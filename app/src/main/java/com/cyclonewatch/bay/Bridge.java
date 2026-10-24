package com.cyclonewatch.bay;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.webkit.JavascriptInterface;
import android.widget.Toast;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;

/** Methods the dashboard can call as window.Android.* */
public class Bridge {

    static final String PREFS = "cw";
    private final Activity act;

    Bridge(Activity act) {
        this.act = act;
    }

    static SharedPreferences prefs(Context c) {
        return c.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    /** Shows a system notification (status changes, location alerts). */
    @JavascriptInterface
    public void showAlert(String title, String body) {
        Notifier.show(act.getApplicationContext(), title, body, Notifier.nextId());
    }

    /** Remembers the chosen location so the background checker can use it. Empty name clears it. */
    @JavascriptInterface
    public void setLocation(double lat, double lon, String name) {
        SharedPreferences.Editor e = prefs(act).edit();
        if (name == null || name.isEmpty()) {
            e.remove("lat").remove("lon").remove("name");
        } else {
            e.putString("lat", String.valueOf(lat)).putString("lon", String.valueOf(lon)).putString("name", name);
        }
        e.apply();
    }

    /** Shared state with the background checker, so the same change is not announced twice. */
    @JavascriptInterface
    public String getPref(String key) {
        return prefs(act).getString("js." + key, null);
    }

    @JavascriptInterface
    public void setPref(String key, String value) {
        SharedPreferences.Editor e = prefs(act).edit();
        if (value == null || value.isEmpty()) e.remove("js." + key);
        else e.putString("js." + key, value);
        e.apply();
    }

    /** Opens the animated track film. */
    @JavascriptInterface
    public void openFilm() {
        act.runOnUiThread(() -> act.startActivity(new Intent(act, FilmActivity.class)));
    }

    /** Saves the current tracks as KML and opens them in Google Earth (or any KML viewer). */
    @JavascriptInterface
    public void openKml(String kml) {
        try {
            File f = KmlProvider.file(act);
            try (FileOutputStream out = new FileOutputStream(f)) {
                out.write(kml.getBytes(StandardCharsets.UTF_8));
            }
        } catch (Exception e) {
            toast("Could not save the tracks");
            return;
        }
        act.runOnUiThread(() -> {
            Intent view = new Intent(Intent.ACTION_VIEW);
            view.setDataAndType(Uri.parse("content://" + KmlProvider.AUTHORITY + "/" + KmlProvider.NAME), KmlProvider.MIME);
            view.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            PackageManager pm = act.getPackageManager();
            if (view.resolveActivity(pm) != null) {
                act.startActivity(Intent.createChooser(view, "Open the tracks in"));
            } else {
                toast("Install Google Earth to view the tracks in 3D");
                MainActivity.openExternal(act, Uri.parse("https://play.google.com/store/apps/details?id=com.google.earth"));
            }
        });
    }

    private void toast(String msg) {
        act.runOnUiThread(() -> Toast.makeText(act, msg, Toast.LENGTH_LONG).show());
    }
}

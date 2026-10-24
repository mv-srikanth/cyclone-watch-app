package com.cyclonewatch.bay;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Calendar;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.TimeZone;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Background check, mirroring the dashboard's own logic:
 * 1. storm status from JTWC (stage estimated from its winds, name, formation alert);
 * 2. wind and rain alert level for the saved location from five forecast models.
 * State is shared with the page (keys "js.stage" and "js.myAlertL") so a change is announced once.
 */
final class Checker {

    private static final String JT = "https://www.metoc.navy.mil/jtwc/";
    private static final String MODELS = "ecmwf_ifs,ukmo_global_deterministic_10km,icon_global,gfs_global,ecmwf_aifs025_single";
    static final String[] CODES = {"LPA", "D", "DD", "CS", "SCS", "VSCS", "ESCS", "SuCS"};
    static final String[] LABELS = {"Low pressure area", "Depression", "Deep depression", "Cyclonic storm",
            "Severe cyclonic storm", "Very severe cyclonic storm", "Extremely severe cyclonic storm", "Super cyclonic storm"};
    static final int[] KT = {0, 17, 28, 34, 48, 64, 90, 120};
    static final String[] LEVELS = {"No warning", "Be aware", "Be prepared", "Take action"};
    static final String[] COLOURS = {"green", "yellow", "orange", "red"};
    private static final List<String> MONTHS = Arrays.asList("JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC");
    private static final Pattern NUMWORD = Pattern.compile(
            "INVEST|ONE|TWO|THREE|FOUR|FIVE|SIX|SEVEN|EIGHT|NINE|TEN|ELEVEN|TWELVE|THIRTEEN|FOURTEEN|FIFTEEN|SIXTEEN|SEVENTEEN|EIGHTEEN|NINETEEN|TWENTY|UNNAMED");

    private Checker() {
    }

    static void run(Context c) {
        SharedPreferences p = Bridge.prefs(c);
        try {
            checkStatus(c, p);
        } catch (Exception ignored) {
            // try again on the next run
        }
        try {
            checkLocation(c, p);
        } catch (Exception ignored) {
            // try again on the next run
        }
    }

    // ---------------------------------------------------------------- storm status

    /** JTWC one-minute wind (kt) to the approximate IMD three-minute category. */
    static int stageIndex(double kt1) {
        double k = kt1 * 0.93;
        int s = 0;
        for (int i = 0; i < KT.length; i++) if (k >= KT[i]) s = i;
        return s;
    }

    static String properName(String n) {
        if (n == null || !n.matches("[A-Z][A-Z'-]+") || NUMWORD.matcher(n).matches()) return null;
        return n.charAt(0) + n.substring(1).toLowerCase(Locale.ROOT);
    }

    static String stageText(String label, String name, boolean tcfa) {
        return label + (name != null ? " " + name : "") + (tcfa && name == null ? " (formation alert)" : "");
    }

    static void checkStatus(Context c, SharedPreferences p) throws Exception {
        String rss = safeGet(JT + "rss/jtwc.rss");
        String abio = safeGet(JT + "products/abioweb.txt");
        if (rss.isEmpty() && abio.isEmpty()) return;

        Set<String> ids = new LinkedHashSet<>();
        Matcher m = Pattern.compile("products/(io\\d{4})web\\.txt", Pattern.CASE_INSENSITIVE).matcher(rss);
        while (m.find()) ids.add(m.group(1).toLowerCase(Locale.ROOT));

        boolean tcfa = false;
        int stage = -1;
        String name = null;
        String src = null;
        long t = 0;
        double best = 1e9;
        for (String id : ids) {
            if (Integer.parseInt(id.substring(2, 4)) >= 90) {
                tcfa = true;
                continue;
            }
            String tcw = safeGet(JT + "products/" + id + ".tcw");
            Matcher h = Pattern.compile("(?m)^(\\d{10})\\s+(\\d{2}[A-Z])\\s+(\\S+)").matcher(tcw);
            Matcher f = Pattern.compile("(?m)^T000\\s+(\\d+)([NS])\\s+(\\d+)([EW])\\s+(\\d+)").matcher(tcw);
            if (!h.find() || !f.find()) continue;
            double lat = Integer.parseInt(f.group(1)) / 10.0 * ("S".equals(f.group(2)) ? -1 : 1);
            double lon = Integer.parseInt(f.group(3)) / 10.0 * ("W".equals(f.group(4)) ? -1 : 1);
            double d = km(16, 87, lat, lon);
            if (d < best) {
                best = d;
                stage = stageIndex(Integer.parseInt(f.group(5)));
                name = properName(h.group(3));
                src = "JTWC warning";
                t = utcMillis(h.group(1));
            }
        }
        boolean isTc = stage >= 0;

        if (!isTc && !abio.isEmpty()) {
            String a = abio.replaceAll("\\s+", " ");
            Calendar cal = Calendar.getInstance(TimeZone.getTimeZone("UTC"));
            int year = cal.get(Calendar.YEAR);
            int month = cal.get(Calendar.MONTH);
            Matcher my = Pattern.compile("\\d{6}Z-\\d{6}Z([A-Z]{3})(\\d{4})").matcher(a);
            if (my.find()) {
                year = Integer.parseInt(my.group(2));
                int mi = MONTHS.indexOf(my.group(1));
                if (mi >= 0) month = mi;
            }
            long issued = System.currentTimeMillis();
            Matcher hd = Pattern.compile("ABIO\\d+ PGTW (\\d{2})(\\d{2})(\\d{2})").matcher(a);
            if (hd.find()) {
                cal.clear();
                cal.set(year, month, Integer.parseInt(hd.group(1)), Integer.parseInt(hd.group(2)), Integer.parseInt(hd.group(3)));
                issued = cal.getTimeInMillis();
            }
            Matcher blk = Pattern.compile("\\(INVEST (\\d{2}[AB])\\)(.*?)(?=\\(\\d\\) | [A-C]\\. (?:TROPICAL|SUBTROPICAL)| \\d\\. (?:NORTH|SOUTH|JUSTIFICATION)|$)").matcher(a);
            while (blk.find()) {
                String b = blk.group(2);
                Matcher pos = Pattern.compile("IS NOW LOCATED NEAR ([\\d.]+)N ([\\d.]+)E").matcher(b);
                if (!pos.find()) {
                    pos = Pattern.compile("LOCATED NEAR ([\\d.]+)N ([\\d.]+)E").matcher(b);
                    if (!pos.find()) continue;
                }
                double lat = Double.parseDouble(pos.group(1));
                double lon = Double.parseDouble(pos.group(2));
                if (lon <= 75 || lon >= 100 || lat <= 0) continue;
                Matcher w = Pattern.compile("WINDS ARE ESTIMATED AT (\\d+)(?: TO (\\d+))? KNOTS").matcher(b);
                if (w.find()) {
                    double w0 = Double.parseDouble(w.group(1));
                    double w1 = w.group(2) != null ? Double.parseDouble(w.group(2)) : w0;
                    stage = stageIndex((w0 + w1) / 2);
                } else {
                    stage = 0;
                }
                name = null;
                src = tcfa ? "JTWC formation alert" : "JTWC advisory";
                t = issued;
                break;
            }
        }
        if (stage < 0) return;

        boolean keyTcfa = !isTc && tcfa;
        String key = CODES[stage] + "|" + (name == null ? "" : name) + "|" + (keyTcfa ? 1 : 0);
        JSONObject prev = null;
        String ps = p.getString("js.stage", null);
        if (ps != null) {
            try {
                prev = new JSONObject(ps);
            } catch (Exception ignored) {
                prev = null;
            }
        }
        if (prev != null) {
            String prevName = prev.isNull("name") ? null : prev.optString("name", null);
            if (prevName != null && prevName.isEmpty()) prevName = null;
            boolean prevTcfa = prev.optBoolean("tcfa", false);
            String prevCode = prev.optString("code", "LPA");
            String pk = prevCode + "|" + (prevName == null ? "" : prevName) + "|" + (prevTcfa ? 1 : 0);
            if (!pk.equals(key) && t >= prev.optLong("t", 0)) {
                int pi = Arrays.asList(CODES).indexOf(prevCode);
                boolean named = name != null && prevName == null;
                boolean up = stage > pi || named || (keyTcfa && !prevTcfa);
                String before = stageText(prev.optString("label", "Disturbance"), prevName, prevTcfa);
                String after = stageText(LABELS[stage], name, keyTcfa);
                String msg = (named ? "Named: " : up ? "Upgraded: " : "Changed: ") + before + " → " + after + " (" + src + ")";
                String title = "Cyclone watch: " + (name != null ? LABELS[stage] + " " + name : LABELS[stage]);
                Notifier.show(c, title, msg, 1001);
            }
        }
        JSONObject now = new JSONObject();
        now.put("code", CODES[stage]);
        now.put("label", LABELS[stage]);
        now.put("name", name == null ? JSONObject.NULL : name);
        now.put("tcfa", keyTcfa);
        now.put("t", t);
        now.put("src", src);
        p.edit().putString("js.stage", now.toString()).apply();
    }

    // ---------------------------------------------------------------- your location

    static void checkLocation(Context c, SharedPreferences p) throws Exception {
        String la = p.getString("lat", null);
        String lo = p.getString("lon", null);
        String place = p.getString("name", null);
        if (la == null || lo == null || place == null || place.isEmpty()) return;

        String body = get("https://api.open-meteo.com/v1/forecast?latitude=" + la + "&longitude=" + lo
                + "&hourly=wind_gusts_10m,precipitation&models=" + MODELS + "&forecast_days=6&timezone=GMT");
        JSONObject h = new JSONObject(body).getJSONObject("hourly");
        JSONArray time = h.getJSONArray("time");
        int n = time.length();
        SimpleDateFormat fmt = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm", Locale.ROOT);
        fmt.setTimeZone(TimeZone.getTimeZone("UTC"));
        long[] ts = new long[n];
        for (int i = 0; i < n; i++) ts[i] = fmt.parse(time.getString(i)).getTime();
        long from = System.currentTimeMillis() - 3600000L;

        List<Double> gusts = new ArrayList<>();
        List<Double> rains = new ArrayList<>();
        for (String model : MODELS.split(",")) {
            JSONArray g = h.optJSONArray("wind_gusts_10m_" + model);
            JSONArray r = h.optJSONArray("precipitation_" + model);
            if (r == null) continue;
            double gmax = -1;
            double rmax = 0;
            for (int k = 0; k < n; k++) {
                if (ts[k] < from) continue;
                if (g != null && !g.isNull(k)) gmax = Math.max(gmax, g.getDouble(k));
            }
            for (int k = 0; k + 24 <= n; k++) {
                if (ts[k] < from) continue;
                double s = 0;
                for (int q = k; q < k + 24; q++) if (!r.isNull(q)) s += r.getDouble(q);
                rmax = Math.max(rmax, s);
            }
            if (gmax >= 0) gusts.add(gmax);
            rains.add(rmax);
        }
        if (rains.isEmpty()) return;
        double g = lowerMedian(gusts);
        double r = lowerMedian(rains);
        int level = 0;
        if (g >= 40 || r >= 64.5) level = 1;
        if (g >= 62 || r >= 115.6) level = 2;
        if (g >= 89 || r >= 204.5) level = 3;

        String prevS = p.getString("js.myAlertL", null);
        Integer prev = null;
        if (prevS != null) {
            try {
                prev = (int) Double.parseDouble(prevS);
            } catch (NumberFormatException ignored) {
                prev = null;
            }
        }
        // The page can also raise the level from the ensemble strike chance, which is not computed here,
        // so the background check only ever raises the level and leaves lowering to the page.
        if (prev == null || level > prev) {
            if (prev != null) {
                String msg = place + ": " + LEVELS[level] + " (" + COLOURS[level] + ") — gusts about " + Math.round(g)
                        + " km/h, up to " + Math.round(r) + " mm of rain in 24 h";
                Notifier.show(c, "Your location: " + LEVELS[level], msg, 1002);
            }
            p.edit().putString("js.myAlertL", String.valueOf(level)).apply();
        }
    }

    static double lowerMedian(List<Double> v) {
        if (v.isEmpty()) return 0;
        List<Double> s = new ArrayList<>(v);
        Collections.sort(s);
        return s.get((s.size() - 1) / 2);
    }

    // ---------------------------------------------------------------- helpers

    static double km(double a1, double o1, double a2, double o2) {
        double r = Math.PI / 180, dA = (a2 - a1) * r, dO = (o2 - o1) * r;
        double s = Math.pow(Math.sin(dA / 2), 2) + Math.cos(a1 * r) * Math.cos(a2 * r) * Math.pow(Math.sin(dO / 2), 2);
        return 12742 * Math.asin(Math.sqrt(s));
    }

    static long utcMillis(String yyyymmddhh) {
        Calendar cal = Calendar.getInstance(TimeZone.getTimeZone("UTC"));
        cal.clear();
        cal.set(Integer.parseInt(yyyymmddhh.substring(0, 4)), Integer.parseInt(yyyymmddhh.substring(4, 6)) - 1,
                Integer.parseInt(yyyymmddhh.substring(6, 8)), Integer.parseInt(yyyymmddhh.substring(8, 10)), 0);
        return cal.getTimeInMillis();
    }

    static String safeGet(String url) {
        try {
            return get(url);
        } catch (Exception e) {
            return "";
        }
    }

    static String get(String url) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        c.setConnectTimeout(20000);
        c.setReadTimeout(30000);
        c.setRequestProperty("User-Agent", "CycloneWatch-Android/1.0");
        try {
            int code = c.getResponseCode();
            if (code >= 400) throw new Exception("HTTP " + code);
            try (InputStream in = c.getInputStream()) {
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                byte[] buf = new byte[16384];
                int k;
                while ((k = in.read(buf)) > 0) out.write(buf, 0, k);
                return new String(out.toByteArray(), StandardCharsets.UTF_8);
            }
        } finally {
            c.disconnect();
        }
    }
}

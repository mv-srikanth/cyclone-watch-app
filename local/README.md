# Cyclone Watch — local edition (Windows, Mac, Linux)

The same live dashboard as the Android and iPhone apps, opened in your web browser from your own computer,
plus a track from **Google's WeatherNext** weather model read through your own Google Cloud access.

## Start it

You need Python 3.8 or newer (python.org). Nothing else to install for the dashboard.

- **Windows:** double-click `Start Cyclone Watch.bat`
- **Mac:** double-click `start-cyclone-watch.command` (first time: right-click → Open)
- **Any system:** `python3 cyclone_watch.py`

Your browser opens `http://127.0.0.1:8765/`. Keep the small window open while you use it; close it (or Ctrl+C) to stop.
The page is served only to this computer. It reads JTWC through the local server, so the
advisories that a browser alone would block now load as they do in the apps. The **Animation** button opens the track film.

## Open it on your phone

**Same Wi-Fi as the computer (includes the Google track):**
1. On the computer, double-click `Start for Phone.bat` (Windows) or `start-for-phone.command` (Mac), or run `python3 cyclone_watch.py --phone`.
2. The window prints an address such as `http://192.168.1.23:8765/`. Type it into the phone's browser (Chrome or Safari).
3. Optional: browser menu → **Add to Home screen** so it opens like an app.

Windows asks once whether Python may use the network: allow it on **private** networks. Anyone on the same Wi-Fi can open the page,
and their visits run Google WeatherNext queries billed to your project, so use phone mode on your home Wi-Fi only.
Phone browsers only share GPS with secure (https) pages, so **Use my location** will not work on this address. Pick a town or tap the map instead.
The computer must stay on, with the window open.

**Away from the computer:** install the Android app (APK, see the main README) or the iPhone app. They show the same dashboard and
send background alerts, but not the Google WeatherNext track, because that needs your Google sign-in on the computer.

## Google WeatherNext

The local server reads WeatherNext forecasts from BigQuery with your Google account, follows the
lowest sea-level pressure from the current JTWC position of the system (for example Invest 92B), and draws it on the map as a dashed blue
line, with a **Google WeatherNext** card in the side panel (also in the Google Earth export).

One-time setup:

1. Have WeatherNext access in BigQuery (WeatherNext data request form, then subscribe to the listing in Analytics Hub; this creates a dataset in your project).
2. Install the Google Cloud CLI, then run:
   ```
   gcloud auth application-default login
   gcloud config set project YOUR_PROJECT_ID
   ```
3. Optional: copy `config.example.json` to `config.json` to name the project and table yourself. Without it the
   app looks through your project's datasets for a `weathernext_*` table and picks the newest version
   (WeatherNext 3 `weathernext_3_0_0_0p1deg`, or WeatherNext 2 tables). Environment variables `CW_BILLING_PROJECT` and `CW_WEATHERNEXT_TABLE` also work.

Queries use the latest 00/06/12/18 UTC run, read only the Indian Ocean area and are cached for the run,
but BigQuery bills you for the data scanned (see your project's BigQuery costs).

### Ask for the latest Invest 92 from the command line

```
python3 cyclone_watch.py --invest 92
```

prints JTWC's latest position for Invest 92 (92B in the Bay of Bengal) and Google WeatherNext's track from its newest run:
lead time, position, central pressure and strongest nearby wind every 6 hours. Use any invest number (`--invest 93`, …).
In the browser the same answer is at `http://127.0.0.1:8765/api/google/invest?id=92`.

The track is traced from the model's pressure field by this app; it is not Google's own cyclone product, and not an official forecast.
Follow IMD and your state disaster management authority.

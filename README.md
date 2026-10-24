# Cyclone Watch — Android app

Everything built for the web, in one Android app:

- **Live dashboard** (opens first)
  - Storm shown with a spinning cyclone symbol; status ladder (D → DD → CS → SCS …) that updates itself, with alerts when the system is upgraded or named.
  - Five model tracks in order of resolution: ECMWF HRES 9 km, UK Met Office 10 km, ICON 13 km, GFS, ECMWF AIFS.
  - 82-run ensemble cone, landfall chances along the coast, strike chance.
  - Wind and rain maps that follow the time slider, with IMD categories.
  - Satellite view (Himawari infrared/visible/air mass, Meteosat, VIIRS) and Radar view (radar mosaic, rain from space, IMD radar sites).
  - Coastal-town table and a forecast for any spot you tap.
- **Your location**: phone GPS (or a town you pick) → gusts, 24-hour rain, storm distance, strike chance and a green / yellow / orange / red level.
- **Track animation**: the 30-second film with its soundtrack (film button in the top bar).
- **Google Earth**: the globe button exports the current tracks and cone and opens them in Google Earth.
- **Background alerts**: every 30 minutes when online, the app checks JTWC and the forecast for your saved location and notifies you when the storm is upgraded or named, or your alert level rises — even with the app closed.

Not an official forecast. Follow IMD and your state disaster management authority.

## Build the APK

**A. Android Studio (Windows, Mac or Linux)**
1. Install Android Studio (Koala 2024.1 or newer).
2. File → Open → choose this `CycloneWatch` folder and let it sync (it downloads Gradle 8.7 and the Android plugin).
3. Build → Build App Bundle(s) / APK(s) → Build APK(s). The APK appears under `app/build/outputs/apk/`.
   Or connect a phone with USB debugging on and press Run.

**B. GitHub (nothing to install)**
1. Create a GitHub repository and upload this folder's contents, including the hidden `.github` folder.
2. Open the repository's **Actions** tab; "Build APK" runs automatically (about 5 minutes).
3. Open the finished run and download **CycloneWatch-apk** (a zip with the APK inside).

## Install on a phone
Copy the APK to the phone and open it; Android asks once to allow installs from that source.
On first launch allow **location** (for your-location alerts) and **notifications** (for alerts).
Some phones pause background apps to save battery: set Cyclone Watch's battery use to "Unrestricted" for timely alerts.

## Notes
- The release build is signed with the standard debug key so it installs directly. Use your own signing key before publishing on the Play Store.
- Needs an internet connection. Data: Open-Meteo (CC BY 4.0), NASA GIBS, EUMETSAT, RainViewer, JTWC, GDACS.
- Package `com.cyclonewatch.bay`; Android 7.0 (API 24) and newer; targets Android 14 (API 34).
- Source layout: `app/src/main/java/...` (Java, no extra libraries), `app/src/main/assets/index.html` (dashboard), `assets/film.html` (animation).

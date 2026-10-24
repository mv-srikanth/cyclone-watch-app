# Cyclone Watch — iPhone and iPad app

The same app as the Android version:

- **Live dashboard** (opens first)
  - Storm shown with a spinning cyclone symbol; status ladder (D → DD → CS → SCS …) that updates itself, with an alert when the system is upgraded or named.
  - Five model tracks in order of resolution: ECMWF HRES 9 km, UK Met Office 10 km, ICON 13 km, GFS, ECMWF AIFS.
  - 82-run ensemble cone, landfall chances along the coast, strike chance.
  - Wind and rain maps that follow the time slider, with IMD categories.
  - Satellite view (Himawari infrared/visible/air mass, Meteosat, VIIRS) and Radar view (radar mosaic, rain from space, IMD radar sites).
  - Coastal-town table and a forecast for any spot you tap.
- **Your location**: iPhone location (or a town you pick) → gusts, 24-hour rain, storm distance, strike chance and a green / yellow / orange / red level.
- **Track animation**: the 30-second film with its soundtrack (Animation button in the top bar).
- **Google Earth**: the globe button exports the current tracks and cone; choose Google Earth, Files or AirDrop from the share sheet.
- **Background alerts**: the app checks JTWC and the forecast for your saved location in the background and notifies you when the storm is upgraded or named, or your alert level rises.

Not an official forecast. Follow IMD and your state disaster management authority.

## What's in this folder

```
ios/
  CycloneWatch.xcodeproj      Xcode project (open this)
  CycloneWatch/
    CycloneWatchApp.swift     app start, background check, notifications
    ContentView.swift         screen, animation player, share sheet
    WebBridge.swift           connects the dashboard to location, alerts, files
    Checker.swift             background storm-status and location check
    index.html                the live dashboard
    film.html                 the track animation
    Info.plist, Assets.xcassets (icon, colours)
.github/workflows/build-ios.yml   builds the app on GitHub's Macs
```

## Install on an iPhone

Apple only lets apps onto an iPhone if they are signed with an Apple ID. A free Apple ID is enough for your own phone; the app then runs for 7 days before it must be installed again (your data and saved location stay).

**A. With a Mac (Xcode 15 or newer)**
1. Open `CycloneWatch.xcodeproj` in Xcode.
2. Click the CycloneWatch project → target **CycloneWatch** → **Signing & Capabilities** → Team: add and pick your Apple ID ("Personal Team").
   If Xcode says the bundle identifier is not available, change `com.cyclonewatch.bay` to something of your own, such as `com.yourname.cyclonewatch`.
3. Connect the iPhone by cable, unlock it and tap **Trust**. On iOS 16 or newer turn on **Settings → Privacy & Security → Developer Mode** (the phone restarts).
4. Choose the iPhone at the top of Xcode and press **Run** (▶).
5. The first time, on the iPhone: **Settings → General → VPN & Device Management** → your Apple ID → **Trust**.

**B. Without a Mac (GitHub builds it)**
1. Upload this `ios` folder and `.github/workflows/build-ios.yml` into your Cyclone Watch GitHub repository (next to the Android project).
2. **Actions** tab → "Build iOS app" runs (about 5–10 minutes). Open the finished run and download **CycloneWatch-ios-unsigned-ipa**; unzip it to get `CycloneWatch-unsigned.ipa`.
3. Install the .ipa from a Windows PC or Mac with a sideloading tool that signs with your Apple ID, such as Sideloadly or AltStore. Then do step 5 above (Trust) and turn on Developer Mode if asked.

**Sharing with other people**: iPhones cannot install an app from a file the way Android can. Each person either installs it the same way with their own Apple ID, or you join the Apple Developer Program (US$99 a year) and invite them through TestFlight. The web dashboard also works in Safari on any iPhone (Share → Add to Home Screen).

## First launch
- Allow **notifications** (for alerts) and, when you tap "Use my location", **location while using the app**.
- Keep **Settings → General → Background App Refresh** on for Cyclone Watch. iOS decides when background checks run (usually a few times a day, more often for apps you open regularly); Low Power Mode pauses them. Opening the app always updates everything at once.

## Notes
- iOS 15 and newer, iPhone and iPad. Needs an internet connection. Data: Open-Meteo (CC BY 4.0), NASA GIBS, EUMETSAT, RainViewer, JTWC, GDACS.
- Bundle identifier `com.cyclonewatch.bay`; background task identifier `com.cyclonewatch.bay.refresh`.
- No extra libraries; the dashboard and the animation are the same files as the web and Android versions.

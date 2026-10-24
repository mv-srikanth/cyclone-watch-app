import SwiftUI
import WebKit
import CoreLocation
import UIKit

private let baseURL = URL(string: "https://cyclonewatch.local/")!
private let pageColor = UIColor(red: 11 / 255, green: 22 / 255, blue: 34 / 255, alpha: 1)

/// Shared state between the dashboard page and SwiftUI.
final class WebModel: ObservableObject {
    @Published var showFilm = false
    @Published var shareItem: ShareItem?
    weak var web: WKWebView?
}

/// Values the page and the background check both read, so a change is announced only once.
enum Prefs {
    static let keys = ["stage", "myAlertL"]

    static func pageJSON() -> String {
        var out: [String: String] = [:]
        for k in keys {
            if let v = UserDefaults.standard.string(forKey: "js." + k) { out[k] = v }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: out),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

/// Gives the page the same `window.Android` interface the Android app has, plus native location.
private func shimScript() -> String {
    """
    (function(){
     var P = \(Prefs.pageJSON());
     function post(o){ try { window.webkit.messageHandlers.cw.postMessage(o); } catch (e) {} }
     window.__cwSetPrefs = function(o){ P = o || {}; };
     window.Android = {
      showAlert: function(t, b){ post({fn: 'showAlert', title: String(t), body: String(b)}); },
      setLocation: function(a, o, n){ post({fn: 'setLocation', lat: Number(a), lon: Number(o), name: String(n || '')}); },
      getPref: function(k){ return Object.prototype.hasOwnProperty.call(P, k) ? P[k] : null; },
      setPref: function(k, v){ if (v) { P[k] = String(v); } else { delete P[k]; } post({fn: 'setPref', key: String(k), value: v ? String(v) : ''}); },
      openFilm: function(){ post({fn: 'openFilm'}); },
      openKml: function(k){ post({fn: 'openKml', kml: String(k)}); }
     };
     var waiting = [];
     window.__cwGeo = function(la, lo, acc){ var q = waiting; waiting = []; q.forEach(function(w){ w.ok({coords: {latitude: la, longitude: lo, accuracy: acc}, timestamp: Date.now()}); }); };
     window.__cwGeoErr = function(code, msg){ var q = waiting; waiting = []; q.forEach(function(w){ if (w.err) w.err({code: code, message: msg}); }); };
     try {
      Object.defineProperty(navigator, 'geolocation', {configurable: true, value: {
       getCurrentPosition: function(ok, err){ waiting.push({ok: ok, err: err}); post({fn: 'locate'}); },
       watchPosition: function(){ return 0; },
       clearWatch: function(){}
      }});
     } catch (e) {}
    })();
    """
}

private func bundledPage(_ name: String) -> String {
    guard let url = Bundle.main.url(forResource: name, withExtension: "html"),
          let text = try? String(contentsOf: url, encoding: .utf8) else {
        return "<html><body style='background:#0B1622;color:#fff;font-family:-apple-system'>Could not open \(name).html</body></html>"
    }
    return text
}

/// The live dashboard.
struct DashboardWebView: UIViewRepresentable {
    @ObservedObject var model: WebModel

    func makeCoordinator() -> WebBridge {
        WebBridge(model: model)
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: shimScript(), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(context.coordinator, name: "cw")

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()

        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = pageColor
        web.scrollView.backgroundColor = pageColor
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        context.coordinator.web = web
        model.web = web
        web.loadHTMLString(bundledPage("index"), baseURL: baseURL)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}
}

/// The track animation.
struct FilmWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 5 / 255, green: 13 / 255, blue: 21 / 255, alpha: 1)
        web.scrollView.isScrollEnabled = false
        web.loadHTMLString(bundledPage("film"), baseURL: baseURL.appendingPathComponent("film/"))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}
}

/// Handles calls from the page, external links and location.
final class WebBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, CLLocationManagerDelegate {

    private let model: WebModel
    weak var web: WKWebView?
    private var locator: CLLocationManager?
    private var wantsLocation = false

    init(model: WebModel) {
        self.model = model
    }

    // MARK: messages from the page

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let fn = body["fn"] as? String else { return }
        let defaults = UserDefaults.standard
        switch fn {
        case "showAlert":
            Notifications.post(title: body["title"] as? String ?? "Cyclone watch", body: body["body"] as? String ?? "")
        case "setLocation":
            let name = body["name"] as? String ?? ""
            if name.isEmpty {
                defaults.removeObject(forKey: "lat")
                defaults.removeObject(forKey: "lon")
                defaults.removeObject(forKey: "name")
            } else {
                let lat = (body["lat"] as? NSNumber)?.doubleValue ?? 0
                let lon = (body["lon"] as? NSNumber)?.doubleValue ?? 0
                defaults.set(String(format: "%.4f", lat), forKey: "lat")
                defaults.set(String(format: "%.4f", lon), forKey: "lon")
                defaults.set(name, forKey: "name")
            }
        case "setPref":
            guard let key = body["key"] as? String else { return }
            let value = body["value"] as? String ?? ""
            if value.isEmpty {
                defaults.removeObject(forKey: "js." + key)
            } else {
                defaults.set(value, forKey: "js." + key)
            }
        case "openFilm":
            model.showFilm = true
        case "openKml":
            let kml = body["kml"] as? String ?? ""
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("cyclone-tracks.kml")
            do {
                try kml.write(to: url, atomically: true, encoding: .utf8)
                model.shareItem = ShareItem(url: url)
            } catch {
                Notifications.post(title: "Cyclone watch", body: "Could not save the tracks file.")
            }
        case "locate":
            requestLocation()
        default:
            break
        }
    }

    // MARK: links

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url,
           navigationAction.navigationType == .linkActivated,
           url.host != baseURL.host {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            UIApplication.shared.open(url)
        }
        return nil
    }

    // MARK: location

    private func requestLocation() {
        let manager = locator ?? CLLocationManager()
        if locator == nil {
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            locator = manager
        }
        wantsLocation = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            replyError(1, "location access is off for Cyclone Watch (turn it on in Settings)")
        default:
            manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard wantsLocation else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            replyError(1, "location access is off for Cyclone Watch (turn it on in Settings)")
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard wantsLocation, let loc = locations.last else { return }
        wantsLocation = false
        let c = loc.coordinate
        web?.evaluateJavaScript("window.__cwGeo(\(c.latitude), \(c.longitude), \(loc.horizontalAccuracy))")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        replyError(2, "your position is not available right now")
    }

    private func replyError(_ code: Int, _ message: String) {
        wantsLocation = false
        let safe = message.replacingOccurrences(of: "'", with: "\\'")
        web?.evaluateJavaScript("window.__cwGeoErr(\(code), '\(safe)')")
    }
}

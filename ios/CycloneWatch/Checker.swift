import Foundation

/// Background check, mirroring the dashboard's own logic (and the Android app's):
/// 1. storm status from JTWC (stage estimated from its winds, name, formation alert);
/// 2. wind and rain alert level for the saved location from five forecast models.
/// State is shared with the page (keys "js.stage" and "js.myAlertL") so a change is announced once.
enum Checker {

    private static let jt = "https://www.metoc.navy.mil/jtwc/"
    private static let models = ["ecmwf_ifs", "ukmo_global_deterministic_10km", "icon_global", "gfs_global", "ecmwf_aifs025_single"]
    static let codes = ["LPA", "D", "DD", "CS", "SCS", "VSCS", "ESCS", "SuCS"]
    static let labels = ["Low pressure area", "Depression", "Deep depression", "Cyclonic storm",
                         "Severe cyclonic storm", "Very severe cyclonic storm", "Extremely severe cyclonic storm", "Super cyclonic storm"]
    static let kt: [Double] = [0, 17, 28, 34, 48, 64, 90, 120]
    static let levels = ["No warning", "Be aware", "Be prepared", "Take action"]
    static let colours = ["green", "yellow", "orange", "red"]
    private static let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

    private static let defaults = UserDefaults.standard

    static func run() async {
        async let status: Void = checkStatus()
        async let place: Void = checkLocation()
        _ = await (status, place)
    }

    // MARK: storm status

    /// JTWC one-minute wind (kt) to the approximate IMD three-minute category.
    static func stageIndex(_ kt1: Double) -> Int {
        let k = kt1 * 0.93
        var s = 0
        for (i, v) in kt.enumerated() where k >= v { s = i }
        return s
    }

    static func properName(_ n: String?) -> String? {
        guard let n = n,
              Rx("^[A-Z][A-Z'-]+$").first(n) != nil,
              Rx("^(?:INVEST|ONE|TWO|THREE|FOUR|FIVE|SIX|SEVEN|EIGHT|NINE|TEN|ELEVEN|TWELVE|THIRTEEN|FOURTEEN|FIFTEEN|SIXTEEN|SEVENTEEN|EIGHTEEN|NINETEEN|TWENTY|UNNAMED)$").first(n) == nil
        else { return nil }
        return String(n.prefix(1)) + n.dropFirst().lowercased()
    }

    static func stageText(_ label: String, _ name: String?, _ tcfa: Bool) -> String {
        let named = name.map { " " + $0 } ?? ""
        let alert = tcfa && name == nil ? " (formation alert)" : ""
        return label + named + alert
    }

    static func checkStatus() async {
        async let rssText = safeGet(jt + "rss/jtwc.rss")
        async let abioText = safeGet(jt + "products/abioweb.txt")
        let rss = await rssText
        let abio = await abioText
        if rss.isEmpty && abio.isEmpty { return }

        var ids: [String] = []
        for g in Rx("products/(io\\d{4})web\\.txt", [.caseInsensitive]).all(rss) {
            let id = (g[1] ?? "").lowercased()
            if !id.isEmpty && !ids.contains(id) { ids.append(id) }
        }

        var tcfa = false
        var stage = -1
        var name: String?
        var src = ""
        var t: Int64 = 0
        var best = 1e9
        for id in ids {
            let num = Int(id.dropFirst(2).prefix(2)) ?? 0
            if num >= 90 {
                tcfa = true
                continue
            }
            let tcw = await safeGet(jt + "products/" + id + ".tcw")
            guard let h = Rx("^(\\d{10})\\s+(\\d{2}[A-Z])\\s+(\\S+)", [.anchorsMatchLines]).first(tcw),
                  let f = Rx("^T000\\s+(\\d+)([NS])\\s+(\\d+)([EW])\\s+(\\d+)", [.anchorsMatchLines]).first(tcw),
                  let la = Double(f[1] ?? ""), let lo = Double(f[3] ?? ""), let wind = Double(f[5] ?? "")
            else { continue }
            let lat = la / 10 * (f[2] == "S" ? -1 : 1)
            let lon = lo / 10 * (f[4] == "W" ? -1 : 1)
            let d = km(16, 87, lat, lon)
            if d < best {
                best = d
                stage = stageIndex(wind)
                name = properName(h[3])
                src = "JTWC warning"
                t = utcMillis(h[1] ?? "")
            }
        }
        let isTc = stage >= 0

        if !isTc && !abio.isEmpty {
            let a = abio.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            let nowParts = cal.dateComponents([.year, .month], from: Date())
            var year = nowParts.year ?? 2026
            var month = nowParts.month ?? 1
            if let my = Rx("\\d{6}Z-\\d{6}Z([A-Z]{3})(\\d{4})").first(a) {
                year = Int(my[2] ?? "") ?? year
                if let mi = months.firstIndex(of: my[1] ?? "") { month = mi + 1 }
            }
            var issued = Int64(Date().timeIntervalSince1970 * 1000)
            if let hd = Rx("ABIO\\d+ PGTW (\\d{2})(\\d{2})(\\d{2})").first(a),
               let date = cal.date(from: DateComponents(year: year, month: month, day: Int(hd[1] ?? ""),
                                                        hour: Int(hd[2] ?? ""), minute: Int(hd[3] ?? ""))) {
                issued = Int64(date.timeIntervalSince1970 * 1000)
            }
            let block = Rx("\\(INVEST (\\d{2}[AB])\\)(.*?)(?=\\(\\d\\) | [A-C]\\. (?:TROPICAL|SUBTROPICAL)| \\d\\. (?:NORTH|SOUTH|JUSTIFICATION)|$)")
            for blk in block.all(a) {
                let b = blk[2] ?? ""
                guard let pos = Rx("IS NOW LOCATED NEAR ([\\d.]+)N ([\\d.]+)E").first(b) ?? Rx("LOCATED NEAR ([\\d.]+)N ([\\d.]+)E").first(b),
                      let lat = Double(pos[1] ?? ""), let lon = Double(pos[2] ?? "")
                else { continue }
                if lon <= 75 || lon >= 100 || lat <= 0 { continue }
                if let w = Rx("WINDS ARE ESTIMATED AT (\\d+)(?: TO (\\d+))? KNOTS").first(b), let w0 = Double(w[1] ?? "") {
                    let w1 = Double(w[2] ?? "") ?? w0
                    stage = stageIndex((w0 + w1) / 2)
                } else {
                    stage = 0
                }
                name = nil
                src = tcfa ? "JTWC formation alert" : "JTWC advisory"
                t = issued
                break
            }
        }
        if stage < 0 || Task.isCancelled { return }

        let keyTcfa = !isTc && tcfa
        let key = codes[stage] + "|" + (name ?? "") + "|" + (keyTcfa ? "1" : "0")
        if let ps = defaults.string(forKey: "js.stage"),
           let data = ps.data(using: .utf8),
           let prev = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            var prevName = prev["name"] as? String
            if prevName?.isEmpty == true { prevName = nil }
            let prevTcfa = prev["tcfa"] as? Bool ?? false
            let prevCode = prev["code"] as? String ?? "LPA"
            let prevT = (prev["t"] as? NSNumber)?.int64Value ?? 0
            let pk = prevCode + "|" + (prevName ?? "") + "|" + (prevTcfa ? "1" : "0")
            if pk != key && t >= prevT {
                let pi = codes.firstIndex(of: prevCode) ?? 0
                let named = name != nil && prevName == nil
                let up = stage > pi || named || (keyTcfa && !prevTcfa)
                let before = stageText(prev["label"] as? String ?? "Disturbance", prevName, prevTcfa)
                let after = stageText(labels[stage], name, keyTcfa)
                let verb = named ? "Named" : (up ? "Upgraded" : "Changed")
                let msg = "\(verb): \(before) → \(after) (\(src))"
                let title = name.map { "Cyclone watch: \(labels[stage]) \($0)" } ?? "Cyclone watch: \(labels[stage])"
                Notifications.post(title: title, body: msg, id: "cw.status")
            }
        }
        let now: [String: Any] = [
            "code": codes[stage],
            "label": labels[stage],
            "name": name.map { $0 as Any } ?? NSNull(),
            "tcfa": keyTcfa,
            "t": NSNumber(value: t),
            "src": src,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: now), let text = String(data: data, encoding: .utf8) {
            defaults.set(text, forKey: "js.stage")
        }
    }

    // MARK: your location

    static func checkLocation() async {
        guard let la = defaults.string(forKey: "lat"), let lo = defaults.string(forKey: "lon"),
              let place = defaults.string(forKey: "name"), !place.isEmpty else { return }

        let url = "https://api.open-meteo.com/v1/forecast?latitude=" + la + "&longitude=" + lo
            + "&hourly=wind_gusts_10m,precipitation&models=" + models.joined(separator: ",") + "&forecast_days=6&timezone=GMT"
        guard let body = try? await get(url),
              let data = body.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let h = root["hourly"] as? [String: Any],
              let time = h["time"] as? [String]
        else { return }

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let ts = time.map { fmt.date(from: $0)?.timeIntervalSince1970 ?? 0 }
        let n = ts.count
        let from = Date().timeIntervalSince1970 - 3600

        func values(_ key: String) -> [Double?]? {
            guard let arr = h[key] as? [Any] else { return nil }
            return arr.map { ($0 as? NSNumber)?.doubleValue }
        }

        var gusts: [Double] = []
        var rains: [Double] = []
        for model in models {
            guard let r = values("precipitation_" + model), r.count >= n else { continue }
            let g = values("wind_gusts_10m_" + model)
            var gmax = -1.0
            var rmax = 0.0
            for k in 0..<n where ts[k] >= from {
                if let g = g, k < g.count, let v = g[k] { gmax = max(gmax, v) }
            }
            if n >= 24 {
                for k in 0...(n - 24) where ts[k] >= from {
                    var s = 0.0
                    for q in k..<(k + 24) { s += r[q] ?? 0 }
                    rmax = max(rmax, s)
                }
            }
            if gmax >= 0 { gusts.append(gmax) }
            rains.append(rmax)
        }
        if rains.isEmpty || Task.isCancelled { return }
        let g = lowerMedian(gusts)
        let r = lowerMedian(rains)
        var level = 0
        if g >= 40 || r >= 64.5 { level = 1 }
        if g >= 62 || r >= 115.6 { level = 2 }
        if g >= 89 || r >= 204.5 { level = 3 }

        let prev = defaults.string(forKey: "js.myAlertL").flatMap { Double($0) }.map { Int($0) }
        // The page can also raise the level from the ensemble strike chance, which is not computed here,
        // so the background check only ever raises the level and leaves lowering to the page.
        if prev == nil || level > prev! {
            if prev != nil {
                let msg = "\(place): \(levels[level]) (\(colours[level])) — gusts about \(Int(g.rounded())) km/h, up to \(Int(r.rounded())) mm of rain in 24 h"
                Notifications.post(title: "Your location: \(levels[level])", body: msg, id: "cw.location")
            }
            defaults.set(String(level), forKey: "js.myAlertL")
        }
    }

    static func lowerMedian(_ v: [Double]) -> Double {
        if v.isEmpty { return 0 }
        let s = v.sorted()
        return s[(s.count - 1) / 2]
    }

    // MARK: helpers

    static func km(_ a1: Double, _ o1: Double, _ a2: Double, _ o2: Double) -> Double {
        let r = Double.pi / 180, dA = (a2 - a1) * r, dO = (o2 - o1) * r
        let s = pow(sin(dA / 2), 2) + cos(a1 * r) * cos(a2 * r) * pow(sin(dO / 2), 2)
        return 12742 * asin(sqrt(s))
    }

    static func utcMillis(_ s: String) -> Int64 {
        let c = Array(s)
        guard c.count >= 10 else { return 0 }
        func num(_ a: Int, _ b: Int) -> Int { Int(String(c[a..<b])) ?? 0 }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let d = cal.date(from: DateComponents(year: num(0, 4), month: num(4, 6), day: num(6, 8), hour: num(8, 10), minute: 0))
        return Int64((d?.timeIntervalSince1970 ?? 0) * 1000)
    }

    static func safeGet(_ url: String) async -> String {
        (try? await get(url)) ?? ""
    }

    static func get(_ url: String) async throws -> String {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("CycloneWatch-iOS/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw URLError(.badServerResponse)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Small wrapper over NSRegularExpression (works on iOS 15).
struct Rx {
    private let re: NSRegularExpression?

    init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        re = try? NSRegularExpression(pattern: pattern, options: options)
    }

    private func groups(_ m: NSTextCheckingResult, _ ns: NSString) -> [String?] {
        (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    /// Capture groups of the first match (index 0 is the whole match), or nil.
    func first(_ s: String) -> [String?]? {
        guard let re = re else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return groups(m, ns)
    }

    /// Capture groups of every match.
    func all(_ s: String) -> [[String?]] {
        guard let re = re else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { groups($0, ns) }
    }
}

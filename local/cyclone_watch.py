#!/usr/bin/env python3
"""Cyclone Watch, local edition.

Opens the same live dashboard as the Android and iOS apps in your web browser,
served from this computer, and adds a track from Google's WeatherNext weather
model (read from your own BigQuery access).

    python3 cyclone_watch.py                 # start and open the dashboard
    python3 cyclone_watch.py --invest 92     # print Google's latest track for Invest 92 and exit

Only the Python standard library is used. Google access comes from the Google
Cloud CLI on this computer (run `gcloud auth application-default login` once).
"""

import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.normpath(os.path.join(HERE, "..", "app", "src", "main", "assets"))
CONFIG_PATH = os.path.join(HERE, "config.json")
JTWC = "https://www.metoc.navy.mil/jtwc/"
BQ = "https://bigquery.googleapis.com/bigquery/v2"
UA = "CycloneWatch-Local/1.0"

# Bay of Bengal and Arabian Sea search area for the tracker
BOX = {"lat0": -2.0, "lat1": 30.0, "lon0": 60.0, "lon1": 102.0}
BIN = 0.5          # degrees; pressure minimum and wind maximum per bin
STEP_H = 6         # hours between track points
MAX_H = 168        # 7 days


# ------------------------------------------------------------------ config

def load_config():
    cfg = {}
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, encoding="utf-8") as f:
                cfg = json.load(f)
        except Exception as e:  # noqa: BLE001
            print("! could not read config.json:", e)
    env = {
        "billing_project": os.environ.get("CW_BILLING_PROJECT"),
        "weathernext_table": os.environ.get("CW_WEATHERNEXT_TABLE"),
        "port": os.environ.get("CW_PORT"),
    }
    cfg.update({k: v for k, v in env.items() if v})
    return cfg


CFG = load_config()


# ------------------------------------------------------------------ http helpers

def http(url, data=None, headers=None, timeout=60):
    h = {"User-Agent": UA}
    h.update(headers or {})
    body = None
    if data is not None:
        body = json.dumps(data).encode()
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=h, method="POST" if body else "GET")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.headers, r.read()


# ------------------------------------------------------------------ JTWC

def parse_abio(txt):
    """Same parser as the dashboard: invest areas from the JTWC Indian Ocean advisory."""
    t = re.sub(r"\s+", " ", txt)
    out = []
    issued = None
    my = re.search(r"\d{6}Z-\d{6}Z([A-Z]{3})(\d{4})", t)
    hd = re.search(r"ABIO\d+ PGTW (\d{2})(\d{2})(\d{2})", t)
    if my and hd:
        mon = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"].index(my.group(1)) + 1
        issued = datetime(int(my.group(2)), mon, int(hd.group(1)), int(hd.group(2)), int(hd.group(3)), tzinfo=timezone.utc)
    pat = re.compile(r"\(INVEST (\d{2}[A-Z])\)(.*?)(?=\(\d\) | [A-C]\. (?:TROPICAL|SUBTROPICAL)| \d\. (?:NORTH|SOUTH|JUSTIFICATION)|$)")
    for m in pat.finditer(t):
        b = m.group(2)
        pos = re.search(r"IS NOW LOCATED NEAR ([\d.]+)([NS]) ([\d.]+)([EW])", b) or re.search(r"LOCATED NEAR ([\d.]+)([NS]) ([\d.]+)([EW])", b)
        if not pos:
            continue
        w = re.search(r"WINDS ARE ESTIMATED AT (\d+)(?: TO (\d+))? KNOTS", b)
        p = re.search(r"PRESSURE IS ESTIMATED TO BE NEAR (\d+) MB", b)
        pot = re.search(r"POTENTIAL FOR THE DEVELOPMENT.*?(LOW|MEDIUM|HIGH)", b)
        out.append({
            "id": m.group(1),
            "lat": float(pos.group(1)) * (-1 if pos.group(2) == "S" else 1),
            "lon": float(pos.group(3)) * (-1 if pos.group(4) == "W" else 1),
            "wind_kt": [int(w.group(1)), int(w.group(2) or w.group(1))] if w else None,
            "mslp": int(p.group(1)) if p else None,
            "potential": pot.group(1) if pot else None,
            "issued": issued.isoformat() if issued else None,
        })
    return out


def latest_invest(num):
    """Latest JTWC position of Invest <num> (e.g. 92 -> 92B / 92A / 92S)."""
    _, _, raw = http(JTWC + "products/abioweb.txt", timeout=30)
    num = str(num).upper()
    for inv in parse_abio(raw.decode("utf-8", "replace")):
        if inv["id"] == num or inv["id"][:2] == num:
            return inv
    return None


# ------------------------------------------------------------------ Google access

_tok = {"v": None, "at": 0}


def gcloud_bin():
    return shutil.which("gcloud") or shutil.which("gcloud.cmd")


def access_token():
    if os.environ.get("CW_GOOGLE_TOKEN"):
        return os.environ["CW_GOOGLE_TOKEN"]
    if _tok["v"] and time.time() - _tok["at"] < 45 * 60:
        return _tok["v"]
    g = gcloud_bin()
    if not g:
        raise RuntimeError("Google Cloud CLI (gcloud) not found. Install it, then run: gcloud auth application-default login")
    errs = []
    for args in (["auth", "application-default", "print-access-token"], ["auth", "print-access-token"]):
        try:
            r = subprocess.run([g] + args, capture_output=True, text=True, timeout=60)
            if r.returncode == 0 and r.stdout.strip():
                _tok.update(v=r.stdout.strip().splitlines()[-1], at=time.time())
                return _tok["v"]
            errs.append(r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "no token")
        except Exception as e:  # noqa: BLE001
            errs.append(str(e))
    raise RuntimeError("Not signed in to Google. Run: gcloud auth application-default login  (" + "; ".join(errs) + ")")


def billing_project():
    if CFG.get("billing_project"):
        return CFG["billing_project"]
    g = gcloud_bin()
    if g:
        r = subprocess.run([g, "config", "get-value", "project"], capture_output=True, text=True, timeout=30)
        v = r.stdout.strip()
        if v and "unset" not in v:
            return v
    raise RuntimeError('No Google Cloud project set. Run: gcloud config set project YOUR_PROJECT  (or put "billing_project" in local/config.json)')


def bq_get(path):
    _, _, raw = http(BQ + path, headers={"Authorization": "Bearer " + access_token()})
    return json.loads(raw)


def bq_query(sql, project):
    tok = {"Authorization": "Bearer " + access_token()}
    _, _, raw = http(f"{BQ}/projects/{project}/queries", {
        "query": sql, "useLegacySql": False, "timeoutMs": 90000, "maxResults": 100000}, tok, timeout=150)
    res = json.loads(raw)
    job = res["jobReference"]
    loc = job.get("location")
    while not res.get("jobComplete"):
        time.sleep(2)
        q = urllib.parse.urlencode({k: v for k, v in {"timeoutMs": 60000, "maxResults": 100000, "location": loc}.items() if v})
        res = bq_get(f"/projects/{job['projectId']}/queries/{job['jobId']}?{q}")
    fields = [f["name"] for f in res["schema"]["fields"]]
    rows = list(res.get("rows", []))
    tokn = res.get("pageToken")
    while tokn:
        q = urllib.parse.urlencode({k: v for k, v in {"pageToken": tokn, "maxResults": 100000, "location": loc}.items() if v})
        page = bq_get(f"/projects/{job['projectId']}/queries/{job['jobId']}?{q}")
        rows += page.get("rows", [])
        tokn = page.get("pageToken")
    return [dict(zip(fields, [c["v"] for c in r["f"]])) for r in rows]


def friendly(e):
    if isinstance(e, urllib.error.HTTPError):
        try:
            msg = json.loads(e.read())["error"]["message"]
        except Exception:  # noqa: BLE001
            msg = str(e)
        if e.code in (401, 403):
            return f"Google refused access ({e.code}): {msg}"
        return f"BigQuery error {e.code}: {msg}"
    return str(e)


# ------------------------------------------------------------------ WeatherNext table discovery

_table = {}


def find_table():
    """Pick the WeatherNext table: from config, else search the billing project's datasets."""
    if _table:
        return _table
    proj = billing_project()
    full = CFG.get("weathernext_table")
    if not full:
        cands = []
        for ds in bq_get(f"/projects/{proj}/datasets?all=true&maxResults=1000").get("datasets", []):
            d = ds["datasetReference"]
            for t in bq_get(f"/projects/{d['projectId']}/datasets/{d['datasetId']}/tables?maxResults=1000").get("tables", []):
                tid = t["tableReference"]["tableId"]
                if tid.startswith("weathernext"):
                    cands.append(f"{d['projectId']}.{d['datasetId']}.{tid}")

        def rank(n):  # newest version first, prefer full-resolution statistics tables
            v = re.findall(r"weathernext_(\d+)", n)
            return (int(v[0]) if v else 0, "0p1deg" in n, n.endswith("_mean"))
        cands.sort(key=rank, reverse=True)
        if not cands:
            raise RuntimeError(
                f"No WeatherNext table found in project {proj}. Subscribe to the WeatherNext listing in BigQuery "
                'Analytics Hub, or set "weathernext_table": "project.dataset.table" in local/config.json')
        full = cands[0]
    p, d, t = full.split(".")
    schema = bq_get(f"/projects/{p}/datasets/{d}/tables/{t}")["schema"]["fields"]
    fc = next((f for f in schema if f["name"] == "forecast"), None)
    if not fc:
        raise RuntimeError(f"{full} has no 'forecast' column; is it a WeatherNext forecast table?")
    names = [f["name"] for f in fc.get("fields", [])]

    def pick(*pats):
        for pat in pats:
            for n in names:
                if re.fullmatch(pat, n):
                    return n
        return None
    mslp = pick(r"mean_sea_level_pressure_mean", r"mean_sea_level_pressure", r"mean_sea_level_pressure.*")
    spd = pick(r"wind_speed_10m_mean", r"wind_speed_10m", r"10m_wind_speed.*")
    u = pick(r"u_component_of_wind_10m_mean", r"10m_u_component_of_wind(_mean)?", r"u_component_of_wind_10m.*")
    v = pick(r"v_component_of_wind_10m_mean", r"10m_v_component_of_wind(_mean)?", r"v_component_of_wind_10m.*")
    if not mslp:
        raise RuntimeError(f"{full}: no mean sea level pressure field in forecast ({', '.join(names[:12])}…)")
    wind = f"f.`{spd}`" if spd else (f"SQRT(POW(f.`{u}`,2)+POW(f.`{v}`,2))" if u and v else "NULL")
    _table.update(full=full, project=proj, mslp=mslp, wind=wind, hours="hours" in names,
                  version=(re.findall(r"weathernext_[\w]+", t) or [t])[0])
    return _table


# ------------------------------------------------------------------ track from the model fields

_cache = {}


def latest_init(tb):
    rows = bq_query(f"""
      SELECT MAX(init_time) AS init FROM `{tb['full']}`
      WHERE init_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 3 DAY)
        AND MOD(EXTRACT(HOUR FROM init_time), 6) = 0""", tb["project"])
    v = rows[0]["init"] if rows else None
    if not v:
        raise RuntimeError(f"{tb['full']}: no forecast run in the last 3 days")
    return datetime.fromtimestamp(float(v), timezone.utc)


def fetch_fields(tb, init):
    lead = "f.hours" if tb["hours"] else "CAST(TIMESTAMP_DIFF(f.time, t.init_time, HOUR) AS INT64)"
    sql = f"""
      SELECT {lead} AS h,
             CAST(FLOOR(ST_Y(t.geography)/{BIN}) AS INT64) AS iy,
             CAST(FLOOR(ST_X(t.geography)/{BIN}) AS INT64) AS ix,
             MIN(f.`{tb['mslp']}`) AS p,
             MAX({tb['wind']}) AS w
      FROM `{tb['full']}` AS t, t.forecast AS f
      WHERE t.init_time = TIMESTAMP('{init.strftime('%Y-%m-%d %H:%M:%S')} UTC')
        AND ST_INTERSECTS(t.geography, ST_GEOGFROMTEXT(
          'POLYGON(({BOX['lon0']} {BOX['lat0']}, {BOX['lon1']} {BOX['lat0']}, {BOX['lon1']} {BOX['lat1']}, {BOX['lon0']} {BOX['lat1']}, {BOX['lon0']} {BOX['lat0']}))'))
        AND MOD({lead}, {STEP_H}) = 0 AND {lead} <= {MAX_H}
      GROUP BY h, iy, ix"""
    grid = {}
    for r in bq_query(sql, tb["project"]):
        if r["p"] is None:
            continue
        p = float(r["p"])
        grid.setdefault(int(r["h"]), {})[(int(r["iy"]), int(r["ix"]))] = (p / 100 if p > 2000 else p, float(r["w"]) if r["w"] is not None else None)
    return grid


def km(a1, o1, a2, o2):
    r = math.pi / 180
    s = math.sin((a2 - a1) * r / 2) ** 2 + math.cos(a1 * r) * math.cos(a2 * r) * math.sin((o2 - o1) * r / 2) ** 2
    return 12742 * math.asin(math.sqrt(s))


def track(grid, lat, lon, init):
    """Follow the pressure minimum from the given start point, step by step."""
    pts = []
    guess = (lat, lon)
    misses = 0
    for h in sorted(grid):
        g = grid[h]
        radius = 300 if pts else 350
        near = [((iy + .5) * BIN, (ix + .5) * BIN, v) for (iy, ix), v in g.items()
                if km(guess[0], guess[1], (iy + .5) * BIN, (ix + .5) * BIN) <= radius]
        if not near:
            break
        cy, cx, (p, _) = min(near, key=lambda q: q[2][0])
        ring = [v[0] for (y, x, v) in near if 250 <= km(cy, cx, y, x) <= 500] or \
               [v[0] for (iy, ix), v in g.items() if 250 <= km(cy, cx, (iy + .5) * BIN, (ix + .5) * BIN) <= 500]
        depth = (sum(ring) / len(ring) - p) if ring else 0
        edge = km(guess[0], guess[1], cy, cx) > radius * 0.85
        if pts and (depth < 0.8 or edge):
            misses += 1
            if misses >= 2:
                break
            continue
        misses = 0
        wmax = max((v[1] for (iy, ix), v in g.items() if v[1] is not None
                    and km(cy, cx, (iy + .5) * BIN, (ix + .5) * BIN) <= 220), default=None)
        pts.append({"h": h, "t": int((init.timestamp() + h * 3600) * 1000), "lat": round(cy, 2), "lon": round(cx, 2),
                    "p": round(p, 1), "depth": round(depth, 1),
                    "kt": round(wmax * 1.94384) if wmax is not None else None})
        if len(pts) >= 2:  # first guess for the next step: keep the latest motion
            a, b = pts[-2], pts[-1]
            k = STEP_H / max(STEP_H, b["h"] - a["h"])
            guess = (b["lat"] + (b["lat"] - a["lat"]) * k, b["lon"] + (b["lon"] - a["lon"]) * k)
        else:
            guess = (cy, cx)
    return pts


def google_track(lat, lon):
    tb = find_table()
    init = latest_init(tb)
    key = (tb["full"], init.isoformat(), round(lat, 1), round(lon, 1))
    if key in _cache:
        return _cache[key]
    if init.isoformat() not in _cache:
        _cache.clear()
        _cache[init.isoformat()] = fetch_fields(tb, init)
    pts = track(_cache[init.isoformat()], lat, lon, init)
    out = {"ok": True, "model": "Google WeatherNext", "table": tb["full"], "version": tb["version"],
           "init": int(init.timestamp() * 1000), "start": {"lat": lat, "lon": lon}, "track": pts}
    _cache[key] = out
    return out


# ------------------------------------------------------------------ web server

class Handler(BaseHTTPRequestHandler):
    server_version = "CycloneWatchLocal/1.0"

    def log_message(self, fmt, *args):
        if os.environ.get("CW_VERBOSE"):
            super().log_message(fmt, *args)

    def send(self, code, body, ctype="application/json; charset=utf-8", extra=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        u = urllib.parse.urlparse(self.path)
        q = dict(urllib.parse.parse_qsl(u.query))
        path = u.path
        try:
            if path in ("/", "/index.html"):
                return self.page("index.html")
            if path == "/film.html":
                return self.page("film.html")
            if path.startswith("/jtwc/"):
                return self.jtwc(path[len("/jtwc/"):])
            if path == "/api/google/track":
                return self.send(200, google_track(float(q["lat"]), float(q["lon"])))
            if path == "/api/google/invest":
                inv = latest_invest(q.get("id", "92"))
                if not inv:
                    return self.send(404, {"ok": False, "error": "Invest %s is not in the latest JTWC advisory" % q.get("id", "92")})
                out = dict(google_track(inv["lat"], inv["lon"]))
                out["invest"] = inv
                return self.send(200, out)
            if path == "/api/google/status":
                tb = find_table()
                return self.send(200, {"ok": True, "table": tb["full"], "version": tb["version"], "project": tb["project"]})
            return self.send(404, {"error": "not found"})
        except KeyError as e:
            return self.send(400, {"ok": False, "error": "missing parameter " + str(e)})
        except Exception as e:  # noqa: BLE001
            return self.send(502 if path.startswith("/jtwc/") else 200, {"ok": False, "error": friendly(e)})

    def page(self, name):
        with open(os.path.join(ASSETS, name), encoding="utf-8") as f:
            html = f.read()
        inject = '<script>window.CW_LOCAL={google:true};</script>'
        if name == "index.html":  # lets phones add it to the home screen as an app
            inject += ('<meta name="apple-mobile-web-app-capable" content="yes">'
                       '<meta name="mobile-web-app-capable" content="yes">'
                       '<meta name="theme-color" content="#07111B">')
        html = html.replace("<head>", "<head>\n" + inject, 1)
        self.send(200, html, "text/html; charset=utf-8")

    def jtwc(self, rest):
        if not re.fullmatch(r"[A-Za-z0-9_./-]+", rest) or ".." in rest:
            return self.send(400, {"error": "bad path"})
        try:
            code, hdr, raw = http(JTWC + rest, timeout=30)
        except urllib.error.HTTPError as e:
            return self.send(e.code, e.read() or b"", "text/plain")
        self.send(code, raw, hdr.get("Content-Type", "text/plain"))


def lan_ip():
    """This computer's address on the local network (no traffic is sent)."""
    import socket
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("192.0.2.1", 80))
        return s.getsockname()[0]
    except OSError:
        return None
    finally:
        s.close()


def print_invest(num):
    print(f"Looking up Invest {num} in the latest JTWC advisory…")
    inv = latest_invest(num)
    if not inv:
        print(f"Invest {num} is not listed in the latest JTWC Indian Ocean advisory.")
        return 1
    w = inv["wind_kt"]
    line = f"  Invest {inv['id']}: {abs(inv['lat']):.1f}°{'S' if inv['lat'] < 0 else 'N'} {inv['lon']:.1f}°E"
    if w:
        line += f" · winds {w[0]}–{w[1]} kt"
    if inv["mslp"]:
        line += f" · {inv['mslp']} hPa"
    if inv["potential"]:
        line += f" · chance of a cyclone within 24 h: {inv['potential'].lower()}"
    print(line + f"  (JTWC {inv['issued']})")
    print("Asking Google WeatherNext for its latest run…")
    try:
        g = google_track(inv["lat"], inv["lon"])
    except Exception as e:  # noqa: BLE001
        print("  ! " + friendly(e))
        return 2
    init = datetime.fromtimestamp(g["init"] / 1000, timezone.utc)
    print(f"  {g['table']} · run {init:%Y-%m-%d %H} UTC · {len(g['track'])} points\n")
    print("  lead   time (UTC)         lat     lon     hPa    wind kt")
    for p in g["track"]:
        t = datetime.fromtimestamp(p["t"] / 1000, timezone.utc)
        print(f"  {p['h']:>3} h  {t:%a %d %b %H:%M}   {p['lat']:5.1f}N  {p['lon']:5.1f}E  {p['p']:6.1f}  {p['kt'] if p['kt'] is not None else '–':>5}")
    if g["track"]:
        lo = min(g["track"], key=lambda p: p["p"])
        print(f"\n  Deepest: {lo['p']:.0f} hPa at +{lo['h']} h near {lo['lat']:.1f}N {lo['lon']:.1f}E")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--invest", help="print Google WeatherNext's latest track for this invest number (e.g. 92) and exit")
    ap.add_argument("--port", type=int, default=int(CFG.get("port") or 8765))
    ap.add_argument("--no-browser", action="store_true", help="do not open the browser")
    ap.add_argument("--phone", action="store_true",
                    help="also serve phones and tablets on the same Wi-Fi (prints the address to open on the phone)")
    a = ap.parse_args()
    if a.invest:
        sys.exit(print_invest(a.invest))
    if not os.path.exists(os.path.join(ASSETS, "index.html")):
        sys.exit("Dashboard not found at " + ASSETS)
    srv = None
    for port in range(a.port, a.port + 20):
        try:
            srv = ThreadingHTTPServer(("0.0.0.0" if a.phone else "127.0.0.1", port), Handler)
            break
        except OSError:
            continue
    if not srv:
        sys.exit("No free port near %d" % a.port)
    url = "http://127.0.0.1:%d/" % srv.server_address[1]
    print("Cyclone Watch is running at", url)
    if a.phone:
        ip = lan_ip()
        print()
        print("  On your phone (same Wi-Fi), open:  http://%s:%d/" % (ip or "<this computer's IP>", srv.server_address[1]))
        print("  If it does not load, allow Python through this computer's firewall (Windows asks the first time).")
        print("  Anyone on this Wi-Fi can open it, and its Google WeatherNext queries are billed to your project.")
        print()
    print("Keep this window open while you use it. Press Ctrl+C to stop.")
    if not a.no_browser:
        threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()

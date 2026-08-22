#!/usr/bin/env python3
"""
A stand-in for the OpenF1 REST API, served from an archived session.

Why this exists
---------------
Developing against the real API costs a race weekend of waiting. A session is
live for an hour a fortnight; outside that window `car_data` and `location` for
the moment you care about are gone, the free tier is capped at 3 requests a
second, and during any live session the whole API -- past sessions included --
is closed to unauthenticated callers. None of that is a good loop to write code
in.

`Formula1Backend.OpenF1BaseUrl` was always documented as "override to point at a
mirror or a recording". This is the recording. Point the constant here and the
entire sync runs unchanged, at whatever speed the disk allows:

    scripts/openf1-mock.py --port 8099 &
    cd Formula1Backend && ./mxcli constant set \\
        Formula1Backend.OpenF1BaseUrl http://localhost:8099/v1 -p Formula1Backend.mpr --apply

What it serves
--------------
Whatever `scripts/archive-session.sh` wrote: one file per whole-session
endpoint, and one file per time window for car_data and location. Requests are
answered from those files, including the `date>=` / `date<=` filtering the sync
depends on, so a window that spans several archived files is stitched back
together and re-filtered rather than returned whole.

Deliberate fidelity choices, because the sync has been bitten by all three:
  * a filter that matches nothing answers 404, not [] -- OpenF1 does that, and
    Sync_Fetch treats it as "no rows" rather than as an error
  * an unknown session answers 404
  * `--rate N` optionally enforces N requests/second and answers 429 beyond it,
    so pacing can be tested without waiting for the real limiter
"""
import argparse, glob, gzip, json, os, re, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data", "openf1")
WINDOWED = ("car_data", "location")


def load(path):
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt") as fh:
        return json.load(fh)


def find(session, endpoint):
    """Every archived file for one endpoint of one session."""
    base = os.path.join(ROOT, str(session))
    if endpoint in WINDOWED:
        return sorted(glob.glob(os.path.join(base, endpoint, "*.json*")))
    hits = glob.glob(os.path.join(base, endpoint + ".json*"))
    return sorted(hits)


def rows_for(session, endpoint):
    out = []
    for f in find(session, endpoint):
        try:
            d = load(f)
        except Exception:
            continue
        out.extend(d if isinstance(d, list) else [d])
    return out


OPS = [(">=", "ge"), ("<=", "le"), (">", "gt"), ("<", "lt")]


def apply_filters(rows, params):
    """OpenF1 puts the operator in the value: date>=..., driver_number=44."""
    for key, values in params.items():
        for raw in values:
            val = unquote(raw)
            op = "eq"
            for sym, name in OPS:
                if val.startswith(sym):
                    op, val = name, val[len(sym):]
                    break
            # OpenF1 writes `date>=X`, which percent-encodes to `date%3E=X`.
            # The `=` is then the key/value separator, so parse_qs hands back
            # the key `date>` -- the operator is inclusive even though only the
            # `>` survives. Reading it as a strict `>` drops every row in the
            # first second of a window.
            k = key
            for sym, name in (("<", "le"), (">", "ge")):
                if k.endswith(sym):
                    op, k = name, k[: -1]
                    break
            if k in ("session_key", "meeting_key"):
                continue
            def keep(r, k=k, op=op, val=val):
                if k not in r or r[k] is None:
                    return False
                a, b = r[k], val
                if isinstance(a, (int, float)):
                    try:
                        b = float(val)
                    except ValueError:
                        return False
                else:
                    a, b = str(a), str(val)
                    # ISO-8601 compares correctly as plain text, and must NOT be
                    # truncated to the filter's length first: that throws away
                    # the sub-second part, so 10:15:00.078 reads as exactly
                    # 10:15:00 and falls out of its own window.
                    if op == "eq" and len(a) > len(b):
                        a = a[:len(b)]
                return {"eq": a == b, "ge": a >= b, "le": a <= b,
                        "gt": a > b, "lt": a < b}[op]
            rows = [r for r in rows if keep(r)]
    return rows


class Handler(BaseHTTPRequestHandler):
    rate = 0
    _hits = []

    def log_message(self, *a):
        pass

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        m = re.match(r"^/v1/([a-z_]+)/?$", u.path)
        if not m:
            return self._send(404, {"detail": "Not Found"})
        endpoint = m.group(1)
        params = parse_qs(u.query, keep_blank_values=True)

        if self.rate:
            now = time.time()
            Handler._hits = [t for t in Handler._hits if now - t < 1.0]
            if len(Handler._hits) >= self.rate:
                return self._send(429, {
                    "detail": "Rate limit exceeded. Max %d requests/second." % self.rate,
                    "error": "Too Many Requests"})
            Handler._hits.append(now)

        sessions = params.get("session_key") or params.get("meeting_key")
        if not sessions:
            avail = sorted(os.path.basename(p) for p in glob.glob(os.path.join(ROOT, "*")))
            return self._send(404, {"detail": "mock needs session_key; archived: %s" % avail})
        session = unquote(sessions[0])
        if session == "latest":
            archived = sorted(os.path.basename(p) for p in glob.glob(os.path.join(ROOT, "*")))
            if not archived:
                return self._send(404, {"detail": "nothing archived"})
            session = archived[-1]

        rows = rows_for(session, endpoint)
        if not rows:
            return self._send(404, {"detail": "No results found."})
        rows = apply_filters(rows, params)
        if not rows:
            return self._send(404, {"detail": "No results found."})
        self._send(200, rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8099)
    ap.add_argument("--rate", type=int, default=0,
                    help="requests/second before answering 429 (0 = unlimited)")
    a = ap.parse_args()
    Handler.rate = a.rate
    have = sorted(os.path.basename(p) for p in glob.glob(os.path.join(ROOT, "*")))
    print("openf1 mock on http://localhost:%d/v1  sessions: %s%s"
          % (a.port, ", ".join(have) or "none",
             "  rate-limited to %d/s" % a.rate if a.rate else ""))
    ThreadingHTTPServer(("127.0.0.1", a.port), Handler).serve_forever()


if __name__ == "__main__":
    main()

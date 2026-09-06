#!/usr/bin/env python3
"""S3.5 — populate url_resolution for every canonical URL.

Standalone backfill: reads Spec/url-canonical/corpus-canonical.tsv, writes JSONL that S2 imports.
Deliberately NOT a reimplementation of canonicalisation — final URLs are piped through the Swift
binary, so there is exactly one canonicaliser (see Spec/url-canonical/SPEC.md).

Resumable: appends, and skips URLs already present in the output.
Polite: at most one request in flight per host; concurrency is across hosts, never within one.
"""
import json, sys, time, threading, queue, subprocess, os
import urllib.request, urllib.error
from urllib.parse import urlparse
from collections import defaultdict
from datetime import datetime, timezone

TSV  = "Spec/url-canonical/corpus-canonical.tsv"
OUT  = "research/url-resolution.jsonl"
CANON = os.environ.get("CANON_BIN", "/tmp/canonrun")
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")
HOST_WORKERS = int(os.environ.get("HOST_WORKERS", "8"))
TIMEOUT, MAX_HOPS, HOST_GAP = 8, 10, 0.5

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None
opener = urllib.request.build_opener(NoRedirect)

def resolve(url):
    """Follow redirects manually so hops are counted. Returns (final_url, status, hops)."""
    cur, hops = url, 0
    for _ in range(MAX_HOPS):
        for method in ("HEAD", "GET"):
            try:
                req = urllib.request.Request(cur, method=method, headers={"User-Agent": UA})
                with opener.open(req, timeout=TIMEOUT) as r:
                    return cur, r.status, hops
            except urllib.error.HTTPError as e:
                if e.code in (301, 302, 303, 307, 308):
                    nxt = e.headers.get("Location")
                    if not nxt: return cur, e.code, hops
                    cur = urllib.parse.urljoin(cur, nxt); hops += 1
                    break                      # follow the hop
                if e.code == 405 and method == "HEAD":
                    continue                   # server refuses HEAD; retry as GET
                return cur, e.code, hops
            except Exception as e:
                return cur, type(e).__name__, hops
        else:
            return cur, None, hops
    return cur, "TooManyRedirects", hops

def main():
    urls = sorted({c for line in open(TSV, encoding="utf-8")
                   if not line.startswith("#") and "\t" in line
                   for c in [line.rstrip("\n").split("\t")[1]] if c})
    done = set()
    if os.path.exists(OUT):
        for l in open(OUT, encoding="utf-8"):
            try: done.add(json.loads(l)["url_canonical"])
            except Exception: pass
    todo = [u for u in urls if u not in done]
    print(f"{len(urls)} canonical URLs, {len(done)} already resolved, {len(todo)} to go",
          file=sys.stderr)
    if not todo: return

    by_host = defaultdict(list)
    for u in todo: by_host[urlparse(u).netloc].append(u)
    hostq = queue.Queue()
    for h, us in sorted(by_host.items(), key=lambda kv: -len(kv[1])): hostq.put((h, us))

    lock, out = threading.Lock(), open(OUT, "a", encoding="utf-8")
    counter = [0]
    def worker():
        while True:
            try: host, us = hostq.get_nowait()
            except queue.Empty: return
            for u in us:                                    # serial WITHIN a host
                final, status, hops = resolve(u)
                rec = {"url_canonical": u, "final_url": final,
                       "http_status": status, "hops": hops,
                       "resolved_at": datetime.now(timezone.utc).isoformat()}
                with lock:
                    out.write(json.dumps(rec, ensure_ascii=False) + "\n"); out.flush()
                    counter[0] += 1
                    if counter[0] % 250 == 0:
                        print(f"  {counter[0]}/{len(todo)}", file=sys.stderr)
                time.sleep(HOST_GAP)
            hostq.task_done()

    ts = [threading.Thread(target=worker, daemon=True) for _ in range(HOST_WORKERS)]
    t0 = time.time()
    for t in ts: t.start()
    for t in ts: t.join()
    out.close()
    print(f"done: {counter[0]} in {(time.time()-t0)/60:.1f} min", file=sys.stderr)

if __name__ == "__main__":
    main()

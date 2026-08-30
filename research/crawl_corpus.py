#!/usr/bin/env python3
"""Polite backfill crawler for one public channel -> JSONL. Research probe only."""
import re, json, time, sys, html, base64, urllib.request, urllib.parse

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8", "replace")

def text_of(frag):
    frag = re.sub(r'<br\s*/?>', '\n', frag)
    return html.unescape(re.sub(r'<[^>]+>', '', frag)).strip()

def parse(page):
    starts = [m.start() for m in re.finditer(r'<div class="tgme_widget_message_wrap', page)]
    out = []
    for s, e in zip(starts, starts[1:] + [len(page)]):
        b = page[s:e]
        pm = re.search(r'data-post="([^"/]+)/(\d+)"', b)
        if not pm: continue
        chan, pid = pm.group(1), int(pm.group(2))
        raw_chan = None
        dv = re.search(r'data-view="([^"]+)"', b)
        if dv:
            t = dv.group(1) + "=" * (-len(dv.group(1)) % 4)
            try: raw_chan = json.loads(base64.b64decode(t)).get("c")
            except Exception: pass
        tm = re.search(r'<time datetime="([^"]+)"', b)
        au = re.search(r'tgme_widget_message_owner_name[^>]*>(.*?)</a>', b, re.S)
        # NB: two blocks share the class `tgme_widget_message_text`. The reply-quote block is
        # `js-message_reply_text` (Telegram truncates it to ~256 chars); the real body is
        # `js-message_text`. Matching the class prefix alone silently harvests the quote.
        tx = re.search(r'tgme_widget_message_text js-message_text"[^>]*>(.*?)</div>', b, re.S)
        body = text_of(tx.group(1)) if tx else ""
        rq = re.search(r'<a class="tgme_widget_message_reply"[^>]*href="[^"]*?/(\d+)"', b)
        reply_to = int(rq.group(1)) if rq else None
        if reply_to is None and 'js-message_reply_text' in b:
            m2 = re.search(r'href="https://t\.me/[^"/]+/(\d+)"[^>]*>\s*(?:<i|<div class="tgme_widget_message_author)', b, re.S)
            reply_to = int(m2.group(1)) if m2 else -1   # -1 = reply detected, target unresolved
        # hashtags are relative ?q=%23 links; external links are absolute
        tags = [urllib.parse.unquote(x) for x in re.findall(r'href="\?q=%23([^"]+)"', b)]
        links = [u for u in re.findall(r'href="(https?://[^"]+)"', (tx.group(1) if tx else ""))]
        prev = re.search(r'tgme_widget_message_link_preview" href="([^"]+)"', b)
        pv = {}
        if prev:
            pv["url"] = html.unescape(prev.group(1))
            for k, cls in (("site","link_preview_site_name"),("title","link_preview_title"),("desc","link_preview_description")):
                m = re.search(r'"'+cls+r'"[^>]*>(.*?)</div>', b, re.S)
                if m: pv[k] = text_of(m.group(1))
        rx = re.search(r'js-message_reactions">(.*?)</div>', b, re.S)
        reacts = []
        if rx:
            for sp in re.split(r'(?=<span class="tgme_reaction)', rx.group(1)):
                if "tgme_reaction" not in sp: continue
                emo = re.search(r'<b>([^<]*)</b>', sp)
                cnt = re.sub(r'^\D*', '', re.sub(r'<[^>]+>', '', sp).strip())
                reacts.append({"emoji": "⭐" if "tgme_reaction_paid" in sp else (emo.group(1) if emo else "?"),
                               "count": int(re.sub(r'[^\d]', '', cnt) or 0),
                               "paid": "tgme_reaction_paid" in sp})
        out.append({"channel": chan, "id": pid, "raw_channel_id": raw_chan,
                    "date": tm.group(1) if tm else None,
                    "author": text_of(au.group(1)) if au else None,
                    "text": body, "hashtags": tags, "links": links, "reply_to": reply_to,
                    "preview": pv or None, "reactions": reacts,
                    "url": f"https://t.me/{chan}/{pid}"})
    return out

def crawl(chan, max_pages=40, delay=1.0):
    seen, cursor = {}, None
    for i in range(max_pages):
        url = f"https://t.me/s/{chan}" + (f"?before={cursor}" if cursor else "")
        msgs = parse(fetch(url))
        if not msgs: break
        new = [m for m in msgs if m["id"] not in seen]
        for m in msgs: seen[m["id"]] = m
        lo = min(m["id"] for m in msgs)
        print(f"  page {i+1}: {len(msgs)} msgs, ids {lo}..{max(m['id'] for m in msgs)}, "
              f"{len(new)} new, total {len(seen)}", file=sys.stderr)
        if cursor is not None and lo >= cursor: break   # no progress -> stop
        cursor = lo
        if lo <= 1: break
        time.sleep(delay)
    return [seen[k] for k in sorted(seen)]

if __name__ == "__main__":
    ch = sys.argv[1] if len(sys.argv) > 1 else "swiftui_dev"
    rows = crawl(ch, max_pages=int(sys.argv[2]) if len(sys.argv) > 2 else 40)
    with open(f"fixtures/{ch}.jsonl", "w", encoding="utf-8") as f:
        for r in rows: f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"wrote {len(rows)} posts -> fixtures/{ch}.jsonl", file=sys.stderr)

#!/usr/bin/env bash
# Reproduces the empirical probes behind research/web-preview-probe.md.
# Read-only; polite by default (1s between requests). Usage: ./probe.sh [channel]
set -uo pipefail
CH="${1:-swiftui_dev}"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
DELAY="${DELAY:-1}"

get() { curl -sS --max-time 25 -A "$UA" "$@"; }
u()   { python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$1"; }

# Print "<http-code> n=<count> ids: <ids…>" for a preview URL.
probe() {
  local body code ids
  body=$(get -w '\n#HTTP:%{http_code}' "$1")
  code=$(printf '%s' "$body" | tail -1 | sed 's/#HTTP://')
  ids=$(printf '%s' "$body" | grep -oE 'data-post="[^"]+"' | grep -oE '/[0-9]+' | tr -d '/' | tr '\n' ' ')
  printf '[%s] http=%s n=%s ids: %s\n' "$2" "$code" "$(printf '%s' "$ids" | wc -w | tr -d ' ')" "$ids"
  sleep "$DELAY"
}

echo "### robots.txt (expect 404 — no robots.txt exists)"
get -o /dev/null -w 'HTTP %{http_code}\n' https://t.me/robots.txt; sleep "$DELAY"

echo; echo "### availability + 302 classification"
code=$(get -o /dev/null -w '%{http_code}' "https://t.me/s/$CH"); sleep "$DELAY"
echo "https://t.me/s/$CH -> $code"
if [ "$code" != "200" ]; then
  echo "  not previewable; classifying via plain page:"
  get -L "https://t.me/$CH" | python3 -c '
import sys,re,html
h=sys.stdin.read()
for cls in ("tgme_page_title","tgme_page_extra","tgme_page_description"):
    for m in re.finditer(r"<div class=\""+cls+r"\"[^>]*>(.*?)</div>",h,re.S):
        t=html.unescape(re.sub(r"<[^>]+>","",m.group(1))).strip()
        if t: print(f"    {cls}: {t[:140]}")'
  exit 0
fi

echo; echo "### pagination (ids are non-contiguous; page size varies)"
probe "https://t.me/s/$CH"             "default"
probe "https://t.me/s/$CH?before=20"   "before=20 (history floor)"

echo; echo "### search semantics via undocumented ?q="
probe "https://t.me/s/$CH?q=animation" "latin full word"
probe "https://t.me/s/$CH?q=anim"      "latin PREFIX  (expect: same set)"
probe "https://t.me/s/$CH?q=imation"   "latin SUBSTR  (expect: 0)"
probe "https://t.me/s/$CH?q=$(u навигация)" "cyrillic full word"
probe "https://t.me/s/$CH?q=$(u навигац)"   "cyrillic stem  (expect: same set)"
probe "https://t.me/s/$CH?q=$(u навига)"    "cyrillic short prefix (expect: 0)"

echo; echo "### per-message field extraction (first 3 messages)"
get "https://t.me/s/$CH" | python3 -c '
import sys,re,html,base64,json
h=sys.stdin.read()
starts=[m.start() for m in re.finditer(r"<div class=\"tgme_widget_message_wrap",h)]
def one(p,b):
    m=re.search(p,b,re.S); 
    return html.unescape(re.sub(r"<[^>]+>","",m.group(1))).strip() if m else None
for s,e in list(zip(starts,starts[1:]+[len(h)]))[:3]:
    b=h[s:e]
    post=re.search(r"data-post=\"([^\"]+)\"",b)
    dv=re.search(r"data-view=\"([^\"]+)\"",b)
    chan=None
    if dv:
        raw=dv.group(1); raw+="="*(-len(raw)%4)
        try: chan=json.loads(base64.b64decode(raw)).get("c")
        except Exception: pass
    print("post      :",post.group(1) if post else None)
    print("raw chan  :",chan)
    print("date      :",(re.search(r"<time datetime=\"([^\"]+)\"",b) or [None,None])[1] if re.search(r"<time datetime=\"([^\"]+)\"",b) else None)
    print("author    :",one(r"tgme_widget_message_owner_name[^>]*>(.*?)</a>",b))
    print("views     :",one(r"tgme_widget_message_views\"[^>]*>(.*?)</span>",b))
    txt=one(r"tgme_widget_message_text[^>]*>(.*?)</div>",b) or ""
    print("text      :",txt[:100].replace("\n"," "))
    rx=re.search(r"js-message_reactions\">(.*?)</div>",b,re.S)
    reacts=[]
    if rx:
        for sp in re.split(r"(?=<span class=\"tgme_reaction)",rx.group(1)):
            if "tgme_reaction" not in sp: continue
            emo=re.search(r"<b>([^<]*)</b>",sp)
            cnt=re.sub(r"^\D*","",re.sub(r"<[^>]+>","",sp).strip())
            reacts.append(("STAR" if "tgme_reaction_paid" in sp else (emo.group(1) if emo else "?"),cnt))
    print("reactions :",reacts)
    prev=re.search(r"tgme_widget_message_link_preview\" href=\"([^\"]+)\"",b)
    print("link prev :",prev.group(1)[:90] if prev else None)
    print("-"*60)'

#!/usr/bin/env python3
"""Grades a Claude model on evals/tgkb-mcp/eval.xml, through tgkb-mcp and nothing else.

The mcp-builder skill's evaluation (anthropics/skills, mcp-builder/reference/evaluation.md): ten
questions a model answers using only the server's tools, each graded by exact string comparison.
Its own harness calls the API with a key; this one drives Claude Code headless (`claude -p`), so it
runs on whatever login the CLI has, and the model sees the tools exactly as a Claude client presents
them.

    Scripts/run_mcp_eval.py [--out DIR] [--claude PATH] [--model NAME] [--only 3,7] [--server BIN]

1. Writes the synthetic corpus into a fresh store (EvalCorpusTests, with TGKB_EVAL_STORE set).
2. Builds tgkb-mcp — or takes --server, an older build to compare against — and registers it for
   each run with --mcp-config --strict-mcp-config, so no MCP configuration is persisted anywhere,
   and with --tools "" so no built-in tool can answer.
3. Asks each question in its own session; keeps every transcript in DIR; prints and writes a report.

Accuracy is a measurement, not a gate: the exit status says whether the run worked, not how well
the model did.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EVAL = ROOT / "evals" / "tgkb-mcp" / "eval.xml"
# Every tool of the one server, whatever a given build names them.
ALLOWED = "mcp__tgkb"

PROMPT = """Answer the question below using only the tgkb tools, which search a local archive of \
Telegram posts. Then:
- in <summary></summary>, list the tool calls you made and what each returned that mattered;
- in <feedback></feedback>, say specifically what about the tools' names, descriptions, \
parameters or results helped you or got in your way;
- last, give only the answer inside <response></response>, in the format the question asks for, \
or <response>NOT_FOUND</response> if the archive does not hold it.

Question: {question}"""


def run(cmd, **kw):
    return subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True, **kw)


def tag(text, name):
    found = re.findall(rf"<{name}>(.*?)</{name}>", text or "", re.S)
    return found[-1].strip() if found else None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", type=Path, default=None, help="where transcripts and the report go")
    ap.add_argument("--claude", default=os.environ.get("CLAUDE", "claude"), help="the Claude Code CLI")
    ap.add_argument("--model", default=None, help="passed to claude --model")
    ap.add_argument("--only", default=None, help="comma-separated 1-based question numbers")
    ap.add_argument("--server", type=Path, default=None, help="a tgkb-mcp binary to grade instead of this checkout's")
    args = ap.parse_args()
    out = args.out or Path(tempfile.mkdtemp(prefix="tgkb-mcp-eval."))
    out.mkdir(parents=True, exist_ok=True)

    pairs = [(q.findtext("question").strip(), q.findtext("answer").strip())
             for q in ET.parse(EVAL).getroot().iter("qa_pair")]
    wanted = {int(n) for n in args.only.split(",")} if args.only else set(range(1, len(pairs) + 1))

    # 1. The store. A skipped test exits 0 like a passing one, so the file is the proof.
    store = out / "eval.sqlite"
    for leftover in out.glob("eval.sqlite*"):
        leftover.unlink()
    built = run(["swift", "test", "--filter", "writesTheEvalStore"],
                env={**os.environ, "TGKB_EVAL_STORE": str(store)})
    if built.returncode != 0 or not store.exists():
        sys.exit(f"could not write the eval store:\n{built.stdout[-2000:]}{built.stderr[-2000:]}")

    # 2. The server, registered for these runs only.
    if args.server:
        binary = args.server.resolve()
    else:
        if run(["swift", "build", "--product", "tgkb-mcp"]).returncode != 0:
            sys.exit("swift build --product tgkb-mcp failed")
        binary = Path(run(["swift", "build", "--show-bin-path"]).stdout.strip()) / "tgkb-mcp"
    config = out / "mcp.json"
    config.write_text(json.dumps({"mcpServers": {"tgkb": {
        "type": "stdio", "command": str(binary), "args": ["--db", str(store)]}}}))

    # 3. One session per question.
    rows = []
    for number, (question, answer) in enumerate(pairs, 1):
        if number not in wanted:
            continue
        cmd = [args.claude, "-p", PROMPT.format(question=question),
               "--mcp-config", str(config), "--strict-mcp-config", "--tools", "",
               "--allowedTools", ALLOWED,
               "--output-format", "stream-json", "--verbose", "--no-session-persistence"]
        if args.model:
            cmd += ["--model", args.model]
        started = time.time()
        proc = subprocess.run(cmd, cwd=out, text=True, capture_output=True, timeout=900)
        (out / f"q{number}.jsonl").write_text(proc.stdout)
        events = [json.loads(line) for line in proc.stdout.splitlines() if line.startswith("{")]
        final = next((e for e in reversed(events) if e.get("type") == "result"), {})
        calls = [block["name"] for e in events if e.get("type") == "assistant"
                 for block in e["message"].get("content", []) if block.get("type") == "tool_use"]
        model = next((e.get("model") for e in events if e.get("subtype") == "init"), "?")
        text = final.get("result", "")
        denied = final.get("permission_denials") or []
        got = tag(text, "response")
        rows.append(dict(number=number, question=question, expected=answer, got=got,
                         correct=got == answer, calls=calls, seconds=round(time.time() - started),
                         feedback=tag(text, "feedback"), summary=tag(text, "summary"),
                         error=(text if final.get("is_error") else None) or
                               (f"permission denied: {denied}" if denied else None), model=model))
        print(f"{number:>2} {'PASS' if got == answer else 'FAIL'}  {len(calls):>2} calls  "
              f"expected {answer!r}, got {got!r}", flush=True)

    # The report: the numbers first, then what the model said about the tools.
    correct = sum(r["correct"] for r in rows)
    lines = [f"# tgkb-mcp eval — {correct}/{len(rows)} correct",
             "", f"Model: {rows[0]['model'] if rows else '?'}. Server: `{binary}`. "
                 "Transcripts: `q<n>.jsonl` beside this file.", "",
             "| # | result | tool calls | seconds | expected | got |", "|---|---|---:|---:|---|---|"]
    lines += [f"| {r['number']} | {'PASS' if r['correct'] else 'FAIL'} | {len(r['calls'])} | {r['seconds']} "
              f"| {r['expected']} | {r['got']} |" for r in rows]
    for r in rows:
        lines += ["", f"## {r['number']}. {r['question']}", "",
                  f"**Calls:** {', '.join(c.removeprefix('mcp__tgkb__') for c in r['calls']) or 'none'}", ""]
        if r["error"]:
            lines += [f"**Error:** {r['error']}", ""]
        lines += [f"**Feedback:** {r['feedback'] or '(none given)'}"]
    (out / "report.md").write_text("\n".join(lines) + "\n")
    print(f"\n{correct}/{len(rows)} correct — report: {out / 'report.md'}")
    if any(r["error"] for r in rows):
        sys.exit(1)


if __name__ == "__main__":
    main()

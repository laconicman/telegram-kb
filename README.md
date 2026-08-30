# telegram-kb

A searchable knowledge base built from Telegram channels, exposed to Claude over MCP.

**The direction documents in the DocC catalog are authoritative** — they outrank this README and
any code comment:

- `Design` — decisions, with the rejected alternatives
- `Roadmap` — Now / Next / Later
- `TechDebt` — numbered `TD-n`
- `Research` — the Verified / Unverified ledger

```bash
swift package --disable-sandbox preview-documentation --target TelegramKB
```

## Shape

Two executables over one SQLite store:

| | |
|---|---|
| `tgkb` | Ingestion. Crawls channels, writes the index. Owns all network and credentials. |
| `tgkb-mcp` | Read-only stdio MCP server. No network, no credentials, no ban exposure. |

The TDLib ingestion path is behind a **trait, off by default** — a default build does not
download the binary artifact. Verified, not assumed; see `research/spm-traits-binarytarget.md`.

```bash
swift build                      # no TDLib, no artifact download
swift build --traits TDLib       # adds the TDLib ingestion source
./Scripts/check-invariants.sh    # asserts tgkb-mcp is TDLib-free
```

## Status

**Phase 0 — research and scaffold.** No feature code yet; see `Roadmap`. Research notes,
including reproducible probes, are in `research/`.

## Licence note

TDLib is Boost; TDLibKit, TDLibFramework, GRDB, SwiftSoup and the MCP SDK are MIT. **Never
vendor code from `Telegram-iOS` or `Swiftgram/Telegram-iOS` — both are GPLv2** and would
relicense this project.

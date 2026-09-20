# Review Guidelines

Every rule below comes from a bug that automated review actually found on this repository (PR #1:
thirteen rounds, 34 inline findings, exactly one of which did not reproduce). Rationale lives in
`Sources/TelegramKB/TelegramKB.docc/Design.md`: flag a change that contradicts a decision recorded
there rather than re-arguing the decision.

## Critical Areas

- Flag a change to `Store.CrawlState` in `Sources/TelegramKBStore/Store.swift` that is not traced
  through four walks interrupted after one page: first backfill, resumed backfill, incremental,
  `--full`.
- Flag any path in `Sources/TelegramKBSync/ChannelSync.swift` that stores a `highestMessageID`
  above an id the walk has not yet fetched.
- Flag `backfillComplete` becoming true from anything but `reachedEnd` in
  `Sources/TelegramKBIngest/WebPreviewSource.swift` — not the page cap, a repeated page, or `since`.
- Flag a non-2xx response that is parsed instead of thrown in
  `Sources/TelegramKBIngest/WebPreviewSource.swift`; an error page parses as zero posts.
- Flag a non-2xx response that is classified instead of thrown in
  `Sources/TelegramKBIngest/ChannelClassifier.swift`; it reads as an unresolvable channel.
- Flag a post write and a crawl-state write in separate `dbPool.write` calls; both belong in one
  `Store.commitPage` transaction. One exception, and only this one: the final state write in
  `Sources/TelegramKBSync/ChannelSync.swift` after a walk ends, because completion is knowable
  only once the walk stops — a crash before it costs a re-crawl, never a false completion.
- Flag a new dependency of `tgkb-mcp` or `TelegramKBMCP` in `Package.swift` beyond
  `TelegramKBStore`, `TelegramKBModel` and the MCP SDK (`Scripts/check-invariants.sh`).
- Require a `specVersion` bump plus `Spec/url-canonical/SPEC.md` and
  `Spec/url-canonical/fixtures.json` cases in any diff that changes
  `Sources/TelegramKBModel/URLCanonicaliser.swift` rules.
- Flag merging or truncating `searchWords` and `searchSubstring` results outside `Store.search` in
  `Sources/TelegramKBStore/Search.swift`.

## Conventions

- Require a test that fails without the fix for every fix in `Sources/`, and require the test to
  FAIL when the fix is reverted — a repro that fails for another reason proves nothing.
- Require a mutant in `Scripts/mutants/` — a patch putting the bug back, named after the test it
  must break — for any fix whose failure mode is **silent**: lost posts, a false completion, a
  check that cannot fail, a skipped row, a stale identity. `Scripts/mutation-check.sh` replays
  them. Fixes to wording, formatting or argument validation do not need one: they fail loudly.
- Flag a test asserting only that a walk stopped, without asserting the `Store.CrawlState` it left.
- Flag a channel username reaching `Store` without `.lowercased()` in
  `Sources/TelegramKBSync/ChannelSync.swift`, `Sources/tgkb/Doctor.swift` or
  `Sources/TelegramKBIngest/WebPreviewParser.swift`.
- Require `Store.ensureChannel` before the first `commitPage` for a channel; `post` has a foreign
  key to `channel`.
- Flag `upsert(channel:)` with a placeholder `rawChannelID` of 0; it overwrites a learned id.
- Require numeric options in `Sources/tgkb/` to be checked in `validate()`: `Array.prefix` traps
  on a negative `--limit`.
- Flag `try?` around `Store.openForReading` or `Store.openForWriting` in `Sources/tgkb/`.
- Flag an import path in `Sources/TelegramKBStore/Store.swift` that skips bad rows without
  returning the count.
- Require a change to `TextNormalizer.indexed` in `Sources/TelegramKBStore/TextNormalizer.swift`
  to carry the matching change to `normalizeQuery`: what the index folds, the query must fold.
- Flag surface text and lemmas written to the same FTS5 column in
  `Sources/TelegramKBStore/Store.swift`; a phrase would straddle the join and match a post that
  contains it in neither form.
- Flag `NLTagger` use without an explicit `setLanguage` in `Sources/TelegramKBStore/`.

## Anti-patterns to Flag

- Flag a counter incremented inside a pipeline or `$( )` subshell in `Scripts/run-evals.sh`; the
  parent never sees it, and the eval reports PASS with nothing measured.
- Flag `2>&1` merged into output that `Scripts/run-evals.sh` parses as a number.
- Flag SwiftSoup `.text()` for message bodies in `Sources/TelegramKBIngest/`; it drops `<br/>`.
  Use the `NodeText` walk.
- Flag a body selector in `Sources/TelegramKBIngest/WebPreviewParser.swift` that can match
  `js-message_reply_text`.
- Flag `@unchecked Sendable` or `nonisolated(unsafe)` added in `Sources/` to silence a Swift 6
  diagnostic; use an actor.
- Flag posts retained in `WebPreviewSource.crawl` when `onPage` is given.
- Flag a decrementing cursor in `WebPreviewSource.crawl`; albums occupy several ids.

## Security

- Flag any credential, Keychain or session access reachable from `Sources/tgkb-mcp/` or
  `Sources/TelegramKBMCP/`.
- Flag string interpolation into a `MATCH` clause in `Sources/TelegramKBStore/`; queries come from
  an LLM tool call and must pass through `FTS5Pattern`.
- Flag `print` or any stdout write in `Sources/tgkb-mcp/` or `Sources/TelegramKBMCP/`; stdout is
  the MCP protocol stream.
- Reject code copied from the Telegram-iOS or Swiftgram Telegram-iOS repositories into `Sources/`;
  both are GPLv2.
- Flag CAPTCHA solving or fingerprint spoofing in `Sources/TelegramKBIngest/`; the design rejects
  bot-wall evasion (`Sources/TelegramKB/TelegramKB.docc/Design.md`).

## Ignore

- Skip `Tests/TelegramKBIngestTests/Fixtures/` and `research/fixtures/` — captured Telegram HTML.
- Skip `Spec/url-canonical/corpus-canonical.tsv` and `Spec/url-canonical/effective-url.tsv`;
  review `Scripts/GoldenCheck/` and `Scripts/resolve_urls.py` instead.
- Skip `Package.resolved` unless `Package.swift` changed in the same diff.
- Skip prose in `research/` and `reports/` — evidence notes and upstream drafts.

# ModelProxy

macOS menu bar app - transparent local API proxy for multi-vendor model routing.

> **新会话第一件事：读 `private/asc/HANDOFF-2026-08-28-0844.md`**
> （App Store 2.5 因 Guideline 5 / 中国区被拒，元数据已修但**尚未重新提交**；挂起等审核结果。
> 该文件在 gitignored 的 `private/` 下 —— 本机有，clone 出来的没有。历史交接见
> `private/asc/HANDOFF-*.md`。）

## Document Truth Source

All project documents use `docs/00-AI-CONTEXT.md` as the single source of truth. This file only provides navigation.

### Quick Reference

| Need... | Look at |
|--------|------|
| Project overview | `docs/00-AI-CONTEXT.md` |
| Project research | `docs/01-discovery/` |
| Architecture | `docs/02-architecture/` |
| Decision rationale | `docs/03-decisions/` |
| Implementation details | `docs/04-implementation/` |
| Feature behavior | `docs/05-features/` |
| Dev guide / plans | `docs/06-plans/` |
| Change history | `docs/07-changelog/` |
| Lessons learned | `docs/09-lessons-learned/` |

## Document After Completing Features

**Trigger:**
- Completed multi-file feature implementation
- Fixed bugs requiring context understanding
- Made design decisions with trade-offs

**Location:** `docs/05-features/feature-name.md`

**Trigger method:** After completion, ask the user; for a full session handoff, prompt the user to run `/handoff` (that skill is `disable-model-invocation`, so the model cannot invoke it itself)

## Project-Specific Constraints

```
Prohibited:
- Modifying API request/response content outside documented routing compatibility transforms
- Storing or logging API request/response bodies
- Listening on non-localhost interfaces

Required:
- All network I/O through SwiftNIO (not URLSession for the proxy server side)
- Streaming (SSE) response relay must forward chunks immediately, no buffering
- SSE response transforms must commit the same guarded/repaired content that is relayed to the client; add regression tests for both relay output and stored lineage data
- API keys stored in ~/Library/Application Support/ModelProxy/config.json, not Keychain (simplicity for personal tool)
- macOS 15.6+ (Sequoia) minimum deployment target (`MACOSX_DEPLOYMENT_TARGET = 15.6`)
```

## Tech Stack

- macOS 15.6+, Swift 6, SwiftUI
- SwiftNIO + NIOHTTP1 for HTTP proxy server
- AsyncHTTPClient or URLSession for upstream requests
- UserDefaults + JSON for config persistence
- No SwiftData, no Core Data

## Coding Conventions

See `~/.claude/CLAUDE.md` for general rules.

**Project-specific:**
- Menu bar app: use `MenuBarExtra`, no `WindowGroup` for main UI
- Settings: use SwiftUI `Settings` scene
- Config model: `@Observable` classes, JSON Codable
- Proxy layer: pure NIO, no SwiftUI dependencies

## When Confused

1. Check `docs/00-AI-CONTEXT.md` - project overview
2. Check `docs/03-decisions/` - may already have a decision
3. Check `docs/05-features/` - expected behavior and key code locations
4. Check `docs/09-lessons-learned/` - may be a known issue

## Runtime Inspection

The app is **sandboxed** (`com.90percent.ModelProxy`). At runtime, `AppPaths.appSupport`
resolves into the container, NOT the bare `~/Library/Application Support/...`:

```
~/Library/Containers/com.90percent.ModelProxy/Data/Library/Application Support/ModelProxy/
  ├── logs/modelproxy-YYYY-MM-DD.log   (daily log; NO request/response bodies, by policy)
  ├── config.json                      (vendors, keys)
  └── lineages.json                    (branch/lineage cache)
```

- **These files are TCC-locked.** Claude's shell gets `Operation not permitted` on
  `head`/`cp`/`ls` even though perms are `-rw-r--r--` — it's macOS TCC, not Unix perms.
  Read them via the app's log panel, a user-run `sudo`, or terminal Full Disk Access.
  Don't burn turns retrying file reads.
- **os_log is empty.** Subsystem `com.modelproxy.app` persists nothing
  (`log show --predicate 'subsystem == "com.modelproxy.app"'`). Not a debugging source.
- **Determine a model's route by probing the live proxy, not by guessing:**
  `curl localhost:9090/v1/messages -H 'x-api-key: probe' -H 'anthropic-version: 2023-06-01' -d '{"model":"<m>","max_tokens":8,"messages":[{"role":"user","content":"x"}]}'`
  — an Anthropic-format error (`request_id: req_011C...`) means that model is **passthrough
  to Anthropic**; a different vendor/error means it's mapped. See
  `docs/09-lessons-learned/2026-06-11-proxy-transform-diagnosis.md` for the tool-call transform gating table.

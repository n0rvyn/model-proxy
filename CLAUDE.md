# ModelProxy

macOS menu bar app - transparent local API proxy for multi-vendor model routing.

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

## Plan Execution Rules

When executing plan tasks with these fields:

| Field | Action |
|------|------|
| `Design ref:` | Read referenced design doc section before implementation |
| `Expected values:` | Verify each value matches after implementation |
| `Replaces:` | Grep old code references, confirm all handled |
| `Data flow:` | Trace path end-to-end, confirm connected |
| `Quality markers:` | Use specified algorithm/data structure, don't simplify |
| `Verify after:` | Execute each check after implementation |

When encountering gray areas not covered by the plan: **ask user, don't improvise**.

### Document After Completing Features

**Trigger:**
- Completed multi-file feature implementation
- Fixed bugs requiring context understanding
- Made design decisions with trade-offs

**Location:** `docs/05-features/feature-name.md`

**Trigger method:** After completion, use `/handoff` or ask user

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
- macOS 14+ (Sonoma) minimum deployment target
```

## Tech Stack

- macOS 14+, Swift 6, SwiftUI
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

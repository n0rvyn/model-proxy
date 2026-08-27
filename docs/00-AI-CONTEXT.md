# ModelProxy - AI Context

> AI assistant entry document for this project.

## One-line Description

macOS menu bar app that acts as a transparent local API proxy, routing model requests from Claude Code / Codex to different AI providers based on model ID.

## Core Features

### Local HTTP Proxy

Listens on localhost, intercepts Anthropic-format API requests, routes to the correct vendor endpoint based on model ID matching.

**Key Files:**
- `ModelProxy/Proxy/ProxyServer.swift` - NIO HTTP server, request routing
- `ModelProxy/Proxy/RequestRouter.swift` - Model ID matching and endpoint resolution
- `ModelProxy/Proxy/ResponseRelay.swift` - Response forwarding (streaming + non-streaming)

### Configuration

Manages vendors, model mappings, and client-specific settings (Claude Code / Codex).

**Key Files:**
- `ModelProxy/Models/AppConfig.swift` - Top-level config model
- `ModelProxy/Models/Vendor.swift` - Vendor definition (endpoint, API key, models)
- `ModelProxy/Models/ClientConfig.swift` - Per-client settings (port, tier mappings)

### Menu Bar UI

System tray status, traffic log, token stats.

**Key Files:**
- `ModelProxy/App/ModelProxyApp.swift` - App entry, MenuBarExtra
- `ModelProxy/Views/StatusPopover.swift` - Main popover view
- `ModelProxy/Views/SettingsView.swift` - Settings window

## Tech Stack

| Technology | Version | Purpose |
|-----------|---------|---------|
| macOS | 15.6+ (Sequoia) | Minimum support |
| Swift | 6 | Language |
| SwiftUI | - | UI framework |
| SwiftNIO | 2.x | HTTP proxy server |
| UserDefaults | - | Config persistence |

## Key Paths

| Feature | Entry File |
|---------|-----------|
| App entry | `ModelProxy/App/ModelProxyApp.swift` |
| Proxy server | `ModelProxy/Proxy/ProxyServer.swift` |
| Config models | `ModelProxy/Models/` |
| Views | `ModelProxy/Views/` |

## Document Index

- Project brief: `docs/01-discovery/project-brief.md`
- Architecture: `docs/02-architecture/`
- Dev guide / plans: `docs/06-plans/`
- Features: `docs/05-features/`

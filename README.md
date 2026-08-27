# ModelProxy

> macOS menu bar app for routing Claude Code and Codex requests to different upstream model vendors.

![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift)
![macOS](https://img.shields.io/badge/macOS-15.6+-86909B?logo=apple)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-007AFF)

## What It Is

ModelProxy runs local HTTP listeners on `127.0.0.1` and forwards each request to the right upstream based on the request's `model` field.

The current app ships with two default client listeners:

- `Claude Code` on port `8080`
- `Codex` on port `8081`

Each client can have its own:

- local proxy port
- default passthrough upstream
- policy for unmapped models

Global routing rules then map source model IDs such as `claude-haiku-4-5` to vendor-specific target models.

## Why Use It

| Benefit | Description |
|---------|-------------|
| Cost optimization | Route lower-priority models to cheaper vendors while keeping premium models on their default upstreams. |
| Zero modification | Point Claude Code or Codex at localhost; no app-side plugin or fork is required. |
| Full visibility | See listener status, recent traffic, and daily token usage from the menu bar app. |
| Hot-reload config | Saving settings updates routing snapshots for running listeners without restarting the whole app. |

## Current Feature Set

### Proxy and routing

- one SwiftNIO listener per configured client
- exact-match routing plus longest-prefix routing
- per-client unmapped model policy:
  - passthrough to the client's default upstream
  - route all unmapped models to a chosen vendor
  - block unmapped models with HTTP 403
- routing rules can be enabled or disabled without deleting the rule
- optional backup target per routing rule for failover
- API key replacement for routed requests
- top-level `model` field replacement without rewriting the rest of the JSON body
- streaming response relay
- signing-domain aware transcript replay:
  - `transparent` replay for Anthropic API / Bedrock / Vertex style routes
  - `portableOnly` replay for third-party compatible vendors
- vendor-local branch reuse for portable routes, so Claude Code / Codex sub-agent follow-up requests can resume on the same upstream transcript without poisoning the main Anthropic session
- persisted committed branch transcripts across app restarts

### Desktop app

- menu bar popover with:
  - running state
  - bound ports
  - today's token summary
  - recent traffic
  - start, stop, settings, and quit controls
- settings tabs:
  - `General`
  - `Clients`
  - `Vendors`
  - `Routing`
  - `Statistics`
  - `Debug`
- launch at login
- copyable quick-start shell command for each client

### Observability

- in-memory traffic log
- daily token usage persistence
- persisted lineage cache for committed vendor-local branch transcripts
- optional file-based debug logging with retention and compression
- corrupt config reset detection on app launch

## How It Works

```text
Claude Code / Codex
        |
        | HTTP -> 127.0.0.1:<client-port>
        v
   ModelProxy listener
        |
        | read JSON body -> extract model
        v
   RequestRouter
        |
        +--> mapped model ----------> vendor base URL + vendor API key
        |
        +--> unmapped passthrough --> client default upstream + original API key
        |
        +--> unmapped block -------> HTTP 403
```

For mapped requests, ModelProxy forwards the original request path to the chosen vendor base URL, swaps credentials, optionally swaps the model name, and relays the response back to the client.

For vendors outside the Anthropic signing domain, ModelProxy no longer replays raw Claude thinking/signature history back and forth. Instead it projects the request into a portable transcript, keeps a vendor-local branch transcript for that route, and only merges portable assistant output back into the main session.

## Quick Start

### 1. Build and run

```bash
git clone git@github.com:n0rvyn/model-proxy.git
cd model-proxy
open ModelProxy.xcodeproj
```

Run the `ModelProxy` scheme in Xcode.

### 2. Configure clients and vendors

After launch, open the menu bar app and configure:

- client ports and default upstreams in `Clients`
- vendor base URLs, API keys, compatible client, timeouts, and supported model lists in `Vendors`
- vendor signing domain and replay policy in `Vendors`
- source-model to target-model rules in `Routing`

### 3. Point tools at the local listeners

Example for the default ports:

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:8080
```

For Codex installations that need a different local endpoint, use the command shown in the `Clients` tab for that client.

## Configuration Model

ModelProxy persists config to:

```text
~/Library/Application Support/ModelProxy/config.json
```

The app creates this file on first launch with default clients for Claude Code and Codex.

The config currently contains:

- `vendors`
- `clients`
- `modelMappings`
- `debug`

Example shape:

```json
{
  "clients": [
    {
      "clientName": "Claude Code",
      "port": 8080,
      "defaultUpstream": "https://api.anthropic.com",
      "unmappedPolicy": "passthrough"
    },
    {
      "clientName": "Codex",
      "port": 8081,
      "defaultUpstream": "https://api.openai.com",
      "unmappedPolicy": "routeAll",
      "fallbackVendorID": "VENDOR-UUID",
      "fallbackTargetModel": "qwen-plus"
    }
  ],
  "vendors": [
    {
      "name": "DashScope",
      "baseURL": "https://dashscope.aliyuncs.com/compatible-mode",
      "apiKey": "sk-...",
      "connectTimeoutSeconds": 10,
      "readTimeoutSeconds": 120,
      "supportedModels": ["qwen-plus", "qwen-max"],
      "signingDomain": "compatibleThirdParty",
      "replayPolicy": "portableOnly"
    }
  ],
  "modelMappings": [
    {
      "sourceModel": "claude-haiku-4-5",
      "targetModel": "qwen-plus",
      "targetVendorID": "VENDOR-UUID",
      "isEnabled": true,
      "backupTargetModel": "qwen-max",
      "backupTargetVendorID": "BACKUP-VENDOR-UUID"
    }
  ],
  "debug": {
    "isEnabled": false,
    "minimumLogLevel": "info",
    "autoCleanupEnabled": true,
    "cleanupAfterDays": 7,
    "compressAfterDays": 3
  }
}
```

## Data Storage

- config: `~/Library/Application Support/ModelProxy/config.json`
- lineage cache: `~/Library/Application Support/ModelProxy/lineages.json`
- token stats: `~/Library/Application Support/ModelProxy/token-stats-YYYY-MM-DD.json`
- debug logs: `~/Library/Application Support/ModelProxy/logs/`

API keys are stored in plaintext in the local config file. That is the current product behavior.

## Tech Stack

| Component | Technology |
|-----------|------------|
| Language | Swift 6 |
| UI | SwiftUI + MenuBarExtra |
| Proxy server | SwiftNIO + NIOHTTP1 + AsyncHTTPClient |
| Config storage | JSON files in Application Support |
| Minimum OS | macOS 15.6+ |

## Development

### Build

```bash
xcodebuild -project ModelProxy.xcodeproj \
  -scheme ModelProxy \
  -destination 'platform=macOS' \
  build
```

### Test

```bash
xcodebuild -project ModelProxy.xcodeproj \
  -scheme ModelProxy \
  -destination 'platform=macOS' \
  test
```

## Code Map

```text
ModelProxy/
  App/        app lifecycle, paths, logging
  Models/     config, routing records, transcript replay domain, traffic, token stats
  Proxy/      server, router, forwarder, relay
  Services/   config store, lineage broker, transcript projector, replay recorder, login item, debug log manager
  Views/      menu bar popover and settings tabs
```

Key files:

- `ModelProxy/App/ModelProxyApp.swift`
- `ModelProxy/Services/ConfigStore.swift`
- `ModelProxy/Proxy/ProxyServer.swift`
- `ModelProxy/Proxy/RequestRouter.swift`
- `ModelProxy/Proxy/ProxyForwarder.swift`
- `ModelProxy/Proxy/ResponseRelay.swift`
- `ModelProxy/Services/SessionLineageBroker.swift`
- `ModelProxy/Services/TranscriptProjector.swift`
- `ModelProxy/Views/StatusPopover.swift`
- `ModelProxy/Views/SettingsView.swift`

## Roadmap

- [ ] MCP server integration
- [ ] Model capability auto-discovery
- [ ] Request and response transformation controls
- [ ] Remote access and multi-user support

## License

MIT. See `LICENSE`.

## Acknowledgments

Built for developers who switch between multiple model providers in daily tool workflows.

## Status

This README reflects the codebase as of May 6, 2026.

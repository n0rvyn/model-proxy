# App Store Connect Release Copy — v2.4

> Source of truth for ASC listing text. Reuse and trim per release. Banned-word rules from `~/.claude/CLAUDE.md` applied (no em-dashes, no "seamless/leverage", etc.).
>
> Scope note: "What's New" covers only features new since 2.2 (Web Search Bridge, routing rule toggles, third-party reliability hardening). Cost/savings tracking shipped before 2.2, so it lives in the Description as a standing feature, not in What's New.

---

## Description

### English

```
Model Proxy lets you run Claude Code and Codex on any AI provider, not just one. It is a tiny macOS menu bar app that starts a local HTTP proxy and transparently routes each request to the right vendor based on the model ID. Point your CLI at localhost once, and everything keeps working.

Why developers use it:

• Use cheaper or faster models. Route Claude Code traffic to DeepSeek, MiniMax, Kimi, GLM, or any Anthropic-compatible endpoint, and keep your exact CLI setup.

• See what you save. Model Proxy tracks token usage per model and shows your real cost next to the equivalent official price, so you know exactly how much each session saved.

• Web search keeps working everywhere. Most third-party vendors do not support Claude's built-in web search. The Web Search Bridge runs the search through Brave, Google, or Tavily and feeds the results back, so the web_search tool works no matter which model you route to.

• Watch every request live. A real-time traffic monitor shows each call, its model, token counts, and request type as it happens. Nothing is buffered.

• Route by rule, toggle on the fly. Build model-mapping rules, enable or disable them without deleting, and let Model Proxy suggest mappings for new model IDs it observes.

• Private by design. The proxy listens on localhost only. It never stores or logs your request and response bodies. Your API keys stay in a local config file on your Mac.

Built on SwiftNIO for low-latency streaming. Native menu bar app, macOS 14 and later.
```

### 中文

```
Model Proxy 让你的 Claude Code 和 Codex 用上任意 AI 服务商，而不必绑定单一平台。它是一个轻量的 macOS 菜单栏小工具，在本地启动一个 HTTP 代理，根据模型 ID 把每个请求透明转发到对应的服务商。CLI 只需指向 localhost 一次，原有用法完全不变。

开发者为什么用它：

• 用更便宜、更快的模型。把 Claude Code 的流量路由到 DeepSeek、MiniMax、Kimi、GLM 或任意兼容 Anthropic 协议的接口，保持原有 CLI 配置不动。

• 看清省了多少。Model Proxy 按模型统计 token 用量，并在实际花费旁边显示官方等价价格，每次会话省了多少一目了然。

• 联网搜索处处可用。大多数第三方服务商不支持 Claude 内置的联网搜索。联网搜索桥接会把搜索请求转给 Brave、Google 或 Tavily，再把结果回填，无论路由到哪个模型，web_search 工具都能正常工作。

• 实时查看每个请求。流量监视器实时显示每一次调用的模型、token 数量和请求类型，全程不缓冲。

• 按规则路由，随时开关。自定义模型映射规则，不删除即可启用或停用；Model Proxy 还会为观察到的新模型 ID 主动建议映射。

• 隐私优先。代理只监听 localhost，从不存储或记录你的请求与响应内容，API 密钥保存在本机配置文件中。

基于 SwiftNIO，低延迟流式转发；原生菜单栏应用，支持 macOS 14 及以上。
```

---

## Promotional Text (≤170 chars)

### English

```
Run Claude Code on any model. Route to cheaper vendors, keep web search working everywhere, and see exactly how much each session saves. 100% local and private.
```

### 中文

```
让 Claude Code 用上任意模型：路由到更便宜的服务商，联网搜索处处可用，每次会话省多少看得清清楚楚。全程本地运行，隐私优先。
```

---

## What's New in This Version (2.4)

### English

```
This release is about routing to third-party vendors more reliably, with web search that finally works everywhere.

• Web Search Bridge (new): Claude's web_search tool now works even on vendors that don't support it. Searches run through Brave Search, Google Custom Search, or Tavily, and results are fed back automatically. Choose your provider in Settings.

• Search visibility: the traffic monitor now tags bridged search requests and counts how many searches each session triggered.

• Routing rule toggles: enable or disable any model-mapping rule without deleting it, plus one-tap suggestions for new model IDs the proxy observes.

• More reliable third-party routing: hardened DeepSeek Anthropic compatibility, more accurate tool-call name handling, safer SSE streaming relay, and cleaner vendor-side tool handling.

Thanks for using Model Proxy. Feedback is always welcome.
```

### 中文

```
本次更新让第三方服务商的路由更可靠，并让联网搜索真正处处可用。

• 联网搜索桥接（全新）：Claude 的 web_search 工具现在即使在不支持它的服务商上也能用。搜索会经由 Brave Search、Google Custom Search 或 Tavily 执行，结果自动回填。在设置中选择你的搜索服务商即可。

• 搜索可视化：流量监视器现在会标记桥接的搜索请求，并统计每次会话触发了多少次搜索。

• 路由规则开关：任意模型映射规则都可以不删除直接启用或停用；代理观察到新的模型 ID 时还会主动建议映射，一键采用。

• 更可靠的第三方路由：增强 DeepSeek 的 Anthropic 兼容性，更准确的工具调用名称处理，更稳的 SSE 流式转发，以及更干净的服务商侧工具处理。

感谢使用 Model Proxy，欢迎反馈。
```

---

## Keywords (per-localization, ≤100 chars, no space after comma)

ASC keyword field is localized. App name "Model Proxy" already indexes the words `model` and `proxy`, so they are dropped from both lists to save budget.

### zh-Hans (Chinese Simplified)

```
中转,代理,转发,大模型,模型,接口,搜索,claude,code,codex,deepseek,kimi,glm,智谱,minimax,openai,anthropic,llm,ai,api
```

96/100 chars. Rationale:
- Added (highest CN search value): `中转` (devs search "API 中转 / 中转站"), `代理` `转发` `大模型` `接口`.
- Added `搜索` for the 2.4 Web Search Bridge.
- Added supported-vendor names: `codex` `kimi` `glm` `智谱` `minimax`.
- Dropped from old list: `model` `proxy` (in app name), `routing` `developer` (no CN search volume).

### en (English)

```
api,relay,gateway,router,llm,claude,code,codex,deepseek,openai,anthropic,kimi,glm,minimax,websearch
```

99/100 chars. Rationale:
- Added English proxy-synonyms users actually search: `relay` `gateway` `router`.
- Added `websearch` (2.4 feature) and vendor names `codex` `kimi` `glm` `minimax`.
- Dropped `model` `proxy` (in app name).

### Caveats

- Per-localization: zh-Hans keywords go in the Chinese localization only; en keywords in the English only. Do not mix.
- No space after commas (spaces count against the 100-char budget).
- Third-party brand keywords (deepseek/openai/anthropic/kimi/glm/minimax) carry a low-but-nonzero review-rejection risk. If rejected, drop niche brands first (minimax/glm/智谱), keep claude/openai/deepseek.

---

## Feature provenance (for next release)

| Field claim | Code anchor |
|---|---|
| Web Search Bridge, providers Brave/Google/Tx | `ModelProxy/Models/WebSearchConfig.swift` (`Provider` enum), `ModelProxy/Proxy/ProxyForwarder.swift` |
| Search count + bridged request tagging | commits `5109e2e`, `5599033`, `a26024d` (`webSearchBridge` RequestKind) |
| Routing rule toggles + observed model suggestions | commits `35fbab2`, `3bf9853`, `2b41753` (`isEnabled` field) |
| DeepSeek compat / ToolCallGuard / vendor tool sanitizer / SSE decouple | commits `a6eea04`, `422712e`, `84652c8`, `8d27741` |
| Cost & savings tracking (pre-2.2, Description only) | commits `c212d5b`, `2a0c57b` (`ModelPrice`) |

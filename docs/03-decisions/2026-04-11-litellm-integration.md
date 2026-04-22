# ADR: ModelProxy + LiteLLM 跨 Provider 支持调研

**Date:** 2026-04-11
**Status:** Proposed (待讨论)
**Topic:** ModelProxy 集成 LiteLLM 以支持 OpenAI-native Providers（如 Codex）

## 背景

用户希望 ModelProxy 能支持更多 Provider，尤其是 OpenAI-native 的 Provider（如 Codex），实现方式类似于 Claude Code 可以通过 LiteLLM 代理使用 Codex。

本文档记录架构调研结果和待讨论的关键决策。

---

## 现状分析

### ModelProxy 当前架构

```
Claude Code → ModelProxy → [Anthropic / Vertex / OpenRouter / ...]
                        (纯透明代理，只做路由)
```

**核心特性：**
- 请求/响应格式原样透传，不做格式转换
- 只替换 `model` name，保留原始 endpoint path（如 `/v1/messages`）
- 支持 WebSearchBridge 拦截 `web_search` tool call
- 支持 branch/replay 系统（跨 provider 重放对话）

**格式处理现状：**
- `ProxyForwarder.executeUpstream()` 直接把 `/v1/messages` 拼到 upstream URL 上
- `ResponseRelay` 原样转发 upstream 响应，无格式翻译
- 唯一格式处理：`vendorSafeBlockTypes` 过滤 Anthropic 专用内容块（防止第三方 vendor 400 错误）
- usage 解析兼容 Anthropic（`input_tokens`/`output_tokens`）和 OpenAI（`prompt_tokens`/`completion_tokens`）两种格式

### LiteLLM 架构

```
[任意格式请求] → LiteLLM → [OpenAI / Codex / Azure / Vertex / ...]
               (OpenAI 格式中介)
```

**核心特性：**
- 暴露 OpenAI Chat Completions API（`/v1/chat/completions`）
- 输入：OpenAI Chat Completions 格式
- 输出：OpenAI Chat Completions 格式（无论 underlying provider 是什么）
- 支持 100+ provider 翻译
- 支持 streaming、virtual keys、rate limiting、cost tracking
- 部署方式：`pip install litellm` 或 Docker

---

## 核心障碍：格式差异

| | Anthropic `/v1/messages` | OpenAI `/v1/chat/completions` |
|--|--|--|
| Endpoint | `/v1/messages` | `/v1/chat/completions` |
| Content | 内容块数组（`text` block 等） | 字符串或内容块数组 |
| 函数调用 | `tool_use` block | `functions`/`tools` 参数 |
| Streaming 事件 | `content_block_delta` | `choices[0].delta` |
| Stop reason | `stop_reason` | `finish_reason` |
| Role 限制 | `system` 必须在首条消息 | `system` 可在任意位置 |

**ModelProxy 目前完全没有 OpenAI ↔ Anthropic 格式翻译能力。**

---

## 可选方案

### 方案 A：ModelProxy 内置 OpenAI 翻译层

在 ModelProxy 里新增 translation layer，检测 target vendor 需要的格式，按需转换。

**工作量：** ~300-500 行格式转换代码

**优点：**
- 所有逻辑内聚，单一代理
- 保留 ModelProxy 的本地拦截、模型映射、branch/replay 能力

**缺点：**
- 架构范式转变：从"透明代理"变成"协议转换代理"
- 格式翻译代码需要持续维护，跟进各 provider 的 API 变化
- 复杂度显著增加

### 方案 B：ModelProxy + LiteLLM 分层

ModelProxy 处理 Anthropic-native vendors，LiteLLM 处理 OpenAI-native vendors。两者独立运行。

**架构：**
```
Claude Code → ModelProxy
                ├── Anthropic-native vendors（直接转发）
                └── OpenAI-native vendors → LiteLLM → Codex/OpenAI/...
```

**问题：** ModelProxy 仍然需要把 Anthropic 格式转成 OpenAI 格式发给 LiteLLM，再把 OpenAI 响应转回 Anthropic 格式。本质上等同于方案 A。

### 方案 C：纯 LiteLLM 方案（最简）

放弃 ModelProxy 的路由能力，用 LiteLLM 完全替代。

```bash
# 起 LiteLLM 指向 Codex
# Claude Code: export ANTHROPIC_BASE_URL=http://localhost:4000/anthropic
```

**优点：**
- 格式翻译完全由 LiteLLM 处理，无需自研
- 快速可用，社区活跃

**缺点：**
- 失去 ModelProxy 的本地透明拦截能力（Claude Code 须显式配置 endpoint）
- 失去 branch/replay 系统（ModelProxy 独有）
- 失去菜单栏 UI 和 Traffic Log 可视化
- 失去 per-request 的模型映射能力

---

## 待讨论事项

1. **ModelProxy 的核心价值主张是什么？**
   - 如果是"透明代理 + 路由"，则方案 C 更合适
   - 如果是"本地 intercept + 任意格式支持"，则需要方案 A

2. **是否需要保留 branch/replay 系统？**
   - 这是 ModelProxy 独有的能力，但依赖于请求的完整语义
   - 如果翻译层破坏了对话语义，branch/replay 可能失效

3. **工作量预期**
   - 方案 A 估计 300-500 行，需要测试多种 edge cases（streaming、tool calling、thinking blocks 等）
   - 方案 C 零开发，直接可用

4. **用户场景确认**
   - 主要场景是"让 Claude Code 用 Codex"还是"通用跨 provider 代理"？
   - 前者方案 C 最优；后者需要方案 A

---

## 参考资料

- Claude Code 代理配置文档：https://code.claude.com/docs/en/llm-gateway.md
- Claude Code 支持 `ANTHROPIC_BASE_URL` 环境变量
- Claude Code 支持 `HTTPS_PROXY` / `HTTP_PROXY` 环境变量
- LiteLLM GitHub：https://github.com/BerriAI/litellm
- LiteLLM 支持 OpenAI-compatible endpoint（`/v1/chat/completions`）

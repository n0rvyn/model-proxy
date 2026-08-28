# Privacy Policy | 隐私政策

*Last Updated: March 2026 | 最后更新：2026 年 3 月*

## Overview | 概述

Model Proxy is a macOS menu bar application that runs a local HTTP proxy server on your computer. It routes API requests from development tools (such as Claude Code and Codex CLI) to AI service providers based on your configuration.

Model Proxy 是一款 macOS 菜单栏应用，在您的电脑上运行本地 HTTP 代理服务器。它根据您的配置，将开发工具（如 Claude Code 和 Codex CLI）的 API 请求路由到 AI 服务商。

## Information We Collect | 我们收集的信息

**We do not collect any personal information.**

**我们不收集任何个人信息。**

Model Proxy operates entirely on your local machine. Specifically:

Model Proxy 完全在您的本地设备上运行。具体而言：

### Data Stored Locally | 本地存储的数据

- **Configuration Data**: Your vendor settings, model mappings, and API keys are stored locally in `~/Library/Application Support/ModelProxy/config.json`. This data never leaves your device through Model Proxy.
- **配置数据**：您的服务商设置、模型映射和 API 密钥存储在本地 `~/Library/Application Support/ModelProxy/config.json`。这些数据不会通过 Model Proxy 离开您的设备。

### Data Not Stored | 未存储的数据

- **API Request/Response Bodies**: Model Proxy forwards API requests and responses as-is without reading, storing, or logging their content.
- **API 请求/响应内容**：Model Proxy 原样转发 API 请求和响应，不读取、存储或记录其内容。

- **Traffic Statistics**: Basic traffic metadata (model name, route type, HTTP status code, response duration, token counts) is kept in memory during the app session and discarded when the app quits.
- **流量统计**：基本的流量元数据（模型名称、路由类型、HTTP 状态码、响应耗时、Token 用量）仅在应用运行期间保存在内存中，应用退出后即被丢弃。

## Data Sharing | 数据共享

Model Proxy does not transmit any data to us or to any third party. The app functions as a transparent pass-through proxy; API requests are sent directly from your device to whichever AI service providers you have configured yourself.

Model Proxy 不会向我们或任何第三方传输数据。该应用作为透明直通代理运行；API 请求直接从您的设备发送到您自己配置的 AI 服务商。

## Analytics and Tracking | 分析与追踪

Model Proxy does not include any analytics, crash reporting, or tracking SDKs. We do not collect usage data of any kind.

Model Proxy 不包含任何分析、崩溃报告或追踪 SDK。我们不收集任何类型的使用数据。

## Network Usage | 网络使用

- **Inbound**: The proxy server listens only on `localhost` (127.0.0.1). It is not accessible from other devices on your network.
- **入站**：代理服务器仅监听 `localhost`（127.0.0.1），不可从网络中的其他设备访问。

- **Outbound**: The app makes HTTPS requests to the AI service provider endpoints you have configured. These requests contain the API keys and content you provide through your development tools.
- **出站**：应用向您配置的 AI 服务商端点发出 HTTPS 请求。这些请求包含您通过开发工具提供的 API 密钥和内容。

## Data Security | 数据安全

- API keys are stored in a local configuration file within the macOS App Sandbox.
- All outbound connections use HTTPS (TLS encryption).
- The proxy server only accepts connections from localhost.

- API 密钥存储在 macOS App Sandbox 内的本地配置文件中。
- 所有出站连接使用 HTTPS（TLS 加密）。
- 代理服务器仅接受来自 localhost 的连接。

## Children's Privacy | 儿童隐私

Model Proxy is a developer tool and is not directed at children under 13. We do not knowingly collect information from children.

Model Proxy 是一款开发者工具，不面向 13 岁以下儿童。我们不会故意收集儿童的信息。

## Changes to This Policy | 政策变更

We may update this Privacy Policy from time to time. Changes will be reflected in the "Last Updated" date above.

我们可能会不时更新本隐私政策。变更将体现在上方的"最后更新"日期中。

## Contact | 联系方式

If you have questions about this Privacy Policy, please contact us at:

如果您对本隐私政策有疑问，请通过以下方式联系我们：

Email: norvynzhang@gmail.com

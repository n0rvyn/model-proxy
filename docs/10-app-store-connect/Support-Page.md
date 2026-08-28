# Model Proxy Support | 支持

## Frequently Asked Questions | 常见问题

### What is Model Proxy? | Model Proxy 是什么？

Model Proxy is a macOS menu bar app that runs a local API proxy server. It allows you to route AI model requests from development tools like Claude Code and Codex CLI to different AI providers based on model ID.

Model Proxy 是一款 macOS 菜单栏应用，运行本地 API 代理服务器。它允许您根据模型 ID 将来自 Claude Code 和 Codex CLI 等开发工具的 AI 模型请求路由到不同的 AI 服务商。

### How do I set up the proxy? | 如何设置代理？

1. Launch Model Proxy from your Applications folder.
2. Click the menu bar icon to open the configuration panel.
3. Add your AI service vendors with their API endpoints and keys.
4. Configure model mappings to route specific models to specific vendors.
5. Set the proxy address in your development tool's configuration.

1. 从"应用程序"文件夹启动 Model Proxy。
2. 点击菜单栏图标打开配置面板。
3. 添加您的 AI 服务商及其 API 端点和密钥。
4. 配置模型映射，将特定模型路由到特定服务商。
5. 在您的开发工具配置中设置代理地址。

### Does Model Proxy store my API requests? | Model Proxy 会存储我的 API 请求吗？

No. Model Proxy acts as a transparent pass-through proxy. It does not read, store, or log the content of API requests or responses.

不会。Model Proxy 作为透明直通代理运行，不读取、存储或记录 API 请求或响应的内容。

### Where are my API keys stored? | 我的 API 密钥存储在哪里？

API keys are stored locally on your Mac in `~/Library/Application Support/ModelProxy/config.json`, within the App Sandbox. They are never transmitted to us or any third party.

API 密钥存储在您 Mac 本地的 `~/Library/Application Support/ModelProxy/config.json` 中，位于 App Sandbox 内。它们永远不会被传输给我们或任何第三方。

### Which AI providers are supported? | 支持哪些 AI 服务商？

Model Proxy supports any AI provider with an HTTP API. The app ships with no provider preset and no bundled API key: you add each vendor yourself by entering its endpoint URL and your own key.

Model Proxy 支持任何具有 HTTP API 的 AI 服务商。应用不预置任何服务商，也不内置任何 API 密钥：每个服务商都由您自己填写端点地址和自己的密钥后添加。

### The proxy server won't start. What should I do? | 代理服务器无法启动怎么办？

- Check that the configured port is not already in use by another application.
- Try changing the port number in the settings.
- Restart Model Proxy.

- 检查配置的端口是否已被其他应用占用。
- 尝试在设置中更改端口号。
- 重新启动 Model Proxy。

## Troubleshooting | 故障排除

### Requests are failing with connection errors | 请求因连接错误失败

- Verify that Model Proxy is running (check the menu bar icon).
- Confirm the proxy port matches your development tool's configuration.
- Check that your API keys are valid for the target provider.

- 确认 Model Proxy 正在运行（检查菜单栏图标）。
- 确认代理端口与开发工具配置一致。
- 检查您的 API 密钥对目标服务商是否有效。

### Model routing is not working as expected | 模型路由未按预期工作

- Open the traffic log in Model Proxy to see how requests are being routed.
- Verify your model ID mappings in the configuration.
- Check that the target vendor endpoint is correct.

- 打开 Model Proxy 中的流量日志，查看请求的路由情况。
- 在配置中验证您的模型 ID 映射。
- 检查目标服务商端点是否正确。

## Contact Us | 联系我们

For support inquiries, please reach out to:

如需支持，请通过以下方式联系：

- **Email**: norvynzhang@gmail.com

## App Information | 应用信息

- **Version**: 2.5
- **System Requirements**: macOS 15.6 (Sequoia) or later
- **Developer**: Norvyn Zhang

Copyright © 2026 Norvyn Zhang. All rights reserved.

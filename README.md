<div align="center">

<img src="docs/banner.png" alt="Tars — 住在 MacBook 刘海里的 AI 桌面伙伴" width="100%" />

# Tars

**住在 MacBook 刘海里的原生 AI 客户端与 TARS 机器人**

[![macOS](https://img.shields.io/badge/macOS-14.0+-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

**中文** · [English](./README.en.md)

</div>

Tars 是一个 SwiftUI 原生 macOS 应用。点击刘海下方的胶囊呼出聊天，来自《星际穿越》的 TARS 机器人会在灵动岛、聊天状态条和桌面之间活动。整个应用只有这一个角色，切换 AI 模式不会更换形象。

> Swift 6 · SwiftUI · macOS 14+ · 无 Electron · 无 WebView

## 核心能力

- 最多 8 个独立对话，可并行流式执行
- AI 助手、Claude Code、Codex 三种模式
- ChatGPT 订阅：使用 ChatGPT 登录，共享 Plus / Pro 额度，无需 API Key
- 内嵌 opencode：支持 DeepSeek、Kimi、智谱、MiniMax、OpenAI 等服务商模型
- Claude Code / Codex CLI 位于高级设置；旧版 Hermes / OpenClaw 选择自动迁移到 opencode
- Markdown、GFM 表格、代码块、图片、文件路径附件和 Codex 生图
- ScreenCaptureKit 截屏、按住说话、全局快问、桌面 Pin
- 聊天状态条直接显示当前模型与账号信息；任务过程按对话隔离，点击可展开工具操作
- 登录、额度与执行错误保留在当前对话，支持重新登录、检查连接与只读任务检查
- 灵动岛展示连接状态、工具调用、执行步骤、文件修改和完成状态
- TARS 桌面巡视、文件扫描和桌面图标探索

## 三种模式

| 模式 | 适合场景 | 准备工作 |
|---|---|---|
| **AI 助手** | 对话、写作、看图、本地 agent 工具 | 设置中使用 ChatGPT 登录，或选择 opencode 并配置服务商密钥 |
| **Claude Code** | 文件修改、命令执行、编程任务 | 本机 Claude 已登录 |
| **Codex** | 编程任务、命令执行、生图 | 本机 Codex 已登录 |

## ChatGPT 订阅接入

设置 → AI 助手 → **ChatGPT 订阅** → **使用 ChatGPT 登录**，在系统浏览器的 OpenAI 页面授权 Tars，再选择账号返回的模型；可展开「连接诊断」点击「验证订阅连接」。验证会调用一次模型，只有任务成功完成才显示验证通过。该入口采用 OpenAI 为开源/本机个人项目提供的 [Sign in with ChatGPT 订阅共享流程](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)，使用公共 Responses API；无需 API Key，也不借用已有 Codex 登录凭据。

登录网页出错时，可取消本次登录，展开「账号管理」选择「用 Safari 登录」发起新授权。浏览器的安全验证需要在浏览器中完成；本机回调等待 5 分钟，超时后需重新发起登录。

本机需安装支持 app-server 的当前 [Codex CLI](https://developers.openai.com/codex/cli)。Tars 的授权凭据存系统钥匙串，支持多账号、PKCE、身份签名验证、刷新和退出撤销。每个对话绑定首次使用的账号、模型和工作目录，切换账号用于新对话；线程映射存 `~/.hermespet/agents/chatgpt-threads.json`（0600）。文本、图片、文档路径、本机命令、MCP、Skills 和 TARS 风格通过本机 app-server 执行。订阅共享不读取 ChatGPT 历史或记忆；当前预览不支持此入口的托管生图、语音接口和其他托管工具。高级 Codex 模式的生图是独立通道。

额度与 Codex / ChatGPT Work 共享，可在 ChatGPT 设置 → Usage 管理 Tars 的用量上限。额度错误会明确显示，不自动转入 API 计费。取消会请求中断任务；断线后读取保存的线程状态，不自动重放不确定输入。安装与协议测试不能替代用户授权后的真实请求验证。

## 快速开始

需要 macOS 14+ 和完整 Xcode：

```bash
git clone https://github.com/simpledavid/tars.git
cd tars
./install.sh
```

`install.sh` 会构建并安装到 `/Applications/Tars.app`。

## 快捷键

| 快捷键 | 功能 |
|---|---|
| `⌘⇧H` | 呼出或收回聊天窗 |
| `⌘⇧J` | 截屏并附加到当前对话 |
| `⌘⇧V` | 按住说话，松开发送 |
| `⌘⇧Space` | 快问 |
| `⌘⇧P` | Pin 当前对话最新 AI 回复 |
| `⌘N` | 新对话 |
| `⌘1` ~ `⌘8` | 切换到指定对话 |

## 构建脚本

| 脚本 | 用途 |
|---|---|
| `./build.sh` | 构建项目目录下的 `Tars.app` |
| `./install.sh` | 构建、安装到 `/Applications/Tars.app` 并启动 |
| `./make-dmg.sh` | 生成 Apple Silicon 与 Intel DMG |

## 数据与兼容

为了保留旧版本用户的数据、TCC 权限和本地工具配置，以下内部路径与标识继续沿用：

| 路径或标识 | 用途 |
|---|---|
| `com.nousresearch.hermespet` | 兼容 bundle ID |
| `~/.hermespet/` | 对话、图片、Pin、活动数据和模型配置 |
| `~/Library/Application Support/HermesPet/` | opencode runtime 与会话目录 |
| `~/Library/Caches/HermesPet/` | 临时附件与截图 |

这些旧名属于内部兼容层，用户可见产品名统一为 Tars。

## 隐私

- API 请求只发送到用户选择的服务商或本机 agent
- 活动数据和对话记录默认保存在本机
- 桌面巡视会过滤包含密码、合同、薪资、`.env` 等敏感关键词的文件名
- Tars 不包含独立遥测后端

技术约束与开发约定见 [CLAUDE.md](./CLAUDE.md)。

## License

[Apache License 2.0](./LICENSE)

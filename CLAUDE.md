# Tars — macOS 刘海桌宠 + AI 聊天客户端

Swift 6 + SwiftUI，支持 macOS 14+，SwiftPM 构建。Tars 常驻 MacBook 顶部刘海区域，点击胶囊呼出聊天窗；全应用只使用一个角色形象：电影《星际穿越》中的 TARS 机器人。

当前版本：v1.2.7 build 12，主程序 universal arm64+x86_64，内嵌 opencode v1.15.1。

## 三个 AgentMode

| AgentMode | 用户名称 | 实现 |
|---|---|---|
| `.directAPI` | AI 助手 | ChatGPT 订阅 / 本地 opencode |
| `.claudeCode` | Claude Code | spawn `claude -p` |
| `.codex` | Codex | spawn `codex exec -i` |

AI 助手可选择 ChatGPT 订阅和 opencode。ChatGPT 订阅使用 Tars 自己的官方 OAuth 授权和本机 `codex app-server`，凭据存钥匙串；共享 Plus / Pro 订阅额度，不读取已有 Codex 登录，不回退到 API 计费。账号、模型和工作目录按对话绑定，线程映射为 `~/.hermespet/agents/chatgpt-threads.json`（0600）。opencode 使用服务商模型与 API Key。Claude Code / Codex CLI 的入口和配置位于高级设置。旧版 Hermes / OpenClaw / none 选择迁移到 opencode；已移除的 Agents API 选择迁移到 ChatGPT 订阅，保留本机聊天历史，续聊需要订阅授权。

驱动配置写入 `~/.hermespet/agents/model-driver.json`，权限为目录 0700、文件 0600。ChatGPT 订阅凭据存系统钥匙串。每个对话锁定引擎，会话绑定含未确认请求标记，禁止自动重放不确定输入。

## 品牌与兼容层

- 项目目录和 GitHub 仓库名统一为 `tars`：`https://github.com/simpledavid/tars`。
- 用户可见产品名、安装包名、窗口标题统一为 **Tars**。
- SwiftPM executable target、可执行文件、bundle ID、通知名和旧数据目录暂时保留 `HermesPet` / `com.nousresearch.hermespet`。
- 这些内部旧名用于保持升级兼容、TCC 权限、历史对话和工具 hook，不应再出现在用户文案中。
- 构建产物为 `Tars.app`，安装到 `/Applications/Tars.app`。

## 单宠物规则

- 灵动岛、聊天窗状态条和桌面漫步都只渲染 TARS：黑银四柱机体、蓝色信息屏和分段机械步态。
- 切换 AgentMode 只改变模式图标、颜色、标签和请求路由，不改变宠物种类。
- 桌面漫步行为不按模式分叉：自由活动开启时常驻，否则系统空闲后出现；流式任务期间收回。
- 不再加入云朵、小马、终端等模式专属宠物。
- 所有通道共享 `TarsPersonality` 的冷静、简洁、任务优先与克制干幽默；角色名称与实际模型身份分别说明。桌宠语录集中在 `TarsQuotes`，产物遵从用户指定的语气和格式。

## 主要文件

- 核心：`HermesPetApp`、`ChatViewModel`、`ChatView`、`ChatWindowController`、`Models`
- 聊天 UI：`ChatComponents`、`MarkdownRenderer`、`ChatFontScale`
- 刘海与桌宠：`DynamicIslandController`、`TarsWalkOverlay`、`ModeSprite`、`PetHeaderStrip`
- Agent：`APIClient`、`ClaudeCodeClient`、`CodexClient`、`OpenCodeServerManager`、`OpenCodeHTTPClient`、`AgentHarness`、`ChatGPTPlanAuth`、`ChatGPTPlanClient`、`ChatGPTLoginCallback`
- 权限：`PermissionWindowController`、`PermissionHookServer`、`PermissionHookInstaller`
- 系统：`UpdateChecker`、`CrashReporter`、`StorageManager`、`SchemaMigrator`

## 快捷键

- 全局：`⌘⇧H` 聊天、`⌘⇧J` 截屏、`⌘⇧V` 按住说话、`⌘⇧Space` 快问、`⌘⇧P` Pin 最新回答
- 聊天窗：`⌘N` 新对话、`⌘[`/`⌘]` 切换、`⌘1`~`⌘8` 直达、`⌘⌫` 关闭、`⌘±`/`⌘0` 字号

## 构建

- `./build.sh`：构建 `Tars.app`
- `./install.sh`：构建、安装到 `/Applications/Tars.app` 并启动
- `./make-dmg.sh`：生成 Apple Silicon 和 Intel 两份 Tars DMG

## 不可破坏的技术约束

1. 灵动岛 NSWindow 不调用 `setFrame`；需要扩展面积的内容使用独立 NSWindow。
2. 灵动岛 hit-test 通过 NSEvent monitor 和屏幕坐标判定。
3. 截屏使用 ScreenCaptureKit，不预检 `CGPreflightScreenCaptureAccess`。
4. 本地构建优先使用 Apple Development 证书，保持 TCC 权限稳定。
5. Swift 6 后台系统回调注意 actor isolation；必要时使用 `@unchecked Sendable`、锁和显式主线程跳转。
6. 跨窗口同步变更使用异步主线程调度，避免嵌套 layout。
7. Codex 图片参数必须使用 `-i path -- prompt`。
8. 文档附件传路径，不把全文塞入上下文。
9. `@Observable` 错误状态必须有对应 UI 渲染。
10. 修改 AgentMode 路由时同时检查图片、文档、连接检测、设置和所有 switch。

## 工作约定

- 新会话先读 `CLAUDE.md`。
- 修改后运行：`./build.sh 2>&1 | grep -E "error:|warning:|Build complete"`
- 本地部署使用 `./install.sh`。
- 保持 UI 极简，优先图标，遵循 Apple HIG；输入栏注意光标、padding 和 Capsule 半圆边界。
- 面向非开发用户交付完整修改和构建结果，不要求用户手工拼代码。

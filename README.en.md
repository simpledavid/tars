<div align="center">

<img src="docs/banner.png" alt="Tars — an AI desktop companion living under the MacBook notch" width="100%" />

# Tars

**A native macOS AI client with one TARS robot companion**

[![macOS](https://img.shields.io/badge/macOS-14.0+-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

[中文](./README.md) · **English**

</div>

Tars is a native SwiftUI macOS app. Click the capsule below the notch to open chat while the TARS robot from *Interstellar* moves between the Dynamic Island, chat status strip, and desktop. The same character is used across every AI mode.

> Swift 6 · SwiftUI · macOS 14+ · No Electron · No WebView

## Highlights

- Up to eight independent, concurrently streaming conversations
- AI Assistant, Claude Code, and Codex modes
- Sign in with ChatGPT to use shared Plus / Pro subscription allowance without an API key
- Bundled opencode for other provider models; Claude Code / Codex CLI in Advanced settings
- Markdown, GFM tables, code blocks, images, path-based documents, and Codex image generation
- ScreenCaptureKit screenshots, push-to-talk, global quick ask, and desktop Pins
- Notch status for connectivity, tool calls, steps, changed files, and completion
- One TARS robot with mechanical walking, file scanning, and desktop-icon patrol

## Modes

| Mode | Best for | Setup |
|---|---|---|
| **AI Assistant** | Chat, writing, vision, local agent tools | Sign in with ChatGPT, or configure an opencode provider |
| **Claude Code** | File edits, commands, coding tasks | Claude signed in locally |
| **Codex** | Coding, commands, image generation | Codex signed in locally |

## ChatGPT subscription

Select **ChatGPT subscription** in Settings → AI Assistant, sign in through OpenAI in your system browser, choose an account model, and run **Verify subscription connection**. Verification uses a small amount of subscription allowance and succeeds only after a completed inference turn. This follows the official [open-source/local-project authorization flow](https://developers.openai.com/siwc/token-sharing-open-source/sign-in) and public Responses API. Install a current Codex CLI supporting `app-server`; Tars supplies its own OAuth credentials and does not read your existing Codex login.

Credentials stay in the macOS Keychain. Tars validates PKCE/state, nonce and ID-token signatures, supports multiple accounts, refreshes credentials and revokes renewable sessions on sign-out. Each conversation binds its account, model and workspace. Thread mappings live in `~/.hermespet/agents/chatgpt-threads.json` with mode 0600. Local commands, document paths, images, MCP and Skills use the app-server harness. The preview does not provide ChatGPT history/memory, hosted image generation or speech endpoints; advanced Codex image generation remains a separate route. Usage shares Codex / ChatGPT Work allowance and can be managed in ChatGPT Settings → Usage. Quota errors never fall back to paid API billing. Uncertain turns are inspected, never replayed automatically.

The chat strip shows the current model and opens account details. Task activity is scoped to each conversation; click its status to inspect tool operations. Authorization, quota, and execution errors stay with the conversation until handled or dismissed. Interrupted ChatGPT tasks offer a read-only status check that never starts another turn. Account management and connection diagnostics are collapsed in settings.

## Quick start

Requires macOS 14+ and full Xcode:

```bash
git clone https://github.com/simpledavid/tars.git
cd tars
./install.sh
```

`install.sh` builds and installs `/Applications/Tars.app`.

## Build scripts

| Script | Purpose |
|---|---|
| `./build.sh` | Build `Tars.app` in the project directory |
| `./install.sh` | Build, install, and launch `/Applications/Tars.app` |
| `./make-dmg.sh` | Create Apple Silicon and Intel DMGs |

## Compatibility storage

The legacy bundle ID and storage paths remain unchanged so upgrades retain TCC permissions, conversations, and local tool configuration:

- `com.nousresearch.hermespet`
- `~/.hermespet/`
- `~/Library/Application Support/HermesPet/`
- `~/Library/Caches/HermesPet/`

These are internal compatibility identifiers. The user-facing product name is Tars.

Development constraints and architecture notes live in [CLAUDE.md](./CLAUDE.md).

## License

[Apache License 2.0](./LICENSE)

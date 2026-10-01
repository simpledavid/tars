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
- OpenAI Agents API (Beta) for managed cloud sessions with a local executor
- Bundled opencode for other provider models; Claude Code / Codex CLI in Advanced settings
- Markdown, GFM tables, code blocks, images, path-based documents, and Codex image generation
- ScreenCaptureKit screenshots, push-to-talk, global quick ask, and desktop Pins
- Notch status for connectivity, tool calls, steps, changed files, and completion
- One TARS robot with mechanical walking, file scanning, and desktop-icon patrol

## Modes

| Mode | Best for | Setup |
|---|---|---|
| **AI Assistant** | Chat, writing, vision, local agent tools | Configure Agents API credentials or an opencode provider |
| **Claude Code** | File edits, commands, coding tasks | Claude signed in locally |
| **Codex** | Coding, commands, image generation | Codex signed in locally |

## OpenAI Agents API (Beta)

Configure a model, application key and dedicated environment key in Settings → AI Assistant. Keys are stored in macOS Keychain. The application key needs Agents read/write and Responses write permissions. The environment key must only permit environment connections and belong to the same project and owner. See [OpenAI setup](https://developers.openai.com/api/docs/guides/agents-api/environments/self-hosted).

Install a Codex CLI that supports `exec-server`. Tars manages one executor per cloud session. Agent settings provide workspace and Skills directories, saved preferences, MCP servers and native multi-agent configuration. Documents are sent as paths; images are sent as image inputs. OpenAI manages cloud context compaction. Existing defaults remain on opencode until explicitly changed; retired runtime selections migrate to opencode.

Connection checks are read-only. Use the explicit conversation validation button to test the model and environment key; this incurs API usage. Stream EOF and idle are not success. Saved terminal turns and items can recover output; otherwise Tars requests cancellation and stops the executor without replaying input. Unconfirmed requests survive restarts and may require clearing the conversation. Browser approval interactions are not supported yet and cause an explicit error and cancellation.

## Quick start

Requires macOS 14+ and full Xcode:

```bash
git clone https://github.com/simpledavid/opencrab.git
cd opencrab
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

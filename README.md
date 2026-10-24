# GhostEdit

**Free, open-source grammar checker for macOS. Press one hotkey in any app. GhostEdit shows a compact correction floater with a nearby diff and Copy button; it never replaces the selected text. Connect Claude, Codex, Gemini, Grok, Ollama, or a Magpie gateway.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/Platform-macOS%2013%2B-black.svg)](https://github.com/xiaocang/GhostEdit-mac-app/releases)
[![Latest Release](https://img.shields.io/github/v/release/xiaocang/GhostEdit-mac-app)](https://github.com/xiaocang/GhostEdit-mac-app/releases/latest)

> This is a fork of [nareshnavinash/GhostEdit-mac-app](https://github.com/nareshnavinash/GhostEdit-mac-app). Releases and Homebrew updates for this fork are published from the `xiaocang` repositories.

> GhostEdit is a macOS menu bar app that corrects text system-wide. Press the correction hotkey (cmd+E by default). A small floater appears beside the selection: a ghost while the model works, a green check if nothing changed, or a narrow red/green diff with Copy.

![GhostEdit launch preview](remotion/out/TwitterBanner.png)

## Installation

### Homebrew (Recommended)

```bash
brew tap xiaocang/homebrew-tap
brew install --cask ghostedit
```

This installs GhostEdit to `/Applications`, clears the quarantine flag automatically, and supports `brew upgrade --cask ghostedit` for future updates.

## Trailer

![GhostEdit launch trailer](remotion/out/LaunchTrailerInstant.gif)

## Why GhostEdit?

- **No GhostEdit account** - connect a supported AI CLI or HTTP provider. Provider authentication and service requirements still apply.
- **Local privacy option** - Ollama at a localhost URL keeps correction text on this Mac. Cloud CLIs and remote Ollama URLs send text to their configured services.
- **Free and open source** - no premium tiers, no word limits, no feature gates.
- **Works everywhere** - correct text in any macOS app: Slack, Notion, VS Code, Mail, Pages, or any text field. One hotkey, any app.
- **Bring your own AI** - switch between Claude, Codex, Gemini, Grok, Ollama, and Magpie in Settings.
- **Review before you copy** - the hotkey never replaces the selection. Copy the result when you want it.

## How It Works

1. **Select text and press cmd+E** (configurable). GhostEdit reads the selection, or the line at the cursor when nothing is selected.
2. **A ghost appears beside the text** while the selected provider works.
3. **Nothing to change** shows a green check that fades. A real change shows a narrow diff: removed words in red, added words in green, with a Copy button.
4. **Copy does not paste back.** The original text stays where it is.

Set up one of the supported providers listed below.

## Features

### Correction

- **One hotkey**: cmd+E by default. It sends the selection, or the line at the cursor, to the provider in Settings.
- **Nearby floater**: a ghost while the model works, a green check when nothing changed, or a narrow red/green diff with Copy.
- **No automatic replacement**: Copy puts the result on the clipboard. The selection stays as it is.
- **Token preservation**: mentions, emojis, URLs, email addresses, file paths, and inline code are protected before correction.

### One hotkey

GhostEdit has one correction hotkey, cmd+E by default. Change it in **Settings > Hotkey**. It sends the selection to the provider chosen in Settings and shows the result nearby. It does not paste over the selection.

Live Feedback, when enabled, still checks spelling and grammar in the focused field and can apply those fixes itself.

### Prerequisites

GhostEdit supports command-line providers and HTTP endpoints. Configure a provider in **Settings > General**:

| Provider | Setup |
|----------|-------|
| Ollama | Install [Ollama](https://ollama.com), start it, and pull a model such as `qwen3:1.7b`. |
| Claude | Install Claude Code and authenticate with `claude auth login`. |
| OpenAI Codex | Install `@openai/codex` and authenticate with `codex login`. |
| Gemini | Install `@google/gemini-cli` and authenticate with `gemini`. |
| Grok | Install the Grok CLI and authenticate with `grok login`. |
| Magpie | Run a Magpie-compatible HTTP gateway and set its URL in Settings; the default is `http://127.0.0.1:3425`. |

Use **Refresh Models** to load the model list from the selected provider. Ollama lists installed models and available cloud models; sign in with `ollama signin` before using an Ollama cloud model.

## Configuration

GhostEdit creates these files on first launch:

- `~/.ghostedit/prompt.txt` AI prompt (editable)
- `~/.ghostedit/config.json` settings
- `~/.ghostedit/history.json` correction history

If `~/.grammarfixer` exists from older builds, GhostEdit migrates it to `~/.ghostedit` automatically.

Default `config.json`:

```json
{
  "claudePath": "",
  "codexPath": "",
  "geminiPath": "",
  "grokPath": "",
  "ollamaBaseURL": "http://127.0.0.1:11434",
  "magpieBaseURL": "http://127.0.0.1:3425",
  "provider": "claude",
  "model": "sonnet",
  "hotkeyKeyCode": 14,
  "hotkeyModifiers": 256,
  "timeoutSeconds": 60,
  "launchAtLogin": false,
  "historyLimit": 50,
  "developerMode": false,
  "language": "auto",
  "tonePreset": "default",
  "soundFeedbackEnabled": true,
  "notifyOnSuccess": false,
  "liveFeedbackEnabled": false,
  "floaterOpacity": 0.42
}
```

Notes:
- `provider` selects `"claude"`, `"codex"`, `"gemini"`, `"grok"`, `"ollama"`, or `"magpie"`.
- `model` is shared. Leave it blank to use the provider default. Grok, Ollama, and Magpie have no compiled-in default.
- `claudePath`, `codexPath`, `geminiPath`, and `grokPath` can be empty if auto-discovery works.
- `ollamaBaseURL` and `magpieBaseURL` are server addresses. Refresh Models fills the menu from the live provider and caches it. For Ollama it also adds cloud models from `https://ollama.com/api/tags`, named the way the local server runs them.
- If a model is busy or fails, GhostEdit retries with the next cached model.
- `hotkeyKeyCode` / `hotkeyModifiers` control the correction hotkey (cmd+E by default). It shows a nearby diff and does not replace the selection.
- `historyLimit` controls how many recent corrections are kept in `history.json`.
- `language` can be `"auto"` or a code such as `"en"`. Auto-detect corrects in the input language. A specific language returns that language, translating when the input is not already in it.
- `tonePreset` can be `"default"`, `"casual"`, `"professional"`, `"academic"`, or `"slack"`.
- `soundFeedbackEnabled` plays audio cues on success and error.
- `notifyOnSuccess` sends a macOS notification when a correction completes.
- `liveFeedbackEnabled` enables real-time spelling and grammar checking. The widget can still apply its own fixes.
- `floaterOpacity` is the correction box background strength, from `0.15` to `1`. Lower is more transparent. Change it in Settings > Behavior > Correction box.

### Per-App Profiles

Create `~/.ghostedit/profiles.json` to customize settings per application:

```json
[
  {
    "bundleIdentifier": "com.tinyspeck.slackmacgap",
    "tonePreset": "slack"
  },
  {
    "bundleIdentifier": "com.apple.mail",
    "tonePreset": "professional",
    "model": "sonnet"
  }
]
```

Each profile can override `tonePreset`, `model`, and `provider` for a specific app (matched by bundle identifier).

## Protected Tokens During Correction

To keep platform-specific syntax intact (especially in Slack), GhostEdit replaces static tokens with placeholders before sending text to the model, then restores them after correction. Token preservation applies to the correction hotkey and live feedback.

Protected token types:
- Mentions: `@name`, `@<id>`, and `<@id>`
- Emojis: `:hat:`, `:cat:`, etc.
- URLs: `https://...`
- Email addresses: `name@company.com`
- File paths:
  - absolute/relative Unix paths like `/tmp/file.txt`, `./notes/todo.md`
  - folder/file-style paths like `docs/readme.md`
- Inline code spans: `` `git status` ``

Failure behavior:
- If the model edits/removes placeholder tokens, GhostEdit retries once automatically.
- If the retry still fails, GhostEdit performs a best-effort restoration - any placeholders the model preserved are restored, and the correction still succeeds.

Practical effect:
- Grammar/spelling/punctuation are still corrected.
- Static items are kept exactly as typed so links, mentions, emojis, and paths survive correction.

## Accessibility Permission

GhostEdit uses macOS Accessibility APIs to read/replace selected text directly and to send `Cmd+C`/`Cmd+V` as a fallback. Grant permission at:

- System Settings > Privacy & Security > Accessibility

## GitHub Publishing

A workflow is included at `.github/workflows/release.yml`.

Push a version tag such as `v7.9.1.1` to build and publish the `.zip` and `.dmg` release assets. The workflow then updates `Casks/ghostedit.rb` in [`xiaocang/homebrew-tap`](https://github.com/xiaocang/homebrew-tap).

Configure the `HOMEBREW_TAP_TOKEN` Actions secret in this repository with contents-write access to `xiaocang/homebrew-tap`. The release workflow uses it only to commit and push the cask update. For notarized releases, add signing and notarization steps and secrets to the workflow.

## Privacy

- No accounts, no telemetry, no data collection.
- Text is sent only to the provider selected in Settings. Nothing is sent to GhostEdit servers (there are none).
- Ollama at a localhost URL keeps correction text on this Mac. Cloud CLIs and a remote Ollama URL send text to that service.
- This repo does not store local user prompt/config files from `~/.ghostedit`.

Before pushing, verify no local secrets were added:

```bash
rg -n "(api[_-]?key|token|secret|password|PRIVATE KEY)" .
```

## Acknowledgments

GhostEdit is built on the shoulders of excellent open-source projects. A huge thank you to the teams and individuals behind them:

- **[Harper](https://github.com/automattic/harper)** - The fast, privacy-first grammar checker written in Rust by Automattic. Harper powers GhostEdit's live feedback, running entirely on-device with zero network calls.

- **Apple NSSpellChecker** - macOS built-in spell and grammar checking APIs that complement Harper for comprehensive text analysis including smart quotes, em-dashes, and autocorrect suggestions.

## License

MIT

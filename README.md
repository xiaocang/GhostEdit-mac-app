# GhostEdit

**Free, open-source grammar checker for macOS. Press one hotkey in any app. GhostEdit shows a nearby diff and a Copy button. It does not replace the selected text. Use Ollama, Claude, OpenAI Codex, or Gemini.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/Platform-macOS%2013%2B-black.svg)](https://github.com/nareshnavinash/GhostEdit/releases)
[![Latest Release](https://img.shields.io/github/v/release/nareshnavinash/GhostEdit)](https://github.com/nareshnavinash/GhostEdit/releases/latest)

> GhostEdit is a macOS menu bar app that corrects text system-wide. Press the correction hotkey (cmd+E by default). A small floater appears beside the selection: a ghost while the model works, a green check if nothing changed, or a narrow red/green diff with Copy.

![GhostEdit launch preview](remotion/out/TwitterBanner.png)

## Installation

### Homebrew (Recommended)

```bash
brew tap nareshnavinash/ghostedit
brew install --cask ghostedit
```

This installs GhostEdit to `/Applications`, clears the quarantine flag automatically, and supports `brew upgrade --cask ghostedit` for future updates.

### Manual Download

Download the latest `.dmg` from the [Releases page](https://github.com/nareshnavinash/GhostEdit/releases/latest), drag GhostEdit to Applications, and grant Accessibility permission.

### macOS Installation & Troubleshooting

Because GhostEdit is not currently signed with an Apple Developer certificate, macOS Gatekeeper may flag it and show an error saying: **"Apple could not verify 'GhostEdit' is free of malware"** or **"'GhostEdit' is damaged and can't be opened."**

If you encounter this error and only see a "Move to Bin" option, you can easily bypass it using one of the following methods:

#### Method 1: Using Terminal (Recommended)
This removes the macOS "quarantine" flag from the downloaded app, allowing it to run normally.

1. Unzip the downloaded release and move `GhostEdit.app` to your **Applications** folder.
2. Open the **Terminal** app.
3. Paste the following command and press Enter:
   xattr -cr /Applications/GhostEdit.app

You can now double-click the app to open it normally! (You only need to do this once).

#### Method 2: System Settings
1. Attempt to open the app normally by double-clicking it (this triggers the error). Click Done.
2. Open your Mac's System Settings and go to Privacy & Security.
3. Scroll down to the Security section.
4. You will see a message saying that "GhostEdit" was blocked. Click the Open Anyway button next to it.
5. Enter your Mac password or use Touch ID, and click Open on the final prompt.

## Trailer

![GhostEdit launch trailer](remotion/out/LaunchTrailerInstant.gif)

## Why GhostEdit?

- **No account required** - uses AI CLIs you already have installed (Claude, Codex, Gemini). No sign-ups, no subscriptions.
- **Local privacy option** - Ollama at a localhost URL keeps correction text on this Mac. Cloud CLIs and remote Ollama URLs send text to their configured services.
- **Free and open source** - no premium tiers, no word limits, no feature gates.
- **Works everywhere** - correct text in any macOS app: Slack, Notion, VS Code, Mail, Pages, or any text field. One hotkey, any app.
- **Bring your own AI** - switch between Ollama, Claude, OpenAI Codex, and Gemini in Settings.
- **Review before you copy** - the hotkey never replaces the selection. Copy the result when you want it.

## How It Works

1. **Select text and press cmd+E** (configurable). GhostEdit reads the selection, or the line at the cursor when nothing is selected.
2. **A ghost appears beside the text** while the selected provider works.
3. **Nothing to change** shows a green check that fades. A real change shows a narrow diff: removed words in red, added words in green, with a Copy button.
4. **Copy does not paste back.** The original text stays where it is.

Install Ollama or a supported AI CLI. GhostEdit auto-detects the CLI.

## Features

### Correction

- **One hotkey**: cmd+E by default. It sends the selection, or the line at the cursor, to the provider in Settings.
- **Nearby floater**: a ghost while the model works, a green check when nothing changed, or a narrow red/green diff with Copy.
- **No automatic replacement**: Copy puts the result on the clipboard. The selection stays as it is.
- **Token preservation**: mentions, URLs, emojis, and code blocks are protected before the text is sent to the model.
- **Fallback**: a retriable model failure retries with the next available model.

### Core Features

- **One correction hotkey**: Press cmd+E by default. The result appears beside the selection and is never written back automatically.
- **Nearby result floater**: A ghost and spinner while the request runs. A green check fades when the text is already clean. Changes stay up with Copy until you click outside.
- **Copy, don't replace**: The Copy button puts the corrected text on the clipboard. The selection is left alone.
- **Multi-provider support**: Claude, Codex, Gemini, Grok, Ollama, and Magpie. Model lists come from Refresh Models, not a compiled-in catalog.
- **Multi-language support**: Correct text in 30+ languages - auto-detect or pick a specific language in Settings
- **Tone presets**: Switch between Default, Casual, Professional, Academic, and Slack tones from the menu bar
- **Writing coach**: **Sharpen My Writing Style** analyzes your past corrections and shows what you do well plus areas to improve
- **Token preservation**: Mentions, emojis, URLs, emails, file paths, and inline code are preserved during correction across all paths (cloud, local, streaming, live feedback)
- **Correction history**: Browse, copy, and export past corrections as CSV
- **Statistics dashboard**: View correction counts, success rates, provider/model breakdown, and estimated token usage
- **Narrow diff**: Changed words are shown in red and green. Unchanged runs are shortened so the floater stays small.
- **Auto-retry with fallback model**: If the selected model fails, GhostEdit automatically retries with the next available model - with smart error classification to skip non-retriable failures
- **Per-app profiles**: Configure different tone, model, or provider per application via `~/.ghostedit/profiles.json`
- **Export/import settings**: Back up or transfer your full configuration (settings + prompt) as a single JSON file
- **Customizable prompt**: Tailor the AI instructions in `~/.ghostedit/prompt.txt`
- **Sound feedback**: Audio cues for success and error (configurable)
- **Success notifications**: Optional system notifications on successful corrections
- **Menu bar tooltip**: Shows a summary of the last correction (time, text preview, provider)
- **Token estimation**: Estimated cumulative token usage shown in Statistics
- **Live feedback**: Real-time spelling, grammar, punctuation, and style checking in any text field - a floating widget shows issues as you type with smart quotes, em-dash, and symbol replacement suggestions powered by macOS native text checking and Harper
- **Ignored words**: Permanently ignore specific words across sessions via the widget or `~/.ghostedit/ignored_words.json`
- **Version check support**: Compare your version against the latest release
- Global hotkey (`Command + E` by default), configurable in **Settings...**
- Works in background (no Dock icon)
- Launch at login toggle
- Menu bar state indicator:
  - ![Idle menubar icon](remotion/out/MenuBarIconIdle.png) idle
  - ![Processing menubar icon](remotion/out/MenuBarIconProcessing.png) processing

### Correction floater

The correction hotkey always opens a small panel beside the selection. It does not replace the text.

- **Loading**: a ghost and spinner. Click outside to cancel.
- **No changes**: a green check that fades.
- **Changes**: removed words in red, added words in green, and a Copy button. The panel stays until you click outside.

Click outside to dismiss. Copy leaves the original text in place.

### Live Feedback

When enabled in **Settings > Behavior**, a floating widget appears near the active text field and checks your writing in real time using macOS built-in text checking and Harper - no AI API calls needed.

**What it detects:**

| Category | Examples |
|----------|----------|
| Spelling | Misspelled words with correction suggestions |
| Grammar | Subject-verb agreement, punctuation errors |
| Smart quotes | Straight `"..."` → curly `\u201c...\u201d` |
| Smart dashes | `--` → em-dash `\u2014` |
| Symbol replacement | `(c)` → `\u00a9`, `(tm)` → `\u2122` |
| Autocorrect | Common typos the system already knows |

The widget shows a colored status dot (green = clean, red = issues found). Click the widget to toggle the detail popover listing each issue with suggestions. Each issue row has action buttons: accept the fix, ignore once, or always ignore the word. Drag the widget anywhere - it stays put until you switch apps. Enable from **Settings > Behavior > Live Feedback** or set `"liveFeedbackEnabled": true` in config.

### One hotkey

GhostEdit has one correction hotkey, cmd+E by default. Change it in **Settings > Hotkey**. It sends the selection to the provider chosen in Settings and shows the result nearby. It does not paste over the selection.

Live Feedback, when enabled, still checks spelling and grammar in the focused field and can apply those fixes itself.

### Prerequisites

Choose local Ollama or one of the cloud CLIs:

| Provider | Install | Auth |
|----------|---------|------|
| Ollama (local HTTP) | Install [Ollama](https://ollama.com), then `ollama pull qwen3:1.7b` | No login for local models |
| Claude | `brew install claude` or [download](https://claude.com/claude-code) | `claude auth login` |
| OpenAI Codex | `npm install -g @openai/codex` | `codex login` |
| Gemini | `npm install -g @google/gemini-cli` | `gemini` |

**Supported models:**

| Provider | Models |
|----------|--------|
| Claude | claude-haiku-4-5, claude-sonnet-4-5, claude-sonnet-4-6, claude-opus-4-6, haiku, sonnet, opus |
| OpenAI Codex | gpt-5-codex, gpt-5.3-codex, gpt-5 |
| Gemini | gemini-2.5-flash-lite, gemini-2.5-flash, gemini-2.5-pro, gemini-3-flash-preview, gemini-3-pro-preview, gemini-3.1-pro-preview |
| Ollama | Installed model names from **Refresh Models**, plus Ollama cloud models such as `kimi-k3:cloud` and `gpt-oss:120b-cloud` |

### Local Ollama Setup

1. Start the Ollama app, or run `ollama serve`.
2. Install a model: `ollama pull qwen3:1.7b`.
3. In **Settings > General**, choose **Ollama (Local)**. Keep Server URL `http://127.0.0.1:11434` for on-device corrections.
4. Click **Refresh Models**. The menu lists installed models and Ollama cloud models (`name:cloud`, or `name:tag-cloud` when the catalog name has a size tag). Select one and save. Cloud models run through the local server; sign in with `ollama signin` first.
5. Focus or select text in another app and press **cmd+E**. Copy the diff if you want the corrected text.

No Python environment or cloud CLI is needed for Ollama. Small models trade correction quality for latency; copy the diff if you want the corrected text. Connection failures suggest starting Ollama; missing-model errors include the `ollama pull` command. If using a proxy, set its server base URL (not `/api/chat`). HTTPS is supported; authenticated services such as Magpie are not configured by this integration.

## Build from Source

1. Install dependencies:

```bash
brew install xcodegen
```

Install [Rust via rustup](https://rustup.rs). Xcode builds the Harper static library and Swift C module automatically using `scripts/build_harper.sh`; generated files stay in `build/`. Universal builds need both Rust targets:

```bash
rustup target add aarch64-apple-darwin x86_64-apple-darwin
```

2. Generate Xcode project:

```bash
xcodegen generate --spec project.yml
```

3. Open in Xcode:

```bash
open GhostEdit.xcodeproj
```

4. Set your signing team and run.

### Local development build

`dev.sh` builds with Xcode's **Apple Development** signing identity, verifies the signature, and installs the app in `/Applications/GhostEdit.app`. It restarts GhostEdit if it was already running:

```bash
./dev.sh --run
```

The default development team is `WNF89D7V44`, matching the local Xcode setup. To use another team or a Debug build:

```bash
DEVELOPMENT_TEAM=YOUR_TEAM_ID CONFIGURATION=Debug ./dev.sh --run
```

Full Xcode must have a valid Apple Development certificate for that team. The script generates the Xcode project, keeps build products in `build/DerivedDataDev`, and preserves the separate app and framework bundle identifiers. Omit `--run` to install without launching when GhostEdit is not already running.

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

## Developer Mode

GhostEdit includes a **Developer Mode** that shows what happens behind the scenes during each text correction. When enabled, a live console window displays every step of the correction pipeline in real time.

### How to enable

- **Menu bar**: Click the GhostEdit menu bar icon > **Developer Mode** (toggles on/off)
- **Settings**: Check **Enable Developer Mode** in the Settings window
- **Config file**: Set `"developerMode": true` in `~/.ghostedit/config.json`

### What you see

The Developer Console shows timestamped, color-coded log entries for each phase:

| Phase | Description |
|-------|-------------|
| `TEXT_CAPTURE` | Selected text read via Accessibility or clipboard |
| `TOKEN_PROTECTION` | Mentions, emojis, URLs replaced with placeholders |
| `CLI_RESOLUTION` | CLI executable path discovery |
| `CLI_EXECUTION` | Full command with arguments, process lifecycle |
| `CLI_RESPONSE` | AI response content and length |
| `TOKEN_RESTORATION` | Placeholder replacement with original tokens |
| `PASTE_BACK` | Text replacement via AX or clipboard paste |

Use **Clear** to reset the log and **Copy All** to copy the full log to clipboard.

## Accessibility Permission

GhostEdit uses macOS Accessibility APIs to read/replace selected text directly and to send `Cmd+C`/`Cmd+V` as a fallback. Grant permission at:

- System Settings > Privacy & Security > Accessibility

## Testing

Run the full test+coverage gate:

```bash
./scripts/run_tests_with_coverage.sh
```

This gate enforces:
- All 684+ unit and integration tests must pass.
- 100% line coverage on 40+ guarded source files.

The same gate is wired into:
- `.githooks/pre-commit`
- `.githooks/pre-push`

Enable repo hooks locally:

```bash
git config core.hooksPath .githooks
```

## Create Installable Artifacts

Build signed release artifacts (`.zip` and `.dmg`):

```bash
./scripts/build_release.sh
```

Optional: sign with a specific Developer ID identity:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build_release.sh
```

By default, the build script uses ad-hoc signing with a stable designated requirement (`identifier "com.ghostedit.app"`). This helps macOS treat app updates as the same trusted app for Accessibility more reliably than cdhash-based ad-hoc signing.

For the most reliable persistence of Accessibility trust across updates, use a consistent real signing identity (Developer ID or Apple Development).

Artifacts are generated in:

- `build/release/GhostEdit-macOS.zip`
- `build/release/GhostEdit-macOS.dmg`

For true out-of-the-box install on other Macs (no Gatekeeper warning), notarize the DMG:

```bash
NOTARY_PROFILE="your-notary-profile" ./scripts/notarize_release.sh build/release/GhostEdit-macOS.dmg
```

`NOTARY_PROFILE` is a keychain profile created with Apple `notarytool`.

## GitHub Publishing

A workflow is included at `.github/workflows/release.yml`.

- Push a tag like `v1.0.0`
- Workflow builds and uploads `.zip` and `.dmg` to the GitHub Release
- For notarized releases, add signing/notary steps and secrets to the workflow

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

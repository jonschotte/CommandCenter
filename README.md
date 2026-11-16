# Command Center

A native macOS app for running and watching all your coding-agent terminals, local models, and system resources.

## Build & install

```sh
./build.sh            # builds build/Command Center.app
./build.sh --install  # also copies it to /Applications
./build.sh --clean    # rebuild the vendored SwiftTerm library too
```

Requires only the Xcode Command Line Tools. SwiftPM is broken on this machine, so the build calls `swiftc` directly.
SwiftTerm v1.20.0 is vendored in `Vendor/SwiftTerm` (MIT).

## Features

- **Sessions**: pick a folder and an agent (Claude Code with a chosen model, a local MLX model, a shell, or any command) and launch it in an embedded terminal. Each session shows live status (working / idle / exited), CPU and RAM for its whole process tree, and a 🔔 badge when it finishes a burst of work while you're looking elsewhere. When the agent exits, the tab drops into a shell in the same folder. ⌘T opens a new session; ⇧⌘T opens a plain terminal right away. Terminals use your default Terminal.app profile (font, colors, cursor) and keep 10,000 lines of scrollback. The Terminal menu has Find (⌘F, ⌘G), Clear Scrollback (⌘K) and text size (⌘+, ⌘−, ⌘0).
- **Sessions survive quitting**: each in-app session runs under `cc-keeper` (`Keeper/cc-keeper.c`), a small background process that holds the terminal. Quit or crash the app and the sessions keep running. They reconnect on the next launch and replay up to 512 KB of recent output. **Stop Sessions & Quit** ends them instead. State lives in `~/.commandcenter/s/`.
- **Status from Claude itself**: in-app Claude sessions load `~/.commandcenter/hooks/cc-settings.json` through `claude --settings`. Claude Code's hooks report *Working*, *Needs you* (permission prompt), and *Your turn* (finished), and these drive the status dots, dock badge, and macOS notifications. Settings (⌘,) has notification toggles and an opt-in to add the hook to `~/.claude/settings.json` so sessions started anywhere report too. A backup is made first.
- **Groups**: make named, colored groups (sidebar **Group** button or a row's *Move to Group* menu). Drag terminals from the sidebar or dashboard onto a group, or onto *Sessions* to ungroup. Groups hold in-app sessions and outside terminals, persist across launches, and follow a session through Restart and Move Here. The dashboard shows each group as a section of live-preview tiles.
- **Memory**: click RAM in the sidebar or the Memory card for a breakdown (app, wired, compressed, cached, free) and every app ranked by memory, with helper processes grouped under their app. Expand an app to see or quit its processes.
- **Other Terminals**: agents already running in Terminal.app or iTerm2 appear in the sidebar. Click one to see a live mirror of its tab. Type in the box and press Return to send text. The buttons send Esc, ⌃C, ↑/↓, ⇧Tab, and Enter. The first use triggers macOS's Automation prompt. Special keys also need Accessibility permission. **Move Here** reopens one as a full terminal inside the app. For Claude it resumes the same conversation, using `~/.claude/sessions/<pid>.json`, and can close the original tab.
- **All Running Agents**: finds claude, codex, aider, gemini, opencode, and other agents, plus model servers (ollama, llama-server, mlx_lm), anywhere on the Mac. Shows each one's folder, host app, uptime, CPU, and RAM. You can stop or kill them, reveal the folder, or resume a Claude conversation inside the app.
- **System**: CPU (total and per core), memory breakdown, swap, GPU utilization and memory, storage per volume, network, thermal state, and top processes.
- **Models & Server**: lists MLX, safetensors, and GGUF models in `~/.lmstudio/models`, the Hugging Face cache, and any folders you add. One click installs the MLX engine (uv, Python 3.12, and mlx-lm in `~/Library/Application Support/CommandCenter/venv`). Starts and stops `mlx_lm.server` with any chat model. If the port (default 8080) is taken by another app, it moves to the next free port and notes it in the server log.
- **Chat**: streaming chat against the built-in server, LM Studio (:1234), or Ollama (:11434).
- **API Access**: OpenAI-compatible endpoint info with copy-paste curl, Python, and JS snippets. An optional toggle exposes it on your LAN.

## Layout

| File | Purpose |
|---|---|
| `Sources/CommandCenter/Sessions.swift` | Session model, PTY launch, store, terminal hosting |
| `Sources/CommandCenter/ProcessScanner.swift` | `ps`/`lsof` scan, agent detection, process trees |
| `Sources/CommandCenter/SystemMonitor.swift` | Mach/IOKit CPU, memory, GPU, disk, network |
| `Sources/CommandCenter/TerminalBridge.swift` | AppleScript control of Terminal.app / iTerm2 tabs by tty |
| `Sources/CommandCenter/AgentEvents.swift` | Claude Code hook events → status + notifications |
| `Keeper/cc-keeper.c` | Background session keeper (survives app quit) |
| `Sources/CommandCenter/Groups.swift` | Terminal groups: storage, menus, drag-and-drop |
| `Sources/CommandCenter/Theme.swift` | Colors, gradients, glow cards, Core Animation status pulse |
| `Sources/CommandCenter/Models.swift` | Model discovery, mlx_lm.server control, chat client |
| `Sources/CommandCenter/*View*.swift` | SwiftUI screens |

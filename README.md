# CPUTemp

A macOS menu bar app and CLI for Apple Silicon. It shows live CPU temperature with a sparkline and a 10-minute history. It also has a one-click "hard reset" that kills runaway apps, AI agents and node processes without a reboot.

- **Menu bar:** the hottest die temperature, with a coloured dot (green under 60 °C, orange under 80 °C, red above).
- **Menu:** a 2-minute sparkline, the hottest core, the average across all sensors, the peak this session, and a launch-at-login toggle.
- **`cputemp` CLI:** a thermal snapshot with temperatures, macOS thermal state, a 10-minute trend, load average, power source and the top CPU processes. Add `--json` for machine-readable output.
- **Claude Code hook:** `cputemp --hook` adds the snapshot to your prompt whenever you ask about heat, fans, throttling or a slow machine.
- **Kill All Background Processes:** a danger button for when agents, dev servers or Electron apps are cooking your Mac. See [Hard reset](#hard-reset).

It needs no root, no kernel extension and no dependencies. Temperatures come from the same IOHID sensor interface that tools like Stats and macmon use.

## Requirements

- An Apple Silicon Mac (M1 or later) on macOS 14 Sonoma or newer
- Xcode Command Line Tools for `swiftc`: `xcode-select --install`

## Install

```sh
git clone https://github.com/aavora-tr/cpu-temp-menu.git
cd cpu-temp-menu
./build.sh
```

`build.sh` compiles both binaries and ad-hoc signs them. It installs:

| What | Where |
| --- | --- |
| Menu bar app | `~/Applications/CPUTemp.app` (launched automatically) |
| CLI | `~/.local/bin/cputemp` |

Make sure `~/.local/bin` is on your `PATH`. To start the app when you log in, turn on **Launch at Login** in its menu.

To update, run `git pull && ./build.sh`. The script quits and replaces the running app.

### Agent install

Paste this into Claude Code, or any coding agent with shell access:

```text
Install CPUTemp from https://github.com/aavora-tr/cpu-temp-menu:
1. Check this is an Apple Silicon Mac on macOS 14 or later, and that `swiftc` exists
   (if it doesn't, tell me to run `xcode-select --install` and stop).
2. Clone the repo into ~/repos/cpu-temp-menu (or `git pull` if it's already there)
   and run ./build.sh.
3. Make sure ~/.local/bin is on my PATH in ~/.zshrc; add it if it isn't.
4. Run `cputemp` and show me the output to confirm it works.
5. If you are Claude Code: add a UserPromptSubmit hook to ~/.claude/settings.json
   that runs `"$HOME/.local/bin/cputemp" --hook 2>/dev/null || true` with a 5 second
   timeout, and allow `Bash(cputemp)` and `Bash(cputemp *)` in permissions.
   Merge into the existing settings; don't overwrite them. Show me the diff first.
6. Add a line to ~/.claude/CLAUDE.md saying the `cputemp` CLI is available for
   questions about CPU heat, fans, throttling or the machine feeling slow.
```

### Claude Code hook (manual)

To set up the hook yourself, add this to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$HOME/.local/bin/cputemp\" --hook 2>/dev/null || true",
            "timeout": 5
          }
        ]
      }
    ]
  },
  "permissions": {
    "allow": ["Bash(cputemp)", "Bash(cputemp *)"]
  }
}
```

The hook reads the prompt from stdin. It only outputs anything when the prompt mentions temperature, heat, fans, throttling, CPU, or a sluggish or laggy machine. Otherwise it prints nothing and costs nothing.

## Usage

```console
$ cputemp
CPU temperature (Apple M5 Pro die sensors, 42 sensors)
  hottest: 44.9°C   average: 43.1°C
  macOS thermal state: nominal
  trend (hottest): 1m ago 46.1°C, 5m ago 56.6°C, 10m ago 48.2°C; 10-min peak 64.1°C
  load average: 3.02 / 4.14 / 4.55 (1/5/15 min) on 15 cores
  power: AC power; 100%; charged
Top processes by CPU (% of one core):
    25.8%  claude (pid 51937)
    13.2%  WindowServer (pid 968)
    ...

$ cputemp --json      # the same data as JSON
```

The trend and peak come from the menu bar app. It logs one sample per second to `~/Library/Application Support/CPUTemp/history.json` and keeps the last 10 minutes. The CLI works without the app running, but then it can't show any trend.

## Hard reset

**Kill All Background Processes…**, in red at the bottom of the menu, is a reboot without the reboot. Use it when AI agents, MCP servers, dev servers or orphaned node processes from Electron apps have piled up and the fans won't stop.

> [!WARNING]
> This force-quits **every process you own**, including all open apps, so unsaved work is lost. It also kills Terminal and its shells, Claude Code and other agents, node, python, Docker and Electron helper processes.

**Spared:**

- macOS's own processes: anything run from `/System`, `/usr/libexec`, `/usr/sbin`, `/sbin` or `/Library/Apple`
- core session UI: loginwindow (so you aren't logged out), Finder, Dock, the menu bar, Control Center and Notification Center
- anything owned by root or other system accounts
- the Microsoft Intune device-management agent and Company Portal
- CPUTemp itself

**Safeguards:**

- Hover the item for a tooltip that explains what it does.
- Clicking opens a confirmation listing how many processes will die and what they are, for example "Google Chrome ×27, node ×23, Claude ×14, …".
- Return and Esc both cancel. Only clicking the red button kills anything.
- Processes first get SIGTERM so they can shut down cleanly. Anything still alive after 3 seconds gets SIGKILL.

Background agents that macOS restarts automatically will reappear within seconds. That's expected.

To spare more processes, add their names to `protectedNames` in `HardReset.swift` and rebuild.

## Uninstall

```sh
pkill -x CPUTemp
rm -rf ~/Applications/CPUTemp.app ~/.local/bin/cputemp ~/Library/Application\ Support/CPUTemp
```

Turn off **Launch at Login** before you delete the app. If you added the Claude Code hook, remove it from `~/.claude/settings.json`.

## Project layout

| File | Purpose |
| --- | --- |
| `TempSensors.swift` | Reads die temperatures through the private IOHIDEventSystem API |
| `History.swift` | 10-minute sample log shared between the app and the CLI |
| `HardReset.swift` | Picks and kills the hard-reset targets |
| `App/main.swift` | Menu bar app (AppKit) |
| `CLI/main.swift` | `cputemp` CLI and Claude Code hook |
| `build.sh` | Builds, signs and installs both |

## Caveats

- Temperatures use a private Apple API. It works on current macOS releases, but Apple can change it without notice.
- Sensor names and counts differ by chip. The app reports the hottest and average of all die sensors it finds.

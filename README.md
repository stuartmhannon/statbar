# StatBar

A floating macOS system monitor — CPU, GPU, memory, network, disk, and Ollama model status in a compact always-on-top panel.

<p align="center">
  <img src="https://grainworks.tech/projects/statbar/screenshot.png" alt="StatBar screenshot" width="480">
</p>

## Features

- **Zero config** — launches with sensible defaults, auto-creates `~/.config/statbar/config.json`
- **Hot-reload** — edit `config.json` while running, changes apply instantly
- **Live stats** — CPU (Mach), GPU (IOKit/AGXAccelerator), memory (Mach VM), network (`getifaddrs`), disk (APFS volume)
- **Ollama integration** — shows running models with parameter size, quantization, context length, and GPU usage
- **Configurable layout** — 6 stat sections in any order, each individually toggleable
- **MCP server** — configure remotely via Hermes Agent or any MCP-compatible client
- **Pure Swift + Python stdlib** — zero dependencies beyond macOS 14+

## Quick Start

```bash
git clone https://github.com/stuartmhannon/statbar.git
cd statbar
./compile.sh
open StatBar.app
```

Add StatBar.app to Login Items for auto-launch on boot.

## Configuration

All settings live in `~/.config/statbar/config.json`. The file auto-creates on first launch.

Key sections:

| Section | What it controls |
|---|---|
| `window` | Position, size, min/max height |
| `appearance` | Background color/opacity, shadow, titlebar |
| `stats` | Visibility, colors, section order, network interface prefixes |
| `ollama` | Endpoint URL, timeout, enabled/disabled |

## MCP Tools

When `statbar-mcp` is running, Hermes Agent can control StatBar remotely:

- `statbar_get_config` — dump current config
- `statbar_update_config` — partial deep-merge (change any subset of keys)
- `statbar_reset_config` — restore defaults
- `statbar_get_status` — check if StatBar is running

## Requirements

- macOS 14.0+
- Apple Silicon (optional, Intel works for CPU/memory/network/disk; GPU requires AGXAccelerator)
- Command Line Tools (`swiftc`, `python3`)

## License

MIT

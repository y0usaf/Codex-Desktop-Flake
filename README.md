# Codex Desktop for Linux

Run [OpenAI Codex Desktop](https://openai.com/codex/) on Linux.

The official Codex Desktop app is macOS-only. This project provides an automated installer that converts the macOS `.dmg` into a working Linux application.

## How it works

The installer:

1. Extracts the macOS `.dmg` (using `7z`)
2. Extracts `app.asar` (the Electron app bundle)
3. Rebuilds native Node.js modules (`node-pty`, `better-sqlite3`) for Linux
4. Removes macOS-only modules (`sparkle` auto-updater)
5. Downloads Linux Electron (same version as the app — v40)
6. Repacks everything and creates a launch script

## Prerequisites

**Note:** The following prerequisites are only required for the shell-script installation paths (Options B and C). If using the Nix flake (Option A, recommended), no additional prerequisites are needed beyond Nix itself.

**Node.js 20+**, **npm**, **Python 3**, **7z**, **curl**, **unzip**, and **build tools** (gcc/g++/make).

### Debian/Ubuntu

```bash
sudo apt install nodejs npm python3 p7zip-full curl unzip build-essential
```

### Fedora

```bash
sudo dnf install nodejs npm python3 p7zip curl unzip
sudo dnf groupinstall 'Development Tools'
```

### Arch

```bash
sudo pacman -S nodejs npm python p7zip curl unzip base-devel
```

You also need the **Codex CLI**:

```bash
npm i -g @openai/codex
```

## Installation

### Option A: Nix Flake (Recommended for Nix/NixOS)

For reproducible, dependency-free installation on NixOS or systems with Nix:

```bash
# Direct installation from flake
nix run github:y0usaf/codex-desktop-flake

# Or add to your own flake inputs:
codex-desktop-flake = {
  url = "github:y0usaf/codex-desktop-flake";
  inputs.nixpkgs.follows = "nixpkgs";
};

# Then install/use the package from outputs:
# packages.${system}.default
# apps.${system}.default
```

The flake handles all dependencies (Electron 40, Node.js, Python, 7z) automatically. The app runs with Wayland/Ozone support enabled by default.

**Note:** The flake uses `electron_40` from nixpkgs and recompiles pinned native modules (`better-sqlite3`, `node-pty`) for Linux during the build. If the upstream DMG updates these module versions, `package.nix` must be updated with the new tarball hashes.

### Option B: Auto-download DMG

```bash
git clone https://github.com/y0usaf/codex-desktop-flake.git
cd codex-desktop-flake
chmod +x install.sh
./install.sh
```

### Option C: Provide your own DMG

Download `Codex.dmg` from [openai.com/codex](https://openai.com/codex/), then:

```bash
./install.sh /path/to/Codex.dmg
```

## Usage

### Nix Flake (Option A)

If you installed via the Nix flake, you can run the app directly:

```bash
nix run github:y0usaf/codex-desktop-flake
```

To add it to your NixOS system configuration, include the flake as an input and add the package to your `environment.systemPackages`:

```nix
# flake.nix
{
  inputs.codex-desktop-flake = {
    url = "github:y0usaf/codex-desktop-flake";
    inputs.nixpkgs.follows = "nixpkgs";
  };
}

# configuration.nix (inside the module)
{ pkgs, inputs, ... }:
{
  environment.systemPackages = [
    inputs.codex-desktop-flake.packages.${pkgs.system}.default
  ];
}
```

The `.desktop` file is installed automatically, so the app will appear in your desktop environment's application launcher.

### Shell-script install (Options B/C)

The app is installed into `codex-app/` next to the install script:

```bash
codex-desktop-flake/codex-app/start.sh
```

Or add an alias to your shell:

```bash
echo 'alias codex-desktop="~/codex-desktop-flake/codex-app/start.sh"' >> ~/.bashrc
```

### Custom install directory

```bash
CODEX_INSTALL_DIR=/opt/codex ./install.sh
```

## How it works (technical details)

The macOS Codex app is an Electron application. The core code (`app.asar`) is platform-independent JavaScript, but it bundles:

- **Native modules** compiled for macOS (`node-pty` for terminal emulation, `better-sqlite3` for local storage, `sparkle` for auto-updates)
- **Electron binary** for macOS

The installer replaces the macOS Electron with a Linux build and recompiles the native modules using `@electron/rebuild`. The `sparkle` module (macOS-only auto-updater) is removed since it has no Linux equivalent.

A small Python HTTP server is used as a workaround: when `app.isPackaged` is `false` (which happens with extracted builds), the app tries to connect to a Vite dev server on `localhost:5175`. The HTTP server serves the static webview files on that port.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `Error: write EPIPE` | Make sure you're not piping the output — run `start.sh` directly |
| Blank window | Check that port 5175 is not in use: `lsof -i :5175` |
| `CODEX_CLI_PATH` error | Install CLI: `npm i -g @openai/codex` |
| GPU/rendering issues | Try: `./codex-app/start.sh --disable-gpu` |
| Sandbox errors | The `--no-sandbox` flag is already set in `start.sh` |

> **Linux/NixOS sandbox note:** The app runs with `--no-sandbox` because no SUID sandbox helper is available in the Nix store (or in typical extracted-Electron setups). This is a known Electron/NixOS limitation and not a configuration error. The Chromium sandbox requires a setuid binary that is not provided by Nix-packaged Electron, so `--no-sandbox` is the standard workaround.

## Reliability checks

This repo uses a minimal reliability layer to catch breakage without heavy test infrastructure:

- CI on PRs/pushes runs `nix build .#packages.x86_64-linux.default`
- CI then runs a short smoke launch (headless via Xvfb) to ensure the app does not crash immediately
- The daily DMG hash automation also runs a build validation before opening a PR

### Manual release checklist

Before merging substantial packaging changes, do a quick local validation:

- App launches (`nix run .` or `./codex-app/start.sh`)
- Codex CLI is detected (`codex` on PATH or `CODEX_CLI_PATH` set)
- Terminal opens in the app
- Basic prompt/response round-trip works

## Disclaimer

This is an unofficial community project. Codex Desktop is a product of OpenAI. This tool does not redistribute any OpenAI software — it automates the conversion process that users perform on their own copies.

## License

MIT

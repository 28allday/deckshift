# DeckShift

**Version 0.1.0** — Steam Deck-style gaming mode for Linux + Hyprland. Press `Super+Shift+S` to enter Gaming Mode (Steam Big Picture in Gamescope), `Super+Shift+R` to return to your desktop.

Lineage: forked from [Super-Shift-S-Omarchy-Deck-Mode](https://git.no-signal.uk/nosignal/Super-Shift-S-Omarchy-Deck-Mode), briefly renamed Omarchy Deck, then renamed DeckShift as the project moves toward distro-portability.

> **Current status**: targets [Omarchy](https://omarchy.com) (Arch + Hyprland + SDDM + iwd). Works on other Arch + Hyprland setups with minor manual tweaks. Cross-distro support (Fedora / openSUSE / Cachy) is the next direction.

## What's New vs Super-Shift-S

- **Gaming Mode settings TUI** — a floating gum-based TUI launched from Walker (`Super+Space → "DeckShift Settings"`) for adjusting monitor, GPU, resolution, and refresh rate after install. No more hand-editing `gamescope-session-plus.conf`.
- **NVIDIA driver branch auto-pick** — Pascal/Maxwell/Volta cards (GTX 9xx/10xx, Quadro P/M) get the legacy `nvidia-580xx-utils` driver automatically via Omarchy's `omarchy-hw-nvidia-gsp` helper. Modern Turing+ cards stay on `nvidia-utils`.
- **Idempotent package installs** — uses Omarchy's `omarchy-pkg-add` everywhere, which double-checks pacman actually installed each package.
- **Optional Xbox Bluetooth controller support** — opt-in step installs `xpadneo-dkms` for proper button mapping and rumble with wireless Xbox pads.
- **Intel GPU support** — Intel-only systems (Iris Xe, Arc) are now supported. Older Gen8/9 (Skylake/Kaby Lake) gets a performance warning before continuing. The `NO DICE CHICAGO - INTEL DETECTED` block-out is gone.
- **Multilib check removed** — Omarchy ships with multilib enabled.

## Settings TUI

After install, launch `DeckShift Settings` from Walker (or run `deckshift-settings` directly) to change Gaming Mode display settings without editing config files:

| Option | What it sets in `gamescope-session-plus.conf` |
|--------|------------------------------------------------|
| Monitor      | `OUTPUT_CONNECTOR` (auto-detected from connected DRM outputs) |
| Resolution   | `SCREEN_WIDTH` / `SCREEN_HEIGHT` (offers monitor's native modes + common presets) |
| Refresh rate | `CUSTOM_REFRESH_RATES` (parsed from EDID, or common rates as fallback) |
| GPU          | `VULKAN_ADAPTER` + `GBM_BACKEND` (NVIDIA) or `DRI_PRIME` (AMD) — useful on hybrid laptops |

The TUI launches as a floating window via Omarchy's `TUI.float` pattern. Selections are **buffered** — nothing is written to disk until you pick **Save and exit**. **Cancel** discards unsaved changes. Saved changes apply next time you enter Gaming Mode (`Super+Shift+S`).

## What It Does

This installer transforms your desktop into a dual-mode system:

- **Desktop Mode** - Your normal Hyprland session
- **Gaming Mode** - Full-screen Steam Big Picture running inside Gamescope (the same compositor used by the Steam Deck), with automatic performance tuning, controller support, and external drive mounting

Switching between modes is seamless - SDDM handles session transitions, and all your network, audio, and peripherals carry over automatically.

## Requirements

- **OS**: [Omarchy](https://omarchy.com) (Arch Linux)
- **GPU**: AMD (discrete or APU), NVIDIA (discrete), or Intel (Arc / Iris Xe)
  - Intel Arc (Alchemist, Battlemage): well-supported
  - Tiger Lake / Alder Lake Iris Xe: playable for indies / older AAA
  - Older Gen8/9 Intel (Skylake, Kaby Lake): expect slow/glitchy — installer warns and asks before continuing
  - Intel iGPU + AMD/NVIDIA dGPU configurations: dGPU is used for gaming
- **AUR Helper**: yay or paru (for ChimeraOS session packages)

> **Note**: This script is designed specifically for Omarchy and its stack (Hyprland, SDDM, iwd, UWSM, PipeWire). It is not intended for other Arch installations or distributions.

## Quick Start

```bash
git clone https://git.no-signal.uk/nosignal/deckshift.git
cd deckshift
chmod +x deckshift.sh
./deckshift.sh
```

The installer is fully interactive and will walk you through each step.

## Usage

| Action | Keybind |
|--------|---------|
| Enter Gaming Mode | `Super + Shift + S` |
| Return to Desktop | `Super + Shift + R` |
| Exit to Desktop (fallback) | Steam > Power > Exit to Desktop |

### Command-Line Options

```
./deckshift.sh              # Full installation
./deckshift.sh --verify     # Verify installation only
./deckshift.sh --version    # Show version
./deckshift.sh --help       # Show help
```

## What Gets Installed

### Packages

The installer checks for and offers to install:

**Core Steam Dependencies**
- `steam`, `gamescope`, `mangohud`, `gamemode`
- Vulkan loaders and Mesa libraries (32-bit and 64-bit)
- Audio libraries (`lib32-alsa-plugins`, `lib32-libpulse`, `lib32-openal`)
- Networking (`networkmanager`, `lib32-libnm`)
- Fonts (`ttf-liberation`)

**GPU-Specific Drivers**
- **NVIDIA (Turing+ / GSP firmware — GTX 16xx, RTX 20-50xx, etc.)**: `nvidia-utils`, `lib32-nvidia-utils`, `nvidia-settings`, `libva-nvidia-driver`
- **NVIDIA (legacy Maxwell/Pascal/Volta — GTX 9xx/10xx, Quadro P/M)**: `nvidia-580xx-utils`, `lib32-nvidia-580xx-utils`, `nvidia-settings`, `libva-nvidia-driver`
- **AMD**: `vulkan-radeon`, `lib32-vulkan-radeon`, `libvdpau`, `lib32-libvdpau`
- **Intel**: `vulkan-intel`, `lib32-vulkan-intel`, `intel-media-driver`

The correct NVIDIA driver branch is auto-selected via Omarchy's `omarchy-hw-nvidia-gsp` / `omarchy-hw-nvidia-without-gsp` helpers — no manual override needed. Intel-only systems get a generation warning + Y/N prompt before continuing (Skylake/Kaby Lake era is slow; Tiger Lake / Arc is fine).

**AUR Packages** (via yay/paru)
- `gamescope-session-git` - ChimeraOS base session framework
- `gamescope-session-steam-git` - ChimeraOS Steam session with compatibility scripts
- `proton-ge-custom-bin` (optional)

**Other Requirements**
- `python-evdev` - For the keyboard shortcut monitor
- `ntfs-3g` - For mounting NTFS game drives
- `udisks2` - For external drive auto-mounting
- `xcb-util-cursor`, `libcap`, `curl`, `pciutils`

**Optional: Xbox Bluetooth Controllers**
- `xpadneo-dkms`, `linux-headers` - Wireless Xbox pad button mapping & rumble for Big Picture / RetroArch (wired pads work without this)
- Prompted opt-in during install; pair with `Super+Ctrl+B`

Package installs use Omarchy's `omarchy-pkg-add` (idempotent, double-checks pacman actually installed each package).

### Files Created

#### Session Scripts
| Path | Purpose |
|------|---------|
| `/usr/local/bin/switch-to-gaming` | Switches from Hyprland to Gaming Mode |
| `/usr/local/bin/switch-to-desktop` | Switches from Gaming Mode back to Hyprland |
| `/usr/local/bin/gamescope-session-nm-wrapper` | Main session wrapper (performance mode, NM, drive mounting) |
| `/usr/local/bin/gaming-session-switch` | Helper to toggle SDDM session config between modes |
| `/usr/local/bin/gaming-keybind-monitor` | Python daemon monitoring `Super+Shift+R` in Gaming Mode |
| `/usr/lib/os-session-select` | Handler for Steam's "Exit to Desktop" button |
| `/usr/local/lib/gamescope-nvidia/gamescope` | NVIDIA wrapper adding `--force-composition` flag |

#### NetworkManager Integration
| Path | Purpose |
|------|---------|
| `/usr/local/bin/gamescope-nm-start` | Starts NetworkManager on gaming session entry |
| `/usr/local/bin/gamescope-nm-stop` | Stops NetworkManager and restores iwd on session exit |
| `/etc/NetworkManager/conf.d/10-iwd-backend.conf` | Configures NM to use iwd backend (if iwd detected) |
| `/etc/NetworkManager/conf.d/20-unmanaged-systemd.conf` | Prevents NM/systemd-networkd conflicts (if networkd detected) |

#### External Drive Support
| Path | Purpose |
|------|---------|
| `/usr/local/bin/steam-library-mount` | Auto-detects and mounts drives with Steam libraries |

#### Session & Display Manager
| Path | Purpose |
|------|---------|
| `/usr/share/wayland-sessions/gamescope-session-steam-nm.desktop` | SDDM session entry for Gaming Mode |
| `/etc/sddm.conf.d/zz-gaming-session.conf` | SDDM autologin session switching config |

#### Permissions & Security
| Path | Purpose |
|------|---------|
| `/etc/sudoers.d/gaming-session-switch` | Passwordless sudo for session switching, NM, bluetooth |
| `/etc/sudoers.d/gaming-mode-sysctl` | Passwordless sudo for performance sysctl tuning |
| `/etc/polkit-1/rules.d/50-gamescope-networkmanager.rules` | Polkit rules for NM D-Bus access |
| `/etc/polkit-1/rules.d/50-udisks-gaming.rules` | Polkit rules for external drive mounting |
| `/etc/udev/rules.d/99-gaming-performance.rules` | Udev rules for CPU/GPU performance control |
| `/etc/security/limits.d/99-gaming-memlock.conf` | Memory lock limits (2GB) for gaming |

#### Performance & Environment
| Path | Purpose |
|------|---------|
| `/etc/environment.d/99-shader-cache.conf` | Shader cache optimization (12GB Mesa/DXVK cache) |
| `/etc/environment.d/90-nvidia-gamescope.conf` | NVIDIA Gamescope environment variables |
| `/etc/pipewire/pipewire.conf.d/10-gaming-latency.conf` | PipeWire low-latency audio config |

#### User Config
| Path | Purpose |
|------|---------|
| `~/.config/environment.d/gamescope-session-plus.conf` | Gamescope session config (resolution, refresh rate, GPU) — edit via the settings TUI |
| `~/.config/hypr/bindings.conf` | Hyprland keybind for `Super+Shift+S` (appended) |

#### Settings TUI
| Path | Purpose |
|------|---------|
| `/usr/local/bin/deckshift-settings` | Gum-based TUI for adjusting Gaming Mode display settings |
| `/usr/share/applications/deckshift-settings.desktop` | Walker launcher (floats via Omarchy's `TUI.float` windowrule) |

## How It Works

### Session Switching Flow

```
Desktop Mode (Hyprland)
    │
    ├─ Super+Shift+S pressed
    │   └─ switch-to-gaming runs:
    │       ├─ Masks suspend targets (prevents sleep during switch)
    │       ├─ Updates SDDM config to gaming session
    │       └─ Restarts SDDM → boots into Gaming Mode
    │
Gaming Mode (Gamescope + Steam Big Picture)
    │
    ├─ On session start (gamescope-session-nm-wrapper):
    │   ├─ Enables performance mode (CPU governor, GPU tuning)
    │   ├─ Starts NetworkManager (for Steam network access)
    │   ├─ Launches steam-library-mount (external drive detection)
    │   ├─ Starts gaming-keybind-monitor (Super+Shift+R listener)
    │   └─ Launches gamescope-session-plus with Steam
    │
    ├─ Super+Shift+R pressed (or Steam > Exit to Desktop)
    │   └─ switch-to-desktop runs:
    │       ├─ Unmasks suspend targets
    │       ├─ Restores Bluetooth
    │       ├─ Shuts down Steam gracefully
    │       ├─ Kills gamescope
    │       ├─ Updates SDDM config to Hyprland session
    │       └─ Restarts SDDM → boots into Desktop Mode
    │
    └─ On session cleanup (trap handler):
        ├─ Kills steam-library-mount and keybind-monitor
        ├─ Stops NetworkManager, restores iwd WiFi
        └─ Restores balanced power mode
```

### Performance Mode

When Gaming Mode starts, the session wrapper automatically:

- Sets CPU governor to `performance` on all cores
- **NVIDIA**: Enables persistence mode, sets power limit to maximum, disables runtime suspend
- **AMD**: Sets GPU to high performance via `power_dpm_force_performance_level`
- Applies kernel sysctl tuning (scheduler, VM, inotify, network buffers)
- Sets power profile to `performance` (if power-profiles-daemon is available)

On exit, everything is restored to balanced/powersave defaults.

### GPU Detection

The installer automatically detects your GPU configuration:

- **AMD dGPU**: Detected via PCI device names (Navi, RDNA, Vega discrete cards)
- **AMD APU**: Detected via integrated GPU codenames (Phoenix, Rembrandt, Van Gogh, etc.)
- **NVIDIA**: Detected via lspci, configures `nvidia-drm.modeset=1` if missing. Driver branch (modern vs legacy 580xx) auto-selected via Omarchy's GSP-firmware detection — older Pascal/Maxwell cards get `nvidia-580xx-utils` automatically.
- **Intel (Arc / Iris Xe / iGPU)**: Detected via `i915` / `xe` kernel drivers. Used as primary on Intel-only systems. The gamescope conf for Intel skips `ADAPTIVE_SYNC` and `ENABLE_GAMESCOPE_HDR` by default — most Intel iGPUs don't support adaptive sync, and gamescope HDR on Intel is unreliable. Users with Intel Arc + a VRR display can enable both via the settings TUI.
- **Multi-GPU**: Correctly identifies discrete vs integrated, selects dGPU for gaming. Intel iGPU + AMD/NVIDIA dGPU systems use the dGPU.

### Monitor Detection

The installer scans DRM connectors on your gaming GPU to find connected displays. If multiple monitors are connected to the dGPU, you can choose which one to use for Gaming Mode. Resolution and refresh rate are auto-detected from EDID data.

### NetworkManager Integration

Many systems running Hyprland use `iwd` or `systemd-networkd` instead of NetworkManager. Since Steam requires NetworkManager for its network settings UI, the installer creates a managed handoff:

1. On Gaming Mode entry: NetworkManager starts, takes over networking
2. On Gaming Mode exit: NetworkManager stops, iwd/networkd resumes

This avoids conflicts and ensures both desktop and gaming sessions have network access.

### External Drive Auto-Mount

The `steam-library-mount` daemon runs during Gaming Mode and:

1. Scans all connected drives for Steam library folders
2. Mounts drives containing `steamapps/` directories via udisks2
3. Monitors udev for hot-plugged drives
4. Unmounts non-Steam drives to avoid clutter

Supports ext4, NTFS, btrfs, xfs, exfat, f2fs, and vfat filesystems.

## Configuration

### Config File

The installer reads from `/etc/gaming-mode.conf` (or `~/.gaming-mode.conf` if it exists):

```bash
PERFORMANCE_MODE=enabled   # Set to "disabled" to skip performance tuning
```

### Gamescope Session Config

After installation, you can edit `~/.config/environment.d/gamescope-session-plus.conf`:

```bash
SCREEN_WIDTH=2560
SCREEN_HEIGHT=1440
CUSTOM_REFRESH_RATES=165
OUTPUT_CONNECTOR=DP-1
ADAPTIVE_SYNC=1            # AMD only
ENABLE_GAMESCOPE_HDR=1     # AMD only
```

**NVIDIA note**: Resolution is capped at 2560x1440 due to Gamescope limitations with NVIDIA GPUs.

### Shader Cache

The installer configures a 12GB shader cache by default in `/etc/environment.d/99-shader-cache.conf`. This reduces stutter in games by caching compiled shaders. Values can be adjusted:

```bash
MESA_SHADER_CACHE_MAX_SIZE=12G
__GL_SHADER_DISK_CACHE_SIZE=12884901888
DXVK_STATE_CACHE=1
```

## NVIDIA-Specific Notes

- **Kernel parameter**: `nvidia-drm.modeset=1` is required. The installer can configure this for Limine, GRUB, or systemd-boot.
- **Resolution cap**: Gamescope on NVIDIA is limited to 2560x1440 maximum.
- **Force composition**: The NVIDIA wrapper automatically adds `--force-composition` if supported by your Gamescope version.
- **Environment**: `GBM_BACKEND=nvidia-drm` and related vars are set automatically.
- **Persistence mode**: Enabled during gaming to keep the GPU initialized, disabled on exit.

## Bootloader Support

The installer can automatically configure `nvidia-drm.modeset=1` for:

- **Limine** - Appends to `cmdline:` in `/boot/limine.conf`
- **GRUB** - Adds to `GRUB_CMDLINE_LINUX_DEFAULT` and regenerates config
- **systemd-boot** - Provides manual instructions for `/boot/loader/entries/*.conf`

A backup is created before any bootloader modification.

## Troubleshooting

### Verify Installation

Run the built-in verification to check all files, permissions, packages, and services:

```bash
./deckshift.sh --verify
```

### Common Issues

**Gaming Mode doesn't start / black screen**
- Check NVIDIA kernel params: `cat /proc/cmdline | grep nvidia`
- Verify gamescope works: `gamescope -- steam`
- Check session logs: `journalctl --user -u gamescope-session -n 50`

**No network in Gaming Mode**
- Test NM manually: `sudo systemctl start NetworkManager && nmcli general`
- Check polkit rules: `ls -la /etc/polkit-1/rules.d/50-gamescope-*`
- Check logs: `journalctl -t gamescope-nm -n 20`

**Super+Shift+R doesn't work in Gaming Mode**
- Ensure `python-evdev` is installed: `pacman -Qi python-evdev`
- Ensure user is in `input` group: `groups | grep input`
- Check keybind monitor: `journalctl -t gaming-keybind-monitor -n 20`
- Fallback: Use Steam > Power > Exit to Desktop

**External drives not mounting**
- Ensure `udisks2` is installed: `pacman -Qi udisks2`
- Check polkit rules exist: `ls /etc/polkit-1/rules.d/50-udisks-gaming.rules`
- Check mount logs: `journalctl -t steam-library-mount -n 20`

**Audio stuttering in Gaming Mode**
- Check PipeWire config exists: `cat /etc/pipewire/pipewire.conf.d/10-gaming-latency.conf`
- Try lower quantum: edit the config and set `default.clock.min-quantum = 128`

**Intel-only system, Gaming Mode is laggy**
- Older Gen8/9 Intel iGPUs (Skylake, Kaby Lake) struggle with Vulkan workloads. Lower the launch resolution via the settings TUI (`deckshift-settings`) — 720p / 1080p makes a big difference.
- If you have a discrete GPU that should take over, check its driver is loaded: `lspci -k | grep -A2 VGA`

### Log Locations

| Component | Command |
|-----------|---------|
| Gaming session | `journalctl --user -u gamescope-session` |
| NetworkManager | `journalctl -t gamescope-nm` |
| Drive mounting | `journalctl -t steam-library-mount` |
| Keybind monitor | `journalctl -t gaming-keybind-monitor` |
| Session wrapper | `journalctl -t gamescope-wrapper` |
| Installation | `journalctl -t gaming-mode` |

## Uninstalling

To remove Gaming Mode, delete the files listed in the [Files Created](#files-created) section. Key cleanup:

```bash
# Remove scripts
sudo rm -f /usr/local/bin/switch-to-gaming
sudo rm -f /usr/local/bin/switch-to-desktop
sudo rm -f /usr/local/bin/gamescope-session-nm-wrapper
sudo rm -f /usr/local/bin/gaming-session-switch
sudo rm -f /usr/local/bin/gaming-keybind-monitor
sudo rm -f /usr/local/bin/gamescope-nm-start
sudo rm -f /usr/local/bin/gamescope-nm-stop
sudo rm -f /usr/local/bin/steam-library-mount
sudo rm -f /usr/lib/os-session-select
sudo rm -rf /usr/local/lib/gamescope-nvidia

# Remove session entry
sudo rm -f /usr/share/wayland-sessions/gamescope-session-steam-nm.desktop

# Remove permissions
sudo rm -f /etc/sudoers.d/gaming-session-switch
sudo rm -f /etc/sudoers.d/gaming-mode-sysctl
sudo rm -f /etc/polkit-1/rules.d/50-gamescope-networkmanager.rules
sudo rm -f /etc/polkit-1/rules.d/50-udisks-gaming.rules
sudo rm -f /etc/udev/rules.d/99-gaming-performance.rules
sudo rm -f /etc/security/limits.d/99-gaming-memlock.conf

# Remove configs
sudo rm -f /etc/sddm.conf.d/zz-gaming-session.conf
sudo rm -f /etc/environment.d/99-shader-cache.conf
sudo rm -f /etc/environment.d/90-nvidia-gamescope.conf
sudo rm -f /etc/pipewire/pipewire.conf.d/10-gaming-latency.conf
sudo rm -f /etc/NetworkManager/conf.d/10-iwd-backend.conf
sudo rm -f /etc/NetworkManager/conf.d/20-unmanaged-systemd.conf
rm -f ~/.config/environment.d/gamescope-session-plus.conf

# Remove keybind from Hyprland (edit manually)
# Remove the "bindd = SUPER SHIFT, S, Gaming Mode..." line from ~/.config/hypr/bindings.conf

# Optionally remove AUR packages
yay -Rns gamescope-session-git gamescope-session-steam-git
```

## Credits

- [Omarchy](https://omarchy.com) - The Arch Linux distribution this was built for
- [ChimeraOS](https://chimeraos.org/) - gamescope-session packages
- [Valve](https://store.steampowered.com/) - Steam, Gamescope, and the Steam Deck inspiration
- [Hyprland](https://hyprland.org/) - Wayland compositor

## License

This project is provided as-is for the Omarchy community.

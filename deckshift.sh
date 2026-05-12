#!/bin/bash
# ==============================================================================
# DeckShift - Steam Deck Mode for Linux + Hyprland
#
# Forked from Super-Shift-S-Omarchy-Deck-Mode (v12.27) → renamed Omarchy Deck →
# renamed DeckShift. Currently targets Omarchy/Arch but distro-portability is
# the next direction. Extended with:
#   - NVIDIA GSP-aware driver branch selection (legacy 580xx for Pascal/Maxwell)
#   - omarchy-pkg-add idempotent package installs
#   - Optional Xbox Bluetooth controller support (xpadneo-dkms)
#   - Intel GPU support (Iris Xe / Arc / iGPU)
#   - Settings TUI launched from Walker (deckshift-settings)
#
# This script transforms an Omarchy (Arch Linux + Hyprland) desktop into a
# dual-mode system: Desktop Mode (Hyprland) and Gaming Mode (Steam Big Picture
# inside Gamescope — the same compositor the Steam Deck uses).
#
# It handles everything needed for this transformation:
#   - Installing all Steam/gaming dependencies and GPU drivers
#   - Configuring NVIDIA kernel parameters (nvidia-drm.modeset=1)
#   - Setting up session switching between Hyprland and Gamescope via SDDM
#   - Creating keybinds (Super+Shift+S to enter, Super+Shift+R to exit)
#   - Configuring NetworkManager handoff (iwd <-> NM) for Steam network access
#   - Setting up performance tuning (CPU governor, GPU power, kernel sysctl)
#   - Auto-mounting external drives with Steam libraries
#   - Configuring permissions (polkit, sudoers, udev) so it all works
#     without password prompts during gameplay
#
# The script is idempotent — running it again skips steps that are already done.
# ==============================================================================

set -Euo pipefail
# -E: ERR traps are inherited by functions, command substitutions, and subshells
# -u: Treat unset variables as errors (catches typos in variable names)
# -o pipefail: A pipeline fails if ANY command in it fails, not just the last one

DECKSHIFT_VERSION="0.1.5"

# Resolve the directory this script lives in so we can find sibling files like
# bin/deckshift-settings and applications/deckshift-settings.desktop when
# the installer is run from the cloned repo.
SCRIPT_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" &>/dev/null && pwd)

# Load configuration from /etc/gaming-mode.conf (system-wide) or
# ~/.gaming-mode.conf (user override). This lets users disable performance
# tuning by setting PERFORMANCE_MODE=disabled without editing the script.
CONFIG_FILE="/etc/gaming-mode.conf"
[[ -f "$HOME/.gaming-mode.conf" ]] && CONFIG_FILE="$HOME/.gaming-mode.conf"
source "$CONFIG_FILE" 2>/dev/null || true
: "${PERFORMANCE_MODE:=enabled}"

# Flags that track whether the user needs to reboot or re-login after setup.
# Various steps set these to 1 when they make changes that only take effect
# after a session restart (e.g. adding user groups, changing kernel params).
NEEDS_RELOGIN=0
NEEDS_REBOOT=0

# Logging helpers — consistent prefix makes it easy to spot installer output
# in a busy terminal. err() goes to stderr so it can be captured separately.
info(){ echo "[*] $*"; }
warn(){ echo "[!] $*"; }
err(){ echo "[!] $*" >&2; }

# Fatal error handler — logs to the system journal (journalctl -t gaming-mode)
# so failures can be diagnosed even after the terminal is closed.
die() {
  local msg="$1"; local code="${2:-1}"
  echo "FATAL: $msg" >&2
  logger -t gaming-mode "Installation failed: $msg"
  exit "$code"
}

# AUR helpers (yay, paru) can break after a major system update if their
# own dependencies change. This checks whether the helper actually runs,
# not just whether the binary exists on disk.
check_aur_helper_functional() {
  local helper="$1"
  if $helper --version &>/dev/null; then
    return 0
  else
    return 1
  fi
}

# If yay is broken (common after Go or glibc updates), this rebuilds it
# from scratch by cloning the AUR package and running makepkg. This avoids
# a chicken-and-egg problem where you need an AUR helper to install an
# AUR helper.
rebuild_yay() {
  info "Attempting to rebuild yay..."
  local tmp_dir
  tmp_dir=$(mktemp -d)
  pushd "$tmp_dir" >/dev/null || return 1
  if git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm; then
    popd >/dev/null || true
    rm -rf "$tmp_dir"
    info "yay rebuilt successfully"
    return 0
  else
    popd >/dev/null || true
    rm -rf "$tmp_dir"
    err "Failed to rebuild yay"
    return 1
  fi
}

# Sanity check — make sure we're actually running on an Omarchy system.
# pacman = Arch Linux, hyprctl = Hyprland compositor, ~/.config/hypr = config dir.
# If any of these are missing, the script can't do its job.
validate_environment() {
  command -v pacman  >/dev/null || die "pacman required"
  command -v hyprctl >/dev/null || die "hyprctl required"
  [ -d "$HOME/.config/hypr" ] || die "Hyprland config directory not found (~/.config/hypr)"
}

# Quick check if a pacman package is installed. Used throughout the script
# to avoid reinstalling things that are already present.
check_package() { pacman -Qi "$1" &>/dev/null; }

# Distinguishes AMD integrated GPUs (iGPUs/APUs) from discrete AMD GPUs (dGPUs).
# This matters because Gaming Mode needs to target the RIGHT GPU — if you have
# both an AMD APU and an NVIDIA dGPU, we want to use the NVIDIA card for gaming,
# not the low-power APU that's driving your laptop display.
#
# It works by reading the PCI device info and matching against known AMD APU
# codenames (Phoenix, Rembrandt, Van Gogh, etc.). If the name matches an APU
# pattern, it returns 0 (true = this IS an iGPU). If it matches a discrete
# GPU pattern (Navi, RX, Vega 56/64), it returns 1 (false = this is a dGPU).
is_amd_igpu_card() {
  local card_path="$1"
  local device_path="$card_path/device"
  local pci_slot=""
  [[ -L "$device_path" ]] && pci_slot=$(basename "$(readlink -f "$device_path")")
  [[ -z "$pci_slot" ]] && return 1
  local device_info=$(/usr/bin/lspci -s "$pci_slot" 2>/dev/null)
  if echo "$device_info" | grep -iqE 'renoir|cezanne|barcelo|rembrandt|phoenix|raphael|lucienne|picasso|raven|vega.*mobile|vega.*integrated|radeon.*graphics|yellow.*carp|green.*sardine|cyan.*skillfish|vangogh|van gogh|mendocino|hawk.*point|strix.*point|strix.*halo|krackan|sarlak'; then
    return 0
  fi
  if echo "$device_info" | grep -iqE 'radeon rx|navi [0-9]|navi[0-9]|vega 56|vega 64|radeon vii|radeon pro|firepro|polaris|ellesmere|baffin|lexa|radeon [0-9]{3,4}[^0-9]'; then
    return 1
  fi
  return 1
}

# Intel-only GPU detection — Gaming Mode doesn't support Intel GPUs because
# Gamescope (the compositor) doesn't work well with Intel graphics.
# However, many laptops have Intel iGPU + NVIDIA/AMD dGPU — those are fine
# because we use the discrete GPU for gaming. This function only blocks
# systems where Intel is the ONLY GPU available.
check_intel_only() {
  # Returns 0 (true) if system has Intel GPU but NO AMD/NVIDIA GPU
  # Returns 1 (false) if system has AMD/NVIDIA (Intel iGPU + dGPU is OK)
  local card_name driver driver_link
  local has_intel=false
  local has_amd_nvidia=false

  for card_path in /sys/class/drm/card[0-9]*; do
    card_name=$(basename "$card_path")
    [[ "$card_name" == render* ]] && continue
    driver_link="$card_path/device/driver"
    [[ -L "$driver_link" ]] || continue
    driver=$(basename "$(readlink "$driver_link")")

    case "$driver" in
      i915|xe)
        has_intel=true
        ;;
      nvidia|amdgpu)
        has_amd_nvidia=true
        ;;
    esac
  done

  # Block only if Intel exists and no AMD/NVIDIA exists
  if $has_intel && ! $has_amd_nvidia; then
    return 0  # Intel-only, block it
  fi
  return 1  # Has AMD/NVIDIA (or no Intel), allow it
}

# Finds which monitors are physically connected to the discrete GPU.
# Gaming Mode needs to know which display output to use (e.g. HDMI-1, DP-2)
# and what resolution/refresh rate it supports.
#
# It scans /sys/class/drm/ for GPU cards, identifies the discrete GPU by its
# driver (nvidia or amdgpu), then checks each connector (HDMI, DP, etc.) to
# see if a monitor is plugged in. Resolution and refresh rate are read from
# the EDID data that the monitor reports to the system.
#
# Uses bash nameref variables (_monitors, _dgpu_card, _dgpu_type) so the
# caller gets the results without needing subshells or global variables.
detect_dgpu_monitors() {
  local -n _monitors=$1
  local -n _dgpu_card=$2
  local -n _dgpu_type=$3
  _monitors=()
  _dgpu_card=""
  _dgpu_type=""

  local lspci_output
  lspci_output=$(/usr/bin/lspci 2>/dev/null)
  if echo "$lspci_output" | grep -qi nvidia; then
    _dgpu_type="NVIDIA"
  elif echo "$lspci_output" | grep -iqE 'radeon rx|navi|vega 56|vega 64|radeon vii|radeon pro'; then
    _dgpu_type="AMD dGPU"
  fi

  # Two-pass: prefer a real dGPU (NVIDIA or AMD discrete). On systems with
  # only Intel — iGPU or Arc dGPU — fall back to i915/xe in the second pass.
  local pass
  for pass in dgpu intel; do
    for card_path in /sys/class/drm/card[0-9]*; do
      local card_name=$(basename "$card_path")
      [[ "$card_name" == render* ]] && continue
      local driver_link="$card_path/device/driver"
      [[ -L "$driver_link" ]] || continue
      local driver=$(basename "$(readlink "$driver_link")")
      local is_target=false

      if [[ "$pass" == "dgpu" ]]; then
        case "$driver" in
          nvidia)
            is_target=true
            [[ -z "$_dgpu_type" ]] && _dgpu_type="NVIDIA"
            ;;
          amdgpu)
            if ! is_amd_igpu_card "$card_path"; then
              is_target=true
              [[ -z "$_dgpu_type" ]] && _dgpu_type="AMD dGPU"
            fi
            ;;
        esac
      else
        # Intel pass — only used if first pass found nothing
        case "$driver" in
          i915|xe)
            is_target=true
            [[ -z "$_dgpu_type" ]] && _dgpu_type="Intel"
            ;;
        esac
      fi

      if $is_target; then
        _dgpu_card="$card_name"
        for connector in "$card_path"/"$card_name"-*/status; do
          [[ -f "$connector" ]] || continue
          local conn_dir=$(dirname "$connector")
          local conn_name=$(basename "$conn_dir")
          conn_name=${conn_name#card*-}
          [[ "$conn_name" == Writeback* ]] && continue
          local status=$(cat "$connector" 2>/dev/null)
          if [[ "$status" == "connected" ]]; then
            local resolution=""
            local mode_file="$conn_dir/modes"
            [[ -f "$mode_file" ]] && [[ -s "$mode_file" ]] && resolution=$(head -1 "$mode_file" 2>/dev/null)
            _monitors+=("$conn_name|$resolution")
          fi
        done
        break 2
      fi
    done
  done
}

# NVIDIA GPUs require a kernel parameter (nvidia-drm.modeset=1) to work
# properly with Wayland compositors like Gamescope. Without it, the GPU
# won't expose DRM (Direct Rendering Manager) devices, and Gamescope
# won't be able to take over the display.
#
# This function checks if the parameter is already set in the running
# kernel's command line (/proc/cmdline). If not, it detects the bootloader
# (Limine, GRUB, or systemd-boot) and offers to add it automatically.
# A reboot is required after adding the parameter.
check_nvidia_kernel_params() {
  local lspci_output
  lspci_output=$(/usr/bin/lspci 2>/dev/null)
  if ! echo "$lspci_output" | grep -qi nvidia; then
    return 0
  fi

  echo ""
  echo "================================================================"
  echo "  NVIDIA KERNEL PARAMETER CHECK"
  echo "================================================================"
  echo ""

  if grep -qE "nvidia[-_]drm\.modeset=1" /proc/cmdline 2>/dev/null; then
    info "nvidia-drm.modeset=1 is already configured"
    return 0
  fi

  warn "nvidia-drm.modeset=1 is NOT SET - required for Gaming Mode!"
  echo ""

  local bootloader=""
  local config_file=""

  if [ -f /boot/limine.conf ]; then
    bootloader="limine"; config_file="/boot/limine.conf"
  elif [ -f /boot/limine/limine.conf ]; then
    bootloader="limine"; config_file="/boot/limine/limine.conf"
  elif [ -d /boot/loader/entries ]; then
    bootloader="systemd-boot"
  elif [ -f /etc/default/grub ]; then
    bootloader="grub"
  fi

  info "Detected bootloader: $bootloader"

  case "$bootloader" in
    limine)
      info "Limine config: $config_file"
      read -p "Add nvidia-drm.modeset=1 to Limine config? [Y/n]: " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        configure_limine_nvidia "$config_file"
      else
        warn "Skipping - you'll need to add nvidia-drm.modeset=1 manually"
        show_manual_nvidia_instructions
      fi
      ;;
    systemd-boot)
      echo ""
      echo "  systemd-boot detected. You need to add nvidia-drm.modeset=1"
      echo "  to your boot entry in /boot/loader/entries/*.conf"
      echo ""
      show_manual_nvidia_instructions
      ;;
    grub)
      echo ""
      read -p "Add nvidia-drm.modeset=1 to GRUB config? [Y/n]: " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        configure_grub_nvidia
      else
        warn "Skipping - you'll need to add nvidia-drm.modeset=1 manually"
        show_manual_nvidia_instructions
      fi
      ;;
    *)
      echo ""
      warn "Could not detect bootloader type"
      show_manual_nvidia_instructions
      ;;
  esac
}

# Adds nvidia-drm.modeset=1 to the Limine bootloader config.
# Limine stores kernel command line parameters on lines starting with "cmdline:".
# This appends the parameter to the end of that line. A backup is created first
# in case something goes wrong.
configure_limine_nvidia() {
  local config_file="$1"

  info "Backing up Limine config..."
  sudo cp "$config_file" "${config_file}.backup.$(date +%Y%m%d%H%M%S)" || {
    err "Failed to backup Limine config"
    return 1
  }

  info "Adding nvidia-drm.modeset=1 to Limine cmdline..."

  if sudo sed -i '/^[[:space:]]*cmdline:/ s/$/ nvidia-drm.modeset=1/' "$config_file"; then
    if grep -q "nvidia-drm.modeset=1" "$config_file"; then
      info "Successfully added nvidia-drm.modeset=1 to Limine config"
      echo ""
      echo "  ✓ Limine config updated"
      echo "  ✓ Changes will take effect after reboot"
      echo ""
      NEEDS_REBOOT=1
    else
      err "Failed to add parameter - please add manually"
      show_manual_nvidia_instructions
    fi
  else
    err "Failed to modify Limine config"
    show_manual_nvidia_instructions
  fi
}

# Adds nvidia-drm.modeset=1 to GRUB's kernel parameters.
# GRUB stores defaults in /etc/default/grub — after modifying it, grub-mkconfig
# must be run to regenerate the actual boot config at /boot/grub/grub.cfg.
configure_grub_nvidia() {
  local grub_default="/etc/default/grub"

  info "Backing up GRUB config..."
  sudo cp "$grub_default" "${grub_default}.backup.$(date +%Y%m%d%H%M%S)" || {
    err "Failed to backup GRUB config"
    return 1
  }

  info "Adding nvidia-drm.modeset=1 to GRUB..."

  if ! grep -q "nvidia-drm.modeset=1" "$grub_default"; then
    sudo sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)/\1 nvidia-drm.modeset=1/' "$grub_default"

    if grep -q "nvidia-drm.modeset=1" "$grub_default"; then
      info "Regenerating GRUB config..."
      sudo grub-mkconfig -o /boot/grub/grub.cfg || {
        err "Failed to regenerate GRUB config"
        return 1
      }
      info "Successfully configured GRUB for NVIDIA"
      NEEDS_REBOOT=1
    else
      err "Failed to add parameter to GRUB"
      show_manual_nvidia_instructions
    fi
  fi
}

show_manual_nvidia_instructions() {
  cat <<'MSG'
  Manual configuration required:
  Limine: Add nvidia-drm.modeset=1 to cmdline in /boot/limine.conf
  systemd-boot: Add to options in /boot/loader/entries/*.conf
  GRUB: Add to GRUB_CMDLINE_LINUX_DEFAULT, then run grub-mkconfig -o /boot/grub/grub.cfg
MSG
  warn "Gaming Mode may not work correctly without nvidia-drm.modeset=1"
}

# Sets NVIDIA-specific environment variables needed for Gamescope to work
# properly with NVIDIA GPUs. These tell the system to use the NVIDIA DRM
# backend for GBM (Generic Buffer Management), which is how Wayland
# compositors allocate GPU memory for rendering.
#
# GBM_BACKEND=nvidia-drm         — Use NVIDIA's DRM backend for buffer allocation
# __GLX_VENDOR_LIBRARY_NAME=nvidia — Use NVIDIA's GLX implementation
# __VK_LAYER_NV_optimus=NVIDIA_only — On Optimus laptops, force Vulkan to use NVIDIA
install_nvidia_deckmode_env() {
  local lspci_output
  lspci_output=$(/usr/bin/lspci 2>/dev/null)
  if ! echo "$lspci_output" | grep -qi nvidia; then
    info "No NVIDIA detected; skipping NVIDIA Deck-mode env."
    return 0
  fi

  local env_file="/etc/environment.d/90-nvidia-gamescope.conf"

  if [ -f "$env_file" ]; then
    info "NVIDIA gamescope env already present: $env_file"
    return 0
  fi

  info "Installing NVIDIA gamescope env (Deck-mode style)..."
  sudo mkdir -p /etc/environment.d

  sudo tee "$env_file" >/dev/null <<'EOF'
GBM_BACKEND=nvidia-drm
__GLX_VENDOR_LIBRARY_NAME=nvidia
__VK_LAYER_NV_optimus=NVIDIA_only
EOF

  info "Installed $env_file"
  NEEDS_RELOGIN=1
}

# Steam on Linux requires a LOT of dependencies — 32-bit libraries (lib32-*),
# Vulkan drivers, audio libraries, fonts, and GPU-specific drivers. This
# function checks for everything Steam needs and offers to install what's missing.
#
# It handles three categories:
#   1. Core deps — required for Steam to run at all (lib32 libs, Vulkan, audio)
#   2. GPU deps — driver packages specific to NVIDIA or AMD
#   3. Recommended — nice-to-haves like MangoHud (FPS overlay), Proton-GE, etc.
#
# The multilib repository must be enabled in pacman.conf for 32-bit packages
# to be available — Steam is a 32-bit application that needs 32-bit libraries.
check_steam_dependencies() {
  info "Checking Steam dependencies for Arch Linux..."

  info "Force refreshing package database from all mirrors..."
  sudo pacman -Syy || die "Failed to refresh package database"

  echo ""
  echo "================================================================"
  echo "  SYSTEM UPDATE RECOMMENDED"
  echo "================================================================"
  echo ""
  echo "  It's recommended to upgrade your system before installing"
  echo "  gaming dependencies to avoid package version conflicts."
  echo ""
  read -p "Upgrade system now? [Y/n]: " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    info "Upgrading system..."
    sudo pacman -Syu || die "Failed to upgrade system"
  fi
  echo ""

  local -a missing_deps=()
  local -a optional_deps=()

  local -a core_deps=(
    "steam"
    "lib32-vulkan-icd-loader"
    "vulkan-icd-loader"
    "lib32-mesa"
    "mesa"
    "mesa-utils"
    "lib32-glibc"
    "lib32-gcc-libs"
    "lib32-libx11"
    "lib32-libxss"
    "lib32-alsa-plugins"
    "lib32-libpulse"
    "lib32-openal"
    "lib32-nss"
    "lib32-libcups"
    "lib32-sdl2-compat"
    "lib32-freetype2"
    "lib32-fontconfig"
    "lib32-libnm"
    "networkmanager"
    "gamemode"
    "lib32-gamemode"
    "ttf-liberation"
    "xdg-user-dirs"
    "kbd"
  )

  local gpu_vendor
  gpu_vendor=$(/usr/bin/lspci 2>/dev/null | grep -iE 'vga|3d|display' || echo "")

  local has_nvidia=false has_amd=false has_intel=false

  if echo "$gpu_vendor" | grep -qi nvidia; then
    has_nvidia=true
    info "Detected NVIDIA GPU"
  fi
  if echo "$gpu_vendor" | grep -iqE 'amd|radeon|advanced micro'; then
    has_amd=true
    info "Detected AMD GPU"
  fi
  if echo "$gpu_vendor" | grep -iq intel; then
    has_intel=true
    info "Detected Intel GPU"
  fi

  local -a gpu_deps=()

  if $has_nvidia; then
    # Pick modern (Turing+, GSP firmware) vs legacy 580xx (Maxwell/Pascal/Volta)
    # using Omarchy's hardware detection helpers.
    if omarchy-hw-nvidia-gsp; then
      info "NVIDIA driver branch: modern (nvidia-utils)"
      gpu_deps+=(
        "nvidia-utils"
        "lib32-nvidia-utils"
        "nvidia-settings"
        "libva-nvidia-driver"
      )
      if ! check_package "nvidia" && ! check_package "nvidia-dkms" && ! check_package "nvidia-open-dkms"; then
        info "Note: You may need to install 'nvidia', 'nvidia-dkms', or 'nvidia-open-dkms' kernel module"
        optional_deps+=("nvidia-dkms")
      fi
    elif omarchy-hw-nvidia-without-gsp; then
      info "NVIDIA driver branch: legacy 580xx (Maxwell/Pascal/Volta)"
      gpu_deps+=(
        "nvidia-580xx-utils"
        "lib32-nvidia-580xx-utils"
        "nvidia-settings"
        "libva-nvidia-driver"
      )
      if ! check_package "nvidia-580xx-dkms" && ! check_package "nvidia-580xx-open-dkms"; then
        info "Note: You may need to install 'nvidia-580xx-dkms' or 'nvidia-580xx-open-dkms' kernel module"
        optional_deps+=("nvidia-580xx-dkms")
      fi
    else
      info "NVIDIA detected but driver branch unrecognised; defaulting to modern (nvidia-utils)"
      gpu_deps+=(
        "nvidia-utils"
        "lib32-nvidia-utils"
        "nvidia-settings"
        "libva-nvidia-driver"
      )
    fi
  fi

  if $has_amd; then
    gpu_deps+=(
      "vulkan-radeon"
      "lib32-vulkan-radeon"
      "libvdpau"
      "lib32-libvdpau"
    )
    ! check_package "xf86-video-amdgpu" && optional_deps+=("xf86-video-amdgpu")
  fi

  if $has_intel; then
    gpu_deps+=(
      "vulkan-intel"
      "lib32-vulkan-intel"
      "intel-media-driver"
    )
  fi

  if ! $has_nvidia && ! $has_amd && ! $has_intel; then
    die "No NVIDIA/AMD/Intel GPU detected — Gaming Mode needs a supported GPU"
  fi

  gpu_deps+=(
    "vulkan-tools"
    "vulkan-mesa-layers"
  )

  local -a recommended_deps=(
    "gamescope"
    "mangohud"
    "lib32-mangohud"
    "proton-ge-custom-bin"
    "udisks2"
  )

  info "Checking core Steam dependencies..."
  for dep in "${core_deps[@]}"; do
    if ! check_package "$dep"; then
      missing_deps+=("$dep")
    fi
  done

  info "Checking GPU-specific dependencies..."
  for dep in "${gpu_deps[@]}"; do
    if ! check_package "$dep"; then
      missing_deps+=("$dep")
    fi
  done

  info "Checking recommended dependencies..."
  for dep in "${recommended_deps[@]}"; do
    if ! check_package "$dep"; then
      optional_deps+=("$dep")
    fi
  done

  echo ""
  echo "================================================================"
  echo "  STEAM DEPENDENCY CHECK RESULTS"
  echo "================================================================"
  echo ""

  if ((${#missing_deps[@]})); then
    echo "  MISSING REQUIRED PACKAGES (${#missing_deps[@]}):"
    for dep in "${missing_deps[@]}"; do
      echo "    - $dep"
    done
    echo ""

    read -p "Install missing required packages? [Y/n]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      info "Installing missing dependencies..."
      omarchy-pkg-add "${missing_deps[@]}" || die "Failed to install Steam dependencies"
      info "Required dependencies installed successfully"
    else
      die "Missing required Steam dependencies"
    fi
  else
    info "All required Steam dependencies are installed!"
  fi

  echo ""
  if ((${#optional_deps[@]})); then
    echo "  RECOMMENDED PACKAGES (${#optional_deps[@]}):"
    for dep in "${optional_deps[@]}"; do
      echo "    - $dep"
    done
    echo ""

    read -p "Install recommended packages? [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      info "Syncing package database before installing..."
      sudo pacman -Sy || warn "Failed to sync package database"

      info "Installing recommended packages..."
      # Check which packages are available in repos vs need AUR
      local -a failed_deps=()
      local -a pacman_deps=()
      for dep in "${optional_deps[@]}"; do
        if pacman -Si "$dep" &>/dev/null; then
          pacman_deps+=("$dep")
        else
          failed_deps+=("$dep")
        fi
      done
      if ((${#pacman_deps[@]})); then
        omarchy-pkg-add "${pacman_deps[@]}" || warn "Some packages failed to install"
      fi

      # If some packages failed, try with an official Arch mirror as fallback
      if ((${#failed_deps[@]})); then
        local mirrorlist="/etc/pacman.d/mirrorlist"
        local fallback_mirror="Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch"
        local added_fallback=false

        if ! grep -q "geo.mirror.pkgbuild.com" "$mirrorlist" 2>/dev/null; then
          info "Some packages not found in current repos. Adding official Arch mirror..."
          sudo sed -i "1i $fallback_mirror" "$mirrorlist"
          sudo pacman -Syy || warn "Failed to sync with official mirror"
          added_fallback=true
        fi

        # Retry failed packages with updated database
        local -a aur_optional=()
        local -a retry_pacman=()
        for dep in "${failed_deps[@]}"; do
          if pacman -Si "$dep" &>/dev/null; then
            retry_pacman+=("$dep")
          else
            aur_optional+=("$dep")
          fi
        done
        if ((${#retry_pacman[@]})); then
          info "Found packages in official repos: ${retry_pacman[*]}"
          omarchy-pkg-add "${retry_pacman[@]}" || warn "Some packages failed to install from official repos"
        fi

        # Remove the fallback mirror to restore original mirrorlist
        if $added_fallback; then
          sudo sed -i '/geo\.mirror\.pkgbuild\.com/d' "$mirrorlist"
          sudo pacman -Syy 2>/dev/null || true
          info "Removed fallback mirror, restored original mirrorlist"
        fi
      else
        local -a aur_optional=()
      fi

      if ((${#aur_optional[@]})); then
        echo ""
        info "The following packages are from AUR and need an AUR helper:"
        for dep in "${aur_optional[@]}"; do
          echo "    - $dep"
        done
        echo ""

        local aur_helper_available=""
        if command -v yay >/dev/null 2>&1; then
          if check_aur_helper_functional yay; then
            aur_helper_available="yay"
          else
            warn "yay is installed but broken (needs rebuild after system update)"
            read -p "Rebuild yay now? [Y/n]: " -n 1 -r
            echo
            REPLY=${REPLY:-Y}
            if [[ $REPLY =~ ^[Yy]$ ]] && rebuild_yay && check_aur_helper_functional yay; then
              aur_helper_available="yay"
            fi
          fi
        elif command -v paru >/dev/null 2>&1; then
          if check_aur_helper_functional paru; then
            aur_helper_available="paru"
          fi
        fi

        if [[ -n "$aur_helper_available" ]]; then
          read -p "Install AUR packages with $aur_helper_available? [y/N]: " -n 1 -r
          echo
          if [[ $REPLY =~ ^[Yy]$ ]]; then
            # Install AUR packages one at a time so a single failure doesn't block others
            for dep in "${aur_optional[@]}"; do
              info "Installing $dep..."
              $aur_helper_available -S --needed --noconfirm "$dep" || warn "Failed to install $dep from AUR"
            done
          fi
        else
          info "No functional AUR helper found (yay/paru). Install manually if desired."
        fi
      fi
    fi
  else
    info "All recommended packages are already installed!"
  fi

  echo ""
  echo "================================================================"

  check_steam_config

  # Bootstrap Steam — launches it in the background so its first-run client
  # update happens in parallel with the rest of the install. Same pattern as
  # omarchy-install-gaming-steam. Skipped silently if Steam isn't installed
  # (e.g. user declined to install missing required deps).
  if check_package steam && command -v gtk-launch >/dev/null 2>&1; then
    info "Launching Steam to complete its first-run download..."
    setsid gtk-launch steam >/dev/null 2>&1 < /dev/null &
    disown 2>/dev/null || true
  fi
}

# Checks that the user is in the right Linux groups for gaming:
#   - video:  Access to GPU hardware (required for rendering)
#   - input:  Access to controllers, gamepads, and keyboard input devices
#   - wheel:  Sudo/admin group, needed for NetworkManager control in gaming mode
#
# Also checks for some common performance tips like lowering vm.swappiness
# (reduces swap usage during gaming) and increasing the open file limit
# (needed for esync, a Steam/Proton feature that reduces CPU overhead).
check_steam_config() {
  info "Checking Steam configuration..."

  local missing_groups=()

  if ! groups | grep -qw 'video'; then
    missing_groups+=("video")
  fi

  if ! groups | grep -qw 'input'; then
    missing_groups+=("input")
  fi

  if ! groups | grep -qw 'wheel'; then
    missing_groups+=("wheel")
  fi

  if ((${#missing_groups[@]})); then
    echo ""
    echo "================================================================"
    echo "  USER GROUP PERMISSIONS"
    echo "================================================================"
    echo ""
    echo "  Your user needs to be added to the following groups:"
    echo ""
    for group in "${missing_groups[@]}"; do
      case "$group" in
        video) echo "    - video  - Required for GPU hardware access" ;;
        input) echo "    - input  - Required for controller/gamepad support" ;;
        wheel) echo "    - wheel  - Required for NetworkManager control in gaming mode" ;;
      esac
    done
    echo ""
    echo "  NOTE: After adding groups, you MUST log out and log back in"
    echo ""
    read -p "Add user to ${missing_groups[*]} group(s)? [Y/n]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      local groups_to_add=$(IFS=,; echo "${missing_groups[*]}")
      info "Adding user to groups: $groups_to_add"
      if sudo usermod -aG "$groups_to_add" "$USER"; then
        info "Successfully added user to group(s): $groups_to_add"
        NEEDS_RELOGIN=1
      else
        err "Failed to add user to groups"
      fi
    fi
  else
    info "User is in video, input, and wheel groups - permissions OK"
  fi

  if [ -d "$HOME/.steam" ]; then
    info "Steam directory found at ~/.steam"
  fi

  if [ -d "$HOME/.local/share/Steam" ]; then
    info "Steam data directory found at ~/.local/share/Steam"
  fi

  if [ -f /proc/sys/vm/swappiness ]; then
    local swappiness
    swappiness=$(cat /proc/sys/vm/swappiness)
    if [ "$swappiness" -gt 10 ]; then
      info "Tip: Consider lowering vm.swappiness to 10 for better gaming performance"
    fi
  fi

  local max_files
  max_files=$(ulimit -n 2>/dev/null || echo "0")
  if [ "$max_files" -lt 524288 ]; then
    info "Tip: Increase open file limit for esync support"
  fi
}

# Sets up the permissions needed for Gaming Mode to tune system performance
# WITHOUT requiring a password prompt. This creates three things:
#
# 1. UDEV RULES — Make CPU governor and GPU performance files writable by
#    regular users. Normally these sysfs files are root-only, but udev rules
#    can relax permissions when the devices are detected at boot.
#
# 2. SUDOERS RULES — Allow members of the "video" group to run specific
#    sysctl commands (kernel scheduler tuning, VM settings, network buffers)
#    and nvidia-smi commands without entering a password. These are narrowly
#    scoped — only the exact commands needed, not blanket sudo access.
#
# 3. MEMLOCK LIMITS — Increase the memory lock limit to 2GB. Games using
#    esync/fsync need to lock memory pages to avoid latency spikes.
#
# 4. PIPEWIRE CONFIG — Sets a lower audio quantum (buffer size) for reduced
#    audio latency during gaming. Lower = less delay but more CPU usage.
setup_performance_permissions() {
  local udev_rules_file="/etc/udev/rules.d/99-gaming-performance.rules"
  local sudoers_file="/etc/sudoers.d/gaming-mode-sysctl"
  local needs_setup=false

  if [ ! -f "$udev_rules_file" ] || [ ! -f "$sudoers_file" ]; then
    needs_setup=true
  fi

  if [ "$needs_setup" = false ]; then
    info "Performance permissions already configured"
    return 0
  fi

  echo ""
  echo "================================================================"
  echo "  PERFORMANCE PERMISSIONS SETUP"
  echo "================================================================"
  echo ""
  echo "  To avoid sudo password prompts during gaming, we need to set"
  echo "  up permissions for CPU and GPU performance control."
  echo ""
  read -p "Set up passwordless performance controls? [Y/n]: " -n 1 -r
  echo

  if [[ $REPLY =~ ^[Nn]$ ]]; then
    info "Skipping permissions setup"
    return 0
  fi

  if [ ! -f "$udev_rules_file" ]; then
    info "Creating udev rules for CPU/GPU performance control..."

    if sudo tee "$udev_rules_file" > /dev/null <<'UDEV_RULES'
KERNEL=="cpu[0-9]*", SUBSYSTEM=="cpu", ACTION=="add", RUN+="/bin/chmod 666 /sys/devices/system/cpu/%k/cpufreq/scaling_governor"
KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="amdgpu", ACTION=="add", RUN+="/bin/chmod 666 /sys/class/drm/%k/device/power_dpm_force_performance_level"
KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="i915", ACTION=="add", RUN+="/bin/chmod 666 /sys/class/drm/%k/gt_boost_freq_mhz"
KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="i915", ACTION=="add", RUN+="/bin/chmod 666 /sys/class/drm/%k/gt_min_freq_mhz"
KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="i915", ACTION=="add", RUN+="/bin/chmod 666 /sys/class/drm/%k/gt_max_freq_mhz"
UDEV_RULES
    then
      info "Udev rules created successfully"
      sudo udevadm control --reload-rules || true
      sudo udevadm trigger --subsystem-match=cpu --subsystem-match=drm || true
    fi
  fi

  if [[ -f "$sudoers_file" ]]; then
    info "Performance sudoers already exist at $sudoers_file"
  else
    info "Creating sudoers rule for Performance Mode sysctl tuning..."

    local tee_output
    tee_output=$(sudo tee "$sudoers_file" << 'SUDOERS_PERF' 2>&1
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w kernel.sched_autogroup_enabled=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w kernel.sched_migration_cost_ns=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w kernel.sched_min_granularity_ns=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w kernel.sched_latency_ns=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.swappiness=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.dirty_ratio=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.dirty_background_ratio=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.dirty_writeback_centisecs=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.dirty_expire_centisecs=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w fs.inotify.max_user_watches=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w fs.inotify.max_user_instances=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w fs.file-max=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w net.core.rmem_max=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w net.core.wmem_max=*
%video ALL=(ALL) NOPASSWD: /usr/bin/nvidia-smi -pm *
%video ALL=(ALL) NOPASSWD: /usr/bin/nvidia-smi -pl *
%video ALL=(ALL) NOPASSWD: /usr/bin/powerprofilesctl set *
SUDOERS_PERF
)
    local tee_exit=$?

    if [[ $tee_exit -eq 0 ]]; then
      sudo chmod 0440 "$sudoers_file"
      info "Performance sudoers created successfully"
    else
      err "Failed to create performance sudoers file (exit code: $tee_exit)"
    fi
  fi

  local memlock_file="/etc/security/limits.d/99-gaming-memlock.conf"
  if [ ! -f "$memlock_file" ]; then
    info "Creating memlock limits for gaming performance..."
    if sudo tee "$memlock_file" > /dev/null << 'MEMLOCKCONF'
* soft memlock 2147484
* hard memlock 2147484
MEMLOCKCONF
    then
      info "Memlock limits configured (2GB)"
    fi
  fi

  local pipewire_conf_dir="/etc/pipewire/pipewire.conf.d"
  local pipewire_conf="$pipewire_conf_dir/10-gaming-latency.conf"
  if [ ! -f "$pipewire_conf" ]; then
    info "Creating PipeWire low-latency audio configuration..."
    sudo mkdir -p "$pipewire_conf_dir"
    if sudo tee "$pipewire_conf" > /dev/null << 'PIPEWIRECONF'
context.properties = {
    default.clock.min-quantum = 256
}
PIPEWIRECONF
    then
      info "PipeWire gaming latency configured"
    fi
  fi

  info "Performance permissions configured"
  return 0
}

# Configures shader cache settings for better gaming performance.
# When a game runs for the first time, the GPU driver compiles shaders
# (small programs that run on the GPU). This causes stuttering because
# compilation takes time. By caching these compiled shaders to disk
# (up to 12GB), the stuttering only happens once — next time the shader
# loads instantly from cache.
#
# MESA_SHADER_CACHE — AMD/Intel open-source driver cache
# __GL_SHADER_DISK_CACHE — NVIDIA proprietary driver cache
# DXVK_STATE_CACHE — Proton/Wine DirectX-to-Vulkan translation cache
# RADV_PERFTEST=gpl — AMD Vulkan: enables graphics pipeline library for
#                      faster shader compilation
setup_shader_cache() {
  local env_file="/etc/environment.d/99-shader-cache.conf"

  if [ -f "$env_file" ]; then
    info "Shader cache configuration already exists"
    return 0
  fi

  echo ""
  echo "================================================================"
  echo "  SHADER CACHE OPTIMIZATION"
  echo "================================================================"
  echo ""
  echo "  Configuring shader cache sizes for better gaming performance."
  echo "  This reduces stuttering in games by caching compiled shaders."
  echo ""
  read -p "Configure shader cache optimization? [Y/n]: " -n 1 -r
  echo

  if [[ $REPLY =~ ^[Nn]$ ]]; then
    info "Skipping shader cache configuration"
    return 0
  fi

  info "Creating shader cache configuration..."
  sudo mkdir -p /etc/environment.d || { warn "Failed to create /etc/environment.d"; return 0; }
  local tmp_shader
  tmp_shader=$(mktemp) || { warn "Failed to create temp file"; return 0; }

  cat > "$tmp_shader" << 'SHADERCACHE'
MESA_SHADER_CACHE_MAX_SIZE=12G
MESA_SHADER_CACHE_DISABLE_CLEANUP=1
RADV_PERFTEST=gpl
__GL_SHADER_DISK_CACHE=1
__GL_SHADER_DISK_CACHE_SIZE=12884901888
__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1
DXVK_STATE_CACHE=1
FCITX_NO_WAYLAND_DIAGNOSE=1
SHADERCACHE

  if sudo cp "$tmp_shader" "$env_file"; then
    rm -f "$tmp_shader"
    sudo chmod 644 "$env_file"
    info "Shader cache configured for all GPUs (AMD/NVIDIA + Proton)"
  else
    rm -f "$tmp_shader"
    warn "Failed to create shader cache configuration"
  fi
}

# Silences a harmless but annoying warning from fcitx5 (input method framework).
# fcitx5 complains about Wayland support on every login, even if you don't use
# it for input. This sets FCITX_NO_WAYLAND_DIAGNOSE=1 to suppress the warning
# in both Hyprland config and the user's environment.
setup_fcitx_silence() {
  local env_dir="$HOME/.config/environment.d"
  local env_file="$env_dir/90-fcitx-wayland.conf"
  local hypr_conf="$HOME/.config/hypr/hyprland.conf"

  if [[ -f "$hypr_conf" ]]; then
    if ! grep -q "FCITX_NO_WAYLAND_DIAGNOSE" "$hypr_conf" 2>/dev/null; then
      echo "" >> "$hypr_conf"
      echo "# Silence fcitx5 Wayland diagnose warning (gaming-mode installer)" >> "$hypr_conf"
      echo "env = FCITX_NO_WAYLAND_DIAGNOSE,1" >> "$hypr_conf"
      info "Added FCITX_NO_WAYLAND_DIAGNOSE to Hyprland config"
      NEEDS_RELOGIN=1
    fi
  fi

  if [[ ! -f "$env_file" ]] || ! grep -q "FCITX_NO_WAYLAND_DIAGNOSE=1" "$env_file" 2>/dev/null; then
    mkdir -p "$env_dir" || return 0
    cat > "$env_file" <<'EOF'
FCITX_NO_WAYLAND_DIAGNOSE=1
EOF
    info "Created fcitx Wayland silence config"
    NEEDS_RELOGIN=1
  fi
}

# Configures the Elephant app launcher (used in Omarchy) to launch desktop
# applications through uwsm-app. UWSM (Universal Wayland Session Manager)
# ensures apps are properly associated with the Wayland session, which
# prevents issues with apps losing track of their display server.
configure_elephant_launcher() {
  local cfg="$HOME/.config/elephant/desktopapplications.toml"
  if [[ ! -f "$cfg" ]]; then
    return 0
  fi
  if ! command -v uwsm-app >/dev/null 2>&1; then
    return 0
  fi

  if grep -q '^launch_prefix[[:space:]]*=[[:space:]]*"uwsm-app --"' "$cfg" 2>/dev/null; then
    return 0
  fi

  if grep -q '^launch_prefix[[:space:]]*=' "$cfg" 2>/dev/null; then
    sed -i 's|^launch_prefix[[:space:]]*=.*|launch_prefix = "uwsm-app --"|' "$cfg"
  else
    echo 'launch_prefix = "uwsm-app --"' >> "$cfg"
  fi
  info "Configured Elephant desktopapplications launch_prefix (uwsm-app)"
  restart_elephant_walker
}

# Restarts the Elephant/Walker launcher service so config changes take
# effect immediately without requiring a logout.
restart_elephant_walker() {
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    return 0
  fi
  if command -v omarchy-restart-walker >/dev/null 2>&1; then
    omarchy-restart-walker >/dev/null 2>&1 || true
    return 0
  fi
  systemctl --user restart elephant.service >/dev/null 2>&1 || true
  systemctl --user restart app-walker@autostart.service >/dev/null 2>&1 || true
}

# Installs the core packages that the Gaming Mode scripts themselves need
# (as opposed to Steam's dependencies which are handled separately).
# These include:
#   - python-evdev: Reads raw keyboard input for the Super+Shift+R hotkey
#   - libcap: Sets Linux capabilities on gamescope (cap_sys_nice for priority)
#   - ntfs-3g: Mounts NTFS-formatted game drives (common for Windows dual-boot)
#   - xcb-util-cursor: X11 cursor support needed by some Proton games
#
# After installing packages, it also runs the sub-setup functions for
# performance permissions, shader cache, and gamescope capabilities.
setup_requirements() {
  local -a required_packages=("steam" "gamescope" "mangohud" "python" "python-evdev" "libcap" "gamemode" "curl" "pciutils" "ntfs-3g" "xcb-util-cursor")
  local -a packages_to_install=()
  for pkg in "${required_packages[@]}"; do
    check_package "$pkg" || packages_to_install+=("$pkg")
  done

  if ((${#packages_to_install[@]})); then
    info "The following packages are required: ${packages_to_install[*]}"
    read -p "Install missing packages? [Y/n]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      omarchy-pkg-add "${packages_to_install[@]}" || die "package install failed"
    else
      die "Required packages missing - cannot continue"
    fi
  else
    info "All required packages present."
  fi

  setup_performance_permissions
  setup_fcitx_silence
  setup_shader_cache
  configure_elephant_launcher

  if [[ "${PERFORMANCE_MODE,,}" == "enabled" ]] && command -v gamescope >/dev/null 2>&1; then
    if ! getcap "$(command -v gamescope)" 2>/dev/null | grep -q 'cap_sys_nice'; then
      echo ""
      echo "================================================================"
      echo "  GAMESCOPE CAPABILITY REQUEST"
      echo "================================================================"
      echo ""
      echo "  Performance mode requires granting cap_sys_nice to gamescope."
      echo ""
      read -p "Grant cap_sys_nice to gamescope? [Y/n]: " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        sudo setcap 'cap_sys_nice=eip' "$(command -v gamescope)" || warn "Failed to set capability"
        info "Capability granted to gamescope"
      fi
    fi
  fi
}

# Optional: install Bluetooth Xbox controller support (xpadneo).
# Wired Xbox controllers work without this via the kernel's xpad driver.
# xpadneo-dkms gives proper button mapping and rumble for wireless controllers
# in Steam Big Picture / RetroArch. Mirrors omarchy-install-gaming-xbox-controllers
# but defers reboot/relogin to the installer's end-of-setup prompt instead of
# triggering its own.
setup_xbox_controllers() {
  echo ""
  echo "================================================================"
  echo "  XBOX BLUETOOTH CONTROLLER SUPPORT (optional)"
  echo "================================================================"
  echo ""
  echo "  Installs xpadneo-dkms for proper button mapping and rumble"
  echo "  with wireless Xbox controllers in Big Picture / RetroArch."
  echo ""
  echo "  Wired Xbox pads already work via the kernel's xpad driver and"
  echo "  do not need this step."
  echo ""
  read -p "Install Xbox Bluetooth controller support? [y/N]: " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    info "Skipping Xbox controller support"
    return 0
  fi

  info "Installing xpadneo-dkms..."
  omarchy-pkg-add linux-headers xpadneo-dkms || {
    warn "Failed to install Xbox controller packages"
    return 1
  }

  echo blacklist xpad | sudo tee /etc/modprobe.d/blacklist-xpad.conf >/dev/null
  echo hid_xpadneo | sudo tee /etc/modules-load.d/xpadneo.conf >/dev/null

  if ! id -nG "$USER" | grep -qw input; then
    sudo usermod -aG input "$USER"
    NEEDS_RELOGIN=1
    info "Added $USER to the input group (login required to take effect)"
  fi

  if lsmod | grep -q '^xpad '; then
    sudo modprobe -r xpad 2>/dev/null || NEEDS_REBOOT=1
  fi
  sudo modprobe hid_xpadneo 2>/dev/null || warn "Could not load hid_xpadneo (may need reboot)"

  info "Xbox Bluetooth controller support installed"
  info "Pair controllers with Super+Ctrl+B (Omarchy Bluetooth menu)"
}

# Install the Gaming Mode settings TUI and its Walker launcher.
# The TUI lets users pick monitor / GPU / resolution / refresh rate after
# install without hand-editing ~/.config/environment.d/gamescope-session-plus.conf.
# The .desktop file uses Omarchy's TUI.float pattern so it pops up as a floating
# terminal window from Walker (Super+Space → "DeckShift Settings").
setup_settings_tui() {
  echo ""
  echo "================================================================"
  echo "  GAMING MODE SETTINGS TUI"
  echo "================================================================"
  echo ""

  local tui_src="${SCRIPT_DIR}/bin/deckshift-settings"
  local desktop_src="${SCRIPT_DIR}/applications/deckshift-settings.desktop"
  local tui_dst="/usr/local/bin/deckshift-settings"
  local desktop_dst="/usr/share/applications/deckshift-settings.desktop"

  if [[ ! -f "$tui_src" || ! -f "$desktop_src" ]]; then
    warn "Settings TUI source files not found in ${SCRIPT_DIR} — skipping"
    return 0
  fi

  info "Installing gum + jq (TUI dependencies)..."
  omarchy-pkg-add gum jq || die "Failed to install settings TUI dependencies"

  info "Installing settings TUI to $tui_dst"
  sudo install -m 0755 "$tui_src" "$tui_dst" || die "Failed to install settings TUI"

  info "Installing Walker launcher to $desktop_dst"
  sudo install -m 0644 "$desktop_src" "$desktop_dst" || die "Failed to install desktop entry"

  if command -v update-desktop-database >/dev/null 2>&1; then
    sudo update-desktop-database /usr/share/applications 2>/dev/null || true
  fi

  # Refresh Walker so the new entry shows up immediately. omarchy-restart-walker
  # handles the elephant.service + walker autostart restart for us; without
  # this, the entry only appears after the next Walker restart / login.
  if command -v omarchy-restart-walker >/dev/null 2>&1; then
    omarchy-restart-walker 2>/dev/null || true
  fi

  info "Settings TUI installed — launch from Walker (Super+Space → 'DeckShift Settings')"
}

# ==============================================================================
# SESSION SWITCHING — The heart of the installer
#
# This is the biggest and most important function. It sets up everything needed
# to seamlessly switch between Desktop Mode (Hyprland) and Gaming Mode
# (Gamescope + Steam Big Picture).
#
# The switching mechanism works through SDDM (the display/login manager):
#   1. User presses Super+Shift+S in Hyprland
#   2. switch-to-gaming script updates SDDM config to point to Gaming session
#   3. SDDM restarts and auto-logs into the Gaming Mode session
#   4. gamescope-session-nm-wrapper starts performance tuning, NetworkManager,
#      drive mounting, keybind monitor, then launches Gamescope + Steam
#   5. When done (Super+Shift+R or Steam > Exit to Desktop), the reverse happens
#
# This function creates ALL the scripts and config files needed for this flow:
#   - Session wrapper (gamescope-session-nm-wrapper)
#   - Switch scripts (switch-to-gaming, switch-to-desktop)
#   - Keybind monitor (Python daemon using evdev for Super+Shift+R)
#   - NetworkManager start/stop scripts (iwd <-> NM handoff)
#   - Steam library auto-mount daemon
#   - SDDM session entry and config
#   - Polkit and sudoers rules for passwordless operation
#   - Hyprland keybind for Super+Shift+S
#
# It also installs ChimeraOS's gamescope-session packages from AUR, which
# provide the base session framework that the Steam Deck uses.
# ==============================================================================
setup_session_switching() {
  echo ""
  echo "================================================================"
  echo "  SESSION SWITCHING SETUP (Hyprland <-> Gamescope)"
  echo "  Using ChimeraOS gamescope-session packages"
  echo "================================================================"
  echo ""

  # Intel-only systems are supported but performance varies. Older Gen8/9
  # iGPUs (Skylake/Kaby Lake era) struggle with Vulkan — Tiger Lake Iris Xe
  # and Intel Arc are the realistic targets.
  if check_intel_only; then
    echo ""
    warn "Intel-only GPU detected — Gaming Mode performance varies by generation:"
    echo "    - Intel Arc (Alchemist, Battlemage):     good"
    echo "    - Tiger Lake / Alder Lake Iris Xe:       playable for indies"
    echo "    - Older Gen8/9 (Skylake, Kaby Lake):     expect slow/glitchy"
    echo ""
    read -p "Continue installation? [y/N]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      die "Installation aborted"
    fi
  fi

  echo "  This will:"
  echo "    - Install gamescope-session-git and gamescope-session-steam-git from AUR"
  echo "    - Configure Super+Shift+S to switch to Gaming Mode"
  echo "    - Configure Steam's 'Exit to Desktop' to return to Hyprland"
  echo ""
  read -p "Set up session switching? [Y/n]: " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Nn]$ ]]; then
    info "Skipping session switching setup"
    return 0
  fi

  local current_user="${SUDO_USER:-$USER}"
  local user_home
  user_home=$(eval echo "~$current_user")

  # GPU detection only — the installer no longer chooses a monitor, resolution
  # or refresh rate. Those are user choices, made later via Walker → "DeckShift
  # Settings". This avoids stale OUTPUT_CONNECTOR values when displays are
  # unplugged and lets the user pick whatever fits their setup.
  local -a dgpu_monitors=()
  local dgpu_card=""
  local dgpu_type=""
  detect_dgpu_monitors dgpu_monitors dgpu_card dgpu_type

  if [[ -z "$dgpu_card" ]]; then
    if [[ "$dgpu_type" == "NVIDIA" ]]; then
      err "NVIDIA GPU detected but no DRM card found!"
      echo ""
      echo "  This usually means nvidia-drm.modeset=1 is not set."
      echo "  The installer will configure this - please complete the setup"
      echo "  and REBOOT before running this section again."
      echo ""
      NEEDS_REBOOT=1
      return 1
    fi
    # No dGPU - check for AMD APU as a viable Gaming Mode GPU
    local apu_card=""
    local card_name driver_link driver

    for card_path in /sys/class/drm/card[0-9]*; do
      card_name=$(basename "$card_path")
      [[ "$card_name" == render* ]] && continue
      driver_link="$card_path/device/driver"
      [[ -L "$driver_link" ]] || continue
      driver=$(basename "$(readlink "$driver_link")")

      if [[ "$driver" == "amdgpu" ]] && is_amd_igpu_card "$card_path"; then
        apu_card="$card_name"
        break
      fi
    done

    if [[ -n "$apu_card" ]]; then
      echo ""
      info "No discrete GPU found, but detected AMD APU ($apu_card)"
      echo ""
      read -p "  Set up Gaming Mode for APU? [Y/n]: " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        dgpu_card="$apu_card"
        dgpu_type="AMD APU"
        info "Configuring Gaming Mode for AMD APU"
      else
        info "Skipping APU Gaming Mode setup"
        return 0
      fi
    else
      err "No discrete GPU (dGPU) or AMD APU found!"
      echo "  Gaming mode requires a supported GPU."
      return 1
    fi
  fi

  info "Found $dgpu_type on $dgpu_card"
  info "Display selection (monitor / resolution / refresh) is left to the user."
  info "After install, launch Walker → 'DeckShift Settings' to configure."

  info "Checking for old custom session files to clean up..."

  local -a old_files=(
    "/usr/bin/gamescope-session"
    "/usr/share/wayland-sessions/gamescope-session.desktop"
    "/usr/bin/jupiter-biosupdate"
    "/usr/bin/steamos-update"
    "/usr/bin/steamos-select-branch"
    "/usr/bin/steamos-session-select"
  )

  local cleaned=false
  for old_file in "${old_files[@]}"; do
    if [[ -f "$old_file" ]]; then
      info "Removing old file: $old_file"
      sudo rm -f "$old_file" && cleaned=true
    fi
  done

  if $cleaned; then
    info "Old custom session files removed"
  else
    info "No old files to clean up"
  fi

  info "Checking for ChimeraOS gamescope-session packages..."

  local -a aur_packages=()
  local -a packages_to_remove=()

  if ! check_package "gamescope-session-git" && ! check_package "gamescope-session"; then
    aur_packages+=("gamescope-session-git")
  fi

  local steam_scripts_missing=false
  local -a required_steam_scripts=(
    "/usr/bin/steamos-session-select"
    "/usr/bin/steamos-update"
    "/usr/bin/jupiter-biosupdate"
    "/usr/bin/steamos-select-branch"
  )

  for script in "${required_steam_scripts[@]}"; do
    if [[ ! -f "$script" ]]; then
      steam_scripts_missing=true
      break
    fi
  done

  if ! check_package "gamescope-session-steam-git"; then
    if check_package "gamescope-session-steam"; then
      warn "gamescope-session-steam (non-git) is installed but missing Steam compatibility scripts"
      info "The -git version from ChimeraOS includes required scripts:"
      info "  - steamos-session-select, steamos-update, jupiter-biosupdate, steamos-select-branch"
      packages_to_remove+=("gamescope-session-steam")
    fi
    aur_packages+=("gamescope-session-steam-git")
  elif $steam_scripts_missing; then
    warn "gamescope-session-steam-git is installed but Steam compatibility scripts are missing!"
    info "Will reinstall package to restore missing files:"
    for script in "${required_steam_scripts[@]}"; do
      if [[ ! -f "$script" ]]; then
        info "  - Missing: $script"
      fi
    done
    packages_to_remove+=("gamescope-session-steam-git")
    aur_packages+=("gamescope-session-steam-git")
  fi

  if ((${#aur_packages[@]})); then
    echo ""
    echo "  The following AUR packages are required for ChimeraOS session:"
    for pkg in "${aur_packages[@]}"; do
      echo "    - $pkg"
    done
    if ((${#packages_to_remove[@]})); then
      echo ""
      echo "  The following packages need to be replaced:"
      for pkg in "${packages_to_remove[@]}"; do
        echo "    - $pkg (will be removed)"
      done
    fi
    echo ""

    local aur_helper=""
    if command -v yay >/dev/null 2>&1 && check_aur_helper_functional yay; then
      aur_helper="yay"
    elif command -v paru >/dev/null 2>&1 && check_aur_helper_functional paru; then
      aur_helper="paru"
    fi

    if [[ -n "$aur_helper" ]]; then
      read -p "Install ChimeraOS session packages with $aur_helper? [Y/n]: " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        if ((${#packages_to_remove[@]})); then
          info "Removing conflicting packages: ${packages_to_remove[*]}"
          sudo pacman -Rns --noconfirm "${packages_to_remove[@]}" || {
            warn "Failed to remove old packages, trying to continue anyway..."
          }
        fi

        info "Installing ChimeraOS gamescope-session packages..."
        $aur_helper -S --needed --noconfirm --answeredit None --answerclean None --answerdiff None "${aur_packages[@]}" || {
          err "Failed to install gamescope-session packages"
          warn "You may need to install them manually: $aur_helper -S ${aur_packages[*]}"
        }
      fi
    else
      warn "No AUR helper found (yay/paru). Please install manually:"
      if ((${#packages_to_remove[@]})); then
        echo "    sudo pacman -Rns ${packages_to_remove[*]}"
      fi
      echo "    yay -S ${aur_packages[*]}"
      echo ""
      read -p "Press Enter to continue after installing, or Ctrl+C to abort..."
    fi
  else
    info "ChimeraOS gamescope-session packages already installed (correct -git versions)"
  fi

  # NetworkManager Integration
  #
  # Omarchy uses iwd (Intel Wireless Daemon) for WiFi, but Steam requires
  # NetworkManager for its network settings UI. These can't run simultaneously
  # without conflicts, so we create a managed handoff:
  #   - On gaming session start: NM starts, takes over networking from iwd
  #   - On gaming session exit: NM stops, iwd restarts and reconnects to WiFi
  #
  # If iwd is active, we configure NM to use iwd as its WiFi backend so they
  # cooperate instead of fighting. If systemd-networkd is also running, we
  # tell NM to leave ethernet interfaces alone to avoid conflicts.
  info "Setting up NetworkManager integration..."
  if systemctl is-active --quiet iwd; then
    info "Detected iwd is active - configuring NetworkManager to use iwd backend..."
    sudo mkdir -p /etc/NetworkManager/conf.d
    sudo tee /etc/NetworkManager/conf.d/10-iwd-backend.conf > /dev/null << 'NM_IWD_CONF'
[device]
wifi.backend=iwd
wifi.scan-rand-mac-address=no

[main]
plugins=ifupdown,keyfile

[ifupdown]
managed=false

[connection]
connection.autoconnect-slaves=0
NM_IWD_CONF
    info "Created NetworkManager iwd backend configuration"
  fi

  if systemctl is-active --quiet systemd-networkd; then
    info "Detected systemd-networkd - configuring NetworkManager to avoid conflicts..."
    sudo tee /etc/NetworkManager/conf.d/20-unmanaged-systemd.conf > /dev/null << 'NM_UNMANAGED'
[keyfile]
unmanaged-devices=interface-name:en*;interface-name:eth*
NM_UNMANAGED
    info "Configured NetworkManager to not manage ethernet interfaces"
  fi

  local nm_start_script="/usr/local/bin/gamescope-nm-start"
  sudo tee "$nm_start_script" > /dev/null << 'NM_START'
#!/bin/bash
NM_MARKER="/tmp/.gamescope-started-nm"
LOG_TAG="gamescope-nm"

log() { logger -t "$LOG_TAG" "$*"; echo "$*"; }

if ! systemctl is-active --quiet NetworkManager.service; then
    log "Starting NetworkManager service..."
    systemctl start NetworkManager.service
    if [ $? -eq 0 ]; then
        touch "$NM_MARKER"
        log "NetworkManager started successfully"
    else
        log "ERROR: Failed to start NetworkManager"
        exit 1
    fi
    log "Waiting for NetworkManager to initialize..."
    for i in {1..20}; do
        if nmcli general status &>/dev/null; then
            log "NetworkManager ready after ${i} attempts"
            break
        fi
        sleep 0.5
    done
    if nmcli general status 2>/dev/null | grep -q "connected"; then
        log "Network connected and ready"
    else
        log "WARNING: NetworkManager running but not connected"
    fi
else
    log "NetworkManager already running"
fi
nmcli general status 2>/dev/null || log "WARNING: nmcli status check failed"
NM_START
  sudo chmod +x "$nm_start_script"

  local nm_stop_script="/usr/local/bin/gamescope-nm-stop"
  sudo tee "$nm_stop_script" > /dev/null << 'NM_STOP'
#!/bin/bash
NM_MARKER="/tmp/.gamescope-started-nm"
LOG_TAG="gamescope-nm"
log() { logger -t "$LOG_TAG" "$*"; echo "$*"; }

if [ -f "$NM_MARKER" ]; then
    rm -f "$NM_MARKER"
    if systemctl is-active --quiet NetworkManager.service; then
        log "Stopping NetworkManager service..."
        systemctl stop NetworkManager.service 2>/dev/null || true
        sleep 1
    fi

    # Restart iwd to restore WiFi connection (must restart, not just start,
    # because iwd may be "active" but not managing the interface while NM had control)
    log "Restarting iwd to restore WiFi..."
    systemctl restart iwd.service 2>/dev/null || true
    sleep 3

    # Find the wireless interface dynamically
    WIFI_IFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
    if [ -z "$WIFI_IFACE" ]; then
        WIFI_IFACE=$(ls /sys/class/net/ 2>/dev/null | grep -E '^wl' | head -1)
    fi

    if [ -n "$WIFI_IFACE" ]; then
        # Verify WiFi restoration (iwd auto-connects to known networks)
        if iwctl station "$WIFI_IFACE" show 2>/dev/null | grep -qi "connected"; then
            log "WiFi restored on $WIFI_IFACE"
        else
            log "Triggering WiFi scan on $WIFI_IFACE..."
            iwctl station "$WIFI_IFACE" scan 2>/dev/null || true
            sleep 3
            if iwctl station "$WIFI_IFACE" show 2>/dev/null | grep -qi "connected"; then
                log "WiFi connected on $WIFI_IFACE after scan"
            else
                log "WiFi on $WIFI_IFACE may need manual reconnection via iwctl"
            fi
        fi
    else
        log "No wireless interface found - skipping WiFi verification"
    fi
else
    log "No marker file found - NetworkManager was not started by gaming session"
fi
NM_STOP
  sudo chmod +x "$nm_stop_script"
  info "Created NetworkManager start/stop scripts"

  # Steam Library Auto-Mount Daemon
  #
  # Many gamers have games spread across multiple drives (external SSDs,
  # NTFS partitions from a Windows dual-boot, etc.). This daemon:
  #   1. Scans all connected drives for Steam library folders (steamapps/)
  #   2. Mounts drives that contain Steam libraries via udisks2
  #   3. Unmounts drives that DON'T have Steam libraries (keeps it clean)
  #   4. Watches for hot-plugged drives (USB drives plugged in during gaming)
  #
  # It runs in the background during Gaming Mode and stops when you exit.
  local steam_mount_script="/usr/local/bin/steam-library-mount"
  info "Creating Steam library drive mount script..."
  sudo tee "$steam_mount_script" > /dev/null << 'STEAM_MOUNT'
#!/bin/bash
LOG_TAG="steam-library-mount"
MOUNT_BASE="/run/media/$USER"

log() { logger -t "$LOG_TAG" "$*"; }

check_steam_library() {
    local mount_point="$1"
    if [[ -d "$mount_point/steamapps" ]] || \
       [[ -d "$mount_point/SteamLibrary/steamapps" ]] || \
       [[ -d "$mount_point/SteamLibrary" ]] || \
       [[ -f "$mount_point/libraryfolder.vdf" ]] || \
       [[ -f "$mount_point/steamapps/libraryfolder.vdf" ]] || \
       [[ -f "$mount_point/SteamLibrary/libraryfolder.vdf" ]]; then
        return 0
    fi
    return 1
}

handle_device() {
    local device="$1"
    local part_name
    part_name=$(basename "$device")

    log "Checking device: $device"

    if findmnt -n "$device" &>/dev/null; then
        local existing_mount
        existing_mount=$(findmnt -n -o TARGET "$device" 2>/dev/null)
        if [[ -n "$existing_mount" ]] && check_steam_library "$existing_mount"; then
            log "Steam library already mounted at $existing_mount"
        else
            log "Device $device mounted at $existing_mount (no Steam library)"
        fi
        return
    fi

    [[ "$device" =~ [0-9]$ ]] || { log "Skipping whole disk: $device"; return; }

    local fstype
    fstype=$(lsblk -n -o FSTYPE --nodeps "$device" 2>/dev/null)
    case "$fstype" in
        ext4|ext3|ext2|btrfs|xfs|ntfs|vfat|exfat|f2fs) ;;
        crypto_LUKS) log "Skipping encrypted: $device"; return ;;
        swap) log "Skipping swap: $device"; return ;;
        "") log "Skipping $device - no filesystem"; return ;;
        *) log "Skipping $device - unsupported filesystem: $fstype"; return ;;
    esac

    if ! command -v udisksctl &>/dev/null; then
        log "udisksctl not found - cannot mount $device"
        return
    fi

    log "Attempting to mount $device..."
    local mount_output
    mount_output=$(udisksctl mount -b "$device" --no-user-interaction 2>&1)
    local mount_rc=$?

    if [[ $mount_rc -ne 0 ]]; then
        log "Could not mount $device: $mount_output"
        return
    fi

    local mount_point
    mount_point=$(findmnt -n -o TARGET "$device" 2>/dev/null)

    if [[ -z "$mount_point" ]]; then
        log "Could not determine mount point for $device"
        return
    fi

    if check_steam_library "$mount_point"; then
        log "Steam library found on $device at $mount_point - keeping mounted"
    else
        log "No Steam library on $device - unmounting"
        udisksctl unmount -b "$device" --no-user-interaction 2>/dev/null
    fi
}

log "Starting Steam library drive monitor..."

shopt -s nullglob
for dev in /dev/sd*[0-9]* /dev/nvme*p[0-9]*; do
    [[ -b "$dev" ]] && handle_device "$dev"
done
shopt -u nullglob

log "Initial device scan complete, watching for new devices..."

udevadm monitor --kernel --subsystem-match=block 2>/dev/null | while read -r line; do
    if [[ "$line" =~ ^KERNEL.*[[:space:]]add[[:space:]]+.*/([^/[:space:]]+)[[:space:]]+\(block\)$ ]]; then
        dev_name="${BASH_REMATCH[1]}"
        dev_path="/dev/$dev_name"
        if [[ "$dev_name" =~ [0-9]$ ]] && [[ -b "$dev_path" ]]; then
            sleep 1
            handle_device "$dev_path"
        fi
    fi
done
STEAM_MOUNT
  sudo chmod +x "$steam_mount_script"
  info "Created $steam_mount_script"

  # Polkit Rules
  #
  # Polkit is Linux's permission system for D-Bus actions. Steam communicates
  # with NetworkManager over D-Bus, but by default only root can control NM.
  # These rules allow members of the "wheel" group (admin users) to control
  # NetworkManager without a password prompt — otherwise Steam would show
  # a "permission denied" error when trying to access network settings.
  local polkit_rules="/etc/polkit-1/rules.d/50-gamescope-networkmanager.rules"

  if sudo test -f "$polkit_rules"; then
    info "Polkit rules already exist at $polkit_rules"
  else
    info "Creating Polkit rules for NetworkManager D-Bus access..."

    local polkit_output
    polkit_output=$(sudo tee "$polkit_rules" << 'POLKIT_RULES' 2>&1
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.NetworkManager.enable-disable-network" ||
         action.id == "org.freedesktop.NetworkManager.enable-disable-wifi" ||
         action.id == "org.freedesktop.NetworkManager.network-control" ||
         action.id == "org.freedesktop.NetworkManager.wifi.scan" ||
         action.id == "org.freedesktop.NetworkManager.settings.modify.system" ||
         action.id == "org.freedesktop.NetworkManager.settings.modify.own" ||
         action.id == "org.freedesktop.NetworkManager.settings.modify.hostname") &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
POLKIT_RULES
)
    local polkit_exit=$?

    if [[ $polkit_exit -eq 0 ]]; then
      sudo chmod 644 "$polkit_rules"
      info "Polkit rules created successfully"
      sudo systemctl restart polkit.service 2>/dev/null || true
    else
      err "Failed to create polkit rules file (exit code: $polkit_exit)"
    fi
  fi

  # Udisks2 Polkit Rules — same concept as above but for drive mounting.
  # Allows the steam-library-mount daemon to mount/unmount drives without
  # a password prompt. Without this, plugging in a USB drive with games
  # would show a password dialog — not ideal in the middle of a gaming session.
  local udisks_polkit="/etc/polkit-1/rules.d/50-udisks-gaming.rules"

  if sudo test -f "$udisks_polkit"; then
    info "Udisks2 polkit rules already exist at $udisks_polkit"
  else
    info "Creating Polkit rules for external drive auto-mount..."
    sudo mkdir -p /etc/polkit-1/rules.d
    sudo tee "$udisks_polkit" > /dev/null << 'UDISKS_POLKIT'
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.udisks2.filesystem-mount" ||
         action.id == "org.freedesktop.udisks2.filesystem-mount-system" ||
         action.id == "org.freedesktop.udisks2.filesystem-unmount-others" ||
         action.id == "org.freedesktop.udisks2.encrypted-unlock" ||
         action.id == "org.freedesktop.udisks2.power-off-drive") &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
UDISKS_POLKIT

    if [[ $? -eq 0 ]]; then
      sudo chmod 644 "$udisks_polkit"
      info "Udisks2 polkit rules created successfully"
      sudo systemctl restart polkit.service 2>/dev/null || true
    else
      err "Failed to create udisks2 polkit rules"
    fi
  fi

  # Gamescope Session Configuration
  #
  # The installer writes only GPU-specific and static keys here. Display keys
  # (SCREEN_WIDTH, SCREEN_HEIGHT, CUSTOM_REFRESH_RATES, OUTPUT_CONNECTOR) are
  # NOT written by the installer — they are owned by the user and managed via
  # the settings TUI (Walker → "DeckShift Settings"). This keeps existing user
  # selections intact across re-runs and avoids preselecting values that may
  # not match the user's setup.
  #
  # NVIDIA gets: VULKAN_ADAPTER + GBM_BACKEND=nvidia-drm
  # AMD gets:    ADAPTIVE_SYNC=1 + ENABLE_GAMESCOPE_HDR=1
  # Intel:       no extra display flags (adaptive sync / HDR unreliable on Intel)
  info "Updating gamescope-session-plus configuration..."
  local env_dir="${user_home}/.config/environment.d"
  local gamescope_conf="${env_dir}/gamescope-session-plus.conf"

  mkdir -p "$env_dir"
  touch "$gamescope_conf"

  # Per-key updater — replaces in place if present, appends if missing.
  # Same shape as the TUI's flush_pending so the two never fight.
  set_conf_key() {
    local key="$1" value="$2"
    if grep -qE "^${key}=" "$gamescope_conf"; then
      sed -i "s|^${key}=.*|${key}=${value}|" "$gamescope_conf"
    else
      echo "${key}=${value}" >> "$gamescope_conf"
    fi
  }
  unset_conf_key() {
    sed -i "/^$1=/d" "$gamescope_conf"
  }

  # Static keys — apply on every install, every GPU.
  set_conf_key STEAM_ALLOW_DRIVE_UNMOUNT 1
  set_conf_key FCITX_NO_WAYLAND_DIAGNOSE 1
  set_conf_key SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS 0

  # GPU-specific keys — set the right ones, clear stale ones from a prior
  # install on a different GPU (e.g. user swapped NVIDIA → AMD).
  case "$dgpu_type" in
    "NVIDIA")
      local nvidia_device_id
      nvidia_device_id=$(/usr/bin/lspci -nn | grep -i nvidia | grep -oP '\[10de:\K[0-9a-fA-F]+' | head -1)
      [[ -n "$nvidia_device_id" ]] && set_conf_key VULKAN_ADAPTER "10de:${nvidia_device_id}"
      set_conf_key GBM_BACKEND nvidia-drm
      unset_conf_key ADAPTIVE_SYNC
      unset_conf_key ENABLE_GAMESCOPE_HDR
      unset_conf_key DRI_PRIME
      ;;
    "Intel")
      unset_conf_key VULKAN_ADAPTER
      unset_conf_key GBM_BACKEND
      unset_conf_key ADAPTIVE_SYNC
      unset_conf_key ENABLE_GAMESCOPE_HDR
      ;;
    *)
      # AMD dGPU and AMD APU — adaptive sync (FreeSync) and HDR are well supported.
      set_conf_key ADAPTIVE_SYNC 1
      set_conf_key ENABLE_GAMESCOPE_HDR 1
      unset_conf_key VULKAN_ADAPTER
      unset_conf_key GBM_BACKEND
      ;;
  esac

  unset -f set_conf_key unset_conf_key

  info "Updated $gamescope_conf (display keys left for the TUI)"

  # NVIDIA Gamescope Wrapper
  #
  # NVIDIA GPUs need the --force-composition flag in Gamescope to avoid
  # rendering glitches. This wrapper script sits in front of the real
  # gamescope binary — when Gaming Mode starts, it calls this wrapper
  # instead, which adds the flag and then exec's the real gamescope.
  # It checks if the flag is actually supported first (older versions don't have it).
  info "Creating NVIDIA gamescope wrapper..."
  local nvidia_wrapper_dir="/usr/local/lib/gamescope-nvidia"
  local nvidia_wrapper="${nvidia_wrapper_dir}/gamescope"

  sudo mkdir -p "$nvidia_wrapper_dir"
  sudo tee "$nvidia_wrapper" > /dev/null << 'NVIDIA_WRAPPER'
#!/bin/bash
EXTRA_ARGS=""
if /usr/bin/gamescope --help 2>&1 | grep -q "force-composition"; then
    EXTRA_ARGS="--force-composition"
fi
exec /usr/bin/gamescope $EXTRA_ARGS "$@"
NVIDIA_WRAPPER

  sudo chmod +x "$nvidia_wrapper"
  info "Created $nvidia_wrapper"

  # Main Session Wrapper — gamescope-session-nm-wrapper
  #
  # This is the master script that runs when Gaming Mode starts. It's the
  # entry point for the entire gaming session and orchestrates everything:
  #
  #   1. Enables performance mode (CPU governor → performance, GPU max power)
  #   2. Adds NVIDIA wrapper to PATH if needed
  #   3. Starts NetworkManager for Steam's network access
  #   4. Launches steam-library-mount daemon for external drive detection
  #   5. Starts the keybind monitor (listens for Super+Shift+R to exit)
  #   6. Sets Steam-specific environment variables
  #   7. Launches gamescope-session-plus (the actual Gamescope + Steam session)
  #
  # When the session ends (for any reason), the cleanup trap:
  #   - Kills the mount daemon and keybind monitor
  #   - Stops NetworkManager and restores iwd WiFi
  #   - Restores balanced power mode (CPU powersave, GPU defaults)
  #   - Removes the session marker file
  info "Creating NetworkManager session wrapper..."
  local nm_wrapper="/usr/local/bin/gamescope-session-nm-wrapper"

  sudo tee "$nm_wrapper" > /dev/null << 'NM_WRAPPER'
#!/bin/bash
log() { logger -t gamescope-wrapper "$*"; echo "$*"; }

SAVED_STATE_FILE="$HOME/.cache/deckshift/saved-state"

# Capture the user's actual pre-Gaming-Mode CPU governor + power profile so we
# can restore those exact values on exit, instead of guessing "powersave/balanced"
# (which was wrong on systems whose default is schedutil or power-saver).
save_pre_gaming_state() {
    mkdir -p "$(dirname "$SAVED_STATE_FILE")"
    {
        echo "PRE_GAMING_CPU_GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
        echo "PRE_GAMING_POWER_PROFILE=$(powerprofilesctl get 2>/dev/null)"
    } > "$SAVED_STATE_FILE"
    log "Saved pre-Gaming-Mode state to $SAVED_STATE_FILE"
}

enable_performance_mode() {
    log "Enabling performance mode..."
    save_pre_gaming_state

    # Set CPU governor to performance
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$gov" 2>/dev/null
    done
    log "CPU governor set to performance"

    # NVIDIA dGPU performance mode
    if command -v nvidia-smi &>/dev/null; then
        sudo -n nvidia-smi -pm 1 2>/dev/null && log "NVIDIA persistence mode enabled"

        local max_power
        max_power=$(nvidia-smi --query-gpu=power.max_limit --format=csv,noheader,nounits 2>/dev/null | head -1 | cut -d'.' -f1)
        if [[ -n "$max_power" && "$max_power" -gt 0 ]]; then
            sudo -n nvidia-smi -pl "$max_power" 2>/dev/null && log "NVIDIA power limit set to ${max_power}W"
        fi

        for nvidia_pci in /sys/bus/pci/devices/*/power/control; do
            if [[ -f "${nvidia_pci%/power/control}/driver" ]]; then
                local drv=$(basename "$(readlink -f "${nvidia_pci%/power/control}/driver")" 2>/dev/null)
                if [[ "$drv" == "nvidia" ]]; then
                    echo on > "$nvidia_pci" 2>/dev/null && log "NVIDIA runtime suspend disabled"
                fi
            fi
        done
    fi

    # Set power profile to performance — sudo -n bypasses the polkit prompt
    # (NOPASSWD allowed for `powerprofilesctl set *` in /etc/sudoers.d/gaming-session-switch)
    if command -v powerprofilesctl &>/dev/null; then
        sudo -n powerprofilesctl set performance 2>/dev/null || \
            powerprofilesctl set performance 2>/dev/null && log "Power profile set to performance"
    fi
}

restore_balanced_mode() {
    log "Restoring pre-Gaming-Mode state..."

    # Read what the user's state actually was before Gaming Mode; fall back
    # to safe defaults if the saved-state file is missing.
    local saved_cpu_gov="" saved_pp=""
    if [[ -f "$SAVED_STATE_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$SAVED_STATE_FILE"
        saved_cpu_gov="${PRE_GAMING_CPU_GOVERNOR:-}"
        saved_pp="${PRE_GAMING_POWER_PROFILE:-}"
    fi

    local target_gov="${saved_cpu_gov:-powersave}"
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo "$target_gov" > "$gov" 2>/dev/null
    done

    # NVIDIA dGPU restore
    if command -v nvidia-smi &>/dev/null; then
        local default_power
        default_power=$(nvidia-smi --query-gpu=power.default_limit --format=csv,noheader,nounits 2>/dev/null | head -1 | cut -d'.' -f1)
        if [[ -n "$default_power" && "$default_power" -gt 0 ]]; then
            sudo -n nvidia-smi -pl "$default_power" 2>/dev/null
        fi

        for nvidia_pci in /sys/bus/pci/devices/*/power/control; do
            if [[ -f "${nvidia_pci%/power/control}/driver" ]]; then
                local drv=$(basename "$(readlink -f "${nvidia_pci%/power/control}/driver")" 2>/dev/null)
                if [[ "$drv" == "nvidia" ]]; then
                    echo auto > "$nvidia_pci" 2>/dev/null
                fi
            fi
        done

        sudo -n nvidia-smi -pm 0 2>/dev/null
    fi

    # Restore power profile (saved value, or balanced fallback)
    if command -v powerprofilesctl &>/dev/null; then
        local target_pp="${saved_pp:-balanced}"
        sudo -n powerprofilesctl set "$target_pp" 2>/dev/null || \
            powerprofilesctl set "$target_pp" 2>/dev/null
    fi

    rm -f "$SAVED_STATE_FILE"
    log "Pre-Gaming-Mode state restored (governor=$target_gov profile=${saved_pp:-balanced})"
}

cleanup() {
    pkill -f steam-library-mount 2>/dev/null || true
    pkill -f gaming-keybind-monitor 2>/dev/null || true
    sudo -n /usr/local/bin/gamescope-nm-stop 2>/dev/null || true
    restore_balanced_mode
    rm -f /tmp/.gaming-session-active
}
trap cleanup EXIT INT TERM

# Enable performance mode immediately on session start
enable_performance_mode

if /usr/bin/lspci 2>/dev/null | grep -qi nvidia; then
    export PATH="/usr/local/lib/gamescope-nvidia:$PATH"
fi

sudo -n /usr/local/bin/gamescope-nm-start 2>/dev/null || {
    log "Warning: Could not start NetworkManager"
}

if [[ -x /usr/local/bin/steam-library-mount ]]; then
    /usr/local/bin/steam-library-mount &
    log "Steam library drive monitor started"
else
    log "Warning: steam-library-mount not found"
fi

echo "gamescope" > /tmp/.gaming-session-active

keybind_ok=true

if ! python3 -c "import evdev" 2>/dev/null; then
    log "WARNING: python-evdev not installed"
    keybind_ok=false
fi

if ! groups | grep -qw input; then
    log "WARNING: User not in 'input' group"
    keybind_ok=false
fi

if $keybind_ok && ! ls /dev/input/event* >/dev/null 2>&1; then
    log "WARNING: No input devices accessible"
    keybind_ok=false
fi

if $keybind_ok; then
    /usr/local/bin/gaming-keybind-monitor &
    log "Keybind monitor started (Super+Shift+R to exit)"
else
    log "Keybind monitor NOT started"
fi

export QT_IM_MODULE=steam
export GTK_IM_MODULE=Steam
export STEAM_DISABLE_AUDIO_DEVICE_SWITCHING=1
export STEAM_ENABLE_VOLUME_HANDLER=1

/usr/share/gamescope-session-plus/gamescope-session-plus steam
rc=$?

exit $rc
NM_WRAPPER

  sudo chmod +x "$nm_wrapper"
  info "Created $nm_wrapper"

  # SDDM Session Entry
  #
  # SDDM (the login/display manager) needs a .desktop file to know about
  # Gaming Mode as a session option. This is what tells SDDM "when you
  # auto-login to the gaming session, run this script." It's placed in
  # /usr/share/wayland-sessions/ alongside the normal Hyprland session.
  info "Creating SDDM session entry..."
  local session_desktop="/usr/share/wayland-sessions/gamescope-session-steam-nm.desktop"

  sudo tee "$session_desktop" > /dev/null << 'SESSION_DESKTOP'
[Desktop Entry]
Name=Gaming Mode (ChimeraOS)
Comment=Steam Big Picture with ChimeraOS gamescope-session
Exec=/usr/local/bin/gamescope-session-nm-wrapper
Type=Application
DesktopNames=gamescope
SESSION_DESKTOP

  info "Created $session_desktop"

  # os-session-select — Steam's "Exit to Desktop" handler
  #
  # When you click Steam > Power > "Exit to Desktop" inside Gaming Mode,
  # Steam calls /usr/lib/os-session-select. On a real Steam Deck this
  # switches to Desktop Mode. Our version does the same thing — it updates
  # SDDM to boot back into Hyprland and restarts the display manager.
  info "Creating session-select script..."
  local os_session_select="/usr/lib/os-session-select"

  sudo tee "$os_session_select" > /dev/null << 'OS_SESSION_SELECT'
#!/bin/bash
rm -f /tmp/.gaming-session-active
sudo -n /usr/local/bin/gaming-session-switch desktop 2>/dev/null || {
  echo "Warning: Failed to update session config"
}
timeout 5 steam -shutdown 2>/dev/null || true
sleep 1
nohup sudo -n systemctl restart sddm &>/dev/null &
disown
exit 0
OS_SESSION_SELECT

  sudo chmod +x "$os_session_select"
  info "Created $os_session_select"

  # switch-to-gaming — Called when Super+Shift+S is pressed in Hyprland
  #
  # This script handles the transition from Desktop to Gaming Mode:
  #   1. Masks suspend targets — prevents the system from sleeping when the
  #      monitor briefly disconnects during the display manager restart
  #   2. Updates SDDM config to auto-login to the gaming session
  #   3. Kills any leftover gamescope processes from a previous session
  #   4. Switches to VT2 (virtual terminal) to avoid display conflicts
  #   5. Restarts SDDM, which auto-logs into Gaming Mode
  info "Creating switch-to-gaming script..."
  local switch_script="/usr/local/bin/switch-to-gaming"

  sudo tee "$switch_script" > /dev/null << 'SWITCH_SCRIPT'
#!/bin/bash
# Inhibit suspend FIRST - prevents suspend when monitor detaches during switch
sudo -n systemctl mask --runtime sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null
sudo -n /usr/local/bin/gaming-session-switch gaming 2>/dev/null || {
  notify-send -u critical -t 3000 "Gaming Mode" "Failed to update session config" 2>/dev/null || true
}
notify-send -u normal -t 2000 "Gaming Mode" "Switching to Gaming Mode..." 2>/dev/null || true
pkill -9 gamescope 2>/dev/null || true
pkill -9 -f gamescope-session 2>/dev/null || true
sleep 1
sudo -n chvt 2 2>/dev/null || true
sleep 0.3
sudo -n systemctl restart sddm
SWITCH_SCRIPT

  sudo chmod +x "$switch_script"
  info "Created $switch_script"

  # switch-to-desktop — Called when Super+Shift+R is pressed in Gaming Mode
  #
  # This script handles the transition back from Gaming to Desktop Mode:
  #   1. Unmasks suspend targets (re-enables sleep/hibernate)
  #   2. Restores Bluetooth (disabled during gaming to reduce interference)
  #   3. Gracefully shuts down Steam (timeout 5s, then force kill)
  #   4. Kills gamescope with SIGTERM first, then SIGKILL if it won't die
  #   5. Updates SDDM config back to Hyprland session
  #   6. Restarts SDDM, which auto-logs into Desktop Mode
  info "Creating switch-to-desktop script..."
  local switch_desktop_script="/usr/local/bin/switch-to-desktop"

  sudo tee "$switch_desktop_script" > /dev/null << 'SWITCH_DESKTOP'
#!/bin/bash
if [[ ! -f /tmp/.gaming-session-active ]]; then
  exit 0
fi
rm -f /tmp/.gaming-session-active

# SYNCHRONOUS POWER RESTORE — done first because the trap-based restore in
# gamescope-session-nm-wrapper can be SIGKILL'd by `systemctl restart sddm`
# before it completes, leaving CPU governor / power profile stuck at
# "performance". Reading the saved-state file first guarantees the user's
# pre-Gaming-Mode values are restored even if the wrapper's trap dies.
SAVED_STATE_FILE="$HOME/.cache/deckshift/saved-state"
if [[ -f "$SAVED_STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$SAVED_STATE_FILE"
  for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo "${PRE_GAMING_CPU_GOVERNOR:-powersave}" > "$gov" 2>/dev/null
  done
  if command -v powerprofilesctl &>/dev/null && [[ -n "${PRE_GAMING_POWER_PROFILE:-}" ]]; then
    sudo -n powerprofilesctl set "$PRE_GAMING_POWER_PROFILE" 2>/dev/null || \
      powerprofilesctl set "$PRE_GAMING_POWER_PROFILE" 2>/dev/null
  fi
  rm -f "$SAVED_STATE_FILE"
fi

# Unmask both /etc and /run masking symlinks (the gaming-mode mask uses
# --runtime, which lives in /run; some systemd versions don't clear it via
# plain `unmask`). Then daemon-reload so logind's CanSuspend cache refreshes
# — without this, `systemctl suspend` returns "Access denied" via polkit even
# though the masks are gone.
sudo -n systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null
sudo -n systemctl unmask --runtime sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null
sudo -n systemctl daemon-reload 2>/dev/null
sudo -n /usr/local/bin/gaming-session-switch desktop 2>/dev/null || true

# Re-enable Bluetooth
sudo -n /usr/bin/rfkill unblock bluetooth 2>/dev/null || true
sudo -n /usr/bin/systemctl start bluetooth.service 2>/dev/null || true

timeout 5 steam -shutdown 2>/dev/null || true
sleep 1

pkill -TERM gamescope 2>/dev/null || true
pkill -TERM -f gamescope-session 2>/dev/null || true

for _ in {1..6}; do
  pgrep -x gamescope >/dev/null 2>&1 || break
  sleep 0.5
done

if pgrep -x gamescope >/dev/null 2>&1; then
  pkill -9 gamescope 2>/dev/null || true
  pkill -9 -f gamescope-session 2>/dev/null || true
fi

sleep 2

# Marker for the next Hyprland startup — tells deckshift-portal-recovery
# that we're returning from Gaming Mode and the xdg-desktop-portal stack
# needs a kick. Without this, Chromium/Firefox screen-sharing on Wayland
# silently fails (only tab-sharing works) because the portal is still bound
# to the killed Hyprland instance. /tmp survives SDDM restart; /run/user
# does not (logind tears down the user manager).
touch /tmp/.deckshift-just-returned 2>/dev/null || true

sudo -n chvt 2 2>/dev/null || true
sleep 0.5
# Atomic restart — stop+start (with stop and start as separate sudo calls)
# was unreliable: stop/start aren't NOPASSWD-allowed individually (only
# `restart` is), and the disowned `start` could be killed by session teardown
# before SDDM actually came back up, leaving the user on a black screen.
sudo -n systemctl restart sddm
exit 0
SWITCH_DESKTOP

  sudo chmod +x "$switch_desktop_script"
  info "Created $switch_desktop_script"

  # Keybind Monitor — Python daemon for Super+Shift+R in Gaming Mode
  #
  # Inside Gamescope, Hyprland isn't running so its keybinds don't work.
  # This Python script uses python-evdev to read raw keyboard input directly
  # from /dev/input/event* devices, bypassing the compositor entirely.
  #
  # It uses Linux's selector (epoll) interface to efficiently monitor multiple
  # keyboard devices simultaneously without busy-waiting. When it detects
  # Super+Shift+R, it calls switch-to-desktop to return to Hyprland.
  #
  # The user must be in the "input" group to read /dev/input/ devices.
  info "Creating gaming mode keybind monitor..."
  local keybind_monitor="/usr/local/bin/gaming-keybind-monitor"

  sudo tee "$keybind_monitor" > /dev/null << 'KEYBIND_MONITOR'
#!/usr/bin/env python3
import sys
import subprocess
import time
import syslog

def log(msg, error=False):
    print(msg, file=sys.stderr if error else sys.stdout)
    syslog.syslog(syslog.LOG_ERR if error else syslog.LOG_INFO, msg)

syslog.openlog("gaming-keybind-monitor", syslog.LOG_PID)

try:
    import evdev
    from evdev import ecodes
except ImportError:
    log("FATAL: python-evdev not installed", error=True)
    sys.exit(1)

def find_keyboards():
    keyboards = []
    devices_checked = 0
    permission_errors = 0
    for path in evdev.list_devices():
        devices_checked += 1
        try:
            device = evdev.InputDevice(path)
            caps = device.capabilities()
            if ecodes.EV_KEY in caps:
                keys = caps[ecodes.EV_KEY]
                if ecodes.KEY_A in keys and ecodes.KEY_R in keys:
                    keyboards.append(device)
        except PermissionError:
            permission_errors += 1
        except Exception:
            continue
    if permission_errors > 0 and not keyboards:
        log(f"FATAL: Permission denied on {permission_errors}/{devices_checked} input devices.", error=True)
    return keyboards

def monitor_keyboards(keyboards):
    meta_pressed = False
    shift_pressed = False
    from selectors import DefaultSelector, EVENT_READ
    selector = DefaultSelector()
    for kbd in keyboards:
        selector.register(kbd, EVENT_READ)
    log(f"Monitoring {len(keyboards)} keyboard(s) for Super+Shift+R...")
    try:
        while True:
            for key, mask in selector.select():
                device = key.fileobj
                try:
                    for event in device.read():
                        if event.type != ecodes.EV_KEY:
                            continue
                        if event.code in (ecodes.KEY_LEFTMETA, ecodes.KEY_RIGHTMETA):
                            meta_pressed = event.value > 0
                        elif event.code in (ecodes.KEY_LEFTSHIFT, ecodes.KEY_RIGHTSHIFT):
                            shift_pressed = event.value > 0
                        elif event.code == ecodes.KEY_R and event.value == 1:
                            if meta_pressed and shift_pressed:
                                log("Super+Shift+R detected! Switching to desktop...")
                                subprocess.run(['/usr/local/bin/switch-to-desktop'])
                                return
                except Exception as e:
                    log(f"Read error: {e}", error=True)
                    continue
    except KeyboardInterrupt:
        pass
    finally:
        selector.close()

def main():
    time.sleep(2)
    keyboards = find_keyboards()
    if not keyboards:
        log("FATAL: No accessible keyboards found!", error=True)
        sys.exit(1)
    monitor_keyboards(keyboards)

if __name__ == '__main__':
    main()
KEYBIND_MONITOR

  sudo chmod +x "$keybind_monitor"
  info "Created $keybind_monitor"

  # Portal Recovery Helper — runs at every Hyprland startup
  #
  # When switch-to-desktop restarts SDDM, the new Hyprland instance gets a
  # fresh HYPRLAND_INSTANCE_SIGNATURE, but xdg-desktop-portal-hyprland (and
  # the pipewire stack) may still be bound to the old, dead instance. The
  # symptom is Chromium/Firefox "Share desktop / window" failing silently on
  # Google Meet etc. while "Share a tab" still works (because tab capture
  # bypasses the portal entirely).
  #
  # switch-to-desktop drops /tmp/.deckshift-just-returned right before the
  # SDDM restart. This helper, run as exec-once from Hyprland's autostart,
  # checks for that marker on every Hyprland start, and if present, bounces
  # the portal + pipewire user services so they reattach to the live HIS.
  # No marker = no-op (cheap; runs in milliseconds).
  #
  # The recovery sequence is ordered to avoid a race that earlier versions
  # hit when restarting all five services simultaneously: portals could come
  # up before wireplumber had finished building the node graph, so the
  # screencast portal would bind to nothing. We now (a) push live session
  # env into D-Bus + systemd --user so portals activate against the new
  # Wayland socket, (b) stop portals first, (c) restart pipewire and wait
  # for the graph, (d) start portals last, (e) restart Walker/elephant so
  # the clipboard listener reattaches to the live Wayland socket too.
  info "Creating portal recovery helper..."
  local portal_recovery="/usr/local/bin/deckshift-portal-recovery"

  sudo tee "$portal_recovery" > /dev/null << 'PORTAL_RECOVERY'
#!/bin/bash
[[ -f /tmp/.deckshift-just-returned ]] || exit 0
rm -f /tmp/.deckshift-just-returned

# Give the new Hyprland a moment to fully come up and export its env to the
# user manager (HYPRLAND_INSTANCE_SIGNATURE / WAYLAND_DISPLAY).
sleep 2

# Pull the live session env into systemd --user and the D-Bus activation env,
# so D-Bus-activated portals bind to the new Wayland socket, not the dead one
# left over from the gamescope session.
systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE 2>/dev/null || true
dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE 2>/dev/null || true

# Stop portals first so they don't try to talk to a half-restarted pipewire.
systemctl --user stop xdg-desktop-portal-hyprland.service xdg-desktop-portal.service 2>/dev/null || true
# Kill any zombies left over from gamescope's session (SIGTERM, then SIGKILL
# only for stragglers — SIGKILL alone leaves stale D-Bus name registrations).
pkill -TERM -x xdg-desktop-portal-hyprland xdg-desktop-portal xdg-desktop-portal-wlr 2>/dev/null
sleep 0.5
pkill -KILL -x xdg-desktop-portal-hyprland xdg-desktop-portal xdg-desktop-portal-wlr 2>/dev/null
systemctl --user reset-failed xdg-desktop-portal-hyprland.service xdg-desktop-portal.service 2>/dev/null || true

# Restart pipewire stack and wait for wireplumber to rebuild the node graph
# before portals come back up (otherwise screencast portal binds to nothing).
systemctl --user restart pipewire.service pipewire-pulse.service wireplumber.service 2>/dev/null || true
sleep 2

# Now bring portals up cleanly.
systemctl --user start xdg-desktop-portal-hyprland.service xdg-desktop-portal.service 2>/dev/null || true

# Walker (elephant) holds the clipboard listener, which is also bound to the
# dead Hyprland's Wayland socket and stays broken until restarted. Prefer the
# omarchy helper if present; fall back to direct systemctl --user.
if command -v omarchy-restart-walker >/dev/null 2>&1; then
  omarchy-restart-walker >/dev/null 2>&1 || true
else
  systemctl --user restart elephant.service 2>/dev/null || true
  systemctl --user restart app-walker@autostart.service 2>/dev/null || true
fi
PORTAL_RECOVERY

  sudo chmod +x "$portal_recovery"
  info "Created $portal_recovery"

  # Hyprland autostart hook for portal recovery
  local hypr_autostart="${user_home}/.config/hypr/autostart.conf"
  if [[ -f "$hypr_autostart" ]]; then
    if grep -q "deckshift-portal-recovery" "$hypr_autostart" 2>/dev/null; then
      info "Portal recovery already wired into autostart.conf"
    else
      sudo -u "$current_user" tee -a "$hypr_autostart" > /dev/null << 'HYPR_PORTAL'

# DeckShift — restart xdg-desktop-portal stack after returning from Gaming Mode
exec-once = /usr/local/bin/deckshift-portal-recovery
HYPR_PORTAL
      info "Added portal recovery exec-once to $hypr_autostart"
    fi
  else
    warn "autostart.conf not found at $hypr_autostart — portal recovery not auto-wired"
    warn "Add manually: exec-once = /usr/local/bin/deckshift-portal-recovery"
  fi

  # SDDM Session Switching Config
  #
  # SDDM supports auto-login — it can automatically log in a user to a
  # specific session without showing the login screen. This config file
  # controls WHICH session SDDM auto-logs into.
  #
  # The switching mechanism works by editing this file:
  #   - "Session=hyprland-uwsm" → boots into Desktop Mode
  #   - "Session=gamescope-session-steam-nm" → boots into Gaming Mode
  #
  # The gaming-session-switch helper script toggles this value, then SDDM
  # is restarted to pick up the change. The "zz-" prefix ensures this
  # config loads LAST and overrides any other SDDM autologin settings.
  info "Creating SDDM session switching config..."
  local sddm_gaming_conf="/etc/sddm.conf.d/zz-gaming-session.conf"

  local autologin_user="$current_user"
  if [[ -f /etc/sddm.conf.d/autologin.conf ]]; then
    autologin_user=$(sed -n 's/^User=//p' /etc/sddm.conf.d/autologin.conf 2>/dev/null | head -1)
    [[ -z "$autologin_user" ]] && autologin_user="$current_user"
  fi

  sudo tee "$sddm_gaming_conf" > /dev/null << SDDM_GAMING
[Autologin]
User=${autologin_user}
Session=hyprland-uwsm
Relogin=true
SDDM_GAMING

  info "Created $sddm_gaming_conf"

  info "Creating session switching helper script..."
  local session_helper="/usr/local/bin/gaming-session-switch"

  sudo tee "$session_helper" > /dev/null << 'SESSION_HELPER'
#!/bin/bash
CONF="/etc/sddm.conf.d/zz-gaming-session.conf"
if [[ ! -f "$CONF" ]]; then
  echo "Error: Config file not found: $CONF" >&2
  exit 1
fi

case "$1" in
  gaming)
    sed -i 's/^Session=.*/Session=gamescope-session-steam-nm/' "$CONF"
    echo "Session set to: gaming mode"
    ;;
  desktop)
    sed -i 's/^Session=.*/Session=hyprland-uwsm/' "$CONF"
    echo "Session set to: desktop mode"
    ;;
  *)
    echo "Usage: $0 {gaming|desktop}" >&2
    exit 1
    ;;
esac
SESSION_HELPER

  sudo chmod +x "$session_helper"
  info "Created $session_helper"

  # Sudoers Rules for Session Switching
  #
  # The session switching scripts need to run several commands as root
  # (restart SDDM, start/stop NetworkManager, control Bluetooth, etc.).
  # These sudoers rules allow members of the "video" and "wheel" groups
  # to run ONLY these specific commands without a password.
  #
  # This is much safer than giving blanket NOPASSWD sudo — each rule
  # is scoped to a specific binary path. An attacker can't leverage
  # these rules to run arbitrary commands as root.
  local sudoers_session="/etc/sudoers.d/gaming-session-switch"

  if [[ -f "$sudoers_session" ]]; then
    info "Removing old sudoers rules to update..."
    sudo rm -f "$sudoers_session"
  fi

  info "Creating sudoers rules for session switching..."

  local switch_output
  switch_output=$(sudo tee "$sudoers_session" << 'SUDOERS_SWITCH' 2>&1
%video ALL=(ALL) NOPASSWD: /usr/local/bin/gaming-session-switch
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart sddm
%video ALL=(ALL) NOPASSWD: /usr/bin/chvt
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl mask --runtime sleep.target suspend.target hibernate.target hybrid-sleep.target
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl unmask --runtime sleep.target suspend.target hibernate.target hybrid-sleep.target
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl daemon-reload
%wheel ALL=(ALL) NOPASSWD: /usr/bin/systemctl start NetworkManager.service
%wheel ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop NetworkManager.service
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl start bluetooth.service
%video ALL=(ALL) NOPASSWD: /usr/bin/rfkill unblock bluetooth
%wheel ALL=(ALL) NOPASSWD: /usr/local/bin/gamescope-nm-start
%wheel ALL=(ALL) NOPASSWD: /usr/local/bin/gamescope-nm-stop
SUDOERS_SWITCH
)
  local switch_exit=$?

  if [[ $switch_exit -eq 0 ]]; then
    sudo chmod 0440 "$sudoers_session"
    info "Sudoers rules created successfully"
  else
    err "Failed to create sudoers file (exit code: $switch_exit)"
  fi

  info "Adding Hyprland keybind..."
  local hypr_bindings_conf="${user_home}/.config/hypr/bindings.conf"

  if [[ ! -f "$hypr_bindings_conf" ]]; then
    warn "bindings.conf not found at $hypr_bindings_conf - skipping keybind setup"
    warn "You can manually add: bindd = SUPER SHIFT, S, Gaming Mode, exec, /usr/local/bin/switch-to-gaming"
  else
    if grep -q "switch-to-gaming" "$hypr_bindings_conf" 2>/dev/null; then
      info "Gaming Mode keybind already exists in bindings.conf"
    else
      cat >> "$hypr_bindings_conf" << 'HYPR_GAMING'

bindd = SUPER SHIFT, S, Gaming Mode, exec, /usr/local/bin/switch-to-gaming
HYPR_GAMING
      info "Added Gaming Mode keybind to bindings.conf"
    fi
  fi

  info "Steam compatibility scripts provided by gamescope-session-steam-git"

  info "Verifying NetworkManager integration..."
  echo ""

  local nm_test_ok=true
  local iwd_was_active=false
  systemctl is-active --quiet iwd.service && iwd_was_active=true

  if ! systemctl is-active --quiet NetworkManager.service; then
    info "Testing NetworkManager startup..."
    if sudo systemctl start NetworkManager.service 2>/dev/null; then
      sleep 2
      if nmcli general status &>/dev/null; then
        info "NetworkManager started successfully"
        if nmcli general status 2>/dev/null | grep -qE "connected|connecting"; then
          info "NetworkManager can see network - Steam network access should work"
        else
          warn "NetworkManager running but shows disconnected"
          warn "This is expected if iwd/systemd-networkd manages your connection"
          info "Steam should still be able to use the network via D-Bus"
        fi
        sudo systemctl stop NetworkManager.service 2>/dev/null || true
        if $iwd_was_active; then
          info "Restoring iwd WiFi connection..."
          sudo systemctl restart iwd.service 2>/dev/null || true
          sleep 2
        fi
      else
        nm_test_ok=false
        err "NetworkManager started but nmcli not responding"
        sudo systemctl stop NetworkManager.service 2>/dev/null || true
        if $iwd_was_active; then
          sudo systemctl restart iwd.service 2>/dev/null || true
        fi
      fi
    else
      nm_test_ok=false
      err "Failed to start NetworkManager for testing"
    fi
  else
    info "NetworkManager already running - integration should work"
  fi

  echo ""
  echo "================================================================"
  echo "  SESSION SWITCHING CONFIGURED (ChimeraOS)"
  echo "================================================================"
  echo ""
  echo "  Usage:"
  echo "    - Press Super+Shift+S in Hyprland to switch to Gaming Mode"
  echo "    - Press Super+Shift+R in Gaming Mode to return to Hyprland"
  echo "    - (Steam's Power > Exit to Desktop also works as fallback)"
  echo ""
  echo "  ChimeraOS packages installed:"
  echo "    - gamescope-session-git (base session framework)"
  echo "    - gamescope-session-steam-git (Steam session)"
  echo ""
  echo "  Files created/modified:"
  echo "    - ~/.config/environment.d/gamescope-session-plus.conf"
  echo "    - /usr/local/bin/gamescope-session-nm-wrapper"
  echo "    - /usr/share/wayland-sessions/gamescope-session-steam-nm.desktop"
  echo "    - /usr/lib/os-session-select"
  echo "    - /usr/local/bin/switch-to-gaming"
  echo "    - /usr/local/bin/switch-to-desktop"
  echo "    - /usr/local/bin/gaming-keybind-monitor (Super+Shift+R)"
  echo "    - ~/.config/hypr/bindings.conf (keybind added)"
  echo ""
  echo "  NetworkManager integration (Steam network access):"
  echo "    - /usr/local/bin/gamescope-nm-start"
  echo "    - /usr/local/bin/gamescope-nm-stop"
  echo "    - /etc/polkit-1/rules.d/50-gamescope-networkmanager.rules"
  echo "    - /etc/sudoers.d/gaming-session-switch (NM rules added)"

  if [[ -f /etc/NetworkManager/conf.d/10-iwd-backend.conf ]]; then
    echo "    - /etc/NetworkManager/conf.d/10-iwd-backend.conf (iwd backend)"
  fi
  if [[ -f /etc/NetworkManager/conf.d/20-unmanaged-systemd.conf ]]; then
    echo "    - /etc/NetworkManager/conf.d/20-unmanaged-systemd.conf (systemd-networkd coexistence)"
  fi
  echo ""

  if [[ "$nm_test_ok" != "true" ]]; then
    echo "  WARNING: NetworkManager test failed!"
    echo "  Steam may not have network access in Gaming Mode."
    echo ""
    echo "  Troubleshooting:"
    echo "    1. Ensure NetworkManager is installed: pacman -S networkmanager"
    echo "    2. Check if iwd is running: systemctl status iwd"
    echo "    3. Try manually: sudo systemctl start NetworkManager && nmcli general"
    echo "    4. Check logs: journalctl -u NetworkManager -n 50"
    echo ""
  fi

  if command -v hyprctl >/dev/null 2>&1 && hyprctl monitors >/dev/null 2>&1; then
    hyprctl reload >/dev/null 2>&1 && info "Hyprland config reloaded" || true
  fi

  return 0
}

# Comprehensive verification — checks every file, permission, package, group,
# and service that Gaming Mode depends on. This is the --verify mode that
# users can run to diagnose problems without re-running the full installer.
#
# It checks:
#   - All installed files exist and have correct permissions
#   - Hyprland keybind is configured
#   - ChimeraOS AUR packages are installed
#   - Steam library mount script and udisks2 are ready
#   - python-evdev works and user is in the input group
#   - Gamescope session config exists
#   - User is in required groups (video, input, wheel)
#   - Service states (NM should be inactive, iwd should be active)
#   - Sudo permissions work without password
verify_installation() {
  echo ""
  echo "================================================================"
  echo "  GAMING MODE INSTALLATION VERIFICATION"
  echo "================================================================"
  echo ""

  local all_ok=true
  local missing_files=()
  local permission_issues=()

  declare -A expected_files=(
    ["/usr/local/bin/gamescope-session-nm-wrapper"]="755:ChimeraOS session with NM wrapper"
    ["/usr/local/lib/gamescope-nvidia/gamescope"]="755:NVIDIA gamescope wrapper (--force-composition)"
    ["/usr/local/bin/gaming-session-switch"]="755:Session switching helper (gaming/desktop)"
    ["/usr/lib/os-session-select"]="755:Steam Exit to Desktop handler"
    ["/usr/local/bin/switch-to-gaming"]="755:Hyprland to Gaming Mode switcher"
    ["/usr/local/bin/switch-to-desktop"]="755:Gaming Mode to Desktop switcher (Super+Shift+R)"
    ["/usr/local/bin/gaming-keybind-monitor"]="755:Keybind monitor for Super+Shift+R"
    ["/usr/local/bin/deckshift-portal-recovery"]="755:xdg-desktop-portal restart helper (post-Gaming-Mode)"
    ["/usr/local/bin/gamescope-nm-start"]="755:NetworkManager start script"
    ["/usr/local/bin/gamescope-nm-stop"]="755:NetworkManager stop script"
    ["/usr/local/bin/steam-library-mount"]="755:Steam library drive auto-mount script"
    ["/usr/bin/steamos-session-select"]="755:Steam compatibility (from AUR package)"
    ["/usr/bin/steamos-update"]="755:Steam compatibility (from AUR package)"
    ["/usr/bin/jupiter-biosupdate"]="755:Steam compatibility (from AUR package)"
    ["/usr/bin/steamos-select-branch"]="755:Steam compatibility (from AUR package)"
    ["/usr/share/wayland-sessions/gamescope-session-steam-nm.desktop"]="644:SDDM session entry"
    ["/usr/share/gamescope-session-plus/gamescope-session-plus"]="755:ChimeraOS session launcher (from AUR)"
    ["/etc/sddm.conf.d/zz-gaming-session.conf"]="644:SDDM session switching config"
    ["/etc/polkit-1/rules.d/50-gamescope-networkmanager.rules"]="644:Polkit NM rules"
    ["/etc/polkit-1/rules.d/50-udisks-gaming.rules"]="644:Polkit udisks2 rules (external drive mount)"
    ["/etc/sudoers.d/gaming-session-switch"]="440:Sudoers rules"
    ["/etc/NetworkManager/conf.d/10-iwd-backend.conf"]="644:NM iwd backend config (optional)"
    ["/etc/NetworkManager/conf.d/20-unmanaged-systemd.conf"]="644:NM systemd coexistence (optional)"
    ["/etc/udev/rules.d/99-gaming-performance.rules"]="644:Udev performance rules"
    ["/etc/sudoers.d/gaming-mode-sysctl"]="440:Performance sudoers"
    ["/etc/security/limits.d/99-gaming-memlock.conf"]="644:Memlock limits"
    ["/etc/pipewire/pipewire.conf.d/10-gaming-latency.conf"]="644:PipeWire low-latency"
    ["/etc/environment.d/99-shader-cache.conf"]="644:Shader cache config"
    ["/usr/local/bin/deckshift-settings"]="755:Gaming Mode settings TUI"
    ["/usr/share/applications/deckshift-settings.desktop"]="644:Walker launcher for settings TUI"
  )
  echo "  FILE STATUS:"
  echo "  ------------"
  echo ""

  for file in "${!expected_files[@]}"; do
    local expected_perm="${expected_files[$file]%%:*}"
    local description="${expected_files[$file]#*:}"
    local is_optional=false

    [[ "$description" == *"(optional)"* ]] && is_optional=true

    if sudo test -f "$file" 2>/dev/null; then
      local actual_perm
      actual_perm=$(sudo stat -c "%a" "$file" 2>/dev/null)

      if [[ "$actual_perm" == "$expected_perm" ]]; then
        printf "  ✓ %-55s [%s] OK\n" "$file" "$actual_perm"
      else
        printf "  ⚠ %-55s [%s] (expected %s)\n" "$file" "$actual_perm" "$expected_perm"
        permission_issues+=("$file: has $actual_perm, expected $expected_perm")
        all_ok=false
      fi
    else
      if $is_optional; then
        printf "  - %-55s [SKIPPED] %s\n" "$file" "(optional)"
      else
        printf "  ✗ %-55s [MISSING]\n" "$file"
        missing_files+=("$file: $description")
        all_ok=false
      fi
    fi
  done

  echo ""
  echo "  HYPRLAND KEYBIND:"
  echo "  -----------------"
  local hypr_bindings="$HOME/.config/hypr/bindings.conf"
  if [[ -f "$hypr_bindings" ]]; then
    if grep -q "switch-to-gaming" "$hypr_bindings" 2>/dev/null; then
      echo "  ✓ Gaming Mode keybind (Super+Shift+S) configured"
    else
      echo "  ✗ Gaming Mode keybind NOT found in bindings.conf"
      all_ok=false
    fi
  else
    echo "  ⚠ bindings.conf not found - keybind needs manual setup"
  fi

  echo ""
  echo "  CHIMERAOS PACKAGES:"
  echo "  -------------------"
  if check_package "gamescope-session-git" || check_package "gamescope-session"; then
    echo "  ✓ gamescope-session installed"
  else
    echo "  ✗ gamescope-session NOT installed"
    all_ok=false
  fi
  if check_package "gamescope-session-steam-git" || check_package "gamescope-session-steam"; then
    echo "  ✓ gamescope-session-steam installed"
  else
    echo "  ✗ gamescope-session-steam NOT installed"
    all_ok=false
  fi

  echo ""
  echo "  STEAM LIBRARY DRIVE SUPPORT:"
  echo "  -----------------------------"
  if [[ -x "/usr/local/bin/steam-library-mount" ]]; then
    echo "  ✓ steam-library-mount script installed"
  else
    echo "  ✗ steam-library-mount NOT found - external Steam libraries will not auto-mount"
    all_ok=false
  fi
  if check_package "udisks2"; then
    echo "  ✓ udisks2 installed (mount backend)"
  else
    echo "  ✗ udisks2 NOT installed"
    all_ok=false
  fi
  if sudo test -f "/etc/polkit-1/rules.d/50-udisks-gaming.rules" 2>/dev/null; then
    echo "  ✓ udisks2 polkit rules configured"
  else
    echo "  ✗ udisks2 polkit rules NOT found"
    all_ok=false
  fi

  echo ""
  echo "  KEYBIND MONITOR (Super+Shift+R):"
  echo "  ---------------------------------"
  local keybind_ok=true

  if check_package "python-evdev"; then
    echo "  ✓ python-evdev installed"
  else
    echo "  ✗ python-evdev NOT installed"
    keybind_ok=false
    all_ok=false
  fi

  if python3 -c "import evdev" 2>/dev/null; then
    echo "  ✓ python-evdev importable"
  else
    echo "  ✗ python-evdev cannot be imported"
    keybind_ok=false
    all_ok=false
  fi

  if groups 2>/dev/null | grep -qw input; then
    echo "  ✓ User in 'input' group"
  else
    echo "  ✗ User NOT in 'input' group (required for keybind)"
    keybind_ok=false
    all_ok=false
  fi

  if ls /dev/input/event* >/dev/null 2>&1; then
    local test_device=$(ls /dev/input/event* 2>/dev/null | head -1)
    if [[ -r "$test_device" ]]; then
      echo "  ✓ Can read input devices"
    else
      echo "  ✗ Cannot read $test_device (permission denied)"
      echo "    (May need to log out/in after adding to input group)"
      keybind_ok=false
      all_ok=false
    fi
  else
    echo "  ⚠ No /dev/input/event* devices found"
  fi

  if $keybind_ok; then
    echo "  → Super+Shift+R keybind should work"
  else
    echo "  → Super+Shift+R keybind will NOT work (use Steam > Power > Exit to Desktop)"
  fi

  echo ""
  echo "  USER CONFIG:"
  echo "  ------------"
  local user_conf="$HOME/.config/environment.d/gamescope-session-plus.conf"
  if [[ -f "$user_conf" ]]; then
    echo "  ✓ gamescope-session-plus.conf exists"
  else
    echo "  ✗ gamescope-session-plus.conf NOT found"
    all_ok=false
  fi

  echo ""
  echo "  USER GROUPS:"
  echo "  ------------"
  local user_groups
  user_groups=$(groups 2>/dev/null)
  for grp in video input wheel; do
    if echo "$user_groups" | grep -qw "$grp"; then
      printf "  ✓ User is in '%s' group\n" "$grp"
    else
      printf "  ✗ User is NOT in '%s' group\n" "$grp"
      all_ok=false
    fi
  done

  echo ""
  echo "  SERVICE STATUS:"
  echo "  ---------------"
  echo "  NetworkManager: $(systemctl is-active NetworkManager.service 2>/dev/null || echo 'inactive') (should be inactive until gaming mode)"
  echo "  iwd:            $(systemctl is-active iwd.service 2>/dev/null || echo 'inactive')"
  echo "  systemd-networkd: $(systemctl is-active systemd-networkd.service 2>/dev/null || echo 'inactive')"
  echo "  polkit:         $(systemctl is-active polkit.service 2>/dev/null || echo 'inactive')"

  echo ""
  echo "  SUDO PERMISSIONS TEST:"
  echo "  ----------------------"
  if sudo -n true 2>/dev/null; then
    echo "  ✓ sudo -n works (passwordless sudo available)"
    if sudo -n -l /usr/local/bin/gamescope-nm-start &>/dev/null; then
      echo "  ✓ Can run gamescope-nm-start without password"
    else
      echo "  ✗ Cannot run gamescope-nm-start without password"
      all_ok=false
    fi
  else
    echo "  ⚠ sudo -n test skipped (requires recent sudo auth)"
    echo "    Run: sudo -v && sudo -n -l /usr/local/bin/gamescope-nm-start"
  fi

  echo ""
  echo "================================================================"
  if $all_ok; then
    echo "  ✓ ALL CHECKS PASSED - Gaming Mode should work correctly"
  else
    echo "  ⚠ SOME ISSUES DETECTED"
    echo ""
    if ((${#missing_files[@]})); then
      echo "  Missing files (${#missing_files[@]}):"
      for f in "${missing_files[@]}"; do
        echo "    - $f"
      done
    fi
    if ((${#permission_issues[@]})); then
      echo ""
      echo "  Permission issues (${#permission_issues[@]}):"
      for p in "${permission_issues[@]}"; do
        echo "    - $p"
      done
    fi
    echo ""
    echo "  Re-run the installer to fix these issues."
  fi
  echo "================================================================"
  echo ""

  $all_ok && return 0 || return 1
}

# Main orchestrator — runs the full installation process in order.
# Each step builds on the previous one:
#   1. Authenticate sudo (and clear cached credentials first for a fresh prompt)
#   2. Validate we're on an Omarchy system
#   3. Install Steam dependencies and GPU drivers
#   4. Configure NVIDIA kernel parameters (if applicable)
#   5. Set NVIDIA environment variables (if applicable)
#   6. Install script requirements and performance permissions
#   7. Set up session switching (the big one — all the scripts and configs)
#   8. Optionally install Xbox Bluetooth controller support (xpadneo)
#   9. Install the Gaming Mode settings TUI + Walker launcher
#  10. Prompt for reboot/relogin if needed
#  11. Optionally run verification to confirm everything worked
execute_setup() {
  sudo -k
  sudo -v || die "sudo authentication required"

  validate_environment

  echo ""
  echo "================================================================"
  echo "  DECKSHIFT INSTALLER v${DECKSHIFT_VERSION}"
  echo "  Dependencies & GPU Configuration"
  echo "================================================================"
  echo ""

  check_steam_dependencies
  check_nvidia_kernel_params
  install_nvidia_deckmode_env
  setup_requirements
  setup_session_switching
  setup_xbox_controllers
  setup_settings_tui

  if [ "$NEEDS_REBOOT" -eq 1 ]; then
    echo ""
    echo "================================================================"
    echo "  IMPORTANT: REBOOT REQUIRED"
    echo "================================================================"
    echo ""
    echo "  Bootloader configuration has been updated (nvidia-drm.modeset=1)."
    echo "  You MUST reboot for the kernel parameter to take effect."
    echo ""
    if [ "$NEEDS_RELOGIN" -eq 1 ]; then
      echo "  Additionally, user groups were updated (video/input/wheel)."
    fi
    echo ""
    read -p "Reboot now? [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      info "Rebooting..."
      sleep 2
      systemctl reboot
    else
      echo ""
      echo "  Remember to reboot before continuing!"
      echo ""
    fi
  elif [ "$NEEDS_RELOGIN" -eq 1 ]; then
    echo ""
    echo "================================================================"
    echo "  IMPORTANT: LOG OUT REQUIRED"
    echo "================================================================"
    echo ""
    echo "  User groups have been updated. You MUST log out and log back in"
    echo "  for the changes to take effect."
    echo ""
    read -r -p "Press Enter to exit (remember to log out)..."
  else
    echo ""
    echo "================================================================"
    echo "  SETUP COMPLETE"
    echo "================================================================"
    echo ""
    echo "  Dependencies, GPU configuration, and session switching are ready."
    echo ""
    echo "  To switch to Gaming Mode: Press Super+Shift+S"
    echo "  To return to Desktop:     Press Super+Shift+R"
    echo ""
  fi

  echo ""
  read -p "Run installation verification? [Y/n]: " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    verify_installation
  fi
}

show_help() {
  echo "DeckShift Installer v${DECKSHIFT_VERSION}"
  echo ""
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --help, -h      Show this help message"
  echo "  --verify, -v    Run verification only (check all files and permissions)"
  echo "  --version       Show version number"
  echo ""
  echo "Without options, runs the full installation/setup process."
  echo ""
}

# Command-line argument parsing — determines what mode to run in.
# With no arguments, runs the full installation. Otherwise:
#   --help/-h:    Show usage information
#   --verify/-v:  Only check if everything is installed correctly
#   --version:    Print version number
case "${1:-}" in
  --help|-h)
    show_help
    exit 0
    ;;
  --verify|-v)
    echo "Running verification only..."
    verify_installation
    exit $?
    ;;
  --version)
    echo "DeckShift Installer v${DECKSHIFT_VERSION}"
    exit 0
    ;;
  "")
    execute_setup
    ;;
  *)
    echo "Unknown option: $1"
    echo "Use --help for usage information."
    exit 1
    ;;
esac

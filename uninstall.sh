#!/usr/bin/env bash
#
# DeckShift uninstaller — removes everything ./deckshift.sh installed and puts
# the system back the way it was.
#
# Scope, deliberately:
#   removed by default  — every file DeckShift itself creates, its Hyprland
#                         keybinds and autostart lines, the control-panel
#                         plugin and its shell.json wiring, its sudoers/polkit/
#                         udev/limits drop-ins, and its per-user state
#   opt-in              — third-party packages (--remove-packages) and the GRUB
#                         nvidia-drm.modeset=1 kernel parameter (--revert-grub);
#                         both are commonly wanted independently of DeckShift
#   never touched       — files owned by the AUR packages (steamos-* helpers,
#                         gamescope-session-plus), and your group memberships
#                         (removing yourself from `wheel` would cost you sudo)
#
# Usage:
#   ./uninstall.sh                    remove DeckShift, keep packages and GRUB
#   ./uninstall.sh --dry-run          print what would happen, change nothing
#   ./uninstall.sh --yes              no prompts
#   ./uninstall.sh --remove-packages  also remove the AUR gamescope-session pkgs
#   ./uninstall.sh --revert-grub      also strip nvidia-drm.modeset=1 from GRUB
#
set -uo pipefail

DRY_RUN=0
ASSUME_YES=0
REMOVE_PACKAGES=0
REVERT_GRUB=0

PLUGIN_ID="nosignal.deckshift"

for arg in "$@"; do
  case "$arg" in
    --dry-run)         DRY_RUN=1 ;;
    --yes|-y)          ASSUME_YES=1 ;;
    --remove-packages) REMOVE_PACKAGES=1 ;;
    --revert-grub)     REVERT_GRUB=1 ;;
    -h|--help)         sed -n '2,26p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

C_INFO=$'\033[1;34m'; C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'
C_ERR=$'\033[1;31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
info() { printf '%s==>%s %s\n' "$C_INFO" "$C_OFF" "$*"; }
# Silent during a dry run: the "would ..." lines already say what happens, and
# an "ok removed X" after them would read as if it had actually been done.
ok()   { (( DRY_RUN )) && return 0; printf '%s  ok%s %s\n' "$C_OK" "$C_OFF" "$*"; }
skip() { printf '%s   - %s%s\n' "$C_DIM" "$*" "$C_OFF"; }
warn() { printf '%s  !!%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
die()  { printf '%serror:%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

REMOVED=0
CHANGED=0

run() {
  if (( DRY_RUN )); then
    printf '%s  would run:%s %s\n' "$C_DIM" "$C_OFF" "$*"
    return 0
  fi
  "$@"
}

confirm() {
  (( ASSUME_YES )) && return 0
  (( DRY_RUN ))    && return 0
  local reply
  read -r -p "  $1 [y/N]: " reply
  [[ $reply =~ ^[Yy]$ ]]
}

# Existence test that also works for root-only directories such as
# /etc/sudoers.d and /etc/polkit-1/rules.d.
#
# Echoes yes / no / unknown. "unknown" happens only in a dry run whose sudo
# credentials are not cached and whose parent directory the user cannot read —
# claiming "not present" there would be a lie, and this script's whole value is
# that you can trust its dry run.
path_state() {
  if [[ -e $1 || -L $1 ]]; then echo yes; return; fi
  if [[ -r $(dirname "$1") ]]; then echo no; return; fi
  if sudo -n true 2>/dev/null; then
    sudo -n test -e "$1" 2>/dev/null && echo yes || echo no
  else
    echo unknown
  fi
}

# Remove a path only if it exists; report either way so the run is auditable.
drop() {
  local path="$1" what="${2:-}"
  local label="$path${what:+  ($what)}"
  case "$(path_state "$path")" in
    yes)
      if (( DRY_RUN )); then
        printf '%s  would remove %s%s\n' "$C_DIM" "$label" "$C_OFF"
      else
        sudo rm -rf -- "$path" && { ok "removed $label"; (( REMOVED++ )); }
      fi ;;
    no)
      skip "not present: $path" ;;
    unknown)
      printf '%s  would remove if present: %s  (needs sudo to check)%s\n' \
        "$C_DIM" "$path" "$C_OFF" ;;
  esac
}

drop_user() {
  local path="$1" what="${2:-}"
  local label="$path${what:+  ($what)}"
  if [[ -e $path || -L $path ]]; then
    if (( DRY_RUN )); then
      printf '%s  would remove %s%s\n' "$C_DIM" "$label" "$C_OFF"
    else
      rm -rf -- "$path" && { ok "removed $label"; (( REMOVED++ )); }
    fi
  else
    skip "not present: $path"
  fi
}

# --------------------------------------------------------------- preflight ---

[[ $EUID -eq 0 ]] && die "run this as your normal user, not root — it uses sudo where needed"

USER_HOME="$HOME"
[[ -d $USER_HOME ]] || die "cannot resolve home directory"

if [[ -f /tmp/.gaming-session-active ]] || pgrep -x gamescope >/dev/null 2>&1; then
  die "you appear to be inside Gaming Mode. Return to the desktop first (Super+Shift+R), then re-run."
fi

echo
if (( DRY_RUN )); then
  info "DRY RUN — nothing will be changed"
else
  info "This removes DeckShift from your system."
  (( REMOVE_PACKAGES )) && warn "--remove-packages: the AUR gamescope-session packages will also be removed"
  (( REVERT_GRUB ))     && warn "--revert-grub: nvidia-drm.modeset=1 will be stripped and GRUB regenerated"
  confirm "Continue?" || { echo "  aborted"; exit 0; }
fi

if (( ! DRY_RUN )); then
  sudo -v || die "sudo is required"
fi

# ------------------------------------------------- 1. stop what is running ---

info "Stopping DeckShift processes"
for p in gaming-keybind-monitor steam-library-mount; do
  if pgrep -f "$p" >/dev/null 2>&1; then
    run sudo pkill -f "$p" && ok "stopped $p"
  else
    skip "not running: $p"
  fi
done

# --------------------------------- 2. put SDDM back on the desktop session ---
#
# Done before the config is deleted. If the stored session is still the gaming
# one and something re-reads it mid-uninstall, the next login would drop into a
# session whose scripts are about to disappear.

SDDM_CONF=/etc/sddm.conf.d/zz-gaming-session.conf
info "Restoring the SDDM session"
if [[ "$(path_state "$SDDM_CONF")" != no ]]; then
  if sudo -n grep -q '^Session=gamescope' "$SDDM_CONF" 2>/dev/null; then
    run sudo sed -i 's/^Session=.*/Session=hyprland-uwsm/' "$SDDM_CONF" \
      && ok "session set back to hyprland-uwsm before removal"
  else
    skip "already on a desktop session"
  fi
else
  skip "not present: $SDDM_CONF"
fi

# ------------------------------------------------ 3. DeckShift's own files ---

info "Removing DeckShift scripts"
for f in \
  /usr/local/bin/switch-to-gaming \
  /usr/local/bin/switch-to-desktop \
  /usr/local/bin/gamescope-session-nm-wrapper \
  /usr/local/bin/gaming-session-switch \
  /usr/local/bin/gaming-keybind-monitor \
  /usr/local/bin/gamescope-nm-start \
  /usr/local/bin/gamescope-nm-stop \
  /usr/local/bin/steam-library-mount \
  /usr/local/bin/deckshift-portal-recovery \
  /usr/local/bin/deckshift-settings \
  /usr/share/applications/deckshift-settings.desktop \
  /usr/lib/os-session-select \
  /usr/local/lib/gamescope-nvidia
do
  drop "$f"
done

info "Removing the SDDM session entry"
drop /usr/share/wayland-sessions/gamescope-session-steam-nm.desktop "DeckShift's own entry"
skip "leaving gamescope-session-steam.desktop / gamescope-session.desktop — owned by the AUR packages"

info "Removing permission and tuning drop-ins"
for f in \
  /etc/sudoers.d/gaming-session-switch \
  /etc/sudoers.d/gaming-mode-sysctl \
  /etc/polkit-1/rules.d/50-gamescope-networkmanager.rules \
  /etc/polkit-1/rules.d/50-udisks-gaming.rules \
  /etc/udev/rules.d/99-gaming-performance.rules \
  /etc/security/limits.d/99-gaming-memlock.conf \
  /usr/share/libalpm/hooks/deckshift-gamescope-cap.hook \
  /etc/modprobe.d/blacklist-xpad.conf \
  /etc/modules-load.d/xpadneo.conf
do
  drop "$f"
done

info "Removing system configs"
for f in \
  "$SDDM_CONF" \
  /etc/environment.d/99-shader-cache.conf \
  /etc/environment.d/90-nvidia-gamescope.conf \
  /etc/pipewire/pipewire.conf.d/10-gaming-latency.conf \
  /etc/NetworkManager/conf.d/10-iwd-backend.conf \
  /etc/NetworkManager/conf.d/20-unmanaged-systemd.conf
do
  drop "$f"
done

# --------------------------------- 4. revert in-place changes to other files ---

info "Reverting in-place modifications"

# cap_sys_nice on the gamescope binary (granted for performance mode).
if command -v gamescope >/dev/null 2>&1; then
  GAMESCOPE_BIN=$(command -v gamescope)
  if getcap "$GAMESCOPE_BIN" 2>/dev/null | grep -q cap_sys_nice; then
    run sudo setcap -r "$GAMESCOPE_BIN" && { ok "dropped cap_sys_nice from $GAMESCOPE_BIN"; (( CHANGED++ )); }
  else
    skip "no cap_sys_nice on gamescope"
  fi
else
  skip "gamescope not installed"
fi

# gamescope-session-plus is a package-owned file that DeckShift patches in
# place. Reverting means restoring the packaged copy, so reinstall its owner.
GSP=/usr/share/gamescope-session-plus/gamescope-session-plus
if [[ -f $GSP ]] && grep -q DECKSHIFT-NESTED-REFRESH-FALLBACK "$GSP" 2>/dev/null; then
  GSP_OWNER=$(pacman -Qoq "$GSP" 2>/dev/null | head -1)
  if [[ -n $GSP_OWNER ]]; then
    warn "$GSP carries DeckShift's refresh-rate patch"
    if confirm "Restore the packaged version by reinstalling $GSP_OWNER?"; then
      if command -v yay >/dev/null 2>&1; then
        run yay -S --noconfirm "$GSP_OWNER" && { ok "reinstalled $GSP_OWNER"; (( CHANGED++ )); }
      else
        run sudo pacman -S --noconfirm "$GSP_OWNER" && { ok "reinstalled $GSP_OWNER"; (( CHANGED++ )); }
      fi
    else
      warn "left patched — to revert later: yay -S $GSP_OWNER"
    fi
  else
    warn "$GSP is patched but owned by no package; leaving it alone"
  fi
else
  skip "gamescope-session-plus not patched"
fi

# ------------------------------------------------------- 5. user-level bits ---

info "Removing user files"
drop_user "$USER_HOME/.config/environment.d/gamescope-session-plus.conf"
drop_user "$USER_HOME/.config/environment.d/90-fcitx-wayland.conf"
drop_user "$USER_HOME/.cache/deckshift"
drop_user "$USER_HOME/.config/omarchy/plugins/$PLUGIN_ID" "control panel plugin"
for m in /tmp/.gaming-session-active /tmp/.deckshift-just-returned; do
  [[ -e $m ]] && drop_user "$m" "stale marker"
done

# shell.json — prefer the backup the installer took, fall back to a jq surgery.
SHELL_JSON="$USER_HOME/.config/omarchy/shell.json"
SHELL_BAK="${SHELL_JSON}.bak.deckshift"
info "Unwiring the control panel from omarchy-shell"
if [[ -f $SHELL_BAK ]]; then
  if confirm "Restore $SHELL_JSON from the installer's backup?"; then
    run cp "$SHELL_BAK" "$SHELL_JSON" && { ok "restored from .bak.deckshift"; (( CHANGED++ )); }
    run rm -f "$SHELL_BAK"
  else
    skip "backup left in place at $SHELL_BAK"
  fi
elif [[ -f $SHELL_JSON ]] && command -v jq >/dev/null 2>&1; then
  if jq -e --arg id "$PLUGIN_ID" \
       '([.plugins[]?.id] | index($id)) != null or ([.bar.layout[]?[]?.id] | index($id)) != null' \
       "$SHELL_JSON" >/dev/null 2>&1; then
    if (( DRY_RUN )); then
      printf '%s  would strip %s from %s%s\n' "$C_DIM" "$PLUGIN_ID" "$SHELL_JSON" "$C_OFF"
    else
      tmp=$(mktemp)
      if jq --arg id "$PLUGIN_ID" '
            (.plugins? |= (map(select(.id != $id)) // []))
            | (.bar.layout? |= with_entries(.value |= map(select(.id != $id))))
          ' "$SHELL_JSON" > "$tmp" && [[ -s $tmp ]]; then
        cp "$SHELL_JSON" "${SHELL_JSON}.pre-uninstall.bak"
        mv "$tmp" "$SHELL_JSON"
        ok "stripped $PLUGIN_ID (previous file kept as ${SHELL_JSON##*/}.pre-uninstall.bak)"
        (( CHANGED++ ))
      else
        rm -f "$tmp"
        warn "jq edit failed — leaving $SHELL_JSON untouched"
      fi
    fi
  else
    skip "$PLUGIN_ID not referenced in shell.json"
  fi
elif [[ -f $SHELL_JSON ]]; then
  warn "jq not installed — remove the \"$PLUGIN_ID\" entries from $SHELL_JSON by hand"
else
  skip "no shell.json"
fi

# Hyprland keybinds and autostart lines, Lua and legacy .conf alike.
info "Stripping Hyprland config lines"
for f in \
  "$USER_HOME/.config/hypr/bindings.lua" \
  "$USER_HOME/.config/hypr/bindings.conf" \
  "$USER_HOME/.config/hypr/autostart.lua" \
  "$USER_HOME/.config/hypr/autostart.conf" \
  "$USER_HOME/.config/hypr/hyprland.conf"
do
  [[ -f $f ]] || { skip "not present: $f"; continue; }

  out=$(DRY_RUN=$DRY_RUN PLUGIN_ID=$PLUGIN_ID python3 - "$f" <<'PY'
import os, re, sys

path = sys.argv[1]
plugin_id = os.environ["PLUGIN_ID"]
dry = os.environ.get("DRY_RUN") == "1"

lines = open(path).read().splitlines(keepends=True)

# Lines DeckShift is responsible for, matched by payload rather than by exact
# text: an upgraded install can carry launch_on_start or exec_on_start, and
# users reformat these by hand.
#
# The (?!-) after switch-to-gaming matters. switch-to-gaming-nosession is a
# different tool that DeckShift neither ships nor knows about, and a bare
# prefix match would strip its keybind along with ours.
payload = re.compile(
    r"switch-to-gaming(?!-)"
    r"|deckshift-portal-recovery"
    r"|" + re.escape(plugin_id) +
    r"|FCITX_NO_WAYLAND_DIAGNOSE"
)
gaming_bind = re.compile(r"switch-to-gaming(?!-)")
# Comment lines DeckShift appended above its own blocks.
own_comment = re.compile(r"^\s*(--|#)\s*(DeckShift|Silence fcitx5 Wayland diagnose)", re.I)
# The unbind only exists to free the key for the Gaming Mode bind.
unbind = re.compile(r'^\s*hl\.unbind\(\s*"SUPER \+ SHIFT \+ S"\s*\)\s*$')
legacy_unbind = re.compile(r'^\s*unbind\s*=\s*SUPER\s+SHIFT\s*,\s*S\s*$')

drop = [False] * len(lines)
for i, line in enumerate(lines):
    if payload.search(line):
        drop[i] = True

# An unbind counts as ours only when a dropped Gaming Mode bind follows within
# a couple of lines; a hand-written unbind elsewhere is left alone.
for i, line in enumerate(lines):
    if unbind.match(line) or legacy_unbind.match(line):
        if any(drop[j] and gaming_bind.search(lines[j])
               for j in range(i + 1, min(i + 4, len(lines)))):
            drop[i] = True

# Own comments directly above a dropped line go too.
for i in range(len(lines) - 1):
    if own_comment.match(lines[i]):
        j = i + 1
        while j < len(lines) and lines[j].strip() == "":
            j += 1
        if j < len(lines) and drop[j]:
            drop[i] = True

if not any(drop):
    print("CLEAN")
    sys.exit(0)

kept = [l for l, d in zip(lines, drop) if not d]
# Collapse the blank-line runs the removals leave behind.
collapsed, blanks = [], 0
for l in kept:
    if l.strip() == "":
        blanks += 1
        if blanks > 1:
            continue
    else:
        blanks = 0
    collapsed.append(l)
while collapsed and collapsed[-1].strip() == "":
    collapsed.pop()
text = "".join(collapsed)
if text and not text.endswith("\n"):
    text += "\n"

if not dry:
    with open(path + ".pre-uninstall.bak", "w") as f:
        f.writelines(lines)
    with open(path, "w") as f:
        f.write(text)

print("STRIPPED %d" % sum(drop))
PY
  ) || { warn "could not process $f"; continue; }

  case "$out" in
    CLEAN)      skip "nothing of ours in ${f##*/}" ;;
    STRIPPED*)  n=${out#STRIPPED }
                if (( DRY_RUN )); then
                  printf '%s  would strip %s line(s) from %s%s\n' "$C_DIM" "$n" "$f" "$C_OFF"
                else
                  ok "stripped $n line(s) from ${f##*/} (backup: ${f##*/}.pre-uninstall.bak)"
                  (( CHANGED++ ))
                fi ;;
  esac
done

# ------------------------------------------------------- 6. optional extras ---

if (( REVERT_GRUB )); then
  info "Reverting the GRUB kernel parameter"
  if sudo -n grep -q 'nvidia-drm.modeset=1' /etc/default/grub 2>/dev/null; then
    run sudo cp /etc/default/grub "/etc/default/grub.pre-uninstall.$(date +%Y%m%d%H%M%S).bak"
    run sudo sed -i 's/ *nvidia-drm\.modeset=1//g' /etc/default/grub
    if (( ! DRY_RUN )); then
      ok "stripped nvidia-drm.modeset=1"
      info "Regenerating /boot/grub/grub.cfg"
      sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 \
        && ok "GRUB config regenerated" \
        || warn "grub-mkconfig failed — run it yourself before rebooting"
      (( CHANGED++ ))
    fi
  else
    skip "nvidia-drm.modeset=1 not in /etc/default/grub"
  fi
else
  if sudo -n grep -q 'nvidia-drm.modeset=1' /etc/default/grub 2>/dev/null; then
    skip "keeping nvidia-drm.modeset=1 in GRUB (use --revert-grub to strip it)"
  fi
fi

if (( REMOVE_PACKAGES )); then
  info "Removing third-party packages"
  pkgs=()
  for p in gamescope-session-steam-git gamescope-session-git gamescope-session-steam gamescope-session; do
    pacman -Qq "$p" >/dev/null 2>&1 && pkgs+=("$p")
  done
  if (( ${#pkgs[@]} )); then
    warn "about to remove: ${pkgs[*]}"
    if confirm "Remove these packages?"; then
      run sudo pacman -Rns --noconfirm "${pkgs[@]}" && { ok "packages removed"; (( CHANGED++ )); }
    else
      skip "packages kept"
    fi
  else
    skip "no gamescope-session packages installed"
  fi
  skip "gamescope, mangohud, xpadneo-dkms and friends are left alone — they are useful on their own"
else
  skip "keeping installed packages (use --remove-packages to drop the gamescope-session ones)"
fi

# ------------------------------------------------------------- 7. reload ------

info "Reloading system state"
run sudo systemctl daemon-reload
if systemctl is-active --quiet polkit 2>/dev/null; then
  run sudo systemctl restart polkit && ok "polkit restarted"
fi
run sudo udevadm control --reload-rules && ok "udev rules reloaded"
if command -v omarchy-restart-shell >/dev/null 2>&1 && [[ -n ${WAYLAND_DISPLAY:-} ]]; then
  run omarchy-restart-shell >/dev/null 2>&1 && ok "omarchy-shell restarted"
fi

# ------------------------------------------------------------- 8. summary -----

echo
if (( DRY_RUN )); then
  info "Dry run complete — nothing was changed"
  exit 0
fi

info "DeckShift removed — $REMOVED path(s) deleted, $CHANGED file(s)/setting(s) reverted"
cat <<EOM

Left alone on purpose:
  · your group memberships (video / input / wheel) — dropping wheel would
    cost you sudo, and you may have been in these before installing
  · packages such as gamescope, mangohud and xpadneo-dkms
  · any /etc/default/grub.backup.* the installer wrote
  · comments you wrote yourself next to a removed keybind — only DeckShift's
    own comment lines are stripped, so a stray note may be left behind

Backups this run created end in .pre-uninstall.bak — delete them once you have
checked the results.

Log out and back in (or reboot) to clear the environment DeckShift set up.
EOM

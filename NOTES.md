# DeckShift — maintainer notes

Working notes for future development sessions. User-facing docs live in README.md.

## Current state (2026-08-14)

- **v0.2.0 built; the end-to-end Launch test is the last gate before release.**
  The Omarchy 4 control-panel work was done in a temporary remote-less working
  clone and has now been merged back into this repo.
- The change: the gum settings TUI (`bin/deckshift-settings`,
  `applications/*.desktop`) is deleted and replaced by
  `plugins/nosignal.deckshift/` — an omarchy-shell (Quickshell) plugin with a
  bar icon and a panel that both configures Gaming Mode and launches it.
- Verified on this box (Omarchy 4, RTX 5060 Ti + AMD Raphael iGPU): panel opens,
  reads real monitor/GPU/conf state, buffered edit → Save writes the conf, launch
  confirm appears and cancels cleanly. The Launch path itself (execDetached →
  switch-to-gaming) is **not yet exercised end to end** — see open items.
- Note: the previous NOTES said the dev box was an "AMD RX 9060 XT". `lspci` on
  this machine reports an NVIDIA RTX 5060 Ti plus an AMD Raphael iGPU. Trust
  lspci.

## Omarchy 4 facts that shape this codebase

Discovered during the 2026-07-27 compatibility audit and the 2026-07-30 panel
work; verify against a live system before assuming they still hold.

1. **Hyprland runs on Omarchy's Lua config provider** — `hyprctl systeminfo`
   reports `configProvider: lua`. Every `~/.config/hypr/*.conf` file
   (bindings.conf, autostart.conf, windows.conf, ...) is **completely ignored**,
   even though `hyprland.conf` still contains `source =` lines for them.
   Proof method: a bind present only in bindings.conf does not appear in
   `hyprctl binds -j`.
2. **User override files are Lua**: `~/.config/hypr/bindings.lua`,
   `autostart.lua`, etc., loaded after Omarchy's defaults. API (defined in
   `~/.local/share/omarchy/default/hypr/helpers.lua`):
   - `o.bind("SUPER + SHIFT + S", "Description", "command")`
   - `hl.unbind("SUPER + SHIFT + S")` — required before rebinding a combo the
     Omarchy defaults claim; duplicate Hyprland binds BOTH fire. SUPER+ALT+G
     (the panel toggle) is unclaimed, so it needs no unbind.
   - `o.launch_on_start("command")` — exec-once equivalent (wraps the command
     with `o.launch()`, i.e. uwsm-app).
3. **Walker/elephant are gone**: `omarchy-restart-walker` and `elephant` no
   longer exist. The Quickshell-based omarchy-shell owns the app menu,
   notifications, and clipboard. `omarchy-restart-shell` exists if a shell
   bounce is ever needed — and it IS needed after changing panel QML.
4. **Still present and safe to depend on**: `omarchy-pkg-add`,
   `omarchy-hw-nvidia-gsp` / `-without-gsp`, `omarchy-install-gaming-steam`,
   `uwsm-app`, `xdg-terminal-exec`.

## Shell-plugin facts (learned the hard way, 2026-07-30)

1. **`omarchy plugin rescan` does NOT reload edited QML.** It picks up new
   plugin *folders*, but an already-loaded Panel.qml stays cached — you will
   test your old code and believe your fix failed. Use `omarchy-restart-shell`.
   Sanity check: change a visible string and confirm it rendered.
2. **`native` is a reserved word in QML's JS dialect.** Using it as a local
   variable makes the whole file fail to parse, and both `qmllint` and
   `qmlformat` report this as a bare non-zero exit with **no message**. If a
   QML file fails to parse with no diagnostic, bisect for reserved words.
3. **Never run `qmlformat -i` on the panel.** It hoists every section comment
   to the top of the root Item and reindents to 4 spaces, away from the sibling
   nosignal.* plugins' style. Use it read-only as a parse check
   (`qmlformat file.qml >/dev/null; echo $?`).
4. **A key handler must be an ANCESTOR of focusable controls, not a sibling.**
   Unhandled keys propagate up the *focused item's* parent chain only. The
   panel's first draft had `keyCatcher` as a sibling of the content Column, so
   the moment Tab moved focus onto a Dropdown trigger, `s`/`r`/`g` stopped
   working — silently, while the Save button still looked live. It now wraps the
   content with `Keys.priority: Keys.AfterItem` so dropdowns still own their own
   Tab/arrow/Enter handling.
5. **`omarchy plugin enable` is not enough for a panel.** It appends the bar
   widget but does not add the `plugins[]` entry, and without that entry every
   summon silently no-ops. The installer edits shell.json with jq directly
   (also because `enable` needs a *running* shell over IPC, which an installer
   run from a tty may not have).
6. Plugins are per-user: `~/.config/omarchy/plugins` is the only directory
   scanned for third-party plugins. Nothing goes in /usr/share.
7. Entering Gaming Mode destroys the shell, so the launch must use
   `Quickshell.execDetached` — an attached `Process` dies with the panel. Same
   reasoning as the plugin-manager's "panelish" toggles.

## Conventions

- **Omarchy-only, not distro-portable** — depend on `omarchy-*` helpers freely;
  no non-Omarchy fallbacks. (Pre/post-Omarchy-4 *version* branching is fine and
  used for the bindings/autostart writers.)
- Lua-first, `.conf` fallback: every Hyprland config write site checks for the
  `.lua` override file first, falls back to the legacy `.conf`, warns if
  neither exists. Keep new write sites consistent with this.
- All config writes are idempotent (grep-before-append, or jq `if any(...)`).
- Panel QML follows the style of the sibling `nosignal.*` shell plugins
  (2-space indent, `[menu]` theme tokens, one-shot fetch on open, no polling).
- Release flow: bump `DECKSHIFT_VERSION`, README header + changelog entry,
  commit `vX.Y.Z — summary`, annotated tag, `git push forgejo master &&
  git push forgejo vX.Y.Z` (covers both remotes).

## Testing checklist for future changes

- `bash -n deckshift.sh` + `shellcheck -S warning` (4 pre-existing SC2034s are
  known noise; SC2155/SC1090 too).
- QML: `qmlformat Panel.qml >/dev/null; echo $?` (parse) and
  `qmllint -I ~/.local/share/omarchy/shell Panel.qml` (resolve), plus
  `omarchy plugin validate plugins/nosignal.deckshift`.
- `./deckshift.sh --verify` on the dev box.
- After changing panel QML: `omarchy-restart-shell`, then confirm a visibly
  changed string actually rendered before trusting any behaviour test.
- After touching keybind/autostart wiring: `hyprctl reload` +
  `hyprctl configerrors` clean, and confirm via `hyprctl binds -j` that the bind
  is live (don't trust file contents — that's how the v0.1.15 bug hid).
- Full round-trip (enter + return + screen-share + clipboard) when touching
  anything in switch-to-gaming / gaming-session-switch / portal recovery.

### Driving the panel headlessly

`wtype` sends keys to the focused layer surface, so the panel can be tested
without a human:

```bash
omarchy-shell shell summon nosignal.deckshift '{}'
wtype -k Tab; wtype -k Return          # focus + open the Monitor dropdown
wtype -k Up; wtype -k Return           # pick the entry above the current one
wtype s                                # save
grim /tmp/panel.png                    # look at it
```

Re-selecting the *already-current* value is a safe end-to-end Save test: the
written key=value set is unchanged, only the line order moves (managed keys are
delete-then-append), so the dev box's real config can't drift.

## Open items / ideas

- **Launch button never exercised end to end.** The confirm dialog and the
  cancel path are verified; pressing Launch for real (execDetached →
  switch-to-gaming → SDDM restart → Big Picture → return) has not been run.
  This is the main thing standing between v0.2.0 and a release.
- Real hardware round-trip test of v0.1.15 portal recovery (enter Gaming Mode,
  return, confirm "Share desktop" works in Chromium) — still outstanding, and
  can be folded into the same test run as the Launch button.
- The panel's Save has no undo. The TUI's "Cancel discards changes" maps to
  Esc (buffered edits are dropped on close/refresh), but there's no revert
  after a save. Consider keeping the pre-save values for one step.
- SDDM `Relogin=true` has no backoff: a crash-looping gamescope session
  respawns several times per second until gamescope-session-plus's 5-strike
  short-session tracker recovers. Escape hatch from a tty:
  `sudo /usr/local/bin/gaming-session-switch desktop && sudo systemctl restart sddm`.
- The `--noninteractive` mode sketched for NoSignal OS integration was never
  committed here; re-implement from scratch if needed.

## Project history and field notes (compiled 2026-08-02)

DeckShift is a "Gaming Mode" launcher for Omarchy laptops (Acer Nitro and similar) — flips into a gamescope-driven Steam Big Picture session and back. Modeled on Steam Deck UX.

**Omarchy-only — NOT a distro-portable script.** Earlier docs/headers said "distro-portability is the next direction"; that's been retracted (2026-05-12). The script can freely depend on `omarchy-*` helpers, Walker/elephant, Hyprland-specific paths, SDDM, etc. without fallbacks. The "non-Omarchy stub" fallback added briefly in v0.1.5 was removed in v0.1.6. Don't add `command -v omarchy-* || ...` defensive patterns to this code.

**Remotes (dual-push pattern):**
- Forgejo: `https://git.no-signal.uk/nosignal/deckshift.git`
- GitHub: `https://github.com/28allday/deckshift.git`
- The `forgejo` remote is wired to push to BOTH URLs, so `git push forgejo` updates both. (The `github` remote also exists separately.)

**Status as of 2026-05-18:** Published, v0.1.12 latest. Recent commits: TUI hardening, hybrid PRIME offload (NVIDIA dGPU + iGPU), installer cleanup, Steam bootstrap fix, Walker refresh fix, Gaming Mode power-state revert fix, README rewrite + demo video, TUI layout polish. Return-from-Gaming-Mode fixes shipped 2026-05-09 (sleep + portal v1), 2026-05-12 v0.1.4 (portal-recovery race fix), 2026-05-12 v0.1.5 (clipboard via Walker restart), 2026-05-12 v0.1.6 (dropped non-Omarchy fallback), 2026-05-17 v0.1.7 (AMD Steam bootstrap fix + dep cleanup), 2026-05-18 v0.1.8 (NVIDIA+HDMI 60 Hz launch fix), 2026-05-18 v0.1.9 (legacy CUSTOM_REFRESH_RATES auto-migration), 2026-05-18 v0.1.10 (Settings TUI layout polish — single centred panel column) — see below.

**v0.1.4 is the first actually-git-tagged release.** v0.1.0–v0.1.3 only existed as "v0.1.x —" prefixes in commit messages; no annotated tags. Going forward, tag releases with `git tag -a vX.Y.Z -m "..."` and `git push forgejo vX.Y.Z` (covers both remotes).

**Gaming Mode → Desktop return-side gotchas (both fixed 2026-05-09):**

The SDDM restart that brings the user back to Hyprland causes two distinct downstream failures because some kernel/polkit/dbus state is sticky across the restart:

1. **`systemctl suspend` → "Access denied" (polkit)** — `switch-to-gaming` masks `sleep.target suspend.target hibernate.target hybrid-sleep.target` with `--runtime` (symlinks in `/run/systemd/system/`). Plain `unmask` in `switch-to-desktop` doesn't always clear them, and even when it does, logind's `CanSuspend` cache stays "no" until a daemon-reload. Fix: explicit `unmask --runtime` + `daemon-reload` in `switch-to-desktop`, plus matching NOPASSWD sudoers entries. Commit `f66452d`.

2. **Chromium/Firefox "Share desktop" silently fails (only "Share a tab" works)** — `xdg-desktop-portal-hyprland`, pipewire, wireplumber are user services bound to `HYPRLAND_INSTANCE_SIGNATURE`. After the SDDM restart they're still attached to the killed Hyprland; new compositor's screencasts get no frames. Tab capture works because Chromium does it internally without the portal. Fix: `switch-to-desktop` drops `/tmp/.deckshift-just-returned`; new helper `/usr/local/bin/deckshift-portal-recovery` is `exec-once`'d from `~/.config/hypr/autostart.conf`, checks the marker and bounces the portal+pipewire stack. Initial fix commit `49046c4` (2026-05-09).

3. **Portal recovery race (v0.1.4, commit `ada71c9`, 2026-05-12)** — the initial helper used a single `systemctl --user restart` on all five units, which raced: portals could come up before wireplumber had rebuilt the node graph, leaving the screencast portal bound to nothing. User on the issue tracker reported intermittent recurrence. Rewritten to a serialised sequence: marker guard → `sleep 2` (wait for Hyprland env) → `systemctl --user import-environment` → `dbus-update-activation-environment --systemd` (so D-Bus-activated portals target the live Wayland socket, not the dead one) → stop portals → `pkill -TERM` then `pkill -KILL` for stragglers (SIGKILL alone leaves stale D-Bus name registrations) → `reset-failed` → restart pipewire stack → wait 2s → start portals. The marker guard and initial sleep are load-bearing: without the guard the helper would bounce portals on every Hyprland login (breaks normal screen-share); without the sleep `WAYLAND_DISPLAY` may be empty when the env push happens.

4. **Clipboard dead after return (v0.1.5 → simplified v0.1.6, commits `74b1a5b` + `8293d26`, 2026-05-12)** — same user reported v0.1.4 fixed the portal but clipboard then stopped working. Same root cause: Walker's `elephant.service` holds the wl-clipboard listener, which was bound to the dead Hyprland's Wayland socket. Fix: append `omarchy-restart-walker` at the END of `deckshift-portal-recovery` (it restarts `elephant.service` + `app-walker@autostart.service`). v0.1.5 had a non-Omarchy fallback; v0.1.6 removed it since DeckShift is Omarchy-only.

**Manual recovery one-liner (for stuck users on old installs):**
```
touch /tmp/.deckshift-just-returned && /usr/local/bin/deckshift-portal-recovery
```
The `touch` is required because the helper is a no-op without the marker — that guard prevents it from bouncing portals on every normal Hyprland login.

**How to apply:** If a user reports anything weird after returning from Gaming Mode (sleep, screen sharing, audio routing, dbus-mediated stuff), suspect leftover state from the SDDM restart cycle first — masked targets, stale logind cache, user services bound to the dead compositor — before assuming a new bug.

**v0.1.7 (2026-05-17): Steam bootstrap delegated to upstream Omarchy + dep cleanup.** Steam was failing to bootstrap on AMD installs because the homegrown `setsid gtk-launch steam` line silently no-op'd when `gtk-launch` (gtk3) wasn't installed — NVIDIA systems usually pulled gtk3 in via nvidia-settings, AMD lean setups didn't. Bootstrap now calls `omarchy-install-gaming-steam` (which runs `omarchy-pkg-add steam` idempotently, then `omarchy-install-gaming-gpu-lib32`, then `setsid gtk-launch steam &`). Since lib32 GPU drivers are now installed by `omarchy-install-gaming-gpu-lib32`, the following were dropped from DeckShift's own dep lists: `steam` (was in core_deps AND setup_requirements required_packages), `mesa-utils` (script never called glxinfo), `lib32-nvidia-utils`, `lib32-nvidia-580xx-utils`, `lib32-vulkan-radeon`, `lib32-vulkan-intel`, and `xf86-video-amdgpu` (X11 DDX, useless under Hyprland Wayland). Net 8 entries removed. 64-bit GPU drivers (`vulkan-radeon`, `vulkan-intel`, `nvidia-utils`, etc.) kept because the upstream helper only handles lib32.

**How to apply:** When DeckShift runs on Omarchy, prefer delegating to `omarchy-install-gaming-*` helpers over reimplementing the same logic — they're tested on all three GPU vendors. Same principle applies to other Omarchy-only tools.

**v0.1.8 (2026-05-18): Gaming Mode launching at 60 Hz on NVIDIA + HDMI (commit `4fa77a6`).** Reported by clutchmuffin: settings TUI saved e.g. `CUSTOM_REFRESH_RATES=165` but Gaming Mode always launched at 60 Hz. Two stacked bugs:

1. **TUI didn't reload systemd user env.** Settings TUI wrote `~/.config/environment.d/gamescope-session-plus.conf` but never pushed the change into the running user manager, so `gamescope-session-plus@.service` still saw the old values until next login. Fix: `flush_pending` now calls `systemctl --user import-environment` / `unset-environment` for the touched keys.

2. **`CUSTOM_REFRESH_RATES` written as a scalar.** Gamescope's `--custom-refresh-rates` is a list of *switchable* rates, not a launch-rate selector — with no safe 60 Hz fallback in the list, some DRM/NVIDIA paths drop to the EDID-preferred 60 Hz on first launch. TUI now writes a comma list (e.g. `60,165`). `show_state` and `confirm_risky_save` de-list to the highest member for display/validation. Steam BPM client-side rate persistence is the canonical first-launch workaround (now documented in README troubleshooting).

**v0.1.9 (2026-05-18): Auto-migrate legacy `CUSTOM_REFRESH_RATES` on installer re-run (commit `3131dca`).** v0.1.8 only fixed the TUI write path, so pre-v0.1.8 users with a scalar `CUSTOM_REFRESH_RATES=<rate>` still hit the 60 Hz bug until they re-opened the TUI and re-picked the rate. Installer now detects the legacy scalar format, rewrites to the comma list (`60,<rate>`) on re-run, and imports the new value into the running systemd user environment. Idempotent — already-migrated comma-list configs are left alone.

**How to apply:** When fixing a config-format bug, also add a migration path in the installer/upgrade path so existing users get the fix without manual intervention. Don't rely on "users will re-open the TUI" — they won't.

**v0.1.10 (2026-05-18): Settings TUI layout polish (commit `aaa2f3d`).** Banner, state panel, menu header, and menu items now share a single centred panel column instead of each block being centred independently — earlier, the state panel drifted left because `center_block` centred it based on the widest line (the long config-file path), while the short menu drifted right. Key bits:

1. **Adaptive `PANEL_WIDTH`** = `min(COLS − 6, 60)`, floored at 40. Computed once per loop in `refresh_cols` alongside `LEFT_MARGIN` and a cached `LEFT_PAD` string.
2. **`pad_block` replaces `center_block`** as the workhorse — prepends a single shared `$LEFT_PAD` to every line, so every block lands at the same column.
3. **`stty size </dev/tty` is now the primary terminal-width source.** `tput cols` is kept as a fallback but in a freshly-spawned floating terminal (Walker → `xdg-terminal-exec --app-id=TUI.float`) it sometimes returns the terminfo default (80) before the compositor has applied its real size — `stty size` is kernel-reported and always reflects the live window.
4. **`set -eo pipefail` trap:** the *first* attempt used `COLS=$(stty size 2>/dev/null </dev/tty | awk '{print $2}')` — when `/dev/tty` isn't attached (script piped or stdin redirected), the pipeline failed under pipefail and propagated out, tripping `-e` on the assignment. The TUI opened-and-closed-instantly. Fix: every command substitution that calls a potentially-failing program ends with `|| true`, and the validation chain is collapsed into a single `if [[ regex ]] && (( > 0 ))` so the `(( ))` arithmetic sits inside the if-test (where `-e` is suspended) rather than the body.
5. **`cmenu` helper** wraps `gum choose` with a padded `--cursor`/`--header` so the rendered block sits at the panel's left edge. gum widgets always draw at column 0 with no alignment flag, but gum reserves the cursor string's visual width as the gutter for unselected rows — baking left-padding into the cursor prefix shifts the whole block. Used for every menu in the script (main + Monitor/Resolution/Refresh/GPU pickers).
6. **Config path uses `~`** instead of `/home/<user>/...` so it fits the panel.

**How to apply:** For gum-based TUIs that need a tidy layout: pick a single panel width, compute one shared left margin, position EVERY block at that margin (don't independently centre each one — they won't visually align). gum widgets can't centre themselves, but you can shift them right by baking padding into `--cursor` and `--header`. Under `set -eo pipefail`, command substitutions that call programs which can legitimately fail (stty/tput against an absent tty) need `|| true` *inside* the `$(...)` — without it, the outer assignment trips `-e` and the script exits before fallbacks can run.

**v0.1.11 (2026-05-18): Multi-monitor handling via `OUTPUT_CONNECTOR_TO_DISABLE` (commit `52c883b`).** Reported on a Framework Desktop (AMD AI MAX 380) + Gigabyte M27Q + LG DualUp setup: with both monitors attached, gamescope landed on the wrong screen / refused to start, and `OUTPUT_CONNECTOR=DP-X` alone didn't fix it. The reporter's workaround patched `/usr/share/gamescope-session-plus/gamescope-session-plus` to add `hyprctl keyword monitor X,disable` before launching gamescope — but that's the wrong place: by the time gamescope-session-plus runs, Hyprland has been killed and `hyprctl` has no live IPC socket. (Their script may have been silently no-op'ing; gamescope likely succeeded for an unrelated reason like a DRM race resolving.)

DeckShift's fix puts the disable in `switch-to-gaming`, BEFORE the SDDM restart, while Hyprland is still alive. The disable is runtime-only (`hyprctl keyword` doesn't touch the static config), so when the user returns from Gaming Mode the new Hyprland reads its config fresh and the monitor comes back automatically — no re-enable hook needed. The env var supports a comma list (`HDMI-A-1,DP-2`) so triple-monitor setups can disable both auxiliaries.

Settings TUI exposes this as a **"Hide monitor"** main-menu item. The picker lists every connected monitor EXCEPT the one currently set as `OUTPUT_CONNECTOR` (excluding it prevents the user from accidentally disabling their gaming display).

**Latent bug also fixed:** v0.1.10's `${CONF/#$HOME/~}` to render `~/.config/...` was a no-op — bash applies tilde-expansion to the replacement side, re-expanding `~` back to `$HOME`. Escaped as `\~` now. The earlier preview test I ran for v0.1.10 used a hardcoded `~` literal in the heredoc instead of exercising the actual `show_state` function, so the bug slipped through.

**How to apply:**
- For features that need to act on the live compositor (hyprctl, dbus to xdg-desktop-portal, etc.) before the SDDM restart, put them in `switch-to-gaming`, not in gamescope-session-plus or anywhere downstream of the restart. By the time those run, the original Hyprland IPC socket is gone.
- When using bash `${var/#pat/repl}`: if `repl` contains `~`, escape it as `\~` or bash's tilde expansion will swap it back to `$HOME` before the substitution runs.
- When previewing TUI output, source the real script and call the real functions — don't hand-build a fake heredoc, because that bypasses the very substitutions you're trying to verify.

**v0.1.12 (2026-05-18): Refresh-rate selection actually reaches gamescope now (commit `a3cb6f2`).** The real root cause behind v0.1.8's "60 Hz stuck" reports was finally identified and fixed.

**The mismatch in our install chain (memorise this):**
- `gamescope` binary at `/usr/bin/gamescope` is owned by **`gamescope` 3.16.23 from Arch's `extra` repo** — upstream Valve build, packager Sven-Hendrik Haase. URL: github.com/ValveSoftware/gamescope.
- `gamescope-session-plus` script at `/usr/share/gamescope-session-plus/gamescope-session-plus` is owned by **`gamescope-session-git` from AUR** — OpenGamingCollective (post-rebrand of ChimeraOS). URL: github.com/OpenGamingCollective/gamescope-session.
- These two were authored by different upstreams with different assumptions. The session script uses `--custom-refresh-rates`, a flag that exists only in the ChimeraOS-fork `gamescope-plus` binary, which is NOT what Arch's `extra` repo ships. There's no 64-bit `gamescope-plus` AUR package either — `lib32-gamescope-plus` exists but at 3.12.2-base, not a usable 64-bit gamescope.
- The session script feature-detects via `gamescope_has_option "--custom-refresh-rates"`, finds it absent, and silently drops the env value. The user's TUI selection is recorded in `~/.config/environment.d/gamescope-session-plus.conf` but never makes it to the gamescope CLI.

**Why v0.1.8 looked like it worked:** I never actually verified the flag round-tripped to gamescope on Omarchy. The dev box's monitor never got tested at a non-60 rate. The Framework Desktop user with a 170 Hz panel was the first to actually look — they noticed it stuck at 60 and assumed it was their hardware. Their patch (singular `CUSTOM_REFRESH_RATE` + `--nested-refresh`) was the right shape of fix, applied in the wrong place (inside the gamescope-session-plus script, where AUR clobbers it on rebuild).

**DeckShift's fix:** `patch_gamescope_session_plus()` function in `deckshift.sh` runs after `setup_session_switching`'s AUR install. Uses Python `re.sub` with a function-callback replacement to inject an `elif` branch that falls back to `--nested-refresh` with the highest value from the comma list. Marked with `DECKSHIFT-NESTED-REFRESH-FALLBACK` sentinel for idempotency. Re-applied on every `./deckshift.sh` run so AUR upgrades that clobber the file don't silently regress.

**Python `re.sub` gotcha learned:** A first-attempt string-form replacement (`'... | tr "," "\\n" | ...'`) failed because re.sub processes backslash escapes in the replacement string — `\n` in `\\n` became a real newline in the output, breaking the `tr` argument. Function-callback replacements (`re.sub(pat, lambda m: ..., text)`) return literal strings and bypass that processing. Use the callback form whenever the replacement contains shell-escape sequences that need to survive intact.

**How to apply:**
- When DeckShift assumes a gamescope flag, sanity-check it on the actual Omarchy box with `gamescope --help | grep <flag>`. The session-plus script is from a different upstream than the binary — their assumptions don't always align.
- Re-applying a patch on every installer run is the right pattern for AUR-clobber resilience: idempotent via a sentinel comment, no harm done if already patched.
- For `re.sub` replacements that contain `\n`, `\t`, `\1`-style sequences that need to reach the output verbatim: pass a function as the replacement, not a string. Function returns are taken literally.

**v0.1.13 (2026-05-19): Pacman hook for cap_sys_nice persistence (commit `d45f81b`).** Discord report (via user): file capabilities live as an xattr on the inode, so every pacman upgrade of `gamescope` replaces the binary and silently strips `cap_sys_nice=eip`. Performance mode keeps "working" but the compositor thread loses priority — worse frame pacing + input latency, zero surfaced error.

Fix: installer drops `/usr/share/libalpm/hooks/deckshift-gamescope-cap.hook` with `Type=Path`, `Operation=Install`/`Upgrade`, `Target=usr/bin/gamescope` (repo-root relative, no leading slash), `When=PostTransaction`, `Exec=/usr/bin/setcap cap_sys_nice=eip /usr/bin/gamescope`. Pacman runs hooks as root so no sudo prompt. New helper `install_gamescope_cap_hook()` is called from the existing performance-mode cap block in `setup_requirements`. Hook is treated as optional in the verification inventory so users who declined performance mode don't see a missing-file warning.

Rejected the Discord commenter's hash-and-prompt-with-don't-ask-again approach as over-engineered: PERFORMANCE_MODE is already explicit user opt-in, the binary is always the pacman-installed `command -v gamescope`, and a pacman upgrade isn't a fresh trust event. The pacman hook is the idiomatic Arch fix — no prompts, no extra state.

**How to apply:**
- For any cap_sys_nice / cap_net_admin / other file-cap requirement on an Arch package's binary, install a libalpm hook so the cap re-applies on every upgrade. Don't rely on installer re-runs — users won't notice silent regressions.
- In libalpm hooks: `Target` paths are repo-root relative (no leading `/`). `When=PostTransaction` for "after the file is on disk". Hooks run as root with no auth prompts.

**v0.1.14 (2026-06-16): `--noninteractive` / `-y` unattended mode (UNCOMMITTED, local-only so far).** Added so NoSignal OS could bake DeckShift in by default on its fully-OFFLINE ISO. New `prompt_yn DEFAULT "msg"` / `prompt_pause` helpers (after the logging helpers) replace all ~20 `read -p "..." -n 1 -r` sites; they set `$REPLY` so the existing `[[ $REPLY =~ ^[Yy] ]]`/`^[Nn]` checks are unchanged. With `NONINTERACTIVE=1`: yes to all config/groups/sudoers/session/keybind prompts; no/skip to system-upgrade, AUR-helper rebuild/install, Xbox controllers, reboot. The one unconditional network call (`pacman -Syy || die` in `check_steam_dependencies`) is guarded behind `[[ -z "$NONINTERACTIVE" ]]`; everything else network-touching is behind a prompt (answered no) or the failed-deps fallback (never triggers when packages are pre-installed). Flag wired into the `case "${1:-}"` dispatch + `show_help` + version bump. **How to apply:** NoSignal runs `deckshift.sh --noninteractive` once on first login with every gaming package already pacstrapped, so it does zero network and lays down only config. ⏭️ Never committed — re-implement from scratch if needed (see Open items).

**Uninstalled from the desktop 2026-07-06 (NVIDIA→AMD swap), then REINSTALLED the same evening (20:43) after the RX 9060 XT went in.** Note the README's Uninstalling section misses three installed items: `deckshift-portal-recovery`, its `exec-once` line in `~/.config/hypr/autostart.conf`, and `/usr/share/libalpm/hooks/deckshift-gamescope-cap.hook` — all three fixed in the v0.1.15 README.

**2026-07-06 crash loop on the AMD desktop (diagnosed 2026-07-11):** first Gaming Mode attempts crash-looped — Steam (32-bit client) SIGSEGV, then `mangoapp` SIGSEGV every ~9 s (session start → die → SDDM `Relogin=true` respawn; journal shows `sddm-helper: Failed to take control of "/dev/tty1": Operation not permitted` spam during the respawn storm). Root cause was the THEN-current graphics stack (mesa 26.1.1, mangohud 0.8.3, gamescope 3.16.23, kernel 7.0.9) on brand-new RDNA4 (Navi 44 / GFX1200). The 2026-07-11 system update (mesa 26.1.4, mangohud 0.8.4, gamescope 3.16.24, kernel 7.1.3, steam 1.0.0.87) fixed it: verified same day — vulkaninfo enumerates RADV GFX1200, nested gamescope selects the RX 9060 XT, mangoapp no longer segfaults, `deckshift.sh --verify` ALL CHECKS PASSED. Config confirmed sane: `DRI_PRIME=pci-0000_03_00_0` (dGPU; monitor is on the dGPU's HDMI-A-2; Raphael iGPU correctly excluded by the APU regex), renders 2560x1440@60 on the 4K panel, `ENABLE_GAMESCOPE_HDR=1` (first knob to flip to 0 if issues return — AMD+HDMI HDR is flaky). cap_sys_nice pacman hook proven: survived the 07-11 gamescope upgrade. v0.1.12 session-plus patch present in installed file. Escape hatch from a crash loop: tty → `sudo /usr/local/bin/gaming-session-switch desktop && sudo systemctl restart sddm`. Design hazard worth fixing someday: SDDM `Relogin=true` has no backoff, so a failing session respawns several times per second until session-plus's 5-strike short-session tracker recovers.

**Maintainer notes live in `NOTES.md` in the repo** (added 2026-07-27, commit `d7251fe`) — Omarchy 4 facts, Lua-first conventions, release flow, test checklist, open items. Read it at session start before changing the code.

**v0.1.15 (2026-07-27, commit `8ba6e72`, tagged, dual-pushed): Omarchy 4 compatibility — ALL items from the audit below FIXED.** Installer now writes keybind to bindings.lua (`hl.unbind` + `o.bind`, .conf fallback for pre-4) and portal-recovery autostart via `o.launch_on_start` in autostart.lua (.conf fallback); `--verify` checks the Lua files + new portal-recovery autostart check; Walker/elephant code removed entirely (configure_elephant_launcher, restart_elephant_walker, walker refresh, portal-recovery clipboard tail — pre-4 users needing the clipboard fix stay on v0.1.13); README updated incl. the long-flagged uninstall gaps (portal-recovery, autostart lines, pacman cap hook). Desktop box live-fixed same day: autostart.lua wired (hyprctl reload clean), installed portal-recovery de-walkered, `--verify` ALL CHECKS PASSED. Version 0.1.14 skipped (reverted unreleased keybind change used that label).

**2026-07-27 Omarchy 4 (Quickshell + Lua config) compatibility audit — desktop:** Hyprland now reports `configProvider: lua`; ALL `~/.config/hypr/*.conf` files are dead (proven: a bind present only in bindings.conf is absent from `hyprctl binds`). Consequences:
1. **BROKEN LIVE: `deckshift-portal-recovery` never runs** — its `exec-once` sits in dead `autostart.conf`; `autostart.lua` is an empty template. Return-from-Gaming-Mode portal/pipewire bounce is silently disabled → the v0.1.4 "Share desktop broken" bug is back. Fix: `o.launch_on_start("/usr/local/bin/deckshift-portal-recovery")` in `~/.config/hypr/autostart.lua`.
2. Enter keybind still works on the desktop ONLY because of the 2026-07-11 manual bindings.lua fix (line 33). Installer + `--verify` still target dead bindings.conf (repo unchanged) — broken for fresh Omarchy 4 installs, and --verify false-passes.
3. **`omarchy-restart-walker` and `elephant` are GONE** (Quickshell shell shipped; `walker` binary still present as leftover). `restart_elephant_walker`, `configure_elephant_launcher` (writes dead `~/.config/elephant/desktopapplications.toml`), and portal-recovery's final clipboard step are all silent no-ops. Clipboard is now omarchy-shell's (spawned fresh each session, no persistent user service), so the stale-socket clipboard bug likely can't recur — drop those steps; `omarchy-restart-shell` exists if a shell bounce is ever needed.
4. Still fine: switch-to-gaming / gaming-session-switch / gaming-keybind-monitor have zero waybar/mako/walker refs; `TUI.float` floating rule survives in O4 defaults (`default/hypr/apps/system.lua`); `omarchy-pkg-add`, `omarchy-hw-nvidia-gsp`/`-without-gsp`, `omarchy-install-gaming-steam`, `uwsm-app` all still exist.

**2026-07-11: Super+Shift+S keybind silently lost to Omarchy's Lua binding migration.** Omarchy now registers all binds via Lua; DeckShift's installer appends `bindd =` to `~/.config/hypr/bindings.conf`, which no longer produces a live bind, and Omarchy's default `applications.lua` claims SUPER+SHIFT+S for Google Maps. Fixed on the desktop by adding `hl.unbind("SUPER + SHIFT + S")` + `o.bind("SUPER + SHIFT + S", "Gaming Mode", "/usr/local/bin/switch-to-gaming")` to `~/.config/hypr/bindings.lua`. ⏭️ TODO: DeckShift installer (setup_hyprland_keybind and the --verify keybind check) needs to target bindings.lua on Lua-binding Omarchy versions.

**Components (as of v0.2.0):**
- `deckshift.sh` — main entry script
- `plugins/nosignal.deckshift/` — omarchy-shell control panel (bar icon + panel), replaces the old TUI
- gamescope-based session

**v0.2.0 (2026-07-30; merged back into this repo 2026-08-14).** Developed in a temporary remote-less clone of `deckshift` @ `d7251fe` so nothing reached the live repos before it was ready. Replaces the gum settings TUI with a native Omarchy 4 Quickshell plugin (`nosignal.deckshift`): same five settings as dropdowns fed from the selected monitor's real mode list, edits buffered until Save, plus a Launch Gaming Mode button behind a confirm. Installer gained `setup_shell_plugin` + `remove_legacy_settings_tui`; `--verify` gained a control-panel section. Installed live on the dev desktop (plugin dir symlinked to the working tree) with a SUPER+ALT+G bind. ⏭️ Launch button never pressed for real — that end-to-end run is what's between this and a release. Full detail in the repo's NOTES.md.

**Why:** the goal is a one-keystroke transition into a Deck-like full-screen gamescope/Steam mode for couch / handheld-style play, then back out cleanly to Hyprland.

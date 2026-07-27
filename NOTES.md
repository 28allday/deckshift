# DeckShift — maintainer notes

Working notes for future development sessions. User-facing docs live in README.md.

## Current state (2026-07-27)

- **v0.1.15 released** — commit `8ba6e72`, tagged, pushed to both remotes
  (Forgejo `nosignal/deckshift` + GitHub `28allday/deckshift`; the `forgejo`
  remote pushes to both).
- v0.1.14 was **skipped**: that label was used by a keybind-change commit
  (`0844f02`, Super+Shift+S → Super+Shift+G) that was reverted before release.
- Dev/reference machine: Omarchy 4 desktop (AMD RX 9060 XT), install verified
  with `./deckshift.sh --verify` — all checks passed, including the two checks
  added in v0.1.15.

## Omarchy 4 facts that shape this codebase

Discovered during the 2026-07-27 compatibility audit; verify against a live
system before assuming they still hold.

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
     Omarchy defaults claim; duplicate Hyprland binds BOTH fire.
   - `o.launch_on_start("command")` — exec-once equivalent (wraps the command
     with `o.launch()`, i.e. uwsm-app).
3. **Walker/elephant are gone**: `omarchy-restart-walker` and `elephant` no
   longer exist (`walker` binary may linger as an orphan). The Quickshell-based
   omarchy-shell owns the app menu, notifications, and clipboard. The clipboard
   holder starts fresh with each Hyprland session, so the pre-4 stale-socket
   clipboard bug (v0.1.5/v0.1.6 fix) cannot recur — that code was removed.
   `omarchy-restart-shell` exists if a shell bounce is ever needed.
4. **Still present and safe to depend on**: `omarchy-pkg-add`,
   `omarchy-hw-nvidia-gsp` / `-without-gsp`, `omarchy-install-gaming-steam`,
   `uwsm-app`, the `TUI.float` floating-window rule
   (`default/hypr/apps/system.lua`), `xdg-terminal-exec`.

## Conventions

- **Omarchy-only, not distro-portable** — depend on `omarchy-*` helpers freely;
  no non-Omarchy fallbacks. (Pre/post-Omarchy-4 *version* branching is fine and
  used for the bindings/autostart writers.)
- Lua-first, `.conf` fallback: every Hyprland config write site checks for the
  `.lua` override file first, falls back to the legacy `.conf`, warns if
  neither exists. Keep new write sites consistent with this.
- All config writes are idempotent (grep-before-append). Re-running
  `./deckshift.sh` on an existing install migrates `.conf` wiring to `.lua`
  automatically (the stale `.conf` lines are left in place — they're dead
  files under Omarchy 4).
- Release flow: bump `DECKSHIFT_VERSION`, README header + changelog entry,
  commit `vX.Y.Z — summary`, annotated tag, `git push forgejo master &&
  git push forgejo vX.Y.Z` (covers both remotes).

## Testing checklist for future changes

- `bash -n deckshift.sh bin/deckshift-settings` + `shellcheck -S warning` on
  both (pre-existing SC2155/SC1090 warnings are known noise).
- `./deckshift.sh --verify` on the dev box.
- After touching keybind/autostart wiring: `hyprctl reload` +
  `hyprctl configerrors` must come back clean, and confirm via
  `hyprctl binds -j` that the bind is actually live (don't trust file contents
  — that's exactly how the v0.1.15 bug hid).
- Full round-trip (enter + return + screen-share + clipboard) when touching
  anything in switch-to-gaming / gaming-session-switch / portal recovery.

## Open items / ideas

- Real hardware round-trip test of v0.1.15 portal recovery (enter Gaming Mode,
  return, confirm "Share desktop" works in Chromium) — wiring is verified, the
  end-to-end path hasn't been re-run since the change.
- SDDM `Relogin=true` has no backoff: a crash-looping gamescope session
  respawns several times per second until gamescope-session-plus's 5-strike
  short-session tracker recovers. Escape hatch from a tty:
  `sudo /usr/local/bin/gaming-session-switch desktop && sudo systemctl restart sddm`.
  Worth a proper fix someday.
- The `--noninteractive` mode sketched for NoSignal OS integration was never
  committed here; re-implement from scratch if needed.

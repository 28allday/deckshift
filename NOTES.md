# DeckShift — maintainer notes

Working notes for future development sessions. User-facing docs live in README.md.

## Current state (2026-07-30)

- **v0.2.0 in progress** — this repo (`deckshift-o4`) is a clone of `deckshift`
  taken at `d7251fe`, created to build the Omarchy 4 control panel. It has **no
  git remotes** on purpose, so nothing here can reach the live
  `nosignal/deckshift` + `28allday/deckshift` repos before the work is ready.
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
  git push forgejo vX.Y.Z` (covers both remotes) — **once this clone has
  remotes again**.

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
- Decide the endgame for this clone: merge back into `deckshift` as v0.2.0, or
  keep it separate. If merging, remember the remotes were stripped deliberately.

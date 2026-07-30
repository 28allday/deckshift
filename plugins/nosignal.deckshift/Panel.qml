import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// DeckShift Gaming Mode control panel. Summoned/toggled through the shell host:
//   omarchy-shell shell toggle nosignal.deckshift
// The host calls open(payloadJson) / close() and reads `opened`; it also
// injects `shell` right after the Loader resolves (see onShellChanged).
//
// This panel replaces the gum settings TUI that shipped up to v0.1.15. It owns
// the same five keys in ~/.config/environment.d/gamescope-session-plus.conf —
// OUTPUT_CONNECTOR, SCREEN_WIDTH/SCREEN_HEIGHT, CUSTOM_REFRESH_RATES, the GPU
// mode key set, and OUTPUT_CONNECTOR_TO_DISABLE — and keeps the TUI's two
// safety behaviours: edits are buffered until Save (nothing touches disk as you
// browse), and Save refuses to go quietly when the picked mode exceeds what the
// monitor reports.
//
// Hardware state is read ONCE per open (r/F5 refetches): hyprctl for monitors
// and their mode lists, lspci for GPUs, the conf file for current values. No
// polling while open, none while closed.
//
// Do NOT run `qmlformat -i` on this file — it hoists every section comment to
// the top of the root Item and reindents away from the sibling plugins' style.
Item {
  id: root

  property bool opened: false

  readonly property string selfId: "nosignal.deckshift"

  // Injected by the shell host after the Loader resolves. Used to keep the
  // host's open-flag honest on close(), and to self-restore if the host's
  // panel Instantiator rebuild destroys a visibly-open instance.
  property var shell: null
  onShellChanged: {
    if (!root.opened && root.shell && root.shell.openPanelIds
        && root.shell.openPanelIds[root.selfId] === true)
      root.open("{}")
  }

  // ------------------------------------------------------------------ state

  // Hardware + on-disk config, all replaced wholesale by parseFetch so
  // bindings that read them re-evaluate.
  property var monitors: []          // [{name, modes:[ "2560x1440@165.00Hz", … ]}]
  property var gpus: []              // [{slot, vendorDev, kind, label}]
  property var conf: ({})            // KEY → VALUE straight off disk
  property bool loaded: false
  property string fetchError: ""     // "", "nojq", "nohyprctl", "err"

  // Buffered edits — flushed only by Save, exactly like the TUI's
  // PENDING_SET / PENDING_UNSET. Both are reassigned (never mutated in place)
  // so QML notices the change.
  property var pendingSet: ({})      // KEY → VALUE to write
  property var pendingUnset: ({})    // KEY → true to delete

  readonly property bool hasPending:
    Object.keys(root.pendingSet).length > 0 || Object.keys(root.pendingUnset).length > 0

  property string saveError: ""
  property bool saving: false

  // Keys the GPU dropdown owns. Cleared as a set on every GPU pick so
  // switching modes never leaves a stale flag behind — same list, same reason
  // as the TUI's GPU_MODE_KEYS.
  readonly property var gpuModeKeys: [
    "VULKAN_ADAPTER", "GBM_BACKEND", "DRI_PRIME",
    "__NV_PRIME_RENDER_OFFLOAD", "__VK_LAYER_NV_optimus", "__GLX_VENDOR_LIBRARY_NAME",
    "MESA_VK_DEVICE_SELECT", "MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE"
  ]

  // Shares the [menu] surface tokens so themes that style the menu style this
  // panel too — same approach as the sibling nosignal.* panels.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color accent: Color.accent
  property color urgent: Color.urgent
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int rowSpacing: Style.spacing.lg
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)

  // ------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    root.opened = true
    root.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    if (!root.opened) return
    root.opened = false
    launchConfirm.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.selfId)
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  // Re-read hardware and disk. Deliberately drops buffered edits: the values
  // they were picked against may no longer exist (monitor unplugged, eGPU
  // gone), so keeping them would let Save write a mode for hardware that isn't
  // there any more.
  function refresh() {
    root.loaded = false
    root.saveError = ""
    root.pendingSet = ({})
    root.pendingUnset = ({})
    fetchProc.running = true
  }

  // ---------------------------------------------------- pending-edit buffer

  function effective(key) {
    if (root.pendingUnset[key] === true) return ""
    if (root.pendingSet[key] !== undefined) return String(root.pendingSet[key])
    var v = root.conf[key]
    return v === undefined || v === null ? "" : String(v)
  }

  function setPending(key, value) {
    var s = ({}); for (var a in root.pendingSet) s[a] = root.pendingSet[a]
    var u = ({}); for (var b in root.pendingUnset) u[b] = root.pendingUnset[b]
    s[key] = String(value)
    delete u[key]
    root.pendingSet = s
    root.pendingUnset = u
  }

  function unsetPending(key) {
    var s = ({}); for (var a in root.pendingSet) s[a] = root.pendingSet[a]
    var u = ({}); for (var b in root.pendingUnset) u[b] = root.pendingUnset[b]
    delete s[key]
    // Only worth a delete line if the key is actually on disk.
    if (root.conf[key] !== undefined && root.conf[key] !== null) u[key] = true
    else delete u[key]
    root.pendingSet = s
    root.pendingUnset = u
  }

  // ------------------------------------------------------- monitor helpers

  // The connector we're configuring: explicit pick, else the first monitor
  // hyprctl reports (which is what gamescope would land on unaided).
  readonly property string activeConnector: {
    var c = root.effective("OUTPUT_CONNECTOR")
    if (c !== "") return c
    return root.monitors.length > 0 ? String(root.monitors[0].name) : ""
  }

  function monitorByName(name) {
    for (var i = 0; i < root.monitors.length; i++)
      if (String(root.monitors[i].name) === name) return root.monitors[i]
    return null
  }

  // Mode strings for the active connector — empty if it isn't currently
  // plugged in, in which case every capability check below stands down rather
  // than blocking the user with limits it can't actually see.
  readonly property var activeModes: {
    var m = root.monitorByName(root.activeConnector)
    return m && m.modes ? m.modes : []
  }

  // Native resolution = hyprctl's first (preferred) mode.
  readonly property string nativeRes: {
    if (root.activeModes.length === 0) return ""
    return String(root.activeModes[0]).replace(/@.*/, "")
  }

  // Max refresh AT NATIVE resolution, rounded to whole Hz. Reporting the max
  // across all modes would mislead — a 4K@60 panel may well do 100Hz at
  // 1024x768, which tells the user nothing useful about Gaming Mode.
  readonly property int maxRefresh: {
    var best = 0
    for (var i = 0; i < root.activeModes.length; i++) {
      var mode = String(root.activeModes[i])
      if (mode.indexOf(root.nativeRes + "@") !== 0) continue
      var hz = Math.round(parseFloat(mode.split("@")[1]))
      if (hz > best) best = hz
    }
    return best
  }

  function resolutionsFor(modes) {
    var seen = ({}), out = []
    for (var i = 0; i < modes.length; i++) {
      var res = String(modes[i]).replace(/@.*/, "")
      if (seen[res]) continue
      seen[res] = true
      out.push(res)
    }
    return out
  }

  // Whole-Hz rates supported at `res` (or across every mode when res is ""),
  // deduplicated — 60.00 and 59.94 both land on 60 — and ordered high first.
  function refreshRatesFor(res) {
    var seen = ({}), out = []
    for (var i = 0; i < root.activeModes.length; i++) {
      var mode = String(root.activeModes[i])
      if (res !== "" && mode.indexOf(res + "@") !== 0) continue
      var hz = Math.round(parseFloat(mode.split("@")[1]))
      if (!hz || seen[hz]) continue
      seen[hz] = true
      out.push(hz)
    }
    out.sort(function(a, b) { return b - a })
    return out
  }

  function resolutionSupported(res) {
    if (root.nativeRes === "") return true          // unknown → don't block
    // `native` is a reserved word in QML's JS dialect — naming a local that
    // fails the whole file to parse, with no diagnostic.
    var want = res.split("x"), max = root.nativeRes.split("x")
    return parseInt(want[0]) <= parseInt(max[0])
        && parseInt(want[1]) <= parseInt(max[1])
  }

  function refreshRateSupported(hz) {
    if (root.activeModes.length === 0) return true  // unknown → don't block
    return root.refreshRatesFor("").indexOf(parseInt(hz)) !== -1
  }

  // ------------------------------------------------------- current values

  readonly property string resValue: {
    var w = root.effective("SCREEN_WIDTH"), h = root.effective("SCREEN_HEIGHT")
    return (w !== "" && h !== "") ? w + "x" + h : ""
  }

  // CUSTOM_REFRESH_RATES is stored as a list ("60,165") so gamescope keeps a
  // safe 60Hz fallback; the rate the user actually picked is the highest
  // member, and that's the only one the UI should talk about.
  readonly property string rateValue: {
    var raw = root.effective("CUSTOM_REFRESH_RATES")
    if (raw === "") return ""
    var best = 0, parts = raw.split(",")
    for (var i = 0; i < parts.length; i++) {
      var hz = parseInt(parts[i])
      if (hz > best) best = hz
    }
    return best > 0 ? String(best) : ""
  }

  // "01:00.0" → "pci-0000_01_00_0", the tag DRI_PRIME wants.
  function driTag(slot) {
    var tag = "pci-" + String(slot).replace(/[:.]/g, "_")
    if (tag.indexOf("pci-0000") !== 0) tag = "pci-0000_" + tag.substring(4)
    return tag
  }

  function gpuByDriTag(tag) {
    for (var i = 0; i < root.gpus.length; i++)
      if (root.driTag(root.gpus[i].slot) === tag) return root.gpus[i]
    return null
  }

  function gpuByVendorDev(vd) {
    for (var i = 0; i < root.gpus.length; i++)
      if (String(root.gpus[i].vendorDev) === vd) return root.gpus[i]
    return null
  }

  // Option encoding: "auto" | "hybrid-nvidia" | "hybrid-amd|slot|vendorDev"
  // | "direct|slot|vendorDev|kind". Decoded in applyGpuMode.
  readonly property string gpuValue: {
    if (root.effective("__NV_PRIME_RENDER_OFFLOAD") !== "") return "hybrid-nvidia"
    var dri = root.effective("DRI_PRIME")
    var mvk = root.effective("MESA_VK_DEVICE_SELECT")
    var vk = root.effective("VULKAN_ADAPTER")
    var g
    if (dri !== "" && mvk !== "") {
      g = root.gpuByDriTag(dri)
      return g ? "hybrid-amd|" + g.slot + "|" + g.vendorDev : "hybrid-amd|?|" + mvk
    }
    if (vk !== "") {
      g = root.gpuByVendorDev(vk)
      return g ? "direct|" + g.slot + "|" + g.vendorDev + "|nvidia" : "direct|?|" + vk + "|nvidia"
    }
    if (dri !== "") {
      g = root.gpuByDriTag(dri)
      return g ? "direct|" + g.slot + "|" + g.vendorDev + "|" + g.kind : "direct|?|" + dri + "|other"
    }
    return "auto"
  }

  function applyGpuMode(value) {
    // Wipe the whole key set first; each branch re-sets only what it needs.
    for (var i = 0; i < root.gpuModeKeys.length; i++) root.unsetPending(root.gpuModeKeys[i])
    if (value === "auto") return

    var parts = value.split("|")
    if (value === "hybrid-nvidia") {
      root.setPending("__NV_PRIME_RENDER_OFFLOAD", "1")
      root.setPending("__VK_LAYER_NV_optimus", "NVIDIA_only")
      root.setPending("__GLX_VENDOR_LIBRARY_NAME", "nvidia")
      return
    }
    if (parts[0] === "hybrid-amd") {
      root.setPending("DRI_PRIME", root.driTag(parts[1]))
      root.setPending("MESA_VK_DEVICE_SELECT", parts[2])
      root.setPending("MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE", "1")
      return
    }
    if (parts[0] === "direct") {
      if (parts[3] === "nvidia") {
        root.setPending("VULKAN_ADAPTER", parts[2])
        root.setPending("GBM_BACKEND", "nvidia-drm")
      } else {
        root.setPending("DRI_PRIME", root.driTag(parts[1]))
      }
    }
  }

  // ------------------------------------------------------- dropdown models

  readonly property var monitorOptions: {
    var out = [{ value: "", label: "Auto — let gamescope pick" }]
    for (var i = 0; i < root.monitors.length; i++) {
      var m = root.monitors[i]
      var res = (m.modes && m.modes.length > 0) ? String(m.modes[0]).replace(/@.*/, "") : ""
      out.push({ value: String(m.name), label: res !== "" ? m.name + "  ·  " + res : String(m.name) })
    }
    // A connector saved earlier may not be plugged in now (external display
    // unplugged, different desk). Keep it in the list and say so, rather than
    // letting the trigger show a bare name with no explanation for why there
    // are no resolutions to pick from.
    var cur = root.effective("OUTPUT_CONNECTOR")
    if (cur !== "" && !root.monitorByName(cur))
      out.push({ value: cur, label: cur + "  ·  not connected" })
    return out
  }

  readonly property var resolutionOptions: {
    var out = [{ value: "", label: "Auto — monitor default" }]
    var listed = ({})
    var supported = root.resolutionsFor(root.activeModes)
    for (var i = 0; i < supported.length; i++) {
      listed[supported[i]] = true
      out.push({ value: supported[i], label: supported[i] + "  ·  supported" })
    }
    var presets = ["1280x720", "1920x1080", "2560x1440", "3840x2160"]
    for (var j = 0; j < presets.length; j++) {
      if (listed[presets[j]]) continue
      out.push({
        value: presets[j],
        label: presets[j] + (root.resolutionSupported(presets[j])
          ? "  ·  preset" : "  ·  preset, beyond monitor max")
      })
    }
    return out
  }

  readonly property var refreshOptions: {
    var out = [{ value: "", label: "Auto — monitor default" }]
    var listed = ({})
    // Rates at the chosen resolution first; with no resolution picked, every
    // rate the panel can do.
    var supported = root.refreshRatesFor(root.resValue)
    for (var i = 0; i < supported.length; i++) {
      listed[supported[i]] = true
      out.push({
        value: String(supported[i]),
        label: supported[i] + " Hz  ·  supported" + (root.resValue !== "" ? " at " + root.resValue : "")
      })
    }
    var presets = [240, 165, 144, 120, 100, 75, 60]
    for (var j = 0; j < presets.length; j++) {
      if (listed[presets[j]]) continue
      out.push({
        value: String(presets[j]),
        label: presets[j] + " Hz  ·  preset" + (root.refreshRateSupported(presets[j])
          ? "" : ", not reported by monitor")
      })
    }
    return out
  }

  // Every connector EXCEPT the gaming one — disabling that would be
  // self-defeating.
  readonly property var hideOptions: {
    var out = [{ value: "", label: "None — leave all monitors on" }]
    for (var i = 0; i < root.monitors.length; i++) {
      var name = String(root.monitors[i].name)
      if (name === root.activeConnector) continue
      out.push({ value: name, label: name })
    }
    var cur = root.effective("OUTPUT_CONNECTOR_TO_DISABLE")
    if (cur !== "" && !root.monitorByName(cur))
      out.push({ value: cur, label: cur + "  ·  not connected" })
    return out
  }

  readonly property var gpuOptions: {
    var out = [{ value: "auto", label: "Auto — let the system decide" }]
    var hasNvidia = false, nonNvidia = 0, i, g

    for (i = 0; i < root.gpus.length; i++) {
      if (String(root.gpus[i].kind) === "nvidia") hasNvidia = true
      else nonNvidia++
    }

    // Hybrid laptops: eDP hangs off the iGPU, games offload to the dGPU.
    if (hasNvidia && nonNvidia > 0)
      out.push({ value: "hybrid-nvidia", label: "Hybrid — NVIDIA render-offload via iGPU" })
    if (nonNvidia >= 2) {
      for (i = 0; i < root.gpus.length; i++) {
        g = root.gpus[i]
        if (String(g.kind) === "nvidia") continue
        out.push({
          value: "hybrid-amd|" + g.slot + "|" + g.vendorDev,
          label: "Hybrid — offload to " + g.label
        })
      }
    }
    for (i = 0; i < root.gpus.length; i++) {
      g = root.gpus[i]
      out.push({
        value: "direct|" + g.slot + "|" + g.vendorDev + "|" + g.kind,
        label: "Direct — " + g.label + "  ·  " + g.vendorDev
      })
    }

    // Never let the dropdown misreport what's on disk: if the saved keys
    // describe hardware we can't match, surface that rather than snapping the
    // display to "Auto".
    var cur = root.gpuValue
    for (i = 0; i < out.length; i++) if (out[i].value === cur) return out
    out.splice(1, 0, { value: cur, label: "Current setting — GPU not detected" })
    return out
  }

  // ---------------------------------------------------------- validation

  // Same two checks the TUI ran before writing: a mode the monitor never
  // reported is the usual cause of a black screen on entering Gaming Mode.
  readonly property var warnings: {
    var out = []
    if (root.activeModes.length === 0) return out
    if (root.resValue !== "" && !root.resolutionSupported(root.resValue))
      out.push("Resolution " + root.resValue + " exceeds " + root.activeConnector
               + "'s maximum of " + root.nativeRes)
    if (root.rateValue !== "" && !root.refreshRateSupported(root.rateValue))
      out.push("Refresh rate " + root.rateValue + " Hz is not in "
               + root.activeConnector + "'s reported modes (max " + root.maxRefresh + " Hz)")
    return out
  }

  // ------------------------------------------------------------ state fetch

  // One shot, one JSON object: monitors with their mode lists, GPUs from
  // lspci, and the conf file parsed into an object. Markers guard the two
  // tools we can't work without.
  readonly property string fetchScript: [
    "command -v jq >/dev/null 2>&1 || { echo '{\"error\":\"nojq\"}'; exit 0; }",
    "command -v hyprctl >/dev/null 2>&1 || { echo '{\"error\":\"nohyprctl\"}'; exit 0; }",
    "",
    "mon=\"$(hyprctl monitors all -j 2>/dev/null | jq -c '[.[] | {name: .name, modes: (.availableModes // [])}]' 2>/dev/null)\"",
    "[ -z \"$mon\" ] && mon='[]'",
    "",
    "gpus=\"$(lspci -nn 2>/dev/null | grep -iE 'vga|3d|display' | while IFS= read -r line; do",
    "  slot=$(printf '%s' \"$line\" | awk '{print $1}')",
    "  vd=$(printf '%s' \"$line\" | grep -oE '\\[[0-9a-fA-F]{4}:[0-9a-fA-F]{4}\\]' | tail -1 | tr -d '[]')",
    "  if printf '%s' \"$line\" | grep -qi nvidia; then kind=nvidia",
    "  elif printf '%s' \"$line\" | grep -qiE 'amd|advanced micro|radeon'; then kind=amd",
    "  elif printf '%s' \"$line\" | grep -qi intel; then kind=intel",
    "  else kind=other; fi",
    "  label=$(printf '%s' \"$line\" | sed -E 's/.*: //; s/ \\[[0-9a-f:]+\\] \\(rev [0-9a-f]+\\)$//; s/ \\[[0-9a-f:]+\\]$//')",
    "  jq -cn --arg s \"$slot\" --arg v \"$vd\" --arg k \"$kind\" --arg l \"$label\" \\",
    "    '{slot:$s,vendorDev:$v,kind:$k,label:$l}'",
    "done | jq -sc . 2>/dev/null)\"",
    "[ -z \"$gpus\" ] && gpus='[]'",
    "",
    "conf_file=\"$HOME/.config/environment.d/gamescope-session-plus.conf\"",
    "if [ -f \"$conf_file\" ]; then",
    "  conf=\"$(jq -Rn '[inputs | capture(\"^(?<k>[A-Za-z_][A-Za-z0-9_]*)=(?<v>.*)$\")]",
    "    | map({key: .k, value: .v}) | from_entries' < \"$conf_file\" 2>/dev/null)\"",
    "else",
    "  conf=''",
    "fi",
    "[ -z \"$conf\" ] && conf='{}'",
    "",
    "jq -cn --argjson m \"$mon\" --argjson g \"$gpus\" --argjson c \"$conf\" \\",
    "  '{monitors:$m, gpus:$g, conf:$c}'"
  ].join("\n")

  function parseFetch(raw) {
    var text = String(raw || "").trim()
    if (text === "") {
      root.fetchError = "err"
      root.loaded = true
      return
    }
    try {
      var j = JSON.parse(text)
      if (j.error) {
        root.fetchError = String(j.error)
        root.loaded = true
        return
      }
      root.monitors = j.monitors || []
      root.gpus = j.gpus || []
      root.conf = j.conf || ({})
      root.fetchError = ""
    } catch (e) {
      root.fetchError = "err"
    }
    root.loaded = true
  }

  Process {
    id: fetchProc
    command: ["sh", "-c", root.fetchScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseFetch(text)
    }
  }

  // ------------------------------------------------------------------ save

  // Takes {set:{KEY:VALUE}, unset:[KEY]} as $1. Managed keys are deleted then
  // re-appended rather than edited in place: it sidesteps every sed-delimiter
  // question about the values, and any key we don't manage (ADAPTIVE_SYNC,
  // HDR, hand-added ones) survives untouched.
  //
  // environment.d/*.conf is read by `systemd --user` at user-manager startup,
  // so a plain file write wouldn't reach gamescope-session-plus@.service until
  // the next login. set-environment/unset-environment push the change into the
  // running user manager so the very next Gaming Mode launch sees it.
  //
  // Note this is `set-environment KEY=VALUE`, not the `import-environment KEY`
  // the old TUI used: import copies the variable out of the *calling process's*
  // environment, which here holds whatever was read at login — i.e. the value
  // we just replaced. It never propagated a fresh edit at all.
  readonly property string saveScript: [
    "command -v jq >/dev/null 2>&1 || { echo 'nojq'; exit 1; }",
    "payload=\"$1\"",
    "conf_file=\"$HOME/.config/environment.d/gamescope-session-plus.conf\"",
    "mkdir -p \"$(dirname \"$conf_file\")\" || { echo 'mkdir failed'; exit 1; }",
    "touch \"$conf_file\" || { echo 'cannot write conf'; exit 1; }",
    "",
    "printf '%s' \"$payload\" | jq -r '((.unset // []) + ((.set // {}) | keys))[]' | while read -r k; do",
    "  [ -n \"$k\" ] && sed -i \"/^${k}=/d\" \"$conf_file\"",
    "done",
    "",
    "printf '%s' \"$payload\" | jq -r '(.set // {}) | to_entries[] | \"\\(.key)=\\(.value)\"' >> \"$conf_file\"",
    "",
    "printf '%s' \"$payload\" | jq -r '(.set // {}) | to_entries[] | \"\\(.key)=\\(.value)\"' | while IFS= read -r kv; do",
    "  [ -n \"$kv\" ] && systemctl --user set-environment \"$kv\" 2>/dev/null",
    "done",
    "printf '%s' \"$payload\" | jq -r '(.unset // [])[]' | while IFS= read -r k; do",
    "  [ -n \"$k\" ] && systemctl --user unset-environment \"$k\" 2>/dev/null",
    "done",
    "echo ok"
  ].join("\n")

  function save() {
    if (root.saving || !root.hasPending) return
    var unsetList = []
    for (var k in root.pendingUnset) unsetList.push(k)
    root.saving = true
    root.saveError = ""
    saveProc.command = ["sh", "-c", root.saveScript, "deckshift-save",
                        JSON.stringify({ set: root.pendingSet, unset: unsetList })]
    saveProc.running = true
  }

  function saveFinished(exitCode, stdoutText) {
    root.saving = false
    var out = String(stdoutText || "").trim()
    if (exitCode !== 0 || out.indexOf("ok") === -1) {
      root.saveError = out !== "" ? out : "save failed"
      return
    }
    // Re-read from disk rather than assuming the write landed as intended.
    root.refresh()
  }

  Process {
    id: saveProc
    stdout: StdioCollector { id: saveOut; waitForEnd: true }
    onExited: function(exitCode) { root.saveFinished(exitCode, saveOut.text) }
  }

  // ---------------------------------------------------------------- launch

  // Raise the confirm and take the keyboard back off whichever dropdown
  // trigger last had it, so the dialog's own Left/Right/Enter handling works
  // whether the user got here by click or by pressing g.
  function askLaunch() {
    if (root.fetchError !== "") return
    launchConfirm.selectedIndex = 0        // default to Cancel, not Launch
    launchConfirm.opened = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // switch-to-gaming masks sleep targets, flips the SDDM session and restarts
  // SDDM — this whole Hyprland session, shell included, dies within a second
  // of the call. An attached Process would be torn down mid-flight, so the
  // launch has to outlive us: execDetached, same reasoning as the plugin
  // manager's panelish toggles.
  function launchGamingMode() {
    launchConfirm.opened = false
    root.close()
    Quickshell.execDetached(["/usr/local/bin/switch-to-gaming"])
  }

  // ------------------------------------------------------------------- UI

  readonly property bool anyDropdownOpen:
    monitorDrop.popupOpen || resDrop.popupOpen || rateDrop.popupOpen
    || gpuDrop.popupOpen || hideDrop.popupOpen

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-deckshift"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: Math.min(Style.space(460), panel.width - Style.gapsOut * 2)
      height: Math.min(
        card.contentTopInset + card.contentBottomInset + content.implicitHeight,
        Math.min(panel.height * 0.9, panel.height - Style.bar.sizeHorizontal - Style.gapsOut * 2))
      radius: root.cornerRadius
      // Top-right, tucked under the bar — where the first-party network and
      // bluetooth popups land, and where the sibling nosignal.* panels sit.
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.topMargin: Style.bar.sizeHorizontal + Style.gapsOut
      anchors.rightMargin: Style.gapsOut
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin
      clip: true

      MouseArea { anchors.fill: parent; onClicked: {} }

      // The key handler has to be an ANCESTOR of the dropdowns, not a sibling:
      // Tab moves active focus onto a Dropdown trigger, and unhandled keys only
      // propagate up the focused item's parent chain. As a sibling it went deaf
      // the moment the user touched a dropdown — Save-by-keyboard silently
      // stopped working while the button still said otherwise.
      //
      // Keys.AfterItem (not the BeforeItem default) keeps the dropdowns in
      // charge of their own navigation: the focused child sees Tab, arrows and
      // Enter first, and only keys it doesn't accept reach the shortcuts here.
      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.AfterItem
        Keys.onPressed: function(event) {
          // The launch confirm owns the keyboard while it's up.
          if (launchConfirm.opened) {
            if (launchConfirm.handleKey(event)) event.accepted = true
            return
          }
          // An open dropdown popup drives its own list — don't double-handle.
          if (root.anyDropdownOpen) return

          if (event.key === Qt.Key_Escape || event.key === Qt.Key_Q) {
            root.close()
            event.accepted = true
          } else if (event.key === Qt.Key_R || event.key === Qt.Key_F5) {
            root.refresh()
            event.accepted = true
          } else if (event.key === Qt.Key_S) {
            root.save()
            event.accepted = true
          } else if (event.key === Qt.Key_G) {
            root.askLaunch()
            event.accepted = true
          }
        }

        Column {
          id: content
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.topMargin: card.contentTopInset
          anchors.leftMargin: card.contentLeftInset
          anchors.rightMargin: card.contentRightInset
          spacing: root.rowSpacing

          // ---- header ------------------------------------------------------
          Item {
            width: parent.width
            height: root.headerHeight

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "󰊴  Gaming Mode"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.hasPending ? "unsaved changes · s save" : "esc close · r refresh · g launch"
              color: root.hasPending ? root.accent : root.foreground
              opacity: root.hasPending ? 1.0 : 0.45
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: root.hasPending
            }
          }

          // ---- loading / fetch failure -------------------------------------
          Text {
            width: parent.width
            visible: !root.loaded || root.fetchError !== ""
            text: !root.loaded ? "Reading hardware…"
                : root.fetchError === "nojq" ? "jq is required for this panel"
                : root.fetchError === "nohyprctl" ? "hyprctl not found — this panel needs a Hyprland session"
                : "Couldn't read display or GPU state"
            color: root.fetchError !== "" && root.loaded ? root.urgent : root.foreground
            opacity: root.fetchError !== "" && root.loaded ? 1.0 : 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            wrapMode: Text.WordWrap
          }

          // ---- settings -----------------------------------------------------
          Column {
            width: parent.width
            visible: root.loaded && root.fetchError === ""
            spacing: root.rowSpacing

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "DISPLAY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Dropdown {
              id: monitorDrop
              width: parent.width
              label: "Monitor"
              fontFamily: root.fontFamily
              options: root.monitorOptions
              value: root.effective("OUTPUT_CONNECTOR")
              onChanged: function(v) {
                if (v === "") root.unsetPending("OUTPUT_CONNECTOR")
                else root.setPending("OUTPUT_CONNECTOR", v)
              }
            }

            Dropdown {
              id: resDrop
              width: parent.width
              label: root.nativeRes !== "" ? "Resolution  (monitor max " + root.nativeRes + ")" : "Resolution"
              fontFamily: root.fontFamily
              options: root.resolutionOptions
              value: root.resValue
              onChanged: function(v) {
                if (v === "") {
                  root.unsetPending("SCREEN_WIDTH")
                  root.unsetPending("SCREEN_HEIGHT")
                } else {
                  var wh = v.split("x")
                  root.setPending("SCREEN_WIDTH", wh[0])
                  root.setPending("SCREEN_HEIGHT", wh[1])
                }
              }
            }

            Dropdown {
              id: rateDrop
              width: parent.width
              label: root.maxRefresh > 0 ? "Refresh rate  (monitor max " + root.maxRefresh + " Hz)" : "Refresh rate"
              fontFamily: root.fontFamily
              options: root.refreshOptions
              value: root.rateValue
              onChanged: function(v) {
                if (v === "") { root.unsetPending("CUSTOM_REFRESH_RATES"); return }
                // gamescope reads this as --custom-refresh-rates: a list of
                // rates Steam can switch between, not a single mode. Writing
                // only the high rate can leave it with no safe fallback when
                // the EDID preferred mode is 60Hz and the high mode isn't
                // enumerated on first launch — the NVIDIA-over-HDMI black
                // screen from v0.1.8. Always keep 60 as the floor.
                root.setPending("CUSTOM_REFRESH_RATES", v === "60" ? "60" : "60," + v)
              }
            }

            Dropdown {
              id: hideDrop
              width: parent.width
              label: "Disable while gaming"
              fontFamily: root.fontFamily
              options: root.hideOptions
              value: root.effective("OUTPUT_CONNECTOR_TO_DISABLE")
              onChanged: function(v) {
                if (v === "") root.unsetPending("OUTPUT_CONNECTOR_TO_DISABLE")
                else root.setPending("OUTPUT_CONNECTOR_TO_DISABLE", v)
              }
            }

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "GPU"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Dropdown {
              id: gpuDrop
              width: parent.width
              label: "Render device"
              fontFamily: root.fontFamily
              options: root.gpuOptions
              value: root.gpuValue
              onChanged: function(v) { root.applyGpuMode(v) }
            }
          }

          // ---- warnings -----------------------------------------------------
          Column {
            width: parent.width
            visible: root.warnings.length > 0 || root.saveError !== ""
            spacing: Style.spacing.xs

            Repeater {
              model: root.warnings
              delegate: Text {
                required property string modelData
                width: content.width
                text: "!  " + modelData
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            Text {
              visible: root.saveError !== ""
              width: content.width
              text: "!  Save failed: " + root.saveError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---- actions ------------------------------------------------------
          Item {
            width: parent.width
            height: launchButton.implicitHeight + card.contentBottomInset

            Button {
              id: saveButton
              anchors.left: parent.left
              anchors.top: parent.top
              text: root.saving ? "Saving…" : "Save"
              bordered: true
              enabled: root.hasPending && !root.saving && root.fetchError === ""
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              opacity: enabled ? 1.0 : 0.4
              onClicked: root.save()
            }

            Button {
              id: launchButton
              anchors.right: parent.right
              anchors.top: parent.top
              text: "󰊴  Launch Gaming Mode"
              bordered: true
              enabled: root.fetchError === ""
              foreground: root.accent
              accent: root.accent
              fontFamily: root.fontFamily
              opacity: enabled ? 1.0 : 0.4
              onClicked: root.askLaunch()
            }
          }
        }
      }

      // Launching restarts SDDM and takes the desktop session with it, so it
      // always goes through a confirm — and says so plainly when the settings
      // on screen aren't the ones Gaming Mode would actually use.
      ConfirmDialog {
        id: launchConfirm
        anchors.fill: parent
        message: root.hasPending
          ? "Launch Gaming Mode now? Your desktop session will close.\n\nYou have unsaved changes — Gaming Mode will start with the last saved settings, not the ones shown here."
          : "Launch Gaming Mode now? Your desktop session will close and Steam Big Picture will start."
        cancelText: "Cancel"
        confirmText: "Launch"
        background: root.background
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: {
          launchConfirm.opened = false
          Qt.callLater(function() { keyCatcher.forceActiveFocus() })
        }
        onConfirmed: root.launchGamingMode()
      }
    }
  }
}

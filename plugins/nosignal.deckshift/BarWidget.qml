import QtQuick
import qs.Commons
import qs.Ui

// Bar icon for the DeckShift panel. Clicking runs the same IPC route the
// SUPER+ALT+G keybinding uses (omarchy-shell shell toggle …), mirroring how
// the first-party omarchy.menu bar widget summons its panel.
//
// Static icon only — no polling while the panel is closed. The widget
// deliberately does NOT launch Gaming Mode: entering Gaming Mode tears down
// the whole Hyprland session, which is not something a single stray bar click
// should ever do. That action lives behind the panel's confirm step.
BarWidget {
  id: root
  moduleName: "nosignal.deckshift"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰊴"
    tooltipText: "Gaming Mode"
    foreground: Color.accent
    fixedWidth: root.bar && root.bar.vertical ? -1 : Style.space(27)
    fixedHeight: root.bar && root.bar.vertical ? Style.space(26) : -1
    onPressed: function(b) {
      if (!root.bar) return
      root.bar.run("omarchy-shell shell toggle nosignal.deckshift")
    }
  }
}

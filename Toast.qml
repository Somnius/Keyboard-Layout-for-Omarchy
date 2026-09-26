import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Top-center layout toast. Follows Omarchy's OSD surface (overlay layer, no
// keyboard focus, empty input mask so it never takes a click), but anchors
// to the top edge and respects the bar's exclusive zone, so it sits just
// below the bar on whichever monitor it is given.
PanelWindow {
  id: root

  property string abbr: ""
  property string keymap: ""
  property bool shown: false

  anchors { top: true; left: true; right: true }
  implicitHeight: card.height + Style.space(24)
  color: "transparent"
  WlrLayershell.namespace: "lef-keyboard-layout-toast"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Normal
  exclusiveZone: 0
  mask: Region {}

  readonly property int pad: Style.space(14)

  BorderSurface {
    id: card
    width: card.borderLeft + root.pad + content.implicitWidth + root.pad + card.borderRight
    height: card.borderTop + root.pad + content.implicitHeight + root.pad + card.borderBottom
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: parent.top
    anchors.topMargin: Style.space(12)
    color: Util.alpha(Color.background, 0.97)
    borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
    radius: Style.cornerRadius
    opacity: root.shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 120 } }

    Row {
      id: content
      x: card.borderLeft + root.pad
      y: card.borderTop + root.pad
      spacing: Style.space(12)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.abbr !== "" ? root.abbr : "⌨"
        textFormat: Text.PlainText
        color: Color.accent
        font.family: Style.font.family
        font.bold: true
        font.pixelSize: Style.font.displayLarge
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.keymap
        textFormat: Text.PlainText
        color: Color.popups.text
        font.family: Style.font.family
        font.bold: true
        font.pixelSize: Style.font.title
        elide: Text.ElideRight
        width: Math.min(implicitWidth, Style.space(320))
      }
    }
  }
}

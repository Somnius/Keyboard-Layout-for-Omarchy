import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "lef.keyboard-layout"

  readonly property var service: bar && bar.shell
    ? bar.shell.serviceFor(root.moduleName) : null
  readonly property bool ready: service !== null && service.loaded
  readonly property string displayName: ready && service.currentAbbr !== ""
    ? service.currentAbbr : "⌨"

  implicitWidth: glyph.implicitWidth + Style.space(12)
  implicitHeight: barSize

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    target.bar = root.bar
    target.anchorItem = root
    target.hostWidget = root
    target.service = root.service
  }

  onBarChanged: injectPanel()
  onServiceChanged: injectPanel()

  Text {
    id: glyph
    anchors.centerIn: parent
    text: root.displayName
    textFormat: Text.PlainText
    color: root.bar ? root.bar.barForeground : Color.foreground
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.body
    opacity: root.ready ? 1 : 0.45
    Behavior on color {
      enabled: !root.bar || root.bar.foregroundAnimationEnabled
      ColorAnimation { duration: 160 }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton

    onClicked: function (mouse) {
      if (!root.ready) return
      if (mouse.button === Qt.RightButton) {
        // Switch immediately, no panel.
        root.service.nextLayout()
      } else {
        root.toggle()
      }
    }
    onEntered: if (root.bar) root.bar.showTooltip(root,
      root.ready && service.currentKeymap !== "" ? service.currentKeymap : "Keyboard Layout")
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // First-run: ask where the widget should live, exactly once.
  Timer {
    interval: 1500
    running: root.ready && root.service.askedState === -1
    onTriggered: if (root.service.askedState === -1) root.open()
  }

  IpcHandler {
    target: root.moduleName

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function next(): void { if (root.ready) root.service.nextLayout() }
    function place(section: string): string {
      if (!root.ready) return "service not ready"
      if (section !== "center" && section !== "right") return "use center or right"
      root.service.place(section)
      return "moving to " + section
    }
    function status(): string {
      if (!root.ready) return "service not ready"
      return JSON.stringify({
        keyboard: root.service.keyboardName,
        keymap: root.service.currentKeymap,
        abbr: root.service.currentAbbr,
        layouts: root.service.layouts,
        hotkey: root.service.hotkey,
        led: root.service.led,
        placement: root.service.placement,
        askedState: root.service.askedState
      })
    }
  }
}

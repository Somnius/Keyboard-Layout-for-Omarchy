import QtQuick
import Quickshell
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
  readonly property color baseColor: root.bar ? root.bar.barForeground : Color.foreground
  readonly property bool highlighted: ready && service.highlightEnabled && !service.onMainLayout

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

  // The screen this bar sits on, so the service's IPC can open the panel on
  // the focused monitor when several bars carry the widget.
  readonly property string screenName: root.QsWindow.window && root.QsWindow.window.screen
    ? root.QsWindow.window.screen.name : ""
  property var registeredWith: null

  function register() {
    if (root.registeredWith === root.service) return
    if (root.registeredWith) root.registeredWith.unregisterPanelHost(root)
    root.registeredWith = root.service
    if (root.service) root.service.registerPanelHost(root)
  }

  onBarChanged: injectPanel()
  onServiceChanged: {
    injectPanel()
    register()
  }
  Component.onCompleted: register()
  Component.onDestruction: if (root.registeredWith) root.registeredWith.unregisterPanelHost(root)

  Text {
    id: glyph
    anchors.centerIn: parent
    text: root.displayName
    textFormat: Text.PlainText
    color: root.highlighted ? Color.accent : root.baseColor
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
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    // A wheel notch or touchpad swipe yields a burst of events; switch at
    // most once per burst window so one flick is one layout.
    property real lastWheel: 0

    onClicked: function (mouse) {
      if (!root.ready) return
      if (mouse.button === Qt.RightButton) root.service.nextLayout()
      else if (mouse.button === Qt.MiddleButton) root.service.mainLayout()
      else root.toggle()
    }
    onWheel: function (wheel) {
      if (!root.ready) return
      var delta = wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.angleDelta.x
      var now = Date.now()
      if (delta === 0 || now - lastWheel < 150) return
      lastWheel = now
      if (delta < 0) root.service.nextLayout()
      else root.service.prevLayout()
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
}

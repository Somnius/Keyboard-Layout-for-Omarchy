import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "lef.keyboard-layout"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  readonly property var barIdentity: hostWidget || root
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var layoutChoices: [
    "us", "gr", "de", "fr", "es", "it", "pt", "nl", "pl",
    "se", "no", "fi", "dk", "cz", "hu", "ro", "bg", "ua",
    "ru", "tr", "ara", "jp", "kr", "cn", "il"
  ]
  readonly property var secondChoices: ["(none)"].concat(layoutChoices)
  readonly property var hotkeyChoices: ["caps", "alt+shift", "ctrl+shift"]

  // Panel-local selection state, seeded from the service.
  property string primarySel: ""
  property string secondSel: "(none)"
  property string hotkeySel: "caps"
  property bool ledSel: true
  property bool seeded: false

  function seed() {
    if (seeded || !service || !service.loaded) return
    primarySel = service.layouts.length > 0 ? service.layouts[0] : "us"
    secondSel = service.layouts.length > 1 ? service.layouts[1] : "(none)"
    hotkeySel = service.hotkey
    ledSel = service.led
    seeded = true
  }

  function open() {
    seeded = false
    if (service) service.refresh()
    controller.show()
  }

  function close() { controller.hide() }
  function toggle() { opened ? close() : open() }

  onOpenedChanged: if (opened) seed()
  Component.onCompleted: seed()

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      ColumnLayout {
        id: content
        anchors.fill: parent
        spacing: Style.space(12)

        PanelHero {
          Layout.fillWidth: true
          title: "Keyboard Layout"
          meta: root.service ? root.service.statusText() : "Service unavailable"
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconComponent: Component {
            Text {
              text: "⌨"
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

        PanelSectionHeader {
          Layout.fillWidth: true
          text: root.service && root.service.askedState === -1 ? "WHERE SHOULD THE WIDGET LIVE?" : "PLACEMENT"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Dropdown {
            Layout.fillWidth: true
            label: "Bar section"
            value: root.service ? root.service.placement : "right"
            options: ["center", "right"]
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: root.service !== null
            onChanged: function (value) { if (root.service) root.service.place(value) }
          }
        }

        Text {
          Layout.fillWidth: true
          text: "Center parks the widget right after the clock. The left section is not offered. Moving triggers a Hyprland + shell reload."
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          Layout.fillWidth: true
          visible: root.service && root.service.lastPlaceAction !== ""
          text: root.service ? root.service.lastPlaceAction : ""
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        PanelSectionHeader {
          Layout.fillWidth: true
          text: "ACTIVE"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Text {
          Layout.fillWidth: true
          text: root.service && root.service.currentKeymap !== ""
            ? root.service.currentKeymap : "Unknown"
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Button {
          Layout.fillWidth: true
          text: "Switch to next layout"
          iconText: "󰌌"
          bordered: true
          focusable: true
          enabled: root.service && root.service.layouts.length > 1
          foreground: root.foreground
          accent: Color.accent
          fontFamily: root.fontFamily
          onClicked: if (root.service) root.service.nextLayout()
        }

        PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

        PanelSectionHeader {
          Layout.fillWidth: true
          text: "LAYOUTS"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Dropdown {
            Layout.fillWidth: true
            label: "Primary"
            value: root.primarySel
            options: root.layoutChoices
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function (value) { root.primarySel = value }
          }

          Dropdown {
            Layout.fillWidth: true
            label: "Second"
            value: root.secondSel
            options: root.secondChoices
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function (value) { root.secondSel = value }
          }
        }

        Text {
          Layout.fillWidth: true
          visible: root.primarySel === root.secondSel
          text: "Primary and Second are the same layout."
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        PanelSectionHeader {
          Layout.fillWidth: true
          text: "SWITCH HOTKEY"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Dropdown {
            Layout.fillWidth: true
            label: "Hotkey"
            value: root.hotkeySel
            options: root.hotkeyChoices
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function (value) { root.hotkeySel = value }
          }

          Toggle {
            Layout.fillWidth: true
            label: "Caps LED shows 2nd layout"
            description: root.hotkeySel === "caps"
              ? "Caps Lock toggles; LED lights on the second layout."
              : "LED option only applies with Caps Lock."
            checked: root.ledSel
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily
            enabled: root.hotkeySel === "caps"
            onClicked: root.ledSel = !root.ledSel
          }
        }

        Text {
          Layout.fillWidth: true
          text: "Super+Space is not offered — Omarchy uses it for the app launcher. Alt+Shift and Ctrl+Shift are safe Hyprland toggle options."
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

        Button {
          Layout.fillWidth: true
          text: "Apply & reload Hyprland"
          iconText: "󰐊"
          bordered: true
          focusable: true
          enabled: root.service !== null && root.primarySel !== root.secondSel
          foreground: root.foreground
          accent: Color.accent
          fontFamily: root.fontFamily
          onClicked: if (root.service)
            root.service.applySettings(root.primarySel, root.secondSel, root.hotkeySel, root.ledSel)
        }

        Text {
          Layout.fillWidth: true
          visible: root.service && root.service.lastError !== ""
          text: root.service ? root.service.lastError : ""
          textFormat: Text.PlainText
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          Layout.fillWidth: true
          visible: root.service && root.service.lastAction !== "" && root.service.lastError === ""
          text: root.service ? root.service.lastAction : ""
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          Layout.fillWidth: true
          text: "Edits ~/.config/hypr/input.lua directly. A one-time backup is kept at input.lua.bak.<timestamp> before the first write."
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

        Button {
          Layout.fillWidth: true
          text: "Source code · MIT license"
          bordered: true
          focusable: true
          enabled: root.service !== null
          foreground: root.foreground
          accent: Color.accent
          fontFamily: root.fontFamily
          onClicked: {
            // Ui Panel scope refuses Quickshell.Io Process; go through the service.
            if (root.service) openRepo()
          }

          function openRepo() {
            Qt.openUrlExternally(root.service.repoUrl)
          }
        }
      }
    }
  }
}

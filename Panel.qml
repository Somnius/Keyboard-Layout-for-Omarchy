import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "ServiceLogic.js" as Logic

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

  // Panel-local draft, seeded from the service: [{ layout, variant }].
  property var layoutsSel: []
  property string hotkeySel: "grp:caps_toggle"
  property bool ledSel: true
  property bool seeded: false
  // Search dropdowns own the keyboard while their popup is open.
  property int openPopups: 0
  property string restoreId: ""
  property bool applyConfirmOpen: false

  readonly property var hotkeyOptions: {
    var list = root.service ? root.service.hotkeyChoices.slice() : []
    var current = root.service ? root.service.hotkey : ""
    var known = list.some(function (o) { return o.value === current })
    if (current !== "" && !known) list.push({ value: current, label: "Custom (" + current + ") — keep" })
    return list
  }
  readonly property int maxLayouts: root.service ? root.service.maxLayouts : 4

  function seed() {
    if (seeded || !service || !service.loaded) return
    layoutsSel = service.layouts.slice(0, maxLayouts).map(function (l) {
      return { layout: l.layout, variant: l.variant }
    })
    if (layoutsSel.length === 0) layoutsSel = [{ layout: "us", variant: "" }]
    hotkeySel = service.hotkey
    ledSel = service.led
    seeded = true
  }

  function open() {
    seeded = false
    if (service) {
      service.refresh()
      service.listBackups()
    }
    controller.show()
  }

  function close() { controller.hide() }
  function toggle() { opened ? close() : open() }

  onOpenedChanged: if (opened) seed()
  Component.onCompleted: seed()

  // input.lua is the source of truth: when it changes (Apply, Restore, or an
  // edit elsewhere) the draft follows it.
  Connections {
    target: root.service
    function onLayoutsChanged() { root.seeded = false; root.seed() }
    function onHotkeyChanged() { root.seeded = false; root.seed() }
    function onLedChanged() { root.seeded = false; root.seed() }
  }

  function specOf(entry) {
    return service ? service.layoutSpec(entry) : ""
  }

  function parseSpec(spec) {
    var match = String(spec).match(/^([A-Za-z0-9_+-]+)(?:\(([A-Za-z0-9_+-]+)\))?$/)
    return match ? { layout: match[1], variant: match[2] || "" } : null
  }

  function setLayoutAt(index, spec) {
    var entry = parseSpec(spec)
    if (!entry) return
    var next = layoutsSel.slice()
    next[index] = entry
    layoutsSel = next
  }

  function addLayout(spec) {
    var entry = parseSpec(spec)
    if (!entry || layoutsSel.length >= maxLayouts) return
    layoutsSel = layoutsSel.concat([entry])
  }

  function removeLayout(index) {
    if (layoutsSel.length <= 1) return
    var next = layoutsSel.slice()
    next.splice(index, 1)
    layoutsSel = next
  }

  function moveLayout(index, delta) {
    var target = index + delta
    if (target < 0 || target >= layoutsSel.length) return
    var next = layoutsSel.slice()
    var item = next[index]
    next[index] = next[target]
    next[target] = item
    layoutsSel = next
  }

  function hasDuplicates() {
    var seen = {}
    for (var i = 0; i < layoutsSel.length; i++) {
      var key = "$" + specOf(layoutsSel[i])
      if (seen[key]) return true
      seen[key] = true
    }
    return false
  }

  function isDirty() {
    if (!service) return false
    var current = service.layouts.slice(0, maxLayouts).map(specOf).join(",")
    return current !== layoutsSel.map(specOf).join(",")
      || hotkeySel !== service.hotkey
      || (hotkeySel === "grp:caps_toggle" && ledSel !== service.led)
  }

  function mainRisksPasswords() {
    return Logic.mainLayoutRisksPasswords(layoutsSel)
  }

  function requestApply() {
    if (!service) return
    if (Logic.needsPasswordConfirm(service.layouts, layoutsSel)) applyConfirmOpen = true
    else service.applySettings(layoutsSel, hotkeySel, ledSel)
  }

  function mainDescription() {
    return layoutsSel.length > 0 && service ? service.layoutDescription(layoutsSel[0]) : ""
  }

  function backupLabel(row) {
    var when = Qt.formatDateTime(new Date(row.time * 1000), "yyyy-MM-dd HH:mm")
    // A file with no live kb_layout leaves Omarchy's defaults in charge.
    var what = row.valid ? (row.layouts !== "" ? row.layouts : "defaults") : "unreadable"
    return (row.kind === "original" ? "orig " : "") + when + " · " + what
  }

  // Settings sit side by side instead of in one tall column, so the panel
  // stays short enough for small screens. The column count follows the
  // room the screen leaves: three columns normally, fewer on narrow ones.
  readonly property int columnWidth: Style.space(290)
  readonly property int columnGap: Style.space(24)
  readonly property int columns: {
    var room = panel.availableCardWidth - panel.padding * 2 - Style.space(8)
    if (room <= 0) return 3
    var fit = Math.floor((room + columnGap) / (columnWidth + columnGap))
    return Math.max(1, Math.min(3, fit))
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(
      root.columns * root.columnWidth + (root.columns - 1) * root.columnGap)
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.openPopups > 0
      onCloseRequested: {
        if (restoreConfirm.opened) root.restoreId = ""
        else if (applyConfirm.opened) root.applyConfirmOpen = false
        else root.close()
      }
      onActivateRequested: {
        if (restoreConfirm.opened) restoreConfirm.confirmed()
        else if (applyConfirm.opened) applyConfirm.confirmed()
      }

      // Only scrolls when even the column layout cannot fit the screen.
      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick

        ColumnLayout {
          id: content
          width: scroller.width
          spacing: Style.space(12)

          // ------------------------------------------------- top strip
          GridLayout {
            Layout.fillWidth: true
            columns: root.columns > 1 ? 3 : 1
            columnSpacing: Style.space(16)
            rowSpacing: Style.space(8)

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

            ColumnLayout {
              Layout.alignment: Qt.AlignVCenter
              spacing: Style.space(2)

              Text {
                text: "ACTIVE"
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                Layout.maximumWidth: root.columnWidth
                text: root.service && root.service.currentKeymap !== ""
                  ? root.service.currentKeymap : "Unknown"
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
              }
            }

            RowLayout {
              Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
              spacing: Style.space(8)

              Button {
                text: "Previous"
                tooltipText: "Bar: scroll up"
                bordered: true
                focusable: true
                enabled: root.service !== null && root.service.layouts.length > 1
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                onClicked: if (root.service) root.service.prevLayout()
              }

              Button {
                text: "Next"
                iconText: "󰌌"
                tooltipText: "Bar: right-click or scroll down"
                bordered: true
                focusable: true
                enabled: root.service !== null && root.service.layouts.length > 1
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                onClicked: if (root.service) root.service.nextLayout()
              }
            }
          }

          PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

          GridLayout {
            Layout.fillWidth: true
            columns: root.columns
            columnSpacing: root.columnGap
            rowSpacing: Style.space(16)

            // ------------------------------------------- column: layouts
            ColumnLayout {
              Layout.fillWidth: true
              Layout.preferredWidth: root.columnWidth
              Layout.alignment: Qt.AlignTop
              spacing: Style.space(8)

              PanelSectionHeader {
                Layout.fillWidth: true
                text: "LAYOUTS (" + root.layoutsSel.length + " OF " + root.maxLayouts + ")"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: root.layoutsSel.length

                delegate: RowLayout {
                  id: layoutRow
                  required property int index
                  Layout.fillWidth: true
                  spacing: Style.space(6)

                  Text {
                    Layout.preferredWidth: Style.space(14)
                    text: String(layoutRow.index + 1)
                    textFormat: Text.PlainText
                    color: layoutRow.index === 0 ? Color.accent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: layoutRow.index === 0
                  }

                  SearchableDropdown {
                    Layout.fillWidth: true
                    showLabel: false
                    label: layoutRow.index === 0 ? "Main layout" : "Layout " + (layoutRow.index + 1)
                    value: root.specOf(root.layoutsSel[layoutRow.index])
                    options: root.service ? root.service.catalogOptions : []
                    placeholderText: "Search layouts…"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onChanged: function (value) { root.setLayoutAt(layoutRow.index, value) }
                    onPopupOpenChanged: root.openPopups += popupOpen ? 1 : -1
                  }

                  Button {
                    text: "↑"
                    tooltipText: "Move up"
                    bordered: true
                    enabled: layoutRow.index > 0
                    foreground: root.foreground
                    accent: Color.accent
                    fontFamily: root.fontFamily
                    onClicked: root.moveLayout(layoutRow.index, -1)
                  }

                  Button {
                    text: "↓"
                    tooltipText: "Move down"
                    bordered: true
                    enabled: layoutRow.index < root.layoutsSel.length - 1
                    foreground: root.foreground
                    accent: Color.accent
                    fontFamily: root.fontFamily
                    onClicked: root.moveLayout(layoutRow.index, 1)
                  }

                  Button {
                    text: "✕"
                    tooltipText: "Remove"
                    bordered: true
                    enabled: root.layoutsSel.length > 1
                    foreground: root.foreground
                    accent: Color.accent
                    fontFamily: root.fontFamily
                    onClicked: root.removeLayout(layoutRow.index)
                  }
                }
              }

              SearchableDropdown {
                Layout.fillWidth: true
                visible: root.layoutsSel.length < root.maxLayouts
                showLabel: false
                label: "Add layout"
                value: ""
                triggerLabel: "+ Add a layout…"
                options: root.service ? root.service.catalogOptions : []
                placeholderText: "Search layouts…"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onChanged: function (value) { root.addLayout(value) }
                onPopupOpenChanged: root.openPopups += popupOpen ? 1 : -1
              }

              Text {
                Layout.fillWidth: true
                text: "1 is the main layout. The toast shows at the top center; other kb_options in input.lua are kept."
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Text {
                Layout.fillWidth: true
                visible: root.mainRisksPasswords()
                text: "⚠ Main layout is " + root.mainDescription() + ", not English (US). "
                  + "Password prompts that start on the main layout (hyprlock, new sessions) "
                  + "will type its characters, so a password typed on English (US) may not work. "
                  + "Keep English (US) as layout 1 unless you type passwords on this layout."
                textFormat: Text.PlainText
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Text {
                Layout.fillWidth: true
                visible: root.hasDuplicates()
                text: "The same layout is listed twice."
                textFormat: Text.PlainText
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                Layout.fillWidth: true
                visible: root.service !== null && root.service.layouts.length > root.maxLayouts
                text: "input.lua lists " + (root.service ? root.service.layouts.length : 0)
                  + " layouts; xkb only uses " + root.maxLayouts + ". Applying keeps the ones shown."
                textFormat: Text.PlainText
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            // ------------------------------ column: switch key and display
            ColumnLayout {
              Layout.fillWidth: true
              Layout.preferredWidth: root.columnWidth
              Layout.alignment: Qt.AlignTop
              spacing: Style.space(8)

              PanelSectionHeader {
                Layout.fillWidth: true
                text: "SWITCH KEY"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Dropdown {
                Layout.fillWidth: true
                showLabel: false
                label: "Switch key"
                value: root.hotkeySel
                options: root.hotkeyOptions
                foreground: root.foreground
                fontFamily: root.fontFamily
                onChanged: function (value) { root.hotkeySel = value }
              }

              Toggle {
                Layout.fillWidth: true
                label: "Caps LED off main"
                checked: root.ledSel && root.hotkeySel === "grp:caps_toggle"
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                enabled: root.hotkeySel === "grp:caps_toggle"
                onClicked: root.ledSel = !root.ledSel
              }

              Button {
                Layout.fillWidth: true
                text: root.isDirty() ? "Apply & reload Hyprland" : "Apply (no changes)"
                iconText: "󰐊"
                bordered: true
                focusable: true
                enabled: root.service !== null && root.layoutsSel.length > 0 && !root.hasDuplicates()
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                onClicked: root.requestApply()
              }

              Text {
                Layout.fillWidth: true
                visible: root.service !== null && root.service.lastError !== ""
                text: root.service ? root.service.lastError : ""
                textFormat: Text.PlainText
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Text {
                Layout.fillWidth: true
                visible: root.service !== null && root.service.lastAction !== "" && root.service.lastError === ""
                text: root.service ? root.service.lastAction : ""
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              PanelSectionHeader {
                Layout.fillWidth: true
                Layout.topMargin: Style.space(8)
                text: "DISPLAY"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Toggle {
                Layout.fillWidth: true
                label: "Toast on switch"
                checked: root.service !== null && root.service.toastEnabled
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                enabled: root.service !== null
                onClicked: root.service.setToast(!root.service.toastEnabled)
              }

              Toggle {
                Layout.fillWidth: true
                label: "Accent off main"
                checked: root.service !== null && root.service.highlightEnabled
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                enabled: root.service !== null
                onClicked: root.service.setHighlight(!root.service.highlightEnabled)
              }

              Dropdown {
                Layout.fillWidth: true
                label: root.service && root.service.askedState === -1 ? "Where should it live?" : "Bar section"
                value: root.service ? root.service.placement : "right"
                options: ["center", "right"]
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: root.service !== null
                onChanged: function (value) { if (root.service) root.service.place(value) }
              }

              Text {
                Layout.fillWidth: true
                text: root.service && root.service.lastPlaceAction !== ""
                  ? root.service.lastPlaceAction
                  : "Center sits right after the clock."
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            // ------------------------------------------- column: backups
            ColumnLayout {
              Layout.fillWidth: true
              Layout.preferredWidth: root.columnWidth
              Layout.alignment: Qt.AlignTop
              spacing: Style.space(6)

              PanelSectionHeader {
                Layout.fillWidth: true
                text: "BACKUPS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                Layout.fillWidth: true
                text: "Taken before every Apply or Restore, or by hand; newest 10 kept. Originals (input.lua.bak.*) are never removed."
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)

                Button {
                  Layout.fillWidth: true
                  text: "Back up now"
                  iconText: "󰆓"
                  bordered: true
                  focusable: true
                  enabled: root.service !== null
                  foreground: root.foreground
                  accent: Color.accent
                  fontFamily: root.fontFamily
                  onClicked: root.service.backupNow()
                }

                Button {
                  Layout.fillWidth: true
                  text: "Open folder"
                  iconText: "󰉋"
                  tooltipText: "~/.config/omarchy/keyboard-layout/backups"
                  bordered: true
                  focusable: true
                  enabled: root.service !== null
                  foreground: root.foreground
                  accent: Color.accent
                  fontFamily: root.fontFamily
                  onClicked: {
                    root.service.openBackupFolder()
                    root.close()
                  }
                }
              }

              Text {
                Layout.fillWidth: true
                visible: root.service !== null && root.service.backups.length === 0
                text: "No backups yet."
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Repeater {
                model: root.service ? root.service.backups : []

                delegate: RowLayout {
                  id: backupRow
                  required property var modelData
                  Layout.fillWidth: true
                  spacing: Style.space(6)

                  Text {
                    Layout.fillWidth: true
                    text: root.backupLabel(backupRow.modelData)
                    textFormat: Text.PlainText
                    color: backupRow.modelData.valid ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }

                  Button {
                    text: "Restore"
                    bordered: true
                    enabled: backupRow.modelData.valid
                    foreground: root.foreground
                    accent: Color.accent
                    fontFamily: root.fontFamily
                    onClicked: root.restoreId = backupRow.modelData.id
                  }
                }
              }

              Text {
                Layout.fillWidth: true
                visible: root.service !== null && root.service.lastBackupAction !== ""
                text: root.service ? root.service.lastBackupAction : ""
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Button {
                Layout.fillWidth: true
                Layout.topMargin: Style.space(8)
                text: "Source code · MIT license"
                bordered: true
                focusable: true
                enabled: root.service !== null
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                // Ui Panel scope refuses Quickshell.Io Process; open through Qt.
                onClicked: if (root.service) Qt.openUrlExternally(root.service.repoUrl)
              }
            }
          }
        }
      }

      ConfirmDialog {
        id: applyConfirm
        anchors.fill: parent
        z: 10
        opened: root.applyConfirmOpen
        message: "Make " + root.mainDescription() + " the main layout? Password prompts that "
          + "start on the main layout (hyprlock, new sessions) will type its characters, so a "
          + "password you type on English (US) may be rejected. Keep a way back: Caps Lock, "
          + "the bar or a backup restore."
        confirmText: "Apply anyway"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.applyConfirmOpen = false
        onConfirmed: {
          root.applyConfirmOpen = false
          if (root.service) root.service.applySettings(root.layoutsSel, root.hotkeySel, root.ledSel)
        }
      }

      ConfirmDialog {
        id: restoreConfirm
        anchors.fill: parent
        z: 10
        opened: root.restoreId !== ""
        message: "Replace input.lua with backup " + root.restoreId
          + "? The current file is backed up first, then Hyprland reloads."
        confirmText: "Restore"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.restoreId = ""
        onConfirmed: {
          var id = root.restoreId
          root.restoreId = ""
          if (root.service) root.service.restoreBackup(id)
        }
      }
    }
  }
}

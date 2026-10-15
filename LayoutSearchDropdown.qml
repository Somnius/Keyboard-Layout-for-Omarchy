import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "ServiceLogic.js" as Logic

// Omarchy's Ui/SearchableDropdown.qml (omarchy 4.0.4, MIT) with one change:
// the search box is not a text field. Every editable Qt text input hooks
// the clipboard when it is created, even hidden, and can pull another
// application's offered text through paste, Shift+Insert or middle-click.
// The panel stays loaded, so its fields always exist. This box is a plain
// item that builds the query from typed keys (ServiceLogic searchTyped):
// it has no paste, selection or input method path and never touches the
// clipboard. Dead keys and IME composition are not supported; type the
// plain letter. The query stops at maxQueryLength characters.
//
// Searchable single-select dropdown. Same trigger shape as Dropdown, but
// the popup leads with an embedded search box that filters the option
// list in real time. Use for pickers with enough options that scanning
// is friction.
//
// Filtering is case-insensitive substring against each option's label.
// Options can be string[] or [{ value, label, description? }] — the same
// shape Dropdown accepts. The filter clears whenever the popup closes.
//
// Keyboard: Tab to focus the trigger, Enter/Space opens (search focused
// immediately). Down arrow from the search jumps to the first match;
// Up from the first match returns to the search. Enter selects, Esc
// closes (and clears the filter).
Item {
  id: root

  property string label: ""
  property string value: ""
  property var options: []
  property string placeholderText: "Search..."
  property string emptyText: "No matches"
  property string triggerLabel: ""

  property color foreground: Commons.Color.popups.text
  property color background: Commons.Color.popups.background
  property color popupBorder: Commons.Color.popups.border
  property color accent: Commons.Color.accent
  readonly property var popupBorderSpec: Border.localOrSurfaceSpec("popups", "border", popupBorder, Commons.Color.popups.border, Style.normalBorderWidth)
  property string fontFamily: Style.font.family
  property int rowHeight: Style.spacing.controlHeight
  property int popupRowHeight: Style.spacing.popupRowHeight
  property int popupMinHeight: Style.spacing.searchablePopupMinHeight
  property bool showLabel: true
  property int maxQueryLength: Logic.SEARCH_MAX_CHARS
  property string query: ""

  // Panel-cursor flag. When true, the trigger renders the shared
  // hover-cursor state. Active Qt focus defaults to the same visuals.
  // Emits `hovered(bool)` on pointer enter/leave so the panel can keep
  // its cursor state in sync with the mouse.
  property bool hasCursor: false

  // popupOpen + open()/close()/toggle() let a parent panel know when the
  // dropdown owns keys (search field + result list are active) and
  // suspend its own keyCatcher so typing into the filter doesn't drive
  // the panel cursor.
  readonly property bool popupOpen: popup.opened
  function open() { popup.open() }
  function close() { popup.close() }
  function toggle() { popup.opened ? popup.close() : popup.open() }

  signal changed(string value)
  signal hovered(bool isHovered)

  function optionValue(o) {
    return (o && typeof o === "object") ? String(o.value) : String(o)
  }
  function optionLabel(o) {
    return (o && typeof o === "object") ? String(o.label) : String(o)
  }
  function optionDescription(o) {
    return (o && typeof o === "object" && o.description) ? String(o.description) : ""
  }
  function currentLabel() {
    for (var i = 0; i < options.length; i++) {
      if (optionValue(options[i]) === value) return optionLabel(options[i])
    }
    return value
  }

  property var filtered: options
  function recomputeFiltered() {
    var q = root.query.toLowerCase()
    if (!q) { filtered = options; return }
    var out = []
    for (var i = 0; i < options.length; i++) {
      var lbl = optionLabel(options[i]).toLowerCase()
      var desc = optionDescription(options[i]).toLowerCase()
      if (lbl.indexOf(q) !== -1 || desc.indexOf(q) !== -1) out.push(options[i])
    }
    filtered = out
  }

  onOptionsChanged: recomputeFiltered()

  implicitWidth: Style.spacing.searchableDropdownWidth
  implicitHeight: showLabel && label !== "" ? rowHeight + Style.spacing.huge : rowHeight

  Column {
    anchors.fill: parent
    spacing: Style.spacing.labelGap

    Text {
      textFormat: Text.PlainText
      visible: root.showLabel && root.label !== ""
      text: root.label
      color: Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    BorderSurface {
      id: trigger
      width: parent.width
      height: root.rowHeight
      radius: Style.cornerRadius

      readonly property bool _focused: trigger.activeFocus
      readonly property bool _hot: triggerHover.hovered || root.hasCursor
      readonly property var _borderSpec: Border.controlSpec(trigger._focused ? "focus" : (trigger._hot ? "hover-cursor" : "normal"), root.foreground, root.accent)

      color: Style.controlFill(trigger._focused, trigger._hot, root.foreground, root.accent)
      borderSpec: _borderSpec

      activeFocusOnTab: true

      HoverHandler {
        id: triggerHover
        onHoveredChanged: root.hovered(hovered)
      }

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
            || event.key === Qt.Key_Space || event.key === Qt.Key_Down) {
          popup.opened ? popup.close() : popup.open()
          event.accepted = true
        } else if (event.key === Qt.Key_Escape && popup.opened) {
          popup.close(); event.accepted = true
        }
      }

      Text {
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.right: chevron.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: trigger.borderLeft + Style.spacing.controlPaddingX
        anchors.rightMargin: trigger.borderRight + Style.spacing.md
        text: root.currentLabel() || root.triggerLabel || root.placeholderText
        color: (root.currentLabel() || root.triggerLabel) ? root.foreground : Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        id: chevron
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: trigger.borderRight + Style.spacing.controlGap
        text: "󰅀"
        color: Qt.darker(root.foreground, 1.2)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          trigger.forceActiveFocus()
          popup.opened ? popup.close() : popup.open()
        }
      }

      QQC.Popup {
        id: popup
        x: 0
        y: trigger.height + Style.spacing.xxs
        width: trigger.width
        implicitHeight: Math.max(root.popupMinHeight,
                                 Math.min(resultList.contentHeight + Style.space(50),
                                          root.popupRowHeight * 6 + 5 * Style.spacing.labelGap + Style.space(50)))
        padding: Style.spacing.hairline
        leftPadding: Border.left(root.popupBorderSpec) + Style.spacing.hairline
        rightPadding: Border.right(root.popupBorderSpec) + Style.spacing.hairline
        topPadding: Border.top(root.popupBorderSpec) + Style.spacing.hairline
        bottomPadding: Border.bottom(root.popupBorderSpec) + Style.spacing.hairline
        focus: true

        background: BorderSurface {
          color: root.background
          borderSpec: root.popupBorderSpec
          radius: Style.cornerRadius
        }

        onOpened: {
          searchField.setQuery("")
          Qt.callLater(function() { searchField.forceActiveFocus() })
        }
        onClosed: searchField.setQuery("")

        contentItem: Column {
          spacing: 0

          Item {
            id: searchHeader
            width: parent.width
            height: root.popupRowHeight + Style.spacing.controlPaddingX

            BorderSurface {
              id: searchField
              anchors.fill: parent
              anchors.margins: Style.spacing.md
              radius: Style.cornerRadius
              activeFocusOnTab: true

              readonly property var _borderSpec: Border.controlSpec(searchField.activeFocus ? "focus" : "normal", root.foreground, root.accent)
              color: Style.controlFill(searchField.activeFocus, false, root.foreground, root.accent)
              borderSpec: _borderSpec

              function setQuery(q) {
                // searchTyped already caps typed text; this only bounds any other caller.
                root.query = String(q).slice(0, 4 * root.maxQueryLength)
                root.recomputeFiltered()
                if (resultList.count > 0) resultList.currentIndex = 0
              }

              Text {
                id: queryText
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: searchField.borderLeft + Style.spacing.controlPaddingX
                anchors.rightMargin: searchField.borderRight + Style.spacing.controlPaddingX
                textFormat: Text.PlainText
                text: root.query !== "" ? root.query : root.placeholderText
                color: root.query !== "" ? root.foreground : Qt.darker(root.foreground, 1.6)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideLeft
              }

              Rectangle {
                id: caret
                visible: searchField.activeFocus
                width: 1
                height: queryText.font.pixelSize + 2
                anchors.verticalCenter: parent.verticalCenter
                x: queryText.x + (root.query !== "" ? Math.min(queryText.contentWidth, queryText.width) : 0) + 1
                color: root.foreground
                SequentialAnimation on opacity {
                  running: searchField.activeFocus
                  loops: Animation.Infinite
                  NumberAnimation { to: 1; duration: 0 }
                  PauseAnimation { duration: 530 }
                  NumberAnimation { to: 0; duration: 0 }
                  PauseAnimation { duration: 530 }
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.IBeamCursor
                onClicked: searchField.forceActiveFocus()
              }

              Keys.onPressed: function(event) {
                var mods = event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)
                if (event.key === Qt.Key_Escape) {
                  popup.close(); event.accepted = true
                } else if (event.key === Qt.Key_Down) {
                  if (resultList.count > 0) {
                    resultList.currentIndex = 0
                    resultList.forceActiveFocus()
                  }
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  if (resultList.count > 0) {
                    resultList.currentIndex = 0
                    resultList.selectCurrent()
                  }
                  event.accepted = true
                } else if (event.key === Qt.Key_Backspace) {
                  if (mods & Qt.ControlModifier) searchField.setQuery("")
                  else if (root.query !== "") searchField.setQuery(Logic.searchBackspace(root.query))
                  event.accepted = true
                } else if (mods === 0 && Logic.isSearchText(event.text)) {
                  searchField.setQuery(Logic.searchTyped(root.query, event.text, root.maxQueryLength))
                  event.accepted = true
                }
              }
            }
          }

          Rectangle {
            width: parent.width
            height: 1
            color: Util.alpha(root.foreground, 0.10)
          }

          Item {
            width: parent.width
            height: popup.height - searchHeader.height - Style.spacing.xxs - 1

            Text {
              textFormat: Text.PlainText
              anchors.centerIn: parent
              visible: resultList.count === 0
              text: root.emptyText
              color: Qt.darker(root.foreground, 1.6)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            ListView {
              id: resultList
              anchors.fill: parent
              spacing: Style.spacing.labelGap
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              model: root.filtered
              currentIndex: -1
              keyNavigationEnabled: false

              function selectCurrent() {
                if (currentIndex < 0 || currentIndex >= root.filtered.length) return
                var v = root.optionValue(root.filtered[currentIndex])
                root.value = v
                root.changed(v)
                popup.close()
              }

              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  popup.close(); event.accepted = true
                } else if (event.key === Qt.Key_Down || event.text === "j") {
                  if (resultList.currentIndex >= resultList.count - 1) {
                    event.accepted = true; return
                  }
                  resultList.currentIndex = resultList.currentIndex + 1
                  event.accepted = true
                } else if (event.key === Qt.Key_Up || event.text === "k") {
                  if (resultList.currentIndex <= 0) {
                    searchField.forceActiveFocus()
                    event.accepted = true; return
                  }
                  resultList.currentIndex = resultList.currentIndex - 1
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  resultList.selectCurrent(); event.accepted = true
                }
              }

              delegate: Rectangle {
                required property var modelData
                required property int index
                width: resultList.width
                height: Math.max(root.popupRowHeight, rowContent.implicitHeight + Style.spacing.rowPaddingX)
                color: index === resultList.currentIndex
                  ? Style.hoverFillFor(root.foreground, root.accent)
                  : "transparent"

                Column {
                  id: rowContent
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.spacing.controlPaddingX
                  anchors.rightMargin: Style.spacing.controlPaddingX
                  spacing: Style.spacing.xxs

                  Text {
                    textFormat: Text.PlainText
                    text: root.optionLabel(modelData)
                    color: index === resultList.currentIndex ? Style.hoverStateColor(root.foreground, root.accent) : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                    width: parent.width
                  }
                  Text {
                    textFormat: Text.PlainText
                    visible: text !== ""
                    text: root.optionDescription(modelData)
                    color: Qt.darker(root.foreground, 1.5)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: parent.width
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onPositionChanged: resultList.currentIndex = parent.index
                  onClicked: resultList.selectCurrent()
                }
              }
            }
          }
        }
      }
    }
  }
}

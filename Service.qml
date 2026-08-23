import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string inputLuaPath: home + "/.config/hypr/input.lua"
  readonly property string configDir: home + "/.config/omarchy/keyboard-layout"
  readonly property string moduleId: "lef.keyboard-layout"
  readonly property string repoUrl: "https://github.com/Somnius/Omarchy-Keyboard-Layout"

  // Parsed from ~/.config/hypr/input.lua
  property var layouts: []
  property string hotkey: "caps"        // caps | alt+shift | ctrl+shift
  property bool led: true

  // Live state from hyprctl / xkbcli
  property string keyboardName: ""      // typed keyboard we read & switch
  property string currentKeymap: ""     // e.g. "English (US)"
  property string currentAbbr: ""       // e.g. "EN"
  property bool loaded: false
  property string lastError: ""
  property string lastAction: ""

  // Short language codes: xkb description -> brief ("English (US)": "en"),
  // read from xkb's own table instead of maintained by hand.
  property var layoutBriefs: ({})

  // Bar placement: 0 = unknown (loading), 1 = answered, -1 = not yet
  // answered. The panel opens by itself once while -1.
  // Placement itself is center|right only — never left.
  property int askedState: 0
  property string placement: "right"
  property string lastPlaceAction: ""

  function saveConfig() {
    configFile.setText(JSON.stringify({ asked: true, placement: root.placement }))
    root.askedState = 1
  }

  function place(section) {
    if (section !== "center" && section !== "right") {
      root.lastPlaceAction = "Only center or right — never left"
      return
    }
    var moved = section !== root.placement
    if (moved) {
      var args = ["omarchy", "bar", "move", root.moduleId, "--section", section]
      if (section === "center") args.push("--after", "omarchy.clock")
      placeProc.command = args
      placeProc.running = true
      root.placement = section
    }
    saveConfig()
    root.lastPlaceAction = moved
      ? "Moved to " + section + " — reloading Hyprland & shell…"
      : "Already on the " + section
    if (moved) placeReloadTimer.restart()
  }

  readonly property var hotkeyMap: {
    "caps": "grp:caps_toggle",
    "alt+shift": "grp:alt_shift_toggle",
    "ctrl+shift": "grp:ctrl_shift_toggle"
  }
  readonly property var hotkeyLabels: {
    "caps": "Caps Lock",
    "alt+shift": "Alt+Shift",
    "ctrl+shift": "Ctrl+Shift"
  }

  // Same exclusions as the first-party widget: fcitx5's injection keyboard,
  // ACPI buttons and lid switches all carry the seat's layout list, answer to
  // switchxkblayout, and nobody types on any of them.
  readonly property string untypedPattern: "^(hl-virtual-keyboard|power-button|sleep-button|lid-switch|video-bus)"

  function isTypedKeyboard(name) {
    return !new RegExp(root.untypedPattern).test(String(name || ""))
  }

  function shortLabel(description) {
    if (!description) return ""
    // ponytail: first-word fallback reads ENG/POR; xkbcli briefs cover the rest.
    var brief = root.layoutBriefs[description]
    var label = typeof brief === "string" && brief !== ""
      ? brief.split("-")[0]
      : String(description).split(/\s+/)[0]
    return label.substring(0, 3).toUpperCase()
  }

  function statusText() {
    var l = root.layouts.join(" · ")
    var hk = root.hotkeyLabels[root.hotkey] || root.hotkey
    if (root.hotkey === "caps" && root.led) hk += " + LED"
    return (l !== "" ? l : "no layouts") + "  ·  " + hk
  }

  function refresh() {
    if (!devicesProc.running) devicesProc.running = true
  }

  function applyDevices(text) {
    var listed
    try { listed = JSON.parse(text || "{}").keyboards } catch (e) { return }
    if (!Array.isArray(listed)) return

    var typed = listed.filter(function (k) { return root.isTypedKeyboard(k.name) })
    if (typed.length === 0) { root.keyboardName = ""; root.currentKeymap = ""; root.currentAbbr = ""; return }

    // Furthest-advanced wins: every keyboard shares the layout list, only the
    // typed-on one moves through it, and index comparison survives wrapping.
    var kb = typed.reduce(function (furthest, k) {
      return ((k.active_layout_index || 0) > (furthest.active_layout_index || 0)) ? k : furthest
    }, typed[0])

    if (!kb.active_keymap) return
    root.keyboardName = String(kb.name || "")
    root.currentKeymap = String(kb.active_keymap)
    root.currentAbbr = root.shortLabel(root.currentKeymap)
    root.loaded = true
  }

  function parseOptions(optStr) {
    var s = String(optStr || "")
    if (/alt_shift_toggle/.test(s)) root.hotkey = "alt+shift"
    else if (/ctrl_shift_toggle/.test(s)) root.hotkey = "ctrl+shift"
    else if (/caps_toggle/.test(s)) root.hotkey = "caps"
    root.led = /grp_led:caps/.test(s)
  }

  function applyLua(text) {
    var t = String(text || "")
    var m = t.match(/kb_layout\s*=\s*"([^"]*)"/)
    root.layouts = m ? m[1].split(",").map(function (s) { return s.trim() })
                       .filter(function (s) { return s !== "" }) : []
    var o = t.match(/kb_options\s*=\s*"([^"]*)"/)
    parseOptions(o ? o[1] : "")
    root.loaded = true
  }

  function backupOnce() {
    bakProc.command = ["bash", "-c",
      "f=" + JSON.stringify(root.inputLuaPath) +
      "; ls \"$f\".bak.* >/dev/null 2>&1 || cp \"$f\" \"$f.bak.$(date +%s)\""]
    bakProc.running = true
  }

  function applySettings(primary, second, hk, useLed) {
    var arr = [primary, second].filter(function (x) { return x && x.length && x !== "(none)" })
    if (arr.length === 0) { root.lastError = "Pick at least one layout"; return }
    if (!root.hotkeyMap[hk]) { root.lastError = "Unknown hotkey: " + hk; return }

    backupOnce()

    var t = String(luaFile.text() || "")
    var optParts = [root.hotkeyMap[hk]]
    if (useLed && hk === "caps") optParts.push("grp_led:caps")
    var layRe = /(kb_layout\s*=\s*)"([^"]*)"/
    var optRe = /(kb_options\s*=\s*)"([^"]*)"/
    var replacedLay = layRe.test(t)
    var replacedOpt = optRe.test(t)
    if (replacedLay) t = t.replace(layRe, "$1\"" + arr.join(",") + "\"")
    if (replacedOpt) t = t.replace(optRe, "$1\"" + optParts.join(",") + "\"")
    // Missing lines get appended as a second hl.config block; Hyprland merges them.
    if (!replacedLay || !replacedOpt) {
      t += "\nhl.config({\n  input = {\n" +
        (replacedLay ? "" : "    kb_layout = \"" + arr.join(",") + "\",\n") +
        (replacedOpt ? "" : "    kb_options = \"" + optParts.join(",") + "\",\n") +
        "  },\n})\n"
    }

    root.lastError = ""
    luaFile.setText(t)
    root.lastAction = "Saved to input.lua — reloading Hyprland…"
    reloadTimer.restart()
  }

  function nextLayout() {
    if (root.layouts.length < 2) {
      root.lastAction = "Add a second layout in the panel first"
      return
    }
    if (!root.keyboardName) {
      root.lastAction = "No keyboard found yet"
      return
    }
    // switchxkblayout is a hyprctl command, not a dispatcher — run it directly,
    // naming the exact device the label describes so click and label agree.
    switchProc.command = ["hyprctl", "switchxkblayout", root.keyboardName, "next"]
    switchProc.running = true
    syncTimer.restart()
  }

  FileView {
    id: luaFile
    path: root.inputLuaPath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyLua(text())
    onLoadFailed: root.applyLua("")
    onFileChanged: reload()
  }

  FileView {
    id: configFile
    path: root.configDir + "/config.json"
    watchChanges: false
    printErrors: false
    onLoaded: {
      var c = {}
      try { c = JSON.parse(text()) || {} } catch (e) { c = {} }
      root.placement = c.placement === "center" ? "center" : "right"
      root.askedState = c.asked === true ? 1 : -1
    }
    onLoadFailed: root.askedState = -1
  }

  Process {
    id: placeProc
    onExited: function (exitCode) {
      if (exitCode !== 0)
        root.lastPlaceAction = "omarchy bar move failed (" + exitCode + ")"
    }
  }

  // Detached: survives the shell restart it triggers.
  Process {
    id: placeReloadProc
    command: ["bash", "-c",
      "nohup bash -c 'hyprctl reload; sleep 1; omarchy restart shell' >/dev/null 2>&1 &"]
  }

  Timer {
    id: placeReloadTimer
    interval: 400
    onTriggered: placeReloadProc.running = true
  }

  Process {
    id: configDirProc
    command: ["mkdir", "-p", root.configDir]
  }

  Process {
    id: bakProc
  }

  Process {
    id: devicesProc
    command: ["hyprctl", "-j", "devices"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyDevices(text)
    }
  }

  Process {
    id: switchProc
  }

  Process {
    id: briefsProc
    command: ["xkbcli", "list", "--load-exotic"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // xkbcli prints YAML pairing brief + description inside each block;
        // a brief never carries past its block.
        var briefs = {}
        var brief = ""
        String(text || "").split("\n").forEach(function (line) {
          if (/^\s*- /.test(line)) brief = ""
          var field = line.match(/^  (brief|description): (.*)$/)
          if (!field) return
          if (field[1] === "brief") brief = field[2].replace(/^'|'$/g, "")
          else if (brief !== "") { briefs[field[2]] = brief; brief = "" }
        })
        root.layoutBriefs = briefs
        root.currentAbbr = root.shortLabel(root.currentKeymap)
      }
    }
  }

  Process {
    id: reloadProc
    command: ["hyprctl", "reload"]
    onExited: function (exitCode) {
      root.lastAction = exitCode === 0 ? "Hyprland reloaded — settings live"
                                       : "hyprctl reload failed (" + exitCode + ")"
      syncTimer.restart()
    }
  }

  // A reload adding a layout raises no activelayout, so notice configreloaded.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      var name = String(event.name)
      if (name.indexOf("activelayout") !== -1 || name === "configreloaded") root.refresh()
    }
  }

  Timer {
    id: reloadTimer
    interval: 400
    onTriggered: reloadProc.running = true
  }

  Timer {
    id: syncTimer
    interval: 600
    onTriggered: root.refresh()
  }

  Component.onCompleted: {
    root.refresh()
    if (!briefsProc.running) briefsProc.running = true
    configDirProc.running = true
  }
}

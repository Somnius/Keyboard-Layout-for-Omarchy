import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "ServiceLogic.js" as Logic

Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string inputLuaPath: home + "/.config/hypr/input.lua"
  readonly property string configDir: home + "/.config/omarchy/keyboard-layout"
  readonly property string configPath: configDir + "/config.json"
  readonly property string boundedReadScriptPath: decodeURIComponent(
    String(Qt.resolvedUrl("BoundedRead.pl")).replace(/^file:\/\//, ""))
  readonly property string boundedExecScriptPath: decodeURIComponent(
    String(Qt.resolvedUrl("BoundedExec.pl")).replace(/^file:\/\//, ""))
  readonly property string writeInputScriptPath: decodeURIComponent(
    String(Qt.resolvedUrl("WriteInput.pl")).replace(/^file:\/\//, ""))
  readonly property string moduleId: "lef.keyboard-layout"
  readonly property string repoUrl: "https://github.com/Somnius/Keyboard-Layout-for-Omarchy"

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

  property bool inputReadPending: false
  property bool configReadPending: false
  property bool devicesReadPending: false
  property bool configHasGoodState: false
  property string pendingPlacement: ""

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
    var text = JSON.stringify({ asked: true, placement: root.placement }) + "\n"
    // Reads stay disabled. Reset FileView's write cache so an externally
    // replaced file can never suppress this explicit placement write.
    configFile.path = ""
    configFile.path = root.configPath
    configFile.setText(text)
    root.applyConfig(text)
  }

  function place(section) {
    if (section !== "center" && section !== "right") {
      root.lastPlaceAction = "Only center or right — never left"
      return
    }
    if (placeProc.running) {
      root.lastPlaceAction = "A placement move is already in progress"
      return
    }
    if (section === root.placement) {
      saveConfig()
      root.lastPlaceAction = "Already on the " + section
      return
    }

    root.pendingPlacement = section
    var args = ["omarchy", "bar", "move", root.moduleId, "--section", section]
    if (section === "center") args.push("--after", "omarchy.clock")
    placeProc.command = args
    placeProc.running = true
    root.lastPlaceAction = "Moving to " + section + "…"
  }

  readonly property var hotkeyMap: {
    "caps": "grp:caps_toggle",
    "both alts": "grp:alts_toggle",
    "alt+shift": "grp:alt_shift_toggle",
    "ctrl+shift": "grp:ctrl_shift_toggle"
  }
  readonly property var hotkeyLabels: {
    "caps": "Caps Lock",
    "both alts": "Both Alts",
    "alt+shift": "Alt+Shift",
    "ctrl+shift": "Ctrl+Shift"
  }

  // Omarchy's stock kb_options. Applying a hotkey must not silently drop these
  // — compose:caps puts Compose on Caps Lock and shift:both_capslock_cancel
  // keeps a misfired Caps Lock self-clearing. The caps_toggle variant has to
  // give up compose:caps, since Caps Lock cannot be Compose and the toggle.
  readonly property string omarchyBaseOptions: "compose:caps,shift:both_capslock_cancel"
  readonly property string omarchyBaseOptionsNoCompose: "shift:both_capslock_cancel"

  function shortLabel(description) {
    if (!description) return ""
    // ponytail: first-word fallback reads ENG/POR; xkbcli briefs cover the rest.
    var brief = root.layoutBriefs["$" + description]
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
    if (devicesProc.running) {
      root.devicesReadPending = true
      return
    }
    root.devicesReadPending = false
    devicesProc.running = true
  }

  function applyDevices(text) {
    var result = Logic.parseDevices(text)
    if (!result.ok) return result

    root.keyboardName = result.value.keyboardName
    root.currentKeymap = result.value.currentKeymap
    root.currentAbbr = root.shortLabel(root.currentKeymap)
    root.loaded = true
    return result
  }

  function applyLua(text) {
    var result = Logic.parseLua(text)
    if (!result.ok) return result

    root.layouts = result.value.layouts
    root.hotkey = result.value.hotkey
    root.led = result.value.led
    root.loaded = true
    return result
  }

  function applyConfig(text) {
    var result = Logic.parseConfig(text)
    if (!result.ok) return result

    root.placement = result.value.placement
    root.askedState = result.value.askedState
    root.configHasGoodState = true
    return result
  }

  function applyBriefs(text) {
    var result = Logic.parseBriefs(text)
    if (!result.ok) return result

    root.layoutBriefs = result.value
    root.currentAbbr = root.shortLabel(root.currentKeymap)
    return result
  }

  function readFailure(stderrText, fallback) {
    var detail = String(stderrText || "").replace(/[\u0000-\u001f\u007f]+/g, " ").trim()
    return (detail || fallback).substring(0, 160)
  }

  function clearReadError(prefix) {
    if (root.lastError.indexOf(prefix) === 0) root.lastError = ""
  }

  function requestInputRead() {
    if (inputReadProc.running) {
      root.inputReadPending = true
      return
    }
    root.inputReadPending = false
    inputReadProc.running = true
  }

  function requestConfigRead() {
    if (configReadProc.running) {
      root.configReadPending = true
      return
    }
    root.configReadPending = false
    configReadProc.running = true
  }

  function onInputReadExited(exitCode) {
    var stale = root.inputReadPending
    root.inputReadPending = false
    if (stale) {
      Qt.callLater(root.requestInputRead)
      return
    }

    if (exitCode === 0) {
      var result = root.applyLua(inputReadOutput.text)
      if (result.ok) {
        root.clearReadError("Invalid input.lua:")
        root.clearReadError("Could not read input.lua:")
      }
      else root.lastError = "Invalid input.lua: " + result.error
    } else {
      root.lastError = "Could not read input.lua: "
        + root.readFailure(inputReadError.text, "bounded read failed")
    }
    // Keep the panel reachable even when the first read fails. Literal
    // defaults remain in place; later failures never replace good state.
    if (!root.loaded) root.loaded = true
  }

  function onConfigReadExited(exitCode) {
    var stale = root.configReadPending
    root.configReadPending = false
    if (stale) {
      Qt.callLater(root.requestConfigRead)
      return
    }

    if (exitCode === 0) {
      var result = root.applyConfig(configReadOutput.text)
      if (result.ok) {
        root.clearReadError("Invalid config.json:")
        root.clearReadError("Could not read config.json:")
      }
      else {
        if (!root.configHasGoodState) root.askedState = -1
        root.lastError = "Invalid config.json: " + result.error
      }
    } else {
      if (!root.configHasGoodState) root.askedState = -1
      if (exitCode !== 2 || root.configHasGoodState)
        root.lastError = "Could not read config.json: "
          + root.readFailure(configReadError.text, "bounded read failed")
    }
  }

  function onDevicesExited(exitCode) {
    var stale = root.devicesReadPending
    root.devicesReadPending = false
    if (stale) {
      Qt.callLater(root.refresh)
      return
    }

    if (exitCode !== 0) {
      console.warn("keyboard-layout", "hyprctl devices rejected:",
        root.readFailure(devicesError.text, "bounded producer failed"))
      return
    }
    var result = root.applyDevices(devicesOutput.text)
    if (!result.ok)
      console.warn("keyboard-layout", "hyprctl devices rejected:", result.error)
  }

  function applySettings(primary, second, hk, useLed) {
    if (inputWriteProc.running) { root.lastError = "A save is already in progress"; return }
    if (typeof primary !== "string" || typeof second !== "string"
        || typeof hk !== "string" || typeof useLed !== "boolean") {
      root.lastError = "Invalid settings"
      return
    }
    var arr = [primary, second].filter(function (x) { return x !== "" && x !== "(none)" })
    if (arr.length === 0) { root.lastError = "Pick at least one layout"; return }
    if (!Object.prototype.hasOwnProperty.call(root.hotkeyMap, hk)) {
      root.lastError = "Unknown hotkey: " + hk
      return
    }
    for (var i = 0; i < arr.length; i++) {
      if (arr[i].length > Logic.MAX_LAYOUT_NAME_CHARS
          || !/^[A-Za-z0-9_+-]+$/.test(arr[i])) {
        root.lastError = "Invalid layout name"
        return
      }
    }

    var optParts = [hk === "caps" ? root.omarchyBaseOptionsNoCompose
                                  : root.omarchyBaseOptions,
                    root.hotkeyMap[hk]]
    if (useLed && hk === "caps") optParts.push("grp_led:caps")
    root.lastError = ""
    root.lastAction = "Saving input.lua…"
    inputWriteProc.command = ["/usr/bin/perl", root.writeInputScriptPath,
      root.inputLuaPath, String(Logic.INPUT_MAX_BYTES),
      arr.join(","), optParts.join(",")]
    inputWriteProc.running = true
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
    path: root.inputLuaPath
    preload: false
    blockAllReads: true
    watchChanges: true
    printErrors: false
    onFileChanged: root.requestInputRead()
  }

  FileView {
    id: configFile
    path: ""
    preload: false
    blockAllReads: true
    watchChanges: true
    printErrors: false
    atomicWrites: true
    onFileChanged: root.requestConfigRead()
    onSaveFailed: function (error) {
      root.lastError = "Could not save config.json (" + error + ")"
    }
  }

  Process {
    id: placeProc
    onExited: function (exitCode) {
      var section = root.pendingPlacement
      root.pendingPlacement = ""
      if (exitCode !== 0) {
        root.lastPlaceAction = "omarchy bar move failed (" + exitCode + ")"
        return
      }
      root.placement = section
      root.saveConfig()
      root.lastPlaceAction = "Moved to " + section + " — reloading Hyprland & shell…"
      placeReloadTimer.restart()
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
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        root.askedState = -1
        root.lastError = "Could not create keyboard-layout config directory"
        return
      }
      configFile.path = root.configPath
      root.requestConfigRead()
    }
  }

  Process {
    id: inputReadProc
    command: ["/usr/bin/perl", root.boundedReadScriptPath,
      root.inputLuaPath, String(Logic.INPUT_MAX_BYTES)]
    stdout: StdioCollector {
      id: inputReadOutput
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: inputReadError
      waitForEnd: true
    }
    onExited: function (exitCode) { root.onInputReadExited(exitCode) }
  }

  Process {
    id: configReadProc
    command: ["/usr/bin/perl", root.boundedReadScriptPath,
      root.configPath, String(Logic.CONFIG_MAX_BYTES)]
    stdout: StdioCollector {
      id: configReadOutput
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: configReadError
      waitForEnd: true
    }
    onExited: function (exitCode) { root.onConfigReadExited(exitCode) }
  }

  Process {
    id: inputWriteProc
    stderr: StdioCollector {
      id: inputWriteError
      waitForEnd: true
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        root.lastError = "Could not save input.lua: "
          + root.readFailure(inputWriteError.text, "safe write failed")
        root.lastAction = ""
        Qt.callLater(root.requestInputRead)
        return
      }
      root.lastError = ""
      root.lastAction = "Saved to input.lua — reloading Hyprland…"
      Qt.callLater(root.requestInputRead)
      reloadTimer.restart()
    }
  }

  Process {
    id: devicesProc
    command: ["/usr/bin/timeout", "5", "/usr/bin/perl",
      root.boundedExecScriptPath, String(Logic.DEVICES_MAX_BYTES),
      "hyprctl", "-j", "devices"]
    stdout: StdioCollector {
      id: devicesOutput
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: devicesError
      waitForEnd: true
    }
    onExited: function (exitCode) { root.onDevicesExited(exitCode) }
  }

  Process {
    id: switchProc
  }

  Process {
    id: briefsProc
    command: ["/usr/bin/timeout", "10", "/usr/bin/perl",
      root.boundedExecScriptPath, String(Logic.XKB_MAX_BYTES),
      "xkbcli", "list", "--load-exotic"]
    stdout: StdioCollector {
      id: briefsOutput
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: briefsError
      waitForEnd: true
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        console.warn("keyboard-layout", "xkbcli output rejected:",
          root.readFailure(briefsError.text, "bounded producer failed"))
        return
      }
      var result = root.applyBriefs(briefsOutput.text)
      if (!result.ok)
        console.warn("keyboard-layout", "xkbcli output rejected:", result.error)
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
    root.requestInputRead()
    root.refresh()
    if (!briefsProc.running) briefsProc.running = true
    configDirProc.running = true
  }
}

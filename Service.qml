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
  readonly property string backupDir: configDir + "/backups"
  readonly property string boundedReadScriptPath: scriptPath("BoundedRead.pl")
  readonly property string boundedExecScriptPath: scriptPath("BoundedExec.pl")
  readonly property string inputLuaScriptPath: scriptPath("InputLua.pl")
  readonly property string moduleId: "lef.keyboard-layout"
  readonly property string repoUrl: "https://github.com/Somnius/Keyboard-Layout-for-Omarchy"

  function scriptPath(name) {
    return decodeURIComponent(String(Qt.resolvedUrl(name)).replace(/^file:\/\//, ""))
  }

  // Parsed from ~/.config/hypr/input.lua: [{ layout, variant }], in order.
  property var layouts: []
  property var options: []
  property string hotkey: "grp:caps_toggle"   // an xkb grp: option, or "none"
  property bool led: true

  // Live state from hyprctl / xkbcli
  property var keyboards: []            // typed keyboards: [{ name, keymap, index }]
  property string keyboardName: ""      // the keyboard being typed on
  property string eventKeyboardName: "" // last keyboard an activelayout named
  property string currentKeymap: ""     // e.g. "English (US)"
  property string currentAbbr: ""       // e.g. "EN"
  property int currentIndex: 0
  property bool loaded: false
  property bool devicesLoaded: false
  property string lastError: ""
  property string lastAction: ""

  property bool inputReadPending: false
  property bool configReadPending: false
  property bool devicesReadPending: false
  property bool configHasGoodState: false
  property string pendingPlacement: ""
  // A next / prev / index waiting for a fresh device read before it switches.
  property var pendingSwitch: null
  // Our own batch raises an activelayout per keyboard; those name no one
  // who is typing, so they must not move the typed-keyboard choice.
  property real ownSwitchUntil: 0

  // xkb's own table: short language codes by description, and every
  // layout/variant pair for the panel's picker.
  property var layoutBriefs: ({})
  property var catalog: []
  property var catalogOptions: []

  // Bar placement: 0 = unknown (loading), 1 = answered, -1 = not yet
  // answered. The panel opens by itself once while -1.
  // Placement itself is center|right only — never left.
  property int askedState: 0
  property string placement: "right"
  property string lastPlaceAction: ""

  // Optional behaviour, both off by default.
  property bool toastEnabled: false
  property bool highlightEnabled: false

  property var backups: []
  property string lastBackupAction: ""

  // Toast state: the window exists only while a toast is on screen.
  property string toastAbbr: ""
  property string toastKeymap: ""
  property bool toastActive: false
  property bool toastShown: false

  readonly property var hotkeyChoices: Logic.HOTKEYS
  readonly property int maxLayouts: Logic.MAX_LAYOUTS
  readonly property bool onMainLayout: currentIndex === 0

  // Emitted when the active layout really changes (never on first load or on
  // a refresh that finds the same layout), whatever caused the change.
  signal layoutSwitched(string abbr, string keymap)

  function saveConfig() {
    var text = Logic.configText({
      placement: root.placement,
      toast: root.toastEnabled,
      highlight: root.highlightEnabled
    })
    // Reads stay disabled. Reset FileView's write cache so an externally
    // replaced file can never suppress this explicit write.
    configFile.path = ""
    configFile.path = root.configPath
    configFile.setText(text)
    root.applyConfig(text)
  }

  function setToast(enabled) {
    root.toastEnabled = enabled === true
    saveConfig()
  }

  function setHighlight(enabled) {
    root.highlightEnabled = enabled === true
    saveConfig()
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

  function hotkeyLabel(value) {
    return Logic.hotkeyLabel(value)
  }

  function shortLabel(description) {
    if (!description) return ""
    // ponytail: first-word fallback reads ENG/POR; xkbcli briefs cover the rest.
    var brief = root.layoutBriefs["$" + description]
    var label = typeof brief === "string" && brief !== ""
      ? brief.split("-")[0]
      : String(description).split(/\s+/)[0]
    return label.substring(0, 3).toUpperCase()
  }

  function layoutSpec(entry) {
    return Logic.layoutSpec(entry)
  }

  function layoutDescription(entry) {
    var spec = Logic.layoutSpec(entry)
    for (var i = 0; i < root.catalog.length; i++)
      if (Logic.layoutSpec(root.catalog[i]) === spec) return root.catalog[i].description
    return spec
  }

  function statusText() {
    var l = root.layouts.map(Logic.layoutSpec).join(" · ")
    var hk = Logic.hotkeyLabel(root.hotkey)
    if (root.hotkey === "grp:caps_toggle" && root.led) hk += " + LED"
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

  function setKeymap(keymap) {
    var changed = root.devicesLoaded && keymap !== "" && keymap !== root.currentKeymap
    root.currentKeymap = keymap
    root.currentAbbr = root.shortLabel(keymap)
    if (changed) root.layoutSwitched(root.currentAbbr, keymap)
  }

  function applyDevices(text) {
    var result = Logic.parseDevices(text, root.eventKeyboardName)
    if (!result.ok) return result

    root.keyboards = result.value.keyboards
    root.keyboardName = result.value.keyboardName
    root.currentIndex = result.value.currentIndex
    root.setKeymap(result.value.currentKeymap)
    root.devicesLoaded = true
    root.loaded = true
    return result
  }

  function applyLua(text) {
    var result = Logic.parseLua(text)
    if (!result.ok) return result

    root.layouts = result.value.layouts
    root.options = result.value.options
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
    root.toastEnabled = result.value.toast
    root.highlightEnabled = result.value.highlight
    root.configHasGoodState = true
    return result
  }

  function applyCatalog(text) {
    var result = Logic.parseCatalog(text)
    if (!result.ok) return result

    root.layoutBriefs = result.value.briefs
    root.catalog = result.value.entries
    root.catalogOptions = result.value.entries.map(function (entry) {
      var spec = Logic.layoutSpec(entry)
      return { value: spec, label: entry.description, description: spec }
    })
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

    var result = exitCode === 0
      ? root.applyDevices(devicesOutput.text)
      : { ok: false, error: root.readFailure(devicesError.text, "bounded producer failed") }
    if (!result.ok) console.warn("keyboard-layout", "hyprctl devices rejected:", result.error)

    if (root.pendingSwitch !== null) {
      var action = root.pendingSwitch
      root.pendingSwitch = null
      if (result.ok) root.performSwitch(action)
      else root.lastAction = "Could not read keyboards; layout not switched"
    }
  }

  // Layout count Hyprland is actually using: the configured list, capped at
  // what xkb can hold.
  function layoutCount() {
    return Math.min(root.layouts.length, Logic.MAX_LAYOUTS)
  }

  function requestSwitch(action) {
    if (root.layoutCount() < 2) {
      root.lastAction = "Add a second layout in the panel first"
      return false
    }
    // Always switch from a fresh reading, so a Caps toggle a moment ago can
    // never make "next" land on the layout that is already active.
    root.pendingSwitch = action
    root.refresh()
    return true
  }

  function performSwitch(action) {
    var target = Logic.targetIndex(root.currentIndex, root.layoutCount(), action)
    if (target < 0) {
      root.lastAction = "No such layout"
      return
    }
    var batch = Logic.switchBatch(root.keyboards, target)
    if (batch === "") {
      root.lastAction = "No keyboard found yet"
      return
    }
    // switchxkblayout is a hyprctl command, not a dispatcher. Every typed
    // keyboard is set to the same absolute index in one batch, so several
    // physical keyboards never drift apart; virtual and ACPI "keyboards"
    // are never touched.
    root.ownSwitchUntil = Date.now() + 500
    switchProc.command = ["hyprctl", "--batch", batch]
    switchProc.running = true
  }

  function nextLayout() { return root.requestSwitch("next") }
  function prevLayout() { return root.requestSwitch("prev") }
  function mainLayout() { return root.requestSwitch(0) }

  // IPC `set`: an index ("1"), layout ("gr") or spec ("gr(polytonic)").
  function setLayout(argument) {
    var target = Logic.resolveSetTarget(argument, root.layouts.slice(0, Logic.MAX_LAYOUTS))
    if (target < 0) return "unknown layout: " + String(argument).substring(0, 64)
    if (root.layoutCount() < 1) return "no layouts configured"
    root.pendingSwitch = target
    root.refresh()
    return "switching to " + Logic.layoutSpec(root.layouts[target])
  }

  function applySettings(layoutList, hk, useLed) {
    if (inputWriteProc.running || restoreProc.running) {
      root.lastError = "A save is already in progress"
      return
    }
    var args = Logic.writeArguments(layoutList, hk, useLed, root.hotkey)
    if (!args.ok) {
      root.lastError = args.error
      return
    }

    root.lastError = ""
    root.lastAction = "Saving input.lua…"
    inputWriteProc.command = ["/usr/bin/perl", root.inputLuaScriptPath, "write",
      root.inputLuaPath, String(Logic.INPUT_MAX_BYTES), root.backupDir,
      args.value.layouts, args.value.variants, args.value.groups]
    inputWriteProc.running = true
  }

  function listBackups() {
    if (backupsProc.running) return
    backupsProc.running = true
  }

  function backupNow() {
    if (manualBackupProc.running || inputWriteProc.running || restoreProc.running) {
      root.lastBackupAction = "A backup or save is already in progress"
      return "busy"
    }
    root.lastBackupAction = "Backing up input.lua…"
    manualBackupProc.running = true
    return "backing up"
  }

  // Qt.openUrlExternally is unreliable from inside the shell, so external
  // links go through xdg-open, detached, like the backups folder does.
  function openRepo() {
    Quickshell.execDetached(["xdg-open", root.repoUrl])
  }

  // Opens the backups folder in the default file manager, creating it first
  // so there is always something to open.
  function openBackupFolder() {
    if (!backupDirProc.running) backupDirProc.running = true
    return "opening " + root.backupDir
  }

  function restoreBackup(id) {
    if (inputWriteProc.running || restoreProc.running) {
      root.lastBackupAction = "A save is already in progress"
      return "busy"
    }
    var known = root.backups.some(function (row) { return row.id === id && row.valid })
    if (!Logic.isBackupId(id) || !known) {
      root.lastBackupAction = "Unknown or unusable backup"
      return "unknown backup: " + String(id).substring(0, 64)
    }
    root.lastBackupAction = "Restoring " + id + "…"
    restoreProc.command = ["/usr/bin/perl", root.inputLuaScriptPath, "restore",
      root.inputLuaPath, String(Logic.INPUT_MAX_BYTES), root.backupDir, id]
    restoreProc.running = true
    return "restoring " + id
  }

  // Bar widgets that can show the panel (one per bar that carries the widget).
  property var panelHosts: []

  function registerPanelHost(host) {
    if (root.panelHosts.indexOf(host) < 0) root.panelHosts = root.panelHosts.concat([host])
  }

  function unregisterPanelHost(host) {
    root.panelHosts = root.panelHosts.filter(function (h) { return h !== host })
  }

  function panelHost() {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? monitor.name : ""
    for (var i = 0; i < root.panelHosts.length; i++)
      if (root.panelHosts[i].screenName === name) return root.panelHosts[i]
    return root.panelHosts.length > 0 ? root.panelHosts[root.panelHosts.length - 1] : null
  }

  function statusJson() {
    return JSON.stringify({
      keyboard: root.keyboardName,
      keyboards: root.keyboards.map(function (k) { return k.name }),
      keymap: root.currentKeymap,
      abbr: root.currentAbbr,
      index: root.currentIndex,
      layouts: root.layouts.map(Logic.layoutSpec),
      options: root.options,
      hotkey: root.hotkey,
      led: root.led,
      toast: root.toastEnabled,
      highlight: root.highlightEnabled,
      placement: root.placement,
      askedState: root.askedState,
      lastError: root.lastError
    })
  }

  function focusedScreen() {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? monitor.name : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++)
      if (screens[i].name === name) return screens[i]
    return screens.length > 0 ? screens[0] : null
  }

  function showToast(abbr, keymap) {
    root.toastAbbr = abbr
    root.toastKeymap = keymap
    root.toastActive = true
    root.toastShown = true
    toastHideTimer.restart()
  }

  onLayoutSwitched: function (abbr, keymap) {
    if (root.toastEnabled) root.showToast(abbr, keymap)
  }

  function onKeyboardEvent(event) {
    var parts = null
    try {
      // parse() hands back a Qt string list; copy it into a plain array.
      if (event.parse) parts = Array.prototype.slice.call(event.parse(2))
    } catch (error) {
    }
    if (!parts) {
      var data = String(event.data || "")
      var comma = data.indexOf(",")
      parts = comma < 0 ? [data] : [data.substring(0, comma), data.substring(comma + 1)]
    }
    var named = Logic.parseLayoutEvent(parts)
    if (!named) return
    // The event names the keyboard that switched: that is the one being typed
    // on. Show its layout at once; one coalesced read then settles the index.
    if (Date.now() > root.ownSwitchUntil) {
      root.eventKeyboardName = named.name
      root.keyboardName = named.name
    }
    root.setKeymap(named.keymap)
    eventSettleTimer.restart()
  }

  // The service is loaded once, unlike bar widgets (one per bar, re-created
  // on every move), so it owns the IPC target.
  IpcHandler {
    target: root.moduleId

    function open(): string {
      var host = root.panelHost()
      if (!host) return "no bar widget"
      host.open()
      return "ok"
    }
    function close(): string {
      for (var i = 0; i < root.panelHosts.length; i++) root.panelHosts[i].close()
      return "ok"
    }
    function toggle(): string {
      var host = root.panelHost()
      if (!host) return "no bar widget"
      host.toggle()
      return "ok"
    }
    function next(): string { return root.nextLayout() ? "ok" : root.lastAction }
    function prev(): string { return root.prevLayout() ? "ok" : root.lastAction }
    function set(layout: string): string { return root.setLayout(layout) }
    function place(section: string): string {
      if (section !== "center" && section !== "right") return "use center or right"
      root.place(section)
      return "moving to " + section
    }
    function toast(state: string): string {
      if (state !== "on" && state !== "off") return "use on or off"
      root.setToast(state === "on")
      return "toast " + state
    }
    function highlight(state: string): string {
      if (state !== "on" && state !== "off") return "use on or off"
      root.setHighlight(state === "on")
      return "highlight " + state
    }
    function backups(): string {
      root.listBackups()
      return JSON.stringify(root.backups)
    }
    function backup(): string { return root.backupNow() }
    function folder(): string { return root.openBackupFolder() }
    function restore(id: string): string { return root.restoreBackup(id) }
    function status(): string { return root.statusJson() }
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

  // `omarchy bar move` rewrites shell.json, which the running shell watches
  // and applies live: no Hyprland reload or shell restart is needed.
  Process {
    id: placeProc
    stderr: StdioCollector {
      id: placeError
      waitForEnd: true
    }
    onExited: function (exitCode) {
      var section = root.pendingPlacement
      root.pendingPlacement = ""
      if (exitCode !== 0) {
        root.lastPlaceAction = "omarchy bar move failed: "
          + root.readFailure(placeError.text, "exit " + exitCode)
        return
      }
      root.placement = section
      root.saveConfig()
      root.lastPlaceAction = "Moved to " + section
    }
  }

  Process {
    id: configDirProc
    command: ["mkdir", "-p", "-m", "700", root.configDir]
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        root.askedState = -1
        root.lastError = "Could not create keyboard-layout config directory"
        return
      }
      configFile.path = root.configPath
      root.requestConfigRead()
      root.listBackups()
    }
  }

  Process {
    id: inputReadProc
    command: ["/usr/bin/perl", root.inputLuaScriptPath, "read",
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
      Qt.callLater(root.requestInputRead)
      root.listBackups()
      if (exitCode !== 0) {
        root.lastError = "Could not save input.lua: "
          + root.readFailure(inputWriteError.text, "safe write failed")
        root.lastAction = ""
        return
      }
      root.lastError = ""
      root.lastAction = "Saved to input.lua — reloading Hyprland…"
      reloadTimer.restart()
    }
  }

  Process {
    id: backupsProc
    command: ["/usr/bin/timeout", "10", "/usr/bin/perl",
      root.boundedExecScriptPath, String(Logic.BACKUPS_MAX_BYTES),
      "/usr/bin/perl", root.inputLuaScriptPath, "backups",
      root.inputLuaPath, String(Logic.INPUT_MAX_BYTES), root.backupDir]
    stdout: StdioCollector {
      id: backupsOutput
      waitForEnd: true
    }
    onExited: function (exitCode) {
      var result = exitCode === 0 ? Logic.parseBackups(backupsOutput.text)
                                  : { ok: false, error: "listing failed (" + exitCode + ")" }
      if (result.ok) root.backups = result.value
      else console.warn("keyboard-layout", "backup list rejected:", result.error)
    }
  }

  Process {
    id: backupDirProc
    command: ["mkdir", "-p", "-m", "700", root.backupDir]
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        root.lastBackupAction = "Could not create the backups folder"
        return
      }
      // xdg-open, detached, so it respects the desktop's default file
      // manager and outlives any shell restart.
      Quickshell.execDetached(["xdg-open", root.backupDir])
    }
  }

  Process {
    id: manualBackupProc
    command: ["/usr/bin/perl", root.inputLuaScriptPath, "backup",
      root.inputLuaPath, String(Logic.INPUT_MAX_BYTES), root.backupDir]
    stdout: StdioCollector {
      id: manualBackupOutput
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: manualBackupError
      waitForEnd: true
    }
    onExited: function (exitCode) {
      root.listBackups()
      if (exitCode !== 0) {
        root.lastBackupAction = "Backup failed: "
          + root.readFailure(manualBackupError.text, "exit " + exitCode)
        return
      }
      var result = null
      try { result = JSON.parse(manualBackupOutput.text) } catch (error) {}
      if (result && result.created === true && Logic.isBackupId(result.id))
        root.lastBackupAction = "Backed up as " + result.id
      else if (result && result.created === false)
        root.lastBackupAction = "Unchanged since the newest backup — nothing to add"
      else
        root.lastBackupAction = "Backup finished with an unexpected reply"
    }
  }

  Process {
    id: restoreProc
    stderr: StdioCollector {
      id: restoreError
      waitForEnd: true
    }
    onExited: function (exitCode) {
      Qt.callLater(root.requestInputRead)
      root.listBackups()
      if (exitCode !== 0) {
        root.lastBackupAction = "Restore failed: "
          + root.readFailure(restoreError.text, "exit " + exitCode)
        return
      }
      root.lastBackupAction = "Restored — reloading Hyprland…"
      root.lastAction = ""
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
    onExited: function (exitCode) {
      if (exitCode !== 0) root.lastAction = "hyprctl switchxkblayout failed (" + exitCode + ")"
      // The activelayout events normally settle the label; this covers a
      // switch that raises none (for instance, one that changed nothing).
      eventSettleTimer.restart()
    }
  }

  Process {
    id: catalogProc
    command: ["/usr/bin/timeout", "10", "/usr/bin/perl",
      root.boundedExecScriptPath, String(Logic.XKB_MAX_BYTES),
      "xkbcli", "list", "--load-exotic"]
    stdout: StdioCollector {
      id: catalogOutput
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: catalogError
      waitForEnd: true
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        console.warn("keyboard-layout", "xkbcli output rejected:",
          root.readFailure(catalogError.text, "bounded producer failed"))
        return
      }
      var result = root.applyCatalog(catalogOutput.text)
      if (!result.ok)
        console.warn("keyboard-layout", "xkbcli output rejected:", result.error)
    }
  }

  Process {
    id: reloadProc
    command: ["hyprctl", "reload"]
    onExited: function (exitCode) {
      var message = exitCode === 0 ? "Hyprland reloaded — settings live"
                                   : "hyprctl reload failed (" + exitCode + ")"
      if (root.lastBackupAction.indexOf("Restored") === 0) root.lastBackupAction = message
      else root.lastAction = message
      syncTimer.restart()
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      var name = String(event.name)
      if (name === "activelayout") root.onKeyboardEvent(event)
      // A reload adding a layout raises no activelayout, so notice configreloaded.
      else if (name === "configreloaded") root.refresh()
    }
  }

  LazyLoader {
    active: root.toastActive
    Toast {
      screen: root.focusedScreen()
      abbr: root.toastAbbr
      keymap: root.toastKeymap
      shown: root.toastShown
    }
  }

  Timer {
    id: toastHideTimer
    interval: 1200
    onTriggered: {
      root.toastShown = false
      toastCloseTimer.restart()
    }
  }

  // Let the fade finish before the window goes away.
  Timer {
    id: toastCloseTimer
    interval: 160
    onTriggered: if (!root.toastShown) root.toastActive = false
  }

  // One seat switch fires an activelayout per keyboard; read devices once
  // after they settle rather than once per event.
  Timer {
    id: eventSettleTimer
    interval: 150
    onTriggered: root.refresh()
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
    if (!catalogProc.running) catalogProc.running = true
    configDirProc.running = true
  }
}

.pragma library

var INPUT_MAX_BYTES = 262144
var CONFIG_MAX_BYTES = 16384
var DEVICES_MAX_BYTES = 262144
var XKB_MAX_BYTES = 524288
var BACKUPS_MAX_BYTES = 65536

// xkb holds at most four groups, so that is what the plugin writes. A file
// written by hand may list more; those are read (and shown) but only the
// first four ever take effect.
var MAX_LAYOUTS = 4
var MAX_READ_LAYOUTS = 32
var MAX_LAYOUT_NAME_CHARS = 64
var MAX_OPTIONS = 32
var MAX_OPTION_CHARS = 128
var MAX_DEVICE_ROWS = 128
var MAX_DEVICE_NAME_CHARS = 256
var MAX_KEYMAP_NAME_CHARS = 256
var MAX_LAYOUT_INDEX = 4096
var MAX_XKB_LINES = 16384
var MAX_KEYMAP_ROWS = 4096
var MAX_BRIEF_CHARS = 64
var MAX_DESCRIPTION_CHARS = 256
var MAX_BACKUP_ROWS = 64

// These devices carry the seat layout and answer switchxkblayout, but are not
// keyboards a user types on (same exclusions as Omarchy's first-party widget).
var untypedKeyboard = /^(hl-virtual-keyboard|power-button|sleep-button|lid-switch|video-bus)/
var controls = /[\u0000-\u001f\u007f]/
var layoutName = /^[A-Za-z0-9_+-]{1,64}$/
var variantName = /^[A-Za-z0-9_+-]{0,64}$/
var optionName = /^[A-Za-z0-9_+.-]+:[A-Za-z0-9_+.-]+$/
var groupOption = /^grp:[a-z0-9_]{1,48}$/
// Names that go into a `hyprctl --batch` string, where `;` separates commands
// and whitespace separates arguments. Anything else is never switched.
var batchSafeName = /^[A-Za-z0-9_.:-]{1,256}$/
var rotatingBackupId = /^input\.lua\.[0-9]{8}-[0-9]{6}(?:-[0-9]{1,2})?$/
var originalBackupId = /^input\.lua\.bak\.[0-9]{1,12}(?:\.[0-9]{1,2})?$/

// Switch-key choices, as xkb option names. Every Super/Win and *_space_*
// variant is left out on purpose: Omarchy binds Super+Space and friends.
// "none" writes no grp: option at all, for switching through a Hyprland
// binding to `omarchy-shell lef.keyboard-layout next` instead.
var HOTKEYS = [
  { value: "grp:caps_toggle", label: "Caps Lock" },
  { value: "grp:shift_caps_toggle", label: "Shift+Caps Lock" },
  { value: "grp:alt_caps_toggle", label: "Alt+Caps Lock" },
  { value: "grp:alt_shift_toggle", label: "Alt+Shift" },
  { value: "grp:lalt_lshift_toggle", label: "Left Alt+Left Shift" },
  { value: "grp:ctrl_shift_toggle", label: "Ctrl+Shift" },
  { value: "grp:lctrl_lshift_toggle", label: "Left Ctrl+Left Shift" },
  { value: "grp:ctrl_alt_toggle", label: "Ctrl+Alt" },
  { value: "grp:shifts_toggle", label: "Both Shifts together" },
  { value: "grp:alts_toggle", label: "Both Alts together" },
  { value: "grp:menu_toggle", label: "Menu key" },
  { value: "grp:rctrl_toggle", label: "Right Ctrl" },
  { value: "grp:toggle", label: "Right Alt" },
  { value: "grp:rshift_toggle", label: "Right Shift" },
  { value: "grp:sclk_toggle", label: "Scroll Lock" },
  { value: "none", label: "None (keybinding / bar only)" }
]
var LED_HOTKEY = "grp:caps_toggle"
var LED_OPTION = "grp_led:caps"

function success(value) {
  return { ok: true, value: value, error: "" }
}

function failure(message) {
  return { ok: false, value: null, error: message }
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function isBoundedText(value, maxChars, allowEmpty) {
  return typeof value === "string"
    && value.length <= maxChars
    && (allowEmpty || value.length > 0)
    && !controls.test(value)
}

function hasOwn(object, key) {
  return Object.prototype.hasOwnProperty.call(object, key)
}

// ----------------------------------------------------------------- config --

function parseConfig(text) {
  var parsed
  try { parsed = JSON.parse(String(text)) }
  catch (error) { return failure("config.json is not valid JSON") }

  if (!isRecord(parsed)) return failure("config.json must contain an object")
  if (parsed.asked !== undefined && typeof parsed.asked !== "boolean")
    return failure("config.json asked must be a boolean")
  if (parsed.placement !== undefined
      && (typeof parsed.placement !== "string"
          || (parsed.placement !== "center" && parsed.placement !== "right")))
    return failure("config.json placement must be center or right")
  if (parsed.toast !== undefined && typeof parsed.toast !== "boolean")
    return failure("config.json toast must be a boolean")
  if (parsed.highlight !== undefined && typeof parsed.highlight !== "boolean")
    return failure("config.json highlight must be a boolean")

  return success({
    placement: parsed.placement === "center" ? "center" : "right",
    askedState: parsed.asked === true ? 1 : -1,
    toast: parsed.toast === true,
    highlight: parsed.highlight === true
  })
}

function configText(state) {
  return JSON.stringify({
    asked: true,
    placement: state.placement === "center" ? "center" : "right",
    toast: state.toast === true,
    highlight: state.highlight === true
  }) + "\n"
}

// -------------------------------------------------------------- input.lua --

function isStringArray(value, maxItems) {
  if (!Array.isArray(value) || value.length > maxItems) return false
  for (var i = 0; i < value.length; i++)
    if (typeof value[i] !== "string") return false
  return true
}

// Validates the JSON printed by `InputLua.pl read` and shapes it for the UI.
function parseLua(text) {
  var parsed
  try { parsed = JSON.parse(String(text)) }
  catch (error) { return failure("input.lua reader returned invalid JSON") }

  if (!isRecord(parsed)) return failure("input.lua reader returned an invalid shape")
  if (!isStringArray(parsed.layouts, MAX_READ_LAYOUTS)
      || !isStringArray(parsed.variants, MAX_READ_LAYOUTS)
      || !isStringArray(parsed.options, MAX_OPTIONS)
      || parsed.variants.length !== parsed.layouts.length)
    return failure("input.lua reader returned an invalid shape")

  var layouts = []
  for (var i = 0; i < parsed.layouts.length; i++) {
    if (!layoutName.test(parsed.layouts[i]) || !variantName.test(parsed.variants[i]))
      return failure("input.lua contains an invalid layout or variant name")
    layouts.push({ layout: parsed.layouts[i], variant: parsed.variants[i] })
  }

  var hotkey = "none"
  var led = false
  for (var j = 0; j < parsed.options.length; j++) {
    var option = parsed.options[j]
    if (option.length > MAX_OPTION_CHARS || !optionName.test(option))
      return failure("input.lua contains an invalid kb_options entry")
    if (option === LED_OPTION) led = true
    else if (hotkey === "none" && groupOption.test(option)) hotkey = option
  }

  return success({
    layouts: layouts,
    options: parsed.options.slice(),
    hotkey: hotkey,
    led: led
  })
}

function layoutSpec(entry) {
  if (!entry) return ""
  return entry.variant ? entry.layout + "(" + entry.variant + ")" : entry.layout
}

function parseLayoutSpec(spec) {
  var match = String(spec).match(/^([A-Za-z0-9_+-]{1,64})(?:\(([A-Za-z0-9_+-]{1,64})\))?$/)
  if (!match) return null
  return { layout: match[1], variant: match[2] || "" }
}

// Password prompts that start on the first layout (hyprlock, a fresh
// session, apps that reset the layout) type whatever that layout produces.
// Anything other than plain English (US) there risks a password typed with
// the wrong characters, so the panel warns and asks before applying it.
var PASSWORD_SAFE_MAIN = "us"

function mainLayoutRisksPasswords(layouts) {
  if (!Array.isArray(layouts) || layouts.length === 0) return false
  return layoutSpec(layouts[0]) !== PASSWORD_SAFE_MAIN
}

// True when applying DRAFT would newly put a password-risky layout first.
function needsPasswordConfirm(current, draft) {
  if (!mainLayoutRisksPasswords(draft)) return false
  var before = Array.isArray(current) && current.length > 0 ? layoutSpec(current[0]) : ""
  return before !== layoutSpec(draft[0])
}

function isKnownHotkey(value) {
  for (var i = 0; i < HOTKEYS.length; i++)
    if (HOTKEYS[i].value === value) return true
  return false
}

function hotkeyLabel(value) {
  for (var i = 0; i < HOTKEYS.length; i++)
    if (HOTKEYS[i].value === value) return HOTKEYS[i].label
  return "Custom (" + value + ")"
}

// Returns the writer's layout, variant and group-option arguments, or an error.
// CURRENT_HOTKEY lets an unlisted grp: option already in input.lua be kept.
function writeArguments(layouts, hotkey, led, currentHotkey) {
  if (!Array.isArray(layouts) || layouts.length === 0)
    return failure("Pick at least one layout")
  if (layouts.length > MAX_LAYOUTS)
    return failure("xkb supports at most " + MAX_LAYOUTS + " layouts")

  var seen = {}
  var names = []
  var variants = []
  for (var i = 0; i < layouts.length; i++) {
    var entry = layouts[i]
    if (!isRecord(entry) || typeof entry.layout !== "string" || typeof entry.variant !== "string"
        || !layoutName.test(entry.layout) || !variantName.test(entry.variant))
      return failure("Invalid layout name")
    var key = "$" + layoutSpec(entry)
    if (hasOwn(seen, key)) return failure("The same layout is listed twice")
    seen[key] = true
    names.push(entry.layout)
    variants.push(entry.variant)
  }

  if (typeof hotkey !== "string"
      || !(isKnownHotkey(hotkey) || (hotkey === currentHotkey && groupOption.test(hotkey))))
    return failure("Unknown switch key: " + hotkey)

  var groups = []
  if (hotkey !== "none") groups.push(hotkey)
  if (led === true && hotkey === LED_HOTKEY) groups.push(LED_OPTION)

  var anyVariant = variants.some(function (v) { return v !== "" })
  return success({
    layouts: names.join(","),
    variants: anyVariant ? variants.join(",") : "",
    groups: groups.join(",")
  })
}

// ---------------------------------------------------------------- devices --

function isTypedKeyboard(name) {
  return !untypedKeyboard.test(String(name || ""))
}

// Every keyboard on the seat carries the same layout list, but only the one
// being typed on advances through it. The keyboard the latest activelayout
// event named wins; the furthest-advanced one is only a fallback. Comparing
// positions alone reads a stale keyboard the moment the typed one wraps from
// its last layout back to the first.
function selectKeyboard(typed, namedByEvent) {
  if (!typed || typed.length === 0) return null
  for (var i = 0; i < typed.length; i++)
    if (typed[i].name === namedByEvent) return typed[i]
  var furthest = typed[0]
  for (var j = 1; j < typed.length; j++)
    if (typed[j].index > furthest.index) furthest = typed[j]
  return furthest
}

function parseDevices(text, namedByEvent) {
  var parsed
  try { parsed = JSON.parse(String(text)) }
  catch (error) { return failure("hyprctl devices returned invalid JSON") }

  if (!isRecord(parsed) || !Array.isArray(parsed.keyboards))
    return failure("hyprctl devices has an invalid top-level shape")
  if (parsed.keyboards.length > MAX_DEVICE_ROWS)
    return failure("hyprctl devices returned too many keyboard rows")

  var typed = []
  for (var i = 0; i < parsed.keyboards.length; i++) {
    var row = parsed.keyboards[i]
    if (!isRecord(row)) return failure("hyprctl devices contains a non-object keyboard row")

    if (!isBoundedText(row.name, MAX_DEVICE_NAME_CHARS, false))
      return failure("hyprctl devices contains an invalid keyboard name")

    var keymap = row.active_keymap
    if (!isBoundedText(keymap, MAX_KEYMAP_NAME_CHARS, true))
      return failure("hyprctl devices contains an invalid active keymap")

    var index = row.active_layout_index
    if (typeof index !== "number" || !isFinite(index) || Math.floor(index) !== index
        || index < 0 || index > MAX_LAYOUT_INDEX)
      return failure("hyprctl devices contains an invalid layout index")

    if (isTypedKeyboard(row.name))
      typed.push({ name: row.name, keymap: keymap, index: index })
  }

  var chosen = selectKeyboard(typed, namedByEvent)
  if (chosen === null)
    return success({ keyboards: [], keyboardName: "", currentKeymap: "", currentIndex: 0 })
  if (chosen.keymap === "")
    return failure("hyprctl devices did not report an active keymap")

  return success({
    keyboards: typed,
    keyboardName: chosen.name,
    currentKeymap: chosen.keymap,
    currentIndex: chosen.index
  })
}

// An activelayout event carries "keyboard,layout description"; PARTS is what
// HyprlandEvent.parse(2) returned — a Qt string list, which is array-like but
// not a JS Array. Returns null for a keyboard nobody types on or for anything
// malformed.
function parseLayoutEvent(parts) {
  if (parts === null || typeof parts !== "object" || typeof parts.length !== "number"
      || parts.length < 2)
    return null
  var name = String(parts[0])
  var keymap = String(parts[1])
  if (!isBoundedText(name, MAX_DEVICE_NAME_CHARS, false) || !isTypedKeyboard(name)) return null
  if (!isBoundedText(keymap, MAX_KEYMAP_NAME_CHARS, false)) return null
  return { name: name, keymap: keymap }
}

// The index a next / prev / set action lands on, or -1 when it cannot apply.
function targetIndex(current, count, action) {
  if (typeof count !== "number" || count < 1) return -1
  var from = typeof current === "number" && current >= 0 && current < count ? current : 0
  if (action === "next") return count < 2 ? -1 : (from + 1) % count
  if (action === "prev") return count < 2 ? -1 : (from + count - 1) % count
  if (typeof action === "number" && Math.floor(action) === action && action >= 0 && action < count)
    return action
  return -1
}

// `set` accepts an index ("1"), a layout ("gr") or a spec ("gr(polytonic)").
function resolveSetTarget(argument, layouts) {
  var text = String(argument === undefined || argument === null ? "" : argument).trim()
  if (/^[0-9]{1,2}$/.test(text)) {
    var index = parseInt(text, 10)
    return index < layouts.length ? index : -1
  }
  var wanted = parseLayoutSpec(text)
  if (!wanted) return -1
  for (var i = 0; i < layouts.length; i++)
    if (layoutSpec(layouts[i]) === text) return i
  if (text.indexOf("(") === -1)
    for (var j = 0; j < layouts.length; j++)
      if (layouts[j].layout === wanted.layout) return j
  return -1
}

// One `hyprctl --batch` string that sets every typed keyboard to the same
// absolute index, so several physical keyboards never drift apart. Returns
// "" when nothing safe can be switched.
function switchBatch(keyboards, index) {
  if (typeof index !== "number" || index < 0 || Math.floor(index) !== index
      || index > MAX_LAYOUT_INDEX)
    return ""
  var commands = []
  for (var i = 0; i < (keyboards || []).length; i++) {
    var name = keyboards[i] && keyboards[i].name
    if (typeof name === "string" && batchSafeName.test(name) && isTypedKeyboard(name))
      commands.push("switchxkblayout " + name + " " + index)
  }
  return commands.join(" ; ")
}

// ------------------------------------------------------------- xkb catalog --

function unquoteSingle(value) {
  if (value.length >= 2 && value.charAt(0) === "'"
      && value.charAt(value.length - 1) === "'")
    return value.slice(1, -1)
  return value
}

// Reads `xkbcli list --load-exotic`: every layout/variant pair with its short
// language code and description. Returns { briefs, entries } where briefs is
// a "$"-prefixed description -> brief lookup (the prefix keeps descriptions
// such as "__proto__" away from object prototype names).
function parseCatalog(text) {
  var lines = String(text).split("\n")
  if (lines.length > MAX_XKB_LINES)
    return failure("xkbcli returned too many output lines")

  var briefs = {}
  var entries = []
  var row = null
  var inLayouts = false
  var rowCount = 0

  function finish() {
    if (row && row.description !== undefined && row.brief !== undefined) {
      briefs["$" + row.description] = row.brief
      if (row.layout !== undefined && layoutName.test(row.layout)
          && variantName.test(row.variant || ""))
        entries.push({
          layout: row.layout,
          variant: row.variant || "",
          brief: row.brief,
          description: row.description
        })
    }
    row = null
  }

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line === "layouts:") {
      finish()
      inLayouts = true
      continue
    }
    if (inLayouts && /^[A-Za-z_][A-Za-z0-9_]*:$/.test(line)) {
      finish()
      inLayouts = false
      continue
    }
    if (!inLayouts) continue

    var start = line.match(/^- layout: (.*)$/)
    if (start || /^- /.test(line)) {
      finish()
      rowCount++
      if (rowCount > MAX_KEYMAP_ROWS)
        return failure("xkbcli returned too many keymap rows")
      row = {}
      if (start) row.layout = unquoteSingle(start[1])
      continue
    }
    if (!row) continue

    var field = line.match(/^  (variant|brief|description): (.*)$/)
    if (!field) continue
    var value = unquoteSingle(field[2])
    if (field[1] === "brief") {
      if (!isBoundedText(value, MAX_BRIEF_CHARS, false))
        return failure("xkbcli returned an invalid brief")
      row.brief = value
    } else if (field[1] === "description") {
      if (!isBoundedText(value, MAX_DESCRIPTION_CHARS, false))
        return failure("xkbcli returned an invalid description")
      row.description = value
    } else {
      if (!isBoundedText(value, MAX_LAYOUT_NAME_CHARS, true))
        return failure("xkbcli returned an invalid variant")
      row.variant = value
    }
  }
  finish()

  if (entries.length === 0 && Object.keys(briefs).length === 0)
    return failure("xkbcli returned no keymap descriptions")
  entries.sort(function (a, b) {
    return a.description < b.description ? -1 : a.description > b.description ? 1 : 0
  })
  return success({ briefs: briefs, entries: entries })
}

// ----------------------------------------------------------------- backups --

function isBackupId(id) {
  return typeof id === "string" && (rotatingBackupId.test(id) || originalBackupId.test(id))
}

// Validates the JSON printed by `InputLua.pl backups`.
function parseBackups(text) {
  var parsed
  try { parsed = JSON.parse(String(text)) }
  catch (error) { return failure("backup list is not valid JSON") }
  if (!Array.isArray(parsed)) return failure("backup list has an invalid shape")

  var rows = []
  for (var i = 0; i < parsed.length && rows.length < MAX_BACKUP_ROWS; i++) {
    var row = parsed[i]
    if (!isRecord(row) || !isBackupId(row.id)
        || (row.kind !== "rotating" && row.kind !== "original")
        || typeof row.time !== "number" || !isFinite(row.time)
        || typeof row.size !== "number" || !isFinite(row.size)
        || !isBoundedText(row.layouts, 2048, true)
        || typeof row.valid !== "boolean")
      return failure("backup list has an invalid row")
    rows.push({
      id: row.id, kind: row.kind, time: row.time, size: row.size,
      layouts: row.layouts, valid: row.valid
    })
  }
  return success(rows)
}

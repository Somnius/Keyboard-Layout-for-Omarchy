.pragma library

var INPUT_MAX_BYTES = 262144
var CONFIG_MAX_BYTES = 16384
var DEVICES_MAX_BYTES = 262144
var XKB_MAX_BYTES = 524288

var MAX_LAYOUTS = 32
var MAX_LAYOUT_FIELD_CHARS = 2048
var MAX_LAYOUT_NAME_CHARS = 64
var MAX_OPTIONS_FIELD_CHARS = 2048
var MAX_DEVICE_ROWS = 128
var MAX_DEVICE_NAME_CHARS = 256
var MAX_KEYMAP_NAME_CHARS = 256
var MAX_LAYOUT_INDEX = 4096
var MAX_XKB_LINES = 8192
var MAX_KEYMAP_ROWS = 2048
var MAX_BRIEF_CHARS = 64
var MAX_DESCRIPTION_CHARS = 256

// These devices carry the seat layout and answer switchxkblayout, but are not
// keyboards a user types on (same exclusions as Omarchy's first-party widget).
var untypedKeyboard = /^(hl-virtual-keyboard|power-button|sleep-button|lid-switch|video-bus)/
var controls = /[\u0000-\u001f\u007f]/

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

  return success({
    placement: parsed.placement === "center" ? "center" : "right",
    askedState: parsed.asked === true ? 1 : -1
  })
}

function parseLua(text) {
  var source = String(text)
  var layoutMatch = source.match(/kb_layout\s*=\s*"([^"]*)"/)
  var optionMatch = source.match(/kb_options\s*=\s*"([^"]*)"/)
  var layouts = []

  if (layoutMatch) {
    var layoutField = layoutMatch[1]
    if (layoutField.length > MAX_LAYOUT_FIELD_CHARS || controls.test(layoutField))
      return failure("input.lua kb_layout is too long or contains control characters")

    var parts = layoutField.split(",")
    if (parts.length > MAX_LAYOUTS) return failure("input.lua has too many layouts")
    for (var i = 0; i < parts.length; i++) {
      var layout = parts[i].trim()
      if (layout === "") continue
      if (layout.length > MAX_LAYOUT_NAME_CHARS || !/^[A-Za-z0-9_+-]+$/.test(layout))
        return failure("input.lua contains an invalid layout name")
      layouts.push(layout)
    }
  }

  var options = optionMatch ? optionMatch[1] : ""
  if (options.length > MAX_OPTIONS_FIELD_CHARS || controls.test(options))
    return failure("input.lua kb_options is too long or contains control characters")

  var hotkey = "caps"
  if (/alt_shift_toggle/.test(options)) hotkey = "alt+shift"
  else if (/ctrl_shift_toggle/.test(options)) hotkey = "ctrl+shift"

  return success({
    layouts: layouts,
    hotkey: hotkey,
    led: /grp_led:caps/.test(options)
  })
}

function isTypedKeyboard(name) {
  return !untypedKeyboard.test(String(name || ""))
}

function parseDevices(text) {
  var parsed
  try { parsed = JSON.parse(String(text)) }
  catch (error) { return failure("hyprctl devices returned invalid JSON") }

  if (!isRecord(parsed) || !Array.isArray(parsed.keyboards))
    return failure("hyprctl devices has an invalid top-level shape")
  if (parsed.keyboards.length > MAX_DEVICE_ROWS)
    return failure("hyprctl devices returned too many keyboard rows")

  var candidate = null
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

    var shaped = { name: row.name, keymap: keymap, index: index }
    if (isTypedKeyboard(shaped.name)
        && (candidate === null || shaped.index > candidate.index))
      candidate = shaped
  }

  if (candidate === null)
    return success({ keyboardName: "", currentKeymap: "" })
  if (candidate.keymap === "")
    return failure("hyprctl devices did not report an active keymap")

  return success({
    keyboardName: candidate.name,
    currentKeymap: candidate.keymap
  })
}

function unquoteSingle(value) {
  if (value.length >= 2 && value.charAt(0) === "'"
      && value.charAt(value.length - 1) === "'")
    return value.slice(1, -1)
  return value
}

function parseBriefs(text) {
  var lines = String(text).split("\n")
  if (lines.length > MAX_XKB_LINES)
    return failure("xkbcli returned too many output lines")

  var briefs = {}
  var brief = ""
  var inLayouts = false
  var rowCount = 0
  var pairCount = 0

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line === "layouts:") {
      inLayouts = true
      brief = ""
      continue
    }
    if (inLayouts && /^[A-Za-z_][A-Za-z0-9_]*:$/.test(line)) {
      inLayouts = false
      brief = ""
      continue
    }
    if (!inLayouts) continue

    if (/^- /.test(line)) {
      rowCount++
      if (rowCount > MAX_KEYMAP_ROWS)
        return failure("xkbcli returned too many keymap rows")
      brief = ""
    }

    var field = line.match(/^  (brief|description): (.*)$/)
    if (!field) continue
    var value = unquoteSingle(field[2])
    if (field[1] === "brief") {
      if (!isBoundedText(value, MAX_BRIEF_CHARS, false))
        return failure("xkbcli returned an invalid brief")
      brief = value
    } else if (brief !== "") {
      if (!isBoundedText(value, MAX_DESCRIPTION_CHARS, false))
        return failure("xkbcli returned an invalid description")
      // Prefixing keeps attacker-controlled descriptions away from object
      // prototype property names while retaining constant-time lookup.
      briefs["$" + value] = brief
      pairCount++
      brief = ""
    }
  }

  if (pairCount === 0) return failure("xkbcli returned no keymap descriptions")
  return success(briefs)
}

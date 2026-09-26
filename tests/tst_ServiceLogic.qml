import QtQuick
import QtTest
import "../ServiceLogic.js" as Logic

TestCase {
  name: "ServiceLogic"

  function test_configShape() {
    var good = Logic.parseConfig('{"asked":true,"placement":"center"}')
    verify(good.ok)
    compare(good.value.askedState, 1)
    compare(good.value.placement, "center")
    compare(good.value.toast, false, "toast defaults off for older files")
    compare(good.value.highlight, false, "highlight defaults off for older files")

    var full = Logic.parseConfig('{"asked":true,"placement":"right","toast":true,"highlight":true}')
    verify(full.ok)
    compare(full.value.toast, true)
    compare(full.value.highlight, true)

    verify(!Logic.parseConfig("[]").ok)
    verify(!Logic.parseConfig('{"asked":"yes","placement":"right"}').ok)
    verify(!Logic.parseConfig('{"asked":true,"placement":7}').ok)
    verify(!Logic.parseConfig('{"asked":true,"placement":"left"}').ok)
    verify(!Logic.parseConfig('{"asked":true,"toast":"on"}').ok)
    verify(!Logic.parseConfig('{"asked":true,"highlight":1}').ok)
  }

  function test_configRoundTrip() {
    var text = Logic.configText({ placement: "center", toast: true, highlight: false })
    var parsed = Logic.parseConfig(text)
    verify(parsed.ok)
    compare(parsed.value.askedState, 1)
    compare(parsed.value.placement, "center")
    compare(parsed.value.toast, true)
    compare(Logic.parseConfig(Logic.configText({ placement: "left" })).value.placement, "right")
  }

  function test_rejectedConfigCannotReplaceLastGood() {
    var state = Logic.parseConfig('{"asked":true,"placement":"center"}').value
    var bad = Logic.parseConfig('{"asked":"yes","placement":"right"}')
    if (bad.ok) state = bad.value
    compare(state.askedState, 1)
    compare(state.placement, "center")
  }

  function readerJson(layouts, variants, options) {
    return JSON.stringify({ exists: true, layouts: layouts, variants: variants,
      options: options, present: {} })
  }

  function test_luaReaderShape() {
    var good = Logic.parseLua(readerJson(["us", "gr"], ["", "polytonic"],
      ["compose:ralt", "grp:caps_toggle", "grp_led:caps"]))
    verify(good.ok)
    compare(good.value.layouts.length, 2)
    compare(good.value.layouts[1].layout, "gr")
    compare(good.value.layouts[1].variant, "polytonic")
    compare(good.value.hotkey, "grp:caps_toggle")
    compare(good.value.led, true)
    compare(good.value.options.join(","), "compose:ralt,grp:caps_toggle,grp_led:caps")
    compare(good.value.hasOptions, false, "present flags default to absent")
    var flagged = Logic.parseLua(JSON.stringify({ exists: true, layouts: ["us"], variants: [""],
      options: [], present: { kb_layout: true, kb_options: true } }))
    compare(flagged.value.hasLayout, true)
    compare(flagged.value.hasOptions, true)

    var none = Logic.parseLua(readerJson(["us"], [""], ["compose:ralt"]))
    compare(none.value.hotkey, "none", "no grp: option means no switch key")
    compare(none.value.led, false)

    verify(!Logic.parseLua("not json").ok)
    verify(!Logic.parseLua("[]").ok)
    verify(!Logic.parseLua(readerJson(["us", "gr"], [""], [])).ok, "misaligned variants")
    verify(!Logic.parseLua(readerJson(["us;x"], [""], [])).ok)
    verify(!Logic.parseLua(readerJson(["us"], ["bad variant"], [])).ok)
    verify(!Logic.parseLua(readerJson(["us"], [""], ["no-colon"])).ok)
    verify(!Logic.parseLua(readerJson([7], [""], [])).ok)

    var tooMany = []
    var blanks = []
    for (var i = 0; i <= Logic.MAX_READ_LAYOUTS; i++) { tooMany.push("us"); blanks.push("") }
    verify(!Logic.parseLua(readerJson(tooMany, blanks, [])).ok)
  }

  function test_rejectedLuaCannotReplaceLastGood() {
    var state = Logic.parseLua(readerJson(["us", "gr"], ["", ""], ["grp:caps_toggle"])).value
    var bad = Logic.parseLua(readerJson(["us\nbad"], [""], []))
    if (bad.ok) state = bad.value
    compare(state.layouts.length, 2)
    compare(state.hotkey, "grp:caps_toggle")
  }

  function test_layoutSpecs() {
    compare(Logic.layoutSpec({ layout: "gr", variant: "" }), "gr")
    compare(Logic.layoutSpec({ layout: "gr", variant: "polytonic" }), "gr(polytonic)")
    compare(JSON.stringify(Logic.parseLayoutSpec("de(nodeadkeys)")),
      JSON.stringify({ layout: "de", variant: "nodeadkeys" }))
    compare(Logic.parseLayoutSpec("us").variant, "")
    compare(Logic.parseLayoutSpec("us(x"), null)
    compare(Logic.parseLayoutSpec("us gr"), null)
  }

  function test_passwordWarningForNonUsMain() {
    var us = { layout: "us", variant: "" }
    var intl = { layout: "us", variant: "intl" }
    var gr = { layout: "gr", variant: "" }
    verify(!Logic.mainLayoutRisksPasswords([us, gr]), "English (US) first is safe")
    verify(Logic.mainLayoutRisksPasswords([gr, us]), "Greek first warns")
    verify(Logic.mainLayoutRisksPasswords([intl, gr]), "a US variant with dead keys warns")
    verify(!Logic.mainLayoutRisksPasswords([]))

    verify(Logic.needsPasswordConfirm([us, gr], [gr, us]), "moving Greek first asks")
    verify(!Logic.needsPasswordConfirm([gr, us], [gr, us]), "an unchanged non-US main does not ask again")
    verify(!Logic.needsPasswordConfirm([gr, us], [us, gr]), "going back to US never asks")
    verify(Logic.needsPasswordConfirm([], [gr]), "a fresh non-US setup asks")
  }

  function test_hotkeysAndWriteArguments() {
    for (var i = 0; i < Logic.HOTKEYS.length; i++) {
      var value = Logic.HOTKEYS[i].value
      verify(value === "none" || /^grp:[a-z_]+$/.test(value), value)
      verify(value.indexOf("win") === -1 && value.indexOf("space") === -1,
        "no Super/Space combinations: " + value)
    }
    compare(Logic.hotkeyLabel("grp:caps_toggle"), "Caps Lock")
    compare(Logic.hotkeyLabel("grp:win_space_toggle"), "Custom (grp:win_space_toggle)")

    var us = { layout: "us", variant: "" }
    var gr = { layout: "gr", variant: "" }
    var poly = { layout: "gr", variant: "polytonic" }

    var file = ["grp:caps_toggle", "grp_led:caps"]
    var caps = Logic.writeArguments([us, gr], "grp:caps_toggle", true, "grp:caps_toggle", file, [])
    verify(caps.ok)
    compare(caps.value.layouts, "us,gr")
    compare(caps.value.variants, "-", "no variants, none live, none in effect: leave kb_variant alone")
    compare(Logic.writeArguments([us, gr], "grp:caps_toggle", true, "", file, [], true).value.variants, "",
      "a live or effective variant forces kb_variant to be written")
    compare(caps.value.options, "grp:caps_toggle,grp_led:caps")
    compare(caps.value.expected, "grp:caps_toggle,grp_led:caps")

    var alt = Logic.writeArguments([us, poly], "grp:alt_shift_toggle", true, "", file, [])
    compare(alt.value.variants, ",polytonic")
    compare(alt.value.options, "grp:alt_shift_toggle", "LED only applies to Caps Lock")

    compare(Logic.writeArguments([us], "none", true, "", file, []).value.options, "")

    var custom = Logic.writeArguments([us, gr], "grp:win_space_toggle", false, "grp:win_space_toggle", file, [])
    verify(custom.ok, "an existing custom switch key is kept")
    verify(!Logic.writeArguments([us, gr], "grp:win_space_toggle", false, "grp:caps_toggle", file, []).ok,
      "an unlisted switch key cannot be introduced")

    verify(!Logic.writeArguments([], "grp:caps_toggle", false, "", file, []).ok)
    verify(!Logic.writeArguments([us, gr, poly, { layout: "de", variant: "" },
      { layout: "fr", variant: "" }], "grp:caps_toggle", false, "", file, []).ok, "max four layouts")
    verify(!Logic.writeArguments([us, us], "grp:caps_toggle", false, "", file, []).ok, "no duplicates")
    verify(Logic.writeArguments([gr, poly], "grp:caps_toggle", false, "", file, []).ok,
      "same layout with different variants is fine")
    verify(!Logic.writeArguments([{ layout: "us;x", variant: "" }], "grp:caps_toggle", false, "", file, []).ok)
    verify(!Logic.writeArguments([us], "grp:caps_toggle;x", false, "grp:caps_toggle;x", file, []).ok)
    verify(!Logic.writeArguments([us], "grp:caps_toggle", false, "", ["bad option"], []).ok)
  }

  // Issue #1 / PR #3: a stock input.lua has no live kb_options, so Omarchy's
  // defaults are in effect and must survive the first Apply.
  function test_stockInstallKeepsEffectiveOptions() {
    var us = { layout: "us", variant: "" }
    var se = { layout: "se", variant: "" }
    var stock = ["compose:caps", "shift:both_capslock_cancel"]

    var alt = Logic.writeArguments([us, se], "grp:alt_shift_toggle", false, "none", null, stock)
    verify(alt.ok)
    compare(alt.value.options, "compose:caps,shift:both_capslock_cancel,grp:alt_shift_toggle")
    compare(alt.value.expected, "-", "the key was absent in input.lua")
    compare(alt.value.notes.length, 0)

    var caps = Logic.writeArguments([us, se], "grp:caps_toggle", true, "none", null, stock)
    compare(caps.value.options,
      "compose:ralt,shift:both_capslock_cancel,grp:caps_toggle,grp_led:caps",
      "Compose moves off Caps Lock to Right Alt")
    compare(caps.value.notes.length, 1)
    verify(caps.value.notes[0].indexOf("Right Alt") !== -1)

    var fileWins = Logic.writeArguments([us, se], "grp:alt_shift_toggle", false, "none", [], stock)
    compare(fileWins.value.options, "grp:alt_shift_toggle",
      "a live (even empty) kb_options in input.lua is the source, not the defaults")
    compare(fileWins.value.expected, "")
  }

  function test_planOptionsResolvesKeyConflicts() {
    var plan = Logic.planOptions(["caps:escape", "compose:caps", "grp:alts_toggle"], "grp:caps_toggle", false)
    compare(plan.options.join(","), "compose:ralt,grp:caps_toggle")
    compare(plan.notes.length, 2, "one note for caps:escape, one for Compose")

    var ralt = Logic.planOptions(["compose:ralt"], "grp:toggle", false)
    compare(ralt.options.join(","), "compose:menu,grp:toggle", "Right Alt switch moves Compose to Menu")

    var taken = Logic.planOptions(["compose:caps", "compose:ralt"], "grp:caps_toggle", false)
    compare(taken.options.join(","), "compose:ralt,grp:caps_toggle",
      "an existing second Compose key is kept rather than adding a third")
    verify(taken.notes[0].indexOf("stays on Right Alt") !== -1)

    var free = Logic.planOptions(["compose:caps", "lv3:ralt_switch"], "grp:alt_shift_toggle", false)
    compare(free.options.join(","), "compose:caps,lv3:ralt_switch,grp:alt_shift_toggle")
    compare(free.notes.length, 0, "no conflict, no note")

    compare(Logic.planOptions(["grp_led:scroll", "grp:ctrl_shift_toggle"], "none", true).options.join(","),
      "", "old switch options go; the LED needs Caps Lock")
  }

  function test_effectiveOptions() {
    var text = '{"option": "input:kb_layout", "str": "us,gr", "set": true }\n\n\n'
      + '{"option": "input:kb_variant", "str": ",polytonic", "set": true }\n\n\n'
      + '{"option": "input:kb_options", "str": "compose:caps,shift:both_capslock_cancel,grp:alts_toggle", "set": true }'
    var good = Logic.parseEffective(text)
    verify(good.ok)
    compare(good.value.layouts.length, 2)
    compare(good.value.layouts[1].variant, "polytonic")
    compare(good.value.hotkey, "grp:alts_toggle")
    compare(good.value.options.length, 3)
    verify(good.value.variantSet)
    verify(!Logic.parseEffective(text.replace(",polytonic", ",")).value.variantSet, "only commas is no variant")

    verify(!Logic.parseEffective("").ok)
    verify(!Logic.parseEffective('{"option":"input:kb_layout","str":"us"}').ok)
    verify(!Logic.parseEffective(text.replace("us,gr", "us;x")).ok)
    verify(!Logic.parseEffective(text.replace("grp:alts_toggle", "bad option")).ok)
  }

  function test_nonLatinMainBreaksBindings() {
    verify(Logic.mainLayoutBreaksBindings([{ layout: "gr", variant: "" }]))
    verify(Logic.mainLayoutBreaksBindings([{ layout: "ru", variant: "phonetic" }]))
    verify(!Logic.mainLayoutBreaksBindings([{ layout: "de", variant: "" }]), "Latin is fine")
    verify(!Logic.mainLayoutBreaksBindings([{ layout: "us", variant: "" }, { layout: "gr", variant: "" }]))
    verify(!Logic.mainLayoutBreaksBindings([]))
  }

  // Issue #1: ThinkPad hotkey devices outrank the real keyboard's index.
  function test_laptopDecoysAreNotKeyboards() {
    var thinkpad = JSON.stringify({ keyboards: [
      { name: "intel-hid-events", active_keymap: "Swedish", active_layout_index: 1 },
      { name: "thinkpad-extra-buttons", active_keymap: "English (US)", active_layout_index: 0 },
      { name: "at-translated-set-2-keyboard", active_keymap: "English (US)", active_layout_index: 0 }
    ] })
    var result = Logic.parseDevices(thinkpad, "")
    compare(result.value.keyboardName, "at-translated-set-2-keyboard")
    compare(result.value.keyboards.length, 1)
    verify(!Logic.isTypedKeyboard("logitech-g432-gaming-headset-consumer-control"))
    verify(!Logic.isTypedKeyboard("roccat-roccat-burst-pro-wireless-radio-control"))
    verify(!Logic.isTypedKeyboard("asus-wmi-hotkeys-extra-buttons"))
    verify(Logic.isTypedKeyboard("roccat-roccat-burst-pro-keyboard"))
    verify(Logic.isTypedKeyboard("cx-2.4g-wireless-receiver"))
  }

  function test_mainFlagBeatsFurthestBeforeAnyEvent() {
    var devices = JSON.stringify({ keyboards: [
      { name: "usb-keyboard", active_keymap: "Greek", active_layout_index: 1, main: false },
      { name: "laptop-keyboard", active_keymap: "English (US)", active_layout_index: 0, main: true }
    ] })
    compare(Logic.parseDevices(devices, "").value.keyboardName, "laptop-keyboard")
    compare(Logic.parseDevices(devices, "usb-keyboard").value.keyboardName, "usb-keyboard",
      "an event still wins over the main flag")
  }

  function validDevices() {
    return JSON.stringify({
      keyboards: [
        {
          name: "power-button",
          active_keymap: "English (US)",
          active_layout_index: 9,
          ignored: { deeply: ["unassigned"] }
        },
        {
          name: "at-translated-set-2-keyboard",
          active_keymap: "Greek",
          active_layout_index: 1,
          ignored: "not copied"
        },
        {
          name: "usb-keyboard",
          active_keymap: "English (US)",
          active_layout_index: 0
        }
      ],
      mice: [{ ignored: true }]
    })
  }

  function test_deviceRowsAreValidatedAndShaped() {
    var good = Logic.parseDevices(validDevices(), "")
    verify(good.ok)
    compare(good.value.keyboardName, "at-translated-set-2-keyboard")
    compare(good.value.currentKeymap, "Greek")
    compare(good.value.currentIndex, 1)
    compare(good.value.keyboards.length, 2, "untyped devices are dropped")
    compare(Object.keys(good.value.keyboards[0]).sort().join(","), "index,keymap,main,name")

    var rows = []
    for (var i = 0; i <= Logic.MAX_DEVICE_ROWS; i++) {
      rows.push({ name: "keyboard-" + i, active_keymap: "English", active_layout_index: 0 })
    }
    verify(!Logic.parseDevices(JSON.stringify({ keyboards: rows })).ok)
    verify(!Logic.parseDevices('{"keyboards":[{"name":7}]}').ok)
    verify(!Logic.parseDevices('{"keyboards":[{"name":"keyboard","active_keymap":"English"}]}').ok)
    verify(!Logic.parseDevices('{"keyboards":[{"name":"keyboard","active_keymap":{},"active_layout_index":0}]}').ok)
    verify(!Logic.parseDevices('{"keyboards":[{"name":"keyboard","active_keymap":"English","active_layout_index":"0"}]}').ok)
    verify(!Logic.parseDevices(JSON.stringify({ keyboards: [{
      name: "x".repeat(Logic.MAX_DEVICE_NAME_CHARS + 1),
      active_keymap: "English",
      active_layout_index: 0
    }] })).ok)

    var empty = Logic.parseDevices('{"keyboards":[{"name":"power-button","active_keymap":"x","active_layout_index":0}]}')
    verify(empty.ok)
    compare(empty.value.keyboardName, "")
  }

  // The regression the review found: after typing on usb-keyboard and wrapping
  // back to index 0, the stale laptop keyboard (still at 1) must not win.
  function test_eventNamedKeyboardWinsOverFurthest() {
    var named = Logic.parseDevices(validDevices(), "usb-keyboard")
    compare(named.value.keyboardName, "usb-keyboard")
    compare(named.value.currentKeymap, "English (US)")
    compare(named.value.currentIndex, 0)

    var gone = Logic.parseDevices(validDevices(), "unplugged-keyboard")
    compare(gone.value.keyboardName, "at-translated-set-2-keyboard",
      "falls back to the furthest keyboard when the named one is gone")
    compare(Logic.selectKeyboard([], "x"), null)
  }

  function test_rejectedDeviceDataCannotReplaceLastGood() {
    var state = { keyboardName: "old", currentKeymap: "Old keymap" }
    var good = Logic.parseDevices(validDevices(), "")
    if (good.ok) state = good.value
    var bad = Logic.parseDevices('{"keyboards":[{"name":false}]}', "")
    if (bad.ok) state = bad.value
    compare(state.keyboardName, "at-translated-set-2-keyboard")
    compare(state.currentKeymap, "Greek")
  }

  function test_layoutEvents() {
    var event = Logic.parseLayoutEvent(["usb-keyboard", "Greek"])
    compare(event.name, "usb-keyboard")
    compare(event.keymap, "Greek")
    compare(Logic.parseLayoutEvent(["hl-virtual-keyboard-1", "English (US)"]), null)
    compare(Logic.parseLayoutEvent(["power-button", "English (US)"]), null)
    compare(Logic.parseLayoutEvent(["usb-keyboard"]), null)
    compare(Logic.parseLayoutEvent(["usb-keyboard", ""]), null)
    compare(Logic.parseLayoutEvent(["usb\nkeyboard", "Greek"]), null)
    compare(Logic.parseLayoutEvent(null), null)
    // HyprlandEvent.parse() returns a Qt sequence, not a JS Array.
    var arrayLike = { 0: "usb-keyboard", 1: "Greek", length: 2 }
    compare(Logic.parseLayoutEvent(arrayLike).keymap, "Greek")
    compare(Logic.parseLayoutEvent("usb-keyboard,Greek"), null)
  }

  function test_targetIndex() {
    compare(Logic.targetIndex(0, 2, "next"), 1)
    compare(Logic.targetIndex(1, 2, "next"), 0, "wraps forward")
    compare(Logic.targetIndex(0, 3, "prev"), 2, "wraps backward")
    compare(Logic.targetIndex(2, 3, "prev"), 1)
    compare(Logic.targetIndex(0, 1, "next"), -1, "nothing to switch to")
    compare(Logic.targetIndex(7, 2, "next"), 1, "out-of-range current treated as 0")
    compare(Logic.targetIndex(0, 4, 3), 3)
    compare(Logic.targetIndex(0, 4, 4), -1)
    compare(Logic.targetIndex(0, 4, -1), -1)
    compare(Logic.targetIndex(0, 4, 1.5), -1)
    compare(Logic.targetIndex(0, 0, 0), -1)
  }

  function test_resolveSetTarget() {
    var layouts = [
      { layout: "us", variant: "" },
      { layout: "gr", variant: "polytonic" },
      { layout: "gr", variant: "" }
    ]
    compare(Logic.resolveSetTarget("0", layouts), 0)
    compare(Logic.resolveSetTarget("2", layouts), 2)
    compare(Logic.resolveSetTarget("3", layouts), -1)
    compare(Logic.resolveSetTarget("gr", layouts), 2, "exact spec beats first layout match")
    compare(Logic.resolveSetTarget("gr(polytonic)", layouts), 1)
    compare(Logic.resolveSetTarget("de", layouts), -1)
    compare(Logic.resolveSetTarget("us;rm", layouts), -1)
    compare(Logic.resolveSetTarget("", layouts), -1)
    compare(Logic.resolveSetTarget(undefined, layouts), -1)
  }

  function test_switchBatch() {
    var keyboards = [
      { name: "usb-keyboard" },
      { name: "at-translated-set-2-keyboard" },
      { name: "evil;dispatch exec x" },
      { name: "has space" },
      { name: "hl-virtual-keyboard" },
      { name: "power-button" }
    ]
    compare(Logic.switchBatch(keyboards, 1),
      "switchxkblayout usb-keyboard 1 ; switchxkblayout at-translated-set-2-keyboard 1")
    compare(Logic.switchBatch(keyboards, -1), "")
    compare(Logic.switchBatch(keyboards, 1.5), "")
    compare(Logic.switchBatch([], 0), "")
    compare(Logic.switchBatch([{ name: "power-button" }], 0), "")
  }

  function validCatalog() {
    return "models:\n"
      + "- name: pc105\n"
      + "  description: Generic 105-key PC\n"
      + "layouts:\n"
      + "- layout: 'us'\n"
      + "  variant: ''\n"
      + "  brief: 'en'\n"
      + "  description: English (US)\n"
      + "  iso639: ['eng']\n"
      + "- layout: 'gr'\n"
      + "  variant: 'polytonic'\n"
      + "  brief: 'gr'\n"
      + "  description: Greek (polytonic)\n"
      + "- layout: 'xx'\n"
      + "  brief: 'safe'\n"
      + "  description: __proto__\n"
      + "option_groups:\n"
      + "- name: 'grp'\n"
      + "  description: Switching to another layout\n"
  }

  function test_catalogRowsAndStringsAreBounded() {
    var good = Logic.parseCatalog(validCatalog())
    verify(good.ok)
    compare(good.value.briefs["$English (US)"], "en")
    compare(good.value.briefs["$__proto__"], "safe")
    compare(Object.getPrototypeOf(good.value.briefs), Object.prototype)
    compare(good.value.entries.length, 3)
    var poly = good.value.entries.filter(function (e) { return e.variant === "polytonic" })[0]
    compare(poly.layout, "gr")
    compare(poly.description, "Greek (polytonic)")
    compare(good.value.briefs["$Switching to another layout"], undefined,
      "option groups are not layouts")

    var rows = ["layouts:"]
    for (var i = 0; i <= Logic.MAX_KEYMAP_ROWS; i++) {
      rows.push("- layout: 'x'")
      rows.push("  brief: 'x'")
      rows.push("  description: row " + i)
    }
    verify(!Logic.parseCatalog(rows.join("\n")).ok)

    var longDescription = "layouts:\n- layout: 'x'\n  brief: 'x'\n  description: "
      + "d".repeat(Logic.MAX_DESCRIPTION_CHARS + 1) + "\n"
    verify(!Logic.parseCatalog(longDescription).ok)
    verify(!Logic.parseCatalog("layouts:\n- layout: 'x'\n  brief: '\u0001'\n  description: bad\n").ok)
    verify(!Logic.parseCatalog("layouts:\n").ok)

    var oddName = Logic.parseCatalog("layouts:\n- layout: 'a b'\n  brief: 'x'\n  description: Odd\n"
      + "- layout: 'us'\n  brief: 'en'\n  description: English (US)\n")
    verify(oddName.ok)
    compare(oddName.value.entries.length, 1, "unusable layout names are not offered")
    compare(oddName.value.briefs["$Odd"], "x", "but still label the bar")
  }

  function test_rejectedCatalogCannotReplaceLastGood() {
    var state = Logic.parseCatalog(validCatalog()).value
    var bad = Logic.parseCatalog("layouts:\n")
    if (bad.ok) state = bad.value
    compare(state.briefs["$English (US)"], "en")
  }

  function test_backupList() {
    var good = Logic.parseBackups(JSON.stringify([
      { id: "input.lua.20260926-141345-2", kind: "rotating", time: 1, size: 10,
        layouts: "us,gr", valid: true, extra: "dropped" },
      { id: "input.lua.bak.1787432230", kind: "original", time: 0, size: 5,
        layouts: "", valid: false }
    ]))
    verify(good.ok)
    compare(good.value.length, 2)
    compare(good.value[0].extra, undefined)

    verify(Logic.isBackupId("input.lua.20260926-141345"))
    verify(Logic.isBackupId("input.lua.bak.1787432230.3"))
    verify(!Logic.isBackupId("../input.lua"))
    verify(!Logic.isBackupId("input.lua.20260926-141345/../x"))
    verify(!Logic.isBackupId(7))

    verify(!Logic.parseBackups("{}").ok)
    verify(!Logic.parseBackups('[{"id":"../x","kind":"rotating","time":1,"size":1,"layouts":"","valid":true}]').ok)
    verify(!Logic.parseBackups('[{"id":"input.lua.bak.1","kind":"other","time":1,"size":1,"layouts":"","valid":true}]').ok)
  }
}

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

    verify(!Logic.parseConfig("[]").ok)
    verify(!Logic.parseConfig('{"asked":"yes","placement":"right"}').ok)
    verify(!Logic.parseConfig('{"asked":true,"placement":7}').ok)
    verify(!Logic.parseConfig('{"asked":true,"placement":"left"}').ok)
  }

  function test_rejectedConfigCannotReplaceLastGood() {
    var state = Logic.parseConfig('{"asked":true,"placement":"center"}').value
    var bad = Logic.parseConfig('{"asked":"yes","placement":"right"}')
    if (bad.ok) state = bad.value
    compare(state.askedState, 1)
    compare(state.placement, "center")
  }

  function test_luaFieldBounds() {
    var good = Logic.parseLua(
      'hl.config({ input = { kb_layout = "us,gr", '
        + 'kb_options = "grp:caps_toggle,grp_led:caps" } })')
    verify(good.ok)
    compare(good.value.layouts.join(","), "us,gr")
    compare(good.value.hotkey, "caps")
    compare(good.value.led, true)

    verify(!Logic.parseLua('kb_layout = "us\ngrim"').ok)
    verify(!Logic.parseLua('kb_layout = "' + "a".repeat(Logic.MAX_LAYOUT_NAME_CHARS + 1) + '"').ok)

    var tooMany = []
    for (var i = 0; i <= Logic.MAX_LAYOUTS; i++) tooMany.push("us")
    verify(!Logic.parseLua('kb_layout = "' + tooMany.join(",") + '"').ok)
  }

  function test_rejectedLuaCannotReplaceLastGood() {
    var state = Logic.parseLua('kb_layout = "us,gr"\nkb_options = "grp:caps_toggle"').value
    var bad = Logic.parseLua('kb_layout = "us\nbad"')
    if (bad.ok) state = bad.value
    compare(state.layouts.join(","), "us,gr")
    compare(state.hotkey, "caps")
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
        }
      ],
      mice: [{ ignored: true }]
    })
  }

  function test_deviceRowsAreValidatedAndShaped() {
    var good = Logic.parseDevices(validDevices())
    verify(good.ok)
    compare(good.value.keyboardName, "at-translated-set-2-keyboard")
    compare(good.value.currentKeymap, "Greek")
    compare(Object.keys(good.value).sort().join(","), "currentKeymap,keyboardName")

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
  }

  function acpiHotkeyDevices() {
    return JSON.stringify({
      keyboards: [
        {
          name: "intel-hid-events",
          active_keymap: "Swedish",
          active_layout_index: 1
        },
        {
          name: "thinkpad-extra-buttons",
          active_keymap: "Swedish",
          active_layout_index: 1
        },
        {
          name: "at-translated-set-2-keyboard",
          active_keymap: "English (US)",
          active_layout_index: 0
        },
        {
          name: "hl-virtual-keyboard-fcitx5",
          active_keymap: "English (US)",
          active_layout_index: 0
        }
      ]
    })
  }

  function test_acpiHotkeyDevicesDoNotOutrankTheRealKeyboard() {
    var result = Logic.parseDevices(acpiHotkeyDevices())
    verify(result.ok)
    compare(result.value.keyboardName, "at-translated-set-2-keyboard")
    compare(result.value.currentKeymap, "English (US)")
  }

  function test_rejectedDeviceDataCannotReplaceLastGood() {
    var state = { keyboardName: "old", currentKeymap: "Old keymap" }
    var good = Logic.parseDevices(validDevices())
    if (good.ok) state = good.value
    var bad = Logic.parseDevices('{"keyboards":[{"name":false}]}')
    if (bad.ok) state = bad.value
    compare(state.keyboardName, "at-translated-set-2-keyboard")
    compare(state.currentKeymap, "Greek")
  }

  function validBriefs() {
    return "models:\n"
      + "- name: pc105\n"
      + "  description: Generic 105-key PC\n"
      + "layouts:\n"
      + "- layout: 'us'\n"
      + "  brief: 'en'\n"
      + "  description: English (US)\n"
      + "- layout: 'xx'\n"
      + "  brief: 'safe'\n"
      + "  description: __proto__\n"
      + "option_groups:\n"
  }

  function test_keymapRowsAndStringsAreBounded() {
    var good = Logic.parseBriefs(validBriefs())
    verify(good.ok)
    compare(good.value["$English (US)"], "en")
    compare(good.value["$__proto__"], "safe")
    compare(Object.getPrototypeOf(good.value), Object.prototype)

    var rows = ["layouts:"]
    for (var i = 0; i <= Logic.MAX_KEYMAP_ROWS; i++) {
      rows.push("- layout: 'x'")
      rows.push("  brief: 'x'")
      rows.push("  description: row " + i)
    }
    verify(!Logic.parseBriefs(rows.join("\n")).ok)

    var longDescription = "layouts:\n- layout: 'x'\n  brief: 'x'\n  description: "
      + "d".repeat(Logic.MAX_DESCRIPTION_CHARS + 1) + "\n"
    verify(!Logic.parseBriefs(longDescription).ok)
    verify(!Logic.parseBriefs("layouts:\n- layout: 'x'\n  brief: '\u0001'\n  description: bad\n").ok)
    verify(!Logic.parseBriefs("layouts:\n").ok)
  }

  function test_rejectedBriefsCannotReplaceLastGood() {
    var state = Logic.parseBriefs(validBriefs()).value
    var bad = Logic.parseBriefs("layouts:\n")
    if (bad.ok) state = bad.value
    compare(state["$English (US)"], "en")
  }
}

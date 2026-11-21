pragma Singleton
import QtQuick
import "FoamyI18nText.js" as I18nText

// The login screen's FoamyI18n: the members the lock's elements use, over
// the catalog copied into the snapshot (its `strings`, `language`,
// `formatLocale` and `rightToLeft`). Main.qml sets them; a key missing from
// the catalog shows as its English text. The greeter has no Omarchy shell,
// so this replaces foamy-kit's FoamyI18n (which reads Commons.Translations).
QtObject {
  id: root

  // The snapshot's catalog for its language: English text to translation.
  property var strings: ({})
  property string language: "en"
  property string formatLocale: "en-US"
  property bool rightToLeft: false
  readonly property var translator: I18nText.translator(strings, ({}), root.number)

  function t(key, values) {
    return translator.t(key, values)
  }

  function tn(key, count, values) {
    return translator.tn(key, count, values)
  }

  // Ungrouped, in the language's decimal point and digits, like the shell's
  // I18n.formatNumber. Without `decimals` the value is written as it is.
  function number(value, decimals) {
    var n = Number(value)
    if (!isFinite(n))
      return String(value)
    var text = decimals === undefined ? String(n) : n.toFixed(decimals)
    var locale = Qt.locale(root.formatLocale)
    var zero = locale.zeroDigit.charCodeAt(0)
    var out = ""
    for (let i = 0; i < text.length; i++) {
      const c = text.charAt(i)
      if (c === ".")
        out += locale.decimalPoint
      else if (c >= "0" && c <= "9")
        out += String.fromCharCode(zero + c.charCodeAt(0) - 48)
      else
        out += c
    }
    return out
  }
}

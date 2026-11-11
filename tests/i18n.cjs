// Exercise the kit's real substitution code (FoamyI18nText.js, which FoamyI18n
// calls) with catalog data in pure model tests.
const I18n = require('../kit/node-loader.cjs').load('FoamyI18nText');
const en = require('../i18n/en.json');
const no = require('../i18n/no.json');
const translators = {
  no: I18n.translator(no, en, value => String(value)),
  en: I18n.translator(en, en, value => String(value)),
};
function text(key, language, values) {
  return translators[language === 'no' || language === 'nb' ? 'no' : 'en'].t(key, values);
}
module.exports = {text, no, en, norwegian: no, nb: no};

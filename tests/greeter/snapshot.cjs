// A fixture snapshot for tests/greeter.sh, in stage's schema
// (native/src/studio/login_screen/stage.rs) with step 3's `strings`:
//   node tests/greeter/snapshot.cjs PRESET dark|light LANGUAGE AVATAR(true|false)
// prints one compact JSON line. The look is the preset as stage filters it:
// media, status and weather hidden, and a picture source ("omarchy" or
// "picture", which Studio's showsPicture reports) as source "picture" with
// the copied background.png.
'use strict'
const fs = require('node:fs')
const path = require('node:path')
const Layout = require('../../Layout.js')

const [preset, scheme, language, avatar] = process.argv.slice(2)
if (!Layout.SELECTABLE_PRESETS.includes(preset)) throw new Error(`unknown preset ${preset}`)
if (!['dark', 'light'].includes(scheme)) throw new Error(`colours must be dark or light, not ${scheme}`)

// Two themes' colours as Commons.Color resolves them without a [lock]
// section (the lock* ones are the theme's foreground and friends): Tokyo
// Night (Omarchy's default) and Catppuccin Latte.
const SCHEMES = {
  dark: { background: '#1a1b26', foreground: '#a9b1d6', accent: '#7aa2f7', muted: '#444b6a', urgent: '#f7768e',
    warning: '#e0af68', success: '#9ece6a', error: '#f7768e', info: '#7dcfff' },
  light: { background: '#eff1f5', foreground: '#4c4f69', accent: '#1e66f5', muted: '#9ca0b0', urgent: '#d20f39',
    warning: '#df8e1d', success: '#40a02b', error: '#d20f39', info: '#04a5e5' }
}
const theme = SCHEMES[scheme]
const colors = {
  ...theme,
  lockBackground: theme.background,
  lockBorder: theme.foreground,
  lockBorderError: theme.urgent,
  lockPlaceholder: theme.foreground,
  lockSelection: theme.accent,
  lockText: theme.foreground,
  lockTextError: theme.urgent,
  popupsBackground: theme.background,
  popupsBorder: theme.foreground,
  popupsText: theme.foreground
}

const shown = Layout.preset(preset)
const showsPicture = ['omarchy', 'picture'].includes(shown.background.source)
const layout = { media: { hidden: true }, status: { hidden: true }, weather: { hidden: true } }
const look = { preset, layout }
if (showsPicture) look.background = { source: 'picture' }

const catalog = path.join(__dirname, '../../i18n', `${language}.json`)
const strings = fs.existsSync(catalog) ? JSON.parse(fs.readFileSync(catalog, 'utf8')) : {}

const snapshot = {
  version: 1,
  user: 'ada',
  timeFormat: '24h',
  showUserInfo: true,
  language,
  formatLocale: language === 'no' ? 'nb-NO' : 'en-US',
  rightToLeft: false,
  look,
  colors,
  lockThemed: [],
  strings,
  files: { background: showsPicture ? 'background.png' : null, avatar: avatar === 'true' ? 'avatar.png' : null }
}
process.stdout.write(JSON.stringify(snapshot) + '\n')

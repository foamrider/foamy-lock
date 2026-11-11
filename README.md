# Foamy Lock

A lock screen for Omarchy Quattro with a large clock, account name and avatar,
password and fingerprint authentication, network and battery status, and media
controls. It uses Omarchy's wallpaper and authentication services.

![Foamy Lock with a sample account and sample media](preview.png)

The screenshot uses synthetic account and media details and a neutral wallpaper.

## Install

Requires Omarchy 4.5 (checked against 4.5.0), Omarchy's Quickshell build and the existing
`/etc/pam.d/omarchy-lock-password` service. Fingerprint unlock also requires
Omarchy's fingerprint setup and an enrolled fingerprint. The plugin does not
install or change PAM configuration. The layout uses Adwaita Sans, URW Gothic,
and JetBrainsMono Nerd Font for the intended typography and status icons. When one
is missing, text falls back to the system sans-serif font and icons to the Omarchy
font. A theme that styles the stock lock (`[lock]` colours in `shell.toml`: `text`,
`placeholder`, `background`, `border`, `selection`, `text-error`, `border-error`)
recolours the glass; without those entries the lock keeps its white-on-glass look.

Artwork, the avatar thumbnail and background pictures additionally use ImageMagick
7 and Bubblewrap with unprivileged namespaces and seccomp support. They are
prepared by the plugin's
bundled helper, `bin/<arch>/foamy-lock-helper` (static binaries for x86-64 and
AArch64 Linux; no Python or other runtime). Remote artwork over HTTPS also needs a
CPU with AES and carry-less multiplication instructions (on x86-64 also AVX2, BMI2
and ADX: Intel Broadwell, AMD Zen or newer; on AArch64 the ARMv8 crypto extensions,
so not a Raspberry Pi 4); without them remote artwork reports `https-unsupported`.
If the helper or its sandbox cannot run, the music icon (or the account initial) is
shown. Artwork has no unsandboxed decoding fallback, and authentication depends on
neither. The same helper also finds the current wallpaper (see Wallpaper); on a CPU
without a helper binary the lock shows the plain themed background.

Install while your session is unlocked:

```sh
omarchy plugin add https://github.com/foamrider/foamy-lock.git
```

If another custom lock plugin is enabled, answer **No** to the enable prompt and
replace its entry with `foamy.lock` in `~/.config/omarchy/shell.json` as shown below.
Otherwise, you can enable Foamy Lock at the prompt; Omarchy disables the stock
lock service automatically. Keep exactly one lock service active, and keep
`omarchy.lock` in `disabledPlugins`. Preserve all unrelated entries and settings.

If both lock services end up loaded anyway, `omarchy-shell lock status` reports
`"conflict": true` with `conflictReasons` (`stock-lock-enabled`: `omarchy.lock` is
missing from `disabledPlugins`; `lock-target-shared`: another handler also answers
`lock`), and the shell log has a warning. On Omarchy 4.5 Foamy Lock keeps the
`lock` IPC target answered by itself, so the lock request and the pre-suspend status
check always reach the same lock screen. `omarchy-shell foamy.lock status` returns
the same status from a target only this plugin uses.

Apply the initial switch with `omarchy restart shell` **while unlocked**. Lock
normally with `omarchy system lock`. Restarting the shell while locked can leave
the compositor showing its lock-screen recovery screen.

## Settings

Settings belong directly on the plugin entry in the `plugins` array of
`~/.config/omarchy/shell.json`, not inside a separate `config` object. This fragment
shows the defaults; merge it into your existing file instead of replacing it:

```json
{
  "version": 1,
  "plugins": [
    {
      "id": "foamy.lock",
      "timeFormat": "24h",
      "showUserInfo": true,
      "showMedia": true,
      "showBrowserMedia": false,
      "showArtwork": true,
      "artworkHosts": [],
      "artworkFileRoots": [],
      "blankAfterSec": 30
    }
  ],
  "disabledPlugins": ["omarchy.lock"]
}
```

| Setting | Default | Values and effect |
| --- | --- | --- |
| `timeFormat` | `"24h"` | `"24h"` or `"12h"`; 12-hour time includes AM/PM. The date uses the session locale. |
| `showUserInfo` | `true` | Show the account name and avatar. Set `false` to hide both. |
| `showMedia` | `true` | Show available MPRIS media and transport controls. Set `false` to hide them. |
| `showBrowserMedia` | `false` | Also show media from web browsers (Firefox, Chromium, Chrome, Brave, Zen and others). Browsers report the page or tab title as the track title, so it stays off the lock screen unless you set `true`. |
| `showArtwork` | `true` | Prepare permitted artwork while unlocked. Set `false` to always show the music icon; titles and controls remain available. |
| `artworkHosts` | `[]` | Opt in to HTTPS artwork from at most 32 exact lowercase DNS hostnames, such as `images.example.com`. No wildcards, URL schemes, IP literals, or ports. Empty disables all remote artwork. Lock Studio's **Cover art** sets this and `showArtwork` together (see Cover art below). |
| `artworkFileRoots` | `[]` | Additional permitted local artwork directories, up to 14 absolute paths. `$XDG_CACHE_HOME` (or `~/.cache`) and `$XDG_RUNTIME_DIR` are included automatically. Values must be actual absolute paths, without `..`; `~` and environment variables are not expanded. |
| `blankAfterSec` | `30` | Integer from 1 to 2147483 seconds of lock-screen inactivity before blanking the display and keyboard backlight. `null` disables this timer. This does not unlock or suspend the computer. |

All settings are optional. Changes are watched live. Invalid setting values,
duplicate `foamy.lock` entries, or a file this plugin cannot read produce a warning
and retain the last valid preferences (the defaults on startup). Correct the file to
apply new settings.

A `shell.json` that Omarchy itself cannot use (invalid JSON, or no `"version": 1`)
is different: Omarchy then falls back to its default configuration, in which Foamy
Lock is not enabled and the stock lock is. Until the file is fixed, the stock lock
screen is used. If this happens while the screen is locked (for example after
editing the file over SSH), the session stays locked: Hyprland keeps the lock, and
the stock lock's stranded-lock recovery takes over. Nothing in this path unlocks
the session.

The automatic **lock** timeout remains Omarchy's `idle.lock` setting. This plugin's
`blankAfterSec` only controls blanking after a lock has been requested. The normal
password check and wake handling are preserved; a running password check pauses
the blanking timer. Fingerprint waiting does not prevent blanking.

The plugin reads the same `~/.config/omarchy/shell.json` and
`~/.local/state/omarchy/current/background` paths as Omarchy. It stores its derived
avatar thumbnail at `$XDG_CACHE_HOME/omarchy/foamy.lock/avatar.png`, falling back to
`~/.cache/omarchy/foamy.lock/avatar.png`.

## Look: presets, layout and background

The lock screen is made of eight elements (date, clock, account, password field,
media, status, calendar, weather) on a background. A preset chooses where each element sits and how
it looks. `layout` changes single elements, and `background` and `glass` change
what is behind them. All four keys sit on the same `foamy.lock` entry and are
optional; without them the lock looks exactly as in 1.2.0.

```json
{
  "id": "foamy.lock",
  "preset": "corner",
  "layout": { "media": { "zone": "bottom-center" }, "status": { "hidden": true } },
  "background": { "source": "picture", "path": "/home/you/Pictures/lake.jpg", "blur": 0.4, "dim": 0.3 },
  "glass": { "opacity": 0.6 }
}
```

| Preset | |
| --- | --- |
| `foamy` | **Default.** The date and a large clock at the top, the account and field below the middle, media bottom left, status top right. |
| `corner` | Everything in the two lower corners: your chip and an underline field in one, a heavy stacked time under the date in the other. |
| `editorial` | A magazine page: a spaced kicker, a serif clock, your name as the byline and an underline field, inside a thin page rule; the music as a caption. |
| `zen` | Fireflies over a dark meadow, a greeting with your first name and the field; nothing else. |
| `dock` | A band along the bottom: the time and date, the field box and the music player. |
| `island` | A black pill at the top with the time, the date and what plays; a glass pill field in the middle. |
| `split` | A solid panel on the left with the date, a bold clock, your name and the field; the wallpaper on the right. |
| `sheet` | Everything on a frosted sheet on the right: status, avatar, clock, date, field and the player. |
| `card` | A glass card in the middle: avatar, a light clock, the date and the field. |
| `cinema` | A film still: black bars over a moonlit sea, the date and time in the top bar, the field and the music as a subtitle in the bottom one. |
| `poster` | Huge hours over minutes (the minutes in the accent) on the left; the field bottom left. |
| `analog` | A watch face: a large analogue clock, the weekday in serif, the field. |
| `flip` | Flip-card hours and minutes over the date and field. |
| `ring` | The time inside a ring that fills with the minutes of the hour. |
| `calendar` | A planner: the week number, a bold clock and the field on the left; this month's calendar, large, on the right. |
| `terminal` | A console login on black: the ISO date, a mono clock, your name and a `Password:` prompt, on one margin. |
| `neon` | An outlined clock and accent edges inside a glowing accent frame, over a dark wallpaper. |
| `system` | The clock and field beside a panel with uptime, memory, load and battery. |
| `music` | Now playing: large artwork with the controls in the middle over a blurred wallpaper, the field below it. |
| `aurora` | Northern lights over a dark ridge, the date, clock and field below them. |
| `rain` | Slanted rain at three depths behind a card with a mono clock and a terminal field. |
| `constellation` | A twinkling star field; each typed character lights the next star of a figure. |
| `dotmatrix` | A dot-matrix clock and dotted field on a dark LED panel over digital rain in 5 × 7 glyphs, inside a bezel. |
| `flat` | A solid accent colour with solid surfaces and no edges. |
| `frosted` | Snow falling behind glass surfaces. |
| `fluent` | Gradient flow behind accent-edged glass and a greeting card. |

The animated presets (`zen`, `cinema`, `aurora`, `rain`, `constellation`,
`dotmatrix`, `frosted`, `fluent`) move only with GPU rendering and hold a
still frame otherwise. Under the lock's light text their picture stays dark,
on a light theme too.

Presets from `dock` on are inspired by the layouts of
[Lock Designs](https://github.com/KamradSmeshnyavy/omarchy-lock-designs) (MIT),
rebuilt from the elements, shapes and backgrounds here; no code is shared.
The editor's thumbnails are in `previews/presets` (`tests/harness.sh thumbnails`).

**Layout.** Each element takes `zone`, `style`, `order` and `hidden`, and the
optional `scale`, `opacity`, `offset`, `glass` and `screens` (below the styles):

- **`zone`.** One of `top-start`, `top-center`, `top-end`, `middle-start`,
  `middle-center`, `middle-end`, `bottom-start`, `bottom-center` and
  `bottom-end`. Start and end mean left and right, and swap in right-to-left
  languages.
- **`order`.** Elements in one zone stack by `order`, an integer from -99 to 99.
- **On narrow screens** the bottom corners are centred and stacked under the
  field, and when both middle sides are used the end side moves under the
  start side.
- **The calendar** is its own element rather than a clock style, so it can sit
  beside any clock; it keeps one size (six weeks) whatever the month.
- **The `system` panel** reads `/proc/uptime`, `/proc/loadavg` and
  `/proc/meminfo` every five seconds, only while it is shown and the display
  is on; nothing is read or kept otherwise. With `items`, each file is read
  only while an item shows it, in any style.
- **The weather** comes from [Foamy Weather](https://github.com/foamrider/foamy-weather)
  (its `current()` call; see below). No built-in preset shows it.

| Element | Styles |
| --- | --- |
| `date` | `long` (default), `caps`, `short` (abbreviated, "Sat 7 Nov"), `serif` (a large serif weekday over the spaced date), `numeric` (the locale's short date), `stacked` (a large day number beside the month and weekday), `week` (the ISO week number and the date), `iso` (the ISO date and the short weekday in the mono font, "2026-09-26  Sat") |
| `clock` | `thin` (default), `bold`, `stacked` (hours over minutes), `mono` (the Omarchy font), `outline`, `dots` (a dot-matrix face), `flip` (two cards), `analog`, `small` (one line, for a bar or card), `poster` (huge hours over accent minutes), `ring` (the time in a ring that fills over the hour), `serif` (large, light serif numerals) |
| `account` | `avatar` (default), `chip`, `name` (the name alone), `greeting` ("Good evening, Ada": a greeting for the time of day with the first name) |
| `password` | `pill` (default), `underline`, `box` (an always-visible glass box with the arrow), `dots` (no surface), `terminal` (a "Password:" prompt in the mono font), `card` (a greeting above the field) |
| `media` | `card` (default), `line`, `pill` (thumbnail, title and play/pause), `art` (large artwork with the controls below), `hero` (a large cover without a surface, the title and artist under it, no controls), `minimal` (one line of text, "♪ Title — Artist", no controls), `disc` (a round cover beside the title, artist and play/pause; it turns while the player plays, only with GPU rendering, never with reduced motion or while the display is blanked) |
| `status` | `text` (default), `icons`, `pill` (icons and the battery level in one pill), `system` (a panel with uptime, memory, load and the battery, or the network without one) |
| `calendar` | `card` (default; this month on glass, today ringed in the accent), `plain`, `week` (this week's seven days on a glass strip), `mini` (a smaller month without a card). Hidden unless a preset or `hidden: false` shows it. |
| `weather` | `compact` (default; an icon and the temperature), `pill` (one line in a glass pill), `detailed` (a glass card), `line` (one line of text, "Light rain · 6°"), `large` (a large temperature, the condition small under it), `card` (a centred glass card with the icon, temperature, condition and today's high and low, always). Hidden unless `hidden: false` shows it, and only while Foamy Weather has a report. |

**Element keys of their own.** Optional, and accepted only on their element:

| Key | Values | Default | Meaning |
| --- | --- | --- | --- |
| `password.reveal` | `always`, `typing` | `typing` for `pill` and `dots`, `always` for the others (each style's drawing before 1.3.0) | `typing` shows only the unlock hint until you type or a failure or check shows: the field's surface, line, prompt, greeting and arrow (the pill's glass, the dots' track) come with the first key. `always` shows the field while it is empty too: the pill keeps its glass with the hint inside it, and the dots get a dotted track under the editor. Either way the unlock hint and the fingerprint notice stay, and the field is live and keeps its place. A value equal to the style's own is left out of the look. |
| `status.items` | An ordered list of `network`, `battery`, `volume`, `bluetooth`, `keyboard`, `uptime`, `load`, `memory`, each at most once | the style's own (network and battery; the `system` panel's four rows) | What the status shows, in that order, in any style. An item whose source has nothing (no battery, no PipeWire sink, no Bluetooth adapter) is left out. The volume (the default sink, PipeWire), Bluetooth (on or off and connected devices) and keyboard layout (Hyprland's active layout, read with `hyprctl -j devices`; nothing is switched) are read only while their item shows. A line wider than the centre column wraps. |
| `weather.details` | `temperature`, `full` | `temperature` | `full` adds the condition and today's high and low (the `line` and `large` styles show the condition anyway; the `card` always shows everything). |
| `weather.location` | `true`, `false` | `false` | Shows the forecast's place name. Off by default: anyone can see a lock screen. |
| `media.artwork` | `true`, `false` | `true` | `false` shows the music icon in place of the player's cover in this look, and prepares no artwork for it; the `showArtwork` setting still decides whether there is any. |

**Weather.** While the lock or the preview shows a look with the weather, the
lock asks Foamy Weather (`foamy.weather current`, in-process on Omarchy 4.5)
when it opens and then every 15 minutes while the display is on. Nothing is
called when no `foamy.weather` target is loaded; a starting service is asked
again up to three times, 10 s apart. A reply is shown only when every field
checks out (numbers in range, one-line text within the documented lengths, no
control or direction-override characters), as plain text, and only while it
is under three hours old; otherwise, and for an older Foamy Weather without
`current()`, the weather is hidden. `lock status` reports its state, never the
place.

**Size, finish and free placement.** Every key is optional; without them an
element draws exactly as its preset says.

| Key | Values | Default | Meaning |
| --- | --- | --- | --- |
| `scale` | 0.5 to 2 in steps of 0.05; the field 0.85 to 1.5 | 1 | The element's size. A scaled date or clock in a centre column widens with it, up to the screen less its margins. |
| `opacity` | 0.3 to 1; the field 0.7 to 1 | 1 | The whole element's opacity. |
| `offset` | `{ "x": …, "y": … }`, both required, each -0.5 to 0.5 | none | A move from where the zone puts it, as a fraction of the screen's width (`x`) and height (`y`), so one look fits every screen size. `x` mirrors in right-to-left languages, like start and end. The rest of the zone's stack stays where it was, and a shape around its zone keeps fitting the zone, not the moved element (a shape around the module follows it). |
| `glass` | 0 to 1; the field 0.08 to 1 | the look's `glass.opacity` | The opacity of the element's own glass surface. Only these styles have one: the clock's `analog` and `ring`, the account `chip`, the field's `pill`, `box` and `card`, the media `card`, `pill` and `art`, the status `pill` and `system`, the calendar `card` and `week`, and the weather `pill`, `detailed` and `card`; the element's other styles ignore it. The date has no glass and rejects the key. |
| `screens` | `all`, `primary` | `all` | `primary` shows the element only on the monitor that receives your keystrokes (or on every monitor until one does). For the date, clock, media, status, calendar and weather; the account and the field already follow that monitor and reject the key. |

```json
"layout": { "clock": { "scale": 1.25, "offset": { "x": -0.1, "y": 0.02 } }, "media": { "glass": 0.4, "screens": "primary" } }
```

Each password style has a fixed size, so the field never moves while you type.
Every style reads the same with CPU rendering, except the artwork: the media
pill, art, hero and disc then show it as a plain square instead of a round or rounded one,
and the card's thumbnail still needs GPU rendering. Only the drawn backgrounds
move (see below).

The password field can't be hidden, and it stays in the middle or bottom row.
`showUserInfo: false` and `showMedia: false` still hide the account and media
whatever the layout says. Artwork is prepared only while a media style
that shows it (`card`, `pill`, `art`, `hero` or `disc`) is shown.

**Background.** These keys set what's behind the elements:

- **`source`.** One of:
  - `omarchy` (default; **Wallpaper** in Lock Studio): the current Omarchy
    wallpaper, as before;
  - `picture` (**Custom image** in Lock Studio): the file in `path`, an absolute `.png`, `.jpg` or `.webp`, or a
    video (`.mp4`, `.m4v`, `.mov`, `.mkv`, `.webm`; see Video below);
  - `color` (**Solid colour** in Lock Studio): the colour in `color`, either
    one of the theme's colours by name (`background`, the default, `accent`,
    `muted`, `urgent`; it follows the theme) or exactly `#rrggbb` (six hex
    digits; anything else is a mistake, see below);
  - `theme` and `black`, the older names of a solid colour, still read: the
    theme's background and `#000000` (`status` and `catalog` show them as
    `color`);
  - the animations (**Animation** in Lock Studio), drawn in the theme's
    colours, dark under the lock's light text (on a dark theme over its
    background; on a light theme over a deep tone of its text colour) and
    light only where a theme's `[lock]` text is dark:
    - `aurora` (**Northern lights**): curtains of the theme's green, accent and
      cyan swaying over a dark sky and a low ridge;
    - `rain` (**Rain**): slanted streaks in the accent at three depths;
    - `stars` (**Stars**): a twinkling star field with a faint Milky Way and a
      rare shooting star; each typed character lights the next star of a
      figure (`constellation`, its older name, is still read as `stars`);
    - `matrix` (**Matrix**): columns of glyphs falling in the accent;
    - `snow` (**Snow**): flakes at four depths, drifting as they fall;
    - `fireflies` (**Fireflies**): glows in the theme's yellow and green
      wandering and pulsing over a dark meadow;
    - `gradient` (**Gradient flow**): a slow, calm flow of the theme's colours
      from edge to edge, dithered so it has no contour rings;
    - `ocean` (**Ocean waves**): swells rolling under a moon.

  With the GPU each is a small fragment shader (`elements/shaders`, compiled
  with Qt's `qsb` by `elements/shaders/build.sh`; commit the `.qsb` files
  with the sources). They move only while the lock screen is shown, the display
  is on, Omarchy's animations are on and the GPU renders; otherwise (reduced
  motion, a blanked display) they hold their frame, and with CPU rendering a
  still frame is painted once instead (`elements/BackdropStill.js`, the same
  picture). Nothing is fetched.
- **`color`.** The solid colour (above); ignored, and left out of the look,
  with any other source.
- **`shapes`.** Up to four shapes over the background and behind every
  element (see Shapes below); `[]` takes a preset's away. An older look's
  `decor` (`none`, `split`, `sheet`, `cinema`, `strip`, `island`, `frame`
  or `card`) is still read as its template, drawn exactly as before; a look
  can't have both.
- **`blur`.** From 0 to 1.
- **`dim`.** The darkening scrim, from 0 to 0.9; the default is 0.25.
- **Picture preparation.** A custom image is decoded, cropped to the screen and
  blurred by the bundled helper in its sandbox while you are unlocked. The
  original file never reaches the lock screen.
- **Blur of the Omarchy wallpaper** needs GPU rendering. With CPU rendering
  the wallpaper stays sharp, and the dim still applies.
- **Underline field.** It has no surface of its own, so it keeps at least
  0.15 dim behind it.
- **`motion`.** For a video (a `picture` that is a video, or an Omarchy
  wallpaper that is one): `still` (default) or `play`.
- **`pauseOnBattery`.** `true` (default) or `false`: whether a playing video
  holds still on battery.

**Video.** A video background shows its first frame, made by the helper in
its sandbox (an Omarchy video wallpaper keeps Omarchy's own still frame).
With `motion: "play"` it plays a clip that Lock Studio converted for this
file and the largest screen's native size (its Convert button, see Lock
Studio); the lock itself never converts, and without such a clip it shows
the still frame. It plays only with GPU rendering, muted and looping, and
holds its frame while the display is blanked, motion is reduced, the lock
isn't shown or (with `pauseOnBattery`) the laptop is on battery. After the
first playback error or 2 s without a new frame it shows the still frame for
the rest of that lock (`video.failure` in `status`). Play is experimental:
the clip is decoded inside the shell, so a decoder crash would take the lock
screen with it and leave the session locked behind a dead screen. Then log
in on a text console (Ctrl+Alt+F3) and run `loginctl unlock-session`.

Conversion limits: the input at most 2 GiB, MP4/MOV, MKV or WebM with H.264,
HEVC, VP8, VP9 or AV1 video up to 7680 x 4320; the first 60 s are used, at
the source's frame rate up to 30 fps; the output is H.264 at the screen's
native size up to 3840 x 2160, at most 150 MiB, without sound or metadata.
The helper decodes the file and encodes the clip in two separate sandboxes,
at idle priority with up to 16 threads (one conversion at a time, cancel any
time, 10 minutes at most). It keeps at most three clips in
`$XDG_CACHE_HOME/omarchy/foamy.lock/video/` (`~/.cache/omarchy/foamy.lock/video/`
by default), the oldest evicted.

**Shapes.** `background.shapes` is a list of at most four shapes (at most two
of them frosted), drawn over the background and under every element, frosted
ones first, then in list order. They are background: they never cover an
element, never take part in the geometry check and never cause a fallback.

```json
"background": {
  "source": "omarchy", "blur": 0.4, "dim": 0.25,
  "shapes": [
    { "kind": "box", "wrap": { "modules": ["media"] }, "pad": { "x": 10, "y": 10 },
      "radius": "auto", "fill": { "color": "black", "opacity": 0.82 }, "absorb": true },
    { "kind": "frame", "style": "line" }
  ]
}
```

- **`kind`.** `box`: a rounded rectangle around what it wraps, plus `pad`;
  `panel`: a rectangle along one screen `edge` (`start`, `end`, `top`,
  `bottom`; start and end mirror right to left), as thick as what it wraps
  needs plus `pad`, within `size`; `frame`: a border inset from the edges.
- **`wrap`.** `{ "zones": [...] }`: the shown modules in those zones, where the
  zone puts them (an offset never drags the shape along; on narrow screens a
  zone stacked with another wraps both); or `{ "modules": [...] }`: those
  modules where they are drawn, so the shape follows an offset, a scale and
  content that arrives late. A box needs one; a panel without one keeps its
  minimum size. A box around nothing shown isn't drawn (a module hidden by
  privacy leaves no empty pill).
- **Geometry.** Lengths are whole pixels at 1080p, scaled with the screen:
  `pad` (a box: `{ "x", "y" }`, 0 to 120, default 24 and 16; a panel: 0 to 200,
  default 32), `inset` (a panel, 0 to 64, default 0; a box with
  `"stretch": "across"`, which spans the screen's width, default 16; a frame, 0
  to 24, default 12) and `radius` (default 24 for a box, 0 for a panel, 22 for a
  frame; a box's `"auto"` is the wrapped module's own corners plus the
  padding). A panel's `size` takes `min`, `max` and `fillPast` (past it the
  panel fills the screen), each `{ "screen": 0.05–1 }` or `{ "px": 0–4000 }`.
- **`fill`.** `color`: `auto` (default: follows the glass tint, dark over clear
  glass and the look's glass under `accent` and `solid`), `glass` (the look's
  glass), `surface` (exactly what the wrapped modules' own glass draws) or
  `black`; `opacity` (0 to 1, default 0.6); `frost` blurs a picture background
  behind it (GPU rendering only).
- **`border`.** `color` `glass` (default) or `accent`, `width` 0 to 4 (default
  1), and on a panel `sides: "inner"`, only the edge facing the screen.
- **`absorb`.** `true` makes the shape the only background of the modules it
  wraps: the media card, pill and art, the status pill and system panel, the
  calendar card and week, the weather pill, detailed and card, and the account
  chip draw no surface of their own (their content stays where it is). The
  password field always keeps its own. A box around one module with `pad` 0,
  `radius: "auto"`, `fill: { "color": "surface", "opacity": 1 }` and `absorb`
  is exactly that module's own surface, however it moves or grows.
- **`style`** (a frame). `auto` (default: a glow in the accent with the `accent`
  tint, otherwise a dark bezel), `bezel`, `glow` or `line`.
- **Templates.** The presets' shapes, and Lock Studio's Add shape: `island` (a
  dark pill around the top-center zone), `card` (frosted glass around the
  middle-center zone), `split` (a panel on the start side, at least 38%, with an
  accent inner edge; it fills a narrow screen), `sheet` (a frosted panel on
  the end side), `strip` (a band across the bottom row), `cinema` (black bars
  at the top and bottom) and `frame`. A bottom panel, or a box across the
  screen, around the bottom-center zone holds the bottom row: the
  bottom-center stack sits at the bottom edge, in the band.

**Glass.** `opacity` (0 to 1, default 1) scales the transparency of the glass
behind the media card, the account chip, the field and the shapes.
`tint` is `none` (default, white glass), `accent` (the theme accent on the
edges, and the outline clock drawn in it) or `solid` (opaque surfaces without
edges).

**Mistakes and safety.** A mistake in these keys, such as an unknown name or a
value out of range, leaves the previous look in place and shows up as
`lookError` in `omarchy-shell foamy.lock status`. It never resets the other
settings, and a mistake in the other settings never resets the look. Each time
the lock screen is shown, it checks what each screen draws: the field must be
on the screen, its top below the top third, and not covered by another
element; every element must be on the screen; and elements in different zones,
or moved with `offset`, must not overlap (elements stacked in one zone may, as
the clocks pull up into the date). If not, that screen shows the `foamy` preset
instead, and if even that doesn't fit, only the field, centred. `status`
reports this as `layoutError` and `fallbackPreset`. The codes are `password-missing`,
`password-offscreen`, `password-high`, `password-overlap`, `element-offscreen`
and `element-overlap`.

**Several monitors.** Every monitor shows the same layout. The account and the
field's surround show only on the monitor that receives your keystrokes, or on
every monitor until one does. A password field that accepts typing stays on
every monitor, so a keystroke is never lost.

**Previewing a preset.** `omarchy-shell foamy.lock previewPreset corner` opens
the preview overlay with a preset without saving anything. `omarchy-shell lock
preview` shows your saved look.

Editors use three more calls on the same target: `catalog` (version 3) lists the elements, zones,
styles, the element keys with their limits (`elementLimits`: ranges, glass styles, `screens`, and each element's own keys under `options` with their values and defaults; `elementKeysFor` names every key an element takes), the status items, whether Foamy Weather answers (`weather`), presets (with their thumbnails), background sources (`backgroundSources`, the animations among them in `backgroundAnimations`, the named colours in `backgroundColors`), shapes (`shapeKinds`, `shapeLimits` and `templates`; `backgroundDecor` for older clients), glass tints and the saved look; `previewLook '<json>'` previews an unsaved look;
`saveLook '<json>'` saves one. Both take the look keys above, validated by the same
rules; `saveLook` replaces only those keys in the `foamy.lock` entry and writes through
Omarchy's own settings path, which keeps a symlinked `shell.json` a symlink.
`saveLook` also takes `userPreset`, the id of the user preset the look came from
(omitted, the link is removed). A `shell.json` that Omarchy can't read is never
written: the answer is then `write-failed`. A JSON argument (`previewLook`, `saveLook`,
`savePreset`) over 64 KiB is refused before it is parsed: `invalid: argument over 65536 bytes`.

**Cover art.** `omarchy-shell foamy.lock setCoverArt off|player|spotify` sets
`showArtwork` and `artworkHosts` to one of three fixed pairs and keeps every other
key: `off` is `false` and `[]`; `player` is `true` and `[]` (the player's own
`file://` art under `artworkFileRoots`, the default); `spotify` is `true` and
`["i.scdn.co"]`, exactly the host Spotify's `mpris:artUrl` names. It takes no
other argument (a host never comes from the call) and answers like `saveLook`;
while locked it answers `locked`. `catalog` names the current mode (`coverArt`:
one of the three, or `custom` for hosts set by hand). Remote covers still go
through the helper's checks below.

**User presets.** `userPresets` in the `foamy.lock` entry holds your own presets,
newest first: `[{"id": "u-…", "name": "Default (mine)", "look": {"preset": …,
"layout": …, "background": …, "glass": …}}]`, at most 50 and 256 KiB (items past either are
counted as skipped, not read). Each item is
checked on its own: an invalid one is skipped (`status` and `catalog` count it in
`userPresetsInvalid`), and nothing in the list can change the settings or the look.
`catalog` lists them (`userPresets`, with the built-in preset's thumbnail), and
`previewPreset user:<id>` previews one. Editors change one at a time:
`savePreset '<json>'` (`{id, name, look}`; the id is the caller's own, a new id goes
first, a known one is updated), `renamePreset <id> <name>` and `deletePreset <id>`
(which also drops the look's link to it). They answer like `saveLook`, plus `full`,
`too-large` and `unknown-preset`; a repeated call answers `unchanged`.

## Lock Studio

Lock Studio is a desktop app for designing the lock screen: pick a preset, drag
the elements around a live copy of the lock screen, and adjust each one (style, size,
opacity, glass, position, which screens show it), the background and the glass.
It runs the lock screen's own drawing code in its own window, so what you see is what
the lock screen shows, and it saves through Foamy Lock (`saveLook`), never by writing
`shell.json` itself.

Open **Lock Studio** from the app launcher, or run the helper:

```sh
~/.config/omarchy/plugins/foamy.lock/bin/$HOSTTYPE/foamy-lock-helper studio
```

Opening it again brings the open window to the front.

**The launcher entry.**
- **Added automatically:** about 20 seconds after the shell starts, the lock adds the entry (`studio ensure`). It writes `~/.local/share/applications/foamy-lock-studio.desktop` and the icon under `~/.local/share/icons/hicolor/`, and it rewrites them only when they've changed, for example after the plugin moves.
- **Removed with the plugin:** the entry's command starts the helper while the helper is there. Once the plugin is gone, choosing the entry removes it and its icon. Omarchy has no removal hook, and its launcher ignores `TryExec`.
- **Turning it off:** `studio uninstall` removes the entry and keeps it off. `studio install` adds it again.

**Editing.** Drag an element on the canvas; it snaps to where it would sit in each
zone, to the screen's centre lines, to the other elements' edges and to a grid. The
library on the left lists every element: drag a hidden one onto the canvas to show
it, or drag one from the canvas back to the library to hide it. The preset is the
library's first row. Click beside the lock screen image (or press Esc) to edit the look as
a whole: background, glass and dim. Everything the pointer does, the keyboard does
too. The screen menu lists each connected screen with its native size and scale
(the canvas lays it out at its logical size, as the lock screen does) and two reference
sizes (1280 × 720, 1920 × 1080); a problem on a connected screen (an
element off screen, two elements overlapping, the password field covered or too
high) is listed under the canvas and stops Apply, one only at a reference size is
a warning.

**Element options.** The inspector also sets each element's own keys: the
password field's **Show the field** (Always, or While typing; each style starts
from its own), the status's items (a checklist: tick what it shows, reorder by
the grip or with Alt+Up and Alt+Down; a new style starts from its own contents),
the weather's details and place name (off by default), and the media's
**Cover art** (Off, From the player, Also online (Spotify): a lock screen setting
saved at once through `setCoverArt`, not part of the look or undo) with **Show the
cover in this look** (`media.artwork`). The canvas shows sample
volume, Bluetooth, keyboard layout and weather, never yours, and the problem check
uses the widest samples. When the lock screen can't reach Foamy Weather, the
Weather row says **Needs Foamy Weather**.

**The background page.** **Source** is **Wallpaper**, **Custom image**, **Solid
colour** or **Animation**, and what is under it follows the choice: the picture
(or video) and its chooser for a custom image; for a solid colour, swatches of the
theme's colours and black, and a field for any `#rrggbb` (six hex digits, checked
as you type and again by the lock screen); for an animation, a tile per animation,
each drawn by the lock screen's own code in its still frame. Blur (wallpaper and
custom image) follows. The dim (on the glass and dim page) moves in 1 % steps.

**Shapes.** Library → Scene → Shapes lists the look's shapes in drawing order
("Box around Clock, Date"), each with Move up, Move down and Remove. **Add shape**
offers the templates as drawings and a box around the selected module (up to
four shapes, two frosted). Selecting a shape (in the list, or by clicking it on
the canvas where no module is) shows only what its kind takes: what it wraps
(zones on the zone picker, which then picks several, or modules), its edge,
padding, full width, sizes (off, % or px), inset, corners (a box can match the
module's), frame style, fill and opacity (1 % steps), frost, border and whether it
is the background of the modules inside. Delete removes the selected shape, Esc
deselects it. A module's inspector has **Wrap in a shape**: a box that is exactly
the module's own surface and its only background, opened on the shapes page
(**Edit its shape** once it has one); padding then grows it evenly. The checker
warns, without blocking Apply, when a module crosses a shape's edge or leaves a
frame, frosted shapes overlap, or a shape wraps nothing. A module's **Order in
the zone** has Move up and Move down in zone.

**A video background.** "Choose picture or video…" offers MP4, MOV, MKV and WebM
videos too. For a video (or an Omarchy wallpaper that is one) the background page
shows a card: its first frame, the facts ("4 min 12 s · 3840 × 2160 · HEVC ·
412 MB"), what converting makes of it ("Uses the first 60 s, scaled to 3440 × 1440,
30 fps, no sound"), the estimated time and **Convert**. Nothing converts until you
press it; a progress bar with **Cancel** follows, then "Ready · 72 MB". Over a limit
(see Video) the card says which, and Convert is disabled. Once there is a clip,
**Motion** can be **Play (experimental)**, with **Pause on battery** (on by default).
The canvas shows the first frame; Preview full screen plays the clip as the lock
screen would.

| Keys | |
| --- | --- |
| Arrows | Move one grid step |
| Shift+arrows | Move one pixel |
| Ctrl+arrows | Move to the next zone |
| `+` / `-` | Larger or smaller |
| Delete / Insert | Hide or show the element |
| `[` / `]` | Previous or next element |
| Esc | Clear the selection (the look as a whole) |
| Shift while dragging | Drag without snapping |
| Alt while dragging | Drag along one axis |
| Ctrl+Z / Ctrl+Shift+Z | Undo / redo |
| Tab, F6 | Next control, next pane |
| `?` | All shortcuts |
| Ctrl+Q | Quit |

**Saving.**
- **Your draft** (the look and its undo steps) is kept in
  `~/.local/state/foamy-lock/studio-draft.json` a moment after each edit, so closing
  the app or a crash loses nothing. When you open the app with a draft the lock
  screen doesn't have, it asks: **Continue editing**, or **Start from saved** (which deletes
  the draft).
- **Apply to lock screen** saves the look through the running Foamy Lock. While the
  lock screen doesn't have your changes, the header says **Unsaved changes** right
  after Reset; a save clears it. A problem shows there instead, in a few words:
  refused (with the reason), the screen is locked, the shell isn't running or didn't
  answer (it is asked once more; if it still doesn't answer, the look may or may not
  be saved). Anything but a save keeps the draft.
- **Your presets** come first in the preset menu, then the built-in ones. Applying
  changes made on a built-in preset asks for a name (prefilled "Default (mine)"), saves
  your preset and applies it; **Apply without saving** applies the look as it
  is. Applying changes on one of your presets updates it. **Save as new…**, rename and
  delete (asked first) are in the menu. They live in `shell.json` with the lock
  screen's other settings (see User presets above).
- **Reset** goes back to the last saved look, or to the preset without your changes;
  either can be undone.
- **Preview full screen** shows the look on the lock screen's own preview overlay without
  saving; click or press any key to close it.
- **Quitting** (Ctrl+Q) with changes the lock screen doesn't have asks: **Apply and
  quit**, **Discard** (deletes the draft) or **Cancel**. Closing the window keeps the
  draft and quits; the next start offers it back.

**Privacy.** The canvas uses a sample account and a sample track, never your name,
avatar or what is playing. The clock, network and battery are real. The full-screen
preview is the lock screen's own and shows your real account and media. Your picture
and name on the lock screen come from your account; the first tip in the app says to
set them with Mugshot (and how to install it). The tips keep to what isn't obvious:
that, Shift and Alt while dragging, and Ctrl+arrows between zones. The app remembers
the last tip you saw in
`~/.local/state/foamy-lock/studio-state.json`.

Screenshots of the app will follow.

## Fingerprint recovery

Temporary reader or daemon errors are retried with increasing delays. If the
reader remains unreachable, the lock shows "Fingerprint reader unavailable";
password unlock remains available. Temporary availability-check errors do not
turn fingerprint unlock off for the rest of the lock session.

Some readers also need a system-level `fprintd` restart after resume. This plugin
does not install that hook or change system services. Recovery follows
[Omarchy PR #7158](https://github.com/omacom/omarchy/pull/7158), including retries
while the daemon restarts. Device errors within two seconds of a finger prompt
also back off; ordinary mismatches keep the fast retry. Display blanking pauses
new attempts, lets an active attempt finish, and preserves pending retry delays.
Input, an arriving display, or resume detection restarts the loop. Status includes
`fingerprintUnavailable` and `fingerprintPaused`.

## Wallpaper

Static wallpapers are preloaded at each display size and refreshed when the
selected file changes, including replacement at the same path. Video wallpapers
use a cached still frame: the poster of the bundled helper's sandboxed `video-probe`
(the same probe and cache as a video background, never Omarchy's `poster.sh`, whose
ffmpegthumbnailer runs outside any sandbox). Unless a look plays it, Foamy Lock
does not play video. If the helper is missing or can't read the video, it uses the
plain themed background. Wallpaper failures do not block
authentication; `lock status` reports them in `wallpaperError`.

The bundled helper (`foamy-lock-helper wallpaper <link>`, at most 2 seconds) resolves
`~/.local/state/omarchy/current/background` like `readlink -f` and stats the file it
ends at; no shell tools such as `stat` or `jq` are involved. A change of the file's
size, modification or change time, or another file in its place, reloads the image;
an unchanged file keeps the cached one. A dangling link, a missing file, a directory
or another non-regular file leaves the plain themed background with
`wallpaperError: "wallpaper-unavailable"`. `helper-unavailable` means there is no
helper binary for this CPU; the probe is then not run again until the shell reloads.

## Account name and avatar

Open **About Me** from the application launcher (the app is **Mugshot**, also
available as `mugshot`). It lets you set your account's display name and avatar.
Foamy Lock reads those account details; there is no separate name or image setting
in `shell.json`. Open the preview or lock again after saving to refresh them.

AccountsService supplies the display name and avatar when available. The passwd
entry's full name and `~/.face` are fallbacks; without a display name the login name
is shown, and without a usable image the avatar shows an initial. The picture
goes through the same sandboxed decoder as artwork (PNG, JPEG or WebP, up to
16 MiB and 4096 × 4096 pixels) and comes back as a 256 × 256 thumbnail, with a
10-second limit for the whole job. Only when Bubblewrap or ImageMagick is not
installed is the original picture shown instead; a picture the sandbox rejects or
times out on shows the initial, and `lock status` reports `avatarError`.

## Media and preview

Media controls use Quickshell's MPRIS integration directly and do not need Foamy
Media or a custom bar. A playing track with metadata takes priority; otherwise the
first player with track metadata is shown. Buttons follow the player's supported
transport actions. No controls appear when no player supplies metadata.

Privacy: anyone at the locked computer can read the shown title and artist and use
previous, play/pause and next. Transport control is deliberate: Omarchy's media keys
already work while locked (they are bound with `locked = true`), so the buttons add
no new capability, and nothing else is reachable from them. Browser players are
hidden by default (`showBrowserMedia`) because their "track title" is the page or
tab title. Set `showMedia: false` to show no media at all.

### Artwork safety and fallback

The view never loads the player's `trackArtUrl` directly. While unlocked, a
separate helper reads permitted artwork and decodes it in a Bubblewrap sandbox
without network, home-directory, session-bus, or desktop-socket access. It accepts
static PNG, JPEG, and WebP only. ImageMagick delegates and other image coders are
disabled, and the decoder cannot create subprocesses or additional namespaces.
Before the decoder reads a PNG, the helper copies it without its text chunks
(`tEXt`, `zTXt`, `iTXt`), reading only the chunk headers, so compressed text can't
expand in the decoder's memory; a PNG whose chunk list is malformed (a chunk past
the end, a type that isn't four letters, no `IEND`, more than 16384 chunks) is
refused as `invalid-png`. This applies to artwork, the avatar and background
pictures alike, and the pixels are the same.
The sandbox returns exactly 256 × 256 RGB pixels. The helper checks
their length and creates a minimal PNG without copying source metadata or source
compressed data. Only that thumbnail reaches the lock view.

Local sources must be `file:///` URLs to user-owned regular files below a
permitted directory. Symlink traversal below that directory, special files, and
parent traversal are rejected. For players that store covers elsewhere, add the
specific artwork directory to `artworkFileRoots`, rather than your whole home.

Remote artwork is off by default. Adding a hostname to `artworkHosts` allows
requests to that host while unlocked, which reveals your IP and request timing
to it. Every redirect must remain HTTPS on port 443 and use an allowed hostname.
DNS answers must be public addresses; connections are pinned to a checked IP
with normal hostname certificate verification. There are no cookies,
credentials, proxy-environment settings, or user curl configuration involved.

| Boundary | Limit |
| --- | --- |
| Input, including responses without a length header | 5 MiB |
| Source width and height | 4096 pixels each |
| Network operation, including DNS and redirects | 5 seconds; 2 redirects |
| Decoder | 256 MiB address space; 2 CPU seconds; 3 wall-clock seconds |
| Thumbnail | 256 × 256 RGB; approximately 193 KiB PNG |
| Cached thumbnails | 16 files, approximately 3 MiB total |
| Work | One job at a time; at most one start every 2 seconds |

These are upper bounds, not promises that every image within them can decode:
an image that needs more working memory falls back to the icon. The decoder
cannot spill its image cache to disk. Whole helper jobs have a 9-second limit.

On a lock request, outstanding artwork work is cancelled without delaying the
lock. No new helper jobs start while locking or locked. A track with a completed
thumbnail in this shell session's cache can show it; other tracks show the music
icon until unlocked. Cancellation cannot retract network packets already sent.
Preview follows the same policy as the current lock state.

The icon also appears during loading, for missing or rejected artwork, and on
helper or image-display errors. Stale results from cancelled tracks are ignored.
Failures are held for 60 seconds before a subsequent track/state change can retry;
there is no automatic retry loop. Disabling media or artwork cancels current work.

Generated thumbnails use a private directory at
`$XDG_CACHE_HOME/omarchy/foamy.lock/artwork` (or
`~/.cache/omarchy/foamy.lock/artwork`). They contain no embedded track names or
URLs. Old thumbnails are evicted automatically; interrupted staging files are
reclaimed by the next decoding job. A shell restart rebuilds its trusted cache
instead of treating existing disk images as validated. This protects against
untrusted media content; it does not isolate the shell from other malicious
processes already running as your Unix user.

```sh
omarchy-shell lock preview
omarchy-shell foamy.lock previewPreset zen   # a preset, not saved
omarchy-shell lock hidePreview
omarchy-shell lock status
```

Preview is a visual overlay, **not a secure lock**: a "Preview" banner says so, and
the password field shows no unlock hint. Click it or press any key to dismiss it;
for half a second after, it still takes the keyboard, so keys typed into it don't
reach the window below. A real lock request also closes it, and the preview calls
answer `locked` while the screen is locked. Preview
and status use your real account details; the README screenshot is generated
separately with synthetic data. Status includes effective settings, configuration
errors, lock state, and local account information. Do not share its output without
checking it for personal details.

Status also reports `artworkState` and a short `artworkError` code without
including artwork URLs. Sources outside `artworkHosts` or `artworkFileRoots` are
refused before any helper starts, and each error code is logged once until artwork
works again. `host-not-allowed` means remote artwork was not opted in;
`file-outside-roots` means the cover is outside the permitted directories.
`decoder-unavailable` means Bubblewrap or ImageMagick is missing; `decode-failed`
can indicate a rejected image, a resource limit, or unavailable sandbox support.
`helper-unavailable` means there is no helper binary for this CPU; artwork then
stays on the music icon and no helper is started again until the shell reloads.

### Background picture preparation

Background pictures (the look's `picture` source) are
prepared by the same helper and sandbox as artwork (`foamy-lock-helper artwork`
with the request `{"kind": "background", "path": "/absolute/path", "width": W, "height": H, "blur": B}`;
the full contract is at the top of `native/src/main.rs`). The path may be a symlink
or root-owned, like Omarchy's theme wallpapers, but must be a regular static PNG,
JPEG or WebP file. The sandbox returns exactly W × H RGB pixels, cover-scaled and
centre-cropped like Qt's `PreserveAspectCrop`; the helper checks their length and
writes a minimal PNG, so no source metadata or compressed data reaches the lock.
Blur 0 is none; otherwise it is a Gaussian with a sigma of B × min(W, H) / 40
pixels (27 px at full blur on a 1080-pixel-high screen), computed at a reduced
scale and scaled back up. Large JPEGs are decoded at a reduced scale that still
covers the screen.

| Boundary | Limit |
| --- | --- |
| Input | 32 MiB |
| Output (the screen in logical pixels) | 16 to 7680 wide, 16 to 4320 high |
| Source | 16384 pixels a side, under 64 megapixels |
| Decoder (P = W × H) | 768 MiB + 32 bytes × P address space (about 1.7 GiB at 7680 × 4320); 2 CPU seconds + 1 per started 3840 × 2160 of P (3 to 6); 1 more wall-clock second |
| Result | W × H RGB; a stored PNG of about W × H × 3 bytes (24 MiB at 3840 × 2160) |
| Cached backgrounds | 4 files, newest kept |

Very large screens on slow CPUs can reach the decoder or 9-second job limit
(`decode-timeout`, `job-timeout`). Results are kept in a private directory,
`$XDG_CACHE_HOME/omarchy/foamy.lock/background` (or
`~/.cache/omarchy/foamy.lock/background`), as `<sha256>.png`, under the same
ownership, permission, locking and staging rules as the artwork cache. Its own
error codes are `invalid-size` (width or height), `invalid-background-path` and
`background-missing`; a blur outside 0 to 1 is `invalid-request`.

## Validation

```sh
omarchy plugin validate .
/usr/lib/qt6/bin/qmllint Artwork.qml Service.qml LockView.qml elements/*.qml
node --test tests/*.test.cjs
python3 -I -B -m unittest discover -s tests -p artwork_test.py -v
FOAMY_HELPER='["bin/aarch64/foamy-lock-helper"]' python3 -I -B -m unittest discover -s tests -p artwork_test.py
python3 -I -B tests/artwork_runtime.py
bash tests/harness.sh render                  # --language no renders in Norwegian
bash tests/harness.sh parity                  # geometry against 1.2.0 (needs the git history)
bash tests/harness.sh layout                  # every preset, the style sweep and the placement cases (also: styles, placement alone)
bash tests/harness.sh runtime                 # service, PAM, fingerprint, wallpaper and IPC flows
bash tests/harness.sh thumbnails              # re-render previews/presets/*.png (480 × 270)
bash tests/harness.sh studio                  # Lock Studio offscreen, saving against a fake omarchy-shell (--language no, ar)
bash tests/kit-check.sh
```

The tests are Rust (`tests/harness`), Python 3 and Node (development only; the plugin does not need
them at runtime). `tests/plaintext.test.cjs` is a lint: every `Text` in the plugin's QML sets
`textFormat: Text.PlainText` (Text's default renders markup, so a file name like
`<img src='data:…'>` would make Qt decode an image outside the sandbox); an exception needs an
entry with its reason in the test's `ALLOWED`. `artwork_test.py` runs the helper as a process: it checks the
request/reply contract, the exact Bubblewrap command line, environment, rlimits,
inherited descriptors, policy and seccomp program (through stand-in `bwrap` and
`magick` scripts in an outer Bubblewrap namespace), HTTPS against a local TLS
server, and the real sandbox. It also covers the `wallpaper` subcommand (link chains,
touches, rewrites and failures against `readlink -f`). The `background` job's request
checks, limits, PNG writer and a real-sandbox decode are Rust unit tests in `native/`
(run by `build-native.sh --test`). `FOAMY_HELPER` selects another
build; the aarch64 binary runs through qemu binfmt, which has no seccomp, so its
real-sandbox tests are skipped. The HTTPS tests use the helper's test-only `FOAMY_LOCK_TEST_RESOLVE`
and `FOAMY_LOCK_TEST_CONNECT` overrides (documented in `native/src/main.rs`; the
shell clears the helper's environment, so they never apply there).

### Rebuilding the helper

The helper's source is `native/` (Rust; its contract is the doc comment at the top
of `native/src/main.rs`), built with the tool in `kit/native/`, which needs rustup with the
toolchain in `rust-toolchain.toml`:

```sh
export CARGO_TARGET_DIR=~/.cache/foamy-native/foamy-lock   # never a target/ inside the plugin
kit/native/build-native.sh . --test  # fmt, clippy, unit tests
kit/native/build-native.sh .         # both arches into bin/, writes native/native.pin
kit/native/build-native.sh . --verify
```

Commit the binaries with `native/native.pin`; `tests/kit-check.sh` refuses
binaries that are stale or don't match the pin.

Shared foamy components (translations, IPC, style tokens) live in `kit/`, copied
from [foamy-kit](https://github.com/foamrider/foamy-kit); `tests/kit-check.sh`
verifies they are unedited.

`LockView.qml` owns the view's data sources (network, battery, the wall clock,
/proc, and the volume, Bluetooth and keyboard sources in `elements/sources`, which
it loads by path only while a status item needs them) and places the elements in
`elements/` (date, clock, account, password field, media, status, calendar,
weather), which only draw what the view gives them. Every reading is a view
property, so a host can supply samples (`liveSources: false` opens no PipeWire,
Bluetooth or Hyprland connection). The tests replace those data sources in
`LockView.qml` alone (`tests/harness/fixtures`).

The render, parity, layout, styles, placement, runtime, studio and thumbnails commands run through `tests/harness.sh`, which builds and
runs `tests/harness`: a development-only Rust crate (std only apart from `serde_json`
for the runtime test's status replies, its own workspace, so the helper's `native.pin`
doesn't cover it; built under `~/.cache/foamy-native`, never inside the plugin;
`cargo test` covers its own PNG, argument, Service.qml patch and JSON helpers).

The parity test renders the current view next to 1.2.0's `LockView.qml` (from git) with the same synthetic
data, and compares the position, size, visibility, text and font size of every
named item, within 1 px, in nine states (sizes from 700 × 1200 to 3440 × 1440,
12-hour time, failure, checking, hidden identity, no media or battery, fingerprint
unavailable, no wallpaper, right-to-left). `--baseline REV` compares with another
revision.

The layout test runs every preset in `Layout.SELECTABLE_PRESETS` (four
quickshells at a time) through five sizes (1920 × 1080, 3440 × 1440, 1280 × 720,
1080 × 1920 and 800 × 1000), 12- and 24-hour time, typing,
secondary screens and right-to-left, where every element and shape must
mirror. No preset may fall back or have any geometry problem; the field and every element must sit wholly
inside or outside each shape (and inside a frame), shapes must be under every
element (frosted ones first) and draw what the fixed decorations of 6efe1fd drew
(within a pixel); a drawn
background must hold its still frame under the software renderer; the system
panel must have its readings (from fixtures, not the real `/proc`). The foamy
run also switches one view through every preset and back, which must restore
its geometry exactly, and forces the fallback chain.

The thumbnails show each preset at 1920 × 1080 with the synthetic data and a
fixed dark theme, scaled to 480 × 270. The offscreen platform has no GPU, so
they show CPU rendering: no blur, and the avatar's initial instead of a
picture.

The placement cases (`placement`, also run by `layout` without `--preset`) put
`scale`, `opacity`, `offset`, `glass` and `screens` on one view: an offset off
the screen, onto another zone's element, into its own stack or onto the field,
the field moved above the top third, a scale that overflows, an offset mirrored
right-to-left, a primary-only element on a secondary view, zone shapes that keep
fitting the un-offset zones and module shapes that follow their modules (offset,
scale, late media and weather, mirrored), an absorbing box compared pixel for
pixel with the module's own surface, weather arriving after the check, the weather's
glass, details and screens, and the status sources (made only while an item needs
them, none with `liveSources: false`, an empty status hidden). Each expects its
geometry code, and a view with `latchFallback: false` (for an editor) must report
it without falling back.

The style sweep (`styles`, also run by `layout` without `--preset`) shows every
style of every element in each column of its row at 1920 × 1080 and 800 × 1000,
in 12- and 24-hour time, typing and idle, on primary and secondary screens. The
field must stay on screen, uncovered, live, focused and one size; every element
and its parts must stay in place, the avatar square, and nothing may fall back.
It also shows every status item at once in each status style and column, and the
weather with its widest sample (every detail, a 64-character condition and an
80-character place). It then switches one view through every style, left-to-right
and mirrored, and back to the default, whose geometry must return exactly, and
types into each field style with `reveal: "typing"` on primary and secondary
screens (hidden while idle with the hint kept, shown when typed into, failed or
checking, never moved). With `FOAMY_RENDER_OUT` it keeps two captures per case.

The render test uses the real view with synthetic account, network, battery, and
media data. It saves wide, narrow, error, and busy-state images in a temporary
folder, including populated artwork and icon fallbacks; set `FOAMY_RENDER_OUT` to
a directory to keep a copy. It is hermetic: a temporary home and config, English
unless `--language CODE` picks another Omarchy language, whatever the desktop uses;
it also checks that the unlock hint is never truncated or clipped. `preview.png` is the first
1920 × 1080 capture with `artworkPath` cleared: the offscreen software renderer
draws no masked artwork, so the screenshot shows the music icon. Artwork tests exercise
the real sandbox with small synthetic images, a local TLS fixture, URL and file
restrictions, byte and decoder limits, caching, cancellation, and stale results.
They require host support for unprivileged namespaces and a private session bus;
a restricted agent/container sandbox may prevent these even when the desktop
supports them. The runtime test runs the real `Service.qml` with an isolated home,
runtime directory and session bus, simulated PAM, session-lock and view objects, and
stand-in desktop commands, and drives it over `quickshell ipc`; it does not lock the
desktop or authenticate a user. It also covers the weather: a stand-in
`foamy.weather` target in IpcRegistry (no target: nothing is called; an older one
without `current()` reaches a recording `omarchy-shell` stand-in), asked on opening
and every poll only for a shown weather and never while blanked, pending retries,
and stale, not-ok and invalid replies hidden.
It runs the real helper against a temporary wallpaper link: relative and retargeted
links, touched and rewritten files, dangling links, directories and a missing helper.
A real password/fingerprint unlock, suspend/resume, and multi-monitor lock cycle
still require supervised validation after installation.

The harness tests run on Omarchy 4.5: `FOAMY_HOST_45` (a
`shell` directory), else `$OMARCHY_TEST_ROOT/shell`, else the installed
`/usr/share/omarchy/shell`. `--host 4.0` and `--host both` run 4.0 only when
`FOAMY_HOST_40` names a 4.0 shell; otherwise they print a SKIP line for it.
The runtime suite supplies both PAM-file fixtures and simulated authentication;
it does not require an enrolled fingerprint or change the host session.

## Verifying the helper binaries

`bin/x86_64/foamy-lock-helper` and `bin/aarch64/foamy-lock-helper` are compiled from the Rust source in this repository: `native/`, the
shared crate in `kit/rust/`, the dependencies locked in `Cargo.lock` and the
toolchain pinned in `rust-toolchain.toml`, with the build tool in
`kit/native/`. The build is reproducible. `native/native.pin` records the
toolchain, a hash of every build input (`source`) and the SHA-256 of each
binary.

**CI.** The [Verify native helpers](https://github.com/foamrider/foamy-lock/actions/workflows/verify-native.yml)
workflow rebuilds both binaries on a GitHub-hosted runner for every push,
compares them byte for byte with `bin/`, and attests the rebuilt files. To
check the committed files against that attestation (GitHub CLI):

```sh
gh attestation verify bin/x86_64/foamy-lock-helper --repo foamrider/foamy-lock \
  --signer-workflow foamrider/foamy-lock/.github/workflows/verify-native.yml \
  --deny-self-hosted-runners
gh attestation verify bin/aarch64/foamy-lock-helper --repo foamrider/foamy-lock \
  --signer-workflow foamrider/foamy-lock/.github/workflows/verify-native.yml \
  --deny-self-hosted-runners
```

Add `--source-digest <commit>` to require a particular commit.

**Yourself.** You need `rustup`, Python 3.11 or newer and `file`. From a
checkout of this repository at the commit you want to check:

```sh
rustup toolchain install "$(awk '$1 == "toolchain" { print $2 }' native/native.pin)" \
  --profile minimal --target x86_64-unknown-linux-musl,aarch64-unknown-linux-musl
kit/native/build-native.sh . --verify
```

It builds both binaries from scratch in `~/.cache/foamy-native/` (nothing is
written to the checkout), compares them byte for byte with `bin/`, checks
that the kit files are unmodified and that `native.pin` matches the source,
and ends with `verify OK (foamy-lock-helper, <toolchain>, both arches reproducible)`.

### Building the helper yourself

To run binaries you built instead of the committed ones, build them in the
installed plugin with the same toolchain, then run `omarchy restart shell`:

```sh
cd ~/.config/omarchy/plugins/foamy.lock
kit/native/build-native.sh .
```

The build is reproducible, so `git status` shows no change when your
binaries match the release, and `omarchy plugin update` still applies.

## Remove

Run this command only while your session is **unlocked**:

```sh
omarchy plugin remove foamy.lock
```

When removing an enabled replacement, Omarchy restores `omarchy.lock`.
If Foamy Lock was already disabled, explicitly
enable the stock lock with `omarchy plugin enable omarchy.lock`. Restart the
shell while unlocked with `omarchy restart shell`, then verify the stock lock
works. Account details, fingerprints, PAM configuration, and the avatar/artwork caches
remain unchanged.

Omarchy manages the plugin entry in `shell.json`. Packages and data outside
the plugin directory are retained unless you remove them separately.

## License

`kit/` holds shared components copied from [foamy-kit](https://github.com/foamrider/foamy-kit); edit them there, not here.

Licensed under [MIT](LICENSE), with the upstream [Omarchy notice](LICENSE-OMARCHY).
Presets inspired by [Lock Designs](https://github.com/KamradSmeshnyavy/omarchy-lock-designs)
by KamradSmeshnyavy (MIT); they are new implementations and share no code.

Language follows **Omarchy → Setup → Language** on Omarchy 4.5, including
right-to-left layout for right-to-left languages (media transport buttons keep their
order). Plugin language overrides are no longer used.
Missing translations fall back to English.

Translation checks: `python3 tests/i18n-runtime.py` checks live language switching on the installed 4.5 shell. Set `OMARCHY_PATH` to another Omarchy tree to check that one.

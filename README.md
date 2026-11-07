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
| `artworkHosts` | `[]` | Opt in to HTTPS artwork from at most 32 exact lowercase DNS hostnames, such as `images.example.com`. No wildcards, URL schemes, IP literals, or ports. Empty disables all remote artwork. |
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

The lock screen is made of seven elements (date, clock, account, password field,
media, status, calendar) on a background. A preset chooses where each element sits and how
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
| `foamy` | The default: the date and a large clock at the top, the account and field below the middle, media bottom left, status top right. |
| `corner` | The date and a bold clock bottom left; the account chip and an underline field bottom right. |
| `editorial` | The date, clock, account and field stacked on the left, in the middle of the screen. |
| `zen` | Only the field, centred, over a blurred and dimmed wallpaper. |
| `dock` | A band along the bottom: a small clock, the field box and the short date. |
| `island` | The time and date in a black pill at the top; the field in the middle. |
| `split` | A solid panel on the left with the date, a bold clock, your name and the field; the wallpaper on the right. |
| `sheet` | A frosted panel on the right with the avatar, clock, date and field. |
| `card` | A glass card in the middle: avatar, small clock, date and field. |
| `cinema` | Black bars: the time and date in the top one, an underline field in the bottom one. |
| `poster` | Huge hours over minutes (the minutes in the accent) on the left; the field bottom left. |
| `analog` | An analogue clock, the date and the field in the middle. |
| `flip` | Flip-card hours and minutes over the date and field. |
| `ring` | The time inside a ring that fills with the minutes of the hour. |
| `calendar` | The date, a bold clock and the field on the left; this month's calendar on the right. |
| `terminal` | A console login on black: mono clock, your name and a `Password:` prompt. |
| `neon` | An outlined clock and accent edges inside a glowing accent frame, over a dark wallpaper. |
| `system` | The clock and field beside a panel with uptime, memory, load and battery. |
| `music` | Now playing with large artwork in the middle, the field below it. |
| `aurora` | Soft bands of the theme's colours drifting behind the clock and field. |
| `rain` | Thin streaks falling behind a card with a mono clock and a terminal field. |
| `constellation` | A star field; each typed character lights the next star of a figure. |
| `dotmatrix` | A dot-matrix clock and dotted field inside a dark bezel. |
| `flat` | The clock, date and field in the middle, on solid surfaces without edges. |
| `frosted` | The same on glass over a strongly blurred wallpaper (blur needs GPU rendering). |
| `fluent` | A bold clock and a greeting card with accent edges. |

Presets from `dock` on are inspired by the layouts of
[Lock Designs](https://github.com/KamradSmeshnyavy/omarchy-lock-designs) (MIT),
rebuilt from the elements, decorations and backgrounds here; no code is shared.
The editor's thumbnails are in `previews/presets` (`tests/harness.sh thumbnails`).

**Layout.** Each element takes `zone`, `style`, `order` and `hidden`:

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
  is on; nothing is read or kept otherwise.

| Element | Styles |
| --- | --- |
| `date` | `long` (default), `caps`, `short` (abbreviated, "Sat 7 Nov"), `serif` (a large serif weekday over the spaced date) |
| `clock` | `thin` (default), `bold`, `stacked` (hours over minutes), `mono` (the Omarchy font), `outline`, `dots` (a dot-matrix face), `flip` (two cards), `analog`, `small` (one line, for a bar or card), `poster` (huge hours over accent minutes), `ring` (the time in a ring that fills over the hour) |
| `account` | `avatar` (default), `chip`, `name` (the name alone) |
| `password` | `pill` (default), `underline`, `box` (an always-visible glass box with the arrow), `dots` (no surface), `terminal` (a "Password:" prompt in the mono font), `card` (a greeting above the field) |
| `media` | `card` (default), `line`, `pill` (thumbnail, title and play/pause), `art` (large artwork with the controls below) |
| `status` | `text` (default), `icons`, `pill` (icons and the battery level in one pill), `system` (a panel with uptime, memory, load and the battery, or the network without one) |
| `calendar` | `card` (default; this month on glass, today ringed in the accent), `plain`. Hidden unless a preset or `hidden: false` shows it. |

Each password style has a fixed size, so the field never moves while you type.
Every style reads the same with CPU rendering, except the artwork: the media
pill and art then show it as a plain square instead of a round or rounded one,
and the card's thumbnail still needs GPU rendering. Only the drawn backgrounds
move (see below).

The password field can't be hidden, and it stays in the middle or bottom row.
`showUserInfo: false` and `showMedia: false` still hide the account and media
whatever the layout says. Artwork is prepared only while a media style
that shows it (`card`, `pill` or `art`) is shown.

**Background.** These keys set what's behind the elements:

- **`source`.** One of:
  - `omarchy` (default): the current wallpaper, as before;
  - `picture`: the file in `path`, an absolute `.png`, `.jpg` or `.webp`;
  - `theme`: the theme's background colour;
  - `black`;
  - `aurora`: soft bands of the theme accent, green and cyan drifting slowly;
  - `rain`: thin accent streaks falling at different speeds;
  - `constellation`: stars and one figure whose stars light up as you type.

  The last three are drawn in the theme's colours over its background. They
  move only while the lock screen is shown, the display is on, Omarchy's
  animations are on and the GPU renders; otherwise (reduced motion, CPU
  rendering, a blanked display) they hold a still frame.
- **`decor`.** A shape over the background and behind the elements, fitted to
  the zones it belongs to (it follows them to narrow screens and mirrors in
  right-to-left languages). It is background: it never covers an element.
  - `none` (default);
  - `split`: a solid panel on the start side, as wide as its column needs
    (at least 38%), with an accent edge; it fills a narrow screen;
  - `sheet`: a frosted panel on the end side;
  - `cinema`: black bars at the top and bottom;
  - `strip`: a band behind the bottom row;
  - `island`: a pill around the top-center zone;
  - `frame`: a border inset from the edges: a glow with the `accent` glass
    tint, otherwise a dark bezel;
  - `card`: a glass card behind the middle-center zone.

  With `cinema` and `strip` the bottom-center stack sits at the bottom edge,
  in the band, instead of at 65% height. The frosting behind `sheet` and
  `card` needs GPU rendering.
- **`blur`.** From 0 to 1.
- **`dim`.** The darkening scrim, from 0 to 0.9; the default is 0.25.
- **Picture preparation.** Your picture is decoded, cropped to the screen and
  blurred by the bundled helper in its sandbox while you are unlocked. The
  original file never reaches the lock screen.
- **Blur of the Omarchy wallpaper** needs GPU rendering. With CPU rendering
  the wallpaper stays sharp, and the dim still applies.
- **Underline field.** It has no surface of its own, so it keeps at least
  0.15 dim behind it.

**Glass.** `opacity` (0 to 1, default 1) scales the transparency of the glass
behind the media card, the account chip, the field and the decorations.
`tint` is `none` (default, white glass), `accent` (the theme accent on the
edges, and the outline clock drawn in it) or `solid` (opaque surfaces without
edges).

**Mistakes and safety.** A mistake in these keys, such as an unknown name or a
value out of range, leaves the previous look in place and shows up as
`lookError` in `omarchy-shell foamy.lock status`. It never resets the other
settings, and a mistake in the other settings never resets the look. Each time
the lock screen is shown, it checks that the field is on the screen and not
covered by another element. If it is, that screen shows the `foamy` preset
instead, and if even that doesn't fit, only the field, centred. `status`
reports this as `layoutError` and `fallbackPreset`.

**Several monitors.** Every monitor shows the same layout. The account and the
field's surround show only on the monitor that receives your keystrokes, or on
every monitor until one does. A password field that accepts typing stays on
every monitor, so a keystroke is never lost.

**Previewing a preset.** `omarchy-shell foamy.lock previewPreset corner` opens
the preview overlay with a preset without saving anything. `omarchy-shell lock
preview` shows your saved look.

Editors use three more calls on the same target: `catalog` lists the elements, zones,
styles, presets (with their thumbnails), background sources, decorations, glass tints and the saved look; `previewLook '<json>'` previews an unsaved look;
`saveLook '<json>'` saves one. Both take the look keys above, validated by the same
rules; `saveLook` replaces only those keys in the `foamy.lock` entry and writes through
Omarchy's own settings path, which keeps a symlinked `shell.json` a symlink.

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
use a cached still frame from Omarchy 4.5's optional `poster.sh` helper. Foamy Lock
does not play video or require the new video QML module. If that helper is missing
or extraction fails, videos use the plain themed background. Wallpaper failures do not block
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

Preview is a visual overlay, **not a secure lock**. Click it or press any key to
dismiss it; a real lock request also closes it. Preview
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
bash tests/harness.sh layout                  # every preset, then the style sweep (also: styles alone)
bash tests/harness.sh runtime                 # service, PAM, fingerprint, wallpaper and IPC flows
bash tests/harness.sh thumbnails              # re-render previews/presets/*.png (480 × 270)
bash tests/kit-check.sh
```

The tests are Rust (`tests/harness`), Python 3 and Node (development only; the plugin does not need
them at runtime). `artwork_test.py` runs the helper as a process: it checks the
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
of `native/src/main.rs`), built with foamy-kit's tool, which needs rustup with the
toolchain in `rust-toolchain.toml`:

```sh
export CARGO_TARGET_DIR=~/.cache/foamy-native/foamy-lock   # never a target/ inside the plugin
~/GitHub/Personal/foamy-kit/tools/build-native.sh . --test  # fmt, clippy, unit tests
~/GitHub/Personal/foamy-kit/tools/build-native.sh .         # both arches into bin/, writes native/native.pin
~/GitHub/Personal/foamy-kit/tools/build-native.sh . --verify
```

Commit the binaries with `native/native.pin`; `tests/kit-check.sh` refuses
binaries that are stale or don't match the pin.

Shared foamy components (translations, IPC, style tokens) live in `kit/`, copied
from [foamy-kit](https://github.com/foamrider/foamy-kit); `tests/kit-check.sh`
verifies they are unedited.

`LockView.qml` owns the view's data sources (network, battery, the wall clock)
and places the elements in `elements/` (date, clock, account, password field,
media, status), which only draw what the view gives them. The render and parity
tests replace those data sources in `LockView.qml` alone.

The render, parity, layout, styles, runtime and thumbnails commands run through `tests/harness.sh`, which builds and
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
quickshells at a time) through four sizes, 12- and 24-hour time, typing,
secondary screens and right-to-left, where every element and decoration must
mirror. No preset may fall back; the field and every element must sit wholly
inside or outside each decoration surface (and inside a frame); a drawn
background must hold its still frame under the software renderer; the system
panel must have its readings (from fixtures, not the real `/proc`). The foamy
run also switches one view through every preset and back, which must restore
its geometry exactly, and forces the fallback chain.

The thumbnails show each preset at 1920 × 1080 with the synthetic data and a
fixed dark theme, scaled to 480 × 270. The offscreen platform has no GPU, so
they show CPU rendering: no blur, and the avatar's initial instead of a
picture.

The style sweep (`styles`, also run by `layout` without `--preset`) shows every
style of every element in each column of its row at 1920 × 1080 and 800 × 1000,
in 12- and 24-hour time, typing and idle, on primary and secondary screens. The
field must stay on screen, uncovered, live, focused and one size; every element
and its parts must stay in place, the avatar square, and nothing may fall back.
It then switches one view through every style, left-to-right and mirrored, and
back to the default, whose geometry must return exactly. With `FOAMY_RENDER_OUT`
it keeps two captures per case.

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
desktop or authenticate a user.
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

# Plan: Lock Studio, round 5 (user review, 2026-11-08)

Status: requirements recorded; design and implementation start after round 4
lands (see [lock-studio-round2.md](lock-studio-round2.md), "Round 4").

## Requests

1. **Header:**
   - Remove the green "The preview is showing. Click or press a key to
     close it" status text.
   - Put the unsaved-changes warning on the **left**, right after the Reset
     button.
2. **The preview overlay's banner** (added in round 3) shows as an empty
   button-like box at the top, with no text. Fix it so it reads "Preview",
   or drop it if a better cue exists. Find out why the text is missing in
   the shell (an i18n key, a font, `PlainText`?).
3. **Decorations:**
   - **More adjustable,** with parameters instead of fixed shapes.
   - **Island alignment:** the island must line up exactly with the media
     player's own background (today some settings put them out of step).
   - **Presets from the tools:** every built-in preset must be possible to
     recreate with the tools Lock Studio offers.
4. **Tips:** keep only the important, non-obvious ones (a handful).
5. **Background page:**
   - **Source:** Wallpaper, Custom image, **Solid colour** (replaces
     Black), **Animation**.
   - **The section below follows the source:**
     - **Image** shows only for Custom image (picture or video, as today).
     - **Colour** shows for Solid colour.
     - **Animation** shows an animation picker.
   - **Animations:**
     - Requested: northern lights (aurora), rain, stars, matrix (digital
       rain).
     - Proposed beside them: snow, fireflies, a slow gradient flow, and
       ocean waves.
     - All must be beautiful, pause like today's (blanked, reduced motion,
       hidden), and run only with the GPU, with a still frame otherwise.
   - **Less help text** in the bottom section.
6. **Presets pass, after 1–5:**
   - **Rename:** "Foamy" becomes **Default** ("Standard" in Norwegian).
     Only the display name changes: the stored id stays `foamy`, so
     existing saved looks keep working.
   - **Every preset reviewed** with creative freedom: modules and design
     that match, alignment and sizes that fit the preset's idea.
   - **New module variants where a preset needs them** (encouraged).
   - **The constraints hold:** geometry checks at the four test sizes,
     parity for Default, and thumbnails regenerated deliberately.

## Order

1. **UI fixes:** items 1, 2 and 4, and the background page structure from
   item 5.
2. **Decorations redesign** (item 3). This one starts with a design note
   and a review.
   - **The model:** decorations as parameterised shapes (kind, what they
     wrap (zones or modules), padding, radius, edge or side, size, opacity
     or tint, blur).
   - **Following modules:** an island or card that wraps modules follows
     their drawn rectangles, so it always lines up.
3. **The new animations.**
4. **The presets pass** (item 6), with before/after thumbnails for the
   user.

## Round 5 progress

### Step 1: UI fixes (items 1, 2, 4 and the background page of item 5)

On `feat/layout-engine`, 2026-11-08; offscreen only (fake omarchy-shell and
session lock; nothing locked, no real omarchy-shell, hyprctl dispatch or
desktop quickshell). The decorations (item 3) are left as they are; their
design note is [lock-decorations.md](lock-decorations.md).
- **The preview banner (item 2).** The cause was its sizing, not i18n, the
  font or PlainText (the text was "Preview" all along). The banner's width
  came from its Column's `implicitWidth`, which a Column takes from its
  children's widths, and the children's widths were bound to the Column's:
  a loop that settles at zero. The title elided to nothing, the hint laid
  out at width 0, the Column skipped both, and the shell drew an empty
  pill. `elements/PreviewBanner.qml` sizes it from the texts' own unwrapped
  widths. The runtime harness checks the real overlay's texts are drawn
  (width, painted size, not truncated); the render harness shows it over
  the last state, refuses an empty or undrawn one, checks "Preview" /
  "Forhåndsvisning" and keeps `capture-banner.png`.
- **Header (item 1).** The status line sits after Reset, start-aligned, and
  shows only warnings and errors: Unsaved changes, or a problem with the
  last Apply, Preview, preset or cover art call. Busy and done say nothing
  (the notice model stays, with empty texts), so "The preview is
  showing…", "Applied…", "Saved to Your presets", "Cover art saved…" and
  the busy lines are gone (en, no). The longer error texts are shorter.
- **Tips (item 4).** Three: Mugshot, Shift/Alt while dragging, Ctrl+arrows
  between zones. A remembered tip that is gone shows the first.
- **Background page (item 5).**
  - **Lock:** a `color` source with `background.color`: a theme colour by
    name (`background`, the default, `accent`, `muted`, `urgent`; it
    follows the theme) or exactly `#rrggbb`. `black` and `theme` are still
    read and become `color` (`#000000`, `background`) in canonical form, so
    an old look equals its new spelling; `terminal` and the fallback preset
    say `color` now. `color` is dropped with any other source. LockView's
    `solidBackground` replaces `blackBackground`. Catalog: additive
    `backgroundAnimations` and `backgroundColors`.
  - **Studio:** Source is Wallpaper, Custom image, Solid colour, Animation
    (`Draft.SOURCE_CHOICES`). The image section shows only for Custom image;
    the colour section has swatches (the four theme colours and black,
    named, arrows and Enter/Space) and a `#rrggbb` field (the kit's
    FoamyTextSettingField: 7 characters at most, bounded paste,
    `Draft.hexColor` checks, the lock checks again); the animation section
    is a StyleTiles picker over `Layout.DRAWN_SOURCES`, each tile drawn by
    the lock's own `Backdrop` in its still frame, so the next step's
    animations get pictures without new art. Removed help: the drawn,
    still-wallpaper, not-shown, blur, decoration, dim and glass notes; the
    wallpaper's missing and video-without-still warnings stay.
  - **Draft.entry:** a preset's own colour going back to the default
    (`terminal`'s black to the theme's background) is written out, since
    canonical form leaves defaults out.
- **artwork_test.py (item 5 of the brief).** The four FakeDecoder launch
  cases expect foamy-kit 0.6.0's program: io_uring, `add_key`,
  `request_key`, `keyctl` and `userfaultfd` denied too, both arches; every
  other number is still checked.
- **Commits:** 19cc97b (artwork_test), a1d860c (banner), be49ed1 (header),
  41c7d4f (tips), 883c955 (solid colour, lock), 1ddd64b (background page).
- **Checks, all green:** node (122); harness parity, runtime (the banner
  drawn), layout, render en and no (the banner's capture), styles,
  placement, video, studio en/no/ar (new captures `studio-animation`,
  `studio-color`); thumbnails byte-identical; `tests/artwork_test.py` (33);
  kit-check; `check.sh --lint-only`; qmllint (the same warning kinds as at
  2a71227; +2 `missing-property` are the banner's `FoamyStyle.font.*`, moved
  from Service.qml); `omarchy-plugin-validate`.
- **Deviations:**
  - A video Omarchy wallpaper still gets its video card (Convert, Motion)
    under Wallpaper: the image section is Custom image only, but the card is
    how a video wallpaper plays.
  - `color` is dropped from a look whose source isn't a solid colour (unlike
    `path`), so switching away and back starts from the theme's background.
  - Swatches are background, accent, muted, urgent and black; the
    foreground is left out (white type on it would be unreadable).
  - The swatches have accessible names but no hover tooltip (the kit has no
    plain tooltip for a non-button item).
  - Between 883c955 and 1ddd64b the i18n test lacks `studio.source.color`
    (the lock lists the source before the studio names it).
- **Live app:** no new studio files, so the open app hot-reloads. The banner
  needs a shell running this branch (`elements/PreviewBanner.qml`).

### Animations (item 5)

On `feat/animations` (from `feat/layout-engine` 6efe1fd), 2026-11-08;
offscreen only. Decorations untouched (they are redesigned on
`feat/layout-engine` meanwhile); Layout.js changes are the background
sources, the `constellation` alias and an export block at the end.
- **Eight animations,** in the picker's order (`Layout.DRAWN_SOURCES`):
  Northern lights (`aurora`, redone: two folded curtains of green rising
  into the accent and cyan, with rays, over a darkened sky, faint stars and a
  low ridge), Rain (redone: slanted streaks at three depths, mist low down),
  Stars (`stars`, was `constellation`: three depths of twinkling stars, a few
  warm or cool, spikes on the brightest, a faint Milky Way, three shooting
  stars per loop; the typed-character figure is kept), Matrix (5 × 7 dot
  glyphs, mostly mirror-symmetric, in the accent, a near and a far layer),
  Snow (four depths, swaying), Fireflies (yellow and green glows wandering and
  pulsing over a dark meadow), Gradient flow (four soft pools drifting through
  a warped space, rolled off toward the background's lightness so text stays
  legible on any theme) and Ocean waves (eight bands of swell with foam under
  a moon, its path glinting). Colours are the theme's only: background,
  accent, green, cyan, yellow (FoamyPalette) and the lock's foreground; on a
  light theme light paints over instead of adding, and stars and foam take
  the theme's text colour.
- **How they draw** (`elements/Backdrop.qml`): with the GPU a fragment shader
  per animation (`elements/shaders/*.frag`, a shared `common.glsl` uniform
  block and `hash.glsl`, compiled by `elements/shaders/build.sh` with
  `qsb --glsl '330,300 es'` plus SPIR-V, as Foamy Weather ships its sky;
  original code). A FrameAnimation steps the time each frame while
  `moving` (the old Timer's rule: shown, display awake, animations on, GPU),
  so it is 60 fps (or the display's rate); every motion is periodic in a
  120 s loop, so there is no seam. Paused (blanked, reduced motion) the
  shader keeps its last frame and nothing re-renders; hidden, neither the
  shader nor the still is loaded. A shader that fails to build falls back to
  the still frame.
- **The still frame** (`elements/BackdropStill.js`): the software renderer
  (CPU rendering, the tests, thumbnails, Lock Studio's tiles there) paints the
  same picture once on two Canvases: the smooth field a column at a time as
  vertical gradients (QML's ImageData was unusably slow), scaled up, and the
  points (stars, drops, flakes, glyphs, glows) at full size, at most 1920
  wide. The integer hash is the shaders' bit for bit (checked against
  lowbias32 in `tests/backdrop.test.cjs`), so stars and flakes land where the
  shader puts them. Painted once per scene by value (a binding that recomputes
  the same scene, or Qt asking again, paints nothing). Deterministic: the
  render harness draws each twice and compares bytes.
- **Older looks:** `constellation` stays a valid source; canonical form,
  `Layout.drawnSource`, LockView and `Draft.sourceChoice` read it as `stars`
  (the picker shows Stars chosen). The `constellation` preset keeps its id and
  now draws `stars`.
- **Names:** en Northern lights, Rain, Stars, Matrix, Snow, Fireflies,
  Gradient flow, Ocean waves; no Nordlys, Regn, Stjerner, Matrix, Snø,
  Ildfluer, Fargeflyt, Havbølger. The presets keep their names.
- **Cost, measured** with a scratch QQuickRenderControl tool (not in the
  repo): the Backdrop alone rendered through OpenGL into a texture with
  Qt's offscreen platform, no window. Per frame, render plus `glFinish`, on
  the dev machine's RX 9070 XT at 1920 × 1080 / 3840 × 2160, and on Mesa
  llvmpipe (software GL, a stand-in for a weak GPU) at 1920 × 1080: aurora
  0.59 / 1.77 / 12.6 ms, rain 0.24 / 0.75 / 4.0, stars 0.49 / 1.52 / 8.0,
  matrix 0.19 / 0.59 / 3.3, snow 0.42 / 1.32 / 7.1, fireflies 0.93 (after
  cutting its search to four cells; was 1.43) / 2.39 / 16.0, gradient
  0.19 / 0.64 / 4.3, ocean 0.13 / 0.35 / 3.1. Limits: a fast desktop GPU and
  a CPU rasteriser, no laptop iGPU, no compositor in the loop. The still
  frame, painted once on the CPU at 1920 × 1080: aurora 177 ms, ocean
  183, matrix 114, stars 112, gradient 49, snow 39, fireflies 24, rain 11.
- **Thumbnails:** regenerated deliberately for the three presets that use an
  animation (`aurora`, `rain`, `constellation`); the other 23 are
  byte-identical.
- **Tests:** `tests/backdrop.test.cjs` (shaders present and compiled, the
  uniforms Backdrop sets are the block's, the hash, the alias); the render
  harness saves `capture-animation-<name>.png` for each (1920 × 1080, the
  backdrop alone, painted without a shader, the same twice); the studio case
  checks every tile is painted without a shader and that `constellation`
  shows Stars chosen.

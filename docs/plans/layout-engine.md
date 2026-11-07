# Plan: lock-screen layout engine (foamy-lock 1.3.0)

Status: in progress (steps 0–3, 5, 6 done; see Progress) · reviewed, revision 2 · 2026-11-07 · branch `feat/layout-engine` off `dev`

## Goal

Make the lock screen a composition of six elements (clock, date, account,
password field, media, status) plus a background. Each element has a style
and a position, chosen by a preset and optionally overridden per element.
This is the engine only. The editor popup comes later as a separate plugin
that talks to foamy.lock over IPC and writes `shell.json` through
FoamyPrefsQueue; nothing here depends on it.

**In 1.3.0:** the view split into elements, the zone model, two styles per
element, four presets, per-element zone/order/hidden overrides, background
sources (Omarchy wallpaper, own picture, theme colour, black) with blur and
dim, glass opacity, one-layout-on-every-screen with the field on the active
screen, safety checks, and a preset preview over IPC.

**Deferred to 1.4+:** the editor popup and on-screen editor, element `size`,
more styles per element, blur behind glass, animated backgrounds (aurora,
rain), per-monitor layouts, and the remaining Lock Designs-inspired presets.

## Requirements

1. **No regression.** With no new settings, the lock looks and behaves as in
   1.2.0 (commit 8ad7ccc). The `foamy` preset reproduces today's layout, and
   a parity test compares item geometry with 1.2.0 (see Tests).
2. **Authentication is untouched.** Service.qml's PAM, fingerprint, blanking,
   session-lock and IPC code doesn't change, except to pass layout data to
   the view, track which surface is active, and report layout state in
   `status`.
3. **Layouts are data, never code.** No user QML, no `Loader` from a user
   path, no asynchronous loading on the lock surface. Users can only pick
   styles the plugin ships.
4. **Keystrokes always reach a password input.** Every lock surface keeps a
   live, focused `TextInput`. Layout choices change where the field is drawn
   and what surrounds it, never whether input is accepted.
5. **The password field can't be lost.** Every layout passes a model check
   when parsed and a geometry check when shown. Failures fall back in two
   stages (to the `foamy` preset, then to a field-only layout) and set
   `layoutError`.
6. **One layout on every screen.** The account and visible field show on the
   active screen (the one receiving keystrokes); everything else shows on
   every screen.
7. **Privacy settings always apply.** `showUserInfo`, `showMedia`,
   `showBrowserMedia` and `showArtwork` keep their meaning, and a layout
   error never resets them.
8. **Suite rules (foamy-kit DESIGN.md):**
   - no hex outside the art surface (with a reasoned opt-out);
   - effects gated off under the software renderer;
   - RTL via anchors;
   - i18n (en + no) for every new string;
   - the lock stays free of animation in 1.3.0, so FoamyMotion isn't needed.

## Layout model

**Zones.** There are nine:

| | start | center | end |
|---|---|---|---|
| **top** | `top-start` | `top-center` | `top-end` |
| **middle** | `middle-start` | `middle-center` | `middle-end` |
| **bottom** | `bottom-start` | `bottom-center` | `bottom-end` |

Start/end mean left/right in left-to-right languages, and mirror in
right-to-left ones. Zones and every element are positioned with anchors only
(no `x` arithmetic, no `Column` for horizontal placement), so the existing
`LayoutMirroring.childrenInherit` on the lock surface mirrors them.
Elements in a zone stack by `order` (ties broken by a fixed element order).

**Elements.** Each element is `{ "zone", "style", "order", "hidden" }`.
`hidden` is rejected for the password element.

| Element | Styles (1.3.0) | Hideable | Notes |
|---|---|---|---|
| clock | `thin` (today), `bold` | yes | 12h and 24h rendered in both |
| date | `long` (today), `caps` | yes | `caps` uses `toLocaleUpperCase` |
| account | `avatar` (today), `chip` | yes | `showUserInfo: false` forces hidden |
| password | `pill` (today), `underline` | **no** | fixed size; zones: middle and bottom rows only |
| media | `card` (today), `line` | yes | `showMedia: false` forces hidden |
| status | `text` (today), `icons` | yes | network, battery |

The password element owns everything about authentication: the field, the
unlock hint, the failure, busy and "Unlocking…" states, and the "Fingerprint
reader unavailable" notice (moved in from its current anchor on
`loginColumn`). Every style reserves fixed space for the hint, the failure
line and the notice, so the element's size doesn't change while you type or
when a state changes.

**Background.** `{ "source": "omarchy" | "picture" | "theme" | "black", "path", "blur": 0–1, "dim": 0–0.9 }`.
The default `dim` 0.25 reproduces today's scrim. `omarchy` follows Omarchy's
wallpaper, including video posters, as today. See Background preparation.

**Glass.** `{ "opacity": 0–1 }` scales the alpha of the existing `glass`
colour; a theme's `[lock] background` still sets the colour.

**Presets** (1.3.0), each a full layout object in `Layout.js`:
- `foamy`: the default, today's layout.
- `corner`: the clock bottom-start, the field bottom-end.
- `editorial`: date and clock middle-start, the field below them.
- `zen`: only the field, centred, with heavy blur.
- `field-only`: the last-resort fallback. Not selectable, never fails
  geometry: the field centred on a themed background.

## Config

New optional keys on the existing `foamy.lock` entry in `shell.json`:

```json
{ "id": "foamy.lock",
  "preset": "foamy",
  "layout": { "media": { "zone": "bottom-end" }, "status": { "hidden": true } },
  "background": { "source": "picture", "path": "/home/me/Pictures/lake.jpg", "blur": 0.4, "dim": 0.2 },
  "glass": { "opacity": 0.12 } }
```

- **Merging.** The effective layout is the preset deep-merged with `layout`.
  Only differences are stored, so updates to a preset still reach users.
- **Two validation groups.** Model.parseConfig validates the existing keys
  exactly as today (all-or-nothing, last valid kept). It validates
  `preset`/`layout`/`background`/`glass` separately:
  - If that group is invalid, it uses the last valid layout (the `foamy`
    preset on startup) and adds to `configError`.
  - A layout error never touches the privacy or behaviour keys.
- **Strict names.** Unknown preset, zone, style, element or element key
  names are invalid, so typos show up as `configError` instead of silently
  doing nothing.
- **Privacy precedence.** An element is visible only if both the existing
  switch and the layout allow it. Media hidden by the layout also stops
  artwork preparation (`Artwork.allowed`).
- **Downgrades.** 1.2.0 ignores the new keys.

## Multiple monitors

Each screen already gets its own `LockView` inside a `WlSessionLockSurface`.
Each view keeps its own focused `TextInput`, as today, and all of them share
`Service.enteredPassword`.

**Where the keys go.** Track the active surface with the surface window's
`Window.active`, which is where keystrokes actually arrive. Service keeps
the set of active surfaces.

**What "primary" means.**
- A view is primary if its surface is active, or if no surface is active.
- Primary views show the account and the visible field chrome.
- Non-primary views hide that chrome, but keep their `TextInput` enabled
  and focused at opacity 0. Typing on one makes it active, and so primary,
  within a frame. Its text is already shared.
- A non-primary view also shows its field whenever `enteredPassword` isn't
  empty, so a password being typed is never invisible.

**No Hyprland import.** `Quickshell.Hyprland` isn't used, so there's no
compositor-specific failure path.

**Guarding the screen.** `WlSessionLockSurface.screen` can be null at first;
a view without a known screen is treated as primary until it has one.

**Preview.** The preview overlay is a single layer-shell window and is
always primary.

**Step 0 result (2026-11-07).** Tested with Quickshell 0.3.2 and Hyprland
0.56.2: DP-2 plus a temporary headless output, three lock/unlock cycles. The
instrumentation diff isn't kept in the repo.
- **`Window.active` works.** About 40 ms after `secure=true`, it is true on
  the DP-2 surface and stays false on the other.
- **Hyprland's focus is the wrong source.** Moving Hyprland's focused
  monitor to the headless output and back while locked
  (`hl.dsp.focus({ monitor = … })`) did **not** move keyboard focus: DP-2
  stayed active and the other surface never became active. Hyprland's
  focused monitor and the surface receiving keystrokes can differ, which
  confirms that `Window.active` is the right source.
- **`screen` starts null.** It is null when a surface is created and set
  within about 2 ms, so the null guard is needed.
- **Each surface keeps its own focused input.** Every surface's active
  focus item is its own `passwordInput`, as assumed.
- **Not tested:** moving the pointer to another monitor while locked (the
  Lua cursor dispatcher wasn't found) and real second-monitor hardware. The
  live inputs on every surface keep both safe.

**Non-primary screens show no hint** (decided 2026-11-07).

## Background preparation

Today the Omarchy wallpaper is decoded by Qt inside the lock process, as the
stock lock does; that stays the default path. A user-picked picture and any
blur go through the helper:

- **New helper kind `background`.** The helper decodes the source in the
  existing Bubblewrap + ImageMagick sandbox, which already serves artwork
  and the avatar. It returns a PNG at the largest screen's size, optionally
  blurred and without metadata, cached by source signature, size and blur.
- **Input checks.** The helper checks magic bytes and rejects animated
  images, with byte and pixel limits like the artwork path.
- **When it runs.** It prepares while unlocked, when settings, the
  wallpaper or the screens change, and the lock shows the prepared file.
  Like artwork, it never decodes after the lock starts.
- **Blur everywhere.** Blur therefore works under the software renderer too.
  There's no MultiEffect on the background, and no per-frame cost on a
  3440×1440 screen.
- **`omarchy` source with blur > 0.** The wallpaper goes through the helper.
  If the helper is unavailable, the lock shows the unblurred wallpaper the
  same way it does today.
- **`picture` source.** If the helper is unavailable, or the file is
  missing, rejected or fails to decode, the lock shows the themed background
  and reports `wallpaperError: "picture-unavailable"` (or the helper's code).
  The raw file is never loaded into Qt.
- **Decode errors.** An `Image.status === Image.Error` on the prepared file
  also falls back and sets an error code.
- **Separate wiring.** A separate `Process` and preload entry handle the
  prepared background. The existing wallpaper probe and its poster handling
  stay as they are.

## Code structure

```
LockView.qml           data sources (clock, Networking, UPower, MPRIS state), background,
                       zones, primary, geometry check, fallback stage
elements/Clock.qml  Date.qml  Account.qml  Password.qml  Media.qml  Status.qml
Layout.js              parse/validate/merge, presets lookup, zone rules, primary rule (pure JS)
```

- Elements are presentational: they get the time, network, battery and
  player state as properties from LockView. Only LockView still touches
  `Networking`, `UPower` and the clock, so the render harness keeps patching
  one file.
- `Password.qml` takes today's `TextInput` and its behaviour verbatim:
  - auto-repeat drop, focus forcing, text sync;
  - the submit arrow, hint, failure and busy states, and the fingerprint
    notice.
  It's created directly, never re-parented. Zone placement only changes its
  anchors, and every relayout calls `forcePasswordFocus()`.
- Styles switch with `visible` on sibling items inside each element.
- `objectName`s used by the tests (`inputField`, `passwordInput`, `mediaRow`,
  `statusFooter`, `unlockHint`, `fingerprintNotice`, the RTL checks) are
  kept.

## Safety checks

1. **Model check (Layout.js).**
   - The password element is present, not hidden, uses a valid style, and
     sits in an allowed zone.
   - All names are known and there are no duplicates.
2. **Geometry check (LockView).**
   - **When it runs:** a binding over the password element's rectangle,
     with a 300 ms debounce after changes.
   - **What it checks:** the rectangle stays inside the screen with a
     margin, keeps its fixed size, doesn't intersect another visible
     element's reserved rectangle, and its zone stack fits the zone.
   - **On failure:** the first failure switches that view to `foamy`; a
     failure of `foamy` switches it to `field-only`. Each stage latches until
     the next lock or settings change, so it never flips back and forth.
   - **Reported codes:** `password-offscreen`, `password-overlap`,
     `zone-overflow`.
   - Because sizes are reserved, media appearing, the avatar loading or a
     failure message doesn't move the field.
3. **Legibility floor.** Styles without their own surface (`underline`) keep
   the text shadow, and a minimum `dim` of 0.15 applies behind them. Contrast
   against a photo can't be measured, and the plan doesn't claim to.

## IPC

- `status` gains `preset`, `layout` (effective), `layoutError` and
  `activeSurface`.
- `omarchy-shell foamy.lock previewPreset <name>` opens the existing preview
  overlay with that preset. The name is checked against `Presets`. It
  applies only to the preview's view, never the lock's, and saves nothing.
  `lock preview` is unchanged. Nothing new can unlock anything.

## Progress (2026-11-07)

Done on `feat/layout-engine`, all offline. Nothing has run on the real lock
screen yet; that waits for the user's go.

- **0:** spike (`Window.active`).
- **1:** extraction.
- **1b:** runtime test in Rust.
- **2:** Layout.js, the zones and the safety net.
- **3:** second styles and presets.
- **5:** primary surface.
- **6:** status fields and `previewPreset`.
- **4:** the QML half is done: sources, dim, glass, GPU blur. The helper's
  `background` kind, which decodes and blurs your picture in the sandbox, is
  in progress.

What changed from the plan while building:
- **One JavaScript file.** Presets live in Layout.js. A second `.js`
  imported from it would need `.import`, which node can't load.
- **No zone containers.** Elements are positioned by bindings
  (`placeX`/`placeY`), never re-parented. The zone rules reproduce 1.2.0's
  positions exactly, and the parity test proves it.
- **Narrow screens** (1.2.0's `compactLayout`) centre the bottom corners and
  stack them: the start zone at the bottom, the end zone above it. The
  bottom-center zone reserves room for both, at least 1.2.0's 140 px.
- **A hidden element keeps its place,** as 1.2.0's anchors did.
- **Blur of the Omarchy wallpaper** uses MultiEffect with GPU rendering and
  stays sharp under the software renderer. The helper prepares only the
  `picture` source (decode, crop and blur in the sandbox). Pictures are
  never decoded by Qt.
- **Fallback order.** The user's look falls back to plain foamy (or straight
  to field-only when it already is plain foamy), then to field-only. Each
  stage is latched for the view's lifetime; the service resets its report
  on the next lock or look change.
- **The geometry check** waits until the view has a size. A 0×0 view at
  creation would otherwise always "fail".

## Steps

0. **Spike (no merge).**
   - Done: `Window.active` per session-lock surface (see Multiple monitors).
   - Still open, and needs no lock: check that a prepared 3440×1440 PNG
     loads in one frame.
1. **Extract without changing behaviour.** Done 2026-11-07. LockView is
   split into `elements/`, still placed at today's positions; the zones come
   in step 2.
   - The render test moved from Python into `tests/harness` (Rust, std
     only), which copies the whole tree and patches only LockView.
   - The parity test against 8ad7ccc is in the same harness.
   - LockView's interface is unchanged, so runtime.py's mock needed no
     update. All existing tests stay green.
1b. **Port runtime.py to the Rust harness** before step 2 extends it. New
   test code is Rust, not Python. The artwork tests and i18n-runtime.py stay
   Python: the layout work doesn't touch them, and the artwork tests need a
   TLS server.
2. **Layout.js and the safety net.**
   - Zone/order/hidden overrides, the `foamy` and `field-only` presets.
   - The model check, the geometry check and the fallback stages.
   - The separate validation group in Model.parseConfig, plus node tests.
3. **Styles and presets.** The second style for each element; the `corner`,
   `editorial` and `zen` presets.
4. **Background preparation.** The helper `background` kind with tests, the
   sources, dim and glass opacity.
5. **Multiple monitors.** Primary from `Window.active`, with the guards above.
6. **IPC.** The status fields and `previewPreset`.
7. **Docs and release.**
   - README settings and a preset gallery from render captures.
   - i18n (en, no) and CHANGELOG.
   - Version 1.3.0, kit check.

Each step is one or more commits on `feat/layout-engine`; the branch merges
into `dev` through a PR.

## Tests

- **`tests/layout.test.cjs` (new).**
  - Parse, merge and validate; every preset is valid.
  - The password can't be hidden or put in a disallowed zone.
  - A layout error keeps the privacy keys.
  - The primary rule: one active surface, none, two, an unknown screen,
    and the preview.
- **Render (`tests/harness.sh render`).**
  - Every preset in 12h and 24h, and 1920×1080, 3440×1440, 1280×720 and
    800×1000, each primary and non-primary. That's split across several
    quickshell runs, or the 15 s timeout is raised.
  - Asserts the field is visible, inside, unclipped and not overlapped on
    primary views, and present but invisible on non-primary ones.
  - A broken layout falls back with `layoutError`; `foamy` failing at a tiny
    size falls back to `field-only`.
- **Parity (`tests/harness.sh parity`).** The harness renders 1.2.0's LockView (`git show
  8ad7ccc:LockView.qml`) and the new `foamy` view in the same run and
  compares the rectangles of the named items within ±1 px. That replaces a
  pixel diff, which would depend on installed fonts.
- **Runtime** (`tests/runtime.py`, in the Rust harness after step 1b).
  - Live reload of `preset`/`layout`; an invalid layout keeps the previous
    one and the privacy keys.
  - Background preparation: missing, replaced, rejected and unchanged
    files, and an unavailable helper.
  - The status fields and `previewPreset`.
- **Helper (Rust).** The `background` kind with the same sandbox and limit
  tests as `avatar`.
- **Lint.** Existing suites green; `check.sh` clean.
- **Not covered automatically.** The render tests draw views, not real
  surfaces. They can't exercise compositor keyboard focus, the mapping from
  surface to screen, or blur effects (the software renderer is used).
- **Manual, after install on this desktop (one 3440×1440 monitor).**
  - Lock and unlock with password and fingerprint, using each preset.
  - Suspend and resume.
  - A video wallpaper, and an own picture.
  - Multiple monitors need an outside tester; the "no surface active → all
    primary" rule and the always-live inputs keep that gap safe.

## Risks

- **`Window.active` on lock surfaces.** Confirmed in step 0. A pointer move
  between monitors is still untested; the fallback is "all primary".
- **Parity during extraction.** Comparing geometry, not pixels, keeps this
  checkable; small anchor changes are caught at ±1 px.
- **Helper scope.** The `background` kind builds on the existing sandbox
  code. If it slips, ship 1.3.0 with only the `omarchy`, `theme` and `black`
  sources, unblurred, and defer `picture` and `blur`.
- **Config grows.** The separate validation group and `configError` keep
  mistakes visible without weakening privacy.
- **Lock Designs.** Presets are new implementations inspired by its layouts.
  Any code taken from it keeps its MIT notice.

## Review log

Revision 1 was reviewed against the code. The changes in revision 2:

- **Field on secondary screens.**
  - **Was:** hidden on secondary screens, with `primary` from
    `Hyprland.focusedMonitor`.
  - **Problem:** keystrokes could be lost on a secondary screen, and a
    failed import would break the lock.
  - **Now:** every surface keeps a live input, and `primary` comes from
    `Window.active`, with no Hyprland import.
- **Config validation.**
  - **Was:** one all-or-nothing validation.
  - **Problem:** a layout typo could reset `showMedia`/`showUserInfo` to
    their defaults on startup.
  - **Now:** the layout keys are validated as a separate group.
- **Geometry check.**
  - **Was:** a single check "after layout settles", with one fallback.
  - **Problem:** sizes have no settled moment, and the fallback could fail
    too.
  - **Now:** reserved sizes, a fixed-size field in allowed zones, a
    debounce, latched stages, and a `field-only` last resort.
- **Render harness.**
  - **Was:** split files patched in place.
  - **Problem:** render.py only patches and copies LockView.qml and
    Model.js.
  - **Now:** the data sources stay in LockView, the harness copies the
    tree, and parity compares geometry with 8ad7ccc.
- **User picture.**
  - **Was:** decoded by Qt inside the lock process.
  - **Now:** the sandboxed helper kind `background`, which also does blur
    without MultiEffect.
- **Small fixes.**
  - Added `hidden` to the schema.
  - `preview [preset]` became `previewPreset <name>`, because IPC functions
    have a fixed number of arguments.
  - Multi-monitor test coverage is now stated honestly.
- **Scope.**
  - Cut to two styles per element.
  - Element `size` and blur behind glass are deferred.
  - The safety net moved to step 2.
- **Nitpicks.**
  - Zones named start/end, positioned with anchors.
  - Locale-aware upper-casing for `caps`.
  - 12h render cases.
  - Kept the `objectName`s the tests use.
  - Guard a null `screen`.
  - No animation, so FoamyMotion isn't needed.

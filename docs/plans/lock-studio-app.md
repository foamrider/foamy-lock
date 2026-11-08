# Plan: Lock Studio, a desktop app for the Foamy lock screen

Status: revision 3 (2026-11-08): Rust split decided; revision 2 was reviewed. Steps 1–6 done (see Progress). Builds on
[layout-engine.md](layout-engine.md) (zones, presets, safety checks, IPC).

## Goal

A separate desktop app with its own window, in the app launcher, for
designing the lock screen: pick a preset, drag modules around a live canvas,
and adjust each one (style, size, opacity, glass, position). It replaces the
bar popup (`foamy-lock-studio`, never released).

**Chosen design** (2026-11-08): mockup **A, Canvas**, with **C's free drag**:
- **Left:** module library and scene (background, glass and dim).
- **Middle:** a live canvas with zone overlay, preview states and presets
  strip.
- **Right:** an inspector.

Modules are dragged on the canvas and **snap** (grid lock). Holding Shift
turns snapping off while it is held (see Interaction).

## Decisions

Settled:
1. **Design:** A plus C's free drag, snapping by default, holding Shift turns
   it off, Alt locks the axis (user, 2026-11-08).
2. **One look format, extended.** Free placement is a zone anchor plus an
   offset, not a second layout system. The lock's safety checks and
   fallback cover the new keys.
3. **The new keys ship in foamy-lock 1.3.0**, which isn't released, so
   users see one format change rather than two.
4. **Saving goes through the lock.** The app never writes `shell.json`; it
   calls `omarchy-shell foamy.lock saveLook`, which validates and writes
   through Omarchy (keeping the dotfiles symlink).

5. **Runtime: QML on Quickshell for the window, Rust for everything else**
   (user, 2026-11-08). The window and canvas are a Quickshell config run as
   its own process. All logic with I/O (launching, raising, the launcher
   entry, drafts and undo history on disk, Apply with its reply handling,
   the portal file picker) lives in Rust, as `studio` subcommands of the
   lock's existing multi-call `foamy-lock-helper` (foamy-kit: one helper
   binary per plugin). JavaScript is left only for what must run on every
   pointer move inside the window (snapping maths), like `Layout.js`. Why
   not all Rust: Quickshell's modules are compiled into the `quickshell`
   binary (`/usr/lib/qt6/qml/Quickshell/*` holds only tooling stubs), so
   only Quickshell can run the lock's QML. Omarchy's own apps are
   C++/Qt, but here the canvas must *be* the lock screen. Quickshell loads
   the lock's real `LockView`, elements, kit, i18n and Omarchy `Commons`
   with no stand-ins (see Spike); a C++ app would need fake `qs.Commons`,
   `Quickshell.Io`, `Networking` and `UPower` modules that drift. The existing Rust harness tests it.
6. **Source in the foamy-lock repo, under `studio/`.** App and lock then
   always match (same `Layout.js`, elements and version). At launch the
   app runs from a root the launcher builds outside the plugin folder (see
   Launching). The `foamy-lock-studio` repo is retired; the parts worth
   keeping are ported.
7. **Names:** app id and `.desktop` name `foamy-lock-studio`; launcher
   command `foamy-lock-helper studio`; window title "Lock Studio".

## Spike (2026-11-08)

- **Setup:** a scratch Quickshell config with
  `//@ pragma AppId lockstudio-spike` and a `FloatingWindow`.
  - Links to the worktree's `elements/`, `kit/` and `i18n/`, and to
    `/usr/share/omarchy/shell/Commons` (as the harness does).
  - Copies of `LockView.qml`, `Layout.js` and `Model.js`.
- **It works as an app.** It opened as a normal tiled window with class
  `lockstudio-spike`, as its own process beside the running shell.
- **It renders the real lock.** `LockView` at 3440×1440 drew the real
  clock, date, status (live network), account, hint and media card, in
  Norwegian from the Omarchy language. It was scaled with `scale` into a
  1060 px stage.
- **Overlays work.** A `DragHandler` item on top of the stage worked as an
  editor overlay.
- **Warnings:** only from the spike's incomplete fake player.
- **Not tested:**
  - The portal file picker from Quickshell.
  - Linking single files rather than copying them.
  - Drag from the library into the canvas.

## Look format additions (foamy-lock 1.3.0)

Each element today is `{ zone, style, order, hidden }`. New optional keys,
with defaults that reproduce today's rendering exactly (parity test):

| Key | Type, range | Default | Meaning |
|---|---|---|---|
| `scale` | number 0.5–2.0, multiple of 0.05 (checked as `Math.round(v*20) === v*20` within 1e-9) | 1 | Element size. Password: 0.85–1.5. |
| `opacity` | number 0.3–1.0 | 1 | Element opacity. Password: 0.7–1.0. |
| `offset` | `{ x, y }`, **both required**, each −0.5…0.5 | absent = `{0,0}` | Move from the zone position, as a fraction of screen width (x) and height (y). x mirrors in right-to-left layouts, like start/end. |
| `glass` | number 0–1 | **absent** (the look's `glass.opacity` applies) | Per-element glass surface. Elements with one: media, calendar, analog/ring faces, status pill styles, account chip, password pill/box/card. Password floor 0.08. |
| `screens` | `"all"` \| `"primary"` | `"all"` | Clock, date, media, status, calendar only. "Primary" means the view that has the keys (or every view until one has). Account and password keep the existing rule and reject the key. |

- **Deferred:** `options` (clock seconds, calendar week numbers, media
  progress). Each one is a feature, not an extra key: seconds need a 1 s
  clock gated on `displayAwake`; progress needs MPRIS position polling.
  They come after 1.3.0, each with its own step.
- **Merging** stays shallow per element. `offset` is accepted only whole
  (both `x` and `y`), so a partial offset can't produce NaN. `glass` stays
  absent unless set. `plainFoamy` compares a canonical shape: absent keys
  and their defaults count as equal.
- **Offsets as fractions** keep one look valid across screen sizes (one
  layout on every screen).
- **Offsets don't move the zone stack.** Other elements stay where the
  stack puts them.
- **Decorations follow the reserved, un-offset rectangles.** An offset
  element is drawn where it was moved, but the cinema, strip, sheet, split
  and island surfaces keep fitting the zones. The layout test's "wholly
  inside or outside each surface" rule applies to un-offset elements only.
- **Password rules hold under offsets.** The field's drawn rectangle must
  have its top below one third of the screen height (`password-high`), as
  well as staying on screen and clear of everything else.
- **Downgrade:** 1.2.0 ignores the whole look group, so there is no old
  reader to break.

## Lock changes (foamy-lock)

1. **A `uiScale` seam** (before anything reads `scale`).
   - **Today:** elements read `view.uiScale` directly (108 places, mostly
     Password, Media, Status and Account). The field, dot and content sizes
     are root-level values (`LockView.qml` 65–72).
   - **Change:** give every element its own `uiScale` property, set by
     LockView, and move the field, dot and content sizes into the elements
     as functions of it.
   - **Centre column:** its width (`textWidth`, `contentWidth`) is
     multiplied by the element's scale, clamped to the screen width minus
     margins, so a scaled clock or date actually grows instead of shrinking
     to fit.
   - **Proof:** parity, layout, styles and runtime all unchanged at scale 1.
2. **Layout.js:** keys, ranges, password limits, canonical shape, and the
   new codes in `geometryError`. Node tests for every key, edge and message.
3. **LockView rendering.**
   - **Placement:** `placeX`/`placeY` add the mirrored offset.
   - **Element inputs:** each element gets its own `uiScale`, plus
     `opacity` and `glassOpacity`.
   - **Screens:** `screens: "primary"` hides an element on non-primary
     views.
4. **Geometry check.**
   - **What it compares:** each element's `drawnRect()` (what is painted),
     not `rectOf()`.
   - **What may overlap:** neighbours in the same zone stack, by design
     (clocks pull up into the date with negative gaps). Overlap is checked
     between elements in different zones, and between an offset element and
     everything else.
   - **New codes:** `element-offscreen`, `element-overlap`,
     `password-high`.
   - **Zone overflow:** the earlier plan's claim that it is checked was
     wrong. It isn't, and it stays out of scope.
   - **When it runs:** `geometryKey` is rebuilt from every element's
     rectangle, so a change to an offset or scale alone triggers the check.
5. **A fallback switch, nothing else, for the app.**
   - **The change:** `checkGeometry` splits into a pure `geometryProblem()`
     (returns a code, or "") and the latch, which stays as it is.
   - **One new property:** `latchFallback` (default true). The app sets it
     false to report problems instead of switching presets.
   - **Already in place:** everything else the app needs is a public input
     today. `inputEnabled: false` disables the field, as the preview window
     does. `passwordText`, `failureMessage`, `authenticatingPassword` and
     `activePlayer` drive the preview states. The wake/blank timers and
     authentication live in Service, not LockView.
   - **Rectangles for the overlay:** `elementRects` comes from the existing
     `elementItem()`/`drawnRect()`.
   - **Proof:** the runtime suite (look, settings_and_password, fingerprint)
     stays green.
6. **IPC.**
   - **`saveLook` and `previewLook`:** accept the new keys.
   - **`catalog`:** gains the ranges and moves to `version: 2`, so the app
     notices an older running plugin.
   - **`openStudio`:** none on the lock; the launcher is enough.

Validate the 1.3.0 layout engine on a real lock (still pending) before the
format change is released. Offline work isn't blocked by it.

## Launching

`foamy-lock-helper studio [open]` (Rust):
1. **Builds the app root.** It writes
   `~/.cache/foamy-lock-studio/root/` with links to the plugin's `studio/`
   files, `elements/`, `kit/`, `i18n/`, `LockView.qml`, `Layout.js` and
   `Model.js`. `Commons` links to `$OMARCHY_PATH/shell/Commons` (falling
   back to `/usr/share/omarchy/shell`). It never writes into the plugin
   folder, which the shell watches and reloads on any change. Linking
   single files is spiked first; copying them, as the harness does, is the
   fallback.
2. **Single instance.** If the app is already running, it raises the window
   through the studio's own IPC handler (`raise`), and exits. `-n` alone
   only exits.
3. **Starts it detached:** `quickshell -p <root>`.
4. **`studio install` and `studio uninstall`** write or remove
   `~/.local/share/applications/foamy-lock-studio.desktop` with
   `TryExec=`, `StartupWMClass=foamy-lock-studio` and the icon. Nothing is
   installed unasked; the README says how.

## The app (`studio/`)

```text
studio/shell.qml          //@ pragma AppId foamy-lock-studio; ShellRoot, FloatingWindow, IpcHandler raise
studio/StudioWindow.qml   three panes, keys, quit guard
studio/Canvas.qml         scaled LockView (latchFallback false, inputEnabled false), overlay, drag, resize
studio/Checker.qml        off-stage LockViews per connected screen and reference size → problems
studio/Library.qml        module list (drag source, keyboard moves), scene entries
studio/Inspector.qml      style tiles, scale/opacity/glass, placement, screens
studio/PresetStrip.qml    thumbnails (previews/presets/*.png)
studio/BackgroundPage.qml source, picture, decor, blur, dim, glass, tint
studio/Draft.js           pure: draft, diff against preset, undo/redo, snapping maths
```

- **Strings** go in the root `i18n/{en,no}.json` under `studio.*` keys.
  `FoamyI18n` reads the one folder beside `kit/`.
- **Theme:** follows Omarchy live through `Commons.Color`.
- **DESIGN.md applies:** rows, FoamyPalette, no hex literals, effects gated
  on the graphics API, en+no, right-to-left.

### Canvas

- **What it draws:** `LockView` at the selected monitor's logical size,
  scaled to fit.
  - `displayAwake` follows the window being visible, so drawn backgrounds
    stop while it's hidden or the session is locked.
- **Monitor picker:** the connected screens (`Quickshell.screens`), plus
  1280×720 and 1920×1080 reference sizes.
- **Preview states:** Idle, Typing, Wrong password, No media.
- **Data:** a sample track and sample user, never the user's real media or
  name. Network, battery and the clock are real.
- **Pictures:** decoded only through the lock's sandboxed helper
  (`background` kind, via FoamyNative), as on the lock. Until it's
  prepared, the canvas shows the theme colour.
- **Problems:** `Checker` keeps one hidden `LockView` per connected screen
  and reference size (debounced like the lock, 300 ms). It reports
  `geometryProblem()` per size. The cost (several views) is measured in the
  skeleton step; the fallback is to check only on drop.

### Interaction

- **Select:** click a module on the canvas or in the library. Handles
  appear and the inspector follows.
- **Move: drag with snapping (grid lock).** While dragging, the module
  snaps to the nearest of:
  - **Zone anchors:** where the element would sit in each zone's current
    stack.
  - **Grid:** steps of 1/48 of the screen height in both directions (square
    cells), stored as offset fractions.
  - **Guides:** the screen's centre lines, and other modules' edges and
    centres.

  The snap radius is 8 canvas px, whatever the zoom. The active guide is
  drawn.
- **Drop:**
  - **Zone:** the one whose anchor is nearest; the offset is the rest. The
    zone changes only on drop, so stacks don't jump mid-drag.
  - **Order:** a module entering a zone goes last in its stack.
  - **Password:** only anchors in its allowed zones count, and the drop is
    clamped to its limits.
- **Hold Shift to turn snapping off** while it is held: free placement,
  still clamped to the screen (user, 2026-11-08).
- **Hold Alt to lock the axis:** the drag stays horizontal or vertical,
  whichever it started along. It combines with Shift.
  - Read from key press and release as well as the pointer's modifiers, so
    pressing or releasing mid-drag takes effect without moving the mouse.
- **Resize:** corner handles change `scale` in 0.05 steps; Shift turns that
  snapping off too (the value is rounded to 0.05 on drop).
- **Keyboard** (selected module):
  - Arrows move one grid step; Shift+arrow moves one pixel.
  - Ctrl+arrows move to the neighbouring zone.
  - `+` and `-` scale; Delete hides the module (not the password).
  - `[` and `]` select the previous or next module.
- **App keys:**
  - Tab and Shift+Tab move between controls; F6 moves between panes.
  - Ctrl+Z and Ctrl+Shift+Z undo and redo.
  - Ctrl+Q quits; `?` lists the shortcuts.
- **Accessibility:**
  - The library list does everything the canvas does, so no edit needs a
    pointer.
  - Every control has an accessible name and role, and focus is always
    visible.
- **Library drag:**
  - Dragging a hidden module (e.g. Calendar) onto the canvas shows it at
    the drop point.
  - Dragging a shown one onto the library hides it.
- **Problems** show on the module (outline) and in a bar under the canvas,
  for example "Overlaps the password field on HDMI-A-1".
  - A problem on a connected screen blocks Apply.
  - One only at a reference size is a warning that doesn't block.

### Drafts and saving

- **The draft** is the look being edited, in memory, with undo/redo. It's
  also kept in `~/.local/state/foamy-lock/studio-draft.json` (atomic
  write), so a crash or closing doesn't lose it. On open, if the draft
  differs from the saved look, the app asks: "Continue editing" or "Start
  from saved".
- **Apply** sends `saveLook` with the draft's four look keys.
  - **Replies from the lock:** `ok`, `unchanged`, `invalid-json`,
    `invalid:…`, `locked`, `unsupported` and `no-entry`. Each has its own
    message.
  - **Failures from `omarchy-shell`:** "not responding" (2 s; the call may
    have run), "not ready", "Target not found." and "Function not found."
  - **After any unclear reply,** the app re-reads `catalog` and compares
    `look` and `lookError` instead of retrying blindly. Errors keep the
    draft.
- **In Rust:** `studio draft-load`, `studio draft-save` (look plus a bounded
  undo history, atomic write, 0600), `studio apply` (runs `omarchy-shell`,
  classifies every reply below, re-reads `catalog` when unclear, prints one
  JSON result) and `studio pick-picture` (the portal FileChooser over
  D-Bus). The QML calls them through FoamyNative, one process per action.
- **Preview full screen** sends `previewLook`.
- **Quitting** (Ctrl+Q, or closing the window) with unapplied changes asks
  first.
- **Presets:** picking one replaces the draft's preset, and asks before
  dropping element changes.

## Steps

Each step ends green: node tests, harness (parity, layout, styles,
runtime), kit-check, lint and the validator. Each is one commit.

1. **`uiScale` seam.** A pure refactor; every suite unchanged.
2. **Look format.**
   - Layout.js keys, ranges, password limits, canonical shape; node tests.
   - Parity unchanged.
3. **Lock rendering and geometry.**
   - Offsets, scale, opacity, glass, screens.
   - The new overlap rule (`drawnRect`, between zones), `password-high`,
     the full `geometryKey`, and the `geometryProblem()` and
     `latchFallback` split.
   - **Harness:**
     - Every preset at 1280×720, 1920×1080, 3440×1440 and 1080×1920
       expects no problem.
     - New cases: an offset off-screen, an offset overlap, the field moved
       too high, scale overflow, RTL mirroring, a primary-only element on a
       secondary view.
     - Decorations ignore offsets.
4. **App skeleton.**
   - Rust: `foamy-lock-helper studio` (root build, raise, install/uninstall,
     draft load/save, apply, pick-picture) with unit tests; rebuild the
     pinned binaries with `build-native.sh`.
   - `studio/shell.qml` and the window.
   - The canvas without editing, monitor picker and `Checker`, with the
     cost measured.
   - **Spike:** single-file links.
   - **Harness `studio` subcommand:** builds the root in a temp HOME, runs
     the app offscreen, grabs the window and checks the elements are drawn
     and no input has focus.
5. **Snapping and drag.**
   - `Draft.js` snapping maths, node-tested: anchors, grid, guides, the
     modifier, clamping, password limits, RTL, order on zone change.
   - Canvas drag, resize and keyboard.
   - Harness: scripted drags through test hooks, comparing the resulting
     look JSON.
6. **Inspector, library, presets strip, background page.** Port from
   `foamy-lock-studio` where it fits.
7. **Drafts, undo, Apply, preview, quit guard** (QML wired to the Rust
   subcommands). Rust tests and the harness with a fake
   `omarchy-shell`, covering every reply, the timeout and draft restore.
8. **i18n, RTL, accessibility, README and screenshots** (from the harness,
   sample data only).
9. **Retire the bar plugin** (`omarchy plugin disable`, with the user's go),
   and archive the repo.

## Tests

- **Node:** Layout.js and Draft.js.
- **Rust unit tests:** the `studio` subcommands (root build in a temp dir,
  desktop entry, draft round trip and corruption, every `saveLook` reply
  with a fake `omarchy-shell`).
- **Rust harness:**
  - **Existing suites:** parity (defaults identical to 1.2.0), layout,
    styles and runtime, all extended.
  - **New suite:** `studio`, offscreen and hermetic.
- **Never** a real lock, and nothing on the user's screen without asking.

## Risks

- **File picker.** The portal FileChooser is called from Rust over D-Bus.
  A D-Bus crate is a large dependency for a static musl helper; step 4
  decides between a crate (zbus, blocking) and a minimal hand-written
  client. Fallback: a validated path field.
- **`Commons` from the installed shell** could change in an Omarchy update.
  The exposure is the same as the lock's, and the parity run against the
  installed shell catches it.
- **The `uiScale` refactor touches every element.** Mitigation: it's a
  separate step, and all four harness suites must be unchanged.
- **Cost.** A full-size scaled `LockView` plus checker views. Measured in
  step 4. Options: render the canvas at half size, or check only on drop.
- **Free offsets on small screens.** The lock falls back safely; the app
  warns at reference sizes.

## Progress (2026-11-08)

Steps 1 to 3 are done on `feat/layout-engine`, offline (the harness only;
nothing ran on the real lock).

- **1, the `uiScale` seam.** Every element has a required `uiScale`, set by
  LockView (`elementScale(name)`). The field, dot and inset sizes moved into
  PasswordElement; the centre column is `contentWidthAt(scale)`, clamped to
  the screen less 64 px (at the view's scale). Thumbnails, parity and every
  suite were identical (thumbnails byte for byte).
- **2, the look format.** Layout.js: `scale`, `opacity`, `offset`, `glass`,
  `screens`, the password limits, `GLASS_STYLES`, `elementLimits()` and the
  canonical form. `catalog` is version 2 with `elementLimits` and `screens`.
- **3, rendering and geometry.** Offsets in `placeX`/`placeY`,
  `reservedRect` for the decorations, `glassAt()`/`glassFill`,
  `screens: "primary"`, `geometryProblem()`, `latchFallback`,
  `geometryProblemCode`, `elementRects` and the full `geometryKey`. A new
  harness suite, `placement` (also run by `layout`), holds the new cases.

Decisions made while building:
- **Canonical form strips defaults** (`scale: 1`, `opacity: 1`,
  `screens: "all"`, a zero offset) instead of filling them in, so a preset's
  look, `status` and the catalog are unchanged for existing looks. The scale
  is stored exactly on its step (`Math.round(v * 20) / 20`). `plainFoamy`
  compares `Layout.canonical(look)`.
- **`glass` is accepted per element, not per style.** The date (no glass
  style) rejects it; any style of the other elements accepts it, and the
  styles without a surface ignore it, so switching style never makes a look
  invalid. The glass styles: clock `analog`, `ring`; account `chip`;
  password `pill`, `box`, `card`; media `card`, `pill`, `art`; status
  `pill`, `system`; calendar `card`. The flip cards and terminal panel are
  fixed dark fills, not glass.
- **Where the codes live.** `geometryError` gained `password-high` (the
  field's top must be at least a third down); a new
  `Layout.lookGeometryError(elements, rects, …)` adds `element-offscreen`
  (1 px slack) and `element-overlap`. Order: the field's codes first. The
  field is still checked against every element, its own stack included,
  as before.
- **The stricter overlap rule found two things.** The `sheet` panel
  straddled the centred media card on a portrait 1080×1920 screen; on narrow
  screens it now widens over the centred bottom corners, as `split` does.
  The style sweep put the `system` status panel beside the top-center clock
  on 800×1000, where they really overlap; that case now moves the date and
  clock to the middle row.
- **The layout test** runs 1080×1920 as a fifth size (800×1000 kept) and
  requires `geometryProblem() === ""` for every preset and state.
- **The plugin validator** was run as
  `/usr/share/omarchy/bin/omarchy-plugin-validate .` (the same read-only
  script `omarchy plugin validate` dispatches to).

Open: live validation on a real lock (as before), and steps 4 to 9.

**Step 4, Rust half** (branch `feat/studio-native`, merged): `foamy-lock-helper studio` is in
(`native/src/studio/`, contract in its module docs): `open` (root build,
raise, detached start), `install`/`uninstall`, `draft-load`/`draft-save`/
`draft-clear`, `apply` and `pick-picture`. 47 unit tests and 4 CLI tests;
binaries rebuilt and pinned (x86_64 +132 KiB, aarch64 +113 KiB; no new
crates).
- **Spike, single-file links:** they work. An offscreen Quickshell ran a
  root whose `shell.qml` and `LockView.qml` are symlinks; it loaded
  `LockView` with `qs.Commons` and answered `studio raise`. Quickshell
  keys the instance by the root path, not the link target. So the root
  links files and doesn't copy them.
- **Picker:** a hand-written D-Bus client (std only) instead of zbus.
  Tests run it against an in-process fake bus and portal; the real
  portal hasn't been called yet.
- **Root extras:** `previews` and `bin` are linked too. The app finds
  the helper as `bin/$HOSTTYPE/foamy-lock-helper` from its own root
  through FoamyNative.
- **Apply:** an unclear reply is retried once with `saveLook`, not
  followed by a `catalog` re-read (see Drafts and saving). An `unchanged`
  answer to the retry confirms the save.

**Step 4, QML half, and step 5** (offscreen only; nothing ran on the
desktop):
- **The app:** `studio/shell.qml` (AppId `foamy-lock-studio`, a
  `FloatingWindow` "Lock Studio", `IpcHandler` `studio.raise()`:
  un-minimises, shows and `requestActivate()`s the window, answers
  `raised`), `StudioWindow.qml` (mockup A's three panes; keys), `Canvas.qml`,
  `Checker.qml`, `SampleView.qml` (LockView with the sample user and track,
  `enabled: false` so nothing reaches the lock's own controls) and three
  small controls (`StudioButton`, `Segmented`, `StudioToggle`): this
  plugin's kit has no FoamyButton or FoamyDropdown, so they follow
  DESIGN.md's tokens by hand. The library lists the modules (select, zone
  or "Hidden") and the scene; the inspector shows the selection's values
  only; the presets strip picks a preset (undoable, no confirmation yet).
  Preview and Apply are shown disabled.
- **Draft.js:** the draft is the sparse entry (`entry()` diffs the
  effective look against its preset). Edits (`place`, `setZone`,
  `setOffset`, `setScale`, `scaleBy`, `setOrder`, `setHidden`,
  `setPreset`) return a new entry and refuse what the lock would refuse.
  History keeps 100 steps. Comparisons are order-insensitive (`stable()`):
  a QML `var` property hands objects back with sorted keys; `ordered()`
  restores the lock's key order for saving.
- **Snapping:** per axis, anchors and guides within the radius win
  (nearest; anchors before guides on a tie), else the grid. Guides: the
  screen's centre lines and the other shown modules' edges and centres.
  Anchors are measured at drag start on a hidden probe LockView, one look
  per allowed zone, with the lock's own placement code (2.4 ms for nine
  zones). Offsets are measured centre to centre across and top to top
  down, in whole pixels, so the grid is "whole cells from the nearest
  anchor" and a drop lands exactly where it was shown. Mid-drag the module
  moves by an unlimited offset in its own zone; the zone changes on drop.
  A snap that the limits push back is not shown as one.
- **Keys:** arrows step to the next grid line (repeats never drift),
  Shift+arrows one pixel, Ctrl+arrows the neighbouring zone (on screen,
  so mirrored right-to-left; the field never into the top row), `+`/`-`,
  Delete (not the field), `[`/`]`, Ctrl+Z / Ctrl+Shift+Z (and Ctrl+Y),
  F6 / Shift+F6, `?`, Esc, Ctrl+Q (quits at once; the guard is step 7).
- **Checker:** one hidden `SampleView` per connected screen and reference
  size, following committed looks only (never mid-drag), checked 300 ms
  after the look settles with `geometryProblem()`, plus
  `Draft.problemElements()` for the modules to outline. A problem on a
  connected screen sets `applyBlocked`; one only at a reference size is
  shown as a warning.
- **Costs** (harness: offscreen, software renderer, 1920 × 1080 canvas):
  each hidden checker view costs about 15 MB of RSS (measured with
  `gc()`, six extra views at one size) and 0.4 ms per committed edit;
  creating one takes about 10 ms; the check itself is under 1 ms for nine
  views; one pointer move (snap, dragged look, relayout, no painting)
  0.2 ms. The app is about 130 MB with three checker views. If memory
  matters on machines with many screens: one hidden view resized through
  the sizes in turn (`geometryProblem()` is synchronous) keeps it to one
  view's cost.
- **Harness `studio`:** builds the root by `root.rs`'s rules in a
  temporary HOME (with the fixture-patched `LockView.qml`, `fixtures/` and
  the driver as `StudioTest.qml`, which the real `shell.qml` loads only
  with `FOAMY_LOCK_STUDIO_TEST=1`), runs it offscreen and checks: the
  window and title, no text input with active focus, every shown module
  drawn (pixel contrast inside each rectangle of a PPM capture), drags to
  an anchor, Shift (free) and Shift pressed mid-drag, Alt, the field's
  limits, resize, keyboard edits, undo/redo, preview states, the checker,
  the shortcuts overlay, F6, and `quickshell ipc … call studio raise`.
  Expected look JSON is compared exactly (key order aside). It runs
  mirrored too (`--language ar`).
- **Validator:** `omarchy-plugin-validate` accepts `studio/` as it is (it
  checks the manifest, entry points and symlinks; the shell loads only
  `Service.qml`), so nothing needed changing.
- **Lint:** the repo's command is unchanged (120). The studio files can
  only be linted in a built root (qmllint follows the links back to
  `studio/`, where `kit` isn't): 20 warnings, all `FoamyStyle.font.*`
  typed as QObject by the kit.

**Step 6** (offscreen only; nothing ran on the desktop):
- **Files** (names differ from the list above): `Inspector.qml`, `Library.qml`,
  `ScenePage.qml` (the background page and glass and dim), `PresetMenu.qml`
  (the strip stays in `StudioWindow`), `LockSources.qml`, and the controls
  `StyleArt`, `StyleTiles`, `ZonePicker`, `StudioSlider`, `StepField`,
  `SectionLabel`, `PaneNote`.
- **Draft.js** gained the inspector's and scene's edits, each refusing
  what the lock would: `setStyle`, `setOpacity` (hundredths, the field's
  floor 0.7), `setGlass` (null gives the look's glass back; `glassOf`,
  `hasGlass` for the current style), `setScreens`, `resetOffset`,
  `offsetPixels`/`pixelsToSteps`/`stepsToPixels`, `setBackground` (source,
  blur, dim, decor; "picture" only with a path), `setPicture` (source and
  path in one step), `setGlassLook`, `place(…, show)` (a module dropped
  from the library is shown in the same step) and `presetKeeping` (the
  draft's overrides on another preset, sparse against it; null when the
  lock refuses them). Node-tested.
- **Inspector** (`Inspector.qml`): Shown (not the field), style tiles for
  every style in `Layout.STYLES` (`StyleTiles` + `StyleArt`, ported from
  foamy-lock-studio; its FoamyIcon icons are drawn on a Canvas here, and
  the drawings never mirror; decoration tiles do), size, opacity and glass
  sliders (`StudioSlider`; glass only for a style in `GLASS_STYLES`, with
  "Use the look's" to clear it; ranges from `LIMITS`/`PASSWORD_LIMITS`), the
  3×3 `ZonePicker` (the field's top row faded and skipped), offset X/Y
  (`StepField`) in grid steps with their pixels at the screen shown,
  "Reset position", screens All/Primary (not account or field), and notes
  when the lock's settings hide the account or media. **Offsets from the
  fields go through the arrow keys' code** (`Canvas.offsetTo` →
  `Draft.nudge`), so they stay on screen and the field below the top third;
  X is towards the reading end (logical), like the stored offset.
- **One undo step per edit; a slider drag is one step.** A drag shows
  through `StudioWindow.preview()` (`previewDraft`, which only the canvas
  shows; the checker follows committed looks) and commits on release; each
  key press commits.
- **Library** (`Library.qml`): rows with a grip, faded when hidden.
  Dragging a row onto the canvas starts a canvas gesture
  (`Canvas.beginInsert`): the module (shown or not) follows the pointer
  with the canvas's snapping and zone highlight, and the drop is
  `place(…, show)`; leaving the canvas cancels it. A module dragged from the
  canvas over the library shows "Drop to hide" and hides on drop (never the
  field). Keys: Up/Down walk and select, Insert shows, Delete hides (added to
  the `?` list).
- **Presets:** the header button opens `PresetMenu.qml` (all selectable
  presets with their thumbnails, dropped from the button and mirrored
  right to left; arrows, Enter, Esc). Picking in the menu or the strip
  with changes asks: **Keep changes** (`presetKeeping`; disabled with a
  note when the lock refuses them), **Replace**, or Cancel/Esc; either
  answer is one undo step. It asks for **any** change, background and glass
  included, not only element changes, since a preset replaces those too.
- **Scene pages** (`ScenePage.qml`, in the inspector pane, chosen from the
  library): Background (source list, picture, blur for the wallpaper and
  picture, decoration tiles) and Glass and dim (dim within 0–90 %, glass
  opacity, tint). Hints from the retired popup (drawn sources, GPU-only
  blur).
- **Outside sources** (`LockSources.qml`):
  - *Omarchy wallpaper:* the helper's `wallpaper` probe on
    `~/.local/state/omarchy/current/background` (as Service), re-run when the
    window shows and on a theme change; the view loads the file as the lock
    does. **A video wallpaper shows the theme colour** (the lock's poster
    frame comes from Omarchy's `poster.sh`, not run here).
  - *Lock settings:* `~/.config/omarchy/shell.json` through a FileView that
    is never written, parsed by `Model.parseConfig`; `timeFormat`,
    `showUserInfo` and `showMedia` reach the canvas, the probe and the
    checker views. Without a valid entry, the lock's defaults.
  - *Picture:* `foamy-lock-helper studio pick-picture` (FoamyNative from
    the app root), replies translated by code (`NO_SESSION_BUS`,
    `PORTAL_UNAVAILABLE`, `PORTAL_FAILED`, unavailable helper, cancelled is
    silent, a path the lock refuses is "UNSUPPORTED"). The picture is
    prepared by the helper's sandboxed `artwork` job, kind `background`, at
    the screen shown and the blur (debounced 250 ms), and shown only then;
    until it is, the theme colour. **Deviation:** it runs with
    `XDG_CACHE_HOME=$XDG_CACHE_HOME/foamy-lock-studio/picture`, so the
    studio's preparations (one per screen size and blur) never evict the
    lock's own prepared picture from its four-file cache.
- **Switches** (`StudioToggle`) are drawn as Ui/ToggleSwitch (what
  FoamyToggle uses) from the Commons tokens, since the root has no `qs.Ui`:
  the theme's control fills and border, square on sharp themes.
- **RTL:** row labels set `AlignLeft` so they mirror; sliders fill from the
  reading start; the zone picker and menus mirror.
- **Harness `studio`:** the temporary HOME has a wallpaper link, the lock's
  entry (12-hour clock) and a picture. New steps cover the inspector, the
  library drag in and out, the preset menu and question, and both scene
  pages; the chooser never runs (its replies are fed to `applyPick`), the
  picture goes through the real sandboxed helper, and a missing one is
  reported. Six more captures. Passes in en, no and ar.
- **Lint:** in a copied root, the studio files show only the known kinds:
  `FoamyStyle.font.*` members, `qs.Commons` names qmllint can't resolve
  there (Style, Border, Color), and Process `environment` maps (as in
  Service.qml).
- **Costs:** unchanged in en and no. In Arabic with the 12-hour clock a
  commit costs about 21 ms (2.3 ms at 24 h): the lock's own Arabic AM/PM
  clock text, on every relayout; worth a look on the lock itself.
- **Live app:** the new files aren't in a root built before them; restart
  the app (`foamy-lock-helper studio` rebuilds the root).

Open for steps 7 and 8: drafts on disk (and starting from the saved look),
Apply, Preview and the quit guard; `displayAwake` also off while the
session is locked; screen hot-plug while a check runs; the video
wallpaper's still frame; accessibility review with a screen reader; the
README and its screenshots.

## Open questions for the user

None. Decisions 5 to 7 were confirmed on 2026-11-08 (Rust for the logic,
QML on Quickshell for the window; Shift turns snapping off).

## Review log

**Revision 2 → 3** (2026-11-08, user decisions): Rust `studio` subcommands
of `foamy-lock-helper` take over launching, the launcher entry, drafts,
Apply and the file picker; Shift turns snapping off and Alt locks the axis.

**Revision 1 → 2** (2026-11-08, independent read-only review against the
code; both blockers checked by hand):
- **Blocker, overlaps:** an all-pairs overlap check would trip most presets.
  Clocks pull up into the date with negative gaps (`ClockElement.qml`
  `stackGap`). The check now compares `drawnRect`s between zones and for
  offset elements only, with a test of every preset at four sizes.
- **Blocker, scale seam:** elements read `view.uiScale` directly, and the
  centre column caps width. A refactor step comes first.
- **Should-fix items folded in:**
  - **Geometry check:** it re-runs on offset or scale changes alone
    (`geometryKey`).
  - **Format details:** whole offsets only, no `glass` default, a
    canonical shape, and a tolerant scale step.
  - **Password under offsets:** `password-high` and limited anchors.
  - **Decorations and app hooks:** decorations use un-offset rectangles,
    and `latchFallback` replaces the umbrella editing mode.
  - **Launching:** the app root is built in `~/.cache` (the plugin folder
    is watched), `Commons` comes from `$OMARCHY_PATH`, and a running app
    is raised over IPC (`-n` only exits).
  - **Strings:** they go in the root i18n catalogs.
  - **Saving:** every reply is handled, unclear ones are followed by a
    catalog re-read, and the catalog moves to version 2.
  - **Pictures:** decoded only in the helper.
- **Minor items folded in:**
  - `options` deferred.
  - Snapping pinned down: zone and order on drop, radius in canvas px,
    modifiers from key events.
  - Keyboard: F6 for panes, `[`/`]` for modules, Ctrl+Q.
  - Accessible names and roles.
  - Per-screen checker views.
  - The `.desktop` entry has an owner (the launcher's `install`).
  - Facts: zone overflow isn't checked; glass and primary semantics;
    `displayAwake`; ordering against the pending real-lock test.

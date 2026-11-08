# Plan: Lock Studio, round 2 (user review, 2026-11-08)

Status: revision 2 (2026-11-08), after review. Where "Changes after review"
disagrees with D1–D7, it wins. Follows [lock-studio-app.md](lock-studio-app.md)
(steps 1–8) after the user tried the live app.

## What the user asked for

1. A **Reset** button: after confirmation, go back to the last save or to the
   chosen preset.
2. **Password field option:** hidden while empty ("or something").
3. **More date variants**, or calendar variants.
4. **Icon-only buttons** where a label isn't needed.
5. **Status contents:** choose what it shows (network, battery, audio and so
   on).
6. **A title for the preview states** ("Preview mode") inside that button
   group.
7. **A weather module**, using foamy-weather's location and settings.
8. **Native resolution** in the monitor picker (DP-2 shows 2752×1152, the
   logical size, not 3440×1440).
9. **Monitor picker as a dropdown**, so several screens don't fill the
   header.
10. **No presets strip** at the bottom (it can't be scrolled and repeats the
   menu). The preset picker moves to the **top of the left sidebar**.
11. **User presets:**
   - Saving changes made on top of a preset asks for a **name** and
     creates a user preset.
   - User presets are always **at the top** of the list.
12. **Deselect** by clicking outside the lock image.
13. **Tips**, pinned to the bottom edge of the left sidebar, including one
   about setting the profile picture and name with Mugshot.
14. **Animated wallpapers** (MP4, for example) if possible: see D8.
15. **Round 3: a security review** by a subagent, focused on memory handling
   and safe handling of input data such as images.

## Decisions (proposed defaults)

- **D1. User presets live in the lock's entry in `shell.json`,** as
  `userPresets`. The file is a dotfiles link, so the presets travel with
  the user's config, and the lock can validate and preview them.
  - **Shape:** `[{ "id", "name", "look": { preset, layout, background,
    glass } }]`, newest first, at most 50. The `id` is a short slug,
    unique, never reused while the preset exists.
  - **The active look stays self-contained:** the four keys, exactly as
    today. Two keys are added:
    - `userPreset: "<id>"` says which user preset the look came from.
    - `presetName` is not stored; the name is read from `userPresets`.
  - **When the user preset is deleted,** the active look keeps working;
    only the link is gone.
  - **Saving:** a new IPC `saveStudio <json>` writes the four look keys,
    `userPreset` and `userPresets` in one `updateEntryInline` call, so
    they never disagree. The reply strings match `saveLook`'s. `saveLook`
    itself stays for other callers.
- **D2. Saving flow:**
  - **Draft based on a built-in preset, with changes:** "Save" asks for a
    name (prefilled "<Preset> (mine)") and then applies.
    - **Cancel** keeps the draft.
    - **"Apply without saving a preset"** stays available as a secondary
      choice. Otherwise, testing a tweak would force a name.
  - **Draft based on a user preset:** "Save" updates that preset and
    applies. "Save as new…" asks for a name.
  - **Managing user presets:** rename and delete, from the preset menu.
    Delete asks first.
- **D3. Reset:** a header icon button (rotate-ccw). The dialog offers
  "Last saved look" or "Preset <name>", plus Cancel. Either choice is
  undoable.
- **D4. Element extras.** Small keys per element, each validated by a
  table, rather than a generic `options` bag:
  - **`password.reveal`:** `"always"` (default) or `"typing"`.
    - **`typing`:** the field's chrome is hidden while the text is empty and
      there is no failure, busy or fingerprint state. The hint line stays,
      so the screen still says how to unlock.
    - **Input:** the `TextInput` is still focused and live on every surface
      (the safety rule), and its rectangle stays reserved, so nothing moves
      when it appears.
  - **`status.items`:** an ordered subset of `network`, `battery`,
    `volume`, `bluetooth`, `keyboard`, `uptime`, `load` and `memory`.
    - **Defaults:** each style's current contents, so parity holds. `text`
      and `icons` show network and battery; `system` shows its panel rows.
    - **`volume`:** the default sink's volume and mute. Omarchy's
      `Commons.AudioNodes`, if usable from the lock; otherwise
      `Quickshell.Services.Pipewire`.
    - **`bluetooth`:** on/off and the number of connected devices
      (`Quickshell.Bluetooth`).
    - **`keyboard`:** the active layout. This is useful on a lock screen,
      where a password typed in the wrong layout fails. Source to be decided
      in step R2-3: `Commons.InputMethodState` or Hyprland's `devices`, read
      only, with no dispatch.
    - **Missing data:** an item whose source isn't available is left out.
      It never shows an error.
  - **`weather.details`:** `"temperature"` (default) or `"full"` (adds the
    condition and the high and low). **`weather.location`:** true or false,
    default **false**, because a place name on a lock screen is visible to
    anyone.
- **D5. More styles:**
  - **Date, new styles:**
    - `numeric`: the locale's short date.
    - `weekday`: a large weekday over the date.
    - `stacked`: a large day number beside the month and weekday.
    - `week`: the week number and the date.
  - **Calendar, new styles:** `week` (a 7-day strip with today marked) and
    `mini` (a month without a card).
  - **Presets:** they don't change; the new styles only add choices.
- **D6. Weather module** (new element `weather`, styles `compact`, `pill`
  and `detailed`; default hidden and placed `top-start`; never in a built-in
  preset).
  - **Data:** a new IPC in foamy-weather, `current(): string`. It returns
    `{ ok, temperature, unit, code, condition, high, low, location,
    updatedAt }`, with `condition` already translated.
  - **No bar widget needed:** foamy-weather's service must answer even with
    its bar widget absent. Today it only runs while a widget exists, and the
    user's bar has none. A `current()` call starts the service on demand. It
    stays active for 30 minutes after the last call.
  - **The lock's side:**
    - **Fetching:** it calls `foamy.weather current` (FoamyPeerIpc) when
      the lock or the preview opens, and every 15 minutes while the display
      is awake.
    - **Hidden:** when there's no answer, an error, or data more than 3
      hours old.
    - **Icons:** its own line icons for about 8 condition groups. No files
      are read from another plugin; plugins can't share files at runtime.
  - **Lock Studio:** the module is listed. When foamy-weather isn't
    installed or doesn't answer, its row is disabled with "Needs Foamy
    Weather". The canvas shows sample weather; the canvas never shows the
    user's real location.
- **D7. UI changes in the app:**
  - **Header:**
    - Undo, redo, preview and reset become icon buttons, with tooltips and
      accessible names. Apply stays a labelled primary button.
    - The `?` help becomes an icon.
  - **Monitors:** a dropdown with each entry as "DP-2 · 3440 × 1440"
    (native pixels = logical × `devicePixelRatio`, with "125 %" when
    scaled), then the reference sizes. The canvas still lays out at the
    logical size, as the lock does.
  - **Presets:** the bottom strip is removed. The first sidebar row is
    "Preset: <name> ▾". It opens the preset menu (thumbnails, user presets
    in a "Your presets" section first, then "Built-in").
  - **Preview states:** the group gets a caption "Preview" inside it,
    before Idle, Typing and the rest.
  - **Tips:** a card pinned to the bottom edge of the left sidebar
    (anchored there whatever the list above holds, not placed after the last
    row), replacing today's help text. The module list scrolls above it
    when space runs short. It shows one tip at a time, with previous and next buttons
    and an action button where there is one.
    - **First tip:** "Your picture and name on the lock screen come from
      your account. Set them with Mugshot." With an "Open Mugshot" button
      (`/usr/bin/mugshot`, started detached; hidden when it isn't
      installed, and the tip then says how to install it). The lock reads
      AccountsService's real name and icon, and `~/.face`, which is what
      Mugshot writes.
    - **Other tips:**
      - Shift drags freely and Alt locks the axis.
      - Arrows nudge and Ctrl+arrows change zone.
      - Any key closes the full-screen preview.
      - Saving changes to a preset creates your own.
      - Status can show your keyboard layout.
    - **Remembering:** the last tip seen is kept per user in the app's
      state.
  - **Deselect:** clicking the canvas area outside the lock image (or
    pressing Escape) clears the selection, and the inspector shows the
    look as a whole (background, glass and dim).
  - **Kit components instead of hand-drawn ones:** `FoamyIcon`,
    `FoamyButton`, `FoamyDropdown`, `FoamyToggle` and `FoamyNumberField`
    are synced from foamy-kit (`sync.sh --add`). They import `qs.Ui`, so
    the app root also links `$OMARCHY_PATH/shell/Ui`. That's a small
    `root.rs` change, with a rebuild and a new pin.

## Changes after review (revision 2)

- **Weather needs a service in foamy-weather (was D6).**
  - **Why:** foamy-weather is a bar widget only. Its `foamy.weather` IPC
    lives in Panel.qml, and `WeatherService` is only created by a Panel.
    Without the widget (the user's bar has none) nothing can answer.
  - **Fix:** foamy-weather gains a `service` kind and entry point. It
    hosts the service and an IPC `current()`, and is enabled through a
    `plugins[]` entry.
  - **Settings:** units, language, automatic location and user agent are
    read from that entry. The user already has a `foamy.weather` entry
    there.
  - **The bar widget** keeps working and feeds the same service when
    present.
  - **Step R2-4 starts in foamy-weather,** on its own branch and version.
- **User presets are validated as a third, independent group (D1).**
  - **Per item:** each preset is parsed on its own. Invalid items are
    dropped and reported in `status` and `catalog`; valid ones are kept.
  - **Isolation:** they never affect `settings` or `look`. An unknown
    `userPreset` id is ignored.
  - **Tests:** node tests for "bad presets list, look still applies".
- **Small per-preset operations instead of one big write (D1).**
  - **The operations:** `savePreset <json>` (a client-made id, so a retry
    is idempotent), `renamePreset <id> <name>` and `deletePreset <id>`.
  - **How they write:** the lock merges each one into the current entry.
    The full list never crosses IPC, which is capped at 64 KiB per
    argument.
  - **Caps:** a total size cap (256 KiB of presets) as well as the
    50-item cap.
  - **The link:** `userPreset` becomes a fifth `saveLook` key (omitted
    means removed), so applying a different look never leaves a stale
    link.
  - **Ordering:** Lock Studio's "save as preset and apply" runs
    `savePreset` then `saveLook`.
- **No merging over a stale entry.**
  - **Fix:** after `updateEntryInline` returns true, Service sets
    `lastEntry` to the written entry at once. Two quick saves (save, then
    rename) no longer revert each other (DESIGN.md: never merge over a
    stale entry).
  - **Write failures:** a save that `persistShellConfig` skips (unreadable
    shell.json) must not report `ok`. It is checked and reported as
    `write-failed`.
- **`password.reveal: typing` hides only the surface (D4).**
  - **What hides:** a separate `surfaceIdleHidden` hides the surface,
    border, underline, prompt, greeting and arrow.
  - **What stays:** the hint and fingerprint notice stay on `chromeShown`,
    so the screen always says how to unlock.
  - **Where it applies:** to `box`, `underline`, `terminal` and `card`.
    Pill and dots already show only the hint when idle, so the inspector
    disables the option for those styles.
- **Status sources corrected (D4).**
  - **Volume:** `Quickshell.Services.Pipewire` with `PwObjectTracker`
    (as Omarchy's audio panel does). `Commons.AudioNodes` is only a node
    filter.
  - **Keyboard layout:** `Quickshell.Hyprland`'s `activelayout` event
    plus a read-only `hyprctl -j devices` (as Omarchy's KeyboardLayout
    does). Not `InputMethodState`, which is fcitx and starts a Python
    indicator.
  - **Bluetooth:** `Quickshell.Bluetooth`.
  - **Plumbing:** every source is read through `view` (LockView's data
    properties). Lock Studio's sample sources then supply values, and the
    app never opens its own PipeWire or Bluetooth connection.
  - **Laziness:** the sources are created only when an item needs them;
    the /proc reads are gated on items, not the `system` style.
- **Status parity (D4).**
  - **Absent `items`:** means the style's built-in behaviour (`system`
    picks battery or network itself), and is dropped by `canonical`.
  - **Changing style:** clears `items`. Each item is rendered in all
    four styles.
- **The weather element is added without breaking presets.**
  - **Element order:** `weather` goes last in ELEMENTS, and every preset
    (`compose` and the literal ones) gets it hidden.
  - **Tables:** SCREENS_ELEMENTS and GLASS_STYLES are updated.
  - **Per-element keys:** `reveal`, `items`, `details` and `location`
    are allowed only on their own element, like `screens` and `glass`.
    They are not in the global ELEMENT_KEYS.
  - **Catalog version 3.**
- **Weather over FoamyPeerIpc.**
  - **Kit:** `sync.sh --add FoamyPeerIpc`.
  - **Before calling:** check
    `IpcResolver.handlersFor(root, "foamy.weather")`, so an absent plugin
    costs nothing every 15 minutes.
  - **A cold service:** answers "pending"; retry up to 3 times, 10 s
    apart.
  - **Replies:** validated in Model.js (numbers, string lengths) and drawn
    with `Text.PlainText`.
  - **Errors:** "Function not found." needs no special case; FoamyPeerIpc
    reports it as not ok.
- **Late content and geometry.** Weather or status arriving after lock
  re-runs the geometry check, as media does today. Lock Studio's Checker
  validates with the widest samples (full weather with a long condition, all
  status items).
- **Native size from Hyprland (D7).**
  - **Why:** Qt Wayland reports the integer `wl_output` scale (2 at 1.25),
    so `devicePixelRatio` would claim 5504×2304.
  - **Source:** `HyprlandMonitor.lastIpcObject` (`width`, `height`,
    `scale`), read-only, through the studio process's sources.
- **Kit sync scope (D7).**
  - **Synced:** `FoamyIcon`, `FoamyButton`, `FoamyDropdown` and
    `FoamyNumberField`. The `Ui` link in the root is enough for them
    (`Ui`'s Commons import resolves through the root's link); qmllint gets
    the Ui import path.
  - **Not synced:** `FoamyToggle`. It is part of the large FoamySettings
    component, so StudioToggle stays.
- **D5 styles adjusted.**
  - **Date:** `weekday` would duplicate `serif`, so the new date styles
    are `numeric`, `stacked` and `week`.
  - **Week number:** `week` needs a tested ISO week-number function, since
    `toLocaleString` has none.

## Steps

Each step ends green (node, harness parity/runtime/layout/render/styles/
studio in en/no/ar, kit-check, kit lint, qmllint baseline, validator) and is
one or more commits on `feat/layout-engine`.

- **R2-1. App UI.**
  - D7: icon buttons, monitor dropdown with native size, sidebar preset
    row, preview caption, strip removed.
  - D3: Reset.
  - Kit sync, plus the `root.rs` Ui link and binary rebuild.
- **R2-2. User presets** (D1, D2).
  - Lock: `userPresets` and `userPreset` validation (Model/Layout), the
    preset IPC (`savePreset`, `renamePreset`, `deletePreset`; see Changes
    after review) and the catalog listing user presets. `previewPreset`
    accepts `user:<id>`.
  - App: the naming prompt, update vs save-as, rename and delete, ordering.
  - Rust: `studio preset save|rename|delete` beside `studio apply`.
- **R2-3. Element extras and styles** (D4 password and status, D5).
  - Lock data sources: volume, bluetooth, keyboard.
  - Parity unchanged.
  - App: inspector controls for `reveal` and `items` (an ordered checklist).
- **R2-4. Weather** (D6).
  - foamy-weather: a `service` kind hosting the service and the `current()` IPC (settings from its `plugins[]` entry), with tests
    and a version bump, in its own repo and branch.
  - Lock: the weather element, polling, icons and harness fixtures.
  - App: the availability row.

- **R2-5. Animated wallpapers** (D8, below). It starts with a spike and
  is dropped cleanly if the spike fails.

## D8. Animated wallpapers (user, 2026-11-08: "if we can")

- **What's there today:**
  - **Video wallpapers:** Omarchy already supports them, and its stock
    lock shows a still poster (`plugins/lock/poster.sh`, ffmpeg). Foamy
    lock does the same (`Service.videoPosterPath`).
  - **Playback:** `qt6-multimedia` with the ffmpeg backend is installed,
    so `QtMultimedia`'s `Video` is available to Quickshell.
- **Proposal:** a background setting `motion: "still" | "play"`, default
  `still`.
  - **Sources:** `play` applies to source `omarchy` when the wallpaper is
    a video, and to source `picture` when the chosen file is MP4 or WebM.
    The picture source accepts video only with `play`.
- **Safety first: the lock never plays the user's file directly.**
  - **The rule:** decoding untrusted media in the lock process is what the
    picture pipeline already avoids.
  - **The helper's `background` kind prepares a clip in its bwrap and
    seccomp sandbox with ffmpeg:**
    - re-encoded to one constrained format: H.264, yuv420p, no audio, no
      metadata or subtitle streams;
    - at most the largest screen's size and 30 fps;
    - at most 60 s, looped;
    - capped bitrate and file size;
    - plus a poster frame.
  - **Playback:** the lock plays only that output, from the helper's
    cache.
  - **Failures:** a source that doesn't prepare falls back to the poster,
    then to the theme colour.
- **When it plays:**
  - Only with GPU rendering (Software rendering shows the poster).
  - Paused while the display is blanked, while `Style.reduceMotion` is on,
    and while the view isn't visible.
  - Optionally paused on battery (`pauseOnBattery`, default true).
  - The poster is shown until the first frame, so unlocking never waits
    on video.
- **Lock Studio:** the canvas plays the same prepared clip (through the
  same helper kind). The inspector shows Still or Play plus "Pause on
  battery", and explains when the source isn't a video.
- **Spike (first):**
  - `Video` on a `WlSessionLockSurface`-like layer in Quickshell 0.3.2,
    using the preview overlay, never a real lock.
  - CPU and GPU cost on DP-2.
  - That the ffmpeg re-encode works inside the existing sandbox profile
    (seccomp allow-list, time and memory limits).
- **If the spike fails** (crashes, high cost, the sandbox can't host
  ffmpeg): keep the poster, record why, and drop D8.

## Round 3: security review

After round 2, an independent subagent runs a security review of foamy-lock
(lock, Lock Studio, the Rust helper), and its findings are fixed. The focus
is memory handling and safe handling of input data:
- **Rust helper:**
  - Every `unsafe` block, libc and rustix call, and buffer and length
    arithmetic.
  - The hand-written D-Bus client (`native/src/studio/dbus.rs`): message
    parsing bounds, alignment, signature and array-length checks, and what
    happens with a hostile bus peer.
  - JSON request size limits.
  - The sandbox profile (bwrap mounts, the seccomp allow-list, resource
    limits) for images and, after D8, video.
  - Child processes: environment, argv, kill on timeout, zombies.
- **Images and video:**
  - Can any user-supplied file reach a decoder outside the sandbox (Qt
    image providers, `Image.source`, thumbnails, the canvas)?
  - Path handling: symlinks, `..`, races between check and use, and
    oversized files.
  - The cache: naming, permissions, eviction.
- **IPC inputs** (any local process can call `omarchy-shell`):
  - `saveLook`, `previewLook`, `previewPreset` and the new preset
    operations: size limits, strict parsing, no unlock path.
  - Peer weather replies: validated and rendered as plain text.
- **Files:**
  - The studio root in `~/.cache` (symlink attacks).
  - The `.desktop` entry (`Exec` quoting and injection through paths).
  - The draft and state files (permissions, atomic writes).
  - `shell.json` writes through Omarchy (the symlink kept, never a
    temporary file in the wrong place).
- **The lock's safety properties:**
  - The fallback chain.
  - A live, focused input on every surface.
  - No way for a look, preset or IPC call to hide the field or block
    unlocking.
- **Method:**
  - A read-only review report with severities and evidence.
  - Fuzzing where it pays: `cargo fuzz` targets for the D-Bus parser and
    the JSON request parser, run for a bounded time.
  - Fixes on a branch with tests for each finding.

## Risks

- **Weather couples two plugins.** It goes over IPC only, and the lock
  treats any failure as "hidden".
- **foamy-weather releases separately.** The lock must cope with an older
  foamy-weather that has no `current()` ("Function not found." is treated
  as unavailable).
- **`reveal: typing` hides the field.** Mitigations: the hint stays, every
  state shows the field, and a runtime test types on each surface with the
  field hidden.
- **New status sources on the lock screen** (Pipewire, Bluetooth). Each is
  read-only; a missing service drops the item. Loading them only when the
  item is chosen keeps the default lock unchanged.
- **`userPresets` grows `shell.json`.** Capped at 50; each look is small.

## Progress

**R2-1, app UI** (2026-11-08, on `feat/layout-engine`; offscreen only,
nothing ran on the real lock or the desktop):
- **Kit:** `FoamyIcon`, `FoamyButton`, `FoamyDropdown` and
  `FoamyNumberField` synced with `sync.sh --add` (bringing `FoamyMotion`,
  `SafeTextField` and `FoamyTextSettingField`, which R2-2's name prompt
  can use). `FoamyToggle` not synced; `StudioToggle` stays.
- **Root:** `root.rs` links `Ui` beside the `Commons` it links (so
  `$OMARCHY_PATH/shell/Ui`, else the installed one), reserved like
  `Commons`; a unit test covers it. Helper rebuilt and pinned. The harness
  root links it too; qmllint gets `-I` with `qs/Commons` and `qs/Ui`.
  **The live app needs a restart** (`foamy-lock-helper studio` rebuilds the
  root): the new files (`IconButton.qml`, `Tips.qml`) and the `Ui` link
  aren't in a root built before them.
- **Header:** `IconButton` (a FoamyButton with its own FoamyIcon: tooltip
  "Undo (Ctrl+Z)", accessible name "Undo", the keys as description) for
  undo, redo, reset, preview and help; Apply is a FoamyButton, primary.
  **Deviation:** the kit has neither `rotate-ccw` nor `redo-2`. Redo is
  `undo-2` mirrored (`flipped`); Reset uses `undo-dot`. Adding the two
  Lucide icons is a foamy-kit change (and release) of its own. DESIGN.md
  puts icon-only toolbar actions on FoamyAction; FoamyButton was the
  synced scope, and its bordered square matches the dropdown beside it.
- **Reset (D3):** the dialog offers "Last saved look" (`savedDraft`) and
  "Preset <name>" (the draft's preset, no changes), each enabled only when
  it changes the draft, plus Cancel/Esc; either is one undo step.
- **Screens:** a FoamyDropdown. `Draft.monitorEntries(screens, natives)`
  (node-tested) labels each screen with Hyprland's
  `lastIpcObject.width/height/scale` (a rotated transform swaps them),
  "DP-2 · 3440 × 1440 · 125 %"; `width`/`height` stay logical. The
  natives are read in `LockSources` only when `HYPRLAND_INSTANCE_SIGNATURE`
  is set (`Hyprland.refreshMonitors()` on screen changes and when the
  window shows, read only); without Hyprland the logical size shows.
- **Presets:** the strip is gone. The library's first row, "Preset: <name>"
  with a chevron, opens the preset menu (dropped from the row). The menu
  has a `userPresets` hook and a "Built-in" heading for R2-2.
- **Preview caption:** `Segmented.caption`, "Preview" inside the group.
- **Deselect:** a tap on the canvas outside the lock image
  (`Canvas.tapOutside`, the letterbox) or Esc (after the open questions,
  menus and the shortcuts) sets `selected` to "". The inspector pane then
  shows ScenePage's new "look" page: background, then glass and dim.
- **Tips:** `Tips.qml`, pinned to the library pane's bottom edge (full
  width, a hairline above). The library scrolls above it (a non-interactive
  Flickable, so a drag on a row stays a module drag; the wheel scrolls and
  the keyboard keeps its row in view). Seven tips: Mugshot, dragging in and
  out, Shift/Alt, arrows, the look as a whole, closing the preview, `?`.
  The card keeps the longest tip's height. "Open Mugshot" runs
  `Quickshell.execDetached(["/usr/bin/mugshot"])` and shows only when
  `test -x` finds it (checked when the window shows); otherwise the tip
  says `omarchy-pkg-add mugshot`. **Left out until their steps:** "Saving
  changes to a preset creates your own" (R2-2) and "Status can show your
  keyboard layout" (R2-3); they'd be untrue today. The last tip seen is in
  `$XDG_STATE_HOME/foamy-lock/studio-state.json` (`{version: 1, tip}`,
  FileView, atomic).
- **Form buttons** in the dialogs, the inspector and the picture row are
  FoamyButtons. `StepField` stays (FoamyNumberField has no −/+ or pixel
  detail).
- **Harness `studio`** (en, no, ar): icon buttons' names, tooltips and
  size; help; Reset both choices, undo, Esc and the enabled choices; the
  dropdown's entries and picks, a scaled fake monitor's label; the
  caption inside the group; the preset row opening the menu below it;
  deselect by an outside tap (not on the image) and Esc, the look page;
  the tips card's bottom edge equal to the pane's, a short list scrolling,
  paging and wrapping, the state file, Mugshot absent (no button, install
  hint) and present (a fake script, started, never the real one). New
  captures: `studio-reset`, `studio-look`, `studio-tips`.

**R2-2, user presets** (2026-11-08, on `feat/layout-engine`; offscreen only,
the fake omarchy-shell, nothing ran on the real lock or shell):
- **Lock, the third group:** `Layout.parseUserPresets` (a separate region at
  the end of Layout.js, its own exports) reads `userPresets` item by item:
  an invalid item (shape, id slug, name of 1 to 64 characters without
  control characters, a look parseLook refuses, a second item with an id
  already read, past 50 items or 256 KiB) is skipped and counted, the
  others kept. Service calls it beside parseConfig and parseLook; nothing
  in it touches `settings` or `look`, and an unknown `userPreset` is
  ignored. `status` adds `userPresets` (ids and names),
  `userPresetsInvalid`, `userPresetsError` and `userPreset`; `catalog`
  adds `userPresets` (entry, effective look, the built-in preset's
  thumbnail), the same counts and `userPresetLimits`. `previewPreset`
  takes `user:<id>`.
- **IPC contract** (target `foamy.lock`; Layout.savingPreset,
  renamingPreset, deletingPreset merge one item into the entry as last
  read and keep every other item, invalid ones too):
  - `savePreset <json>`: `{id, name, look}`, `look` without
    `userPreset`. A known id is updated in place, a new one goes first.
  - `renamePreset <id> <name>`: `unknown-preset` for an id not there.
  - `deletePreset <id>`: also drops `userPreset` when it names it; an id
    not there answers `unchanged`.
  - `saveLook` takes `userPreset` as a fifth key (omitted: removed).
  - Replies: `ok`, `unchanged`, `invalid-json`, `invalid: …`, `locked`,
    `unsupported`, `no-entry`, `write-failed`, and for the preset calls
    `full` (50), `too-large` (256 KiB of the list as written),
    `unknown-preset`. Each call is idempotent.
  - **write-failed:** the scoped shell API doesn't expose
    `userConfigUnreadable`, so Service applies Omarchy's own rule to its
    own read of shell.json (`entryState`: not a version 1 object, or not
    read at all) and answers `write-failed` before writing; saveLook
    too.
  - **lastEntry:** set to the written entry as soon as
    `updateEntryInline` returns true (and the presets re-read), so two
    quick writes don't revert each other.
- **Helper:** `studio preset save|rename|delete`, stdin `{id, name,
  look}` / `{id, name}` / `{id}`, the lock's checks on shape (64 KiB per
  argument), `studio apply`'s reply line and single retry
  (`apply::run`); `full`, `too-large` and `unknown-preset` confirm after
  a retry, `write-failed` (like `locked`) doesn't. A look (apply, the
  draft file) may carry `userPreset`. Binaries rebuilt and pinned.
- **App (D2):** the draft carries its link (`userPreset`): `commit()`
  keeps it on every edit, a built-in pick or Reset to one drops it, the
  draft file and `savedDraft` keep it. Apply is still the single entry
  point (`Draft.saveMode`): a built-in preset with changes asks for a
  name (FoamyTextSettingField, prefilled "<Preset> (mine)" / "(mitt)",
  " 2" when taken) with "Apply without saving a preset" and Cancel; a
  user preset with changes is updated, then applied; savePreset then
  saveLook with the link, and a refused save stops before saveLook. The
  preset menu always shows "Your presets" (with "Save as new…", and an
  empty note without any) above "Built-in"; each user tile has rename and
  delete (pencil, trash; F2 and Delete on the cursor); delete asks.
  Picking a user preset with changes only offers Replace. Reset's
  "Preset <name>" goes back to the user preset as saved. The list updates
  as soon as the lock confirms (Draft.presetsAfter) until shell.json
  follows. Names show as plain text (StudioButton, the questions). The
  tip "Saving changes to a preset creates your own" joined the list.
- **Tests:** node (`user-presets.test.cjs`: bad list with the look still
  applying, per-item drops, caps, idempotent retry, two quick operations;
  `studio-presets.test.cjs`: the link, saveMode, ids, names, the list
  after an operation); runtime (`user_presets`: listing, preview, save,
  retry, rename right after save, the fifth key, delete, strict parsing,
  both caps, write-failed, no-entry); helper unit and CLI tests; studio
  harness (en/no/ar) for every flow, with two new captures
  (`studio-user-presets`, `studio-preset-name`).
- **Deviations:** `catalog` stays version 2 (the keys are additive; the
  round-2 elements branch bumps it to 3). "Save as new…" applies too, as
  the plan's "save as preset and apply" order. Quitting's "Apply and
  quit" never asks for a name (a built-in look is applied as it is).
- **The user's review of the live app** (its own commit): the tips' previous
  and next are small ghost buttons under the text; tips launch nothing
  (the "Open Mugshot" button and `openMugshot()` are gone); the header shows
  only "Unsaved changes" as a warning (and Apply/Preview results), no
  "The lock has this look"; the studio strings and the README's Lock Studio
  section say "lock screen" / "låseskjerm".

## Open questions for the user

None. Settled by the user on 2026-11-08:
- **D1/D2:** user presets live in `shell.json`, and "Apply without saving
  a preset" stays as a secondary choice.
- **D6:** weather is hidden by default and shows no location unless turned
  on. Turning those on is the user's privacy decision.

## Review log

**Revision 1 → 2** (2026-11-08, independent read-only review against the
code):
- **3 blockers:**
  - The weather IPC doesn't exist without the bar widget.
  - One bad user preset could break the settings or the look.
  - The full preset list can exceed the 64 KiB IPC argument cap.
- **7 should-fix:**
  - Merging over a stale entry.
  - Where `userPreset` lives.
  - The `reveal` hint.
  - The status data sources.
  - Status parity.
  - Presets breaking when `weather` is added.
  - FoamyPeerIpc handling.
- **Minor:**
  - The kit sync scope (FoamyToggle).
  - `devicePixelRatio` at fractional scales.
  - A duplicate date style.
  - Late content and geometry.
- All folded into "Changes after review".

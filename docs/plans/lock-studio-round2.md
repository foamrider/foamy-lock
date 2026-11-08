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
12. **Deselect** by clicking outside the lock image.
11. **User presets:**
   - Saving changes made on top of a preset asks for a **name** and
     creates a user preset.
   - User presets are always **at the top** of the list.

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
    `saveStudio` IPC and the catalog listing user presets. `previewPreset`
    accepts `user:<id>`.
  - App: the naming prompt, update vs save-as, rename and delete, ordering.
  - Rust: `studio apply` gains a mode that sends `saveStudio`.
- **R2-3. Element extras and styles** (D4 password and status, D5).
  - Lock data sources: volume, bluetooth, keyboard.
  - Parity unchanged.
  - App: inspector controls for `reveal` and `items` (an ordered checklist).
- **R2-4. Weather** (D6).
  - foamy-weather: a `service` kind hosting the service and the `current()` IPC (settings from its `plugins[]` entry), with tests
    and a version bump, in its own repo and branch.
  - Lock: the weather element, polling, icons and harness fixtures.
  - App: the availability row.

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

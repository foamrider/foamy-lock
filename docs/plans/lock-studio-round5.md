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

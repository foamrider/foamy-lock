# Plan: adjustable lock-screen decorations (round 5, item 3)

Status: design note for review · 2026-11-08 · branch `feat/layout-engine` ·
no code yet. Follows [lock-studio-round5.md](lock-studio-round5.md) item 3
and the decorations of [layout-engine.md](layout-engine.md) (step 8).

## The request

From the round 5 review:
- Decorations should be **more adjustable**, with parameters instead of
  fixed shapes.
- The **island must line up exactly** with the media player's own
  background. Today some settings put them out of step.
- **Every built-in preset must be possible to recreate** with the tools
  Lock Studio offers.

This note covers the diagnosis, the model, the look format, safety, Lock
Studio and the steps. Nothing here is built yet.

## Diagnosis

### How decorations work today

- **One string.** `background.decor` is one of `none`, `split`, `sheet`,
  `cinema`, `strip`, `island`, `frame` or `card` (`Layout.js` `DECORATIONS`).
  Each kind is a hard-coded shape in `elements/Decoration.qml`, with its own
  padding, radius, fill, border and zones written into the code.
- **Fitted to zones, not modules.** Every kind except `frame` measures
  `LockView.zonesRect(zones)` (`LockView.qml:444-457`). That is the union of
  the shown elements' `reservedRect`s in those zones, and `reservedRect`
  (`LockView.qml:436-439`) is the drawn rectangle **with the offset taken
  away**. This was chosen on purpose so that "an offset element never drags
  a surface along" (README `offset` row, lock-studio-app.md "Decorations
  follow the reserved, un-offset rectangles"). The placement suite even
  asserts it ("decorations ignore offsets", `tests/harness/src/placement.qml:203-212`).
- **Own colours.** The decorations' fill is `Decoration.fill(alpha)`
  (`Decoration.qml:104-108`): the theme's glass colour at a fixed alpha
  (0.5 to 0.9), times the look's `glass.opacity`. The island is black at
  0.82 with the `none` tint and ignores the opacity (`Decoration.qml:229`).
  Elements draw their glass with `LockView.glassAt()` (`LockView.qml:486-492`):
  the theme glass's own alpha (0.34 by default) times the element's `glass`,
  or the look's, and mixed with the accent under the `accent` tint.
- **Elements keep their surfaces.** The media card, pill and art, the
  status pill, the calendar card, the weather card, the account chip and
  the field's pill, box and card each draw their own glass
  (`MediaElement.qml:86-90` and the other elements' `glassFill`). A
  decoration behind them adds a second background.

### Why the island goes out of step with the media background

Each of these, alone, is enough. The examples are at 1920×1080
(`uiScale` 1) on the `island` preset.

| # | Cause | Settings that show it | Code |
|---|---|---|---|
| 1 | **Offsets are ignored.** The island wraps where the zone would put the media, not where it is drawn. | `layout.media: { zone: "top-center", offset: { x: 0.03, y: 0.02 } }`. The card is drawn 58 px right and 22 px down, while the island stays around its un-offset place. | `Decoration.qml:70-77` → `zonesRect` → `reservedRect` |
| 2 | **Lock Studio creates offsets.** A drop on the canvas stores the zone *and* the distance from the zone's anchor (`Draft.drop` → `offsetFrom`). Unless the snap lands exactly on the anchor, the drop leaves an offset, and cause 1 applies. This is the most likely way the user met it. | Drag the media card under the clock in Lock Studio and drop it a little off the snap line. | `studio/Canvas.qml:238-240`, `studio/Draft.js:651-660` |
| 3 | **Fixed, uneven padding.** The island pads 34 px across and 12 px down (scaled by the view's `uiScale`, not the element's `scale`). Its radius is `min(h/2, 40)`. The card's radius is `22 × scale`, and the pill's is half its height. The two outlines are never concentric. | Media `card` in `top-center`: a 470×92 card (radius 22) inside a 538-px island (radius 40). The gap is 34 px at the ends and 12 px below. With `scale: 1.5` the card is 705×138 (radius 33) and the gaps stay the same. | `Decoration.qml:74-76, 228`; `MediaElement.qml:87` |
| 4 | **Two different colours.** The island is `rgba(0,0,0,0.82)`. The media card is `glassAt(g)`: the theme's glass at 0.34 × g, accent-mixed under the `accent` tint. Under the island the card shows as a lighter lozenge with its own 1 px border. | Any media style with a surface (`card`, `pill`, `art`) in `top-center` with `island`. | `Decoration.qml:229`; `LockView.qml:486-492` |
| 5 | **Glass settings move only one of them.** `glass.opacity` and `layout.media.glass` change the card but not the island (black under the `none` tint). With `glass: 0` the card's fill goes but its border stays. `glass.tint: "accent"` gives the island the plain theme glass at 0.86 and the card the accent-mixed glass at `max(a, 0.55)`. A theme's `[lock] background` recolours the card but not the black island. | `glass: { opacity: 0.4 }`; `layout.media.glass: 0`; `glass.tint: "accent"`. | `Decoration.qml:104-108, 229`; `MediaElement.qml:88-90` |
| 6 | **Half pixels.** Centre-column items sit at `(width − w) / 2`, a fractional x. The island floors its x and ceils its width, so on odd widths its sides are up to 1 px uneven around the card. | Any odd-width card or pill in `top-center`. | `LockView.qml:388`, `Decoration.qml:75-76` |

**The same causes affect the others.**
- **Offsets (causes 1 and 2):** the `card`, `strip`, `sheet`, `split` and
  `cinema` kinds use the same `zonesRect`, so an offset module leaves them
  behind.
- **Double backgrounds (causes 3 to 5):** `card` (the field's `box` inside
  it in `card`; the `terminal` field in `rain`) and `strip` (the `box` field
  in `dock`) draw a second surface under their elements' own glass.
- **The frame** ignores the content altogether. An offset element can sit
  across its line; the layout test skips offset elements
  (`tests/harness/src/layout.qml:254`).

### Why the presets can't be recreated with the tools today

- **One choice, no parameters.** Lock Studio offers the decoration only
  as eight tiles (`studio/ScenePage.qml:431-445`). Padding, size, radius,
  fill, frost, border and what the shape wraps can't be changed. "A bit
  more padding" or "the panel on the other side" has no answer.
- **Hidden coupling.** Choosing `cinema` or `strip` also moves the
  bottom-center stack to the bottom edge (`LockView.qml:406`,
  `BAND_DECORATIONS`). Neither the UI nor the format says so.
- **Gaps outside decorations** (found while checking the acceptance test,
  see Lock Studio):
  - `sheet` has `dim: 0.12`, but the dim slider steps by 0.05
    (`ScenePage.qml:468`), so 0.12 can't be reached.
  - `terminal` uses the `black` source, which round 5 item 5 replaces with
    "Solid colour".
  - Element `order` inside a zone can only be set by the order of drops
    (`Draft.place` appends), so a preset's order has to be reachable by a
    drop sequence.

## The model: decorations as shapes

A look has a list of **shapes**, at most **4**. They are drawn over the
background (wallpaper, video, drawn source and scrim) and under every
element, in list order, except that frosted shapes are drawn first (see
Fill). Each shape is plain data, with no code and nothing loaded from a
user path.

### Kinds

There are three primitives. The eight old kinds are templates built from
them.

| Kind | What it is | Old kinds it covers |
|---|---|---|
| `box` | A rounded rectangle around what it wraps, plus padding. It can be stretched across the screen's width. | `island`, `card`, `strip` |
| `panel` | A rectangle attached to one screen edge (`start`, `end`, `top`, `bottom`) along its whole length, less the inset. Its thickness reaches past what it wraps by the padding, within a minimum and a maximum. | `split`, `sheet`, `cinema` (two panels) |
| `frame` | A border inset from the screen's edges. | `frame` |

### What a shape wraps

`wrap` is one of:
- **`{ "zones": [...] }`**: the shown elements in those zones, at their
  **reserved (un-offset)** rectangles. This is today's rule, kept so that
  every preset draws as before and a zone-shaped panel doesn't jump when
  one module is nudged.
  - **Companion zones on narrow screens.** Narrow screens (`compactLayout`)
    stack the bottom corners in the centre, and `middleStacked()` puts
    middle-end under middle-start. A shape that wraps one zone of such a
    pair then wraps both. This is the general form of the special cases in
    `Decoration.qml:39` and `:49`; for the presets it gives exactly today's
    zone lists.
- **`{ "modules": [...] }`**: the named elements at their **drawn**
  rectangles (`LockView.drawnRect`). This includes the offset, the scale,
  the centred text's natural width and content that arrives late. It is the
  mode for "the island is the media player's background".
- **Absent** (panels only): no content. The thickness is the panel's
  minimum. A frame never wraps.

Hidden elements, elements hidden by privacy (`showMedia`, `showUserInfo`),
`screens: "primary"` elements on other screens and elements with nothing to
show (no player, no weather) are not shown, so they are left out. **A
`box` with nothing shown is not drawn.** A `panel` with nothing shown falls
back to its minimum (today's cinema bars keep 12 %).

### Geometry (in px at 1080p, scaled by the view's `uiScale`)

All lengths are whole numbers, scaled like every other length on the lock:
`px = round(n × uiScale)`. Fractions of the screen are written
`{ "screen": f }`, a fixed length `{ "px": n }`. `R` is the union rectangle
of what the shape wraps, `W` × `H` the view.

- **`box`:**
  - **Rectangle:** `pad: { x, y }` is added on each side:
    `x = floor(R.x − padX)`, `y = floor(R.y − padY)`,
    `w = ceil(R.w + 2·padX)`, `h = ceil(R.h + 2·padY)`.
  - **`stretch: "across"`:** spans `inset … W − inset`. The top and bottom
    stay within `inset` of the edges (today's strip:
    `bottom = min(H − inset, …)`).
- **`panel`:**
  - **`E`:** how far the wrapped content reaches from the panel's edge
    (start: `R.x + R.w`, mirrored right to left; top: `R.y + R.h`;
    bottom: `H − R.y`).
  - **Thickness:** `T = ceil(E − inset + pad)`, then at least
    `size.min`, then at most `size.max`. Past `size.fillPast` the panel
    fills the screen (today's split past 62 %). It never exceeds the span
    less `2·inset`.
  - **Placement:** `inset` applies on all sides, as with today's sheet: a
    gap from its own edge and from the two edges beside it.
- **`frame`:** inset by `inset`, with `radius`, and a style: `bezel` (the
  dark band outside the line plus a hairline, as today), `glow` (the accent
  line with fading rings, as today) or `line` (the hairline only; new).
- **Radius:** `radius` is drawn as `min(radius, w/2, h/2)` (the island's
  `min(h/2, 40)` is radius 40). A box also takes `"auto"`: wrapping exactly
  one module that has a surface, it is that module's own corner radius plus
  the padding, so the two are concentric. Otherwise the default, 24.

The zone geometry and the decorations' rules move into **one pure
function** in Layout.js (`shapeRects(shapes, frame)`). Its input is the
view size, `uiScale`, right to left, the compact flags and each shown
element's zone, drawn rectangle, offset and surface radius. Node can then
test it without QML (see Tests).

### Fill, border and frost

- **`fill: { color, opacity, frost }`:**
  - **`color`:**
    - `"glass"`: the theme's glass colour at `opacity × glass.opacity`,
      and at least 0.9 under the `solid` tint. This is today's
      `Decoration.fill()`, unchanged.
    - `"surface"`: exactly what the wrapped modules' own surfaces draw,
      `glassAt(g) × opacity`. `g` is the module's own `glass` when the
      shape wraps exactly one module, otherwise the look's. Tint, theme and
      opacity follow, so the shape and the module can't drift apart.
    - `"black"`: black at `opacity` (cinema bars, island).
    - There is no free colour and no light colour. Text on the lock is
      light, and the suite allows no hex outside the art surface.
  - **`frost: true`:** blurs the wallpaper behind the shape (today's sheet
    and card).
    - **GPU only.** Under the software renderer nothing is created (a
      `Loader`, not a hidden item).
    - **At most 2 frosted shapes** per look.
    - **Skipped where there is nothing to blur.** With the `theme`,
      `black` or drawn sources it draws nothing today; the same pixels
      without the work.
    - **Drawn first.** Frost samples only the wallpaper, so a frosted
      shape drawn over another shape would cut a hole in it. Frosted shapes
      are therefore always drawn before the others.
- **`border: { color, width, sides }`:**
  - **`color`:** `"glass"` (the look's glass edge, which follows the tint
    as today) or `"accent"`.
  - **`width`:** 0 to 4, drawn as `max(1, round(width × uiScale))`. That
    reproduces today's unscaled 1 px edges and the split's
    `max(2, round(3u))` accent edge. 0 means no border.
  - **`sides`:** `"all"`, or `"inner"` for a panel: only the edge that
    faces the screen, which isn't drawn when the panel fills the screen.

### One background, not two: `absorb`

- **`absorb: true`** makes the shape **the** background of the modules it
  wraps:
  - their own surface (fill and border) isn't drawn;
  - their content stays exactly where it is.
- **What it applies to:** the panel-like surfaces, `ABSORB_STYLES` in
  Layout.js:
  - media `card`, `pill` and `art`;
  - status `pill` and `system`;
  - calendar `card` and `week`;
  - weather `pill`, `detailed` and `card`;
  - the account `chip`.
- **What it doesn't apply to:**
  - **The password field's surface, never.** It is where you type, and
    its glass floor (0.08) stays.
  - **The analog and ring clock faces.** They are the clock's drawing,
    not a backdrop.
- **What the elements need:** each element with a surface gets a
  `surfaceShown` input from LockView and exposes `surfaceRadius`, which
  `radius: "auto"` uses.
- **"The island lines up exactly"** becomes a construction rule rather
  than a tuning job. A box with `wrap: { modules: ["media"] }`,
  `pad: { x: 0, y: 0 }`, `radius: "auto"`, `fill: { color: "surface" }` and
  `absorb: true` draws exactly the media pill's or card's own surface, for
  every scale, offset, glass, tint and theme.
  - **Padding** then grows it concentrically.
  - **`black` at 0.82** makes it a dynamic-island look.
  - The render test proves the zero-padding case pixel for pixel (see
    Tests).

### Following modules live

- **Bindings, not timers.** `shapeRects` is one binding in LockView over
  `elementRects` (already computed for the geometry check), the reserved
  rectangles, the shown map and the look's shapes.
- **What it follows:**
  - **Offsets and scale,** including mid-drag on the Lock Studio canvas,
    where the drag is shown as a live look with an offset.
  - **Late content:** media starting or stopping, a track title that
    changes the pill's width, weather that arrives later, and status items
    that read later.
- **No animation.** A shape changes size in the same frame as its
  content, so there's nothing to pause under reduced motion and no
  per-frame cost.
- **Stable around the field.** The field reserves a fixed size for its
  hint, failure and notice lines, so a shape around it never moves while
  you type.

### Shapes that change the layout: the bottom band

Today `cinema` and `strip` move the bottom-center stack down into the
band.
- **The rule:** this stays, made explicit and derived **from data only,
  never from geometry**: a `panel` on the `bottom` edge, or a box stretched
  `across`, that wraps the `bottom-center` **zone** is a bottom band
  (`Layout.bottomBand(shapes)`).
- **No module wraps.** A shape that wraps modules never changes the
  layout. Its size depends on where the modules are, so letting it move
  them would make a binding loop.
- **In Lock Studio** the shape's inspector shows a note when it is a band:
  "The bottom row sits in this band."

## Look format

### JSON

`background.shapes` is a new key: a list of 0 to 4 shapes. The example is
an island that is the media player's background, plus a frame:

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

### Keys, limits and defaults

| Key | Kinds | Values | Default |
|---|---|---|---|
| `kind` | all | `box`, `panel`, `frame` | required |
| `wrap` | box (required), panel | `{ "zones": [1–9 distinct zones] }` or `{ "modules": [1–8 distinct elements] }`, exactly one key | panel: none |
| `edge` | panel (required) | `start`, `end`, `top`, `bottom` | — |
| `pad` | box | `{ "x", "y" }`, both required, integers 0–120 | `{ "x": 24, "y": 16 }` |
| `pad` | panel | integer 0–200 | 32 |
| `stretch` | box | `none`, `across` | `none` |
| `inset` | box (with `across` only), panel | integer 0–64 | box 16, panel 0 |
| `inset` | frame | integer 0–24 (the advice reports a module outside it) | 12 |
| `size` | panel | `{ "min", "max", "fillPast" }`, each optional, each `{ "screen": 0.05–1 }` or `{ "px": 0–4000 }`; `min ≤ max` when both use the same unit | none |
| `radius` | box | integer 0–200, or `"auto"` | 24 |
| `radius` | panel | integer 0–200 | 0 |
| `radius` | frame | integer 0–64 | 22 |
| `fill` | box, panel | `{ "color": glass/surface/black, "opacity": 0–1, "frost": bool }`, each optional | `glass`, 0.6, false |
| `border` | box, panel | `{ "color": glass/accent, "width": 0–4 integer, "sides": all/inner }`, each optional; `inner` only on a panel | `glass`, 1, `all` |
| `absorb` | box, panel | bool | false |
| `style` | frame | `bezel`, `glow`, `line` | `bezel` |

### Validation

Validation is strict, in `backgroundError`, like every other look key.
- **What is rejected:** unknown keys, a key for another kind, wrong types,
  values out of range, duplicate zones or modules, more than 4 shapes,
  more than 2 frosted shapes, `inset` on a box that isn't `across`,
  `sides: "inner"` on a box, and `decor` and `shapes` together.
- **What happens then:** each error names the path, as in
  `background.shapes[1].pad.x must be an integer from 0 to 120`. The look
  is invalid, the last valid look stays, `lookError` is set, and the
  privacy keys are untouched (the existing group rules).
- **Lengths are integers.** That keeps the canonical form exact and the
  Lock Studio steppers honest. Opacities and fractions are numbers, and
  opacity is stored to two decimals by Lock Studio.

### Canonical form

`Layout.canonical` (and `merge`):
- **Each shape:**
  - keys in a fixed order (`kind`, `edge`, `wrap`, `pad`, `stretch`,
    `inset`, `size`, `radius`, `fill`, `border`, `absorb`, `style`);
  - the kind's defaults dropped, inside `fill` and `border` too, and an
    empty `fill` or `border` dropped;
  - `wrap` lists sorted in `ZONES` or `ELEMENTS` order.
- **The list:** order is kept, since it is the drawing order. An empty
  list stays `[]`, because it is how a look removes a preset's shapes.
- **The effective look** always has `background.shapes` and never
  `decor`.
- **Lock Studio's drafts** stay sparse. `Draft.entry` compares
  `background.shapes` as a whole with the preset's, so a look that keeps
  the preset's shapes stores nothing.

### The presets in the new format

The presets are defined with shapes through one helper, `template(name)`.
Lock Studio's "Add shape" menu uses the same templates. Only 9 of the 26
selectable presets have a decoration. The other 17 (`foamy` among them) and
`field-only` get `shapes: []`.

| Template (old kind) | Presets | Shapes |
|---|---|---|
| `split` | split | `{ kind: panel, edge: start, wrap: { zones: [top-start, middle-start, bottom-start] }, pad: 56, size: { min: { screen: 0.38 }, fillPast: { screen: 0.62 } }, fill: { opacity: 0.9 }, border: { color: accent, width: 3, sides: inner } }` |
| `sheet` | sheet | `{ kind: panel, edge: end, wrap: { zones: [top-end, middle-end, bottom-end] }, pad: 44, inset: 24, size: { min: { px: 420 } }, radius: 28, fill: { opacity: 0.55, frost: true } }` |
| `cinema` | cinema | `{ kind: panel, edge: top, wrap: { zones: [top-start, top-center, top-end] }, pad: 26, size: { min: { screen: 0.12 }, max: { screen: 0.4 } }, fill: { color: black, opacity: 1 }, border: { width: 0 } }`, and the same with `edge: bottom` and the bottom row |
| `strip` | dock | `{ kind: box, wrap: { zones: [bottom-start, bottom-center, bottom-end] }, pad: { x: 0, y: 14 }, stretch: across, radius: 20, fill: { opacity: 0.72 } }` (inset 16 is the default) |
| `island` | island | `{ kind: box, wrap: { zones: [top-center] }, pad: { x: 34, y: 12 }, radius: 40, fill: { color: black, opacity: 0.82 } }` |
| `card` | card, rain | `{ kind: box, wrap: { zones: [middle-center] }, pad: { x: 36, y: 36 }, radius: 30, fill: { opacity: 0.5, frost: true } }` |
| `frame` | neon | `{ kind: frame, style: glow }` |
| `frame` | dotmatrix | `{ kind: frame }` (bezel) |

`dock` and `cinema` are bottom bands by the data rule, as they are today
through `BAND_DECORATIONS`.

### Proof that the defaults reproduce every preset

Today's formulas (`Decoration.qml`) set against the general ones, with
`u = uiScale` and `p(n) = round(n·u)`:

| Template | Today | New | Result |
|---|---|---|---|
| island, card | `floor(R.x − p(pad))`, `ceil(R.w + 2p(pad))`; radius `min(h/2, p(40))` and `p(30)` | the same `box` formula and radius rule | exact |
| strip | `x = p(16)`, `w = W − 2p(16)`, `top = floor(R.y − p(14))`, `bottom = min(H − p(16), ceil(R.y + R.h + p(14)))` | `box` + `across`. The added top clamp to `p(16)` is never reached by a bottom-row band. | exact |
| cinema | `min(round(0.4H), max(round(0.12H), ceil(E + p(26))))`, `0.12H` without content | `panel`, inset 0 | exact |
| split | `max(round(0.38W), round(E + 56u))`, full past `0.62W` | `max(round(0.38W), ceil(E + p(56)))` | ±1 px when `E` or `56u` is fractional |
| sheet | `min(W − 2m, max(p(420), round(E − m + 44u)))`, `m = p(24)` | `ceil(E − m + p(44))`, the same min and max | ±1 px, as split |
| frame | inset `p(12)`, radius `p(22)`, glow when the tint is `accent` | the same, with the style named in the preset | exact for neon and dotmatrix |
| colours | `fill(a)`, black 0.82 and 1, the bezel's own near-black, `glassBorder` | `glass`, `black`, the style's own colour, border `glass` | exact |
| borders | 1 px unscaled; split `max(2, round(3u))` | `max(1, round(w·u))` | exact for `u` in 0.82–1.12 |

- **How the proof runs.** Node checks it over a grid of synthetic inputs:
  four screen sizes, compact and not, left to right and right to left,
  empty zones, and fractional rectangles. The reference is a port of
  today's formulas into the test. The harness then compares the rendered
  `surfaces` of every preset at the four test sizes with those of the
  current `Decoration.qml` (`git show` of this commit, as the parity test
  does with 8ad7ccc), within ±1 px.
- **Thumbnails** are regenerated and pixel-diffed. Only split and sheet
  may change, by a pixel.
- **Optional exact rounding.** Making split and sheet exact would mean a
  per-shape rounding rule. That isn't worth a key, but the general formula
  can use `round` instead of `ceil` if the user wants zero drift (then
  cinema drifts instead).

### Old looks with `background.decor`

- **Unreleased.** `decor` has never shipped (`main` is 1.2.0), so only
  development looks and drafts use it. It stays accepted anyway, because
  that costs little.
- **How it is read:**
  - **Accepted:** the string, as before.
  - **Expanded** to `template(name)` in `merge`, after the glass is
    merged, so the expansion can follow the tint exactly as today: `island`
    becomes glass at 0.86 under the `accent` and `solid` tints, and `frame`
    becomes `glow` under `accent`. A saved look therefore draws exactly as
    before.
  - **`"none"`** expands to `[]`.
  - **Both keys** in one look is an error.
- **Never written.** Lock Studio writes `shapes` only; a draft that came
  with `decor` is saved as `shapes` (or as nothing, when it equals the
  preset).
- **Catalog:** version 4. It adds `shapeKinds`, `shapeLimits` (the table
  above, for the inspector) and `templates`, and keeps `backgroundDecor`
  for older clients.
- **Downgrade:** a build without `shapes` refuses such a look with
  `lookError` and keeps the last valid one; nothing unsafe follows.
- **What changes for looks without a stored decoration:** with explicit
  colours, a look that only *changes the tint* of `island`, `neon` or
  `dotmatrix` no longer recolours the island or switches the frame style.
  See open question 1.

## Safety

- **The field is never covered.** All shapes stay in one item under every
  element (as today's `Decoration`, `LockView.qml:780-784`). They have no
  input handlers and take no focus. A render test checks the z-order and
  that a click on a shape still reaches the view's MouseArea.
- **The geometry check doesn't change.** It still judges elements only
  (`Layout.lookGeometryError`). Shapes are not in `geometryKey` and can
  never trigger the fallback, since nothing a shape does can make the field
  unusable. The fallback looks (`foamy`, `field-only`) have no shapes.
- **Advice for Lock Studio, never a fallback.** A new pure
  `Layout.shapeAdvice(look, rects, shapes)` reports:
  - the field or another module straddling a shape's edge;
  - a module outside a frame;
  - frosted shapes overlapping each other;
  - a shape that wraps nothing on this screen.
  Lock Studio's checker shows them as warnings beside its geometry
  problems. The lock ignores them.
- **Legibility:**
  - **Dark fills only.** Fills are theme glass, matching glass or black.
    The accent appears only in borders of up to 4 px and in the frame's
    glow, so text never sits on a light fill.
  - **The field's surface stays.** `absorb` never removes it.
  - **The dim floor holds.** The 0.15 minimum dim behind a field without
    a surface is unchanged.
  - **An absorbed module** is no worse off than with `glass: 0`, which
    the format already allows.
- **Privacy:** a module hidden by `showMedia` or `showUserInfo` isn't shown,
  so a shape around it alone isn't drawn. It never shows an empty pill
  hinting that something is playing.
- **Performance:**
  - **Frost** is GPU only, at most two shapes, each a `ShaderEffectSource`
    limited to its own rectangle plus one `MultiEffect` blur (as today),
    created through a `Loader` gated on `gpuRendering`.
  - **Geometry** is one binding over data the view already computes.
  - **No timers, no animation.**
- **Right to left:**
  - **Logical sides.** `start`, `end` and `inner` are logical.
  - **Zone wraps** follow the mirrored zones; **module wraps** follow the
    drawn rectangles, which are already mirrored.
  - **Frames, boxes and pads** are symmetric.
  - **Test:** the layout suite's `checkMirror` keeps comparing every
    surface, and gains a right-to-left case with an offset, module-wrapped
    shape.
- **Several screens:** each view computes its own shapes from its own
  elements, so a shape around a `screens: "primary"` module appears only
  on the screen that gets the keys.

## Lock Studio

The aim: the old one-click tiles stay the fast path, and every number is
reachable for those who want it.

- **Library → Scene → Shapes** (a new row with the count, "Shapes · 2").
  It replaces the decoration tiles on the Background page, which round 5
  item 5 restructures anyway.
  - **The Shapes page** lists the look's shapes in drawing order:
    - each row has the kind's icon and a summary ("Box around Clock,
      Date");
    - up and down buttons;
    - a remove button.
  - **Add shape** opens the templates as tiles (the existing `StyleArt`
    decoration drawings): Island, Centre card, Side panel, Frosted sheet,
    Bottom strip, Cinema bars (counts as two), Frame, and **Around
    selected module**.
  - **At four shapes** the button is disabled, with a note.
- **The shape inspector** (selecting a row, or clicking a shape on the
  canvas where no module is) shows only what the kind takes:
  - **Wraps:** Zones / Modules (/ Nothing for a panel).
    - **Zones:** the `ZonePicker` in a new multi-select mode.
    - **Modules:** a checklist in `DISPLAY_ORDER`.
  - **Shape:**
    - **box:** padding X and Y (`StepField`, px), corner radius
      (`StudioSlider`, with "Match the module" for `auto` when one module
      with a surface is wrapped), "Full width" with its inset.
    - **panel:** edge (Start / End / Top / Bottom, logical), padding,
      minimum and maximum size (a `StepField` with a %/px switch), "Fill
      the screen past", inset, corner radius.
    - **frame:** style tiles (bezel, glow, line), inset, radius.
  - **Fill:** Glass / Like the modules / Black, opacity (1 % steps: the
    templates use 0.55, 0.72 and 0.82), Frost (with the existing
    "needs GPU rendering" note).
  - **Border:** None / Glass / Accent, width, "Inner edge only" (panel).
  - **"Modules inside use this as their background"** (`absorb`), with
    the note "The password field keeps its own."
- **The module inspector** gains one action: **Wrap in a shape**. It adds
  a box around this module with `pad` 0, `radius: "auto"`,
  `fill: surface` and `absorb`, and selects it. That covers "the island
  around my media player" in one click, and stays aligned however the
  module is moved or scaled afterwards. On a module that is already
  wrapped, it reads **Edit its shape**.
- **On the canvas:**
  - **The shapes are the lock's own drawing** (the canvas is a real
    `LockView`).
  - **The overlay** outlines the selected shape and highlights what it
    wraps (zone cells or module outlines).
  - **No resize handles in this round.** A shape's size comes from what it
    wraps, and handles would fight that. Padding and size are set in the
    inspector.
  - **Keys:** Delete removes the selected shape, Esc deselects.
- **Edits:**
  - **New Draft functions:** `addShape(draft, template, module)`,
    `removeShape`, `moveShape`, `setShape(draft, index, path, value)`.
    Each refuses what the lock would refuse (through `parseLook`), and each
    edit is one undo step; slider drags preview and commit once.
  - **"Keep changes" on another preset** keeps the shapes as a background
    override, as it does today for `decor`.
- **Strings:** new strings in `en` and `no`. The glass hint ("Behind the
  media card, … and the decorations") is updated.

### Acceptance: every built-in preset can be recreated with the tools

- **A node test,** `tests/studio-recreate.test.cjs`. For each selectable
  preset:
  - **Start** from `{ preset: "foamy" }` and derive a **recipe** from the
    target look:
    - only operations from a whitelist that maps each to a real control
      (its objectName, its `Draft` function and its value grid: blur and
      dim in 0.05 steps, opacity 0.01, integer pads);
    - module zones by drops, in an order that produces the preset's
      `order`;
    - shapes by template and then by `setShape`.
  - **Apply** the recipe and require the canonical effective look to equal
    the preset's. The preset name isn't compared, and hidden elements are
    compared only on `hidden`.
  - **New presets** are covered automatically: the recipe is generated,
    not written by hand.
  - **A value off its control's grid fails the test** with the control's
    name. Today it would fail on `sheet`'s `dim: 0.12` (see open question
    3), and on `terminal`'s `black` until round 5's "Solid colour" offers
    black.
- **A harness test,** `studio` suite. It drives the real controls for
  `island`, `cinema` and `sheet` (template, then a parameter change and
  back) and compares the canvas view's `decoration.surfaces` with a
  `previewPreset` view's at the same size: identical.

## Implementation steps

Each step is one or more commits on `feat/layout-engine`. They run after
round 5's UI fixes (item 1 of its order) and before the new animations.

1. **Model (Layout.js):**
   - `SHAPE_KINDS`, `SHAPE_LIMITS`, `ABSORB_STYLES`;
   - `shapeError`, `canonicalShape`, `template`, `legacyShapes(name, tint)`
     and `bottomBand`;
   - the `shapes` key in `BACKGROUND_KEYS`, and `merge` reordered (glass
     before the expansion);
   - `shapeRects` (pure geometry) and `shapeAdvice`.
   - Node tests for every key, limit, message, the canonical form, the
     legacy strings and the geometry proof.
2. **Presets as shapes.** `PRESETS` use `template()`, and `DECORATIONS`
   becomes the legacy list. The catalog moves to version 4. Node: every
   preset is valid and canonical.
3. **Rendering:**
   - **Decoration.qml** becomes a Repeater over `shapeRects`, with the
     box, panel and frame delegates and Frost behind a GPU `Loader` (drawn
     first).
   - **LockView:** the `shapeRects` binding; `placeY` uses `bottomBand`;
     `surfaceShown` goes to the elements.
   - **The elements** expose `surfaceRadius` and honour `surfaceShown`.
   - **`surfaces`** stays the test hook (with the shape index and kind).
4. **Parity and thumbnails:** the old-decoration comparison in the harness,
   thumbnails regenerated deliberately and pixel-diffed for the user.
5. **Safety and placement cases** (see Tests).
6. **Lock Studio:** the Draft functions with node tests; the Shapes page,
   the shape inspector, the multi-select `ZonePicker`, the canvas selection
   and outline, "Wrap in a shape"; i18n.
7. **The acceptance test**, and the fixes it calls for: the dim step or
   the sheet's dim, and the black source with round 5 item 5.
8. **Docs:** the README's `decor` section becomes `shapes` (with the
   templates and the island-around-media example), and Progress is
   recorded here.

## Tests

- **Node:**
  - **`layout.test.cjs`:**
    - parsing and errors for every key;
    - `decor` and `shapes` together;
    - the 4-shape and 2-frost caps;
    - the canonical form (defaults dropped, lists sorted, order kept,
      `[]` kept);
    - the legacy expansion under each tint;
    - `bottomBand` from data;
    - `shapeRects` against the ported old formulas over the input grid
      (exact, ±1 px for split and sheet);
    - companion zones;
    - right to left;
    - `shapeAdvice`.
  - **`studio-draft.test.cjs`:** add, remove, move and set; refusals;
    `entry` sparseness with shapes; `presetKeeping`.
  - **`studio-recreate.test.cjs`:** the acceptance test.
- **Harness `layout`** (every preset, four sizes, primary and secondary,
  right to left):
  - the "wholly inside or outside each surface, inside a frame" rule for
    zone-wrapped shapes and un-offset elements (as today);
  - for module-wrapped shapes, wrapped modules inside and other modules
    not straddling;
  - shapes under every element;
  - frosted shapes drawn first.
- **Harness `placement`:**
  - **Zone wraps:** "decorations ignore offsets" still holds for them.
  - **Module wraps follow:** an offset, a scale of 1.5, media that appears
    and disappears, weather that arrives late, and a `screens: "primary"`
    module on a secondary view.
  - **Absorb:** the media pill alone against the same pill absorbed by a
    zero-padding `surface` box, compared pixel for pixel in a grab, across
    the `none`, `accent` and `solid` tints and `glass` 0.3.
  - **Right to left** for a module-wrapped panel.
  - **The geometry check** is unchanged with any shapes, and a shape never
    causes a fallback.
- **Harness `thumbnails`:** regenerated after step 4. A pixel diff against
  the committed PNGs; only split and sheet may differ, by a pixel.
- **Harness `studio`:** the control-driven recreation of island, cinema
  and sheet; "Wrap in a shape" on the media card; the advice shown in the
  checker.
- **Manual (GPU, on this desktop, after the user's go):** frost on sheet
  and card templates, two frosted shapes, frost over a playing video
  wallpaper, the neon glow, and a real lock with the island around the
  media card.

## Risks

- **More knobs, more ugly combinations.** For example, an across box
  around the middle row covering half the screen. Limits, templates and
  Lock Studio's advice keep it manageable; nothing a shape does can affect
  unlocking.
- **±1 px drift** for split and sheet. Tolerated by the parity test,
  visible only in a pixel diff; or exact rounding, at cinema's expense.
- **Frost and video.** Frost samples the wallpaper `Image`, which is hidden
  while a clip plays. Whether a hidden item still renders into the
  `ShaderEffectSource` must be checked on the GPU. If it doesn't, frost
  samples the video item instead, or shows the poster.
- **Binding loops.** Shapes read element geometry. Elements read only
  data-derived shape facts (`bottomBand`, which modules are absorbed), never
  shape geometry. A test cycles every preset and template with QML's
  binding-loop warnings counted as failures.
- **Scope.** This touches Layout.js, Decoration.qml, LockView, five
  elements and Lock Studio. Round 5 item 5 (the background page) and item 6
  (the presets pass) overlap; this note assumes item 5's page structure and
  leaves preset changes to item 6.

## Self-review (fresh eye)

Gaps found on a second read, and how the note now handles them:
- **A data-only band rule.** The bottom band could have been inferred from
  geometry, which would loop. It is now data only, and module wraps never
  change the layout.
- **Overlapping frost** would punch holes; frosted shapes are now drawn
  first and capped at two.
- **Shapes have no `screens` key.** Module wraps inherit their modules'
  screens; zone shapes and panels show on every screen, as today. A
  `screens` key can come later if asked for.
- **Lock Studio's drops create offsets** (cause 2). Fixing only the
  island's padding wouldn't have helped; following drawn rectangles in
  module mode is what does.
- **The acceptance test reaches outside decorations:** slider grids,
  element order and the black source. Those gaps are listed, not hidden.
- **A legacy `decor` with a changed tint** had to stay exact: the
  expansion follows the tint at merge time.
- **The password field** is excluded from `absorb` and keeps its glass
  floor; that is stated in the format, not left to the UI.

## Open questions

1. **Tint and the island and frame.** Should a shape's colours be its own,
   as proposed (the island stays black and the frame keeps its style when
   the glass tint changes)? Or should the island and frame keep following
   the tint, as today, through an `auto` value?
2. **Offsets and zone shapes.** Proposed: zone-wrapped shapes keep
   ignoring offsets (today's rule, which keeps the presets stable), and
   module-wrapped shapes follow them. Or should every shape follow the
   drawn rectangles?
3. **The sheet's dim of 0.12** can't be set with the 5 % dim slider.
   Change the preset to 0.10 in the presets pass (proposed), or give the
   slider 1 % steps?
4. **Limits and handles.** Are 4 shapes (2 frosted), and no resize
   handles on the canvas in this round, enough?

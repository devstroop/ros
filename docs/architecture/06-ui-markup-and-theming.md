# UI markup and theming

> **Status:** Implemented subset — 9 templates render (6 in the shell, 3 as
> session gates). Theming is implemented (light/dark).
> **Last verified:** 2026-10-20, by source review.
> **Source:** `src/app.native`, `src/screens/*.native`, `src/app_sources.zig`,
> `src/core/theme.zig`, `src/core/model.zig`.

## The view is markup

There is no widget tree built in Zig. `app.native` declares the shell, and
each screen is a `<template>` in `src/screens/`. The runtime parses the
markup, resolves bindings against the model, and builds widgets. The app
never calls a paint API.

Consequences:

- A screen is data plus a template, not a class.
- Bindings are zero-argument reads. Reactivity is "the model changed, so
  rebuild".
- There is no place to put imperative UI code, which is the point.

## File layout and imports

```
app.native                 shell + top-level gates
screens/screen-*.native    one <template> per screen
app_sources.zig            embedded import closure
```

`app.native` imports each screen:

```xml
<import src="screens/screen-role-picker.native"/>
...
```

Every imported file must also be listed in `app_sources.zig`. The compiler
enforces this, and hot reload re-resolves the same paths from disk. A
missing entry fails loudly at the import site, which is intentional: a
screen that is not compiled in is a screen that does not exist.

`app.native` is embedded with `@embedFile` and watched at
`src/app.native` for hot reload.

## Shell structure

```
column
├── row            title bar: company, role badge, theme toggle
├── if has_error     error banner: message + Dismiss
├── if !role_chosen   → screen-role-picker
├── if role_chosen && !signed_in → screen-login
├── if signed_in
│   └── split      rail (200px) | content
│       ├── column  nav rail: sections
│       └── column  content: <if screen_index == N> gates
└── status-bar     screen title | company | operator
```

Only the active screen is mounted. That is what keeps the 1024-node
budget reachable.

The content gates are hard-coded ordinals:

| Index | Screen | Template |
|---|---|---|
| 8 | `admin_dashboard` | `screen-dashboard` |
| 10 | `pos` | `screen-pos` |
| 13 | `orders` | `screen-orders` |
| 17 | `dining_tables` | `screen-tables` |
| 41 | `kds_board` | `screen-kitchen` |

The other 36 screens render an empty pane. See
[03-navigation-and-rbac](03-navigation-and-rbac.md).

## Markup vocabulary used

The app uses a small, conservative subset:

| Purpose | Elements |
|---|---|
| Layout | `column`, `row`, `split`, `scroll`, `grid`, `spacer` |
| Surfaces | `card` (stacking), `separator` |
| Text | `text` (with `size`, `foreground`, `wrap`, `grow`) |
| Controls | `button`, `toggle-button`, `search-field`, `text-field` |
| Data display | `badge`, `for` |
| Structure | `if`, `template`, `use`, `import` |
| Chrome | `status-bar` |

Not yet used: `table`, `timeline`, `chart`, `stepper`, `dialog`, `sheet`,
`select`, `virtualized`, `drag`, `tooltip`, `avatar`, `image`.

## Grammar rules that shape the code

These come from the SDK and are non-negotiable:

1. **Expressions are a closed language.** Binding paths, numbers, quoted
   strings, `+ - * /`, comparisons, `and/or/not`, `++`, and 17 functions
   (`fixed`, `thousands`, `percent`, `date`, `time`, `datetime`, `upper`,
   `lower`, `trim`, `min`, `max`, `abs`, `round`, `floor`, `ceil`,
   `plural`, `pad`).
2. **No method calls in markup.** A row cannot call `row.label()`; labels
   are fields resolved at decode time.
3. **No negation operator, no ternary, no else-if.** Every conditional is
   an `<if>`; the inverse is a second `<if>`.
4. **Colours and radii are token names only.** No hex literals.
   `border-color`, not `border`.
5. **One size register per row.** Mixing `size="sm"` with default
   controls produces two heights.
6. **Stacking containers reject `gap`.** `card`, `stack`, `panel`,
   `dialog`, `sheet`, `drawer`, `alert`, `bubble`, `resizable`. Wrap
   children in a `column`.
7. **`split` takes exactly two children.** `gap` is divider thickness.
8. **Interactive controls need an accessible name.** Text, `text=` or
   `label=` is required.
9. **`<else>` must directly follow `<if>`.**
10. **Widget budget per view:** 1024 retained nodes, 64 KiB text, 512
    context-menu items, 16 floating surfaces, 2048 commands / 8192 glyphs
    per frame.
11. **The shell's import closure holds thirty-two files.** The limit is
    on FILES, not on templates: one file may hold several templates, so
    a screen that shares a file with its neighbours costs nothing. The
    app is at the ceiling, and the two settings forms share one file
    because of it.

## Binding patterns

### Derived values

```xml
<text size="display">{open_order_count}</text>
```

`open_order_count` is a method on `Model`, not a stored count.

### Filtered rows

```xml
<for each="visible_products" key="id" as="product">
  <card on-press="add_to_cart:{product.id}">
    <text wrap="true">{product.name}</text>
    <text size="sm">{currency_symbol}{fixed(product.price_minor / 100, 2)}</text>
  </card>
</for>
```

`visible_products(arena)` applies the category and search filters. The
markup never filters.

### Dispatch with a payload

```xml
<button on-press="pick_role:{role.id}">Open</button>
<button on-press="advance_order:{ticket.id}">Next</button>
```

A payload must be a binding. A literal must become its own message
(`set_category_all`).

### Conditional sections

```xml
<if test="{cart_is_empty}"><text>The cart is empty.</text></if>
<scroll grow="1"><!-- list --></scroll>
```

There is no else-if; each branch is its own `<if>`.

## Theming

`src/core/theme.zig` supplies `canvas.DesignTokens` on every rebuild:

```zig
pub fn tokens(model: *const Model) DesignTokens {
    const chosen = model.theme_palette;
    if (!model.theme_contrast_high) return register(chosen);
    return withColors(highContrast(register(chosen).colors, chosen.is_dark()));
}
```

`toggle_theme` hops between the halves of the day - Light for a dark
register, Dark for a light one - and Settings' Appearance card sets
`theme_palette` directly and `theme_contrast_high` beside it. Both are
model state, so a theme change is a message, a field and a rebuild - and
a write: `repos.saveTheme` keeps the pair in `app_config`, `loadTheme`
reads it back at boot, and a device wakes in the look it was left in.

### Brand palette

| Name | Value | Use |
|---|---|---|
| Primary | `#176B84` | Accent, focus ring |
| Success | `#1B6E47` | Success text/status |
| Warning | `#87520C` | Warning |
| Danger | `#B32D22` | Destructive |
| Info | `#2F5EC2` | Info |

The light semantic fills are the darkest step of the v1 hues that clears
WCAG AA with white text, and as text on the light background and surface
(`tests.zig` asserts every text pair in all eight palettes - four
registers, each standard and high contrast - and again with each of six
brands worn).

### The restaurant's own colour

A brand is data, not a stylesheet. `company.brand_color` holds `#rrggbb`
or nothing, the owner types it into Settings → Company, and the theme
reads it through the same parser the form validates with
(`core.parseBrand`), so the two can never disagree about what counts as
a colour.

The brand replaces exactly three tokens - `accent`, `accent_text` and
`focus_ring` - because those are the three that mean "this restaurant".
The danger red and the success green mean "this void is permanent" and
"this ticket is ready", and a logo colour does not get to redefine them.

A colour that already clears four and a half against the register's
surfaces, and against the label it can carry, is used exactly as it was
typed. One that does not is walked toward the extreme its register has
room for - lighter on a dark ground, darker on a light one - which keeps
the hue and moves only its strength. The accent has two jobs, so it is
held to both: it is the ground a button's label sits on, and it is the
ink the markup paints prices with.

An empty field is the honest "this restaurant has no colour yet", and
the register's own accent stands. The brand is applied *before* the
high-contrast derivation, so the setting that is about the eyes pushes
the brand the same way it pushes the house accent.

### Semantic tokens in use

Light and Dark, the two registers the house hues drive:

| Token | Light | Dark |
|---|---|---|
| `background` | `#F7F8FA` | `#0F1318` |
| `surface` | `#FFFFFF` | `#171C23` |
| `surface_subtle` | `#F1F3F6` | `#1F262E` |
| `surface_pressed` | `#E6EAEF` | `#272F38` |
| `text` | `#151A21` | `#ECEFF3` |
| `text_muted` | `#646E7A` | `#9AA5B1` |
| `border` | `#E1E5EA` | `#2A333D` |
| `accent` | `#176B84` | `#4CC2EA` |
| `destructive` | `#B32D22` | `#E85D51` |
| `success` | `#1B6E47` | `#45B886` |
| `warning` | `#87520C` | `#E09A3C` |
| `info` | `#2F5EC2` | `#5B8CE0` |

Warm (a laminated-menu paper for a dining-room tablet) and Night (a
kitchen display at 3am) carry their own hues, because a cyan that clears
AA on white rarely clears it on a near-black ground. The full four-register
value table and the high-contrast derivation are in
[ui-components.md](ui-components.md).

### Type, spacing, radius

| Scale | Values |
|---|---|
| Type | body 14, label 13, title 20, heading 28, display 48, button 14 |
| Spacing | xs 4, sm 8, md 12, lg 16, xl 24 |
| Radius | none 0, sm 4, md 8, lg 12, xl 16 |

The v1 app had 14 type rungs, 11 menu-tile colours and an 8-step spacing
scale. Restaurant OS keeps 6/5/5. The lost colour range is a deliberate trade-off;
see [ADR-0010](../decisions/0010-markup-only-no-custom-paint.md) and the
open question about brand fidelity.

### Theme limitations

- There is no way to supply an arbitrary 40-colour palette. The runtime
  resolves semantic tokens and an accent override.
- A colour cannot travel as data: `background=` and `foreground=` take
  a token *name*, as a literal. A state that carries its own colour is
  picked by an `<if>` chain over the ordinal the row already stores,
  which is what `screens/parts.native` does for a ticket.
- A `badge` ignores both attributes - its colours come from the theme's
  badge table - so a count reads as a badge and a state as a chip.
  The dining grid has no `<if>` chain yet and shows its table status as
  a badge label.
- The four registers are written out; only the high-contrast form is
  derived. A new semantic token means editing four `colors` blocks, and
  the contrast test is what catches the one that was missed.

## Layout patterns

| Pattern | Where | Notes |
|---|---|---|
| Rail + content | Shell | `split` with a model-owned fraction (0.18 default) |
| Menu + cart | POS | Inner `split` with `menu_split` (0.62 default) |
| Card grid | POS, tables, KDS | `grid columns="3"` or `"4"` inside `scroll` |
| Summary strip | Dashboard | Four `card`s in a `row`, each `grow="1"` |
| Empty state | Orders, KDS, tables, cart | `<if count == 0>` + muted text |

There is no responsive variant yet. The shell assumes a desktop window
(1280×800 default, 960×600 minimum in `app.json`).

## Accessibility

- Shell and canvas carry accessibility labels ("Restaurant OS").
- Icon-only buttons must carry `label=`; the SDK rejects unnamed
  interactive controls.
- Text is real text, so the OS can read it; there is no canvas-drawn copy.
- Focus order follows declaration order. The POS search field is not
  autofocused; login's PIN field is.
- Colour is never the only status signal: a chip or a badge carries the
  word as well, and both are real text.
- Every register's text pairs are asserted against WCAG AA in
  `src/tests.zig`, including the six state chips; a keyboard-only pass
  and focus-visible checks remain.

## Adding a screen: checklist

1. Add the `Screen` variant at the **end** of the enum in
   `core/navigation.zig`; add a title and a nav section.
2. Add it to `rbac.allows` for the roles that may open it, and decide
   `rbac.section_screen` if it is a rail landing.
3. Write `screens/screen-<name>.native` with exactly one
   `<template name="screen-<name>">`.
4. Import it in `app.native` and add the file to `app_sources.zig`.
5. Add an `<if test="{screen_index == N}">` gate in the shell, using the
   enum's ordinal.
6. Add model fields and derived methods; add `Msg` variants for every
   interaction. Keep private fields in `view_unbound`.
7. Keep the template under 1024 nodes; use `scroll`/`grid` and plan for
   virtualization on long lists.
8. Add a test that builds the tree and finds a landmark text.
9. Update `docs/architecture/03`, `06` and `plan/status.md`.

## Current templates

| Template | Screen | State |
|---|---|---|
| `screen-role-picker` | 0 | Implemented |
| `screen-login` | 1 | Implemented |
| `screen-dashboard` | 8 | Implemented |
| `screen-pos` | 10 | Implemented |
| `screen-orders` | 13 | Implemented |
| `screen-tables` | 17 | Implemented |
| `screen-kitchen` | 41 | Implemented |

No reusable components exist in `src/components/`, although the directory
is present. The target is ~24 component templates (button/card/empty
state/order card/product card/timeline/adaptive shell/etc.); today the
patterns are repeated inline.

## Known weak points

1. **Index-gated shell.** Hard-coded ordinals in markup are brittle; a test
   should assert them, or the shell should switch on a model method.
2. **No virtualization.** A 200-order list renders every row; the node
   budget will fail before the data does.
3. **No component library.** Duplication across templates is already
   visible (empty states, headers, rows).
4. **No responsive mode.** Window resize changes the split fraction only.
5. **No motion.** There are no transitions or tweened values.
6. **Contrast is tested for the token pairs, not the composition.** Every
   register's text pairs are asserted, and so are the accent's two jobs -
   as a label's ground and as ink - with each of six brands. What is not
   audited is a real screen: two tokens touching each other, a chip on a
   wash, a screenshot nobody has looked at.

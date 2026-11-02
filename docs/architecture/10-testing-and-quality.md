# Testing and quality

> **Status:** Healthy — `scripts/verify-all.sh` is green: admin
> **213/213** (67 handwritten rules, 145 against a migrated database, and
> one test block that imports both), service **10/10**, kiosk **8/8**,
> `ros-core` **43/43**, net-spike **13/13**. CI adds a headless paint
> check per app and the sale walkthrough. Still uncovered: the clock
> tick's own arithmetic, a salt race between two first boots, resizes
> below the minimum, and the Flutter interop.
> **Last verified:** 2026-10-31, by running `scripts/verify-all.sh` on
> Linux.
> **Source:** `apps/*/src/tests*.zig`, `packages/ros-core/src`,
> `scripts/verify-all.sh`, `scripts/smoke-sale.sh`,
> `.github/workflows/ci.yml`.

## Philosophy

The architecture exists partly to make testing cheap:

- `update` is pure, so a test dispatches a message and asserts on the
  model;
- effects have a fake executor, so a test can observe requests without a
  database or a clock;
- markup is built from a model, so a test can assert that a landmark
  appears in the tree;
- the database has an in-memory migrated mode, so repository tests need no
  file.

A rule that lives only in a comment is a rule that breaks. The tests in
`src/tests.zig` are written as rules, not as coverage for its own sake.

## Current tests

`native test apps/admin` reports **213** for the admin target - 67 in
`tests.zig`, 145 in `tests_data.zig`, one generated - and the service and
kiosk targets add 10 and 8 of their own. The table below is the subset
this page names, not the whole list.

| # | Test | What it pins |
|---|---|---|
| 1 | The picker is the first screen and lists the device modes | Initial model and first render |
| 2 | Picking a person opens the sign-in surface that is theirs | Session gate and credential kind |
| 3 | Picking a board signs the device in and opens it | Kiosk path |
| 4 | A role cannot open a screen it may not use | RBAC guard |
| 5 | The permission matrix is total: every role against every screen | Lock-out guarantees |
| 6 | Going back returns to the previous screen | Stack |
| 7 | The cart adds, counts and totals in minor units | Cart arithmetic |
| 8 | Money stays integer | No float money |
| 9 | A PIN is hashed, never stored | Salt and hashing |
| 10 | The page decoder reads the engine's dialect | Wire format |
| 11 | The model reports its own numbers instead of storing them | Derived values |
| 12 | The setup screen renders on a fresh installation | Setup gate and template |
| 13 | The POS screen renders with a menu and a cart | POS template |
| 14 | The order confirmation screen renders after a sale | Confirmation template |
| 15 | The layout survives a resize | Markup build + layout at 1280×800 |
| 16 | The secret shows as bullets, and the eye opens it | Masking, and that the view never sees the value |
| 17 | The pad taps a PIN one digit at a time | The numeric surface, its length guard |
| 18 | The database, not an old list, decides which surface the till offers | The kind is the row's, and a mismatch costs nothing |
| 19 | A wrong try is counted once | The lockout arithmetic, against a query's terminal result |
| 20 | A price is read in the currency the till actually trades in | Money decimals come from the company; a finer fraction is refused, not rounded |
| 21 | A tax slab is saved, and the rate the owner typed is the rate stored | A rate keeps the hundred of the percent, one fraction digit included |

How they run:

```
native test apps/admin --yes
```

The test block in `main.zig` imports `tests.zig` and `tests_data.zig`.
Markup tests resolve the same import closure as the runtime, then build
and finalize a tree, so a broken template fails a unit test with a
line/column diagnostic.

The fake effects channel is `Effects.init(allocator)` with
`fx.executor = .fake`. It records requests; it does not answer them. A test
that needs a DB result must construct one by hand (as the page decoder test
does) or bind an in-memory store.

## What is not tested

| Area | Risk |
|---|---|
| The clock tick's arithmetic | `tick` only feeds the board's "waiting" text and has no unit test; the kiosk's two-second board re-read is exercised by the sale walkthrough, not by a headless test |
| A salt race between two first boots | Two fresh terminals writing at once is unproven; one boot, a second instance adopting the stored salt, a legacy digest waiting for confirmation, and a failed write are all tested |
| Theme switch | The walkthrough presses the control, asserts the chosen state each register button reports and the canvas's own centre pixel, and keeps a screenshot of every register; every text pair in all eight palettes - four registers, each standard and high contrast - clears its threshold in `src/tests.zig`, and Settings is pinned to offer every register the enum has. The choice is kept: the DB test writes it, boots a second model and reads it back, and shows that a read landing after a tap does not undo it. The restaurant's own colour is asserted the same way from both ends - the form refuses a hash it cannot read and the pair survives, the value comes back out of the database and into the reference document a peer applies, and the eight palettes each wear six brands through the accent's four pairs. A brand the register cannot carry is proved to be pushed rather than replaced: the order of its channels is the hue, and that order is what the test holds. No test compares the registers field by field, and no test screenshots a branded canvas, because the pixel the walkthrough can read is the canvas's centre, which is a card and not a button |
| Accessibility names | Visible labels are enforced by `expectVisibleLabels`; accessible names are left to SDK validation |
| Window resize below minimum | "The layout survives a resize" covers 1280×800; the clamp below the minimum is untested |
| Two binaries on two machines | The socket is in the app now, so `apps/net-spike` and the admin's net tests cover the seam, and the walkthrough hands the admin's database to the kiosk on one host. A till and a kitchen display on separate machines, converging over a real LAN, is not run anywhere |

## Test layers

| Layer | Tool | Scope | Status |
|---|---|---|---|
| Pure update | `native test` | Model transitions, RBAC, cart, status machine, the sign-in | Covered |
| Markup build | `native test` | Every screen builds for its fixture and stays inside the widget budget | Covered |
| Page decoder | `native test` | The page dialect and every repository load | Covered |
| Relational integration | `native test` + `openMemoryMigrated` | Migrate, insert fixtures, run repo SQL, assert rows | Covered — 145 tests |
| Business calculations | `native test` | Tax, discounts, cash tenders and change | Covered |
| Split payment | — | One bill paid by more than one tender | Not a feature yet |
| Live automation | `native automate` | Role picker → sign-in → sale → KDS advance, node budget, non-blank GPU | In CI (`smoke`, `sale-smoke`) |
| Interop | External harness | Flutter app and native app converge on sync | Planned |

### Relational test recipe

```zig
var db = try native_sdk.relational_store.Database.openMemoryMigrated(
    testing.allocator,
    migrations,
);
defer db.deinit();

var fx = Effects.init(testing.allocator);
// The real executor: these tests exist to run SQL.
fx.bindRelationalStore(db.binding());

// seed, then drive fx.dbExec / fx.dbQuery exactly as the app does
```

This is how `saveOrder` is proven: "an order is written, read back, and
its status advances" executes the write and queries both tables back;
"a failed sale does not consume an order number" points the cart at a
product the database does not carry, forces the line's foreign key to
fail, and shows the order and the sequence stayed put. The retry tests
add the harder case: a sale written twice is still one sale, and its
stock is taken once.

### Automation smoke

Two jobs drive a live app headlessly. `smoke` proves each binary paints:

```
native build -Dautomation=true
# run under xvfb
native automate assert 'gpu_nonblank=true'
native automate screenshot <view>
native automate assert 'widget_nodes=<n>/1024'
```

One pixel on a canvas is not a sale, so `sale-smoke` runs
`scripts/smoke-sale.sh`, which walks setup → sign out → the pad → the
picker → POS → add a dish → Place order → Orders → the four registers and the
restaurant's own colour, then resets the owner to a password and signs in
through the masked field, then hands the database the admin wrote to the
kiosk and asserts the same ticket on the kitchen board and advances it.
Every step is an `automate assert` against the snapshot, so a shell gate
pointing at the wrong ordinal fails the run rather than rendering
something plausible.

Three things the script has to survive:

- **Stale widget ids.** A view that refreshes on a timer rebuilds its tree,
  and an id read from one snapshot can be retired before the click carrying
  it arrives. Every press is repeated until the screen it expects actually
  appears; the app's own guards — a sale still being saved, an order
  already moving — make a repeated press safe instead of a second sale.
- **Keystrokes, which move no screen.** A dropped press shows up as the
  next assertion failing; a dropped `set_text` shows up twenty steps later
  as an order with no name on it. The host answers a stale id with
  `delivered` and discards the command, so the only proof a field took its
  value is the `text="…"` the snapshot publishes back — and typing is
  repeated until that reading matches what was asked for.
- **Names, not positions.** A widget is found by role and accessible name,
  matched literally, so a price carrying `$` is never read as a regex. The
  settings rows press as cards, which the tree publishes unnamed: the word
  that says which row it is sits on the title inside, so the script presses
  the title and the card takes it.

The same path exists as a headless test, "a sale at the till shows on the
orders board and the kitchen board", driven against a real migrated
database. The test proves the state machine; the job proves the binaries
and the screens an operator actually sees.

## CI

`.github/workflows/ci.yml` has four jobs:

1. **verify** — installs the pinned Zig 0.16.0 and Node 24, builds or
   restores the SDK CLI, then runs `scripts/verify-all.sh`
   (`native check` + `native test`).
2. **smoke** — one matrix leg per app: builds with `-Dautomation=true`,
   runs under `xvfb`, and asserts `gpu_nonblank=true` plus a screenshot.
3. **sale-smoke** — runs `scripts/smoke-sale.sh` end to end and uploads the
   screens and app logs as an artifact, so a run that dies three screens
   into the walk is still diagnosable from the runner.
4. **package** — packages the three macOS apps with ad-hoc signing and
   checks the artifacts without rebuilding; a release supplies the
   Developer ID and notarisation profile.

Pinning matters: Zig 0.17 cannot parse the SDK, and Node 22 fails the
relational toolchain. A CI runner that "looks fine" will fail at step 1.

## Quality gates before a release

| Gate | Required |
|---|---|
| `native check` clean | Yes |
| `native test` green | Yes |
| Every `Screen` either rendered or explicitly unavailable | Yes |
| Node budget asserted for POS and orders | Yes |
| Order write/read-back test | Yes |
| Migration test on a copy of a real database | Yes |
| Receipt print on target hardware | Yes, if printing ships |
| Two-device sync convergence | Yes, if sync ships |
| Keyboard-only pass on POS and login | Yes |
| Contrast audit, every register in both contrasts | Yes |
| Crash-free 30-minute service run | Yes |

## Known testing hazards

1. **Markup tests are brittle to copy changes.** They find literal text
   ("Restaurant OS", "Sign in"). Changing display copy breaks tests; that is
   usually the right trade, but keep landmarks stable.
2. **Fake effects do not answer.** A test that expects a follow-up message
   must synthesize the result.
3. **The model is large.** Tests allocate it on the stack in some places;
   `UiApp.create` exists because that is risky in production.
4. **Line numbers in docs drift.** Anchor on symbols in tests and docs.
5. **No test covers the screen-index contract.** The most likely
   regression in this codebase is a new screen inserted in the middle of
   the enum, which silently remaps every gate in `app.native`. Add a test
   that asserts the ordinal of every rendered screen, or generate the
   gates.

# As-built status

> **Status:** Snapshot. Regenerate by reading the source, not by trusting
> this page. The detailed counts below describe the admin app; the
> service and kiosk mount their role's subsets of the same core.
> **Last verified:** 2026-11-03, by source review and the split suites.
> `scripts/verify-all.sh` is green for ros-core, admin, kiosk, net-spike
> and service; the suites are admin 225/225, kiosk 8/8, net-spike 13/13,
> service 10/10 and ros-core 46/46.
> `native build` produces ReleaseFast binaries.
> `scripts/package.sh --ci` and `--check` produce and verify three macOS
> DMGs; the CI package job runs both. The artifacts are ad-hoc signed
> until the release credentials are configured.
> The money and back-office tracks are merged. The three apps share
> `packages/ros-core`; the session and setup screens are copied into
> each app by the package split. The screens the roadmap's phase two
> names are built.
> See the [full audit](../review/archive/2026-10-20-audit.md).
> **Screen-by-screen table:** [`architecture/03`](../architecture/03-navigation-and-rbac.md#the-53-screens).

## Scoreboard

| Measure | Value | Evidence |
|---|---|---|
| `Screen` variants | 53 | `packages/ros-core/src/core/navigation.zig` |
| Screen templates | 53 in the admin app | `apps/admin/src/screens/*.native` (ten area files); the service and kiosk copies carry their subsets |
| Templates mounted in the shell | 53 in the admin (46 on the screen ordinal, seven session screens on their own condition); the service and kiosk mount their role's subset | `apps/{admin,service,kiosk}/src/app.native` |
| Screens that render at all | 53 in the admin | every mounted template builds; a test asserts it |
| Templates with a render test | 53 in the admin | `apps/admin/src/tests.zig` (the screen-coverage test builds each one, and finds a landmark of its own) |
| `Msg` variants | 223 | `packages/ros-core/src/core/msg.zig` |
| Tables | 46 | `apps/admin/src/schema/*.sql` |
| Migrations | 20 | `apps/admin/src/schema/migrations.lock.json` version 20 |
| Read queries | 34 named constants | `packages/ros-core/src/data/repos.zig` (one named constant each, and one place that says the app is loading) |
| Write paths | setup, order + lines, status + history, config, currency, product, employee, employee credential (hash and kind), employee removal, customer, category, tax slab, discount, modifier group, dish station, stock count, payment, op log, reference version, log compaction, snapshot apply, pairing token (seeded once, then rotated) | `repos.zig` |
| Effect keys | 71, each used once | `packages/ros-core/src/data/repos.zig`; a test asserts the uniqueness |
| Headless tests | admin 225/225, kiosk 8/8, net-spike 13/13, service 10/10, ros-core 46/46; every target green | `apps/*/src/tests*.zig`, `packages/*`, `scripts/verify-all.sh` |
| Database integration tests | 150, green | `apps/admin/src/tests_data.zig` |
| Sidecar binaries | 0 | `tools/*` contain READMEs only |
| CI workflows | 1 (verify, smoke, package) | `.github/workflows/ci.yml` |
| Reusable component templates | 0 | `src/components/` empty |

## Subsystems

| Subsystem | Status | Notes |
|---|---|---|
| Build and manifest | Partial | Three `app.json` manifests, scripts, CI and the macOS package job exist; Developer ID/notarisation and the clean-machine proof remain |
| App model | Implemented | Model, Msg, update, boot, effects keys |
| Role picker and login | Partial | bcrypt credential hashes, kiosk sign-in and the admin's first-run setup exist; the sign-in checks the employee's stored role (B-002) and waits for the database to confirm the salt (B-003). A service or kiosk waits for the admin's reference data instead of setting up. A person signs in as themselves on the picker, and their row decides whether the till offers the numeric pad or a masked password field with an eye; neither shows the secret (B-027, #96, [ADR-0022](../decisions/0022-a-person-chooses-how-they-sign-in.md)) |
| RBAC and navigation | Implemented core | 53 screens, 4 roles, one guard, a session-scoped stack ([ADR-0015](../decisions/0015-session-scoped-navigation.md)). The waiter opens the counter POS (`pos`, `pos_cart`, `payments`); the admin app remains the wildcard superset ([ADR-0021](../decisions/0021-counter-pos-is-the-service-app.md)) |
| Screen coverage | Implemented | 53 screens in the admin app; every one is mounted, renders, and has a landmark of its own. The seven session screens are mounted on their own condition, the other forty-six on their ordinal gate. The service and kiosk mount their role's subset |
| Theming | Implemented | Four registers - light, dark, warm, night - and a high-contrast derivation of whichever one is chosen, kept on the device in `app_config`; the restaurant's own `#rrggbb` drives the accent, the label on it and the focus ring. Every text pair is asserted against WCAG AA, in all eight palettes |
| Shell layout | Partial | Fixed rail + content, no responsive mode, but the chrome is the same in all three apps by gate: `scripts/check-copies.sh` compares everything from the shell's opening element to the content pane plus the status bar, and only the pane's own gates may differ. The shell says "Loading..." while a read is on its way, and a failed read replaces the screen with the reason and a way to try again |
| Dashboard | Implemented | Counts, recent orders, shortcuts; amounts use the company's currency decimals |
| POS | Partial | Menu, filter, cart, order types and discounts work; the order write succeeds; a sale happens once, the number is a sequence and a retry is the same sale; the tax is worked out line by line from each product's slab. The service app mounts the counter POS as well as the admin app ([ADR-0021](../decisions/0021-counter-pos-is-the-service-app.md)). No modifiers; the price parser is still two-decimal (#66) |
| Orders | Partial | Lists non-voided orders including completed; status advance is conditional (D19); the header badge still disagrees with the list (D5, #7) |
| Kitchen board | Implemented | Tickets, summary, wait time, advance |
| Floor board | Partial | The table board shows what is true about each table; a guest cannot be moved to another table |
| Customers | Partial | The list, the count, the load and the form all work - a customer can be written and edited. A customer still cannot be attached to an order, so the loyalty points are only ever earned by hand |
| Employees | Partial | The list and the form work; how a person signs in can be reset by a manager - the same form chooses PIN or password and writes the new hash, so the old sign-in stops working the moment it is saved - and an employee who has left can be removed: the row stays, so the orders they took still name them, and the last admin cannot be removed |
| Catalog admin | Partial | The catalogue list, the product form, the categories, the tax slabs, the discounts and the modifier groups all work. The CHOICES inside a modifier group, and which dishes a group applies to, do not |
| Settings / setup | Partial | The admin's first run is the walk-through: the company's record, then the owner and the credential they choose - a PIN or a password - written in one transaction with the starter menu, the salt and six tables. The quick setup stays for an owner who wants to start serving sooner. A service or kiosk that starts first waits for the admin's reference data and cannot set up a second restaurant |
| Payments | Partial | Cash/card/UPI mode, confirmation and one payment write; a payment is taken once, and an order can still be closed without one. The service app takes payments too: the waiter's device owns the op and the order's status transition makes a retry the same sale ([ADR-0021](../decisions/0021-counter-pos-is-the-service-app.md)) |
| Reports / compliance | Partial | The owner's read of the day exists: the takings, the orders, the tax, the discounts, and the way the money was paid. The X report, the Z report and the day close are the reports track's |
| Printing | Scaffolded | Tables and README-only sidecar; no code |
| Sync | Implemented core | Op log in the same transaction, per-device Lamport clock and vector cursor, beacon or manual peers, reference snapshot. The push stream (#110) is implemented: a held-open `/v1/events` line wakes the peer's pull, with the five-second poll as the fallback. Cross-device order identity (#87) is implemented: `orders.id` is the local row key, `(origin_device, origin_id)` is the stable name, remote orders get negative local ids, and status/payment ops carry the origin. Late join/compaction (#111) is implemented: `/v1/ops` is served from the durable log with a vector cursor, a 128-op trigger compacts to `sync_snapshot_op`, a cursor below the floor gets 409 and bootstraps from `/v1/snapshot`, and the header clocks are adopted after the last page |
| Push / events | Implemented | `/v1/events` held open, chunked NDJSON, one thread per stream, 20ms wake, 15s heartbeat; one stream per peer, line-triggered pull, pending-pull follow-up, terminal reopen; 5s poll fallback |
| Display board | Partial | The board renders and shows the order cards |
| Waiter shell | Partial | The floor, the menu, the cart, the order list, the counter POS and payments render; the tables screen has "Counter sale" and "Payments" entry points |
| Testing | Partial | The split suites are green via `scripts/verify-all.sh` (admin 213/213, kiosk 8/8, net-spike 13/13, service 10/10, ros-core 43/43); each app walks its shell against the permission matrix; `scripts/smoke-sale.sh` walks the sale, the four registers, the restaurant colour and the kitchen board headlessly (#42) |
| Packaging | Partial | `scripts/package.sh` builds three macOS DMGs, injects each app's `NSLocalNetworkUsageDescription`, signs ad-hoc by default (Developer ID + notarisation through `ROS_SIGNING_IDENTITY` / `ROS_NOTARY_PROFILE`), and verifies the checksums and the app inside each DMG. CI's **Package (macOS)** job uploads the three DMGs; the clean-machine sign-off and the hosted update feed remain. See [`operations/release.md`](../operations/release.md) |

## Flows that work

1. Choose Admin → pick yourself on the people list → the pad or the
   password field → dashboard (given an employee whose stored role is
   admin).
2. Orders → advance status → `orders.status` + `order_status_history`
   (given an externally seeded order).
3. Choose Kitchen → board → advance tickets.
4. Choose Waiter → tables → menu → cart → order; the order is joined to
   an open order on the table.
5. Choose Display → the customer board shows the order cards.
6. Title-bar palette glyph - a sun on a dark register and a moon on a
   light one, so the glyph names the half of the day the tap brings -
   hops between Light and Dark. Settings' Appearance card is the one that
   offers all four registers (Light, Dark, Warm, Night) and the
   high-contrast derivation, per device. Settings → Company holds the
   restaurant's own colour, which is not per device: it is a column on
   the company, it reaches every till in the reference document, and the
   theme derives the accent, its label and the focus ring from it.
7. The admin's setup creates a starter menu, six tables, the operator
   and the installation salt; the operator signs in with the credential
   they chose, tapped or typed. The service and kiosk copy the menu and
   the people from the admin's reference document, `auth_kind` included.
8. An order placed on the service app reaches the kiosk board on the
   event line, without waiting for the five-second poll; the poll is
   still the fallback when the stream is down.

The POS order write is committed and read back by the integration test
(`placing an order writes one op row and a durable clock`); the earlier
B-001/B-005 failures are history.

## Flows that do not work

1. ~~**Fresh install.**~~ FIXED for the admin: the admin app opens on
   the setup screen when the database has no company, and its setup
   writes the company, the operator, the installation salt, a 13-dish
   starter menu and six tables in one transaction. A service or kiosk
   that starts first waits for the admin's reference data.
2. ~~**Place order (committed HEAD).**~~ FIXED: the insert writes
   `orders.updated_at` and writes `NULL` for absent table/customer ids
   (B-001, B-005); the integration test reads the order back.
3. **Sign-in with the wrong role.** FIXED: the sign-in query is scoped to
   the session's role and the returned row is checked against it, so a
   waiter's credential no longer opens an admin session (B-002).
4. **Sign-in before the salt is confirmed.** FIXED: the sign-in waits
   until the database has confirmed the salt, and the setup writes the
   salt with the operator's hash (B-003).
5. **Payment edge cases.** FIXED: the payment write is idempotent (B-035).
   Closing a ticket without a payment is still possible (D23), and
   "Another order" is unhandled (B-033).
6. **Printing.** No receipt, no KOT.
7. ~~**Sync.** No second device sees the first.~~ FIXED: a second device
   pulls the ops above its vector cursor, and the reference document
   gives it the menu, people and tables. A late joiner still replays the
   whole log (#111).
8. ~~**Customers.** The list renders, but the data is never loaded.~~ FIXED: the
   customers load, and the owner can write one.
9. **A customer on an order.** The column is there and the order's
   `customer_id` is written, but the selling flow does not let the
   cashier pick the customer, so the loyalty points are never earned by
   a sale.
10. **The trading day.** The report's day is the calendar day. An order
    has no accounting date of its own, and the policy for a trading
    day is not settled (B-036, V1-G-027).
11. ~~**Loading and retry.**~~ FIXED: every read goes through one
    place, the shell says "Loading..." while one is on its way, and a
    read that failed is remembered with the screen it failed for. The
    screen is replaced with the reason and a "Try again" button, so a
    failed read never leaves a screen saying there is nothing there
    (B-021, E-004).

## Known source defects

These are facts about the current tree. Fixing them is engineering work, not
a docs change.

| # | Defect | Where | Impact |
|---|---|---|---|
| D1 | ~~Provisional salt installed before the database confirms it; a failed save was marked confirmed~~ | `src/core/update.zig` (`submit_login`, `createSalt`, `config_loaded`) | FIXED: the salt is a four-state lifecycle (`unknown`, `installing`, `verifying`, `confirmed`), the sign-in waits for `confirmed`, and the setup writes the salt with the operator's hash (B-003) |
| D2 | ~~Order `id` = wall ms, `order_no` = wall seconds~~ | `src/core/update.zig` (`placeOrder`, `nextOrderId`), `src/data/repos.zig` (`saveOrder`) | FIXED: the number is a sequence the database assigns, the id keeps a per-device floor, and a request key makes a retry the same sale (B-006, [ADR-0014](../decisions/0014-order-identity.md)). The cross-device half is the origin pair and negative remote ids ([ADR-0019](../decisions/0019-cross-device-order-identity.md), #87) |
| D3 | ~~`loadAll` omits `loadCustomers`~~ | `packages/ros-core/src/data/repos.zig` (`loadAll`) | FIXED: `loadAll` calls `loadCustomers`; the list and the form load (B-015) |
| D4 | Shell gates are hard-coded ordinals | `src/app.native` | A test now pins the gated ordinals against the enum, so inserting a screen fails the suite instead of remapping the UI (B-023) |
| D5 | `orders` header badge says "open" but uses `order_count` (non-voided, including completed) | `src/screens/screen-orders.native` | Misleading count (B-012) |
| D6 | ~~`auth.equal` is tested but unused by the login path~~ | `src/data/auth.zig` | FIXED: the helper is gone with the fetch-and-verify rewrite ([ADR-0018](../decisions/0018-the-pin-hash-is-the-employees.md)). A modern hash is checked by bcrypt's own `strVerify`, and a legacy digest by a plain `std.mem.eql`; the login compares digests, never the secret itself, so there is no secret for a timing signal to give up (B-027) |
| D7 | `app.json` declares a 960×600 minimum and restore policy; `main.zig` shell config does not | `app.json`, `src/main.zig` | `native dev` can open an unsupported window (B-024) |
| D8 | ~~`busy` is set on write, not on read~~ | `src/core/update.zig` | FIXED: every read goes through `repos.query`, so the app knows it is loading, and a failed read is remembered with the screen it failed for (B-021, E-004) |
| D9 | ~~No screen-coverage test~~ | `src/tests.zig` | FIXED: a test builds every gated screen and every screen in the enum, and asserts the widget budget. It found four screens that could never render (D20) |
| D10 | ~~CI smoke asserts only a non-blank canvas~~ | `.github/workflows/ci.yml` | FIXED: `scripts/smoke-sale.sh` walks setup → sign out → the pad → the picker → the till → orders → Team → the password field → KDS through the admin and kiosk binaries, and the `sale-smoke` job fails when a screen is not the screen it claims to be (G-018, #42) |
| D11 | No `build.zig` / `build.zig.zon` in the app | app root | Fine while managed; blocks linking a C library until `native eject` |
| D12 | ~~`view_unbound` lists `pending_screen`, which is not a field~~ | `src/core/model.zig` | FIXED: the stale entry is gone and the salt state is listed |
| D13 | ~~Order insert omitted `orders.updated_at`, which is `NOT NULL` with no default~~ | `packages/ros-core/src/data/repos.zig` (`saveOrder`), `apps/admin/src/schema/0005_orders.sql` | FIXED: the insert writes `updated_at`; the integration test reads the order back (B-001) |
| D14 | ~~Login query ignores `employee.role`; the chosen role decides the session~~ | `src/core/update.zig` (`login_checked`), `src/data/repos.zig` (`login_sql`) | FIXED: the query asks for the session's role and the returned row is checked against it (B-002) |
| D15 | ~~Order table/customer ids were written as `0`, not `NULL`~~ | `packages/ros-core/src/core/update.zig` (`placeOrder`) | FIXED: absent ids are written as `NULL` (B-005) |
| D16 | ~~`decodeCompany` kept slices into page drain memory~~ | `src/data/repos.zig` (`decodeCompany`) | FIXED: every decoder copies text into the model's bump buffer, and a regression test overwrites the page after decoding to prove it (B-004) |
| D17 | ~~PIN is a fast SHA-256 over four digits, with no lockout or masking~~ | `src/data/auth.zig`, `src/screens/screen-session.native` | FIXED: bcrypt at 2^10 rounds, six digits, and the till stops after five wrong credentials. The masking came with [ADR-0022](../decisions/0022-a-person-chooses-how-they-sign-in.md): neither surface shows the secret, because the model holds it and the markup binds a masked value - a dot for each tapped digit, a bullet for each typed character (B-027) |
| D18 | ~~Setup exists but has gaps (currency symbol field, no disabled submit)~~ | `apps/admin/src/screens/screen-session.native`, `packages/ros-core/src/core/update.zig` | FIXED: the setup carries the currency symbol and refuses an incomplete form; the admin owns the first run |
| D19 | ~~Status advance is not conditional; history can duplicate~~ | `src/core/update.zig` (`advance_order`), `src/data/repos.zig` (`setOrderStatus`) | FIXED: the move happens only from the status the order is in, and the history is written only when it did (B-008) |
| D20 | Four screens bound counts the model does not have (`customer_count`, `reservation_count`, `supplier_count`, `purchase_order_count`) | `src/screens/screen-customers.native`, `screen-reservations.native`, `screen-suppliers.native`, `screen-purchase-orders.native` | FIXED: those rail destinations could never render at all. The counts are model methods now |
| D21 | Three effect keys were used by two effects each (20, 21, 22) | `src/data/repos.zig` (the key table) | FIXED: a second live effect with the same key is REFUSED, so a company save could refuse an order write. Every key is used once, and a test says so |
| D22 | ~~The amounts are shown with two decimals whatever the currency is~~ | `packages/ros-core/src/core/model.zig` (`currency_divisor`), `apps/{admin,service,kiosk}/src/screens/*.native` | FIXED: the company carries its currency's decimals, the divisor comes from the model, and no amount divides by a hundred in the markup (B-013) |
| D23 | An order can be closed without a payment | `src/core/update.zig` (`nextStatus`) | The kitchen can advance a ticket straight to closed and the money is never taken (B-014) |
| D24 | ~~Back from home exposed the login screen; the stack froze at depth 32; cart/search/filters survived sign-out and role change~~ | `src/core/update.zig` (`resetSession`, `go`), `src/core/navigation.zig` (`Stack.push`) | FIXED: one session reset path, session gates are roots, pushing the current screen is a no-op and a full stack drops its oldest entry ([ADR-0015](../decisions/0015-session-scoped-navigation.md); B-009, B-010, B-011) |
| D25 | ~~The PIN salt is per installation, not per employee~~ | `src/data/auth.zig` | FIXED: the bcrypt salt is derived from the installation salt *and* the employee's id, and a bcrypt string carries its own salt, so a row is one person's and verifies on a device that never saw the installation salt ([ADR-0018](../decisions/0018-the-pin-hash-is-the-employees.md)). A cracked database still gives up every hash it holds - which is what the slow KDF, not the salt, is for ([ADR-0016](../decisions/0016-what-a-pin-is.md)) |
| D26 | A table with an order on it still said "Free" | `src/data/repos.zig` (`openOrderForTable`, `takePayment`) | FIXED: the table is occupied when the order opens and free when it is paid for, in the same transaction as each |
| D27 | The lists showed what the restaurant had finished with | `src/data/repos.zig` (the list queries) | FIXED: the categories, tables, customers and suppliers are filtered on `active` |
| D28 | The shell's import closure was full | `apps/admin/src/screens/` | FIXED: the screens of one area share one file, so the ceiling is no longer the reason the forms had to share |
| D29 | An empty pane and a working screen looked the same | `src/tests.zig` | FIXED: every screen has a landmark of its own, and the test finds it |
| D26 | The failed-credential counter is per session | `src/core/model.zig` | A restart clears it, so a determined guesser restarts (B-027, [ADR-0016](../decisions/0016-what-a-pin-is.md) follow-up) |
| D27 | ~~A second instance could confirm its own salt after a no-op write~~ | `src/core/update.zig` (`config_saved`) | FIXED: a successful salt write is read back; the model adopts the stored salt and only confirms that one (B-028) |
| D30 | The first run was one form with six fields on it, and it asked for nothing an invoice needs | `src/screens/screen-session.native`, `src/core/update.zig` | FIXED: the first run is the walk-through the roadmap names - the company's record, then the owner and the credential they choose, a PIN or a password - and the restaurant is written whole or not at all |
| D31 | A manager could not reset how a person signs in without SQL, and could not remove somebody who had left | `src/screens/screen-people.native`, `src/data/repos.zig` | FIXED: the reset form chooses the kind as well as the secret and writes both, so the old sign-in stops working the moment it is saved; the removal keeps the row and takes the person off the team, and the last admin is protected |
| D32 | The owner could not see what the restaurant took, and could not count the stock | `src/screens/screen-overview.native`, `src/screens/screen-catalog.native` | FIXED: the payments, the report, the stock count and the dishes' stations are all screens the owner can write to |
| D33 | An owner could not write a customer or a modifier group | `src/screens/screen-floor.native`, `src/screens/screen-settings.native` | FIXED: both have a form, and a group with no name is refused |
| D34 | The database inspector counted the tables in a list the app kept, and the list could drift from the schema | `src/data/repos.zig` (`table_counts_sql`) | FIXED: a test compares the list with what SQLite says, so a table the schema adds and the inspector forgets is a failing test |
| D35 | The walk-through was mounted inside the shell, which is only drawn when somebody is signed in | `src/app.native` | FIXED: the walk-through is a session screen, mounted beside the setup rather than inside the shell. It was never on the pane at all, and the tests drove the model, not the view |
| D36 | A failed read left a screen saying there was nothing there | `src/app.native`, `src/core/update.zig` | FIXED: a failed read replaces the screen with the reason and a way to try again, and the failure belongs to the screen that asked for the data |
| D38 | A ticket's button said "Advance" and its states said "Pending" and "Preparing": the workflow engine's words, not the floor's | `src/domain/models.zig`, `src/core/model.zig`, `src/data/repos.zig`, `src/screens/screen-orders.native`, `src/screens/screen-kitchen.native` | FIXED: a ticket is New, Cooking, Ready, Served, Closed or Voided, and its button names the move it makes - Start cooking, Mark ready, Hand off, Close ticket. A ticket with no move left shows no button rather than a blank one. `docs/glossary.md` is the list and a test pins it; the `status` ordinals did not move |
| D39 | No state on a board was coloured, and the colour a badge was given was silently thrown away | `src/screens/parts.native`, `src/screens/screen-{orders,kitchen,overview,service}.native`, `src/data/repos.zig`, `src/tests.zig` | FIXED: a ticket's state reads in its own colour on every board - a chip built from a row and a text, because a `badge` ignores `background=`. The pairing of the six states with their words and their tokens is pinned by a test that also checks each pair against WCAG AA in every palette |
| D40 | The title bar's palette control was a word, "Theme" - the noun it changes, and no word about the move it makes | `src/app.native`, `src/core/model.zig`, `src/tests.zig`, `scripts/smoke-sale.sh` | FIXED: a sun when the room is dark and a moon when it is light, with `label="Switch theme"` so the glyph is named for what it does. The button binds `theme_icon()`, so the picture cannot freeze on one palette; the walkthrough asserts the name and screenshots the dark paint |
| D41 | There were two palettes, the dark one was unfinished, and an operator had no way to ask for anything else | `src/core/theme.zig`, `src/core/{model,msg,update}.zig`, `src/screens/screen-settings.native`, `src/tests.zig` | FIXED: four registers - Light, Dark, Warm and Night - with the two dark ones completed (`disabled`, `shadow` and `scrim` were inheriting light values, so a dark modal had no scrim), a high-contrast derivation that pushes ink, washes and chips past their thresholds, and Settings' Appearance card to choose them. `theme_dark` became `theme_palette` and `theme_contrast_high`; the title bar's glyph still hops between the halves of the day and now carries the contrast with it. The contrast test walks all eight palettes |
| D42 | Appearance could be read and could not be used: its buttons were at the bottom of a scroll nobody scrolled | `src/screens/screen-settings.native`, `scripts/smoke-sale.sh` | FIXED: the card sits above the scroll. Every palette screenshot the walkthrough took came back in the same dark register, because the widgets were in the tree and off the pane - the presses were delivered to a control the operator could not see. The walkthrough now asserts the chosen state each register button reports and the canvas's own centre pixel, so a palette that stops painting fails there |
| D43 | The look the device was given was gone at the next boot | `src/data/repos.zig`, `src/core/{model,msg,update}.zig`, `src/tests_data.zig`, `scripts/smoke-sale.sh` | FIXED: `theme_palette` and `theme_contrast` are kept in `app_config` beside the salt - no migration, they are settings rather than records - written the moment the choice is made and read back with the rest of the boot. A read that lands after a tap does not undo it; the operator's choice is the truth. The stored look belongs to the file, so a copied database carries it, which is noted in `docs/glossary.md` |
| D44 | The restaurant had no colour of its own anywhere: the brand lived in the app's stylesheet and died there | `src/schema/0019_company_brand.sql`, `src/data/repos.zig`, `src/net/reference.zig`, `src/core/{model,theme,msg,update}.zig`, `src/screens/screen-settings.native`, `src/tests{,_data}.zig`, `scripts/smoke-sale.sh` | FIXED: `company.brand_color` is `#rrggbb` or nothing, typed in Settings → Company and saved with the rest of the restaurant's record. The theme reads it through the parser the form validates with, so the two cannot disagree, and it drives the accent, the label on that accent and the focus ring - nothing else, because a void is red in every restaurant. A brand the register cannot carry is walked toward the extreme it has room for, which keeps the hue and moves only its strength; a brand that can is used exactly as typed. It travels in the reference document, so a till that has never met the admin's stylesheet draws the awning's colour. The contrast test wears six brands over all eight palettes, and the walkthrough refuses a half-typed hash and reads a whole one back |
| D46 | The credential fields' labels floated beside the box or were `label=` text nobody could see: the PIN pad's display carried a label that replaced its own accessible name, and the setup, login and reset forms drew label, field and eye on three different lines | `src/screens/{screen-session,screen-people}.native` (all three apps), `scripts/smoke-sale.sh` | FIXED: the form pattern the rest of the app uses - a `<column gap="4">` with a `<text size="sm" foreground="text_muted">` directly above the field, and the eye as the last child of a `row cross="end"` so it sits on the field's bottom edge rather than the label's. The pad's bullets got the same treatment, which also un-stuck the walkthrough: a `label=` on the bullet text replaces the name the snapshot publishes, so `tap_pin` could never read the dots back. The visible-label rule now passes on a label that is above the field rather than merely next to it |
| D47 | Signing out left a gate that named nobody: "- enter your PIN" over a pad, whatever the person who had just left signed in with | `src/core/update.zig`, `src/tests{,_data}.zig`, `scripts/smoke-sale.sh` | FIXED: the person waiting at the gate is the caller's business, not the reset's. A successful sign-in ends the picker's pending choice, and a sign-out hands the gate back to the person whose session just ended, with the surface their row says they use - both read the row through one `choose_sign_in`, so the pad-or-field answer comes from the staff list rather than from whatever the screen last showed. A person whose row has gone during their session goes back to the picker, because a gate for nobody is a gate a secret gets typed at no one. The walkthrough now signs out into the gate the person left, and into the field for the password they were changed to |
| D48 | A typed amount was read at two decimals whatever the currency is, and a rate with one fraction digit was read twice | `packages/ros-core/src/core/{model,update}.zig`, `src/screens/screen-sell.native` (admin and service), `src/tests{,_data}.zig` | FIXED: money goes through `parseAmount`, which takes the company's `currency_decimals` - sixty yen is 60 and not 6000, a dinar keeps its third decimal, and a fraction finer than the currency can say is refused rather than rounded. A percentage and a tax rate are not money: they keep the hundred that belongs to the percent and now read it through `parsePrice`, which is that same reader at two decimals. Its own copy used to put a lone fraction digit in the tens and scale it again, so a slab typed "12.5" saved seventeen percent. The price, the fixed discount and the cash tender take the currency's decimals, and the confirmation screen's change, short and invalid readings call the same parser, so the warning beside the field cannot disagree with the payment that refuses it (#142) |
| D49 | The pad kept taking digits while the till was locked, and nothing on the screen said it was locked | `packages/ros-core/src/core/{model,update}.zig`, `src/screens/screen-session.native` (all three apps), `src/tests{,_data}.zig` | FIXED: `login_locked()` and `login_locked_seconds()` had been computed for a year and bound by no markup, so an operator tapped a six-digit PIN, was refused, and saw a live pad with no reason - the answer only ever arrived on the next press. `credential_surface_open` gates the pad and the field as one tree, the sign-in button is disabled for the wait, and the countdown is the heading in its place, under the person's name that is already on the card. A refused digit is refused on the way in, not hidden on the way out: `.credential_digit`, `.credential_edit`, `.credential_back` and `.credential_clear` all stop at the same gate, and the wrong guess that tripped the lock is cleared so the pad is empty when the wait ends. The lockout itself still lives only in the model - SEC8 and #135 are the persistence half, not this one |
| D50 | The kitchen board's badge counted every open ticket while the board itself showed one station's | `packages/ros-core/src/core/model.zig` (`ticket_count`), `src/tests_data.zig` | FIXED: the count applies the station filter the list applies, so the number over the board is the length of the list under it - the same class D5 caught on the orders badge. A station with nothing on it now reports nothing, which is what the board's empty state binds (#146) |
| D51 | `GET /v1/reference` answered anybody on the network, and the document it served was every employee's credential hash plus the installation salt | `packages/ros-core/src/net/{protocol,server}.zig`, `src/core/{net_bridge,model,msg,update}.zig`, `src/data/repos.zig`, `apps/*/src/main.zig`, `src/screens/screen-settings.native`, `src/tests{,_data}.zig` | FIXED: one pairing token per restaurant, held in `app_config` under `pairing_token`, seeded by `main` or `ROS_NET_TOKEN` and beaten by whatever is stored. It rides the `x-ros-token` header of every request for the restaurant's data and is checked twice, because the two halves of the wire are answered in two places: in `update` for `/v1/reference`, `/v1/ops` and `/v1/snapshot`, and in the listener thread for the held-open `/v1/events`, which never asks the app. An unpaired peer gets `401` and no bytes, and the refusal is counted on the Control centre beside the token an operator reads out to the next device. `/v1/hello` still answers anyone - a device that is not paired yet should be seen, and its card carries no restaurant data. Rotating is a typed field: `update` has no randomness, so a button could not make a secret ([ADR-0023](../decisions/0023-a-peer-presents-a-shared-device-token.md), #134, SEC9 for what is left) |

B-002 and B-003 are fixed in the working tree of 2026-10-21, with the
effect-key collision (D21) and the four unrenderable screens (D20) found
alongside them. The order identity was settled the same day: the number
is a sequence the database assigns, the id keeps a per-device floor, and
a request key makes a retry the same sale
([ADR-0014](../decisions/0014-order-identity.md), which supersedes
[ADR-0013](../decisions/0013-clock-based-order-ids.md)).

The money track has since closed the amount: the tax is worked out line
by line from each product's own slab, a discount is spread across the
lines and the tax follows it, a payment is taken once, and every
transition is conditional. What is left of the money is the price
parser and rounding (#66), an order that can close without a payment
(D23), and the lockout that a restart clears (B-027, D26). The full order is in the
[audit](../review/archive/2026-10-20-audit.md).

The compile-time `makeSalt` mismatch and the invisible-error-banner gap
were fixed earlier; they are no longer current defects. This status page
now defers detailed evidence to the [review set](../review/README.md).

## Test inventory

The inventory below is the pre-split core; the authoritative counts are
the suites themselves, and `scripts/verify-all.sh` runs all of them.

| Test | Area |
|---|---|
| The picker is the first screen and lists the device modes | Navigation |
| The picker lists the people who work here | Navigation |
| Picking a person opens the sign-in surface that is theirs | Session |
| The pad taps a PIN one digit at a time | Session |
| The secret shows as bullets, and the eye opens it | Session |
| A person whose role is not this app's is refused | RBAC |
| Picking a board signs the device in and opens it | Session |
| Back from home after a sign-in stays home | Session / Stack |
| Signing out clears the cart, filters and operator | Session |
| Changing role ends the previous session | Session |
| Role cannot open forbidden screen | RBAC |
| The permission matrix is total: every role against every screen | RBAC |
| Back returns | Stack |
| A full history drops its oldest entry, so navigation never freezes | Stack |
| Pressing the current destination does not grow the history | Stack |
| Cart arithmetic | POS |
| A second tap in flight does not place a second order | POS |
| Two sales in the same millisecond are two sales | POS |
| The order number is a sequence | POS |
| A failed sale does not consume an order number | POS |
| A retried write is the same sale | POS |
| A sale at the till shows on the orders board and the kitchen board | POS → Orders → Kitchen |
| The tax is worked out line by line, from the product's own slab | POS |
| An inclusive price already carries its tax | POS |
| The tax is rounded half up | POS |
| A discount comes off the bill, and the tax follows it | POS |
| A fixed discount is spread over the lines | POS |
| Advancing an order twice writes one history row | Orders |
| A move that does not apply leaves the order where it is | Orders |
| A payment is taken once | Payment |
| Integer money | Domain |
| A PIN is hashed, never stored | Auth |
| A PIN verifies against its own hash and nothing else | Auth |
| Two employees with the same PIN have different hashes | Auth |
| The old hash still verifies, so a running restaurant still works | Auth |
| A person signs in to the role this app runs, and nobody else | Session |
| The sign-in checks one person, not the whole staff list | Session |
| A legacy PIN waits for the database to confirm the salt | Auth |
| A failed salt write does not make the salt look confirmed | Auth |
| A fresh installation gets a salt, stores it, and keeps it | Auth |
| A second instance adopts the salt that is already stored | Auth |
| A PIN shorter than six digits is refused | Auth |
| The till stops taking PINs after too many wrong ones | Auth |
| An old PIN is rewritten in the modern form the next time it signs in | Auth |
| The page decoder | Data |
| A decoded company does not point at the page bytes | Data |
| A brand colour that is not a colour is refused | Data |
| The brand colour travels to the till with the company | Data |
| Derived counts | Model |
| Layout survives resize | Markup |
| The shell gates the screens the enum says it does | Navigation |
| Every gated screen renders, inside the widget budget | Markup |
| Every screen builds a view inside the budget | Markup |
| Every text entry draws a visible label | Markup |
| The rail, the title bar and the markup say the same thing | Vocabulary |
| Every effect key names one effect and no two | Data |
| Every text pair in every register clears WCAG, both contrasts | Theme |
| A ticket's chip colours the state it names, in every palette | Theme |
| No badge is given a colour it will ignore | Theme |
| Settings offers every palette, and the contrast beside them | Theme |
| The palette and the contrast the theme reads are the model's | Theme |
| The theme control's glyph is the theme the tap brings | Theme |
| The palette and the contrast come back on the next boot | Theme |
| A boot read that lands after a choice does not undo it | Theme |
| A brand colour is a hash and six digits | Theme |
| A brand colour keeps every pair it lands on, in every register | Theme |
| A brand the register can already carry is used exactly as it was typed | Theme |
| A brand the register cannot carry is pushed, not replaced | Theme |
| The walk-through takes a restaurant from nothing to a POS | Setup |
| The setup Symbol field writes the symbol, not the code | Setup |
| A fresh database asks to be set up | Setup |
| A manager can reset how an employee signs in | People |
| A row from before the choice signs in with a PIN | People |
| An employee is saved and can sign in | People |
| The setup refuses a PIN that does not match | Setup |
| An owner can open the restaurant with a password | Setup |
| The reference says how each person signs in | Sync |
| An employee who has left is not on the team and cannot sign in | People |
| The last admin cannot be removed | People |
| The payments screen shows the money the restaurant took | Money |
| The report says what the day came to | Money |
| The owner counts the stock, and the count says why it moved | Catalog |
| A count without a reason is refused | Catalog |
| The owner says which station cooks which dish | Kitchen |
| A dish with no station chosen is refused | Kitchen |
| The inspector counts every table the schema creates | Data |
| The inspector counts the rows that are really there | Data |
| The control centre shows the devices and the sync state | Data |
| The owner writes a customer | Customers |
| A customer with no name is refused | Customers |
| The owner writes a modifier group | Catalog |
| A modifier group with no name is refused | Catalog |
| The app says it is loading while a read is on its way | Shell |
| A read that fails is something the operator can try again | Shell |
| A failure belongs to the screen that asked, not to the pane | Shell |
| Every session screen renders, inside the widget budget | Markup |
| A fresh installation shows the walk-through, not the quick setup | Setup |
| The event stream stays open, and a normal request still gets through | Wire |
| A peer's event stream opens, and a line pulls its ops | Wire |
| An event during a pull schedules one more pull | Wire |
| A failed event stream is counted, and the poll reopens it | Wire |
| The SDK's real stream fetch reads the held-open NDJSON server | Wire |
| An applied op reloads the board without an explicit query | Sync |

Not covered: every decoder except the generic page reader and the
company decoder, timer, error arms, and the sidecars. The sale is walked
headlessly now, in the suite and in CI, but it stops at the payment prompt:
nothing in automation takes the money or prints the receipt.

## What "done" would add

- A test per screen that asserts what the operator sees, not only that
  it builds.
- A Developer ID signed, notarised release installed and signed off on
  the three clean machines.
- A hosted, signed update feed per app, with the per-app cadence in
  [`operations/release.md`](../operations/release.md) put into practice.

## Related

- [architecture/03](../architecture/03-navigation-and-rbac.md) — screen and role detail
- [architecture/04](../architecture/04-data-layer.md) — repository coverage
- [risks](risks.md) — what could go wrong next
- [open questions](open-questions.md) — what we still do not know

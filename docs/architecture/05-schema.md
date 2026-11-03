# Schema

> **Status:** Scaffolded — 46 tables across 21 migrations; only the core
> subset is used by repositories or UI.
> **Last verified:** 2026-11-04, by source review and the migration lock.
> **Source:** `src/schema/0001_core.sql` … `0021_unpaid_closures.sql`,
> `src/schema/migrations.lock.json`.

## Conventions

Every table follows these rules. They are enforced partly by SQLite and
partly by review.

| Rule | Detail |
|---|---|
| `STRICT` only | The SDK rejects non-STRICT tables (`NS1405`). Declared types are enforced. |
| Money is `INTEGER` minor units | Cents, paise, yen. No `REAL` money. |
| Time is `INTEGER` epoch milliseconds, UTC | Including `created_at`, `updated_at`, `placed_at`. |
| Booleans are `INTEGER` 0/1 | With `CHECK (x IN (0, 1))`; STRICT has no `BOOLEAN`. |
| Enumerations are `INTEGER` codes | With a `CHECK` listing valid codes; the app mirrors them in `domain/models.zig`. |
| Machine-readable text is `TEXT` | Order numbers, hashes, codes, JSON snapshots. |
| Monetary columns are non-negative unless they are a delta | `price_minor >= 0`; `stock_adjustment.delta` may be negative. |
| Foreign keys are explicit | `REFERENCES ... ON DELETE ...`; the engine runs with `foreign_keys=ON`. |
| Append-only migrations | Never edit a shipped migration; add the next number and regenerate the lock. The SDK checks every published file against `migrations.lock.json` (`NS1406`), so even a **comment** in `0001_core.sql` is frozen history — where the file says "salted SHA-256" it means "what this column held then". This page is where the current truth is written. |

## Migration policy

- Files are numbered `NNNN_name.sql` in `src/schema/`.
- `migrations.lock.json` is the authority: version 21 and twenty-one
  hashes.
- `native db new-migration <name>` is the intended authoring path.
- The engine opens the database **already migrated** at boot; the app
  never runs migration code.
- A schema change is one edit in `repos.zig` plus one new migration.
- The target is a greenfield baseline plus forward migrations. There is no
  installed Restaurant OS base yet, so a correction can still be folded into a new
  migration without a data migration. Once a release ships, that stops.
  `0021` is the first migration that breaks the rule, and it does so
  deliberately: the rows it repairs were written by a build the owner
  already runs, on a database that upgrades in place, and there is no
  version of "fold it into the baseline" that reaches them.

## Tables by domain

The SQL file is authoritative for columns. This table is the map.

### 0001 — Core (4 tables)

| Table | Purpose | Used today |
|---|---|---|
| `company` | The one company: name, currency, tax-inclusive flag, address/contact/tax number, brand colour | Read/write |
| `currency` | Supported currencies with symbol and minor-unit count | No |
| `employee` | Staff; `role` 0–3; `pin_hash` the credential's bcrypt hash (0001 wrote "salted SHA-256"; see the append-only rule above) | Login read |
| `app_config` | Key/value settings: the credential salt (the key is still `pin_salt`), this device's palette and contrast, the restaurant's pairing token, schema version, device role, shift | Read/write (salt, look, pairing) |

### 0002 — Catalog (7 tables)

| Table | Purpose | Used today |
|---|---|---|
| `product_category` | Menu sections | Read |
| `tax_slab` | Rate in basis points, inclusive flag | No |
| `product` | Menu item: price, type, food type, tax slab, stock | Read |
| `modifier_group` | Required/optional choice set with min/max | No |
| `modifier` | One choice with a price delta | No |
| `product_modifier` | Product ↔ modifier group | No |
| `discount` | Percentage (bps) or fixed amount | No |

### 0003 — Floor (4 tables)

| Table | Purpose | Used today |
|---|---|---|
| `dining_table_category` | Room/zone grouping | No |
| `dining_table` | Table: status, seats, grid position, size | Read (status board) |
| `kds_station` | Kitchen station ("Grill", "Tandoor", "Bar") | No |
| `product_station` | Product ↔ station routing | No |

### 0004 — Customers (3 tables)

| Table | Purpose | Used today |
|---|---|---|
| `customer` | Name, contact, loyalty points | Read repo only |
| `customer_loyalty` | Points ledger | No |
| `loyalty_transaction` | Points delta tied to an order | No |

### 0005 — Orders (7 tables)

| Table | Purpose | Used today |
|---|---|---|
| `orders` | The sale header: status, type, totals, table/customer/employee | Read/write |
| `order_line` | Frozen product name and price, qty, tax bps, station | Read/write |
| `order_line_modifier` | Frozen modifier choice on a line | No |
| `order_discount` | Discount applied to an order | No |
| `order_status_history` | Lifecycle ledger, written with the status change | Write |
| `payment` | Mode, amount, reference | No |
| `reservation` | Booking: party, table, time, status | No |

### 0006 — Inventory (4 tables)

| Table | Purpose | Used today |
|---|---|---|
| `supplier` | Vendor master | No |
| `purchase_order` | Purchase header | No |
| `purchase_order_item` | Purchase line, received qty | No |
| `stock_adjustment` | Why stock changed (delta + reason) | No |

### 0007 — Operations (6 tables)

| Table | Purpose | Used today |
|---|---|---|
| `shift` | Cash drawer open/close, expected vs counted | No |
| `time_entry` | Clock in/out | No |
| `business_hours` | Weekly opening minutes | No |
| `holiday_hours` | Date-specific hours | No |
| `expense_category` | Expense grouping | No |
| `expense` | Money out | No |

### 0008 — Compliance (3 tables)

| Table | Purpose | Used today |
|---|---|---|
| `compliance_report` | X/Z report snapshot with payment split JSON | No |
| `void_log_entry` | Voided order, reason, employee, amount | No |
| `subscription` | Plan and expiry | No |

### 0009 — Printing (2 tables)

| Table | Purpose | Used today |
|---|---|---|
| `printer` | Kind (`escpos`/`system`), transport (`ble`/`tcp`/`usb`/`file`), address, job, width | No |
| `auto_print` | Printer ↔ job routing | No |

### 0010 — Sync (3 tables)

| Table | Purpose | Used today |
|---|---|---|
| `device` | Device identity and role | No |
| `op_log` | Append-only mutation log: table, row, operation, snapshot, logical clock, device | No |
| `sync_state` | Local logical clock and sync metadata | No |

### 0016 — Order origin (columns and indexes on `orders`)

| Column/index | Purpose |
|---|---|
| `orders.origin_device` | The device that took the sale. Empty on a row that predates the columns and has no create op; the app treats that as this device. |
| `orders.origin_id` | The order's id on `origin_device`. Together with the device it is the stable cross-device name. |
| `orders_origin` | Lookup index on `(origin_device, origin_id)` for a status or payment op that names the origin. |
| `orders_remote_origin` | Partial unique index on `(origin_device, origin_id) WHERE id < 0`; a remote order is stored once per origin. |

The local `orders.id` stays the row key. Local sales are positive; a
received sale gets a negative local id. See
[ADR-0019](../decisions/0019-cross-device-order-identity.md).

### 0017 — Sync snapshot (2 tables)

| Table | Purpose | Used today |
|---|---|---|
| `sync_snapshot` | The compacted base state: one row per generation with the vector clocks it was taken at | Yes |
| `sync_snapshot_op` | The encoded wire lines of that generation, ordered by `seq` and paged by `/v1/snapshot` | Yes |

The migration also adds `op_log.compacted_at`, an index on
`op_log(device_id, logical_clock)` for retention, and a trigger that
keeps `sync_state('ops_since_compact')` durable across restarts. The
deleted range is recorded per device in `sync_state('op_floor')`; a
peer below it is sent to `/v1/snapshot`. See
[ADR-0020](../decisions/0020-late-join-and-compaction.md).

### 0018 — Order line stock (1 column)

| Column | Purpose | Used today |
|---|---|---|
| `order_line.stock_taken` | Whether this database's shelf figure has a plate in it: 1 means a later void must put it back | Yes |

A line takes its product off the shelf where the sale is written, and a
void puts it back. A device that bootstraps from a compacted snapshot
never replays the sale — its stock already reflects it — so the line has
to remember whether there is anything to restore. A line on an open order
keeps 1 even when it arrives in a snapshot, because the snapshot's count
was taken with that plate already sold.

### 0019 — Company brand colour (1 column)

| Column | Purpose | Used today |
|---|---|---|
| `company.brand_color` | `#rrggbb` the restaurant draws with; `''` means the register's own accent | Yes |

The colour belongs to the company rather than to the device: the owner
types it once and every till, board and kiosk on the network draws with
it, including one that was set up before the column existed. It is
therefore part of the reference document, not of `app_config`, and the
default keeps an old database upgrading in place with no data migration.
The app never stores a colour it cannot read — the form refuses a string
that is not `#rrggbb`, and the theme parses the same shape.

### 0020 — Employee credential kind (1 column)

| Column | Purpose | Used today |
|---|---|---|
| `employee.auth_kind` | How this person proves who they are: 0 a PIN, 1 a password | Yes |

The kind is a fact about the person, not about the device and not about
the role. A device changes hands, and a role says what a person may open
rather than what they type. It decides the surface the till offers — a
numeric pad for a PIN, a masked text field with an eye for a password —
and the policy the form applies when the secret is written.

`NOT NULL DEFAULT 0` means a database written before the column exists
upgrades in place and everybody on it signs in exactly as before: the
digest in `pin_hash` was made from digits, so zero is the truth about it.
The `CHECK` an enumeration usually carries is not available to a column
added after the table — SQLite refuses it — so
`CredentialKind.fromInt` is what decides that a number nobody wrote is
not a kind, and falls back to the PIN.

The kind is part of the reference document, so a second device offers the
right surface for a person it has never met, and the sign-in takes the
kind from the row it is about to check rather than from a list it loaded
earlier. See [ADR-0022](../decisions/0022-a-person-chooses-how-they-sign-in.md).

### 0021 — Unpaid closures reopened (a data repair, no DDL)

| Statement | Effect |
|---|---|
| `INSERT INTO order_status_history … SELECT id, 3, updated_at FROM orders WHERE status = 4 AND NOT EXISTS (payment)` | Records the reopening of every ticket that closed without money |
| `UPDATE orders SET status = 3 WHERE …the same rows…` | Puts them back on the last step the kitchen owns |

Nothing about the shape of a table changes. This migration repairs rows:
every order sitting in `completed` with no `payment` behind it goes back
to `served`, where the till can take the money and close it properly.

The state is not untidy, it is uncollectable. `paid` is read from the
payment rows an order has, so an unpaid closed ticket still shows a Pay
button, and taking the payment refuses a ticket it reads as paid; and a
table is freed only by a payment or a void, so the ticket keeps its party
on the floor plan. `served` is where a reopened ticket lands because
`ready` and `preparing` ring the pass for plates that have already gone
out. Its history row's `changed_at` is the order's own `updated_at`,
because there is no honest timestamp for a state the app never recorded a
person entering.

The repair is local and writes no op: `applyOrderStatus` moves a ticket
forward, never back, so a `served` op arriving after a `completed` one is
refused by design. Each device repairs its own copy the first time it
opens on this version, and the statements that were guarded in the same
release stop any of them writing another one. See
[ADR-0024](../decisions/0024-a-ticket-closes-with-its-money.md).

## Indexes

Indexes exist where the current queries need them:

- `employee(active)`
- `product(category_id)`, `product(active)`
- `modifier(group_id)`
- `dining_table(category_id)`
- `customer(name)`
- `customer_loyalty(customer_id)`
- `orders(status)`, `orders(placed_at)`, `orders(dining_table_id)`
- `orders(origin_device, origin_id)`, plus the partial unique remote-origin index
- `order_line(order_id)`
- `order_line_modifier(order_line_id)`
- `order_status_history(order_id)`
- `payment(order_id)`
- `reservation(reserved_at)`
- `purchase_order(supplier_id)`, `purchase_order_item(purchase_order_id)`
- `stock_adjustment(product_id)`
- `shift(employee_id)`
- `expense(spent_at)`
- `compliance_report(generated_at)`
- `void_log_entry(order_id)`
- `auto_print(printer_id)`
- `op_log(entity_table, entity_id)`, `op_log(logical_clock)`, `op_log(device_id)`,
  `op_log(device_id, logical_clock)` for retention

Missing indexes that the target will need: order lines by product for
sales-by-item reports, payments by `paid_at` for shift reconciliation,
and reservations by status.

## Relationship to the Flutter schema

The v1 app had 39 tables in `assets/db/schema.sql`. Restaurant OS has 46, rewritten
as STRICT. The differences that matter:

| v1 | Restaurant OS | Why |
|---|---|---|
| `order_product` | `order_line` | Clearer name; frozen product name/price |
| `payments` / `payment` naming drift | `payment` | One spelling |
| No `device` table | `device` | Sync identity is first-class |
| `op_log` JSON blobs | `op_log` STRICT with clock/device columns | Sync is a schema concern now |
| `currency` folded into company | `currency` table | Currency picker needs a list |
| 8 tables with no repository | Still no repository, but they exist | Issue #153 is closed in schema, not in code |
| `REAL` money | `INTEGER` minor units | Rounding bugs |
| Loose affinity | `STRICT` + `CHECK`s | The SDK requires it |

The v1 `app_config` also held `schema_version` and `device_role`; Restaurant OS keeps
the table but only reads/writes `pin_salt` today.

## Schema gaps and decisions still open

1. **`order_line` vs modifiers.** The schema supports modifiers; the POS
   cannot choose one and the order write does not persist them.
2. **Tax.** `tax_slab` and `order_line.tax_bps` exist; the order write
   hard-codes `tax_bps = 0` and `tax_minor = 0`.
3. **Payments.** No repository, no UI. An order can be completed without
   a payment row; the schema does not enforce otherwise.
4. **Loyalty.** `customer.loyalty_points` and two ledgers overlap. Which
   is authoritative is undecided.
5. **Reservations vs tables.** No link from a reservation to an order.
6. **Soft delete.** Some tables have `active`; orders have status. There
   is no global deletion convention.
7. **Audit columns.** `created_at`/`updated_at` exist on some tables, not
   all. A uniform convention is a target.
8. **Sync identity.** The order origin pair is defined in ADR-0019. The
   device token is generated at boot and not persisted, so a restart is
   a new device identity for future rows and cursors; persisting it is a
   follow-up.
9. **Schema version.** `app_config.schema_version` is mentioned in v1
   docs but not written by Restaurant OS. The migration lock is the real version.
10. **One company.** Enforced by query, not by a constraint. A second row
    would be silently ignored by `LIMIT 1`.
11. **No seed data.** A fresh install has no company, no employee and no
    products. The walk-through and the setup wizard build the first two,
    and the owner chooses there whether they sign in with a PIN or a
    password. Products come from the reference document or the catalog
    form, not from a seed.
12. **Deletion and referential actions.** `ON DELETE SET NULL` on order
    lines means deleting a product does not destroy history, but it does
    lose the link. That is intentional; document it per table when the
    admin UI lands.

## Rules for changing the schema

1. Read this page and `repos.zig`.
2. Add `src/schema/NNNN_name.sql`; never edit an earlier file.
3. Keep `STRICT`, `CHECK`s, integer money and epoch-ms time.
4. Regenerate `migrations.lock.json` through the SDK tooling.
5. Add or update the repository constant; update its decoder.
6. Add an in-memory migration test for the new table/column.
7. Update this page and `plan/status.md`.

If a change needs a data migration, that is a release decision, not a
phase-2 cleanup. See [ADR-0005](../decisions/0005-engine-owned-sqlite-strict-schema.md).

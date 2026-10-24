# Schema

> **Status:** Scaffolded — 46 tables across 17 migrations; only the core
> subset is used by repositories or UI.
> **Last verified:** 2026-10-24, by source review and the migration lock.
> **Source:** `src/schema/0001_core.sql` … `0017_sync_snapshot.sql`,
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
| Append-only migrations | Never edit a shipped migration; add the next number and regenerate the lock. |

## Migration policy

- Files are numbered `NNNN_name.sql` in `src/schema/`.
- `migrations.lock.json` is the authority: version 17 and seventeen hashes.
- `native db new-migration <name>` is the intended authoring path.
- The engine opens the database **already migrated** at boot; the app
  never runs migration code.
- A schema change is one edit in `repos.zig` plus one new migration.
- The target is a greenfield baseline plus forward migrations. There is no
  installed Restaurant OS base yet, so a correction can still be folded into a new
  migration without a data migration. Once a release ships, that stops.

## Tables by domain

The SQL file is authoritative for columns. This table is the map.

### 0001 — Core (4 tables)

| Table | Purpose | Used today |
|---|---|---|
| `company` | The one company: name, currency, tax-inclusive flag, address/contact/tax number | Read |
| `currency` | Supported currencies with symbol and minor-unit count | No |
| `employee` | Staff; `role` 0–3; `pin_hash` salted SHA-256 | Login read |
| `app_config` | Key/value settings: PIN salt, schema version, device role, shift | Read/write (salt) |

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
    products. Login cannot succeed until setup exists. Setup is planned,
    not built.
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

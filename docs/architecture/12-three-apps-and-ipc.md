# Three apps and the protocol between them

> **Status:** Implemented core. The three shells build; the wire (9.2),
> the op log (9.3), discovery (9.4), reference data (9.5), the push
> stream (9.6) and late-join bootstrap/compaction (9.7) are merged.
> Packaging (9.9) remains. The decision is
> [ADR-0017](../decisions/0017-three-apps-over-tcp-ip.md); the bootstrap
> and compaction rules are
> [ADR-0020](../decisions/0020-late-join-and-compaction.md); the delivery
> order is [`plan/phase-9`](../plan/phase-9-three-apps-and-ipc.md).
> **Last reviewed:** 2026-10-24, after the bootstrap/compaction slice landed.

## What this page is

The product stops being one binary with four roles and becomes three
apps that talk to each other over TCP/IP. This page says which screens
live in which app, what the wire looks like, who owns which piece of
data, and what happens when a device is off, unreachable or new.

It is the target, not the as-built. The as-built picture is
[`plan/status.md`](../plan/status.md).

## The three apps

| App | Role | Sign-in | Home | Screens |
|---|---|---|---|---|
| `admin` | `admin` | PIN | `admin_dashboard` | 50 |
| `service` | `waiter` | PIN | `waiter_tables` | 12 |
| `kiosk` | `kds` or `display`, chosen at install | device | `kds_board` or `display_board` | 3 per mode |

Each app is a separate Native SDK app: its own `app.json`, its own id
(`com.devstroop.ros.admin`, `com.devstroop.ros.service`, `com.devstroop.ros.kiosk`),
its own window, its own icon, its own engine-owned database in its own
app-data directory, and its own release artifact. `scripts/package.sh`
builds the three macOS DMGs and the
[release runbook](../operations/release.md) covers signing, install and
the per-app update cadence.

### The screen partition

The split follows the permission matrix in `src/core/rbac.zig` exactly.
`Role.needs_sign_in()` is already the boundary: `admin` and `waiter`
sign in with a PIN, `kds` and `display` sign in by device.

The counts are read off the enum and the matrix, not estimated. The
`admin` app mounts the 50 screens the admin role may open, less the
three every app shares; the `service` app mounts the 12 the waiter role
may open, less those three; the `kiosk` app mounts 3 per mode - its
board and `order_detail` - plus the person picker and the sign-in.

**The counter POS is the service app's.** The waiter role opens `pos`,
`pos_cart` and `payments`, and the service shell mounts all three; the
tables screen has "Counter sale" and "Payments" entry points. The
`admin` app remains the wildcard superset, so a single-machine
restaurant can still run the till from it and a manager can use the
same screens for setup or correction. The kiosk roles never open a
money screen. See
[ADR-0021](../decisions/0021-counter-pos-is-the-service-app.md).

**These counts move, and they have moved.** The first draft of this
page said 38, 11 and 3, read off the enum as it stood on 2026-10-21.
The enum has grown since - the back office added the payments, the
report, the stock, the dishes, the control centre, the database
inspector, the customer and modifier forms, the cart, the table
categories and the floor plan - and the numbers with it. The counts
here are read off the tree **this phase will be built on**, which is
the back office merged: 53 screens in the enum, 50 for the admin app.

The partition is not something to maintain by hand. The matrix is
walked against the enum by a test in `src/tests.zig`, and the shell's
gates are pinned to the enum by another, so a screen cannot be added
or moved without a test saying so. The table below is the partition
those two tests describe.

| Screen group | admin | service | kiosk |
|---|---|---|---|
| `admin_dashboard`, `control_center` | ● | | |
| `pos`, `pos_cart` | ● | ● | |
| `orders` | ● | ● | |
| `order_detail` | ● | ● | ● |
| `order_confirmation` | ● | ● | |
| `payments` | ● | ● | |
| `customers` | ● | ● | |
| `dining_tables`, `table_categories`, `floor_plan`, `reservations` | ● | | |
| `kitchen_dishes`, `inventory_items`, `product_categories`, `suppliers`, `purchase_orders` | ● | | |
| `employees`, `employee_form`, `reports` | ● | | |
| `settings`, `settings_company`, `settings_currency`, `settings_tax`, `settings_modifiers`, `settings_discounts`, `settings_printers`, `data_management`, `db_inspector` | ● | | |
| `product_form` | ● | | |
| `tax_slab_form`, `discount_form`, `category_form`, `categories` | ● | | |
| `modifier_group_form`, `customer_form`, `table_category_form`, `stock_count` | ● | | |
| `waiter_tables`, `waiter_menu`, `waiter_cart`, `waiter_orders` | | ● | |
| `kds_board` | | | ● in kitchen mode |
| `display_board` | | | ● in display mode |
| `login` | ● | ● | ● |
| `landing`, `reset_pin` | ● | ● | |
| `setup`, `wizard`, `create_company`, `upgrade` | ● | | |
| `role_picker` (the person picker) | ● | ● | ● |

`setup`, `wizard`, `create_company` and `upgrade` are the onboarding
path: every app mounts them by their own condition before a role
exists, and the table records the role that may open them once signed
in.

`role_picker` is the one screen whose meaning changes, and **it is
mounted in all three apps** - which is a change from the first draft of
this page, and the change is a correction.

Under [ADR-0018](../decisions/0018-the-pin-hash-is-the-employees.md)
the sign-in names the *person* and the PIN says they are that person.
So the picker is no longer a choice between four roles: it is a list of
the people who work here, each with the mode they work in, and it is
the way in to the PIN. `admin` and `service` both sign in with a PIN,
so both need it. In `kiosk` it carries the two device modes as well -
the kitchen board and the customer display are not people, and nobody
types a PIN into them - and the choice is stored in the device's
configuration.

The first draft of this page said the picker survived only in `kiosk`.
That was written against the salt being settled but not implemented, and
it does not match the code: `pick_employee` in `core/update.zig` is the
entry to the PIN, and the login screen refuses a sign-in with "Choose
who you are first" when it has not been sent. The enum's name stays -
the enum is append-only - but the screen behind it is the **person
picker** now, and it is mounted wherever a person signs in.

The `Screen` enum stays append-only. Nothing is renumbered and no
ordinal moves: the markup's contract is the enum's order, and the
partition is expressed by what each app *mounts*, not by renumbering.

### One model, three shells

The apps do not carry three copies of the logic. There is one shared
package with the domain, the model, the messages, `update`, the
repositories and the protocol. The apps differ in:

- the manifest and the id;
- `main.zig`, which declares the app's fixed role;
- `app.native`, which mounts that role's screens;
- `app_sources.zig`, the import closure of those screens.

`Role` stops being model state. It is a constant of the binary, and
`rbac.allows` is evaluated against it exactly as it is today - so the
refusal path, and its test, do not change.

## What one app looks like inside

```
┌────────────────────────────────────────────────────────────────────────┐
│                                                                        │
│  loop thread                            net thread (started in main)   │
│  ┌                            ┐         ┌                        ┐     │
│  │ UiApp                      │         │ std.Io.net             │     │
│  │   Model ◀─ update ─▶ Msg   │         │  TCP listen :45871     │     │
│  │     ▲                      │         │   accept → HTTP/1.1    │     │
│  │     │ fx.dbQuery / dbExec  │         │  UDP beacon :45872     │     │
│  │     │ fx.fetch  (client)   │         │       │                │     │
│  │     │ fx.openChannel       │◀────────┤ post(ChannelHandle)    │     │
│  │     │ fx.startTimer        │         └                        ┘     │
│  └                            ┘                                        │
│         ▲                            │                                 │
│         │                                                              │
│                              ┌───────┴───────┐                         │
│                              │    outbox     │                         │
│                              └───────────────┘                         │
│  SQLite (engine-owned, one database per app)                           │
└────────────────────────────────────────────────────────────────────────┘
```

### The rule that keeps this honest

**The net thread never touches the model and never touches the
database.** It moves bytes. That is the whole of it.

- **Thread to app:** the net thread posts the received bytes with
  `ChannelHandle.post`. The SDK delivers them as a `Msg`, so the bytes
  arrive as a message payload rather than as a drain of a queue. The
  pure-core rule survives: `update` is still a function of the model and
  the message it was given.
- **App to thread:** the SDK has no channel that runs the other way, so
  the app owns a small, bounded outbox. `update` writes an answer into
  it; the net thread reads the answer back and writes it to the socket.
  The net thread is woken by a self-pipe where the platform offers one
  (`std.Io.Dispatch`), and by a short timed poll where it does not.
- **The handshake:** the net thread cannot post into a channel that
  does not exist yet, and the channel can only be opened from `update`,
  which is the loop thread's job. So the loop thread opens it and
  publishes the handle; the net thread waits for it. One atomic flag
  and one handle.
- **The stop:** a thread that owns a socket needs a way to stop, and
  `accept` blocks, so a flag alone cannot wake it. The app sets the
  flag and connects to its own listener, which is the portable way to
  make `accept` return.
- **The event threads:** A held-open `/v1/events` connection gets its
  own thread. It watches the shared sequence and writes bytes; it does
  not touch the model, the database or the outbox.

This outbox is the one shared mutable **buffer** in an app. The event
stream adds one atomic counter, `Shared.event_seq`, which the app bumps
after an op commits and every event thread reads; it carries no rows
and no answer. Both are app-owned memory, not the world: no clock, no
allocator, no I/O happens in `update`. The outbox is called out here
because it is the one place the design bends, and because a reader
should be able to find it.

**It does not need a lock, and that is a finding rather than a
preference.** `std.Thread.Mutex` is gone in Zig 0.16, and
`std.Io.Mutex` takes the `Io` it locks against - which `update` does
not have, because `update` is pure and has no `Io`. A mutex is
therefore not available to the code that needs it. The outbox is
single-producer and single-consumer: the loop thread is the only
writer and the net thread is the only reader. Two atomic counters are
enough, with a release store after a write and an acquire load before
a read. `update` never blocks, and it never waits.

**The outbox is per connection, not one shared ring.** A frame carries
no peer id, so a shared ring would let one peer's answer reach
another peer - and a leftover answer from a connection that timed out
would be handed to the next connection that reused the slot. Each
connection owns a slot, and the slot is cleared when the connection is
accepted. The protocol will have several peers connected to one app at
once, so this is not a nicety: it is the difference between an answer
and the wrong answer.

### What the spike proved

`apps/net-spike` is the proof, and it runs in the repository's own
suite. It is a net thread with a real listener and a real app with a
real model, and it does one thing: it calls its own listener.

| Claim | How it is proved |
|---|---|
| A `std.Io.net` listener in a `main` thread accepts a connection and speaks HTTP/1.1 | The app fetches its own listener and gets a 200 |
| `fx.fetch` reaches that listener, and the response arrives as a `Msg` | The body arrives in the model as a `.fetched` message |
| Bytes posted from the net thread arrive as a `Msg` payload | The app copies them out of the message and answers |
| A response written by `update` reaches the socket | The fetch gets back the response `update` wrote |

The round trip, from the app's own log:

```
SEAM: the net thread bound port 63627
SEAM: fetch outcome=ok status=200 body="pong" -> SEAM OK
```

Seven things the spike settled that the design had assumed:

1. **The outbox is lock-free**, as above. The design said "lock
   protected"; the code says "two atomics", because a lock is not
   available to `update`.
2. **The outbox is per connection.** The first version of the spike
   used one shared ring, and the review found the hole: a frame
   carries no peer id, so an answer could reach the wrong peer, and an
   answer left behind by a timed-out connection would be handed to the
   next one. The slots fixed both, and the test that proves it is
   "an answer never crosses to another connection".
3. **The port is learned as bytes.** The net thread posts `PORT 45123`
   and the app reads it out of a message, so the model is the only
   place the port lives. A shared variable would have been a second
   source of truth.
4. **Plain `http://` works.** The SDK's fetch is built on Zig's own
   `std.http.Client`, not on the platform's, so macOS App Transport
   Security does not stand in the way of a LAN address.
5. **The channel's bytes are drain scratch.** They are valid only for
   the `update` call that receives them, so the app copies them. This
   is the same rule the database's page bytes follow.
6. **A thread that owns a socket needs a stop, and a flag is not
   enough.** `accept` blocks. The app sets a flag *and* connects to
   its own listener, which is what makes `accept` return. Without it
   the app hangs on quit wherever the runtime returns from
   `runWithOptions` instead of terminating the process - which is
   Linux and Windows, and not macOS, where AppKit's `exit()` hides it.
7. **An answer that does not fit must say so.** The read reports the
   frame's full length, so the caller can refuse rather than write
   half a response to a socket.

The spike binds the address it is told to bind, so the LAN path can be
exercised without a rebuild:

```sh
ROS_SPIKE_BIND=192.168.1.42 ./zig-out/bin/net-spike
```

What the spike still does **not** prove, and what a later slice must:
a peer on a **different** machine - the spike fetches its own listener,
so the traffic never leaves the host, and a loopback or same-subnet
path proves the seam but not the network; more than one connection in
flight at once, which the per-connection slots make room for but the
spike does not exercise; and the wake-up path that a self-pipe would
give. The macOS Local Network permission is also still untested by the
spike: it is asked the first time an app opens a socket to a
local-network address, which is exactly what the LAN bind does, and a
machine that has never been asked will show the prompt. The packaged
apps carry their own `NSLocalNetworkUsageDescription`; the kiosk's
install grants it by hand
([release runbook](../operations/release.md)).

### Why the client is `fx.fetch` and not a socket

The client half of the protocol is ordinary SDK effects. That means:

- it is journaled, so a recorded session replays;
- it is cancellable, so a request in flight can be dropped by key;
- it is testable against the fake executor, with no socket in the test;
- it is timed out and bounded by the SDK, not by our discipline.

Only the server half is ours. A peer is both, so each app carries a
listener - but the listener is a byte pipe, and the app is the only
thing that knows what a byte means.

## The protocol

HTTP/1.1 over raw TCP. The default port is **45871**, and a device
advertises the port it actually bound (see [Discovery](#discovery)).
Bodies are NDJSON: one JSON object per line,
`Content-Type: application/x-ndjson`.

HTTP is chosen over a bespoke framing for three reasons: `fx.fetch`
speaks it, so the client needs no code; it is debuggable with `curl` and
`nc` from a support laptop; and it is a framing that a future web client
could speak without a second protocol.

### Endpoints

| Endpoint | Direction | Body | Purpose |
|---|---|---|---|
| `GET /v1/hello` | peer → peer | — | The peer card: device id, role, protocol version, app version, local clock |
| `GET /v1/ops?since=<cursor>` | peer → peer | NDJSON out | A page of durable ops the cursor does not already cover; `409` when the cursor is below the compacted floor |
| `POST /v1/ops` | peer → peer | NDJSON in | Ops this peer produced |
| `GET /v1/reference?after=<version>` | admin → peer | NDJSON out | Admin-owned reference rows above a version |
| `GET /v1/snapshot?after=<seq>` | peer → peer | NDJSON out | One page of a compacted base state, for a device that joins late or fell below the floor |
| `GET /v1/events` | peer → peer | NDJSON out | A long-lived stream of push notifications |

`GET /v1/events` is the push path. The server holds the response open
and writes a line as something happens; the client reads it with
`fx.fetch` in `.stream` mode, and each line arrives as a `Msg`. A
poll on a timer is the fallback, and the two coexist: the stream makes
the common case immediate, the poll makes the system converge even if
the stream is dropped.

**As built.** The response is chunked NDJSON and the line is
`{"seq":N}\n`, where `N` is the server's op-log sequence at the time of
the write; a heartbeat line keeps an idle connection honest. The server
gives each stream its own thread and watches a shared atomic sequence
every 20ms, so the listener keeps accepting. The client holds one
stream per peer, and a line pulls that peer's ops from the cursor; a
pull already in flight sets `sync_pending`, and the answer issues
exactly one follow-up. A terminal or timeout clears the stream key and
the five-second poll reopens it. The line never carries the op: a
missed line costs latency, never state.

### Records

An operation is one line:

```json
{"id":"dev-3:1042:7","entity_table":"order","entity_id":"O-000123",
 "operation":"create","logical_clock":1042,"device_id":"dev-3",
 "created_at":1758000000000,"data":{"table_id":12,"status":"pending"}}
```

| Field | `op_log` column | Meaning |
|---|---|---|
| `id` | `id` | Globally unique: `<device_id>:<clock>:<sequence>` |
| `entity_table` | `entity_table` | What the operation touched |
| `entity_id` | `entity_id` | The row's key; for an order, status or payment, the order id on the origin device |
| `operation` | `operation` | `create`, `update` or `delete` |
| `logical_clock` | `logical_clock` | The Lamport counter of the writer |
| `device_id` | `device_id` | The writer. For a create this is normally the origin device; for a status or payment it can be a device that only holds a remapped copy. |
| `created_at` | `created_at` | Epoch milliseconds |
| `data` | `data_json` | The row snapshot after the operation |

The wire names are the column names, so the table and the wire are the
same record and only two things differ:

- `data_json` is a JSON **string** in the column and a nested **object**
  on the wire. It is the same value in two encodings, so the codec is
  parse-into-an-object on the way in and serialise-on-the-way-out, not
  a translation.
- Three columns are **not carried**: `previous_json`, `host_id` and
  `parent_id`. They only had meaning under the host-elected sidecar
  that this design replaces - a host, and a causality chain between
  hosts. The receiving side writes `'{}'` and `''` for them. They are
  columns in a shipped migration, so they stay; a later migration can
  drop them.

An operation is **idempotent**: applying one whose `id` is already known
is a no-op, which is what makes a repeated delivery, a reconnect and a
re-ask all safe.

Two rules govern every value on the wire:

- **Money is an integer in minor units.** No float crosses the wire, and
  the decoder rejects a fractional part rather than truncating it.
- **Time is epoch milliseconds.** One shape for every timestamp.

### Order identity on the wire

The op's `device_id` is the writer, and the vector cursor is keyed by it.
It is not the order's cross-device name. An order's stable name is the
pair `(origin_device, origin_id)`: the device that took the sale and
that device's local order id.

- A create op carries `origin_device` in its snapshot. The receiver uses
  it; a create written before the origin columns existed falls back to
  the op's `device_id`.
- A status or payment op carries `origin_device` too, because the writer
  may only hold a remapped copy. The receiver resolves the pair to its
  own local id. The id in the snapshot is the origin id, not the
  receiver's row key.
- A local order keeps a positive `orders.id`; an order received from a
  peer gets a negative local id. Lines are namespaced under the local
  order id (`local_order_id * 128 + index`), and the line id on the wire
  is informational.
- `entity_id` for an order, status or payment is the origin order id.

See [ADR-0019](../decisions/0019-cross-device-order-identity.md).

### Clocks

There is no leader, so the clock cannot be a single number that means
"everything I have seen". Each device has its own Lamport counter, and
the counters of different devices are unrelated.

**Writing.** Before it writes an op, a device sets
`logical_clock = max(its own clock, the highest clock it has seen from
any source) + 1`. That is the rule the sidecar used to apply, now
applied by the writer itself, because the sidecar is gone.

**The cursor is a vector.** A device that has applied ops from three
peers has three separate positions, one per source, and a single
scalar cursor cannot express them. The cursor is therefore a map from
device id to the highest `logical_clock` applied from that device:

```
GET /v1/ops?since=dev-1:1042,dev-3:87
```

and the peer answers with every op whose `(device_id, logical_clock)` is
above the cursor **for that device**.

Why a scalar is wrong, concretely: device C is partitioned. B takes an
order at B's clock 20. A takes an order at A's clock 500. C reconnects,
pulls from A first - its cursor for A becomes 500 - and then pulls from
B with a single scalar of 500. **B's op 20 is below the cursor and is
never delivered**, and C silently never converges. The vector cursor
does not have this failure, because B's position is tracked separately
from A's.

The `id` of an op stays `<device_id>:<clock>:<sequence>`, so a repeated
delivery is still recognisable without trusting the cursor.

### Discovery

There is no mDNS in the SDK, so discovery is a **UDP broadcast beacon**
on port **45872**, sent every five seconds:

```json
{"proto":"ros/1","device":"dev-3","role":"kds",
 "host":"192.168.1.42","tcp":45892}
```

The `role` is the **device table's vocabulary** - `admin`, `waiter`,
`kds` or `display` - because that is what `device.role` accepts
(`src/schema/0010_sync.sql` constrains it with a CHECK, and that table
is in the shared schema all three apps migrate). The kiosk *app* has
two modes, and the device row records the mode it is in: `kds` on a
kitchen screen, `display` on a customer-facing one. A peer that reads
`kds` knows to expect tickets, and one that reads `display` knows to
expect a status board.

The role travels with the beacon, so a peer learns both that a device
exists and whether it is the admin it should ask for reference data.

**The port is chosen at bind time and advertised.** Nothing listens on a
fixed port by default, because three apps on one machine - which is how
this is developed and demonstrated - would collide on one. A device
binds an ephemeral port and puts the port it got into its beacon. The
fixed port is a convenience for the admin app only, and even there it is
a fallback to the ephemeral one.

Broadcast is blocked by some managed and guest networks, and macOS asks
the user for Local Network permission the first time a socket is used.
The packaged apps carry their own `NSLocalNetworkUsageDescription`, so
the prompt is in the app's words; the kiosk's install grants it by hand
([release runbook](../operations/release.md)). So every app also accepts
a **manually configured peer address**, and the admin app keeps a list
of the devices it has seen. A restaurant that blocks broadcast
configures one address per device and never thinks about it again.

### Bootstrap and compaction

A device that has never seen the restaurant asks for `/v1/ops` with an
empty cursor and replays the durable log. The log is the history, so
replay *is* the state while the range still exists.

The log does not grow without bound. A SQLite trigger keeps a durable
`ops_since_compact` counter; after 128 new ops the app compacts the log
into a snapshot and keeps the last 64 clocks per device. The highest
deleted clock for each device is the **floor**, stored in `sync_state`.
Compaction writes the snapshot metadata and its lines, deletes the range
below the floor and marks the retained rows in one transaction.

The snapshot is NDJSON: a header line carrying the format version, the
snapshot generation, the per-device clocks it was taken at, and the page
position; then synthetic `create`, `order_status` and `payment` ops for
the current state. The lines are ordinary wire ops, applied through the
same idempotent path as a live op, with no op-log write and no cursor
move per line. The receiver adopts the header clocks only after the last
page, using the per-device maximum, so an interrupted bootstrap starts
again from the top.

A peer whose cursor does not cover the floor cannot replay the missing
range. `/v1/ops` answers:

```json
{"error":"snapshot required","snapshot":"/v1/snapshot"}
```

with status `409`. The client resets its snapshot position, pages
`/v1/snapshot?after=0` until the header says `done`, adopts the clocks,
and then pulls the tail above them. A device that has been offline for a
week therefore converges: the snapshot covers the week, and the tail
covers what happened while it was reading.

Both reads are async: the net thread parks the connection, the loop
thread reads SQLite and answers. One pending answer slot is enough
because the net thread is serial; a competing short request while a read
is in flight gets `503`. A page is bounded by the 32 KiB frame. An op
page that fills before its row limit is progress: the lines that fit are
sent and the next pull resumes above the last clock. A single op or
snapshot line that cannot fit in an empty frame is refused with `413`
rather than split.

The snapshot covers current orders, their lines, the current status and
payments. It does not carry status history, voided drafts or reference
data: a late joiner still gets the menu from the admin's
`/v1/reference` document. An admin that is closed cannot seed a
brand-new device's menu, but it is not needed for the restaurant to keep
selling.

## Who owns what

The rule is that a conflict is impossible wherever it can be made
impossible, and only accepted where it cannot.

| Entity | Writer | How it reaches other devices | Merge |
|---|---|---|---|
| Company, settings, tax slabs, printers | `admin` | `GET /v1/reference` | The admin's row wins; a peer accepts only a newer version |
| Employees and PINs | `admin` | `GET /v1/reference` | Same - but see [The sign-in problem](#the-sign-in-problem) before trusting this row |
| Product categories, products, modifier groups | `admin` | `GET /v1/reference` | Same |
| Dining tables, table categories | `admin` | `GET /v1/reference` | Same |
| Customers | the device that created the row | ops | Last writer - on the **vector** clock and then the device id, because two devices' scalar clocks are not comparable |
| An order's content and its lines | the device that created the order | ops | Single writer - nobody else writes it |
| An order's status | any device | ops | Monotonic: the furthest along wins |
| Payments | the device that took the money, `admin` or `service` | ops | Single writer, idempotent by request key ([ADR-0014](../decisions/0014-order-identity.md)) |
| Devices | each device, for itself | ops | Insert-only |

The counter POS is the service app's, so the device that takes the
money is usually the waiter's tablet or counter terminal
([ADR-0021](../decisions/0021-counter-pos-is-the-service-app.md)). The
payment is an op like any other: the device that took it owns it, and
the order's status transition is the idempotency key, so a second tap
finds the order closed and writes nothing. The admin app can still take
a payment as the wildcard superset; the kiosk cannot.

Two properties fall out of this and both are worth stating plainly:

- **Reference data cannot conflict.** One writer means there is never a
  second opinion about the menu.
- **Order status cannot conflict.** The status machine only moves
  forward, so "furthest along wins" is not a heuristic - it is the
  merge of two monotonic values.

What is left is the genuinely hard case, and it is already an open
question in the plan: two waiters editing the same table's order at the
same time ([`open-questions.md` A20](../plan/open-questions.md)).

## The sign-in problem

**This is a blocker, and it is not solved by the protocol.** It is
recorded here because the three apps cannot work without settling it,
and because a reader who takes the ownership table at face value will
build the service app and then find that no waiter can sign in.

The mechanism, as it stands:

- `data/auth.zig` `hashPin` derives the bcrypt salt from the
  **installation salt** (`deriveSalt`), so a hash is a function of
  (installation salt, PIN) and of nothing else.
- `data/repos.zig` `login_sql` finds the employee by **matching the
  computed hash for equality**:
  `WHERE (pin_hash = ?1 OR pin_hash = ?2) AND role = ?3 AND active = 1`.
- `data/auth.zig` says why it is written that way: a random
  per-employee salt "would mean trying every employee in turn, and a
  slow hash for each of them".
- The installation salt is generated once per **installation**
  (`main.zig` calls `auth.makeSalt`) and stored in `app_config.pin_salt`
  by `repos.saveSalt`, which is `ON CONFLICT DO NOTHING` - written once
  and never replaced.

Each app has its own database in its own data directory, so **each app
has its own installation salt**. The employee hashes were computed
against the admin app's salt. The service app computes
`hashPin(service_salt, "123456")`, which is a different bcrypt string
from the stored one, the equality match misses, and **the waiter cannot
sign in** - including in exactly the case the design is built for: the
admin app is closed.

There are two ways out.

### Option A - replicate the installation salt

The salt becomes reference data owned by the admin app, exactly like the
employee rows. The service app stores it and the existing sign-in path
works unchanged: no schema change, no migration, no UX change.

The cost is that a **shared secret crosses the wire in plain HTTP**,
and a stolen service device's database becomes as crackable as the
admin's is today. It also contradicts the security claim below.

### Option B - the salt becomes per employee

`employee` grows a per-employee random salt. A bcrypt crypt string
already embeds its own salt, so the row becomes **self-verifying**: any
device holding the row can verify the PIN with one `bcrypt.strVerify`
and needs nothing else.

The sign-in then has to identify the employee before it hashes - which
is exactly the follow-up ADR-0016 already records: *"The per-employee
salt, when the sign-in can identify the employee before it hashes: an
employee picker makes the salt per employee and the login one hash."*
The alternatives are an employee picker (one hash) or trying the
active employees of that role in turn (one hash each, a few hundred
milliseconds at cost 2^10).

The cost is a schema migration and a sign-in flow change, which is a
product decision.

### The recommendation

**Option B.** It is the one that keeps the wire free of a shared
secret, it is the recorded follow-up of an accepted decision, and it
makes a replicated employee row self-verifying - which is the property
the whole three-app design needs. Option A is cheaper to build and
weakens the threat model in a way that is awkward to undo later, because
once a secret has crossed a wire in plaintext it has crossed it.

The question belongs to the product as much as to engineering, so it is
[open question D19](../plan/open-questions.md) and it must be answered
before the protocol is frozen - not during the implementation of it.

**It is answered: the salt becomes per-employee**, by
[#95](https://github.com/devstroop/ros/issues/95) - the sign-in
identifies the employee before it hashes, so the row is self-verifying
and no shared secret crosses the wire. That issue also plans the picker
*in place of the role picker*, which the three-app split makes
convenient: the `service` app signs in by picking an employee, and the
role picker is only still needed by `kiosk`, for the choice between the
kitchen board and the customer display.

Whichever way it goes, one thing is settled now: **the employee row
replicates as reference data, and the row must contain everything a
device needs to verify a PIN offline.** A row that needs a second,
separately replicated secret is the thing to avoid.

## Failure modes

| Failure | What happens | What it costs |
|---|---|---|
| A device is off | The others keep working. Reference data is the last version they received; orders keep their own writers. | Nothing, until the device returns |
| The admin app is off | The till keeps selling; the kitchen keeps cooking. Only *changes to the menu* wait. | New catalogue edits are deferred |
| The network is down | Every device writes locally and queues its ops. The orders are taken. | Convergence is late, not lost |
| A peer is unreachable | The fetch fails, is classified, and is retried on the next tick | A stale board for a moment |
| A frame is dropped | The channel's back-pressure drops it; the pull path asks again from the cursor it held | A duplicated request, never a lost order |
| A duplicate op arrives | Applying an op whose id is known is a no-op | Nothing |
| Two devices write the same order's status | Both advance; the merge keeps the furthest along | Nothing |
| A device is removed from the restaurant | Its ops stay in the log; its reference rows stop being served | Needs a policy - see the follow-ups |
| The protocol version differs | `/v1/hello` reports it and the peer refuses to talk | A device must be updated |

## Security

The trust model is a trusted LAN, and it is a decision rather than an
omission: a restaurant's devices sit on a network the owner controls,
and the alternative - pairing, certificates, a key exchange - is a
second product.

What that means concretely:

- Every peer can read the reference data and the ops. A device that
  joins the LAN is a device in the restaurant.
- **PINs are never sent.** The digits a cashier types never leave the
  device. What crosses the wire is the **hash** - and, under the salt
  as it stands today, the **installation salt** as well, because the
  hash is computed from it. That is why
  [the sign-in problem](#the-sign-in-problem) has to be settled before
  this section can be called accurate: a peer must receive a row it can
  verify a PIN against, and the salt question decides whether that row
  is self-verifying or whether a shared secret has to travel with it.
- Money is never trusted from a peer: an order's total is recomputed
  from its lines by the device that owns the order.
- The wire is plain HTTP on the LAN. It is readable by anyone on the
  wire, and that is a known, accepted cost.

The follow-up is peer authentication: a shared secret in the admin app's
settings, presented in `/v1/hello`. That is a small change to one
endpoint and it should be decided before the first restaurant runs on
this.

## The shared package

```
apps/
  admin/
    app.json                 id: com.devstroop.ros.admin
    src/main.zig             the role constant, the shell
    src/app.native           mounts the admin screens
    src/app_sources.zig      the import closure
  service/
    app.json                 id: com.devstroop.ros.service
  kiosk/
    app.json                 id: com.devstroop.ros.kiosk
packages/
  ros-core/
    build.zig  build.zig.zon
    src/
      core/     model, msg, update, navigation, rbac, theme, bump
      data/     repos, page, auth
      domain/   models
      net/      the protocol: frames, the client, the server, discovery
      schema/   0001..0015_*.sql and the migration lock
```

Each app ejects its build (`native eject`) so it owns a `build.zig` that
depends on `packages/ros-core` as a path dependency and adds the
shared module as an import. The generated build graph is regenerated by
the CLI on every `native dev`, so the dependency has to live in the
ejected file.

`scripts/verify-all.sh` and `scripts/build.sh` already loop over
`apps/*/`, so three apps are picked up without changes.

The schema stays in the shared package, so all three apps run the same
migration chain. That is what keeps the op log and the reference rows
meaningful across the three databases.

## What is not decided here

- **The PIN salt.** The sign-in problem above is a blocker: either the
  installation salt replicates as reference data, or it becomes
  per-employee. The second is the recommendation, and it is a product
  decision as much as an engineering one.
- ~~Whether the counter POS is the `admin` app or the `service` app.~~
  **Decided:** the counter POS is the `service` app, and the `admin` app
  remains the wildcard superset
  ([ADR-0021](../decisions/0021-counter-pos-is-the-service-app.md)).
- Peer authentication (see Security).
- Whether a removed device's ops are retained.
- Whether the snapshot should carry status history for the admin's
  audit screens.
- The port numbers, which are a proposal, not a reservation.

The PIN salt and peer authentication are tracked as open questions;
the counter POS is settled. The rest belong to the phase that needs
them.

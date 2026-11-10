# ADR-0019: Cross-device order identity

> **Status:** Accepted
> **Date:** 2026-10-24
> **Deciders:** Devstroop maintainers
> **Related:** [ADR-0014](0014-order-identity.md),
> [ADR-0009](0009-oplog-sync-with-transport-sidecar.md),
> [ADR-0017](0017-three-apps-over-tcp-ip.md),
> [`architecture/12`](../architecture/12-three-apps-and-ipc.md),
> [`architecture/05`](../architecture/05-schema.md),
> [`plan/status.md`](../plan/status.md)

## Context

ADR-0014 settled the identity of a sale inside one database:

- `orders.id` is the wall clock in milliseconds, with a per-device floor;
- `orders.order_no` is a database sequence;
- the request key is this device's token plus the attempt id, so a retry
  is the same sale.

That is enough for one device. It is not enough for two databases. Two
devices can take a sale in the same millisecond and mint the same
`orders.id`. The request keys are device-scoped, so neither device can
mistake the other's sale for a retry, but the op log still needs a name
for the sale that both databases can agree on.

The first attempt at a merge used `orders.id` as that name. It works
until the ids collide, and then the second create op is dropped or
overwrites the first. There is a second, less obvious case: a device
that holds a remapped copy of an order can advance it or take its
payment. That op is written by the remapped device, so the writer's
`device_id` is not the device that took the sale. A status or payment
op that names the writer's local id cannot be applied by the origin
device.

The op log already has a vector cursor keyed by the writer, and that
must stay the writer: it is what makes a repeat, a reconnect and a
re-ask safe. The order's identity therefore has to be carried separately
from the op's writer.

## Decision

**An order has a local row key and a stable cross-device name.**

1. **The local key stays an `i64`.** `orders.id` is still what lines,
   status history and payments point at. A local sale keeps a positive
   id. A sale received from a peer gets a **negative** id, allocated
   from the negative side of the range:

   ```sql
   COALESCE((SELECT MIN(id) FROM orders WHERE id < 0), 0) - 1
   ```

   Local ids are positive, so the two namespaces cannot meet. The
   negative id is local to the receiving database; it is not sent as
   the order's identity.

2. **The stable name is `(origin_device, origin_id)`.** Two columns on
   `orders` hold the device that took the sale and that device's local
   order id. A local sale stores its own device and id. A received sale
   stores the create op's origin. `origin_id` is the id in
   `OrderSnapshot.id`; `origin_device` is in the snapshot (and falls
   back to the op's `device_id` for creates written before this
   change).

3. **A create op is idempotent by origin.** The order insert is
   conditional on the origin pair not already existing, and a partial
   unique index on `(origin_device, origin_id) WHERE id < 0` is the
   backstop for remote rows. A repeated create op, or a peer echoing a
   local order back, writes no second order and consumes no second
   order number.

4. **Status and payment ops carry the origin, not the writer's local
   id.** `OrderStatusSnapshot` and `PaymentSnapshot` carry
   `origin_device`; their id fields are the order id on that device.
   The receiver resolves the pair to its own local id. This is what
   lets a device that only holds a remapped copy advance or pay the
   order and have the change converge on the origin.

5. **The op's `device_id` remains the writer.** It is the vector-cursor
   key and the idempotency namespace. For a create op it normally equals
   the origin device; for a status or payment op written on a remapped
   copy it does not. The op's `entity_id` is the origin order id.

6. **Line ids are namespaced under the local order id.** A local order
   line is `local_order_id * 128 + index`; a received line is
   `receiver_local_order_id * 128 + index`. The line id on the wire is
   informational; the receiver does not trust it, because two devices'
   line ids are not comparable. The multiplier leaves room for the
   sixty-four lines an order may carry.

7. **Old data is backfilled, and old ops still apply.** Migration
   `0016_order_origin.sql` sets `origin_id = id` and takes
   `origin_device` from the create op in `op_log`; a draft with no
   create op has an empty origin and is treated as local. A status or
   payment op with no `origin_device` falls back to the old rule, where
   the local id was the origin id.

## Consequences

### Positive

- Two devices can mint the same wall-clock id and both sales survive
  the merge as two rows.
- A third device can tell them apart by origin, even when the ids are
  equal.
- A remapped device can advance or pay an order and the origin device
  applies the change to the same sale.
- The local row key stays cheap and sortable, and the local retry
  semantics from ADR-0014 do not change.
- The op log's idempotency rule is untouched: the cursor is still per
  writer, and an op's id is still globally unique.

### Negative

- A remote order has a negative local id. Anything that displays or
  exports an id must not assume it is positive, and a local id is not
  comparable with the same-looking id on another database.
- The origin pair is two columns and an index on every order, not a
  single opaque key. The queries that map a status or payment to an
  order carry the pair.
- The local row id and the origin id can differ. A repair or a test can
  write a row whose origin belongs to another device; that is supported,
  but it is a second name to keep straight.
- The device token is generated at boot and is not persisted. An order's
  stored origin does not change across a restart, but the next boot's
  device id is new. Persisting the token is a follow-up; it does not
  break the origin pair because the pair is stored per order.

## Alternatives considered

- **A UUIDv7 or ULID for the id.** Rejected in ADR-0014 and still
  rejected here. It moves the schema, the model and every child foreign
  key to a 128-bit value, and the merge would still need an origin for
  the status and payment ops written by a remapped device.
- **A device-prefixed integer.** Rejected: a prefix would have to fit
  in the same `i64` as the wall clock, which leaves too few bits for a
  device namespace and a time-ordered id, and it changes the meaning of
  every existing id.
- **Renumbering at merge time.** Rejected: the merge would have to
  rewrite child rows and in-flight ops, and a peer that reconnects after
  a renumber would need a second mapping to understand the old op log.
- **A separate `order_origin` mapping table.** Rejected: it is a second
  row per order and a second insert on the apply path. The origin columns
  keep the mapping on the order itself, which is also where the local
  retry and the order number already live.
- **Letting the writer's `device_id` name the order in status and
  payment ops.** Rejected: the writer may only hold a remapped copy.
  The origin is the only device that can name the sale consistently.

## Follow-ups

- Persist the device token so a restart does not create a new device
  identity for future orders and cursors.
- The snapshot and compaction work (#111) must preserve the origin
  columns and the per-device cursors; a late joiner needs both the rows
  and the clocks.
- Reports and exports should use `origin_device`/`origin_id` when they
  need a cross-device name, not the local `orders.id`.

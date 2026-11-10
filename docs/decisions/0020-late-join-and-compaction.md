# ADR-0020: Late join, snapshots and log compaction

> **Status:** Accepted
> **Date:** 2026-10-24
> **Deciders:** Devstroop maintainers
> **Related:** [ADR-0009](0009-oplog-sync-with-transport-sidecar.md),
> [ADR-0017](0017-three-apps-over-tcp-ip.md),
> [ADR-0019](0019-cross-device-order-identity.md),
> [`architecture/12`](../architecture/12-three-apps-and-ipc.md),
> [`architecture/05`](../architecture/05-schema.md),
> [`plan/phase-9`](../plan/phase-9-three-apps-and-ipc.md),
> [`plan/status.md`](../plan/status.md)

## Context

The op log is the history of the restaurant, and replaying it is how a
peer catches up. That works while the history is small. It does not work
for a device that joins a restaurant after a year of service, and it does
not work for the database on the device that has been there the whole
time: the log grows without bound, and every new device pays for all of
it.

Two things are needed, and they pull in opposite directions:

- **A new device must start from the current state**, not from the first
  sale ever taken.
- **A device that was offline must not miss an op** because the peer it
  asks has thrown that part of the history away.

The op log is also the source of `/v1/ops`. Serving from a bounded
in-memory cache made the answer depend on which ops a process happened
to remember; a restart or a long pull could silently lose the middle of
a range. The durable `op_log` is the only honest source.

## Decision

**The log is compacted into a snapshot, and the floor is part of the
protocol.**

1. **Compaction is driven by a durable counter.** A SQLite trigger on
   `op_log` maintains `sync_state('ops_since_compact')`. The app compacts
   after 128 new ops, not after a fixed time and not on a timer. A
   restart does not reset the counter, so a process that is restarted
   often still compacts when the log has grown.

2. **Compaction keeps a tail, not the whole history.** For each device
   whose cursor is above the retention, the log keeps the last 64
   clocks. Everything below `cursor - 64` is deleted. The highest deleted
   clock per device is `op_floor`, stored in `sync_state`.

3. **A snapshot is the current order state, encoded as ordinary ops.**
   One header line, then synthetic `create` lines for current orders
   (with their lines), one `order_status` line with the current status,
   and one `payment` line per payment. It deliberately does **not**
   carry status history, voided drafts, reference data or the device
   table: those are either history, another owner's data, or not needed
   to serve.

4. **Snapshot lines apply through the live idempotent path.** The
   synthetic op is decoded and handed to the same apply function as a
   live op, with `persist = false`. It writes the row but no `op_log`
   row, and it does not move the cursor line by line. A create is a
   no-op when the origin pair is already present; a status only moves
   forward; a payment is keyed by the order. A snapshot is state, not a
   second history.

5. **The header carries the clocks, and they are adopted last.** The
   header names the vector cursor the snapshot was taken at. The receiver
   applies every page first, then adopts the clocks with
   `cursor.Vector.observe` (per-device maximum). An interrupted bootstrap
   therefore restarts from the top; it can never leave the cursor ahead
   of the rows.

6. **`/v1/ops` is served from the durable log, filtered by a vector
   cursor.** The cursor is a vector of per-device clocks, not a single
   number, because one device's high clock must not hide another
   device's first op. The wire carries it as `dev:clock,...`; the query
   converts it to a JSON object for SQLite's `json_each`. The answer is
   paged by the 32 KiB frame limit, and the requester's cursor advances
   only over the lines that fit. A page that fills before its row limit
   is progress: the lines that fit are sent, and the next pull resumes
   above the last clock. Only a single op that cannot fit in an
   otherwise empty frame is refused with 413.

7. **A cursor below the floor is a 409, not a partial answer.** If the
   requester's cursor does not cover `sync_op_floor`, `/v1/ops` returns
   `409 {"error":"snapshot required","snapshot":"/v1/snapshot"}`. The
   client resets its snapshot position, fetches `/v1/snapshot`, applies
   it, and then pulls the tail above the adopted clocks. A 409 is a
   normal convergence path, not an error the operator sees.

8. **Snapshots are stored, not rebuilt per request.** Compaction writes
   `sync_snapshot` (version, clocks, created_at) and
   `sync_snapshot_op` (version, seq, line). `/v1/snapshot` pages over
   those rows with `after`/`next`/`done`. Rebuilding the base state from
   live tables on every request would race the sale in progress and
   would make the clocks a guess.

9. **Reads are async, one at a time.** Both endpoints read the database
   on the loop thread through the effects channel, not on the net thread.
   One pending answer slot is enough because the net thread is serial; a
   second short request while a read is pending gets 503 rather than
   racing the slot.

## Consequences

### Positive

- A new device joins in snapshot-sized work, not history-sized work.
- A device that was off for a week converges: the 409 points it at the
  snapshot, and the tail covers what happened while it was reading.
- The database does not grow with the age of the restaurant.
- The op log has one meaning again: the durable history above the floor,
  served in order, with a cursor the receiver can resume from.
- Compaction is one transaction. A crash leaves either the old log and
  metadata or the new snapshot and floor, never a half-deleted range.
- Snapshot lines cannot invent a second write path: they are the same
  ops, applied by the same code.

### Negative

- The snapshot is a second copy of current state. It costs disk roughly
  proportional to the orders that are still current, and it is rewritten
  on every compaction.
- A device whose cursor is below the floor must re-read the base state.
  If it held unapplied local changes, the snapshot does not reconcile
  them field by field; the existing per-entity rules still decide.
- The retention is a constant (64 clocks per device), not an operator
  setting. A restaurant with a very slow device and a very busy one may
  want a larger tail later.
- The snapshot does not include reference data. A late joiner still
  needs the admin's `/v1/reference` document, and an admin that is closed
  cannot seed a brand-new device's menu.
- A 32 KiB frame bounds one snapshot line. An order with more lines than
  fits is refused with 413 rather than split; the line cap (64) keeps
  that theoretical for now.

### Neutral / follow-ups

- Retaining status history in the snapshot would let the admin's audit
  screens work on a late joiner; today they read the local history only.
- The compaction threshold and the tail are constants in `model.zig`;
  making them configurable is a settings question, not a protocol one.
- The device token is still per-process (ADR-0019), so a restart looks
  like a new cursor namespace. Persisting it is the same follow-up.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Replay the whole log to every new device | Unbounded join time and unbounded storage; a year-old restaurant takes minutes to join and the log never shrinks. |
| Compact to a single scalar clock | Two devices' clocks are not comparable. A scalar would hide a peer's first op behind another peer's high clock. |
| Rebuild the snapshot from live tables on each request | The sale in progress races the read, and the clocks would describe a state that never existed as one transaction. |
| Delete the log and keep only live tables | A peer that was offline has no way to learn what changed, and the 409 would have no tail to point at. |
| A separate snapshot database or file | A second store to back up, restore and keep consistent; the same SQLite transaction already gives atomicity. |
| Keep the in-memory cache as the `/v1/ops` source | It is a hint, not state. A restart or a long pull loses the middle of a range, and the receiver cannot tell. |
| Compact on a timer | A quiet restaurant would rewrite the same snapshot, and a busy one would compact mid-service on the clock rather than on growth. |

## Evidence

- `packages/ros-core/src/data/repos.zig`: `compactSyncLog`,
  `maybeCompact`, `onSyncCompacted`, `writeSyncOpsPage`,
  `writeSyncSnapshotPage`, `applySnapshotOp`, `adoptSnapshotCursor`.
- `packages/ros-core/src/net/snapshot.zig`: header format and tests.
- `packages/ros-core/src/core/net_bridge.zig`: async `/v1/ops` and
  `/v1/snapshot`, the 409 floor check, and the client bootstrap flow.
- `apps/admin/src/schema/0017_sync_snapshot.sql`: the tables, the
  retention index and the durable counter trigger.
- `apps/admin/src/tests_data.zig`: the compaction test (floor, retained
  tail, snapshot page, late joiner with no op-log rows), the week-off
  convergence test, the three-device test with the admin closed, and the
  op-page test (a full page makes progress, the next pull gets the rest).
- `apps/admin/src/tests.zig`: the client turns a 409 into a snapshot
  fetch from the top.

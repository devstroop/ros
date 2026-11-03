# ADR-0024: A ticket closes with its money

> **Status:** Accepted
> **Date:** 2026-11-04
> **Deciders:** Devstroop maintainers
> **Related:** [ADR-0014](0014-order-identity.md) (the ticket the
> lifecycle belongs to), [ADR-0019](0019-cross-device-order-identity.md)
> (the order an op names by its origin pair),
> [ADR-0020](0020-late-join-and-compaction.md) (the snapshot pages that
> forbid a schema-level constraint),
> [ADR-0005](0005-engine-owned-sqlite-strict-schema.md) (where a rule
> like this would live if SQLite could state it),
> [`architecture/04`](../architecture/04-data-layer.md),
> [`architecture/05`](../architecture/05-schema.md),
> [`architecture/08`](../architecture/08-sync.md),
> [#139](https://github.com/devstroop/ros/issues/139),
> [#143](https://github.com/devstroop/ros/issues/143),
> [#144](https://github.com/devstroop/ros/issues/144)

## Context

The order lifecycle has one step that is not a step in the kitchen's
story: `pending → preparing → ready → served` is cooking, and `served →
completed` is money. The app has always said so. `update` refuses to
advance a ticket that has not been paid for - "Take the money before
closing the order" - and `takePayment` writes the payment row and the
close in one transaction, so a closed ticket and a collected bill are
the same event.

The refusal only ever existed in `update`. `setOrderStatus` - the write
`update` calls, and the write anybody else can call - conditioned its
`UPDATE` on the status the caller held and said nothing about payment,
and `applyOrderStatus` accepted any status an op carried that moved the
ticket forward. So the rule was a policy at one call site, not a
property of the data. Three roads led around it:

- **A peer on an older build.** A status op is a status op. A device
  that has not been upgraded asks this one to park a ticket in
  `completed`, and this one obeys.
- **A replay, or a snapshot page**
  ([ADR-0020](0020-late-join-and-compaction.md)), which carries the
  order's row - status included - and its payment rows separately,
  arriving in whichever order the log delivers them.
- **The next screen.** A guard that lives in the reducer is a guard for
  the reducer. A KDS that closes a ticket it believes is paid, a repair
  tool, a test harness: none of them pass through `update`.

The state on the other side of those roads is not untidy; it is
uncollectable. `paid` is read from the payment rows a
ticket has (`repos.orders_sql` counts them), so an unpaid closed ticket
shows a Pay button, and `takePayment` refuses the tap with "That order
is already paid" ([#143](https://github.com/devstroop/ros/issues/143)).
And a table is only ever freed by a payment or a void, so the ticket
keeps the room: the floor plan shows a party that left, and the next
waiter is told the table is taken
([#144](https://github.com/devstroop/ros/issues/144)). There is no
reopen path and no "record a late payment" screen, because until now
nobody needed one.

The forces that decide where the rule goes:

- **The database is the one that decides.** Every write here is
  conditional SQL - `WHERE status = the status the caller held` - so
  that two taps and two devices produce one move. The payment rule is
  the same kind of fact and is asked in the same sentence or it is not
  asked at all.
- **A refused write must not be announced.** That machinery only
  arrived with `c3f71fa`: an op and a clock that ride `changes()` of the
  write that made them. With it, a statement-level refusal is a refusal
  on the wire too; without it, guarding the statement would have
  broadcast a status the order never had.
- **A constraint cannot see another table.** A `CHECK` on `orders`
  cannot mention `payment`, and a row trigger on `orders` that demands a
  payment would reject ADR-0020's snapshot page, where the order row
  legitimately arrives before the money does. The rule is a property of
  a *transition*, and SQLite has no place to write it.
- **Rows that already exist are the owner's problem.** An owner with a
  till that closed a ticket unpaid cannot be told to re-enter the sale.
  Whatever happens must not invent money.

## Decision

**Closing a ticket is money's step, and the statement says so.**
`completed` may not be written by a status move - locally or over the
wire - unless a `payment` row is already behind the order.

1. **The guard is in both writers, in the SQL.** `setOrderStatus` gained
   `AND (?2 <> ?5 OR EXISTS (SELECT 1 FROM payment WHERE
   payment.order_id = orders.id))` on its `UPDATE orders`, and the
   matching `EXISTS` inside the guard on its history insert;
   `applyOrderStatus` gained the same clause on the update it applies for
   a peer. `?5` is `completed`, bound as a parameter rather than written
   into the text, the way every other literal in this file is.
2. **`update` keeps its refusal.** The database can say no; it cannot
   say *why* to the person who pressed the button. The message is the
   operator's half of the same rule, and the two now agree because the
   statement, not the reducer, is the one that decides.
3. **A refusal is silent on the wire.** The op and the clock already
   ride `changes()` of the write. A move that the guard refused writes
   no op, burns no clock, and leaves no history row, so nothing about a
   state this order never held reaches a peer or this device's own
   history.
4. **`takePayment` and `applyPayment` are unchanged, and they are the
   only closers.** Each writes the payment row and the close in one
   transaction, and each frees the table in the same batch. A payment
   that arrives after the status did is still booked; that is the
   recovery route, and it is why `applyPayment` asks only for
   `status < voided`.
5. **A database that already holds the bad state is repaired on boot, by
   migration `0021_unpaid_closures.sql`.** Every order `completed` with
   no payment row goes back to `served`, with a matching
   `order_status_history` row. Served is where a reopened ticket lands
   because `ready` and `preparing` ring the pass, and a cook who has
   cleared the plates should not be told to bring them out again.
   `changed_at` is the order's own `updated_at` - there is no honest
   timestamp for a state the app never recorded anyone entering.
6. **The repair writes no op, and each device repairs its own copy.**
   `applyOrderStatus` moves a ticket forward, never back, so a `served`
   op arriving after a `completed` one would be refused: telling peers
   about the repair is not available on the normal route, and inventing
   a special one for it is not worth a state the guarded release cannot
   produce again. Every device that holds such a row runs the migration
   the first time it opens on this build.
7. **No schema constraint.** Not a `CHECK`, not a trigger, not a
   generated `is_closed` column. See the alternatives: the constraint
   either cannot be stated or rejects a page that is supposed to arrive.

## Consequences

### Positive

- The invariant is a property of the database, so it holds for callers
  that have not been written yet.
- #143 and #144 lose their premise. A ticket that shows Pay has no
  payment row, and such a ticket is no longer `completed`, so the dead
  click and the phantom party are both gone for a database on this
  build.
- A device on an older build cannot push this one into the state through
  a status op, and a repair tool cannot push it through the write path:
  both of them meet the statement.
- An owner's unpaid closed ticket is reopened by the app that
  upgraded it. Nothing has to be re-keyed, and no money is invented.
- The refusal is invisible to peers, which is the right shape: a state
  that never happened is not news.

### Negative

- **The clause is written twice**, once for the local writer and once
  for the apply path. That is the price of there being two writers; a
  third one has to be given it too, and nothing in the schema will
  remind whoever adds it.
- **The repair is local, and a mixed-version fleet stays broken where it
  is broken.** An un-upgraded till can still offer the dead click on a
  row it wrote itself, and it will keep sending the op this build
  refuses. The answer is to upgrade it, not to argue with it.
- **A refused status op is dropped without a trace the operator can
  see.** The op is recorded, so it will not be re-asked, and the order
  stays where it was. Nothing says "a peer asked you to close a ticket
  nobody paid for"; the Control centre counts refusals of *requests*,
  not of *states*.
- **The snapshot road stays open, on purpose.** An `order` row arriving
  from a peer's snapshot page carries its own status, and `applyOrder`
  writes it as it reads it: this device must not refuse the ticket. So a
  late joiner pointed at an old device can still end up with a completed
  order whose payment page never comes. Its status *op* is refused, and
  its money is booked when it arrives, but the row itself is not
  re-checked - only the next version bump will repair it, on migration.
  Closing that gap means giving the apply path a repair of its own, and
  that is a decision this one deliberately stops short of.
- **A reopened ticket is `served`, which may be a lie about the floor.**
  The guests may have left. It is the smaller lie: the money can be
  taken, the table can then be released, and the alternative is a ticket
  nobody can close at all.
- Reopening does not free the table, because a table is freed by money
  or a void. A reopened ticket therefore *keeps* its party - correctly,
  in the sense that the bill is still open - and the floor has to take
  the payment to clear it.

### Neutral / follow-ups

- Whether the orders list should show a reopened ticket differently -
  it is `served`, and it has been sitting since before the upgrade.
- A visible record of an op that was refused on arrival, in the same
  place the refused-request counter lives.
- The mixed-version fleet problem is the general one: a build that
  refuses a state an older build can still write needs an upgrade path,
  not a negotiation.
- A repair that runs on arrival rather than on a version bump - the same
  two statements, in the apply path, for an `order` row that lands
  `completed` with nothing paid. It has to decide whether to reopen the
  row or to refuse the ticket, and either answer is a bigger claim than
  this one. Opened as
  [#155](https://github.com/devstroop/ros/issues/155).

## Alternatives considered

| Alternative | Why not |
|---|---|
| Leave the rule in `update` only | That is what produced the bug. The reducer is one caller of a write path that has three, and two of them arrive over the wire. |
| A `BEFORE UPDATE` trigger on `orders` that rejects `completed` without a payment | It fires for the snapshot and page-replay paths of ADR-0020, where a completed order row legitimately lands before the page that carries its payment rows, and a row-level trigger has no way to tell "the money is on its way" from "the money is never coming". It also belongs to a schema the app cannot migrate out from under: the rule would be history in a file that may never be edited. |
| A `CHECK` constraint on `orders` | SQLite `CHECK`s cannot reference another table, and `status <> 4 OR paid_flag` is a second column that has to be kept in step with `payment` by every writer - a new way to be wrong. |
| Make the reopen a `void` | A void is a cancelled sale with a reason, an audit row and a stock restore. This ticket happened; only the money is missing. |
| Reopen to `ready`, or to a new `needs payment` status | `ready` and `preparing` ring the pass and wake the KDS for plates that are gone. A new status means every screen, every label and every monotonic comparison in the lifecycle learns it for a state that `served` already describes. |
| Write an op for the repair so peers agree | `applyOrderStatus` is monotonic: a `served` op behind a `completed` one is refused by design, so the op would be dropped anyway - and on a build that has the guard it cannot be produced, which is the same answer with more traffic. |
| Refuse the *op* at the HTTP edge | The edge does not know what an op means. It answers for the request; the state decision belongs with the statement. |
| Let the till collect money on a completed ticket (fix #143 by loosening `takePayment`) | That is the recovery route `applyPayment` already uses for a peer's late payment, and it makes a second local path to a state the release is trying to make impossible. The state is the bug; the button is only the symptom. |
| Leave the old rows alone and let the operator void them | A void puts stock back on the shelf and writes a cancelled sale that never happened, for a ticket whose food was eaten and whose money is simply missing. |

## Evidence

- `packages/ros-core/src/data/repos.zig`: `setOrderStatus` (the guarded
  history insert and `UPDATE orders`), `applyOrderStatus` (the same
  clause on the way in, and a history row that rides `changes()`),
  `takePayment`, `applyPayment` (the two writers that close, each with
  the money), `insert_op_if_written_sql` and
  `save_clock_if_op_written_sql`, `orders_sql`'s `paid` subselect.
- `packages/ros-core/src/core/update.zig`: `.advance_order` and the
  operator-facing refusal.
- `apps/admin/src/schema/0021_unpaid_closures.sql`, carried byte for
  byte by the other two apps.
- `apps/admin/src/tests_data.zig`: "a ticket cannot close without
  money", "a completed status op does not close an order nobody paid",
  "a ticket that closed unpaid is reopened when the database opens".
- `apps/admin/src/tests_data.zig`: "a move that matched no row writes
  no op and burns no clock" - the machinery a statement-level guard
  depends on.
- [#139](https://github.com/devstroop/ros/issues/139) - the invariant
  and where it lives; [#143](https://github.com/devstroop/ros/issues/143)
  and [#144](https://github.com/devstroop/ros/issues/144) - the dead
  click and the parked table it leaves behind.

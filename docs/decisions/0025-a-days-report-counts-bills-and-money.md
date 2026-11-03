# ADR-0025: A day's report counts the bills and the money as two figures

> **Status:** Accepted
> **Date:** 2026-11-04
> **Deciders:** Devstroop maintainers
> **Related:** [ADR-0024](0024-a-ticket-closes-with-its-money.md) (the
> reason a closed ticket owes nothing),
> [ADR-0006](0006-integer-money-epoch-ms.md) (integer minor units, so the
> difference of two sums is exact),
> [ADR-0010](0010-markup-only-no-custom-paint.md) (the screen binds
> derived model values and stores nothing),
> [`architecture/04`](../architecture/04-data-layer.md),
> [`architecture/06`](../architecture/06-ui-markup-and-theming.md),
> [`glossary`](../glossary.md),
> [#141](https://github.com/devstroop/ros/issues/141),
> [#157](https://github.com/devstroop/ros/issues/157),
> [#77](https://github.com/devstroop/ros/issues/77),
> [#78](https://github.com/devstroop/ros/issues/78)

## Context

The report screen had one big number and one table under it. The number
was `SUM(total_minor)` over the day's non-voided tickets; the table was
`SUM(amount_minor)` over the day's `payment` rows, grouped by the way it
was paid. They were labelled "TAKINGS" and "How it was paid", which
invited an owner to read the first as money and reconcile it against the
second. They are not the same fact and never were: a ticket that is
served and not yet paid for is in the first figure and not in the second,
and it is exactly the ticket that has to be chased at close.

So the day's report said two things at once and named neither. An owner
closing the night read "what we took" from a figure that counted what is
still owed, and the discrepancy grew with the number of open tables -
which is to say, it was worst on the busiest nights, when the number
matters.

There was a second, quieter mismatch in the same pair of queries. The
tickets are counted by `placed_at`; the money is counted by `paid_at`. A
ticket opened at 23:50 and settled five minutes later is yesterday's
turnover and today's cash. That is not a bug in either figure - each is
right about its own question - but two figures on one screen, both
meaning "today", cannot be reconciled by anyone who does not know which
clock each one runs on.

## Decision

1. **`report_sql` grows a sixth column.** Alongside the sums of the
   ticket's own figures it now sums, over the same set of tickets, the
   `payment` rows standing against them: `taken_minor`. One query, one
   set of tickets, both facts, so they are comparable by construction
   rather than by hope.
2. **The screen names three things.** `BILLED` is what the day's tickets
   came to, `TAKEN` is what stands paid against them, and `OWED` is the
   difference. `OWED` is a derived model method over two fields the
   query already returned; it is not stored, not re-read, and not a
   fourth fact.
3. **"Takings" is retired vocabulary.** The word is added to
   `retired_words` in `apps/admin/src/tests.zig`, which fails the build if
   a caption anywhere in the markup or the shell spells a destination or a
   figure the way it used to. `docs/glossary.md` is the list; the rule is
   the enforcement, as it has been for "Advance" and "Theme".
4. **The mode breakdown keeps its clock and says so.** "How it was paid"
   still selects on `paid_at`, because that is the drawer's question -
   what came over this counter today - and a caption now reads "received
   today, by the day the money arrived". It is deliberately not made to
   add up to `TAKEN`, and the screen no longer lets anyone pretend it does.
5. **Voided tickets stay out of the ticket figures, and no money of theirs
   is in the breakdown either.** `report_sql` has always excluded
   `status = voided`; ADR-0024 makes it so that the exclusion cannot be
   flanked from the money side, because a void is refused once a payment
   has closed the ticket. A ticket cannot be both counted-out and paid.
6. **One payment row per ticket, by schema.** `payment_one_per_order`
   (`0014_payment_once.sql`) is a UNIQUE index on `payment.order_id`, so
   `taken_minor` is a sum of at most one row per ticket and `OWED` is
   precisely the totals of the tickets that have none.
7. **No upper bound is added to either query, and no day is redefined.**
   The window stays "everything since the first millisecond of the day the
   report was asked for", and the day stays the UTC calendar day. Whether
   the restaurant's day ends at all, and where, is the trading-day policy
   - #77 and #78 - and this decision does not answer it. The gap it leaves
   is #157.

## Consequences

### Positive

- **The owner can close a night without inventing a number.** The figure
  that was overread as cash is labelled as the billing it is, and the cash
  is on the screen too, in its own card.
- **The difference is the actionable figure.** `OWED` is what the floor is
  holding. Before, that number existed only as the subtraction an owner
  had to think of themselves, and the sign of it was wrong: the two
  figures looked like the same fact, so a careful owner comparing them saw
  a discrepancy with no explanation rather than a list of open tabs.
- **One query, so one set of tickets.** Billed and taken describe exactly
  the same rows. Nothing about the day's takings depends on when a later
  query happened to run.
- **Nothing new to migrate.** `taken_minor` is a column of an existing
  read, not of the schema; no table, no index, no lock file touched.
- **ADR-0024 is what makes the arithmetic safe.** Because money closes a
  ticket and change was never written to the payment row - the row is the
  bill, not the tender - a closed ticket contributes the same amount to
  both figures, and a live ticket contributes nothing to `taken`. `OWED`
  cannot go negative on money this app took.

### Negative

- **`OWED` says how much, not which.** It is a subtraction of two sums, so
  the screen cannot tell the owner which table has not settled. A number
  that only points at a problem is a half-answer; the other half is the
  day close (#78), which needs the count as well as the total.
- **The two clocks still disagree across midnight, now in the open.**
  Yesterday's ticket paid today moves the drawer's total and not the
  day's `TAKEN`. That is correct for both figures and still confusing for
  anyone who has to reconcile them, which is why #157 exists rather than a
  quiet `AND placed_at < ?2`.
- **`taken_minor` is a correlated sum.** It runs a `payment` lookup per
  ticket in the day's set. The unique index makes each one a seek, and a
  day is hundreds of tickets, not hundreds of thousands - but the shape is
  one a much bigger report would have to revisit.
- **The "cannot go negative" claim is about this app's money.** A peer
  running an older build could write a payment row larger than the bill,
  and then `OWED` would read negative. It would be a wrong figure about a
  wrong row, and nothing on the screen would say so.
- **`BILLED` invites a question the screen answers badly.** It includes the
  tax and is after the discount - which is what a ticket total is - and the
  TAX and DISCOUNTS cards sit beside it without saying which side of the
  arithmetic they are on. A clearer report would show the sum the ticket
  total is built from. That is a labelling change, not this decision.

### Neutral / follow-ups

- #157: the day has no end, and the two figures have two clocks.
- #77: an order has no accounting date, so "the day" a ticket belongs to is
  inferred from `placed_at` and cannot be corrected when the inference is
  wrong.
- #78: the day close wants `billed - taken` for one named day, plus the
  count and the variance. This decision is the precondition for that; it is
  not the close.
- Whether `OWED` should expand into the list of open tickets on the same
  screen, or stay a single figure with the list on Orders.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Make "TAKINGS" mean money: count only tickets with a payment row | The number becomes easy to read and impossible to trust at close: a busy floor with six open tables reports a quiet day. The open tickets are the reason the screen exists. |
| Relabel only, and leave the money on the Payments screen | Cheapest, and the issue would half-close: the owner still cannot see what is owed without holding two screens in their head. A label that points elsewhere is a label that says "this screen cannot answer you". |
| Join `payment` in a second query with its own `placed_at` filter | Two queries, two chances to disagree about which tickets are in the day. The whole point was that billed and taken describe the same set. |
| Put the mode breakdown on the ticket's clock so it adds up to `TAKEN` | It stops answering the drawer's question, and the drawer is the reason that table exists. Money received today for yesterday's bill is cash someone has to count. |
| Store `owed` as a column or a model field | It is a subtraction. A stored third copy of two figures can only get stale, and the app's rule is that derived values are methods. |
| Add `AND placed_at < ?2` / `AND paid_at < ?2` bounds now | That invents a trading day. The day's end is a policy with a host of friends - accounting date, Z report, variance - and #77 and #78 own them, not a report screen. |
| Reuse an existing word: "SALES", "REVENUE" | Neither is plainer to the person at the counter, and both are accounting nouns this project has not earned: a revenue figure has a period, and the period is exactly what is not yet decided. |

## Evidence

- `packages/ros-core/src/data/repos.zig` - `report_sql` (six columns now),
  `report_modes_sql`, `decodeReport`.
- `packages/ros-core/src/core/model.zig` - `report_taken_field`,
  `report_taken_minor`, `report_owed_minor`.
- `apps/admin/src/screens/screen-overview.native` - the `screen-reports`
  template: two rows of figures, and the clock named over the breakdown.
- `apps/admin/src/tests_data.zig` - "the report says what the day came to"
  (billed 36700, taken 32500, owed 4200 with one open ticket) and "money
  received today for yesterday's ticket is in the drawer, not in the day's
  figures".
- `apps/admin/src/tests.zig` - `retired_words` now carries "TAKINGS", and
  "the day report tells what was billed from what was taken" renders the
  screen and reads its captions.
- `apps/admin/src/schema/0014_payment_once.sql` - `payment_one_per_order`.
- [#141](https://github.com/devstroop/ros/issues/141) - the two figures on
  one screen.

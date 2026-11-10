# ADR-0021: The counter POS is the service app

> **Status:** Accepted
> **Date:** 2026-10-24
> **Deciders:** Devstroop maintainers
> **Related:** [ADR-0014](0014-order-identity.md),
> [ADR-0017](0017-three-apps-over-tcp-ip.md),
> [ADR-0019](0019-cross-device-order-identity.md),
> [ADR-0020](0020-late-join-and-compaction.md),
> [`architecture/12`](../architecture/12-three-apps-and-ipc.md),
> [`plan/open-questions.md`](../plan/open-questions.md) A22/A23,
> [`plan/phase-9`](../plan/phase-9-three-apps-and-ipc.md)

## Context

The three-app split gives the admin app the back office and the service
app the floor. The permission matrix gave `pos`, `pos_cart` and
`payments` to the admin role only, so the till was the dedicated admin
machine. That is not the product the phase is built for: the phase's
own done criterion says the kitchen keeps cooking and the till keeps
selling **with the admin app closed**. If the till were the admin app,
closing the admin would stop the till, and the criterion would be
false.

The service app already carries the POS markup, and the order
confirmation screen already takes a payment. What was missing was the
permission and the mount: the waiter role could not open `pos`,
`pos_cart` or `payments`, and the service shell did not mount them. The
money path itself is already device-owned and idempotent: `takePayment`
builds an op with the order's origin pair, the payment is conditional
on the order's status, and a second tap finds the order closed and
writes nothing.

## Decision

**The counter POS belongs to the service app.**

1. The waiter role opens `pos`, `pos_cart` and `payments`.
2. The service shell mounts all three, and the waiter's tables screen
   has "Counter sale" and "Payments" entry points.
3. A waiter can take money at the counter or at a table. The payment is
   replicated with the same discipline as the order: the device that
   took the money owns the op, and the order's status transition is the
   idempotency key, so a retry is the same sale.
4. The admin app remains the back office and the wildcard superset. It
   still opens all three screens, so a single-machine restaurant can
   run the till from it and a manager can use them for setup or
   correction.
5. The kiosk roles never open a money screen.

## Consequences

### Positive

- The admin app can be closed during service without stopping the till.
  This is the phase-9 requirement, and the #111 three-device test keeps
  the admin closed while the service till sells and takes payments.
- The counter and the floor use one app and one database, so a sale and
  a table order share the product data, the order identity and the
  payment path.
- The permission matrix and the partition now agree: the screens the
  waiter may open are exactly the screens the service shell mounts. A
  test in each app walks every `(role, screen)` pair and compares the
  matrix with the shell's gates.

### Negative

- The service app is no longer a read-mostly floor tool; it writes
  orders and payments, so it carries the op log and compaction load.
  It already did: the order confirmation screen takes payments.
- A restaurant that wants a dedicated cashier machine and a separate
  floor tablet still needs two service devices or the admin app as the
  cashier. The matrix does not distinguish "counter" from "floor"
  inside the waiter role; both are the same person.
- The waiter's rail is still one section, so the POS and payments are
  reached from the tables screen rather than a second rail entry.

### Neutral / follow-ups

- A future "cashier" role could separate the counter from the floor.
  Not now: a second role inside one binary needs an in-app role choice,
  which ADR-0017 deliberately removed.
- The admin app's POS screens stay as the superset; a restaurant that
  runs a single machine uses the admin app.
- The service app's sign-in still depends on the PIN-salt decision
  (#95).

## Alternatives considered

| Alternative | Why not |
|---|---|
| Keep the POS in the admin app only | The admin app is the back office; closing it stops the till, which contradicts the phase-9 requirement and the #111 three-device test. |
| Put the POS in the kiosk app | The kiosk is the kitchen and customer display; it signs in by device and deliberately excludes money. |
| Add a fourth "cashier" app | Three apps is the budget; the counter and the floor are the same front-of-house job, and the service app already has the screens. |
| Add a "cashier" role to the service app | A second role inside one binary needs an in-app role choice, which ADR-0017 removed. The waiter can be the cashier. |

## Evidence

- `packages/ros-core/src/core/rbac.zig`: the waiter allows `pos`,
  `pos_cart` and `payments`; the kiosk roles do not.
- `apps/service/src/app.native`: gates 10, 11 and 15 mount the three
  screens.
- `apps/service/src/screens/screen-service.native`: "Counter sale" and
  "Payments" entry points on the tables screen.
- `apps/service/src/tests.zig`: walks every screen against the waiter
  role and the shell's gates.
- `apps/kiosk/src/tests.zig`: walks both boards against the kiosk gates.
- `apps/admin/src/tests.zig`: walks the admin wildcard and the POS
  partition.
- `packages/ros-core/src/core/rbac.zig` test: pins the POS partition
  for all four roles.
- #111's three-device test keeps the admin closed while the service till
  sells and takes payments.

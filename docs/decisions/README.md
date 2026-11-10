# Architecture decision records

An ADR records a decision that is expensive to reverse. It states the
context, the decision, the consequences and the alternatives, so a future
contributor can tell the difference between "we chose this" and "we did not
think about it".

This project follows a lightweight MADR-style format.

## Index

| ID | Title | Status |
|---|---|---|
| [0001](0001-native-sdk-zig-rewrite.md) | Rewrite on the Native SDK in Zig | Accepted |
| [0002](0002-pure-model-msg-update.md) | Pure Model / Msg / update core | Accepted |
| [0003](0003-no-router-screen-enum-and-stack.md) | No router; screen enum and stack | Accepted |
| [0004](0004-four-roles-one-binary.md) | Four roles in one binary | Superseded by ADR-0017 |
| [0005](0005-engine-owned-sqlite-strict-schema.md) | Engine-owned SQLite and a STRICT schema | Accepted |
| [0006](0006-integer-money-epoch-ms.md) | Integer minor-unit money and epoch-ms time | Accepted |
| [0007](0007-pin-hashing.md) | Salted SHA-256 PIN hashing | Superseded by ADR-0016 |
| [0008](0008-sidecar-for-printing.md) | A sidecar owns printing and BLE | Proposed |
| [0009](0009-oplog-sync-with-transport-sidecar.md) | Op-log sync with the transport in a sidecar | Revised by ADR-0017 |
| [0010](0010-markup-only-no-custom-paint.md) | Markup only; no custom paint or Lottie | Accepted |
| [0011](0011-desktop-first-defer-mobile.md) | Desktop first; defer mobile | Proposed |
| [0012](0012-csv-first-interchange.md) | CSV first for import/export | Proposed |
| [0013](0013-clock-based-order-ids.md) | Clock-based order IDs | Superseded by ADR-0014 |
| [0014](0014-order-identity.md) | The order identity: a sequence, an id and a request key | Accepted; cross-device half in ADR-0019 |
| [0015](0015-session-scoped-navigation.md) | A session owns its state and its history | Accepted |
| [0016](0016-what-a-pin-is.md) | What a PIN is in this app | Accepted; decision 3 superseded by ADR-0018, decision 1 made PIN-only by ADR-0022 |
| [0017](0017-three-apps-over-tcp-ip.md) | Three apps, one core, TCP/IP between them | Accepted |
| [0018](0018-the-pin-hash-is-the-employees.md) | The PIN hash is the employee's | Accepted |
| [0019](0019-cross-device-order-identity.md) | Cross-device order identity: a local row id and an origin pair | Accepted |
| [0020](0020-late-join-and-compaction.md) | Late join, snapshots and log compaction | Accepted |
| [0021](0021-counter-pos-is-the-service-app.md) | The counter POS is the service app | Accepted |
| [0022](0022-a-person-chooses-how-they-sign-in.md) | A person chooses how they sign in | Accepted |
| [0023](0023-a-peer-presents-a-shared-device-token.md) | A peer presents a shared device token | Accepted |
| [0024](0024-a-ticket-closes-with-its-money.md) | A ticket closes with its money | Accepted |
| [0025](0025-a-days-report-counts-bills-and-money.md) | A day's report counts the bills and the money as two figures | Accepted |
| [0026](0026-printing-via-tcp-and-spawn.md) | Printing via TCP :9100 in-process, ESC/POS, spool on failure | Accepted |

ADR-0017 was accepted on 2026-10-24. It supersedes ADR-0004 (four
roles in one binary) and revises ADR-0009 (the op-log sidecar); the op
log stays, and the apps carry the transport themselves.

ADR-0022 was accepted on 2026-10-31. It partially supersedes ADR-0016:
the six-digit rule is now the rule for a PIN, and a person may choose a
password instead. The hash, the cost and the lockout are unchanged.

ADR-0023 was accepted on 2026-11-03. It settles the peer-authentication
half of ADR-0017 that was left open: a shared device token in a header
on every request that carries the restaurant's data. It corrects the
`/v1/hello` wording in [`architecture/12`](../architecture/12-three-apps-and-ipc.md),
which described a handshake no client performs, and its claim that the
installation salt does not travel, which the reference document has
never honoured.

ADR-0024 was accepted on 2026-11-04. It moves the rule that only money
closes a ticket out of the reducer and into the statements that write a
status - both the local one and the one that applies a peer's op - and
reopens the tickets that closed unpaid before the rule was anywhere but
in `update`. It supersedes no earlier record; it makes an assumption all
of them shared enforceable.

ADR-0025 was accepted on 2026-11-04. It splits the day's report into what
the tickets came to and what was taken for them, counted over one set of
rows by one query, and retires the word that covered both. It leaves the
drawer's breakdown on its own clock and says so on the screen; the day
itself, and where it ends, stays with A19 and #157.

## Drafts

`drafts/` holds six early, unreferenced drafts of the first decisions.
They are kept for reference only; the numbered records below are the
canonical set. See [`drafts/README.md`](drafts/README.md).

## Status meanings

| Status | Meaning |
|---|---|
| **Proposed** | Written down, not agreed. Code may not exist. Needs an owner. |
| **Accepted** | Agreed and reflected in the code or the target design. |
| **Revised** | Still in force, with named changes made by a later ADR. |
| **Provisional** | In use, but known to be insufficient. Expected to be superseded. |
| **Superseded** | Replaced by a later ADR; keep for history. |
| **Rejected** | Considered and not chosen. |

## Template

```markdown
# ADR-NNNN: Title

> **Status:** Proposed | Accepted | Provisional | Superseded by ADR-XXXX
> **Date:** YYYY-MM-DD
> **Deciders:** names or roles
> **Related:** links

## Context

What forces are at play? What makes this a decision rather than an
obvious step? Include the constraint and the evidence.

## Decision

What we will do. Be specific enough that a reviewer can disagree.

## Consequences

### Positive

### Negative

### Neutral / follow-ups

## Alternatives considered

| Alternative | Why not |
|---|---|

## Evidence

Code, tests, spikes or external constraints that back the decision.
```

## Rules

1. Accepted ADRs are immutable except for status and superseding links.
2. A new fact goes in a new ADR, not an edit to history.
3. An ADR that has no code must say so.
4. Link the owning architecture page from the ADR, and the ADR from the
   architecture page.
5. If a decision is reversed, write the superseding ADR first.

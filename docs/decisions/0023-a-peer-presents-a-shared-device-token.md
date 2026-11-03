# ADR-0023: A peer presents a shared device token

> **Status:** Accepted
> **Date:** 2026-11-03
> **Deciders:** Devstroop maintainers
> **Related:** [ADR-0017](0017-three-apps-over-tcp-ip.md) (this is the
> peer-authentication half it left open),
> [ADR-0018](0018-the-pin-hash-is-the-employees.md) and
> [ADR-0022](0022-a-person-chooses-how-they-sign-in.md) (what a
> credential is, and what still never crosses the wire),
> [ADR-0020](0020-late-join-and-compaction.md) (the snapshot a gated
> endpoint serves),
> [`architecture/12`](../architecture/12-three-apps-and-ipc.md),
> [`architecture/08`](../architecture/08-sync.md),
> [`plan/risks.md`](../plan/risks.md) (SEC3),
> [`plan/open-questions.md`](../plan/open-questions.md) (D12, D13),
> [#134](https://github.com/devstroop/ros/issues/134)

## Context

ADR-0017 made the trust model "a trusted LAN" and named peer
authentication as the thing to decide later. `architecture/12` went
further and wrote the answer into the follow-up: "a shared secret in the
admin app's settings, presented in `/v1/hello`". That sentence is two
decisions wearing one coat, and the second one is wrong.

There is no `/v1/hello` *handshake*. It is a GET that returns this
device's own card - name, role, port, protocol version - and no client
in this repository has ever fetched it. Discovery runs over UDP beacons;
the request path is four calls: `GET /v1/ops`, `POST /v1/ops`,
`GET /v1/reference` and `GET /v1/snapshot`, plus a held-open
`GET /v1/events`. Presenting a secret in the one endpoint that carries
no restaurant data, and that nothing asks for, would have authenticated
exactly nothing.

Meanwhile the four that do carry data answered whoever asked. The
reference document is the whole `employee` table's secret material -
every `pin_hash`, and `pin_salt`, the installation salt, beside it
([#134](https://github.com/devstroop/ros/issues/134)). The bcrypt rows
do not need that salt; the legacy `sha256(pin_salt || PIN)` rows do, and
their PIN space is four to six digits. One unauthenticated `GET` handed
over the material to guess every old credential in the restaurant at
once. So "a trusted LAN" was not a choice an owner had made. It was an
omission with a document in its defence.

The forces that kept the answer small:

- **The wire is answered in two places.** `/v1/events` is held open by
  the listener thread, which never posts to the app and cannot wait for
  it: a request can arrive before `boot` has read a single row. The
  other four are answered in `update`, on the loop thread, where the
  model is the only source of truth. A check that lives in one of them
  guards half the door.
- **`update` has no randomness and no `Io`.** That is what keeps it
  replayable and testable. Anything that *makes* a secret belongs in
  `main`, which is where `auth.makeSalt` and `auth.makeToken` already
  live; anything that *changes* one at the operator's word belongs in a
  typed field.
- **The house rules bind the view to the model.** A value the screen
  shows is a `Model` field or method, and a device's secret is
  therefore a model field - which is exactly the thing `view_unbound`
  exists to keep off the screen. It needed a deliberate exception, and
  a stated one.
- **The token has to survive a restart, and a copied database.** A
  restaurant with one always-on machine exports its state by copying
  `app.db`; `scripts/smoke-sale.sh` does the same to bring a kiosk to
  the party. Whatever stores the token must travel with the rows.

## Decision

**Every device of one restaurant holds the same secret, called its
pairing token, and presents it in the `x-ros-token` header of every
request for the restaurant's data. A request that does not present the
token this device holds gets `401` and not one byte of the answer.**

Concretely:

1. **One token per installation, not one per device.** It says *which
   restaurant*, not *which machine*. Per-device identity is already on
   the wire and is already kept separate: the installation token names
   the writer in every request key and every op id
   ([ADR-0019](0019-cross-device-order-identity.md)). Rotating this one
   revokes every peer at once; that is the property that makes it worth
   having, and it is the property a per-device token would need a
   revocation list to reach. There is no revocation list.
2. **It is stored in `app_config` under the key `pairing_token`.**
   Key/value rows are the installation's own settings and `app_config`
   is already read at boot for the salt and the look of the device, so
   this needs no migration and no new table, and it crosses to a new
   device with the database file it was copied from.
3. **It is seeded, not negotiated.** `main` makes a token at boot - the
   same `auth.makeToken` that makes the installation token - and an
   operator's `ROS_NET_TOKEN` beats it, because provisioning a device
   with the restaurant's token is the case that has to work. The first
   boot writes what it was given with `ON CONFLICT DO NOTHING`, and
   every later boot keeps what it finds: **the stored row always wins
   over the seeded value**, so a stale environment variable cannot
   quietly split a restaurant in two.
4. **The value is kept twice, and published.** The model holds it for
   the screen and for `update`; a single slot in the shared state the
   listener thread reads holds it for `/v1/events`, written before the
   thread starts and rewritten whenever it changes. Bytes are copied
   before the length is, and the length is published with a release
   store against an acquire load, because the thread reads it while the
   loop thread may be writing it.
5. **Three endpoints are gated in `update`, one in the thread, and two
   stay open.** `/v1/reference`, `/v1/ops` (both directions) and
   `/v1/snapshot` are the answers that *are* restaurant data.
   `/v1/events` is gated in `net/server.zig` because it is answered
   there. `/v1/hello` and the 404 branch stay open on purpose: a device
   that has not been paired yet should be *seen* on the Control centre,
   and the card it carries is this device's own name and port, not the
   restaurant's.
6. **A refusal is counted and shown.** `refused` is a counter on the
   shared state; the Control centre says how many requests have been
   turned away. An owner who mistypes a token needs to see that a
   device is asking, not watch two tills silently fail to agree.
7. **Rotation is a typed field.** Settings shows the token the device
   presents and takes a new one. Typing is the only mechanism that
   exists on both sides of the house rules: `update` cannot make a
   random secret, and a button that "generates" one would have to be
   handed it by `main`, which knows nothing about the tap. The typed
   value is written with `ON CONFLICT DO UPDATE`, published to the
   thread, and takes effect on the next request in either direction.
   Every other device has to be told, in the same way it was told the
   first time.
8. **Nothing about a person changes.** A credential still never crosses
   the wire. What crosses is the employee row, self-verifying because
   bcrypt carries its own salt - and the installation salt still
   crosses with it, only to a paired peer now, and only while a legacy
   row exists to verify.

## Consequences

### Positive

- The document that undoes ADR-0018 for old rows is no longer
  downloadable by anything that can open a TCP socket.
- "A trusted LAN" becomes a claim an owner can act on: the token is on
  a screen, it is one value, and it can be changed.
- The gate is one header and one comparison, on a path that already
  copies every header line. Nothing is added to the wire format, no
  round trip is added, and no device has to be online to pair another.
- A misconfigured device is visible instead of silent, in the one place
  an owner looks at when devices disagree.

### Negative

- **The token is a shared secret, so it does not identify a device and
  cannot revoke one.** Any device that learns it reads and writes the
  restaurant's data, and rotating it disconnects everybody, including
  the machine that is being thrown away. The owner's mental model is a
  Wi-Fi password, and the honesty of that model is the whole of what
  this ADR claims.
- **It is sent over plain HTTP.** Anyone who can read the wire can
  replay the token. This closes the door that was wide open; it does
  not close the window. The network the owner does not control - a
  guest Wi-Fi, a shared router, a building network - is still the case
  TLS would answer, and is recorded as a follow-up rather than a
  solved thing.
- **Rotation is manual and multi-device.** Forgetting one till is
  possible, and the forgotten till will keep being refused until
  somebody notices. There is no "invite this device" flow and no way to
  see *which* peer was refused.
- **A copied database carries the token to the copy**, so a restored
  backup, a test device built from a production `app.db`, and the
  smoke-test kiosk all start out paired. That is the intended
  convenience of decision 3 and the reason a rotation exists.
- The legacy `sha256(pin_salt || PIN)` rows are still exported to a
  paired peer. Refusing *unpaired* peers is the fix this ADR makes;
  retiring those rows is a different one, and it is still owed.

### Neutral / follow-ups

- Per-device tokens, an invite flow, and a list of revoked devices - the
  three things this decision deliberately does not do.
- A TLS option for networks the owner does not control.
- Showing *which* device was refused, not only how many refusals there
  were; the peer card carries a device id and could carry the pair.
- A deadline or a count for the legacy-digest rows so `pin_salt` can
  stop travelling at all.
- The Control centre now has a secret on it. Whether that screen should
  be gated behind a manager's sign-in is a question about the screen,
  not about the wire.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Present the secret in `/v1/hello`, as `architecture/12` said | No client fetches it, the data endpoints would still answer anyone, and `/v1/events` is answered by a thread that never sees `update`. It would have been a handshake nobody performs. |
| A token per device | Buys revocation of one device, costs an identity table, a UI for it, and a rotation ceremony per machine. Nothing in this codebase can yet *use* a per-device identity for authorization, so it would be a list to maintain and nothing more. |
| Per-endpoint roles: authenticate writes, leave the reads open | `GET /v1/reference` is the exploit. Leaving any data endpoint open leaves the document that this whole decision exists to protect. |
| Reuse the installation token as the pairing token | It is per-device by design - it names the writer in every request key - so it cannot be shared, and reusing it would mean a peer learns the id that signs this device's ops. |
| Bind the listener to loopback, or require a firewall | Both are configuration an owner will not have, and the app's own discovery protocol exists precisely to let devices find each other on a shared network. |
| Derive the token from the PIN salt | Two different secrets, two different rotations, and the operator would be sharing the thing that hashes the staff's PINs. |
| Challenge-response or a signed nonce per request | Both need a per-device private key, which is the certificate model rejected below, and neither can be typed to an operator who has to configure the next till by hand. |
| Certificates and a key exchange | A second product: enrolment, a trust store, expiry, and an owner who has to understand all four. Named in ADR-0017 as the alternative to a trusted LAN rather than a way of making it honest; this is the smaller thing that makes the claim true. |
| Generate a fresh token on a button in Settings | `update` has no `Io` and no randomness, by design. The only honest way to offer that is to have `main` make the value and put it in the model, which means a button that changes a secret the operator never chose or read. |
| Store it in a file beside the database | Then it does not travel with the rows a restaurant actually copies, and every tool that moves a database has to be told about the second file. |

## Evidence

- `packages/ros-core/src/net/protocol.zig`: `token_header`,
  `max_token_bytes`.
- `packages/ros-core/src/net/server.zig`: `headerOf`, `Pairing`
  (byte-then-length publication, `matches`, `accepts`), `refused`, the
  gate in `run()`, and `refusePairing`.
- `packages/ros-core/src/core/net_bridge.zig`: `seedPairing`, `start`,
  `sharePairing`, `pairingHeaders`, `dataEndpoint`, and the gate at the
  top of `answer()`.
- `packages/ros-core/src/core/model.zig`: `pairing_buf`, `pairing_len`,
  `pairing_entry`, `net_refused` and the `view_unbound` entries that
  name the exception.
- `packages/ros-core/src/data/repos.zig`: `pairing_sql`, `loadPairing`,
  `savePairing` (`DO NOTHING`) and `setPairing` (`DO UPDATE`).
- `packages/ros-core/src/core/update.zig`: the `.pairing_loaded`
  arm - stored value wins - `.pairing_saved`, `pairing_edit` and
  `savePairing`.
- `apps/*/src/main.zig`: `net_bridge.seedPairing(...)` and the token
  passed to `net_bridge.start`.
- `apps/admin/src/screens/screen-settings.native`: the Pairing card on
  the Control centre.
- `packages/ros-core/src/net/server.zig` tests: "a header is read from
  the head the thread posts", "the pairing token is published last and
  matched without a shortcut", "an unpaired event stream is refused
  before it is held open".
- `apps/admin/src/tests.zig`: "restaurant data is answered only to a
  paired peer", "every request for restaurant data carries the pairing
  token", "a device with no token asks without one", "a rotated token
  opens the door it just closed".
- `apps/admin/src/tests_data.zig`: "a compacted log keeps a tail and a
  late joiner applies the snapshot" - the gated snapshot and ops pages
  of a real database.
- [#134](https://github.com/devstroop/ros/issues/134) - the evidence
  that the document and the salt went to anyone.

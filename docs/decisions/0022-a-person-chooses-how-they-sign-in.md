# ADR-0022: A person chooses how they sign in

> **Status:** Accepted
> **Date:** 2026-10-31
> **Deciders:** Devstroop maintainers
> **Related:** [ADR-0016](0016-what-a-pin-is.md) (decisions 1 and the
> unmasked-field consequence are replaced by this one; the rest stands),
> [ADR-0018](0018-the-pin-hash-is-the-employees.md) (decision 1, the
> picker, is extended here),
> [ADR-0020](0020-late-join-and-compaction.md) (the reference document
> now carries the kind),
> [`architecture/04`](../architecture/04-data-layer.md),
> [`architecture/03`](../architecture/03-navigation-and-rbac.md),
> [`plan/open-questions.md`](../plan/open-questions.md) (C13, C14)

## Context

Every screen that proves who is at the keyboard asked for a PIN. So did
every sentence in the app: "enter your PIN", a numeric pad, a
six-digit rule, the name of the column. That was right while there was
only one kind of secret, and it stopped being right the moment the
owner asked for the other one.

A PIN and a password are two different things that had been typed into
one box.

- A **PIN** is short, numeric and *tapped* on a till with a queue
  behind it. It is entered with an elbow in view of a customer, so it
  is worth something only if nobody can read it over the operator's
  shoulder, and it is worth something only as a name on a list.
- A **password** is long, mixed-case, full of punctuation, and *typed*
  on a keyboard by someone who chose it. It cannot be tapped on a pad;
  a pad has no shift key, and asking for `table-and-spoon` on a
  numeric surface is asking the person to fail.

The gaps the owner reported were both halves of the same problem. The
till offered one way in and would not take the other; and neither the
PIN nor the password was masked, so the secret sat in plain text on a
screen that faces the room, while the SDK's field had no password mode
to ask it for.

ADR-0016 named the mask as a *follow-up* - "The mask, when the SDK
grows one" - and ADR-0018 named the picker as the thing that makes the
salt per employee and the sign-in one hash. Both turned out to be the
same change: the picker already knows which person is signing in, and
the person's row already decides what they type. Once the kind of
secret is a fact you can read before you ask for it, the mask is just
a bound value and the pad is just one of two surfaces.

The mask had one real constraint. The SDK field reports what it holds,
and the app binds that value back into `text=` on every frame, so a
masked field cannot be a field that *shows* a mask - it has to be a
field that **holds** the secret and is *bound to a different string*.
That works only if the caret survives being moved by a rewrite, which
it does not for absolute-offset events: content edits are
caret-relative and safe, but `move_caret` and `set_selection` are byte
offsets into whatever the view last saw, so an eleven-bullet line and
an eleven-character secret disagree the moment the operator taps in the
middle.

## Decision

**The kind of credential is a fact about the person, it decides the
surface, and the view never gets to read the secret.**

1. **`employee.auth_kind`, one column, default PIN.** The kind rides
   on the person's row - not on the device, which changes hands, and
   not on the role, which says what a person may open rather than how
   they prove who they are. Zero means PIN, which is what every row
   written before the column existed already means: its digest was
   made from digits.
2. **Two surfaces, chosen by the row.** A PIN is *tapped* on a numeric
   pad that lays out the table `pin_digits` returns, and shows one
   bullet per digit under it. A password is *typed* into a masked text
   field with an eye beside it. The prompt says which: "enter your
   PIN", "enter your password".
3. **The mask is a bound value, not a field mode.** The secret lives in
   a `TextBuffer` the view cannot reach; the field binds
   `credential_display()`, which is the secret when the eye has opened
   it and one bullet per character otherwise. Bullets count characters,
   not bytes, so a nine-character password shows nine of them.
4. **The secret itself is `view_unbound`.** `credential`,
   `setup_credential`, `setup_credential2`, `form_reset_credential_buf`
   and their kind and reveal flags are all on the list the contract
   checker uses to catch a binding to something the interface has no
   business reading.
5. **Taps into a masked field keep their place.** `applySecretEdit`
   applies the edit to the buffer that holds the secret and pins the
   caret back, because the caret the view reports is a caret in the
   bullet line.
6. **Two policies, one hash.** A PIN is 6 to 16 digits; a password is 8
   characters or more, capped at bcrypt's own 72-byte limit. Both are
   bcrypt at the cost ADR-0016 chose, both in the column still called
   `pin_hash`, both salted the way ADR-0018 decided. The only difference
   is what the person is asked to type.
7. **The row wins over the list.** At sign-in the database's row
   decides the surface, not the employee list the app loaded earlier.
   When they disagree, the kind flips, the screen says so in words, and
   the attempt is **not** counted as a wrong guess.
8. **The choice is offered wherever a secret is written**: the setup
   form for the owner, the reset form for any employee. Both ask for it
   twice, mask both boxes, and share the eye.
9. **The kind travels.** `auth_kind` is in the reference document, so a
   second app offers the right surface for a person it has never met.

## Consequences

### Positive

- **Nobody is told to type something they cannot type.** An owner who
  chose a password is not sent at a numeric pad, and the words on the
  screen match the surface under them.
- **A till in front of a queue keeps its secret.** Both surfaces show
  bullets, so the length is visible and the value is not. The eye is a
  deliberate, local, one-tap exception rather than a permanent state.
- **A stolen database is no easier to read than it was.** One hash, one
  cost, one salt derivation; a password just makes the guess list
  longer. The kind column says how to *ask*, not how to *check*.
- **A stale employee list cannot lock anybody out.** A person who
  changed their credential on another device gets the right screen and
  no strike against them.
- **The mask costs the view nothing.** It is a slice of a
  pre-allocated bullet table; no copy, no allocation, no per-frame
  work.

### Negative

- **`pin_hash` and `pin_salt` are misnomers now.** They hold a password
  hash and the salt of one, and renaming them would rewrite an on-disk
  contract for a word. They stay, and the schema comment says what they
  are.
- **The eye says "Show" and "Hide"**, because the SDK's built-in icon
  set has an `eye` and no `eye-off`, and there is no app-icon
  registration in a markup-only app. A glyph alone would be a glyph
  that means two different things.
- **Revealing is not timed out.** It stays open until the person closes
  it or the session resets. A lock button is a model timer, and the
  model is not supposed to own a clock it renders against.
- **A masked field cannot be filled by a helper that asserts what the
  field reports.** The smoke script's `type_into` checks the text it
  typed; a masked box reports bullets, so the secret steps now prove
  the mask (`type_secret`, `tap_pin`) instead of assuming it.
- **Two surfaces is two paths through the sign-in**, and the reset form
  has to be able to switch a person from one to the other and say that
  the old sign-in stops working immediately.

### Neutral / follow-ups

- A device that has never seen the admin's reference document offers
  the pad for a password person on its first attempt, then corrects
  itself from the row. That is the designed behaviour; whether the
  correction should also happen *before* the first tap is a question
  about how eagerly a device pulls the staff list.
- The five-tries lockout is unchanged, and still session-scoped
  (ADR-0016 named that). A password raises the cost of guessing far
  more than it raises the cost of the counter.
- The pad has no way to type a non-digit; if a restaurant wants a
  numeric password, it should be a PIN, and the form says so.
- An employee row can be written with a kind and no hash by a future
  import; `CredentialKind.fromInt` falling back to PIN is the guard for
  a number, not for an empty secret. The sign-in already refuses a row
  with no hash.

## Alternatives considered

| Alternative | Why not |
|---|---|
| A per-device setting for the credential kind | The same person works a till and a back office. The device changes hands; the person does not. |
| A per-role rule: managers get passwords, crew get PINs | A role says what a person may open. Making it also say what they type means an owner cannot give themselves a PIN, and a cashier cannot have a password. |
| Both surfaces at once, one screen | Two boxes for one value, and the person has to work out which one the app is listening to. |
| One box that accepts both, with a free-text keyboard | A phone-style keyboard at a till is a mistake machine for a six-digit code, and nothing stops a person typing a password's worth of characters into a PIN-sized rule. |
| Let the SDK mask the field | There is no password mode: the field reports what it holds, and the app binds that value back every frame. |
| Keep the view bound to the buffer and paint bullets in the field | Either the caret jumps or a tap inserts at the wrong byte: the field's absolute-offset events index the string the view last saw, which is not the secret. |
| Count the stale-list mismatch as a failed attempt | It punishes the app's own bookkeeping, and five of them is a lockout for someone who typed the right thing. |

## Evidence

- `apps/*/src/schema/0020_employee_credential.sql` - one column,
  `NOT NULL DEFAULT 0`, append-only, with the reason the CHECK is not
  there.
- `packages/ros-core/src/domain/models.zig`: `CredentialKind` and
  `Employee.auth_kind` / `credential_label`.
- `packages/ros-core/src/core/model.zig`: `credential_display`,
  `masked`, `sign_in_by_pin`, `sign_in_by_password`,
  `credential_prompt`, `reveal_label`, `pin_digits`,
  `credential_kinds`, `credential_is_acceptable`, and the
  `view_unbound` entry that keeps `credential` out of the interface.
- `packages/ros-core/src/data/auth.zig`: `min_pin_len`,
  `max_pin_len`, `min_password_len`, `max_secret_len` and why 72 is
  bcrypt's own ceiling, not a UI rule.
- `packages/ros-core/src/core/update.zig`: `applySecretEdit` pinning
  the caret, `toggle_reveal`, the pad's digit taps, and the
  `.login_checked` branch that corrects the kind from the row without
  counting a failure.
- `packages/ros-core/src/net/reference.zig`: `auth_kind` in the
  published product of the staff document.
- `apps/*/src/screens/screen-session.native` - the pad branch and the
  masked field branch; `screen-people.native` - the reset form's kind
  toggles, both confirm rows and the eye.
- `apps/admin/src/tests.zig`: "the secret shows as bullets, and the eye
  opens it", "the pad taps a PIN one digit at a time", "picking a
  person lands on the PIN screen, in the mode they work in".
- `apps/admin/src/tests_data.zig`: "the database, not an old list,
  decides which surface the till offers", "a row from before the choice
  signs in with a PIN", "an owner can open the restaurant with a
  password", "a manager can reset how an employee signs in", "the
  reference says how each person signs in".
- `scripts/smoke-sale.sh`: `type_secret` and `tap_pin` walk both
  surfaces on a real canvas and assert the bullet count, then reset
  Smoke Owner to a password and sign in with the field.

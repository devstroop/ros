#!/usr/bin/env bash
# File the findings from the deep audit as GitHub issues.
#
#   scripts/file-findings.sh
#
# Each body carries the file:line evidence the audit produced, so an issue
# can be checked against the source without redoing the investigation.
# Idempotent by title: an existing issue with the same title is skipped.
set -u

REPO="devstroop/ros"
cd "$(dirname "$0")/.." || exit 1

if ! command -v gh >/dev/null 2>&1; then
  printf 'ros: gh is not on PATH\n' >&2
  exit 1
fi

file_issue() {
  local title="$1"
  local body="$2"
  local existing
  existing="$(gh issue list --repo "$REPO" --state all --limit 200 --json title --jq '.[].title' 2>/dev/null | grep -Fx "$title" || true)"
  if [ -n "$existing" ]; then
    printf 'skip   %s\n' "$title"
    return 0
  fi
  if gh issue create --repo "$REPO" --title "$title" --body "$body" >/dev/null; then
    printf 'filed  %s\n' "$title"
  else
    printf 'FAILED %s\n' "$title" >&2
  fi
}

# ------------------------------------------------------------ security

file_issue "P0 — the reference document hands any LAN peer every credential hash and the installation salt" "$(cat <<'EOF'
`GET /v1/reference` is answered with no authentication of any kind, and the
document it serves contains the whole `employee` table's secret material.

Evidence:
- `packages/ros-core/src/data/repos.zig:4798-4801` — the snapshot SQL puts
  `pin_hash` and `auth_kind` for every employee into the JSON document.
- `packages/ros-core/src/data/repos.zig:4821` — the same document carries
  `pin_salt`, the installation salt, under the `app_config` key.
- `packages/ros-core/src/net/reference.zig:36,72-84` — the receiving shape
  names both fields, so this is the intended contract, not an accident.
- `packages/ros-core/src/net/server.zig` — the request loop routes
  `/v1/reference`, `/v1/ops` and `/v1/events` with no credential check on
  any of them.

Why it matters now, and more than it did before: a bcrypt row is
self-salting and does not need `pin_salt`, but a **legacy** row is
`sha256(pin_salt || PIN)` over a four-to-six digit numeric space
(`packages/ros-core/src/data/auth.zig:118`). One unauthenticated request
therefore yields a material that is offline-guessable across every employee
at once. The per-employee bcrypt derivation added in ADR-0018 protects the
new rows; the old ones are exported in a form that undoes it.

ADR-0017 records "decide peer authentication" as an open decision on the
assumption that a trusted LAN is a *choice*. It is currently an omission:
nothing in the code or the docs states that any device on the network may
read the credential file.

Decide and implement one of: bind the endpoint to a paired device, drop
`pin_hash`/`pin_salt` from the document and give peers a separate
authenticated fetch, or finish the legacy rehash so no row in a live
database is a fast digest. The third is already the migration path
(`update.zig:930-938` rehashes on a successful sign-in); it needs a deadline
and a count of rows still on the old form.

No test covers this.
EOF
)"

file_issue "P1 — the sign-in lockout does not survive a restart, and clears its own count when it expires" "$(cat <<'EOF'
Two counters decide whether the till takes a credential. Both live only in
the model, so the ceiling on guessing is "five per process", not five per
interval.

Evidence:
- `packages/ros-core/src/core/model.zig:882,885` — `login_failures` and
  `login_locked_until` are model fields defaulting to `0`.
- `packages/ros-core/src/core/update.zig:2732-2735` — a wrong credential
  increments the count; on reaching `max_login_failures` (5,
  `model.zig:168`) it **sets `login_failures = 0`** and locks for
  `login_lockout_ms`.
- No SQL anywhere writes either value — grep for `login_failures` finds only
  `model.zig` and `update.zig`, no `repos.zig` writer.
- `packages/ros-core/src/core/update.zig:956-957` — the session reset zeroes
  both.

Consequences:
1. Restarting the app (or the device) resets the counter and the lock. A
   guesser gets five attempts per reboot, indefinitely.
2. Because the count is cleared at lockout rather than at unlock, the lock
   expiring hands back a clean five.
3. The counter is global to the device, not per person, so one locked till
   locks out the whole staff — and a per-person counter would at least
   survive being written down.

`docs/plan/risks.md` already carries this as SEC8 with the proposed fix
("keep the counter in the database, one row per person"). This issue is the
evidence for it. There is a test that the till stops after too many wrong
ones (`apps/admin/src/tests_data.zig:975`) and none that it stops after a
restart.
EOF
)"

file_issue "P1 — four pre-verification oracles answer before any hash is checked, and none of them costs a failed attempt" "$(cat <<'EOF'
`submit_login` answers several questions before it runs bcrypt, and each of
those answers is free: it does not increment the failure count, so an
attacker can ask it as often as they like.

Evidence, all in `packages/ros-core/src/core/update.zig`:
- `:871-875` — the returned row's id does not match the one tapped → returns
  without charging a failure.
- `:876-881` — the row's role is not this app's role → returns without
  charging.
- `:887-896` — the row's `auth_kind` disagrees with the surface the picker
  offered → returns without charging, and the error text tells the caller
  which kind that person actually uses. Pinned by
  `apps/admin/src/tests_data.zig:2803-2806`, which asserts the *no-charge*
  behaviour as correct.
- `:902-909` — the stored hash is empty → "That person has no PIN yet"
  (`:2719`). A per-employee "no credential is set" probe, uncharged and
  untested.
- `:916-920` — a legacy row with an unconfirmed salt → "Still starting up",
  which announces that this employee's secret is a fast SHA-256 digest
  rather than bcrypt. Refusal tested (`tests_data.zig:1822`); the leak and
  the free retry are not.
- `:845-849` — the inverse: a busy or corrupt database **is** charged as a
  wrong credential, so a flapping store can lock out a whole shift.

Timing: `auth.verifyCredential` runs at `:921`, after all of the above. An
unknown or inactive employee id answers in microseconds; a known one costs
~100 ms of bcrypt (`auth.zig:51-54`). That gap is itself an existence oracle
and no test covers it.

The design intent — a stale picker list must not cost a person their
lockout budget — is right and should stay. What needs deciding is which of
these answers are safe to give a device that has not proved anything, and
whether the free paths should be rate limited in place of being charged.
EOF
)"

file_issue "P2 — the pad keeps taking digits while the till is locked, and the countdown is bound by nothing" "$(cat <<'EOF'
When the lockout is active the app refuses the credential but the numeric
surface behaves exactly as it did a moment before.

Evidence:
- `packages/ros-core/src/core/update.zig:764-774` — `.credential_digit`
  checks only the length cap (`auth.max_pin_len`). There is no lock gate, so
  digits accumulate into the buffer while locked.
- `packages/ros-core/src/core/model.zig:2209` (`login_locked()`) and `:2215`
  (`login_locked_seconds`) both exist and compute correctly, and neither is
  referenced by any markup — grep `apps/*/src/screens/*.native` for
  `login_locked` returns nothing.

So an operator taps a six-digit PIN, presses Sign in, gets refused, and sees
no reason: the pad is still live, no countdown is shown, and the message
arrives only on the attempt. `tests.zig` pins the arithmetic
("a wrong try is counted once") and nothing pins what the locked screen
looks like.

Fix shape: gate the pad and the field on `login_locked()`, bind the seconds
into the sign-in card, and keep the person's name visible so they know whom
they are waiting for.
EOF
)"

file_issue "P3 — the legacy digest comparison is not constant-time" "$(cat <<'EOF'
`packages/ros-core/src/data/auth.zig:118` compares a legacy
`sha256(pin_salt || PIN)` digest with `std.mem.eql`, which returns on the
first differing byte. A modern hash goes through `bcrypt.strVerify`, which
handles its own comparison.

This is a real timing channel only in combination with the unauthenticated
reference endpoint (see the P0 issue): with the salt in hand, an attacker on
the LAN is doing offline work anyway, so the online leak is the one that
matters. Recorded separately because the honest fix is not "use a constant
time compare" — it is "finish retiring legacy digests", which makes the
question disappear.

Worth noting the plaintext is never compared either way; only digests are.
EOF
)"

# ---------------------------------------------------------------- money

file_issue "P1 — the rule that a ticket cannot close unpaid exists only in Zig; the SQL lets any caller do it" "$(cat <<'EOF'
The app refuses to move a served ticket to completed without a payment, and
the database does not.

Evidence:
- `packages/ros-core/src/core/update.zig:2075` — the guard: served →
  completed requires `order.paid`.
- `packages/ros-core/src/data/repos.zig:3683-3690` — the actual UPDATE is
  conditioned only on `status = from_status`. Nothing mentions payment.
- `packages/ros-core/src/apps/admin/src/schema/0005_orders.sql` — no trigger
  or check constraint ties `status` to a `payment` row.
- `packages/ros-core/src/data/repos.zig:4329-4355` — the peer apply path
  accepts `status = 4` under
  `status < ?2 OR (?2 = 5 AND status < 4)`, and `applySnapshotOp`
  (`repos.zig:3352`) replays it. **An unpaid-closed ticket can arrive over
  the wire without any local guard being consulted at all.**

Test coverage: `apps/admin/src/tests_data.zig:1017` proves the model-side
refusal. Nothing proves the SQL, and nothing tests the incoming-op path.

This is the invariants-in-the-wrong-place bug: `update` is pure and its
guards evaporate for every other writer — a peer op, a snapshot replay, a
future screen, or anything holding the database file. Decide whether money
is a database invariant (a trigger, or a `completed` that only a payment
write may set) or an app rule with a documented tolerance, and make the two
halves agree.
EOF
)"

file_issue "P1 — a payment that matches no row still writes an op, so peers book money this till never took" "$(cat <<'EOF'
Every money statement in `takePayment` is conditional, but the operation-log
write that follows them is not.

Evidence:
- `packages/ros-core/src/data/repos.zig:2296-2345` — the order update, the
  payment insert and the table release are all guarded (`WHERE status = …`,
  `changes() = 1`).
- `packages/ros-core/src/data/repos.zig:2404` — the op is written with
  `insert_op_log_sql` (`:2633`), the unconditional form, instead of
  `insert_op_if_written_sql` (`:2675`), which every other money path uses.
- `packages/ros-core/src/core/update.zig:1720-1738` — the result handler
  reports success from the transaction's completion, not from whether a row
  changed.

Sequence that loses the money trail: the kitchen advances or the peer's op
closes the ticket first, this till presses Pay, the conditional statements
match nothing, the op and a clock still land — and peers apply a payment for
a sale this device never recorded. No test covers it.

The same unconditional-op bug is at `repos.zig:3750` (`setOrderStatus`),
`:1917` and `:2102`: a status move that matched no row still burns a clock
value and appends an op, which inflates the log and the reference version
for nothing.
EOF
)"

file_issue "P1 — the dashboard's takings and the payment breakdown are two different numbers, and one of them counts money not yet taken" "$(cat <<'EOF'
The same screen reports two totals that disagree by design.

Evidence:
- `packages/ros-core/src/data/repos.zig:228-236` — `report_sql` sums
  `subtotal_minor`, `tax_minor`, `discount_minor` and `total_minor` from
  `orders` where `status <> 5`. That includes **open** tickets and any
  ticket closed without payment.
- `packages/ros-core/src/data/repos.zig:239-247` — `report_modes_sql` sums
  real `payment.amount_minor`.
- `apps/admin/src/screens/screen-overview.native:105` renders the first as
  the day's TAKINGS; `screen-orders.native:152` renders the second.
- `apps/admin/src/tests_data.zig:2571` currently asserts the inflated figure
  (32500), so the behaviour is pinned in the wrong direction — a fix has to
  change a test on purpose.

An owner closing the night reads "what we took" from a number that includes
what is still owed. Either the label changes to what it counts (turnover)
and a separate figure shows money actually taken, or the query joins
`payment`. Which one is a product decision about what an X report means —
but the two figures must not sit on one screen looking like the same fact.
EOF
)"

file_issue "P2 — price entry is hard-wired to two decimals while the currency carries its own" "$(cat <<'EOF'
Amounts are `i64` minor units everywhere and the company row stores
`currency_decimals`, but the entry path assumes 100.

Evidence:
- `packages/ros-core/src/core/model.zig:325-341` — the parser computes
  `whole * 100 + cents` and silently drops a third fraction digit.
- `packages/ros-core/src/core/update.zig:322-329` — the same `/100` on the
  way back out.
- `packages/ros-core/src/core/model.zig:1270` — `currency_divisor` reads the
  company's decimals and is used correctly throughout the markup.
- Test coverage: `apps/admin/src/tests.zig:1319` pins the divisor for
  display. Nothing pins entry.

So a JPY restaurant prices everything ×100 on the way in, and a KWD one
(three decimals) truncates the third digit of every price typed. The money
rule — integer minor units, never a float — is right; the constant is not.
EOF
)"

file_issue "P2 — once a ticket is closed unpaid the till can never collect it, but the Pay button still renders" "$(cat <<'EOF'
An unpaid-closed ticket is reachable and unfixable.

Evidence:
- `packages/ros-core/src/core/update.zig:2646-2652` — payment is refused
  when `status == .completed`.
- `apps/admin/src/screens/screen-orders.native:52-56` — the orders list
  still offers Pay for that ticket, and `apps/admin/src/tests.zig:1560`
  asserts that the button is there.
- The result is a dead click: the operator sees "That order is already
  paid" for an order with no payment row.
- Peers behave differently again: `repos.zig:4520-4536` books money onto a
  completed ticket (`status < voided`), so the same op can succeed remotely
  and fail locally. Untested against a real database.

There is no "record a late payment" or "reopen" path, and no test that
walks an unpaid close to a collected payment. Decide the recovery route
alongside the P1 invariant issue — they are the same decision.
EOF
)"

file_issue "P2 — a ticket closed without payment leaves its table occupied" "$(cat <<'EOF'
Freeing a dining table is a side effect of paying or voiding, not of
closing.

Evidence:
- `packages/ros-core/src/data/repos.zig:2326-2345` (payment) and
  `:3925-3946`, `:4570-4597` (void) set `dining_table.status` back to free.
- `setOrderStatus` (`repos.zig:3683-3690`) frees nothing.
- Tests `apps/admin/src/tests_data.zig:4135` and `:4213` cover the paid path
  and one-order-of-two; no test closes a ticket unpaid and looks at the
  table.

So the walk-out that closes at the board (see the P1 invariant issue) parks
a phantom party on the floor plan, and the next waiter is told the table is
taken.
EOF
)"

file_issue "P3 — the same sale carries different order numbers on the till and the kitchen" "$(cat <<'EOF'
Order numbers come from a per-database sequence.

Evidence:
- `packages/ros-core/src/data/repos.zig:3438-3448` — the local insert takes
  `order_no` from this database's sequence.
- `packages/ros-core/src/data/repos.zig:4048-4062` — the peer apply path
  assigns from *its* sequence rather than keeping the seller's number.

The order keeps its identity across devices (ADR-0020, and
`tests_data.zig:5300` "a payment op finds its order by origin, not by a
shared id" proves identity), so this is cosmetic — but a cook shouting
"number 12" and a till holding "number 7" for one ticket is the kind of
thing a floor notices immediately.
EOF
)"

file_issue "P3 — the kitchen board's ticket count ignores the station filter the board itself applies" "$(cat <<'EOF'
Two model methods disagree about what the board is showing.

Evidence:
- `packages/ros-core/src/core/model.zig:2537` — `kitchen_tickets` filters by
  the station the cook selected.
- `packages/ros-core/src/core/model.zig:2571` — `ticket_count` counts
  without that filter.

The badge therefore reports every open ticket while the list shows one
station's. Cosmetic, but it is exactly the class of defect D5 was
("the orders badge says open and counts everything else"), so worth pinning
with a test rather than trusting the eye.
EOF
)"

# -------------------------------------------------------------- hardware

file_issue "P1 — printing: the tables and the screen exist, nothing else does" "$(cat <<'EOF'
A POS cannot hand over a bill or send a kitchen ticket on paper. This is
the gap between "incomplete" and "not deployable".

**What exists**
- `apps/admin/src/schema/0009_printing.sql:7` — `printer` (kind
  `escpos|system`, transport `ble|tcp|usb|file`, address, job
  `receipt|kot|report`, `paper_width_mm`, active) and `:25` — `auto_print`.
  No later migration touches printing.
- A read-only path: `repos.zig:399 printers_sql` → `:1034 loadPrinters` →
  `:1661 decodePrinters` → `update.zig:1910` → `model.zig:1838 printers()`.
  `printers_sql` **omits `paper_width_mm`**, and `domain.Printer`
  (`models.zig:354`) has no width field, so the column cannot reach a
  renderer that would need it.
- `apps/admin/src/screens/screen-settings.native:251` (`screen-settings-printers`,
  gated at `app.native:135`) lists printers and shows a count. It saves
  nothing; its only control is Back.
- `key_save_printer = 27` (`repos.zig:68`) is declared, never used, and
  survives only in the key-uniqueness test `apps/admin/src/tests.zig:1441`.
- The bill's data is all there and persists: company header
  (`0001_core.sql:20-23`, written `repos.zig:2140`), lines
  (`repos.zig:195`), payments (`:248`), discounts and grand total
  (`model.zig:1288,1345`), and invoice numbering works
  (`0012_order_sequence.sql`, `repos.zig:1888-1902` — zero-padded
  `order_no` inside the insert transaction).
- The customer display (`screen-kitchen.native:63`, `model.zig:1183`) shows
  table, order number, status and type only — no lines, no totals — so it is
  not today a substitute for a printed bill.

**What is missing**
ESC/POS encoder, a print job table and row, a queue with retry and
idempotency, test print, drawer kick, a status surface, any read or write of
`auto_print` (only a COUNT at `repos.zig:341`), and any INSERT into
`printer` outside `tests_data.zig:4823`. `fx.spawn` and `fx.writeFile` are
used **zero** times in the repository.

**Hard constraints from the SDK** (from the installed SDK's own docs —
`~/native-sdk/skill-data/`; note `AGENTS.md` points at
`../native-zig-showcase/docs/sdk/`, which does not exist on this machine)
- **BLE, USB and serial have no API at all**, and the capability lists in
  `apps/*/app.json:27` declare none. A Bluetooth printer cannot be reached
  from inside the app. That is a decision point, not a task.
- **TCP :9100 is reachable in-app**: `std.Io.net.IpAddress.listen/connect`
  (`skill-data/zig/SKILL.md:157`) is already proven here
  (`net/server.zig:236`, `net/discovery.zig:28`, `apps/net-spike/`). It must
  run on the net thread, since `update` has no `Io`.
- **`fx.spawn`** (`skill-data/core/…/effects.zig:2990`) gives argv, one-shot
  stdin, stdout as lines (4 KiB default, 256 KiB ceiling) or collected, and
  an exit code — enough for `lp`/`lpr` and one-way jobs; binary status
  read-back is line-framed.
- **Files**: `writeFile`/`append`/stream with a 1 MiB whole-file cap and
  `filesystem` permission already granted, so a spool file is available now.
- **`fx.fetch` is HTTP(S) only** and cannot reach a raw printer. (ADR-0008's
  line 70 claim that there is "no socket API" is simply false today.)

Needs an ADR before code: which transports are in scope, in-app versus an
external helper for BLE, and what a failed print does to a sale.
EOF
)"

# ----------------------------------------------------------------- docs

file_issue "P2 — the roadmap's phase table contradicts the code it describes" "$(cat <<'EOF'
`docs/plan/roadmap.md:38-40` states three things that are not true.

- **Phase 2 "The admin back office" — Not started.** It is built, and the
  same page's own exit criteria (`roadmap.md:296-315`) are ticked 6 of 8.
- **Phase 3 "The waiter and kiosk surfaces" — Not started.**
  `apps/service/src/app.native` gates ordinals 37-40 (the waiter screens),
  `apps/kiosk/src/app.native` gates 41 (`kds_board`) and 42
  (`display_board`).
- **Phase 4 "Sync sidecar" — Scaffolded, "long pole".** There is no sidecar
  and there will not be one: ADR-0017 (accepted, implemented 2026-10-24)
  moved the socket in-process, and `packages/ros-core/src/net/` is ten files
  with a working push stream, discovery, compaction and snapshot replay.

The table also still lists Phase 5 as a sidecar, which the printing issue
shows is a live decision rather than a settled design.

A planning page that says the product is two phases behind where it is
steers the next decision wrong, which is worse than a typo. Worth a rule:
the phase table's State column is derived from the exit criteria below it,
not written by hand.
EOF
)"

file_issue 'P2 — the docs describe paths that no longer exist: per-app src/, tools/, PORT-PLAN.md, and stale counts' "$(cat <<'EOF'
Systemic, and cheap to fix in one pass. Verified with the file system.

**Wrong source paths.** The core moved to `packages/ros-core/src/…`, but the
docs still cite per-app paths that do not exist:
`architecture/01-system-overview.md:76-81`, `04-data-layer.md:6`,
`03-navigation-and-rbac.md:5-6`, `architecture/navigation-and-roles.md:10-12`,
`architecture/ui-components.md:12-13`, `roadmap.md:106,108,246-262`, and
`plan/status.md:169`, which names `src/screens/screen-customers.native`,
`screen-reservations.native`, `screen-suppliers.native` and
`screen-purchase-orders.native` — those four files were never there; the
templates live inside `screen-catalog.native` and `screen-floor.native`.

**Directories that do not exist.** `tools/` is absent entirely, yet is
described as present at `architecture/08-sync.md:125` ("an empty
directory"), `architecture/09-printing-and-hardware.md:6`,
`roadmap.md:179-180,211-213,408-413,454-460`, `plan/status.md:38`
("`tools/*` contain READMEs only") and `architecture/01-system-overview.md:83`
— the Sidecars row, which I removed from the testing page, is still there.

**Broken links.** `PORT-PLAN.md` is gone but linked from `docs/README.md:14`,
`docs/plan/README.md:5`, `architecture/01-system-overview.md:19`,
`architecture/07-windowing-and-desktop.md:127`, mentioned at
`09-printing-and-hardware.md:7` and `11-capability-gaps.md:5`, and cited by
`docs/decisions/drafts/*`. `architecture/ui-components.md:15` links
`../../../native-zig-showcase/…`, which is not on this machine — and is the
same path `AGENTS.md:…` tells contributors to read for the SDK reference, so
the instruction "if it is not in the SDK reference it does not exist" cannot
currently be followed.

**Stale counts.** `01-system-overview.md:82` "0001..0017" and `:168` "17
migrations" → 20; `:169` "80 authored headless tests, 47 in-memory" → 211
(66 + 144 + 1); `:173` "14 of the 45 screens have no template" → 53 screens,
all templated; `:174` "catalog and settings administration" and `:166` "floor
table board" use retired words. `roadmap.md:107` "nine templates" → 11 files;
`:108` "seventeen migrations"; `:110` "15 authored + 12 in-memory".
`06-ui-markup-and-theming.md:3` "9 templates render" plus its 7-row table at
`:340-347`; `ui-components.md:3` and `navigation-and-roles.md:3-5` ("the
other 36 `Screen` values" — 9+36=45, not 53).
`04-data-layer.md:146-160` lists 13 effect keys → 67, calls
`key_write_product`/`key_write_table` "unused" at 21/22 when their real
values are 34/35, and `:198` claims `loadAll` omits `loadCustomers` while
`repos.zig:1153` calls it.

**Headers that contradict their own bodies.** `04-data-layer.md:3` "most
entities have no write path" against 21 write functions in `repos.zig`;
`03-navigation-and-rbac.md:3` "screen coverage is Partial" against
`plan/status.md` "Screen coverage | Implemented"; `ui-components.md:8` and
`docs/README.md:19-21` say the `native` CLI is absent and the binary is
`zig-out/bin/ros`, when it is installed and produces `ros-admin`,
`ros-service` and `ros-kiosk`.

**Terminology.** Retired words per `glossary.md:128-131` still describe the
current UI at `04-data-layer.md:177` and `data-model.md:677,720` ("Floor
board"), `01-system-overview.md:166`, and `roadmap.md:232` ("rail entries —
Catalog, People, System"; the rail says Dining, Menu, Team).
EOF
)"

printf '\ndone\n'

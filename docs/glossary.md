# Glossary — the words the product uses for itself

One concept, one word, everywhere: the rail, the status bar, the heading
and the empty state all say the same thing about the same destination.
The test `the rail, the title bar and the markup say the same thing` in
`apps/admin/src/tests.zig` pins the rail labels, the screen titles and
the markup text against this page, so a screen cannot quietly start
calling the till something else.

## Destinations

| Word | What it is | Was called |
|---|---|---|
| **Dashboard** | The day at a glance: open orders, tables busy, takings. | Overview |
| **POS** | The till. Ring up a sale, take the money. | Sell, counter, till |
| **Orders** | Every ticket the restaurant is still working, and the paid ones below it. | — |
| **Dining** | The room: tables, their status, reservations, customers. | Floor, Dining tables |
| **Menu** | What the restaurant sells: dishes, categories, prices, stock, suppliers. | Catalog, Catalogue |
| **Team** | The people with a PIN on this device. | People, Employees, staff |
| **Settings** | Company, currency, tax, discounts, printers, data. | System |
| **Kitchen** | The board the cooks work from. | — |
| **Display** | The screen the room reads. | — |

## Ticket states

The state a ticket is in, and the move its button offers from there.
Both come from `domain.OrderStatus`: the ordinal in the `status` column
is the contract, the words are not, and renaming one never moves a
ticket to a different state.

| State | The chip says | Its colour | The button says | Was called |
|---|---|---|---|---|
| new | New | info | Start cooking | Pending |
| cooking | Cooking | warning | Mark ready | Preparing |
| ready | Ready | success | Hand off | — |
| served | Served | accent | Close ticket | — |
| closed | Closed | surface subtle | no button | Completed |
| voided | Voided | destructive | no button | — |

A state reads in the same colour on every board, so a glance at the
kitchen wall says how far a ticket has got without reading its number.
The colour is a theme token, not a hex, and a test pins the pairing
between the six states, their words and their tokens.

The button names the move it makes, on the kitchen board and the orders
board alike - so neither has a button called "Next" or "Advance". A
ticket with no state left to move to shows no button at all, because a
caption-less button is a blank one. **Closed** is not a ticket that has
been rung up: it is one whose money has been taken.

## Money and tickets

- **Order** — one ticket, from the moment it is placed. The kitchen and
  the floor both call it an order; `Order 000001` is its number.
- **Line** — one dish on an order.
- **Tender** — the money handed over. **Payment** — the record that it
  was taken. **Change** — what comes back.
- **Void** — an order that never happened. It is never deleted: the
  reason is written down.

## People

- **Role** — how a device runs: Admin, Waiter, Kitchen, Display.
- **Operator** — the person signed in right now.
- **Team member** — an account with a PIN. The database row is still
  `employee`; the screen never says "employee" to a person.

## Appearance

- **Switch theme** — the title bar's palette control. It draws no word:
  a sun when the room is dark and a moon when it is light, so the glyph
  names the theme the tap brings rather than the one it leaves. Its
  accessibility name is the move, `Switch theme`, because a glyph is a
  drawing instruction and not a label.
- **Light / Dark** — the two halves of the day, and the only two a
  **Switch theme** tap can land on. Dark for a room that is dim, light
  for a room that is bright.
- **Warm / Night** — the other two registers, chosen in Settings and
  never by the title bar. Warm is light structure on menu-paper cream,
  for a dining-room tablet; Night is deeper than Dark, for a kitchen
  display at 3am.
- **High contrast** — a derivation, not a fifth palette: the register
  you are looking at with the ink, the washes and the chips pushed
  further from the page. It belongs to the eyes, not to the palette, so
  **Switch theme** carries it across.
- **Appearance** — the Settings card that offers all four registers and
  the contrast. It is a per-device choice: it is kept on the device, in
  `app_config`, and nothing about it is kept for the restaurant. The
  look belongs to the file rather than to the machine, so a database
  that is copied - a kiosk hand-over, the smoke's walkthrough - carries
  the look of the device it came from.
- **Brand colour** — the restaurant's own colour, typed into Settings →
  Company as `#rrggbb`. It is the one colour in the app that belongs to
  the restaurant rather than to the device, so it is saved with the
  company and travels to every till and board on the network. It paints
  the accent, the label on it and the ring round a focused control; it
  never touches the red of a void or the green of a ready ticket, which
  mean the same thing in every restaurant. Left empty, it means the
  restaurant has not chosen, and the register's own accent stands. The
  fixed hues the app falls back on are therefore the **house palette**,
  and never "the brand": in this product the brand is the restaurant's.

## Retired words

Do not use these again in anything an operator reads: Sell, Floor,
People, Catalog, Catalogue, System, Overview, Employees, Control center,
counter, Advance, Pending, Preparing, Completed, and **Theme** as the
name of a button - the control that changes the palette is a glyph with
a name for the move, not a caption spelling the noun it changes.

Retiring a word is not a rename of the code. `Screen.sell`, the
`employee` table, `OrderStatus.pending` and the status integers stay:
they are contracts with the markup's ordinals and with rows already on
disk.

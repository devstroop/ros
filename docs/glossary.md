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

## Retired words

Do not use these again in anything an operator reads: Sell, Floor,
People, Catalog, Catalogue, System, Overview, Employees, Control center,
counter, Advance, Pending, Preparing, Completed.

Retiring a word is not a rename of the code. `Screen.sell`, the
`employee` table, `OrderStatus.pending` and the status integers stay:
they are contracts with the markup's ordinals and with rows already on
disk.

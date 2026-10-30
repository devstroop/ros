# Glossary — the words the product uses for itself

One concept, one word, everywhere: the rail, the status bar, the heading
and the empty state all say the same thing about the same destination.
The test `the product speaks one vocabulary` in
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
counter. `Advance` joins the list when the kitchen buttons name what
they do.

Retiring a word is not a rename of the code. `Screen.sell`, the
`employee` table and the status integers stay: they are contracts with
the markup's ordinals and with rows already on disk.

-- 0025_customer_ledger.sql - append-only customer credit ledger.
--
-- A customer's balance is derived from these rows. Reversals are
-- new rows referencing the original, never edits.

CREATE TABLE customer_ledger (
    id            INTEGER PRIMARY KEY,
    customer_id   INTEGER NOT NULL REFERENCES customer(id) ON DELETE RESTRICT,
    entry_type    INTEGER NOT NULL CHECK (entry_type IN (0, 1, 2)),
    amount_minor  INTEGER NOT NULL,
    reference     TEXT    NOT NULL DEFAULT '',
    reversed_id   INTEGER REFERENCES customer_ledger(id) ON DELETE RESTRICT,
    created_at    INTEGER NOT NULL,
    employee_id   INTEGER NOT NULL REFERENCES employee(id) ON DELETE RESTRICT
) STRICT;

CREATE INDEX customer_ledger_customer_id ON customer_ledger(customer_id);

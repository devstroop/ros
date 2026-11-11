-- 0026_banking.sql - bank accounts and their ledger.

CREATE TABLE bank_account (
    id          INTEGER PRIMARY KEY,
    name        TEXT    NOT NULL,
    account_no  TEXT    NOT NULL DEFAULT '',
    active      INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
    created_at  INTEGER NOT NULL
) STRICT;

CREATE TABLE bank_ledger (
    id            INTEGER PRIMARY KEY,
    account_id    INTEGER NOT NULL REFERENCES bank_account(id) ON DELETE RESTRICT,
    entry_type    INTEGER NOT NULL CHECK (entry_type IN (0, 1)),
    amount_minor  INTEGER NOT NULL CHECK (amount_minor >= 0),
    reference     TEXT    NOT NULL DEFAULT '',
    created_at    INTEGER NOT NULL,
    employee_id   INTEGER NOT NULL REFERENCES employee(id) ON DELETE RESTRICT
) STRICT;

CREATE INDEX bank_ledger_account_id ON bank_ledger(account_id);

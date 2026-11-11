-- 0027_loyalty.sql - loyalty members and their points ledger.

CREATE TABLE loyalty_member (
    id          INTEGER PRIMARY KEY,
    name        TEXT    NOT NULL,
    phone       TEXT    NOT NULL DEFAULT '',
    points      INTEGER NOT NULL DEFAULT 0,
    active      INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
    created_at  INTEGER NOT NULL
) STRICT;

CREATE TABLE loyalty_ledger (
    id            INTEGER PRIMARY KEY,
    member_id     INTEGER NOT NULL REFERENCES loyalty_member(id) ON DELETE RESTRICT,
    entry_type    INTEGER NOT NULL CHECK (entry_type IN (0, 1)),
    points        INTEGER NOT NULL,
    reference     TEXT    NOT NULL DEFAULT '',
    created_at    INTEGER NOT NULL
) STRICT;

CREATE INDEX loyalty_ledger_member_id ON loyalty_ledger(member_id);

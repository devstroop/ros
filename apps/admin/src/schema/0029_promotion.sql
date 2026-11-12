-- 0029_promotion.sql - promotions and gift cards.

CREATE TABLE promotion (
    id            INTEGER PRIMARY KEY,
    name          TEXT    NOT NULL,
    kind          INTEGER NOT NULL CHECK (kind IN (0, 1)),
    value_minor   INTEGER NOT NULL DEFAULT 0,
    active        INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
    starts_at     INTEGER,
    ends_at       INTEGER,
    created_at    INTEGER NOT NULL
) STRICT;

CREATE TABLE gift_card (
    id            INTEGER PRIMARY KEY,
    code          TEXT    NOT NULL UNIQUE,
    balance_minor INTEGER NOT NULL DEFAULT 0,
    active        INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
    created_at    INTEGER NOT NULL
) STRICT;

CREATE INDEX promotion_active ON promotion(active);
CREATE INDEX gift_card_code ON gift_card(code);

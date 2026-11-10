-- 0022_refund.sql - a refund records money given back.
--
-- A voided paid order needs a matching refund so the day's money
-- reconciles. One refund row per voided paid order.

CREATE TABLE refund (
    id            INTEGER PRIMARY KEY,
    payment_id    INTEGER NOT NULL REFERENCES payment(id) ON DELETE CASCADE,
    order_id      INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    amount_minor  INTEGER NOT NULL,
    reason        TEXT    NOT NULL DEFAULT '',
    refunded_at   INTEGER NOT NULL,
    created_at    INTEGER NOT NULL
) STRICT;

CREATE INDEX refund_order ON refund(order_id);

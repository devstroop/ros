-- 0018_order_line_stock.sql - a plate remembers whether the shelf paid for it.
--
-- Stock moves with the order. A line takes its product off the shelf on
-- the device that writes it, and a void puts it back. A peer that applies
-- the same order does the same, so every till sees the same shelf.
--
-- A device that bootstraps from a compacted snapshot does not replay the
-- sale: its stock comes from the snapshot's stock figures. The line still
-- needs to know that a future void must restore it. `stock_taken` is that
-- memory:
--
--   1  the line has a plate in this database's stock figure;
--   0  it does not (a product that is not counted, a closed ticket, or
--      a line restored from a snapshot whose stock is already current).
--
-- A line on an OPEN order keeps 1 even when it arrives in a snapshot,
-- because the snapshot's stock is measured with that plate already sold.
-- Voiding the order afterwards must put it back. A closed order can
-- never be voided, so its lines stay 0.
--
-- Backfill: before this migration the selling device always decremented
-- the stock of an open line. A peer may not have, but the selling device
-- is the one this database is repairing, and a void from the old data
-- must still restore what it took.

ALTER TABLE order_line ADD COLUMN stock_taken INTEGER NOT NULL DEFAULT 0
    CHECK (stock_taken IN (0, 1));

UPDATE order_line SET stock_taken = 1
WHERE EXISTS (
    SELECT 1 FROM orders
    WHERE orders.id = order_line.order_id AND orders.status < 4
)
AND EXISTS (
    SELECT 1 FROM product
    WHERE product.id = order_line.product_id AND product.track_stock = 1
);

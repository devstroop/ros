-- 0016_order_origin.sql - the order has an origin, and a merge can tell
-- two devices apart.
--
-- `orders.id` is still the row this database points at. It is local: a
-- device's wall-clock id, made unique within that device by the floor in
-- `nextOrderId`. It is not a cross-device name, because two devices can
-- mint the same number in the same millisecond.
--
-- The stable name is the pair (`origin_device`, `origin_id`): the device
-- that took the sale, and that device's order id. A create op carries
-- it; a status or payment op carries it too, even when a third device
-- wrote the op. The receiver looks the pair up in this table and uses
-- its own local id.
--
-- A remote order gets a NEGATIVE local id, allocated from the negative
-- side of the integer range. Local ids are positive, so the two
-- namespaces cannot collide. The order's children - lines, status
-- history, payments - point at the local id, and the line ids are
-- namespaced under it as well.
--
-- Existing rows are backfilled from the op log. An old create op's
-- `device_id` is the origin device, and under the old scheme the origin
-- id was the local id. A draft row with no create op has no origin yet;
-- the app treats an empty origin device as "this device" when it writes
-- a status or payment op for it.

ALTER TABLE orders ADD COLUMN origin_device TEXT NOT NULL DEFAULT '';
ALTER TABLE orders ADD COLUMN origin_id INTEGER NOT NULL DEFAULT 0;

UPDATE orders SET
  origin_id = id,
  origin_device = COALESCE(
    (SELECT device_id FROM op_log
     WHERE entity_table = 'order' AND entity_id = CAST(orders.id AS TEXT)
     ORDER BY logical_clock DESC LIMIT 1),
    ''
  );

CREATE INDEX orders_origin ON orders(origin_device, origin_id);

-- A remote order is stored once per origin. The partial index leaves
-- local rows alone: their primary key already makes them unique, and a
-- retried local sale must remain a request-key no-op rather than a
-- second constraint failure.
CREATE UNIQUE INDEX orders_remote_origin
  ON orders(origin_device, origin_id)
  WHERE id < 0;

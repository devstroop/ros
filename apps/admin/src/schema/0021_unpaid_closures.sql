-- 0021_unpaid_closures.sql - a ticket that closed without money is
-- reopened, because it never should have been able to close.
--
-- The rule is that the last step of an order's life is the payment: the
-- kitchen can walk a ticket from new to cooking to ready to served, and
-- only money takes it to `completed`. Until this version the rule lived
-- in `update`, where every guard lives, and `update` is only one of the
-- writers. `setOrderStatus` conditioned its UPDATE on the status the
-- caller held and said nothing about payment, and `applyOrderStatus`
-- applied any monotonic status an op carried - so a peer on an older
-- build, a replayed op, or a snapshot page could park an order in
-- `completed` with no `payment` row behind it.
--
-- That state is not untidy; it is uncollectable. The till refuses to take
-- money for an order it reads as completed, and the payment and the void
-- are the only two statements that release a dining table, so the floor
-- keeps the party and the drawer never gets the cash.
--
-- Served is where a reopened ticket lands. Not `ready` and not
-- `preparing`: those states ring the pass, and a cook who has already
-- cleared the plates should not be told to bring them out again. Served
-- is the step the ticket was standing on when money was asked of it, and
-- from there the till can take the payment and close it properly.
--
-- The history row is written first, and `changed_at` is the order's own
-- `updated_at`. There is no honest timestamp for a state the app never
-- recorded a person entering, and the order's last real movement is the
-- closest thing to one. Without the row the timeline and the status
-- disagree in the other direction: an order back in `served` that the
-- history says has never been there.
--
-- This repairs the database the app is opened on, and only that one. It
-- does not write an op, and a peer cannot be told about it by the normal
-- route: `applyOrderStatus` moves a ticket forward, never back, so a
-- `served` op arriving after a `completed` one would be refused. That is
-- the right outcome. Every device that holds such a row got it from
-- somewhere, so every device repairs its own copy the first time it
-- opens on a build with this version, and the statements guarded in the
-- same release stop any of them writing another one.

INSERT INTO order_status_history (order_id, status, changed_at)
SELECT id, 3, updated_at FROM orders
WHERE status = 4
  AND NOT EXISTS (SELECT 1 FROM payment WHERE payment.order_id = orders.id);

UPDATE orders SET status = 3
WHERE status = 4
  AND NOT EXISTS (SELECT 1 FROM payment WHERE payment.order_id = orders.id);

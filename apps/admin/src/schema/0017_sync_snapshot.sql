-- 0017_sync_snapshot.sql - the log is compacted, and a late joiner
-- starts from the current state instead of the whole history.
--
-- A snapshot is the current order state, not another copy of the log:
-- one create op per order, one status op with the current status, and
-- one payment op when the order is paid. The lines are ordinary wire
-- operations, so a peer applies them through the same idempotent path
-- as a live op. The header carries the per-device clocks the snapshot
-- was taken at; a peer that applies it can then pull only what happened
-- after those clocks.
--
-- Compaction keeps a tail of the log per device. `op_floor` in
-- `sync_state` is the highest clock that was deleted for each device;
-- a peer whose cursor does not cover that floor cannot replay the
-- missing range and asks for `/v1/snapshot` instead.
--
-- `ops_since_compact` is maintained by the trigger below, so the
-- counter survives a restart and the compaction policy does not depend
-- on a process staying up for a fixed number of writes.

ALTER TABLE op_log ADD COLUMN compacted_at INTEGER NOT NULL DEFAULT 0;
CREATE INDEX op_log_retention ON op_log(device_id, logical_clock);

CREATE TABLE sync_snapshot (
    version     INTEGER PRIMARY KEY,
    -- The vector cursor this snapshot covers, in `dev:clock,...` form.
    clocks      TEXT    NOT NULL DEFAULT '',
    created_at  INTEGER NOT NULL
) STRICT;

CREATE TABLE sync_snapshot_op (
    version  INTEGER NOT NULL,
    -- Ordering inside one snapshot: create rows first, then status,
    -- then payment. A page asks for `after` and reads forward.
    seq      INTEGER NOT NULL,
    -- One encoded `record.Op` line. It is the same line the wire uses.
    line     TEXT    NOT NULL,
    PRIMARY KEY (version, seq)
) STRICT;

-- Every op insert moves the compaction counter, including ops applied
-- from a peer and rows written by a test. The counter is reset in the
-- compaction transaction.
CREATE TRIGGER op_log_since_compact
AFTER INSERT ON op_log
BEGIN
    INSERT INTO sync_state (key, value) VALUES ('ops_since_compact', '1')
    ON CONFLICT(key) DO UPDATE SET value = CAST(value AS INTEGER) + 1;
END;

-- An existing database has a log but no counter. Count it now so the
-- first boot after the migration can compact when the log is already
-- large.
INSERT INTO sync_state (key, value)
VALUES ('ops_since_compact', CAST((SELECT COUNT(*) FROM op_log) AS TEXT))
ON CONFLICT(key) DO UPDATE SET value = excluded.value;

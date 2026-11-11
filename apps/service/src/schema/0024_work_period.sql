-- 0024_work_period.sql - a work period is a report and cash boundary.
--
-- A period starts when the operator opens the till and ends when they
-- close it. Reports, cash reconciliation and the Z-report are scoped
-- to the active period. At most one period is active at a time.

CREATE TABLE work_period (
    id          INTEGER PRIMARY KEY,
    started_at  INTEGER NOT NULL,
    ended_at    INTEGER,
    status      INTEGER NOT NULL DEFAULT 0 CHECK (status IN (0, 1)),
    started_by  INTEGER NOT NULL REFERENCES employee(id) ON DELETE RESTRICT,
    ended_by    INTEGER REFERENCES employee(id) ON DELETE RESTRICT
) STRICT;

CREATE INDEX work_period_status ON work_period(status);

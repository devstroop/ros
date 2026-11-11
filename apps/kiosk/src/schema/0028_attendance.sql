-- 0028_attendance.sql - staff clock in / clock out.

CREATE TABLE attendance (
    id          INTEGER PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employee(id) ON DELETE RESTRICT,
    clock_in    INTEGER NOT NULL,
    clock_out   INTEGER,
    CHECK (clock_out IS NULL OR clock_out >= clock_in)
) STRICT;

CREATE INDEX attendance_employee_id ON attendance(employee_id);

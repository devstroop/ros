-- 0019_company_brand.sql - the restaurant's own colour.
--
-- Every device in the room wears the register its operator chose, but
-- the accent they all draw with was the app's: a teal no restaurant was
-- asked about. A brand colour is the company's, the way its name and
-- its currency are, so it belongs on the company row and travels to
-- every device with the reference data.
--
-- Stored as text, as every machine-readable value in this schema is:
-- six hex digits after a hash, or empty. Empty is not black and not a
-- failure - it means the register's own accent, so an unbranded
-- restaurant looks exactly as it did before this column existed.
--
-- Append-only, and the column carries a default, so a database written
-- by an older app upgrades in place and every row it already has gets
-- the empty value.

ALTER TABLE company ADD COLUMN brand_color TEXT NOT NULL DEFAULT '';

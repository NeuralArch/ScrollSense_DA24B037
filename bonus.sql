-- ScrollSense — Assignment 1, Bonus
-- bonus.sql
-- Run after schema.sql and generate_data.py.
-- Covers Bonus §1 (audit-log-style immutability trigger) and
-- Bonus §2 (overlap-prevention trigger on a temporal table).
-- Bonus §3 is deliberately NOT attempted as a trigger — see the
-- written note in master.tex for why, and where that enforcement
-- actually has to live instead.

PRAGMA foreign_keys = ON;

-- ============================================================
-- Bonus §1 — Trigger-based immutability for ModerationDecision.
--
-- This closes the exact gap flagged in E.2's constraint trace table:
-- A10 (append-only moderation history) was enforced only by "the
-- application doesn't expose an UPDATE/DELETE path" -- nothing stopped
-- a raw SQL statement from violating it directly. These two triggers
-- make that violation impossible at the database level, not just the
-- application level.
--
-- SQLite supports FOR EACH ROW triggers only (no statement-level
-- triggers), which is what BEFORE UPDATE/DELETE ... FOR EACH ROW below
-- relies on implicitly -- every row-level UPDATE or DELETE attempt
-- fires the trigger once per affected row before it takes effect.
-- ============================================================

DROP TRIGGER IF EXISTS trg_moddecision_no_update;
CREATE TRIGGER trg_moddecision_no_update
BEFORE UPDATE ON ModerationDecision
BEGIN
    SELECT RAISE(ABORT, 'ModerationDecision is append-only: UPDATE not permitted (A10)');
END;

DROP TRIGGER IF EXISTS trg_moddecision_no_delete;
CREATE TRIGGER trg_moddecision_no_delete
BEFORE DELETE ON ModerationDecision
BEGIN
    SELECT RAISE(ABORT, 'ModerationDecision is append-only: DELETE not permitted (A10)');
END;


-- ============================================================
-- Bonus §2 — Trigger preventing overlapping validity intervals.
--
-- Applied to CreatorTierPeriod (chosen over ModelPricingPeriod/
-- PromptTemplateVersion because it has the simplest key shape to
-- demonstrate against). PostgreSQL would express this declaratively
-- with an EXCLUDE constraint using a range type and the && overlap
-- operator; SQLite has neither range types nor EXCLUDE, so the check
-- is hand-written here as two triggers (INSERT and UPDATE separately,
-- since SQLite triggers are per-operation, not shared).
--
-- What this version CANNOT guarantee that PostgreSQL's EXCLUDE would:
--   1. It only fires on single-row INSERT/UPDATE through normal SQL --
--      a bulk load path that bypasses per-row triggers (there is no
--      such path in ordinary SQLite DML, but a corrupted/malicious
--      direct file write would not be caught).
--   2. It re-checks only the row being written, not global consistency
--      -- if the table already contains an overlap (e.g. loaded before
--      this trigger existed, as E.3's generator did), the trigger does
--      not retroactively detect or repair it.
--   3. Under SQLite's single-writer model (T3), no genuine race
--      condition between two concurrent overlapping inserts can occur
--      within one file the way it could under a true multi-writer
--      MVCC engine -- so this trigger is stricter than it strictly
--      needs to be for correctness here, but would still be necessary
--      in a hypothetical multi-writer deployment.
-- ============================================================

DROP TRIGGER IF EXISTS trg_creatortier_no_overlap_insert;
CREATE TRIGGER trg_creatortier_no_overlap_insert
BEFORE INSERT ON CreatorTierPeriod
BEGIN
    SELECT RAISE(ABORT, 'Overlapping validity interval for this creator (Bonus 2)')
    WHERE EXISTS (
        SELECT 1 FROM CreatorTierPeriod existing
        WHERE existing.creator_id = NEW.creator_id
          AND NEW.valid_from < COALESCE(existing.valid_to, '9999-12-31T23:59:59Z')
          AND COALESCE(NEW.valid_to, '9999-12-31T23:59:59Z') > existing.valid_from
    );
END;

DROP TRIGGER IF EXISTS trg_creatortier_no_overlap_update;
CREATE TRIGGER trg_creatortier_no_overlap_update
BEFORE UPDATE ON CreatorTierPeriod
BEGIN
    SELECT RAISE(ABORT, 'Overlapping validity interval for this creator (Bonus 2)')
    WHERE EXISTS (
        SELECT 1 FROM CreatorTierPeriod existing
        WHERE existing.creator_id = NEW.creator_id
          AND existing.valid_from != OLD.valid_from  -- exclude the row being updated
          AND NEW.valid_from < COALESCE(existing.valid_to, '9999-12-31T23:59:59Z')
          AND COALESCE(NEW.valid_to, '9999-12-31T23:59:59Z') > existing.valid_from
    );
END;

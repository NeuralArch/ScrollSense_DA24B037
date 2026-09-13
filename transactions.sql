-- ScrollSense — Assignment 1, Deliverable G.3
-- transactions.sql
-- Every failure mode below was actually executed and verified (see
-- master.tex G.3 for the exact terminal output), not merely asserted.

PRAGMA foreign_keys = ON;

-- ============================================================
-- T1 — Retraction must be atomic.
--
-- IMPORTANT — a real finding, not a template assumption: SQLite's
-- SELECT 1/0 does NOT raise an error (integer division by zero returns
-- NULL in SQLite, unlike Postgres/MySQL). The task sheet's suggested
-- "SELECT 1/0;" failure injector does not work as a failure mechanism
-- in SQLite and was replaced here with a genuine constraint violation.
--
-- SECOND real finding: SQLite's default ON CONFLICT ABORT resolution
-- aborts only the FAILING STATEMENT, not the whole transaction. The
-- transaction remains open (conn.in_transaction == True) with the
-- earlier successful INSERT still uncommitted. An explicit ROLLBACK is
-- required — if a COMMIT were issued instead at this point (the naive
-- reading of "COMMIT; -- will not be reached"), the first INSERT WOULD
-- be committed, because it was never automatically undone.
-- ============================================================

BEGIN;
    -- Step 1: write the retraction for a real, unretracted like
    -- (signal_id 1935 used here; substitute any unretracted like id)
    INSERT INTO LikeRetraction (retraction_id, like_signal_id, retracted_at)
    VALUES (999905, 1935, '2026-01-01T00:00:05Z');

    -- deliberate failure: a second retraction for the SAME like violates
    -- UNIQUE(like_signal_id) -- a genuine constraint violation
    INSERT INTO LikeRetraction (retraction_id, like_signal_id, retracted_at)
    VALUES (999906, 1935, '2026-01-01T00:00:10Z');
    -- Runtime error: UNIQUE constraint failed: LikeRetraction.like_signal_id
    -- The transaction is still OPEN at this point -- the first INSERT has
    -- not been undone automatically.

ROLLBACK;  -- REQUIRED explicitly; this is what actually undoes both inserts

-- Proof of consistency: neither retraction row exists.
SELECT COUNT(*) AS should_be_zero
FROM LikeRetraction WHERE retraction_id IN (999905, 999906);
-- Verified result: 0


-- ============================================================
-- T2 — Moderation decision visibility under WAL.
-- Verified with two real concurrent sqlite3 connections to this file.
--
-- Connection A:
--   BEGIN;
--   INSERT INTO ModerationDecision (video_id, decided_at, state, decided_by_type)
--   VALUES (1, '2026-09-13T12:00:00Z', 'taken_down', 'human');
--   -- do NOT commit yet
--
-- Connection B (while A is still open):
--   SELECT current_state FROM v_video_current_state WHERE video_id = 1;
--   -- VERIFIED result: 'live' (the OLD state) -- A's uncommitted write
--   -- is invisible to B under WAL's snapshot isolation
--
-- Connection A:
--   COMMIT;
--
-- Connection B (re-query):
--   SELECT current_state FROM v_video_current_state WHERE video_id = 1;
--   -- VERIFIED result: 'taken_down' -- now visible after commit
--
-- This demonstration specifically requires journal_mode = WAL (set at
-- the top of schema.sql). Under the default rollback-journal mode,
-- Connection B's read would instead BLOCK until A releases its lock,
-- rather than showing a consistent pre-write snapshot -- a materially
-- different (and less interesting) demonstration.
-- ============================================================


-- ============================================================
-- T3 — Handle change limited to twice a year; SQLITE_BUSY.
-- ============================================================

CREATE TABLE IF NOT EXISTS HandleChangeLog (
    user_id     INTEGER NOT NULL REFERENCES AppUser(user_id),
    changed_at  TEXT NOT NULL,
    old_handle  TEXT NOT NULL,
    new_handle  TEXT NOT NULL
);

-- Two changes within the same rolling year for user_id = 1:
INSERT INTO HandleChangeLog VALUES (1, '2026-01-10T00:00:00Z', 'user1_orig', 'user1_v2');
UPDATE AppUser SET handle = 'user1_v2' WHERE user_id = 1;

INSERT INTO HandleChangeLog VALUES (1, '2026-04-10T00:00:00Z', 'user1_v2', 'user1_v3');
UPDATE AppUser SET handle = 'user1_v3' WHERE user_id = 1;

-- Third attempt within the same twelve months: application code checks
-- this count BEFORE allowing the change (no declarative CHECK can express
-- a rolling-window count -- see E.2's trace for A6's non-declarative half).
SELECT COUNT(*) AS changes_in_last_year
FROM HandleChangeLog
WHERE user_id = 1 AND changed_at > '2025-04-10T00:00:00Z';
-- Result: 2 -- the application must refuse a third change here, since
-- SQLite itself has no mechanism to enforce this and will silently
-- accept a third UPDATE if the application doesn't check first.

-- SQLITE_BUSY demonstration (two real concurrent connections, verified):
--
-- Connection A:
--   BEGIN IMMEDIATE;
--   UPDATE AppUser SET handle = 'blocking_write' WHERE user_id = 2;
--   -- do NOT commit
--
-- Connection B (while A holds the write lock):
--   BEGIN IMMEDIATE;
--   UPDATE AppUser SET handle = 'should_fail' WHERE user_id = 3;
--   -- VERIFIED result: "OperationalError: database is locked" (SQLITE_BUSY)
--
-- Connection A:
--   ROLLBACK;  -- or COMMIT
--
-- What this shows: SQLite allows exactly one writer at a time across the
-- ENTIRE database file (not per-row or per-table locking), so it
-- sidesteps the lost-update anomaly a multi-writer engine must instead
-- solve with row-level locking or MVCC conflict detection -- at the cost
-- of forcing every concurrent writer but one to block or fail outright,
-- even when, as here, the two writers touch entirely unrelated rows
-- (user 2 and user 3).

-- ScrollSense — Assignment 1, Deliverable E.1
-- schema.sql
-- Run against an empty SQLite 3.44+ database file.

PRAGMA foreign_keys = ON;   -- SQLite ignores every declared FK without this
PRAGMA journal_mode = WAL;  -- needed for G.3's concurrency demonstration

-- ============================================================
-- Timestamp convention: ISO-8601 UTC text, e.g. '2026-03-03T14:32:07Z'
-- used on every timestamp column in this file, without exception.
-- See E.1 written note for why, and its consequence for F3/F9/F10.
-- ============================================================

-- ------------------------------------------------------------
-- Identity
-- ------------------------------------------------------------

CREATE TABLE AppUser (
    user_id        INTEGER PRIMARY KEY,
    phone          TEXT,
    google_id      TEXT,
    handle         TEXT NOT NULL,
    display_name   TEXT NOT NULL,
    account_state  TEXT NOT NULL DEFAULT 'active'
                   CHECK (account_state IN ('active','deactivated','pending_deletion')),
    deletion_requested_at TEXT,   -- NULL unless account_state = 'pending_deletion'
    created_at     TEXT NOT NULL,
    CHECK (phone IS NOT NULL OR google_id IS NOT NULL),
    UNIQUE (handle COLLATE NOCASE)
    -- NOTE: this UNIQUE is GLOBAL, not "among active accounts" (A6).
    -- SQLite cannot express a partial/filtered UNIQUE constraint, so the
    -- "only among active accounts" half of A6 is enforced at the
    -- application layer (checked before every handle write), not here.
    -- Traced in E.2.
);

CREATE TABLE UserInterestDeclared (
    user_id      INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    category     TEXT NOT NULL,
    declared_at  TEXT NOT NULL,
    PRIMARY KEY (user_id, category)
);
-- ON DELETE CASCADE: a declared interest has no meaning once its user
-- is gone, and no other table references this row.

CREATE TABLE UserInterestInferred (
    user_id       INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    category      TEXT NOT NULL,
    refreshed_at  TEXT NOT NULL,
    confidence    REAL NOT NULL CHECK (confidence BETWEEN 0.0 AND 1.0),
    PRIMARY KEY (user_id, category, refreshed_at)
);

CREATE TABLE InterestSuppression (
    user_id        INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    category       TEXT NOT NULL,
    suppressed_at  TEXT NOT NULL,
    PRIMARY KEY (user_id, category)
);

CREATE TABLE CreatorTierPeriod (
    creator_id   INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    tier         TEXT NOT NULL,
    valid_from   TEXT NOT NULL,
    valid_to     TEXT,   -- NULL = current tier
    PRIMARY KEY (creator_id, valid_from)
);
-- ON DELETE CASCADE: Finance's "tier last March" question presumes the
-- creator still exists to be asked about; if the account is truly
-- deleted (past the 30-day window), tier history goes with it.

CREATE TABLE Follow (
    follower_id  INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    followee_id  INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    started_at   TEXT NOT NULL,
    ended_at     TEXT,   -- NULL = still following
    PRIMARY KEY (follower_id, followee_id, started_at),
    CHECK (follower_id != followee_id)
);

CREATE TABLE Block (
    blocker_id  INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    blocked_id  INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    started_at  TEXT NOT NULL,
    PRIMARY KEY (blocker_id, blocked_id, started_at),
    CHECK (blocker_id != blocked_id)
);

CREATE TABLE Mute (
    muter_id   INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    muted_id   INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    started_at TEXT NOT NULL,
    PRIMARY KEY (muter_id, muted_id, started_at),
    CHECK (muter_id != muted_id)
);

-- ------------------------------------------------------------
-- Content
-- ------------------------------------------------------------

CREATE TABLE AudioTrack (
    track_id         INTEGER PRIMARY KEY,
    origin_video_id  INTEGER,   -- FK added after Video exists (circular ref)
    source           TEXT NOT NULL CHECK (source IN ('original','licensed')),
    license_ref      TEXT       -- NULL unless source = 'licensed'
);

CREATE TABLE Video (
    video_id        INTEGER PRIMARY KEY,
    owner_id        INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE RESTRICT,
    duration_ms     INTEGER NOT NULL CHECK (duration_ms BETWEEN 20000 AND 90000),
    caption         TEXT NOT NULL DEFAULT '',
    audio_track_id  INTEGER REFERENCES AudioTrack(track_id) ON DELETE SET NULL,
    uploaded_at     TEXT NOT NULL
);
-- owner_id ON DELETE RESTRICT: a video must not silently become
-- ownerless or vanish when a user record is removed; deletion of a
-- creator with live videos must be handled explicitly by the
-- application (reassign or take down first), not implicitly by the DB.
-- audio_track_id ON DELETE SET NULL: losing a shared track (e.g. a
-- licence expiring) should not delete the videos that used it.

-- deferred FK, since AudioTrack.origin_video_id -> Video and
-- Video.audio_track_id -> AudioTrack are mutually referencing;
-- SQLite has no ALTER TABLE ... ADD CONSTRAINT, so this must be
-- declared at CREATE TABLE time in whichever table is created second,
-- as DEFERRABLE INITIALLY DEFERRED so the insert order doesn't matter
-- within one transaction.
CREATE TABLE AudioTrackOrigin (
    -- workaround table: SQLite disallows adding the FK after the fact
    -- and disallows a forward reference at CREATE TABLE time without
    -- deferral, so origin_video_id's FK is expressed as a satellite
    -- 1:1 table rather than reopening AudioTrack.
    track_id   INTEGER PRIMARY KEY REFERENCES AudioTrack(track_id) ON DELETE CASCADE,
    video_id   INTEGER NOT NULL REFERENCES Video(video_id)
               DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE ModerationDecision (
    video_id         INTEGER NOT NULL REFERENCES Video(video_id) ON DELETE CASCADE,
    decided_at       TEXT NOT NULL,
    state            TEXT NOT NULL
                     CHECK (state IN ('pending','live','age_restricted','demoted','taken_down')),
    decided_by_type  TEXT NOT NULL CHECK (decided_by_type IN ('automated','human')),
    decided_by_id    INTEGER,   -- NULL if automated classifier, not a human reviewer id
    PRIMARY KEY (video_id, decided_at)
);
-- append-only by convention (A10, B.3-1): no UPDATE/DELETE path is
-- exposed in the application layer for this table.

-- ------------------------------------------------------------
-- Watch telemetry
-- ------------------------------------------------------------

CREATE TABLE Impression (
    impression_id  INTEGER PRIMARY KEY,
    user_id        INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    video_id       INTEGER NOT NULL REFERENCES Video(video_id) ON DELETE CASCADE,
    ts             TEXT NOT NULL,
    feed_position  INTEGER NOT NULL,
    model_version  TEXT NOT NULL
);

CREATE TABLE View (
    view_id        INTEGER PRIMARY KEY,
    impression_id  INTEGER NOT NULL UNIQUE
                   REFERENCES Impression(impression_id) ON DELETE CASCADE,
    started_at     TEXT NOT NULL
);

CREATE TABLE ViewSegment (
    view_id      INTEGER NOT NULL REFERENCES View(view_id) ON DELETE CASCADE,
    segment_seq  INTEGER NOT NULL,
    watch_ms     INTEGER NOT NULL CHECK (watch_ms > 0),
    completed    INTEGER NOT NULL DEFAULT 0 CHECK (completed IN (0,1)),
    PRIMARY KEY (view_id, segment_seq)
);

CREATE TABLE EngagementSignal (
    signal_id          INTEGER PRIMARY KEY,
    user_id            INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    video_id           INTEGER NOT NULL REFERENCES Video(video_id) ON DELETE CASCADE,
    signal_type        TEXT NOT NULL CHECK (signal_type IN
                       ('like','save','share','comment','follow_from_feed',
                        'not_interested','report')),
    ts                 TEXT NOT NULL,
    share_destination  TEXT CHECK (share_destination IS NULL OR
                       share_destination IN ('whatsapp','instagram','copied_link')),
    comment_text       TEXT,
    CHECK ( (signal_type = 'share')   = (share_destination IS NOT NULL) ),
    CHECK ( (signal_type = 'comment') = (comment_text IS NOT NULL) )
);
-- The two CHECKs above enforce "share_destination only when sharing,
-- always when sharing" and likewise for comment_text — this is the
-- declarative half of the NULL-means-doesn't-apply distinction from
-- the NOT NULL audit below.

CREATE TABLE LikeRetraction (
    retraction_id    INTEGER PRIMARY KEY,
    like_signal_id   INTEGER NOT NULL UNIQUE
                     REFERENCES EngagementSignal(signal_id) ON DELETE CASCADE,
    retracted_at     TEXT NOT NULL
);

-- ------------------------------------------------------------
-- Agent layer
-- ------------------------------------------------------------

CREATE TABLE AgentSession (
    session_id  INTEGER PRIMARY KEY,
    user_id     INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    started_at  TEXT NOT NULL
);

CREATE TABLE PromptTemplateVersion (
    template_id  INTEGER NOT NULL,
    version      INTEGER NOT NULL,
    valid_from   TEXT NOT NULL,
    valid_to     TEXT,
    text         TEXT NOT NULL,
    PRIMARY KEY (template_id, version)
);

CREATE TABLE ModelPricingPeriod (
    model_id    TEXT NOT NULL,
    rate_type   TEXT NOT NULL CHECK (rate_type IN ('input','output','cached_input')),
    valid_from  TEXT NOT NULL,
    valid_to    TEXT,
    rate        REAL NOT NULL CHECK (rate >= 0),
    PRIMARY KEY (model_id, rate_type, valid_from)
);

CREATE TABLE AgentTurn (
    turn_id            INTEGER PRIMARY KEY,
    session_id         INTEGER NOT NULL REFERENCES AgentSession(session_id) ON DELETE CASCADE,
    seq                INTEGER NOT NULL,
    user_message       TEXT NOT NULL,
    assistant_message  TEXT NOT NULL,
    template_id        INTEGER NOT NULL,
    template_version   INTEGER NOT NULL,
    model_id           TEXT NOT NULL,
    temperature        REAL NOT NULL CHECK (temperature BETWEEN 0.0 AND 2.0),
    created_at         TEXT NOT NULL,
    FOREIGN KEY (template_id, template_version)
        REFERENCES PromptTemplateVersion(template_id, version),
    UNIQUE (session_id, seq)
);

CREATE TABLE ToolCall (
    tool_call_id         INTEGER PRIMARY KEY,
    turn_id              INTEGER NOT NULL REFERENCES AgentTurn(turn_id) ON DELETE CASCADE,
    parent_tool_call_id  INTEGER REFERENCES ToolCall(tool_call_id) ON DELETE CASCADE,
    name                 TEXT NOT NULL,
    arguments_json       TEXT NOT NULL CHECK (json_valid(arguments_json)),
    result               TEXT,          -- NULL until the call returns
    latency_ms           INTEGER,       -- NULL until the call returns
    errored              INTEGER NOT NULL DEFAULT 0 CHECK (errored IN (0,1))
);
-- arguments_json is the one deliberate JSON use in this schema — see
-- E.4. result/latency_ms are NULL meaning "not yet known" (the call is
-- in flight), distinct from every other NULL in this file, which is
-- flagged in the NOT NULL audit.

CREATE TABLE TurnUsage (
    turn_id        INTEGER PRIMARY KEY REFERENCES AgentTurn(turn_id) ON DELETE CASCADE,
    model_id       TEXT NOT NULL,
    priced_at      TEXT NOT NULL,
    input_tokens   INTEGER NOT NULL CHECK (input_tokens >= 0),
    output_tokens  INTEGER NOT NULL CHECK (output_tokens >= 0),
    cached_tokens  INTEGER NOT NULL DEFAULT 0 CHECK (cached_tokens >= 0)
);

CREATE TABLE Recommendation (
    turn_id        INTEGER NOT NULL REFERENCES AgentTurn(turn_id) ON DELETE CASCADE,
    position       INTEGER NOT NULL CHECK (position > 0),
    video_id       INTEGER NOT NULL REFERENCES Video(video_id) ON DELETE CASCADE,
    impression_id  INTEGER UNIQUE REFERENCES Impression(impression_id) ON DELETE SET NULL,
    PRIMARY KEY (turn_id, position)
);
-- impression_id ON DELETE SET NULL: if the impression row is ever
-- purged (it shouldn't be, under A3, but defensively), the
-- recommendation itself — the fact that this clip was shown at this
-- position — should survive; only the link to what happened next is lost.

CREATE TABLE JudgeScore (
    turn_id       INTEGER NOT NULL REFERENCES AgentTurn(turn_id) ON DELETE CASCADE,
    judged_at     TEXT NOT NULL,
    helpfulness   INTEGER NOT NULL CHECK (helpfulness BETWEEN 1 AND 5),
    groundedness  INTEGER NOT NULL CHECK (groundedness BETWEEN 1 AND 5),
    safety        INTEGER NOT NULL CHECK (safety BETWEEN 1 AND 5),
    PRIMARY KEY (turn_id, judged_at)
);

CREATE TABLE UserRating (
    turn_id     INTEGER PRIMARY KEY REFERENCES AgentTurn(turn_id) ON DELETE CASCADE,
    rated_at    TEXT NOT NULL,
    thumbs_up   INTEGER NOT NULL CHECK (thumbs_up IN (0,1))
);

-- ------------------------------------------------------------
-- Indexes supporting the query workload (F1–F13)
-- ------------------------------------------------------------

CREATE INDEX idx_impression_video_ts   ON Impression(video_id, ts);
CREATE INDEX idx_impression_user_ts    ON Impression(user_id, ts);
CREATE INDEX idx_signal_video_type     ON EngagementSignal(video_id, signal_type);
CREATE INDEX idx_moddecision_video     ON ModerationDecision(video_id, decided_at);
CREATE INDEX idx_agentturn_session     ON AgentTurn(session_id, seq);
CREATE INDEX idx_toolcall_turn         ON ToolCall(turn_id);
CREATE INDEX idx_toolcall_parent       ON ToolCall(parent_tool_call_id);

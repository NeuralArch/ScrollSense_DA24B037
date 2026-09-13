-- ScrollSense — Assignment 1, Deliverable F
-- queries.sql
-- Run with: sqlite3 scrollsense.db < queries.sql
-- PRAGMA foreign_keys = ON is set for consistency, though these are all reads.

PRAGMA foreign_keys = ON;

-- ============================================================
-- F1 — Top 10 audio tracks by distinct videos in the last 7 days
-- ============================================================
SELECT at.track_id,
       COUNT(DISTINCT v.video_id) AS distinct_videos
FROM AudioTrack at
JOIN Video v ON v.audio_track_id = at.track_id
WHERE v.uploaded_at >= datetime('2026-08-25T00:00:00Z')  -- last 7 days of sim window
GROUP BY at.track_id
ORDER BY distinct_videos DESC
LIMIT 10;


-- ============================================================
-- F2 — Watch hours and mean completion rate per creator, live clips only
-- every creator must appear, including zero-live and never-watched
-- ============================================================
WITH live_videos AS (
    SELECT v.video_id, v.owner_id
    FROM Video v
    WHERE (
        SELECT md.state FROM ModerationDecision md
        WHERE md.video_id = v.video_id
        ORDER BY md.decided_at DESC LIMIT 1
    ) = 'live'
),
telemetry AS (
    SELECT lv.owner_id,
           SUM(vs.watch_ms) AS watch_ms_total,
           AVG(vs.completed) AS completion_rate
    FROM live_videos lv
    LEFT JOIN Impression i ON i.video_id = lv.video_id
    LEFT JOIN View vw ON vw.impression_id = i.impression_id
    LEFT JOIN ViewSegment vs ON vs.view_id = vw.view_id
    GROUP BY lv.owner_id
)
SELECT au.user_id AS creator_id,
       COALESCE(t.watch_ms_total, 0) / 3600000.0 AS watch_hours,
       COALESCE(t.completion_rate, 0.0) AS mean_completion_rate
FROM AppUser au
LEFT JOIN telemetry t ON t.owner_id = au.user_id
WHERE au.user_id IN (SELECT DISTINCT owner_id FROM Video)
ORDER BY watch_hours DESC;


-- ============================================================
-- F3 — Videos with no audio track: NOT IN vs NOT EXISTS
-- ============================================================
-- NOT IN version: compares the nullable audio_track_id against the
-- (never-null) AudioTrack.track_id. This is the classic trap: SQL's
-- "NULL NOT IN (...)" evaluates to NULL (unknown), not TRUE, so every
-- row whose audio_track_id IS NULL is silently excluded from the result.
SELECT COUNT(*) AS not_in_count
FROM Video
WHERE audio_track_id NOT IN (SELECT track_id FROM AudioTrack);

-- NOT EXISTS version: correlated, and NULL-safe by construction --
-- a NULL audio_track_id can never equal any track_id, so the NOT EXISTS
-- correctly reports "true, no matching track" for every such row.
SELECT COUNT(*) AS not_exists_count
FROM Video v
WHERE NOT EXISTS (SELECT 1 FROM AudioTrack at WHERE at.track_id = v.audio_track_id);


-- ============================================================
-- F4 — Users who liked and then retracted within 60 seconds
-- ============================================================
SELECT es.user_id, es.video_id, es.ts AS liked_at, lr.retracted_at
FROM EngagementSignal es
JOIN LikeRetraction lr ON lr.like_signal_id = es.signal_id
WHERE es.signal_type = 'like'
  AND (julianday(lr.retracted_at) - julianday(es.ts)) * 86400.0 <= 60;


-- ============================================================
-- F5 — Videos whose caption carries a given hashtag
-- case-insensitive, tolerant of surrounding punctuation/whitespace
-- ============================================================
SELECT video_id, caption
FROM Video
WHERE instr(
    ' ' || lower(trim(replace(replace(caption, char(10), ' '), char(9), ' '))) || ' ',
    ' #comedy '
) > 0
   OR lower(caption) LIKE '%#comedy%';
-- Uses lower() for ASCII case-insensitivity; GLOB is case-sensitive so LIKE
-- is the correct choice here. For a Tamil hashtag, lower() is a no-op (Tamil
-- has no case), so matching still works correctly for exact Tamil text, but
-- would not fold any Latin/Tamil mixed-script variant spelling differences.


-- ============================================================
-- F6 — Users shown a creator's clips but never engaged (set operator)
-- plus one roll-up shown with UNION and UNION ALL
-- ============================================================
-- users shown but never engaged, via EXCEPT
SELECT DISTINCT i.user_id
FROM Impression i
JOIN Video v ON v.video_id = i.video_id
WHERE v.owner_id = 2208
EXCEPT
SELECT DISTINCT es.user_id
FROM EngagementSignal es
JOIN Video v ON v.video_id = es.video_id
WHERE v.owner_id = 2208;

-- UNION vs UNION ALL row-count comparison on one signal roll-up
SELECT user_id FROM EngagementSignal WHERE signal_type = 'like'
UNION
SELECT user_id FROM EngagementSignal WHERE signal_type = 'save';

SELECT user_id FROM EngagementSignal WHERE signal_type = 'like'
UNION ALL
SELECT user_id FROM EngagementSignal WHERE signal_type = 'save';


-- ============================================================
-- F7 — Cost per agent session last month, by template version, above a threshold
-- ============================================================
WITH turn_cost AS (
    SELECT tu.turn_id,
           at.session_id,
           at.template_id,
           at.template_version,
           (tu.input_tokens * mpp_in.rate
            + tu.output_tokens * mpp_out.rate
            + tu.cached_tokens * mpp_cache.rate) AS turn_cost
    FROM TurnUsage tu
    JOIN AgentTurn at ON at.turn_id = tu.turn_id
    JOIN ModelPricingPeriod mpp_in
        ON mpp_in.model_id = tu.model_id AND mpp_in.rate_type = 'input'
        AND tu.priced_at >= mpp_in.valid_from
        AND (mpp_in.valid_to IS NULL OR tu.priced_at < mpp_in.valid_to)
    JOIN ModelPricingPeriod mpp_out
        ON mpp_out.model_id = tu.model_id AND mpp_out.rate_type = 'output'
        AND tu.priced_at >= mpp_out.valid_from
        AND (mpp_out.valid_to IS NULL OR tu.priced_at < mpp_out.valid_to)
    JOIN ModelPricingPeriod mpp_cache
        ON mpp_cache.model_id = tu.model_id AND mpp_cache.rate_type = 'cached_input'
        AND tu.priced_at >= mpp_cache.valid_from
        AND (mpp_cache.valid_to IS NULL OR tu.priced_at < mpp_cache.valid_to)
)
SELECT session_id, template_id, template_version, SUM(turn_cost) AS session_cost
FROM turn_cost
GROUP BY session_id, template_id, template_version
HAVING SUM(turn_cost) > 0.01
ORDER BY session_cost DESC;


-- ============================================================
-- F8 — Videos whose moderation state changed more than twice,
-- with the full chronological sequence (needs SQLite 3.44+ for ORDER BY in group_concat)
-- ============================================================
SELECT video_id,
       COUNT(*) AS n_decisions,
       group_concat(state, ' -> ' ORDER BY decided_at) AS sequence
FROM ModerationDecision
GROUP BY video_id
HAVING COUNT(*) > 2
ORDER BY n_decisions DESC;


-- ============================================================
-- F9 — Each user's longest streak of consecutive active days
-- "active" = had at least one impression that day
-- ============================================================
WITH active_days AS (
    SELECT DISTINCT user_id, date(ts) AS d
    FROM Impression
),
numbered AS (
    SELECT user_id, d,
           julianday(d) - ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY d) AS grp
    FROM active_days
),
streaks AS (
    SELECT user_id, grp, COUNT(*) AS streak_len
    FROM numbered
    GROUP BY user_id, grp
)
SELECT user_id, MAX(streak_len) AS longest_streak
FROM streaks
GROUP BY user_id
ORDER BY longest_streak DESC
LIMIT 20;


-- ============================================================
-- F10 — Rank creators by 7-day rolling watch time, week-over-week change
-- "7 days" = seven calendar days, per creator's own daily totals
-- ============================================================
WITH daily_watch AS (
    SELECT v.owner_id AS creator_id,
           date(i.ts) AS d,
           SUM(vs.watch_ms) AS watch_ms
    FROM Video v
    JOIN Impression i ON i.video_id = v.video_id
    JOIN View vw ON vw.impression_id = i.impression_id
    JOIN ViewSegment vs ON vs.view_id = vw.view_id
    GROUP BY v.owner_id, date(i.ts)
),
rolling AS (
    SELECT creator_id, d, watch_ms,
           SUM(watch_ms) OVER (
               PARTITION BY creator_id
               ORDER BY julianday(d)
               RANGE BETWEEN 6 PRECEDING AND CURRENT ROW
           ) AS rolling_7d_ms
    FROM daily_watch
)
SELECT creator_id, d, rolling_7d_ms,
       rolling_7d_ms - LAG(rolling_7d_ms, 7) OVER (PARTITION BY creator_id ORDER BY julianday(d)) AS wow_change_ms,
       RANK() OVER (PARTITION BY d ORDER BY rolling_7d_ms DESC) AS daily_rank
FROM rolling
ORDER BY d DESC, daily_rank
LIMIT 30;


-- ============================================================
-- F11 — Full nesting tree for a given agent session's tool calls, with depth
-- ============================================================
WITH RECURSIVE call_tree AS (
    SELECT tc.tool_call_id, tc.turn_id, tc.parent_tool_call_id, tc.name,
           0 AS depth
    FROM ToolCall tc
    JOIN AgentTurn at ON at.turn_id = tc.turn_id
    WHERE at.session_id = 235 AND tc.parent_tool_call_id IS NULL

    UNION ALL

    SELECT tc.tool_call_id, tc.turn_id, tc.parent_tool_call_id, tc.name,
           ct.depth + 1
    FROM ToolCall tc
    JOIN call_tree ct ON tc.parent_tool_call_id = ct.tool_call_id
)
SELECT tool_call_id, turn_id, name, depth
FROM call_tree
ORDER BY turn_id, depth;


-- ============================================================
-- F12 — Sessions where the agent recommended a clip watched to completion,
-- with the clip's shelf position (the spine query)
-- ============================================================
SELECT s.session_id, r.turn_id, r.position, r.video_id
FROM Recommendation r
JOIN AgentTurn at ON at.turn_id = r.turn_id
JOIN AgentSession s ON s.session_id = at.session_id
JOIN Impression i ON i.impression_id = r.impression_id
JOIN View v ON v.impression_id = i.impression_id
JOIN ViewSegment vs ON vs.view_id = v.view_id
WHERE vs.completed = 1
GROUP BY s.session_id, r.turn_id, r.position, r.video_id;


-- ============================================================
-- F13 — Turns where judge score > 4 (any dimension) but user thumbs-down
-- ============================================================
SELECT at.turn_id, js.helpfulness, js.groundedness, js.safety, ur.thumbs_up
FROM AgentTurn at
JOIN JudgeScore js ON js.turn_id = at.turn_id
JOIN UserRating ur ON ur.turn_id = at.turn_id
WHERE (js.helpfulness > 4 OR js.groundedness > 4 OR js.safety > 4)
  AND ur.thumbs_up = 0;

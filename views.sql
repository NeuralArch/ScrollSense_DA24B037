-- ScrollSense — Assignment 1, Deliverable G.1
-- views.sql
-- Run after schema.sql and generate_data.py.

PRAGMA foreign_keys = ON;

-- ============================================================
-- v_public_profile — consumer: mobile client
-- Must expose handle, display name, follower count.
-- Must NOT expose phone/email, and must not return accounts that
-- are deactivated or inside the deletion window.
-- ============================================================
DROP VIEW IF EXISTS v_public_profile;
CREATE VIEW v_public_profile AS
SELECT
    au.user_id,
    au.handle,
    au.display_name,
    (SELECT COUNT(*) FROM Follow f
     WHERE f.followee_id = au.user_id AND f.ended_at IS NULL) AS follower_count
FROM AppUser au
WHERE au.account_state = 'active';
-- phone, google_id, deletion_requested_at, and account_state itself are
-- never selected, so the mobile client has no path to them through this
-- view regardless of what it asks for. 'deactivated' and 'pending_deletion'
-- accounts are excluded by the WHERE clause, so an account inside its
-- 30-day recovery window never appears here (A6/E.2).


-- ============================================================
-- v_video_current_state — consumer: Trust & Safety
-- The current moderation state of every video, in one lookup,
-- derived from the append-only ModerationDecision log (A7/B.3-1).
-- ============================================================
DROP VIEW IF EXISTS v_video_current_state;
CREATE VIEW v_video_current_state AS
SELECT
    v.video_id,
    COALESCE(latest.state, 'pending') AS current_state,
    latest.decided_at AS state_as_of
FROM Video v
LEFT JOIN (
    SELECT md.video_id, md.state, md.decided_at
    FROM ModerationDecision md
    WHERE md.decided_at = (
        SELECT MAX(md2.decided_at) FROM ModerationDecision md2
        WHERE md2.video_id = md.video_id
    )
) latest ON latest.video_id = v.video_id;
-- A video with zero decisions yet defaults to 'pending' rather than NULL,
-- matching §2.2's description of the moderation state machine's start point.


-- ============================================================
-- v_creator_tier_current — consumer: Growth
-- Each creator's tier as of now, from the validity-interval design (B.2).
-- ============================================================
DROP VIEW IF EXISTS v_creator_tier_current;
CREATE VIEW v_creator_tier_current AS
SELECT
    ctp.creator_id,
    ctp.tier,
    ctp.valid_from
FROM CreatorTierPeriod ctp
WHERE ctp.valid_to IS NULL;
-- Exactly one open-ended row per creator by construction (E.3's generator
-- always leaves the final period's valid_to NULL); if two open rows ever
-- existed for the same creator that would itself be a data-integrity bug
-- this view has no way to hide, which is the correct failure mode --
-- silently picking one would be worse than a consumer noticing duplicates.


-- ============================================================
-- v_video_daily_engagement — consumer: Growth analysts
-- Per video per day: impressions, views, watch seconds, net likes.
-- Days with impressions but no engagement must appear with zeros.
-- ============================================================
DROP VIEW IF EXISTS v_video_daily_engagement;
CREATE VIEW v_video_daily_engagement AS
SELECT
    imp.video_id,
    imp.d AS day,
    imp.impression_count,
    COALESCE(vw.view_count, 0) AS view_count,
    COALESCE(vw.watch_seconds, 0.0) AS watch_seconds,
    COALESCE(lk.like_count, 0) - COALESCE(rt.retraction_count, 0) AS net_likes
FROM (
    SELECT video_id, date(ts) AS d, COUNT(*) AS impression_count
    FROM Impression
    GROUP BY video_id, date(ts)
) imp
LEFT JOIN (
    SELECT i.video_id, date(i.ts) AS d,
           COUNT(DISTINCT v.view_id) AS view_count,
           SUM(vs.watch_ms) / 1000.0 AS watch_seconds
    FROM Impression i
    JOIN View v ON v.impression_id = i.impression_id
    JOIN ViewSegment vs ON vs.view_id = v.view_id
    GROUP BY i.video_id, date(i.ts)
) vw ON vw.video_id = imp.video_id AND vw.d = imp.d
LEFT JOIN (
    SELECT video_id, date(ts) AS d, COUNT(*) AS like_count
    FROM EngagementSignal
    WHERE signal_type = 'like'
    GROUP BY video_id, date(ts)
) lk ON lk.video_id = imp.video_id AND lk.d = imp.d
LEFT JOIN (
    SELECT es.video_id, date(es.ts) AS d, COUNT(*) AS retraction_count
    FROM LikeRetraction lr
    JOIN EngagementSignal es ON es.signal_id = lr.like_signal_id
    GROUP BY es.video_id, date(es.ts)
) rt ON rt.video_id = imp.video_id AND rt.d = imp.d;
-- Anchored on the impression aggregate (never empty for a day with any
-- traffic), then LEFT JOINed to view/like/retraction aggregates, so a day
-- with impressions but zero views or zero likes surfaces with 0, not by
-- being silently absent from the result — an inner join anywhere in this
-- chain would drop exactly the "quiet days" Growth needs to see.


-- ============================================================
-- v_turn_cost — consumer: Finance
-- Cost per turn, computed against the price in force at the turn's
-- timestamp, never the current price (A12/B.2).
-- ============================================================
DROP VIEW IF EXISTS v_turn_cost;
CREATE VIEW v_turn_cost AS
SELECT
    tu.turn_id,
    at.session_id,
    tu.model_id,
    tu.priced_at,
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
    AND (mpp_cache.valid_to IS NULL OR tu.priced_at < mpp_cache.valid_to);
-- The join condition itself is the "price in force at this timestamp"
-- resolution — there is no current-price column anywhere for a careless
-- query to reach for instead, so a price change can never retroactively
-- alter a past turn's computed cost (the exact guarantee §2.5 demands).

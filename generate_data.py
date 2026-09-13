#!/usr/bin/env python3
"""
ScrollSense — Assignment 1, Deliverable E.3
generate_data.py
"""

import sqlite3
import random
import math
import json
from datetime import datetime, timedelta, timezone

# ---- parameters ----
SEED = 37        
N_USERS = 5_000
N_VIDEOS = 20_000
N_IMPRESSIONS = 300_000
N_AGENT_SESSIONS = 2_000
SCALE = 1               
DB_PATH = "scrollsense.db"

SIM_START = datetime(2025, 9, 1, tzinfo=timezone.utc)
SIM_END   = datetime(2026, 9, 1, tzinfo=timezone.utc)
# -----------------------------------------------------------------

random.seed(SEED)

N_USERS = N_USERS * SCALE
N_VIDEOS = N_VIDEOS * SCALE
N_IMPRESSIONS = N_IMPRESSIONS * SCALE
N_AGENT_SESSIONS = N_AGENT_SESSIONS * SCALE


def iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


_HOUR_WEIGHTS = [3, 2, 1, 1, 1, 1, 2, 4, 6, 7, 7, 8, 9, 8, 7, 7,
                 8, 12, 18, 24, 26, 22, 14, 7]  


def random_ts_with_daily_rhythm(start: datetime, end: datetime) -> datetime:
    """Bias timestamps toward a smooth evening peak (~19:00-21:00), approximating
    the 'activity following a daily rhythm' requirement."""
    span_days = (end - start).days
    day_offset = random.randint(0, max(span_days - 1, 0))
    base_day = start + timedelta(days=day_offset)
    hour = random.choices(range(24), weights=_HOUR_WEIGHTS, k=1)[0]
    minute = random.randint(0, 59)
    second = random.randint(0, 59)
    return base_day.replace(hour=hour, minute=minute, second=second)


def pareto_bounded(alpha: float, lo: int, hi: int, scale: float = 6.0) -> int:
    """Power-law integer in [lo, hi]. random.paretovariate(alpha) returns x >= 1
    with a heavy right tail for alpha close to 1; scale controls how far that
    tail reaches so a handful of users land near `hi` while most stay near `lo`."""
    x = random.paretovariate(alpha) - 1  # >= 0, heavy-tailed
    val = lo + int(x * scale)
    return min(val, hi)


def right_skewed_ms(min_ms: int, max_ms: int, mode_frac: float = 0.25) -> int:
    """Right-skewed duration: most values cluster low, long tail toward max.
    Used for watch_ms so most segments are short glances, few are long watches."""
    u = random.random() ** 2.2  # skew toward 0
    return int(min_ms + u * (max_ms - min_ms) * 1.0 + mode_frac * 0)


def main():
    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA foreign_keys = ON;")
    cur = conn.cursor()

    cur.execute("BEGIN;")

    # ---------------- AppUser ----------------
    print(f"Generating {N_USERS} users...")
    user_rows = []
    account_states = ["active"] * 96 + ["deactivated"] * 3 + ["pending_deletion"] * 1
    for uid in range(1, N_USERS + 1):
        use_phone = random.random() < 0.7
        phone = f"+91{random.randint(6000000000, 9999999999)}" if use_phone else None
        google_id = None if use_phone else f"g_{uid}_{random.randint(10000,99999)}"
        handle = f"user{uid}_{random.randint(100,999)}"
        display_name = f"User {uid}"
        state = random.choice(account_states)
        deletion_requested = None
        if state == "pending_deletion":
            deletion_requested = iso(random_ts_with_daily_rhythm(
                SIM_END - timedelta(days=25), SIM_END))
        created_at = iso(random_ts_with_daily_rhythm(SIM_START, SIM_END))
        user_rows.append((uid, phone, google_id, handle, display_name,
                           state, deletion_requested, created_at))

    cur.executemany(
        """INSERT INTO AppUser (user_id, phone, google_id, handle, display_name,
                                 account_state, deletion_requested_at, created_at)
           VALUES (?,?,?,?,?,?,?,?)""",
        user_rows,
    )

    # ---------------- Interests ----------------
    print("Generating interests...")
    categories = ["comedy", "music", "sports", "gaming", "food", "travel",
                  "fashion", "tech", "pets", "fitness", "dance", "news"]

    declared_rows, inferred_rows, suppression_rows = [], [], []
    for uid in range(1, N_USERS + 1):
        n_declared = random.randint(1, 4)
        for cat in random.sample(categories, n_declared):
            declared_rows.append((uid, cat, iso(random_ts_with_daily_rhythm(SIM_START, SIM_END))))

        n_inferred = random.randint(0, 5)
        inferred_cats = random.sample(categories, n_inferred) if n_inferred else []
        for cat in inferred_cats:
            refreshed_at = iso(random_ts_with_daily_rhythm(SIM_START, SIM_END))
            confidence = round(random.betavariate(2, 3), 3)
            inferred_rows.append((uid, cat, refreshed_at, confidence))
            if random.random() < 0.1:
                suppression_rows.append((uid, cat, refreshed_at))

    cur.executemany(
        "INSERT INTO UserInterestDeclared (user_id, category, declared_at) VALUES (?,?,?)",
        declared_rows,
    )
    cur.executemany(
        """INSERT INTO UserInterestInferred (user_id, category, refreshed_at, confidence)
           VALUES (?,?,?,?)""",
        inferred_rows,
    )
    cur.executemany(
        "INSERT INTO InterestSuppression (user_id, category, suppressed_at) VALUES (?,?,?)",
        suppression_rows,
    )

    # ---------------- Creators & tiers ----------------
    print("Generating creator tiers...")
    n_creators = int(N_USERS * 0.15)
    creator_ids = random.sample(range(1, N_USERS + 1), n_creators)
    tiers = ["bronze", "silver", "gold", "platinum"]

    tier_rows = []
    for cid in creator_ids:
        n_periods = random.randint(1, 3)
        cursor_time = SIM_START
        for i in range(n_periods):
            valid_from = iso(cursor_time)
            tier = random.choice(tiers)
            is_last = i == n_periods - 1
            if is_last:
                valid_to = None
            else:
                cursor_time = cursor_time + timedelta(days=random.randint(30, 120))
                valid_to = iso(cursor_time)
            tier_rows.append((cid, tier, valid_from, valid_to))

    cur.executemany(
        "INSERT INTO CreatorTierPeriod (creator_id, tier, valid_from, valid_to) VALUES (?,?,?,?)",
        tier_rows,
    )

    # ---------------- Social graph (power-law FOLLOWER counts) ----------------
    print("Generating social graph...")
    follow_rows, block_rows, mute_rows = [], [], []

    # Follower count is IN-degree, not out-degree: uniform target sampling
    # produces a flat in-degree distribution regardless of how out-degree is
    # drawn, so popularity must be assigned per-user and used as a sampling
    # weight when others choose who to follow. A Zipf-shaped weight gives a
    # few mega-accounts and a long tail of near-zero-follower users.
    popularity_weight = [0.0] * (N_USERS + 1)  # index 0 unused
    for uid in range(1, N_USERS + 1):
        popularity_weight[uid] = 1.0 / (uid ** 1.1)  # Zipf-like: rank-based skew
    random.shuffle(popularity_weight[1:])  # so popularity isn't correlated with uid order
    popularity_weight = [0.0] + popularity_weight[1:]

    all_user_ids = list(range(1, N_USERS + 1))
    global_weights = popularity_weight[1:]  # aligned with all_user_ids
    cum_weights = []
    running = 0.0
    for w in global_weights:
        running += w
        cum_weights.append(running)

    for uid in range(1, N_USERS + 1):
        # out-degree: how many accounts THIS user chooses to follow; kept
        # modest and roughly uniform, since the brief's power-law claim is
        # about follower counts specifically, not who follows how many others
        n_following = random.choices([0, 1, 3, 8, 20], weights=[10, 30, 35, 20, 5])[0]
        if n_following == 0:
            continue
        targets = set()
        attempts = 0
        while len(targets) < min(n_following, N_USERS - 1) and attempts < n_following * 6:
            t = random.choices(all_user_ids, cum_weights=cum_weights, k=1)[0]
            if t != uid:
                targets.add(t)
            attempts += 1
        for t in targets:
            started = random_ts_with_daily_rhythm(SIM_START, SIM_END)
            ended = None
            if random.random() < 0.05:
                ended_dt = started + timedelta(days=random.randint(1, 200))
                if ended_dt < SIM_END:
                    ended = iso(ended_dt)
            follow_rows.append((uid, t, iso(started), ended))

    for _ in range(int(N_USERS * 0.02)):
        a, b = random.sample(range(1, N_USERS + 1), 2)
        block_rows.append((a, b, iso(random_ts_with_daily_rhythm(SIM_START, SIM_END))))

    for _ in range(int(N_USERS * 0.05)):
        a, b = random.sample(range(1, N_USERS + 1), 2)
        mute_rows.append((a, b, iso(random_ts_with_daily_rhythm(SIM_START, SIM_END))))

    cur.executemany(
        "INSERT OR IGNORE INTO Follow (follower_id, followee_id, started_at, ended_at) VALUES (?,?,?,?)",
        follow_rows,
    )
    cur.executemany(
        "INSERT OR IGNORE INTO Block (blocker_id, blocked_id, started_at) VALUES (?,?,?)",
        block_rows,
    )
    cur.executemany(
        "INSERT OR IGNORE INTO Mute (muter_id, muted_id, started_at) VALUES (?,?,?)",
        mute_rows,
    )

    # ---------------- Audio tracks ----------------
    print("Generating audio tracks...")
    n_tracks = int(N_VIDEOS * 0.3)
    track_rows = []
    for tid in range(1, n_tracks + 1):
        source = "original" if random.random() < 0.4 else "licensed"
        license_ref = f"LIC-{random.randint(10000,99999)}" if source == "licensed" else None
        track_rows.append((tid, source, license_ref))

    cur.executemany(
        "INSERT INTO AudioTrack (track_id, source, license_ref) VALUES (?,?,?)",
        track_rows,
    )

    # ---------------- Videos ----------------
    print(f"Generating {N_VIDEOS} videos...")
    video_rows = []
    for vid in range(1, N_VIDEOS + 1):
        owner_id = random.choice(creator_ids) if creator_ids else random.randint(1, N_USERS)
        duration_ms = random.randint(20000, 90000)
        n_tags = random.randint(0, 3)
        tags = " ".join(f"#{random.choice(categories)}" for _ in range(n_tags))
        caption = f"check this out {tags}".strip()
        audio_track_id = random.randint(1, n_tracks) if (n_tracks and random.random() < 0.6) else None
        uploaded_at = iso(random_ts_with_daily_rhythm(SIM_START, SIM_END))
        video_rows.append((vid, owner_id, duration_ms, caption, audio_track_id, uploaded_at))

    cur.executemany(
        """INSERT INTO Video (video_id, owner_id, duration_ms, caption, audio_track_id, uploaded_at)
           VALUES (?,?,?,?,?,?)""",
        video_rows,
    )

    # ---------------- Moderation decisions ----------------
    print("Generating moderation decisions...")
    states = ["pending", "live", "age_restricted", "demoted", "taken_down"]
    mod_rows = []
    for vid in range(1, N_VIDEOS + 1):
        uploaded_dt = datetime.strptime(video_rows[vid - 1][5], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        n_decisions = random.choices([1, 2, 3, 4], weights=[70, 20, 7, 3])[0]
        cursor_time = uploaded_dt
        current_state = "pending"
        for _ in range(n_decisions):
            cursor_time += timedelta(minutes=random.randint(1, 500))
            if cursor_time > SIM_END:
                break
            by_type = "automated" if random.random() < 0.8 else "human"
            by_id = random.randint(1, 50) if by_type == "human" else None
            # transition toward 'live' most of the time
            current_state = random.choices(states, weights=[5, 70, 10, 10, 5])[0]
            mod_rows.append((vid, iso(cursor_time), current_state, by_type, by_id))

    cur.executemany(
        """INSERT INTO ModerationDecision (video_id, decided_at, state, decided_by_type, decided_by_id)
           VALUES (?,?,?,?,?)""",
        mod_rows,
    )

    # ---------------- Impressions / Views / ViewSegments (the funnel) ----------------
    print(f"Generating {N_IMPRESSIONS} impressions (funnel)...")
    model_versions = ["ranker_v11", "ranker_v12", "ranker_v13", "ranker_v14"]

    impression_rows = []
    view_rows = []
    segment_rows = []
    view_id_counter = 1
    impression_id_counter = 1

    for _ in range(N_IMPRESSIONS):
        uid = random.randint(1, N_USERS)
        vid = random.randint(1, N_VIDEOS)
        ts = random_ts_with_daily_rhythm(SIM_START, SIM_END)
        feed_position = random.randint(1, 50)
        model_version = random.choice(model_versions)
        iid = impression_id_counter
        impression_id_counter += 1
        impression_rows.append((iid, uid, vid, iso(ts), feed_position, model_version))

        # funnel: most impressions never become views (§2.4/§2.6)
        if random.random() < 0.22:
            vid_row_id = view_id_counter
            view_id_counter += 1
            view_rows.append((vid_row_id, iid, iso(ts + timedelta(milliseconds=random.randint(300, 1000)))))

            n_segments = random.choices([1, 2, 3], weights=[80, 15, 5])[0]
            for seg_seq in range(1, n_segments + 1):
                duration_ms = 90000  # upper bound context; watch_ms can exceed clip duration on loop
                watch_ms = right_skewed_ms(300, 95000)
                completed = 1 if random.random() < 0.18 else 0
                segment_rows.append((vid_row_id, seg_seq, watch_ms, completed))

    cur.executemany(
        """INSERT INTO Impression (impression_id, user_id, video_id, ts, feed_position, model_version)
           VALUES (?,?,?,?,?,?)""",
        impression_rows,
    )
    cur.executemany(
        "INSERT INTO View (view_id, impression_id, started_at) VALUES (?,?,?)",
        view_rows,
    )
    cur.executemany(
        """INSERT INTO ViewSegment (view_id, segment_seq, watch_ms, completed)
           VALUES (?,?,?,?)""",
        segment_rows,
    )

    # ---------------- Engagement signals (sparse: most views produce none) ----------------
    print("Generating engagement signals...")
    signal_types_weighted = (
        ["like"] * 50 + ["save"] * 10 + ["share"] * 8 + ["comment"] * 7 +
        ["follow_from_feed"] * 5 + ["not_interested"] * 15 + ["report"] * 5
    )
    share_destinations = ["whatsapp", "instagram", "copied_link"]

    signal_rows = []
    signal_id_counter = 1
    like_signal_ids_by_pair = {}

    for (vid_row_id, iid, started_at) in view_rows:
        if random.random() < 0.12:  # most views produce no explicit signal
            uid, vid, ts, *_ = next(
                r for r in impression_rows if r[0] == iid
            )[1], None, None
            # re-fetch cleanly
            imp = impression_rows[iid - 1]
            uid, vid_target, ts = imp[1], imp[2], imp[3]
            signal_type = random.choice(signal_types_weighted)
            share_dest = random.choice(share_destinations) if signal_type == "share" else None
            comment_text = "nice clip!" if signal_type == "comment" else None
            sid = signal_id_counter
            signal_id_counter += 1
            signal_rows.append((sid, uid, vid_target, signal_type, ts, share_dest, comment_text))
            if signal_type == "like":
                like_signal_ids_by_pair[sid] = ts

    cur.executemany(
        """INSERT INTO EngagementSignal
           (signal_id, user_id, video_id, signal_type, ts, share_destination, comment_text)
           VALUES (?,?,?,?,?,?,?)""",
        signal_rows,
    )

    # ---------------- Like retractions (sparse subset of likes) ----------------
    print("Generating like retractions...")
    retraction_rows = []
    retraction_id = 1
    for sid, ts_str in like_signal_ids_by_pair.items():
        if random.random() < 0.06:
            ts_dt = datetime.strptime(ts_str, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
            retracted_at = iso(ts_dt + timedelta(seconds=random.randint(2, 120)))
            retraction_rows.append((retraction_id, sid, retracted_at))
            retraction_id += 1

    cur.executemany(
        "INSERT INTO LikeRetraction (retraction_id, like_signal_id, retracted_at) VALUES (?,?,?)",
        retraction_rows,
    )

    # ---------------- Agent layer ----------------
    print(f"Generating {N_AGENT_SESSIONS} agent sessions...")

    # Prompt template versions (edited several times a week -> many versions)
    template_rows = []
    for template_id in range(1, 6):
        cursor_time = SIM_START
        version = 1
        while cursor_time < SIM_END:
            valid_from = iso(cursor_time)
            next_time = cursor_time + timedelta(days=random.randint(2, 6))
            valid_to = iso(next_time) if next_time < SIM_END else None
            text = f"Template {template_id} v{version}: explain why this clip was shown..."
            template_rows.append((template_id, version, valid_from, valid_to, text))
            cursor_time = next_time
            version += 1

    cur.executemany(
        """INSERT INTO PromptTemplateVersion (template_id, version, valid_from, valid_to, text)
           VALUES (?,?,?,?,?)""",
        template_rows,
    )

    # Model pricing periods
    model_ids = ["gpt-4o-mini", "llama-3.1-70b", "internal-ft-v2"]
    rate_types = ["input", "output", "cached_input"]
    pricing_rows = []
    for model_id in model_ids:
        for rate_type in rate_types:
            cursor_time = SIM_START
            base_rate = {"input": 0.15, "output": 0.6, "cached_input": 0.075}[rate_type]
            while cursor_time < SIM_END:
                valid_from = iso(cursor_time)
                next_time = cursor_time + timedelta(days=random.randint(20, 90))
                valid_to = iso(next_time) if next_time < SIM_END else None
                rate = round(base_rate * random.uniform(0.8, 1.3), 4)
                pricing_rows.append((model_id, rate_type, valid_from, valid_to, rate))
                cursor_time = next_time

    cur.executemany(
        """INSERT INTO ModelPricingPeriod (model_id, rate_type, valid_from, valid_to, rate)
           VALUES (?,?,?,?,?)""",
        pricing_rows,
    )

    # Sessions, turns, tool calls, usage, recommendations, judge scores, ratings
    session_rows = []
    turn_rows = []
    tool_call_rows = []
    usage_rows = []
    recommendation_rows = []
    judge_rows = []
    rating_rows = []

    turn_id_counter = 1
    tool_call_id_counter = 1

    for sid in range(1, N_AGENT_SESSIONS + 1):
        uid = random.randint(1, N_USERS)
        started_at = random_ts_with_daily_rhythm(SIM_START, SIM_END)
        session_rows.append((sid, uid, iso(started_at)))

        n_turns = random.randint(1, 6)
        cursor_time = started_at
        for seq in range(1, n_turns + 1):
            cursor_time += timedelta(seconds=random.randint(5, 90))
            tid = turn_id_counter
            turn_id_counter += 1

            template_id = random.randint(1, 5)
            candidate_versions = [r for r in template_rows if r[0] == template_id
                                   and r[2] <= iso(cursor_time)]
            template_version = candidate_versions[-1][1] if candidate_versions else 1

            model_id = random.choice(model_ids)
            temperature = round(random.uniform(0.2, 1.0), 2)

            turn_rows.append((tid, sid, seq, "find me that clip about...",
                               "Here's why this clip was shown...",
                               template_id, template_version, model_id, temperature,
                               iso(cursor_time)))

            # tool calls (0..N, occasionally nested)
            n_calls = random.choices([0, 1, 2, 3], weights=[30, 40, 20, 10])[0]
            parent_id_for_turn = None
            for _ in range(n_calls):
                cid = tool_call_id_counter
                tool_call_id_counter += 1
                parent = parent_id_for_turn if (parent_id_for_turn and random.random() < 0.2) else None
                name = random.choice(["search_videos", "get_user_history", "fetch_trending_audio"])
                args = json.dumps({"query": "cat that thinks it's a dog"}) if name == "search_videos" \
                    else json.dumps({"days": 7}) if name == "get_user_history" \
                    else json.dumps({"region": "IN"})
                latency_ms = random.randint(50, 800)
                errored = 1 if random.random() < 0.03 else 0
                tool_call_rows.append((cid, tid, parent, name, args,
                                        "ok" if not errored else None, latency_ms, errored))
                parent_id_for_turn = cid

            input_tokens = random.randint(200, 2000)
            output_tokens = random.randint(50, 800)
            cached_tokens = random.randint(0, input_tokens // 2)
            usage_rows.append((tid, model_id, iso(cursor_time), input_tokens,
                                output_tokens, cached_tokens))

            # recommendations (shelf of clips)
            if random.random() < 0.6:
                n_recs = random.randint(1, 5)
                shown_videos = random.sample(range(1, N_VIDEOS + 1), n_recs)
                for pos, rvid in enumerate(shown_videos, start=1):
                    impression_id = None
                    if random.random() < 0.4 and impression_rows:
                        impression_id = random.randint(1, len(impression_rows))
                    recommendation_rows.append((tid, pos, rvid, impression_id))

            # judge score (rare)
            if random.random() < 0.08:
                judge_rows.append((tid, iso(cursor_time + timedelta(minutes=5)),
                                    random.randint(1, 5), random.randint(1, 5), random.randint(1, 5)))

            # user rating (very rare)
            if random.random() < 0.04:
                rating_rows.append((tid, iso(cursor_time + timedelta(seconds=30)),
                                     1 if random.random() < 0.7 else 0))

    cur.executemany("INSERT INTO AgentSession (session_id, user_id, started_at) VALUES (?,?,?)",
                     session_rows)
    cur.executemany(
        """INSERT INTO AgentTurn (turn_id, session_id, seq, user_message, assistant_message,
                                   template_id, template_version, model_id, temperature, created_at)
           VALUES (?,?,?,?,?,?,?,?,?,?)""",
        turn_rows,
    )
    cur.executemany(
        """INSERT INTO ToolCall (tool_call_id, turn_id, parent_tool_call_id, name,
                                  arguments_json, result, latency_ms, errored)
           VALUES (?,?,?,?,?,?,?,?)""",
        tool_call_rows,
    )
    cur.executemany(
        """INSERT INTO TurnUsage (turn_id, model_id, priced_at, input_tokens, output_tokens, cached_tokens)
           VALUES (?,?,?,?,?,?)""",
        usage_rows,
    )
    cur.executemany(
        "INSERT OR IGNORE INTO Recommendation (turn_id, position, video_id, impression_id) VALUES (?,?,?,?)",
        recommendation_rows,
    )
    cur.executemany(
        "INSERT INTO JudgeScore (turn_id, judged_at, helpfulness, groundedness, safety) VALUES (?,?,?,?,?)",
        judge_rows,
    )
    cur.executemany(
        "INSERT INTO UserRating (turn_id, rated_at, thumbs_up) VALUES (?,?,?)",
        rating_rows,
    )

    conn.commit()

    # ---------------- integrity check ----------------
    print("Running foreign_key_check...")
    problems = cur.execute("PRAGMA foreign_key_check;").fetchall()
    if problems:
        print(f"FOREIGN KEY VIOLATIONS FOUND: {len(problems)}")
        for p in problems[:20]:
            print(p)
    else:
        print("PRAGMA foreign_key_check: clean, no violations.")

    print("\nRow counts:")
    for table in ["AppUser", "Video", "Impression", "View", "ViewSegment",
                  "EngagementSignal", "LikeRetraction", "AgentSession",
                  "AgentTurn", "ToolCall", "Recommendation"]:
        n = cur.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        print(f"  {table}: {n}")

    conn.close()


if __name__ == "__main__":
    main()
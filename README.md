# ScrollSense — Assignment 1

Data modelling and relational foundations for a short-video app with an
LLM-powered recommendation agent. SQLite 3.44+.

## Files

| File | Purpose |
|---|---|
| `schema.sql` | DDL — all 25 tables, constraints, indexes (Deliverable E.1) |
| `generate_data.py` | Parameterised, seeded synthetic data generator (Deliverable E.3) |
| `views.sql` | Five consumer-facing views (Deliverable G.1) |
| `transactions.sql` | Three transaction scripts demonstrating atomicity, WAL isolation, and `SQLITE_BUSY` (Deliverable G.3) |
| `queries.sql` | Thirteen analytical queries (Deliverable F) |
| `bonus.sql` | Two trigger-based integrity checks (Bonus §1 and §2) |
| `DA24B037.pdf` | All written deliverables (A through G, plus Bonus, plus the LLM-usage appendix) |

`scrollsense.db` (plus its `-shm`/`-wal` WAL sidecar files) is a **generated artifact**, not source, and is intentionally excluded from anything graded — see "How to run" below to build it from scratch. If a copy exists locally in this repo, it was left over from development and can be deleted; it regenerates deterministically from `schema.sql` + `generate_data.py` given the same `SEED`.

## How to run, in order, from an empty database

**1. Check your SQLite version** (3.44+ required for `group_concat(... ORDER BY ...)` used in F8):
```bash
sqlite3 --version
```

**2. Build the schema:**
```bash
sqlite3 scrollsense.db < schema.sql
```
This sets `PRAGMA foreign_keys = ON` and `PRAGMA journal_mode = WAL` as its first two statements, creates all 25 tables, and adds supporting indexes. Running this against a database file that already has these tables will fail with "table already exists" errors — delete `scrollsense.db` first if re-running from scratch:
```bash
rm -f scrollsense.db
sqlite3 scrollsense.db < schema.sql
```

**3. Generate synthetic data:**
```bash
python3 generate_data.py
```
Before running, open `generate_data.py` and set `SEED` (near the top) to your own roll number. Default volumes: 5,000 users, 20,000 videos, 300,000 impressions, 2,000 agent sessions — matching the task sheet exactly. The whole load runs inside a single transaction and takes roughly 30 seconds on a typical machine. At the end it runs `PRAGMA foreign_key_check` automatically and reports any violations (there should be none).

**4. Apply the views:**
```bash
sqlite3 scrollsense.db < views.sql
```

**5. (Optional) Apply the bonus triggers:**
```bash
sqlite3 scrollsense.db < bonus.sql
```

**6. Run the queries:**
```bash
sqlite3 scrollsense.db < queries.sql
```
Two of the thirteen queries (F6, F11) reference specific IDs (`owner_id`, `session_id`) that were chosen because they have rich, demonstrative data in the generator's own reference run — with a different seed, these specific IDs may not be the most illustrative examples in your generated data. If so, re-run the two finder queries documented in the F6/F11 sections of the PDF to pick better IDs for your own seed, and update the corresponding `WHERE` clauses in `queries.sql`.

**7. Run the transaction demonstrations:**
```bash
sqlite3 scrollsense.db < transactions.sql
```
T1 (retraction atomicity) runs standalone. **T2 and T3 require two separate terminal sessions** connected to the same database file at the same time — see the commented step-by-step instructions inside `transactions.sql` for the exact sequence. These cannot be demonstrated by running the file straight through in one session.

## Regenerating from scratch

```bash
rm -f scrollsense.db
sqlite3 scrollsense.db < schema.sql
python3 generate_data.py
sqlite3 scrollsense.db < views.sql
sqlite3 scrollsense.db < bonus.sql   # optional
```

## Notes

- All timestamps are ISO-8601 UTC text (`'2026-03-03T14:32:07Z'`), consistently, across every table.
- `PRAGMA foreign_keys = ON` is per-connection, not per-database — every script above sets it explicitly at the top; any additional ad-hoc `sqlite3` session should do the same before writing.
- Tables are not declared `STRICT` — see the PDF (E.1) for the type-affinity experiment explaining why, and what enforces correctness instead (`CHECK` constraints throughout).

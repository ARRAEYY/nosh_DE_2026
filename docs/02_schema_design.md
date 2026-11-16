# Phase 2 — Schema Design

**Status: `sql/01_schema.sql` runs top-to-bottom on an empty database, `sql/02_load_data.sql` loads all 10 CSV files without a single error, and all 30 workload queries (R01–R25, W01–W05 inside `BEGIN … ROLLBACK`) execute successfully against the loaded schema.**

## 1. How we worked

Nobody gave us the `CREATE TABLE` statements — working them out was the task. We:

1. **Profiled every CSV** (headers, row counts, empty-value patterns, distinct values, min/max) before writing a single line of DDL.
2. **Hunted for candidate keys** — checking `user_id`/`email`, `handle`, `(user_id, channel_id)`, `(user_id, video_id)`, `(playlist_id, position)` and `(playlist_id, video_id)` for uniqueness across the full files.
3. **Cross-checked referential integrity** — every `user_id`/`channel_id`/`video_id`/`watch_id`/`parent_comment_id` in the child files exists in the parent files.
4. **Tested business rules against all rows** — only constraints that accept 100% of the seed data made it into the schema (see §9 for the one rule we found broken in the data itself).
5. **Loaded the data for real** and re-ran everything after each schema change, including a smoke run of all 30 workload queries.

All timestamps in the export carry `+05:30` offsets, so every temporal column is `TIMESTAMPTZ`. All money is `NUMERIC`, never float. Yes/no columns are `BOOLEAN`, country codes are `CHAR(2)`, birth year is `SMALLINT`.

## 2. Rules compliance

- Every table lives in the schema **`youtube`** (`CREATE SCHEMA youtube; SET search_path TO youtube;`).
- Phase 2 creates **only constraints**: PK, FK, UNIQUE, NOT NULL, CHECK — no tuning indexes (those belong to Phase 4). PostgreSQL's automatic PK/UNIQUE indexes are listed in §10.
- The schema contains **27 CHECK constraints** (12 required), plus 10 primary keys, 11 foreign keys and 2 natural UNIQUE keys.
- `01_schema.sql` is re-runnable: it opens with `DROP SCHEMA IF EXISTS youtube CASCADE`.

## 3. Data dictionary

### 3.1 `users` — 30,000 rows

| Column | Type | Constraints | Why |
|---|---|---|---|
| user_id | INTEGER | PK | Surrogate id from the export; plain `INTEGER` (fits 30,000 now and 600,000 at 20x). |
| email | VARCHAR(255) | NOT NULL, UNIQUE | Login identity; verified unique across all 30,000 rows. |
| display_name | VARCHAR(100) | NOT NULL | Always present in the export; not unique (500 distinct names). |
| country_code | CHAR(2) | NOT NULL, CHECK `~ '^[A-Z]{2}$'` | ISO 3166-1 alpha-2 (values: AE, GB, IN, SG, US). |
| birth_year | SMALLINT | NULL allowed, CHECK 1900–2013 | Empty in 4,433 rows — age is optional. Range check: nobody born before 1900; 2013 = "at least ~13 in 2026" (COPPA-style rule). Actual data: 1960–2009. |
| premium_until | DATE | NULL allowed, CHECK ≥ signup date | Empty in 27,602 rows — no active Premium. R25 compares it to `shown_at::date`, so DATE is the right type. |
| created_at | TIMESTAMPTZ | NOT NULL | Account creation, always present, `+05:30` offsets. |

### 3.2 `channels` — 3,000 rows

| Column | Type | Constraints | Why |
|---|---|---|---|
| channel_id | INTEGER | PK | Surrogate id. |
| owner_user_id | INTEGER | NOT NULL, FK → users, ON DELETE CASCADE | A channel cannot outlive its owner. |
| handle | VARCHAR(30) | NOT NULL, UNIQUE, CHECK `~ '^@[A-Za-z0-9._-]+$'` | Natural key (e.g. `@vivaanvlogs1`); verified unique. |
| channel_name | VARCHAR(100) | NOT NULL | Display name (200 distinct names — not unique). |
| country_code | CHAR(2) | NOT NULL, CHECK `~ '^[A-Z]{2}$'` | Same format rule as users (values: GB, IN, US). |
| is_verified | BOOLEAN | NOT NULL | Export uses `t`/`f`; `BOOLEAN` is the honest type. |
| monetization_status | VARCHAR(15) | NOT NULL, CHECK IN (NOT_ELIGIBLE, ELIGIBLE, SUSPENDED) | The three values present in the data. |
| subscriber_count | INTEGER | NOT NULL, CHECK ≥ 0 | Derived counter (see §7). |
| created_at | TIMESTAMPTZ | NOT NULL | Channel creation. |

> **Not constrained:** `owner_user_id` is *not* UNIQUE. In this export each user owns at most one channel (3,000 channels, 3,000 distinct owners — currently 1:1), but YouTube allows one account to run several channels, so we constrain only "each channel has exactly one owner".

### 3.3 `videos` — 30,000 rows

| Column | Type | Constraints | Why |
|---|---|---|---|
| video_id | CHAR(11) | PK, CHECK `~ '^[A-Za-z0-9_-]{11}$'` | The 11-character YouTube id alphabet; verified on all rows (e.g. `ZkNSlUB1EOs`, `__21WjTDc9K`). |
| channel_id | INTEGER | NOT NULL, FK → channels, ON DELETE CASCADE | Videos belong to their channel. |
| title | VARCHAR(100) | NOT NULL | YouTube caps titles at 100 chars; longest in data is 37. |
| description | VARCHAR(5000) | NULL allowed | Empty for 9,083 videos — description is optional. |
| category | VARCHAR(20) | NOT NULL, CHECK IN (10 values) | Comedy, Cooking, Education, Film, Gaming, Music, News, Sports, Tech, Vlogs. |
| duration_sec | INTEGER | NOT NULL, CHECK > 0 | Also protects R09's division by duration. Range: 10–3,718 s. |
| is_short | BOOLEAN | NOT NULL | See §7 — derivable from duration but kept as an explicit flag. |
| is_made_for_kids | BOOLEAN | NOT NULL DEFAULT FALSE | Designated at upload; the DEFAULT keeps workload insert W01 (which omits it) legal. |
| visibility | VARCHAR(10) | NOT NULL, CHECK IN (PUBLIC, UNLISTED, PRIVATE, SCHEDULED) | Counts: 26,335 / 2,079 / 1,526 / 60. |
| uploaded_at | TIMESTAMPTZ | NOT NULL | When the file was uploaded. |
| published_at | TIMESTAMPTZ | NULL allowed + 2 CHECKs (below) | NULL **exactly** for the 1,526 PRIVATE videos; every UNLISTED/PUBLIC/SCHEDULED video has one. SCHEDULED rows store the future go-live time (2–21 Jul 2026). |
| view_count | BIGINT | NOT NULL DEFAULT 0, CHECK ≥ 0 | Derived counter (§7); BIGINT because view counters grow without bound. DEFAULT keeps W01 legal. |

Two column-pair rules: `videos_private_never_published` (PRIVATE ⇒ `published_at IS NULL`) and `videos_scheduled_needs_publish_time` (SCHEDULED ⇒ `published_at IS NOT NULL`), plus `videos_published_not_before_upload` (`published_at ≥ uploaded_at` — 0 violations in 30,000 rows).

### 3.4 `subscriptions` — 129,253 rows

| Column | Type | Constraints | Why |
|---|---|---|---|
| user_id | INTEGER | PK (part 1), FK → users, CASCADE | Composite PK: one subscription per (user, channel) — verified, no duplicates. |
| channel_id | INTEGER | PK (part 2), FK → channels, CASCADE | — |
| notifications | VARCHAR(12) | NOT NULL, CHECK IN (NONE, PERSONALIZED, ALL) | The three values in the data. |
| subscribed_at | TIMESTAMPTZ | NOT NULL | Subscription timestamp. |

### 3.5 `watch_events` — 200,000 rows (the fact table)

| Column | Type | Constraints | Why |
|---|---|---|---|
| watch_id | INTEGER | PK | **Plain INTEGER, not GENERATED** — workload W02 inserts explicit ids (90000001). |
| user_id | INTEGER | NULL allowed, FK → users, ON DELETE CASCADE | NULL in 49,964 rows (25.0%) = **logged-out views**. CASCADE, not SET NULL: pseudonymising a deleted user's views as logged-out would corrupt R12's logged-out metric. |
| video_id | CHAR(11) | NOT NULL, FK → videos, CASCADE | The video watched. |
| started_at | TIMESTAMPTZ | NOT NULL | 2025-01-01 → 2026-06-30. |
| watch_seconds | INTEGER | NOT NULL, CHECK 0–86400 | 0 = clicked away instantly (458 rows); "never longer than a day". Max in data: 3,718. |
| device | VARCHAR(10) | NOT NULL, CHECK IN (WEB, ANDROID, IOS, TV) | The four devices in the data. |
| traffic_source | VARCHAR(15) | NOT NULL, CHECK IN (6 values) | HOME, SEARCH, SUGGESTED, SHORTS_FEED, SUBSCRIPTION, EXTERNAL. |

### 3.6 `video_reactions` — 67,417 rows

| Column | Type | Constraints | Why |
|---|---|---|---|
| user_id | INTEGER | PK (part 1), FK → users, CASCADE | Composite PK: at most one reaction per user per video — verified. |
| video_id | CHAR(11) | PK (part 2), FK → videos, CASCADE | — |
| reaction | VARCHAR(7) | NOT NULL, CHECK IN (LIKE, DISLIKE) | — |
| reacted_at | TIMESTAMPTZ | NOT NULL | Reaction timestamp. |

### 3.7 `comments` — 60,000 rows

| Column | Type | Constraints | Why |
|---|---|---|---|
| comment_id | INTEGER | PK | Surrogate id. |
| video_id | CHAR(11) | NOT NULL, FK → videos, CASCADE | The video commented on. |
| user_id | INTEGER | NOT NULL, FK → users, CASCADE | Comment author. |
| parent_comment_id | INTEGER | NULL allowed, FK → comments (self), CASCADE | NULL in 52,610 rows = top-level comments; 7,390 replies. Deleting a comment cascades to its replies ("delete thread"). Verified: every reply references a parent with a **smaller** comment_id, so the file is parent-before-child and the FK can be immediate. |
| body | VARCHAR(10000) | NOT NULL | YouTube's comment length cap. |
| like_count | INTEGER | NOT NULL, CHECK ≥ 0 | 0–1,999 in the data. |
| is_pinned | BOOLEAN | NOT NULL | Pinned status. |
| created_at | TIMESTAMPTZ | NOT NULL | Comment time. |

Extra rule: `comments_replies_cannot_be_pinned` (`parent_comment_id IS NULL OR NOT is_pinned`) — 0 violations in the data.

### 3.8 `playlists` — 8,000 rows

| Column | Type | Constraints | Why |
|---|---|---|---|
| playlist_id | INTEGER | PK | Surrogate id. |
| owner_user_id | INTEGER | NOT NULL, FK → users, CASCADE | Playlist owner. |
| title | VARCHAR(150) | NOT NULL | YouTube's playlist title cap. |
| visibility | VARCHAR(10) | NOT NULL, CHECK IN (PRIVATE, UNLISTED, PUBLIC) | The three values in the data. |
| created_at | TIMESTAMPTZ | NOT NULL | Playlist creation. |

### 3.9 `playlist_items` — 56,005 rows

| Column | Type | Constraints | Why |
|---|---|---|---|
| playlist_id | INTEGER | PK (part 1), FK → playlists, CASCADE | Composite PK with position: a position is used once per playlist (verified; positions run 1–12, contiguous from 1 in every playlist). |
| position | SMALLINT | PK (part 2), CHECK ≥ 1 | SMALLINT is plenty for a per-playlist index. |
| video_id | CHAR(11) | NOT NULL, FK → videos, CASCADE | The video at this position. |
| added_at | TIMESTAMPTZ | NOT NULL | When it was added (never before the playlist's `created_at` — verified). |

> `(playlist_id, video_id)` is deliberately **not** unique: YouTube legitimately allows the same video twice in a playlist. The seed data happens to contain no duplicates (integrity check IC3), but that is a property of the export, not a business rule.

### 3.10 `ad_impressions` — 57,014 rows

| Column | Type | Constraints | Why |
|---|---|---|---|
| impression_id | INTEGER | PK | Surrogate id. |
| watch_id | INTEGER | NOT NULL, FK → watch_events, **ON DELETE RESTRICT** | An impression is a financial record; see §4. |
| ad_format | VARCHAR(10) | NOT NULL, CHECK IN (PREROLL, MIDROLL) | The two formats in the data. |
| revenue_inr | NUMERIC(10,4) | NOT NULL, CHECK ≥ 0 | Money — exact decimal, 4 dp as exported (₹0.1750–₹0.8250). |
| shown_at | TIMESTAMPTZ | NOT NULL | When the ad ran — always inside the watch event's window (IC4). |

## 4. Relationships, cardinalities and the delete policy

| Relationship | Cardinality | ON DELETE | Reasoning |
|---|---|---|---|
| users → channels (`owner_user_id`) | 1:N (currently 1:1 in data) | CASCADE | A channel cannot exist without its owner. |
| channels → videos | 1:N (one channel in the export has no videos) | CASCADE | Videos die with their channel. |
| users ↔ channels via `subscriptions` | M:N | CASCADE both | Engagement record; meaningless without either side. |
| users → `watch_events.user_id` | 0:N, optional on the event side | CASCADE (**not** SET NULL) | SET NULL would silently turn a deleted user's views into "logged out" and corrupt R12; the history is deleted instead. |
| videos → watch_events | 1:N | CASCADE | Watch events of a deleted video are meaningless. |
| watch_events → ad_impressions | 1:N | **RESTRICT** | Financial records must never be silently destroyed; an account/video that earned ad revenue cannot be hard-deleted until its impressions are explicitly archived. |
| users/videos → `video_reactions` | M:N | CASCADE both | Engagement record. |
| users/videos → `comments`; comments → comments (replies) | M:N / self 1:N | CASCADE | Deleting a comment deletes its thread, matching YouTube. |
| users → playlists → playlist_items; videos → playlist_items | 1:N chains | CASCADE | A playlist dies with its owner; its items die with the playlist or the video. |

## 5. ER diagram

Image: [`diagrams/er_diagram.png`](../diagrams/er_diagram.png) (crow's-foot notation; PK/FK/UK marked per attribute).

```mermaid
erDiagram
    users {
        integer user_id PK
        varchar email UK
        varchar display_name
        char country_code
        smallint birth_year "NULL: not provided"
        date premium_until "NULL: no active Premium"
        timestamptz created_at
    }
    channels {
        integer channel_id PK
        integer owner_user_id FK
        varchar handle UK
        varchar channel_name
        char country_code
        boolean is_verified
        varchar monetization_status
        integer subscriber_count "derived: recomputed by W04"
        timestamptz created_at
    }
    videos {
        char video_id PK "11-char [A-Za-z0-9_-]"
        integer channel_id FK
        varchar title
        varchar description "NULL: none (9,083 rows)"
        varchar category
        integer duration_sec
        boolean is_short "Short if <= 60 s"
        boolean is_made_for_kids
        varchar visibility
        timestamptz uploaded_at
        timestamptz published_at "NULL: PRIVATE only"
        bigint view_count "derived: new uploads start at 0"
    }
    subscriptions {
        integer user_id PK, FK
        integer channel_id PK, FK
        varchar notifications
        timestamptz subscribed_at
    }
    watch_events {
        integer watch_id PK
        integer user_id FK "NULL: logged-out view"
        char video_id FK
        timestamptz started_at
        integer watch_seconds
        varchar device
        varchar traffic_source
    }
    video_reactions {
        integer user_id PK, FK
        char video_id PK, FK
        varchar reaction "LIKE or DISLIKE"
        timestamptz reacted_at
    }
    comments {
        integer comment_id PK
        char video_id FK
        integer user_id FK
        integer parent_comment_id FK "NULL: top-level; self-ref"
        varchar body
        integer like_count
        boolean is_pinned
        timestamptz created_at
    }
    playlists {
        integer playlist_id PK
        integer owner_user_id FK
        varchar title
        varchar visibility
        timestamptz created_at
    }
    playlist_items {
        integer playlist_id PK, FK
        smallint position PK "1..n order in playlist"
        char video_id FK
        timestamptz added_at
    }
    ad_impressions {
        integer impression_id PK
        integer watch_id FK "ON DELETE RESTRICT"
        varchar ad_format "PREROLL or MIDROLL"
        numeric revenue_inr "INR, NUMERIC(10,4)"
        timestamptz shown_at
    }

    users           ||--o{ channels : "owns"
    users           ||--o{ subscriptions : "subscribes via"
    channels        ||--o{ subscriptions : "gains"
    channels        ||--o{ videos : "uploads"
    users           |o--o{ watch_events : "generates"
    videos          ||--o{ watch_events : "receives"
    watch_events    ||--o{ ad_impressions : "shows"
    users           ||--o{ video_reactions : "reacts via"
    videos          ||--o{ video_reactions : "rated by"
    users           ||--o{ comments : "writes"
    videos          ||--o{ comments : "discussed in"
    comments        |o--o{ comments : "replies to"
    users           ||--o{ playlists : "owns"
    playlists       ||--o{ playlist_items : "contains"
    videos          ||--o{ playlist_items : "appears in"
```

## 6. Functional dependencies and normal form

Notation: `→` "determines". Every table below is in **3NF and BCNF** — in each one, every non-trivial FD's determinant is a superkey (the PK, or one of the candidate keys).

**users** — `user_id → (email, display_name, country_code, birth_year, premium_until, created_at)`; `email → user_id` (unique). Both determinants are candidate keys. **3NF/BCNF.**

**channels** — `channel_id → (owner_user_id, handle, …)`; `handle → channel_id` (unique). No FD between non-key columns. **3NF/BCNF.**

**videos** — `video_id → (channel_id, title, …)`. `channel_id → channel_name` etc. does **not** live here (that's the channels table), so no transitive chain. **3NF/BCNF.** `is_short` and `view_count` are derived *values*, not FDs — see §7.

**subscriptions** — key `(user_id, channel_id)`; `subscribed_at` and `notifications` depend on the whole key (you cannot know when X subscribed to Y from X or Y alone). No partial, no transitive dependencies. **3NF/BCNF.**

**watch_events** — `watch_id → (user_id, video_id, started_at, …)`; `started_at` etc. depend on the event, never on `user_id` or `video_id` alone. **3NF/BCNF.**

**video_reactions** — key `(user_id, video_id)`; `reaction`, `reacted_at` depend on the pair. **3NF/BCNF.**

**comments** — `comment_id → (video_id, user_id, parent_comment_id, …)`; a reply's existence depends on one row. **3NF/BCNF.**

**playlists** — `playlist_id → (owner_user_id, title, visibility, created_at)`. **3NF/BCNF.**

**playlist_items** — key `(playlist_id, position)`; `video_id` and `added_at` depend on the pair (the same video in two playlists is a different row). **3NF/BCNF.**

**ad_impressions** — `impression_id → (watch_id, ad_format, revenue_inr, shown_at)`. Revenue depends on the impression, not on the watch alone (one watch can carry PREROLL + MIDROLL with different revenue). **3NF/BCNF.**

## 7. Derived / redundant columns — kept, with justification

| Column | Derivation | Why we keep it |
|---|---|---|
| `channels.subscriber_count` | `count(*)` over `subscriptions` per channel | W04 recomputes it nightly. Reading a channel page (R02) then costs one row lookup instead of counting up to ~5,000 subscription rows. Verified consistent with the export (IC7: 0 mismatches). |
| `videos.view_count` | `count(*)` over `watch_events` per video | W03 increments it on every view. Same read-vs-compute trade-off; verified consistent (IC6). The counter and the events can drift between refreshes — an accepted, documented staleness. |
| `videos.is_short` | `duration_sec <= 60` | The flag is exactly `duration_sec <= 60` in all 30,000 rows. Keeping the explicit boolean documents creator intent and stays stable if YouTube ever changes the Shorts limit (only the *rule* "Short ⇒ ≤ 60 s" is constrained, not the converse). |

## 8. Load results (real run)

```bash
createdb youtube
psql -d youtube -f sql/01_schema.sql          # runs clean
psql -d youtube -f sql/02_load_data.sql       # from the repo root; ~6 s, no errors
```

Output of the row-count verification at the end of `02_load_data.sql`:

```
table_name       | rows_loaded
-----------------+-------------
ad_impressions   |       57014
channels         |        3000
comments         |       60000
playlist_items   |       56005
playlists        |        8000
subscriptions    |      129253
users            |       30000
video_reactions  |       67417
videos           |       30000
watch_events     |      200000
```

All ten counts match the project brief exactly. Every constraint accepted every row.

## 9. Integrity checks (real output)

Run after `SET search_path TO youtube;` on the loaded database.

**IC1 — Nobody watched a video before it was uploaded**

```sql
SELECT count(*) AS violations
FROM watch_events w JOIN videos v USING (video_id)
WHERE w.started_at < v.uploaded_at;
```
```
violations
-----------
         0
```

**IC2 — `watch_seconds` never exceeds the video duration** (cross-table, hence a check query instead of a CHECK constraint)

```sql
SELECT count(*) AS violations
FROM watch_events w JOIN videos v USING (video_id)
WHERE w.watch_seconds > v.duration_sec;
```
```
violations
-----------
         0
```

**IC3 — No playlist contains the same video twice**

```sql
SELECT count(*) AS playlists_with_duplicates
FROM (SELECT playlist_id FROM playlist_items
      GROUP BY playlist_id, video_id HAVING count(*) > 1) t;
```
```
playlists_with_duplicates
-------------------------
                        0
```

**IC4 — Every ad was shown during its watch event** (between `started_at` and `started_at + watch_seconds`)

```sql
SELECT count(*) AS violations
FROM ad_impressions a JOIN watch_events w USING (watch_id)
WHERE a.shown_at < w.started_at
   OR a.shown_at > w.started_at + make_interval(secs => w.watch_seconds);
```
```
violations
-----------
         0
```

**IC5 — Ads shown to users with an active Premium membership** (business rule: Premium never sees ads)

```sql
SELECT count(*) AS premium_ad_violations
FROM ad_impressions a
JOIN watch_events w USING (watch_id)
JOIN users u ON u.user_id = w.user_id
WHERE u.premium_until >= a.shown_at::date;
```
```
premium_ad_violations
----------------------
                  181
```
→ **181 genuine data-quality violations** (this is exactly what audit query R25 surfaces). We deliberately did *not* add a constraint for it — the database must accept the rows so the audit can find them; the fix belongs in the ad-serving pipeline. See §10.

**IC6 — `videos.view_count` matches the actual watch-event counts**

```sql
SELECT count(*) AS mismatched_videos
FROM videos v
LEFT JOIN (SELECT video_id, count(*) n FROM watch_events GROUP BY video_id) w USING (video_id)
WHERE v.view_count <> coalesce(w.n, 0);
```
```
mismatched_videos
-------------------
                 0
```

**IC7 — `channels.subscriber_count` matches the actual subscription counts**

```sql
SELECT count(*) AS mismatched_channels
FROM channels c
LEFT JOIN (SELECT channel_id, count(*) n FROM subscriptions GROUP BY channel_id) s USING (channel_id)
WHERE c.subscriber_count <> coalesce(s.n, 0);
```
```
mismatched_channels
---------------------
                   0
```

**IC8 — No reply was posted before the comment it replies to**

```sql
SELECT count(*) AS violations
FROM comments r JOIN comments p ON p.comment_id = r.parent_comment_id
WHERE r.created_at < p.created_at;
```
```
violations
-----------
         0
```

**Workload smoke test.** After loading, we ran all 30 queries from `queries/workload_30.sql` (writes inside `BEGIN … ROLLBACK`): **30/30 succeeded**, including R19 — the intentionally heavy one (~17 s at this scale) — and R13, which returns 0 rows (the P5 `NOT IN` + NULL trap to be explained in Phase 4).

## 10. Data problems and notable findings

1. **Premium members saw ads — 181 times (IC5/R25).** The clearest genuine data problem in the export. Constraint deliberately omitted (see §9) — the audit query needs those rows to exist.
2. **R13 returns an empty report although such subscribers exist** — not a schema problem: `NOT IN` over a subquery that produces NULLs filters everything out. Identified now; the fix belongs to Phase 4.
3. **Workload W01 initially failed** — it inserts a video without `is_made_for_kids` or `view_count`. The spec is explicit ("fix the schema, not the query"), so both columns now carry `DEFAULT FALSE` / `DEFAULT 0`, which is also the honest business default for a new upload.
4. **Users : channels is 1:1 in this export** (3,000 distinct owners for 3,000 channels) but the business allows more — documented, not constrained.
5. **Two users subscribe to their own channel** — legal on YouTube, kept.
6. **25% of watch events are logged-out** (`user_id IS NULL`) — by design; it drives R12 and is why `watch_events.user_id` is nullable.
7. **Engagement never touches PRIVATE videos** — no reactions, comments or playlist placements reference the 1,526 private videos (platform behaviour working as intended).
8. **`is_short ≡ duration_sec <= 60` exactly** in this export (max Short duration 59 s; shortest regular video 61 s) — we constrain only the business direction (§7).

## 11. Automatic index inventory (Phase 2)

No tuning indexes exist yet. PostgreSQL created exactly these backing indexes:

```
ad_impressions_pkey   ON ad_impressions (impression_id)
channels_handle_key   ON channels (handle)
channels_pkey         ON channels (channel_id)
comments_pkey         ON comments (comment_id)
playlist_items_pkey   ON playlist_items (playlist_id, position)
playlists_pkey        ON playlists (playlist_id)
subscriptions_pkey    ON subscriptions (user_id, channel_id)
users_email_key       ON users (email)
users_pkey            ON users (user_id)
video_reactions_pkey  ON video_reactions (user_id, video_id)
videos_pkey           ON videos (video_id)
watch_events_pkey     ON watch_events (watch_id)
```

Note for Phase 3: with only these, every non-key lookup (R01's `channel_id`, R05's `user_id`, R08's `video_id`, …) will be a Seq Scan — that is exactly the untuned baseline we are supposed to measure.

## 12. How to reproduce

```bash
# from the repository root, with seed_data/ unzipped next to this README
createdb youtube
psql -d youtube -f sql/01_schema.sql
psql -d youtube -f sql/02_load_data.sql     # prints the row-count table at the end
psql -d youtube -c "SET search_path TO youtube; <any IC query from §9>"
```

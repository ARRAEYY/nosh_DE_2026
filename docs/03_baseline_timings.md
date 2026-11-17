# Phase 3 — Baseline Timings (CP2)

**Team:** Adil Reyaz (2501010025), Utkarsh Singh (2501010488), Renuka Yadav (2501010373), Shubham (2501010672)

**Database:** PostgreSQL 16.2, database `youtube`, schema `youtube`.

**How we measured:** `./benchmarks/run_benchmark.sh youtube baseline 3`. Every query runs inside `EXPLAIN (ANALYZE, BUFFERS)`, 3 times, and we report the average. The write queries (W01 to W05) run inside `BEGIN ... ROLLBACK`, so they never actually change the data. We closed other heavy programs, and we will use the same laptop for Phase 4 (CP3) and Phase 5 (CP4), so before/after numbers are comparable.

**Why the baseline is bad on purpose.** The Phase 2 rules allowed only PK, UNIQUE, NOT NULL and CHECK constraints. No tuning indexes. PostgreSQL does index PRIMARY KEY and UNIQUE columns automatically (full list in `docs/02_schema_design.md`), but that is all we have. So this baseline measures the database as the previous team left it: correct constraints, but no fast paths for lookups except by key. Every full table scan (Seq Scan) below is a gap that Phase 4 fills with a specific index or rewrite. That is the point of the exercise: we cannot show improvement without first showing what is slow and why.

---

## How to read this document (EXPLAIN vocabulary)

Each query section shows the real `EXPLAIN (ANALYZE, BUFFERS)` output from run 1. The raw 3-run plans are in `benchmarks/results/baseline/RXX.txt`. Here is what the terms mean, in plain words. These come up at CP5, so it is worth knowing them cold:

- **cost=0.00..1098.00**: the planner's guess of how much work the query needs, in made-up units, before running anything. It is estimated from table statistics. When the estimate and the actual time disagree wildly, either the statistics are off or the planner has no good access path to choose.
- **actual time=0.894..5.003**: what it really took, in milliseconds. First number is time to the first row, second is time to the last row.
- **rows=8 (estimate) vs rows=12 (actual)**: the planner guessed 8 rows, reality was 12. Big guess errors make the planner pick wrong join strategies.
- **Buffers: shared hit=3 read=648**: the most useful line for answering "why is it slow". PostgreSQL reads data in fixed-size blocks called pages. One page is 8 KB. `hit` means the page was already in memory. `read` means it had to be fetched from disk (or the OS cache). 648 pages is about 5.2 MB of data physically read for this query.
- **Rows Removed by Filter: 29988**: rows the database read and then immediately threw away because they did not match the WHERE clause. A big number here means the query is reading a whole table to find a few rows. That is the classic sign of a missing index.
- **Sort Method: quicksort Memory: 26kB** vs **external merge Disk: 3656kB**: sorts that fit in `work_mem` (default 4 MB) run in memory. Bigger sorts spill to disk, and disk is much slower.
- **loops=1087**: the node above ran the node below 1,087 times, once per row of the outer node. A Seq Scan inside a `loops=N` plan means the table gets read N times. That is what kills R19.
- **Workers Planned/Launched: 1**: the planner started an extra parallel worker process. For a query that returns 4 rows, hiring a worker is a waste.
- **sargable**: a WHERE condition an index can actually use. `started_at >= '2026-06-01'` is sargable: it compares the raw column, so an index on started_at can jump straight to the right spot. `DATE(started_at) >= '2026-06-01'` is not: the column is wrapped in a function, so every row must be computed first and an index cannot help. Non-sargable conditions force full scans.

---

## Why run 1 is often slower than runs 2 and 3

Several queries show run 1 clearly above runs 2 and 3. For example R01: 5.066, then 2.737, then 2.713 ms. And R25: 128.6, then 79.0, then 77.6 ms. The reason is caching. On run 1 the pages come from disk (`read`). On runs 2 and 3 they are already in PostgreSQL's memory (`hit`). We keep all three runs in the raw files so anyone can see both cold and warm behavior, and we report the average of 3 as the fair number.

---

## Timing table (all 30 queries)

| SQL Query | Type | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) |
| --- | --- | ---: | ---: | ---: | ---: |
| R01: Channel page: the 20 newest public videos of channel 217 | READ | 5.066 | 2.737 | 2.713 | 3.505 |
| R02: Watch page: one video with its channel | READ | 0.078 | 0.052 | 0.050 | 0.060 |
| R03: Subscriptions feed: public videos from channels user 1042 subscribes to, newest first | READ | 5.221 | 5.216 | 5.126 | 5.188 |
| R04: Search: public videos with "tutorial" in the title, most viewed first | READ | 17.103 | 16.840 | 16.950 | 16.964 |
| R05: History page: the last 50 videos user 1042 watched | READ | 13.791 | 8.972 | 8.268 | 10.344 |
| R06: Publishing service: videos scheduled to go live in the first week of July 2026 | READ | 3.141 | 3.082 | 3.079 | 3.101 |
| R07: YouTube Studio: channel 217's daily views and watch hours in June 2026 | READ | 15.660 | 16.058 | 31.603 | 21.107 |
| R08: YouTube Studio: where views of video ZkNSlUB1EOs come from | READ | 8.393 | 8.415 | 8.299 | 8.369 |
| R09: YouTube Studio: average percentage watched for each of channel 217's videos | READ | 17.354 | 17.182 | 16.988 | 17.175 |
| R10: Shorts shelf: most viewed Shorts in the last 7 days of June 2026 | READ | 16.769 | 16.792 | 16.650 | 16.737 |
| R11: Trending tab: top 5 videos per category by views in June 2026 | READ | 34.631 | 33.059 | 33.629 | 33.773 |
| R12: Growth: share of logged-out viewing per device type | READ | 23.739 | 23.508 | 23.332 | 23.526 |
| R13: Creator insights: subscribers of channel 217 who have never watched any of its videos | READ | 29.997 | 28.284 | 28.171 | 28.817 |
| R14: YouTube Studio: likes, dislikes and like ratio per video of channel 217 | READ | 19.844 | 17.681 | 17.446 | 18.324 |
| R15: Watch page: pinned comment and top 10 comments of video ZkNSlUB1EOs | READ | 6.922 | 4.184 | 4.159 | 5.088 |
| R16: Finance: ad revenue per channel in June 2026, top 20 | READ | 26.770 | 24.558 | 24.818 | 25.382 |
| R17: Partner program: NOT_ELIGIBLE channels that now have 100+ subscribers and 40+ watch hours | READ | 25.865 | 25.317 | 43.323 | 31.502 |
| R18: Child safety: "made for kids" videos that still have comments | READ | 22.476 | 22.814 | 22.606 | 22.632 |
| R19: Partner report: for every monetized channel, its latest upload and its total views | READ | 30462.231 | 30411.564 | 30477.013 | 30450.269 |
| R20: Platform analytics: daily watch hours and running total for June 2026 | READ | 15.037 | 14.840 | 14.687 | 14.855 |
| R21: Playlist page: playlist 501 in order | READ | 0.196 | 0.170 | 0.121 | 0.162 |
| R22: Copyright team: same title and duration uploaded by more than one channel | READ | 32.477 | 32.967 | 32.460 | 32.635 |
| R23: Moderation queue: all comments, newest first, page 1,201 (25 per page) | READ | 26.210 | 36.818 | 25.339 | 29.456 |
| R24: YouTube Studio: new subscribers per month for channel 217 | READ | 2.261 | 1.369 | 2.026 | 1.885 |
| R25: Premium audit: ads that were shown to users with an active Premium membership | READ | 128.610 | 79.024 | 77.591 | 95.075 |
| W01: Upload: a new public video on channel 217 | WRITE | 1.086 | 0.551 | 0.541 | 0.726 |
| W02: Player: record a view of video ZkNSlUB1EOs by user 1042 | WRITE | 0.808 | 0.662 | 1.061 | 0.844 |
| W03: View counter: add one view to video ZkNSlUB1EOs | WRITE | 0.479 | 0.302 | 0.456 | 0.412 |
| W04: Nightly job: recompute every channel's subscriber count | WRITE | 65.290 | 80.465 | 49.836 | 65.197 |
| W05: Publishing service: make scheduled videos public once their time has come | WRITE | 5.376 | 3.753 | 5.132 | 4.754 |
| **Total (sum of all 30)** | | **62692.59** | **62623.92** | **62647.09** | **30987.864** |

**One query dominates everything.** R19 alone is 30,450 ms of the 30,988 ms total. That is 98.2%. The other 29 queries together are only 537 ms. So the practical priority is clear: fixing R19 is worth more than fixing everything else combined. After R19, the next tier is the 20 to 95 ms report queries (R11, R22, R25, R17, R16, R12, R18, R09, R14, R10, R20, R04).

---

## Per-query analysis

### R01: Channel page: the 20 newest PUBLIC videos of channel 217 (3.505 ms)

This is the channel page a viewer opens (problem P1). It needs to feel instant, target under 5 ms on large data.

```
Limit  (cost=1098.12..1098.14 rows=8) (actual time=5.034..5.037 rows=12)
  Buffers: shared hit=3 read=648
  ->  Sort  (cost=1098.12..1098.14 rows=8) (actual time=5.034..5.037 rows=12)
        Sort Key: published_at DESC
        Sort Method: quicksort  Memory: 26kB
        ->  Seq Scan on videos  (cost=0.00..1098.00 rows=8) (actual time=0.894..5.003 rows=12)
              Filter: ((channel_id = 217) AND (visibility = 'PUBLIC'))
              Rows Removed by Filter: 29988
              Buffers: shared read=648
Execution Time: 5.066 ms   (run 1; runs 2-3 are about 2.7 ms, cache warm)
```

**What the plan says:** the planner guessed 8 matching rows, the real number is 12 (channel 217 has 15 videos, 12 of them PUBLIC). The Sort step only exists because of `ORDER BY published_at DESC` before `LIMIT 20`.

**Why it is slow:** the Seq Scan reads 648 pages, about 5.2 MB of the videos table, and throws away 29,988 of 30,000 rows. That is 99.96% wasted reading, to find 12 rows. The WHERE clause is fine and index-friendly. The problem is simply that no index on `(channel_id, ...)` exists. The videos PK is on `video_id`, which does not help here.

An analogy: it is like a book with no index at the back. To find every mention of "channel 217" you have to flip through all 300 pages, even if it is mentioned on only 12 of them.

**What Phase 4 will do:** add a partial covering index `(channel_id, published_at DESC) INCLUDE (video_id, title, duration_sec, view_count) WHERE visibility='PUBLIC'`. Then the database jumps straight to channel 217's 12 public videos, already in newest-first order. No table scan, no sort step.

### R02: Watch page: one video with its channel (0.060 ms)

```
Nested Loop
  -> Index Scan using videos_pkey on videos (rows=1)      -- PK equality
  -> Index Scan using channels_pkey on channels (rows=1)  -- PK equality
Execution Time: 0.078 ms
```

This one is already as good as it gets. Two index lookups: find the video by its id, find its channel by its id. Each lookup touches about 3 index pages plus one table page. This is what every viewer-facing query should look like, and it is the reference point for what the other queries are missing. Nothing to fix.

### R03: Subscriptions feed for user 1042 (5.188 ms)

The home feed (P2): newest PUBLIC videos from the channels user 1042 subscribes to.

```
Limit (rows=30)
  -> Sort  Sort Key: v.published_at DESC
       -> Nested Loop
            -> Index Only Scan using subscriptions_pkey on subscriptions s (user_id = 1042)   -- OK
            -> Seq Scan on videos v (channel_id = s.channel_id AND visibility = 'PUBLIC')
               Rows Removed by Filter: (per channel, ~29990 of 30000)
Execution Time: 5.221 ms
```

**What the plan says:** the subscriptions side is already good. The PK is `(user_id, channel_id)`, and looking up `user_id = 1042` uses the first column of that index, so it works as an Index Only Scan.

**Why it is slow:** for each subscribed channel, the database then searches `videos` for that channel's public videos. But there is no `(channel_id, ...)` index, so each probe reads the whole 30,000-row videos table. User 1042 subscribes to only a handful of channels, but each one costs a full scan.

**What Phase 4 will do:** the same `(channel_id, published_at DESC) WHERE visibility='PUBLIC'` index from R01 serves every probe. The feed becomes a few small index range reads, then one merge for the newest-first order.

### R04: Search: "tutorial" in title (16.964 ms)

The search box (P3).

```
Limit (rows=20)
  -> Sort  Sort Key: view_count DESC
       -> Seq Scan on videos
            Filter: (title ILIKE '%tutorial%' AND visibility = 'PUBLIC')
            Rows Removed by Filter: ~29700 of 30000
Execution Time: 17.103 ms
```

**Why it is slow, two separate reasons:**

1. `ILIKE '%tutorial%'` has a wildcard on both sides. A normal B-tree index on `title` keeps rows in alphabetical order, so it can only help when the beginning of the text is known, like `'tutorial%'`. With `'%tutorial%'` the word can start anywhere, so a B-tree is useless here. The right tool is a GIN trigram index from the `pg_trgm` extension. It splits every title into 3-character pieces and can answer "contains" searches.
2. Even after finding the matches (about 2,900 public videos contain "tutorial"), the `ORDER BY view_count DESC LIMIT 20` needs a top-20 sort of all matches. That part is acceptable once the matches are found through an index instead of a full scan.

**What Phase 4 will do:** try `CREATE EXTENSION pg_trgm` plus a GIN index on title. One honest note: pg_trgm is a contrib extension, and it is not installed on this benchmark machine. So our optimized run keeps the Seq Scan for R04, and we say so in the report instead of hiding it.

### R05: History page: last 50 videos user 1042 watched (10.344 ms)

Watch history (P2).

```
Gather Merge  (Workers Planned: 1, Workers Launched: 1) (actual time=13.163..13.724 rows=4)
  -> Sort (actual time=11.201..11.202 rows=2 loops=2)
       Sort Key: w.started_at DESC
       -> Nested Loop (rows=2 loops=2)
            -> Parallel Seq Scan on watch_events w (cost=0.00..3470.59 rows=4) (actual rows=2 loops=2)
                 Filter: (user_id = 1042)
                 Rows Removed by Filter: 99998
                 Buffers: shared read=2000
            -> Index Scan using videos_pkey on videos v (actual time=0.018 rows=1 loops=4)
Execution Time: 13.791 ms
```

**What the plan says:** the planner knew the answer was tiny. It guessed 4 rows and it was exactly right (user 1042 has 4 watch events). It still chose a parallel scan and even started an extra worker process. That is the tell: when the planner parallelizes a 4-row result, it is because it has no index to use instead. 2,000 pages, about 16 MB, read to find 4 rows scattered in the table. The videos side of the join is already fine (PK lookup).

**Why it is slow:** `watch_events` has no index on `user_id`. Its PK is `watch_id`. So every visit to the history page reads the entire 200,000-row table. This is the clearest missing index in the whole workload.

**What Phase 4 will do:** covering index `(user_id, started_at DESC) INCLUDE (video_id, watch_seconds)`. The 4 rows get found through about 3 index pages, with the values coming from the index itself. Expected: around 0.1 ms.

### R06: Scheduled videos in the first week of July 2026 (3.101 ms)

The publishing service's poll (P7): which SCHEDULED videos go live soon?

```
Sort  Sort Key: published_at
  -> Seq Scan on videos
       Filter: (visibility = 'SCHEDULED' AND published_at < '2026-07-08')
       Rows Removed by Filter: ~29950 of 30000
Execution Time: 3.141 ms
```

**Why it is slow:** SCHEDULED is a rare status. Only about 50 rows out of 30,000 have it. But rarity does not help by itself. Without an index that filters on it, the database still reads all 30,000 rows to find those 50.

**What Phase 4 will do:** a partial index `ON videos (published_at) WHERE visibility='SCHEDULED'`. A partial index only contains rows matching its WHERE clause, so this one is physically tiny: it holds only the scheduled videos, ordered by date. It serves both the date range and the ORDER BY. The same index also serves W05, the publisher's UPDATE, because that query filters on exactly the same condition. One index, two queries.

### R07: Studio: channel 217's daily views and watch hours in June 2026 (21.107 ms)

Studio daily chart (P4).

```
GroupAggregate  Group Key: (date(w.started_at))
  -> Sort
       -> Nested Loop / Parallel Hash Join
            -> Parallel Seq Scan on watch_events w (actual rows=5452 loops=2)
                 Filter: ((date(started_at) >= '2026-06-01') AND (date(started_at) <= '2026-06-30'))
                 Rows Removed by Filter: 94548 (per worker)
            -> Seq Scan on videos v (channel_id = 217, rows=15, removed 29985)
Execution Time: 15.660 ms (run 1)
```

**Why it is slow, two separate problems:**

1. `DATE(w.started_at)` is not sargable. The WHERE clause wraps the column in a function, so no index on `started_at` can ever be used. The whole 200,000-row table gets scanned and the function runs on every row (189,096 rows removed: only June's 10,904 events actually matter).
2. The channel filter needs "channel 217's videos", but there is no `(channel_id, ...)` index on videos, so that side is also a full scan.

**What Phase 4 will do:** rewrite the date condition into a form an index can use: `started_at >= '2026-06-01' AND started_at < '2026-07-01'`. This returns exactly the same rows (a timestamp belongs to June if and only if it is on or after June 1, 00:00 and before July 1, 00:00). Then a small BRIN index on `started_at` lets the database skip all non-June pages, and the `(channel_id, ...)` index serves the other side.

### R08: Studio: traffic sources for video ZkNSlUB1EOs (8.369 ms)

```
HashAggregate  Group Key: traffic_source
  -> Seq Scan on watch_events
       Filter: (video_id = 'ZkNSlUB1EOs')
       Rows Removed by Filter: ~199900 of 200000
Execution Time: 8.393 ms
```

**Why it is slow:** the video has 97 watch events, but finding them means reading the whole 16 MB table and throwing away about 199,900 rows. Same disease as R05 with a different key: no index on `watch_events(video_id)`, because the PK is `watch_id`. Every per-video Studio chart (R08, R09, R10, R11, R16, R17) has this same gap underneath it.

**What Phase 4 will do:** covering index `(video_id) INCLUDE (user_id, started_at, watch_seconds, traffic_source)`. The whole aggregate then reads about 97 index entries in a few pages.

### R09: Studio: avg % watched per video of channel 217 (17.175 ms)

Channel 217 has 15 videos, and the query needs each video's watch events. The plan joins a full scan of `videos` (filtered on channel, 29,985 rows removed) with a full scan of `watch_events` (all 200k, hash join) and then groups. Both sides are unindexed, so we pay for two full scans. The fixes are the same as R07 and R08: an index for the channel side and one for the video side.

### R10: Shorts shelf: last 7 days of June 2026 (16.737 ms)

Scans a time range (June 24 to 30) joined with `videos` filtered on `is_short`. The watch_events side is scanned fully. Its date condition is on the raw column (so it is sargable), but no index exists yet. The videos side is scanned for the `is_short` flag. **Phase 4:** BRIN on `started_at` (rows were inserted in time order, so a BRIN works well here, explained in the optimization report) plus the shared `(video_id)` covering index.

### R11: Trending: top 5 per category in June 2026 (33.773 ms)

The heaviest aggregate after R19. It scans the full June window (10,904 events out of 200k), joins and groups by (category, video) over about 11k rows, then ranks with `RANK() OVER (PARTITION BY category)`. Being realistic here: even with perfect indexes, this query has to read all of June's rows, because the answer depends on every one of them. An index can only remove the other 17 months from the scan. Phase 4 adds the BRIN and accepts the remaining cost. On the large dataset this query will grow roughly with the data, and the scalability report (section 2.2) treats it as such.

### R12: Growth: logged-out share per device (23.526 ms)

```
HashAggregate  Group Key: device
  -> Seq Scan on watch_events          -- no WHERE clause at all
Execution Time: 23.739 ms
```

**Why this cannot be fixed by an index:** the query has no WHERE clause. It groups all 200,000 rows by device. To count every row you have to visit every row, so a full scan is the best possible plan. This one is not a defect, it is just what the query asks for. The only real fix is architectural: a summary table recomputed nightly. That is a Phase 5 idea (scalability report, section 5.4).

### R13: Creator insights: subscribers of 217 who never watched its videos (28.817 ms). This is the WRONG-ANSWER query

```
Index Scan using subscriptions_pkey on subscriptions s (actual time=28.227..28.231 rows=0 loops=1)
  Index Cond: (channel_id = 217)
  Filter: (NOT (hashed SubPlan 1))
  Rows Removed by Filter: 88              <- ALL 88 subscribers removed!
  SubPlan 1
    -> Hash Join (rows=97)
         -> Seq Scan on watch_events w (rows=200000)
         -> Hash -> Seq Scan on videos v (channel_id = 217, rows=15, removed 29985)
Execution Time: 29.997 ms
```

**This query returns 0 rows, and that is wrong.** Here is the full explanation. The subquery finds channel 217's 97 watch events. 24 of those events have `user_id IS NULL` (logged-out views; 25% of the whole table is logged out, so this is normal data, not a rare edge case). The outer query then asks "is this subscriber in that list of watchers?" using `user_id NOT IN (subquery)`.

The rule that bites us: in SQL, comparing anything with NULL gives NULL, not true or false. And `x NOT IN (list)` is only true if x differs from every element of the list. If the list contains even one NULL, then "x differs from every element" can never be proven true, so the result is never true. Every row gets filtered out. All 88 subscribers are removed, for every channel, always. That is exactly the P5 complaint: "the report always comes back empty".

A tiny example:

| x | list | `x IN (list)` | `x NOT IN (list)` | row kept by WHERE? |
|---|---|---|---|---|
| 5 | {1, 2} | false | true | yes |
| 5 | {1, NULL} | NULL | NULL | no |
| NULL | {1, 2} | NULL | NULL | no |

**The fix (Phase 4):** replace `NOT IN` with `NOT EXISTS`:

```sql
AND NOT EXISTS (SELECT 1
                FROM watch_events w JOIN videos v ON v.video_id = w.video_id
                WHERE v.channel_id = 217 AND w.user_id = s.user_id);
```

`NOT EXISTS` compares values row by row (`w.user_id = s.user_id`). A NULL user_id never equals anything, so it is simply skipped, which is what the business actually means: "this subscriber has no watch event on record". We proved it on the loaded data: the original returns 0 rows, the rewrite returns **88 rows**, which is the true answer for channel 217.

### R14: Studio: likes/dislikes per video of channel 217 (18.324 ms)

The `video_reactions` PK is `(user_id, video_id)`. That order is designed for "did THIS user react to THIS video". But this query asks the reverse: "give me all reactions for THESE videos". A B-tree index can only be searched by its leading columns, so with `video_id` second, the PK cannot help. The plan scans all 67,417 reactions. **Phase 4:** a covering index `(video_id) INCLUDE (reaction)`. The per-video count of likes and dislikes then reads only the index.

### R15: Watch page: pinned + top 10 comments of ZkNSlUB1EOs (5.088 ms)

```
Limit (rows=11)
  -> Sort  Sort Key: (is_pinned DESC, like_count DESC)
       -> Seq Scan on comments
            Filter: (video_id = 'ZkNSlUB1EOs' AND parent_comment_id IS NULL)
            Rows Removed by Filter: ~59990 of 60000
Execution Time: 6.922 ms
```

The video has about 11 top-level comments. Finding them reads 60,000 rows, about 5 MB, then sorts them. **Phase 4:** partial covering index `(video_id, is_pinned DESC, like_count DESC) INCLUDE (comment_id, user_id, body, created_at) WHERE parent_comment_id IS NULL`. Two ideas combine here. First, the partial WHERE keeps replies out of the index entirely. Second, the column order matches the sort order, so the LIMIT 11 just reads the first 11 entries of that video's section. No sort step, no table visit.

### R16: Finance: ad revenue per channel in June 2026 (25.382 ms)

Three-way join: `ad_impressions` (June filter on `shown_at`) joined to `watch_events` (on `watch_id`, uses the PK) joined to `videos` (on `video_id`, uses the PK), then grouped by channel. June holds only 4,739 of 57,014 impressions, but there is no `shown_at` index, so all impressions get scanned, and the watch_events side contributes its own full scan for the join. **Phase 4:** BRIN on `ad_impressions(shown_at)` plus the shared `watch_events(video_id)` index.

### R17: Partner program: NOT_ELIGIBLE channels now eligible (31.502 ms)

Filters channels on the rare `NOT_ELIGIBLE` status, joins through `videos` to `watch_events`, and adds up watch hours per channel with a HAVING clause. All three tables are fully scanned: the status filter, the channel-to-videos step, and the videos-to-watches step are all unindexed. **Phase 4:** a partial index on the rare status plus the two shared covering indexes. Some scanning will remain, because the HAVING aggregate has to see every NOT_ELIGIBLE channel's events to compute the sums. We say that openly in the optimization report.

### R18: Child safety: made-for-kids videos that still have comments (22.632 ms)

`is_made_for_kids` is true for 2,236 of 30,000 videos (7.5%, rare enough for a partial index). The `EXISTS (comments ...)` check has no `(video_id)` index on comments either, so each of the 2,236 checks scans all 60,000 comments. **Phase 4:** a small partial index on the kids flag plus `comments(video_id)`. An EXISTS check can be answered from an index alone, without touching the table.

### R19: Partner report: monetized channels' latest upload + total views (30,450.269 ms). The intentionally slow query

```
Sort (cost=7143291..7143295 rows=1087) (actual time=30458..30459 rows=1087)
  Sort Key: ((SubPlan 2)) DESC
  Buffers: shared hit=3582826                     <- 3.58 MILLION buffer hits
  -> Seq Scan on channels c (cost=0..14089259) (actual time=30.549..30458.861 rows=1087 loops=1)
       Filter: (monetization_status = 'ELIGIBLE')
       Rows Removed by Filter: 1913
       SubPlan 1   (max uploaded_at for this channel)
         -> Aggregate (loops=1087)
              -> Seq Scan on videos v (rows=10 loops=1087)         <- 10 useful rows per scan
                   Rows Removed by Filter: 29990                   <- 29,990 wasted per scan
                   Buffers: shared hit=704376
       SubPlan 2   (count of watch events for this channel)
         -> Aggregate (loops=1087) (actual time=25.953 each)
              -> Hash Join (rows=65 loops=1087)
                   -> Seq Scan on watch_events w (rows=200000 loops=1087)   <- x1087!!
                        Buffers: shared hit=2174000
                   -> Hash -> Seq Scan on videos v_1 (rows=10 loops=1087)
Execution Time: 30462.231 ms
```

**What is happening, step by step:**

- 1,087 of the 3,000 channels are ELIGIBLE. For each of them, PostgreSQL runs SubPlan 1 (a fresh scan of all 30,000 videos to find that channel's 10) and SubPlan 2 (a fresh scan of all 200,000 watch events, joined to the channel's videos).
- The line `rows=200000 loops=1087` is the whole story. 1,087 times 200,000 is about 217.4 million row visits. The buffer counter shows 3,582,826 page touches, roughly 27 GB of page accesses. Most of that is absorbed by cache, so it is not 27 GB of disk reading, but every page still costs CPU to walk. 1,087 scans at about 26 ms each is around 28 seconds of pure re-scanning.
- The planner knew this plan was terrible. Its cost estimate was 14,089,259 units, enormous. It picked it anyway because with no indexes there was nothing better to pick.
- Total: 30.45 seconds, 98.2% of the whole baseline. The brief said one query would take seconds. It is this one.

**The Phase 4 fix (the biggest rewrite of the project):** turn both correlated subqueries into a `CROSS JOIN LATERAL`, so each per-channel question becomes an index lookup. `(channel_id, uploaded_at DESC)` answers "latest upload" by reading one entry. The `(video_id, user_id)` covering index answers "total views" by counting only that channel's own events. Result: 96.5 ms, a 315 times improvement, same 1,087 rows, proven identical with EXCEPT in both directions (details in the optimization report).

### R20: Platform analytics: daily watch hours + running total for June 2026 (14.855 ms)

Has the same non-sargable date problem as R07 (`started_at::date BETWEEN ...`), plus a window function `sum(hours) OVER (ORDER BY day)` over the 30 grouped days. The window part is trivial because it only sees 30 rows. All the cost is the full scan underneath it. **Phase 4:** the same sargable rewrite plus BRIN.

### R21: Playlist page: playlist 501 in order (0.162 ms)

```
Nested Loop
  -> Index Scan using playlist_items_pkey on playlist_items (playlist_id = 501)
  -> Index Scan using videos_pkey on videos
Execution Time: 0.196 ms
```

Already fast, and there is a design story worth telling here. We made the `playlist_items` PK `(playlist_id, position)`. Because `playlist_id` is the first column of the PK, the PK index serves `WHERE playlist_id = 501` directly. And within one playlist's section, the index is already stored in position order, so `ORDER BY position` costs nothing. This is a Phase 2 design decision paying off two phases later. No Phase 4 work needed.

### R22: Copyright: same title+duration across channels (32.635 ms)

```
HashAggregate / GroupAggregate  Group Key: (title, duration_sec)
  -> Seq Scan on videos              -- all 30,000 rows, no WHERE
       (then HAVING count(DISTINCT channel_id) > 1, LIMIT 50)
Execution Time: 32.477 ms
```

Like R12, there is no filter condition. Finding duplicate (title, duration) pairs means grouping every video, because a duplicate can be anywhere in the table. An index on (title, duration_sec) would make the scan cheaper (index-only instead of table), but the full read stays. This query is what it is. The Phase 5 answer would be preventing duplicates in the first place, which is out of scope because the data intentionally contains them.

### R23: Moderation queue: page 1,201, 25 per page (29.456 ms). The disk-spill query

```
Limit (rows=25) (actual time=22.341..24.590 rows=30025)
  Buffers: shared hit=659, temp read=457 written=458        <- TEMP SPILL
  -> Sort (cost=6018..6168 rows=60000)
       Sort Key: created_at DESC
       Sort Method: external merge  Disk: 3656kB             <- 3.6 MB sorted on DISK
       -> Seq Scan on comments (rows=60000)
Execution Time: 26.210 ms
```

**Two costs stacked on top of each other:**

1. Sorting 60,000 rows does not fit in `work_mem` (default 4 MB), so PostgreSQL writes 3.6 MB to temporary files and reads it back (`temp read=457 written=458`: 458 pages written, 457 read back). A disk round trip, for a query that returns 25 rows.
2. `OFFSET 30000` then throws away 30,025 sorted rows and hands back the remaining 25. And OFFSET gets more expensive the deeper you page: page 2,000 would sort and skip everything all over again.

**The Phase 4 fix: keyset pagination.** Instead of counting past 30,000 rows, remember the last row of the previous page (its `created_at` and `comment_id`) and ask for "the next 25 rows at or below that point" using `(created_at, comment_id) <= (last seen)`, with an index in exactly that order. The plan becomes an index-only read of exactly 25 entries. No sort, no spill, no skipping. How the "last seen" value is chosen is a fair exam question: in the real app, the client keeps the previous page's last row, so no OFFSET ever runs. For the benchmark we compute the seek point with one offset probe (explained in the optimization report).

### R24: Studio: new subscribers per month for channel 217 (1.885 ms)

```
Index Scan using subscriptions_pkey on subscriptions (rows=88)
  Index Cond: (channel_id = 217)      -- channel_id is NOT the leading PK column!
  (then HashAggregate on date_trunc('month', subscribed_at))
Execution Time: 2.261 ms
```

**A subtle one worth understanding.** The PK is `(user_id, channel_id)`, so `channel_id = 217` cannot use the index as a direct jump (it is the second column). The planner still uses the index, but as a full walk of the whole index with a filter, not a targeted seek. It looks fast here only because the whole PK index (2,848 kB) is smaller than the table (7,552 kB). At 20 times the data this stops working well. **Phase 4:** a channel-first index `(channel_id, subscribed_at) INCLUDE (user_id)`, which does a proper targeted read of the 88 entries.

### R25: Premium audit: ads shown to Premium users (95.075 ms)

The biggest query after R19. It hash-joins three full table scans (`watch_events` 200k, `ad_impressions` 57k, `users` 30k), then filters on the Premium window `u.premium_until >= a.shown_at::date`. The result is only 181 rows, the audit violations the seed data deliberately contains. The 95 ms average is dominated by the cold first run (128 ms vs about 78 ms warm). **Phase 4:** a `ad_impressions(watch_id)` join index plus the shared watch_events index remove two of the three scans. The users table is small. Some cost remains, because the 181-row answer is deliberately hard to find in 257k rows of haystack. We report it as it is.

### W01: Upload a new public video (0.726 ms)

A single-row INSERT. The cost is the PK uniqueness check, the FK check to channels (an index probe), and CHECK constraint evaluation. All in-memory operations. This is what an INSERT should cost, and it doubles as our measuring stick for Phase 4: when we add indexes, each one makes every future INSERT slightly more expensive (one more index entry to write). We measure W01 before and after to quantify exactly that.

### W02: Record a view (0.844 ms)

Single-row INSERT into `watch_events`, with FK probes on `users_pkey` and `videos_pkey`. Fast today. Phase 4 adds 4 indexes to watch_events, so each insert will write 4 more index entries. The write-overhead section of the optimization report measures this exact change.

### W03: Add one view to ZkNSlUB1EOs (0.412 ms)

```
Update on videos
  -> Index Scan using videos_pkey on videos (video_id = 'ZkNSlUB1EOs') (rows=1)
```

PK lookup plus a single-row update. Already as good as it gets.

### W04: Nightly job: recompute every channel's subscriber_count (65.197 ms)

```
Update on channels
  -> Seq Scan on channels (rows=3000)
  ... from (Subquery: HashAggregate -> Seq Scan on subscriptions (rows=129253), Group Key: channel_id)
```

The subquery has to add up all 129,253 subscriptions grouped by channel. A full scan is unavoidable for "recompute every channel". The 65 ms is real work. Phase 4's `(channel_id) INCLUDE (user_id)` index lets the grouping run as an Index Only Scan, which is where its modest speedup comes from. As a nightly batch job it stays well inside its 2 second target either way.

### W05: Publishing flip: SCHEDULED to PUBLIC (4.754 ms)

Scans `videos` looking for SCHEDULED rows past their timestamp. The R06 partial index serves this UPDATE the same way it serves R06 itself: the index finds the rare scheduled rows without touching the rest of the table. One index, one read query and one write query.

---

## Patterns across the whole workload

### 1. What the five fast queries have in common

R02 (0.060), R21 (0.162), W03 (0.412), W01 (0.726), W02 (0.844). Every one is an exact-key lookup or a single-row write. Their plans are 1 to 3 index probes. That is the shape every query wants. The baseline shows exactly what stands between the other 25 queries and that shape.

### 2. The full scans, grouped by actual cause

20 of the 25 read queries contain at least one Seq Scan. Grouping them by cause, not by symptom:

| Cause | Queries | What is going on |
|---|---|---|
| Missing index on the FK side of a join (the child table has no index on the column we search by) | R03, R05, R08, R09, R10, R11, R14, R16, R17, R18 | The parent tables have PK indexes, but the search flows the other way: watch_events by video_id, reactions by video_id, comments by video_id |
| Date condition wrapped in a function (not sargable) | R07, R20 | `DATE(col)` or `col::date` in WHERE blocks any index on the column |
| Correlated subquery times a full scan | R19, R13 | the inner plan re-scans the table once per outer row (loops=1087) |
| OFFSET pagination plus a disk-spilling sort | R23 | full sort spilled to disk, then 30k rows discarded |
| Rare status or flag without a partial index | R06, R17, R18 | SCHEDULED, NOT_ELIGIBLE, made-for-kids are tiny slices of big tables |
| Aggregate with no WHERE at all | R12, R22, (W04) | an index cannot reduce a query that must read every row anyway |

This grouping is the actual to-do list for Phase 4: one missing index type, two rewrites for sargability, one structural rewrite (R19), one pagination rewrite (R23), three partial indexes, and two queries we honestly cannot speed up with indexes.

### 3. How good were the planner's guesses

Very good, wherever it had statistics (we ran ANALYZE after loading, visible in `02_load_data.sql`). R05: guessed 4, actual 4. R01: guessed 8, actual 12. R19: guessed 1,087 eligible channels, actual 1,087. So none of our slowness comes from bad estimates. It all comes from missing access paths. That distinction matters at CP5: the fix is indexes and rewrites, not planner tuning.

### 4. Where the time actually is

R19 is 98.2% of the total. The Phase 4 strategy follows directly: the one structural rewrite (R19, LATERAL) buys more than every index combined, and the index work then targets the 20-95 ms tier so every group meets its target on the large dataset.

---

## Totals and what "baseline" means

- Sum of all 30 averages: **30,987.864 ms** (R19: 30,450.269, the other 29 combined: 537.595).
- Every number is reproducible: `psql -d youtube -f sql/01_schema.sql && psql -d youtube -f sql/02_load_data.sql && ./benchmarks/run_benchmark.sh youtube baseline 3` on the same laptop.
- Phase 4's job is now defined query by query: add the missing access paths (indexes), remove the anti-patterns (rewrites), and prove the results do not change. The before/after table in `docs/04_optimization_report.md` maps one to one onto the sections above.

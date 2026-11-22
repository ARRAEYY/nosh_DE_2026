# Phase 4: Optimization Report (CP3)

**Team:** Adil Reyaz (2501010025), Utkarsh Singh (2501010488), Renuka Yadav (2501010373), Shubham (2501010672)

**Database:** PostgreSQL 16.2, database `youtube`.

**How we measured:** baseline with `./benchmarks/run_benchmark.sh youtube baseline 3`, optimized with `./benchmarks/run_benchmark.sh youtube optimized 5 sql/06_optimized_queries.sql`. The optimized run uses 5 runs and reports the average, because that is the run count in the brief's example command. Writes run inside `BEGIN ... ROLLBACK`. Same laptop, same PostgreSQL instance, same loaded seed data as Phase 3. The only differences between the two runs are the 17 indexes in `sql/05_indexes.sql` and the 5 rewritten queries in `sql/06_optimized_queries.sql`.

**The rules we followed:**

- Results must stay identical (same rows, and the same order wherever the query has an ORDER BY). We proved it for every rewrite with `EXCEPT` in both directions (section 3).
- No server-setting tricks, no caching outside the database, no data changes.
- `queries/workload_30.sql` is untouched. `06_optimized_queries.sql` is a copy where only R07, R13, R19, R20 and R23 differ. The other 25 queries are byte-identical, so their before/after change measures the pure effect of the indexes, nothing else.

## 1. The wrong-result query: R13's NULL bug (found, explained, fixed)

The brief hides one query that returns a wrong answer because of a SQL NULL rule. It is R13, the query behind the P5 complaint: "the creator report of subscribers who never watched the channel always comes back empty."

**The original query:**

```sql
SELECT s.user_id, s.subscribed_at
FROM subscriptions s
WHERE s.channel_id = 217
  AND s.user_id NOT IN (SELECT w.user_id
                        FROM watch_events w JOIN videos v ON v.video_id = w.video_id
                        WHERE v.channel_id = 217);
```

**Why it silently returns 0 rows.** SQL comparisons have three outcomes: TRUE, FALSE, and NULL (meaning unknown). This trips up `NOT IN` in a specific way:

- `x NOT IN (list)` is true only if x is different from every element of the list.
- But comparing any value with NULL gives NULL, not TRUE or FALSE.
- So if the list contains even one NULL, "x is different from every element" can never be shown true. The result is NULL or FALSE for every x, never TRUE. The WHERE clause keeps only TRUE rows, so nothing survives.

| x | list contains | `x IN (list)` | `x NOT IN (list)` | row kept by WHERE? |
|---|---|---|---|---|
| 5 | {1, 2} | FALSE | TRUE | yes |
| 5 | {1, NULL} | NULL | NULL | no |
| NULL | {1, 2} | NULL | NULL | no |

Our data guarantees the NULL shows up. Channel 217's videos were watched 97 times, and 24 of those watch events have `user_id IS NULL` (logged-out views; 25% of the whole table is logged out, so this is completely normal data). The subquery's list contains NULL, so the outer WHERE throws away all 88 real subscribers. The report comes back empty for every channel. That is the P5 bug.

We proved both versions on the loaded database:

| Version | Rows returned | Verdict |
|---|---:|---|
| R13 as written (`NOT IN`) | **0** | wrong, silently, for every channel |
| R13 rewritten (`NOT EXISTS`) | **88** | the true answer for channel 217 |

**The fix** is to ask the question row by row instead of set membership:

```sql
AND NOT EXISTS (SELECT 1
                FROM watch_events w JOIN videos v ON v.video_id = w.video_id
                WHERE v.channel_id = 217 AND w.user_id = s.user_id);
```

`NOT EXISTS` checks each subscription against the watch events with a normal equality (`w.user_id = s.user_id`). A NULL user_id simply never equals anything, so it is skipped, which is what the business means: "this subscriber has no watch event on record".

**Why we call this the most important find of the project:** a report that always lies becomes a report that tells the truth. The brief says finding this query is worth marks. It also explains a user-visible bug (P5) that no amount of indexing could ever fix. If we had only benchmarked, we would never have noticed: the query runs "successfully", it just answers the wrong thing.

## 2. The 17 indexes, each with its reason

First, the one rule we used everywhere for multi-column indexes: **equality columns first, then the sort or range column**. Why: a B-tree index can only be searched by a matching prefix of its columns. Once the search reaches a range column (like a date), it stops narrowing and starts scanning in index order. Putting the sort column last means the index's own order matches the query's ORDER BY, so no separate sort step is needed.

Two more tools we used:

- **INCLUDE columns** ride along in the index's leaf pages without being part of the sort key. They let an Index Only Scan return all needed values without visiting the table at all.
- **Partial indexes** (with a WHERE clause) only contain matching rows. They are physically smaller, and the filter is effectively pre-applied.

| # | Index | Serves | Shape and reasoning |
|---|---|---|---|
| 1 | `videos (channel_id, published_at DESC) INCLUDE (video_id, title, duration_sec, view_count) WHERE visibility='PUBLIC'` | R01, R03 | Partial (only PUBLIC rows enter it), covering (all 5 selected columns are in the leaf), and `published_at DESC` last so the index order is already the query's ORDER BY. No sort step needed at all. |
| 2 | `videos USING gin (title gin_trgm_ops) WHERE visibility='PUBLIC'` | R04 | GIN trigram is the only index type that serves `ILIKE '%...%'`, because B-tree can only do prefix matches. At Phase 3 time the benchmark PostgreSQL was the bundled build without contrib extensions, so a DO block noticed the missing pg_trgm and skipped the index (section 8). We compiled the extension in before the Phase 5 large run and measured R04 on this index - see `05_scalability_report.md` section 3. |
| 3 | `watch_events (user_id, started_at DESC) INCLUDE (video_id, watch_seconds)` | R05 | Equality column (user) first, sort column (time) second. The history page reads the first 50 entries of the user's section, already newest first. INCLUDE carries the join key and the projected value, so it is an Index Only Scan. |
| 4 | `videos (published_at) INCLUDE (video_id, channel_id, title) WHERE visibility='SCHEDULED'` | R06, W05 | SCHEDULED is rare, so the partial index is tiny and holds only those rows, ordered by the date the query filters and sorts on. The same predicate serves the publisher's UPDATE (W05): one index, one read plus one write query. |
| 5 | `watch_events (video_id) INCLUDE (user_id, started_at, watch_seconds, traffic_source)` | R08, R09, R10, R11, R16, R17 | The single most-used index: almost every Studio and analytics query probes watch_events by video. Covering, so the aggregates read only the index. It is 12 MB, our largest, and it serves 6 queries. |
| 6 | `watch_events USING brin (started_at)` | R07, R10, R11, R20 | A BRIN (Block Range Index) stores just one summary line, min and max of started_at, per chunk of table pages. It is tiny (24 kB) and works because rows were inserted in time order, so each page chunk covers a narrow time range. Date-range queries can skip whole chunks. At 20x data it stays around 24-30 kB, where a B-tree on the same column would be about 80 MB. |
| 7 | `watch_events (video_id, user_id) INCLUDE (watch_id)` | R13 | After the NOT EXISTS rewrite, the inner check is "does a watch event exist for (this channel's video, this subscriber)?" A two-column equality lookup answers it from the index alone. |
| 8 | `video_reactions (video_id) INCLUDE (reaction, reacted_at)` | R14 | The PK is (user_id, video_id), useless for by-video lookups since video_id is not the leading column. This is the reversed order, plus INCLUDE(reaction), so the per-video LIKE/DISLIKE totals come straight from the index. |
| 9 | `comments (video_id, is_pinned DESC, like_count DESC) INCLUDE (comment_id, user_id, body, created_at) WHERE parent_comment_id IS NULL` | R15 | Partial on top-level comments only (replies never enter it). Column order equals the query's ORDER BY, so LIMIT 11 reads the first 11 entries. No sort, no table visit. |
| 10 | `ad_impressions USING brin (shown_at)` | R16 | Same BRIN-on-time reasoning as #6, for the finance month window. |
| 11 | `ad_impressions (watch_id) INCLUDE (ad_format, revenue_inr, shown_at)` | R25 | The audit joins impressions to watches; watch_id lookups were full scans before. |
| 12 | `channels (monetization_status) INCLUDE (channel_id, handle, subscriber_count) WHERE monetization_status IN ('NOT_ELIGIBLE','ELIGIBLE')` | R17, R19 | A rare-slice partial index for the two statuses the workload filters on. |
| 13 | `videos (channel_id, uploaded_at DESC) INCLUDE (video_id, title, view_count)` | R19, R07, R09, R14, R17 | The channel-to-videos probe in upload-date order. In R19's LATERAL, "latest upload" reads literally one entry per channel. |
| 14 | `videos (video_id) INCLUDE (channel_id, title) WHERE is_made_for_kids` | R18 | Rare flag (7.5% of rows), so the partial index is tiny (48 kB) and lists exactly the videos child-safety needs to check. |
| 15 | `comments (video_id) INCLUDE (comment_id)` | R18 | Turns the EXISTS check into an index-only existence test. |
| 16 | `comments (created_at DESC, comment_id DESC) INCLUDE (video_id, user_id, body)` | R23 | Column order equals the keyset pagination's seek order. INCLUDE carries the projected columns, so a page fetch reads exactly 25 index entries. |
| 17 | `subscriptions (channel_id, subscribed_at) INCLUDE (user_id)` | R24, W04, R13 | The PK is user-first, but several queries go channel-first (Studio monthly counts, the nightly recompute, R13's subscriber list). This gives them a proper targeted read. |

**What we deliberately did not index, and why:** `playlists` and `playlist_items` beyond the PK, because R21 is already optimal (see the baseline doc). No B-tree on `watch_events.started_at`, because BRIN #6 gives the same pruning at about 1/3000th of the size. Nothing for R12 and R22, because they have no WHERE clause for an index to serve (section 8). Nothing extra on `users`, because only R25 touches it and it is the smallest table.

## 3. The 5 rewrites, with plans and proofs

### 3.1 R07 and R20: making the date conditions usable by an index

**Before (R07):** `DATE(w.started_at) BETWEEN '2026-06-01' AND '2026-06-30'`. The function wrapper means every row must be computed, so no index can be used. The plan was a Parallel Seq Scan reading all 200k rows (189k removed).

**After:** `w.started_at >= '2026-06-01' AND w.started_at < '2026-07-01'`.

**Why this gives exactly the same rows:** a timestamp belongs to June 1 through June 30 (as a date) if and only if the raw timestamp is on or after June 1, 00:00 and before July 1, 00:00. The upper bound has to be `< '2026-07-01'`, not `<= '2026-06-30'`, because a raw timestamp of June 30 at 23:59:59 is still June 30 as a date. The half-open range `[June 1, July 1)` matches the DATE() version exactly.

**Proof:** EXCEPT in both directions returns 0 rows; 7 day-rows on both sides (R07). 21.107 -> **0.435 ms** (49 times faster). R20 the same mechanics: 14.855 -> **4.748 ms** (about 3 times; the remaining cost is genuinely aggregating June's 10.9k rows, which the BRIN has already isolated to June's pages).

### 3.2 R13: the correctness fix (section 1) plus performance

The optimized plan runs as bitmap scans on `idx_subscriptions_channel_subscribed` (88 subscribers), `idx_videos_channel_uploaded` (15 videos), and `idx_watch_events_video_user` (existence checks). 28.817 -> **0.530 ms** (54 times faster). And the answer changes from 0 rows (wrong) to 88 rows (right). The EXCEPT proof does not apply to R13, because the original was wrong. The 0 to 88 change is the fix itself, documented in section 1.

### 3.3 R19: correlated subqueries to CROSS JOIN LATERAL (the 315x headline)

**Before (30,450 ms):** for each of the 1,087 ELIGIBLE channels, the two subplans re-scanned `videos` (30k rows, 29,990 removed) and `watch_events` (200k rows x 1,087 loops = 217.4 million row visits, buffer hits 3.58 million). The planner's cost estimate of 14,089,259 units was its way of saying it had no better access path.

**After (96.5 ms):**

```
Nested Loop (actual rows=1087)
  -> Seq Scan on channels c (monetization_status='ELIGIBLE') (rows=1087)      -- 40 pages, fair enough
  -> Result / InitPlan per channel:
       latest upload:  Bitmap Index Scan on idx_videos_channel_uploaded
                       (channel_id = c.channel_id) -> max(uploaded_at)          -- ~10 rows, index-only
       total views:    Bitmap Heap Scan on videos v2 (channel_id) x
                       Bitmap Index Scan on idx_watch_events_video_user
                       (video_id = v2.video_id) -> count(*)                      -- ~65 events per channel
```

The idea of the rewrite: before, each channel's question triggered a full-table scan. After, each channel's question is a targeted index lookup. The channel's ~10 videos come from a short B-tree descent, and each video's ~7 watch events from the covering index. So the total work is roughly 1,087 x (10 + 65) = about 81k index entries, instead of 217.4 million row visits.

**Proof:** EXCEPT both directions 0 rows; 1,087 rows on both sides; same ORDER BY total_views DESC. **30,450.269 -> 96.542 ms, a 315 times improvement.**

### 3.4 R23: OFFSET to keyset pagination

**Before (29.456 ms):** a 60k-row sort that spills 3.6 MB to disk (external merge, work_mem is 4 MB), then OFFSET 30000 throws away 30,025 rows to return 25. Deeper pages cost more and more.

**After:** jump straight to the row at position 30,001, then read the 25 entries at or below it:

```sql
WITH seek AS (SELECT created_at, comment_id FROM comments
              ORDER BY created_at DESC, comment_id DESC OFFSET 30000 LIMIT 1)
SELECT ... FROM comments
WHERE (created_at, comment_id) <= (SELECT created_at, comment_id FROM seek)
ORDER BY created_at DESC, comment_id DESC LIMIT 25;
```

The pair comparison `(a,b) <= (x,y)` compares in order (first created_at, then comment_id as tiebreaker), which is exactly the sort order. So index #16 serves both the seek and the page fetch as pure index order. The plan collapses to an Index Only Scan reading 25 entries. **29.456 -> 6.160 ms (about 5 times).**

The remaining 6 ms is the seek CTE's own one-time OFFSET probe. In the real app it never runs: the seek value is simply the last row of the previous page, kept by the client as cursor state, so fetching a page is one 25-entry index read. For the benchmark we compute it once with the offset probe above. The brief asks how "last seen" is chosen on the large dataset: the answer is page N+1 starts from page N's last `(created_at, comment_id)`, held by the app. No OFFSET anywhere in normal operation.

**Proof:** EXCEPT both directions 0 rows, 25 rows both sides. One detail worth knowing: the seek row (position 30,001) must be *included* in the page, so the comparison is `<=`, not `<`. Our first draft used `<` and the proof caught a one-row shift between old and new page 1,201. That is exactly why the proof protocol exists.

### 3.5 R20: same date rewrite as R07

14.855 -> **4.748 ms**, 30 rows, EXCEPT 0 both ways. The window function `sum(hours) OVER (ORDER BY day)` runs over 30 grouped rows and costs nothing either way. All the gain came from the scan underneath it.

## 4. Before/after table (all 30 queries)

| Query | Before (ms) | Problem in the baseline plan | What we did | After (ms) | Improvement | Same result? |
|---|---:|---|---|---:|---:|:---:|
| R01 | 3.505 | Seq Scan 30k videos, 29,988 removed, Sort for LIMIT | idx #1 partial covering | 0.113 | 97% (31x) | yes |
| R02 | 0.060 | none (already PK lookups) | nothing needed | 0.044 | 27% | yes |
| R03 | 5.188 | per-channel Seq Scan of videos | idx #1 shared | 0.386 | 93% (13x) | yes |
| R04 | 16.964 | ILIKE '%...%' infix match | GIN trigram (index #2); extension missing at Phase 3, so the seed run kept its Seq Scan (section 8) - pg_trgm was compiled in afterwards and the Phase 5 large run uses the index (05_scalability_report section 3) | 18.283 | none at Phase 3 (see section 8) | yes |
| R05 | 10.344 | 16 MB scan for 4 rows, parallel worker hired | idx #3 covering | 0.114 | 99% (91x) | yes |
| R06 | 3.101 | rare SCHEDULED, no index | idx #4 partial | 0.129 | 96% (24x) | yes |
| R07 | 21.107 | DATE() not sargable, full 200k scan | rewrite to sargable range + idx #6 BRIN + #13 | 0.435 | 98% (49x) | yes, EXCEPT=0 |
| R08 | 8.369 | 97 rows found in a 200k scan | idx #5 covering | 0.148 | 98% (57x) | yes |
| R09 | 17.175 | double Seq Scan (channel side + video side) | idx #13 + #5 | 0.457 | 97% (38x) | yes |
| R10 | 16.737 | 7-day window, no time index | idx #6 BRIN + #5 | 5.763 | 66% (3x) | yes |
| R11 | 33.773 | full June aggregate + RANK window | idx #6 BRIN (+ #5); the June share remains (section 8) | 24.732 | 27% | yes |
| R12 | 23.526 | unfiltered GROUP BY (no WHERE) | nothing possible (section 8) | 28.839 | none (see section 8) | yes |
| R13 | 28.817 | **wrong answer** (NOT IN + NULL) plus scans | rewrite to NOT EXISTS + idx #17, #7 | 0.530 | 98% (54x) | yes: 0 -> 88 rows (the fix) |
| R14 | 18.324 | reactions PK is user-first | idx #8 covering | 0.321 | 98% (57x) | yes |
| R15 | 5.088 | 60k scan + Sort | idx #9 partial, order-matched | 0.072 | 99% (71x) | yes |
| R16 | 25.382 | no time index on impressions | idx #10 BRIN + #11 + #5 | 23.991 | 5% | yes |
| R17 | 31.502 | three unindexed tables | idx #12 + #13 + #5; the HAVING share remains | 30.756 | 2% | yes |
| R18 | 22.632 | rare flag + EXISTS probe scans | idx #14 + #15 | 2.245 | 90% (10x) | yes |
| R19 | 30450.269 | 2 correlated subplans x 1087 channels | rewrite to LATERAL + idx #12, #13, #5 | 96.542 | **100% (315x)** | yes, EXCEPT=0, 1087 rows |
| R20 | 14.855 | ::date not sargable | rewrite to sargable + BRIN #6 | 4.748 | 68% (3x) | yes, EXCEPT=0 |
| R21 | 0.162 | none (composite PK design paying off) | nothing needed | 0.141 | 13% | yes |
| R22 | 32.635 | unfilterable duplicate detection | nothing possible (section 8) | 32.495 | none (see section 8) | yes |
| R23 | 29.456 | disk-spill sort + OFFSET 30000 | rewrite to keyset + idx #16 | 6.160 | 79% (5x) | yes, EXCEPT=0, 25 rows |
| R24 | 1.885 | non-leading PK column (full index walk) | idx #17 channel-first | 0.225 | 88% (8x) | yes |
| R25 | 95.075 | three full scans for 181 rows | idx #11 + #5; users scan is small | 87.778 | 8% | yes |
| W01 | 0.726 | single-row INSERT | nothing (measures index overhead) | 0.786 | +8% (section 6) | yes |
| W02 | 0.844 | single-row INSERT | nothing (measures index overhead) | 1.035 | +23% (section 6) | yes |
| W03 | 0.412 | PK probe + row update | nothing needed | 0.377 | 8% | yes |
| W04 | 65.197 | aggregate all subscriptions (unavoidable) | idx #17 index-only aggregate | 53.674 | 18% | yes |
| W05 | 4.754 | Seq Scan for rare SCHEDULED | idx #4 (shared with R06) | 0.548 | 88% (9x) | yes |
| **Total** | **30987.864** | | | **421.867** | **98.6% (73x)** | |

## 5. The biggest improvements, plan by plan

### 5.1 R19: 30,450.269 -> 96.542 ms (315x)

Before: `Seq Scan on channels ... SubPlan 1 (Seq Scan videos, loops=1087) ... SubPlan 2 (Seq Scan watch_events rows=200000 loops=1087), Buffers: shared hit=3582826`, which is 217.4 million row visits. (The full plan is in `benchmarks/results/baseline/R19.txt`, walked line by line in the baseline doc's R19 section.)

After: `Nested Loop -> (Seq Scan channels, 1087 rows, 40 buffers) -> Bitmap Index Scan idx_videos_channel_uploaded (channel_id = c.channel_id, ~10 rows, loops=1087) x Bitmap Index Scan idx_watch_events_video_user (video_id, ~7 rows, loops=10500)`. Every per-channel fact now comes from an index descent. Total buffers: 119,794 versus 3,582,826 before, about 30 times fewer page touches, and about 2,700 times fewer row visits.

### 5.2 R05: 10.344 -> 0.114 ms (91x)

Before: `Parallel Seq Scan on watch_events (Rows Removed: 99998 per worker; Buffers: read=2000)`, plus a hired worker, for 4 rows.

After: `Bitmap Index Scan on idx_watch_events_user_started (user_id = 1042) -> 4 rows in 3 index pages -> Index Scan videos_pkey x 4`. Buffers total: 22. The planner no longer hires a worker. There is nothing left worth parallelizing in a 3-page read.

### 5.3 R15: 5.088 -> 0.072 ms (71x)

Before: Seq Scan of 60k comments plus an in-memory Sort.

After: `Index Only Scan using idx_comments_video_top`. The partial index (top-level comments only) has about 30k entries. The video lookup lands directly at that video's ~11 entries, already in (pinned, likes) order. The table is never touched and the Sort node is gone.

### 5.4 R01: 3.505 -> 0.113 ms (31x)

Before: 648 pages read, 29,988 rows filtered away, a quicksort for the LIMIT.

After: `Bitmap Index Scan idx_videos_channel_published_public (Index Cond: channel_id = 217) -> Bitmap Heap Scan, Heap Blocks: exact=12, Buffers: shared read=15`. 648 pages down to 15, about 43 times fewer. Why a Bitmap Heap Scan and not Index Only: the INCLUDE columns make it *nearly* index-only, but PostgreSQL still double-checks row visibility on 12 table pages when they are cold. On warm runs those become `hit=` and the read count drops further.

### 5.5 R13: 28.817 -> 0.530 ms (54x), and the answer becomes correct

Covered in section 1 and 3.2. The result set changed from 0 rows (wrong) to 88 rows (right). The 54x speedup matters less than that.

## 6. Write overhead: what the 17 indexes cost on writes

Every index adds one more entry to write on every INSERT or UPDATE of that table. We measured each write before and after:

| Query | Before (ms) | After (ms) | Change | Where the change comes from | Acceptable? |
|---|---:|---:|---|---|---|
| W01 (INSERT videos) | 0.726 | 0.786 | **+8%** | videos gained tuning indexes #1, #4, #13, #14; each adds one descent plus one leaf write | yes, still under 1 ms |
| W02 (INSERT watch_events) | 0.844 | 1.035 | **+23%** | watch_events gained 4 indexes (#3, #5, #6 BRIN, #7). The BRIN is nearly free (one summary update). The 3 B-trees are the cost | yes, about 1 ms for the platform's highest-volume write |
| W03 (UPDATE videos view_count) | 0.412 | 0.377 | -8% | view_count sits in the INCLUDE of #1, but non-key INCLUDE columns do not force index updates here; measured difference is noise | yes |
| W04 (UPDATE all channels) | 65.197 | 53.674 | **-18%** | the GROUP BY now runs as an Index Only Scan over #17 instead of hashing a 129k-row table scan | yes, faster |
| W05 (UPDATE scheduled to public) | 4.754 | 0.548 | **-88%** | partial index #4 finds the SCHEDULED rows without scanning videos | yes, faster |

**How we answer "which writes got slower":** W01 and W02, by 8% and 23%. Both are sub-millisecond either way, and both are single-row operations, so the absolute cost is tiny. In exchange, W02's table carries the indexes that make six read queries (R05, R08, R09, R10, R11, R16, R17) between 3 and 91 times faster. That is a trade basically every transactional system makes willingly. Two writes (W04, W05) actually got faster, because their own reads were index-shaped.

## 7. Index storage: what the indexes cost in disk space

Measured with `pg_relation_size` (the generation log in `benchmarks/results/optimized/` has the full inventory):

| Table | Table size | Tuning indexes (sizes) | Index overhead relative to table |
|---|---:|---|---:|
| watch_events | 16 MB | #3 9.7 MB, #5 12 MB, #7 7.9 MB, #6 BRIN 24 kB | about 1.85x |
| comments | 5.2 MB | #9 4.2 MB, #16 4.3 MB, #15 1.9 MB | about 2.0x |
| videos | 5.2 MB | #1 2.4 MB, #13 2.5 MB, #4 16 kB, #14 48 kB | about 0.95x |
| subscriptions | 7.4 MB | #17 5.1 MB | about 0.7x |
| ad_impressions | 3.5 MB | #11 2.8 MB, #10 BRIN 24 kB | about 0.8x |
| video_reactions | 4.1 MB | #8 3.3 MB | about 0.8x |
| channels | 1.6 MB | #12 0.9 MB | about 0.6x |

**Totals: 65 MB of tables, 56 MB of tuning indexes.** Two things worth pointing out:

1. The partial and BRIN indexes are nearly free. #4 is 16 kB, #14 is 48 kB, both BRINs are 24 kB each. Yet #4 alone made R06 24x and W05 9x faster. Best value in the whole file.
2. The two big B-trees on watch_events (#5 at 12 MB, #3 at 9.7 MB) are the expensive ones. They are justified because watch_events is probed by six queries. At 20x scale, B-trees only grow in leaf pages; the root and internal levels stay about 3 deep, so lookups do not slow down. The BRINs stay around 24-30 kB. The scalability report tracks exactly these numbers.

## 8. Queries we could not make faster, and exactly why

| Query | Why no index helps |
|---|---|
| R12 | `GROUP BY device` over all 200k rows. There is no WHERE clause, so there is nothing for an index to narrow. Counting every row requires visiting every row. The Seq Scan is already the best plan. The real fix is a nightly summary table or materialized view, which is a Phase 5 architecture idea (scalability report section 5.4). |
| R22 | Duplicate detection groups every video by (title, duration_sec). Same logic as R12: no filter, full read is inherent. An index-only scan would save some I/O but still read all 30k entries. |
| R11 (24.7 ms remaining) | June is a fixed share, about 5.5%, of an 18-month table. BRIN #6 removes the other 17 months, but June's 10.9k events all have to be read, grouped, and ranked, because the answer depends on every one of them. |
| R17 (30.8 ms remaining) | The HAVING watch-hours total must see every NOT_ELIGIBLE channel's full watch history. Same fixed-share logic, over a rarer slice. |
| R25 (87.8 ms remaining) | The audit's 181 violations are deliberately rare in 257k rows across three tables. The planner correctly judges that residual scanning is cheaper than 200k individual index probes. We expect it to improve relatively on the large dataset, where index probes pay off better. |
| R04 | `ILIKE '%tutorial%'` needs pg_trgm (GIN trigram). At Phase 3 the extension was missing from this benchmark PostgreSQL (the bundled build ships without contrib), so the guarded CREATE EXTENSION skipped and R04 kept its Seq Scan. On any standard install, `CREATE EXTENSION pg_trgm` is one line and index #2 activates. We chose to write this down rather than pretend it does not exist. Update, 23 Nov: we compiled pg_trgm 1.6 from the PostgreSQL 16.2 sources into the bundled server and built index #2; the large-data R04 now runs the GIN bitmap plan at 61.229 ms, 3.9x faster than the Seq-Scan fallback (`05_scalability_report.md`, section 3). The seed-side 18.283 ms in the table above stays as originally measured, extension absent. |

## 9. How we proved "same result" (reproducibly)

For every rewrite we ran this on the loaded database:

```
WITH orig AS (...original query...), opt AS (...rewritten query...)
SELECT 'orig_minus_opt', count(*) FROM (SELECT * FROM orig EXCEPT SELECT * FROM opt) t
UNION ALL SELECT 'opt_minus_orig', count(*) FROM (...reverse...) t
UNION ALL SELECT 'orig_count', count(*) FROM orig
UNION ALL SELECT 'opt_count', count(*) FROM opt;
```

The idea: if the two result sets are identical, then subtracting each from the other gives 0 rows both ways, and the counts match.

Results: **R07** 0/0/7/7. **R19** 0/0/1087/1087. **R20** 0/0/30/30. **R23** 0/0/25/25 (after the `<=` boundary fix; the first draft's `<` gave 1/1 and the proof caught the off-by-one). **R13** is the documented exception: 0 rows to 88 rows, because the original was wrong (section 1).

For the 25 untouched queries, the SQL text is identical, so no proof is needed beyond comparing the files (they are diff-able in the repo).

**Reproduce everything:** `psql -d youtube -f sql/01_schema.sql && psql -d youtube -f sql/02_load_data.sql && ./benchmarks/run_benchmark.sh youtube baseline 3`, then `psql -d youtube -f sql/05_indexes.sql && ./benchmarks/run_benchmark.sh youtube optimized 5 sql/06_optimized_queries.sql`.

## 10. Summary

- **Total: 30,987.864 -> 421.867 ms, 98.6% faster (73x),** with identical results on every rewritten query and one query (R13) changed from silently wrong to correct.
- One structural rewrite (R19 LATERAL) contributed 30.3 s of the 30.5 S saved. The 17 indexes carried the 20-95 ms tier toward the per-group targets that matter on the large dataset.
- The costs are accounted for: +8% and +23% on two sub-millisecond writes, and 56 MB of index storage. Both documented per the brief's questions.
- Three queries cannot be fixed by indexing (R12, R22, plus the fixed-share remains in R11 and R17), each with the reason explained, which the brief explicitly asks for.

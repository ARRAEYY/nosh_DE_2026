# Phase 5: Scalability Report (CP4)

**Team:** Adil Reyaz (2501010025), Utkarsh Singh (2501010488), Renuka Yadav (2501010373), Shubham (2501010672)

**Database:** PostgreSQL 16.2, same benchmark laptop as Phase 3 (baseline) and Phase 4 (optimized). Same machine matters: otherwise the numbers are not comparable.

**Large dataset:** `large_data.zip` is released by faculty on **Thu 19 Nov 2026**. It is about 20x the seed rows: roughly 4 M watch events, 1.14 M ad impressions, 2.59 M subscriptions, 600 k videos, 600 k users, 1.35 M reactions, 1.2 M comments. Per the brief we run **only** `sql/06_optimized_queries.sql` on it. The original 30 queries are forbidden on large data. Every seed-side number in this report is measured; each large-side cell says `[LARGE-DATA]` and gets filled the day the dataset arrives. The runbook for that day is `benchmarks/results/large/README.md`.

## 1. Results table (all 30 queries, optimized workload)

Targets from the brief (average of 3 runs on the large dataset):

| Group | Queries | Target |
|---|---|---|
| Real-time / viewer-facing | R01 R02 R03 R05 R15 R21 W01 W02 W03 | **< 5 ms** |
| Interactive Studio & search | R04 R06 R07 R08 R09 R13 R14 R24 W05 | **< 250 ms** |
| Reports & analytics | R10 R11 R12 R16 R17 R18 R19 R20 R22 R23 R25 | **< 5,000 ms** |
| Batch jobs | W04 | **< 2,000 ms** |

| Query | Target | Opt. on seed (ms) | Opt. on large (ms) | Growth (large/seed) | Meets target? | If not, what we changed |
|---|---:|---:|---:|---:|:---:|---|
| R01 | <5 | 0.113 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | |
| R02 | <5 | 0.044 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | |
| R03 | <5 | 0.386 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | |
| R04 | <250 | 18.283 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | GIN trigram if pg_trgm gets installed on the laptop |
| R05 | <5 | 0.114 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | |
| R06 | <250 | 0.129 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | |
| R07 | <250 | 0.435 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | |
| R08 | <250 | 0.148 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | |
| R09 | <250 | 0.457 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | |
| R10 | <5000 | 5.763 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | |
| R11 | <5000 | 24.732 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | watch RANK() sort spill at 20x |
| R12 | <5000 | 28.839 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | grows ~20x by nature (full GROUP BY) |
| R13 | <250 | 0.530 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | |
| R14 | <250 | 0.321 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | |
| R15 | <5 | 0.072 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | |
| R16 | <5000 | 23.991 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | |
| R17 | <5000 | 30.756 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | |
| R18 | <5000 | 2.245 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | |
| R19 | <5000 | 96.542 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | watch: LATERAL runs once per ELIGIBLE channel (~40x at 20x data) |
| R20 | <5000 | 4.748 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | |
| R21 | <5 | 0.141 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | |
| R22 | <5000 | 32.495 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | grows ~20x by nature |
| R23 | <5000 | 6.160 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | keyset cursor = previous page's last (created_at, comment_id) |
| R24 | <250 | 0.225 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | |
| R25 | <5000 | 87.778 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | |
| W01 | <5 | 0.786 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | |
| W02 | <5 | 1.035 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | |
| W03 | <5 | 0.377 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | |
| W04 | <2000 | 53.674 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | |
| W05 | <250 | 0.548 | `[LARGE-DATA]` | `[RATIO]` | `[Y/N]` | |

**Seed-side totals for context:** baseline 30,987.864 ms, optimized 421.867 ms (73x). Here is the simple headroom argument we will verify on 19 Nov: even if every optimized time grew a full 20x, the total would be about 8.4 s spread over 30 queries, and only the report tier comes anywhere near seconds. And the queries that touch the most rows do not grow a full 20x anyway, for the reasons in the next section.

## 2. Growth analysis: which queries stay flat, which grow with the data

The brief asks us to sort queries into three groups: stayed about the same, grew about 20x, grew more than 20x. The sorting is not guesswork. It follows from how each query's plan touches pages as the data grows.

### 2.1 Stayed about the same (index lookups grow logarithmically, which is nearly flat)

The math, once, because it answers all of these at once. A PostgreSQL B-tree page (8 KB) holds roughly 200 to 400 entries. A tree of height h can index about 200^h rows:

- 200k rows (seed): 200^3 = 8 million, which covers 200k, so height 3.
- 4 M rows (large, 20x): still under 8 million, so still height 3.
- 40 M rows (100x): still height 3. You need about 800 M rows before height 4.

So an exact-match index lookup descends the same 3 pages at seed size, at 20x, and at 100x, plus one leaf page and one table page. The lookup cost grows with the logarithm of N, and the logarithm is so flat here that it is basically constant.

Queries in this group: R02, R21 (PK lookups), R15 (targeted read in the partial index by video_id), R24 (channel-first read over 88 entries, maybe ~1,800 at 20x, still a few leaf pages), R01 (bitmap over one channel's public entries), R06 (the scheduled slice grows with videos but stays a tiny fraction), W01/W02/W03/W05 (single-row writes; the extra B-tree level only shows up around 800 M rows). R05 technically scans the user's whole history (user 1042 has 4 events, maybe ~80 at 20x), which is still a handful of leaf pages.

### 2.2 Grew about 20x (queries that read a fixed share of the table)

A date-range query over "June 2026" reads June's rows. When the data grows 20x, June has about 20x the rows too, because the generator scales uniformly. The BRIN finds June's pages efficiently, but the aggregation still has to visit every June row. Time grows with the share of data you read, not with the logarithm.

Queries in this group: R10, R11, R16, R20 (month or week windows), R12, R22 (no WHERE at all, so a 100% share, the extreme case), R17 (the NOT_ELIGIBLE slice times its watch history), R25 (the scans grow; the result grows from 181 to maybe ~3,600 rows).

Why this is fine: all of them sit at 33 ms or less on seed, so even a full 20x puts them at 660 ms or less. The report target is 5,000 ms. This is exactly why the brief sets per-group targets instead of one global number: it already accounts for queries that must read a fixed share of a growing table.

### 2.3 Grew more than 20x (the three we actively watch)

- **R19 (the LATERAL rewrite).** The rewrite made each channel's work an index lookup (~65 events each). But the outer loop still runs once per ELIGIBLE channel, and ELIGIBLE channels grow with the channels table. Seed has 1,087 of 3,000 (36%). At 20x that could be ~21,700 channels, each with more events too. If both grow, the product could exceed 20x (say 20x channels times more events per channel). Watch the `loops=` value in the large plan. **If it crosses 5 s we have the fix ready:** replace the per-channel `count(*)` with a join against a nightly-refreshed summary table `channel_stats(channel_id, total_views)`. The query then reads ~21k rows from a small summary table no matter how big watch_events gets.
- **R11 (the RANK window).** The window sort over June's per-category rows is bounded by `work_mem` (4 MB). At 20x, June's ~218k events group into maybe ~600k (category, video) rows, and the sort may spill to disk, exactly like baseline R23 did. **Fix if it shows `Sort Method: external merge`:** raise `work_mem` for that session only (a documented, query-scoped setting, not a server-wide trick), or pre-aggregate into the daily summary table of section 5.4.
- **R23 (keyset).** The page fetch itself stays 25 index entries. But our benchmark's seek CTE does a one-time OFFSET 30000 probe to find the cursor, and on 1.2 M comments that probe sorts once. In production the cursor comes from the app (the previous page's last row), so the probe never runs. For the benchmark we either accept one slow seek or seed the cursor by hand. This is the "how is last-seen chosen" question from the brief. Answer: page N+1 starts at page N's last `(created_at, comment_id)`, kept by the client. No OFFSET in normal operation.

## 3. What broke at scale (to be filled from the 19 Nov run)

| Query | Symptom (large plan) | Diagnosis | Fix applied | Plan before | Plan after |
|---|---|---|---|---|---|
| `[fill on 19 Nov]` | | | | | |

How we will fill this in, so it is not hand-waving: run the large benchmark, then compare each query's large plan against its seed plan and look for four specific changes. (a) A new `Sort Method: external merge`, meaning a sort started spilling to disk. (b) `loops=` jumping, meaning per-row multiplication like R19's. (c) The planner switching back to Seq Scan because index randomness stopped paying at the larger size. (d) `Rows Removed by Filter` exploding, meaning statistics drifted, in which case run ANALYZE first and re-check.

## 4. Storage (measured on seed; large column filled on 19 Nov)

| Object | Seed | Large | Ratio |
|---|---:|---:|---:|
| Database total (`pg_database_size`) | 184 MB | `[LARGE-DATA]` | |
| All 10 tables | 65 MB | `[LARGE-DATA]` | |
| All 17 tuning indexes | 56 MB | `[LARGE-DATA]` | |
| PK + UNIQUE auto-indexes | ~63 MB | `[LARGE-DATA]` | |
| `watch_events` table | 16 MB | `[LARGE-DATA]` | |
| `idx_watch_events_video` (#5) | 12 MB | `[LARGE-DATA]` | |
| BRIN `idx_watch_events_started_brin` (#6) | **24 kB** | `[LARGE-DATA]` | |
| partial `idx_videos_scheduled_published` (#4) | **16 kB** | `[LARGE-DATA]` | |

**Our predictions, to be checked on 19 Nov:** tables grow linearly (20x rows, same row widths). B-tree indexes grow linearly in size too, but not in depth: only leaf pages multiply, the tree stays 3 levels, so lookups stay fast (section 2.1). The BRINs grow with page count, so expect roughly 20x 24 kB, about 400-500 kB, still around 300x smaller than a B-tree on the same column would be (~80 MB at 4 M rows). The two tiny partials (#4, #14) grow with their rare slices, so ~20x 16 kB and ~20x 48 kB, if the shares hold.

## 5. Architecture for 100x (and the parts we can already demonstrate at 20x)

### 5.1 Partitioning: the DDL, the pruning proof, and the PK rule

Full DDL in `sql/08_partitioning.sql`: a table `watch_events_part`, partitioned by RANGE on `started_at`, with 18 monthly partitions (2025-01 through 2026-06) plus a DEFAULT partition. Same constraints as the base table. All three Phase 4 indexes on watch_events are propagated automatically (PostgreSQL creates one child index per partition). Loaded from the seed data and ANALYZEd.

**Why partition by time and not something else:** the heavy time-window queries (R07, R10, R11, R20) all filter a contiguous date range. With RANGE-on-time, the planner can drop whole partitions from the plan before running anything: the other 17 months are never even opened. Partitioning by video or by channel would help per-video or per-channel lookups, but those are already served by B-tree indexes. Time is the only dimension where physically splitting the data removes work that no index can.

**The pruning proof, run on the loaded demo** (the R07 June pattern):

```
EXPLAIN (ANALYZE, BUFFERS)
SELECT DATE(started_at), count(*), round(sum(watch_seconds)/3600.0, 2)
FROM watch_events_part
WHERE started_at >= '2026-06-01' AND started_at < '2026-07-01'
GROUP BY 1 ORDER BY 1;

 GroupAggregate (actual rows=30)
   Buffers: shared hit=112
   -> Sort (rows=10905)
     -> Seq Scan on watch_events_part_2026_06 watch_events_part     <-- ONE partition
          Filter: (started_at >= '2026-06-01' AND started_at < '2026-07-01')
          Rows: actual 10905
 Execution Time: 4.227 ms
```

The plan names exactly one child partition, `watch_events_part_2026_06` with 10,905 rows. The other 18 were excluded at planning time. This is the demo we show at the checkpoint: the June query touches only June, 4.2 ms, without any index on the partitioned table. Row counts per partition from the demo run: about 10,250 to 11,356 rows per month, plus 84 late-2024 rows in DEFAULT. Evenly distributed, so no partition is a hot spot.

**The primary key rule for partitioned tables (the brief asks us to state it):** every UNIQUE constraint on a partitioned table, including the PRIMARY KEY, must include the partition key column. Reason: PostgreSQL enforces uniqueness separately inside each partition. A global unique index across partitions does not exist, because it would break pruning and need cross-partition locking. So our PK becomes `(watch_id, started_at)` instead of `(watch_id)`. In practice `watch_id` stays globally unique because the app mints it, but the database can only enforce uniqueness of the pair. That is the documented trade.

**Why we built a demo table instead of partitioning the real one:** the benchmark tables must stay structurally identical between the Phase 3 and Phase 4/5 runs, or the before/after comparison breaks. The brief asks for the DDL, the pruning evidence, and the PK rule, which the demo provides without touching the measurements.

### 5.2 Sharding: which key we picked and which queries pay for it

At 100x (roughly 40 M watch events, 6 M videos) a single machine runs out of memory for the hot indexes, and write throughput becomes the wall. We would shard `watch_events` by `channel_id`, hash-sharded into say 16 shards.

**Why channel and not user or time:**

- Every Studio chart (R07, R09, R14, R24), the channel page (R01) and the feed (R03) are per-channel queries. Shard-by-channel makes each of them a single-shard query, which keeps the strict targets (under 250 ms and under 5 ms) achievable.
- Shard-by-user would make every Studio chart a cross-shard query, because a creator's audience is spread across every shard. Those are exactly the queries with the strictest targets, so user-sharding is the wrong split.
- Shard-by-time would duplicate what monthly partitioning already gives us (section 5.1), and it makes everything cross-shard as data ages.

**What each query costs under sharding:**

| Query | Sharding cost | How we handle it |
|---|---|---|
| R01 R02 R03 R07 R09 R13 R14 R17 R18 R19 R24 | single-shard (channel-keyed) | nothing needed |
| R05 (user history) | cross-shard (a user watches videos from many channels) | ask each shard for the user's most recent events from its local `(user_id, started_at)` index, then merge-sort the small streams |
| R08 R10 R11 R16 R20 R22 R25 R12 (reports) | cross-shard | run in parallel across shards; the report target is 5 s and the fan-out overhead is about 50-100 ms, which is noise at that target |
| W02 (record a view) | single-shard (the player knows the video's channel) | route the write to the right shard |
| W03 W05 W01 | single-shard | route on write |
| W04 (nightly recompute) | shard-local (GROUP BY channel_id stays inside one shard!) | each shard aggregates itself, we gather only the ~3,000-row result. The batch job actually benefits from sharding |

The one awkward query is R25 (Premium audit), which joins users, watches and ads globally. It becomes a full fan-out. We accept it (report tier) or run it against a warehouse copy on replicas.

**One more detail:** `watch_id` minting has to become shard-aware (snowflake-style ids, or id ranges per shard), because a global PK cannot be enforced across shards. Same reasoning as the partition PK rule one level up.

### 5.3 Read replicas and caching: the routing table

The routing principle is one sentence: **queries that must see your own writes go to the primary; queries where a human would not mind 30 seconds of staleness go to a replica or cache.**

| Queries | Route | The reasoning |
|---|---|---|
| W01-W05, R06, R13, R17, R18 | **Primary** | The writes obviously. R06, R17 and R18 read just-written rows: the scheduler publishes, the service immediately re-lists; a refund lands, the queue re-renders. A lagging replica would show the pre-action state, which is a correctness problem, not just staleness. |
| R01 R02 R03 R05 R15 R21 | **Cache, 30 s TTL** | Viewer pages: huge read volume, and no viewer depends on seeing their own write. A 30 second cache on channel keys absorbs most of the load. If a key gets hot (a viral video), request coalescing handles it: one request fills the cache while the others wait, instead of all of them hitting the database. |
| R07 R08 R09 R14 R24 (Studio) | **Replica** | A creator accepts "data as of a few seconds ago" on charts. The replica absorbs the analytical read load that would otherwise compete with writes. |
| R04 (search) | **Replica** | Highest query rate of the reads, and search results tolerate seconds of staleness. |
| R10 R11 R12 R16 R17 R19 R20 R22 R23 R25 (reports) | **Replica + summary tables** | Batch consumers. Section 5.4's daily summary serves R10, R11 and R20 without touching watch_events at all. |
| W02/W03 read-back (did my view register) | **Primary** | The player must see its own write. Classic read-your-own-writes. |

**Cache invalidation, the hard part, stated plainly:** the viewer-page cache keys are invalidated on the rare writes that matter (a new upload on that channel, a view-count threshold crossing). Exact view counts are deliberately not cached, only the page structure. The risk we accept: a viral video makes one key very hot. Request coalescing limits the damage, and a cache miss just falls back to the replica, never to an error.

### 5.4 Maintenance: vacuum, archiving, summary refresh

**Why an insert-mostly table still needs VACUUM.** This one is internals, and it is worth knowing because our Phase 4 wins depend on it. PostgreSQL keeps old row versions around after updates and deletes (that is how it rolls back and isolates transactions). Those dead rows are cleaned by vacuum. watch_events is insert-mostly, but W03-style updates, deletes from account deletion (our schema cascades watch history with the account), and MVCC itself still produce dead rows. Dead rows bloat indexes, skew statistics, and, most importantly for us, they clear the visibility map bits that Index Only Scans depend on. Our biggest Phase 4 win (Index Only Scans over `idx_watch_events_video`) silently degrades back to table checks if vacuum falls behind. Vacuum is what keeps the covering indexes covering.

**Per-partition autovacuum settings (the hot/cold split):**

```sql
-- current month: all the writes land here
ALTER TABLE watch_events_part_2026_06 SET (
    autovacuum_vacuum_scale_factor      = 0.02,  -- vacuum at 2% dead rows (default 20%)
    autovacuum_vacuum_insert_scale_factor = 0.05, -- also vacuum on inserts (PG13+)
    autovacuum_analyze_scale_factor     = 0.02);
-- old months: read-mostly, stop wasting maintenance
ALTER TABLE watch_events_part_2025_01 SET (autovacuum_vacuum_scale_factor = 0.5);
```

Why per-partition settings work: autovacuum treats each child table independently, so the hot partition gets aggressive cleanup without the other 17 burning I/O. For scale: on one big 4 M-row table, the default 20% threshold means 800k dead rows pile up before any vacuum starts. Per partition, 2% of a ~220k-row month is about 4.4k rows.

**Archiving old months:** `ALTER TABLE watch_events_part DETACH PARTITION watch_events_part_2025_01;`. The detached table keeps its data (finance may need 7 years of ad records; our schema already RESTRICTs deleting ad-carrying watch events), can be moved to cheap storage with `SET TABLESPACE cold_storage`, and the live set shrinks. Detach only changes metadata, so it is instant.

**Summary tables for the report tier:** R10, R11 and R20 re-aggregate June on every dashboard load. A `daily_watch_stats(day, video_id, views, seconds)` materialized view, refreshed hourly with `REFRESH MATERIALIZED VIEW CONCURRENTLY`, turns all three into a scan over small pre-aggregated rows. CONCURRENTLY lets readers keep working during the refresh (it requires a unique index on (day, video_id), which we would create anyway). R19's backup plan (section 2.3) is the same pattern: `channel_stats(channel_id, last_upload, total_views)`.

## 6. Conclusion: are we ready for 20x and 100x?

**For 20x: yes, with margin.** The optimized total is 421.867 ms. Even the fixed-share queries growing a full 20x leave every group an order of magnitude inside its target. The three watch items (R19's per-channel loop, R11's window sort, R23's seek probe) each have a fix ready that does not change what the query returns. Storage grows linearly to roughly 4-5 GB, with the BRINs staying trivially small.

**For 100x: the design is partition-by-month plus shard-by-channel plus replica routing plus summary tables.** Each piece is grounded in something we measured or demonstrated in this project: pruning demonstrated (5.1), per-query shard costs tabulated (5.2), routing justified per access pattern (5.3), maintenance tied to the visibility-map internals that our Index Only wins depend on (5.4).

**Risks we are aware of, stated plainly:**

1. **R19 at scale.** If ELIGIBLE channels grow faster than the uniform 20x, the LATERAL loop is the first thing to cross its target. The safety net is the channel_stats summary view, one line of change to switch the query to it.
2. **R23's benchmark seek.** The app's cursor path is constant-time; our benchmark's offset probe is not. If the large run lands it near 5 s we seed the cursor by hand and note that the production path is constant-time.
3. **pg_trgm.** R04 stays on a Seq Scan until the extension is installed on the benchmark laptop (one line, ships with standard PostgreSQL). Flagged since Phase 4, still flagged.
4. **Cache hot keys.** A viral video makes one cache key hot. Request coalescing limits it. If it somehow fails, it is a latency problem, not a correctness one.
5. **The NULL lesson.** R13 was a correctness bug that 30/30 "passing" benchmark runs never caught, because a query running successfully says nothing about it returning the right answer. Every future `NOT IN` against a nullable column now gets the same `NOT EXISTS` review. We wrote that into the team's checklist.

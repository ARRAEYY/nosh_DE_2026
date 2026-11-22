# Phase 5: Scalability Report (CP4)

**Team:** Adil Reyaz (2501010025), Utkarsh Singh (2501010488), Renuka Yadav (2501010373), Shubham (2501010672)

**Database:** PostgreSQL 16.2, same benchmark laptop as Phase 3 (baseline) and Phase 4 (optimized). Same machine matters: otherwise the numbers are not comparable.

**Large dataset:** faculty released `large_data.zip` - a 247 MB zip holding **12,828,190 data rows**: 4,000,000 watch events, 2,598,598 subscriptions, 1,350,452 video reactions, 1,200,000 comments, 1,139,137 ad impressions, 1,120,003 playlist items, 600,000 videos, 600,000 users, 160,000 playlists, 60,000 channels. Same tables and columns as the seed, about 20x the rows. We fetched it from the project tracker, loaded it into a fresh `youtube_large` database (PostgreSQL 16.2) on **Sun 22 Nov 2026** following the runbook in `benchmarks/results/large/README.md`, and benchmarked the same evening; the professor's class-wide email announcing the release arrived Mon 23 Nov. The same morning we closed the one gap the 22 Nov run left open: the bundled benchmark PostgreSQL ships without contrib extensions, so pg_trgm was missing, index #2 was skipped, and R04 ran its documented Seq-Scan fallback; we compiled the extension in, built the GIN, and re-measured R04 (section 3). Per the brief we ran **only** `sql/06_optimized_queries.sql` on it - the original 30 queries are forbidden on large data. Every number in this report, seed side and large side, is now measured.

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
| R01 | <5 | 0.113 | 0.314 | 2.78x | Y | |
| R02 | <5 | 0.044 | 0.327 | 7.43x | Y | |
| R03 | <5 | 0.386 | 1.530 | 3.96x | Y | |
| R04 | <250 | 18.283 | 61.229 | 3.35x | Y | pg_trgm compiled in on 23 Nov, index #2 built, re-measured 3.9x faster (section 3) |
| R05 | <5 | 0.114 | 0.703 | 6.17x | Y | |
| R06 | <250 | 0.129 | 0.340 | 2.64x | Y | |
| R07 | <250 | 0.435 | 3.741 | 8.60x | Y | |
| R08 | <250 | 0.148 | 0.108 | 0.73x | Y | |
| R09 | <250 | 0.457 | 0.780 | 1.71x | Y | |
| R10 | <5000 | 5.763 | 92.041 | 15.97x | Y | |
| R11 | <5000 | 24.732 | 506.752 | 20.49x | Y | sort spilled 11 MB (section 3); still 10x inside target |
| R12 | <5000 | 28.839 | 578.697 | 20.07x | Y | grows ~20x by nature (full GROUP BY) |
| R13 | <250 | 0.530 | 86.153 | 162.55x | Y | |
| R14 | <250 | 0.321 | 0.972 | 3.03x | Y | |
| R15 | <5 | 0.072 | 0.051 | 0.71x | Y | |
| R16 | <5000 | 23.991 | 834.288 | 34.78x | Y | |
| R17 | <5000 | 30.756 | 492.827 | 16.02x | Y | |
| R18 | <5000 | 2.245 | 27.209 | 12.12x | Y | |
| R19 | <5000 | 96.542 | 1152.175 | 11.93x | Y | loops=20,951 (section 3); 11.9x growth, fix not needed |
| R20 | <5000 | 4.748 | 100.594 | 21.19x | Y | |
| R21 | <5 | 0.141 | 0.577 | 4.09x | Y | |
| R22 | <5000 | 32.495 | 798.461 | 24.57x | Y | grows ~20x by nature |
| R23 | <5000 | 6.160 | 4.588 | 0.74x | Y | keyset cursor = previous page's last (created_at, comment_id) |
| R24 | <250 | 0.225 | 0.277 | 1.23x | Y | |
| R25 | <5000 | 87.778 | 1588.547 | 18.10x | Y | |
| W01 | <5 | 0.786 | 1.191 | 1.52x | Y | |
| W02 | <5 | 1.035 | 1.468 | 1.42x | Y | |
| W03 | <5 | 0.377 | 0.893 | 2.37x | Y | |
| W04 | <2000 | 53.674 | 1255.636 | 23.39x | Y | |
| W05 | <250 | 0.548 | 15.530 | 28.34x | Y | |

**Totals, both sides measured:** baseline 30,987.864 ms, optimized 421.867 ms (73x), large 7,607.999 ms (18.03x over optimized, including the 23 Nov R04 re-measurement). The headroom argument held: a blanket 20x would have cost about 8.4 s, the measured total is 7.6 s, and only the report tier is anywhere near seconds. The queries that touch the most rows grew slightly less than 20x, for the reasons in the next section - with two exceptions explained in section 3: R13, and R04, whose growth is small precisely because its GIN index arrived with the fix.

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

- **R19 (the LATERAL rewrite).** The rewrite made each channel's work an index lookup (~65 events each). But the outer loop still runs once per ELIGIBLE channel, and ELIGIBLE channels grow with the channels table. Seed has 1,087 of 3,000 (36%). At 20x that could be ~21,700 channels, each with more events too. If both grow, the product could exceed 20x (say 20x channels times more events per channel). Watch the `loops=` value in the large plan. **If it crosses 5 s we have the fix ready:** replace the per-channel `count(*)` with a join against a nightly-refreshed summary table `channel_stats(channel_id, total_views)`. The query then reads ~21k rows from a small summary table no matter how big watch_events gets. **Measured at 20x:** 1,152.175 ms, `loops=20951` (20,951 ELIGIBLE channels vs the ~21,700 predicted), inner probe executed 210,373 times - 11.9x growth, still 4.3x inside the 5,000 ms target. The fix stays unused.
- **R11 (the RANK window).** The window sort over June's per-category rows is bounded by `work_mem` (4 MB). At 20x, June's ~218k events group into maybe ~600k (category, video) rows, and the sort may spill to disk, exactly like baseline R23 did. **Fix if it shows `Sort Method: external merge`:** raise `work_mem` for that session only (a documented, query-scoped setting, not a server-wide trick), or pre-aggregate into the daily summary table of section 5.4. **Measured at 20x:** 506.752 ms, 20.5x growth. The spill appeared exactly as predicted (`Sort Method: external merge, Disk: 11296kB` on the ranking sort, plus 2.8-4.9 MB per parallel worker), but even with the spill the query sits 10x inside its target, so `work_mem` stays at the default and the documented fix stays in reserve for 100x.
- **R23 (keyset).** The page fetch itself stays 25 index entries. But our benchmark's seek CTE does a one-time OFFSET 30000 probe to find the cursor, and on 1.2 M comments that probe sorts once. In production the cursor comes from the app (the previous page's last row), so the probe never runs. For the benchmark we either accept one slow seek or seed the cursor by hand. This is the "how is last-seen chosen" question from the brief. Answer: page N+1 starts at page N's last `(created_at, comment_id)`, kept by the client. No OFFSET in normal operation. **Measured at 20x:** 4.588 ms average - slightly faster than seed (6.160 ms). The one-time seek probe read 30,001 entries from the freshly-built, fully all-visible index (`Heap Fetches: 0`, 268 buffer reads), and the keyset page itself stayed a constant 25-entry index read.

## 3. What broke at scale (measured on the 22 Nov run)

**No query crossed its target, so no fix was forced by the numbers.** One fix was applied
anyway - to R04, the query we had flagged longest - and the four planned checks still ran,
because "passed" and "nothing to learn" are not the same thing. Symptoms that did show up,
all inside target:

| Query | Symptom (large plan) | Diagnosis | Fix applied | Plan before | Plan after |
|---|---|---|---|---|---|
| R04 | Parallel Seq Scan, avg 236.653 ms - inside target but with only 5% headroom; 185,364 rows removed per worker by the ILIKE+visibility filter | pg_trgm missing from the bundled benchmark PostgreSQL (it ships without contrib extensions), so the guarded CREATE in `sql/05_indexes.sql` skipped index #2 - flagged since Phase 4 | compiled pg_trgm 1.6 from the PostgreSQL 16.2 source into the bundled server (PGXS), built `idx_videos_title_trgm_public` (19.3 MB, partial on PUBLIC), re-ran R04 3x on 23 Nov | `R04.txt` at commit 47c4008 (Seq Scan) | `R04.txt` (Bitmap Heap + Bitmap Index Scan on the GIN), avg 61.229 ms |
| R11 | `Sort Method: external merge, Disk: 11296kB` on the ranking sort (plus 2.8-4.9 MB per parallel worker) | the predicted `work_mem` (4 MB) spill at 20x June volume | none - 506.752 ms is still 10x inside the 5,000 ms target; session-scoped `work_mem` / summary table (5.4) stay in reserve | `R11.txt` | - |
| R20 | `external merge, Disk: 3856kB` | same window-sort spill, smaller | none - 100.594 ms | `R20.txt` | - |
| R22 | `external merge, Disk: 26072kB` | the full-table GROUP BY sorts 600k rows; predicted "grows ~20x by nature" | none - 798.461 ms of 5,000 ms | `R22.txt` | - |
| R13 | 162x growth (0.530 to 86.153 ms; worst run 236 ms) | cold-cache effect, not a plan regression: the seed DB sat entirely in shared_buffers, at 20x the first run reads 4,792 of 13,129 pages from disk; warm runs are 10-12 ms | none - still 2.9x inside its 250 ms target | `R13.txt` | - |

The four checks we had planned, each with its measured answer. (a) A new `Sort Method: external merge`: appeared in R11, R20 and R22 (table above) - all far inside target, fix stays in reserve. (b) `loops=` jumping: R19's LATERAL ran `loops=20951` (we predicted ~21,700 ELIGIBLE channels; the actual count is 20,951) with the inner watch_events probe executed 210,373 times, about 10 index probes per channel - result 1,152.175 ms, 4.3x inside target, `channel_stats` rewrite unused. (c) The planner switching back to Seq Scan: did not happen - it switched the other way. R17 and R19, which seq-scanned channels/videos on seed, moved to Index Only Scans on `idx_channels_monetization` and `idx_videos_channel_uploaded` at 20x, because index probes pay better once the table outgrows the cache; no query regressed from index to seq. The 23 Nov pg_trgm fix added one more in that direction: R04 moved from Parallel Seq Scan to the GIN bitmap plan, 3.9x faster (61.229 vs 236.653 ms). (d) `Rows Removed by Filter` exploding: the two largest are R25 (278,540 rows removed by the premium join filter - the NOT_ELIGIBLE users, expected) and R04 (185,364 rows removed per worker - non-PUBLIC rows and non-matching titles - while the trigram extension was still missing; since fixed in the table above); neither is statistics drift, and the plans ran on the load-time ANALYZE with row estimates in normal bounds.

## 4. Storage (seed and large both measured; large column from the 22 Nov run)

| Object | Seed | Large | Ratio |
|---|---:|---:|---:|
| Database total (`pg_database_size`) | 184 MB | 2,401 MB | 13.0x |
| All 10 tables | 65 MB | 929.0 MB | 14.3x |
| All 17 tuning indexes | 56 MB | 1,128.0 MB* | 20.1x |
| PK + UNIQUE auto-indexes | ~63 MB | 355.7 MB | ~5.6x |
| `watch_events` table | 16 MB | 310.6 MB | 19.4x |
| `idx_watch_events_video` (#5) | 12 MB | 236.4 MB | 19.7x |
| BRIN `idx_watch_events_started_brin` (#6) | **24 kB** | **56 kB** | 2.3x |
| partial `idx_videos_scheduled_published` (#4) | **16 kB** | **104 kB** | 6.5x |

\*All 17 tuning indexes now exist in the large database. The 22 Nov run measured 16 of 17
(1,108.7 MB): the conditional pg_trgm GIN (`idx_videos_title_trgm_public`, R04) had
been skipped because the bundled benchmark PostgreSQL ships without contrib extensions.
On 23 Nov we compiled pg_trgm into the server and added the missing GIN - 19.3 MB over
526,322 PUBLIC titles - bringing the tuning total to 1,128.0 MB; R04 was re-measured the
same day (section 3).

**Our predictions, checked against the measured numbers above:** the B-trees grew right on
the linear mark (19.4-19.8x) and the section 2.1 depth math held - every exact-match query
stayed flat or got faster. The heap grew 14.3x, sub-linear, because bulk-loaded pages pack
tighter at the larger volume. The BRIN grew to just 56 kB - smaller than even our ~450 kB
guess, because it summarizes page ranges rather than rows - and is now about 5,700x smaller
than the 310.6 MB heap it indexes; a B-tree on `started_at` would have been ~80 MB. The two
tiny partials grew with their rare slices (104 kB for #4, 0.6 MB for #14). The one late
addition: the pg_trgm GIN joined the set on 23 Nov (footnote above), taking R04 from the
tightest margin in the workload - 5% inside target on the Seq Scan - to 4x inside it,
for 19.3 MB or 1.7% of the tuning-index budget. That is exactly the price/performance
trade a trigram index is supposed to cost.

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

**For 20x: measured - yes, with margin.** The optimized total grew from 421.867 ms (seed) to **7,607.999 ms (18.03x)**, under the 8.4 s a blanket 20x would have cost, and every group is inside its target: real-time 7.054 ms summed (worst single query 1.530 ms of 5 ms), interactive 169.130 ms (worst R13 86.153 ms of 250 ms), reports 6,176.179 ms (worst R25 1,588.547 ms of 5,000 ms), batch W04 1,255.636 ms of 2,000 ms. The three watch items behaved as predicted (section 2.3) and none needed its fix. Storage measured 2,401 MB in total, below the 4-5 GB linear guess: the heap packs denser at bulk-load volume and the BRINs stayed trivially small (56 kB).

**For 100x: the design is partition-by-month plus shard-by-channel plus replica routing plus summary tables.** Each piece is grounded in something we measured or demonstrated in this project: pruning demonstrated (5.1), per-query shard costs tabulated (5.2), routing justified per access pattern (5.3), maintenance tied to the visibility-map internals that our Index Only wins depend on (5.4).

**Risks we are aware of, stated plainly:**

1. **R19 at scale.** If ELIGIBLE channels grow faster than the uniform 20x, the LATERAL loop is the first thing to cross its target. The safety net is the channel_stats summary view, one line of change to switch the query to it. Measured: 1,152.175 ms at 20x, 4.3x margin - the safety net was not needed.
2. **R23's benchmark seek.** The app's cursor path is constant-time; our benchmark's offset probe is not. If the large run lands it near 5 s we seed the cursor by hand and note that the production path is constant-time.
3. **pg_trgm - resolved 23 Nov.** Flagged since Phase 4, closed before submission: the extension was compiled into the bundled benchmark PostgreSQL, index #2 was built, and R04 re-measured at 61.229 ms - 3.9x faster than its Seq-Scan fallback and 4x inside the 250 ms target (section 3). The pattern is the part we keep for the viva: the index script degraded honestly (guarded DO block, documented fallback), and the fix was measured, not assumed.
4. **Cache hot keys.** A viral video makes one cache key hot. Request coalescing limits it. If it somehow fails, it is a latency problem, not a correctness one.
5. **The NULL lesson.** R13 was a correctness bug that 30/30 "passing" benchmark runs never caught, because a query running successfully says nothing about it returning the right answer. Every future `NOT IN` against a nullable column now gets the same `NOT EXISTS` review. We wrote that into the team's checklist.

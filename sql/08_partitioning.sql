-- ============================================================================
-- YouTube DBMS - Phase 5 partitioning DDL + pruning demo
-- sql/08_partitioning.sql - CP4 DE
-- Team: Adil Reyaz (2501010025), Utkarsh Singh (2501010488),
--       Renuka Yadav (2501010373), Shubham (2501010672)
--
-- The brief asks for the DDL for `watch_events` partitioned, with an EXPLAIN
-- showing partition pruning, and the note about the primary-key rule for
-- partitioned tables.
--
-- We create a DEMO partitioned table `watch_events_part` (same shape as
-- `watch_events`) so the benchmark tables stay untouched. We RANGE-partition
-- by month on `started_at`, load the seed data into it, and then show that a
-- June-only query prunes to exactly one partition.
--
-- Why RANGE by started_at:
--   * The hottest time-bounded queries (R07, R10, R11, R20) all filter a date
--     range on started_at. RANGE by started_at lets the planner prune every
--     other month at planning time.
--   * watch_events is append-only and naturally clustered by started_at (rows
--     are inserted in watch_id order, which is ~time order), so a per-month
--     RANGE partition is also physically ordered - BRIN stays accurate inside
--     each partition and new data appends into the latest partition cheaply.
--   * By channel or by user would help R05 (history) or R07/R09 (Studio) but
--     would scatter rows across partitions for time-range queries, which are
--     the majority of the workload. Time wins.
--
-- ============================================================================

SET search_path TO youtube;

-- ----------------------------------------------------------------------------
-- 1. The partitioned parent table.
--    PRIMARY KEY rule for partitioned tables: the partition key MUST be part of
--    every unique index, including the PRIMARY KEY. The original watch_events
--    PK is (watch_id) alone. For a RANGE-partitioned table by started_at, the
--    PK must become (watch_id, started_at) so each partition can enforce
--    uniqueness of watch_id within itself. (watch_id alone remains globally
--    unique in practice - the app generates it - but PostgreSQL cannot enforce
--    a cross-partition UNIQUE constraint without the partition key in it.)
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS watch_events_part CASCADE;
CREATE TABLE watch_events_part (
    watch_id       INTEGER      NOT NULL,
    user_id        INTEGER      REFERENCES users (user_id) ON DELETE CASCADE,
    video_id       CHAR(11)     NOT NULL REFERENCES videos (video_id) ON DELETE CASCADE,
    started_at     TIMESTAMPTZ  NOT NULL,
    watch_seconds  INTEGER      NOT NULL,
    device         VARCHAR(10)  NOT NULL,
    traffic_source VARCHAR(15)  NOT NULL,
    PRIMARY KEY (watch_id, started_at),   -- <- partition key in PK (the rule)
    CONSTRAINT wep_watch_seconds_range
        CHECK (watch_seconds BETWEEN 0 AND 86400),
    CONSTRAINT wep_device_valid
        CHECK (device IN ('WEB', 'ANDROID', 'IOS', 'TV')),
    CONSTRAINT wep_traffic_source_valid
        CHECK (traffic_source IN ('HOME', 'SEARCH', 'SUGGESTED', 'SHORTS_FEED',
                                   'SUBSCRIPTION', 'EXTERNAL'))
) PARTITION BY RANGE (started_at);

-- ----------------------------------------------------------------------------
-- 2. One partition per month for the 18 months of seed data (Jan 2025 - Jun 2026)
--    plus a default partition for anything outside the declared ranges.
--    On the large dataset we'd add 2026-07 through 2027-06 the same way.
-- ----------------------------------------------------------------------------
CREATE TABLE watch_events_part_2025_01 PARTITION OF watch_events_part
    FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');
CREATE TABLE watch_events_part_2025_02 PARTITION OF watch_events_part
    FOR VALUES FROM ('2025-02-01') TO ('2025-03-01');
CREATE TABLE watch_events_part_2025_03 PARTITION OF watch_events_part
    FOR VALUES FROM ('2025-03-01') TO ('2025-04-01');
CREATE TABLE watch_events_part_2025_04 PARTITION OF watch_events_part
    FOR VALUES FROM ('2025-04-01') TO ('2025-05-01');
CREATE TABLE watch_events_part_2025_05 PARTITION OF watch_events_part
    FOR VALUES FROM ('2025-05-01') TO ('2025-06-01');
CREATE TABLE watch_events_part_2025_06 PARTITION OF watch_events_part
    FOR VALUES FROM ('2025-06-01') TO ('2025-07-01');
CREATE TABLE watch_events_part_2025_07 PARTITION OF watch_events_part
    FOR VALUES FROM ('2025-07-01') TO ('2025-08-01');
CREATE TABLE watch_events_part_2025_08 PARTITION OF watch_events_part
    FOR VALUES FROM ('2025-08-01') TO ('2025-09-01');
CREATE TABLE watch_events_part_2025_09 PARTITION OF watch_events_part
    FOR VALUES FROM ('2025-09-01') TO ('2025-10-01');
CREATE TABLE watch_events_part_2025_10 PARTITION OF watch_events_part
    FOR VALUES FROM ('2025-10-01') TO ('2025-11-01');
CREATE TABLE watch_events_part_2025_11 PARTITION OF watch_events_part
    FOR VALUES FROM ('2025-11-01') TO ('2025-12-01');
CREATE TABLE watch_events_part_2025_12 PARTITION OF watch_events_part
    FOR VALUES FROM ('2025-12-01') TO ('2026-01-01');
CREATE TABLE watch_events_part_2026_01 PARTITION OF watch_events_part
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE watch_events_part_2026_02 PARTITION OF watch_events_part
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE watch_events_part_2026_03 PARTITION OF watch_events_part
    FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE watch_events_part_2026_04 PARTITION OF watch_events_part
    FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE watch_events_part_2026_05 PARTITION OF watch_events_part
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE watch_events_part_2026_06 PARTITION OF watch_events_part
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE watch_events_part_default PARTITION OF watch_events_part DEFAULT;

-- ----------------------------------------------------------------------------
-- 3. Load the seed data into the partitioned table (one INSERT...SELECT).
--    ~200,000 rows; the planner routes each row to the right partition.
-- ----------------------------------------------------------------------------
INSERT INTO watch_events_part (watch_id, user_id, video_id, started_at,
                                watch_seconds, device, traffic_source)
SELECT watch_id, user_id, video_id, started_at, watch_seconds, device, traffic_source
FROM watch_events;

-- Per-partition row counts (the brief asks for partition pruning evidence;
-- the row distribution across months is the foundation of that).
SELECT to_char(started_at, 'YYYY-MM') AS month, count(*) AS rows
FROM watch_events_part
GROUP BY 1
ORDER BY 1;

-- ----------------------------------------------------------------------------
-- 4. Carry the Phase-4 indexes onto each partition.
--    On a partitioned table, `CREATE INDEX` propagates to all partitions
--    automatically - we write the index once and PostgreSQL creates one child
--    index per partition. This is the same index set as 05_indexes.sql, just
--    on the partitioned table.
-- ----------------------------------------------------------------------------
CREATE INDEX idx_wep_video
    ON watch_events_part (video_id)
    INCLUDE (user_id, started_at, watch_seconds, traffic_source);
CREATE INDEX idx_wep_user_started
    ON watch_events_part (user_id, started_at DESC)
    INCLUDE (video_id, watch_seconds);
CREATE INDEX idx_wep_video_user
    ON watch_events_part (video_id, user_id)
    INCLUDE (watch_id);

ANALYZE watch_events_part;

-- ----------------------------------------------------------------------------
-- 5. PARTITION PRUNING DEMO
--    Run EXPLAIN on a June-only query (R07's pattern). The plan should show
--    "Subplans Removed: 17" and only the 2026-06 partition scanned.
--    This is what we paste into docs/05_scalability_report.md §5.1.
-- ----------------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS)
SELECT DATE(started_at) AS day, count(*) AS views,
       round(sum(watch_seconds) / 3600.0, 2) AS watch_hours
FROM watch_events_part
WHERE started_at >= '2026-06-01' AND started_at < '2026-07-01'
GROUP BY 1
ORDER BY 1;

-- ----------------------------------------------------------------------------
-- 6. Summary: why this design, what changes for the large dataset
-- ----------------------------------------------------------------------------
-- For the large dataset (~4 M watch events, ~20 months):
--   * Add partitions 2026-07 .. 2027-06 the same way (12 more CREATE TABLE).
--   * The default partition catches any out-of-range row (an INSERT into a
--     gap raises an error, which is the safe behaviour).
--   * Each partition is ~200k-250k rows; the June-only R07 reads one ~200k
--     partition instead of the full 4 M table - a ~20x pruning.
--   * DETACH and archive old months: once Jan 2025 is stale, run
--       ALTER TABLE watch_events_part DETACH PARTITION watch_events_part_2025_01;
--     The detached table keeps its data for compliance; the live set shrinks.
--   * VACUUM per-partition: autovacuum treats each partition as its own table,
--     so the hot recent partitions get vacuumed often and the cold old ones
--     are left alone. Set a lower autovacuum_vacuum_scale_factor (e.g. 0.02)
--     on the current-month partition only:
--       ALTER TABLE watch_events_part_2026_06 SET (autovacuum_vacuum_scale_factor = 0.02);
--   * Sharding (brief §5.3): for 100x, RANGE-partition by month on a single
--     node handles ~5-10x; beyond that, HASH-partition watch_events by
--     channel_id across nodes (Studio charts are per-channel so they stay
--     single-shard; history and feed become cross-shard and need a fan-out).

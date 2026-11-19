-- ============================================================================
-- YouTube DBMS - Phase 4 indexes
-- sql/05_indexes.sql - CP3 DE
-- Team: Adil Reyaz (2501010025), Utkarsh Singh (2501010488),
--       Renuka Yadav (2501010373), Shubham (2501010672)
--
-- Every index here exists to serve at least one of the 30 workload queries.
-- The Phase-2 rule said "no tuning indexes" - Phase 4 is exactly where we add
-- them. PostgreSQL already indexes PRIMARY KEY and UNIQUE columns; we do not
-- repeat those.
--
-- Conventions used:
--   * Equality predicates first, then range/sort columns, then INCLUDE() for
--     index-only scans. This is the column-order rule from the brief.
--   * Partial indexes (WHERE ...) for rare statuses so the index is small and
--     the right rows are pre-filtered.
--   * BRIN where the table is large and clustered by a monotonic column
--     (watch_id is insertion order, which matches started_at for watch_events).
--   * GIN + pg_trgm for substring ILIKE search.
--
-- Run AFTER 01_schema.sql and 02_load_data.sql, then ANALYZE.
-- ============================================================================

SET search_path TO youtube;

-- pg_trgm extension for R04 (ILIKE '%tutorial%'). CREATE EXTENSION needs the
-- extension to be available; on PostgreSQL 15+ it ships with contrib. If it is
-- missing, R04 falls back to a Seq Scan (documented in 04_optimization_report).
-- Use a DO block so the file still runs clean on a server without pg_trgm.
DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_trgm;
EXCEPTION WHEN feature_not_supported OR insufficient_privilege OR undefined_file OR syntax_error OR undefined_object THEN
    RAISE NOTICE 'pg_trgm not available; R04 will fall back to Seq Scan (documented in 04_optimization_report.md)';
END $$;

-- ----------------------------------------------------------------------------
-- R01  Channel page: 20 newest PUBLIC videos of one channel
-- R03  Subscriptions feed: PUBLIC videos by channel, newest first (shares this)
-- Equality on channel_id + range/sort on published_at DESC, only PUBLIC rows.
-- INCLUDE the projected columns so the videos table is never touched
-- (Index-Only Scan). Partial on visibility='PUBLIC' keeps the index ~1/4 size.
-- ----------------------------------------------------------------------------
CREATE INDEX idx_videos_channel_published_public
    ON videos (channel_id, published_at DESC)
    INCLUDE (video_id, title, duration_sec, view_count)
    WHERE visibility = 'PUBLIC';

-- ----------------------------------------------------------------------------
-- R04  Search: public videos with "tutorial" in title, most viewed first
-- GIN trigram index supports ILIKE '%...%' (a btree cannot). Partial on PUBLIC
-- so the index only covers searchable rows. ORDER BY view_count still needs a
-- sort, but the candidate set is tiny.
-- Created only if pg_trgm is available; otherwise R04 falls back to Seq Scan
-- (documented honestly in 04_optimization_report.md - on a full PostgreSQL
-- install pg_trgm ships with contrib and is a one-line `CREATE EXTENSION`).
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm') THEN
        CREATE INDEX IF NOT EXISTS idx_videos_title_trgm_public
            ON videos USING gin (title gin_trgm_ops)
            WHERE visibility = 'PUBLIC';
    ELSE
        RAISE NOTICE 'pg_trgm GIN index skipped (extension not installed); R04 uses Seq Scan';
    END IF;
END $$;

-- ----------------------------------------------------------------------------
-- R05  History page: last 50 videos user 1042 watched
-- Equality on user_id, range/sort started_at DESC, INCLUDE the join + projected
-- columns so watch_events is index-only; videos is still joined for title.
-- ----------------------------------------------------------------------------
CREATE INDEX idx_watch_events_user_started
    ON watch_events (user_id, started_at DESC)
    INCLUDE (video_id, watch_seconds);

-- ----------------------------------------------------------------------------
-- R06  Scheduled videos in the first week of July 2026
-- R05-W05 Publishing flip: visibility='SCHEDULED' AND published_at <= cutoff
-- SCHEDULED is a rare status; a partial index on just that slice + published_at
-- keeps the index small and makes R06 an index-only range scan.
-- ----------------------------------------------------------------------------
CREATE INDEX idx_videos_scheduled_published
    ON videos (published_at)
    INCLUDE (video_id, channel_id, title)
    WHERE visibility = 'SCHEDULED';

-- ----------------------------------------------------------------------------
-- R07, R08, R09, R10, R11, R16, R17  the big watch_events family
-- Almost every Studio/analytics query probes watch_events by video_id (R08,
-- R09, R10, R11, R16, R17) or by a time range (R07, R10, R11, R20). The PK is
-- watch_id, useless for these. A covering B-tree on (video_id) lets the planner
-- Index-Only-Scan watch_events for per-video aggregates; INCLUDE the columns
-- those aggregates need so the heap is never visited.
-- ----------------------------------------------------------------------------
CREATE INDEX idx_watch_events_video
    ON watch_events (video_id)
    INCLUDE (user_id, started_at, watch_seconds, traffic_source);

-- R07 also needs a per-channel filter, which lives on videos - so a
-- watch_events(video_id) index is used after the join with videos(channel_id).
-- ----------------------------------------------------------------------------
-- R07  daily views per channel in June - sargable time range (rewritten query)
-- R20  daily watch hours in June - sargable time range (rewritten query)
-- R10  Shorts shelf in last 7 days of June - sargable time range
-- R11  Trending in June - sargable time range
-- BRIN is the right tool: watch_events is clustered by started_at (rows are
-- appended in watch_id order, which is ~time order), and BRIN indexes huge
-- append-only tables at near-zero cost. A B-tree on started_at would be ~5 MB
-- and overkill for 200k rows; BRIN scales to the 20x large dataset for free.
-- ----------------------------------------------------------------------------
CREATE INDEX idx_watch_events_started_brin
    ON watch_events USING brin (started_at) WITH (pages_per_range = 32);

-- ----------------------------------------------------------------------------
-- R13  subscribers of channel 217 who never watched its videos
-- After the NOT IN -> NOT EXISTS rewrite, this needs to probe watch_events by
-- (video_id, user_id) to check existence. A composite index lets the planner
-- answer "did this user watch any of this channel's videos?" as an index-only
-- existence check, no heap touch.
-- ----------------------------------------------------------------------------
CREATE INDEX idx_watch_events_video_user
    ON watch_events (video_id, user_id)
    INCLUDE (watch_id);

-- ----------------------------------------------------------------------------
-- R14  likes/dislikes per video of channel 217
-- video_reactions PK is (user_id, video_id) - useless for "all reactions of
-- this video" probes. A covering index on (video_id) INCLUDE (reaction) lets
-- the aggregate be an index-only scan.
-- ----------------------------------------------------------------------------
CREATE INDEX idx_video_reactions_video
    ON video_reactions (video_id)
    INCLUDE (reaction, reacted_at);

-- ----------------------------------------------------------------------------
-- R15  pinned + top 10 comments of one video
-- Filter on video_id + top-level (parent IS NULL), sort by (is_pinned DESC,
-- like_count DESC). Partial on top-level keeps replies out. LIMIT 11 is then
-- a tiny index range.
-- ----------------------------------------------------------------------------
CREATE INDEX idx_comments_video_top
    ON comments (video_id, is_pinned DESC, like_count DESC)
    INCLUDE (comment_id, user_id, body, created_at)
    WHERE parent_comment_id IS NULL;

-- ----------------------------------------------------------------------------
-- R16  Finance: ad revenue per channel in June 2026
-- R25  Premium audit: ads shown to Premium users
-- ad_impressions is probed by shown_at (R16) and by watch_id (R25 join).
-- BRIN on shown_at for the time range; B-tree on watch_id for the join to
-- watch_events.
-- ----------------------------------------------------------------------------
CREATE INDEX idx_ad_impressions_shown_brin
    ON ad_impressions USING brin (shown_at) WITH (pages_per_range = 64);
CREATE INDEX idx_ad_impressions_watch
    ON ad_impressions (watch_id)
    INCLUDE (ad_format, revenue_inr, shown_at);

-- ----------------------------------------------------------------------------
-- R17, R18, R19, R22  channels/videos probes by attributes
-- R17 + R19 need to filter channels by monetization_status (rare slices).
-- R18 needs videos where is_made_for_kids (rare slice) + comments by video.
-- R19 (rewritten with LATERAL) needs videos(channel_id, uploaded_at DESC).
-- R22 is a full-table GROUP BY - no index helps, documented honestly.
-- ----------------------------------------------------------------------------
CREATE INDEX idx_channels_monetization
    ON channels (monetization_status)
    INCLUDE (channel_id, handle, subscriber_count)
    WHERE monetization_status IN ('NOT_ELIGIBLE', 'ELIGIBLE');

CREATE INDEX idx_videos_channel_uploaded
    ON videos (channel_id, uploaded_at DESC)
    INCLUDE (video_id, title, view_count);

CREATE INDEX idx_videos_made_for_kids
    ON videos (video_id)
    INCLUDE (channel_id, title)
    WHERE is_made_for_kids;

-- comments by video for the R18 EXISTS probe (and R15 top-level already covers
-- most of this; this one is unrestricted on parent for the EXISTS path)
CREATE INDEX idx_comments_video
    ON comments (video_id)
    INCLUDE (comment_id);

-- ----------------------------------------------------------------------------
-- R23  Moderation queue: comments newest-first, deep page
-- Rewritten with keyset pagination: WHERE (created_at, comment_id) < (last_seen)
-- ORDER BY created_at DESC, comment_id DESC LIMIT 25. A composite index on the
-- exact sort key makes the seek a tiny index range, no OFFSET skip.
-- ----------------------------------------------------------------------------
CREATE INDEX idx_comments_created_id_desc
    ON comments (created_at DESC, comment_id DESC)
    INCLUDE (video_id, user_id, body);

-- ----------------------------------------------------------------------------
-- R24  New subscribers per month for channel 217
-- subscriptions PK is (user_id, channel_id) - prefix-serves user_id but NOT
-- channel_id. A channel-first index makes R24 an index range + group.
-- ----------------------------------------------------------------------------
CREATE INDEX idx_subscriptions_channel_subscribed
    ON subscriptions (channel_id, subscribed_at)
    INCLUDE (user_id);

-- ----------------------------------------------------------------------------
-- W04  Nightly job: recompute every channel's subscriber count
-- GROUP BY channel_id on 129,253 rows - a channel-first index lets the aggregate
-- be an index-only scan (shares R24's index).
-- (No new index needed - idx_subscriptions_channel_subscribed covers it.)
-- ----------------------------------------------------------------------------

-- Refresh planner statistics after creating indexes.
ANALYZE;

-- Inventory of tuning indexes created (PK/UNIQUE auto-indexes not listed):
--   idx_videos_channel_published_public   partial covering B-tree  (R01, R03)
--   idx_videos_title_trgm_public           partial GIN              (R04)
--   idx_watch_events_user_started          covering B-tree          (R05)
--   idx_videos_scheduled_published         partial covering B-tree  (R06, W05)
--   idx_watch_events_video                 covering B-tree          (R07-R11, R16, R17)
--   idx_watch_events_started_brin          BRIN                     (R07, R10, R11, R20)
--   idx_watch_events_video_user            covering B-tree          (R13)
--   idx_video_reactions_video              covering B-tree          (R14)
--   idx_comments_video_top                 partial covering B-tree  (R15)
--   idx_ad_impressions_shown_brin          BRIN                     (R16)
--   idx_ad_impressions_watch              covering B-tree          (R25)
--   idx_channels_monetization              partial covering B-tree  (R17, R19)
--   idx_videos_channel_uploaded            covering B-tree          (R19)
--   idx_videos_made_for_kids               partial                  (R18)
--   idx_comments_video                     covering B-tree          (R18)
--   idx_comments_created_id_desc           covering B-tree          (R23)
--   idx_subscriptions_channel_subscribed   covering B-tree          (R24, W04)
-- 17 tuning indexes total.

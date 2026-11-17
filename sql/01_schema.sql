-- ============================================================================
-- YouTube Video Sharing Database - schema rebuilt from the seed_data exports
-- CP1 / Phase 2, Team: Adil Reyaz (2501010025), Utkarsh Singh (2501010488),
--                      Renuka Yadav (2501010373), Shubham (2501010672)
--
-- Runs top-to-bottom on an empty PostgreSQL 15+ database.
-- Design decisions (data types, keys, delete rules) are documented inline;
-- the full data dictionary, functional dependencies and normal-form analysis
-- are in docs/02_schema_design.md.
--
-- Per the project rules this file creates ONLY constraints:
-- PK / FK / UNIQUE / NOT NULL / CHECK - no extra indexes. (PostgreSQL
-- automatically indexes PRIMARY KEY and UNIQUE columns; the inventory of
-- those automatic indexes is listed in docs/02_schema_design.md.)
-- ============================================================================

-- Re-runnable: start from a clean slate if the database already has a youtube schema.
DROP SCHEMA IF EXISTS youtube CASCADE;
CREATE SCHEMA youtube;
SET search_path TO youtube;

-- ----------------------------------------------------------------------------
-- 1. users - signed-in YouTube accounts (30,000 rows in the seed export)
-- ----------------------------------------------------------------------------
CREATE TABLE users (
    user_id       INTEGER       PRIMARY KEY,        -- surrogate id from the export
    email         VARCHAR(255)  NOT NULL UNIQUE,    -- natural key / login identity
    display_name  VARCHAR(100)  NOT NULL,
    country_code  CHAR(2)       NOT NULL,           -- ISO 3166-1 alpha-2
    birth_year    SMALLINT,                          -- NULL: not provided (4,433 rows)
    premium_until DATE,                              -- NULL: no active Premium membership
    created_at    TIMESTAMPTZ   NOT NULL,           -- export carries +05:30 offsets

    CONSTRAINT users_country_code_format
        CHECK (country_code ~ '^[A-Z]{2}$'),
    CONSTRAINT users_birth_year_sane
        CHECK (birth_year IS NULL OR birth_year BETWEEN 1900 AND 2013),
    CONSTRAINT users_premium_not_before_signup
        CHECK (premium_until IS NULL
               OR premium_until >= (created_at AT TIME ZONE 'Asia/Kolkata')::date)
);

-- ----------------------------------------------------------------------------
-- 2. channels - creator channels (3,000 rows), each owned by one user
-- ----------------------------------------------------------------------------
CREATE TABLE channels (
    channel_id          INTEGER       PRIMARY KEY,
    owner_user_id       INTEGER       NOT NULL REFERENCES users (user_id)
                                        ON DELETE CASCADE,   -- a channel cannot outlive its owner
    handle              VARCHAR(30)   NOT NULL UNIQUE,      -- natural key, e.g. @vivaanvlogs1
    channel_name        VARCHAR(100)  NOT NULL,
    country_code        CHAR(2)       NOT NULL,
    is_verified         BOOLEAN       NOT NULL,
    monetization_status VARCHAR(15)   NOT NULL,
    subscriber_count    INTEGER       NOT NULL,             -- derived counter, see docs
    created_at          TIMESTAMPTZ   NOT NULL,

    CONSTRAINT channels_handle_format
        CHECK (handle ~ '^@[A-Za-z0-9._-]+$'),
    CONSTRAINT channels_country_code_format
        CHECK (country_code ~ '^[A-Z]{2}$'),
    CONSTRAINT channels_monetization_status_valid
        CHECK (monetization_status IN ('NOT_ELIGIBLE', 'ELIGIBLE', 'SUSPENDED')),
    CONSTRAINT channels_subscriber_count_nonnegative
        CHECK (subscriber_count >= 0)
);
-- owner_user_id is deliberately NOT UNIQUE: YouTube allows one account to run
-- several channels. In the seed export the relation happens to be 1:1 (3,000
-- channels, 3,000 distinct owners), but that is a property of this dataset,
-- not a business rule, so it is not constrained.

-- ----------------------------------------------------------------------------
-- 3. videos - long videos and Shorts (30,000 rows)
-- ----------------------------------------------------------------------------
CREATE TABLE videos (
    video_id         CHAR(11)      PRIMARY KEY,     -- 11-character YouTube id
    channel_id       INTEGER       NOT NULL REFERENCES channels (channel_id)
                                     ON DELETE CASCADE,
    title            VARCHAR(100)  NOT NULL,        -- YouTube caps titles at 100 chars
    description      VARCHAR(5000),                 -- NULL: no description (9,083 rows)
    category         VARCHAR(20)   NOT NULL,
    duration_sec     INTEGER       NOT NULL,
    is_short         BOOLEAN       NOT NULL,
    is_made_for_kids BOOLEAN       NOT NULL DEFAULT FALSE,  -- designated at upload; W01 omits it
    visibility       VARCHAR(10)   NOT NULL,
    uploaded_at      TIMESTAMPTZ   NOT NULL,
    published_at     TIMESTAMPTZ,                   -- NULL: exactly the 1,526 PRIVATE videos
    view_count       BIGINT        NOT NULL DEFAULT 0,      -- derived counter, see docs; new uploads start at 0 (W01 omits it)

    CONSTRAINT videos_video_id_format
        CHECK (video_id ~ '^[A-Za-z0-9_-]{11}$'),
    CONSTRAINT videos_category_valid
        CHECK (category IN ('Comedy', 'Cooking', 'Education', 'Film', 'Gaming',
                            'Music', 'News', 'Sports', 'Tech', 'Vlogs')),
    CONSTRAINT videos_duration_positive
        CHECK (duration_sec > 0),                   -- also protects R09's division by duration
    CONSTRAINT videos_short_at_most_60s
        CHECK (NOT is_short OR duration_sec <= 60),
    CONSTRAINT videos_visibility_valid
        CHECK (visibility IN ('PUBLIC', 'UNLISTED', 'PRIVATE', 'SCHEDULED')),
    CONSTRAINT videos_private_never_published
        CHECK (visibility <> 'PRIVATE' OR published_at IS NULL),
    CONSTRAINT videos_scheduled_needs_publish_time
        CHECK (visibility <> 'SCHEDULED' OR published_at IS NOT NULL),
    CONSTRAINT videos_published_not_before_upload
        CHECK (published_at IS NULL OR published_at >= uploaded_at),
    CONSTRAINT videos_view_count_nonnegative
        CHECK (view_count >= 0)
);
-- In the seed data is_short is EXACTLY (duration_sec <= 60): every Short is
-- 10-59 s and every regular video is 61 s or longer. Only the business rule
-- ("a Short is at most 60 s") is constrained - a future 45 s regular upload
-- must remain legal.

-- ----------------------------------------------------------------------------
-- 4. subscriptions - which user follows which channel (129,253 rows)
-- ----------------------------------------------------------------------------
CREATE TABLE subscriptions (
    user_id       INTEGER      NOT NULL REFERENCES users (user_id)
                                 ON DELETE CASCADE,
    channel_id    INTEGER      NOT NULL REFERENCES channels (channel_id)
                                 ON DELETE CASCADE,
    notifications VARCHAR(12)  NOT NULL,
    subscribed_at TIMESTAMPTZ  NOT NULL,
    PRIMARY KEY (user_id, channel_id),      -- at most one subscription per user per channel
    CONSTRAINT subscriptions_notifications_valid
        CHECK (notifications IN ('NONE', 'PERSONALIZED', 'ALL'))
);

-- ----------------------------------------------------------------------------
-- 5. watch_events - every view, signed in or not (200,000 rows)
-- ----------------------------------------------------------------------------
CREATE TABLE watch_events (
    watch_id       INTEGER      PRIMARY KEY,       -- plain INTEGER: workload W02 supplies ids
    user_id        INTEGER      REFERENCES users (user_id)
                                 ON DELETE CASCADE, -- NULL: logged-out view (49,964 rows ≈ 25%)
    video_id       CHAR(11)     NOT NULL REFERENCES videos (video_id)
                                 ON DELETE CASCADE,
    started_at     TIMESTAMPTZ  NOT NULL,
    watch_seconds  INTEGER      NOT NULL,
    device         VARCHAR(10)  NOT NULL,
    traffic_source VARCHAR(15)  NOT NULL,

    CONSTRAINT watch_events_watch_seconds_range
        CHECK (watch_seconds BETWEEN 0 AND 86400),
    CONSTRAINT watch_events_device_valid
        CHECK (device IN ('WEB', 'ANDROID', 'IOS', 'TV')),
    CONSTRAINT watch_events_traffic_source_valid
        CHECK (traffic_source IN ('HOME', 'SEARCH', 'SUGGESTED', 'SHORTS_FEED',
                                  'SUBSCRIPTION', 'EXTERNAL'))
);
-- user_id is ON DELETE CASCADE, not SET NULL: re-labelling a deleted user's
-- views as "logged out" would silently corrupt the logged-out share metric
-- (query R12). The watch history is deleted with the account.
-- The rule "watch_seconds never exceeds the video duration" holds on all
-- 200,000 rows, but it spans two tables, so it is verified as an integrity
-- check in docs/02_schema_design.md rather than a CHECK constraint.

-- ----------------------------------------------------------------------------
-- 6. video_reactions - likes and dislikes (67,417 rows)
-- ----------------------------------------------------------------------------
CREATE TABLE video_reactions (
    user_id    INTEGER     NOT NULL REFERENCES users (user_id)
                             ON DELETE CASCADE,
    video_id   CHAR(11)    NOT NULL REFERENCES videos (video_id)
                             ON DELETE CASCADE,
    reaction   VARCHAR(7)  NOT NULL,
    reacted_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (user_id, video_id),        -- at most one reaction per user per video
    CONSTRAINT video_reactions_reaction_valid
        CHECK (reaction IN ('LIKE', 'DISLIKE'))
);

-- ----------------------------------------------------------------------------
-- 7. comments - comments and replies (60,000 rows)
-- ----------------------------------------------------------------------------
CREATE TABLE comments (
    comment_id        INTEGER        PRIMARY KEY,
    video_id          CHAR(11)       NOT NULL REFERENCES videos (video_id)
                                      ON DELETE CASCADE,
    user_id           INTEGER        NOT NULL REFERENCES users (user_id)
                                      ON DELETE CASCADE,
    parent_comment_id INTEGER        REFERENCES comments (comment_id)
                                      ON DELETE CASCADE,
    body              VARCHAR(10000) NOT NULL,
    like_count        INTEGER        NOT NULL,
    is_pinned         BOOLEAN        NOT NULL,
    created_at        TIMESTAMPTZ    NOT NULL,

    CONSTRAINT comments_like_count_nonnegative
        CHECK (like_count >= 0),
    CONSTRAINT comments_replies_cannot_be_pinned
        CHECK (parent_comment_id IS NULL OR NOT is_pinned)
);
-- Verified on the export: every reply references a parent with a smaller
-- comment_id, so comments.csv is parent-before-child and the self-FK can be
-- checked immediately. Deleting a comment cascades to its replies, matching
-- YouTube's "delete thread" behaviour.

-- ----------------------------------------------------------------------------
-- 8. playlists - user playlists (8,000 rows)
-- ----------------------------------------------------------------------------
CREATE TABLE playlists (
    playlist_id   INTEGER       PRIMARY KEY,
    owner_user_id INTEGER       NOT NULL REFERENCES users (user_id)
                                  ON DELETE CASCADE,
    title         VARCHAR(150)  NOT NULL,
    visibility    VARCHAR(10)   NOT NULL,
    created_at    TIMESTAMPTZ   NOT NULL,

    CONSTRAINT playlists_visibility_valid
        CHECK (visibility IN ('PRIVATE', 'UNLISTED', 'PUBLIC'))
);

-- ----------------------------------------------------------------------------
-- 9. playlist_items - videos inside each playlist, in order (56,005 rows)
-- ----------------------------------------------------------------------------
CREATE TABLE playlist_items (
    playlist_id INTEGER      NOT NULL REFERENCES playlists (playlist_id)
                               ON DELETE CASCADE,
    position    SMALLINT     NOT NULL,
    video_id    CHAR(11)     NOT NULL REFERENCES videos (video_id)
                               ON DELETE CASCADE,
    added_at    TIMESTAMPTZ  NOT NULL,
    PRIMARY KEY (playlist_id, position),

    CONSTRAINT playlist_items_position_positive
        CHECK (position >= 1)
);
-- A video may legitimately appear twice in a YouTube playlist, so
-- (playlist_id, video_id) is deliberately NOT unique; the seed export happens
-- to contain no duplicates (verified as integrity check #3 in the docs).

-- ----------------------------------------------------------------------------
-- 10. ad_impressions - ads shown during views and revenue earned (57,014 rows)
-- ----------------------------------------------------------------------------
CREATE TABLE ad_impressions (
    impression_id INTEGER       PRIMARY KEY,
    watch_id      INTEGER       NOT NULL REFERENCES watch_events (watch_id)
                                 ON DELETE RESTRICT,   -- finance data, see note below
    ad_format     VARCHAR(10)   NOT NULL,
    revenue_inr   NUMERIC(10,4) NOT NULL,             -- money: exact decimal, never float
    shown_at      TIMESTAMPTZ   NOT NULL,

    CONSTRAINT ad_impressions_ad_format_valid
        CHECK (ad_format IN ('PREROLL', 'MIDROLL')),
    CONSTRAINT ad_impressions_revenue_nonnegative
        CHECK (revenue_inr >= 0)
);
-- ON DELETE RESTRICT: an ad impression is a financial record - it pays the
-- creator and feeds partner-program reports (R16, R19, R25). Deleting a watch
-- event that carried ads would silently destroy revenue history, so the
-- database refuses until the impressions are explicitly archived. The
-- consequence is deliberate: an account or video that earned ad revenue
-- cannot be hard-deleted in one step.

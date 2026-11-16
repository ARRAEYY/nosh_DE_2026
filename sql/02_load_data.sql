-- ============================================================================
-- YouTube Video Sharing Database — load the seed export (Phase 2, CP1)
--
-- Run FROM THE REPOSITORY ROOT so the relative paths resolve:
--     psql -d <database> -f sql/02_load_data.sql
--
-- Tables are loaded parents-first so every foreign key is satisfied
-- (in comments.csv every reply references a parent with a smaller
-- comment_id, so the file is already parent-before-child).
-- ============================================================================

SET search_path TO youtube;

-- 1. users (30,000)          — no dependencies
\copy users FROM 'seed_data/users.csv' WITH (FORMAT csv, HEADER true)

-- 2. channels (3,000)        — depends on users
\copy channels FROM 'seed_data/channels.csv' WITH (FORMAT csv, HEADER true)

-- 3. videos (30,000)         — depends on channels
\copy videos FROM 'seed_data/videos.csv' WITH (FORMAT csv, HEADER true)

-- 4. subscriptions (129,253) — depends on users, channels
\copy subscriptions FROM 'seed_data/subscriptions.csv' WITH (FORMAT csv, HEADER true)

-- 5. watch_events (200,000)  — depends on users, videos
\copy watch_events FROM 'seed_data/watch_events.csv' WITH (FORMAT csv, HEADER true)

-- 6. video_reactions (67,417) — depends on users, videos
\copy video_reactions FROM 'seed_data/video_reactions.csv' WITH (FORMAT csv, HEADER true)

-- 7. comments (60,000)       — depends on videos, users (self-FK deferred)
\copy comments FROM 'seed_data/comments.csv' WITH (FORMAT csv, HEADER true)

-- 8. playlists (8,000)       — depends on users
\copy playlists FROM 'seed_data/playlists.csv' WITH (FORMAT csv, HEADER true)

-- 9. playlist_items (56,005) — depends on playlists, videos
\copy playlist_items FROM 'seed_data/playlist_items.csv' WITH (FORMAT csv, HEADER true)

-- 10. ad_impressions (57,014) — depends on watch_events
\copy ad_impressions FROM 'seed_data/ad_impressions.csv' WITH (FORMAT csv, HEADER true)

ANALYZE;

-- ----------------------------------------------------------------------------
-- Row counts as loaded — must match the project brief:
--   users 30,000 · channels 3,000 · videos 30,000 · subscriptions 129,253
--   watch_events 200,000 · video_reactions 67,417 · comments 60,000
--   playlists 8,000 · playlist_items 56,005 · ad_impressions 57,014
-- ----------------------------------------------------------------------------
SELECT 'users' AS table_name, count(*) AS rows_loaded FROM users
UNION ALL SELECT 'channels',          count(*) FROM channels
UNION ALL SELECT 'videos',            count(*) FROM videos
UNION ALL SELECT 'subscriptions',     count(*) FROM subscriptions
UNION ALL SELECT 'watch_events',      count(*) FROM watch_events
UNION ALL SELECT 'video_reactions',   count(*) FROM video_reactions
UNION ALL SELECT 'comments',          count(*) FROM comments
UNION ALL SELECT 'playlists',         count(*) FROM playlists
UNION ALL SELECT 'playlist_items',    count(*) FROM playlist_items
UNION ALL SELECT 'ad_impressions',    count(*) FROM ad_impressions
ORDER BY 1;

# Phase 1 — Problem Understanding

We are the new YouTube India data team. The database we inherited has **no documented schema** — only raw CSV exports survive — and nine product teams have reported problems. Our job is to (1) rebuild a correct, well-constrained schema from the exports, (2) measure the 30 most important queries, (3) make them fast without changing results, and (4) survive 20x growth.

## The nine problems, in our own words

| # | What the business actually needs | Stakeholder affected | Class |
|---|----------------------------------|----------------------|-------|
| P1 | Channel, watch and playlist pages must open instantly — a viewer tapping a video or playlist cannot wait seconds for the page to build. | Viewer | Customer-facing, real-time |
| P2 | The subscriptions feed and watch history must load in milliseconds even for the most active users (hundreds of subscriptions, thousands of views). | Viewer | Customer-facing, real-time |
| P3 | Search by title must stay interactive; today a simple "tutorial" search crawls through every video. | Viewer / Search team | Customer-facing, real-time (interactive) |
| P4 | Studio charts (daily views, traffic sources, retention, likes, subscriber growth) must refresh fast enough for a creator to use them interactively while editing content. | Creator / YouTube Studio team | Customer-facing for creators, interactive analytics |
| P5 | The "subscribers who never watched" report always comes back **empty** — this is a **correctness** bug (a subtle NULL rule in SQL), not a speed problem; the data to answer it clearly exists. | Creator / Studio team | Customer-facing, correctness |
| P6 | The Shorts shelf and Trending tab are recomputed over all watch events; recommendations must keep pace with fresh data or the surfaces go stale. | Trending / Recommendations team | Reporting / analytics feeding customer surfaces |
| P7 | The publishing service must never miss a scheduled go-live, and the write path (uploads, view recording, counter increments) must stay fast under load. | Publishing team (and every uploader/viewer behind them) | Customer-facing, real-time write path |
| P8 | Finance and partner-program reports — ad revenue per channel, monetization eligibility, the Premium ads audit — time out before producing numbers. | Finance / Partner program | Reporting / analytics |
| P9 | Trust teams need child-safety, copyright and moderation reports; growth needs logged-out and watch-time trends; and all of it must survive **20x** traffic growth. | Child safety, copyright, moderation, Growth | Reporting / analytics + scalability |

The class column maps directly onto the Phase 5 performance targets: the real-time group (R01–R03, R05, R15, R21, W01–W03) targets **< 5 ms**, the interactive Studio/search group (R04, R06–R09, R13, R14, R24, W05) targets **< 250 ms**, and the reporting group (R10–R12, R16–R20, R22, R23, R25, W04) targets **< 5 s** (batch job W04 < 2 s).

## Assumptions

1. The 10 CSV files in `seed_data.zip` are a faithful production export (1 Jan 2025 – 30 Jun 2026, all timestamps IST, `+05:30`); we rebuild the schema to fit them, never the reverse.
2. A watch event with no `user_id` is a **logged-out** view; nothing is broken in those rows (they are ~25% of the table and drive R12).
3. A user's Premium membership is active from `premium_until` onward as used by R25; the 181 ads found on active Premium accounts are a **data-quality violation** to report, not a schema failure.
4. `email` (users) and `handle` (channels) are natural unique identifiers; `video_id` is the 11-character YouTube id.
5. `channels.subscriber_count` and `videos.view_count` are derived counters maintained by batch jobs (W03, W04) — we keep them for cheap reads and document the redundancy.
6. The 30 queries in `queries/workload_30.sql` are fixed; if one fails, our schema is wrong, not the query.
7. Money (`revenue_inr`) is stored as an exact decimal, never a float.
8. Delete rules are ours to justify: ownership/engagement cascades, but financial records (ad impressions) are protected by RESTRICT.

# Phase 1: Problem Understanding

We are the new database team for a YouTube-like video platform (the "YouTube India" data). The old team left no schema documentation. All we have is raw CSV exports of the data. Nine different teams have reported problems to us.

Our job has four parts:

1. Rebuild a correct schema from the CSV exports.
2. Measure how fast the 30 most important queries run today (the baseline).
3. Make them fast without changing their results.
4. Make sure the system still works when the data grows 20 times bigger.

## The nine problems, in our own words

| # | What the business needs | Who is affected | What kind of problem it is |
|---|--------------------------|-----------------|----------------------------|
| P1 | Channel pages, watch pages and playlist pages must open instantly. A viewer taps a video and waits for the page to build. If that takes seconds, the viewer leaves. | Viewer | Real-time, customer-facing |
| P2 | The subscriptions feed and watch history must load in milliseconds, even for the most active users (people with hundreds of subscriptions and thousands of views). | Viewer | Real-time, customer-facing |
| P3 | Search by title must stay fast. Right now a simple "tutorial" search walks through every single video row. | Viewer / Search team | Real-time, interactive |
| P4 | Studio charts (daily views, traffic sources, retention, likes, subscriber growth) must refresh fast. A creator uses these charts while editing, so they need to feel interactive. | Creator / Studio team | Interactive analytics |
| P5 | The "subscribers who never watched" report always comes back empty. This is not a speed problem. It is a wrong-answer problem caused by a subtle SQL NULL rule. The subscribers it should list clearly exist in the data. | Creator / Studio team | Correctness bug |
| P6 | The Shorts shelf and Trending tab are recomputed over all watch events. Recommendations must keep up with fresh data or these surfaces go stale. | Trending / Recommendations team | Reporting that feeds customer pages |
| P7 | The publishing service must never miss a scheduled go-live. The write path (uploads, recording a view, bumping view counters) must stay fast under load. | Publishing team, and every uploader and viewer behind them | Real-time write path |
| P8 | Finance and partner-program reports (ad revenue per channel, monetization eligibility, the Premium ads audit) currently time out before they finish. | Finance / Partner program | Reporting |
| P9 | Trust teams need child-safety, copyright and moderation reports. Growth needs logged-out and watch-time trends. And everything must survive 20x traffic growth. | Child safety, copyright, moderation, Growth | Reporting + scalability |

## How these problems map to the performance targets

The Phase 5 brief sets a speed target for each query, based on what kind of problem it solves:

- Real-time, viewer-facing queries (R01, R02, R03, R05, R15, R21, W01, W02, W03): target under 5 ms. A person is waiting for this page.
- Interactive Studio and search queries (R04, R06, R07, R08, R09, R13, R14, R24, W05): target under 250 ms. A creator is clicking around Studio.
- Reports and analytics (R10, R11, R12, R16, R17, R18, R19, R20, R22, R23, R25): target under 5 s. Nobody stares at a report, but it must finish.
- Batch jobs (W04): target under 2 s. Runs at night, no human waiting.

So when we pick what to optimize first, the group a query belongs to tells us how fast is fast enough.

## Assumptions we made (and why)

1. The 10 CSV files in `seed_data.zip` are a faithful export of production. They cover 1 Jan 2025 to 30 Jun 2026, all timestamps in IST (+05:30). We build the schema to fit the data, never the other way around.
2. A watch event with no `user_id` is a logged-out view. Nothing is broken in those rows. They are about 25% of the table, and query R12 actually depends on them.
3. A user's Premium membership is active until `premium_until`. Query R25 uses this rule. The 181 ads shown to active Premium members are a data-quality problem in the export, not a schema problem. We report them, we do not hide them.
4. `email` (users) and `handle` (channels) are natural unique identifiers. `video_id` is the standard 11-character YouTube id.
5. `channels.subscriber_count` and `videos.view_count` are counters kept in sync by jobs (W03, W04). We keep them because reading one number is much cheaper than counting thousands of rows on every page view. We document this as a known redundancy.
6. The 30 queries in `queries/workload_30.sql` are fixed. If one of them fails, our schema is wrong, not the query. (This exact rule hit us once, see the schema doc.)
7. Money (`revenue_inr`) is stored as an exact decimal type, never a float, because floats cannot represent rupee amounts exactly.
8. Delete rules are our choice to justify. Ownership and engagement data gets deleted along with its parent (CASCADE). Financial records (ad impressions) are protected (RESTRICT) because money records must never silently disappear.

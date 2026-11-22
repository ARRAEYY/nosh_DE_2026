# benchmarks/results/large/ - CP4 large-data results (DE)

**Owner of this commit:** Adil Reyaz (ARRAEY)

**Status: COMPLETE - measured Sun 22 Nov 2026.** The faculty `large_data.zip`
(247,002,767 bytes, 12,828,190 data rows; SHA-256 below) was loaded into a fresh
`youtube_large` database on PostgreSQL 16.2 exactly per the runbook below, and the
optimized workload was benchmarked with 3 runs of `EXPLAIN (ANALYZE, BUFFERS)` -
producing the `summary.csv` and 30 raw plan files in this folder. All 30 queries met
their per-group targets (tightest margin: R04, 236.653 ms of 250 ms). The filled-in
analysis is `docs/05_scalability_report.md`. The zip was available on the project
tracker before the professor's class-wide announcement email (Mon 23 Nov), which is
how the run happened Sunday evening.

## Provenance - what was measured, on which data

| Table | Rows in `large_data.zip` | Rows in `youtube_large` | Match |
|---|---:|---:|---|
| users | 600,000 | 600,000 | yes |
| channels | 60,000 | 60,000 | yes |
| videos | 600,000 | 600,000 | yes |
| subscriptions | 2,598,598 | 2,598,598 | yes |
| watch_events | 4,000,000 | 4,000,000 | yes |
| video_reactions | 1,350,452 | 1,350,452 | yes |
| comments | 1,200,000 | 1,200,000 | yes |
| playlists | 160,000 | 160,000 | yes |
| playlist_items | 1,120,003 | 1,120,003 | yes |
| ad_impressions | 1,139,137 | 1,139,137 | yes |
| **Total** | **12,828,190** | **12,828,190** | **yes** |

SHA-256 of the zip this run used:
`99c96c0cc4f9227bb889bb637320dd2b51b4b1f0fb9fefec7e67706ceb123671`

## How the large-data benchmark is produced (runbook for Adil)

```bash
# 0. on the benchmark laptop (same one used for CP2 and CP3):
cd nosh_DE_2026

# 1. unzip the large dataset into large_data/ next to README.md
unzip large_data.zip -d large_data/
#    -> 10 CSV files, ~20x the seed rows:
#      users ~600,000, channels ~60,000, videos ~600,000, subscriptions ~2,585,000
#      watch_events ~4,000,000, video_reactions ~1,348,000, comments ~1,200,000
#      playlists ~160,000, playlist_items ~1,120,000, ad_impressions ~1,140,000

# 2. create a fresh database, load schema + large data, apply indexes
createdb youtube_large
psql -d youtube_large -f sql/01_schema.sql
#    TEMPORARILY edit sql/02_load_data.sql: change 'seed_data/' to 'large_data/'
#    (do NOT commit that edit - keep 02_load_data.sql pointing at seed_data/)
psql -d youtube_large -f sql/02_load_data.sql
psql -d youtube_large -f sql/05_indexes.sql
#    loading may take several minutes; ANALYZE at the end

# 3. run the optimized workload ONLY (brief forbids the original 30 on large data)
./benchmarks/run_benchmark.sh youtube_large large 3 sql/06_optimized_queries.sql
#    -> writes benchmarks/results/large/summary.csv + R01.txt ... W05.txt

# 4. revert the load-script edit (so 02_load_data.sql still points at seed_data/)
git checkout sql/02_load_data.sql

# 5. commit the results (this commit is Adil's CP4 contribution):
git add benchmarks/results/large/
git commit -m "CP4: large-data benchmark results (optimized workload, 20x seed)"
git push origin main
```

## Targets (from the brief) - to be checked against summary.csv

| Group | Queries | Target (avg of 3 runs) |
| --- | --- | --- |
| Real-time / viewer-facing | R01, R02, R03, R05, R15, R21, W01, W02, W03 | < 5 ms |
| Interactive Studio and search | R04, R06, R07, R08, R09, R13, R14, R24, W05 | < 250 ms |
| Reports and analytics | R10, R11, R12, R16, R17, R18, R19, R20, R22, R23, R25 | < 5,000 ms |
| Batch jobs | W04 | < 2,000 ms |

Any query that misses its target: read the plan, diagnose, fix, show the
before/after plan in `docs/05_scalability_report.md` §3.

## Do NOT commit

- the `large_data/` CSV files (they're .gitignored - the upstream .gitignore excludes them)
- the edited `sql/02_load_data.sql` (revert it with `git checkout` before committing)

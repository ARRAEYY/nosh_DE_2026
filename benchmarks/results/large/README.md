# benchmarks/results/large/ - placeholder (CP4 DE)

**Owner of this commit:** Adil Reyaz (ARRAEY)

**Status:** The `large_data.zip` dataset is released by faculty on **Thu 19 Nov 2026**.
Until then this folder contains only this README. The actual `summary.csv` and raw
plan files will be generated on the benchmark laptop and committed here as soon as
the large dataset is available - well before the Mon 23 Nov CP4 deadline.

## How the large-data benchmark is produced (runbook for Adil)

```bash
# 0. on the benchmark laptop (same one used for CP2 and CP3):
cd nosh_DE_2026

# 1. unzip the large dataset (released Thu 19 Nov) into large_data/ next to README.md
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

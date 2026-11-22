# README - YouTube Video Sharing Database (DE Project 2026)

**Course:** Database Management Systems · **Year:** B.Tech 2nd year · **Team size:** 4
**Database:** PostgreSQL 16.2 · **Final submission:** Mon 23 Nov 2026

## Team

| Role | Name | Enrollment No. | GitHub Username |
| --- | --- | --- | --- |
| Group Lead | Adil Reyaz | 2501010025 | ARRAEYY |
| Member 2 | Utkarsh Singh | 2501010488 | utksh1 |
| Member 3 | Renuka Yadav | 2501010373 | Renuka11aug |
| Member 4 | Shubham | 2501010672 | ShubhamManglaw |

**Team No.:** T0026 · **Section:** _fill_ · **Repository URL:** https://github.com/ARRAEYY/nosh_DE_2026

## Headline numbers

| Phase | Workload total (sum of all 30 query averages) | Notes |
| --- | ---: | --- |
| CP2 - Baseline | **30,987.864 ms** | Schema only (PK/UNIQUE/CHECK), no tuning indexes. R19 alone is ~30.5 s. |
| CP3 - Optimized | **421.867 ms** | 17 tuning indexes + 5 query rewrites. **73x faster.** |
| CP4 - Large data (20x) | **7,783.423 ms** | Optimized workload on the official 20x dataset (12,828,190 rows, 3 runs, avg). All 30 queries inside their per-group targets; slowest was R25 at 1,588.547 ms of 5,000. 18.45x the CP3 total. |

R19 (the intentionally slow partner report) went from 30,450 ms to 96 ms, a 315 times improvement. The fix was rewriting two correlated subqueries into a `CROSS JOIN LATERAL`, so each channel's numbers come from an index lookup instead of a full table scan.

R13 (the creator insights report) was a correctness fix, not just a speedup. The original `NOT IN` silently returned 0 rows for every channel, because 24 of channel 217's watch events have `user_id IS NULL`, and SQL's `NOT IN` never returns TRUE when the list contains a NULL. The `NOT EXISTS` rewrite returns the true 88 rows. This is the wrong-result query the brief warned about.

## How to run

```bash
# 1. load the schema + seed data (one-time, ~10 s)
createdb youtube
psql -d youtube -f sql/01_schema.sql
psql -d youtube -f sql/02_load_data.sql     # prints the row-count table at the end

# 2. baseline benchmark (CP2)
./benchmarks/run_benchmark.sh youtube baseline
#   -> benchmarks/results/baseline/summary.csv + R01.txt ... W05.txt

# 3. apply indexes, benchmark the optimized workload (CP3)
psql -d youtube -f sql/05_indexes.sql
./benchmarks/run_benchmark.sh youtube optimized 5 sql/06_optimized_queries.sql
#   -> benchmarks/results/optimized/summary.csv + raw plans

# 4. large-data benchmark (CP4, after large_data.zip is released)
createdb youtube_large
psql -d youtube_large -f sql/01_schema.sql
#   edit sql/02_load_data.sql: change 'seed_data/' to 'large_data/'
psql -d youtube_large -f sql/02_load_data.sql
psql -d youtube_large -f sql/05_indexes.sql
./benchmarks/run_benchmark.sh youtube_large large 3 sql/06_optimized_queries.sql
#   -> benchmarks/results/large/summary.csv + raw plans

# 5. partitioning demo (CP4)
psql -d youtube -f sql/08_partitioning.sql   # creates watch_events_part + pruning demo
```

## Repository structure

```
nosh_DE_2026/
├── README.md                          # this file
├── team.json                          # team roster (required format)
├── CHECKPOINTS.md                     # upstream checkpoint dates + file lists
├── docs/
│   ├── 01_problem_understanding.md    # CP1 - P1-P9, stakeholders, classification
│   ├── 02_schema_design.md            # CP1 - data dictionary, FDs, ER, integrity checks
│   ├── 03_baseline_timings.md         # CP2 - 30-row timing table + scan analysis
│   ├── 04_optimization_report.md      # CP3 - before/after, proofs, write overhead, storage
│   └── 05_scalability_report.md       # CP4 - large-data results, growth, partitioning, sharding
├── diagrams/
│   └── er_diagram.png                 # CP1 - crow's-foot ER diagram
├── sql/
│   ├── 01_schema.sql                  # CREATE SCHEMA + 10 tables, constraints only
│   ├── 02_load_data.sql               # \copy in FK order + ANALYZE + row-count check
│   ├── 05_indexes.sql                # 17 tuning indexes (Phase 4)
│   ├── 06_optimized_queries.sql       # 30 queries, 5 rewritten (R07, R13, R19, R20, R23)
│   └── 08_partitioning.sql            # watch_events_part RANGE by started_at + pruning demo
├── queries/
│   └── workload_30.sql                # the 30 given queries (do not edit)
└── benchmarks/
    ├── run_benchmark.sh               # timing script (3 or 5 runs, average, raw plans)
    └── results/
        ├── baseline/                  # CP2: summary.csv + R01.txt ... W05.txt
        ├── optimized/                 # CP3: summary.csv + raw plans
        └── large/                     # CP4: summary.csv + raw plans (after large_data)
```

## What each member owns (for CP5 individual analysis)

| Member | Owns at CP5 |
| --- | --- |
| Adil Reyaz | schema (types, composite PKs, FK delete policy), load order + zero-rejection story, `05_indexes.sql` rationale, large-data benchmark |
| Utkarsh Singh | P1-P9 problem mapping, baseline methodology (3 runs, avg, BUFFERS), optimization report numbers, README headline numbers |
| Renuka Yadav | data dictionary, FDs + 3NF/BCNF per table, baseline scan analysis, scalability report |
| Shubham | both ER diagrams (DE + AP), the R13 `NOT IN`+NULL fix, R23 keyset rewrite, partitioning DDL + PK rule |

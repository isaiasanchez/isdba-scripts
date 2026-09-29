# AGENTS.md

PostgreSQL DBA query collection plus a bash runner (`run_query.sh`). There is
no build step, test suite, CI, or package manager — the only way to verify a
change is to run the script against a live PostgreSQL.

## Verifying changes

- Needs `bash` and `psql` on `PATH`. If `psql` is installed but not on PATH
  (Postgres.app): `export PATH="/Applications/Postgres.app/Contents/Versions/latest/bin:$PATH"`
- `./run_query.sh --list`, then run a real query against a scratch database.
  That is the whole verification story — don't go looking for tests or linters.

## Conventions and gotchas

- `run_query.sh` must stay compatible with macOS system bash 3.2: no
  associative arrays, `mapfile`, or other bash 4+ features.
- Two easily confused flags: `-a`/`--all` runs every *query* in `sql/`;
  `-A`/`--all-databases` runs against every *database* in the cluster.
- Adding a query = dropping one `.sql` file into `sql/`; `--list` and `--all`
  pick it up automatically. No registration step.
- The `top10_queries_*` queries require the `pg_stat_statements` extension
  (`shared_preload_libraries`) on the target cluster — they error without it.
- The bloat queries are estimates built on `pg_stats`, so they need current
  `ANALYZE` stats. `table_bloat_check.sql` is documented in-file as approximate
  (±20%) — don't "fix" it casually.
- The password is deliberately not a CLI option (shell-history / `ps`
  leakage): use `PGPASSWORD` or a `~/.pgpass` entry (chmod 600).
- Keep `--no-psqlrc` and `ON_ERROR_STOP=1` on the psql invocations — they make
  reports reproducible and turn SQL errors into failures. One failing query or
  database must not stop the run; the script exits non-zero at the end.
- `reports/` is git-ignored; never commit generated reports.
- Report thresholds live in the SQL `WHERE` clauses. The README's description
  of `index_bloat_check` thresholds is stale — trust the SQL file.
- Commit messages are short and lowercase; no conventional-commit format.

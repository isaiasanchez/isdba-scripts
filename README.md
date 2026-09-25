# isdba-scripts

A small collection of PostgreSQL DBA queries, plus a runner that executes any of
them against one or more databases in a cluster and saves the output as
timestamped text reports — one report per query per database.

```
.
├── run_query.sh          # the runner
├── sql/                  # query files, one .sql per check
│   └── index_bloat_check.sql
└── reports/              # generated reports (git-ignored)
```

## Requirements

- `bash` (works on the macOS system bash 3.2 and on modern bash)
- `psql` on your `PATH` — from PostgreSQL, Postgres.app, or `libpq`

If `psql` is installed but not on your `PATH` (common with Postgres.app):

```bash
export PATH="/Applications/Postgres.app/Contents/Versions/latest/bin:$PATH"
```

## Quick start

```bash
./run_query.sh --list                        # what queries are available?
./run_query.sh -d appdb index_bloat_check    # one query, one database
./run_query.sh -d appdb,billing index_bloat_check   # several databases
./run_query.sh -A index_bloat_check          # every database in the cluster
```

Reports land in `reports/`, named `<query>_<database>_<timestamp>.txt`:

```
reports/index_bloat_check_appdb_20260925_104027.txt
reports/index_bloat_check_billing_20260925_104027.txt
```

## Usage

```
./run_query.sh [options] <query>...
./run_query.sh [options] --all
./run_query.sh --list
```

`<query>` can be a bare name, a file name, or a path — these are equivalent:

```bash
./run_query.sh index_bloat_check
./run_query.sh index_bloat_check.sql
./run_query.sh sql/index_bloat_check.sql
```

Bare names are resolved inside `sql/`, so you can run a check from anywhere:

```bash
cd /somewhere/else
/path/to/isdba-scripts/run_query.sh -d appdb index_bloat_check
```

### Options

| Option | Description |
| --- | --- |
| `-H`, `--host HOST` | Database host (default: `$PGHOST`, else `localhost`) |
| `-p`, `--port PORT` | Database port (default: `$PGPORT`, else `5432`) |
| `-U`, `--user USER` | Database user (default: `$PGUSER`, else your login name) |
| `-d`, `--dbname NAMES` | Database name, or comma-separated list. May be repeated. (default: `$PGDATABASE`) |
| `-F`, `--format FMT` | psql output format: `aligned` (default), `unaligned`, `csv`, `html`, `wrapped` |
| `-a`, `--all` | Run every `.sql` file in `sql/` |
| `-l`, `--list` | List available queries and exit |
| `-q`, `--quiet` | Don't print progress to stdout |
| `-h`, `--help` | Show help and exit |

### Database selection options

| Option | Description |
| --- | --- |
| `-A`, `--all-databases` | Run against every database in the cluster, discovered from `pg_database` |
| `--include-admin` | With `-A`, also include administrative databases (skipped by default) |
| `--exclude REGEX` | With `-A`, skip discovered databases matching this extended regex |
| `-m`, `--maintenance-db N` | Database to connect to for discovery with `-A` |

Note the two different "all" flags: **`-a`/`--all` means all *queries*** in
`sql/`, while **`-A`/`--all-databases` means all *databases*** in the cluster.
They combine — `-a -A` runs every query against every database.

`-A` and `-d` are mutually exclusive; pick either discovery or an explicit list.

## Running across several databases

Three ways to choose what to run against:

```bash
./run_query.sh -d appdb index_bloat_check              # one database
./run_query.sh -d appdb,billing,reporting index_bloat_check   # explicit list
./run_query.sh -d appdb -d billing index_bloat_check   # -d may repeat
./run_query.sh -A index_bloat_check                    # discover them all
```

With nothing specified, the runner uses libpq's own default, so `PGDATABASE` or
a `PGSERVICE` entry still decides which database is used.

### How `-A` discovers databases

`-A` asks the cluster directly:

```sql
SELECT datname FROM pg_database
WHERE datallowconn AND NOT datistemplate
  AND datname NOT IN ('postgres', 'rdsadmin', 'cloudsqladmin', ...)
ORDER BY datname;
```

So it always skips template databases (`template0`, `template1`) and any
database with `datallowconn = false`, since neither can be connected to. It
also skips administrative databases by default — `postgres`, `rdsadmin`,
`azure_maintenance`, `azure_sys`, `cloudsqladmin`, `alloydbadmin`,
`alloydbmetadata` — so a managed-service cluster doesn't produce noise reports.
Add `--include-admin` to keep them:

```bash
./run_query.sh -A --include-admin index_bloat_check
```

Filter further with an extended regex:

```bash
./run_query.sh -A --exclude '^test_' index_bloat_check
./run_query.sh -A --exclude '^(test_|tmp_|.*_old$)' index_bloat_check
```

Discovery needs a database to connect to first. The runner tries `$PGDATABASE`,
then `postgres`, then `template1`. If none of those accept a connection — some
locked-down clusters don't expose `postgres` — name one explicitly:

```bash
./run_query.sh -A -m appdb index_bloat_check
```

### Query × database matrix

`-a` and `-A` combine, producing one report per pair:

```bash
./run_query.sh -a -A -H db.internal -U postgres
```

With 3 queries and 4 databases that's 12 reports, all sharing one timestamp.

### Failures don't stop the run

If one database is unreachable or one query errors, the runner logs it, keeps
going with the rest, and exits non-zero at the end:

```
Running index_bloat_check on appdb ...
Report: reports/index_bloat_check_appdb_20260925_110224.txt
Running index_bloat_check on nosuchdb ...
error: index_bloat_check on nosuchdb failed (psql exit 2); see reports/index_bloat_check_nosuchdb_20260925_110224.txt
Running index_bloat_check on billing ...
Report: reports/index_bloat_check_billing_20260925_110224.txt
Done: 2 report(s) written, 1 failed.
```

Every attempt leaves a report, including the failed one, which contains the
error text.

## Examples

Run a single check against a remote host:

```bash
./run_query.sh -H db.internal -p 5433 -U postgres -d appdb index_bloat_check
```

Run every check in `sql/` in one pass:

```bash
./run_query.sh --all -H db.internal -U postgres -d appdb
```

Run one check across three databases:

```bash
./run_query.sh -H db.internal -U postgres -d appdb,billing,reporting index_bloat_check
```

Run every check against every database in the cluster, skipping scratch ones:

```bash
./run_query.sh --all --all-databases --exclude '^(test_|tmp_)' -H db.internal -U postgres
```

Produce CSV instead of an ASCII table, for loading into a spreadsheet:

```bash
./run_query.sh -F csv -d appdb index_bloat_check
```

Use the standard libpq environment variables instead of flags — handy when you
run several checks against the same database:

```bash
export PGHOST=db.internal PGPORT=5432 PGUSER=postgres PGDATABASE=appdb
./run_query.sh index_bloat_check
./run_query.sh --all
```

Run several named queries in one invocation:

```bash
./run_query.sh -d appdb index_bloat_check some_other_check
```

Quiet mode, for cron or CI where only failures should be noisy:

```bash
./run_query.sh --quiet --all -d appdb
```

A nightly cron entry (note the explicit `PATH`, since cron's is minimal):

```cron
0 2 * * * PATH=/usr/local/bin:/usr/bin:/bin PGHOST=db.internal PGUSER=postgres \
          /path/to/isdba-scripts/run_query.sh --quiet --all --all-databases
```

## Passwords

The password is deliberately **not** a command-line option, so it can't leak
into your shell history or into `ps` output. Use either:

```bash
# per-invocation, via the environment
PGPASSWORD=secret ./run_query.sh -d appdb index_bloat_check
```

or — preferred — a `~/.pgpass` entry with `chmod 600`:

```
db.internal:5432:appdb:postgres:secret
```

Other libpq variables work as usual, including `PGSSLMODE=require` and
`PGSERVICE` if you keep connection definitions in a `pg_service.conf`.

## Reports

Each run writes `reports/<query-name>_<database>_<YYYYMMDD_HHMMSS>.txt`, one
file per query per database. All reports from a single invocation share one
timestamp, so a batch groups together when the directory is sorted by name:

```
index_bloat_check_appdb_20260925_110224.txt
index_bloat_check_billing_20260925_110224.txt
long_running_queries_appdb_20260925_110224.txt
long_running_queries_billing_20260925_110224.txt
```

Database names are reduced to `A-Za-z0-9._-` for the file name, so a database
called `odd name/db` becomes `odd_name_db`; the header keeps the real name.

Every report starts with a header recording how it was produced, so an old file
still makes sense months later:

```
-- query    : /path/to/isdba-scripts/sql/index_bloat_check.sql
-- host     : db.internal
-- port     : 5432
-- database : appdb
-- user     : postgres
-- run at   : 2026-09-25 10:40:27 CEST
--

 database_name | schema_name | table_name | index_name | bloat_pct | bloat_mb | index_mb | table_mb | index_scans
---------------+-------------+------------+------------+-----------+----------+----------+----------+-------------
(0 rows)
```

Reports are git-ignored (`reports/.gitignore`), since they're output rather than
source and may contain details about your databases.

The report directory and the query directory can be relocated with environment
variables, which is useful for shipping reports to a shared location:

```bash
REPORT_DIR=/var/log/pgreports ./run_query.sh --all -d appdb
```

## Exit codes and error handling

| Code | Meaning |
| --- | --- |
| `0` | All queries ran successfully |
| `1` | Unknown option, missing option value, query not found, conflicting flags, or database discovery failed |
| `2` | No query given (usage printed), or `psql` could not connect |
| `3` | `psql` connected but the SQL failed |

Codes `2` and `3` above the usage case are `psql`'s own exit codes, passed
through unchanged. When a run covers several queries or databases, the code
reported is that of the last failure.

Queries run with `ON_ERROR_STOP=1`, so a SQL error aborts that query instead of
writing a half-finished report. `psql`'s stderr is captured *into* the report
file, so a failed run leaves a report explaining what went wrong:

```
psql: error: connection to server on socket "/tmp/.s.PGSQL.5432" failed: No such file or directory
	Is the server running locally and accepting connections on that socket?
```

One failing query or unreachable database doesn't stop the others; the script
works through every target and still exits non-zero so a scheduler notices. A
closing `Done: N report(s) written, M failed.` line summarises any run that
produced more than one report.

Queries also run with `--no-psqlrc`, so a personal `~/.psqlrc` can't change the
formatting of a report.

## Adding a query

Drop a `.sql` file into `sql/` — that's the whole process. It's picked up by
`--list` and by `--all` automatically:

```bash
cat > sql/long_running_queries.sql <<'SQL'
-- sessions running longer than 5 minutes
SELECT pid, now() - query_start AS duration, state, query
FROM pg_stat_activity
WHERE state <> 'idle'
  AND now() - query_start > interval '5 minutes'
ORDER BY duration DESC;
SQL

./run_query.sh -d appdb long_running_queries
```

Keep each file to a single logical check, and add a short comment at the top
describing what it reports.

## Available queries

| Query | Description |
| --- | --- |
| `index_bloat_check` | Estimates bloat for btree indexes; reports indexes over 50% bloat and larger than 10 MB, worst first. Adjust the `WHERE`/`ORDER BY` in the file to change the thresholds. |

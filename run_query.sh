#!/usr/bin/env bash
#
# run_query.sh - run query files from sql/ against one or more PostgreSQL
#                databases in a cluster, writing one timestamped report per
#                (query, database) pair into reports/.
#
# Usage:
#   ./run_query.sh [connection options] <query>
#   ./run_query.sh -d db1,db2 --all
#   ./run_query.sh --all-databases <query>
#   ./run_query.sh --list
#
# The query argument may be the bare name (index_bloat_check), the file name
# (index_bloat_check.sql) or a path to any .sql file.
#
# Connection parameters are taken from the command line first, then from the
# standard libpq environment variables (PGHOST, PGPORT, PGUSER, PGDATABASE,
# PGPASSWORD). The password is never passed on the command line: export
# PGPASSWORD or, preferably, use a ~/.pgpass entry.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="${SQL_DIR:-$SCRIPT_DIR/sql}"
REPORT_DIR="${REPORT_DIR:-$SCRIPT_DIR/reports}"

# Administrative databases skipped by --all-databases unless --include-admin.
ADMIN_DBS="postgres rdsadmin azure_maintenance azure_sys cloudsqladmin alloydbadmin alloydbmetadata"

db_host=""
db_port=""
db_user=""
maint_db=""
exclude_re=""
format="aligned"
run_all_queries=false
all_databases=false
include_admin=false
quiet=false
db_names=()

usage() {
    cat <<'EOF'
Run query files from sql/ against one or more PostgreSQL databases and save the
output under reports/, one report per query per database.

Usage:
  run_query.sh [options] <query>...
  run_query.sh [options] --all
  run_query.sh --list

Arguments:
  <query>                Query name, file name, or path to a .sql file.
                         Bare names are resolved inside the sql/ folder.

Connection options:
  -H, --host HOST        Database host          (default: $PGHOST or localhost)
  -p, --port PORT        Database port          (default: $PGPORT or 5432)
  -U, --user USER        Database user          (default: $PGUSER or $USER)
  -d, --dbname NAMES     Database name, or a comma-separated list of names.
                         May be repeated. (default: $PGDATABASE)

Database selection:
  -A, --all-databases    Run against every database in the cluster, discovered
                         by querying pg_database. Templates and databases that
                         disallow connections are always skipped.
      --include-admin    With -A, also include administrative databases
                         (postgres, rdsadmin, cloudsqladmin, ...), which are
                         skipped by default.
      --exclude REGEX    With -A, skip discovered databases matching this
                         extended regular expression.
  -m, --maintenance-db N Database to connect to for discovery with -A
                         (default: first of $PGDATABASE, postgres, template1
                         that accepts a connection).

Other options:
  -F, --format FORMAT    psql output format: aligned, unaligned, csv, html,
                         wrapped (default: aligned)
  -a, --all              Run every .sql file in sql/
  -l, --list             List the available queries and exit
  -q, --quiet            Do not echo progress to stdout
  -h, --help             Show this help and exit

Reports are named <query>_<database>_<timestamp>.txt. All reports from a single
invocation share one timestamp, so a batch groups together on disk.

The password is read from $PGPASSWORD or ~/.pgpass; it is never accepted as an
argument so it cannot leak into the shell history or the process list.

Examples:
  ./run_query.sh index_bloat_check
  ./run_query.sh -d appdb,billing index_bloat_check
  ./run_query.sh -A --exclude '^test_' --all
  PGPASSWORD=secret ./run_query.sh -H db.internal -U postgres -A -F csv
EOF
}

die() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

log() {
    $quiet || printf '%s\n' "$1"
}

list_queries() {
    local found=false f
    for f in "$SQL_DIR"/*.sql; do
        [[ -e "$f" ]] || continue
        found=true
        printf '  %s\n' "$(basename "$f" .sql)"
    done
    $found || printf '  (no .sql files in %s)\n' "$SQL_DIR"
}

# Turn a user-supplied query argument into a readable path to a .sql file.
resolve_query() {
    local arg="$1" candidate
    for candidate in "$arg" "$arg.sql" "$SQL_DIR/$arg" "$SQL_DIR/$arg.sql"; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# Database names are free-form and may contain characters that are awkward in a
# file name, so reduce them to a safe token for the report file.
sanitize() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# Run a query on one database and print the result as unaligned tuples.
psql_value() {
    local dbname="$1" sql="$2"
    psql ${psql_conn[@]+"${psql_conn[@]}"} --dbname "$dbname" \
        --no-psqlrc --set ON_ERROR_STOP=1 --tuples-only --no-align \
        --command "$sql" 2>/dev/null
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -H|--host)    [[ $# -ge 2 ]] || die "$1 requires a value"; db_host="$2"; shift 2 ;;
        -p|--port)    [[ $# -ge 2 ]] || die "$1 requires a value"; db_port="$2"; shift 2 ;;
        -U|--user)    [[ $# -ge 2 ]] || die "$1 requires a value"; db_user="$2"; shift 2 ;;
        -d|--dbname)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            # Accept a comma-separated list, and allow the flag to repeat.
            IFS=',' read -r -a _split <<<"$2"
            for _name in ${_split[@]+"${_split[@]}"}; do
                [[ -n "$_name" ]] && db_names+=("$_name")
            done
            shift 2 ;;
        -m|--maintenance-db)
                      [[ $# -ge 2 ]] || die "$1 requires a value"; maint_db="$2"; shift 2 ;;
        --exclude)    [[ $# -ge 2 ]] || die "$1 requires a value"; exclude_re="$2"; shift 2 ;;
        -F|--format)  [[ $# -ge 2 ]] || die "$1 requires a value"; format="$2"; shift 2 ;;
        -A|--all-databases|--all-dbs) all_databases=true; shift ;;
        --include-admin) include_admin=true; shift ;;
        -a|--all)     run_all_queries=true; shift ;;
        -q|--quiet)   quiet=true; shift ;;
        -l|--list)    printf 'Available queries in %s:\n' "$SQL_DIR"; list_queries; exit 0 ;;
        -h|--help)    usage; exit 0 ;;
        --)           shift; break ;;
        -*)           die "unknown option: $1 (try --help)" ;;
        *)            break ;;
    esac
done

command -v psql >/dev/null 2>&1 || die "psql not found in PATH"
[[ -d "$SQL_DIR" ]] || die "sql folder not found: $SQL_DIR"

if $all_databases && [[ ${#db_names[@]} -gt 0 ]]; then
    die "--all-databases and --dbname are mutually exclusive"
fi
if ! $all_databases; then
    [[ -z "$exclude_re" ]]  || die "--exclude only applies with --all-databases"
    ! $include_admin || die "--include-admin only applies with --all-databases"
fi

# Collect the queries to run.
queries=()
if $run_all_queries; then
    [[ $# -eq 0 ]] || die "--all does not take a query argument"
    for f in "$SQL_DIR"/*.sql; do
        [[ -e "$f" ]] || continue
        queries+=("$f")
    done
    [[ ${#queries[@]} -gt 0 ]] || die "no .sql files found in $SQL_DIR"
else
    [[ $# -gt 0 ]] || { usage >&2; exit 2; }
    for arg in "$@"; do
        path="$(resolve_query "$arg")" || {
            printf 'error: query not found: %s\n\nAvailable queries in %s:\n' "$arg" "$SQL_DIR" >&2
            list_queries >&2
            exit 1
        }
        queries+=("$path")
    done
fi

# Build the shared psql connection arguments. The database is supplied per
# target below, so it is deliberately not part of this list.
psql_conn=()
[[ -n "$db_host" ]] && psql_conn+=(--host "$db_host")
[[ -n "$db_port" ]] && psql_conn+=(--port "$db_port")
[[ -n "$db_user" ]] && psql_conn+=(--username "$db_user")

# Ask the cluster which databases exist. Templates and databases that refuse
# connections are always excluded; administrative databases are excluded unless
# --include-admin was given.
discover_databases() {
    local sql candidates=() maint out admin_list
    sql="SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate"
    if ! $include_admin; then
        admin_list=$(printf "'%s'," $ADMIN_DBS)
        sql="$sql AND datname NOT IN (${admin_list%,})"
    fi
    sql="$sql ORDER BY datname"

    if [[ -n "$maint_db" ]]; then
        candidates=("$maint_db")
    else
        [[ -n "${PGDATABASE:-}" ]] && candidates+=("$PGDATABASE")
        candidates+=(postgres template1)
    fi

    for maint in "${candidates[@]}"; do
        if out=$(psql_value "$maint" "$sql"); then
            printf '%s\n' "$out"
            return 0
        fi
    done
    return 1
}

# Work out the databases to run against.
databases=()
if $all_databases; then
    log "Discovering databases ..."
    discovered="$(discover_databases)" || {
        if [[ -n "$maint_db" ]]; then
            die "could not list databases via maintenance database '$maint_db'"
        fi
        die "could not list databases (tried ${PGDATABASE:+$PGDATABASE, }postgres, template1); use --maintenance-db"
    }
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        if [[ -n "$exclude_re" ]] && printf '%s' "$name" | grep -Eq "$exclude_re"; then
            log "  skipping $name (matches --exclude)"
            continue
        fi
        databases+=("$name")
    done <<<"$discovered"
    [[ ${#databases[@]} -gt 0 ]] || die "no databases to run against after filtering"
    log "Databases: ${databases[*]}"
elif [[ ${#db_names[@]} -gt 0 ]]; then
    databases=("${db_names[@]}")
else
    # Nothing specified: keep libpq's own default, so a PGSERVICE or PGDATABASE
    # setting still decides. Resolve the name only for labelling the report.
    databases=("")
fi

mkdir -p "$REPORT_DIR"

# One timestamp for the whole invocation, so a batch of reports groups together.
run_ts="$(date +%Y%m%d_%H%M%S)"
run_at="$(date '+%Y-%m-%d %H:%M:%S %Z')"

written=0
failed=0
exit_code=0

for dbname in "${databases[@]}"; do
    # Label used in the report file name and header.
    if [[ -n "$dbname" ]]; then
        db_label="$dbname"
    else
        db_label="$(psql_value "" 'SELECT current_database()')" \
            || db_label="${PGDATABASE:-${db_user:-${PGUSER:-$(id -un)}}}"
        [[ -n "$db_label" ]] || db_label="default"
    fi

    for query_file in "${queries[@]}"; do
        query_name="$(basename "$query_file" .sql)"
        report_file="$REPORT_DIR/${query_name}_$(sanitize "$db_label")_${run_ts}.txt"

        {
            printf -- '-- query    : %s\n' "$query_file"
            printf -- '-- host     : %s\n' "${db_host:-${PGHOST:-localhost}}"
            printf -- '-- port     : %s\n' "${db_port:-${PGPORT:-5432}}"
            printf -- '-- database : %s\n' "$db_label"
            printf -- '-- user     : %s\n' "${db_user:-${PGUSER:-$(id -un)}}"
            printf -- '-- run at   : %s\n' "$run_at"
            printf -- '%s\n\n' '--'
        } >"$report_file"

        log "Running $query_name on $db_label ..."

        # --no-psqlrc keeps a user's ~/.psqlrc from altering the output format.
        # ON_ERROR_STOP makes a SQL error a non-zero exit instead of a partial report.
        if psql \
            ${psql_conn[@]+"${psql_conn[@]}"} \
            ${dbname:+--dbname "$dbname"} \
            --no-psqlrc \
            --set ON_ERROR_STOP=1 \
            --pset "format=$format" \
            --pset "footer=on" \
            --file "$query_file" \
            >>"$report_file" 2>&1
        then
            written=$((written + 1))
            log "Report: $report_file"
        else
            status=$?
            failed=$((failed + 1))
            exit_code=$status
            printf 'error: %s on %s failed (psql exit %s); see %s\n' \
                "$query_name" "$db_label" "$status" "$report_file" >&2
        fi
    done
done

# Only worth summarising when the run covered more than a single report.
if [[ $((written + failed)) -gt 1 ]]; then
    log "Done: $written report(s) written, $failed failed."
fi

exit "$exit_code"

SELECT
    queryid,
    substring(query, 1, 100) AS short_query,
    calls,
    round(total_exec_time::numeric, 2) AS total_time_ms,
    round(mean_exec_time::numeric, 2) AS mean_time_ms,
    round((100 * total_exec_time / sum(total_exec_time) OVER())::numeric, 2) AS pct_of_total,
    rows,
    round((rows::numeric / NULLIF(calls, 0))::numeric, 2) AS rows_per_call,
    round(stddev_exec_time::numeric, 2) AS stddev_time_ms,
    round((shared_blks_hit::numeric / NULLIF(shared_blks_hit + shared_blks_read, 0) * 100), 2) AS cache_hit_pct,
    shared_blks_read,
    shared_blks_dirtied,
    temp_blks_written
FROM pg_stat_statements
WHERE query NOT ILIKE '%pg_stat_statements%'
ORDER BY mean_exec_time DESC
LIMIT 10;

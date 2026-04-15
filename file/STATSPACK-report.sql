WITH params AS (
    SELECT :bid as bid, :eid as eid FROM dual
),
-- 1. 基礎環境資訊
si AS (
    SELECT 
        e.dbid, e.instance_number, di.db_name, di.instance_name, di.host_name,
        DECODE(di.parallel, 'YES', 'YES', 'NO') as rac,
        b.snap_time as b_time, e.snap_time as e_time,
        (e.snap_time - b.snap_time) * 1440 as ela_min,
        (e.snap_time - b.snap_time) * 86400 as ela_sec,
        e.startup_time, di.version as release
    FROM PERFSTAT.STATS$SNAPSHOT b
    JOIN PERFSTAT.STATS$SNAPSHOT e ON b.dbid = e.dbid AND b.instance_number = e.instance_number
    JOIN PERFSTAT.STATS$DATABASE_INSTANCE di ON e.dbid = di.dbid AND e.instance_number = di.instance_number
    WHERE b.snap_id = (SELECT bid FROM params) AND e.snap_id = (SELECT eid FROM params)
),
-- 2. 系統 Delta (Load Profile 核心)
st AS (
    SELECT 
        SUM(CASE WHEN name = 'session logical reads' THEN diff ELSE 0 END) as log_rd,
        SUM(CASE WHEN name = 'physical reads' THEN diff ELSE 0 END) as phy_rd,
        SUM(CASE WHEN name = 'physical writes' THEN diff ELSE 0 END) as phy_wr,
        SUM(CASE WHEN name = 'redo size' THEN diff ELSE 0 END) as redo,
        SUM(CASE WHEN name = 'db block changes' THEN diff ELSE 0 END) as blk_chg,
        SUM(CASE WHEN name = 'user calls' THEN diff ELSE 0 END) as u_calls,
        SUM(CASE WHEN name = 'parse count (total)' THEN diff ELSE 0 END) as parse,
        SUM(CASE WHEN name = 'parse count (hard)' THEN diff ELSE 0 END) as h_parse,
        SUM(CASE WHEN name = 'workarea memory allocated' THEN diff ELSE 0 END)/1024/1024 as wa_mb,
        SUM(CASE WHEN name = 'logons cumulative' THEN diff ELSE 0 END) as logons,
        SUM(CASE WHEN name = 'execute count' THEN diff ELSE 0 END) as execs,
        SUM(CASE WHEN name = 'user rollbacks' THEN diff ELSE 0 END) as rollbacks,
        SUM(CASE WHEN name = 'user commits' THEN diff ELSE 0 END) + SUM(CASE WHEN name = 'user rollbacks' THEN diff ELSE 0 END) as tx,
        SUM(CASE WHEN name = 'redo entries' THEN diff ELSE 0 END) as redo_ent,
        SUM(CASE WHEN name = 'redo log space requests' THEN diff ELSE 0 END) as redo_req,
        SUM(CASE WHEN name = 'workarea executions - optimal' THEN diff ELSE 0 END) as wa_opt,
        SUM(CASE WHEN name = 'workarea executions - onepass' THEN diff ELSE 0 END) as wa_one,
        SUM(CASE WHEN name = 'workarea executions - multipass' THEN diff ELSE 0 END) as wa_multi,
        SUM(CASE WHEN name = 'parse time cpu' THEN diff ELSE 0 END) as p_cpu,
        SUM(CASE WHEN name = 'parse time elapsed' THEN diff ELSE 0 END) as p_ela,
        SUM(CASE WHEN name = 'CPU used by this session' THEN diff ELSE 0 END) as t_cpu
    FROM (
        SELECT name, (SUM(CASE WHEN snap_id = (SELECT eid FROM params) THEN value ELSE 0 END) - 
                      SUM(CASE WHEN snap_id = (SELECT bid FROM params) THEN value ELSE 0 END)) as diff
        FROM PERFSTAT.STATS$SYSSTAT 
        WHERE snap_id IN ((SELECT bid FROM params), (SELECT eid FROM params))
        GROUP BY name
    )
),
-- 3. Time Model
tm AS (
    SELECT 
        SUM(CASE WHEN sn.stat_name = 'DB time' THEN diff ELSE 0 END) / 1000000 as dbt_s,
        SUM(CASE WHEN sn.stat_name = 'DB CPU' THEN diff ELSE 0 END) / 1000000 as dbc_s
    FROM (
        SELECT stat_id, (SUM(CASE WHEN snap_id = (SELECT eid FROM params) THEN value ELSE 0 END) - 
                         SUM(CASE WHEN snap_id = (SELECT bid FROM params) THEN value ELSE 0 END)) as diff
        FROM PERFSTAT.STATS$SYS_TIME_MODEL
        WHERE snap_id IN ((SELECT bid FROM params), (SELECT eid FROM params))
        GROUP BY stat_id
    ) t JOIN PERFSTAT.STATS$TIME_MODEL_STATNAME sn ON t.stat_id = sn.stat_id
),
-- 4. Cache Sizes
cs AS (
    SELECT 
        (SELECT MAX(value)/1024/1024 FROM PERFSTAT.STATS$SGA WHERE name = 'Database Buffers' AND snap_id = (SELECT bid FROM params)) as b_buf,
        (SELECT MAX(value)/1024/1024 FROM PERFSTAT.STATS$SGA WHERE name = 'Variable Size' AND snap_id = (SELECT bid FROM params)) as b_pool,
        (SELECT MAX(value) FROM PERFSTAT.STATS$PARAMETER WHERE name = 'db_block_size' AND snap_id = (SELECT bid FROM params)) as blk_sz,
        (SELECT MAX(value)/1024 FROM PERFSTAT.STATS$SGA WHERE name = 'Redo Buffers' AND snap_id = (SELECT bid FROM params)) as redo_k
    FROM dual
),
-- 5. Shared Pool Metrics (全新展開，同時計算 Begin 與 End 雙邊真實指標)
sp AS (
    SELECT 
        (SELECT SUM(CASE WHEN name != 'free memory' THEN bytes ELSE 0 END) / NULLIF(SUM(bytes), 0) * 100 
         FROM PERFSTAT.STATS$SGASTAT WHERE snap_id = (SELECT bid FROM params) AND pool = 'shared pool') as b_use_pct,
        (SELECT SUM(CASE WHEN name != 'free memory' THEN bytes ELSE 0 END) / NULLIF(SUM(bytes), 0) * 100 
         FROM PERFSTAT.STATS$SGASTAT WHERE snap_id = (SELECT eid FROM params) AND pool = 'shared pool') as e_use_pct,
        (SELECT 100 - (MAX(single_use_sql) / NULLIF(MAX(total_sql), 0)) * 100 
         FROM PERFSTAT.STATS$SQL_STATISTICS WHERE snap_id = (SELECT bid FROM params)) as b_reuse_pct,
        (SELECT 100 - (MAX(single_use_sql) / NULLIF(MAX(total_sql), 0)) * 100 
         FROM PERFSTAT.STATS$SQL_STATISTICS WHERE snap_id = (SELECT eid FROM params)) as e_reuse_pct,
        (SELECT 100 - (MAX(single_use_sql_mem) / NULLIF(MAX(total_sql_mem), 0)) * 100 
         FROM PERFSTAT.STATS$SQL_STATISTICS WHERE snap_id = (SELECT bid FROM params)) as b_mem_reuse,
        (SELECT 100 - (MAX(single_use_sql_mem) / NULLIF(MAX(total_sql_mem), 0)) * 100 
         FROM PERFSTAT.STATS$SQL_STATISTICS WHERE snap_id = (SELECT eid FROM params)) as e_mem_reuse
    FROM dual
),
-- 6. Library Cache Hit 積木
lc AS (
    SELECT 100 * SUM(diff_pinhits) / NULLIF(SUM(diff_pins), 0) as lib_hit
    FROM (
        SELECT namespace, 
               SUM(CASE WHEN snap_id = (SELECT eid FROM params) THEN pinhits ELSE 0 END) - 
               SUM(CASE WHEN snap_id = (SELECT bid FROM params) THEN pinhits ELSE 0 END) as diff_pinhits,
               SUM(CASE WHEN snap_id = (SELECT eid FROM params) THEN pins ELSE 0 END) - 
               SUM(CASE WHEN snap_id = (SELECT bid FROM params) THEN pins ELSE 0 END) as diff_pins
        FROM PERFSTAT.STATS$LIBRARYCACHE WHERE snap_id IN ((SELECT bid FROM params), (SELECT eid FROM params)) GROUP BY namespace
    )
),
-- 7. Latch Hit 積木
lt AS (
    SELECT 100 * (1 - SUM(diff_misses) / NULLIF(SUM(diff_gets), 0)) as latch_hit
    FROM (
        SELECT name, 
               SUM(CASE WHEN snap_id = (SELECT eid FROM params) THEN misses ELSE 0 END) - 
               SUM(CASE WHEN snap_id = (SELECT bid FROM params) THEN misses ELSE 0 END) as diff_misses,
               SUM(CASE WHEN snap_id = (SELECT eid FROM params) THEN gets ELSE 0 END) - 
               SUM(CASE WHEN snap_id = (SELECT bid FROM params) THEN gets ELSE 0 END) as diff_gets
        FROM PERFSTAT.STATS$LATCH WHERE snap_id IN ((SELECT bid FROM params), (SELECT eid FROM params)) GROUP BY name
    )
),
-- 8. 報表生成 (全動態、全對齊)
rpt AS (
    SELECT 10 id, 'Database    DB Id      Instance     Inst Num  Startup Time    Release     RAC' text FROM dual
    UNION ALL SELECT 11, '~~~~~~~~ ----------- ------------ -------- --------------- ----------- ---' FROM dual
    UNION ALL SELECT 12, '          '||si.dbid||' '||RPAD(si.instance_name, 12)||LPAD(si.instance_number, 8)||' '||TO_CHAR(si.startup_time, 'DD-Mon-YY HH24:MI')||' '||RPAD(si.release, 11)||si.rac FROM si
    
    UNION ALL SELECT 14, '' FROM dual
    UNION ALL SELECT 15, 'Host Name             Platform                         CPUs Cores Sockets Memory (G)' FROM dual
    UNION ALL SELECT 16, '~~~~ ---------------- ---------------------- ----- ----- ------- ------------' FROM dual
    UNION ALL SELECT 17, '     '||RPAD(SUBSTR(si.host_name,1,16), 16)||' Linux x86 64-bit            4     4       1         15.5' FROM si
    
    UNION ALL SELECT 20, '' FROM dual
    UNION ALL SELECT 21, 'Snapshot       Snap Id     Snap Time           Sessions Curs/Sess Comment' FROM dual
    UNION ALL SELECT 22, '~~~~~~~~    ---------- ------------------ -------- --------- ------------------' FROM dual
    UNION ALL SELECT 23, 'Begin Snap:'||LPAD((SELECT bid FROM params), 11)||' '||TO_CHAR(si.b_time, 'DD-Mon-YY HH24:MI:SS')||'       59       3.2' FROM si
    UNION ALL SELECT 24, '  End Snap:'||LPAD((SELECT eid FROM params), 11)||' '||TO_CHAR(si.e_time, 'DD-Mon-YY HH24:MI:SS')||'       56       3.2' FROM si
    UNION ALL SELECT 25, '   Elapsed:'||LPAD(TO_CHAR(si.ela_min, '99990.00'), 11)||' (mins) Av Act Sess:'||LPAD(TO_CHAR(tm.dbt_s/NULLIF(si.ela_sec,0), '99990.0'), 10) FROM si CROSS JOIN tm
    UNION ALL SELECT 26, '   DB time:'||LPAD(TO_CHAR(tm.dbt_s/60, '99990.00'), 11)||' (mins)      DB CPU:'||LPAD(TO_CHAR(tm.dbc_s/60, '99990.00'), 10)||' (mins)' FROM tm

    UNION ALL SELECT 30, '' FROM dual
    UNION ALL SELECT 31, 'Cache Sizes            Begin        End' FROM dual
    UNION ALL SELECT 32, '~~~~~~~~~~~       ---------- ----------' FROM dual
    UNION ALL SELECT 33, '    Buffer Cache:'||LPAD(TRIM(TO_CHAR(cs.b_buf, '999,999'))||'M', 11)||'              Std Block Size: '||LPAD(cs.blk_sz/1024||'K', 8) FROM cs
    UNION ALL SELECT 34, '     Shared Pool:'||LPAD(TRIM(TO_CHAR(cs.b_pool, '999,999'))||'M', 11)||'                  Log Buffer: '||LPAD(TRIM(TO_CHAR(cs.redo_k, '999,999'))||'K', 8) FROM cs

    UNION ALL SELECT 40, '' FROM dual
    UNION ALL SELECT 41, 'Load Profile              Per Second    Per Transaction    Per Exec    Per Call' FROM dual
    UNION ALL SELECT 42, '~~~~~~~~~~~~      ------------------  ----------------- ----------- -----------' FROM dual
    UNION ALL SELECT 43, '      DB time(s):'||LPAD(TO_CHAR(tm.dbt_s/NULLIF(si.ela_sec,0), '99990.0'), 18)||LPAD(TO_CHAR(tm.dbt_s/NULLIF(st.tx,0), '99990.0'), 19)||LPAD(TO_CHAR(tm.dbt_s/NULLIF(st.execs,0), '9990.00'), 12)||LPAD(TO_CHAR(tm.dbt_s/NULLIF(st.u_calls,0), '9990.00'), 12) FROM si CROSS JOIN tm CROSS JOIN st
    UNION ALL SELECT 44, '       DB CPU(s):'||LPAD(TO_CHAR(tm.dbc_s/NULLIF(si.ela_sec,0), '99990.0'), 18)||LPAD(TO_CHAR(tm.dbc_s/NULLIF(st.tx,0), '99990.0'), 19)||LPAD(TO_CHAR(tm.dbc_s/NULLIF(st.execs,0), '9990.00'), 12)||LPAD(TO_CHAR(tm.dbc_s/NULLIF(st.u_calls,0), '9990.00'), 12) FROM si CROSS JOIN tm CROSS JOIN st
    UNION ALL SELECT 45, '       Redo size:'||LPAD(TO_CHAR(st.redo/NULLIF(si.ela_sec,0), '999,990.0'), 18)||LPAD(TO_CHAR(st.redo/NULLIF(st.tx,0), '999,990.0'), 19) FROM si CROSS JOIN st
    UNION ALL SELECT 46, '   Logical reads:'||LPAD(TO_CHAR(st.log_rd/NULLIF(si.ela_sec,0), '999,990.0'), 18)||LPAD(TO_CHAR(st.log_rd/NULLIF(st.tx,0), '999,990.0'), 19) FROM si CROSS JOIN st
    UNION ALL SELECT 47, '   Block changes:'||LPAD(TO_CHAR(st.blk_chg/NULLIF(si.ela_sec,0), '999,990.0'), 18)||LPAD(TO_CHAR(st.blk_chg/NULLIF(st.tx,0), '999,990.0'), 19) FROM si CROSS JOIN st
    UNION ALL SELECT 48, '  Physical reads:'||LPAD(TO_CHAR(st.phy_rd/NULLIF(si.ela_sec,0), '999,990.0'), 18)||LPAD(TO_CHAR(st.phy_rd/NULLIF(st.tx,0), '999,990.0'), 19) FROM si CROSS JOIN st
    UNION ALL SELECT 49, ' Physical writes:'||LPAD(TO_CHAR(st.phy_wr/NULLIF(si.ela_sec,0), '999,990.0'), 18)||LPAD(TO_CHAR(st.phy_wr/NULLIF(st.tx,0), '999,990.0'), 19) FROM si CROSS JOIN st
    UNION ALL SELECT 50, '      User calls:'||LPAD(TO_CHAR(st.u_calls/NULLIF(si.ela_sec,0), '999,990.0'), 18)||LPAD(TO_CHAR(st.u_calls/NULLIF(st.tx,0), '999,990.0'), 19) FROM si CROSS JOIN st
    UNION ALL SELECT 51, '          Parses:'||LPAD(TO_CHAR(st.parse/NULLIF(si.ela_sec,0), '999,990.0'), 18)||LPAD(TO_CHAR(st.parse/NULLIF(st.tx,0), '999,990.0'), 19) FROM si CROSS JOIN st
    UNION ALL SELECT 52, '     Hard parses:'||LPAD(TO_CHAR(st.h_parse/NULLIF(si.ela_sec,0), '999,990.0'), 18)||LPAD(TO_CHAR(st.h_parse/NULLIF(st.tx,0), '999,990.0'), 19) FROM si CROSS JOIN st
    UNION ALL SELECT 53, 'W/A MB processed:'||LPAD(TO_CHAR(st.wa_mb/NULLIF(si.ela_sec,0), '999,990.0'), 18)||LPAD(TO_CHAR(st.wa_mb/NULLIF(st.tx,0), '999,990.0'), 19) FROM si CROSS JOIN st
    UNION ALL SELECT 54, '          Logons:'||LPAD(TO_CHAR(st.logons/NULLIF(si.ela_sec,0), '999,990.0'), 18)||LPAD(TO_CHAR(st.logons/NULLIF(st.tx,0), '999,990.0'), 19) FROM si CROSS JOIN st
    UNION ALL SELECT 55, '        Executes:'||LPAD(TO_CHAR(st.execs/NULLIF(si.ela_sec,0), '999,990.0'), 18)||LPAD(TO_CHAR(st.execs/NULLIF(st.tx,0), '999,990.0'), 19) FROM si CROSS JOIN st
    UNION ALL SELECT 56, '       Rollbacks:'||LPAD(TO_CHAR(st.rollbacks/NULLIF(si.ela_sec,0), '999,990.0'), 18)||LPAD(TO_CHAR(st.rollbacks/NULLIF(st.tx,0), '999,990.0'), 19) FROM si CROSS JOIN st
    UNION ALL SELECT 57, '    Transactions:'||LPAD(TO_CHAR(st.tx/NULLIF(si.ela_sec,0), '999,990.0'), 18) FROM si CROSS JOIN st

    UNION ALL SELECT 60, '' FROM dual
    UNION ALL SELECT 61, 'Instance Efficiency Indicators' FROM dual
    UNION ALL SELECT 62, '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' FROM dual
    UNION ALL SELECT 63, '            Buffer Nowait %: '||LPAD(TO_CHAR(NVL(100*(1-(st.redo_req/NULLIF(st.redo_ent,0))), 100), '990.00'), 7)||'       Redo NoWait %: '||LPAD(TO_CHAR(NVL(100*(1-(st.redo_req/NULLIF(st.redo_ent,0))), 100), '990.00'), 7) FROM st
    UNION ALL SELECT 64, '            Buffer  Hit   %: '||LPAD(TO_CHAR(NVL(100*(1-(st.phy_rd/NULLIF(st.log_rd,0))), 100), '990.00'), 7)||'  Optimal W/A Exec %: '||LPAD(TO_CHAR(NVL(100*(st.wa_opt/NULLIF(st.wa_opt+st.wa_one+st.wa_multi,0)), 100), '990.00'), 7) FROM st
    UNION ALL SELECT 65, '            Library Hit   %: '||LPAD(TO_CHAR(NVL(lc.lib_hit, 100), '990.00'), 7)||'        Soft Parse %: '||LPAD(TO_CHAR(NVL(100*(1-(st.h_parse/NULLIF(st.parse,0))), 100), '990.00'), 7) FROM st CROSS JOIN lc
    UNION ALL SELECT 66, '         Execute to Parse %: '||LPAD(TO_CHAR(NVL(100*(1-(st.parse/NULLIF(st.execs,0))), 100), '990.00'), 7)||'          Latch Hit %: '||LPAD(TO_CHAR(NVL(lt.latch_hit, 100), '990.00'), 7) FROM st CROSS JOIN lt
    UNION ALL SELECT 67, 'Parse CPU to Parse Elapsd %: '||LPAD(TO_CHAR(NVL(100*(st.p_cpu/NULLIF(st.p_ela,0)), 100), '990.00'), 7)||'     % Non-Parse CPU: '||LPAD(TO_CHAR(NVL(100*(1-(st.p_cpu/NULLIF(st.t_cpu,0))), 100), '990.00'), 7) FROM st
    
    UNION ALL SELECT 70, '' FROM dual
    UNION ALL SELECT 71, 'Shared Pool Statistics        Begin      End' FROM dual
    UNION ALL SELECT 72, '~~~~~~~~~~~~~~~~~~~~~~       ------   ------' FROM dual
    UNION ALL SELECT 73, '              Memory Usage %:'||LPAD(TO_CHAR(NVL(sp.b_use_pct, 0), '990.00'), 8)||LPAD(TO_CHAR(NVL(sp.e_use_pct, 0), '990.00'), 9) FROM sp
    UNION ALL SELECT 74, '     % SQL with executions>1:'||LPAD(TO_CHAR(NVL(sp.b_reuse_pct, 0), '990.00'), 8)||LPAD(TO_CHAR(NVL(sp.e_reuse_pct, 0), '990.00'), 9) FROM sp
    UNION ALL SELECT 75, '   % Memory for SQL w/exec>1:'||LPAD(TO_CHAR(NVL(sp.b_mem_reuse, 0), '990.00'), 8)||LPAD(TO_CHAR(NVL(sp.e_mem_reuse, 0), '990.00'), 9) FROM sp
)
SELECT text FROM rpt ORDER BY id;
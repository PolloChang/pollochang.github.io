/*
* 
*/
CREATE OR REPLACE PACKAGE pkg_stress_demo IS

    PROCEDURE log_and_pause(P_TEST_ID in NUMERIC,p_name in VARCHAR2, p_status in VARCHAR2,p_desc in NVARCHAR2);

    /*
    * p_loops: 執行循環次數，建議設為 5-10 次以確保持續產生 Log Switch
    */

    PROCEDURE start_storm(p_loops IN NUMBER DEFAULT 5, P_TEST_ID in NUMERIC);
    PROCEDURE start_storm_batch_commit(p_loops IN NUMBER DEFAULT 5,P_BATCH_COMMIT_COUNT IN NUMBER DEFAULT 500, P_TEST_ID in NUMERIC);
    PROCEDURE start_storm_commit_every_time(p_loops IN NUMBER DEFAULT 5, P_TEST_ID in NUMERIC);
    PROCEDURE start_storm_optimized(p_loops IN NUMBER DEFAULT 5, P_TEST_ID in NUMERIC);
    PROCEDURE start_storm_hint(p_loops IN NUMBER DEFAULT 5, P_TEST_ID in NUMERIC);

    PROCEDURE start_ctas(p_loops IN NUMBER DEFAULT 5, P_TEST_ID in NUMERIC);
    PROCEDURE start_ctas_nologging(p_loops IN NUMBER DEFAULT 5, P_TEST_ID in NUMERIC);
    PROCEDURE start_ctas_nologging_paralel(p_loops IN NUMBER DEFAULT 5, P_TEST_ID in NUMERIC);
END pkg_stress_demo;


CREATE OR REPLACE PACKAGE BODY pkg_stress_demo IS

    -- 定義一個內部的 Helper 程序來減少重複代碼
	PROCEDURE log_and_pause(P_TEST_ID in NUMERIC,p_name in VARCHAR2, p_status in VARCHAR2,p_desc in NVARCHAR2) IS
	BEGIN
	    INSERT INTO stress_demo_log(test_id, test_name, status,DESC#) 
	    VALUES (P_TEST_ID, p_name, p_status,p_desc);
	    COMMIT;
	    
	    -- 如果是 stop 狀態，則執行冷卻暫停
	    IF p_status = 'stop' THEN
	    
	        EXECUTE IMMEDIATE  'TRUNCATE TABLE dest_table';
	       
	        DBMS_OUTPUT.PUT_LINE('測試 ' || p_name || ' 完成，進入冷卻期 30 秒...');
	        DBMS_SESSION.SLEEP(30); 
	    END IF;
	END;


    PROCEDURE start_storm(p_loops IN NUMBER DEFAULT 5, P_TEST_ID in NUMERIC) IS
    BEGIN
        DBMS_OUTPUT.ENABLE(1000000);
        pkg_stress_demo.log_and_pause(P_TEST_ID,'start_storm', 'start','=== Redo Storm 實驗開始 ===');

        FOR i IN 1..p_loops LOOP
            pkg_stress_demo.log_and_pause(P_TEST_ID,'start_storm', 'loop-start','Loop ' || i || ' / ' || p_loops || ' 執行中...');

            -----------------------------------------------------
            -- 1. INSERT INTO ... SELECT
            -- 特性：逐筆寫入 Redo Buffer，產生標準 Redo
            -----------------------------------------------------
            INSERT INTO dest_table SELECT * FROM src_data;
            COMMIT; -- 頻繁 Commit 會加劇 LGWR 負擔

            -----------------------------------------------------
            -- 2. DELETE FROM
            -- 特性：產生最大的 Redo 量 (因為要記錄 Before Image 到 Undo)
            -----------------------------------------------------
            DELETE FROM dest_table;
            COMMIT;
            pkg_stress_demo.log_and_pause(P_TEST_ID,'start_storm', 'loop-finish','Loop ' || i || ' / ' || p_loops || ' 執行完畢...');
        END LOOP;

        pkg_stress_demo.log_and_pause(P_TEST_ID,'start_storm', 'stop','=== 實驗結束，請檢查 Alert Log ===');
    END start_storm;
   
    PROCEDURE start_storm_batch_commit(p_loops IN NUMBER DEFAULT 5, P_BATCH_COMMIT_COUNT IN NUMBER DEFAULT 500, P_TEST_ID in NUMERIC) IS

        CURSOR C1 IS SELECT ID,OWNER,OBJECT_NAME,SUBOBJECT_NAME,OBJECT_ID,DATA_OBJECT_ID,OBJECT_TYPE,CREATED,LAST_DDL_TIME,TIMESTAMP,STATUS,TEMPORARY,GENERATED,SECONDARY,NAMESPACE,EDITION_NAME,SHARING,EDITIONABLE,ORACLE_MAINTAINED,APPLICATION,DEFAULT_COLLATION,DUPLICATED,SHARDED,CREATED_APPID,CREATED_VSNID,MODIFIED_APPID,MODIFIED_VSNID FROM src_data;
        CURSOR C2 IS SELECT ID FROM dest_table;
        V_COMMIT NUMBER;

    BEGIN
        DBMS_OUTPUT.ENABLE(1000000);
        pkg_stress_demo.log_and_pause(P_TEST_ID,'start_storm_batch_commit', 'start','=== Redo Storm 實驗開始 ===');

        V_COMMIT := 0;

        FOR i IN 1..p_loops LOOP
            pkg_stress_demo.log_and_pause(P_TEST_ID,'start_storm_batch_commit', 'loop-start','Loop ' || i || ' / ' || p_loops || ' 執行中...');

            -----------------------------------------------------
            -- 1. INSERT INTO ... SELECT
            -- 特性：逐筆寫入 Redo Buffer，產生標準 Redo
            -----------------------------------------------------

            for R1 in c1 LOOP

                INSERT INTO dest_table(ID,OWNER,OBJECT_NAME,SUBOBJECT_NAME,OBJECT_ID,DATA_OBJECT_ID,OBJECT_TYPE,CREATED,LAST_DDL_TIME,TIMESTAMP,STATUS,TEMPORARY,GENERATED,SECONDARY,NAMESPACE,EDITION_NAME,SHARING,EDITIONABLE,ORACLE_MAINTAINED,APPLICATION,DEFAULT_COLLATION,DUPLICATED,SHARDED,CREATED_APPID,CREATED_VSNID,MODIFIED_APPID,MODIFIED_VSNID)
                VALUES
                (r1.ID,r1.OWNER,r1.OBJECT_NAME,r1.SUBOBJECT_NAME,r1.OBJECT_ID,r1.DATA_OBJECT_ID,r1.OBJECT_TYPE,r1.CREATED,r1.LAST_DDL_TIME,r1.TIMESTAMP,r1.STATUS,r1.TEMPORARY,r1.GENERATED,r1.SECONDARY,r1.NAMESPACE,r1.EDITION_NAME,r1.SHARING,r1.EDITIONABLE,r1.ORACLE_MAINTAINED,r1.APPLICATION,r1.DEFAULT_COLLATION,r1.DUPLICATED,r1.SHARDED,r1.CREATED_APPID,r1.CREATED_VSNID,r1.MODIFIED_APPID,r1.MODIFIED_VSNID);

                V_COMMIT := V_COMMIT + 1;

                IF mod(V_COMMIT,P_BATCH_COMMIT_COUNT)  = 0 THEN
                    pkg_stress_demo.log_and_pause(P_TEST_ID,'start_storm_batch_commit', 'insert batch','commit-' || V_COMMIT);
                    COMMIT;                
                END IF;

            end loop;
            COMMIT;
            V_COMMIT := 0;

            -----------------------------------------------------
            -- 2. DELETE FROM
            -- 特性：產生最大的 Redo 量 (因為要記錄 Before Image 到 Undo)
            -----------------------------------------------------
            for R1 in c1 LOOP

                DELETE FROM dest_table T WHERE T.ID = r1.ID;

                V_COMMIT := V_COMMIT + 1;

                IF mod(V_COMMIT,P_BATCH_COMMIT_COUNT)  = 0 THEN
                    pkg_stress_demo.log_and_pause(P_TEST_ID,'start_storm_batch_commit', 'insert batch','commit-' || V_COMMIT);
                    COMMIT;
                END IF;

            END LOOP


            COMMIT;
            pkg_stress_demo.log_and_pause(P_TEST_ID,'start_storm_batch_commit', 'loop-finish','Loop ' || i || ' / ' || p_loops || ' 執行完畢...');
        END LOOP;

        pkg_stress_demo.log_and_pause(P_TEST_ID,'start_storm_batch_commit', 'start','=== 實驗結束，請檢查 Alert Log ===');
    END start_storm_batch_commit;

   
    PROCEDURE start_storm_commit_every_time(p_loops IN NUMBER DEFAULT 5, P_TEST_ID in NUMERIC) IS

        CURSOR C1 IS SELECT ID,OWNER,OBJECT_NAME,SUBOBJECT_NAME,OBJECT_ID,DATA_OBJECT_ID,OBJECT_TYPE,CREATED,LAST_DDL_TIME,TIMESTAMP,STATUS,TEMPORARY,GENERATED,SECONDARY,NAMESPACE,EDITION_NAME,SHARING,EDITIONABLE,ORACLE_MAINTAINED,APPLICATION,DEFAULT_COLLATION,DUPLICATED,SHARDED,CREATED_APPID,CREATED_VSNID,MODIFIED_APPID,MODIFIED_VSNID FROM src_data;
        CURSOR C2 IS SELECT ID FROM dest_table;
        V_COMMIT NUMBER;

    BEGIN
        DBMS_OUTPUT.ENABLE(1000000);
        pkg_stress_demo.log_and_pause(P_TEST_ID,'start_storm_commit_every_time', 'start','=== Redo Storm 實驗開始 ===');

        V_COMMIT := 0;

        FOR i IN 1..p_loops LOOP
            pkg_stress_demo.log_and_pause(P_TEST_ID,'start_storm_commit_every_time', 'loop-start','Loop ' || i || ' / ' || p_loops || ' 執行中...');

            -----------------------------------------------------
            -- 1. INSERT INTO ... SELECT
            -- 特性：逐筆寫入 Redo Buffer，產生標準 Redo
            -----------------------------------------------------

            for R1 in c1 LOOP

                INSERT INTO dest_table(ID,OWNER,OBJECT_NAME,SUBOBJECT_NAME,OBJECT_ID,DATA_OBJECT_ID,OBJECT_TYPE,CREATED,LAST_DDL_TIME,TIMESTAMP,STATUS,TEMPORARY,GENERATED,SECONDARY,NAMESPACE,EDITION_NAME,SHARING,EDITIONABLE,ORACLE_MAINTAINED,APPLICATION,DEFAULT_COLLATION,DUPLICATED,SHARDED,CREATED_APPID,CREATED_VSNID,MODIFIED_APPID,MODIFIED_VSNID)
                VALUES
                (r1.ID,r1.OWNER,r1.OBJECT_NAME,r1.SUBOBJECT_NAME,r1.OBJECT_ID,r1.DATA_OBJECT_ID,r1.OBJECT_TYPE,r1.CREATED,r1.LAST_DDL_TIME,r1.TIMESTAMP,r1.STATUS,r1.TEMPORARY,r1.GENERATED,r1.SECONDARY,r1.NAMESPACE,r1.EDITION_NAME,r1.SHARING,r1.EDITIONABLE,r1.ORACLE_MAINTAINED,r1.APPLICATION,r1.DEFAULT_COLLATION,r1.DUPLICATED,r1.SHARDED,r1.CREATED_APPID,r1.CREATED_VSNID,r1.MODIFIED_APPID,r1.MODIFIED_VSNID);

                COMMIT;

            end loop;

            COMMIT;
            V_COMMIT := 0;

            -----------------------------------------------------
            -- 2. DELETE FROM
            -- 特性：產生最大的 Redo 量 (因為要記錄 Before Image 到 Undo)
            -----------------------------------------------------
            for R1 in c1 LOOP

                DELETE FROM dest_table T WHERE T.ID = r1.ID;

                COMMIT;

            END LOOP

            COMMIT;
            pkg_stress_demo.log_and_pause(P_TEST_ID,'start_storm_commit_every_time', 'loop-finish','Loop ' || i || ' / ' || p_loops || ' 執行完畢...');
        END LOOP;

        pkg_stress_demo.log_and_pause(P_TEST_ID,'start_storm_commit_every_time', 'stop','=== 實驗結束，請檢查 Alert Log ===');
    END start_storm_commit_every_time;
   
    PROCEDURE start_storm_optimized(p_loops IN NUMBER DEFAULT 5, P_TEST_ID in NUMERIC) IS
        TYPE t_data_tab IS TABLE OF src_data%ROWTYPE;
        v_data t_data_tab;
        CURSOR c1 IS SELECT * FROM src_data;
    BEGIN
        DBMS_OUTPUT.ENABLE(1000000);
        pkg_stress_demo.log_and_pause(P_TEST_ID,'start_storm_optimized', 'start','=== Redo Storm 實驗開始 ===');

        FOR i IN 1..p_loops LOOP
            pkg_stress_demo.log_and_pause(P_TEST_ID,'start_storm_optimized', 'loop-start','Loop ' || i || ' / ' || p_loops || ' 執行中...');

            -----------------------------------------------------
            -- 1. INSERT INTO ... SELECT
            -- 特性：逐筆寫入 Redo Buffer，產生標準 Redo
            -----------------------------------------------------
            OPEN c1;
                LOOP
                -- 一次抓取 1000 筆到記憶體 (減少 Context Switch)
                FETCH c1 BULK COLLECT INTO v_data LIMIT 1000;
                    EXIT WHEN v_data.COUNT = 0;
            
                    -- 一次寫入 1000 筆
                    FORALL i IN 1..v_data.COUNT
                    INSERT INTO dest_table VALUES v_data(i);
            
                    -- 每 1000 筆 Commit 一次 (仍會有 log file sync 問題)
                    COMMIT;
                END LOOP;
            CLOSE c1;


            -----------------------------------------------------
            -- 2. DELETE FROM
            -- 特性：產生最大的 Redo 量 (因為要記錄 Before Image 到 Undo)
            -----------------------------------------------------
            DELETE FROM dest_table;
            COMMIT;
            pkg_stress_demo.log_and_pause(P_TEST_ID,'start_storm_optimized', 'loop-finish','Loop ' || i || ' / ' || p_loops || ' 執行完畢...');
        END LOOP;

        pkg_stress_demo.log_and_pause(P_TEST_ID,'start_storm_optimized', 'stop','=== 實驗結束，請檢查 Alert Log ===');
    END start_storm_optimized;
   

    PROCEDURE start_storm_hint(p_loops IN NUMBER DEFAULT 5, P_TEST_ID in NUMERIC) IS
    BEGIN
        DBMS_OUTPUT.ENABLE(1000000);
        pkg_stress_demo.log_and_pause(P_TEST_ID,'start_storm_hint', 'start','=== Redo Storm 實驗開始 ===');

        FOR i IN 1..p_loops LOOP
            pkg_stress_demo.log_and_pause(P_TEST_ID,'start_storm_hint', 'loop-start','Loop ' || i || ' / ' || p_loops || ' 執行中...');

            -----------------------------------------------------
            -- 1. INSERT INTO ... SELECT
            -- 特性：逐筆寫入 Redo Buffer，產生標準 Redo
            -----------------------------------------------------
            INSERT /*+ APPEND */ INTO dest_table NOLOGGING SELECT * FROM src_data;
            COMMIT; -- 頻繁 Commit 會加劇 LGWR 負擔

            -----------------------------------------------------
            -- 2. DELETE FROM
            -- 特性：產生最大的 Redo 量 (因為要記錄 Before Image 到 Undo)
            -----------------------------------------------------
            EXECUTE IMMEDIATE 'TRUNCATE TABLE dest_table';
            COMMIT;
            pkg_stress_demo.log_and_pause(P_TEST_ID,'start_storm_hint', 'loop-finish','Loop ' || i || ' / ' || p_loops || ' 執行完畢...');
        END LOOP;

        pkg_stress_demo.log_and_pause(P_TEST_ID,'start_storm_hint', 'stop','=== 實驗結束，請檢查 Alert Log ===');
    END start_storm_hint;

    PROCEDURE start_ctas(p_loops IN NUMBER DEFAULT 5, P_TEST_ID in NUMERIC) IS
    BEGIN
        DBMS_OUTPUT.ENABLE(1000000);
        pkg_stress_demo.log_and_pause(P_TEST_ID,'start_ctas', 'start','=== Redo Storm 實驗開始 ===');

        FOR i IN 1..p_loops LOOP
            pkg_stress_demo.log_and_pause(P_TEST_ID,'start_ctas', 'loop-start','Loop ' || i || ' / ' || p_loops || ' 執行中...');

            -----------------------------------------------------
            -- 3. CREATE TABLE ... AS SELECT (CTAS)
            -- 特性：預設模式下 (無 NOLOGGING) 會產生大量日誌
            -- 注意：CTAS 是 DDL，自帶 Commit
            -----------------------------------------------------
            -- 先刪除舊表
            BEGIN
                EXECUTE IMMEDIATE 'DROP TABLE temp_ctas_table PURGE';
            EXCEPTION WHEN OTHERS THEN NULL;
            END;
            
            -- 執行 CTAS
            EXECUTE IMMEDIATE 'CREATE TABLE temp_ctas_table AS SELECT * FROM src_data';
            
            -- 清理
            EXECUTE IMMEDIATE 'DROP TABLE temp_ctas_table PURGE';
            pkg_stress_demo.log_and_pause(P_TEST_ID,'start_ctas', 'loop-finish','Loop ' || i || ' / ' || p_loops || ' 執行完畢...');
        END LOOP;

        pkg_stress_demo.log_and_pause(P_TEST_ID,'start_ctas', 'start','=== 實驗結束，請檢查 Alert Log ===');
    END start_ctas;


    PROCEDURE start_ctas_nologging(p_loops IN NUMBER DEFAULT 5, P_TEST_ID in NUMERIC) IS
    BEGIN
        DBMS_OUTPUT.ENABLE(1000000);
        pkg_stress_demo.log_and_pause(P_TEST_ID,'start_ctas_nologging', 'start','=== Redo Storm 實驗開始 ===');

        FOR i IN 1..p_loops LOOP
            pkg_stress_demo.log_and_pause(P_TEST_ID,'start_ctas_nologging', 'loop-start','Loop ' || i || ' / ' || p_loops || ' 執行中...');

            -----------------------------------------------------
            -- 3. CREATE TABLE ... AS SELECT (CTAS)
            -- 特性：預設模式下 (無 NOLOGGING) 會產生大量日誌
            -- 注意：CTAS 是 DDL，自帶 Commit
            -----------------------------------------------------
            -- 先刪除舊表
            BEGIN
                EXECUTE IMMEDIATE 'DROP TABLE temp_ctas_table PURGE';
            EXCEPTION WHEN OTHERS THEN NULL;
            END;
            
            -- 執行 CTAS
            EXECUTE IMMEDIATE 'CREATE TABLE temp_ctas_table NOLOGGING AS SELECT * FROM src_data';
            
            -- 清理
            EXECUTE IMMEDIATE 'DROP TABLE temp_ctas_table PURGE';
            pkg_stress_demo.log_and_pause(P_TEST_ID,'start_ctas_nologging', 'loop-finish','Loop ' || i || ' / ' || p_loops || ' 執行完畢...');
        END LOOP;

        pkg_stress_demo.log_and_pause(P_TEST_ID,'start_ctas_nologging', 'stop','=== 實驗結束，請檢查 Alert Log ===');
    END start_ctas_nologging;


    PROCEDURE start_ctas_nologging_paralel(p_loops IN NUMBER DEFAULT 5, P_TEST_ID in NUMERIC) IS
    BEGIN
        DBMS_OUTPUT.ENABLE(1000000);
        pkg_stress_demo.log_and_pause(P_TEST_ID,'start_ctas_nologging_paralel', 'start','=== Redo Storm 實驗開始 ===');

        FOR i IN 1..p_loops LOOP
            pkg_stress_demo.log_and_pause(P_TEST_ID,'start_storm_hint', 'loop-start','Loop ' || i || ' / ' || p_loops || ' 執行中...');

            -----------------------------------------------------
            -- 3. CREATE TABLE ... AS SELECT (CTAS)
            -- 特性：預設模式下 (無 NOLOGGING) 會產生大量日誌
            -- 注意：CTAS 是 DDL，自帶 Commit
            -----------------------------------------------------
            -- 先刪除舊表
            BEGIN
                EXECUTE IMMEDIATE 'DROP TABLE temp_ctas_table PURGE';
            EXCEPTION WHEN OTHERS THEN NULL;
            END;
            
            -- 執行 CTAS
            EXECUTE IMMEDIATE 'CREATE TABLE temp_ctas_table NOLOGGING PARALLEL 4 AS SELECT /*+ PARALLEL(4) */ * FROM src_data';
            
            -- 清理
            EXECUTE IMMEDIATE 'DROP TABLE temp_ctas_table PURGE';


            pkg_stress_demo.log_and_pause(P_TEST_ID,'start_ctas_nologging_paralel', 'loop-finish','Loop ' || i || ' / ' || p_loops || ' 執行完畢...');
        END LOOP;

        pkg_stress_demo.log_and_pause(P_TEST_ID,'start_ctas_nologging_paralel', 'start','=== 實驗結束，請檢查 Alert Log ===');
    END start_ctas_nologging_paralel;

END pkg_stress_demo;


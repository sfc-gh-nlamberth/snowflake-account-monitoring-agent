-- =============================================================================
-- ACCOUNT MONITORING AGENT DEMO — Setup Script
-- =============================================================================
-- Creates a Cortex Agent that answers natural language questions about
-- Snowflake query performance and credit consumption by querying
-- SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY via a Cortex Analyst semantic view.
-- A Cortex Search tool backed by the official Snowflake documentation is also
-- wired in so the agent can answer "how-to" and conceptual questions.
--
-- Objects created:
--   Role      ACCOUNT_MONITORING_AGENT_ROLE
--   Database  ACCOUNT_MONITORING_AGENT_DEMO
--   Schema    ACCOUNT_MONITORING_AGENT_DEMO.PUBLIC
--   Warehouse ACCOUNT_MONITORING_AGENT_WH
--   Resource monitor  ACCOUNT_MONITORING_AGENT_RM
--   Semantic view     ACCOUNT_MONITORING_AGENT_DEMO.PUBLIC.QUERY_HISTORY_MONITORING
--   Agent     ACCOUNT_MONITORING_AGENT_DEMO.PUBLIC.ACCOUNT_MONITORING_AGENT
--   Budget    ACCOUNT_MONITORING_AGENT_DEMO.PUBLIC.ACCOUNT_MONITORING_AGENT_BUDGET
--
-- Prerequisites:
--   1. You must be able to use the ACCOUNTADMIN role.
--   2. The Snowflake Documentation Cortex Knowledge Extension must be installed
--      from the Marketplace BEFORE running this script. See Step 0 below.
--   3. Your Snowflake user email must be verified if you want budget alert emails.
-- =============================================================================


-- =============================================================================
-- STEP 0: INSTALL THE SNOWFLAKE DOCUMENTATION KNOWLEDGE EXTENSION (MANUAL)
-- =============================================================================
-- This step must be completed in Snowsight BEFORE running the SQL below.
--
-- The agent's "snowflake_docs" tool is backed by a Cortex Search service
-- distributed by Snowflake on the Marketplace as a Cortex Knowledge Extension
-- (CKE). It contains ~57,000 indexed chunks from docs.snowflake.com and lets
-- the agent answer how-to, syntax, and best-practice questions.
--
-- To install:
--   1. Log in to Snowsight and navigate to:
--      Data Products → Marketplace
--   2. Search for "Snowflake Documentation" (provider: Snowflake) or go to:
--      https://app.snowflake.com/marketplace/listing/GZSTZ67BY9OQ4
--   3. Click "Get".
--   4. When prompted for the local database name, enter: SNOWFLAKE_DOCUMENTATION
--      (the CREATE AGENT statement below references this exact name)
--   5. Under "Who can access this database?" select at least
--      ACCOUNT_MONITORING_AGENT_ROLE (or grant access after creation — see Step 4).
--   6. Click "Get" to complete the installation.
--
-- The Cortex Search service will be available at:
--   SNOWFLAKE_DOCUMENTATION.SHARED.CKE_SNOWFLAKE_DOCS_SERVICE
--
-- If you choose a different local database name, update the tool_resources
-- section in the CREATE AGENT statement (Step 9) to match.
-- =============================================================================


-- =============================================================================
-- STEP 1: SET CONTEXT AND CREATE THE DEMO ROLE
-- =============================================================================
-- We start as ACCOUNTADMIN because creating resource monitors, granting
-- system-level database roles (e.g. SNOWFLAKE.ACCOUNT_USAGE_VIEWER), and
-- attaching resource monitors to warehouses all require account-level authority.
-- We hand off ownership to a dedicated demo role so day-to-day operations
-- don't need ACCOUNTADMIN.

USE ROLE ACCOUNTADMIN;

-- Create a dedicated role. Using a purpose-built role (rather than SYSADMIN)
-- makes it easy to audit, revoke, or replicate this demo.
CREATE ROLE IF NOT EXISTS ACCOUNT_MONITORING_AGENT_ROLE
  COMMENT = 'Owner role for the Account Monitoring Agent demo objects';

-- Attach the role to the standard role hierarchy so SYSADMIN and ACCOUNTADMIN
-- can still operate on its objects if needed.
GRANT ROLE ACCOUNT_MONITORING_AGENT_ROLE TO ROLE SYSADMIN;


-- =============================================================================
-- STEP 2: CREATE THE DATABASE AND SCHEMA
-- =============================================================================
-- All demo objects live in one database with a single PUBLIC schema.
-- Ownership is transferred to the demo role so subsequent steps can run
-- without ACCOUNTADMIN (except where noted).

CREATE DATABASE IF NOT EXISTS ACCOUNT_MONITORING_AGENT_DEMO
  COMMENT = 'Demo database for the Snowflake Account Monitoring Cortex Agent';

CREATE SCHEMA IF NOT EXISTS ACCOUNT_MONITORING_AGENT_DEMO.PUBLIC;

-- Transfer ownership so the demo role can create objects in this schema.
GRANT OWNERSHIP ON DATABASE ACCOUNT_MONITORING_AGENT_DEMO
  TO ROLE ACCOUNT_MONITORING_AGENT_ROLE COPY CURRENT GRANTS;

GRANT OWNERSHIP ON SCHEMA ACCOUNT_MONITORING_AGENT_DEMO.PUBLIC
  TO ROLE ACCOUNT_MONITORING_AGENT_ROLE COPY CURRENT GRANTS;


-- =============================================================================
-- STEP 3: GRANT REQUIRED PRIVILEGES TO THE DEMO ROLE
-- =============================================================================
-- These grants must come from ACCOUNTADMIN because they involve system-level
-- database roles and cross-database access.

-- ACCOUNT_USAGE_VIEWER is the least-privilege Snowflake database role that
-- grants SELECT on SNOWFLAKE.ACCOUNT_USAGE views, including QUERY_HISTORY.
-- This is what powers the agent's query_history tool.
GRANT DATABASE ROLE SNOWFLAKE.ACCOUNT_USAGE_VIEWER
  TO ROLE ACCOUNT_MONITORING_AGENT_ROLE;

-- BUDGET_CREATOR is a Snowflake database role that allows creating budget
-- instances (SNOWFLAKE.CORE.BUDGET) in schemas where CREATE SNOWFLAKE.CORE.BUDGET
-- has also been granted. Both grants are required.
GRANT DATABASE ROLE SNOWFLAKE.BUDGET_CREATOR
  TO ROLE ACCOUNT_MONITORING_AGENT_ROLE;

GRANT CREATE SNOWFLAKE.CORE.BUDGET
  ON SCHEMA ACCOUNT_MONITORING_AGENT_DEMO.PUBLIC
  TO ROLE ACCOUNT_MONITORING_AGENT_ROLE;

-- Grant access to the Snowflake Documentation database created in Step 0.
-- IMPORTED PRIVILEGES allows the role to query all objects inside the
-- shared/imported database, including the Cortex Search service.
GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE_DOCUMENTATION
  TO ROLE ACCOUNT_MONITORING_AGENT_ROLE;


-- =============================================================================
-- STEP 4: CREATE THE DEDICATED WAREHOUSE
-- =============================================================================
-- A dedicated X-Small warehouse keeps the agent's compute costs isolated and
-- easy to govern. Key settings:
--   AUTO_SUSPEND = 60s   — minimises idle credit burn; the agent resumes it on demand
--   ENABLE_QUERY_ACCELERATION — improves latency for selective ACCOUNT_USAGE queries
--   MAX_SCALE_FACTOR = 2 — allows the warehouse to scale out up to 2x when busy,
--                          but caps unbounded scaling costs

USE ROLE ACCOUNTADMIN;

CREATE WAREHOUSE IF NOT EXISTS ACCOUNT_MONITORING_AGENT_WH
  WAREHOUSE_SIZE                   = 'X-Small'
  AUTO_SUSPEND                     = 60
  AUTO_RESUME                      = TRUE
  ENABLE_QUERY_ACCELERATION        = TRUE
  QUERY_ACCELERATION_MAX_SCALE_FACTOR = 2
  COMMENT = 'Dedicated warehouse for ACCOUNT_MONITORING_AGENT — governed by ACCOUNT_MONITORING_AGENT_RM resource monitor';

-- Transfer ownership to the demo role, then grant APPLYBUDGET so the role
-- can attach this warehouse to the budget created in Step 8.
GRANT OWNERSHIP ON WAREHOUSE ACCOUNT_MONITORING_AGENT_WH
  TO ROLE ACCOUNT_MONITORING_AGENT_ROLE COPY CURRENT GRANTS;

GRANT APPLYBUDGET ON WAREHOUSE ACCOUNT_MONITORING_AGENT_WH
  TO ROLE ACCOUNT_MONITORING_AGENT_ROLE;


-- =============================================================================
-- STEP 5: CREATE THE RESOURCE MONITOR
-- =============================================================================
-- Resource monitors are account-level objects and must be created by ACCOUNTADMIN.
-- This monitor enforces a hard daily credit cap on the warehouse to prevent
-- runaway cost from unexpected query bursts.
--
-- Trigger behaviour:
--   75%  NOTIFY          — sends an alert email to the monitor's notify users
--   100% SUSPEND         — gracefully suspends the warehouse (active queries finish)
--   110% SUSPEND_IMMEDIATE — kills active queries and suspends immediately
--
-- NOTE: To receive email alerts, add your verified email address to
-- NOTIFY_USERS in the statement below. Multiple users can be listed
-- comma-separated: NOTIFY_USERS = ('user1', 'user2')

CREATE RESOURCE MONITOR IF NOT EXISTS ACCOUNT_MONITORING_AGENT_RM
  WITH
    CREDIT_QUOTA    = 17
    FREQUENCY       = DAILY
    START_TIMESTAMP = IMMEDIATELY
    -- NOTIFY_USERS = ('<your_snowflake_username>')   -- uncomment and fill in
    TRIGGERS
      ON 75  PERCENT DO NOTIFY
      ON 100 PERCENT DO SUSPEND
      ON 110 PERCENT DO SUSPEND_IMMEDIATE;

-- Attach the resource monitor to the dedicated warehouse. This is an ACCOUNTADMIN
-- operation even though the warehouse is owned by the demo role.
ALTER WAREHOUSE ACCOUNT_MONITORING_AGENT_WH
  SET RESOURCE_MONITOR = ACCOUNT_MONITORING_AGENT_RM;


-- =============================================================================
-- STEP 6: SWITCH TO THE DEMO ROLE FOR REMAINING OBJECT CREATION
-- =============================================================================
-- All remaining objects (semantic view, agent, budget) are owned by the demo
-- role. Switching here ensures the ownership is correct from the start.

USE ROLE      ACCOUNT_MONITORING_AGENT_ROLE;
USE DATABASE  ACCOUNT_MONITORING_AGENT_DEMO;
USE SCHEMA    PUBLIC;
USE WAREHOUSE ACCOUNT_MONITORING_AGENT_WH;


-- =============================================================================
-- STEP 7: CREATE THE QUERY_HISTORY_MONITORING SEMANTIC VIEW
-- =============================================================================
-- Cortex Analyst (the text-to-SQL engine behind the agent's query_history tool)
-- uses this semantic view instead of querying the raw table directly. The semantic
-- view does three things:
--
--   1. Curates columns — exposes only the metrics and dimensions relevant to
--      performance monitoring so the LLM doesn't get confused by irrelevant columns.
--
--   2. Defines derived facts — PARTITION_SCAN_RATIO, TOTAL_SPILL_BYTES, and
--      EXECUTION_EFFICIENCY_RATIO are computed expressions, not raw columns.
--      Defining them here means the agent can reference them by name without
--      knowing the underlying formula.
--
--   3. Enriches with synonyms and comments — each fact and dimension has a
--      COMMENT and SYNONYMS so the LLM maps natural language ("how long did it
--      take?") to the right column (TOTAL_ELAPSED_TIME).
--
--   4. Pre-verifies golden queries — the AI_VERIFIED_QUERIES section contains
--      hand-verified SQL for the most common monitoring patterns. Cortex Analyst
--      will prefer these over generating new SQL, improving accuracy and consistency.

CREATE OR REPLACE SEMANTIC VIEW QUERY_HISTORY_MONITORING
  TABLES (
    SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  )
  FACTS (
    QUERY_HISTORY.TOTAL_ELAPSED_TIME
      AS TOTAL_ELAPSED_TIME
      WITH SYNONYMS = ('elapsed time', 'wall clock time', 'total duration ms', 'how long did it take')
      COMMENT = 'Total wall-clock time from start to finish in milliseconds. Includes queuing, compilation, and execution.',

    QUERY_HISTORY.EXECUTION_TIME
      AS EXECUTION_TIME
      WITH SYNONYMS = ('compute time', 'pure execution ms', 'execution duration')
      COMMENT = 'Pure compute/execution time in milliseconds, excluding queuing and compilation.',

    QUERY_HISTORY.COMPILATION_TIME
      AS COMPILATION_TIME
      WITH SYNONYMS = ('parse time', 'compile duration ms')
      COMMENT = 'Time spent compiling the query in milliseconds. High values indicate very complex or highly dynamic SQL.',

    QUERY_HISTORY.QUEUED_OVERLOAD_TIME
      AS QUEUED_OVERLOAD_TIME
      WITH SYNONYMS = ('queue time', 'overload queue ms', 'warehouse queue time')
      COMMENT = 'Time in milliseconds the query spent waiting in the warehouse queue due to warehouse overload.',

    QUERY_HISTORY.BYTES_SCANNED
      AS BYTES_SCANNED
      WITH SYNONYMS = ('bytes read', 'data scanned', 'scan volume bytes')
      COMMENT = 'Number of bytes scanned from storage. Primary indicator of large table scans.',

    QUERY_HISTORY.PERCENTAGE_SCANNED_FROM_CACHE
      AS PERCENTAGE_SCANNED_FROM_CACHE
      WITH SYNONYMS = ('cache hit rate', 'cache percentage', 'local cache ratio')
      COMMENT = 'Fraction (0.0-1.0) of scanned bytes served from the warehouse local disk cache. Higher is better.',

    QUERY_HISTORY.PARTITIONS_SCANNED
      AS PARTITIONS_SCANNED
      WITH SYNONYMS = ('micro-partitions scanned', 'partitions read')
      COMMENT = 'Number of micro-partitions scanned by the query.',

    QUERY_HISTORY.PARTITIONS_TOTAL
      AS PARTITIONS_TOTAL
      WITH SYNONYMS = ('total micro-partitions', 'total partitions in tables')
      COMMENT = 'Total number of micro-partitions across all tables referenced in the query.',

    QUERY_HISTORY.BYTES_SPILLED_TO_LOCAL_STORAGE
      AS BYTES_SPILLED_TO_LOCAL_STORAGE
      WITH SYNONYMS = ('local spill bytes', 'local disk spill')
      COMMENT = 'Bytes spilled to local warehouse storage due to insufficient memory. Non-zero values indicate memory pressure.',

    QUERY_HISTORY.BYTES_SPILLED_TO_REMOTE_STORAGE
      AS BYTES_SPILLED_TO_REMOTE_STORAGE
      WITH SYNONYMS = ('remote spill bytes', 'remote disk spill', 'S3 spill')
      COMMENT = 'Bytes spilled to remote (cloud) storage. More expensive than local spill and a strong indicator the warehouse is undersized.',

    QUERY_HISTORY.CREDITS_USED_CLOUD_SERVICES
      AS CREDITS_USED_CLOUD_SERVICES
      WITH SYNONYMS = ('cloud services credits', 'credit cost', 'credits consumed')
      COMMENT = 'Cloud services credits consumed by this query. Does not include warehouse compute credits.',

    -- Derived: ratio of partitions actually scanned vs total available.
    -- 1.0 = full table scan (no pruning). 0.0 = perfectly pruned.
    QUERY_HISTORY.PARTITION_SCAN_RATIO
      AS PARTITIONS_SCANNED / NULLIF(PARTITIONS_TOTAL, 0)
      WITH SYNONYMS = ('pruning ratio', 'scan ratio', 'partition pruning efficiency')
      COMMENT = 'Fraction of micro-partitions actually scanned vs total. Values near 1.0 mean poor pruning. Values near 0.0 mean effective pruning.',

    -- Derived: sum of both spill destinations.
    QUERY_HISTORY.TOTAL_SPILL_BYTES
      AS BYTES_SPILLED_TO_LOCAL_STORAGE + BYTES_SPILLED_TO_REMOTE_STORAGE
      WITH SYNONYMS = ('total spill', 'combined spill', 'all spill bytes')
      COMMENT = 'Total bytes spilled to either local or remote storage. Non-zero values indicate the query exceeded warehouse memory.',

    -- Derived: fraction of elapsed time spent in actual execution.
    -- Low values mean most time was spent in the queue or compiler.
    QUERY_HISTORY.EXECUTION_EFFICIENCY_RATIO
      AS EXECUTION_TIME / NULLIF(TOTAL_ELAPSED_TIME, 0)
      WITH SYNONYMS = ('execution fraction', 'compute vs elapsed ratio', 'time spent executing')
      COMMENT = 'Fraction of total elapsed time spent in actual execution. Low values indicate the query spent most time queuing or compiling.',

    -- Derived: human-readable elapsed time in seconds instead of milliseconds.
    QUERY_HISTORY.TOTAL_ELAPSED_TIME_SECONDS
      AS TOTAL_ELAPSED_TIME / 1000.0
      WITH SYNONYMS = ('elapsed seconds', 'duration seconds', 'runtime seconds')
      COMMENT = 'Total elapsed time converted to seconds for readability.'
  )
  DIMENSIONS (
    QUERY_HISTORY.QUERY_ID
      AS QUERY_ID
      WITH SYNONYMS = ('query identifier', 'query hash id')
      COMMENT = 'Internal system-generated unique identifier for the SQL statement. Use to link to Query Profile.',

    QUERY_HISTORY.QUERY_TEXT
      AS QUERY_TEXT
      WITH SYNONYMS = ('sql text', 'sql statement', 'query string')
      COMMENT = 'The full SQL text of the statement (truncated at 100K characters).',

    QUERY_HISTORY.QUERY_TYPE
      AS QUERY_TYPE
      WITH SYNONYMS = ('statement type', 'dml type')
      COMMENT = 'Type of SQL statement — SELECT, INSERT, UPDATE, DELETE, MERGE, etc.',

    QUERY_HISTORY.QUERY_PARAMETERIZED_HASH
      AS QUERY_PARAMETERIZED_HASH
      WITH SYNONYMS = ('query pattern', 'parameterized hash', 'query fingerprint')
      COMMENT = 'Hash of the canonicalized, parameterized SQL. Groups queries with the same logical shape regardless of literal values.',

    QUERY_HISTORY.USER_NAME
      AS USER_NAME
      WITH SYNONYMS = ('user', 'username', 'who ran it')
      COMMENT = 'Snowflake user who issued the query.',

    QUERY_HISTORY.ROLE_NAME
      AS ROLE_NAME
      WITH SYNONYMS = ('role', 'active role')
      COMMENT = 'Role active in the session when the query was executed.',

    QUERY_HISTORY.WAREHOUSE_NAME
      AS WAREHOUSE_NAME
      WITH SYNONYMS = ('warehouse', 'compute warehouse')
      COMMENT = 'Warehouse the query executed on.',

    QUERY_HISTORY.WAREHOUSE_SIZE
      AS WAREHOUSE_SIZE
      WITH SYNONYMS = ('warehouse size', 'compute size', 'node size')
      COMMENT = 'Size of the warehouse at the time of execution (X-Small, Small, Medium, Large, X-Large, etc.).',

    QUERY_HISTORY.EXECUTION_STATUS
      AS EXECUTION_STATUS
      WITH SYNONYMS = ('status', 'query status', 'outcome')
      COMMENT = 'Execution outcome — success, fail, or incident.',

    QUERY_HISTORY.ERROR_CODE
      AS ERROR_CODE
      WITH SYNONYMS = ('error code', 'failure code')
      COMMENT = 'Snowflake error code if the query failed. NULL for successful queries.',

    QUERY_HISTORY.ERROR_MESSAGE
      AS ERROR_MESSAGE
      WITH SYNONYMS = ('error message', 'failure reason', 'error detail')
      COMMENT = 'Error message text if the query failed (truncated at 5K characters).',

    QUERY_HISTORY.START_TIME
      AS START_TIME
      WITH SYNONYMS = ('start time', 'query start', 'execution start')
      COMMENT = 'Timestamp when the query started (local time zone). Primary time column for filtering.',

    QUERY_HISTORY.END_TIME
      AS END_TIME
      WITH SYNONYMS = ('end time', 'query end', 'completion time')
      COMMENT = 'Timestamp when the query completed.'
  )
  COMMENT = 'Semantic model for monitoring and troubleshooting Snowflake query history. Surfaces consumption-heavy queries by tracking scan volume, spill, partition pruning efficiency, queuing, credit usage, and elapsed time per query, user, warehouse, and query pattern hash. Source is SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY (up to 365 days of history, ~45-minute latency).'
  AI_VERIFIED_QUERIES (
    -- Pre-verified SQL for common monitoring questions. Cortex Analyst will
    -- prefer these over generating new SQL, improving accuracy and consistency.

    SLOWEST_QUERIES_LAST_7_DAYS AS (
      QUESTION 'What are the slowest queries in the last 7 days?'
      SQL 'SELECT QUERY_ID, USER_NAME, WAREHOUSE_NAME, WAREHOUSE_SIZE,
                  TOTAL_ELAPSED_TIME, BYTES_SCANNED,
                  BYTES_SPILLED_TO_REMOTE_STORAGE, CREDITS_USED_CLOUD_SERVICES,
                  QUERY_TEXT
             FROM query_history
            WHERE START_TIME >= DATEADD(DAY, -7, CURRENT_TIMESTAMP())
              AND EXECUTION_STATUS = ''success''
            ORDER BY TOTAL_ELAPSED_TIME DESC
            LIMIT 25'
    ),

    WORST_PARTITION_PRUNING_LAST_7_DAYS AS (
      QUESTION 'Which queries from the past week have the worst partition pruning efficiency?'
      SQL 'SELECT QUERY_ID, USER_NAME, WAREHOUSE_NAME, BYTES_SCANNED,
                  PARTITIONS_SCANNED, PARTITIONS_TOTAL,
                  ROUND(PARTITIONS_SCANNED / NULLIF(PARTITIONS_TOTAL, 0), 4) AS partition_scan_ratio,
                  QUERY_TEXT
             FROM query_history
            WHERE START_TIME >= DATEADD(DAY, -7, CURRENT_TIMESTAMP())
              AND PARTITIONS_TOTAL > 0
              AND EXECUTION_STATUS = ''success''
            ORDER BY partition_scan_ratio DESC
            LIMIT 25'
    ),

    MOST_REMOTE_SPILL_LAST_7_DAYS AS (
      QUESTION 'Which queries spilled the most data to remote storage in the last 7 days?'
      SQL 'SELECT QUERY_ID, USER_NAME, WAREHOUSE_NAME,
                  BYTES_SPILLED_TO_REMOTE_STORAGE, BYTES_SPILLED_TO_LOCAL_STORAGE,
                  EXECUTION_TIME, QUERY_TEXT
             FROM query_history
            WHERE START_TIME >= DATEADD(DAY, -7, CURRENT_TIMESTAMP())
              AND BYTES_SPILLED_TO_REMOTE_STORAGE > 0
              AND EXECUTION_STATUS = ''success''
            ORDER BY BYTES_SPILLED_TO_REMOTE_STORAGE DESC
            LIMIT 25'
    ),

    HEAVIEST_QUERY_PATTERNS_LAST_30_DAYS AS (
      QUESTION 'Which query patterns consumed the most total data scanned in the last 30 days?'
      SQL 'SELECT QUERY_PARAMETERIZED_HASH,
                  COUNT(*)                        AS execution_count,
                  AVG(TOTAL_ELAPSED_TIME)         AS avg_elapsed_ms,
                  MAX(TOTAL_ELAPSED_TIME)         AS max_elapsed_ms,
                  SUM(BYTES_SCANNED)              AS total_bytes_scanned,
                  SUM(CREDITS_USED_CLOUD_SERVICES) AS total_credits,
                  ANY_VALUE(QUERY_TEXT)           AS sample_query_text
             FROM query_history
            WHERE START_TIME >= DATEADD(DAY, -30, CURRENT_TIMESTAMP())
              AND EXECUTION_STATUS = ''success''
            GROUP BY QUERY_PARAMETERIZED_HASH
            ORDER BY total_bytes_scanned DESC
            LIMIT 25'
    ),

    TOP_CREDIT_USERS_BY_WAREHOUSE_LAST_7_DAYS AS (
      QUESTION 'Which users and warehouses used the most cloud services credits in the last 7 days?'
      SQL 'SELECT USER_NAME, WAREHOUSE_NAME,
                  COUNT(*)                              AS query_count,
                  SUM(TOTAL_ELAPSED_TIME) / 1000.0     AS total_elapsed_seconds,
                  SUM(BYTES_SCANNED)                    AS total_bytes_scanned,
                  SUM(CREDITS_USED_CLOUD_SERVICES)      AS total_credits
             FROM query_history
            WHERE START_TIME >= DATEADD(DAY, -7, CURRENT_TIMESTAMP())
              AND EXECUTION_STATUS = ''success''
            GROUP BY USER_NAME, WAREHOUSE_NAME
            ORDER BY total_credits DESC
            LIMIT 25'
    ),

    MOST_QUEUED_QUERIES_LAST_7_DAYS AS (
      QUESTION 'Which queries spent the most time queued due to warehouse overload in the past week?'
      SQL 'SELECT QUERY_ID, USER_NAME, WAREHOUSE_NAME,
                  QUEUED_OVERLOAD_TIME, TOTAL_ELAPSED_TIME,
                  ROUND(QUEUED_OVERLOAD_TIME / NULLIF(TOTAL_ELAPSED_TIME, 0), 4) AS queue_fraction,
                  QUERY_TEXT
             FROM query_history
            WHERE START_TIME >= DATEADD(DAY, -7, CURRENT_TIMESTAMP())
              AND QUEUED_OVERLOAD_TIME > 0
              AND EXECUTION_STATUS = ''success''
            ORDER BY QUEUED_OVERLOAD_TIME DESC
            LIMIT 25'
    ),

    LOW_EXECUTION_EFFICIENCY_LAST_7_DAYS AS (
      QUESTION 'Which queries in the last 7 days spent most of their time queuing or compiling rather than executing?'
      SQL 'SELECT QUERY_ID, USER_NAME, WAREHOUSE_NAME,
                  ROUND(TOTAL_ELAPSED_TIME / 1000.0, 2)  AS total_elapsed_seconds,
                  ROUND(EXECUTION_TIME / 1000.0, 2)      AS execution_seconds,
                  ROUND(QUEUED_OVERLOAD_TIME / 1000.0, 2) AS queue_seconds,
                  ROUND(COMPILATION_TIME / 1000.0, 2)    AS compile_seconds,
                  ROUND(EXECUTION_EFFICIENCY_RATIO, 3)   AS execution_efficiency_ratio,
                  QUERY_TEXT
             FROM query_history
            WHERE START_TIME >= DATEADD(DAY, -7, CURRENT_TIMESTAMP())
              AND EXECUTION_STATUS = ''success''
              AND TOTAL_ELAPSED_TIME >= 5000
              AND EXECUTION_EFFICIENCY_RATIO < 0.5
            ORDER BY TOTAL_ELAPSED_TIME DESC
            LIMIT 25'
    ),

    MOST_FAILING_QUERY_PATTERNS_LAST_7_DAYS AS (
      QUESTION 'Which query patterns failed the most times in the last 7 days, and what errors are they producing?'
      SQL 'SELECT QUERY_PARAMETERIZED_HASH, ERROR_CODE,
                  ANY_VALUE(ERROR_MESSAGE)  AS sample_error_message,
                  COUNT(*)                  AS failure_count,
                  ANY_VALUE(USER_NAME)      AS sample_user,
                  ANY_VALUE(WAREHOUSE_NAME) AS sample_warehouse,
                  ANY_VALUE(QUERY_TEXT)     AS sample_query_text
             FROM query_history
            WHERE START_TIME >= DATEADD(DAY, -7, CURRENT_TIMESTAMP())
              AND EXECUTION_STATUS = ''fail''
            GROUP BY QUERY_PARAMETERIZED_HASH, ERROR_CODE
            ORDER BY failure_count DESC
            LIMIT 25'
    ),

    TOP_OPTIMIZATION_CANDIDATES_LAST_7_DAYS AS (
      QUESTION 'Which queries combine poor partition pruning with significant spill and are the top candidates for optimization?'
      SQL 'SELECT QUERY_ID, USER_NAME, WAREHOUSE_NAME,
                  ROUND(PARTITION_SCAN_RATIO, 3)               AS partition_scan_ratio,
                  PARTITIONS_SCANNED, PARTITIONS_TOTAL,
                  ROUND(TOTAL_SPILL_BYTES / 1073741824.0, 2)  AS total_spill_gb,
                  ROUND(BYTES_SCANNED / 1073741824.0, 2)       AS bytes_scanned_gb,
                  ROUND(TOTAL_ELAPSED_TIME_SECONDS, 2)         AS elapsed_seconds,
                  QUERY_TEXT
             FROM query_history
            WHERE START_TIME >= DATEADD(DAY, -7, CURRENT_TIMESTAMP())
              AND EXECUTION_STATUS = ''success''
              AND PARTITIONS_TOTAL > 0
              AND TOTAL_SPILL_BYTES > 0
              AND PARTITION_SCAN_RATIO > 0.5
            ORDER BY TOTAL_SPILL_BYTES DESC
            LIMIT 25'
    )
  );


-- =============================================================================
-- STEP 8: CREATE THE CORTEX AGENT
-- =============================================================================
-- The agent is defined using a YAML specification inside a $$ ... $$ block.
-- Key sections:
--
--   instructions.response
--     The system prompt. Defines the agent's persona, scope, tool-selection
--     logic, data caveats, and response formatting rules.
--
--   tools
--     Two tools are registered:
--       query_history  — cortex_analyst_text_to_sql backed by the semantic view
--       snowflake_docs — cortex_search backed by the Snowflake Documentation CKE
--
--   tool_resources
--     Maps each tool name to its backing object (semantic view or search service).
--     Update these FQNs if you used different database/schema names.

CREATE OR REPLACE AGENT ACCOUNT_MONITORING_AGENT
  COMMENT = 'An account monitoring agent that checks Snowflake query history for long-running or expensive queries.'
  FROM SPECIFICATION
  $$
  orchestration:
    instructions:
      response: |
        ## Role
        You are the Snowflake Account Monitoring Assistant — a technical analyst for Snowflake account
        administrators and data platform engineers who need to investigate query performance issues,
        identify consumption hotspots, and understand Snowflake platform behavior.

        ## Scope
        You answer questions about:
        - Query performance (elapsed time, execution time, queuing, compilation)
        - Data scan efficiency (bytes scanned, cache hit rate, partition pruning)
        - Memory pressure and spill (local and remote storage spill)
        - Credit consumption at the query, user, warehouse, and pattern level
        - Failed queries and error diagnosis
        - Snowflake platform concepts, configuration, SQL syntax, and best practices

        ## Domain Context
        - All query history data comes from SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY with approximately
          45-minute latency. Data is NOT real-time. If a user asks about queries from the last few
          minutes, clarify this lag.
        - History covers up to 365 days. Default to the last 7 days unless the user specifies otherwise.
        - CREDITS_USED_CLOUD_SERVICES reflects cloud services credits only, not warehouse compute credits.
          Warehouse compute credits are tracked in WAREHOUSE_METERING_HISTORY, which is NOT available here.
        - PARTITION_SCAN_RATIO near 1.0 means poor pruning (full scan). Near 0.0 means effective pruning.
          Values above 0.5 are worth investigating.
        - BYTES_SPILLED_TO_REMOTE_STORAGE is a stronger signal of warehouse undersizing than local spill.

        ## Tool Selection Logic
        - Use **query_history** for any question that requires querying or aggregating data: slowest
          queries, top users by credit, spill analysis, failed queries, query pattern trends, partition
          pruning efficiency, warehouse load.
        - Use **snowflake_docs** for any conceptual or how-to question: what a feature does, how to
          configure something, SQL syntax, best practices, troubleshooting guidance, feature availability.
        - For questions that mix both (e.g. "why is this query slow and how do I fix it?"), call
          query_history first to retrieve the data, then call snowflake_docs for optimization guidance.

        ## Limitations
        - No access to warehouse compute credits (only cloud services credits per query).
        - No access to real-time query data — minimum ~45-minute lag.
        - No access to Snowflake billing, contract pricing, or dollar amounts.
        - No data outside ACCOUNT_USAGE.QUERY_HISTORY (no user management, storage metrics, pipe/task history).
        - Do NOT extrapolate or predict future consumption. Report historical data only.

        ## Response Format
        - Lead with the direct answer or key finding, then provide supporting data.
        - Use tables for any result with more than 3 rows.
        - Use bold for metric names and key values when inline in text.
        - Report time durations in seconds — e.g. "12.4s" not "12,400ms".
        - Report byte volumes in MB or GB — e.g. "2.3 GB" not "2,300,000,000 bytes".
        - Always include units: seconds, GB, credits, %.
        - When presenting query history results, include: "Data reflects queries up to ~45 minutes ago."
        - After presenting data, add 1-3 concise observations highlighting the most actionable findings.
        - When a question is outside the available data, say so clearly and suggest where to find it.

      sample_questions:
        - question: "In the last 24 hours, which queries combine poor partition pruning with significant spill and what recommendations would you make?"

  tools:
    - tool_spec:
        type: cortex_analyst_text_to_sql
        name: query_history
        description: |
          Queries and aggregates Snowflake query execution history to surface performance issues,
          consumption hotspots, and usage patterns. Source is SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
          with up to 365 days of history and ~45-minute latency.

          Metrics: elapsed_time, execution_time, compilation_time, queued_overload_time,
                   bytes_scanned, cache_hit_rate, partitions_scanned, partitions_total,
                   partition_scan_ratio, local_spill, remote_spill, total_spill,
                   credits_used_cloud_services, execution_efficiency_ratio.

          Dimensions: query_id, query_text, query_type, query_parameterized_hash,
                      user_name, role_name, warehouse_name, warehouse_size,
                      execution_status, error_code, error_message, start_time, end_time.

          Use for: slowest queries, spill analysis, pruning efficiency, credit consumption,
                   failed queries, warehouse queue time, query pattern trends.
          Do NOT use for: warehouse compute credits, storage metrics, real-time data.

    - tool_spec:
        type: cortex_search
        name: snowflake_docs
        description: |
          Searches the official Snowflake documentation (~57,000 indexed chunks from docs.snowflake.com).
          Covers SQL reference, feature guides, architecture, security, performance tuning,
          connectors, Snowpark, Cortex AI, and more.

          Use for: feature explanations, SQL syntax, configuration how-tos, performance best practices,
                   error code lookup, optimization guidance after retrieving query data.
          Do NOT use for: questions requiring actual account data, unreleased features.

  tool_resources:
    query_history:
      semantic_view: ACCOUNT_MONITORING_AGENT_DEMO.PUBLIC.QUERY_HISTORY_MONITORING
    snowflake_docs:
      name: SNOWFLAKE_DOCUMENTATION.SHARED.CKE_SNOWFLAKE_DOCS_SERVICE
      max_results: "5"
  $$;


-- =============================================================================
-- STEP 9: CREATE THE BUDGET
-- =============================================================================
-- Budgets are instances of the SNOWFLAKE.CORE.BUDGET class. They track monthly
-- credit consumption for a set of linked objects and send email alerts when
-- projected spend is expected to exceed the monthly spending limit.
--
-- The spending limit here (510 credits) is set to ~30x the daily resource
-- monitor limit (17 credits/day × 30 days), giving the budget a full-month view
-- while the resource monitor enforces the per-day hard cap.
--
-- To enable email notifications, create a notification integration and register
-- it with the budget after creation (see the commented block below).

CREATE SNOWFLAKE.CORE.BUDGET IF NOT EXISTS ACCOUNT_MONITORING_AGENT_BUDGET ()
  COMMENT = 'Monthly credit budget for the Account Monitoring Agent dedicated warehouse';

-- Set the monthly spending limit (in credits).
CALL ACCOUNT_MONITORING_AGENT_BUDGET!SET_SPENDING_LIMIT(510);

-- Attach the dedicated warehouse so the budget tracks its compute spend.
-- SYSTEM$REFERENCE creates a scoped reference to the warehouse object.
CALL ACCOUNT_MONITORING_AGENT_BUDGET!ADD_RESOURCE(
  SYSTEM$REFERENCE('WAREHOUSE', 'ACCOUNT_MONITORING_AGENT_WH', 'SESSION', 'APPLYBUDGET')
);

-- To receive budget alert emails, uncomment the block below after creating a
-- notification integration. The integration must have USAGE granted to the
-- SNOWFLAKE application.
--
-- USE ROLE ACCOUNTADMIN;
-- CREATE NOTIFICATION INTEGRATION IF NOT EXISTS BUDGETS_NOTIFICATION_INTEGRATION
--   TYPE            = EMAIL
--   ENABLED         = TRUE
--   ALLOWED_RECIPIENTS = ('<your_verified_email@example.com>');
--
-- GRANT USAGE ON INTEGRATION BUDGETS_NOTIFICATION_INTEGRATION
--   TO APPLICATION SNOWFLAKE;
--
-- USE ROLE ACCOUNT_MONITORING_AGENT_ROLE;
-- CALL ACCOUNT_MONITORING_AGENT_DEMO.PUBLIC.ACCOUNT_MONITORING_AGENT_BUDGET!ADD_NOTIFICATION_INTEGRATION(
--   'BUDGETS_NOTIFICATION_INTEGRATION'
-- );


-- =============================================================================
-- STEP 10: GRANT ACCESS TO CONSUMERS
-- =============================================================================
-- Grant the minimum privileges needed for a user to call the agent via the
-- REST API or Snowsight. Adjust the target role as appropriate for your org.

USE ROLE ACCOUNTADMIN;

GRANT USAGE ON DATABASE ACCOUNT_MONITORING_AGENT_DEMO
  TO ROLE SYSADMIN;

GRANT USAGE ON SCHEMA ACCOUNT_MONITORING_AGENT_DEMO.PUBLIC
  TO ROLE SYSADMIN;

GRANT USAGE ON AGENT ACCOUNT_MONITORING_AGENT_DEMO.PUBLIC.ACCOUNT_MONITORING_AGENT
  TO ROLE SYSADMIN;

GRANT USAGE ON WAREHOUSE ACCOUNT_MONITORING_AGENT_WH
  TO ROLE SYSADMIN;


-- =============================================================================
-- VERIFICATION
-- =============================================================================
-- Run the statements below to confirm everything was created correctly.

SHOW WAREHOUSES         LIKE 'ACCOUNT_MONITORING_AGENT_WH';
SHOW RESOURCE MONITORS  LIKE 'ACCOUNT_MONITORING_AGENT_RM';
SHOW AGENTS             IN SCHEMA ACCOUNT_MONITORING_AGENT_DEMO.PUBLIC;

USE ROLE ACCOUNT_MONITORING_AGENT_ROLE;
SHOW SNOWFLAKE.CORE.BUDGET IN SCHEMA ACCOUNT_MONITORING_AGENT_DEMO.PUBLIC;

-- Confirm the budget spending limit and linked resources:
-- CALL ACCOUNT_MONITORING_AGENT_DEMO.PUBLIC.ACCOUNT_MONITORING_AGENT_BUDGET!GET_SPENDING_LIMIT();
-- CALL ACCOUNT_MONITORING_AGENT_DEMO.PUBLIC.ACCOUNT_MONITORING_AGENT_BUDGET!GET_LINKED_RESOURCES();

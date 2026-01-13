--  Copyright 2021 Google Inc.

--  Licensed under the Apache License, Version 2.0 (the "License");
--  you may not use this file except in compliance with the License.
--  You may obtain a copy of the License at

--      http://www.apache.org/licenses/LICENSE-2.0

--  Unless required by applicable law or agreed to in writing, software
--  distributed under the License is distributed on an "AS IS" BASIS,
--  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
--  See the License for the specific language governing permissions and
--  limitations under the License.

-- Changed by: Uladzislau Pralat
-- Changed on: 13 Jan 2026
-- Changes: Implemented CORTEX_S4_RAW partition pruning optimization to cut cost and improve performance.   

DECLARE recordstamp_from TIMESTAMP;                                                        -- partition pruning optimization   
DECLARE recordstamp_to TIMESTAMP;                                                          -- partition pruning optimization 
SET recordstamp_from = (SELECT IFNULL(MAX(recordstamp), TIMESTAMP('0001-01-01 00:00:00'))  -- partition pruning optimization
                        FROM `${target_table}`);                                           -- partition pruning optimization
SET recordstamp_to   = (SELECT IFNULL(MAX(recordstamp), TIMESTAMP('9999-12-31 23:59:59'))  -- partition pruning optimization
                        FROM `${base_table}`);                                             -- partition pruning optimization

MERGE `${target_table}` AS T
USING (
  WITH
    -- All the rows that arrived in raw table after the latest CDC table refresh.
    NewRawRecords AS (
      SELECT * FROM `${base_table}`
--    WHERE recordstamp >= (                                                               -- partition pruning optimization
--      SELECT IFNULL(MAX(recordstamp), TIMESTAMP('3940-12-25 05:30:00+00'))               -- partition pruning optimization
      WHERE recordstamp >= recordstamp_from                                                -- partition pruning optimization  
        AND DATE(recordstamp) BETWEEN DATE(recordstamp_from) AND DATE(recordstamp_to)      -- partition pruning optimization
        FROM `${target_table}`)        
      AND ${primary_keys_not_null_clause}
    )
    -- For each unique record (by primary key), find chronologically latest row. This ensures CDC
    -- table only contains one entry for a unique record.
    -- This also handles the conditions where SLT connector may have introduced true duplicate
    -- rows (same recordstamp).
    SELECT *
    FROM NewRawRecords
    QUALIFY
      ROW_NUMBER() OVER (
        PARTITION BY ${primary_keys}
        ORDER BY
          recordstamp DESC,
          IF(operation_flag = 'D', 'ZZ', operation_flag) DESC -- Prioritize "D" flag within the dups.
      ) = 1
  ) AS S
ON ${primary_keys_join_clause}
-- ## CORTEX-CUSTOMER You can use "is_deleted = true" condition along with "operation_flag = 'D'",
-- if that is applicable to your CDC set up.
WHEN NOT MATCHED AND IFNULL(S.operation_flag, 'I') != 'D' THEN
  INSERT (${fields})
  VALUES (${fields})
WHEN MATCHED AND S.operation_flag = 'D' THEN
  DELETE
-- 'L' flag is also included to account for post possible pipeline reconfiguration.
WHEN MATCHED AND S.operation_flag IN ('I','U','L') THEN
  UPDATE SET ${update_fields};


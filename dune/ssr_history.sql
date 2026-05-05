-- Dune query 7425009 — https://dune.com/queries/7425009
-- Name: SSR Rate History — sUSDS file() boundaries
--
-- SSR rate boundaries from SP-BEAM file() calls on sUSDS.
--
-- Reads `file(bytes32("ssr"), uint256)` traces on sUSDS (0xa3931d71...fbD).
-- The 4-byte selector for file(bytes32,uint256) is 0x29ae8114.
-- The first arg is the bytes32 key; for SSR it is bytes32("ssr") =
--   0x7373720000000000000000000000000000000000000000000000000000000000.
-- The new rate sits at offset 37 = 4 (selector) + 32 (key) + 1; raw value is
-- RAY-scaled (1e27) per-second growth factor.
--
-- Output:
--   effective_date          UTC date the rate became effective
--   rate_per_second_ray     RAY-scaled per-second growth factor (1e27 = 1.0)
--   ssr_apy                 (rate_per_second_ray/1e27)^31536000 - 1
--
-- Sparse: only days that contain at least one file() call appear.
-- Forward-fill downstream when joining to balances on arbitrary dates.
--
-- Parameters:
--   start_date  text  'YYYY-MM-DD' lower bound (default 2024-09-01)

WITH file_calls AS (
  SELECT
    tr.block_time,
    tr.block_date,
    CAST(bytearray_to_uint256(substr(tr.input, 37, 32)) AS DOUBLE) AS rate_per_second_ray
  FROM ethereum.traces tr
  WHERE tr."to"          = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD
    AND substr(tr.input, 1, 4) = 0x29ae8114  -- file(bytes32, uint256)
    AND substr(tr.input, 5, 32) = 0x7373720000000000000000000000000000000000000000000000000000000000
    AND tr.success    = true
    AND tr.block_date >= DATE '{{start_date}}'
),
-- Multiple file() calls can land on the same UTC day. Keep only the
-- chronologically last call per day — that is the rate in effect at end-of-day.
deduped AS (
  SELECT
    block_date,
    rate_per_second_ray,
    ROW_NUMBER() OVER (PARTITION BY block_date ORDER BY block_time DESC) AS rn
  FROM file_calls
)
SELECT
  block_date         AS effective_date,
  rate_per_second_ray,
  POWER(rate_per_second_ray / 1e27, 31536000) - 1 AS ssr_apy
FROM deduped
WHERE rn = 1
ORDER BY block_date

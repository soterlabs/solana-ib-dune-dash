-- Dune query 7429781 — https://dune.com/queries/7429781
-- Name: USDS Solana Boost — weekly history
--
-- Per-partner weekly USDS Integration Boost over a rolling 12-week window
-- (12 most recently completed Mon→Sun UTC weeks). Methodology mirrors
-- query 7433459 (current + past week):
--   * Anchor balance from `stablecoins_solana.balances` for the day before
--     the window start (treated as end-of-day = start-of-window).
--   * Per-hour TWAP balance reconstructed via cumulative USDS transfers.
--   * Intra-day SSR APY via `ethereum.traces` `file()` calls on the SSR pot,
--     deduped to last call per day, looked up at hour-start.
--   * Linear formula:  hourly_boost = balance × ssr_apy / 8760.
--   * Keel Pioneer = total_solana_usds_supply − Σ tracked_partner_balances.

WITH
partner_addresses(partner, lookup_address) AS (
  VALUES
    ('kamino',       '9DrvZvyWh1HuAoZxvYWMvkf2XCzryCpGgHqrMjyDWpmo'),
    ('maple',        '6QbtpY2jDNcncRFmVf343NThnCdaY8gCAsYATPnYQR9g'),
    ('onre',         'FsvTiXTUFDc4aLbrov4PrvDTjXCWCniL1dxTUkZ1T2ss'),
    ('huma',         'B5WhxpGmV5BfJnRBpB93dMSePHtttFySJ4dcAZ9YzYYc'),
    ('juplend',      '7s1da8DduuBFqGra5bJBjpnvL5E9mGzCuMk1Qkh4or2Z'),
    ('onre_reserve', '45YnzauhsBM8CpUz96Djf8UG5vqq2Dua62wuW9H3jaJ5'),
    ('huma_reserve', '6q76D2fJxPqzQQfUBMmkb2MzT4Vg7VGe2dgXHKd33ad2')
),

windows AS (
  SELECT
    CAST(DATE_TRUNC('week', CURRENT_DATE) - INTERVAL '84' DAY AS TIMESTAMP) AS history_start,
    CAST(DATE_TRUNC('week', CURRENT_DATE)                    AS TIMESTAMP) AS history_end
),

calendar_hours AS (
  SELECT (SELECT history_start FROM windows) + (h * INTERVAL '1' HOUR) AS hr
  FROM UNNEST(SEQUENCE(0, 12 * 7 * 24 - 1)) AS t(h)
),

ssr_raw AS (
  SELECT
    CAST(tr.block_time AS TIMESTAMP)         AS block_time,
    DATE(tr.block_time AT TIME ZONE 'UTC')   AS effective_date,
    CAST(bytearray_to_uint256(substr(tr.input, 37, 32)) AS DOUBLE) AS rps_ray
  FROM ethereum.traces tr
  WHERE tr."to"     = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD
    AND substr(tr.input, 1, 4)  = 0x29ae8114
    AND substr(tr.input, 5, 32) = 0x7373720000000000000000000000000000000000000000000000000000000000
    AND tr.success    = true
    AND tr.block_date >= DATE '2024-09-01'
),
ssr_deduped AS (
  SELECT block_time, rps_ray,
         ROW_NUMBER() OVER (PARTITION BY effective_date ORDER BY block_time DESC) AS rn
  FROM ssr_raw
),
ssr_boundaries AS (
  SELECT block_time AS effective_time,
         POWER(rps_ray / 1e27, 31536000) - 1 AS ssr_apy
  FROM ssr_deduped
  WHERE rn = 1
),

ssr_lookup AS (
  SELECT ch.hr, MAX(b.effective_time) AS last_boundary
  FROM calendar_hours ch
  LEFT JOIN ssr_boundaries b ON b.effective_time <= ch.hr
  GROUP BY ch.hr
),
ssr_hourly AS (
  SELECT sl.hr, sb.ssr_apy
  FROM ssr_lookup sl
  LEFT JOIN ssr_boundaries sb ON sb.effective_time = sl.last_boundary
),

partner_anchor AS (
  SELECT pa.partner,
         COALESCE(b.balance, 0) AS anchor_balance
  FROM partner_addresses pa
  LEFT JOIN stablecoins_solana.balances b
    ON b.address      = pa.lookup_address
   AND b.token_symbol = 'USDS'
   AND b.day          = CAST((SELECT history_start FROM windows) - INTERVAL '1' DAY AS DATE)
),

partner_transfers AS (
  SELECT
    pa.partner,
    CAST(t.block_time AS TIMESTAMP) AS block_time,
    CASE
      WHEN t.from_owner = pa.lookup_address AND t.to_owner = pa.lookup_address THEN 0.0
      WHEN t.from_owner = pa.lookup_address THEN -CAST(t.amount AS DOUBLE)
      WHEN t.to_owner   = pa.lookup_address THEN  CAST(t.amount AS DOUBLE)
    END AS delta
  FROM partner_addresses pa
  JOIN stablecoins_solana.transfers t
    ON (t.from_owner = pa.lookup_address OR t.to_owner = pa.lookup_address)
   AND t.token_symbol = 'USDS'
   AND t.block_month >= DATE_TRUNC('month',
                                   CAST((SELECT history_start FROM windows) AS DATE))
   AND t.block_date  >= CAST((SELECT history_start FROM windows) AS DATE)
   AND t.block_date  <  CAST((SELECT history_end FROM windows) AS DATE)
),

events AS (
  SELECT partner, (SELECT history_start FROM windows) AS t,
         anchor_balance AS delta, 0 AS kind, CAST(NULL AS TIMESTAMP) AS hr
  FROM partner_anchor
  UNION ALL
  SELECT partner, block_time AS t, delta, 1 AS kind, CAST(NULL AS TIMESTAMP) AS hr
  FROM partner_transfers
  UNION ALL
  SELECT pa.partner, ch.hr AS t, 0.0 AS delta, 2 AS kind, ch.hr AS hr
  FROM partner_addresses pa CROSS JOIN calendar_hours ch
),

events_with_balance AS (
  SELECT partner, t, hr,
         SUM(delta) OVER (PARTITION BY partner ORDER BY t, kind ROWS UNBOUNDED PRECEDING) AS balance
  FROM events
),

partner_hourly AS (
  SELECT partner, hr, balance
  FROM events_with_balance
  WHERE hr IS NOT NULL
),

daily_total_supply AS (
  SELECT day, SUM(balance) AS total_supply
  FROM stablecoins_solana.balances
  WHERE token_symbol = 'USDS'
    AND day >= CAST((SELECT history_start FROM windows) - INTERVAL '1' DAY AS DATE)
    AND day <  CAST((SELECT history_end FROM windows) AS DATE)
  GROUP BY day
),

hourly_total_supply AS (
  SELECT ch.hr, dts.total_supply
  FROM calendar_hours ch
  LEFT JOIN daily_total_supply dts ON dts.day = DATE(ch.hr)
),

tracked_hourly AS (
  SELECT hr, SUM(balance) AS tracked_total
  FROM partner_hourly
  GROUP BY hr
),

pioneer_hourly AS (
  SELECT 'Keel Pioneer' AS partner,
         hts.hr,
         GREATEST(0.0, hts.total_supply - COALESCE(th.tracked_total, 0)) AS balance
  FROM hourly_total_supply hts
  LEFT JOIN tracked_hourly th ON th.hr = hts.hr
),

all_hourly AS (
  SELECT partner, hr, balance FROM partner_hourly
  UNION ALL
  SELECT partner, hr, balance FROM pioneer_hourly
),

hourly_boost AS (
  SELECT ah.partner, ah.hr, ah.balance, sh.ssr_apy,
         ah.balance * sh.ssr_apy / 8760.0 AS boost_hour
  FROM all_hourly ah
  JOIN ssr_hourly sh ON sh.hr = ah.hr
)

SELECT
  CAST(DATE_TRUNC('week', hb.hr) AS DATE) AS week_start,
  hb.partner,
  ROUND(AVG(hb.balance), 2) AS avg_balance,
  ROUND(SUM(hb.boost_hour), 2) AS dune_boost
FROM hourly_boost hb
GROUP BY 1, 2
ORDER BY 1 DESC, dune_boost DESC NULLS LAST

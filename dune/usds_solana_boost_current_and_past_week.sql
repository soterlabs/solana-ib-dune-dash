-- Dune query 7433459 — https://dune.com/queries/7433459
-- Name: USDS Solana Boost — current + past week
--
-- Two windows:
--   * past_week        : the most recent fully-completed Mon→Sun UTC week (168 h)
--   * current_week     : the in-progress week, from this Monday 00:00 up to the
--                        most recently completed UTC hour
--
-- Payout per partner = (SSR-derived boost on USDS balances) + (fixed bonus).
-- Methodology of the SSR-derived component:
--   * Anchor balance from `stablecoins_solana.balances` for the Sunday before the
--     past week's Monday (treated as end-of-day = start-of-window).
--   * Per-hour TWAP balance reconstructed via cumulative USDS transfers
--     (token_symbol = 'USDS' only — kUSDS shares are excluded).
--   * Intra-day SSR APY via `ethereum.traces` `file()` calls on the SSR pot,
--     deduped to last call per day, looked up at hour-start.
--   * Linear formula:  hourly_boost = balance × ssr_apy / 8760.
--   * Keel Pioneer = total_solana_usds_supply − Σ tracked_partner_balances.
--     If today's daily balance snapshot hasn't landed yet, the most recent
--     available day's total supply is used for any NULL hours.
-- Fixed bonuses (constants, applied separately so payout = boost + bonus):
--   * kamino: 50,000 USDS / week (pro-rated to hours_counted / 168 for the
--     in-progress current week).

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

-- Fixed weekly bonuses paid on top of the SSR-derived boost.
partner_weekly_bonus(partner, weekly_bonus) AS (
  VALUES
    ('kamino', CAST(50000 AS DOUBLE))
),

windows AS (
  SELECT
    CAST(DATE_TRUNC('week', CURRENT_DATE) - INTERVAL '7' DAY AS TIMESTAMP)            AS past_start,
    CAST(DATE_TRUNC('week', CURRENT_DATE)                    AS TIMESTAMP)            AS current_start,
    CAST(DATE_TRUNC('hour', CAST(CURRENT_TIMESTAMP AS TIMESTAMP)) AS TIMESTAMP)       AS current_end
),

past_hours AS (
  SELECT (SELECT past_start FROM windows) + (h * INTERVAL '1' HOUR) AS hr,
         'past_week' AS window_label
  FROM UNNEST(SEQUENCE(0, 167)) AS t(h)
),

current_hours AS (
  SELECT (SELECT current_start FROM windows) + (h * INTERVAL '1' HOUR) AS hr,
         'current_week_so_far' AS window_label
  FROM UNNEST(SEQUENCE(
    0,
    GREATEST(CAST(date_diff('hour',
                            (SELECT current_start FROM windows),
                            (SELECT current_end   FROM windows)) AS BIGINT) - 1, -1)
  )) AS t(h)
),

calendar_hours AS (
  SELECT hr, window_label FROM past_hours
  UNION ALL
  SELECT hr, window_label FROM current_hours
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
   AND b.day          = CAST((SELECT past_start FROM windows) - INTERVAL '1' DAY AS DATE)
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
                                   CAST((SELECT past_start FROM windows) AS DATE))
   AND t.block_date  >= CAST((SELECT past_start FROM windows) AS DATE)
),

events AS (
  SELECT partner, (SELECT past_start FROM windows) AS t,
         anchor_balance AS delta, 0 AS kind, CAST(NULL AS TIMESTAMP) AS hr,
         CAST(NULL AS VARCHAR) AS window_label
  FROM partner_anchor
  UNION ALL
  SELECT partner, block_time AS t, delta, 1 AS kind, CAST(NULL AS TIMESTAMP) AS hr,
         CAST(NULL AS VARCHAR) AS window_label
  FROM partner_transfers
  UNION ALL
  SELECT pa.partner, ch.hr AS t, 0.0 AS delta, 2 AS kind, ch.hr AS hr,
         ch.window_label
  FROM partner_addresses pa CROSS JOIN calendar_hours ch
),

events_with_balance AS (
  SELECT partner, t, hr, window_label,
         SUM(delta) OVER (PARTITION BY partner ORDER BY t, kind ROWS UNBOUNDED PRECEDING) AS balance
  FROM events
),

partner_hourly AS (
  SELECT partner, hr, window_label, balance
  FROM events_with_balance
  WHERE hr IS NOT NULL
),

daily_total_supply AS (
  SELECT day, SUM(balance) AS total_supply
  FROM stablecoins_solana.balances
  WHERE token_symbol = 'USDS'
    AND day >= CAST((SELECT past_start FROM windows) - INTERVAL '1' DAY AS DATE)
  GROUP BY day
),

latest_supply AS (
  SELECT total_supply AS supply
  FROM daily_total_supply
  ORDER BY day DESC
  LIMIT 1
),

hourly_total_supply AS (
  SELECT ch.hr, ch.window_label,
         COALESCE(dts.total_supply, ls.supply) AS total_supply
  FROM calendar_hours ch
  LEFT JOIN daily_total_supply dts ON dts.day = DATE(ch.hr)
  CROSS JOIN latest_supply ls
),

tracked_hourly AS (
  SELECT hr, SUM(balance) AS tracked_total
  FROM partner_hourly
  GROUP BY hr
),

pioneer_hourly AS (
  SELECT 'Keel Pioneer' AS partner,
         hts.hr, hts.window_label,
         GREATEST(0.0, hts.total_supply - COALESCE(th.tracked_total, 0)) AS balance
  FROM hourly_total_supply hts
  LEFT JOIN tracked_hourly th ON th.hr = hts.hr
),

all_hourly AS (
  SELECT partner, hr, window_label, balance FROM partner_hourly
  UNION ALL
  SELECT partner, hr, window_label, balance FROM pioneer_hourly
),

hourly_boost AS (
  SELECT ah.partner, ah.window_label, ah.balance, sh.ssr_apy,
         ah.balance * sh.ssr_apy / 8760.0 AS boost_hour
  FROM all_hourly ah
  JOIN ssr_hourly sh ON sh.hr = ah.hr
),

windowed AS (
  SELECT partner, window_label,
         AVG(balance)    AS avg_balance,
         SUM(boost_hour) AS boost,
         COUNT(*)        AS hours_counted
  FROM hourly_boost
  GROUP BY 1, 2
),

windowed_with_bonus AS (
  SELECT
    w.partner,
    w.window_label,
    w.avg_balance,
    w.boost,
    w.hours_counted,
    -- Pro-rate the fixed weekly bonus by completed hours / 168.
    COALESCE(b.weekly_bonus, 0) * (w.hours_counted / 168.0) AS bonus
  FROM windowed w
  LEFT JOIN partner_weekly_bonus b ON b.partner = w.partner
)

SELECT
  partner,
  ROUND(MAX(CASE WHEN window_label = 'past_week'           THEN avg_balance   END), 2) AS past_week_avg_balance,
  ROUND(MAX(CASE WHEN window_label = 'past_week'           THEN boost         END), 2) AS past_week_boost,
  ROUND(MAX(CASE WHEN window_label = 'past_week'           THEN bonus         END), 2) AS past_week_bonus,
  ROUND(MAX(CASE WHEN window_label = 'past_week'           THEN boost + bonus END), 2) AS past_week_total,
  ROUND(MAX(CASE WHEN window_label = 'current_week_so_far' THEN avg_balance   END), 2) AS current_week_avg_balance,
  ROUND(MAX(CASE WHEN window_label = 'current_week_so_far' THEN boost         END), 2) AS current_week_boost_so_far,
  ROUND(MAX(CASE WHEN window_label = 'current_week_so_far' THEN bonus         END), 2) AS current_week_bonus_so_far,
  ROUND(MAX(CASE WHEN window_label = 'current_week_so_far' THEN boost + bonus END), 2) AS current_week_total_so_far,
  COALESCE(MAX(CASE WHEN window_label = 'current_week_so_far' THEN hours_counted END), 0) AS current_week_hours
FROM windowed_with_bonus
GROUP BY partner
ORDER BY past_week_total DESC NULLS LAST

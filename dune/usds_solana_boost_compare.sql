-- Dune query 7429781 — https://dune.com/queries/7429781
-- Name: USDS Solana Boost — compare against historical actuals
--
-- Per-partner weekly USDS Integration Boost (continuously-compounded SSR yield
-- on time-weighted USDS balance) compared with Sky's historically-paid amounts
-- for the 6 weeks 02/23 → 04/05 2026.
--
-- Method:
--   - Per-hour TWAP balance per address, anchored to the spell's daily snapshot
--     and reconstructed via cumulative USDS transfers in/out.
--   - Intra-day SSR rate boundaries: each hour gets the SSR APY active at the
--     start of that hour, using block_time of the underlying file() calls.
--   - Linear formula:  hourly_boost = balance × ssr_apy / 8760.
--   - Keel Pioneer  =  total_solana_usds_supply − Σ tracked_partner_balances.
--
-- The Kamino sub-markets (maple/onre/huma) are pass-through: USDS held in the
-- Kamino Maple/OnRe/Huma markets generates boost paid to Maple/OnRe/Huma rather
-- than Kamino itself.

WITH
partner_addresses(partner, lookup_address) AS (
  VALUES
    ('kamino',       '9DrvZvyWh1HuAoZxvYWMvkf2XCzryCpGgHqrMjyDWpmo'),  -- owner of Kamino Main USDS reserve
    ('maple',        '6QbtpY2jDNcncRFmVf343NThnCdaY8gCAsYATPnYQR9g'),  -- owner of Kamino Maple Market
    ('onre',         'FsvTiXTUFDc4aLbrov4PrvDTjXCWCniL1dxTUkZ1T2ss'),  -- owner of Kamino OnRe Market
    ('huma',         'B5WhxpGmV5BfJnRBpB93dMSePHtttFySJ4dcAZ9YzYYc'),  -- owner of Kamino Huma Market
    ('juplend',      '7s1da8DduuBFqGra5bJBjpnvL5E9mGzCuMk1Qkh4or2Z'),  -- Jupiter Lend USDS pool
    ('onre_reserve', '45YnzauhsBM8CpUz96Djf8UG5vqq2Dua62wuW9H3jaJ5'),  -- OnRe reserve wallet
    ('huma_reserve', '6q76D2fJxPqzQQfUBMmkb2MzT4Vg7VGe2dgXHKd33ad2')   -- Huma reserve wallet
),

calendar_hours AS (
  SELECT TIMESTAMP '2026-02-23 00:00:00' + (h * INTERVAL '1' HOUR) AS hr
  FROM UNNEST(SEQUENCE(0, 6 * 7 * 24 - 1)) AS t(h)
),

-- ============ SSR boundaries (with block_time for intra-day handling) ============
ssr_raw AS (
  SELECT
    CAST(tr.block_time AS TIMESTAMP) AS block_time,
    DATE(tr.block_time AT TIME ZONE 'UTC')  AS effective_date,
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

-- For each hour, find the most recent SSR boundary effective at or before the hour start.
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

-- ============ Per-partner hourly balance: anchor + cumulative transfers ============
partner_anchor AS (
  -- Spell row for day = D-1 is the balance at end of D-1 = start of window.
  SELECT pa.partner,
         COALESCE(b.balance, 0) AS anchor_balance
  FROM partner_addresses pa
  LEFT JOIN stablecoins_solana.balances b
    ON b.address      = pa.lookup_address
   AND b.token_symbol = 'USDS'
   AND b.day          = DATE '2026-02-22'
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
   AND t.block_month  IN (DATE '2026-02-01', DATE '2026-03-01', DATE '2026-04-01')
   AND t.block_date   BETWEEN DATE '2026-02-23' AND DATE '2026-04-05'
),

-- Combined event stream: anchor first (kind=0), transfers (kind=1), then hour reads (kind=2).
-- ORDER BY (t, kind) ensures proper application order at coincident timestamps.
events AS (
  SELECT partner, TIMESTAMP '2026-02-23 00:00:00' AS t,
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

-- ============ Total Solana USDS supply (daily) for Pioneer residual ============
daily_total_supply AS (
  SELECT day, SUM(balance) AS total_supply
  FROM stablecoins_solana.balances
  WHERE token_symbol = 'USDS'
    AND day BETWEEN DATE '2026-02-22' AND DATE '2026-04-05'
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
),

weeks AS (
  SELECT hr, CASE
    WHEN hr >= TIMESTAMP '2026-02-23 00:00' AND hr < TIMESTAMP '2026-03-02 00:00' THEN '02/23-03/01'
    WHEN hr >= TIMESTAMP '2026-03-02 00:00' AND hr < TIMESTAMP '2026-03-09 00:00' THEN '03/02-03/08'
    WHEN hr >= TIMESTAMP '2026-03-09 00:00' AND hr < TIMESTAMP '2026-03-16 00:00' THEN '03/09-03/15'
    WHEN hr >= TIMESTAMP '2026-03-16 00:00' AND hr < TIMESTAMP '2026-03-23 00:00' THEN '03/16-03/22'
    WHEN hr >= TIMESTAMP '2026-03-23 00:00' AND hr < TIMESTAMP '2026-03-30 00:00' THEN '03/23-03/29'
    WHEN hr >= TIMESTAMP '2026-03-30 00:00' AND hr < TIMESTAMP '2026-04-06 00:00' THEN '03/30-04/05'
  END AS week
  FROM calendar_hours
),

dune_weekly AS (
  SELECT hb.partner, w.week,
         AVG(hb.balance)    AS avg_balance,
         SUM(hb.boost_hour) AS dune_boost
  FROM hourly_boost hb
  JOIN weeks w ON w.hr = hb.hr
  WHERE w.week IS NOT NULL
  GROUP BY 1, 2
),

actuals(partner, week, actual_boost) AS (
  VALUES
    ('huma','02/23-03/01',66.7),('juplend','02/23-03/01',9044.3),('kamino','02/23-03/01',9675.0),
    ('maple','02/23-03/01',69.1),('onre','02/23-03/01',82.5),('onre_reserve','02/23-03/01',8442.7),
    ('Keel Pioneer','02/23-03/01',20081.6),
    ('huma','03/02-03/08',63.6),('juplend','03/02-03/08',8888.1),('kamino','03/02-03/08',8746.9),
    ('maple','03/02-03/08',55.2),('onre','03/02-03/08',148.4),('onre_reserve','03/02-03/08',8449.0),
    ('Keel Pioneer','03/02-03/08',20679.9),
    ('huma','03/09-03/15',59.5),('juplend','03/09-03/15',8232.9),('kamino','03/09-03/15',7811.4),
    ('maple','03/09-03/15',38.5),('onre','03/09-03/15',205.7),('onre_reserve','03/09-03/15',7977.9),
    ('Keel Pioneer','03/09-03/15',21153.8),
    ('huma','03/16-03/22',26.2),('juplend','03/16-03/22',7668.5),('kamino','03/16-03/22',7859.7),
    ('maple','03/16-03/22',55.8),('onre','03/16-03/22',128.5),('onre_reserve','03/16-03/22',7933.0),
    ('Keel Pioneer','03/16-03/22',20805.7),
    ('huma','03/23-03/29',28.6),('juplend','03/23-03/29',7944.3),('kamino','03/23-03/29',7481.1),
    ('maple','03/23-03/29',34.5),('onre','03/23-03/29',63.2),('onre_reserve','03/23-03/29',7938.6),
    ('Keel Pioneer','03/23-03/29',21338.3),
    ('huma','03/30-04/05',16.2),('juplend','03/30-04/05',4767.1),('kamino','03/30-04/05',6564.3),
    ('maple','03/30-04/05',33.9),('onre','03/30-04/05',48.5),('onre_reserve','03/30-04/05',7944.4),
    ('Keel Pioneer','03/30-04/05',25017.6)
)

SELECT
  dw.week,
  dw.partner,
  ROUND(dw.avg_balance, 2)            AS avg_balance,
  ROUND(dw.dune_boost, 2)             AS dune_boost,
  COALESCE(a.actual_boost, 0)         AS actual_boost,
  ROUND(dw.dune_boost - COALESCE(a.actual_boost, 0), 2) AS delta_usd,
  CASE WHEN a.actual_boost > 0
       THEN ROUND(100.0 * (dw.dune_boost - a.actual_boost) / a.actual_boost, 2)
  END                                 AS delta_pct
FROM dune_weekly dw
LEFT JOIN actuals a
  ON a.partner = dw.partner
 AND a.week    = dw.week
ORDER BY dw.week, dw.partner

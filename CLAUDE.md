# solana-ib-dune-dash — agent reference

Dune dashboard project for tracking weekly **USDS Integration Boost** payments to Solana lending integrations under the Keel prime.

## What "integration boost" means

Sky pays integration partners the equivalent of SSR (Sky Savings Rate) yield on USDS that those integrations hold on Solana. For a given week:

```
boost = balance × ssr_apy × (seconds_in_period / 31_536_000)        ← LINEAR
```

Despite Sky describing it as "continuously compounding", **historical payouts match the linear formula within pennies** and `usds-flagship-ssr-calc/calculate_rewards.py` is also linear. Use linear.

The flagship Morpho-vault calc (`bal × vault_usds × apr × duration / total_supply / SECONDS_PER_YEAR`) collapses on Solana to plain `bal × ssr_apy × t/yr` because there's no vault-share layer — partners just hold USDS directly.

## Dune queries (live)

| Query | ID | Purpose |
|---|---|---|
| **SSR Rate History** | [7425009](https://dune.com/queries/7425009) | sUSDS `file()` rate boundaries from `ethereum.traces` → `(effective_date, rate_per_second_ray, ssr_apy)`. Sparse (rate-change days only). |
| **Boost — current + past week** | [7433459](https://dune.com/queries/7433459) | Per-partner boost for the most recent fully-completed Mon→Sun UTC week and the in-progress current week (sum over completed hours only). Dynamic dates. |
| **Boost — weekly history** | [7429781](https://dune.com/queries/7429781) | Per-partner weekly boost over the rolling 12 most recently completed weeks. Dynamic dates. No actuals comparison (see KEEL.md for the back-test that validated this methodology). |

The dashboard ([USDS Solana Integration Boost](https://dune.com/soterlabs/usds-solana-integration-boost)) shows current+past week first, then the rolling-12-week history.

## Partner addresses (USDS-source)

`stablecoins_solana.balances.address` is keyed by **owner** (not the SPL token account). For Kamino markets the user shared token-account addresses; we use the *owner* of those token accounts.

| Partner | USDS-holding address (owner, used in queries) | Note |
|---|---|---|
| kamino (main) | `9DrvZvyWh1HuAoZxvYWMvkf2XCzryCpGgHqrMjyDWpmo` | owner of token-account `4aE6ow1Y…hupD` |
| maple | `6QbtpY2jDNcncRFmVf343NThnCdaY8gCAsYATPnYQR9g` | owner of Kamino Maple Market token-account `C2BZ79f…TJwL` (boost pass-through to Maple) |
| onre | `FsvTiXTUFDc4aLbrov4PrvDTjXCWCniL1dxTUkZ1T2ss` | owner of Kamino OnRe Market token-account `21Skwocv…yKLx` |
| huma | `B5WhxpGmV5BfJnRBpB93dMSePHtttFySJ4dcAZ9YzYYc` | owner of Kamino Huma Market token-account `FSWKgzBo…1LJV` |
| juplend | `7s1da8DduuBFqGra5bJBjpnvL5E9mGzCuMk1Qkh4or2Z` | already an owner address |
| onre_reserve | `45YnzauhsBM8CpUz96Djf8UG5vqq2Dua62wuW9H3jaJ5` | already an owner address |
| huma_reserve | `6q76D2fJxPqzQQfUBMmkb2MzT4Vg7VGe2dgXHKd33ad2` | already an owner address; usually $0 |
| **Keel Pioneer** | n/a — *residual* | `total_solana_usds_supply − Σ tracked_balances` |

**Skipped (no addresses)**: `drift`, `marginfi`, `solend`. Tracked by Sky Feb–Mar 2026, dropped from 03/30/2026. Their balances now sit inside the Keel Pioneer residual. The historical *payout* addresses they appear under in the user's spreadsheets (`5hMjmxe…`, `CYcWgRx…`, `5QbRL9MU…`) are payout-recipient addresses, **not** USDS-source addresses.

The "Address" column in Sky's per-week SSR-Incentive spreadsheet is **always the payout recipient**, never the USDS-source. `AU4GkzA4G9rRX3hS8QCNTiVGAtt5MNUAfK5L5Q57BAC4` recurs across huma/kamino/maple/onre because it's a single payout wallet for multiple partners.

## Methodology details

### Time window
Each week is `[Mon 00:00:00 UTC, Sun 23:59:59 UTC]` = 7 × 24h = 604,800s.

### Per-hour TWAP balances
For each tracked address:
1. **Anchor** = balance from `stablecoins_solana.balances` on the day BEFORE the window start (treated as end-of-day balance = start of window).
2. **Cumulative deltas** = signed sum of `stablecoins_solana.transfers` matching `from_owner = addr` (negative) or `to_owner = addr` (positive), filtered to `token_symbol = 'USDS'`.
3. Combine anchor + transfers + hour-boundary "read" rows in a UNION, sort by `(t, kind)` with anchor first (kind 0), transfers next (kind 1), hour reads last (kind 2). Apply `SUM(delta) OVER (PARTITION BY partner ORDER BY t, kind)`. Read balance at each hour-boundary row.

For partition pruning on `stablecoins_solana.transfers`, filter on **both** `block_month` (the partition key) and `block_date`.

### Intra-day SSR boundaries
`ssr_boundaries` CTE keeps `block_time` (UTC) of each rate-change `file()` call (deduped to last call of the day). For each calendar hour, look up the most recent boundary `effective_time <= hr`. This eliminates the systematic ~0.6% gap on rate-change weeks (e.g., 03/09).

### Pioneer residual (hourly)
- `daily_total_supply(D)` = `SUM(balance) WHERE token_symbol='USDS' AND day=D` from `stablecoins_solana.balances`.
- For hour H in day D: `pioneer_balance(H) = max(0, daily_total_supply(D) − Σ tracked_hourly_balance(H))`.
- Daily total supply is held constant within the day (acceptable approximation — mints/burns are infrequent vs. balance reshuffles between addresses).

### Linear boost per hour
```
boost_hour = balance × ssr_apy / 8760
weekly_boost = SUM over 168 hours
```

## Validation against historical actuals

The 14-week back-test (12/29/2025 → 04/05/2026) that validated this methodology has been moved out of the live queries — see [`KEEL.md`](./KEEL.md) for the methodology, what reconciled cleanly, and the open questions for the Keel team. Headline results:

| Partner type | Match quality |
|---|---|
| Stable balances (onre_reserve) | Within ±$0.05 (0.00%) every week |
| huma / maple | Constant −$15–22/wk under (independent of balance) — likely ~$19–20k of USDS held at addresses we don't track |
| onre | Constant +$46–52/wk over (independent of balance, scales with rate change) — likely ~$65k of USDS at a sub-account we should exclude |
| juplend (post-01/26) | −3% to −6%; ~$300/wk absolute, suggests per-block vs per-hour TWAP delta |
| **kamino (main)** | **−6% to +14%** — most volatile address (8M↔14M intra-week swings); hourly TWAP misses sub-hour movements |
| Keel Pioneer | Within $84–$1,100 boost-equivalent across all 14 weeks once Sky's tracked-address set delta (juplend pre-01/26, drift/mfi/solend pre-03/30) is modelled in |

## Reference files outside this repo

- `../settle/msc/settlement-cycle/src/settle/queries/ssr_history.sql` — original Python-flavored SSR history SQL; the basis for Dune query 7425009.
- `../usds-flagship-ssr-calc/calculate_rewards.py` — reference Python implementation of the boost calc (linear).
- `../usds-flagship-ssr-calc/PLAN.md` — methodology notes for the Morpho flagship vault calc.

## Open items

- Whether to skip drift/marginfi/solend permanently or research their USDS-source addresses (their balances currently inflate the Pioneer residual for pre-03/30 weeks).
- Per-minute TWAP if kamino's residual gap (~±$1k/week) is unacceptable.
- Whether the production calc applies any kamino-specific accounting (kUSDS supply, special factor) — the flat 50k bonus hints at it.

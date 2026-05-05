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

`stablecoins_solana.balances.address` is keyed by **owner** (not the SPL token account) — verified directly: querying the four Kamino token-accounts returns NULL; querying their owners returns real balances. The Kamino balance for a given market = sum of USDS across every token-account that owner holds. For maple / onre / huma the owner holds USDS in **exactly one** token-account each (identical to what Keel shared), so owner-keyed = token-account-keyed. For kamino-main the owner holds two — see note in the table.

| Partner | USDS-holding address (owner, used in queries) | Note |
|---|---|---|
| kamino (main) | `9DrvZvyWh1HuAoZxvYWMvkf2XCzryCpGgHqrMjyDWpmo` | owner of token-account `4aE6ow1Y…hupD`. **Owner also holds USDS in a second token-account `3PfZfx8cjfW8EADSSaDt7fsmBABKdTU4Zjrf4HWjJBwa`** — currently a flow-through that nets to $0 by end of every active day, so our owner-keyed read ≈ the single token-account Keel shared. Re-check if it ever holds an end-of-day balance. |
| maple | `6QbtpY2jDNcncRFmVf343NThnCdaY8gCAsYATPnYQR9g` | owner of Kamino Maple Market token-account `C2BZ79f…TJwL` (boost pass-through to Maple); single USDS token-account |
| onre | `FsvTiXTUFDc4aLbrov4PrvDTjXCWCniL1dxTUkZ1T2ss` | owner of Kamino OnRe Market token-account `21Skwocv…yKLx`; single USDS token-account |
| huma | `B5WhxpGmV5BfJnRBpB93dMSePHtttFySJ4dcAZ9YzYYc` | owner of Kamino Huma Market token-account `FSWKgzBo…1LJV`; single USDS token-account |
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
2. **Cumulative deltas** = signed sum of `stablecoins_solana.transfers` matching `from_owner = addr` (negative) or `to_owner = addr` (positive), filtered to `token_symbol = 'USDS'`. **Filter `block_date >= window_start` — NOT `>= window_start − 1 day`.** See the warning below.
3. Combine anchor + transfers + hour-boundary "read" rows in a UNION, sort by `(t, kind)` with anchor first (kind 0), transfers next (kind 1), hour reads last (kind 2). Apply `SUM(delta) OVER (PARTITION BY partner ORDER BY t, kind)`. Read balance at each hour-boundary row.

For partition pruning on `stablecoins_solana.transfers`, filter on **both** `block_month` (the partition key) and `block_date`.

> **Anchor-day double-count — most important pitfall.** The spell `stablecoins_solana.balances.day = D` represents end-of-day-D balance, equivalent to balance at 00:00 on D+1. So the anchor on day `window_start − 1` already includes that day's transfers. If the transfer filter is widened to `block_date >= window_start − 1 day`, those transfers are ALSO summed before the anchor in the running balance, and every reconstructed hourly balance is biased by the partner's net anchor-day transfer for the entire window. In the original 14-week back-test this produced rock-solid per-partner offsets vs Keel actuals (onre **+$50/wk**, huma **−$15/wk**, maple **−$15–22/wk**, juplend **−$300/wk**, kamino **+$58/wk**) that were initially attributed to Sky-side methodology differences but were actually entirely our bug. Tightening the filter to `>= window_start` eliminated all of them; non-kamino partners now reconcile to within ±$11/wk.

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

14-week back-test (12/29/2025 → 04/05/2026) — full record in [`KEEL.md`](./KEEL.md). The status BELOW reflects the methodology AFTER the anchor-day transfer-filter fix (see methodology pitfall above); the original write-up identified several "constant per-week offsets" that were our bug, not Keel's accounting.

| Partner | Match quality (post-fix) |
|---|---|
| onre_reserve | Within ±$0.05 (0.00%) every week — reference proof of formula and rate handling |
| huma / maple / onre / juplend | Within ±$11/wk in stable weeks; the previously-reported constant offsets ($15–$320/wk per partner) were entirely the anchor-day double-count |
| Pioneer (post-03/30, address sets aligned) | Within $300–$1,100 boost-equivalent — most of the residual gap is kamino TWAP error bleeding into Pioneer |
| **kamino (main)** | ±$200 in 6 of 8 weeks; **−$541** in 03/02 and **+$758** in 03/30. Weekly-average balances differ between us and Keel by ~$0.7M in those two weeks — not explained by hourly TWAP alone or by address basis (verified). Suspected: kamino-specific accounting (kUSDS supply × exchange rate) or a different snapshot cadence — open question for Keel. |
| Pioneer (pre-03/30) | Reverse-engineered Keel's tracked-set: pre-01/26 = ours − juplend + drift/mfi/solend (Pioneer earned juplend's boost while it received only the $12.5k/wk bonus); 01/26 → 03/29 = ours + drift/mfi/solend. Model fits all weeks within $84–$1,100. |

Implied SSR APY across the back-test (back-solved from `onre_reserve` actuals, since it matches to the penny): **4.00% from 12/29/2025 through 03/02/2026**, transitioning during the week of 03/09 to **3.75% from 03/16 onward**.

## Reference files outside this repo

- `../settle/msc/settlement-cycle/src/settle/queries/ssr_history.sql` — original Python-flavored SSR history SQL; the basis for Dune query 7425009.
- `../usds-flagship-ssr-calc/calculate_rewards.py` — reference Python implementation of the boost calc (linear).
- `../usds-flagship-ssr-calc/PLAN.md` — methodology notes for the Morpho flagship vault calc.

## Open items

- **kamino — only remaining methodology gap.** Three pointed questions for Keel in [`KEEL.md`](./KEEL.md): (1) snapshot cadence (per-block vs per-hour vs end-of-day vs end-of-week), (2) balance basis (raw USDS at the token-account vs derived from kUSDS supply × exchange rate), (3) what the flat $50k weekly bonus represents and whether it should be folded into the SSR calc. Address basis already verified — owner-keyed read ≈ the single token-account Keel shared, so the gap is not address-side.
- **drift / marginfi / solend USDS-source addresses** — historical only (Sky stopped tracking from 03/30/2026). Not needed for current calc, but would unlock pre-03/30 Pioneer reconciliation if asked.
- **juplend pre-01/26 treatment** — historical only. Reverse-engineering shows Sky kept juplend's $10M inside the Pioneer residual during 12/29 → 01/25/2026 (Pioneer effectively earned its boost), with the $12,500/wk a separate onboarding incentive on top. Worth confirming with Keel for documentation.
- Per-block (rather than per-hour) TWAP — only worth implementing if Keel confirms they snapshot per-block AND the kamino gap can't be closed another way. Heavy rewrite.

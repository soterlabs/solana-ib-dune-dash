# Solana Integration Boost Dashboard

A Dune dashboard that computes the weekly **Integration Boost** payments owed to Sky's Solana lending integrations under the Keel prime.

## What it does

Each week, Sky pays integration partners the equivalent of [SSR (Sky Savings Rate)](https://docs.sky.money/sky-token-rewards/sky-savings-rate-ssr) yield on the USDS those integrations are holding on Solana. This dashboard reproduces those payout amounts directly from on-chain data, so you can:

- Verify a payout before it's made.
- Audit historical payouts.
- Track how each partner's USDS balance — and therefore boost — moves week to week.

## Tracked partners

| Partner | Where USDS sits |
|---|---|
| **kamino** | Kamino Lend main USDS market |
| **juplend** | Jupiter Lend USDS pool |
| **onre_reserve** | OnRe reserve wallet |
| **huma_reserve** | Huma reserve wallet |
| **maple** | Kamino Maple Market (boost passes through to Maple) |
| **onre** | Kamino OnRe Market (passes through to OnRe) |
| **huma** | Kamino Huma Market (passes through to Huma) |
| **Keel Pioneer** | Residual: all USDS on Solana not held by the partners above |

(`drift`, `marginfi`, `solend` were tracked Feb–Mar 2026 but dropped on 03/30/2026 — their USDS now sits inside the Keel Pioneer residual.)

## How the boost is calculated

```
weekly_boost = balance × ssr_apy × 7 / 365
```

Each hour over the 7-day window the dashboard computes the partner's USDS balance and multiplies by the SSR APY active in that hour. Hourly chunks are summed for the weekly figure.

- **Balance** comes from a per-hour TWAP (time-weighted average) reconstructed from the Dune Solana spell tables.
- **SSR APY** comes from the on-chain `file()` calls on the sUSDS contract (Ethereum). Rate changes are honored at the hour they happen (intra-day boundaries).
- **Weeks** run Monday 00:00 UTC through Sunday 23:59:59 UTC.
- **Keel Pioneer** = total Solana USDS supply minus the sum of all tracked partner balances.

## Dashboard

**[USDS Solana Integration Boost — dune.com/soterlabs/usds-solana-integration-boost](https://dune.com/soterlabs/usds-solana-integration-boost)**

Two views:
- **Total weekly payout** — Dune-computed total vs. actually-paid total, week by week.
- **Per-partner breakdown** — full back-test (6 weeks × 8 partners) with Δ vs. Sky's historical payouts.

## Dune queries

| Query | Purpose |
|---|---|
| [SSR Rate History (7425009)](https://dune.com/queries/7425009) | Per-rate-change record of SSR APY changes |
| [USDS Solana Boost — compare (7429781)](https://dune.com/queries/7429781) | Weekly per-partner boost vs. Sky's historical payouts (back-test) |

## Validation

Compared against six weeks of historical Sky payouts (02/23/2026 – 04/05/2026):

- **Stable balances** (e.g. `onre_reserve`): match within $0.05.
- **Active partners** (huma, maple, onre, juplend): ±0.5% in calm weeks, ±2% in volatile weeks.
- **kamino (main)**: ±6–12% — extreme intra-week volatility (8M ↔ 14M) means even hourly TWAP misses sub-hour swings.
- **Keel Pioneer**: matches to within −4% on the most recent week. For earlier weeks the dashboard over-counts by the balance of the dropped partners (drift/marginfi/solend) which are not yet subtracted.

## Bonus incentives

Some partners receive a flat bonus on top of the SSR-derived boost. Currently:
- **kamino**: +50,000 USDS / week (constant)

Bonus values are applied as constants in the comparison query.

## Repo layout

```
.
├── README.md                                  ← you are here
├── CLAUDE.md                                  ← technical reference for AI agents
└── dune/
    ├── ssr_history.sql                        ← mirror of Dune query 7425009
    └── usds_solana_boost_compare.sql          ← mirror of Dune query 7429781
```

`dune/*.sql` are the source-of-truth committed copies; the live queries on dune.com are the same content. When you edit a query on Dune, please update the corresponding `.sql` file (and vice versa) so they stay in sync.

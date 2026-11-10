# KuCoin Funding Desk

A read-only dashboard, rebuilt hourly by GitHub Actions and served from GitHub Pages.

For the most-traded KuCoin USDT perpetuals: current, 7-day and 30-day funding, realised volatility from hourly candles, order-book depth, a correlation matrix and a what-if book for overnight risk and funding.

Public market data only. No API keys, no accounts, no orders. Not investment advice.

## Run locally

    perl build.pl --out dist        # needs perl (JSON::PP) and curl
    # open dist/index.html

`data/seed.json` is a snapshot used only if KuCoin cannot be reached and no earlier published data exists; `perl build.pl --seed` rewrites it.

## Setup on GitHub

Settings > Pages > Source = GitHub Actions. The workflow runs on push, hourly, and from the "Run workflow" button.

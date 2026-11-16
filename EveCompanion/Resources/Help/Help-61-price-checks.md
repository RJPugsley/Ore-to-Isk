---
id: price-checks
title: Price Checks & Badges
section: Everywhere
order: 20
icon: checkmark.seal
keywords: fair price, live price, inflated, dumped, no history, trend, trending up, trending down, quick, slow, wide, tight, badges, price check, median, band, lookback, batch, manipulation, spike, odd price
related: market, build-vs-sell, reprocessing, numbers-and-tables
summary: How the app avoids being fooled by silly prices on the market, and what the coloured badges mean.
---
Market prices in EVE can be misleading. One player might list a frigate for twice its value and hope someone clicks by mistake. Another might dump a stack far below its value. If the app believed every price, its profit figures would be wrong.

## Live price and fair price

- **Live price**: the app doesn't just take the single cheapest order. It **averages the orders you'd actually trade against** for the amount you're buying or selling. If you're selling 10 frigates, the price takes all 10 into account.
- **Fair price**: the typical price from **real sales** over recent days (30 by default). If the last week has clearly moved away from that, with real sales behind it, the fair price follows the newer level.

When the live price is far above the fair price, the app uses the **fair price** in its profit figures, so you aren't shown profit you'd never get.

## Price badges

- **Inflated** (orange): well above the fair price. The fair price is used instead.
- **Dumped** (purple): well below the fair price. Someone is selling cheap, and the live price is kept.
- **No history**: no recent sales, so the price can't be checked.
- **↑ / ↓**: the price has been trending up or down over the last 7 days.

## Market badges

- **Quick** (green): selling at least 25% faster than usual.
- **Slow**: selling at least 25% slower than usual.
- **Tight** (green): buy and sell prices are within 10% of each other. A busy, healthy market.
- **Wide**: the sell price is more than double the buy price. The price is shaky.

## Settings (Price Checks menu)

Shared by every page:

- **Flag prices more than**: ±25%, 50% (default), 75% or 100% away from fair.
- **Fair price from**: the last 7, 14, 30 (default), 60 or 90 days of sales.

> Hover over any badge for the actual figures behind it. The **?** button on a page lists its columns and badges.

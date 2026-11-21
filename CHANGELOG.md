# Changelog

## v1.4 beta – 21 November 2026

### New
- **Reprocess or Sell** (Mine and Sell tabs) – for loot, salvage, modules, packaged ships and empty
  containers: sell it as it is, or reprocess it (and its outputs) for more? Checks all five hubs,
  your Scrapmetal Processing skill, station tax and standings, and can compare reprocessing where
  the item is with hauling it to your refinery. Look Up mode for any item, with a breakdown tree.
- **Build Planner money tiles** – Total Cost, Sells For and Profit (ISK and %), plus Cash profit
  (only the ISK you actually spent), with "Build components myself" taken into account and a note
  on how much building the components saves.
- **Where your stock came from** – stock used by a plan is split into bought or built (at what it
  cost you), mined, looted / other and already had, tracked from the app's first run.
- **Use stock at other stations** (Build Planner) – counts what you have elsewhere and lists what
  to fetch from where.
- **Industry Jobs slot tiles** – Manufacturing, Science and Reactions: how many jobs are running
  and how many more you can start (finished but undelivered jobs still count).

### Changed
- **Market Orders** – the sell table now shows your price against the lowest other price (±%),
  Net Left after sales tax, broker and relisting fees and what the items cost to build, the fair
  price for the region, and sold per day. Status is a symbol; Listed column removed.
- **Reprocessing** is now called **Ore Reprocessing**; everything that isn't ore or ice moved to
  Reprocess or Sell.
- **Manufacturing** – picking a blueprint copy you own sets Runs to the runs left on it (and caps it).
- Every table highlights the selected row.
- Search suggestions open in a floating list that is always on top.
- Pages remember their results while nothing has changed, and ESI data is kept exactly as long as
  CCP says it is fresh – faster page switching, fewer calls to CCP.
- Help updated for every changed page, plus a new Reprocess or Sell article.

## v1.0 beta – 16 November 2026

First public release.

- Five workflow tabs – Pilot, Mine, Build, Sell, Haul – covering character, skills, finances,
  mining, build planning, reprocessing, manufacturing, blueprints, copying, payback,
  market, market orders, hauling, routes and a watch list.
- Login with EVE SSO using PKCE: no client secret, login kept in the Keychain.
- First-run welcome and setup; Settings → Start Fresh.
- Built-in searchable Help with an A–Z index, walk-throughs and a glossary.
- Fair-price checks and market badges (Inflated, Dumped, Quick, Slow, Tight, Wide).
- Local history (wallet, transactions, mining, orders, jobs, net worth, competition).
- App icon: ore crystal turning into ISK.

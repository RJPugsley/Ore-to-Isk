---
id: build-planner
title: Build Planner
section: Mine
also: Build
order: 20
icon: hammer.circle
page: buildPlanner
keywords: plan, planner, profit, cash profit, loot, looted, salvage origin, already had, where stock came from, stock at other stations, fetch, total cost, sells for, job fees, worth building, ore to mine, what to mine, minerals needed, shopping list, components, build components, fewest m³, ore grades, II-Grade, III-Grade, belts, high-sec, low-sec, null-sec, Pochven, reactions, planetary, moon materials, salvage, buy list, runs
related: ore-database, reprocessing, manufacturing, walk-mining-for-build
summary: Pick what you want to build. The app tells you which ore to mine, how much, and what else you need to buy.
---
The Build Planner works backwards from a build. Say you want ten of a frigate. It works out every mineral you need, takes away what you already have, and finds the **mix of ore with the fewest m³** to mine for the rest, so you spend the least time hauling and mining.

## Making a plan

1. On the left, under **Add**, search for something to build. With **Only my blueprints** ticked you only see blueprints you own. Untick it to search everything, or to browse by **Category** and **Group**. Items you own are shown in **bold**.
2. Click it to add it to **To Build**. Set the **runs**: type a number or use the arrows.
3. Add as many items as you like. Right-click an item to **Remove** it, or to **Clear the Whole Plan** (the app asks first).

## Options

- **Where you mine**: tick *High*, *Low*, *Null* and/or *Pochven*. Only ore found in ordinary asteroid belts in those areas is used.
- **Build components myself**: parts that have their own blueprint (such as construction parts) are broken down into *their* materials, all the way down, so the ore plan covers them too. Untick it to treat them as things to buy.
- **Subtract what I already have**: takes away materials in your stock and, if you allowed it in [Build settings](help:build-settings), ore waiting at your refinery.
- **Use stock at other stations**: also counts what you own at other stations, not just at your Stock location. Anything the plan takes from elsewhere is listed under **Fetch from Other Stations**, with where it is, so you can haul it over before you build. Untick it to count only what's at home.

## What you get

### Is it worth it? (the top tiles)

The three tiles across the top answer the big question: does this plan make money?

- **Total Cost**: everything the plan uses, split into *minerals*, things you'd *buy*, and *job fees*. Minerals count at what they'd sell for in your hub's buy orders after tax, even ones you mine yourself or already have. That's the same way [Build vs Sell](help:build-vs-sell) counts them, so the two pages agree. If the plan uses things from your stock (minerals, components or other parts), a second line shows where they came from: the part you **bought or built** (and what it cost you), the part you **mined**, the part that's **looted / other**, and the part you **already had**.

EVE doesn't tell apps when you loot or salvage, so the app works it out by elimination. Anything you own that your history can't explain (not bought, not mined, not built, and not there when tracking began) counts as *looted / other*. That covers loot, salvage and reprocessed loot, and also gifts and items moved from your other characters. Tracking begins the first time the app runs: everything you owned then counts as *already had*. Hover over **Total Cost** to see the date. The app works this out from your market purchases, the same way Manufacturing's *Your Track Record* does.
- **Sells For**: what the finished items sell for, checked against recent sales, after sales tax and broker fee. It uses the sell hub chosen on Build vs Sell.
- **Profit**: in ISK and as a percentage, green when you make money and red when you lose it. Under it:
  - *Cash profit* counts only the ISK you actually spend. Things still to buy count at the hub's price, job fees count for the jobs you'll actually run, and stock counts at what it cost you: bought at what you paid, built at what the build cost. Minerals you mine, and stock you mined, looted or already had, count as free. The main Profit values every mineral at what it would sell for instead, which tells you whether building beats selling the minerals.
  - *Building the components yourself saves…* compares building every component with buying them. It works either way **Build components myself** is set, so you don't need to flick the switch to find out.

Each item on the left also gets a small line: **Cost · Sells · profit**, so one loser can't hide behind a good build.

Example: you plan 10 Ventures. Total Cost says 4.1m (minerals 3.6m, job fees 0.5m), Sells For says 5.3m, and Profit shows +1.2m (+33%). Under it, *Cash profit* says +4.8m, because the minerals were ones you mined.

### Ore to Mine

Each row is one ore with three columns: **Standard**, **II-Grade** and **III-Grade**. **Any one column is enough on its own.** Mine whichever grade the belt has. Higher grades give more minerals per unit, so you need fewer of them. Mixing grades works too: half the Standard amount plus half the II-Grade amount gives the same minerals.

**Gives** lists the minerals that ore produces with *your* refinery yield. **In Belts** says where the ore is found.

### Minerals

For each mineral: **Needed**, **Have**, **To Mine**, **Plan Gives**, **Spare** and **Worth**. *Spare* is the extra the ore gives beyond what you need. Ore comes in whole batches and gives several minerals at once, so there's usually a little over.

### Build First – Components

The parts you'll build yourself before the main build, with how many runs of each.

### Everything else

Anything that doesn't come from belt ore is listed by where you get it: **reactions**, **planetary** materials, **moon** materials, **salvage**, or **buy**. Each item is priced at your hub's cheapest sell order. Their cost is part of **Total Cost** at the top.

> Hover over an ore to see the batches and m³ for each grade.

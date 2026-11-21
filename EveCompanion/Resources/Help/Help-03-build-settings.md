---
id: build-settings
title: Build Settings
section: Getting Started
also: Build
order: 30
icon: slider.horizontal.3
keywords: settings, build location, facility, structure, rigs, ME rig, TE rig, facility tax, material hub, price basis, stock location, refinery, yield, refinery yield, ice yield, refinery tax, setup, Raitaru, Azbel, Sotiyo, NPC station
related: manufacturing, reprocessing, build-planner, walk-reprocess-or-sell
summary: Tell the app where you build, where you buy materials, where your stock is and how well your refinery works. The welcome screen asks for these the first time.
---
Build Settings is where the app learns the parts of your setup that it can't read from the game. Open it with the **Build Settings** button on the Manufacturing page, or the **Settings** button on the Ore Reprocessing page. It opens as a panel on the right.

## Build Location

- **System**: type the name of the system where you run manufacturing jobs. The app looks up that system's live **cost index**, which changes how much each job costs to start.
- **Facility**: an NPC station, or a player structure (Raitaru, Azbel or Sotiyo). Structures have their own material and time bonuses.
- **Rigs (ME / TE)**: if the structure has manufacturing rigs, enter their material and time bonuses.
- **Facility tax**: NPC stations charge 0.25%. Player structures set their own tax, so ask the owner or look at the job window in the game.

## Material Prices

- **Price at**: the trade hub whose prices you use for materials.
- **Cost materials at**: *Sell orders* means what it costs to buy them now. *Buy orders* means what you'd get by selling yours.
- **Use materials I already own**: when ticked, materials you already have count as **free**, so the profit shown is the cash you actually make. Untick it to see the profit as if you had to buy everything.
- **Count stock at**: the station or container where you keep your building materials, or *Everywhere*.

## Refinery

This is where you reprocess (refine) ore.

1. Pick the station or structure.
2. In the game, open the Reprocessing window there, drop in some ore, and read the **yield %** it shows.
3. Type that number in here and choose the ore it was measured on. The app removes your own skill bonuses from it, so it knows the refinery's own bonus. It then works out the right yield for every other ore with your skill for that ore.
4. Do the same with some ice for the **ice yield**. Refinery rigs treat ore and ice separately.
5. Enter the **refinery tax**, if the owner charges one.

Until you enter a yield (it starts at 0), the app assumes a plain NPC station.

**Count ore at the refinery as minerals**: when ticked, ore waiting at your refinery counts as the minerals it would give you, both on Manufacturing and in the Build Planner.

> The game rounds the yield % it shows, so the app's mineral totals can be a tiny bit different from the game's (about 0.05%).

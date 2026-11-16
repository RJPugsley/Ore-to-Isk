---
id: keeping-up-to-date
title: Keeping Up to Date
section: Getting Started
order: 40
icon: arrow.clockwise
keywords: refresh, update, updating, reload, connection, connected, offline, downtime, game data, static data, preparing game data, cache, prices as of, popup, activity
related: troubleshooting, history-range, your-data
summary: How the app refreshes, what the status dot means, and EVE's daily downtime.
---
## Refresh

- **⌘R**, or the **↻** button at the top right, re-reads your character: wallet, assets, skills, orders, jobs and history.
- Many pages also have their own **Refresh** or **Refresh Prices** button. It fetches brand-new market prices straight away instead of using the copy from a few minutes ago.
- Some pages refresh themselves: the character summary every minute, Build vs Sell and Market Orders every 5 minutes.

## How fresh is it?

To stay quick, and to be polite to CCP's servers, the app keeps recent answers for a short time:

- market orders: about **5 minutes** (pages say *Prices as of hh:mm*)
- your assets and skills: about **10 minutes**
- average prices and system cost indexes: about **1 hour**
- market price history: a few hours

## The "Updating…" box

When the app is waiting on CCP, a small box at the bottom right lists what it's fetching. It closes by itself when it's done, and you can keep clicking around while it's open.

## The status dot (top left)

- **Green, Connected**: all good. Hover over it to see when it last updated.
- **Orange, Not logged in**: see [Logging in](help:logging-in).
- **Orange, EVE downtime**: the game's servers restart every day at about **11:00 EVE time (UTC)** for around half an hour. The app shows the last figures it had and carries on by itself afterwards.
- **Red, Offline**: no internet, or CCP's servers aren't answering.

## Preparing Game Data

The first time you open the app, and again after big game patches, it downloads CCP's **static data**: every item, blueprint, ore and system. You'll see **Preparing Game Data** for a few minutes. After that it's stored on your Mac.

---
id: route
title: Route
section: Haul
order: 20
icon: point.topleft.down.to.point.bottomright.curvepath
page: haulRoute
keywords: route, autopilot, waypoints, destination, jumps, safe route, lowest risk, game route, avoid, avoidance, stops, optimise order, traffic light, red, amber, green, kills, ganks, gank, CONCORD, pod kill, security penalty, prefer safer, send route, zKillboard
related: watch-list, haul-planner, walk-safe-haul, glossary
summary: Plan a trip like the game's autopilot does, see how dangerous each system on the way is, then send the route to the game.
---
## Planning a route

- **From**: where you start. Click the location button to start from where you are now. **Swap** plans the trip back.
- **To**: type a system, station or structure. Each system is listed first, then its stations, with trade hubs marked.
- **Stops**: places to visit on the way, in order. **Optimise Order** puts them in the shortest order.
- **Avoid**: systems to keep out of. Right-click a system in the list and choose **Avoid**.
- **Route**:
  - **Game Route**: what your game would fly, using your autopilot settings and the systems you avoid.
  - **Lowest Risk**: the same, but it goes round red systems when that's safer and costs no more than the **extra jumps** you allow.

## Your in-game autopilot

Open the **Autopilot** panel and set it the same as the Route settings in your game (the autopilot menu). Those are **Route preference** (shorter, safer or less secure), **Security penalty**, and whether to avoid systems with recent pod kills. The game doesn't let apps read these settings, so the app copies yours to plan exactly the way your game will.

## The systems list

Every system on the way gets a **traffic light** and a **Why** explaining it:

- **Red**: low-sec or null-sec; a hauler ganked there in the last 24 hours; two or more haulers ganked this week; or a sudden spike in kills.
- **Amber**: another gank in the last 24 hours; one hauler ganked this week; or much busier than usual for that system.
- **Green**: quiet.

The lights compare each system with **its own normal**. A busy hub like Jita isn't red just for being busy, but a quiet system with three kills in an hour is.

Columns: **Sec, Jumps / h** (traffic), **Kills 1 h / 24 h / 7 d** (ships killed by players) and **Ganks 7 d**. A *gank* is a kill in high-sec where CONCORD then destroyed an attacker.

> The first look at a route reads a week of kills from zKillboard, so it takes a little longer. The quick figures from CCP appear first.

## Sending it to the game

- **Send route**: sets your start, stops and finish in the game, adding a waypoint only where it's needed to keep you out of avoided or red systems.
- **Destination only**: the game picks the way.

**Watch** adds the route to your [Watch List](help:watch-list).

> The first time you send a route, log out and in again so the app is allowed to set waypoints. See [Logging in](help:logging-in).

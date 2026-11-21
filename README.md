# EVE: Ore to ISK

A free macOS companion for **EVE Online** that follows the whole industrial loop:
**mine → refine → build → sell → haul** – and shows what actually pays before you undock.

> **v1.4 beta.** Free and open source (MIT). Fan-made; not affiliated with or endorsed by CCP hf.

## What it does

| Tab | Pages |
|---|---|
| **Pilot** | Character summary, Skills, Finances (income, spending, net worth over time, every trade) |
| **Mine** | Mining Ledger, Build Planner (which ore to mine for a build – fewest m³), Reprocessing (sell ore or minerals?), Ore Database |
| **Build** | Manufacturing (cost and cash profit at all five hubs), Blueprints, Blueprint Copying, Industry Jobs, Build vs Sell, Blueprint Payback |
| **Sell** | Market browser with five-hub comparison and price history, your Market Orders (undercut alerts, finished-order results) |
| **Haul** | Haul Planner (pack trips by ISK per m³), Route (gank-aware traffic lights, sends waypoints to the game), Watch List (alerts when a route turns red) |

Also: fair-price checks that ignore silly listings, right-click shortcuts into the game,
a local history that keeps your wallet and mining records beyond CCP's 30 days,
and a built-in, searchable Help (⌘?).

## Install

1. Download **EVE-Ore-to-ISK-1.4-beta.dmg** from [Releases](../../releases).
2. Open it and drag **EVE Ore to ISK** into **Applications**.
3. The beta isn't notarised by Apple yet, so the first launch is blocked once:
   open the app, click **Done**, then go to **System Settings → Privacy & Security**,
   scroll down and click **Open Anyway**. After that it opens normally.
4. Follow the welcome screen: log in with your EVE character and tell the app where you build and refine.

Requires **macOS 14 Sonoma** or later (Apple silicon or Intel).

## Privacy

- You log in on CCP's own page (EVE SSO with PKCE). The app never sees your password and has no secret key.
- Your login is kept in your Mac's Keychain; everything else the app saves is in
  `~/Library/Application Support/eve_ore_to_isk`.
- The app talks only to CCP (login, ESI, static data) and zKillboard (public kill counts). No tracking, no ads, no accounts.

## Build from source

Open `EveCompanion.xcodeproj` in Xcode 16 or newer and press ⌘R. Nothing to configure –
the app's public EVE application is built in. The project uses Xcode's synchronised
folder, so new files in `EveCompanion/` are picked up automatically.

```
EveCompanion/
  App/              entry point, menus, shared state
  Models/           Codable models
  Resources/        ore_locations.json, Help/ (Markdown help articles)
  Services/Engine/  ESI, SSO login, static data, market, industry, history, routes …
  Views/            pages and shared components
scripts/make-dmg.sh packages an exported app as a .dmg
design/            app icon source (SVG) – original artwork, MIT like the code
```

## Licence

MIT – see [LICENSE](LICENSE). EVE Online and the EVE logo are the registered trademarks of CCP hf.
This app was created under the EVE Developer License Agreement and uses data from EVE's ESI,
the EVE Static Data Export and zKillboard.

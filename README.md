# Tallybook

A small, read-only auction house notebook for the World of Warcraft: Forever beta.

- **Min AH Price** on item tooltips, from your own last price scan.
- **Crafting Cost** for anything you can craft: every mat with its price (vendor price when a vendor sells it), and the
  **Profit** or **Loss** of crafting it to sell, after the auction house's 5% cut.
- The cost next to every recipe in the profession window, and a **Profit** panel (`/tally profit`) that lists a whole
  profession sorted by profit.

## What it does and does not do

- It **only reads**. It never posts, bids, buys, cancels or crafts, and it has no code that could.
- It scans **only when you type a command** (`/tally browse`, `/tally scan`); nothing runs on a timer.
- It never reads or stores who is selling: no player names of any kind.
- It is free. There is nothing to buy and no way to pay.

## Install

Copy the `Tallybook` folder into `World of Warcraft\_classic_beta_\Interface\AddOns\`, start the game, and type `/tally`.

| Command | What it does |
|---|---|
| `/tally` | status |
| `/tally browse` | price scan, about 6 seconds - do this once per session at the auction house |
| `/tally scan` | full market snapshot (15 minute cooldown) |
| `/tally profit` | the profit panel for the profession you have open |
| `/tally reload` | reloads the UI so the game writes the addon's saved file |

Known limit of the current beta build: the game does not read addon saved data back after a restart, so prices need one
`/tally browse` per session. `Data.lua` is where learned vendor prices and recipes are handed back as code; the copy here is
empty.

## About this repository

This is the addon's code only, published so that anyone can read it, as Blizzard's UI Add-On Development Policy requires.
It is developed elsewhere and mirrored here per release, which is why the history is one commit per version. Comments that
mention design documents or rule numbers (C7, C11...) refer to notes kept with the development copy.

Not affiliated with or endorsed by Blizzard Entertainment. World of Warcraft is a trademark or registered trademark of
Blizzard Entertainment, Inc.

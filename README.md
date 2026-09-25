# Tallybook

A small, read-only auction house notebook for the World of Warcraft: Forever beta.

- **Lowest now** on item tooltips, from your own last price scan.
- **Craft cost** for anything you can craft: every mat with its price (vendor price when a vendor sells it), and the
  **Profit** (or a red **Profit** with a minus sign) of crafting it to sell, after the auction house's 5% cut.
- The cost next to every recipe in the profession window, and a **Profit** panel (`/tally profit`) that lists a whole
  profession sorted by profit.

## What it does and does not do

- It **only reads**. It never posts, bids, buys, cancels or crafts, and it has no code that could.
- It scans when you open the auction house, or when you type a command (`/tally browse`, `/tally scan`) - see
  "Install" below for how the automatic scan works and how to turn it off. Nothing runs on a timer, and nothing
  else starts itself.
- It never reads or stores who is selling: no player names of any kind.
- It is free. There is nothing to buy and no way to pay.

## Install

Copy the `Tallybook` folder into `World of Warcraft\_classic_beta_\Interface\AddOns\`, start the game, and type `/tally`.

Open the auction house and Tallybook scans it once, by itself (or press **Full scan** for a full snapshot); open a
profession window and it learns your recipes. Nothing to type either way.

A small strip appears beside the auction house window:

- **Full scan** runs a full market snapshot; **Quick scan** runs a quicker price scan - the same two scans the
  commands below trigger (Full scan and Quick scan were called Scan and Browse before 0.11.0; the commands
  themselves haven't changed).
- **Stop** shows up only while a scan is running, and ends it right there.
- An **auto-scan** checkbox, on by default: while it's ticked, opening the auction house runs one Quick scan by
  itself - once per visit, and never while the newest scan anyone in the group has made is under 30 minutes old,
  so a handful of people visiting an auctioneer make a handful of scans a day, not dozens. The scan may start a
  second or two after the house opens rather than the instant it does: the game's own auction house window
  usually spends the client's one query allowance first, so the scan waits for the client to say it is free -
  once. Untick it and the automatic scan stops; the two buttons keep working either way.
- One status line says what's happening: `waiting for the house to accept a query` while the scan waits for the
  client, `scanning ... page 3` while a scan runs, `last scan 6h ago` when the last one is old news, `the house
  is busy - try the button in a moment` if the game's own cooldown turned the query away even then (it isn't
  tried again until you close and reopen the house), or `no prices yet - press Quick scan` the first time. It
  adds `- press Sync to upload` whenever there is something new to send.
- **Sync** uploads what you have learned - it reloads the UI, which is what writes the file (called Send before
  0.11.0; `/tally reload` still does the same thing).

Opening a profession window also reads its recipes, every time - nothing to type there either. A line beside the
**Profit** button confirms it: `✓ learned 41 recipes, 3 new`, with its own **Sync** button beside that line. The
mailbox gets a **Sync** button too, on the mail frame itself, while it's open - see "Your mailbox" below.

Also available, as typed commands - the strip's first two buttons do the same things as the first two rows below:

| Command | What it does |
|---|---|
| `/tally` | status |
| `/tally browse` | price scan, about 6 seconds |
| `/tally scan` | full market snapshot (15 minute cooldown) |
| `/tally selftest` | a small synthetic scan for checking the upload path - made-up prices, labelled so they can never mix into a real market |
| `/tally profit` | the profit panel for the profession you have open |
| `/tally basket <N>` | prices `N` crafts of the recipe you last clicked in the Profit panel (or shift-click an item) against real auction house listings |
| `/tally list profit` or `/tally list cost` | switches whether the profession window's recipe list shows profit or plain cost next to each recipe |
| `/tally reload` | reloads the UI so the game writes the addon's saved file |

Known limit of the current beta build: the game does not read addon saved data back after a restart, so a fresh
session needs one scan - automatic on opening the auction house, or by hand with the button or the command above.
`Data.lua` is where learned vendor prices and recipes are handed back as code; the copy here is empty.

## Your mailbox

When you open your mailbox, Tallybook reads what it's already showing you: for a sold auction, the item, the
count, the price you received, the deposit and the auction house's cut; for one that expired or was
cancelled, the item and the count. It also reads how many days the mail has left, only so it can tell the
same mail apart from a new one later - not something it shows you. It reads while the mailbox is open, and
only because you opened it: nothing happens while it's closed, and nothing goes anywhere until you press
**Sync** (on the strip, on the mail window itself, or `/tally reload`), same as everything else it learns. It
never reads or stores who bought anything, who sent a mail, or any other player's name. A mail from anyone
titled `Auction expired: <name>` or `Auction canceled: <name>` (or `cancelled`, either spelling) is filed as a
returned auction under that name, on your own Sales page only - it never enters the group's figures.

With the tray app and a membership, your own sales and returns then show up in detail on the site - to you
alone. The group only ever sees a median price and how many sold, per item, never whose. In game, the
tooltip's `Market value` line gains a sale rate (`Market value: 16g 95s · sells ~3.2 a day`), and Profit is
worked out from that market value when there is one, quietly falling back to Lowest now when there isn't yet
enough history for it - the same order the profession Profit panel uses, so hovering an item and opening the
panel never disagree.

## The tray app (`tray/`)

Optional. A small Windows program (C#, .NET Framework 4.8) for members of our group: it sends the addon's saved file to
the group's private server and writes one shared `Data.lua` back into the addon's folder, so the game has prices without
scanning. It reads `Tallybook.lua` / `Tallybook.lua.bak` under the World of Warcraft folder **you** pick, writes that one
`Data.lua`, and touches nothing else: it does not look at the game while it runs, find or scan anything by itself, update
itself, or run without its tray icon. `shared/risk-notice.txt` is what every member reads before downloading it. It is
useless without a membership - the server is private - but the source is here so anyone can read what it does.
Build: `dotnet build tray/Tallybook.Tray -c Release`; tests: `dotnet test tray/Tallybook.Tray.Tests`.

## About this repository

This is the code of what our group is handed - the addon, and the optional tray app - published so that anyone can read
it, as Blizzard's UI Add-On Development Policy requires of addons.
It is developed elsewhere and mirrored here per release, which is why the history is one commit per version. Comments that
mention design documents or rule numbers (C7, C11...) refer to notes kept with the development copy.

Not affiliated with or endorsed by Blizzard Entertainment. World of Warcraft is a trademark or registered trademark of
Blizzard Entertainment, Inc.

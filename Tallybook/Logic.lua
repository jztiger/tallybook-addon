-- Tallybook: pure logic. No WoW API in this file, only the Lua 5.1 standard library, so every function
-- here is unit-tested outside the game (addon/tests/logic.test.ts).
--
-- Numbers: the game's Lua 5.1 has one number type (a double). Anything that ends up in a saved string is
-- written with "%d" and never with tostring() or "..", so it reads "1" and never "1.0" on any Lua.

local ADDON, ns = ...
ns = ns or {}
local L = {}
ns.Logic = L

L.VERSION = "0.9.3"
-- Two independent version counters, mirroring the server (src/shared/scan-schema.ts SCAN_SCHEMA_VERSION,
-- src/shared/ref-doc.ts REF_SCHEMA_VERSION): the scan document's shape (replicate, browse) has not changed
-- since M1, so buildDoc still tags SCAN_SCHEMA; the reference document gained items, suffixes and named
-- recipes in M2, so refDoc tags SCHEMA.
L.SCAN_SCHEMA = 1
L.SCHEMA = 2
L.REPLICATE_COOLDOWN = 900
-- What the auction house keeps of a sale, in percent. MEASURED at 5 on Forever, 2026-09-22: a sale of
-- 2100 copper returned 2337 after a 105 copper cut (docs/research/2026-09-22-ah-cut-and-deposit.md).
-- This is only the fallback: the server owns the number, per market, and sends it in the data file, so
-- that the game and the dashboard can never quote different profits. See L.applyBaked.
L.AH_CUT_PERCENT = 5
L.RING_MAX_SCANS = 12
L.RING_MAX_BYTES = 8 * 1024 * 1024
-- The server refuses a document with more rows than this (MAX_ROWS in src/shared/scan-schema.ts; a
-- test holds the two together). The addon never saves one: see Export.save.
L.MAX_ROWS = 250000
-- The bake step does not decode a reference string longer than this (MAX_REF_BASE64_CHARS in
-- src/shared/ref-doc.ts; a test holds the two together, tag included).
L.REF_MAX_BYTES = 4 * 1024 * 1024
-- Auction prices from the data file are not adopted when older than this (the bake and the server do not send
-- older ones either: PRICES_MAX_AGE in src/tools/bake.ts).
L.PRICES_MAX_AGE = 604800
-- M2: item names/quality and suffix names, learned this session (spec 2026-09-23). Mirrors MAX_ITEM_ROWS /
-- MAX_SUFFIX_ROWS / MAX_NAME_CHARS in src/shared/ref-doc.ts.
L.MAX_ITEM_ROWS = 20000
L.MAX_SUFFIX_ROWS = 20000
L.MAX_NAME_CHARS = 128

-- The server refuses any number that is not a safe integer (2^53 - 1).
local MAX_SAFE = 9007199254740991
local FACTIONS = { Horde = true, Alliance = true, Neutral = true }

-- A whole number in [min, 2^53). NaN and infinity fail the comparisons.
local function isCount(v, min)
    return type(v) == "number" and v >= min and v <= MAX_SAFE and v % 1 == 0
end

-- A whole number of either sign.
local function isInt(v)
    return type(v) == "number" and v >= -MAX_SAFE and v <= MAX_SAFE and v % 1 == 0
end

local function countOr0(v)
    if isCount(v, 0) then return v end
    return 0
end

-- 16 lowercase hex characters
local function isUid(v)
    return type(v) == "string" and #v == 16 and string.match(v, "^[0-9a-f]+$") ~= nil
end

-- A learned name (item, suffix, recipe or profession, M2): 1..MAX_NAME_CHARS bytes (UTF-8 is fine).
local function validName(v)
    return type(v) == "string" and #v >= 1 and #v <= L.MAX_NAME_CHARS
end

---------------------------------------------------------------------------------------------------
-- Item links and scan ids
---------------------------------------------------------------------------------------------------

-- "|Hitem:6292::::::1234:..." -> 1234. The suffix id is the 7th field after "item:"
-- (itemID, enchant, four gems, suffix). No link, no match or an empty field -> 0. May be negative.
function L.parseSuffix(link)
    if type(link) ~= "string" then return 0 end
    local field = string.match(link, "item:%-?%d+:[^:|]*:[^:|]*:[^:|]*:[^:|]*:[^:|]*:%s*(%-?%d+)")
    if not field then return 0 end
    local n = tonumber(field)
    if not isInt(n) or n == 0 then return 0 end
    return n
end

-- "|Hitem:4561::::::::20:1485:::1:12728::|h" -> 12728. The variant this client actually records: the
-- FIRST bonus id, which is field 14, guarded by numBonusIDs at field 13.
--
-- Field 7 (what parseSuffix reads) is empty on every row this client produces, so a full scan keyed on
-- it lumped every variant of an item together - board card B6, settled in game 2026-09-21. The bonus id
-- lives in a DIFFERENT id space from the browse key's itemSuffix, and the server holds the crosswalk;
-- the addon never guesses. `numBonusIDs` of 0 means the next field is not a bonus id at all.
-- Evidence: docs/research/2026-09-21-b6-item-variants.md.
function L.parseVariant(link)
    if type(link) ~= "string" then return 0 end
    -- itemID, then 12 fields, then the count and the first id
    local count, first = string.match(
        link,
        "item:%-?%d+:" .. string.rep("[^:|]*:", 11) .. "%s*(%d*):%s*(%-?%d+)")
    if not count or count == "" then return 0 end
    if (tonumber(count) or 0) < 1 then return 0 end
    local n = tonumber(first)
    if not isInt(n) or n == 0 then return 0 end
    return n
end

local HEX = "0123456789abcdef"

-- 8 lowercase hex digits of n modulo 2^32, by hand: "%x" goes through a C long, which is 32 bits
-- on Windows, and this must not depend on that.
local function hex8(n)
    if type(n) ~= "number" or n ~= n or n < 0 or n == math.huge then n = 0 end
    n = math.floor(n) % 4294967296
    local out = ""
    for _ = 1, 8 do
        local digit = n % 16
        out = string.sub(HEX, digit + 1, digit + 1) .. out
        n = (n - digit) / 16
    end
    return out
end

-- 16 lowercase hex characters: the server time, then a random number in [0, 2^31).
function L.newUid(serverTime, rand)
    return hex8(serverTime) .. hex8(rand)
end

-- A random whole number in [0, 2^31). Two small draws: math.random(0, 2^31 - 1) overflows a C int
-- inside Lua 5.1.
function L.rand31()
    return math.random(0, 65535) * 32768 + math.random(0, 32767)
end

---------------------------------------------------------------------------------------------------
-- Guards
---------------------------------------------------------------------------------------------------

-- The cooldown self-guard. -> true, 0   or   false, secondsRemaining
function L.canReplicate(now, lastAt, cooldown)
    if type(now) ~= "number" or type(lastAt) ~= "number" or lastAt <= 0 then return true, 0 end
    local elapsed = now - lastAt
    -- Saved state is not to be trusted blindly: a time far in the future is not one this addon
    -- wrote. A time slightly ahead (clock skew) counts as "just scanned".
    if elapsed < -cooldown then return true, 0 end
    if elapsed < 0 then elapsed = 0 end
    if elapsed >= cooldown then return true, 0 end
    return false, cooldown - elapsed
end

-- nil when the realm / faction / build are good enough to label a scan, else what is wrong.
function L.metaProblem(meta)
    if type(meta) ~= "table" then return "the client did not report a realm" end
    if type(meta.realm) ~= "string" or meta.realm == "" or #meta.realm > 64 then
        return "the client did not report a usable realm name"
    end
    if not FACTIONS[meta.faction] then return "the client did not report a faction" end
    if type(meta.build) ~= "string" or meta.build == "" or #meta.build > 64 then
        return "the client did not report a build number"
    end
    return nil
end

-- The scan document is not re-learned when the newest known scan (own or pooled) is younger than this.
L.AUTO_SCAN_MIN_AGE = 30 * 60

-- The C7 limits (docs/decisions.md, revised 2026-09-23), as one decision: whether the ONE browse scan that
-- may start itself on AUCTION_HOUSE_SHOW is allowed to this time. s = { enabled, ahOpen, scannedThisOpening,
-- newestScanAt, now, cooldownRefused }. Order matters: the house being shut or the switch being off make
-- every other field moot; a scan already run, or refused by the client's own cooldown, is never retried
-- until the next opening; only then does freshness decide.
-- -> "scan" | "skip-off" | "skip-fresh" | "skip-done" | "skip-cooldown" | "skip-closed"
function L.autoScanDecision(s)
    if type(s) ~= "table" or not s.ahOpen then return "skip-closed" end
    if not s.enabled then return "skip-off" end
    if s.scannedThisOpening then return "skip-done" end
    if s.cooldownRefused then return "skip-cooldown" end
    if countOr0(s.now) - countOr0(s.newestScanAt) < L.AUTO_SCAN_MIN_AGE then return "skip-fresh" end
    return "scan"
end

---------------------------------------------------------------------------------------------------
-- Aggregation: (itemID, suffixID, stackCount, stackBuyout) -> number of auctions
---------------------------------------------------------------------------------------------------

local Agg = {}
Agg.__index = Agg

function L.newAggregator()
    return setmetatable({
        rowCount = 0, -- every row handed to add()
        bidOnly = 0,  -- rows with buyout 0: counted, not recorded
        noLink = 0,   -- recorded rows whose item link was missing (variant recorded as 0)
        suffixSeen = 0, -- rows whose link DID fill field 7: 0 on this client, and we want to know if it changes
        invalid = 0,  -- rows the server would refuse: counted, not recorded
        tree = {},    -- itemID -> suffixID -> count -> buyout -> row
        list = {},
        keys = 0,
    }, Agg)
end

-- The buyout is stored exactly as the client gave it: per stack or per unit is the server's call,
-- and nothing here ever divides it by the count.
function Agg:add(itemID, suffixID, count, buyout, hadLink)
    self.rowCount = self.rowCount + 1
    if buyout == 0 then
        self.bidOnly = self.bidOnly + 1
        return
    end
    if not (isCount(itemID, 1) and isCount(count, 1) and isCount(buyout, 1)) then
        self.invalid = self.invalid + 1
        return
    end
    if not isInt(suffixID) then suffixID = 0 end
    if not hadLink then self.noLink = self.noLink + 1 end

    local bySuffix = self.tree[itemID]
    if not bySuffix then
        bySuffix = {}
        self.tree[itemID] = bySuffix
    end
    local byCount = bySuffix[suffixID]
    if not byCount then
        byCount = {}
        bySuffix[suffixID] = byCount
        self.keys = self.keys + 1
    end
    local byBuyout = byCount[count]
    if not byBuyout then
        byBuyout = {}
        byCount[count] = byBuyout
    end
    local row = byBuyout[buyout]
    if row then
        row[5] = row[5] + 1
    else
        row = { itemID, suffixID, count, buyout, 1 }
        byBuyout[buyout] = row
        self.list[#self.list + 1] = row
    end
end

local function rowBefore(a, b)
    for i = 1, 4 do
        if a[i] ~= b[i] then return a[i] < b[i] end
    end
    return false
end

-- -> array of { itemID, suffixID, count, buyout, n }, sorted by itemID, suffixID, count, buyout
function Agg:rows()
    local out = {}
    for i = 1, #self.list do out[i] = self.list[i] end
    table.sort(out, rowBefore)
    return out
end

-- distinct (itemID, suffixID)
function Agg:keyCount()
    return self.keys
end

---------------------------------------------------------------------------------------------------
-- Browse results
---------------------------------------------------------------------------------------------------

-- array of { itemKey = { itemID, itemLevel, itemSuffix }, minPrice, totalQuantity }
--   -> array of { itemID, itemLevel, itemSuffix, minPrice, totalQuantity }
-- Rows with no item id or no price are skipped. No other field of a result is read.
function L.browseRows(results)
    local out = {}
    if type(results) ~= "table" then return out end
    for i = 1, #results do
        local result = results[i]
        local key = type(result) == "table" and result.itemKey
        if type(key) == "table" and isCount(key.itemID, 1) and isCount(result.minPrice, 0) then
            local suffix = key.itemSuffix
            if not isInt(suffix) then suffix = 0 end
            out[#out + 1] = { key.itemID, countOr0(key.itemLevel), suffix, result.minPrice, countOr0(result.totalQuantity) }
        end
    end
    return out
end

-- -> { [itemID] = lowest minPrice across its variants }, prices above 0 only. For the tooltip.
function L.priceTable(browseRows)
    local prices = {}
    if type(browseRows) ~= "table" then return prices end
    for i = 1, #browseRows do
        local row = browseRows[i]
        local itemID, price = row[1], row[4]
        if isCount(itemID, 1) and isCount(price, 1) and (prices[itemID] == nil or price < prices[itemID]) then
            prices[itemID] = price
        end
    end
    return prices
end

-- -> { [itemID] = how many are listed, all variants together }. For the Profit panel's "Listed" column.
function L.listedTable(browseRows)
    local listed = {}
    if type(browseRows) ~= "table" then return listed end
    for i = 1, #browseRows do
        local row = browseRows[i]
        if type(row) == "table" and isCount(row[1], 1) and isCount(row[5], 0) then
            listed[row[1]] = (listed[row[1]] or 0) + row[5]
        end
    end
    return listed
end

---------------------------------------------------------------------------------------------------
-- The scan document (design spec section 5; src/shared/scan-schema.ts is the contract)
---------------------------------------------------------------------------------------------------

-- extra = { uid =, rowCount =, bidOnly =, noLink = }   (bidOnly / noLink: replicate only)
-- A Lua table cannot hold a nil, so `copper` is simply absent when the client cannot say.
function L.buildDoc(meta, kind, complete, t0, t1, rows, extra)
    if type(meta) ~= "table" then meta = {} end
    if type(extra) ~= "table" then extra = {} end
    if type(rows) ~= "table" then rows = {} end
    t0 = countOr0(t0)
    t1 = countOr0(t1)
    if t1 < t0 then t1 = t0 end

    local uid = extra.uid
    if not isUid(uid) then uid = L.newUid(t0, L.rand31()) end

    local doc = {
        schema = L.SCAN_SCHEMA,
        uid = uid,
        kind = kind,
        complete = complete and true or false,
        t0 = t0,
        t1 = t1,
        region = countOr0(meta.region),
        realm = type(meta.realm) == "string" and meta.realm or "",
        faction = type(meta.faction) == "string" and meta.faction or "",
        build = type(meta.build) == "string" and meta.build or "",
        interface = countOr0(meta.interface),
        addon = type(meta.addon) == "string" and meta.addon or L.VERSION,
        rowCount = countOr0(extra.rowCount),
        rows = rows,
    }
    if type(meta.copper) == "boolean" then doc.copper = meta.copper end
    if kind == "replicate" then
        doc.bidOnly = countOr0(extra.bidOnly)
        doc.noLink = countOr0(extra.noLink)
        -- Which id space the rows' variant column is in. The server cannot tell by looking, and a bonus
        -- id is NOT an itemSuffix - board card B6. "suffix" only for a build that fills link field 7.
        doc.variant = extra.variant == "suffix" and "suffix" or "bonus"
        doc.suffixSeen = countOr0(extra.suffixSeen)
    end
    return doc
end

---------------------------------------------------------------------------------------------------
-- Chunks, the end sentinel and the ring
---------------------------------------------------------------------------------------------------

-- -> "j1:<uid>:<part>/<parts>:<b64>"   (concatenation, not "%s": the payload can be megabytes)
function L.chunkTag(uid, part, parts, b64)
    return "j1:" .. tostring(uid) .. ":" .. string.format("%d/%d", part, parts) .. ":" .. tostring(b64)
end

-- "j1:<uid>:<part>/<parts>:..." -> uid ; anything else -> nil
function L.uidOf(chunk)
    if type(chunk) ~= "string" then return nil end
    local uid = string.match(chunk, "^j1:(%x+):%d+/%d+:")
    if isUid(uid) then return uid end
    return nil
end

-- Removes every "end:<n>" entry, in place. Anything else that is not a chunk goes too: the server
-- counts chunk strings and compares with the sentinel, so a stray entry would get the whole file
-- refused.
function L.stripSentinel(chunks)
    if type(chunks) ~= "table" then return {} end
    local n = #chunks
    local kept = 0
    for i = 1, n do
        local chunk = chunks[i]
        if L.uidOf(chunk) then
            kept = kept + 1
            chunks[kept] = chunk
        end
    end
    for i = kept + 1, n do chunks[i] = nil end
    return chunks
end

-- stripSentinel, then appends "end:<number of chunk strings>". Safe to call any number of times.
function L.appendSentinel(chunks)
    chunks = L.stripSentinel(chunks)
    chunks[#chunks + 1] = "end:" .. string.format("%d", #chunks)
    return chunks
end

-- -> number of scans, bytes of chunk text
function L.ringStats(chunks)
    local scans, bytes = 0, 0
    if type(chunks) ~= "table" then return scans, bytes end
    local seen = {}
    for i = 1, #chunks do
        local uid = L.uidOf(chunks[i])
        if uid then
            bytes = bytes + #chunks[i]
            if not seen[uid] then
                seen[uid] = true
                scans = scans + 1
            end
        end
    end
    return scans, bytes
end

local function dropUid(chunks, uid)
    local n = #chunks
    local kept = 0
    for i = 1, n do
        local chunk = chunks[i]
        if L.uidOf(chunk) ~= uid then
            kept = kept + 1
            chunks[kept] = chunk
        end
    end
    for i = kept + 1, n do chunks[i] = nil end
end

-- Appends newChunks (all the parts of one scan), then evicts whole scans from the front until both
-- caps hold. The scan just added is never evicted. Leaves no sentinel: the caller seals the ring.
-- -> chunks, evicted   (the uids that were pushed out, oldest first; the caller tells the player,
-- because a scan that was never written to disk is gone for good)
function L.ringPush(chunks, newChunks, maxScans, maxBytes)
    chunks = L.stripSentinel(chunks)
    local evicted = {}
    if type(newChunks) ~= "table" then return chunks, evicted end
    local newUid = L.uidOf(newChunks[1])
    if not newUid then return chunks, evicted end
    dropUid(chunks, newUid) -- the same scan twice would be refused by the server as a duplicate part
    for i = 1, #newChunks do
        if L.uidOf(newChunks[i]) == newUid then chunks[#chunks + 1] = newChunks[i] end
    end
    while true do
        local scans, bytes = L.ringStats(chunks)
        if scans <= maxScans and bytes <= maxBytes then break end
        local oldest = L.uidOf(chunks[1])
        if oldest == nil or oldest == newUid then break end
        dropUid(chunks, oldest)
        evicted[#evicted + 1] = oldest
    end
    return chunks, evicted
end

-- The server time a uid was made at (its first 8 hex digits), or nil. Digit by digit, like hex8:
-- tonumber(text, 16) goes through a C integer whose width this must not depend on.
function L.uidTime(uid)
    if not isUid(uid) then return nil end
    local n = 0.0 -- written as a float so that a Lua with 32-bit integers (the test VM) cannot wrap it
    for i = 1, 8 do
        n = n * 16 + (string.find(HEX, string.sub(uid, i, i), 1, true) - 1)
    end
    return n
end

---------------------------------------------------------------------------------------------------
-- Saved state
---------------------------------------------------------------------------------------------------

-- Brings whatever was saved (possibly nothing: saved state does not survive a client restart) to
-- the layout in design spec section 4. Reuses the saved table. Does not touch the sentinel.
function L.initDB(db)
    if type(db) ~= "table" then db = {} end
    db.v = 1
    if type(db.state) ~= "table" then db.state = {} end
    if not isCount(db.state.lastReplicateAt, 0) then db.state.lastReplicateAt = 0 end
    if not isCount(db.state.lastBrowseAt, 0) then db.state.lastBrowseAt = 0 end
    if type(db.prices) ~= "table" then db.prices = {} end
    if not isCount(db.pricesAt, 0) then db.pricesAt = 0 end
    if type(db.chunks) ~= "table" then db.chunks = {} end
    if type(db.recipes) ~= "table" then db.recipes = {} end
    if type(db.vendor) ~= "table" then db.vendor = {} end
    if type(db.listed) ~= "table" then db.listed = {} end
    if type(db.settings) ~= "table" then db.settings = {} end
    if type(db.items) ~= "table" then db.items = {} end
    if type(db.suffixes) ~= "table" then db.suffixes = {} end
    -- where the prices came from when not from this session's own scan: the data file's "saved" or "shared"
    if db.pricesFrom ~= "saved" and db.pricesFrom ~= "shared" then db.pricesFrom = nil end
    return db
end

---------------------------------------------------------------------------------------------------
-- Crafting cost (tooltip line "Crafting Cost: ..."). Pure arithmetic on three tables the addon keeps:
--   recipes[outputItemID] = { { recipeID =, qty = <items made>, mats = { {itemID, qty}, ... } }, ... }
--   prices[itemID]        = cheapest auction unit price, from the last complete browse scan
--   vendor[itemID]        = unit price at a vendor the player has visited; when known it always wins
---------------------------------------------------------------------------------------------------

local function validMats(mats)
    if type(mats) ~= "table" or #mats == 0 then return false end
    for i = 1, #mats do
        local m = mats[i]
        if type(m) ~= "table" or not isCount(m[1], 1) or not isCount(m[2], 1) then return false end
    end
    return true
end

-- What one unit of a mat costs: the VENDOR price whenever a vendor is known to sell it (unlimited supply at a
-- fixed price - one cheap auction listing must not make a craft look cheaper than it is), otherwise the
-- cheapest auction price; nil when neither is known.
-- -> price, "vendor" | "ah"
local function unitPrice(itemID, prices, vendor)
    local shop = type(vendor) == "table" and vendor[itemID] or nil
    if isCount(shop, 1) then return shop, "vendor" end
    local ah = type(prices) == "table" and prices[itemID] or nil
    if isCount(ah, 1) then return ah, "ah" end
    return nil
end

-- -> total copper for the mats that have a price, how many mats have none, the cost of ONE item made.
-- A mat with no price is never treated as free: it is left out of the total and counted.
-- -> nil when the recipe cannot be priced at all (no mats, broken numbers).
function L.craftingCost(recipe, prices, vendor)
    if type(recipe) ~= "table" or not validMats(recipe.mats) then return nil end
    local qty = isCount(recipe.qty, 1) and recipe.qty or 1
    local total, missing = 0, 0
    for i = 1, #recipe.mats do
        local m = recipe.mats[i]
        local price = (unitPrice(m[1], prices, vendor))
        if price then total = total + price * m[2] else missing = missing + 1 end
    end
    return total, missing, math.ceil(total / qty)
end

-- The same sum, mat by mat, for the tooltip: { { itemID =, qty =, unit =, total =, source = "vendor" | "ah" }, ... }
-- in recipe order. A mat with no price has no unit, total or source. The totals always add up to craftingCost.
function L.costBreakdown(recipe, prices, vendor)
    local rows = {}
    if type(recipe) ~= "table" or not validMats(recipe.mats) then return rows end
    for i = 1, #recipe.mats do
        local m = recipe.mats[i]
        local price, source = unitPrice(m[1], prices, vendor)
        rows[i] = { itemID = m[1], qty = m[2], unit = price, total = price and price * m[2] or nil, source = source }
    end
    return rows
end

-- Crafting to sell: what the recipe makes, sold at the cheapest current listing, less the auction house's cut,
-- less the mats. -> profit (negative = a loss), revenue after the cut
-- -> nil when it would be a guess: a mat with no price (the cost is understated) or nobody selling the item.
-- The deposit is left out: it comes back when the item sells.
function L.craftingProfit(total, missing, qty, salePrice)
    if not isCount(total, 0) or missing ~= 0 or not isCount(salePrice, 1) then return nil end
    if not isCount(qty, 1) then qty = 1 end
    local revenue = math.floor(salePrice * qty * (100 - L.AH_CUT_PERCENT) / 100)
    return revenue - total, revenue
end

-- Several recipes can make the same item: prefer one whose mats are all priced, then the cheapest per item.
-- -> recipeID, total, missing, perItem, recipe   (nil when there is nothing to choose from)
function L.cheapestRecipe(recipes, prices, vendor)
    local best
    if type(recipes) ~= "table" then return nil end
    for i = 1, #recipes do
        local total, missing, each = L.craftingCost(recipes[i], prices, vendor)
        if total and (not best or missing < best.missing or (missing == best.missing and each < best.each)) then
            best = { id = recipes[i].recipeID, total = total, missing = missing, each = each, recipe = recipes[i] }
        end
    end
    if not best then return nil end
    return best.id, best.total, best.missing, best.each, best.recipe
end

-- Files one recipe under its output item; seeing the same recipe again replaces it. name, professionName
-- and skillLine (M2) are optional and ride along on the entry for refDoc to read; a recipe with none of
-- them yet is still filed here for this session's own Crafting Cost. -> true when stored.
function L.addRecipe(book, outputItemID, recipeID, qty, mats, name, professionName, skillLine)
    if type(book) ~= "table" or not isCount(outputItemID, 1) or not isCount(recipeID, 1) then return false end
    if not isCount(qty, 1) or not validMats(mats) then return false end
    local copy = {}
    for i = 1, #mats do copy[i] = { mats[i][1], mats[i][2] } end
    local entry = { recipeID = recipeID, qty = qty, mats = copy, name = name, profession = professionName, skillLine = skillLine }
    local list = book[outputItemID]
    if type(list) ~= "table" then
        list = {}
        book[outputItemID] = list
    end
    for i = 1, #list do
        if type(list[i]) == "table" and list[i].recipeID == recipeID then
            list[i] = entry
            return true
        end
    end
    list[#list + 1] = entry
    return true
end

-- How many entries a table holds. Only used to enforce the item/suffix caps below: their keys (an itemID,
-- or "itemID:suffixID") are not dense, so # is not reliable on them.
local function tableSize(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- An item's name and quality (M2), learned once this session: the name never changes, so a later call for
-- an id already known is a no-op rather than a rewrite. name is 1..MAX_NAME_CHARS bytes (UTF-8 is fine);
-- quality an integer 0..7. -> true when recorded
function L.noteItem(db, itemID, name, quality)
    if type(db) ~= "table" or type(db.items) ~= "table" then return false end
    if not isCount(itemID, 1) then return false end
    if not validName(name) then return false end
    if not isCount(quality, 0) or quality > 7 then return false end
    if db.items[itemID] ~= nil then return false end
    -- The cap check used to walk the whole table (tableSize) on every new id - free while few are known,
    -- but a session that learns thousands would re-walk a growing table on each one. A running count,
    -- lazily seeded from whatever db.items already holds the first time this runs (so a table filled some
    -- other way, e.g. loaded state, still counts correctly), keeps every call after that O(1).
    db.itemCount = db.itemCount or tableSize(db.items)
    if db.itemCount >= L.MAX_ITEM_ROWS then return false end
    db.items[itemID] = { name, quality }
    db.itemCount = db.itemCount + 1
    return true
end

-- The full name of one random-suffix item (M2), e.g. "Hunting Gloves of the Bear", keyed by item AND
-- suffix: the same suffix reads differently on different base items. suffixID may be negative but never 0
-- (that means no suffix, and needs no name). -> true when recorded
function L.noteSuffix(db, itemID, suffixID, fullName)
    if type(db) ~= "table" or type(db.suffixes) ~= "table" then return false end
    if not isCount(itemID, 1) or not isInt(suffixID) or suffixID == 0 then return false end
    if not validName(fullName) then return false end
    local key = itemID .. ":" .. suffixID
    if db.suffixes[key] ~= nil then return false end
    db.suffixCount = db.suffixCount or tableSize(db.suffixes) -- see L.noteItem
    if db.suffixCount >= L.MAX_SUFFIX_ROWS then return false end
    db.suffixes[key] = { itemID, suffixID, fullName }
    db.suffixCount = db.suffixCount + 1
    return true
end

-- One merchant row -> the copper price of ONE item, or nil when it is not a plain, always-available gold
-- purchase (another currency, or limited stock that may not be there next time).
function L.vendorUnitPrice(item)
    if type(item) ~= "table" or item.hasExtendedCost == true then return nil end
    if not isCount(item.price, 1) then return nil end
    if item.numAvailable ~= nil and item.numAvailable ~= -1 then return nil end
    local stack = isCount(item.stackCount, 1) and item.stackCount or 1
    return math.ceil(item.price / stack)
end

---------------------------------------------------------------------------------------------------
-- The basket (board card F13): what N crafts really cost. "Cheapest listing x quantity" is optimistic for a
-- batch - the cheap listings run out. Given each auction-house mat's price ladder (Scan.ladders), buy from
-- the cheapest tier up. Vendor mats stay at the vendor price: unlimited supply.
---------------------------------------------------------------------------------------------------

L.BASKET_MAX_CRAFTS = 1000

-- tiers: { {unitPrice, quantity}, ... } in any order. -> cost of the cheapest `need` units, how many were there
function L.walkLadder(tiers, need)
    local sorted = {}
    if type(tiers) == "table" then
        for i = 1, #tiers do
            local t = tiers[i]
            if type(t) == "table" and isCount(t[1], 1) and isCount(t[2], 1) then sorted[#sorted + 1] = t end
        end
    end
    table.sort(sorted, function(a, b) return a[1] < b[1] end)
    local cost, bought = 0, 0
    if not isCount(need, 1) then return cost, bought end
    for i = 1, #sorted do
        if bought >= need then break end
        local take = math.min(sorted[i][2], need - bought)
        cost = cost + take * sorted[i][1]
        bought = bought + take
    end
    return cost, bought
end

-- The mats whose ladder has to be asked for: no vendor sells them. Each once, in recipe order.
function L.ladderMats(recipe, vendor)
    local out, seen = {}, {}
    if type(recipe) ~= "table" or not validMats(recipe.mats) then return out end
    for i = 1, #recipe.mats do
        local itemID = recipe.mats[i][1]
        local shop = type(vendor) == "table" and vendor[itemID] or nil
        if not isCount(shop, 1) and not seen[itemID] then
            seen[itemID] = true
            out[#out + 1] = itemID
        end
    end
    return out
end

-- ladders: { [itemID] = tiers }. -> { crafts, total, perCraft, short, missing, rows = { { itemID, need, bought,
-- cost, cheapest, source = "vendor" | "ah" }, ... } }   or nil for a recipe or a number of crafts that makes no sense.
-- short: mats with fewer listed than needed (priced as far as they go). missing: mats with nothing to price them
-- by. Neither is ever counted as free - the total is then a floor, and the caller says so.
function L.basket(recipe, crafts, vendor, ladders)
    if type(recipe) ~= "table" or not validMats(recipe.mats) then return nil end
    if not isCount(crafts, 1) or crafts > L.BASKET_MAX_CRAFTS then return nil end
    local out = { crafts = crafts, total = 0, short = 0, missing = 0, rows = {} }
    for i = 1, #recipe.mats do
        local itemID, need = recipe.mats[i][1], recipe.mats[i][2] * crafts
        local row = { itemID = itemID, need = need, bought = 0, cost = 0 }
        local shop = type(vendor) == "table" and vendor[itemID] or nil
        local tiers = type(ladders) == "table" and ladders[itemID] or nil
        if isCount(shop, 1) then
            row.bought, row.cost, row.cheapest, row.source = need, shop * need, shop, "vendor"
        elseif type(tiers) == "table" then
            row.cost, row.bought = L.walkLadder(tiers, need)
            if row.bought > 0 then
                row.source = "ah"
                row.cheapest = (L.walkLadder(tiers, 1))
            end
        end
        if row.bought == 0 then
            out.missing = out.missing + 1
        elseif row.bought < need then
            out.short = out.short + 1
        end
        out.total = out.total + row.cost
        out.rows[i] = row
    end
    out.perCraft = math.ceil(out.total / crafts)
    return out
end

-- recipes[outputItemID] lists -> { [recipeID] = entry }, { [recipeID] = outputItemID }.
-- The profession window lists recipes, not items.
function L.recipeIndex(book)
    local index, outputs = {}, {}
    if type(book) ~= "table" then return index, outputs end
    for outputItemID, list in pairs(book) do
        if type(list) == "table" then
            for i = 1, #list do
                local entry = list[i]
                if type(entry) == "table" and isCount(entry.recipeID, 1) and validMats(entry.mats) then
                    index[entry.recipeID] = entry
                    if isCount(outputItemID, 1) then outputs[entry.recipeID] = outputItemID end
                end
            end
        end
    end
    return index, outputs
end

---------------------------------------------------------------------------------------------------
-- The profit summary of a whole profession (Summary.lua): the tooltip's numbers, one row per recipe.
---------------------------------------------------------------------------------------------------

-- recipeIDs: the open profession's recipes, in the game's order. index, outputs: from recipeIndex.
-- -> rows { recipeID, itemID, qty, cost, missing, sale, profit, status = "profit" | "loss" | "unknown",
--          why = "mats" | "nosale" }, counts { profit, loss, unknown }
-- sale is what the recipe makes at the cheapest listing, before the cut; profit is after it. Breaking even is
-- a profit. A recipe never read, or one that makes no item, is left out: there is nothing honest to say.
function L.profitSummary(recipeIDs, index, outputs, prices, vendor, listed)
    local rows, counts = {}, { profit = 0, loss = 0, unknown = 0 }
    if type(recipeIDs) ~= "table" or type(index) ~= "table" or type(outputs) ~= "table" then return rows, counts end
    for i = 1, #recipeIDs do
        local recipeID = recipeIDs[i]
        local entry, itemID = index[recipeID], outputs[recipeID]
        local cost, missing = L.craftingCost(entry, prices, vendor)
        if cost and isCount(itemID, 1) then
            local qty = isCount(entry.qty, 1) and entry.qty or 1
            local row = { recipeID = recipeID, itemID = itemID, qty = qty, cost = cost, missing = missing }
            if type(listed) == "table" and isCount(listed[itemID], 0) then row.listed = listed[itemID] end
            local price = type(prices) == "table" and prices[itemID] or nil
            local profit = L.craftingProfit(cost, missing, qty, price)
            if profit then
                row.sale, row.profit = price * qty, profit
                row.status = profit >= 0 and "profit" or "loss"
            else
                row.status = "unknown"
                row.why = missing > 0 and "mats" or "nosale"
            end
            counts[row.status] = counts[row.status] + 1
            rows[#rows + 1] = row
        end
    end
    return rows, counts
end

local SORT_KEYS = { profit = "number", cost = "number", sale = "number", listed = "number", name = "string" }

-- Sorts in place and returns rows. A row with nothing under this key goes last in either direction; ties
-- keep recipe order, so the list never shuffles between refreshes. An unknown key leaves the order alone.
function L.sortSummary(rows, key, descending)
    if type(rows) ~= "table" or not SORT_KEYS[key] then return rows end
    local kind = SORT_KEYS[key]
    local function value(row)
        local v = row[key]
        if type(v) ~= kind then return nil end
        if kind == "string" then return string.lower(v) end
        return v
    end
    table.sort(rows, function(a, b)
        local va, vb = value(a), value(b)
        if va ~= vb then
            if va == nil then return false end
            if vb == nil then return true end
            if descending then return va > vb end
            return va < vb
        end
        return (a.recipeID or 0) < (b.recipeID or 0)
    end)
    return rows
end

---------------------------------------------------------------------------------------------------
-- Reference data. Saved data is never read back on this client (CLAUDE.md), so what never changes -
-- vendor prices and recipes - leaves the game as one "reference document" in the saved file and comes
-- back as addon code: Data.lua, written by the bake step (src/shared/bake.ts) and loaded like any
-- other file of the addon. Learned this session always beats baked; baked only fills the gaps.
---------------------------------------------------------------------------------------------------

-- What the player has chosen, remembered two ways: TallybookDB.settings (read back the day the client reads
-- saved data again) and, until then, the baked copy that went out in the reference document and came back in
-- Data.lua at the last install. Saved beats baked beats the default, field by field; anything that is not a
-- known value is ignored. panel = { point, relativePoint, x, y } of the Profit panel after a drag.
local LIST_MODES = { profit = true, cost = true }
local POINTS = { TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true, RIGHT = true,
    BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true }

local function finite(v)
    return type(v) == "number" and v == v and v > -1e6 and v < 1e6
end

local function validPanel(p)
    return type(p) == "table" and POINTS[p[1]] and POINTS[p[2]] and finite(p[3]) and finite(p[4])
end

-- Only the fields that hold a usable value, copied.
local function cleanSettings(src)
    local out = {}
    if type(src) ~= "table" then return out end
    if LIST_MODES[src.list] then out.list = src.list end
    if SORT_KEYS[src.sortKey] then out.sortKey = src.sortKey end
    for _, flag in ipairs({ "sortDesc", "knownOnly", "hideUnknown", "autoScan" }) do
        if type(src[flag]) == "boolean" then out[flag] = src[flag] end
    end
    if validPanel(src.panel) then
        local function cents(v) return math.floor(v * 100 + 0.5) / 100 end
        out.panel = { src.panel[1], src.panel[2], cents(src.panel[3]), cents(src.panel[4]) }
    end
    return out
end

function L.settings(saved, baked)
    local out = { list = "profit", sortKey = "profit", sortDesc = true, knownOnly = true, hideUnknown = false,
        autoScan = true }
    for _, layer in ipairs({ cleanSettings(baked), cleanSettings(saved) }) do
        for key, value in pairs(layer) do out[key] = value end
    end
    return out
end

local function sortedKeys(tbl)
    local keys = {}
    for k in pairs(tbl) do
        if isCount(k, 1) then keys[#keys + 1] = k end
    end
    table.sort(keys)
    return keys
end

-- -> { schema, kind = "ref", at, addon, vendor = { {itemID, price}, ... }, recipes = { {outputItemID,
-- recipeID, qty, { {itemID, qty}, ... }, name, profession, skillLine}, ... }, items = { {itemID, name,
-- quality}, ... }, suffixes = { {itemID, suffixID, name}, ... } }, all sorted; nil when there is nothing
-- to tell. Arrays throughout: JSON has no numeric keys. src/shared/ref-doc.ts is the contract.
--
-- A recipe rides along only once it has a name and a profession (M2, C16 decision 1): one learned before
-- names existed stays in db.recipes for this session's own Crafting Cost, but is left out here rather than
-- sent as a v1-shaped row - it is relearned, with its name, the next time its profession window opens,
-- which is the same moment it would have been sent anyway.
function L.refDoc(db, at)
    if type(db) ~= "table" then return nil end
    local vendor, recipes = {}, {}
    if type(db.vendor) == "table" then
        local ids = sortedKeys(db.vendor)
        for i = 1, #ids do
            local price = db.vendor[ids[i]]
            if isCount(price, 1) then vendor[#vendor + 1] = { ids[i], price } end
        end
    end
    if type(db.recipes) == "table" then
        local outputs = sortedKeys(db.recipes)
        for i = 1, #outputs do
            local byRecipe = L.recipeIndex({ db.recipes[outputs[i]] })
            local recipeIDs = sortedKeys(byRecipe)
            for j = 1, #recipeIDs do
                local entry = byRecipe[recipeIDs[j]]
                if validName(entry.name) and validName(entry.profession) then
                    local mats = {}
                    for m = 1, #entry.mats do mats[m] = { entry.mats[m][1], entry.mats[m][2] } end
                    recipes[#recipes + 1] = { outputs[i], entry.recipeID, isCount(entry.qty, 1) and entry.qty or 1,
                        mats, entry.name, entry.profession, isCount(entry.skillLine, 0) and entry.skillLine or 0 }
                end
            end
        end
    end
    -- Variant pairs (board card B6): bonus id -> item suffix, learned from auctions this player looked at.
    -- Both sides must be real ids; 0 means "no variant" on either side and pairs with nothing.
    local variants = {}
    if type(db.variants) == "table" then
        local bonusIDs = sortedKeys(db.variants)
        for i = 1, #bonusIDs do
            local suffix = db.variants[bonusIDs[i]]
            if isCount(suffix, 1) then variants[#variants + 1] = { bonusIDs[i], suffix } end
        end
    end
    -- Item names and quality (M2), keyed by itemID like vendor prices.
    local items = {}
    if type(db.items) == "table" then
        local ids = sortedKeys(db.items)
        for i = 1, #ids do
            local it = db.items[ids[i]]
            if type(it) == "table" and validName(it[1]) and isCount(it[2], 0) and it[2] <= 7 then
                items[#items + 1] = { ids[i], it[1], it[2] }
            end
        end
    end
    -- Suffix full names (M2), stored under a composite "itemID:suffixID" key; sorted by the (itemID,
    -- suffixID) the row itself carries rather than that string, so item 10's suffixes do not sort before
    -- item 2's.
    local suffixes = {}
    if type(db.suffixes) == "table" then
        for _, s in pairs(db.suffixes) do
            if type(s) == "table" and isCount(s[1], 1) and isInt(s[2]) and s[2] ~= 0 and validName(s[3]) then
                suffixes[#suffixes + 1] = { s[1], s[2], s[3] }
            end
        end
        table.sort(suffixes, function(a, b)
            if a[1] ~= b[1] then return a[1] < b[1] end
            return a[2] < b[2]
        end)
    end
    local settings = cleanSettings(db.settings)
    local hasSettings = false
    for _ in pairs(settings) do
        hasSettings = true
        break
    end
    if #vendor == 0 and #recipes == 0 and #variants == 0 and #items == 0 and #suffixes == 0 and not hasSettings then
        return nil
    end
    local doc = { schema = L.SCHEMA, kind = "ref", at = countOr0(at), addon = L.VERSION, vendor = vendor, recipes = recipes }
    if #variants > 0 then doc.variants = variants end
    if hasSettings then doc.settings = settings end
    if #items > 0 then doc.items = items end
    if #suffixes > 0 then doc.suffixes = suffixes end
    return doc
end

-- -> "r2:<b64>"   (its own tag: the scan extractor on the server only ever looks for "j1:" and "end:")
function L.refTag(b64)
    return "r2:" .. tostring(b64)
end

-- "r2:<b64>" -> b64 ; anything else -> nil. This client only ever writes r2 now (the server still reads an
-- r1 from an addon that has not updated, but Export.saveRef only ever checks its OWN tag right back).
function L.refOf(text)
    if type(text) ~= "string" then return nil end
    return string.match(text, "^r2:([A-Za-z0-9+/=]+)$")
end

-- Whole numbers from one id -> value table, copied. -> the copy, how many
local function cleanCounts(src, minValue)
    local out, n = {}, 0
    if type(src) ~= "table" then return out, n end
    for id, value in pairs(src) do
        if isCount(id, 1) and isCount(value, minValue) then
            out[id] = value
            n = n + 1
        end
    end
    return out, n
end

-- Auction prices in the data file (F10): the owner's own last scan ("saved", local bake) or the newest scan
-- anyone uploaded ("shared", the server). NEWEST WINS: they are adopted only when newer than what the session
-- has - so the player's own /tally browse always takes over - and never when older than PRICES_MAX_AGE.
-- now may be nil (no clock yet): the age is then not checked. -> how many prices were adopted
local function adoptPrices(db, baked, now)
    if not isCount(baked.pricesAt, 1) or baked.pricesAt <= db.pricesAt then return 0 end
    if isCount(now, 1) and now - baked.pricesAt > L.PRICES_MAX_AGE then return 0 end
    local prices, n = cleanCounts(baked.prices, 1)
    if n == 0 then return 0 end
    db.prices, db.pricesAt = prices, baked.pricesAt
    db.listed = cleanCounts(baked.listed, 0)
    db.pricesFrom = baked.pricesFrom == "saved" and "saved" or "shared"
    return n
end

-- Copies into db whatever the baked tables know and this session does not.
-- -> vendor prices added, recipes added, auction prices adopted
function L.applyBaked(db, baked, now)
    local vendorAdded, recipesAdded = 0, 0
    if type(db) ~= "table" or type(baked) ~= "table" then return vendorAdded, recipesAdded, 0 end
    db = L.initDB(db)
    -- The server's cut for this market. A figure it cannot justify is ignored rather than adopted: a
    -- wrong cut is worse than a stale one, because every profit on screen would quietly be wrong.
    local cut = baked.ahCutPercent
    if type(cut) == "number" and cut == cut and cut >= 0 and cut <= 100 then
        L.AH_CUT_PERCENT = cut
    end
    if type(baked.vendor) == "table" then
        for itemID, price in pairs(baked.vendor) do
            if isCount(itemID, 1) and isCount(price, 1) and db.vendor[itemID] == nil then
                db.vendor[itemID] = price
                vendorAdded = vendorAdded + 1
            end
        end
    end
    if type(baked.recipes) == "table" then
        local known = L.recipeIndex(db.recipes)
        for outputItemID, list in pairs(baked.recipes) do
            if type(list) == "table" then
                for i = 1, #list do
                    local entry = list[i]
                    -- name / profession / skillLine ride along when the baked entry has them (it will not
                    -- today: the bake step does not carry a recipe row past its first 4 fields), so this
                    -- reads whatever a future bake step hands back rather than silently dropping it.
                    if type(entry) == "table" and known[entry.recipeID] == nil
                        and L.addRecipe(db.recipes, outputItemID, entry.recipeID, entry.qty, entry.mats,
                            entry.name, entry.profession, entry.skillLine) then
                        known[entry.recipeID] = true
                        recipesAdded = recipesAdded + 1
                    end
                end
            end
        end
    end
    return vendorAdded, recipesAdded, adoptPrices(db, baked, now)
end

---------------------------------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------------------------------

-- 45 -> "45s", 600 -> "10m", 7200 -> "2h", 200000 -> "2d"
function L.formatAge(seconds)
    if type(seconds) ~= "number" or seconds ~= seconds or seconds < 0 then seconds = 0 end
    if seconds == math.huge then return "?" end
    if seconds < 60 then return string.format("%.0f", math.floor(seconds)) .. "s" end
    if seconds < 3600 then return string.format("%.0f", math.floor(seconds / 60)) .. "m" end
    if seconds < 86400 then return string.format("%.0f", math.floor(seconds / 3600)) .. "h" end
    return string.format("%.0f", math.floor(seconds / 86400)) .. "d"
end

-- 123456 -> "12g 34s 56c"; 5000 -> "50s"; 0 -> "0c". Plain text, for clients without a coin formatter.
-- "%.0f" and not "%d": a big gold figure does not fit the C long behind "%d" on Windows.
function L.formatMoney(copper)
    if not isCount(copper, 0) then copper = 0 end
    local c = copper % 100
    local s = ((copper - c) / 100) % 100
    local g = (copper - c - s * 100) / 10000
    local parts = {}
    if g > 0 then parts[#parts + 1] = string.format("%.0f", g) .. "g" end
    if s > 0 then parts[#parts + 1] = string.format("%.0f", s) .. "s" end
    if c > 0 or #parts == 0 then parts[#parts + 1] = string.format("%.0f", c) .. "c" end
    return table.concat(parts, " ")
end

return L

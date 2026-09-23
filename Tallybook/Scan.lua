-- Tallybook: the auction house scans. Read-only: this file asks the auction house for listings and
-- reads them; it never changes anything there.
--
-- Rules this file keeps (docs/decisions.md C5-C7, C11):
--   * A scan starts only from Scan.replicate / Scan.browse / Scan.selftest, which are called by the
--     typed /tally commands and by the auction house strip's own buttons - and, for the browse scan
--     alone, once per opening of the auction house (C7 as revised 2026-09-23: the six limits on that
--     one are all in Strip.lua; nothing in this file decides it). Event handlers and timers below do
--     nothing unless such a scan is running, and then they only carry that one scan forward. Nothing
--     re-arms itself.
--   * Player names are never read: the four name positions of a replicate row are discarded in
--     the assignment itself, and only itemKey / minPrice / totalQuantity of a browse row are read.
--   * One request per player action for the full scan, with a self-imposed cooldown; browse pages
--     are asked for one at a time and only when the client says its throttle is ready.
--   * A scan only ever claims to be complete when everything it was asked to cover was read from
--     results that are provably its own: the server reads "not listed in a complete scan" as
--     "sold out", for good. When in doubt a scan is incomplete, or not exported at all.
--
-- Call shapes follow spikes/ForeverAHProbe, which ran on the real client: replicate rows are
-- 0-indexed, `sorts` is an array of tables, item data can be missing on a row.

local _, ns = ...
local Logic = ns.Logic

local Scan = {}
ns.Scan = Scan

local SLICE = 1000            -- replicate rows read per frame (2,000 measured 29-39 ms: a visible stutter)
local SETTLE_SECONDS = 2      -- the row count must be unchanged this long before the list is read
local MAX_RESETTLES = 15      -- ... and is given this many more tries if it keeps changing quietly
local SETTLE_BUDGET = 60      -- ... or this long after the first list event if it keeps announcing changes
local REPLICATE_TIMEOUT = 30  -- no list event by then: say so, and let the player do something else
local LATE_LIMIT = 300        -- a list that arrives within this long of the request is still read
local LINK_RETRY_SECONDS = 1  -- rows whose item link was not loaded are looked at once more after this
local SIGNATURE_MIN_ROWS = 50 -- lists this long are compared with the last one read (see lastSignature)
local BROWSE_TIMEOUT = 180
local BROWSE_MAX_PAGES = 400
local SELFTEST_REALM = "Tallybook Selftest"

local current -- the running scan, or nil. A new table per scan, so stale timers recognise themselves.
local late    -- a full scan whose list had not arrived after REPLICATE_TIMEOUT. It no longer blocks
              -- anything, and sends nothing; it only says "a list that arrives now is still mine".

-- When this session's newest scan of the market finished, as server time, or 0. Set in the two places a
-- scan document is saved and nowhere else: a synthetic /tally selftest is no scan of a market and must
-- never hold the next real one off. The strip reads it through Scan.status (C7's 30-minute limit).
local lastScanAt = 0

local ladderNext -- defined with the price ladders further down; the throttle handler above them calls it
-- Defined with the variant learning further down, but finishBrowse - above it - starts it. A Lua local
-- must be in scope where it is USED, not merely where it is assigned.
local learnFromBrowse

-- A whole number that can be an id. Secret values and floats are neither.
local function isCountLike(v)
    return not ns.isSecret(v) and type(v) == "number" and v >= 1 and v % 1 == 0
end

-- A whole number of either sign, not secret (itemKey.itemSuffix may legitimately be 0, unlike an id).
local function isIntLike(v)
    return not ns.isSecret(v) and type(v) == "number" and v % 1 == 0
end

function Scan.busy()
    return current ~= nil
end

-- What the auction house strip shows (Strip.lua). Read-only, and busy is only ever about a scan of the
-- market: the short learn and ladder runs are nothing the Stop button should offer to end.
-- -> { busy, kind, pages, lastScanAt }
function Scan.status()
    local run = current
    local scanning = run ~= nil and (run.kind == "replicate" or run.kind == "browse")
    return {
        busy = scanning,
        kind = scanning and run.kind or nil,
        pages = scanning and run.pages or nil,
        lastScanAt = lastScanAt,
    }
end

-- Whether the client would take a query this instant. Its own throttle is what refuses one: a scan the
-- player asked for waits for it (browseSend below), and the strip - which nobody clicked - does not, so
-- that no query of its making can ever leave on a later event (C7 limits 1 and 6).
function Scan.throttleReady()
    if type(C_AuctionHouse) ~= "table" or type(C_AuctionHouse.IsThrottledMessageSystemReady) ~= "function" then
        return false
    end
    local ok, ready = pcall(C_AuctionHouse.IsThrottledMessageSystemReady)
    return ok and ready == true
end

-- Called by Core after any error: never stay busy.
function Scan.reset()
    current = nil
    late = nil
end

local function seconds(run)
    return (ns.clockMs() - run.startedMs) / 1000
end

-- The checks every real scan shares. -> meta, or nil after saying why not.
local function ready(api, events)
    if current then
        ns.print("a " .. current.kind .. " scan is already running")
        return nil
    end
    if not ns.ahOpen then
        ns.print("open the auction house first")
        return nil
    end
    local ok, why = ns.Export.available()
    if not ok then
        ns.print(why)
        return nil
    end
    if type(C_AuctionHouse) ~= "table" then
        ns.print("this client has no C_AuctionHouse")
        return nil
    end
    for i = 1, #api do
        if type(C_AuctionHouse[api[i]]) ~= "function" then
            ns.print("this client has no C_AuctionHouse." .. api[i])
            return nil
        end
    end
    for i = 1, #events do
        -- without its events a scan could only sit there until it timed out
        if ns.unknownEvents[events[i]] then
            ns.print("this client does not know the " .. events[i] .. " event")
            return nil
        end
    end
    if type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then
        ns.print("this client has no C_Timer.After")
        return nil
    end
    local meta = ns.meta()
    local problem = Logic.metaProblem(meta)
    if problem then
        ns.print(problem .. "; try again in a moment")
        return nil
    end
    return meta
end

---------------------------------------------------------------------------------------------------
-- Item names, quality and suffix names (M2, spec 2026-09-23): a side effect of both scans below, never a
-- request of their own. A row/result with no variant carries its own base name already; one WITH a variant
-- (a different id space on each side - board card B6) needs the item template's own unsuffixed name
-- instead. Logic.noteItem / noteSuffix are no-ops for an id already known, so calling either every scan
-- costs nothing once a name is learned.
---------------------------------------------------------------------------------------------------

-- The item template's own name, no suffix: C_Item.GetItemInfo where it exists, else the classic global
-- GetItemInfo (Ruling B). Guarded both ways - a client with neither simply learns no base name for a
-- variant row; a name the client has not cached yet is left missing, never guessed (spec section 3).
local function templateName(itemID)
    local ok, name
    if type(C_Item) == "table" and type(C_Item.GetItemInfo) == "function" then
        ok, name = pcall(C_Item.GetItemInfo, itemID)
    elseif type(GetItemInfo) == "function" then
        ok, name = pcall(GetItemInfo, itemID)
    else
        return nil
    end
    if ok and not ns.isSecret(name) and type(name) == "string" and name ~= "" then return name end
    return nil
end

-- Wraps a one-argument lookup so it is asked at most once per distinct key: a table made fresh for one
-- scan run, never shared between runs or between the replicate and browse paths.
local function memoize(fn)
    local cache = {}
    return function(key)
        local hit = cache[key]
        if hit == nil then
            hit = fn(key) or false -- false marks "looked up, nothing there" so it is not asked again
            cache[key] = hit
        end
        if hit == false then return nil end
        return hit
    end
end

---------------------------------------------------------------------------------------------------
-- /tally scan : the full-market replicate scan
---------------------------------------------------------------------------------------------------

local REPLICATE_API = { "ReplicateItems", "GetNumReplicateItems", "GetReplicateItemInfo", "GetReplicateItemLink" }
local REPLICATE_EVENTS = { "REPLICATE_ITEM_LIST_UPDATE" }

-- The client keeps the last list it was given. A request the server throttles brings no new list,
-- and a list event that fires anyway (item data loading, another addon) would have the old rows read
-- again as a new scan, under the current time. So the length of a list and three of its rows are
-- remembered for the session, and the very same list is not saved twice. Tiny lists are exempt: a
-- quiet market really can be unchanged after 15 minutes.
local lastSignature

local function replicateCount()
    local n = C_AuctionHouse.GetNumReplicateItems()
    if ns.isSecret(n) or type(n) ~= "number" then return 0 end
    return n
end

-- noLink: rows left out because their item link never loaded (see processReplicate).
local function finishReplicate(run, agg, n, unreadable, noLink)
    current = nil
    if agg.rowCount == 0 then
        ns.print("full scan: no rows could be read. Nothing was saved.")
        return
    end
    local rows = agg:rows()
    if #rows == 0 then
        ns.print(string.format("full scan: %.0f auctions, none with a buyout. Nothing was saved.", agg.rowCount))
        return
    end
    if run.signature ~= nil and run.signature == lastSignature then
        ns.print("full scan: the client handed back the very same list as the last full scan, so the new"
            .. " request was not answered (throttled?). Nothing was saved.")
        return
    end
    if run.signature ~= nil then lastSignature = run.signature end
    -- An item missing from a complete scan reads as "sold out" on the server, so a scan that had to
    -- drop a row (no item id, no link, a secret value, a count or buyout the server would refuse),
    -- or whose list was not the same length after the read as before it, must not claim to be
    -- complete. Bid-only rows are not dropped rows: they have no buyout to record.
    -- run.readOk and run.finalCount were taken when the last row was read, one frame ago: closing
    -- the auction house after that does not make a whole scan incomplete.
    local dropped = unreadable + noLink + agg.invalid
    local complete = run.readOk == true and (not run.unstable)
        and dropped == 0 and agg.rowCount == n and run.finalCount == n
    ns.print(string.format("full scan: %.0f auctions -> %.0f rows, %.0f item keys, %.0f bid-only, %.0f without a link, %.1f s",
        agg.rowCount, #rows, agg:keyCount(), agg.bidOnly, noLink, seconds(run)))
    if not complete then
        local why = "the list kept changing"
        if not run.readOk then
            -- Cut short mid-read: by whatever ended it (interrupt records that), or by the house being
            -- shut without one - which only leaves ns.ahOpen false, and is the case the fallback names.
            why = run.stoppedWhy or "the auction house was closed"
        elseif dropped > 0 then
            why = string.format("%.0f of %.0f rows could not be read", dropped, n)
        end
        ns.print("INCOMPLETE (" .. why .. "): saved for the record, but the server will not use its prices")
    end
    local t1 = ns.serverTime()
    local doc = Logic.buildDoc(run.meta, "replicate", complete, run.t0, t1, rows, {
        uid = run.uid,
        rowCount = agg.rowCount,
        bidOnly = agg.bidOnly,
        noLink = noLink,
        variant = "bonus",
        suffixSeen = agg.suffixSeen,
    })
    ns.Export.save(doc)
    lastScanAt = t1 -- the market was read, complete or not: the strip counts it as this session's newest
end

local function processReplicate(run, n)
    run.processing = true
    local agg = Logic.newAggregator()
    local db = ns.db()
    local getInfo = C_AuctionHouse.GetReplicateItemInfo
    local getLink = C_AuctionHouse.GetReplicateItemLink
    local secret = type(issecretvalue) == "function" and issecretvalue or nil
    local parseVariant = Logic.parseVariant
    local parseSuffix = Logic.parseSuffix
    local baseName = memoize(templateName) -- M2: one GetItemInfo per distinct itemID, this run only
    local i = 0          -- the replicate list is 0-indexed: rows 0 .. n-1
    local unreadable = 0 -- rows with no item id, or holding a secret value
    -- The suffix id comes from the item link, and a link can be missing while the client is still
    -- loading the item. Such a row is NOT filed under suffix 0 (that would record its price under
    -- an item key that does not exist and leave the real one looking sold out): it waits here for
    -- one more look, and if it still has no link it is left out and the scan is incomplete.
    local waiting = {}   -- { index, itemID, count, buyout, name, qualityID, hasAllInfo }
    local looked = 0     -- how many of `waiting` have had their second look
    local noLink = 0
    local marks = { [0] = true, [math.floor(n / 2)] = true, [n - 1] = true } -- rows that go into the signature
    local signature = { string.format("%.0f", n) }

    local function link(index)
        local value = getLink(index)
        if value ~= nil and secret and secret(value) then return nil end
        return value
    end

    -- M2 (Ruling B): called only once a row's variant is known, from both loops below. No variant -> the
    -- row's own name IS the base name, when hasAllInfo said the row was whole. A variant -> the row's name
    -- is the FULL suffixed name (Ruling A: never sent to noteSuffix - a full scan never calls it at all,
    -- since field 7 is empty on this client, board card B6) - so the base name is asked for separately.
    local function noteRow(itemID, variant, name, qualityID, hasAllInfo)
        if secret and secret(qualityID) then return end
        if variant == 0 then
            if not (secret and secret(hasAllInfo)) and hasAllInfo == true and not (secret and secret(name)) then
                Logic.noteItem(db, itemID, name, qualityID)
            end
        else
            local base = baseName(itemID)
            if base then Logic.noteItem(db, itemID, base, qualityID) end
        end
    end

    local function step()
        if current ~= run then return end
        if run.interrupted or not ns.ahOpen then
            -- Closed in the middle of the read: what was read is saved for the record, incomplete.
            run.readOk = false
            finishReplicate(run, agg, n, unreadable, noLink + (#waiting - looked))
            return
        end
        local budget = SLICE
        if i < n then
            while i < n and budget > 0 do
                -- Positions 12-15 are player names: they are discarded right here and never held.
                local name, _, count, qualityID, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID, hasAllInfo = getInfo(i)
                if secret and (secret(itemID) or secret(count) or secret(buyout)) then
                    unreadable = unreadable + 1
                elseif not itemID or itemID == 0 then
                    unreadable = unreadable + 1
                else
                    if marks[i] then
                        signature[#signature + 1] = tostring(itemID) .. ":" .. tostring(count) .. ":" .. tostring(buyout)
                    end
                    local itemLink = link(i)
                    if itemLink ~= nil then
                        if parseSuffix(itemLink) ~= 0 then agg.suffixSeen = agg.suffixSeen + 1 end
                        local variant = parseVariant(itemLink)
                        agg:add(itemID, variant, count, buyout, true)
                        noteRow(itemID, variant, name, qualityID, hasAllInfo)
                    else
                        waiting[#waiting + 1] = { i, itemID, count, buyout, name, qualityID, hasAllInfo }
                    end
                end
                i = i + 1
                budget = budget - 1
            end
            if i < n then
                ns.after(0, step) -- the next slice on the next frame, so the client does not freeze
                return
            end
            if #waiting > 0 then
                ns.after(LINK_RETRY_SECONDS, step) -- give the client a moment to load those items
                return
            end
        end
        while looked < #waiting and budget > 0 do
            looked = looked + 1
            local row = waiting[looked]
            local itemLink = link(row[1])
            if itemLink ~= nil then
                if parseSuffix(itemLink) ~= 0 then agg.suffixSeen = agg.suffixSeen + 1 end
                local variant = parseVariant(itemLink)
                agg:add(row[2], variant, row[3], row[4], true)
                noteRow(row[2], variant, row[5], row[6], row[7])
            else
                noLink = noLink + 1
            end
            budget = budget - 1
        end
        if looked < #waiting then
            ns.after(0, step)
            return
        end
        -- Every row has been read. What decides completeness is taken now; the sort, the JSON and
        -- the base64 get a frame of their own.
        run.readOk = true
        run.finalCount = replicateCount()
        if n >= SIGNATURE_MIN_ROWS then run.signature = table.concat(signature, "|") end
        ns.after(0, function()
            if current ~= run then return end
            finishReplicate(run, agg, n, unreadable, noLink)
        end)
    end
    step()
end

-- Reads the list as it is now.
local function readList(run)
    run.token = (run.token or 0) + 1 -- a settle timer that is still pending recognises itself as stale
    local n = replicateCount()
    if n < 1 then
        current = nil
        ns.print("full scan: the list came back empty. Nothing was saved.")
        return
    end
    ns.print(string.format("full scan: %.0f auctions, reading ...", n))
    processReplicate(run, n)
end

-- Waits until the row count has been the same for SETTLE_SECONDS.
local function settle(run)
    run.count = replicateCount()
    run.token = (run.token or 0) + 1
    local token = run.token
    ns.after(SETTLE_SECONDS, function()
        if current ~= run or run.token ~= token or run.processing then return end
        if replicateCount() ~= run.count then
            run.resettles = (run.resettles or 0) + 1
            if run.resettles <= MAX_RESETTLES then
                settle(run)
                return
            end
            run.unstable = true
        end
        readList(run)
    end)
end

function Scan.replicate()
    local meta = ready(REPLICATE_API, REPLICATE_EVENTS)
    if not meta then return end
    local state = ns.db().state
    local now = ns.serverTime()
    local allowed, remaining = Logic.canReplicate(now, state.lastReplicateAt, Logic.REPLICATE_COOLDOWN)
    if not allowed then
        ns.print("the full scan is on cooldown for another " .. Logic.formatAge(remaining)
            .. " (Tallybook asks for one at most every 15 minutes). /tally browse works any time.")
        return
    end

    local run = { kind = "replicate", meta = meta, t0 = now, startedMs = ns.clockMs(), events = 0,
        uid = Logic.newUid(now, Logic.rand31()) }
    current = run
    late = nil
    state.lastReplicateAt = now -- before the request: a request that fails still spent the attempt
    local ok, err = pcall(C_AuctionHouse.ReplicateItems)
    if not ok then
        current = nil
        ns.print("the full scan request failed: " .. tostring(err))
        return
    end
    ns.print("full scan requested ...")
    ns.after(REPLICATE_TIMEOUT, function()
        if current ~= run or run.events > 0 then return end
        -- Not given up on: only moved out of the way. This sends nothing; if the list this request
        -- asked for still arrives, the list handler below reads it.
        current = nil
        late = run
        ns.print("no answer after 30 s: the request was throttled by the server's own cooldown, or the server"
            .. " is slow. Nothing is saved yet - if the list still arrives while the auction house stays"
            .. " open, it will be read. /tally browse works meanwhile.")
    end)
end

ns.on("REPLICATE_ITEM_LIST_UPDATE", function()
    if current == nil and late ~= nil then
        local waited = late
        late = nil
        if ns.ahOpen and (ns.clockMs() - waited.startedMs) / 1000 <= LATE_LIMIT then
            current = waited
            ns.print("full scan: the list has arrived after all ...")
        end
    end
    local run = current
    -- While the rows are being read the event is not acted on: the client also fires it as item
    -- data loads. Whether the list really changed is settled by counting it again after the read.
    if not run or run.kind ~= "replicate" or run.processing then return end
    run.events = run.events + 1
    if run.events == 1 then
        run.firstEventMs = ns.clockMs()
        settle(run)
        return
    end
    -- An event that leaves the row count alone does not restart the wait ...
    if replicateCount() == run.count then return end
    -- ... one that changes it does, but not for ever: a list that is still announcing changes a
    -- minute after it first arrived is read as it is, and is not complete.
    if (ns.clockMs() - run.firstEventMs) / 1000 >= SETTLE_BUDGET then
        run.unstable = true
        readList(run)
        return
    end
    settle(run)
end)

---------------------------------------------------------------------------------------------------
-- /tally browse : the whole market through browse queries
---------------------------------------------------------------------------------------------------

local BROWSE_API = { "SendBrowseQuery", "RequestMoreBrowseResults", "HasFullBrowseResults", "GetBrowseResults",
    "IsThrottledMessageSystemReady" }
local BROWSE_EVENTS = { "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
    "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" }

-- Rows holding a secret value are dropped before anything looks inside them.
local function withoutSecrets(results)
    if type(issecretvalue) ~= "function" then return results end
    local out = {}
    for i = 1, #results do
        local result = results[i]
        local key = (not ns.isSecret(result)) and type(result) == "table" and result.itemKey
        if type(key) == "table" and not ns.isSecret(key)
            and not (ns.isSecret(key.itemID) or ns.isSecret(key.itemLevel) or ns.isSecret(key.itemSuffix)
                or ns.isSecret(result.minPrice) or ns.isSecret(result.totalQuantity)) then
            out[#out + 1] = result
        end
    end
    return out
end

-- The client has ONE browse result list. The game's own auction house window, and any other
-- addon, search into the same list, and the result events carry nothing that says whose query
-- they answer. So while a browse scan runs, Tallybook watches for anybody else's search:
--   * a post-hook on the three functions that start one (it changes nothing about them). The
--     flag below is up exactly while Tallybook's own query is being sent;
--   * and, because a hook may not exist and cannot see everything, a check on the list itself
--     (see onBrowseResults).
-- Results that are not provably this scan's own are not exported at all, not even as incomplete:
-- they are no scan of the market, and the tooltip prices must not be replaced by them.
local sendingOwn = false

local function abandonBrowse(run, why)
    if current == run then current = nil end
    ns.print("browse scan: " .. why .. ", so the results are no longer this scan's. Nothing was saved and the"
        .. " tooltip prices were left alone. Run /tally browse again, and leave the search alone until it is done.")
end

local function onForeignSearch()
    local run = current
    if sendingOwn or not run or run.kind ~= "browse" then return end
    abandonBrowse(run, "another search was sent while it was running")
end

if type(hooksecurefunc) == "function" and type(C_AuctionHouse) == "table" then
    local searches = { "SendBrowseQuery", "SearchForFavorites", "SearchForItemKeys" }
    for index = 1, #searches do
        if type(C_AuctionHouse[searches[index]]) == "function" then
            pcall(hooksecurefunc, C_AuctionHouse, searches[index], function()
                local ok, err = pcall(onForeignSearch)
                if not ok then ns.fail("search hook", err) end
            end)
        end
    end
end

-- "itemID:itemLevel:itemSuffix" of one result row, or nil. Only the item key is looked at.
local function keyOf(result)
    if ns.isSecret(result) or type(result) ~= "table" then return nil end
    local key = result.itemKey
    if ns.isSecret(key) or type(key) ~= "table" then return nil end
    if ns.isSecret(key.itemID) or ns.isSecret(key.itemLevel) or ns.isSecret(key.itemSuffix) then return nil end
    return tostring(key.itemID) .. ":" .. tostring(key.itemLevel) .. ":" .. tostring(key.itemSuffix)
end

local function browseResults()
    local results = C_AuctionHouse.GetBrowseResults()
    if ns.isSecret(results) or type(results) ~= "table" then return {} end
    return results
end

-- True when a browse result's key has nothing left for GetItemKeyInfo to teach: itemSuffix 0 needs only
-- the base item's own name (db.items); a non-zero itemSuffix needs that AND its own full suffixed name
-- (db.suffixes, keyed exactly as Logic.noteSuffix keys it - read here, not assumed). A whole-market browse
-- returns the same keys session after session, so this turns most of a repeat scan's names into no call
-- at all rather than a pcall that would only confirm what is already known.
local function namesKnown(db, key)
    if type(db.items) ~= "table" or db.items[key.itemID] == nil then return false end
    if key.itemSuffix == 0 then return true end
    return type(db.suffixes) == "table" and db.suffixes[key.itemID .. ":" .. key.itemSuffix] ~= nil
end

-- M2 (Ruling A/B): for each result's itemKey, GetItemKeyInfo answers itemName and quality once the client
-- has cached the key - or nil until ITEM_KEY_ITEM_INFO_RECEIVED, in which case this result is skipped and
-- a later scan sees it (no new event handler for this). itemSuffix 0 IS the base item: straight to
-- noteItem. A non-zero itemSuffix is the FULL suffixed name, to noteSuffix; its base name is a separate,
-- memoized lookup (the item template), because a suffixed key's own itemName is never the unsuffixed one.
local function noteBrowseNames(results)
    local getKeyInfo = C_AuctionHouse.GetItemKeyInfo
    if type(getKeyInfo) ~= "function" then return end
    local db = ns.db()
    local baseName = memoize(templateName)
    for i = 1, #results do
        local key = results[i].itemKey
        if type(key) == "table" and isCountLike(key.itemID) and isIntLike(key.itemSuffix)
            and not namesKnown(db, key) then
            local ok, info = pcall(getKeyInfo, key)
            if ok and not ns.isSecret(info) and type(info) == "table"
                and not (ns.isSecret(info.itemName) or ns.isSecret(info.quality)) then
                if key.itemSuffix ~= 0 then
                    if type(info.itemName) == "string" then
                        Logic.noteSuffix(db, key.itemID, key.itemSuffix, info.itemName)
                    end
                    local base = baseName(key.itemID)
                    if base then Logic.noteItem(db, key.itemID, base, info.quality) end
                elseif type(info.itemName) == "string" then
                    Logic.noteItem(db, key.itemID, info.itemName, info.quality)
                end
            end
        end
    end
end

local function finishBrowse(run, complete, why)
    current = nil
    if not run.answered then
        -- The list still holds whatever was searched for last; none of it answers this scan's query.
        ns.print("browse scan: no answer to this scan's query" .. (why and (" (" .. why .. ")") or "")
            .. ". Nothing was saved.")
        return
    end
    local results = browseResults()
    local safe = withoutSecrets(results)
    local rows = Logic.browseRows(safe)
    if #rows == 0 then
        ns.print("browse scan: no rows" .. (why and (" (" .. why .. ")") or "") .. ". Nothing was saved.")
        return
    end
    if complete and #rows ~= #results then
        -- An item missing from a complete scan reads as "sold out" on the server, so a scan that
        -- had to drop rows must not claim to be complete.
        complete = false
        why = string.format("%.0f of %.0f rows could not be read", #results - #rows, #results)
    end
    local t1 = ns.serverTime()
    ns.print(string.format("browse scan: %.0f item keys in %.0f %s, %.1f s", #rows, run.pages,
        run.pages == 1 and "page" or "pages", seconds(run)))
    if complete then
        local db = ns.db()
        db.prices = Logic.priceTable(rows)
        db.listed = Logic.listedTable(rows)
        db.pricesAt = t1
        db.pricesFrom = nil -- the player's own scan now: no "saved" / "shared" label
        ns.changed() -- the costs in an open profession window follow the new prices
    else
        ns.print("INCOMPLETE (" .. tostring(why) .. "): saved for the record, but the server will not use its prices")
    end
    local doc = Logic.buildDoc(run.meta, "browse", complete, run.t0, t1, rows, { uid = run.uid, rowCount = #results })
    ns.Export.save(doc)
    lastScanAt = t1 -- the market was read, complete or not: the strip counts it as this session's newest
    -- M2: item names, quality and the full names of any suffixed keys, learned from this scan's own
    -- results only (Ruling A/B) - after the scan is safely saved, like the variant learning right below.
    noteBrowseNames(safe)
    -- Only after the scan is safely saved, only for keys this scan itself returned (B6) - and only after a
    -- scan the player asked for. The one scan that starts itself (C7) learns nothing: its whole footprint
    -- is that one browse query and its pages, and eight item searches behind it would be a re-query loop
    -- in shape however well bounded. The pairs are learned the next time somebody presses Browse.
    if not run.auto then learnFromBrowse(results) end
end

---------------------------------------------------------------------------------------------------
-- Learning variant pairs (board card B6)
---------------------------------------------------------------------------------------------------
-- A full scan reads an auction's variant from the item link, where this client keeps it as a BONUS id.
-- A browse scan reads it from the item key, where it is an itemSuffix. They are different id spaces and
-- nothing can compute one from the other, so the two numbers have to be seen together - which happens in
-- exactly one place: an item search result, which carries both the key and the auction's link.
--
-- So the server names the suffixes it still has no pair for (ns.baked.wantVariants) and this looks a few
-- of them up, but ONLY right after a browse scan the player asked for, only for keys that scan already
-- returned, and never more than LEARN_MAX of them. The pairs go home in the reference document.

local LEARN_MAX = 8
local LEARN_TIMEOUT = 8

local function learnNext(run)
    if current ~= run or run.waiting then return end
    if run.index >= #run.keys then
        current = nil
        if run.learned > 0 then
            ns.print(string.format("learned %.0f item %s for the group", run.learned,
                run.learned == 1 and "variant" or "variants"))
        end
        return
    end
    if not C_AuctionHouse.IsThrottledMessageSystemReady() then return end -- the ready event brings us back
    run.index = run.index + 1
    local key, index = run.keys[run.index], run.index
    local sorts = {}
    local order = type(Enum) == "table" and type(Enum.AuctionHouseSortOrder) == "table" and Enum.AuctionHouseSortOrder
    if order and order.Price ~= nil then sorts[1] = { sortOrder = order.Price, reverseSort = false } end
    if not pcall(C_AuctionHouse.SendSearchQuery, key, sorts, false) then return learnNext(run) end
    run.waiting = key
    -- A key with no live auction answers with nothing at all; every step carries its own deadline so one
    -- silent answer cannot strand the rest (the same trap the probe's first sweep fell into).
    ns.after(LEARN_TIMEOUT, function()
        if current ~= run or run.index ~= index or run.waiting ~= key then return end
        run.waiting = nil
        learnNext(run)
    end)
end

-- -> true when this search was ours, so the ladder never sees it.
local function learnAnswer(itemKey)
    local run = current
    if not run or run.kind ~= "learn" then return false end
    local waiting = run.waiting
    if type(waiting) ~= "table" or waiting.itemID ~= itemKey.itemID
        or waiting.itemSuffix ~= itemKey.itemSuffix then return false end
    run.waiting = nil
    local suffix = itemKey.itemSuffix
    local n = C_AuctionHouse.GetNumItemSearchResults(itemKey)
    if not ns.isSecret(n) and type(n) == "number" and n >= 1 and isCountLike(suffix) then
        local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, 1)
        if type(r) == "table" and not ns.isSecret(r.itemLink) then
            local bonus = Logic.parseVariant(r.itemLink)
            if bonus ~= 0 then
                local db = ns.db()
                if type(db.variants) ~= "table" then db.variants = {} end
                if db.variants[bonus] == nil then run.learned = run.learned + 1 end
                db.variants[bonus] = suffix
            end
        end
    end
    learnNext(run)
    return true
end

-- Started only by finishBrowse, with the results of the scan the player just ran - never after the scan
-- that starts itself on AUCTION_HOUSE_SHOW, which finishBrowse keeps out by run.auto.
function learnFromBrowse(results)
    if current then return end -- never in the way of a scan
    local baked = ns.baked
    local want = type(baked) == "table" and baked.wantVariants or nil
    if type(want) ~= "table" or #want == 0 then return end
    local wanted = {}
    for i = 1, #want do
        if isCountLike(want[i]) then wanted[want[i]] = true end
    end
    local keys, seen = {}, {}
    for i = 1, #results do
        local k = type(results[i]) == "table" and results[i].itemKey
        if type(k) == "table" and isCountLike(k.itemSuffix) and wanted[k.itemSuffix] and not seen[k.itemSuffix] then
            seen[k.itemSuffix] = true
            keys[#keys + 1] = k
            if #keys >= LEARN_MAX then break end
        end
    end
    if #keys == 0 then return end
    current = { kind = "learn", keys = keys, index = 0, learned = 0 }
    learnNext(current)
end

-- The first page: one query, sent once, and only when the client's throttle is ready.
local function browseSend(run)
    if run.sent or not C_AuctionHouse.IsThrottledMessageSystemReady() then return end
    run.sent = true
    run.pages = 1
    local sorts = {}
    local order = type(Enum) == "table" and type(Enum.AuctionHouseSortOrder) == "table" and Enum.AuctionHouseSortOrder.Price
    if order ~= nil and order ~= false then sorts[1] = { sortOrder = order, reverseSort = false } end
    sendingOwn = true
    local ok, err = pcall(C_AuctionHouse.SendBrowseQuery,
        { searchString = "", sorts = sorts, filters = {}, itemClassFilters = {} })
    sendingOwn = false
    if not ok then
        current = nil
        ns.print("the browse query failed: " .. tostring(err))
        return
    end
    ns.db().state.lastBrowseAt = ns.serverTime() -- only now has a browse scan really been asked for
end

-- The next page: asked for at most once per page of results, and only when the throttle is ready.
local function browseMore(run)
    if not run.wantMore or not C_AuctionHouse.IsThrottledMessageSystemReady() then return end
    run.wantMore = false
    run.pages = run.pages + 1
    C_AuctionHouse.RequestMoreBrowseResults()
end

local function onBrowseResults()
    local run = current
    if not run or run.kind ~= "browse" or not run.sent then return end
    run.answered = true
    -- One paged query only ever grows its list, and what it has listed stays where it is. A list
    -- that got shorter, or whose first row or last-known row is now another item, was replaced by
    -- somebody else's search. (Comparing lengths alone would miss a replacement of the same size.)
    local results = browseResults()
    local n = #results
    if n < run.listed or (run.listed > 0
        and (keyOf(results[1]) ~= run.firstKey or keyOf(results[run.listed]) ~= run.lastKey)) then
        abandonBrowse(run, "another search replaced the results")
        return
    end
    run.listed = n
    run.firstKey = keyOf(results[1])
    run.lastKey = keyOf(results[n])
    if C_AuctionHouse.HasFullBrowseResults() then
        finishBrowse(run, true)
        return
    end
    if run.pages >= BROWSE_MAX_PAGES then
        finishBrowse(run, false, "stopped at " .. BROWSE_MAX_PAGES .. " pages")
        return
    end
    run.wantMore = true
    browseMore(run)
end

-- opts.auto marks the one scan that starts itself when the house opens (Strip.lua): the same scan in every
-- other respect, but it does not go on to learn variant pairs - see finishBrowse. /tally browse and the
-- Browse button pass nothing and behave exactly as they always have.
-- -> true only when the query really went out. false when nothing was started (the reason was printed),
-- and false too when the scan is running but the client's throttle has not taken the query yet - which a
-- /tally browse or the Browse button is content to wait for, and the strip is not (C7 limit 6).
function Scan.browse(opts)
    local meta = ready(BROWSE_API, BROWSE_EVENTS)
    if not meta then return false end
    local now = ns.serverTime()
    local run = { kind = "browse", meta = meta, t0 = now, startedMs = ns.clockMs(), pages = 0,
        sent = false, answered = false, wantMore = false, listed = 0,
        auto = type(opts) == "table" and opts.auto == true,
        uid = Logic.newUid(now, Logic.rand31()) }
    current = run
    ns.after(BROWSE_TIMEOUT, function()
        if current ~= run then return end
        finishBrowse(run, false, "gave up after " .. BROWSE_TIMEOUT .. " s")
    end)
    browseSend(run)
    if current ~= run then return false end
    ns.print(run.sent and "browsing the whole market ... please leave the auction house search alone until it is done"
        or "waiting for the auction house to accept a query ...")
    return run.sent == true
end

ns.on("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", onBrowseResults)
ns.on("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", onBrowseResults)

ns.on("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function()
    local run = current
    if run and run.kind == "learn" then return learnNext(run) end
    if run and run.kind == "ladder" then return ladderNext(run) end
    if not run or run.kind ~= "browse" then return end
    if not run.sent then
        browseSend(run)
    else
        browseMore(run)
    end
end)

ns.on("AUCTION_HOUSE_BROWSE_FAILURE", function()
    local run = current
    if not run or run.kind ~= "browse" then return end
    finishBrowse(run, false, "the server reported a browse failure")
end)

-- Ends whatever is running, saying why. There is one such path and this is it: the auction house closing
-- and the strip's Stop button are the same ending, so nothing can be abandoned in a way the other two
-- kinds of ending were not written for. A browse scan keeps what it read (incomplete); a full scan in the
-- middle of its read is told to stop at the next slice, which saves what it has, incomplete.
local function interrupt(why)
    local run = current
    if not run then return false end
    if run.kind == "ladder" then
        current = nil
        ns.print("basket abandoned: " .. why)
    elseif run.kind == "learn" then
        -- Nothing a learn run holds is worth saving, and it must not outlive the house it is searching
        -- in: its next lookup would leave on a throttle event nobody asked for. It goes quietly - the
        -- player never asked for it and was never told it had started.
        current = nil
    elseif run.kind == "browse" then
        finishBrowse(run, false, why)
    elseif run.kind == "replicate" then
        run.interrupted = true
        run.stoppedWhy = why -- a read already under way ends INCOMPLETE, and says this as the reason
        if not run.processing then
            current = nil
            ns.print("full scan: " .. why .. " before the list arrived. Nothing was saved.")
        end
    end
    return true
end

-- The Stop button on the auction house strip (C7's "visible while it runs, with a Stop button").
function Scan.stop()
    return interrupt("you stopped it")
end

-- Core's own handler for this event runs first, so ns.ahOpen is already false here.
ns.on("AUCTION_HOUSE_CLOSED", function()
    late = nil -- whatever list arrives after this is not read
    interrupt("the auction house was closed")
end)

---------------------------------------------------------------------------------------------------
-- Price ladders for a basket (board card F13): one search per item, for a handful of mats
---------------------------------------------------------------------------------------------------

-- Asked for by the player (/tally basket, or a right-click in the Profit panel) and never otherwise. One
-- query at a time, each only when the throttle is ready, exactly like the pages of a browse scan; nothing is
-- repeated or kept running. Only unit prices and quantities are read from a result - never who is selling.
local LADDER_API = { "MakeItemKey", "SendSearchQuery", "IsThrottledMessageSystemReady",
    "GetNumCommoditySearchResults", "GetCommoditySearchResultInfo" }
local LADDER_TIMEOUT = 10   -- no answer for one item by then: it counts as not listed, and the next is asked
local LADDER_MAX_TIERS = 300
local LADDER_MAX_ITEMS = 12

function ladderNext(run)
    if current ~= run or run.waiting then return end
    if run.index >= #run.items then
        current = nil
        run.done(run.ladders)
        return
    end
    if not C_AuctionHouse.IsThrottledMessageSystemReady() then return end -- the ready event brings us back
    run.index = run.index + 1
    local itemID, index = run.items[run.index], run.index
    local sorts = {}
    local order = type(Enum) == "table" and type(Enum.AuctionHouseSortOrder) == "table" and Enum.AuctionHouseSortOrder
    if order and order.Price ~= nil then sorts[1] = { sortOrder = order.Price, reverseSort = false } end
    local okKey, key = pcall(C_AuctionHouse.MakeItemKey, itemID)
    local ok = okKey and pcall(C_AuctionHouse.SendSearchQuery, key, sorts, false)
    if not ok then return ladderNext(run) end -- this one stays unknown; the basket says so
    run.waiting = itemID
    ns.after(LADDER_TIMEOUT, function()
        if current ~= run or run.index ~= index or run.waiting ~= itemID then return end
        run.waiting = nil
        ladderNext(run)
    end)
end

-- read(i) -> unit price, quantity of result i
local function ladderAnswer(itemID, n, read)
    local run = current
    if not run or run.kind ~= "ladder" or run.waiting ~= itemID then return end -- somebody else's search
    local tiers = {}
    if not ns.isSecret(n) and type(n) == "number" then
        for i = 1, math.min(n, LADDER_MAX_TIERS) do
            local price, quantity = read(i)
            if not ns.isSecret(price) and not ns.isSecret(quantity) and type(price) == "number" and type(quantity) == "number" then
                tiers[#tiers + 1] = { price, quantity }
            end
        end
    end
    run.ladders[itemID] = tiers
    run.waiting = nil
    ladderNext(run)
end

-- itemIDs -> done({ [itemID] = { {unitPrice, quantity}, ... } }); an item that never answered has no entry.
-- -> false after saying why, when nothing was started.
function Scan.ladders(itemIDs, done)
    if current then
        ns.print("a " .. current.kind .. " scan is already running")
        return false
    end
    if not ns.ahOpen then
        ns.print("open the auction house first")
        return false
    end
    if type(C_AuctionHouse) ~= "table" or type(C_Timer) ~= "table" then
        ns.print("this client has no C_AuctionHouse")
        return false
    end
    for i = 1, #LADDER_API do
        if type(C_AuctionHouse[LADDER_API[i]]) ~= "function" then
            ns.print("this client has no C_AuctionHouse." .. LADDER_API[i])
            return false
        end
    end
    if type(itemIDs) ~= "table" or #itemIDs > LADDER_MAX_ITEMS then
        ns.print("that recipe has too many auction house mats to price in one go")
        return false
    end
    local run = { kind = "ladder", items = itemIDs, index = 0, ladders = {}, done = done }
    current = run
    ladderNext(run)
    return true
end

ns.on("COMMODITY_SEARCH_RESULTS_UPDATED", function(itemID)
    ladderAnswer(itemID, C_AuctionHouse.GetNumCommoditySearchResults(itemID), function(i)
        local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
        if type(r) ~= "table" then return nil end
        return r.unitPrice, r.quantity
    end)
end)

-- A mat that is sold as single listings rather than pooled.
ns.on("ITEM_SEARCH_RESULTS_UPDATED", function(itemKey)
    if type(itemKey) ~= "table" or type(C_AuctionHouse.GetNumItemSearchResults) ~= "function"
        or type(C_AuctionHouse.GetItemSearchResultInfo) ~= "function" then return end
    if learnAnswer(itemKey) then return end
    ladderAnswer(itemKey.itemID, C_AuctionHouse.GetNumItemSearchResults(itemKey), function(i)
        local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
        if type(r) ~= "table" then return nil end
        return r.buyoutAmount, r.quantity
    end)
end)

---------------------------------------------------------------------------------------------------
-- /tally selftest : one small synthetic scan through the real aggregator and the real export
---------------------------------------------------------------------------------------------------

-- Works with the auction house closed and asks the server for nothing. The document is labelled
-- with its own realm name so that its made-up prices can never land in a real market's history.
function Scan.selftest()
    if current then
        ns.print("a " .. current.kind .. " scan is already running")
        return
    end
    local ok, why = ns.Export.available()
    if not ok then
        ns.print(why)
        return
    end
    local meta = ns.meta()
    meta.realm = SELFTEST_REALM
    local problem = Logic.metaProblem(meta)
    if problem then
        ns.print(problem .. "; try again in a moment")
        return
    end

    local agg = Logic.newAggregator()
    for _ = 1, 3 do agg:add(2589, 0, 20, 4000, true) end
    agg:add(2589, 0, 1, 250, true)
    for _ = 1, 2 do agg:add(2770, 0, 10, 1500, true) end
    agg:add(6292, 1234, 1, 1000, true)
    agg:add(774, 0, 1, 0, true) -- bid-only

    ns.print("selftest: one synthetic scan, filed under the realm label \"" .. SELFTEST_REALM .. "\"")
    local now = ns.serverTime()
    local doc = Logic.buildDoc(meta, "replicate", true, now, now, agg:rows(), {
        uid = Logic.newUid(now, Logic.rand31()),
        rowCount = agg.rowCount,
        bidOnly = agg.bidOnly,
        noLink = agg.noLink,
        variant = "bonus",
        suffixSeen = agg.suffixSeen,
    })
    ns.Export.save(doc)
end

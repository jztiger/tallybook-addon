-- Tallybook: the auction house scans. Read-only: this file asks the auction house for listings and
-- reads them; it never changes anything there.
--
-- Rules this file keeps (docs/decisions.md C5-C7, C11):
--   * A scan starts only from Scan.replicate / Scan.browse / Scan.selftest, which only the typed
--     /tally commands call. Event handlers and timers below do nothing unless such a scan is
--     running, and then they only carry that one scan forward. Nothing re-arms itself.
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

function Scan.busy()
    return current ~= nil
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
            why = "the auction house was closed"
        elseif dropped > 0 then
            why = string.format("%.0f of %.0f rows could not be read", dropped, n)
        end
        ns.print("INCOMPLETE (" .. why .. "): saved for the record, but the server will not use its prices")
    end
    local doc = Logic.buildDoc(run.meta, "replicate", complete, run.t0, ns.serverTime(), rows, {
        uid = run.uid,
        rowCount = agg.rowCount,
        bidOnly = agg.bidOnly,
        noLink = noLink,
    })
    ns.Export.save(doc)
end

local function processReplicate(run, n)
    run.processing = true
    local agg = Logic.newAggregator()
    local getInfo = C_AuctionHouse.GetReplicateItemInfo
    local getLink = C_AuctionHouse.GetReplicateItemLink
    local secret = type(issecretvalue) == "function" and issecretvalue or nil
    local parseSuffix = Logic.parseSuffix
    local i = 0          -- the replicate list is 0-indexed: rows 0 .. n-1
    local unreadable = 0 -- rows with no item id, or holding a secret value
    -- The suffix id comes from the item link, and a link can be missing while the client is still
    -- loading the item. Such a row is NOT filed under suffix 0 (that would record its price under
    -- an item key that does not exist and leave the real one looking sold out): it waits here for
    -- one more look, and if it still has no link it is left out and the scan is incomplete.
    local waiting = {}   -- { index, itemID, count, buyout }
    local looked = 0     -- how many of `waiting` have had their second look
    local noLink = 0
    local marks = { [0] = true, [math.floor(n / 2)] = true, [n - 1] = true } -- rows that go into the signature
    local signature = { string.format("%.0f", n) }

    local function link(index)
        local value = getLink(index)
        if value ~= nil and secret and secret(value) then return nil end
        return value
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
                local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = getInfo(i)
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
                        agg:add(itemID, parseSuffix(itemLink), count, buyout, true)
                    else
                        waiting[#waiting + 1] = { i, itemID, count, buyout }
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
                agg:add(row[2], parseSuffix(itemLink), row[3], row[4], true)
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

local function finishBrowse(run, complete, why)
    current = nil
    if not run.answered then
        -- The list still holds whatever was searched for last; none of it answers this scan's query.
        ns.print("browse scan: no answer to this scan's query" .. (why and (" (" .. why .. ")") or "")
            .. ". Nothing was saved.")
        return
    end
    local results = browseResults()
    local rows = Logic.browseRows(withoutSecrets(results))
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
        db.pricesAt = t1
        ns.changed() -- the costs in an open profession window follow the new prices
    else
        ns.print("INCOMPLETE (" .. tostring(why) .. "): saved for the record, but the server will not use its prices")
    end
    local doc = Logic.buildDoc(run.meta, "browse", complete, run.t0, t1, rows, { uid = run.uid, rowCount = #results })
    ns.Export.save(doc)
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

function Scan.browse()
    local meta = ready(BROWSE_API, BROWSE_EVENTS)
    if not meta then return end
    local now = ns.serverTime()
    local run = { kind = "browse", meta = meta, t0 = now, startedMs = ns.clockMs(), pages = 0,
        sent = false, answered = false, wantMore = false, listed = 0,
        uid = Logic.newUid(now, Logic.rand31()) }
    current = run
    ns.after(BROWSE_TIMEOUT, function()
        if current ~= run then return end
        finishBrowse(run, false, "gave up after " .. BROWSE_TIMEOUT .. " s")
    end)
    browseSend(run)
    if current == run then
        ns.print(run.sent and "browsing the whole market ... please leave the auction house search alone until it is done"
            or "waiting for the auction house to accept a query ...")
    end
end

ns.on("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", onBrowseResults)
ns.on("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", onBrowseResults)

ns.on("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function()
    local run = current
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

-- Core's own handler for this event runs first, so ns.ahOpen is already false here.
ns.on("AUCTION_HOUSE_CLOSED", function()
    late = nil -- whatever list arrives after this is not read
    local run = current
    if not run then return end
    if run.kind == "browse" then
        finishBrowse(run, false, "the auction house was closed")
    elseif run.kind == "replicate" then
        run.interrupted = true
        if not run.processing then
            current = nil
            ns.print("full scan: the auction house was closed before the list arrived. Nothing was saved.")
        end
    end
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
    })
    ns.Export.save(doc)
end

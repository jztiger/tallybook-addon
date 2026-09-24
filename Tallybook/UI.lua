-- Tallybook: what the player sees on item tooltips, and the /tally status lines.
--
--   Min AH Price: 45s (7m)                                  cheapest listing, from the last browse scan
--   Market: 52s · sells ~3.2/day                            what the server worked out, from Data.lua (M3)
--   Vendor: 10c                                             when a visited vendor sells it
--   Crafting Cost: 4s 90c                  Profit: 37s 85c  green, or "Loss: ..." in red: crafting to sell at the
--     4 x Medium Leather @ 1s 20c                   4s 80c  Min AH Price, less the auction house's cut. Left out
--     1 x Coarse Thread (vendor)                       10c  when it would be a guess (Logic.craftingProfit).
--
-- Crafting Cost = the mats of the cheapest known recipe, each at its vendor price when a vendor the player has
-- visited sells it, otherwise its auction price (last browse scan), times the quantity (Logic.cheapestRecipe).
-- Recipes and vendor prices are learned by Craft.lua from windows the player opened.
--
-- The tooltip price comes from the last complete browse scan held in memory (TallybookDB.prices).
-- That table may be empty: saved state does not survive a full client restart on this client, so
-- no line is simply no line until the next /tally browse. Nothing here asks the server anything.

local _, ns = ...
local Logic = ns.Logic

local UI = {}
ns.UI = UI

local LABEL = "|cff33ff99Min AH Price|r: "
local CRAFT_LABEL = "|cff33ff99Crafting Cost|r: "
local VENDOR_LABEL = "|cff33ff99Vendor|r: "
local MARKET_LABEL = "|cff33ff99Market|r: "
local PROFIT, LOSS, DIM, CLOSE = "|cff00ff00Profit: ", "|cffff2020Loss: ", "|cff808080", "|r"

---------------------------------------------------------------------------------------------------
-- Money
---------------------------------------------------------------------------------------------------

local function money(copper)
    if type(C_CurrencyInfo) == "table" and type(C_CurrencyInfo.GetCoinTextureString) == "function" then
        local ok, text = pcall(C_CurrencyInfo.GetCoinTextureString, copper)
        if ok and type(text) == "string" and text ~= "" then return text end
    end
    if type(GetCoinTextureString) == "function" then
        local ok, text = pcall(GetCoinTextureString, copper)
        if ok and type(text) == "string" and text ~= "" then return text end
    end
    return Logic.formatMoney(copper)
end
UI.money = money

---------------------------------------------------------------------------------------------------
-- Tooltip line: "Tallybook: <min price> (<age>)"
---------------------------------------------------------------------------------------------------

-- Where the prices came from when not from this session's own scan: "saved" (the player's own earlier scan, handed
-- back by the local bake) or "shared" (the newest scan anyone uploaded, from the server). "" for the player's own.
function UI.priceSource(before, after)
    local db = TallybookDB
    local from = type(db) == "table" and db.pricesFrom or nil
    if from ~= "saved" and from ~= "shared" then return "" end
    return (before or "") .. from .. (after or "")
end

-- -> the line for this item, or nil when there is no price for it, THEN (M3) the market line, or nil when
-- the data file has no market value for it. Two separate answers: an item nobody is selling today can
-- still have a market value, and a market value is not "what it costs right now".
function UI.priceLine(itemID)
    if ns.isSecret(itemID) or type(itemID) ~= "number" then return nil end
    local db = TallybookDB
    if type(db) ~= "table" or type(db.prices) ~= "table" then return nil end
    local line
    local price = db.prices[itemID]
    if type(price) == "number" and price > 0 then
        line = LABEL .. money(price)
        if type(db.pricesAt) == "number" and db.pricesAt > 0 then
            line = line .. " (" .. Logic.formatAge(ns.serverTime() - db.pricesAt) .. UI.priceSource(", ") .. ")"
        end
    end
    return line, UI.marketLine(itemID)
end

-- -> "Market: <value> · sells ~N.N/day", the two figures the server works out and sends back in Data.lua
-- (spec 2026-09-24 section 5). The sale rate travels x100 as a whole number, so it is divided here; it is
-- left off entirely when the server has none, and 0.0/day is a real answer rather than a missing one.
function UI.marketLine(itemID)
    if ns.isSecret(itemID) or type(itemID) ~= "number" then return nil end
    local db = TallybookDB
    if type(db) ~= "table" or type(db.market) ~= "table" then return nil end
    local value = db.market[itemID]
    if type(value) ~= "number" or value <= 0 then return nil end
    local line = MARKET_LABEL .. money(value)
    local sells = type(db.sells) == "table" and db.sells[itemID] or nil
    if type(sells) == "number" and sells >= 0 then
        line = line .. " · sells ~" .. string.format("%.1f", sells / 100) .. "/day"
    end
    return line
end

-- -> "Vendor: <unit price>" for an item a visited vendor sells for gold in unlimited supply, else nil.
-- This is the price Crafting Cost uses for that mat, whatever the auction house says.
function UI.vendorLine(itemID)
    if ns.isSecret(itemID) or type(itemID) ~= "number" then return nil end
    local db = TallybookDB
    if type(db) ~= "table" or type(db.vendor) ~= "table" then return nil end
    local price = db.vendor[itemID]
    if type(price) ~= "number" or price <= 0 then return nil end
    return VENDOR_LABEL .. money(price)
end

local function unpriced(n)
    if n == 1 then return "1 mat with no price" end
    return string.format("%.0f", n) .. " mats with no price"
end

-- The name as far as the client has it; an item it has not loaded yet is shown by its number (the hover itself
-- makes the client fetch it, so the next hover has the name).
local function itemName(itemID)
    if type(C_Item) == "table" and type(C_Item.GetItemNameByID) == "function" then
        local ok, name = pcall(C_Item.GetItemNameByID, itemID)
        if ok and not ns.isSecret(name) and type(name) == "string" and name ~= "" then return name end
    end
    return "item " .. string.format("%.0f", itemID)
end
UI.itemName = itemName

-- -> "Crafting Cost: <total> (<one> each) + N mats with no price", then "Profit: <n>" / "Loss: <n>" or nil, then
-- the chosen recipe's mats as { {left, right}, ... }; nil when no recipe makes this item
function UI.craftLine(itemID)
    if ns.isSecret(itemID) or type(itemID) ~= "number" then return nil end
    local db = TallybookDB
    if type(db) ~= "table" or type(db.recipes) ~= "table" then return nil end
    local _, total, missing, each, recipe = Logic.cheapestRecipe(db.recipes[itemID], db.prices, db.vendor)
    if not total then return nil end

    local mats = {}
    local rows = Logic.costBreakdown(recipe, db.prices, db.vendor)
    for i = 1, #rows do
        local row = rows[i]
        local left = "  " .. string.format("%.0f", row.qty) .. " x " .. itemName(row.itemID)
        if row.source == "vendor" then left = left .. " (vendor)" end
        if row.unit and row.qty > 1 then left = left .. " @ " .. money(row.unit) end
        mats[i] = { left, row.total and money(row.total) or (DIM .. "no price" .. CLOSE) }
    end

    if total == 0 and missing > 0 then return CRAFT_LABEL .. "unknown (" .. unpriced(missing) .. ")", nil, mats end
    local line = CRAFT_LABEL .. money(total)
    if each ~= total then line = line .. " (" .. money(each) .. " each)" end
    if missing > 0 then line = line .. " + " .. unpriced(missing) end

    -- M3, fix round 1: what one sells for is the server's market value when there is one, today's cheapest
    -- listing when there is not - the same order Logic.profitSummary uses for the Profit panel. Hovering a
    -- row of that panel shows this tooltip, so the two must never quote different profits for one recipe.
    local result
    local market = type(db.market) == "table" and db.market[itemID] or nil
    local price = (type(market) == "number" and market > 0) and market
        or (type(db.prices) == "table" and db.prices[itemID] or nil)
    local profit = Logic.craftingProfit(total, missing, recipe.qty, price)
    if profit then
        result = (profit >= 0 and (PROFIT .. money(profit)) or (LOSS .. money(-profit))) .. CLOSE
    end
    return line, result, mats
end

-- Two columns where the tooltip has them, the same words on one line where it does not. soft: the quieter
-- off-white of the mat lines, so the cost line above them stays the headline.
local function addPair(tooltip, left, right, soft)
    if type(tooltip.AddDoubleLine) == "function" then
        if soft then
            tooltip:AddDoubleLine(left, right, 0.85, 0.85, 0.85, 0.85, 0.85, 0.85)
        else
            tooltip:AddDoubleLine(left, right)
        end
    else
        tooltip:AddLine(left .. "  " .. right)
    end
end

local function addLine(tooltip, itemID)
    if type(tooltip) ~= "table" or type(tooltip.AddLine) ~= "function" then return end
    local line, market = UI.priceLine(itemID)
    if line then tooltip:AddLine(line) end
    if market then tooltip:AddLine(market) end
    local vendor = UI.vendorLine(itemID)
    if vendor then tooltip:AddLine(vendor) end
    local craft, result, mats = UI.craftLine(itemID)
    if not craft then return end
    if result then addPair(tooltip, craft, result) else tooltip:AddLine(craft) end
    for i = 1, #mats do addPair(tooltip, mats[i][1], mats[i][2], true) end
end

local function fromTooltipData(tooltip, data)
    if ns.isSecret(data) or type(data) ~= "table" then return end
    addLine(tooltip, data.id)
end

local function fromItemLink(tooltip)
    if type(tooltip) ~= "table" or type(tooltip.GetItem) ~= "function" then return end
    local _, link = tooltip:GetItem()
    if ns.isSecret(link) or type(link) ~= "string" then return end
    addLine(tooltip, tonumber(string.match(link, "item:(%d+)")))
end

-- The whole handler runs under pcall, and a tooltip failure is swallowed: a broken price line
-- must never break the game's tooltips or fill the chat on every mouse-over.
local hooked = false
if type(TooltipDataProcessor) == "table" and type(TooltipDataProcessor.AddTooltipPostCall) == "function"
    and type(Enum) == "table" and type(Enum.TooltipDataType) == "table" and Enum.TooltipDataType.Item ~= nil then
    hooked = pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Item, function(tooltip, data)
        pcall(fromTooltipData, tooltip, data)
    end)
end
if not hooked and type(GameTooltip) == "table" and type(GameTooltip.HookScript) == "function"
    and type(GameTooltip.HasScript) == "function" then
    local okHas, has = pcall(GameTooltip.HasScript, GameTooltip, "OnTooltipSetItem")
    if okHas and has then
        hooked = pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetItem", function(tooltip)
            pcall(fromItemLink, tooltip)
        end)
    end
end
UI.tooltipHooked = hooked

---------------------------------------------------------------------------------------------------
-- /tally : status
---------------------------------------------------------------------------------------------------

local function age(at, now)
    -- "never" may only mean "not since the client was restarted": saved state does not survive that
    if type(at) ~= "number" or at <= 0 then return "never, or not since the last client restart" end
    return Logic.formatAge(now - at) .. " ago"
end

function UI.status()
    local db = ns.db()
    local now = ns.serverTime()
    local scans, bytes = Logic.ringStats(db.chunks)
    local allowed, remaining = Logic.canReplicate(now, db.state.lastReplicateAt, Logic.REPLICATE_COOLDOWN)

    ns.print("v" .. Logic.VERSION .. " - auction house " .. (ns.ahOpen and "open" or "closed")
        .. (ns.Scan.busy() and ", a scan is running" or ""))
    ns.print("last full scan: " .. age(db.state.lastReplicateAt, now)
        .. (allowed and ", ready" or (", cooldown " .. Logic.formatAge(remaining) .. " left")))
    ns.print("last browse scan: " .. age(db.state.lastBrowseAt, now))
    ns.print(string.format("held in memory: %.0f %s (room for %.0f), %.1f KB of %.0f MB - /tally reload writes them to disk",
        scans, scans == 1 and "scan" or "scans", Logic.RING_MAX_SCANS, bytes / 1024, Logic.RING_MAX_BYTES / 1048576))

    local priced = 0
    for _ in pairs(db.prices) do priced = priced + 1 end
    if priced > 0 then
        ns.print(string.format("tooltip prices: %.0f items, from %s", priced, age(db.pricesAt, now)) .. UI.priceSource(" (", ")"))
    else
        ns.print("tooltip prices: none yet - /tally browse fills them")
    end
    local recipes, vendor = 0, 0
    for _, list in pairs(db.recipes) do
        if type(list) == "table" then recipes = recipes + #list end
    end
    for _ in pairs(db.vendor) do vendor = vendor + 1 end
    if recipes > 0 or vendor > 0 then
        ns.print(string.format("recipes known: %.0f - vendor prices: %.0f", recipes, vendor))
    else
        ns.print("recipes known: none yet - open a profession window, and a vendor for thread and dyes")
    end
    local baked = ns.baked
    if type(baked) == "table" and type(baked.builtAt) == "number" and baked.builtAt > 0 then
        local bakedVendor, bakedRecipes = 0, 0
        if type(baked.vendor) == "table" then
            for _ in pairs(baked.vendor) do bakedVendor = bakedVendor + 1 end
        end
        if type(baked.recipes) == "table" then
            for _, list in pairs(baked.recipes) do
                if type(list) == "table" then bakedRecipes = bakedRecipes + #list end
            end
        end
        ns.print(string.format("built-in data: %.0f vendor %s, %.0f %s, baked %s", bakedVendor,
            bakedVendor == 1 and "price" or "prices", bakedRecipes, bakedRecipes == 1 and "recipe" or "recipes",
            age(baked.builtAt, now)))
    else
        -- The empty Data.lua the addon ships with: nothing has replaced it yet. This is what a friend sees in the
        -- minutes after installing, and saying nothing at all left them wondering whether it was working.
        ns.print("built-in data: none yet - it arrives on its own once you have scanned and reloaded")
    end
    local ok, why = ns.Export.available()
    if not ok then ns.print(why) end
end

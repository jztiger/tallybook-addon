-- Tallybook: a number next to each recipe in the profession window's recipe list - the profit of crafting it to
-- sell (green / red), or with "/tally list cost" its crafting cost coloured the same way.
--
-- Display only. It prices recipes with what Craft.lua learned (or Data.lua brought back) and the last
-- browse scan; it asks the game and the server nothing. The game recycles list rows as the player
-- scrolls, so the text is set from the list's own "this row was just set up" callback, never once per
-- row. Everything about the window is feature-detected: on a client with another profession window
-- nothing happens, and a failure in here is swallowed - it must never break the game's window.

local _, ns = ...
local Logic = ns.Logic

local List = {}
ns.List = List

local PAD = 6        -- between the cost and the row's right edge, and between the name and the cost
local LABEL_LEFT = 36 -- where a recipe name starts when the row cannot say

local hooked = false
local GREEN, RED, CLOSE = "|cff00ff00", "|cffff2020", "|r"
local index, outputs -- recipeID -> recipe entry / output item; dropped whenever something new is learned

local function scrollBox()
    local frame = ProfessionsFrame
    local page = type(frame) == "table" and frame.CraftingPage
    local list = type(page) == "table" and page.RecipeList
    local box = type(list) == "table" and list.ScrollBox
    if type(box) == "table" then return box end
    return nil
end

-- What a row says; nil for a recipe never seen.
--   list = "profit" (default): "+<money>" green or "-<money>" red - crafting to sell at the Min AH Price
--   list = "cost":             the crafting cost, green when the craft pays and red when it does not
-- When the profit cannot be told (a mat with no price, nobody selling) both fall back to the plain cost:
-- "<money>", "<money> +?" when some mats have no price, "?" when none has.
function List.costText(recipeID)
    if ns.isSecret(recipeID) or type(recipeID) ~= "number" then return nil end
    local db = TallybookDB
    if type(db) ~= "table" then return nil end
    if not index then index, outputs = Logic.recipeIndex(db.recipes) end
    local entry = index[recipeID]
    local total, missing = Logic.craftingCost(entry, db.prices, db.vendor)
    if not total then return nil end
    if missing > 0 then
        if total == 0 then return "?" end
        return ns.UI.money(total) .. " +?"
    end
    local itemID = outputs[recipeID]
    -- M3, fix round 1: the server's market value where there is one, today's cheapest listing otherwise -
    -- the order Logic.profitSummary and UI.craftLine both use. This number and the Profit panel's are on
    -- screen together, off the same profession window, so they price the same recipe the same way.
    local market = itemID and type(db.market) == "table" and db.market[itemID] or nil
    local price = (type(market) == "number" and market > 0) and market
        or (itemID and type(db.prices) == "table" and db.prices[itemID] or nil)
    local profit = Logic.craftingProfit(total, missing, entry.qty, price)
    if not profit then return ns.UI.money(total) end
    local colour = profit >= 0 and GREEN or RED
    if ns.settings().list == "cost" then return colour .. ns.UI.money(total) .. CLOSE end
    return colour .. (profit >= 0 and "+" or "-") .. ns.UI.money(math.abs(profit)) .. CLOSE
end

-- A list entry is a tree node: node:GetData().recipeInfo.recipeID. Category headers have no recipeInfo.
local function recipeIDOf(elementData)
    local data = elementData
    if type(data) == "table" and type(data.GetData) == "function" then data = data:GetData() end
    local info = type(data) == "table" and data.recipeInfo
    if type(info) ~= "table" then return nil end
    return info.recipeID
end

local function decorate(row, elementData)
    if type(row) ~= "table" or type(row.CreateFontString) ~= "function" then return end
    if elementData == nil and type(row.GetElementData) == "function" then elementData = row:GetElementData() end
    local text = List.costText(recipeIDOf(elementData))
    local cost = row.TallybookCost
    if not cost then
        if not text then return end
        cost = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        cost:SetPoint("RIGHT", row, "RIGHT", -PAD, 0)
        cost:SetJustifyH("RIGHT")
        cost:SetTextColor(0.75, 0.75, 0.75)
        row.TallybookCost = cost
    end
    cost:SetText(text or "")
    if not text then return end

    -- The game sizes the name anew each time it sets a row up; narrow it if it would run under the cost.
    local label = row.Label
    if type(label) ~= "table" or type(label.GetWidth) ~= "function" or type(label.SetWidth) ~= "function" then return end
    local left = LABEL_LEFT
    if type(label.GetLeft) == "function" and type(row.GetLeft) == "function" then
        local labelLeft, rowLeft = label:GetLeft(), row:GetLeft()
        if type(labelLeft) == "number" and type(rowLeft) == "number" then left = labelLeft - rowLeft end
    end
    local room = row:GetWidth() - left - cost:GetStringWidth() - PAD
    if room > 0 and label:GetWidth() > room then label:SetWidth(room) end
end

-- ScrollUtil hands over (row, entry); a callback registry hands over (owner, row, entry).
local function onRow(a, b, c)
    if a == List then a, b = b, c end
    pcall(decorate, a, b)
end

-- Safe to call any number of times; does nothing until the game has built its profession window.
function List.hook()
    if hooked then return true end
    local box = scrollBox()
    if not box then return false end
    if type(ScrollUtil) == "table" and type(ScrollUtil.AddInitializedFrameCallback) == "function" then
        hooked = pcall(ScrollUtil.AddInitializedFrameCallback, box, onRow, List, true)
    end
    if not hooked and type(box.RegisterCallback) == "function" then
        local events = type(ScrollBoxListMixin) == "table" and ScrollBoxListMixin.Event
        local event = type(events) == "table" and events.OnInitializedFrame or "OnInitializedFrame"
        hooked = pcall(box.RegisterCallback, box, event, onRow, List)
        if hooked then List.refresh() end
    end
    return hooked
end

-- Something was learned or scanned: re-price the rows that are on screen right now.
function List.refresh()
    index = nil
    local box = hooked and scrollBox()
    if not box or type(box.ForEachFrame) ~= "function" then return end
    pcall(box.ForEachFrame, box, onRow)
end

ns.onChange(List.refresh)
ns.on("TRADE_SKILL_SHOW", List.hook)
ns.on("TRADE_SKILL_LIST_UPDATE", List.hook)
-- The window's code is load-on-demand: it may arrive after this addon, and after TRADE_SKILL_SHOW reached us.
ns.on("ADDON_LOADED", function(name)
    if name == "Blizzard_Professions" then List.hook() end
end)

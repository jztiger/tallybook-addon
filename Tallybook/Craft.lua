-- Tallybook: learning what things cost to make.
--
-- Two readers, both of windows the PLAYER opened, neither of which sends anything to the server:
--   * a profession window -> each recipe's output item, how many it makes, and its required mats
--   * a vendor window     -> the unit price of everything sold for plain gold in unlimited supply
-- What is learned lands in TallybookDB.recipes / TallybookDB.vendor; UI.lua turns it into the
-- "Crafting Cost" tooltip line with Logic.cheapestRecipe. Nothing here touches the auction house.

local ADDON, ns = ...
local Logic = ns.Logic

local Craft = {}
ns.Craft = Craft

local SLICE = 50 -- recipe schematics read per frame
local BASIC = 1  -- Enum.CraftingReagentType.Basic, when the enum is missing

local reading = false

local function basicType()
    local e = type(Enum) == "table" and Enum.CraftingReagentType
    if type(e) == "table" and type(e.Basic) == "number" then return e.Basic end
    return BASIC
end

-- One recipe schematic -> outputItemID, quantity made, { {itemID, qty}, ... }, name (M2; the first three
-- nil when the schematic is unusable, name nil when the schematic simply has none - a missing name is
-- left missing, never guessed).
local function readSchematic(schematic)
    if ns.isSecret(schematic) or type(schematic) ~= "table" then return nil end
    local slots = schematic.reagentSlotSchematics
    if type(slots) ~= "table" then return nil end
    local basic, mats = basicType(), {}
    for i = 1, #slots do
        local slot = slots[i]
        if type(slot) == "table" and slot.required ~= false
            and (slot.reagentType == nil or slot.reagentType == basic)
            and type(slot.reagents) == "table" and type(slot.reagents[1]) == "table" then
            local itemID, qty = slot.reagents[1].itemID, slot.quantityRequired
            if not ns.isSecret(itemID) and not ns.isSecret(qty) then mats[#mats + 1] = { itemID, qty } end
        end
    end
    local made = schematic.quantityMin
    if ns.isSecret(made) or type(made) ~= "number" or made < 1 then made = 1 end
    local name = schematic.name
    if ns.isSecret(name) or type(name) ~= "string" or name == "" then name = nil end
    return schematic.outputItemID, made, mats, name
end

local function countNew(book, outputItemID, recipeID)
    local list = book[outputItemID]
    if type(list) ~= "table" then return 1 end
    for i = 1, #list do
        if type(list[i]) == "table" and list[i].recipeID == recipeID then return 0 end
    end
    return 1
end

-- The open profession's name and its numeric skill line (M2), the FALLBACK for a recipe recipeProfession
-- below cannot place: C_TradeSkillUI.GetBaseProfessionInfo() is already used the same way in
-- Summary.lua:80. professionID is the TradeSkillLineID (Tailoring = 197, what recipe.skill_line means
-- server-side) - a different number from the small `profession` enum field on the same table, which this
-- does not read (0.9.2, confirmed against the live client). Guarded like every other client API here; 0
-- means unknown.
local function professionInfo()
    local T = C_TradeSkillUI
    if type(T) ~= "table" or type(T.GetBaseProfessionInfo) ~= "function" then return nil, 0 end
    local ok, info = pcall(T.GetBaseProfessionInfo)
    if not ok or ns.isSecret(info) or type(info) ~= "table" then return nil, 0 end
    local name = info.professionName
    if ns.isSecret(name) or type(name) ~= "string" or name == "" then name = nil end
    local id = info.professionID
    if ns.isSecret(id) or type(id) ~= "number" or id < 0 or id % 1 ~= 0 then id = 0 end
    return name, id
end

-- 0.9.2, live defect: a recipe's OWN trade skill line, when the client can say one, wins over whatever
-- profession window happens to be open. Found in game: 604 Leatherworking recipes filed as "Skinning"
-- (skill line 393) and 32 Cooking recipes as "Fishing" (356) - in both pairs the FIRST name is the
-- profession that had been open just before the one actually read. GetAllRecipeIDs already lists the new
-- profession's recipes at the moment GetBaseProfessionInfo can still describe the old one for a moment
-- longer, so a single read of the window at the top of learnRecipes can tag a whole profession wrong.
--
-- 0.9.3, live finding: GetTradeSkillLineForRecipe's own tradeSkillID turned out to be FOREVER'S OWN
-- internal id space (Leatherworking 2945, Cooking 2939, First Aid 2942, Fishing 2943, Skinning 2947,
-- Tailoring 2948 - all seen live), not the classic profession id the window and the server both mean by
-- skill_line (professionID 165 for Leatherworking, confirmed by the owner's live /dump). The two id
-- spaces mixed in one column worked only because a name still told them apart on the pages; a row with no
-- name would not survive it. So the NAME is always this call's own skillLineName once it has one; the ID
-- is resolved through ONE precedence, stated here in full (flushPending below applies only its last two
-- tiers, and points back to this comment rather than restating them):
--   1. parentTradeSkillID - this call's own third return - when a positive integer: the cheapest correct
--      answer, needing nothing further.
--   2. else C_TradeSkillUI.GetProfessionInfoBySkillLineID(tradeSkillID): its parentProfessionID when a
--      positive integer, else its professionID when a positive integer.
--   3. else the WINDOW's professionID (professionInfo above, read once the whole read is done - 0.9.2)
--      when a positive integer.
--   4. else this call's own raw tradeSkillID - Forever's internal id, wrong space but still an id, and
--      only ever reached when nothing else above answered anything at all.
-- -> skillLineName, id, tradeSkillID. id is the FULLY resolved answer (tier 1 or 2) when non-nil, in
-- which case the caller can file the recipe immediately; id nil means tiers 3-4 (the window, then
-- tradeSkillID itself) decide once the read completes - skillLineName and tradeSkillID still ride along
-- for that. Every value nil when the client has no GetTradeSkillLineForRecipe at all, or this one recipe
-- answers nothing usable - tier 3 then supplies BOTH the name and the id, as it always has.
local function recipeProfession(recipeID)
    local T = C_TradeSkillUI
    if type(T) ~= "table" or type(T.GetTradeSkillLineForRecipe) ~= "function" then return nil, nil, nil end
    local ok, tradeSkillID, skillLineName, parentTradeSkillID = pcall(T.GetTradeSkillLineForRecipe, recipeID)
    if not ok or ns.isSecret(tradeSkillID) or ns.isSecret(skillLineName) then return nil, nil, nil end
    if type(skillLineName) ~= "string" or skillLineName == "" then return nil, nil, nil end
    if type(tradeSkillID) ~= "number" or tradeSkillID < 1 or tradeSkillID % 1 ~= 0 then return nil, nil, nil end
    -- Tier 1.
    if not ns.isSecret(parentTradeSkillID) and type(parentTradeSkillID) == "number"
        and parentTradeSkillID > 0 and parentTradeSkillID % 1 == 0 then
        return skillLineName, parentTradeSkillID, tradeSkillID
    end
    -- Tier 2.
    if type(T.GetProfessionInfoBySkillLineID) == "function" then
        local ok2, info = pcall(T.GetProfessionInfoBySkillLineID, tradeSkillID)
        if ok2 and not ns.isSecret(info) and type(info) == "table" then
            local parentID = info.parentProfessionID
            if not ns.isSecret(parentID) and type(parentID) == "number" and parentID > 0 and parentID % 1 == 0 then
                return skillLineName, parentID, tradeSkillID
            end
            local profID = info.professionID
            if not ns.isSecret(profID) and type(profID) == "number" and profID > 0 and profID % 1 == 0 then
                return skillLineName, profID, tradeSkillID
            end
        end
    end
    -- Neither tier resolved: id stays nil, tiers 3-4 decide at flush time.
    return skillLineName, nil, tradeSkillID
end

-- Reads every recipe of the open profession, SLICE per frame. A recipe recipeProfession cannot place
-- waits in `pending` for the window's own answer - read once, after the LAST schematic rather than before
-- the first (0.9.2, the live defect above): by the time every recipe has been read, the window can only
-- describe the profession that is actually open, whatever it still said when the read began. Every
-- pending recipe of this run gets that one end-of-read answer.
function Craft.learnRecipes()
    local T = C_TradeSkillUI
    if reading or type(T) ~= "table" or type(T.GetAllRecipeIDs) ~= "function"
        or type(T.GetRecipeSchematic) ~= "function" or type(C_Timer) ~= "table" then return end
    if type(T.IsTradeSkillReady) == "function" then
        local okReady, ready = pcall(T.IsTradeSkillReady)
        if not okReady or not ready then return end -- TRADE_SKILL_LIST_UPDATE will bring us back
    end
    local okIDs, ids = pcall(T.GetAllRecipeIDs)
    if not okIDs or type(ids) ~= "table" or #ids == 0 then return end

    local db = Logic.initDB(TallybookDB)
    local i, added = 0, 0
    -- { outputItemID, recipeID, qty, mats, name, fresh, profName, tradeSkillID }, one per recipe whose id
    -- recipeProfession could not resolve on its own (tiers 1-2 in the comment above): profName and
    -- tradeSkillID are whatever recipeProfession DID find - a name with no id yet, or nothing at all - and
    -- ride along so flushPending can apply tiers 3-4 without losing a name it already had (0.9.3).
    local pending = {}
    reading = true

    -- Files every still-pending recipe once the read is done: tiers 3 (the window's own professionID,
    -- read now for the reason 0.9.2 gives above) then 4 (the entry's own tradeSkillID) of the precedence on
    -- recipeProfession, applied only to the id - a recipe's own name (entry's profName) always wins over
    -- the window's when recipeProfession already found one; only a recipe it told nothing about at all
    -- uses the window's name too. Also the recovery path if step() throws partway through: what was
    -- already read should not be lost just because its id was not settled yet.
    local function flushPending()
        if #pending == 0 then return end
        local windowName, windowID = professionInfo()
        for p = 1, #pending do
            local entry = pending[p]
            local profName = entry[7] or windowName
            local skillLine = windowID
            if skillLine <= 0 and type(entry[8]) == "number" and entry[8] > 0 then skillLine = entry[8] end
            if Logic.addRecipe(db.recipes, entry[1], entry[2], entry[3], entry[4], entry[5], profName, skillLine) then
                added = added + entry[6]
            end
        end
        pending = {}
    end

    local function step()
        local stop = math.min(i + SLICE, #ids)
        while i < stop do
            i = i + 1
            local recipeID = ids[i]
            local ok, schematic = pcall(T.GetRecipeSchematic, recipeID, false)
            if ok then
                local outputItemID, made, mats, name = readSchematic(schematic)
                if outputItemID then
                    local fresh = countNew(db.recipes, outputItemID, recipeID)
                    local profName, skillLine, tradeSkillID = recipeProfession(recipeID)
                    if profName and skillLine then
                        if Logic.addRecipe(db.recipes, outputItemID, recipeID, made, mats, name, profName, skillLine) then
                            added = added + fresh
                        end
                    else
                        pending[#pending + 1] = { outputItemID, recipeID, made, mats, name, fresh, profName, tradeSkillID }
                    end
                end
            end
        end
        if i < #ids then
            C_Timer.After(0, step)
            return
        end
        flushPending()
        reading = false
        ns.changed()
        if added > 0 then
            ns.pendingUpload = true -- 0.9.3: something is now waiting on a Send / /tally reload to go out
            ns.print(string.format("learned %.0f recipes (%.0f new) - hover a craftable item to see its Crafting Cost", #ids, added))
        end
        -- M2: a small on-screen confirmation beside the Profit button, every run - not only when
        -- something is new, so reopening an already-known profession still confirms it worked.
        if ns.Summary and type(ns.Summary.setLearned) == "function" then ns.Summary.setLearned(#ids, added) end
    end
    local ok, err = pcall(step)
    if not ok then
        reading = false
        flushPending()
        ns.fail("recipes", err)
    end
end

-- Reads the open vendor's price list.
function Craft.learnVendor()
    if type(C_MerchantFrame) ~= "table" or type(C_MerchantFrame.GetItemInfo) ~= "function"
        or type(GetMerchantNumItems) ~= "function" or type(GetMerchantItemID) ~= "function" then return end
    local okN, n = pcall(GetMerchantNumItems)
    if not okN or ns.isSecret(n) or type(n) ~= "number" then return end
    local db = Logic.initDB(TallybookDB)
    local learned = 0
    for index = 1, n do
        local okI, info = pcall(C_MerchantFrame.GetItemInfo, index)
        local okID, itemID = pcall(GetMerchantItemID, index)
        if okI and okID and not ns.isSecret(info) and not ns.isSecret(itemID)
            and type(itemID) == "number" and itemID > 0 then
            local price = Logic.vendorUnitPrice(info)
            if price then
                if db.vendor[itemID] ~= price then learned = learned + 1 end
                db.vendor[itemID] = price
            end
        end
    end
    if learned > 0 then
        ns.changed()
        ns.print(string.format("noted %.0f vendor prices here", learned))
    end
end

---------------------------------------------------------------------------------------------------
-- The basket (board card F13): what N crafts of one recipe really cost
---------------------------------------------------------------------------------------------------

-- chosen = { recipeID =, itemID =, name = }. Asks Scan for the ladder of every mat no vendor sells, then prints
-- the batch: each mat, the total, the cost of one craft next to the optimistic cheapest-listing figure, and the
-- profit of one craft when everything could be priced. Started by the player, one report, nothing kept running.
function Craft.basket(crafts, chosen)
    local db = Logic.initDB(TallybookDB)
    local index = Logic.recipeIndex(db.recipes)
    local recipe = type(chosen) == "table" and index[chosen.recipeID] or nil
    if not recipe then
        ns.print("click a recipe in the Profit panel first, or shift-click its item: /tally basket 20 [item]")
        return
    end
    local money, itemName = ns.UI.money, ns.UI.itemName
    local function report(ladders)
        local b = Logic.basket(recipe, crafts, db.vendor, ladders)
        if not b then return end
        ns.print(string.format("basket: %.0f x %s", crafts, tostring(chosen.name or itemName(chosen.itemID))))
        for i = 1, #b.rows do
            local row = b.rows[i]
            local line = string.format("  %.0f x %s", row.need, itemName(row.itemID))
            if row.source == "vendor" then
                line = line .. " (vendor): " .. money(row.cost)
            elseif row.bought == 0 then
                line = line .. ": nobody is selling any"
            elseif row.bought < row.need then
                line = line .. string.format(": only %.0f listed - ", row.bought) .. money(row.cost) .. " for those"
            else
                line = line .. ": " .. money(row.cost)
                if row.need > 1 then
                    line = line .. "  (average " .. money(math.ceil(row.cost / row.need)) .. ", cheapest " .. money(row.cheapest) .. ")"
                end
            end
            ns.print(line)
        end
        if b.short > 0 or b.missing > 0 then
            ns.print("total at least " .. money(b.total) .. string.format(" - %.0f %s could not be fully priced",
                b.short + b.missing, (b.short + b.missing) == 1 and "mat" or "mats"))
            return
        end
        local line = "total " .. money(b.total) .. " - " .. money(b.perCraft) .. " each"
        local estimate, missing = Logic.craftingCost(recipe, db.prices, db.vendor)
        if estimate and missing == 0 then line = line .. "  (cheapest-listing estimate: " .. money(estimate) .. " each)" end
        ns.print(line)
        local price = type(db.prices) == "table" and db.prices[chosen.itemID] or nil
        local profit = Logic.craftingProfit(b.perCraft, 0, recipe.qty, price)
        if profit then
            ns.print("sells for " .. money(price) .. ": " .. money(math.abs(profit)) .. (profit >= 0 and " profit" or " LOSS") .. " each")
        end
    end

    local mats = Logic.ladderMats(recipe, db.vendor)
    if #mats == 0 then return report({}) end -- every mat comes from a vendor: nothing to ask the auction house
    if ns.Scan.ladders(mats, report) then
        ns.print(string.format("pricing %.0f crafts: asking the auction house about %.0f %s ...", crafts, #mats, #mats == 1 and "mat" or "mats"))
    end
end

ns.on("TRADE_SKILL_SHOW", Craft.learnRecipes)
ns.on("TRADE_SKILL_LIST_UPDATE", Craft.learnRecipes)
ns.on("MERCHANT_SHOW", Craft.learnVendor)

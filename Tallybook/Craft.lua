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

-- One recipe schematic -> outputItemID, quantity made, { {itemID, qty}, ... }  (nil when it is unusable)
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
    return schematic.outputItemID, made, mats
end

local function countNew(book, outputItemID, recipeID)
    local list = book[outputItemID]
    if type(list) ~= "table" then return 1 end
    for i = 1, #list do
        if type(list[i]) == "table" and list[i].recipeID == recipeID then return 0 end
    end
    return 1
end

-- Reads every recipe of the open profession, SLICE per frame.
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
    reading = true
    local function step()
        local stop = math.min(i + SLICE, #ids)
        while i < stop do
            i = i + 1
            local recipeID = ids[i]
            local ok, schematic = pcall(T.GetRecipeSchematic, recipeID, false)
            if ok then
                local outputItemID, made, mats = readSchematic(schematic)
                if outputItemID then
                    local fresh = countNew(db.recipes, outputItemID, recipeID)
                    if Logic.addRecipe(db.recipes, outputItemID, recipeID, made, mats) then added = added + fresh end
                end
            end
        end
        if i < #ids then
            C_Timer.After(0, step)
            return
        end
        reading = false
        ns.changed()
        if added > 0 then
            ns.print(string.format("learned %.0f recipes (%.0f new) - hover a craftable item to see its Crafting Cost", #ids, added))
        end
    end
    local ok, err = pcall(step)
    if not ok then
        reading = false
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

ns.on("TRADE_SKILL_SHOW", Craft.learnRecipes)
ns.on("TRADE_SKILL_LIST_UPDATE", Craft.learnRecipes)
ns.on("MERCHANT_SHOW", Craft.learnVendor)

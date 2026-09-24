-- Tallybook: the profit summary of the open profession - a "Profit" button on the profession window and a
-- panel beside it with one row per recipe: cost, what it sells for, profit or loss.
--
-- Display only. The numbers are the tooltip's (Logic.profitSummary); opening, sorting and scrolling the
-- panel asks the game for recipe names and nothing else, and asks the server nothing. Both the button and
-- the panel sit OUTSIDE the profession window's right edge, so they cover nothing of the game's whatever
-- its layout. No templates are required: if the panel cannot be built on this client, /tally profit
-- prints the summary in chat instead. Nothing here crafts, buys or queues anything.

local _, ns = ...
local Logic = ns.Logic

local Summary = {}
ns.Summary = Summary

local VISIBLE, ROW_H = 20, 18 -- rows on screen, and the height of one
local TOP = 88                -- where the rows start, below the title, counts, toggles and column headers
local WHEEL = 3               -- rows per notch of the mouse wheel
local CRAFTS = { 1, 5, 10, 20, 50, 100 } -- what the "crafts" button cycles through, for a right-click basket
-- columns: sort key, header text, left edge, width, alignment, the row's field for it
local COLUMNS = {
    { "name", "Recipe", 12, 190, "LEFT", "name" },
    { "cost", "Cost", 206, 84, "RIGHT", "cost" },
    { "sale", "Sells for", 294, 84, "RIGHT", "sale" },
    { "listed", "Listed", 382, 56, "RIGHT", "listed" },
    { "profit", "Profit / Loss", 442, 124, "RIGHT", "result" },
}
local WIDTH = 578
-- The profession tabs hang off the window's right edge (about 45 wide on this client): the panel starts past them.
local CLEAR_OF_TABS = 52
local GREEN, RED, GREY, CLOSE = "|cff00ff00", "|cffff2020", "|cff808080", "|r"

-- The player's choices live in the settings (ns.settings: saved, else baked at the last install, else default);
-- state is this session's working copy, read once and written back on every change.
local state
local panel, cannotBuild

local function choices()
    if not state then
        local s = ns.settings()
        state = { key = s.sortKey, descending = s.sortDesc, knownOnly = s.knownOnly, hideUnknown = s.hideUnknown,
            offset = 0 }
    end
    return state
end

local crafts = 2 -- index into CRAFTS: 5 to start with

local function remember()
    ns.setSetting("list", ns.settings().list)
    ns.setSetting("sortKey", state.key)
    ns.setSetting("sortDesc", state.descending)
    ns.setSetting("knownOnly", state.knownOnly)
    ns.setSetting("hideUnknown", state.hideUnknown)
end
local current, counts = {}, { profit = 0, loss = 0, unknown = 0 }

local function window()
    if type(ProfessionsFrame) == "table" then return ProfessionsFrame end
    return nil
end

local function windowOpen()
    local w = window()
    if not w then return false end
    if type(w.IsShown) == "function" then return w:IsShown() and true or false end
    return true
end

-- Runs a widget script under pcall: a failure in here must never reach the game's own window.
local function guarded(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then ns.fail("summary", err) end
    end
end

local function professionName()
    local T = C_TradeSkillUI
    if type(T) == "table" and type(T.GetBaseProfessionInfo) == "function" then
        local ok, info = pcall(T.GetBaseProfessionInfo)
        if ok and not ns.isSecret(info) and type(info) == "table" and type(info.professionName) == "string"
            and info.professionName ~= "" then
            return info.professionName
        end
    end
    return "Profession"
end

local function plural(n, one, many)
    return string.format("%.0f", n) .. " " .. (n == 1 and one or many)
end

local function countsText()
    return string.format("%.0f profitable, %.0f at a loss, %.0f unknown", counts.profit, counts.loss, counts.unknown)
end

---------------------------------------------------------------------------------------------------
-- The rows
---------------------------------------------------------------------------------------------------

-- The open profession's recipes -> current (filtered, named, sorted) and counts (before "hide unknown").
local function compute()
    choices()
    current, counts = {}, { profit = 0, loss = 0, unknown = 0 }
    local T, db = C_TradeSkillUI, TallybookDB
    if type(T) ~= "table" or type(T.GetAllRecipeIDs) ~= "function" or type(db) ~= "table" then return end
    local ok, ids = pcall(T.GetAllRecipeIDs)
    if not ok or type(ids) ~= "table" then return end

    local wanted, names = {}, {}
    for i = 1, #ids do
        local recipeID = ids[i]
        local learned = true
        if type(T.GetRecipeInfo) == "function" then
            local okInfo, info = pcall(T.GetRecipeInfo, recipeID)
            if okInfo and not ns.isSecret(info) and type(info) == "table" then
                if info.learned == false then learned = false end
                if not ns.isSecret(info.name) and type(info.name) == "string" and info.name ~= "" then
                    names[recipeID] = info.name
                end
            end
        end
        if learned or not state.knownOnly then wanted[#wanted + 1] = recipeID end
    end

    local index, outputs = Logic.recipeIndex(db.recipes)
    local rows
    rows, counts = Logic.profitSummary(wanted, index, outputs, db.prices, db.vendor, db.listed, db.market)
    for i = 1, #rows do
        local row = rows[i]
        row.name = names[row.recipeID] or ns.UI.itemName(row.itemID)
        if not (state.hideUnknown and row.status == "unknown") then current[#current + 1] = row end
    end
    Logic.sortSummary(current, state.key, state.descending)
end

local function costText(row)
    if row.missing == 0 then return ns.UI.money(row.cost) end
    if row.cost == 0 then return "?" end
    return ns.UI.money(row.cost) .. " +?"
end

-- M3: what the craft sells for. The server's market value where there is one; today's cheapest listing
-- otherwise, marked "(now)" so a figure that is only what somebody happens to be asking today never reads
-- as what the item is worth.
local function saleText(row)
    if not row.sale then return "-" end
    return ns.UI.money(row.sale) .. (row.saleFrom == "now" and " (now)" or "")
end

local function resultText(row)
    if row.status == "profit" then return GREEN .. "+" .. ns.UI.money(row.profit) .. CLOSE end
    if row.status == "loss" then return RED .. "-" .. ns.UI.money(-row.profit) .. CLOSE end
    if row.why == "mats" then return GREY .. plural(row.missing, "mat", "mats") .. " with no price" .. CLOSE end
    return GREY .. "nobody selling" .. CLOSE
end

---------------------------------------------------------------------------------------------------
-- The panel
---------------------------------------------------------------------------------------------------

-- What a button says: through its own label when it has one, else the template's text.
function Summary.textOf(widget)
    if type(widget) ~= "table" then return nil end
    if widget.label then return widget.label:GetText() end
    return widget:GetText()
end

local function setText(widget, text)
    if widget.label then widget.label:SetText(text) else widget:SetText(text) end
end

-- A plain hover tooltip - the same GameTooltip:SetText/Show/Hide a plain-text tooltip anywhere in the game
-- uses. Guarded like everything else here: a client missing any one piece of it just shows no tooltip.
local function withTooltip(widget, text)
    widget:SetScript("OnEnter", guarded(function(self)
        if type(GameTooltip) ~= "table" or type(GameTooltip.SetText) ~= "function"
            or type(GameTooltip_SetDefaultAnchor) ~= "function" then return end
        GameTooltip_SetDefaultAnchor(GameTooltip, self)
        GameTooltip:SetText(text)
        GameTooltip:Show()
    end))
    widget:SetScript("OnLeave", guarded(function()
        if type(GameTooltip) == "table" and type(GameTooltip.Hide) == "function" then GameTooltip:Hide() end
    end))
end

local function newLabel(parent, font, justify)
    local text = parent:CreateFontString(nil, "OVERLAY", font)
    text:SetJustifyH(justify or "LEFT")
    text:SetWordWrap(false)
    return text
end

-- A plain button with its own text: needs no template, so it cannot be missing on this client.
local function textButton(parent, width, justify, onClick)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(width, ROW_H)
    button.label = newLabel(button, "GameFontNormalSmall", justify)
    button.label:SetAllPoints()
    button:SetScript("OnClick", guarded(onClick))
    return button
end

local function paint()
    if not panel then return end
    local db = TallybookDB
    local hasPrices = false
    if type(db) == "table" and type(db.prices) == "table" then
        for _ in pairs(db.prices) do
            hasPrices = true
            break
        end
    end
    if hasPrices then
        panel.title:SetText(professionName() .. " - prices from " .. Logic.formatAge(ns.serverTime() - db.pricesAt) .. " ago"
            .. ns.UI.priceSource(" (", ")"))
    else
        panel.title:SetText(professionName() .. " - no AH prices yet: /tally browse at the auction house")
    end

    local last = math.max(0, #current - VISIBLE)
    if state.offset > last then state.offset = last end
    if state.offset < 0 then state.offset = 0 end
    local range = ""
    if #current > VISIBLE then
        range = string.format("   (%.0f-%.0f of %.0f)", state.offset + 1, state.offset + VISIBLE, #current)
    end
    panel.counts:SetText(countsText() .. range)

    setText(panel.knownToggle, (state.knownOnly and "[x]" or "[ ]") .. " recipes I know only")
    setText(panel.unknownToggle, (state.hideUnknown and "[x]" or "[ ]") .. " hide unknown")
    for i = 1, #COLUMNS do
        local key, title = COLUMNS[i][1], COLUMNS[i][2]
        if key == state.key then title = title .. (state.descending and " v" or " ^") end
        setText(panel.headers[key], title)
    end

    for i = 1, VISIBLE do
        local row, data = panel.rows[i], current[state.offset + i]
        row.data = data
        if data then
            row.name:SetText(data.name)
            row.cost:SetText(costText(data))
            row.sale:SetText(saleText(data))
            row.listed:SetText(data.listed and string.format("%.0f", data.listed) or "-")
            row.result:SetText(resultText(data))
            row:Show()
        else
            row:Hide()
        end
    end
end

local function build(parent)
    local p = CreateFrame("Frame", nil, parent)
    p:SetSize(WIDTH, TOP + VISIBLE * ROW_H + 10)
    local at = ns.settings().panel -- where it was dragged to, if it ever was
    if at and type(UIParent) == "table" then
        p:SetPoint(at[1], UIParent, at[2], at[3], at[4])
    else
        p:SetPoint("TOPLEFT", parent, "TOPRIGHT", CLEAR_OF_TABS, -56)
    end
    -- Readable whatever is behind it: a solid background, and above the quest tracker, meters and action bars
    -- (tooltips and menus are higher still).
    p:SetFrameStrata("HIGH")
    p:SetToplevel(true)
    p:EnableMouse(true) -- clicks on the panel do not fall through to the world behind it
    p.background = p:CreateTexture(nil, "BACKGROUND")
    p.background:SetAllPoints()
    p.background:SetColorTexture(0.06, 0.06, 0.07, 1)
    -- a one-pixel frame and a band behind the title, so the panel reads as a window and not as a shadow
    for _, edge in ipairs({ { "TOPLEFT", "TOPRIGHT", nil, 1 }, { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 1 },
        { "TOPLEFT", "BOTTOMLEFT", 1, nil }, { "TOPRIGHT", "BOTTOMRIGHT", 1, nil } }) do
        local line = p:CreateTexture(nil, "BORDER")
        line:SetColorTexture(0.55, 0.45, 0.2, 1)
        line:SetPoint(edge[1], p, edge[1], 0, 0)
        line:SetPoint(edge[2], p, edge[2], 0, 0)
        if edge[3] then line:SetWidth(edge[3]) end
        if edge[4] then line:SetHeight(edge[4]) end
    end
    local band = p:CreateTexture(nil, "BORDER")
    band:SetColorTexture(1, 1, 1, 0.06)
    band:SetPoint("TOPLEFT", p, "TOPLEFT", 1, -1)
    band:SetPoint("TOPRIGHT", p, "TOPRIGHT", -1, -1)
    band:SetHeight(TOP - 4)

    -- Drag it anywhere with the left button; where it is dropped goes into the settings.
    p:SetMovable(true)
    p:SetClampedToScreen(true)
    p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart", guarded(function(self) self:StartMoving() end))
    p:SetScript("OnDragStop", guarded(function(self)
        self:StopMovingOrSizing()
        local point, _, relativePoint, x, y = self:GetPoint(1)
        if point and type(x) == "number" and type(y) == "number" then
            -- to the hundredth: what is saved is what the reference document and the baked file will say
            ns.setSetting("panel", { point, relativePoint, math.floor(x * 100 + 0.5) / 100, math.floor(y * 100 + 0.5) / 100 })
        end
    end))

    p.title = newLabel(p, "GameFontNormal")
    p.title:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -10)
    p.counts = newLabel(p, "GameFontHighlightSmall")
    p.counts:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -28)

    local close = textButton(p, 20, "CENTER", function() Summary.toggle() end)
    close:SetPoint("TOPRIGHT", p, "TOPRIGHT", -6, -6)
    setText(close, "x")

    -- How many crafts a right-click on a row prices (the basket, board card F13).
    p.craftsButton = textButton(p, 80, "RIGHT", function()
        crafts = crafts % #CRAFTS + 1
        setText(p.craftsButton, "crafts: " .. string.format("%.0f", CRAFTS[crafts]))
    end)
    p.craftsButton:SetPoint("TOPRIGHT", p, "TOPRIGHT", -34, -6)
    setText(p.craftsButton, "crafts: " .. string.format("%.0f", CRAFTS[crafts]))

    p.knownToggle = textButton(p, 170, "LEFT", function()
        state.knownOnly = not state.knownOnly
        state.offset = 0
        remember()
        Summary.refresh()
    end)
    p.knownToggle:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -46)
    p.unknownToggle = textButton(p, 130, "LEFT", function()
        state.hideUnknown = not state.hideUnknown
        state.offset = 0
        remember()
        Summary.refresh()
    end)
    p.unknownToggle:SetPoint("TOPLEFT", p, "TOPLEFT", 190, -46)

    p.headers = {}
    for i = 1, #COLUMNS do
        local key, _, left, width, justify = COLUMNS[i][1], COLUMNS[i][2], COLUMNS[i][3], COLUMNS[i][4], COLUMNS[i][5]
        local header = textButton(p, width, justify, function()
            if state.key == key then
                state.descending = not state.descending
            else
                state.key, state.descending = key, key ~= "name" -- numbers start biggest first, names A to Z
            end
            state.offset = 0
            remember()
            Summary.refresh()
        end)
        header:SetPoint("TOPLEFT", p, "TOPLEFT", left, -68)
        p.headers[key] = header
    end

    p.rows = {}
    for i = 1, VISIBLE do
        local row = CreateFrame("Button", nil, p)
        row:SetSize(WIDTH - 2, ROW_H)
        row:SetPoint("TOPLEFT", p, "TOPLEFT", 1, -(TOP + (i - 1) * ROW_H))
        if i % 2 == 0 then -- every other row shaded: the eye can follow a name across to its numbers
            row.stripe = row:CreateTexture(nil, "BACKGROUND")
            row.stripe:SetAllPoints()
            row.stripe:SetColorTexture(1, 1, 1, 0.05)
        end
        row.glow = row:CreateTexture(nil, "BORDER")
        row.glow:SetAllPoints()
        row.glow:SetColorTexture(1, 0.82, 0, 0.14)
        row.glow:Hide()
        for c = 1, #COLUMNS do
            local text = newLabel(row, "GameFontHighlightSmall", COLUMNS[c][5])
            text:SetWidth(COLUMNS[c][4])
            text:SetPoint("LEFT", row, "LEFT", COLUMNS[c][3], 0)
            row[COLUMNS[c][6]] = text
        end
        -- Left click: show the recipe in the game's own window (the call behind recipe links in chat). It
        -- selects; it never crafts - Create stays the player's own click. Right click: price a basket of it.
        -- Either way it becomes the recipe "/tally basket N" means.
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetScript("OnClick", guarded(function(self, button)
            if not self.data then return end
            Summary.chosen = { recipeID = self.data.recipeID, itemID = self.data.itemID, name = self.data.name }
            if button == "RightButton" then
                ns.Craft.basket(CRAFTS[crafts], Summary.chosen)
                return
            end
            local T = C_TradeSkillUI
            if type(T) == "table" and type(T.OpenRecipe) == "function" then pcall(T.OpenRecipe, self.data.recipeID) end
        end))
        -- The item's own tooltip carries the full breakdown (UI.lua adds it to every item tooltip).
        row:SetScript("OnEnter", guarded(function(self)
            self.glow:Show()
            if not self.data or type(GameTooltip) ~= "table" or type(GameTooltip.SetItemByID) ~= "function"
                or type(GameTooltip_SetDefaultAnchor) ~= "function" then return end
            GameTooltip_SetDefaultAnchor(GameTooltip, self)
            GameTooltip:SetItemByID(self.data.itemID)
            GameTooltip:Show()
        end))
        row:SetScript("OnLeave", guarded(function(self)
            self.glow:Hide()
            if type(GameTooltip) == "table" and type(GameTooltip.Hide) == "function" then GameTooltip:Hide() end
        end))
        p.rows[i] = row
    end

    p:EnableMouseWheel(true)
    p:SetScript("OnMouseWheel", guarded(function(_, delta)
        state.offset = state.offset - delta * WHEEL
        paint()
    end))
    p:Hide()
    return p
end

---------------------------------------------------------------------------------------------------
-- Opening it
---------------------------------------------------------------------------------------------------

-- Re-reads and re-draws an open panel. Called when anything is learned or scanned (ns.changed) - which
-- includes the profession window changing what it shows: Craft.lua re-reads the recipes then, and says so
-- once at the end, however many list events the game sent in between.
function Summary.refresh()
    if not panel or not panel:IsShown() then return end
    compute()
    paint()
end

-- The same summary as a few chat lines, for a client on which the panel cannot be built.
local function chatSummary()
    compute()
    ns.print(professionName() .. ": " .. countsText())
    local shown = 0
    Logic.sortSummary(current, "profit", true)
    for i = 1, #current do
        if current[i].status ~= "profit" or shown == 5 then break end
        shown = shown + 1
        ns.print("  " .. tostring(current[i].name) .. ": " .. resultText(current[i]))
    end
end

function Summary.toggle()
    if not windowOpen() then
        ns.print("open a profession window first - the summary is of the profession you have open")
        return
    end
    if not panel and not cannotBuild then
        local ok, built = pcall(build, window())
        if ok then
            panel = built
            Summary.panel = built
        else
            cannotBuild = true
        end
    end
    if not panel then
        chatSummary()
        return
    end
    panel:SetShown(not panel:IsShown())
    choices().offset = 0
    Summary.refresh()
end

-- The "Profit" button, once, as soon as the game has built its profession window. Safe to call again on
-- a later event: the button, the learned-text label under it, and the Send button beside that label are
-- each built at most once, but independently - if one's pcall failed while an earlier one succeeded, a
-- later call tries only the piece still missing rather than leaving it missing for the rest of the session.
function Summary.attach()
    if cannotBuild or not window() then return end
    if not Summary.button then
        local ok, button = pcall(CreateFrame, "Button", nil, window(), "UIPanelButtonTemplate")
        if not ok then
            ok, button = pcall(textButton, window(), 60, "CENTER", function() end)
            if not ok then return end
        end
        button:SetSize(60, 22)
        button:SetPoint("TOPLEFT", window(), "TOPRIGHT", 2, -28)
        setText(button, "Profit")
        button:SetScript("OnClick", guarded(function() Summary.toggle() end))
        Summary.button = button
    end

    -- M2: "✓ learned 41 recipes, 3 new" (Craft.setLearned below). A child of the button itself, built the
    -- same way and under the same guard, rather than of window() directly - a client that can build the
    -- button can always build this too, and it needs nothing more from the game's own frame.
    if not Summary.learnedText then
        local okLabel, label = pcall(newLabel, Summary.button, "GameFontHighlightSmall", "LEFT")
        if okLabel then
            label:SetPoint("TOPLEFT", Summary.button, "BOTTOMLEFT", 0, -4)
            label:SetWidth(320) -- room for the longest line: "learned 999 recipes, 999 new - press Send to upload"
            Summary.learnedText = label
        end
    end

    -- 0.9.3: the same reload as /tally reload and the strip's own Send (Core.lua ns.reload) - beside the
    -- learned line, the other place a friend is looking right after opening a profession window. Needs the
    -- label to anchor to, so it waits for that, same as the label waits for the button.
    if not Summary.sendButton and Summary.learnedText then
        local okSend, send = pcall(CreateFrame, "Button", nil, window(), "UIPanelButtonTemplate")
        if not okSend then
            okSend, send = pcall(textButton, window(), 50, "CENTER", function() end)
        end
        if okSend then
            send:SetSize(50, 20)
            send:SetPoint("LEFT", Summary.learnedText, "RIGHT", 6, 0)
            setText(send, "Send")
            send:SetScript("OnClick", guarded(function() ns.reload() end))
            withTooltip(send, "Send - reloads the UI")
            Summary.sendButton = send
        end
    end
end

-- Craft.learnRecipes calls this once per profession window read, whether or not it is the first
-- (Summary.attach may not have run yet - Craft.lua loads first in the .toc - so this builds the label
-- itself if needed; both are idempotent). A no-op on a client that could not build it either way.
function Summary.setLearned(total, added)
    Summary.attach()
    if not Summary.learnedText then return end
    local text = string.format("✓ learned %.0f recipes, %.0f new", total, added)
    if ns.pendingUpload then text = text .. " - press Send to upload" end -- 0.9.3
    Summary.learnedText:SetText(text)
end

ns.onChange(Summary.refresh)
ns.on("TRADE_SKILL_SHOW", Summary.attach)
ns.on("TRADE_SKILL_LIST_UPDATE", Summary.attach)
ns.on("ADDON_LOADED", function(name)
    if name == "Blizzard_Professions" then Summary.attach() end
end)

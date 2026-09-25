-- Tallybook: the shopping list (0.12.0) - a panel under the Tallybook bar at the auction house, listing the mats of
-- a batch the member planned on the web (the Workbench drawer's "Send list to the game"). The owner's ruling of
-- 2026-09-25 (Tally 2.0 open decision 3, inside C17): the member's OWN list travels through their own Data.lua, as
-- ns.baked.shopping; Logic.shoppingList reads it, so a damaged one is simply no list.
--
-- Each row: the mat, how many are in the bags (C_Item.GetItemCount, repainted on the game's own bag event), how
-- many are in the bank (0.12.1 - C_Item.GetItemCount(id, true) minus the bags count, read live on every paint,
-- never stored: the owner's probe of 2026-09-25 found includeBank answers correctly even on a session that never
-- opened the bank), how many are still to buy (bags and bank both taken off), the average price the web walked
-- for the batch, and "pay up to" - the price per unit where the whole craft stops paying. A click on a row asks
-- Scan.lua for ONE search in the game's own window (Scan.search): the player's click, one query (C7); the
-- results and the buying stay in Blizzard's window. A vendor's mat is not searched for.
--
-- What this file does NOT do: it sends nothing to the auction house itself (Scan.lua is the one file that does),
-- owns no clock of any kind (the compliance test holds it to that), never repeats or retries a search, and
-- never buys, posts or cancels. It shows itself when the house opens - showing is not asking the house for
-- anything - and the Close button hides it until the next visit; /tally shopping brings it back. Every widget is
-- built under pcall: a client that cannot build it gets no panel, and the list stays readable in /tally shopping.

local _, ns = ...
local Logic = ns.Logic

local Shopping = {}
ns.Shopping = Shopping

local WIDTH, ROW_H = 458, 20
local TOP = 62 -- where the rows start, below the title, the heading and the column headers
-- columns: key, header, left edge, width, alignment
local COLUMNS = {
    { "name", "Mat", 10, 150, "LEFT" },
    { "bags", "Bags", 162, 36, "RIGHT" },
    { "bank", "Bank", 200, 36, "RIGHT" },
    { "buy", "Buy", 238, 36, "RIGHT" },
    { "each", "Avg", 276, 60, "RIGHT" },
    { "payUpTo", "Pay up to", 338, 70, "RIGHT" },
    { "action", "", 410, 44, "RIGHT" },
}
local CAPTION = "Pay up to is the price where the whole craft stops paying. Each Search sends one auction house query; "
    .. "buying stays in Blizzard's window."
local GREEN, RED, CLOSE = "|cff00ff00", "|cffff2020", "|r"

local panel, cannotBuild
-- Closed with its button during THIS visit to the house; the next AUCTION_HOUSE_SHOW shows it again.
local closedThisVisit = false

local function window()
    if type(AuctionHouseFrame) == "table" then return AuctionHouseFrame end
    return nil
end

-- Runs a widget script under pcall: a failure in here must never reach the game's own window.
local function guarded(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then ns.fail("shopping list", err) end
    end
end

local function newLabel(parent, font, justify)
    local text = parent:CreateFontString(nil, "OVERLAY", font)
    text:SetJustifyH(justify or "LEFT")
    return text
end

local function money(copper)
    if copper == nil then return "-" end
    return ns.UI.money(copper)
end

-- The list the data file carried, or nil.
local function currentList()
    return Logic.shoppingList(ns.baked)
end

-- A mat's name: the list's, else the game's own, else its id.
local function nameOf(itemID, name)
    if name then return name, true end
    if type(C_Item) == "table" and type(C_Item.GetItemNameByID) == "function" then
        local ok, known = pcall(C_Item.GetItemNameByID, itemID)
        if ok and not ns.isSecret(known) and type(known) == "string" and known ~= "" then return known, true end
    end
    return "item " .. string.format("%.0f", itemID), false
end

-- { [itemID] = count in the bags } for the list's mats, or nil on a client that cannot count them.
local function bags(list)
    if type(C_Item) ~= "table" or type(C_Item.GetItemCount) ~= "function" then return nil end
    local have = {}
    for i = 1, #list.mats do
        local itemID = list.mats[i].itemID
        local ok, count = pcall(C_Item.GetItemCount, itemID)
        if ok and not ns.isSecret(count) and type(count) == "number" then have[itemID] = count else have[itemID] = 0 end
    end
    return have
end

-- { [itemID] = count in the bank } for the list's mats: C_Item.GetItemCount(id, true) counts bags AND bank, so
-- the bank alone is that minus the plain (bags-only) call - never below 0. Read live on every paint (0.12.1); no
-- snapshot, nothing stored (the owner's ruling of 2026-09-25: alts' banks are a separate, unbuilt feature). A mat
-- whose count cannot be read BOTH ways - no C_Item.GetItemCount at all, or either call answering anything but a
-- plain number - is left out of the table entirely: unknown, never guessed as 0.
local function bank(list)
    if type(C_Item) ~= "table" or type(C_Item.GetItemCount) ~= "function" then return nil end
    local have = {}
    for i = 1, #list.mats do
        local itemID = list.mats[i].itemID
        local okBags, inBags = pcall(C_Item.GetItemCount, itemID)
        local okTotal, total = pcall(C_Item.GetItemCount, itemID, true)
        if okBags and okTotal and not ns.isSecret(inBags) and not ns.isSecret(total)
            and type(inBags) == "number" and type(total) == "number" then
            local diff = total - inBags
            have[itemID] = diff > 0 and diff or 0
        end
    end
    return have
end

---------------------------------------------------------------------------------------------------
-- The panel
---------------------------------------------------------------------------------------------------

local function newRow(p, i)
    local row = CreateFrame("Button", nil, p)
    row:SetSize(WIDTH - 2, ROW_H)
    row:SetPoint("TOPLEFT", p, "TOPLEFT", 1, -(TOP + (i - 1) * ROW_H))
    if i % 2 == 0 then
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
        row[COLUMNS[c][1]] = text
    end
    -- The one thing a click does: one search, through Scan.lua, for this mat - or, for a vendor's mat, nothing but
    -- saying so.
    row:SetScript("OnClick", guarded(function(self)
        local data = self.data
        if not data then return end
        if data.vendor then
            ns.print(data.label .. " is sold by a vendor")
            return
        end
        if not data.named then
            ns.print("no name known for " .. data.label .. " yet - search for it by hand")
            return
        end
        ns.Scan.search(data.label)
    end))
    row:SetScript("OnEnter", guarded(function(self) self.glow:Show() end))
    row:SetScript("OnLeave", guarded(function(self) self.glow:Hide() end))
    return row
end

local function build(parent)
    local p = CreateFrame("Frame", nil, parent)
    p:SetSize(WIDTH, TOP + 10)
    -- Under the Tallybook bar when there is one, outside the house's right edge like the bar: it covers nothing of
    -- the game's own window.
    local strip = ns.Strip and ns.Strip.frame
    if strip then
        p:SetPoint("TOPLEFT", strip, "BOTTOMLEFT", 0, -8)
    else
        p:SetPoint("TOPLEFT", parent, "TOPRIGHT", 2, -28)
    end
    p:SetFrameStrata("HIGH")
    p:EnableMouse(true)
    p.background = p:CreateTexture(nil, "BACKGROUND")
    p.background:SetAllPoints()
    p.background:SetColorTexture(0.035, 0.035, 0.055, 0.96)
    for _, edge in ipairs({ { "TOPLEFT", "TOPRIGHT", nil, 1 }, { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 1 },
        { "TOPLEFT", "BOTTOMLEFT", 1, nil }, { "TOPRIGHT", "BOTTOMRIGHT", 1, nil } }) do
        local line = p:CreateTexture(nil, "BORDER")
        line:SetColorTexture(0.35, 0.35, 0.39, 1)
        line:SetPoint(edge[1], p, edge[1], 0, 0)
        line:SetPoint(edge[2], p, edge[2], 0, 0)
        if edge[3] then line:SetWidth(edge[3]) end
        if edge[4] then line:SetHeight(edge[4]) end
    end

    p.title = newLabel(p, "GameFontNormal")
    p.title:SetPoint("TOPLEFT", p, "TOPLEFT", 10, -8)
    p.title:SetText("Shopping list")
    p.heading = newLabel(p, "GameFontHighlightSmall")
    p.heading:SetPoint("TOPLEFT", p, "TOPLEFT", 10, -24)
    p.heading:SetWidth(WIDTH - 44)

    local ok, close = pcall(CreateFrame, "Button", nil, p, "UIPanelCloseButton")
    if not ok then
        close = CreateFrame("Button", nil, p)
        close.label = newLabel(close, "GameFontNormal", "CENTER")
        close.label:SetAllPoints()
        close.label:SetText("x")
    end
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", p, "TOPRIGHT", -2, -2)
    close:SetScript("OnClick", guarded(function()
        closedThisVisit = true
        p:Hide()
    end))
    p.closeButton = close

    p.headers = {}
    for c = 1, #COLUMNS do
        local header = newLabel(p, "GameFontDisableSmall", COLUMNS[c][5])
        header:SetWidth(COLUMNS[c][4])
        header:SetPoint("TOPLEFT", p, "TOPLEFT", COLUMNS[c][3] + 1, -44)
        header:SetText(COLUMNS[c][2])
        p.headers[COLUMNS[c][1]] = header
    end

    p.rows = {}
    p.cost = newLabel(p, "GameFontHighlightSmall")
    p.profit = newLabel(p, "GameFontHighlightSmall", "RIGHT")
    p.caption = newLabel(p, "GameFontDisableSmall")
    p.caption:SetWidth(WIDTH - 20)
    if type(p.caption.SetWordWrap) == "function" then p.caption:SetWordWrap(true) end
    p.caption:SetText(CAPTION)
    p:Hide()
    return p
end

-- Fills the panel from the list and the bags. Called on every show and on every bag event; asks nothing of the
-- house.
local function paint(list)
    if not panel then return end
    list = list or currentList()
    if not list then
        panel:Hide()
        return
    end
    panel.heading:SetText(Logic.shoppingHeading(list, ns.serverTime()))
    local rows = Logic.shoppingRows(list, bags(list), bank(list))
    for i = 1, #rows do
        local r = rows[i]
        local row = panel.rows[i]
        if not row then
            row = newRow(panel, i)
            panel.rows[i] = row
        end
        local label, named = nameOf(r.itemID, r.name)
        row.data = { label = label, named = named, vendor = r.vendor }
        row.name:SetText(label)
        local have = r.have == nil and "-" or string.format("%.0f", r.have)
        row.bags:SetText(r.enough and (GREEN .. have .. CLOSE) or have)
        row.bank:SetText(r.bank == nil and "—" or string.format("%.0f", r.bank))
        row.buy:SetText(string.format("%.0f", r.buy))
        row.each:SetText(money(r.each))
        row.payUpTo:SetText(money(r.payUpTo))
        row.action:SetText(r.vendor and "vendor" or "Search")
        row:Show()
    end
    for i = #rows + 1, #panel.rows do
        panel.rows[i].data = nil
        panel.rows[i]:Hide()
    end
    local bottom = TOP + #rows * ROW_H
    panel.cost:ClearAllPoints()
    panel.cost:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -(bottom + 8))
    panel.cost:SetText("Buy for about " .. money(list.cost))
    panel.profit:ClearAllPoints()
    panel.profit:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -10, -(bottom + 8))
    local profit = "-"
    if list.profit ~= nil then
        profit = list.profit < 0 and (RED .. "-" .. money(-list.profit) .. CLOSE)
            or (GREEN .. "+" .. money(list.profit) .. CLOSE)
    end
    panel.profit:SetText("Profit at market " .. profit)
    panel.caption:ClearAllPoints()
    panel.caption:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -(bottom + 26))
    panel:SetHeight(bottom + 60)
end

-- Builds the panel once, the first time it is needed, on a client with a window to hang it off.
local function attach()
    if panel or cannotBuild or not window() then return panel end
    local ok, built = pcall(build, window())
    if not ok then
        cannotBuild = true
        return nil
    end
    panel = built
    Shopping.panel = built
    return panel
end

-- Shows the list if there is one. -> true when it is on screen.
local function show()
    local list = currentList()
    if not list or not attach() then return false end
    paint(list)
    panel:Show()
    return true
end

---------------------------------------------------------------------------------------------------
-- /tally shopping
---------------------------------------------------------------------------------------------------

function Shopping.command()
    local list = currentList()
    if not list then
        ns.print("no shopping list yet - plan one on the web (Workbench, Send list to the game), then Sync")
        return
    end
    if not ns.ahOpen then
        ns.print("open the auction house - the shopping list shows there")
        return
    end
    closedThisVisit = false
    if not show() then
        -- No panel on this client: the list in chat instead, one mat a line.
        ns.print(Logic.shoppingHeading(list, ns.serverTime()))
        local rows = Logic.shoppingRows(list, bags(list), bank(list))
        for i = 1, #rows do
            local label = nameOf(rows[i].itemID, rows[i].name)
            ns.print("  " .. string.format("%.0f", rows[i].buy) .. " x " .. label)
        end
    end
end

---------------------------------------------------------------------------------------------------
-- Events: showing and repainting only
---------------------------------------------------------------------------------------------------

-- Loads after Strip.lua, so the bar is built (and the panel can sit under it) by the time this runs.
ns.on("AUCTION_HOUSE_SHOW", function()
    closedThisVisit = false
    show()
end)

ns.on("AUCTION_HOUSE_CLOSED", function()
    if panel then panel:Hide() end
end)

-- The bags changed (a loot, a purchase, the mailbox): the counts follow. The game's own event, not a clock.
local function repaint()
    if panel and panel:IsShown() and not closedThisVisit then paint() end
end
if not ns.on("BAG_UPDATE_DELAYED", repaint) then ns.on("BAG_UPDATE", repaint) end

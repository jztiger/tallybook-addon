-- Tallybook: the player's OWN auction outcomes, read out of the mailbox they opened.
--
-- What this file is for (design spec 2026-09-24, section 4): an auction that sold leaves an invoice in the
-- mail saying what it fetched, what the deposit was and what the auction house kept; one that expired or was
-- cancelled comes back with the item. Those are the only numbers anyone has for what things really sell for,
-- as opposed to what they are listed at, and they are about the player's own auctions.
--
-- Rules this file keeps (docs/decisions.md C7, C11; spec section 6):
--   * The mailbox is read only while the player has it open, and only because they opened it. MAIL_SHOW
--     reads it once; MAIL_INBOX_UPDATE reads it only while it is still open; MAIL_CLOSED ends that. There is
--     no timer in this file, no other event, and nothing at all happens when the mailbox is shut.
--   * GetInboxInvoiceInfo's third return is the OTHER party to the auction - the one field in the whole
--     mailbox that is about somebody else. It is discarded in the destructuring below and never bound to a
--     name, the same discipline Scan.lua applies to the replicate list's four name positions. The compliance
--     test in addon/tests/syntax.test.ts holds it.
--   * Nothing here takes mail, returns it, deletes it or empties it, and nothing here posts, buys or
--     cancels an auction. It reads what is already on screen.
--   * Every client function is feature-detected and called under pcall, and every value that comes back is
--     checked with ns.isSecret before it is used, exactly as Scan.lua and Craft.lua do.
--
-- What is read lands in TallybookDB.sales (Logic.noteSale, which owns the dedup rule); it leaves in the
-- reference document on the next Sync or /tally reload, like everything else.
--
-- 0.11.0 (D15): a Sync button on the mail window while the mailbox is open, with the "press Sync to upload"
-- hint while something is waiting. It is a click, and it calls the same ns.reload as /tally reload and the
-- strip's Sync (Core.lua) - the one place the UI is ever reloaded. Nothing else here is new: no timer, no
-- mail action, and the button does nothing until somebody presses it.

local _, ns = ...
local Logic = ns.Logic

local Mail = {}
ns.Mail = Mail

-- An auction that did not sell comes back with its subject saying so and the item attached. 0.11.0 (D13):
-- the client's own format strings come first (AUCTION_REMOVED_MAIL_SUBJECT, AUCTION_EXPIRED_MAIL_SUBJECT,
-- e.g. "Auction cancelled: %s"), used only when one ends in %s so the part before it is a plain prefix;
-- then the English subjects in both spellings as fallbacks. The owner's UAT (2026-09-24) found Forever
-- writing "Auction canceled: " with ONE L, which the 0.10.0 list did not have, so no cancelled auction was
-- ever captured.
local FALLBACK_PREFIXES = { "Auction expired: ", "Auction cancelled: ", "Auction canceled: " }
-- The invoice type the game gives the OTHER side of a sale - the person who bought it. Everything else is
-- the player's own sale-side invoice. Tested this way round on purpose: the word for the other type is one
-- the compliance test bans from the addon's code, and nothing here needs it.
local BUYER = "buyer"

-- A whole number of seconds; nothing else can key a mail (see Logic.noteSale on the dedup rule).
local function isWholeSecond(v)
    return type(v) == "number" and v == v and v >= 1 and v < 4102444800 and v % 1 == 0
end

-- The prefix a client format string gives, or nil. Compared as text, never as a pattern: in a Lua pattern
-- "%s" means whitespace. A string that is nothing but "%s" would make every mail a return, so it is refused.
local function clientPrefix(format)
    if ns.isSecret(format) or type(format) ~= "string" then return nil end
    if #format < 3 or string.sub(format, -2) ~= "%s" then return nil end
    return string.sub(format, 1, -3)
end

-- The client's prefixes first, then the fallbacks. Read on every walk rather than once at load: the globals
-- are the client's, and reading two of them costs nothing.
local function returnPrefixes()
    local list = {}
    local removed, expired = clientPrefix(AUCTION_REMOVED_MAIL_SUBJECT), clientPrefix(AUCTION_EXPIRED_MAIL_SUBJECT)
    if removed then list[#list + 1] = removed end
    if expired then list[#list + 1] = expired end
    for i = 1, #FALLBACK_PREFIXES do list[#list + 1] = FALLBACK_PREFIXES[i] end
    return list
end

-- The item's name out of "Auction expired: Linen Cloth", or nil when this is not a returned auction.
local function returnedName(subject, prefixes)
    if ns.isSecret(subject) or type(subject) ~= "string" then return nil end
    for i = 1, #prefixes do
        local prefix = prefixes[i]
        if string.sub(subject, 1, #prefix) == prefix then
            local name = string.sub(subject, #prefix + 1)
            if #name >= 1 and #name <= Logic.MAX_NAME_CHARS then return name end
        end
    end
    return nil
end

-- How many mail the inbox holds. 0 on any client that cannot say.
local function inboxCount()
    if type(GetInboxNumItems) ~= "function" then return 0 end
    local ok, n = pcall(GetInboxNumItems)
    if not ok or ns.isSecret(n) or type(n) ~= "number" or n ~= n or n < 1 then return 0 end
    return math.floor(n)
end

-- The subject, and daysLeft exactly as the client gave it (nil when it cannot say one).
--
-- GetInboxHeaderInfo's returns, in the client's order:
--   packageIcon, stationeryIcon, sender, subject, money, CODAmount, daysLeft, itemCount, wasRead,
--   wasReturned, textCreated, canReply, isGM
-- The sender is position 3 and is discarded with the rest: auction mail is recognised by its invoice and by
-- the subject, so there is never a reason to hold a name that, on ordinary mail, is another player's.
-- (The owner's UAT dump of a cancelled auction, 2026-09-24: [3] "Horde Auction House", [4] "Auction
-- canceled: Skinning Knife", [7] 29.999559402466, [8] 1.)
local function header(index)
    if type(GetInboxHeaderInfo) ~= "function" then return nil end
    local ok, _, _, _, subject, _, _, daysLeft = pcall(GetInboxHeaderInfo, index)
    if not ok then return nil end
    if ns.isSecret(subject) or type(subject) ~= "string" then subject = nil end
    if ns.isSecret(daysLeft) or type(daysLeft) ~= "number" or daysLeft ~= daysLeft or daysLeft < 0 then
        return subject, nil
    end
    return subject, daysLeft
end

-- 0.11.0 (D16): the mail's expiry as a unix second rounded DOWN to the minute, one per READING.
--
-- daysLeft is not a live countdown: it is a snapshot from the client's last fetch of the inbox, so reading
-- the same snapshot twice minutes apart gave now + daysLeft two different answers - the owner opened the
-- mailbox twice about 4 minutes apart and every sale became two rows exactly 240 s apart. So the first
-- expiry computed for a reading is kept for the session and reused for an identical one: the same mail
-- (outcome, name, count, price) with the same daysLeft. The last key is the NUMBER, a nested table keyed
-- by it - never tostring, which rounds to 14 digits and would let two different readings share a key. A
-- fresh fetch changes daysLeft, so it is computed anew, and lands on the same minute as long as the
-- countdown is honest (the server's +-60 s match covers a boundary). The open case - a stale snapshot
-- read first and a fresh one later - still lands as far apart as the snapshot was old; see the test
-- marked OPEN in addon/tests/logic.test.ts. Session state only: a reload starts it empty - and since the
-- client keeps its inbox cache across a reload, the same stale snapshot then comes back with the identical
-- daysLeft, which is why each row also carries that raw number (Logic.noteSale): the server folds a
-- re-read of one snapshot by it (fix round 1, src/server/ingest/reference.ts).
local readings = {}

local function expiryFor(outcome, name, count, price, daysLeft, now)
    local node = readings
    local path = { outcome, name, count, price }
    for i = 1, #path do
        local child = node[path[i]]
        if child == nil then
            child = {}
            node[path[i]] = child
        end
        node = child
    end
    local known = node[daysLeft]
    if known ~= nil then return known end
    local expiresAt = math.floor((now + daysLeft * 86400) / 60) * 60
    if not isWholeSecond(expiresAt) then return nil end
    node[daysLeft] = expiresAt
    return expiresAt
end

-- A whole number of at least 1, from a value the client handed back; nil otherwise.
local function positiveWhole(v)
    if ns.isSecret(v) or type(v) ~= "number" or v ~= v or v < 1 or v >= 4294967296 then return nil end
    return math.floor(v)
end

-- The first attachment: its item id and how many of it. GetInboxItem(index, attachment) -> name, itemID,
-- texture, count, quality, canUse.
--
-- 0.11.0 (D13): the owner's UAT dump on Forever (2026-09-24) proved this is the modern shape there -
-- "Skinning Knife", 7005 (the real item id), 135637 (a texture), 1 (the count). So [2] is taken as the
-- item id only when it is a positive whole number AND [3] is a texture FILE id (>= TEXTURE_ID_MIN), else 0
-- as before; the server matches a 0 by name like every other name-only row. The old layout - name,
-- texture, count, quality, ... - also has two positive numbers there, but its [3] is a stack count, never
-- that large, so a texture id is never written down as an item id.
-- The count is 1 when the client cannot say (a mail with nothing on it is still one auction).
local TEXTURE_ID_MIN = 100000
local function attachment(index)
    if type(GetInboxItem) ~= "function" then return 0, 1 end
    local ok, _, itemID, texture, count = pcall(GetInboxItem, index, 1)
    if not ok then return 0, 1 end
    local id = positiveWhole(itemID)
    local textureID = positiveWhole(texture)
    if not id or not textureID or textureID < TEXTURE_ID_MIN then id = 0 end
    return id, positiveWhole(count) or 1
end

-- One mail -> one sale, one return, or nothing at all. -> true when a row was recorded.
--
-- GetInboxInvoiceInfo's returns, from a live /dump on Forever (2026-09-24) with one sold auction in the box:
--   invoiceType, itemName, <the other party>, bid, buyout, deposit, consignment, moneyDelay, etaHour,
--   etaMin, count, itemID
-- On that client [3] came back "" and [12] false - the invoice names no item, so the row travels by name and
-- the server matches it. [4] bid is the amount the player received and [7] consignment is the house's cut.
local function readMail(db, index, now, prefixes)
    local subject, daysLeft = header(index)
    if daysLeft == nil then return false end

    if type(GetInboxInvoiceInfo) == "function" then
        local ok, invoiceType, itemName, _, bid, _, deposit, consignment, _, _, _, count, itemID =
            pcall(GetInboxInvoiceInfo, index)
        if ok and not ns.isSecret(invoiceType) and type(invoiceType) == "string" then
            -- A mail with an invoice is an auction house mail either way; whether it is OURS is the type.
            if invoiceType == BUYER then return false end
            if ns.isSecret(itemName) or type(itemName) ~= "string" then return false end
            if ns.isSecret(bid) or type(bid) ~= "number" or bid ~= bid then return false end
            if ns.isSecret(deposit) or type(deposit) ~= "number" then deposit = 0 end
            if ns.isSecret(consignment) or type(consignment) ~= "number" then consignment = 0 end
            if ns.isSecret(count) or type(count) ~= "number" or count < 1 then count = 1 end
            if ns.isSecret(itemID) or type(itemID) ~= "number" then itemID = 0 end
            count, bid = math.floor(count), math.floor(bid)
            local expiresAt = expiryFor("sold", itemName, count, bid, daysLeft, now)
            if expiresAt == nil then return false end
            return Logic.noteSale(db, math.floor(itemID), itemName, count, bid,
                math.floor(deposit), math.floor(consignment), "sold", expiresAt, daysLeft)
        end
    end

    -- No invoice: an auction that expired or was cancelled, which the subject says and the item proves.
    -- Nothing comes back but the item, so there is no price and the deposit is not returned either.
    local name = returnedName(subject, prefixes)
    if not name then return false end
    local itemID, count = attachment(index)
    local expiresAt = expiryFor("returned", name, count, 0, daysLeft, now)
    if expiresAt == nil then return false end
    return Logic.noteSale(db, itemID, name, count, 0, 0, 0, "returned", expiresAt, daysLeft)
end

-- Walks the open inbox once. Called on MAIL_SHOW, and on each MAIL_INBOX_UPDATE while it is still open -
-- both of which the player caused. A mail already noted is refused by Logic.noteSale's dedup key, so a
-- second walk of the same inbox records nothing and costs one table lookup per mail.
function Mail.readInbox()
    if not ns.mailOpen then return 0 end
    local db = ns.db()
    local now = ns.serverTime()
    local prefixes = returnPrefixes()
    local added = 0
    for index = 1, inboxCount() do
        if readMail(db, index, now, prefixes) then added = added + 1 end
    end
    if added > 0 then
        ns.pendingUpload = true -- something is now waiting on a Sync / /tally reload to go out
        ns.changed()
    end
    return added
end

---------------------------------------------------------------------------------------------------
-- 0.11.0 (D15): Sync on the mail window
---------------------------------------------------------------------------------------------------

-- The game's mail window, or nil on a client that has none.
local function mailWindow()
    if type(MailFrame) == "table" then return MailFrame end
    return nil
end

-- Runs a widget script under pcall: a failure in here must never reach the game's own window.
local function guarded(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then ns.fail("mail", err) end
    end
end

-- The hint beside the button: "press Sync to upload" while something is waiting, nothing otherwise.
local function paint()
    if not Mail.syncHint then return end
    Mail.syncHint:SetText(ns.pendingUpload and "press Sync to upload" or "")
end

-- Built once, the first time the mailbox opens on a client that has a mail window to hang it off - the
-- same game-look-or-plain fallback as the strip's buttons. A client on which it cannot be built is
-- remembered and never tried twice; /tally reload is the way in either way.
local cannotBuild = false
local function build(parent)
    local ok, button = pcall(CreateFrame, "Button", nil, parent, "UIPanelButtonTemplate")
    if not ok then
        button = CreateFrame("Button", nil, parent)
        button.label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        button.label:SetJustifyH("CENTER")
        button.label:SetAllPoints()
    end
    button:SetSize(60, 22)
    -- Outside the window's right edge, like the strip beside the auction house: it covers nothing of the game's.
    button:SetPoint("TOPLEFT", parent, "TOPRIGHT", 2, -28)
    if button.label then button.label:SetText("Sync") else button:SetText("Sync") end
    button:SetScript("OnClick", guarded(function()
        ns.reload()
        paint()
    end))
    local hint = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetJustifyH("LEFT")
    hint:SetPoint("TOPLEFT", button, "BOTTOMLEFT", 0, -4)
    hint:SetWidth(160)
    return button, hint
end

local function attach()
    if Mail.syncButton or cannotBuild or not mailWindow() then return end
    local ok, button, hint = pcall(build, mailWindow())
    if not ok then
        cannotBuild = true
        return
    end
    Mail.syncButton, Mail.syncHint = button, hint
end

ns.mailOpen = false

ns.on("MAIL_SHOW", function()
    ns.mailOpen = true
    Mail.readInbox()
    attach()
    if Mail.syncButton then Mail.syncButton:Show() end
    paint()
end)

-- The inbox refreshes as pages load and as the player takes things out of it. Read again only while the
-- mailbox is still open: after MAIL_CLOSED this event does nothing at all.
ns.on("MAIL_INBOX_UPDATE", function()
    if not ns.mailOpen then return end
    Mail.readInbox()
    paint()
end)

ns.on("MAIL_CLOSED", function()
    ns.mailOpen = false
    if Mail.syncButton then Mail.syncButton:Hide() end
end)

ns.onChange(paint)

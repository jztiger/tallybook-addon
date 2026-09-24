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
-- reference document on the next Send or /tally reload, like everything else.

local _, ns = ...
local Logic = ns.Logic

local Mail = {}
ns.Mail = Mail

-- An auction that did not sell comes back with its subject saying so and the item attached. These are the
-- ENGLISH client's subjects; the addon has only ever run on an English client, and a non-English one simply
-- records no returns until the strings are read from the client's own globals instead.
local RETURN_PREFIXES = { "Auction expired: ", "Auction cancelled: " }
-- The invoice type the game gives the OTHER side of a sale - the person who bought it. Everything else is
-- the player's own sale-side invoice. Tested this way round on purpose: the word for the other type is one
-- the compliance test bans from the addon's code, and nothing here needs it.
local BUYER = "buyer"

-- A whole number of seconds; nothing else can key a mail (see Logic.noteSale on the dedup rule).
local function isWholeSecond(v)
    return type(v) == "number" and v == v and v >= 1 and v < 4102444800 and v % 1 == 0
end

-- The item's name out of "Auction expired: Linen Cloth", or nil when this is not a returned auction.
local function returnedName(subject)
    if ns.isSecret(subject) or type(subject) ~= "string" then return nil end
    for i = 1, #RETURN_PREFIXES do
        local prefix = RETURN_PREFIXES[i]
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

-- The subject, and the mail's own expiry as a unix second rounded DOWN to the minute.
--
-- GetInboxHeaderInfo's returns, in the client's order:
--   packageIcon, stationeryIcon, sender, subject, money, CODAmount, daysLeft, itemCount, wasRead,
--   wasReturned, textCreated, canReply, isGM
-- The sender is position 3 and is discarded with the rest: auction mail is recognised by its invoice and by
-- the subject, so there is never a reason to hold a name that, on ordinary mail, is another player's.
--
-- daysLeft counts down while the mail sits there, but the moment it will vanish does not move: rounding to
-- the minute is what makes the same mail read the same on a second visit, which is what the dedup key
-- needs. A client that cannot say a daysLeft gets nil back and the mail is left alone rather than filed
-- under a guessed expiry.
local function header(index, now)
    if type(GetInboxHeaderInfo) ~= "function" then return nil end
    local ok, _, _, _, subject, _, _, daysLeft = pcall(GetInboxHeaderInfo, index)
    if not ok then return nil end
    if ns.isSecret(subject) or type(subject) ~= "string" then subject = nil end
    if ns.isSecret(daysLeft) or type(daysLeft) ~= "number" or daysLeft ~= daysLeft or daysLeft < 0 then
        return subject, nil
    end
    local expiresAt = math.floor((now + daysLeft * 86400) / 60) * 60
    if not isWholeSecond(expiresAt) then return subject, nil end
    return subject, expiresAt
end

-- How many of the item are attached to this mail; 1 when the client cannot say (a mail with nothing on it
-- is still one auction). GetInboxItem(index, attachment) -> name, itemID, texture, count, quality, canUse.
--
-- ASSUMED, not yet dumped on Forever: position 4 is the count. It is the one position read here, so a
-- client whose signature differs can cost at most a wrong count on a returned auction - never a wrong
-- price and never a wrong item. Position 2 (the item id) is deliberately NOT trusted: on an older
-- signature that slot is a texture id, which is a number and would pass every check this file makes, and
-- a texture id written down as an item id is silent bad data. The returned row therefore carries itemID 0
-- and its name from the subject, which the server matches by name like every other name-only row.
local function attachedCount(index)
    if type(GetInboxItem) ~= "function" then return 1 end
    local ok, _, _, _, count = pcall(GetInboxItem, index, 1)
    if not ok or ns.isSecret(count) or type(count) ~= "number" or count ~= count or count < 1 then return 1 end
    return math.floor(count)
end

-- One mail -> one sale, one return, or nothing at all. -> true when a row was recorded.
--
-- GetInboxInvoiceInfo's returns, from a live /dump on Forever (2026-09-24) with one sold auction in the box:
--   invoiceType, itemName, <the other party>, bid, buyout, deposit, consignment, moneyDelay, etaHour,
--   etaMin, count, itemID
-- On that client [3] came back "" and [12] false - the invoice names no item, so the row travels by name and
-- the server matches it. [4] bid is the amount the player received and [7] consignment is the house's cut.
local function readMail(db, index, now)
    local subject, expiresAt = header(index, now)
    if expiresAt == nil then return false end

    if type(GetInboxInvoiceInfo) == "function" then
        local ok, invoiceType, itemName, _, bid, _, deposit, consignment, _, _, _, count, itemID =
            pcall(GetInboxInvoiceInfo, index)
        if ok and not ns.isSecret(invoiceType) and type(invoiceType) == "string" then
            -- A mail with an invoice is an auction house mail either way; whether it is OURS is the type.
            if invoiceType == BUYER then return false end
            if ns.isSecret(itemName) or type(itemName) ~= "string" then return false end
            if ns.isSecret(bid) or type(bid) ~= "number" then return false end
            if ns.isSecret(deposit) or type(deposit) ~= "number" then deposit = 0 end
            if ns.isSecret(consignment) or type(consignment) ~= "number" then consignment = 0 end
            if ns.isSecret(count) or type(count) ~= "number" or count < 1 then count = 1 end
            if ns.isSecret(itemID) or type(itemID) ~= "number" then itemID = 0 end
            return Logic.noteSale(db, math.floor(itemID), itemName, math.floor(count), math.floor(bid),
                math.floor(deposit), math.floor(consignment), "sold", expiresAt)
        end
    end

    -- No invoice: an auction that expired or was cancelled, which the subject says and the item proves.
    -- Nothing comes back but the item, so there is no price and the deposit is not returned either.
    local name = returnedName(subject)
    if not name then return false end
    return Logic.noteSale(db, 0, name, attachedCount(index), 0, 0, 0, "returned", expiresAt)
end

-- Walks the open inbox once. Called on MAIL_SHOW, and on each MAIL_INBOX_UPDATE while it is still open -
-- both of which the player caused. A mail already noted is refused by Logic.noteSale's dedup key, so a
-- second walk of the same inbox records nothing and costs one table lookup per mail.
function Mail.readInbox()
    if not ns.mailOpen then return 0 end
    local db = ns.db()
    local now = ns.serverTime()
    local added = 0
    for index = 1, inboxCount() do
        if readMail(db, index, now) then added = added + 1 end
    end
    if added > 0 then
        ns.pendingUpload = true -- something is now waiting on a Send / /tally reload to go out
        ns.changed()
    end
    return added
end

ns.mailOpen = false

ns.on("MAIL_SHOW", function()
    ns.mailOpen = true
    Mail.readInbox()
end)

-- The inbox refreshes as pages load and as the player takes things out of it. Read again only while the
-- mailbox is still open: after MAIL_CLOSED this event does nothing at all.
ns.on("MAIL_INBOX_UPDATE", function()
    if not ns.mailOpen then return end
    Mail.readInbox()
end)

ns.on("MAIL_CLOSED", function()
    ns.mailOpen = false
end)

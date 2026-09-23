-- Tallybook: the auction house strip - Scan / Browse / Stop, an auto-scan switch and one status line
-- beside the game's auction house window - and the one browse scan that may start itself when the house
-- opens (docs/decisions.md C7, revised by the owner 2026-09-23).
--
-- Display, and one decision that is not taken here: whether that scan may run is Logic.autoScanDecision,
-- which is pure and tested on its own. This file gathers the six fields it takes and obeys what it says.
-- The six limits C7 keeps, and the line here that keeps each:
--   1. The TRIGGER is AUCTION_HOUSE_SHOW and nothing else: the handler at the foot of this file is the
--      only caller of startAutoScan(), and there is no timer, no repeat and no retry anywhere in it.
--      Note what this does NOT claim: a browse scan is paged, so pages 2..N of a scan that HAS started
--      are asked for on later events (Scan.lua's browseMore, from the results and throttle handlers),
--      exactly as they are for a /tally browse. That is the browse scan limit 4 names, and it is bounded
--      by that one scan's own paging - it starts nothing new.
--   2. One scan per opening: opening.scanned, set before the scan is asked for and cleared by
--      AUCTION_HOUSE_CLOSED (see the one exception at startAutoScan, which is a refusal, not a retry).
--   3. Nothing while the newest known scan - this session's own, or the pooled one the data file carries
--      back into the game - is younger than Logic.AUTO_SCAN_MIN_AGE: newestScanAt() feeds the decision.
--   4. The browse scan only: startAutoScan() calls ns.Scan.browse() and nothing else. The full scan stays
--      behind its own button and /tally scan. The whole footprint of this scan is that ONE browse query
--      and its pages: it is marked `auto`, and Scan.lua's finishBrowse keeps the variant learner - up to
--      eight item searches - for the scans somebody pressed a button for.
--   5. Visible: paint() writes "scanning ..." and shows the Stop button for as long as a scan runs.
--   6. A query the client REFUSES is never taken up again - not on the throttle's own event, not on a
--      second AUCTION_HOUSE_SHOW, not ever until the house has been closed and opened again. A /tally
--      browse may wait for the throttle to clear, because a player asked for it; a scan of the strip's
--      may not. Two things make that so, and the second is what enforces it: the throttle pre-check in
--      startAutoScan() means no such run is normally created, and any run whose query did not go out is
--      ENDED there (ns.Scan.stop) rather than left for the throttle handler to pick up. opening.refused
--      is recorded either way, and the decision then answers "skip-cooldown".
-- The switch is ns.settings().autoScan, remembered by ns.setSetting like every other choice.
--
-- Nothing here posts, bids, buys or cancels, and nothing here asks the auction house for anything: the
-- buttons call ns.Scan, which is the one file that sends a request. Every widget is built under pcall,
-- and a client that has no auction house window gets no strip and no scan of its own accord - the
-- commands still work, and nothing the player cannot see ever starts.

local _, ns = ...
local Logic = ns.Logic

local Strip = {}
ns.Strip = Strip

local BUTTON_W, BUTTON_H = 60, 22
local WIDTH, HEIGHT = 190, 76

-- What is true of THIS opening of the auction house. Either one is enough to stop a second scan, and only
-- AUCTION_HOUSE_CLOSED clears them - with one exception, inside startAutoScan: a scan that was asked for
-- but whose query did not go out puts `scanned` back down and `refused` up in the same breath, so what the
-- player is told is "the house is busy" rather than "already done". The opening is no less closed to a
-- second scan for it: decide() weighs `refused` right after `scanned`, and both answer skip.
local opening = { scanned = false, refused = false }

local strip, cannotBuild

-- The game's auction house window, or nil on a client that has none.
local function window()
    if type(AuctionHouseFrame) == "table" then return AuctionHouseFrame end
    return nil
end

-- Runs a widget script under pcall: a failure in here must never reach the game's own window.
local function guarded(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then ns.fail("strip", err) end
    end
end

local function setText(widget, text)
    if widget.label then widget.label:SetText(text) else widget:SetText(text) end
end

local function newLabel(parent, font, justify)
    local text = parent:CreateFontString(nil, "OVERLAY", font)
    text:SetJustifyH(justify or "LEFT")
    return text
end

-- A button with the game's own look where the client has the template, and a plain one carrying its own
-- text where it has not - the same fallback the Profit button uses, so no template is ever required.
local function newButton(parent, width, text, onClick)
    local ok, button = pcall(CreateFrame, "Button", nil, parent, "UIPanelButtonTemplate")
    if not ok then
        ok, button = pcall(CreateFrame, "Button", nil, parent)
        if not ok then return nil end
        button.label = newLabel(button, "GameFontNormalSmall", "CENTER")
        button.label:SetAllPoints()
    end
    button:SetSize(width, BUTTON_H)
    button:SetScript("OnClick", guarded(onClick))
    setText(button, text)
    return button
end

---------------------------------------------------------------------------------------------------
-- The decision (C7 as revised): gathered here, taken in Logic.autoScanDecision, obeyed below
---------------------------------------------------------------------------------------------------

-- The switch, as the player last left it: saved beats baked beats the default (which is on).
local function autoScanOn()
    return ns.settings().autoScan ~= false
end

-- Limit 3: the newest scan anybody knows of - this session's own (Scan.status) or the time of the prices
-- baked into the data file, whichever is later. 0 when neither is known, which reads as "old enough".
local function newestScanAt(status)
    local own = status.lastScanAt
    if type(own) ~= "number" or own ~= own or own < 0 then own = 0 end
    local pooled = type(ns.baked) == "table" and ns.baked.pricesAt or 0
    if type(pooled) ~= "number" or pooled ~= pooled or pooled < 0 then pooled = 0 end
    if own > pooled then return own end
    return pooled
end

local function decide(status)
    return Logic.autoScanDecision({
        enabled = autoScanOn(),
        ahOpen = ns.ahOpen and true or false,
        scannedThisOpening = opening.scanned,
        newestScanAt = newestScanAt(status),
        now = ns.serverTime(),
        cooldownRefused = opening.refused,
    })
end

---------------------------------------------------------------------------------------------------
-- The strip
---------------------------------------------------------------------------------------------------

-- Limit 5: one line that always says what is happening. A scan in progress wins over everything else;
-- otherwise the player is told why no scan started, or how old the prices they are looking at are.
local function statusText(status)
    if status.busy then
        if status.kind == "browse" and type(status.pages) == "number" and status.pages > 0 then
            return string.format("scanning ... page %.0f", status.pages)
        end
        return "scanning ..."
    end
    local reason = decide(status)
    if reason == "skip-off" then return "auto-scan is off" end
    if reason == "skip-cooldown" then return "the house is busy - try the button in a moment" end
    local newest = newestScanAt(status)
    if newest <= 0 then return "no prices yet - press Browse" end
    return "last scan " .. Logic.formatAge(ns.serverTime() - newest) .. " ago"
end

local function paint()
    if not strip then return end
    local status = ns.Scan.status()
    local on = autoScanOn()
    if strip.autoIsCheckBox then
        strip.autoBox:SetChecked(on)
    else
        setText(strip.autoBox, (on and "[x]" or "[ ]") .. " auto-scan")
    end
    strip.stopButton:SetShown(status.busy)
    strip.status:SetText(statusText(status))
end

-- Starts nothing by itself: it writes the choice down and repaints, and the next opening of the house
-- reads it (limit 1 - a click on the switch is not an AUCTION_HOUSE_SHOW).
local function toggleAuto()
    ns.setSetting("autoScan", not autoScanOn())
    paint()
end

local function build(parent)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(WIDTH, HEIGHT)
    -- Outside the window's right edge, like the Profit panel: it covers nothing of the game's own.
    frame:SetPoint("TOPLEFT", parent, "TOPRIGHT", 2, -28)

    frame.scanButton = newButton(frame, BUTTON_W, "Scan", function()
        ns.Scan.replicate()
        paint()
    end)
    frame.browseButton = newButton(frame, BUTTON_W, "Browse", function()
        ns.Scan.browse()
        paint()
    end)
    frame.stopButton = newButton(frame, BUTTON_W, "Stop", function()
        ns.Scan.stop()
        paint()
    end)
    if not (frame.scanButton and frame.browseButton and frame.stopButton) then
        error("this client could not build a button")
    end
    frame.scanButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    frame.browseButton:SetPoint("TOPLEFT", frame.scanButton, "TOPRIGHT", 2, 0)
    frame.stopButton:SetPoint("TOPLEFT", frame.browseButton, "TOPRIGHT", 2, 0)

    -- The switch. A real tick box where the client has the template, else a button reading "[x] auto-scan";
    -- which one it is is remembered rather than guessed from the widget, because only one has a tick.
    local ok, box = pcall(CreateFrame, "CheckButton", nil, frame, "UICheckButtonTemplate")
    frame.autoIsCheckBox = ok
    if ok then
        box:SetSize(24, 24)
        box:SetScript("OnClick", guarded(toggleAuto))
        frame.autoLabel = newLabel(frame, "GameFontHighlightSmall", "LEFT")
        frame.autoLabel:SetText("auto-scan")
        frame.autoLabel:SetPoint("LEFT", box, "RIGHT", 2, 0)
    else
        box = newButton(frame, 110, "[x] auto-scan", toggleAuto)
        if not box then error("this client could not build the auto-scan switch") end
    end
    box:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -BUTTON_H - 4)
    frame.autoBox = box

    frame.status = newLabel(frame, "GameFontHighlightSmall", "LEFT")
    frame.status:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -BUTTON_H - 32)
    frame.status:SetWidth(WIDTH)
    return frame
end

-- Built once, the first time the auction house is opened on a client that has a window to hang it off.
-- Safe to call again: a client on which it cannot be built is remembered and never tried twice, and the
-- /tally commands are the way in either way.
function Strip.attach()
    if strip or cannotBuild or not window() then return end
    local ok, built = pcall(build, window())
    if not ok then
        cannotBuild = true
        return
    end
    strip = built
    Strip.frame = built
    Strip.scanButton = built.scanButton
    Strip.browseButton = built.browseButton
    Strip.stopButton = built.stopButton
    Strip.autoBox = built.autoBox
    Strip.status = built.status
end

---------------------------------------------------------------------------------------------------
-- The one scan that starts itself
---------------------------------------------------------------------------------------------------

-- Starts the one scan C7 allows without a click - not to be read as autoScanOn(), which is only the
-- switch this consults. Called from the AUCTION_HOUSE_SHOW handler below and from nowhere else. It asks
-- once, it never waits and it never repeats: whatever comes of this one attempt stands until the house is
-- closed and opened again. A strip that could not be built means no auto-scan at all - nothing the player
-- cannot see and cannot stop may start on its own.
local function startAutoScan()
    local status = ns.Scan.status()
    if decide(status) ~= "scan" then return end
    -- Limit 6: the auction house's own throttle is the cooldown. The Browse button may wait for it to
    -- clear; this may not, because the query would then go out on the throttle's own event rather than
    -- on the opening of the house (limit 1). A shut throttle is a refusal, recorded and not retried.
    if not ns.Scan.throttleReady() then
        opening.refused = true
        return
    end
    opening.scanned = true -- limit 2: written before the scan is asked for, so nothing can ask twice
    -- Limit 4: the browse scan, through the very function the Browse button and /tally browse call, so
    -- it passes the same checks they do. It answers false when the query did not go out, and then this
    -- opening has had its one attempt refused rather than taken.
    -- Anything running after this call that was not running before it can only be the run this call made:
    -- that, and only that, is what the stop below is allowed to end.
    local wasBusy = ns.Scan.busy()
    if ns.Scan.browse({ auto = true }) ~= true then
        -- false covers three cases: nothing was started; a run IS live but the client would not take its
        -- query; and the scan was refused because something else is already running. The second is the
        -- dangerous one - a live unsent browse run is precisely what AUCTION_HOUSE_THROTTLED_SYSTEM_READY
        -- picks up and sends - so it is ended here rather than left queued. The third must NOT be stopped:
        -- a full scan reading its list outlives the house closing, so an opening can find one still going,
        -- and it is the player's.
        if not wasBusy then ns.Scan.stop() end
        opening.scanned = false
        opening.refused = true
    end
end

ns.on("AUCTION_HOUSE_SHOW", function()
    Strip.attach()
    if not strip then return end
    startAutoScan()
    paint()
end)

ns.on("AUCTION_HOUSE_CLOSED", function()
    opening.scanned = false
    opening.refused = false
    paint()
end)

-- Repaints, and nothing else. Every one of these runs after Scan.lua's own handler for the same event, so
-- what they show is the scan as it stands; none of them decides anything and none of them starts anything.
ns.on("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", paint)
ns.on("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", paint)
ns.on("AUCTION_HOUSE_BROWSE_FAILURE", paint)
ns.on("REPLICATE_ITEM_LIST_UPDATE", paint)
ns.onChange(paint)

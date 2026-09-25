-- Tallybook: namespace, events, saved state and the /tally slash command.
--
-- Rules this file keeps (docs/decisions.md C7, C11):
--   * Nothing here starts a scan or a reload by itself. Events only keep state up to date; every
--     scan and the reload start from a typed /tally command.
--   * The one UI reload in the whole addon is inside the "/tally reload" handler below.
--   * Saved state may be missing at load - it does not survive a full client restart on this
--     client - so an absent or damaged TallybookDB is normal and is rebuilt without complaint.

local ADDON, ns = ...
local Logic = ns.Logic

local PREFIX = "|cff33ff99Tallybook|r "

function ns.print(msg)
    print(PREFIX .. tostring(msg))
end

-- Midnight-era clients can hand addons "secret values" that must not be compared or stored.
function ns.isSecret(v)
    return type(issecretvalue) == "function" and issecretvalue(v) == true
end

function ns.serverTime()
    if type(GetServerTime) == "function" then
        local ok, t = pcall(GetServerTime)
        if ok and type(t) == "number" then return t end
    end
    return time()
end

-- Milliseconds, for measuring. Not a wall clock.
function ns.clockMs()
    if type(debugprofilestop) == "function" then return debugprofilestop() end
    return GetTime() * 1000
end

---------------------------------------------------------------------------------------------------
-- Errors: every handler and timer body runs under pcall. A failure ends whatever scan was running,
-- so the addon is never left "busy", and is reported once (not once per event) until the player
-- types the next command.
---------------------------------------------------------------------------------------------------

local reported = {}

function ns.fail(where, err)
    local text = tostring(where) .. ": " .. tostring(err)
    if ns.Scan and ns.Scan.reset then ns.Scan.reset() end
    if reported[text] then return end
    reported[text] = true
    ns.print("error in " .. text)
end

-- One-shot timer whose body runs under pcall. (There are no repeating timers in this addon.)
function ns.after(seconds, fn)
    C_Timer.After(seconds, function()
        local ok, err = pcall(fn)
        if not ok then ns.fail("timer", err) end
    end)
end

---------------------------------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
ns.frame = frame
ns.unknownEvents = {}

local handlers = {} -- event -> array of functions, called in the order they were added

-- RegisterEvent throws on event names the client does not know (and returns false on others),
-- so it is called under pcall and an unknown event just never fires.
function ns.on(event, fn)
    local list = handlers[event]
    if not list then
        local ok, registered = pcall(frame.RegisterEvent, frame, event)
        if not ok or registered == false then
            ns.unknownEvents[event] = true
            return false
        end
        list = {}
        handlers[event] = list
    end
    list[#list + 1] = fn
    return true
end

frame:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if not list then return end
    for i = 1, #list do
        local ok, err = pcall(list[i], ...)
        if not ok then ns.fail(event, err) end
    end
end)

---------------------------------------------------------------------------------------------------
-- "Something was learned or scanned": whatever is on screen re-prices itself (List.lua, Summary.lua)
---------------------------------------------------------------------------------------------------

local listeners = {}

function ns.onChange(fn)
    listeners[#listeners + 1] = fn
end

function ns.changed()
    for i = 1, #listeners do pcall(listeners[i]) end
end

---------------------------------------------------------------------------------------------------
-- Saved state
---------------------------------------------------------------------------------------------------

-- The saved table, brought to the spec layout if it is missing or damaged.
function ns.db()
    local db = TallybookDB
    if type(db) ~= "table" or db.v ~= 1 or type(db.state) ~= "table" or type(db.prices) ~= "table"
        or type(db.chunks) ~= "table" then
        db = Logic.initDB(db)
        TallybookDB = db
    end
    return db
end

-- Everything the client is about to write: the sealed ring, and the reference string built fresh. The ring
-- comes first and the string is built under pcall: whatever happens to it, the scans are complete on disk.
function ns.beforeWrite()
    ns.sealRing()
    if ns.Export and ns.Export.saveRef then pcall(ns.Export.saveRef) end
end

-- What the player has chosen (Logic.settings): saved beats what was baked at the last install beats the default.
function ns.settings()
    return Logic.settings(ns.db().settings, type(ns.baked) == "table" and ns.baked.settings or nil)
end

function ns.setSetting(key, value)
    ns.db().settings[key] = value
end

-- The ring always ends with the "end:<n>" sentinel - after load, after every save and at logout -
-- so the file is complete whenever the client writes it, whichever of those moments it honours.
function ns.sealRing()
    Logic.appendSentinel(ns.db().chunks)
end

ns.on("ADDON_LOADED", function(name)
    if name ~= (ADDON or "Tallybook") then return end
    TallybookDB = Logic.initDB(TallybookDB)
    Logic.stripSentinel(TallybookDB.chunks)
    ns.sealRing()
    -- Data.lua: vendor prices and recipes from earlier sessions, brought back as code (see Logic.applyBaked)
    -- ... and, when the session has nothing newer, the auction prices that came with it (newest wins)
    Logic.applyBaked(TallybookDB, ns.baked, ns.serverTime())
end)

ns.on("PLAYER_LOGOUT", function()
    ns.beforeWrite()
end)

ns.ahOpen = false
ns.on("AUCTION_HOUSE_SHOW", function() ns.ahOpen = true end)
ns.on("AUCTION_HOUSE_CLOSED", function() ns.ahOpen = false end)

-- 0.9.3: something this session has not gone into the saved file yet - a scan (Scan.lua's finishReplicate /
-- finishBrowse / selftest) or a newly learned recipe (Craft.lua's learnRecipes, when it adds one). Read by
-- Strip.lua, Summary.lua and Mail.lua to nudge "press Sync to upload"; cleared by ns.reload below, before the reload
-- that is the only thing that ever writes it out. Not saved: like everything else session-only, it starts
-- false every time the client loads.
ns.pendingUpload = false

---------------------------------------------------------------------------------------------------
-- What labels a scan
---------------------------------------------------------------------------------------------------

-- -> { region, realm, faction, build, interface, addon, copper }
function ns.meta()
    local meta = { addon = Logic.VERSION }
    if type(GetBuildInfo) == "function" then
        local version, build, _, interface = GetBuildInfo()
        if version ~= nil and build ~= nil then meta.build = tostring(version) .. "." .. tostring(build) end
        meta.interface = interface
    end
    if type(GetCurrentRegion) == "function" then meta.region = GetCurrentRegion() end
    if type(GetRealmName) == "function" then meta.realm = GetRealmName() end
    if type(UnitFactionGroup) == "function" then meta.faction = (UnitFactionGroup("player")) end
    -- copper: true / false, or left out when the client has no such function
    if type(C_AuctionHouse) == "table" and type(C_AuctionHouse.SupportsCopperValues) == "function" then
        local ok, value = pcall(C_AuctionHouse.SupportsCopperValues)
        if ok and type(value) == "boolean" then meta.copper = value end
    end
    return meta
end

---------------------------------------------------------------------------------------------------
-- /tally
---------------------------------------------------------------------------------------------------

local commands = {}

function commands.status()
    ns.UI.status()
end

function commands.scan()
    ns.Scan.replicate()
end

function commands.browse()
    ns.Scan.browse()
end

function commands.selftest()
    ns.Scan.selftest()
end

function commands.profit()
    ns.Summary.toggle()
end

-- /tally basket 20            the recipe last clicked in the Profit panel
-- /tally basket 20 [item]     or the one that makes a shift-clicked item
function commands.basket(arg, msg)
    local crafts = tonumber(arg)
    if not crafts or crafts < 1 or crafts > Logic.BASKET_MAX_CRAFTS or crafts % 1 ~= 0 then
        ns.print("/tally basket <how many crafts, 1-" .. string.format("%.0f", Logic.BASKET_MAX_CRAFTS) .. "> [shift-click an item]")
        return
    end
    local chosen = ns.Summary.chosen
    local linked = type(msg) == "string" and tonumber(string.match(msg, "item:(%d+)")) or nil
    if linked then
        local db = ns.db()
        local recipeID = Logic.cheapestRecipe(db.recipes[linked], db.prices, db.vendor)
        chosen = recipeID and { recipeID = recipeID, itemID = linked } or nil
    end
    ns.Craft.basket(crafts, chosen)
end

-- /tally shopping : the shopping list planned on the web (0.12.0) - shown at the auction house (Shopping.lua)
function commands.shopping()
    ns.Shopping.command()
end

-- /tally list profit | cost : what the number next to each recipe in the profession window is
function commands.list(arg)
    if arg == "profit" or arg == "cost" then
        ns.setSetting("list", arg)
        ns.changed()
    end
    ns.print("recipe list shows: " .. ns.settings().list .. "   (/tally list profit | /tally list cost)")
end

-- The only place in the addon that reloads the UI, and only because the player asked - by typing
-- /tally reload, or by clicking a Sync button (Strip.lua, Summary.lua, Mail.lua): both call this SAME function
-- (commands.reload below is a plain alias, not a second body), so there is still exactly one ReloadUI()
-- call site in the whole addon, wherever it was asked for from (0.9.3).
function ns.reload()
    if ns.Scan.busy() then
        ns.print("a scan is still running. Wait for it to finish, or type /reload yourself to abandon it.")
        return
    end
    if type(ReloadUI) ~= "function" then
        ns.print("this client has no reload function. Type /reload instead.")
        return
    end
    ns.pendingUpload = false -- before beforeWrite/ReloadUI, not after: ReloadUI need not ever return
    ns.beforeWrite()
    ReloadUI()
end
commands.reload = ns.reload

SLASH_TALLYBOOK1 = "/tally"
SLASH_TALLYBOOK2 = "/tallybook"
SlashCmdList["TALLYBOOK"] = function(msg)
    local word, arg = "", ""
    if type(msg) == "string" then
        word, arg = string.match(string.lower(msg), "^%s*(%S*)%s*(%S*)")
        word, arg = word or "", arg or ""
    end
    if word == "" then word = "status" end
    reported = {}
    local command = commands[word]
    if not command then
        ns.print("open the auction house - it scans; buttons for Quick scan / Full scan / Stop / Sync are on the frame.")
        ns.print("commands: /tally (status) | scan | browse | profit | basket | shopping | list | selftest | reload")
        return
    end
    local ok, err = pcall(command, arg, msg)
    if not ok then ns.fail("/tally " .. word, err) end
end

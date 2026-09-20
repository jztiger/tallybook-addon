-- Tallybook: scan document -> JSON -> base64 -> one tagged chunk in the saved ring.
--
-- The server never runs Lua: it lifts the "j1:..." strings out of the SavedVariables file with a
-- regular expression. So what is stored must be exactly base64 text; anything else is refused
-- here rather than saved, because one unreadable chunk would get the whole file refused.
--
-- Nothing is on disk until the client writes SavedVariables (a UI reload or a logout), and on
-- this client saved state does not survive a full restart - hence the reminder after every save.

local _, ns = ...
local Logic = ns.Logic

local Export = {}
ns.Export = Export

-- The scans saved in THIS session. None of them is on disk until the next reload or logout, and
-- on this client the ring holds nothing else, so pushing one out of the ring destroys the only
-- copy. (A scan that came back from disk at load is not in here: losing it from the ring is fine.)
local unsaved = {}

-- -> true   or   false, why. There is no fallback encoder in v1.
function Export.available()
    local E = C_EncodingUtil
    if type(E) ~= "table" or type(E.SerializeJSON) ~= "function" or type(E.EncodeBase64) ~= "function" then
        return false, "this client has no C_EncodingUtil.SerializeJSON / EncodeBase64, so scans cannot be saved"
    end
    return true
end

-- -> true, stats   or   false
function Export.save(doc)
    local ok, why = Export.available()
    if not ok then
        ns.print(why)
        return false
    end
    local E = C_EncodingUtil

    -- Never save what the server is known to refuse: it would read "saved" here and "invalid" there.
    local rowCount = type(doc.rows) == "table" and #doc.rows or 0
    if rowCount > Logic.MAX_ROWS then
        ns.print(string.format("not saved: %.0f rows, and the server accepts at most %.0f per scan."
            .. " The market has outgrown this version of Tallybook; /tally browse still works.",
            rowCount, Logic.MAX_ROWS))
        return false
    end

    local t0 = ns.clockMs()
    local okJson, json = pcall(E.SerializeJSON, doc)
    local t1 = ns.clockMs()
    if not okJson or type(json) ~= "string" or json == "" then
        ns.print("not saved: SerializeJSON failed (" .. tostring(json) .. ")")
        return false
    end
    local okB64, b64 = pcall(E.EncodeBase64, json)
    local t2 = ns.clockMs()
    if not okB64 or type(b64) ~= "string" or b64 == "" then
        ns.print("not saved: EncodeBase64 failed (" .. tostring(b64) .. ")")
        return false
    end
    -- Some encoders wrap their output in lines; the server's pattern allows no white space.
    if string.find(b64, "%s") then b64 = string.gsub(b64, "%s+", "") end
    if string.find(b64, "[^A-Za-z0-9+/=]") then
        ns.print("not saved: EncodeBase64 returned something that is not plain base64")
        return false
    end

    local db = ns.db()
    local chunk = Logic.chunkTag(doc.uid, 1, 1, b64)
    if Logic.uidOf(chunk) == nil then
        ns.print("not saved: the scan has no valid id")
        return false
    end
    if #chunk > Logic.RING_MAX_BYTES then
        -- ringPush would keep it and push out every other scan still waiting to be written.
        ns.print(string.format("not saved: this scan is %.1f MB and everything held in memory may be %.0f MB."
            .. " The scans already held were kept.", #chunk / 1048576, Logic.RING_MAX_BYTES / 1048576))
        return false
    end
    local _, evicted = Logic.ringPush(db.chunks, { chunk }, Logic.RING_MAX_SCANS, Logic.RING_MAX_BYTES)
    ns.sealRing()

    local lost, oldest = 0, nil
    for i = 1, #evicted do
        if unsaved[evicted[i]] then
            unsaved[evicted[i]] = nil
            lost = lost + 1
            local at = Logic.uidTime(evicted[i])
            if at and (not oldest or at < oldest) then oldest = at end
        end
    end
    unsaved[doc.uid] = true

    local stats = {
        rows = rowCount,
        bytes = #chunk,
        jsonBytes = #json,
        jsonMs = t1 - t0,
        base64Ms = t2 - t1,
    }
    ns.print(string.format("saved %s scan: %.0f rows, %.1f KB, json %.0f ms, base64 %.0f ms — /tally reload to write it to disk",
        tostring(doc.kind), stats.rows, stats.bytes / 1024, stats.jsonMs, stats.base64Ms))
    if lost > 0 then
        ns.print(string.format("no room left: dropped %.0f %s that had never been written to disk%s."
            .. " /tally reload before scanning again.", lost, lost == 1 and "scan" or "scans",
            oldest and (", from " .. Logic.formatAge(ns.serverTime() - oldest) .. " ago") or ""))
    else
        -- Worth a word only while the scan next in line to be pushed out exists nowhere but here.
        local scans, bytes = Logic.ringStats(db.chunks)
        local nearlyFull = scans >= Logic.RING_MAX_SCANS - 2 or bytes > 0.75 * Logic.RING_MAX_BYTES
        if nearlyFull and unsaved[Logic.uidOf(db.chunks[1]) or ""] then
            ns.print(string.format("nearly full: %.0f of %.0f scans, %.1f of %.0f MB held in memory. /tally reload now"
                .. " to write them to disk - once it is full, each new scan pushes out the oldest one.",
                scans, Logic.RING_MAX_SCANS, bytes / 1048576, Logic.RING_MAX_BYTES / 1048576))
        end
    end
    return true, stats
end

-- What the addon has learned that never changes (vendor prices, recipes) -> TallybookDB.ref, one
-- "r1:<base64 JSON>" string, rebuilt from scratch each time. Called when the client is about to write the
-- saved file (logout, /tally reload), so it says nothing: there is nobody left to read it. The bake step
-- (src/shared/ref-doc.ts, bake.ts) turns these strings into Data.lua. -> true when a string was stored
function Export.saveRef()
    local db = ns.db()
    db.ref = nil
    if not Export.available() then return false end
    local doc = Logic.refDoc(db, ns.serverTime())
    if not doc then return false end
    local E = C_EncodingUtil
    local okJson, json = pcall(E.SerializeJSON, doc)
    if not okJson or type(json) ~= "string" or json == "" then return false end
    local okB64, b64 = pcall(E.EncodeBase64, json)
    if not okB64 or type(b64) ~= "string" then return false end
    if string.find(b64, "%s") then b64 = string.gsub(b64, "%s+", "") end
    local tagged = Logic.refTag(b64)
    if Logic.refOf(tagged) == nil or #tagged > Logic.REF_MAX_BYTES then return false end
    db.ref = tagged
    return true
end

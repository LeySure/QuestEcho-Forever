-- =============================================================================
-- QuestEcho112.lua
-- Compatibility layer for pre-WotLK 1.12/1.18 clients (Turtle WoW, Everlook,
-- and other 1.12-based servers). Loaded BEFORE Core.lua from QuestEcho.toc.
--
-- This client embeds a *vanilla Lua 5.0*:
--   * `...` exists ONLY as the last item of a parameter list. There is no `...`
--     expression at all, so f(...) and local a = ... are syntax errors.
--     Arguments of a vararg function arrive in the implicit global `arg` table.
--   * there is no `select()` function (it is Lua 5.1), so even arg counts must
--     come from #arg.
--   * no `%` modulo operator      -> math.mod(a, b)
--   * no `#` length operator      -> #t
--   * no `^` power operator       -> math.pow(a, b)
--   * no hexadecimal literals     -> decimal
--   * no string.gmatch/string.match -> string.gfind / string.find
--   * string.find(s, pat) returns only the END index when there are no captures
--   * no bit library, no C_* namespaces, no hooksecurefunc, no SetShown, no
--     StopSound, no MuteSoundFile, no GetCVarBool, no UnitGUID, no strsplit
--
-- Everything is feature-detected, so modern clients still work unchanged.
-- =============================================================================

local ADDON_VERSION = "1.9.0"

-- Everything this file needs from the standard library, captured up front
-- because Core.lua expects the shims to exist before it runs.
local type, tostring, tonumber, pcall = type, tostring, tonumber, pcall
local tgetn, tinsert = table.getn, table.insert
local floor, mod, pow = math.floor, math.mod, math.pow
local sfind, sgsub, slower = string.find, string.gsub, string.lower
local sformat, srep, sbyte, schar = string.format, string.rep, string.byte, string.char
local ssub, slen = string.sub, string.len

-- =============================================================================
-- Argument helpers. Lua 5.0 has no `...` expression and no select(), so a
-- vararg function receives its extra arguments in the implicit `arg` table.
--
-- The caller passes that table in EXPLICITLY (Capture(arg)) rather than letting
-- Capture read a global, because whether `arg` is a fresh local per call or a
-- single global differs between Lua 5.0 builds; passing it avoids the question
-- and keeps nested vararg calls from clobbering each other.
--
--   Capture(arg)      -> table of the extra arguments
--   Spread(f, t)      -> call f with t[1], t[2], ... unrolled, up to 10 values
-- =============================================================================
QuestEcho112 = QuestEcho112 or {}
local Compat = QuestEcho112

function Compat.Capture(source)
    local out = {}
    if type(source) == "table" then
        local i = 1
        while source[i] ~= nil do
            out[i] = source[i]
            i = i + 1
        end
        out.count = tgetn(source)
    else
        out.count = 0
    end
    return out
end
function Compat.Spread(fn, values)
    if type(fn) ~= "function" then return end
    local t = values or {}
    return fn(t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8], t[9], t[10])
end

-- Call a frame script function with the values captured from an event.
function Compat.SpreadScript(handler, frame, values)
    if type(handler) ~= "function" then return end
    local t = values or {}
    return handler(frame, t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8])
end

-- =============================================================================
-- Client detection. GetBuildInfo's 4th value is the interface number (11200 on
-- 1.12/1.18). Grab it without select(); fall back to probing the Lua dialect.
-- =============================================================================
local function detectInterface()
    if type(GetBuildInfo) == "function" then
        local ok, _version, _build, _date, interface = pcall(GetBuildInfo)
        if ok and type(interface) == "number" and interface > 0 then
            return interface
        end
    end
    -- Lua 5.1+ always has string.gmatch; Lua 5.0 never does.
    if type(string.gmatch) ~= "function" then
        return 11200
    end
    return 0
end

local INTERFACE = detectInterface()
local IS_112 = (INTERFACE < 20000)

-- =============================================================================
-- Capability probe, taken once while CreateFrame is still the real one.
--
-- The interface number no longer tells the clients apart. The Forever build
-- reports 16001 ("vanilla" by the version) while having retail frames, retail
-- templates, C_QuestLog and StopSound. The version guess applied the whole 1.12
-- layer to it, which replaced CreateFrame, GetQuestLogTitle and PlaySoundFile at
-- global scope. That put addon code inside Blizzard's own call stack - the
-- client then refused protected calls with "this function is only available to
-- the Blizzard UI" on login - threw away every sound handle, fed frame scripts
-- the 1.12 arg1..arg9 globals instead of their own arguments (so OnUpdate saw
-- delta=nil), and left the details-button anchor misresolved. ForeverVO, which
-- works on this client, neither wraps CreateFrame nor any Blizzard global.
--
-- Every shim below is therefore gated on the capability it provides being
-- genuinely absent, so nothing is replaced on a client that already has it.
-- =============================================================================
local probeFrame = CreateFrame("Frame")
local MISSING = {
    setSize = (probeFrame.SetSize == nil),
    setShown = (probeFrame.SetShown == nil),
    hookScript = (probeFrame.HookScript == nil),
    colorTexture = (probeFrame.SetColorTexture == nil
        and probeFrame.SetTexture ~= nil),
    cQuestLog = (type(C_QuestLog) ~= "table"),
    stopSound = (type(StopSound) ~= "function"),
    getn = (type(table.getn) ~= "function"),
    gmatch = (type(string.gmatch) ~= "function"),
}
probeFrame:Hide()
probeFrame = nil
Compat.missing = MISSING

-- True only on a client whose frame objects really lack the methods the layer
-- adds for them. Every frame created afterwards goes through addon code, so the
-- answer must be "no" whenever the client can already do this itself.
local NEEDS_FRAME_SHIMS = MISSING.setSize or MISSING.setShown
    or MISSING.hookScript or MISSING.colorTexture
Compat.NEEDS_FRAME_SHIMS = NEEDS_FRAME_SHIMS

Compat.interface = INTERFACE
Compat.IS_112 = IS_112
Compat.version = ADDON_VERSION
-- A stoppable handle is what Core needs, and it only exists where StopSound
-- does: on 1.12 PlaySoundFile returns nothing usable.
Compat.PlaySoundFileReturnsHandle = (not MISSING.stopSound)
-- Does HookScript exist on frame objects here?
Compat.hasHookScript = (type(CreateFrame) == "function")
    and (function()
        local ok, res = pcall(function()
            local f = CreateFrame("Frame")
            return type(f.HookScript) == "function"
        end)
        return ok and res
    end)()

-- =============================================================================
-- GetQuestLogTitle shim - installed for EVERY client, because a quest id is
-- needed on all of them:
--   * 1.12/1.18 returns six values and has no id at all;
--   * a WotLK client is documented as returning eight, but some private-server
--     cores return six as well (observed: questID=nil on 3.3.5a).
-- The id is therefore synthesised from the quest title through the data pack
-- lookup, which is the only reliable source. The real function is called lazily
-- so the packs (which load after this file) are ready by then.
-- =============================================================================
-- See Core.lua: 0 is true in Lua, so a header test must be explicit.
local function IsQuestHeader(value)
    return value == 1 or value == true
end

-- Only where the client gives no quest id to work with. Replacing a Blizzard
-- function at global scope puts addon code in Blizzard's call stack, which the
-- modern client answers with the "only available to the Blizzard UI" block, so a
-- client that already has C_QuestLog is left alone.
local _origGetQuestLogTitle = GetQuestLogTitle
if type(_origGetQuestLogTitle) == "function" and MISSING.cQuestLog then
    function GetQuestLogTitle(questIndex)
        -- forward however many values the client actually returns
        local a, b, c, d, e, f, g, h = _origGetQuestLogTitle(questIndex)
        local title, isHeader, questID = a, d, h
        if not title then
            -- a client that returns nothing usable: keep the call harmless
            return a, b, c, d, e, f, g, h
        end
        if a == nil or d == 1 or d == true then
            return a, b, c, d, e, f, g, h
        end
        if type(questID) ~= "number" or questID <= 0 then
            if QuestEcho and QuestEcho.DataModules then
                local ok, id = pcall(function()
                    return QuestEcho.DataModules:GetQuestID("accept", title, "", "")
                end)
                if ok and id then questID = id end
            end
        end
        return a, b, c, d, e, f, g, questID
    end
end

-- =============================================================================
-- GetQuestID - installed for EVERY client.
--
--   * 1.12/1.18 has no GetQuestID at all;
--   * 3.3.5a has one, but this private-server core returns nil for it, which
--     left questID nil and broke the Echo buttons and every quest voice line.
--
-- Whatever the client provides is wrapped, and an unusable answer falls back to
-- the quest title through the data pack lookup. Order matters:
--   1. the title of the quest window that is open (the quest being looked at);
--   2. the selected quest-log row.
-- Resolving from the log first made accepting quest B play quest A's line.
-- The packs load after this file, so the lookup happens at call time.
-- =============================================================================
-- Records why the title lookup failed, for /qe diag. Filled in at call time.
QuestEcho112Diagnosis = {}

-- Markers this client appends to a quest title in the log. They are part of how
-- the log displays the quest, not part of its name, and the voice pack is keyed by
-- the bare title - "开始狩猎 (日常)" must be looked up as "开始狩猎".
local TITLE_MARKERS = {
    "(日常)", "(每日)", "(每周)", "(PvP)", "(PVP)", "(团队)", "(地下城)",
    "(副本)", "(职业)", "(种族)", "(节日)", "(活动)", "(精英)", "(组队)",
    "[日常]", "[每日]", "[PvP]",
}

local function cleanTitle(title)
    if type(title) ~= "string" then return nil end
    -- trim the whitespace the client likes to keep
    local s = string.gsub(title, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    if s == "" then return nil end
    -- drop a trailing marker (possibly repeated) until nothing matches
    local changed = true
    while changed do
        changed = false
        for _i = 1, table.getn(TITLE_MARKERS) do
            local marker = TITLE_MARKERS[_i]
            local n = string.len(marker)
            if string.len(s) > n
                and string.sub(s, string.len(s) - n + 1) == marker then
                s = string.gsub(string.sub(s, 1, string.len(s) - n), "%s+$", "")
                changed = true
            end
        end
    end
    if s == "" then return nil end
    return s
end
QuestEcho112 = QuestEcho112 or {}
QuestEcho112.CleanTitle = cleanTitle

-- The quest window title, or the selected log row's title when the window's own
-- title is empty (observed: GetTitleText() returns "" on this client).
local function currentQuestTitle()
    local diag = QuestEcho112Diagnosis

    if type(GetTitleText) == "function" then
        local okTitle, rawTitle = pcall(GetTitleText)
        diag.rawTitle = tostring(rawTitle)
        if okTitle then
            local cleaned = cleanTitle(rawTitle)
            if cleaned then
                diag.titleSource = "GetTitleText"
                diag.title = cleaned
                return cleaned
            end
        end
    end

    -- the selected row of the quest log
    if type(GetQuestLogSelection) == "function"
        and type(GetQuestLogTitle) == "function" then
        local okIdx, idx = pcall(GetQuestLogSelection)
        if okIdx and type(idx) == "number" and idx > 0 then
            local okT, title, _lvl, _sg, isHeader = pcall(GetQuestLogTitle, idx)
            if okT and not (isHeader == 1 or isHeader == true) then
                local cleaned = cleanTitle(title)
                if cleaned then
                    diag.titleSource = "quest log row " .. tostring(idx)
                    diag.title = cleaned
                    return cleaned
                end
            end
        end
    end

    -- last resort: the text region of the selected row
    if type(GetQuestLogSelection) == "function" then
        local okIdx, idx = pcall(GetQuestLogSelection)
        if okIdx and type(idx) == "number" and idx > 0 then
            local region = _G["QuestLogScrollFrameButton" .. idx .. "NormalText"]
                or _G["QuestLogTitle" .. idx .. "NormalText"]
            if region and type(region.GetText) == "function" then
                local okText, text = pcall(function() return region:GetText() end)
                if okText then
                    local cleaned = cleanTitle(text)
                    if cleaned then
                        diag.titleSource = "row text region " .. tostring(idx)
                        diag.title = cleaned
                        return cleaned
                    end
                end
            end
        end
    end

    diag.titleSource = "none"
    return nil
end

local function titleBasedQuestID()
    local diag = QuestEcho112Diagnosis
    diag.step = "start"
    local title = currentQuestTitle()
    if not title then
        diag.step = "no title available"
        return nil
    end
    if not (QuestEcho and QuestEcho.DataModules) then
        diag.step = "DataModules not ready"
        return nil
    end
    diag.step = "looking up"
    local okId, id = pcall(function()
        return QuestEcho.DataModules:GetQuestID("accept", title, "", "")
    end)
    diag.lookupOk = okId
    diag.lookupResult = tostring(id)
    if okId and id then
        diag.step = "resolved"
        return id
    end
    diag.step = "lookup returned " .. tostring(id)
    return nil
end
QuestEcho112 = QuestEcho112 or {}
QuestEcho112.Diagnosis = QuestEcho112Diagnosis
QuestEcho112 = QuestEcho112 or {}
QuestEcho112.TitleBasedQuestID = titleBasedQuestID

local function selectedLogQuestID()
    if type(GetQuestLogSelection) ~= "function"
        or type(GetQuestLogTitle) ~= "function" then
        return nil
    end
    local okIdx, idx = pcall(GetQuestLogSelection)
    if not okIdx or type(idx) ~= "number" or idx <= 0 then return nil end
    local okT, _title, _lvl, _sg, isHeader, _col, _comp, _freq, questID =
        pcall(GetQuestLogTitle, idx)
    if okT and not IsQuestHeader(isHeader)
        and type(questID) == "number" and questID > 0 then
        return questID
    end
    return nil
end

do
    local native = GetQuestID
    function GetQuestID()
        if type(native) == "function" then
            -- a client-provided value is trusted when it is a usable id
            local ok, id = pcall(native)
            if ok and type(id) == "number" and id > 0 then return id end
        end
        -- Only the displayed quest may answer this. Falling back to the quest-log
        -- SELECTION returned a different quest: accepting a quest with no voice
        -- played the voice of whichever row was selected in the log.
        return titleBasedQuestID()
    end
end
-- =============================================================================
-- Script error capture.
--
-- A flood of Lua errors makes the client warn about lost performance. The
-- default handler prints to the error frame, but the addon cannot read that, so
-- the first errors are recorded here and reported by /qe diag.
-- =============================================================================
QuestEcho = QuestEcho or {}
QuestEcho.LastErrors = QuestEcho.LastErrors or {}

do
    local previous = geterrorhandler and geterrorhandler() or nil
    local function record(message)
        local list = QuestEcho.LastErrors
        if table.getn(list) < 10 then
            list[table.getn(list) + 1] = tostring(message)
        end
        QuestEcho.LastError = tostring(message)
        if previous and previous ~= record then
            pcall(previous, message)
        end
    end
    if type(seterrorhandler) == "function" then
        pcall(seterrorhandler, record)
        QuestEcho.ErrorHandlerInstalled = true
    end
end

-- =============================================================================
-- table.getn compatibility, installed for EVERY client.
--
-- Lua 5.0 (the 1.18 client) has table.getn and no # operator. Lua 5.1 (the 3.3.5a
-- client) removed table.getn - the diagnostic reported table.getn=nil there - and
-- neither string.match, string.gmatch nor string.gfind exists on it either.
--
-- This loads first and installs the missing function before any other file runs,
-- because the call sites are spread across Core.lua from the top down.
-- =============================================================================
if type(table.getn) ~= "function" then
    table.getn = function(t)
        if type(t) ~= "table" then return 0 end
        local n = 0
        local key = next(t)
        while key ~= nil do
            if type(key) == "number" and key > n and key == math.floor(key) then
                n = key
            end
            key = next(t, key)
        end
        return n
    end
    QuestEcho112 = QuestEcho112 or {}
    QuestEcho112.InstalledGetn = true
else
    QuestEcho112 = QuestEcho112 or {}
    QuestEcho112.InstalledGetn = false
end

-- math.mod / math.pow: present on Lua 5.0 (1.12) but removed in 5.1.
-- ItemGameObject.lua captures math.mod at load time for its MD5 helper, so the
-- shim has to exist before that file runs. Installed only when missing, so the
-- 1.12 client keeps using the native one.
if type(math.mod) ~= "function" then
    math.mod = function(a, b)
        if type(a) ~= "number" or type(b) ~= "number" or b == 0 then return 0 end
        return a - math.floor(a / b) * b
    end
    QuestEcho112 = QuestEcho112 or {}
    QuestEcho112.InstalledMod = true
end
if type(math.pow) ~= "function" then
    math.pow = function(a, b) return math.exp(b * math.log(a)) end
    QuestEcho112 = QuestEcho112 or {}
    QuestEcho112.InstalledPow = true
end

-- Pattern iteration without string.gmatch/gfind: 3.3.5a provides neither.
local rawFind = string.find
function QuestEcho112.Words(text)
    local out, pos = {}, 1
    text = tostring(text or "")
    while true do
        local s = rawFind(text, "%S+", pos)
        if not s then break end
        local e = rawFind(text, "%s", s) or (string.len(text) + 1)
        out[table.getn(out) + 1] = string.sub(text, s, e - 1)
        pos = e
    end
    return out
end

if not IS_112 then
    return
end

-- =============================================================================
-- Lua 5.0 standard-library gaps
-- =============================================================================
if type(string.gfind) ~= "function" and type(string.gmatch) == "function" then
    string.gfind = string.gmatch
end

-- Lua 5.0 has no string.match. Its string.find returns (start, end, captures...)
-- while 5.1 returns (start, captures...), so the two leading positions are
-- skipped explicitly here.
if type(string.match) ~= "function" then
    function string.match(s, pattern, init)
        local startPos, _endPos, cap1, cap2, cap3, cap4, cap5 =
            sfind(s, pattern, init or 1)
        if not startPos then return nil end
        if cap1 ~= nil then return cap1 end
        if cap2 ~= nil then return cap2 end
        if cap3 ~= nil then return cap3 end
        if cap4 ~= nil then return cap4 end
        return cap5
    end
end

-- =============================================================================
-- bit library shim
-- ItemGameObject.lua's MD5 needs band/bor/bxor/bnot/lshift/rshift. Lua 5.0
-- numbers are doubles, so every intermediate is reduced modulo 2^32 after each
-- step to stay exact (a single 32x22-bit product would exceed 2^53).
-- =============================================================================
if type(bit) ~= "table" then
    local TWO32 = 4294967296
    local TWO31 = 2147483648

    local function toU(x)
        x = tonumber(x) or 0
        x = mod(x, TWO32)
        if x < 0 then x = x + TWO32 end
        return x
    end

    local function toS(x)
        x = mod(x, TWO32)
        if x >= TWO31 then x = x - TWO32 end
        return x
    end

    local shim = {}

    function shim.band(a, b)
        a, b = toU(a), toU(b)
        local r, k = 0, 1
        for _ = 1, 32 do
            if mod(a, 2) >= 1 and mod(b, 2) >= 1 then r = r + k end
            a, b = floor(a / 2), floor(b / 2)
            k = k * 2
        end
        return toS(r)
    end

    function shim.bor(a, b)
        a, b = toU(a), toU(b)
        local r, k = 0, 1
        for _ = 1, 32 do
            if mod(a, 2) >= 1 or mod(b, 2) >= 1 then r = r + k end
            a, b = floor(a / 2), floor(b / 2)
            k = k * 2
        end
        return toS(r)
    end

    -- Folds any number of arguments left to right, because the addon's MD5
    -- calls bxor(b, c, d) with three arguments.
    function shim.bxor(...)
        local values = Compat.Capture(arg)
        local n = values.count
        if n == 0 then return 0 end
        local result = toU(values[1])
        for i = 2, n do
            local other = toU(values[i])
            local r, k = 0, 1
            for _ = 1, 32 do
                if (mod(result, 2) >= 1) ~= (mod(other, 2) >= 1) then r = r + k end
                result, other = floor(result / 2), floor(other / 2)
                k = k * 2
            end
            result = r
        end
        return toS(result)
    end

    function shim.bnot(a)
        return toS(TWO32 - 1 - toU(a))
    end

    function shim.lshift(a, n)
        local x = toU(a)
        for _ = 1, n do
            x = mod(x * 2, TWO32)
        end
        return toS(x)
    end

    function shim.rshift(a, n)
        -- toU() is already in [0, 2^32), so this division is exact.
        return toS(floor(toU(a) / pow(2, n)))
    end

    bit = shim
end


-- =============================================================================
-- PlaySoundFile shim
-- 1.12: PlaySoundFile(path[, volume]) with volume 0-1 and no return value.
-- The wrapper always reports success and plays at full volume, because a nil
-- return would make Core treat every line as a playback failure.
-- =============================================================================
local _origPlaySoundFile = PlaySoundFile
if type(_origPlaySoundFile) == "function" and MISSING.stopSound then
    function PlaySoundFile(path, _channelOrVolume)
        if not path then return false end
        pcall(_origPlaySoundFile, path, 1.0)
        return true
    end
end

-- =============================================================================
-- Sound / CVar helpers missing on 1.12
-- =============================================================================
if type(StopSound) ~= "function" then
    function StopSound(_handle) end
end

if type(GetCVarBool) ~= "function" then
    function GetCVarBool(cvar)
        local value = GetCVar(cvar)
        if type(value) == "string" then
            local v = slower(value)
            return v == "1" or v == "true" or v == "on"
        end
        return value and true or false
    end
end

if type(IsMuted) ~= "function" then
    function IsMuted()
        return false
    end
end

-- These are no-ops: the client has no such API. They exist only so addon code
-- that calls them does not error. QuestEcho112.HasSoundFileMute records that the
-- real capability is missing, because a `type()` check cannot tell a real
-- function from one of these stubs.
QuestEcho112 = QuestEcho112 or {}
QuestEcho112.HasSoundFileMute = (type(MuteSoundFile) == "function")
    and (type(UnmuteSoundFile) == "function")
if type(MuteSoundFile) ~= "function" then
    function MuteSoundFile(_soundFile) end
end
if type(UnmuteSoundFile) ~= "function" then
    function UnmuteSoundFile(_soundFile) end
end

-- =============================================================================
-- strsplit / strtrim
-- FrameXML usually provides these, but they rely on string.find returning a
-- start index (Lua 5.1 behaviour), so provide safe versions when missing or
-- suspect, and use plain string.find(..., true) internally.
-- =============================================================================
-- strsplit/strtrim, plus an unpack fallback: this client's standard library is
-- trimmed enough that `unpack` may be missing too.
local function spreadArray(t)
    if type(unpack) == "function" then
        return unpack(t)
    end
    return t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8], t[9], t[10],
        t[11], t[12], t[13], t[14], t[15], t[16], t[17], t[18], t[19], t[20]
end
Compat.spreadArray = spreadArray

local function localFind(text, pattern, plain)
    -- string.find in Lua 5.0 with plain=true returns (start, end) like 5.1.
    return sfind(text, pattern, 1, plain)
end

if type(strsplit) ~= "function" then
    function strsplit(separator, text, limit)
        local parts = {}
        if type(text) ~= "string" then
            return spreadArray(parts)
        end
        local start = 1
        local count = 0
        while true do
            local s, e = localFind(text, separator, true)
            if not s then
                tinsert(parts, ssub(text, start))
                return spreadArray(parts)
            end
            if limit and count == limit - 1 then
                tinsert(parts, ssub(text, start))
                return spreadArray(parts)
            end
            tinsert(parts, ssub(text, start, s - 1))
            start = e + 1
            count = count + 1
        end
    end
end

if type(strtrim) ~= "function" then
    function strtrim(text)
        if type(text) ~= "string" then return text end
        return (sgsub(text, "^%s*(.-)%s*$", "%1"))
    end
end


-- =============================================================================
-- Frame method shims
-- Verified against this client: SetSize, SetShown, SetColorTexture, HookScript
-- and SlashCmdList are absent, while SetWidth/SetHeight/SetTexture/SetScript
-- exist. Frame objects are plain tables whose metatable __index is a *function*,
-- so writing into a shared method table has no effect; the methods have to be
-- placed on each frame instance. That is also what the working 1.12 addons on
-- this client do, so CreateFrame is wrapped and every new frame gets them.
--
-- Wrapping CreateFrame is also the single most expensive thing any addon can do
-- here: afterwards every frame in the game - Blizzard's included - is built by
-- addon code, which is precisely the chain that gets Blizzard's own UI blocked
-- with "this function is only available to the Blizzard UI". So the block runs
-- only when the client genuinely lacks the methods (NEEDS_FRAME_SHIMS), not by
-- version number.
-- =============================================================================
if NEEDS_FRAME_SHIMS then
do
    -- The original constructor, captured before the global is replaced.
    local realCreateFrame = CreateFrame

    -- Script callbacks must take fixed parameters: the engine calls them with
    -- arguments it provides through `arg`, and a Lua 5.0 function that wants
    -- those values cannot use a `...` expression to forward them.
    local SCRIPT_KEYS = {
        "OnShow", "OnHide", "OnEnter", "OnLeave", "OnUpdate",
        "OnEvent", "OnClick", "OnDragStart", "OnDragStop", "OnValueChanged",
    }

    local function addMethod(frame, key, fn)
        if frame[key] == nil then
            frame[key] = fn
        end
    end

    -- Textures and font strings created through a frame get the two methods this
    -- client lacks. This has to live on the fframe's own factory methods (below),
    -- because a global CreateTexture wrapper is never reached by frame:CreateTexture.
    local function patchRegion(region)
        if type(region) ~= "table" and type(region) ~= "userdata" then
            return region
        end
        if region.SetColorTexture == nil and region.SetTexture ~= nil then
            region.SetColorTexture = function(self, r, g, b, a)
                self:SetTexture(r, g, b, a)
            end
        end
        if region.SetShown == nil and region.Show ~= nil then
            region.SetShown = function(self, shown)
                if shown then self:Show() else self:Hide() end
            end
        end
        -- Textures and font strings are regions too, and this client has no
        -- SetSize on them either: Core calls progBg:SetSize(340, 3) and
        -- fill:SetSize(0, 3) while building the status bar.
        if region.SetSize == nil and region.SetWidth ~= nil then
            region.SetSize = function(self, width, height)
                if width then self:SetWidth(width) end
                if height then self:SetHeight(height) end
            end
        end
        -- Regions also reject the short SetPoint forms (Minimap.lua calls
        -- overlay:SetPoint("TOPLEFT")), so the same completion is applied here.
        local realSetPoint = region.SetPoint
        if type(realSetPoint) == "function" and region.SetPointPatched == nil then
            region.SetPointPatched = true
            region.SetPointRaw = realSetPoint
            region.SetPoint = function(self, point, a, b, c, d)
                if a == nil and b == nil and c == nil and d == nil then
                    return realSetPoint(self, point, UIParent, point, 0, 0)
                end
                if b == nil and c == nil and d == nil then
                    if type(a) == "number" then
                        -- SetPoint("TOPLEFT", x, y)
                        return realSetPoint(self, point, UIParent, "TOPLEFT", a, 0)
                    end
                    return realSetPoint(self, point, a, point, 0, 0)
                end
                return realSetPoint(self, point, a, b, c, d)
            end
        end
        return region
    end
    Compat.patchRegion = patchRegion

    -- Called with the frame as `self`, exactly like a real method.
    local function patchFrame(frame)
        if type(frame) ~= "table" and type(frame) ~= "userdata" then
            return frame
        end

        addMethod(frame, "SetSize", function(self, width, height)
            if width then self:SetWidth(width) end
            if height then self:SetHeight(height) end
        end)

        addMethod(frame, "SetShown", function(self, shown)
            if shown then self:Show() else self:Hide() end
        end)

        if frame.SetColorTexture == nil and frame.SetTexture ~= nil then
            frame.SetColorTexture = function(self, r, g, b, a)
                self:SetTexture(r, g, b, a)
            end
        end

        -- HookScript arrived in 3.x. It must not depend on GetScript existing
        -- (this client has neither), so the accumulated handler is kept in a
        -- plain field and installed through our SetScript.
        addMethod(frame, "HookScript", function(self, script, handler)
            if type(handler) ~= "function" then return end
            local previous = self[script .. "QEChain"]
            if previous == nil and type(self.SetScriptRaw) == "function" then
                previous = self:SetScriptRaw(script)
            end
            if previous == nil and type(self.GetScript) == "function" then
                previous = self:GetScript(script)
            end
            local function chained(f, a1, a2, a3, a4, a5, a6, a7, a8, a9)
                if type(previous) == "function" then
                    previous(f, a1, a2, a3, a4, a5, a6, a7, a8, a9)
                end
                return handler(f, a1, a2, a3, a4, a5, a6, a7, a8, a9)
            end
            self[script .. "QEChain"] = chained
            self:SetScript(script, chained)
            local shown = false
            pcall(function() shown = self:IsVisible() end)
            if shown then pcall(handler, self) end
        end)

        -- Chat frames: the real AddMessage takes a colour triple. Accept both
        -- AddMessage("text") and AddMessage("text", r, g, b).
        if type(frame.AddMessage) == "function" then
            local rawAddMessage = frame.AddMessage
            frame.AddMessageRaw = rawAddMessage
            frame.AddMessage = function(self, text, r, g, b)
                if type(text) ~= "string" and type(text) ~= "number" then
                    return
                end
                local message = tostring(text)
                if r ~= nil then
                    rawAddMessage(self, message, r, g, b)
                else
                    rawAddMessage(self, message)
                end
            end
        end

        -- Keep the engine's script slots callable from a fixed-parameter Lua
        -- function. Probe results on this client: callbacks are invoked with NO
        -- arguments, and the engine publishes the values through globals --
        -- `this` (the frame), `event` (the event name) and `arg1`..`arg9`.
        -- `arg` does not exist inside a callback and `...` is a syntax error on
        -- Lua 5.0. Crucially the wrapper must go through the engine's own
        -- SetScript (kept under SetScriptRaw) instead of assigning the field,
        -- or the engine never registers the slot and the control stays dead.
        local realSetScript = frame.SetScript
        if type(realSetScript) == "function" and frame.SetScriptPatched == nil then
            frame.SetScriptPatched = true
            frame.SetScriptRaw = realSetScript
            frame.SetScript = function(self, script, handler)
                if handler == nil then
                    return realSetScript(self, script, nil)
                end
                if script == "OnEvent" then
                    return realSetScript(self, script, function()
                        return handler(self, event, arg1, arg2, arg3, arg4, arg5,
                            arg6, arg7, arg8, arg9)
                    end)
                end
                return realSetScript(self, script, function()
                    return handler(self, arg1, arg2, arg3, arg4, arg5, arg6,
                        arg7, arg8, arg9)
                end)
            end
        end

        -- Region factories. Core.lua calls frame:CreateTexture(...) and
        -- frame:CreateFontString(...), which resolve to the frame's own methods
        -- and would never reach a global wrapper, so they are overridden here.
        local realCreateTexture = frame.CreateTexture
        if type(realCreateTexture) == "function" and frame.CreateTexturePatched == nil then
            frame.CreateTexturePatched = true
            frame.CreateTexture = function(self, name, layer)
                return patchRegion(realCreateTexture(self, name, layer))
            end
        end
        local realCreateFontString = frame.CreateFontString
        if type(realCreateFontString) == "function" and frame.CreateFontStringPatched == nil then
            frame.CreateFontStringPatched = true
            frame.CreateFontString = function(self, name, layer, template)
                return patchRegion(realCreateFontString(self, name, layer, template))
            end
        end

        -- 1.12 rejects the short SetPoint forms: a relative point is required.
        -- Filling in nil/nil (as an earlier version did) parks the frame at
        -- (0,0), i.e. off screen, which is what emptied the options panel and
        -- hid the minimap button. Every arity is completed explicitly here.
        local realSetPoint = frame.SetPoint
        if type(realSetPoint) == "function" and frame.SetPointPatched == nil then
            frame.SetPointPatched = true
            frame.SetPointRaw = realSetPoint
            frame.SetPoint = function(self, point, a, b, c, d)
                if a == nil and b == nil and c == nil and d == nil then
                    -- SetPoint("CENTER")
                    return realSetPoint(self, point, UIParent, point, 0, 0)
                end
                if b == nil and c == nil and d == nil then
                    if type(a) == "number" then
                        -- SetPoint("TOPLEFT", x, y)
                        return realSetPoint(self, point, UIParent, "TOPLEFT", a, 0)
                    end
                    -- SetPoint("TOPLEFT", relativeFrame)
                    return realSetPoint(self, point, a, point, 0, 0)
                end
                return realSetPoint(self, point, a, b, c, d)
            end
        end

        return frame
    end

    -- Frame methods that return *new objects* are overridden inside patchFrame
    -- (they resolve on the frame itself, not through a global).

    function CreateFrame(frameType, name, parent, template)
        return patchFrame(realCreateFrame(frameType, name, parent, template))
    end
end
end

-- =============================================================================
-- UI templates
-- The probe shows this client is missing several Blizzard templates the addon
-- relies on (UIPanelButtonTemplate, UIPanelCloseButton, UIDropDownMenuTemplate,
-- OptionsSliderTemplate, InterfaceOptionsCheckButtonTemplate). Registering them
-- is what makes CreateFrame(type, name, parent, template) work: the engine
-- refuses an unknown template before handing the frame back to Lua.
-- =============================================================================
-- Each template is registered in its own protected block: a failure in one must
-- not leave the later templates unregistered (the check box and slider are what
-- the options panel needs most).
local function registerTemplate(name, builder)
    if type(_G[name]) == "table" then return end
    local ok, err = pcall(builder)
    if not ok then
        if type(DEFAULT_CHAT_FRAME) == "table" and DEFAULT_CHAT_FRAME.AddMessage then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff6060[QuestEcho]|r template failed: "
                .. name .. " -> " .. tostring(err))
        end
    end
end

local function createTemplates()
    local container = CreateFrame("Frame")
    local fonts = {
        button = "GameFontNormal",
        title = "GameFontNormalLarge",
        label = "GameFontHighlightSmall",
        small = "GameFontHighlightSmall",
    }
    local colors = {
        button = { 1.0, 0.82, 0.0 },
        title = { 1.0, 0.82, 0.0 },
        label = { 1.0, 0.82, 0.0 },
        small = { 0.8, 0.8, 0.8 },
    }

    -- ---- buttons -----------------------------------------------------------
    if type(_G["UIPanelButtonTemplate"]) ~= "table"
        and type(CreateFrame) == "function" then
        local btn = CreateFrame("Button", "QuestEchoPanelButtonTemplate", container)
        btn:Hide()

        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(0.15, 0.15, 0.18, 0.95)
        btn.qeBg = bg

        local borderTop = btn:CreateTexture(nil, "BORDER")
        borderTop:SetPoint("TOPLEFT")
        borderTop:SetPoint("TOPRIGHT")
        borderTop:SetHeight(1)
        borderTop:SetTexture(0.5, 0.45, 0.35, 0.9)
        local borderBottom = btn:CreateTexture(nil, "BORDER")
        borderBottom:SetPoint("BOTTOMLEFT")
        borderBottom:SetPoint("BOTTOMRIGHT")
        borderBottom:SetHeight(1)
        borderBottom:SetTexture(0.5, 0.45, 0.35, 0.9)

        local label = btn:CreateFontString(nil, "OVERLAY", fonts.button)
        label:SetPoint("CENTER")
        label:SetTextColor(colors.button[1], colors.button[2], colors.button[3])
        btn.qeLabel = label
        btn.SetText = function(self, text)
            self.qeLabel:SetText(text or "")
        end
        btn.GetText = function(self)
            return self.qeLabel:GetText() or ""
        end

        local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetTexture(1, 1, 1, 0.15)

        btn.Enable = function(self) self.qeLabel:SetTextColor(1, 0.82, 0) end
        btn.Disable = function(self) self.qeLabel:SetTextColor(0.5, 0.5, 0.5) end
        btn:EnableMouse(true)
    end

    -- close button: a plain button with an X label
    if type(_G["UIPanelCloseButton"]) ~= "table"
        and type(CreateFrame) == "function" then
        local close = CreateFrame("Button", "QuestEchoCloseButtonTemplate", container)
        close:Hide()
        close:SetWidth(26)
        close:SetHeight(26)
        local x = close:CreateFontString(nil, "OVERLAY", fonts.title)
        x:SetPoint("CENTER")
        x:SetText("X")
        x:SetTextColor(1, 0.3, 0.3)
        close.qeLabel = x
        close:EnableMouse(true)
    end

    -- ---- checkbox ----------------------------------------------------------
    if type(_G["InterfaceOptionsCheckButtonTemplate"]) ~= "table"
        and type(CreateFrame) == "function" then
        local check = CreateFrame("CheckButton", "QuestEchoCheckButtonTemplate", container)
        check:Hide()
        check:SetWidth(20)
        check:SetHeight(20)
        local box = check:CreateTexture(nil, "BACKGROUND")
        box:SetAllPoints()
        box:SetTexture(0.1, 0.1, 0.12, 0.95)
        local mark = check:CreateTexture(nil, "ARTWORK")
        mark:SetPoint("TOPLEFT", 3, -3)
        mark:SetPoint("BOTTOMRIGHT", -3, 3)
        mark:SetTexture(1, 0.82, 0, 1)
        check.qeMark = mark
        local realSetChecked = check.SetChecked
        check.SetChecked = function(self, checked)
            if checked then self.qeMark:Show() else self.qeMark:Hide() end
            if realSetChecked then pcall(realSetChecked, self, checked) end
        end
        check:SetChecked(false)
        check:EnableMouse(true)
    end

    -- ---- slider ------------------------------------------------------------
    if type(_G["OptionsSliderTemplate"]) ~= "table"
        and type(CreateFrame) == "function" then
        local slider = CreateFrame("Slider", "QuestEchoSliderTemplate", container)
        slider:Hide()
        slider:SetWidth(200)
        slider:SetHeight(16)
        local track = slider:CreateTexture(nil, "BACKGROUND")
        track:SetPoint("LEFT")
        track:SetPoint("RIGHT")
        track:SetHeight(4)
        track:SetTexture(0.1, 0.1, 0.12, 1)
        local thumb = slider:CreateTexture(nil, "ARTWORK")
        thumb:SetWidth(12)
        thumb:SetHeight(16)
        thumb:SetTexture(0.8, 0.7, 0.3, 1)
        slider:SetThumbTexture(thumb)

        local suffix = slider.GetName and slider:GetName() or "QuestEchoSlider"
        local low = slider:CreateFontString(suffix .. "Low", "ARTWORK", fonts.small)
        low:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", -4, 2)
        local high = slider:CreateFontString(suffix .. "High", "ARTWORK", fonts.small)
        high:SetPoint("TOPRIGHT", slider, "BOTTOMRIGHT", 4, 2)
        local text = slider:CreateFontString(suffix .. "Text", "ARTWORK", fonts.label)
        text:SetPoint("BOTTOM", slider, "TOP", 0, 4)
        slider.qeLow, slider.qeHigh, slider.qeText = low, high, text
    end

    -- ---- dropdown ----------------------------------------------------------
    -- The UIDropDownMenu_* functions DO exist on this client; only the template
    -- is missing, so a button carrying the expected child name is enough.
    if type(_G["UIDropDownMenuTemplate"]) ~= "table"
        and type(CreateFrame) == "function" then
        local dd = CreateFrame("Frame", "QuestEchoDropDownTemplate", container)
        dd:Hide()
        dd:SetWidth(200)
        dd:SetHeight(32)
        local btn = CreateFrame("Button", "$parentButton", dd)
        btn:SetPoint("LEFT")
        btn:SetWidth(200)
        btn:SetHeight(24)
        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(0.1, 0.1, 0.12, 0.95)
        local label = btn:CreateFontString("$parentText", "OVERLAY", fonts.small)
        label:SetPoint("LEFT", 6, 0)
        btn.qeLabel = label
        dd.qeButton = btn
    end
end
pcall(createTemplates)

-- =============================================================================
-- SlashCmdList is absent while addon files load on this client, and it is
-- created later by FrameXML. This watcher waits for it and then wires up
-- whatever handler Core registered on QuestEcho.SlashHandler, so "/qe" works
-- even though the table did not exist at load time.
-- =============================================================================
if type(SlashCmdList) ~= "table" then
    SlashCmdList = {}
end

local slashWatch = CreateFrame("Frame")
local slashElapsed = 0
local slashTries = 0
slashWatch:SetScript("OnUpdate", function(self, elapsed)
    slashElapsed = slashElapsed + (elapsed or 0)
    if slashElapsed < 0.5 then return end
    slashElapsed = 0
    slashTries = slashTries + 1
    local handler = QuestEcho and QuestEcho.SlashHandler
    local installed = false
    if type(SlashCmdList) == "table" and type(handler) == "function" then
        pcall(function()
            SlashCmdList["QUESTECHO"] = handler
            installed = true
        end)
    end
    if installed or slashTries > 40 then
        self:SetScript("OnUpdate", nil)
        self:Hide()
    end
end)

-- =============================================================================
-- hooksecurefunc (absent on 1.12, and there is no taint system here)
-- The wrapper cannot use `...`, so it captures the arguments and returns the
-- first six values, which covers every hook the addon installs.
-- =============================================================================
if type(hooksecurefunc) ~= "function" then
    function hooksecurefunc(target, funcName, hookFunc)
        if type(target) == "string" then
            local original = _G[target]
            if type(original) ~= "function" then return end
            _G[target] = function(...)
                local values = Compat.Capture(arg)
                local a, b, c, d, e, f = Compat.Spread(original, values)
                Compat.Spread(hookFunc, values)
                return a, b, c, d, e, f
            end
            return
        end
        if type(target) ~= "table" then
            return
        end
        local original = target[funcName]
        if type(original) ~= "function" then return end
        target[funcName] = function(self, ...)
            local values = Compat.Capture(arg)
            local a, b, c, d, e, f = original(self, values[1], values[2], values[3],
                values[4], values[5], values[6], values[7], values[8], values[9],
                values[10])
            Compat.SpreadScript(hookFunc, self, values)
            return a, b, c, d, e, f
        end
    end
end

-- =============================================================================
-- EventUtil (arrived in 4.x; Core uses it to wait for another addon)
-- =============================================================================
if type(EventUtil) ~= "table" then
    EventUtil = {}
    function EventUtil.ContinueOnAddOnLoaded(addonName, callback)
        local frame = CreateFrame("Frame")
        local elapsed = 0
        frame:SetScript("OnUpdate", function(self, delta)
            elapsed = elapsed + delta
            if IsAddOnLoaded(addonName) or elapsed > 10 then
                self:SetScript("OnUpdate", nil)
                self:Hide()
                pcall(callback)
            end
        end)
    end
end

-- =============================================================================
-- Modern namespace placeholders
-- =============================================================================
if type(C_Sound) ~= "table" then C_Sound = {} end
if type(C_Timer) ~= "table" then C_Timer = {} end
if type(C_QuestLog) ~= "table" then C_QuestLog = {} end
if type(C_AddOns) ~= "table" then C_AddOns = {} end
if type(C_GossipInfo) ~= "table" then C_GossipInfo = {} end
if type(C_Item) ~= "table" then C_Item = {} end
if type(BackdropTemplateMixin) ~= "table" then BackdropTemplateMixin = nil end

-- =============================================================================
-- GetBuildInfo hardening: guarantee a numeric interface value for Core's
-- IS_VANILLA_ERA / IS_MODERN_API branches.
-- =============================================================================
local _origGetBuildInfo = GetBuildInfo
if type(_origGetBuildInfo) == "function" then
    function GetBuildInfo()
        local version, build, date, interface = _origGetBuildInfo()
        if type(interface) ~= "number" or interface <= 0 then
            interface = INTERFACE > 0 and INTERFACE or 11200
        end
        return version, build, date, interface
    end
end

-- =============================================================================
-- Load confirmation
-- =============================================================================
-- Kept as a function but not called: startup chat output is limited to a single
-- line from Core, so a normal login stays quiet.
local function Announce()
    local frame = DEFAULT_CHAT_FRAME
    if not frame or type(frame.AddMessage) ~= "function" then return end
    frame:AddMessage("|cff33ffcc[QuestEcho]|r " .. sformat(
        "1.12 compatibility layer active (interface %s, %s)",
        tostring(INTERFACE),
        type(string.gfind) == "function" and "Lua 5.0" or "Lua 5.1+"))
end
QuestEcho112.Announce = Announce

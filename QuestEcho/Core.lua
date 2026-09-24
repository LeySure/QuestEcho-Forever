-- =============================================================================
-- QuestEcho (Retail) — quest voice lines for World of Warcraft
-- Plays a TTS voice line when a quest is shown / accepted / completed, shows
-- the text being read as a caption under a movable status bar, and queues
-- multiple lines. Standalone addon + data packs (QuestEchoData[-zhCN]).
-- =============================================================================

local ADDON_NAME, _ns = ...

local interfaceVersion = (select(4, GetBuildInfo())) or 0
QuestEcho = QuestEcho or {}
QuestEcho.Interface = interfaceVersion

local L = function(en, zh)
    local loc = GetLocale()
    if loc == "zhCN" or loc == "zhTW" then
        return zh or en
    end
    return en
end

local format = string.format
local tinsert = table.insert
local tremove = table.remove
local max = math.max
local min = math.min
local floor = math.floor

-- =============================================================================
-- Enums
-- =============================================================================
QuestEcho.Enums = QuestEcho.Enums or {}
local Enums = QuestEcho.Enums

Enums.SoundEvent = Enums.SoundEvent or {
    QuestAccept   = "accept",
    QuestComplete = "complete",
    QuestDetail   = "detail",
    QuestProgress = "progress",
    QuestGreeting = "greeting",
    Gossip        = "gossip",
}

Enums.GUID = Enums.GUID or {}
function Enums.GUID:IsCreature(t)
    return type(t) == "string" and t:sub(1, 3) == "Creature"
end
function Enums.GUID:CanHaveID(t)
    if type(t) ~= "string" then return false end
    local prefix = t:sub(1, 4)
    return prefix == "Creature" or prefix == "GameObj" or prefix == "Player" or prefix == "Vehicle" or prefix == "NPC"
end

function Enums.SoundEvent:IsQuestEvent(event)
    return event == self.QuestAccept or event == self.QuestComplete
        or event == self.QuestDetail or event == self.QuestProgress
        or event == self.QuestGreeting
end
function Enums.SoundEvent:IsGossipEvent(event)
    return event == self.Gossip
end

-- =============================================================================
-- Addon config
-- =============================================================================
QuestEcho.Addon = {}
local Addon = QuestEcho.Addon

function Addon:GetDefaults()
    return {
        profile = {
            ShowUI = true,
            Captions = true,
            VoiceLang = "auto",      -- "auto" follows client; "enUS"/"zhCN" force a pack
            Volume = 1.0,            -- kept for compatibility; unused on retail
            AudioChannel = "MASTER", -- retail PlaySoundFile only takes (path, channel)
            QuestDetail = true,      -- play detail voice when quest text is shown
            QuestAccept = true,
            QuestComplete = true,
            QuestProgress = true,    -- play in-progress (turn-in incomplete) voice
            QuestGreeting = true,    -- play NPC quest-greeting voice
            QueueGrow = "down",      -- "down": rows below header, header rises; "up": header fixed, rows above
            QueueGap = 2,           -- seconds of silence between consecutive voices
        },
        char = {
            IsPaused = false,
            Pos = nil,
            OptPos = nil,
        },
        missing = { items = {} },    -- scan log of voice lines that had no audio
    }
end

function Addon:MergeDB(loaded, defaults)
    local function Merge(dst, src)
        for k, v in pairs(src) do
            if type(v) == "table" then
                dst[k] = dst[k] or {}
                Merge(dst[k], v)
            elseif dst[k] == nil then
                dst[k] = v
            end
        end
        return dst
    end
    return Merge(loaded or {}, defaults)
end

-- Bind the db to the SavedVariables global (QuestEchoDB). MergeDB returns the
-- SAME table it was given, so writing Addon.db.char.* persists to disk -- if we
-- let it build a fresh table on a nil global, nothing ever gets saved.
local function InitDB()
    -- SavedVariables are only guaranteed to be loaded by the time our own
    -- ADDON_LOADED fires; at file-scope they can still be nil on retail 12.x.
    -- Re-running here rebinds Addon.db to the on-disk table so positions and
    -- settings persist.
    QuestEchoDB = QuestEchoDB or {}
    Addon.db = Addon:MergeDB(QuestEchoDB, Addon:GetDefaults())
end
InitDB()

QuestEcho.session = { PlayedSession = {} }

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc[QuestEcho]|r " .. tostring(msg))
end

QuestEcho.Debug = {}
local Debug = QuestEcho.Debug
Debug.enabled = false
function Debug:Print(...)
    if not self.enabled then return end
    DEFAULT_CHAT_FRAME:AddMessage("|cff66aa66[QE-dbg]|r " .. format(...))
end

-- =============================================================================
-- Utils
-- =============================================================================
QuestEcho.Utils = {}
local Utils = QuestEcho.Utils

function Utils:GetNPCName()
    if UnitExists("npc") then
        local name = UnitName("npc")
        if name and name ~= UNKNOWN then
            return name
        end
    end
    return nil
end

function Utils:GetNPCGUID()
    if UnitExists("npc") then
        return UnitGUID("npc")
    end
    return nil
end

-- Play a file through the game sound system. Retail PlaySoundFile only takes
-- (sound, channel) — the old volume argument was removed, so volume is
-- controlled by the game's channel volume slider for the chosen channel.
-- PlaySoundFile returns (willPlay, soundHandle); the handle is what StopSound
-- needs, so both are captured (WeakAuras/AIQuestVoices use the same pattern).
-- Audio capability probe. Retail exposes C_Sound.GetPosition (current playback
-- position in seconds); C_Sound.SetPosition (a true seek) is unavailable on most
-- builds. All playback code below is pcall-guarded and degrades gracefully.
local HAS_GETPOSITION = (type(C_Sound) == "table") and (type(C_Sound.GetPosition) == "function")
local HAS_SETPOSITION = (type(C_Sound) == "table") and (type(C_Sound.SetPosition) == "function")

-- ============================================================================
-- Client flavour support. One Core runs on retail (9.0+ API), World of
-- Warcraft: Forever and Classic-era clients. Every difference is feature
-- detected at runtime, so no per-client build is required.
-- ============================================================================
local TOC_VERSION = (select(4, GetBuildInfo())) or 0
local IS_MODERN_API = (TOC_VERSION >= 90000)
local HAS_CLASSIC_QUESTLOG = (type(GetQuestLogSelection) == "function")
    and (type(GetQuestLogTitle) == "function")

local function QEAfter(delay, fn)
    local CT = C_Timer
    if CT and CT.After then CT.After(delay, fn); return end
    local f = CreateFrame("Frame")
    local elapsed = 0
    f:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed >= delay then
            f:SetScript("OnUpdate", nil)
            f:Hide()
            fn()
        end
    end)
end
QuestEcho.After = QEAfter

local function CreatePanelFrame(name, parent)
    local f
    local ok = pcall(function()
        f = CreateFrame("Frame", name, parent, "BackdropTemplate")
    end)
    if ok and f and f.SetBackdrop then
        f._qeHasBackdrop = true
        return f
    end
    f = CreateFrame("Frame", name, parent)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    if bg.SetColorTexture then
        bg:SetColorTexture(0.05, 0.05, 0.08, 0.97)
    else
        bg:SetTexture(0.05, 0.05, 0.08, 0.97)
    end
    f._qeHasBackdrop = false
    return f
end
QuestEcho.CreatePanelFrame = CreatePanelFrame

local function PlayFile(path)
    local channel = Addon.db.profile.AudioChannel or "MASTER"
    local ok, didPlay, handle = pcall(PlaySoundFile, path, channel)
    if ok and didPlay and handle then
        return handle
    end
    -- fallback to the default channel if the chosen one was rejected
    if channel ~= "MASTER" then
        local ok2, didPlay2, handle2 = pcall(PlaySoundFile, path, "MASTER")
        if ok2 and didPlay2 and handle2 then
            return handle2
        end
    end
    return nil
end

function Utils:PlaySound(soundData)
    if not soundData or not soundData.path then
        return nil
    end
    local handle = PlayFile(soundData.path)
    if handle then
        soundData.handle = handle
    end
    return handle
end

function Utils:StopSound(soundData)
    if not soundData then
        return
    end
    if soundData.handle then
        pcall(StopSound, soundData.handle)
        soundData.handle = nil
    end
end

-- Current playback position of a line (seconds), or nil when unavailable.
function Utils:GetPlayPosition(soundData)
    if soundData and soundData.handle and HAS_GETPOSITION then
        local ok, pos = pcall(C_Sound.GetPosition, soundData.handle)
        if ok and type(pos) == "number" and pos >= 0 then
            return pos
        end
    end
    return nil
end

function Utils:CanSeek()
    return HAS_SETPOSITION
end

-- (Re)start a line, seeking to pos when the client supports it.
function Utils:PlaySoundAt(soundData, pos)
    if not soundData or not soundData.path then
        return nil
    end
    local handle = PlayFile(soundData.path)
    if handle then
        soundData.handle = handle
        if pos and pos > 0.1 and HAS_SETPOSITION then
            pcall(C_Sound.SetPosition, handle, pos)
        end
    end
    return handle
end

function Utils:IsSoundEnabled()
    return not IsMuted() and GetCVarBool("Sound_EnableAllSound")
end

-- =============================================================================
-- Data modules (data packs: QuestEchoData, QuestEchoData-zhCN, ...)
-- =============================================================================
QuestEcho.DataModules = {}
local DataModules = QuestEcho.DataModules

-- Retail-safe addon enumeration: the classic GetNumAddOns/GetAddOnInfo still
-- exist in 12.x (wowprogramming confirms); C_AddOns also exposes some of them.
-- Every path is pcall-guarded so no client state can crash startup.
local function SafeGetNumAddOns()
    local ok, n = pcall(GetNumAddOns)
    if ok and type(n) == "number" then
        return n
    end
    ok, n = pcall(function()
        if C_AddOns and C_AddOns.GetNumAddOns then
            return C_AddOns.GetNumAddOns()
        end
        return 0
    end)
    if ok and type(n) == "number" then
        return n
    end
    return 0
end

local function SafeGetAddOnInfo(i)
    local ok, name = pcall(GetAddOnInfo, i)
    if ok then
        return name
    end
    ok, name = pcall(function()
        if C_AddOns and C_AddOns.GetAddOnInfo then
            return C_AddOns.GetAddOnInfo(i)
        end
        return nil
    end)
    if ok then
        return name
    end
    return nil
end

-- Retail-safe "is this addon loaded": the global IsAddOnLoaded was moved to
-- C_AddOns in 10.1/12.x. Try the namespaced API first, then the legacy global.
local function QE_IsAddOnLoaded(id)
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        local ok, res = pcall(C_AddOns.IsAddOnLoaded, id)
        if ok then return res end
    end
    if IsAddOnLoaded then
        local ok, res = pcall(IsAddOnLoaded, id)
        if ok then return res end
    end
    return false
end

-- Modifier-key helper: IsShiftKeyDown was removed in 12.0; prefer
-- GetModifierKeyState, then InputUtil, then the legacy global.
local function IsShiftDown()
    local ok, shift, ctrl, alt = pcall(GetModifierKeyState)
    if ok and type(shift) == "boolean" then
        return shift
    end
    if InputUtil and InputUtil.IsShiftKeyDown then
        return InputUtil.IsShiftKeyDown()
    end
    if IsShiftKeyDown then
        return IsShiftKeyDown()
    end
    return false
end

function DataModules:EnumerateAddons()
    local list = {}
    local n = SafeGetNumAddOns()
    for i = 1, n do
        local name = SafeGetAddOnInfo(i)
        if name and (name:find("^QuestEchoData") or name:find("^AI_VoiceOverData")) then
            list[#list + 1] = name
        end
    end
    -- fallback: known locale packs even if enumeration is unavailable
    if #list == 0 then
        for _, known in ipairs({ "QuestEchoData", "QuestEchoData-zhCN", "QuestEchoData-ruRU", "QuestEchoData-esES", "QuestEchoData-deDE", "QuestEchoData-frFR", "QuestEchoData-koKR" }) do
            if QE_IsAddOnLoaded(known) then
                list[#list + 1] = known
            end
        end
    end
    table.sort(list, function(a, b) return a < b end)
    return list
end

function DataModules:Register(name, module, addonNameOverride)
    self.registeredModules = self.registeredModules or {}
    self.registeredAddonNames = self.registeredAddonNames or {}
    if self.registeredModules[name] and self.registeredModules[name] ~= module then
        -- keep the METADATA of the previous module when replacing
        module.METADATA = self.registeredModules[name].METADATA
    end
    self.registeredModules[name] = module
    -- the on-disk addon folder (differs for locale packs: e.g.
    -- QuestEchoData-zhCN registers under the shared key "QuestEchoData")
    self.registeredAddonNames[name] = addonNameOverride or name
end

function DataModules:GetModule(name)
    return self.registeredModules and self.registeredModules[name]
end

function DataModules:GetModules()
    local list = {}
    if not self.registeredModules then return list end
    for name, m in pairs(self.registeredModules) do
        list[#list + 1] = { name = name, module = m }
    end
    return list
end

-- ---- active language selection ---------------------------------------------
-- Each pack tags its table with _lang ("enUS"/"zhCN"). The active language is
-- the user's forced choice (db.profile.VoiceLang) when that pack exists, else
-- the client-locale pack, else "enUS" as the final fallback.
function DataModules:GetActiveLang()
    local forced = Addon.db and Addon.db.profile and Addon.db.profile.VoiceLang or "auto"
    if forced and forced ~= "auto" and self:LangModuleExists(forced) then
        return forced
    end
    local loc = GetLocale()
    if loc and self:LangModuleExists(loc) then
        return loc
    end
    if self:LangModuleExists("enUS") then
        return "enUS"
    end
    -- no enUS pack: accept whatever is installed so audio still works
    for _, m in ipairs(self:GetModules()) do
        local l = m.module and m.module._lang
        if l then return l end
    end
    return (forced ~= "auto" and forced) or loc or "enUS"
end

function DataModules:LangModuleExists(lang)
    if not lang then return false end
    for _, m in ipairs(self:GetModules()) do
        if m.module and m.module._lang == lang then
            return true
        end
    end
    return false
end

function DataModules:IsActive(module)
    if not module then return false end
    -- packs without a _lang tag (legacy) are treated as enUS
    local lang = module._lang or "enUS"
    return lang == self:GetActiveLang()
end

function DataModules:TryLoad(name)
    if QE_IsAddOnLoaded(name) then
        return true
    end
    local ok = pcall(LoadAddOn, name)
    return ok and QE_IsAddOnLoaded(name)
end

-- Load all QuestEchoData packs lazily (called on ADDON_LOADED of the main
-- addon and on demand).
function DataModules:LoadAll()
    local ok, err = pcall(function()
        for _, name in ipairs(self:EnumerateAddons()) do
            if not QE_IsAddOnLoaded(name) then
                self:TryLoad(name)
            end
        end
    end)
    if not ok then
        Debug:Print("LoadAll error: %s", tostring(err))
    end
end

-- ---- fuzzy title lookup -----------------------------------------------------
local function jaccardSimilarity(a, b)
    local sa, sb = tostring(a or ""):lower(), tostring(b or ""):lower()
    if sa == sb then return 1 end
    if sa == "" or sb == "" then return 0 end
    local function grams(s, n)
        local set = {}
        local count = 0
        for i = 1, #s - n + 1 do
            local g = s:sub(i, i + n - 1)
            if not set[g] then set[g] = true count = count + 1 end
        end
        return set, count
    end
    local n = 2
    local ga, ca = grams(sa, n)
    local gb, cb = grams(sb, n)
    local inter = 0
    for g in pairs(ga) do
        if gb[g] then inter = inter + 1 end
    end
    local union = ca + cb - inter
    if union == 0 then return 0 end
    return inter / union
end

function QuestEcho.FuzzySearchBestKeys(query, tableVar)
    local best = {}
    for key, value in pairs(tableVar) do
        local sim = jaccardSimilarity(query, key)
        if sim >= 0.45 then
            best[#best + 1] = { key = key, value = value, sim = sim }
        end
    end
    table.sort(best, function(x, y)
        if x.sim == y.sim then return x.key < y.key end
        return x.sim > y.sim
    end)
    return best
end

local function replaceDoubleQuotes(text)
    if not text then return text end
    text = tostring(text)
    -- Normalise every apostrophe/quote variant to the straight ASCII form used
    -- as the data-pack key (retail titles use the curly U+2019 apostrophe).
    text = text:gsub("‘", "'")
    text = text:gsub("’", "'")
    text = text:gsub("‛", "'")
    text = text:gsub("′", "'")
    text = text:gsub("`", "'")
    text = text:gsub('"', "'")
    return text
end

local function getFirstNWords(text, n)
    if not text then return "" end
    local count = 0
    local result = ""
    for word in tostring(text):gmatch("%S+") do
        count = count + 1
        result = result .. " " .. word
        if count >= n then break end
    end
    return result
end

local function getLastNWords(text, n)
    if not text then return "" end
    local words = {}
    for word in tostring(text):gmatch("%S+") do
        tinsert(words, word)
    end
    local result = ""
    for i = max(1, #words - n + 1), #words do
        result = result .. " " .. words[i]
    end
    return result
end

-- Resolve an Emberveil/Vanilla quest id from a retail quest title by matching
-- the data pack lookup: lookup[source][title] -> id, or
-- lookup[source][title][npcName] -> id / {questText -> id}.
function DataModules:GetQuestID(source, title, npcName, text)
    local cleanedTitle = replaceDoubleQuotes(title)
    local cleanedNPCName = replaceDoubleQuotes(npcName)
    local cleanedText = replaceDoubleQuotes(getFirstNWords(text, 15)) .. " " ..
        replaceDoubleQuotes(getLastNWords(text, 15))
    local text_entries = {}
    for _, m in ipairs(self:GetModules()) do
        local data = m.module.QuestIDLookup
        if data then
            local sourceLookup = data[source]
            if sourceLookup then
                local titleLookup = sourceLookup[cleanedTitle]
                if titleLookup then
                    if type(titleLookup) == "number" then
                        return titleLookup
                    end
                    local npcLookup = titleLookup[cleanedNPCName]
                    if npcLookup then
                        if type(npcLookup) == "number" then
                            return npcLookup
                        end
                        for questText, ID in pairs(npcLookup) do
                            text_entries[questText] = text_entries[questText] or ID
                        end
                    end
                end
            end
        end
    end
    if not next(text_entries) then
        return nil
    end
    local best = QuestEcho.FuzzySearchBestKeys(cleanedText, text_entries)
    return best and best[1] and best[1].value or nil
end

-- Resolve a quest display title on retail. GetQuestInfo() was renamed to
-- GetTitleForQuestID() in Shadowlands; both return a plain title string, but
-- a QuestInfo object is tolerated as well.
local function GetQuestTitle(questID)
    if not questID then return nil end
    local ret
    local ok = pcall(function()
        if C_QuestLog and C_QuestLog.GetTitleForQuestID then
            ret = C_QuestLog.GetTitleForQuestID(questID)
        elseif C_QuestLog and C_QuestLog.GetQuestInfo then
            ret = C_QuestLog.GetQuestInfo(questID)
        end
    end)
    if not ret and type(GetTitleText) == "function" then
        local okT, title = pcall(GetTitleText)
        if okT and type(title) == "string" and title ~= "" then
            ret = title
        end
    end
    if not ret and type(GetNumQuestLogEntries) == "function"
        and type(GetQuestLogTitle) == "function" and questID then
        local okN, n = pcall(GetNumQuestLogEntries)
        if okN and n then
            for i = 1, n do
                local qTitle, _lvl, _sg, isHeader, _col, _comp, _freq, qid =
                    GetQuestLogTitle(i)
                if not isHeader and qid == questID and qTitle and qTitle ~= "" then
                    ret = qTitle
                    break
                end
            end
        end
    end
    if not ok or ret == nil then return nil end
    if type(ret) == 'table' then
        return ret.title or ret.Title or ret.name or ret.Name
    end
    if ret == '' then return nil end
    return ret
end

local function getFileNameForEvent(event, questID)
    if event == Enums.SoundEvent.QuestAccept or event == Enums.SoundEvent.QuestDetail then
        return format("%d-accept", questID)
    elseif event == Enums.SoundEvent.QuestComplete then
        return format("%d-complete", questID)
    elseif event == Enums.SoundEvent.QuestProgress then
        return format("%d-progress", questID)
    elseif event == Enums.SoundEvent.QuestGreeting then
        return format("%d-greeting", questID)
    end
    return nil
end

-- Gender-prefixed filename variant (male/female voices).
function DataModules:AddPlayerGenderToFilename(fileName)
    local ok, gender = pcall(UnitSex, "player")
    if not ok then
        return fileName
    end
    if gender == 2 then
        return "m-" .. fileName
    elseif gender == 3 then
        return "f-" .. fileName
    end
    return fileName
end

-- Build a playable path + length for a sound, if any data pack knows this
-- voice line. Existence is decided by the sound-length table. All retail voice
-- files are shipped as .ogg (the game plays ogg/mp3, not wav).
function DataModules:PrepareSound(soundData)
    local baseName = soundData.fileName or getFileNameForEvent(soundData.event, soundData.questID)
    if not baseName then
        return false
    end
    for _, m in ipairs(self:GetModules()) do
        local module = m.module
        if self:IsActive(module) then
            local data = module.SoundLengthLookupByFileName
            if data then
                local gendered = self:AddPlayerGenderToFilename(baseName)
                local fileName = gendered
                local length = data[gendered]
                if not length then
                    fileName = baseName
                    length = data[baseName]
                end
                if length then
                    local folder = (soundData.event == Enums.SoundEvent.Gossip) and "gossip" or "quests"
                    local addonFolder = self.registeredAddonNames and self.registeredAddonNames[m.name] or m.name
                    local path = format("Interface\\AddOns\\%s\\generated\\sounds\\%s\\%s.ogg",
                        addonFolder, folder, fileName)
                    soundData.fileName = fileName
                    soundData.path = path
                    soundData.length = tonumber(length)
                    soundData.module = module
                    return true
                end
            end
        end
    end
    return false
end

function Utils:FileExists(relativePath)
    return false
end

-- Build a global file index from the data pack lookup tables (names known at
-- data load time), so PrepareSound can decide ogg vs wav without I/O.
function DataModules:BuildFileIndex()
    QuestEcho._fileIndex = QuestEcho._fileIndex or {}
    local idx = QuestEcho._fileIndex
    for _, m in ipairs(self:GetModules()) do
        local module = m.module
        if self:IsActive(module) and module.FileExtLookup then
            for k, ext in pairs(module.FileExtLookup) do
                idx[k] = ext
            end
        end
    end
end

-- Resolve the gossip voice file hash for the NPC the player is talking to.
-- Looks up by NPC id first (GossipLookupByNPCID), then by name
-- (GossipLookupByNPCName), across every loaded data pack.
function DataModules:GetNPCGossipHash(npcID, npcName, text)
    if not text or text == "" then return nil end
    local entries = {}
    for _, m in ipairs(self:GetModules()) do
        local mod = m.module
        if mod and self:IsActive(mod) then
            if npcID then
                local byID = mod.GossipLookupByNPCID
                if byID and byID[npcID] then
                    for t, h in pairs(byID[npcID]) do
                        entries[t] = entries[t] or h
                    end
                end
            end
            if npcName then
                local byName = mod.GossipLookupByNPCName
                if byName and byName[npcName] then
                    for t, h in pairs(byName[npcName]) do
                        entries[t] = entries[t] or h
                    end
                end
            end
        end
    end
    if not next(entries) then return nil end
    if entries[text] then return entries[text] end
    local best = QuestEcho.FuzzySearchBestKeys(text, entries)
    return best and best[1] and best[1].value or nil
end

-- Does the data pack have a voice file for (vanilla quest id, event)?
function DataModules:HasSound(vanillaID, event)
    local fileName = getFileNameForEvent(event, vanillaID)
    if not fileName then return false end
    for _, m in ipairs(self:GetModules()) do
        local module = m.module
        if self:IsActive(module) then
            local data = module.SoundLengthLookupByFileName
            if data then
                if data[fileName] then return true end
                local gendered = self:AddPlayerGenderToFilename(fileName)
                if data[gendered] then return true end
            end
        end
    end
    return false
end

-- =============================================================================
-- SoundQueue
-- =============================================================================
QuestEcho.SoundQueue = {}
local SoundQueue = QuestEcho.SoundQueue
-- Forward declaration: SoundQueue's methods (defined just below) call
-- SoundQueueUI:RebuildRows, but the UI block is constructed later in the file.
-- The local must be visible here, otherwise those methods resolve SoundQueueUI
-- as a nil global and the queue list never refreshes.
local SoundQueueUI

SoundQueue.sounds = {}
SoundQueue.current = nil

function SoundQueue:GetQueueSize()
    return #self.sounds
end

function SoundQueue:IsEmpty()
    return self.current == nil and #self.sounds == 0
end

function SoundQueue:IsPlaying()
    return self.current ~= nil and not Addon.db.char.IsPaused
end

function SoundQueue:AddSoundToQueue(soundData)
    if not soundData then return end
    local function fingerprint(s)
        if s.event == Enums.SoundEvent.Gossip then
            return "g:" .. tostring(s.fileName)
        end
        return "q:" .. tostring(s.event) .. ":" .. tostring(s.questID)
    end
    local fp = fingerprint(soundData)
    -- waiting queue: drop an exact duplicate so the same line never stacks
    for _, s in ipairs(self.sounds) do
        if fingerprint(s) == fp then
            Debug:Print("dedupe waiting %s", fp)
            return
        end
    end
    -- current line: debounce a rapid re-trigger within 2s; after that allow replay
    if self.current and fingerprint(self.current) == fp then
        local since = GetTime() - (self.current.startedAt or GetTime())
        if since < 2 then
            Debug:Print("dedupe current %s", fp)
            return
        end
    end
    soundData.queuedAt = GetTime()
    tinsert(self.sounds, soundData)
    Debug:Print("queued %s", tostring(soundData.fileName))
    if not self.current then
        self:PlayNextSound()
    end
    if SoundQueueUI and SoundQueueUI.RebuildRows then
        SoundQueueUI:RebuildRows()
    end
end

function SoundQueue:PlayNextSound()
    if Addon.db.char.IsPaused then
        return
    end
    self._gapUntil = nil
    local next = tremove(self.sounds, 1)
    if not next then
        self.current = nil
        if SoundQueueUI and SoundQueueUI.RebuildRows then
            SoundQueueUI:RebuildRows()
        end
        return
    end
    self.current = next
    next.startedAt = GetTime()
    next._heard = false
    next._lastHeard = nil
    next._pausePos = nil
    next._watchPos = nil
    next._stallT = nil
    next._restarts = 0
    Utils:PlaySound(next)
    Debug:Print("playing %s", tostring(next.fileName or next.path))
    if SoundQueueUI then
        SoundQueueUI:RebuildRows()
    end
end

function SoundQueue:OnUpdate()
    local now = GetTime()
    local delta = self._lastTick and (now - self._lastTick) or 0
    self._lastTick = now

    local cur = self.current
    if not cur then
        if #self.sounds > 0 then
            local gap = tonumber(Addon.db.profile.QueueGap) or 0
            if self._gapUntil and now < self._gapUntil then
                return -- silence between voices
            end
            self:PlayNextSound()
        end
        return
    end
    if Addon.db.char.IsPaused then
        return
    end

    local elapsed = now - (cur.startedAt or now)
    local length = cur.length or 0

    -- Watchdog for OS window suspension: while tabbed out the playing handle
    -- can freeze and stay silent after returning. Only run while the client is
    -- actively rendering (small frame delta) so background throttling never
    -- restarts audio; once back in the foreground, a frozen line is restarted
    -- within ~0.8s. Seek is unsupported, so it restarts from the beginning and
    -- the caption timer resets to stay in sync.
    if cur.handle and length > 0 and elapsed > 1.5 and elapsed < length - 0.5 then
        if delta < 0.2 then
            local advancing = false
            local pos = Utils:GetPlayPosition(cur)
            if pos then
                if cur._watchPos == nil or math.abs(pos - cur._watchPos) > 0.05 then
                    cur._watchPos = pos
                    advancing = true
                end
            elseif C_Sound and type(C_Sound.IsPlaying) == "function" then
                local okP, playing = pcall(C_Sound.IsPlaying, cur.handle)
                if okP and playing then advancing = true end
            end
            if advancing then
                cur._stallT = nil
            elseif not cur._stallT then
                cur._stallT = now
            elseif (cur._restarts or 0) < 2 and now - cur._stallT > 0.8 then
                Utils:StopSound(cur)
                Utils:PlaySound(cur)
                cur.startedAt = GetTime()
                cur._watchPos = nil
                cur._stallT = nil
                cur._restarts = (cur._restarts or 0) + 1
            end
        else
            -- large frame gap (background / loading screen): don't accumulate
            -- stall time and don't fast-forward
            cur._stallT = nil
            cur._watchPos = nil
        end
    end

    local finished = false
    if length > 0 then
        -- Trust the data pack's exact line duration. Never end a line from
        -- C_Sound.IsPlaying returning false: background throttling reports
        -- not-playing and used to drain the whole queue while tabbed out.
        finished = elapsed >= length
    elseif cur.handle and C_Sound and type(C_Sound.IsPlaying) == "function" then
        -- Fallback only for a line with no known duration.
        local ok, playing = pcall(C_Sound.IsPlaying, cur.handle)
        if ok and playing then
            cur._heard = true
            cur._lastHeard = now
        elseif cur._heard and elapsed > 0.5
            and (not cur._lastHeard or (now - cur._lastHeard) > 0.4) then
            finished = true
        end
    end

    if finished then
        Utils:StopSound(cur)
        self.current = nil
        if #self.sounds > 0 then
            local gap = tonumber(Addon.db.profile.QueueGap) or 0
            if gap > 0 then self._gapUntil = GetTime() + gap end
        end
        -- Honor the gap: let OnUpdate start the next line instead of playing now.
        if SoundQueueUI and SoundQueueUI.RebuildRows then
            SoundQueueUI:RebuildRows()
        end
    end
end

function SoundQueue:PauseQueue()
    -- Remember where the line was (real engine position when available), then
    -- stop it. If the line is essentially over (<1s left) just let it finish.
    local cur = self.current
    if cur and cur.startedAt and cur.length and cur.length > 0 then
        local pos = Utils:GetPlayPosition(cur)
        if not pos then pos = GetTime() - cur.startedAt end
        cur._pausePos = pos
        if cur.length - pos < 1.0 then
            cur._pausePos = nil
            return
        end
    end
    Addon.db.char.IsPaused = true
    if cur then
        Utils:StopSound(cur)
    end
    if SoundQueueUI then SoundQueueUI:RebuildRows() end
end

function SoundQueue:ResumeQueue()
    Addon.db.char.IsPaused = false
    local cur = self.current
    if cur then
        local pos = (Utils:CanSeek() and cur._pausePos) or 0
        Utils:PlaySoundAt(cur, pos)
        if Utils:CanSeek() and pos and pos > 0.1 then
            -- resume from the saved position so captions/progress line up
            cur.startedAt = GetTime() - pos
        else
            -- Retail has no seek API: the interrupted line replays from its
            -- start; reset its clock so captions stay in sync with the audio.
            cur.startedAt = GetTime()
        end
        cur._pausePos = nil
        cur._watchPos = nil
        cur._stallT = nil
    else
        self:PlayNextSound()
    end
    if SoundQueueUI then SoundQueueUI:RebuildRows() end
end

function SoundQueue:TogglePauseQueue()
    if Addon.db.char.IsPaused then
        self:ResumeQueue()
    else
        self:PauseQueue()
    end
end

function SoundQueue:RemoveSound(id)
    if self.current and self.current.id == id then
        Utils:StopSound(self.current)
        self.current = nil
        self:PlayNextSound()
        if SoundQueueUI then SoundQueueUI:RebuildRows() end
        return
    end
    for i = #self.sounds, 1, -1 do
        if self.sounds[i].id == id then
            tremove(self.sounds, i)
            break
        end
    end
    if SoundQueueUI then SoundQueueUI:RebuildRows() end
end

function SoundQueue:RemoveAllSoundsFromQueue()
    for _, s in ipairs(self.sounds) do
        Utils:StopSound(s)
    end
    self.sounds = {}
    if self.current then
        Utils:StopSound(self.current)
        self.current = nil
    end
    if SoundQueueUI then SoundQueueUI:RebuildRows() end
end

-- =============================================================================
-- SoundQueueUI: status bar + queue rows + progress + captions
-- =============================================================================
QuestEcho.SoundQueueUI = {}
SoundQueueUI = QuestEcho.SoundQueueUI

local FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
local UI_GOLD_TEXT   = { 1.0, 0.82, 0.0 }
local UI_GOLD_DARK   = { 0.6, 0.5, 0.2 }
local UI_GREY_TOP    = { 0.25, 0.22, 0.18 }
local UI_GREY_BOTTOM = { 0.08, 0.07, 0.06 }
local QUEUE_ROW_HEIGHT = 20

-- Hidden FontString used to measure real caption pixel widths (character-count
-- estimates overflow the 308px caption line and get truncated to ellipsis).
local captionMeasurer = nil
local CAPTION_MAX_WIDTH = 300

local function ColorForEvent(event)
    if event == "gossip" then
        return "|cff7fff7f"
    elseif event == "complete" then
        return "|cff66ccff"
    end
    return "|cffffd24a"
end

local function FormatStatus()
    local cur = SoundQueue.current
    if not cur then
        return L("Ready", "就绪")
    end
    local label = cur.title or cur.name or cur.fileName or "?"
    if Addon.db.char.IsPaused then
        return format("|cffcccccc%s|r (%s)", label, L("paused", "已暂停"))
    end
    local elapsed = GetTime() - (cur.startedAt or 0)
    local length = cur.length or 0
    local pct = (length > 0) and floor(min(1, max(0, elapsed / length)) * 100) or 0
    return format("%s %d%%", label, pct)
end

function SoundQueueUI:ApplySavedPos()
    local pos = Addon.db.char.Pos
    self.frame:ClearAllPoints()
    -- Bar is anchored at its bottom centre and grows upward. Only v==2
    -- positions are bottom offsets; older centre-offset saves are discarded.
    if pos and pos.x and pos.v == 2 then
        self.frame:SetPoint("BOTTOM", UIParent, "BOTTOM", pos.x, pos.y)
    else
        self.frame:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 180)
    end
end

-- Click helper: 12.1 input changes can swallow OnClick on some widgets, so a
-- single OnClick is registered with errors printed for visibility. (Dual
-- OnMouseDown+OnClick registration flips toggle buttons twice on a held press,
-- so only OnClick is used — AIQuestVoices/ChattyLittleNpc do the same.)
local function AddClickFallback(button, fn)
    button._qeClick = fn
    button:SetScript("OnClick", function(self)
        local f = self._qeClick
        if f then
            local ok, err = pcall(f, self)
            if not ok then
                Print("[QuestEcho] click error: " .. tostring(err))
            end
        end
    end)
end

-- Template button with the click fallback. Uses UIPanelButtonTemplate for the
-- classic WoW look; the click helper guarantees it responds on 12.1.
local function MakeButton(parent, w, h, text, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h)
    b:EnableMouse(true)
    b:RegisterForClicks("LeftButtonUp")
    b:SetText(text or "")
    AddClickFallback(b, onClick)
    return b
end

-- CheckButton: Blizzard's InterfaceOptionsCheckButtonTemplate (the same
-- template ChattyLittleNpc uses on retail 12.1 — verified working). The
-- OnClick reverts to the stored value before writing, exactly like
-- ChattyLittleNpc's ConfigSystem:CreateCheckbox, which makes double-toggling
-- impossible and keeps the box in sync with the db.
local function MakeCheck(parent, x, y, text, getter, setter, extra)
    local c = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
    c:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    local ctext = c.Text or c.text
    if not ctext then
        ctext = c:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        ctext:SetPoint("LEFT", c, "RIGHT", 4, 0)
    end
    c.Text = ctext
    ctext:SetText(text)
    pcall(ctext.SetFontObject, ctext, GameFontNormal)
    ctext:SetJustifyH("LEFT")
    c:SetScript("OnClick", function(self)
        local checked = self:GetChecked()
        setter(checked)
        self:SetChecked(getter())
        if extra then extra() end
    end)
    c:SetChecked(getter())
    return c
end

function SoundQueueUI:Create()
    local frame = CreateFrame("Frame", "QuestEchoStatusFrame", UIParent)
    self.frame = frame
    frame:SetSize(360, 40)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(f)
        if IsShiftDown() then
            f:StartMoving()
        end
    end)
    frame:SetScript("OnDragStop", function(f)
        f:StopMovingOrSizing()
        -- Anchor by the BOTTOM centre so the bar grows upward as queue rows
        -- appear; store the bottom-centre offset from UIParent's bottom centre.
        local fl, fr, fb = f:GetLeft(), f:GetRight(), f:GetBottom()
        local pl, pr, pb = UIParent:GetLeft(), UIParent:GetRight(), UIParent:GetBottom()
        if fl and fr and fb and pl and pr and pb then
            Addon.db.char.Pos = { x = (fl + fr) / 2 - (pl + pr) / 2, y = fb - pb, v = 2 }
            QuestEchoDB = Addon.db
        end
    end)

    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.72)
    frame.bg = bg

    -- gold trim along the top of the fixed header (header stays at the bottom
    -- because the bar grows upward)
    local trim = frame:CreateTexture(nil, "BORDER")
    trim:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 38)
    trim:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 38)
    trim:SetHeight(2)
    trim:SetColorTexture(UI_GOLD_TEXT[1], UI_GOLD_TEXT[2], UI_GOLD_TEXT[3], 0.9)
    frame.trim = trim

    -- status text
    local status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    status:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 8, 19)
    status:SetWidth(250)
    status:SetHeight(16)
    status:SetJustifyH("LEFT")
    status:SetJustifyV("MIDDLE")
    pcall(status.SetFont, status, FONT, 12)
    self.status = status

    -- top-right button cluster (matches the Emberveil bar layout):
    -- clear(X) at the far right, pause(II) beside it, settings beside that.
    local clear = MakeButton(frame, 24, 18, "X", function()
        SoundQueue:RemoveAllSoundsFromQueue()
    end)
    clear:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 19)
    self.clearBtn = clear

    local pause = MakeButton(frame, 24, 18, "II", function()
        SoundQueue:TogglePauseQueue()
    end)
    pause:SetPoint("BOTTOMRIGHT", clear, "BOTTOMLEFT", -2, 0)
    self.pauseBtn = pause

    -- settings button (OptionsUI is declared later in the file, so resolve it
    -- through the global namespace at click time)
    local gear = MakeButton(frame, 48, 18, L("Settings", "设置"), function()
        local O = QuestEcho.OptionsUI
        if O and O.Toggle then
            pcall(O.Toggle, O)
        else
            Print("[QuestEcho] settings unavailable")
        end
    end)
    gear:SetPoint("BOTTOMRIGHT", pause, "BOTTOMLEFT", -2, 0)
    self.gear = gear


    -- progress bar
    local progBg = frame:CreateTexture(nil, "ARTWORK")
    progBg:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 8, 15)
    progBg:SetSize(340, 3)
    progBg:SetColorTexture(0.1, 0.1, 0.1, 1)
    self.progBg = progBg
    local progFill = frame:CreateTexture(nil, "ARTWORK")
    progFill:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 8, 15)
    progFill:SetSize(0, 3)
    progFill:SetColorTexture(UI_GOLD_TEXT[1], UI_GOLD_TEXT[2], UI_GOLD_TEXT[3], 0.9)
    self.progFill = progFill

    -- caption lines (up to 8, one line each; multi-line \n is unreliable)
    self.captionLines = {}
    for i = 1, 8 do
        local line = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        line:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 8, 4 + (i - 1) * 13)
        line:SetWidth(308)
        line:SetHeight(16)
        line:SetJustifyH("LEFT")
        pcall(line.SetFont, line, FONT, 12)
        line:SetShadowColor(0, 0, 0, 1)
        line:SetShadowOffset(1, -1)
        self.captionLines[i] = line
    end

    captionMeasurer = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    pcall(captionMeasurer.SetFont, captionMeasurer, FONT, 12)
    captionMeasurer:Hide()

    -- queue rows
    self.rows = {}
    for i = 1, 6 do
        local row = CreateFrame("Frame", nil, frame)
        row:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 8, 42 + (i - 1) * QUEUE_ROW_HEIGHT)
        row:SetSize(344, QUEUE_ROW_HEIGHT - 2)
        local bgRow = row:CreateTexture(nil, "BACKGROUND")
        bgRow:SetAllPoints()
        bgRow:SetColorTexture(0, 0, 0, 0.4)
        row.rowBg = bgRow
        local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        label:SetPoint("LEFT", row, "LEFT", 4, 0)
        label:SetWidth(290)
        label:SetHeight(14)
        label:SetJustifyH("LEFT")
        pcall(label.SetFont, label, FONT, 11)
        row.label = label
        local x = CreateFrame("Button", nil, row, "UIPanelCloseButton")
        x:SetSize(14, 14)
        x:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        x:EnableMouse(true)
        AddClickFallback(x, function()
            if row.soundId then
                SoundQueue:RemoveSound(row.soundId)
            end
        end)
        row.xButton = x
        self.rows[i] = row
    end

    -- update ticker
    frame:SetScript("OnUpdate", function()
        SoundQueue:OnUpdate()
        self:UpdateProgress()
        self:UpdateCaption()
    end)

    self:ApplyLayout()
    self:ApplySavedPos()
    self:Update()
end

-- Reposition header widgets and queue rows for the chosen grow direction. The
-- frame is always anchored by its bottom centre; "up" pins the header to the
-- bottom and stacks rows above it, "down" puts the header on top (it rises as
-- the frame grows) with rows stacked beneath it.
function SoundQueueUI:ApplyLayout()
    local f = self.frame
    if not f or not self.rows then return end
    local grow = (Addon.db.profile.QueueGrow == "up") and "up" or "down"
    self.grow = grow
    local trim, status = f.trim, self.status
    local clear, pause, gear = self.clearBtn, self.pauseBtn, self.gear
    local progBg, progFill = self.progBg, self.progFill
    if grow == "up" then
        trim:ClearAllPoints()
        trim:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 38)
        trim:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 38)
        status:ClearAllPoints(); status:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8, 19)
        clear:ClearAllPoints();  clear:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, 19)
        pause:ClearAllPoints();  pause:SetPoint("BOTTOMRIGHT", clear, "BOTTOMLEFT", -2, 0)
        gear:ClearAllPoints();   gear:SetPoint("BOTTOMRIGHT", pause, "BOTTOMLEFT", -2, 0)
        progBg:ClearAllPoints();   progBg:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8, 15)
        progFill:ClearAllPoints(); progFill:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8, 15)
        for i = 1, #self.rows do
            self.rows[i]:ClearAllPoints()
            self.rows[i]:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8, 42 + (i - 1) * QUEUE_ROW_HEIGHT)
        end
    else
        trim:ClearAllPoints()
        trim:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
        trim:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
        status:ClearAllPoints(); status:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -5)
        clear:ClearAllPoints();  clear:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -3)
        pause:ClearAllPoints();  pause:SetPoint("TOPRIGHT", clear, "TOPLEFT", -2, 0)
        gear:ClearAllPoints();   gear:SetPoint("TOPRIGHT", pause, "TOPLEFT", -2, 0)
        progBg:ClearAllPoints();   progBg:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -22)
        progFill:ClearAllPoints(); progFill:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -22)
        for i = 1, #self.rows do
            self.rows[i]:ClearAllPoints()
            self.rows[i]:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -28 - (i - 1) * QUEUE_ROW_HEIGHT)
        end
    end
end

function SoundQueueUI:Update()
    local show = Addon.db.profile.ShowUI
    if show then
        self.frame:Show()
        self:ApplySavedPos()
    else
        self.frame:Hide()
    end
    self:RebuildRows()
end

function SoundQueueUI:UpdateProgress()
    local cur = SoundQueue.current
    local pct = 0
    if cur and cur.length and cur.length > 0 and cur.startedAt then
        pct = min(1, max(0, (GetTime() - cur.startedAt) / cur.length))
    end
    self.progFill:SetWidth(floor(340 * pct))
    self.status:SetText(format("|cffffd200%s|r %s", "QuestEcho", FormatStatus()))
end

-- ---- caption wrapping (real pixel measurement) -----------------------------
local function CaptionTextWidth(s)
    if s == nil or s == "" then return 0 end
    if captionMeasurer then
        captionMeasurer:SetText(s)
        local w = captionMeasurer:GetStringWidth()
        if w then return w end
    end
    -- fallback rough estimate (should not normally be hit)
    local w = 0
    for i = 1, #s do
        local b = s:byte(i)
        w = w + ((b and b >= 0x80) and 12 or 6.5)
    end
    return w
end

-- Split a sentence into breakable tokens: CJK characters are individually
-- breakable; ASCII words stay intact; spaces are breakable glue.
local function TokenizeForWrap(s)
    local tokens = {}
    local i, n = 1, #s
    while i <= n do
        local b = s:byte(i)
        if not b then break end
        if b < 0x80 then
            local ch = s:sub(i, i)
            if ch == " " then
                tokens[#tokens + 1] = { t = " ", br = true }
                i = i + 1
            else
                local j = i
                while j <= n do
                    local b2 = s:byte(j)
                    if not b2 or b2 >= 0x80 or s:sub(j, j) == " " then break end
                    j = j + 1
                end
                tokens[#tokens + 1] = { t = s:sub(i, j - 1), br = false }
                i = j
            end
        else
            local clen = 1
            if b >= 0xF0 then clen = 4
            elseif b >= 0xE0 then clen = 3
            elseif b >= 0xC0 then clen = 2 end
            tokens[#tokens + 1] = { t = s:sub(i, i + clen - 1), br = true }
            i = i + clen
        end
    end
    return tokens
end

-- Greedily pack tokens into lines no wider than maxWidth (real pixels).
local function WrapSentencePixels(sent, maxWidth)
    local tokens = TokenizeForWrap(sent)
    local lines = {}
    local line = ""
    for _, tok in ipairs(tokens) do
        local cand = line .. tok.t
        if CaptionTextWidth(cand) <= maxWidth then
            line = cand
        elseif tok.br then
            if line:gsub("%s", "") ~= "" then lines[#lines + 1] = line end
            line = (tok.t == " ") and "" or tok.t
        else
            if line == "" then
                -- one unbreakable word wider than the line: hard-split it
                local piece = ""
                for k = 1, #tok.t do
                    local c = tok.t:sub(k, k)
                    if piece ~= "" and CaptionTextWidth(piece .. c) > maxWidth then
                        lines[#lines + 1] = piece
                        piece = c
                    else
                        piece = piece .. c
                    end
                end
                line = piece
            else
                lines[#lines + 1] = line
                line = tok.t
            end
        end
    end
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" then lines[#lines + 1] = line end
    return lines
end

-- Split text into sentences (ASCII terminators + newlines) then wrap each by
-- real pixel width. CJK terminators are multi-byte and are treated as ordinary
-- breakable characters by the tokenizer, which is sufficient for wrapping.
local function CaptionHeroName()
    local loc = GetLocale and GetLocale() or "enUS"
    return (loc:sub(1, 2) == "zh") and L("adventurer", "勇士") or "adventurer"
end

local function WrapCaption(s)
    s = tostring(s or "")
    s = s:gsub("%$B%$B", "\n"):gsub("%$b%$b", "\n")
    s = s:gsub("%$B", "\n"):gsub("%$b", "\n")
    -- never read the player's real name aloud/in captions
    s = s:gsub("%$[Nn]", CaptionHeroName())
    local lines = {}
    local function Emit(chunk)
        chunk = chunk:gsub("^%s+", ""):gsub("%s+$", "")
        if chunk == "" then return end
        for _, l in ipairs(WrapSentencePixels(chunk, CAPTION_MAX_WIDTH)) do
            lines[#lines + 1] = l
        end
    end
    local sent = ""
    for i = 1, #s do
        local c = s:sub(i, i)
        sent = sent .. c
        if c == "." or c == "!" or c == "?" or c == "\n" then
            Emit(sent)
            sent = ""
        end
    end
    Emit(sent)
    return table.concat(lines, "\n")
end

function SoundQueueUI:UpdateCaption()
    if not self.captionLines then return end
    local lines = {}
    if Addon.db.profile.Captions then
        local cur = SoundQueue.current
        local body = nil
        if cur then
            body = cur.text
            if (not body or body == "") and cur.textByID then
                body = tostring(cur.textByID.D or "")
            end
        end
        if cur and cur.questID and body and body ~= "" then
            local wrapped = {}
            for part in WrapCaption(body):gmatch("[^\n]+") do
                wrapped[#wrapped + 1] = part
            end
            local total = #wrapped
            if total > 0 then
                local totalWords = 0
                local lineWords = {}
                for idx = 1, total do
                    local n = 0
                    for _ in wrapped[idx]:gmatch("%S+") do n = n + 1 end
                    if n <= 1 then
                        n = 0
                        for i2 = 1, #wrapped[idx] do
                            local b = wrapped[idx]:byte(i2)
                            n = n + ((b and b >= 0x80) and 2 or 1)
                        end
                    end
                    lineWords[idx] = n
                    totalWords = totalWords + n
                end
                local curIdx = 1
                if cur.startedAt and cur.length and cur.length > 0.5 then
                    local elapsed = GetTime() - cur.startedAt
                    local isZh = (GetLocale() or "enUS"):sub(1, 2) == "zh"
                    local lead = isZh and 0.3 or 0.2
                    local dur = (cur.length - lead) * (isZh and 1.06 or 1.0)
                    local adj = (elapsed - lead) / dur
                    adj = max(0, min(1, adj))
                    local target = adj * totalWords
                    local acc = 0
                    curIdx = total
                    for idx = 1, total do
                        acc = acc + lineWords[idx]
                        if acc >= target then
                            curIdx = idx
                            break
                        end
                    end
                end
                lines[#lines + 1] = wrapped[curIdx]
            end
        end
    end
    for i = 1, 8 do
        self.captionLines[i]:SetText(lines[i] or "")
    end
end

function SoundQueueUI:RebuildRows()
    local frame = self.frame
    if not frame then return end
    local items = {}
    if SoundQueue.current then
        tinsert(items, { sound = SoundQueue.current, playing = true })
    end
    for _, sound in ipairs(SoundQueue.sounds) do
        tinsert(items, { sound = sound, playing = false })
    end
    local shown = min(#items, #self.rows)
    local ok, err = pcall(function()
        for i = 1, #self.rows do
            local row = self.rows[i]
            local entry = items[i]
            if not entry then
                row:Hide()
                row.soundId = nil
            else
                row:Show()
                row.soundId = entry.sound.id
                row.xButton:Show()
                local sound = entry.sound
                local labelText = sound.title or sound.name or sound.fileName or "?"
                if entry.playing then
                    local state = Addon.db.char.IsPaused and L("(paused)", "(已暂停)") or L("(playing)", "(播放中)")
                    row.label:SetText(format("|cffffd24a>|r %s%s|r  |cffcccccc%s|r", ColorForEvent(sound.event), labelText, state))
                else
                    row.label:SetText(format("%s%s|r", ColorForEvent(sound.event), labelText))
                end
            end
        end
    end)
    if not ok then Debug:Print("RebuildRows ERR: %s", tostring(err)) end
    frame:SetHeight(40 + shown * QUEUE_ROW_HEIGHT)
end

function SoundQueueUI:Toggle()
    Addon.db.profile.ShowUI = not Addon.db.profile.ShowUI
    self:Update()
end

-- =============================================================================
-- OptionsUI
-- =============================================================================
QuestEcho.OptionsUI = {}
local OptionsUI = QuestEcho.OptionsUI

function OptionsUI:ApplySavedPos()
    local pos = Addon.db.char.OptPos
    if not pos or not pos.x then
        self.frame:ClearAllPoints()
        self.frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        return
    end
    self.frame:ClearAllPoints()
    self.frame:SetPoint("CENTER", UIParent, "CENTER", pos.x, pos.y)
end

function OptionsUI:Create()
    -- Native WoW window: BackdropTemplate + Tooltip frame textures, the same
    -- pattern ChattyLittleNpc's SettingsWindow uses on retail 12.1.
    local frame = CreatePanelFrame("QuestEchoOptionsFrame", UIParent)
    self.frame = frame
    frame:SetSize(300, 414)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    if frame._qeHasBackdrop then
        frame:SetBackdrop({
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile     = true, tileSize = 16, edgeSize = 16,
            insets   = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        frame:SetBackdropColor(0.05, 0.05, 0.08, 0.97)
        frame:SetBackdropBorderColor(0.25, 0.22, 0.20, 0.80)
    end
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(f)
        if IsShiftDown() then
            f:StartMoving()
        end
    end)
    frame:SetScript("OnDragStop", function(f)
        f:StopMovingOrSizing()
        local x, y = f:GetCenter()
        local ux, uy = UIParent:GetCenter()
        -- UI-space offset from the UIParent centre; same space as SetPoint.
        Addon.db.char.OptPos = { x = x - ux, y = y - uy }
        QuestEchoDB = Addon.db
    end)
    frame:SetClampedToScreen(true)
    tinsert(UISpecialFrames, "QuestEchoOptionsFrame")

    -- title
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", frame, "TOP", 0, -8)
    title:SetText("QuestEcho " .. L("Settings", "设置"))
    title:SetTextColor(1.0, 0.82, 0.0)

    -- close (X)
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
    close:SetSize(26, 26)
    close:EnableMouse(true)
    AddClickFallback(close, function()
        self:Hide()
    end)
    self.close = close

    -- voice language selector: lets an English client hear Chinese and vice
    -- versa, independent of the client language.
    local langLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    langLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -34)
    langLabel:SetText(L("Voice language", "语音语言"))
    langLabel:SetTextColor(1, 0.82, 0)

    local LANGS = {
        ["auto"] = L("Auto (client language)", "自动（跟随客户端）"),
        ["enUS"] = L("English", "英语"),
        ["zhCN"] = L("Chinese", "中文"),
    }
    local langDropdown = CreateFrame("Frame", "QuestEchoLangDropdown", frame, "UIDropDownMenuTemplate")
    langDropdown:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -56)
    UIDropDownMenu_SetWidth(langDropdown, 184)
    UIDropDownMenu_SetText(langDropdown, LANGS[Addon.db.profile.VoiceLang] or LANGS.auto)
    UIDropDownMenu_Initialize(langDropdown, function(_, level)
        local info = UIDropDownMenu_CreateInfo()
        for value, label in pairs(LANGS) do
            info.text = label
            info.value = value
            info.func = function(btn)
                Addon.db.profile.VoiceLang = value
                UIDropDownMenu_SetText(langDropdown, btn:GetText())
                if RefreshQuestEchoButtons then pcall(RefreshQuestEchoButtons) end
            end
            info.checked = (value == (Addon.db.profile.VoiceLang or "auto"))
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    self.langDropdown = langDropdown

    -- audio channel dropdown (native UIDropDownMenu).
    local chLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    chLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -98)
    chLabel:SetText(L("Audio channel", "音频通道"))
    chLabel:SetTextColor(1, 0.82, 0)

    local CHANNELS = {
        ["MASTER"]   = L("Master", "主音量"),
        ["DIALOG"]   = L("Dialog", "对话"),
        ["SFX"]      = L("Sound Effects", "音效"),
        ["MUSIC"]    = L("Music", "音乐"),
        ["AMBIENCE"] = L("Ambience", "环境"),
    }
    local dropdown = CreateFrame("Frame", "QuestEchoChannelDropdown", frame, "UIDropDownMenuTemplate")
    dropdown:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -120)
    UIDropDownMenu_SetWidth(dropdown, 184)
    UIDropDownMenu_SetText(dropdown, CHANNELS[Addon.db.profile.AudioChannel] or "Master")
    UIDropDownMenu_Initialize(dropdown, function(self, level)
        local info = UIDropDownMenu_CreateInfo()
        for value, label in pairs(CHANNELS) do
            info.text = label
            info.value = value
            info.func = function(self2)
                Addon.db.profile.AudioChannel = self2.value
                UIDropDownMenu_SetText(dropdown, self2:GetText())
            end
            info.checked = (value == Addon.db.profile.AudioChannel)
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    self.channelDropdown = dropdown

    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hint:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -160)
    hint:SetWidth(270)
    hint:SetJustifyH("LEFT")
    hint:SetTextColor(0.7, 0.7, 0.7)
    hint:SetText(L("Voice volume follows the selected channel's volume slider in the game Sound options.", "语音音量跟随游戏声音设置中对应通道的音量滑条。"))
    pcall(hint.SetFont, hint, FONT, 11)

    -- captions checkbox
    local capCheck = MakeCheck(frame, 16, -188, L("Show captions", "显示字幕"),
        function() return Addon.db.profile.Captions end,
        function(v) Addon.db.profile.Captions = v end)
    self.capCheck = capCheck

    -- detail voice checkbox
    local detCheck = MakeCheck(frame, 16, -218, L("Play quest detail voice", "播放任务详情语音"),
        function() return Addon.db.profile.QuestDetail end,
        function(v) Addon.db.profile.QuestDetail = v end)
    self.detCheck = detCheck

    -- status bar toggle
    local uiCheck = MakeCheck(frame, 16, -248, L("Show status bar", "显示状态栏"),
        function() return Addon.db.profile.ShowUI end,
        function(v) Addon.db.profile.ShowUI = v end,
        function() SoundQueueUI:Update() end)
    self.uiCheck = uiCheck

    -- test voice button (TestPlay is declared later in the file; resolve at
    -- click time through the global namespace)
    local testBtn = MakeButton(frame, 140, 22, L("Test voice", "测试语音"), function()
        local tp = QuestEcho.TestPlay
        if tp then
            pcall(tp)
        else
            Print("[QuestEcho] test unavailable")
        end
    end)
    testBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -278)
    self.testBtn = testBtn

    -- queue grow direction
    local growLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    growLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -312)
    growLabel:SetText(L("Queue grows", "队列展开方向"))
    growLabel:SetTextColor(1, 0.82, 0)

    local GROWS = {
        ["down"] = L("Down (header moves up)", "向下（标题栏上移）"),
        ["up"]   = L("Up (header fixed)", "向上（标题栏固定）"),
    }
    local growDropdown = CreateFrame("Frame", "QuestEchoGrowDropdown", frame, "UIDropDownMenuTemplate")
    growDropdown:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -334)
    UIDropDownMenu_SetWidth(growDropdown, 184)
    UIDropDownMenu_SetText(growDropdown, GROWS[Addon.db.profile.QueueGrow] or GROWS.down)
    UIDropDownMenu_Initialize(growDropdown, function(_, level)
        local info = UIDropDownMenu_CreateInfo()
        for value, label in pairs(GROWS) do
            info.text = label
            info.value = value
            info.func = function(btn)
                Addon.db.profile.QueueGrow = value
                UIDropDownMenu_SetText(growDropdown, btn:GetText())
                if SoundQueueUI then
                    SoundQueueUI:ApplyLayout()
                    SoundQueueUI:RebuildRows()
                end
            end
            info.checked = (value == Addon.db.profile.QueueGrow)
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    self.growDropdown = growDropdown

    -- silence between consecutive voices
    local gapSlider = CreateFrame("Slider", "QuestEchoGapSlider", frame, "OptionsSliderTemplate")
    gapSlider:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -372)
    gapSlider:SetWidth(264)
    gapSlider:SetMinMaxValues(0, 10)
    gapSlider:SetValueStep(1)
    pcall(gapSlider.SetObeyStepOnDrag, gapSlider, true)
    gapSlider:SetValue(tonumber(Addon.db.profile.QueueGap) or 2)
    _G[gapSlider:GetName() .. "Text"]:SetText(L("Gap between voices (sec)", "语音间隔（秒）"))
    _G[gapSlider:GetName() .. "Low"]:SetText("0")
    _G[gapSlider:GetName() .. "High"]:SetText("10")
    gapSlider:SetScript("OnValueChanged", function(_, value)
        Addon.db.profile.QueueGap = value
    end)
    self.gapSlider = gapSlider

    self:ApplySavedPos()
    frame:Hide()
end

function OptionsUI:Toggle()
    if not self.frame then
        local ok, err = pcall(function() self:Create() end)
        if not ok then
            Print("[QuestEcho] options create error: " .. tostring(err))
            return false
        end
    end
    if self.frame:IsShown() then
        self:Hide()
        return false
    end
    self.frame:Show()
    self:ApplySavedPos()
    return true
end

function OptionsUI:Hide()
    if self.frame then self.frame:Hide() end
end

-- =============================================================================
-- Quest triggering (retail events)
-- =============================================================================

-- Build a soundData for an Emberveil/Vanilla quest id. PrepareSound fills
-- fileName/path/length when the data pack actually has a voice file.
local function MakeQuestSound(vanillaID, event, title)
    if not vanillaID then return nil end
    local soundData = {
        id = tostring(vanillaID) .. "-" .. tostring(event) .. "-" .. tostring(GetTime()),
        questID = vanillaID,
        event = event,
        title = title,
    }
    if not DataModules:PrepareSound(soundData) then
        return nil
    end
    local qm = soundData.module
    if qm and qm.QuestTextByID and qm.QuestTextByID[vanillaID] then
        soundData.textByID = qm.QuestTextByID[vanillaID]
    end
    return soundData
end

-- Resolve retail questID -> vanilla id via title match, then queue the voice
-- line. Returns true when a line was queued.
-- Live NPC text shown in the quest panel for the current phase. The data pack
-- only stores the accept/description body, so complete lines must be read from
-- the open QUEST_COMPLETE panel (GetRewardText); this also localises captions
-- to the client language.
local function GetPanelQuestText(event)
    local fn = nil
    if event == Enums.SoundEvent.QuestComplete then
        fn = GetRewardText
    elseif event == Enums.SoundEvent.QuestDetail
        or event == Enums.SoundEvent.QuestAccept then
        fn = GetQuestText
    elseif event == Enums.SoundEvent.QuestProgress then
        fn = GetProgressText
    elseif event == Enums.SoundEvent.QuestGreeting then
        fn = GetGreetingText
    end
    if fn then
        local ok, txt = pcall(fn)
        if ok and type(txt) == "string" and txt ~= "" then
            return txt
        end
    end
    return nil
end

local function QueueQuestVoice(clientQuestID, event, titleOverride, textOverride)
    if not clientQuestID then return false end
    local title = titleOverride
    if not title then
        title = GetQuestTitle(clientQuestID)
    end
    -- a detail line shares the accept voice file (x-accept.ogg)
    local lookupSource = event
    if event == Enums.SoundEvent.QuestDetail then
        lookupSource = Enums.SoundEvent.QuestAccept
    end
    -- Fast path: on classic-flavour clients (and for classic-era quests on
    -- retail) the client's questID IS the data-pack vanilla id. This avoids the
    -- title lookup that misses most quests; the title match stays as a fallback
    -- for retail remade quests.
    local vanillaID = nil
    if DataModules:HasSound(clientQuestID, lookupSource) then
        vanillaID = clientQuestID
    elseif title then
        vanillaID = DataModules:GetQuestID(lookupSource, title)
    end
    if not vanillaID then
        Debug:Print("no voice id for quest %s (%s)", tostring(clientQuestID), tostring(title))
        return false
    end
    local soundData = MakeQuestSound(vanillaID, event, title)
    if not soundData then
        Debug:Print("no voice file for %d-%s", vanillaID, tostring(event))
        return false
    end
    local body = textOverride or GetPanelQuestText(event)
    if body and body ~= "" then
        soundData.text = body
    end
    SoundQueue:AddSoundToQueue(soundData)
    return true
end

-- ---- missing-voice scanner -------------------------------------------------
-- When an NPC panel has text but no matching audio, record the NPC id, name,
-- race and sex so the author knows which lines still need recording. Export
-- with /qe missing, clear with /qe clearmissing. Only NPC-driven panels are
-- scanned (the quest-log Echo button has no NPC unit, so it is skipped).
-- ---- export popup ----------------------------------------------------------
-- WoW addons cannot write a .txt to disk. Present the missing list in a
-- multi-line EditBox the user can select and Ctrl+C into their own text file.
local exportFrame
local function ShowExportFrame(text)
    if not exportFrame then
        local tmpl = BackdropTemplateMixin and "BackdropTemplate"
        exportFrame = CreateFrame("Frame", "QuestEchoExportFrame", UIParent, tmpl)
        exportFrame:SetSize(420, 300)
        exportFrame:SetPoint("CENTER")
        exportFrame:SetFrameStrata("DIALOG")
        if exportFrame.SetBackdrop then
            exportFrame:SetBackdrop({
                bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 16, edgeSize = 16,
                insets = { left = 4, right = 4, top = 4, bottom = 4 },
            })
            exportFrame:SetBackdropColor(0, 0, 0, 0.95)
            exportFrame:SetBackdropBorderColor(0.85, 0.7, 0.2, 1)
        else
            local bg = exportFrame:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints(); bg:SetColorTexture(0, 0, 0, 0.95)
        end
        exportFrame:SetMovable(true); exportFrame:EnableMouse(true)
        exportFrame:RegisterForDrag("LeftButton")
        exportFrame:SetScript("OnDragStart", function(f) f:StartMoving() end)
        exportFrame:SetScript("OnDragStop", function(f) f:StopMovingOrSizing() end)
        exportFrame:SetClampedToScreen(true)
        tinsert(UISpecialFrames, "QuestEchoExportFrame")

        local etitle = exportFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        etitle:SetPoint("TOPLEFT", exportFrame, "TOPLEFT", 12, -10)
        etitle:SetText(L("Missing voice lines - Ctrl+C to copy, Esc to close",
                         "缺失语音 — Ctrl+C 复制，Esc 关闭"))
        etitle:SetTextColor(1, 0.82, 0)

        local eclose = CreateFrame("Button", nil, exportFrame, "UIPanelCloseButton")
        eclose:SetPoint("TOPRIGHT", exportFrame, "TOPRIGHT", -2, -2)
        eclose:SetSize(24, 24)

        local eb = CreateFrame("EditBox", nil, exportFrame)
        eb:SetMultiLine(true)
        eb:SetFontObject(ChatFontNormal)
        eb:SetSize(392, 244)
        eb:SetPoint("TOPLEFT", exportFrame, "TOPLEFT", 14, -34)
        eb:SetAutoFocus(true)
        eb:SetScript("OnEscapePressed", function() exportFrame:Hide() end)
        exportFrame.eb = eb
    end
    exportFrame.eb:SetText(text)
    exportFrame.eb:HighlightText(0)
    exportFrame.eb:SetFocus()
    exportFrame:Show()
end

QuestEcho.Missing = {}
local Missing = QuestEcho.Missing
local SEXNAME = { [1] = "neutral", [2] = "male", [3] = "female" }

local function MissingGUIDInfo()
    local npcName, npcID, raceID, sexID
    pcall(function() npcName = Utils:GetNPCName() end)
    pcall(function()
        local guid = UnitGUID("npc")
        if guid then
            local _, _, _, _, _, id = strsplit("-", guid)
            npcID = tonumber(id)
        end
    end)
    pcall(function()
        local rname, rid = UnitRace("npc")
        local locRace, engRace
        local guid = UnitGUID("npc")
        if guid then
            local pok, _, _, lr, er = pcall(GetPlayerInfoByGUID, guid)
            if pok then locRace, engRace = lr, er end
        end
        local offRace
        if QuestEcho_NPCRace and npcID then offRace = QuestEcho_NPCRace[npcID] end
        local ctype, ctoken = UnitCreatureType("npc")
        -- Prefer a concrete playable race (client API, then the offline faction
        -- lookup), fall back to creature type (Humanoid/Demon/Undead/Dragonkin/
        -- Mechanical/...), always present.
        raceID = rname or rid or locRace or engRace or offRace or ctype or ctoken
    end)
    pcall(function() sexID = UnitSex("npc") end)
    return npcID, npcName, raceID, sexID
end

function Missing:Record(kind)
    if not kind then return end
    local npcID, npcName, raceID, sexID = MissingGUIDInfo()
    Addon.db.missing = Addon.db.missing or { items = {} }
    local items = Addon.db.missing.items
    local key = tostring(npcID or npcName or "?") .. "|" .. tostring(kind)
    local it = items[key]
    if not it then
        items[key] = { npcID = npcID, name = npcName, race = raceID, sex = sexID, kind = kind, count = 1 }
    else
        it.count = it.count + 1
        if it.race == nil and raceID then it.race = raceID end
        if it.sex == nil and sexID then it.sex = sexID end
        if it.name == nil and npcName then it.name = npcName end
    end
end

function Missing:Dump()
    local items = Addon.db.missing and Addon.db.missing.items or {}
    local rows = {}
    for _, it in pairs(items) do
        rows[#rows + 1] = format("%s|%s|%s|%s|%s|x%d",
            tostring(it.npcID or "-"), it.name or "-",
            tostring(it.race or "-"), SEXNAME[it.sex] or tostring(it.sex or "-"),
            tostring(it.kind), it.count)
    end
    table.sort(rows)
    Print(format(L("Missing voice lines: %d unique (npcID|name|race|sex|scene|count)",
        "缺失语音：%d 条（格式 NPCID|名称|种族|性别|场景|次数）"), #rows))
    for _, r in ipairs(rows) do Print(r) end
    -- Also open a copyable popup (addons cannot write a .txt to disk).
    local out = { L("QuestEcho missing voice lines (npcID|name|race|sex|scene|count)",
                    "QuestEcho 缺失语音（NPCID|名称|种族|性别|场景|次数）") }
    for _, r in ipairs(rows) do out[#out + 1] = r end
    ShowExportFrame(table.concat(out, "\n"))
end

function Missing:Clear()
    Addon.db.missing = { items = {} }
    Print(L("Missing list cleared", "缺失列表已清空"))
end

-- ---- event handlers ----------------------------------------------------------
local function GetCurrentQuestID()
    local ok, id = pcall(GetQuestID)
    if ok and id and id > 0 then return id end
    if C_QuestLog and C_QuestLog.GetSelectedQuest then
        local sid = C_QuestLog.GetSelectedQuest()
        if sid and sid > 0 then return sid end
    end
    return nil
end

-- Unified NPC quest-panel scene handler. Plays the line for the panel that is
-- open; if no audio exists (or the panel id is not ready on the first event)
-- it records the missing line once, including the NPC's race and sex.
local function AttemptQuestScene(kind, soundEvent)
    local function attempt()
        local qid = GetCurrentQuestID()
        if qid and QueueQuestVoice(qid, soundEvent) then
            return
        end
        Missing:Record(kind)
    end
    if GetCurrentQuestID() then
        attempt()
    else
        QEAfter(0.3, attempt)
    end
end

local function OnQuestDetail()
    if not Addon.db.profile.QuestDetail then return end
    AttemptQuestScene("detail", Enums.SoundEvent.QuestDetail)
end

local function OnQuestAccepted(questIndex, questID)
    if not Addon.db.profile.QuestAccept then return end
    if not questID then return end
    -- QUEST_DETAIL already plays the same accept line when the quest text is
    -- shown (detail and accept share x-accept.ogg); only play on accept when
    -- detail autoplay is turned off.
    if Addon.db.profile.QuestDetail then return end
    QueueQuestVoice(questID, Enums.SoundEvent.QuestAccept)
end

-- QUEST_COMPLETE fires with no quest id on retail; the active turn-in quest is
-- read from the global GetQuestID() (same approach ChattyLittleNpc uses).
local function TryComplete(qid, retried)
    local id = qid or GetCurrentQuestID()
    if not id then
        Missing:Record("complete")
        return
    end
    local rewardText = GetPanelQuestText(Enums.SoundEvent.QuestComplete)
    -- the reward panel text can lag the event; retry once before queueing so
    -- the caption matches the complete voice line
    if not rewardText and not retried then
        QEAfter(0.3, function() TryComplete(id, true) end)
        return
    end
    local title = GetQuestTitle(id)
    if not QueueQuestVoice(id, Enums.SoundEvent.QuestComplete, title, rewardText) then
        Missing:Record("complete")
    end
end

local function OnQuestComplete()
    if not Addon.db.profile.QuestComplete then return end
    local questID = GetCurrentQuestID()
    if not questID then
        -- the complete panel may lag the event by a frame; retry shortly
        QEAfter(0.3, function() TryComplete(GetCurrentQuestID(), false) end)
        return
    end
    TryComplete(questID, false)
end

-- QUEST_PROGRESS: the turn-in dialog shown when quest objectives are not yet
-- complete; plays {id}-progress.ogg.
local function OnQuestProgress()
    if not Addon.db.profile.QuestProgress then return end
    AttemptQuestScene("progress", Enums.SoundEvent.QuestProgress)
end

-- QUEST_GREETING: the NPC greeting list (available quests/turn-ins); plays
-- {id}-greeting.ogg when one exists.
local function OnQuestGreeting()
    if not Addon.db.profile.QuestGreeting then return end
    AttemptQuestScene("greeting", Enums.SoundEvent.QuestGreeting)
end

-- ---- gossip ---------------------------------------------------------------
local gossipOpenKey = nil

local function GetNPCIDFromUnit()
    local guid = UnitGUID("npc")
    if not guid then return nil end
    local _, _, _, _, _, id = strsplit("-", guid)
    return tonumber(id)
end

-- GOSSIP_SHOW fires when the gossip window opens; GetGossipText returns the
-- NPC's greeting. Resolve the voice hash and queue it.
local function OnGossipShow()
    local npcName = Utils:GetNPCName()
    local npcID = GetNPCIDFromUnit()
    local ok, text = pcall(GetGossipText)
    text = ok and text or nil
    if (not text or text == "") and C_GossipInfo and type(C_GossipInfo.GetText) == "function" then
        local ok2, t2 = pcall(C_GossipInfo.GetText)
        if ok2 and type(t2) == "string" then text = t2 end
    end
    if not text or text == "" then return end
    local key = (npcName or "") .. "|" .. text
    if gossipOpenKey == key then return end
    gossipOpenKey = key

    local hash = DataModules:GetNPCGossipHash(npcID, npcName, text)
    if not hash then
        Debug:Print("no gossip voice for %s", tostring(npcName or npcID))
        Missing:Record("gossip")
        return
    end
    local soundData = {
        id = "gossip-" .. tostring(hash) .. "-" .. tostring(GetTime()),
        event = Enums.SoundEvent.Gossip,
        title = npcName or L("NPC", "NPC"),
        name = npcName,
        text = text,
        fileName = hash,
    }
    if DataModules:PrepareSound(soundData) then
        SoundQueue:AddSoundToQueue(soundData)
    end
end

local gossipResetFrame = CreateFrame("Frame")
gossipResetFrame:RegisterEvent("GOSSIP_CLOSED")
gossipResetFrame:SetScript("OnEvent", function()
    gossipOpenKey = nil
end)

-- ---- quest detail Echo buttons ---------------------------------------------
-- Mirrors ChattyLittleNpc's PlayButton on QuestMapFrame.DetailsFrame: a
-- standalone "Echo" button on the quest-log details panel (visible whenever a
-- quest is selected in the log) plus a small speaker button next to the back
-- arrow of the quest detail popup. The log button is always visible when a
-- quest is selected: enabled (red/gold) when a voice line exists, disabled
-- (grey) when there is none.
local questEchoLogBtn = nil
local questEchoDetailBtn = nil
local questUpdateAllHooked = false
local questDetailShowHooked = false
local questMapHookInstalled = false
local RefreshQuestEchoButtons

local function PlaySelectedQuest()
    local questID = C_QuestLog and C_QuestLog.GetSelectedQuest and C_QuestLog.GetSelectedQuest()
    if questID then
        QueueQuestVoice(questID, Enums.SoundEvent.QuestDetail)
    end
end

-- Create the buttons once. Buttons are reused across quest-log opens; only
-- their visibility/enabled state changes. Frame level is raised well above
-- the DetailsFrame backdrop so the button is never buried (CLN uses TOOLTIP
-- strata for the same reason).
local function CreateQuestEchoButtons()
    local df = QuestMapFrame and QuestMapFrame.DetailsFrame
    if not df then return false end

    if not questEchoLogBtn then
        local logBtn = MakeButton(df, 52, 20, "Echo", function()
            if questEchoLogBtn and questEchoLogBtn:IsEnabled() then
                PlaySelectedQuest()
            end
        end)
        logBtn:SetPoint("TOPRIGHT", df, "TOPRIGHT", -10, -36)
        -- raise above the DetailsFrame backdrop and any decorative layers
        logBtn:SetFrameStrata("TOOLTIP")
        logBtn:SetFrameLevel(df:GetFrameLevel() + 40)
        logBtn:EnableMouse(true)
        questEchoLogBtn = logBtn
    end

    if not questEchoDetailBtn then
        local backButton = df.BackButton or (df.BackFrame and df.BackFrame.BackButton)
        if backButton then
            local btn = CreateFrame("Button", nil, df)
            btn:SetSize(24, 24)
            btn:SetFrameStrata("TOOLTIP")
            btn:SetFrameLevel(df:GetFrameLevel() + 40)
            local bg = btn:CreateTexture(nil, "BACKGROUND")
            bg:SetPoint("CENTER")
            bg:SetSize(28, 28)
            bg:SetTexture("Interface\Tooltips\UI-Tooltip-Background")
            bg:SetVertexColor(1, 1, 1, 0.12)
            btn.bg = bg
            local icon = btn:CreateTexture(nil, "ARTWORK")
            icon:SetPoint("CENTER")
            icon:SetSize(18, 18)
            icon:SetTexture("Interface\COMMON\VOICECHAT-SPEAKER")
            btn.icon = icon
            btn:SetPoint("LEFT", backButton, "RIGHT", 4, 0)
            btn:SetScript("OnClick", PlaySelectedQuest)
            btn:SetScript("OnEnter", function(f) f.bg:SetVertexColor(1, 1, 1, 0.25) end)
            btn:SetScript("OnLeave", function(f) f.bg:SetVertexColor(1, 1, 1, 0.12) end)
            questEchoDetailBtn = btn
        end
    end

    return true
end

function RefreshQuestEchoButtons()
    local df = QuestMapFrame and QuestMapFrame.DetailsFrame
    if not df or not questEchoLogBtn then return end
    if not df:IsShown() then
        questEchoLogBtn:Hide()
        if questEchoDetailBtn then questEchoDetailBtn:Hide() end
        return
    end
    local hasVoice = false
    local questID = C_QuestLog and C_QuestLog.GetSelectedQuest and C_QuestLog.GetSelectedQuest()
    if questID and questID > 0 then
        if DataModules:HasSound(questID, Enums.SoundEvent.QuestAccept) then
            hasVoice = true
        else
            local title = GetQuestTitle(questID)
            if title then
                local vanillaID = DataModules:GetQuestID(Enums.SoundEvent.QuestAccept, title)
                hasVoice = vanillaID and DataModules:HasSound(vanillaID, Enums.SoundEvent.QuestAccept) or false
            end
        end
    end
    questEchoLogBtn:Show()
    questEchoLogBtn:SetFrameStrata("TOOLTIP")
    questEchoLogBtn:SetFrameLevel(df:GetFrameLevel() + 40)
    if hasVoice then
        questEchoLogBtn:Enable()
    else
        questEchoLogBtn:Disable()
    end
    if questEchoDetailBtn then
        if hasVoice then questEchoDetailBtn:Show() else questEchoDetailBtn:Hide() end
    end
end

local function InstallQuestEchoButtons()
    if not QuestMapFrame then return end
    local df = QuestMapFrame.DetailsFrame

    if df then
        local created = CreateQuestEchoButtons()
        if created then
            -- refresh whenever the quest log content changes
            if type(QuestMapFrame_UpdateAll) == "function" and not questUpdateAllHooked then
                questUpdateAllHooked = true
                hooksecurefunc("QuestMapFrame_UpdateAll", function() pcall(RefreshQuestEchoButtons) end)
            end
            -- refresh every time the details panel itself shows
            if not questDetailShowHooked then
                questDetailShowHooked = true
                df:HookScript("OnShow", function()
                    pcall(RefreshQuestEchoButtons)
                end)
            end
            pcall(RefreshQuestEchoButtons)
        end
    end

    -- If DetailsFrame is not created yet, retry when QuestMapFrame first shows
    if not questMapHookInstalled then
        questMapHookInstalled = true
        QuestMapFrame:HookScript("OnShow", function()
            if QuestMapFrame.DetailsFrame then
                pcall(InstallQuestEchoButtons)
            end
        end)
    end
end

-- =============================================================================
-- Classic-flavour quest-log Echo button (Forever / Classic Era). These clients
-- keep the legacy QuestLogFrame / QuestLogDetailFrame and the
-- GetQuestLogSelection/GetQuestLogTitle API instead of QuestMapFrame.
-- =============================================================================
local classicLogBtn = nil
local classicDetailBtn = nil
local classicHooksInstalled = false

local function GetClassicSelectedQuest()
    if type(GetQuestLogSelection) ~= "function"
        or type(GetQuestLogTitle) ~= "function" then
        return nil
    end
    local okIdx, idx = pcall(GetQuestLogSelection)
    if not okIdx or not idx or idx <= 0 then return nil end
    local okT, title, _lvl, _sg, isHeader, _col, _comp, _freq, questID =
        pcall(GetQuestLogTitle, idx)
    if not okT or isHeader then return nil end
    return questID, title, idx
end

local function ClassicRefreshButtons()
    local qid = GetClassicSelectedQuest()
    local hasVoice = false
    if qid then
        pcall(function()
            if DataModules:HasSound(qid, Enums.SoundEvent.QuestAccept) then
                hasVoice = true
            end
        end)
    end
    for _, btn in ipairs({ classicLogBtn, classicDetailBtn }) do
        if btn then
            if qid then
                btn:Show()
                if hasVoice then btn:Enable() else btn:Disable() end
            else
                btn:Hide()
            end
        end
    end
end

local function ClassicPlaySelected()
    local qid, title = GetClassicSelectedQuest()
    if not qid then return end
    local soundData = MakeQuestSound(qid, Enums.SoundEvent.QuestDetail, title)
    if not soundData then return end
    if type(GetQuestLogQuestText) == "function" then
        local okTxt, qtxt = pcall(GetQuestLogQuestText)
        if okTxt and type(qtxt) == "string" and qtxt ~= "" then
            soundData.text = qtxt
        end
    end
    SoundQueue:AddSoundToQueue(soundData)
end

local function MakeClassicEchoButton(parent)
    local b = MakeButton(parent, 52, 20, "Echo", ClassicPlaySelected)
    pcall(b.SetFrameStrata, b, "TOOLTIP")
    pcall(b.SetFrameLevel, b, parent:GetFrameLevel() + 30)
    b:EnableMouse(true)
    return b
end

local function InstallClassicQuestButtons()
    if not HAS_CLASSIC_QUESTLOG then return end
    local logf = _G["QuestLogFrame"]
    local dff = _G["QuestLogDetailFrame"]
    if logf and not classicLogBtn then
        classicLogBtn = MakeClassicEchoButton(logf)
        classicLogBtn:SetPoint("TOPRIGHT", logf, "TOPRIGHT", -12, -34)
        logf:HookScript("OnShow", function() pcall(ClassicRefreshButtons) end)
    end
    if dff and not classicDetailBtn then
        classicDetailBtn = MakeClassicEchoButton(dff)
        classicDetailBtn:SetPoint("TOPRIGHT", dff, "TOPRIGHT", -12, -34)
        dff:HookScript("OnShow", function() pcall(ClassicRefreshButtons) end)
    end
    if not classicHooksInstalled and logf and type(QuestLog_Update) == "function" then
        classicHooksInstalled = true
        pcall(hooksecurefunc, "QuestLog_Update", function()
            pcall(ClassicRefreshButtons)
        end)
    end
    pcall(ClassicRefreshButtons)
end


-- =============================================================================
-- Slash commands
-- =============================================================================
local GOSSIP_NAMES = {
    always = L("always", "总是"),
    once = L("once per NPC (per character)", "每 NPC 一次（每角色）"),
    oncequest = L("once per quest NPC (per session)", "每任务 NPC 一次（每会话）"),
    never = L("never", "从不"),
}

-- ---- key bindings ----------------------------------------------------------
QuestEcho.Keys = {}
local Keys = QuestEcho.Keys

function Keys:TogglePause()
    local q = QuestEcho.SoundQueue
    if q:IsEmpty() then return end
    if QuestEcho.Addon.db.char.IsPaused then
        q:ResumeQueue()
    else
        q:PauseQueue()
    end
end

function Keys:StopAll()
    QuestEcho.SoundQueue:RemoveAllSoundsFromQueue()
end

function Keys:Settings()
    QuestEcho.OptionsUI:Toggle()
end

BINDING_HEADER_QUESTECHO = "QuestEcho"
BINDING_NAME_QE_TOGGLEPAUSE = L("Pause / resume voice queue", "暂停 / 恢复语音队列")
BINDING_NAME_QE_STOP = L("Stop and clear voice queue", "停止并清空语音队列")
BINDING_NAME_QE_SETTINGS = L("Open QuestEcho settings", "打开 QuestEcho 设置")

-- ---- data-pack health check ------------------------------------------------
local function HealthCheck()
    local mods = DataModules:GetModules()
    if #mods == 0 then
        Print("|cffff6060[QuestEcho]|r " .. L("No voice data pack found. Install a QuestEchoData pack from the release page.",
                                              "未找到语音数据包，请从发布页安装 QuestEchoData 语音包。"))
        -- Belt-and-suspenders: force the bar visible with the warning in it.
        if SoundQueueUI and SoundQueueUI.frame then
            Addon.db.profile.ShowUI = true
            SoundQueueUI.frame:Show()
            if SoundQueueUI.status then
                SoundQueueUI.status:SetText(L("|cffff6060No voice data pack installed|r",
                                              "|cffff6060未安装语音数据包|r"))
            end
        end
        return
    end
    local forced = Addon.db.profile.VoiceLang or "auto"
    if forced ~= "auto" and not DataModules:LangModuleExists(forced) then
        Print(L("[QuestEcho] Selected voice pack missing; using an available pack.",
                "[QuestEcho] 所选语音包缺失，已改用可用语音包。"))
    end
end

local function Help()
    Print("|cff33ffccQuestEcho|r " .. tostring(GetAddOnMetadata("QuestEcho", "Version") or ""))
    Print("/qe — " .. L("toggle status bar", "开关状态栏"))
    Print("/qe settings — " .. L("open settings", "打开设置"))
    Print("/qe captions on|off — " .. L("toggle captions", "开关字幕"))
    Print("/qe diag — " .. L("diagnostics", "诊断信息"))
    Print("/qe test — " .. L("play a test voice", "播放测试语音"))
    Print("/qe resetpos — " .. L("reset frame positions", "重置界面位置"))
    Print("/qe missing — " .. L("list NPC lines missing voice", "列出缺少语音的 NPC 台词"))
    Print("/qe clearmissing — " .. L("clear the missing list", "清空缺失列表"))
    Print("/qe help — " .. L("show this help", "显示帮助"))
end

local function Diag()
    local packs = {}
    local n = SafeGetNumAddOns() or 0
    for i = 1, n do
        local name = SafeGetAddOnInfo(i)
        if name and (name:find("^QuestEchoData")) then
            packs[#packs + 1] = name .. "=" .. (IsAddOnLoaded(name) and "ON" or "off")
        end
    end
    local qm = DataModules:GetModule("QuestEchoData")
    local df = QuestMapFrame and QuestMapFrame.DetailsFrame
    local sel, vid, voice = "-", "-", "-"
    local okId, curId = pcall(GetQuestID)
    if okId and curId and curId > 0 then
        local title = GetQuestTitle(curId)
        sel = tostring(title or "?")
        vid = tostring(DataModules:GetQuestID(Enums.SoundEvent.QuestAccept, title or "") or "-")
        voice = tostring(vid ~= "-" and DataModules:HasSound(tonumber(vid), Enums.SoundEvent.QuestAccept) or "-")
    end
    local p = Addon.db.char.Pos
    local packStr = (table.concat(packs, ",") ~= "" and table.concat(packs, ",")) or "-"
    local btnState = "nil"
    if questEchoLogBtn then
        if questEchoLogBtn:IsShown() then
            btnState = questEchoLogBtn:IsEnabled() and "S" or "S(grey)"
        else
            btnState = "H"
        end
    end
    local posStr = "nil"
    if p and p.x then
        posStr = tostring(math.floor(p.x + 0.5)) .. "," .. tostring(math.floor(p.y + 0.5))
    end
    Print("diag r10 | packs:" .. packStr ..
        " | QID=" .. tostring(qm and type(qm.QuestIDLookup)) ..
        " | DF=" .. tostring(df and "Y" or "N") ..
        " | btn=" .. btnState ..
        " | sel=" .. sel ..
        " | vanilla=" .. vid ..
        " | voice=" .. voice ..
        " | pos=" .. posStr ..
        " | fmt=" .. tostring(type(format)))
    Print("diag done")
end

local function TestPlay()
    local soundData = MakeQuestSound(5, Enums.SoundEvent.QuestAccept, L("Test voice", "测试语音"))
    if not soundData then
        -- fallback: build the entry manually if the data pack is missing
        local folder = "QuestEchoData"
        if DataModules.registeredAddonNames then
            for _, addonName in pairs(DataModules.registeredAddonNames) do
                folder = addonName
                break
            end
        end
        soundData = {
            id = "test-" .. tostring(GetTime()),
            questID = 5,
            event = Enums.SoundEvent.QuestAccept,
            title = L("Test voice", "测试语音"),
            fileName = "5-accept",
            path = format("Interface\\AddOns\\%s\\generated\\sounds\\quests\\5-accept.ogg", folder),
            length = 5,
        }
    end
    SoundQueue:AddSoundToQueue(soundData)
end
-- expose for click handlers defined earlier in the file
QuestEcho.TestPlay = TestPlay

local HandleSlashCommandInner

local function HandleSlashCommand(input)
    local okRun, errRun = pcall(function()
        HandleSlashCommandInner(input or "")
    end)
    if not okRun then
        Print("[QuestEcho] command error: " .. tostring(errRun))
    end
end

function HandleSlashCommandInner(input)
    input = input or ""
    local command, arg1 = input:match("^(%S*)%s*(.-)$")
    command = (command or ""):lower()
    arg1 = arg1 or ""
    if command == "" then
        SoundQueueUI:Toggle()
    elseif command == "settings" or command == "opt" or command == "o" then
        OptionsUI:Toggle()
    elseif command == "captions" or command == "caption" or command == "c" then
        if arg1 == "off" then
            Addon.db.profile.Captions = false
            Print(L("captions off", "字幕已关闭"))
        else
            Addon.db.profile.Captions = true
            Print(L("captions on", "字幕已开启"))
        end
    elseif command == "diag" then
        Diag()
    elseif command == "resetpos" then
        Addon.db.char.Pos = nil
        Addon.db.char.OptPos = nil
        SoundQueueUI:ApplySavedPos()
        Print(L("position reset — drag to a new spot", "位置已重置 — 请重新拖动"))
    elseif command == "missing" then
        Missing:Dump()
    elseif command == "clearmissing" then
        Missing:Clear()
    elseif command == "test" or command == "t" then
        TestPlay()
    elseif command == "help" or command == "h" then
        Help()
    else
        Help()
    end
end

SLASH_QUESTECHO1 = "/qe"
SlashCmdList["QUESTECHO"] = HandleSlashCommand

-- =============================================================================
-- Event frame + init
-- =============================================================================
local coreFrame = CreateFrame("Frame", "QuestEchoCoreFrame")

local function OnEvent(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == ADDON_NAME then
            InitDB()
            DataModules:LoadAll()
        elseif name and name:find("^QuestEchoData") then
            local module = _G[name]
            if module and module.QuestIDLookup then
                DataModules:Register(name, module)
            end
        elseif name == "Blizzard_QuestLog" then
            pcall(InstallQuestEchoButtons)
        end
        return
    end
    if event == "QUEST_DETAIL" then
        OnQuestDetail()
    elseif event == "QUEST_PROGRESS" then
        OnQuestProgress()
    elseif event == "QUEST_GREETING" then
        OnQuestGreeting()
    elseif event == "QUEST_ACCEPTED" then
        OnQuestAccepted(...)
    elseif event == "QUEST_COMPLETE" then
        OnQuestComplete()
    elseif event == "GOSSIP_SHOW" then
        OnGossipShow()
    elseif event == "QUEST_LOG_UPDATE" then
        if ClassicRefreshButtons then pcall(ClassicRefreshButtons) end
    elseif event == "QUEST_TURNED_IN" then
        -- completion voice is played when the complete UI shows; nothing extra
    elseif event == "PLAYER_LOGOUT" then
        -- Guarantee the SavedVariables global references the live db table so
        -- positions/settings always persist (handles nil-starting saves).
        QuestEchoDB = Addon.db
    end
end

coreFrame:SetScript("OnEvent", OnEvent)
coreFrame:RegisterEvent("ADDON_LOADED")
coreFrame:RegisterEvent("QUEST_DETAIL")
coreFrame:RegisterEvent("QUEST_PROGRESS")
coreFrame:RegisterEvent("QUEST_GREETING")
coreFrame:RegisterEvent("QUEST_ACCEPTED")
coreFrame:RegisterEvent("QUEST_COMPLETE")
coreFrame:RegisterEvent("QUEST_TURNED_IN")
coreFrame:RegisterEvent("GOSSIP_SHOW")
coreFrame:RegisterEvent("QUEST_LOG_UPDATE")
coreFrame:RegisterEvent("PLAYER_LOGOUT")

-- ---- startup ----------------------------------------------------------------
local started = false
local startupFrame = CreateFrame("Frame")
startupFrame:RegisterEvent("PLAYER_LOGIN")
startupFrame:SetScript("OnEvent", function()
    started = true
    pcall(DataModules.LoadAll, DataModules)
    -- register packs already loaded (e.g. at ADDON_LOADED time)
    local okEnum, addonList = pcall(function() return DataModules:EnumerateAddons() end)
    if okEnum and type(addonList) == "table" then
        for _, name in ipairs(addonList) do
            local module = _G[name]
            if module and module.QuestIDLookup and not DataModules:GetModule(name) then
                DataModules:Register(name, module)
            end
        end
    end
    -- Early warning before any UI is built, so it prints even if frame
    -- creation below errors.
    if #DataModules:GetModules() == 0 then
        Print("|cffff6060[QuestEcho]|r " .. L("No voice data pack found. Install a QuestEchoData pack from the release page.",
                                              "未找到语音数据包，请从发布页安装 QuestEchoData 语音包。"))
    end
    local okBar, errBar = pcall(function() SoundQueueUI:Create() end)
    if not okBar then
        Print("[QuestEcho] status bar init error: " .. tostring(errBar))
    end
    local okOpt, errOpt = pcall(function() OptionsUI:Create() end)
    if not okOpt then
        Print("[QuestEcho] options init error: " .. tostring(errOpt))
    end
    local okBtn, errBtn = pcall(InstallQuestEchoButtons)
    if not okBtn then
        Print("[QuestEcho] quest button init error: " .. tostring(errBtn))
    end
    if not QuestMapFrame and EventUtil and EventUtil.ContinueOnAddOnLoaded then
        pcall(EventUtil.ContinueOnAddOnLoaded, "Blizzard_QuestLog", function()
            pcall(InstallQuestEchoButtons)
        end)
    end
    -- classic-flavour clients build the legacy quest log lazily; retry a few
    -- times after login so the Echo button attaches reliably.
    pcall(InstallClassicQuestButtons)
    for _i = 1, 5 do QEAfter(_i, function() pcall(InstallClassicQuestButtons) end) end
    for i = 1, 5 do
        QEAfter(i, function()
            pcall(InstallQuestEchoButtons)
        end)
    end
    HealthCheck()
    print("|cff33ffcc[QuestEcho]|r " .. L("loaded — /qe for options", "已加载 — /qe 打开设置"))
end)

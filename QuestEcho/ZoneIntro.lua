-- ZoneIntro.lua
-- 区域介绍：进入地区 / 次级地区时朗读介绍语音。
--
-- 数据链：GetRealZoneText()/GetSubZoneText() -> ZoneAudioLookup(中文区域名 -> 文件)
-- -> "1411\zone" / "1411\razor-hill" -> generated/sounds/maps/<file>.ogg
-- ZoneAudioLookup 随数据包发布（生成器 outputs/_gen_zone_book_data.py）。
--
-- 行为（与参考实现一致）：
--   * ZONE_CHANGED / ZONE_CHANGED_INDOORS / ZONE_CHANGED_NEW_AREA 都是入口，
--     统一延迟一拍再看最终位置（跨子区域时会连发好几个事件）；
--   * 区域与当前次级地区分别判定，各自"没听过"才排；区域在前、次级地区在后；
--   * 战斗 / 电影中挂起，结束再播（最多挂 30 秒）；飞行 / 乘出租车途中跳过；
--   * "每个地区只播报一次"开启时按角色记录；"忘记已朗读的地方"清空重来。
--
-- Lua 5.0 兼容：无 '#'、无 '%'。

local QE = QuestEcho
if not QE or not QE.DataModules or not QE.SoundQueue then return end
local DataModules = QE.DataModules
local SoundQueue = QE.SoundQueue
local Enums = QE.Enums

local tinsert, tgetn = table.insert, table.getn

local function Profile()
    local db = QE.Addon and QE.Addon.db
    return db and db.profile or nil
end

local function CharHeard()
    local db = QE.Addon and QE.Addon.db
    if not db or not db.char then return nil end
    if type(db.char.ZoneHeard) ~= "table" then
        db.char.ZoneHeard = {}
    end
    return db.char.ZoneHeard
end

-- 电影（开场动画 / 影片）期间不念，和战斗一样属于"等一等"。
local function CinematicUp()
    local f = _G.CinematicFrame
    if f and f.IsShown and f:IsShown() then return true end
    local m = _G.MovieFrame
    if m and m.IsShown and m:IsShown() then return true end
    if type(InCinematic) == "function" then
        local ok, r = pcall(InCinematic)
        if ok and r then return true end
    end
    return false
end

local function InCombat()
    if type(UnitAffectingCombat) ~= "function" then return false end
    local ok, v = pcall(UnitAffectingCombat, "player")
    if ok and v then return true end
    return false
end

-- 飞行 / 出租车：途中掠过的地方不值得念（落地后照常）。
local function OnTaxiOrFlying()
    if type(UnitOnTaxi) == "function" then
        local ok, v = pcall(UnitOnTaxi, "player")
        if ok and v then return true end
    end
    if type(IsFlying) == "function" then
        local ok, v = pcall(IsFlying)
        if ok and v then return true end
    end
    return false
end

-- 当前该排的条目（区域 + 次级地区），各自只在没听过时进表。
local function CollectTargets(prof, heard)
    local pack = DataModules:GetActive()
    local zl = pack and pack.ZoneAudioLookup
    if not zl then return nil end
    local zone = GetRealZoneText and GetRealZoneText() or ""
    if not zone or zone == "" then return nil end
    local sub = GetSubZoneText and GetSubZoneText() or ""
    local once = prof.ZoneOnce
    local out = {}

    local zfile = zl.zones and zl.zones[zone]
    if zfile and (not once or not heard[zone]) then
        tinsert(out, { file = zfile, key = zone, label = zone })
    end
    if prof.ZoneSubzones and sub and sub ~= "" then
        local group = zl.subzones and zl.subzones[zone]
        local sfile = group and group[sub]
        local skey = zone .. "/" .. sub
        if sfile and (not once or not heard[skey]) then
            tinsert(out, { file = sfile, key = skey, label = sub })
        end
    end
    return out
end

local function QueueTargets(prof, heard, list)
    for i = 1, tgetn(list) do
        local e = list[i]
        local soundData = {
            id = "zone-" .. e.key,
            fileName = e.file,
            event = Enums.SoundEvent.Zone,
            title = e.label,
            name = e.label,
            _source = "zone",
        }
        if DataModules:PrepareSound(soundData) then
            if prof.ZoneOnce then heard[e.key] = true end
            SoundQueue:AddSoundToQueue(soundData)
        end
    end
end

local pending = nil
local pendingUntil = 0
local nextCheck = 0

local function TryPlay()
    local prof = Profile()
    if not prof or not prof.ZoneIntro then return end
    if OnTaxiOrFlying() then return end
    local heard = CharHeard()
    if not heard then return end
    local list = CollectTargets(prof, heard)
    if not list or tgetn(list) == 0 then return end
    if InCombat() or CinematicUp() then
        pending = list
        pendingUntil = GetTime() + 30
        return
    end
    QueueTargets(prof, heard, list)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("ZONE_CHANGED")
frame:RegisterEvent("ZONE_CHANGED_INDOORS")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")

local function OnZoneEvent()
    -- 过渡期连发多个事件：统一等一拍，只看最终停在哪儿。
    nextCheck = GetTime() + 1.0
end

local function OnFrameUpdate()
    local now = GetTime()
    -- 挂起的条目（战斗/电影结束就播）
    if pending then
        if now >= pendingUntil then
            pending = nil
        elseif not InCombat() and not CinematicUp() then
            local list = pending
            pending = nil
            local prof = Profile()
            local heard = CharHeard()
            if prof and prof.ZoneIntro and heard then
                QueueTargets(prof, heard, list)
            end
        end
    end
    -- 延迟到点的区域检查
    if nextCheck > 0 and now >= nextCheck then
        nextCheck = 0
        local ok, err = pcall(TryPlay)
        if not ok then
            QE.Debug:Print("ZoneIntro ERR: %s", tostring(err))
        end
    end
end

frame:SetScript("OnEvent", OnZoneEvent)
frame:SetScript("OnUpdate", OnFrameUpdate)

QE.ZoneIntro = {
    TryPlay = TryPlay,
    OnZoneEvent = OnZoneEvent,
    OnFrameUpdate = OnFrameUpdate,
    -- "忘记已朗读的地方"：清空本角色的收听记录，之后可以重新听一遍。
    Forget = function()
        local db = QE.Addon and QE.Addon.db
        if db and db.char then
            db.char.ZoneHeard = {}
        end
    end,
}

-- =============================================================================
-- QuestEcho Harvest — 台词采集
--
-- 采集玩家在游戏里真正读到的 NPC 对话、任务正文与书籍文本，导出成官网能解析的
-- 文本块。数据落在 QuestEchoDB.harvest，导出内容带客户端版本号与服务器名，
-- 用于区分正式服 / 怀旧服 / 无限服 / 乌龟服 / 3.3.5a。
--
-- 兼容性：与 Core.lua 同一套约束——Lua 5.0（1.12）到 5.1 通吃，不用 select()、
-- 不用 # 取长、string.find 的捕获手工取；每个客户端 API 都经 pcall，缺失即跳过。
--
-- Copyright (c) 2026 Leysure. All rights reserved.
-- =============================================================================

local QE = QuestEcho or {}
QuestEcho = QE

local function HL(en, zh)
    local loc = ""
    if type(GetLocale) == "function" then
        local ok, l = pcall(GetLocale)
        if ok and type(l) == "string" then loc = l end
    end
    if loc == "zhCN" or loc == "zhTW" then return zh or en end
    return en
end

local function HPrint(msg)
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc[QuestEcho]|r " .. tostring(msg))
    end
end

local Harvest = {}
QE.Harvest = Harvest

local MAX_ITEMS = 3000   -- 采集条数上限，防止 SavedVariables 无限膨胀
local MAX_TEXT  = 1200   -- 单条文本截断长度（字符）
local MAX_PAGE  = 6000   -- 单页导出字符数，EditBox 复制有上限，超出分页

-- ---- 端识别 ----------------------------------------------------------------
-- TOC 里声明的每个 interface 号对应的客户端。认不出来的按号段兜底，玩家也可
-- 用 /qe flavor <名称> 手工指定，写进 db.profile.HarvestFlavor 永久生效。
local FLAVOR_BY_IFACE = {
    [11200] = "vanilla112",   -- 1.12.x：乌龟服 / 水豚服
    [11509] = "era",          -- 1.15.x：官方怀旧服 60 级
    [16001] = "forever",      -- 1.60.x：无限服
    [20506] = "tbc",          -- 2.5.x：怀旧服 TBC
    [30300] = "wrath335",     -- 3.3.5a：WLK 原版客户端
    [30405] = "wrath",        -- 3.4.x：怀旧服 WLK
    [38002] = "wrath",
    [40402] = "cata",         -- 4.4.x：怀旧服 CTM
    [50504] = "mop",          -- 5.5.x：怀旧服 MOP
    [120007] = "retail",
    [120100] = "retail",
    [121000] = "retail",
}

local function DetectFlavor()
    local db = QE.Addon and QE.Addon.db
    if db and db.profile and db.profile.HarvestFlavor and db.profile.HarvestFlavor ~= "" then
        return db.profile.HarvestFlavor
    end
    local iface = QE.Interface or 0
    local f = FLAVOR_BY_IFACE[iface]
    if f then return f end
    if iface >= 110000 then return "retail" end
    if iface >= 30000 and iface < 40000 then return "wrath335" end
    if iface >= 20000 and iface < 30000 then return "tbc" end
    if iface > 0 then return "era" end
    return "unknown"
end
Harvest.DetectFlavor = DetectFlavor

-- ---- 序列化 ----------------------------------------------------------------
local function Q(s)
    s = tostring(s or "")
    s = string.gsub(s, "\\", "\\\\")
    s = string.gsub(s, '"', '\\"')
    s = string.gsub(s, "\r", "")
    s = string.gsub(s, "\n", "\\n")
    return '"' .. s .. '"'
end

local function Clip(s)
    s = tostring(s or "")
    if string.len(s) > MAX_TEXT then s = string.sub(s, 1, MAX_TEXT) end
    return s
end

local function BuildMeta()
    local iface = QE.Interface or 0
    local build = ""
    if type(GetBuildInfo) == "function" then
        local _v, _b = GetBuildInfo()
        if type(_b) == "number" or type(_b) == "string" then build = tostring(_b) end
    end
    local realm = ""
    if type(GetRealmName) == "function" then
        local ok, r = pcall(GetRealmName)
        if ok and type(r) == "string" then realm = r end
    end
    local loc = ""
    if type(GetLocale) == "function" then
        local ok2, l = pcall(GetLocale)
        if ok2 and type(l) == "string" then loc = l end
    end
    local ver = ""
    if type(GetAddOnMetadata) == "function" then
        local ok3, v = pcall(GetAddOnMetadata, "QuestEcho", "Version")
        if ok3 and type(v) == "string" then ver = v end
    end
    return "flavor=" .. Q(DetectFlavor()) .. ",interface=" .. tostring(iface)
        .. ",build=" .. Q(build) .. ",realm=" .. Q(realm)
        .. ",locale=" .. Q(loc) .. ",addon=" .. Q(ver)
end

-- ---- 现场信息 --------------------------------------------------------------
local function NPCInfo()
    local name, id = nil, nil
    if QE.Utils and type(QE.Utils.GetNPCName) == "function" then
        local ok, n = pcall(QE.Utils.GetNPCName)
        if ok and type(n) == "string" and n ~= "" then name = n end
    end
    if type(UnitGUID) == "function" and type(strsplit) == "function" then
        local ok2, guid = pcall(UnitGUID, "npc")
        if ok2 and type(guid) == "string" then
            -- Creature-0-...-...-...-<npcID>-...：第 6 段是 NPC id
            local _, _, _, _, _, sid = strsplit("-", guid)
            if sid then id = sid end
        end
    end
    return id, name
end

local function CurrentQuestID()
    if type(GetQuestID) == "function" then
        local ok, id = pcall(GetQuestID)
        if ok and type(id) == "number" and id > 0 then return tostring(id) end
    end
    if type(C_QuestLog) == "table" and type(C_QuestLog.GetSelectedQuest) == "function" then
        local ok2, sid = pcall(C_QuestLog.GetSelectedQuest)
        if ok2 and type(sid) == "number" and sid > 0 then return tostring(sid) end
    end
    -- 3.3.5a 上 GetQuestID 会返回 nil，改从任务窗口标题反查
    if QuestEcho112 and type(QuestEcho112.TitleBasedQuestID) == "function" then
        local ok3, tid = pcall(QuestEcho112.TitleBasedQuestID)
        if ok3 and type(tid) == "number" and tid > 0 then return tostring(tid) end
    end
    return nil
end

local function CurrentQuestTitle()
    if type(GetTitleText) == "function" then
        local ok, t = pcall(GetTitleText)
        if ok and type(t) == "string" and t ~= "" then return t end
    end
    if type(QE.CurrentQuestTitle) == "function" then
        local ok2, t2 = pcall(QE.CurrentQuestTitle)
        if ok2 and type(t2) == "string" and t2 ~= "" then return t2 end
    end
    return nil
end

-- ---- 采集 ------------------------------------------------------------------
function Harvest:Add(kind, nid, nname, qid, qtitle, text)
    if not text or text == "" then return false end
    local db = QE.Addon and QE.Addon.db
    if not db then return false end
    db.harvest = db.harvest or { items = {} }
    local items = db.harvest.items
    local key = tostring(kind) .. "|" .. tostring(nid or "") .. "|"
        .. tostring(nname or "") .. "|" .. tostring(qid or "") .. "|" .. text
    if items[key] then return false end
    local n = 0
    for _ in pairs(items) do n = n + 1 end
    if n >= MAX_ITEMS then return false end
    items[key] = {
        kind = kind,
        nid  = nid or "",
        nn   = nname or "",
        qid  = qid or "",
        qt   = qtitle or "",
        t    = Clip(text),
    }
    return true
end

local function CaptureGossip()
    local text = nil
    -- Classic Era（1.15）没有 GetGossipText，只有 C_GossipInfo.GetText
    if type(C_GossipInfo) == "table" and type(C_GossipInfo.GetText) == "function" then
        local ok, t = pcall(C_GossipInfo.GetText)
        if ok and type(t) == "string" and t ~= "" then text = t end
    end
    if (not text or text == "") and type(GetGossipText) == "function" then
        local ok2, t2 = pcall(GetGossipText)
        if ok2 and type(t2) == "string" and t2 ~= "" then text = t2 end
    end
    if not text or text == "" then return end
    local id, name = NPCInfo()
    Harvest:Add("gossip", id, name, nil, nil, text)
end

local function CaptureQuest(kind)
    local fn = nil
    if kind == "quest_detail" then fn = GetQuestText
    elseif kind == "quest_complete" then fn = GetRewardText
    elseif kind == "quest_progress" then fn = GetProgressText
    elseif kind == "quest_greeting" then fn = GetGreetingText end
    if type(fn) ~= "function" then return end
    local ok, text = pcall(fn)
    if not ok or type(text) ~= "string" or text == "" then return end
    local id, name = NPCInfo()
    Harvest:Add(kind, id, name, CurrentQuestID(), CurrentQuestTitle(), text)
end

local function CaptureBook()
    if type(ItemTextGetText) ~= "function" then return end
    local ok, text = pcall(ItemTextGetText)
    if not ok or type(text) ~= "string" or text == "" then return end
    local title = nil
    if type(ItemTextGetItem) == "function" then
        local ok2, t = pcall(ItemTextGetItem)
        if ok2 and type(t) == "string" and t ~= "" then title = t end
    end
    Harvest:Add("book", nil, nil, nil, title, text)
end

-- ---- 导出 ------------------------------------------------------------------
local function SerializeLines()
    local db = QE.Addon and QE.Addon.db
    local items = db and db.harvest and db.harvest.items or {}
    local lines = {}
    local n = 0
    for _, it in pairs(items) do
        n = n + 1
        lines[n] = "{k=" .. Q(it.kind) .. ",nid=" .. Q(it.nid) .. ",nn=" .. Q(it.nn)
            .. ",qid=" .. Q(it.qid) .. ",qt=" .. Q(it.qt) .. ",t=" .. Q(it.t) .. "}"
    end
    table.sort(lines)
    return lines
end

local function BuildPages(lines)
    local pages = {}
    local cur, size, pn = {}, 0, 0
    for i = 1, table.getn(lines) do
        local ln = lines[i]
        local len = string.len(ln)
        if size > 0 and size + len > MAX_PAGE then
            pn = pn + 1
            pages[pn] = cur
            cur, size = {}, 0
        end
        cur[table.getn(cur) + 1] = ln
        size = size + len + 1
    end
    pn = pn + 1
    pages[pn] = cur
    return pages
end

local exportFrame
local function ShowHarvestFrame(text)
    if not exportFrame then
        local made = false
        if type(BackdropTemplateMixin) == "table" then
            made = pcall(function()
                exportFrame = CreateFrame("Frame", "QuestEchoHarvestFrame", UIParent, "BackdropTemplate")
            end)
        end
        if not made or not exportFrame then
            exportFrame = CreateFrame("Frame", "QuestEchoHarvestFrame", UIParent)
        end
        exportFrame:SetSize(520, 340)
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
            bg:SetAllPoints()
            if bg.SetColorTexture then bg:SetColorTexture(0, 0, 0, 0.95)
            else bg:SetTexture(0, 0, 0, 0.95) end
        end
        exportFrame:SetMovable(true)
        exportFrame:EnableMouse(true)
        exportFrame:RegisterForDrag("LeftButton")
        exportFrame:SetScript("OnDragStart", function(f) f:StartMoving() end)
        exportFrame:SetScript("OnDragStop", function(f) f:StopMovingOrSizing() end)
        exportFrame:SetClampedToScreen(true)
        if type(UISpecialFrames) == "table" then
            tinsert(UISpecialFrames, "QuestEchoHarvestFrame")
        end

        local etitle = exportFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        etitle:SetPoint("TOPLEFT", exportFrame, "TOPLEFT", 12, -10)
        etitle:SetText(HL("Harvested text — Ctrl+A then Ctrl+C, Esc to close",
                          "采集到的台词 — Ctrl+A 然后 Ctrl+C，Esc 关闭"))
        etitle:SetTextColor(1, 0.82, 0)

        if type(UIPanelCloseButton) == "string" then
            local eclose = CreateFrame("Button", nil, exportFrame, "UIPanelCloseButton")
            eclose:SetPoint("TOPRIGHT", exportFrame, "TOPRIGHT", -2, -2)
            eclose:SetSize(24, 24)
        end

        local eb = CreateFrame("EditBox", nil, exportFrame)
        eb:SetMultiLine(true)
        eb:SetFontObject(ChatFontNormal)
        eb:SetSize(492, 284)
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

function Harvest:Dump(pageArg)
    local lines = SerializeLines()
    local total = table.getn(lines)
    if total == 0 then
        HPrint(HL("Nothing harvested yet — talk to NPCs, open quests or read a book, then run /qe harvest again.",
                  "还没有采集到台词 — 先和 NPC 对话、打开任务或读一本书，再运行 /qe harvest。"))
        return
    end
    local pages = BuildPages(lines)
    local np = table.getn(pages)
    local idx = tonumber(pageArg or "1") or 1
    if idx < 1 then idx = 1 end
    if idx > np then idx = np end
    local body = "QuestEchoHarvest{v=1,meta={" .. BuildMeta() .. "},items={\n"
        .. table.concat(pages[idx], ",\n") .. "\n}}"
    ShowHarvestFrame(body)
    HPrint(HL("Harvest: ", "采集：") .. total .. HL(" entries — page ", " 条 — 第 ") .. idx
        .. "/" .. np .. HL(". Ctrl+A then Ctrl+C, paste on the site.",
                          " 页。Ctrl+A 然后 Ctrl+C，粘贴到官网。"))
    if np > 1 and idx < np then
        HPrint(HL("Next page: /qe harvest ", "下一页：/qe harvest ") .. tostring(idx + 1))
    end
end

function Harvest:Clear()
    local db = QE.Addon and QE.Addon.db
    if db then db.harvest = { items = {} } end
    HPrint(HL("Harvest cleared.", "采集已清空。"))
end

function Harvest:SetFlavor(v)
    local db = QE.Addon and QE.Addon.db
    if not db then return end
    db.profile = db.profile or {}
    db.profile.HarvestFlavor = tostring(v or "")
    if db.profile.HarvestFlavor == "" then
        HPrint(HL("Harvest client tag reset to auto-detect.", "采集端标记已重置为自动识别。"))
    else
        HPrint(HL("Harvest client tag set to ", "采集端标记已设为 ") .. db.profile.HarvestFlavor)
    end
end

function Harvest:Count()
    local db = QE.Addon and QE.Addon.db
    local items = db and db.harvest and db.harvest.items or {}
    local n = 0
    for _ in pairs(items) do n = n + 1 end
    return n
end

-- ---- 事件 ------------------------------------------------------------------
local EVENTS = {
    GOSSIP_SHOW      = CaptureGossip,
    QUEST_DETAIL     = function() CaptureQuest("quest_detail") end,
    QUEST_COMPLETE   = function() CaptureQuest("quest_complete") end,
    QUEST_PROGRESS   = function() CaptureQuest("quest_progress") end,
    QUEST_GREETING   = function() CaptureQuest("quest_greeting") end,
    ITEM_TEXT_READY  = CaptureBook,
}

local hf = CreateFrame("Frame")
hf:SetScript("OnEvent", function(self, event)
    local fn = EVENTS[event]
    if fn then pcall(fn) end
end)
for e in pairs(EVENTS) do
    pcall(hf.RegisterEvent, hf, e)
end

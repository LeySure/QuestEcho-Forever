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

-- 只按 interface 号判断，不看玩家手工设置。
local function DetectFromInterface()
    local iface = QE.Interface or 0
    local f = FLAVOR_BY_IFACE[iface]
    if f then return f end
    if iface >= 110000 then return "retail" end
    if iface >= 30000 and iface < 40000 then return "wrath335" end
    if iface >= 20000 and iface < 30000 then return "tbc" end
    if iface > 0 then return "era" end
    return "unknown"
end

local function DetectFlavor()
    local db = QE.Addon and QE.Addon.db
    if db and db.profile and db.profile.HarvestFlavor and db.profile.HarvestFlavor ~= "" then
        return db.profile.HarvestFlavor
    end
    if db and db.profile and db.profile.DetectedFlavor
            and db.profile.DetectedFlavor ~= "" then
        return db.profile.DetectedFlavor
    end
    return DetectFromInterface()
end
Harvest.DetectFlavor = DetectFlavor

-- 把自动识别到的客户端写进存档（DetectedFlavor）。
-- 玩家直接上传 QuestEcho.lua 时，网站要靠这个字段才知道他在哪个客户端：
-- 无限服的旧世界任务沿用了 60 年代的任务 ID，只看 ID 会把它误判成香草 60 年代。
-- 手工 /qe flavor 设过的 HarvestFlavor 优先级更高，这里不覆盖它。
function Harvest:StampClient()
    local db = QE.Addon and QE.Addon.db
    if not (db and db.profile) then return end
    local f = DetectFromInterface()
    if db.profile.DetectedFlavor ~= f then
        db.profile.DetectedFlavor = f
    end
end

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

-- ---- 实名还原（去个性化） --------------------------------------------------
-- 部分私服客户端（如无限服 1.60.1）在把任务/闲聊文本交给插件之前，就已经把
-- $n/$c/$r/$g 这些占位符渲染成了玩家自己的信息：角色名、本职业名、本种族名、
-- 性别称呼（"哟，圣骑士，有好消息吗？"）。同一句话每个玩家看到的不一样，
-- 收进台词库就成了某个人的专属文本，语音包也没法通用。
-- 采集时在这里把渲染出来的实名换回占位符，让上传的永远是通用文本：
--   * 角色名     -> $n    （官方文本里不会出现玩家自己的名字，出现即渲染产物）
--   * 本职业名   -> $c    （只在明确对玩家说话的语境：两侧都是边界标点的呼语）
--   * 本种族名   -> $r    （同上）
--   * 性别称呼   -> 勇士   （$g 的另一分支拿不到，直接给通用称呼，与 1.9.10 一致）
-- 职业/种族只在"猜错代价可控"的形态下替换：见 AddressCheck 的实证表，宽松形态
-- （"……的圣骑士"、"作为一名圣骑士"）精度只有百分之几，会把"杀死黑石氏族的兽人"
-- 这类正常正文一并污染，故一律不猜。玩家职业/种族仍随 meta 上报，网站可据多份
-- 采集对照判定。
-- 安全网：文本里只要还留着任何未渲染的 $ 占位符，就说明这个客户端把原文直接
-- 交给了我们 —— 一律不动。官方客户端（文本带 $n/$c/$r）的采集结果因此零影响。
local Persona = {}
Harvest.Persona = Persona

-- 面向 1.12(Lua 5.0) - 5.1：不用 #、不用 %f、不用 select，全走 string.find。
local function Utf8Len(s)
    local n = 0
    for i = 1, string.len(s) do
        local b = string.byte(s, i)
        if b < 128 or b >= 192 then n = n + 1 end
    end
    return n
end

-- 位置 i 处字符的分类："b"=边界（标点/空白/行外）、"w"=ASCII 词字符、
-- "h"=汉字；同时返回该字符的字节串（用于识别 的/们）。
local function CharAt(text, i)
    local total = string.len(text)
    if i < 1 or i > total then return "b", "" end
    local b = string.byte(text, i)
    if b < 128 then
        if (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
                or b == 45 or b == 39 then
            return "w", string.sub(text, i, i)
        end
        return "b", string.sub(text, i, i)
    end
    -- 多字节字符：先回溯到首字节，再按 UTF-8 长度取全字符。
    -- 注意看的是"当前"字节：只要还停在续接字节上就继续左移。
    local st = i
    while st > 1 do
        local p = string.byte(text, st)
        if p and p >= 128 and p <= 191 then st = st - 1 else break end
    end
    local lead = string.byte(text, st)
    local clen = 1
    if lead >= 240 then clen = 4
    elseif lead >= 224 then clen = 3
    elseif lead >= 192 then clen = 2 end
    local ch = string.sub(text, st, st + clen - 1)
    if lead >= 228 and lead <= 233 and clen == 3 then
        return "h", ch
    end
    return "b", ch
end

-- 文本里是否还有未渲染的占位符（原样 $n/$c/$r/$g/$b/$t 或 $数字）。
local function HasTokens(text)
    local pos = 1
    while true do
        local s = string.find(text, "$", pos, true)
        if not s then return false end
        local b = string.byte(text, s + 1)
        if b then
            if b >= 48 and b <= 57 then return true end
            local c = string.char(b)
            if c == "n" or c == "N" or c == "c" or c == "C" or c == "r" or c == "R"
                    or c == "g" or c == "G" or c == "t" or c == "T"
                    or c == "b" or c == "B" then
                return true
            end
        end
        pos = s + 1
    end
end

-- 把 text 里每一处 word 的出现交给 check 判定，通过的替换成 repl。
-- 从后往前重建，返回新文本与替换处数。
local function ReplaceWord(text, word, repl, check)
    local wlen = string.len(word)
    if wlen == 0 then return text, 0 end
    local hits = {}
    local pos = 1
    while true do
        local s = string.find(text, word, pos, true)
        if not s then break end
        hits[table.getn(hits) + 1] = s
        pos = s + 1
    end
    local n = 0
    local prevStart = -1
    local i = table.getn(hits)
    while i >= 1 do
        local s = hits[i]
        local e = s + wlen - 1
        if not (prevStart >= 0 and e >= prevStart) then
            prevStart = s
            local bk, bch = CharAt(text, s - 1)
            local ak, ach = CharAt(text, e + 1)
            if check(text, s, e, bk, bch, ak, ach) then
                text = string.sub(text, 1, s - 1) .. repl .. string.sub(text, e + 1)
                n = n + 1
            end
        end
        i = i - 1
    end
    return text, n
end

-- 中文称呼语里会随性别变化的常见词（渲染出来了就换成通用称呼）。
-- 顺序有意为之："小姑娘" 先于 "姑娘"，避免子串重复命中。
local G_WORDS = {
    { "小姑娘", "f" }, { "小伙子", "m" }, { "姑娘", "f" },
    { "先生", "m" }, { "女士", "f" }, { "小姐", "f" },
}

-- 玩家画像（角色名/本地化职业/本地化种族/英文 token/性别），登录后取一次缓存。
function Persona:Get()
    if self._cache then return self._cache end
    local p = {}
    if type(UnitName) == "function" then
        local ok, n = pcall(UnitName, "player")
        if ok and type(n) == "string" and n ~= "" then p.name = n end
    end
    if type(UnitClass) == "function" then
        local ok, cl, ct = pcall(UnitClass, "player")
        if ok and type(cl) == "string" and cl ~= "" then p.class = cl end
        if ok and type(ct) == "string" and ct ~= "" then p.classToken = ct end
    end
    if type(UnitRace) == "function" then
        local ok, rl, rt = pcall(UnitRace, "player")
        if ok and type(rl) == "string" and rl ~= "" then p.race = rl end
        if ok and type(rt) == "string" and rt ~= "" then p.raceToken = rt end
    end
    if type(UnitSex) == "function" then
        local ok, s = pcall(UnitSex, "player")
        if ok and type(s) == "number" then
            if s == 2 then p.sex = "m" elseif s == 3 then p.sex = "f" end
        end
    end
    self._cache = p
    return p
end

function Persona:Invalidate()
    self._cache = nil
end

-- 呼语判定：只认"两侧都是边界标点"这一种形态。
--
-- 为什么只留这一种（2026-10-07 全语料实证：10k+ 条中文正文 + 192 处未渲染 token）
--   模式                        真 token   字面(误伤)
--   标点 + 职业名 + 标点           133         61     <- 本函数
--   ……的 + 职业名 + 标点           11        368
--   标点 + 职业名 + 非标点           4        391
--   "作为一名" + 职业名             4          7
-- 后三种精度只有 1%~36%：每救回一条真 token 要污染几十条正常正文，而误伤是
-- 不可逆的——"杀死黑石氏族的兽人"会被念成"杀死黑石氏族的勇士"，指向都变了。
-- SpeakStone 作者对同一问题的结论一致（Harvest.lua 注释原文）：
--   "words like 'priest' also occur naturally in quest text and a single capture
--    cannot tell the two apart. Guessing would corrupt genuine lines."
-- 他们的做法是职业/种族只随 meta 上报，留给网站用多份采集对照判定——本插件的
-- BuildMeta 同样上报 class=/race=，判定交给网站，插件端不做猜。
--
-- 附加护栏：排掉"列举/标题"语境，那些位置是第三人称清单，不是称呼玩家。
--   "通缉：兽人！"        —— 前一字是冒号
--   "战士、法师、牧师"     —— 前后是顿号
local function AddressCheck()
    return function(text, s, e, bk, bch, ak, ach)
        if bk == "b" and ak == "b" then
            if bch == "：" or bch == "、" or ach == "、" then return false end
            return true
        end
        -- "你们矮人" —— 第二人称群体呼语，随种族实名一起被渲染
        if bch == "们" then return true end
        return false
    end
end

-- 主入口：还原文本里的实名，返回新文本与计数表（没有任何替换时计数为 nil）。
function Persona:Clean(text)
    if type(text) ~= "string" or text == "" then return text end
    if HasTokens(text) then return text end
    local p = Persona:Get()
    if not (p.name or p.class or p.race or p.sex) then return text end
    local fixed = nil
    local n = 0
    local function bump(key, c)
        if c and c > 0 then
            fixed = fixed or { n = 0, c = 0, r = 0, g = 0 }
            fixed[key] = fixed[key] + c
        end
    end
    -- 1) 角色名：出现即替换。拉丁名按 ASCII 词边界；中文名要求两侧连标点
    --    都不是（防"小雨伞"这类词内子串误伤）。
    if p.name and Utf8Len(p.name) >= 2 then
        local first = string.byte(p.name, 1)
        local latin = first ~= nil and first < 128
        text, n = ReplaceWord(text, p.name, "$n", function(t, s, e, bk, bch, ak)
            if latin then
                return bk ~= "w" and ak ~= "w"
            end
            return bk == "b" and ak == "b"
        end)
        bump("n", n)
    end
    -- 2) 本职业名/本种族名：只在称呼语境替换（呼语，或中文句中有"你/您"）。
    --    只处理中文文本 + 中文词形：英文语料没有实测样本，以零误伤为准跳过
    --    （英文客户端的职业/种族是 "Paladin"/"Dwarf"，本来也不会命中中文文本）。
    local hasCJK = string.find(text, "[\228-\233]") ~= nil
    local targets = {}
    if hasCJK and p.class and string.find(p.class, "[\228-\233]") then
        targets[table.getn(targets) + 1] = { w = p.class, tag = "$c", key = "c" }
    end
    if hasCJK and p.race and string.find(p.race, "[\228-\233]") then
        targets[table.getn(targets) + 1] = { w = p.race, tag = "$r", key = "r" }
    end
    if table.getn(targets) > 0 then
        for ti = 1, table.getn(targets) do
            local tg = targets[ti]
            text, n = ReplaceWord(text, tg.w, tg.tag, AddressCheck())
            bump(tg.key, n)
        end
    end
    -- 3) 性别称呼：只处理与玩家性别一致方向、且处于称呼语境的词（中文词）。
    if hasCJK and p.sex then
        for gi = 1, table.getn(G_WORDS) do
            local gw = G_WORDS[gi]
            if gw[2] == p.sex then
                text, n = ReplaceWord(text, gw[1], HL("adventurer", "勇士"), AddressCheck())
                bump("g", n)
            end
        end
    end
    return text, fixed
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
    -- 玩家画像一并上报：网站靠 role 信息核对/兜底实名还原（"勇士"字样由网站
    -- 统一渲染，职业/种族用英文 token，跨语言稳定）。
    local persona = Persona:Get()
    local who = ""
    if persona.name then who = who .. ",player=" .. Q(persona.name) end
    if persona.classToken then who = who .. ",class=" .. Q(persona.classToken) end
    if persona.raceToken then who = who .. ",race=" .. Q(persona.raceToken) end
    return "flavor=" .. Q(DetectFlavor()) .. ",interface=" .. tostring(iface)
        .. ",build=" .. Q(build) .. ",realm=" .. Q(realm)
        .. ",locale=" .. Q(loc) .. ",addon=" .. Q(ver) .. who
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
    -- 先去实名：把客户端渲染出来的角色名/职业/种族/称呼换回占位符
    local fixed
    text, fixed = Persona:Clean(text)
    if fixed then
        local t = Harvest.fixed
        if not t then
            t = { n = 0, c = 0, r = 0, g = 0 }
            Harvest.fixed = t
        end
        t.n = t.n + (fixed.n or 0)
        t.c = t.c + (fixed.c or 0)
        t.r = t.r + (fixed.r or 0)
        t.g = t.g + (fixed.g or 0)
    end
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
    local fx = Harvest.fixed
    if fx and (fx.n + fx.c + fx.r + fx.g) > 0 then
        HPrint(HL("Restored to placeholders while harvesting: name(",
                  "采集时已还原实名：角色名×") .. fx.n
            .. HL(") class(", ") 职业×") .. fx.c
            .. HL(") race(", ") 种族×") .. fx.r
            .. HL(") address(", ") 称呼×") .. fx.g .. ")")
    end
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

-- 客户端标记在登录时就写进存档，玩家不用做任何操作
EVENTS.PLAYER_LOGIN = function() Harvest:StampClient(); Persona:Invalidate() end
EVENTS.PLAYER_ENTERING_WORLD = function() Harvest:StampClient(); Persona:Invalidate() end

local hf = CreateFrame("Frame")
hf:SetScript("OnEvent", function(self, event)
    local fn = EVENTS[event]
    if fn then pcall(fn) end
end)
for e in pairs(EVENTS) do
    pcall(hf.RegisterEvent, hf, e)
end

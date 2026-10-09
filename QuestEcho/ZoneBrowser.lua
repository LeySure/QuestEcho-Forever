-- ZoneBrowser.lua
-- 「艾泽拉斯地区介绍」窗口：左边列出全部有语音的地区与次级地区，点一条听一条；
-- 右边像翻书一样显示这一条的插图（QuestEcho\pictures）和文字（ZoneMedia）。
--
-- 数据来自 ZoneAudioLookup / ZoneMedia（随数据包发布）。播放走通用队列，来源标记
-- "zone" 与自动播报一致：试听时按来源清掉旧项，点谁听谁；再点同一条就停下。
-- 停止按条目 id（"zone-<区域>" / "zone-<区域>/<次级>"）从队列里精确移除，
-- 与 ZoneIntro 的命名一致，两边互不打架。
--
-- 控件首次打开才创建；窗口位置记进 profile。
-- Lua 5.0 兼容：无 '#'、无 '%'、无 SetShown。

local QE = QuestEcho
if not QE or not QE.DataModules or not QE.SoundQueue then return end

local DataModules = QE.DataModules
local SoundQueue = QE.SoundQueue
local Enums = QE.Enums
local L = QE.L or function(en, zh) return zh or en end
local Print = QE.Print or function(m) DEFAULT_CHAT_FRAME:AddMessage(tostring(m)) end
local Tint = QE.Tint
local CreatePanelFrame = QE.CreatePanelFrame
local AddClickFallback = QE.AddClickFallback

local tinsert, tgetn = table.insert, table.getn
local floor = math.floor
local sort = table.sort

local WIDTH, HEIGHT = 820, 580
-- 布局: 左边列表 [LIST_X, LIST_X+LIST_W]，右边书页 [PAGE_L, WIDTH-14]。
local LIST_X, LIST_W = 14, 250
local PAGE_L = 278
-- 书页里插图的显示尺寸（原图 512x256，缩到 480x240 画质正好）。
local PIC_W, PIC_H = 480, 240
local ROW_H, SUB_H = 24, 20
-- 数量列固定占位（右对齐）。给死宽度是为了让左侧地名的可用宽度有个确定边界，
-- 两个数字挤不到地名上去。
--
-- 数字不走字体，用插件自带的贴图逐位拼（numbers 目录下的 n0.tga .. n9.tga，8x11）。
-- 起因是个别 3.3.5a 客户端把阿拉伯数字画成汉字的怪字形（实测 2->目、9->匿/圄、
-- 5->图、4->大），同一个数字在不同行还会渲染出不同结果，换字号也躲不开 —— 那是
-- 客户端字体渲染层的问题。贴图渲染完全绕开字体管线，形状永远稳定。
local NUM_DIR = "Interface\\AddOns\\QuestEcho\\numbers\\"
local NUM_PREFIX = "n"
local NUM_SUFFIX = ".tga"
local NUM_W, NUM_H, NUM_GAP = 8, 11, 1
local NUM_POOL = 3      -- 位数上限（子项最多的地区也就两位数，留一位余量）
local NUM_RIGHT = 6     -- 数字右端与播放图标的间距
local COUNT_W = NUM_POOL * (NUM_W + NUM_GAP) - NUM_GAP
local ICON_PLAY = "Interface\\AddOns\\QuestEcho\\QuestEchoPlay.tga"
local ICON_STOP = "Interface\\AddOns\\QuestEcho\\QuestEchoPause.tga"
-- 展开箭头走自带贴图(不用字体符号, 也不赌客户端材质里有什么)
local ARROW_OPEN = "Interface\\AddOns\\QuestEcho\\QuestEchoArrowDown.tga"    -- 已展开, 点一下收起
local ARROW_CLOSED = "Interface\\AddOns\\QuestEcho\\QuestEchoArrowRight.tga"  -- 可展开, 点一下打开

local Browser = {}
QE.ZoneBrowser = Browser

local frame, listScroll, listChild, searchBox, emptyText
local bar, thumb
local page, pageScroll, pageChild, pagePic, pageTitle, pageSub, pageBody
local allRows = {}
local shownCount = 0
local expanded = nil    -- 一次展开一个区域
local filter = ""       -- 小写过滤词
local selectedData = nil -- 书页当前显示的那条（BuildRows 造的数据表，只读）

local Render
local HoverRow

--------------------------------------------------------------------------------
-- 数据
--------------------------------------------------------------------------------

local function Profile()
    local db = QE.Addon and QE.Addon.db
    return db and db.profile or nil
end

local function ActiveLookup()
    local pack = DataModules:GetActive()
    return pack and pack.ZoneAudioLookup or nil
end

-- 书页要的「插图 + 文字」和音频用同一把 key（file 字段），存在数据包的 ZoneMedia 里。
local function ActiveMedia()
    local pack = DataModules:GetActive()
    return pack and pack.ZoneMedia or nil
end

local zoneCache = { lookup = nil, names = nil, has = false }
local function SortedZones(zl)
    if not zoneCache.has or zoneCache.lookup ~= zl then
        local names = {}
        if zl.zones then
            for name in pairs(zl.zones) do
                tinsert(names, name)
            end
            sort(names)
        end
        zoneCache.lookup, zoneCache.names, zoneCache.has = zl, names, true
    end
    return zoneCache.names
end

local subCache = {}
local function SortedSubs(zl, zone)
    local group = zl.subzones and zl.subzones[zone]
    if not group then return nil end
    local hit = subCache[zone]
    if hit and hit.lookup == zl then return hit.names end
    local names = {}
    for name in pairs(group) do
        tinsert(names, name)
    end
    sort(names)
    subCache[zone] = { lookup = zl, names = names }
    return names
end

--------------------------------------------------------------------------------
-- 播放
--------------------------------------------------------------------------------

local function IsOn(file)
    if not file then return false end
    if SoundQueue.current and SoundQueue.current.fileName == file then
        return true
    end
    local list = SoundQueue.sounds
    local n = list and tgetn(list) or 0
    for i = 1, n do
        if list[i].fileName == file then return true end
    end
    return false
end

local function PlayOrStop(data)
    if not data or not data.file then return end
    local sq = SoundQueue
    if IsOn(data.file) then
        sq:RemoveSound(data.id)
        if sq.MaybeAutoHide then sq:MaybeAutoHide() end
        return
    end
    -- 试听接管：先清掉这一来源的旧项（含自动播报排的），点哪条就立即听哪条。
    sq:StopSource("zone")
    local soundData = {
        id = data.id,
        fileName = data.file,
        event = Enums.SoundEvent.Zone,
        title = data.name,
        name = data.name,
        _source = "zone",
    }
    if DataModules:PrepareSound(soundData) then
        sq:AddSoundToQueue(soundData)
    else
        Print(L("This place has no audio yet.", "这个地方还没有可以播放的语音。"))
    end
end

--------------------------------------------------------------------------------
-- 行数据
--------------------------------------------------------------------------------

-- 当前该显示的行，一条条排好。kind "zone"（区域）| "sub"（次级地区）。
-- 搜索时两边都匹配；区域命中或它的次级命中都会把它带出来。
local function BuildRows()
    local zl = ActiveLookup()
    local out = {}
    if not zl then return out end
    local searching = (filter ~= "")
    local names = SortedZones(zl)
    for i = 1, tgetn(names) do
        local zone = names[i]
        local all = SortedSubs(zl, zone)
        local count = all and tgetn(all) or 0
        if searching then
            local subs = nil
            if all then
                for j = 1, count do
                    if string.find(string.lower(all[j]), filter, 1, true) then
                        if not subs then subs = {} end
                        tinsert(subs, all[j])
                    end
                end
            end
            local subN = subs and tgetn(subs) or 0
            local zoneHit = string.find(string.lower(zone), filter, 1, true) ~= nil
            if zoneHit or subN > 0 then
                tinsert(out, {
                    kind = "zone", name = zone, file = zl.zones[zone],
                    id = "zone-" .. zone, count = count, open = false,
                })
                for j = 1, subN do
                    local sub = subs[j]
                    tinsert(out, {
                        kind = "sub", name = sub, zone = zone,
                        file = zl.subzones[zone][sub],
                        id = "zone-" .. zone .. "/" .. sub,
                    })
                end
            end
        else
            local open = (expanded == zone)
            tinsert(out, {
                kind = "zone", name = zone, file = zl.zones[zone],
                id = "zone-" .. zone, count = count, open = open,
            })
            if open and all then
                for j = 1, count do
                    local sub = all[j]
                    tinsert(out, {
                        kind = "sub", name = sub, zone = zone,
                        file = zl.subzones[zone][sub],
                        id = "zone-" .. zone .. "/" .. sub,
                    })
                end
            end
        end
    end
    return out
end

--------------------------------------------------------------------------------
-- 行控件
--------------------------------------------------------------------------------

local function MakeFont(parent, font)
    return parent:CreateFontString(nil, "ARTWORK", font)
end

local function UpdateWash(row)
    if not Tint then return end
    local data = row.data
    if data and IsOn(data.file) then
        Tint(row.wash, 1, 0.82, 0, 0.16)
        row.wash:Show()
    elseif row.sel then
        -- 书页正显示的这一条：浅浅留一层底，比悬停稍轻。
        Tint(row.wash, 1, 1, 1, 0.07)
        row.wash:Show()
    elseif row.over then
        Tint(row.wash, 1, 1, 1, 0.10)
        row.wash:Show()
    else
        row.wash:Hide()
    end
end

local function UpdateRowState(row)
    local data = row.data
    if not data then return end
    if IsOn(data.file) then
        row.icon:SetTexture(ICON_STOP)
        row.icon:SetAlpha(1)
    else
        row.icon:SetTexture(ICON_PLAY)
        row.icon:SetAlpha(0.35)
    end
    UpdateWash(row)
end

-- 把数量逐位铺成贴图，右对齐（贴图池在 AcquireRow 里建好，锚点已定死，这里只换图）。
-- n <= 0 时整列收起。多余的位一律隐藏，行之间不会串味。
local function SetCount(row, n)
    local pool = row.countNums
    if not pool then return end
    local s = ""
    if type(n) == "number" and n > 0 then s = tostring(n) end
    local len = string.len(s)
    for i = 1, tgetn(pool) do
        local tex = pool[i]
        local pos = len - i + 1
        if pos >= 1 then
            tex:SetTexture(NUM_DIR .. NUM_PREFIX .. string.sub(s, pos, pos) .. NUM_SUFFIX)
            tex:Show()
        else
            tex:Hide()
        end
    end
end

local function AcquireRow(i)
    local row = allRows[i]
    if row then return row end
    row = CreateFrame("Button", nil, listChild)
    row:RegisterForClicks("LeftButtonUp")
    row:EnableMouse(true)

    row.wash = row:CreateTexture(nil, "BACKGROUND")
    row.wash:SetAllPoints()
    row.wash:Hide()

    row.arrow = row:CreateTexture(nil, "ARTWORK")
    row.arrow:SetSize(13, 13)
    row.arrow:SetPoint("LEFT", row, "LEFT", 6, 0)
    row.arrow:Hide()

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(14, 14)
    row.icon:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.icon:SetTexture(ICON_PLAY)
    row.icon:SetAlpha(0.35)

    -- 数量列先建：它占住行尾一段固定宽度，地名再按它让位。
    -- 逐位的贴图**从右往左**排在播放图标左边：第 1 位贴在最右（编号越大越往左），
    -- 所以位数变化时右端永远对齐，不会左右跳。
    row.countNums = {}
    for n = 1, NUM_POOL do
        local tex = row:CreateTexture(nil, "ARTWORK")
        tex:SetSize(NUM_W, NUM_H)
        -- 灰色跟原来那行字保持一致（字体渲染是 0.55 灰，贴图用同样的顶点色）。
        tex:SetVertexColor(0.55, 0.55, 0.55)
        tex:SetPoint("RIGHT", row.icon, "LEFT",
            -(NUM_RIGHT + (n - 1) * (NUM_W + NUM_GAP)), 0)
        tex:Hide()
        row.countNums[n] = tex
    end

    row.label = MakeFont(row, "GameFontNormal")
    row.label:SetJustifyH("LEFT")
    if row.label.SetWordWrap then row.label:SetWordWrap(false) end

    -- 展开箭头只对区域行有效的小热区：点它只展开/收起，不播放。
    row.arrowHit = CreateFrame("Button", nil, row)
    row.arrowHit:SetSize(20, ROW_H)
    row.arrowHit:SetPoint("LEFT", row, "LEFT", 2, 0)
    row.arrowHit:EnableMouse(true)

    -- 点击统一走 AddClickFallback: 单个 OnClick + 出错时在聊天框可见,
    -- 与插件其它按钮同一套做法。
    local function OnRowClick(self)
        local data = self.data
        if not data then return end
        PlayOrStop(data)
        -- 点哪条书页翻到哪条；行高亮/播放态由 Render 统一刷新。
        selectedData = data
        Render()
    end
    local function OnArrowClick(self)
        local data = self:GetParent().data
        if not data or data.kind ~= "zone" then return end
        if filter ~= "" then return end
        if expanded == data.name then
            expanded = nil
        else
            expanded = data.name
        end
        Render()
    end
    if AddClickFallback then
        AddClickFallback(row, OnRowClick)
        AddClickFallback(row.arrowHit, OnArrowClick)
    else
        row:SetScript("OnClick", OnRowClick)
        row.arrowHit:SetScript("OnClick", OnArrowClick)
    end
    row:SetScript("OnEnter", function(self) HoverRow(self, true) end)
    row:SetScript("OnLeave", function(self) HoverRow(self, false) end)
    row.arrowHit:SetScript("OnEnter", function(self) HoverRow(self:GetParent(), true) end)
    row.arrowHit:SetScript("OnLeave", function(self) HoverRow(self:GetParent(), false) end)

    allRows[i] = row
    return row
end

HoverRow = function(row, over)
    row.over = over
    if over then
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
        local data = row.data
        if data then
            GameTooltip:SetText(data.name, 1, 1, 1)
            if data.kind == "zone" and data.count and data.count > 0 then
                GameTooltip:AddLine(tostring(data.count) .. " "
                    .. L("subzones", "个次级地区"), 0.6, 0.6, 0.6)
            end
            if IsOn(data.file) then
                GameTooltip:AddLine(L("Playing. Click to stop.", "正在播放，点击停止。"),
                    0.8, 0.8, 0.8)
            else
                GameTooltip:AddLine(L("Click to listen.", "点击试听。"), 0.8, 0.8, 0.8)
            end
        end
        GameTooltip:Show()
    else
        GameTooltip:Hide()
    end
    UpdateWash(row)
end

--------------------------------------------------------------------------------
-- 滚动
--------------------------------------------------------------------------------

local function UpdateBar()
    if not bar then return end
    local view = listScroll:GetHeight() or 0
    local total = listChild:GetHeight() or 0
    local range = total - view
    if range <= 0 then
        bar:Hide()
        return
    end
    bar:Show()
    local h = floor(view * view / total + 0.5)
    if h < 20 then h = 20 end
    thumb:SetHeight(h)
    local cur = listScroll:GetVerticalScroll() or 0
    if cur < 0 then cur = 0 end
    if cur > range then cur = range end
    local maxY = view - h
    local y = 0
    if range > 0 and maxY > 0 then
        y = floor(cur / range * maxY + 0.5)
    end
    thumb:ClearAllPoints()
    thumb:SetPoint("TOP", bar, "TOP", 0, -y)
end

local function BuildBar(parent)
    bar = CreateFrame("Frame", nil, parent)
    bar:SetWidth(6)
    bar:SetPoint("TOPRIGHT", listScroll, "TOPRIGHT", 4, 0)
    bar:SetPoint("BOTTOMRIGHT", listScroll, "BOTTOMRIGHT", 4, 0)
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    if Tint then Tint(track, 1, 1, 1, 0.06) end

    thumb = CreateFrame("Button", nil, bar)
    thumb:SetWidth(6)
    thumb:SetHeight(24)
    thumb:SetPoint("TOP", bar, "TOP", 0, 0)
    thumb:EnableMouse(true)
    local tex = thumb:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    if Tint then Tint(tex, 1, 0.82, 0, 0.45) end

    local dragFrom, dragAt
    local function DragStep()
        if IsMouseButtonDown and not IsMouseButtonDown("LeftButton") then
            dragFrom = nil
            thumb:SetScript("OnUpdate", nil)
            return
        end
        if not dragFrom then return end
        local _, cy = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale() or 1
        local view = listScroll:GetHeight() or 0
        local total = listChild:GetHeight() or 0
        local range = total - view
        local maxY = view - (thumb:GetHeight() or 0)
        if range <= 0 or maxY <= 0 then return end
        local dy = dragFrom - (cy or 0) / scale
        local target = dragAt + dy / maxY * range
        if target < 0 then target = 0 end
        if target > range then target = range end
        listScroll:SetVerticalScroll(target)
        UpdateBar()
    end
    thumb:SetScript("OnMouseDown", function()
        local _, cy = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale() or 1
        dragFrom = (cy or 0) / scale
        dragAt = listScroll:GetVerticalScroll() or 0
        thumb:SetScript("OnUpdate", DragStep)
    end)
    thumb:SetScript("OnMouseUp", function()
        dragFrom = nil
        thumb:SetScript("OnUpdate", nil)
    end)
end

--------------------------------------------------------------------------------
-- 书页（插图 + 文字）
--------------------------------------------------------------------------------

-- 把书页翻到当前选中的一条：标题、它在哪、插图、正文。没有插图或没有文本就留白，
-- 不挡翻页。插图/文字都按 file 从 ZoneMedia 取，取不到就显示兜底文案。
local function UpdatePage()
    if not page then return end
    local data = selectedData
    if not data then
        pageTitle:SetText("")
        pageSub:SetText("")
        pagePic:SetTexture(nil)
        pagePic:Hide()
        pageScroll:ClearAllPoints()
        pageScroll:SetPoint("TOPLEFT", page, "TOPLEFT", 10, -56)
        pageScroll:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -10, 8)
        pageBody:SetTextColor(0.6, 0.6, 0.6)
        pageBody:SetText(L("Pick a place on the left; its picture and story appear here.",
                           "从左边选一条地区，这里会显示它的插图和文字介绍。"))
    else
        local media = ActiveMedia()
        local entry = media and media[data.file] or nil
        pageTitle:SetText(data.name)
        if data.kind == "zone" then
            if data.count and data.count > 0 then
                pageSub:SetText(L("Zone", "区域") .. " · " .. data.count .. L(" subzones", " 个次级地区"))
            else
                pageSub:SetText(L("Zone", "区域"))
            end
        else
            pageSub:SetText(L("Subzone of ", "属于 ") .. tostring(data.zone))
        end

        local pic = entry and entry.pic
        if pic and pic ~= "" then
            pagePic:SetTexture(pic)
            pagePic:Show()
            pageScroll:ClearAllPoints()
            pageScroll:SetPoint("TOPLEFT", page, "TOPLEFT", 10, -(PIC_H + 62))
            pageScroll:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -10, 8)
        else
            pagePic:SetTexture(nil)
            pagePic:Hide()
            pageScroll:ClearAllPoints()
            pageScroll:SetPoint("TOPLEFT", page, "TOPLEFT", 10, -56)
            pageScroll:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -10, 8)
        end

        local text = entry and entry.text
        if text and text ~= "" then
            pageBody:SetTextColor(1, 0.95, 0.85)
            pageBody:SetText(text)
        else
            pageBody:SetTextColor(0.6, 0.6, 0.6)
            pageBody:SetText(L("No story text for this place yet.", "这个地区还没有文字介绍。"))
        end
    end
    pageScroll:SetVerticalScroll(0)
    -- 文字宽度与滚动高度都必须显式同步：滚动子控件不给宽度会退回 1 像素
    -- （同 SyncListWidth 的教训），宽度不对，换行和高度也全不对。
    local w = pageScroll:GetWidth() or 0
    if w <= 0 then w = WIDTH - PAGE_L - 34 end
    pageChild:SetWidth(w)
    pageBody:SetWidth(w)
    local h = pageBody:GetHeight() or 0
    if h < 1 then h = 1 end
    pageChild:SetHeight(h)
end

-- 建书页控件：标题、它在哪、插图、可滚动的正文。位置都按 LIST/PAGE
-- 常量排，窗口固定尺寸，不用监听尺寸变化。
local function BuildPage()
    page = CreateFrame("Frame", nil, frame)
    page:SetPoint("TOPLEFT", frame, "TOPLEFT", PAGE_L, -80)
    page:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 14)
    local pageBG = page:CreateTexture(nil, "BACKGROUND")
    pageBG:SetAllPoints()
    if Tint then Tint(pageBG, 0, 0, 0, 0.30) end

    pageTitle = MakeFont(page, "GameFontNormalLarge")
    pageTitle:SetPoint("TOPLEFT", page, "TOPLEFT", 12, -8)
    pageTitle:SetPoint("RIGHT", page, "RIGHT", -12, 0)
    pageTitle:SetJustifyH("LEFT")
    if pageTitle.SetWordWrap then pageTitle:SetWordWrap(false) end

    -- 副标题里有数字（"区域 · 4 个次级地区"），所以走 12px 那档字体：
    -- 这个客户端 10px 那档对个别数字栅格化会糊。
    pageSub = MakeFont(page, "GameFontNormal")
    pageSub:SetTextColor(0.62, 0.62, 0.62)
    pageSub:SetPoint("TOPLEFT", pageTitle, "BOTTOMLEFT", 0, -2)
    pageSub:SetPoint("RIGHT", page, "RIGHT", -12, 0)
    pageSub:SetJustifyH("LEFT")
    if pageSub.SetWordWrap then pageSub:SetWordWrap(false) end

    pagePic = page:CreateTexture(nil, "ARTWORK")
    pagePic:SetSize(PIC_W, PIC_H)
    pagePic:SetPoint("TOP", page, "TOP", 0, -54)
    pagePic:Hide()

    pageScroll = CreateFrame("ScrollFrame", nil, page)
    pageScroll:SetPoint("TOPLEFT", page, "TOPLEFT", 10, -(PIC_H + 62))
    pageScroll:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -10, 8)
    if pageScroll.SetClipsChildren then
        pageScroll:SetClipsChildren(true)
    end
    pageScroll:EnableMouse(true)
    pageScroll:EnableMouseWheel(true)
    pageScroll:SetScript("OnMouseWheel", function(self, delta)
        local range = (pageChild:GetHeight() or 0) - (self:GetHeight() or 0)
        if range <= 0 then return end
        local target = (self:GetVerticalScroll() or 0) - (delta or 0) * 40
        if target < 0 then target = 0 end
        if target > range then target = range end
        self:SetVerticalScroll(target)
    end)

    pageChild = CreateFrame("Frame", nil, pageScroll)
    -- 宽度必须显式同步到视口: 见 SyncListWidth 的说明。
    pageChild:SetSize(WIDTH - PAGE_L - 34, 1)
    pageScroll:SetScrollChild(pageChild)

    pageBody = pageChild:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    pageBody:SetJustifyH("LEFT")
    pageBody:SetPoint("TOPLEFT", pageChild, "TOPLEFT", 0, 0)
    pageBody:SetWidth(WIDTH - PAGE_L - 34)
    if pageBody.SetWordWrap then pageBody:SetWordWrap(true) end
end

--------------------------------------------------------------------------------
-- 渲染
--------------------------------------------------------------------------------

-- 滚动子控件必须显式给出视口宽度: 只设高度的话, 行的实际宽度会停在 1 像素 --
-- 文字能照常画出来, 但点击只能命中最左侧一列, 表现为"点了没反应"。列表每次
-- 渲染时都同步一次, 窗口尺寸固定所以不必监听尺寸变化。
local function SyncListWidth()
    if not listChild or not listScroll then return end
    local w = listScroll:GetWidth() or 0
    if w <= 0 then w = LIST_W end
    listChild:SetWidth(w)
end

Render = function()
    if not frame then return end
    SyncListWidth()
    local list = BuildRows()
    local y = 0
    for i = 1, tgetn(list) do
        local data = list[i]
        local row = AcquireRow(i)
        row.data = data
        local h
        if data.kind == "zone" then h = ROW_H else h = SUB_H end
        row:SetHeight(h)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", listChild, "TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", listChild, "TOPRIGHT", 0, -y)
        y = y + h

        row.label:ClearAllPoints()
        row.label:SetText(data.name)
        -- 宽度一律显式给死。只挂一个左锚点时宽度是自适应的，客户端字体在个别字号
        -- 下测量的宽度偏大，4 个字也会被截成"两个字 + 省略号"；写死宽度并关掉折行
        -- 之后，显示宽度就是算出来的那个数，不会再看字体脸色。
        -- 右侧留白：区域行要给数量列和播放图标让位；子项行没有数量，只让图标。
        -- 列表宽度万一没同步上（1 像素那种），这里会算出负宽度把文字挤没，所以兜底。
        local lw = listChild:GetWidth() or LIST_W
        if lw < 160 then lw = LIST_W end
        if data.kind == "zone" then
            row.label:SetFontObject("GameFontNormal")
            row.label:SetPoint("LEFT", row, "LEFT", 26, 0)
            row.label:SetWidth(lw - 26 - (COUNT_W + NUM_RIGHT + 14 + 8))
            if filter ~= "" then
                row.arrow:Hide()
                row.arrowHit:Hide()
            else
                row.arrowHit:Show()
                if data.count and data.count > 0 then
                    row.arrow:SetTexture(data.open and ARROW_OPEN or ARROW_CLOSED)
                    row.arrow:Show()
                else
                    row.arrow:Hide()
                end
            end
            if data.count and data.count > 0 then
                SetCount(row, data.count)
            else
                SetCount(row, 0)
            end
        else
            row.label:SetFontObject("GameFontHighlightSmall")
            row.label:SetPoint("LEFT", row, "LEFT", 36, 0)
            row.label:SetWidth(lw - 36 - (14 + 8 + 8))
            row.arrow:Hide()
            row.arrowHit:Hide()
            SetCount(row, 0)
        end
        row.over = false
        row.sel = (selectedData ~= nil and selectedData.id == data.id)
        row:Show()
        UpdateRowState(row)
    end
    for i = tgetn(list) + 1, tgetn(allRows) do
        allRows[i].data = nil
        allRows[i]:Hide()
    end
    shownCount = tgetn(list)
    listChild:SetHeight(y > 0 and y or 1)
    if shownCount == 0 then
        if ActiveLookup() then
            emptyText:SetText(L("No matching places.", "没有匹配的地区。"))
        else
            emptyText:SetText(L("No voice data pack loaded.", "语音数据包未加载。"))
        end
        emptyText:Show()
    else
        emptyText:Hide()
    end
    UpdateBar()
    UpdatePage()
end

-- 打开窗口时，如果队列里正有一条 zone 语音，把列表滚到它那里（方便当场停掉）。
-- 没有在播的就保持原位。
local function ScrollToPlaying()
    local target = 0
    for i = 1, shownCount do
        local row = allRows[i]
        if row and row.data and IsOn(row.data.file) then
            target = i
            break
        end
    end
    if target == 0 then return end
    -- 有正在播的就顺手把书页翻到它（打开窗口常常就是为了当场停掉）。
    local playingRow = allRows[target]
    if playingRow and playingRow.data
        and (not selectedData or selectedData.id ~= playingRow.data.id) then
        selectedData = playingRow.data
        Render()
    end
    local y = 0
    for i = 1, target - 1 do
        local row = allRows[i]
        if row and row.data and row.data.kind == "sub" then
            y = y + SUB_H
        else
            y = y + ROW_H
        end
    end
    local view = listScroll:GetHeight() or 0
    local want = y - view / 3
    if want < 0 then want = 0 end
    local range = (listChild:GetHeight() or 0) - view
    if range > 0 and want > range then want = range end
    listScroll:SetVerticalScroll(want)
    UpdateBar()
end

--------------------------------------------------------------------------------
-- 窗口
--------------------------------------------------------------------------------

local function BuildFrame()
    if frame then return end
    frame = CreatePanelFrame and CreatePanelFrame("QuestEchoZoneBrowser", UIParent)
        or CreateFrame("Frame", "QuestEchoZoneBrowser", UIParent)
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetFrameStrata("DIALOG")
    if frame._qeHasBackdrop then
        frame:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        frame:SetBackdropColor(0.05, 0.05, 0.08, 0.97)
        frame:SetBackdropBorderColor(0.25, 0.22, 0.20, 0.80)
    end
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(f) f:StartMoving() end)
    frame:SetScript("OnDragStop", function(f)
        f:StopMovingOrSizing()
        local x, y = f:GetCenter()
        local ux, uy = UIParent:GetCenter()
        local p = Profile()
        if p and x and y and ux and uy then
            p.ZoneWinX = floor(x - ux + 0.5)
            p.ZoneWinY = floor(y - uy + 0.5)
        end
    end)

    local title = MakeFont(frame, "GameFontNormalLarge")
    title:SetPoint("TOP", frame, "TOP", 0, -10)
    title:SetText(L("Azeroth Zone Introductions", "艾泽拉斯地区介绍"))
    Browser._Title = title

    local note = MakeFont(frame, "GameFontNormalSmall")
    note:SetTextColor(0.6, 0.6, 0.6)
    note:SetPoint("TOP", frame, "TOP", 0, -30)
    note:SetText(L("Click a line to listen; the arrow opens its subzones; the right page shows its picture and story.",
                   "点一条听一条; 左边箭头展开次级地区, 右侧书页显示插图和文字介绍。"))

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetSize(26, 26)
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)

    searchBox = CreateFrame("EditBox", nil, frame)
    searchBox:SetHeight(20)
    searchBox:SetPoint("TOPLEFT", frame, "TOPLEFT", LIST_X, -50)
    searchBox:SetWidth(LIST_W)
    pcall(searchBox.SetFontObject, searchBox, GameFontHighlightSmall)
    pcall(searchBox.SetAutoFocus, searchBox, false)
    local sbg = searchBox:CreateTexture(nil, "BACKGROUND")
    sbg:SetAllPoints()
    if Tint then Tint(sbg, 0.12, 0.12, 0.16, 1) end
    searchBox:SetTextInsets(6, 6, 0, 0)
    searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    -- 占位文字挂在搜索框自己身上: 挂在窗口上的话会被搜索框的背景纹理整个盖住。
    local ph = searchBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ph:SetTextColor(0.5, 0.5, 0.5)
    ph:SetPoint("LEFT", searchBox, "LEFT", 6, 0)
    ph:SetText(L("Search", "搜索"))
    Browser._Placeholder = ph

    searchBox:SetScript("OnTextChanged", function(self)
        local raw = self:GetText() or ""
        if raw == "" then ph:Show() else ph:Hide() end
        local text = string.lower(raw)
        if text ~= filter then
            filter = text
            listScroll:SetVerticalScroll(0)
            Render()
        end
    end)

    local listBG = frame:CreateTexture(nil, "BACKGROUND")
    listBG:SetPoint("TOPLEFT", frame, "TOPLEFT", LIST_X - 4, -76)
    listBG:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", LIST_X + LIST_W + 4, 10)
    if Tint then Tint(listBG, 0, 0, 0, 0.30) end

    listScroll = CreateFrame("ScrollFrame", nil, frame)
    listScroll:SetPoint("TOPLEFT", frame, "TOPLEFT", LIST_X, -80)
    listScroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", LIST_X + LIST_W, 14)
    if listScroll.SetClipsChildren then
        listScroll:SetClipsChildren(true)
    end
    listScroll:EnableMouseWheel(true)
    listScroll:SetScript("OnMouseWheel", function(self, delta)
        local range = (listChild:GetHeight() or 0) - (self:GetHeight() or 0)
        if range <= 0 then return end
        local target = (self:GetVerticalScroll() or 0) - (delta or 0) * 40
        if target < 0 then target = 0 end
        if target > range then target = range end
        self:SetVerticalScroll(target)
        UpdateBar()
    end)
    listScroll:SetScript("OnVerticalScroll", function() UpdateBar() end)

    listChild = CreateFrame("Frame", nil, listScroll)
    -- 宽度必须是视口宽度: 见 SyncListWidth 的说明。
    listChild:SetSize(LIST_W, 1)
    listScroll:SetScrollChild(listChild)

    BuildBar(frame)
    BuildPage()

    emptyText = MakeFont(frame, "GameFontNormalSmall")
    emptyText:SetTextColor(0.6, 0.6, 0.6)
    emptyText:SetPoint("TOP", listScroll, "TOP", 0, -30)
    emptyText:Hide()

    -- 每 0.25 秒把可见行的播放状态(图标/底色)对齐队列。
    local acc = 0
    frame:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + (elapsed or 0)
        if acc < 0.25 then return end
        acc = 0
        for i = 1, shownCount do
            local row = allRows[i]
            if row and row.data then
                UpdateRowState(row)
            end
        end
    end)

    tinsert(UISpecialFrames, "QuestEchoZoneBrowser")

    frame:ClearAllPoints()
    local p = Profile()
    local x = (p and p.ZoneWinX) or 220
    local y = (p and p.ZoneWinY) or 0
    frame:SetPoint("CENTER", UIParent, "CENTER", x, y)
    frame:Hide()
end

function Browser:Toggle()
    local ok, err = pcall(BuildFrame)
    if not ok or not frame then
        Print("[QuestEcho] 无法创建艾泽拉斯地区介绍窗口: " .. tostring(err))
        return
    end
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        Render()
        ScrollToPlaying()
    end
end

-- 供设置页 / 小地图菜单 / 测试使用
Browser._BuildRows = BuildRows
Browser._PlayOrStop = PlayOrStop
Browser._IsOn = IsOn
Browser._Build = BuildFrame
Browser._Render = Render
Browser._ScrollToPlaying = ScrollToPlaying
Browser._SetFilter = function(t)
    filter = string.lower(t or "")
end
Browser._GetFilter = function() return filter end
Browser._SetExpanded = function(z) expanded = z end
Browser._GetRow = function(i) return allRows[i] end
Browser._RowCount = function() return shownCount end
Browser._GetListChild = function() return listChild end
Browser._SyncListWidth = SyncListWidth

-- 书页测试口
Browser._GetSelected = function() return selectedData end
Browser._SetSelectedData = function(d)
    selectedData = d
    UpdatePage()
end
Browser._ClearSelection = function()
    selectedData = nil
    UpdatePage()
end
Browser._GetPageTitle = function() return pageTitle and pageTitle:GetText() or "" end
Browser._GetPageSub = function() return pageSub and pageSub:GetText() or "" end
Browser._GetPageText = function() return pageBody and pageBody:GetText() or "" end
Browser._GetPagePic = function() return pagePic and pagePic:GetTexture() or "" end
-- 控件本体也要能拿到：插图有没有显示、正文宽度跟没跟上滚动框，都得直接量。
Browser._GetPagePicFrame = function() return pagePic end
Browser._GetPageScroll = function() return pageScroll end
Browser._GetPageChild = function() return pageChild end

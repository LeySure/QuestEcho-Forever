-- Welcome.lua
--
-- 第一次进游戏弹一次的欢迎窗口(2.0.1)。只问两件事: 台词要不要显示在状态栏上、
-- 朗读时要不要压低游戏其它声音。末尾一个按钮把官网地址放出来, 玩家复制去补台词。
-- 之后随时可以在设置面板的「主设置」页里重新打开。
local QE = QuestEcho
if not QE or not QE.Addon then return end

local Addon = QE.Addon
local CAP = QE.CAP or {}
local L = QE.L or function(en, zh) return zh or en end
local Print = QE.Print or function(m) DEFAULT_CHAT_FRAME:AddMessage(tostring(m)) end
local MakeButton = QE.MakeButton
local AddClickFallback = QE.AddClickFallback
local AttachTooltip = QE.AttachTooltip
local CreatePanelFrame = QE.CreatePanelFrame

local Welcome = {}
QE.Welcome = Welcome

local WIDTH, HEIGHT = 620, 430
local SITE = "https://questecho.dpdns.org/"

local function Fs(parent, font, r, g, b)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    fs:SetTextColor(r or 1, g or 1, b or 1)
    return fs
end

-- 两块卡片: 显示状态栏 / 隐藏状态栏。选中的那块描金边。
local function Tile(parent, title, text, onPick)
    local tile = CreateFrame("Button", nil, parent)
    tile:SetSize(276, 78)
    tile:EnableMouse(true)
    if AddClickFallback then AddClickFallback(tile, onPick) end

    local bg = tile:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    if QE.Tint then QE.Tint(bg, 0.10, 0.10, 0.13, 1) end
    tile.bg = bg

    local edge = tile:CreateTexture(nil, "BORDER")
    edge:SetAllPoints()
    if QE.Tint then QE.Tint(edge, 0.35, 0.30, 0.22, 0.0) end
    tile.edge = edge

    local head = Fs(tile, "GameFontNormal", 1, 0.82, 0)
    head:SetPoint("TOPLEFT", tile, "TOPLEFT", 12, -10)
    head:SetText(title)

    local body = Fs(tile, "GameFontHighlightSmall", 0.78, 0.78, 0.78)
    body:SetPoint("TOPLEFT", tile, "TOPLEFT", 12, -30)
    body:SetPoint("RIGHT", tile, "RIGHT", -12, 0)
    body:SetJustifyH("LEFT")
    body:SetText(text)

    tile.SetPicked = function(self, picked)
        if QE.Tint then
            if picked then
                QE.Tint(self.edge, 1, 0.82, 0, 0.85)
                QE.Tint(self.bg, 0.16, 0.14, 0.10, 1)
            else
                QE.Tint(self.edge, 0.35, 0.30, 0.22, 0.0)
                QE.Tint(self.bg, 0.10, 0.10, 0.13, 1)
            end
        end
    end
    return tile
end

function Welcome:Build()
    local frame = CreatePanelFrame and CreatePanelFrame("QuestEchoWelcomeFrame", UIParent)
        or CreateFrame("Frame", "QuestEchoWelcomeFrame", UIParent)
    self.frame = frame
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 30)
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(f) f:StartMoving() end)
    frame:SetScript("OnDragStop", function(f) f:StopMovingOrSizing() end)
    frame:SetClampedToScreen(true)
    if frame._qeHasBackdrop then
        frame:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        frame:SetBackdropColor(0.05, 0.05, 0.08, 0.98)
        frame:SetBackdropBorderColor(0.30, 0.26, 0.20, 0.85)
    end
    -- 不管怎么关的(完成 / 右上 X / Esc), 关了就算见过。
    frame:SetScript("OnHide", function()
        if Addon.db and Addon.db.global then Addon.db.global.Welcomed = true end
        QuestEchoDB = Addon.db
    end)
    table.insert(UISpecialFrames, "QuestEchoWelcomeFrame")

    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetSize(40, 40)
    icon:SetPoint("TOPLEFT", frame, "TOPLEFT", 22, -20)
    icon:SetTexture("Interface\\AddOns\\QuestEcho\\QuestEchoIcon.tga")

    local title = Fs(frame, "GameFontNormalLarge", 1, 0.82, 0)
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 74, -24)
    title:SetText(L("Welcome to QuestEcho", "欢迎使用 QuestEcho"))

    local intro = Fs(frame, "GameFontHighlightSmall", 0.80, 0.80, 0.80)
    intro:SetPoint("TOPLEFT", frame, "TOPLEFT", 74, -50)
    intro:SetPoint("RIGHT", frame, "RIGHT", -22, 0)
    intro:SetJustifyH("LEFT")
    intro:SetText(L("QuestEcho reads the quest and NPC lines out loud, in Chinese, with the official text on screen. Two things are worth deciding before you start.",
                    "QuestEcho 把任务和 NPC 的台词念出来, 中文语音配官方原文。开始前先定两件事就好。"))

    -- 一、台词怎么显示
    local showHead = Fs(frame, "GameFontNormal", 1, 0.82, 0)
    showHead:SetPoint("TOPLEFT", frame, "TOPLEFT", 24, -100)
    showHead:SetText(L("How lines appear", "台词如何显示"))

    local tiles = {}
    local function pick(which)
        Addon.db.profile.ShowUI = which
        if which then Addon.db.profile.Captions = true end
        if QE.SoundQueueUI and QE.SoundQueueUI.Update then
            pcall(QE.SoundQueueUI.Update, QE.SoundQueueUI)
        end
        for k, t in pairs(tiles) do t:SetPicked(k == (which and "show" or "hide")) end
    end
    tiles.show = Tile(frame, L("Show the status bar", "显示状态栏"),
        L("The line being spoken is written on a movable bar.",
          "正在念的台词显示在一个可拖动的状态栏上。"),
        function() pick(true) end)
    tiles.show:SetPoint("TOPLEFT", frame, "TOPLEFT", 24, -122)
    tiles.hide = Tile(frame, L("Hide the status bar", "隐藏状态栏"),
        L("Voice only. Nothing is drawn on screen.",
          "只听语音, 屏幕上什么都不显示。"),
        function() pick(false) end)
    tiles.hide:SetPoint("TOPLEFT", frame, "TOPLEFT", 320, -122)
    self.tiles = tiles
    -- 建好就按当前设置点亮, 不改动设置本身。
    tiles.show:SetPicked(Addon.db.profile.ShowUI and true or false)
    tiles.hide:SetPicked(not (Addon.db.profile.ShowUI and true or false))

    -- 二、朗读时压低其它声音
    local lowerHead = Fs(frame, "GameFontNormal", 1, 0.82, 0)
    lowerHead:SetPoint("TOPLEFT", frame, "TOPLEFT", 24, -214)
    lowerHead:SetText(L("Other sounds", "其它声音"))

    local lower = nil
    local lowerAvailable = QE.LowerSounds and QE.LowerSounds.IsAvailable
        and QE.LowerSounds:IsAvailable()
    if lowerAvailable then
        lower = CreateFrame("Button", nil, frame)
        lower:SetSize(20, 20)
        lower:SetPoint("TOPLEFT", frame, "TOPLEFT", 26, -238)
        lower:EnableMouse(true)
        local box = lower:CreateTexture(nil, "BACKGROUND")
        box:SetAllPoints()
        if QE.Tint then QE.Tint(box, 0.10, 0.10, 0.12, 0.95) end
        local mark = lower:CreateTexture(nil, "ARTWORK")
        mark:SetPoint("TOPLEFT", 3, -3)
        mark:SetPoint("BOTTOMRIGHT", -3, 3)
        if QE.Tint then QE.Tint(mark, 1, 0.82, 0, 1) end
        local label = Fs(frame, "GameFontNormal", 1, 1, 1)
        label:SetPoint("LEFT", lower, "RIGHT", 8, 0)
        label:SetText(L("Lower other sounds while reading", "朗读时降低其它声音"))
        local function render()
            if Addon.db.profile.LowerOthers then mark:Show() else mark:Hide() end
        end
        if AddClickFallback then
            AddClickFallback(lower, function()
                Addon.db.profile.LowerOthers = not Addon.db.profile.LowerOthers
                render()
                if QE.LowerSounds then QE.LowerSounds:RefreshConfig() end
            end)
        end
        render()
        self.lowerMark = mark
        AttachTooltip(lower, L("Turn the game's music, ambience, sound effects and dialog down while a line is spoken, and back up afterwards.",
                               "朗读时把游戏的音乐、环境、音效、对话压低, 念完再恢复。"))
    else
        local note = Fs(frame, "GameFontHighlightSmall", 0.7, 0.7, 0.7)
        note:SetPoint("TOPLEFT", frame, "TOPLEFT", 26, -238)
        note:SetPoint("RIGHT", frame, "RIGHT", -24, 0)
        note:SetJustifyH("LEFT")
        note:SetText(L("This client cannot lower other sounds separately: the voice plays through the music channel here.",
                       "这个客户端没法单独压低其它声音: 语音本身走的就是音乐通道。"))
    end

    -- 底部: 分隔线 + 按钮
    local rule = frame:CreateTexture(nil, "ARTWORK")
    rule:SetHeight(1)
    rule:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 24, 52)
    rule:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -24, 52)
    if QE.Tint then QE.Tint(rule, 0.35, 0.30, 0.22, 0.8) end

    local done = MakeButton(frame, 150, 24, L("Done", "完成"), function()
        frame:Hide()
        if QE.OptionsUI and QE.OptionsUI.RefreshAll then QE.OptionsUI:RefreshAll() end
    end)
    done:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -24, 16)

    local settings = MakeButton(frame, 150, 24, L("All settings", "全部设置"), function()
        frame:Hide()
        if QE.OptionsUI and QE.OptionsUI.Open then QE.OptionsUI:Open() end
    end)
    settings:SetPoint("RIGHT", done, "LEFT", -10, 0)

    -- 用户要的那个按钮: 点了把官网地址摆出来给复制
    local site = MakeButton(frame, 210, 24,
        L("Visit the site and help improve the voices", "访问官网 · 帮助完善语音"),
        function()
            if QE.ShowCopyPopup then
                QE.ShowCopyPopup("QuestEcho " .. L("site", "官网"), SITE)
            else
                Print("[QuestEcho] " .. SITE)
            end
        end)
    site:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 24, 16)
    AttachTooltip(site, L("Opens a small window with the address selected; press Ctrl+C, then paste it into your browser.",
                          "弹出一个小窗口并全选地址, 按 Ctrl+C 复制, 再粘到浏览器打开。"))

    frame:Hide()
end

function Welcome:Sync()
    if not self.frame then return end
    local show = Addon.db.profile.ShowUI and true or false
    if self.tiles then
        self.tiles.show:SetPicked(show)
        self.tiles.hide:SetPicked(not show)
    end
end

function Welcome:Show()
    if not Addon.db then return end
    if not self.frame then
        local ok, err = pcall(function() self:Build() end)
        if not ok then
            Print("[QuestEcho] 欢迎窗口创建失败: " .. tostring(err))
            return
        end
    end
    if self.lowerMark then
        if Addon.db.profile.LowerOthers then self.lowerMark:Show() else self.lowerMark:Hide() end
    end
    self.frame:Show()
end
QE.Welcome = Welcome

-- 每个账号只弹一次。战斗中不弹: 那时候屏幕上多一个窗口最招人烦。
local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:SetScript("OnEvent", function()
    events:UnregisterEvent("PLAYER_ENTERING_WORLD")
    if not (Addon.db and Addon.db.global) then return end
    if Addon.db.global.Welcomed then return end
    local function Open()
        if InCombatLockdown and InCombatLockdown() then return end
        Welcome:Show()
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(2, Open)
    else
        QE.After(2, Open)
    end
end)

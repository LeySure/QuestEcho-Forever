-- Minimap.lua
-- A round button on the minimap. Left-click opens the options, right-click
-- pauses or resumes the queue, and dragging it around the rim moves it (the
-- angle is saved). It uses the client's own minimap tracking border so it
-- matches the rest of the minimap.

local QE = QuestEcho
if not QE or not QE.Addon then return end

local MinimapButton = {}
QE.Minimap = MinimapButton

local BUTTON_SIZE = 32
local RADIUS_PADDING = 6
-- The client cannot load PNG (only BLP/TGA/BMP), which is why the button used
-- to show an empty icon. QuestEchoIcon.tga is a 32-bit TGA with alpha, the
-- format this client reads without trouble.
local ICON_TEX = "Interface\\AddOns\\QuestEcho\\QuestEchoIcon.tga"

local function profile()
    return QE.Addon.db and QE.Addon.db.profile
end

local function OpenOptions()
    local O = QE.OptionsUI
    if O and O.Open then
        pcall(O.Open, O)
    elseif O and O.Toggle then
        pcall(O.Toggle, O)
    end
end

-- 右键菜单: 艾泽拉斯地区介绍 / 设置。客户端没有菜单系统时退回直接打开设置。
local menuFrame
local function OpenMenu()
    local hasMenu = (type(EasyMenu) == "function"
        and type(UIDropDownMenu_Initialize) == "function")
    if not hasMenu then
        OpenOptions()
        return
    end
    if not menuFrame then
        menuFrame = CreateFrame("Frame", "QuestEchoMinimapMenu", UIParent, "UIDropDownMenuTemplate")
    end
    local L = QE.L or function(en, zh) return zh or en end
    local menu = {
        { text = L("Azeroth Zone Introductions", "艾泽拉斯地区介绍"), notCheckable = true, func = function()
            if QE.ZoneBrowser and QE.ZoneBrowser.Toggle then
                QE.ZoneBrowser:Toggle()
            end
        end },
        { text = L("Settings", "设置"), notCheckable = true, func = OpenOptions },
    }
    local ok = pcall(EasyMenu, menu, menuFrame, "cursor", 0, 0, "MENU", 2)
    if not ok then
        pcall(HideDropDownMenu, 1)
        OpenOptions()
    end
end

local function UpdatePosition(button)
    local p = profile()
    local angle = math.rad((p and p.MinimapAngle) or 225)
    local radius = (Minimap:GetWidth() / 2) + RADIUS_PADDING
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function DragTo(button)
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    cx, cy = cx / scale, cy / scale
    local p = profile()
    if p then p.MinimapAngle = math.deg(math.atan2(cy - my, cx - mx)) end
    UpdatePosition(button)
end

function MinimapButton:Create()
    if self.button then return self.button end
    local button = CreateFrame("Button", "QuestEchoMinimapButton", Minimap)
    self.button = button
    button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    -- Layer order, bottom to top: the client's round background, then our
    -- artwork, then the gold ring. Putting the artwork under the background
    -- hides it completely, because that texture is opaque.
    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetPoint("CENTER", button, "CENTER", 0, 0)
    button.Background = background

    local icon = button:CreateTexture(nil, "BORDER")
    icon:SetSize(20, 20)
    icon:SetTexture(ICON_TEX)
    icon:SetPoint("CENTER", button, "CENTER", 0, 0)
    -- slight trim so a square source image cannot poke outside the gold ring
    icon:SetTexCoord(0.04, 0.96, 0.04, 0.96)
    button.Icon = icon

    -- the gold ring the client uses around minimap buttons
    local overlay = button:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
    button.Border = overlay

    -- 右键弹菜单(艾泽拉斯地区介绍 / 设置), 左键暂停/继续。
    button:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then
            OpenMenu()
        elseif QE.SoundQueue then
            QE.SoundQueue:TogglePauseQueue()
        end
    end)
    button:SetScript("OnEnter", function(self)
        local loc = GetLocale()
        local zh = (loc == "zhCN" or loc == "zhTW")
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("QuestEcho")
        GameTooltip:AddLine(zh and "左键：暂停/继续　右键：菜单　拖动：移动"
                                or "Left-click: pause/resume  Right-click: menu  Drag: move",
            1, 1, 1, true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", DragTo)
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    UpdatePosition(button)
    return button
end

function MinimapButton:ApplySettings()
    if not self.button then return end
    local p = profile()
    -- SetShown arrived with 3.x; Show/Hide is the 1.12-safe spelling.
    if p and p.MinimapButton ~= false then
        self.button:Show()
    else
        self.button:Hide()
    end
    UpdatePosition(self.button)
end

-- Build it after login so the saved variables and Minimap are ready.
local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function()
    MinimapButton:Create()
    MinimapButton:ApplySettings()
end)

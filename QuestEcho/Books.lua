-- Books.lua
-- 书籍朗读：打开就自动念、整本连念、翻页自动跟上。
--
-- 数据链：ITEM_TEXT_READY -> BookChecksum(客户端原文) -> BookLookup(书名+页码+校验码)
-- -> pageId -> "book-<pageId>" -> generated/sounds/items/book-<pageId>.ogg
-- BookLookup 随数据包发布（生成器 outputs/_gen_zone_book_data.py）。
--
-- 行为（与参考实现一致）：
--   * 打开与翻页由同一个事件送达，都表示"现在看的是这一页"；
--   * 当前页不在队列里 -> 丢掉书籍队列，从该页排到全书末页（整本连念）；
--   * 翻到已在队列里的页 -> 什么都不做，不打断正在念的那一页；
--   * 邮件（别人写的信，同一个窗口显示）一律不念；
--   * 关掉窗口继续念（用状态栏暂停/清空来控制）。
--
-- Lua 5.0 兼容：无 '#'、无 '%' 运算符（math.mod 兜底）、无十六进制字面量。

local QE = QuestEcho
if not QE or not QE.DataModules or not QE.SoundQueue then return end
local DataModules = QE.DataModules
local SoundQueue = QE.SoundQueue
local Enums = QE.Enums
local L = QE.L or function(en) return en end

local tinsert = table.insert
local tgetn = table.getn
local sbyte, slen, sgsub, sfind = string.byte, string.len, string.gsub, string.find
local floor = math.floor
local mod = math.mod or function(a, b) return a - floor(a / b) * b end

-- =============================================================================
-- 校验码：与数据包 index 里的数字同源
--   sum = len(text) % MODULUS；逐字节 sum = (sum * 31 + byte) % MODULUS
-- 输入先归一化：CRLF/CR 与 $B 都成为换行、去行尾空白、压空行、两端裁剪。
-- 模数是最大有符号 32 位质数，中间值在 double 里保持精确。
-- =============================================================================
local MODULUS = 2147483647
local FACTOR = 31

local function BookNormalise(text)
    text = sgsub(text, "\r\n", "\n")
    text = sgsub(text, "\r", "\n")
    text = sgsub(text, "%$[Bb]", "\n")
    text = sgsub(text, "[ \t]+\n", "\n")
    text = sgsub(text, "[ \t]+$", "")
    while sfind(text, "\n\n\n", 1, true) do
        text = sgsub(text, "\n\n\n", "\n\n")
    end
    text = sgsub(text, "^%s+", "")
    text = sgsub(text, "%s+$", "")
    return text
end

local function BookChecksum(text)
    if type(text) ~= "string" then return 0 end
    text = BookNormalise(text)
    local sum = mod(slen(text), MODULUS)
    for i = 1, slen(text) do
        sum = mod(sum * FACTOR + sbyte(text, i), MODULUS)
    end
    return sum
end

-- 邮件用的是同一个 ItemText 窗口。发件人一栏只对邮件有值；退还的信连发件人都没有，
-- 靠 MailFrame 打开这一条兜住。别人的私人信件不替人念。
local function IsMailText()
    if type(ItemTextGetCreator) == "function" and ItemTextGetCreator() then
        return true
    end
    local mail = _G.MailFrame
    if mail and mail.IsShown and mail:IsShown() then
        return true
    end
    return false
end

-- =============================================================================
-- 查找与排队
-- =============================================================================
local function ActiveLookup()
    local pack = DataModules:GetActive()
    return pack and pack.BookLookup or nil
end

-- 该书从 pageId 起的页序（含本页）。pageId 不在书里就返回 nil。
local function PagesFrom(bl, pageId)
    local rec = bl.pages and bl.pages[pageId]
    local title = rec and rec.book
    local book = title and bl.books and bl.books[title]
    local list = book and book.pages
    if not list then return nil end
    local rest, found = {}, false
    for i = 1, tgetn(list) do
        local id = list[i]
        if id == pageId then found = true end
        if found then tinsert(rest, id) end
    end
    if not found then return nil end
    return rest
end

local function IsQueued(pageId)
    local name = "book-" .. pageId
    local cur = SoundQueue.current
    if cur and cur.fileName == name then return true end
    local list = SoundQueue.sounds
    for i = 1, tgetn(list) do
        if list[i].fileName == name then return true end
    end
    return false
end

-- 排 [pageId..末尾]。没有音频的页直接跳过（不排静音）。
local function PlayFrom(bl, pageId)
    local pages = PagesFrom(bl, pageId)
    if not pages then
        -- 数据包里只有"校验码 -> 页号"的散表、没有书页列表时(全书只此一页)，
        -- 至少把这一页本身念出来。参考实现在这里直接放弃，结果是玩家盯着一页
        -- 有音频的内容却一片安静。
        pages = { pageId }
    end
    local queued = 0
    for i = 1, tgetn(pages) do
        local id = pages[i]
        local rec = bl.pages[id]
        local label = tostring((rec and rec.book) or L("Book", "书页"))
        local book = rec and rec.book and bl.books and bl.books[rec.book]
        local total = (book and book.pages and tgetn(book.pages)) or 0
        if rec and rec.number and total > 0 then
            label = label .. " (" .. rec.number .. "/" .. total .. ")"
        end
        local soundData = {
            id = "book-" .. id,
            fileName = "book-" .. id,
            event = Enums.SoundEvent.Book,
            title = label,
            name = label,
            _source = "book",
        }
        if DataModules:PrepareSound(soundData) then
            SoundQueue:AddSoundToQueue(soundData)
            queued = queued + 1
        end
    end
    return queued
end

-- 开书 / 翻页的总入口：已在队列里 -> 不打断；否则丢掉书籍队列，从这页重排。
local function SyncTo(pageId)
    local bl = ActiveLookup()
    if not bl or not bl.index then return 0 end
    if IsQueued(pageId) then return 0 end
    SoundQueue:StopSource("book")
    return PlayFrom(bl, pageId)
end

-- 屏幕上这一页的 pageId，或 nil。
local function PageOnScreen()
    if IsMailText() then return nil end
    local text = ItemTextGetText and ItemTextGetText()
    if type(text) ~= "string" or text == "" then return nil end
    local bl = ActiveLookup()
    if not bl or not bl.index then return nil end
    local checksum = BookChecksum(text)
    local title = ItemTextGetItem and ItemTextGetItem()
    local number = 1
    if type(ItemTextGetPage) == "function" then
        number = ItemTextGetPage() or 1
    end
    -- 书名+页码+校验码；页码对不上（客户端版本差异）就退回"校验码全局唯一"表。
    local byTitle = title and bl.index[title]
    local byNumber = byTitle and byTitle[number]
    local found = byNumber and byNumber[checksum]
    if not found then
        found = bl.loose and bl.loose[checksum]
    end
    return found
end

-- =============================================================================
-- 事件
-- =============================================================================
local function HandleTextReady()
    local pageId = PageOnScreen()
    if pageId then
        SyncTo(pageId)
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ITEM_TEXT_READY")
frame:SetScript("OnEvent", function()
    local ok, err = pcall(HandleTextReady)
    if not ok then
        QE.Debug:Print("Books ERR: %s", tostring(err))
    end
end)

-- 供 /qe 自检与测试使用
QE.Books = {
    Checksum = BookChecksum,
    Normalise = BookNormalise,
    SyncTo = SyncTo,
    PageOnScreen = PageOnScreen,
    HandleTextReady = HandleTextReady,
}

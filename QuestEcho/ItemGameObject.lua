-- ItemGameObject.lua
-- Item (ITEM_TEXT_READY) and GameObject (GOSSIP_SHOW on a GameObj GUID) voice
-- support for QuestEcho:
--   fileName = "<id>_<Item|GameObject>_<md5>"
--   md5      = MD5(id .. CleanText(text))   (CleanTextV2 hash tried as fallback)
-- Files live in generated/sounds/items and generated/sounds/gameobjects and
-- are resolved through the normal sound-length table + PrepareSound pipeline.

local QE = QuestEcho
if not QE or not QE.DataModules or not QE.SoundQueue then return end
local DataModules = QE.DataModules
local SoundQueue = QE.SoundQueue
local Enums = QE.Enums

-- =============================================================================
-- Lua 5.0 notes (1.12 / Turtle WoW clients)
-- The client embeds Lua 5.0, which has no '%' operator and no '#' length
-- operator and no hexadecimal literals. Use math.mod(), string.len() and
-- decimal constants instead. Unlike 5.1, string.find(s, pat) only returns the
-- end position of the match when there are no captures, so `guid:match(...)`
-- became a string.find comparison here.
-- =============================================================================

-- =============================================================================
-- MD5 (pure Lua)
-- =============================================================================
local MD5 = {}
local K5 = {
    3614090360, 3905402710, 606105819, 3250441966,
    4118548399, 1200080426, 2821735955, 4249261313,
    1770035416, 2336552879, 4294925233, 2304563134,
    1804603682, 4254626195, 2792965006, 1236535329,
    4129170786, 3225465664, 643717713, 3921069994,
    3593408605, 38016083, 3634488961, 3889429448,
    568446438, 3275163606, 4107603335, 1163531501,
    2850285829, 4243563512, 1735328473, 2368359562,
    4294588738, 2272392833, 1839030562, 4259657740,
    2763975236, 1272893353, 4139469664, 3200236656,
    681279174, 3936430074, 3572445317, 76029189,
    3654602809, 3873151461, 530742520, 3299628645,
    4096336452, 1126891415, 2878612391, 4237533241,
    1700485571, 2399980690, 4293915773, 2240044497,
    1873313359, 4264355552, 2734768916, 1309151649,
    4149444226, 3174756917, 718787259, 3951481745
}
-- MD5 per-round left-rotation amounts (RFC 1321). Each round has its own table,
-- so the amount cannot be derived from i % 4 alone.
local SHIFTS = {
     7, 12, 17, 22,  7, 12, 17, 22,  7, 12, 17, 22,  7, 12, 17, 22,
     5,  9, 14, 20,  5,  9, 14, 20,  5,  9, 14, 20,  5,  9, 14, 20,
     4, 11, 16, 23,  4, 11, 16, 23,  4, 11, 16, 23,  4, 11, 16, 23,
     6, 10, 15, 21,  6, 10, 15, 21,  6, 10, 15, 21,  6, 10, 15, 21
}
local floor = math.floor
local mod = math.mod
local byte, char, sub, format = string.byte, string.char, string.sub, string.format
local strlen, strrep = string.len, string.rep
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift = bit.lshift, bit.rshift

function MD5.lrot(x, n)
    return lshift(x, n) + rshift(x, 32 - n)
end

function MD5.padding(len)
    local bits = len * 8
    local pad_len = 56 - mod(len + 1, 64)
    if pad_len < 0 then pad_len = pad_len + 64 end
    local padding = "\128" .. strrep("\0", pad_len) .. char(mod(bits, 256))
    bits = floor(bits / 256)
    for i = 1, 7 do
        padding = padding .. char(mod(bits, 256))
        bits = floor(bits / 256)
    end
    return padding
end

-- Split a 64-byte MD5 block into its sixteen little-endian 32-bit words.
-- The previous code passed the raw 64-byte block as `chunk` and indexed it with
-- chunk[G + 1]; because a Lua string byte array is not the same as the MD5 word
-- array, that only produced correct results for the i < 16 round (where
-- G == i == word index). All later rounds read the wrong bytes.
local function MD5Words(block)
    local words = {}
    for j = 0, 15 do
        local p = j * 4 + 1
        local b0 = byte(block, p)
        local b1 = byte(block, p + 1)
        local b2 = byte(block, p + 2)
        local b3 = byte(block, p + 3)
        if not b3 then break end
        words[j + 1] = mod(b0 + b1 * 256 + b2 * 65536 + b3 * 16777216, 4294967296)
    end
    return words
end

function MD5.processChunk(chunk, H0, H1, H2, H3)
    local F, G
    local a, b, c, d = H0, H1, H2, H3
    for i = 0, 63 do
        if i < 16 then
            F = bor(band(b, c), band(bnot(b), d))
            G = i
        elseif i < 32 then
            F = bor(band(d, b), band(bnot(d), c))
            G = mod(5 * i + 1, 16)
        elseif i < 48 then
            -- round 3 is a plain three-way xor
            F = bxor(b, c, d)
            G = mod(3 * i + 5, 16)
        else
            F = bxor(c, bor(b, bnot(d)))
            G = mod(7 * i, 16)
        end
        -- MD5 rotation amount: each of the four rounds has its OWN table, so
        -- this cannot be derived from i % 4. Round 1 is 7,12,17,22; round 2 is
        -- 5,9,14,20; round 3 is 4,11,16,23; round 4 is 6,10,15,21.
        local shift_amount = SHIFTS[i + 1]
        -- MD5 state rotation: (a, b, c, d) <- (d, b + T, b, c), all computed
        -- from the OLD values. The previous code used temp/d/c/a shuffling that
        -- ended with a = c and c = d, corrupting every digest it produced.
        local T = mod(a + F + K5[i + 1] + chunk[G + 1], 4294967296)
        local newB = mod(b + MD5.lrot(T, shift_amount), 4294967296)
        local newC = b
        local newD = c
        a, b, c, d = d, newB, newC, newD
    end
    return H0 + a, H1 + b, H2 + c, H3 + d
end

function MD5.generate(message)
    -- decimal for 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476 (no hex in 5.0)
    local H0, H1, H2, H3 = 1732584193, 4023233417, 2562383102, 271733878
    message = message .. MD5.padding(strlen(message))
    local total = strlen(message)
    local i = 1
    while i <= total do
        local block = sub(message, i, i + 63)
        H0, H1, H2, H3 = MD5.processChunk(MD5Words(block), H0, H1, H2, H3)
        i = i + 64
    end
    return MD5.hexWord(H0) .. MD5.hexWord(H1) .. MD5.hexWord(H2) .. MD5.hexWord(H3)
end

-- MD5 digests are the four state words serialised little-endian. format("%08x")
-- cannot be used directly: on Lua 5.0 (and 5.1) a negative state word makes %x
-- print "ffffffff..." because the value is cast to a 32-bit signed int, and
-- even with the word converted to unsigned the bytes would come out reversed.
-- So swap the bytes by hand and format each byte from the 0-255 range.
function MD5.hexWord(word)
    word = mod(word, 4294967296)
    local b0 = mod(word, 256);            word = floor(word / 256)
    local b1 = mod(word, 256);            word = floor(word / 256)
    local b2 = mod(word, 256);            word = floor(word / 256)
    local b3 = mod(word, 256)
    return format("%02x%02x%02x%02x", b0, b1, b2, b3)
end

-- =============================================================================
-- Text cleaning
-- =============================================================================
local htmlPatterns = {
    {"\r\n", " "},
    {"<HTML>", ""}, {"</HTML>", ""},
    {"<BODY>", ""}, {"</BODY>", ""},
    {"<BR/>", " "}, {"<p>", ""}, {"</p>", ""},
    {'<p align="center">', ""},
}

local cleanPats, cleanV2Pats
local function buildCleanPatterns()
    if cleanPats then return end
    local name = UnitName("player")
    if not name or name == "" or name == UNKNOWNOBJECT then
        cleanPats = {}; cleanV2Pats = {}; return
    end
    -- No select() on Lua 5.0: capture UnitClass/UnitRace into a table and take
    -- the first value (the localised name), which is what the patterns need.
    local classInfo = { UnitClass("player") }
    local raceInfo = { UnitRace("player") }
    local class = classInfo[1]
    local race = raceInfo[1]
    cleanPats = {
        {name, "Hero"}, {string.lower(name), "Hero"}, {string.upper(name), "Hero"},
        {class, "Hero"}, {string.lower(class), "Hero"}, {string.upper(class), "Hero"},
        {race, "Hero"}, {string.lower(race), "Hero"}, {string.upper(race), "Hero"},
    }
    cleanV2Pats = {
        {name, "{name|" .. name .. "}"}, {string.lower(name), "{name|" .. string.lower(name) .. "}"}, {string.upper(name), "{name|" .. string.upper(name) .. "}"},
        {class, "{class|" .. class .. "}"}, {string.lower(class), "{class|" .. string.lower(class) .. "}"}, {string.upper(class), "{class|" .. string.upper(class) .. "}"},
        {race, "{race|" .. race .. "}"}, {string.lower(race), "{race|" .. string.lower(race) .. "}"}, {string.upper(race), "{race|" .. string.upper(race) .. "}"},
    }
end

local function applyHtml(text)
    for _, p in ipairs(htmlPatterns) do
        text = string.gsub(text, p[1], p[2])
    end
    return text
end

local function cleanText(text)
    if not text or text == "" then return text or "" end
    buildCleanPatterns()
    for _, p in ipairs(cleanPats) do
        text = string.gsub(text, p[1], p[2])
    end
    text = string.gsub(text, "\n\n", " ")
    return applyHtml(text)
end

local function cleanTextV2(text)
    if not text or text == "" then return text or "" end
    buildCleanPatterns()
    for _, p in ipairs(cleanV2Pats) do
        text = string.gsub(text, p[1], p[2])
    end
    return applyHtml(text)
end

-- Both hashes, in lookup order (CleanText then CleanTextV2).
local function hashesFor(id, text)
    return {
        MD5.generate(tostring(id) .. cleanText(text)),
        MD5.generate(tostring(id) .. cleanTextV2(text)),
    }
end

-- =============================================================================
-- Client compatibility helpers
-- UnitGUID / strsplit / string.match do not exist on 1.12 (Lua 5.0 + no GUID
-- API), so every use is feature-detected here instead of being called blindly.
-- =============================================================================
local hasUnitGUID = (type(UnitGUID) == "function")
local strsplit = strsplit

local function SplitDash(text)
    if type(strsplit) == "function" then
        return strsplit("-", text)
    end
    local parts = {}
    local start = 1
    while true do
        local s, e = string.find(text, "-", start, true)
        if not s then
            table.insert(parts, string.sub(text, start))
            return QuestEcho112.spreadArray(parts)
        end
        table.insert(parts, string.sub(text, start, s - 1))
        start = e + 1
    end
end

-- A GameObject GUID looks like "GameObj-0-0-0-0-12345-0".
local function GUIDIsGameObject(guid)
    if type(guid) ~= "string" then return false end
    if string.find(guid, "^GameObj%-") then return true end
    return string.sub(guid, 1, 7) == "GameObj"
end

-- =============================================================================
-- ITEM_TEXT_READY  (readable items: books, letters, plaques, ...)
-- =============================================================================
local itemFrame = CreateFrame("Frame")
itemFrame:RegisterEvent("ITEM_TEXT_READY")
itemFrame:SetScript("OnEvent", function()
    local itemName = ItemTextGetItem()
    local itemText = ItemTextGetText()
    local itemId
    if C_Item and C_Item.GetItemInfoInstant then
        itemId = C_Item.GetItemInfoInstant(itemName)
    elseif type(GetItemInfo) == "function" then
        local _n,_l,_q,_iL,_rL,_mL,_t,_s,_e,_p,_c,_cl,_g,id = GetItemInfo(itemName)
        itemId = id
    end
    local soundType = Enums.SoundEvent.Item

    -- No item id but a GameObject is the source: switch to the GameObject voice.
    if not itemId and hasUnitGUID then
        local guid = UnitGUID("npc")
        if GUIDIsGameObject(guid) then
            local parts = {SplitDash(guid)}
            local goId = tonumber(parts[6])
            if goId then
                itemId = goId
                soundType = Enums.SoundEvent.GameObject
            end
        end
    end
    if type(itemId) ~= "number" or not itemText or itemText == "" then return end

    for _, h in ipairs(hashesFor(itemId, itemText)) do
        local typeTag = (soundType == Enums.SoundEvent.GameObject) and "GameObject" or "Item"
        local fileName = itemId .. "_" .. typeTag .. "_" .. h
        local soundData = {
            id = "itemgo-" .. fileName .. "-" .. tostring(GetTime()),
            event = soundType,
            title = itemName or "Item",
            name = itemName,
            text = itemText,
            fileName = fileName,
        }
        if DataModules:PrepareSound(soundData) then
            SoundQueue:AddSoundToQueue(soundData)
            return
        end
    end
    if QE.Addon and QE.Addon.db.profile.TestMode then
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc[QuestEcho]|r "
            .. "Missing: item " .. tostring(itemId) .. " | " .. tostring(itemName or "-"))
    end
end)

-- =============================================================================
-- GOSSIP_SHOW on a GameObject (signposts, plaques, ...)
-- =============================================================================
local goFrame = CreateFrame("Frame")
goFrame:RegisterEvent("GOSSIP_SHOW")
goFrame:SetScript("OnEvent", function()
    if not (QE.Addon and QE.Addon.db.profile.Gossip) then return end
    if not hasUnitGUID then return end
    local guid = UnitGUID("npc")
    if not GUIDIsGameObject(guid) then return end
    local parts = {SplitDash(guid)}
    local goId = tonumber(parts[6])
    local text
    if C_GossipInfo and type(C_GossipInfo.GetText) == "function" then
        local ok, t = pcall(C_GossipInfo.GetText)
        if ok and type(t) == "string" then text = t end
    elseif type(GetGossipText) == "function" then
        local ok, t = pcall(GetGossipText)
        if ok and type(t) == "string" then text = t end
    end
    if not goId or not text or text == "" then return end

    for _, h in ipairs(hashesFor(goId, text)) do
        local fileName = goId .. "_GameObject_" .. h
        local soundData = {
            id = "gameobject-" .. fileName .. "-" .. tostring(GetTime()),
            event = Enums.SoundEvent.GameObject,
            title = "GameObject",
            name = "GameObject",
            text = text,
            fileName = fileName,
        }
        if DataModules:PrepareSound(soundData) then
            SoundQueue:AddSoundToQueue(soundData)
            return
        end
    end
    if QE.Addon and QE.Addon.db.profile.TestMode then
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc[QuestEcho]|r "
            .. "Missing: gameobject " .. tostring(goId))
    end
end)

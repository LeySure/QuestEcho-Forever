-- QuestTitleMap.lua
-- GENERATED FILE - do not edit by hand.
-- Cross-language quest titles joined on the vanilla quest id. The two
-- QuestEchoData packs key their lookups by the title in the client language,
-- so a Chinese client could never find an English-only voice line. This bridge
-- translates the title before the voice lookup. Neither pack is modified.

QE_QuestTitleMap = QE_QuestTitleMap or {}
local M = QE_QuestTitleMap

M.zhCNtoEN = M.zhCNtoEN or {}
M.enUStozhCN = M.enUStozhCN or {}

-- Title in the other language, or nil when no pair is known.
function M:Translate(title)
    if type(title) ~= "string" or title == "" then return nil end
    return self.zhCNtoEN[title] or self.enUStozhCN[title]
end

-- Data lives in separate files so no code follows the big tables.
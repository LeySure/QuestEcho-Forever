-- GossipTitleMap.lua
-- GENERATED FILE - do not edit by hand.
-- Cross-language NPC gossip. The npc id and the voice-file hash are language
-- independent while the dialogue text is not, so they join the Chinese and
-- English tables exactly: a Chinese client can find a gossip line that only
-- exists in the English pack. Neither pack is modified.

QE_GossipMap = QE_GossipMap or {}
local M = QE_GossipMap

M.zhCNtoEN = M.zhCNtoEN or {}
M.enUStozhCN = M.enUStozhCN or {}
M.npcZhCNtoEN = M.npcZhCNtoEN or {}
M.npcENtozhCN = M.npcENtozhCN or {}

-- Spoken line in the other language, or nil when no pair is known.
function M:TranslateText(text)
    if type(text) ~= "string" or text == "" then return nil end
    return self.zhCNtoEN[text] or self.enUStozhCN[text]
end

-- NPC name in the other language, or nil when no pair is known.
function M:TranslateNPC(name)
    if type(name) ~= "string" or name == "" then return nil end
    return self.npcZhCNtoEN[name] or self.npcENtozhCN[name]
end

-- Data lives in separate files so no code follows the big tables.
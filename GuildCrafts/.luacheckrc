-- .luacheckrc — GuildCrafts addon
std = "lua51"
max_line_length = false

-- Exclude vendored libraries
exclude_files = {
    "Libs/**",
}

-- Suppress WoW-convention noise:
--   unused self    — WoW callbacks always receive self
--   self shadowing — SetScript handlers shadow the outer self
ignore = {
    "212/self",   -- unused argument 'self'
    "432/self",   -- shadowing upvalue argument 'self'
}

globals = {
    "GuildCrafts",
    "GuildCraftsCharDB",
    "GuildCraftsDB",
    -- Slash commands
    "SlashCmdList",
    "SLASH_GUILDCRAFTS1",
    "SLASH_GUILDCRAFTS2",
}

read_globals = {
    -- WoW API — Frames & UI
    "CreateFrame", "UIParent", "GameTooltip", "ItemRefTooltip",
    "GameFontNormal", "GameFontHighlight", "GameFontHighlightSmall",
    "GameFontNormalLarge", "GameFontNormalSmall", "GameFontDisableSmall",
    "ChatFontNormal", "UISpecialFrames",
    "UIDropDownMenu_Initialize", "UIDropDownMenu_AddButton",
    "UIDropDownMenu_SetSelectedID",
    "Minimap", "GetCursorPosition",

    -- WoW API — Addon messaging
    "C_ChatInfo", "C_Timer", "C_GuildInfo",

    -- WoW API — Trade skills
    "GetNumTradeSkills", "GetTradeSkillInfo", "GetTradeSkillItemLink",
    "GetTradeSkillRecipeLink", "GetTradeSkillLine", "ExpandTradeSkillSubClass",
    "GetTradeSkillNumReagents", "GetTradeSkillReagentInfo", "GetTradeSkillReagentItemLink",

    -- WoW API — Craft (Enchanting in Classic TBC)
    "GetNumCrafts", "GetCraftInfo", "GetCraftItemLink",
    "GetCraftRecipeLink", "ExpandCraftSkillLine",
    "GetCraftNumReagents", "GetCraftReagentInfo", "GetCraftReagentItemLink",

    -- WoW API — Cooldowns
    "GetTradeSkillCooldown", "GetCraftCooldown",

    -- WoW API — Skills
    "GetNumSkillLines", "GetSkillLineInfo",

    -- WoW API — Guild
    "GetGuildInfo", "GetGuildRosterInfo", "GetNumGuildMembers",
    "GuildRoster", "IsInGuild",

    -- WoW API — Combat
    "InCombatLockdown", "UnitAffectingCombat",

    -- WoW API — Chat
    "SendChatMessage",

    -- WoW API — Sound
    "PlaySound", "SOUNDKIT",

    -- WoW API — Misc
    "GetAddOnMemoryUsage", "UpdateAddOnMemoryUsage",
    "GetBuildInfo", "GetItemInfo", "IsSpellKnown",
    "UnitName", "GetRealmName", "ReloadUI",
    "time",

    -- Ace3 / Libraries
    "LibStub",
}

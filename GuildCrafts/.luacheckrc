-- .luacheckrc — GuildCrafts addon
std = "lua51"
max_line_length = false

globals = {
    "GuildCrafts",
    "GuildCraftsDB",
}

read_globals = {
    -- WoW API — Frames & UI
    "CreateFrame", "UIParent", "GameTooltip", "ItemRefTooltip",
    "GameFontNormal",
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
    "GetGuildRosterInfo", "GetNumGuildMembers", "GuildRoster", "IsInGuild",

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

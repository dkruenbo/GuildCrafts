----------------------------------------------------------------------
-- GuildCrafts Minimap Button
-- Uses LibDBIcon-1.0 for standard minimap icon behaviour,
-- compatible with Leatrix Plus, SexyMap, and other minimap managers.
----------------------------------------------------------------------

local GuildCrafts = _G.GuildCrafts
local MinimapButton = GuildCrafts:NewModule("MinimapButton", "AceEvent-3.0")
GuildCrafts.MinimapButton = MinimapButton

local icon = LibStub("LibDBIcon-1.0")

local ldb = LibStub("LibDataBroker-1.1"):NewDataObject("GuildCrafts", {
    type = "launcher",
    icon = "Interface\\Icons\\INV_Misc_Book_11",
    OnClick = function(_, button)
        if button == "LeftButton" then
            GuildCrafts.UI:Toggle()
        end
    end,
    OnTooltipShow = function(tooltip)
        tooltip:AddLine("GuildCrafts")
        tooltip:AddLine("|cffffffffLeft-click|r to toggle window", 0.8, 0.8, 0.8)
    end,
})

----------------------------------------------------------------------
-- Module Lifecycle
----------------------------------------------------------------------

function MinimapButton:OnEnable()
    -- GuildCrafts.db is set up by Data:OnInitialize before modules are enabled.
    icon:Register("GuildCrafts", ldb, GuildCrafts.db.global.minimap)
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

--- Toggle minimap button visibility.
--- Pass silent=true to suppress the chat print (e.g. when called from the UI).
function MinimapButton:Toggle(silent)
    local db = GuildCrafts.db.global.minimap
    if db.hide then
        icon:Show("GuildCrafts")
        db.hide = false
        if not silent then
            GuildCrafts:Print("Minimap button shown.")
        end
    else
        icon:Hide("GuildCrafts")
        db.hide = true
        if not silent then
            GuildCrafts:Print("Minimap button hidden. Type /gc minimap to show it again.")
        end
    end
end

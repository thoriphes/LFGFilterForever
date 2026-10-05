-- LFG Filter Forever: filters Blizzard's Looking For Group browse list (Blizzard_GroupFinder_VanillaStyle,
-- load-on-demand). Players by level, role and class; groups by tank / healer present and an open DPS spot.
-- Your own listing is never hidden.
--
-- How: LFGBrowseMixin:UpdateResultList() fetches the results, sorts them with the global
-- LFGBrowseUtil_SortSearchResults(results) and then builds the list from that table. A post-hook
-- on the sort drops the filtered entries from the table in place. With no filter active the hook
-- returns without touching anything.
--
-- The gear: our own button covers Blizzard's (which is faded to alpha 0) and opens our own popover,
-- styled like Blizzard's gear menu but with real padding (Blizzard's menu insets are shared by every
-- dropdown in the game). Blizzard's only gear option, "Show All Level Ranges", is a CVar whose
-- CVAR_UPDATE handler rebuilds the category dropdown; flipped from addon code that rebuild runs
-- tainted and the category dropdown's C_LFGList.Search() gets blocked. So that row is a secure
-- macro button (/console ...), and the popover cannot open in combat. Esc closes the popover
-- through its own OnKeyDown, not UISpecialFrames (that would put addon data on the Esc path).
local ADDON, ns = ...
local L = ns.L

local BLIZZARD_LFG = "Blizzard_GroupFinder_VanillaStyle"
local SHOW_ALL_CVAR = "disableSuggestedLevelActivityFilter"

local DEFAULTS = {
    roles = { tank = true, healer = true, dps = true },
    hiddenClasses = {},     -- [classFilename] = true
    levelMin = 0,           -- 0 = no bound
    levelMax = 0,
    groups = { tank = "any", healer = "any", dpsSpot = false },   -- tank/healer: "any" | "yes" | "no"
}

-- Popover layout
local PAD_X, PAD_Y = 12, 10
local ROW_W, ROW_H = 354, 22
local ROW_GAP, BLOCK_GAP = 2, 10

local db
local hiddenPlayers, hiddenGroups = 0, 0
local hiddenLabel, gear, clearButton, panel, showAllButton

local function applyDefaults(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            applyDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

------------------------------------------------------------------------------------------------
-- Filtering
------------------------------------------------------------------------------------------------
local function RolesActive()
    local r = db.roles
    return not (r.tank and r.healer and r.dps)
end

local function PlayersActive()
    return RolesActive() or next(db.hiddenClasses) ~= nil or db.levelMin > 0 or db.levelMax > 0
end

local function GroupsActive()
    local g = db.groups
    return g.tank ~= "any" or g.healer ~= "any" or g.dpsSpot
end

local function FiltersActive()
    return PlayersActive() or GroupsActive()
end

local function PlayerPasses(resultID, checkRoles)
    local member = C_LFGList.GetSearchResultPlayerInfo(resultID, 1)
    if not member then
        return true
    end
    if checkRoles then
        local r, want = member.lfgRoles, db.roles
        if not (r and ((r.tank and want.tank) or (r.healer and want.healer) or (r.dps and want.dps))) then
            return false
        end
    end
    if member.classFilename and db.hiddenClasses[member.classFilename] then
        return false
    end
    local level = member.level
    if level and ((db.levelMin > 0 and level < db.levelMin) or (db.levelMax > 0 and level > db.levelMax)) then
        return false
    end
    return true
end

-- want = "yes" / "no" against a member count.
local function MatchesPresence(want, count)
    return want == "any" or ((count or 0) > 0) == (want == "yes")
end

local function GroupPasses(resultID)
    local counts = C_LFGList.GetSearchResultMemberCounts(resultID)
    if not counts then
        return true
    end
    local g = db.groups
    if not MatchesPresence(g.tank, counts.TANK) or not MatchesPresence(g.healer, counts.HEALER) then
        return false
    end
    return not g.dpsSpot or (counts.DAMAGER_REMAINING or 0) > 0
end

-- Post-hook of LFGBrowseUtil_SortSearchResults: compacts the sorted table in place.
local function FilterResults(results)
    hiddenPlayers, hiddenGroups = 0, 0
    local players, groups = PlayersActive(), GroupsActive()
    if not (players or groups) then
        return
    end
    local checkRoles = RolesActive()
    local count, kept = #results, 0
    for i = 1, count do
        local resultID = results[i]
        local info = C_LFGList.GetSearchResultInfo(resultID)
        local keep = true
        if info and not info.hasSelf then
            if info.numMembers == 1 then
                keep = not players or PlayerPasses(resultID, checkRoles)
                if not keep then hiddenPlayers = hiddenPlayers + 1 end
            else
                keep = not groups or GroupPasses(resultID)
                if not keep then hiddenGroups = hiddenGroups + 1 end
            end
        end
        if keep then
            kept = kept + 1
            if kept ~= i then
                results[kept] = resultID
            end
        end
    end
    for i = count, kept + 1, -1 do
        results[i] = nil
    end
end

local function HiddenText()
    local parts = {}
    if hiddenPlayers > 0 then
        table.insert(parts, hiddenPlayers == 1 and L["1 player"] or L["%d players"]:format(hiddenPlayers))
    end
    if hiddenGroups > 0 then
        table.insert(parts, hiddenGroups == 1 and L["1 group"] or L["%d groups"]:format(hiddenGroups))
    end
    return L["%s hidden by filters"]:format(table.concat(parts, ", "))
end

-- Post-hook of LFGBrowseFrame:UpdateResults: hidden count + empty-list text.
local function OnUpdateResults(frame)
    local idle = not frame.searching and not frame.searchFailed
    if idle and hiddenPlayers + hiddenGroups > 0 then
        hiddenLabel:SetText(HiddenText())
        hiddenLabel:Show()
        if #frame.results == 0 then
            frame.NoResultsFound:SetText(L["Everything is hidden by your filters."])
            frame.NoResultsFound:Show()
        end
    else
        hiddenLabel:Hide()
    end
end

local function Refresh()
    clearButton:SetShown(FiltersActive())
    if LFGBrowseFrame:IsVisible() then
        LFGBrowseFrame:UpdateResultList()
    end
end

------------------------------------------------------------------------------------------------
-- Popover
------------------------------------------------------------------------------------------------
-- A cell = { text, state(), cycle(), tooltipTitle?, tooltipText? }; state() = true/false or "yes"/"no"/"any".
local function Cell(text, state, cycle, tipTitle, tipText)
    return { text, state, cycle, tipTitle, tipText }
end

-- The role icons Blizzard's own LFG list draws next to solo players.
local ICON = {
    tank   = CreateAtlasMarkup("groupfinder-icon-role-micro-tank", 16, 16) .. " ",
    healer = CreateAtlasMarkup("groupfinder-icon-role-micro-heal", 16, 16) .. " ",
    dps    = CreateAtlasMarkup("groupfinder-icon-role-micro-dps", 16, 16) .. " ",
}

local ROLE_CELLS = {
    Cell(ICON.tank .. TANK,      function() return db.roles.tank end,   function() db.roles.tank = not db.roles.tank end),
    Cell(ICON.healer .. HEALER,  function() return db.roles.healer end, function() db.roles.healer = not db.roles.healer end),
    Cell(ICON.dps .. DAMAGER,    function() return db.roles.dps end,    function() db.roles.dps = not db.roles.dps end),
}

local CLASS_CELLS = {}
for _, classFile in ipairs(CLASS_SORT_ORDER) do
    local name = LOCALIZED_CLASS_NAMES_MALE[classFile] or classFile
    local color = RAID_CLASS_COLORS[classFile]
    table.insert(CLASS_CELLS, Cell(color and color:WrapTextInColorCode(name) or name,
        function() return not db.hiddenClasses[classFile] end,
        function() db.hiddenClasses[classFile] = not db.hiddenClasses[classFile] or nil end))
end

local NEXT_PRESENCE = { any = "yes", yes = "no", no = "any" }
local function PresenceCell(icon, text, key, tipYes, tipNo)
    return Cell(icon .. text,
        function() return db.groups[key] end,
        function() db.groups[key] = NEXT_PRESENCE[db.groups[key]] or "any" end,
        text, L["Click to cycle:"] .. "\n|A:common-dropdown-icon-checkmark-yellow:14:14|a " .. tipYes
            .. "\n|TInterface\\RaidFrame\\ReadyCheck-NotReady:14:14|t " .. tipNo .. "\n" .. L["Empty: any group"])
end

local GROUP_CELLS = {
    PresenceCell(ICON.tank, L["Has Tank"], "tank", L["only groups with a tank"], L["only groups without a tank"]),
    PresenceCell(ICON.healer, L["Has Healer"], "healer", L["only groups with a healer"], L["only groups without a healer"]),
    Cell(ICON.dps .. L["Has DPS Spot"],
        function() return db.groups.dpsSpot end,
        function() db.groups.dpsSpot = not db.groups.dpsSpot end,
        L["Has DPS Spot"], L["Only groups with an open damage slot."]),
}

local function ShowCellState(button, state)
    button.Check:SetShown(state == true or state == "yes")
    button.Cross:SetShown(state == "no")
end

local function OnCellClick(button)
    local cell = button.cell
    cell[3]()
    local state = cell[2]()
    ShowCellState(button, state)
    PlaySound((state == true or state == "yes") and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON
        or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
    Refresh()
end

local function OnCellEnter(button)
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    GameTooltip:SetText(button.cell[4], HIGHLIGHT_FONT_COLOR:GetRGB())
    GameTooltip:AddLine(button.cell[5], NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b, true)
    GameTooltip:Show()
end

local function SyncShowAll()
    local on = GetCVarBool(SHOW_ALL_CVAR)
    showAllButton.Check:SetShown(on)
    if not InCombatLockdown() then
        showAllButton:SetAttribute("macrotext", ("/console %s %d"):format(SHOW_ALL_CVAR, on and 0 or 1))
    end
end

local function SyncPanel()
    SyncShowAll()
    for _, row in ipairs(panel.rows) do
        for i = 1, 3 do
            local button = row["Cell" .. i]
            if button.cell then
                ShowCellState(button, button.cell[2]())
            end
        end
    end
    local range = panel.levelRow.Range
    range:SetLevelRangeChangedCallback(nil)
    range:Reset()
    if db.levelMin > 0 then range:SetMinLevel(db.levelMin) end
    if db.levelMax > 0 then range:SetMaxLevel(db.levelMax) end
    range:SetLevelRangeChangedCallback(function(minLevel, maxLevel)
        db.levelMin, db.levelMax = minLevel, maxLevel
        Refresh()
    end)
end

local function BuildPanel()
    panel = CreateFrame("Frame", "LFGFilterForeverPanel", UIParent)
    panel:SetFrameStrata("DIALOG")
    panel:SetToplevel(true)
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    panel:Hide()
    panel.rows = {}

    -- Blizzard's MenuStyle2Mixin look (the gear menu's own background).
    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAtlas("common-dropdown-c-bg")
    bg:SetPoint("TOPLEFT", -17, 12)
    bg:SetPoint("BOTTOMRIGHT", 17, -22)

    local y = -PAD_Y
    local function place(region, height, gap)
        region:SetPoint("TOPLEFT", PAD_X, y)
        y = y - height - (gap or ROW_GAP)
    end
    local function title(text)
        local fs = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        fs:SetText(text)
        place(fs, 16, 6)
    end
    local function rows(cells, gapAfter)
        for first = 1, #cells, 3 do
            local row = CreateFrame("Frame", nil, panel, "LFGFilterForeverCheckRowTemplate")
            for i = 1, 3 do
                local button, cell = row["Cell" .. i], cells[first + i - 1]
                button.cell = cell
                button:SetShown(cell ~= nil)
                if cell then
                    button.Text:SetText(cell[1])
                    button:SetScript("OnClick", OnCellClick)
                    if cell[4] then
                        button:SetScript("OnEnter", OnCellEnter)
                        button:SetScript("OnLeave", GameTooltip_Hide)
                    end
                end
            end
            table.insert(panel.rows, row)
            place(row, ROW_H, first + 3 > #cells and gapAfter or nil)
        end
    end

    -- Blizzard's own option, run as a secure macro (see the header).
    showAllButton = CreateFrame("Button", nil, panel, "SecureActionButtonTemplate, LFGFilterForeverCheckTemplate")
    showAllButton:SetWidth(ROW_W)
    showAllButton.Text:SetText(LFG_LIST_IGNORE_SUGGESTED_LEVEL)
    showAllButton:SetAttribute("type", "macro")
    showAllButton:RegisterForClicks("AnyUp", "AnyDown")
    place(showAllButton, ROW_H, BLOCK_GAP)

    title(L["Players"])
    panel.levelRow = CreateFrame("Frame", nil, panel, "LFGFilterForeverLevelRowTemplate")
    place(panel.levelRow, 26, 4)
    rows(ROLE_CELLS, 6)
    rows(CLASS_CELLS, BLOCK_GAP)

    title(L["Groups"])
    rows(GROUP_CELLS, 0)

    panel:SetSize(ROW_W + 2 * PAD_X, -y + PAD_Y)

    panel:SetScript("OnShow", function(self)
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
        SyncPanel()
    end)
    panel:SetScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
        self:ClearAllPoints()   -- no anchor to Blizzard's frame while the secure row is not shown
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
    end)
    panel:SetScript("OnEvent", function(self)
        if not self:IsMouseOver() and not gear:IsMouseOver() then
            self:Hide()
        end
    end)
    -- Esc closes the popover (and only the popover); every other key goes on to the game.
    -- Never shown in combat, where SetPropagateKeyboardInput is protected.
    panel:EnableKeyboard(true)
    panel:SetScript("OnKeyDown", function(self, key)
        local isEscape = key == "ESCAPE"
        self:SetPropagateKeyboardInput(not isEscape)
        if isEscape then
            self:Hide()
        end
    end)
end

local function TogglePanel()
    if panel and panel:IsShown() then
        panel:Hide()
        return
    end
    if InCombatLockdown() then
        UIErrorsFrame:AddMessage(ERR_NOT_IN_COMBAT, RED_FONT_COLOR:GetRGB())
        return
    end
    if not panel then
        BuildPanel()
    end
    panel:SetPoint("TOPLEFT", gear, "BOTTOMLEFT", -4, -6)
    PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    panel:Show()
end

local function ResetFilters()
    db.roles.tank, db.roles.healer, db.roles.dps = true, true, true
    wipe(db.hiddenClasses)
    db.levelMin, db.levelMax = 0, 0
    db.groups.tank, db.groups.healer, db.groups.dpsSpot = "any", "any", false
    if panel and panel:IsShown() then
        SyncPanel()
    end
    Refresh()
end

------------------------------------------------------------------------------------------------
-- Setup
------------------------------------------------------------------------------------------------
local function OnBlizzardLFGLoaded()
    hiddenLabel = LFGBrowseFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hiddenLabel:SetPoint("BOTTOM", LFGBrowseFrame, "BOTTOM", 0, 26)
    hiddenLabel:Hide()

    -- Our gear on top of Blizzard's (same art, LFGOptionsButton), which is faded out.
    local blizzardGear = LFGBrowseFrame.OptionsButton
    blizzardGear:SetAlpha(0)
    gear = CreateFrame("Button", nil, LFGBrowseFrame)
    gear:SetAllPoints(blizzardGear)
    gear:SetFrameLevel(blizzardGear:GetFrameLevel() + 2)
    gear.Icon = gear:CreateTexture(nil, "ARTWORK")
    gear.Icon:SetAtlas("OptionsIcon-Brown")
    gear.Icon:SetAllPoints()
    gear.Icon:SetAlpha(0.8)
    gear:SetScript("OnEnter", function(self) self.Icon:SetAlpha(1) end)
    gear:SetScript("OnLeave", function(self) self.Icon:SetAlpha(0.8) end)
    gear:SetScript("OnMouseDown", function(self) self.Icon:AdjustPointsOffset(1, -1) end)
    gear:SetScript("OnMouseUp", function(self) self.Icon:AdjustPointsOffset(-1, 1) end)
    gear:SetScript("OnClick", TogglePanel)

    -- The Auction House's red X on its filter button, here on the gear: shown while a filter is on.
    clearButton = CreateFrame("Button", nil, gear)
    clearButton:SetSize(23, 23)
    clearButton:SetPoint("CENTER", gear, "TOPRIGHT", -3, 0)
    clearButton:SetFrameLevel(gear:GetFrameLevel() + 2)
    clearButton:SetNormalAtlas("auctionhouse-ui-filter-redx")
    clearButton:SetHighlightAtlas("auctionhouse-ui-filter-redx", "ADD")
    clearButton:GetHighlightTexture():SetAlpha(0.4)
    clearButton:SetScript("OnClick", function()
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        ResetFilters()
    end)
    clearButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L["Reset filters"], HIGHLIGHT_FONT_COLOR:GetRGB())
        GameTooltip:Show()
    end)
    clearButton:SetScript("OnLeave", GameTooltip_Hide)
    clearButton:SetShown(FiltersActive())

    LFGBrowseFrame:HookScript("OnHide", function()
        if panel and panel:IsShown() and not InCombatLockdown() then
            panel:Hide()
        end
    end)

    hooksecurefunc("LFGBrowseUtil_SortSearchResults", FilterResults)
    hooksecurefunc(LFGBrowseFrame, "UpdateResults", OnUpdateResults)
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("CVAR_UPDATE")
events:SetScript("OnEvent", function(self, event, name)
    if event == "PLAYER_REGEN_DISABLED" then
        -- Lockdown starts after this event: close while a secure row may still be hidden.
        if panel and panel:IsShown() then
            panel:Hide()
        end
        return
    elseif event == "CVAR_UPDATE" then
        if name == SHOW_ALL_CVAR and panel and panel:IsShown() then
            SyncShowAll()
        end
        return
    end
    if name ~= ADDON then
        return
    end
    self:UnregisterEvent("ADDON_LOADED")
    LFGFilterForeverDB = LFGFilterForeverDB or {}
    db = LFGFilterForeverDB
    -- 1.0.0 kept a level mode (any / near / range) and a 1..cap range; only a picked range carries over.
    if db.levelMode ~= nil then
        if db.levelMode ~= "range" then
            db.levelMin, db.levelMax = 0, 0
        end
        db.levelMode, db.levelNear = nil, nil
        if (db.levelMin or 0) <= 1 then db.levelMin = 0 end
        if (db.levelMax or 0) >= GetMaxPlayerLevel() then db.levelMax = 0 end
    end
    applyDefaults(db, DEFAULTS)
    EventUtil.ContinueOnAddOnLoaded(BLIZZARD_LFG, OnBlizzardLFGLoaded)
end)

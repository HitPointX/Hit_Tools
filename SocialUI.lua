--[[
═══════════════════════════════════════════════════════════════════════════════
  HIT-TOOLS SOCIAL HEATMAP UI
  Full-featured UI for community analytics
═══════════════════════════════════════════════════════════════════════════════
]]--

local _, HitTools = ...

HitTools.SocialUI = HitTools.SocialUI or {}
local SocialUI = HitTools.SocialUI

-- Constants
local TAB_PLAYERS = 1
local TAB_PAIRINGS = 2
local TAB_RUNS = 3
local TAB_SETTINGS = 4

-- UI Version - increment this when frame structure changes to force rebuild
local UI_VERSION = 5

-- ISSUE C FIX: Throttled UI refresh
local lastUIRefreshTime = 0
local UI_REFRESH_THROTTLE = 0.25  -- seconds

local CLASS_COLORS = {
  WARRIOR = {0.78, 0.61, 0.43},
  PALADIN = {0.96, 0.55, 0.73},
  HUNTER = {0.67, 0.83, 0.45},
  ROGUE = {1.00, 0.96, 0.41},
  PRIEST = {1.00, 1.00, 1.00},
  SHAMAN = {0.00, 0.44, 0.87},
  MAGE = {0.41, 0.80, 0.94},
  WARLOCK = {0.58, 0.51, 0.79},
  DRUID = {1.00, 0.49, 0.04},
  DEATHKNIGHT = {0.77, 0.12, 0.23},
}

-- Debug helper
local function DebugPrint(...)
  if HitTools.DB and HitTools.DB.social and HitTools.DB.social.debug then
    print("[SocialUI]", ...)
  end
end

local function getPlayerStore(db)
  if not db then return nil end
  return db.playersById or db.players
end

local function resolvePlayerKey(db, playerKey)
  if not db or not playerKey then return nil end

  local players = getPlayerStore(db)
  if players and players[playerKey] then
    return playerKey
  end

  if HitTools.SocialHeatmap and HitTools.SocialHeatmap.ResolveId then
    local name, realm = playerKey:match("^([^%-]+)%-(.+)$")
    if name then
      local resolved = HitTools.SocialHeatmap.ResolveId(nil, name, realm)
      if resolved and db.playersById and db.playersById[resolved] then
        return resolved
      end
    end
  end

  if db.nameIndex and db.playersById then
    local mapped = db.nameIndex[playerKey]
    if mapped and db.playersById[mapped] then
      return mapped
    end
  end

  return nil
end

local function getPlayerRecord(db, playerKey)
  local resolvedKey = resolvePlayerKey(db, playerKey)
  if not resolvedKey then return nil, nil end
  local players = getPlayerStore(db)
  if not players then return nil, nil end
  return players[resolvedKey], resolvedKey
end

-- StaticPopup Dialogs
StaticPopupDialogs["HITSOCIAL_ADD_TAG"] = {
  text = "Add tag for %s:",
  button1 = "Add",
  button2 = "Cancel",
  hasEditBox = true,
  maxLetters = 20,
  OnAccept = function(self)
    local tag = self.editBox:GetText()
    if tag and tag ~= "" and self.playerKey then
      local db = HitTools.DB and HitTools.DB.social
      local player = db and select(1, getPlayerRecord(db, self.playerKey))
      if player then
        player.tags = player.tags or {}
        table.insert(player.tags, tag)
        HitTools:Print("Added tag '" .. tag .. "' to " .. (player.name or "player"))
      end
    end
  end,
  OnShow = function(self)
    self.editBox:SetFocus()
  end,
  OnHide = function(self)
    self.editBox:SetText("")
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
}

StaticPopupDialogs["HITSOCIAL_EDIT_NOTES"] = {
  text = "Notes for %s:",
  button1 = "Save",
  button2 = "Cancel",
  hasEditBox = true,
  maxLetters = 256,
  OnAccept = function(self)
    local notes = self.editBox:GetText()
    if self.playerKey then
      local db = HitTools.DB and HitTools.DB.social
      local player = db and select(1, getPlayerRecord(db, self.playerKey))
      if player then
        player.notes = notes
        HitTools:Print("Saved notes for " .. (player.name or "player"))
      end
    end
  end,
  OnShow = function(self)
    if self.playerKey then
      local db = HitTools.DB and HitTools.DB.social
      local player = db and select(1, getPlayerRecord(db, self.playerKey))
      if player then
        self.editBox:SetText(player.notes or "")
      end
    end
    self.editBox:SetFocus()
  end,
  OnHide = function(self)
    self.editBox:SetText("")
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
}

StaticPopupDialogs["HITSOCIAL_RESET_PLAYER"] = {
  text = "Reset all data for %s?",
  button1 = "Reset",
  button2 = "Cancel",
  OnAccept = function(self)
    if self.playerKey then
      local db = HitTools.DB and HitTools.DB.social
      local player, resolvedKey = db and getPlayerRecord(db, self.playerKey)
      if player then
        local playerName = player.name or "player"
        if db.playersById and resolvedKey then
          db.playersById[resolvedKey] = nil
        end
        if db.players and db.players[self.playerKey] then
          db.players[self.playerKey] = nil
        end
        HitTools:Print("Reset data for " .. playerName)
        if HitTools.SocialUI then
          HitTools.SocialUI:InvalidateFilterCache()
          HitTools.SocialUI:RefreshPlayersTab()
        end
      end
    end
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
}

-- Helper: Get class color
local function getClassColor(class)
  local color = CLASS_COLORS[class] or {0.5, 0.5, 0.5}
  return color[1], color[2], color[3]
end

-- Helper: Format time ago
local function formatTimeAgo(timestamp)
  if not timestamp then return "Never" end
  local now = GetTime()
  local diff = now - timestamp

  if diff < 60 then return "Just now" end
  if diff < 3600 then return string.format("%dm ago", math.floor(diff / 60)) end
  if diff < 86400 then return string.format("%dh ago", math.floor(diff / 3600)) end
  if diff < 604800 then return string.format("%dd ago", math.floor(diff / 86400)) end
  return string.format("%dw ago", math.floor(diff / 604800))
end

-- Helper: Create custom dropdown (TBC-compatible)
local function CreateDropdown(parent, width, options, onSelect)
  local dropdown = CreateFrame("Button", nil, parent)
  dropdown:SetSize(width, 20)

  -- Background
  dropdown.bg = dropdown:CreateTexture(nil, "BACKGROUND")
  dropdown.bg:SetAllPoints()
  dropdown.bg:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
  dropdown.bg:SetVertexColor(0, 0, 0, 0.5)

  -- Border
  dropdown.border = dropdown:CreateTexture(nil, "BORDER")
  dropdown.border:SetPoint("TOPLEFT", -1, 1)
  dropdown.border:SetPoint("BOTTOMRIGHT", 1, -1)
  dropdown.border:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
  dropdown.border:SetVertexColor(0.3, 0.3, 0.3, 0.8)

  -- Text
  dropdown.text = dropdown:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
  dropdown.text:SetPoint("LEFT", 4, 0)
  dropdown.text:SetPoint("RIGHT", -16, 0)
  dropdown.text:SetJustifyH("LEFT")
  dropdown.text:SetText(options[1].text)

  -- Arrow
  dropdown.arrow = dropdown:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
  dropdown.arrow:SetPoint("RIGHT", -4, 0)
  dropdown.arrow:SetText("▼")
  dropdown.arrow:SetTextColor(0.7, 0.7, 0.7)

  -- Store options and current value
  dropdown.options = options
  dropdown.currentValue = options[1].value
  dropdown.onSelect = onSelect

  -- Create menu frame
  dropdown.menu = CreateFrame("Frame", nil, dropdown)
  dropdown.menu:SetPoint("TOPLEFT", dropdown, "BOTTOMLEFT", 0, -2)
  dropdown.menu:SetSize(width, #options * 20)
  dropdown.menu:SetFrameStrata("FULLSCREEN_DIALOG")
  dropdown.menu:Hide()

  if dropdown.menu.SetBackdrop then
    dropdown.menu:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true,
      tileSize = 16,
      edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
  end

  -- Create menu items
  dropdown.menuItems = {}
  for i, option in ipairs(options) do
    local item = CreateFrame("Button", nil, dropdown.menu)
    item:SetSize(width - 8, 18)
    item:SetPoint("TOPLEFT", 4, -(i - 1) * 20 - 4)

    item.bg = item:CreateTexture(nil, "BACKGROUND")
    item.bg:SetAllPoints()
    item.bg:SetTexture("Interface\\Buttons\\WHITE8x8")
    item.bg:SetVertexColor(0, 0, 0, 0)

    item.text = item:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
    item.text:SetPoint("LEFT", 4, 0)
    item.text:SetText(option.text)
    item.text:SetTextColor(1, 1, 1)

    item:SetScript("OnEnter", function(self)
      self.bg:SetVertexColor(0.3, 0.5, 0.7, 0.5)
    end)

    item:SetScript("OnLeave", function(self)
      self.bg:SetVertexColor(0, 0, 0, 0)
    end)

    item:SetScript("OnClick", function(self)
      dropdown.currentValue = option.value
      dropdown.text:SetText(option.text)
      dropdown.menu:Hide()
      if dropdown.onSelect then
        dropdown.onSelect(option.value)
      end
    end)

    dropdown.menuItems[i] = item
  end

  -- Dropdown button click
  dropdown:SetScript("OnClick", function(self)
    if self.menu:IsShown() then
      self.menu:Hide()
    else
      self.menu:Show()
    end
  end)

  -- Hide menu when clicking outside
  dropdown.menu:SetScript("OnHide", function(self)
    dropdown.arrow:SetText("▼")
  end)

  dropdown.menu:SetScript("OnShow", function(self)
    dropdown.arrow:SetText("▲")
  end)

  return dropdown
end

--[[═══════════════════════════════════════════════════════════════════════════
  INITIALIZATION
═══════════════════════════════════════════════════════════════════════════════]]

-- Destroy existing UI frames to force clean rebuild
function SocialUI:Destroy()
  if self.mainFrame then
    self.mainFrame:Hide()
    self.mainFrame:SetParent(nil)
    self.mainFrame = nil
  end

  -- Clear all frame references
  self.playersContent = nil
  self.pairingsContent = nil
  self.runsContent = nil
  self.settingsContent = nil
  self.playerDetailPanel = nil
  self.tabs = nil

  DebugPrint("Destroyed old UI frames")
end

function SocialUI:Initialize()
  DebugPrint("Starting initialization...")

  -- Check if UI needs rebuild due to version mismatch
  local db = HitTools.DB and HitTools.DB.socialUI
  local storedVersion = (db and db.uiVersion) or 0
  DebugPrint(string.format("Version check: stored=%d, current=%d", storedVersion, UI_VERSION))

  if self.mainFrame and storedVersion ~= UI_VERSION then
    DebugPrint(string.format("UI version mismatch (stored=%d, current=%d), rebuilding...", storedVersion, UI_VERSION))
    self:Destroy()
  end

  if self.mainFrame then
    DebugPrint("mainFrame already exists, skipping initialization")
    return
  end

  DebugPrint("Creating UI frames...")

  -- Store current UI version
  if db then
    db.uiVersion = UI_VERSION
  end

  -- Restore last tab and filters from SavedVars
  local db = HitTools.DB and HitTools.DB.socialUI
  self.currentTab = (db and db.lastTab) or TAB_PLAYERS

  -- Restore or use default filters
  if db and db.lastFilters and db.lastFilters.players then
    self.filters = {
      search = db.lastFilters.players.search or "",
      timeWindow = db.lastFilters.players.timeWindow or 0,
      roleFilter = db.lastFilters.players.roleFilter or "ANY",
      instanceFilter = db.lastFilters.players.instanceFilter or "ANY",
      frequentOnly = db.lastFilters.players.frequentOnly or false,
      inPartyOnly = db.lastFilters.players.inPartyOnly or false,
    }
    self.pairingsFilters = db.lastFilters.pairings or {search = "", timeWindow = 0}
    self.runsFilters = db.lastFilters.runs or {timeWindow = 0, instance = "ANY", outcome = "ANY"}
  else
    self.filters = {
      search = "",
      timeWindow = 0,
      roleFilter = "ANY",
      instanceFilter = "ANY",
      frequentOnly = false,
      inPartyOnly = false,
    }
    self.pairingsFilters = {search = "", timeWindow = 0}
    self.runsFilters = {timeWindow = 0, instance = "ANY", outcome = "ANY"}
  end

  self.sortColumn = "runs"
  self.sortAsc = false

  -- Cache
  self.filteredPlayers = nil
  self.lastFilterHash = nil

  self:CreateMainFrame()
  self:CreateTabs()
  self:CreatePlayersTab()
  self:CreatePairingsTab()
  self:CreateRunsTab()
  self:CreateSettingsTab()
  self:CreatePlayerDetailPanel()
end

--[[═══════════════════════════════════════════════════════════════════════════
  MAIN FRAME
═══════════════════════════════════════════════════════════════════════════════]]

function SocialUI:CreateMainFrame()
  local frame
  if BackdropTemplateMixin then
    frame = CreateFrame("Frame", "HitToolsSocialUI", UIParent, "BackdropTemplate")
  else
    frame = CreateFrame("Frame", "HitToolsSocialUI", UIParent)
  end

  -- Restore size from SavedVars or use defaults
  local db = HitTools.DB and HitTools.DB.socialUI
  local width = (db and db.width) or 700
  local height = (db and db.height) or 500

  frame:SetSize(width, height)
  frame:SetFrameStrata("HIGH")
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:Hide()

  -- Restore position from SavedVars
  if db and db.point then
    frame:SetPoint(db.point, UIParent, db.relativePoint or db.point, db.x or 0, db.y or 0)
  else
    frame:SetPoint("CENTER")
  end

  if frame.SetBackdrop then
    frame:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true,
      tileSize = 32,
      edgeSize = 32,
      insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
  end

  -- Header
  frame.header = CreateFrame("Frame", nil, frame)
  frame.header:SetPoint("TOPLEFT", 12, -12)
  frame.header:SetPoint("TOPRIGHT", -12, -12)
  frame.header:SetHeight(32)

  frame.title = frame.header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  frame.title:SetPoint("LEFT")
  frame.title:SetText("Hit-Tools - Social Heatmap")

  -- Close button
  frame.closeBtn = CreateFrame("Button", nil, frame.header, "UIPanelCloseButton")
  frame.closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
  frame.closeBtn:SetScript("OnClick", function()
    SocialUI:Hide()
  end)

  -- Make draggable with position saving
  frame.header:EnableMouse(true)
  frame.header:RegisterForDrag("LeftButton")
  frame.header:SetScript("OnDragStart", function() frame:StartMoving() end)
  frame.header:SetScript("OnDragStop", function()
    frame:StopMovingOrSizing()
    -- Save position to DB
    local db = HitTools.DB and HitTools.DB.socialUI
    if db then
      local point, _, relativePoint, x, y = frame:GetPoint(1)
      db.point = point
      db.relativePoint = relativePoint
      db.x = x
      db.y = y
    end
  end)

  self.mainFrame = frame
end

--[[═══════════════════════════════════════════════════════════════════════════
  TABS
═══════════════════════════════════════════════════════════════════════════════]]

function SocialUI:CreateTabs()
  local frame = self.mainFrame

  -- Tab container
  frame.tabContainer = CreateFrame("Frame", nil, frame)
  frame.tabContainer:SetPoint("TOPLEFT", frame.header, "BOTTOMLEFT", 0, -8)
  frame.tabContainer:SetPoint("TOPRIGHT", frame.header, "BOTTOMRIGHT", 0, -8)
  frame.tabContainer:SetHeight(28)

  local tabNames = {"Players", "Pairings", "Runs", "Settings"}
  frame.tabs = {}

  for i, name in ipairs(tabNames) do
    local tab = CreateFrame("Button", nil, frame.tabContainer)
    tab:SetSize(100, 24)
    tab:SetPoint("LEFT", (i - 1) * 105, 0)

    tab:SetNormalFontObject("GameFontNormal")
    tab:SetHighlightFontObject("GameFontHighlight")
    tab:SetText(name)

    tab.bg = tab:CreateTexture(nil, "BACKGROUND")
    tab.bg:SetAllPoints()
    tab.bg:SetTexture("Interface\\Buttons\\WHITE8x8")
    tab.bg:SetVertexColor(0.2, 0.2, 0.2, 0.5)

    tab:SetScript("OnClick", function()
      SocialUI:SelectTab(i)
    end)

    frame.tabs[i] = tab
  end

  -- Content frame
  frame.content = CreateFrame("Frame", nil, frame)
  frame.content:SetPoint("TOPLEFT", frame.tabContainer, "BOTTOMLEFT", 0, -8)
  frame.content:SetPoint("BOTTOMRIGHT", -12, 12)
end

function SocialUI:SelectTab(tabIndex)
  self.currentTab = tabIndex

  -- Save current tab to SavedVars
  local db = HitTools.DB and HitTools.DB.socialUI
  if db then
    db.lastTab = tabIndex
  end

  -- Update tab visuals
  for i, tab in ipairs(self.mainFrame.tabs) do
    if i == tabIndex then
      tab.bg:SetVertexColor(0.3, 0.5, 0.7, 0.8)
    else
      tab.bg:SetVertexColor(0.2, 0.2, 0.2, 0.5)
    end
  end

  -- Show/hide content
  if self.playersContent then self.playersContent:SetShown(tabIndex == TAB_PLAYERS) end
  if self.pairingsContent then self.pairingsContent:SetShown(tabIndex == TAB_PAIRINGS) end
  if self.runsContent then self.runsContent:SetShown(tabIndex == TAB_RUNS) end
  if self.settingsContent then self.settingsContent:SetShown(tabIndex == TAB_SETTINGS) end

  if tabIndex == TAB_PLAYERS then
    self:RefreshPlayersTab()
  elseif tabIndex == TAB_PAIRINGS then
    self:RefreshPairingsTab()
  elseif tabIndex == TAB_RUNS then
    self:RefreshRunsTab()
  elseif tabIndex == TAB_SETTINGS then
    self:RefreshSettingsTab()
  end
end

--[[═══════════════════════════════════════════════════════════════════════════
  PLAYERS TAB
═══════════════════════════════════════════════════════════════════════════════]]

function SocialUI:CreatePlayersTab()
  local content = CreateFrame("Frame", nil, self.mainFrame.content)
  content:SetAllPoints()
  content:Hide()
  self.playersContent = content

  -- Filter bar
  content.filterBar = CreateFrame("Frame", nil, content)
  content.filterBar:SetPoint("TOPLEFT")
  content.filterBar:SetPoint("TOPRIGHT")
  content.filterBar:SetHeight(70)

  -- Row 1: Search + Dropdowns
  -- Search box
  content.searchBox = CreateFrame("EditBox", nil, content.filterBar)
  content.searchBox:SetSize(120, 20)
  content.searchBox:SetPoint("TOPLEFT", 4, -20)
  content.searchBox:SetAutoFocus(false)
  content.searchBox:SetFontObject("ChatFontNormal")

  if content.searchBox.SetBackdrop then
    content.searchBox:SetBackdrop({
      bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
      edgeFile = "Interface\\ChatFrame\\ChatFrameBackground",
      tile = true,
      edgeSize = 1,
      tileSize = 5,
    })
    content.searchBox:SetBackdropColor(0, 0, 0, 0.5)
    content.searchBox:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)
  end

  -- Debounced search with 0.1s delay
  content.searchBox._lastUpdate = 0
  content.searchBox._pendingText = nil
  content.searchBox:SetScript("OnTextChanged", function(self)
    local text = self:GetText():lower()
    self._pendingText = text
    local now = GetTime()

    if now - self._lastUpdate > 0.1 then
      self._lastUpdate = now
      SocialUI.filters.search = text
      SocialUI:InvalidateFilterCache()
      SocialUI:RefreshPlayersTab()
    else
      -- Schedule delayed update
      if C_Timer and C_Timer.After then
        C_Timer.After(0.1, function()
          if self._pendingText then
            SocialUI.filters.search = self._pendingText
            SocialUI:InvalidateFilterCache()
            SocialUI:RefreshPlayersTab()
            self._lastUpdate = GetTime()
          end
        end)
      end
    end
  end)

  content.searchBox:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
  end)

  local searchLabel = content.filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  searchLabel:SetPoint("BOTTOMLEFT", content.searchBox, "TOPLEFT", 0, 2)
  searchLabel:SetText("Search:")

  -- Time window dropdown
  local timeLabel = content.filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  timeLabel:SetPoint("LEFT", searchLabel, "RIGHT", 130, 0)
  timeLabel:SetText("Time:")

  content.timeDropdown = CreateDropdown(content.filterBar, 80, {
    {value = 0, text = "All"},
    {value = 7, text = "7 days"},
    {value = 30, text = "30 days"},
    {value = 90, text = "90 days"},
  }, function(value)
    SocialUI.filters.timeWindow = value
    SocialUI:InvalidateFilterCache()
    SocialUI:RefreshPlayersTab()
  end)
  content.timeDropdown:SetPoint("LEFT", content.searchBox, "RIGHT", 8, 0)

  -- Role filter dropdown
  local roleLabel = content.filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  roleLabel:SetPoint("LEFT", timeLabel, "RIGHT", 90, 0)
  roleLabel:SetText("Role:")

  content.roleDropdown = CreateDropdown(content.filterBar, 80, {
    {value = "ANY", text = "Any"},
    {value = "TANK", text = "Tank"},
    {value = "HEALER", text = "Healer"},
    {value = "DPS", text = "DPS"},
  }, function(value)
    SocialUI.filters.roleFilter = value
    SocialUI:InvalidateFilterCache()
    SocialUI:RefreshPlayersTab()
  end)
  content.roleDropdown:SetPoint("LEFT", content.timeDropdown, "RIGHT", 8, 0)

  -- Dungeon filter dropdown
  local dungeonLabel = content.filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  dungeonLabel:SetPoint("LEFT", roleLabel, "RIGHT", 90, 0)
  dungeonLabel:SetText("Dungeon:")

  content.dungeonDropdown = CreateDropdown(content.filterBar, 100, {
    {value = "ANY", text = "Any"},
  }, function(value)
    SocialUI.filters.instanceFilter = value
    SocialUI:InvalidateFilterCache()
    SocialUI:RefreshPlayersTab()
  end)
  content.dungeonDropdown:SetPoint("LEFT", content.roleDropdown, "RIGHT", 8, 0)

  -- Row 2: Checkboxes
  -- Frequent only checkbox
  content.frequentCheck = CreateFrame("CheckButton", nil, content.filterBar, "UICheckButtonTemplate")
  content.frequentCheck:SetPoint("TOPLEFT", content.searchBox, "BOTTOMLEFT", 0, -8)
  content.frequentCheck:SetScript("OnClick", function(self)
    SocialUI.filters.frequentOnly = self:GetChecked()
    SocialUI:InvalidateFilterCache()
    SocialUI:RefreshPlayersTab()
  end)

  local freqLabel = content.filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  freqLabel:SetPoint("LEFT", content.frequentCheck, "RIGHT", 2, 0)
  freqLabel:SetText("Only frequent (3+ runs)")

  -- In-party only checkbox
  content.inPartyCheck = CreateFrame("CheckButton", nil, content.filterBar, "UICheckButtonTemplate")
  content.inPartyCheck:SetPoint("LEFT", freqLabel, "RIGHT", 16, 0)
  content.inPartyCheck:SetScript("OnClick", function(self)
    SocialUI.filters.inPartyOnly = self:GetChecked()
    SocialUI:InvalidateFilterCache()
    SocialUI:RefreshPlayersTab()
  end)

  local partyLabel = content.filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  partyLabel:SetPoint("LEFT", content.inPartyCheck, "RIGHT", 2, 0)
  partyLabel:SetText("Show in-party only")

  -- Column headers
  content.headerFrame = CreateFrame("Frame", nil, content)
  content.headerFrame:SetPoint("TOPLEFT", content.filterBar, "BOTTOMLEFT", 0, -4)
  content.headerFrame:SetPoint("TOPRIGHT", content.filterBar, "BOTTOMRIGHT", -24, -4)
  content.headerFrame:SetHeight(20)

  content.headerFrame.bg = content.headerFrame:CreateTexture(nil, "BACKGROUND")
  content.headerFrame.bg:SetAllPoints()
  content.headerFrame.bg:SetTexture("Interface\\Buttons\\WHITE8x8")
  content.headerFrame.bg:SetVertexColor(0.15, 0.15, 0.15, 0.8)

  local headers = {
    {key = "name", text = "Name", width = 120, x = 4},
    {key = "runs", text = "Runs", width = 40, x = 128},
    {key = "completes", text = "Complete%", width = 60, x = 172},
    {key = "synergy", text = "Synergy", width = 80, x = 236},
    {key = "lastSeen", text = "Last Seen", width = 80, x = 320},
  }

  content.headers = {}
  for i, h in ipairs(headers) do
    local header = CreateFrame("Button", nil, content.headerFrame)
    header:SetSize(h.width, 18)
    header:SetPoint("LEFT", h.x, 0)

    header.text = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    header.text:SetPoint("LEFT", 0, 0)
    header.text:SetText(h.text)
    header.text:SetTextColor(0.9, 0.9, 0.9)

    header.arrow = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    header.arrow:SetPoint("LEFT", header.text, "RIGHT", 2, 0)
    header.arrow:SetText("")
    header.arrow:SetTextColor(0.7, 0.9, 1.0)

    header:SetScript("OnEnter", function(self)
      self.text:SetTextColor(1, 1, 1)
    end)

    header:SetScript("OnLeave", function(self)
      if SocialUI.sortColumn == h.key then
        self.text:SetTextColor(0.7, 0.9, 1.0)
      else
        self.text:SetTextColor(0.9, 0.9, 0.9)
      end
    end)

    header:SetScript("OnClick", function(self)
      if SocialUI.sortColumn == h.key then
        SocialUI.sortAsc = not SocialUI.sortAsc
      else
        SocialUI.sortColumn = h.key
        SocialUI.sortAsc = false
      end
      SocialUI:UpdateColumnHeaders()
      SocialUI:InvalidateFilterCache()
      SocialUI:RefreshPlayersTab()
    end)

    content.headers[h.key] = header
  end

  -- Player list scroll frame
  content.scrollFrame = CreateFrame("ScrollFrame", nil, content)
  content.scrollFrame:SetPoint("TOPLEFT", content.headerFrame, "BOTTOMLEFT", 0, -2)
  content.scrollFrame:SetPoint("BOTTOMRIGHT", -24, 0)

  content.scrollChild = CreateFrame("Frame", nil, content.scrollFrame)
  content.scrollFrame:SetScrollChild(content.scrollChild)
  content.scrollChild:SetSize(650, 1)

  -- Scroll bar
  content.scrollBar = CreateFrame("Slider", nil, content.scrollFrame)
  content.scrollBar:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, -68)
  content.scrollBar:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -4, 4)
  content.scrollBar:SetWidth(16)
  content.scrollBar:SetOrientation("VERTICAL")
  content.scrollBar:SetMinMaxValues(0, 100)
  content.scrollBar:SetValue(0)
  content.scrollBar:SetValueStep(20)

  if content.scrollBar.SetBackdrop then
    content.scrollBar:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8x8",
      edgeFile = "Interface\\Buttons\\WHITE8x8",
      tile = false,
      edgeSize = 1,
    })
    content.scrollBar:SetBackdropColor(0.1, 0.1, 0.1, 0.5)
    content.scrollBar:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)
  end

  content.scrollBar.thumb = content.scrollBar:CreateTexture(nil, "OVERLAY")
  content.scrollBar.thumb:SetSize(14, 24)
  content.scrollBar.thumb:SetTexture("Interface\\Buttons\\WHITE8x8")
  content.scrollBar.thumb:SetVertexColor(0.4, 0.4, 0.4, 0.8)
  content.scrollBar:SetThumbTexture(content.scrollBar.thumb)

  content.scrollBar:SetScript("OnValueChanged", function(self, value)
    content.scrollChild:SetPoint("TOPLEFT", 0, value)
  end)

  -- Enable mousewheel scrolling
  content.scrollFrame:EnableMouseWheel(true)
  content.scrollFrame:SetScript("OnMouseWheel", function(self, delta)
    local current = content.scrollBar:GetValue()
    local minVal, maxVal = content.scrollBar:GetMinMaxValues()
    local step = 30 -- Scroll speed (pixels per wheel tick)

    local newValue = current - (delta * step)
    newValue = math.max(minVal, math.min(maxVal, newValue))

    content.scrollBar:SetValue(newValue)
  end)

  -- Empty state message (shown when no players tracked)
  content.emptyState = CreateFrame("Frame", nil, content)
  content.emptyState:SetPoint("TOPLEFT", content.headerFrame, "BOTTOMLEFT", 0, -50)
  content.emptyState:SetPoint("TOPRIGHT", content.headerFrame, "BOTTOMRIGHT", 0, -50)
  content.emptyState:SetHeight(200)
  content.emptyState:Hide()

  content.emptyState.icon = content.emptyState:CreateTexture(nil, "ARTWORK")
  content.emptyState.icon:SetSize(64, 64)
  content.emptyState.icon:SetPoint("TOP", 0, -20)
  content.emptyState.icon:SetTexture("Interface\\FriendsFrame\\Battlenet-Portrait")
  content.emptyState.icon:SetVertexColor(0.5, 0.5, 0.5, 0.6)

  content.emptyState.title = content.emptyState:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  content.emptyState.title:SetPoint("TOP", content.emptyState.icon, "BOTTOM", 0, -12)
  content.emptyState.title:SetText("No Players Tracked Yet")
  content.emptyState.title:SetTextColor(0.7, 0.7, 0.7)

  content.emptyState.text = content.emptyState:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  content.emptyState.text:SetPoint("TOP", content.emptyState.title, "BOTTOM", 0, -8)
  content.emptyState.text:SetWidth(400)
  content.emptyState.text:SetJustifyH("CENTER")
  content.emptyState.text:SetText("Run a dungeon with a party to start tracking players.\n\nPlayers will appear here automatically when you zone into\nan instance with 2+ people.")
  content.emptyState.text:SetTextColor(0.6, 0.6, 0.6)

  -- Player rows (pooled) - CREATE ACTUAL FRAMES
  content.playerRows = {}

  local ROW_HEIGHT = 32
  local MAX_VISIBLE_ROWS = 15

  DebugPrint(string.format("Creating %d player row frames...", MAX_VISIBLE_ROWS))

  for i = 1, MAX_VISIBLE_ROWS do
    local ok, result = pcall(function()
      return self:CreatePlayerRow(content.scrollChild, i)
    end)

    if not ok then
      print(string.format("[SocialUI] ERROR creating row %d: %s", i, tostring(result)))
      break
    end

    local row = result
    if not row then
      print(string.format("[SocialUI] ERROR: CreatePlayerRow returned nil for row %d", i))
      break
    end

    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", content.scrollChild, "TOPLEFT", 4, -(i - 1) * ROW_HEIGHT)
    row:SetPoint("RIGHT", content.scrollFrame, "RIGHT", -20, 0)
    row:Hide()
    content.playerRows[i] = row
  end

  DebugPrint(string.format("Created %d row frames successfully", #content.playerRows))

  -- Set scrollChild height to accommodate all rows
  content.scrollChild:SetHeight(MAX_VISIBLE_ROWS * ROW_HEIGHT)

  -- STEP 2: Frame construction assertions
  assert(self.playersContent, "[SocialUI] FATAL: playersContent is nil after CreatePlayersTab")
  assert(self.playersContent.scrollFrame, "[SocialUI] FATAL: scrollFrame is nil after CreatePlayersTab")
  assert(self.playersContent.scrollChild, "[SocialUI] FATAL: scrollChild is nil after CreatePlayersTab")
  assert(self.playersContent.emptyState, "[SocialUI] FATAL: emptyState is nil after CreatePlayersTab")
  assert(self.playersContent.playerRows, "[SocialUI] FATAL: playerRows table is nil after CreatePlayersTab")
  assert(#self.playersContent.playerRows > 0, string.format("[SocialUI] FATAL: No player rows created (expected %d, got %d)", MAX_VISIBLE_ROWS, #self.playersContent.playerRows))

  DebugPrint(string.format("CreatePlayersTab complete - %d row frames created and validated", #content.playerRows))
end

function SocialUI:InvalidateFilterCache()
  self.filteredPlayers = nil
  self.lastFilterHash = nil
end

function SocialUI:UpdateColumnHeaders()
  if not self.playersContent or not self.playersContent.headers then return end

  for key, header in pairs(self.playersContent.headers) do
    if key == self.sortColumn then
      header.arrow:SetText(self.sortAsc and "▲" or "▼")
      header.text:SetTextColor(0.7, 0.9, 1.0)
    else
      header.arrow:SetText("")
      header.text:SetTextColor(0.9, 0.9, 0.9)
    end
  end
end

function SocialUI:RefreshDungeonDropdown()
  if not self.playersContent or not self.playersContent.dungeonDropdown then return end

  local db = HitTools.DB and HitTools.DB.social
  if not db or not db.runs then return end

  -- Collect unique instances
  local instances = {}
  local instanceSet = {}

  for _, run in pairs(db.runs) do
    if run.instanceName and run.instanceID and not instanceSet[run.instanceID] then
      instanceSet[run.instanceID] = true
      instances[#instances + 1] = {
        id = run.instanceID,
        name = run.instanceName
      }
    end
  end

  -- Sort alphabetically
  table.sort(instances, function(a, b) return a.name < b.name end)

  -- Build dropdown options
  local options = {{value = "ANY", text = "Any"}}
  for _, inst in ipairs(instances) do
    options[#options + 1] = {value = inst.id, text = inst.name}
  end

  -- Update dropdown options
  local dropdown = self.playersContent.dungeonDropdown
  dropdown.options = options

  -- Recreate menu items
  if dropdown.menu then
    for _, item in ipairs(dropdown.menuItems or {}) do
      item:Hide()
    end
  end

  dropdown.menuItems = {}
  dropdown.menu:SetHeight(#options * 20)

  for i, option in ipairs(options) do
    local item = CreateFrame("Button", nil, dropdown.menu)
    item:SetSize(dropdown:GetWidth() - 8, 18)
    item:SetPoint("TOPLEFT", 4, -(i - 1) * 20 - 4)

    item.bg = item:CreateTexture(nil, "BACKGROUND")
    item.bg:SetAllPoints()
    item.bg:SetTexture("Interface\\Buttons\\WHITE8x8")
    item.bg:SetVertexColor(0, 0, 0, 0)

    item.text = item:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
    item.text:SetPoint("LEFT", 4, 0)
    item.text:SetText(option.text)
    item.text:SetTextColor(1, 1, 1)

    item:SetScript("OnEnter", function(self)
      self.bg:SetVertexColor(0.3, 0.5, 0.7, 0.5)
    end)

    item:SetScript("OnLeave", function(self)
      self.bg:SetVertexColor(0, 0, 0, 0)
    end)

    item:SetScript("OnClick", function(self)
      dropdown.currentValue = option.value
      dropdown.text:SetText(option.text)
      dropdown.menu:Hide()
      if dropdown.onSelect then
        dropdown.onSelect(option.value)
      end
    end)

    dropdown.menuItems[i] = item
  end
end

function SocialUI:GetFilteredPlayers()
  -- DIAGNOSTIC: Log filter state
  if HitTools.DB and HitTools.DB.social and HitTools.DB.social.debug then
    HitTools:Print(string.format("[SocialUI.GetFilteredPlayers] search='%s', time=%d, role=%s, instance=%s, frequent=%s, inParty=%s",
      self.filters.search or "",
      self.filters.timeWindow or 0,
      self.filters.roleFilter or "ANY",
      self.filters.instanceFilter or "ANY",
      tostring(self.filters.frequentOnly),
      tostring(self.filters.inPartyOnly)))
  end

  -- Generate filter hash
  local hash = string.format("%s_%d_%s_%s_%s_%s",
    self.filters.search,
    self.filters.timeWindow,
    self.filters.roleFilter,
    self.filters.instanceFilter,
    tostring(self.filters.frequentOnly),
    tostring(self.filters.inPartyOnly)
  )

  if self.lastFilterHash == hash and self.filteredPlayers then
    if HitTools.DB and HitTools.DB.social and HitTools.DB.social.debug then
      HitTools:Print(string.format("[SocialUI.GetFilteredPlayers] Using cached result: %d players", #self.filteredPlayers))
    end
    return self.filteredPlayers
  end

  -- Build filtered list
  local players = {}
  local db = HitTools.DB and HitTools.DB.social
  if not db or not db.playersById then
    if HitTools.DB and HitTools.DB.social and HitTools.DB.social.debug then
      HitTools:Print(string.format("[SocialUI.GetFilteredPlayers] DB not found or no playersById table (db=%s)", tostring(db ~= nil)))
    end
    return players
  end

  local now = GetTime()

  -- DIAGNOSTIC: Count players in DB
  local dbPlayerCount = 0
  for _ in pairs(db.playersById) do dbPlayerCount = dbPlayerCount + 1 end
  if HitTools.DB and HitTools.DB.social and HitTools.DB.social.debug then
    HitTools:Print(string.format("[SocialUI.GetFilteredPlayers] DB has %d players", dbPlayerCount))
  end

  -- Get current party/raid roster for in-party filter (using canonical IDs)
  local partyRoster = {}
  if self.filters.inPartyOnly then
    if IsInRaid() then
      for i = 1, GetNumGroupMembers() do
        local unit = "raid" .. i
        if UnitExists(unit) then
          local name, realm = UnitName(unit)
          local guid = UnitGUID(unit)
          local id = HitTools.SocialHeatmap.ResolveId(guid, name, realm)
          if id then
            partyRoster[id] = true
          end
        end
      end
    elseif IsInGroup() then
      for i = 1, GetNumSubgroupMembers() do
        local unit = "party" .. i
        if UnitExists(unit) then
          local name, realm = UnitName(unit)
          local guid = UnitGUID(unit)
          local id = HitTools.SocialHeatmap.ResolveId(guid, name, realm)
          if id then
            partyRoster[id] = true
          end
        end
      end
      -- Add player
      local playerGUID = UnitGUID("player")
      local playerName, playerRealm = UnitName("player")
      local playerID = HitTools.SocialHeatmap.ResolveId(playerGUID, playerName, playerRealm)
      if playerID then
        partyRoster[playerID] = true
      end
    end
  end

  for id, player in pairs(db.playersById) do
    local include = true

    -- Search filter
    if self.filters.search ~= "" then
      if not player.name:lower():find(self.filters.search, 1, true) then
        include = false
      end
    end

    -- Frequent filter
    if self.filters.frequentOnly and player.runsTogether < 3 then
      include = false
    end

    -- Time window filter
    if self.filters.timeWindow > 0 then
      local cutoff = now - (self.filters.timeWindow * 86400)
      if not player.lastSeen or player.lastSeen < cutoff then
        include = false
      end
    end

    -- Role filter
    if include and self.filters.roleFilter ~= "ANY" then
      if not player.rolesObserved or player.rolesObserved[self.filters.roleFilter] == nil or player.rolesObserved[self.filters.roleFilter] == 0 then
        include = false
      end
    end

    -- Instance filter
    if include and self.filters.instanceFilter ~= "ANY" then
      if not player.dungeons or not player.dungeons[self.filters.instanceFilter] then
        include = false
      end
    end

    -- In-party filter
    if include and self.filters.inPartyOnly then
      if not partyRoster[id] then
        include = false
      end
    end

    if include then
      players[#players + 1] = {key = id, data = player}
    end
  end

  -- Sort
  table.sort(players, function(a, b)
    return self:ComparePlayerRows(a, b)
  end)

  self.filteredPlayers = players
  self.lastFilterHash = hash

  -- DIAGNOSTIC: Log result count
  if HitTools.DB and HitTools.DB.social and HitTools.DB.social.debug then
    HitTools:Print(string.format("[SocialUI.GetFilteredPlayers] Filtered result: %d players match filters", #players))
  end

  return players
end

function SocialUI:ComparePlayerRows(a, b)
  local aVal, bVal

  if self.sortColumn == "runs" then
    aVal = a.data.runsTogether or 0
    bVal = b.data.runsTogether or 0
  elseif self.sortColumn == "completes" then
    local aTotal = (a.data.aggregates.completes or 0) + (a.data.aggregates.wipes or 0)
    local bTotal = (b.data.aggregates.completes or 0) + (b.data.aggregates.wipes or 0)
    aVal = aTotal > 0 and (a.data.aggregates.completes or 0) / aTotal or 0
    bVal = bTotal > 0 and (b.data.aggregates.completes or 0) / bTotal or 0
  elseif self.sortColumn == "synergy" then
    local aTotal = (a.data.aggregates.completes or 0) + (a.data.aggregates.wipes or 0)
    local bTotal = (b.data.aggregates.completes or 0) + (b.data.aggregates.wipes or 0)
    aVal = aTotal > 0 and (a.data.aggregates.completes or 0) / aTotal or 0
    bVal = bTotal > 0 and (b.data.aggregates.completes or 0) / bTotal or 0
  elseif self.sortColumn == "lastSeen" then
    aVal = a.data.lastSeen or 0
    bVal = b.data.lastSeen or 0
  elseif self.sortColumn == "name" then
    aVal = a.data.name or ""
    bVal = b.data.name or ""
  else
    aVal = a.data.runsTogether or 0
    bVal = b.data.runsTogether or 0
  end

  if self.sortAsc then
    return aVal < bVal
  else
    return aVal > bVal
  end
end

function SocialUI:RefreshPlayersTab()
  -- Guard: ensure UI is initialized
  if not self.playersContent then
    print("[SocialUI.RefreshPlayersTab] ERROR: playersContent is nil, UI not initialized!")
    return
  end

  if not self.playersContent:IsShown() then
    if HitTools.DB and HitTools.DB.social and HitTools.DB.social.debug then
      HitTools:Print("[SocialUI.RefreshPlayersTab] BLOCKED: content not shown")
    end
    return
  end

  -- DIAGNOSTIC: Log refresh
  if HitTools.DB and HitTools.DB.social and HitTools.DB.social.debug then
    HitTools:Print("[SocialUI.RefreshPlayersTab] Refreshing players tab")
  end

  -- Refresh dungeon dropdown with current data
  self:RefreshDungeonDropdown()

  local players = self:GetFilteredPlayers()
  local content = self.playersContent

  -- DIAGNOSTIC: Log player count
  DebugPrint(string.format("RefreshPlayersTab: Got %d players, emptyState exists: %s",
    #players, tostring(content.emptyState ~= nil)))

  -- Show/hide empty state (with nil check for backwards compatibility)
  if #players == 0 then
    DebugPrint("RefreshPlayersTab: Showing empty state (0 players)")
    if content.emptyState then
      content.emptyState:Show()
    end
    if content.scrollFrame then content.scrollFrame:Hide() end
    if content.scrollBar then content.scrollBar:Hide() end
  else
    DebugPrint(string.format("RefreshPlayersTab: Hiding empty state, showing %d player rows", #players))
    if content.emptyState then
      content.emptyState:Hide()
    end
    if content.scrollFrame then content.scrollFrame:Show() end
    if content.scrollBar then content.scrollBar:Show() end
  end

  -- Hard guard: ensure playerRows exists
  if not content.playerRows then
    print("[SocialUI] ERROR: playerRows is nil, cannot render list!")
    return
  end

  if #content.playerRows == 0 then
    print("[SocialUI] ERROR: playerRows is empty, no row frames created!")
    return
  end

  DebugPrint(string.format("Using %d row frames from pool", #content.playerRows))

  -- Clear existing rows
  for _, row in ipairs(content.playerRows) do
    row:Hide()
  end

  -- Show rows from pool (reuse existing frames)
  local MAX_VISIBLE = #content.playerRows
  for i = 1, MAX_VISIBLE do
    local row = content.playerRows[i]
    if not row then
      print(string.format("[SocialUI] ERROR: Row %d is nil!", i))
      break
    end

    if players[i] then
      self:UpdatePlayerRow(row, players[i])
      row:Show()
    else
      row:Hide()
    end
  end

  -- Update scroll child height
  local totalHeight = #players * 32
  content.scrollChild:SetHeight(math.max(totalHeight, 1))
  content.scrollBar:SetMinMaxValues(0, math.max(0, totalHeight - content.scrollFrame:GetHeight()))
end

function SocialUI:CreatePlayerRow(parent, index)
  local row = CreateFrame("Button", nil, parent)
  row:SetSize(640, 30)

  row.bg = row:CreateTexture(nil, "BACKGROUND")
  row.bg:SetAllPoints()
  row.bg:SetTexture("Interface\\Buttons\\WHITE8x8")
  row.bg:SetVertexColor(0.1, 0.1, 0.1, index % 2 == 0 and 0.3 or 0.1)

  row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  row.name:SetPoint("LEFT", 4, 0)
  row.name:SetWidth(120)
  row.name:SetJustifyH("LEFT")

  row.runs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.runs:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
  row.runs:SetWidth(40)

  row.completes = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.completes:SetPoint("LEFT", row.runs, "RIGHT", 4, 0)
  row.completes:SetWidth(60)

  row.synergy = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.synergy:SetPoint("LEFT", row.completes, "RIGHT", 4, 0)
  row.synergy:SetWidth(80)

  row.lastSeen = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.lastSeen:SetPoint("LEFT", row.synergy, "RIGHT", 4, 0)
  row.lastSeen:SetWidth(80)

  row.friendBtn = CreateFrame("Button", nil, row)
  row.friendBtn:SetSize(60, 20)
  row.friendBtn:SetPoint("RIGHT", -80, 0)
  row.friendBtn:SetNormalFontObject("GameFontNormalSmall")
  row.friendBtn:SetText("+Friend")

  row.friendBtn.bg = row.friendBtn:CreateTexture(nil, "BACKGROUND")
  row.friendBtn.bg:SetAllPoints()
  row.friendBtn.bg:SetTexture("Interface\\Buttons\\WHITE8x8")
  row.friendBtn.bg:SetVertexColor(0.2, 0.4, 0.6, 0.8)

  row.profileBtn = CreateFrame("Button", nil, row)
  row.profileBtn:SetSize(60, 20)
  row.profileBtn:SetPoint("RIGHT", -10, 0)
  row.profileBtn:SetNormalFontObject("GameFontNormalSmall")
  row.profileBtn:SetText("Profile")

  row.profileBtn.bg = row.profileBtn:CreateTexture(nil, "BACKGROUND")
  row.profileBtn.bg:SetAllPoints()
  row.profileBtn.bg:SetTexture("Interface\\Buttons\\WHITE8x8")
  row.profileBtn.bg:SetVertexColor(0.3, 0.5, 0.3, 0.8)

  row:SetScript("OnEnter", function(self)
    self.bg:SetVertexColor(0.2, 0.3, 0.4, 0.5)
  end)

  row:SetScript("OnLeave", function(self)
    self.bg:SetVertexColor(0.1, 0.1, 0.1, index % 2 == 0 and 0.3 or 0.1)
  end)

  -- Register for right-click
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row:SetScript("OnClick", function(self, button)
    if button == "RightButton" and self.playerKey then
      SocialUI:ShowPlayerContextMenu(self.playerKey)
    end
  end)

  return row
end

function SocialUI:UpdatePlayerRow(row, playerData)
  local player = playerData.data
  local key = playerData.key

  -- Store player key for context menu
  row.playerKey = key

  -- Name with class color
  local r, g, b = getClassColor(player.class)
  row.name:SetTextColor(r, g, b)
  row.name:SetText(player.name)

  -- Runs
  row.runs:SetText(player.runsTogether or 0)

  -- Complete %
  local totalRuns = (player.aggregates.completes or 0) + (player.aggregates.wipes or 0)
  local completeRate = totalRuns > 0 and (player.aggregates.completes or 0) / totalRuns * 100 or 0
  row.completes:SetText(string.format("%.0f%%", completeRate))

  -- Synergy
  local synergyLabel = "Mixed"
  if completeRate >= 70 then
    synergyLabel = "Smooth"
    row.synergy:SetTextColor(0.3, 1, 0.3)
  elseif completeRate < 40 then
    synergyLabel = "Spicy"
    row.synergy:SetTextColor(1, 0.3, 0.3)
  else
    row.synergy:SetTextColor(1, 1, 0.3)
  end
  row.synergy:SetText(synergyLabel)

  -- Last seen
  row.lastSeen:SetText(formatTimeAgo(player.lastSeen))

  -- Friend button
  row.friendBtn:SetScript("OnClick", function()
    if HitTools.SocialHeatmap then
      HitTools.SocialHeatmap:QuickAddFriend(key)
    end
  end)

  -- Profile button
  row.profileBtn:SetScript("OnClick", function()
    SocialUI:ShowPlayerDetail(key)
  end)
end

function SocialUI:ShowPlayerContextMenu(playerKey)
  if not playerKey then return end

  local db = HitTools.DB and HitTools.DB.social
  local player = db and select(1, getPlayerRecord(db, playerKey))
  if not player then return end
  local playerName = player.name or "Unknown"

  local menuItems = {
    {
      text = playerName,
      isTitle = true,
      notCheckable = true,
    },
    {
      text = "View Profile",
      func = function()
        self:ShowPlayerDetail(playerKey)
      end,
      notCheckable = true,
    },
    {
      text = "Add Friend",
      func = function()
        if HitTools.SocialHeatmap then
          HitTools.SocialHeatmap:QuickAddFriend(playerKey)
        end
      end,
      notCheckable = true,
    },
    {
      text = "Add Tag",
      func = function()
        local dialog = StaticPopup_Show("HITSOCIAL_ADD_TAG", playerName)
        if dialog then
          dialog.playerKey = playerKey
        end
      end,
      notCheckable = true,
    },
    {
      text = "Edit Notes",
      func = function()
        local dialog = StaticPopup_Show("HITSOCIAL_EDIT_NOTES", playerName)
        if dialog then
          dialog.playerKey = playerKey
        end
      end,
      notCheckable = true,
    },
    {
      text = "Ignore Player",
      func = function()
        AddIgnore(playerName)
        HitTools:Print("Added " .. playerName .. " to ignore list")
      end,
      notCheckable = true,
    },
    {
      text = "Reset Stats",
      func = function()
        local dialog = StaticPopup_Show("HITSOCIAL_RESET_PLAYER", playerName)
        if dialog then
          dialog.playerKey = playerKey
        end
      end,
      notCheckable = true,
    },
  }

  -- Use EasyMenu if available, otherwise create custom menu
  if EasyMenu then
    EasyMenu(menuItems, CreateFrame("Frame", "HitSocialContextMenu", UIParent, "UIDropDownMenuTemplate"), "cursor", 0, 0, "MENU")
  else
    -- Fallback: print menu options to chat
    HitTools:Print("Right-click menu for " .. playerName .. ":")
    for i, item in ipairs(menuItems) do
      if not item.isTitle then
        HitTools:Print(i .. ". " .. item.text)
      end
    end
  end
end

--[[═══════════════════════════════════════════════════════════════════════════
  PLAYER DETAIL PANEL
═══════════════════════════════════════════════════════════════════════════════]]

function SocialUI:CreatePlayerDetailPanel()
  local frame = CreateFrame("Frame", "HitToolsSocialPlayerDetail", UIParent, "BackdropTemplate")
  frame:SetSize(400, 500)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("FULLSCREEN_DIALOG")
  frame:SetMovable(true)
  frame:Hide()

  if frame.SetBackdrop then
    frame:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true,
      tileSize = 32,
      edgeSize = 32,
      insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
  end

  frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  frame.title:SetPoint("TOP", 0, -16)

  frame.closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  frame.closeBtn:SetPoint("TOPRIGHT", -4, -4)
  frame.closeBtn:SetScript("OnClick", function() frame:Hide() end)

  frame.content = CreateFrame("ScrollFrame", nil, frame)
  frame.content:SetPoint("TOPLEFT", 16, -50)
  frame.content:SetPoint("BOTTOMRIGHT", -16, 16)

  frame.scrollChild = CreateFrame("Frame", nil, frame.content)
  frame.content:SetScrollChild(frame.scrollChild)
  frame.scrollChild:SetSize(360, 1000)

  -- Enable mousewheel scrolling
  frame.content:EnableMouseWheel(true)
  frame.content:SetScript("OnMouseWheel", function(self, delta)
    local currentScroll = self:GetVerticalScroll()
    local scrollRange = self:GetVerticalScrollRange()
    local step = 30 -- Scroll speed (pixels per wheel tick)

    local newScroll = currentScroll - (delta * step)
    newScroll = math.max(0, math.min(scrollRange, newScroll))

    self:SetVerticalScroll(newScroll)
  end)

  self.playerDetailFrame = frame
end

function SocialUI:ShowPlayerDetail(playerKey)
  if not HitTools.DB or not HitTools.DB.social then return end

  local player = select(1, getPlayerRecord(HitTools.DB.social, playerKey))
  if not player then return end

  local frame = self.playerDetailFrame
  if not frame then return end

  -- Set title
  local r, g, b = getClassColor(player.class)
  frame.title:SetTextColor(r, g, b)
  frame.title:SetText(player.name)

  -- Clear previous content
  for _, child in pairs({frame.scrollChild:GetChildren()}) do
    child:Hide()
  end

  local yOffset = -10
  local totalRuns = (player.aggregates.completes or 0) + (player.aggregates.wipes or 0)
  local completeRate = totalRuns > 0 and (player.aggregates.completes or 0) / totalRuns * 100 or 0

  -- Stats Section
  local statsHeader = frame.scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  statsHeader:SetPoint("TOPLEFT", 0, yOffset)
  statsHeader:SetText("Statistics")
  yOffset = yOffset - 24

  local statsText = frame.scrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  statsText:SetPoint("TOPLEFT", 0, yOffset)
  statsText:SetJustifyH("LEFT")
  statsText:SetWidth(360)
  statsText:SetText(string.format(
    "Runs: %d\nCompletes: %d (%.0f%%)\nWipes: %d\nAvg Deaths: %.1f\nLast Seen: %s",
    player.runsTogether or 0,
    player.aggregates.completes or 0,
    completeRate,
    player.aggregates.wipes or 0,
    totalRuns > 0 and (player.aggregates.deathsTotal or 0) / totalRuns or 0,
    formatTimeAgo(player.lastSeen)
  ))
  yOffset = yOffset - 110

  -- Friend Status Section
  local friendHeader = frame.scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  friendHeader:SetPoint("TOPLEFT", 0, yOffset)
  friendHeader:SetText("Friend Status")
  yOffset = yOffset - 24

  local friendInfo = frame.scrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  friendInfo:SetPoint("TOPLEFT", 0, yOffset)
  friendInfo:SetJustifyH("LEFT")
  friendInfo:SetWidth(360)

  local friendStatus = player.friend and player.friend.isCharFriend and "On Friends List" or "Not on Friends List"
  local friendColor = player.friend and player.friend.isCharFriend and "|cff00ff00" or "|cffff0000"
  local bnetStatus = player.friend and player.friend.bnet or "(not set)"

  friendInfo:SetText(string.format(
    "Character Friend: %s%s|r\nBattleTag: %s",
    friendColor,
    friendStatus,
    bnetStatus
  ))
  yOffset = yOffset - 50

  local addFriendBtn = CreateFrame("Button", nil, frame.scrollChild)
  addFriendBtn:SetSize(150, 24)
  addFriendBtn:SetPoint("TOPLEFT", 0, yOffset)
  addFriendBtn:SetNormalFontObject("GameFontNormal")
  addFriendBtn:SetText("Add to Friends")
  addFriendBtn.bg = addFriendBtn:CreateTexture(nil, "BACKGROUND")
  addFriendBtn.bg:SetAllPoints()
  addFriendBtn.bg:SetTexture("Interface\\Buttons\\WHITE8x8")
  addFriendBtn.bg:SetVertexColor(0.3, 0.5, 0.7, 0.8)
  addFriendBtn:SetScript("OnClick", function()
    if HitTools.SocialHeatmap then
      HitTools.SocialHeatmap:QuickAddFriend(playerKey)
    end
  end)
  yOffset = yOffset - 36

  -- Tags Section
  local tagsHeader = frame.scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  tagsHeader:SetPoint("TOPLEFT", 0, yOffset)
  tagsHeader:SetText("Tags")
  yOffset = yOffset - 24

  local tagsText = frame.scrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  tagsText:SetPoint("TOPLEFT", 0, yOffset)
  tagsText:SetJustifyH("LEFT")
  tagsText:SetWidth(360)

  if player.tags and #player.tags > 0 then
    tagsText:SetText(table.concat(player.tags, ", "))
  else
    tagsText:SetText("(no tags)")
    tagsText:SetTextColor(0.6, 0.6, 0.6)
  end
  yOffset = yOffset - 30

  -- Notes Section
  local notesHeader = frame.scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  notesHeader:SetPoint("TOPLEFT", 0, yOffset)
  notesHeader:SetText("Notes")
  yOffset = yOffset - 24

  local notesText = frame.scrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  notesText:SetPoint("TOPLEFT", 0, yOffset)
  notesText:SetJustifyH("LEFT")
  notesText:SetWidth(360)

  if player.notes and player.notes ~= "" then
    notesText:SetText(player.notes)
  else
    notesText:SetText("(no notes)")
    notesText:SetTextColor(0.6, 0.6, 0.6)
  end
  yOffset = yOffset - 60

  -- Dungeon Breakdown Section
  if player.dungeons and next(player.dungeons) then
    local dungeonHeader = frame.scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    dungeonHeader:SetPoint("TOPLEFT", 0, yOffset)
    dungeonHeader:SetText("Dungeon Breakdown")
    yOffset = yOffset - 24

    -- Sort dungeons by runs
    local dungeonList = {}
    for instanceID, data in pairs(player.dungeons) do
      dungeonList[#dungeonList + 1] = {id = instanceID, data = data}
    end
    table.sort(dungeonList, function(a, b)
      return (a.data.runs or 0) > (b.data.runs or 0)
    end)

    for _, dungeon in ipairs(dungeonList) do
      local dungeonData = dungeon.data
      local runs = dungeonData.runs or 0
      local completes = dungeonData.completes or 0
      local dungeonCompleteRate = runs > 0 and completes / runs * 100 or 0

      -- Get dungeon name from runs (if available)
      local dungeonName = "Unknown"
      if HitTools.DB and HitTools.DB.social and HitTools.DB.social.runs then
        for _, run in pairs(HitTools.DB.social.runs) do
          if run.instanceID == dungeon.id then
            dungeonName = run.instanceName or "Unknown"
            break
          end
        end
      end

      local dungeonLine = frame.scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      dungeonLine:SetPoint("TOPLEFT", 0, yOffset)
      dungeonLine:SetJustifyH("LEFT")
      dungeonLine:SetWidth(360)
      dungeonLine:SetText(string.format("  %s: %d runs (%.0f%% complete)", dungeonName, runs, dungeonCompleteRate))
      yOffset = yOffset - 18
    end
  end

  frame:Show()
end

--[[═══════════════════════════════════════════════════════════════════════════
  PAIRINGS TAB
═══════════════════════════════════════════════════════════════════════════════]]

function SocialUI:CreatePairingsTab()
  local content = CreateFrame("Frame", nil, self.mainFrame.content)
  content:SetAllPoints()
  content:Hide()
  self.pairingsContent = content

  -- Filter bar
  content.filterBar = CreateFrame("Frame", nil, content)
  content.filterBar:SetPoint("TOPLEFT")
  content.filterBar:SetPoint("TOPRIGHT")
  content.filterBar:SetHeight(40)

  -- Search box
  content.searchBox = CreateFrame("EditBox", nil, content.filterBar)
  content.searchBox:SetSize(120, 20)
  content.searchBox:SetPoint("TOPLEFT", 4, -20)
  content.searchBox:SetAutoFocus(false)
  content.searchBox:SetFontObject("ChatFontNormal")

  if content.searchBox.SetBackdrop then
    content.searchBox:SetBackdrop({
      bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
      edgeFile = "Interface\\ChatFrame\\ChatFrameBackground",
      tile = true,
      edgeSize = 1,
      tileSize = 5,
    })
    content.searchBox:SetBackdropColor(0, 0, 0, 0.5)
    content.searchBox:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)
  end

  content.searchBox:SetScript("OnTextChanged", function(self)
    SocialUI.pairingsFilters = SocialUI.pairingsFilters or {}
    SocialUI.pairingsFilters.search = self:GetText():lower()
    SocialUI:RefreshPairingsTab()
  end)

  content.searchBox:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
  end)

  local searchLabel = content.filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  searchLabel:SetPoint("BOTTOMLEFT", content.searchBox, "TOPLEFT", 0, 2)
  searchLabel:SetText("Search:")

  -- Time window dropdown
  local timeLabel = content.filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  timeLabel:SetPoint("LEFT", searchLabel, "RIGHT", 130, 0)
  timeLabel:SetText("Time:")

  content.timeDropdown = CreateDropdown(content.filterBar, 80, {
    {value = 0, text = "All"},
    {value = 7, text = "7 days"},
    {value = 30, text = "30 days"},
    {value = 90, text = "90 days"},
  }, function(value)
    SocialUI.pairingsFilters = SocialUI.pairingsFilters or {}
    SocialUI.pairingsFilters.timeWindow = value
    SocialUI:RefreshPairingsTab()
  end)
  content.timeDropdown:SetPoint("LEFT", content.searchBox, "RIGHT", 8, 0)

  -- Scroll frame
  content.scrollFrame = CreateFrame("ScrollFrame", nil, content)
  content.scrollFrame:SetPoint("TOPLEFT", content.filterBar, "BOTTOMLEFT", 0, -8)
  content.scrollFrame:SetPoint("BOTTOMRIGHT", -24, 0)

  content.scrollChild = CreateFrame("Frame", nil, content.scrollFrame)
  content.scrollFrame:SetScrollChild(content.scrollChild)
  content.scrollChild:SetSize(650, 1)

  -- Scroll bar
  content.scrollBar = CreateFrame("Slider", nil, content.scrollFrame)
  content.scrollBar:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, -48)
  content.scrollBar:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -4, 4)
  content.scrollBar:SetWidth(16)
  content.scrollBar:SetOrientation("VERTICAL")
  content.scrollBar:SetMinMaxValues(0, 100)
  content.scrollBar:SetValue(0)
  content.scrollBar:SetValueStep(20)

  if content.scrollBar.SetBackdrop then
    content.scrollBar:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8x8",
      edgeFile = "Interface\\Buttons\\WHITE8x8",
      tile = false,
      edgeSize = 1,
    })
    content.scrollBar:SetBackdropColor(0.1, 0.1, 0.1, 0.5)
    content.scrollBar:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)
  end

  content.scrollBar.thumb = content.scrollBar:CreateTexture(nil, "OVERLAY")
  content.scrollBar.thumb:SetSize(14, 24)
  content.scrollBar.thumb:SetTexture("Interface\\Buttons\\WHITE8x8")
  content.scrollBar.thumb:SetVertexColor(0.4, 0.4, 0.4, 0.8)
  content.scrollBar:SetThumbTexture(content.scrollBar.thumb)

  content.scrollBar:SetScript("OnValueChanged", function(self, value)
    content.scrollChild:SetPoint("TOPLEFT", 0, value)
  end)

  -- Enable mousewheel scrolling
  content.scrollFrame:EnableMouseWheel(true)
  content.scrollFrame:SetScript("OnMouseWheel", function(self, delta)
    local current = content.scrollBar:GetValue()
    local minVal, maxVal = content.scrollBar:GetMinMaxValues()
    local step = 30 -- Scroll speed (pixels per wheel tick)

    local newValue = current - (delta * step)
    newValue = math.max(minVal, math.min(maxVal, newValue))

    content.scrollBar:SetValue(newValue)
  end)

  -- Pairing rows (pooled)
  content.pairingRows = {}
end

function SocialUI:RefreshPairingsTab()
  if not self.pairingsContent or not self.pairingsContent:IsShown() then return end

  local db = HitTools.DB and HitTools.DB.social
  local players = getPlayerStore(db)
  if not db or not db.pairings or not players then return end

  local content = self.pairingsContent
  local filters = self.pairingsFilters or {search = "", timeWindow = 0}

  -- Get player key (GUID-first canonical ID when possible)
  local playerID
  if HitTools.SocialHeatmap and HitTools.SocialHeatmap.ResolveId then
    local guid = UnitGUID("player")
    local name, realm = UnitName("player")
    playerID = HitTools.SocialHeatmap.ResolveId(guid, name, realm)
  end

  -- Fallback to legacy name-realm key
  local playerName, playerRealm = UnitName("player")
  if not playerName then return end
  playerRealm = playerRealm or GetRealmName()
  local playerKey = playerID or (playerName .. "-" .. playerRealm)

  -- Build pairings list
  local pairings = {}
  local now = GetTime()

  if db.pairings[playerKey] then
    for otherKey, pairData in pairs(db.pairings[playerKey]) do
      local otherPlayer = players[otherKey]
      if otherPlayer then
        local include = true

        -- Search filter
        if filters.search ~= "" then
          if not otherPlayer.name:lower():find(filters.search, 1, true) then
            include = false
          end
        end

        -- Time window filter
        if filters.timeWindow > 0 then
          local cutoff = now - (filters.timeWindow * 86400)
          if not otherPlayer.lastSeen or otherPlayer.lastSeen < cutoff then
            include = false
          end
        end

        if include then
          pairings[#pairings + 1] = {
            otherKey = otherKey,
            otherPlayer = otherPlayer,
            pairData = pairData
          }
        end
      end
    end
  end

  -- Sort by runs descending
  table.sort(pairings, function(a, b)
    return (a.pairData.runsTogether or 0) > (b.pairData.runsTogether or 0)
  end)

  -- Clear existing rows
  for _, row in ipairs(content.pairingRows) do
    row:Hide()
  end

  -- ISSUE C FIX: Show empty state if no pairings
  if #pairings == 0 then
    if not content.emptyText then
      content.emptyText = content.scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
      content.emptyText:SetPoint("CENTER", content.scrollFrame, "CENTER")
      content.emptyText:SetText("No pairings recorded yet.\nRun dungeons with 2+ players to build synergy data.")
      content.emptyText:SetTextColor(0.6, 0.6, 0.6)
    end
    content.emptyText:Show()
    content.scrollChild:SetHeight(1)
    content.scrollBar:SetMinMaxValues(0, 0)
    return
  else
    if content.emptyText then
      content.emptyText:Hide()
    end
  end

  -- Create/show rows
  for i, pairing in ipairs(pairings) do
    local row = content.pairingRows[i]
    if not row then
      row = self:CreatePairingRow(content.scrollChild, i)
      content.pairingRows[i] = row
    end

    self:UpdatePairingRow(row, pairing)
    row:SetPoint("TOPLEFT", 4, -(i - 1) * 32)
    row:Show()
  end

  -- Update scroll child height
  local totalHeight = #pairings * 32
  content.scrollChild:SetHeight(math.max(totalHeight, 1))
  content.scrollBar:SetMinMaxValues(0, math.max(0, totalHeight - content.scrollFrame:GetHeight()))
end

function SocialUI:CreatePairingRow(parent, index)
  local row = CreateFrame("Button", nil, parent)
  row:SetSize(640, 30)

  row.bg = row:CreateTexture(nil, "BACKGROUND")
  row.bg:SetAllPoints()
  row.bg:SetTexture("Interface\\Buttons\\WHITE8x8")
  row.bg:SetVertexColor(0.1, 0.1, 0.1, index % 2 == 0 and 0.3 or 0.1)

  row.pairLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  row.pairLabel:SetPoint("LEFT", 4, 0)
  row.pairLabel:SetWidth(150)
  row.pairLabel:SetJustifyH("LEFT")

  row.runs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.runs:SetPoint("LEFT", row.pairLabel, "RIGHT", 4, 0)
  row.runs:SetWidth(40)

  row.completes = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.completes:SetPoint("LEFT", row.runs, "RIGHT", 4, 0)
  row.completes:SetWidth(70)

  row.wipes = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.wipes:SetPoint("LEFT", row.completes, "RIGHT", 4, 0)
  row.wipes:SetWidth(70)

  row.synergy = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.synergy:SetPoint("LEFT", row.wipes, "RIGHT", 4, 0)
  row.synergy:SetWidth(80)

  row:SetScript("OnEnter", function(self)
    self.bg:SetVertexColor(0.2, 0.3, 0.4, 0.5)
  end)

  row:SetScript("OnLeave", function(self)
    self.bg:SetVertexColor(0.1, 0.1, 0.1, index % 2 == 0 and 0.3 or 0.1)
  end)

  return row
end

function SocialUI:UpdatePairingRow(row, pairing)
  local otherPlayer = pairing.otherPlayer
  local pairData = pairing.pairData

  -- Pair label "You + Name" with class color
  local r, g, b = getClassColor(otherPlayer.class)
  row.pairLabel:SetText("You + " .. otherPlayer.name)
  row.pairLabel:SetTextColor(r, g, b)

  -- Runs
  row.runs:SetText(pairData.runsTogether or 0)

  -- Complete % and Wipes %
  local totalRuns = pairData.runsTogether or 0
  local completes = pairData.completes or 0
  local wipes = pairData.wipes or 0
  local completeRate = totalRuns > 0 and completes / totalRuns * 100 or 0
  local wipeRate = totalRuns > 0 and wipes / totalRuns * 100 or 0

  row.completes:SetText(string.format("%.0f%% complete", completeRate))
  row.wipes:SetText(string.format("%.0f%% wipes", wipeRate))

  -- Synergy label
  local synergyLabel = "Mixed"
  if completeRate >= 70 then
    synergyLabel = "Smooth"
    row.synergy:SetTextColor(0.3, 1, 0.3)
  elseif completeRate < 40 then
    synergyLabel = "Spicy"
    row.synergy:SetTextColor(1, 0.3, 0.3)
  else
    row.synergy:SetTextColor(1, 1, 0.3)
  end
  row.synergy:SetText(synergyLabel)
end

--[[═══════════════════════════════════════════════════════════════════════════
  RUNS TAB
═══════════════════════════════════════════════════════════════════════════════]]

function SocialUI:CreateRunsTab()
  local content = CreateFrame("Frame", nil, self.mainFrame.content)
  content:SetAllPoints()
  content:Hide()
  self.runsContent = content

  -- Filter bar
  content.filterBar = CreateFrame("Frame", nil, content)
  content.filterBar:SetPoint("TOPLEFT")
  content.filterBar:SetPoint("TOPRIGHT")
  content.filterBar:SetHeight(40)

  -- Time window dropdown
  local timeLabel = content.filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  timeLabel:SetPoint("TOPLEFT", 4, -2)
  timeLabel:SetText("Time:")

  content.timeDropdown = CreateDropdown(content.filterBar, 80, {
    {value = 0, text = "All"},
    {value = 7, text = "7 days"},
    {value = 30, text = "30 days"},
    {value = 90, text = "90 days"},
  }, function(value)
    SocialUI.runsFilters = SocialUI.runsFilters or {}
    SocialUI.runsFilters.timeWindow = value
    SocialUI:RefreshRunsTab()
  end)
  content.timeDropdown:SetPoint("TOPLEFT", 4, -20)

  -- Instance dropdown
  local instLabel = content.filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  instLabel:SetPoint("LEFT", timeLabel, "RIGHT", 90, 0)
  instLabel:SetText("Instance:")

  content.instanceDropdown = CreateDropdown(content.filterBar, 120, {
    {value = "ANY", text = "Any"},
  }, function(value)
    SocialUI.runsFilters = SocialUI.runsFilters or {}
    SocialUI.runsFilters.instance = value
    SocialUI:RefreshRunsTab()
  end)
  content.instanceDropdown:SetPoint("LEFT", content.timeDropdown, "RIGHT", 8, 0)

  -- Outcome dropdown
  local outcomeLabel = content.filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  outcomeLabel:SetPoint("LEFT", instLabel, "RIGHT", 130, 0)
  outcomeLabel:SetText("Outcome:")

  content.outcomeDropdown = CreateDropdown(content.filterBar, 100, {
    {value = "ANY", text = "Any"},
    {value = "COMPLETE", text = "Complete"},
    {value = "WIPE", text = "Not Complete"},
  }, function(value)
    SocialUI.runsFilters = SocialUI.runsFilters or {}
    SocialUI.runsFilters.outcome = value
    SocialUI:RefreshRunsTab()
  end)
  content.outcomeDropdown:SetPoint("LEFT", content.instanceDropdown, "RIGHT", 8, 0)

  -- Scroll frame
  content.scrollFrame = CreateFrame("ScrollFrame", nil, content)
  content.scrollFrame:SetPoint("TOPLEFT", content.filterBar, "BOTTOMLEFT", 0, -8)
  content.scrollFrame:SetPoint("BOTTOMRIGHT", -24, 0)

  content.scrollChild = CreateFrame("Frame", nil, content.scrollFrame)
  content.scrollFrame:SetScrollChild(content.scrollChild)
  content.scrollChild:SetSize(650, 1)

  -- Scroll bar
  content.scrollBar = CreateFrame("Slider", nil, content.scrollFrame)
  content.scrollBar:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, -48)
  content.scrollBar:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -4, 4)
  content.scrollBar:SetWidth(16)
  content.scrollBar:SetOrientation("VERTICAL")
  content.scrollBar:SetMinMaxValues(0, 100)
  content.scrollBar:SetValue(0)
  content.scrollBar:SetValueStep(20)

  if content.scrollBar.SetBackdrop then
    content.scrollBar:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8x8",
      edgeFile = "Interface\\Buttons\\WHITE8x8",
      tile = false,
      edgeSize = 1,
    })
    content.scrollBar:SetBackdropColor(0.1, 0.1, 0.1, 0.5)
    content.scrollBar:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)
  end

  content.scrollBar.thumb = content.scrollBar:CreateTexture(nil, "OVERLAY")
  content.scrollBar.thumb:SetSize(14, 24)
  content.scrollBar.thumb:SetTexture("Interface\\Buttons\\WHITE8x8")
  content.scrollBar.thumb:SetVertexColor(0.4, 0.4, 0.4, 0.8)
  content.scrollBar:SetThumbTexture(content.scrollBar.thumb)

  content.scrollBar:SetScript("OnValueChanged", function(self, value)
    content.scrollChild:SetPoint("TOPLEFT", 0, value)
  end)

  -- Enable mousewheel scrolling
  content.scrollFrame:EnableMouseWheel(true)
  content.scrollFrame:SetScript("OnMouseWheel", function(self, delta)
    local current = content.scrollBar:GetValue()
    local minVal, maxVal = content.scrollBar:GetMinMaxValues()
    local step = 30 -- Scroll speed (pixels per wheel tick)

    local newValue = current - (delta * step)
    newValue = math.max(minVal, math.min(maxVal, newValue))

    content.scrollBar:SetValue(newValue)
  end)

  -- Run rows (pooled)
  content.runRows = {}
end

local function hashRosterForDisplay(roster)
  if type(roster) ~= "table" then
    return "0"
  end
  local ids = {}
  for _, id in ipairs(roster) do
    ids[#ids + 1] = tostring(id)
  end
  table.sort(ids)
  local text = table.concat(ids, "|")
  local hash = 5381
  for i = 1, #text do
    hash = (hash * 33 + string.byte(text, i)) % 2147483647
  end
  return tostring(hash)
end

local function getRunDisplayKey(runId, runData)
  if runData and runData.runKey then
    return tostring(runData.runKey)
  end
  local instanceID = runData and runData.instanceID or 0
  local bucket = math.floor((runData and runData.timestampStart or 0) / 60)
  local rosterHash = hashRosterForDisplay(runData and runData.roster)
  return string.format("%s:%d:%s", tostring(instanceID), bucket, rosterHash)
end

local function mergeRunForDisplay(dst, src)
  dst.timestampStart = math.min(dst.timestampStart or src.timestampStart or 0, src.timestampStart or 0)
  dst.timestampEnd = math.max(dst.timestampEnd or src.timestampEnd or 0, src.timestampEnd or 0)
  dst.duration = math.max(dst.duration or 0, src.duration or 0)
  dst.complete = (dst.complete or false) or (src.complete or false)
  dst.wipeCount = math.max(dst.wipeCount or 0, src.wipeCount or 0)
  dst.totalDeaths = math.max(dst.totalDeaths or 0, src.totalDeaths or 0)
  dst.groupSize = math.max(dst.groupSize or 0, src.groupSize or 0)
  dst.instanceName = dst.instanceName or src.instanceName
  dst.instanceID = dst.instanceID or src.instanceID
  dst.runKey = dst.runKey or src.runKey
end

function SocialUI:RefreshRunsTab()
  if not self.runsContent or not self.runsContent:IsShown() then return end

  local db = HitTools.DB and HitTools.DB.social
  if not db or not db.runs then return end

  local content = self.runsContent
  local filters = self.runsFilters or {timeWindow = 0, instance = "ANY", outcome = "ANY"}

  -- Build runs list (deduped by runKey/fallback key)
  local runs = {}
  local mergedByKey = {}
  local now = GetTime()

  for runId, run in pairs(db.runs) do
    local displayKey = getRunDisplayKey(runId, run)
    local merged = mergedByKey[displayKey]
    if not merged then
      merged = {
        id = runId,
        data = {
          timestampStart = run.timestampStart,
          timestampEnd = run.timestampEnd,
          duration = run.duration,
          instanceName = run.instanceName,
          instanceID = run.instanceID,
          difficulty = run.difficulty,
          groupSize = run.groupSize,
          roster = run.roster,
          complete = run.complete,
          wipeCount = run.wipeCount,
          totalDeaths = run.totalDeaths,
          runKey = run.runKey,
        }
      }
      mergedByKey[displayKey] = merged
      runs[#runs + 1] = merged
    else
      mergeRunForDisplay(merged.data, run)
    end
  end

  -- Apply filters
  local filtered = {}
  for _, entry in ipairs(runs) do
    local run = entry.data
    local include = true
    -- Time window filter
    if filters.timeWindow > 0 then
      local cutoff = now - (filters.timeWindow * 86400)
      if not run.timestampStart or run.timestampStart < cutoff then
        include = false
      end
    end

    -- Instance filter
    if filters.instance ~= "ANY" then
      if not run.instanceID or run.instanceID ~= filters.instance then
        include = false
      end
    end

    -- Outcome filter
    if filters.outcome == "COMPLETE" then
      if not run.complete then include = false end
    elseif filters.outcome == "WIPE" then
      if run.complete then include = false end
    end

    if include then
      filtered[#filtered + 1] = entry
    end
  end

  -- Sort by timestamp descending (newest first)
  table.sort(filtered, function(a, b)
    return (a.data.timestampStart or 0) > (b.data.timestampStart or 0)
  end)

  -- Clear existing rows
  for _, row in ipairs(content.runRows) do
    row:Hide()
  end

  -- ISSUE C FIX: Show empty state if no runs
  if #filtered == 0 then
    if not content.emptyText then
      content.emptyText = content.scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
      content.emptyText:SetPoint("CENTER", content.scrollFrame, "CENTER")
      content.emptyText:SetText("No runs recorded yet.\nComplete a dungeon with 2+ players to see run history.")
      content.emptyText:SetTextColor(0.6, 0.6, 0.6)
    end
    content.emptyText:Show()
    content.scrollChild:SetHeight(1)
    content.scrollBar:SetMinMaxValues(0, 0)
    return
  else
    if content.emptyText then
      content.emptyText:Hide()
    end
  end

  -- Create/show rows
  for i, run in ipairs(filtered) do
    local row = content.runRows[i]
    if not row then
      row = self:CreateRunRow(content.scrollChild, i)
      content.runRows[i] = row
    end

    self:UpdateRunRow(row, run)
    row:SetPoint("TOPLEFT", 4, -(i - 1) * 32)
    row:Show()
  end

  -- Update scroll child height
  local totalHeight = #filtered * 32
  content.scrollChild:SetHeight(math.max(totalHeight, 1))
  content.scrollBar:SetMinMaxValues(0, math.max(0, totalHeight - content.scrollFrame:GetHeight()))

  -- Refresh instance dropdown
  self:RefreshRunsInstanceDropdown()
end

function SocialUI:RefreshRunsInstanceDropdown()
  if not self.runsContent or not self.runsContent.instanceDropdown then return end

  local db = HitTools.DB and HitTools.DB.social
  if not db or not db.runs then return end

  -- Collect unique instances
  local instances = {}
  local instanceSet = {}

  for _, run in pairs(db.runs) do
    if run.instanceName and run.instanceID and not instanceSet[run.instanceID] then
      instanceSet[run.instanceID] = true
      instances[#instances + 1] = {
        id = run.instanceID,
        name = run.instanceName
      }
    end
  end

  -- Sort alphabetically
  table.sort(instances, function(a, b) return a.name < b.name end)

  -- Build dropdown options
  local options = {{value = "ANY", text = "Any"}}
  for _, inst in ipairs(instances) do
    options[#options + 1] = {value = inst.id, text = inst.name}
  end

  -- Update dropdown options (same pattern as dungeon dropdown)
  local dropdown = self.runsContent.instanceDropdown
  dropdown.options = options

  if dropdown.menu then
    for _, item in ipairs(dropdown.menuItems or {}) do
      item:Hide()
    end
  end

  dropdown.menuItems = {}
  dropdown.menu:SetHeight(#options * 20)

  for i, option in ipairs(options) do
    local item = CreateFrame("Button", nil, dropdown.menu)
    item:SetSize(dropdown:GetWidth() - 8, 18)
    item:SetPoint("TOPLEFT", 4, -(i - 1) * 20 - 4)

    item.bg = item:CreateTexture(nil, "BACKGROUND")
    item.bg:SetAllPoints()
    item.bg:SetTexture("Interface\\Buttons\\WHITE8x8")
    item.bg:SetVertexColor(0, 0, 0, 0)

    item.text = item:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
    item.text:SetPoint("LEFT", 4, 0)
    item.text:SetText(option.text)
    item.text:SetTextColor(1, 1, 1)

    item:SetScript("OnEnter", function(self)
      self.bg:SetVertexColor(0.3, 0.5, 0.7, 0.5)
    end)

    item:SetScript("OnLeave", function(self)
      self.bg:SetVertexColor(0, 0, 0, 0)
    end)

    item:SetScript("OnClick", function(self)
      dropdown.currentValue = option.value
      dropdown.text:SetText(option.text)
      dropdown.menu:Hide()
      if dropdown.onSelect then
        dropdown.onSelect(option.value)
      end
    end)

    dropdown.menuItems[i] = item
  end
end

function SocialUI:CreateRunRow(parent, index)
  local row = CreateFrame("Button", nil, parent)
  row:SetSize(640, 30)

  row.bg = row:CreateTexture(nil, "BACKGROUND")
  row.bg:SetAllPoints()
  row.bg:SetTexture("Interface\\Buttons\\WHITE8x8")
  row.bg:SetVertexColor(0.1, 0.1, 0.1, index % 2 == 0 and 0.3 or 0.1)

  row.date = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.date:SetPoint("LEFT", 4, 0)
  row.date:SetWidth(80)
  row.date:SetJustifyH("LEFT")

  row.instance = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  row.instance:SetPoint("LEFT", row.date, "RIGHT", 4, 0)
  row.instance:SetWidth(120)
  row.instance:SetJustifyH("LEFT")

  row.duration = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.duration:SetPoint("LEFT", row.instance, "RIGHT", 4, 0)
  row.duration:SetWidth(50)

  row.outcome = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.outcome:SetPoint("LEFT", row.duration, "RIGHT", 4, 0)
  row.outcome:SetWidth(70)

  row.wipes = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.wipes:SetPoint("LEFT", row.outcome, "RIGHT", 4, 0)
  row.wipes:SetWidth(50)

  row.deaths = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.deaths:SetPoint("LEFT", row.wipes, "RIGHT", 4, 0)
  row.deaths:SetWidth(50)

  row.size = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.size:SetPoint("LEFT", row.deaths, "RIGHT", 4, 0)
  row.size:SetWidth(40)

  row:SetScript("OnEnter", function(self)
    self.bg:SetVertexColor(0.2, 0.3, 0.4, 0.5)
  end)

  row:SetScript("OnLeave", function(self)
    self.bg:SetVertexColor(0.1, 0.1, 0.1, index % 2 == 0 and 0.3 or 0.1)
  end)

  return row
end

function SocialUI:UpdateRunRow(row, run)
  local runData = run.data

  -- Date
  row.date:SetText(date("%m/%d %H:%M", runData.timestampStart or 0))

  -- Instance
  row.instance:SetText(runData.instanceName or "Unknown")

  -- Duration
  local duration = (runData.duration or 0) / 60
  row.duration:SetText(string.format("%dm", math.floor(duration)))

  -- Outcome
  if runData.complete then
    row.outcome:SetText("Complete")
    row.outcome:SetTextColor(0.3, 1, 0.3)
  else
    row.outcome:SetText("Incomplete")
    row.outcome:SetTextColor(1, 0.6, 0.3)
  end

  -- Wipes
  row.wipes:SetText(string.format("%d wipes", runData.wipeCount or 0))

  -- Deaths
  row.deaths:SetText(string.format("%d deaths", runData.totalDeaths or 0))

  -- Group size
  row.size:SetText(string.format("%d-man", runData.groupSize or 0))
end

--[[═══════════════════════════════════════════════════════════════════════════
  SETTINGS TAB
═══════════════════════════════════════════════════════════════════════════════]]

-- StaticPopup for Reset confirmation
StaticPopupDialogs["HITSOCIAL_RESET_ALL"] = {
  text = "Type RESET to confirm wiping all Social Heatmap data:",
  button1 = "Confirm",
  button2 = "Cancel",
  hasEditBox = true,
  maxLetters = 10,
  OnAccept = function(self)
    local text = self.editBox:GetText()
    if text == "RESET" then
      local db = HitTools.DB and HitTools.DB.social
      if db then
        db.playersById = {}
        db.players = nil
        db.aliases = db.aliases or {}
        db.nameIndex = db.nameIndex or {}
        wipe(db.aliases)
        wipe(db.nameIndex)
        db.runs = {}
        db.pairings = {}
        HitTools:Print("All Social Heatmap data has been reset")
        if HitTools.SocialUI then
          HitTools.SocialUI:InvalidateFilterCache()
          HitTools.SocialUI:RefreshPlayersTab()
        end
      end
    else
      HitTools:Print("Reset cancelled - you must type exactly 'RESET'")
    end
  end,
  OnShow = function(self)
    self.editBox:SetFocus()
  end,
  OnHide = function(self)
    self.editBox:SetText("")
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
}

function SocialUI:CreateSettingsTab()
  local content = CreateFrame("Frame", nil, self.mainFrame.content)
  content:SetAllPoints()
  content:Hide()
  self.settingsContent = content

  local yOffset = -20

  -- Section 1: Enable/Disable
  local enableHeader = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  enableHeader:SetPoint("TOPLEFT", 20, yOffset)
  enableHeader:SetText("Tracking")
  yOffset = yOffset - 30

  content.enableCheck = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
  content.enableCheck:SetPoint("TOPLEFT", 20, yOffset)
  content.enableCheck:SetScript("OnClick", function(self)
    local db = HitTools.DB and HitTools.DB.social
    if db then
      db.enabled = self:GetChecked()
      HitTools:Print("Social Heatmap tracking " .. (db.enabled and "ENABLED" or "DISABLED"))
    end
  end)

  local enableLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  enableLabel:SetPoint("LEFT", content.enableCheck, "RIGHT", 2, 0)
  enableLabel:SetText("Enable Social Heatmap tracking")
  yOffset = yOffset - 50

  -- Section 2: Privacy & Sentiment
  local privacyHeader = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  privacyHeader:SetPoint("TOPLEFT", 20, yOffset)
  privacyHeader:SetText("Privacy & Sentiment")
  yOffset = yOffset - 30

  content.sentimentCheck = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
  content.sentimentCheck:SetPoint("TOPLEFT", 20, yOffset)
  content.sentimentCheck:SetScript("OnClick", function(self)
    local db = HitTools.DB and HitTools.DB.social
    if db then
      db.sentimentEnabled = self:GetChecked()
      HitTools:Print("Sentiment tracking " .. (db.sentimentEnabled and "ENABLED" or "DISABLED"))
    end
  end)

  local sentimentLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  sentimentLabel:SetPoint("LEFT", content.sentimentCheck, "RIGHT", 2, 0)
  sentimentLabel:SetText("Enable sentiment tracking (chat keywords)")
  yOffset = yOffset - 25

  local privacyNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  privacyNote:SetPoint("TOPLEFT", 40, yOffset)
  privacyNote:SetWidth(600)
  privacyNote:SetJustifyH("LEFT")
  privacyNote:SetTextColor(0.7, 0.7, 0.7)
  privacyNote:SetText("Privacy note: Sentiment analysis tracks positive/negative keywords in chat. All data is stored locally.")
  yOffset = yOffset - 60

  -- Section 3: Data Management
  local dataHeader = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  dataHeader:SetPoint("TOPLEFT", 20, yOffset)
  dataHeader:SetText("Data Management")
  yOffset = yOffset - 30

  -- Reset button
  local resetBtn = CreateFrame("Button", nil, content)
  resetBtn:SetSize(150, 28)
  resetBtn:SetPoint("TOPLEFT", 20, yOffset)
  resetBtn:SetNormalFontObject("GameFontNormal")
  resetBtn:SetText("Reset All Data")

  resetBtn.bg = resetBtn:CreateTexture(nil, "BACKGROUND")
  resetBtn.bg:SetAllPoints()
  resetBtn.bg:SetTexture("Interface\\Buttons\\WHITE8x8")
  resetBtn.bg:SetVertexColor(0.7, 0.2, 0.2, 0.8)

  resetBtn:SetScript("OnClick", function()
    StaticPopup_Show("HITSOCIAL_RESET_ALL")
  end)

  resetBtn:SetScript("OnEnter", function(self)
    self.bg:SetVertexColor(0.9, 0.3, 0.3, 1.0)
  end)

  resetBtn:SetScript("OnLeave", function(self)
    self.bg:SetVertexColor(0.7, 0.2, 0.2, 0.8)
  end)

  local resetNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  resetNote:SetPoint("LEFT", resetBtn, "RIGHT", 10, 0)
  resetNote:SetTextColor(0.7, 0.7, 0.7)
  resetNote:SetText("Wipes all players, runs, and pairings data")
  yOffset = yOffset - 50

  -- Section 4: Debug
  local debugHeader = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  debugHeader:SetPoint("TOPLEFT", 20, yOffset)
  debugHeader:SetText("Debug")
  yOffset = yOffset - 30

  content.debugCheck = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
  content.debugCheck:SetPoint("TOPLEFT", 20, yOffset)
  content.debugCheck:SetScript("OnClick", function(self)
    local db = HitTools.DB and HitTools.DB.social
    if db then
      db.showDebug = self:GetChecked()
      HitTools:Print("Debug mode " .. (db.showDebug and "ENABLED" or "DISABLED"))
    end
  end)

  local debugLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  debugLabel:SetPoint("LEFT", content.debugCheck, "RIGHT", 2, 0)
  debugLabel:SetText("Show performance counters")
  yOffset = yOffset - 40

  -- Info text at bottom
  local infoText = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  infoText:SetPoint("BOTTOMLEFT", 20, 20)
  infoText:SetWidth(640)
  infoText:SetJustifyH("LEFT")
  infoText:SetTextColor(0.5, 0.7, 0.9)
  infoText:SetText("Hit-Tools Social Heatmap - Track your dungeon companions and synergy\nAll data is stored locally in your SavedVariables")
end

function SocialUI:RefreshSettingsTab()
  if not self.settingsContent or not self.settingsContent:IsShown() then return end

  local db = HitTools.DB and HitTools.DB.social
  if not db then return end

  local content = self.settingsContent

  -- Sync checkboxes with DB values
  if content.enableCheck then
    content.enableCheck:SetChecked(db.enabled ~= false)  -- Default true
  end

  if content.sentimentCheck then
    content.sentimentCheck:SetChecked(db.sentimentEnabled == true)  -- Default false
  end

  if content.debugCheck then
    content.debugCheck:SetChecked(db.showDebug == true)  -- Default false
  end
end

--[[═══════════════════════════════════════════════════════════════════════════
  SHOW/HIDE/TOGGLE
═══════════════════════════════════════════════════════════════════════════════]]

function SocialUI:Show()
  if not self.mainFrame then
    local ok, err = pcall(function()
      self:Initialize()
    end)
    if not ok then
      print("[SocialUI] FATAL: Initialize() failed!")
      print("[SocialUI] Error: " .. tostring(err))
      return
    end
  end

  if not self.mainFrame then
    print("[SocialUI] FATAL: mainFrame is nil after Initialize()")
    return
  end

  self.mainFrame:Show()
  self:SelectTab(TAB_PLAYERS)
end

function SocialUI:Hide()
  if self.mainFrame then
    self.mainFrame:Hide()
  end
end

function SocialUI:Toggle()
  if self.mainFrame and self.mainFrame:IsShown() then
    self:Hide()
  else
    self:Show()
  end
end

--[[═══════════════════════════════════════════════════════════════════════════
  OnRunEnded - ISSUE C FIX: Refresh UI when runs finish
═══════════════════════════════════════════════════════════════════════════════]]

function SocialUI:OnRunStarted()
  self:OnSocialDBUpdated("SOCIAL_DB_UPDATED", "run_started")
end

function SocialUI:OnRunEnded()
  self:OnSocialDBUpdated("SOCIAL_DB_UPDATED", "run_ended")
end

function SocialUI:OnSocialDBUpdated(eventName, reason)
  if not self.mainFrame or not self.mainFrame:IsShown() then
    return  -- UI not visible, no refresh needed
  end

  -- Throttle refreshes to prevent spam
  local now = GetTime()
  if now - lastUIRefreshTime < UI_REFRESH_THROTTLE then
    return
  end
  lastUIRefreshTime = now

  -- CRITICAL: Invalidate filter cache so new players/runs show up
  self:InvalidateFilterCache()

  -- Refresh current tab (or both key tabs when visible transitions happen)
  if self.currentTab == TAB_PLAYERS then
    self:RefreshPlayersTab()
  elseif self.currentTab == TAB_PAIRINGS then
    self:RefreshPairingsTab()
  elseif self.currentTab == TAB_RUNS then
    self:RefreshRunsTab()
  end
end

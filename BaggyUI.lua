--[[
═══════════════════════════════════════════════════════════════════════════════
  BAGGY UI - Frame rendering, animations, rainbow effects
═══════════════════════════════════════════════════════════════════════════════]]

local _, HitTools = ...

HitTools.BaggyUI = HitTools.BaggyUI or {}
local BaggyUI = HitTools.BaggyUI

-- Constants
local ICON_SIZE = 32
local ICON_SIZE_COMPACT = 28
local ICONS_PER_ROW = 10
local ICON_SPACING = 2
local SEARCH_DEBOUNCE = 0.15
local LAYOUT_RETRY_DELAY = 0.25
local NUM_CONTAINER_FRAMES = NUM_CONTAINER_FRAMES or 13  -- TBC default

-- Layout constants (Classic-style tight layout)
local FRAME_PADDING = 6
local HEADER_HEIGHT = 22
local TOPBAR_HEIGHT = 22
local TOPBAR_SPACING = 4
local BANK_SECTION_GAP = 12

-- Quality colors (TBC)
local QUALITY_COLORS = {
  [0] = {0.6, 0.6, 0.6},  -- Poor (gray)
  [1] = {1.0, 1.0, 1.0},  -- Common (white)
  [2] = {0.12, 1.0, 0},   -- Uncommon (green)
  [3] = {0, 0.44, 0.87},  -- Rare (blue)
  [4] = {0.64, 0.21, 0.93}, -- Epic (purple)
  [5] = {1.0, 0.5, 0},    -- Legendary (orange)
}

-- Debug infrastructure (matches Baggy.lua)
local DEBUG_ENABLED = false
local lastDebugTime = {}

local function DebugPrint(...)
  if DEBUG_ENABLED then
    print("|cff00ff00[BaggyUI]|r", ...)
  end
end

-- Rate-limited debug (max once per 0.5s per key)
local function DebugLog(key, ...)
  if not DEBUG_ENABLED then return end
  local now = GetTime()
  if not lastDebugTime[key] or (now - lastDebugTime[key]) > 0.5 then
    lastDebugTime[key] = now
    print("|cff00ff00[BaggyUI:" .. key .. "]|r", ...)
  end
end

-- Sync debug state with Baggy module
function BaggyUI:SyncDebugState()
  -- This will be called from Baggy when debug is toggled
  if HitTools.Baggy and HitTools.Baggy._debugEnabled ~= nil then
    DEBUG_ENABLED = HitTools.Baggy._debugEnabled
  end
end

-- Initialize debug state on load
if HitTools.Baggy and HitTools.Baggy._debugEnabled then
  DEBUG_ENABLED = HitTools.Baggy._debugEnabled
end

local function IsFrameShown(name)
  local frame = _G[name]
  return frame and frame.IsShown and frame:IsShown() or false
end

local function IsBankBagID(bagID)
  return bagID == -1 or (bagID and bagID >= 5 and bagID <= 11)
end

--[[═══════════════════════════════════════════════════════════════════════════
  BLIZZARD BUTTON HIJACKING - The Key to Secure Right-Click!
═══════════════════════════════════════════════════════════════════════════════]]

-- Ensure Blizzard container frames exist by forcing them to update
function BaggyUI:EnsureBlizzardFramesExist()
  -- Open all bags briefly to ensure container frames are created
  -- This is safe - we'll hide them immediately after
  if not InCombatLockdown() then
    -- Open backpack and bags
    for bagID = 0, 4 do
      if OpenBag then
        pcall(OpenBag, bagID)
      end
    end

    -- If bank is open, ensure bank container buttons exist too.
    if IsFrameShown("BankFrame") then
      if OpenBag then
        pcall(OpenBag, -1) -- Bank main container
      end
      for bagID = 5, 11 do
        if OpenBag then
          pcall(OpenBag, bagID)
        end
      end
    end

    -- Note: We no longer call ContainerFrame_Update here because it can cause
    -- tooltip errors when buttons have been reparented. The buttons will be
    -- updated individually during HijackAndLayoutButtons instead.
  end
end

-- Collect all Blizzard container item buttons
-- Returns: table of {button=frame, bagID=num, slot=num, itemLink=string}
function BaggyUI:CollectBlizzardItemButtons()
  local buttons = {}

  -- Iterate through all container frames
  for i = 1, NUM_CONTAINER_FRAMES do
    local frameName = "ContainerFrame" .. i
    local containerFrame = _G[frameName]

    if containerFrame then
      local bagID = containerFrame:GetID()

      -- Get number of slots in this bag
      local GetNumSlots = GetContainerNumSlots or (C_Container and C_Container.GetContainerNumSlots)
      local numSlots = GetNumSlots and GetNumSlots(bagID) or 0

      -- Collect item buttons from this container
      for slot = 1, numSlots do
        local buttonName = frameName .. "Item" .. slot
        local button = _G[buttonName]

        if button then
          if not button._baggyOriginalParent then
            button._baggyOriginalParent = button:GetParent()
          end

          -- Get item info
          local GetItemLink = GetContainerItemLink or (C_Container and C_Container.GetContainerItemLink)
          local itemLink = GetItemLink and GetItemLink(bagID, slot)

          table.insert(buttons, {
            button = button,
            bagID = bagID,
            slot = slot,
            itemLink = itemLink,
            originalParent = button._baggyOriginalParent,
          })
        end
      end
    end
  end

  DebugPrint("Collected " .. #buttons .. " Blizzard item buttons")
  return buttons
end

--[[═══════════════════════════════════════════════════════════════════════════
  INITIALIZATION
═══════════════════════════════════════════════════════════════════════════════]]

function BaggyUI:Initialize()
  if self.frame then return end

  DebugPrint("Creating Baggy UI...")

  self:CreateMainFrame()
  self:CreateTopBar()
  self:CreateItemGrid()
  self:CreateRainbowBorder()
  self:RegisterEvents()

  -- Restore position (size will be auto-calculated on first Refresh)
  local db = HitTools.DB.baggy.position
  self.frame:ClearAllPoints()
  self.frame:SetPoint(db.point, UIParent, db.relativePoint, db.x, db.y)

  DebugPrint("UI created successfully")
end

--[[═══════════════════════════════════════════════════════════════════════════
  EVENT HANDLING
═══════════════════════════════════════════════════════════════════════════════]]

function BaggyUI:GetContextState()
  return {
    merchant = IsFrameShown("MerchantFrame"),
    auctionHouse = IsFrameShown("AuctionHouseFrame") or IsFrameShown("AuctionFrame"),
    bank = IsFrameShown("BankFrame"),
    mail = IsFrameShown("MailFrame") or IsFrameShown("OpenMailFrame"),
    trade = IsFrameShown("TradeFrame"),
  }
end

function BaggyUI:EnsureBagParent(bagID)
  if not self.frame or not self.frame.scrollChild then
    return nil
  end

  self.frame.bagParents = self.frame.bagParents or {}
  local parent = self.frame.bagParents[bagID]
  if parent then
    return parent
  end

  parent = CreateFrame("Frame", nil, self.frame.scrollChild)
  parent:SetID(bagID)
  parent:SetAllPoints()
  self.frame.bagParents[bagID] = parent
  return parent
end

function BaggyUI:IsUnsafeLayoutContext(reason)
  local context = self:GetContextState()

  -- Merchant/AH should keep updating live so sold/posted items disappear immediately.
  -- Keep mail/trade deferred because these contexts are more sensitive to layout churn.
  if context.mail or context.trade then
    return true
  end

  -- Allow an initial bank-open render, but defer churn while bank UI is active.
  if context.bank and reason ~= "show" and reason ~= "bank_opened" then
    return true
  end

  return false
end

function BaggyUI:ScheduleDeferredLayout(reason, delay)
  self._rebuildDeferred = true
  self._deferredReason = reason or self._deferredReason or "unknown"

  if self._layoutRetryActive then
    return
  end

  self._layoutRetryActive = true
  C_Timer.After(delay or LAYOUT_RETRY_DELAY, function()
    self._layoutRetryActive = false
    if self.layoutPending and self.frame and self.frame:IsShown() then
      self:RequestLayout("deferred_retry")
    end
  end)
end

function BaggyUI:GetAllKnownContainerButtons()
  local known = {}
  if not self.frame then
    return known
  end

  -- Prefer currently collected bag buttons (real bag/slot mapping).
  local collected = self:CollectBlizzardItemButtons()
  for _, btnData in ipairs(collected) do
    local button = btnData.button
    if button and not known[button] then
      known[button] = {
        button = button,
        originalParent = btnData.originalParent,
      }
    end
  end

  -- Also include currently tracked hijacked buttons for safety.
  for _, btnData in ipairs(self.frame.hijackedButtons or {}) do
    local button = btnData.button
    if button and not known[button] then
      known[button] = {
        button = button,
        originalParent = btnData.originalParent or button._baggyOriginalParent,
      }
    end
  end

  return known
end

function BaggyUI:ReleaseHijackedButtons(reason)
  if not self.frame then
    return false
  end
  if InCombatLockdown() then
    self.layoutPending = true
    self.frame.layoutDirty = true
    return false
  end

  local iconSize = HitTools.DB.baggy.compactMode and ICON_SIZE_COMPACT or ICON_SIZE
  local released = 0
  local knownButtons = self:GetAllKnownContainerButtons()
  local bagParents = self.frame.bagParents or {}

  for _, btnData in pairs(knownButtons) do
    local button = btnData.button
    if button then
      local parent = button:GetParent()
      local isBagParent = false
      for _, bagParent in pairs(bagParents) do
        if parent == bagParent then
          isBagParent = true
          break
        end
      end
      local wasManaged = button._baggyManaged
        or parent == self.frame.scrollChild
        or parent == self.frame
        or isBagParent

      if wasManaged then
        local originalParent = btnData.originalParent or button._baggyOriginalParent
        if originalParent then
          button:SetParent(originalParent)
        end
        self:ResetButtonForLayout(button, iconSize)
        button:Hide()
        button:EnableMouse(false)
        button._baggyManaged = nil
        if button._baggySlotLabel then
          button._baggySlotLabel:Hide()
        end
        released = released + 1
      end
    end
  end

  self.frame.hijackedButtons = {}
  self.visibleSlotMap = {}
  self.displaySlots = {}
  self._contextSuspended = true
  self._waitingForSafeContext = true
  if self.frame.bankDividerLine then
    self.frame.bankDividerLine:Hide()
  end
  if self.frame.bankDividerLabel then
    self.frame.bankDividerLabel:Hide()
  end
  DebugLog("Layout", "Released hijacked buttons (" .. tostring(reason or "unknown") .. ", " .. tostring(released) .. ")")
  return released > 0
end

function BaggyUI:RequestLayout(reason)
  reason = reason or "unknown"
  self.layoutPending = true

  if self.frame then
    self.frame.layoutDirty = true
  end

  self._layoutRequestToken = (self._layoutRequestToken or 0) + 1

  if not self.frame or not self.frame:IsShown() then
    return false
  end

  if InCombatLockdown() then
    DebugLog("Layout", "Deferred in combat (" .. reason .. ")")
    self._rebuildDeferred = true
    self._deferredReason = "combat_" .. reason
    return false
  end

  if CursorHasItem() then
    DebugLog("Layout", "Deferred (cursor item) (" .. reason .. ")")
    self:ScheduleDeferredLayout("cursor_" .. reason, LAYOUT_RETRY_DELAY)
    return false
  end

  if self:IsUnsafeLayoutContext(reason) then
    local hasHijacked = self.frame
      and self.frame.hijackedButtons
      and #self.frame.hijackedButtons > 0

    -- If opened directly in vendor/mail/AH/trade, wait a beat before a
    -- one-time bootstrap so Blizzard bag open/position updates can settle.
    if not hasHijacked and not self._unsafeBootstrapDone then
      if not self._unsafeBootstrapArmed then
        self._unsafeBootstrapArmed = true
        self._waitingForSafeContext = true
        DebugLog("Layout", "Deferred initial transaction bootstrap (" .. reason .. ")")
        self:ScheduleDeferredLayout("context_bootstrap_" .. reason, 0.2)
        return false
      end

      if reason == "deferred_retry" then
        self._unsafeBootstrapArmed = false
        DebugLog("Layout", "Running delayed transaction bootstrap")
        local bootstrapped = self:LayoutNow("unsafe_bootstrap")
        if bootstrapped then
          self._unsafeBootstrapDone = true
        end
        return bootstrapped
      end
    end

    self._waitingForSafeContext = true
    DebugLog("Layout", "Deferred (transaction context) (" .. reason .. ")")
    -- Avoid rapid retry churn while transaction UIs are open; rely on close events,
    -- with a slow probe as a fallback in case a close event is missed.
    self._unsafeBootstrapArmed = false
    self:ScheduleDeferredLayout("context_" .. reason, 1.5)
    return false
  end

  self._unsafeBootstrapDone = false
  self._unsafeBootstrapArmed = false
  self._waitingForSafeContext = false
  return self:LayoutNow(reason)
end

function BaggyUI:RegisterEvents()
  if not self.eventFrame then
    self.eventFrame = CreateFrame("Frame")
  end

  local events = {
    "PLAYER_REGEN_ENABLED",
    "BAG_UPDATE_DELAYED",
    "MERCHANT_SHOW",
    "MERCHANT_CLOSED",
    "AUCTION_HOUSE_SHOW",
    "AUCTION_HOUSE_CLOSED",
    "MAIL_SHOW",
    "MAIL_CLOSED",
    "BANKFRAME_OPENED",
    "BANKFRAME_CLOSED",
    "TRADE_SHOW",
    "TRADE_CLOSED",
  }
  for _, eventName in ipairs(events) do
    pcall(self.eventFrame.RegisterEvent, self.eventFrame, eventName)
  end

  self.eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_REGEN_ENABLED" then
      if self.layoutPending and self.frame and self.frame:IsShown() then
        self:RequestLayout("regen_enabled")
      end
    elseif event == "BAG_UPDATE_DELAYED" then
      if self.frame and self.frame:IsShown() then
        self:RequestLayout("bag_update")
      end
    elseif event == "MERCHANT_SHOW"
      or event == "AUCTION_HOUSE_SHOW" then
      if self.frame and self.frame:IsShown() then
        -- Ensure we are not stuck in deferred mode from a prior unsafe context.
        self._unsafeBootstrapDone = false
        self._unsafeBootstrapArmed = false
        self._waitingForSafeContext = false
        self:RequestLayout(event:lower())
      end
    elseif event == "MAIL_SHOW"
      or event == "TRADE_SHOW" then
      if self.frame and self.frame:IsShown() then
        self._waitingForSafeContext = true
        self.layoutPending = true
        self.frame.layoutDirty = true
        -- Let close events drive the refresh; keep current visual state stable.
      end
    elseif event == "BANKFRAME_OPENED" then
      if self.frame and self.frame:IsShown() then
        -- Bank bags are part of the visible inventory when enabled.
        self:RequestLayout("bank_opened")
      end
    elseif event == "MERCHANT_CLOSED"
      or event == "AUCTION_HOUSE_CLOSED"
      or event == "MAIL_CLOSED"
      or event == "BANKFRAME_CLOSED"
      or event == "TRADE_CLOSED" then
      self._unsafeBootstrapDone = false
      self._unsafeBootstrapArmed = false
      self._waitingForSafeContext = false
      if self.frame and self.frame:IsShown() then
        self:RequestLayout(event:lower())
      end
    end
  end)
end

--[[═══════════════════════════════════════════════════════════════════════════
  MAIN FRAME
═══════════════════════════════════════════════════════════════════════════════]]

function BaggyUI:CreateMainFrame()
  local frame
  if BackdropTemplateMixin then
    frame = CreateFrame("Frame", "BaggyFrame", UIParent, "BackdropTemplate")
  else
    frame = CreateFrame("Frame", "BaggyFrame", UIParent)
  end

  -- Start with minimal size - will be resized dynamically
  frame:SetSize(300, 200)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("MEDIUM")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:SetClampedToScreen(true)
  frame:Hide()

  if frame.SetBackdrop then
    frame:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true,
      tileSize = 16,
      edgeSize = 16,
      insets = {left = 3, right = 3, top = 3, bottom = 3},
    })
    frame:SetBackdropColor(0, 0, 0, 0.9)
    frame:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
  end

  -- Title (smaller font for Classic feel)
  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", FRAME_PADDING + 2, -FRAME_PADDING)
  title:SetText("Baggy")
  title:SetTextColor(1, 0.82, 0)
  frame.title = title

  -- Close button (smaller, tighter to corner)
  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)
  close:SetSize(18, 18)
  close:SetScript("OnClick", function()
    BaggyUI:Hide()
  end)
  frame.closeButton = close

  -- Make draggable
  frame:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" then
      self:StartMoving()
      -- Clear search box focus when clicking on frame
      if BaggyUI.frame.searchBox then
        BaggyUI.frame.searchBox:ClearFocus()
      end
    end
  end)

  frame:SetScript("OnMouseUp", function(self)
    self:StopMovingOrSizing()
    BaggyUI:SavePosition()
  end)

  -- Clear search box focus when frame is hidden
  frame:SetScript("OnHide", function(self)
    if BaggyUI.frame.searchBox then
      BaggyUI.frame.searchBox:ClearFocus()
    end
  end)

  self.frame = frame
end

--[[═══════════════════════════════════════════════════════════════════════════
  TOP BAR (Search, Sort, Buttons) - Compact horizontal layout
═══════════════════════════════════════════════════════════════════════════════]]

function BaggyUI:CreateTopBar()
  local frame = self.frame

  -- Container for top bar (positioned below title)
  local topBar = CreateFrame("Frame", nil, frame)
  topBar:SetHeight(TOPBAR_HEIGHT)
  topBar:SetPoint("TOPLEFT", frame.title, "BOTTOMLEFT", 0, -TOPBAR_SPACING)
  topBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -FRAME_PADDING - 20, 0)
  topBar:EnableMouse(true)

  -- Clear search box focus when clicking on topBar background
  topBar:SetScript("OnMouseDown", function()
    if BaggyUI.frame.searchBox then
      BaggyUI.frame.searchBox:ClearFocus()
    end
  end)

  frame.topBar = topBar

  -- Search box (left side)
  local searchBox = CreateFrame("EditBox", nil, topBar)
  searchBox:SetSize(140, TOPBAR_HEIGHT)
  searchBox:SetPoint("LEFT", topBar, "LEFT", 0, 0)
  searchBox:SetAutoFocus(false)
  searchBox:SetFontObject("GameFontNormalSmall")

  if searchBox.SetBackdrop then
    searchBox:SetBackdrop({
      bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
      edgeFile = "Interface\\ChatFrame\\ChatFrameBackground",
      tile = true,
      edgeSize = 1,
      tileSize = 5,
    })
    searchBox:SetBackdropColor(0, 0, 0, 0.5)
    searchBox:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
  end

  searchBox:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
  end)

  searchBox:SetScript("OnTextChanged", function(self)
    local text = self:GetText():lower()
    BaggyUI:OnSearchChanged(text)
  end)

  -- Placeholder text
  local placeholder = searchBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  placeholder:SetPoint("LEFT", 4, 0)
  placeholder:SetText("Search...")
  placeholder:SetTextColor(0.5, 0.5, 0.5)

  searchBox:SetScript("OnEditFocusGained", function()
    placeholder:Hide()
  end)

  searchBox:SetScript("OnEditFocusLost", function(self)
    if self:GetText() == "" then
      placeholder:Show()
    end
  end)

  frame.searchBox = searchBox
  frame.searchPlaceholder = placeholder

  -- Gold display (shows character gold, tooltip shows total)
  local goldFrame = CreateFrame("Frame", nil, topBar)
  goldFrame:SetSize(80, TOPBAR_HEIGHT)
  goldFrame:SetPoint("LEFT", searchBox, "RIGHT", 6, 0)

  local goldText = goldFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  goldText:SetPoint("RIGHT", goldFrame, "RIGHT", 0, 0)
  goldText:SetText("0")
  goldText:SetTextColor(1, 0.82, 0)
  goldFrame.text = goldText

  -- Tooltip showing total gold across characters
  goldFrame:EnableMouse(true)
  goldFrame:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Gold", 1, 1, 1)
    GameTooltip:AddLine(" ")

    -- Current character
    local charGold = HitTools.Baggy:GetCurrentCharacterGold()
    local charKey = HitTools.Baggy:GetCharacterKey()
    GameTooltip:AddDoubleLine(charKey .. " (current):", BaggyUI:FormatMoney(charGold), 1, 0.82, 0, 1, 1, 1)

    GameTooltip:AddLine(" ")

    -- All characters
    local goldData = HitTools.DB.baggy.goldPerChar
    local sortedChars = {}
    for char, gold in pairs(goldData) do
      if char ~= charKey then  -- Don't show current char twice
        table.insert(sortedChars, {char = char, gold = gold})
      end
    end
    table.sort(sortedChars, function(a, b) return a.gold > b.gold end)

    for _, data in ipairs(sortedChars) do
      GameTooltip:AddDoubleLine(data.char .. ":", BaggyUI:FormatMoney(data.gold), 0.7, 0.7, 0.7, 1, 1, 1)
    end

    -- Total
    GameTooltip:AddLine(" ")
    local total = HitTools.Baggy:GetTotalGold()
    GameTooltip:AddDoubleLine("Total:", BaggyUI:FormatMoney(total), 1, 0.82, 0, 1, 0.82, 0)

    GameTooltip:Show()
  end)

  goldFrame:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)

  frame.goldFrame = goldFrame

  -- Sort dropdown (compact button)
  local sortButton = CreateFrame("Button", nil, topBar)
  sortButton:SetSize(70, TOPBAR_HEIGHT)
  sortButton:SetPoint("LEFT", goldFrame, "RIGHT", 4, 0)
  sortButton:SetNormalFontObject("GameFontNormalSmall")
  sortButton:SetText("Type")

  if sortButton.SetBackdrop then
    sortButton:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8x8",
      edgeFile = "Interface\\Buttons\\WHITE8x8",
      tile = false,
      edgeSize = 1,
    })
    sortButton:SetBackdropColor(0.2, 0.2, 0.2, 0.8)
    sortButton:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
  end

  sortButton:SetScript("OnClick", function()
    -- Clear search box focus when clicking sort
    if BaggyUI.frame.searchBox then
      BaggyUI.frame.searchBox:ClearFocus()
    end
    BaggyUI:ShowSortMenu(sortButton)
  end)

  frame.sortButton = sortButton

  -- Keyring button (compact icon)
  local keyringButton = CreateFrame("Button", nil, topBar)
  keyringButton:SetSize(18, 18)
  keyringButton:SetPoint("LEFT", sortButton, "RIGHT", 4, 0)
  keyringButton:SetNormalTexture("Interface\\Icons\\INV_Misc_Key_14")
  keyringButton:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight")

  -- Make the icon fit nicely
  local normalTex = keyringButton:GetNormalTexture()
  if normalTex then
    normalTex:SetTexCoord(0.1, 0.9, 0.1, 0.9)  -- Crop edges for cleaner look
  end

  -- Configure click handling BEFORE setting OnClick script
  keyringButton:RegisterForClicks("LeftButtonUp")
  keyringButton:EnableMouse(true)

  keyringButton:SetScript("OnClick", function(self, button)
    DebugLog("Keyring", "Keyring button clicked")

    -- Clear search box focus
    if BaggyUI.frame.searchBox then
      BaggyUI.frame.searchBox:ClearFocus()
    end

    -- Prevent ToggleBackpack hook from firing
    HitTools._ignoringToggleBackpack = true

    -- Use pcall to catch any errors
    local success, err = pcall(function()
      BaggyUI:ToggleKeyring()
    end)

    -- Re-enable ToggleBackpack hook
    HitTools._ignoringToggleBackpack = false

    if not success then
      DebugLog("Keyring", "Error in ToggleKeyring: " .. tostring(err))
      print("|cffff8000[Baggy]|r Keyring error: " .. tostring(err))
    end

    -- Stop propagation
    return true
  end)

  keyringButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Keyring")
    GameTooltip:AddLine("Click to open/close keyring", 1, 1, 1)
    GameTooltip:Show()
  end)

  keyringButton:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)

  frame.keyringButton = keyringButton

  -- Settings cog icon (compact)
  local settingsButton = CreateFrame("Button", nil, topBar)
  settingsButton:SetSize(18, 18)
  settingsButton:SetPoint("LEFT", keyringButton, "RIGHT", 4, 0)
  settingsButton:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
  settingsButton:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight")

  settingsButton:SetScript("OnClick", function()
    -- Clear search box focus
    if BaggyUI.frame.searchBox then
      BaggyUI.frame.searchBox:ClearFocus()
    end
    -- Open Hit-Tools options to Baggy settings
    HitTools.Options:Show()
  end)

  settingsButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Baggy Settings")
    GameTooltip:Show()
  end)

  settingsButton:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)

  frame.settingsButton = settingsButton

  -- Stack button (compact)
  local stackButton = CreateFrame("Button", nil, topBar)
  stackButton:SetSize(45, TOPBAR_HEIGHT)
  stackButton:SetPoint("LEFT", settingsButton, "RIGHT", 4, 0)
  stackButton:SetNormalFontObject("GameFontNormalSmall")
  stackButton:SetText("Stack")

  if stackButton.SetBackdrop then
    stackButton:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8x8",
      edgeFile = "Interface\\Buttons\\WHITE8x8",
      tile = false,
      edgeSize = 1,
    })
    stackButton:SetBackdropColor(0.2, 0.5, 0.3, 0.8)
    stackButton:SetBackdropBorderColor(0.3, 0.6, 0.4, 1)
  end

  stackButton:SetScript("OnClick", function()
    -- Clear search box focus
    if BaggyUI.frame.searchBox then
      BaggyUI.frame.searchBox:ClearFocus()
    end
    BaggyUI:StackItems()
  end)

  frame.stackButton = stackButton
end

--[[═══════════════════════════════════════════════════════════════════════════
  ITEM GRID - Compact layout with tight spacing
═══════════════════════════════════════════════════════════════════════════════]]

function BaggyUI:CreateItemGrid()
  local frame = self.frame

  -- Scroll frame (positioned directly under topBar with minimal spacing)
  local scrollFrame = CreateFrame("ScrollFrame", nil, frame)
  scrollFrame:SetPoint("TOPLEFT", frame.topBar, "BOTTOMLEFT", 0, -TOPBAR_SPACING)
  scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -20, FRAME_PADDING)

  local scrollChild = CreateFrame("Frame", nil, scrollFrame)
  scrollFrame:SetScrollChild(scrollChild)
  scrollChild:SetSize(scrollFrame:GetWidth(), 1)
  scrollChild:EnableMouse(true)

  -- Clear search box focus when clicking on grid area
  scrollChild:SetScript("OnMouseDown", function()
    if BaggyUI.frame.searchBox then
      BaggyUI.frame.searchBox:ClearFocus()
    end
  end)

  -- Scroll bar (minimal width)
  local scrollBar = CreateFrame("Slider", nil, scrollFrame)
  scrollBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -FRAME_PADDING, -HEADER_HEIGHT - TOPBAR_HEIGHT - TOPBAR_SPACING * 2)
  scrollBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -FRAME_PADDING, FRAME_PADDING)
  scrollBar:SetWidth(12)
  scrollBar:SetOrientation("VERTICAL")
  scrollBar:SetMinMaxValues(0, 100)
  scrollBar:SetValue(0)
  scrollBar:SetValueStep(20)

  if scrollBar.SetBackdrop then
    scrollBar:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8x8",
      edgeFile = "Interface\\Buttons\\WHITE8x8",
      tile = false,
      edgeSize = 1,
    })
    scrollBar:SetBackdropColor(0.1, 0.1, 0.1, 0.5)
    scrollBar:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)
  end

  scrollBar.thumb = scrollBar:CreateTexture(nil, "OVERLAY")
  scrollBar.thumb:SetSize(10, 20)
  scrollBar.thumb:SetTexture("Interface\\Buttons\\WHITE8x8")
  scrollBar.thumb:SetVertexColor(0.4, 0.4, 0.4, 0.8)
  scrollBar:SetThumbTexture(scrollBar.thumb)

  scrollBar:SetScript("OnValueChanged", function(self, value)
    scrollChild:SetPoint("TOPLEFT", 0, value)
  end)

  frame.scrollFrame = scrollFrame
  frame.scrollChild = scrollChild
  frame.scrollBar = scrollBar

  -- Hijacked Blizzard buttons storage
  frame.hijackedButtons = {}
  frame.layoutDirty = false
  self.layoutPending = false
  self.visibleSlotMap = {}
  self._layoutRetryActive = false

  -- Visual divider for separating inventory and bank sections.
  frame.bankDividerLine = scrollChild:CreateTexture(nil, "ARTWORK")
  frame.bankDividerLine:SetTexture("Interface\\Buttons\\WHITE8x8")
  frame.bankDividerLine:SetVertexColor(1.0, 0.82, 0.0, 0.45)
  frame.bankDividerLine:Hide()

  frame.bankDividerLabel = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.bankDividerLabel:SetText("Bank")
  frame.bankDividerLabel:SetTextColor(1.0, 0.82, 0.0, 0.95)
  frame.bankDividerLabel:Hide()

  -- Create dummy bag parent frames (so buttons can find their bag ID via GetParent():GetID())
  frame.bagParents = {}
  -- Create known container parent IDs up front.
  -- Bags: 0-4, bank main: -1, bank bags: 5-11.
  for bagID = -1, 11 do
    self:EnsureBagParent(bagID)
  end
end

--[[═══════════════════════════════════════════════════════════════════════════
  DISPLAY LIST - Single Source of Truth
═══════════════════════════════════════════════════════════════════════════════]]

function BaggyUI:BuildDisplayList()
  local start = debugprofilestop()

  -- Get items from Baggy backend
  local items = HitTools.Baggy:GetAllItems()
  DebugLog("BuildDisplay", "Got " .. #items .. " items from backend")

  -- Apply search filter
  local searchText = self.frame.searchBox:GetText():lower()
  if searchText ~= "" then
    items = HitTools.Baggy:FilterItems(items, searchText)
    DebugLog("BuildDisplay", "Filtered to " .. #items .. " items")
  end

  -- Apply sorting (this reorders the list)
  items = HitTools.Baggy:SortItems(items)
  DebugLog("BuildDisplay", "Sorted by " .. HitTools.DB.baggy.sortMode)

  -- Store as display list (this is now the ONLY source of truth for rendering)
  self.displayList = items

  local elapsed = debugprofilestop() - start
  DebugLog("BuildDisplay", string.format("Built displayList with %d items in %.2fms", #items, elapsed))

  return items
end

--[[═══════════════════════════════════════════════════════════════════════════
  BLIZZARD BUTTON REPARENTING (Secure, Combat-Safe)
  CRITICAL: Each button must be bound to the correct bag/slot from displayList
═══════════════════════════════════════════════════════════════════════════════]]

function BaggyUI:ResetButtonForLayout(button, iconSize)
  if not button then return end
  button:ClearAllPoints()
  button:SetScale(1.0)
  button:SetSize(iconSize, iconSize)
  -- Tooltip state is mapping-dependent; clear when button is repurposed.
  button._baggyTooltipOwnedKey = nil
  local icon = self:GetButtonIconTexture(button)
  if icon then
    icon:ClearAllPoints()
    icon:SetAllPoints(button)
  end
end

function BaggyUI:GetButtonIconTexture(button)
  if not button then
    return nil
  end

  local icon = button.icon
    or button.IconTexture
    or button.iconTexture
    or button.Icon

  if not icon and button.GetName then
    local name = button:GetName()
    if name then
      icon = _G[name .. "IconTexture"] or _G[name .. "Icon"]
    end
  end

  if icon then
    -- Normalize access so the rest of the code can use button.icon safely.
    button.icon = icon
  end
  return icon
end

function BaggyUI:LayoutNow(reason)
  if not self.frame or not self.frame:IsShown() then
    return false
  end

  if InCombatLockdown() then
    self._rebuildDeferred = true
    self._deferredReason = "combat_" .. tostring(reason)
    return false
  end

  self._layoutToken = (self._layoutToken or 0) + 1
  local myToken = self._layoutToken
  local layoutStart = debugprofilestop()
  local layoutError = nil

  self._rebuildDeferred = false
  self._deferredReason = nil
  self._lastLayoutReason = reason or "unknown"
  self._contextSuspended = false
  self._unsafeBootstrapDone = false
  self._unsafeBootstrapArmed = false
  self._waitingForSafeContext = false

  DebugLog("Layout", "=== LAYOUT START (token=" .. myToken .. ", reason=" .. tostring(reason) .. ") ===")

  self:EnsureBlizzardFramesExist()

  local displayList = self:BuildDisplayList()
  local inventorySlots = {}
  local bankSlots = {}
  for _, entry in ipairs(displayList) do
    local slotData = {
      bagID = entry.bagID,
      slot = entry.slot,
      entry = entry,
    }
    if IsBankBagID(entry.bagID) then
      table.insert(bankSlots, slotData)
    else
      table.insert(inventorySlots, slotData)
    end
  end

  local displaySlots = {}
  for _, slotData in ipairs(inventorySlots) do
    table.insert(displaySlots, slotData)
  end
  for _, slotData in ipairs(bankSlots) do
    table.insert(displaySlots, slotData)
  end
  self.displaySlots = displaySlots

  local blizzButtons = self:CollectBlizzardItemButtons()
  local buttonLookup = {}
  for _, btnData in ipairs(blizzButtons) do
    buttonLookup[btnData.bagID .. "_" .. btnData.slot] = btnData
  end

  local iconSize = HitTools.DB.baggy.compactMode and ICON_SIZE_COMPACT or ICON_SIZE
  local spacing = ICON_SPACING
  local cols = ICONS_PER_ROW
  local inventoryCount = #inventorySlots
  local bankCount = #bankSlots
  local inventoryRows = (inventoryCount > 0) and math.ceil(inventoryCount / cols) or 0
  local bankRows = (bankCount > 0) and math.ceil(bankCount / cols) or 0
  local showBankDivider = IsFrameShown("BankFrame") and inventoryCount > 0 and bankCount > 0
  local bankSectionOffsetY = showBankDivider and BANK_SECTION_GAP or 0

  local ok, err = pcall(function()
    for _, btnData in ipairs(blizzButtons) do
      if btnData.button then
        btnData.button:EnableMouse(false)
      end
    end

    for _, btnData in ipairs(self.frame.hijackedButtons or {}) do
      if btnData.button and btnData.originalParent then
        btnData.button:SetParent(btnData.originalParent)
        self:ResetButtonForLayout(btnData.button, iconSize)
        btnData.button:Hide()
        btnData.button._baggyManaged = nil
      end
    end

    self.frame.hijackedButtons = {}
    self.visibleSlotMap = {}

    for gridIndex, slotData in ipairs(displaySlots) do
      local key = slotData.bagID .. "_" .. slotData.slot
      local btnData = buttonLookup[key]
      local entry = slotData.entry

      if btnData and btnData.button then
        local blizzBtn = btnData.button
        local bagParent = self:EnsureBagParent(slotData.bagID) or self.frame.scrollChild

        blizzBtn:SetParent(bagParent)
        self:ResetButtonForLayout(blizzBtn, iconSize)

        local row, col
        local yOffset = 0
        if showBankDivider and gridIndex > inventoryCount then
          local bankIndex = gridIndex - inventoryCount
          row = inventoryRows + math.floor((bankIndex - 1) / cols)
          col = (bankIndex - 1) % cols
          yOffset = bankSectionOffsetY
        else
          row = math.floor((gridIndex - 1) / cols)
          col = (gridIndex - 1) % cols
        end
        local x = math.floor(col * (iconSize + spacing) + 0.5)
        local y = -math.floor((row * (iconSize + spacing)) + yOffset + 0.5)
        blizzBtn:SetPoint("TOPLEFT", self.frame.scrollChild, "TOPLEFT", x, y)

        -- Canonical bag/slot mapping for display + click parity.
        blizzBtn:SetID(slotData.slot)
        blizzBtn.bagID = slotData.bagID
        blizzBtn._baggyManaged = true
        blizzBtn._displayEntry = entry
        blizzBtn._gridIndex = gridIndex

        blizzBtn.UpdateTooltip = function(self)
          if not GameTooltip:IsOwned(self) then
            return
          end
          local key = tostring(self.bagID) .. ":" .. tostring(self:GetID())
          if self._baggyTooltipOwnedKey ~= key then
            GameTooltip:SetBagItem(self.bagID, self:GetID())
            self._baggyTooltipOwnedKey = key
          end
        end

        blizzBtn:SetScript("OnEnter", function(self)
          GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
          self._baggyTooltipOwnedKey = nil
          self:UpdateTooltip()
          GameTooltip:Show()
        end)

        blizzBtn:SetScript("OnLeave", function(self)
          self._baggyTooltipOwnedKey = nil
          GameTooltip:Hide()
          ResetCursor()
        end)

        self:ApplyButtonSkin(blizzBtn, entry)
        blizzBtn:Show()
        blizzBtn:EnableMouse(true)

        self.visibleSlotMap[gridIndex] = {
          bagID = slotData.bagID,
          slot = slotData.slot,
          itemLink = entry.itemLink,
          texture = entry.texture,
          button = blizzBtn,
        }

        table.insert(self.frame.hijackedButtons, {
          button = blizzBtn,
          bagID = slotData.bagID,
          slot = slotData.slot,
          originalParent = btnData.originalParent,
        })

        if gridIndex <= 5 then
          DebugLog("Layout", string.format("#%d -> bag=%d slot=%d link=%s",
            gridIndex, slotData.bagID, slotData.slot, entry.itemLink or "nil"))
        end
      end
    end

    local gridWidth = (iconSize * cols) + (spacing * (cols - 1))
    local gridHeight = iconSize
    if #displaySlots > 0 then
      if showBankDivider then
        local inventoryHeight = (inventoryRows > 0) and ((inventoryRows * iconSize) + ((inventoryRows - 1) * spacing)) or 0
        local bankHeight = (bankRows > 0) and ((bankRows * iconSize) + ((bankRows - 1) * spacing)) or 0
        gridHeight = inventoryHeight + bankSectionOffsetY + bankHeight
      else
        local rows = math.ceil(#displaySlots / cols)
        gridHeight = (rows * iconSize) + ((rows - 1) * spacing)
      end
    end

    if self.frame.bankDividerLine and self.frame.bankDividerLabel then
      if showBankDivider then
        local dividerY = -math.floor((inventoryRows * (iconSize + spacing)) + (bankSectionOffsetY / 2) + 0.5)
        self.frame.bankDividerLine:ClearAllPoints()
        self.frame.bankDividerLine:SetPoint("TOPLEFT", self.frame.scrollChild, "TOPLEFT", 0, dividerY)
        self.frame.bankDividerLine:SetSize(math.max(1, gridWidth), 1)
        self.frame.bankDividerLine:Show()

        self.frame.bankDividerLabel:ClearAllPoints()
        self.frame.bankDividerLabel:SetPoint("BOTTOMLEFT", self.frame.bankDividerLine, "TOPLEFT", 2, 1)
        self.frame.bankDividerLabel:SetText("Bank")
        self.frame.bankDividerLabel:Show()
      else
        self.frame.bankDividerLine:Hide()
        self.frame.bankDividerLabel:Hide()
      end
    end

    self.frame.scrollChild:SetSize(math.max(1, gridWidth), math.max(1, gridHeight))

    local frameWidth = gridWidth + (FRAME_PADDING * 2) + 20
    local frameHeight = HEADER_HEIGHT + TOPBAR_HEIGHT + (TOPBAR_SPACING * 3) + gridHeight + (FRAME_PADDING * 2)
    frameWidth = math.max(300, math.min(frameWidth, 800))
    frameHeight = math.max(200, math.min(frameHeight, 600))
    self.frame:SetSize(frameWidth, frameHeight)

    local scrollHeight = math.max(0, gridHeight - self.frame.scrollFrame:GetHeight())
    self.frame.scrollBar:SetMinMaxValues(0, scrollHeight)
    if scrollHeight > 0 then
      self.frame.scrollBar:Show()
    else
      self.frame.scrollBar:Hide()
    end

    for i = 1, NUM_CONTAINER_FRAMES do
      local containerFrame = _G["ContainerFrame" .. i]
      if containerFrame then
        containerFrame:Hide()
      end
    end
  end)

  for _, btnData in ipairs(blizzButtons) do
    if btnData.button then
      btnData.button:EnableMouse(true)
    end
  end

  if not ok then
    layoutError = err
  end

  if layoutError then
    self.layoutPending = true
    self._rebuildDeferred = true
    self._deferredReason = "layout_error"
    self.frame.layoutDirty = true
    DebugLog("Layout", "Layout failed: " .. tostring(layoutError))
    self:ScheduleDeferredLayout("layout_error", LAYOUT_RETRY_DELAY)
    return false
  end

  self.layoutPending = false
  self.frame.layoutDirty = false

  local layoutTime = debugprofilestop() - layoutStart
  DebugLog("Layout", string.format("=== LAYOUT DONE in %.2fms: %d buttons ===",
    layoutTime, #(self.frame.hijackedButtons or {})))
  return true
end

-- Compatibility shim for older call sites.
function BaggyUI:HijackAndLayoutButtons()
  return self:RequestLayout("hijack_compat")
end

function BaggyUI:ShowCellMappingOverlay(durationSeconds)
  if not DEBUG_ENABLED then
    print("|cffff8000[Baggy]|r Enable debug first: /hit baggy debug on")
    return
  end

  if not self.frame or not self.frame.hijackedButtons then
    return
  end

  local duration = durationSeconds or 10
  for _, btnData in ipairs(self.frame.hijackedButtons) do
    local button = btnData.button
    if button then
      if not button._baggySlotLabel then
        local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
        label:SetJustifyH("LEFT")
        label:SetTextColor(1, 0.85, 0.2, 1)
        button._baggySlotLabel = label
      end
      button._baggySlotLabel:SetText(tostring(btnData.bagID) .. ":" .. tostring(btnData.slot))
      button._baggySlotLabel:Show()
    end
  end

  C_Timer.After(duration, function()
    if not self.frame or not self.frame.hijackedButtons then
      return
    end
    for _, btnData in ipairs(self.frame.hijackedButtons) do
      local button = btnData.button
      if button and button._baggySlotLabel then
        button._baggySlotLabel:Hide()
      end
    end
  end)
end

--[[═══════════════════════════════════════════════════════════════════════════
  BUTTON SKIN - Centralized visual control
  Controls: icon texture, count text, quality borders, overlays
═══════════════════════════════════════════════════════════════════════════════]]

function BaggyUI:ApplyButtonSkin(button, entry)
  if not button or not entry then return end
  local icon = self:GetButtonIconTexture(button)

  -- 1) SET ICON TEXTURE
  if entry.texture and icon then
    icon:SetTexture(entry.texture)
    icon:Show()
    icon:SetAlpha(1)
  elseif icon then
    -- Fallback: try to get texture from container API
    local GetInfo = GetContainerItemInfo or (C_Container and C_Container.GetContainerItemInfo)
    if GetInfo then
      local info = GetInfo(entry.bagID, entry.slot)
      if info then
        local tex = info.iconFileID or info.texture
        if tex then
          icon:SetTexture(tex)
          icon:Show()
        end
      end
    end
  end

  -- 2) SET COUNT TEXT
  local countTextName = button:GetName() .. "Count"
  local countText = _G[countTextName]
  if countText and type(countText.SetText) == "function" then
    if entry.count and entry.count > 1 then
      countText:SetText(tostring(entry.count))
      countText:Show()
      countText:SetAlpha(1)
    else
      countText:SetText("")
      countText:Hide()
    end
  end

  -- 3) CONTROL BLIZZARD OVERLAYS
  -- Hide unwanted modern overlays
  if button.BattlepayItemTexture then
    button.BattlepayItemTexture:Hide()
  end
  if button.NewItemTexture then
    button.NewItemTexture:Hide()  -- Control new item glow manually if needed
  end
  if button.JunkIcon then
    button.JunkIcon:Hide()  -- We can show this for junk items if desired
  end

  -- 4) CONTROL QUALITY BORDER
  -- Modern client has IconBorder that shows quality colors
  if button.IconBorder then
    -- Option A: Use Blizzard's border system
    if entry.quality and entry.quality >= 2 then
      local color = QUALITY_COLORS[entry.quality]
      button.IconBorder:SetVertexColor(color[1], color[2], color[3])
      button.IconBorder:SetAlpha(0.5)  -- Make it subtle
      button.IconBorder:Show()
    else
      button.IconBorder:Hide()
    end

    -- Option B: Or hide it completely and use our own
    -- button.IconBorder:Hide()
  end

  -- 5) CUSTOM BAGGY BORDER (optional, in addition to or instead of IconBorder)
  -- Uncomment if you want a custom border effect
  -- self:AddCustomBorder(button, entry.quality)

  -- 6) ENSURE OTHER STANDARD TEXTURES ARE VISIBLE
  if button.IconOverlay then
    button.IconOverlay:Show()
  end
  if button.NormalTexture then
    button.NormalTexture:Show()
  end

  -- 7) UPDATE COOLDOWN (if applicable)
  if ContainerFrame_UpdateCooldown then
    ContainerFrame_UpdateCooldown(entry.bagID, button)
  end
end

-- DEPRECATED: Old custom border function (kept for reference, not used by default)
function BaggyUI:AddCustomBorder(button, quality)
  if not button then return end

  -- Create or reuse border texture (thin 1px border style)
  if not button.baggyBorder then
    button.baggyBorder = button:CreateTexture(nil, "OVERLAY")
    button.baggyBorder:SetTexture("Interface\\Buttons\\WHITE8x8")
    button.baggyBorder:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
    button.baggyBorder:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
    button.baggyBorder:SetBlendMode("ADD")
  end

  -- Set color based on quality (subtle for Classic feel)
  if quality and quality >= 2 then
    local color = QUALITY_COLORS[quality]
    button.baggyBorder:SetVertexColor(color[1], color[2], color[3], 0.2)
  else
    button.baggyBorder:SetVertexColor(0, 0, 0, 0)
  end
end

-- OLD FUNCTION - REMOVE (replaced by Blizzard button hijacking)
-- OLD FUNCTION - REMOVED
-- Replaced by Blizzard button hijacking approach (HijackAndLayoutButtons)
-- We no longer create our own buttons - we reparent Blizzard's secure buttons instead!

function BaggyUI:Refresh()
  DebugPrint("Refresh() called")

  if not self.frame or not self.frame:IsShown() then
    DebugPrint("Refresh skipped - frame not shown")
    return
  end

  self:RequestLayout("refresh")
end

-- OLD FUNCTION - NO LONGER USED (replaced by HijackAndLayoutButtons)
-- function BaggyUI:RenderItems(items)
--   Replaced by Blizzard button hijacking approach for secure right-click
-- end

--[[═══════════════════════════════════════════════════════════════════════════
  RAINBOW BORDER EFFECT
═══════════════════════════════════════════════════════════════════════════════]]

function BaggyUI:CreateRainbowBorder()
  local frame = self.frame
  local borders = {}

  -- Create 8 border segments (top, bottom, left, right, corners)
  local segments = {
    {name = "top", point = "TOPLEFT", relPoint = "TOPLEFT", x = 0, y = 0, width = "frame:GetWidth()", height = 3},
    {name = "bottom", point = "BOTTOMLEFT", relPoint = "BOTTOMLEFT", x = 0, y = 0, width = "frame:GetWidth()", height = 3},
    {name = "left", point = "TOPLEFT", relPoint = "TOPLEFT", x = 0, y = 0, width = 3, height = "frame:GetHeight()"},
    {name = "right", point = "TOPRIGHT", relPoint = "TOPRIGHT", x = 0, y = 0, width = 3, height = "frame:GetHeight()"},
  }

  for _, seg in ipairs(segments) do
    local border = frame:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Buttons\\WHITE8x8")
    border:SetPoint(seg.point, frame, seg.relPoint, seg.x, seg.y)

    if type(seg.width) == "string" then
      border:SetWidth(frame:GetWidth())
    else
      border:SetWidth(seg.width)
    end

    if type(seg.height) == "string" then
      border:SetHeight(frame:GetHeight())
    else
      border:SetHeight(seg.height)
    end

    border:SetBlendMode("ADD")
    border:SetVertexColor(1, 1, 1, 0)  -- Start invisible
    border:Hide()

    borders[seg.name] = border
  end

  frame.rainbowBorders = borders
  frame.rainbowActive = false
end

function BaggyUI:TriggerRainbowEffect()
  if not self.frame or self.frame.rainbowActive then
    return
  end

  local duration = HitTools.DB.baggy.rainbowSeconds or 3.0
  local borders = self.frame.rainbowBorders
  local startTime = GetTime()

  -- Show borders
  for _, border in pairs(borders) do
    border:Show()
  end

  self.frame.rainbowActive = true

  -- Animate with C_Timer
  if C_Timer and C_Timer.NewTicker then
    local ticker = C_Timer.NewTicker(0.05, function()
      local elapsed = GetTime() - startTime
      local progress = elapsed / duration

      if progress >= 1 then
        -- Fade out and stop
        for _, border in pairs(borders) do
          border:SetVertexColor(1, 1, 1, 0)
          border:Hide()
        end
        self.frame.rainbowActive = false
        return
      end

      -- Rainbow color cycle
      local hue = (elapsed * 2) % 1  -- Cycle through hue
      local r, g, b = self:HSVtoRGB(hue, 1, 1)
      local alpha = 1 - progress  -- Fade out over time

      for _, border in pairs(borders) do
        border:SetVertexColor(r, g, b, alpha)
      end
    end)

    -- Stop ticker after duration
    C_Timer.After(duration + 0.1, function()
      if ticker then
        ticker:Cancel()
      end
    end)
  end
end

function BaggyUI:HSVtoRGB(h, s, v)
  local r, g, b

  local i = math.floor(h * 6)
  local f = h * 6 - i
  local p = v * (1 - s)
  local q = v * (1 - f * s)
  local t = v * (1 - (1 - f) * s)

  i = i % 6

  if i == 0 then r, g, b = v, t, p
  elseif i == 1 then r, g, b = q, v, p
  elseif i == 2 then r, g, b = p, v, t
  elseif i == 3 then r, g, b = p, q, v
  elseif i == 4 then r, g, b = t, p, v
  elseif i == 5 then r, g, b = v, p, q
  end

  return r, g, b
end

--[[═══════════════════════════════════════════════════════════════════════════
  UI INTERACTIONS
═══════════════════════════════════════════════════════════════════════════════]]

function BaggyUI:Show()
  DebugPrint("Show() called, frame exists:", self.frame ~= nil)

  if not self.frame then
    if InCombatLockdown() then
      print("|cffff8000[Baggy]|r Baggy cannot initialize during combat")
      return
    end
    DebugPrint("Frame doesn't exist, calling Initialize()")
    self:Initialize()
  end

  local wasShown = self.frame and self.frame:IsShown()
  DebugPrint("Showing frame and requesting layout")
  if not wasShown then
    self._contextSuspended = false
    self._unsafeBootstrapDone = false
    self._unsafeBootstrapArmed = false
    self.frame:Show()
  end

  -- Update gold display
  self:UpdateGoldDisplay()

  local success, err = pcall(function()
    local reason = InCombatLockdown() and "show_combat" or (wasShown and "show_refresh" or "show")
    self:RequestLayout(reason)
  end)
  if not success then
    print("[BaggyUI] ERROR in Refresh(): " .. tostring(err))
  end
end

function BaggyUI:Hide()
  DebugPrint("Hide() called")
  self:ReleaseHijackedButtons("hide")
  self._unsafeBootstrapDone = false
  self._unsafeBootstrapArmed = false
  self._waitingForSafeContext = false
  if self.frame then
    self.frame:Hide()
  end

  -- Also hide keyring when Baggy closes
  if HitTools.KeyringUI and HitTools.KeyringUI.frame then
    HitTools.KeyringUI.frame:Hide()
  end
end

function BaggyUI:Toggle()
  DebugPrint("Toggle() called, frame exists:", self.frame ~= nil, "isShown:", self.frame and self.frame:IsShown())

  if self.frame and self.frame:IsShown() then
    self:Hide()
  else
    self:Show()
  end
end

function BaggyUI:IsShown()
  return self.frame and self.frame:IsShown()
end

function BaggyUI:SavePosition()
  if not self.frame then return end

  local point, _, relativePoint, x, y = self.frame:GetPoint()
  local db = HitTools.DB.baggy.position

  -- Only save position, not size (size is auto-calculated)
  db.point = point
  db.relativePoint = relativePoint
  db.x = x
  db.y = y
end

function BaggyUI:OnSearchChanged(text)
  -- Debounce search
  self._searchPending = text
  local now = GetTime()

  DebugLog("Search", "Text: " .. (text or ""))

  if not self._lastSearchTime or now - self._lastSearchTime > SEARCH_DEBOUNCE then
    self._lastSearchTime = now
    self:RequestLayout("search")
  else
    -- Schedule delayed search
    if C_Timer and C_Timer.After then
      C_Timer.After(SEARCH_DEBOUNCE, function()
        if self._searchPending then
          self:RequestLayout("search_debounced")
          self._lastSearchTime = GetTime()
        end
      end)
    end
  end
end

function BaggyUI:ShowSortMenu(anchor)
  -- Simple sort mode cycling for V1
  local modes = {
    {id = "default", label = "Default"},
    {id = "rarity", label = "Rarity"},
    {id = "alphabetical", label = "Name"},
    {id = "type", label = "Type"},
    {id = "newest", label = "Newest"},
    {id = "value", label = "Value"},
  }
  local currentMode = HitTools.DB.baggy.sortMode
  local currentIndex = 1

  for i, mode in ipairs(modes) do
    if mode.id == currentMode then
      currentIndex = i
      break
    end
  end

  -- Cycle to next mode
  local nextIndex = (currentIndex % #modes) + 1
  local nextMode = modes[nextIndex]

  local oldMode = HitTools.DB.baggy.sortMode
  HitTools.DB.baggy.sortMode = nextMode.id
  anchor:SetText(nextMode.label)

  DebugLog("Sort", "Changed from " .. oldMode .. " to " .. nextMode.id)

  self:RequestLayout("sort_changed")
end

function BaggyUI:StackItems()
  -- TODO: Implement item stacking
  -- This is complex in TBC, requires PickupContainerItem loops
  DebugPrint("Item stacking not yet implemented")
end

function BaggyUI:SetCombatMode(inCombat)
  if not self.frame then return end

  -- Disable certain buttons in combat
  if inCombat then
    self.frame.stackButton:Disable()
    self.frame.sortButton:Disable()
  else
    self.frame.stackButton:Enable()
    self.frame.sortButton:Enable()
  end
end

--[[═══════════════════════════════════════════════════════════════════════════
  GOLD DISPLAY
═══════════════════════════════════════════════════════════════════════════════]]

function BaggyUI:FormatMoney(copper)
  if not copper or copper == 0 then
    return "0|cffC0C0C0c|r"
  end

  local gold = math.floor(copper / 10000)
  local silver = math.floor((copper % 10000) / 100)
  copper = copper % 100

  local str = ""
  if gold > 0 then
    str = str .. gold .. "|cffFFD700g|r"
  end
  if silver > 0 then
    if gold > 0 then str = str .. " " end
    str = str .. silver .. "|cffC0C0C0s|r"
  end
  if copper > 0 or (gold == 0 and silver == 0) then
    if gold > 0 or silver > 0 then str = str .. " " end
    str = str .. copper .. "|cffC07030c|r"
  end

  return str
end

function BaggyUI:UpdateGoldDisplay()
  if not self.frame or not self.frame.goldFrame then return end

  local gold = HitTools.Baggy:GetCurrentCharacterGold()
  self.frame.goldFrame.text:SetText(self:FormatMoney(gold))
end

--[[═══════════════════════════════════════════════════════════════════════════
  KEYRING TOGGLE
═══════════════════════════════════════════════════════════════════════════════]]

function BaggyUI:ToggleKeyring()
  -- Toggle separate keyring UI
  if not HitTools.KeyringUI then
    -- Initialize keyring UI on first use
    HitTools.KeyringUI = {}
    self:CreateKeyringUI()
  end

  if HitTools.KeyringUI.frame:IsShown() then
    HitTools.KeyringUI.frame:Hide()
  else
    HitTools.KeyringUI.frame:Show()
    self:RefreshKeyringUI()
  end
end

function BaggyUI:CreateKeyringUI()
  local frame = CreateFrame("Frame", "BaggyKeyringFrame", UIParent)
  frame:SetSize(200, 100)  -- Small compact frame
  frame:SetPoint("BOTTOMLEFT", self.frame, "TOPLEFT", 0, 4)
  frame:SetFrameStrata("MEDIUM")
  frame:SetMovable(false)
  frame:EnableMouse(true)

  -- Background
  if frame.SetBackdrop then
    frame:SetBackdrop({
      bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
      edgeFile = "Interface\\Buttons\\WHITE8x8",
      tile = false,
      edgeSize = 1,
    })
    frame:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
    frame:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
  end

  -- Title
  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  title:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -4)
  title:SetText("Keyring")
  title:SetTextColor(1, 0.82, 0)

  -- Close button
  local closeBtn = CreateFrame("Button", nil, frame)
  closeBtn:SetSize(16, 16)
  closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
  closeBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
  closeBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight")
  closeBtn:SetScript("OnClick", function()
    frame:Hide()
  end)

  -- Container for keyring buttons
  local container = CreateFrame("Frame", nil, frame)
  container:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -22)
  container:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -6, 6)
  container:EnableMouse(true)

  local emptyText = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  emptyText:SetPoint("CENTER", container, "CENTER", 0, 0)
  emptyText:SetTextColor(0.8, 0.8, 0.8, 1)
  emptyText:Hide()

  HitTools.KeyringUI.frame = frame
  HitTools.KeyringUI.container = container
  HitTools.KeyringUI.emptyText = emptyText
  HitTools.KeyringUI.customButtons = {}

  frame:SetScript("OnShow", function()
    BaggyUI:StartKeyringHoverTicker()
  end)
  frame:SetScript("OnHide", function()
    BaggyUI:StopKeyringHoverTicker()
  end)

  frame:Hide()  -- Start hidden
end

function BaggyUI:ShowKeyringTooltip(owner, bagID, slot, itemLink)
  if not owner then return false end

  GameTooltip:SetOwner(UIParent, "ANCHOR_CURSOR_RIGHT")
  GameTooltip:ClearLines()

  local shown = false
  local method = "none"

  -- Prefer item-link tooltips for keyring because bag -2 can return wrong tooltip
  -- data on some modern-client Classic branches.
  if itemLink then
    local ok = pcall(GameTooltip.SetHyperlink, GameTooltip, itemLink)
    if ok then
      local _, tooltipLink = GameTooltip:GetItem()
      shown = (tooltipLink ~= nil) or (GameTooltip:NumLines() > 0)
      if shown then
        method = "hyperlink"
      end
    end
  end

  if not shown and itemLink and GameTooltip.SetItemByID then
    local itemID = tonumber(itemLink:match("item:(%d+)"))
    if itemID then
      local ok = pcall(GameTooltip.SetItemByID, GameTooltip, itemID)
      shown = ok and (GameTooltip:NumLines() > 0)
      if shown then
        method = "itemid"
      end
    end
  end

  -- Keep SetBagItem as a final fallback only.
  if not shown and bagID and slot then
    local ok = pcall(GameTooltip.SetBagItem, GameTooltip, bagID, slot)
    if ok then
      local _, tooltipLink = GameTooltip:GetItem()
      shown = (tooltipLink ~= nil) or (GameTooltip:NumLines() > 0)
      if shown then
        method = "bagitem"
      end
    end
  end

  if not shown and itemLink then
    local itemName = GetItemInfo(itemLink)
    if itemName then
      GameTooltip:SetText(itemName)
      shown = true
      method = "name"
    end
  end

  if DEBUG_ENABLED then
    local _, tooltipLink = GameTooltip:GetItem()
    DebugLog("KeyringTT", string.format("slot=%s shown=%s method=%s link=%s tt=%s",
      tostring(slot), tostring(shown), tostring(method), tostring(itemLink), tostring(tooltipLink)))
  end

  GameTooltip:Show()
  return shown
end

function BaggyUI:StartKeyringHoverTicker()
  if not HitTools.KeyringUI or not HitTools.KeyringUI.frame then return end
  local frame = HitTools.KeyringUI.frame
  if frame._hoverTicker then return end

  frame._hoverTicker = C_Timer.NewTicker(0.1, function()
    if not frame:IsShown() then return end
    local now = GetTime()
    local hovered = nil

    for _, btn in ipairs(HitTools.KeyringUI.customButtons or {}) do
      if btn and btn:IsShown() and btn:IsMouseOver() then
        hovered = btn
        break
      end
    end

    if hovered then
      frame._hoveredKeyButton = hovered
      frame._lastHoverTime = now
      if hovered ~= frame._shownTooltipButton or not GameTooltip:IsShown() then
        BaggyUI:ShowKeyringTooltip(hovered, hovered._baggyBagID, hovered._baggySlot, hovered._baggyItemLink)
        frame._shownTooltipButton = hovered
      end
    else
      -- Debounce hide to avoid tooltip flicker from transient hover gaps.
      if frame._hoveredKeyButton and (now - (frame._lastHoverTime or 0)) > 0.18 then
        frame._hoveredKeyButton = nil
        frame._shownTooltipButton = nil
        GameTooltip:Hide()
      end
    end
  end)
end

function BaggyUI:StopKeyringHoverTicker()
  if not HitTools.KeyringUI or not HitTools.KeyringUI.frame then return end
  local frame = HitTools.KeyringUI.frame
  if frame._hoverTicker then
    frame._hoverTicker:Cancel()
    frame._hoverTicker = nil
  end
  frame._hoveredKeyButton = nil
  frame._shownTooltipButton = nil
  frame._lastHoverTime = nil
  GameTooltip:Hide()
end

function BaggyUI:RefreshKeyringUI()
  if not HitTools.KeyringUI then return end

  local container = HitTools.KeyringUI.container
  local emptyText = HitTools.KeyringUI.emptyText
  local bagID = KEYRING_CONTAINER or -2

  -- Get API functions
  local GetNumSlots = GetContainerNumSlots or (C_Container and C_Container.GetContainerNumSlots)
  local GetContainerInfo = GetContainerItemInfo or (C_Container and C_Container.GetContainerItemInfo)
  local GetItemLink = GetContainerItemLink or (C_Container and C_Container.GetContainerItemLink)

  if not GetNumSlots then
    if emptyText then
      emptyText:SetText("Keyring unavailable on this client")
      emptyText:Show()
    end
    return
  end

  local numSlots = GetNumSlots(bagID) or 0

  -- Clear existing custom buttons
  if HitTools.KeyringUI.customButtons then
    for _, btn in ipairs(HitTools.KeyringUI.customButtons) do
      btn:Hide()
    end
  end
  HitTools.KeyringUI.customButtons = {}
  if emptyText then
    emptyText:Hide()
  end

  if numSlots <= 0 then
    if emptyText then
      emptyText:SetText("No keyring on this client")
      emptyText:Show()
    end
    HitTools.KeyringUI.frame:SetSize(220, 70)
    return
  end

  -- Collect keyring items (only non-empty slots)
  local items = {}
  for slot = 1, numSlots do
    local itemLink = GetItemLink and GetItemLink(bagID, slot)
    if itemLink then
      table.insert(items, {
        slot = slot,
        link = itemLink,
      })
    end
  end

  -- If no keys, show message
  if #items == 0 then
    if emptyText then
      emptyText:SetText("Keyring is empty")
      emptyText:Show()
    end
    HitTools.KeyringUI.frame:SetSize(200, 70)
    return
  end

  -- Layout config
  local iconSize = 32
  local spacing = 2
  local cols = 8

  -- Create custom buttons for each keyring item
  for i, item in ipairs(items) do
    local slot = item.slot
    local itemLink = item.link
    local row = math.floor((i - 1) / cols)
    local col = (i - 1) % cols

    -- Create simple button
    local button = CreateFrame("Button", nil, container)
    button:SetSize(iconSize, iconSize)
    button:EnableMouse(true)
    button._baggyBagID = bagID
    button._baggySlot = slot
    button._baggyItemLink = itemLink
    button:SetPoint("TOPLEFT", container, "TOPLEFT",
      col * (iconSize + spacing),
      -row * (iconSize + spacing))

    -- Create icon texture
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    local itemTexture = GetItemIcon(itemLink)
    if itemTexture then
      icon:SetTexture(itemTexture)
    end

    -- Create count text
    local count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 2)
    local itemCount = 1
    local info = GetContainerInfo and GetContainerInfo(bagID, slot)
    if type(info) == "table" then
      itemCount = info.stackCount or 1
    elseif GetContainerInfo then
      local _, oldCount = GetContainerInfo(bagID, slot)
      itemCount = oldCount or 1
    end
    if itemCount and itemCount > 1 then
      count:SetText(itemCount)
    else
      count:SetText("")
    end

    -- Set click handlers
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:SetScript("OnClick", function(_, btn)
      if btn == "LeftButton" then
        if C_Container and C_Container.PickupContainerItem then
          C_Container.PickupContainerItem(bagID, slot)
        elseif PickupContainerItem then
          PickupContainerItem(bagID, slot)
        end
      elseif btn == "RightButton" then
        if C_Container and C_Container.UseContainerItem then
          C_Container.UseContainerItem(bagID, slot)
        elseif UseContainerItem then
          UseContainerItem(bagID, slot)
        end
      end
    end)

    button:SetScript("OnEnter", function(self)
      BaggyUI:ShowKeyringTooltip(self, bagID, slot, itemLink)
    end)

    button:SetScript("OnLeave", nil)

    button:Show()
    table.insert(HitTools.KeyringUI.customButtons, button)
  end

  -- Auto-size frame
  local numRows = math.ceil(#items / cols)
  local frameHeight = 22 + (numRows * (iconSize + spacing)) + 10
  local frameWidth = math.min(#items, cols) * (iconSize + spacing) + 12
  HitTools.KeyringUI.frame:SetSize(frameWidth, frameHeight)
end

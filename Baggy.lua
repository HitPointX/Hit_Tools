--[[
═══════════════════════════════════════════════════════════════════════════════
  BAGGY - Unified Inventory UI
  "One big bag" with search, sorting, and rainbow effects
═══════════════════════════════════════════════════════════════════════════════
]]--

local _, HitTools = ...

HitTools.Baggy = HitTools.Baggy or {}
local Baggy = HitTools.Baggy

-- Constants
local BACKPACK_CONTAINER = 0
local NUM_BAG_SLOTS = 4
local BANK_CONTAINER = -1
local NUM_BANKBAGSLOTS = 7

-- Quality thresholds
local ITEM_QUALITY_UNCOMMON = 2  -- Green
local ITEM_QUALITY_RARE = 3      -- Blue
local ITEM_QUALITY_EPIC = 4      -- Purple

-- Throttle intervals
local BAG_UPDATE_THROTTLE = 0.15  -- seconds
local SEARCH_DEBOUNCE = 0.15      -- seconds

-- Debug infrastructure
local DEBUG_ENABLED = false
local lastDebugTime = {}

local function DebugPrint(...)
  if DEBUG_ENABLED then
    print("|cff00ff00[Baggy]|r", ...)
  end
end

-- Rate-limited debug (max once per 0.5s per key)
local function DebugLog(key, ...)
  if not DEBUG_ENABLED then return end
  local now = GetTime()
  if not lastDebugTime[key] or (now - lastDebugTime[key]) > 0.5 then
    lastDebugTime[key] = now
    print("|cff00ff00[Baggy:" .. key .. "]|r", ...)
  end
end

-- Item cache structure
local itemCache = {
  bags = {},        -- [bagID][slot] = itemData
  bank = {},        -- [bagID][slot] = itemData
  lastUpdate = 0,
  dirty = true,
}

-- Loot tracking for "newest" sort
local recentLoots = {}  -- [itemID] = timestamp
local MAX_RECENT_LOOTS = 50

--[[═══════════════════════════════════════════════════════════════════════════
  INITIALIZATION
═══════════════════════════════════════════════════════════════════════════════]]

function Baggy:OnDBReady()
  DebugPrint("Initializing Baggy module...")

  -- Initialize DB structure
  if not HitTools.DB.baggy then
    HitTools.DB.baggy = {
      enabled = true,
      showBank = true,
      compactMode = false,
      sortMode = "default",
      searchTooltip = false,
      bigDropQuality = ITEM_QUALITY_RARE,  -- Rare+
      rainbowSeconds = 3.0,
      goldPerChar = {},  -- [realm-name] = gold amount
      position = {
        point = "CENTER",
        relativePoint = "CENTER",
        x = 0,
        y = 0,
        width = 600,
        height = 500,
      },
    }
  end

  -- Ensure goldPerChar table exists (for existing installs)
  if not HitTools.DB.baggy.goldPerChar then
    HitTools.DB.baggy.goldPerChar = {}
  end

  -- Create event frame
  local f = CreateFrame("Frame")
  self._frame = f

  -- Register events
  f:RegisterEvent("BAG_UPDATE_DELAYED")
  f:RegisterEvent("BAG_UPDATE")
  f:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
  f:RegisterEvent("BANKFRAME_OPENED")
  f:RegisterEvent("BANKFRAME_CLOSED")
  f:RegisterEvent("PLAYER_ENTERING_WORLD")
  f:RegisterEvent("CHAT_MSG_LOOT")
  f:RegisterEvent("PLAYER_REGEN_DISABLED")  -- Combat start
  f:RegisterEvent("PLAYER_REGEN_ENABLED")   -- Combat end
  f:RegisterEvent("PLAYER_MONEY")           -- Gold changed

  f:SetScript("OnEvent", function(_, event, ...)
    if event == "BAG_UPDATE_DELAYED" then
      -- Use DELAYED only (not BAG_UPDATE) to avoid excessive refreshes
      DebugLog("Event", "BAG_UPDATE_DELAYED")
      Baggy:OnBagUpdate()
    elseif event == "BAG_UPDATE" then
      -- Ignore BAG_UPDATE, only use DELAYED
      -- (BAG_UPDATE fires too frequently)
    elseif event == "PLAYERBANKSLOTS_CHANGED" then
      if Baggy:IsBankOpen() then
        DebugLog("Event", "PLAYERBANKSLOTS_CHANGED")
        Baggy:MarkDirty()
      end
    elseif event == "BANKFRAME_OPENED" then
      DebugLog("Event", "BANKFRAME_OPENED")
      Baggy:OnBankOpened()
    elseif event == "BANKFRAME_CLOSED" then
      DebugLog("Event", "BANKFRAME_CLOSED")
      Baggy:OnBankClosed()
    elseif event == "PLAYER_ENTERING_WORLD" then
      DebugLog("Event", "PLAYER_ENTERING_WORLD")
      Baggy:OnEnteringWorld()
    elseif event == "CHAT_MSG_LOOT" then
      local message = ...
      Baggy:OnLootMessage(message)
    elseif event == "PLAYER_REGEN_DISABLED" then
      DebugLog("Event", "COMBAT_START")
      Baggy:OnCombatStart()
    elseif event == "PLAYER_REGEN_ENABLED" then
      DebugLog("Event", "COMBAT_END")
      Baggy:OnCombatEnd()
    elseif event == "PLAYER_MONEY" then
      Baggy:UpdateGoldTracking()
    end
  end)

  -- Initialize BaggyUI frame
  DebugPrint("BaggyUI exists:", HitTools.BaggyUI ~= nil, "Initialize exists:", HitTools.BaggyUI and HitTools.BaggyUI.Initialize ~= nil)
  if HitTools.BaggyUI and HitTools.BaggyUI.Initialize then
    DebugPrint("Calling BaggyUI:Initialize()")
    HitTools.BaggyUI:Initialize()
  else
    DebugPrint("WARNING: BaggyUI or Initialize not found!")
  end

  -- Hook bag toggle functions (if enabled)
  self:SetupBagHooks()

  DebugPrint("Initialization complete")
end

--[[═══════════════════════════════════════════════════════════════════════════
  BAG HOOKS - Intercept default bag keybinds
═══════════════════════════════════════════════════════════════════════════════]]

function Baggy:SetupBagHooks()
  if not self._hooked then
    -- Create hidden frame to reparent default bags (Bagnon-style)
    local disabledParent = CreateFrame("Frame", nil, UIParent)
    disabledParent:SetAllPoints()
    disabledParent:Hide()
    self._disabledParent = disabledParent

    -- Hook ContainerFrame SetID to reparent when Baggy is enabled
    -- This prevents default bags from showing even when Blizzard code tries to open them
    local NUM_CONTAINER_FRAMES = NUM_CONTAINER_FRAMES or 13
    for i = 1, NUM_CONTAINER_FRAMES do
      local frame = _G["ContainerFrame" .. i]
      if frame then
        hooksecurefunc(frame, "SetID", function(self, bag)
          if HitTools.DB.baggy.enabled then
            self:SetParent(disabledParent)
          else
            self:SetParent(UIParent)
          end
        end)
      end
    end

    -- Hook ToggleBackpack (default "B" key)
    hooksecurefunc("ToggleBackpack", function()
      DebugPrint("ToggleBackpack hook fired, enabled:", HitTools.DB.baggy.enabled)
      if HitTools.DB.baggy.enabled then
        -- Skip if triggered from keyring button
        if HitTools._ignoringToggleBackpack then
          DebugPrint("Skipped - ignoring ToggleBackpack (keyring button)")
          return
        end

        local stack = debugstack()
        local calledFromBulkOpen = stack:find("ToggleAllBags") or stack:find("OpenAllBags")
        if not calledFromBulkOpen then
          DebugPrint("Calling BaggyUI:Toggle(), BaggyUI exists:", HitTools.BaggyUI ~= nil)
          if HitTools.BaggyUI then
            HitTools.BaggyUI:Toggle()
          end
        else
          DebugPrint("Skipped - called from bulk bag open")
        end
      end
    end)

    -- Hook OpenAllBags (Shift+B)
    hooksecurefunc("OpenAllBags", function()
      if HitTools.DB.baggy.enabled then
        if HitTools.BaggyUI then
          HitTools.BaggyUI:Show()
        end
      end
    end)

    -- Hook CloseAllBags
    hooksecurefunc("CloseAllBags", function()
      if HitTools.DB.baggy.enabled then
        if HitTools.BaggyUI then
          HitTools.BaggyUI:Hide()
        end
      end
    end)

    self._hooked = true
  end
end

--[[═══════════════════════════════════════════════════════════════════════════
  EVENT HANDLERS
═══════════════════════════════════════════════════════════════════════════════]]

function Baggy:OnBagUpdate()
  -- Throttle bag updates
  local now = GetTime()
  if now - itemCache.lastUpdate < BAG_UPDATE_THROTTLE then
    DebugLog("Throttle", "Skipped update (too soon)")
    return
  end

  itemCache.lastUpdate = now
  self:MarkDirty()

  -- Refresh UI if visible (BaggyUI handles deferred layout safely)
  if HitTools.BaggyUI and HitTools.BaggyUI:IsShown() then
    DebugLog("Refresh", "Triggering refresh")
    HitTools.BaggyUI:Refresh()
  end
end

function Baggy:OnBankOpened()
  if HitTools.DB.baggy.enabled and HitTools.DB.baggy.showBank then
    self:MarkDirty()
    if HitTools.BaggyUI then
      HitTools.BaggyUI:Show()
    end
  end
end

function Baggy:OnBankClosed()
  self:MarkDirty()
  if HitTools.BaggyUI and HitTools.BaggyUI:IsShown() then
    HitTools.BaggyUI:Refresh()
  end
end

function Baggy:OnEnteringWorld()
  self:MarkDirty()
  -- Initialize gold tracking for this character
  self:UpdateGoldTracking()
end

function Baggy:OnLootMessage(message)
  -- Parse loot message for big drop detection
  -- Format: "You receive loot: [Item Link]."
  local itemLink = message:match("|c%x+|Hitem:.-|h%[.-%]|h|r")
  if not itemLink then return end

  -- Extract quality
  local _, _, quality, _, _, _, _, _, _, _, _ = GetItemInfo(itemLink)
  if not quality then return end

  -- Check if big drop (configurable threshold)
  if quality >= HitTools.DB.baggy.bigDropQuality then
    -- Trigger rainbow effect
    if HitTools.BaggyUI then
      HitTools.BaggyUI:TriggerRainbowEffect()
    end
  end

  -- Track for "newest" sort
  local itemID = self:GetItemIDFromLink(itemLink)
  if itemID then
    recentLoots[itemID] = GetTime()
    -- Prune old loots
    if self:TableCount(recentLoots) > MAX_RECENT_LOOTS then
      local oldest = nil
      local oldestTime = GetTime()
      for id, time in pairs(recentLoots) do
        if time < oldestTime then
          oldestTime = time
          oldest = id
        end
      end
      if oldest then
        recentLoots[oldest] = nil
      end
    end
  end
end

function Baggy:OnCombatStart()
  -- Disable certain buttons during combat
  if HitTools.BaggyUI then
    HitTools.BaggyUI:SetCombatMode(true)
  end
end

function Baggy:OnCombatEnd()
  if HitTools.BaggyUI then
    HitTools.BaggyUI:SetCombatMode(false)
  end
end

--[[═══════════════════════════════════════════════════════════════════════════
  ITEM CACHE MANAGEMENT
═══════════════════════════════════════════════════════════════════════════════]]

function Baggy:MarkDirty()
  itemCache.dirty = true
end

function Baggy:RebuildCache()
  if not itemCache.dirty then
    return itemCache
  end

  local bags = {}
  local bank = {}

  -- Scan backpack + equipped bags (0-4)
  for bag = BACKPACK_CONTAINER, NUM_BAG_SLOTS do
    bags[bag] = self:ScanBag(bag)
  end

  -- Scan bank bags if open
  if self:IsBankOpen() and HitTools.DB.baggy.showBank then
    -- Bank container
    bank[BANK_CONTAINER] = self:ScanBag(BANK_CONTAINER)

    -- Bank bag slots (5-11 in TBC)
    for bag = NUM_BAG_SLOTS + 1, NUM_BAG_SLOTS + NUM_BANKBAGSLOTS do
      bank[bag] = self:ScanBag(bag)
    end
  end

  itemCache.bags = bags
  itemCache.bank = bank
  itemCache.dirty = false

  return itemCache
end

function Baggy:ScanBag(bagID)
  local slots = {}

  -- TBC API compatibility
  local GetNumSlots = GetContainerNumSlots or (C_Container and C_Container.GetContainerNumSlots)
  if not GetNumSlots then
    print("[Baggy] ERROR: GetContainerNumSlots not available!")
    return slots
  end

  local numSlots = GetNumSlots(bagID)
  DebugPrint("ScanBag(" .. tostring(bagID) .. "): GetContainerNumSlots returned " .. tostring(numSlots))

  if not numSlots or numSlots == 0 then
    DebugPrint("Bag " .. tostring(bagID) .. " has no slots, skipping")
    return slots
  end

  DebugPrint("Bag " .. tostring(bagID) .. " has " .. tostring(numSlots) .. " slots, scanning...")

  for slot = 1, numSlots do
    local GetContainerInfo = GetContainerItemInfo or (C_Container and C_Container.GetContainerItemInfo)
    local info = GetContainerInfo(bagID, slot)

    -- C_Container returns a table, old API returns multiple values
    local texture, itemCount, locked, quality, readable, lootable
    if type(info) == "table" then
      -- Modern API (C_Container) - returns table
      texture = info.iconFileID or info.texture
      itemCount = info.stackCount
      locked = info.isLocked
      quality = info.quality
      readable = info.isReadable
      lootable = info.hasLoot
    else
      -- Classic API - returns multiple values
      texture = info
      itemCount, locked, quality, readable, lootable = GetContainerInfo(bagID, slot)
    end

    -- TBC: Get itemLink separately (GetContainerItemInfo doesn't return it in TBC)
    local GetItemLink = GetContainerItemLink or (C_Container and C_Container.GetContainerItemLink)
    local itemLink = GetItemLink and GetItemLink(bagID, slot)

    -- TBC: itemID must be extracted from itemLink
    local itemID = itemLink and self:GetItemIDFromLink(itemLink)

    if itemID and texture then
      -- Get additional item info
      local name, link, itemQuality, ilvl, minLevel, itemType, itemSubType, stackCount, equipLoc, icon, vendorPrice = GetItemInfo(itemID)

      slots[slot] = {
        bagID = bagID,
        slot = slot,
        itemID = itemID,
        itemLink = itemLink,
        name = name,
        quality = quality or itemQuality,
        ilvl = ilvl,
        itemType = itemType,
        itemSubType = itemSubType,
        texture = icon,  -- Use icon string from GetItemInfo, not texture object from GetContainerItemInfo
        count = itemCount or 1,
        locked = locked,
        vendorPrice = vendorPrice,
        lootTime = recentLoots[itemID],
      }
    else
      -- Empty slot
      slots[slot] = {
        bagID = bagID,
        slot = slot,
        empty = true,
      }
    end
  end

  return slots
end

function Baggy:GetAllItems()
  local cache = self:RebuildCache()
  local items = {}

  DebugPrint("GetAllItems: cache.bags has " .. self:TableCount(cache.bags) .. " bags")

  -- Add bag items
  for bagID, bag in pairs(cache.bags) do
    local bagCount = 0
    for slot, item in pairs(bag) do
      if not item.empty then
        table.insert(items, item)
        bagCount = bagCount + 1
      end
    end
    DebugPrint("Bag " .. bagID .. " has " .. bagCount .. " items")
  end

  -- Add bank items
  for bagID, bag in pairs(cache.bank) do
    for slot, item in pairs(bag) do
      if not item.empty then
        table.insert(items, item)
      end
    end
  end

  DebugPrint("Total items: " .. #items)
  return items
end

--[[═══════════════════════════════════════════════════════════════════════════
  SEARCH & FILTERING
═══════════════════════════════════════════════════════════════════════════════]]

function Baggy:FilterItems(items, searchQuery)
  if not searchQuery or searchQuery == "" then
    return items
  end

  local filtered = {}
  local query = searchQuery:lower()

  for _, item in ipairs(items) do
    if self:ItemMatchesSearch(item, query) then
      table.insert(filtered, item)
    end
  end

  return filtered
end

function Baggy:ItemMatchesSearch(item, query)
  -- Match against name
  if item.name and item.name:lower():find(query, 1, true) then
    return true
  end

  -- Match against type/subtype
  if item.itemType and item.itemType:lower():find(query, 1, true) then
    return true
  end

  if item.itemSubType and item.itemSubType:lower():find(query, 1, true) then
    return true
  end

  -- Optional: tooltip search (expensive, only if enabled)
  if HitTools.DB.baggy.searchTooltip then
    -- TODO: Implement tooltip search using GameTooltip scanning
    -- This is expensive, skip for V1
  end

  return false
end

--[[═══════════════════════════════════════════════════════════════════════════
  SORTING
═══════════════════════════════════════════════════════════════════════════════]]

function Baggy:SortItems(items, sortMode)
  sortMode = sortMode or HitTools.DB.baggy.sortMode

  if sortMode == "rarity" then
    table.sort(items, self.SortByRarity)
  elseif sortMode == "alphabetical" then
    table.sort(items, self.SortByName)
  elseif sortMode == "type" then
    table.sort(items, self.SortByType)
  elseif sortMode == "newest" then
    table.sort(items, self.SortByNewest)
  elseif sortMode == "value" then
    table.sort(items, self.SortByValue)
  end
  -- "default" = bag order, no sorting

  return items
end

function Baggy.SortByRarity(a, b)
  if a.quality ~= b.quality then
    return (a.quality or 0) > (b.quality or 0)
  end
  return (a.name or "") < (b.name or "")
end

function Baggy.SortByName(a, b)
  return (a.name or "") < (b.name or "")
end

function Baggy.SortByType(a, b)
  if a.itemType ~= b.itemType then
    return (a.itemType or "") < (b.itemType or "")
  end
  if a.itemSubType ~= b.itemSubType then
    return (a.itemSubType or "") < (b.itemSubType or "")
  end
  return (a.name or "") < (b.name or "")
end

function Baggy.SortByNewest(a, b)
  local aTime = a.lootTime or 0
  local bTime = b.lootTime or 0
  if aTime ~= bTime then
    return aTime > bTime  -- Newest first
  end
  return (a.name or "") < (b.name or "")
end

function Baggy.SortByValue(a, b)
  local aValue = (a.vendorPrice or 0) * (a.count or 1)
  local bValue = (b.vendorPrice or 0) * (b.count or 1)
  if aValue ~= bValue then
    return aValue < bValue  -- Least expensive first
  end
  return (a.name or "") < (b.name or "")
end

--[[═══════════════════════════════════════════════════════════════════════════
  UTILITIES
═══════════════════════════════════════════════════════════════════════════════]]

function Baggy:IsBankOpen()
  -- TBC-compatible bank check
  return BankFrame and BankFrame:IsShown()
end

function Baggy:GetItemIDFromLink(itemLink)
  if not itemLink then return nil end
  local itemID = itemLink:match("item:(%d+)")
  return tonumber(itemID)
end

function Baggy:TableCount(tbl)
  local count = 0
  for _ in pairs(tbl) do
    count = count + 1
  end
  return count
end

function Baggy:CalculateVendorTotal()
  local total = 0
  local items = self:GetAllItems()

  for _, item in ipairs(items) do
    if item.vendorPrice and item.count then
      total = total + (item.vendorPrice * item.count)
    end
  end

  return total
end

--[[═══════════════════════════════════════════════════════════════════════════
  GOLD TRACKING
═══════════════════════════════════════════════════════════════════════════════]]

function Baggy:GetCharacterKey()
  local realm = GetRealmName()
  local name = UnitName("player")
  return realm .. "-" .. name
end

function Baggy:UpdateGoldTracking()
  local charKey = self:GetCharacterKey()
  local gold = GetMoney()

  HitTools.DB.baggy.goldPerChar[charKey] = gold

  -- Update UI if visible
  if HitTools.BaggyUI and HitTools.BaggyUI.UpdateGoldDisplay then
    HitTools.BaggyUI:UpdateGoldDisplay()
  end
end

function Baggy:GetTotalGold()
  local total = 0
  for _, amount in pairs(HitTools.DB.baggy.goldPerChar) do
    total = total + amount
  end
  return total
end

function Baggy:GetCurrentCharacterGold()
  return GetMoney()
end

--[[═══════════════════════════════════════════════════════════════════════════
  DEBUG & DIAGNOSTICS
═══════════════════════════════════════════════════════════════════════════════]]

function Baggy:ToggleDebug(enabled)
  if enabled == nil then
    DEBUG_ENABLED = not DEBUG_ENABLED
  else
    DEBUG_ENABLED = enabled
  end

  -- Store state for BaggyUI to access
  self._debugEnabled = DEBUG_ENABLED

  -- Sync with BaggyUI
  if HitTools.BaggyUI and HitTools.BaggyUI.SyncDebugState then
    HitTools.BaggyUI:SyncDebugState()
  end

  print("|cffff8000[Baggy]|r Debug mode:", DEBUG_ENABLED and "|cff00ff00ON|r" or "|cffff0000OFF|r")
  return DEBUG_ENABLED
end

function Baggy:PrintDiagnostics()
  print("|cffff8000=== Baggy Diagnostics ===|r")
  local ui = HitTools.BaggyUI

  if not ui or not ui.frame then
    print("BaggyUI frame: NOT CREATED")
    print("|cffff8000=====================|r")
    return
  end

  local frame = ui.frame
  local context = ui.GetContextState and ui:GetContextState() or {}
  local frameW, frameH = frame:GetSize()
  local gridW, gridH = 0, 0
  local childW, childH = 0, 0
  if frame.scrollFrame then
    gridW, gridH = frame.scrollFrame:GetSize()
  end
  if frame.scrollChild then
    childW, childH = frame.scrollChild:GetSize()
  end
  local hijackedCount = frame.hijackedButtons and #frame.hijackedButtons or 0

  print("In combat:", InCombatLockdown())
  print("Sort mode:", HitTools.DB.baggy.sortMode)
  print(string.format("Context open: merchant=%s ah=%s bank=%s mail=%s trade=%s",
    tostring(context.merchant), tostring(context.auctionHouse), tostring(context.bank),
    tostring(context.mail), tostring(context.trade)))
  print("Layout token:", ui._layoutToken or 0)
  print("Buttons count:", hijackedCount)
  print(string.format("Frame sizes: main=%.1fx%.1f grid=%.1fx%.1f scrollChild=%.1fx%.1f",
    frameW, frameH, gridW, gridH, childW, childH))
  print(string.format("Layout pending: pending=%s dirty=%s retry=%s deferred=%s",
    tostring(ui.layoutPending), tostring(frame.layoutDirty),
    tostring(ui._layoutRetryActive), tostring(ui._rebuildDeferred)))

  print("First 5 visible mappings:")
  local printed = 0
  local mapped = ui.visibleSlotMap or {}
  for i = 1, 5 do
    local entry = mapped[i]
    if entry then
      print(string.format("  #%d bag=%s slot=%s link=%s tex=%s",
        i, tostring(entry.bagID), tostring(entry.slot), tostring(entry.itemLink), tostring(entry.texture)))
      printed = printed + 1
    end
  end
  if printed == 0 then
    print("  (no visible mapped buttons)")
  end

  print("Cache dirty:", itemCache.dirty)
  print("Last update:", string.format("%.2fs ago", GetTime() - itemCache.lastUpdate))

  print("|cffff8000=====================|r")
end

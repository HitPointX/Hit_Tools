local _, HitTools = ...

HitTools.Scrapya = HitTools.Scrapya or {}
local Scrapya = HitTools.Scrapya

local BACKPACK_CONTAINER = 0
local NUM_BAG_SLOTS = 4
local ITEM_QUALITY_POOR = 0
local ITEM_QUALITY_COMMON = 1
local ITEM_QUALITY_RARE = 3
local DEFAULT_SELL_INTERVAL = 0.2
local DEFAULT_MAX_PASSES = 40
local ITEM_CLASS_ARMOR = LE_ITEM_CLASS_ARMOR or 4
local ITEM_BIND_ON_EQUIP = LE_ITEM_BIND_ON_EQUIP or 2

local GetNumSlots = GetContainerNumSlots or (C_Container and C_Container.GetContainerNumSlots)
local GetContainerInfo = GetContainerItemInfo or (C_Container and C_Container.GetContainerItemInfo)
local GetItemLink = GetContainerItemLink or (C_Container and C_Container.GetContainerItemLink)
local UseContainerItemCompat = UseContainerItem or (C_Container and C_Container.UseContainerItem)

local PRIMARY_ARMOR_SUBCLASS_BY_CLASS = {
  WARRIOR = 4,      -- Plate
  PALADIN = 4,      -- Plate
  DEATHKNIGHT = 4,  -- Plate
  HUNTER = 3,       -- Mail
  SHAMAN = 3,       -- Mail
  EVOKER = 3,       -- Mail
  ROGUE = 2,        -- Leather
  DRUID = 2,        -- Leather
  MONK = 2,         -- Leather
  DEMONHUNTER = 2,  -- Leather
  PRIEST = 1,       -- Cloth
  MAGE = 1,         -- Cloth
  WARLOCK = 1,      -- Cloth
}

local ARMOR_EQUIP_LOC = {
  INVTYPE_HEAD = true,
  INVTYPE_SHOULDER = true,
  INVTYPE_CHEST = true,
  INVTYPE_ROBE = true,
  INVTYPE_WAIST = true,
  INVTYPE_LEGS = true,
  INVTYPE_FEET = true,
  INVTYPE_WRIST = true,
  INVTYPE_HAND = true,
}

local SCAN_TIP_NAME = "HitToolsScrapyaScanTooltip"
local ScanTip = CreateFrame("GameTooltip", SCAN_TIP_NAME, UIParent, "GameTooltipTemplate")
ScanTip:SetOwner(UIParent, "ANCHOR_NONE")

local state = {
  selling = false,
  ticker = nil,
  passCount = 0,
  startedMoney = 0,
  soldStacksJunk = 0,
  soldItemsJunk = 0,
  soldStacksSoulbound = 0,
  soldItemsSoulbound = 0,
}

local function formatMoney(copper)
  copper = tonumber(copper) or 0
  if copper < 0 then
    copper = 0
  end
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  if g > 0 then
    return string.format("%dg %ds %dc", g, s, c)
  end
  if s > 0 then
    return string.format("%ds %dc", s, c)
  end
  return string.format("%dc", c)
end

local function merchantIsOpen()
  return MerchantFrame and MerchantFrame.IsShown and MerchantFrame:IsShown()
end

local function getDB()
  return HitTools.DB and HitTools.DB.scrapya
end

function Scrapya:StopSelling(reason)
  if state.ticker and state.ticker.Cancel then
    state.ticker:Cancel()
  end
  state.ticker = nil

  local wasSelling = state.selling
  state.selling = false

  if not wasSelling then
    return
  end

  local db = getDB()
  if not db or db.showSummary == false then
    return
  end

  local currentMoney = GetMoney and (GetMoney() or state.startedMoney) or state.startedMoney
  local earned = currentMoney - (state.startedMoney or 0)
  local totalSoldItems = (state.soldItemsJunk or 0) + (state.soldItemsSoulbound or 0)
  local totalSoldStacks = (state.soldStacksJunk or 0) + (state.soldStacksSoulbound or 0)
  if earned > 0 then
    if (state.soldItemsSoulbound or 0) > 0 then
      HitTools:Print(string.format(
        "Scrapya: Sold %d item%s (%d stack%s) for %s. Breakdown: junk=%d, soulbound non-primary armor=%d.",
        totalSoldItems,
        (totalSoldItems == 1 and "" or "s"),
        totalSoldStacks,
        (totalSoldStacks == 1 and "" or "s"),
        formatMoney(earned),
        state.soldItemsJunk or 0,
        state.soldItemsSoulbound or 0
      ))
    else
      HitTools:Print(string.format(
        "Scrapya: Sold %d junk item%s (%d stack%s) for %s.",
        state.soldItemsJunk,
        (state.soldItemsJunk == 1 and "" or "s"),
        state.soldStacksJunk,
        (state.soldStacksJunk == 1 and "" or "s"),
        formatMoney(earned)
      ))
    end
  elseif reason == "limit" and totalSoldStacks > 0 then
    HitTools:Print("Scrapya: Stopped after max sell passes.")
  end
end

function Scrapya:GetPrimaryArmorSubclassID()
  local _, classToken = UnitClass and UnitClass("player")
  if not classToken then
    return nil
  end
  return PRIMARY_ARMOR_SUBCLASS_BY_CLASS[classToken]
end

function Scrapya:IsSlotSoulbound(bagID, slot)
  if not ScanTip or not ScanTip.SetBagItem then
    return false
  end

  ScanTip:ClearLines()
  ScanTip:SetBagItem(bagID, slot)

  local soulboundText = ITEM_SOULBOUND
  local numLines = ScanTip:NumLines() or 0
  for i = 2, numLines do
    local leftText = _G[SCAN_TIP_NAME .. "TextLeft" .. i]
    local text = leftText and leftText:GetText()
    if text and soulboundText and text:find(soulboundText, 1, true) then
      return true
    end
  end
  return false
end

function Scrapya:IsSoulboundOffArmorCandidate(bagID, slot, itemQuality, vendorPrice, itemEquipLoc, itemClassID, itemSubClassID, bindType)
  local db = getDB()
  if not db or db.sellNonPrimarySoulbound ~= true then
    return false
  end

  -- Restricted scope by quality and required vendor value.
  if itemQuality ~= ITEM_QUALITY_COMMON and itemQuality ~= ITEM_QUALITY_RARE then
    return false
  end
  if not vendorPrice or vendorPrice <= 0 then
    return false
  end

  -- NEVER touch BoE items in this advanced mode.
  if bindType == nil then
    return false
  end
  if bindType == ITEM_BIND_ON_EQUIP then
    return false
  end

  -- NEVER touch jewelry/weapons: only consider standard armor slots.
  if itemClassID ~= ITEM_CLASS_ARMOR then
    return false
  end
  if not itemEquipLoc or not ARMOR_EQUIP_LOC[itemEquipLoc] then
    return false
  end

  -- Only cloth/leather/mail/plate; skip shields/relics/misc armor subclasses.
  if not itemSubClassID or itemSubClassID < 1 or itemSubClassID > 4 then
    return false
  end

  -- Only sell if it is soulbound right now.
  if not self:IsSlotSoulbound(bagID, slot) then
    return false
  end

  -- Only sell if this armor type does not match class primary armor type.
  local primaryArmor = self:GetPrimaryArmorSubclassID()
  if not primaryArmor then
    return false
  end
  if itemSubClassID == primaryArmor then
    return false
  end

  return true
end

function Scrapya:TrySellSlot(bagID, slot)
  if not GetContainerInfo or not GetItemLink or not UseContainerItemCompat then
    return false
  end

  local info = GetContainerInfo(bagID, slot)
  local texture, itemCount, locked, quality

  if type(info) == "table" then
    texture = info.iconFileID or info.texture
    itemCount = info.stackCount or info.count or 0
    locked = info.isLocked
    quality = info.quality
  else
    texture = info
    itemCount, locked, quality = select(2, GetContainerInfo(bagID, slot))
  end

  if not texture or locked then
    return false
  end

  local itemLink = GetItemLink(bagID, slot)
  if not itemLink then
    return false
  end

  local itemQuality = quality
  local _, _, qualityFromInfo, _, _, _, _, _, itemEquipLoc, _, vendorPrice, itemClassID, itemSubClassID, bindType = GetItemInfo(itemLink)
  if itemQuality == nil then
    itemQuality = qualityFromInfo
  end

  local sellAsJunk = (itemQuality == ITEM_QUALITY_POOR and vendorPrice and vendorPrice > 0) and true or false
  local sellAsSoulboundOffArmor = false
  if not sellAsJunk then
    sellAsSoulboundOffArmor = self:IsSoulboundOffArmorCandidate(
      bagID,
      slot,
      itemQuality,
      vendorPrice,
      itemEquipLoc,
      itemClassID,
      itemSubClassID,
      bindType
    )
  end

  if not sellAsJunk and not sellAsSoulboundOffArmor then
    return false
  end

  UseContainerItemCompat(bagID, slot)

  if sellAsSoulboundOffArmor then
    state.soldStacksSoulbound = state.soldStacksSoulbound + 1
    state.soldItemsSoulbound = state.soldItemsSoulbound + (tonumber(itemCount) or 1)
  else
    state.soldStacksJunk = state.soldStacksJunk + 1
    state.soldItemsJunk = state.soldItemsJunk + (tonumber(itemCount) or 1)
  end
  return true
end

function Scrapya:SellPass()
  local db = getDB()
  if not db or db.enabled == false then
    self:StopSelling("disabled")
    return
  end

  if not merchantIsOpen() then
    self:StopSelling("merchant_closed")
    return
  end

  state.passCount = state.passCount + 1
  if state.passCount > (tonumber(db.maxPasses) or DEFAULT_MAX_PASSES) then
    self:StopSelling("limit")
    return
  end

  local soldThisPass = 0
  for bagID = BACKPACK_CONTAINER, NUM_BAG_SLOTS do
    local numSlots = GetNumSlots and (GetNumSlots(bagID) or 0) or 0
    for slot = 1, numSlots do
      if self:TrySellSlot(bagID, slot) then
        soldThisPass = soldThisPass + 1
      end
    end
  end

  if soldThisPass == 0 then
    self:StopSelling("done")
  end
end

function Scrapya:StartSelling()
  local db = getDB()
  if not db or db.enabled == false then
    return
  end

  if db.shiftBypass ~= false and IsShiftKeyDown and IsShiftKeyDown() then
    return
  end

  if state.ticker and state.ticker.Cancel then
    state.ticker:Cancel()
  end
  state.ticker = nil

  state.selling = true
  state.passCount = 0
  state.soldStacksJunk = 0
  state.soldItemsJunk = 0
  state.soldStacksSoulbound = 0
  state.soldItemsSoulbound = 0
  state.startedMoney = GetMoney and (GetMoney() or 0) or 0

  local interval = tonumber(db.sellInterval) or DEFAULT_SELL_INTERVAL
  if interval < 0.05 then
    interval = 0.05
  end

  if C_Timer and C_Timer.NewTicker then
    state.ticker = C_Timer.NewTicker(interval, function()
      Scrapya:SellPass()
    end)
  else
    -- Fallback for clients without NewTicker.
    local f = CreateFrame("Frame")
    local elapsedTotal = 0
    f:SetScript("OnUpdate", function(self, elapsed)
      elapsedTotal = elapsedTotal + (elapsed or 0)
      if elapsedTotal < interval then
        return
      end
      elapsedTotal = 0
      if not state.selling then
        self:SetScript("OnUpdate", nil)
        return
      end
      Scrapya:SellPass()
    end)
    state.ticker = {
      Cancel = function()
        if f then
          f:SetScript("OnUpdate", nil)
        end
      end
    }
  end
end

function Scrapya:OnDBReady()
  if not HitTools.DB.scrapya then
    HitTools.DB.scrapya = {
      enabled = true,
      showSummary = true,
      shiftBypass = true,
      sellInterval = DEFAULT_SELL_INTERVAL,
      maxPasses = DEFAULT_MAX_PASSES,
      sellNonPrimarySoulbound = false, -- Disabled by default (high-risk mode)
    }
  end

  local db = HitTools.DB.scrapya
  if db.enabled == nil then db.enabled = true end
  if db.showSummary == nil then db.showSummary = true end
  if db.shiftBypass == nil then db.shiftBypass = true end
  if db.sellInterval == nil then db.sellInterval = DEFAULT_SELL_INTERVAL end
  if db.maxPasses == nil then db.maxPasses = DEFAULT_MAX_PASSES end
  if db.sellNonPrimarySoulbound == nil then db.sellNonPrimarySoulbound = false end

  if not self._frame then
    self._frame = CreateFrame("Frame")
  end

  local f = self._frame
  f:RegisterEvent("MERCHANT_SHOW")
  f:RegisterEvent("MERCHANT_CLOSED")
  f:RegisterEvent("UI_ERROR_MESSAGE")

  f:SetScript("OnEvent", function(_, event, ...)
    if event == "MERCHANT_SHOW" then
      Scrapya:StartSelling()
    elseif event == "MERCHANT_CLOSED" then
      Scrapya:StopSelling("merchant_closed")
    elseif event == "UI_ERROR_MESSAGE" then
      local arg1, arg2 = ...
      local errText = arg2 or arg1
      if errText == ERR_VENDOR_DOESNT_BUY or errText == ERR_TOO_MUCH_GOLD then
        Scrapya:StopSelling("vendor_error")
      end
    end
  end)
end

function Scrapya:HandleCommand(args)
  args = (args or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  local db = getDB()
  if not db then
    HitTools:Print("Scrapya: Database not ready yet.")
    return
  end

  if args == "" or args == "status" then
    HitTools:Print("Scrapya: " .. (db.enabled and "ON" or "OFF"))
    HitTools:Print("  Shift override: " .. ((db.shiftBypass ~= false) and "ON" or "OFF"))
    HitTools:Print("  Summary message: " .. ((db.showSummary ~= false) and "ON" or "OFF"))
    HitTools:Print("  Sell soulbound non-primary armor (white/blue): " .. ((db.sellNonPrimarySoulbound == true) and "ON" or "OFF"))
    return
  end

  if args == "on" then
    db.enabled = true
    HitTools:Print("Scrapya enabled.")
    return
  end

  if args == "off" then
    db.enabled = false
    self:StopSelling("manual_off")
    HitTools:Print("Scrapya disabled.")
    return
  end

  if args == "summary on" then
    db.showSummary = true
    HitTools:Print("Scrapya summary enabled.")
    return
  end

  if args == "summary off" then
    db.showSummary = false
    HitTools:Print("Scrapya summary disabled.")
    return
  end

  if args == "shift on" then
    db.shiftBypass = true
    HitTools:Print("Scrapya shift override enabled.")
    return
  end

  if args == "shift off" then
    db.shiftBypass = false
    HitTools:Print("Scrapya shift override disabled.")
    return
  end

  if args == "soulbound on" then
    db.sellNonPrimarySoulbound = true
    HitTools:Print("Scrapya caution mode enabled: soulbound non-primary white/blue armor can be sold.")
    return
  end

  if args == "soulbound off" then
    db.sellNonPrimarySoulbound = false
    HitTools:Print("Scrapya caution mode disabled.")
    return
  end

  HitTools:Print("Scrapya commands:")
  HitTools:Print("  /hit scrapya on|off")
  HitTools:Print("  /hit scrapya status")
  HitTools:Print("  /hit scrapya summary on|off")
  HitTools:Print("  /hit scrapya shift on|off")
  HitTools:Print("  /hit scrapya soulbound on|off")
end

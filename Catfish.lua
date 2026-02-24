local _, HitTools = ...

HitTools.Catfish = HitTools.Catfish or {}
local Catfish = HitTools.Catfish

local FISHING_SPELL_ID = 7620
local DRAGONFLIGHT_FISHING_SPELL_ID = 131474
local DEFAULT_DOUBLE_CLICK_WINDOW = 0.35
local DEFAULT_MIN_BITE_DELAY = 1.5
local DEFAULT_ALERT_TIMEOUT = 8.0
local CLICK_SUPPRESS_WINDOW = 0.45
local DOUBLE_CLICK_MIN_SECONDS = 0.04
local HOVER_ALERT_ANCHOR_WINDOW = 0.75
local DEFAULT_ADAPTIVE_BOOTSTRAP_DELAY = 8.0
local DEFAULT_ADAPTIVE_MIN_SECONDS = 4.0
local DEFAULT_ADAPTIVE_MAX_SECONDS = 18.0
local DEFAULT_ADAPTIVE_LEAD_SECONDS = 0.35
local DEFAULT_ADAPTIVE_EARLY_OFFSET = 0.0
local ADAPTIVE_SAMPLE_CAP = 40
local ADAPTIVE_EMA_ALPHA = 0.35

local CLASSIC_FISHING_IDS = {
  7620, 7731, 7732, 18248, 33095, 51294,
}

local function getFishingSpellID()
  if IsSpellKnown then
    for i = 1, #CLASSIC_FISHING_IDS do
      local spellID = CLASSIC_FISHING_IDS[i]
      if IsSpellKnown(spellID) then
        return spellID
      end
    end
  end
  return FISHING_SPELL_ID
end

local function getFishingSpellName()
  if GetSpellInfo then
    return GetSpellInfo(FISHING_SPELL_ID) or "Fishing"
  end
  return "Fishing"
end

local function getCursorPositionUI()
  if not GetCursorPosition or not UIParent or not UIParent.GetEffectiveScale then
    return nil, nil
  end
  local x, y = GetCursorPosition()
  local scale = UIParent:GetEffectiveScale()
  if not x or not y or not scale or scale <= 0 then
    return nil, nil
  end
  return x / scale, y / scale
end

local function getCatfishDB()
  local db = HitTools.DB and HitTools.DB.catfish
  if type(db) ~= "table" then return nil end
  return db
end

local function getTooltipLeftText(line)
  local region = _G and _G["GameTooltipTextLeft" .. tostring(line)]
  if region and region.GetText then
    return region:GetText()
  end
  return nil
end

local function getCVarSafe(name)
  if not GetCVar then return nil end
  local ok, value = pcall(GetCVar, name)
  if ok then return value end
  return nil
end

local function setCVarSafe(name, value)
  if not SetCVar then return end
  pcall(SetCVar, name, value)
end

local function clamp(value, minValue, maxValue)
  if value < minValue then return minValue end
  if value > maxValue then return maxValue end
  return value
end

local function sortedCopy(values)
  local out = {}
  for i = 1, #values do
    out[i] = values[i]
  end
  table.sort(out)
  return out
end

local function percentileFromSorted(sortedValues, p)
  local n = #sortedValues
  if n <= 0 then return nil end
  if n == 1 then return sortedValues[1] end
  local rank = ((n - 1) * p) + 1
  local low = math.floor(rank)
  local high = math.ceil(rank)
  if low < 1 then low = 1 end
  if high < 1 then high = 1 end
  if low > n then low = n end
  if high > n then high = n end
  if low == high then return sortedValues[low] end
  local frac = rank - low
  return sortedValues[low] + ((sortedValues[high] - sortedValues[low]) * frac)
end

function Catfish:IsEnabled()
  local db = getCatfishDB()
  return db and db.enabled ~= false
end

function Catfish:CreateGlowFrame()
  if self._glowFrame then return end

  local frame = CreateFrame("Frame", "HitToolsCatfishGlowFrame", UIParent)
  frame:SetFrameStrata("TOOLTIP")
  frame:SetFrameLevel(9000)
  frame:SetSize(1, 1)
  frame:EnableMouse(false)
  frame:Hide()

  frame.rings = {}

  local outer = frame:CreateTexture(nil, "BACKGROUND", nil, 0)
  outer:SetPoint("CENTER", frame, "CENTER", 0, 0)
  outer:SetSize(110, 110)
  outer:SetTexture("Interface\\GLUES\\Models\\UI_Draenei\\GenericGlow64")
  outer:SetVertexColor(0.15, 1.0, 0.7)
  outer:SetBlendMode("ADD")
  frame.rings[1] = outer

  local middle = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
  middle:SetPoint("CENTER", frame, "CENTER", 0, 0)
  middle:SetSize(78, 78)
  middle:SetTexture("Interface\\GLUES\\Models\\UI_Draenei\\GenericGlow64")
  middle:SetVertexColor(0.25, 1.0, 0.8)
  middle:SetBlendMode("ADD")
  frame.rings[2] = middle

  local inner = frame:CreateTexture(nil, "BACKGROUND", nil, 2)
  inner:SetPoint("CENTER", frame, "CENTER", 0, 0)
  inner:SetSize(48, 48)
  inner:SetTexture("Interface\\GLUES\\Models\\UI_Draenei\\GenericGlow64")
  inner:SetVertexColor(0.35, 1.0, 0.9)
  inner:SetBlendMode("ADD")
  frame.rings[3] = inner

  self._glowFrame = frame
end

function Catfish:CreateCastButton()
  if self._castButton then return end

  local button = CreateFrame("Button", "HitToolsCatfishCastButton", UIParent, "SecureActionButtonTemplate")
  button:RegisterForClicks("AnyDown", "AnyUp")
  button:SetAttribute("type", "spell")
  button:SetAttribute("spell", getFishingSpellID())
  if SecureHandlerWrapScript then
    local isClassic = WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE
    SecureHandlerWrapScript(button, "PostClick", button, string.format([[
      local isClassic = %s
      if isClassic == true then
        self:ClearBindings()
      else
        if not down then
          self:ClearBindings()
        end
      end
    ]], tostring(isClassic)))
  end
  button:Hide()
  self._castButton = button
end

function Catfish:CreateCoreFrame()
  if self._frame then return end

  local f = CreateFrame("Frame", "HitToolsCatfishFrame")
  f:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
  f:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
  f:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
  f:RegisterEvent("UNIT_SPELLCAST_FAILED")
  f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
  f:RegisterEvent("PLAYER_STARTED_MOVING")
  f:RegisterEvent("LOOT_OPENED")
  f:RegisterEvent("PLAYER_ENTERING_WORLD")
  f:SetScript("OnEvent", function(_, event, ...)
    self:OnEvent(event, ...)
  end)
  f:SetScript("OnUpdate", function(_, elapsed)
    self:OnUpdate(elapsed)
  end)

  self._frame = f
end

function Catfish:HookWorldFrame()
  if self._worldHooked then return end
  if not WorldFrame or not WorldFrame.HookScript then return end

  WorldFrame:HookScript("OnMouseDown", function(_, button)
    self:OnWorldMouseDown(button)
  end)

  self._worldHooked = true
end

function Catfish:OnDBReady()
  if self._initialized then return end
  self._initialized = true

  self._lastWorldLeftClick = 0
  self._fishingChannelActive = false
  self._fishingChannelStartedAt = 0
  self._movedDuringChannel = false
  self._alertActive = false
  self._alertElapsed = 0
  self._alertX = nil
  self._alertY = nil
  self._lastCastCursorX = nil
  self._lastCastCursorY = nil
  self._lastCastAt = 0
  self._lastAnyLeftClickAt = 0
  self._currentBobberName = nil
  self._hoverTracking = false
  self._hoverLastCursorType = nil
  self._hoverLastTooltipLine2 = nil
  self._hoverLastNpcGuid = nil
  self._hoverLastNpcName = nil
  self._hoverPredictiveFired = false
  self._lastHoverBobberCursorX = nil
  self._lastHoverBobberCursorY = nil
  self._lastHoverBobberAt = 0
  self._softTargetCVarCache = nil
  self._pendingStopElapsed = nil
  self._pendingStopAt = 0
  self._pendingLeadDelta = nil
  self._pendingLeadLateNoAlert = false
  self._lastAdaptiveThreshold = nil
  self._currentCastAlertElapsed = nil
  self._debug = false

  self:CreateGlowFrame()
  self:CreateCastButton()
  self:CreateCoreFrame()
  self:HookWorldFrame()
end

function Catfish:ResetFishingState(preservePendingStop)
  self._fishingChannelActive = false
  self._fishingChannelStartedAt = 0
  self._movedDuringChannel = false
  self._currentBobberName = nil
  self._hoverTracking = false
  self._hoverLastCursorType = nil
  self._hoverLastTooltipLine2 = nil
  self._hoverLastNpcGuid = nil
  self._hoverLastNpcName = nil
  self._hoverPredictiveFired = false
  self._currentCastAlertElapsed = nil
  if not preservePendingStop then
    self._pendingStopElapsed = nil
    self._pendingStopAt = 0
    self._pendingLeadDelta = nil
    self._pendingLeadLateNoAlert = false
  end
  self:RestoreSoftTargetInteractCVars()
end

function Catfish:StopAlert()
  self._alertActive = false
  self._alertElapsed = 0
  if self._glowFrame then
    self._glowFrame:Hide()
  end
end

function Catfish:CaptureAlertPosition()
  local now = GetTime()
  local x, y

  -- Best anchor is the most recent confirmed "cursor is over bobber" point.
  if self._lastHoverBobberCursorX and self._lastHoverBobberCursorY and (now - (self._lastHoverBobberAt or 0) <= HOVER_ALERT_ANCHOR_WINDOW) then
    x = self._lastHoverBobberCursorX
    y = self._lastHoverBobberCursorY
  end

  if (not x or not y) then
    local hovering = self:GetHoverBobberState()
    if hovering then
      x, y = getCursorPositionUI()
    end
  end

  -- Accessibility fallback: cursor position if bobber anchor is unavailable.
  if not x or not y then
    x, y = getCursorPositionUI()
  end

  -- Last resort fallback: last cast position.
  if (not x or not y) and self._lastCastCursorX and self._lastCastCursorY and (now - (self._lastCastAt or 0) <= 30) then
    x = self._lastCastCursorX
    y = self._lastCastCursorY
  end

  if not x or not y then
    x = UIParent:GetWidth() * 0.5
    y = UIParent:GetHeight() * 0.5
  end
  self._alertX = x
  self._alertY = y
end

function Catfish:StartAlert()
  local db = getCatfishDB()
  if not db or db.bobberAlert == false then return end

  self:CaptureAlertPosition()
  self._alertActive = true
  self._alertElapsed = 0

  if self._glowFrame then
    self._glowFrame:ClearAllPoints()
    self._glowFrame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", self._alertX or 0, self._alertY or 0)
    self._glowFrame:Show()
  end

  if db.playSound ~= false and HitTools.PlayAlertSound then
    HitTools:PlayAlertSound("catfishBobber")
  end
end

function Catfish:IsFishingChannel()
  if not UnitChannelInfo then return false end
  local name, _, _, _, _, _, _, spellID = UnitChannelInfo("player")
  local fishingSpellID = getFishingSpellID()
  if spellID and (spellID == fishingSpellID or spellID == FISHING_SPELL_ID or spellID == DRAGONFLIGHT_FISHING_SPELL_ID) then
    return true
  end
  return name and name == getFishingSpellName()
end

function Catfish:TryCastFishingWithSecureBinding()
  if InCombatLockdown and InCombatLockdown() then
    return false
  end

  if not self._castButton or not SetOverrideBindingClick then return false end
  if IsFlying and IsFlying() then return false end
  if IsPlayerMoving and IsPlayerMoving() then return false end
  if IsMounted and IsMounted() then return false end

  local spellID = getFishingSpellID()
  if not spellID then return false end

  if self._castButton.SetAttribute then
    self._castButton:SetAttribute("type", "spell")
    self._castButton:SetAttribute("spell", spellID)
  end

  local ok = pcall(SetOverrideBindingClick, self._castButton, true, "BUTTON1", "HitToolsCatfishCastButton")
  if ok then
    return true
  end

  return false
end

function Catfish:OnWorldMouseDown(button)
  local now = GetTime()
  if button == "LeftButton" or button == "RightButton" then
    self._lastAnyLeftClickAt = now
    if self._alertActive then
      self:StopAlert()
    end
  end

  local db = getCatfishDB()
  if not db or db.enabled == false then return end
  if db.doubleClickCast == false then return end
  if button ~= "LeftButton" then return end
  if InCombatLockdown and InCombatLockdown() then return end
  if IsMouselooking and IsMouselooking() then return end
  if IsShiftKeyDown and IsShiftKeyDown() then return end
  if IsControlKeyDown and IsControlKeyDown() then return end
  if IsAltKeyDown and IsAltKeyDown() then return end

  local window = tonumber(db.doubleClickWindow) or DEFAULT_DOUBLE_CLICK_WINDOW
  local delta = now - (self._lastWorldLeftClick or 0)

  if delta <= window and delta >= DOUBLE_CLICK_MIN_SECONDS then
    self._lastWorldLeftClick = 0
    self._lastCastCursorX, self._lastCastCursorY = getCursorPositionUI()
    self._lastCastAt = now
    self:TryCastFishingWithSecureBinding()
    return
  end

  self._lastWorldLeftClick = now
end

function Catfish:HasRecentLeftClick()
  local last = tonumber(self._lastAnyLeftClickAt) or 0
  return (GetTime() - last) <= CLICK_SUPPRESS_WINDOW
end

function Catfish:GetHoverBobberState()
  if not GameTooltip or not GameTooltip.IsShown or not GameTooltip:IsShown() then
    return false, nil, nil
  end

  local title = getTooltipLeftText(1)
  if not title or title == "" then
    return false, nil, nil
  end

  local trackedName = self._currentBobberName or _G.FISHING_BOBBER or "Fishing Bobber"
  if trackedName and trackedName ~= "" and title ~= trackedName then
    if not tostring(title):find(tostring(trackedName), 1, true) then
      return false, nil, nil
    end
  end

  local tooltipLine2 = getTooltipLeftText(2) or ""
  local cursorType = nil
  if GetCursor then
    cursorType = GetCursor()
  end
  return true, tooltipLine2, tostring(cursorType or "")
end

function Catfish:UpdateHoverBiteProbe()
  local hovering, tooltipLine2, cursorType = self:GetHoverBobberState()
  local npcGuid = UnitGUID and UnitGUID("npc") or nil
  local npcName = UnitName and UnitName("npc") or nil
  if not hovering then
    self._hoverTracking = false
    self._hoverLastCursorType = nil
    self._hoverLastTooltipLine2 = nil
    self._hoverLastNpcGuid = nil
    self._hoverLastNpcName = nil
    return
  end

  local hoverX, hoverY = getCursorPositionUI()
  if hoverX and hoverY then
    self._lastHoverBobberCursorX = hoverX
    self._lastHoverBobberCursorY = hoverY
    self._lastHoverBobberAt = GetTime()
  end

  if not self._hoverTracking then
    self._hoverTracking = true
    self._hoverLastCursorType = cursorType
    self._hoverLastTooltipLine2 = tooltipLine2
    self._hoverLastNpcGuid = npcGuid
    self._hoverLastNpcName = npcName
    if self._debug then
      HitTools:Print("Catfish hover probe: tracking bobber")
    end
    return
  end

  local prevCursorType = self._hoverLastCursorType
  local prevTooltipLine2 = self._hoverLastTooltipLine2
  local prevNpcGuid = self._hoverLastNpcGuid
  local prevNpcName = self._hoverLastNpcName
  local cursorChanged = (cursorType ~= prevCursorType)
  local tooltipChanged = (tooltipLine2 ~= prevTooltipLine2)
  local npcGuidChanged = (npcGuid ~= prevNpcGuid)
  local npcNameChanged = (npcName ~= prevNpcName)

  self._hoverLastCursorType = cursorType
  self._hoverLastTooltipLine2 = tooltipLine2
  self._hoverLastNpcGuid = npcGuid
  self._hoverLastNpcName = npcName

  if cursorChanged then
    if self:TryTriggerBiteAlert("hover_cursor_changed") then
      return
    end
  end

  if tooltipChanged and tooltipLine2 ~= "" then
    if self:TryTriggerBiteAlert("hover_tooltip_changed") then
      return
    end
  end

  if npcGuidChanged or npcNameChanged then
    if self._debug then
      HitTools:Print(string.format(
        "Catfish hover probe npc change: %s -> %s (%s -> %s)",
        tostring(prevNpcName),
        tostring(npcName),
        tostring(prevNpcGuid),
        tostring(npcGuid)
      ))
    end
    self:TryTriggerBiteAlert("hover_npc_changed")
  end

  -- Accessibility fallback: if Blizzard provides no detectable bite signal,
  -- alert after a hover+time threshold while still fishing.
  self:TryTriggerHoverAdaptiveAlert()
end

function Catfish:ApplySoftTargetInteractCVars()
  if self._softTargetCVarCache then return end
  self._softTargetCVarCache = {
    SoftTargetInteract = getCVarSafe("SoftTargetInteract"),
    SoftTargetInteractArc = getCVarSafe("SoftTargetInteractArc"),
    SoftTargetInteractRange = getCVarSafe("SoftTargetInteractRange"),
    SoftTargetIconGameObject = getCVarSafe("SoftTargetIconGameObject"),
    SoftTargetIconInteract = getCVarSafe("SoftTargetIconInteract"),
  }

  -- Matches BetterFishing behavior to improve bobber hover interaction fidelity.
  setCVarSafe("SoftTargetInteract", 3)
  setCVarSafe("SoftTargetInteractArc", 2)
  setCVarSafe("SoftTargetInteractRange", 25)
  setCVarSafe("SoftTargetIconGameObject", 1)
  setCVarSafe("SoftTargetIconInteract", 1)
end

function Catfish:RestoreSoftTargetInteractCVars()
  local cache = self._softTargetCVarCache
  if not cache then return end
  setCVarSafe("SoftTargetInteract", cache.SoftTargetInteract or 0)
  setCVarSafe("SoftTargetInteractArc", cache.SoftTargetInteractArc or 0)
  setCVarSafe("SoftTargetInteractRange", cache.SoftTargetInteractRange or 0)
  setCVarSafe("SoftTargetIconGameObject", cache.SoftTargetIconGameObject or 0)
  setCVarSafe("SoftTargetIconInteract", cache.SoftTargetIconInteract or 0)
  self._softTargetCVarCache = nil
end

function Catfish:CanFireBiteAlert()
  if not self._fishingChannelActive then return false end
  if self._movedDuringChannel then return false end
  if self._alertActive then return false end
  if self:HasRecentLeftClick() then return false end

  local db = getCatfishDB()
  local elapsed = GetTime() - (self._fishingChannelStartedAt or 0)
  local minDelay = tonumber(db and db.minBiteDelay) or DEFAULT_MIN_BITE_DELAY
  return elapsed >= minDelay
end

function Catfish:GetAdaptiveSamples()
  local db = getCatfishDB()
  if not db then return {} end
  if type(db.adaptiveSamples) ~= "table" then
    db.adaptiveSamples = {}
  end

  local samples = db.adaptiveSamples
  local i = 1
  while i <= #samples do
    local v = tonumber(samples[i])
    if not v or v <= 0 or v > 60 then
      table.remove(samples, i)
    else
      samples[i] = v
      i = i + 1
    end
  end

  while #samples > ADAPTIVE_SAMPLE_CAP do
    table.remove(samples, 1)
  end
  return samples
end

function Catfish:RecordAdaptiveSample(elapsedSeconds)
  local db = getCatfishDB()
  if not db then return end
  local elapsed = tonumber(elapsedSeconds)
  if not elapsed then return end
  if elapsed < 2 or elapsed > 45 then return end
  local samples = self:GetAdaptiveSamples()
  table.insert(samples, elapsed)
  while #samples > ADAPTIVE_SAMPLE_CAP do
    table.remove(samples, 1)
  end

  local prevEma = tonumber(db.adaptiveEma)
  if prevEma then
    db.adaptiveEma = (prevEma * (1 - ADAPTIVE_EMA_ALPHA)) + (elapsed * ADAPTIVE_EMA_ALPHA)
  else
    db.adaptiveEma = elapsed
  end

  if self._debug then
    local predicted = self:GetAdaptivePredictiveThreshold()
    HitTools:Print(string.format(
      "Catfish adaptive sample %.2fs (n=%d, ema=%.2fs, next threshold=%.2fs)",
      elapsed,
      #samples,
      tonumber(db.adaptiveEma) or elapsed,
      predicted
    ))
  end
end

function Catfish:GetAdaptivePredictiveThreshold()
  local db = getCatfishDB()
  local minSeconds = tonumber(db and db.adaptiveMinSeconds) or DEFAULT_ADAPTIVE_MIN_SECONDS
  local maxSeconds = tonumber(db and db.adaptiveMaxSeconds) or DEFAULT_ADAPTIVE_MAX_SECONDS
  local leadSeconds = tonumber(db and db.adaptiveLeadSeconds) or DEFAULT_ADAPTIVE_LEAD_SECONDS
  local earlyOffset = tonumber(db and db.adaptiveEarlyOffset) or DEFAULT_ADAPTIVE_EARLY_OFFSET
  local bootstrapDelay = tonumber(db and db.adaptiveBootstrapDelay) or tonumber(db and db.hoverPredictiveDelay) or DEFAULT_ADAPTIVE_BOOTSTRAP_DELAY
  if minSeconds > maxSeconds then
    minSeconds, maxSeconds = maxSeconds, minSeconds
  end

  local samples = self:GetAdaptiveSamples()
  local n = #samples
  if n <= 0 then
    local fallback = clamp(bootstrapDelay, minSeconds, maxSeconds)
    self._lastAdaptiveThreshold = fallback
    return fallback
  end

  local sorted = sortedCopy(samples)
  local base
  if n == 1 then
    base = sorted[1]
  elseif n == 2 then
    base = (sorted[1] * 0.30) + (sorted[2] * 0.70)
  else
    local p45 = percentileFromSorted(sorted, 0.45) or sorted[1]
    local p60 = percentileFromSorted(sorted, 0.60) or sorted[math.ceil(n * 0.6)]
    local p75 = percentileFromSorted(sorted, 0.75) or sorted[n]
    base = (p45 * 0.15) + (p60 * 0.55) + (p75 * 0.30)
  end

  local ema = tonumber(db and db.adaptiveEma)
  if ema then
    local emaWeight = (n >= 8) and 0.30 or 0.45
    base = (base * (1 - emaWeight)) + (ema * emaWeight)
  end

  local raw = base - leadSeconds + earlyOffset
  if ema and n >= 4 then
    local antiEarlyFloor = ema - 0.25
    if raw < antiEarlyFloor then
      raw = antiEarlyFloor
    end
  end
  local threshold = clamp(raw, minSeconds, maxSeconds)
  self._lastAdaptiveThreshold = threshold
  return threshold
end

function Catfish:TryTriggerHoverAdaptiveAlert()
  local db = getCatfishDB()
  if db and db.adaptiveEnabled == false then return false end
  if self._hoverPredictiveFired then return false end
  if not self._fishingChannelActive then return false end
  if self._alertActive then return false end
  if self._movedDuringChannel then return false end
  if self:HasRecentLeftClick() then return false end
  if not self._hoverTracking then return false end

  local elapsed = GetTime() - (self._fishingChannelStartedAt or 0)
  local threshold = self:GetAdaptivePredictiveThreshold()
  if elapsed < threshold then return false end

  self._hoverPredictiveFired = true
  self._currentCastAlertElapsed = elapsed
  if self._debug then
    local n = #self:GetAdaptiveSamples()
    HitTools:Print(string.format(
      "Catfish adaptive hover trigger at %.2fs (threshold=%.2fs, n=%d)",
      elapsed, threshold, n
    ))
  end
  self:StartAlert()
  return true
end

function Catfish:AdjustAdaptiveLead(deltaToClick, wasLateNoAlert)
  local db = getCatfishDB()
  if not db then return end

  local lead = tonumber(db.adaptiveLeadSeconds) or DEFAULT_ADAPTIVE_LEAD_SECONDS
  local earlyOffset = tonumber(db.adaptiveEarlyOffset) or DEFAULT_ADAPTIVE_EARLY_OFFSET
  local changed = false
  local step = 0
  local offsetStep = 0

  if wasLateNoAlert then
    step = 0.04
    offsetStep = -0.02
    changed = true
  else
    local delta = tonumber(deltaToClick)
    if delta and delta >= 0 then
      local targetGap = 0.25
      local error = delta - targetGap
      -- Positive error means alert was too early; move lead down.
      step = clamp(-error * 0.10, -0.06, 0.06)
      if math.abs(step) >= 0.005 then
        changed = true
      end

      -- Additional anti-early bias to stop premature alerts.
      if error > 0.12 then
        offsetStep = clamp(error * 0.20, 0.0, 0.20)
        changed = true
      elseif error < -0.08 then
        offsetStep = -clamp((-error) * 0.06, 0.0, 0.05)
        changed = true
      end
    end
  end

  if not changed then return end
  lead = clamp(lead + step, 0.02, 1.5)
  earlyOffset = clamp(earlyOffset + offsetStep, 0.0, 2.5)
  db.adaptiveLeadSeconds = lead
  db.adaptiveEarlyOffset = earlyOffset
  if self._debug then
    HitTools:Print(string.format(
      "Catfish adaptive tuned: lead=%.2fs (step=%+.2f) earlyOffset=%.2fs (step=%+.2f)",
      lead,
      step,
      earlyOffset,
      offsetStep
    ))
  end
end

function Catfish:TryTriggerBiteAlert(triggerReason)
  if not self:CanFireBiteAlert() then return false end
  if self._debug then
    HitTools:Print("Catfish bite trigger: " .. tostring(triggerReason))
  end
  self:ResetFishingState()
  self:StartAlert()
  return true
end

function Catfish:OnChannelStart(unit, spellID)
  if unit ~= "player" then return end
  local fishingSpellID = getFishingSpellID()
  if spellID then
    if spellID ~= fishingSpellID and spellID ~= FISHING_SPELL_ID and spellID ~= DRAGONFLIGHT_FISHING_SPELL_ID then
      return
    end
  elseif not self:IsFishingChannel() then
    return
  end

  self:StopAlert()
  self._fishingChannelActive = true
  self._fishingChannelStartedAt = GetTime()
  self._movedDuringChannel = false
  self._currentBobberName = nil
  self._hoverTracking = false
  self._hoverLastCursorType = nil
  self._hoverLastTooltipLine2 = nil
  self._hoverLastNpcGuid = nil
  self._hoverLastNpcName = nil
  self._hoverPredictiveFired = false
  self._currentCastAlertElapsed = nil
  self:ApplySoftTargetInteractCVars()
end

function Catfish:OnChannelStop(unit)
  if unit ~= "player" then return end
  if not self._fishingChannelActive then return end
  local elapsed = math.max(0, GetTime() - (self._fishingChannelStartedAt or 0))
  local stopAt = GetTime()
  local hadRecentClick = self:HasRecentLeftClick()
  local alertElapsed = tonumber(self._currentCastAlertElapsed)
  local alertDelta = (alertElapsed and elapsed >= alertElapsed) and (elapsed - alertElapsed) or nil

  -- In many clients this stop happens only after clicking the bobber.
  -- Keep it as fallback, but suppress if there was a very recent click.
  if self:CanFireBiteAlert() then
    if self._debug then
      HitTools:Print("Catfish channel-stop fallback trigger")
    end
    self:ResetFishingState(true)
    self._pendingStopElapsed = elapsed
    self._pendingStopAt = stopAt
    self:StartAlert()
  else
    if self._debug then
      HitTools:Print("Catfish channel-stop ignored (likely manual click/cancel)")
    end
    self:ResetFishingState(true)
    self._pendingStopElapsed = elapsed
    self._pendingStopAt = stopAt
  end

  self._pendingLeadDelta = alertDelta
  self._pendingLeadLateNoAlert = (alertDelta == nil and hadRecentClick) and true or false
end

function Catfish:OnSpellInterrupted(unit)
  if unit ~= "player" then return end
  self._pendingStopElapsed = nil
  self._pendingStopAt = 0
  self._pendingLeadDelta = nil
  self._pendingLeadLateNoAlert = false
  self:ResetFishingState()
end

function Catfish:OnLootOpened()
  if self._alertActive then
    self:StopAlert()
  end

  local pendingElapsed = tonumber(self._pendingStopElapsed)
  local pendingAt = tonumber(self._pendingStopAt) or 0
  local pendingLeadDelta = tonumber(self._pendingLeadDelta)
  local pendingLeadLateNoAlert = self._pendingLeadLateNoAlert and true or false
  self._pendingStopElapsed = nil
  self._pendingStopAt = 0
  self._pendingLeadDelta = nil
  self._pendingLeadLateNoAlert = false

  if not pendingElapsed or pendingAt <= 0 then
    if self._debug then
      HitTools:Print("Catfish loot-open: no pending sample to record")
    end
    return
  end
  if (GetTime() - pendingAt) > 8.0 then
    if self._debug then
      HitTools:Print("Catfish loot-open: pending sample too old, skipped")
    end
    return
  end
  self:RecordAdaptiveSample(pendingElapsed)
  if pendingLeadDelta then
    self:AdjustAdaptiveLead(pendingLeadDelta, false)
  elseif pendingLeadLateNoAlert then
    self:AdjustAdaptiveLead(nil, true)
  end
end

function Catfish:OnCombatLogEvent()
  if not CombatLogGetCurrentEventInfo then return end

  local playerGUID = UnitGUID and UnitGUID("player")
  if not playerGUID then return end

  local _, subevent, _, sourceGUID, sourceName, _, _, destGUID, destName, _, _, spellId, spellName = CombatLogGetCurrentEventInfo()
  if not subevent then return end
  local isFishingSpell = (spellId == getFishingSpellID() or spellId == FISHING_SPELL_ID or spellId == DRAGONFLIGHT_FISHING_SPELL_ID or spellName == getFishingSpellName())
  local isPlayerRelated = (sourceGUID == playerGUID or destGUID == playerGUID)
  local isPlayerSource = (sourceGUID == playerGUID)
  local isBobberName = (destName and tostring(destName):find("Fishing Bobber"))

  if self._debug and subevent:match("^SPELL") and (isPlayerRelated or (isPlayerSource and isBobberName)) then
    local elapsed = GetTime() - (self._fishingChannelStartedAt or 0)
    HitTools:Print(string.format(
      "Catfish CLEU: %s | spell=%s(%s) | src=%s dst=%s | t=%.2fs",
      tostring(subevent),
      tostring(spellName),
      tostring(spellId),
      tostring(sourceName),
      tostring(destName),
      elapsed
    ))
  end

  -- Build state from CLEU too (covers clients where channel events are inconsistent).
  if subevent == "SPELL_AURA_APPLIED" and isFishingSpell and isPlayerRelated then
    self._fishingChannelActive = true
    self._fishingChannelStartedAt = GetTime()
    self._movedDuringChannel = false
    self:ApplySoftTargetInteractCVars()
    if self._debug then
      HitTools:Print("Catfish CLEU state: fishing active (aura applied)")
    end
    return
  end

  if subevent == "SPELL_CREATE" and isFishingSpell and isPlayerSource then
    if destName and destName ~= "" then
      self._currentBobberName = destName
    end
    if not self._fishingChannelActive then
      self._fishingChannelActive = true
      self._fishingChannelStartedAt = GetTime()
      self._movedDuringChannel = false
      self:ApplySoftTargetInteractCVars()
      if self._debug then
        HitTools:Print("Catfish CLEU state: fishing active (spell create)")
      end
    end
    return
  end

  if not self._fishingChannelActive then return end

  -- Clients that expose bite-like events can emit SPELL_SPLASH around bobber bob.
  if subevent == "SPELL_SPLASH" then
    if isPlayerRelated or isBobberName then
      self:TryTriggerBiteAlert("combatlog_splash")
    end
    return
  end

  if subevent == "SPELL_AURA_REMOVED" and isFishingSpell and isPlayerRelated then
    self:TryTriggerBiteAlert("combatlog_aura_removed")
    return
  end

  if subevent == "SPELL_CAST_SUCCESS" or subevent == "SPELL_MISSED" then
    if isPlayerRelated and isFishingSpell then
      self:TryTriggerBiteAlert("combatlog_fishing")
    end
  end
end

function Catfish:OnEvent(event, ...)
  if event == "PLAYER_ENTERING_WORLD" then
    self:ResetFishingState()
    self:StopAlert()
    return
  end

  if event == "PLAYER_STARTED_MOVING" then
    if self._fishingChannelActive then
      self._movedDuringChannel = true
    end
    return
  end

  if event == "UNIT_SPELLCAST_CHANNEL_START" then
    local unit, _, spellID = ...
    self:OnChannelStart(unit, spellID)
    return
  end

  if event == "UNIT_SPELLCAST_CHANNEL_STOP" then
    local unit = ...
    self:OnChannelStop(unit)
    return
  end

  if event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" then
    local unit = ...
    self:OnSpellInterrupted(unit)
    return
  end

  if event == "COMBAT_LOG_EVENT_UNFILTERED" then
    self:OnCombatLogEvent()
    return
  end

  if event == "LOOT_OPENED" then
    self:OnLootOpened()
    return
  end
end

function Catfish:OnUpdate(elapsed)
  if self._pendingStopAt and self._pendingStopAt > 0 and (GetTime() - self._pendingStopAt) > 12.0 then
    self._pendingStopElapsed = nil
    self._pendingStopAt = 0
    self._pendingLeadDelta = nil
    self._pendingLeadLateNoAlert = false
  end

  if self._fishingChannelActive then
    self:UpdateHoverBiteProbe()
  end

  if not self._alertActive then return end

  local db = getCatfishDB()
  local timeout = tonumber(db and db.alertTimeout) or DEFAULT_ALERT_TIMEOUT
  self._alertElapsed = (self._alertElapsed or 0) + (tonumber(elapsed) or 0)
  if self._alertElapsed >= timeout then
    self:StopAlert()
    return
  end

  local frame = self._glowFrame
  if not frame then return end
  if not frame:IsShown() then frame:Show() end

  local pulseSpeed = tonumber(db and db.pulseSpeed) or 2.2
  local pulseAmount = tonumber(db and db.pulseAmount) or 0.16
  local baseScale = tonumber(db and db.glowScale) or 1.0

  local pulse = 1.0 + (math.sin(GetTime() * pulseSpeed * math.pi * 2) * pulseAmount)
  local finalScale = baseScale * pulse

  local baseSizes = {110, 78, 48}
  local baseAlphas = {0.16, 0.24, 0.32}
  local alphaPulse = 0.85 + 0.15 * math.sin(GetTime() * pulseSpeed * math.pi * 2)

  for i, ring in ipairs(frame.rings or {}) do
    local size = baseSizes[i] * finalScale
    local alpha = baseAlphas[i] * alphaPulse
    ring:SetSize(size, size)
    ring:SetAlpha(alpha)
  end
end

function Catfish:Enable()
  local db = getCatfishDB()
  if not db then return end
  db.enabled = true
end

function Catfish:Disable()
  local db = getCatfishDB()
  if not db then return end
  db.enabled = false
  self:ResetFishingState()
  self:StopAlert()
end

function Catfish:HandleCommand(args)
  local db = getCatfishDB()
  if not db then return end

  args = (args or ""):lower():trim()

  if args == "on" then
    self:Enable()
    HitTools:Print("Catfish enabled")
    return
  end

  if args == "off" then
    self:Disable()
    HitTools:Print("Catfish disabled")
    return
  end

  if args == "test" then
    self:StartAlert()
    HitTools:Print("Catfish test alert started")
    return
  end

  if args == "debug on" then
    self._debug = true
    HitTools:Print("Catfish debug: ON")
    return
  end

  if args == "debug off" then
    self._debug = false
    HitTools:Print("Catfish debug: OFF")
    return
  end

  local adaptiveToggle = args:match("^adaptive%s+(%S+)$")
  if adaptiveToggle == "on" or adaptiveToggle == "off" then
    db.adaptiveEnabled = (adaptiveToggle == "on")
    HitTools:Print("Catfish adaptive model: " .. (db.adaptiveEnabled and "ON" or "OFF"))
    return
  end

  if args == "adaptive reset" then
    db.adaptiveSamples = {}
    db.adaptiveEma = nil
    db.adaptiveEarlyOffset = 0
    db.adaptiveLeadSeconds = DEFAULT_ADAPTIVE_LEAD_SECONDS
    self._lastAdaptiveThreshold = nil
    HitTools:Print("Catfish adaptive history reset")
    return
  end

  local delayVal = args:match("^delay%s+(%S+)")
  if delayVal then
    local num = tonumber(delayVal)
    if num and num >= 1 and num <= 60 then
      db.adaptiveBootstrapDelay = num
      HitTools:Print(string.format("Catfish adaptive bootstrap delay set to %.1fs", num))
    else
      HitTools:Print("Invalid delay. Use: /hit catfish delay <1-60>")
    end
    return
  end

  local leadVal = args:match("^lead%s+(%S+)")
  if leadVal then
    local num = tonumber(leadVal)
    if num and num >= 0 and num <= 3 then
      db.adaptiveLeadSeconds = num
      HitTools:Print(string.format("Catfish adaptive lead set to %.2fs", num))
    else
      HitTools:Print("Invalid lead. Use: /hit catfish lead <0-3>")
    end
    return
  end

  local minVal = args:match("^min%s+(%S+)")
  if minVal then
    local num = tonumber(minVal)
    if num and num >= 2 and num <= 40 then
      db.adaptiveMinSeconds = num
      HitTools:Print(string.format("Catfish adaptive min set to %.1fs", num))
    else
      HitTools:Print("Invalid min. Use: /hit catfish min <2-40>")
    end
    return
  end

  local maxVal = args:match("^max%s+(%S+)")
  if maxVal then
    local num = tonumber(maxVal)
    if num and num >= 3 and num <= 45 then
      db.adaptiveMaxSeconds = num
      HitTools:Print(string.format("Catfish adaptive max set to %.1fs", num))
    else
      HitTools:Print("Invalid max. Use: /hit catfish max <3-45>")
    end
    return
  end

  local threshold = self:GetAdaptivePredictiveThreshold()
  local sampleCount = #self:GetAdaptiveSamples()

  HitTools:Print(string.format(
    "Catfish: %s | Double-click cast: %s | Bobber alert: %s | Sound: %s | Adaptive: %s | Threshold: %.2fs | Lead: %.2fs | EarlyOffset: %.2fs | Samples: %d | Debug: %s",
    db.enabled ~= false and "ON" or "OFF",
    db.doubleClickCast ~= false and "ON" or "OFF",
    db.bobberAlert ~= false and "ON" or "OFF",
    db.playSound ~= false and "ON" or "OFF",
    db.adaptiveEnabled ~= false and "ON" or "OFF",
    threshold,
    tonumber(db.adaptiveLeadSeconds) or DEFAULT_ADAPTIVE_LEAD_SECONDS,
    tonumber(db.adaptiveEarlyOffset) or DEFAULT_ADAPTIVE_EARLY_OFFSET,
    sampleCount,
    self._debug and "ON" or "OFF"
  ))
  HitTools:Print("Commands: /hit catfish on|off|test|debug on|off|adaptive on|off|adaptive reset|delay <1-60>|lead <0-3>|min <2-40>|max <3-45>")
end

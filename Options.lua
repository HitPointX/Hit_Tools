local _, HitTools = ...

local ADDON_OPTIONS_NAME = "Hit-Tools"

-- StaticPopup for Baggy reload prompt
StaticPopupDialogs["HITTOOLS_BAGGY_RELOAD"] = {
  text = "Required to reload UI. Reload now?",
  button1 = "Yes",
  button2 = "No",
  OnAccept = function()
    ReloadUI()
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

local uid = 0
local function nextName(prefix)
  uid = uid + 1
  return string.format("HitTools_%s_%d", prefix, uid)
end

local function createCheck(parent, label, tooltip, onClick)
  local name = nextName("Check")
  local cb = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
  local textRegion = _G[name .. "Text"] or cb.Text or cb.text
  if textRegion and textRegion.SetText then
    textRegion:SetText(label)
  end
  cb.tooltipText = tooltip
  cb:SetScript("OnClick", function(self)
    local onSound = (SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON) or "igMainMenuOptionCheckBoxOn"
    local offSound = (SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF) or "igMainMenuOptionCheckBoxOff"
    PlaySound(self:GetChecked() and onSound or offSound)
    onClick(self:GetChecked() and true or false)
  end)
  return cb
end

local function createButton(parent, label, width, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetText(label)
  b:SetSize(width or 160, 22)
  b:SetScript("OnClick", onClick)
  return b
end

local function createSlider(parent, name, label, minValue, maxValue, step, onValueChanged)
  local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
  s:SetMinMaxValues(minValue, maxValue)
  s:SetValueStep(step)
  if s.SetObeyStepOnDrag then
    s:SetObeyStepOnDrag(true)
  end

  local low = _G[name .. "Low"]
  local high = _G[name .. "High"]
  local text = _G[name .. "Text"]
  if low and low.SetText then low:SetText(tostring(minValue)) end
  if high and high.SetText then high:SetText(tostring(maxValue)) end
  if text and text.SetText then text:SetText(label) end

  s:SetScript("OnValueChanged", function(_, value)
    value = tonumber(value) or minValue
    value = math.floor(value + 0.5)
    onValueChanged(value)
  end)

  return s
end

local function createEditBox(parent, width, onCommit)
  local eb = CreateFrame("EditBox", nextName("Edit"), parent, "InputBoxTemplate")
  eb:SetSize(width, 20)
  eb:SetAutoFocus(false)
  eb:SetScript("OnEnterPressed", function(self)
    onCommit(self:GetText() or "")
    self:ClearFocus()
  end)
  eb:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
  end)
  return eb
end

local function applyAMarkSettingsChanged()
  if HitTools.AMark and HitTools.AMark.OnSettingChanged then
    HitTools.AMark:OnSettingChanged()
  end
end

local function ensureInterfaceOptionsContainer(panel)
  if InterfaceOptionsFramePanelContainer and panel:GetParent() ~= InterfaceOptionsFramePanelContainer then
    panel:SetParent(InterfaceOptionsFramePanelContainer)
  end
end

local function tryRegisterWithSettings(panel)
  if panel._hitToolsSettingsRegistered then
    return true
  end
  if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then
    return false
  end

  local categoryName = panel.name or ADDON_OPTIONS_NAME
  local ok, category = pcall(Settings.RegisterCanvasLayoutCategory, panel, categoryName)
  if not ok or not category then
    return false
  end

  -- Most addons on this client force a stable string ID so `Settings.GetCategory("Name")` works.
  pcall(function() category.ID = categoryName end)
  pcall(Settings.RegisterAddOnCategory, category)

  panel._hitToolsSettingsRegistered = true
  panel._hitToolsSettingsCategory = category
  HitTools.OptionsCategoryID = category.ID or categoryName
  return true
end

local function tryRegisterWithInterfaceOptions(panel)
  local registerFn = InterfaceOptions_AddCategory or InterfaceOptionsFrame_AddCategory
  if not registerFn then
    return false
  end

  ensureInterfaceOptionsContainer(panel)

  local ok = pcall(registerFn, panel)
  if not ok then
    -- Some clients wrap this API and accept an optional addon name.
    ok = pcall(registerFn, panel, panel.name or ADDON_OPTIONS_NAME)
  end
  return ok and true or false
end

local function tryRegister(panel)
  -- Prefer Settings API when present; it's what Questie/RXPGuides use on this client.
  if tryRegisterWithSettings(panel) then
    return true
  end
  return tryRegisterWithInterfaceOptions(panel)
end

local function after(delaySeconds, fn)
  if C_Timer and C_Timer.After then
    C_Timer.After(delaySeconds, fn)
    return
  end

  local f = CreateFrame("Frame")
  local elapsed = 0
  f:SetScript("OnUpdate", function(self, dt)
    elapsed = elapsed + (dt or 0)
    if elapsed < delaySeconds then return end
    self:SetScript("OnUpdate", nil)
    fn()
  end)
end

function HitTools:EnsureOptionsRegistered()
  if not self.Options then
    return false
  end
  if self.OptionsRegistered then
    return true
  end

  if tryRegister(self.Options) then
    self.OptionsRegistered = true
    return true
  end

  if not self._optionsRegistrar then
    local f = CreateFrame("Frame")
    self._optionsRegistrar = f
    f:RegisterEvent("ADDON_LOADED")
    f:RegisterEvent("PLAYER_LOGIN")

    local elapsedTotal = 0
    f:SetScript("OnEvent", function()
      if HitTools.Options and tryRegister(HitTools.Options) then
        HitTools.OptionsRegistered = true
        f:UnregisterAllEvents()
        f:SetScript("OnUpdate", nil)
      end
    end)

    f:SetScript("OnUpdate", function(_, elapsed)
      elapsedTotal = elapsedTotal + (elapsed or 0)
      if elapsedTotal < 0.25 then return end
      elapsedTotal = 0
      if HitTools.Options and tryRegister(HitTools.Options) then
        HitTools.OptionsRegistered = true
        f:UnregisterAllEvents()
        f:SetScript("OnUpdate", nil)
      end
    end)
  end

  return false
end

function HitTools:OpenOptions()
  if self.CreateOptions and not self.Options then
    self:CreateOptions()
  end

  self:EnsureOptionsRegistered()

  local optionsName = (self.Options and self.Options.name) or ADDON_OPTIONS_NAME
  local settingsID = self.OptionsCategoryID or optionsName

  if Settings and Settings.OpenToCategory then
    local category = Settings.GetCategory and Settings.GetCategory(settingsID) or nil
    if category and category.HasSubcategories and category:HasSubcategories() then
      category.expanded = true
    end
    local ok = pcall(Settings.OpenToCategory, (category and category.ID) or settingsID)
    if ok then
      return
    end
  end

  if not InterfaceOptionsFrame_OpenToCategory then
    return
  end

  InterfaceOptionsFrame_OpenToCategory(optionsName)
  InterfaceOptionsFrame_OpenToCategory(optionsName)
  if self.Options then
    InterfaceOptionsFrame_OpenToCategory(self.Options)
  end
end

function HitTools:CreateOptions()
  if self.Options then
    self:EnsureOptionsRegistered()
    return
  end

  local parent = SettingsPanel or InterfaceOptionsFramePanelContainer or InterfaceOptionsFrame or UIParent
  local panel = CreateFrame("Frame", "HitToolsOptionsPanel", parent)
  panel.name = ADDON_OPTIONS_NAME
  panel.okay = function() end
  panel.cancel = function() end
  panel.default = function() end
  panel.refresh = function() end
  panel.OnCommit = panel.okay
  panel.OnDefault = panel.default
  panel.OnRefresh = panel.refresh

  local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText(ADDON_OPTIONS_NAME)

  local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
  subtitle:SetText("Configuration for XPRate, Alerts, Instance Tracking, and AMark.")

  local tabsAnchor = CreateFrame("Frame", nil, panel)
  tabsAnchor:SetSize(560, 24)
  tabsAnchor:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -14)

  local xpratePage = CreateFrame("Frame", nil, panel)
  xpratePage:SetPoint("TOPLEFT", tabsAnchor, "BOTTOMLEFT", 0, -10)
  xpratePage:SetSize(560, 520)

  local amarkPage = CreateFrame("Frame", nil, panel)
  amarkPage:SetPoint("TOPLEFT", tabsAnchor, "BOTTOMLEFT", 0, -10)
  amarkPage:SetSize(560, 520)

  local instancePage = CreateFrame("Frame", nil, panel)
  instancePage:SetPoint("TOPLEFT", tabsAnchor, "BOTTOMLEFT", 0, -10)
  instancePage:SetSize(560, 520)

  local alertsPage = CreateFrame("Frame", nil, panel)
  alertsPage:SetPoint("TOPLEFT", tabsAnchor, "BOTTOMLEFT", 0, -10)
  alertsPage:SetSize(560, 520)

  local extraPage = CreateFrame("Frame", nil, panel)
  extraPage:SetPoint("TOPLEFT", tabsAnchor, "BOTTOMLEFT", 0, -10)
  extraPage:SetSize(560, 520)

  local tabs = {}
  local function setTab(tabName)
    xpratePage:SetShown(tabName == "xprate")
    amarkPage:SetShown(tabName == "amark")
    instancePage:SetShown(tabName == "instance")
    alertsPage:SetShown(tabName == "alerts")
    extraPage:SetShown(tabName == "extra")
    tabs.xprate:Enable(tabName ~= "xprate")
    tabs.amark:Enable(tabName ~= "amark")
    tabs.instance:Enable(tabName ~= "instance")
    tabs.alerts:Enable(tabName ~= "alerts")
    tabs.extra:Enable(tabName ~= "extra")
  end

  tabs.xprate = createButton(tabsAnchor, "XPRate", 100, function() setTab("xprate") end)
  tabs.xprate:SetPoint("TOPLEFT", tabsAnchor, "TOPLEFT", 0, 0)

  tabs.amark = createButton(tabsAnchor, "AMark", 100, function() setTab("amark") end)
  tabs.amark:SetPoint("LEFT", tabs.xprate, "RIGHT", 8, 0)

  tabs.instance = createButton(tabsAnchor, "Instance", 100, function() setTab("instance") end)
  tabs.instance:SetPoint("LEFT", tabs.amark, "RIGHT", 8, 0)

  tabs.alerts = createButton(tabsAnchor, "Alerts", 100, function() setTab("alerts") end)
  tabs.alerts:SetPoint("LEFT", tabs.instance, "RIGHT", 8, 0)

  tabs.extra = createButton(tabsAnchor, "Extra", 100, function() setTab("extra") end)
  tabs.extra:SetPoint("LEFT", tabs.alerts, "RIGHT", 8, 0)

  local xprateHeader = xpratePage:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  xprateHeader:SetPoint("TOPLEFT", xpratePage, "TOPLEFT", 0, 0)
  xprateHeader:SetText("XPRate")

  local chatEnabled = createCheck(xpratePage, "Show details in chat", "Print summaries and quick info to chat.", function(v)
    HitTools.DB.chat.enabled = v
  end)
  chatEnabled:SetPoint("TOPLEFT", xprateHeader, "BOTTOMLEFT", -2, -10)

  local dungeonSummary = createCheck(xpratePage, "Dungeon summaries in chat", "Print a summary when you leave a dungeon.", function(v)
    HitTools.DB.chat.dungeonSummary = v
  end)
  dungeonSummary:SetPoint("TOPLEFT", chatEnabled, "BOTTOMLEFT", 0, -8)

  local uiEnabled = createCheck(xpratePage, "Show UI frame", "Show a small on-screen frame with XP/hr and time to level.", function(v)
    HitTools.DB.ui.enabled = v
    HitTools:ApplyUIEnabled()
  end)
  uiEnabled:SetPoint("TOPLEFT", dungeonSummary, "BOTTOMLEFT", 0, -14)

  local uiLocked = createCheck(xpratePage, "Lock UI frame", "Prevent dragging the UI frame.", function(v)
    HitTools.DB.ui.locked = v
    HitTools:ApplyUILock()
  end)
  uiLocked:SetPoint("TOPLEFT", uiEnabled, "BOTTOMLEFT", 0, -8)

  -- ISSUE D FIX: Party output toggle
  local xpOutputToParty = createCheck(xpratePage, "Send run summary to party/raid chat", "When a dungeon ends, also send a summary message to party or raid chat.", function(v)
    HitTools.DB.xpRate.outputToParty = v
  end)
  xpOutputToParty:SetPoint("TOPLEFT", uiLocked, "BOTTOMLEFT", 0, -8)

  -- ISSUE B FIX: Finalize mode dropdown label
  local finalizeModeLabel = xpratePage:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  finalizeModeLabel:SetPoint("TOPLEFT", xpOutputToParty, "BOTTOMLEFT", 0, -10)
  finalizeModeLabel:SetText("Run finalization timing:")

  -- Finalize mode buttons (simple toggle between modes)
  local finalizeInfo = xpratePage:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  finalizeInfo:SetPoint("TOPLEFT", finalizeModeLabel, "BOTTOMLEFT", 20, -8)
  finalizeInfo:SetWidth(300)
  finalizeInfo:SetJustifyH("LEFT")
  finalizeInfo:SetText("Smart: Quick finish when leaving instance\nGrace: Wait 30s after leaving\nInstant: Finalize immediately (testing only)")

  local reset = createButton(xpratePage, "Reset dungeon stats", 180, function()
    HitTools:ResetDungeonStats()
  end)
  reset:SetPoint("TOPLEFT", finalizeInfo, "BOTTOMLEFT", -16, -12)

  local instanceHeader = instancePage:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  instanceHeader:SetPoint("TOPLEFT", instancePage, "TOPLEFT", 0, 0)
  instanceHeader:SetText("Instance Tracking")

  local instEnabled = createCheck(instancePage, "Enable instance tracking", "Print a detailed summary when you truly leave a 5-player dungeon (with guardrails for corpse runs / quick re-entry).", function(v)
    HitTools.DB.features.instanceTracking = v
    HitTools:CheckDungeonTransition()
    if HitTools.UI and HitTools.UI.UpdateText then
      HitTools.UI:UpdateText()
    end
  end)
  instEnabled:SetPoint("TOPLEFT", instanceHeader, "BOTTOMLEFT", -2, -10)

  local resetPopup = createCheck(instancePage, "Reset popup (leader)", "When you leave a dungeon, show a popup to reset the instance (only if you're group leader).", function(v)
    HitTools.DB.features.instanceResetPopup = v
  end)
  resetPopup:SetPoint("TOPLEFT", instEnabled, "BOTTOMLEFT", 0, -8)

  local stepsNote = instancePage:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  stepsNote:SetPoint("TOPLEFT", resetPopup, "BOTTOMLEFT", 4, -10)
  stepsNote:SetText("Footsteps are estimated from time moving: walk=2.5 yds/sec, run=7 yds/sec.")

  local alertsHeader = alertsPage:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  alertsHeader:SetPoint("TOPLEFT", alertsPage, "TOPLEFT", 0, 0)
  alertsHeader:SetText("Alerts")

  local alertsEnabled = createCheck(alertsPage, "Enable alerts", "Master toggle for all Hit-Tools alerts.", function(v)
    HitTools.DB.alerts.enabled = v
    if HitTools.UpdateHealerOOMAlert then
      HitTools:UpdateHealerOOMAlert()
    end
  end)
  alertsEnabled:SetPoint("TOPLEFT", alertsHeader, "BOTTOMLEFT", -2, -10)

  local healerOOMEnabled = createCheck(alertsPage, "Healer OOM (<5% mana)", "Show a top-screen flashing alert when your healer is below 5% mana.", function(v)
    HitTools.DB.alerts.healerOOM = v
    if HitTools.UpdateHealerOOMAlert then
      HitTools:UpdateHealerOOMAlert()
    end
  end)
  healerOOMEnabled:SetPoint("TOPLEFT", alertsEnabled, "BOTTOMLEFT", 0, -8)

  local muteAlertSounds = createCheck(alertsPage, "Mute alert sounds", "Disable all Hit-Tools alert sounds.", function(v)
    HitTools.DB.alerts.soundEnabled = not v
  end)
  muteAlertSounds:SetPoint("TOPLEFT", healerOOMEnabled, "BOTTOMLEFT", 0, -8)

  local alertSoundVolume = createSlider(alertsPage, "HitToolsAlertSoundVolumeSlider", "Alert sound volume (1-10)", 1, 10, 1, function(v)
    HitTools.DB.alerts.soundVolume = v
    if alertsPage._volumeValue then
      alertsPage._volumeValue:SetText(string.format("%d (%d%%)", v, v * 10))
    end
  end)
  alertSoundVolume:SetPoint("TOPLEFT", muteAlertSounds, "BOTTOMLEFT", 6, -20)
  alertSoundVolume:SetWidth(260)

  local volumeValue = alertsPage:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  volumeValue:SetPoint("LEFT", alertSoundVolume, "RIGHT", 10, 0)
  volumeValue:SetText("10 (100%)")
  alertsPage._volumeValue = volumeValue

  local alertsNote = alertsPage:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  alertsNote:SetPoint("TOPLEFT", alertSoundVolume, "BOTTOMLEFT", -2, -8)
  alertsNote:SetText("Style: animated wave text at top-center, flashing white/red + meow.ogg once per OOM event.")

  local amarkHeader = amarkPage:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  amarkHeader:SetPoint("TOPLEFT", amarkPage, "TOPLEFT", 0, 0)
  amarkHeader:SetText("AMark")

  local amarkEnabled = createCheck(amarkPage, "Enable AMark (auto-mark packs)", "Marks the current pull around your target.", function(v)
    HitTools.DB.amark.enabled = v
    applyAMarkSettingsChanged()
  end)
  amarkEnabled:SetPoint("TOPLEFT", amarkHeader, "BOTTOMLEFT", -2, -10)

  local amarkCount = createSlider(amarkPage, "HitToolsAMarkCountSlider", "Mobs to mark (1-5)", 1, 5, 1, function(v)
    HitTools.DB.amark.count = v
    applyAMarkSettingsChanged()
  end)
  amarkCount:SetPoint("TOPLEFT", amarkEnabled, "BOTTOMLEFT", 6, -22)
  amarkCount:SetWidth(220)

  local amarkParty = createCheck(amarkPage, "Enable in party", "Allow AMark in 5-player parties.", function(v)
    HitTools.DB.amark.allowInParty = v
    applyAMarkSettingsChanged()
  end)
  amarkParty:SetPoint("TOPLEFT", amarkCount, "BOTTOMLEFT", -8, -16)

  local amarkRaid = createCheck(amarkPage, "Enable in raid", "Allow AMark in raids.", function(v)
    HitTools.DB.amark.allowInRaid = v
    applyAMarkSettingsChanged()
  end)
  amarkRaid:SetPoint("TOPLEFT", amarkParty, "BOTTOMLEFT", 0, -8)

  local amarkSolo = createCheck(amarkPage, "Enable solo", "Allow AMark when not grouped.", function(v)
    HitTools.DB.amark.allowSolo = v
    applyAMarkSettingsChanged()
  end)
  amarkSolo:SetPoint("TOPLEFT", amarkRaid, "BOTTOMLEFT", 0, -8)

  local amarkTankOnly = createCheck(amarkPage, "Tank-only mode", "Only mark when your role/class is tank-capable.", function(v)
    HitTools.DB.amark.tankOnly = v
    applyAMarkSettingsChanged()
  end)
  amarkTankOnly:SetPoint("TOPLEFT", amarkSolo, "BOTTOMLEFT", 0, -8)

  local amarkAnnounce = createCheck(amarkPage, "Announce kill order on zone-in", "Send one party/raid message with current AMark kill order when entering an instance with your group. Won't resend from party roster churn inside the same instance session.", function(v)
    HitTools.DB.amark.announceKillOrderOnZoneIn = v
    applyAMarkSettingsChanged()
  end)
  amarkAnnounce:SetPoint("TOPLEFT", amarkTankOnly, "BOTTOMLEFT", 0, -8)

  local prioLabel = amarkPage:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  prioLabel:SetPoint("TOPLEFT", amarkAnnounce, "BOTTOMLEFT", 2, -16)
  prioLabel:SetText("Priority after skull (4 icons):")

  local prioHelp = amarkPage:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  prioHelp:SetPoint("TOPLEFT", prioLabel, "BOTTOMLEFT", 0, -2)
  prioHelp:SetText("Example: x triangle moon square")

  local amarkPriority = createEditBox(amarkPage, 240, function(text)
    HitTools.DB.amark.priorityAfterSkull = text
    applyAMarkSettingsChanged()
  end)
  amarkPriority:SetPoint("TOPLEFT", prioHelp, "BOTTOMLEFT", -4, -8)

  local prioReset = createButton(amarkPage, "Reset AMark priority", 180, function()
    HitTools.DB.amark.priorityAfterSkull = "x triangle moon square"
    amarkPriority:SetText(HitTools.DB.amark.priorityAfterSkull)
    applyAMarkSettingsChanged()
  end)
  prioReset:SetPoint("TOPLEFT", amarkPriority, "BOTTOMLEFT", 4, -10)

  -- Extra tab content
  local extraHeader = extraPage:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  extraHeader:SetPoint("TOPLEFT", extraPage, "TOPLEFT", 0, 0)
  extraHeader:SetText("Extra Features")

  local cursorGrowEnabled = createCheck(extraPage, "Enable cursor finder/growth", "Makes your cursor grow larger when you move it quickly, making it easier to find.", function(v)
    HitTools.DB.cursorGrow.enabled = v
    if HitTools.CursorGrow then
      if v then
        HitTools.CursorGrow:Enable()
      else
        HitTools.CursorGrow:Disable()
      end
    end
  end)
  cursorGrowEnabled:SetPoint("TOPLEFT", extraHeader, "BOTTOMLEFT", -2, -10)

  local cursorGrowInfo = extraPage:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  cursorGrowInfo:SetPoint("TOPLEFT", cursorGrowEnabled, "BOTTOMLEFT", 20, -8)
  cursorGrowInfo:SetWidth(400)
  cursorGrowInfo:SetJustifyH("LEFT")
  cursorGrowInfo:SetText("When enabled, your mouse cursor will grow larger when you move it quickly,\nmaking it easier to locate during combat or when switching between windows.")

  local catfishEnabled = createCheck(extraPage, "Enable Catfish (fishing helper)", "Double-left-click in the world to cast Fishing, and show bobber bite alerts with glow + meow sound.", function(v)
    if not HitTools.DB.catfish then
      HitTools.DB.catfish = {
        enabled = true,
        doubleClickCast = true,
        bobberAlert = true,
        playSound = true,
        doubleClickWindow = 0.35,
        minBiteDelay = 1.5,
        hoverPredictiveDelay = 8.0,
        adaptiveEnabled = true,
        adaptiveBootstrapDelay = 8.0,
        adaptiveMinSeconds = 4.0,
        adaptiveMaxSeconds = 18.0,
        adaptiveLeadSeconds = 0.35,
        adaptiveSamples = {},
        alertTimeout = 8.0,
        pulseSpeed = 2.2,
        pulseAmount = 0.16,
        glowScale = 1.0,
      }
    end
    HitTools.DB.catfish.enabled = v
    if HitTools.Catfish then
      if v then
        HitTools.Catfish:Enable()
      else
        HitTools.Catfish:Disable()
      end
    end
  end)
  catfishEnabled:SetPoint("TOPLEFT", cursorGrowInfo, "BOTTOMLEFT", -20, -16)

  local catfishInfo = extraPage:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  catfishInfo:SetPoint("TOPLEFT", catfishEnabled, "BOTTOMLEFT", 20, -8)
  catfishInfo:SetWidth(400)
  catfishInfo:SetJustifyH("LEFT")
  catfishInfo:SetText("Catfish adds a fishing flow helper: double-left-click to cast Fishing,\nand a pulsing transparent glow + meow alert when a fish bites.")

  -- Baggy settings
  local baggyEnabled = createCheck(extraPage, "Enable Baggy (unified bag UI)", "Replaces default bags with a single unified bag window with search, sorting, and rainbow effects.", function(v)
    HitTools.DB.baggy.enabled = v
    -- Show reload prompt popup
    StaticPopup_Show("HITTOOLS_BAGGY_RELOAD")
  end)
  baggyEnabled:SetPoint("TOPLEFT", catfishInfo, "BOTTOMLEFT", -20, -16)

  local baggyInfo = extraPage:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  baggyInfo:SetPoint("TOPLEFT", baggyEnabled, "BOTTOMLEFT", 20, -8)
  baggyInfo:SetWidth(400)
  baggyInfo:SetJustifyH("LEFT")
  baggyInfo:SetText("Baggy shows all your bags in a single unified window with search, sorting (rarity, alphabetical, type, newest),\nand plays a rainbow border effect when you loot rare or epic items. Press B to toggle.")

  -- Scrapya settings
  local refreshScrapyaControls

  local scrapyaEnabled = createCheck(extraPage, "Enable Scrapya (auto-sell junk)", "Automatically sells grey items when you open a vendor. Hold Shift while opening vendor to skip once.", function(v)
    if not HitTools.DB.scrapya then
      HitTools.DB.scrapya = {
        enabled = true,
        showSummary = true,
        shiftBypass = true,
        sellInterval = 0.2,
        maxPasses = 40,
        sellNonPrimarySoulbound = false,
      }
    end
    HitTools.DB.scrapya.enabled = v
    if not v and HitTools.Scrapya and HitTools.Scrapya.StopSelling then
      HitTools.Scrapya:StopSelling("disabled_option")
    end
    if refreshScrapyaControls then
      refreshScrapyaControls()
    end
  end)
  scrapyaEnabled:SetPoint("TOPLEFT", baggyInfo, "BOTTOMLEFT", -20, -16)

  local scrapyaInfo = extraPage:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  scrapyaInfo:SetPoint("TOPLEFT", scrapyaEnabled, "BOTTOMLEFT", 20, -8)
  scrapyaInfo:SetWidth(400)
  scrapyaInfo:SetJustifyH("LEFT")
  scrapyaInfo:SetText("Scrapya auto-sells poor-quality (grey) items when a merchant window opens.\nIt uses repeated sell passes for reliability and prints a summary after selling.")

  local scrapyaSoulboundMode = createCheck(extraPage, "Enable CAUTION mode: sell soulbound non-primary armor", "Disabled by default. When enabled, Scrapya may sell soulbound white/blue armor that is NOT your class primary armor type. Never sells BoE items, weapons, rings, necklaces, or trinkets.", function(v)
    if not HitTools.DB.scrapya then
      HitTools.DB.scrapya = {
        enabled = true,
        showSummary = true,
        shiftBypass = true,
        sellInterval = 0.2,
        maxPasses = 40,
        sellNonPrimarySoulbound = false,
      }
    end
    HitTools.DB.scrapya.sellNonPrimarySoulbound = v
  end)
  scrapyaSoulboundMode:SetPoint("TOPLEFT", scrapyaInfo, "BOTTOMLEFT", -20, -14)

  local scrapyaWarning = extraPage:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  scrapyaWarning:SetPoint("TOPLEFT", scrapyaSoulboundMode, "BOTTOMLEFT", 20, -8)
  scrapyaWarning:SetWidth(430)
  scrapyaWarning:SetJustifyH("LEFT")
  scrapyaWarning:SetTextColor(1.0, 0.25, 0.25)
  scrapyaWarning:SetText("WARNING: Use with caution. This mode can vendor soulbound white/blue off-armor pieces.\nSafeguards: BoE is ignored, only soulbound items, and jewelry/weapons are never sold by this mode.")

  refreshScrapyaControls = function()
    local db = HitTools.DB and HitTools.DB.scrapya
    local scrapyaOn = db and db.enabled and true or false
    if scrapyaSoulboundMode.SetEnabled then
      scrapyaSoulboundMode:SetEnabled(scrapyaOn)
    end
    if not scrapyaOn then
      scrapyaWarning:SetAlpha(0.6)
    else
      scrapyaWarning:SetAlpha(1)
    end
  end

  panel:SetScript("OnShow", function()
    if not HitTools.DB then return end

    chatEnabled:SetChecked(HitTools.DB.chat.enabled and true or false)
    dungeonSummary:SetChecked(HitTools.DB.chat.dungeonSummary and true or false)
    uiEnabled:SetChecked(HitTools.DB.ui.enabled and true or false)
    uiLocked:SetChecked(HitTools.DB.ui.locked and true or false)
    xpOutputToParty:SetChecked(HitTools.DB.xpRate and HitTools.DB.xpRate.outputToParty and true or false)
    instEnabled:SetChecked(HitTools.DB.features.instanceTracking and true or false)
    resetPopup:SetChecked(HitTools.DB.features.instanceResetPopup and true or false)
    alertsEnabled:SetChecked(HitTools.DB.alerts.enabled ~= false)
    healerOOMEnabled:SetChecked(HitTools.DB.alerts.healerOOM ~= false)
    muteAlertSounds:SetChecked(HitTools.DB.alerts.soundEnabled == false)
    local soundVolume = tonumber(HitTools.DB.alerts.soundVolume) or 10
    if soundVolume < 1 then soundVolume = 1 end
    if soundVolume > 10 then soundVolume = 10 end
    alertSoundVolume:SetValue(soundVolume)
    if alertsPage._volumeValue then
      alertsPage._volumeValue:SetText(string.format("%d (%d%%)", soundVolume, soundVolume * 10))
    end

    amarkEnabled:SetChecked(HitTools.DB.amark.enabled and true or false)
    amarkCount:SetValue(tonumber(HitTools.DB.amark.count) or 5)
    amarkParty:SetChecked(HitTools.DB.amark.allowInParty ~= false)
    amarkRaid:SetChecked(HitTools.DB.amark.allowInRaid ~= false)
    amarkSolo:SetChecked(HitTools.DB.amark.allowSolo ~= false)
    amarkTankOnly:SetChecked(HitTools.DB.amark.tankOnly and true or false)
    amarkAnnounce:SetChecked(HitTools.DB.amark.announceKillOrderOnZoneIn ~= false)
    amarkPriority:SetText(HitTools.DB.amark.priorityAfterSkull or "x triangle moon square")

    cursorGrowEnabled:SetChecked(HitTools.DB.cursorGrow and HitTools.DB.cursorGrow.enabled and true or false)
    if type(HitTools.DB.catfish) ~= "table" then
      HitTools.DB.catfish = {
        enabled = true,
        doubleClickCast = true,
        bobberAlert = true,
        playSound = true,
        doubleClickWindow = 0.35,
        minBiteDelay = 1.5,
        hoverPredictiveDelay = 8.0,
        adaptiveEnabled = true,
        adaptiveBootstrapDelay = 8.0,
        adaptiveMinSeconds = 4.0,
        adaptiveMaxSeconds = 18.0,
        adaptiveLeadSeconds = 0.35,
        adaptiveSamples = {},
        alertTimeout = 8.0,
        pulseSpeed = 2.2,
        pulseAmount = 0.16,
        glowScale = 1.0,
      }
    end
    catfishEnabled:SetChecked(HitTools.DB.catfish.enabled ~= false)
    baggyEnabled:SetChecked(HitTools.DB.baggy and HitTools.DB.baggy.enabled and true or false)

    local scrapyaDB = HitTools.DB.scrapya
    if type(scrapyaDB) ~= "table" then
      HitTools.DB.scrapya = {
        enabled = true,
        showSummary = true,
        shiftBypass = true,
        sellInterval = 0.2,
        maxPasses = 40,
        sellNonPrimarySoulbound = false,
      }
      scrapyaDB = HitTools.DB.scrapya
    end
    if scrapyaDB.enabled == nil then
      scrapyaDB.enabled = true
    end
    if scrapyaDB.sellNonPrimarySoulbound == nil then
      scrapyaDB.sellNonPrimarySoulbound = false
    end
    scrapyaEnabled:SetChecked(scrapyaDB.enabled and true or false)
    scrapyaSoulboundMode:SetChecked(scrapyaDB.sellNonPrimarySoulbound and true or false)
    if refreshScrapyaControls then
      refreshScrapyaControls()
    end

    setTab("xprate")
  end)

  self.Options = panel
  self:EnsureOptionsRegistered()
end

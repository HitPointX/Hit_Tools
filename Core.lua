local ADDON_NAME, HitTools = ...

_G.HitTools = HitTools

local DEFAULTS = {
  verboseLoading = false,  -- Show detailed addon initialization messages
  chat = {
    enabled = true,
    dungeonSummary = true,
  },
  ui = {
    enabled = true,
    locked = false,
    point = "TOPLEFT",
    relativePoint = "TOPLEFT",
    x = 20,
    y = -120,
  },
  alerts = {
    enabled = true,
    healerOOM = true,
    healerOOMThreshold = 5,
    soundEnabled = true,
    soundVolume = 10, -- 1..10
  },
  features = {
    instanceTracking = true,
    instanceResetPopup = true,
  },
  stats = {
    dungeons = {},
  },
  amark = {
    enabled = true,
    count = 5, -- 1..5
    priorityAfterSkull = "x triangle moon square",
    allowSolo = true,
    allowInParty = true,
    allowInRaid = true,
    tankOnly = false,
    announceKillOrderOnZoneIn = true,
    debug = false,
  },
  mounts = {
    enabled = true,
    kills = {},
  },
  cursorGrow = {
    enabled = true,
    maxScale = 2.5,
    speedThreshold = 800,
    minFlips = 4,  -- Minimum direction changes to detect shaking
    scoreRiseRate = 3.0,
    scoreDecayRate = 2.0,
    growLerpSpeed = 8.0,
    shrinkLerpSpeed = 5.0,
    stopGrowDelaySeconds = 0.3,
    startGrowThreshold = 1.0,
    stopGrowThreshold = 0.5,
    showCursor = true,  -- Show enlarged cursor overlay
    showRings = true,   -- Show glow rings
    easterEggs = true,  -- Enable fun particle effects (1.2% chance)
    debugMode = false,
  },
  catfish = {
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
  },
  baggy = {
    enabled = true,
    showBank = true,
    compactMode = false,
    sortMode = "default",
    searchTooltip = false,
    bigDropQuality = 3,  -- ITEM_QUALITY_RARE
    rainbowSeconds = 3.0,
    debug = false,  -- Debug print statements
    position = {
      point = "CENTER",
      relativePoint = "CENTER",
      x = 0,
      y = 0,
      width = 600,
      height = 500,
    },
  },
  scrapya = {
    enabled = true,
    showSummary = true,
    shiftBypass = true,      -- Hold Shift while opening vendor to skip autosell
    sellInterval = 0.2,      -- Seconds between sell passes
    maxPasses = 40,          -- Safety cap for repeated sell passes
    sellNonPrimarySoulbound = false, -- Caution mode (disabled by default)
  },
  xpRate = {
    -- ISSUE B & D FIX: Smart finalize and party output
    finalizeMode = "smart",  -- "smart" | "instant" | "grace"
    graceSeconds = 30,       -- grace period for normal finishes
    ghostGraceSeconds = 600, -- grace period when dead/ghost
    outputToParty = false,   -- send end-of-run summary to party/raid chat
  },
  socialUI = {
    enabled = true,
    point = "CENTER",
    relativePoint = "CENTER",
    x = 0,
    y = 0,
    width = 700,
    height = 500,
    lastTab = 1,
    lastFilters = {
      players = {
        search = "",
        timeWindow = 0,
        roleFilter = "ANY",
        instanceFilter = "ANY",
        frequentOnly = false,
        inPartyOnly = false,
      },
      pairings = {
        search = "",
        timeWindow = 0,
      },
      runs = {
        timeWindow = 0,
        instance = "ANY",
        outcome = "ANY",
      },
    },
  },
}

local function deepCopyDefaults(dst, src)
  if type(dst) ~= "table" then dst = {} end
  for k, v in pairs(src) do
    if type(v) == "table" then
      dst[k] = deepCopyDefaults(dst[k], v)
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
  return dst
end

local function commify(n)
  if type(n) ~= "number" then return tostring(n) end
  local s = tostring(math.floor(n + 0.5))
  local left, num, right = s:match("^([^%d]*)(%d+)(.-)$")
  if not num then return s end
  num = num:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return (left or "") .. num .. (right or "")
end

local function fmtSeconds(seconds)
  if not seconds or seconds <= 0 or seconds ~= seconds then return nil end
  seconds = math.floor(seconds + 0.5)
  local h = math.floor(seconds / 3600)
  local m = math.floor((seconds % 3600) / 60)
  local s = seconds % 60
  if h > 0 then
    return string.format("%dh %dm", h, m)
  end
  if m > 0 then
    return string.format("%dm %ds", m, s)
  end
  return string.format("%ds", s)
end

local function formatMoney(copper)
  copper = tonumber(copper) or 0
  local sign = ""
  if copper < 0 then
    sign = "-"
    copper = -copper
  end
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  if g > 0 then
    return string.format("%s%dg %ds %dc", sign, g, s, c)
  end
  if s > 0 then
    return string.format("%s%ds %dc", sign, s, c)
  end
  return string.format("%s%dc", sign, c)
end

local function addToMap(map, key, delta)
  if not map then map = {} end
  map[key] = (map[key] or 0) + (delta or 0)
  return map
end

local function getItemQualitySafe(link)
  if not link or link == "" then return nil end
  local quality = select(3, GetItemInfo(link))
  if quality == nil then return nil end
  return tonumber(quality)
end

local function parseLootMsg(msg)
  if type(msg) ~= "string" then return nil end
  local link = msg:match("(|c%x+|Hitem:%d+.-|h%[.-%]|h|r)")
  if not link then
    link = msg:match("(|Hitem:%d+.-|h%[.-%]|h)")
  end
  if not link then return nil end
  local qty = tonumber(msg:match("|r%s*[xX](%d+)"))
    or tonumber(msg:match("%s+[xX](%d+)"))
    or 1
  return link, qty
end

local function parseRepMsg(msg)
  if type(msg) ~= "string" then return nil end
  local faction, amount = msg:match("^Reputation with (.+) increased by (%d+)%p?$")
  if not faction then
    faction, amount = msg:match("^Your reputation with (.+) has increased by (%d+)%p?$")
  end
  amount = tonumber(amount)
  if not faction or not amount then return nil end
  faction = faction:gsub("%.$", "")
  return faction, amount
end

local function calcFootstepsEstimate(dungeon)
  local walkSec = (dungeon and dungeon.moveSecondsWalk) or 0
  local runSec = (dungeon and dungeon.moveSecondsRun) or 0
  local yards = (walkSec * 2.5) + (runSec * 7.0)
  local steps = math.floor(yards + 0.5)
  return steps, yards
end

local function isDungeonInstance()
  local inInstance, instanceType = IsInInstance()
  return inInstance and instanceType == "party"
end

local function isPlayerGUID(guid)
  return type(guid) == "string" and guid:find("^Player%-") ~= nil
end

local function isCurrentGroupPlayerGUID(guid)
  if not isPlayerGUID(guid) then return false end

  if UnitGUID and UnitGUID("player") == guid then
    return true
  end

  local count = GetNumSubgroupMembers and (GetNumSubgroupMembers() or 0) or 0
  for i = 1, count do
    if UnitGUID("party" .. i) == guid then
      return true
    end
  end

  return false
end

local HEALER_CLASS_FALLBACK = {
  PRIEST = true,
  DRUID = true,
  PALADIN = true,
  SHAMAN = true,
  MONK = true,
  EVOKER = true,
}

local function getUnitManaPercent(unit)
  if not unit or not UnitExists or not UnitExists(unit) then return nil end
  local powerType = UnitPowerType and UnitPowerType(unit)
  if powerType ~= 0 then return nil end
  local maxMana = UnitPowerMax and (UnitPowerMax(unit, 0) or 0) or 0
  if maxMana <= 0 then return nil end
  local mana = UnitPower and (UnitPower(unit, 0) or 0) or 0
  return mana / maxMana
end

local function getInstanceKey()
  local name, _, difficultyID, difficultyName, _, _, _, instanceID = GetInstanceInfo()
  local key
  if instanceID and instanceID > 0 then
    key = tostring(instanceID) .. ":" .. tostring(difficultyID or 0)
  else
    key = tostring(name or "Unknown") .. ":" .. tostring(difficultyID or 0)
  end
  return key, name or "Unknown", difficultyID or 0, difficultyName or ""
end

HitTools.DB = nil

HitTools.session = {
  startTime = 0,
  xpGained = 0,
  lastFinalizedRunId = nil,  -- SAFEGUARD 1: Track last finalized run to prevent duplicates
  lastXP = 0,
  lastXPMax = 0,
  lastLevel = 0,
  windowSeconds = 300,
  samples = {},
}

HitTools.alertState = {
  _accum = 0,
  healerOOMActive = false,
}

local ALERT_SOUND_PATHS = {
  healerOOM = "Interface\\AddOns\\Hit_Tools\\assets\\meow.ogg",
  catfishBobber = "Interface\\AddOns\\Hit_Tools\\assets\\meow.ogg",
}

HitTools.dungeon = {
  active = false,
  key = nil,
  name = nil,
  difficultyID = nil,
  difficultyName = nil,
  startTime = 0,
  startTotalXP = 0,
  startLevel = 0,
  startXP = 0,
  startXPMax = 0,
  pendingEnd = false,
  leftAt = 0,
  leftWasGhost = false,
  _finalizeScheduled = false,
  mobsKilled = 0,
  deaths = 0,
  itemsTotal = 0,
  itemsByQuality = nil, -- [quality]=count
  pendingLoot = nil, -- { {link=..., qty=...}, ... } when item info not cached yet
  repByFaction = nil, -- [faction]=amount
  goldEarned = 0, -- positive deltas only
  _lastMoney = 0,
  moveSecondsWalk = 0,
  moveSecondsRun = 0,
  _moveAccum = 0,
}

function HitTools:Print(msg)
  if not msg then return end
  if not self.DB or not self.DB.chat or not self.DB.chat.enabled then return end
  DEFAULT_CHAT_FRAME:AddMessage("|cff66c0ffHit-Tools|r: " .. msg)
end

function HitTools:VerbosePrint(msg)
  if not msg then return end
  if not self.DB or not self.DB.verboseLoading then return end
  print("[HitTools] " .. msg)
end

function HitTools:MaybeInitResetPopup()
  if self._resetPopupInitialized then return end
  self._resetPopupInitialized = true

  if not StaticPopupDialogs then return end
  if StaticPopupDialogs.HITTOOLS_RESET_INSTANCE then return end

  StaticPopupDialogs.HITTOOLS_RESET_INSTANCE = {
    text = "Reset this instance now?",
    button1 = "Reset",
    button2 = "Cancel",
    OnAccept = function()
      if ResetInstances then
        ResetInstances()
      end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
  }
end

function HitTools:ShowResetInstancePopup()
  if not (self.DB and self.DB.features and self.DB.features.instanceResetPopup) then return end
  if not StaticPopup_Show then return end
  if not ResetInstances then return end

  if IsInInstance and select(1, IsInInstance()) then return end
  if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return end

  if IsInGroup and IsInGroup() then
    if UnitIsGroupLeader and not UnitIsGroupLeader("player") then
      return
    end
  end

  self:MaybeInitResetPopup()
  StaticPopup_Show("HITTOOLS_RESET_INSTANCE")
end

function HitTools:InstanceTrackerOnMoneyChanged()
  if not self.dungeon or not self.dungeon.active then return end
  if not GetMoney then return end
  local nowMoney = GetMoney() or 0
  local lastMoney = self.dungeon._lastMoney or nowMoney
  local delta = nowMoney - lastMoney
  if delta > 0 then
    self.dungeon.goldEarned = (self.dungeon.goldEarned or 0) + delta
  end
  self.dungeon._lastMoney = nowMoney
end

function HitTools:InstanceTrackerOnLoot(msg)
  if not self.dungeon or not self.dungeon.active then return end
  if not isDungeonInstance() then return end
  local link, qty = parseLootMsg(msg)
  if not link then return end
  qty = tonumber(qty) or 1
  if qty < 1 then qty = 1 end

  self.dungeon.itemsTotal = (self.dungeon.itemsTotal or 0) + qty

  local quality = getItemQualitySafe(link)
  if quality == nil then
    if not self.dungeon.pendingLoot then self.dungeon.pendingLoot = {} end
    table.insert(self.dungeon.pendingLoot, { link = link, qty = qty })
    return
  end
  self.dungeon.itemsByQuality = addToMap(self.dungeon.itemsByQuality, quality, qty)
end

function HitTools:InstanceTrackerResolvePendingLoot()
  if not self.dungeon or not self.dungeon.pendingLoot then return end
  if #self.dungeon.pendingLoot == 0 then return end

  local stillPending = {}
  for _, entry in ipairs(self.dungeon.pendingLoot) do
    local link = entry and entry.link
    local qty = (entry and entry.qty) or 1
    local quality = getItemQualitySafe(link)
    if quality == nil then
      stillPending[#stillPending + 1] = entry
    else
      self.dungeon.itemsByQuality = addToMap(self.dungeon.itemsByQuality, quality, qty)
    end
  end
  self.dungeon.pendingLoot = stillPending
end

function HitTools:InstanceTrackerOnFactionChange(msg)
  if not self.dungeon or not self.dungeon.active then return end
  if not isDungeonInstance() then return end
  local faction, amount = parseRepMsg(msg)
  if not faction or not amount or amount <= 0 then return end
  self.dungeon.repByFaction = addToMap(self.dungeon.repByFaction, faction, amount)
end

function HitTools:InstanceTrackerOnDeath()
  if not isDungeonInstance() then return end
  local playerGUID = UnitGUID and UnitGUID("player") or "player"
  self:InstanceTrackerCountDeath(playerGUID)
end

function HitTools:InstanceTrackerCountDeath(guid)
  if not self.dungeon or not self.dungeon.active then return end

  local key = guid or "unknown"
  local now = GetTime and (GetTime() or 0) or 0
  if type(self.dungeon._deathSeenAt) ~= "table" then
    self.dungeon._deathSeenAt = {}
  end

  -- Prevent duplicate counts from overlapping event sources (e.g. PLAYER_DEAD + combat log).
  local lastAt = self.dungeon._deathSeenAt[key]
  if lastAt and (now - lastAt) < 2 then
    return
  end

  self.dungeon._deathSeenAt[key] = now
  self.dungeon.deaths = (self.dungeon.deaths or 0) + 1
end

function HitTools:InstanceTrackerOnCombatLogEvent()
  if not self.dungeon or not self.dungeon.active then return end
  if not isDungeonInstance() then return end
  if not CombatLogGetCurrentEventInfo then return end

  local _, subevent, _, _, _, _, _, destGUID = CombatLogGetCurrentEventInfo()

  if subevent == "PARTY_KILL" then
    self.dungeon.mobsKilled = (self.dungeon.mobsKilled or 0) + 1
    return
  end

  if subevent == "UNIT_DIED" and isCurrentGroupPlayerGUID(destGUID) then
    self:InstanceTrackerCountDeath(destGUID)
  end
end

function HitTools:InstanceTrackerOnUpdate(elapsed)
  if not self.dungeon or not self.dungeon.active then return end
  elapsed = tonumber(elapsed) or 0
  if elapsed <= 0 then return end

  self.dungeon._moveAccum = (self.dungeon._moveAccum or 0) + elapsed
  if self.dungeon._moveAccum < 0.25 then return end
  local tickDt = self.dungeon._moveAccum
  self.dungeon._moveAccum = 0

  local speed = GetUnitSpeed and (GetUnitSpeed("player") or 0) or 0
  if not speed or speed <= 0 then return end

  local walking
  if IsWalking then
    walking = IsWalking() and true or false
  else
    walking = speed <= 3.0
  end

  if walking then
    self.dungeon.moveSecondsWalk = (self.dungeon.moveSecondsWalk or 0) + tickDt
  else
    self.dungeon.moveSecondsRun = (self.dungeon.moveSecondsRun or 0) + tickDt
  end
end

function HitTools:GetLowestHealerManaInfo()
  local explicitHealer = nil
  local fallbackHealer = nil

  local function consider(unit, explicit)
    if not UnitExists or not UnitExists(unit) then return end
    if UnitIsConnected and not UnitIsConnected(unit) then return end
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost(unit) then return end

    local pct = getUnitManaPercent(unit)
    if not pct then return end

    local entry = {
      name = UnitName(unit) or unit,
      pct = pct,
    }
    if explicit then
      if (not explicitHealer) or pct < explicitHealer.pct then
        explicitHealer = entry
      end
    else
      if (not fallbackHealer) or pct < fallbackHealer.pct then
        fallbackHealer = entry
      end
    end
  end

  local function isFallbackHealerClass(unit)
    local _, class = UnitClass and UnitClass(unit)
    return class and HEALER_CLASS_FALLBACK[class]
  end

  local function visitUnit(unit)
    local role = UnitGroupRolesAssigned and UnitGroupRolesAssigned(unit) or "NONE"
    if role == "HEALER" then
      consider(unit, true)
      return
    end
    if isFallbackHealerClass(unit) then
      consider(unit, false)
    end
  end

  if IsInRaid and IsInRaid() then
    local n = GetNumGroupMembers and (GetNumGroupMembers() or 0) or 0
    for i = 1, n do
      visitUnit("raid" .. i)
    end
  else
    visitUnit("player")
    local n = GetNumSubgroupMembers and (GetNumSubgroupMembers() or 0) or 0
    for i = 1, n do
      visitUnit("party" .. i)
    end
  end

  return explicitHealer or fallbackHealer
end

function HitTools:ShouldCheckHealerOOMAlert()
  if not self.DB or not self.DB.alerts then return false end
  if not self.DB.alerts.enabled then return false end
  if not self.DB.alerts.healerOOM then return false end
  if not isDungeonInstance() then return false end
  if not IsInGroup or not IsInGroup() then return false end
  return true
end

function HitTools:PlayAlertSound(alertKey)
  if not self.DB or not self.DB.alerts then return end
  if self.DB.alerts.soundEnabled == false then return end

  local path = ALERT_SOUND_PATHS[alertKey]
  if not path or path == "" then return end
  if not PlaySoundFile then return end

  local volumeStep = tonumber(self.DB.alerts.soundVolume) or 10
  if volumeStep < 1 then volumeStep = 1 end
  if volumeStep > 10 then volumeStep = 10 end
  local scale = volumeStep / 10

  -- WoW does not expose per-sound volume for PlaySoundFile; scale via SFX volume briefly.
  if not (GetCVar and SetCVar) then
    PlaySoundFile(path, "SFX")
    return
  end

  local prior = GetCVar("Sound_SFXVolume")
  local priorNum = tonumber(prior)
  if not priorNum then priorNum = 1 end
  local target = scale
  target = priorNum * scale
  if target < 0 then target = 0 end
  if target > 1 then target = 1 end

  self._alertSoundToken = (self._alertSoundToken or 0) + 1
  local token = self._alertSoundToken
  SetCVar("Sound_SFXVolume", string.format("%.3f", target))
  PlaySoundFile(path, "SFX")

  local restoreFn = function()
    if self._alertSoundToken ~= token then return end
    SetCVar("Sound_SFXVolume", string.format("%.3f", priorNum))
  end

  if C_Timer and C_Timer.After then
    C_Timer.After(0.6, restoreFn)
  else
    restoreFn()
  end
end

function HitTools:UpdateHealerOOMAlert()
  if not self.alertState then
    self.alertState = { _accum = 0, healerOOMActive = false }
  end
  local wasActive = self.alertState.healerOOMActive and true or false

  if not self:ShouldCheckHealerOOMAlert() then
    self.alertState.healerOOMActive = false
    if self.HideTopAlert then
      self:HideTopAlert("healerOOM")
    end
    return
  end

  local healer = self:GetLowestHealerManaInfo()
  if not healer or not healer.pct then
    self.alertState.healerOOMActive = false
    if self.HideTopAlert then
      self:HideTopAlert("healerOOM")
    end
    return
  end

  local thresholdPct = (tonumber(self.DB.alerts.healerOOMThreshold) or 5) / 100
  if healer.pct <= thresholdPct then
    self.alertState.healerOOMActive = true
    local pct = math.floor((healer.pct * 100) + 0.5)
    local msg = string.format("HEALER OOM: %d%%", pct)
    if self.ShowTopAlert then
      self:ShowTopAlert("healerOOM", msg)
    end
    if not wasActive then
      self:PlayAlertSound("healerOOM")
    end
    return
  end

  self.alertState.healerOOMActive = false
  if self.HideTopAlert then
    self:HideTopAlert("healerOOM")
  end
end

function HitTools:AlertsOnUpdate(elapsed)
  if not self.alertState then
    self.alertState = { _accum = 0, healerOOMActive = false }
  end
  self.alertState._accum = (self.alertState._accum or 0) + (tonumber(elapsed) or 0)
  if self.alertState._accum < 0.25 then return end
  self.alertState._accum = 0

  self:UpdateHealerOOMAlert()
end

function HitTools:_InstanceHasInterestingStats(duration, gainedXP)
  duration = tonumber(duration) or 0
  gainedXP = tonumber(gainedXP) or 0
  local d = self.dungeon or {}
  if duration >= 30 then return true end
  if gainedXP > 0 then return true end
  if (d.mobsKilled or 0) > 0 then return true end
  if (d.itemsTotal or 0) > 0 then return true end
  if (d.goldEarned or 0) > 0 then return true end
  if d.repByFaction and next(d.repByFaction) then return true end
  if (d.deaths or 0) > 0 then return true end
  return false
end

function HitTools:RecordXPGain()
  local level = UnitLevel("player") or 0
  local xp = UnitXP("player") or 0
  local xpMax = UnitXPMax("player") or 0

  if self.session.startTime == 0 then
    self.session.startTime = GetTime()
    self.session.lastXP = xp
    self.session.lastXPMax = xpMax
    self.session.lastLevel = level
    wipe(self.session.samples)
    table.insert(self.session.samples, { t = self.session.startTime, total = 0 })
    return
  end

  local prevXP = self.session.lastXP or xp
  local prevXPMax = self.session.lastXPMax or xpMax

  local diff = xp - prevXP
  if diff < 0 then
    diff = (prevXPMax - prevXP) + xp
  end

  if diff > 0 then
    self.session.xpGained = (self.session.xpGained or 0) + diff
    local now = GetTime()
    table.insert(self.session.samples, { t = now, total = self.session.xpGained })

    local cutoff = now - (self.session.windowSeconds or 300)
    while #self.session.samples > 2 and self.session.samples[1].t < cutoff do
      table.remove(self.session.samples, 1)
    end
  end

  self.session.lastXP = xp
  self.session.lastXPMax = xpMax
  self.session.lastLevel = level
end

function HitTools:GetRates()
  local now = GetTime()
  local sessionSeconds = now - (self.session.startTime or now)
  local sessionRate = nil
  if sessionSeconds > 5 and (self.session.xpGained or 0) > 0 then
    sessionRate = (self.session.xpGained / sessionSeconds) * 3600
  end

  local rollingRate = nil
  local samples = self.session.samples
  if samples and #samples >= 2 then
    local oldest = samples[1]
    local newest = samples[#samples]
    local dt = newest.t - oldest.t
    local dxp = newest.total - oldest.total
    if dt > 5 and dxp > 0 then
      rollingRate = (dxp / dt) * 3600
    end
  end

  return sessionRate, rollingRate
end

function HitTools:GetTimeToLevelSeconds(preferRolling)
  local xpMax = UnitXPMax("player") or 0
  if xpMax <= 0 then return nil end
  local xp = UnitXP("player") or 0
  local remaining = xpMax - xp
  if remaining <= 0 then return 0 end

  local sessionRate, rollingRate = self:GetRates()
  local rate = preferRolling and rollingRate or sessionRate
  if not rate or rate <= 0 then
    rate = rollingRate or sessionRate
  end
  if not rate or rate <= 0 then return nil end

  local xpPerSecond = rate / 3600
  return remaining / xpPerSecond
end

function HitTools:StartDungeonRun()
  local key, name, difficultyID, difficultyName = getInstanceKey()
  local _, _, _, _, _, _, _, instanceID = GetInstanceInfo()
  self.dungeon.active = true
  self.dungeon.pendingEnd = false
  self.dungeon.leftAt = 0
  self.dungeon.leftWasGhost = false
  self.dungeon._finalizeScheduled = false
  self.dungeon.key = key
  self.dungeon.name = name
  self.dungeon.difficultyID = difficultyID
  self.dungeon.difficultyName = difficultyName
  self.dungeon.instanceID = instanceID  -- SAFEGUARD 2: Store for left-instance detection
  self.dungeon.startTime = GetTime()
  self.dungeon.startTotalXP = self.session.xpGained or 0
  self.dungeon.startLevel = UnitLevel("player") or 0
  self.dungeon.startXP = UnitXP("player") or 0
  self.dungeon.startXPMax = UnitXPMax("player") or 1

  self.dungeon.mobsKilled = 0
  self.dungeon.deaths = 0
  self.dungeon.itemsTotal = 0
  self.dungeon.itemsByQuality = {}
  self.dungeon.pendingLoot = {}
  self.dungeon.repByFaction = {}
  self.dungeon.goldEarned = 0
  self.dungeon._lastMoney = GetMoney and (GetMoney() or 0) or 0
  self.dungeon.moveSecondsWalk = 0
  self.dungeon.moveSecondsRun = 0
  self.dungeon._moveAccum = 0
  self.dungeon._deathSeenAt = {}
end

function HitTools:EndDungeonRun()
  if not self.dungeon.active then return end

  -- SAFEGUARD 1: Generate run ID and check if already finalized
  local runId = string.format("%s_%d", self.dungeon.key or "unknown", self.dungeon.startTime or 0)
  if self.session.lastFinalizedRunId == runId then
    -- Already finalized this run, skip to avoid duplicate output
    self.dungeon.active = false
    self.dungeon.pendingEnd = false
    return
  end

  self:InstanceTrackerResolvePendingLoot()

  local endTime = GetTime()
  local duration = endTime - (self.dungeon.startTime or endTime)
  local gained = (self.session.xpGained or 0) - (self.dungeon.startTotalXP or 0)

  local startLevel = self.dungeon.startLevel or 0
  local startXP = self.dungeon.startXP or 0
  local startXPMax = self.dungeon.startXPMax or 1

  local endLevel = UnitLevel("player") or startLevel
  local endXP = UnitXP("player") or 0
  local endXPMax = UnitXPMax("player") or 1

  local progressStart = startXPMax > 0 and (startXP / startXPMax) or 0
  local progressEnd = endXPMax > 0 and (endXP / endXPMax) or 0
  local levelsGained = (endLevel - startLevel) + (progressEnd - progressStart)
  local barsGained = levelsGained * 20

  local key = self.dungeon.key or "unknown:0"
  local name = self.dungeon.name or "Unknown"
  local difficultyName = self.dungeon.difficultyName or ""

  local interesting = self:_InstanceHasInterestingStats(duration, gained)
  local recordable = duration >= 10 and gained > 0

  -- SAFEGUARD 1: Mark this run as finalized before deactivating
  self.session.lastFinalizedRunId = runId

  self.dungeon.active = false
  self.dungeon.pendingEnd = false
  self.dungeon.leftAt = 0
  self.dungeon.key = nil

  -- INTEGRATION: End Social Heatmap run when XPRate run ends
  -- BUT: Only if we're actually leaving instance (not zoning back in after wipe)
  if HitTools.SocialHeatmap and HitTools.SocialHeatmap.EndRun then
    local inInstance, instanceType = IsInInstance()
    if not inInstance or instanceType == "none" then
      print("[Core] XPRate run ended, triggering Social Heatmap EndRun (actually left instance)")
      HitTools.SocialHeatmap:EndRun("xprate_ended")
    else
      print("[Core] XPRate run ended but still in instance (wipe/runback), NOT ending Social run")
    end
  end

  if not interesting then
    return
  end

  local entry = nil
  local runRate = duration > 0 and ((gained / duration) * 3600) or 0
  local avgRate = nil
  local avgBars = nil

  if recordable and self.DB and self.DB.stats and self.DB.stats.dungeons then
    local dungeons = self.DB.stats.dungeons
    entry = dungeons[key]
    if type(entry) ~= "table" then
      entry = {
        name = name,
        difficultyName = difficultyName,
        runs = 0,
        totalXP = 0,
        totalTime = 0,
        totalLevels = 0,
        last = nil,
      }
      dungeons[key] = entry
    end

    entry.name = name
    entry.difficultyName = difficultyName
    entry.runs = (entry.runs or 0) + 1
    entry.totalXP = (entry.totalXP or 0) + gained
    entry.totalTime = (entry.totalTime or 0) + duration
    entry.totalLevels = (entry.totalLevels or 0) + levelsGained
    entry.last = {
      xp = gained,
      time = duration,
      bars = barsGained,
      endedAt = time(),
      mobs = self.dungeon.mobsKilled or 0,
      deaths = self.dungeon.deaths or 0,
      items = self.dungeon.itemsTotal or 0,
      gold = self.dungeon.goldEarned or 0,
      steps = (calcFootstepsEstimate(self.dungeon)),
    }

    avgBars = ((entry.totalLevels or 0) / (entry.runs or 1)) * 20
    if (entry.totalTime or 0) > 0 then
      avgRate = (entry.totalXP / entry.totalTime) * 3600
    end
  end

  if self.DB and self.DB.chat and self.DB.chat.dungeonSummary then
    local steps = calcFootstepsEstimate(self.dungeon)
    local goldStr = formatMoney(self.dungeon.goldEarned or 0)
    local timeStr = fmtSeconds(duration) or "?"
    local xpStr = commify(gained)
    local mobsStr = tostring(self.dungeon.mobsKilled or 0)
    local deathsStr = tostring(self.dungeon.deaths or 0)
    local itemsTotal = tonumber(self.dungeon.itemsTotal) or 0

    local repParts = {}
    if self.dungeon.repByFaction then
      for faction, amount in pairs(self.dungeon.repByFaction) do
        if amount and amount > 0 then
          repParts[#repParts + 1] = string.format("%s +%d", faction, amount)
        end
      end
      table.sort(repParts)
    end

    local itemParts = {}
    if self.dungeon.itemsByQuality then
      local order = { 4, 3, 2, 1, 0, 5, 6, 7 }
      for _, q in ipairs(order) do
        local n = self.dungeon.itemsByQuality[q]
        if n and n > 0 then
          local _, _, _, hex = GetItemQualityColor and GetItemQualityColor(q) or nil
          local label = _G["ITEM_QUALITY" .. tostring(q) .. "_DESC"] or ("Q" .. tostring(q))
          if hex then
            itemParts[#itemParts + 1] = string.format("|c%s%s|r:%d", hex, label, n)
          else
            itemParts[#itemParts + 1] = string.format("%s:%d", label, n)
          end
        end
      end
    end

    -- Build summary messages
    local msg1 = string.format(
      "%s: XP +%s, Mobs %s, Time %s, Gold +%s, Deaths %s, Steps ~%d.",
      name,
      xpStr,
      mobsStr,
      timeStr,
      goldStr,
      deathsStr,
      steps or 0
    )
    local msg2 = string.format("Items: %d%s.", itemsTotal, (#itemParts > 0 and (" (" .. table.concat(itemParts, ", ") .. ")") or ""))
    local msg3 = #repParts > 0 and ("Rep: " .. table.concat(repParts, ", ") .. ".") or nil
    local msg4 = nil
    if recordable then
      if avgRate and entry then
        msg4 = string.format("Run XP/hr: %.0f. Avg XP/hr: %.0f (%d runs).", runRate, avgRate, entry.runs or 0)
      else
        msg4 = string.format("Run XP/hr: %.0f.", runRate)
      end
    end

    -- Print locally
    self:Print(msg1)
    self:Print(msg2)
    if msg3 then self:Print(msg3) end
    if msg4 then self:Print(msg4) end

    -- SAFEGUARD 5: Send to party/raid chat with guardrails
    if self.DB.xpRate and self.DB.xpRate.outputToParty then
      -- Verify still in group (race condition check)
      if IsInGroup() or IsInRaid() then
        local channel = IsInRaid() and "RAID" or "PARTY"
        -- Combine into single message to avoid spam
        local summary = msg1
        if msg4 then
          summary = summary .. " " .. msg4
        end

        -- Truncate to safe length (WoW chat limit ~255, use 240 to be safe)
        if #summary > 240 then
          summary = summary:sub(1, 237) .. "..."
        end

        -- Send with error handling (pcall to avoid blocking on chat errors)
        local success, err = pcall(SendChatMessage, summary, channel)
        if not success and self.DB.xpRate.debug then
          self:Print("XPRate: Failed to send to " .. channel .. " - " .. tostring(err))
        end
      end
    end

  end

  self:ShowResetInstancePopup()
end

function HitTools:_GetDungeonLeaveGraceSeconds()
  -- ISSUE B FIX: Smart finalize mode
  local mode = self.DB.xpRate and self.DB.xpRate.finalizeMode or "smart"
  local graceSeconds = self.DB.xpRate and self.DB.xpRate.graceSeconds or 30
  local ghostGraceSeconds = self.DB.xpRate and self.DB.xpRate.ghostGraceSeconds or 600

  -- Instant mode: no grace period
  if mode == "instant" then
    return 0
  end

  -- Ghost/dead: use longer grace period
  if self.dungeon and self.dungeon.leftWasGhost then
    return ghostGraceSeconds
  end
  if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then
    return ghostGraceSeconds
  end

  -- Grace mode: use configured grace period
  if mode == "grace" then
    return graceSeconds
  end

  -- SAFEGUARD 2: Smart mode with tighter instance detection
  local inInstance, instanceType = IsInInstance()
  local _, _, _, _, _, _, _, currentInstanceID = GetInstanceInfo()
  local dungeonInstanceID = self.dungeon and self.dungeon.instanceID

  -- Check if definitely left instance
  if not inInstance or instanceType == "none" then
    -- Not in any instance, finalize quickly with confirmation delay
    return 1  -- 1s grace to ensure state is stable during loading screens
  end

  -- Check if instance ID changed (teleported to different instance)
  if dungeonInstanceID and currentInstanceID and currentInstanceID ~= dungeonInstanceID then
    -- Instance ID changed, definitely left
    return 1  -- Quick finalize with confirmation delay
  end

  -- Still in instance (or state unclear), use grace period
  return graceSeconds
end

--[[═══════════════════════════════════════════════════════════════════════════
  OnSocialRunEnded - ISSUE B FIX: Trigger XPRate finalization when social run ends
═══════════════════════════════════════════════════════════════════════════════]]

function HitTools:OnSocialRunEnded(run, reason)
  -- If we have an active XPRate run and social run just ended, trigger finalization
  if not self.dungeon or not self.dungeon.active then
    return
  end

  -- Mark dungeon as pending end if not already
  if not self.dungeon.pendingEnd then
    self.dungeon.pendingEnd = true
    self.dungeon.leftAt = GetTime()
    self.dungeon.leftWasGhost = UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") or false
  end

  -- Schedule finalization with smart grace period
  self:ScheduleDungeonFinalize()
end

function HitTools:FinalizeDungeonRunIfLeft()
  if not self.dungeon or not self.dungeon.active or not self.dungeon.pendingEnd then
    if self.dungeon then
      self.dungeon._finalizeScheduled = false
    end
    return
  end

  if isDungeonInstance() then
    self.dungeon.pendingEnd = false
    self.dungeon.leftAt = 0
    self.dungeon.leftWasGhost = false
    self.dungeon._finalizeScheduled = false
    return
  end

  local now = GetTime()
  local leftAt = self.dungeon.leftAt or now
  local grace = self:_GetDungeonLeaveGraceSeconds()
  if (now - leftAt) < grace then
    if C_Timer and C_Timer.After then
      local waitMore = grace - (now - leftAt)
      C_Timer.After(waitMore + 1, function()
        if HitTools and HitTools.FinalizeDungeonRunIfLeft then
          HitTools:FinalizeDungeonRunIfLeft()
        end
      end)
    end
    return
  end

  self.dungeon._finalizeScheduled = false
  self:EndDungeonRun()
end

function HitTools:ScheduleDungeonFinalize()
  if not self.dungeon or not self.dungeon.active or not self.dungeon.pendingEnd then return end
  if self.dungeon._finalizeScheduled then return end
  self.dungeon._finalizeScheduled = true
  if C_Timer and C_Timer.After then
    C_Timer.After(self:_GetDungeonLeaveGraceSeconds(), function()
      if HitTools and HitTools.FinalizeDungeonRunIfLeft then
        HitTools:FinalizeDungeonRunIfLeft()
      end
    end)
  end
end

function HitTools:CheckDungeonTransition()
  if not self.DB or not self.DB.features.instanceTracking then
    if self.dungeon.active then
      self.dungeon.active = false
      self.dungeon.key = nil
      self.dungeon.pendingEnd = false
      self.dungeon.leftAt = 0
      self.dungeon.leftWasGhost = false
      self.dungeon._finalizeScheduled = false
    end
    return
  end

  local inDungeon = isDungeonInstance()
  if inDungeon then
    local key = getInstanceKey()
    if self.dungeon.active and self.dungeon.key and key and key ~= self.dungeon.key then
      self:EndDungeonRun()
    end
    if not self.dungeon.active then
      self:StartDungeonRun()
    else
      self.dungeon.pendingEnd = false
      self.dungeon.leftAt = 0
      self.dungeon.leftWasGhost = false
      self.dungeon._finalizeScheduled = false
    end
    return
  end

  if self.dungeon.active then
    if not self.dungeon.pendingEnd then
      self.dungeon.pendingEnd = true
      self.dungeon.leftAt = GetTime()
      self.dungeon.leftWasGhost = UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") and true or false
    end
    self:ScheduleDungeonFinalize()
  end
end

function HitTools:ResetDungeonStats()
  self.DB.stats.dungeons = {}
  self:Print("Dungeon stats reset.")
end

function HitTools:PrintDungeonStats(limit)
  limit = limit or 10
  local dungeons = self.DB and self.DB.stats and self.DB.stats.dungeons
  if not dungeons then return end

  local rows = {}
  for key, entry in pairs(dungeons) do
    if type(entry) == "table" and (entry.totalTime or 0) > 0 and (entry.totalXP or 0) > 0 then
      local avgRate = (entry.totalXP / entry.totalTime) * 3600
      table.insert(rows, {
        key = key,
        name = entry.name or key,
        runs = entry.runs or 0,
        avgRate = avgRate,
        avgBars = ((entry.totalLevels or 0) / (entry.runs or 1)) * 20,
      })
    end
  end

  table.sort(rows, function(a, b) return (a.avgRate or 0) > (b.avgRate or 0) end)

  if #rows == 0 then
    self:Print("No dungeon stats yet.")
    return
  end

  self:Print("Dungeon averages (top " .. tostring(math.min(limit, #rows)) .. "):")
  for i = 1, math.min(limit, #rows) do
    local r = rows[i]
    self:Print(string.format("%d) %s — %.0f XP/hr, ~%.1f bars/run (%d runs)", i, r.name, r.avgRate or 0, r.avgBars or 0, r.runs or 0))
  end
end

function HitTools:HandleSlash(msg)
  msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if msg == "config" or msg == "options" then
    if self.OpenOptions then
      self:OpenOptions()
    elseif InterfaceOptionsFrame_OpenToCategory and self.Options then
      InterfaceOptionsFrame_OpenToCategory(self.Options)
      InterfaceOptionsFrame_OpenToCategory(self.Options)
    end
    return
  end
  if msg == "stats" then
    self:PrintDungeonStats(10)
    return
  end
  if msg == "ui" then
    self.DB.ui.enabled = not self.DB.ui.enabled
    self:ApplyUIEnabled()
    self:Print("UI frame: " .. (self.DB.ui.enabled and "ON" or "OFF"))
    return
  end

  if msg == "lock" then
    self.DB.ui.locked = not self.DB.ui.locked
    self:ApplyUILock()
    self:Print("UI frame locked: " .. (self.DB.ui.locked and "YES" or "NO"))
    return
  end

  if msg == "reset" then
    self:ResetDungeonStats()
    return
  end

  -- Cursor commands: /hit cursor [grow] <args>
  if msg:match("^cursor") then
    -- Support both "/hit cursor <args>" and "/hit cursor grow <args>"
    local args = msg:match("^cursor%s+grow%s*(.*)") or msg:match("^cursor%s+(.*)")
    args = args or ""
    if self.CursorGrow and self.CursorGrow.HandleCommand then
      self.CursorGrow:HandleCommand(args)
    else
      self:Print("Cursor grow module not loaded")
    end
    return
  end

  -- Catfish commands: /hit catfish <args>
  if msg:match("^catfish") then
    local args = msg:match("^catfish%s*(.*)") or ""
    if self.Catfish and self.Catfish.HandleCommand then
      self.Catfish:HandleCommand(args)
    else
      self:Print("Catfish module not loaded")
    end
    return
  end

  -- Baggy commands
  if msg:match("^baggy") then
    local args = msg:match("^baggy%s*(.*)") or ""

    -- /hit baggy debug [on|off]
    if args == "debug" or args == "debug on" or args == "debug off" then
      local enable = nil
      if args == "debug on" then enable = true end
      if args == "debug off" then enable = false end
      if HitTools.Baggy then
        HitTools.Baggy:ToggleDebug(enable)
      end
      return
    end

    -- /hit baggy diag
    if args == "diag" or args == "diagnostics" then
      if HitTools.Baggy then
        HitTools.Baggy:PrintDiagnostics()
      else
        self:Print("Baggy not loaded")
      end
      return
    end

    -- /hit baggy overlay
    if args == "overlay" or args == "map" then
      if HitTools.BaggyUI and HitTools.BaggyUI.ShowCellMappingOverlay then
        HitTools.BaggyUI:ShowCellMappingOverlay(10)
      else
        self:Print("Baggy UI not ready")
      end
      return
    end

    self:Print("Baggy commands:")
    self:Print("  /hit baggy debug [on|off] - Toggle debug logging")
    self:Print("  /hit baggy diag - Print diagnostics")
    self:Print("  /hit baggy overlay - Show bag:slot labels for 10s (debug)")
    return
  end

  -- Scrapya commands
  if msg:match("^scrapya") then
    local args = msg:match("^scrapya%s*(.*)") or ""
    if self.Scrapya and self.Scrapya.HandleCommand then
      self.Scrapya:HandleCommand(args)
    else
      self:Print("Scrapya module not loaded")
    end
    return
  end

  -- Verbose loading toggle: /hit verbose
  if msg == "verbose" then
    self.DB.verboseLoading = not self.DB.verboseLoading
    self:Print("Verbose loading: " .. (self.DB.verboseLoading and "ON" or "OFF"))
    return
  end

  -- Social heatmap commands: /hit social <args>
  if msg:match("^social") then
    local args = msg:match("^social%s*(.*)") or ""
    if self.SocialHeatmap and self.SocialHeatmap.HandleCommand then
      self.SocialHeatmap:HandleCommand(args)
    else
      self:Print("Social Heatmap module not loaded")
    end
    return
  end

  local sessionRate, rollingRate = self:GetRates()
  local ttl = self:GetTimeToLevelSeconds(true)
  local ttlStr = fmtSeconds(ttl) or "n/a"
  local r1 = sessionRate and string.format("%.0f", sessionRate) or "n/a"
  local r2 = rollingRate and string.format("%.0f", rollingRate) or "n/a"
  self:Print(string.format("XP/hr session=%s, rolling=%s. TTL=%s.", r1, r2, ttlStr))
  self:Print("Commands: /hittools config | stats | ui | lock | reset | cursor grow | catfish | baggy | scrapya | social (alias: /xprate)")
end

function HitTools:ApplyUIEnabled()
  if not self.UI then return end
  if self.DB.ui.enabled then
    self.UI:Show()
  else
    self.UI:Hide()
  end
end

function HitTools:ApplyUILock()
  if not self.UI then return end
  self.UI:SetLocked(self.DB.ui.locked)
end

local function onEvent(_, event, arg1)
  if event == "PLAYER_LOGIN" then
    if HitTools.EnsureOptionsRegistered then
      HitTools:EnsureOptionsRegistered()
    end
    return
  end

  if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
    -- Migrate prior settings if they exist.
    if type(HitToolsDB) ~= "table" or next(HitToolsDB) == nil then
      if type(XPRateDB) == "table" and next(XPRateDB) ~= nil then
        HitToolsDB = XPRateDB
      else
        HitToolsDB = {}
      end
    end

    HitToolsDB = deepCopyDefaults(HitToolsDB, DEFAULTS)
    HitTools.DB = HitToolsDB

    HitTools.session.startTime = 0
    HitTools.session.xpGained = 0
    HitTools.session.lastXP = UnitXP("player") or 0
    HitTools.session.lastXPMax = UnitXPMax("player") or 0
    HitTools.session.lastLevel = UnitLevel("player") or 0
    wipe(HitTools.session.samples)
    HitTools.session.startTime = GetTime()
    table.insert(HitTools.session.samples, { t = HitTools.session.startTime, total = 0 })

    if HitTools.CreateUI then
      HitTools:CreateUI()
      HitTools:ApplyUIEnabled()
      HitTools:ApplyUILock()
    end

    if HitTools.CreateAlertUI then
      HitTools:CreateAlertUI()
    end

    if HitTools.CreateOptions then
      HitTools:CreateOptions()
    end

    SLASH_HITTOOLS1 = "/hittools"
    SLASH_HITTOOLS2 = "/hit"
    SlashCmdList.HITTOOLS = function(msg) HitTools:HandleSlash(msg) end

    -- Back-compat.
    SLASH_XPRATE1 = "/xprate"
    SlashCmdList.XPRATE = SlashCmdList.HITTOOLS

    HitTools:VerbosePrint("Calling module OnDBReady functions...")

    if HitTools.AMark and HitTools.AMark.OnDBReady then
      HitTools:VerbosePrint("Calling AMark:OnDBReady()")
      HitTools.AMark:OnDBReady()
    end

    if HitTools.MountTracker and HitTools.MountTracker.OnDBReady then
      HitTools:VerbosePrint("Calling MountTracker:OnDBReady()")
      HitTools.MountTracker:OnDBReady()
    end

    if HitTools.CursorGrow and HitTools.CursorGrow.OnDBReady then
      HitTools:VerbosePrint("Calling CursorGrow:OnDBReady()")
      HitTools.CursorGrow:OnDBReady()
    end

    if HitTools.Catfish and HitTools.Catfish.OnDBReady then
      HitTools:VerbosePrint("Calling Catfish:OnDBReady()")
      HitTools.Catfish:OnDBReady()
    end

    HitTools:VerbosePrint("After CursorGrow, checking SocialHeatmap...")

    if HitTools.SocialHeatmap and HitTools.SocialHeatmap.OnDBReady then
      HitTools:VerbosePrint("Calling SocialHeatmap:OnDBReady()")
      local success, err = pcall(HitTools.SocialHeatmap.OnDBReady, HitTools.SocialHeatmap)
      if not success then
        print("[HitTools] ERROR in SocialHeatmap:OnDBReady(): " .. tostring(err))
      end
    else
      HitTools:VerbosePrint("SocialHeatmap.OnDBReady check failed: SocialHeatmap=" .. tostring(HitTools.SocialHeatmap ~= nil) .. ", OnDBReady=" .. tostring(HitTools.SocialHeatmap and HitTools.SocialHeatmap.OnDBReady ~= nil))
    end

    HitTools:VerbosePrint("After SocialHeatmap, checking Baggy...")
    HitTools:VerbosePrint("Baggy check: HitTools.Baggy=" .. tostring(HitTools.Baggy ~= nil))
    if HitTools.Baggy then
      HitTools:VerbosePrint("Baggy exists, checking OnDBReady: " .. tostring(HitTools.Baggy.OnDBReady ~= nil))
    end

    if HitTools.Baggy and HitTools.Baggy.OnDBReady then
      HitTools:VerbosePrint("Calling Baggy:OnDBReady()")
      local success, err = pcall(HitTools.Baggy.OnDBReady, HitTools.Baggy)
      if not success then
        print("[HitTools] ERROR in Baggy:OnDBReady(): " .. tostring(err))
      end
    else
      HitTools:VerbosePrint("Baggy.OnDBReady check failed: Baggy=" .. tostring(HitTools.Baggy ~= nil) .. ", OnDBReady=" .. tostring(HitTools.Baggy and HitTools.Baggy.OnDBReady ~= nil))
    end

    if HitTools.Scrapya and HitTools.Scrapya.OnDBReady then
      HitTools:VerbosePrint("Calling Scrapya:OnDBReady()")
      local success, err = pcall(HitTools.Scrapya.OnDBReady, HitTools.Scrapya)
      if not success then
        print("[HitTools] ERROR in Scrapya:OnDBReady(): " .. tostring(err))
      end
    else
      HitTools:VerbosePrint("Scrapya.OnDBReady check failed: Scrapya=" .. tostring(HitTools.Scrapya ~= nil) .. ", OnDBReady=" .. tostring(HitTools.Scrapya and HitTools.Scrapya.OnDBReady ~= nil))
    end

    -- Mark addon as loaded, message will be printed on PLAYER_ENTERING_WORLD
    HitTools._addonLoadedSuccessfully = true

    return
  end

  if event == "PLAYER_XP_UPDATE" then
    HitTools:RecordXPGain()
    if HitTools.UI and HitTools.UI.UpdateText then
      HitTools.UI:UpdateText()
    end
    return
  end

  if event == "PLAYER_LEVEL_UP" then
    -- Record any XP gain just before the level-up update.
    HitTools:RecordXPGain()
    return
  end

  if event == "PLAYER_DEAD" then
    HitTools:InstanceTrackerOnDeath()
    return
  end

  if event == "PLAYER_MONEY" then
    HitTools:InstanceTrackerOnMoneyChanged()
    return
  end

  if event == "CHAT_MSG_LOOT" then
    HitTools:InstanceTrackerOnLoot(arg1)
    return
  end

  if event == "CHAT_MSG_COMBAT_FACTION_CHANGE" then
    HitTools:InstanceTrackerOnFactionChange(arg1)
    return
  end

  if event == "COMBAT_LOG_EVENT_UNFILTERED" then
    HitTools:InstanceTrackerOnCombatLogEvent()
    return
  end

  if event == "GET_ITEM_INFO_RECEIVED" then
    HitTools:InstanceTrackerResolvePendingLoot()
    return
  end

  if event == "PLAYER_ENTERING_WORLD" then
    -- Print addon loaded message once on first login/reload
    if HitTools._addonLoadedSuccessfully and not HitTools._loadMessageShown then
      HitTools._loadMessageShown = true
      print("|cFFFFFFFF[|r|cFFFF00FFHitTools|r|cFFFFFFFF]|r Addon Loaded")
    end

    HitTools:CheckDungeonTransition()
    if HitTools.UI and HitTools.UI.UpdateText then
      HitTools.UI:UpdateText()
    end
    return
  end

  if event == "ZONE_CHANGED"
    or event == "ZONE_CHANGED_NEW_AREA"
    or event == "ZONE_CHANGED_INDOORS" then
    HitTools:CheckDungeonTransition()
    if HitTools.UI and HitTools.UI.UpdateText then
      HitTools.UI:UpdateText()
    end
    return
  end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_XP_UPDATE")
f:RegisterEvent("PLAYER_LEVEL_UP")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("ZONE_CHANGED")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("ZONE_CHANGED_INDOORS")
f:RegisterEvent("PLAYER_DEAD")
f:RegisterEvent("PLAYER_MONEY")
f:RegisterEvent("CHAT_MSG_LOOT")
f:RegisterEvent("CHAT_MSG_COMBAT_FACTION_CHANGE")
f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
f:RegisterEvent("GET_ITEM_INFO_RECEIVED")
f:SetScript("OnEvent", onEvent)
f:SetScript("OnUpdate", function(_, elapsed)
  if HitTools and HitTools.InstanceTrackerOnUpdate then
    HitTools:InstanceTrackerOnUpdate(elapsed)
  end
  if HitTools and HitTools.AlertsOnUpdate then
    HitTools:AlertsOnUpdate(elapsed)
  end
end)

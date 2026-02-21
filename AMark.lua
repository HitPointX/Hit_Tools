local _, HitTools = ...

--[[
  AMark - Automatic Target Marking for TBC Classic/TBC Anniversary
  
  RESEARCH SUMMARY (targeted sources only):
  - Blizzard forum threads consistently map Skull/X as primary/secondary kill.
  - Classic convention for CC mapping is Square=Trap, Moon=Sheep, Triangle=Shackle,
    Diamond=Banish, Star=Sap (Circle often treated as free/extra control target).
  - Public addon docs (CurseForge AutoMarker/QuickMark) and utility packs reflect
    the same icon semantics and reserve Skull for "kill now"/high priority.
  - TBC dungeon guides (Icy Veins) repeatedly flag healer/caster mob name patterns
    like Acolyte, Oracle, Prophet, Physician, Ritualist, Warlock, etc.
]]

HitTools.AMark = HitTools.AMark or {}
local AMark = HitTools.AMark

--=============================================================================
-- SECTION 1: TBC CANONICAL ICON CONSTANTS
--=============================================================================

-- Icon numbers as used by SetRaidTarget
local ICON = {
  STAR = 1,      -- Sap target
  CIRCLE = 2,    -- Shackle Undead / MC
  DIAMOND = 3,   -- Banish / Fear
  TRIANGLE = 4,  -- Hibernate / Shackle
  MOON = 5,      -- Polymorph
  SQUARE = 6,    -- Freezing Trap
  CROSS = 7,     -- Secondary kill
  SKULL = 8      -- Primary kill / Healer
}

local ICON_LABELS = {
  [ICON.STAR] = "Star",
  [ICON.CIRCLE] = "Circle",
  [ICON.DIAMOND] = "Diamond",
  [ICON.TRIANGLE] = "Triangle",
  [ICON.MOON] = "Moon",
  [ICON.SQUARE] = "Square",
  [ICON.CROSS] = "Cross",
  [ICON.SKULL] = "Skull",
}

-- TBC Default priority order: Cross, Square, Moon, Triangle, Diamond, Circle, Star
-- (Skull reserved for healers only)
local DEFAULT_PRIORITY_AFTER_SKULL = { ICON.CROSS, ICON.SQUARE, ICON.MOON, ICON.TRIANGLE, ICON.DIAMOND, ICON.CIRCLE, ICON.STAR }

-- CC Mode priority (for CC-heavy content like heroics):
-- Square=Trap, Moon=Sheep, Triangle=Shackle, Diamond=Banish, Star=Sap
local CC_MODE_PRIORITY = { ICON.SQUARE, ICON.MOON, ICON.TRIANGLE, ICON.DIAMOND, ICON.STAR, ICON.CIRCLE, ICON.CROSS }

--=============================================================================
-- SECTION 2: TBC HEALER/CASTER KEYWORDS
--=============================================================================

-- Priority: Healer > Caster > Melee
-- These keywords are matched against mob names (case-insensitive)

-- High priority healers (always get Skull)
local HEALER_KEYWORDS = {
  -- Common healer naming patterns in TBC trash/boss adds
  "healer", "priest", "cleric", "acolyte", "medic", "mender", "restorer",
  "shaman", "seer", "oracle", "witch doctor", "sage", "spiritualist",
  "prophet", "disciple", "physician", "chirurgeon"
}

-- Medium priority casters (get priority marking but not skull unless no healers)
local CASTER_KEYWORDS = {
  "mage", "warlock", "sorcerer", "sorceress", "conjurer", "elementalist",
  "channeler", "arcanist", "necromancer", "summoner", "enchanter", "ritualist",
  "darkcaster", "caster", "invoker", "evoker", "spellbinder", "spell",
  "arcane", "shadow", "flame", "frost", "storm", "fire"
}

-- Low priority (support/buff mobs - still important but not priority targets)
local SUPPORT_KEYWORDS = {
  "totem", "banner", "spirit", "spiritual", "guardian", "warder", "defender",
  "fury", "spawn", "add", "handler", "protector"
}

-- Healing cast keywords (optional score contribution)
local HEALING_SPELL_KEYWORDS = {
  "heal", "renew", "rejuven", "regrowth", "holy light", "prayer",
  "healing wave", "chain heal", "flash of light", "lifebloom"
}

-- Small hardening config section (npcID based)
local blacklistNeverMark = {
  -- [12345] = true, -- Totems/critters/summons you never want AMark to touch
}

local whitelistHealers = {
  -- [12345] = true, -- Known healer mobs; forced to healer threshold
}

--=============================================================================
-- SECTION 3: CONFIGURATION & STATE
--=============================================================================

local function getDB()
  return HitTools.DB and HitTools.DB.amark
end

local function cloneArray(src)
  local out = {}
  for i = 1, #src do
    out[i] = src[i]
  end
  return out
end

local function getDefaultConfig()
  return {
    enabled = true,
    -- Activation settings
    onlyInInstance = true,      -- Only mark inside instances
    tankOrSoloOnly = true,      -- Grouped: require tank role; solo always allowed
    forceEnable = false,        -- Bypass tank/solo gate
    tankOnly = false,           -- Legacy option (still honored as fallback gate)
    disableInPVP = true,        -- Disable in PvP contexts
    requireRaidLeaderOrAssist = true, -- In raid, require leader/assist
    -- Detection settings
    healerAlwaysSkull = true,   -- Healers always get skull
    healerScoreThreshold = 2,   -- Skull only at/above this healer score
    useHealingCastScore = true, -- Add score when actively casting heals
    healerKeywords = cloneArray(HEALER_KEYWORDS),
    casterKeywords = cloneArray(CASTER_KEYWORDS),
    supportKeywords = cloneArray(SUPPORT_KEYWORDS),
    priorityIcons = cloneArray(DEFAULT_PRIORITY_AFTER_SKULL),
    ccPriorityIcons = cloneArray(CC_MODE_PRIORITY),
    useCCMode = false,          -- Use CC priority instead of kill order
    markOnlyInCombat = true,    -- Only mark enemies in combat
    -- Marking settings  
    markCount = 5,              -- How many icons to use (1-5)
    maxMarkChangesPerScan = 1,  -- Hard cap to avoid group-action spam
    raidActionThrottle = 0.35,  -- Minimum seconds between SetRaidTarget calls
    announceKillOrderOnZoneIn = true, -- Send one group message with current AMark order
    -- Pack switch / reset hardening
    packSwitchMinNewGUIDs = 2,  -- Require at least N new GUIDs for fast switch
    packSwitchMinWaveGap = 1.5, -- Or allow switch when this much time passed
    outOfCombatResetSeconds = 3, -- Failsafe reset if no hostile combat units
    announceOutsideResetSeconds = 600, -- Reset announce dedupe after 10 minutes out
    -- Throttle settings
    scanThrottle = 0.2,        -- Max scans per second (5 fps)
  }
end

-- Internal state
local state = {
  lastScanTime = 0,
  markedGUIDs = {},           -- Currently marked GUIDs
  ownedGUIDsThisPull = {},    -- GUIDs AMark has marked this pull
  lastPackGUIDs = {},         -- Previous pack for pack-switch detection
  combatStartTime = nil,      -- When combat started
  skullUsedThisPull = false,  -- Track if skull used
  scanTicker = 0,             -- Periodic apply ticker
  lastMarkWaveTime = 0,       -- Last time we successfully changed marks
  lastHostileCombatTime = 0,  -- Last time hostile combat units were seen
  lastRaidActionTime = 0,     -- Last SetRaidTarget action time
  lastAnnounceKey = nil,      -- Last instance announce key
  lastAnnounceAt = 0,         -- Last announce timestamp
  outsideInstanceSince = 0,   -- Grace timer for announce dedupe reset
  pendingAnnounceToken = 0,   -- Delayed announce token
}

--=============================================================================
-- SECTION 4: HELPER FUNCTIONS
--=============================================================================

local function parseNPCIDFromGUID(guid)
  if not guid then return nil end
  local unitType, _, _, _, _, npcID = strsplit("-", guid)
  if unitType ~= "Creature" and unitType ~= "Vehicle" then
    return nil
  end
  return tonumber(npcID)
end

local function isManaUser(unit)
  local powerType = UnitPowerType(unit)
  if powerType ~= 0 then return false end -- 0 = mana
  return (UnitPowerMax(unit, 0) or 0) > 0
end

local function isHealingCast(unit)
  local spellName = UnitCastingInfo(unit) or UnitChannelInfo(unit)
  if not spellName then return false end
  local lowerSpell = string.lower(spellName)
  for _, keyword in ipairs(HEALING_SPELL_KEYWORDS) do
    if string.find(lowerSpell, keyword, 1, true) then
      return true
    end
  end
  return false
end

local function isNeverMarkUnit(unit, guid)
  if UnitPlayerControlled and UnitPlayerControlled(unit) then return true end
  if UnitIsOtherPlayersPet and UnitIsOtherPlayersPet(unit) then return true end

  local creatureType = UnitCreatureType(unit)
  if creatureType == "Totem" or creatureType == "Critter" then
    return true
  end

  local npcID = parseNPCIDFromGUID(guid)
  if npcID and blacklistNeverMark[npcID] then
    return true
  end

  return false
end

-- Check if player has permission to set raid markers
local function canSetRaidMarkers(db)
  db = db or getDB()
  if IsInRaid() and (not db or db.requireRaidLeaderOrAssist ~= false) then
    return UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
  end
  return true -- Solo/party leader can always mark
end

local function canDoRaidAction(db, force)
  if force then return true end
  local now = GetTime()
  local throttle = (db and db.raidActionThrottle) or 0.35
  if (now - (state.lastRaidActionTime or 0)) < throttle then
    return false
  end
  state.lastRaidActionTime = now
  return true
end

-- Safe wrapper for SetRaidTarget
local function safeSetRaidTarget(unit, iconIndex, force)
  local db = getDB()
  if not canSetRaidMarkers(db) then return false end
  if not unit or not UnitExists(unit) then return false end
  if not canDoRaidAction(db, force) then return false end
  
  -- Check if unit can be marked
  if CanBeRaidTarget and not CanBeRaidTarget(unit) then return false end
  
  local guid = UnitGUID(unit)
  local current = GetRaidTargetIndex(unit)
  if current and current == iconIndex then
    return false
  end

  -- Manual mark preservation: only overwrite marks AMark set this pull
  if current and current > 0 and iconIndex > 0 and guid and not state.ownedGUIDsThisPull[guid] then
    return false
  end
  
  -- Use protected call
  local success = pcall(SetRaidTarget, unit, iconIndex)
  if success and guid then
    if iconIndex and iconIndex > 0 then
      state.markedGUIDs[guid] = iconIndex
      state.ownedGUIDsThisPull[guid] = true
    else
      state.markedGUIDs[guid] = nil
    end
  end
  return success
end

-- Clear a specific mark
local function clearMark(unit, force)
  safeSetRaidTarget(unit, 0, force)
end

-- Get all nameplate units
local function getNameplateUnits()
  if not C_NamePlate or not C_NamePlate.GetNamePlates then
    return {}
  end
  
  local plates = C_NamePlate.GetNamePlates()
  if not plates then return {} end
  
  local units = {}
  for _, plate in ipairs(plates) do
    if plate and plate.namePlateUnitToken then
      units[#units + 1] = plate.namePlateUnitToken
    end
  end
  return units
end

-- Check if unit is in combat
local function isInCombat(unit)
  return UnitAffectingCombat(unit)
end

-- Check if unit is a valid target for marking
local function isValidTarget(unit)
  if not unit or not UnitExists(unit) then return false end
  if not UnitCanAttack("player", unit) then return false end
  if UnitIsDeadOrGhost(unit) then return false end
  if UnitIsPlayer(unit) then return false end
  if UnitIsFriend("player", unit) then return false end

  local guid = UnitGUID(unit)
  if isNeverMarkUnit(unit, guid) then return false end
  if not isInCombat(unit) then return false end
  return true
end

-- Check if player is in combat
local function playerInCombat()
  return UnitAffectingCombat("player")
end

--=============================================================================
-- SECTION 5: HEALER/CASTER DETECTION
--=============================================================================

local function getKeywordList(db, key, fallback)
  if db and type(db[key]) == "table" and #db[key] > 0 then
    return db[key]
  end
  return fallback
end

-- Check if mob name matches healer keyword
local function nameMatchesHealer(name, db)
  if not name then return false end
  local lowerName = string.lower(name)
  
  for _, keyword in ipairs(getKeywordList(db, "healerKeywords", HEALER_KEYWORDS)) do
    if string.find(lowerName, keyword, 1, true) then
      return true
    end
  end
  return false
end

-- Check if mob name matches caster keyword
local function nameMatchesCaster(name, db)
  if not name then return false end
  local lowerName = string.lower(name)
  
  for _, keyword in ipairs(getKeywordList(db, "casterKeywords", CASTER_KEYWORDS)) do
    if string.find(lowerName, keyword, 1, true) then
      return true
    end
  end
  return false
end

local function nameMatchesSupport(name, db)
  if not name then return false end
  local lowerName = string.lower(name)

  for _, keyword in ipairs(getKeywordList(db, "supportKeywords", SUPPORT_KEYWORDS)) do
    if string.find(lowerName, keyword, 1, true) then
      return true
    end
  end
  return false
end

local function getHealerScore(unit, db)
  local threshold = (db and db.healerScoreThreshold) or 2
  local guid = UnitGUID(unit)
  local npcID = parseNPCIDFromGUID(guid)
  if npcID and whitelistHealers[npcID] then
    return threshold
  end

  local name = UnitName(unit)
  local score = 0
  if nameMatchesHealer(name, db) then score = score + 1 end
  if isManaUser(unit) then score = score + 1 end
  if (not db or db.useHealingCastScore ~= false) and isHealingCast(unit) then
    score = score + 1
  end

  return score
end

-- Get unit role based on scored healer detection + caster heuristics
local function getUnitRole(unit, db)
  local threshold = (db and db.healerScoreThreshold) or 2
  local healerScore = getHealerScore(unit, db)
  if healerScore >= threshold then
    return 3, healerScore -- Healer
  end

  local name = UnitName(unit)
  if nameMatchesCaster(name, db) then
    return 2, healerScore -- Caster
  end

  if nameMatchesSupport(name, db) then
    return 1, healerScore -- Support unit
  end

  if isManaUser(unit) then
    return 1, healerScore -- Mana user (possible caster/support)
  end

  return 0, healerScore -- Melee/non-priority
end

--=============================================================================
-- SECTION 6: ROLE-AWARE ACTIVATION
--=============================================================================

-- Check if marking is allowed based on role settings
local function isActivationAllowed(db)
  db = db or getDB()
  if not db then return true end -- Default allow if no config
  
  if not db.enabled then return false end

  if IsInRaid() then
    if db.allowInRaid == false then return false end
  elseif IsInGroup() then
    if db.allowInParty == false then return false end
  else
    if db.allowSolo == false then return false end
  end
  
  -- Check instance requirement
  if db.onlyInInstance then
    local inInstance, instanceType = IsInInstance()
    if not inInstance then return false end

    if db.disableInPVP ~= false and (instanceType == "pvp" or instanceType == "arena") then
      return false
    end
  elseif db.disableInPVP ~= false and UnitIsPVP and UnitIsPVP("player") then
    return false
  end
  
  -- Role-aware activation:
  -- default = solo always, grouped requires tank role unless force-enabled.
  local requireTankWhenGrouped = (db.tankOrSoloOnly ~= false) or db.tankOnly
  if requireTankWhenGrouped and IsInGroup() and db.forceEnable ~= true then
    local role = UnitGroupRolesAssigned and UnitGroupRolesAssigned("player")
    if role ~= "TANK" then
      -- Legacy fallback: if role is unset, allow tank-capable classes.
      local _, class = UnitClass("player")
      local canTankClass = (class == "WARRIOR" or class == "PALADIN" or class == "DRUID")
      if role ~= "NONE" or not canTankClass then
        return false
      end
    end
  end
  
  return true
end

--=============================================================================
-- SECTION 7: PACK DETECTION & COMBAT AWARENESS
--=============================================================================

-- Build set of friendly GUIDs (player, party, raid)
local function buildFriendlyGUIDSet()
  local friendly = {}
  
  -- Player and pet
  local playerGUID = UnitGUID("player")
  if playerGUID then friendly[playerGUID] = true end
  
  local petGUID = UnitGUID("pet")
  if petGUID then friendly[petGUID] = true end
  
  -- Group members
  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do
      local guid = UnitGUID("raid" .. i)
      if guid then friendly[guid] = true end
      local petGuid = UnitGUID("raidpet" .. i)
      if petGuid then friendly[petGuid] = true end
    end
  elseif IsInGroup() then
    for i = 1, GetNumSubgroupMembers() do
      local guid = UnitGUID("party" .. i)
      if guid then friendly[guid] = true end
      local petGuid = UnitGUID("partypet" .. i)
      if petGuid then friendly[petGuid] = true end
    end
  end
  
  return friendly
end

-- Get the current "pack" of enemies around the target
local function getCurrentPack()
  local pack = {}
  local packGUIDs = {}
  local friendlyGUIDs = buildFriendlyGUIDSet()
  
  -- Get all nameplate units
  local units = getNameplateUnits()
  local targetTargetGUID = UnitGUID("targettarget")
  
  for _, unit in ipairs(units) do
    if unit ~= "target" and isValidTarget(unit) then
      local guid = UnitGUID(unit)
      if guid and not packGUIDs[guid] then
        -- Check if this unit is engaged with our group
        local targetOf = unit .. "target"
        local victimGUID = UnitExists(targetOf) and UnitGUID(targetOf)
        
        local sameVictim = targetTargetGUID and victimGUID and victimGUID == targetTargetGUID
        local threateningUs = UnitThreatSituation and ((UnitThreatSituation("player", unit) or 0) > 0)
        local hittingFriendly = victimGUID and friendlyGUIDs[victimGUID]
        
        -- Include if engaged with our group/target context
        if sameVictim or threateningUs or hittingFriendly then
          pack[#pack + 1] = unit
          packGUIDs[guid] = true
        end
      end
    end
  end
  
  return pack, packGUIDs
end

-- Check if pack has switched (new pack detected)
local function detectPackSwitch(currentGUIDs, lastGUIDs, now, db)
  if not lastGUIDs or not next(lastGUIDs) then return false end

  local newGUIDs = 0
  for guid in pairs(currentGUIDs) do
    if not lastGUIDs[guid] then
      newGUIDs = newGUIDs + 1
    end
  end

  if newGUIDs == 0 then return false end

  local minNew = (db and db.packSwitchMinNewGUIDs) or 2
  if newGUIDs >= minNew then
    return true
  end

  local minGap = (db and db.packSwitchMinWaveGap) or 1.5
  return (now - (state.lastMarkWaveTime or 0)) >= minGap
end

local function getPriorityIcons(db)
  local fallback = db and db.useCCMode and CC_MODE_PRIORITY or DEFAULT_PRIORITY_AFTER_SKULL
  local raw = nil
  if db then
    raw = db.useCCMode and db.ccPriorityIcons or db.priorityIcons
  end
  if type(raw) ~= "table" or #raw == 0 then
    return fallback
  end

  local out, seen = {}, {}
  for i = 1, #raw do
    local icon = tonumber(raw[i])
    if icon and icon >= 1 and icon <= 8 and icon ~= ICON.SKULL and not seen[icon] then
      seen[icon] = true
      out[#out + 1] = icon
    end
  end
  if #out == 0 then
    return fallback
  end
  return out
end

local function getAnnounceChannel()
  if LE_PARTY_CATEGORY_INSTANCE and IsInGroup and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
    return "INSTANCE_CHAT"
  end
  if IsInRaid and IsInRaid() then
    return "RAID"
  end
  if IsInGroup and IsInGroup() then
    return "PARTY"
  end
  return nil
end

local function getInstanceAnnounceKey()
  local name, _, difficultyID, _, _, _, _, instanceID = GetInstanceInfo()
  if not name or name == "" then return nil end
  local instanceKey = (instanceID and instanceID > 0) and tostring(instanceID) or name
  -- Intentionally ignore roster composition so party churn inside the same run
  -- does not retrigger kill-order chat announcements.
  return string.format("%s:%s", instanceKey, tostring(difficultyID or 0))
end

local function buildKillOrderMessage(db)
  local maxIcons = tonumber(db.markCount or db.count or 5) or 5
  if maxIcons < 1 then maxIcons = 1 end
  if maxIcons > 8 then maxIcons = 8 end

  local orderedIcons = {}
  if db.healerAlwaysSkull then
    orderedIcons[#orderedIcons + 1] = ICON.SKULL
  end
  for _, icon in ipairs(getPriorityIcons(db)) do
    orderedIcons[#orderedIcons + 1] = icon
  end

  local parts = {}
  for i = 1, math.min(maxIcons, #orderedIcons) do
    local icon = orderedIcons[i]
    local label = ICON_LABELS[icon] or ("Icon" .. tostring(icon))
    if icon == ICON.SKULL and db.healerAlwaysSkull then
      local threshold = tonumber(db.healerScoreThreshold) or 2
      label = string.format("%s(healer>=%d)", label, threshold)
    end
    parts[#parts + 1] = string.format("{rt%d} %s", icon, label)
  end

  local mode = db.useCCMode and "CC order" or "kill order"
  return string.format("AMark %s: %s", mode, table.concat(parts, " > "))
end

--=============================================================================
-- SECTION 8: MARKING LOGIC
--=============================================================================

-- Clear all marks we placed
function AMark:ClearMarks(fullReset)
  local units = getNameplateUnits()
  
  for _, unit in ipairs(units) do
    local guid = UnitGUID(unit)
    if guid and state.markedGUIDs[guid] then
      if state.ownedGUIDsThisPull[guid] then
        clearMark(unit, true)
      end
      state.markedGUIDs[guid] = nil
    end
  end
  
  -- Also clear target
  if UnitExists("target") then
    local guid = UnitGUID("target")
    if guid and state.markedGUIDs[guid] then
      if state.ownedGUIDsThisPull[guid] then
        clearMark("target", true)
      end
      state.markedGUIDs[guid] = nil
    end
  end
  
  state.markedGUIDs = {}
  state.lastPackGUIDs = {}
  state.skullUsedThisPull = false
  if fullReset then
    state.ownedGUIDsThisPull = {}
    state.lastHostileCombatTime = 0
  end
end

-- Main marking function
function AMark:ApplyMarks()
  local db = getDB()
  if not db then return end
  if not db.enabled then
    self:ClearMarks()
    return
  end
  
  -- Check activation rules
  if not isActivationAllowed(db) then
    self:ClearMarks()
    return
  end
  
  -- Throttle scanning
  local now = GetTime()
  local throttle = db.scanThrottle or 0.2
  if state.lastScanTime and (now - state.lastScanTime) < throttle then
    return
  end
  state.lastScanTime = now
  
  -- Check combat requirement
  if db.markOnlyInCombat and not playerInCombat() then
    -- Only clear if we have marks and are out of combat
    if next(state.markedGUIDs) then
      self:ClearMarks(true)
    end
    return
  end
  
  local currentPack, currentGUIDs = getCurrentPack()
  if #currentPack > 0 then
    state.lastHostileCombatTime = now
  else
    -- Failsafe reset if combat-end event is missed
    local resetAfter = db.outOfCombatResetSeconds or 3
    if next(state.markedGUIDs) and state.lastHostileCombatTime > 0 and (now - state.lastHostileCombatTime) >= resetAfter then
      self:ClearMarks(true)
    end
    state.lastPackGUIDs = currentGUIDs
    return
  end
  
  -- Check for pack switch - clear marks on new pack
  if detectPackSwitch(currentGUIDs, state.lastPackGUIDs, now, db) then
    -- Soft reset only: avoid mass clear/set churn that can trigger group-action limits.
    state.markedGUIDs = {}
    state.ownedGUIDsThisPull = {}
    state.skullUsedThisPull = false
    state.lastMarkWaveTime = now
  end
  
  -- Determine priority order
  local priority = getPriorityIcons(db)
  local markCount = db.markCount or db.count or 5
  if markCount < 1 then markCount = 1 end
  if markCount > 5 then markCount = 5 end
  
  -- Sort pack by priority: higher healer score > casters > melee
  local function sortByPriority(a, b)
    local roleA, healerScoreA = getUnitRole(a, db)
    local roleB, healerScoreB = getUnitRole(b, db)
    if healerScoreA ~= healerScoreB then return healerScoreA > healerScoreB end
    if roleA ~= roleB then return roleA > roleB end
    
    -- Tie-breaker: lower HP = higher priority (dangerous targets first)
    local hpA = UnitHealth(a) or 0
    local hpB = UnitHealth(b) or 0
    if hpA ~= hpB then return hpA < hpB end
    
    -- Final tie-breaker: GUID comparison for consistency
    local guidA = UnitGUID(a) or ""
    local guidB = UnitGUID(b) or ""
    return guidA < guidB
  end
  
  table.sort(currentPack, sortByPriority)
  
  -- Assign marks
  local markedThisCycle = {}
  local usedIcons = {}
  local marksChanged = false
  local markChangesThisScan = 0
  local maxChanges = tonumber(db.maxMarkChangesPerScan) or 1
  if maxChanges < 1 then maxChanges = 1 end
  
  for i, unit in ipairs(currentPack) do
    local iconIndex
    
    if i == 1 then
      -- First unit: skull only when healer score reaches threshold
      local _, healerScore = getUnitRole(unit, db)
      local threshold = db.healerScoreThreshold or 2
      if db.healerAlwaysSkull and healerScore >= threshold then
        iconIndex = ICON.SKULL
        state.skullUsedThisPull = true
      else
        iconIndex = priority[1] or ICON.CROSS
      end
    else
      -- Subsequent units: use priority list
      local priorityIndex = i - 1
      if state.skullUsedThisPull then
        priorityIndex = priorityIndex -- Skull used, shift up
      end
      iconIndex = priority[priorityIndex] or (priority[1] or ICON.CROSS)
    end
    
    -- Skip if this icon already used this pull (avoid duplicates)
    local alreadyUsed = usedIcons[iconIndex]
    
    if not alreadyUsed then
      local guid = UnitGUID(unit)
      local currentMark = GetRaidTargetIndex(unit)

      if currentMark and currentMark == iconIndex then
        -- Keep icon reservation this cycle, but do not claim manual marks as ours.
        if guid and state.ownedGUIDsThisPull[guid] then
          state.markedGUIDs[guid] = iconIndex
        end
        markedThisCycle[#markedThisCycle + 1] = iconIndex
        usedIcons[iconIndex] = true
      elseif safeSetRaidTarget(unit, iconIndex) then
        markedThisCycle[#markedThisCycle + 1] = iconIndex
        usedIcons[iconIndex] = true
        marksChanged = true
        markChangesThisScan = markChangesThisScan + 1
      end
    end
    
    -- Stop after markCount icons
    if #markedThisCycle >= markCount then break end
    if markChangesThisScan >= maxChanges then break end
  end
  
  state.lastPackGUIDs = currentGUIDs
  if marksChanged then
    state.lastMarkWaveTime = now
  end
end

--=============================================================================
-- SECTION 9: EVENT HANDLERS
--=============================================================================

function AMark:TryAnnounceKillOrder(reason)
  local db = getDB()
  if not db or db.enabled == false or db.announceKillOrderOnZoneIn == false then
    return
  end
  if reason ~= "enter_world" and reason ~= "zone_changed" then
    return
  end
  if not isActivationAllowed(db) then
    return
  end

  local now = GetTime()
  local inInstance = IsInInstance()
  local inGroup = IsInGroup() or IsInRaid()
  if not inInstance or not inGroup then
    if state.outsideInstanceSince == 0 then
      state.outsideInstanceSince = now
    else
      local resetAfter = tonumber(db.announceOutsideResetSeconds) or 600
      if (now - state.outsideInstanceSince) >= resetAfter then
        state.lastAnnounceKey = nil
      end
    end
    return
  end

  if state.outsideInstanceSince > 0 then
    local resetAfter = tonumber(db.announceOutsideResetSeconds) or 600
    if (now - state.outsideInstanceSince) >= resetAfter then
      state.lastAnnounceKey = nil
    end
    state.outsideInstanceSince = 0
  end

  if IsInRaid() and not canSetRaidMarkers(db) then
    return
  end

  local channel = getAnnounceChannel()
  if not channel then return end

  local announceKey = getInstanceAnnounceKey()
  if not announceKey then return end
  if state.lastAnnounceKey == announceKey then
    return
  end

  -- Minor anti-burst guard for back-to-back zoning events.
  if (now - (state.lastAnnounceAt or 0)) < 2.0 then
    return
  end

  local msg = buildKillOrderMessage(db)
  if not msg or msg == "" then return end

  local ok = pcall(SendChatMessage, msg, channel)
  if ok then
    state.lastAnnounceKey = announceKey
    state.lastAnnounceAt = now
  end
end

function AMark:ScheduleKillOrderAnnounce(reason, delay)
  local db = getDB()
  if not db or db.announceKillOrderOnZoneIn == false then
    return
  end

  state.pendingAnnounceToken = (state.pendingAnnounceToken or 0) + 1
  local token = state.pendingAnnounceToken
  local wait = tonumber(delay) or 1.0
  if wait < 0 then wait = 0 end

  if C_Timer and C_Timer.After then
    C_Timer.After(wait, function()
      if token ~= state.pendingAnnounceToken then return end
      AMark:TryAnnounceKillOrder(reason)
    end)
  else
    self:TryAnnounceKillOrder(reason)
  end
end

function AMark:OnCombatStart()
  state.combatStartTime = GetTime()
  state.markedGUIDs = {}
  state.ownedGUIDsThisPull = {}
  state.lastPackGUIDs = {}
  state.skullUsedThisPull = false
  state.lastMarkWaveTime = 0
  state.lastHostileCombatTime = state.combatStartTime
  state.lastRaidActionTime = 0
end

function AMark:OnCombatEnd()
  state.combatStartTime = nil
  -- Clear all marks when combat ends
  self:ClearMarks(true)
end

function AMark:OnSettingChanged()
  if not getDB() or not getDB().enabled then
    self:ClearMarks()
  else
    self:ApplyMarks()
  end
end

-- Called when DB is ready (hooked by Core.lua)
function AMark:OnDBReady()
  self:Init()
end

-- Event frame setup
function AMark:Init()
  if self._frame then return end
  
  -- Ensure config exists
  if not HitTools.DB then HitTools.DB = {} end
  if not HitTools.DB.amark then
    HitTools.DB.amark = getDefaultConfig()
  else
    local defaults = getDefaultConfig()
    for key, value in pairs(defaults) do
      if HitTools.DB.amark[key] == nil then
        HitTools.DB.amark[key] = value
      end
    end
    -- Migrate prior default (90s) to the new default (600s) without touching custom values.
    if tonumber(HitTools.DB.amark.announceOutsideResetSeconds) == 90 then
      HitTools.DB.amark.announceOutsideResetSeconds = 600
    end
  end
  
  local f = CreateFrame("Frame")
  self._frame = f
  
  -- Register events
  f:RegisterEvent("PLAYER_TARGET_CHANGED")
  f:RegisterEvent("RAID_TARGET_UPDATE")
  f:RegisterEvent("PLAYER_REGEN_DISABLED")  -- Enter combat
  f:RegisterEvent("PLAYER_REGEN_ENABLED")   -- Leave combat
  f:RegisterEvent("PLAYER_ENTERING_WORLD")
  f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
  
  f:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_TARGET_CHANGED" then
      AMark:ApplyMarks()
    elseif event == "RAID_TARGET_UPDATE" then
      -- Reconcile marks if they're out of sync
      local now = GetTime()
      if not state.lastScanTime or (now - state.lastScanTime) > 0.5 then
        AMark:ApplyMarks()
      end
    elseif event == "PLAYER_REGEN_DISABLED" then
      AMark:OnCombatStart()
    elseif event == "PLAYER_REGEN_ENABLED" then
      AMark:OnCombatEnd()
    elseif event == "PLAYER_ENTERING_WORLD" then
      AMark:ScheduleKillOrderAnnounce("enter_world", 1.2)
    elseif event == "ZONE_CHANGED_NEW_AREA" then
      AMark:ScheduleKillOrderAnnounce("zone_changed", 0.8)
    end
  end)

  -- Periodic scan for failsafe reset; actual scan rate is still throttled in ApplyMarks().
  f:SetScript("OnUpdate", function(_, elapsed)
    state.scanTicker = (state.scanTicker or 0) + (elapsed or 0)
    if state.scanTicker < 0.1 then return end
    state.scanTicker = 0
    AMark:ApplyMarks()
  end)
  
  -- Initial apply
  self:ApplyMarks()
end

--=============================================================================
-- SECTION 10: PUBLIC API
--=============================================================================

-- Force refresh marks
function AMark:Refresh()
  self:ClearMarks()
  self:ApplyMarks()
end

-- Get current marked count
function AMark:GetMarkedCount()
  local count = 0
  for _ in pairs(state.markedGUIDs) do
    count = count + 1
  end
  return count
end

-- Debug function
function AMark:DumpState()
  local db = getDB()
  print("=== AMark State ===")
  print("Enabled:", db and db.enabled or "nil")
  print("In Combat:", playerInCombat())
  print("Marked Count:", self:GetMarkedCount())
  print("Skull Used:", state.skullUsedThisPull)
end

-- Export for options panel
function AMark:GetConfig()
  return HitTools.DB and HitTools.DB.amark or getDefaultConfig()
end

function AMark:SetConfig(key, value)
  if not HitTools.DB then HitTools.DB = {} end
  if not HitTools.DB.amark then
    HitTools.DB.amark = getDefaultConfig()
  end
  HitTools.DB.amark[key] = value
  self:OnSettingChanged()
end

function AMark:ResetConfig()
  HitTools.DB.amark = getDefaultConfig()
  self:OnSettingChanged()
end

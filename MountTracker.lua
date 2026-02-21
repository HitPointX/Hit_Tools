local _, HitTools = ...

HitTools.MountTracker = HitTools.MountTracker or {}
local MountTracker = HitTools.MountTracker

-- Boss database: Mount bosses with drop rates
-- Format: ["BossKey"] = { mount data + detection data }
-- Excludes 100% drop rate mounts per user preference
local MOUNT_BOSSES = {
  -- Classic
  ["Rivendare"] = {
    mountName = "Rivendare's Deathcharger",
    instance = "Stratholme",
    instanceShort = "Strat",
    size = "5",
    difficulty = "",
    bossName = "Baron Rivendare",
    baseDropPercent = 1,
    bossNames = {"Baron Rivendare", "Lord Aurius Rivendare"},
    creatureID = 10440,
  },

  -- The Burning Crusade
  ["Raven Lord"] = {
    mountName = "Raven Lord",
    instance = "Sethekk Halls",
    instanceShort = "Seth",
    size = "5",
    difficulty = "H",
    bossName = "Anzu",
    baseDropPercent = 1,
    bossNames = {"Anzu"},
    creatureID = 23035,
  },

  ["White Hawkstrider"] = {
    mountName = "Swift White Hawkstrider",
    instance = "Magisters' Terrace",
    instanceShort = "MGT",
    size = "5",
    difficulty = "H",
    bossName = "Kael'thas Sunstrider",
    baseDropPercent = 4,
    bossNames = {"Kael'thas Sunstrider"},
    creatureID = 24664,
  },

  ["Fiery Warhorse"] = {
    mountName = "Fiery Warhorse",
    instance = "Karazhan",
    instanceShort = "Kara",
    size = "10",
    difficulty = "",
    bossName = "Attumen the Huntsman",
    baseDropPercent = 1,
    bossNames = {"Attumen the Huntsman"},
    creatureID = 16151,
  },

  ["Ashes of Al'ar"] = {
    mountName = "Ashes of Al'ar",
    instance = "The Eye",
    instanceShort = "TK",
    size = "25",
    difficulty = "",
    bossName = "Kael'thas Sunstrider",
    baseDropPercent = 2,
    bossNames = {"Kael'thas Sunstrider"},
    creatureID = 19622,
  },

  -- Wrath of the Lich King
  ["Blue Proto-Drake"] = {
    mountName = "Blue Proto-Drake",
    instance = "Utgarde Pinnacle",
    instanceShort = "UP",
    size = "5",
    difficulty = "H",
    bossName = "Skadi the Ruthless",
    baseDropPercent = 1,
    bossNames = {"Skadi the Ruthless"},
    creatureID = 26693,
  },

  ["Azure Drake"] = {
    mountName = "Azure Drake",
    instance = "The Eye of Eternity",
    instanceShort = "EoE",
    size = "10",
    difficulty = "",
    bossName = "Malygos",
    baseDropPercent = 4,
    bossNames = {"Malygos"},
    creatureID = 28859,
  },

  ["Blue Drake"] = {
    mountName = "Blue Drake",
    instance = "The Eye of Eternity",
    instanceShort = "EoE",
    size = "25",
    difficulty = "",
    bossName = "Malygos",
    baseDropPercent = 4,
    bossNames = {"Malygos"},
    creatureID = 28859,
  },

  ["Onyxian Drake"] = {
    mountName = "Onyxian Drake",
    instance = "Onyxia's Lair",
    instanceShort = "Ony",
    size = "10",
    difficulty = "",
    bossName = "Onyxia",
    baseDropPercent = 1,
    bossNames = {"Onyxia"},
    creatureID = 10184,
  },

  ["Mimiron's Head"] = {
    mountName = "Mimiron's Head",
    instance = "Ulduar",
    instanceShort = "Uld",
    size = "25",
    difficulty = "",
    bossName = "Yogg-Saron",
    baseDropPercent = 1,
    bossNames = {"Yogg-Saron"},
    creatureID = 33288,
  },

  ["Invincible"] = {
    mountName = "Invincible",
    instance = "Icecrown Citadel",
    instanceShort = "ICC",
    size = "25",
    difficulty = "H",
    bossName = "The Lich King",
    baseDropPercent = 1,
    bossNames = {"The Lich King"},
    creatureID = 36597,
  },

  -- Cataclysm
  ["Drake of the North Wind"] = {
    mountName = "Drake of the North Wind",
    instance = "The Vortex Pinnacle",
    instanceShort = "VP",
    size = "5",
    difficulty = "",
    bossName = "Altairus",
    baseDropPercent = 0.5,
    bossNames = {"Altairus"},
    creatureID = 43873,
  },

  ["Vitreous Stone Drake"] = {
    mountName = "Vitreous Stone Drake",
    instance = "The Stonecore",
    instanceShort = "SC",
    size = "5",
    difficulty = "",
    bossName = "Slabhide",
    baseDropPercent = 0.5,
    bossNames = {"Slabhide"},
    creatureID = 43214,
  },

  ["Flametalon of Alysrazor"] = {
    mountName = "Flametalon of Alysrazor",
    instance = "Firelands",
    instanceShort = "FL",
    size = "10",
    difficulty = "",
    bossName = "Alysrazor",
    baseDropPercent = 2,
    bossNames = {"Alysrazor"},
    creatureID = 52530,
  },

  ["Pureblood Fire Hawk"] = {
    mountName = "Pureblood Fire Hawk",
    instance = "Firelands",
    instanceShort = "FL",
    size = "10",
    difficulty = "",
    bossName = "Ragnaros",
    baseDropPercent = 1,
    bossNames = {"Ragnaros"},
    creatureID = 52409,
  },

  ["Swift Zulian Panther"] = {
    mountName = "Swift Zulian Panther",
    instance = "Zul'Gurub",
    instanceShort = "ZG",
    size = "5",
    difficulty = "H",
    bossName = "High Priestess Kilnara",
    baseDropPercent = 1,
    bossNames = {"High Priestess Kilnara"},
    creatureID = 52059,
  },

  ["Armored Razzashi Raptor"] = {
    mountName = "Armored Razzashi Raptor",
    instance = "Zul'Gurub",
    instanceShort = "ZG",
    size = "5",
    difficulty = "H",
    bossName = "Bloodlord Mandokir",
    baseDropPercent = 1,
    bossNames = {"Bloodlord Mandokir"},
    creatureID = 52151,
  },

  ["Drake of the South Wind"] = {
    mountName = "Drake of the South Wind",
    instance = "Throne of the Four Winds",
    instanceShort = "TotFW",
    size = "10",
    difficulty = "",
    bossName = "Al'Akir",
    baseDropPercent = 1,
    bossNames = {"Al'Akir"},
    creatureID = 46753,
  },

  ["Experiment 12-B"] = {
    mountName = "Experiment 12-B",
    instance = "Dragon Soul",
    instanceShort = "DS",
    size = "10",
    difficulty = "",
    bossName = "Ultraxion",
    baseDropPercent = 1,
    bossNames = {"Ultraxion"},
    creatureID = 55294,
  },

  ["Blazing Drake"] = {
    mountName = "Blazing Drake",
    instance = "Dragon Soul",
    instanceShort = "DS",
    size = "10",
    difficulty = "",
    bossName = "Madness of Deathwing",
    baseDropPercent = 5,
    bossNames = {"Madness of Deathwing", "Deathwing"},
    creatureID = 56173,
  },

  ["Life-Binder's Handmaiden"] = {
    mountName = "Life-Binder's Handmaiden",
    instance = "Dragon Soul",
    instanceShort = "DS",
    size = "25",
    difficulty = "H",
    bossName = "Madness of Deathwing",
    baseDropPercent = 2,
    bossNames = {"Madness of Deathwing", "Deathwing"},
    creatureID = 56173,
  },

  -- Mists of Pandaria
  ["Heavenly Onyx Cloud Serpent"] = {
    mountName = "Heavenly Onyx Cloud Serpent",
    instance = "Kun-Lai Summit",
    instanceShort = "World",
    size = "WB",
    difficulty = "",
    bossName = "Sha of Anger",
    baseDropPercent = 0.5,
    bossNames = {"Sha of Anger"},
    creatureID = 60491,
  },

  ["Son of Galleon"] = {
    mountName = "Son of Galleon",
    instance = "Valley of the Four Winds",
    instanceShort = "World",
    size = "WB",
    difficulty = "",
    bossName = "Galleon",
    baseDropPercent = 0.5,
    bossNames = {"Galleon"},
    creatureID = 62346,
  },

  ["Thundering Cobalt Cloud Serpent"] = {
    mountName = "Thundering Cobalt Cloud Serpent",
    instance = "Isle of Thunder",
    instanceShort = "World",
    size = "WB",
    difficulty = "",
    bossName = "Nalak",
    baseDropPercent = 0.5,
    bossNames = {"Nalak", "Nalak, The Storm Lord"},
    creatureID = 69099,
  },

  ["Cobalt Primordial Direhorn"] = {
    mountName = "Cobalt Primordial Direhorn",
    instance = "Isle of Giants",
    instanceShort = "World",
    size = "WB",
    difficulty = "",
    bossName = "Oondasta",
    baseDropPercent = 0.5,
    bossNames = {"Oondasta"},
    creatureID = 69161,
  },

  ["Thundering Onyx Cloud Serpent"] = {
    mountName = "Thundering Onyx Cloud Serpent",
    instance = "Timeless Isle",
    instanceShort = "World",
    size = "RS",
    difficulty = "",
    bossName = "Huolon",
    baseDropPercent = 1,
    bossNames = {"Huolon"},
    creatureID = 73167,
  },

  ["Astral Cloud Serpent"] = {
    mountName = "Astral Cloud Serpent",
    instance = "Mogu'shan Vaults",
    instanceShort = "MSV",
    size = "10",
    difficulty = "",
    bossName = "Elegon",
    baseDropPercent = 1,
    bossNames = {"Elegon"},
    creatureID = 60410,
  },

  ["Spawn of Horridon"] = {
    mountName = "Spawn of Horridon",
    instance = "Throne of Thunder",
    instanceShort = "ToT",
    size = "10",
    difficulty = "",
    bossName = "Horridon",
    baseDropPercent = 1,
    bossNames = {"Horridon"},
    creatureID = 68476,
  },

  ["Clutch of Ji-Kun"] = {
    mountName = "Clutch of Ji-Kun",
    instance = "Throne of Thunder",
    instanceShort = "ToT",
    size = "10",
    difficulty = "",
    bossName = "Ji-Kun",
    baseDropPercent = 1,
    bossNames = {"Ji-Kun"},
    creatureID = 69712,
  },

  ["Kor'kron Juggernaut"] = {
    mountName = "Kor'kron Juggernaut",
    instance = "Siege of Orgrimmar",
    instanceShort = "SoO",
    size = "20",
    difficulty = "M",
    bossName = "Garrosh Hellscream",
    baseDropPercent = 1,
    bossNames = {"Garrosh Hellscream"},
    creatureID = 71865,
  },

  -- Warlords of Draenor
  ["Solar Spirehawk"] = {
    mountName = "Solar Spirehawk",
    instance = "Spires of Arak",
    instanceShort = "World",
    size = "WB",
    difficulty = "",
    bossName = "Rukhmar",
    baseDropPercent = 1,
    bossNames = {"Rukhmar"},
    creatureID = 83746,
  },
}

-- Difficulty suffix mapping for ENCOUNTER_START difficultyID
local DIFFICULTY_SUFFIX = {
  [1] = "",      -- 10-man normal
  [2] = "H",     -- 25-man heroic (some raids)
  [3] = "",      -- 10-man normal
  [4] = "H",     -- 25-man heroic
  [5] = "",      -- 5-man normal
  [6] = "H",     -- 5-man heroic
  [7] = "",      -- 25-man normal
  [8] = "H",     -- 25-man heroic
  [14] = "",     -- Normal
  [15] = "H",    -- Heroic
  [16] = "M",    -- Mythic
}

-- Extract creature ID from GUID
-- GUID format: "Creature-0-3113-0-47-10440-00003AD5D7"
-- Returns: 10440 (creatureID)
function MountTracker:GetCreatureIDFromGUID(guid)
  if not guid or type(guid) ~= "string" then return nil end
  local parts = {strsplit("-", guid)}
  if #parts >= 6 then
    return tonumber(parts[6])
  end
  return nil
end

-- Find boss key by name or creature ID
function MountTracker:FindBossKey(bossName, creatureID)
  for key, data in pairs(MOUNT_BOSSES) do
    -- Try creatureID match first (most reliable)
    if creatureID and data.creatureID == creatureID then
      return key
    end

    -- Fallback to name matching
    if bossName then
      for _, name in ipairs(data.bossNames) do
        if bossName == name then
          return key
        end
      end
    end
  end
  return nil
end

-- Calculate drop chance with bad luck protection
-- Formula: baseChance + (kills × baseChance/10), capped at 99.9%
function MountTracker:CalculateDropChance(bossKey)
  local bossData = MOUNT_BOSSES[bossKey]
  if not bossData then return 0, 0 end

  local baseChance = bossData.baseDropPercent
  local kills = (HitTools.DB and HitTools.DB.mounts and HitTools.DB.mounts.kills[bossKey]) or 0

  -- Apply bad luck protection formula
  local chance = baseChance + (kills * (baseChance / 10))

  -- Cap at 99.9%
  if chance > 99.9 then chance = 99.9 end

  return chance, kills
end

-- Called when a boss is pulled
function MountTracker:OnBossPull(bossKey)
  if not HitTools.DB or not HitTools.DB.mounts or not HitTools.DB.mounts.enabled then
    return
  end

  local bossData = MOUNT_BOSSES[bossKey]
  if not bossData then return end

  -- Anti-spam protection: only trigger once per 5 seconds
  local now = GetTime()
  if self.lastBossPull and (now - self.lastBossPull) < 5 then
    return
  end
  self.lastBossPull = now

  -- Increment kill count
  if not HitTools.DB.mounts.kills then
    HitTools.DB.mounts.kills = {}
  end
  local kills = (HitTools.DB.mounts.kills[bossKey] or 0) + 1
  HitTools.DB.mounts.kills[bossKey] = kills

  -- Calculate drop chance
  local chance = self:CalculateDropChance(bossKey)

  -- Format and print message
  local msg = string.format(
    "%s (%s) — Drop: %.1f%% (base %.1f%%) | Kills: %d",
    bossData.mountName,
    bossData.bossName,
    chance,
    bossData.baseDropPercent,
    kills
  )

  HitTools:Print(msg)
end

-- ENCOUNTER_START handler (primary detection for raids)
function MountTracker:OnEncounterStart(encounterID, encounterName, difficultyID, groupSize)
  -- Try to match by encounter name
  local bossKey = self:FindBossKey(encounterName, nil)
  if bossKey then
    self:OnBossPull(bossKey)
  end
end

-- PLAYER_TARGET_CHANGED handler (fallback for 5-mans and rares)
function MountTracker:OnTargetChanged()
  if not UnitExists("target") then return end

  local name = UnitName("target")
  local guid = UnitGUID("target")
  local classification = UnitClassification("target")

  -- Extract creature ID from GUID
  local creatureID = self:GetCreatureIDFromGUID(guid)

  -- Match against MOUNT_BOSSES by name or creatureID
  local bossKey = self:FindBossKey(name, creatureID)
  if not bossKey then return end

  -- Only trigger if in combat or targeting a world boss/rare
  local inCombat = UnitAffectingCombat("player") or UnitAffectingCombat("target")
  local isSpecial = classification == "worldboss" or classification == "rareelite" or classification == "elite"

  if inCombat or isSpecial then
    -- Set pending pull for combat start validation
    self.pendingBossPull = bossKey
    -- Also trigger immediately if already in combat
    if inCombat then
      self:OnBossPull(bossKey)
      self.pendingBossPull = nil
    end
  end
end

-- COMBAT_LOG_EVENT_UNFILTERED handler (validation layer)
function MountTracker:OnCombatLog()
  if not CombatLogGetCurrentEventInfo then return end

  local _, subevent, _, sourceGUID, sourceName = CombatLogGetCurrentEventInfo()

  -- Track when boss engages (spell cast or melee)
  if subevent == "SPELL_CAST_START" or subevent == "SPELL_CAST_SUCCESS" or subevent == "SWING_DAMAGE" then
    local creatureID = self:GetCreatureIDFromGUID(sourceGUID)
    if creatureID then
      local bossKey = self:FindBossKey(sourceName, creatureID)
      if bossKey then
        -- Boss is actively fighting, validate any pending pulls
        if self.pendingBossPull == bossKey then
          self:OnBossPull(bossKey)
          self.pendingBossPull = nil
        end
      end
    end
  end
end

-- Combat start handler
function MountTracker:OnCombatStart()
  -- If we have a pending boss pull, trigger it now
  if self.pendingBossPull then
    self:OnBossPull(self.pendingBossPull)
    self.pendingBossPull = nil
  end
end

-- Combat end handler
function MountTracker:OnCombatEnd()
  -- Clear pending pulls
  self.pendingBossPull = nil
end

-- Initialize the tracker
function MountTracker:OnDBReady()
  if self._frame then return end

  local f = CreateFrame("Frame")
  self._frame = f

  -- Register events
  f:RegisterEvent("ENCOUNTER_START")
  f:RegisterEvent("PLAYER_TARGET_CHANGED")
  f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
  f:RegisterEvent("PLAYER_REGEN_DISABLED")  -- Combat start
  f:RegisterEvent("PLAYER_REGEN_ENABLED")   -- Combat end

  f:SetScript("OnEvent", function(_, event, ...)
    if event == "ENCOUNTER_START" then
      local encounterID, encounterName, difficultyID, groupSize = ...
      MountTracker:OnEncounterStart(encounterID, encounterName, difficultyID, groupSize)
      return
    end

    if event == "PLAYER_TARGET_CHANGED" then
      MountTracker:OnTargetChanged()
      return
    end

    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
      MountTracker:OnCombatLog()
      return
    end

    if event == "PLAYER_REGEN_DISABLED" then
      MountTracker:OnCombatStart()
      return
    end

    if event == "PLAYER_REGEN_ENABLED" then
      MountTracker:OnCombatEnd()
      return
    end
  end)
end

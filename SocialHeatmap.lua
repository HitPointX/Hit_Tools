--[[
═══════════════════════════════════════════════════════════════════════════════
  HIT-TOOLS SOCIAL HEATMAP
  "Who do I actually vibe with (and win with)?"
═══════════════════════════════════════════════════════════════════════════════

WHAT IT TRACKS:
- Players you group with (party/raid) in dungeons/raids
- Run frequency, success rate, wipe rate, death stats
- Role distribution (tank/healer/dps inferred per run)
- Optional: Social sentiment from chat (disabled by default)
- Pairing synergy: success rate when grouped with specific players

HOW SCORING WORKS:
- Synergy Score = 60% outcomes + 20% stability + 20% vibe
- Outcomes: completes vs wipes
- Stability: death rate, consistent performance
- Vibe: optional chat positivity (must be enabled)
- Labels: "Smooth Runs" (green), "Mixed" (yellow), "Spicy" (red)
- NO TOXIC LABELING: uses neutral, friendly language

PRIVACY GUARANTEE:
- ALL DATA IS LOCAL ONLY - never uploaded, never broadcast, never shared
- Stored in your SavedVariables (HitToolsDB.social)
- You can reset individual players or all data at any time
- Social sentiment tracking is OPT-IN and disabled by default
- This is for YOUR personal insights, not for judging others

DATA RETENTION:
- Keeps last 500 runs maximum (auto-prunes oldest)
- Player stats are aggregated and compacted over time
- No raw combat logs stored (only aggregates)

═══════════════════════════════════════════════════════════════════════════════
]]--

local _, HitTools = ...

HitTools.SocialHeatmap = HitTools.SocialHeatmap or {}
local Social = HitTools.SocialHeatmap

-- Debug helper
local function DebugPrint(...)
  if HitTools.DB and HitTools.DB.social and HitTools.DB.social.debug then
    print("[Social]", ...)
  end
end

--[[═══════════════════════════════════════════════════════════════════════════
  PERFORMANCE & SAFETY CONFIGURATION
═══════════════════════════════════════════════════════════════════════════════

WHY CAPS EXIST:
- Prevent unbounded memory growth during long play sessions
- Keep SavedVariables file size reasonable (<5 MB recommended)
- Maintain fast lookup times (O(1) hash tables, not huge linear scans)
- Prevent GC pressure from massive data structures

PRUNING STRATEGY:
- LRU (Least Recently Used): Keep players/runs you've seen recently
- Prune oldest runs first (ring buffer style)
- When pruning a player, also clean up their pairings to avoid orphans

PAIRING STRATEGY (Prevents O(n²) explosion in raids):
- Party (≤5 players): Track all pairings (manageable, ~10-25 pairs)
- Raids (>5 players): Only track user + other players (You+X), not X+Y
- This keeps pairings linear O(n) instead of quadratic O(n²)
- 25-man raid: 25 pairings instead of 300!

═══════════════════════════════════════════════════════════════════════════]]

-- Hard Caps (MUST NOT EXCEED)
local MAX_PLAYERS_STORED = 2000         -- Prune LRU (oldest lastSeen)
local MAX_RUNS_STORED = 500             -- Prune oldest first
local MAX_PAIRINGS_STORED = 10000       -- Prune least runsTogether
local MAX_DUNGEON_KEYS_PER_PLAYER = 50  -- Prune least-run dungeons
local MAX_NOTES_LENGTH = 256            -- Clamp on save
local MAX_TAGS_PER_PLAYER = 8           -- Prevent tag spam
local MAX_CHAT_SAMPLES_PER_RUN = 200    -- For sentiment (if enabled)

-- Configuration Constants
local RUN_INACTIVITY_TIMEOUT = 600  -- 10 minutes
local WIPE_DEATH_THRESHOLD = 3  -- 3+ deaths in 12 seconds
local WIPE_DEATH_WINDOW = 12
local MIN_RUN_TIME_FOR_METRICS = 480  -- 8 minutes
local MIN_COMBAT_TIME_FOR_METRICS = 120  -- 2 minutes
local MIN_SAMPLE_SIZE = 3  -- 3 runs before showing ratings

-- Heartbeat State Monitor (STEP 2)
local HEARTBEAT_INTERVAL = 1.0  -- Check run state every 1.0s when ACTIVE
local HEARTBEAT_TOKEN_TIMEOUT = 10  -- Old ticker tokens expire after 10s
local LEFT_INSTANCE_END_DELAY = 15   -- Delay EndRun to absorb quick re-zones/death run-backs
local SAME_RUN_RESUME_WINDOW = 30    -- Dedupe window for same-run key
local GROUP_CHANGE_MEMBER_THRESHOLD = 2
local GROUP_CHANGE_SHARED_RATIO_MIN = 0.5
local GROUP_DISBAND_GRACE_SECONDS = 20
local NEW_RUN_START_DELAY = 0.5

-- Rate Limit Intervals (seconds)
local RATE_ROSTER_SCAN = 1.0           -- At most every 1.0s
local RATE_UI_REFRESH = 0.25           -- At most every 0.25s
local RATE_FRIENDS_SCAN = 5.0          -- At most every 5s
local RATE_ROLE_INFERENCE = 2.0        -- At most every 2s per unit
local RATE_WIPE_CHECK = 0.5            -- At most every 0.5s
local RATE_COMPACTION = 1800           -- Auto-compact every 30 min
local RATE_DBG_MSG = 2.0               -- Debug messages: at most every 2s per key

-- Combat Log Event Whitelist (PERFORMANCE CRITICAL)
-- Only process these events to reduce hot-path overhead
local COMBAT_EVENT_WHITELIST = {
  UNIT_DIED = true,
  SWING_DAMAGE = true,
  SPELL_DAMAGE = true,
  SPELL_PERIODIC_DAMAGE = true,
  RANGE_DAMAGE = true,
  SPELL_HEAL = true,
  SPELL_PERIODIC_HEAL = true,
}

-- Role constants
local ROLE_UNKNOWN = "UNKNOWN"
local ROLE_TANK = "TANK"
local ROLE_HEALER = "HEALER"
local ROLE_DPS = "DPS"

-- Synergy score thresholds
local SYNERGY_SMOOTH = 0.7  -- >= 70% = green
local SYNERGY_SPICY = 0.4   -- < 40% = red

-- Friend management constants
local BNET_INVITE_COOLDOWN = 60  -- 60 seconds between BNet invites per player

-- Social sentiment keywords (opt-in)
local POSITIVE_KEYWORDS = {
  "gj", "ty", "thanks", "thx", "nice", "wp", "good", "great",
  "awesome", "lol", "haha", "heal", "gg", "gratz", "gz"
}
local NEGATIVE_KEYWORDS = {
  "idiot", "noob", "trash", "wtf", "fail", "bad", "terrible", "worst"
}

-- Run State Machine (Prevents duplicate/orphaned runs)
local RUN_STATE_IDLE = 0
local RUN_STATE_ACTIVE = 1
local RUN_STATE_ENDING = 2

--[[═══════════════════════════════════════════════════════════════════════════
  RATE LIMITER UTILITY
═══════════════════════════════════════════════════════════════════════════════

Prevents expensive operations from running too frequently.
Usage: if not RateLimit:Allow("mykey", 1.0) then return end

Internally tracks last execution time per key.
Returns true if enough time has passed, false otherwise.
═══════════════════════════════════════════════════════════════════════════════]]

local RateLimit = {
  lastRun = {}  -- [key] = timestamp
}

function RateLimit:Allow(key, intervalSeconds)
  local now = GetTime()
  local last = self.lastRun[key] or 0

  if now - last >= intervalSeconds then
    self.lastRun[key] = now
    return true
  end

  return false
end

function RateLimit:Reset(key)
  self.lastRun[key] = nil
end

--[[═══════════════════════════════════════════════════════════════════════════
  DEBUG HELPER (STEP 1)
═══════════════════════════════════════════════════════════════════════════
Rate-limited debug printing. Only prints if debug enabled and message not repeated.
Usage: Social:Dbg("StartRun", "reason=%s groupSize=%d", reason, groupSize)
═══════════════════════════════════════════════════════════════════════════]]

function Social:Dbg(key, fmt, ...)
  if not (HitTools.DB and HitTools.DB.social and HitTools.DB.social.debug) then
    return
  end
  if not RateLimit:Allow("dbg_" .. key, RATE_DBG_MSG) then
    return
  end
  print(string.format("[Social:%s] " .. fmt, key, ...))
end

--[[═══════════════════════════════════════════════════════════════════════════
  PERFORMANCE TELEMETRY (Optional Debug)
═══════════════════════════════════════════════════════════════════════════════]]

local PerfCounters = {
  combatEventsProcessed = 0,
  combatEventsSkipped = 0,
  rosterScansAllowed = 0,
  rosterScansBlocked = 0,
  uiRefreshesAllowed = 0,
  uiRefreshesBlocked = 0,
  wipesDetected = 0,
  runsStarted = 0,
  runsEnded = 0,
  lastCompactionTime = 0,
  lastResetTime = GetTime(),
}

function PerfCounters:Reset()
  for k in pairs(self) do
    if type(self[k]) == "number" then
      self[k] = 0
    end
  end
  self.lastResetTime = GetTime()
end

function PerfCounters:GetReport()
  return {
    combatEventsProcessed = self.combatEventsProcessed,
    combatEventsSkipped = self.combatEventsSkipped,
    rosterScansAllowed = self.rosterScansAllowed,
    rosterScansBlocked = self.rosterScansBlocked,
    uiRefreshesAllowed = self.uiRefreshesAllowed,
    uiRefreshesBlocked = self.uiRefreshesBlocked,
    runsStarted = self.runsStarted,
    runsEnded = self.runsEnded,
    wipesDetected = self.wipesDetected,
    lastCompactionTime = self.lastCompactionTime
  }
end

--[[═══════════════════════════════════════════════════════════════════════════
  HELPER FUNCTIONS
═══════════════════════════════════════════════════════════════════════════════]]

-- Scratch tables for hot-path reuse (PERFORMANCE CRITICAL)
-- Prevents per-event allocations in combat log handler
local scratchTable1 = {}
local scratchTable2 = {}

-- Generate normalized player key: "Name-Realm"
--[[═══════════════════════════════════════════════════════════════════════════
  GUID-FIRST PLAYER IDENTITY SYSTEM
  Eliminates duplicates by using GUID as canonical ID
═══════════════════════════════════════════════════════════════════════════]]

-- Normalize name-realm to consistent format
local function NormalizeFullName(name, realm)
  if not name then return nil end

  -- Remove realm suffix if embedded in name
  name = name:gsub("%-.*", "")

  -- Trim whitespace
  name = name:match("^%s*(.-)%s*$")

  -- Capitalize first letter, lowercase rest (WoW standard)
  if #name > 0 then
    name = name:sub(1, 1):upper() .. name:sub(2):lower()
  end

  -- Normalize realm
  if realm then
    realm = realm:match("^%s*(.-)%s*$")
    if #realm > 0 then
      realm = realm:sub(1, 1):upper() .. realm:sub(2):lower()
    else
      realm = nil
    end
  end

  -- Use current realm if none provided
  realm = realm or GetRealmName()

  return string.format("%s-%s", name, realm or "Unknown")
end

-- Follow alias chain to canonical ID
local function ResolveAlias(id)
  if not id then return nil end

  local db = HitTools.DB and HitTools.DB.social
  if not db or not db.aliases then return id end

  local visited = {}
  local current = id

  -- Follow alias chain (max 10 hops to prevent infinite loops)
  for i = 1, 10 do
    if visited[current] then
      -- Circular reference, break
      return current
    end

    visited[current] = true
    local next = db.aliases[current]

    if not next then
      -- End of chain
      return current
    end

    current = next
  end

  return current
end

-- Resolve player identity to canonical ID
local function ResolveId(guid, name, realm)
  local db = HitTools.DB and HitTools.DB.social
  if not db then return nil end

  -- GUID always wins if available
  if guid and guid ~= "" then
    return ResolveAlias(guid)
  end

  -- Fall back to name-based lookup
  local fullName = NormalizeFullName(name, realm)
  if not fullName then return nil end

  -- Check name index
  if db.nameIndex and db.nameIndex[fullName] then
    return ResolveAlias(db.nameIndex[fullName])
  end

  -- Return temporary NAME: ID
  return "NAME:" .. fullName
end

-- OLD FUNCTIONS (kept for compatibility during migration)
local function getPlayerKey(name, realm)
  return NormalizeFullName(name, realm)
end

-- Get player key from GUID (OLD - deprecated)
local function getPlayerKeyFromGUID(guid)
  if not guid then return nil end

  -- Try to find unit by GUID
  local function checkUnit(unit)
    if UnitExists(unit) and UnitGUID(unit) == guid then
      local name, realm = UnitName(unit)
      return getPlayerKey(name, realm)
    end
    return nil
  end

  -- Check party/raid members
  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do
      local key = checkUnit("raid" .. i)
      if key then return key end
    end
  elseif IsInGroup() then
    for i = 1, GetNumSubgroupMembers() do
      local key = checkUnit("party" .. i)
      if key then return key end
    end
    local key = checkUnit("player")
    if key then return key end
  end

  return nil
end

-- Get current group roster
local function getCurrentRoster()
  local roster = {}

  local function addToRoster(unit)
    if UnitExists(unit) and UnitIsPlayer(unit) then
      local name, realm = UnitName(unit)
      local _, class = UnitClass(unit)
      local guid = UnitGUID(unit)

      -- Use GUID-first identity resolution
      local id = ResolveId(guid, name, realm)
      if id then
        roster[id] = {
          name = name,
          realm = realm or GetRealmName(),
          class = class,
          guid = guid,
          unit = unit,
        }
      end
    end
  end

  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do
      addToRoster("raid" .. i)
    end
  elseif IsInGroup() then
    for i = 1, GetNumSubgroupMembers() do
      addToRoster("party" .. i)
    end
    addToRoster("player")
  end

  return roster
end

local function getCurrentGroupSize()
  if IsInRaid() then
    return GetNumGroupMembers() or 0
  elseif IsInGroup() then
    return (GetNumSubgroupMembers() or 0) + 1
  end
  return 1
end

local function simpleHash(text)
  local hash = 5381
  for i = 1, #text do
    hash = (hash * 33 + string.byte(text, i)) % 2147483647
  end
  return tostring(hash)
end

local function buildRosterSetAndSignature(roster)
  local ids = {}
  local set = {}
  for id in pairs(roster or {}) do
    ids[#ids + 1] = id
    set[id] = true
  end
  table.sort(ids)
  local sig = table.concat(ids, "|")
  return set, sig, simpleHash(sig), #ids
end

local function getLeaderIdFromRoster(roster)
  for id, playerData in pairs(roster or {}) do
    local unit = playerData and playerData.unit
    if unit and UnitExists(unit) and UnitIsGroupLeader(unit) then
      return id
    end
  end
  return nil
end

local function compareRosterSets(baseSet, currentSet)
  local shared = 0
  local baseCount = 0
  local currentCount = 0
  local added = 0
  local removed = 0

  for id in pairs(baseSet or {}) do
    baseCount = baseCount + 1
    if currentSet and currentSet[id] then
      shared = shared + 1
    else
      removed = removed + 1
    end
  end

  for id in pairs(currentSet or {}) do
    currentCount = currentCount + 1
    if not (baseSet and baseSet[id]) then
      added = added + 1
    end
  end

  local maxCount = math.max(baseCount, currentCount, 1)
  local sharedRatio = shared / maxCount

  return {
    shared = shared,
    baseCount = baseCount,
    currentCount = currentCount,
    added = added,
    removed = removed,
    changedMembers = added + removed,
    sharedRatio = sharedRatio,
  }
end

local function buildRunKey(instanceID, startTime, rosterHash)
  local startBucket = math.floor((startTime or 0) / 60)
  return string.format("%s:%d:%s", tostring(instanceID or 0), startBucket, tostring(rosterHash or "0"))
end

-- Infer role from combat activity (basic heuristics)
local function inferRole(playerKey, combatData)
  if not combatData then return ROLE_UNKNOWN end

  local healing = combatData.healingDone or 0
  local damage = combatData.damageDone or 0
  local damageTaken = combatData.damageTaken or 0

  -- Healer: healing > damage significantly
  if healing > damage * 2 and healing > 10000 then
    return ROLE_HEALER
  end

  -- Tank: high damage taken + moderate threat
  if damageTaken > damage and damageTaken > 20000 then
    return ROLE_TANK
  end

  -- Default to DPS
  if damage > 0 then
    return ROLE_DPS
  end

  return ROLE_UNKNOWN
end

-- Calculate synergy score
local function calculateSynergyScore(playerData)
  if not playerData or not playerData.aggregates then
    return 0, "Not enough data"
  end

  local agg = playerData.aggregates
  local totalRuns = (agg.completes or 0) + (agg.wipes or 0)

  if totalRuns < MIN_SAMPLE_SIZE then
    return 0, "Not enough data"
  end

  -- Outcome score (60%): complete rate
  local completeRate = totalRuns > 0 and (agg.completes or 0) / totalRuns or 0
  local outcomeScore = completeRate * 0.6

  -- Stability score (20%): inverse of death rate
  local avgDeaths = totalRuns > 0 and (agg.deathsTotal or 0) / totalRuns or 0
  local stabilityScore = math.max(0, (1 - avgDeaths / 5)) * 0.2  -- Normalize to ~5 deaths

  -- Vibe score (20%): social signals (if enabled)
  local vibeScore = 0.15  -- Neutral default
  if HitTools.DB and HitTools.DB.social and HitTools.DB.social.sentimentEnabled then
    local friendliness = agg.social and agg.social.friendlinessScore or 0
    vibeScore = math.min(0.2, friendliness / 50) * 0.2  -- Cap at 50 points
  end

  local totalScore = outcomeScore + stabilityScore + vibeScore

  -- Determine label
  local label = "Mixed"
  if totalScore >= SYNERGY_SMOOTH then
    label = "Smooth Runs"
  elseif totalScore < SYNERGY_SPICY then
    label = "Spicy"
  end

  return totalScore, label
end

--[[═══════════════════════════════════════════════════════════════════════════
  DATA MODEL INITIALIZATION
═══════════════════════════════════════════════════════════════════════════════]]

function Social:InitializeDB()
  if not HitTools.DB then return end
  if not HitTools.DB.social then
    HitTools.DB.social = {}
  end

  local db = HitTools.DB.social

  -- Initialize new GUID-first structures
  if not db.playersById then db.playersById = {} end
  if not db.aliases then db.aliases = {} end
  if not db.nameIndex then db.nameIndex = {} end
  if not db.runs then db.runs = {} end
  if not db.pairings then db.pairings = {} end
  if db.sentimentEnabled == nil then db.sentimentEnabled = false end
  if db.debug == nil then db.debug = false end  -- Debug logging flag
  if db.compactionVersion == nil then db.compactionVersion = 0 end

  -- ONE-TIME MIGRATION: Migrate old db.players to db.playersById
  if db.players and next(db.players) ~= nil and db.compactionVersion < 1 then
    DebugPrint("Migrating old players table to GUID-first system...")
    local migratedCount = 0
    local skippedCount = 0

    for oldKey, playerData in pairs(db.players) do
      -- Old key format was "Name-Realm"
      local normalizedName = NormalizeFullName(playerData.name, playerData.realm)

      -- Check if we already have this player by name
      local existingId = db.nameIndex[normalizedName]

      if existingId then
        -- Already migrated, skip
        skippedCount = skippedCount + 1
      else
        -- Create NAME: ID for this player
        local newId = "NAME:" .. normalizedName

        -- Copy player data to new structure
        db.playersById[newId] = playerData
        db.nameIndex[normalizedName] = newId

        -- Create alias from old key to new ID
        if oldKey ~= normalizedName then
          db.aliases[oldKey] = newId
        end

        migratedCount = migratedCount + 1
      end
    end

    -- Clear old players table after migration
    db.players = nil

    db.compactionVersion = 1
    DebugPrint(string.format("Migration complete: %d players migrated, %d skipped", migratedCount, skippedCount))
  end

  -- Ensure old db.players is removed after migration
  if db.compactionVersion >= 1 then
    db.players = nil
  end

  -- Runtime state
  self.currentRun = nil
  self.currentRunRoster = nil  -- STEP 3: Snapshot roster (persists even after group disbands)
  self.runState = RUN_STATE_IDLE  -- State machine
  self.runIdCounter = 0  -- Monotonic counter for session
  self.rosterCache = {}
  self.combatData = {}  -- Temp combat tracking
  self.recentDeaths = {}  -- For wipe detection
  self.lastCombatTime = 0
  self.lastCompactionTime = 0  -- Track auto-compaction
  self.lastTransitionKey = nil
  self.pendingEndAt = nil
  self.pendingEndReason = nil
  self.pendingEndSource = nil
  self.pendingStartToken = 0
  self.lastEndedRunMeta = nil

  -- STEP 2: Heartbeat state monitor
  self.heartbeatTicker = nil  -- Active ticker handle
  self.heartbeatToken = 0  -- Token increments on each StartRun, old tickers expire

  -- Performance counters
  self.perfCounters = PerfCounters
end

-- GUID-FIRST: Ensure player record exists and is up to date
function Social:EnsurePlayerRecord(guid, name, realm, class)
  local db = HitTools.DB.social
  if not db or not db.playersById then return nil end

  -- Resolve to canonical ID
  local id = ResolveId(guid, name, realm)
  if not id then return nil end

  local normalizedName = NormalizeFullName(name, realm)

  -- Check for GUID migration: if we have a NAME: ID but now have a GUID
  if guid and guid ~= "" and id:match("^NAME:") then
    -- Check if a GUID record already exists for this player
    local guidRecord = db.playersById[guid]
    local nameRecord = db.playersById[id]

    if guidRecord and nameRecord then
      -- Merge NAME record into GUID record
      self:MergePlayerRecords(guid, id)
      id = guid
    elseif nameRecord and not guidRecord then
      -- Promote NAME record to GUID
      db.playersById[guid] = nameRecord
      db.playersById[id] = nil
      db.aliases[id] = guid
      db.nameIndex[normalizedName] = guid
      id = guid
    elseif guidRecord and not nameRecord then
      -- GUID record already exists, use it
      db.aliases[id] = guid
      db.nameIndex[normalizedName] = guid
      id = guid
    end
  end

  -- Create record if it doesn't exist
  if not db.playersById[id] then
    local now = GetTime()
    db.playersById[id] = {
      guid = guid or nil,
      name = name or "Unknown",
      realm = realm or GetRealmName(),
      class = class or "UNKNOWN",
      faction = UnitFactionGroup("player"),
      firstSeen = now,
      lastSeen = now,
      runsTogether = 0,
      timeTogetherSeconds = 0,
      rolesObserved = {TANK = 0, HEALER = 0, DPS = 0, UNKNOWN = 0},
      dungeons = {},
      aggregates = {
        completes = 0,
        wipes = 0,
        deathsTotal = 0,
        personalDeathsTotal = 0,
        performance = {},
        social = {
          friendlinessScore = 0,
          chatCount = 0,
          emoteCount = 0,
        },
      },
      notes = "",
      tags = {},
      friend = {
        isCharFriend = false,
        bnet = nil,
        lastInviteAt = nil,
        inviteNote = "Met in WoW!",
      },
    }
  end

  -- Update metadata (GUID might become known later)
  local player = db.playersById[id]
  if guid and guid ~= "" and not player.guid then
    player.guid = guid
  end
  if name then player.name = name end
  if realm then player.realm = realm end
  if class and class ~= "UNKNOWN" then player.class = class end
  player.lastSeen = GetTime()

  -- Update name index
  if normalizedName then
    db.nameIndex[normalizedName] = id
  end

  -- Backward compatibility: ensure friend field exists
  if not player.friend then
    player.friend = {
      isCharFriend = false,
      bnet = nil,
      lastInviteAt = nil,
      inviteNote = "Met in WoW!",
    }
  end

  return player, id
end

-- OLD FUNCTION: kept for backward compatibility
function Social:GetOrCreatePlayer(playerKey, initialData)
  local name = initialData and initialData.name
  local realm = initialData and initialData.realm
  local class = initialData and initialData.class
  local guid = initialData and initialData.guid
  return self:EnsurePlayerRecord(guid, name, realm, class)
end

-- Export local functions for external access
function Social:ResolveId(guid, name, realm)
  return ResolveId(guid, name, realm)
end

function Social:NormalizeFullName(name, realm)
  return NormalizeFullName(name, realm)
end

function Social:ResolveAlias(id)
  return ResolveAlias(id)
end

-- Merge two player records (used during GUID migration)
function Social:MergePlayerRecords(keepId, removeId)
  local db = HitTools.DB.social
  if not db or not db.playersById then return end

  local keepRecord = db.playersById[keepId]
  local removeRecord = db.playersById[removeId]

  if not keepRecord or not removeRecord then return end

  -- Merge aggregates (add them together)
  keepRecord.runsTogether = (keepRecord.runsTogether or 0) + (removeRecord.runsTogether or 0)
  keepRecord.timeTogetherSeconds = (keepRecord.timeTogetherSeconds or 0) + (removeRecord.timeTogetherSeconds or 0)

  -- Merge aggregates
  local keepAgg = keepRecord.aggregates
  local removeAgg = removeRecord.aggregates
  keepAgg.completes = (keepAgg.completes or 0) + (removeAgg.completes or 0)
  keepAgg.wipes = (keepAgg.wipes or 0) + (removeAgg.wipes or 0)
  keepAgg.deathsTotal = (keepAgg.deathsTotal or 0) + (removeAgg.deathsTotal or 0)
  keepAgg.personalDeathsTotal = (keepAgg.personalDeathsTotal or 0) + (removeAgg.personalDeathsTotal or 0)

  -- Merge roles (take max)
  for role, count in pairs(removeRecord.rolesObserved or {}) do
    keepRecord.rolesObserved[role] = math.max(keepRecord.rolesObserved[role] or 0, count)
  end

  -- Merge dungeons
  for dungeonKey, dungeonData in pairs(removeRecord.dungeons or {}) do
    if not keepRecord.dungeons[dungeonKey] then
      keepRecord.dungeons[dungeonKey] = dungeonData
    else
      local kd = keepRecord.dungeons[dungeonKey]
      kd.runs = (kd.runs or 0) + (dungeonData.runs or 0)
      kd.completes = (kd.completes or 0) + (dungeonData.completes or 0)
      kd.wipes = (kd.wipes or 0) + (dungeonData.wipes or 0)
      kd.deathsTotal = (kd.deathsTotal or 0) + (dungeonData.deathsTotal or 0)
      kd.timeSecondsTotal = (kd.timeSecondsTotal or 0) + (dungeonData.timeSecondsTotal or 0)
    end
  end

  -- Keep earliest firstSeen
  if removeRecord.firstSeen and removeRecord.firstSeen < keepRecord.firstSeen then
    keepRecord.firstSeen = removeRecord.firstSeen
  end

  -- Keep latest lastSeen
  if removeRecord.lastSeen and removeRecord.lastSeen > keepRecord.lastSeen then
    keepRecord.lastSeen = removeRecord.lastSeen
  end

  -- Merge tags (union)
  for _, tag in ipairs(removeRecord.tags or {}) do
    local found = false
    for _, existingTag in ipairs(keepRecord.tags or {}) do
      if existingTag == tag then
        found = true
        break
      end
    end
    if not found then
      table.insert(keepRecord.tags, tag)
    end
  end

  -- Keep notes if keepRecord has none
  if not keepRecord.notes or keepRecord.notes == "" then
    keepRecord.notes = removeRecord.notes or ""
  end

  -- Create alias
  db.aliases[removeId] = keepId

  -- Remove old record
  db.playersById[removeId] = nil

  DebugPrint(string.format("Merged player records: %s -> %s", removeId, keepId))
end

-- Compact players database (manual and auto-run)
function Social:CompactPlayers()
  local db = HitTools.DB.social
  if not db or not db.playersById then return end

  DebugPrint("Running player compaction...")

  local mergedCount = 0
  local aliasedCount = 0

  -- Build name -> IDs mapping to find duplicates
  local nameToIds = {}
  for id, player in pairs(db.playersById) do
    local normalizedName = NormalizeFullName(player.name, player.realm)
    if normalizedName then
      if not nameToIds[normalizedName] then
        nameToIds[normalizedName] = {}
      end
      table.insert(nameToIds[normalizedName], id)
    end
  end

  -- For each name that has multiple IDs, merge them
  for normalizedName, ids in pairs(nameToIds) do
    if #ids > 1 then
      -- Prefer GUID over NAME: IDs
      local guidId = nil
      local nameIds = {}

      for _, id in ipairs(ids) do
        if not id:match("^NAME:") then
          -- This is a GUID
          if not guidId then
            guidId = id
          else
            -- Multiple GUIDs for same name - keep first, alias others
            db.aliases[id] = guidId
            aliasedCount = aliasedCount + 1
          end
        else
          table.insert(nameIds, id)
        end
      end

      -- Merge all NAME: IDs into the GUID (or keep one NAME: ID if no GUID)
      if guidId then
        for _, nameId in ipairs(nameIds) do
          self:MergePlayerRecords(guidId, nameId)
          mergedCount = mergedCount + 1
        end
        db.nameIndex[normalizedName] = guidId
      elseif #nameIds > 1 then
        -- No GUID, but multiple NAME: IDs - merge into first
        local keepId = nameIds[1]
        for i = 2, #nameIds do
          self:MergePlayerRecords(keepId, nameIds[i])
          mergedCount = mergedCount + 1
        end
        db.nameIndex[normalizedName] = keepId
      end
    end
  end

  HitTools:Print(string.format("Compaction complete: %d records merged, %d aliased", mergedCount, aliasedCount))

  -- Refresh UI if visible
  if HitTools.SocialUI and HitTools.SocialUI.RefreshPlayersTab then
    HitTools.SocialUI:RefreshPlayersTab()
  end
end

--[[═══════════════════════════════════════════════════════════════════════════
  FRIEND MANAGEMENT

  IMPORTANT LIMITATION:
  - WoW API does NOT expose other players' BattleTags from character names
  - BattleTag must be USER-ENTERED and stored locally
  - This feature is LOCAL-ONLY, never shares data
  - BNet invites can only be sent if user has manually provided the BattleTag
═══════════════════════════════════════════════════════════════════════════════]]

-- Refresh friends list cache
function Social:RefreshFriendsList()
  if not self.friendsListReady then
    -- TBC Anniversary compatibility: ShowFriends doesn't exist in modern client
    if ShowFriends then
      ShowFriends()
    elseif C_FriendList and C_FriendList.ShowFriends then
      C_FriendList.ShowFriends()
    end
    self.friendsListReady = true
  end

  if not HitTools.DB or not HitTools.DB.social then return end

  -- Build character friends set
  local charFriends = {}

  -- TBC Anniversary compatibility: use modern Friends API
  local numFriends = 0
  if C_FriendList and C_FriendList.GetNumFriends then
    numFriends = C_FriendList.GetNumFriends() or 0
  elseif GetNumFriends then
    numFriends = GetNumFriends() or 0
  end

  for i = 1, numFriends do
    local name
    -- TBC Anniversary compatibility
    if C_FriendList and C_FriendList.GetFriendInfoByIndex then
      local friendInfo = C_FriendList.GetFriendInfoByIndex(i)
      name = friendInfo and friendInfo.name
    elseif GetFriendInfo then
      name = GetFriendInfo(i)
    end

    if name then
      -- Normalize friend name and lookup in nameIndex
      local normalizedName = NormalizeFullName(name, GetRealmName())
      if normalizedName and HitTools.DB.social.nameIndex then
        local friendId = HitTools.DB.social.nameIndex[normalizedName]
        if friendId then
          charFriends[friendId] = true
        end
      end
    end
  end

  -- Update all tracked players
  for id, player in pairs(HitTools.DB.social.playersById) do
    if player.friend then
      player.friend.isCharFriend = charFriends[id] == true
    end
  end
end

-- Check if player is on character friends list
function Social:IsCharFriend(playerId)
  if not playerId then return false end

  local player = HitTools.DB.social.playersById[playerId]
  if not player or not player.friend then return false end

  return player.friend.isCharFriend == true
end

-- Add player to character friends list
function Social:AddFriendForPlayer(playerId)
  if not playerId then
    HitTools:Print("Invalid player")
    return
  end

  local player = HitTools.DB.social.playersById[playerId]
  if not player then
    HitTools:Print("Player not found in database")
    return
  end

  -- Check if in combat
  if InCombatLockdown() then
    HitTools:Print("Cannot add friends while in combat. Try again after combat.")
    return
  end

  -- Format name-realm for AddFriend
  local nameRealm = string.format("%s-%s", player.name, player.realm)

  -- Add to character friends list - TBC Anniversary compatibility
  if C_FriendList and C_FriendList.AddFriend then
    C_FriendList.AddFriend(nameRealm)
  elseif AddFriend then
    AddFriend(nameRealm)
  end

  -- Update cache optimistically
  if player.friend then
    player.friend.isCharFriend = true
  end

  HitTools:Print(string.format("Added %s to friends list!", player.name))

  -- Refresh friends list after a short delay
  C_Timer.After(0.5, function()
    self:RefreshFriendsList()
  end)
end

-- Set BattleTag for player
function Social:SetBattleTagForPlayer(playerId, battleTag)
  if not playerId or not battleTag then return end

  local player = HitTools.DB.social.playersById[playerId]
  if not player or not player.friend then return end

  -- Validate BattleTag format (basic)
  if not battleTag:match("%S+#%d+") and not battleTag:match("@") then
    HitTools:Print("Invalid BattleTag format. Expected: Name#1234 or email@example.com")
    return false
  end

  player.friend.bnet = battleTag
  HitTools:Print(string.format("BattleTag saved for %s: %s", player.name, battleTag))

  return true
end

-- Send Battle.net friend invite
function Social:SendBNetInviteForPlayer(playerId, note)
  if not playerId then
    HitTools:Print("Invalid player")
    return
  end

  local player = HitTools.DB.social.playersById[playerId]
  if not player or not player.friend then
    HitTools:Print("Player not found")
    return
  end

  -- Check if BattleTag is saved
  if not player.friend.bnet then
    HitTools:Print(string.format("No BattleTag saved for %s. Use: /hit social setbnet %s <BattleTag>",
      player.name, player.name))
    return
  end

  -- Check cooldown
  local now = GetTime()
  if player.friend.lastInviteAt and (now - player.friend.lastInviteAt) < BNET_INVITE_COOLDOWN then
    local timeLeft = math.ceil(BNET_INVITE_COOLDOWN - (now - player.friend.lastInviteAt))
    HitTools:Print(string.format("Please wait %d seconds before sending another invite", timeLeft))
    return
  end

  -- Check if in combat
  if InCombatLockdown() then
    HitTools:Print("Cannot send BNet invites while in combat. Try again after combat.")
    return
  end

  -- Send invite
  local inviteNote = note or player.friend.inviteNote or "Met in WoW!"
  BNSendFriendInvite(player.friend.bnet, inviteNote)

  -- Update last invite time
  player.friend.lastInviteAt = now

  HitTools:Print(string.format("Battle.net friend invite sent to %s (%s)", player.name, player.friend.bnet))
end

-- Combined: Add character friend + send BNet invite if BattleTag is saved
function Social:QuickAddFriend(playerId)
  if not playerId then return end

  -- Add to character friends
  self:AddFriendForPlayer(playerId)

  local player = HitTools.DB.social.playersById[playerId]
  if not player then return end

  -- Try to send Battle.net friend request (only works if they're in your party)
  C_Timer.After(0.5, function()
    if not InCombatLockdown() then
      -- Check if player is currently in group
      local isInGroup = false
      local numGroupMembers = IsInRaid() and GetNumGroupMembers() or (IsInGroup() and GetNumSubgroupMembers() + 1 or 0)

      for i = 1, numGroupMembers do
        local unit = IsInRaid() and ("raid" .. i) or (i == numGroupMembers and "player" or ("party" .. i))
        if UnitExists(unit) then
          local name, realm = UnitName(unit)
          local guid = UnitGUID(unit)
          local unitId = ResolveId(guid, name, realm)
          if unitId == playerId then
            isInGroup = true
            break
          end
        end
      end

      if isInGroup then
        -- Player is in group - try to send B.net request
        local nameRealm = string.format("%s-%s", player.name, player.realm)
        if BNSendFriendInvite then
          local success = pcall(BNSendFriendInvite, nameRealm, "Met in WoW!")
          if success then
            HitTools:Print(string.format("Battle.net friend request sent to %s!", player.name))
            if player.friend then
              player.friend.lastInviteAt = GetTime()
            end
            return
          end
        end
      else
        -- Player not in group - can't send B.net request via API
        if player.friend and player.friend.bnet then
          -- If BattleTag is manually saved, use that instead
          self:SendBNetInviteForPlayer(playerId)
        else
          HitTools:Print(string.format("Note: %s must be in your party to send B.net request. Added as character friend!", player.name))
        end
      end
    end
  end)
end

--[[═══════════════════════════════════════════════════════════════════════════
  RUN LIFECYCLE MANAGEMENT - State Machine
═══════════════════════════════════════════════════════════════════════════════

STATE MACHINE:
  IDLE -> ACTIVE (when entering instance with group)
  ACTIVE -> ENDING (when EndRun called)
  ENDING -> IDLE (after save completes)

SAFETY:
- Only one active run at a time (checked via state machine)
- StartRun ignores duplicates unless state is IDLE
- EndRun is idempotent (safe if called multiple times)
- Prevents orphaned runs from double-triggers

═══════════════════════════════════════════════════════════════════════════════]]

-- Heartbeat monitor: Check run state periodically while ACTIVE
-- Only runs while a run is active, checks for state changes that should trigger EndRun
function Social:CheckRunState(expectedToken)
  -- Token guard: Prevent old tickers from firing after reload or state change
  if expectedToken ~= self.heartbeatToken then
    self:Dbg("heartbeat", "Token mismatch (expected=%d, current=%d), stopping old ticker",
      expectedToken, self.heartbeatToken)
    return
  end

  -- Only check state if we're ACTIVE
  if self.runState ~= RUN_STATE_ACTIVE then
    return
  end

  -- Validate we have an active run
  if not self.currentRun then
    self:Dbg("heartbeat", "ACTIVE state but no currentRun, forcing EndRun")
    self:EndRun("heartbeat_orphaned")
    return
  end

  local now = GetTime()

  -- Query current instance state
  local inInstance, instanceType = IsInInstance()
  local name, _, _, _, _, _, _, instanceID = GetInstanceInfo()
  local groupSize = getCurrentGroupSize()
  local roster = getCurrentRoster()

  -- Left instance: use delayed end to absorb short re-zones/death run-backs.
  if not inInstance or instanceType == "none" then
    if not self.pendingEndAt then
      self:SchedulePendingEnd("heartbeat_left_instance", LEFT_INSTANCE_END_DELAY, "left_instance")
      self:SetTransition("PENDING_END", "left_instance")
    elseif now >= self.pendingEndAt then
      self:SetTransition("ENDING", "left_instance_timeout")
      self:EndRun(self.pendingEndReason or "heartbeat_left_instance_timeout")
    end
    return
  end

  -- Back in instance: cancel any pending delayed end.
  if self.pendingEndAt then
    self:CancelPendingEnd("reentered_instance")
    self:SetTransition("ACTIVE", "reentered")
  end

  -- Instance changed while active: end old run, then start new one shortly.
  if self.currentRun.instanceID and instanceID and instanceID ~= self.currentRun.instanceID then
    self:SetTransition("ENDING", "instance_changed")
    self:EndRun("heartbeat_instance_changed")
    self:ScheduleStartRun("instance_changed_new_run", NEW_RUN_START_DELAY)
    return
  end

  -- Group dissolved: only end after grace when not fighting.
  if groupSize < 2 then
    local sinceCombat = now - (self.lastCombatTime or 0)
    if sinceCombat >= GROUP_DISBAND_GRACE_SECONDS then
      self:SetTransition("ENDING", "group_dissolved")
      self:EndRun("heartbeat_solo")
    else
      self:SetTransition("ACTIVE", "group_low_grace")
    end
    return
  end

  -- Detect "new group in same instance" and split run cleanly.
  local significantChange, delta = self:IsSignificantGroupChange(self.currentRun, roster)
  if significantChange then
    self:SetTransition("ENDING", "group_changed")
    self:Dbg("run", "Group changed (added=%d removed=%d shared=%.2f leaderChanged=%s)",
      delta and (delta.added or 0) or 0,
      delta and (delta.removed or 0) or 0,
      delta and (delta.sharedRatio or 0) or 0,
      tostring(delta and delta.leaderChanged))

    self:EndRun("group_changed")
    self:ScheduleStartRun("group_changed_new_run", NEW_RUN_START_DELAY)
    return
  end

  -- Keep active run snapshot fresh for diagnostics.
  local _, groupSig, groupSigHash, rosterCount = buildRosterSetAndSignature(roster)
  self.currentRun.liveGroupSig = groupSig
  self.currentRun.liveGroupSigHash = groupSigHash
  self.currentRun.groupSize = groupSize
  self.currentRun.liveRosterCount = rosterCount
  self:SetTransition("ACTIVE", "stable")
end

-- Record roster snapshot immediately at run start
-- Creates minimal player records so they appear in UI instantly
-- Full stats are updated at EndRun via UpdatePlayerStats
function Social:RecordRosterSnapshot(roster)
  if not roster then return end

  local now = GetTime()
  local db = HitTools.DB.social
  local playersSeen = 0

  -- Get self ID
  local selfGUID = UnitGUID("player")
  local selfName, selfRealm = UnitName("player")
  local selfID = ResolveId(selfGUID, selfName, selfRealm)

  for id, playerData in pairs(roster) do
    -- Skip self
    if id and id ~= selfID then
      -- Create or get existing player record
      local player = self:EnsurePlayerRecord(playerData.guid, playerData.name, playerData.realm, playerData.class)

      -- Update lastSeen immediately so they appear in "recent" filters
      if player then
        player.lastSeen = now
      end

      playersSeen = playersSeen + 1
    end
  end

  self:Dbg("roster", "Recorded roster snapshot: %d players", playersSeen)

end

function Social:EmitDBUpdated(reason)
  if HitTools.SocialUI and HitTools.SocialUI.OnSocialDBUpdated then
    HitTools.SocialUI:OnSocialDBUpdated("SOCIAL_DB_UPDATED", reason)
  end
end

function Social:SetTransition(key, detail)
  if self.lastTransitionKey == key then return end
  self.lastTransitionKey = key
  self:Dbg("transition", "%s (%s)", tostring(key), tostring(detail or ""))
end

function Social:CancelPendingEnd(reason)
  if self.pendingEndAt then
    self:Dbg("transition", "Cancel pending end (%s)", tostring(reason or "none"))
  end
  self.pendingEndAt = nil
  self.pendingEndReason = nil
  self.pendingEndSource = nil
end

function Social:SchedulePendingEnd(reason, delaySeconds, source)
  local now = GetTime()
  local delay = delaySeconds or LEFT_INSTANCE_END_DELAY
  local deadline = now + delay

  if not self.pendingEndAt or deadline < self.pendingEndAt then
    self.pendingEndAt = deadline
    self.pendingEndReason = reason or "pending_end"
    self.pendingEndSource = source
    self:Dbg("transition", "Scheduled pending end in %.1fs (%s)", delay, tostring(reason))
  end
end

function Social:ScheduleStartRun(reason, delaySeconds)
  local delay = delaySeconds or NEW_RUN_START_DELAY
  self.pendingStartToken = (self.pendingStartToken or 0) + 1
  local token = self.pendingStartToken

  if C_Timer and C_Timer.After then
    C_Timer.After(delay, function()
      if token ~= self.pendingStartToken then return end
      if self.runState ~= RUN_STATE_IDLE then return end
      self:StartRun(reason or "scheduled")
    end)
  else
    if self.runState == RUN_STATE_IDLE then
      self:StartRun(reason or "scheduled_fallback")
    end
  end
end

function Social:IsSignificantGroupChange(currentRun, newRoster)
  if not currentRun then return false, nil end

  local newSet, _, _, _ = buildRosterSetAndSignature(newRoster)
  local baseSet = currentRun.startRosterSet or {}
  local delta = compareRosterSets(baseSet, newSet)
  local newLeaderId = getLeaderIdFromRoster(newRoster)
  local leaderChanged = (currentRun.leaderId and newLeaderId and currentRun.leaderId ~= newLeaderId) and true or false

  local significant = (delta.changedMembers >= GROUP_CHANGE_MEMBER_THRESHOLD) or
    (delta.sharedRatio < GROUP_CHANGE_SHARED_RATIO_MIN) or
    leaderChanged

  delta.leaderChanged = leaderChanged
  delta.newLeaderId = newLeaderId
  return significant, delta
end

function Social:StartRun(reason)
  reason = reason or "auto"
  local inInstance, instanceType = IsInInstance()
  if not inInstance or instanceType == "none" then
    if HitTools.DB and HitTools.DB.social and HitTools.DB.social.debug then
      HitTools:Print(string.format("[Social.StartRun] BLOCKED: not in instance (inInstance=%s, type=%s)", tostring(inInstance), tostring(instanceType)))
    end
    return
  end

  -- Check if in a group
  local groupSize = getCurrentGroupSize()
  if groupSize < 2 then
    if HitTools.DB and HitTools.DB.social and HitTools.DB.social.debug then
      HitTools:Print(string.format("[Social.StartRun] BLOCKED: solo (groupSize=%d)", groupSize))
    end
    return  -- Solo, don't track
  end

  local name, instanceType, difficulty, _, _, _, _, instanceID = GetInstanceInfo()
  if not name or name == "" then
    if HitTools.DB and HitTools.DB.social and HitTools.DB.social.debug then
      HitTools:Print("[Social.StartRun] BLOCKED: no instance name")
    end
    return
  end

  local roster = getCurrentRoster()
  local startRosterSet, groupSig, groupSigHash, rosterCount = buildRosterSetAndSignature(roster)
  local leaderId = getLeaderIdFromRoster(roster)
  local now = GetTime()

  -- STATE MACHINE CHECK: If not IDLE, check if this is a NEW instance/group
  if self.runState ~= RUN_STATE_IDLE then
    -- Check if instance or roster changed significantly
    local isDifferentInstance = not self.currentRun or self.currentRun.instanceID ~= instanceID
    local isDifferentGroup, delta = self:IsSignificantGroupChange(self.currentRun, roster)

    if isDifferentInstance or isDifferentGroup then
      self:Dbg("run", "Forcing cleanup (reason=%s, diffInst=%s, changed=%s, shared=%.2f)",
        tostring(reason), tostring(isDifferentInstance), tostring(isDifferentGroup), delta and (delta.sharedRatio or 0) or 0)
      self:EndRun("forced_cleanup_" .. tostring(reason))
    else
      -- Same instance and group - don't start duplicate
      if HitTools.DB and HitTools.DB.social and HitTools.DB.social.debug then
        HitTools:Print(string.format("[Social.StartRun] BLOCKED: runState=%d (not IDLE, same instance/group)", self.runState or -1))
      end
      return
    end
  end
  local rosterKeys = {}
  for key, data in pairs(roster) do
    rosterKeys[#rosterKeys + 1] = key
  end

  self.runIdCounter = self.runIdCounter + 1
  local runId = string.format("run_%d_%d", now, self.runIdCounter)
  local runKey = buildRunKey(instanceID, now, groupSigHash)

  self.currentRun = {
    runId = runId,
    runKey = runKey,
    sessionId = self.runIdCounter,  -- For deduplication
    timestampStart = now,
    instanceName = name,
    instanceID = instanceID,
    difficulty = difficulty,
    groupSize = groupSize,
    roster = roster,
    rosterKeys = rosterKeys,
    groupSig = groupSig,
    groupSigHash = groupSigHash,
    leaderId = leaderId,
    startRosterSet = startRosterSet,
    startRosterCount = rosterCount,
    wipeCount = 0,
    totalDeaths = 0,
    playerDeaths = {},
    playerCombat = {},
    complete = false,
  }

  -- Initialize combat tracking for each player
  for key in pairs(roster) do
    self.currentRun.playerCombat[key] = {
      damageDone = 0,
      healingDone = 0,
      damageTaken = 0,
      deaths = 0,
      combatTime = 0,
    }
  end

  self.rosterCache = roster
  self.lastCombatTime = now

  -- STEP 3: Snapshot roster for persistence (survives group disband)
  self.currentRunRoster = roster

  -- Reset delayed end guard on clean start
  self:CancelPendingEnd("start_run")

  -- EARLY ROSTER CAPTURE: Create minimal player records immediately
  -- This ensures players appear in UI right away, before run completes
  self:RecordRosterSnapshot(roster)

  -- TRANSITION STATE: IDLE -> ACTIVE
  self.runState = RUN_STATE_ACTIVE
  self.perfCounters.runsStarted = self.perfCounters.runsStarted + 1
  self:SetTransition("ACTIVE", reason)

  -- STEP 2: Start heartbeat ticker
  -- Increment token to invalidate any old tickers
  self.heartbeatToken = self.heartbeatToken + 1
  local token = self.heartbeatToken

  -- Cancel any existing ticker (shouldn't exist, but safety)
  if self.heartbeatTicker then
    self.heartbeatTicker:Cancel()
    self.heartbeatTicker = nil
  end

  -- Start new ticker if C_Timer available (TBC-safe fallback to nil check)
  if C_Timer and C_Timer.NewTicker then
    self.heartbeatTicker = C_Timer.NewTicker(HEARTBEAT_INTERVAL, function()
      -- Capture Social in closure
      local Social = self
      Social:CheckRunState(token)
    end)
    self:Dbg("heartbeat", "Started ticker (token=%d, interval=%.1fs)", token, HEARTBEAT_INTERVAL)
  else
    -- Fallback: No ticker available, rely on events only
    print("[Social] WARNING: C_Timer.NewTicker not available, using events only")
  end

  -- DIAGNOSTIC: Log run start
  if HitTools.DB and HitTools.DB.social and HitTools.DB.social.debug then
    HitTools:Print(string.format("[Social.StartRun] RUN STARTED: %s (ID=%s, reason=%s)", name, tostring(instanceID), tostring(reason)))
    HitTools:Print(string.format("  runKey=%s groupSize=%d rosterCount=%d timestamp=%.0f", tostring(runKey), groupSize, #rosterKeys, now))
    if #rosterKeys > 0 and #rosterKeys <= 5 then
      local rosterPreview = table.concat(rosterKeys, ", ")
      HitTools:Print(string.format("  roster: %s", rosterPreview))
    else
      HitTools:Print(string.format("  roster: %d players", #rosterKeys))
    end
  end

  self:EmitDBUpdated("run_started")
end

function Social:EndRun(reason)
  -- Don't process if already cleaned up (IDLE)
  if self.runState == RUN_STATE_IDLE and not self.currentRun then
    return
  end

  -- If stuck in ENDING, allow re-entry to force cleanup
  if self.runState == RUN_STATE_ENDING then
    DebugPrint("EndRun: Already ENDING, forcing cleanup")
  end

  self.runState = RUN_STATE_ENDING
  self:SetTransition("ENDING", reason)
  local run = self.currentRun

  local ok, err = true, nil
  if run then
    -- Wrap core logic in xpcall for crash safety
    ok, err = xpcall(function()
      run.timestampEnd = GetTime()
      run.duration = run.timestampEnd - run.timestampStart

      -- Determine completion
      if run.duration >= MIN_RUN_TIME_FOR_METRICS then
        local timeSinceLastWipe = run.timestampEnd - (run.lastWipeTime or 0)
        if timeSinceLastWipe > 180 then
          run.complete = true
        end
      end

      -- STEP 2: Verify roster before UpdatePlayerStats
      local rosterCount = 0
      local rosterSample = {}
      if run.roster then
        for key in pairs(run.roster) do
          rosterCount = rosterCount + 1
          if #rosterSample < 3 then
            table.insert(rosterSample, key)
          end
        end
      end
      DebugPrint(string.format("EndRun roster: count=%d sample=%s", rosterCount, table.concat(rosterSample, ",")))

      self:SaveRun(run)
      self:UpdatePlayerStats(run)

      -- Fire callback hook
      if HitTools.OnSocialRunEnded then
        HitTools:OnSocialRunEnded(run, reason)
      end
    end, function(err) return tostring(err) end)
  end

  if not ok then
    print("[Social] EndRun error: " .. tostring(err))
  end

  -- STEP 1: ALWAYS cleanup (finally block)
  -- Cancel heartbeat ticker
  if self.heartbeatTicker then
    self.heartbeatTicker:Cancel()
    self.heartbeatTicker = nil
    self:Dbg("heartbeat", "Cancelled ticker (reason=%s)", tostring(reason))
  end

  -- Increment token to invalidate any racing callbacks
  self.heartbeatToken = self.heartbeatToken + 1

  -- Clear run data
  self:CancelPendingEnd("end_run_cleanup")
  self.currentRun = nil
  self.currentRunRoster = nil
  self.combatData = {}
  self.recentDeaths = {}
  self.runState = RUN_STATE_IDLE
  self.perfCounters.runsEnded = self.perfCounters.runsEnded + 1
  self:SetTransition("IDLE", reason)

  -- Keep lightweight metadata for dedupe diagnostics / quick resume logic.
  if run then
    self.lastEndedRunMeta = {
      timestampEnd = run.timestampEnd or GetTime(),
      runKey = run.runKey,
      instanceID = run.instanceID,
      groupSigHash = run.groupSigHash,
      leaderId = run.leaderId,
      rosterSet = run.startRosterSet,
    }
  end

  self:EmitDBUpdated("run_ended")
end

function Social:SaveRun(run)
  local db = HitTools.DB.social

  local runData = {
    timestampStart = run.timestampStart,
    timestampEnd = run.timestampEnd,
    duration = run.duration,
    instanceName = run.instanceName,
    instanceID = run.instanceID,
    difficulty = run.difficulty,
    groupSize = run.groupSize,
    roster = run.rosterKeys,
    complete = run.complete,
    wipeCount = run.wipeCount,
    totalDeaths = run.totalDeaths,
    runKey = run.runKey,
    groupSigHash = run.groupSigHash,
  }

  -- Dedupe write: if a same-run key was saved recently, merge instead of duplicate.
  local mergeTargetId = nil
  local runKey = runData.runKey
  if runKey then
    for existingId, existingRun in pairs(db.runs) do
      if existingRun and existingRun.runKey == runKey then
        local startA = runData.timestampStart or 0
        local startB = existingRun.timestampStart or 0
        if math.abs(startA - startB) <= SAME_RUN_RESUME_WINDOW then
          mergeTargetId = existingId
          break
        end
      end
    end
  end

  if mergeTargetId then
    local existing = db.runs[mergeTargetId]
    existing.timestampStart = math.min(existing.timestampStart or runData.timestampStart or 0, runData.timestampStart or 0)
    existing.timestampEnd = math.max(existing.timestampEnd or runData.timestampEnd or 0, runData.timestampEnd or 0)
    existing.duration = math.max(existing.duration or 0, runData.duration or 0)
    existing.complete = (existing.complete or false) or (runData.complete or false)
    existing.wipeCount = math.max(existing.wipeCount or 0, runData.wipeCount or 0)
    existing.totalDeaths = math.max(existing.totalDeaths or 0, runData.totalDeaths or 0)
    existing.groupSize = math.max(existing.groupSize or 0, runData.groupSize or 0)
    existing.instanceName = existing.instanceName or runData.instanceName
    existing.instanceID = existing.instanceID or runData.instanceID
    existing.runKey = existing.runKey or runData.runKey
    existing.groupSigHash = existing.groupSigHash or runData.groupSigHash

    -- Merge roster keys into a unique list.
    local rosterSet = {}
    for _, id in ipairs(existing.roster or {}) do rosterSet[id] = true end
    for _, id in ipairs(runData.roster or {}) do rosterSet[id] = true end
    local mergedRoster = {}
    for id in pairs(rosterSet) do
      mergedRoster[#mergedRoster + 1] = id
    end
    table.sort(mergedRoster)
    existing.roster = mergedRoster
  else
    db.runs[run.runId] = runData
  end

  -- Prune old runs if over limit
  local runCount = 0
  for _ in pairs(db.runs) do runCount = runCount + 1 end

  if runCount > MAX_RUNS_STORED then
    local runList = {}
    for id, data in pairs(db.runs) do
      runList[#runList + 1] = {id = id, time = data.timestampStart}
    end
    table.sort(runList, function(a, b) return a.time < b.time end)

    local toDelete = runCount - MAX_RUNS_STORED
    for i = 1, toDelete do
      db.runs[runList[i].id] = nil
    end
  end
end

function Social:UpdatePlayerStats(run)
  local now = GetTime()
  local db = HitTools.DB.social

  -- STEP 3: Ensure playersById table exists
  if not db.playersById then
    DebugPrint("UpdatePlayerStats: db.playersById was nil, initializing")
    db.playersById = {}
  end

  -- STEP 3: Diagnostic counters
  local iterCount = 0
  local wroteCount = 0
  local skippedSelf = 0
  local skippedNoKey = 0

  -- Get player's canonical ID
  local playerGUID = UnitGUID("player")
  local playerName, playerRealm = UnitName("player")
  local playerID = ResolveId(playerGUID, playerName, playerRealm)

  for id, playerData in pairs(run.roster or {}) do
    iterCount = iterCount + 1

    if not id then
      skippedNoKey = skippedNoKey + 1
    elseif id == playerID then
      skippedSelf = skippedSelf + 1
    else
      wroteCount = wroteCount + 1
      local player = self:EnsurePlayerRecord(playerData.guid, playerData.name, playerData.realm, playerData.class)

      -- Update basic stats
      player.lastSeen = now
      player.runsTogether = player.runsTogether + 1
      player.timeTogetherSeconds = player.timeTogetherSeconds + (run.duration or 0)

      -- Update role observation
      local combat = run.playerCombat[id]
      local role = inferRole(id, combat)
      player.rolesObserved[role] = (player.rolesObserved[role] or 0) + 1

      -- Update aggregates
      if run.complete then
        player.aggregates.completes = player.aggregates.completes + 1
      else
        player.aggregates.wipes = player.aggregates.wipes + 1
      end

      local deaths = combat and combat.deaths or 0
      player.aggregates.deathsTotal = player.aggregates.deathsTotal + deaths
      player.aggregates.personalDeathsTotal = player.aggregates.personalDeathsTotal + deaths

      -- Update dungeon-specific stats
      local dungeonKey = run.instanceID or run.instanceName
      if not player.dungeons[dungeonKey] then
        player.dungeons[dungeonKey] = {
          runs = 0,
          completes = 0,
          wipes = 0,
          deathsTotal = 0,
          timeSecondsTotal = 0,
        }
      end

      local dungeon = player.dungeons[dungeonKey]
      dungeon.runs = dungeon.runs + 1
      dungeon.completes = dungeon.completes + (run.complete and 1 or 0)
      dungeon.wipes = dungeon.wipes + (run.complete and 0 or 1)
      dungeon.deathsTotal = dungeon.deathsTotal + deaths
      dungeon.timeSecondsTotal = dungeon.timeSecondsTotal + (run.duration or 0)

      -- Update pairings with smart strategy (party-only + user-centric for raids)
      local groupSize = run.groupSize or 0

      -- PAIRING STRATEGY:
      -- Party (≤5): Track all pairings
      -- Raid (>5): Only track user+other, not other+other
      if groupSize <= 5 then
        -- PARTY: Track all pairings
        for otherID in pairs(run.roster) do
          if otherID ~= id then
            self:UpdatePairing(id, otherID, run.complete)
          end
        end
      else
        -- RAID: Only track pairings involving the player
        if id == playerID then
          for otherID in pairs(run.roster) do
            if otherID ~= playerID then
              self:UpdatePairing(playerID, otherID, run.complete)
            end
          end
        end
        -- For non-player IDs: skip pairing updates (prevents O(n²) explosion)
      end
    end
  end

  -- STEP 3: Report only if wroteCount == 0
  if wroteCount == 0 then
    DebugPrint(string.format("UpdatePlayerStats wrote 0 players. Skipped: noKey=%d, selfFiltered=%d (iter=%d)", skippedNoKey, skippedSelf, iterCount))
  end
end

--[[═══════════════════════════════════════════════════════════════════════════
  DATABASE COMPACTION - Prevents unbounded growth
═══════════════════════════════════════════════════════════════════════════════

WHEN CALLED:
- Every 30 minutes during play (auto)
- On PLAYER_LOGOUT
- Manually via /hit social compact

WHAT IT DOES:
1. Prune oldest runs if > MAX_RUNS_STORED (500)
2. Prune least-recently-seen players if > MAX_PLAYERS_STORED (2000)
3. Prune least-used pairings if > MAX_PAIRINGS_STORED (10000)
4. Prune old dungeon keys per player if > MAX_DUNGEON_KEYS_PER_PLAYER (50)
5. Clamp notes length to MAX_NOTES_LENGTH (256)
6. Trim tags to MAX_TAGS_PER_PLAYER (8)
7. Remove empty tables and nil holes

═══════════════════════════════════════════════════════════════════════════════]]

function Social:CompactDB()
  local db = HitTools.DB and HitTools.DB.social
  if not db then return end

  local pruned = {players = 0, runs = 0, pairings = 0, dungeons = 0}

  -- 1. PRUNE RUNS: Keep newest MAX_RUNS_STORED runs only
  if db.runs then
    local runsList = {}
    for runId, run in pairs(db.runs) do
      table.insert(runsList, {id = runId, timestamp = run.timestampStart or 0})
    end

    if #runsList > MAX_RUNS_STORED then
      -- Sort by timestamp descending (newest first)
      table.sort(runsList, function(a, b) return a.timestamp > b.timestamp end)

      -- Delete oldest runs
      for i = MAX_RUNS_STORED + 1, #runsList do
        db.runs[runsList[i].id] = nil
        pruned.runs = pruned.runs + 1
      end
    end
  end

  -- 2. PRUNE PLAYERS: Keep MAX_PLAYERS_STORED most recent
  if db.playersById then
    local playersList = {}
    for id, player in pairs(db.playersById) do
      table.insert(playersList, {key = id, lastSeen = player.lastSeen or 0})
    end

    if #playersList > MAX_PLAYERS_STORED then
      -- Sort by lastSeen descending (most recent first)
      table.sort(playersList, function(a, b) return a.lastSeen > b.lastSeen end)

      -- Delete oldest players
      for i = MAX_PLAYERS_STORED + 1, #playersList do
        local id = playersList[i].key
        db.playersById[id] = nil

        -- Also delete their pairings (avoid orphans)
        if db.pairings and db.pairings[id] then
          db.pairings[id] = nil
        end
        for otherID, pairings in pairs(db.pairings or {}) do
          if pairings[id] then
            pairings[id] = nil
          end
        end

        pruned.players = pruned.players + 1
      end
    end

    -- 3. PRUNE DUNGEON KEYS PER PLAYER
    for id, player in pairs(db.playersById) do
      if player.dungeons then
        local dungeonsList = {}
        for dungeonKey, dungeonData in pairs(player.dungeons) do
          table.insert(dungeonsList, {key = dungeonKey, runs = dungeonData.runs or 0})
        end

        if #dungeonsList > MAX_DUNGEON_KEYS_PER_PLAYER then
          -- Sort by runs descending (most-run first)
          table.sort(dungeonsList, function(a, b) return a.runs > b.runs end)

          -- Delete least-run dungeons
          for i = MAX_DUNGEON_KEYS_PER_PLAYER + 1, #dungeonsList do
            player.dungeons[dungeonsList[i].key] = nil
            pruned.dungeons = pruned.dungeons + 1
          end
        end
      end

      -- Clamp notes length
      if player.notes and #player.notes > MAX_NOTES_LENGTH then
        player.notes = player.notes:sub(1, MAX_NOTES_LENGTH)
      end

      -- Trim tags
      if player.tags and #player.tags > MAX_TAGS_PER_PLAYER then
        local trimmed = {}
        for i = 1, MAX_TAGS_PER_PLAYER do
          trimmed[i] = player.tags[i]
        end
        player.tags = trimmed
      end
    end
  end

  -- 4. PRUNE PAIRINGS: Keep MAX_PAIRINGS_STORED most active
  if db.pairings then
    local pairingsList = {}
    for keyA, pairings in pairs(db.pairings) do
      for keyB, pairData in pairs(pairings) do
        table.insert(pairingsList, {
          keyA = keyA,
          keyB = keyB,
          runsTogether = pairData.runsTogether or 0
        })
      end
    end

    if #pairingsList > MAX_PAIRINGS_STORED then
      -- Sort by runsTogether descending (most runs first)
      table.sort(pairingsList, function(a, b) return a.runsTogether > b.runsTogether end)

      -- Delete least-active pairings
      for i = MAX_PAIRINGS_STORED + 1, #pairingsList do
        local pair = pairingsList[i]
        if db.pairings[pair.keyA] then
          db.pairings[pair.keyA][pair.keyB] = nil
        end
        pruned.pairings = pruned.pairings + 1
      end

      -- Clean up empty pairing tables
      for keyA, pairings in pairs(db.pairings) do
        local isEmpty = true
        for _ in pairs(pairings) do isEmpty = false break end
        if isEmpty then
          db.pairings[keyA] = nil
        end
      end
    end
  end

  self.lastCompactionTime = GetTime()
  self.perfCounters.lastCompactionTime = self.lastCompactionTime

  -- Report if anything was pruned
  local total = pruned.players + pruned.runs + pruned.pairings + pruned.dungeons
  if total > 0 then
    HitTools:Print(string.format(
      "Social Heatmap compacted: %d players, %d runs, %d pairings, %d dungeons pruned",
      pruned.players, pruned.runs, pruned.pairings, pruned.dungeons
    ))
  end

  return pruned
end

--[[═══════════════════════════════════════════════════════════════════════════
  UpdatePairing - SMART PAIRING STRATEGY
═══════════════════════════════════════════════════════════════════════════════

PREVENTS O(n²) EXPLOSION IN RAIDS:

Party content (≤5 players):
  - Track all pairings (A+B, A+C, B+C, etc.)
  - Example: 5 players = 10 pairings (manageable)

Raid content (>5 players):
  - Only track pairings involving the player (You+A, You+B, You+C)
  - DO NOT track other pairings (A+B, B+C, etc.)
  - Example: 25-man raid = 24 pairings instead of 300!

This keeps pairing storage O(n) instead of O(n²).

The caller (UpdatePlayerStats) is responsible for filtering which pairings to track.

═══════════════════════════════════════════════════════════════════════════════]]

function Social:UpdatePairing(keyA, keyB, complete)
  local db = HitTools.DB.social

  -- Normalize pairing (alphabetical order for consistency)
  if keyA > keyB then
    keyA, keyB = keyB, keyA
  end

  if not db.pairings[keyA] then
    db.pairings[keyA] = {}
  end

  if not db.pairings[keyA][keyB] then
    db.pairings[keyA][keyB] = {
      runsTogether = 0,
      completes = 0,
      wipes = 0,
    }
  end

  local pairing = db.pairings[keyA][keyB]
  pairing.runsTogether = pairing.runsTogether + 1
  pairing.completes = pairing.completes + (complete and 1 or 0)
  pairing.wipes = pairing.wipes + (complete and 0 or 1)
end

--[[═══════════════════════════════════════════════════════════════════════════
  EVENT HANDLERS
═══════════════════════════════════════════════════════════════════════════════]]

function Social:OnZoneChanged()
  local inInstance, instanceType = IsInInstance()
  self.lastZoneEventAt = GetTime()

  -- DIAGNOSTIC: Log zone change event
  if HitTools.DB and HitTools.DB.social and HitTools.DB.social.debug then
    HitTools:Print(string.format("[Social.OnZoneChanged] inInstance=%s, type=%s", tostring(inInstance), tostring(instanceType)))
  end

  if inInstance and instanceType ~= "none" then
    self:CancelPendingEnd("zone_changed_in_instance")
    -- Entered instance - start run if grouped
    if HitTools.DB and HitTools.DB.social and HitTools.DB.social.debug then
      HitTools:Print("[Social.OnZoneChanged] Scheduling StartRun")
    end

    self:ScheduleStartRun("zone_changed", 1.0)
  else
    -- Left instance - schedule delayed end to avoid duplicate runs on quick re-entry.
    if HitTools.DB and HitTools.DB.social and HitTools.DB.social.debug then
      HitTools:Print("[Social.OnZoneChanged] Left instance, scheduling delayed end")
    end
    if self.currentRun then
      self:SchedulePendingEnd("left_instance_zone", LEFT_INSTANCE_END_DELAY, "zone_changed")
    end
  end
end

function Social:OnGroupRosterUpdate()
  -- RATE LIMIT: At most every 1.0s (prevents spam during rapid join/leave)
  if not RateLimit:Allow("roster_update", RATE_ROSTER_SCAN) then
    self.perfCounters.rosterScansBlocked = self.perfCounters.rosterScansBlocked + 1
    return
  end

  self.perfCounters.rosterScansAllowed = self.perfCounters.rosterScansAllowed + 1
  self.lastRosterEventAt = GetTime()

  -- DIAGNOSTIC: Log roster update event
  if HitTools.DB and HitTools.DB.social and HitTools.DB.social.debug then
    local inRaid = IsInRaid()
    local inGroup = IsInGroup()
    local groupSize = inRaid and (GetNumGroupMembers() or 0) or (inGroup and ((GetNumSubgroupMembers() or 0) + 1) or 1)
    HitTools:Print(string.format("[Social.OnGroupRosterUpdate] inRaid=%s, inGroup=%s, size=%d, hasCurrentRun=%s", tostring(inRaid), tostring(inGroup), groupSize, tostring(self.currentRun ~= nil)))
  end

  if not self.currentRun then
    -- Not in a run, check if we should start one
    local inInstance, instanceType = IsInInstance()
    if inInstance and instanceType ~= "none" then
      self:StartRun("roster_update")
    end
  else
    -- Update roster
    local newRoster = getCurrentRoster()
    local groupSize = getCurrentGroupSize()

    -- If group changed significantly mid-instance, split into a new run.
    if groupSize >= 2 then
      local significantChange, delta = self:IsSignificantGroupChange(self.currentRun, newRoster)
      if significantChange then
        self:Dbg("run", "Roster update triggered run split (added=%d removed=%d shared=%.2f leaderChanged=%s)",
          delta and (delta.added or 0) or 0,
          delta and (delta.removed or 0) or 0,
          delta and (delta.sharedRatio or 0) or 0,
          tostring(delta and delta.leaderChanged))
        self:EndRun("group_changed_roster")
        self:ScheduleStartRun("group_changed_new_run", NEW_RUN_START_DELAY)
        return
      end
    end

    -- Add new members to current run
    local addedMember = false
    for key, data in pairs(newRoster) do
      if not self.currentRun.roster[key] then
        self.currentRun.roster[key] = data
        self.currentRun.rosterKeys[#self.currentRun.rosterKeys + 1] = key
        self.currentRun.playerCombat[key] = {
          damageDone = 0,
          healingDone = 0,
          damageTaken = 0,
          deaths = 0,
          combatTime = 0,
        }
        addedMember = true
      end
    end

    self.rosterCache = newRoster
    if addedMember then
      self:RecordRosterSnapshot(newRoster)
      self:EmitDBUpdated("roster_updated")
    end
  end
end

function Social:OnCombatStart()
  self.lastCombatTime = GetTime()
end

function Social:OnCombatEnd()
  if not self.currentRun then return end

  local now = GetTime()
  local combatDuration = now - self.lastCombatTime

  -- Check for inactivity timeout
  if combatDuration > RUN_INACTIVITY_TIMEOUT then
    self:EndRun("inactivity_timeout")
  end
end

--[[═══════════════════════════════════════════════════════════════════════════
  OnCombatLog - PERFORMANCE CRITICAL HOT PATH
═══════════════════════════════════════════════════════════════════════════════

This function runs on EVERY combat log event (hundreds per second in combat).
Optimizations applied:
1. Early return if not in active run (saves 99% of checks outside dungeons)
2. Event whitelist to skip irrelevant events immediately
3. Reuse scratch tables instead of creating new tables
4. Cache playerKey lookups to avoid redundant GUID→key conversions
5. Rate-limit wipe checks to every 0.5s instead of every death

═══════════════════════════════════════════════════════════════════════════════]]

function Social:OnCombatLog()
  -- EARLY RETURN: Not in active run (most common case outside dungeons)
  if self.runState ~= RUN_STATE_ACTIVE or not self.currentRun then
    self.perfCounters.combatEventsSkipped = self.perfCounters.combatEventsSkipped + 1
    return
  end

  if not CombatLogGetCurrentEventInfo then return end

  local timestamp, subevent, _, sourceGUID, sourceName, _, _, destGUID, destName, _, _,
        spellId, spellName, _, amount = CombatLogGetCurrentEventInfo()

  -- WHITELIST CHECK: Skip events we don't care about
  if not COMBAT_EVENT_WHITELIST[subevent] then
    self.perfCounters.combatEventsSkipped = self.perfCounters.combatEventsSkipped + 1
    return
  end

  self.perfCounters.combatEventsProcessed = self.perfCounters.combatEventsProcessed + 1

  -- Track deaths
  if subevent == "UNIT_DIED" then
    local playerKey = getPlayerKeyFromGUID(destGUID)
    if playerKey and self.currentRun.roster[playerKey] then
      -- Record death
      local combat = self.currentRun.playerCombat[playerKey]
      if combat then
        combat.deaths = combat.deaths + 1
      end

      self.currentRun.totalDeaths = self.currentRun.totalDeaths + 1

      -- Track for wipe detection (reuse scratch table instead of creating new table)
      table.insert(self.recentDeaths, {time = GetTime(), playerKey = playerKey})

      -- RATE-LIMITED: Check for wipe at most every 0.5s
      if RateLimit:Allow("wipe_check", RATE_WIPE_CHECK) then
        self:CheckForWipe()
      end
    end
    return  -- Early exit, no need to check damage/healing
  end

  -- Track damage (combined check for all damage types)
  if subevent == "SWING_DAMAGE" or subevent == "SPELL_DAMAGE" or
     subevent == "SPELL_PERIODIC_DAMAGE" or subevent == "RANGE_DAMAGE" then

    -- Cache lookups to avoid redundant GUID conversions
    local sourceKey = sourceGUID and getPlayerKeyFromGUID(sourceGUID)
    local destKey = destGUID and getPlayerKeyFromGUID(destGUID)

    if sourceKey and self.currentRun.roster[sourceKey] and amount then
      local combat = self.currentRun.playerCombat[sourceKey]
      if combat then
        combat.damageDone = combat.damageDone + amount
      end
    end

    if destKey and self.currentRun.roster[destKey] and amount then
      local combat = self.currentRun.playerCombat[destKey]
      if combat then
        combat.damageTaken = combat.damageTaken + amount
      end
    end
    return
  end

  -- Track healing
  if subevent == "SPELL_HEAL" or subevent == "SPELL_PERIODIC_HEAL" then
    local sourceKey = getPlayerKeyFromGUID(sourceGUID)
    if sourceKey and self.currentRun.roster[sourceKey] and amount then
      local combat = self.currentRun.playerCombat[sourceKey]
      if combat then
        combat.healingDone = combat.healingDone + amount
      end
    end
    return
  end
end

--[[═══════════════════════════════════════════════════════════════════════════
  CheckForWipe - Optimized wipe detection
═══════════════════════════════════════════════════════════════════════════════

Reuses scratchTable1 to avoid per-call allocations.
Only called when rate-limited (max every 0.5s).

═══════════════════════════════════════════════════════════════════════════════]]

function Social:CheckForWipe()
  if not self.currentRun then return end

  local now = GetTime()

  -- Clean up old deaths outside the window
  local i = 1
  while i <= #self.recentDeaths do
    if now - self.recentDeaths[i].time > WIPE_DEATH_WINDOW then
      table.remove(self.recentDeaths, i)
    else
      i = i + 1
    end
  end

  -- Count unique deaths in window (reuse scratch table)
  local uniqueDeaths = scratchTable1
  for k in pairs(uniqueDeaths) do uniqueDeaths[k] = nil end  -- Clear/wipe

  for _, death in ipairs(self.recentDeaths) do
    uniqueDeaths[death.playerKey] = true
  end

  local deathCount = 0
  for _ in pairs(uniqueDeaths) do
    deathCount = deathCount + 1
  end

  -- Wipe if >= threshold
  if deathCount >= WIPE_DEATH_THRESHOLD then
    self.currentRun.wipeCount = self.currentRun.wipeCount + 1
    self.currentRun.lastWipeTime = now
    self.recentDeaths = {}  -- Clear for next wipe
    self.perfCounters.wipesDetected = self.perfCounters.wipesDetected + 1
  end
end

function Social:OnChatMessage(message, sender)
  if not self.currentRun then return end
  if not HitTools.DB or not HitTools.DB.social or not HitTools.DB.social.sentimentEnabled then
    return
  end

  -- Extract player name from sender (format: Name-Realm)
  local name, realm = sender:match("([^%-]+)%-?(.*)")
  if not realm or realm == "" then
    realm = GetRealmName()
  end

  -- Find player ID in current roster by name match
  local playerId = nil
  for id, playerData in pairs(self.currentRun.roster) do
    local normalizedSender = NormalizeFullName(name, realm)
    local normalizedRoster = NormalizeFullName(playerData.name, playerData.realm)
    if normalizedSender == normalizedRoster then
      playerId = id
      break
    end
  end

  if not playerId then return end

  local player = HitTools.DB.social.playersById[playerId]
  if not player then return end

  -- Update chat count
  player.aggregates.social.chatCount = player.aggregates.social.chatCount + 1

  -- Check for positive keywords
  local lowerMsg = message:lower()
  for _, keyword in ipairs(POSITIVE_KEYWORDS) do
    if lowerMsg:find(keyword, 1, true) then
      player.aggregates.social.friendlinessScore = player.aggregates.social.friendlinessScore + 1
      break
    end
  end

  -- Check for negative keywords (small penalty)
  for _, keyword in ipairs(NEGATIVE_KEYWORDS) do
    if lowerMsg:find(keyword, 1, true) then
      player.aggregates.social.friendlinessScore = math.max(0, player.aggregates.social.friendlinessScore - 2)
      break
    end
  end
end

function Social:OnEmote(message, sender)
  if not self.currentRun then return end
  if not HitTools.DB or not HitTools.DB.social or not HitTools.DB.social.sentimentEnabled then
    return
  end

  -- Extract player name from sender (format: Name-Realm)
  local name, realm = sender:match("([^%-]+)%-?(.*)")
  if not realm or realm == "" then
    realm = GetRealmName()
  end

  -- Find player ID in current roster by name match
  local playerId = nil
  for id, playerData in pairs(self.currentRun.roster) do
    local normalizedSender = NormalizeFullName(name, realm)
    local normalizedRoster = NormalizeFullName(playerData.name, playerData.realm)
    if normalizedSender == normalizedRoster then
      playerId = id
      break
    end
  end

  if playerId and self.currentRun.roster[playerId] then
    local player = HitTools.DB.social.playersById[playerId]
    if player then
      player.aggregates.social.emoteCount = player.aggregates.social.emoteCount + 1
      player.aggregates.social.friendlinessScore = player.aggregates.social.friendlinessScore + 0.5
    end
  end
end

function Social:PrintDiag()
  local stateNames = {[0] = "IDLE", [1] = "ACTIVE", [2] = "ENDING"}
  local stateName = stateNames[self.runState] or "UNKNOWN"
  local now = GetTime()

  HitTools:Print("=== Social Heatmap Diag ===")
  HitTools:Print(string.format("runState=%s (%d)", stateName, self.runState or -1))

  if self.currentRun then
    HitTools:Print(string.format("runId=%s runKey=%s", tostring(self.currentRun.runId), tostring(self.currentRun.runKey)))
    HitTools:Print(string.format("instance=%s (%s)", tostring(self.currentRun.instanceName), tostring(self.currentRun.instanceID)))
    HitTools:Print(string.format("groupSigHash=%s members=%d leader=%s",
      tostring(self.currentRun.groupSigHash),
      tonumber(self.currentRun.startRosterCount) or 0,
      tostring(self.currentRun.leaderId)))
  else
    HitTools:Print("runId=none")
  end

  if self.pendingEndAt then
    HitTools:Print(string.format("pendingEnd=true reason=%s in=%.1fs source=%s",
      tostring(self.pendingEndReason),
      math.max(0, self.pendingEndAt - now),
      tostring(self.pendingEndSource)))
  else
    HitTools:Print("pendingEnd=false")
  end

  HitTools:Print(string.format("lastEvents: zone=%.1fs roster=%.1fs combat=%.1fs",
    (self.lastZoneEventAt and (now - self.lastZoneEventAt)) or -1,
    (self.lastRosterEventAt and (now - self.lastRosterEventAt)) or -1,
    (self.lastCombatTime and (now - self.lastCombatTime)) or -1))

  local db = HitTools.DB and HitTools.DB.social
  local runs = {}
  for runId, run in pairs((db and db.runs) or {}) do
    runs[#runs + 1] = {id = runId, data = run, ts = run.timestampStart or 0}
  end
  table.sort(runs, function(a, b) return a.ts > b.ts end)

  HitTools:Print("lastRuns:")
  for i = 1, math.min(3, #runs) do
    local run = runs[i].data
    HitTools:Print(string.format("  [%d] key=%s start=%.0f instance=%s",
      i, tostring(run.runKey), run.timestampStart or 0, tostring(run.instanceID)))
  end
end

--[[═══════════════════════════════════════════════════════════════════════════
  SLASH COMMANDS & UI
═══════════════════════════════════════════════════════════════════════════════]]

function Social:HandleCommand(args)
  local originalArgs = args:trim()
  args = args:trim():lower()

  -- /hit social debug on|off
  if args:match("^debug%s+on") then
    HitTools.DB.social.debug = true
    HitTools:Print("Social Heatmap debug logging ENABLED")
    return
  elseif args:match("^debug%s+off") then
    HitTools.DB.social.debug = false
    HitTools:Print("Social Heatmap debug logging DISABLED")
    return
  end

  -- /hit social diag
  if args == "diag" then
    self:PrintDiag()
    return
  end

  -- /hit social teststart - Manually trigger StartRun for testing
  if args == "teststart" then
    HitTools:Print("[TEST] Manually triggering StartRun()")
    self:StartRun()
    return
  end

  -- /hit social testzone - Manually trigger OnZoneChanged for testing
  if args == "testzone" then
    HitTools:Print("[TEST] Manually triggering OnZoneChanged()")
    self:OnZoneChanged()
    return
  end

  -- /hit social sentiment on|off
  if args:match("^sentiment%s+on") then
    HitTools.DB.social.sentimentEnabled = true
    HitTools:Print("Social sentiment tracking ENABLED")
    return
  elseif args:match("^sentiment%s+off") then
    HitTools.DB.social.sentimentEnabled = false
    HitTools:Print("Social sentiment tracking DISABLED")
    return
  end

  -- /hit social reset player <name>
  local playerName = args:match("^reset%s+player%s+(.+)")
  if playerName then
    -- Search for player by name in playersById
    local foundId = nil
    local normalizedSearch = NormalizeFullName(playerName, GetRealmName())
    for id, player in pairs(HitTools.DB.social.playersById or {}) do
      local normalizedPlayer = NormalizeFullName(player.name, player.realm)
      if normalizedPlayer == normalizedSearch then
        foundId = id
        break
      end
    end

    if foundId then
      HitTools.DB.social.playersById[foundId] = nil
      -- Also clean up name index
      if HitTools.DB.social.nameIndex then
        HitTools.DB.social.nameIndex[normalizedSearch] = nil
      end
      HitTools:Print(string.format("Reset stats for %s", playerName))
    else
      HitTools:Print(string.format("Player not found: %s", playerName))
    end
    return
  end

  -- /hit social reset all
  if args == "reset all" then
    HitTools.DB.social.playersById = {}
    HitTools.DB.social.aliases = {}
    HitTools.DB.social.nameIndex = {}
    HitTools.DB.social.runs = {}
    HitTools.DB.social.pairings = {}
    HitTools:Print("Social Heatmap data cleared")
    return
  end

  -- /hit social addfriend <name>
  local addFriendName = originalArgs:match("^[Aa][Dd][Dd][Ff][Rr][Ii][Ee][Nn][Dd]%s+(.+)")
  if addFriendName then
    -- Search for player by name
    local foundId = nil
    local normalizedSearch = NormalizeFullName(addFriendName, GetRealmName())
    for id, player in pairs(HitTools.DB.social.playersById or {}) do
      local normalizedPlayer = NormalizeFullName(player.name, player.realm)
      if normalizedPlayer == normalizedSearch then
        foundId = id
        break
      end
    end

    if foundId then
      self:QuickAddFriend(foundId)
    else
      HitTools:Print(string.format("Player not found: %s", addFriendName))
      HitTools:Print("Note: You must have grouped with this player for them to be in the database")
    end
    return
  end

  -- /hit social setbnet <name> <BattleTag>
  local setBnetName, setBnetTag = originalArgs:match("^[Ss][Ee][Tt][Bb][Nn][Ee][Tt]%s+([^%s]+)%s+(.+)")
  if setBnetName and setBnetTag then
    -- Search for player by name
    local foundId = nil
    local normalizedSearch = NormalizeFullName(setBnetName, GetRealmName())
    for id, player in pairs(HitTools.DB.social.playersById or {}) do
      local normalizedPlayer = NormalizeFullName(player.name, player.realm)
      if normalizedPlayer == normalizedSearch then
        foundId = id
        break
      end
    end

    if foundId then
      self:SetBattleTagForPlayer(foundId, setBnetTag)
    else
      HitTools:Print(string.format("Player not found: %s", setBnetName))
    end
    return
  end

  -- /hit social invite <name>
  local inviteName = originalArgs:match("^[Ii][Nn][Vv][Ii][Tt][Ee]%s+(.+)")
  if inviteName then
    -- Search for player by name
    local foundId = nil
    local normalizedSearch = NormalizeFullName(inviteName, GetRealmName())
    for id, player in pairs(HitTools.DB.social.playersById or {}) do
      local normalizedPlayer = NormalizeFullName(player.name, player.realm)
      if normalizedPlayer == normalizedSearch then
        foundId = id
        break
      end
    end

    if foundId then
      self:SendBNetInviteForPlayer(foundId)
    else
      HitTools:Print(string.format("Player not found: %s", inviteName))
    end
    return
  end

  -- /hit social friend <name> - Show friend status
  local friendInfoName = originalArgs:match("^[Ff][Rr][Ii][Ee][Nn][Dd]%s+(.+)")
  if friendInfoName then
    -- Search for player by name
    local foundId = nil
    local normalizedSearch = NormalizeFullName(friendInfoName, GetRealmName())
    for id, player in pairs(HitTools.DB.social.playersById or {}) do
      local normalizedPlayer = NormalizeFullName(player.name, player.realm)
      if normalizedPlayer == normalizedSearch then
        foundId = id
        break
      end
    end

    if foundId then
      local player = HitTools.DB.social.playersById[foundId]
      HitTools:Print(string.format("Friend info for %s:", player.name))
      HitTools:Print(string.format("  On Friends list: %s", player.friend.isCharFriend and "Yes" or "No"))
      HitTools:Print(string.format("  BattleTag saved: %s", player.friend.bnet and "Yes (" .. player.friend.bnet .. ")" or "No"))
      if player.friend.lastInviteAt then
        local timeSince = GetTime() - player.friend.lastInviteAt
        HitTools:Print(string.format("  Last BNet invite: %.0f seconds ago", timeSince))
      end
    else
      HitTools:Print(string.format("Player not found: %s", friendInfoName))
    end
    return
  end

  -- /hit social perf - Performance telemetry
  if args == "perf" then
    local report = self.perfCounters:GetReport()
    HitTools:Print("Social Heatmap Performance:")
    HitTools:Print(string.format("  Combat Events: %d processed, %d skipped", report.combatEventsProcessed, report.combatEventsSkipped))
    HitTools:Print(string.format("  Roster Scans: %d allowed, %d throttled", report.rosterScansAllowed, report.rosterScansBlocked))
    HitTools:Print(string.format("  Runs: %d started, %d ended", report.runsStarted, report.runsEnded))
    HitTools:Print(string.format("  Wipes Detected: %d", report.wipesDetected))

    local db = HitTools.DB.social
    local playerCount = 0
    local runCount = 0
    local pairingCount = 0
    for _ in pairs(db.playersById or {}) do playerCount = playerCount + 1 end
    for _ in pairs(db.runs or {}) do runCount = runCount + 1 end
    for outerKey, innerTbl in pairs(db.pairings or {}) do
      for _ in pairs(innerTbl) do pairingCount = pairingCount + 1 end
    end

    HitTools:Print(string.format("  DB Size: %d players, %d runs, %d pairings", playerCount, runCount, pairingCount))
    HitTools:Print(string.format("  Last Compaction: %s", report.lastCompactionTime > 0 and string.format("%.0f sec ago", GetTime() - report.lastCompactionTime) or "Never"))
    return
  end

  -- /hit social dump - DIAGNOSTIC: Dump current state and DB
  if args == "dump" then
    HitTools:Print("=== Social Heatmap Dump ===")

    -- Current run state
    local stateNames = {[0] = "IDLE", [1] = "ACTIVE", [2] = "ENDING"}
    local stateName = stateNames[self.runState] or "UNKNOWN"
    HitTools:Print(string.format("Current Run State: %s", stateName))
    if self.currentRun then
      HitTools:Print(string.format("  RunId: %s", self.currentRun.runId or "none"))
      HitTools:Print(string.format("  Instance: %s (ID=%s)", self.currentRun.instanceName or "unknown", tostring(self.currentRun.instanceID)))
      HitTools:Print(string.format("  Roster: %d players", self.currentRun.rosterKeys and #self.currentRun.rosterKeys or 0))
      if self.currentRun.rosterKeys then
        for i = 1, math.min(5, #self.currentRun.rosterKeys) do
          HitTools:Print(string.format("    [%d] %s", i, self.currentRun.rosterKeys[i]))
        end
        if #self.currentRun.rosterKeys > 5 then
          HitTools:Print(string.format("    ... and %d more", #self.currentRun.rosterKeys - 5))
        end
      end
    else
      HitTools:Print("  No active run")
    end

    -- DB counts
    local db = HitTools.DB.social
    local playerCount = 0
    local runCount = 0
    local pairingCount = 0
    for _ in pairs(db.playersById or {}) do playerCount = playerCount + 1 end
    for _ in pairs(db.runs or {}) do runCount = runCount + 1 end
    for outerKey, innerTbl in pairs(db.pairings or {}) do
      for _ in pairs(innerTbl) do pairingCount = pairingCount + 1 end
    end
    HitTools:Print(string.format("DB Counts: %d players, %d runs, %d pairings", playerCount, runCount, pairingCount))

    -- Last 3 runs
    if runCount > 0 then
      HitTools:Print("Last 3 runs:")
      local runsList = {}
      for runId, run in pairs(db.runs) do
        table.insert(runsList, {id = runId, timestamp = run.timestampStart or 0, data = run})
      end
      table.sort(runsList, function(a, b) return a.timestamp > b.timestamp end)
      for i = 1, math.min(3, #runsList) do
        local run = runsList[i].data
        HitTools:Print(string.format("  [%d] %s (roster=%d, complete=%s)", i, run.instanceName or "unknown", run.roster and #run.roster or 0, tostring(run.complete)))
      end
    end

    -- First 5 players
    if playerCount > 0 then
      HitTools:Print("First 5 players:")
      local playersList = {}
      for id, player in pairs(db.playersById) do
        table.insert(playersList, {key = id, data = player})
      end
      for i = 1, math.min(5, #playersList) do
        local p = playersList[i].data
        HitTools:Print(string.format("  [%d] %s (runs=%d, lastSeen=%.0f)", i, p.name or "unknown", p.runsTogether or 0, p.lastSeen or 0))
      end
      if playerCount > 5 then
        HitTools:Print(string.format("  ... and %d more", playerCount - 5))
      end
    end

    return
  end

  -- /hit social debugui - SAFEGUARD 8: Enhanced debug with run state machine
  if args == "debugui" then
    HitTools:Print("=== Social Heatmap Debug ===")

    -- Run state machine
    local stateNames = {[0] = "IDLE", [1] = "ACTIVE", [2] = "ENDING"}
    local stateName = stateNames[self.runState] or "UNKNOWN"
    HitTools:Print(string.format("Run State: %s (%d)", stateName, self.runState or -1))
    if self.currentRun then
      HitTools:Print(string.format("  RunId: %s", self.currentRun.runId or "none"))
      HitTools:Print(string.format("  Instance: %s", self.currentRun.instanceName or "unknown"))
      HitTools:Print(string.format("  InstanceID: %s", tostring(self.currentRun.instanceID or "none")))
      HitTools:Print(string.format("  Roster size: %d", self.currentRun.rosterKeys and #self.currentRun.rosterKeys or 0))
      local duration = GetTime() - (self.currentRun.timestampStart or 0)
      HitTools:Print(string.format("  Duration: %.0f sec", duration))
    else
      HitTools:Print("  No active run")
    end

    -- XPRate state (if available)
    if HitTools.dungeon then
      HitTools:Print("XPRate State:")
      HitTools:Print(string.format("  Active: %s", HitTools.dungeon.active and "yes" or "no"))
      if HitTools.dungeon.key then
        HitTools:Print(string.format("  Key: %s", HitTools.dungeon.key))
      end
      if HitTools.DB and HitTools.DB.xpRate then
        HitTools:Print(string.format("  Finalize mode: %s", HitTools.DB.xpRate.finalizeMode or "smart"))
      end
      if HitTools.dungeon._finalizeScheduled then
        HitTools:Print("  Finalize: scheduled")
      end
    end

    -- UI state
    if not HitTools.SocialUI then
      HitTools:Print("Social UI: not initialized")
    else
      local ui = HitTools.SocialUI
      HitTools:Print("Social UI:")
      HitTools:Print(string.format("  Current tab: %d", ui.currentTab or 0))
      HitTools:Print(string.format("  Frames: players=%s pairings=%s runs=%s settings=%s",
        ui.playersContent and "yes" or "no",
        ui.pairingsContent and "yes" or "no",
        ui.runsContent and "yes" or "no",
        ui.settingsContent and "yes" or "no"))
    end

    -- DB counts
    local db = HitTools.DB.social
    local playerCount = 0
    local runCount = 0
    local pairingCount = 0
    for _ in pairs(db.playersById or {}) do playerCount = playerCount + 1 end
    for _ in pairs(db.runs or {}) do runCount = runCount + 1 end
    for outerKey, innerTbl in pairs(db.pairings or {}) do
      for _ in pairs(innerTbl) do pairingCount = pairingCount + 1 end
    end
    HitTools:Print(string.format("DB: %d players, %d runs, %d pairings", playerCount, runCount, pairingCount))
    return
  end

  -- /hit social uidiag - STEP 6: UI frame diagnostic
  if args == "uidiag" then
    HitTools:Print("=== Social UI Diagnostic ===")
    local ui = HitTools.SocialUI
    HitTools:Print(string.format("SocialUI object: %s", tostring(ui)))
    HitTools:Print(string.format("mainFrame: %s", tostring(ui.mainFrame)))
    HitTools:Print(string.format("playersContent: %s", tostring(ui.playersContent)))

    if ui.playersContent then
      HitTools:Print(string.format("  scrollFrame: %s", tostring(ui.playersContent.scrollFrame)))
      HitTools:Print(string.format("  scrollChild: %s", tostring(ui.playersContent.scrollChild)))
      HitTools:Print(string.format("  emptyState: %s", tostring(ui.playersContent.emptyState)))
      HitTools:Print(string.format("  playerRows: %s (#%d)", tostring(ui.playersContent.playerRows), ui.playersContent.playerRows and #ui.playersContent.playerRows or 0))
      HitTools:Print(string.format("  playersContent:IsShown(): %s", tostring(ui.playersContent:IsShown())))

      if ui.playersContent.scrollFrame then
        HitTools:Print(string.format("  scrollFrame:IsShown(): %s", tostring(ui.playersContent.scrollFrame:IsShown())))
        HitTools:Print(string.format("  scrollFrame size: %.0fx%.0f", ui.playersContent.scrollFrame:GetWidth() or 0, ui.playersContent.scrollFrame:GetHeight() or 0))
      end

      if ui.playersContent.emptyState then
        HitTools:Print(string.format("  emptyState:IsShown(): %s", tostring(ui.playersContent.emptyState:IsShown())))
      end

      -- Row pool diagnostics
      if ui.playersContent.playerRows and #ui.playersContent.playerRows > 0 then
        local row1 = ui.playersContent.playerRows[1]
        HitTools:Print(string.format("  Row[1]: %s", tostring(row1)))
        if row1 then
          HitTools:Print(string.format("    parent: %s", tostring(row1:GetParent())))
          HitTools:Print(string.format("    height: %.0f", row1:GetHeight() or 0))
          HitTools:Print(string.format("    shown: %s", tostring(row1:IsShown())))
        end
      end
    end

    return
  end

  -- /hit social compact - Compact player database
  if args == "compact" then
    HitTools:Print("Compacting player database...")
    local mergedCount = self:CompactPlayers()
    HitTools:Print(string.format("Compaction complete. Merged %d duplicate records.", mergedCount))
    -- Refresh UI if it's open
    if HitTools.SocialUI and HitTools.SocialUI.RefreshPlayersTab then
      HitTools.SocialUI:RefreshPlayersTab()
    end
    return
  end

  -- /hit social stats
  if args == "stats" or args == "" then
    self:ShowStats()
    return
  end

  HitTools:Print("Social Heatmap commands:")
  HitTools:Print("  /hit social stats - Show tracked players")
  HitTools:Print("  /hit social perf - Show performance counters")
  HitTools:Print("  /hit social compact - Merge duplicate player records")
  HitTools:Print("  /hit social diag - Print run-state diagnostics")
  HitTools:Print("  /hit social dump - Show current run state and DB contents")
  HitTools:Print("  /hit social debugui - Debug run state machine")
  HitTools:Print("  /hit social uidiag - Debug UI frame structure")
  HitTools:Print("  /hit social debug on|off - Toggle debug logging")
  HitTools:Print("  /hit social sentiment on|off - Toggle chat sentiment")
  HitTools:Print("  /hit social addfriend <name> - Add player to friends (+ BNet if saved)")
  HitTools:Print("  /hit social setbnet <name> <BattleTag> - Save BattleTag for player")
  HitTools:Print("  /hit social invite <name> - Send BNet invite (requires saved BattleTag)")
  HitTools:Print("  /hit social friend <name> - Show friend status for player")
  HitTools:Print("  /hit social reset player <name> - Reset player data")
  HitTools:Print("  /hit social reset all - Clear all data")
end

function Social:ShowStats()
  local db = HitTools.DB.social

  if not db or not db.playersById then
    HitTools:Print("No social data yet. Group up and run some dungeons!")
    return
  end

  -- Count players
  local playerCount = 0
  local runCount = 0
  for _ in pairs(db.playersById) do playerCount = playerCount + 1 end
  for _ in pairs(db.runs or {}) do runCount = runCount + 1 end

  HitTools:Print(string.format("Social Heatmap: %d players tracked across %d runs", playerCount, runCount))

  -- Show top 5 by runs together
  local playerList = {}
  for id, data in pairs(db.playersById) do
    playerList[#playerList + 1] = {key = id, data = data}
  end

  table.sort(playerList, function(a, b)
    return a.data.runsTogether > b.data.runsTogether
  end)

  HitTools:Print("Top players by runs together:")
  for i = 1, math.min(5, #playerList) do
    local p = playerList[i].data
    local score, label = calculateSynergyScore(p)
    local completeRate = 0
    local totalRuns = (p.aggregates.completes or 0) + (p.aggregates.wipes or 0)
    if totalRuns > 0 then
      completeRate = (p.aggregates.completes or 0) / totalRuns * 100
    end

    local friendIcon = ""
    if p.friend and p.friend.isCharFriend then
      friendIcon = "[Friend] "
    elseif p.friend and p.friend.bnet then
      friendIcon = "[BNet saved] "
    end

    HitTools:Print(string.format(
      "  %d. %s%s (%s) - %d runs, %.0f%% complete, %s",
      i, friendIcon, p.name, p.class, p.runsTogether, completeRate, label
    ))
  end

  HitTools:Print("Sentiment tracking: " .. (db.sentimentEnabled and "ON" or "OFF"))
  HitTools:Print("Tip: Use '/hit social addfriend <name>' to add players to your friends list!")
end

--[[═══════════════════════════════════════════════════════════════════════════
  INITIALIZATION
═══════════════════════════════════════════════════════════════════════════════]]

function Social:OnDBReady()
  -- DIAGNOSTIC: Log initialization
  DebugPrint("Initializing Social Heatmap module")

  if self._frame then
    DebugPrint("Already initialized, skipping")
    return
  end

  self:InitializeDB()

  DebugPrint("Creating event frame and registering events")

  local f = CreateFrame("Frame")
  self._frame = f

  -- Register events
  f:RegisterEvent("PLAYER_ENTERING_WORLD")
  f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
  f:RegisterEvent("ZONE_CHANGED")  -- TBC: More reliable than ZONE_CHANGED_NEW_AREA
  f:RegisterEvent("GROUP_ROSTER_UPDATE")  -- TBC Anniversary uses modern event (covers party+raid)
  f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
  f:RegisterEvent("PLAYER_REGEN_DISABLED")
  f:RegisterEvent("PLAYER_REGEN_ENABLED")
  f:RegisterEvent("CHAT_MSG_PARTY")
  f:RegisterEvent("CHAT_MSG_PARTY_LEADER")
  f:RegisterEvent("CHAT_MSG_RAID")
  f:RegisterEvent("CHAT_MSG_RAID_LEADER")
  f:RegisterEvent("CHAT_MSG_EMOTE")
  f:RegisterEvent("FRIENDLIST_UPDATE")
  f:RegisterEvent("PLAYER_LOGOUT")

  DebugPrint("Event registration complete")

  -- TBC FIX: Zone events don't fire reliably. Do delayed check if already in instance with group
  local SocialRef = self  -- Capture self reference for timer closure
  if C_Timer and C_Timer.After then
    DebugPrint("OnDBReady complete - Social Heatmap module initialized")
    DebugPrint("Scheduled delayed startup check in 3 seconds...")
    C_Timer.After(3, function()
      DebugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
      DebugPrint("DELAYED STARTUP CHECK (3s)")
      local inInstance, instanceType = IsInInstance()
      local groupSize = IsInRaid() and GetNumGroupMembers() or (IsInGroup() and (GetNumSubgroupMembers() + 1) or 1)
      DebugPrint(string.format("Current state: inInstance=%s, type=%s, groupSize=%d, hasActiveRun=%s",
        tostring(inInstance), tostring(instanceType), groupSize, tostring(SocialRef.currentRun ~= nil)))

      if not SocialRef.currentRun then
        if inInstance and instanceType ~= "none" and groupSize >= 2 then
          DebugPrint("✓ Auto-starting run from delayed check")
          SocialRef:StartRun()
        else
          DebugPrint("✗ Not auto-starting (not in instance or solo)")
        end
      else
        DebugPrint("✓ Run already active, skipping auto-start")
      end
      DebugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    end)
  else
    DebugPrint("WARNING: C_Timer not available, delayed check disabled")
  end

  f:SetScript("OnEvent", function(_, event, ...)
    -- Use SocialRef (captured above) instead of self (which is the frame here)

    -- DIAGNOSTIC (rate-limited): log key lifecycle events only when debug is on.
    if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED" or
       event == "GROUP_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
      SocialRef:Dbg("evt_" .. event, "OnEvent: %s", tostring(event))
    end

    if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED" then
      -- IMMEDIATE CHECK on PLAYER_ENTERING_WORLD (for /reload in active instance)
      if event == "PLAYER_ENTERING_WORLD" then
        DebugPrint("PLAYER_ENTERING_WORLD - Checking for active instance+group...")
        local inInstance, instanceType = IsInInstance()
        local groupSize = IsInRaid() and GetNumGroupMembers() or (IsInGroup() and (GetNumSubgroupMembers() + 1) or 1)
        DebugPrint(string.format("State: inInstance=%s, type=%s, groupSize=%d, currentRun=%s",
          tostring(inInstance), tostring(instanceType), groupSize, tostring(SocialRef.currentRun ~= nil)))

        -- If already in instance with group and no active run, start immediately
        if inInstance and instanceType ~= "none" and groupSize >= 2 and not SocialRef.currentRun then
          DebugPrint("Auto-starting run (immediate check)")
          SocialRef:StartRun()
        end

        -- Also do delayed check as fallback (in case group data not ready yet)
        if C_Timer and C_Timer.After then
          C_Timer.After(2, function()
            DebugPrint("PLAYER_ENTERING_WORLD delayed fallback check")
            SocialRef:OnZoneChanged()
          end)
        end
      else
        -- Zone change events: use normal flow
        SocialRef:OnZoneChanged()
      end
      return
    end

    if event == "GROUP_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
      SocialRef:OnGroupRosterUpdate()
      return
    end

    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
      SocialRef:OnCombatLog()
      return
    end

    if event == "PLAYER_REGEN_DISABLED" then
      SocialRef:OnCombatStart()
      return
    end

    if event == "PLAYER_REGEN_ENABLED" then
      SocialRef:OnCombatEnd()
      return
    end

    if event == "CHAT_MSG_PARTY" or event == "CHAT_MSG_PARTY_LEADER" or
       event == "CHAT_MSG_RAID" or event == "CHAT_MSG_RAID_LEADER" then
      local message, sender = ...
      SocialRef:OnChatMessage(message, sender)
      return
    end

    if event == "CHAT_MSG_EMOTE" then
      local message, sender = ...
      SocialRef:OnEmote(message, sender)
      return
    end

    if event == "FRIENDLIST_UPDATE" then
      SocialRef:RefreshFriendsList()
      return
    end

    if event == "PLAYER_LOGOUT" then
      SocialRef:OnLogout()
      return
    end
  end)

  -- Initial friends list refresh
  C_Timer.After(2, function()
    self:RefreshFriendsList()
  end)

  -- Auto-compaction: Run every 30 minutes during play
  self:ScheduleAutoCompaction()
end

--[[═══════════════════════════════════════════════════════════════════════════
  OnLogout - Compact database on logout
═══════════════════════════════════════════════════════════════════════════════

Called when player logs out. Performs final compaction to clean up data.

═══════════════════════════════════════════════════════════════════════════════]]

function Social:OnLogout()
  -- Final compaction before logout
  -- Note: CompactDB prints its own message if anything was pruned
  self:CompactDB()
end

--[[═══════════════════════════════════════════════════════════════════════════
  ScheduleAutoCompaction - Schedule periodic database compaction
═══════════════════════════════════════════════════════════════════════════════

Schedules CompactDB to run every 30 minutes during play.
Rate-limited to prevent multiple concurrent timers.

═══════════════════════════════════════════════════════════════════════════════]]

function Social:ScheduleAutoCompaction()
  -- Schedule next compaction in 30 minutes
  local function scheduleNext()
    if C_Timer and C_Timer.After then
      C_Timer.After(RATE_COMPACTION, function()
        -- Only compact if rate limit allows (prevents stacking timers)
        if RateLimit:Allow("compaction", RATE_COMPACTION) then
          -- CompactDB prints its own message if anything was pruned
          Social:CompactDB()
        end
        -- Schedule next run
        scheduleNext()
      end)
    end
  end

  scheduleNext()
end

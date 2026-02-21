local _, HitTools = ...

HitTools.CursorGrow = HitTools.CursorGrow or {}
local CursorGrow = HitTools.CursorGrow

-- State enum
local STATE_IDLE = 0
local STATE_GROWING = 1
local STATE_SHRINKING = 2

-- Easter egg effect definitions (rare RNG effects when shaking)
local EASTER_EGG_EFFECTS = {
  {
    name = "hearts",
    texture = "Interface\\AddOns\\Blizzard_Communities\\PartySync-Accepted",
    color = {1.0, 0.4, 0.6},  -- Pink
    particleCount = 8,
    speed = {150, 250},
    size = {16, 24},
    gravity = 100,
    fade = 1.5,
  },
  {
    name = "stars",
    texture = "Interface\\Cooldown\\star4",
    color = {1.0, 1.0, 0.3},  -- Yellow
    particleCount = 12,
    speed = {100, 200},
    size = {12, 20},
    gravity = 50,
    fade = 2.0,
  },
  {
    name = "coins",
    texture = "Interface\\MoneyFrame\\UI-GoldIcon",
    color = {1.0, 0.85, 0.0},  -- Gold
    particleCount = 10,
    speed = {120, 220},
    size = {14, 22},
    gravity = 150,
    fade = 1.8,
  },
  {
    name = "sparkles",
    texture = "Interface\\GLUES\\Models\\UI_Draenei\\GenericGlow64",
    color = {0.8, 0.5, 1.0},  -- Purple
    particleCount = 15,
    speed = {80, 180},
    size = {10, 18},
    gravity = 30,
    fade = 1.2,
  },
  {
    name = "confetti",
    texture = "Interface\\BUTTONS\\WHITE8X8",
    colorVariation = {
      {1.0, 0.2, 0.2},  -- Red
      {0.2, 1.0, 0.2},  -- Green
      {0.2, 0.2, 1.0},  -- Blue
      {1.0, 1.0, 0.2},  -- Yellow
      {1.0, 0.5, 0.2},  -- Orange
    },
    particleCount = 20,
    speed = {100, 250},
    size = {6, 12},
    gravity = 120,
    fade = 1.5,
  },
}

-- Cursor texture mappings (WoW cursor types)
local CURSOR_TEXTURES = {
  ["default"] = "Interface\\Cursor\\Point",
  ["attack"] = "Interface\\Cursor\\Attack",
  ["buy"] = "Interface\\Cursor\\Buy",
  ["speak"] = "Interface\\Cursor\\Speak",
  ["pickup"] = "Interface\\Cursor\\Pickup",
  ["interact"] = "Interface\\Cursor\\Interact",
  ["quest"] = "Interface\\Cursor\\Quest",
}

-- Helper: Calculate distance between two points
local function distance(x1, y1, x2, y2)
  local dx = x2 - x1
  local dy = y2 - y1
  return math.sqrt(dx * dx + dy * dy)
end

-- Helper: Calculate angle between two vectors in radians
local function angleBetween(vx1, vy1, vx2, vy2)
  local dot = vx1 * vx2 + vy1 * vy2
  local mag1 = math.sqrt(vx1 * vx1 + vy1 * vy1)
  local mag2 = math.sqrt(vx2 * vx2 + vy2 * vy2)

  if mag1 < 0.001 or mag2 < 0.001 then
    return 0
  end

  local cosAngle = dot / (mag1 * mag2)
  -- Clamp to [-1, 1] to avoid math.acos domain errors
  cosAngle = math.max(-1, math.min(1, cosAngle))
  return math.acos(cosAngle)
end

-- Helper: Smoothstep interpolation (ease in/out)
local function smoothstep(t)
  t = math.max(0, math.min(1, t))
  return t * t * (3 - 2 * t)
end

-- Helper: Lerp between two values
local function lerp(a, b, t)
  return a + (b - a) * t
end

-- Helper: Get current cursor texture based on cursor state
local function getCursorTexture()
  if not GetCursor then
    return CURSOR_TEXTURES["default"]
  end

  local cursorType = GetCursor()

  -- Map cursor type to texture path
  if cursorType == "attackcursor" then
    return CURSOR_TEXTURES["attack"]
  elseif cursorType == "buy" then
    return CURSOR_TEXTURES["buy"]
  elseif cursorType == "speak" then
    return CURSOR_TEXTURES["speak"]
  elseif cursorType == "pickup" then
    return CURSOR_TEXTURES["pickup"]
  elseif cursorType == "interact" or cursorType == "openhand" then
    return CURSOR_TEXTURES["interact"]
  elseif cursorType == "questinteract" then
    return CURSOR_TEXTURES["quest"]
  else
    return CURSOR_TEXTURES["default"]
  end
end

-- Helper: Random float between min and max
local function randomFloat(min, max)
  return min + (max - min) * math.random()
end

-- Helper: Random integer between min and max (inclusive)
local function randomInt(min, max)
  return math.floor(randomFloat(min, max + 0.999))
end

-- Initialize the cursor grow system
function CursorGrow:OnDBReady()
  if self._frame then return end

  -- State variables
  self.state = STATE_IDLE
  self.currentScale = 1.0
  self.targetScale = 1.0
  self.shakeScore = 0
  self.shrinkDelayTimer = 0
  self._testModeActive = false

  -- Position tracking
  self.lastX = nil
  self.lastY = nil
  self.lastTime = GetTime()

  -- Movement history for shake detection (rolling window)
  self.moveHistory = {}
  self.maxHistorySize = 12  -- ~0.25s at 60fps
  self.lastDx = 0
  self.lastDy = 0

  -- Cursor texture tracking
  self._lastCursorTexture = nil

  -- Easter egg particle system
  self.particles = {}
  self.particlePool = {}
  self._lastEasterEggCheck = 0
  self._easterEggCooldown = 5  -- Minimum 5s between effects

  -- Create overlay frame
  self:CreateOverlayFrame()

  -- Create update ticker (60 FPS)
  self._ticker = C_Timer.NewTicker(1/60, function()
    self:OnUpdate()
  end)

  HitTools:VerbosePrint("CursorGrow initialized successfully")
end

-- Create the cursor overlay frame
function CursorGrow:CreateOverlayFrame()
  local f = CreateFrame("Frame", "HitToolsCursorGrowFrame", UIParent)
  f:SetFrameStrata("TOOLTIP")
  f:SetFrameLevel(9999)
  f:SetSize(1, 1)  -- Minimal frame size, textures will be sized manually
  f:Hide()
  f:EnableMouse(false)  -- Don't block mouse input
  f:SetClampedToScreen(false)  -- Allow positioning at screen edges

  -- Create cursor image overlay (actual cursor texture)
  -- WoW cursor textures are 32x32 with hotspot at top-left corner
  local cursor = f:CreateTexture(nil, "OVERLAY")
  cursor:SetPoint("TOPLEFT", f, "CENTER", 0, 0)  -- Cursor tip at frame center
  cursor:SetSize(32, 32)
  cursor:SetTexture("Interface\\Cursor\\Point")  -- Default cursor texture
  cursor:SetVertexColor(1.0, 1.0, 1.0, 1.0)
  f.cursor = cursor

  -- Create multiple circular glow layers behind the cursor
  -- Using circular textures for smooth, rounded glow effect
  f.rings = {}

  -- Outer glow (largest, very faint, soft edges)
  local outerGlow = f:CreateTexture(nil, "BACKGROUND", nil, 0)
  outerGlow:SetPoint("CENTER", f, "CENTER", 0, 0)
  outerGlow:SetSize(96, 96)
  outerGlow:SetTexture("Interface\\GLUES\\Models\\UI_Draenei\\GenericGlow64")
  outerGlow:SetVertexColor(0.3, 0.7, 1.0)  -- Cyan-blue
  outerGlow:SetBlendMode("ADD")
  f.rings[1] = outerGlow

  -- Middle glow (medium, brighter)
  local middleGlow = f:CreateTexture(nil, "BACKGROUND", nil, 1)
  middleGlow:SetPoint("CENTER", f, "CENTER", 0, 0)
  middleGlow:SetSize(64, 64)
  middleGlow:SetTexture("Interface\\GLUES\\Models\\UI_Draenei\\GenericGlow64")
  middleGlow:SetVertexColor(0.4, 0.9, 1.0)  -- Brighter cyan
  middleGlow:SetBlendMode("ADD")
  f.rings[2] = middleGlow

  -- Inner glow (smallest, brightest core)
  local innerGlow = f:CreateTexture(nil, "BACKGROUND", nil, 2)
  innerGlow:SetPoint("CENTER", f, "CENTER", 0, 0)
  innerGlow:SetSize(40, 40)
  innerGlow:SetTexture("Interface\\GLUES\\Models\\UI_Draenei\\GenericGlow64")
  innerGlow:SetVertexColor(0.6, 1.0, 1.0)  -- Bright cyan-white
  innerGlow:SetBlendMode("ADD")
  f.rings[3] = innerGlow

  -- Main texture reference (for compatibility)
  f.texture = innerGlow
  self._overlayFrame = f

  -- Create particle container frame
  local particleFrame = CreateFrame("Frame", nil, UIParent)
  particleFrame:SetFrameStrata("TOOLTIP")
  particleFrame:SetFrameLevel(10000)
  particleFrame:SetSize(1, 1)
  particleFrame:Hide()
  self._particleFrame = particleFrame
end

-- Create a particle from the pool or make a new one
function CursorGrow:GetParticle()
  local particle = table.remove(self.particlePool)
  if not particle then
    particle = self._particleFrame:CreateTexture(nil, "ARTWORK")
    particle:SetBlendMode("ADD")
  end
  return particle
end

-- Return particle to pool
function CursorGrow:ReleaseParticle(particle)
  particle:Hide()
  particle:ClearAllPoints()
  table.insert(self.particlePool, particle)
end

-- Spawn easter egg particle effect
function CursorGrow:SpawnEasterEggEffect()
  local db = HitTools.DB and HitTools.DB.cursorGrow
  if not db or not db.enabled or not db.easterEggs then return end

  -- Get cursor position
  local cursorX, cursorY = GetCursorPosition()
  local uiScale = UIParent:GetEffectiveScale()
  local x = cursorX / uiScale
  local y = cursorY / uiScale

  -- Pick random effect
  local effect = EASTER_EGG_EFFECTS[randomInt(1, #EASTER_EGG_EFFECTS)]

  -- Spawn particles
  for i = 1, effect.particleCount do
    local particle = self:GetParticle()

    -- Random angle and speed
    local angle = math.rad(randomFloat(0, 360))
    local speed = randomFloat(effect.speed[1], effect.speed[2])
    local vx = math.cos(angle) * speed
    local vy = math.sin(angle) * speed

    -- Random size
    local size = randomFloat(effect.size[1], effect.size[2])

    -- Set texture and color
    particle:SetTexture(effect.texture)
    if effect.colorVariation then
      local color = effect.colorVariation[randomInt(1, #effect.colorVariation)]
      particle:SetVertexColor(color[1], color[2], color[3])
    else
      particle:SetVertexColor(effect.color[1], effect.color[2], effect.color[3])
    end

    particle:SetSize(size, size)
    particle:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
    particle:SetAlpha(1.0)
    particle:Show()

    -- Store particle data
    table.insert(self.particles, {
      texture = particle,
      x = x,
      y = y,
      vx = vx,
      vy = vy,
      gravity = effect.gravity,
      fadeTime = effect.fade,
      lifetime = 0,
      size = size,
    })
  end

  -- Show particle frame
  self._particleFrame:Show()

  -- Debug message
  if db.debugMode then
    print(string.format("[CursorGrow] Easter egg! Effect: %s", effect.name))
  end
end

-- Update all active particles
function CursorGrow:UpdateParticles(dt)
  if #self.particles == 0 then
    self._particleFrame:Hide()
    return
  end

  local uiScale = UIParent:GetEffectiveScale()
  local i = 1
  while i <= #self.particles do
    local p = self.particles[i]
    p.lifetime = p.lifetime + dt

    -- Apply physics
    p.vy = p.vy - (p.gravity * dt)  -- Gravity
    p.x = p.x + (p.vx * dt)
    p.y = p.y + (p.vy * dt)

    -- Update position
    p.texture:ClearAllPoints()
    p.texture:SetPoint("CENTER", UIParent, "BOTTOMLEFT", p.x, p.y)

    -- Fade out
    local alpha = 1.0 - (p.lifetime / p.fadeTime)
    if alpha <= 0 then
      -- Remove particle
      self:ReleaseParticle(p.texture)
      table.remove(self.particles, i)
    else
      p.texture:SetAlpha(alpha)
      i = i + 1
    end
  end
end

-- Update cursor overlay position and scale
function CursorGrow:UpdateOverlay()
  if not self._overlayFrame then return end

  local db = HitTools.DB and HitTools.DB.cursorGrow
  if not db or not db.enabled then
    self._overlayFrame:Hide()
    return
  end

  -- Get cursor position in UI coordinates
  local cursorX, cursorY = GetCursorPosition()
  local uiScale = UIParent:GetEffectiveScale()

  -- Convert to UI parent coordinates
  local x = cursorX / uiScale
  local y = cursorY / uiScale

  -- Position the frame so its CENTER is at the cursor hotspot
  -- Don't use SetScale - we'll manually size textures instead
  self._overlayFrame:ClearAllPoints()
  self._overlayFrame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)

  -- Add subtle pulse animation when growing
  local pulseScale = 1.0
  if self.state == STATE_GROWING or self._testModeActive then
    local pulseSpeed = 3.0  -- cycles per second
    local pulseAmount = 0.08  -- 8% size variation
    pulseScale = 1.0 + math.sin(GetTime() * pulseSpeed * math.pi * 2) * pulseAmount
  end

  -- Calculate final scale with pulse
  local finalScale = self.currentScale * pulseScale

  -- Update cursor texture based on current cursor state
  if self._overlayFrame.cursor then
    if db.showCursor ~= false then
      -- Update cursor texture to match current cursor
      local cursorTexture = getCursorTexture()
      if self._lastCursorTexture ~= cursorTexture then
        self._overlayFrame.cursor:SetTexture(cursorTexture)
        self._lastCursorTexture = cursorTexture
      end

      -- Manually resize cursor texture (don't use frame scale)
      local cursorSize = 32 * finalScale
      self._overlayFrame.cursor:SetSize(cursorSize, cursorSize)
      self._overlayFrame.cursor:SetAlpha(0.9)  -- Slightly transparent
      self._overlayFrame.cursor:Show()
    else
      self._overlayFrame.cursor:Hide()
    end
  end

  -- Update alpha and size based on scale
  -- Rings become MORE visible (less transparent) as scale increases
  local showRings = db.showRings ~= false

  -- Base alpha increases with scale (starts dim, gets brighter)
  -- Scale 1.0 = 0.15 alpha, Scale 2.5+ = 0.9 alpha
  local baseAlpha = math.min(0.9, math.max(0.15, (self.currentScale - 1.0) / 1.5 * 0.75 + 0.15))

  -- Manually resize each ring texture with layered alpha for depth
  local baseSizes = {96, 64, 40}  -- Outer, middle, inner
  local alphaMultipliers = {0.5, 0.75, 1.0}  -- Outer dimmer, inner brighter

  for i, ring in ipairs(self._overlayFrame.rings or {}) do
    if showRings then
      local baseSize = baseSizes[i]
      local ringSize = baseSize * finalScale
      local ringAlpha = baseAlpha * alphaMultipliers[i]

      ring:SetSize(ringSize, ringSize)
      ring:SetAlpha(ringAlpha)
      ring:Show()
    else
      ring:Hide()
    end
  end

  -- Show/hide based on scale (show at even small growth)
  if self.currentScale > 1.05 or self._testModeActive then
    self._overlayFrame:Show()
  else
    self._overlayFrame:Hide()
  end
end


-- Main update loop
function CursorGrow:OnUpdate()
  local db = HitTools.DB and HitTools.DB.cursorGrow
  if not db then return end

  -- Skip processing when disabled (performance optimization)
  if not db.enabled and not self._testModeActive then
    if self.currentScale > 1.0 then
      -- Fade out smoothly
      self.currentScale = math.max(1.0, self.currentScale - 0.05)
      self:UpdateOverlay()
    end
    self.state = STATE_IDLE
    return
  end

  -- Allow test mode even when disabled
  if not db.enabled and self._testModeActive then
    self:UpdateOverlay()
    return
  end

  -- Skip if in mouselook (cursor hidden)
  if IsMouselooking and IsMouselooking() then
    self.state = STATE_IDLE
    self.shakeScore = 0
    self.currentScale = 1.0
    self:UpdateOverlay()
    return
  end

  local now = GetTime()
  local dt = now - self.lastTime
  self.lastTime = now

  -- Clamp dt to avoid huge jumps
  if dt > 0.1 then dt = 0.1 end
  if dt < 0.001 then return end

  -- Get cursor position
  local x, y = GetCursorPosition()
  local scale = UIParent:GetEffectiveScale()
  x = x / scale
  y = y / scale

  -- Calculate movement delta and velocity
  if self.lastX and self.lastY then
    local dx = x - self.lastX
    local dy = y - self.lastY

    -- Calculate velocity (pixels per second)
    local velocityX = dx / dt
    local velocityY = dy / dt
    local speed = math.sqrt(velocityX * velocityX + velocityY * velocityY)

    -- Add to movement history
    table.insert(self.moveHistory, {
      dx = dx,
      dy = dy,
      speed = speed,
      time = now
    })

    -- Trim history to max size
    while #self.moveHistory > self.maxHistorySize do
      table.remove(self.moveHistory, 1)
    end

    -- Detect shaking by counting direction flips (sign changes) in movement history
    local xFlips = 0
    local yFlips = 0
    local totalSpeed = 0
    local validSamples = 0

    for i = 2, #self.moveHistory do
      local prev = self.moveHistory[i - 1]
      local curr = self.moveHistory[i]

      -- Count sign flips (direction reversals)
      if prev.dx ~= 0 and curr.dx ~= 0 then
        if (prev.dx > 0) ~= (curr.dx > 0) then
          xFlips = xFlips + 1
        end
      end

      if prev.dy ~= 0 and curr.dy ~= 0 then
        if (prev.dy > 0) ~= (curr.dy > 0) then
          yFlips = yFlips + 1
        end
      end

      totalSpeed = totalSpeed + curr.speed
      validSamples = validSamples + 1
    end

    local avgSpeed = validSamples > 0 and (totalSpeed / validSamples) or 0
    local totalFlips = xFlips + yFlips

    -- Determine if currently shaking
    -- Requires high average speed AND multiple direction changes
    local minFlips = db.minFlips or 4
    local isShaking = avgSpeed > db.speedThreshold and totalFlips >= minFlips

    -- Update shake score
    if isShaking then
      self.shakeScore = self.shakeScore + (db.scoreRiseRate * dt)
    else
      self.shakeScore = self.shakeScore - (db.scoreDecayRate * dt)
    end
    self.shakeScore = math.max(0, self.shakeScore)

    -- Debug output
    if db.debugMode then
      -- Only print when significant activity (or every 2 seconds)
      if not self._lastDebugPrint then self._lastDebugPrint = 0 end
      local shouldPrint = (now - self._lastDebugPrint) > 2.0
        or (isShaking and (now - self._lastDebugPrint) > 0.5)
        or (self.shakeScore > 0.5 and (now - self._lastDebugPrint) > 0.5)

      if shouldPrint then
        self._lastDebugPrint = now
        local stateNames = {"IDLE", "GROWING", "SHRINKING"}
        print(string.format(
          "[CursorGrow] speed=%.0f flips=%d(x:%d,y:%d) score=%.2f scale=%.2f/%.2f state=%s shaking=%s",
          avgSpeed, totalFlips, xFlips, yFlips, self.shakeScore,
          self.currentScale, self.targetScale,
          stateNames[self.state + 1] or "?",
          isShaking and "YES" or "no"
        ))
      end
    end

    -- Easter egg effect RNG check (only when transitioning to GROWING)
    if self.state == STATE_IDLE and self.shakeScore >= db.startGrowThreshold then
      local timeSinceLastEgg = now - self._lastEasterEggCheck
      if timeSinceLastEgg >= self._easterEggCooldown then
        -- 0.1% to 1.2% chance (1 in 1000 to 1 in 83)
        local rngChance = randomFloat(0, 1000)
        if rngChance <= 12 then  -- 1.2% chance
          self:SpawnEasterEggEffect()
          self._lastEasterEggCheck = now
        end
      end
    end

    -- State machine transitions
    if self.state == STATE_IDLE then
      if self.shakeScore >= db.startGrowThreshold then
        self.state = STATE_GROWING
        self.shrinkDelayTimer = 0
      end
    elseif self.state == STATE_GROWING then
      if self.shakeScore < db.stopGrowThreshold then
        self.state = STATE_SHRINKING
        self.shrinkDelayTimer = db.stopGrowDelaySeconds
      end
    elseif self.state == STATE_SHRINKING then
      if self.shakeScore >= db.startGrowThreshold then
        -- Re-enter growing if shaking resumes
        self.state = STATE_GROWING
        self.shrinkDelayTimer = 0
      else
        -- Count down delay timer
        self.shrinkDelayTimer = math.max(0, self.shrinkDelayTimer - dt)

        -- Once delay expires and score is low, can go idle
        if self.shrinkDelayTimer <= 0 and self.currentScale <= 1.01 then
          self.state = STATE_IDLE
          self.shakeScore = 0
        end
      end
    end
  end

  -- Store last position
  self.lastX = x
  self.lastY = y

  -- Calculate target scale from shake score
  if self.state == STATE_GROWING then
    -- Map shake score to scale using smoothstep for natural feel
    local scoreNormalized = math.min(1, self.shakeScore / 3.0)  -- Normalize to 0-1 over score range 0-3
    local scaleFactor = smoothstep(scoreNormalized)
    self.targetScale = lerp(1.0, db.maxScale, scaleFactor)
  elseif self.state == STATE_SHRINKING then
    -- Only start shrinking after delay expires
    if self.shrinkDelayTimer <= 0 then
      self.targetScale = 1.0
    end
  else
    self.targetScale = 1.0
  end

  -- Lerp current scale toward target
  local lerpSpeed = (self.state == STATE_GROWING) and db.growLerpSpeed or db.shrinkLerpSpeed
  local lerpAmount = math.min(1, lerpSpeed * dt)
  self.currentScale = lerp(self.currentScale, self.targetScale, lerpAmount)

  -- Clamp scale
  self.currentScale = math.max(1.0, math.min(db.maxScale, self.currentScale))

  -- Update overlay rendering
  self:UpdateOverlay()

  -- Update particles (easter eggs)
  self:UpdateParticles(dt)
end

-- Slash command handlers
function CursorGrow:HandleCommand(args)
  local db = HitTools.DB and HitTools.DB.cursorGrow
  if not db then return end

  args = args:lower():trim()

  -- /hit cursor grow on|off
  if args == "on" then
    db.enabled = true
    HitTools:Print("Cursor grow enabled")
    return
  elseif args == "off" then
    db.enabled = false
    HitTools:Print("Cursor grow disabled")
    return
  end

  -- /hit cursor grow max <value>
  local maxVal = args:match("^max%s+(%S+)")
  if maxVal then
    local num = tonumber(maxVal)
    if num and num >= 1.0 and num <= 5.0 then
      db.maxScale = num
      HitTools:Print(string.format("Cursor grow max scale set to %.1f", num))
    else
      HitTools:Print("Invalid max scale (use 1.0 to 5.0)")
    end
    return
  end

  -- /hit cursor grow debug [on|off]
  if args == "debug" or args == "debug on" or args == "debug off" then
    if args == "debug on" then
      db.debugMode = true
    elseif args == "debug off" then
      db.debugMode = false
    else
      db.debugMode = not db.debugMode
    end
    HitTools:Print(string.format("Cursor grow debug mode: %s", db.debugMode and "ON" or "OFF"))
    return
  end

  -- /hit cursor test - Force scale to max for 2s
  if args == "test" then
    if not self._overlayFrame then
      HitTools:Print("ERROR: Cursor grow overlay not initialized!")
      return
    end

    HitTools:Print(string.format("Cursor grow test: Forcing max scale (%.1f) for 2 seconds...", db.maxScale))
    self._testModeActive = true
    self.currentScale = db.maxScale
    self.targetScale = db.maxScale
    self.state = STATE_GROWING  -- Ensure we get the pulse animation
    self:UpdateOverlay()

    -- Ensure frame is visible
    if self._overlayFrame then
      self._overlayFrame:Show()
    end

    C_Timer.After(2, function()
      if not self then return end
      self._testModeActive = false
      self.currentScale = 1.0
      self.targetScale = 1.0
      self.state = STATE_IDLE
      self.shakeScore = 0
      HitTools:Print("Cursor grow test complete")
    end)
    return
  end

  -- /hit cursor party - Trigger easter egg effect manually
  if args == "party" or args == "easteregg" then
    self:SpawnEasterEggEffect()
    HitTools:Print("Party time! 🎉")
    return
  end

  -- Show status
  HitTools:Print(string.format(
    "Cursor Grow: %s | Max Scale: %.1f | Debug: %s",
    db.enabled and "ENABLED" or "DISABLED",
    db.maxScale,
    db.debugMode and "ON" or "OFF"
  ))

  -- Show detailed status if debug mode is on
  if db.debugMode then
    local stateNames = {"IDLE", "GROWING", "SHRINKING"}
    HitTools:Print(string.format(
      "  State: %s | Score: %.2f | Scale: %.2f/%.2f | History: %d samples",
      stateNames[self.state + 1] or "?",
      self.shakeScore,
      self.currentScale,
      self.targetScale,
      #self.moveHistory
    ))
    HitTools:Print(string.format(
      "  Thresholds: Speed=%.0f FlipMin=%d StartGrow=%.1f StopGrow=%.1f",
      db.speedThreshold,
      db.minFlips or 4,
      db.startGrowThreshold,
      db.stopGrowThreshold
    ))
  end

  HitTools:Print("Commands: on|off | max <1.0-5.0> | debug [on|off] | test | party")
end

-- Cleanup
function CursorGrow:OnDisable()
  if self._ticker then
    self._ticker:Cancel()
    self._ticker = nil
  end

  if self._overlayFrame then
    self._overlayFrame:Hide()
  end

  -- Clean up particles
  for _, p in ipairs(self.particles) do
    if p.texture then
      p.texture:Hide()
    end
  end
  self.particles = {}

  if self._particleFrame then
    self._particleFrame:Hide()
  end

  self.state = STATE_IDLE
  self.currentScale = 1.0
  self.shakeScore = 0
  self.moveHistory = {}
  self._testModeActive = false
end

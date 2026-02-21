local _, HitTools = ...

local RXP_TEXTURE_PATH = "Interface\\AddOns\\RXPGuides\\Textures\\"

local function fmtSecondsShort(seconds)
  if not seconds or seconds <= 0 or seconds ~= seconds then return nil end
  seconds = math.floor(seconds + 0.5)
  local h = math.floor(seconds / 3600)
  local m = math.floor((seconds % 3600) / 60)
  if h > 0 then
    return string.format("%dh%02dm", h, m)
  end
  if m > 0 then
    return string.format("%dm", m)
  end
  return string.format("%ds", seconds)
end


local function shortNumber(n)
  if type(n) ~= "number" or n ~= n then
    return "n/a"
  end

  if AbbreviateNumbers then
    return AbbreviateNumbers(n)
  end

  local abs = math.abs(n)
  if abs >= 1000000000 then
    return string.format("%.1fb", n / 1000000000)
  end
  if abs >= 1000000 then
    return string.format("%.1fm", n / 1000000)
  end
  if abs >= 1000 then
    return string.format("%.1fk", n / 1000)
  end
  return string.format("%.0f", n)
end

function HitTools:CreateAlertUI()
  if self.AlertUI then return end

  local frame = CreateFrame("Frame", "HitToolsTopAlertFrame", UIParent)
  frame:SetSize(1200, 90)
  frame:SetPoint("TOP", UIParent, "TOP", 0, -110)
  frame:SetFrameStrata("FULLSCREEN_DIALOG")
  frame:Hide()

  frame.active = false
  frame.currentKey = nil
  frame.message = ""
  frame.charSpacing = 18
  frame.charCount = 0
  frame.baseX = {}
  frame.glyphs = {}
  frame.t = 0

  function frame:SetMessage(text)
    text = tostring(text or "")
    self.message = text
    self.charCount = #text
    local totalWidth = math.max((self.charCount - 1) * self.charSpacing, 0)
    self.totalWidth = totalWidth

    for i = 1, self.charCount do
      local glyph = self.glyphs[i]
      if not glyph then
        glyph = self:CreateFontString(nil, "OVERLAY")
        glyph:SetFont(STANDARD_TEXT_FONT, 34, "OUTLINE")
        glyph:SetShadowColor(0, 0, 0, 1)
        glyph:SetShadowOffset(2, -2)
        self.glyphs[i] = glyph
      end
      local ch = text:sub(i, i)
      glyph:SetText(ch)
      local x = (-totalWidth * 0.5) + ((i - 1) * self.charSpacing)
      self.baseX[i] = x
      glyph:ClearAllPoints()
      glyph:SetPoint("CENTER", self, "CENTER", x, 0)
      glyph:Show()
    end

    for i = self.charCount + 1, #self.glyphs do
      self.glyphs[i]:Hide()
    end
  end

  frame:SetScript("OnUpdate", function(self, elapsed)
    if not self.active or self.charCount <= 0 then return end
    self.t = (self.t or 0) + (elapsed or 0)

    local flash = (math.sin(self.t * 11.5) + 1) * 0.5
    local alpha = 0.78 + (0.22 * flash)

    for i = 1, self.charCount do
      local glyph = self.glyphs[i]
      if glyph and glyph:IsShown() then
        local phase = (self.t * 8.0) + (i * 0.65)
        local x = (self.baseX[i] or 0) + (math.sin(phase * 0.45) * 1.5)
        local y = math.sin(phase) * 7
        glyph:ClearAllPoints()
        glyph:SetPoint("CENTER", self, "CENTER", x, y)

        -- White <-> red flashing cycle.
        local w = (math.sin((self.t * 13.0) + (i * 0.85)) + 1) * 0.5
        local gb = 0.08 + (0.92 * w)
        glyph:SetTextColor(1, gb, gb, alpha)
      end
    end
  end)

  self.AlertUI = frame
end

function HitTools:ShowTopAlert(alertKey, text)
  if not alertKey then return end
  if not text or text == "" then return end
  if not self.AlertUI then
    self:CreateAlertUI()
  end
  if not self.AlertUI then return end

  local frame = self.AlertUI
  if frame.currentKey ~= alertKey or frame.message ~= text then
    frame:SetMessage(text)
  end
  frame.currentKey = alertKey
  frame.active = true
  frame:Show()
end

function HitTools:HideTopAlert(alertKey)
  if not self.AlertUI then return end
  local frame = self.AlertUI
  if alertKey and frame.currentKey and frame.currentKey ~= alertKey then return end
  frame.active = false
  frame.currentKey = nil
  frame:Hide()
end

function HitTools:CreateUI()
  if self.UI then return end

  local frame
  if BackdropTemplateMixin then
    frame = CreateFrame("Frame", "HitToolsFrame", UIParent, "BackdropTemplate")
  else
    frame = CreateFrame("Frame", "HitToolsFrame", UIParent)
  end

  frame:SetSize(300, 104)
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:SetUserPlaced(false)

  if frame.SetBackdrop then
    frame:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true,
      tileSize = 16,
      edgeSize = 14,
      insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0.04, 0.05, 0.08, 0.82)
    frame:SetBackdropBorderColor(0.76, 0.78, 0.82, 0.98)
  end

  frame.baseBg = frame:CreateTexture(nil, "BACKGROUND")
  frame.baseBg:SetAllPoints(frame)
  frame.baseBg:SetTexture("Interface\\Buttons\\WHITE8x8")
  frame.baseBg:SetVertexColor(0.03, 0.05, 0.08, 0.42)

  -- Top accent strip removed; keep header area visually consistent with the main background.

  frame.footer = CreateFrame("Frame", nil, frame)
  frame.footer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 4, 4)
  frame.footer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 4)
  frame.footer:SetHeight(20)

  frame.footerBg = frame.footer:CreateTexture(nil, "BACKGROUND")
  frame.footerBg:SetAllPoints(frame.footer)
  frame.footerBg:SetTexture(RXP_TEXTURE_PATH .. "rxp-banner")
  frame.footerBg:SetTexCoord(0, 1, 0.65, 1)
  frame.footerBg:SetVertexColor(0.28, 0.54, 0.78, 0.55)

  frame.footerLine = frame.footer:CreateTexture(nil, "BORDER")
  frame.footerLine:SetPoint("TOPLEFT", frame.footer, "TOPLEFT", 0, 0)
  frame.footerLine:SetPoint("TOPRIGHT", frame.footer, "TOPRIGHT", 0, 0)
  frame.footerLine:SetHeight(1)
  frame.footerLine:SetTexture("Interface\\Buttons\\WHITE8x8")
  frame.footerLine:SetVertexColor(0.72, 0.84, 0.95, 0.55)

  frame.icon = frame.footer:CreateTexture(nil, "ARTWORK")
  frame.icon:SetSize(14, 14)
  frame.icon:SetPoint("LEFT", frame.footer, "LEFT", 6, 0)
  frame.icon:SetTexture(RXP_TEXTURE_PATH .. "rxp_logo-64")

  frame.footerText = frame.footer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  frame.footerText:SetPoint("LEFT", frame.icon, "RIGHT", 6, 0)
  frame.footerText:SetTextColor(0.75, 0.88, 1.0)
  frame.footerText:SetText("Hit-Tools")

  -- Social Heatmap button
  frame.socialBtn = CreateFrame("Button", nil, frame.footer)
  frame.socialBtn:SetSize(16, 16)
  frame.socialBtn:SetPoint("RIGHT", frame.footer, "RIGHT", -28, 0)

  frame.socialBtn.icon = frame.socialBtn:CreateTexture(nil, "ARTWORK")
  frame.socialBtn.icon:SetAllPoints()
  frame.socialBtn.icon:SetTexture("Interface\\FriendsFrame\\StatusIcon-Online")
  frame.socialBtn.icon:SetVertexColor(0.5, 0.9, 1.0)  -- Cyan tint

  frame.socialBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  frame.socialBtn:SetScript("OnClick", function()
    if HitTools.SocialUI and HitTools.SocialUI.Toggle then
      HitTools.SocialUI:Toggle()
    end
  end)
  frame.socialBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Social Heatmap", 0.5, 0.9, 1.0)
    GameTooltip:AddLine("Who you run with and how smooth it goes", 0.8, 0.8, 0.8)
    GameTooltip:Show()
  end)
  frame.socialBtn:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)

  frame.cog = CreateFrame("Button", nil, frame.footer)
  frame.cog:SetSize(16, 16)
  frame.cog:SetPoint("RIGHT", frame.footer, "RIGHT", -6, 0)
  frame.cog:SetNormalTexture(RXP_TEXTURE_PATH .. "rxp_cog-32")
  frame.cog:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  frame.cog:SetPushedTexture(RXP_TEXTURE_PATH .. "rxp_cog-32")
  frame.cog:SetScript("OnClick", function()
    if HitTools.OpenOptions then
      HitTools:OpenOptions()
    end
  end)
  frame.cog:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Hit-Tools Options", 1, 0.82, 0)
    GameTooltip:AddLine("Click to open settings", 0.8, 0.8, 0.8)
    GameTooltip:Show()
  end)
  frame.cog:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)

  frame.line1 = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  frame.line1:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -12)
  frame.line1:SetJustifyH("LEFT")
  frame.line1:SetText("XP/hr: -")

  frame.line2 = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  frame.line2:SetPoint("TOPLEFT", frame.line1, "BOTTOMLEFT", 0, -6)
  frame.line2:SetJustifyH("LEFT")
  frame.line2:SetText("TTL: -")

  frame.line3 = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.line3:SetPoint("TOPLEFT", frame.line2, "BOTTOMLEFT", 0, -6)
  frame.line3:SetJustifyH("LEFT")
  frame.line3:SetTextColor(0.7, 0.86, 1.0)
  frame.line3:SetText("")

  frame.drag = CreateFrame("Frame", nil, frame)
  frame.drag:SetAllPoints(frame)
  frame.drag:EnableMouse(true)
  frame.drag:RegisterForDrag("LeftButton")
  frame.drag:SetScript("OnDragStart", function()
    if HitTools.DB and HitTools.DB.ui and not HitTools.DB.ui.locked then
      frame:StartMoving()
    end
  end)
  frame.drag:SetScript("OnDragStop", function()
    frame:StopMovingOrSizing()
    if not HitTools.DB or not HitTools.DB.ui then return end
    local point, _, relativePoint, x, y = frame:GetPoint(1)
    HitTools.DB.ui.point = point
    HitTools.DB.ui.relativePoint = relativePoint
    HitTools.DB.ui.x = x
    HitTools.DB.ui.y = y
  end)

  -- Keep buttons clickable even when drag overlay is active.
  frame.socialBtn:SetFrameLevel(frame.drag:GetFrameLevel() + 2)
  frame.cog:SetFrameLevel(frame.drag:GetFrameLevel() + 2)

  function frame:SetLocked(locked)
    if self.drag then
      self.drag:EnableMouse(not locked)
    end
  end

  function frame:UpdateText()
    if not HitTools.DB then return end

    local sessionRate, rollingRate = HitTools:GetRates()
    local rate = rollingRate or sessionRate
    local rateStr = rate and shortNumber(rate) or "n/a"

    local ttl = HitTools:GetTimeToLevelSeconds(true)
    local ttlStr = fmtSecondsShort(ttl) or "n/a"

    self.line1:SetText("XP/hr: " .. rateStr)
    self.line2:SetText("TTL: " .. ttlStr)

    if HitTools.dungeon and HitTools.dungeon.active then
      local gained = (HitTools.session.xpGained or 0) - (HitTools.dungeon.startTotalXP or 0)
      local dt = GetTime() - (HitTools.dungeon.startTime or GetTime())
      local runRate = (dt > 0 and gained > 0) and ((gained / dt) * 3600) or 0
      self.line3:SetText(string.format("%s: +%s XP (%s/hr)", HitTools.dungeon.name or "Dungeon", shortNumber(gained), shortNumber(runRate)))
    else
      self.line3:SetText("")
    end
  end

  frame:UpdateText()

  frame._accum = 0
  frame:SetScript("OnUpdate", function(self, elapsed)
    self._accum = (self._accum or 0) + (elapsed or 0)
    if self._accum < 1 then return end
    self._accum = 0
    self:UpdateText()
  end)

  local db = self.DB and self.DB.ui
  if db and db.point then
    frame:ClearAllPoints()
    frame:SetPoint(db.point, UIParent, db.relativePoint or db.point, db.x or 0, db.y or 0)
  else
    frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 20, -120)
  end

  self.UI = frame
end

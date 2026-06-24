-- ============================================================
--  CataHaste  |  CLIENT  |  WotLK 3.3.5
--
--  Shows floating damage numbers for CataHaste DoT extra-ticks over the
--  target's nameplate, and provides the settings window (minimap button).
--
--  Packet flow:
--    CATAHASTE:APPLY:slot|name|maxHp|spellId
--      → Pre-register slot; store name + maxHp for HP matching.
--
--    CATAHASTE:TICK:amount|slot|name|hp|spellId
--      → On first tick: find nameplate where
--          GetValue() ≈ hp / maxHp   (default WoW nameplates, 0-1 scale)
--          GetValue() ≈ hp            (nameplate addons, absolute scale)
--        and lock it to the slot.
--      → On subsequent ticks: use locked nameplate for floating text.
--
--  Client-side HP tracking after the first tick:
--    COMBAT_LOG_EVENT_UNFILTERED / SPELL_PERIODIC_DAMAGE lets the
--    client subtract damage from the last known HP without waiting for
--    another server ping.  The tracked HP is used to rebind the
--    nameplate if it goes off-screen and comes back.
-- ============================================================

local ADDON_PREFIX = "CATAHASTE:"

-- ============================================================
--  STATE
-- ============================================================
local slotName      = {}   -- [slot] = target name
local slotMaxHp     = {}   -- [slot] = mob max HP (from APPLY packet)
local slotTrackedHp = {}   -- [slot] = client-tracked current HP (updated via CLEU)
local slotNameplate = {}   -- [slot] = locked nameplate frame
local slotSpell     = {}   -- [slot] = spellId (for CLEU matching)
local slotSide      = {}   -- [slot] = last spawn side (alternates ±1)
local lastKnownPos  = {}   -- [slot] = { x, y } last valid nameplate centre

-- ============================================================
--  SETTINGS
-- ============================================================
local CFG = {
    FONT_SIZE = 20,
    RISE_HEIGHT = 80,
    RISE_SPEED  = 55,
    SPREAD_MIN  = 40,
    SPREAD_MAX  = 60,
}

-- ============================================================
--  NAMEPLATE HELPERS
-- ============================================================
local function frameHasName(frame, name)
    for _, r in ipairs({ frame:GetRegions() }) do
        if r.GetObjectType and r:GetObjectType() == "FontString"
        and r:GetText() == name then return true end
    end
    for _, sub in ipairs({ frame:GetChildren() }) do
        for _, r in ipairs({ sub:GetRegions() }) do
            if r.GetObjectType and r:GetObjectType() == "FontString"
            and r:GetText() == name then return true end
        end
    end
    return false
end

-- Normalised difference (0-1 HP fraction) between a single plate's health bar
-- and the server-sent HP.  Works for both default WoW bars and nameplate addons
-- by dividing the bar value by its own max.  Returns math.huge if no bar found.
local function plateNorm(frame, targetHp, maxHp)
    local barVal, barMax = nil, nil
    for _, sub in ipairs({ frame:GetChildren() }) do
        local okV, v = pcall(function() return sub:GetValue() end)
        if okV and v and v > 0 then
            local okM, _, mx = pcall(function() return sub:GetMinMaxValues() end)
            barVal = v
            barMax = (okM and mx and mx > 0) and mx or 1
            break
        end
    end
    if not barVal then return math.huge end
    local barFrac = barVal / barMax
    local expFrac = (maxHp and maxHp > 0) and (targetHp / maxHp) or barFrac
    return math.abs(barFrac - expFrac)
end

-- Returns the same-name nameplate whose health bar best matches targetHp, plus
-- the best and runner-up normalised diffs.  secondNorm == math.huge means the
-- match is unique (only one same-name plate); bestNorm == secondNorm means a
-- tie (several plates read the same HP) -- the caller uses this to avoid binding
-- to the tie-break fallback plate.
local function findNameplate(name, targetHp, maxHp)
    local best, bestNorm, secondNorm = nil, math.huge, math.huge
    for _, child in ipairs({ WorldFrame:GetChildren() }) do
        if not child:GetName() and child:IsShown() and frameHasName(child, name) then
            local norm = plateNorm(child, targetHp, maxHp)
            if norm < bestNorm then
                secondNorm = bestNorm
                bestNorm   = norm
                best       = child
            elseif norm < secondNorm then
                secondNorm = norm
            end
        end
    end
    return best, bestNorm, secondNorm
end

-- Binds the slot to the best HP-matching same-name nameplate, with HYSTERESIS:
-- once a slot is locked to a visible plate, it is kept unless another plate
-- matches STRICTLY better.  On a tie the current lock wins, so the text no
-- longer jumps to the tie-break fallback plate (the first child = rightmost mob)
-- in the brief moment after a tick when the target's bar hasn't refreshed yet
-- and all bars momentarily read equal.  A genuinely lower-HP plate (the real
-- target once its bar updates) still beats the current lock and takes over,
-- which also self-corrects an initial mis-bind from the first full-HP ping.
local function tryBind(slot, hp)
    local name  = slotName[slot]
    local maxHp = slotMaxHp[slot]
    if not name or not maxHp then return end

    local np, bestNorm = findNameplate(name, hp, maxHp)
    if not np then return end

    local cur = slotNameplate[slot]
    if cur and cur:IsShown() then
        -- Keep the current lock unless the candidate matches strictly better.
        if bestNorm >= plateNorm(cur, hp, maxHp) then return end
    end

    if cur ~= np then
        slotNameplate[slot] = np
    end
end

local function getNameplatePos(frame)
    if not frame or not frame:IsShown() then return nil end
    local cx, cy = frame:GetCenter()
    if not cx or not cy then return nil end
    local s = UIParent:GetEffectiveScale()
    return cx / s, cy / s
end

-- ============================================================
--  FLOATING TEXT
-- ============================================================
local function spawnFloatingText(amount, slot)
    local x, y

    -- 1. Locked nameplate
    local np = slotNameplate[slot]
    if np and np:IsShown() then
        x, y = getNameplatePos(np)
        if x then lastKnownPos[slot] = { x, y } end
    end

    -- 2. Last known position (only when a lock exists)
    if not x and lastKnownPos[slot] and slotNameplate[slot] then
        x, y = lastKnownPos[slot][1], lastKnownPos[slot][2]
    end

    if not x then return end  -- no position → skip

    local side = slotSide[slot] or 1
    slotSide[slot] = -side
    local offsetX = side * math.random(CFG.SPREAD_MIN, CFG.SPREAD_MAX)

    local frame = CreateFrame("Frame", nil, UIParent)
    frame:SetWidth(120); frame:SetHeight(30)
    frame:SetFrameStrata("BACKGROUND")
    frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x + offsetX, y)

    local fs = frame:CreateFontString(nil, "OVERLAY")
    fs:SetPoint("CENTER")
    fs:SetFont("Fonts\\FRIZQT__.TTF", CFG.FONT_SIZE, "THICKOUTLINE")
    fs:SetText(tostring(amount))
    fs:SetTextColor(1.0, 1.0, 0.0, 1.0)
    frame:Show()

    local elapsed = 0
    local duration = 2.5
    local lastX, lastY = x, y
    local spawnNp = slotNameplate[slot]  -- capture once; never follows re-binds

    frame:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed >= duration then
            self:SetScript("OnUpdate", nil)
            self:Hide()
            return
        end

        -- Track nameplate movement using the frame captured at spawn.
        -- Using slotNameplate[slot] here would cause the text to jump to
        -- whatever plate the slot re-binds to after the mob dies.
        local curNp = spawnNp
        if curNp and curNp:IsShown() then
            local nx, ny = getNameplatePos(curNp)
            if nx then
                lastX, lastY = nx, ny
                lastKnownPos[slot] = { nx, ny }
            end
        end

        -- Hide text if nameplate is gone
        if curNp and not curNp:IsShown() then
            fs:SetAlpha(0); return
        end

        self:SetPoint("CENTER", UIParent, "BOTTOMLEFT",
            lastX + offsetX,
            lastY + math.min(elapsed * CFG.RISE_SPEED, CFG.RISE_HEIGHT))

        if elapsed > 1.2 then
            fs:SetAlpha(1 - ((elapsed - 1.2) / 1.3))
        else
            fs:SetAlpha(1)
        end
    end)
end

-- ============================================================
--  PACKET HANDLERS
-- ============================================================

-- TIMELINE: slot|duration|maxHp|hp0|hp1|...|hpN
--   Sent once when the extra ticks start.  We only need slot + maxHp
--   (the maxHp lets findNameplate normalise the absolute server HP to the
--   0-1 scale default WoW nameplates report).
--   NOTE: does NOT clear the existing nameplate lock.  A slot maps permanently
--   to one mob GUID, so its nameplate never changes; the server re-sends
--   TIMELINE on every refresh, and clearing the lock here forced an ambiguous
--   rebind each time (the text jumped to other damaged same-name plates).  The
--   watcher releases the lock if the plate actually disappears.
local function onTimeline(rest)
    local slotStr, _durStr, maxHpStr = rest:match("^(%d+)|(%d+)|(%d+)")
    if not slotStr then return end

    local slot  = tonumber(slotStr)
    local maxHp = tonumber(maxHpStr)

    slotMaxHp[slot] = maxHp
end

-- TICK (damage): spellId|amount|slot|name|newHp|guidLow|dist
local function onTick(rest)
    local spellIdStr, amtStr, slotStr, name, hpStr =
        rest:match("^(%d+)|(%d+)|(%d+)|([^|]+)|(%d+)|")
    if not spellIdStr then return end

    local spellId = tonumber(spellIdStr)
    local amount  = tonumber(amtStr)
    local slot    = tonumber(slotStr)
    local hp      = tonumber(hpStr)

    slotName[slot]      = name
    slotSpell[slot]     = spellId
    slotTrackedHp[slot] = hp

    -- (Re-)bind only when the match is unambiguous; self-corrects mis-binds.
    tryBind(slot, hp)

    spawnFloatingText(amount, slot)
end

-- HP: slot|currentHp   (50 ms ping while ticks run)
--   Keeps tracked HP fresh and rebinds the nameplate if it was lost
--   (e.g. target went off-screen and came back).
local function onHpPing(rest)
    local slotStr, hpStr = rest:match("^(%d+)|(%d+)$")
    if not slotStr then return end

    local slot = tonumber(slotStr)
    local hp   = tonumber(hpStr)
    slotTrackedHp[slot] = hp

    -- 50 ms re-evaluation: locks the correct plate the instant HP diverges,
    -- and switches away from an earlier ambiguous mis-bind.
    tryBind(slot, hp)
end

-- HP is streamed authoritatively by the server (per-tick newHp + 50 ms HP
-- pings), so no client-side combat-log HP tracking is needed.  Binding is
-- re-evaluated in onTick / onHpPing via tryBind.

-- ============================================================
--  NAMEPLATE WATCHER  (detects when locked nameplate goes off-screen)
-- ============================================================
local watcher = CreateFrame("Frame")
watcher:SetScript("OnUpdate", function()
    for slot, f in pairs(slotNameplate) do
        if not f:IsShown() then
            slotNameplate[slot] = nil
            -- Rebind will happen on next TICK or CLEU event.
        end
    end
end)

-- Forward declaration (body defined in Phase 2 section below)
local onModePacket

-- ============================================================
--  CHAT_MSG_SYSTEM LISTENER
-- ============================================================
local eventFrame = CreateFrame("Frame", "CataHasteEventFrame")
eventFrame:RegisterEvent("CHAT_MSG_SYSTEM")
eventFrame:SetScript("OnEvent", function(_, _, msg)
    if type(msg) ~= "string" then return end
    if msg:sub(1, #ADDON_PREFIX) ~= ADDON_PREFIX then return end
    local payload = msg:sub(#ADDON_PREFIX + 1)

    if payload:sub(1, 9) == "TIMELINE:" then
        onTimeline(payload:sub(10))
    elseif payload:sub(1, 3) == "HP:" then
        onHpPing(payload:sub(4))
    elseif payload:sub(1, 5) == "MODE:" then
        onModePacket(payload:sub(6))
    else
        onTick(payload)
    end
end)

-- Suppress packets from chat windows
local hookedFrames = {}
local function hookChatFrame(cf)
    if hookedFrames[cf] then return end
    hookedFrames[cf] = true
    local delay = CreateFrame("Frame")
    local waited = 0
    delay:SetScript("OnUpdate", function(self, dt)
        waited = waited + dt
        if waited < 0.5 then return end
        self:SetScript("OnUpdate", nil)
        local orig = cf:GetScript("OnEvent")
        if not orig then return end
        cf:SetScript("OnEvent", function(self2, event, ...)
            if event == "CHAT_MSG_SYSTEM" then
                local m = ...
                if type(m) == "string" and m:sub(1, #ADDON_PREFIX) == ADDON_PREFIX then return end
            end
            orig(self2, event, ...)
        end)
    end)
end
for i = 1, NUM_CHAT_WINDOWS or 7 do
    local cf = _G["ChatFrame" .. i]
    if cf then hookChatFrame(cf) end
end

-- ============================================================
--  PHASE 2: MODE WINDOW
--    Normal Mode  -> forced-haste slider (0..75%), for players without haste gear
--    Haste Mode   -> Loot / Power toggle, uses the player's real haste rating
-- ============================================================

-- Simple On/Off: Off = no extra ticks, On = FORCED_ON (loot-safe forced haste).
local FORCED_ON  = 75         -- loot-safe forced haste % when On

local chTop      = "normal"   -- "normal" | "haste"
local chSlider   = 0          -- 0 = Off, 1 = On (normal mode)
local chSub      = "loot"     -- "loot" | "power" (haste mode)
local uiReady    = false      -- true once saved vars are loaded

local function sliderToForced(s)
    return (s > 0) and FORCED_ON or 0
end

-- Server is driven entirely by the client now; no inbound MODE packet.
onModePacket = function() end

-- Push the full state to the server (suppressed SAY command). Out of combat only;
-- in-combat changes are re-sent on PLAYER_REGEN_ENABLED.
local function chSendState()
    if InCombatLockdown() or UnitAffectingCombat("player") then return end
    SendChatMessage("ch set " .. chTop .. " " .. sliderToForced(chSlider) .. " " .. chSub, "SAY")
end

local function chSave()
    if type(CataHasteDB) ~= "table" then CataHasteDB = {} end
    CataHasteDB.top    = chTop
    CataHasteDB.slider = chSlider
    CataHasteDB.sub    = chSub
end

local refreshWindow            -- forward declaration

local function notInCombat()
    if UnitAffectingCombat("player") then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff4444[CataHaste]|r Change only outside combat.")
        return false
    end
    return true
end

-- ── POWER CONFIRMATION ───────────────────────────────────────
StaticPopupDialogs["CATAHASTE_CONFIRM_POWER"] = {
    text = "|cffffaa00CataHaste - Power|r\n\nExtra ticks hit |cffff4444FULL damage|r, but |cffff4444normal loot AND kill-credit is affected|r.\n\n|cffff0000COLLECTION QUESTS MAY FAIL TO COMPLETE!|r\n\nXP will still work perfectly.",
    button1 = "Enable Power",
    button2 = "Cancel",
    OnAccept = function()
        chSub = "power"; chSave(); chSendState(); refreshWindow()
    end,
    timeout = 0, whileDead = false, hideOnEscape = true, preferredIndex = 3,
}

-- ── MAIN WINDOW ──────────────────────────────────────────────
local win = CreateFrame("Frame", "CataHasteWindow", UIParent)
win:SetWidth(290); win:SetHeight(180)
win:SetPoint("CENTER")
win:SetFrameStrata("DIALOG")
win:SetBackdrop({
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
win:SetMovable(true); win:EnableMouse(true)
win:RegisterForDrag("LeftButton")
win:SetScript("OnDragStart", function(self) self:StartMoving() end)
win:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)
win:Hide()

local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", win, "TOP", 0, -16)
title:SetText("CataHaste")

local closeBtn = CreateFrame("Button", nil, win, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", win, "TOPRIGHT", -6, -6)

-- ── OPTIONS BUTTON (top-left) + OPTIONS PANEL ────────────────
local CFG_DEFAULTS = { FONT_SIZE=20, RISE_HEIGHT=80, RISE_SPEED=55, SPREAD_MIN=40, SPREAD_MAX=60 }

local optBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
optBtn:SetWidth(22); optBtn:SetHeight(22)
optBtn:SetPoint("TOPLEFT", win, "TOPLEFT", 12, -10)
optBtn:SetText("O")

local opt = CreateFrame("Frame", "CataHasteOptions", UIParent)
opt:SetWidth(280); opt:SetHeight(320)
opt:SetPoint("CENTER")
opt:SetFrameStrata("DIALOG")
opt:SetBackdrop({
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
opt:SetMovable(true); opt:EnableMouse(true)
opt:RegisterForDrag("LeftButton")
opt:SetScript("OnDragStart", function(self) self:StartMoving() end)
opt:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)
opt:Hide()

local optTitle = opt:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
optTitle:SetPoint("TOP", opt, "TOP", 0, -16)
optTitle:SetText("Floating Text Options")

local optClose = CreateFrame("Button", nil, opt, "UIPanelCloseButton")
optClose:SetPoint("TOPRIGHT", opt, "TOPRIGHT", -6, -6)

local CFG_SPECS = {
    { key = "FONT_SIZE",   label = "Font Size",          min = 10, max = 40, step = 1 },
    { key = "RISE_HEIGHT", label = "Rise Height",        min = 20, max = 200, step = 5 },
    { key = "RISE_SPEED",  label = "Rise Speed",         min = 10, max = 150, step = 5 },
    { key = "SPREAD_MIN",  label = "Horizontal Spread Min", min = 0, max = 100, step = 5 },
    { key = "SPREAD_MAX",  label = "Horizontal Spread Max", min = 0, max = 150, step = 5 },
}

local cfgSliders = {}

local function saveCfg()
    if type(CataHasteDB) ~= "table" then CataHasteDB = {} end
    CataHasteDB.cfg = CataHasteDB.cfg or {}
    for k, v in pairs(CFG) do CataHasteDB.cfg[k] = v end
end

local function refreshOptSliders()
    for _, spec in ipairs(CFG_SPECS) do
        local s = cfgSliders[spec.key]
        if s then
            s:SetValue(CFG[spec.key])
            _G[s:GetName() .. "Text"]:SetText(spec.label .. ":  " .. CFG[spec.key])
        end
    end
end

local yOff = -50
for i, spec in ipairs(CFG_SPECS) do
    local s = CreateFrame("Slider", "CataHasteCfgSlider" .. i, opt, "OptionsSliderTemplate")
    s:SetWidth(230); s:SetHeight(16)
    s:SetPoint("TOP", opt, "TOP", 0, yOff)
    s:SetMinMaxValues(spec.min, spec.max)
    s:SetValueStep(spec.step)
    _G[s:GetName() .. "Low"]:SetText(tostring(spec.min))
    _G[s:GetName() .. "High"]:SetText(tostring(spec.max))
    s:SetScript("OnValueChanged", function(self, value)
        local v = math.floor(value + 0.5)
        CFG[spec.key] = v
        _G[self:GetName() .. "Text"]:SetText(spec.label .. ":  " .. v)
    end)
    s:SetScript("OnMouseUp", function() saveCfg() end)
    cfgSliders[spec.key] = s
    yOff = yOff - 42
end

local spreadWarn = opt:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
spreadWarn:SetPoint("TOP", opt, "TOP", 0, yOff - 4)
spreadWarn:SetWidth(250); spreadWarn:SetJustifyH("CENTER")
spreadWarn:SetText("Spread Min |cffff4444CANNOT|r be higher than Spread Max or you get a Lua Error!")

opt:SetHeight(355)

local resetBtn = CreateFrame("Button", nil, opt, "UIPanelButtonTemplate")
resetBtn:SetWidth(120); resetBtn:SetHeight(24)
resetBtn:SetPoint("BOTTOM", opt, "BOTTOM", 0, 18)
resetBtn:SetText("Reset Defaults")
resetBtn:SetScript("OnClick", function()
    for k, v in pairs(CFG_DEFAULTS) do CFG[k] = v end
    refreshOptSliders()
    saveCfg()
end)

optBtn:SetScript("OnClick", function()
    if opt:IsShown() then opt:Hide() else refreshOptSliders(); opt:Show() end
end)

-- Top-mode toggle
local btnNormal = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
btnNormal:SetWidth(115); btnNormal:SetHeight(24)
btnNormal:SetPoint("TOPLEFT", win, "TOPLEFT", 20, -44)
btnNormal:SetText("Normal Mode")

local btnHaste = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
btnHaste:SetWidth(115); btnHaste:SetHeight(24)
btnHaste:SetPoint("TOPRIGHT", win, "TOPRIGHT", -20, -44)
btnHaste:SetText("Haste Mode")

-- Explanation
local expl = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
expl:SetPoint("TOPLEFT", win, "TOPLEFT", 20, -76)
expl:SetWidth(250); expl:SetJustifyH("LEFT")

-- Normal section: forced-haste slider
local slider = CreateFrame("Slider", "CataHasteForceSlider", win, "OptionsSliderTemplate")
slider:SetWidth(230); slider:SetHeight(16)
slider:SetPoint("TOPLEFT", win, "TOPLEFT", 30, -118)
slider:SetMinMaxValues(0, 1)
slider:SetValueStep(1)
_G["CataHasteForceSliderLow"]:SetText("Off")
_G["CataHasteForceSliderHigh"]:SetText("On")
_G["CataHasteForceSliderText"]:SetText("")
local sliderVal = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
sliderVal:SetPoint("TOP", slider, "BOTTOM", 0, 30)

local function setSliderLabel()
    if chSlider <= 0 then
        sliderVal:SetText("Extra Ticks: |cffaaaaaaOff|r")
    else
        sliderVal:SetText("Extra Ticks: |cff00ff00On|r")
    end
end

slider:SetScript("OnValueChanged", function(self, value)
    chSlider = math.floor(value + 0.5)
    setSliderLabel()
end)
slider:SetScript("OnMouseUp", function()
    if not uiReady then return end
    chSave(); chSendState()
end)

-- Haste section: loot/power toggle
local btnLoot = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
btnLoot:SetWidth(105); btnLoot:SetHeight(24)
btnLoot:SetPoint("TOPLEFT", win, "TOPLEFT", 25, -118)
btnLoot:SetText("Loot")

local btnPower = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
btnPower:SetWidth(105); btnPower:SetHeight(24)
btnPower:SetPoint("TOPRIGHT", win, "TOPRIGHT", -25, -118)
btnPower:SetText("Power")

local hasteWarn = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
hasteWarn:SetPoint("TOPLEFT", win, "TOPLEFT", 20, -148)
hasteWarn:SetWidth(250); hasteWarn:SetJustifyH("LEFT")

refreshWindow = function()
    if chTop == "normal" then btnNormal:LockHighlight() else btnNormal:UnlockHighlight() end
    if chTop == "haste"  then btnHaste:LockHighlight()  else btnHaste:UnlockHighlight()  end

    if chTop == "normal" then
        win:SetHeight(160)
        expl:SetText("For players without haste gear. Turns extra DoT ticks on even with 0 haste rating.")
        slider:Show(); sliderVal:Show()
        btnLoot:Hide(); btnPower:Hide(); hasteWarn:Hide()
        slider:SetValue(chSlider)
        setSliderLabel()
    else
        win:SetHeight(205)
        expl:SetText("For players with haste mods like Test Haste Ring.")
        slider:Hide(); sliderVal:Hide()
        btnLoot:Show(); btnPower:Show(); hasteWarn:Show()
        if chSub == "loot"  then btnLoot:LockHighlight()  else btnLoot:UnlockHighlight()  end
        if chSub == "power" then btnPower:LockHighlight() else btnPower:UnlockHighlight() end
        if chSub == "power" then
            hasteWarn:SetText("|cffff4444Power:|r full extra-tick damage. XP works, but |cffff4444loot drops AND kill-credit are affected|r. Quests requiring item loots may not complete. \n|cffff4444NOT recommended|r for leveling!")
        else
            hasteWarn:SetText("|cff00ff00Loot:|r extra-tick damage capped to 45% of mob HP so loot/XP always work. \n \n|cff00ff00Recommended|r for leveling!")
        end
    end
end

btnNormal:SetScript("OnClick", function()
    if not notInCombat() then return end
    chTop = "normal"; chSave(); chSendState(); refreshWindow()
end)
btnHaste:SetScript("OnClick", function()
    if not notInCombat() then return end
    chTop = "haste"; chSave(); chSendState(); refreshWindow()
end)
btnLoot:SetScript("OnClick", function()
    if not notInCombat() then return end
    chSub = "loot"; chSave(); chSendState(); refreshWindow()
end)
btnPower:SetScript("OnClick", function()
    if not notInCombat() then return end
    StaticPopup_Show("CATAHASTE_CONFIRM_POWER")
end)

-- ── MINIMAP BUTTON (opens the window) ────────────────────────
local mmBtn = CreateFrame("Button", "CataHasteMinimap", UIParent)
mmBtn:SetWidth(32); mmBtn:SetHeight(32)
mmBtn:SetFrameStrata("MEDIUM"); mmBtn:SetFrameLevel(8)
mmBtn:SetPoint("TOPLEFT", Minimap, "TOPLEFT", 2, -2)
mmBtn:SetMovable(true); mmBtn:EnableMouse(true)
mmBtn:RegisterForClicks("LeftButtonUp")
mmBtn:RegisterForDrag("LeftButton")
mmBtn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local mmIcon = mmBtn:CreateTexture(nil, "ARTWORK")
mmIcon:SetWidth(20); mmIcon:SetHeight(20)
mmIcon:SetTexture("Interface\\Icons\\Spell_Holy_BorrowedTime")
mmIcon:SetPoint("CENTER", mmBtn, "CENTER", 0, 0)

local mmBorder = mmBtn:CreateTexture(nil, "OVERLAY")
mmBorder:SetWidth(56); mmBorder:SetHeight(56)
mmBorder:SetPoint("CENTER", mmBtn, "CENTER", 10, -10)
mmBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

mmBtn:SetScript("OnClick", function()
    if win:IsShown() then win:Hide() else refreshWindow(); win:Show() end
end)
mmBtn:SetScript("OnDragStart", function(self) self:StartMoving() end)
mmBtn:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)
mmBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("CataHaste", 1, 0.82, 0)
    GameTooltip:AddLine("Click to open settings", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end)
mmBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- ── SAVED VARS + LOGIN / COMBAT SYNC ─────────────────────────
local sync = CreateFrame("Frame")
sync:RegisterEvent("ADDON_LOADED")
sync:RegisterEvent("PLAYER_LOGIN")
sync:RegisterEvent("PLAYER_REGEN_ENABLED")
sync:SetScript("OnEvent", function(_, ev, arg1)
    if ev == "ADDON_LOADED" and arg1 == "CataHaste" then
        if type(CataHasteDB) ~= "table" then CataHasteDB = {} end
        if CataHasteDB.top == "normal" or CataHasteDB.top == "haste" then chTop = CataHasteDB.top end
        if type(CataHasteDB.slider) == "number" then
            chSlider = (CataHasteDB.slider > 0) and 1 or 0
        end
        if CataHasteDB.sub == "loot" or CataHasteDB.sub == "power" then chSub = CataHasteDB.sub end
        if type(CataHasteDB.cfg) == "table" then
            for k in pairs(CFG) do
                if type(CataHasteDB.cfg[k]) == "number" then CFG[k] = CataHasteDB.cfg[k] end
            end
        end
        uiReady = true
        refreshWindow()
    elseif ev == "PLAYER_LOGIN" then
        local f = CreateFrame("Frame")
        f:SetScript("OnUpdate", function(self, dt)
            self.t = (self.t or 0) + dt
            if self.t < 2 then return end
            self:SetScript("OnUpdate", nil)
            chSendState()
        end)
    elseif ev == "PLAYER_REGEN_ENABLED" then
        chSendState()   -- re-apply any change that was blocked during combat
    end
end)

DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00[CataHaste] Loaded.|r")
-- Rebuffed · Logging.lua — client-flavor detection + the combat-log recording GUARANTEE.
--
-- This is the addon's highest-value job and the first vertical of "recording": whenever you are
-- playing, the engine-written WoWCombatLog.txt IS being written, with advanced params, cleanly,
-- for the WHOLE time — not just in instances. There is no opt-out, and if logging is ever off we
-- complain heavily and repeatedly until it is back on.
--
-- Cross-client (Midnight "WoW Forever" + Classic/SoD):
--   Midnight's Secret Values (12.0) make in-combat CLEU unreadable to addons, so the file is the
--   only clean path. Classic/SoD have NO Secret Values (CLEU is readable) — but we deliberately use
--   the SAME file-guarantee + landmark model on both so there is a single code path. The only
--   sanctioned APIs we touch here exist on every flavor: SetCVar/GetCVar("advancedCombatLogging"),
--   LoggingCombat(bool) and LoggingCombat() (query).

local ADDON, ns = ...
local L = {}
ns.Logging = L

-- ── client flavor (set once at load — Logging loads first, so all modules can read these) ──
local MAINLINE = WOW_PROJECT_MAINLINE or 1
ns.isMainline     = (WOW_PROJECT_ID == nil) or (WOW_PROJECT_ID == MAINLINE)
ns.isClassic      = not ns.isMainline
ns.hasSecretValues = ns.isMainline                              -- Midnight blocks in-combat CLEU
ns.hasChallengeMode = ns.isMainline and (C_ChallengeMode ~= nil) -- Mythic+ is retail-only
ns.hasDamageMeter   = (C_DamageMeter ~= nil)                     -- Blizzard's 12.0 meter; nil on Classic
ns.flavor          = ns.isMainline and "mainline" or "classic"

-- advancedCombatLogging=1 adds infoGUID, HP, position, item level + COMBATANT_INFO to the file —
-- the fields the backend segmenter and CLA/RPB metrics depend on. Best-effort: some clients gate
-- cvars, so we pcall and re-read rather than trust the write.
local function setACL(on)
  local ok = pcall(SetCVar, "advancedCombatLogging", on and "1" or "0")
  return ok
end

-- Current on-disk logging posture as the engine sees it (source of truth, not our intent).
function L.state()
  local aclOn = GetCVar("advancedCombatLogging") == "1"
  local combatOn = LoggingCombat() and true or false -- no-arg form queries current state
  return aclOn, combatOn
end

-- Force logging ON; report whether we had to change anything.
-- Returns: aclOn, combatOn, changed (all reflect the state AFTER enforcement).
function L.enforce()
  local aclOn, combatOn = L.state()
  local changed = false
  if not aclOn then changed = setACL(true) or changed end
  if not combatOn then LoggingCombat(true); changed = true end
  aclOn, combatOn = L.state()
  return aclOn, combatOn, changed
end

-- Provided for completeness, but the addon never calls this: logging is always-on by design.
function L.stop() LoggingCombat(false) end

-- Compact snapshot for the session record / status line.
function L.snapshot()
  local aclOn, combatOn = L.state()
  return { acl = aclOn, combat = combatOn }
end

-- ── heavy, repeating complaint when logging is not actually on ────────────────────────────────
-- The user's rule: if advanced logging is off, complain HEAVILY and always. So we hit three
-- channels at once (chat, center-screen raid warning, red UI error text + a sound) and repeat on a
-- timer until it is fixed — impossible to miss, whether the player is leveling or mid-raid.
local NAG_PERIOD = 10
local lastNag, wasOff = -1e9, false

local function bigWarn(text)
  if RaidNotice_AddMessage and RaidWarningFrame then
    pcall(RaidNotice_AddMessage, RaidWarningFrame, text, (ChatTypeInfo and ChatTypeInfo.RAID_WARNING) or { r = 1, g = .2, b = .2 })
  end
  if UIErrorsFrame and UIErrorsFrame.AddMessage then
    pcall(UIErrorsFrame.AddMessage, UIErrorsFrame, text, 1, .1, .1, 1)
  end
  if PlaySound then pcall(PlaySound, 8959) end -- IG_MainMenuOptionCheckBoxOn-ish / RaidWarning cue
end

function L.nag(force)
  local now = GetTime()
  if not force and (now - lastNag) < NAG_PERIOD then return end
  lastNag = now
  local msg = "COMBAT LOGGING IS OFF — your gameplay is NOT being recorded."
  ns.msg("|cffe5544b" .. msg .. "|r  Rebuffed needs |cffffffffAdvanced Combat Logging|r on — re-enabling it now. If this keeps happening, another addon or a macro is turning it off.")
  bigWarn("Rebuffed: " .. msg)
end

-- The guardian runs for the WHOLE play session (not just in instances). It enforces logging every
-- NAG_PERIOD seconds, nags heavily while off, confirms once when it comes back, and records a
-- LOGGING_REPAIR landmark (via the recorder) whenever it had to fix a mid-session drop.
-- How many times we've had to turn combat logging back on after startup (exposed for the UI).
L.repairs = 0

function L.startGuardian()
  if L._guardian then return end
  local started = false
  local function tick()
    local acl, combat, changed = L.enforce()
    local off = not (acl and combat)
    if off then
      L.nag()
      wasOff = true
    elseif wasOff then
      wasOff = false
      ns.msg("|cff47c97ecombat logging is back ON|r — recording resumed.")
    end
    -- A change after startup means something dropped logging and we corrected it — count it + mark
    -- the gap in the landmark index (the first tick is initial setup, not a repair).
    if changed and started then
      L.repairs = L.repairs + 1
      if ns.Recorder and ns.Recorder.noteLoggingRepair then ns.Recorder.noteLoggingRepair(acl, combat) end
    end
    started = true
  end
  tick() -- enforce immediately on first world-enter
  -- Re-enforce every 3s: WoW (or another addon) can drop combat logging; a fast poll keeps any gap
  -- tiny instead of the ~10s flicker the old interval caused. Nagging self-throttles (NAG_PERIOD).
  L._guardian = C_Timer.NewTicker(3, tick)
end

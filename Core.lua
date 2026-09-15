-- Rebuffed · Core.lua — boot, event router, slash.
--
-- CORE GUARANTEE (not optional): advanced combat logging + landmark recording are ALWAYS ON, and
-- now EVERYWHERE — open-world leveling included, not just instances. Recording is the entire reason
-- the addon exists; a night with logging silently off is a lost night, so it is unconditional and
-- self-healing (ns.Logging guardian) and complains heavily if it ever can't keep logging on.
--
-- Cross-client: the primary target is the Midnight "WoW Forever" model (Secret Values → CLEU-free,
-- the file is the source of truth). The same code runs on Classic/SoD (our current data-gathering
-- testbed): Midnight-only APIs (C_DamageMeter, C_ChallengeMode / M+) are feature-detected and their
-- events are only registered where they exist. Flags live on ns (set in Logging.lua).

local ADDON, ns = ...

ns.VERSION = "0.5.0"
ns.GOLD = "|cffc9a63c"
ns.CYAN = "|cff00afd7"
function ns.msg(text) print(ns.GOLD .. "Rebuffed|r: " .. text) end

RebuffedDB = RebuffedDB or nil -- materialized on ADDON_LOADED

local f = CreateFrame("Frame")

-- ── context detection (ambient recording — always on, no opt-out) ─────────────
-- Raid/dungeon → a full "instance" session (encounters, challenge mode, combat edges, meter).
-- Everywhere else → a lightweight "world" session for leveling (level-ups, deaths, zone changes).
-- We transition between them so exactly one session is active at a time.
local function checkContext()
  local inInst, itype = IsInInstance()
  local wantInstance = inInst and (itype == "raid" or itype == "party")
  local sess = ns.Recorder.active()
  if wantInstance then
    if sess and sess.kind ~= "instance" then ns.Recorder.stop("entered instance"); sess = nil end
    if not sess then ns.Recorder.start("instance") end
  else
    if sess and sess.kind == "instance" then ns.Recorder.stop("left instance"); sess = nil end
    if not sess then ns.Recorder.start("world") end
  end
end
ns.checkContext = checkContext
ns.checkInstance = checkContext -- back-compat alias

-- ── event router (landmarks only — never CLEU) ────────────────────────────────
local handlers = {
  ENCOUNTER_START = function(id, name, diff, size) ns.Recorder.onEncounterStart(id, name, diff, size) end,
  ENCOUNTER_END   = function(id, name, diff, size, success) ns.Recorder.onEncounterEnd(id, name, diff, size, success) end,
  PLAYER_REGEN_DISABLED = function() ns.Logging.enforce(); if ns.Recorder.active() then ns.Recorder.onCombatStart() end end,
  PLAYER_REGEN_ENABLED  = function() if ns.Recorder.active() then ns.Recorder.onCombatEnd() end end,
  PLAYER_LEVEL_UP = function(level) ns.Recorder.onLevelUp(level) end,
  PLAYER_DEAD     = function() ns.Recorder.onDeath() end,
  CHALLENGE_MODE_START = function()
    if not ns.Recorder.active() then return end
    local name = GetInstanceInfo()
    local instID = select(8, GetInstanceInfo())
    local cmID, level, affixes
    pcall(function()
      cmID = C_ChallengeMode.GetActiveChallengeMapID()
      level, affixes = C_ChallengeMode.GetActiveKeystoneInfo()
    end)
    ns.Recorder.onChallengeStart(name, instID, cmID, level, affixes)
  end,
  CHALLENGE_MODE_END = function()
    if not ns.Recorder.active() then return end
    local instID = select(8, GetInstanceInfo())
    ns.Recorder.onChallengeEnd(instID, true, nil, nil)
  end,
}

-- ── slash ─────────────────────────────────────────────────────────────────────
SLASH_REBUFFED1 = "/rb"
SLASH_REBUFFED2 = "/rebuffed"
SlashCmdList.REBUFFED = function(arg)
  arg = (arg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if arg == "" or arg == "show" or arg == "open" then
    if ns.UI then ns.UI.Toggle() else ns.msg("UI not loaded") end
  elseif arg == "rec" or arg == "recording" then
    if ns.UI then ns.UI.Open("Recording") end
  -- NOTE: /rb loot · /rb ready · /rb crew (raid-lead tools) are DEFERRED — see addon/Rebuffed/future/.
  elseif arg == "export" or arg == "end" then
    if ns.Recorder.active() then
      ns.Recorder.stop("manual export")
      ns.msg("now |cffffffff/reload|r (or log out) to hand the session to the uploader")
    else ns.msg("no active session") end
  elseif arg == "status" then
    local sess = ns.Recorder.active()
    local aclOn, combatOn = ns.Logging.state()
    if sess then
      ns.msg(("|cff46b36b● recording|r · %s (%s) · session %s · %d landmarks · logging acl=%s combat=%s")
        :format(sess.instance.name or "?", sess.kind or "?", sess.id, #sess.segments,
                aclOn and "|cff46b36bon|r" or "|cffe25a5aOFF|r",
                combatOn and "|cff46b36bon|r" or "|cffe25a5aOFF|r"))
    else
      ns.msg(("idle · advanced logging %s · combat logging %s")
        :format(aclOn and "|cff46b36bon|r" or "|cffe25a5aoff|r",
                combatOn and "|cff46b36bon|r" or "|cffe25a5aoff|r"))
    end
    local n = 0
    for _ in pairs(ns.DB.sessions) do n = n + 1 end
    ns.msg(("client: %s · %d session(s) stored — flushed to disk on /reload or logout"):format(ns.flavor, n))
  elseif arg == "debug" or arg:match("^debug ") then
    if ns.Debug then ns.Debug.command((arg:gsub("^debug%s*", ""))) else ns.msg("debug module not loaded") end
  elseif arg == "wipe" then
    ns.DB.sessions = {}; ns.DB.active = nil
    ns.msg("stored sessions wiped")
  else
    ns.msg("commands: /rb (open) · /rb status · /rb debug · /rb export · /rb wipe")
  end
end

-- ── boot ───────────────────────────────────────────────────────────────────────
f:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" and ... == ADDON then
    RebuffedDB = RebuffedDB or {}
    local db = RebuffedDB
    db.sessions = db.sessions or {}
    db.runs = db.runs or {}                   -- saved party/raid runs (Runs.lua)
    db.loot = db.loot or {}                   -- loot state (Loot.lua)
    db.loot.history = db.loot.history or {}   -- award history
    db.loot.reserves = db.loot.reserves or {} -- [itemId] = { {player, class}, ... } (imported SR)
    db.settings = db.settings or {}           -- cosmetic/UI prefs only — never gates core recording
    db.consent = nil                          -- removed: core recording is unconditional
    ns.DB = db
    -- crash recovery: an 'active' session on load means we died mid-run; finalize it so it uploads.
    if db.active and db.sessions[db.active] then
      local orphan = db.sessions[db.active]
      orphan.endedEpoch = orphan.endedEpoch or GetServerTime()
      orphan.recovered = true
      db.active = nil
      ns.msg("recovered an interrupted session (" .. orphan.id .. ") — it will upload normally")
    end
  elseif event == "PLAYER_ENTERING_WORLD" then
    ns.Logging.startGuardian() -- always-on logging everywhere, from the moment we log in
    if not ns.DB.settings.welcomed then
      ns.DB.settings.welcomed = true
      C_Timer.After(4, function()
        ns.msg("installed — combat logging & recording are |cff46b36bon automatically|r, everywhere. Open the panel with |cffffffff/rb|r.")
      end)
    end
    checkContext()
  elseif event == "ZONE_CHANGED_NEW_AREA" then
    ns.Logging.enforce() -- zoning can drop combat logging; re-assert immediately
    ns.Recorder.onZone()
    checkContext()
  elseif event == "GROUP_ROSTER_UPDATE" then
    if ns.UI then ns.UI.onRosterUpdate() end
  elseif event == "PLAYER_LOGOUT" then
    if ns.Recorder.active() then ns.Recorder.stop("logout") end
  elseif handlers[event] then
    handlers[event](...)
  end
end)

-- Register events. Midnight-only events (Mythic+ challenge mode) are only registered where they
-- exist — RegisterEvent on an unknown event errors on Classic.
local events = {
  "ADDON_LOADED", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "PLAYER_LOGOUT",
  "GROUP_ROSTER_UPDATE",
  "ENCOUNTER_START", "ENCOUNTER_END", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
  "PLAYER_LEVEL_UP", "PLAYER_DEAD",
}
if ns.hasChallengeMode then
  events[#events + 1] = "CHALLENGE_MODE_START"
  events[#events + 1] = "CHALLENGE_MODE_END"
end
for _, ev in ipairs(events) do f:RegisterEvent(ev) end

-- Rebuffed · Segments.lua — the fight/leveling landmark index.
--
-- The recorder does NOT reconstruct the combat stream (the file already has it, in higher fidelity
-- than any addon could see under Secret Values). It records only what the file CANNOT carry, plus
-- the shared LANDMARK events that let the uploader line the two up exactly.
--
-- Two session kinds now (recording is always on, everywhere):
--   • "instance" — raid / dungeon: encounter, challenge-mode, zone AND per-pull combat edges + meter.
--   • "world"    — open-world leveling: sparse landmarks only (level-ups, deaths, zone changes). No
--                  per-pull combat edges (leveling is thousands of small pulls). This is what turns
--                  a SoD leveling night into vertical-2 metadata alongside the always-on log file.
--
-- Landmark alignment: ENCOUNTER_START/END, CHALLENGE_MODE_START/END and ZONE changes fire as
-- ordinary, non-secret events AND are engine-written into WoWCombatLog.txt with identical identity,
-- so the uploader matches our landmark sequence to the file's 1:1 and inherits its exact timestamps.
--
-- Rows are pre-formatted packed strings (cheap memory, fast SavedVariables serialize):
--   "seq|epoch|mono|KIND|payload"   epoch = GetServerTime() (wall clock) · mono = GetTime() (monotonic)

local ADDON, ns = ...
local R = {}
ns.Recorder = R

local ROW_CAP = 20000 -- generous: a landmark index is thousands of rows, not millions

local S = { session = nil, seq = 0 }
R.state = S

local function hex16() return string.format("%04x", math.random(0, 65535)) end
local function newId() return date("%y%m%d%H%M%S") .. "-" .. hex16() end

-- ── roster snapshot (labels only — gear/spec/talents come from the file's COMBATANT_INFO) ──
local function snapshotRoster()
  local out, n = {}, GetNumGroupMembers()
  if IsInRaid() then
    for i = 1, n do
      local name, _, subgroup, _, _, classFile, _, online, _, _, _, role = GetRaidRosterInfo(i)
      if name then
        local short, realm = strsplit("-", name)
        out[#out + 1] = { name = short, realm = realm, class = classFile,
                          subgroup = subgroup, role = role, online = online and true or false }
      end
    end
  else
    local units = { "player" }
    for i = 1, n - 1 do units[#units + 1] = "party" .. i end
    for _, u in ipairs(units) do
      if UnitExists(u) then
        local short, realm = UnitNameUnmodified(u)
        out[#out + 1] = { name = short, realm = realm,
                          class = select(2, UnitClass(u)),
                          role = UnitGroupRolesAssigned(u) }
      end
    end
  end
  return out
end

-- ── row append ──────────────────────────────────────────────────────────────
local function row(kind, payload)
  local sess = S.session
  if not sess then return end
  local n = #sess.segments
  if n >= ROW_CAP then
    if n == ROW_CAP then ns.msg("|cffe25a5arow cap reached — segment index frozen for this session|r") end
    return
  end
  S.seq = S.seq + 1
  sess.segments[n + 1] = string.format("%d|%d|%.3f|%s|%s", S.seq, GetServerTime(), GetTime(), kind, payload or "")
end
R.row = row

local function playerLevel()
  return (UnitLevel and UnitLevel("player")) or 0
end

-- ── session lifecycle ────────────────────────────────────────────────────────
function R.start(kind)
  if S.session then return end
  kind = kind or "instance"
  local name, itype, diffID, diffName, _, _, _, instID = GetInstanceInfo()
  local isRaid = itype == "raid"
  if kind == "world" then
    name, itype, isRaid, instID, diffID, diffName = (GetRealZoneText() or "World"), "world", false, 0, 0, ""
  end
  local sess = {
    id = newId(), schema = 3, kind = kind,
    startedEpoch = GetServerTime(), startedMono = GetTime(),
    build = select(4, GetBuildInfo()), project = WOW_PROJECT_ID, flavor = ns.flavor, addonVersion = ns.VERSION,
    player = UnitNameUnmodified("player"), realm = GetRealmName(),
    guild = (GetGuildInfo("player")) or "", class = select(2, UnitClass("player")),
    level = playerLevel(),
    instance = { name = name, type = itype, difficultyID = diffID, difficultyName = diffName,
                 instanceID = instID, isRaid = isRaid },
    roster = snapshotRoster(),
    logging = ns.Logging.snapshot(),
    pulls = {},      -- [encounterID] = attempts so far tonight (the file cannot give you this)
    segments = {},   -- the ordered landmark index
  }
  ns.DB.sessions[sess.id] = sess
  ns.DB.active = sess.id
  S.session, S.seq = sess, 0

  row("SESSION_START", string.format("%s|%s|%d|%s|%d|kind=%s",
    name or "?", itype or "?", instID or 0, diffName or "", isRaid and 1 or 0, kind))
  local aclOn, combatOn = ns.Logging.enforce()
  row("LOGGING", string.format("acl=%d|combat=%d", aclOn and 1 or 0, combatOn and 1 or 0))

  local where = (kind == "world") and (ns.GOLD .. "leveling — logging everywhere|r")
             or (isRaid and (ns.GOLD .. "raid — logging guaranteed|r") or (ns.CYAN .. "dungeon|r"))
  ns.msg(("recording %s%s|r · %ssession %s|r · %s"):format(ns.CYAN, name or "?", ns.CYAN, sess.id, where))
end

function R.stop(reason)
  local sess = S.session
  if not sess then return end
  row("SESSION_END", reason or "")
  sess.endedEpoch, sess.endedMono = GetServerTime(), GetTime()
  ns.DB.active = nil
  S.session = nil
  -- NB: we do NOT turn logging off here — logging is always-on (the guardian owns it).
  ns.msg(("session ended (%s) · %d landmarks · reaches the uploader on |cffffffff/reload|r or logout")
    :format(reason or "ended", #sess.segments))
end

function R.active() return S.session end

-- ── landmark handlers (all args are ordinary, non-secret event payloads) ──────
function R.onEncounterStart(encID, name, diffID, size)
  local sess = S.session; if not sess then return end
  sess.pulls[encID] = (sess.pulls[encID] or 0) + 1
  sess.roster = snapshotRoster() -- roster can drift across a night; refresh at each pull
  row("ENCOUNTER_START", string.format("%s|%s|%s|%s|pull=%d",
    encID or "", name or "", diffID or "", size or "", sess.pulls[encID]))
end

function R.onEncounterEnd(encID, name, diffID, size, success)
  local sess = S.session; if not sess then return end
  local pull = sess.pulls[encID] or 1
  row("ENCOUNTER_END", string.format("%s|%s|%s|%s|success=%s|pull=%d",
    encID or "", name or "", diffID or "", size or "", success and 1 or 0, pull))
  R.captureMeter(encID) -- mainline-only; no-ops on Classic (feature-detected)
end

function R.onChallengeStart(mapName, instID, cmID, level, affixes)
  if not S.session then return end
  local aff = type(affixes) == "table" and table.concat(affixes, ",") or tostring(affixes or "")
  row("CHALLENGE_START", string.format("%s|%s|%s|%s|%s", mapName or "", instID or "", cmID or "", level or "", aff))
end

function R.onChallengeEnd(instID, success, level, totalTime)
  if not S.session then return end
  row("CHALLENGE_END", string.format("%s|success=%s|%s|%s", instID or "", success and 1 or 0, level or "", totalTime or ""))
end

function R.onZone()
  if S.session then row("ZONE", (GetRealZoneText() or "?") .. "|" .. (select(8, GetInstanceInfo()) or 0)) end
end

-- combat edges frame trash between bosses — but ONLY in instances (open-world leveling is thousands
-- of tiny pulls; the file already carries that combat, so indexing every edge would be pure noise).
function R.onCombatStart() local s = S.session; if s and s.kind == "instance" then row("COMBAT_START", "") end end
function R.onCombatEnd()   local s = S.session; if s and s.kind == "instance" then row("COMBAT_END", "") end end

-- leveling landmarks — the heart of the "world" session (and useful in instances too).
function R.onLevelUp(level)
  local sess = S.session; if not sess then return end
  sess.level = level or playerLevel()
  row("LEVEL_UP", string.format("%s|%s", tostring(sess.level or ""), GetRealZoneText() or "?"))
end

function R.onDeath()
  if not S.session then return end
  row("DEATH", string.format("%s|lvl=%d", GetRealZoneText() or "?", playerLevel()))
end

-- called by the logging guardian when it had to repair a mid-session logging drop.
function R.noteLoggingRepair(acl, combat)
  if not S.session then return end
  row("LOGGING_REPAIR", string.format("acl=%d|combat=%d", acl and 1 or 0, combat and 1 or 0))
end

-- ── C_DamageMeter capture (mainline-only, feature-detected, Secret-Values-safe) ──
function R.captureMeter(encID)
  if not ns.hasDamageMeter then return end -- Classic/SoD have no C_DamageMeter
  local sess = S.session
  if not (sess and C_DamageMeter and C_DamageMeter.GetAvailableCombatSessions) then return end
  local ok, packed = pcall(function()
    local sessions = C_DamageMeter.GetAvailableCombatSessions()
    if not (sessions and #sessions > 0) then return nil end
    local latest = sessions[#sessions]
    local id = latest.sessionID or latest.id or latest
    local party = C_DamageMeter.GetPartyData and C_DamageMeter.GetPartyData(id)
    if not party then return nil end
    local parts = {}
    for _, p in ipairs(party) do
      local nm = p.name or p.unitName or "?"
      local dmg = p.damage or p.totalDamage or 0
      local heal = p.healing or p.totalHealing or 0
      parts[#parts + 1] = string.format("%s:%d:%d", nm, dmg, heal)
    end
    if #parts == 0 then return nil end
    return table.concat(parts, ";")
  end)
  if ok and packed then row("METER", string.format("enc=%s|%s", encID or "", packed)) end
end

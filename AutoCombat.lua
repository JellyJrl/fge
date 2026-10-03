--[[
    Auto Combat - dungeon follow / dodge / abilities

    Layout (top to bottom):
      Config    every tunable, grouped by what it affects
      Tuned     the few values the bot adjusts on its own at runtime
      State     flags shared between modules
      Store     learned-data persistence (executor file API; optional)
      Learn     ranges and safety margins learned from hits and deaths
      Enemies   npc cache, groups, target lock
      Zones     attack detection (precast / hitbox / orb / model) and every "is this spot dangerous" query
      Walls     raycasts against the map
      Steer     choosing where to stand
      Move      movement, facing and the path walker
      Skills    ability detection and casting
      Record    manual recording + background hit confirmation
      ESP / UI  visuals and the control window
      Bot       the per-frame decision loop and startup

    Everything lives in a handful of module tables, so the script stays well under Luau's
    local-variable limit. Config keys keep the names they always had.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local clock = os.clock

-- Executor file API. All optional: without it, learning only lasts for the current session.
local fs = {
    write = writefile, read = readfile, isfile = isfile, isfolder = isfolder,
    makefolder = makefolder, list = listfiles, delete = delfile,
}

-- Running the script twice must not leave two bots fighting each other: stop the old one first.
local env = (type(getgenv) == "function" and getgenv()) or _G
local function setHandle(handle)
    pcall(function() env.__AutoCombat = handle end)   -- never let bookkeeping stop the bot from starting
end
if env.__AutoCombat and env.__AutoCombat.stop then
    pcall(env.__AutoCombat.stop)
end

-- =====================
-- CONFIG
-- =====================
local Config = {
    BOOT_DELAY              = 10,    -- seconds to let the game finish its own setup before we touch anything

    -- ---- distances (studs) ----
    MIN_DISTANCE            = 6,     -- SAFETY ONLY: never stand inside an npc's body. No forced standoff - it attacks as soon as it's in range
    ENGAGE_RANGE            = 80,    -- closer than this to an npc = steer locally; further = pathfind
    GROUP_LINK_DISTANCE     = 20,    -- npcs within this of each other are the same group
    TARGET_SWITCH_MARGIN    = 2,     -- another npc must be this much closer before the lock switches
    FLANK_RANGE             = 60,
    ENEMY_BODY_RADIUS       = 4,     -- a normal npc is about this wide; only size BEYOND this counts as extra (big bosses)
    RANGE_MARGIN            = 6,     -- stand this many studs inside the attack range (measured to the npc's centre)
    BIG_BODY_GAP            = 12,    -- ...but never closer than this to the edge of a big body

    -- ---- loop timing ----
    REPATH_RATE             = 0.4,
    STEER_RATE              = 0.12,
    STUCK_THRESHOLD         = 2.5,
    STUCK_MOVE_MIN          = 0.4,
    WAYPOINT_REACHED        = 3.5,
    WAYPOINT_TIMEOUT        = 1.5,

    -- ---- dodging ----
    DODGE_PADDING           = 2,
    PRECAST_DELAY           = 2.0,   -- precast telegraph lasts ~2s before the spell fires
    PRECAST_SAFETY          = 0.3,   -- want to be out of a precast zone this long BEFORE it fires
    DEST_SAFETY_WINDOW      = 1.0,   -- a spot must be safe this far ahead to be a valid destination
    REACTION_TIME           = 0.15,  -- input / humanoid delay added to every travel-time estimate
    MOVE_PREDICT_MAX        = 1.2,   -- seconds ahead a MOVING attack part is extrapolated (sweeping beams etc.)

    -- ---- what counts as an attack ----
    ORB_NAME_HINT           = "battlemageorb",
    ORB_PADDING             = 3,     -- extra radius around an orb
    ORB_LOOKAHEAD           = 1.0,   -- seconds of orb travel treated as dangerous
    ORB_RECHECK_WINDOW      = 3,     -- an orb's Mist/Trail can appear after the part: re-check top-level parts this long
    WORKSPACE_ROOT_AS_ATTACK = false, -- off: only parts named 'precast'/'hitbox', npc-named parts and orbs count
    MODEL_AS_ATTACK         = true,  -- a whole Model dropped straight into workspace counts as an attack too
    GENERIC_MAX_AGE         = 6,     -- a model like that still around after this long is scenery - stop treating it as danger
    -- HARD ignore list, as normalized names (lowercase letters/digits). Anything whose name CONTAINS one of these, or
    -- that sits inside something that does, is invisible to the bot: never an attack zone (no dodging), never drawn
    -- by the ESP, never counted in the UI, never learned from, never a wall for the raycasts. Nothing overrides it,
    -- not even a name that was learned from a death.
    IGNORE_NAMES            = { "groundaura" },
    HITBOX_OWNER_MAX_DIST   = 50,    -- fallback proximity radius when an attack's name doesn't reveal its npc
    HITBOX_OWNER_TIMEOUT    = 2,     -- after this long without a duration, fall back to watching the hitbox itself
    HITBOX_WATCH_ENABLED    = true,  -- watch hitboxes for "active" flags / lifetimes / fading to know when they end
    OWNER_LOOKUP_MAX_AGE    = 0.05,  -- how stale the npc cache may be when matching a brand-new attack to its caster
    OWN_SPAWN_RADIUS        = 12,    -- orb first seen this close to us = ours
    OWN_PROJECTILE_RADIUS_FIRING = 30, -- ...or this close, shortly after we used an ability
    OWN_PROJECTILE_WINDOW   = 3,

    -- ---- barriers (some bosses can't be approached) ----
    BARRIER_STUCK_TIME      = 6,     -- not moving for this long WHILE ACTIVELY TRYING TO WALK = something blocks us
    BARRIER_NOPROGRESS_TIME = 16,    -- walking but not getting any closer for this long = same
    BARRIER_PROGRESS_EPS    = 2,     -- must get this much closer to count as progress
    BARRIER_LEEWAY          = 15,    -- anywhere within this many studs of where we got stuck counts as "at the barrier"
    BARRIER_REQUIRE_WALL    = true,  -- only declare a barrier if a raycast actually finds something solid in the way
    BARRIER_WALL_MAX_DIST   = 25,    -- the obstruction must be within this many studs of us
    BARRIER_RANGE_CAP       = 40,    -- a barrier never stretches the attack range more than this past the range
    BARRIER_RETRY_SECONDS   = 30,    -- forget the barrier after this long and try to get closer again (0 = never)
    RANGE_TEST_SHOTS        = 2,     -- test casts from a barrier before deciding whether the skill reaches
    RANGE_TEST_WAIT         = 1.5,   -- seconds after firing to check whether health dropped
    RANGE_TEST_MIN_DROP     = 1,

    -- ---- tight arenas ----
    POCKET_STEP             = 1.5,   -- grid spacing when hunting for small safe gaps
    POCKET_MAX_REACH        = 30,
    POCKET_PADDINGS         = { 2, 1, 0.5 },   -- roomy margin first, then squeezing into tighter gaps
    POCKET_CHECKS           = 40,    -- how many best-looking gaps get the (expensive) wall/route test

    -- ---- cooldown staging ----
    WAIT_FOR_COOLDOWNS      = false, -- true = back off to WAIT_RANGE studs while skills cool down (slow!)
    WAIT_RANGE              = 100,
    WAIT_MARGIN             = 8,
    WAIT_MAX_SECONDS        = 90,
    WAIT_FOR_BARRAGE        = true,
    WAIT_FOR_RAGE           = true,
    WAIT_CLEARANCE          = 6,

    -- ---- casting ----
    CAST_ONLY_WHEN_SAFE     = false, -- true = only cast when not being attacked. false = cast the moment a skill is ready and an npc is in range
    CAST_MIN_CLEARANCE      = 2,
    CAST_THREAT_RADIUS      = 14,
    HOLD_BARRAGE_FOR_RAGE   = false,
    BARRAGE_REQUIRE_LOS     = false,
    BARRAGE_RANGE           = 90,    -- starting attack range; confirmed hits raise it, misses lower it
    -- Every npc has an `aggroRange` (a NumberValue / attribute on the npc). It only reacts - precasts, attacks - to
    -- someone inside it, so casting from outside makes it do nothing. With this on, skills are only used (and the
    -- bot only stands) inside min(attack range, aggroRange - AGGRO_MARGIN). Npcs without one use the attack range.
    USE_AGGRO_RANGE         = true,
    AGGRO_MARGIN            = 3,     -- stay this many studs inside the aggro range, so we're clearly in it
    AIM_SETTLE              = 0.1,   -- wait after lining up so the rotation reaches the server
    AIM_HOLD                = 0.3,   -- total time you stay facing them after firing
    CAST_CONFIRM_WAIT       = 0.15,  -- after firing, wait this long and check the cooldown actually started
    FAIL_RETRY_DELAY        = 3,
    COOLDOWN_READY_MAX      = 0,     -- ready when the tool's `cooldown` value is <= this (ready = -0.1)
    FALLBACK_COOLDOWN       = 8,
    ABILITY_MIN_GAP         = 0.8,
    EQUIP_DELAY             = 0.12,
    -- these 4 names (case/punctuation-insensitive) are buff skills used reactively; every other tool with a
    -- cooldown is an attack skill, and the one with the longest cooldownLength is the one tracked
    BUFF_SKILL_NAMES        = { "innerrage", "enhancedinnerrage", "innerfocus", "enhancedinnerfocus" },

    -- ---- spawn shield + Inner Rage ----
    SPAWN_SHIELD            = true,  -- after respawning you're briefly immortal: ignore attacks and go all-in
    SPAWN_SHIELD_SECONDS    = 5,
    SPAWN_SHIELD_SAFETY     = 0.3,
    RAGE_FOR_DODGING        = true,
    RAGE_DODGE_SLACK        = 0.35,
    RAGE_DODGE_MANY         = 3,
    RAGE_PRESSURE_RADIUS    = 20,
    RAGE_DURATION           = 3,     -- length of the buff until learned from the game's own cooldown numbers
    RAGE_SPEED_MULT         = 1.4,   -- ASSUMED speed multiplier while raging
    RAGE_TRAVEL_MIN_SAVED   = 2.5,
    RAGE_TRAVEL_MAX_LOSS    = 6,
    RAGE_TO_ATTACK_DELAY    = 0.15,
    RAGE_WAIT_MAX           = 4,

    -- ---- facing ----
    AUTO_AIM                = true,  -- always face the npcs (shift-lock style), even while walking or dodging

    -- ---- steering search ----
    SEARCH_RADII            = { 4, 8, 13, 19, 26, 34 },
    SEARCH_ANGLE_STEP       = 20,
    MAX_WALL_CHECKS         = 80,
    CLEAR_SPOTS_WANTED      = 8,
    W_FLANK                 = 4.0,   -- mild penalty for standing directly in front of npcs
    W_TRAVEL                = 0.15,
    W_STICKY                = 4.0,
    W_CROWD                 = 0.5,
    W_WALL                  = 6.0,   -- penalty for spots hugging walls
    WALL_CLEARANCE          = 5,
    WALL_MARGIN             = 2,     -- extra studs of clearance beyond a destination

    -- ---- visuals ----
    ESP_DEFAULT             = true,  -- the UI ESP button controls ALL esp (attacks, npcs, walls, paths)
    SHOW_WALLS              = true,
    ESP_LABELS              = true,
    ESP_SAFETY_DISCS        = true,
    MAP_ALL_AS_WALLS        = true,  -- every part inside workspace.map is something to avoid, solid or not
    UI_SCALE                = 1,

    -- ---- recording / learning ----
    RECORD_SAMPLE_RATE      = 0.2,
    RECORD_HIT_WINDOW       = 1.5,   -- seconds after a cast to watch for a health drop
    RECORD_MIN_DROP         = 1,
    RECORD_MAX_SAMPLES      = 9000,
    RECORD_NEARBY_NPCS      = 8,
    RECORD_NEARBY_ATKS      = 8,
    RECORD_MAX_EVENTS       = 2000,
    RECORD_NPC_MOVE_MIN     = 5,
    UNCLASSIFIED_MAX_AGE    = 12,    -- stop remembering an unrecognised object this old; it's not what just killed us
    DEATH_ATTACK_SEARCH_RADIUS = 20,
    DEATH_LEARN_WINDOW      = 10,
    DEATH_LEARN_THRESHOLD   = 3,
    DEATH_PRECAST_BUMP      = 0.1,
    DEATH_HITBOX_BUMP       = 0.1,
    DEATH_PRECAST_CAP       = 1.2,
    DEATH_HITBOX_CAP        = 3.0,
    DEATH_MAX_STORED        = 200,
    KNOWN_DUNGEON_NAMES     = { "Northern Lands", "Enchanted Forest" },
    RECORDS_ROOT            = "AutoCombatRuns",
    LEARN_VERSION           = 2,     -- bumped when saved data from older versions can't be trusted (see Learn.applyAll)
}
Config.IDEAL_DISTANCE = Config.MIN_DISTANCE + 4

-- The few numbers the bot changes by itself while running.
local Tuned = {}
function Tuned.reset()
    Tuned.barrageRange = Config.BARRAGE_RANGE
    Tuned.precastSafety = Config.PRECAST_SAFETY
    Tuned.destSafetyWindow = Config.DEST_SAFETY_WINDOW
end
Tuned.reset()

-- =====================
-- SHARED STATE + MODULE TABLES
-- =====================
local State = {
    enabled = true,
    wasEnabled = true,
    espEnabled = Config.ESP_DEFAULT,
    aimEnabled = Config.AUTO_AIM,
    mode = "IDLE",
    character = nil, humanoid = nil, hrp = nil,
    wasAlive = true,
    shieldUntil = 0,
    filterDirty = false,
    stats = { nearestDist = math.huge, group = nil, groupCount = 0, wallAhead = false },
}

local Store, Learn, Enemies, Zones, Walls, Steer, Move, Skills, Record, ESP, UI, Bot =
    {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}

-- =====================
-- UTILITIES
-- =====================
local function flat(v)
    return Vector3.new(v.X, 0, v.Z)
end

-- One normalizer for every name comparison (attacks, npcs, skills, learned names).
local function normalize(name)
    return (tostring(name or ""):lower():gsub("[^%w]", ""))
end

-- A numeric value off any Instance: a NumberValue child (tool.cooldown, npc.attackSpeed) or an attribute.
local function readNumber(inst, name)
    local obj = inst:FindFirstChild(name)
    if obj and obj:IsA("ValueBase") then
        local v = obj.Value
        if type(v) == "number" then return v end
    end
    local attr = inst:GetAttribute(name)
    if type(attr) == "number" then return attr end
    return nil
end

local function destroy(inst)
    if inst and inst.Parent then
        pcall(function() inst:Destroy() end)
    end
end

-- Long-lived connections are tracked so Bot.stop() can drop all of them.
local connections = {}
local function track(conn)
    table.insert(connections, conn)
    return conn
end

-- Tools live in Backpack (or Character while equipped).
local function findTool(name)
    local bp = player:FindFirstChild("Backpack")
    local tool = bp and bp:FindFirstChild(name)
    if tool then return tool end
    return player.Character and player.Character:FindFirstChild(name) or nil
end

-- =====================
-- LOG + STATE HELPERS
-- =====================
local Log = { lines = {}, MAX = 5 }

function Log.add(msg)
    table.insert(Log.lines, 1, os.date("%M:%S") .. "  " .. msg)
    while #Log.lines > Log.MAX do
        table.remove(Log.lines)
    end
end

function State.setMode(newMode)
    if State.mode ~= newMode then
        State.mode = newMode
        Log.add("State: " .. newMode)
    end
end

-- true only while the character exists, its humanoid has health and its root part is in the world
function State.alive()
    return State.humanoid ~= nil and State.humanoid.Parent ~= nil and State.humanoid.Health > 0
        and State.hrp ~= nil and State.hrp.Parent ~= nil
end

-- =====================
-- STORE (persistence)
-- <root>/<dungeon or place id>/learned.json   - best confirmed ranges (manual + auto) and safety margins
-- <root>/<dungeon or place id>/manual/run_<time>.json - full manual recordings
-- Some games reuse one PlaceId for several dungeons picked from a menu, so recordings are split by the
-- dungeon named in the dungeon-select screen when that screen is visible (and by PlaceId otherwise).
-- =====================
Store.dungeonName = nil

function Store.detectDungeon()
    local ok, name = pcall(function()
        local list = player.PlayerGui.queueGui.chooseDungeon.backgroundFillLeft.ScrollingFrame
        for _, dname in ipairs(Config.KNOWN_DUNGEON_NAMES) do
            local frame = list:FindFirstChild(dname)
            if frame and frame.Visible then return dname end
        end
        return nil
    end)
    if ok and name then Store.dungeonName = name end
    return Store.dungeonName   -- the select screen may be gone already: use whatever we last saw this session
end

function Store.folder()
    local place = tostring(game.PlaceId)
    if place == "" or place == "0" then place = "unknown_place" end
    return Config.RECORDS_ROOT .. "/" .. (Store.detectDungeon() or place)
end

function Store.path()
    return Store.folder() .. "/learned.json"
end

function Store.ensureFolder(sub)
    if not (fs.isfolder and fs.makefolder) then return end
    local place = Store.folder()
    if not fs.isfolder(Config.RECORDS_ROOT) then fs.makefolder(Config.RECORDS_ROOT) end
    if not fs.isfolder(place) then fs.makefolder(place) end
    if sub and not fs.isfolder(place .. "/" .. sub) then fs.makefolder(place .. "/" .. sub) end
end

function Store.emptyBank()
    return { ranges = {}, byTarget = {} }
end

-- Whatever was learned in EARLIER sessions for this dungeon:
-- { manual = {ranges, byTarget}, auto = {ranges, byTarget}, safety = {...} }
function Store.load()
    local data = { manual = Store.emptyBank(), auto = Store.emptyBank(), safety = {} }
    if not (fs.read and fs.isfile) then return data end

    local ok, decoded = pcall(function()
        local path = Store.path()
        if not fs.isfile(path) then return nil end
        return HttpService:JSONDecode(fs.read(path))
    end)
    if not ok or type(decoded) ~= "table" then return data end

    for _, bankName in ipairs({ "manual", "auto" }) do
        local bank = type(decoded[bankName]) == "table" and decoded[bankName] or {}
        data[bankName] = {
            ranges = type(bank.ranges) == "table" and bank.ranges or {},
            byTarget = type(bank.byTarget) == "table" and bank.byTarget or {},
        }
    end
    data.safety = type(decoded.safety) == "table" and decoded.safety or {}
    return data
end

-- Read-modify-write of learned.json. `mutate(data)` returns true when it changed something.
function Store.update(label, mutate)
    if not fs.write then return false end
    local ok, err = pcall(function()
        local data = Store.load()
        if not mutate(data) then return end
        data.safety.learnVersion = Config.LEARN_VERSION   -- see Learn.applyAll: untrusted data is wiped once
        local json = HttpService:JSONEncode(data)
        Store.ensureFolder()
        fs.write(Store.path(), json)
    end)
    if not ok then
        Log.add("Couldn't save " .. label .. ": " .. tostring(err))
    end
    return ok
end

function Store.saveRun(data)
    if not fs.write then
        Log.add("Can't save the run to disk here (no writefile) - learned numbers still apply this session")
        return
    end
    local ok, err = pcall(function()
        local json = HttpService:JSONEncode(data)
        Store.ensureFolder("manual")
        local path = string.format("%s/manual/run_%d.json", Store.folder(), os.time())
        fs.write(path, json)
        Log.add("Saved full run to " .. path)
    end)
    if not ok then
        Log.add("Couldn't save the run: " .. tostring(err))
    end
end

-- =====================
-- LEARN
-- Two tracks feed the same live decisions:
--   MANUAL - you press Record and play by hand (full detail, saved under manual/)
--   AUTO   - runs quietly whenever the bot fights: it only confirms which casts actually land
-- Whichever confirms a longer range for an ability (and npc) wins, so the two combine.
-- =====================
Learn.attackNames = {}       -- normalized names that killed us before: always treated as attacks
Learn.ignoreNames = {}       -- normalized names confirmed harmless: never reconsidered
Learn.npcMinDist = {}        -- [npc name] = studs to keep from that npc's surface (only ever increases)
Learn.deathLog = {}
Learn.applied = {}           -- LIVE best-of-both ranges the bot fights with: [ability] = studs
Learn.appliedByTarget = {}   -- [ability][npc name] = studs
Learn.manual, Learn.manualByTarget = {}, {}   -- this manual recording session
Learn.auto, Learn.autoByTarget = {}, {}       -- bot self-play this session

-- On the hard ignore list (Config.IGNORE_NAMES)? Matches any name that contains an entry, after normalizing
-- ("Ground Aura", "GroundAura_2", "groundaura-big" all match). Memoized: the same few names repeat constantly.
Learn.hardIgnoreCache = {}
function Learn.isHardIgnoredName(name)
    local cached = Learn.hardIgnoreCache[name]
    if cached ~= nil then return cached end

    local key = normalize(name)
    local hit = false
    for _, ignore in ipairs(Config.IGNORE_NAMES) do
        if ignore ~= "" and key:find(ignore, 1, true) then
            hit = true
            break
        end
    end
    Learn.hardIgnoreCache[name] = hit
    return hit
end

-- A name is permanently or learned-safe: it never shows up in the danger system, the ESP or the UI.
function Learn.isIgnoredName(name)
    return Learn.isHardIgnoredName(name) or Learn.ignoreNames[name] == true
end

-- Keeps the largest confirmed distance ever seen: once something is confirmed to work, that stays true.
function Learn.mergeBank(bank, newRanges, newByTarget)
    local changed = false
    for name, dist in pairs(newRanges or {}) do
        if not bank.ranges[name] or dist > bank.ranges[name] then
            bank.ranges[name] = dist
            changed = true
        end
    end
    for ability, byName in pairs(newByTarget or {}) do
        bank.byTarget[ability] = bank.byTarget[ability] or {}
        for npcName, dist in pairs(byName) do
            if not bank.byTarget[ability][npcName] or dist > bank.byTarget[ability][npcName] then
                bank.byTarget[ability][npcName] = dist
                changed = true
            end
        end
    end
    return changed
end

function Learn.combine(data)
    local combined = Store.emptyBank()
    Learn.mergeBank(combined, data.manual.ranges, data.manual.byTarget)
    Learn.mergeBank(combined, data.auto.ranges, data.auto.byTarget)
    return combined
end

-- Applies a { ranges, byTarget } table to the LIVE bot: rangeFor() reads this, so it changes behaviour at once.
function Learn.applyRanges(bank)
    local name = Skills.attackName
    if not name then return end

    local r = bank.ranges[name]
    if r and r > (Learn.applied[name] or 0) then
        Learn.applied[name] = r
        if r > Tuned.barrageRange then Tuned.barrageRange = math.ceil(r) end
    end
    for npcName, dist in pairs(bank.byTarget[name] or {}) do
        Learn.appliedByTarget[name] = Learn.appliedByTarget[name] or {}
        if dist > (Learn.appliedByTarget[name][npcName] or 0) then
            Learn.appliedByTarget[name][npcName] = dist
        end
    end
end

local function addToSavedList(safety, listName, name)
    safety[listName] = safety[listName] or {}
    for _, nm in ipairs(safety[listName]) do
        if nm == name then return false end   -- already saved
    end
    table.insert(safety[listName], name)
    return true
end

local function removeFromSavedList(safety, listName, name)
    local removed = false
    for i = #(safety[listName] or {}), 1, -1 do
        if safety[listName][i] == name then
            table.remove(safety[listName], i)
            removed = true
        end
    end
    return removed
end

-- Everything saved from earlier sessions: ranges, safety margins, per-npc distances, names, death history.
function Learn.applyAll(data)
    Learn.applyRanges(Learn.combine(data))

    local s = data.safety or {}
    if s.precastSafety and s.precastSafety > Tuned.precastSafety then
        Tuned.precastSafety = s.precastSafety
    end
    if s.destSafetyWindow and s.destSafetyWindow > Tuned.destSafetyWindow then
        Tuned.destSafetyWindow = s.destSafetyWindow
    end
    for name, d in pairs(s.npcMinDist or {}) do
        Learn.npcMinDist[name] = math.max(Learn.npcMinDist[name] or 0, d)
    end
    -- the saved log is just the in-memory one from an earlier session; never append it twice
    if type(s.deathLog) == "table" and #Learn.deathLog == 0 then
        for _, entry in ipairs(s.deathLog) do
            if #Learn.deathLog < Config.DEATH_MAX_STORED then
                table.insert(Learn.deathLog, entry)
            end
        end
    end
    -- a hard-ignored name can never be an attack, even if an earlier session blamed it for a death: drop it here
    -- and from the saved file, so it doesn't come back
    local purged = {}
    for _, nm in ipairs(type(s.learnedAttackNames) == "table" and s.learnedAttackNames or {}) do
        if Learn.isHardIgnoredName(nm) then
            table.insert(purged, nm)
        else
            Learn.attackNames[nm] = true
        end
    end
    if #purged > 0 then
        Log.add(string.format("Dropped %d saved attack name(s) that are on the ignore list", #purged))
        Store.update("ignore-list cleanup", function(data)
            local changed = false
            for _, nm in ipairs(purged) do
                if removeFromSavedList(data.safety, "learnedAttackNames", nm) then changed = true end
            end
            return changed
        end)
    end
    -- "Harmless" names. Older versions of this script learned EVERY attack the bot dodged as harmless once it went
    -- away ("precast", "hitbox", orb names ...) and saved that, which silently switched detection off. Nothing
    -- saved without the current version stamp can be trusted, so it is wiped once; and even in a current file
    -- a name that announces itself as an attack is never accepted.
    local saved = type(s.learnedIgnoreNames) == "table" and s.learnedIgnoreNames or {}
    if (s.learnVersion or 1) < Config.LEARN_VERSION then
        if #saved > 0 then
            Log.add(string.format("Dropped %d saved 'harmless' name(s) from an older version - they could hide real attacks", #saved))
        end
        if next(s) ~= nil then
            Store.update("learned-data upgrade", function(file)
                file.safety.learnedIgnoreNames = {}
                return true   -- Store.update stamps the current version
            end)
        end
    else
        local dropped = 0
        for _, nm in ipairs(saved) do
            if Learn.looksHostileName(nm) then
                dropped = dropped + 1
            else
                Learn.ignoreNames[nm] = true
            end
        end
        if dropped > 0 then
            Log.add(string.format("Dropped %d saved 'harmless' name(s) that look like attacks", dropped))
            Store.update("harmless-name cleanup", function(file)
                local keep = {}
                for _, nm in ipairs(file.safety.learnedIgnoreNames or {}) do
                    if not Learn.looksHostileName(nm) then table.insert(keep, nm) end
                end
                file.safety.learnedIgnoreNames = keep
                return true
            end)
        end
    end
end

-- A name that announces itself as an attack (precast / hitbox / the orb name), by keyword alone.
function Learn.looksHostileName(name)
    local key = normalize(name)
    return key:find("precast", 1, true) ~= nil or key:find("hitbox", 1, true) ~= nil
        or key:find(Config.ORB_NAME_HINT, 1, true) ~= nil
end

-- A death is rare and important: persist immediately, no batching. A name that killed us is no longer "harmless".
function Learn.addAttackName(name)
    if Learn.attackNames[name] or Learn.isHardIgnoredName(name) then return end   -- the ignore list always wins
    Learn.attackNames[name] = true
    Learn.ignoreNames[name] = nil
    Store.update("learned attack name", function(data)
        local added = addToSavedList(data.safety, "learnedAttackNames", name)
        local removed = removeFromSavedList(data.safety, "learnedIgnoreNames", name)
        return added or removed
    end)
    Zones.resetScanWindow()   -- parts already in the world with this name must be re-examined now
end

function Learn.addIgnoreName(name)
    if Learn.ignoreNames[name] then return end
    Learn.ignoreNames[name] = true
    Store.update("learned ignore name", function(data)
        return addToSavedList(data.safety, "learnedIgnoreNames", name)
    end)
end

-- Persists the learned safety margins so they survive a rejoin (only values above the defaults).
function Learn.saveSafety()
    local saved = Store.update("safety margins", function(data)
        local s = data.safety
        local changed = false
        if Tuned.precastSafety > Config.PRECAST_SAFETY and (not s.precastSafety or Tuned.precastSafety > s.precastSafety) then
            s.precastSafety = Tuned.precastSafety
            changed = true
        end
        if Tuned.destSafetyWindow > Config.DEST_SAFETY_WINDOW and (not s.destSafetyWindow or Tuned.destSafetyWindow > s.destSafetyWindow) then
            s.destSafetyWindow = Tuned.destSafetyWindow
            changed = true
        end
        s.npcMinDist = s.npcMinDist or {}
        for name, d in pairs(Learn.npcMinDist) do
            if not s.npcMinDist[name] or d > s.npcMinDist[name] then
                s.npcMinDist[name] = d
                changed = true
            end
        end
        -- keep the last DEATH_MAX_STORED deaths so patterns survive a rejoin
        if #Learn.deathLog > 0 then
            local keep = {}
            for i = math.max(1, #Learn.deathLog - Config.DEATH_MAX_STORED + 1), #Learn.deathLog do
                table.insert(keep, Learn.deathLog[i])
            end
            s.deathLog = keep
            changed = true
        end
        return changed
    end)
    if saved and fs.write then Log.add("Saved learned safety margins") end
end

-- The range to use against a specific npc: its own confirmed distance if we have one, else the general
-- applied range, else the starting one.
function Learn.rangeFor(npcName)
    local name = Skills.attackName
    if not name then return Tuned.barrageRange end
    local byName = Learn.appliedByTarget[name]
    local specific = byName and npcName and byName[npcName] or 0
    return math.max(specific, Learn.applied[name] or 0, Tuned.barrageRange)
end

function Learn.effectiveMinDist(npcName)
    return math.max(Config.MIN_DISTANCE, Learn.npcMinDist[npcName] or 0)
end

-- Called the instant either track confirms a cast landed from `dist` studs.
function Learn.noteHit(ability, npcName, dist, viaBot)
    if Record.active then
        Learn.manual[ability] = math.max(Learn.manual[ability] or 0, dist)
        Learn.manualByTarget[ability] = Learn.manualByTarget[ability] or {}
        Learn.manualByTarget[ability][npcName] = math.max(Learn.manualByTarget[ability][npcName] or 0, dist)
    end

    if viaBot then
        local byTarget = Learn.autoByTarget[ability] or {}
        local improved = dist > (Learn.auto[ability] or 0) or dist > (byTarget[npcName] or 0)
        Learn.auto[ability] = math.max(Learn.auto[ability] or 0, dist)
        byTarget[npcName] = math.max(byTarget[npcName] or 0, dist)
        Learn.autoByTarget[ability] = byTarget
        -- only touch the disk when this actually beats what this session already confirmed
        if improved then
            Store.update("learned ranges", function(data)
                return Learn.mergeBank(data.auto, { [ability] = dist }, { [ability] = { [npcName] = dist } })
            end)
        end
    end

    Learn.applied[ability] = math.max(Learn.applied[ability] or 0, dist)
    Learn.appliedByTarget[ability] = Learn.appliedByTarget[ability] or {}
    Learn.appliedByTarget[ability][npcName] = math.max(Learn.appliedByTarget[ability][npcName] or 0, dist)
    if ability == Skills.attackName and dist > Tuned.barrageRange then
        Tuned.barrageRange = math.ceil(dist)
    end
end

-- Re-reads every saved manual run for THIS dungeon, merges the best of all of them and applies it now.
function Learn.importRuns()
    if not (fs.list and fs.read) then
        Log.add("Can't list saved runs here (no listfiles) - this environment can't import old runs")
        return
    end

    local ok, err = pcall(function()
        local folder = Store.folder() .. "/manual"
        local files = {}
        if not fs.isfolder or fs.isfolder(folder) then
            local listOk, listed = pcall(fs.list, folder)
            if listOk then files = listed end
        end

        local data = Store.load()
        local runCount, changed = 0, false

        for _, path in ipairs(files) do
            if tostring(path):match("run_%d+%.json$") then
                local decodeOk, run = pcall(function() return HttpService:JSONDecode(fs.read(path)) end)
                if decodeOk and type(run) == "table"
                    and (type(run.learnedRanges) == "table" or type(run.learnedRangesByTarget) == "table") then
                    runCount = runCount + 1
                    if Learn.mergeBank(data.manual, run.learnedRanges, run.learnedRangesByTarget) then
                        changed = true
                    end
                end
            end
        end

        if runCount == 0 then
            Log.add("No saved manual runs found for this dungeon to import")
            return
        end

        if changed then
            Store.ensureFolder()
            fs.write(Store.path(), HttpService:JSONEncode(data))
        end

        Learn.applyRanges(Learn.combine(data))
        for name, dist in pairs(data.manual.ranges) do
            if name == Skills.attackName then
                Log.add(string.format("Imported and applied: range = %d (from %d saved run(s))", Tuned.barrageRange, runCount))
            else
                Log.add(string.format("Imported: %s confirmed range %.0f studs (from %d saved run(s))", name, dist, runCount))
            end
        end
        for ability, byName in pairs(data.manual.byTarget) do
            for npcName, dist in pairs(byName) do
                Log.add(string.format("Imported: %s vs %s confirmed at %.0f studs", ability, npcName, dist))
            end
        end
    end)
    if not ok then
        Log.add("Couldn't import saved runs: " .. tostring(err))
    end
end

-- Deletes every saved manual run AND the learned settings for THIS DUNGEON ONLY, and resets this
-- session's learned numbers back to the config defaults.
function Learn.clearAll()
    for _, t in ipairs({ Learn.manual, Learn.manualByTarget, Learn.auto, Learn.autoByTarget, Learn.applied,
        Learn.appliedByTarget, Learn.deathLog, Learn.npcMinDist, Learn.attackNames, Learn.ignoreNames }) do
        table.clear(t)
    end
    Tuned.reset()

    if not fs.delete then
        Log.add("Cleared this session's learned data, but can't delete saved files here (no delfile)")
        return
    end

    local ok, err = pcall(function()
        local removed = 0
        local path = Store.path()
        if fs.isfile and fs.isfile(path) then
            fs.delete(path)
            removed = removed + 1
        end
        local manualFolder = Store.folder() .. "/manual"
        if fs.list and fs.isfolder and fs.isfolder(manualFolder) then
            for _, p in ipairs(fs.list(manualFolder)) do
                if tostring(p):match("run_%d+%.json$") then
                    fs.delete(p)
                    removed = removed + 1
                end
            end
        end
        Log.add(string.format("Cleared %d saved file(s) for this dungeon (manual + auto)", removed))
    end)
    if not ok then
        Log.add("Couldn't clear saved files: " .. tostring(err))
    end
end

-- =====================
-- DEATH LEARNING
-- Repeated deaths to the same kind of attack (or near the same npc) tighten the matching safety margin.
-- =====================
function Learn.recordDeath()
    local now = os.time()
    local pos = State.hrp and State.hrp.Position or Vector3.zero

    local nearestNpc, nearestNpcDist = nil, math.huge
    for _, e in ipairs(Enemies.list) do
        local d = flat(pos - e.pos).Magnitude
        if d < nearestNpcDist then nearestNpcDist, nearestNpc = d, e.model.Name end
    end

    local closestKind, closestDist = nil, math.huge
    for _, info in pairs(Zones.active) do
        local d = flat(pos - info.pos).Magnitude
        if d < closestDist then closestDist, closestKind = d, info.kind end
    end

    -- Nothing we were tracking was close enough to plausibly be what killed us: look for an unrecognised
    -- object nearby instead, and learn its name as an attack from now on.
    local unknownName = nil
    if closestDist > 10 then
        local suspect, suspectDist = Zones.findSuspect(pos)
        if suspect then
            unknownName = suspect
            if not Learn.attackNames[suspect] then
                Log.add(string.format("Died to something unrecognised: \"%s\" (%.0f studs away) - now treated as an attack", suspect, suspectDist))
                Learn.addAttackName(suspect)
            end
        end
    end

    if #Learn.deathLog >= Config.DEATH_MAX_STORED then table.remove(Learn.deathLog, 1) end
    table.insert(Learn.deathLog, {
        t = now,
        npc = nearestNpc,
        npcDist = (nearestNpcDist < math.huge) and math.floor(nearestNpcDist) or nil,
        attackKind = closestKind,
        attackDist = (closestDist < math.huge) and math.floor(closestDist) or nil,
        unknownAttackName = unknownName,
    })

    -- recent window: global attack-type patterns + per-npc counts
    local precastDeaths, hitboxDeaths, npcDeaths = 0, 0, {}
    for i = math.max(1, #Learn.deathLog - Config.DEATH_LEARN_WINDOW + 1), #Learn.deathLog do
        local d = Learn.deathLog[i]
        if d.attackKind == "precast" then precastDeaths = precastDeaths + 1 end
        if d.attackKind == "hitbox" or d.attackKind == "unknown" then hitboxDeaths = hitboxDeaths + 1 end
        if d.npc then npcDeaths[d.npc] = (npcDeaths[d.npc] or 0) + 1 end
    end

    local changed = false
    if precastDeaths >= Config.DEATH_LEARN_THRESHOLD then
        local new = math.min(Tuned.precastSafety + Config.DEATH_PRECAST_BUMP, Config.DEATH_PRECAST_CAP)
        if new > Tuned.precastSafety then
            Tuned.precastSafety = new
            Log.add(string.format("Learned from %d precast deaths: leaving earlier now (safety %.1fs)", precastDeaths, new))
            changed = true
        end
    end
    if hitboxDeaths >= Config.DEATH_LEARN_THRESHOLD then
        local new = math.min(Tuned.destSafetyWindow + Config.DEATH_HITBOX_BUMP, Config.DEATH_HITBOX_CAP)
        if new > Tuned.destSafetyWindow then
            Tuned.destSafetyWindow = new
            Log.add(string.format("Learned from %d hitbox deaths: wider avoidance window now (%.1fs)", hitboxDeaths, new))
            changed = true
        end
    end
    -- died near the same npc repeatedly: keep further from it (capped so we're never pushed out of range)
    for npcName, count in pairs(npcDeaths) do
        if count >= Config.DEATH_LEARN_THRESHOLD then
            local current = Learn.npcMinDist[npcName] or Config.MIN_DISTANCE
            local new = math.min(current + 3, 30)
            if new > current then
                Learn.npcMinDist[npcName] = new
                Log.add(string.format("Learned from %d deaths near %s: staying %d studs away", count, npcName, new))
                changed = true
            end
        end
    end

    if changed then Learn.saveSafety() end
end

-- =====================
-- ENEMIES: npc cache, groups, target lock
-- =====================
Enemies.list = {}      -- { {model, part, pos, radius, humanoid, attackDuration, aggroRange, key, gid} }, rebuilt by refresh()
Enemies.groups = {}    -- { {members, centroid, radius, count} }
Enemies.locked = nil   -- model of the npc we're locked onto
Enemies.lastRefresh = -math.huge
Enemies.infoCache = setmetatable({}, { __mode = "k" })   -- [model] = { part, radius, humanoid, key, t }
-- Precast timing handed to the hitbox that follows it. Keyed by npc MODEL: the cache entries in `list`
-- are rebuilt constantly, so anything stored on them would be gone before the hitbox appears.
Enemies.pending = setmetatable({}, { __mode = "k" })
Enemies.ROOT_NAMES = { "HumanoidRootPart", "Root", "RootPart" }

-- workspace.dungeon may not exist yet (lobby, loading, between runs): look it up every time instead of hanging
function Enemies.rooms()
    local d = workspace:FindFirstChild("dungeon")
    return d and d:GetChildren() or {}
end

-- Finds a part to track. Bosses (e.g. the Enchanted Forest Dragon) often have no HumanoidRootPart/Root.
function Enemies.findRoot(model)
    for _, name in ipairs(Enemies.ROOT_NAMES) do
        local p = model:FindFirstChild(name)
        if p and p:IsA("BasePart") then return p end
    end
    if model.PrimaryPart then return model.PrimaryPart end

    for _, name in ipairs({ "Torso", "UpperTorso", "LowerTorso", "Head" }) do
        local p = model:FindFirstChild(name)
        if p and p:IsA("BasePart") then return p end
    end

    -- last resort: the biggest part in the model
    local best, bestVolume = nil, 0
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") then
            local v = d.Size.X * d.Size.Y * d.Size.Z
            if v > bestVolume then best, bestVolume = d, v end
        end
    end
    return best
end

-- Geometry is cached for about a second so huge models aren't measured every frame; attackSpeed is cheap and
-- re-read every time (a value added moments before an npc's first attack must not stay invisible for a second).
function Enemies.info(model, now)
    local info = Enemies.infoCache[model]
    if info and info.part.Parent and now - info.t < 1 then
        info.attackDuration = readNumber(model, "attackSpeed")
        info.aggroRange = readNumber(model, "aggroRange")
        return info
    end

    local part = (info and info.part.Parent) and info.part or Enemies.findRoot(model)
    if not part then return nil end

    local size = model:GetExtentsSize()
    local radius = math.max(0, math.max(size.X, size.Z) / 2 - Config.ENEMY_BODY_RADIUS)
    -- a huge model must not push the keep-away distance beyond where our skills can reach it
    radius = math.min(radius, math.max(0, Tuned.barrageRange - Config.RANGE_MARGIN - Config.MIN_DISTANCE))

    info = {
        part = part, radius = radius, t = now,
        humanoid = model:FindFirstChildOfClass("Humanoid"),
        key = normalize(model.Name),
        attackDuration = readNumber(model, "attackSpeed"),   -- how long its attack sequence lasts, when the npc says
        aggroRange = readNumber(model, "aggroRange"),        -- how close you must be before it reacts, when the npc says
    }
    Enemies.infoCache[model] = info
    return info
end

-- Rebuilds the list unless it is younger than `maxAge`. A NEW table every time, so a loop that is halfway
-- through the old list is never disturbed.
function Enemies.refresh(maxAge)
    local now = clock()
    if now - Enemies.lastRefresh < (maxAge or 0) then return end
    Enemies.lastRefresh = now

    local list = {}
    for _, room in ipairs(Enemies.rooms()) do
        local folder = room:FindFirstChild("enemyFolder")
        if folder then
            for _, enemy in ipairs(folder:GetChildren()) do
                if enemy:IsA("Model") then
                    local info = Enemies.info(enemy, now)
                    if info then
                        table.insert(list, {
                            model = enemy, part = info.part, pos = info.part.Position,
                            radius = info.radius,   -- extra body size; distances are measured to the surface
                            humanoid = info.humanoid, key = info.key,
                            attackDuration = info.attackDuration, aggroRange = info.aggroRange,
                        })
                    end
                end
            end
        end
    end
    Enemies.list = list
end

-- How far from this npc (measured to its centre, like skills and aggro are) we may use skills: the learned or
-- starting attack range, and - when the npc has an aggroRange - no further than just inside it. An npc only
-- reacts (precasts, attacks) to someone inside its aggro range, so casting from outside it gives nothing to fight.
-- Returns the range and whether the aggro range is what limits it.
function Enemies.castRange(entry)
    local range = Learn.rangeFor(entry and entry.model.Name)
    local aggro = entry and entry.aggroRange
    if Config.USE_AGGRO_RANGE and aggro and aggro > 0 then
        local inside = math.max(aggro - Config.AGGRO_MARGIN, Config.MIN_DISTANCE + 2)
        if inside < range then return inside, true end
    end
    return range, false
end

-- The strictest cast range of a group's members: standing inside it means every npc in the group is in reach.
function Enemies.groupCastRange(group)
    local range = nil
    for _, m in ipairs(group and group.members or {}) do
        local r = Enemies.castRange(m)
        if not range or r < range then range = r end
    end
    return range or Tuned.barrageRange
end

-- Distance to the nearest npc SURFACE (centre distance minus its extra body radius).
function Enemies.nearestFrom(pos)
    local best, bestDist = nil, math.huge
    for _, e in ipairs(Enemies.list) do
        local d = flat(pos - e.pos).Magnitude - (e.radius or 0)
        if d < bestDist then best, bestDist = e, d end
    end
    return best, bestDist
end

function Enemies.minDistance(pos)
    local _, d = Enemies.nearestFrom(pos)
    return d
end

-- Distance to the nearest npc's CENTRE. Skills reach by this, not by the body surface: a boss with a
-- massive body looks "close" by its edge but can still be far out of skill range.
function Enemies.nearestCenterDist(pos)
    local best, bestDist = nil, math.huge
    for _, e in ipairs(Enemies.list) do
        local d = flat(pos - e.pos).Magnitude
        if d < bestDist then best, bestDist = e, d end
    end
    return bestDist, best
end

-- Cluster npcs into groups: anyone within GROUP_LINK_DISTANCE of a group member joins it.
function Enemies.buildGroups()
    local groups = {}
    for _, e in ipairs(Enemies.list) do e.gid = nil end

    for _, seed in ipairs(Enemies.list) do
        if not seed.gid then
            local id = #groups + 1
            local members = { seed }
            seed.gid = id

            local i = 1
            while i <= #members do
                local cur = members[i]
                for _, other in ipairs(Enemies.list) do
                    if not other.gid and flat(other.pos - cur.pos).Magnitude - other.radius - cur.radius <= Config.GROUP_LINK_DISTANCE then
                        other.gid = id
                        table.insert(members, other)
                    end
                end
                i = i + 1
            end

            local sum = Vector3.zero
            for _, m in ipairs(members) do sum = sum + m.pos end
            local centroid = sum / #members

            local radius = 0
            for _, m in ipairs(members) do
                radius = math.max(radius, flat(m.pos - centroid).Magnitude + m.radius)
            end

            groups[id] = { members = members, centroid = centroid, radius = radius, count = #members }
        end
    end
    Enemies.groups = groups
end

-- Keep the current lock until another npc is clearly closer (ties never switch).
function Enemies.selectTarget(nearest, nearestDist)
    if not nearest then
        Enemies.locked = nil
        return nil
    end

    if Enemies.locked then
        for _, e in ipairs(Enemies.list) do
            if e.model == Enemies.locked then
                local d = flat(State.hrp.Position - e.pos).Magnitude - e.radius
                if d <= nearestDist + Config.TARGET_SWITCH_MARGIN then
                    return e
                end
                break
            end
        end
    end

    Enemies.locked = nearest.model
    return nearest
end

-- Games very often name an attack after its caster ("Northern Mage" -> "northernmageshot"). Matching by
-- name is far more reliable than by distance (a ranged attack can land anywhere; several npcs of one type
-- can stand close together), so it is tried FIRST wherever an attack needs to be matched to its caster.
-- Prefers the LONGEST matching npc name.
function Enemies.findOwnerByName(attackName)
    local normAttack = normalize(attackName)
    if normAttack == "" then return nil end

    -- This runs the instant an attack part appears, possibly before the per-frame scan ever ran or a frame
    -- stale: make sure a fresh npc isn't missed. An attack is only ever classified once.
    Enemies.refresh(Config.OWNER_LOOKUP_MAX_AGE)

    local best, bestLen = nil, 0
    for _, e in ipairs(Enemies.list) do
        if e.key ~= "" and #e.key > bestLen and normAttack:find(e.key, 1, true) then
            best, bestLen = e, #e.key
        end
    end
    return best
end

-- Name match first, proximity as a fallback for attacks whose names don't reveal the caster.
function Enemies.findAttackOwner(attackName, attackPos)
    local byName = Enemies.findOwnerByName(attackName)
    if byName then return byName end

    local nearest, nearestD = nil, math.huge
    for _, e in ipairs(Enemies.list) do
        local d = flat(attackPos - e.pos).Magnitude
        if d < nearestD then nearest, nearestD = e, d end
    end
    if nearest and nearestD <= Config.HITBOX_OWNER_MAX_DIST then return nearest end
    return nil
end

function Enemies.setPending(model, seqBorn, seqDuration, attackName)
    Enemies.pending[model] = { seqBorn = seqBorn, seqDuration = seqDuration, at = clock(), attackName = attackName }
end

-- The timing a precast left behind for the hitbox that follows it (consumed once, valid for 2s).
-- Prefers the npc whose name matches the hitbox, else the nearest npc that has a sequence pending.
function Enemies.takePending(attackName, pos, now)
    local owner = Enemies.findOwnerByName(attackName)
    local pending = owner and Enemies.pending[owner.model]

    if not pending then
        local nearest, nearestD = nil, math.huge
        for _, e in ipairs(Enemies.list) do
            if Enemies.pending[e.model] then
                local d = flat(pos - e.pos).Magnitude
                if d < nearestD then nearest, nearestD = e, d end
            end
        end
        if nearest and nearestD <= Config.HITBOX_OWNER_MAX_DIST then
            owner, pending = nearest, Enemies.pending[nearest.model]
        end
    end

    if pending and now - pending.at < 2.0 then
        Enemies.pending[owner.model] = nil
        return pending
    end
    return nil
end

-- =====================
-- ZONES: attack detection + every "is this spot dangerous" query
--   precast = telegraph, fires ~PRECAST_DELAY seconds after it appears
--   hitbox  = already active (may have a known duration)
--   orb     = moving part (battleMageOrb) detected by its Mist / Trail / Attachment
--   unknown = a loose Model (or part) dropped into workspace: a possible attack until proven scenery
-- Each zone's geometry (cf / size / pos) is read once per frame by update() and reused by every query.
-- =====================
Zones.COLORS = {
    precast = Color3.fromRGB(255, 170, 0),
    hitbox  = Color3.fromRGB(255, 40, 40),
    orb     = Color3.fromRGB(190, 60, 255),
    unknown = Color3.fromRGB(255, 90, 170),
}

Zones.active = {}      -- [part or model] = info
Zones.ignored = setmetatable({}, { __mode = "k" })    -- parts/models confirmed not to be attacks (our own projectiles, scenery)
Zones.expired = setmetatable({}, { __mode = "k" })    -- parts whose attack already ended but which still exist (see Zones.expire)
Zones.seen = setmetatable({}, { __mode = "k" })       -- [top-level part] = when the orb scan first examined it
Zones.suspects = setmetatable({}, { __mode = "k" })   -- [object] = { name, born, pos, damaged, attack }: what might have hurt us
Zones.hardIgnored = setmetatable({}, { __mode = "k" })   -- objects on the hard ignore list (or inside one): see isHardIgnored
Zones.lastScan = 0

Zones.DURATION_PATTERNS = { "lifetime", "duration", "attackspeed", "attackduration", "activetime", "hitduration", "lifespan" }
Zones.ACTIVE_PATTERNS = { "active", "isactive", "enabled", "alive" }
Zones.configValues = nil    -- index of duration-like values in ReplicatedStorage, built lazily
Zones.configBuiltAt = 0

-- ---- classification ----

-- Is this object on the hard ignore list (Config.IGNORE_NAMES, e.g. the ground aura), or inside something that is?
-- Such objects are invisible to the bot. Positive answers are remembered (and the object registered, so the wall
-- raycasts can exclude it); a negative one is re-checked every time, since names and parents can change.
function Zones.isHardIgnored(obj)
    if Zones.hardIgnored[obj] then return true end
    local cur = obj
    while cur and cur ~= workspace do
        if Learn.isHardIgnoredName(cur.Name) then
            Zones.hardIgnored[obj] = true
            return true
        end
        cur = cur.Parent
    end
    return false
end

function Zones.belongsToCharacter(obj)
    local cur = obj
    while cur and cur ~= workspace do
        if cur:IsA("Model") and Players:GetPlayerFromCharacter(cur) then return true end
        cur = cur.Parent
    end
    return false
end

-- an attack spawned right after we used an ability, close to us, is ours
function Zones.nearOwnCast(pos)
    return clock() < Skills.ownFireUntil
        and flat(pos - State.hrp.Position).Magnitude <= Config.OWN_PROJECTILE_RADIUS_FIRING
end

function Zones.isOwnProjectile(obj)
    local d = flat(obj.Position - State.hrp.Position).Magnitude
    local r = (clock() < Skills.ownFireUntil) and Config.OWN_PROJECTILE_RADIUS_FIRING or Config.OWN_SPAWN_RADIUS
    return d <= r
end

-- battleMageOrb is a plain Part in workspace whose name can vary, so look INSIDE it for a mist, trail or attachment.
function Zones.looksLikeOrb(obj, name)
    if name:find(Config.ORB_NAME_HINT, 1, true) then return true end
    for _, d in ipairs(obj:GetDescendants()) do
        if d:IsA("Trail") or d:IsA("Attachment") or d.Name:lower():find("mist", 1, true) then
            return true
        end
    end
    return false
end

function Zones.rawKind(obj)
    local name = normalize(obj.Name)

    -- a name that hurt us before is always an attack - but never one on the hard ignore list (checked in classify)
    if Learn.attackNames[name] then return "hitbox" end
    if Learn.isHardIgnoredName(name) then return nil end

    -- A name that says "precast" / "hitbox" is an attack, whatever was ever learned about it. Only then does a
    -- learned-harmless name apply (to things the bot merely GUESSED were attacks: orbs, npc-named parts ...).
    if name:find("precast", 1, true) then return "precast" end
    if name:find("hitbox", 1, true) then return "hitbox" end
    if Learn.ignoreNames[name] and not name:find(Config.ORB_NAME_HINT, 1, true) then return nil end

    if obj.Parent == workspace then
        -- A top-level part whose name contains a known npc's name ("northernmageshot" contains "northernmage")
        -- is almost certainly that npc's attack. Much more targeted than WORKSPACE_ROOT_AS_ATTACK.
        if Enemies.findOwnerByName(name) then
            if Zones.nearOwnCast(obj.Position) then
                Zones.ignored[obj] = true
                return nil
            end
            return "hitbox"   -- best guess from the name alone; the duration gets resolved right after
        end

        if Zones.looksLikeOrb(obj, name) then
            if Zones.isOwnProjectile(obj) then
                Zones.ignored[obj] = true
                return nil
            end
            return "orb"
        end

        -- The broader, less targeted fallback: anything else spawned straight into workspace is probably an
        -- attack (permanent scenery lives inside a container). Off by default.
        if Config.WORKSPACE_ROOT_AS_ATTACK then
            if Zones.nearOwnCast(obj.Position) then
                Zones.ignored[obj] = true
                return nil
            end
            return "unknown"
        end
    end
    return nil
end

function Zones.classify(obj)
    if not obj:IsA("BasePart") or obj.ClassName == "Terrain" or Zones.ignored[obj] then return nil end
    if Zones.isHardIgnored(obj) then
        Zones.ignored[obj] = true   -- decided once: later scans skip it without even looking
        return nil
    end
    local kind = Zones.rawKind(obj)
    if kind and Zones.belongsToCharacter(obj) then return nil end   -- never our body, nor another player's
    return kind
end

function Zones.orbRadius(part)
    return math.max(part.Size.X, part.Size.Y, part.Size.Z) / 2 + Config.ORB_PADDING
end

-- ---- duration discovery ----

local function findNumericChild(container, patterns)
    for _, child in ipairs(container:GetChildren()) do
        local lname = child.Name:lower()
        for _, pat in ipairs(patterns) do
            if lname:find(pat, 1, true) then
                local v = child:IsA("ValueBase") and child.Value or child:GetAttribute("Value")
                if type(v) == "number" and v > 0 then return v end
            end
        end
    end
    return nil
end

function Zones.buildConfigIndex()
    local list = {}
    for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
        if d:IsA("ValueBase") and d.Parent then
            local lname = d.Name:lower()
            for _, pat in ipairs(Zones.DURATION_PATTERNS) do
                if lname:find(pat, 1, true) then
                    table.insert(list, { value = d, owner = d.Parent.Name:lower() })
                    break
                end
            end
        end
    end
    Zones.configValues = list
    Zones.configBuiltAt = clock()
end

-- Looks for a numeric lifetime on the part, its model, or a ReplicatedStorage config belonging to this
-- attack (games sometimes keep ability configs centrally). nil if nothing useful was found.
function Zones.probeDuration(part)
    local v = findNumericChild(part, Zones.DURATION_PATTERNS)
    if v then return v end
    for _, attr in ipairs({ "lifetime", "duration", "attackDuration" }) do
        local a = part:GetAttribute(attr)
        if type(a) == "number" and a > 0 then return a end
    end

    local model = part.Parent
    local names = { part.Name:lower() }
    if model and model ~= workspace then
        v = findNumericChild(model, Zones.DURATION_PATTERNS)
        if v then return v end
        for _, child in ipairs(model:GetDescendants()) do
            if child:IsA("ValueBase") and type(child.Value) == "number" and child.Value > 0 then
                local lname = child.Name:lower()
                for _, pat in ipairs(Zones.DURATION_PATTERNS) do
                    if lname:find(pat, 1, true) then return child.Value end
                end
            end
        end
        table.insert(names, model.Name:lower())
    end

    if not Zones.configValues or clock() - Zones.configBuiltAt > 60 then
        pcall(Zones.buildConfigIndex)
    end
    for _, entry in ipairs(Zones.configValues or {}) do
        local value = entry.value
        if value.Parent and type(value.Value) == "number" and value.Value > 0 then
            for _, n in ipairs(names) do
                if n ~= "" and entry.owner:find(n, 1, true) then return value.Value end
            end
        end
    end
    return nil
end

-- Live monitoring on a hitbox part, so we notice the moment the GAME itself signals the attack is over:
--   * a BoolValue named "active/isActive/enabled" flipping to false
--   * a NumberValue named "lifetime/duration/..." draining to 0
--   * the part's Transparency reaching 1 (many games fade hitboxes out when they become safe)
--   * a script inside the part disabling itself (common for one-shot hitbox scripts)
function Zones.watchHitbox(part, info)
    if not Config.HITBOX_WATCH_ENABLED or info.watchersSet then return end
    info.watchersSet = true

    local function expire()
        if not info.attackDuration then
            info.attackDuration = clock() - info.born
            Zones.scheduleExpiry(part, info)
        end
    end

    for _, child in ipairs(part:GetDescendants()) do
        local lname = child.Name:lower()
        for _, pat in ipairs(Zones.ACTIVE_PATTERNS) do
            if lname:find(pat, 1, true) and child:IsA("BoolValue") then
                child:GetPropertyChangedSignal("Value"):Connect(function()
                    if not child.Value then expire() end
                end)
            end
        end
        for _, pat in ipairs(Zones.DURATION_PATTERNS) do
            if lname:find(pat, 1, true) and child:IsA("NumberValue") then
                child:GetPropertyChangedSignal("Value"):Connect(function()
                    if child.Value <= 0 then expire() end
                end)
            end
        end
        if child:IsA("LocalScript") or child:IsA("Script") then
            child:GetPropertyChangedSignal("Disabled"):Connect(function()
                if child.Disabled then expire() end
            end)
        end
    end

    part:GetPropertyChangedSignal("Transparency"):Connect(function()
        if part.Transparency >= 0.99 then expire() end
    end)
end

-- Works out how long a hitbox stays active, in order of reliability:
--   1. the precast that came right before it left the whole sequence's timing
--   2. a lifetime value on the part / its model / ReplicatedStorage
--   3. the owning npc's attackSpeed
-- Until one works, live watchers on the part are the fallback. Returns true once resolved.
function Zones.tryResolveDuration(part, info, now)
    local pending = Enemies.takePending(part.Name, info.pos, now)
    if pending then
        local remaining = pending.seqDuration - (now - pending.seqBorn)
        if remaining > 0.05 then
            info.attackDuration = remaining
            Zones.scheduleExpiry(part, info)
            return true
        end
    end

    local d = Zones.probeDuration(part)
    if not (d and d > 0) then
        local owner = Enemies.findAttackOwner(part.Name, info.pos)
        d = owner and owner.attackDuration
    end
    if d and d > 0 then
        info.attackDuration = d
        Zones.scheduleExpiry(part, info)
        return true
    end

    if not info.watchersSet then pcall(Zones.watchHitbox, part, info) end
    if now - info.born > Config.HITBOX_OWNER_TIMEOUT then info.durationGaveUp = true end
    return false
end

-- Removes a zone (and its visuals) once its known duration elapses. Parts of the same multi-part attack
-- (appeared together under the same model) go with it. Done exactly once per zone.
function Zones.scheduleExpiry(part, info)
    if info.expiryScheduled or not info.attackDuration then return end
    info.expiryScheduled = true

    local delay = math.max(0, info.attackDuration - (clock() - info.born)) + 0.05
    local parent = part.Parent
    local owningModel = parent and parent ~= workspace and parent:IsA("Model") and parent or nil
    task.delay(delay, function()
        Zones.expire(part)
        if owningModel and owningModel.Parent then
            for _, sibling in ipairs(owningModel:GetDescendants()) do
                local sibInfo = sibling:IsA("BasePart") and Zones.active[sibling]
                -- only pieces that appeared together with this one: a shared effects model must not lose
                -- unrelated attacks that merely live under it
                if sibInfo and math.abs(sibInfo.born - info.born) <= 1 then Zones.expire(sibling) end
            end
        end
    end)
end

-- The zone ran its course but the part is still around (it outlived its attack). The periodic scan skips it so it
-- isn't re-flagged forever; but if the game re-adds it (a reused/pooled hitbox part), that is a NEW attack - see add().
function Zones.expire(part)
    Zones.expired[part] = true
    Zones.remove(part)
end

-- Scenery, not an attack: never looked at again.
function Zones.ignore(obj)
    Zones.ignored[obj] = true
    Zones.remove(obj)
end

-- ---- visuals ----

function Zones.makeVisual(part, info)
    local list = {}
    local color = Zones.COLORS[info.kind]
    local espOn = State.espEnabled

    if info.isModel then
        -- HandleAdornments don't reliably follow a Model, so a plain anchored box stands in for it
        local visual = Instance.new("Part")
        visual.Name = "_ModelAttackZone"
        visual.Anchored = true
        visual.CanCollide = false
        visual.CanQuery = false
        visual.CanTouch = false
        visual.CastShadow = false
        visual.Material = Enum.Material.Neon
        visual.Color = color
        visual.Transparency = espOn and 0.8 or 1
        visual.CFrame = info.cf
        visual.Size = info.size
        visual.Parent = ESP.folder()
        info.main, info.modelVisual = visual, visual
        table.insert(list, visual)

        local gui, text = ESP.makeAttackLabel(visual, info.size.Y / 2 + 2)
        info.label = text
        table.insert(list, gui)

    elseif info.kind == "orb" then
        local sphere = Instance.new("SphereHandleAdornment")
        sphere.Name = "_AttackZone"
        sphere.Adornee = part
        sphere.Radius = info.radius
        sphere.Color3 = color
        sphere.Transparency = 0.7
        sphere.AlwaysOnTop = true
        sphere.ZIndex = 1
        sphere.Visible = espOn
        sphere.Parent = part
        info.main = sphere
        table.insert(list, sphere)

        -- predicted path (positioned every frame in update)
        local path = Instance.new("Part")
        path.Name = "_OrbPath"
        path.Anchored = true
        path.CanCollide = false
        path.CanQuery = false
        path.CanTouch = false
        path.CastShadow = false
        path.Material = Enum.Material.Neon
        path.Color = color
        path.Size = Vector3.new(0.5, 0.5, 1)
        path.Transparency = 1
        path.Parent = part
        info.path = path
        table.insert(list, path)

        local gui, text = ESP.makeAttackLabel(part, info.radius + 2)
        info.label = text
        table.insert(list, gui)

        part:GetPropertyChangedSignal("Size"):Connect(function()
            info.radius = Zones.orbRadius(part)
            sphere.Radius = info.radius
        end)

    else
        -- padded box = the area the bot actually avoids
        local grow = Vector3.one * (Config.DODGE_PADDING * 2)
        local box = Instance.new("BoxHandleAdornment")
        box.Name = "_AttackZone"
        box.Adornee = part
        box.Size = part.Size + grow
        box.Color3 = color
        box.Transparency = 0.7
        box.AlwaysOnTop = true
        box.ZIndex = 1
        box.Visible = espOn
        box.Parent = part
        info.main = box
        table.insert(list, box)

        local sel = Instance.new("SelectionBox")   -- outline of the real part
        sel.Name = "_AttackOutline"
        sel.Adornee = part
        sel.Color3 = Color3.fromRGB(255, 220, 0)
        sel.LineThickness = 0.04
        sel.SurfaceTransparency = 1
        sel.Visible = espOn
        sel.Parent = part
        table.insert(list, sel)

        local gui, text = ESP.makeAttackLabel(part, part.Size.Y / 2 + Config.DODGE_PADDING + 2)
        info.label = text
        table.insert(list, gui)

        part:GetPropertyChangedSignal("Size"):Connect(function()
            box.Size = part.Size + grow
        end)
    end

    info.visuals = list
end

function Zones.setESP(on)
    for _, info in pairs(Zones.active) do
        for _, v in ipairs(info.visuals or {}) do
            if v == info.modelVisual then
                v.Transparency = on and 0.8 or 1
            else
                ESP.setVisible(v, on)
            end
        end
    end
end

-- ---- creating / removing zones ----

function Zones.newInfo(kind, initial, cf, size)
    local now = clock()
    return {
        kind = kind, initial = initial,
        -- a zone that already existed when we loaded is probably part-way through its sequence
        born = initial and (now - Config.PRECAST_DELAY * 0.6) or now,
        cf = cf, size = size, pos = cf.Position,
        vel = Vector3.zero, flatVel = Vector3.zero, moving = false,
        lastPos = cf.Position, lastT = now,
        radius = 0,
    }
end

function Zones.add(part, initial, fromEvent)
    if Zones.active[part] or Zones.ignored[part] then return end
    if Zones.expired[part] then
        if not fromEvent then return end   -- the polling scan must not resurrect it
        Zones.expired[part] = nil          -- re-added by the game: a new life of a reused part
    end

    local kind = Zones.classify(part)
    if not kind then return end

    local info = Zones.newInfo(kind, initial, part.CFrame, part.Size)
    if kind == "orb" then info.radius = Zones.orbRadius(part) end

    -- For a precast, find the owning npc now and read attackSpeed so we know the whole sequence's duration upfront.
    if kind == "precast" then
        local owner = Enemies.findAttackOwner(part.Name, info.pos)
        info.seqDuration = owner and owner.attackDuration or nil
    end

    Zones.active[part] = info
    State.filterDirty = true
    Zones.makeVisual(part, info)
    Log.add(kind .. ": " .. part.Name)
    Zones.markSuspectAsAttack(part)

    part.Destroying:Connect(function()
        if info.kind == "precast" then
            -- attackSpeed is the total precast+hitbox duration, measured from when the precast appeared.
            -- Leave the sequence's start + length with the owning npc, so the hitbox that follows can work out
            -- how long it has left (even if its own name looks unrelated).
            local owner = Enemies.findAttackOwner(part.Name, info.pos)
            local seqDur = info.seqDuration or (owner and owner.attackDuration)
            if owner and seqDur and seqDur > 0 then
                Enemies.setPending(owner.model, info.born, seqDur, part.Name)
            end
        end
        Zones.remove(part)
    end)

    if kind == "hitbox" or kind == "unknown" then
        Zones.tryResolveDuration(part, info, clock())
    end
end

-- A whole Model sitting directly in workspace counts as an attack too (MODEL_AS_ATTACK). A Model has no
-- CFrame/Size of its own, so its bounding box stands in for them.
function Zones.addModel(model, initial)
    if not Config.MODEL_AS_ATTACK then return end
    if Zones.active[model] or Zones.ignored[model] or model.Parent ~= workspace then return end
    if Zones.isHardIgnored(model) then
        Zones.ignored[model] = true
        return
    end
    if Zones.belongsToCharacter(model) or model:FindFirstChildOfClass("Humanoid") then return end   -- bodies aren't attacks
    if Learn.isIgnoredName(normalize(model.Name)) then return end

    local ok, cf, size = pcall(function() return model:GetBoundingBox() end)
    if not ok or not cf then return end

    if not initial and Zones.nearOwnCast(cf.Position) then
        Zones.ignored[model] = true
        return
    end

    local info = Zones.newInfo("unknown", initial, cf, size)
    info.isModel = true
    Zones.active[model] = info
    State.filterDirty = true
    Zones.makeVisual(model, info)
    Log.add("model: " .. model.Name)
    Zones.markSuspectAsAttack(model)

    model.Destroying:Connect(function() Zones.remove(model) end)
end

function Zones.remove(part)
    local info = Zones.active[part]
    if not info then return end
    Zones.active[part] = nil
    State.filterDirty = true
    for _, v in ipairs(info.visuals or {}) do destroy(v) end
end

-- ---- per-frame upkeep ----

function Zones.refreshGeometry(part, info)
    if info.isModel then
        local ok, cf, size = pcall(function() return part:GetBoundingBox() end)
        if ok and cf then
            info.cf, info.size = cf, size
            if info.modelVisual then
                info.modelVisual.CFrame = cf
                info.modelVisual.Size = size
            end
        end
    else
        info.cf, info.size = part.CFrame, part.Size
    end
    info.pos = info.cf.Position
end

function Zones.updateOrb(part, info)
    local v = info.vel
    local av = part.AssemblyLinearVelocity
    if av.Magnitude > v.Magnitude then v = av end
    info.flatVel = flat(v)
    local speed = info.flatVel.Magnitude

    if info.path then
        if State.espEnabled and speed > 1 then
            local len = speed * Config.ORB_LOOKAHEAD
            local a = info.pos
            local b = a + info.flatVel.Unit * len
            info.path.Size = Vector3.new(0.5, 0.5, len)
            info.path.CFrame = CFrame.lookAt((a + b) / 2, b)
            info.path.Transparency = 0.35
        else
            info.path.Transparency = 1
        end
    end
    if info.label then
        info.label.Text = string.format("ORB  %.0f st/s", speed)
    end
end

function Zones.updatePrecast(info, now)
    local left = Zones.timeLeft(info, now)
    local frac = math.clamp(1 - left / Config.PRECAST_DELAY, 0, 1)
    local c = Zones.COLORS.precast:Lerp(Zones.COLORS.hitbox, frac)

    if info.main then
        info.main.Color3 = c
        info.main.Transparency = 0.8 - 0.35 * frac
    end
    if info.label then
        info.label.Text = left > 0 and string.format("PRECAST  %.1fs", left) or "FIRING"
        info.label.TextColor3 = c
    end
end

function Zones.updateHitbox(part, info, now)
    -- keep trying to learn how long it stays active, so it becomes safe to cross once that has passed
    if info.attackDuration == nil and not info.durationGaveUp and now >= (info.nextResolve or 0) then
        info.nextResolve = now + 0.1
        Zones.tryResolveDuration(part, info, now)
    end

    if info.label then
        if info.attackDuration then
            local left = math.max(0, info.attackDuration - (now - info.born))
            info.label.Text = left > 0 and string.format("HITBOX  %.1fs", left) or "HITBOX (ending)"
        else
            info.label.Text = "HITBOX"
        end
        info.label.TextColor3 = Zones.COLORS.hitbox
    end
end

function Zones.update(now)
    for part, info in pairs(Zones.active) do
        if not part.Parent then
            Zones.remove(part)
        else
            Zones.refreshGeometry(part, info)

            -- velocity of EVERY attack part: moving hitboxes / sweeping beams are extrapolated, not just orbs
            local dt = now - info.lastT
            if dt > 0 then
                info.vel = info.vel:Lerp((info.pos - info.lastPos) / dt, 0.5)
                info.lastPos = info.pos
                info.lastT = now
            end
            info.moving = flat(info.vel).Magnitude > 0.7

            if info.kind == "orb" then
                Zones.updateOrb(part, info)
            elseif info.kind == "precast" then
                Zones.updatePrecast(info, now)
            elseif info.kind == "unknown" then
                if now - info.born > Config.GENERIC_MAX_AGE then
                    Zones.ignore(part)   -- around far longer than any attack: scenery, never re-flag it
                elseif info.label then
                    info.label.Text = "ATTACK?"
                    info.label.TextColor3 = Zones.COLORS.unknown
                end
            else
                Zones.updateHitbox(part, info, now)
            end
        end
    end
end

-- An orb's Mist/Trail/Attachment can be added AFTER the part appears, so top-level parts are re-checked for a
-- short while. Older ones are skipped: re-classifying every static part four times a second is pure waste.
function Zones.scan(now)
    if now - Zones.lastScan < 0.25 then return end
    Zones.lastScan = now

    for _, child in ipairs(workspace:GetChildren()) do
        if child:IsA("BasePart") and not Zones.active[child] and not Zones.ignored[child] then
            local first = Zones.seen[child]
            if not first then
                first = now
                Zones.seen[child] = now
            end
            if now - first <= Config.ORB_RECHECK_WINDOW then
                Zones.add(child)
            end
        end
    end
end

-- Everything already in the world gets a fresh look (a newly learned attack name may match old parts).
function Zones.resetScanWindow()
    Zones.seen = setmetatable({}, { __mode = "k" })
end

-- ---- danger queries ----

-- seconds until the zone becomes harmful (0 = harmful right now)
function Zones.timeLeft(info, now)
    if info.kind == "precast" then
        return math.max(0, Config.PRECAST_DELAY - (now - info.born))
    end
    return 0
end

-- seconds until an ALREADY ACTIVE zone stops being dangerous (math.huge = unknown: dangerous while it exists)
function Zones.activeTimeLeft(info, now)
    if info.attackDuration then
        return math.max(0, info.attackDuration - (now - info.born))
    end
    return math.huge
end

-- flat distance from `pos` to the centre line of an orb's swept capsule
local function orbAxisDistance(info, pos)
    local a = flat(info.pos)
    local ab = info.flatVel * Config.ORB_LOOKAHEAD
    local p = flat(pos)

    local u = 0
    local len2 = ab:Dot(ab)
    if len2 > 0.001 then
        u = math.clamp((p - a):Dot(ab) / len2, 0, 1)
    end
    return (p - (a + ab * u)).Magnitude
end

-- Is `pos` inside this zone? `pad` = margin around it (default DODGE_PADDING), `t` = seconds from now
-- (a moving zone is shifted to where it will be by then).
function Zones.contains(info, pos, pad, t)
    pad = pad or Config.DODGE_PADDING

    if info.kind == "orb" then
        return orbAxisDistance(info, pos) <= info.radius - math.max(0, Config.DODGE_PADDING - pad)
    end

    local p = pos
    if t and t > 0 and info.moving then
        p = pos - info.vel * math.min(t, Config.MOVE_PREDICT_MAX)   -- same as moving the zone forward
    end

    local l = info.cf:PointToObjectSpace(p)
    local half = info.size / 2
    return math.abs(l.X) <= half.X + pad
       and math.abs(l.Y) <= half.Y + pad
       and math.abs(l.Z) <= half.Z + pad
end

-- Would standing at `pos` t seconds from now be inside a zone that is active by then?
-- (a precast we can cross and leave before it fires does NOT count)
function Zones.dangerAt(pos, t, pad)
    local now = clock()
    for _, info in pairs(Zones.active) do
        if info.kind == "precast" and t < Zones.timeLeft(info, now) - Tuned.precastSafety then
            -- precast hasn't fired yet by the time we'd be there: not dangerous yet
        elseif info.kind ~= "orb" and t < math.huge
            and Zones.activeTimeLeft(info, now) ~= math.huge
            and t >= Zones.activeTimeLeft(info, now) + Tuned.precastSafety then
            -- an active hitbox whose real duration we know has ended by the time we'd be there: safe
        else
            if Zones.contains(info, pos, pad, t) then return true end

            -- a destination (t = inf) must also survive a moving zone sweeping across it
            if t == math.huge and info.moving and info.kind ~= "orb" then
                if Zones.contains(info, pos, pad, Config.MOVE_PREDICT_MAX * 0.5)
                    or Zones.contains(info, pos, pad, 0) then
                    return true
                end
            end
        end
    end
    return false
end

-- Inside ANY zone, regardless of timing (spots we might sit at for a long time: waiting out a cooldown, ...).
function Zones.insideDanger(pos, pad)
    return Zones.dangerAt(pos, math.huge, pad)
end

-- Is `pos` dangerous by the time we'd realistically still be near it (steering candidates, dodge spots)?
-- A precast is only a telegraph: standing on it is fine as long as we're not still there when it fires.
function Zones.destinationDanger(pos, pad)
    return Zones.dangerAt(pos, Tuned.destSafetyWindow, pad)
end

-- Is `pos` dangerous RIGHT NOW (do we personally need to be dodging this instant)?
function Zones.dangerNow(pos, pad)
    return Zones.dangerAt(pos, 0, pad)
end

-- Samples along a->b that would be inside an active zone when we get there.
function Zones.routeDangerCount(a, b, speed, pad)
    local dist = flat(b - a).Magnitude
    local steps = math.clamp(math.ceil(dist / 3), 3, 10)   -- a sample every ~3 studs, so a thin beam can't slip between
    local n = 0
    for i = 1, steps do
        local f = i / steps
        local t = (dist * f) / speed + Config.REACTION_TIME
        if Zones.dangerAt(a:Lerp(b, f), t, pad) then n = n + 1 end
    end
    return n
end

-- Time until we're out of every zone when walking a->b.
function Zones.routeExitTime(a, b, speed, pad)
    local dist = flat(b - a).Magnitude
    for i = 1, 8 do
        if not Zones.insideDanger(a:Lerp(b, i / 8), pad) then
            return (dist * i / 8) / speed + Config.REACTION_TIME
        end
    end
    return dist / speed + Config.REACTION_TIME
end

-- Seconds until the soonest zone containing `pos` becomes harmful (0 = already harmful, inf = not inside any).
function Zones.positionDeadline(pos)
    local now = clock()
    local d = math.huge
    for _, info in pairs(Zones.active) do
        if Zones.contains(info, pos) then
            d = math.min(d, Zones.timeLeft(info, now))
        end
    end
    return d
end

-- Studs between `pos` and the edge of ONE zone (0 = inside).
function Zones.zoneClearance(info, pos, pad)
    if info.kind == "orb" then
        return math.max(0, orbAxisDistance(info, pos) - info.radius)
    end
    pad = pad or Config.DODGE_PADDING
    local l = info.cf:PointToObjectSpace(pos)
    local half = info.size / 2
    local dx = math.max(math.abs(l.X) - (half.X + pad), 0)
    local dy = math.max(math.abs(l.Y) - (half.Y + pad), 0)
    local dz = math.max(math.abs(l.Z) - (half.Z + pad), 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Studs between `pos` and the edge of the NEAREST zone (0 = inside one, huge = none around).
function Zones.dangerClearance(pos, pad)
    local best = math.huge
    for _, info in pairs(Zones.active) do
        best = math.min(best, Zones.zoneClearance(info, pos, pad))
    end
    return best
end

-- how many attacks are within `radius` studs of `pos`
function Zones.nearbyThreatCount(pos, radius)
    local n = 0
    for _, info in pairs(Zones.active) do
        if Zones.zoneClearance(info, pos) <= radius then n = n + 1 end
    end
    return n
end

function Zones.counts(now)
    local c = { precast = 0, hitbox = 0, orb = 0, unknown = 0, soonest = math.huge }
    for _, info in pairs(Zones.active) do
        c[info.kind] = c[info.kind] + 1
        if info.kind == "precast" then
            c.soonest = math.min(c.soonest, Zones.timeLeft(info, now))
        end
    end
    return c
end

-- ---- learning from damage: what might have hurt us? ----
-- Every object that appears in workspace is remembered (name, place, birth), whether or not it was recognised as
-- an attack. If something unrecognised kills us, the closest recent object is the suspect, and its name is
-- learned as an attack. An unrecognised object that goes away having never been near us when we took damage is
-- learned as harmless instead, so the bot stops giving it any thought.

local function currentPos(obj, entry)
    return obj:IsA("BasePart") and obj.Position or entry.pos
end

-- An object that was ever treated as an attack (even if it only became one later, e.g. an orb whose Trail
-- appeared after the part) must never be learned as harmless when it goes away.
function Zones.markSuspectAsAttack(obj)
    local entry = Zones.suspects[obj]
    if entry then entry.attack = true end
end

function Zones.nameLooksHostile(key)
    return Learn.looksHostileName(key) or Learn.attackNames[key] or Enemies.findOwnerByName(key) ~= nil
end

function Zones.track(obj)
    if Zones.suspects[obj] or obj.ClassName == "Terrain" then return end

    -- everything this script creates for itself uses a leading underscore: walk up the whole chain, since a
    -- plain-named child can sit inside one of our own underscore-named containers
    local p = obj
    while p and p ~= workspace do
        if p.Name:sub(1, 1) == "_" then return end
        p = p.Parent
    end

    if Zones.isHardIgnored(obj) then return end   -- never remembered, so it can never be blamed for damage
    if Zones.belongsToCharacter(obj) then return end
    local dungeon = workspace:FindFirstChild("dungeon")
    if dungeon and obj:IsDescendantOf(dungeon) then return end   -- part of the dungeon itself, not a loose attack

    local key = normalize(obj.Name)
    if Learn.isIgnoredName(key) then return end

    local pos
    if obj:IsA("BasePart") then
        pos = obj.Position
    else
        local ok, cf = pcall(function() return obj:GetBoundingBox() end)
        pos = ok and cf and cf.Position or nil
    end
    if not pos then return end

    local entry = { name = key, born = clock(), pos = pos, damaged = false, attack = Zones.active[obj] ~= nil }
    Zones.suspects[obj] = entry

    obj.Destroying:Connect(function()
        Zones.suspects[obj] = nil
        -- Only something that was never treated as an attack, never looked like one, and was never near us when
        -- we got hurt is evidence of "harmless". (Learning this for dodged attacks would teach the bot that
        -- every "precast"/"hitbox" is safe after the first one it survives.)
        if not entry.damaged and not entry.attack and not Learn.ignoreNames[entry.name]
            and not Zones.nameLooksHostile(entry.name) then
            Learn.addIgnoreName(entry.name)
        end
    end)
end

-- We took damage at `pos`: anything recent and nearby may be the culprit, so never learn it as harmless.
function Zones.noteDamage(pos)
    local now = clock()
    for obj, entry in pairs(Zones.suspects) do
        if obj.Parent and now - entry.born < Config.UNCLASSIFIED_MAX_AGE
            and flat(pos - currentPos(obj, entry)).Magnitude <= Config.DEATH_ATTACK_SEARCH_RADIUS then
            entry.damaged = true
        end
    end
end

-- The closest untracked, recently-appeared object to where we died (name, distance, object).
function Zones.findSuspect(deathPos)
    local now = clock()
    local best, bestEntry, bestDist = nil, nil, math.huge
    for obj, entry in pairs(Zones.suspects) do
        if obj.Parent and now - entry.born < Config.UNCLASSIFIED_MAX_AGE and not Zones.active[obj] then
            local d = flat(deathPos - currentPos(obj, entry)).Magnitude
            if d < bestDist and d <= Config.DEATH_ATTACK_SEARCH_RADIUS then
                best, bestEntry, bestDist = obj, entry, d
            end
        end
    end
    if bestEntry then bestEntry.damaged = true end
    return bestEntry and bestEntry.name, bestDist, best
end

-- ---- startup ----

function Zones.onAdded(obj)
    if obj:IsA("BasePart") then
        Zones.add(obj, nil, true)
        pcall(Zones.track, obj)
    elseif obj:IsA("Model") or obj:IsA("Folder") then
        for _, d in ipairs(obj:GetDescendants()) do
            if d:IsA("BasePart") then
                Zones.add(d, nil, true)
                pcall(Zones.track, d)
            end
        end
        if obj:IsA("Model") then
            Zones.addModel(obj)
            pcall(Zones.track, obj)
        end
    end
end

function Zones.start()
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("BasePart") then pcall(Zones.add, obj, true) end
    end
    for _, obj in ipairs(workspace:GetChildren()) do
        if obj:IsA("Model") then pcall(Zones.addModel, obj, true) end
    end

    track(workspace.DescendantAdded:Connect(function(obj)
        local ok, err = pcall(Zones.onAdded, obj)
        if not ok then Bot.reportError("zones", err) end
    end))
end

-- =====================
-- WALLS: map / wall detection
-- Everything solid counts as a wall (map, props, terrain). Rays ignore characters, npcs, attack parts and
-- our own visuals, and only hit CanCollide parts. Every part under workspace.map is cast against directly
-- regardless of CanCollide, size or transparency, so nothing in the map is missed.
-- =====================
Walls.rayParams = RaycastParams.new()
Walls.rayParams.FilterType = Enum.RaycastFilterType.Exclude
Walls.rayParams.RespectCanCollide = true
Walls.rayParams.IgnoreWater = true

Walls.mapParams = RaycastParams.new()
Walls.mapParams.FilterType = Enum.RaycastFilterType.Include
Walls.mapParams.FilterDescendantsInstances = {}

Walls.currentMap = nil
Walls.visuals = {}
Walls.LATERALS = { -2, 0, 2 }    -- body width (AgentRadius = 2)
Walls.HEIGHTS = { -1.5, 1 }      -- near the feet and mid-body
Walls.DIRS = {}
for i = 0, 7 do
    local r = math.rad(i * 45)
    table.insert(Walls.DIRS, Vector3.new(math.cos(r), 0, math.sin(r)))
end

function Walls.setMapFilter(map)
    Walls.mapParams.FilterDescendantsInstances = (map and Config.MAP_ALL_AS_WALLS) and { map } or {}
end

-- Casts against everything solid plus everything in the map; the nearer hit wins.
function Walls.cast(origin, direction)
    local a = workspace:Raycast(origin, direction, Walls.rayParams)
    if #Walls.mapParams.FilterDescendantsInstances == 0 then return a end

    local b = workspace:Raycast(origin, direction, Walls.mapParams)
    -- the Include filter can't exclude anything, so a hard-ignored part inside the map is dropped from the result
    if b and Zones.hardIgnored[b.Instance] then b = nil end
    if a and b then
        return (a.Distance <= b.Distance) and a or b
    end
    return a or b
end

function Walls.clearVisuals()
    for _, v in ipairs(Walls.visuals) do destroy(v) end
    Walls.visuals = {}
end

function Walls.draw(map)
    Walls.clearVisuals()
    if not map or not Config.SHOW_WALLS then return end

    -- SelectionBox has no on-screen cap (Highlight is limited to ~31), so enemy highlights stay visible
    for _, obj in ipairs(map:GetDescendants()) do
        if obj:IsA("BasePart") and not Zones.isHardIgnored(obj) then
            local s = Instance.new("SelectionBox")
            s.Adornee = obj
            s.Color3 = Color3.fromRGB(50, 100, 255)
            s.LineThickness = 0.02
            s.Transparency = 0.5
            s.SurfaceTransparency = 1
            s.Visible = State.espEnabled and Config.SHOW_WALLS
            s.Parent = obj
            table.insert(Walls.visuals, s)
        end
    end
end

function Walls.setESP(on)
    for _, v in ipairs(Walls.visuals) do
        if v.Parent then v.Visible = on and Config.SHOW_WALLS end
    end
end

function Walls.rebuildFilter()
    local list = {}

    if player.Character then table.insert(list, player.Character) end
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then table.insert(list, p.Character) end
    end

    local guide = workspace:FindFirstChild("_GuidelineFolder")
    if guide then table.insert(list, guide) end

    for _, room in ipairs(Enemies.rooms()) do
        local ef = room:FindFirstChild("enemyFolder")
        if ef then table.insert(list, ef) end
    end

    for part in pairs(Zones.active) do
        if part.Parent then table.insert(list, part) end
    end

    -- hard-ignored things (the ground aura ...) are visual effects: they must not read as walls or floor
    for obj in pairs(Zones.hardIgnored) do
        if obj.Parent then table.insert(list, obj) end
    end

    Walls.rayParams.FilterDescendantsInstances = list

    -- respect the collision group the character uses, so the walls that block us are the walls the rays see
    if State.hrp and State.hrp.Parent then
        Walls.rayParams.CollisionGroup = State.hrp.CollisionGroup
    end
end

function Walls.refresh()
    local map = workspace:FindFirstChild("map")
    if map ~= Walls.currentMap then
        Walls.currentMap = map
        Walls.setMapFilter(map)
        Walls.draw(map)
    end
    Walls.rebuildFilter()
end

function Walls.floorBelow(pos)
    return Walls.cast(pos + Vector3.new(0, 2, 0), Vector3.new(0, -14, 0)) ~= nil
end

-- Body-wide sweep from a to b (6 rays, plus a margin past b) + floor check under b.
function Walls.moveIsClear(a, b)
    local dir = b - a
    local flatDir = flat(dir)
    if flatDir.Magnitude < 0.01 then return true end

    local unit = flatDir.Unit
    local right = unit:Cross(Vector3.yAxis)
    local rayDir = dir + unit * Config.WALL_MARGIN

    for _, lat in ipairs(Walls.LATERALS) do
        for _, h in ipairs(Walls.HEIGHTS) do
            local off = right * lat + Vector3.new(0, h, 0)
            if Walls.cast(a + off, rayDir) then
                return false
            end
        end
    end

    return Walls.floorBelow(b)
end

-- 0 = open space, higher = closer to walls on more sides (8 directions, avoids corner traps)
function Walls.penalty(pos)
    local pen = 0
    for _, d in ipairs(Walls.DIRS) do
        local hit = Walls.cast(pos, d * Config.WALL_CLEARANCE)
        if hit then
            pen = pen + ((Config.WALL_CLEARANCE - hit.Distance) / Config.WALL_CLEARANCE)
        end
    end
    return pen
end

-- Are we about to walk into a wall (or off a ledge) right now?
function Walls.wallAhead()
    local md = State.humanoid.MoveDirection
    if md.Magnitude < 0.1 then return false end
    local ahead = State.hrp.Position + flat(md).Unit * 5
    return not Walls.moveIsClear(State.hrp.Position, ahead)
end

function Walls.hasLineOfSight(a, b)
    local from = a + Vector3.new(0, 1, 0)
    local to = b + Vector3.new(0, 1, 0)
    return Walls.cast(from, to - from) == nil
end

-- =====================
-- STEER: where to stand
-- =====================
Steer.orbitDir = 1        -- +1 = clockwise (seen from above), -1 = counter-clockwise
Steer.goal = nil          -- current steering destination
Steer.lastFlip = 0
Steer.lastPosition = nil
Steer.lastMoveTime = clock()
Steer.pocketCache = { t = 0, pos = nil, pad = 2 }

function Steer.isStuck()
    local pos = State.hrp.Position
    if not Steer.lastPosition then
        Steer.lastPosition = pos
        return false
    end
    if (pos - Steer.lastPosition).Magnitude > Config.STUCK_MOVE_MIN then
        Steer.lastPosition = pos
        Steer.lastMoveTime = clock()
        return false
    end
    return (clock() - Steer.lastMoveTime) >= Config.STUCK_THRESHOLD
end

-- Is an attack zone (live now, or live by the time we get there) on the way we're walking?
function Steer.pathAheadBlocked()
    local md = State.humanoid.MoveDirection
    if md.Magnitude < 0.1 then return false end

    local dir = flat(md).Unit
    local speed = math.max(State.humanoid.WalkSpeed, 8)
    local reach = math.max(8, speed * 0.9)
    local from = State.hrp.Position

    for d = 3, reach, 3 do
        if Zones.dangerAt(from + dir * d, d / speed + Config.REACTION_TIME) then
            return true
        end
    end
    return false
end

-- How far from the group's centre we want to stand. Normally IDEAL_DISTANCE past the group's edge, BUT skills
-- reach by distance to an npc's CENTRE: a boss with a massive body would otherwise park us too far out to hit
-- it, so come in until we're inside skill range (never closer than BIG_BODY_GAP to its edge).
function Steer.ringRadiusFor(group)
    local r = group.radius + Config.IDEAL_DISTANCE
    local stand = Enemies.groupCastRange(group) - Config.RANGE_MARGIN   -- inside the aggro range too, when the npcs have one
    if r > stand then
        r = math.max(stand, group.radius + Config.BIG_BODY_GAP)
    end
    return r
end

-- Cheap (no raycast) legality + score. nil = illegal.
function Steer.cheapScore(from, cand, ctx)
    -- the destination just needs to be safe by the time we'd get there and settle
    if Zones.destinationDanger(cand) then return nil end

    -- the route may cross a precast we can leave before it fires, but never an active zone
    local dangerSamples = Zones.routeDangerCount(from, cand, ctx.speed)
    if dangerSamples > 0 and not ctx.inDanger then return nil end

    -- keep-away distance at the destination, for EVERY npc (strictest of the global floor and the learned one)
    local nearestEntry, minDist = Enemies.nearestFrom(cand)
    local floorDist = nearestEntry and Learn.effectiveMinDist(nearestEntry.model.Name) or Config.MIN_DISTANCE
    if minDist < floorDist then return nil end

    -- ...and along the route. If we're already too close, the route just can't get closer.
    local routeFloor = math.min(Config.MIN_DISTANCE - 1, ctx.startMin) - 0.5
    for i = 1, 3 do
        if Enemies.minDistance(from:Lerp(cand, i / 4)) < routeFloor then
            return nil
        end
    end

    local score = dangerSamples * 8

    -- Already inside a zone: we must be OUT before it fires. Spots we can't leave in time are heavily penalised.
    if ctx.inDanger then
        local exitTime = Zones.routeExitTime(from, cand, ctx.speed)
        local late = exitTime - (ctx.deadline - Tuned.precastSafety)
        if late > 0 then
            score = score + 5 + late * 25
        end
        score = score + exitTime * 4   -- among ways out, take the quickest (don't run through the attack)
    end

    -- Loose range: stay inside the cast range (attack range, and the npcs' aggro range) but don't enforce a strict
    -- circle shape. Measured to the npc's CENTRE, which is what skills and aggro both use.
    local looseHigh = ctx.range * 0.95
    local centerDist = Enemies.nearestCenterDist(cand)
    if centerDist > looseHigh then
        score = score + ((centerDist - looseHigh) * 6)   -- pull in if drifted out of range
    end

    local move = flat(cand - from)

    for _, e in ipairs(Enemies.list) do
        local toCand = flat(cand - e.pos)
        local dist = toCand.Magnitude
        if dist < Config.FLANK_RANGE and dist > 0.01 then
            local facing = flat(e.part.CFrame.LookVector)
            if facing.Magnitude > 0.01 then
                local dot = facing.Unit:Dot(toCand.Unit)
                if dot > 0.3 then
                    score = score + ((dot - 0.3) * Config.W_FLANK)
                end
            end
            score = score + (math.max(0, (Config.FLANK_RANGE - dist) / Config.FLANK_RANGE) * Config.W_CROWD)
        end
    end

    score = score - (math.min(move.Magnitude, 8) * 0.2)   -- small bonus for any movement (avoid freezing)
    score = score + ((cand - from).Magnitude * Config.W_TRAVEL)
    if Steer.goal and flat(cand - Steer.goal).Magnitude < 3 then
        score = score - Config.W_STICKY
    end

    return score
end

function Steer.findBestSpot(group, urgent, inDanger)
    local from = State.hrp.Position

    local radial = flat(from - group.centroid)
    local tangent = nil
    if radial.Magnitude > 0.01 then
        tangent = Vector3.new(-radial.Z, 0, radial.X).Unit * Steer.orbitDir
    end

    local ctx = {
        range = Enemies.groupCastRange(group),
        startMin = Enemies.minDistance(from),
        inDanger = inDanger,
        speed = math.max(State.humanoid.WalkSpeed, 8),
        deadline = Zones.positionDeadline(from),
    }

    -- Stage 1: cheap scoring of every candidate around us
    local cands = {}
    for _, radius in ipairs(Config.SEARCH_RADII) do
        for angle = 0, 359, Config.SEARCH_ANGLE_STEP do
            local r = math.rad(angle)
            local cand = from + Vector3.new(math.cos(r) * radius, 0, math.sin(r) * radius)
            local s = Steer.cheapScore(from, cand, ctx)
            if s then
                table.insert(cands, { pos = cand, score = s })
            end
        end
    end

    if #cands == 0 then
        return nil
    end

    table.sort(cands, function(a, b) return a.score < b.score end)

    -- Stage 2: wall test only the best ones, add the wall-hugging penalty
    local best, bestScore = nil, math.huge
    local checked, clearFound = 0, 0

    for _, c in ipairs(cands) do
        if checked >= Config.MAX_WALL_CHECKS or clearFound >= Config.CLEAR_SPOTS_WANTED then
            break
        end
        checked = checked + 1

        if Walls.moveIsClear(from, c.pos) then
            clearFound = clearFound + 1
            local total = c.score + Walls.penalty(c.pos) * Config.W_WALL
            if total < bestScore then
                best, bestScore = c.pos, total
            end
        end
    end

    -- If walls force us to go against the circling direction, follow the walls instead.
    if best and tangent and not urgent and clock() - Steer.lastFlip > 1 then
        local mv = flat(best - from)
        if mv.Magnitude > 0.01 and mv.Unit:Dot(tangent) < -0.3 then
            Steer.orbitDir = -Steer.orbitDir
            Steer.lastFlip = clock()
            Log.add("Orbit flipped (wall)")
        end
    end

    return best
end

-- Boxed in: run directly away from the closest npc, rotating until a wall-safe direction is found.
function Steer.fallbackAway()
    local nearest = Enemies.nearestFrom(State.hrp.Position)
    if not nearest then return nil end

    local away = flat(State.hrp.Position - nearest.pos)
    if away.Magnitude < 0.01 then away = Vector3.new(0, 0, 1) end
    away = away.Unit

    for _, deg in ipairs({ 0, 30, -30, 60, -60, 90, -90, 120, -120 }) do
        local r = math.rad(deg)
        local dir = Vector3.new(
            away.X * math.cos(r) - away.Z * math.sin(r),
            0,
            away.X * math.sin(r) + away.Z * math.cos(r)
        )
        local p = State.hrp.Position + dir * 10
        if not Zones.destinationDanger(p) and Walls.moveIsClear(State.hrp.Position, p) then
            return p
        end
    end
    return nil
end

-- Boxed in during an attack: if left / right / forward are all blocked, the surest way out is to back straight
-- away from the attack. Ranks reachable spots outside every zone by how far outside they are, strongly
-- preferring "behind us" relative to the attack, and never moves us closer to an npc than we already are.
function Steer.retreatSpot()
    local from = State.hrp.Position
    local startMin = Enemies.minDistance(from)
    local speed = math.max(State.humanoid.WalkSpeed, 8)
    local deadline = Zones.positionDeadline(from)

    -- "back" = directly away from the closest attack, else away from the closest npc
    local back, nearestZone = nil, math.huge
    for _, info in pairs(Zones.active) do
        local d = flat(info.pos - from).Magnitude
        if d < nearestZone then
            nearestZone = d
            back = flat(from - info.pos)
        end
    end
    if not back or back.Magnitude < 0.5 then
        local nearest = Enemies.nearestFrom(from)
        back = nearest and flat(from - nearest.pos) or Vector3.zero
    end
    if back.Magnitude < 0.01 then
        back = -flat(State.hrp.CFrame.LookVector)
    end
    back = back.Unit

    local best, bestScore = nil, -math.huge

    for _, radius in ipairs({ 4, 8, 13, 19, 26 }) do
        for angle = 0, 340, 20 do
            local r = math.rad(angle)
            local dir = Vector3.new(math.cos(r), 0, math.sin(r))
            local cand = from + dir * radius

            if not Zones.destinationDanger(cand)
                and Enemies.minDistance(cand) >= startMin - 1
                and Walls.moveIsClear(from, cand) then

                local clearance = math.min(Zones.dangerClearance(cand), 20)
                local score = clearance * 2 + dir:Dot(back) * 10 - radius * 0.3

                score = score - (Zones.routeDangerCount(from, cand, speed) * 4)

                local late = Zones.routeExitTime(from, cand, speed) - (deadline - Tuned.precastSafety)
                if late > 0 then
                    score = score - (5 + late * 25)
                end

                if score > bestScore then
                    best, bestScore = cand, score
                end
            end
        end
    end

    return best
end

-- Tight arenas: some bosses leave NO roomy safe spot, only small gaps between crossing attacks. This scans a
-- fine grid around us for any point outside every attack, trying a roomy margin first and squeezing to smaller
-- margins until a gap is found. Gaps are ranked by how far inside the gap they are, how close they are and
-- whether we can reach them before it's too late. It doesn't insist on the usual keep-away distance
-- (surviving comes first), it only avoids walking closer to an npc.
function Steer.findPocket()
    local from = State.hrp.Position
    local speed = math.max(State.humanoid.WalkSpeed, 8)
    local deadline = Zones.positionDeadline(from)
    local startMin = Enemies.minDistance(from)

    -- how far can we get before our current spot turns harmful?
    local budget = (deadline == math.huge) and 1.5 or math.max(0.35, deadline - Tuned.precastSafety)
    local reach = math.clamp(speed * budget, 5, Config.POCKET_MAX_REACH)
    local r2 = reach * reach

    for _, pad in ipairs(Config.POCKET_PADDINGS) do
        local cands = {}

        for dx = -reach, reach, Config.POCKET_STEP do
            for dz = -reach, reach, Config.POCKET_STEP do
                local d2 = dx * dx + dz * dz
                if d2 <= r2 then
                    local cand = from + Vector3.new(dx, 0, dz)

                    if not Zones.destinationDanger(cand, pad) then
                        local dist = math.sqrt(d2)
                        local enemyGap = Enemies.minDistance(cand)

                        local score = math.min(Zones.dangerClearance(cand, pad), 6) * 3 - dist * 0.35
                        score = score - (math.max(0, startMin - enemyGap) * 2)   -- never walk INTO npcs
                        score = score - (math.max(0, Config.MIN_DISTANCE - enemyGap) * 0.15)

                        table.insert(cands, { pos = cand, score = score })
                    end
                end
            end
        end

        if #cands > 0 then
            table.sort(cands, function(a, b) return a.score > b.score end)

            local best, bestScore = nil, -math.huge
            for i = 1, math.min(Config.POCKET_CHECKS, #cands) do
                local c = cands[i]

                if Walls.moveIsClear(from, c.pos) then
                    local total = c.score
                    total = total - (Zones.routeDangerCount(from, c.pos, speed, pad) * 4)

                    local late = Zones.routeExitTime(from, c.pos, speed, pad) - (deadline - Tuned.precastSafety)
                    if late > 0 then
                        total = total - (5 + late * 25)
                    end

                    total = total - (Walls.penalty(c.pos) * 2)

                    if total > bestScore then
                        best, bestScore = c.pos, total
                    end
                end
            end

            if best then return best, pad end
        end
    end

    return nil
end

-- The grid scan is heavy, so reuse the answer for a moment (as long as it's still safe).
function Steer.findPocketCached()
    local now = clock()
    local cache = Steer.pocketCache
    if cache.pos and now - cache.t < 0.12 and not Zones.destinationDanger(cache.pos, cache.pad) then
        return cache.pos
    end

    local pos, pad = Steer.findPocket()
    cache.pos, cache.pad, cache.t = pos, pad or 2, now
    return pos
end

-- No npcs around, just get out of the attack (wall-aware).
function Steer.dodgeWithoutEnemies()
    local from = State.hrp.Position
    for _, radius in ipairs(Config.SEARCH_RADII) do
        for angle = 0, 359, Config.SEARCH_ANGLE_STEP do
            local r = math.rad(angle)
            local cand = from + Vector3.new(math.cos(r) * radius, 0, math.sin(r) * radius)
            if not Zones.destinationDanger(cand) and Walls.moveIsClear(from, cand) then
                return cand
            end
        end
    end
    return nil
end

-- Legal points on the orbit ring around the whole group, nearest to us first.
function Steer.approachPoints(group)
    local ringR = Steer.ringRadiusFor(group)
    local pts = {}

    for angle = 0, 345, 15 do
        local r = math.rad(angle)
        local p = Vector3.new(
            group.centroid.X + math.cos(r) * ringR,
            group.centroid.Y,
            group.centroid.Z + math.sin(r) * ringR
        )
        if Enemies.minDistance(p) >= Config.MIN_DISTANCE + 1 and not Zones.insideDanger(p) and Walls.floorBelow(p) then
            table.insert(pts, p)
        end
    end

    local me = State.hrp.Position
    table.sort(pts, function(a, b)
        return flat(a - me).Magnitude < flat(b - me).Magnitude
    end)
    return pts
end

-- Points outside WAIT_RANGE of every npc, on a ring around the group, nearest to us first.
function Steer.stagingPoints(group)
    local ringR = group.radius + Config.WAIT_RANGE + Config.WAIT_MARGIN
    local me = State.hrp.Position
    local pts = {}

    for angle = 0, 345, 15 do
        local r = math.rad(angle)
        local p = Vector3.new(
            group.centroid.X + math.cos(r) * ringR,
            group.centroid.Y,
            group.centroid.Z + math.sin(r) * ringR
        )
        if Enemies.minDistance(p) >= Config.WAIT_RANGE and not Zones.insideDanger(p) and Walls.floorBelow(p) then
            table.insert(pts, p)
        end
    end

    table.sort(pts, function(a, b)
        return flat(a - me).Magnitude < flat(b - me).Magnitude
    end)

    -- map too small for a full WAIT_RANGE? then just get as far from the npcs as we can
    if #pts == 0 then
        local best, bestGap = nil, Enemies.minDistance(me)
        for _, radius in ipairs({ 10, 20, 30, 45, 60 }) do
            for angle = 0, 330, 30 do
                local r = math.rad(angle)
                local p = me + Vector3.new(math.cos(r) * radius, 0, math.sin(r) * radius)
                local gap = Enemies.minDistance(p)
                if gap > bestGap + 3 and not Zones.insideDanger(p) and Walls.floorBelow(p) and Walls.moveIsClear(me, p) then
                    best, bestGap = p, gap
                end
            end
        end
        if best then pts[1] = best end
    end

    return pts
end

-- =====================
-- BARRIERS
-- If we stop getting closer to an npc, something blocks the way (e.g. the Ancient Enchanted Tree stops you
-- ~105 studs away). Remember how close we got and fight from there instead of walking into it forever.
-- =====================
Steer.barriers = setmetatable({}, { __mode = "k" })   -- [npc model] = { dist, centerDist, ringDist, pos, expires, hits, testShots }
Steer.approach = { model = nil, best = math.huge, progressT = 0, anchor = Vector3.zero, anchorT = 0 }

-- Is there actually something solid between us and the npc right now? Returns the hit, or nil.
function Steer.findObstruction(entry)
    local dir = flat(entry.pos - State.hrp.Position)
    if dir.Magnitude <= 1 then return nil end

    local hit = Walls.cast(State.hrp.Position, dir.Unit * math.min(dir.Magnitude, 300))
    if hit and hit.Distance <= Config.BARRIER_WALL_MAX_DIST then
        return hit
    end
    return nil
end

function Steer.declareBarrier(entry, dist, group, obstruction)
    local centre = group and group.centroid or entry.pos
    local extra = ""
    if obstruction then
        extra = string.format(" (%s, %.0f studs ahead)", obstruction.Instance.Name, obstruction.Distance)
    end

    Steer.barriers[entry.model] = {
        dist       = dist,
        centerDist = flat(State.hrp.Position - entry.pos).Magnitude,
        ringDist   = flat(State.hrp.Position - centre).Magnitude,
        pos        = State.hrp.Position,
        expires    = clock() + (Config.BARRIER_RETRY_SECONDS > 0 and Config.BARRIER_RETRY_SECONDS or math.huge),
        hits       = nil,   -- unknown until test-fired: nil = untested, true = confirmed hitting, false = confirmed not reaching
        testShots  = 0,
    }

    Move.stopWalker()
    ESP.clearGuideline()
    Log.add(string.format("Barrier: can't get closer than %.0f studs%s, attacking from here", dist, extra))
end

-- =====================
-- MOVE: movement + facing (shift-lock style) + the path walker
-- Humanoid:Move(direction) is used instead of Humanoid:MoveTo(point): Move() is pure velocity and never touches
-- facing, so it coexists cleanly with us setting rotation ourselves every frame (AutoRotate = false is built for
-- exactly this). Re-teleporting the whole CFrame via MoveTo-style movement while also fighting it for rotation is
-- what used to freeze the character. Everywhere else, "walk toward this point" is Move.setGoal(point).
-- =====================
Move.goal = nil             -- current destination, or nil to stand still
Move.aimPos = nil           -- set by the main loop every frame: group centre (or the lone npc)
Move.aimOwnsRotation = false
Move.walkerThread = nil
Move.isWalking = false
Move.isComputing = false
Move.lastGoal = nil         -- destination of the path being walked
Move.controls = nil

function Move.setGoal(pos)
    Move.goal = pos
end

function Move.stop()
    Move.goal = nil
end

-- Runs every frame while the bot is on (only then does it own the humanoid's movement).
function Move.drive()
    if not State.enabled then return end

    local char = player.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not root or not hum then return end

    if Move.goal then
        local delta = flat(Move.goal - root.Position)
        if delta.Magnitude > 1 then
            hum:Move(delta.Unit, false)
        else
            hum:Move(Vector3.zero, false)
            Move.goal = nil
        end
    else
        hum:Move(Vector3.zero, false)
    end

    local facePos = (State.aimEnabled and Move.aimPos) or Move.goal
    if facePos then
        local faceDelta = flat(facePos - root.Position)
        if faceDelta.Magnitude > 0.5 then
            Move.aimOwnsRotation = true
            hum.AutoRotate = false
            local vel = root.AssemblyLinearVelocity
            root.CFrame = CFrame.lookAt(root.Position, root.Position + faceDelta)
            root.AssemblyLinearVelocity = vel
        end
    elseif Move.aimOwnsRotation then
        Move.aimOwnsRotation = false
        hum.AutoRotate = true
    end
end

-- Humanoid:Move() calls get silently overwritten the instant the game's own WASD controller runs afterwards
-- (it re-asserts "no keys held" every frame) - that's why a bot could face the npcs but never walk anywhere.
-- Taking over the native controls while the bot runs is the standard way to let a script drive movement; they
-- are handed straight back the moment the bot is turned off.
function Move.getControls()
    if Move.controls then return Move.controls end
    local ok, result = pcall(function()
        local scripts = player:WaitForChild("PlayerScripts", 5)
        local module = require(scripts:WaitForChild("PlayerModule", 5))
        return module:GetControls()
    end)
    if ok then Move.controls = result end
    return Move.controls
end

function Move.setControlsEnabled(on)
    local controls = Move.getControls()
    if not controls then
        if not on then
            Log.add("Couldn't find the default PlayerModule controls - movement may fight your own input")
        end
        return
    end
    pcall(function()
        if on then controls:Enable() else controls:Disable() end
    end)
end

function Move.stopWalker()
    if Move.walkerThread then
        task.cancel(Move.walkerThread)
        Move.walkerThread = nil
    end
    Move.isWalking = false
end

-- Time for local steering instead of the path walker?
function Move.shouldSteer()
    local pos = State.hrp.Position
    if Bot.staging then
        -- backing off to wait for cooldowns: only an attack should interrupt the walk
        return Zones.dangerNow(pos)
    end
    return Enemies.minDistance(pos) <= Config.ENGAGE_RANGE or Zones.dangerNow(pos)
end

function Move.startWalker(waypoints)
    Move.stopWalker()
    Move.isWalking = true

    Move.walkerThread = task.spawn(function()
        for i = 2, #waypoints do
            local wp = waypoints[i]

            if not State.enabled or not State.alive() or Move.shouldSteer() then break end

            if wp.Action == Enum.PathWaypointAction.Jump then
                State.humanoid.Jump = true
            end
            Move.setGoal(wp.Position)

            local timer = clock()
            while true do
                task.wait(0.05)
                if not State.enabled or not State.alive() or Move.shouldSteer() then
                    Move.isWalking = false
                    Move.walkerThread = nil
                    return
                end
                if (wp.Position - State.hrp.Position).Magnitude <= Config.WAYPOINT_REACHED then break end
                if clock() - timer >= Config.WAYPOINT_TIMEOUT then break end
            end
        end

        Move.isWalking = false
        Move.walkerThread = nil
    end)
end

-- Returns true if a path was started (or the situation changed while it computed, so there's nothing to do).
function Move.computeAndWalk(targetPos)
    local path = PathfindingService:CreatePath({
        AgentHeight = 5,
        AgentRadius = 2,
        AgentCanJump = true,
        AgentCanClimb = false,
    })

    local ok = pcall(function()
        path:ComputeAsync(State.hrp.Position, targetPos)
    end)

    -- state may have changed while the path was computing
    if not State.enabled or not State.alive() or Move.shouldSteer() then
        return true
    end

    if not ok or path.Status ~= Enum.PathStatus.Success then
        return false
    end

    local waypoints = path:GetWaypoints()
    if #waypoints == 0 then
        return false
    end

    Move.lastGoal = targetPos
    ESP.drawGuideline(waypoints)
    Move.startWalker(waypoints)
    return true
end

-- =====================
-- SKILLS: ability detection and casting
-- Each tool has a numeric `cooldown` (-0.1 = ready, otherwise it counts down) and a `cooldownLength`.
-- Skills are scanned from the backpack at runtime, so the bot works with any loadout.
-- =====================
Skills.buffName = nil         -- the buff/rage skill (Inner Rage ...)
Skills.attackName = nil       -- the main attack skill (Gale Barrage ...)
Skills.busy = false
Skills.ownFireUntil = 0       -- attacks that appear before this, close to us, are our own
Skills.rageActiveUntil = 0
Skills.barrageNotBefore = 0
Skills.lastRageUse = -100
Skills.lastBarrageUse = -100
Skills.rageTravelUse = false  -- Inner Rage was used to travel: its cooldown must not hold up the approach
Skills.retryAfter = {}        -- [tool name] = time before which we won't retry a failed ability
Skills.methodThatWorks = {}   -- [tool name] = "event" | "activate" (learned at runtime)
Skills.cooldownTrack = {}     -- [tool name] = { prev, peak, startT, learned }
Skills.info = { rage = nil, barrage = nil, plan = "" }
Skills.rangeTest = nil        -- pending test shot: { barrier, humanoid, health, checkAt }
Skills.survivalCache = { t = 0, slack = math.huge, dist = 0 }
Skills.EVASIVE_MODES = { ["DODGE"] = true, ["AVOID"] = true, ["POCKET"] = true, ["RETREAT"] = true, ["BOXED IN"] = true }

function Skills.isBuff(toolName)
    local n = normalize(toolName)
    for _, buffName in ipairs(Config.BUFF_SKILL_NAMES) do
        if n == buffName then return true end
    end
    return false
end

-- Returns true when the detected skills changed.
function Skills.detect()
    local bestBuff, bestBuffLen = nil, -1
    local bestAttack, bestAttackLen = nil, -1

    local function check(t)
        if not t:IsA("Tool") then return end
        if readNumber(t, "cooldown") == nil then return end   -- no cooldown = not a combat ability the bot manages
        local len = readNumber(t, "cooldownLength") or 0
        if Skills.isBuff(t.Name) then
            if len > bestBuffLen then bestBuffLen, bestBuff = len, t.Name end
        elseif len > bestAttackLen then
            bestAttackLen, bestAttack = len, t.Name
        end
    end

    local bp = player:FindFirstChild("Backpack")
    if bp then for _, t in ipairs(bp:GetChildren()) do check(t) end end
    if player.Character then for _, t in ipairs(player.Character:GetChildren()) do check(t) end end

    local changed = false
    if bestBuff and bestBuff ~= Skills.buffName then
        Skills.buffName = bestBuff
        Log.add("Buff skill: " .. bestBuff)
        changed = true
    end
    if bestAttack and bestAttack ~= Skills.attackName then
        Skills.attackName = bestAttack
        Log.add("Attack skill: " .. bestAttack)
        changed = true
    end
    if changed then UI.refreshSkillLabels() end
    return changed
end

-- Every Tool with a numeric `cooldown`, in the backpack or equipped.
function Skills.collectTracked()
    local tools = {}
    local function scan(container)
        if not container then return end
        for _, t in ipairs(container:GetChildren()) do
            if t:IsA("Tool") and readNumber(t, "cooldown") ~= nil then
                tools[t.Name] = t
            end
        end
    end
    scan(player:FindFirstChild("Backpack"))
    scan(player.Character)
    return tools
end

-- { tool, ready, remaining, length, peak, extra } for a skill, or nil if it isn't carried.
function Skills.get(name, lastUse)
    local tool = findTool(name)
    if not tool then return nil end

    local now = clock()
    local cd = readNumber(tool, "cooldown")
    local length = readNumber(tool, "cooldownLength") or Config.FALLBACK_COOLDOWN
    local ready, remaining

    -- Learn the REAL full cooldown. The game's `cooldown` can start higher than `cooldownLength` (Inner Rage:
    -- 3s buff + 6s cooldown = 9), so remember the highest value seen right after each use.
    local st = Skills.cooldownTrack[name]
    if not st then
        st = { prev = -0.1, peak = 0, startT = -100, learned = nil }
        Skills.cooldownTrack[name] = st
    end
    if cd ~= nil then
        if (st.prev <= Config.COOLDOWN_READY_MAX and cd > Config.COOLDOWN_READY_MAX) or (st.peak == 0 and cd > Config.COOLDOWN_READY_MAX) then
            st.peak, st.startT = cd, now
        elseif cd > st.peak and now - st.startT < 0.6 then
            st.peak = cd
        end
        if st.peak > 0 and now - st.startT >= 0.6 then
            st.learned = st.peak
        end
        st.prev = cd
    end
    local peak = st.learned or length
    local extra = math.max(0, peak - length)   -- time on top of cooldownLength (Inner Rage: the buff time)

    if cd == nil then
        -- no live cooldown value: estimate from our last use and the cooldown length
        remaining = math.max(0, length - (now - lastUse))
        ready = remaining <= 0
    else
        remaining = math.max(cd, 0)
        ready = cd <= Config.COOLDOWN_READY_MAX
    end

    -- the cooldown value can lag a moment behind an activation
    if now - lastUse < Config.ABILITY_MIN_GAP or now < (Skills.retryAfter[name] or 0) then
        ready = false
    end

    return { tool = tool, ready = ready, remaining = remaining, length = length, peak = peak, extra = extra }
end

function Skills.findRemote(tool)
    local ev = tool:FindFirstChild("abilityEvent")
    if ev and ev:IsA("RemoteEvent") then return ev end
    for _, c in ipairs(tool:GetChildren()) do
        if c:IsA("RemoteEvent") then return c end
    end
    return nil
end

-- "event"    = tool.abilityEvent:FireServer()   (how Inner Rage works)
-- "activate" = equip the tool and Activate() it
function Skills.fire(tool, method)
    if method == "event" then
        local ev = Skills.findRemote(tool)
        if not ev then return false end
        ev:FireServer()
        return true
    end

    if tool.Parent ~= player.Character then
        State.humanoid:EquipTool(tool)
        task.wait(Config.EQUIP_DELAY)
    end
    tool:Activate()
    return true
end

-- true = cooldown started, false = it didn't, nil = can't tell
function Skills.cooldownStarted(tool)
    local cd = readNumber(tool, "cooldown")
    if cd == nil then return nil end
    return cd > Config.COOLDOWN_READY_MAX
end

-- Uses an ability: tries the remote event first, then equip+Activate, checks the cooldown really started, and
-- remembers which method worked for that tool. With `aim` it first gives the rotation a moment to reach the
-- server and keeps facing through the cast (the facing itself is Move.drive's job).
function Skills.use(tool, label, aim)
    if Skills.busy then return false end
    Skills.busy = true
    Skills.ownFireUntil = clock() + Config.OWN_PROJECTILE_WINDOW

    task.spawn(function()
        local ok, err = pcall(function()
            local aiming = aim and State.aimEnabled
            if aiming then
                task.wait(Config.AIM_SETTLE)
            end

            if Config.CAST_ONLY_WHEN_SAFE and aim and State.stats.inDanger and not State.stats.shielded then
                Log.add(label .. " cancelled: dodging first")
                Skills.retryAfter[tool.Name] = clock() + 0.5
                return
            end

            local order = { "event", "activate" }
            if Skills.methodThatWorks[tool.Name] == "activate" then
                order = { "activate", "event" }
            end

            local fired = false
            for _, method in ipairs(order) do
                local okCall, sent = pcall(Skills.fire, tool, method)
                if okCall and sent then
                    task.wait(Config.CAST_CONFIRM_WAIT)
                    local started = Skills.cooldownStarted(tool)
                    if started == nil or started then
                        fired = true
                        Skills.methodThatWorks[tool.Name] = method
                        Log.add(label .. " used (" .. method .. ")")
                        break
                    end
                end
            end

            if not fired then
                Skills.retryAfter[tool.Name] = clock() + Config.FAIL_RETRY_DELAY
                Log.add(label .. ": nothing happened (cooldown never started)")
            end

            if aiming and fired then
                task.wait(math.max(0, Config.AIM_HOLD - Config.CAST_CONFIRM_WAIT))
            end
        end)

        if not ok then
            Log.add("ability error: " .. tostring(err))
        end
        Skills.busy = false
    end)

    return true
end

-- ---- Inner Rage as a dodging tool ----

-- Time to spare when escaping the attack we're standing in, at walk speed `speed` (negative = we can't make it
-- in time). Also returns the distance to the nearest way out.
function Skills.escapeSlack(speed)
    local from = State.hrp.Position
    local deadline = Zones.positionDeadline(from)
    if deadline == math.huge then return math.huge, 0 end

    local exitDist = math.huge
    for step = 2, 30, 2 do
        for angle = 0, 330, 30 do
            local r = math.rad(angle)
            local p = from + Vector3.new(math.cos(r) * step, 0, math.sin(r) * step)
            if not Zones.insideDanger(p) and Walls.moveIsClear(from, p) then
                exitDist = step
                break
            end
        end
        if exitDist < math.huge then break end
    end

    if exitDist == math.huge then return -math.huge, 0 end

    return deadline - Tuned.precastSafety - (exitDist / speed + Config.REACTION_TIME), exitDist
end

-- The range to fire from right now, for this npc: its cast range (attack range, kept inside its aggro range), or -
-- at a barrier we can't pass - the closest point we reached plus leeway. A barrier overrides the aggro limit:
-- nothing nearer is possible, so holding fire would just leave the bot idle. Returns the range and whether the
-- npc's aggro range is what limits it.
function Skills.effectiveRange(entry, barrier)
    if barrier and barrier.hits ~= false then
        local range = Learn.rangeFor(entry and entry.model.Name)
        return math.min(math.max(range, (barrier.centerDist or barrier.dist) + Config.BARRIER_LEEWAY), range + Config.BARRIER_RANGE_CAP), false
    end
    return Enemies.castRange(entry)
end

-- Should Inner Rage be spent on its SPEED to survive? Returns a reason string, or nil.
--  A) we're inside an attack and can't get out in time at normal speed (or only barely)
--  B) lots of attacks are closing in and we can't attack anyway (barrage cooling down / out of range)
function Skills.survivalRageReason(now, inDanger, barrage, nearest)
    if not Config.RAGE_FOR_DODGING then return nil end

    local speed = math.max(State.humanoid.WalkSpeed, 8)

    if inDanger then
        local cache = Skills.survivalCache
        if now - cache.t > 0.1 then
            cache.t = now
            cache.slack, cache.dist = Skills.escapeSlack(speed)
        end
        if cache.slack < Config.RAGE_DODGE_SLACK and cache.dist > 0 then
            return string.format("rage to escape (%.1fs to spare)", math.max(cache.slack, -9.9))
        end
    end

    local attackDist, reachEntry = Enemies.nearestCenterDist(State.hrp.Position)   -- skills reach by distance to the npc's CENTRE
    local range = Skills.effectiveRange(reachEntry or nearest, State.stats.barrier)
    local attackPossible = barrage ~= nil and barrage.ready and attackDist <= range

    if not attackPossible then
        local n = Zones.nearbyThreatCount(State.hrp.Position, Config.RAGE_PRESSURE_RADIUS)
        if n >= Config.RAGE_DODGE_MANY then
            return string.format("rage for speed: %d attacks closing in", n)
        end
    end

    return nil
end

-- Used only with CAST_ONLY_WHEN_SAFE: not dodging, not inside or near an attack.
function Skills.safeToCast(now, mode)
    local pos = State.hrp.Position

    if Skills.EVASIVE_MODES[mode] then
        return false, "dodging"
    end
    if Zones.destinationDanger(pos) then
        return false, "inside an attack"
    end
    if Zones.nearbyThreatCount(pos, Config.CAST_THREAT_RADIUS) > 0 then
        return false, "attacks nearby"
    end
    if Zones.dangerClearance(pos) < Config.CAST_MIN_CLEARANCE then
        return false, "too close to an attack"
    end
    return true
end

-- Checks a pending range-calibration test shot once enough time has passed for damage to show up.
function Skills.checkRangeTest(now)
    local test = Skills.rangeTest
    if not test or now < test.checkAt then return end

    local barrier, hum = test.barrier, test.humanoid
    local ok, health = pcall(function() return hum.Health end)
    local dead = (not ok) or (hum.Parent == nil)
    local dropped = dead or (health <= test.health - Config.RANGE_TEST_MIN_DROP)

    if dropped then
        barrier.hits = true
        Log.add("Barrage confirmed hitting from the barrier")
    elseif barrier.testShots >= Config.RANGE_TEST_SHOTS then
        barrier.hits = false
        Log.add(string.format("Barrage isn't reaching from the barrier after %d test shot(s), holding fire", barrier.testShots))
    end

    Skills.rangeTest = nil
end

-- Decision logic (called once per frame after movement):
--  * survival first: Inner Rage's speed can be the difference between dodging and being hit
--  * APPROACH: burn Inner Rage for speed ONLY if it saves a meaningful amount of travel time, otherwise save it for damage
--  * in range: Inner Rage first (damage), a short delay so the buff is on, then the attack skill
function Skills.update(now, mode, nearest, nearestDist, urgent, shielded)
    Skills.checkRangeTest(now)

    local rage = Skills.buffName and Skills.get(Skills.buffName, Skills.lastRageUse) or nil
    local barrage = Skills.attackName and Skills.get(Skills.attackName, Skills.lastBarrageUse) or nil

    Skills.info.rage = rage
    Skills.info.barrage = barrage
    Skills.info.plan = ""

    if Skills.busy or not nearest then return end

    if shielded then
        Skills.info.plan = "spawn shield: all-in attack"
    end

    -- a cooldown above cooldownLength means the buff is still running
    local rageActive = now < Skills.rageActiveUntil or (rage ~= nil and rage.remaining > rage.length + 0.3)

    local function fireRage(reason, forTravel)
        if Skills.use(rage.tool, Skills.buffName, false) then
            Skills.lastRageUse = now
            Skills.rageActiveUntil = now + ((rage.extra or 0) >= 0.5 and rage.extra or Config.RAGE_DURATION)
            Skills.rageTravelUse = forTravel == true
            Skills.info.plan = reason
            return true
        end
        return false
    end

    if rage and rage.ready and not rageActive and not shielded then
        local why = Skills.survivalRageReason(now, urgent, barrage, nearest)
        if why and fireRage(why) then
            return
        end
    end

    if urgent and Config.CAST_ONLY_WHEN_SAFE then
        Skills.info.plan = "inside an attack, abilities paused"
        return
    end

    -- 1) rage for speed on the way in
    if mode == "APPROACH" and rage then
        if rageActive then
            Skills.info.plan = "raging, closing in"
        elseif rage.ready then
            local remainingDist = math.max(0, nearestDist - Config.ENGAGE_RANGE)
            local base = math.max(State.humanoid.WalkSpeed, 1)
            local travelTime = remainingDist / (base * Config.RAGE_SPEED_MULT)
            local saved = remainingDist / base - travelTime
            local lostTime = math.max(0, rage.length - travelTime)   -- how long we'd be WITHOUT rage after arriving

            if shielded and remainingDist > 10 then
                -- just respawned: sprint to the target with the extra speed while we're immortal
                if fireRage("respawn sprint: rage to reach the target faster", true) then
                    return
                end
            elseif saved >= Config.RAGE_TRAVEL_MIN_SAVED and lostTime <= Config.RAGE_TRAVEL_MAX_LOSS then
                if fireRage(string.format("rage for travel (saves ~%.1fs)", saved), true) then
                    return
                end
            else
                Skills.info.plan = string.format("saving rage for damage (%.0fs cd)", rage.length)
            end
        end
    end

    -- 2) the attack skill when in range
    if not barrage then
        if Skills.info.plan == "" then Skills.info.plan = "no attack skill in backpack" end
        return
    end

    if not barrage.ready then
        if Skills.info.plan == "" then
            Skills.info.plan = string.format("barrage cooldown %.1fs", barrage.remaining)
        end
        return
    end

    -- at a barrier we can't get any closer, so fire from the closest point we reached (plus leeway) - UNLESS
    -- test shots already showed it doesn't actually reach that far, in which case don't bother
    local barrier = State.stats.barrier
    if barrier and barrier.hits == false then
        Skills.info.plan = "barrage confirmed not reaching from the barrier, holding"
        return
    end

    -- measured to the npc's CENTRE: a massive body makes its edge look much closer than it really is
    local attackDist, reachEntry = Enemies.nearestCenterDist(State.hrp.Position)
    local range, byAggro = Skills.effectiveRange(reachEntry or nearest, barrier)
    if attackDist > range then
        Skills.info.plan = string.format("barrage ready, out of range (%.0f / %.0f%s)", attackDist, range, byAggro and ", inside its aggro range" or "")
        return
    end

    if Config.BARRAGE_REQUIRE_LOS and not Walls.hasLineOfSight(State.hrp.Position, nearest.pos) then
        Skills.info.plan = "barrage ready, no line of sight"
        return
    end

    -- only cast from a safe moment (a freshly respawned, immortal character attacks right away)
    if not shielded and Config.CAST_ONLY_WHEN_SAFE then
        local safe, why = Skills.safeToCast(now, mode)
        if not safe then
            Skills.info.plan = "holding for a safe moment (" .. why .. ")"
            return
        end
    end

    if rage and not rageActive then
        if rage.ready then
            if fireRage("rage first, then barrage") then
                Skills.barrageNotBefore = now + Config.RAGE_TO_ATTACK_DELAY
            end
            return
        elseif Config.HOLD_BARRAGE_FOR_RAGE and not shielded and rage.remaining > 0
            and rage.remaining <= math.min(Config.RAGE_WAIT_MAX, barrage.length * 0.3) then
            Skills.info.plan = string.format("holding barrage for rage (%.1fs)", rage.remaining)
            return
        end
    end

    if now < Skills.barrageNotBefore then
        Skills.info.plan = "buff ramping up"
        return
    end

    -- at an untested barrier this cast doubles as a test shot, so we learn whether it actually connects
    local testing = barrier ~= nil and barrier.hits == nil and barrier.testShots < Config.RANGE_TEST_SHOTS
    local testHum = testing and nearest.humanoid

    if Skills.use(barrage.tool, Skills.attackName, true) then
        Skills.lastBarrageUse = now
        Skills.info.plan = testing and "barrage fired (test shot)" or "barrage fired"

        if testing and testHum then
            barrier.testShots = barrier.testShots + 1
            Skills.rangeTest = { barrier = barrier, humanoid = testHum, health = testHum.Health, checkAt = now + Config.RANGE_TEST_WAIT }
        end
    end
end

-- =====================
-- RECORD
--  MANUAL - you press Record and play by hand. Full detail: movement, npcs, attacks, avoidance, npc movement,
--           cooldown waiting. Saved under <dungeon>/manual/.
--  AUTO   - runs quietly the whole time, no button needed: only watches ability casts and whether they land.
-- Ability detection (the part both tracks share) runs every frame; the rest only while recording.
-- =====================
Record.active = false
Record.startT = 0
Record.samples = {}
Record.damageEvents = {}
Record.avoidedEvents = {}
Record.lastSampleT = 0
Record.lastOwnHealth = nil
Record.pendingHits = {}       -- awaiting a health check: { ability, checkAt, targets, viaBot }
Record.trackedZones = {}      -- [zone key] = { kind, firstSeen, closestDist, damaged }
Record.npcLastPos = setmetatable({}, { __mode = "k" })   -- [npc model] = last position (keyed by model: two npcs can share a name)
Record.npcMovement = {}
Record.cooldownEpisodes = {}
Record.episode = nil
Record.cooldownSeen = {}      -- [tool name] = last cooldown value seen (edge-detects a cast)
-- running totals, so the UI and the report never re-walk thousands of samples
Record.nearestSum, Record.nearestCount = 0, 0
Record.attackSum, Record.attackCount = 0, 0

local function round1(x)
    return math.floor(x * 10) / 10
end

function Record.start()
    Record.active = true
    Record.startT = clock()
    Record.lastSampleT = 0
    Record.lastOwnHealth = nil
    for _, t in ipairs({ Record.samples, Record.damageEvents, Record.avoidedEvents, Record.pendingHits,
        Learn.manual, Learn.manualByTarget, Record.trackedZones, Record.npcLastPos, Record.npcMovement,
        Record.cooldownEpisodes }) do
        table.clear(t)
    end
    Record.episode = nil
    Record.nearestSum, Record.nearestCount, Record.attackSum, Record.attackCount = 0, 0, 0, 0
    Log.add("Manual recording started (movement, skills + distance per npc, attacks, avoidance, npc movement, cooldown waiting)")
end

function Record.stop()
    Record.active = false

    for _, z in pairs(Record.trackedZones) do
        if not z.damaged and #Record.avoidedEvents < Config.RECORD_MAX_EVENTS then
            table.insert(Record.avoidedEvents, { kind = z.kind, closestDist = z.closestDist, duration = clock() - z.firstSeen })
        end
    end
    table.clear(Record.trackedZones)

    local any = false
    for name, dist in pairs(Learn.manual) do
        any = true
        Log.add(string.format("Learned: %s connects from at least %.0f studs", name, dist))
    end
    for ability, byName in pairs(Learn.manualByTarget) do
        for npcName, dist in pairs(byName) do
            Log.add(string.format("Learned: %s vs %s connects from at least %.0f studs", ability, npcName, dist))
        end
    end
    if not any then
        Log.add("No confirmed hits to learn a range from (try landing a few casts next time)")
    end

    if Record.nearestCount > 0 then
        Log.add(string.format("Average distance kept from the nearest npc: %.0f studs", Record.nearestSum / Record.nearestCount))
    end
    if Record.attackCount > 0 then
        Log.add(string.format("Average distance kept from the nearest attack: %.0f studs", Record.attackSum / Record.attackCount))
    end

    if #Record.damageEvents > 0 then
        local byKind = {}
        for _, e in ipairs(Record.damageEvents) do
            local key = e.attacks[1] and e.attacks[1].kind or "unknown"
            byKind[key] = (byKind[key] or 0) + 1
        end
        local parts = {}
        for k, n in pairs(byKind) do table.insert(parts, string.format("%s x%d", k, n)) end
        Log.add(string.format("Took damage %d time(s) - nearest attack when it happened: %s", #Record.damageEvents, table.concat(parts, ", ")))
    else
        Log.add("No damage taken during the recording")
    end

    if #Record.avoidedEvents > 0 then
        local byKind, totalClose = {}, 0
        for _, e in ipairs(Record.avoidedEvents) do
            byKind[e.kind] = (byKind[e.kind] or 0) + 1
            totalClose = totalClose + e.closestDist
        end
        local parts = {}
        for k, n in pairs(byKind) do table.insert(parts, string.format("%s x%d", k, n)) end
        Log.add(string.format("Avoided %d attack(s) (%s), average closest distance %.0f studs",
            #Record.avoidedEvents, table.concat(parts, ", "), totalClose / #Record.avoidedEvents))
    end

    local movers = {}
    for name, dist in pairs(Record.npcMovement) do
        if dist >= Config.RECORD_NPC_MOVE_MIN then table.insert(movers, name .. string.format(" (~%.0f studs)", dist)) end
    end
    if #movers > 0 then
        Log.add("NPCs that moved during the recording: " .. table.concat(movers, ", "))
    else
        Log.add("No npc movement observed")
    end

    if #Record.cooldownEpisodes > 0 then
        local backedOff = 0
        for _, e in ipairs(Record.cooldownEpisodes) do
            if e.backedOff then backedOff = backedOff + 1 end
        end
        Log.add(string.format("Between casts: backed off to wait for cooldowns %d/%d time(s), stayed in the fight the other %d",
            backedOff, #Record.cooldownEpisodes, #Record.cooldownEpisodes - backedOff))
    end

    Store.saveRun({
        duration = clock() - Record.startT,
        samples = Record.samples,
        damageEvents = Record.damageEvents,
        avoidedEvents = Record.avoidedEvents,
        npcMovement = Record.npcMovement,
        learnedRanges = Learn.manual,
        learnedRangesByTarget = Learn.manualByTarget,
    })
    Store.update("manual ranges", function(data)
        return Learn.mergeBank(data.manual, Learn.manual, Learn.manualByTarget)
    end)
end

-- Watches every tracked tool's cooldown for a ready->cooling edge (a cast, by you or the bot), snapshots nearby
-- npc health, and a moment later checks whether it dropped (= the cast connected from that distance).
function Record.updateAbilityDetection(now)
    for i = #Record.pendingHits, 1, -1 do
        local p = Record.pendingHits[i]
        if now >= p.checkAt then
            local anyHit = false
            for _, tgt in ipairs(p.targets) do
                local ok, health = pcall(function() return tgt.hum.Health end)
                local dead = (not ok) or tgt.hum.Parent == nil
                if dead or (ok and health <= tgt.health - Config.RECORD_MIN_DROP) then
                    Learn.noteHit(p.ability, tgt.name, tgt.dist, p.viaBot)
                    anyHit = true
                end
            end

            -- Miss detection: the bot fired but nothing took damage within the window. Most likely the shot fell
            -- short, so gently shrink the working range and the bot will be closer before it fires next time.
            -- Only for bot casts of the main skill, and never below what keeps us out of the npc's body.
            if not anyHit and p.viaBot and p.ability == Skills.attackName then
                local currentRange = Learn.applied[p.ability] or Tuned.barrageRange
                local missRange = p.targets[1] and p.targets[1].dist or currentRange
                if missRange >= currentRange * 0.85 then   -- only if the miss was plausibly within the working range
                    local newRange = math.max(Config.MIN_DISTANCE + Config.RANGE_MARGIN + 4, currentRange - 5)
                    if newRange < currentRange then
                        Tuned.barrageRange = math.ceil(newRange)
                        Learn.applied[p.ability] = newRange
                        Log.add(string.format("Attacks not hitting - closing in (range now %d)", Tuned.barrageRange))
                    end
                end
            end

            table.remove(Record.pendingHits, i)
        end
    end

    if not State.hrp then return end

    for name, tool in pairs(Skills.collectTracked()) do
        local cd = readNumber(tool, "cooldown")
        if cd ~= nil then
            local prev = Record.cooldownSeen[name]
            local isAttack = name == Skills.attackName

            if prev ~= nil and prev <= Config.COOLDOWN_READY_MAX and cd > Config.COOLDOWN_READY_MAX then
                local targets = {}
                for _, e in ipairs(Enemies.list) do
                    if e.humanoid then
                        local ok, health = pcall(function() return e.humanoid.Health end)
                        if ok then
                            table.insert(targets, {
                                hum = e.humanoid, health = health, name = e.model.Name,
                                dist = flat(State.hrp.Position - e.pos).Magnitude,
                            })
                        end
                    end
                end
                if #targets > 0 then
                    table.insert(Record.pendingHits, { ability = name, checkAt = now + Config.RECORD_HIT_WINDOW, targets = targets, viaBot = State.enabled })
                end

                if isAttack and Record.active then
                    local _, nd = Enemies.nearestFrom(State.hrp.Position)
                    Record.episode = { startDist = (nd < math.huge) and nd or nil, maxDist = 0 }
                end
            end

            if isAttack and Record.episode and cd > Config.COOLDOWN_READY_MAX then
                local _, nd = Enemies.nearestFrom(State.hrp.Position)
                if nd < math.huge and nd > Record.episode.maxDist then
                    Record.episode.maxDist = nd
                end
            end

            if isAttack and Record.episode and prev ~= nil and prev > Config.COOLDOWN_READY_MAX and cd <= Config.COOLDOWN_READY_MAX then
                if #Record.cooldownEpisodes < Config.RECORD_MAX_EVENTS then
                    table.insert(Record.cooldownEpisodes, { backedOff = Record.episode.maxDist > Config.ENGAGE_RANGE, maxDist = Record.episode.maxDist })
                end
                Record.episode = nil
            end

            Record.cooldownSeen[name] = cd
        end
    end
end

-- Called once per frame regardless of mode.
function Record.heartbeat(now)
    Record.updateAbilityDetection(now)
    if not Record.active or not State.hrp then return end

    local pos = State.hrp.Position

    for part, info in pairs(Zones.active) do
        local z = Record.trackedZones[part]
        if not z then
            z = { kind = info.kind, firstSeen = now, closestDist = math.huge, damaged = false }
            Record.trackedZones[part] = z
        end
        z.closestDist = math.min(z.closestDist, flat(pos - info.pos).Magnitude)
    end
    for part, z in pairs(Record.trackedZones) do
        if not Zones.active[part] then
            if not z.damaged and #Record.avoidedEvents < Config.RECORD_MAX_EVENTS then
                table.insert(Record.avoidedEvents, { kind = z.kind, closestDist = z.closestDist, duration = now - z.firstSeen })
            end
            Record.trackedZones[part] = nil
        end
    end

    Enemies.refresh(0.05)
    for _, e in ipairs(Enemies.list) do
        local name = e.model.Name
        local last = Record.npcLastPos[e.model]
        if last then
            Record.npcMovement[name] = (Record.npcMovement[name] or 0) + flat(e.pos - last).Magnitude
        end
        Record.npcLastPos[e.model] = e.pos
    end

    if now - Record.lastSampleT < Config.RECORD_SAMPLE_RATE then return end
    Record.lastSampleT = now

    local ownHum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
    local ownHealth = ownHum and ownHum.Health or nil
    local _, nd = Enemies.nearestFrom(pos)

    local npcList = {}
    for _, e in ipairs(Enemies.list) do
        table.insert(npcList, { e = e, d = flat(pos - e.pos).Magnitude })
    end
    table.sort(npcList, function(a, b) return a.d < b.d end)
    local npcSnap = {}
    for i = 1, math.min(Config.RECORD_NEARBY_NPCS, #npcList) do
        local e = npcList[i].e
        table.insert(npcSnap, {
            name = e.model.Name, dist = round1(npcList[i].d),
            x = round1(e.pos.X), z = round1(e.pos.Z),
            health = e.humanoid and e.humanoid.Health or nil,
        })
    end

    local atkList = {}
    for _, info in pairs(Zones.active) do
        table.insert(atkList, { info = info, d = flat(pos - info.pos).Magnitude })
    end
    table.sort(atkList, function(a, b) return a.d < b.d end)
    local atkSnap = {}
    for i = 1, math.min(Config.RECORD_NEARBY_ATKS, #atkList) do
        local info = atkList[i].info
        table.insert(atkSnap, {
            kind = info.kind, dist = round1(atkList[i].d),
            timeLeft = (info.kind == "precast") and math.max(0, round1(Zones.timeLeft(info, now))) or 0,
        })
    end

    if #Record.samples < Config.RECORD_MAX_SAMPLES then
        local look = State.hrp.CFrame.LookVector
        table.insert(Record.samples, {
            t = round1(now - Record.startT),
            x = round1(pos.X), z = round1(pos.Z),
            facing = round1(math.deg(math.atan2(look.X, look.Z))),
            health = ownHealth,
            nearestDist = (nd < math.huge) and round1(nd) or nil,
            npcs = npcSnap, attacks = atkSnap,
        })
        if nd < math.huge then
            Record.nearestSum, Record.nearestCount = Record.nearestSum + nd, Record.nearestCount + 1
        end
        if atkSnap[1] then
            Record.attackSum, Record.attackCount = Record.attackSum + atkSnap[1].dist, Record.attackCount + 1
        end
    end

    if ownHealth == nil then return end
    if Record.lastOwnHealth ~= nil and ownHealth < Record.lastOwnHealth - Config.RECORD_MIN_DROP then
        if #Record.damageEvents < Config.RECORD_MAX_EVENTS then
            table.insert(Record.damageEvents, {
                t = round1(now - Record.startT), health = ownHealth,
                drop = round1(Record.lastOwnHealth - ownHealth),
                attacks = atkSnap, npcs = npcSnap,
            })
        end

        -- blame the nearest tracked attack if one is plausibly responsible
        local bestPart, bestDist = nil, math.huge
        for part in pairs(Record.trackedZones) do
            local info = Zones.active[part]
            local d = info and flat(pos - info.pos).Magnitude or math.huge
            if d < bestDist then bestPart, bestDist = part, d end
        end
        if bestPart and bestDist <= 10 then
            Record.trackedZones[bestPart].damaged = true
        else
            -- nothing tracked was close enough to explain this hit: same unrecognised-attack learning as a
            -- death, just from a non-fatal hit during a recorded run
            local suspect, suspectDist = Zones.findSuspect(pos)
            if suspect and not Learn.attackNames[suspect] then
                Log.add(string.format("Took damage from something unrecognised: \"%s\" (%.0f studs away) - now treated as an attack", suspect, suspectDist))
                Learn.addAttackName(suspect)
            end
        end
    end
    Record.lastOwnHealth = ownHealth
end

-- =====================
-- ESP (everything here follows the ESP toggle)
-- =====================
ESP.enemies = {}            -- [model] = { hl, gui, label, disc }
ESP.guidelineParts = {}
ESP.lastLabelUpdate = 0
ESP.COL_RED    = Color3.fromRGB(255, 70, 70)
ESP.COL_ORANGE = Color3.fromRGB(255, 165, 0)
ESP.COL_GREEN  = Color3.fromRGB(80, 255, 140)
ESP.COL_WHITE  = Color3.new(1, 1, 1)

-- Everything the bot draws lives in this folder (and is excluded from the wall raycasts).
function ESP.folder()
    local folder = workspace:FindFirstChild("_GuidelineFolder")
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = "_GuidelineFolder"
        folder.Parent = workspace
    end
    return folder
end

function ESP.newMarker(name, shape, color)
    local p = Instance.new("Part")
    p.Name = name
    p.Anchored = true
    p.CanCollide = false
    p.CanQuery = false
    p.CanTouch = false
    p.CastShadow = false
    p.Shape = shape
    p.Material = Enum.Material.Neon
    p.Color = color
    p.Transparency = 1
    p.Parent = ESP.folder()
    return p
end

function ESP.init()
    ESP.ring = ESP.newMarker("_GroupRing", Enum.PartType.Cylinder, Color3.fromRGB(0, 200, 255))
    ESP.goal = ESP.newMarker("_SteerGoal", Enum.PartType.Ball, Color3.fromRGB(255, 255, 0))
    ESP.goal.Size = Vector3.new(0.8, 0.8, 0.8)
    ESP.tracer = ESP.newMarker("_Tracer", Enum.PartType.Block, Color3.fromRGB(80, 255, 140))
    ESP.tracer.Size = Vector3.new(0.08, 0.08, 1)
end

function ESP.setVisible(inst, on)
    if inst:IsA("BillboardGui") then
        inst.Enabled = on and Config.ESP_LABELS
    elseif inst:IsA("BasePart") then
        inst.Transparency = on and 0.35 or 1
    else
        inst.Visible = on
    end
end

function ESP.makeAttackLabel(adornee, height)
    local gui = Instance.new("BillboardGui")
    gui.Name = "_AttackLabel"
    gui.Adornee = adornee
    gui.AlwaysOnTop = true
    gui.Size = UDim2.fromOffset(130, 16)
    gui.StudsOffsetWorldSpace = Vector3.new(0, height, 0)
    gui.Enabled = State.espEnabled and Config.ESP_LABELS
    gui.Parent = adornee

    local text = Instance.new("TextLabel")
    text.Size = UDim2.fromScale(1, 1)
    text.BackgroundTransparency = 1
    text.Font = Enum.Font.GothamBold
    text.TextSize = 11
    text.TextColor3 = Color3.new(1, 1, 1)
    text.TextStrokeTransparency = 0.3
    text.Text = ""
    text.Parent = gui

    return gui, text
end

function ESP.clearGuideline()
    for _, p in ipairs(ESP.guidelineParts) do destroy(p) end
    ESP.guidelineParts = {}
end

function ESP.drawGuideline(waypoints)
    ESP.clearGuideline()
    if not State.espEnabled then return end
    local folder = ESP.folder()

    for i = 1, #waypoints - 1 do
        local a, b = waypoints[i].Position, waypoints[i + 1].Position
        local dist = (b - a).Magnitude
        if dist > 0 then
            local mid = (a + b) / 2
            local beam = Instance.new("Part")
            beam.Anchored = true
            beam.CanCollide = false
            beam.CanQuery = false
            beam.CastShadow = false
            beam.Size = Vector3.new(0.12, 0.12, dist)
            beam.CFrame = CFrame.lookAt(mid, mid + (b - a).Unit)
            beam.Material = Enum.Material.Neon
            beam.Color = Color3.fromRGB(0, 255, 150)
            beam.Transparency = 0.2
            beam.Parent = folder
            table.insert(ESP.guidelineParts, beam)
        end
    end

    if #waypoints > 0 then
        local endDot = Instance.new("Part")
        endDot.Anchored = true
        endDot.CanCollide = false
        endDot.CanQuery = false
        endDot.CastShadow = false
        endDot.Shape = Enum.PartType.Ball
        endDot.Size = Vector3.new(0.55, 0.55, 0.55)
        endDot.Position = waypoints[#waypoints].Position + Vector3.new(0, 0.1, 0)
        endDot.Material = Enum.Material.Neon
        endDot.Color = Color3.fromRGB(255, 50, 50)
        endDot.Parent = folder
        table.insert(ESP.guidelineParts, endDot)
    end
end

function ESP.updateRing(group)
    if not group or not State.espEnabled then
        ESP.ring.Transparency = 1
        return
    end
    local d = Steer.ringRadiusFor(group) * 2
    ESP.ring.Size = Vector3.new(0.12, d, d)
    ESP.ring.CFrame = CFrame.new(group.centroid.X, group.centroid.Y - 2.5, group.centroid.Z) * CFrame.Angles(0, 0, math.pi / 2)
    ESP.ring.Transparency = 0.88
end

function ESP.updateGoalMarker(pos)
    if pos and State.espEnabled then
        ESP.goal.Position = pos
        ESP.goal.Transparency = 0.2
    else
        ESP.goal.Transparency = 1
    end
end

function ESP.createEnemy(entry)
    local data = {}

    local hl = Instance.new("Highlight")
    hl.Name = "_EnemyESP"
    hl.OutlineTransparency = 0
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Adornee = entry.model
    hl.Enabled = State.espEnabled
    hl.Parent = entry.model
    data.hl = hl

    local gui = Instance.new("BillboardGui")
    gui.Name = "_EnemyLabel"
    gui.Adornee = entry.part
    gui.AlwaysOnTop = true
    gui.Size = UDim2.fromOffset(150, 16)
    gui.StudsOffsetWorldSpace = Vector3.new(0, 5, 0)
    gui.Enabled = State.espEnabled and Config.ESP_LABELS
    gui.Parent = entry.part
    data.gui = gui

    local text = Instance.new("TextLabel")
    text.Size = UDim2.fromScale(1, 1)
    text.BackgroundTransparency = 1
    text.Font = Enum.Font.GothamBold
    text.TextSize = 11
    text.TextColor3 = ESP.COL_WHITE
    text.TextStrokeTransparency = 0.3
    text.Text = ""
    text.Parent = gui
    data.label = text

    if Config.ESP_SAFETY_DISCS then
        local disc = ESP.newMarker("_SafetyDisc", Enum.PartType.Cylinder, ESP.COL_RED)
        disc.Material = Enum.Material.SmoothPlastic
        disc.Size = Vector3.new(0.12, Config.MIN_DISTANCE * 2, Config.MIN_DISTANCE * 2)
        data.disc = disc
    end

    ESP.enemies[entry.model] = data
    return data
end

function ESP.destroyEnemy(data)
    for _, key in ipairs({ "hl", "gui", "disc" }) do
        destroy(data[key])
    end
end

function ESP.updateEnemies(now, target)
    -- drop esp for npcs that are gone
    local alive = {}
    for _, e in ipairs(Enemies.list) do alive[e.model] = true end
    for model, data in pairs(ESP.enemies) do
        if not alive[model] or not model.Parent then
            ESP.destroyEnemy(data)
            ESP.enemies[model] = nil
        end
    end

    local on = State.espEnabled
    local refreshText = now - ESP.lastLabelUpdate >= 0.1
    if refreshText then ESP.lastLabelUpdate = now end

    for _, e in ipairs(Enemies.list) do
        local data = ESP.enemies[e.model] or ESP.createEnemy(e)
        local isTarget = target ~= nil and e.model == target.model
        local dist = flat(State.hrp.Position - e.pos).Magnitude - e.radius
        local tooClose = dist < Config.MIN_DISTANCE

        data.hl.Enabled = on
        data.hl.FillColor = isTarget and ESP.COL_RED or ESP.COL_ORANGE
        data.hl.OutlineColor = isTarget and ESP.COL_RED or Color3.fromRGB(200, 100, 0)
        data.hl.FillTransparency = isTarget and 0.4 or 0.7

        data.gui.Enabled = on and Config.ESP_LABELS
        if refreshText then
            data.label.Text = string.format("%s%s [G%d]  %.0f", isTarget and "> " or "", e.model.Name, e.gid or 0, dist)
            data.label.TextColor3 = tooClose and ESP.COL_RED or (isTarget and ESP.COL_GREEN or ESP.COL_WHITE)
        end

        if data.disc then
            if on then
                data.disc.CFrame = CFrame.new(e.pos.X, e.pos.Y - 2.8, e.pos.Z) * CFrame.Angles(0, 0, math.pi / 2)
                local dd = (Config.MIN_DISTANCE + e.radius) * 2
                data.disc.Size = Vector3.new(0.12, dd, dd)
                data.disc.Transparency = tooClose and 0.75 or 0.93
            else
                data.disc.Transparency = 1
            end
        end
    end

    -- tracer from us to the locked target
    if on and target then
        local a, b = State.hrp.Position, target.pos
        local len = (b - a).Magnitude
        if len > 1 then
            ESP.tracer.Size = Vector3.new(0.08, 0.08, len)
            ESP.tracer.CFrame = CFrame.lookAt((a + b) / 2, b)
            ESP.tracer.Color = len < Config.MIN_DISTANCE and ESP.COL_RED or ESP.COL_GREEN
            ESP.tracer.Transparency = 0.4
        end
    else
        ESP.tracer.Transparency = 1
    end
end

-- Master switch used by the UI button.
function ESP.setAll(on)
    State.espEnabled = on
    Zones.setESP(on)
    Walls.setESP(on)

    for _, data in pairs(ESP.enemies) do
        data.hl.Enabled = on
        data.gui.Enabled = on and Config.ESP_LABELS
        if data.disc and not on then data.disc.Transparency = 1 end
    end

    if not on then
        ESP.clearGuideline()
        ESP.ring.Transparency = 1
        ESP.goal.Transparency = 1
        ESP.tracer.Transparency = 1
    end

    Log.add(on and "ESP on" or "ESP off")
end

function ESP.destroyAll()
    for _, data in pairs(ESP.enemies) do ESP.destroyEnemy(data) end
    ESP.enemies = {}
    ESP.clearGuideline()
    destroy(workspace:FindFirstChild("_GuidelineFolder"))
end

-- =====================
-- UI
-- =====================
UI.refs = {}
UI.gui = nil
UI.orderCounters = setmetatable({}, { __mode = "k" })

UI.C = {
    bg     = Color3.fromRGB(14, 16, 24),
    card   = Color3.fromRGB(24, 27, 38),
    track  = Color3.fromRGB(38, 43, 58),
    line   = Color3.fromRGB(52, 58, 80),
    text   = Color3.fromRGB(232, 235, 246),
    dim    = Color3.fromRGB(128, 136, 160),
    green  = Color3.fromRGB(88, 222, 138),
    red    = Color3.fromRGB(255, 92, 92),
    orange = Color3.fromRGB(255, 172, 72),
    blue   = Color3.fromRGB(94, 176, 255),
    purple = Color3.fromRGB(190, 124, 255),
    yellow = Color3.fromRGB(255, 212, 96),
    grey   = Color3.fromRGB(150, 156, 176),
}
UI.BUTTON_BG = Color3.fromRGB(30, 33, 46)

UI.STATE_COLORS = {
    ["DODGE"]     = UI.C.red,
    ["KEEP AWAY"] = UI.C.orange,
    ["AVOID"]     = UI.C.orange,
    ["CIRCLE"]    = UI.C.blue,
    ["APPROACH"]  = UI.C.green,
    ["BOXED IN"]  = UI.C.purple,
    ["HOLD"]      = UI.C.grey,
    ["IDLE"]      = UI.C.grey,
    ["OFF"]       = UI.C.grey,
    ["DEAD"]      = UI.C.grey,
    ["RETREAT"]   = Color3.fromRGB(255, 128, 128),
    ["SIEGE"]     = UI.C.yellow,
    ["POCKET"]    = Color3.fromRGB(255, 112, 208),
    ["WAITING"]   = Color3.fromRGB(138, 180, 255),
    ["ALL-IN"]    = Color3.fromRGB(255, 64, 64),
    ["BACK OFF"]  = Color3.fromRGB(255, 176, 96),
}

function UI.hex(c)
    return string.format("#%02x%02x%02x", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

function UI.esc(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

function UI.col(c, text)
    return string.format('<font color="%s">%s</font>', UI.hex(c), text)
end

-- ---- small building blocks ----

function UI.nextOrder(parent)
    UI.orderCounters[parent] = (UI.orderCounters[parent] or 0) + 1
    return UI.orderCounters[parent]
end

function UI.corner(inst, radius)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, radius)
    c.Parent = inst
    return c
end

function UI.outline(inst, color, thickness, transparency)
    local s = Instance.new("UIStroke")
    s.Color = color
    s.Thickness = thickness or 1
    s.Transparency = transparency or 0
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    s.Parent = inst
    return s
end

function UI.padding(inst, l, t, r, b)
    local p = Instance.new("UIPadding")
    p.PaddingLeft, p.PaddingTop, p.PaddingRight, p.PaddingBottom = UDim.new(0, l), UDim.new(0, t), UDim.new(0, r), UDim.new(0, b)
    p.Parent = inst
    return p
end

function UI.vlist(inst, gap)
    local l = Instance.new("UIListLayout")
    l.SortOrder = Enum.SortOrder.LayoutOrder
    l.Padding = UDim.new(0, gap)
    l.Parent = inst
    return l
end

function UI.hlist(inst, gap)
    local l = UI.vlist(inst, gap)
    l.FillDirection = Enum.FillDirection.Horizontal
    return l
end

function UI.label(parent, size, font, color, xalign)
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Font = font
    l.TextSize = size
    l.TextColor3 = color
    l.TextXAlignment = xalign or Enum.TextXAlignment.Left
    l.RichText = true
    l.Text = ""
    l.Parent = parent
    return l
end

function UI.card(parent, title)
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, 0, 0, 0)
    f.AutomaticSize = Enum.AutomaticSize.Y
    f.BackgroundColor3 = UI.C.card
    f.BorderSizePixel = 0
    f.LayoutOrder = UI.nextOrder(parent)
    f.Parent = parent
    UI.corner(f, 9)
    UI.outline(f, UI.C.line, 1, 0.45)
    UI.padding(f, 10, 8, 10, 8)
    UI.vlist(f, 5)

    if title then
        local t = UI.label(f, 11, Enum.Font.GothamBold, UI.C.dim)
        t.Size = UDim2.new(1, 0, 0, 13)
        t.LayoutOrder = UI.nextOrder(f)
        t.Text = title
    end
    return f
end

-- "Key ........ value" row; returns the value label and the key label
function UI.row(parent, key)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 18)
    row.BackgroundTransparency = 1
    row.LayoutOrder = UI.nextOrder(parent)
    row.Parent = parent

    local k = UI.label(row, 13, Enum.Font.Gotham, UI.C.dim)
    k.Size = UDim2.new(0.34, 0, 1, 0)
    k.Text = key

    local v = UI.label(row, 13, Enum.Font.GothamMedium, UI.C.text, Enum.TextXAlignment.Right)
    v.Size = UDim2.new(0.66, 0, 1, 0)
    v.Position = UDim2.fromScale(0.34, 0)
    v.TextTruncate = Enum.TextTruncate.AtEnd
    return v, k
end

function UI.bar(parent, height)
    local track = Instance.new("Frame")
    track.Size = UDim2.new(1, 0, 0, height or 6)
    track.BackgroundColor3 = UI.C.track
    track.BorderSizePixel = 0
    track.LayoutOrder = UI.nextOrder(parent)
    track.Parent = parent
    UI.corner(track, 3)

    local fill = Instance.new("Frame")
    fill.Size = UDim2.fromScale(0, 1)
    fill.BackgroundColor3 = UI.C.green
    fill.BorderSizePixel = 0
    fill.Parent = track
    UI.corner(fill, 3)

    return { track = track, fill = fill, frac = 0 }
end

function UI.setBar(bar, frac, color)
    frac = math.clamp(frac, 0, 1)
    if math.abs(frac - bar.frac) > 0.004 then   -- no tween for an unchanged bar (10 updates/s x 6 bars adds up)
        bar.frac = frac
        TweenService:Create(bar.fill, TweenInfo.new(0.12, Enum.EasingStyle.Quad), { Size = UDim2.fromScale(frac, 1) }):Play()
    end
    bar.fill.BackgroundColor3 = color
end

function UI.chip(parent, color, order)
    local chip = Instance.new("TextLabel")
    chip.Size = UDim2.new(1 / 4, -4, 1, 0)
    chip.BackgroundColor3 = color
    chip.BackgroundTransparency = 0.85
    chip.BorderSizePixel = 0
    chip.Font = Enum.Font.GothamBold
    chip.TextSize = 12
    chip.TextColor3 = color
    chip.Text = ""
    chip.LayoutOrder = order
    chip.Parent = parent
    UI.corner(chip, 6)
    return chip
end

function UI.styleToggle(btn, strokeInst, label, on)
    btn.Text = label .. (on and "  ON" or "  OFF")
    btn.BackgroundColor3 = on and Color3.fromRGB(26, 74, 50) or UI.BUTTON_BG
    btn.TextColor3 = on and UI.C.green or UI.C.dim
    strokeInst.Color = on and UI.C.green or UI.C.line
    strokeInst.Transparency = on and 0.35 or 0.2
end

-- a text button; returns the button and its outline
function UI.button(parent, size, textSize, text)
    local b = Instance.new("TextButton")
    b.Size = size
    b.AutoButtonColor = false
    b.BorderSizePixel = 0
    b.Font = Enum.Font.GothamBold
    b.TextSize = textSize
    b.Text = text or ""
    b.BackgroundColor3 = UI.BUTTON_BG
    b.TextColor3 = UI.C.dim
    b.LayoutOrder = UI.nextOrder(parent)
    b.Parent = parent
    UI.corner(b, 8)
    return b, UI.outline(b, UI.C.line, 1, 0.2)
end

-- ---- window ----

function UI.build()
    local playerGui = player:WaitForChild("PlayerGui")
    destroy(playerGui:FindFirstChild("AutoCombatUI"))

    local gui = Instance.new("ScreenGui")
    gui.Name = "AutoCombatUI"
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 50
    gui.Parent = playerGui
    UI.gui = gui

    local root = Instance.new("Frame")
    root.Name = "Window"
    root.Size = UDim2.fromOffset(340, 0)
    root.AutomaticSize = Enum.AutomaticSize.Y
    root.Position = UDim2.fromOffset(20, 110)
    root.BackgroundColor3 = Color3.new(1, 1, 1)
    root.BackgroundTransparency = 0.04
    root.BorderSizePixel = 0
    root.Parent = gui
    UI.corner(root, 13)
    UI.outline(root, UI.C.line, 1.5, 0.15)
    UI.padding(root, 10, 10, 10, 10)
    UI.vlist(root, 8)

    local grad = Instance.new("UIGradient")
    grad.Color = ColorSequence.new(Color3.fromRGB(26, 30, 46), UI.C.bg)
    grad.Rotation = 90
    grad.Parent = root

    local scale = Instance.new("UIScale")
    scale.Scale = Config.UI_SCALE
    scale.Parent = root

    -- ---- header (drag handle) ----
    local header = Instance.new("Frame")
    header.Size = UDim2.new(1, 0, 0, 28)
    header.BackgroundTransparency = 1
    header.Active = true
    header.LayoutOrder = UI.nextOrder(root)
    header.Parent = root

    local dot = Instance.new("Frame")
    dot.Size = UDim2.fromOffset(10, 10)
    dot.Position = UDim2.new(0, 2, 0.5, -5)
    dot.BackgroundColor3 = UI.C.green
    dot.BorderSizePixel = 0
    dot.Parent = header
    UI.corner(dot, 5)
    UI.refs.dot = dot

    local title = UI.label(header, 16, Enum.Font.GothamBold, UI.C.text)
    title.Position = UDim2.fromOffset(20, 0)
    title.Size = UDim2.new(1, -60, 1, 0)
    title.Text = "Auto Combat"

    local minBtn = Instance.new("TextButton")
    minBtn.Size = UDim2.fromOffset(26, 22)
    minBtn.Position = UDim2.new(1, -26, 0.5, -11)
    minBtn.BackgroundColor3 = UI.C.card
    minBtn.BorderSizePixel = 0
    minBtn.AutoButtonColor = true
    minBtn.Font = Enum.Font.GothamBold
    minBtn.TextSize = 16
    minBtn.TextColor3 = UI.C.dim
    minBtn.Text = "-"
    minBtn.Parent = header
    UI.corner(minBtn, 6)

    local dragging, dragStart, startPos = false, nil, nil
    header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = root.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    track(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            root.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end))

    -- ---- body (collapsible) ----
    local body = Instance.new("Frame")
    body.Size = UDim2.new(1, 0, 0, 0)
    body.AutomaticSize = Enum.AutomaticSize.Y
    body.BackgroundTransparency = 1
    body.LayoutOrder = UI.nextOrder(root)
    body.Parent = root
    UI.vlist(body, 8)

    minBtn.MouseButton1Click:Connect(function()
        body.Visible = not body.Visible
        minBtn.Text = body.Visible and "-" or "+"
    end)

    -- ---- state badge ----
    local stateCard = UI.card(body)

    local badge = Instance.new("TextLabel")
    badge.Size = UDim2.new(1, 0, 0, 36)
    badge.BackgroundColor3 = UI.C.card
    badge.BorderSizePixel = 0
    badge.Font = Enum.Font.GothamBold
    badge.TextSize = 19
    badge.TextColor3 = UI.C.text
    badge.Text = "IDLE"
    badge.LayoutOrder = UI.nextOrder(stateCard)
    badge.Parent = stateCard
    UI.corner(badge, 8)
    UI.refs.badge = badge
    UI.refs.badgeStroke = UI.outline(badge, UI.C.grey, 1.5, 0.3)

    UI.refs.plan = UI.label(stateCard, 12, Enum.Font.Gotham, UI.C.dim, Enum.TextXAlignment.Center)
    UI.refs.plan.Size = UDim2.new(1, 0, 0, 16)
    UI.refs.plan.TextTruncate = Enum.TextTruncate.AtEnd
    UI.refs.plan.LayoutOrder = UI.nextOrder(stateCard)

    -- ---- toggles ----
    local toggleRow = Instance.new("Frame")
    toggleRow.Size = UDim2.new(1, 0, 0, 30)
    toggleRow.BackgroundTransparency = 1
    toggleRow.LayoutOrder = UI.nextOrder(body)
    toggleRow.Parent = body
    UI.hlist(toggleRow, 6)

    local third = UDim2.new(1 / 3, -4, 1, 0)
    local botBtn, botStroke = UI.button(toggleRow, third, 13)
    local espBtn, espStroke = UI.button(toggleRow, third, 13)
    local aimBtn, aimStroke = UI.button(toggleRow, third, 13)

    local function refreshButtons()
        UI.styleToggle(botBtn, botStroke, "Bot", State.enabled)
        UI.styleToggle(espBtn, espStroke, "ESP", State.espEnabled)
        UI.styleToggle(aimBtn, aimStroke, "Aim", State.aimEnabled)
    end

    botBtn.MouseButton1Click:Connect(function()
        State.enabled = not State.enabled
        Move.setControlsEnabled(not State.enabled)   -- bot on -> take the controls; bot off -> give them back
        refreshButtons()
        Log.add(State.enabled and "Bot enabled" or "Bot disabled")
    end)
    espBtn.MouseButton1Click:Connect(function()
        ESP.setAll(not State.espEnabled)
        refreshButtons()
    end)
    aimBtn.MouseButton1Click:Connect(function()
        State.aimEnabled = not State.aimEnabled
        refreshButtons()
        Log.add(State.aimEnabled and "Auto-aim: on" or "Auto-aim: off")
    end)
    refreshButtons()

    -- ---- combat card ----
    local combat = UI.card(body, "COMBAT")
    UI.refs.target = UI.row(combat, "Target")
    UI.refs.nearest = UI.row(combat, "Nearest")

    UI.refs.safety = UI.bar(combat, 6)
    local marker = Instance.new("Frame")     -- MIN_DISTANCE tick mark (the bar spans 0 .. 2x MIN_DISTANCE)
    marker.Size = UDim2.new(0, 2, 1, 4)
    marker.Position = UDim2.new(0.5, -1, 0, -2)
    marker.BackgroundColor3 = UI.C.text
    marker.BackgroundTransparency = 0.35
    marker.BorderSizePixel = 0
    marker.ZIndex = 2
    marker.Parent = UI.refs.safety.track

    UI.refs.group = UI.row(combat, "Group")
    UI.refs.aggro = UI.row(combat, "Aggro")
    UI.refs.barrier = UI.row(combat, "Barrier")

    -- ---- threats card ----
    local threats = UI.card(body, "THREATS")

    local chipRow = Instance.new("Frame")
    chipRow.Size = UDim2.new(1, 0, 0, 22)
    chipRow.BackgroundTransparency = 1
    chipRow.LayoutOrder = UI.nextOrder(threats)
    chipRow.Parent = threats
    UI.hlist(chipRow, 6)

    UI.refs.chipPre = UI.chip(chipRow, Zones.COLORS.precast, 1)
    UI.refs.chipHit = UI.chip(chipRow, Zones.COLORS.hitbox, 2)
    UI.refs.chipOrb = UI.chip(chipRow, Zones.COLORS.orb, 3)
    UI.refs.chipUnk = UI.chip(chipRow, Zones.COLORS.unknown, 4)

    UI.refs.threat = UI.row(threats, "Status")
    UI.refs.threatBar = UI.bar(threats, 6)

    -- ---- abilities card ----
    local abilities = UI.card(body, "ABILITIES")
    UI.refs.rage, UI.refs.rageKey = UI.row(abilities, Skills.buffName or "Buff skill")
    UI.refs.rageBar = UI.bar(abilities, 6)
    UI.refs.barrage, UI.refs.barrageKey = UI.row(abilities, Skills.attackName or "Attack skill")
    UI.refs.barrageBar = UI.bar(abilities, 6)

    -- ---- record & learn card ----
    local rec = UI.card(body, "RECORD & LEARN")

    local recRow = Instance.new("Frame")
    recRow.Size = UDim2.new(1, 0, 0, 26)
    recRow.BackgroundTransparency = 1
    recRow.LayoutOrder = UI.nextOrder(rec)
    recRow.Parent = rec
    UI.hlist(recRow, 6)

    local half = UDim2.new(0.5, -3, 1, 0)
    local recBtn, recStroke = UI.button(recRow, half, 13)
    local applyBtn = UI.button(recRow, half, 12, "Apply Learned")
    local importBtn = UI.button(rec, UDim2.new(1, 0, 0, 26), 12, "Import Saved Runs")
    local clearBtn = UI.button(rec, UDim2.new(1, 0, 0, 26), 12, "Clear Recordings (this dungeon)")

    UI.refs.recStatus = UI.row(rec, "Status")
    UI.refs.recActive = UI.row(rec, "Active range")
    UI.refs.recRange = UI.row(rec, "Manual: attack")
    UI.refs.recAutoRange = UI.row(rec, "Auto: attack")
    UI.refs.recAvg = UI.row(rec, "Avg distance")
    UI.refs.recDmg = UI.row(rec, "Damage taken")
    UI.refs.recDeaths = UI.row(rec, "Deaths logged")
    UI.refs.recSafety = UI.row(rec, "Safety margins")

    local function refreshRecButton()
        UI.styleToggle(recBtn, recStroke, "Record", Record.active)
    end

    recBtn.MouseButton1Click:Connect(function()
        if Record.active then Record.stop() else Record.start() end
        refreshRecButton()
    end)

    applyBtn.MouseButton1Click:Connect(function()
        Learn.applyAll(Store.load())
        Log.add(string.format("Applied: range = %d", Tuned.barrageRange))
    end)

    importBtn.MouseButton1Click:Connect(Learn.importRuns)

    -- destructive: needs a second click within 4 seconds
    local CLEAR_TEXT = "Clear Recordings (this dungeon)"
    local clearArmed = false
    local function disarm()
        clearArmed = false
        clearBtn.Text = CLEAR_TEXT
        clearBtn.TextColor3 = UI.C.dim
    end
    clearBtn.MouseButton1Click:Connect(function()
        if not clearArmed then
            clearArmed = true
            clearBtn.Text = "Click again to confirm"
            clearBtn.TextColor3 = UI.C.red
            task.delay(4, function()
                if clearArmed then disarm() end
            end)
        else
            disarm()
            Learn.clearAll()
        end
    end)

    refreshRecButton()

    -- ---- log card ----
    local logCard = UI.card(body, "LOG")
    UI.refs.log = UI.label(logCard, 12, Enum.Font.Code, UI.C.dim)
    UI.refs.log.Size = UDim2.new(1, 0, 0, 78)
    UI.refs.log.TextYAlignment = Enum.TextYAlignment.Top
    UI.refs.log.TextWrapped = true
    UI.refs.log.LayoutOrder = UI.nextOrder(logCard)

    -- ---- footer ----
    UI.refs.footer = UI.label(body, 11, Enum.Font.Gotham, UI.C.dim, Enum.TextXAlignment.Center)
    UI.refs.footer.Size = UDim2.new(1, 0, 0, 14)
    UI.refs.footer.LayoutOrder = UI.nextOrder(body)
end

-- skill names are only known once the backpack is scanned, which can happen after the window was built
function UI.refreshSkillLabels()
    if UI.refs.rageKey then UI.refs.rageKey.Text = Skills.buffName or "Buff skill" end
    if UI.refs.barrageKey then UI.refs.barrageKey.Text = Skills.attackName or "Attack skill" end
end

-- bar = charging up; full green = ready; yellow = buff running out
local function abilityRow(valueLabel, bar, a, activeLeft, activeTotal)
    if not a then
        valueLabel.Text = UI.col(UI.C.dim, "not in backpack")
        UI.setBar(bar, 0, UI.C.dim)
    elseif activeLeft then
        valueLabel.Text = UI.col(UI.C.yellow, string.format("<b>ACTIVE</b>  %.1fs", activeLeft))
        UI.setBar(bar, activeLeft / activeTotal, UI.C.yellow)
    elseif a.ready then
        valueLabel.Text = UI.col(UI.C.green, "<b>READY</b>")
        UI.setBar(bar, 1, UI.C.green)
    else
        valueLabel.Text = UI.col(UI.C.orange, string.format("%.1fs", a.remaining)) .. UI.col(UI.C.dim, string.format("  / %.0fs", a.length))
        UI.setBar(bar, 1 - a.remaining / math.max(a.length, 0.1), UI.C.orange)
    end
end

function UI.update()
    local r = UI.refs
    if not r.footer then return end   -- the window never finished building

    local stats = State.stats
    local nowT = clock()

    -- header dot + state badge
    local stateColor = UI.STATE_COLORS[State.mode] or UI.C.text
    r.dot.BackgroundColor3 = (not State.enabled) and UI.C.grey or (State.mode == "DEAD" and UI.C.red or UI.C.green)
    r.badge.Text = State.mode
    r.badge.TextColor3 = stateColor
    r.badge.BackgroundColor3 = stateColor:Lerp(UI.C.bg, 0.82)
    r.badgeStroke.Color = stateColor
    r.plan.Text = UI.esc((Skills.info.plan ~= "" and Skills.info.plan) or "no ability plan")

    -- combat
    local locked = Enemies.locked
    if locked then
        r.target.Text = string.format("%s  %s", UI.esc(locked.Name),
            UI.col(UI.C.dim, string.format("%.0f ctr / %.0f edge", stats.targetCenter or 0, stats.targetDist or 0)))
    else
        r.target.Text = UI.col(UI.C.dim, "none")
    end

    local nd = stats.nearestDist
    if nd == math.huge then
        r.nearest.Text = UI.col(UI.C.dim, "--")
        UI.setBar(r.safety, 0, UI.C.track)
    else
        local c = nd >= Config.MIN_DISTANCE and UI.C.green or UI.C.red
        r.nearest.Text = UI.col(c, string.format("%.1f", nd)) .. UI.col(UI.C.dim, string.format("  / min %d", Config.MIN_DISTANCE))
        UI.setBar(r.safety, nd / (Config.MIN_DISTANCE * 2), c)
    end

    local g = stats.group
    if g then
        r.group.Text = string.format("%d npc%s  %s", g.count, g.count == 1 and "" or "s",
            UI.col(UI.C.dim, string.format("r %.0f  |  %d group%s", g.radius, stats.groupCount, stats.groupCount == 1 and "" or "s")))
    else
        r.group.Text = UI.col(UI.C.dim, "--")
    end

    -- the npc's aggro range and the distance we cast from (green = we are inside it)
    if locked and stats.targetCastRange then
        local inside = (stats.targetCenter or math.huge) <= stats.targetCastRange
        if stats.targetAggro then
            r.aggro.Text = UI.col(inside and UI.C.green or UI.C.orange, string.format("%.0f", stats.targetAggro))
                .. UI.col(UI.C.dim, string.format("  cast within %.0f  %s", stats.targetCastRange, inside and "(inside)" or "(outside)"))
        else
            r.aggro.Text = UI.col(UI.C.dim, string.format("no aggroRange  |  cast within %.0f", stats.targetCastRange))
        end
    else
        r.aggro.Text = UI.col(UI.C.dim, "--")
    end

    local b = stats.barrier
    r.barrier.Text = b and UI.col(UI.C.yellow, string.format("closest %.0f (+%d)", b.dist, Config.BARRIER_LEEWAY)) or UI.col(UI.C.dim, "none")

    -- threats
    local counts = Zones.counts(nowT)
    local function chip(label, chipLabel, n)
        chipLabel.Text = string.format("%s  %d", label, n)
        chipLabel.BackgroundTransparency = n > 0 and 0.7 or 0.9
        chipLabel.TextTransparency = n > 0 and 0 or 0.55
    end
    chip("PRECAST", r.chipPre, counts.precast)
    chip("HITBOX", r.chipHit, counts.hitbox)
    chip("ORB", r.chipOrb, counts.orb)
    chip("?", r.chipUnk, counts.unknown)

    local deadline = Zones.positionDeadline(State.hrp.Position)
    if deadline < math.huge then
        if deadline > 0 then
            r.threat.Text = UI.col(UI.C.red, string.format("<b>INSIDE</b>  fires in %.1fs", deadline))
            UI.setBar(r.threatBar, deadline / Config.PRECAST_DELAY, UI.C.red)
        else
            r.threat.Text = UI.col(UI.C.red, "<b>INSIDE ACTIVE ZONE</b>")
            UI.setBar(r.threatBar, 1, UI.C.red)
        end
    elseif counts.soonest < math.huge and counts.soonest > 0 then
        r.threat.Text = UI.col(UI.C.orange, string.format("precast fires in %.1fs", counts.soonest))
        UI.setBar(r.threatBar, counts.soonest / Config.PRECAST_DELAY, UI.C.orange)
    else
        r.threat.Text = UI.col(UI.C.green, "clear")
        UI.setBar(r.threatBar, 0, UI.C.green)
    end

    -- abilities. Inner Rage: the game's cooldown starts at (buff time + cooldownLength), so time above cooldownLength is the BUFF
    local rageInfo = Skills.info.rage
    local rageLeft = Skills.rageActiveUntil - nowT
    if rageInfo then
        rageLeft = math.max(rageLeft, rageInfo.remaining - rageInfo.length)
    end
    local rageTotal = (rageInfo and rageInfo.extra >= 0.5) and rageInfo.extra or Config.RAGE_DURATION
    abilityRow(r.rage, r.rageBar, rageInfo, rageLeft > 0.05 and rageLeft or nil, rageTotal)
    abilityRow(r.barrage, r.barrageBar, Skills.info.barrage, nil, 1)

    -- recording / learning
    if Record.active then
        r.recStatus.Text = UI.col(UI.C.red, string.format("<b>RECORDING</b>  %.0fs  (%d samples)", nowT - Record.startT, #Record.samples))
    else
        r.recStatus.Text = UI.col(UI.C.dim, "not recording")
    end

    local ability = Skills.attackName
    local baseRange = (ability and Learn.applied[ability]) or Tuned.barrageRange
    local targetRange = locked and stats.targetCastRange or nil   -- includes the npc's aggro limit
    if targetRange and targetRange ~= baseRange then
        r.recActive.Text = UI.col(UI.C.green, string.format("%.0f studs (vs %s)", targetRange, locked.Name))
    else
        r.recActive.Text = UI.col(UI.C.green, string.format("%.0f studs (in use now)", targetRange or baseRange))
    end

    local manual = ability and Learn.manual[ability]
    r.recRange.Text = manual and UI.col(UI.C.green, string.format("%.0f studs", manual)) or UI.col(UI.C.dim, "no confirmed hits yet")
    local auto = ability and Learn.auto[ability]
    r.recAutoRange.Text = auto and UI.col(UI.C.green, string.format("%.0f studs", auto)) or UI.col(UI.C.dim, "none yet")

    r.recAvg.Text = (Record.nearestCount > 0) and string.format("%.0f studs", Record.nearestSum / Record.nearestCount) or UI.col(UI.C.dim, "--")
    r.recDmg.Text = #Record.damageEvents > 0 and UI.col(UI.C.orange, #Record.damageEvents .. " time(s)") or UI.col(UI.C.dim, "none")

    local totalDeaths = #Learn.deathLog
    if totalDeaths > 0 then
        local last = Learn.deathLog[totalDeaths].attackKind
        r.recDeaths.Text = UI.col(UI.C.orange, string.format("%d total, last: %s", totalDeaths, last or "unknown"))
    else
        r.recDeaths.Text = UI.col(UI.C.dim, "none yet")
    end
    r.recSafety.Text = string.format("precast %.1fs | hitbox %.1fs", Tuned.precastSafety, Tuned.destSafetyWindow)

    -- log: newest line bright, older ones dimmed
    local lines = {}
    for i, line in ipairs(Log.lines) do
        lines[i] = (i == 1) and UI.col(UI.C.text, UI.esc(line)) or UI.col(UI.C.dim, UI.esc(line))
    end
    r.log.Text = table.concat(lines, "\n")

    local wallText = stats.wallAhead and UI.col(UI.C.orange, "wall ahead, re-routing") or "walls clear"
    r.footer.Text = string.format("orbit %s   |   %s", Steer.orbitDir == 1 and "CW" or "CCW", wallText)
end

function UI.destroy()
    destroy(UI.gui)
    UI.gui = nil
    UI.refs = {}
end

-- =====================
-- BOT: the per-frame decision loop
--  1. inside an attack / closer than MIN_DISTANCE to any npc -> urgent steering (DODGE / KEEP AWAY)
--  2. within ENGAGE_RANGE of an npc                           -> steering (CIRCLE the group)
--  3. far from npcs                                           -> pathfind to the group's orbit ring (APPROACH)
-- =====================
Bot.staging = false          -- backing off / waiting for cooldowns
Bot.waitStartT = nil
Bot.stagingGiveUp = false
Bot.lastWallRefresh = 0
Bot.lastSteerTime = 0
Bot.lastPathTime = 0
Bot.lastUIUpdate = 0
Bot.lastNoPathLog = 0
Bot.lastErrorLog = 0
Bot.stopped = false

-- One bad frame (a part vanishing mid-death, ...) must never kill the loop or spam errors.
function Bot.reportError(label, err)
    Move.isComputing = false
    local now = clock()
    if now - Bot.lastErrorLog > 2 then
        Bot.lastErrorLog = now
        Log.add("error: " .. tostring(err))
        warn("[AutoCombat] " .. label .. ": " .. tostring(err))
    end
end

function Bot.refreshUI(now)
    if now - Bot.lastUIUpdate >= 0.1 then
        Bot.lastUIUpdate = now
        UI.update()
    end
end

-- ---- death / respawn ----
-- Everything tied to the old character is dropped, and the loop idles until the new one is ready.

function Bot.resetForRespawn(reason)
    Move.stopWalker()
    ESP.clearGuideline()
    Steer.goal = nil
    Move.lastGoal = nil
    Steer.lastPosition = nil
    Steer.lastMoveTime = clock()
    Move.isComputing = false
    Skills.rageActiveUntil = 0      -- buffs are lost on death
    Skills.barrageNotBefore = 0
    Skills.busy = false
    Move.stop()
    ESP.updateGoalMarker(nil)
    Log.add(reason)
end

-- Called every frame while there is no live character.
function Bot.handleNotAlive()
    if State.wasAlive then
        State.wasAlive = false
        Bot.resetForRespawn("Dead")
        State.setMode("DEAD")
    end
    local now = clock()
    if now - Bot.lastUIUpdate >= 0.1 and State.hrp then
        Bot.lastUIUpdate = now
        pcall(UI.update)
    end
end

function Bot.onCharacterAdded(char, isInitial)
    task.spawn(function()
        local hum = char:WaitForChild("Humanoid", 10)
        local root = char:WaitForChild("HumanoidRootPart", 10)
        if not hum or not root or Bot.stopped then return end

        State.character, State.humanoid, State.hrp = char, hum, root
        Bot.resetForRespawn("Character ready")

        -- A new character can get the game's own controls back even though we disabled them for the last one;
        -- then our movement calls get overwritten like raw keyboard input and the bot looks dead until toggled.
        if State.enabled then
            Move.setControlsEnabled(false)
        end

        -- re-detect on every respawn (the loadout can change between runs), and whenever a tool lands in the
        -- (new) backpack mid-run
        Skills.detect()
        local bp = player:WaitForChild("Backpack", 5)
        if bp then
            bp.ChildAdded:Connect(function(child)
                if child:IsA("Tool") then Skills.detect() end
            end)
        end

        -- fresh spawn = a few seconds of immortality: spend them attacking
        if Config.SPAWN_SHIELD and not isInitial then
            State.shieldUntil = clock() + Config.SPAWN_SHIELD_SECONDS - Config.SPAWN_SHIELD_SAFETY
            Log.add("Spawn shield: all-in attack")
        end

        -- whatever was near us when we got hurt must never be learned as harmless
        local lastHealth = hum.Health
        hum.HealthChanged:Connect(function(health)
            if health < lastHealth - 0.5 then
                pcall(Zones.noteDamage, root.Position)
            end
            lastHealth = health
        end)

        hum.Died:Connect(function()
            if State.wasAlive then
                State.wasAlive = false
                pcall(Learn.recordDeath)   -- snapshot what killed us before state resets
                Bot.resetForRespawn("Died")
                State.setMode("DEAD")
            end
        end)
    end)
end

-- ---- one frame ----

-- false while there is no live character
function Bot.refreshCharacter()
    State.character = player.Character
    if not State.character then
        Bot.handleNotAlive()
        return false
    end

    local root = State.character:FindFirstChild("HumanoidRootPart")
    local hum = State.character:FindFirstChildOfClass("Humanoid")
    if not root or not hum or hum.Health <= 0 then
        Bot.handleNotAlive()
        return false
    end
    State.hrp, State.humanoid = root, hum

    if not State.wasAlive then
        State.wasAlive = true
        Bot.resetForRespawn("Alive again")
    end
    return true
end

-- The bot is switched off: hand everything back once, then just keep the window fresh.
function Bot.idle(now)
    if State.wasEnabled then
        State.wasEnabled = false
        State.humanoid.AutoRotate = true
        Move.aimOwnsRotation = false
        Move.stopWalker()
        ESP.clearGuideline()
        ESP.updateGoalMarker(nil)
        ESP.updateRing(nil)
        Move.stop()
        Move.setControlsEnabled(true)
        State.setMode("OFF")
    end
    Bot.refreshUI(now)
end

-- A barrier on the current target expires after a while, or vanishes once we get well past it.
function Bot.updateBarrier(target, nearestDist, now)
    local barrier = target and Steer.barriers[target.model] or nil
    if barrier then
        if now > barrier.expires then
            Steer.barriers[target.model] = nil
            barrier = nil
            Log.add("Barrier expired, trying to get closer")
        elseif nearestDist < barrier.dist - Config.BARRIER_LEEWAY then
            Steer.barriers[target.model] = nil   -- we got well past it: it's gone
            barrier = nil
            Log.add("Barrier gone")
        end
    end
    State.stats.barrier = barrier
    return barrier, barrier ~= nil and nearestDist <= barrier.dist + Config.BARRIER_LEEWAY
end

-- No npcs around: only dodge.
function Bot.noEnemiesStep(inDanger, now)
    Move.aimPos = nil
    Move.stopWalker()
    ESP.clearGuideline()
    State.stats.wallAhead = false

    if inDanger then
        State.setMode("DODGE")
        local spot = Steer.dodgeWithoutEnemies()
        if spot then
            Steer.goal = spot
            Move.setGoal(spot)
            ESP.updateGoalMarker(spot)
        end
    else
        State.setMode("IDLE")
        ESP.updateGoalMarker(nil)
    end
    Bot.refreshUI(now)
end

-- Should we back off and wait for cooldowns? (WAIT_FOR_COOLDOWNS)
function Bot.wantsToWait(target, shielded, now)
    local needWait = false
    if Config.WAIT_FOR_COOLDOWNS and target and not shielded then
        local r, b = Skills.info.rage, Skills.info.barrage
        if r and r.ready then Skills.rageTravelUse = false end
        local rageBuff = now < Skills.rageActiveUntil or (r ~= nil and r.remaining > r.length + 0.3)
        local rageCooling = Config.WAIT_FOR_RAGE and r ~= nil and not r.ready and not rageBuff and not Skills.rageTravelUse
        local barrageCooling = Config.WAIT_FOR_BARRAGE and b ~= nil and not b.ready

        if rageCooling or barrageCooling then
            Bot.waitStartT = Bot.waitStartT or now
            needWait = (now - Bot.waitStartT) < Config.WAIT_MAX_SECONDS
        else
            Bot.waitStartT = nil
            Bot.stagingGiveUp = false
        end
    else
        Bot.waitStartT = nil
        Bot.stagingGiveUp = false
    end
    return needWait
end

-- Abilities cooling down: wait far from the next npcs.
function Bot.stagingStep(group, nearestDist, now)
    Steer.approach.model = nil
    Steer.goal = nil
    ESP.updateGoalMarker(nil)
    State.stats.wallAhead = false

    if nearestDist >= Config.WAIT_RANGE then
        -- far enough away: hold here until the cooldowns are back
        if State.mode ~= "WAITING" then
            Move.stopWalker()
            ESP.clearGuideline()
            Move.lastGoal = nil
            Move.stop()
        end
        State.setMode("WAITING")

        -- don't wait right on the edge of an attack: move to somewhere with breathing room
        if Zones.dangerClearance(State.hrp.Position) < Config.WAIT_CLEARANCE then
            local roomy = Steer.retreatSpot()
            if roomy then Move.setGoal(roomy) end
        end
        return
    end

    State.setMode("BACK OFF")

    if now - Bot.lastPathTime >= Config.REPATH_RATE and not Move.isComputing and group then
        Bot.lastPathTime = now

        local needRepath = not Move.isWalking
        if not Move.lastGoal or Enemies.minDistance(Move.lastGoal) < Config.WAIT_RANGE or Zones.destinationDanger(Move.lastGoal) then
            needRepath = true
        end

        if needRepath then
            Move.isComputing = true
            local pts = Steer.stagingPoints(group)
            local pathed = false
            for i = 1, math.min(4, #pts) do
                if Move.computeAndWalk(pts[i]) then
                    pathed = true
                    break
                end
            end
            if not pathed and State.alive() and pts[1] then
                Move.setGoal(pts[1])   -- no navmesh path: walk straight
            end
            Move.isComputing = false
        end
    end

    if Steer.isStuck() then
        Bot.stagingGiveUp = true   -- can't get any further away: fight from here until the cooldowns are back
        Log.add("Can't back off further, holding here")
    end
end

-- Dodge + keep away + circle.
function Bot.steerStep(group, f, now)
    -- NOTE: Steer.approach is deliberately left alone here. Boundary flapping right around ENGAGE_RANGE (or a
    -- brief dodge) used to wipe the barrier-detection timers every time it happened, so a real, persistent
    -- barrier could flicker in and out of "steering" forever without being detected. The timers now just pause.
    Move.stopWalker()
    ESP.clearGuideline()
    Move.lastGoal = nil

    local blocked = Walls.wallAhead()
    -- re-steer if a new attack swallowed our goal, or a wall now sits between us and it
    local goalBad = Steer.goal ~= nil and (Zones.destinationDanger(Steer.goal) or not Walls.moveIsClear(State.hrp.Position, Steer.goal))
    State.stats.wallAhead = blocked
    if blocked then Steer.goal = nil end

    if f.urgent or blocked or goalBad or now - Bot.lastSteerTime >= Config.STEER_RATE then
        Bot.lastSteerTime = now

        local spot = Steer.findBestSpot(group, f.urgent, f.inDanger)
        local mode = f.shielded and "ALL-IN" or (f.inDanger and "DODGE" or (f.aheadBlocked and "AVOID"
            or (f.tooClose and "KEEP AWAY" or ((f.atBarrier and f.nearestDist > Config.ENGAGE_RANGE) and "SIEGE" or "CIRCLE"))))

        if not spot and f.inDanger then
            -- no roomy safe spot: squeeze into a small safe gap between the attacks, else back out of them
            spot = Steer.findPocketCached()
            mode = "POCKET"
            if not spot then
                spot = Steer.retreatSpot()
                mode = "RETREAT"
                if not spot then
                    spot = Steer.fallbackAway()
                    mode = "BOXED IN"
                end
            end
        elseif not spot and f.tooClose then
            spot = Steer.fallbackAway()
            mode = "BOXED IN"
        elseif not spot then
            mode = "HOLD"
            if f.aheadBlocked then
                Move.stop()   -- nowhere safe to go around it: stand still, don't walk into it
            end
        end

        State.setMode(mode)

        if spot then
            Steer.goal = spot
            Move.setGoal(spot)
            ESP.updateGoalMarker(spot)
        else
            ESP.updateGoalMarker(nil)
        end
    end

    if Steer.goal and flat(State.hrp.Position - Steer.goal).Magnitude < 2 then
        Steer.goal = nil
    end

    if Steer.isStuck() then
        Steer.orbitDir = -Steer.orbitDir
        Steer.goal = nil
        Steer.lastMoveTime = clock()
        Log.add("Stuck: flipped orbit")
    end
end

-- Barrier detection while approaching: standing still, or walking without getting any closer, for too long.
function Bot.watchForBarrier(target, group, nearestDist, now)
    local a = Steer.approach
    if a.model ~= target.model then
        a.model = target.model
        a.best = nearestDist
        a.progressT = now
        a.anchor = State.hrp.Position
        a.anchorT = now
    elseif Move.isComputing or not Move.goal then
        -- no destination right now (still computing a path, or none found yet): that's not being blocked,
        -- there's just nothing to walk toward yet, so it shouldn't count as stuck
        a.anchorT = now
    else
        if nearestDist < a.best - Config.BARRIER_PROGRESS_EPS then
            a.best = nearestDist
            a.progressT = now
        end
        if flat(State.hrp.Position - a.anchor).Magnitude > 3 then
            a.anchor = State.hrp.Position
            a.anchorT = now
        end

        local stuckStill = now - a.anchorT >= Config.BARRIER_STUCK_TIME
        local noProgress = now - a.progressT >= Config.BARRIER_NOPROGRESS_TIME
        if (stuckStill or noProgress) and State.alive() then
            local obstruction = Steer.findObstruction(target)
            if obstruction or not Config.BARRIER_REQUIRE_WALL then
                Steer.declareBarrier(target, nearestDist, group, obstruction)
                a.model = nil
            else
                -- no wall found: probably just a slow or winding path, not a real barrier - give it a fresh
                -- window instead of re-triggering every frame
                a.progressT = now
                a.anchorT = now
                a.best = nearestDist
            end
        end
    end
end

-- Far from the npcs: pathfind to the group's orbit ring.
function Bot.approachStep(target, group, barrier, nearestDist, now)
    State.stats.wallAhead = false
    Steer.goal = nil
    ESP.updateGoalMarker(nil)
    State.setMode("APPROACH")

    if target then
        Bot.watchForBarrier(target, group, nearestDist, now)
    end

    if now - Bot.lastPathTime >= Config.REPATH_RATE and not Move.isComputing and group then
        Bot.lastPathTime = now

        local ringR = Steer.ringRadiusFor(group)
        local needRepath = not Move.isWalking

        if not Move.lastGoal
            or Enemies.minDistance(Move.lastGoal) < Config.MIN_DISTANCE + 1
            or Zones.destinationDanger(Move.lastGoal)
            or (not barrier and math.abs(flat(Move.lastGoal - group.centroid).Magnitude - ringR) > 4) then
            needRepath = true
        end

        if needRepath then
            Move.isComputing = true
            local pts = barrier and { barrier.pos } or Steer.approachPoints(group)   -- known barrier: go back to where we got stuck
            local pathed = false
            for i = 1, math.min(6, #pts) do
                if Move.computeAndWalk(pts[i]) then
                    pathed = true
                    break
                end
            end

            -- no navmesh path (big boss room, odd geometry)? walk straight at the nearest legal point
            if not pathed and State.alive() and not Move.shouldSteer() then
                local goal = pts[1]
                if not goal then
                    local out = flat(State.hrp.Position - group.centroid)
                    if out.Magnitude < 0.01 then out = Vector3.new(0, 0, 1) end
                    goal = group.centroid + out.Unit * ringR
                end
                Move.setGoal(goal)
                if now - Bot.lastNoPathLog > 3 then
                    Bot.lastNoPathLog = now
                    Log.add("no path found, walking straight")
                end
            end
            Move.isComputing = false
        end
    end

    if Move.isWalking and Steer.isStuck() then
        local nudgeDir = Move.goal and flat(Move.goal - State.hrp.Position)
        if not nudgeDir or nudgeDir.Magnitude < 0.01 then nudgeDir = flat(State.hrp.CFrame.LookVector) end
        Move.setGoal(State.hrp.Position + nudgeDir.Unit * 5)
        Bot.lastPathTime = 0
    end
end

function Bot.step()
    if not Bot.refreshCharacter() then return end
    local now = clock()

    if State.filterDirty or now - Bot.lastWallRefresh >= 0.5 then
        State.filterDirty = false
        Bot.lastWallRefresh = now
        Walls.refresh()
    end

    if not State.enabled then
        Bot.idle(now)
        return
    end
    State.wasEnabled = true

    Zones.update(now)
    Zones.scan(now)

    -- ---------- gather info ----------
    Enemies.refresh(0)
    Enemies.buildGroups()

    local pos = State.hrp.Position
    local nearest, nearestDist = Enemies.nearestFrom(pos)

    local prevTarget = Enemies.locked
    local target = Enemies.selectTarget(nearest, nearestDist)
    if Enemies.locked and Enemies.locked ~= prevTarget then
        Log.add("Target: " .. Enemies.locked.Name)
    end
    ESP.updateEnemies(now, target)

    local group = target and Enemies.groups[target.gid] or nil
    local barrier, atBarrier = Bot.updateBarrier(target, nearestDist, now)

    local stats = State.stats
    stats.nearestDist = nearestDist
    stats.group = group
    stats.groupCount = #Enemies.groups
    stats.targetDist = target and (flat(pos - target.pos).Magnitude - target.radius) or nil
    stats.targetCenter = target and flat(pos - target.pos).Magnitude or nil
    stats.targetAggro = target and target.aggroRange or nil
    if target then
        stats.targetCastRange, stats.targetByAggro = Skills.effectiveRange(target, barrier)
    else
        stats.targetCastRange, stats.targetByAggro = nil, nil
    end
    ESP.updateRing(group)

    -- a precast with time left is not an emergency - only urgent once it's actually about to go off
    local inDanger = Zones.dangerNow(pos)
    local tooClose = nearest ~= nil and nearestDist < Config.MIN_DISTANCE

    -- spawn immortality: attacks can't hurt us, so ignore them (and npc distance) and go all-in on attacking
    local shielded = Config.SPAWN_SHIELD and (now < State.shieldUntil)
    if shielded then
        inDanger = false
        tooClose = false
    end
    stats.inDanger = inDanger
    stats.shielded = shielded

    -- an attack zone right in front of us on the way we're walking: stop and route around it instead of walking in
    local aheadBlocked = false
    if not inDanger and not shielded then
        aheadBlocked = Steer.pathAheadBlocked()
    end

    if not nearest then
        Bot.noEnemiesStep(inDanger, now)
        return
    end

    local urgent = inDanger or tooClose or aheadBlocked

    Bot.staging = Bot.wantsToWait(target, shielded, now) and not urgent and not Bot.stagingGiveUp

    if Bot.staging then
        Bot.stagingStep(group, nearestDist, now)
    elseif urgent or nearestDist <= Config.ENGAGE_RANGE or atBarrier then
        Bot.steerStep(group, {
            urgent = urgent, inDanger = inDanger, aheadBlocked = aheadBlocked, tooClose = tooClose,
            shielded = shielded, atBarrier = atBarrier, nearestDist = nearestDist,
        }, now)
    else
        Bot.approachStep(target, group, barrier, nearestDist, now)
    end

    -- abilities get their turn (the attack skill aims itself when it fires)
    Move.aimPos = group and ((group.count >= 2) and group.centroid or target.pos) or nil
    -- only pause abilities while actually inside an attack (being too close to an npc doesn't stop casting)
    Skills.update(now, State.mode, nearest, nearestDist, inDanger, shielded)

    Bot.refreshUI(now)
end

-- ---- startup / shutdown ----

function Bot.start()
    print("[AutoCombat] starting...")

    State.character = player.Character or player.CharacterAdded:Wait()
    State.hrp = State.character:WaitForChild("HumanoidRootPart")
    State.humanoid = State.character:WaitForChild("Humanoid")

    -- detect abilities before building the window so the skill names are already known
    Skills.detect()
    local okUI, errUI = pcall(UI.build)
    if not okUI then
        warn("[AutoCombat] UI failed to build: " .. tostring(errUI))
        UI.destroy()
    end

    ESP.init()
    Walls.refresh()
    Zones.start()

    track(RunService.Heartbeat:Connect(Move.drive))
    track(RunService.Heartbeat:Connect(function()
        local ok, err = pcall(Record.heartbeat, clock())
        if not ok then Bot.reportError("record", err) end
    end))
    track(RunService.Heartbeat:Connect(function()
        local ok, err = pcall(Bot.step)
        if not ok then Bot.reportError("step", err) end
    end))

    track(player.CharacterAdded:Connect(function(char) Bot.onCharacterAdded(char, false) end))
    if player.Character then Bot.onCharacterAdded(player.Character, true) end

    local prior = Store.load()
    if next(prior.manual.ranges) or next(prior.manual.byTarget) or next(prior.auto.ranges) or next(prior.auto.byTarget) or next(prior.safety) then
        Log.add("Loaded learned settings from a previous session")
        Learn.applyAll(prior)
    end
    Learn.importRuns()

    if Tuned.barrageRange - Config.RANGE_MARGIN < Config.IDEAL_DISTANCE then
        Log.add(string.format("WARNING: attack range %d is too short for MIN_DISTANCE %d", Tuned.barrageRange, Config.MIN_DISTANCE))
    end
    if State.enabled then Move.setControlsEnabled(false) end
    Log.add("Loaded - waiting for npcs")
    print("[AutoCombat] loaded")
end

-- Drops every connection and visual and gives the controls back. Also what running the script a second time does.
function Bot.stop()
    Bot.stopped = true
    State.enabled = false
    for _, c in ipairs(connections) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(connections)

    Move.stopWalker()
    pcall(Move.setControlsEnabled, true)
    if State.humanoid then
        pcall(function()
            State.humanoid.AutoRotate = true
            State.humanoid:Move(Vector3.zero, false)
        end)
    end

    for part in pairs(Zones.active) do Zones.remove(part) end
    Walls.clearVisuals()
    ESP.destroyAll()
    UI.destroy()
    if env.__AutoCombat and env.__AutoCombat.stop == Bot.stop then
        setHandle(nil)
    end
end

function Bot.boot()
    setHandle({ stop = Bot.stop })

    if not game:IsLoaded() then game.Loaded:Wait() end
    task.wait(Config.BOOT_DELAY)
    if Bot.stopped then return end

    -- starts the dungeon run
    local okStart, errStart = pcall(function()
        local remotes = ReplicatedStorage:WaitForChild("remotes", 15)
        local startEvent = remotes and remotes:WaitForChild("changeStartValue", 15)
        if not startEvent then error("remotes.changeStartValue not found") end
        startEvent:FireServer()
    end)
    if not okStart then
        warn("[AutoCombat] couldn't fire changeStartValue: " .. tostring(errStart))
    end

    local ok, err = pcall(Bot.start)
    if not ok then
        warn("[AutoCombat] failed to start: " .. tostring(err))
        pcall(Bot.stop)
        pcall(function()
            game:GetService("StarterGui"):SetCore("SendNotification", {
                Title = "Auto Combat", Text = "Failed to start: " .. tostring(err), Duration = 15,
            })
        end)
    end
end

Bot.boot()

--[[
    Auto Combat - dungeon follow / dodge / abilities.

    What the bot does, in priority order:
      1. Survive   it always knows which attack zones are live or about to fire (parts named "precast" / "hitbox",
                   orbs, npc-named parts, loose models) and steers out of them in time.
      2. Engage    it walks to the nearest npc group and stands where its skills reach - and inside the npc's own
                   `aggroRange`, because an npc ignores anyone outside it (no precasts, nothing to fight).
      3. Fight     it faces the npcs and uses the buff skill and the attack skill from there.

    One file, a few module tables:
      Util / Log / State          shared helpers
      Npcs                        the dungeon's enemies: cache, groups, target lock, cast range
      Hazards                     attack detection and every "is this spot dangerous" question
      Walls                       raycasts against the map
      Nav                         movement, facing, path walking, choosing where to stand
      Skills                      ability detection and casting
      ESP / UI                    drawing and the control window
      Bot                         the per-frame loop, respawns, startup and shutdown

    Running the script again stops the previous run first. The running bot is reachable as
    getgenv().__AutoCombat (stop(), config, ...).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local clock = os.clock

local env = (type(getgenv) == "function" and getgenv()) or _G
local function setHandle(handle)
    pcall(function() env.__AutoCombat = handle end)   -- bookkeeping must never stop the bot from starting
end
if env.__AutoCombat and env.__AutoCombat.stop then
    pcall(env.__AutoCombat.stop)
end

-- =====================
-- CONFIG
-- =====================
local Config = {
    BOOT_DELAY          = 10,    -- seconds to let the game finish its own setup before we touch anything

    -- ---- where to stand (studs) ----
    MIN_DISTANCE        = 7,     -- never closer than this to an npc's body
    ATTACK_RANGE        = 90,    -- how far the attack skill is assumed to reach (to an npc's CENTRE); calibrated while fighting
    RANGE_MARGIN        = 6,     -- stand this far inside the cast range
    USE_AGGRO_RANGE     = true,  -- npcs only react to someone inside their `aggroRange`: stand and cast inside it
    AGGRO_MARGIN        = 3,     -- ...this far inside, so we're clearly in it
    BIG_BODY_GAP        = 12,    -- never closer than this to the edge of a huge npc (a boss)
    GROUP_LINK          = 20,    -- npcs this close to each other are one group
    TARGET_SWITCH       = 2,     -- another npc must be this much closer before the target lock moves
    BODY_RADIUS         = 4,     -- an npc this wide counts as a point; only size beyond it adds keep-away distance
    FLANK_RANGE         = 60,

    -- ---- movement ----
    STEER_RATE          = 0.12,  -- how often the local spot search runs
    REPATH_RATE         = 0.5,
    WAYPOINT_REACHED    = 3.5,
    WAYPOINT_TIMEOUT    = 1.5,
    STUCK_TIME          = 2.5,
    STUCK_MOVE          = 0.4,
    SEARCH_RADII        = { 4, 8, 13, 19, 26, 34 },
    SEARCH_ANGLE_STEP   = 20,
    WALL_CHECKS         = 60,    -- how many best-scoring spots get the (expensive) wall test
    WALL_CLEARANCE      = 5,     -- studs of breathing room we like around a spot

    -- ---- danger ----
    PADDING             = 2,     -- margin kept around every attack
    PRECAST_DELAY       = 2.0,   -- a precast telegraphs ~2s before the spell fires
    PRECAST_SAFETY      = 0.35,  -- want to be out of a precast zone this long BEFORE it fires
    DODGE_LEAD          = 1.5,   -- start leaving a zone over us once it fires within about this (+ PRECAST_SAFETY) seconds
    SAFE_WINDOW         = 1.0,   -- a destination must stay safe this long after we get there
    REACTION            = 0.15,  -- input / humanoid delay added to every travel-time estimate
    PREDICT_MAX         = 1.2,   -- seconds ahead a MOVING attack is extrapolated (sweeping beams ...)
    ORB_NAME            = "battlemageorb",
    ORB_PADDING         = 3,
    ORB_STAY            = 1.0,   -- an orb is dangerous to a spot it passes within this long of when we're there
    ORB_HORIZON         = 4.0,   -- a spot we will STAY at must be clear of the orb's path this many seconds ahead
    ORB_RECHECK         = 3,     -- an orb's Trail/Mist can appear after the part: re-check top-level parts this long
    MODELS_ARE_ATTACKS  = true,  -- a Model dropped straight into workspace counts as an attack...
    UNKNOWN_MAX_AGE     = 6,     -- ...until it has been around this long: then it was scenery
    OWNER_MAX_DIST      = 50,    -- an attack whose name doesn't reveal its npc is matched to one this close
    OWN_RADIUS          = 30,    -- an attack that appears this close to us right after we cast is our own
    OWN_NEAR            = 12,    -- ...and an orb that first appears this close to us is ours even when we didn't just cast
    OWN_WINDOW          = 3,
    -- Things the bot must never see: no danger zone, no ESP, no UI count, never a wall. Matched against the
    -- normalized name (lowercase letters/digits) of the object AND of everything it sits inside.
    IGNORE_NAMES        = { "groundaura" },

    -- ---- barriers (some bosses can't be approached) ----
    BARRIER_STUCK       = 6,     -- not moving for this long while trying to walk = something blocks us
    BARRIER_NO_PROGRESS = 16,    -- walking but not getting closer for this long = same
    BARRIER_PROGRESS    = 2,     -- must get this much closer to count as progress
    BARRIER_LEEWAY      = 15,    -- fire from up to this far past where we got stuck
    BARRIER_RETRY       = 30,    -- forget the barrier after this long and try to get closer again
    BARRIER_WALL_DIST   = 25,    -- ...only if a wall really is this close in front of us
    BARRIER_CAP         = 40,    -- a barrier never stretches the attack range more than this

    -- ---- skills ----
    BUFF_SKILLS         = { "innerrage", "enhancedinnerrage", "innerfocus", "enhancedinnerfocus" },
    READY_MAX           = 0,     -- a tool is ready when its `cooldown` value is <= this (ready = -0.1)
    FALLBACK_COOLDOWN   = 8,
    MIN_GAP             = 0.8,   -- never use the same skill twice within this
    EQUIP_DELAY         = 0.12,
    AIM_SETTLE          = 0.1,   -- let the rotation reach the server before firing
    AIM_HOLD            = 0.3,   -- stay busy this long after firing
    CAST_CONFIRM        = 0.15,  -- after firing, check the cooldown really started
    RETRY_DELAY         = 3,     -- a skill that did nothing is left alone this long
    RAGE_DURATION       = 3,     -- length of the buff until learned from the game's own cooldown numbers
    RAGE_DELAY          = 0.15,  -- after the buff, wait this long before the attack so its bonus is on
    RAGE_ESCAPE_SLACK   = 0.35,  -- spend the buff on speed when we'd escape an attack with less than this to spare
    RAGE_CROWD          = 3,     -- ...or when this many attacks are closing in and we can't attack anyway
    RAGE_CROWD_RADIUS   = 20,
    REACH_STEP          = 5,     -- the attack range shrinks/grows by this when casts miss/connect
    HIT_WINDOW          = 1.5,   -- seconds after a cast to look for a health drop
    SPAWN_SHIELD        = 5,     -- seconds of immortality after respawning: ignore attacks, go all-in

    -- ---- visuals ----
    AUTO_AIM            = true,  -- always face the target (shift-lock style)
    ESP                 = true,
    ESP_LABELS          = true,
    UI_SCALE            = 1,
}

-- =====================
-- SHARED: modules, state, helpers
-- =====================
local Npcs, Hazards, Walls, Nav, Skills, ESP, UI, Bot = {}, {}, {}, {}, {}, {}, {}, {}

local API = {}   -- filled in at the bottom: the modules, reachable as getgenv().__AutoCombat.api

local State = {
    enabled = true,
    wasEnabled = true,
    esp = Config.ESP,
    aim = Config.AUTO_AIM,
    mode = "IDLE",
    char = nil, hum = nil, hrp = nil,
    wasAlive = true,
    shieldUntil = 0,
    ignoreDirty = false,   -- ray filter needs a rebuild
}

local function flat(v)
    return Vector3.new(v.X, 0, v.Z)
end

-- one normalizer for every name comparison
local function normalize(name)
    return (tostring(name or ""):lower():gsub("[^%w]", ""))
end

-- a number off any Instance: a NumberValue child (tool.cooldown, npc.aggroRange) or an attribute
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

-- long-lived connections are tracked so Bot.stop() can drop all of them
local connections = {}
local function track(conn)
    table.insert(connections, conn)
    return conn
end

local function findTool(name)
    local bp = player:FindFirstChild("Backpack")
    return (bp and bp:FindFirstChild(name)) or (player.Character and player.Character:FindFirstChild(name)) or nil
end

local Log = { lines = {}, MAX = 6 }
function Log.add(msg)
    table.insert(Log.lines, 1, os.date("%M:%S") .. "  " .. msg)
    while #Log.lines > Log.MAX do table.remove(Log.lines) end
end

function State.setMode(mode)
    if State.mode ~= mode then
        State.mode = mode
        Log.add("State: " .. mode)
    end
end

-- the character exists, has health and its root part is in the world
function State.alive()
    return State.hum ~= nil and State.hum.Parent ~= nil and State.hum.Health > 0
        and State.hrp ~= nil and State.hrp.Parent ~= nil
end

-- =====================
-- NPCS: the dungeon's enemies
-- workspace.dungeon.<room>.enemyFolder.<npc model>, each with a Humanoid and (usually) numbers describing it:
--   aggroRange   how close you must be before it reacts (precasts, attacks) at all
--   attackSpeed  how long its attack sequence (precast + hitbox) lasts
-- =====================
Npcs.list = {}      -- { {model, root, pos, radius, humanoid, key, aggro, attackSpeed, group} }, rebuilt by refresh()
Npcs.groups = {}    -- { {members, centroid, radius, count} }
Npcs.locked = nil   -- the model we're locked onto
Npcs.lastRefresh = -math.huge
Npcs.cache = setmetatable({}, { __mode = "k" })     -- [model] = { root, radius, humanoid, key, t }
-- Precast timing left for the hitbox that follows it. Keyed by npc MODEL, because the entries in `list` are rebuilt
-- every refresh and anything stored on them would be gone before the hitbox appears.
Npcs.pending = setmetatable({}, { __mode = "k" })
Npcs.ROOTS = { "HumanoidRootPart", "Root", "RootPart" }

-- workspace.dungeon may not exist yet (lobby, loading, between runs): look it up every time instead of hanging
function Npcs.rooms()
    local d = workspace:FindFirstChild("dungeon")
    return d and d:GetChildren() or {}
end

-- a part to track; bosses often have no HumanoidRootPart
function Npcs.findRoot(model)
    for _, name in ipairs(Npcs.ROOTS) do
        local p = model:FindFirstChild(name)
        if p and p:IsA("BasePart") then return p end
    end
    if model.PrimaryPart then return model.PrimaryPart end
    for _, name in ipairs({ "Torso", "UpperTorso", "LowerTorso", "Head" }) do
        local p = model:FindFirstChild(name)
        if p and p:IsA("BasePart") then return p end
    end
    local best, bestVolume = nil, 0   -- last resort: the biggest part
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") then
            local v = d.Size.X * d.Size.Y * d.Size.Z
            if v > bestVolume then best, bestVolume = d, v end
        end
    end
    return best
end

-- Geometry is cached for ~1s (huge models aren't measured every frame); the numbers the npc publishes are cheap
-- and read fresh, so one added a moment before its first attack is never missed.
function Npcs.info(model, now)
    local info = Npcs.cache[model]
    if not (info and info.root.Parent and now - info.t < 1) then
        local root = (info and info.root.Parent) and info.root or Npcs.findRoot(model)
        if not root then return nil end
        local size = model:GetExtentsSize()
        info = {
            root = root, t = now,
            radius = math.max(0, math.max(size.X, size.Z) / 2 - Config.BODY_RADIUS),   -- body size beyond a point
            humanoid = model:FindFirstChildOfClass("Humanoid"),
            key = normalize(model.Name),
        }
        Npcs.cache[model] = info
    end
    info.aggro = readNumber(model, "aggroRange")
    info.attackSpeed = readNumber(model, "attackSpeed")
    return info
end

-- Rebuilds the list unless it is younger than `maxAge`. A NEW table every time, so a loop halfway through the old
-- one is never disturbed.
function Npcs.refresh(maxAge)
    local now = clock()
    if now - Npcs.lastRefresh < (maxAge or 0) then return end
    Npcs.lastRefresh = now

    local list = {}
    for _, room in ipairs(Npcs.rooms()) do
        local folder = room:FindFirstChild("enemyFolder")
        if folder then
            for _, model in ipairs(folder:GetChildren()) do
                if model:IsA("Model") then
                    local info = Npcs.info(model, now)
                    -- a dead npc lingering through its death animation is no longer a target
                    if info and not (info.humanoid and info.humanoid.Health <= 0) then
                        table.insert(list, {
                            model = model, root = info.root, pos = info.root.Position, radius = info.radius,
                            humanoid = info.humanoid, key = info.key, aggro = info.aggro, attackSpeed = info.attackSpeed,
                        })
                    end
                end
            end
        end
    end
    Npcs.list = list
end

-- nearest npc by SURFACE (centre distance minus its extra body radius)
function Npcs.nearest(pos)
    local best, bestDist = nil, math.huge
    for _, n in ipairs(Npcs.list) do
        local d = flat(pos - n.pos).Magnitude - n.radius
        if d < bestDist then best, bestDist = n, d end
    end
    return best, bestDist
end

-- Skills and aggro both reach by distance to an npc's CENTRE: a boss with a massive body looks "close" by its edge
-- but can still be far out of reach.
function Npcs.nearestCenter(pos)
    local best, bestDist = nil, math.huge
    for _, n in ipairs(Npcs.list) do
        local d = flat(pos - n.pos).Magnitude
        if d < bestDist then best, bestDist = n, d end
    end
    return best, bestDist
end

function Npcs.surfaceDistance(pos)
    local _, d = Npcs.nearest(pos)
    return d
end

-- npcs within GROUP_LINK of a group member join it
function Npcs.buildGroups()
    local groups = {}
    for _, n in ipairs(Npcs.list) do n.group = nil end

    for _, seed in ipairs(Npcs.list) do
        if not seed.group then
            local id = #groups + 1
            local members = { seed }
            seed.group = id

            local i = 1
            while i <= #members do
                local cur = members[i]
                for _, other in ipairs(Npcs.list) do
                    if not other.group and flat(other.pos - cur.pos).Magnitude - other.radius - cur.radius <= Config.GROUP_LINK then
                        other.group = id
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
    Npcs.groups = groups
end

-- keep the current lock until another npc is clearly closer (ties never switch)
function Npcs.pick(nearest, nearestDist, me)
    if not nearest then
        Npcs.locked = nil
        return nil
    end
    if Npcs.locked then
        for _, n in ipairs(Npcs.list) do
            if n.model == Npcs.locked then
                if flat(me - n.pos).Magnitude - n.radius <= nearestDist + Config.TARGET_SWITCH then
                    return n
                end
                break
            end
        end
    end
    Npcs.locked = nearest.model
    return nearest
end

-- How far from this npc (to its centre) skills may be used: as far as the attack reaches, but never outside the npc's
-- own aggro range - it ignores anyone out there, so there would be nothing to fight. A barrier we can't pass
-- overrides the aggro limit (nothing nearer is possible; holding fire would just leave the bot idle).
-- Returns the range and whether the aggro range is what limits it.
function Npcs.castRange(npc, barrier)
    local reach = Skills.reach
    if barrier and not barrier.holdFire then
        return math.min(math.max(reach, barrier.centerDist + Config.BARRIER_LEEWAY), reach + Config.BARRIER_CAP), false
    end
    local aggro = npc and npc.aggro
    if Config.USE_AGGRO_RANGE and aggro and aggro > 0 then
        local inside = math.max(aggro - Config.AGGRO_MARGIN, Config.MIN_DISTANCE + 2)
        if inside < reach then return inside, true end
    end
    return reach, false
end

-- the strictest cast range in a group: standing inside it puts every npc of the group in reach
function Npcs.groupRange(group, barrier)
    local range = nil
    for _, m in ipairs(group and group.members or {}) do
        local r = Npcs.castRange(m, barrier)
        if not range or r < range then range = r end
    end
    return range or Skills.reach
end

-- ---- matching an attack to the npc that cast it ----
-- Games very often name an attack after its caster ("Northern Mage" -> "northernmageshot"). The name is far more
-- reliable than distance (a ranged attack can land anywhere; several npcs of one type stand close together), so it
-- is tried first. The LONGEST matching npc name wins.
function Npcs.ownerByName(attackName)
    local attack = normalize(attackName)
    if attack == "" then return nil end
    Npcs.refresh(0.05)   -- this runs the instant an attack appears: don't miss an npc that just spawned
    local best, bestLen = nil, 0
    for _, n in ipairs(Npcs.list) do
        if n.key ~= "" and #n.key > bestLen and attack:find(n.key, 1, true) then
            best, bestLen = n, #n.key
        end
    end
    return best
end

function Npcs.ownerOf(attackName, pos)
    local byName = Npcs.ownerByName(attackName)
    if byName then return byName end
    local nearest, nearestD = nil, math.huge
    for _, n in ipairs(Npcs.list) do
        local d = flat(pos - n.pos).Magnitude
        if d < nearestD then nearest, nearestD = n, d end
    end
    if nearest and nearestD <= Config.OWNER_MAX_DIST then return nearest end
    return nil
end

function Npcs.setPending(model, born, length)
    Npcs.pending[model] = { born = born, length = length, at = clock() }
end

-- the timing a precast left for the hitbox that follows it (consumed once, valid for 2s)
function Npcs.takePending(attackName, pos, now)
    local owner = Npcs.ownerByName(attackName)
    local pending = owner and Npcs.pending[owner.model]
    if not pending then   -- fall back to the nearest npc with a sequence pending
        local nearest, nearestD = nil, math.huge
        for _, n in ipairs(Npcs.list) do
            if Npcs.pending[n.model] then
                local d = flat(pos - n.pos).Magnitude
                if d < nearestD then nearest, nearestD = n, d end
            end
        end
        if nearest and nearestD <= Config.OWNER_MAX_DIST then
            owner, pending = nearest, Npcs.pending[nearest.model]
        end
    end
    if pending and now - pending.at < 2.0 then
        Npcs.pending[owner.model] = nil
        return pending
    end
    return nil
end

-- =====================
-- HAZARDS: attack zones, and every "is this spot dangerous" question
--   precast  telegraph; fires PRECAST_DELAY seconds after it appears
--   hitbox   active now (its duration is worked out so it becomes safe to cross once over)
--   orb      a moving part (battleMageOrb), recognised by name or by its Trail / Attachment / Mist
--   unknown  a loose Model dropped into workspace: a possible attack until it has been around too long
-- Each zone's geometry (cf / size / pos / velocity) is read once per frame by update() and reused by every query.
-- =====================
Hazards.COLORS = {
    precast = Color3.fromRGB(255, 170, 0),
    hitbox  = Color3.fromRGB(255, 40, 40),
    orb     = Color3.fromRGB(190, 60, 255),
    unknown = Color3.fromRGB(255, 90, 170),
}

Hazards.active = {}      -- [part or model] = zone
Hazards.skip = setmetatable({}, { __mode = "k" })      -- objects decided NOT to be attacks (our own casts, scenery, ignore list)
Hazards.expired = setmetatable({}, { __mode = "k" })   -- attacks that ended while their part still exists
Hazards.watched = setmetatable({}, { __mode = "k" })   -- objects with a Destroying handler already
Hazards.seen = setmetatable({}, { __mode = "k" })      -- [top-level part] = when the re-check scan first looked at it
Hazards.hidden = setmetatable({}, { __mode = "k" })    -- objects on the ignore list (or inside one): the registry the raycasts use
Hazards.nameCache = {}                                 -- raw name -> on the ignore list?
Hazards.nameCount = 0
Hazards.lastScan = 0

-- ---- the ignore list (ground aura ...) ----

-- Any name CONTAINING an entry matches, after normalizing: "Ground Aura", "GroundAura_2" and "groundaura-big" all do.
function Hazards.nameIgnored(raw)
    local cached = Hazards.nameCache[raw]
    if cached ~= nil then return cached end
    local key = normalize(raw)
    local hit = false
    for _, ignore in ipairs(Config.IGNORE_NAMES) do
        if ignore ~= "" and key:find(ignore, 1, true) then
            hit = true
            break
        end
    end
    Hazards.nameCount = Hazards.nameCount + 1
    if Hazards.nameCount > 4000 then   -- a game that gives every effect part a unique name must not grow this forever
        Hazards.nameCache, Hazards.nameCount = {}, 1
    end
    Hazards.nameCache[raw] = hit
    return hit
end

-- on the ignore list, or inside something that is? Positive answers are remembered (and registered for the raycasts)
function Hazards.isIgnored(obj)
    if Hazards.hidden[obj] then return true end
    local cur = obj
    while cur and cur ~= workspace do
        if Hazards.nameIgnored(cur.Name) then
            Hazards.hidden[obj] = true
            return true
        end
        cur = cur.Parent
    end
    return false
end

-- ---- classification ----

function Hazards.inCharacter(obj)
    local cur = obj
    while cur and cur ~= workspace do
        if cur:IsA("Model") and Players:GetPlayerFromCharacter(cur) then return true end
        cur = cur.Parent
    end
    return false
end

-- an attack that appears close to us right after we cast is our own
function Hazards.isOurs(pos)
    local d = flat(pos - State.hrp.Position).Magnitude
    return d <= ((clock() < Skills.castUntil) and Config.OWN_RADIUS or Config.OWN_NEAR)
end

-- battleMageOrb is a plain Part whose name can vary: look INSIDE it for a trail, attachment or mist
function Hazards.looksLikeOrb(obj, name)
    if name:find(Config.ORB_NAME, 1, true) then return true end
    for _, d in ipairs(obj:GetDescendants()) do
        if d:IsA("Trail") or d:IsA("Attachment") or d.Name:lower():find("mist", 1, true) then
            return true
        end
    end
    return false
end

function Hazards.kindOf(obj)
    local name = normalize(obj.Name)
    if name:find("precast", 1, true) then return "precast" end
    if name:find("hitbox", 1, true) then return "hitbox" end

    -- Beyond the two names above, only parts sitting directly in workspace are considered: permanent scenery lives
    -- inside a container, real attacks are created fresh and destroyed once they end.
    if obj.Parent ~= workspace then return nil end

    -- a part named after a known npc ("northernmageshot" contains "northernmage") is almost certainly its attack
    if Npcs.ownerByName(name) then
        if Hazards.isOurs(obj.Position) and clock() < Skills.castUntil then
            Hazards.skip[obj] = true
            return nil
        end
        return "hitbox"
    end

    if Hazards.looksLikeOrb(obj, name) then
        if Hazards.isOurs(obj.Position) then
            Hazards.skip[obj] = true
            return nil
        end
        return "orb"
    end
    return nil
end

function Hazards.classify(obj)
    if not obj:IsA("BasePart") or obj.ClassName == "Terrain" or Hazards.skip[obj] then return nil end
    if obj.Name:sub(1, 1) == "_" then return nil end   -- everything this script draws is named with a leading underscore
    if Hazards.isIgnored(obj) then
        Hazards.skip[obj] = true   -- decided once: later scans skip it without even looking
        return nil
    end
    local kind = Hazards.kindOf(obj)
    if kind and Hazards.inCharacter(obj) then return nil end   -- never our body, nor another player's
    return kind
end

function Hazards.orbRadius(part)
    return math.max(part.Size.X, part.Size.Y, part.Size.Z) / 2 + Config.ORB_PADDING
end

-- ---- how long a hitbox stays active ----

-- a lifetime published on the part or its model, if the game has one
function Hazards.probe(part)
    local holders = { part }
    if part.Parent and part.Parent ~= workspace then table.insert(holders, part.Parent) end
    for _, holder in ipairs(holders) do
        for _, name in ipairs({ "lifetime", "duration", "attackDuration" }) do
            local v = readNumber(holder, name)
            if v and v > 0 then return v end
        end
    end
    return nil
end

-- In order of reliability: the precast right before it left the sequence's timing; a lifetime on the part; the owning
-- npc's attackSpeed. zone.duration is measured from zone.born.
function Hazards.resolve(zone, now)
    local obj = zone.obj
    local pending = Npcs.takePending(obj.Name, zone.pos, now)
    if pending then
        local remaining = pending.length - (now - pending.born)
        if remaining > 0.05 then
            zone.duration = (now - zone.born) + remaining
            return true
        end
    end

    local d = Hazards.probe(obj)
    if not d then
        local owner = Npcs.ownerOf(obj.Name, zone.pos)
        d = owner and owner.attackSpeed
    end
    if d and d > 0 then
        zone.duration = d
        return true
    end

    if now - zone.born > 2 then zone.gaveUp = true end   -- nothing found: dangerous for as long as it exists
    return false
end

-- ---- creating / removing zones ----

function Hazards.newZone(obj, kind, initial, cf, size, isModel)
    local now = clock()
    return {
        obj = obj, kind = kind, isModel = isModel,
        -- a zone that already existed when we loaded is probably part-way through its sequence
        born = initial and (now - Config.PRECAST_DELAY * 0.6) or now,
        cf = cf, size = size, pos = cf.Position,
        vel = Vector3.zero, flatVel = Vector3.zero, moving = false,
        lastPos = cf.Position, lastT = now,
        radius = 0,
    }
end

-- the one Destroying handler an object ever gets (a reused part can be added many times)
function Hazards.watch(obj)
    if Hazards.watched[obj] then return end
    Hazards.watched[obj] = true
    obj.Destroying:Connect(function()
        local zone = Hazards.active[obj]
        if zone and zone.kind == "precast" then
            -- Leave the sequence's start + length with the owning npc, so the hitbox that follows (even with an
            -- unrelated name) can work out how long it has left.
            local owner = Npcs.ownerOf(obj.Name, zone.pos)
            local length = zone.seq or (owner and owner.attackSpeed)
            if owner and length and length > 0 then Npcs.setPending(owner.model, zone.born, length) end
        end
        Hazards.remove(obj)
    end)
end

function Hazards.add(obj, initial, fromEvent)
    if Hazards.active[obj] or Hazards.skip[obj] then return end
    if Hazards.expired[obj] then
        if not fromEvent then return end   -- the polling scan must not resurrect it
        Hazards.expired[obj] = nil         -- the game re-added it: a new life of a reused part
    end

    local kind = Hazards.classify(obj)
    if not kind then return end

    local zone = Hazards.newZone(obj, kind, initial, obj.CFrame, obj.Size, false)
    if kind == "orb" then zone.radius = Hazards.orbRadius(obj) end
    if kind == "precast" then   -- the npc's attackSpeed is the whole sequence's length
        local owner = Npcs.ownerOf(obj.Name, zone.pos)
        zone.seq = owner and owner.attackSpeed or nil
    end

    Hazards.active[obj] = zone
    State.ignoreDirty = true
    ESP.attach(zone)
    Log.add(kind .. ": " .. obj.Name)
    Hazards.watch(obj)

    if kind == "hitbox" then Hazards.resolve(zone, clock()) end
end

-- A Model dropped into workspace counts as an attack too (its bounding box stands in for CFrame/Size). Models that
-- were already there when we started are scenery.
function Hazards.addModel(model, initial)
    if not Config.MODELS_ARE_ATTACKS or initial then return end
    if Hazards.active[model] or Hazards.skip[model] or model.Parent ~= workspace then return end
    if model == workspace:FindFirstChild("dungeon") or model == workspace:FindFirstChild("map") then return end
    if Hazards.isIgnored(model) then
        Hazards.skip[model] = true
        return
    end
    if Hazards.inCharacter(model) or model:FindFirstChildOfClass("Humanoid") then return end   -- bodies aren't attacks

    local ok, cf, size = pcall(function() return model:GetBoundingBox() end)
    if not ok or not cf then return end
    if Hazards.isOurs(cf.Position) and clock() < Skills.castUntil then
        Hazards.skip[model] = true
        return
    end

    local zone = Hazards.newZone(model, "unknown", false, cf, size, true)
    Hazards.active[model] = zone
    State.ignoreDirty = true
    ESP.attach(zone)
    Log.add("model: " .. model.Name)
    Hazards.watch(model)
end

function Hazards.remove(obj)
    local zone = Hazards.active[obj]
    if not zone then return end
    Hazards.active[obj] = nil
    State.ignoreDirty = true
    ESP.detach(zone)
end

-- The attack ran its course but the part still exists. The polling scan won't re-flag it; if the game re-adds it
-- (a pooled hitbox part), that is a NEW attack. Parts of the same multi-part attack (appeared together under the
-- same model) go with it.
function Hazards.expire(obj)
    local zone = Hazards.active[obj]
    Hazards.expired[obj] = true
    Hazards.remove(obj)
    local model = zone and obj.Parent
    if model and model ~= workspace and model:IsA("Model") then
        for _, d in ipairs(model:GetDescendants()) do
            local other = d:IsA("BasePart") and Hazards.active[d]
            if other and math.abs(other.born - zone.born) <= 1 then
                Hazards.expired[d] = true
                Hazards.remove(d)
            end
        end
    end
end

-- scenery: never looked at again
function Hazards.dismiss(obj)
    Hazards.skip[obj] = true
    Hazards.remove(obj)
end

-- ---- per-frame upkeep ----

function Hazards.refreshGeometry(obj, zone)
    if zone.isModel then
        local ok, cf, size = pcall(function() return obj:GetBoundingBox() end)
        if ok and cf then zone.cf, zone.size = cf, size end
    else
        zone.cf, zone.size = obj.CFrame, obj.Size
    end
    zone.pos = zone.cf.Position
end

function Hazards.update(now)
    for obj, zone in pairs(Hazards.active) do
        if not obj.Parent then
            Hazards.remove(obj)
        else
            Hazards.refreshGeometry(obj, zone)

            -- velocity of EVERY attack: moving hitboxes / sweeping beams are extrapolated, not just orbs
            local dt = now - zone.lastT
            if dt > 0 then
                zone.vel = zone.vel:Lerp((zone.pos - zone.lastPos) / dt, 0.5)
                zone.lastPos = zone.pos
                zone.lastT = now
            end
            zone.moving = flat(zone.vel).Magnitude > 0.7

            local age = now - zone.born
            if zone.kind == "orb" then
                local v = zone.vel
                local av = obj.AssemblyLinearVelocity
                if av.Magnitude > v.Magnitude then v = av end
                zone.flatVel = flat(v)
            elseif zone.kind == "hitbox" then
                if not zone.duration and not zone.gaveUp and now >= (zone.nextResolve or 0) then
                    zone.nextResolve = now + 0.1
                    Hazards.resolve(zone, now)
                end
                if zone.duration and age >= zone.duration + 0.05 then
                    Hazards.expire(obj)
                end
            elseif zone.kind == "unknown" and age > Config.UNKNOWN_MAX_AGE then
                Hazards.dismiss(obj)   -- around far longer than any attack: scenery
            end
        end
    end
end

-- An orb's Trail / Attachment / Mist can be added AFTER the part appears, so top-level parts are re-checked for a
-- short while. Older ones are skipped: re-classifying every static part four times a second is pure waste.
function Hazards.scan(now)
    if now - Hazards.lastScan < 0.25 then return end
    Hazards.lastScan = now

    for _, child in ipairs(workspace:GetChildren()) do
        if child:IsA("BasePart") and not Hazards.active[child] and not Hazards.skip[child] then
            local first = Hazards.seen[child]
            if not first then
                first = now
                Hazards.seen[child] = now
            end
            if now - first <= Config.ORB_RECHECK then
                Hazards.add(child)
            end
        end
    end
end

function Hazards.onAdded(obj)
    if obj:IsA("BasePart") then
        Hazards.add(obj, nil, true)
    elseif obj:IsA("Model") or obj:IsA("Folder") then
        for _, d in ipairs(obj:GetDescendants()) do
            if d:IsA("BasePart") then Hazards.add(d, nil, true) end
        end
        if obj:IsA("Model") then Hazards.addModel(obj) end
    end
end

function Hazards.start()
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("BasePart") then pcall(Hazards.add, obj, true) end
    end
    track(workspace.DescendantAdded:Connect(function(obj)
        local ok, err = pcall(Hazards.onAdded, obj)
        if not ok then Bot.reportError("hazards", err) end
    end))
end

-- ---- danger queries ----

-- seconds until the zone becomes harmful (0 = harmful right now)
function Hazards.timeToFire(zone, now)
    if zone.kind == "precast" then
        return math.max(0, Config.PRECAST_DELAY - (now - zone.born))
    end
    return 0
end

-- seconds until an active zone stops being dangerous (math.huge = unknown: dangerous while it exists)
function Hazards.timeToEnd(zone, now)
    if zone.duration then
        return math.max(0, zone.duration - (now - zone.born))
    end
    return math.huge
end

-- Flat distance from `pos` to the path an orb sweeps between t0 and t1 seconds from now. Orbs are judged by WHERE THEY
-- WILL BE: a spot just ahead of an orb on its own line is safe only until the orb gets there.
local function orbDistance(zone, pos, t0, t1)
    local v = zone.flatVel
    local a = flat(zone.pos) + v * t0
    local ab = v * (t1 - t0)
    local p = flat(pos)
    local u = 0
    local len2 = ab:Dot(ab)
    if len2 > 0.001 then u = math.clamp((p - a):Dot(ab) / len2, 0, 1) end
    return (p - (a + ab * u)).Magnitude
end

-- the part of an orb's flight that matters: when we're only passing through (t = when), or when we'll stay at the spot
-- (settle, or t = inf): everything from now until ORB_HORIZON
local function orbWindow(t, settle)
    if settle or t == math.huge then return 0, Config.ORB_HORIZON end
    local t0 = math.max(t or 0, 0)
    return t0, t0 + Config.ORB_STAY
end

-- Is `pos` inside this zone, with `pad` studs of margin? `t` = seconds from now (a moving zone is shifted to where it
-- will be by then; an orb is judged at that time, see orbWindow).
function Hazards.contains(zone, pos, pad, t, settle)
    pad = pad or Config.PADDING
    if zone.kind == "orb" then
        local t0, t1 = orbWindow(t, settle)
        return orbDistance(zone, pos, t0, t1) <= zone.radius - math.max(0, Config.PADDING - pad)
    end
    local p = pos
    if t and t > 0 and zone.moving then
        p = pos - zone.vel * math.min(t, Config.PREDICT_MAX)   -- same as moving the zone forward
    end
    local l = zone.cf:PointToObjectSpace(p)
    local half = zone.size / 2
    return math.abs(l.X) <= half.X + pad and math.abs(l.Y) <= half.Y + pad and math.abs(l.Z) <= half.Z + pad
end

-- Would standing at `pos` t seconds from now be inside a zone that is active by then? (a precast we can cross and
-- leave before it fires does NOT count; neither does a hitbox that will have ended). `settle` = we'll stay there.
function Hazards.dangerAt(pos, t, pad, settle)
    local now = clock()
    for _, zone in pairs(Hazards.active) do
        if zone.kind == "precast" and t < Hazards.timeToFire(zone, now) - Config.PRECAST_SAFETY then
            -- not active yet by the time we'd be there
        elseif zone.kind ~= "orb" and t < math.huge and zone.duration
            and t >= Hazards.timeToEnd(zone, now) + Config.PRECAST_SAFETY then
            -- over by the time we'd be there
        else
            if Hazards.contains(zone, pos, pad, t, settle) then return true end
            -- a destination (t = inf) must also survive a moving zone sweeping across it
            if (t == math.huge or settle) and zone.moving and zone.kind ~= "orb"
                and (Hazards.contains(zone, pos, pad, Config.PREDICT_MAX * 0.5) or Hazards.contains(zone, pos, pad, 0)) then
                return true
            end
        end
    end
    return false
end

function Hazards.dangerNow(pos, pad) return Hazards.dangerAt(pos, 0, pad) end                              -- hit within the next second?
function Hazards.destinationDanger(pos, pad) return Hazards.dangerAt(pos, Config.SAFE_WINDOW, pad, true) end -- a spot to settle at
function Hazards.insideAny(pos, pad) return Hazards.dangerAt(pos, math.huge, pad) end                      -- a spot to sit at for long

-- Do we need to dodge? Something hits where we stand within a second, or a precast / a further-off orb is coming
-- (DODGE_LEAD ahead): leaving early costs nothing.
function Hazards.threatened(pos)
    return Hazards.dangerAt(pos, 0) or Hazards.dangerAt(pos, Config.DODGE_LEAD)
end

-- samples along a->b that would be inside an active zone when we get there
function Hazards.routeDanger(a, b, speed, pad)
    local dist = flat(b - a).Magnitude
    local steps = math.clamp(math.ceil(dist / 3), 3, 10)   -- a sample every ~3 studs, so a thin beam can't slip between
    local n = 0
    for i = 1, steps do
        local f = i / steps
        if Hazards.dangerAt(a:Lerp(b, f), (dist * f) / speed + Config.REACTION, pad) then n = n + 1 end
    end
    return n
end

-- time until we're out of every zone when walking a->b
function Hazards.exitTime(a, b, speed, pad)
    local dist = flat(b - a).Magnitude
    for i = 1, 8 do
        if not Hazards.insideAny(a:Lerp(b, i / 8), pad) then
            return (dist * i / 8) / speed + Config.REACTION
        end
    end
    return dist / speed + Config.REACTION
end

-- seconds until the soonest zone containing `pos` fires (0 = already harmful, inf = not inside any)
function Hazards.deadline(pos)
    local now = clock()
    local d = math.huge
    for _, zone in pairs(Hazards.active) do
        if Hazards.contains(zone, pos) then d = math.min(d, Hazards.timeToFire(zone, now)) end
    end
    return d
end

-- studs between `pos` and the edge of ONE zone (0 = inside)
function Hazards.zoneClearance(zone, pos, pad)
    if zone.kind == "orb" then
        return math.max(0, orbDistance(zone, pos, 0, Config.ORB_HORIZON) - zone.radius)
    end
    pad = pad or Config.PADDING
    local l = zone.cf:PointToObjectSpace(pos)
    local half = zone.size / 2
    local dx = math.max(math.abs(l.X) - (half.X + pad), 0)
    local dy = math.max(math.abs(l.Y) - (half.Y + pad), 0)
    local dz = math.max(math.abs(l.Z) - (half.Z + pad), 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- studs to the edge of the NEAREST zone (0 = inside one, huge = none around)
function Hazards.clearance(pos, pad)
    local best = math.huge
    for _, zone in pairs(Hazards.active) do
        best = math.min(best, Hazards.zoneClearance(zone, pos, pad))
    end
    return best
end

function Hazards.nearby(pos, radius)
    local n = 0
    for _, zone in pairs(Hazards.active) do
        if Hazards.zoneClearance(zone, pos) <= radius then n = n + 1 end
    end
    return n
end

function Hazards.counts(now)
    local c = { precast = 0, hitbox = 0, orb = 0, unknown = 0, soonest = math.huge }
    for _, zone in pairs(Hazards.active) do
        c[zone.kind] = c[zone.kind] + 1
        if zone.kind == "precast" then c.soonest = math.min(c.soonest, Hazards.timeToFire(zone, now)) end
    end
    return c
end

-- =====================
-- WALLS: raycasts against the map
-- Everything solid counts as a wall. Rays ignore characters, npcs, attack zones, our own visuals and everything on the
-- ignore list; every part under workspace.map is cast against directly, solid or not, so nothing in the map is missed.
-- =====================
Walls.rayParams = RaycastParams.new()
Walls.rayParams.FilterType = Enum.RaycastFilterType.Exclude
Walls.rayParams.RespectCanCollide = true
Walls.rayParams.IgnoreWater = true

Walls.mapParams = RaycastParams.new()
Walls.mapParams.FilterType = Enum.RaycastFilterType.Include
Walls.mapParams.FilterDescendantsInstances = {}

Walls.LATERALS = { -2, 0, 2 }    -- body width (AgentRadius = 2)
Walls.HEIGHTS = { -1.5, 1 }      -- near the feet and mid-body
Walls.MARGIN = 2                 -- extra studs of clearance beyond a destination
Walls.DIRS = {}
for i = 0, 7 do
    local r = math.rad(i * 45)
    table.insert(Walls.DIRS, Vector3.new(math.cos(r), 0, math.sin(r)))
end
Walls.lastRefresh = 0

function Walls.refresh(now)
    if not State.ignoreDirty and now - Walls.lastRefresh < 0.5 then return end
    State.ignoreDirty = false
    Walls.lastRefresh = now

    local map = workspace:FindFirstChild("map")
    Walls.mapParams.FilterDescendantsInstances = map and { map } or {}

    local list = {}
    if player.Character then table.insert(list, player.Character) end
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then table.insert(list, p.Character) end
    end
    local drawn = workspace:FindFirstChild("_AutoCombat")
    if drawn then table.insert(list, drawn) end
    for _, room in ipairs(Npcs.rooms()) do
        local folder = room:FindFirstChild("enemyFolder")
        if folder then table.insert(list, folder) end
    end
    for obj in pairs(Hazards.active) do
        if obj.Parent then table.insert(list, obj) end
    end
    -- the ground aura & co are visual effects: they must not read as walls or floor
    for obj in pairs(Hazards.hidden) do
        if obj.Parent then table.insert(list, obj) end
    end
    Walls.rayParams.FilterDescendantsInstances = list

    -- respect the collision group the character uses, so the walls that block us are the walls the rays see
    if State.hrp and State.hrp.Parent then
        Walls.rayParams.CollisionGroup = State.hrp.CollisionGroup
    end
end

-- casts against everything solid plus everything in the map; the nearer hit wins
function Walls.cast(origin, direction)
    local a = workspace:Raycast(origin, direction, Walls.rayParams)
    if #Walls.mapParams.FilterDescendantsInstances == 0 then return a end

    local b = workspace:Raycast(origin, direction, Walls.mapParams)
    -- an Include filter can't exclude anything, so an ignored part inside the map is dropped from the result
    if b and Hazards.hidden[b.Instance] then b = nil end
    if a and b then return (a.Distance <= b.Distance) and a or b end
    return a or b
end

function Walls.floorBelow(pos)
    return Walls.cast(pos + Vector3.new(0, 2, 0), Vector3.new(0, -14, 0)) ~= nil
end

-- body-wide sweep from a to b (6 rays, plus a margin past b) + a floor check under b
function Walls.moveClear(a, b)
    local dir = b - a
    local flatDir = flat(dir)
    if flatDir.Magnitude < 0.01 then return true end

    local unit = flatDir.Unit
    local right = unit:Cross(Vector3.yAxis)
    local rayDir = dir + unit * Walls.MARGIN
    for _, lat in ipairs(Walls.LATERALS) do
        for _, h in ipairs(Walls.HEIGHTS) do
            if Walls.cast(a + right * lat + Vector3.new(0, h, 0), rayDir) then
                return false
            end
        end
    end
    return Walls.floorBelow(b)
end

-- 0 = open space, higher = closer to walls on more sides (avoids corner traps)
function Walls.penalty(pos)
    local pen = 0
    for _, d in ipairs(Walls.DIRS) do
        local hit = Walls.cast(pos, d * Config.WALL_CLEARANCE)
        if hit then pen = pen + (Config.WALL_CLEARANCE - hit.Distance) / Config.WALL_CLEARANCE end
    end
    return pen
end

-- =====================
-- NAV: movement, facing, path walking, choosing where to stand
-- Humanoid:Move(direction) is used instead of MoveTo(point): Move() is pure velocity and never touches facing, so it
-- coexists with us setting the rotation ourselves every frame (AutoRotate = false is built for exactly this).
-- =====================
Nav.goal = nil            -- where Humanoid:Move is taking us, or nil to stand still
Nav.aim = nil             -- the point to face (set by the bot every frame)
Nav.ownsRotation = false
Nav.pathThread = nil
Nav.pathing = false       -- a path is being walked
Nav.computing = false     -- a path is being computed
Nav.pathGoal = nil        -- destination of the path being walked
Nav.controls = nil
Nav.spot = nil            -- the last spot the local search chose (sticky, so the choice doesn't flicker)
Nav.lastPos = nil
Nav.lastMove = clock()

function Nav.setGoal(pos) Nav.goal = pos end
function Nav.stop() Nav.goal = nil end

-- Every frame while the bot is on (only then does it own the humanoid's movement).
function Nav.drive()
    if not State.enabled then return end

    local char = player.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not root or not hum then return end

    if Nav.goal then
        local delta = flat(Nav.goal - root.Position)
        if delta.Magnitude > 1 then
            hum:Move(delta.Unit, false)
        else
            hum:Move(Vector3.zero, false)
            Nav.goal = nil
        end
    else
        hum:Move(Vector3.zero, false)
    end

    local face = (State.aim and Nav.aim) or Nav.goal
    if face then
        local delta = flat(face - root.Position)
        if delta.Magnitude > 0.5 then
            Nav.ownsRotation = true
            hum.AutoRotate = false
            local vel = root.AssemblyLinearVelocity
            root.CFrame = CFrame.lookAt(root.Position, root.Position + delta)
            root.AssemblyLinearVelocity = vel
        end
    elseif Nav.ownsRotation then
        Nav.ownsRotation = false
        hum.AutoRotate = true
    end
end

-- The game's own WASD controller re-asserts "no keys held" every frame and silently overwrites Humanoid:Move(), so
-- the bot could face the npcs but never walk. Taking the native controls while the bot runs is the standard fix; they
-- are handed straight back when it stops.
function Nav.getControls()
    if Nav.controls then return Nav.controls end
    local ok, result = pcall(function()
        local scripts = player:WaitForChild("PlayerScripts", 5)
        return require(scripts:WaitForChild("PlayerModule", 5)):GetControls()
    end)
    if ok then Nav.controls = result end
    return Nav.controls
end

function Nav.setControls(on)
    local controls = Nav.getControls()
    if not controls then
        if not on then Log.add("Couldn't find the default controls - movement may fight your own input") end
        return
    end
    pcall(function()
        if on then controls:Enable() else controls:Disable() end
    end)
end

-- ---- stuck detection ----

function Nav.stuck()
    local pos = State.hrp.Position
    if not Nav.lastPos then
        Nav.lastPos = pos
        return false
    end
    if (pos - Nav.lastPos).Magnitude > Config.STUCK_MOVE then
        Nav.lastPos = pos
        Nav.lastMove = clock()
        return false
    end
    return clock() - Nav.lastMove >= Config.STUCK_TIME
end

-- ---- walking a computed path ----

function Nav.stopPath()
    if Nav.pathThread then
        task.cancel(Nav.pathThread)
        Nav.pathThread = nil
    end
    Nav.pathing = false
end

-- something that should pull us off a walk: a zone about to fire where we stand, or an npc right on top of us
function Nav.interrupted()
    local pos = State.hrp.Position
    return Hazards.threatened(pos) or Npcs.surfaceDistance(pos) < Config.MIN_DISTANCE
end

function Nav.walk(waypoints)
    Nav.stopPath()
    Nav.pathing = true

    Nav.pathThread = task.spawn(function()
        for i = 2, #waypoints do
            local wp = waypoints[i]
            if not State.enabled or not State.alive() or Nav.interrupted() then break end

            if wp.Action == Enum.PathWaypointAction.Jump then State.hum.Jump = true end
            Nav.setGoal(wp.Position)

            local started = clock()
            while true do
                task.wait(0.05)
                if not State.enabled or not State.alive() or Nav.interrupted() then
                    Nav.pathing = false
                    Nav.pathThread = nil
                    return
                end
                if (wp.Position - State.hrp.Position).Magnitude <= Config.WAYPOINT_REACHED then break end
                if clock() - started >= Config.WAYPOINT_TIMEOUT then break end
            end
        end
        Nav.pathing = false
        Nav.pathThread = nil
    end)
end

-- Returns true when a path was started (or the situation changed while it computed, so there is nothing to do).
function Nav.pathTo(pos)
    local path = PathfindingService:CreatePath({ AgentHeight = 5, AgentRadius = 2, AgentCanJump = true, AgentCanClimb = false })
    local ok = pcall(function() path:ComputeAsync(State.hrp.Position, pos) end)

    if not State.enabled or not State.alive() or Nav.interrupted() then return true end
    if not ok or path.Status ~= Enum.PathStatus.Success then return false end

    local waypoints = path:GetWaypoints()
    if #waypoints == 0 then return false end

    Nav.pathGoal = pos
    ESP.drawPath(waypoints)
    Nav.walk(waypoints)
    return true
end

-- is an attack zone (live now, or live by the time we get there) on the way we're walking?
function Nav.aheadBlocked()
    local md = State.hum.MoveDirection
    if md.Magnitude < 0.1 then return false end
    local dir = flat(md).Unit
    local speed = math.max(State.hum.WalkSpeed, 8)
    local from = State.hrp.Position
    for d = 3, math.max(8, speed * 0.9), 3 do
        if Hazards.dangerAt(from + dir * d, d / speed + Config.REACTION) then return true end
    end
    return false
end

-- ---- where to stand ----

-- How far from a group's centre to stand: inside the cast range (and so inside the npcs' aggro range), but never
-- closer than BIG_BODY_GAP to the edge of a huge body.
function Nav.ringRadius(group, barrier)
    local range = Npcs.groupRange(group, barrier)
    return math.max(range - Config.RANGE_MARGIN, group.radius + Config.BIG_BODY_GAP, Config.MIN_DISTANCE + 6)
end

-- legal points on that ring, nearest to us first
function Nav.ringPoints(group, barrier)
    local ringR = Nav.ringRadius(group, barrier)
    local me = State.hrp.Position
    local pts = {}
    for angle = 0, 345, 15 do
        local r = math.rad(angle)
        local p = Vector3.new(group.centroid.X + math.cos(r) * ringR, group.centroid.Y, group.centroid.Z + math.sin(r) * ringR)
        if Npcs.surfaceDistance(p) >= Config.MIN_DISTANCE + 1 and not Hazards.insideAny(p) and Walls.floorBelow(p) then
            table.insert(pts, p)
        end
    end
    table.sort(pts, function(a, b) return flat(a - me).Magnitude < flat(b - me).Magnitude end)
    return pts, ringR
end

-- Cheap (no raycasts) legality + score for standing at `cand`. nil = illegal. Lower is better.
function Nav.scoreSpot(from, cand, ctx)
    -- the destination must be safe by the time we get there and settle
    if Hazards.destinationDanger(cand) then return nil end

    -- the route may cross a precast we can leave before it fires, but never an active zone (unless we're already in one)
    local crossings = Hazards.routeDanger(from, cand, ctx.speed)
    if crossings > 0 and not ctx.threatened then return nil end

    -- never into an npc: at the destination, and along the way (if we're already too close the route just can't get closer)
    local _, surface = Npcs.nearest(cand)
    if surface < Config.MIN_DISTANCE then return nil end
    local floor = math.min(Config.MIN_DISTANCE - 1, ctx.startSurface) - 0.5
    for i = 1, 3 do
        if Npcs.surfaceDistance(from:Lerp(cand, i / 4)) < floor then return nil end
    end

    local score = crossings * 8

    -- already in a zone: we must be OUT before it fires; spots we can't leave in time are heavily penalised
    if ctx.threatened then
        local exit = Hazards.exitTime(from, cand, ctx.speed)
        local late = exit - (ctx.deadline - Config.PRECAST_SAFETY)
        if late > 0 then score = score + 5 + late * 25 end
        score = score + exit * 4   -- among ways out, take the quickest
    end

    -- stay inside the cast range, measured to the npc's centre
    local _, centre = Npcs.nearestCenter(cand)
    local high = ctx.range * 0.95
    if centre > high then score = score + (centre - high) * 6 end

    for _, n in ipairs(Npcs.list) do   -- mild penalty for standing right in front of an npc, and for crowding it
        local toCand = flat(cand - n.pos)
        local dist = toCand.Magnitude
        if dist < Config.FLANK_RANGE and dist > 0.01 then
            local facing = flat(n.root.CFrame.LookVector)
            if facing.Magnitude > 0.01 then
                local dot = facing.Unit:Dot(toCand.Unit)
                if dot > 0.3 then score = score + (dot - 0.3) * 4 end
            end
            score = score + math.max(0, (Config.FLANK_RANGE - dist) / Config.FLANK_RANGE) * 0.5
        end
    end

    score = score + (cand - from).Magnitude * 0.15   -- don't run further than needed
    if Nav.spot and flat(cand - Nav.spot).Magnitude < 3 then score = score - 4 end   -- stay with the last choice
    return score
end

-- The best nearby spot: score everything cheaply, then wall-test only the best few.
function Nav.findSpot(threatened, range)
    local from = State.hrp.Position
    local ctx = {
        range = range,
        speed = math.max(State.hum.WalkSpeed, 8),
        threatened = threatened,
        startSurface = Npcs.surfaceDistance(from),
        deadline = Hazards.deadline(from),
    }

    local cands = {}
    for _, radius in ipairs(Config.SEARCH_RADII) do
        for angle = 0, 359, Config.SEARCH_ANGLE_STEP do
            local r = math.rad(angle)
            local cand = from + Vector3.new(math.cos(r) * radius, 0, math.sin(r) * radius)
            local s = Nav.scoreSpot(from, cand, ctx)
            if s then table.insert(cands, { pos = cand, score = s }) end
        end
    end
    if #cands == 0 then return nil end
    table.sort(cands, function(a, b) return a.score < b.score end)

    local best, bestScore, checked, clear = nil, math.huge, 0, 0
    for _, c in ipairs(cands) do
        if checked >= Config.WALL_CHECKS or clear >= 8 then break end
        checked = checked + 1
        if Walls.moveClear(from, c.pos) then
            clear = clear + 1
            local total = c.score + Walls.penalty(c.pos) * 6   -- hugging walls is how you get cornered
            if total < bestScore then best, bestScore = c.pos, total end
        end
    end
    return best
end

-- Nothing roomy and safe: back straight away from the attack (else the closest npc), taking the reachable spot that
-- is furthest outside every zone, and never walking closer to an npc.
function Nav.flee()
    local from = State.hrp.Position
    local startSurface = Npcs.surfaceDistance(from)
    local speed = math.max(State.hum.WalkSpeed, 8)
    local deadline = Hazards.deadline(from)

    local away, nearestZone = nil, math.huge
    for _, zone in pairs(Hazards.active) do
        local d = flat(zone.pos - from).Magnitude
        if d < nearestZone then
            nearestZone = d
            away = flat(from - zone.pos)
        end
    end
    if not away or away.Magnitude < 0.5 then
        local nearest = Npcs.nearest(from)
        away = nearest and flat(from - nearest.pos) or Vector3.zero
    end
    if away.Magnitude < 0.01 then away = -flat(State.hrp.CFrame.LookVector) end
    away = away.Unit

    local best, bestScore = nil, -math.huge
    for _, radius in ipairs({ 4, 8, 13, 19, 26 }) do
        for angle = 0, 340, 20 do
            local r = math.rad(angle)
            local dir = Vector3.new(math.cos(r), 0, math.sin(r))
            local cand = from + dir * radius
            if not Hazards.destinationDanger(cand) and Npcs.surfaceDistance(cand) >= startSurface - 1 and Walls.moveClear(from, cand) then
                local score = math.min(Hazards.clearance(cand), 20) * 2 + dir:Dot(away) * 10 - radius * 0.3
                score = score - Hazards.routeDanger(from, cand, speed) * 4
                local late = Hazards.exitTime(from, cand, speed) - (deadline - Config.PRECAST_SAFETY)
                if late > 0 then score = score - (5 + late * 25) end
                if score > bestScore then best, bestScore = cand, score end
            end
        end
    end
    if best then return best end

    -- boxed in: just rotate away from the danger until a wall-safe direction is found
    for _, deg in ipairs({ 0, 30, -30, 60, -60, 90, -90, 120, -120 }) do
        local r = math.rad(deg)
        local dir = Vector3.new(away.X * math.cos(r) - away.Z * math.sin(r), 0, away.X * math.sin(r) + away.Z * math.cos(r))
        local p = from + dir * 10
        if Walls.moveClear(from, p) then return p end
    end
    return nil
end

-- no npcs around: just get out of the attack (wall-aware)
function Nav.dodgeAlone()
    local from = State.hrp.Position
    for _, radius in ipairs(Config.SEARCH_RADII) do
        for angle = 0, 359, Config.SEARCH_ANGLE_STEP do
            local r = math.rad(angle)
            local cand = from + Vector3.new(math.cos(r) * radius, 0, math.sin(r) * radius)
            if not Hazards.destinationDanger(cand) and Walls.moveClear(from, cand) then return cand end
        end
    end
    return nil
end

-- =====================
-- SKILLS: ability detection and casting
-- A skill is a Tool with a numeric `cooldown` (-0.1 = ready, otherwise counting down) and a `cooldownLength`. They are
-- scanned from the backpack at runtime, so the bot works with any loadout. The four BUFF_SKILLS names are buffs
-- (Inner Rage ...); every other tool with a cooldown is an attack skill, and the one with the longest cooldown is the
-- one used.
-- =====================
Skills.buff = nil             -- name of the buff skill
Skills.attack = nil           -- name of the attack skill
Skills.reach = Config.ATTACK_RANGE   -- how far the attack really reaches (to an npc's centre); calibrated while fighting
Skills.busy = false
Skills.castUntil = 0          -- attacks that appear before this, close to us, are our own
Skills.buffUntil = 0
Skills.attackNotBefore = 0
Skills.lastBuff = -100
Skills.lastAttack = -100
Skills.castBarrier = nil      -- the barrier the last attack was fired against, if any
Skills.retryAfter = {}        -- [tool name] = time before which we won't retry a skill that did nothing
Skills.method = {}            -- [tool name] = "event" | "activate" (what worked last time)
Skills.cooldowns = {}         -- [tool name] = { prev, peak, startT, learned }
Skills.info = { buff = nil, attack = nil, plan = "" }
Skills.pendingHits = {}       -- { checkAt, targets, barrier } waiting for a health check
Skills.lastCooldown = nil     -- the attack's cooldown last frame (to see the moment it was cast)
Skills.escape = { t = 0, slack = math.huge, dist = 0 }

function Skills.isBuff(toolName)
    local n = normalize(toolName)
    for _, buff in ipairs(Config.BUFF_SKILLS) do
        if n == buff then return true end
    end
    return false
end

-- (re)scans the backpack and the equipped tools
function Skills.detect()
    local bestBuff, bestBuffLen = nil, -1
    local bestAttack, bestAttackLen = nil, -1

    local function check(t)
        if not t:IsA("Tool") or readNumber(t, "cooldown") == nil then return end
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
    if bestBuff and bestBuff ~= Skills.buff then
        Skills.buff = bestBuff
        Log.add("Buff skill: " .. bestBuff)
        changed = true
    end
    if bestAttack and bestAttack ~= Skills.attack then
        Skills.attack = bestAttack
        Log.add("Attack skill: " .. bestAttack)
        changed = true
    end
    if changed then UI.skillNames() end
    return changed
end

-- { tool, ready, remaining, length, extra } for a skill, or nil if it isn't carried
function Skills.get(name, lastUse)
    local tool = findTool(name)
    if not tool then return nil end

    local now = clock()
    local cd = readNumber(tool, "cooldown")
    local length = readNumber(tool, "cooldownLength") or Config.FALLBACK_COOLDOWN

    -- Learn the REAL full cooldown: the game's `cooldown` can start higher than `cooldownLength` (Inner Rage: a 3s
    -- buff + 6s cooldown = 9), so remember the highest value seen right after each use.
    local st = Skills.cooldowns[name]
    if not st then
        st = { prev = -0.1, peak = 0, startT = -100, learned = nil }
        Skills.cooldowns[name] = st
    end
    if cd ~= nil then
        if (st.prev <= Config.READY_MAX and cd > Config.READY_MAX) or (st.peak == 0 and cd > Config.READY_MAX) then
            st.peak, st.startT = cd, now
        elseif cd > st.peak and now - st.startT < 0.6 then
            st.peak = cd
        end
        if st.peak > 0 and now - st.startT >= 0.6 then st.learned = st.peak end
        st.prev = cd
    end
    local extra = math.max(0, (st.learned or length) - length)   -- time on top of cooldownLength (Inner Rage: the buff itself)

    local ready, remaining
    if cd == nil then   -- no live value: estimate from our last use
        remaining = math.max(0, length - (now - lastUse))
        ready = remaining <= 0
    else
        remaining = math.max(cd, 0)
        ready = cd <= Config.READY_MAX
    end
    -- the cooldown value can lag a moment behind an activation
    if now - lastUse < Config.MIN_GAP or now < (Skills.retryAfter[name] or 0) then ready = false end

    return { tool = tool, ready = ready, remaining = remaining, length = length, extra = extra }
end

-- "event" = tool.abilityEvent:FireServer() (how Inner Rage works), "activate" = equip the tool and Activate() it
function Skills.fire(tool, method)
    if method == "event" then
        local ev = tool:FindFirstChild("abilityEvent")
        if not (ev and ev:IsA("RemoteEvent")) then
            ev = nil
            for _, c in ipairs(tool:GetChildren()) do
                if c:IsA("RemoteEvent") then ev = c break end
            end
        end
        if not ev then return false end
        ev:FireServer()
        return true
    end

    if tool.Parent ~= player.Character then
        State.hum:EquipTool(tool)
        task.wait(Config.EQUIP_DELAY)
    end
    tool:Activate()
    return true
end

-- Uses a skill: remote event first, then equip+Activate, checking the cooldown really started and remembering what
-- worked. With `aim` it first gives the rotation a moment to reach the server and stays busy through the cast
-- (the facing itself is Nav.drive's job).
function Skills.use(tool, label, aim)
    if Skills.busy then return false end
    Skills.busy = true
    Skills.castUntil = clock() + Config.OWN_WINDOW

    task.spawn(function()
        local ok, err = pcall(function()
            local aiming = aim and State.aim
            if aiming then task.wait(Config.AIM_SETTLE) end

            local order = { "event", "activate" }
            if Skills.method[tool.Name] == "activate" then order = { "activate", "event" } end

            local fired = false
            for _, method in ipairs(order) do
                local okCall, sent = pcall(Skills.fire, tool, method)
                if okCall and sent then
                    task.wait(Config.CAST_CONFIRM)
                    local cd = readNumber(tool, "cooldown")
                    if cd == nil or cd > Config.READY_MAX then   -- the cooldown started (or can't tell)
                        fired = true
                        Skills.method[tool.Name] = method
                        Log.add(label .. " used (" .. method .. ")")
                        break
                    end
                end
            end

            if not fired then
                Skills.retryAfter[tool.Name] = clock() + Config.RETRY_DELAY
                Log.add(label .. ": nothing happened (cooldown never started)")
            elseif aiming then
                task.wait(math.max(0, Config.AIM_HOLD - Config.CAST_CONFIRM))
            end
        end)
        if not ok then Log.add("ability error: " .. tostring(err)) end
        Skills.busy = false
    end)
    return true
end

-- ---- the buff as a dodging tool ----

-- time to spare when escaping the attack we're standing in (negative = we can't make it), and the distance to the exit
function Skills.escapeSlack(speed)
    local from = State.hrp.Position
    local deadline = Hazards.deadline(from)
    if deadline == math.huge then return math.huge, 0 end

    local exitDist = math.huge
    for step = 2, 30, 2 do
        for angle = 0, 330, 30 do
            local r = math.rad(angle)
            local p = from + Vector3.new(math.cos(r) * step, 0, math.sin(r) * step)
            if not Hazards.insideAny(p) and Walls.moveClear(from, p) then
                exitDist = step
                break
            end
        end
        if exitDist < math.huge then break end
    end
    if exitDist == math.huge then return -math.huge, 0 end
    return deadline - Config.PRECAST_SAFETY - (exitDist / speed + Config.REACTION), exitDist
end

-- Should the buff be spent on its SPEED? A reason, or nil:
--  A) we're inside an attack and can't get out in time at normal speed
--  B) several attacks are closing in and we can't attack anyway
function Skills.speedReason(c, attack)
    local speed = math.max(State.hum.WalkSpeed, 8)

    if c.threatened then
        local e = Skills.escape
        if c.now - e.t > 0.1 then
            e.t = c.now
            e.slack, e.dist = Skills.escapeSlack(speed)
        end
        if e.slack < Config.RAGE_ESCAPE_SLACK and e.dist > 0 then
            return string.format("buff to escape (%.1fs to spare)", math.max(e.slack, -9.9))
        end
    end

    local canAttack = attack ~= nil and attack.ready and c.centreDist <= c.range
    if not canAttack then
        local n = Hazards.nearby(State.hrp.Position, Config.RAGE_CROWD_RADIUS)
        if n >= Config.RAGE_CROWD then return string.format("buff for speed: %d attacks closing in", n) end
    end
    return nil
end

-- ---- using the skills: once per frame, after movement ----
-- c = { now, npc (nearest by centre), centreDist, range, byAggro, threatened, shielded, barrier }
function Skills.update(c)
    local now = c.now
    local buff = Skills.buff and Skills.get(Skills.buff, Skills.lastBuff) or nil
    local attack = Skills.attack and Skills.get(Skills.attack, Skills.lastAttack) or nil
    Skills.info.buff, Skills.info.attack, Skills.info.plan = buff, attack, ""
    local info = Skills.info

    if Skills.busy or not c.npc then return end
    if c.shielded then info.plan = "spawn shield: all-in attack" end

    -- a cooldown above cooldownLength means the buff is still running
    local buffActive = now < Skills.buffUntil or (buff ~= nil and buff.remaining > buff.length + 0.3)

    local function fireBuff(reason)
        if Skills.use(buff.tool, Skills.buff, false) then
            Skills.lastBuff = now
            Skills.buffUntil = now + ((buff.extra or 0) >= 0.5 and buff.extra or Config.RAGE_DURATION)
            info.plan = reason
            return true
        end
        return false
    end

    -- survival first: the buff's speed can be the difference between dodging and being hit
    if buff and buff.ready and not buffActive and not c.shielded then
        local why = Skills.speedReason(c, attack)
        if why and fireBuff(why) then return end
    end

    if not attack then
        if info.plan == "" then info.plan = "no attack skill in backpack" end
        return
    end
    if not attack.ready then
        if info.plan == "" then info.plan = string.format("attack cooldown %.1fs", attack.remaining) end
        return
    end

    -- the target must be inside the cast range: the attack's reach, kept inside the npc's aggro range
    if c.barrier and c.barrier.holdFire then
        info.plan = "attack isn't reaching from the barrier, holding"
        return
    end
    if c.centreDist > c.range then
        info.plan = string.format("attack ready, out of range (%.0f / %.0f%s)", c.centreDist, c.range, c.byAggro and ", inside its aggro range" or "")
        return
    end

    if buff and not buffActive and buff.ready then   -- buff first (damage), a moment for it to take effect, then the attack
        if fireBuff("buff first, then attack") then Skills.attackNotBefore = now + Config.RAGE_DELAY end
        return
    end
    if now < Skills.attackNotBefore then
        info.plan = "buff ramping up"
        return
    end

    if Skills.use(attack.tool, Skills.attack, true) then
        Skills.lastAttack = now
        Skills.castBarrier = c.barrier
        info.plan = "attack fired"
    end
end

-- ---- calibration: does the attack connect from here? ----
-- When the attack's cooldown starts (a cast), nearby npcs' health is noted; a moment later, a drop means it connected
-- from that distance (the range grows to it), no drop at near the edge of the range means it fell short (the range
-- shrinks a little, so the bot stands closer next time). Against a barrier, repeated misses stop the bot wasting casts.
function Skills.watch(now)
    for i = #Skills.pendingHits, 1, -1 do
        local p = Skills.pendingHits[i]
        if now >= p.checkAt then
            local hit = false
            for _, t in ipairs(p.targets) do
                local ok, health = pcall(function() return t.humanoid.Health end)
                if (not ok) or t.humanoid.Parent == nil or health <= t.health - 1 then
                    hit = true
                    if t.dist > Skills.reach then Skills.reach = math.ceil(t.dist) end
                end
            end

            if p.barrier then
                if hit then
                    p.barrier.misses = 0
                    p.barrier.holdFire = false
                else
                    p.barrier.misses = p.barrier.misses + 1
                    if p.barrier.misses >= 2 and not p.barrier.holdFire then
                        p.barrier.holdFire = true
                        Log.add("Attack isn't reaching from the barrier, holding fire")
                    end
                end
            elseif not hit and p.targets[1] and p.targets[1].dist >= Skills.reach * 0.85 then
                local shorter = math.max(Config.MIN_DISTANCE + Config.RANGE_MARGIN + 4, Skills.reach - Config.REACH_STEP)
                if shorter < Skills.reach then
                    Skills.reach = shorter
                    Log.add(string.format("Attacks not connecting - closing in (reach now %d)", Skills.reach))
                end
            end
            table.remove(Skills.pendingHits, i)
        end
    end

    local tool = Skills.attack and findTool(Skills.attack)
    local cd = tool and readNumber(tool, "cooldown")
    local prev = Skills.lastCooldown
    Skills.lastCooldown = cd
    if cd ~= nil and prev ~= nil and prev <= Config.READY_MAX and cd > Config.READY_MAX and State.hrp then
        local targets = {}
        for _, n in ipairs(Npcs.list) do
            if n.humanoid then
                local ok, health = pcall(function() return n.humanoid.Health end)
                if ok then
                    table.insert(targets, { humanoid = n.humanoid, health = health, dist = flat(State.hrp.Position - n.pos).Magnitude })
                end
            end
        end
        table.sort(targets, function(a, b) return a.dist < b.dist end)
        if #targets > 0 then
            table.insert(Skills.pendingHits, {
                checkAt = now + Config.HIT_WINDOW, targets = targets,
                barrier = (now - Skills.lastAttack < 1.5) and Skills.castBarrier or nil,
            })
        end
    end
end

-- =====================
-- ESP: everything the bot draws. One switch (State.esp) controls all of it. Everything lives in the folder
-- workspace._AutoCombat (excluded from the raycasts), and nothing is ever drawn for anything on the ignore list.
-- =====================
ESP.npcs = {}              -- [model] = { highlight, gui, label, disc }
ESP.pathParts = {}
ESP.lastText = 0
ESP.RED, ESP.ORANGE, ESP.GREEN, ESP.WHITE = Color3.fromRGB(255, 70, 70), Color3.fromRGB(255, 165, 0), Color3.fromRGB(80, 255, 140), Color3.new(1, 1, 1)

function ESP.folder()
    local folder = workspace:FindFirstChild("_AutoCombat")
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = "_AutoCombat"
        folder.Parent = workspace
    end
    return folder
end

function ESP.marker(name, shape, color)
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
    ESP.ring = ESP.marker("_StandRing", Enum.PartType.Cylinder, Color3.fromRGB(0, 200, 255))
    ESP.aggroRing = ESP.marker("_AggroRange", Enum.PartType.Cylinder, Color3.fromRGB(255, 80, 200))
    ESP.goal = ESP.marker("_Goal", Enum.PartType.Ball, Color3.fromRGB(255, 255, 0))
    ESP.goal.Size = Vector3.new(0.8, 0.8, 0.8)
    ESP.tracer = ESP.marker("_Tracer", Enum.PartType.Block, ESP.GREEN)
    ESP.tracer.Size = Vector3.new(0.08, 0.08, 1)
end

-- a billboard label; returns the gui and its text
function ESP.label(adornee, height, width)
    local gui = Instance.new("BillboardGui")
    gui.Name = "_Label"
    gui.Adornee = adornee
    gui.AlwaysOnTop = true
    gui.Size = UDim2.fromOffset(width or 130, 16)
    gui.StudsOffsetWorldSpace = Vector3.new(0, height, 0)
    gui.Enabled = State.esp and Config.ESP_LABELS
    gui.Parent = adornee

    local text = Instance.new("TextLabel")
    text.Size = UDim2.fromScale(1, 1)
    text.BackgroundTransparency = 1
    text.Font = Enum.Font.GothamBold
    text.TextSize = 11
    text.TextColor3 = ESP.WHITE
    text.TextStrokeTransparency = 0.3
    text.Text = ""
    text.Parent = gui
    return gui, text
end

-- ---- attack zones ----

function ESP.attach(zone)
    local obj, color, on = zone.obj, Hazards.COLORS[zone.kind], State.esp
    local v = { parts = {} }   -- everything to destroy with the zone

    if zone.isModel then
        -- adornments don't reliably follow a Model, so a plain anchored box stands in for it
        local box = Instance.new("Part")
        box.Name = "_ModelZone"
        box.Anchored = true
        box.CanCollide = false
        box.CanQuery = false
        box.CanTouch = false
        box.CastShadow = false
        box.Material = Enum.Material.Neon
        box.Color = color
        box.Transparency = on and 0.8 or 1
        box.CFrame = zone.cf
        box.Size = zone.size
        box.Parent = ESP.folder()
        v.box = box
        table.insert(v.parts, box)
        local gui, text = ESP.label(box, zone.size.Y / 2 + 2)
        v.label = text
        table.insert(v.parts, gui)

    elseif zone.kind == "orb" then
        local sphere = Instance.new("SphereHandleAdornment")
        sphere.Name = "_Zone"
        sphere.Adornee = obj
        sphere.Radius = zone.radius
        sphere.Color3 = color
        sphere.Transparency = 0.7
        sphere.AlwaysOnTop = true
        sphere.ZIndex = 1
        sphere.Visible = on
        sphere.Parent = obj
        v.main = sphere
        table.insert(v.parts, sphere)

        local path = Instance.new("Part")   -- the orb's predicted path
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
        path.Parent = obj
        v.path = path
        table.insert(v.parts, path)

        local gui, text = ESP.label(obj, zone.radius + 2)
        v.label = text
        table.insert(v.parts, gui)
        obj:GetPropertyChangedSignal("Size"):Connect(function()
            zone.radius = Hazards.orbRadius(obj)
            sphere.Radius = zone.radius
        end)

    else
        -- the padded box is the area the bot actually avoids
        local grow = Vector3.one * (Config.PADDING * 2)
        local box = Instance.new("BoxHandleAdornment")
        box.Name = "_Zone"
        box.Adornee = obj
        box.Size = obj.Size + grow
        box.Color3 = color
        box.Transparency = 0.7
        box.AlwaysOnTop = true
        box.ZIndex = 1
        box.Visible = on
        box.Parent = obj
        v.main = box
        table.insert(v.parts, box)

        local outline = Instance.new("SelectionBox")
        outline.Name = "_ZoneOutline"
        outline.Adornee = obj
        outline.Color3 = Color3.fromRGB(255, 220, 0)
        outline.LineThickness = 0.04
        outline.SurfaceTransparency = 1
        outline.Visible = on
        outline.Parent = obj
        table.insert(v.parts, outline)

        local gui, text = ESP.label(obj, obj.Size.Y / 2 + Config.PADDING + 2)
        v.label = text
        table.insert(v.parts, gui)
        obj:GetPropertyChangedSignal("Size"):Connect(function() box.Size = obj.Size + grow end)
    end
    zone.vis = v
end

function ESP.detach(zone)
    if not zone.vis then return end
    for _, p in ipairs(zone.vis.parts) do destroy(p) end
    zone.vis = nil
end

function ESP.updateZone(zone, now)
    local v = zone.vis
    if not v then return end

    if v.box then   -- a model's stand-in follows it
        v.box.CFrame, v.box.Size = zone.cf, zone.size
    end

    if zone.kind == "precast" then
        local left = Hazards.timeToFire(zone, now)
        local frac = math.clamp(1 - left / Config.PRECAST_DELAY, 0, 1)
        local c = Hazards.COLORS.precast:Lerp(Hazards.COLORS.hitbox, frac)
        if v.main then
            v.main.Color3 = c
            v.main.Transparency = 0.8 - 0.35 * frac
        end
        v.label.Text = left > 0 and string.format("PRECAST  %.1fs", left) or "FIRING"
        v.label.TextColor3 = c
    elseif zone.kind == "hitbox" then
        if zone.duration then
            local left = math.max(0, zone.duration - (now - zone.born))
            v.label.Text = left > 0 and string.format("HITBOX  %.1fs", left) or "HITBOX (ending)"
        else
            v.label.Text = "HITBOX"
        end
        v.label.TextColor3 = Hazards.COLORS.hitbox
    elseif zone.kind == "orb" then
        local speed = zone.flatVel.Magnitude
        if v.path then
            if State.esp and speed > 1 then
                local len = speed * Config.ORB_STAY
                local a = zone.pos
                local b = a + zone.flatVel.Unit * len
                v.path.Size = Vector3.new(0.5, 0.5, len)
                v.path.CFrame = CFrame.lookAt((a + b) / 2, b)
                v.path.Transparency = 0.35
            else
                v.path.Transparency = 1
            end
        end
        v.label.Text = string.format("ORB  %.0f st/s", speed)
    else
        v.label.Text = "ATTACK?"
        v.label.TextColor3 = Hazards.COLORS.unknown
    end
end

-- ---- npcs, path, rings ----

function ESP.createNpc(npc)
    local data = {}
    local hl = Instance.new("Highlight")
    hl.Name = "_NpcESP"
    hl.OutlineTransparency = 0
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Adornee = npc.model
    hl.Enabled = State.esp
    hl.Parent = npc.model
    data.highlight = hl
    data.gui, data.label = ESP.label(npc.root, 5, 170)

    local disc = ESP.marker("_KeepAway", Enum.PartType.Cylinder, ESP.RED)   -- the MIN_DISTANCE bubble
    disc.Material = Enum.Material.SmoothPlastic
    data.disc = disc
    ESP.npcs[npc.model] = data
    return data
end

function ESP.destroyNpc(data)
    destroy(data.highlight)
    destroy(data.gui)
    destroy(data.disc)
end

function ESP.clearPath()
    for _, p in ipairs(ESP.pathParts) do destroy(p) end
    ESP.pathParts = {}
end

function ESP.drawPath(waypoints)
    ESP.clearPath()
    if not State.esp then return end
    local folder = ESP.folder()
    for i = 1, #waypoints - 1 do
        local a, b = waypoints[i].Position, waypoints[i + 1].Position
        local len = (b - a).Magnitude
        if len > 0 then
            local beam = Instance.new("Part")
            beam.Anchored = true
            beam.CanCollide = false
            beam.CanQuery = false
            beam.CastShadow = false
            beam.Size = Vector3.new(0.12, 0.12, len)
            beam.CFrame = CFrame.lookAt((a + b) / 2, (a + b) / 2 + (b - a).Unit)
            beam.Material = Enum.Material.Neon
            beam.Color = Color3.fromRGB(0, 255, 150)
            beam.Transparency = 0.2
            beam.Parent = folder
            table.insert(ESP.pathParts, beam)
        end
    end
end

function ESP.setGoal(pos)
    if pos and State.esp then
        ESP.goal.Position = pos
        ESP.goal.Transparency = 0.2
    else
        ESP.goal.Transparency = 1
    end
end

local function flatDisc(part, pos, diameter, transparency)
    part.Size = Vector3.new(0.12, diameter, diameter)
    part.CFrame = CFrame.new(pos.X, pos.Y - 2.6, pos.Z) * CFrame.Angles(0, 0, math.pi / 2)
    part.Transparency = transparency
end

-- Called every frame by the bot: zones, npcs, the stand ring, the aggro ring and the tracer to the target.
-- `stats` = Bot.stats (target, group, standRadius)
function ESP.update(now, stats)
    for _, zone in pairs(Hazards.active) do ESP.updateZone(zone, now) end

    local alive = {}
    for _, n in ipairs(Npcs.list) do alive[n.model] = true end
    for model, data in pairs(ESP.npcs) do
        if not alive[model] or not model.Parent then
            ESP.destroyNpc(data)
            ESP.npcs[model] = nil
        end
    end

    local on = State.esp
    local text = now - ESP.lastText >= 0.1
    if text then ESP.lastText = now end

    for _, n in ipairs(Npcs.list) do
        local data = ESP.npcs[n.model] or ESP.createNpc(n)
        local isTarget = stats.target ~= nil and n.model == stats.target.model
        local surface = flat(State.hrp.Position - n.pos).Magnitude - n.radius
        local tooClose = surface < Config.MIN_DISTANCE

        data.highlight.Enabled = on
        data.highlight.FillColor = isTarget and ESP.RED or ESP.ORANGE
        data.highlight.OutlineColor = isTarget and ESP.RED or Color3.fromRGB(200, 100, 0)
        data.highlight.FillTransparency = isTarget and 0.4 or 0.7
        data.gui.Enabled = on and Config.ESP_LABELS
        if text then
            data.label.Text = string.format("%s%s  %.0f%s", isTarget and "> " or "", n.model.Name, surface,
                n.aggro and string.format("  (aggro %.0f)", n.aggro) or "")
            data.label.TextColor3 = tooClose and ESP.RED or (isTarget and ESP.GREEN or ESP.WHITE)
        end
        if on then
            flatDisc(data.disc, n.pos, (Config.MIN_DISTANCE + n.radius) * 2, tooClose and 0.75 or 0.93)
        else
            data.disc.Transparency = 1
        end
    end

    -- the ring we try to stand on, and the target's aggro range
    if on and stats.group and stats.standRadius then
        flatDisc(ESP.ring, stats.group.centroid, stats.standRadius * 2, 0.88)
    else
        ESP.ring.Transparency = 1
    end
    if on and stats.target and stats.target.aggro then
        flatDisc(ESP.aggroRing, stats.target.pos, stats.target.aggro * 2, 0.93)
    else
        ESP.aggroRing.Transparency = 1
    end

    if on and stats.target then
        local a, b = State.hrp.Position, stats.target.pos
        local len = (b - a).Magnitude
        if len > 1 then
            ESP.tracer.Size = Vector3.new(0.08, 0.08, len)
            ESP.tracer.CFrame = CFrame.lookAt((a + b) / 2, b)
            ESP.tracer.Transparency = 0.4
        end
    else
        ESP.tracer.Transparency = 1
    end
end

-- the master switch (the UI button)
function ESP.setAll(on)
    State.esp = on
    for _, zone in pairs(Hazards.active) do
        local v = zone.vis
        if v then
            if v.box then v.box.Transparency = on and 0.8 or 1 end
            for _, p in ipairs(v.parts) do
                if p:IsA("BillboardGui") then
                    p.Enabled = on and Config.ESP_LABELS
                elseif p:IsA("HandleAdornment") or p:IsA("SelectionBox") then
                    p.Visible = on
                end
            end
        end
    end
    for _, data in pairs(ESP.npcs) do
        data.highlight.Enabled = on
        data.gui.Enabled = on and Config.ESP_LABELS
        if not on then data.disc.Transparency = 1 end
    end
    if not on then
        ESP.clearPath()
        ESP.ring.Transparency, ESP.aggroRing.Transparency = 1, 1
        ESP.goal.Transparency, ESP.tracer.Transparency = 1, 1
    end
    Log.add(on and "ESP on" or "ESP off")
end

function ESP.destroyAll()
    for _, data in pairs(ESP.npcs) do ESP.destroyNpc(data) end
    ESP.npcs = {}
    for _, zone in pairs(Hazards.active) do ESP.detach(zone) end
    ESP.clearPath()
    destroy(workspace:FindFirstChild("_AutoCombat"))
end

-- =====================
-- UI: the control window (drag it by the title, "-" collapses it)
-- =====================
UI.refs = {}
UI.gui = nil
UI.orders = setmetatable({}, { __mode = "k" })

UI.C = {
    bg = Color3.fromRGB(14, 16, 24), card = Color3.fromRGB(24, 27, 38), track = Color3.fromRGB(38, 43, 58),
    line = Color3.fromRGB(52, 58, 80), text = Color3.fromRGB(232, 235, 246), dim = Color3.fromRGB(128, 136, 160),
    green = Color3.fromRGB(88, 222, 138), red = Color3.fromRGB(255, 92, 92), orange = Color3.fromRGB(255, 172, 72),
    blue = Color3.fromRGB(94, 176, 255), purple = Color3.fromRGB(190, 124, 255), yellow = Color3.fromRGB(255, 212, 96),
    grey = Color3.fromRGB(150, 156, 176), button = Color3.fromRGB(30, 33, 46),
}
UI.MODE_COLORS = {
    ["DODGE"] = UI.C.red, ["AVOID"] = UI.C.orange, ["FLEE"] = UI.C.purple, ["REPOSITION"] = UI.C.blue,
    ["FIGHT"] = UI.C.green, ["APPROACH"] = UI.C.green, ["SIEGE"] = UI.C.yellow, ["ALL-IN"] = Color3.fromRGB(255, 64, 64),
    ["IDLE"] = UI.C.grey, ["OFF"] = UI.C.grey, ["DEAD"] = UI.C.grey,
}

local function hex(c)
    return string.format("#%02x%02x%02x", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end
local function esc(s) return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")) end
local function col(c, text) return string.format('<font color="%s">%s</font>', hex(c), text) end

-- ---- building blocks ----

local function nextOrder(parent)
    UI.orders[parent] = (UI.orders[parent] or 0) + 1
    return UI.orders[parent]
end

local function corner(inst, radius)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, radius)
    c.Parent = inst
end

local function outline(inst, color, thickness, transparency)
    local s = Instance.new("UIStroke")
    s.Color = color
    s.Thickness = thickness
    s.Transparency = transparency
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    s.Parent = inst
    return s
end

local function layout(inst, gap, horizontal)
    local l = Instance.new("UIListLayout")
    l.SortOrder = Enum.SortOrder.LayoutOrder
    l.Padding = UDim.new(0, gap)
    if horizontal then l.FillDirection = Enum.FillDirection.Horizontal end
    l.Parent = inst
end

local function pad(inst, l, t, r, b)
    local p = Instance.new("UIPadding")
    p.PaddingLeft, p.PaddingTop, p.PaddingRight, p.PaddingBottom = UDim.new(0, l), UDim.new(0, t), UDim.new(0, r), UDim.new(0, b)
    p.Parent = inst
end

local function label(parent, size, font, color, align)
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Font = font
    l.TextSize = size
    l.TextColor3 = color
    l.TextXAlignment = align or Enum.TextXAlignment.Left
    l.RichText = true
    l.Text = ""
    l.Parent = parent
    return l
end

local function card(parent, title)
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, 0, 0, 0)
    f.AutomaticSize = Enum.AutomaticSize.Y
    f.BackgroundColor3 = UI.C.card
    f.BorderSizePixel = 0
    f.LayoutOrder = nextOrder(parent)
    f.Parent = parent
    corner(f, 9)
    outline(f, UI.C.line, 1, 0.45)
    pad(f, 10, 8, 10, 8)
    layout(f, 5)
    if title then
        local t = label(f, 11, Enum.Font.GothamBold, UI.C.dim)
        t.Size = UDim2.new(1, 0, 0, 13)
        t.LayoutOrder = nextOrder(f)
        t.Text = title
    end
    return f
end

-- "Key ........ value": returns the value label and the key label
local function row(parent, key)
    local r = Instance.new("Frame")
    r.Size = UDim2.new(1, 0, 0, 18)
    r.BackgroundTransparency = 1
    r.LayoutOrder = nextOrder(parent)
    r.Parent = parent
    local k = label(r, 13, Enum.Font.Gotham, UI.C.dim)
    k.Size = UDim2.new(0.3, 0, 1, 0)
    k.Text = key
    local v = label(r, 13, Enum.Font.GothamMedium, UI.C.text, Enum.TextXAlignment.Right)
    v.Size = UDim2.new(0.7, 0, 1, 0)
    v.Position = UDim2.fromScale(0.3, 0)
    v.TextTruncate = Enum.TextTruncate.AtEnd
    return v, k
end

local function bar(parent)
    local track = Instance.new("Frame")
    track.Size = UDim2.new(1, 0, 0, 6)
    track.BackgroundColor3 = UI.C.track
    track.BorderSizePixel = 0
    track.LayoutOrder = nextOrder(parent)
    track.Parent = parent
    corner(track, 3)
    local fill = Instance.new("Frame")
    fill.Size = UDim2.fromScale(0, 1)
    fill.BackgroundColor3 = UI.C.green
    fill.BorderSizePixel = 0
    fill.Parent = track
    corner(fill, 3)
    return { track = track, fill = fill, frac = 0 }
end

local function setBar(b, frac, color)
    frac = math.clamp(frac, 0, 1)
    if math.abs(frac - b.frac) > 0.004 then   -- no tween for an unchanged bar
        b.frac = frac
        TweenService:Create(b.fill, TweenInfo.new(0.12, Enum.EasingStyle.Quad), { Size = UDim2.fromScale(frac, 1) }):Play()
    end
    b.fill.BackgroundColor3 = color
end

local function chip(parent, color, order)
    local c = Instance.new("TextLabel")
    c.Size = UDim2.new(1 / 4, -4, 1, 0)
    c.BackgroundColor3 = color
    c.BackgroundTransparency = 0.85
    c.BorderSizePixel = 0
    c.Font = Enum.Font.GothamBold
    c.TextSize = 12
    c.TextColor3 = color
    c.Text = ""
    c.LayoutOrder = order
    c.Parent = parent
    corner(c, 6)
    return c
end

local function toggle(parent, size, onClick)
    local b = Instance.new("TextButton")
    b.Size = size
    b.AutoButtonColor = false
    b.BorderSizePixel = 0
    b.Font = Enum.Font.GothamBold
    b.TextSize = 13
    b.LayoutOrder = nextOrder(parent)
    b.Parent = parent
    corner(b, 8)
    local stroke = outline(b, UI.C.line, 1, 0.2)
    b.MouseButton1Click:Connect(onClick)
    return function(text, on)   -- restyle
        b.Text = text .. (on and "  ON" or "  OFF")
        b.BackgroundColor3 = on and Color3.fromRGB(26, 74, 50) or UI.C.button
        b.TextColor3 = on and UI.C.green or UI.C.dim
        stroke.Color = on and UI.C.green or UI.C.line
        stroke.Transparency = on and 0.35 or 0.2
    end
end

-- ---- the window ----

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
    root.Size = UDim2.fromOffset(320, 0)
    root.AutomaticSize = Enum.AutomaticSize.Y
    root.Position = UDim2.fromOffset(20, 110)
    root.BackgroundColor3 = Color3.new(1, 1, 1)
    root.BackgroundTransparency = 0.04
    root.BorderSizePixel = 0
    root.Parent = gui
    corner(root, 13)
    outline(root, UI.C.line, 1.5, 0.15)
    pad(root, 10, 10, 10, 10)
    layout(root, 8)
    local grad = Instance.new("UIGradient")
    grad.Color = ColorSequence.new(Color3.fromRGB(26, 30, 46), UI.C.bg)
    grad.Rotation = 90
    grad.Parent = root
    local scale = Instance.new("UIScale")
    scale.Scale = Config.UI_SCALE
    scale.Parent = root

    -- header: the drag handle
    local header = Instance.new("Frame")
    header.Size = UDim2.new(1, 0, 0, 28)
    header.BackgroundTransparency = 1
    header.Active = true
    header.LayoutOrder = nextOrder(root)
    header.Parent = root
    local dot = Instance.new("Frame")
    dot.Size = UDim2.fromOffset(10, 10)
    dot.Position = UDim2.new(0, 2, 0.5, -5)
    dot.BackgroundColor3 = UI.C.green
    dot.BorderSizePixel = 0
    dot.Parent = header
    corner(dot, 5)
    UI.refs.dot = dot
    local title = label(header, 16, Enum.Font.GothamBold, UI.C.text)
    title.Position = UDim2.fromOffset(20, 0)
    title.Size = UDim2.new(1, -60, 1, 0)
    title.Text = "Auto Combat"
    local minimize = Instance.new("TextButton")
    minimize.Size = UDim2.fromOffset(26, 22)
    minimize.Position = UDim2.new(1, -26, 0.5, -11)
    minimize.BackgroundColor3 = UI.C.card
    minimize.BorderSizePixel = 0
    minimize.Font = Enum.Font.GothamBold
    minimize.TextSize = 16
    minimize.TextColor3 = UI.C.dim
    minimize.Text = "-"
    minimize.Parent = header
    corner(minimize, 6)

    local dragging, dragStart, startPos = false, nil, nil
    header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPos = true, input.Position, root.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    track(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            root.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end))

    local body = Instance.new("Frame")
    body.Size = UDim2.new(1, 0, 0, 0)
    body.AutomaticSize = Enum.AutomaticSize.Y
    body.BackgroundTransparency = 1
    body.LayoutOrder = nextOrder(root)
    body.Parent = root
    layout(body, 8)
    minimize.MouseButton1Click:Connect(function()
        body.Visible = not body.Visible
        minimize.Text = body.Visible and "-" or "+"
    end)

    -- state badge + what the bot is doing about its skills
    local stateCard = card(body)
    local badge = Instance.new("TextLabel")
    badge.Size = UDim2.new(1, 0, 0, 36)
    badge.BackgroundColor3 = UI.C.card
    badge.BorderSizePixel = 0
    badge.Font = Enum.Font.GothamBold
    badge.TextSize = 19
    badge.TextColor3 = UI.C.text
    badge.Text = "IDLE"
    badge.LayoutOrder = nextOrder(stateCard)
    badge.Parent = stateCard
    corner(badge, 8)
    UI.refs.badge = badge
    UI.refs.badgeStroke = outline(badge, UI.C.grey, 1.5, 0.3)
    UI.refs.plan = label(stateCard, 12, Enum.Font.Gotham, UI.C.dim, Enum.TextXAlignment.Center)
    UI.refs.plan.Size = UDim2.new(1, 0, 0, 16)
    UI.refs.plan.TextTruncate = Enum.TextTruncate.AtEnd
    UI.refs.plan.LayoutOrder = nextOrder(stateCard)

    -- switches
    local switches = Instance.new("Frame")
    switches.Size = UDim2.new(1, 0, 0, 30)
    switches.BackgroundTransparency = 1
    switches.LayoutOrder = nextOrder(body)
    switches.Parent = body
    layout(switches, 6, true)
    local third = UDim2.new(1 / 3, -4, 1, 0)
    local styleBot, styleEsp, styleAim
    styleBot = toggle(switches, third, function()
        State.enabled = not State.enabled
        Nav.setControls(not State.enabled)   -- bot on -> it takes the controls; off -> they come back
        Log.add(State.enabled and "Bot enabled" or "Bot disabled")
        UI.restyle()
    end)
    styleEsp = toggle(switches, third, function()
        ESP.setAll(not State.esp)
        UI.restyle()
    end)
    styleAim = toggle(switches, third, function()
        State.aim = not State.aim
        Log.add(State.aim and "Auto-aim on" or "Auto-aim off")
        UI.restyle()
    end)
    UI.restyle = function()
        styleBot("Bot", State.enabled)
        styleEsp("ESP", State.esp)
        styleAim("Aim", State.aim)
    end
    UI.restyle()

    -- the target, and where the cast range comes from
    local target = card(body, "TARGET")
    UI.refs.target = row(target, "Target")
    UI.refs.reach = row(target, "Aggro")
    UI.refs.group = row(target, "Group")
    UI.refs.barrier = row(target, "Barrier")

    -- attacks
    local threats = card(body, "THREATS")
    local chips = Instance.new("Frame")
    chips.Size = UDim2.new(1, 0, 0, 22)
    chips.BackgroundTransparency = 1
    chips.LayoutOrder = nextOrder(threats)
    chips.Parent = threats
    layout(chips, 6, true)
    UI.refs.chipPre = chip(chips, Hazards.COLORS.precast, 1)
    UI.refs.chipHit = chip(chips, Hazards.COLORS.hitbox, 2)
    UI.refs.chipOrb = chip(chips, Hazards.COLORS.orb, 3)
    UI.refs.chipUnk = chip(chips, Hazards.COLORS.unknown, 4)
    UI.refs.threat = row(threats, "Status")
    UI.refs.threatBar = bar(threats)

    -- skills
    local skills = card(body, "SKILLS")
    UI.refs.buff, UI.refs.buffKey = row(skills, Skills.buff or "Buff skill")
    UI.refs.buffBar = bar(skills)
    UI.refs.attack, UI.refs.attackKey = row(skills, Skills.attack or "Attack skill")
    UI.refs.attackBar = bar(skills)
    UI.refs.reachRow = row(skills, "Reach")

    local logCard = card(body, "LOG")
    UI.refs.log = label(logCard, 12, Enum.Font.Code, UI.C.dim)
    UI.refs.log.Size = UDim2.new(1, 0, 0, 92)
    UI.refs.log.TextYAlignment = Enum.TextYAlignment.Top
    UI.refs.log.TextWrapped = true
    UI.refs.log.LayoutOrder = nextOrder(logCard)
end

-- the skill names are only known once the backpack has been scanned, which can happen after the window was built
function UI.skillNames()
    if UI.refs.buffKey then UI.refs.buffKey.Text = Skills.buff or "Buff skill" end
    if UI.refs.attackKey then UI.refs.attackKey.Text = Skills.attack or "Attack skill" end
end

-- bar = charging up; full green = ready; yellow = buff running out
local function skillRow(value, b, s, activeLeft, activeTotal)
    if not s then
        value.Text = col(UI.C.dim, "not in backpack")
        setBar(b, 0, UI.C.dim)
    elseif activeLeft then
        value.Text = col(UI.C.yellow, string.format("<b>ACTIVE</b>  %.1fs", activeLeft))
        setBar(b, activeLeft / activeTotal, UI.C.yellow)
    elseif s.ready then
        value.Text = col(UI.C.green, "<b>READY</b>")
        setBar(b, 1, UI.C.green)
    else
        value.Text = col(UI.C.orange, string.format("%.1fs", s.remaining)) .. col(UI.C.dim, string.format("  / %.0fs", s.length))
        setBar(b, 1 - s.remaining / math.max(s.length, 0.1), UI.C.orange)
    end
end

function UI.update()
    local r = UI.refs
    if not r.log then return end   -- the window never finished building
    local st = Bot.stats
    local now = clock()

    local color = UI.MODE_COLORS[State.mode] or UI.C.text
    r.dot.BackgroundColor3 = (not State.enabled) and UI.C.grey or (State.mode == "DEAD" and UI.C.red or UI.C.green)
    r.badge.Text = State.mode
    r.badge.TextColor3 = color
    r.badge.BackgroundColor3 = color:Lerp(UI.C.bg, 0.82)
    r.badgeStroke.Color = color
    r.plan.Text = esc(Skills.info.plan ~= "" and Skills.info.plan or "no skill plan")

    if st.target then
        r.target.Text = string.format("%s  %s", esc(st.target.model.Name), col(UI.C.dim, string.format("%.0f studs", st.centreDist or 0)))
        local inside = (st.centreDist or math.huge) <= st.castRange
        if st.target.aggro then
            r.reach.Text = col(inside and UI.C.green or UI.C.orange, string.format("%.0f", st.target.aggro))
                .. col(UI.C.dim, string.format("  cast within %.0f  %s", st.castRange, inside and "(inside)" or "(outside)"))
        else
            r.reach.Text = col(UI.C.dim, string.format("no aggroRange  |  cast within %.0f", st.castRange))
        end
        r.group.Text = st.group and string.format("%d npc%s", st.group.count, st.group.count == 1 and "" or "s") or col(UI.C.dim, "--")
    else
        r.target.Text = col(UI.C.dim, "none")
        r.reach.Text = col(UI.C.dim, "--")
        r.group.Text = col(UI.C.dim, "--")
    end
    r.barrier.Text = st.barrier and col(UI.C.yellow, string.format("stuck at %.0f%s", st.barrier.centerDist, st.barrier.holdFire and ", not reaching" or "")) or col(UI.C.dim, "none")

    local counts = Hazards.counts(now)
    local function setChip(name, c, n)
        c.Text = string.format("%s  %d", name, n)
        c.BackgroundTransparency = n > 0 and 0.7 or 0.9
        c.TextTransparency = n > 0 and 0 or 0.55
    end
    setChip("PRECAST", r.chipPre, counts.precast)
    setChip("HITBOX", r.chipHit, counts.hitbox)
    setChip("ORB", r.chipOrb, counts.orb)
    setChip("?", r.chipUnk, counts.unknown)

    local deadline = Hazards.deadline(State.hrp.Position)
    if deadline < math.huge then
        if deadline > 0 then
            r.threat.Text = col(UI.C.red, string.format("<b>INSIDE</b>  fires in %.1fs", deadline))
            setBar(r.threatBar, deadline / Config.PRECAST_DELAY, UI.C.red)
        else
            r.threat.Text = col(UI.C.red, "<b>INSIDE ACTIVE ZONE</b>")
            setBar(r.threatBar, 1, UI.C.red)
        end
    elseif counts.soonest < math.huge and counts.soonest > 0 then
        r.threat.Text = col(UI.C.orange, string.format("precast fires in %.1fs", counts.soonest))
        setBar(r.threatBar, counts.soonest / Config.PRECAST_DELAY, UI.C.orange)
    else
        r.threat.Text = col(UI.C.green, "clear")
        setBar(r.threatBar, 0, UI.C.green)
    end

    -- the buff's cooldown starts at (buff time + cooldownLength): the part above cooldownLength is the BUFF
    local buff = Skills.info.buff
    local left = Skills.buffUntil - now
    if buff then left = math.max(left, buff.remaining - buff.length) end
    skillRow(r.buff, r.buffBar, buff, left > 0.05 and left or nil, (buff and buff.extra >= 0.5) and buff.extra or Config.RAGE_DURATION)
    skillRow(r.attack, r.attackBar, Skills.info.attack, nil, 1)
    r.reachRow.Text = string.format("%.0f studs", Skills.reach)

    local lines = {}
    for i, line in ipairs(Log.lines) do
        lines[i] = (i == 1) and col(UI.C.text, esc(line)) or col(UI.C.dim, esc(line))
    end
    r.log.Text = table.concat(lines, "\n")
end

function UI.destroy()
    destroy(UI.gui)
    UI.gui = nil
    UI.refs = {}
end

-- =====================
-- BOT: the per-frame decision loop
--   threatened (an attack is about to fire where we stand, or an npc is on top of us)  -> DODGE / AVOID / REPOSITION
--   outside the cast range of the nearest npc group                                    -> APPROACH (pathfind to the stand ring)
--   inside it                                                                          -> FIGHT (hold still; adjust only when needed)
-- Skills are used every frame, whatever the movement is doing, as soon as an npc is inside its cast range.
-- =====================
Bot.stats = {}               -- what the UI and ESP show: target, centreDist, castRange, group, barrier, standRadius
Bot.barriers = setmetatable({}, { __mode = "k" })   -- [npc model] = { centerDist, pos, expires, holdFire, misses }
Bot.approach = { model = nil, best = math.huge, progressT = 0, anchor = Vector3.zero, anchorT = 0 }
Bot.lastSearch = 0
Bot.lastPath = 0
Bot.lastUI = 0
Bot.lastError = 0
Bot.lastNoPath = 0
Bot.stopped = false

-- one bad frame (a part vanishing mid-death ...) must never kill the loop or flood the output
function Bot.reportError(label, err)
    Nav.computing = false
    local now = clock()
    if now - Bot.lastError > 2 then
        Bot.lastError = now
        Log.add("error: " .. tostring(err))
        warn("[AutoCombat] " .. label .. ": " .. tostring(err))
    end
end

function Bot.refreshUI(now)
    if now - Bot.lastUI >= 0.1 then
        Bot.lastUI = now
        UI.update()
    end
end

-- ---- death / respawn: everything tied to the old character is dropped ----

function Bot.reset(reason)
    Nav.stopPath()
    ESP.clearPath()
    ESP.setGoal(nil)
    Nav.stop()
    Nav.spot, Nav.pathGoal, Nav.lastPos, Nav.lastMove, Nav.computing = nil, nil, nil, clock(), false
    Skills.buffUntil, Skills.attackNotBefore, Skills.busy = 0, 0, false   -- buffs are lost on death
    Log.add(reason)
end

function Bot.notAlive()
    if State.wasAlive then
        State.wasAlive = false
        Bot.reset("Dead")
        State.setMode("DEAD")
    end
    local now = clock()
    if State.hrp and now - Bot.lastUI >= 0.1 then
        Bot.lastUI = now
        pcall(UI.update)
    end
end

function Bot.onCharacter(char, initial)
    task.spawn(function()
        local hum = char:WaitForChild("Humanoid", 10)
        local root = char:WaitForChild("HumanoidRootPart", 10)
        if not hum or not root or Bot.stopped then return end
        State.char, State.hum, State.hrp = char, hum, root
        Bot.reset("Character ready")

        -- a new character can get the game's own controls back even though we disabled them for the last one
        if State.enabled then Nav.setControls(false) end

        -- re-detect on every respawn (the loadout can change between runs), and when a tool lands in the new backpack
        Skills.detect()
        local bp = player:WaitForChild("Backpack", 5)
        if bp then
            bp.ChildAdded:Connect(function(child)
                if child:IsA("Tool") then Skills.detect() end
            end)
        end

        -- a fresh spawn is immortal for a few seconds: spend them attacking
        if not initial then
            State.shieldUntil = clock() + Config.SPAWN_SHIELD
            Log.add("Spawn shield: all-in attack")
        end

        hum.Died:Connect(function()
            if State.wasAlive then
                State.wasAlive = false
                Bot.reset("Died")
                State.setMode("DEAD")
            end
        end)
    end)
end

-- false while there is no live character
function Bot.refreshChar()
    State.char = player.Character
    local char = State.char
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not root or not hum or hum.Health <= 0 then
        Bot.notAlive()
        return false
    end
    State.hrp, State.hum = root, hum
    if not State.wasAlive then
        State.wasAlive = true
        Bot.reset("Alive again")
    end
    return true
end

-- switched off: hand everything back once, then just keep the window fresh
function Bot.idle(now)
    if State.wasEnabled then
        State.wasEnabled = false
        State.hum.AutoRotate = true
        Nav.ownsRotation = false
        Nav.stopPath()
        Nav.stop()
        ESP.clearPath()
        ESP.setGoal(nil)
        Nav.setControls(true)
        State.setMode("OFF")
    end
    Bot.refreshUI(now)
end

-- ---- barriers ----

-- a barrier on this target expires after a while, or vanishes once we get well past it
function Bot.barrierOf(target, centre, now)
    local b = target and Bot.barriers[target.model]
    if b then
        if now > b.expires then
            Bot.barriers[target.model] = nil
            b = nil
            Log.add("Barrier expired, trying to get closer")
        elseif centre < b.centerDist - Config.BARRIER_LEEWAY then
            Bot.barriers[target.model] = nil
            b = nil
            Log.add("Barrier gone")
        end
    end
    return b
end

-- Standing still, or walking without getting any closer, for too long while approaching: if a wall really is in the
-- way, remember how close we got and fight from there instead of walking into it forever.
function Bot.watchBarrier(target, centre, now)
    local a = Bot.approach
    if a.model ~= target.model then
        a.model, a.best, a.progressT = target.model, centre, now
        a.anchor, a.anchorT = State.hrp.Position, now
        return
    end
    if Nav.computing or not Nav.goal then   -- nothing to walk toward yet: that's not being blocked
        a.anchorT = now
        return
    end

    if centre < a.best - Config.BARRIER_PROGRESS then
        a.best, a.progressT = centre, now
    end
    if flat(State.hrp.Position - a.anchor).Magnitude > 3 then
        a.anchor, a.anchorT = State.hrp.Position, now
    end

    if now - a.anchorT >= Config.BARRIER_STUCK or now - a.progressT >= Config.BARRIER_NO_PROGRESS then
        local dir = flat(target.pos - State.hrp.Position)
        local hit = dir.Magnitude > 1 and Walls.cast(State.hrp.Position, dir.Unit * math.min(dir.Magnitude, 300))
        if hit and hit.Distance <= Config.BARRIER_WALL_DIST then
            Bot.barriers[target.model] = {
                centerDist = centre, pos = State.hrp.Position, holdFire = false, misses = 0,
                expires = clock() + (Config.BARRIER_RETRY > 0 and Config.BARRIER_RETRY or math.huge),
            }
            Nav.stopPath()
            ESP.clearPath()
            a.model = nil
            Log.add(string.format("Barrier: can't get closer than %.0f studs (%s, %.0f ahead), attacking from here", centre, hit.Instance.Name, hit.Distance))
        else
            a.progressT, a.anchorT, a.best = now, now, centre   -- probably a slow or winding path: a fresh window
        end
    end
end

-- ---- the three things the bot can be doing ----

-- no npcs: only dodge
function Bot.aloneStep(threatened, now)
    Nav.aim = nil
    Nav.stopPath()
    ESP.clearPath()
    Bot.stats.target, Bot.stats.group = nil, nil
    if threatened then
        State.setMode("DODGE")
        local spot = Nav.dodgeAlone()
        if spot then
            Nav.spot = spot
            Nav.setGoal(spot)
            ESP.setGoal(spot)
        end
    else
        State.setMode("IDLE")
        ESP.setGoal(nil)
    end
end

-- an attack is about to fire where we stand / is in our way / an npc is on top of us: get out
function Bot.dodgeStep(f)
    Nav.stopPath()
    ESP.clearPath()
    Nav.pathGoal = nil

    local me = State.hrp.Position
    local goalBad = Nav.spot ~= nil and (Hazards.destinationDanger(Nav.spot) or not Walls.moveClear(me, Nav.spot))
    if goalBad then Nav.spot = nil end

    if not Nav.spot or f.now - Bot.lastSearch >= 0.06 then
        Bot.lastSearch = f.now
        local spot = Nav.findSpot(f.threatened, f.range)
        local mode = f.threatened and "DODGE" or (f.aheadBlocked and "AVOID" or "REPOSITION")
        if not spot and (f.threatened or f.tooClose) then
            spot = Nav.flee()   -- no roomy safe spot: back straight out of it
            mode = "FLEE"
        elseif not spot and f.aheadBlocked then
            Nav.stop()   -- nowhere safe to go around it: stand still, don't walk into it
            Nav.spot = nil
        end
        State.setMode(mode)
        if spot then
            Nav.spot = spot
            Nav.setGoal(spot)
            ESP.setGoal(spot)
        else
            ESP.setGoal(nil)
        end
    end
end

-- outside the cast range: pathfind to the stand ring
function Bot.approachStep(f)
    State.setMode("APPROACH")
    Nav.spot = nil
    ESP.setGoal(nil)
    if f.target then Bot.watchBarrier(f.target, f.centre, f.now) end

    if f.now - Bot.lastPath >= Config.REPATH_RATE and not Nav.computing and f.group then
        Bot.lastPath = f.now
        local points, ringR = Nav.ringPoints(f.group, f.barrier)
        Bot.stats.standRadius = ringR

        local needPath = not Nav.pathing
        if not Nav.pathGoal or Npcs.surfaceDistance(Nav.pathGoal) < Config.MIN_DISTANCE + 1 or Hazards.destinationDanger(Nav.pathGoal)
            or (not f.barrier and math.abs(flat(Nav.pathGoal - f.group.centroid).Magnitude - ringR) > 4) then
            needPath = true
        end

        if needPath then
            Nav.computing = true
            local goals = f.barrier and { f.barrier.pos } or points   -- a known barrier: go back to where we got stuck
            local started = false
            for i = 1, math.min(6, #goals) do
                if Nav.pathTo(goals[i]) then
                    started = true
                    break
                end
            end
            -- no navmesh path (a big boss room, odd geometry)? walk straight at the nearest legal point
            if not started and State.alive() and not Nav.interrupted() then
                local goal = goals[1]
                if not goal then
                    local out = flat(State.hrp.Position - f.group.centroid)
                    if out.Magnitude < 0.01 then out = Vector3.new(0, 0, 1) end
                    goal = f.group.centroid + out.Unit * ringR
                end
                Nav.setGoal(goal)
                if f.now - Bot.lastNoPath > 3 then
                    Bot.lastNoPath = f.now
                    Log.add("no path found, walking straight")
                end
            end
            Nav.computing = false
        end
    end

    if Nav.pathing and Nav.stuck() then   -- a nudge to get unstuck
        local dir = Nav.goal and flat(Nav.goal - State.hrp.Position)
        if not dir or dir.Magnitude < 0.01 then dir = flat(State.hrp.CFrame.LookVector) end
        Nav.setGoal(State.hrp.Position + dir.Unit * 5)
        Bot.lastPath = 0
    end
end

-- inside the cast range: stay put; move only when something is wrong with where we are
function Bot.fightStep(f)
    Nav.stopPath()
    ESP.clearPath()
    Nav.pathGoal = nil
    local me = State.hrp.Position
    State.setMode(f.shielded and "ALL-IN" or (f.atBarrier and "SIEGE" or "FIGHT"))

    local goalBad = Nav.spot ~= nil and (Hazards.destinationDanger(Nav.spot) or not Walls.moveClear(me, Nav.spot))
    if Nav.spot and not goalBad then   -- still walking to the last chosen spot
        if flat(me - Nav.spot).Magnitude < 2 then
            Nav.spot = nil
            Nav.stop()
        end
        return
    end
    Nav.spot = nil

    -- worth moving? drifting toward the edge of the range, or an npc closer than comfortable
    local needMove = goalBad or f.centre > f.range * 0.95 or f.surface < Config.MIN_DISTANCE + 2
    if needMove and f.now - Bot.lastSearch >= Config.STEER_RATE then
        Bot.lastSearch = f.now
        local spot = Nav.findSpot(false, f.range)
        if spot then
            Nav.spot = spot
            Nav.setGoal(spot)
            ESP.setGoal(spot)
            return
        end
    end
    if not needMove then
        Nav.stop()
        ESP.setGoal(nil)
    end
end

function Bot.step()
    if not Bot.refreshChar() then return end
    local now = clock()
    Walls.refresh(now)
    if not State.enabled then
        Bot.idle(now)
        return
    end
    State.wasEnabled = true

    Hazards.update(now)
    Hazards.scan(now)
    Npcs.refresh(0)
    Npcs.buildGroups()
    Skills.watch(now)

    local me = State.hrp.Position
    local stats = Bot.stats
    local nearest, surface = Npcs.nearest(me)
    local target = Npcs.pick(nearest, surface, me)

    -- spawn immortality: attacks can't hurt us, so ignore them and go all-in on attacking
    local shielded = now < State.shieldUntil
    local threatened = not shielded and Hazards.threatened(me)
    local tooClose = not shielded and nearest ~= nil and surface < Config.MIN_DISTANCE
    local aheadBlocked = not threatened and not shielded and Nav.aheadBlocked()

    if not nearest then
        Bot.aloneStep(threatened, now)
        stats.target, stats.group, stats.barrier = nil, nil, nil
        Skills.update({ now = now })
        ESP.update(now, stats)
        Bot.refreshUI(now)
        return
    end

    local group = Npcs.groups[target.group]
    local reachNpc, centre = Npcs.nearestCenter(me)   -- skills reach by distance to an npc's centre
    local targetCentre = flat(me - target.pos).Magnitude
    local barrier = Bot.barrierOf(target, targetCentre, now)
    local atBarrier = barrier ~= nil and targetCentre <= barrier.centerDist + Config.BARRIER_LEEWAY
    local castRange, byAggro = Npcs.castRange(reachNpc, barrier)
    local groupRange = Npcs.groupRange(group, barrier)

    stats.target, stats.group, stats.barrier = target, group, barrier
    stats.centreDist = targetCentre
    stats.castRange = (Npcs.castRange(target, barrier))
    stats.standRadius = group and Nav.ringRadius(group, barrier) or nil

    local f = {
        now = now, target = target, group = group, barrier = barrier, atBarrier = atBarrier,
        centre = centre, surface = surface, range = groupRange,
        threatened = threatened, tooClose = tooClose, aheadBlocked = aheadBlocked, shielded = shielded,
    }

    if threatened or tooClose or aheadBlocked then
        Bot.dodgeStep(f)
    elseif centre > groupRange then
        Bot.approachStep(f)
    else
        Bot.fightStep(f)
    end

    -- skills get their turn every frame (the attack aims itself when it fires)
    Nav.aim = group and ((group.count >= 2) and group.centroid or target.pos) or nil
    Skills.update({
        now = now, npc = reachNpc, centreDist = centre, range = castRange, byAggro = byAggro,
        threatened = threatened, shielded = shielded, barrier = barrier,
    })

    ESP.update(now, stats)
    Bot.refreshUI(now)
end

-- ---- startup / shutdown ----

function Bot.start()
    print("[AutoCombat] starting...")
    State.char = player.Character or player.CharacterAdded:Wait()
    State.hrp = State.char:WaitForChild("HumanoidRootPart")
    State.hum = State.char:WaitForChild("Humanoid")

    Skills.detect()   -- before the window exists, so it already shows the skill names
    local okUI, errUI = pcall(UI.build)
    if not okUI then
        warn("[AutoCombat] UI failed to build: " .. tostring(errUI))
        UI.destroy()
    end

    ESP.init()
    Walls.refresh(clock())
    Hazards.start()

    track(RunService.Heartbeat:Connect(Nav.drive))
    track(RunService.Heartbeat:Connect(function()
        local ok, err = pcall(Bot.step)
        if not ok then Bot.reportError("step", err) end
    end))
    track(player.CharacterAdded:Connect(function(char) Bot.onCharacter(char, false) end))
    if player.Character then Bot.onCharacter(player.Character, true) end

    if State.enabled then Nav.setControls(false) end
    Log.add("Ready - waiting for npcs")
    print("[AutoCombat] loaded")
end

-- Drops every connection and visual and gives the controls back. Also what running the script a second time does.
function Bot.stop()
    Bot.stopped = true
    State.enabled = false
    for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
    table.clear(connections)

    Nav.stopPath()
    pcall(Nav.setControls, true)
    if State.hum then
        pcall(function()
            State.hum.AutoRotate = true
            State.hum:Move(Vector3.zero, false)
        end)
    end
    for obj in pairs(Hazards.active) do Hazards.remove(obj) end
    ESP.destroyAll()
    UI.destroy()
    if env.__AutoCombat and env.__AutoCombat.stop == Bot.stop then setHandle(nil) end
end

function Bot.boot()
    setHandle({ stop = Bot.stop, api = API, config = Config })

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
    if not okStart then warn("[AutoCombat] couldn't fire changeStartValue: " .. tostring(errStart)) end

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

API.Config, API.State, API.Log, API.Npcs, API.Hazards, API.Walls = Config, State, Log, Npcs, Hazards, Walls
API.Nav, API.Skills, API.ESP, API.UI, API.Bot = Nav, Skills, ESP, UI, Bot

Bot.boot()

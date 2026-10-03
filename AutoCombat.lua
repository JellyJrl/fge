--[[
    Auto Combat - clears a dungeon on its own.

    The three jobs, in priority order:
      1. IDENTIFY   Npcs      who is in the dungeon: name, health, aggro range, attack speed, which room, which group,
                              and which are bosses (huge bodies, no aggro limit: they wake once you enter the area).
                    Hazards   what is attacking: precast telegraphs, hitboxes, orbs, npc-named parts, loose models -
                              each with the time window in which it hurts.
      2. SURVIVE    Planner   a space-time search over the whole arena: every attack at once, each with its own timing,
                              plus walls and the npcs' own bodies. It finds the quickest way to a spot that stays safe,
                              and re-plans ten times a second. While nothing threatens us it stays put.
                              After a respawn the 5s immortality is used: attacks that end before it does are ignored, the
                              rest only count from when it ends, so the bot sprints in, attacks, and is clear in time.
      3. CLEAR      Dungeon   rooms in order: fight the room's npcs, then walk to the next room, until none are left.
                    Skills    whatever is in the backpack, sorted by name into buff / attack / heal / defense / ignore.
                              Every attack is fired from inside its own reach (calibrated from what it hits); normal
                              npcs ignore anyone outside their aggro range, so those are fought from inside it.

    Dying less:  attacks are padded more when our health is low, and when something hits us that we didn't see coming;
                 the part that appeared right before such a hit is remembered (this run only) as an attack.
                 While fighting one group, the bot stays out of the aggro range of the others.

    One file, a few module tables:
      Npcs  Dungeon  Hazards  Walls  Planner  Nav  Skills  ESP  UI  Bot
    Running the script again stops the previous run. The running bot is reachable as getgenv().__AutoCombat;
    getgenv().__AutoCombat.api.Bot.dump() prints a report of everything it sees (also the button in the window).
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

    -- ---- fighting distances (studs) ----
    MIN_DISTANCE        = 7,     -- never closer than this to an npc's body
    ATTACK_RANGE        = 90,    -- how far the attack skill is assumed to reach (to an npc's CENTRE); calibrated while fighting
    BACKOFF             = 10,    -- while fighting, back off to the stand ring when this much closer than it
    RANGE_MARGIN        = 6,     -- stand this far inside the cast range
    USE_AGGRO_RANGE     = true,  -- npcs only react to someone inside their `aggroRange`: stand and cast inside it
    AGGRO_MARGIN        = 3,     -- ...this far inside, so we're clearly in it
    AVOID_OTHER_AGGRO   = true,  -- while fighting one group, stay out of the aggro range of the others (don't wake them)
    PULL_RANGE          = 60,    -- an npc from another room this close is part of the fight
    BIG_BODY_GAP        = 12,    -- never closer than this to the edge of a huge npc (a boss)
    GROUP_LINK          = 20,    -- npcs this close to each other are one group
    TARGET_SWITCH       = 2,     -- another npc must be this much closer before the target lock moves
    BODY_RADIUS         = 4,     -- an npc this wide counts as a point; only size beyond it adds keep-away distance
    FLANK_RANGE         = 60,
    BOSS_SIZE           = 30,    -- an npc whose body is this wide (studs) is a boss: no aggro limit, must be fought inside its area
    BOSS_NAMES          = {},    -- extra name fragments (lowercase letters/digits) that mark a boss, e.g. { "dragon", "enchantedtree" }
    NOT_BOSS_NAMES      = {},    -- ...and ones that never are
    BOSS_AREA_MARGIN    = 2,     -- stand at least this far inside the room's edge when fighting a boss

    -- ---- the dungeon ----
    ROOM_EMPTY_WAIT     = 5,     -- standing in a room this long without npcs appearing: it was empty, move on
    ROOM_ARRIVE         = 15,    -- this close to a room's centre = arrived
    ADVANCE_RETRY       = 10,    -- a room we couldn't reach is retried after this long
    FINISH_WAIT         = 4,     -- nothing left to do for this long = the dungeon is complete (the next room may still load)

    -- ---- the dodge planner ----
    GRID                = 3,     -- studs per planning cell
    PLAN_RADIUS         = 9,     -- cells searched around us (x GRID studs)
    PLAN_RADIUS_MAX     = 14,    -- ...widened to this when no safe spot is found
    PLAN_RATE           = 0.1,   -- re-plan this often while threatened
    HORIZON             = 2.5,   -- how far ahead we look for something that will hit where we stand
    SETTLE              = 1.5,   -- a spot we stop at must stay safe this long after we arrive
    NEXT_MIN            = 4.5,   -- head for the first point of the plan this far away (not the very next cell: it would be reached too soon)
    REACTION            = 0.15,  -- input / humanoid delay added to every travel-time estimate
    HIT_COST            = 6,     -- walking through a live attack costs this many seconds of walking per cell (never forbidden)
    PLAN_STICK          = 0.5,   -- a re-plan keeps the previous destination unless another is this many seconds better...
    PLAN_STICK_RADIUS   = 4.5,   -- ...(destinations this close count as the same)

    -- ---- attacks ----
    PADDING             = 2,     -- margin kept around every attack
    VERTICAL            = 4,     -- an attack zone also reaches this far above/below its box (our root sits above the floor)
    PRECAST_DELAY       = 2.0,   -- a precast telegraphs ~2s before the spell fires
    PRECAST_SAFETY      = 0.35,  -- want to be out of a precast zone this long BEFORE it fires
    HITBOX_ASSUME       = 1.5,   -- a hitbox of unknown length is assumed to last this much longer (re-assumed every plan)
    PREDICT_MAX         = 3.0,   -- seconds ahead a MOVING attack is extrapolated (sweeping beams ...), then assumed to stop
    ORB_NAME            = "battlemageorb",
    ORB_PADDING         = 3,
    ORB_HORIZON         = 4.0,   -- an orb is assumed to keep flying this long
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

    -- ---- dying less ----
    CAUTION_HP          = 0.6,   -- below this share of health, attacks are padded more
    CAUTION_PAD         = 1.5,   -- ...by up to this many studs (at 0 health)
    SURPRISE_PAD        = 0.5,   -- every hit from something we didn't see pads attacks this much more...
    SURPRISE_MAX        = 2,     -- ...up to this
    SURPRISE_DECAY      = 0.05,  -- ...fading by this per second
    SUSPECT_WINDOW      = 1.5,   -- parts that appeared this recently before an unseen hit are suspects
    SUSPECT_RADIUS      = 30,    -- ...if they were this close to us
    SUSPECT_HITS        = 2,     -- a suspect that is near two unseen hits is treated as an attack for the rest of this run

    -- ---- movement ----
    REPATH_RATE         = 0.5,
    WAYPOINT_REACHED    = 3.5,
    WAYPOINT_TIMEOUT    = 1.5,
    STUCK_TIME          = 2.5,
    STUCK_MOVE          = 0.4,

    -- ---- barriers (some bosses can't be approached) ----
    BARRIER_STUCK       = 6,     -- not moving for this long while trying to walk = something blocks us
    BARRIER_NO_PROGRESS = 16,    -- walking but not getting closer for this long = same
    BARRIER_PROGRESS    = 2,     -- must get this much closer to count as progress
    BARRIER_LEEWAY      = 15,    -- fire from up to this far past where we got stuck
    BARRIER_RETRY       = 30,    -- forget the barrier after this long and try to get closer again
    BARRIER_WALL_DIST   = 25,    -- ...only if a wall really is this close in front of us
    BARRIER_CAP         = 40,    -- a barrier never stretches the attack range more than this

    -- ---- skills ----
    -- Every Tool with a `cooldown` value is a skill, sorted into a kind by its name (see Skills): buff, attack, heal,
    -- defense, or ignore (never fired). Anything unrecognised is an attack. SKILL_KINDS overrides it per tool name, e.g.
    -- { ["Dash Strike"] = "attack", ["Taunt"] = "ignore" }.
    SKILL_KINDS         = {},
    BUFF_SKILLS         = { "innerrage", "enhancedinnerrage", "innerfocus", "enhancedinnerfocus" },   -- exact (normalized) names
    BUFF_WORDS          = { "rage", "berserk", "frenzy", "bloodlust", "warcry", "battlecry", "empower", "haste", "fury", "bolster", "rally", "overdrive", "adrenaline" },
    SPEED_WORDS         = { "innerrage", "haste", "swift", "sprint", "speed", "adrenaline", "overdrive" },   -- buffs that make us faster
    HEAL_WORDS          = { "heal", "regen", "recover", "mend", "cure", "restore", "revive", "bandage" },
    DEFENSE_WORDS       = { "shield", "guard", "barrier", "block", "ward", "protect", "fortify", "bulwark", "aegis", "invuln", "immun" },
    IGNORE_WORDS        = { "dash", "blink", "teleport", "leap", "roll", "evade", "dodge", "shadowstep", "sidestep", "vault", "warp" },
    ATTACK_WORDS        = { "bash", "slam", "throw", "strike", "blast", "bolt", "arrow", "shot", "slash", "smite", "nova", "storm", "barrage", "fireball", "meteor", "burst" },
    HEAL_BELOW          = 0.55,  -- a heal skill is used below this share of health
    DEFENSE_BELOW       = 0.4,   -- a defense skill is also used (when an attack is coming) below this share of health
    READY_MAX           = 0,     -- a tool is ready when its `cooldown` value is <= this (ready = -0.1)
    FALLBACK_COOLDOWN   = 8,
    MIN_GAP             = 0.8,   -- never use the same skill twice within this
    EQUIP_DELAY         = 0.12,
    AIM_SETTLE          = 0.1,   -- let the rotation reach the server before firing
    AIM_HOLD            = 0.3,   -- stay busy this long after firing
    CAST_CONFIRM        = 0.15,  -- after firing, check the cooldown really started
    RETRY_DELAY         = 3,     -- a skill that did nothing is left alone this long
    RAGE_DURATION       = 3,     -- length of a buff until learned from the game's own cooldown numbers
    RAGE_DELAY          = 0.15,  -- after the buff, wait this long before the attack so its bonus is on
    RAGE_ESCAPE_SLACK   = 0.35,  -- spend a speed buff on escaping when we'd get out of an attack with less than this to spare
    RAGE_CROWD          = 3,     -- ...or when this many attacks are closing in and we can't attack anyway
    RAGE_CROWD_RADIUS   = 20,
    RAGE_SPEED_MULT     = 1.4,   -- assumed speed multiplier of a speed buff (for deciding whether to spend it on travel)
    RAGE_TRAVEL_MIN_SAVED = 2.5, -- spend it on travel only if that saves at least this many seconds...
    RAGE_TRAVEL_MAX_LOSS  = 6,   -- ...and it is back within this many seconds of arriving
    REACH_STEP          = 5,     -- an attack's reach shrinks/grows by this when casts miss/connect (faster until it first connects)
    REACH_FIRST_FLOOR   = 45,    -- before an attack has ever connected its reach is only shrunk down to this (a boss that hasn't woken up misses too)
    REACH_REGROW_AFTER  = 3,     -- this many hits in a row with a shrunk reach: back off by two steps
    PROBE_INTERVAL      = 20,    -- an attack whose reach was shrunk is tried again from further out this often
    REACH_MAX           = 160,   -- no reach is ever believed to be more than this
    UTILITY_STRIKES     = 3,     -- an attack that damages nothing in this many casts from well inside its reach is a utility
    HIT_WINDOW          = 1.5,   -- seconds after a cast to look for a health drop
    SPAWN_SHIELD        = 5,     -- seconds of immortality after respawning: ignore attacks, go all-in
    SHIELD_SAFETY       = 0.4,   -- ...but stop relying on it this much early
    SHIELD_TAIL         = 0.8,   -- being too close to an npc only matters again this long before the shield ends
    SHIELD_SPRINT_DIST  = 12,    -- during the shield, spend a speed buff on the way in when still this far from the fight

    -- ---- visuals ----
    AUTO_AIM            = true,  -- always face the target (shift-lock style)
    ESP                 = true,
    ESP_LABELS          = true,
    UI_SCALE            = 1,
}

-- =====================
-- SHARED: modules, state, helpers
-- =====================
local Npcs, Dungeon, Hazards, Walls, Planner, Nav, Skills, ESP, UI, Bot = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
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
    spawnedAt = -100,      -- when the current character appeared (after a respawn)
    ffSeen = false,        -- the spawn shield showed up as a ForceField
    ignoreDirty = false,   -- the ray filter needs a rebuild
    kills = 0,
    deaths = 0,
    startedAt = 0,
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
-- NPCS: who is in the dungeon
-- workspace.dungeon.<room>.enemyFolder.<npc model>, each with a Humanoid and (usually) numbers describing it:
--   aggroRange   how close you must be before it reacts (precasts, attacks) at all
--   attackSpeed  how long its attack sequence (precast + hitbox) lasts
-- Bosses are not like the rest: huge bodies (sometimes no HumanoidRootPart), and their aggroRange means nothing - they
-- wake up when you enter the area. They are recognised (name, a boss flag, or a body wider than BOSS_SIZE) and get no
-- aggro limit; a body too big to stand outside of is capped so the stand ring always lies inside the skills' reach.
-- `list` is every living npc; `pool` is the ones we are fighting or heading for right now (see Dungeon.pool).
-- =====================
Npcs.list = {}      -- { {model, room, root, pos, radius, humanoid, hp, key, aggro, attackSpeed, group} }
Npcs.pool = {}      -- the part of `list` the bot is dealing with
Npcs.groups = {}    -- built from the pool: { {members, centroid, radius, count} }
Npcs.locked = nil   -- the model we're locked onto
Npcs.lastRefresh = -math.huge
Npcs.cache = setmetatable({}, { __mode = "k" })     -- [model] = { root, radius, humanoid, key, t }
Npcs.seen = setmetatable({}, { __mode = "k" })      -- [model] = true while we know it alive (to count kills)
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

-- a yes/no off any Instance: an attribute, or a Bool/Number value child
local function readFlag(inst, names)
    for _, name in ipairs(names) do
        local a = inst:GetAttribute(name)
        if a == true or (type(a) == "number" and a ~= 0) then return true end
        local v = inst:FindFirstChild(name)
        if v and v:IsA("ValueBase") then
            local x = v.Value
            if x == true or (type(x) == "number" and x ~= 0) then return true end
        end
    end
    return false
end

-- Health of an npc: the Humanoid's, or (bosses without one) a Health / MaxHealth pair published as values or attributes.
-- Returns health, max - or nil when nothing says.
Npcs.HEALTH_NAMES = { "Health", "health", "HP", "hp", "CurrentHealth" }
Npcs.MAX_NAMES = { "MaxHealth", "maxHealth", "MaxHP", "maxHp", "maxhp" }
function Npcs.readHealth(model, humanoid)
    if humanoid and humanoid.Parent then return humanoid.Health, humanoid.MaxHealth end
    local health, max
    for _, name in ipairs(Npcs.HEALTH_NAMES) do
        health = readNumber(model, name)
        if health then break end
    end
    if health == nil then return nil, nil end
    for _, name in ipairs(Npcs.MAX_NAMES) do
        max = readNumber(model, name)
        if max then break end
    end
    return health, max or health
end

function Npcs.isBoss(model, key, width)
    for _, word in ipairs(Config.NOT_BOSS_NAMES) do
        if key:find(word, 1, true) then return false end
    end
    for _, word in ipairs(Config.BOSS_NAMES) do
        if key:find(word, 1, true) then return true end
    end
    if key:find("boss", 1, true) then return true end
    if readFlag(model, { "boss", "Boss", "isBoss", "IsBoss" }) then return true end
    return width >= Config.BOSS_SIZE
end

-- Geometry is cached for ~1s (huge models aren't measured every frame); the numbers the npc publishes are cheap
-- and read fresh, so one added a moment before its first attack is never missed.
function Npcs.info(model, now)
    local info = Npcs.cache[model]
    if not (info and info.root.Parent and now - info.t < 1) then
        local root = (info and info.root.Parent) and info.root or Npcs.findRoot(model)
        if not root then return nil end
        local size = model:GetExtentsSize()
        local width = math.max(size.X, size.Z)
        local key = normalize(model.Name)
        -- body size beyond a point is extra keep-away distance - but never more than leaves room to stand inside the
        -- skills' reach (a boss as big as a hill must not push the stand ring out of range)
        local cap = math.max(0, math.max(Skills.reach or Config.ATTACK_RANGE, Config.ATTACK_RANGE) - Config.RANGE_MARGIN - Config.MIN_DISTANCE)
        info = {
            root = root, t = now,
            radius = math.min(cap, math.max(0, width / 2 - Config.BODY_RADIUS)),
            width = width,
            humanoid = model:FindFirstChildOfClass("Humanoid"),
            key = key,
            boss = Npcs.isBoss(model, key, width),
        }
        Npcs.cache[model] = info
    end
    info.aggro = readNumber(model, "aggroRange")
    info.attackSpeed = readNumber(model, "attackSpeed")
    return info
end

-- Rebuilds `list` unless it is younger than `maxAge`. A NEW table every time, so a loop halfway through the old
-- one is never disturbed. Counts the npcs that died since the last rebuild.
function Npcs.refresh(maxAge)
    local now = clock()
    if now - Npcs.lastRefresh < (maxAge or 0) then return end
    Npcs.lastRefresh = now

    local list, aliveNow = {}, {}
    for _, room in ipairs(Npcs.rooms()) do
        local folder = room:FindFirstChild("enemyFolder")
        if folder then
            for _, model in ipairs(folder:GetChildren()) do
                if model:IsA("Model") then
                    local info = Npcs.info(model, now)
                    local health, max = nil, nil
                    if info then health, max = Npcs.readHealth(model, info.humanoid) end
                    -- a dead npc lingering through its death animation is no longer a target
                    if info and not (health and health <= 0) then
                        aliveNow[model] = true
                        table.insert(list, {
                            model = model, room = room, root = info.root, pos = info.root.Position, radius = info.radius,
                            humanoid = info.humanoid, hp = (health and max and max > 0) and math.clamp(health / max, 0, 1) or 1,
                            key = info.key, aggro = info.aggro, attackSpeed = info.attackSpeed,
                            boss = info.boss, width = info.width,
                        })
                    end
                end
            end
        end
    end
    for model in pairs(Npcs.seen) do
        if not aliveNow[model] then
            Npcs.seen[model] = nil
            State.kills = State.kills + 1
        end
    end
    for model in pairs(aliveNow) do Npcs.seen[model] = true end
    Npcs.list = list
end

-- nearest npc of `list` by SURFACE (centre distance minus its extra body radius)
function Npcs.nearest(pos, list)
    local best, bestDist = nil, math.huge
    for _, n in ipairs(list) do
        local d = flat(pos - n.pos).Magnitude - n.radius
        if d < bestDist then best, bestDist = n, d end
    end
    return best, bestDist
end

-- Skills and aggro both reach by distance to an npc's CENTRE: a boss with a massive body looks "close" by its edge
-- but can still be far out of reach.
function Npcs.nearestCenter(pos, list)
    local best, bestDist = nil, math.huge
    for _, n in ipairs(list) do
        local d = flat(pos - n.pos).Magnitude
        if d < bestDist then best, bestDist = n, d end
    end
    return best, bestDist
end

-- how close we are to ANY npc's body: the keep-away distance applies to all of them, fighting or not
function Npcs.surfaceDistance(pos)
    local _, d = Npcs.nearest(pos, Npcs.list)
    return d
end

-- npcs within GROUP_LINK of a group member join it
function Npcs.buildGroups()
    local groups = {}
    local pool = Npcs.pool
    for _, n in ipairs(pool) do n.group = nil end

    for _, seed in ipairs(pool) do
        if not seed.group then
            local id = #groups + 1
            local members = { seed }
            seed.group = id

            local i = 1
            while i <= #members do
                local cur = members[i]
                for _, other in ipairs(pool) do
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
            local boss
            for _, m in ipairs(members) do
                if m.boss then boss = boss or m end
            end
            groups[id] = { members = members, centroid = centroid, radius = radius, count = #members, boss = boss, room = boss and boss.room or seed.room }
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
        for _, n in ipairs(Npcs.pool) do
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
-- own aggro range - it ignores anyone out there, so there would be nothing to fight. Two exceptions:
--  * a boss: its aggroRange means nothing, it wakes up once you enter the area
--  * an aggro range too small to stand inside (the npc's body plus the keep-away distance already fills it)
-- A barrier we can't pass overrides the aggro limit as well (nothing nearer is possible; holding fire would just leave the
-- bot idle). `reach` is the skill's own reach (default: the longest of the attack skills').
-- Returns the range and whether the aggro range is what limits it.
function Npcs.castRange(npc, barrier, reach)
    reach = reach or Skills.reach
    if barrier and not barrier.holdFire then
        return math.min(math.max(reach, barrier.centerDist + Config.BARRIER_LEEWAY), reach + Config.BARRIER_CAP), false
    end
    local aggro = npc and npc.aggro
    if Config.USE_AGGRO_RANGE and aggro and aggro > 0 and not npc.boss then
        local inside = aggro - Config.AGGRO_MARGIN
        local standable = (npc.radius or 0) + Config.MIN_DISTANCE + Config.RANGE_MARGIN   -- a spot we may legally stand on
        if inside >= standable and inside < reach then return inside, true end
    end
    return reach, false
end

-- the strictest cast range in a group: standing inside it puts every npc of the group in reach
function Npcs.groupRange(group, barrier, reach)
    local range = nil
    for _, m in ipairs(group and group.members or {}) do
        local r = Npcs.castRange(m, barrier, reach)
        if not range or r < range then range = r end
    end
    return range or reach or Skills.reach
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
-- DUNGEON: the rooms, in order, and how far through them we are
-- workspace.dungeon.<room>.enemyFolder. Rooms are taken in name order (room1, room2, ... room10): the first one that still
-- has living npcs is the one being fought; when none has, the first one not yet cleared is where to walk next; when
-- every room is cleared the dungeon is finished.
--   cleared   a room that had npcs and now has none, or one we stood in for ROOM_EMPTY_WAIT seconds that never had any
-- =====================
Dungeon.rooms = {}                                   -- sorted: { room, name, alive }
Dungeon.cleared = setmetatable({}, { __mode = "k" })  -- [room] = true
Dungeon.hadNpcs = setmetatable({}, { __mode = "k" })  -- [room] = true once npcs were seen in it
Dungeon.enteredAt = setmetatable({}, { __mode = "k" }) -- [room] = when we started standing in it (while it had no npcs)
Dungeon.blocked = setmetatable({}, { __mode = "k" })  -- [room] = when it may be tried again (we couldn't reach it)
Dungeon.bounds = setmetatable({}, { __mode = "k" })   -- [room] = { min, max, center, t }
Dungeon.finished = false
Dungeon.quietSince = nil                              -- since when nothing was left to do
Dungeon.lastRefresh = -math.huge

local function sortKey(name)
    local text, num = name:lower():match("^(%D*)(%d*)")
    return text or "", tonumber(num) or math.huge
end

local function roomLess(a, b)
    local ta, na = sortKey(a.name)
    local tb, nb = sortKey(b.name)
    if ta ~= tb then return ta < tb end
    if na ~= nb then return na < nb end
    return a.name < b.name
end

local function inEnemyFolder(part, room)
    local p = part.Parent
    while p and p ~= room do
        if p.Name == "enemyFolder" then return true end
        p = p.Parent
    end
    return false
end

-- the area a room covers (its parts, not its npcs), measured once in a while
function Dungeon.boundsOf(room)
    local b = Dungeon.bounds[room]
    if b and clock() - b.t < 10 then return b end

    local lo, hi
    for _, d in ipairs(room:GetDescendants()) do
        if d:IsA("BasePart") and not inEnemyFolder(d, room) then
            local half = d.Size / 2
            local a, c = d.Position - half, d.Position + half
            lo = lo and Vector3.new(math.min(lo.X, a.X), math.min(lo.Y, a.Y), math.min(lo.Z, a.Z)) or a
            hi = hi and Vector3.new(math.max(hi.X, c.X), math.max(hi.Y, c.Y), math.max(hi.Z, c.Z)) or c
        end
    end
    if not lo then return nil end
    b = { min = lo, max = hi, center = (lo + hi) / 2, t = clock() }
    Dungeon.bounds[room] = b
    return b
end

-- is `pos` within the box `b` of Dungeon.boundsOf, grown by `margin` studs (negative = that far inside its edge)?
function Dungeon.within(b, pos, margin)
    margin = margin or 0
    return b ~= nil and pos.X >= b.min.X - margin and pos.X <= b.max.X + margin and pos.Z >= b.min.Z - margin and pos.Z <= b.max.Z + margin
end

function Dungeon.inside(room, pos)
    return Dungeon.within(Dungeon.boundsOf(room), pos, 5)
end

-- Re-reads the rooms and decides which are cleared. Twice a second is plenty.
function Dungeon.refresh(now, me)
    if now - Dungeon.lastRefresh < 0.5 then return end
    Dungeon.lastRefresh = now

    local counts = {}
    for _, n in ipairs(Npcs.list) do counts[n.room] = (counts[n.room] or 0) + 1 end

    local rooms = {}
    for _, room in ipairs(Npcs.rooms()) do
        if room:FindFirstChild("enemyFolder") then
            table.insert(rooms, { room = room, name = room.Name, alive = counts[room] or 0 })
        end
    end
    table.sort(rooms, roomLess)
    Dungeon.rooms = rooms

    for _, r in ipairs(rooms) do
        local room = r.room
        if r.alive > 0 then
            if not Dungeon.hadNpcs[room] then Log.add("Room " .. r.name .. ": " .. r.alive .. " npc(s)") end
            Dungeon.hadNpcs[room] = true
            Dungeon.cleared[room] = nil   -- (a new wave reopens it)
            Dungeon.enteredAt[room] = nil
        elseif not Dungeon.cleared[room] then
            if Dungeon.hadNpcs[room] then
                Dungeon.cleared[room] = true
                Log.add("Room " .. r.name .. " cleared")
            elseif me and Dungeon.inside(room, me) then
                -- standing in a room that never had npcs: give them a moment to spawn, then move on
                Dungeon.enteredAt[room] = Dungeon.enteredAt[room] or now
                if now - Dungeon.enteredAt[room] >= Config.ROOM_EMPTY_WAIT then
                    Dungeon.cleared[room] = true
                    Log.add("Room " .. r.name .. " is empty")
                end
            else
                Dungeon.enteredAt[room] = nil
            end
        end
    end

    -- finished: there are rooms, nothing is left (nor any room we haven't done), and it stays that way for FINISH_WAIT
    -- seconds (the next room may only be built once this one is cleared)
    local pending = false
    for _, r in ipairs(rooms) do
        if r.alive > 0 or not Dungeon.cleared[r.room] then pending = true end
    end
    if #rooms > 0 and not pending then
        Dungeon.quietSince = Dungeon.quietSince or now
    else
        Dungeon.quietSince = nil
    end
    local finished = Dungeon.quietSince ~= nil and now - Dungeon.quietSince >= Config.FINISH_WAIT
    if finished and not Dungeon.finished then
        Log.add(string.format("Dungeon complete: %d npcs killed, %d death(s), %.0fs", State.kills, State.deaths, clock() - State.startedAt))
    end
    Dungeon.finished = finished
end

-- the room being fought: the first (in order) with living npcs
function Dungeon.active()
    for _, r in ipairs(Dungeon.rooms) do
        if r.alive > 0 then return r end
    end
    return nil
end

-- where to walk when nothing is alive: the first room not yet cleared (and not one we gave up on for now)
function Dungeon.next(now)
    for _, r in ipairs(Dungeon.rooms) do
        if r.alive == 0 and not Dungeon.cleared[r.room] and now >= (Dungeon.blocked[r.room] or 0) then
            return r
        end
    end
    return nil
end

-- a floor point in the middle of a room (the centre of its box, dropped onto the ground)
function Dungeon.goal(r)
    local b = Dungeon.boundsOf(r.room)
    if not b then return nil end
    local hit = Walls.cast(Vector3.new(b.center.X, b.max.Y + 50, b.center.Z), Vector3.new(0, -(b.max.Y - b.min.Y) - 300, 0))
    return hit and (hit.Position + Vector3.new(0, 3, 0)) or b.center
end

-- the npcs the bot is dealing with: the active room's, plus any from other rooms that are close enough to be part of
-- the fight (they have noticed us, or are about to)
function Dungeon.pool(list, me)
    local active = Dungeon.active()
    if not active then return list end
    local pool = {}
    for _, n in ipairs(list) do
        if n.room == active.room then
            table.insert(pool, n)
        else
            local surface = flat(me - n.pos).Magnitude - n.radius
            if surface <= math.max(n.aggro or 0, Config.PULL_RANGE) then table.insert(pool, n) end
        end
    end
    return pool
end

-- "3/8" style summary for the UI: rooms cleared / rooms
function Dungeon.progress()
    local done = 0
    for _, r in ipairs(Dungeon.rooms) do
        if Dungeon.cleared[r.room] then done = done + 1 end
    end
    return done, #Dungeon.rooms
end

-- =====================
-- HAZARDS: what is attacking, and WHEN it hurts
--   precast  telegraph; fires PRECAST_DELAY seconds after it appears (from then on the same area is a hitbox)
--   hitbox   active now (its length is worked out when the game says; otherwise assumed HITBOX_ASSUME at a time)
--   orb      a moving part, recognised by name or by its Trail / Attachment / Mist
--   unknown  a loose Model dropped into workspace, or a part blamed for an unseen hit: dangerous until proven scenery
-- Every zone has a time window [on, off] (seconds from now) in which it is dangerous, and a shape at each moment in it.
-- ONE question is asked about all of them - "does this zone occupy this point during [t0, t1]?" - by the planner and by
-- every check, so they can never disagree. A zone's geometry is read once per frame by update().
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

-- dying less: padding grows with low health and with hits we didn't see coming (this run only, never saved)
Hazards.extraPad = 0
Hazards.surprise = 0
Hazards.recent = {}      -- parts that just appeared: { name, raw, pos, t } - suspects when something unseen hits us
Hazards.suspects = {}    -- [normalized name] = unseen hits it was near
Hazards.learned = {}     -- [normalized name] = true: treated as an attack for the rest of this run

function Hazards.pad()
    return Config.PADDING + Hazards.extraPad
end

-- hp = share of health left; dt = seconds since the last call
function Hazards.setCaution(hp, dt)
    Hazards.surprise = math.max(0, Hazards.surprise - Config.SURPRISE_DECAY * dt)
    local low = math.clamp((Config.CAUTION_HP - hp) / Config.CAUTION_HP, 0, 1) * Config.CAUTION_PAD
    Hazards.extraPad = low + Hazards.surprise
end

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
    if Hazards.learned[name] then return "hitbox" end   -- blamed for hits we didn't see coming (this run)
    if name:find("precast", 1, true) then return "precast" end
    if name:find("hitbox", 1, true) then return "hitbox" end

    -- Beyond the names above, only parts sitting directly in workspace are considered: permanent scenery lives
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

    if now - zone.born > 2 then zone.gaveUp = true end   -- nothing found: assumed HITBOX_ASSUME at a time
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

-- remembered for a moment: if something we never saw coming hits us, one of these is probably it
function Hazards.noteRecent(obj)
    if obj.Name:sub(1, 1) == "_" or Hazards.active[obj] or Hazards.isIgnored(obj) or Hazards.inCharacter(obj) then return end
    table.insert(Hazards.recent, { name = normalize(obj.Name), raw = obj.Name, pos = obj.Position, t = clock() })
    if #Hazards.recent > 60 then table.remove(Hazards.recent, 1) end
end

function Hazards.onAdded(obj)
    if obj:IsA("BasePart") then
        Hazards.add(obj, nil, true)
        Hazards.noteRecent(obj)
    elseif obj:IsA("Model") or obj:IsA("Folder") then
        for _, d in ipairs(obj:GetDescendants()) do
            if d:IsA("BasePart") then
                Hazards.add(d, nil, true)
                Hazards.noteRecent(d)
            end
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

-- We were hit and no zone explains it. Every part that appeared near us just before is a suspect; one that is near two
-- such hits is treated as an attack for the rest of this run. Returns the suspects' names (for the log).
function Hazards.blame(pos)
    local now = clock()
    local names, order, seen = {}, {}, {}
    for _, r in ipairs(Hazards.recent) do
        if now - r.t <= Config.SUSPECT_WINDOW and flat(pos - r.pos).Magnitude <= Config.SUSPECT_RADIUS
            and not seen[r.name] and not Hazards.learned[r.name] then
            seen[r.name] = true
            table.insert(order, r.raw)
            Hazards.suspects[r.name] = (Hazards.suspects[r.name] or 0) + 1
            if Hazards.suspects[r.name] >= Config.SUSPECT_HITS then
                Hazards.learned[r.name] = true
                Hazards.skip = setmetatable({}, { __mode = "k" })   -- everything gets a fresh look under the new name
                Log.add("Learned attack (this run): " .. r.raw)
            end
        end
    end
    Hazards.surprise = math.min(Config.SURPRISE_MAX, Hazards.surprise + Config.SURPRISE_PAD)
    return order
end

-- ---- when does it hurt? ----

-- seconds until the zone becomes harmful (0 = harmful right now)
function Hazards.timeToFire(zone, now)
    if zone.kind == "precast" then
        return math.max(0, Config.PRECAST_DELAY - (now - zone.born))
    end
    return 0
end

-- The time window [on, off] (seconds from now) in which the zone is dangerous. A precast is dangerous from just before
-- it fires (PRECAST_SAFETY) for as long as it lasts (the hitbox that replaces it covers the same ground).
function Hazards.window(zone, now)
    local age = now - zone.born
    if zone.kind == "precast" then
        -- dangerous from just before it fires, until its sequence (precast + hitbox) is over - when the npc says how long that is
        local off = zone.seq and (math.max(zone.seq, Config.PRECAST_DELAY + 1) - age + Config.PRECAST_SAFETY) or math.huge
        return math.max(0, Config.PRECAST_DELAY - age - Config.PRECAST_SAFETY), off
    elseif zone.kind == "hitbox" then
        if zone.duration then
            return 0, math.max(0, zone.duration - age) + Config.PRECAST_SAFETY
        end
        return 0, Config.HITBOX_ASSUME
    elseif zone.kind == "orb" then
        return 0, Config.ORB_HORIZON
    end
    return 0, math.max(0, Config.UNKNOWN_MAX_AGE - age)
end

-- every zone with its window, for a batch of questions at one moment (the planner asks thousands)
-- While we are immortal (a fresh spawn: Hazards.shieldLeft seconds more) an attack can only hurt from the moment the shield
-- ends: one that is over by then is dropped, the rest start no earlier. The planner and everything else then simply never
-- see the harmless part, and the bot is clear of the zones the instant the shield runs out.
Hazards.shieldLeft = 0

function Hazards.windows(now)
    local list = {}
    local shield = Hazards.shieldLeft
    for _, zone in pairs(Hazards.active) do
        local on, off = Hazards.window(zone, now)
        if off > shield then
            table.insert(list, { zone = zone, on = math.max(on, shield), off = off })
        end
    end
    return list
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

-- Does the segment (u0,w0)-(u1,w1) touch the box [-hx,hx] x [-hz,hz]? (slab method)
function Hazards.segBox(u0, w0, u1, w1, hx, hz)
    local lo, hi = 0, 1
    local du, dw = u1 - u0, w1 - w0
    if du > -1e-9 and du < 1e-9 then
        if u0 < -hx or u0 > hx then return false end
    else
        local ta, tb = (-hx - u0) / du, (hx - u0) / du
        if ta > tb then ta, tb = tb, ta end
        if ta > lo then lo = ta end
        if tb < hi then hi = tb end
        if lo > hi then return false end
    end
    if dw > -1e-9 and dw < 1e-9 then
        if w0 < -hz or w0 > hz then return false end
    else
        local ta, tb = (-hz - w0) / dw, (hz - w0) / dw
        if ta > tb then ta, tb = tb, ta end
        if ta > lo then lo = ta end
        if tb < hi then hi = tb end
        if lo > hi then return false end
    end
    return true
end

-- Does this zone (dangerous during [on, off]) occupy `pos` at any moment in [t0, t1]?
-- A MOVING zone (a sweeping beam) slides over the ground meanwhile, so the question is whether the spot's path through
-- the zone's own frame - the spot moves the opposite way - touches the zone. (A moving zone is extrapolated at most
-- PREDICT_MAX seconds ahead; after that it is assumed to stop.)
function Hazards.occupies(zone, on, off, pos, t0, t1, pad)
    local a, b = math.max(t0, on), math.min(t1, off)
    if a > b then return false end
    pad = pad or Hazards.pad()

    if zone.kind == "orb" then
        return orbDistance(zone, pos, a, b) <= zone.radius + (pad - Config.PADDING)
    end
    local half = zone.size / 2
    if zone.moving then
        local a2, b2 = math.min(a, Config.PREDICT_MAX), math.min(b, Config.PREDICT_MAX)
        local l0 = zone.cf:PointToObjectSpace(pos - zone.vel * a2)
        local l1 = zone.cf:PointToObjectSpace(pos - zone.vel * b2)
        return math.abs((l0.Y + l1.Y) / 2) <= half.Y + pad + Config.VERTICAL
            and Hazards.segBox(l0.X, l0.Z, l1.X, l1.Z, half.X + pad, half.Z + pad)
    end
    local l = zone.cf:PointToObjectSpace(pos)
    return math.abs(l.X) <= half.X + pad and math.abs(l.Z) <= half.Z + pad and math.abs(l.Y) <= half.Y + pad + Config.VERTICAL
end

-- does any zone of a windows() list occupy `pos` during [t0, t1]?
function Hazards.hitWin(list, pos, t0, t1, pad)
    for _, w in ipairs(list) do
        if Hazards.occupies(w.zone, w.on, w.off, pos, t0, t1, pad) then return true end
    end
    return false
end

-- The first moment within `horizon` seconds at which something hits `pos` if we stand there (math.huge = nothing does).
function Hazards.firstHitWin(list, pos, horizon, pad)
    local best = math.huge
    for _, w in ipairs(list) do
        local start = w.on
        if start <= horizon and w.off >= 0 then
            local z = w.zone
            if z.kind == "orb" or z.moving then
                local t, last = start, math.min(w.off, horizon)
                while t <= last do
                    if Hazards.occupies(z, w.on, w.off, pos, t, t + 0.1, pad) then
                        best = math.min(best, t)
                        break
                    end
                    t = t + 0.1
                end
            elseif Hazards.occupies(z, w.on, w.off, pos, start, start, pad) then
                best = math.min(best, start)
            end
        end
    end
    return best
end

function Hazards.firstHit(pos, horizon, pad)
    return Hazards.firstHitWin(Hazards.windows(clock()), pos, horizon or Config.HORIZON, pad)
end

-- studs between `pos` and the edge of ONE zone (0 = inside); orbs by their whole future path
function Hazards.zoneClearance(zone, pos, pad)
    if zone.kind == "orb" then
        return math.max(0, orbDistance(zone, pos, 0, Config.ORB_HORIZON) - zone.radius)
    end
    pad = pad or Config.PADDING
    local l = zone.cf:PointToObjectSpace(pos)
    local half = zone.size / 2
    local dx = math.max(math.abs(l.X) - (half.X + pad), 0)
    local dy = math.max(math.abs(l.Y) - (half.Y + pad + Config.VERTICAL), 0)
    local dz = math.max(math.abs(l.Z) - (half.Z + pad), 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- how many attacks are within `radius` studs of `pos`
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

-- the cheap test the planner makes for every step between neighbouring cells: one ray along the step at body height, and
-- floor under the end
function Walls.stepClear(a, b)
    if Walls.cast(a + Vector3.new(0, 1, 0), b - a) then return false end
    return Walls.floorBelow(b)
end
-- =====================
-- PLANNER: where to be, and how to get there without being hit
-- The arena is cut into GRID-stud cells. A search spreads out from where we stand in order of cost - ARRIVAL TIME (we
-- walk at WalkSpeed) plus HIT_COST for every cell entered while an attack occupies it. Every attack has its own time
-- window (a precast is harmless until just before it fires, an orb is where it will be then, a sweeping beam is swept
-- along its path, a hitbox ends when it ends), so a cell is only "hit" if an attack is really there while we pass.
-- Walking THROUGH an attack is allowed but dear: when we are already inside one (the middle of two crossing lines) the
-- cheapest way out is found instead of none.
-- A cell is a place to STOP only if it stays safe for SETTLE seconds after we arrive, keeps clear of the npcs' bodies
-- and suits the fight (the caller's `penalty`). The best stopping place - quickest to reach, plus its penalty - wins,
-- and its path is the answer. Many attacks at once, crossing each other, are just more things the search gets around.
-- The attacks are compiled to plain numbers first, so the thousands of questions are cheap.
-- =====================
local G = Config.GRID
local PM = Config.PREDICT_MAX
local segBox = Hazards.segBox

Planner.edges = {}        -- [fromKey][toKey] = { ok, t }: walls don't move, so "can I step from here to there" is remembered
Planner.edgeCount = 0
Planner.last = nil        -- the last plan: { path, arrival, safe, slack, visited }
Planner.lastGoal = nil    -- where it ended, and when it was made (the next plan leans toward the same place)
Planner.lastAt = -math.huge

local DIRS = {}
for dx = -1, 1 do
    for dz = -1, 1 do
        if dx ~= 0 or dz ~= 0 then table.insert(DIRS, { dx, dz, math.sqrt(dx * dx + dz * dz) }) end
    end
end

local function cellOf(p) return math.floor(p.X / G + 0.5), math.floor(p.Z / G + 0.5) end
local function keyOf(cx, cz) return (cx + 8192) * 16384 + (cz + 8192) end

-- a binary min-heap on `cost`
local function heapPush(h, item)
    local n = #h + 1
    h[n] = item
    while n > 1 do
        local p = math.floor(n / 2)
        if h[p].cost <= h[n].cost then break end
        h[p], h[n] = h[n], h[p]
        n = p
    end
end

local function heapPop(h)
    local top = h[1]
    local last = table.remove(h)
    local n = #h
    if n > 0 then
        h[1] = last
        local i = 1
        while true do
            local l, r, s = i * 2, i * 2 + 1, i
            if l <= n and h[l].cost < h[s].cost then s = l end
            if r <= n and h[r].cost < h[s].cost then s = r end
            if s == i then break end
            h[i], h[s] = h[s], h[i]
            i = s
        end
    end
    return top
end

-- Attacks as plain numbers, keeping only those that can matter within `reach` studs of `from` in the next `horizon`
-- seconds. Each is { on, off, ... } plus an orb's path or a box's centre / axes / half extents (already padded).
local function compile(wins, from, pad, horizon, reach)
    local out = {}
    for _, w in ipairs(wins) do
        local z = w.zone
        if w.on <= horizon and w.off >= 0 then
            if z.kind == "orb" then
                local v = z.flatVel
                local a = flat(z.pos)
                local span = math.min(w.off, horizon + Config.SETTLE)
                local e = a + v * span
                -- the closest the orb's path comes to us, against what it could reach
                local ab = e - a
                local p = flat(from) - a
                local len2 = ab:Dot(ab)
                local u = len2 > 0.001 and math.clamp(p:Dot(ab) / len2, 0, 1) or 0
                local r = z.radius + (pad - Config.PADDING)
                if (p - ab * u).Magnitude <= reach + r then
                    table.insert(out, { orb = true, on = w.on, off = w.off, ax = a.X, az = a.Z, vx = v.X, vz = v.Z, r2 = r * r })
                end
            else
                local cf, half = z.cf, z.size / 2
                if math.abs(from.Y - cf.Position.Y) <= half.Y + pad + Config.VERTICAL then
                    local rv, lv = cf.RightVector, cf.LookVector
                    local rl = math.sqrt(rv.X * rv.X + rv.Z * rv.Z)
                    local ll = math.sqrt(lv.X * lv.X + lv.Z * lv.Z)
                    if rl > 0.01 and ll > 0.01 then
                        local reachBox = math.max(half.X, half.Z) * 1.5 + pad + (z.moving and flat(z.vel).Magnitude * PM or 0)
                        if flat(cf.Position - from).Magnitude <= reach + reachBox then
                            table.insert(out, {
                                on = w.on, off = w.off, moving = z.moving,
                                cx = cf.Position.X, cz = cf.Position.Z,
                                rx = rv.X / rl, rz = rv.Z / rl, lx = lv.X / ll, lz = lv.Z / ll,
                                hx = half.X + pad, hz = half.Z + pad, vx = z.vel.X, vz = z.vel.Z,
                            })
                        end
                    end
                end
            end
        end
    end
    return out
end

-- does any compiled attack occupy (x, z) at some moment in [t0, t1]?
local function hitAt(list, x, z, t0, t1)
    for i = 1, #list do
        local h = list[i]
        local a = t0 > h.on and t0 or h.on
        local b = t1 < h.off and t1 or h.off
        if a <= b then
            if h.orb then
                local sx, sz = h.ax + h.vx * a, h.az + h.vz * a
                local ex, ez = (b - a) * h.vx, (b - a) * h.vz
                local px, pz = x - sx, z - sz
                local len2 = ex * ex + ez * ez
                local u = 0
                if len2 > 0.001 then
                    u = (px * ex + pz * ez) / len2
                    if u < 0 then u = 0 elseif u > 1 then u = 1 end
                end
                local dx, dz = px - ex * u, pz - ez * u
                if dx * dx + dz * dz <= h.r2 then return true end
            else
                if h.moving then   -- the spot's path through the box's own frame (see Hazards.occupies)
                    local a2, b2 = a < PM and a or PM, b < PM and b or PM
                    local dx0, dz0 = x - h.vx * a2 - h.cx, z - h.vz * a2 - h.cz
                    local dx1, dz1 = x - h.vx * b2 - h.cx, z - h.vz * b2 - h.cz
                    if segBox(dx0 * h.rx + dz0 * h.rz, dx0 * h.lx + dz0 * h.lz, dx1 * h.rx + dz1 * h.rz, dx1 * h.lx + dz1 * h.lz, h.hx, h.hz) then return true end
                else
                    local dx, dz = x - h.cx, z - h.cz
                    local lx = dx * h.rx + dz * h.rz
                    local lz = dx * h.lx + dz * h.lz
                    if lx <= h.hx and lx >= -h.hx and lz <= h.hz and lz >= -h.hz then return true end
                end
            end
        end
    end
    return false
end

-- can we step between two neighbouring cells? (remembered)
function Planner.stepOk(ax, az, bx, bz, apos, bpos, now)
    local ka, kb = keyOf(ax, az), keyOf(bx, bz)
    local row = Planner.edges[ka]
    if not row then
        row = {}
        Planner.edges[ka] = row
    end
    local e = row[kb]
    if e and now - e.t < 30 then return e.ok end

    local ok = Walls.stepClear(apos, bpos)
    row[kb] = { ok = ok, t = now }
    Planner.edgeCount = Planner.edgeCount + 1
    if Planner.edgeCount > 30000 then   -- a very long dungeon: start over rather than grow without end
        Planner.edges, Planner.edgeCount = {}, 0
    end
    return ok
end

-- a step turned out to be blocked after all (the full body check failed): remember it
function Planner.blockStep(a, b)
    local ax, az = cellOf(a)
    local bx, bz = cellOf(b)
    local ka, kb = keyOf(ax, az), keyOf(bx, bz)
    Planner.edges[ka] = Planner.edges[ka] or {}
    Planner.edges[ka][kb] = { ok = false, t = clock() }
end

-- Which point of the path to head for. The very next cell centre is too close (reached before the next plan, so the bot
-- would stand still waiting for it); the first point NEXT_MIN studs away is better, but only if the straight line to it
-- stays clear of every attack in the times we'd be passing - otherwise fall back toward the next cell.
local function lookahead(list, path, speed)
    local from = path[1]
    local chosen = path[2]
    for k = 2, #path do
        local target = path[k]
        local dx, dz = target.X - from.X, target.Z - from.Z
        local d = math.sqrt(dx * dx + dz * dz)
        local ok = true
        local steps = math.max(1, math.floor(d / 1.5))
        for i = 1, steps do
            local f = i / steps
            local t = Config.REACTION + d * f / speed
            if hitAt(list, from.X + dx * f, from.Z + dz * f, t - 0.1, t + 0.1) then
                ok = false
                break
            end
        end
        if not ok then break end
        chosen = target
        if d >= Config.NEXT_MIN then break end
    end
    return chosen
end

-- opts: from, speed, windows (Hazards.windows), penalty(pos) -> extra seconds-equivalent cost of stopping there,
--       radius (cells). Returns { path = {Vector3...}, arrival, safe, slack, visited } or nil.
function Planner.plan(opts)
    local from, speed, now = opts.from, opts.speed, clock()
    local R = opts.radius or Config.PLAN_RADIUS
    local pad = Hazards.pad()
    local settle = Config.SETTLE
    local penalty = opts.penalty
    local list = compile(opts.windows, from, pad, settle + Config.HORIZON, R * G + 6)
    local y = from.Y

    local startSurface = Npcs.surfaceDistance(from)
    local transitFloor = math.min(Config.MIN_DISTANCE, startSurface) - 0.1   -- never deeper into an npc than we already are
    local sx, sz = cellOf(from)
    local startKey = keyOf(sx, sz)

    local nodes = { [startKey] = { cx = sx, cz = sz, t = 0, c = 0, h = 0, pos = from } }
    local heap = {}
    heapPush(heap, { cost = 0, key = startKey })
    local closed, order = {}, {}
    local best, bestTotal = nil, math.huge
    local R2 = R * R

    -- Stay with the previous plan's destination unless another is clearly better: with several equally good spots the
    -- choice would otherwise flip from one re-plan to the next and the bot would dither instead of running.
    local stickPos = (now - Planner.lastAt < 0.6) and Planner.lastGoal or nil
    local stick = Config.PLAN_STICK
    local stickR2 = Config.PLAN_STICK_RADIUS * Config.PLAN_STICK_RADIUS

    while #heap > 0 do
        local top = heapPop(heap)
        local key = top.key
        if not closed[key] then
            closed[key] = true
            local node = nodes[key]
            if node.c - stick > bestTotal then break end   -- penalties are never negative: nothing later can beat the best
            table.insert(order, node)
            local pos = node.pos

            -- a place to stop? it must stay safe, clear of the npcs, and suit the fight
            if not hitAt(list, pos.X, pos.Z, node.t, node.t + settle) and Npcs.surfaceDistance(pos) >= Config.MIN_DISTANCE then
                local total = node.c + penalty(pos)
                if stickPos then
                    local dx, dz = pos.X - stickPos.X, pos.Z - stickPos.Z
                    if dx * dx + dz * dz <= stickR2 then total = total - stick end
                end
                if total < bestTotal then best, bestTotal = node, total end
            end

            for _, d in ipairs(DIRS) do
                local nx, nz = node.cx + d[1], node.cz + d[2]
                if (nx - sx) * (nx - sx) + (nz - sz) * (nz - sz) <= R2 then
                    local nk = keyOf(nx, nz)
                    if not closed[nk] then
                        local step = d[3] * G / speed
                        local tn = node.t + step + (node.parent == nil and Config.REACTION or 0)
                        local npos = Vector3.new(nx * G, y, nz * G)
                        -- never into an npc; through an attack only at a price
                        if Npcs.surfaceDistance(npos) >= transitFloor then
                            local hit = hitAt(list, npos.X, npos.Z, tn - step / 2, tn + step / 2)
                            local cn = node.c + (tn - node.t) + (hit and Config.HIT_COST or 0)
                            local old = nodes[nk]
                            if (not old or cn < old.c - 1e-6) and Planner.stepOk(node.cx, node.cz, nx, nz, pos, npos, now) then
                                nodes[nk] = { cx = nx, cz = nz, t = tn, c = cn, h = node.h + (hit and 1 or 0), pos = npos, parent = node }
                                heapPush(heap, { cost = cn, key = nk })
                            end
                        end
                    end
                end
            end
        end
    end

    local safe = best ~= nil and best.h == 0
    if not best then
        -- nowhere is safe within reach: take the place where we can stay the longest, nearest first
        local bestScore = -math.huge
        for i = 1, math.min(#order, 150) do
            local node = order[i]
            local until_ = Hazards.firstHitWin(opts.windows, node.pos, Config.HORIZON + 4, pad)
            local score = math.min(until_, 8) - node.t * 0.5
            if score > bestScore then best, bestScore = node, score end
        end
    end
    if not best then return nil end

    local path, n = {}, best
    while n do
        table.insert(path, 1, n.pos)
        n = n.parent
    end
    local startHit = Hazards.firstHitWin(opts.windows, from, Config.HORIZON, pad)
    local plan = {
        path = path, arrival = best.t, safe = safe, hits = best.h or 0, visited = #order,
        next = #path >= 2 and lookahead(list, path, speed) or nil,
        slack = (startHit == math.huge) and math.huge or (safe and (startHit - best.t) or -math.huge),
    }
    Planner.last = plan
    Planner.lastGoal, Planner.lastAt = path[#path], now
    return plan
end

-- =====================
-- NAV: movement, facing, walking long distances
-- Humanoid:Move(direction) is used instead of MoveTo(point): Move() is pure velocity and never touches facing, so it
-- coexists with us setting the rotation ourselves every frame (AutoRotate = false is built for exactly this).
-- Short, safety-critical movement is the Planner's; this module walks the long way (navmesh paths) and carries out
-- whatever it was told.
-- =====================
Nav.goal = nil            -- where Humanoid:Move is taking us, or nil to stand still
Nav.aim = nil             -- the point to face (set by the bot every frame)
Nav.ownsRotation = false
Nav.pathThread = nil
Nav.pathing = false       -- a path is being walked
Nav.computing = false     -- a path is being computed
Nav.pathGoal = nil        -- destination of the path being walked
Nav.controls = nil
Nav.plan = nil            -- the planner's path we are following
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

-- ---- following the planner ----

-- The point to head for on a plan's path (the planner picks it: see Planner's lookahead).
function Nav.nextPoint(plan)
    if not plan or not plan.path or #plan.path < 2 then return nil end
    return plan.next or plan.path[2]
end

-- Walk the planner's path (redone ten times a second). An empty or one-point path means "stay". Returns its destination.
function Nav.follow(plan)
    Nav.plan = plan
    local path = plan and plan.path
    if not path or #path < 2 then
        Nav.stop()
        return nil
    end
    Nav.setGoal(Nav.nextPoint(plan))
    return path[#path]
end

-- ---- walking a computed path ----

function Nav.stopPath()
    if Nav.pathThread then
        task.cancel(Nav.pathThread)
        Nav.pathThread = nil
    end
    Nav.pathing = false
end

-- something that should pull us off a walk: an attack about to hit where we stand, or an npc right on top of us
function Nav.interrupted()
    local pos = State.hrp.Position
    return Hazards.firstHit(pos, 1.2) < math.huge
        or (Hazards.shieldLeft < Config.SHIELD_TAIL and Npcs.surfaceDistance(pos) < Config.MIN_DISTANCE)
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

-- is an attack (live now, or live by the time we get there) on the way we're walking?
function Nav.aheadBlocked()
    local md = State.hum.MoveDirection
    if md.Magnitude < 0.1 then return false end
    local dir = flat(md).Unit
    local speed = math.max(State.hum.WalkSpeed, 8)
    local from = State.hrp.Position
    local wins = Hazards.windows(clock())
    for d = 3, math.max(8, speed * 0.9), 3 do
        local t = d / speed + Config.REACTION
        if Hazards.hitWin(wins, from + dir * d, t, t + 0.4) then return true end
    end
    return false
end

-- ---- where to stand ----

-- How far from a group's centre to stand: inside the cast range (and so inside the aggro range of the npcs that have a
-- usable one), never closer than BIG_BODY_GAP to the edge of a huge body, and never outside the skills' reach.
-- Returns the ring radius and the closest we may stand.
function Nav.ringRadius(group, barrier)
    local range = Npcs.groupRange(group, barrier)
    local lowest = math.max(group.radius + Config.BIG_BODY_GAP, Config.MIN_DISTANCE + 6)
    local r = math.max(range - Config.RANGE_MARGIN, lowest)
    return math.min(r, math.max(range - 2, Config.MIN_DISTANCE + 6)), lowest
end

-- Legal points to stand at around a group, best first (near us, and not inside the aggro range of npcs that are NOT part
-- of this fight). A boss wakes up when you enter its area, so for one the points must lie inside the room, on the largest
-- ring that has any (a room smaller than the skills' reach has no point that far out).
function Nav.ringPoints(group, barrier)
    local ringR, lowest = Nav.ringRadius(group, barrier)
    local me = State.hrp.Position
    local wins = Hazards.windows(clock())
    local bounds = (group.boss and not barrier and group.room) and Dungeon.boundsOf(group.room) or nil

    local speed = math.max(State.hum.WalkSpeed, 8)
    local function collect(radius, insideOnly)
        local pts = {}
        for angle = 0, 345, 15 do
            local r = math.rad(angle)
            local p = Vector3.new(group.centroid.X + math.cos(r) * radius, group.centroid.Y, group.centroid.Z + math.sin(r) * radius)
            local walk = flat(p - me).Magnitude / speed
            -- the point must be clear when we GET there (and for a while after), not just right now
            if Npcs.surfaceDistance(p) >= Config.MIN_DISTANCE + 1 and not Hazards.hitWin(wins, p, walk, walk + Config.SETTLE + 1) and Walls.floorBelow(p)
                and (not insideOnly or Dungeon.within(bounds, p, -Config.BOSS_AREA_MARGIN)) then
                table.insert(pts, { pos = p, cost = walk + Bot.pullCost(p, group) })
            end
        end
        return pts
    end

    local pts, usedR = collect(ringR, false), ringR
    if bounds then
        local radius = ringR
        while radius >= lowest - 0.01 do
            local inside = collect(radius, true)
            if #inside > 0 then
                pts, usedR = inside, radius
                break
            end
            radius = radius - 8
        end
    end
    table.sort(pts, function(a, b) return a.cost < b.cost end)
    local out = {}
    for i, p in ipairs(pts) do out[i] = p.pos end
    return out, usedR
end

-- =====================
-- SKILLS: ability detection and casting
-- A skill is a Tool with a numeric `cooldown` (-0.1 = ready, otherwise counting down) and a `cooldownLength`. They are
-- scanned from the backpack at runtime, so the bot works with any loadout - nothing here is tied to Inner Rage / Gale
-- Barrage. Each skill is sorted by its name into a KIND:
--   buff     fired before attacking (Inner Rage ...); the fast ones can also be spent on speed (escaping, travelling)
--   attack   fired at the target whenever it is inside THAT skill's reach (the default for any name it doesn't know)
--   heal     fired when health is low
--   defense  fired when an attack is about to land and we can't get out of its way
--   ignore   never fired (dashes and the like: where they would take us is not something the bot can steer)
-- Config.SKILL_KINDS overrides the sorting for a specific tool name. An "attack" that never damages anything is
-- demoted to a utility (still fired, but it no longer decides where the bot stands). Each attack skill calibrates its
-- own reach from what its casts hit and miss.
-- =====================
Skills.list = {}              -- the skills carried, in the order they are used: { name, kind, reach, live, ... }
Skills.byName = {}            -- [tool name] = skill record (kept across respawns: calibrated reach, hit counts)
Skills.buff = nil             -- name of the main buff
Skills.attack = nil           -- name of the main attack
Skills.reach = Config.ATTACK_RANGE   -- the longest reach among the attacks (to an npc's centre): where the bot stands
Skills.busy = false
Skills.castUntil = 0          -- attacks that appear before this, close to us, are our own
Skills.attackNotBefore = 0
Skills.lastAttack = -100
Skills.lastAttackSkill = nil
Skills.castBarrier = nil      -- the barrier the last attack was fired against, if any
Skills.retryAfter = {}        -- [tool name] = time before which we won't retry a skill that did nothing
Skills.method = {}            -- [tool name] = "event" | "activate" (what worked last time)
Skills.cooldowns = {}         -- [tool name] = { prev, peak, startT, learned }
Skills.info = { plan = "" }
Skills.pendingHits = {}       -- { skill, checkAt, targets, barrier, ambiguous } waiting for a health check

local KIND_ORDER = { buff = 1, attack = 2, utility = 3, heal = 4, defense = 5, ignore = 6 }

local function hasWord(norm, words)
    for _, w in ipairs(words) do
        if norm:find(w, 1, true) then return true end
    end
    return false
end

function Skills.isBuff(toolName)
    local n = normalize(toolName)
    for _, buff in ipairs(Config.BUFF_SKILLS) do
        if n == buff then return true end
    end
    return false
end

-- does this buff make us faster? (so it can be spent on escaping and travelling)
function Skills.isSpeed(norm)
    return hasWord(norm, Config.SPEED_WORDS)
end

-- the kind a skill is sorted into by its name
function Skills.classify(name)
    local norm = normalize(name)
    local forced = Config.SKILL_KINDS[name] or Config.SKILL_KINDS[norm]
    if forced then return forced end
    if hasWord(norm, Config.ATTACK_WORDS) then return "attack" end   -- "Shield Bash" is an attack, not a shield
    if Skills.isBuff(name) then return "buff" end
    if hasWord(norm, Config.HEAL_WORDS) then return "heal" end
    if hasWord(norm, Config.DEFENSE_WORDS) then return "defense" end
    if hasWord(norm, Config.IGNORE_WORDS) then return "ignore" end
    if hasWord(norm, Config.BUFF_WORDS) then return "buff" end
    return "attack"
end

-- how far a skill is assumed to reach before anything has been seen: a value the game publishes on the tool, else the default
local function initialReach(tool)
    for _, key in ipairs({ "range", "Range", "maxRange", "MaxRange", "distance", "Distance" }) do
        local v = readNumber(tool, key)
        if v and v > 5 then return math.min(v, Config.REACH_MAX) end
    end
    return Config.ATTACK_RANGE
end

function Skills.recomputeReach()
    local best = nil
    for _, s in ipairs(Skills.list) do
        if s.kind == "attack" then best = math.max(best or 0, s.reach) end
    end
    if not best then
        for _, s in ipairs(Skills.list) do
            if s.asAttack then best = math.max(best or 0, s.reach) end
        end
    end
    Skills.reach = best or Config.ATTACK_RANGE
end

-- (re)scans the backpack and the equipped tools. Returns true when the loadout changed.
function Skills.detect()
    local found = {}

    local function check(t)
        if not t:IsA("Tool") or readNumber(t, "cooldown") == nil then return end   -- no cooldown = not a skill we manage
        if found[t.Name] then return end
        local s = Skills.byName[t.Name]
        local forced = Config.SKILL_KINDS[t.Name] or Config.SKILL_KINDS[normalize(t.Name)]
        if s and forced and s.kind ~= forced then   -- the override was set after the skill was first seen
            s.kind, s.speed = forced, forced == "buff" and Skills.isSpeed(s.norm)
        end
        if not s then
            local reach = initialReach(t)
            s = {
                name = t.Name, norm = normalize(t.Name), kind = Skills.classify(t.Name), reach = reach, baseReach = reach,
                hits = 0, casts = 0, strikes = 0, lastUse = -100, lastProbe = -100, activeUntil = 0,
            }
            s.speed = s.kind == "buff" and Skills.isSpeed(s.norm)
            Skills.byName[t.Name] = s
        end
        s.length = readNumber(t, "cooldownLength") or 0
        found[t.Name] = s
    end

    local bp = player:FindFirstChild("Backpack")
    if bp then for _, t in ipairs(bp:GetChildren()) do check(t) end end
    if player.Character then for _, t in ipairs(player.Character:GetChildren()) do check(t) end end

    local list = {}
    for _, s in pairs(found) do table.insert(list, s) end
    table.sort(list, function(a, b)
        if a.kind ~= b.kind then return (KIND_ORDER[a.kind] or 9) < (KIND_ORDER[b.kind] or 9) end
        if a.length ~= b.length then return a.length > b.length end
        return a.name < b.name
    end)

    -- no attack at all (a loadout of "buffs" the sorting got wrong): the unknown-named ones are the attacks
    local attacks = 0
    for _, s in ipairs(list) do if s.kind == "attack" then attacks = attacks + 1 end end
    for _, s in ipairs(list) do
        s.asAttack = (attacks == 0 and s.kind == "buff" and not Skills.isBuff(s.name)) or nil
    end

    local changed = #list ~= #Skills.list
    if not changed then
        for i, s in ipairs(list) do
            if Skills.list[i] ~= s then changed = true break end
        end
    end
    Skills.list = list
    Skills.buff, Skills.attack = nil, nil
    for _, s in ipairs(list) do
        if s.kind == "buff" and not Skills.buff then Skills.buff = s.name end
        if (s.kind == "attack" or s.asAttack) and not Skills.attack then Skills.attack = s.name end
    end
    Skills.recomputeReach()

    if changed then
        local parts = {}
        for _, s in ipairs(list) do table.insert(parts, s.name .. " (" .. s.kind .. ")") end
        Log.add("Skills: " .. (#parts > 0 and table.concat(parts, ", ") or "none found"))
        UI.skillNames()
    end
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

-- everything tied to the old character is dropped (buffs are lost on death, cooldowns start over)
function Skills.reset()
    Skills.attackNotBefore, Skills.busy = 0, false
    Skills.pendingHits = {}
    Skills.retryAfter = {}
    for _, s in pairs(Skills.byName) do
        s.activeUntil, s.lastUse, s.live = 0, -100, nil
    end
end

-- ---- the buff as a dodging / travelling tool ----

-- Should a speed buff be spent on SPEED while fighting? A reason, or nil:
--  A) an attack is about to hit us and the planner says we'd only just make it out at normal speed (its slack = how
--     much time we'd have to spare)
--  B) several attacks are closing in and we can't attack anyway
function Skills.speedReason(c, canAttack)
    if c.threatened and c.slack and c.slack < Config.RAGE_ESCAPE_SLACK then
        return string.format("buff to escape (%.1fs to spare)", math.max(c.slack, -9.9))
    end
    if not canAttack then
        local n = Hazards.nearby(State.hrp.Position, Config.RAGE_CROWD_RADIUS)
        if n >= Config.RAGE_CROWD then return string.format("buff for speed: %d attacks closing in", n) end
    end
    return nil
end

-- Should a speed buff be spent on getting to the fight? Right after a respawn (we are immortal: the buff is free speed
-- for the sprint back) always when far; otherwise only when it saves real time and is back soon after arriving.
function Skills.travelReason(s, c)
    if not c.approaching or not c.travel or c.travel <= 0 then return nil end
    if c.shielded and c.travel > Config.SHIELD_SPRINT_DIST then return "respawn sprint: speed buff to reach the fight" end
    local base = math.max(State.hum.WalkSpeed, 1)
    local travelTime = c.travel / (base * Config.RAGE_SPEED_MULT)
    local saved = c.travel / base - travelTime
    local lost = math.max(0, s.live.length - travelTime)   -- how long we'd then be without it after arriving
    if saved >= Config.RAGE_TRAVEL_MIN_SAVED and lost <= Config.RAGE_TRAVEL_MAX_LOSS then
        return string.format("buff for travel (saves ~%.1fs)", saved)
    end
    return nil
end

-- ---- using the skills: once per frame, after movement ----
-- c = { now, npc (nearest by centre), centreDist, barrier, threatened, slack, shielded, hpFrac, approaching, travel }
function Skills.update(c)
    local now = c.now
    local info = Skills.info
    info.plan = ""
    for _, s in ipairs(Skills.list) do s.live = Skills.get(s.name, s.lastUse) end
    if Skills.busy then return end
    if c.shielded then info.plan = "spawn shield: all-in attack" end

    local function ready(s) return s.live ~= nil and s.live.ready end
    local function buffActive(s)
        return now < s.activeUntil or (s.live ~= nil and s.live.remaining > s.live.length + 0.3)   -- cooldown above its length = still running
    end
    local function cast(s, reason, aim)
        if Skills.use(s.live.tool, s.name, aim) then
            s.lastUse = now
            s.casts = s.casts + 1
            if reason then info.plan = reason end
            return true
        end
        return false
    end
    local function fireBuff(s, reason)
        if cast(s, reason, false) then
            s.activeUntil = now + ((s.live.extra or 0) >= 0.5 and s.live.extra or Config.RAGE_DURATION)
            if reason ~= "buff first, then attack" then Log.add(s.name .. ": " .. reason) end   -- why it was spent early
            return true
        end
        return false
    end

    -- survival first
    if not c.shielded then
        for _, s in ipairs(Skills.list) do
            if ready(s) then
                if s.kind == "heal" and (c.hpFrac or 1) < Config.HEAL_BELOW then
                    if cast(s, "heal: health low") then return end
                elseif s.kind == "defense" and c.threatened
                    and ((c.slack and c.slack < Config.RAGE_ESCAPE_SLACK) or (c.hpFrac or 1) < Config.DEFENSE_BELOW) then
                    if cast(s, "defense: an attack is about to land") then return end
                end
            end
        end
    end

    -- the attacks that could be fired right now: ready, and the target inside their reach
    local anyAttack, fireable, probing = false, nil, false
    if c.npc then
        local blocked = c.barrier and c.barrier.holdFire
        for _, s in ipairs(Skills.list) do
            if s.kind == "attack" or s.kind == "utility" or s.asAttack then
                anyAttack = true
                if ready(s) and not fireable then
                    local limit = Npcs.castRange(c.npc, c.barrier, s.reach)
                    if blocked then
                        info.plan = "attack isn't reaching from the barrier, holding"
                    elseif c.centreDist <= limit then
                        fireable = s
                    elseif s.reach < s.baseReach and now - s.lastProbe >= Config.PROBE_INTERVAL
                        and c.centreDist <= Npcs.castRange(c.npc, c.barrier, s.baseReach) then
                        -- Its reach was shrunk after misses (a boss that hadn't woken up, a phase it couldn't be hurt in ...):
                        -- every so often try from where we stand, so a skill that works again isn't written off for good.
                        fireable, probing = s, true
                        info.plan = s.name .. ": probe shot (reach was shrunk)"
                    elseif info.plan == "" then
                        info.plan = string.format("%s ready, out of range (%.0f / %.0f)", s.name, c.centreDist, limit)
                    end
                end
            end
        end
    end

    -- the speed buffs: escaping, travelling
    for _, s in ipairs(Skills.list) do
        if s.kind == "buff" and s.speed and ready(s) and not buffActive(s) and not c.shielded then
            local why = Skills.speedReason(c, fireable ~= nil)
            if why and fireBuff(s, why) then return end
        end
    end
    if not c.npc then return end
    for _, s in ipairs(Skills.list) do
        if s.kind == "buff" and s.speed and ready(s) and not buffActive(s) then
            local why = Skills.travelReason(s, c)
            if why and fireBuff(s, why) then return end
        end
    end

    if not anyAttack then
        if info.plan == "" then info.plan = "no attack skill in backpack" end
        return
    end
    if not fireable then
        if info.plan == "" then
            local soonest = nil
            for _, s in ipairs(Skills.list) do
                if (s.kind == "attack" or s.kind == "utility" or s.asAttack) and s.live then
                    soonest = math.min(soonest or math.huge, s.live.remaining)
                end
            end
            if soonest then info.plan = string.format("attack cooldown %.1fs", soonest) end
        end
        return
    end

    -- buffs first (damage), a moment for them to take effect, then the attack
    for _, s in ipairs(Skills.list) do
        if s.kind == "buff" and not s.asAttack and ready(s) and not buffActive(s) then
            if fireBuff(s, "buff first, then attack") then Skills.attackNotBefore = now + Config.RAGE_DELAY end
            return
        end
    end
    if now < Skills.attackNotBefore then
        info.plan = "buff ramping up"
        return
    end

    if cast(fireable, probing and (fireable.name .. ": probe shot (reach was shrunk)") or ("attack fired: " .. fireable.name), true) then
        if probing then fireable.lastProbe = now end
        Skills.lastAttack = now
        Skills.lastAttackSkill = fireable
        Skills.castBarrier = c.barrier
    end
end

-- ---- calibration: does the attack connect from here? ----
-- When an attack's cooldown starts (a cast), nearby npcs' health is noted; a moment later, a drop means it connected
-- from that distance (its reach grows to it), no drop at near the edge of its reach means it fell short (the reach shrinks,
-- quickly until the skill has connected once, so the bot stands closer next time). A skill that never damages anything
-- from well inside its reach is demoted to a utility. Against a barrier, repeated misses stop the bot wasting casts.
local function healthNow(t)
    local health = Npcs.readHealth(t.model, t.humanoid)
    return health
end

function Skills.watch(now)
    for i = #Skills.pendingHits, 1, -1 do
        local p = Skills.pendingHits[i]
        if now >= p.checkAt then
            local s = p.skill
            local hit = false
            for _, t in ipairs(p.targets) do
                local gone = t.model.Parent == nil
                local health = (not gone) and healthNow(t) or nil
                if gone or (health ~= nil and health <= t.health - 1) then
                    hit = true
                    if not p.ambiguous and t.dist > s.reach and t.dist <= Config.REACH_MAX then s.reach = math.ceil(t.dist) end
                end
            end

            if hit then
                s.hits, s.strikes, s.streak = s.hits + 1, 0, (s.streak or 0) + 1
                -- connecting steadily with a shrunk reach: it may reach further than it was cut to, so back off again
                -- (a miss at the longer distance shrinks it right back)
                if s.streak >= Config.REACH_REGROW_AFTER and s.reach < s.baseReach and not p.barrier then
                    s.reach = math.min(s.baseReach, s.reach + Config.REACH_STEP * 2)
                    s.streak = 0
                    Log.add(string.format("%s keeps connecting - backing off (reach now %d)", s.name, s.reach))
                end
                if s.kind == "utility" then
                    s.kind = "attack"
                    Log.add(s.name .. " damages after all - an attack again")
                end
            end

            if p.barrier then
                if hit then
                    p.barrier.misses = 0
                    p.barrier.holdFire = false
                elseif not p.ambiguous then
                    p.barrier.misses = p.barrier.misses + 1
                    if p.barrier.misses >= 2 and not p.barrier.holdFire then
                        p.barrier.holdFire = true
                        Log.add("Attack isn't reaching from the barrier, holding fire")
                    end
                end
            elseif not hit and not p.ambiguous and p.targets[1] then
                local nearest = p.targets[1].dist
                s.streak = 0
                if nearest >= s.reach * 0.85 then
                    -- until it has connected once: quickly down to FIRST_FLOOR (most skills reach that far); then slowly
                    local floor_ = Config.MIN_DISTANCE + Config.RANGE_MARGIN + 4
                    local shorter
                    if s.hits == 0 and s.reach > Config.REACH_FIRST_FLOOR then
                        shorter = math.max(Config.REACH_FIRST_FLOOR, s.reach * 0.8)
                    else
                        shorter = math.max(floor_, s.reach - Config.REACH_STEP)
                    end
                    if shorter < s.reach then
                        s.reach = math.floor(shorter)
                        Log.add(string.format("%s not connecting - closing in (reach now %d)", s.name, s.reach))
                    end
                elseif nearest <= s.reach * 0.6 and s.kind == "attack" and s.hits == 0 then
                    s.strikes = s.strikes + 1   -- well inside its reach and still nothing: maybe it isn't a damage skill
                    if s.strikes >= Config.UTILITY_STRIKES then
                        s.kind = "utility"
                        Log.add(s.name .. " never damages anything - treated as a utility")
                    end
                end
            end
            Skills.recomputeReach()
            table.remove(Skills.pendingHits, i)
        end
    end

    -- a cast shows up as the cooldown starting
    for _, s in ipairs(Skills.list) do
        if s.kind == "attack" or s.kind == "utility" or s.asAttack then
            local tool = findTool(s.name)
            local cd = tool and readNumber(tool, "cooldown")
            local prev = s.lastCd
            s.lastCd = cd
            if cd ~= nil and prev ~= nil and prev <= Config.READY_MAX and cd > Config.READY_MAX and State.hrp then
                local targets = {}
                for _, n in ipairs(Npcs.list) do
                    local health = Npcs.readHealth(n.model, n.humanoid)
                    if health then
                        table.insert(targets, { model = n.model, humanoid = n.humanoid, health = health, dist = flat(State.hrp.Position - n.pos).Magnitude })
                    end
                end
                table.sort(targets, function(a, b) return a.dist < b.dist end)
                if #targets > 0 then
                    -- another cast still waiting for its check: whose damage is whose can't be told
                    local ambiguous = #Skills.pendingHits > 0
                    for _, other in ipairs(Skills.pendingHits) do other.ambiguous = true end
                    table.insert(Skills.pendingHits, {
                        skill = s, checkAt = now + Config.HIT_WINDOW, targets = targets, ambiguous = ambiguous,
                        barrier = (now - Skills.lastAttack < 1.5 and Skills.lastAttackSkill == s) and Skills.castBarrier or nil,
                    })
                end
            end
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
                local len = speed * 1.0   -- the next second of its flight
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

-- the planner's route: a handful of line segments, reused every plan instead of rebuilt
ESP.planParts = {}
function ESP.setPlan(path)
    local n = (path and State.esp) and (#path - 1) or 0
    for i = 1, math.max(n, #ESP.planParts) do
        local part = ESP.planParts[i]
        if i <= n then
            if not part then
                part = ESP.marker("_Plan", Enum.PartType.Block, Color3.fromRGB(255, 255, 0))
                ESP.planParts[i] = part
            end
            local a, b = path[i], path[i + 1]
            local len = (b - a).Magnitude
            if len > 0.05 then
                part.Size = Vector3.new(0.15, 0.15, len)
                part.CFrame = CFrame.lookAt((a + b) / 2, b)
                part.Transparency = 0.15
            else
                part.Transparency = 1
            end
        elseif part then
            part.Transparency = 1
        end
    end
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
        data.highlight.FillColor = isTarget and ESP.RED or (stats.inPool and stats.inPool[n.model] and ESP.ORANGE or Color3.fromRGB(120, 120, 120))
        data.highlight.OutlineColor = isTarget and ESP.RED or Color3.fromRGB(200, 100, 0)
        data.highlight.FillTransparency = isTarget and 0.4 or 0.7
        data.gui.Enabled = on and Config.ESP_LABELS
        if text then
            data.label.Text = string.format("%s%s%s  %.0f%%  %.0f%s", isTarget and "> " or "", n.boss and "[BOSS] " or "", n.model.Name, n.hp * 100, surface,
                (n.aggro and not n.boss) and string.format("  (aggro %.0f)", n.aggro) or "")
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
    if on and stats.target and stats.target.aggro and not stats.target.boss then
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
        ESP.setPlan(nil)
        ESP.ring.Transparency, ESP.aggroRing.Transparency = 1, 1
        ESP.goal.Transparency, ESP.tracer.Transparency = 1, 1
    end
    Log.add(on and "ESP on" or "ESP off")
end

function ESP.destroyAll()
    for _, p in ipairs(ESP.planParts) do destroy(p) end
    ESP.planParts = {}
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
    ["ADVANCE"] = UI.C.yellow, ["DONE"] = UI.C.green, ["IDLE"] = UI.C.grey, ["OFF"] = UI.C.grey, ["DEAD"] = UI.C.grey,
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
    k.Size = UDim2.new(0.4, 0, 1, 0)
    k.Text = key
    k.TextTruncate = Enum.TextTruncate.AtEnd
    local v = label(r, 13, Enum.Font.GothamMedium, UI.C.text, Enum.TextXAlignment.Right)
    v.Size = UDim2.new(0.6, 0, 1, 0)
    v.Position = UDim2.fromScale(0.4, 0)
    v.TextTruncate = Enum.TextTruncate.AtEnd
    return v, k, r
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

    local dump = Instance.new("TextButton")
    dump.Size = UDim2.new(1, 0, 0, 24)
    dump.AutoButtonColor = false
    dump.BorderSizePixel = 0
    dump.BackgroundColor3 = UI.C.button
    dump.TextColor3 = UI.C.dim
    dump.Font = Enum.Font.GothamMedium
    dump.TextSize = 12
    dump.Text = "Print report to console"
    dump.LayoutOrder = nextOrder(body)
    dump.Parent = body
    corner(dump, 7)
    outline(dump, UI.C.line, 1, 0.3)
    dump.MouseButton1Click:Connect(function() pcall(Bot.dump) end)

    -- the dungeon
    local dungeon = card(body, "DUNGEON")
    UI.refs.room = row(dungeon, "Room")
    UI.refs.progress = row(dungeon, "Progress")
    UI.refs.tally = row(dungeon, "Kills / deaths")
    UI.refs.npcs = label(dungeon, 12, Enum.Font.Code, UI.C.dim)
    UI.refs.npcs.Size = UDim2.new(1, 0, 0, 64)
    UI.refs.npcs.TextYAlignment = Enum.TextYAlignment.Top
    UI.refs.npcs.LayoutOrder = nextOrder(dungeon)

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

    -- skills: one row per skill carried (hidden when unused)
    local skills = card(body, "SKILLS")
    UI.refs.skillRows = {}
    for i = 1, UI.MAX_SKILLS do
        local value, key, frame = row(skills, "")
        local b = bar(skills)
        UI.refs.skillRows[i] = { value = value, key = key, frame = frame, bar = b }
    end
    UI.refs.reachRow = row(skills, "Reach")
    UI.skillNames()

    local logCard = card(body, "LOG")
    UI.refs.log = label(logCard, 12, Enum.Font.Code, UI.C.dim)
    UI.refs.log.Size = UDim2.new(1, 0, 0, 92)
    UI.refs.log.TextYAlignment = Enum.TextYAlignment.Top
    UI.refs.log.TextWrapped = true
    UI.refs.log.LayoutOrder = nextOrder(logCard)
end

-- the skills are only known once the backpack has been scanned, which can happen after the window was built
UI.MAX_SKILLS = 8
local KIND_COLORS = { buff = "yellow", attack = "orange", utility = "grey", heal = "green", defense = "blue", ignore = "dim" }

function UI.skillNames()
    local rows = UI.refs.skillRows
    if not rows then return end
    for i, r in ipairs(rows) do
        local sk = Skills.list[i]
        r.frame.Visible = sk ~= nil
        r.bar.track.Visible = sk ~= nil
        if sk then
            r.key.Text = esc(sk.name)
            r.key.TextColor3 = UI.C[KIND_COLORS[sk.kind] or "dim"]
        end
    end
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
        if st.target.boss then
            r.reach.Text = col(UI.C.purple, "<b>BOSS</b>") .. col(UI.C.dim, string.format("  cast within %.0f  %s", st.castRange, inside and "(inside)" or "(outside)"))
        elseif st.target.aggro then
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

    -- the dungeon
    local active, nextRoom = Dungeon.active(), Dungeon.next(now)
    local done, total = Dungeon.progress()
    if Dungeon.finished then
        r.room.Text = col(UI.C.green, "<b>COMPLETE</b>")
    elseif active then
        r.room.Text = string.format("%s  %s", esc(active.name), col(UI.C.dim, active.alive .. " npc(s) left"))
    elseif nextRoom then
        r.room.Text = col(UI.C.yellow, "heading to " .. esc(nextRoom.name))
    else
        r.room.Text = col(UI.C.dim, "--")
    end
    r.progress.Text = total > 0 and string.format("%d / %d rooms cleared", done, total) or col(UI.C.dim, "no rooms found")
    r.tally.Text = string.format("%d  /  %s", State.kills, col(State.deaths > 0 and UI.C.orange or UI.C.dim, tostring(State.deaths)))
    -- the npcs closest to us: who they are, how hurt, how far, how far their aggro reaches
    local rows = {}
    local near = {}
    for _, n in ipairs(Npcs.list) do table.insert(near, { n = n, d = flat(State.hrp.Position - n.pos).Magnitude }) end
    table.sort(near, function(a, b) return a.d < b.d end)
    for i = 1, math.min(4, #near) do
        local n = near[i].n
        local mark = (st.target and n.model == st.target.model) and ">" or " "
        rows[i] = col(n.boss and UI.C.purple or UI.C.dim, string.format("%s %-16s %3.0f%% %4.0f  %s", mark, esc(n.model.Name):sub(1, 16), n.hp * 100, near[i].d,
            n.boss and "boss" or ("aggro " .. (n.aggro and string.format("%.0f", n.aggro) or "-"))))
    end
    r.npcs.Text = #rows > 0 and table.concat(rows, "\n") or col(UI.C.dim, "no npcs")

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

    local hitIn = Hazards.firstHit(State.hrp.Position, Config.HORIZON)
    if hitIn < math.huge then
        if hitIn > 0.05 then
            r.threat.Text = col(UI.C.red, string.format("<b>HIT IN</b>  %.1fs here", hitIn))
            setBar(r.threatBar, 1 - hitIn / Config.HORIZON, UI.C.red)
        else
            r.threat.Text = col(UI.C.red, "<b>INSIDE AN ATTACK</b>")
            setBar(r.threatBar, 1, UI.C.red)
        end
    elseif counts.soonest < math.huge and counts.soonest > 0 then
        r.threat.Text = col(UI.C.orange, string.format("precast fires in %.1fs (not here)", counts.soonest))
        setBar(r.threatBar, counts.soonest / Config.PRECAST_DELAY, UI.C.orange)
    else
        r.threat.Text = col(UI.C.green, "clear")
        setBar(r.threatBar, 0, UI.C.green)
    end
    local pad = Hazards.extraPad
    if pad > 0.05 then r.threat.Text = r.threat.Text .. col(UI.C.dim, string.format("  (+%.1f caution)", pad)) end
    if Hazards.shieldLeft > 0 then
        r.threat.Text = col(UI.C.purple, string.format("<b>SHIELD</b>  %.1fs of immortality", Hazards.shieldLeft))
        setBar(r.threatBar, Hazards.shieldLeft / Config.SPAWN_SHIELD, UI.C.purple)
    end

    -- a buff's cooldown starts at (buff time + cooldownLength): the part above cooldownLength is the BUFF
    if r.skillRows then
        for i, rr in ipairs(r.skillRows) do
            local sk = Skills.list[i]
            if sk then
                local live = sk.live
                if sk.kind == "ignore" then
                    rr.value.Text = col(UI.C.dim, "not used")
                    setBar(rr.bar, 0, UI.C.dim)
                elseif sk.kind == "buff" and live then
                    local left = math.max(sk.activeUntil - now, live.remaining - live.length)
                    skillRow(rr.value, rr.bar, live, left > 0.05 and left or nil, (live.extra >= 0.5) and live.extra or Config.RAGE_DURATION)
                else
                    skillRow(rr.value, rr.bar, live, nil, 1)
                    if live and (sk.kind == "attack" or sk.kind == "utility") then
                        rr.value.Text = rr.value.Text .. col(UI.C.dim, string.format("  reach %.0f", sk.reach))
                    end
                end
            end
        end
    end
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
--   something will hit where we stand (or an npc is on top of us)   -> DODGE   the planner finds the way out
--   npcs in the fight, but out of cast range                          -> APPROACH walk to the stand ring (avoiding other groups)
--   npcs in the fight, inside cast range                              -> FIGHT   hold still, move only when something is wrong
--   no npcs                                                           -> ADVANCE to the next room, or DONE when none is left
-- Skills are used every frame, whatever the movement is doing, as soon as an npc is inside its cast range.
-- =====================
Bot.stats = {}               -- what the UI and ESP show: target, centreDist, castRange, group, barrier, standRadius, slack
Bot.barriers = setmetatable({}, { __mode = "k" })   -- [npc model] = { centerDist, pos, expires, holdFire, misses }
Bot.approach = { model = nil, best = math.huge, progressT = 0, anchor = Vector3.zero, anchorT = 0 }
Bot.advance = { room = nil, best = math.huge, progressT = 0, anchorT = 0, anchor = Vector3.zero }
Bot.lastPlan = 0
Bot.lastPath = 0
Bot.lastUI = 0
Bot.lastError = 0
Bot.lastNoPath = 0
Bot.lastStep = nil
Bot.lastUnseen = 0
Bot.lastDetect = 0
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
    Hazards.shieldLeft = 0   -- (set again every frame while the shield lasts)
    Nav.stopPath()
    ESP.clearPath()
    ESP.setPlan(nil)
    Nav.stop()
    Nav.plan, Nav.pathGoal, Nav.lastPos, Nav.lastMove, Nav.computing = nil, nil, nil, clock(), false
    Skills.reset()   -- buffs are lost on death, cooldowns start over
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

-- Something hurt us. If the attacks we know about don't explain it (none near us, no npc within reach), it was something
-- we didn't see coming: pad every attack more for a while, and remember what appeared just before as suspects.
function Bot.onDamage(amount, pos)
    if amount < math.max(3, State.hum.MaxHealth * 0.03) then return end
    if Hazards.nearby(pos, 4) > 0 then return end                       -- an attack we know of was right there
    if Npcs.surfaceDistance(pos) < Config.MIN_DISTANCE + 4 then return end   -- an npc in melee range
    local suspects = Hazards.blame(pos)
    local now = clock()
    if now - Bot.lastUnseen > 1 then
        Bot.lastUnseen = now
        Log.add(string.format("Hit by something unseen (-%.0f)%s", amount, #suspects > 0 and (": " .. table.concat(suspects, ", "):sub(1, 60)) or ""))
    end
end

function Bot.onCharacter(char, initial)
    local born = clock()   -- the spawn shield counts from here, not from when the humanoid finished loading
    if not initial then
        State.shieldUntil = born + Config.SPAWN_SHIELD - Config.SHIELD_SAFETY
        State.spawnedAt, State.ffSeen = born, false
    end
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
        if not initial then Log.add(string.format("Spawn shield: %.1fs of immortality - all-in", math.max(0, State.shieldUntil - clock()))) end

        local lastHealth = hum.Health
        hum.HealthChanged:Connect(function(health)
            if health < lastHealth and State.enabled and clock() >= State.shieldUntil then
                pcall(Bot.onDamage, lastHealth - health, root.Position)
            end
            lastHealth = health
        end)

        hum.Died:Connect(function()
            if State.wasAlive then
                State.wasAlive = false
                State.deaths = State.deaths + 1
                Bot.reset("Died (" .. State.deaths .. " so far)")
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
    Hazards.shieldLeft = 0
    if State.wasEnabled then
        State.wasEnabled = false
        State.hum.AutoRotate = true
        Nav.ownsRotation = false
        Nav.stopPath()
        Nav.stop()
        ESP.clearPath()
        ESP.setPlan(nil)
        Nav.setControls(true)
        State.setMode("OFF")
    end
    Bot.refreshUI(now)
end

-- Seconds of spawn immortality left. A ForceField on the new character is the game's own marker for it: once that is
-- gone the shield is over, however much of our timer is left.
function Bot.shieldLeft(now)
    local left = State.shieldUntil - now
    if left <= 0 then return 0 end
    local ff = State.char and State.char:FindFirstChildOfClass("ForceField")
    if ff then
        State.ffSeen = true
    elseif State.ffSeen then
        State.shieldUntil = now
        Log.add("Spawn shield over (ForceField gone)")
        return 0
    end
    return left
end

-- ---- what makes a good place to stand ----

-- The cost (in "seconds of walking") of standing at `pos` because it lies inside the aggro range of an npc that is NOT
-- part of this fight: we would wake it up.
function Bot.pullCost(pos, group)
    if not Config.AVOID_OTHER_AGGRO then return 0 end
    local cost = 0
    local mine = {}
    for _, m in ipairs(group and group.members or {}) do mine[m.model] = true end
    for _, n in ipairs(Npcs.list) do
        if not mine[n.model] and n.aggro and flat(pos - n.pos).Magnitude < n.aggro then cost = cost + 2 end
    end
    return cost
end

-- Everything about a spot that isn't "can I get there safely": inside the cast range, not in front of an npc, not waking
-- another group. Returned as extra seconds-of-walking, so the planner can weigh it against the way there.
function Bot.penaltyFor(group, range, ring)
    local high = range * 0.95
    local area = (group and group.boss and group.room) and Dungeon.boundsOf(group.room) or nil   -- a boss wakes when we enter its area
    return function(pos)
        local pen = 0
        if area and not Dungeon.within(area, pos, -Config.BOSS_AREA_MARGIN) then pen = pen + 4 end
        local _, centre = Npcs.nearestCenter(pos, Npcs.pool)
        if centre > high then pen = pen + (centre - high) * 0.5 end
        if ring and centre < ring then pen = pen + (ring - centre) * 0.05 end   -- as far out as the skills allow is safest
        for _, n in ipairs(Npcs.pool) do   -- mild: not right in front of an npc
            local to = flat(pos - n.pos)
            local dist = to.Magnitude
            if dist < Config.FLANK_RANGE and dist > 0.01 then
                local facing = flat(n.root.CFrame.LookVector)
                if facing.Magnitude > 0.01 then
                    local dot = facing.Unit:Dot(to.Unit)
                    if dot > 0.3 then pen = pen + (dot - 0.3) * 0.4 end
                end
            end
        end
        return pen + Bot.pullCost(pos, group)
    end
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

-- ---- the things the bot can be doing ----

-- Something will hit us, or an npc is on top of us: ask the planner for the way out and walk it.
function Bot.dodgeStep(f)
    Nav.stopPath()
    ESP.clearPath()
    Nav.pathGoal = nil
    local me = State.hrp.Position

    if f.now - Bot.lastPlan >= Config.PLAN_RATE or not Nav.plan then
        Bot.lastPlan = f.now
        local function make(radius)
            return Planner.plan({ from = me, speed = f.speed, windows = f.wins, penalty = f.penalty, radius = radius })
        end
        local plan = make(Config.PLAN_RADIUS)
        if plan and not plan.safe then plan = make(Config.PLAN_RADIUS_MAX) or plan end   -- nothing safe near: look further
        -- the planner's steps were checked with a cheap ray; the first one gets the full body check
        local nextPoint = Nav.nextPoint(plan)
        if nextPoint and not Walls.moveClear(me, nextPoint) then
            Planner.blockStep(me, plan.path[2])
            plan = make(Config.PLAN_RADIUS) or plan
        end
        local goal = Nav.follow(plan)
        ESP.setPlan(plan and plan.path)
        ESP.setGoal(goal)
        Bot.stats.slack = plan and plan.slack or nil
        State.setMode(f.threatened and ((plan and plan.safe) and "DODGE" or "FLEE") or "REPOSITION")
    end
end

-- outside the cast range: pathfind to the stand ring
function Bot.approachStep(f)
    State.setMode("APPROACH")
    Nav.plan = nil
    ESP.setPlan(nil)
    ESP.setGoal(nil)
    if f.target then Bot.watchBarrier(f.target, f.centre, f.now) end

    if f.now - Bot.lastPath >= Config.REPATH_RATE and not Nav.computing and f.group then
        Bot.lastPath = f.now
        local points, ringR = Nav.ringPoints(f.group, f.barrier)
        Bot.stats.standRadius = ringR

        local needPath = not Nav.pathing
        if not Nav.pathGoal or Npcs.surfaceDistance(Nav.pathGoal) < Config.MIN_DISTANCE + 1
            or (not f.barrier and math.abs(flat(Nav.pathGoal - f.group.centroid).Magnitude - ringR) > 4) then
            needPath = true
        else
            -- an attack appeared over where we are heading: choose again
            local walk = flat(Nav.pathGoal - State.hrp.Position).Magnitude / f.speed
            if Hazards.hitWin(f.wins, Nav.pathGoal, walk, walk + Config.SETTLE + 1) then needPath = true end
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

-- inside the cast range and nothing threatening: stay put; move only when something is wrong with where we are
function Bot.fightStep(f)
    Nav.stopPath()
    ESP.clearPath()
    Nav.pathGoal = nil
    local me = State.hrp.Position
    State.setMode(f.shielded and "ALL-IN" or (f.atBarrier and "SIEGE" or "FIGHT"))

    local pull = Bot.pullCost(me, f.group)
    local area = (f.group and f.group.boss and not f.barrier and f.group.room) and Dungeon.boundsOf(f.group.room) or nil
    local outside = area ~= nil and not Dungeon.within(area, me, -Config.BOSS_AREA_MARGIN)
    local tooNear = f.ring ~= nil and not f.barrier and f.centre < f.ring - Config.BACKOFF   -- closer than needed (the reach was shrunk, then grew back)
    local needMove = f.centre > f.range * 0.95 or f.surface < Config.MIN_DISTANCE + 2 or pull > 0 or outside or tooNear
    if not needMove then
        Nav.plan = nil
        Nav.stop()
        ESP.setPlan(nil)
        ESP.setGoal(nil)
        return
    end

    if f.now - Bot.lastPlan >= 0.5 or not Nav.goal then   -- (no need to re-plan a short walk ten times a second)
        Bot.lastPlan = f.now
        local plan = Planner.plan({ from = me, speed = f.speed, windows = f.wins, penalty = f.penalty, radius = Config.PLAN_RADIUS })
        local goal = Nav.follow(plan)
        local nextPoint = Nav.nextPoint(plan)
        if nextPoint and not Walls.moveClear(me, nextPoint) then
            Planner.blockStep(me, plan.path[2])
            Nav.stop()
        end
        ESP.setPlan(plan and plan.path)
        ESP.setGoal(goal)
        if plan and #plan.path >= 2 then State.setMode("REPOSITION") end
    end
end

-- no npcs in the fight: head for the next room, or finish
function Bot.advanceStep(f)
    Nav.aim = nil
    local room = Dungeon.next(f.now)
    Bot.stats.target, Bot.stats.group, Bot.stats.barrier = nil, nil, nil

    if not room then
        Nav.stopPath()
        Nav.stop()
        ESP.clearPath()
        ESP.setGoal(nil)
        State.setMode(Dungeon.finished and "DONE" or "IDLE")
        return
    end

    local goal = Dungeon.goal(room)
    local me = State.hrp.Position
    if not goal then   -- a room with no parts to aim for
        Dungeon.blocked[room.room] = f.now + Config.ADVANCE_RETRY
        return
    end
    State.setMode("ADVANCE")
    ESP.setGoal(goal)

    if flat(me - goal).Magnitude <= Config.ROOM_ARRIVE then   -- arrived: wait for its npcs to appear (Dungeon marks it empty if not)
        Nav.stopPath()
        Nav.stop()
        return
    end

    -- not getting anywhere for a long time: give this room up for a while
    local a = Bot.advance
    if a.room ~= room.room then
        a.room, a.best, a.progressT, a.anchor, a.anchorT = room.room, math.huge, f.now, me, f.now
    end
    local dist = flat(me - goal).Magnitude
    if dist < a.best - Config.BARRIER_PROGRESS then a.best, a.progressT = dist, f.now end
    if f.now - a.progressT >= Config.BARRIER_NO_PROGRESS then
        Dungeon.blocked[room.room] = f.now + Config.ADVANCE_RETRY
        Log.add("Can't reach " .. room.name .. ", trying again later")
        Nav.stopPath()
        a.room = nil
        return
    end

    if f.now - Bot.lastPath >= Config.REPATH_RATE and not Nav.computing then
        Bot.lastPath = f.now
        if not Nav.pathing or not Nav.pathGoal or flat(Nav.pathGoal - goal).Magnitude > 6 then
            Nav.computing = true
            if not Nav.pathTo(goal) and State.alive() and not Nav.interrupted() then
                Nav.setGoal(goal)   -- no navmesh path: walk straight
            end
            Nav.computing = false
        end
    end
    if Nav.pathing and Nav.stuck() then
        local dir = Nav.goal and flat(Nav.goal - me)
        if not dir or dir.Magnitude < 0.01 then dir = flat(State.hrp.CFrame.LookVector) end
        Nav.setGoal(me + dir.Unit * 5)
        Bot.lastPath = 0
    end
end

function Bot.step()
    if not Bot.refreshChar() then return end
    local now = clock()
    local dt = Bot.lastStep and math.min(now - Bot.lastStep, 0.5) or 0
    Bot.lastStep = now
    Walls.refresh(now)
    if not State.enabled then
        Bot.idle(now)
        return
    end
    State.wasEnabled = true

    Hazards.update(now)
    Hazards.scan(now)
    Npcs.refresh(0)
    local me = State.hrp.Position
    Dungeon.refresh(now, me)
    Npcs.pool = Dungeon.pool(Npcs.list, me)
    Npcs.buildGroups()
    Skills.watch(now)
    local hpFrac = State.hum.MaxHealth > 0 and State.hum.Health / State.hum.MaxHealth or 1
    Hazards.setCaution(hpFrac, dt)
    -- the backpack can fill in after the character appears: look again often right after a spawn
    if now - Bot.lastDetect >= ((now - State.spawnedAt < 8) and 0.25 or 3) then
        Bot.lastDetect = now
        Skills.detect()
    end

    local stats = Bot.stats
    local pool = Npcs.pool
    local nearest, surface = Npcs.nearest(me, pool)
    local target = Npcs.pick(nearest, surface, me)
    local inPool = {}
    for _, n in ipairs(pool) do inPool[n.model] = true end
    stats.inPool = inPool

    -- Spawn immortality: attacks that end before it does can't hurt us and the rest only count from when it ends (see
    -- Hazards.windows) - so the bot walks straight through everything, attacks, and is clear of the zones as it runs out.
    local shieldLeft = Bot.shieldLeft(now)
    local shielded = shieldLeft > 0
    Hazards.shieldLeft = shieldLeft
    local wins = Hazards.windows(now)
    local hitIn = Hazards.firstHitWin(wins, me, Config.HORIZON)
    local threatened = hitIn < math.huge
    local anyNpc, anySurface = Npcs.nearest(me, Npcs.list)
    local tooClose = shieldLeft < Config.SHIELD_TAIL and anyNpc ~= nil and anySurface < Config.MIN_DISTANCE
    local speed = math.max(State.hum.WalkSpeed, 8)

    if not target then
        stats.target, stats.group, stats.barrier, stats.slack = nil, nil, nil, nil
        if threatened or tooClose then
            Bot.dodgeStep({ now = now, wins = wins, speed = speed, threatened = threatened, penalty = function() return 0 end })
        else
            ESP.setPlan(nil)
            Bot.advanceStep({ now = now })
        end
        Skills.update({ now = now, threatened = threatened, slack = Bot.stats.slack, shielded = shielded, hpFrac = hpFrac })
        ESP.update(now, stats)
        Bot.refreshUI(now)
        return
    end

    local group = Npcs.groups[target.group]
    local reachNpc, centre = Npcs.nearestCenter(me, Npcs.list)   -- skills reach by distance to an npc's centre
    local targetCentre = flat(me - target.pos).Magnitude
    local barrier = Bot.barrierOf(target, targetCentre, now)
    local atBarrier = barrier ~= nil and targetCentre <= barrier.centerDist + Config.BARRIER_LEEWAY
    local castRange = Npcs.castRange(reachNpc, barrier)
    local groupRange = Npcs.groupRange(group, barrier)

    stats.target, stats.group, stats.barrier = target, group, barrier
    stats.centreDist = targetCentre
    stats.castRange = (Npcs.castRange(target, barrier))
    local ring = group and Nav.ringRadius(group, barrier) or nil
    stats.standRadius = ring
    if not threatened then stats.slack = nil end

    local f = {
        now = now, target = target, group = group, barrier = barrier, atBarrier = atBarrier,
        centre = centre, surface = surface, range = groupRange, speed = speed, wins = wins,
        threatened = threatened, tooClose = tooClose, shielded = shielded,
        penalty = Bot.penaltyFor(group, groupRange, ring), ring = ring,
    }

    if threatened or tooClose then
        Bot.dodgeStep(f)
    elseif Nav.aheadBlocked() then   -- an attack lies across the way we're walking: wait for it instead of walking in
        State.setMode("AVOID")
        Nav.stopPath()
        Nav.stop()
        ESP.clearPath()
    elseif centre > groupRange then
        Bot.approachStep(f)
    else
        Bot.fightStep(f)
    end

    -- skills get their turn every frame (the attack aims itself when it fires)
    Nav.aim = group and ((group.count >= 2) and group.centroid or target.pos) or nil
    Skills.update({
        now = now, npc = reachNpc, centreDist = centre, barrier = barrier, threatened = threatened, slack = stats.slack,
        shielded = shielded, hpFrac = hpFrac, approaching = centre > castRange, travel = centre - castRange,
    })

    ESP.update(now, stats)
    Bot.refreshUI(now)
end

-- ---- a report of what the bot sees ----

-- For working out why it misbehaves (a boss it can't attack, a skill it ignores): everything it knows about the npcs, rooms,
-- skills and attacks, print()ed to the console (F9 / the executor's output) and returned. Run it from the Dump button or
-- getgenv().__AutoCombat.api.Bot.dump().
local function describeModel(model)
    local parts = {}
    for _, c in ipairs(model:GetChildren()) do
        local text = c.Name .. ":" .. c.ClassName
        if c:IsA("ValueBase") then text = text .. "=" .. tostring(c.Value) end
        table.insert(parts, text)
        if #parts >= 14 then
            table.insert(parts, "...")
            break
        end
    end
    local ok, attrs = pcall(function() return model:GetAttributes() end)
    if ok and type(attrs) == "table" then
        for k, v in pairs(attrs) do table.insert(parts, "@" .. tostring(k) .. "=" .. tostring(v)) end
    end
    return table.concat(parts, ", ")
end

function Bot.dump()
    local out = {}
    local function add(fmt, ...) table.insert(out, string.format(fmt, ...)) end
    local now = clock()
    local me = State.hrp and State.hrp.Position

    add("=== AutoCombat report ===")
    add("mode %s | enabled %s | kills %d | deaths %d | shield %.1fs | caution +%.1f", State.mode, tostring(State.enabled), State.kills, State.deaths, Hazards.shieldLeft, Hazards.extraPad)
    if me then add("position %.0f, %.0f, %.0f | walkspeed %.0f | health %.0f/%.0f", me.X, me.Y, me.Z, State.hum.WalkSpeed, State.hum.Health, State.hum.MaxHealth) end

    add("--- skills (stand reach %.0f) ---", Skills.reach)
    for _, sk in ipairs(Skills.list) do
        local live = sk.live
        add("%-22s %-8s reach %3.0f  casts %d hits %d  %s", sk.name, sk.kind, sk.reach, sk.casts, sk.hits,
            live and (live.ready and "READY" or string.format("%.1fs / %.0fs", live.remaining, live.length)) or "not carried")
    end

    add("--- rooms ---")
    for _, r in ipairs(Dungeon.rooms) do
        local b = Dungeon.boundsOf(r.room)
        add("%-14s alive %d  %s  %s", r.name, r.alive, Dungeon.cleared[r.room] and "cleared" or "pending",
            b and string.format("area %.0f x %.0f at (%.0f, %.0f)", b.max.X - b.min.X, b.max.Z - b.min.Z, b.center.X, b.center.Z) or "no parts")
    end

    add("--- npcs (%d) ---", #Npcs.list)
    for _, n in ipairs(Npcs.list) do
        add("%s%s | room %s | width %.0f (radius %.0f) | aggro %s | attackSpeed %s | hp %.0f%% | %s | root %s (%s)",
            n.boss and "[BOSS] " or "", n.model.Name, n.room.Name, n.width or 0, n.radius, n.aggro and string.format("%.0f", n.aggro) or "-",
            n.attackSpeed and string.format("%.1f", n.attackSpeed) or "-", n.hp * 100,
            me and string.format("%.0f studs", flat(me - n.pos).Magnitude) or "?", n.root.Name, n.root.ClassName)
        add("    %s", describeModel(n.model))
    end

    add("--- attacks (%d) ---", (function() local k = 0 for _ in pairs(Hazards.active) do k = k + 1 end return k end)())
    for obj, zone in pairs(Hazards.active) do
        add("%-8s %s | age %.1fs | size %.0f x %.0f", zone.kind, obj.Name, now - zone.born, zone.size.X, zone.size.Z)
    end
    local learned = {}
    for name in pairs(Hazards.learned) do table.insert(learned, name) end
    if #learned > 0 then add("learned this run: %s", table.concat(learned, ", ")) end

    local text = table.concat(out, "\n")
    print(text)
    Log.add("Report printed to the console")
    return text
end

-- ---- startup / shutdown ----

function Bot.start()
    print("[AutoCombat] starting...")
    State.startedAt = clock()
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

API.Config, API.State, API.Log, API.Npcs, API.Dungeon, API.Hazards, API.Walls = Config, State, Log, Npcs, Dungeon, Hazards, Walls
API.Planner, API.Nav, API.Skills, API.ESP, API.UI, API.Bot = Planner, Nav, Skills, ESP, UI, Bot

Bot.boot()

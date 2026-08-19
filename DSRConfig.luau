--!strict
-- DON'T STOP RIDING :: shared tuning + procedural section library
local C = {}

------------------------------------------------------------------ tuning
C.SECTION_LENGTH   = 140
C.ROAD_HALF        = 22
C.RIDE_HEIGHT      = 6.0
C.GRAVITY          = 190
C.JUMP_VELOCITY    = 72
C.BASE_SPEED       = 68
C.TIER_SPEED       = 20     -- speed gained per momentum tier
C.MAX_TIER         = 5
C.STEER_SPEED      = 44
C.STEER_SPEED_ICE  = 17
C.STEER_ACCEL      = 9
C.MOM_PER_TIER     = 100
C.MOM_NEARMISS     = 18
C.MOM_AIR_PER_SEC  = 70
C.MOM_DECAY        = 7      -- passive drain per second
C.MOM_CLEAN_PER_SEC = 13    -- gain while riding clean (net +6/s vs decay)
C.MOM_BOOSTPAD     = 90
C.HIT_STUN         = 0.55
C.LATERAL_LIMIT    = 70
C.KILL_Y           = -55
C.GROUND_PROBE     = 46
C.ROUND_TIME       = 170
C.INTERMISSION     = 9
C.START_SECTIONS   = 70
C.EXTEND_CHUNK     = 12

C.SECTIONS_PER_BIOME = 7
C.COLLAPSE_SECTION   = 22    -- collapse mode begins around here
C.COLLAPSE_WARN      = 1.15  -- seconds of warning before a slab drops
C.COLLAPSE_NEAR      = 260   -- how close a rider must be to arm a slab

-- Visual identity per biome. Kept to palette + lighting so scenery stays modular
-- and we never blow the part budget.
C.BIOMES = {
	{ name = "GREEN VALLEY", road = Color3.fromRGB(58, 74, 62),  edge = Color3.fromRGB(150, 255, 170),
	  fog = Color3.fromRGB(120, 165, 130), ambient = Color3.fromRGB(70, 85, 70),  clock = 14.2, fogEnd = 2600 },
	{ name = "DESERT",       road = Color3.fromRGB(96, 78, 52),  edge = Color3.fromRGB(255, 210, 120),
	  fog = Color3.fromRGB(210, 175, 120), ambient = Color3.fromRGB(105, 90, 65), clock = 16.5, fogEnd = 2400 },
	{ name = "VOLCANO",      road = Color3.fromRGB(52, 38, 38),  edge = Color3.fromRGB(255, 130, 60),
	  fog = Color3.fromRGB(120, 55, 40),  ambient = Color3.fromRGB(85, 45, 40),  clock = 18.4, fogEnd = 1700 },
	{ name = "ICE",          road = Color3.fromRGB(78, 100, 118), edge = Color3.fromRGB(180, 240, 255),
	  fog = Color3.fromRGB(175, 210, 235), ambient = Color3.fromRGB(85, 105, 125), clock = 13.0, fogEnd = 2200 },
	{ name = "CYBER CITY",   road = Color3.fromRGB(38, 40, 58),  edge = Color3.fromRGB(120, 240, 255),
	  fog = Color3.fromRGB(45, 40, 80),   ambient = Color3.fromRGB(55, 55, 90),  clock = 22.0, fogEnd = 1900 },
	{ name = "SPACE",        road = Color3.fromRGB(26, 26, 40),  edge = Color3.fromRGB(190, 160, 255),
	  fog = Color3.fromRGB(12, 10, 26),   ambient = Color3.fromRGB(40, 35, 65),  clock = 0.2,  fogEnd = 1800 },
	{ name = "COLLAPSE",     road = Color3.fromRGB(60, 26, 26),  edge = Color3.fromRGB(255, 70, 70),
	  fog = Color3.fromRGB(90, 20, 20),   ambient = Color3.fromRGB(80, 35, 35),  clock = 17.5, fogEnd = 1300 },
}

function C.biomeFor(index: number): number
	return math.clamp(math.floor((index - 1) / C.SECTIONS_PER_BIOME) + 1, 1, #C.BIOMES)
end

-- Bike collection. Purely cosmetic by design: identical handling across every
-- bike, so coins never buy an advantage. Order here is display order.
C.BIKES = {
	{ id = "starter",  name = "STARTER BIKE",  price = 0,
	  frame = Color3.fromRGB(255, 90, 120),  rim = Color3.fromRGB(120, 240, 255), trail = Color3.fromRGB(255, 120, 140) },
	{ id = "city",     name = "CITY BIKE",     price = 750,
	  frame = Color3.fromRGB(90, 190, 255),  rim = Color3.fromRGB(220, 240, 255), trail = Color3.fromRGB(120, 200, 255) },
	{ id = "bmx",      name = "BMX",           price = 2000,
	  frame = Color3.fromRGB(255, 170, 60),  rim = Color3.fromRGB(60, 60, 70),    trail = Color3.fromRGB(255, 190, 90) },
	{ id = "mountain", name = "MOUNTAIN BIKE", price = 4500,
	  frame = Color3.fromRGB(110, 220, 130), rim = Color3.fromRGB(200, 255, 200),  trail = Color3.fromRGB(140, 255, 160) },
	{ id = "racing",   name = "RACING BIKE",   price = 9000,
	  frame = Color3.fromRGB(240, 240, 250), rim = Color3.fromRGB(255, 80, 80),    trail = Color3.fromRGB(255, 255, 255) },
	{ id = "neon",     name = "NEON BIKE",     price = 18000,
	  frame = Color3.fromRGB(180, 90, 255),  rim = Color3.fromRGB(120, 255, 230),  trail = Color3.fromRGB(200, 120, 255) },
	{ id = "void",     name = "VOID BIKE",     price = 40000,
	  frame = Color3.fromRGB(35, 30, 55),    rim = Color3.fromRGB(150, 90, 255),   trail = Color3.fromRGB(90, 40, 160) },
	{ id = "phantom",  name = "PHANTOM BIKE",  price = 12000, event = "night_ride",
	  frame = Color3.fromRGB(120, 130, 190), rim = Color3.fromRGB(210, 220, 255),  trail = Color3.fromRGB(180, 195, 255) },
	{ id = "golden",   name = "GOLDEN BIKE",   price = 90000,
	  frame = Color3.fromRGB(255, 205, 70),  rim = Color3.fromRGB(255, 240, 170),  trail = Color3.fromRGB(255, 220, 120) },
}

C.BIKE_BY_ID = {}
for _, b in ipairs(C.BIKES) do
	C.BIKE_BY_ID[b.id] = b
end

function C.getBike(id: string?)
	return C.BIKE_BY_ID[id or "starter"] or C.BIKES[1]
end

-- Challenges. Every metric here is derivable on the SERVER (distance comes from
-- replicated position, time from the round clock, runs from crash events), so
-- the challenge system adds no new surface a client could lie about.
--   stat keys: dayDistance | bestRun | runs | bestTime | collapse
C.DAILY = {
	{ id = "d_dist",     text = "Ride 2,000m today",        stat = "dayDistance", target = 2000, reward = 250 },
	{ id = "d_single",   text = "Reach 800m in one ride",   stat = "bestRun",     target = 800,  reward = 200 },
	{ id = "d_runs",     text = "Complete 5 rides",         stat = "runs",        target = 5,    reward = 150 },
	{ id = "d_survive",  text = "Survive 60s in one ride",  stat = "bestTime",    target = 60,   reward = 300 },
}

C.WEEKLY = {
	{ id = "w_dist",     text = "Ride 20,000m this week",   stat = "dayDistance", target = 20000, reward = 1500 },
	{ id = "w_single",   text = "Reach 2,500m in one ride", stat = "bestRun",     target = 2500,  reward = 1200 },
	{ id = "w_runs",     text = "Complete 40 rides",        stat = "runs",        target = 40,    reward = 1000 },
	{ id = "w_collapse", text = "Reach COLLAPSE MODE",      stat = "collapse",    target = 1,     reward = 2000 },
}

function C.dayIndex(): number
	return math.floor(os.time() / 86400)
end

function C.weekIndex(): number
	return math.floor(os.time() / 604800)
end

-- Trails: a second cosmetic slot, independent of the bike.
-- `event` items can only be bought while their event is running, but once
-- owned they are kept forever (spec: never delete unlocked items).
C.TRAILS = {
	{ id = "t_stock",   name = "STOCK TRAIL",   price = 0,     color = Color3.fromRGB(255, 150, 80) },
	{ id = "t_ember",   name = "EMBER",         price = 600,   color = Color3.fromRGB(255, 110, 40) },
	{ id = "t_frost",   name = "FROST",         price = 1400,  color = Color3.fromRGB(150, 230, 255) },
	{ id = "t_toxic",   name = "TOXIC",         price = 3000,  color = Color3.fromRGB(150, 255, 90) },
	{ id = "t_plasma",  name = "PLASMA",        price = 7000,  color = Color3.fromRGB(200, 110, 255) },
	{ id = "t_gold",    name = "GOLD RUSH",     price = 20000, color = Color3.fromRGB(255, 215, 90) },
	{ id = "t_moon",    name = "MOON TRAIL",    price = 2500,  color = Color3.fromRGB(190, 205, 255), event = "night_ride" },
}

C.TRAIL_BY_ID = {}
for _, t in ipairs(C.TRAILS) do
	C.TRAIL_BY_ID[t.id] = t
end

function C.getTrail(id: string?)
	return C.TRAIL_BY_ID[id or "t_stock"] or C.TRAILS[1]
end

-- Limited event. Runs for EVENT.days from EVENT.startUnix.
C.EVENT = {
	id = "night_ride",
	name = "NIGHT RIDE",
	blurb = "Limited: Phantom Bike + Moon Trail",
	startUnix = 1786147200,   -- 2026-08-08 00:00 UTC
	days = 7,
}

function C.eventActive(): boolean
	-- Studio-only QA override so the "event ended" path can be tested without
	-- waiting a week. Inert in a live game.
	if game:GetService("RunService"):IsStudio()
		and workspace:GetAttribute("DSR_FORCE_EVENT_OFF") == true then
		return false
	end
	local now = os.time()
	return now >= C.EVENT.startUnix and now < C.EVENT.startUnix + C.EVENT.days * 86400
end

function C.eventSecondsLeft(): number
	return math.max(0, (C.EVENT.startUnix + C.EVENT.days * 86400) - os.time())
end

-- Rider level: a permanent number that only ever goes up, derived from data we
-- already store (totalDistance). Purely cosmetic -- it must never touch speed,
-- handling or rewards, or it becomes pay-to-win the moment coins buy distance.
-- Square-root curve so early levels come fast and later ones stay meaningful.
function C.riderLevel(totalDistance: number?): number
	local d = math.max(0, totalDistance or 0)
	return math.floor(math.sqrt(d / 800)) + 1
end

-- distance still needed to reach the next level (for a progress readout)
function C.riderLevelProgress(totalDistance: number?): (number, number)
	local d = math.max(0, totalDistance or 0)
	local lv = C.riderLevel(d)
	local cur = (lv - 1) ^ 2 * 800
	local nxt = lv ^ 2 * 800
	return d - cur, nxt - cur
end

C.TIER_NAMES = {"WARMING UP","ROLLING","FAST","BLAZING","INSANE","MAX MOMENTUM"}
C.TIER_COLORS = {
	Color3.fromRGB(150,170,190),
	Color3.fromRGB(120,220,255),
	Color3.fromRGB(120,255,190),
	Color3.fromRGB(255,220,110),
	Color3.fromRGB(255,150,80),
	Color3.fromRGB(255,90,120),
}

------------------------------------------------------------------ helpers
local function mk(class, props, parent)
	local p = Instance.new(class)
	for k, v in pairs(props) do
		(p :: any)[k] = v
	end
	p.Parent = parent
	return p
end
C.mk = mk

local ROAD_A = Color3.fromRGB(38, 41, 52)
local ROAD_B = Color3.fromRGB(38, 42, 55)
local EDGE   = Color3.fromRGB(120, 240, 255)

-- a slab of road. z-centred, top surface at y.
local function road(g, x0, len, halfW, y, kind, z)
	z = z or 0
	local p = mk("Part", {
		Anchored = true, CanCollide = false, CanTouch = false,
		Size = Vector3.new(len, 2, halfW * 2),
		CFrame = CFrame.new(x0 + len / 2, (y or 0) - 1, z),
		Color = (kind == "ice") and Color3.fromRGB(170, 225, 245) or ROAD_A,
		Material = (kind == "ice") and Enum.Material.Ice or Enum.Material.Metal,
		TopSurface = Enum.SurfaceType.Smooth, BottomSurface = Enum.SurfaceType.Smooth,
	}, g)
	p:SetAttribute("DSR", kind or "ground")
	return p
end
C.road = road

local function edgeLines(g, x0, len, halfW, y, z)
	z = z or 0
	-- cleaner road read: raised kerb + glowing edge + centre dashes.
	-- Speed is hard to judge on a featureless slab; the dashes fix that.
	local wantKerb = len >= 12
	for _, s in ipairs({ -1, 1 }) do
		if wantKerb then
		mk("Part", {
			Anchored = true, CanCollide = false, CanTouch = false, CanQuery = false,
			Size = Vector3.new(len, 0.7, 1.6),
			CFrame = CFrame.new(x0 + len / 2, (y or 0) - 0.1, z + s * (halfW - 0.8)),
			Color = Color3.fromRGB(58, 62, 76), Material = Enum.Material.Metal,
		}, g)
		end
		mk("Part", {
			Anchored = true, CanCollide = false, CanTouch = false, CanQuery = false,
			Size = Vector3.new(len, 0.25, 0.8),
			CFrame = CFrame.new(x0 + len / 2, (y or 0) + 0.28, z + s * (halfW - 0.8)),
			Color = EDGE, Material = Enum.Material.Neon,
		}, g)
	end
	-- dashes are decoration: only worth placing on slabs long enough to read,
	-- and spaced widely. Previously every fragment got at least one, which cost
	-- 583 parts across a 70-section track (43% of the entire budget).
	local dashes = (len >= 24) and math.floor(len / 26) or 0
	for i = 0, dashes - 1 do
		mk("Part", {
			Anchored = true, CanCollide = false, CanTouch = false, CanQuery = false,
			Size = Vector3.new(6, 0.12, 0.9),
			CFrame = CFrame.new(x0 + 13 + i * 26, (y or 0) + 0.08, z),
			Color = Color3.fromRGB(210, 215, 230), Material = Enum.Material.SmoothPlastic,
			Transparency = 0.25,
		}, g)
	end
end

local function hazard(h, props, kind, tag)
	local p = mk("Part", props, h)
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p:SetAttribute("DSR", kind)
	if tag then p:SetAttribute("Mover", tag) end
	return p
end

local PILLAR = Color3.fromRGB(255, 96, 92)
local ROCK   = Color3.fromRGB(122, 110, 100)

------------------------------------------------------------------ sections
-- each: band = {min,max} difficulty 1..3 ; build(ground, hazards, x0, rng)
local S = {}
C.Sections = S

S.straight = { band = {1,3}, build = function(g, h, x0, rng)
	local L = C.SECTION_LENGTH
	road(g, x0, L, C.ROAD_HALF, 0)
	edgeLines(g, x0, L, C.ROAD_HALF, 0)
	return L
end }

S.pillars = { band = {1,3}, build = function(g, h, x0, rng)
	local L = C.SECTION_LENGTH
	road(g, x0, L, C.ROAD_HALF, 0)
	edgeLines(g, x0, L, C.ROAD_HALF, 0)
	for i = 1, 4 do
		local x = x0 + 18 + (i - 1) * 30 + rng:NextNumber(-6, 6)
		local z = rng:NextNumber(-C.ROAD_HALF + 5, C.ROAD_HALF - 5)
		hazard(h, {
			Size = Vector3.new(5, 16, 5),
			CFrame = CFrame.new(x, 8, z),
			Color = PILLAR, Material = Enum.Material.Neon, Transparency = 0.15,
		}, "obstacle")
	end
	return L
end }

S.barriers = { band = {1,3}, build = function(g, h, x0, rng)
	local L = C.SECTION_LENGTH
	road(g, x0, L, C.ROAD_HALF, 0)
	edgeLines(g, x0, L, C.ROAD_HALF, 0)
	for i = 1, 3 do
		local x = x0 + 25 + (i - 1) * 42
		local p = hazard(h, {
			Size = Vector3.new(4, 10, 20),
			CFrame = CFrame.new(x, 5, 0),
			Color = Color3.fromRGB(255, 170, 60), Material = Enum.Material.Neon, Transparency = 0.1,
		}, "obstacle", "slide")
		p:SetAttribute("Amp", C.ROAD_HALF - 10)
		p:SetAttribute("Speed", rng:NextNumber(0.7, 1.4))
		p:SetAttribute("Phase", rng:NextNumber(0, 6.28))
		p:SetAttribute("BaseX", x)
	end
	return L
end }

S.gaps = { band = {1,3}, build = function(g, h, x0, rng, diff)
	local L = C.SECTION_LENGTH
	diff = diff or 1
	-- Gap width must scale with the speed players actually carry at this
	-- difficulty. Jump distance is hangTime * speed, which runs 52 studs at
	-- tier 0 up to 127 at tier 5 -- so a fixed 20-30 stud gap means momentum
	-- makes the game EASIER, inverting the difficulty curve. Widths below are
	-- set so the gap is clearable at the LOWEST speed plausible for the band.
	local lo, hi, n
	if diff <= 1 then
		lo, hi, n = 20, 30, rng:NextInteger(2, 3)   -- tier 0-1: jump 52-67
	elseif diff == 2 then
		lo, hi, n = 32, 44, 2                        -- tier 1-3: jump 67-97
	else
		lo, hi, n = 48, 68, 1                        -- tier 2-5: jump 82-127
	end
	local seg = L / n
	local x = x0
	for i = 1, n do
		local gapW = math.min(rng:NextNumber(lo, hi), seg - 28)
		local solid = seg - gapW
		road(g, x, solid, C.ROAD_HALF, 0)
		edgeLines(g, x, solid, C.ROAD_HALF, 0)
		x += seg
	end
	return L
end }

S.bridge = { band = {1,3}, build = function(g, h, x0, rng)
	local L = C.SECTION_LENGTH
	local z = rng:NextNumber(-8, 8)
	road(g, x0, 26, C.ROAD_HALF, 0)
	road(g, x0 + 26, L - 52, 6, 0, "ground", z)
	road(g, x0 + L - 26, 26, C.ROAD_HALF, 0)
	edgeLines(g, x0 + 26, L - 52, 6, 0, z)
	return L
end }

S.ramp = { band = {1,3}, build = function(g, h, x0, rng)
	local L = C.SECTION_LENGTH
	road(g, x0, 34, C.ROAD_HALF, 0)
	edgeLines(g, x0, 34, C.ROAD_HALF, 0)
	-- sloped launcher
	local rampLen, rise = 40, 13
	local ang = math.atan2(rise, rampLen)
	local hyp = math.sqrt(rampLen ^ 2 + rise ^ 2)
	local p = mk("Part", {
		Anchored = true, CanCollide = false, CanTouch = false,
		Size = Vector3.new(hyp, 2, C.ROAD_HALF * 2),
		CFrame = CFrame.new(x0 + 34 + rampLen / 2, rise / 2 - 1, 0) * CFrame.Angles(0, 0, ang),
		Color = Color3.fromRGB(90, 200, 255), Material = Enum.Material.Metal,
	}, g)
	p:SetAttribute("DSR", "ground")
	-- landing pad after air time
	road(g, x0 + 34 + rampLen + 40, L - (34 + rampLen + 40), C.ROAD_HALF, 0)
	edgeLines(g, x0 + 34 + rampLen + 40, L - (34 + rampLen + 40), C.ROAD_HALF, 0)
	return L
end }

S.boost = { band = {1,3}, build = function(g, h, x0, rng)
	local L = C.SECTION_LENGTH
	road(g, x0, L, C.ROAD_HALF, 0)
	edgeLines(g, x0, L, C.ROAD_HALF, 0)
	for i = 1, 3 do
		local x = x0 + 25 + (i - 1) * 45
		local z = rng:NextNumber(-12, 12)
		local p = mk("Part", {
			Anchored = true, CanCollide = false, CanTouch = false,
			Size = Vector3.new(16, 0.6, 12),
			CFrame = CFrame.new(x, 0.2, z),
			Color = Color3.fromRGB(120, 255, 170), Material = Enum.Material.Neon,
		}, h)
		p:SetAttribute("DSR", "boost")
	end
	return L
end }

S.rocks = { band = {2,3}, build = function(g, h, x0, rng)
	local L = C.SECTION_LENGTH
	road(g, x0, L, C.ROAD_HALF, 0)
	edgeLines(g, x0, L, C.ROAD_HALF, 0)
	for i = 1, 5 do
		local x = x0 + 16 + (i - 1) * 26
		local z = rng:NextNumber(-C.ROAD_HALF + 6, C.ROAD_HALF - 6)
		local p = hazard(h, {
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(9, 9, 9),
			CFrame = CFrame.new(x, 40, z),
			Color = ROCK, Material = Enum.Material.Slate,
		}, "obstacle", "fall")
		p:SetAttribute("Speed", rng:NextNumber(0.5, 0.9))
		p:SetAttribute("Phase", rng:NextNumber(0, 6.28))
		p:SetAttribute("BaseZ", z)
		p:SetAttribute("BaseX", x)
	end
	return L
end }

S.rotors = { band = {2,3}, build = function(g, h, x0, rng)
	local L = C.SECTION_LENGTH
	road(g, x0, L, C.ROAD_HALF, 0)
	edgeLines(g, x0, L, C.ROAD_HALF, 0)
	for i = 1, 3 do
		local x = x0 + 28 + (i - 1) * 42
		mk("Part", {
			Anchored = true, CanCollide = false, CanTouch = false, CanQuery = false,
			Size = Vector3.new(2, 14, 2), CFrame = CFrame.new(x, 7, 0),
			Color = Color3.fromRGB(60, 70, 90), Material = Enum.Material.Metal,
		}, g)
		local p = hazard(h, {
			Size = Vector3.new(3, 4, C.ROAD_HALF * 1.7),
			CFrame = CFrame.new(x, 4.5, 0),
			Color = Color3.fromRGB(255, 96, 92), Material = Enum.Material.Neon, Transparency = 0.1,
		}, "obstacle", "spin")
		p:SetAttribute("Speed", rng:NextNumber(1.1, 2.2) * (rng:NextInteger(0, 1) == 0 and -1 or 1))
		p:SetAttribute("Phase", rng:NextNumber(0, 6.28))
		p:SetAttribute("BaseX", x)
	end
	return L
end }

S.lava = { band = {1,3}, build = function(g, h, x0, rng, diff)
	local L = C.SECTION_LENGTH
	-- glowing pit floor
	mk("Part", {
		Anchored = true, CanCollide = false, CanTouch = false, CanQuery = false,
		Size = Vector3.new(L, 2, C.ROAD_HALF * 2 + 20),
		CFrame = CFrame.new(x0 + L / 2, -14, 0),
		Color = Color3.fromRGB(255, 110, 40), Material = Enum.Material.Neon,
	}, g)
	-- lava gaps scale with difficulty for the same reason the plain gaps do:
	-- a fixed 18-26 stud hole is trivial once a rider is carrying tier 3+ speed
	diff = diff or 1
	local glo, ghi
	if diff <= 1 then glo, ghi = 18, 26
	elseif diff == 2 then glo, ghi = 28, 40
	else glo, ghi = 42, 58 end
	local x = x0
	while x < x0 + L - 1 do
		local solid = rng:NextNumber(30, 46)
		solid = math.min(solid, x0 + L - x)
		road(g, x, solid, C.ROAD_HALF, 0)
		edgeLines(g, x, solid, C.ROAD_HALF, 0)
		x += solid + rng:NextNumber(glo, ghi)
	end
	return L
end }

S.ice = { band = {1,3}, build = function(g, h, x0, rng)
	local L = C.SECTION_LENGTH
	road(g, x0, L, C.ROAD_HALF, 0, "ice")
	edgeLines(g, x0, L, C.ROAD_HALF, 0)
	for i = 1, 3 do
		local x = x0 + 30 + (i - 1) * 38
		local z = rng:NextNumber(-14, 14)
		hazard(h, {
			Size = Vector3.new(6, 9, 6),
			CFrame = CFrame.new(x, 4.5, z),
			Color = Color3.fromRGB(200, 245, 255), Material = Enum.Material.Glass, Transparency = 0.25,
		}, "obstacle")
	end
	return L
end }

S.speedway = { band = {3,3}, build = function(g, h, x0, rng)
	local L = C.SECTION_LENGTH
	road(g, x0, L, C.ROAD_HALF, 0)
	edgeLines(g, x0, L, C.ROAD_HALF, 0)
	for i = 1, 4 do
		local p = mk("Part", {
			Anchored = true, CanCollide = false, CanTouch = false,
			Size = Vector3.new(22, 0.6, C.ROAD_HALF * 2 - 4),
			CFrame = CFrame.new(x0 + 20 + (i - 1) * 34, 0.2, 0),
			Color = Color3.fromRGB(120, 255, 170), Material = Enum.Material.Neon,
		}, h)
		p:SetAttribute("DSR", "boost")
	end
	return L
end }

-- ---------------------------------------------------------------- parkour
-- STEP-UP: a rising staircase of platforms with gaps between. Rewards timing
-- rather than pure reaction.
S.stepup = { band = {2,3}, build = function(g, h, x0, rng, diff)
	local L = C.SECTION_LENGTH
	diff = diff or 2
	local steps = (diff >= 3) and 4 or 3
	local rise = (diff >= 3) and 3.2 or 2.4
	local segLen = L / steps
	local gapW = (diff >= 3) and 18 or 13
	road(g, x0, 26, C.ROAD_HALF, 0)
	edgeLines(g, x0, 26, C.ROAD_HALF, 0)
	local x = x0 + 26
	for i = 1, steps do
		local y = i * rise
		local plateLen = segLen - gapW
		if x + plateLen > x0 + L then plateLen = (x0 + L) - x end
		if plateLen > 8 then
			road(g, x, plateLen, C.ROAD_HALF - 2, y)
			edgeLines(g, x, plateLen, C.ROAD_HALF - 2, y)
			-- support column so platforms do not look unsupported
			mk("Part", {
				Anchored = true, CanCollide = false, CanTouch = false, CanQuery = false,
				Size = Vector3.new(plateLen * 0.5, y + 2, 3),
				CFrame = CFrame.new(x + plateLen / 2, (y - 2) / 2, 0),
				Color = Color3.fromRGB(40, 43, 54), Material = Enum.Material.Metal,
			}, g)
		end
		x += segLen
	end
	return L
end }

-- SPLIT: two parallel routes at different heights. The high road is narrower
-- but shorter; the low road is safe. A real choice every time it appears.
S.split = { band = {2,3}, build = function(g, h, x0, rng, diff)
	local L = C.SECTION_LENGTH
	diff = diff or 2
	road(g, x0, 22, C.ROAD_HALF, 0)
	edgeLines(g, x0, 22, C.ROAD_HALF, 0)
	local midLen = L - 44
	-- low route: full width, ground level, with obstacles
	road(g, x0 + 22, midLen, 9, 0, "ground", -11)
	edgeLines(g, x0 + 22, midLen, 9, 0, -11)
	for i = 1, (diff >= 3) and 3 or 2 do
		local px = x0 + 34 + (i - 1) * (midLen / 3)
		local p = mk("Part", {
			Anchored = true, CanCollide = false, CanTouch = false,
			Size = Vector3.new(4, 12, 4),
			CFrame = CFrame.new(px, 6, -11 + rng:NextNumber(-4, 4)),
			Color = Color3.fromRGB(255, 96, 92), Material = Enum.Material.Neon,
			Transparency = 0.15,
		}, h)
		p:SetAttribute("DSR", "obstacle")
	end
	-- centre divider: a narrow rideable strip so failing to commit is a
	-- disadvantage, not an instant death. No boosts here -- picking a side is
	-- still the rewarded play.
	road(g, x0 + 22, midLen, 3.5, 0, "ground", 0)
	edgeLines(g, x0 + 22, midLen, 3.5, 0, 0)

	-- high route: narrow ledge, boost pads as the reward
	local hy = (diff >= 3) and 7 or 5.5
	road(g, x0 + 22, midLen, 6, hy, "ground", 12)
	edgeLines(g, x0 + 22, midLen, 6, hy, 12)
	for i = 1, 2 do
		local bp = mk("Part", {
			Anchored = true, CanCollide = false, CanTouch = false,
			Size = Vector3.new(14, 0.6, 9),
			CFrame = CFrame.new(x0 + 40 + (i - 1) * 34, hy + 0.2, 12),
			Color = Color3.fromRGB(120, 255, 170), Material = Enum.Material.Neon,
		}, h)
		bp:SetAttribute("DSR", "boost")
	end
	-- ramp up to the high route
	local rampLen = 20
	local ang = math.atan2(hy, rampLen)
	local hyp = math.sqrt(rampLen ^ 2 + hy ^ 2)
	local r = mk("Part", {
		Anchored = true, CanCollide = false, CanTouch = false,
		Size = Vector3.new(hyp, 1.6, 12),
		CFrame = CFrame.new(x0 + 22 + rampLen / 2, hy / 2 - 0.8, 12) * CFrame.Angles(0, 0, ang),
		Color = Color3.fromRGB(90, 200, 255), Material = Enum.Material.Metal,
	}, g)
	r:SetAttribute("DSR", "ground")
	road(g, x0 + L - 22, 22, C.ROAD_HALF, 0)
	edgeLines(g, x0 + L - 22, 22, C.ROAD_HALF, 0)
	return L
end }

-- CANYON: a drop into a trench and a climb back out. Vertical drama without
-- risking an unclearable gap, because the floor is continuous.
S.canyon = { band = {2,3}, build = function(g, h, x0, rng, diff)
	local L = C.SECTION_LENGTH
	diff = diff or 2
	local depth = (diff >= 3) and -7 or -5
	road(g, x0, 20, C.ROAD_HALF, 0)
	edgeLines(g, x0, 20, C.ROAD_HALF, 0)
	-- descent ramp
	local dLen = 22
	local ang = math.atan2(-depth, dLen)
	local hyp = math.sqrt(dLen ^ 2 + depth ^ 2)
	local d1 = mk("Part", {
		Anchored = true, CanCollide = false, CanTouch = false,
		Size = Vector3.new(hyp, 1.6, C.ROAD_HALF * 2),
		CFrame = CFrame.new(x0 + 20 + dLen / 2, depth / 2 - 0.8, 0) * CFrame.Angles(0, 0, -ang),
		Color = Color3.fromRGB(48, 52, 66), Material = Enum.Material.Metal,
	}, g)
	d1:SetAttribute("DSR", "ground")
	-- trench floor with hazards
	local floorLen = L - 40 - dLen * 2
	road(g, x0 + 20 + dLen, floorLen, C.ROAD_HALF, depth)
	edgeLines(g, x0 + 20 + dLen, floorLen, C.ROAD_HALF, depth)
	for i = 1, (diff >= 3) and 3 or 2 do
		local p = mk("Part", {
			Anchored = true, CanCollide = false, CanTouch = false,
			Size = Vector3.new(3.5, 5, 16),
			CFrame = CFrame.new(x0 + 20 + dLen + 14 + (i - 1) * 26, depth + 2.5, rng:NextNumber(-8, 8)),
			Color = Color3.fromRGB(255, 170, 60), Material = Enum.Material.Neon,
			Transparency = 0.1,
		}, h)
		p:SetAttribute("DSR", "obstacle")
	end
	-- climb out
	local u1 = mk("Part", {
		Anchored = true, CanCollide = false, CanTouch = false,
		Size = Vector3.new(hyp, 1.6, C.ROAD_HALF * 2),
		CFrame = CFrame.new(x0 + L - 20 - dLen / 2, depth / 2 - 0.8, 0) * CFrame.Angles(0, 0, ang),
		Color = Color3.fromRGB(48, 52, 66), Material = Enum.Material.Metal,
	}, g)
	u1:SetAttribute("DSR", "ground")
	road(g, x0 + L - 20, 20, C.ROAD_HALF, 0)
	edgeLines(g, x0 + L - 20, 20, C.ROAD_HALF, 0)
	return L
end }

------------------------------------------------------------------ generator
C.Order = {"straight","pillars","barriers","gaps","bridge","ramp","boost","rocks","rotors","lava","ice","speedway","stepup","split","canyon"}

function C.pickSection(rng, difficulty, last)
	local pool = {}
	for _, name in ipairs(C.Order) do
		local s = S[name]
		if difficulty >= s.band[1] and difficulty <= s.band[2] and name ~= last then
			table.insert(pool, name)
		end
	end
	if #pool == 0 then return "straight" end
	return pool[rng:NextInteger(1, #pool)]
end

function C.difficultyFor(index)
	if index <= 6 then return 1 elseif index <= 20 then return 2 else return 3 end
end

return C

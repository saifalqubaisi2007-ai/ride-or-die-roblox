--!strict
-- DON'T STOP RIDING :: server
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local C = require(RS:WaitForChild("DSRConfig"))
local Data = require(script.Parent:WaitForChild("DSRData"))
local Ch = require(script.Parent:WaitForChild("DSRChallenges"))
local Analytics = require(script.Parent:WaitForChild("DSRAnalytics"))
local LB = require(script.Parent:WaitForChild("DSRLeaderboard"))
local Money = require(script.Parent:WaitForChild("DSRMonetization"))
local Remotes = RS:WaitForChild("DSRRemotes")
local RE_State = Remotes:WaitForChild("State") :: RemoteEvent
local RE_Progress = Remotes:WaitForChild("Progress") :: RemoteEvent
local RE_Crash = Remotes:WaitForChild("Crash") :: RemoteEvent
local RE_Revive = Remotes:WaitForChild("Revive") :: RemoteEvent
local RE_Restart = Remotes:WaitForChild("Restart") :: RemoteEvent
local RE_Profile = Remotes:WaitForChild("Profile") :: RemoteEvent
local RE_Shop = Remotes:WaitForChild("Shop") :: RemoteEvent
local RE_Chal = Remotes:WaitForChild("Challenges") :: RemoteEvent
local RE_Settings = Remotes:WaitForChild("Settings") :: RemoteEvent
local RE_Board = Remotes:WaitForChild("Board") :: RemoteEvent

------------------------------------------------------------------ world setup
local function setupWorld()

Money.init(Data)
Money.setupReceipts()
Data.startAutosave(60)
Analytics.bindLifecycle()
Data.bindToClose()
	local L = game:GetService("Lighting")

	-- PREMIUM SKY --------------------------------------------------------
	-- The old setup DESTROYED the Sky object, which left Roblox's flat grey
	-- void behind the track. A skybox costs nothing and is the single biggest
	-- visual win available, since the horizon fills most of the screen while
	-- riding.
	L.ClockTime = 17.2                       -- late afternoon: long warm light
	L.GeographicLatitude = 12
	L.Brightness = 2.6
	L.Ambient = Color3.fromRGB(72, 74, 96)
	L.OutdoorAmbient = Color3.fromRGB(104, 110, 140)
	L.EnvironmentDiffuseScale = 0.55
	L.EnvironmentSpecularScale = 0.5
	L.ExposureCompensation = 0.1
	L.ShadowSoftness = 0.35
	L.FogEnd = 2600                          -- was 1400: track vanished too close
	L.FogStart = 900
	L.FogColor = Color3.fromRGB(150, 146, 186)

	for _, n in ipairs({ "Sky", "SunRays", "Atmosphere", "Bloom", "DepthOfField", "ColorCorrection" }) do
		local o = L:FindFirstChild(n)
		if o then o:Destroy() end
	end

	local sky = Instance.new("Sky")
	sky.Name = "Sky"
	sky.SkyboxBk = "rbxassetid://150720100"
	sky.SkyboxDn = "rbxassetid://150720228"
	sky.SkyboxFt = "rbxassetid://150720161"
	sky.SkyboxLf = "rbxassetid://150720263"
	sky.SkyboxRt = "rbxassetid://150720196"
	sky.SkyboxUp = "rbxassetid://150720299"
	sky.SunAngularSize = 14
	sky.MoonAngularSize = 9
	sky.StarCount = 3000
	sky.Parent = L

	-- thin atmosphere: depth without the soup the old 0.42 density created
	local atm = Instance.new("Atmosphere")
	atm.Density = 0.28
	atm.Offset = 0.1
	atm.Haze = 1.4
	atm.Glare = 0.35
	atm.Color = Color3.fromRGB(190, 190, 215)
	atm.Decay = Color3.fromRGB(96, 100, 140)
	atm.Parent = L

	local bloom = Instance.new("BloomEffect")
	bloom.Intensity = 0.6
	bloom.Threshold = 1.4
	bloom.Size = 20
	bloom.Parent = L

	local rays = Instance.new("SunRaysEffect")
	rays.Intensity = 0.06
	rays.Spread = 0.35
	rays.Parent = L

	-- gentle grade: lifts saturation so biome colours read without going neon
	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "Grade"
	cc.Brightness = 0.02
	cc.Contrast = 0.09
	cc.Saturation = 0.11
	cc.TintColor = Color3.fromRGB(255, 250, 244)
	cc.Parent = L

	local bp = workspace:FindFirstChild("Baseplate")
	if bp then bp:Destroy() end
	local sp = workspace:FindFirstChild("SpawnLocation")
	if sp then sp:Destroy() end
	workspace.Gravity = C.GRAVITY
end
setupWorld()

------------------------------------------------------------------ track
local Track = Instance.new("Folder")
Track.Name = "DSRTrack"
Track.Parent = workspace
local Ground = Instance.new("Folder"); Ground.Name = "Ground"; Ground.Parent = Track
local Hazards = Instance.new("Folder"); Hazards.Name = "Hazards"; Hazards.Parent = Track

local armed: { [BasePart]: boolean } = {}
local trackEndX = 0
local lastGateX = 0
local sectionIndex = 0
local rng = Random.new()
local lastKind = nil

local MAX_LIVE_SECTIONS = 260  -- hard ceiling; rounds regenerate long before this

-- Recolour whatever the section builder just produced so each biome reads
-- distinctly, and tag ground slabs so Collapse Mode can drop them later.
local function applyBiome(newGround, newHazards, sIndex)
	local b = C.biomeFor(sIndex)
	local biome = C.BIOMES[b]
	local collapsible = sIndex >= C.COLLAPSE_SECTION
	for _, p in ipairs(newGround) do
		p:SetAttribute("Biome", b)
		local kind = p:GetAttribute("DSR")
		if p.Material == Enum.Material.Neon then
			p.Color = biome.edge                     -- edge striping
		elseif kind ~= "ice" then
			p.Color = biome.road
		end
		if collapsible and kind ~= nil then
			p:SetAttribute("Collapsible", true)
		end
	end
	for _, p in ipairs(newHazards) do
		p:SetAttribute("Biome", b)
	end
end

-- Sections are generated independently, so two of them can combine into a hole
-- wider than either intended. An 86-stud gap was measured, which a rider who
-- had just been knocked down to tier 0 (52 stud jump) could not clear -- death
-- with no counterplay. Rather than special-casing every section pairing, probe
-- the finished surface and patch anything unclearable at that band's floor tier.
local reachParams = RaycastParams.new()
reachParams.FilterType = Enum.RaycastFilterType.Include
reachParams.FilterDescendantsInstances = { Ground }

local function ensureReachable(xStart: number, xEnd: number, diff: number)
	-- widest gap clearable at the LOWEST tier a player plausibly has here
	local floorTier = (diff <= 1) and 0 or (diff == 2 and 1 or 2)
	local hang = 2 * C.JUMP_VELOCITY / C.GRAVITY
	local maxGap = hang * (C.BASE_SPEED + floorTier * C.TIER_SPEED) * 0.80

	-- multi-lane probe. Two fixes over the single-lane version:
	--   1. Sections like `split` put routes at z = -11 and +12, which a probe
	--      at z=0 alone would report as one long unreachable hole.
	--   2. Elevated sections (stepup, canyon) need any patch platform placed at
	--      the LOCAL surface height, not a hard-coded y = -1, or the fix floats
	--      in mid-air or buries itself.
	local step = 2
	local lanes = { 0, -11, 12 }

	for _, lane in ipairs(lanes) do
		local runStart, runY = nil, 0
		local lastY = 0
		local x = xStart
		while x <= xEnd do
			local hit = workspace:Raycast(Vector3.new(x, 120, lane), Vector3.new(0, -300, 0), reachParams)
			if hit then
				lastY = hit.Position.Y
				if runStart then
					local w = x - runStart
					if w > maxGap then
						local mid = runStart + w / 2
						-- bridge between the two edge heights so the pad meets
						-- whatever level the route is actually on
						local padY = (runY + lastY) / 2
						local pad = C.mk("Part", {
							Anchored = true, CanCollide = false, CanTouch = false,
							Size = Vector3.new(22, 2, 18),
							CFrame = CFrame.new(mid, padY - 1, lane),
							Color = Color3.fromRGB(48, 52, 66),
							Material = Enum.Material.Metal,
						}, Ground)
						pad:SetAttribute("DSR", "ground")
						pad:SetAttribute("Patched", true)
					end
					runStart = nil
				end
			else
				if not runStart then
					runStart = x
					runY = lastY
				end
			end
			x += step
		end
	end
end

local function buildSections(n)
	if sectionIndex >= MAX_LIVE_SECTIONS then return end
	for _ = 1, n do
		sectionIndex += 1
		local diff = C.difficultyFor(sectionIndex)
		local kind = (sectionIndex <= 2) and "straight" or C.pickSection(rng, diff, lastKind)
		lastKind = kind

		local sectionStart = trackEndX
		local gBefore = #Ground:GetChildren()
		local hBefore = #Hazards:GetChildren()
		local len = C.Sections[kind].build(Ground, Hazards, trackEndX, rng, diff)

		local gKids, hKids = Ground:GetChildren(), Hazards:GetChildren()
		local newG, newH = {}, {}
		for i = gBefore + 1, #gKids do table.insert(newG, gKids[i]) end
		for i = hBefore + 1, #hKids do table.insert(newH, hKids[i]) end
		applyBiome(newG, newH, sectionIndex)

		-- milestone gate: progress becomes something you can SEE approaching
		-- rather than a number ticking in the corner. Two parts per 500m, so
		-- ~40 parts across a full track -- negligible against the ~450 budget.
		local gateX = math.floor((trackEndX + len) / 500) * 500
		if gateX > lastGateX and gateX > sectionStart then
			lastGateX = gateX
			for _, side in ipairs({ -1, 1 }) do
				local post = C.mk("Part", {
					Anchored = true, CanCollide = false, CanTouch = false, CanQuery = false,
					Size = Vector3.new(1.4, 15, 1.4),
					CFrame = CFrame.new(gateX, 7.5, side * (C.ROAD_HALF + 2)),
					Color = Color3.fromRGB(255, 220, 110),
					Material = Enum.Material.Neon,
				}, Ground)
				if side == 1 then
					local bb = Instance.new("BillboardGui")
					bb.Size = UDim2.new(0, 150, 0, 42)
					bb.StudsOffset = Vector3.new(0, 9, 0)
					bb.MaxDistance = 500
					bb.Adornee = post
					local lbl = Instance.new("TextLabel")
					lbl.BackgroundTransparency = 1
					lbl.Size = UDim2.new(1, 0, 1, 0)
					lbl.Font = Enum.Font.GothamBlack
					lbl.Text = (gateX >= 1000)
						and (string.format("%.1fk", gateX / 1000):gsub("%.0k", "k"))
						or (gateX .. "m")
					lbl.TextColor3 = Color3.fromRGB(255, 220, 110)
					lbl.TextScaled = true
					lbl.TextStrokeTransparency = 0.5
					lbl.Parent = bb
					bb.Parent = post
				end
			end
		end
		ensureReachable(sectionStart, trackEndX + len, diff)

		trackEndX += len
	end
end

local function clearInBatches(folder: Instance, perFrame: number)
	local kids = folder:GetChildren()
	for i = 1, #kids do
		kids[i]:Destroy()
		if i % perFrame == 0 then task.wait() end
	end
end

local function regenerate()
	table.clear(armed)
	clearInBatches(Ground, 60)
	clearInBatches(Hazards, 60)
	trackEndX = 0
	lastGateX = 0
	sectionIndex = 0
	lastKind = nil
	rng = Random.new(os.clock() * 1000 % 100000)
	-- start pad
	C.road(Ground, -60, 60, C.ROAD_HALF, 0)
	-- Build the opening stretch immediately so the countdown never waits on it,
	-- then yield once per section for the remainder. Players only need the first
	-- ~2000 studs to start riding; the rest streams in during the countdown.
	for i = 1, math.min(15, C.START_SECTIONS) do
		buildSections(1)
		if i % 3 == 0 then task.wait() end
	end
	for i = 16, C.START_SECTIONS do
		buildSections(1)
		task.wait()
	end
end

------------------------------------------------------------------ hazard animation
local movers = {}
local function refreshMovers()
	table.clear(movers)
	for _, p in ipairs(Hazards:GetChildren()) do
		if p:GetAttribute("Mover") then
			table.insert(movers, p)
		end
	end
end

RunService.Heartbeat:Connect(function()
	local t = os.clock()
	-- only animate near players (cheap distance gate)
	local xs = {}
	for _, pl in ipairs(Players:GetPlayers()) do
		local ch = pl.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if hrp then table.insert(xs, (hrp :: BasePart).Position.X) end
	end
	if #xs == 0 then return end
	for _, p in ipairs(movers) do
		if p.Parent then
			local bx = p:GetAttribute("BaseX") :: number
			local near = false
			for _, x in ipairs(xs) do
				if math.abs(x - bx) < 700 then near = true break end
			end
			if near then
				local kind = p:GetAttribute("Mover")
				local sp = p:GetAttribute("Speed") :: number
				local ph = p:GetAttribute("Phase") :: number
				if kind == "slide" then
					local amp = p:GetAttribute("Amp") :: number
					p.CFrame = CFrame.new(bx, 5, math.sin(t * sp + ph) * amp)
				elseif kind == "spin" then
					p.CFrame = CFrame.new(bx, 4.5, 0) * CFrame.Angles(0, t * sp + ph, 0)
				elseif kind == "fall" then
					local bz = p:GetAttribute("BaseZ") :: number
					local cycle = (t * sp + ph) % 3
					local y
					if cycle < 2.2 then
						y = 46 - (cycle / 2.2) ^ 2 * 46
					else
						y = 46
					end
					p.CFrame = CFrame.new(bx, math.max(y, 4.5), bz)
				end
			end
		end
	end
end)

------------------------------------------------------------------ bike
local function buildBike(char: Model)
	local hrp = char:WaitForChild("HumanoidRootPart") :: BasePart
	local existing = char:FindFirstChild("Bike")
	if existing then existing:Destroy() end

	local bike = Instance.new("Model")
	bike.Name = "Bike"

	local function piece2(size, offCF, color, mat, shape)
		local p = Instance.new("Part")
		p.Size = size
		p.Color = color
		p.Material = mat or Enum.Material.SmoothPlastic
		if shape then p.Shape = shape end
		p.CanCollide = false; p.CanTouch = false; p.CanQuery = false
		p.Massless = true
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.CFrame = hrp.CFrame * offCF
		p.Parent = bike
		local w = Instance.new("Weld")
		w.Part0 = hrp; w.Part1 = p; w.C0 = offCF; w.Parent = p
		return p
	end

	local function piece(size, offset, color, mat, shape)
		local p = Instance.new("Part")
		p.Size = size
		p.Color = color
		p.Material = mat or Enum.Material.SmoothPlastic
		if shape then p.Shape = shape end
		p.CanCollide = false
		p.CanTouch = false
		p.CanQuery = false
		p.Massless = true
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.CFrame = hrp.CFrame * CFrame.new(offset)
		p.Parent = bike
		local w = Instance.new("Weld")
		w.Part0 = hrp
		w.Part1 = p
		w.C0 = CFrame.new(offset)
		w.Parent = p
		return p
	end

	local prof = Data.get(Players:GetPlayerFromCharacter(char))
	local skin = C.getBike(prof and prof.equippedBike or "starter")
	-- seat the rider: drop the visible body to meet the saddle
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.HipHeight = 0
	end

	local frameCol = skin.frame

	-- Geometry is built around the contact patch: the wheels must touch the road,
	-- which sits at y = -RIDE_HEIGHT relative to the root. Previously the wheels
	-- were 1.6 studs under the tarmac, so only the frame was visible.
	local WHEEL_R   = 2.5
	local GROUND_Y  = -C.RIDE_HEIGHT
	local AXLE_Y    = GROUND_Y + WHEEL_R      -- wheel centres
	local WHEELBASE = 3.9

	-- wheels
	for _, dx in ipairs({ WHEELBASE, -WHEELBASE }) do
		local off = CFrame.new(dx, AXLE_Y, 0) * CFrame.Angles(0, math.rad(90), 0)
		local tyre = piece2(Vector3.new(0.62, WHEEL_R * 2, WHEEL_R * 2), off,
			Color3.fromRGB(18, 18, 24), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
		tyre:SetAttribute("DSRWheel", true)
		local rim = piece2(Vector3.new(0.66, WHEEL_R * 1.42, WHEEL_R * 1.42), off,
			skin.rim, Enum.Material.Neon, Enum.PartType.Cylinder)
		rim:SetAttribute("DSRWheel", true)
		-- spokes give the rim something to visibly rotate
		for k = 0, 2 do
			local sp = piece2(Vector3.new(0.7, WHEEL_R * 1.9, 0.34),
				off * CFrame.Angles(math.rad(k * 60), 0, 0),
				skin.rim, Enum.Material.Neon)
			sp:SetAttribute("DSRWheel", true)
		end
	end

	-- frame: down tube, top tube, seat post, forks
	piece(Vector3.new(WHEELBASE * 1.9, 0.42, 0.42), Vector3.new(0, AXLE_Y + 1.5, 0), frameCol, Enum.Material.Neon)
	piece(Vector3.new(4.4, 0.38, 0.38), Vector3.new(0.5, AXLE_Y + 2.5, 0), frameCol, Enum.Material.Neon)
	piece(Vector3.new(0.4, 2.1, 0.4), Vector3.new(-2.0, AXLE_Y + 2.1, 0), frameCol, Enum.Material.Neon)
	piece(Vector3.new(0.4, 2.6, 0.4), Vector3.new(WHEELBASE - 0.4, AXLE_Y + 1.6, 0), frameCol, Enum.Material.Neon)

	-- saddle + handlebars
	piece(Vector3.new(1.7, 0.35, 0.8), Vector3.new(-2.2, AXLE_Y + 3.2, 0),
		Color3.fromRGB(26, 26, 34), Enum.Material.SmoothPlastic)
	piece(Vector3.new(0.35, 0.35, 3.4), Vector3.new(WHEELBASE - 0.5, AXLE_Y + 3.0, 0),
		Color3.fromRGB(30, 30, 40), Enum.Material.Metal)

	-- pedals/cranks so it reads as a bicycle, not a scooter
	piece(Vector3.new(0.3, 1.6, 0.3), Vector3.new(0, AXLE_Y + 0.2, 0.5), Color3.fromRGB(40, 40, 52), Enum.Material.Metal)
	piece(Vector3.new(1.0, 0.25, 0.5), Vector3.new(0, AXLE_Y - 0.5, 0.75), Color3.fromRGB(40, 40, 52), Enum.Material.Metal)
	piece(Vector3.new(1.0, 0.25, 0.5), Vector3.new(0, AXLE_Y + 0.9, -0.75), Color3.fromRGB(40, 40, 52), Enum.Material.Metal)

	-- momentum trail anchors
	local a0 = Instance.new("Attachment"); a0.Name = "TrailA"; a0.Position = Vector3.new(-3.2, -0.6, 0); a0.Parent = hrp
	local a1 = Instance.new("Attachment"); a1.Name = "TrailB"; a1.Position = Vector3.new(-3.2, -3.6, 0); a1.Parent = hrp
	local trail = Instance.new("Trail")
	trail.Name = "MomentumTrail"
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = 0.45
	trail.MinLength = 0.1
	trail.LightEmission = 1
	trail.Enabled = false
	local trailSkin = C.getTrail(prof and prof.equippedTrail or "t_stock")
	trail.Color = ColorSequence.new(trailSkin.color)
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.Parent = hrp

	bike.Parent = char
end
------------------------------------------------------------------ SHOP
-- Server-authoritative: the client sends an intent, never a price or a balance.
local lastShop: { [Player]: number } = {}
RE_Shop.OnServerEvent:Connect(function(plr, action, itemId, category)
	if typeof(action) ~= "string" or typeof(itemId) ~= "string" then return end
	category = (category == "trail") and "trail" or "bike"
	local now = os.clock()
	if lastShop[plr] and now - lastShop[plr] < 0.25 then return end
	lastShop[plr] = now

	local prof = Data.get(plr)
	if not prof then return end
	if not Data.isLoaded(plr) then
		RE_Shop:FireClient(plr, false, "Profile still loading, try again")
		return
	end

	local item = (category == "trail") and C.TRAIL_BY_ID[itemId] or C.BIKE_BY_ID[itemId]
	if not item then return end

	prof.bikes = prof.bikes or { starter = true }
	prof.trails = prof.trails or { t_stock = true }
	local owned = (category == "trail") and prof.trails or prof.bikes

	Analytics.event(plr, "shop_open")
	if action == "buy" then
		if owned[itemId] then
			RE_Shop:FireClient(plr, false, "Already owned")
			return
		end
		-- event items are only PURCHASABLE during the event; ownership is forever
		if item.event and not C.eventActive() then
			RE_Shop:FireClient(plr, false, "Event has ended")
			return
		end
		if (prof.coins or 0) < item.price then
			RE_Shop:FireClient(plr, false, "Not enough coins")
			return
		end
		prof.coins -= item.price
		owned[itemId] = true
		if category == "trail" then prof.equippedTrail = itemId else prof.equippedBike = itemId end
		Data.markDirty(plr)
		Data.save(plr)
		RE_Shop:FireClient(plr, true, "Unlocked " .. item.name)
		RE_Profile:FireClient(plr, prof)
		if plr.Character then buildBike(plr.Character) end

	elseif action == "equip" then
		if not owned[itemId] then
			RE_Shop:FireClient(plr, false, "Not owned")
			return
		end
		if category == "trail" then prof.equippedTrail = itemId else prof.equippedBike = itemId end
		Data.markDirty(plr)
		RE_Shop:FireClient(plr, true, "Equipped " .. item.name)
		RE_Profile:FireClient(plr, prof)
		if plr.Character then buildBike(plr.Character) end
	end
end)
-- Studio-only QA hook: lets automated tests fund a purchase without pretending
-- to be a client exploit. Completely inert in a live game.
if RunService:IsStudio() then
	task.spawn(function()
		while true do
			task.wait(0.5)
			for _, plr in ipairs(Players:GetPlayers()) do
				local g = plr:GetAttribute("DSR_DEBUG_GRANT")
				if typeof(g) == "number" and g > 0 then
					plr:SetAttribute("DSR_DEBUG_GRANT", 0)
					local prof = Data.get(plr)
					if prof then
						prof.coins = (prof.coins or 0) + g
						Data.markDirty(plr)
						RE_Profile:FireClient(plr, prof)
					end
				end
			end
		end
	end)
end
-- challenge snapshot on demand (client opens the panel)
local lastChal: { [Player]: number } = {}
RE_Chal.OnServerEvent:Connect(function(plr)
	local now = os.clock()
	if lastChal[plr] and now - lastChal[plr] < 0.5 then return end
	lastChal[plr] = now
	local prof = Data.get(plr)
	if prof then
		RE_Chal:FireClient(plr, { snapshot = Ch.snapshot(prof) })
	end
end)
-- settings: strict whitelist, clamped, never trusted verbatim
local ALLOWED_SETTINGS = { shake = "boolean", sfx = "number", music = "number" }
local lastSet: { [Player]: number } = {}
RE_Settings.OnServerEvent:Connect(function(plr, key, value)
	if typeof(key) ~= "string" then return end
	local expect = ALLOWED_SETTINGS[key]
	if not expect or typeof(value) ~= expect then return end
	local now = os.clock()
	if lastSet[plr] and now - lastSet[plr] < 0.15 then return end
	lastSet[plr] = now
	local prof = Data.get(plr)
	if not prof or not Data.isLoaded(plr) then return end
	prof.settings = prof.settings or {}
	if expect == "number" then
		value = math.clamp(value, 0, 1)
	end
	prof.settings[key] = value
	Data.markDirty(plr)
	RE_Profile:FireClient(plr, prof)
end)
-- leaderboard fetch (rate limited; results are cached server-side for 45s)
local lastBoardReq: { [Player]: number } = {}
RE_Board.OnServerEvent:Connect(function(plr, periodKey)
	if typeof(periodKey) ~= "string" then return end
	local now = os.clock()
	if lastBoardReq[plr] and now - lastBoardReq[plr] < 1 then return end
	lastBoardReq[plr] = now
	local rows = LB.top(periodKey, 10)
	RE_Board:FireClient(plr, { period = periodKey, rows = rows, global = LB.isGlobal() })
end)

------------------------------------------------------------------ round state
type PState = { dist: number, tier: number, alive: boolean, best: number, startedAt: number, lastUpdate: number, spam: number }
local state: { [Player]: PState } = {}

local collapseActive = false
local phase = "INTERMISSION"
local phaseEnds = os.clock() + 3

local function readyCharacter(plr: Player)
	local ch = plr.Character
	if not ch then return end
	local hum = ch:FindFirstChildOfClass("Humanoid")
	local hrp = ch:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hum or not hrp then return end
	hum.WalkSpeed = 0
	hum.JumpPower = 0
	hum.AutoRotate = false
	hum.PlatformStand = true
	hum.BreakJointsOnDeath = false
	hrp.CFrame = CFrame.new(-30, C.RIDE_HEIGHT + 2, 0)
	hrp.AssemblyLinearVelocity = Vector3.zero
	buildBike(ch)
end

local function broadcast(extra)
	local board = {}
	for plr, st in pairs(state) do
		table.insert(board, { name = plr.DisplayName, dist = math.floor(st.dist), alive = st.alive, id = plr.UserId })
	end
	table.sort(board, function(a, b) return a.dist > b.dist end)
	local payload = {
		phase = phase,
		collapse = collapseActive,
		timeLeft = math.max(0, phaseEnds - os.clock()),
		board = board,
	}
	if extra then
		for k, v in pairs(extra) do payload[k] = v end
	end
	RE_State:FireAllClients(payload)
end

local function aliveCount()
	local n = 0
	for _, st in pairs(state) do if st.alive then n += 1 end end
	return n
end

Players.PlayerAdded:Connect(function(plr)
	state[plr] = { dist = 0, tier = 0, alive = false, best = 0, startedAt = os.clock(), lastUpdate = os.clock(), spam = 0 }
	task.spawn(function()
		local prof = Data.load(plr)
		state[plr].best = prof.bestDistance or 0
		Ch.refresh(prof)
		RE_Profile:FireClient(plr, prof)
		RE_Chal:FireClient(plr, { snapshot = Ch.snapshot(prof) })
	end)
	plr.CharacterAdded:Connect(function()
		task.wait(0.2)
		readyCharacter(plr)
		local st = state[plr]

		-- A player who joins mid-round previously sat dead until the next round
		-- began -- up to ROUND_TIME (170s) of staring at nothing before their
		-- first ride. Launch-critical: give them their own run immediately.
		-- The track already exists, distance is per-player, and the round timer
		-- is shared, so this costs nothing and desynchronises nobody.
		if st and phase == "RIDING" and not st.alive then
			st.alive = true
			st.dist = 0
			st.startedAt = os.clock()
			st.lastUpdate = os.clock()
			st.spam = 0
			RE_State:FireClient(plr, {
				phase = phase,
				timeLeft = math.max(0, phaseEnds - os.clock()),
				board = {},
				go = true,
			})
			broadcast()
			return
		end

		RE_State:FireClient(plr, {
			phase = phase,
			timeLeft = math.max(0, phaseEnds - os.clock()),
			board = {},
			youAlive = st and st.alive or false,
		})
	end)
end)

Players.PlayerRemoving:Connect(function(plr)
	state[plr] = nil
	task.spawn(function() Data.release(plr) end)
end)

-- server-side plausibility check. the client simulates the bike (needed for feel),
-- so the server bounds what it will accept: you cannot have travelled further than
-- top speed * time riding, plus a small allowance for latency.
local TOP_SPEED = C.BASE_SPEED + C.MAX_TIER * C.TIER_SPEED

-- Distance is derived from the character's REPLICATED position, not from a
-- number the client sends us. The client owns its root part (needed for a
-- responsive bike), so position can still be manipulated -- but it is bounded
-- by the plausibility cap below, and a client that only fakes the remote
-- without moving is rejected outright.
local function maxPlausible(st: PState): number
	local elapsed = os.clock() - (st.startedAt or os.clock())
	return (elapsed + 1.5) * TOP_SPEED * 1.12
end

local function sampleDistance(plr: Player, st: PState)
	local ch = plr.Character
	local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	local x = (hrp :: BasePart).Position.X
	if x ~= x then return end
	st.dist = math.max(st.dist, math.clamp(x, 0, maxPlausible(st)))
end

-- authoritative distance sampler
task.spawn(function()
	while true do
		task.wait(0.25)
		for plr, st in pairs(state) do
			if st.alive then
				sampleDistance(plr, st)
			end
		end
	end
end)

-- The client still reports tier so we can drive effects/leaderboard styling,
-- but its distance claim is ignored entirely.
RE_Progress.OnServerEvent:Connect(function(plr, dist, tier)
	local st = state[plr]
	if not st or not st.alive then return end
	st.spam = (st.spam or 0) + 1
	if st.spam > 40 then return end
	local t = tonumber(tier)
	st.tier = (t and math.clamp(math.floor(t), 0, C.MAX_TIER)) or 0
end)

-- Settling a run: awards coins, updates best distance, records challenge
-- progress and submits to the leaderboard. Used BOTH when a player crashes and
-- when the round timer ends while they are still riding -- previously the second
-- case paid nothing, so the players who survived longest were the only ones who
-- got no reward at all.
local function finishRun(plr: Player, reason: string)
	local st = state[plr]
	if not st or not st.alive then return end
	sampleDistance(plr, st)
	st.alive = false

	-- single settle point, so every finished run is counted exactly once
	Analytics.run(plr, st.dist, st.tier or 0,
		st.dist >= (C.COLLAPSE_SECTION - 1) * C.SECTION_LENGTH)

	local prof = Data.get(plr)
	local isRecord, coins = false, 0
	if prof then
		isRecord = st.dist > (prof.bestDistance or 0)
		if isRecord then prof.bestDistance = math.floor(st.dist) end
		coins = math.floor((math.floor(st.dist / 10) + (isRecord and 100 or 0)) * Money.coinMultiplier(plr))
		prof.coins = (prof.coins or 0) + coins
		prof.totalDistance = (prof.totalDistance or 0) + math.floor(st.dist)
		prof.runs = (prof.runs or 0) + 1
		st.best = prof.bestDistance

		local seconds = os.clock() - (st.startedAt or os.clock())
		local collapseX = (C.COLLAPSE_SECTION - 1) * C.SECTION_LENGTH
		local newly, bonus = Ch.recordRun(prof, math.floor(st.dist), seconds, st.dist >= collapseX)
		coins += bonus
		if #newly > 0 then
			for _ = 1, #newly do Analytics.event(plr, "challenge") end
			RE_Chal:FireClient(plr, { completed = newly })
		end

		Data.markDirty(plr)
		RE_Profile:FireClient(plr, prof)
		RE_Chal:FireClient(plr, { snapshot = Ch.snapshot(prof) })
		LB.submit(plr, st.dist)
	else
		isRecord = st.dist > st.best
		if isRecord then st.best = st.dist end
	end

	RE_State:FireClient(plr, {
		phase = phase,
		timeLeft = math.max(0, phaseEnds - os.clock()),
		board = {},
		crashed = true,
		reason = reason,
		dist = math.floor(st.dist),
		best = math.floor(st.best),
		record = isRecord,
		coins = coins,
	})
	broadcast()
end

RE_Crash.OnServerEvent:Connect(function(plr, dist)
	finishRun(plr, "crash")
end)

-- RIDE AGAIN: relaunch a crashed player immediately, without waiting for the
-- next round. the track persists for the round, so this costs nothing.
local lastRestart: { [Player]: number } = {}
RE_Restart.OnServerEvent:Connect(function(plr)
	local st = state[plr]
	if not st or st.alive then return end
	if phase ~= "RIDING" then return end
	local now = os.clock()
	if lastRestart[plr] and now - lastRestart[plr] < 1 then return end
	lastRestart[plr] = now
	st.alive = true
	st.dist = 0
	st.startedAt = os.clock()
	st.lastUpdate = os.clock()
	st.spam = 0
	readyCharacter(plr)
	RE_State:FireClient(plr, {
		phase = phase, timeLeft = math.max(0, phaseEnds - os.clock()),
		board = {}, go = true,
	})
	broadcast()
end)

-- watchdog: client reports a broken/missing character, rebuild it (rate limited)
local lastRevive: { [Player]: number } = {}
RE_Revive.OnServerEvent:Connect(function(plr)
	local now = os.clock()
	if lastRevive[plr] and now - lastRevive[plr] < 3 then return end
	lastRevive[plr] = now
	-- watchdog double-spawn guard.
	-- CharacterAutoLoads is true, so the engine ALREADY respawns a dead player.
	-- Calling LoadCharacter() here as well produced two spawns back to back --
	-- which is what made the loading screen appear twice on death.
	-- Only force a reload if the engine has genuinely failed to give us one.
	local ch = plr.Character
	if ch and ch:FindFirstChild("HumanoidRootPart") then
		readyCharacter(plr)
		return
	end
	local waited = 0
	while waited < 6 do
		task.wait(0.5)
		waited += 0.5
		local c2 = plr.Character
		if c2 and c2:FindFirstChild("HumanoidRootPart") then
			readyCharacter(plr)
			return
		end
	end
	-- engine never delivered a character: now a manual load is justified
	plr:LoadCharacter()
end)

-- decay remote-spam counters
task.spawn(function()
	while true do
		task.wait(1)
		for _, st in pairs(state) do
			st.spam = 0
		end
	end
end)

-- track extension when leader nears the end
task.spawn(function()
	while true do
		task.wait(1)
		if phase == "RIDING" then
			local lead = 0
			for _, st in pairs(state) do lead = math.max(lead, st.dist) end
			if lead > trackEndX - 2200 then
				buildSections(C.EXTEND_CHUNK)
				refreshMovers()
			end
		end
	end
end)

------------------------------------------------------------------ COLLAPSE ENGINE
-- Once a rider reaches the collapse zone the road stops being permanent: slabs
-- arm when you get close, flash, then fall away. This is the climax mechanic --
-- it punishes hesitation directly, which is the whole point of the game.
local TweenService = game:GetService("TweenService")

local function armSlab(p: BasePart)
	if armed[p] then return end
	armed[p] = true
	local originalColor = p.Color
	-- warning flash
	task.spawn(function()
		local t0 = os.clock()
		while os.clock() - t0 < C.COLLAPSE_WARN do
			if not p.Parent then return end
			local pulse = (math.sin((os.clock() - t0) * 26) + 1) / 2
			p.Color = originalColor:Lerp(Color3.fromRGB(255, 70, 70), 0.35 + pulse * 0.65)
			task.wait(0.05)
		end
		if not p.Parent then return end
		-- drop it: CanQuery off first so the ground raycast stops finding it
		p.CanQuery = false
		local tw = TweenService:Create(p, TweenInfo.new(1.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			CFrame = p.CFrame * CFrame.new(0, -70, 0) * CFrame.Angles(0, 0, math.rad(math.random(-18, 18))),
			Transparency = 1,
		})
		tw:Play()
		tw.Completed:Wait()
		if p.Parent then p:Destroy() end
		armed[p] = nil
	end)
end

task.spawn(function()
	while true do
		task.wait(0.2)
		if phase ~= "RIDING" then
			collapseActive = false
		else
			local lead = 0
			for _, st in pairs(state) do
				if st.alive then lead = math.max(lead, st.dist) end
			end
			local collapseX = (C.COLLAPSE_SECTION - 1) * C.SECTION_LENGTH
			collapseActive = lead >= collapseX
			if collapseActive then
				-- arm slabs just ahead of every living rider
				for plr, st in pairs(state) do
					if st.alive then
						local ch = plr.Character
						local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
						if hrp then
							local x = (hrp :: BasePart).Position.X
							for _, p in ipairs(Ground:GetChildren()) do
								if p:IsA("BasePart") and p:GetAttribute("Collapsible")
									and not armed[p] then
									-- only arm slabs the rider has already passed.
									-- the road ahead stays intact (readable), but you can
									-- never slow down or backtrack.
									local dx = p.Position.X - x
									if dx < -12 and dx > -C.COLLAPSE_NEAR then
										armSlab(p)
									end
								end
							end
						end
					end
				end
				-- hazards get faster and angrier
				for _, p in ipairs(Hazards:GetChildren()) do
					if p:GetAttribute("Mover") and not p:GetAttribute("Sped") then
						p:SetAttribute("Sped", true)
						local sp = p:GetAttribute("Speed") or 1
						p:SetAttribute("Speed", sp * 1.6)
					end
				end
			end
		end
	end
end)

-- main loop
task.spawn(function()
	while true do
		phase = "INTERMISSION"
		phaseEnds = os.clock() + C.INTERMISSION
		for plr, st in pairs(state) do
			st.alive = false
			st.dist = 0
			st.tier = 0
		end
		broadcast({ newRound = true })
		regenerate()
		refreshMovers()
		while os.clock() < phaseEnds do
			broadcast()
			task.wait(0.5)
		end

		phase = "RIDING"
		phaseEnds = os.clock() + C.ROUND_TIME
		for plr, st in pairs(state) do
			st.alive = true
			st.dist = 0
			st.startedAt = os.clock()
	st.lastUpdate = os.clock()
	st.spam = 0
			readyCharacter(plr)
		end
		broadcast({ go = true })

		while os.clock() < phaseEnds do
			broadcast()
			task.wait(0.4)
			if next(state) ~= nil and aliveCount() == 0 then
				task.wait(2.5)
				break
			end
		end

		-- settle anyone who survived to the end of the round: they earned it
		for plr, st in pairs(state) do
			if st.alive then
				finishRun(plr, "roundEnd")
			end
		end
		phase = "RESULTS"
		phaseEnds = os.clock() + 5
		for _, st in pairs(state) do st.alive = false end
		broadcast({ results = true })
		task.wait(5)
	end
end)

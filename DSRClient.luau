--!strict
-- DON'T STOP RIDING :: client (bike sim + camera + HUD)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local C = require(RS:WaitForChild("DSRConfig"))
local Audio = require(RS:WaitForChild("DSRAudio"))
local Remotes = RS:WaitForChild("DSRRemotes")
local RE_State = Remotes:WaitForChild("State") :: RemoteEvent
local RE_Progress = Remotes:WaitForChild("Progress") :: RemoteEvent
local RE_Crash = Remotes:WaitForChild("Crash") :: RemoteEvent
local RE_Restart = Remotes:WaitForChild("Restart") :: RemoteEvent
local RE_Profile = Remotes:WaitForChild("Profile") :: RemoteEvent
local RE_Shop = Remotes:WaitForChild("Shop") :: RemoteEvent
local RE_Chal = Remotes:WaitForChild("Challenges") :: RemoteEvent
local RE_Settings = Remotes:WaitForChild("Settings") :: RemoteEvent
local RE_Board = Remotes:WaitForChild("Board") :: RemoteEvent
local RE_Revive = Remotes:WaitForChild("Revive") :: RemoteEvent

local plr = Players.LocalPlayer
local cam = workspace.CurrentCamera

------------------------------------------------------------------ sim state
local sim = {
	x = 0, z = 0, y = C.RIDE_HEIGHT,
	vy = 0, speed = C.BASE_SPEED, lateralV = 0,
	airborne = false, airTime = 0, lastSlope = 0,
	tier = 0, momentum = 0,
	stun = 0, onIce = false,
	alive = false, dist = 0,
}
local credited: { [Instance]: boolean } = {}
local shake = 0
local phase = "INTERMISSION"
local phaseTime = 0
local board = {}

local function tierFloor(t) return t * C.MOM_PER_TIER end
local function targetSpeed() return C.BASE_SPEED + sim.tier * C.TIER_SPEED end

------------------------------------------------------------------ raycast params
local Track = workspace:WaitForChild("DSRTrack")
local Ground = Track:WaitForChild("Ground")
local Hazards = Track:WaitForChild("Hazards")

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.FilterDescendantsInstances = { Ground }

local hazParams = OverlapParams.new()
hazParams.FilterType = Enum.RaycastFilterType.Include
hazParams.FilterDescendantsInstances = { Hazards }
hazParams.MaxParts = 24

------------------------------------------------------------------ input
local input = { throttle = 0, brake = 0, steer = 0, jump = false }
local keys = {}
local isTouch = UIS.TouchEnabled and not UIS.KeyboardEnabled
-- Studio-only harness so automated QA can drive the sim without a real keyboard.
-- Never active in a live game.
local TEST_HOOKS = RunService:IsStudio()
local onConfirm: (() -> ())? = nil

UIS.InputBegan:Connect(function(io, gp)
	if gp then return end
	keys[io.KeyCode] = true
	if io.KeyCode == Enum.KeyCode.Space or io.KeyCode == Enum.KeyCode.ButtonA then
		if onConfirm then onConfirm() end
		input.jump = true
	end
end)
UIS.InputEnded:Connect(function(io)
	keys[io.KeyCode] = nil
end)

local function readInput()
	local t, b, s = 0, 0, 0
	if keys[Enum.KeyCode.W] or keys[Enum.KeyCode.Up] then t = 1 end
	if keys[Enum.KeyCode.S] or keys[Enum.KeyCode.Down] then b = 1 end
	if keys[Enum.KeyCode.A] or keys[Enum.KeyCode.Left] then s -= 1 end
	if keys[Enum.KeyCode.D] or keys[Enum.KeyCode.Right] then s += 1 end
	-- gamepad
	for _, g in ipairs(UIS:GetGamepadState(Enum.UserInputType.Gamepad1)) do
		if g.KeyCode == Enum.KeyCode.Thumbstick1 and g.Position.Magnitude > 0.15 then
			s += g.Position.X
		elseif g.KeyCode == Enum.KeyCode.ButtonR2 then
			t = math.max(t, g.Position.Z)
		elseif g.KeyCode == Enum.KeyCode.ButtonL2 then
			b = math.max(b, g.Position.Z)
		end
	end
	if TEST_HOOKS then
		local ts = plr:GetAttribute("DSR_IN_STEER")
		if typeof(ts) == "number" then s += ts end
		local tt = plr:GetAttribute("DSR_IN_THROTTLE")
		if typeof(tt) == "number" then t = math.max(t, tt) end
		local tb = plr:GetAttribute("DSR_IN_BRAKE")
		if typeof(tb) == "number" then b = math.max(b, tb) end
		local m = plr:GetAttribute("DSR_IN_MOM")
		if typeof(m) == "number" and m >= 0 then
			plr:SetAttribute("DSR_IN_MOM", -1)
			sim.momentum = m
			sim.tier = math.min(C.MAX_TIER, math.floor(m / C.MOM_PER_TIER))
		end
		local warp = plr:GetAttribute("DSR_IN_WARP")
		if typeof(warp) == "number" and warp > 0 then
			plr:SetAttribute("DSR_IN_WARP", 0)
			sim.x = warp
			sim.y = C.RIDE_HEIGHT + 4
			sim.airborne = true
			sim.vy = 0
		end
		if plr:GetAttribute("DSR_IN_JUMP") == true then
			plr:SetAttribute("DSR_IN_JUMP", false)
			input.jump = true
		end
	end
	input.throttle = math.clamp(t + (input.touchThrottle or 0), 0, 1)
	input.brake = math.clamp(b + (input.touchBrake or 0), 0, 1)
	input.steer = math.clamp(s + (input.touchSteer or 0), -1, 1)
end

------------------------------------------------------------------ HUD
local gui = Instance.new("ScreenGui")
gui.Name = "DSRHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = plr:WaitForChild("PlayerGui")

-- One UIScale drives the whole HUD so phone and desktop both read correctly.
local hudScale = Instance.new("UIScale")
hudScale.Parent = gui

local function applyHudScale()
	local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
	if not vp or vp.Y <= 0 then return end
	hudScale.Scale = math.clamp(0.55 + vp.Y / 900, 0.95, 1.9)
end

applyHudScale()
if workspace.CurrentCamera then
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(applyHudScale)
end
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	if workspace.CurrentCamera then
		applyHudScale()
		workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(applyHudScale)
	end
end)

local function new(cls, props, parent)
	local o = Instance.new(cls)
	for k, v in pairs(props) do (o :: any)[k] = v end
	o.Parent = parent
	return o
end

-- Resolves panels by name at call time, so this can be declared before any of
-- them exist. Keeps overlay exclusivity independent of block ordering.
local OVERLAY_NAMES = { "ShopPanel", "ChalPanel" }
local function closeOverlays(keepName)
	for _, n in ipairs(OVERLAY_NAMES) do
		local o = gui:FindFirstChild(n)
		if o and n ~= keepName then o.Visible = false end
	end
end

-- forward declarations: assigned in the VFX block further down
local ensureVfx: ((BasePart) -> ())? = nil
local burst: ((Color3, number) -> ())? = nil

local dsrRunClock = 0
local dsrCombo = 0
local dsrComboLast = 0
local dsrComboLabel = nil
local dsrComboReset  -- assigned in the combo block below
local dsrPaceLabel = nil
local dsrLevelLabel = nil
local dsrLastGate = 0
local hudPulse = 0
local leanSmooth = 0

-- SMOOTHING: exponential decay is framerate-independent, unlike dt*k which
-- over-damps at low fps and snaps at high fps.
local function smooth(dt: number, rate: number): number
	return 1 - math.exp(-rate * dt)
end
local dsrBlur = nil
local dsrSpeedLines = nil
local dsrHitFlash = nil
local dsrCoinLayer = nil
local dsrBestLabel = nil
local dsrRecordFired = false
local dsrGhostX = 0

-- forward declaration: assigned in the ghost-rider block further down
local dsrGhostFinish: ((number) -> ())? = nil

-- Roblox's built-in character sounds, all parented to HumanoidRootPart
local DEFAULT_CHAR_SOUNDS = {
	Running = true, Walking = true, FreeFalling = true, Landing = true,
	Jumping = true, GettingUp = true, Climbing = true, Swimming = true,
	Splash = true, Died = true,
}

local FONT = Enum.Font.GothamBlack
local FONT2 = Enum.Font.GothamBold

-- distance / speed cluster (top centre)
local top = new("Frame", {
	BackgroundTransparency = 1,
	Size = UDim2.new(0, 420, 0, 130),
	Position = UDim2.new(0.5, -210, 0, 14),
}, gui)

-- HUD POLISH: shadow layer behind the distance readout. TextStroke alone
-- disappears against bright biomes (Desert, Ice); an offset dark copy holds
-- legibility on every background.
local distShadow = new("TextLabel", {
	BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 66),
	Position = UDim2.new(0, 2, 0, 3),
	Font = FONT, Text = "0m", TextColor3 = Color3.fromRGB(0, 0, 0),
	TextTransparency = 0.55, TextScaled = true, ZIndex = 1,
}, top)

local distLabel = new("TextLabel", {
	BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 66),
	Font = FONT, Text = "0m", TextColor3 = Color3.new(1,1,1),
	TextScaled = true, TextStrokeTransparency = 0.35, ZIndex = 2,
}, top)

local speedLabel = new("TextLabel", {
	BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30),
	Position = UDim2.new(0, 0, 0, 66),
	Font = FONT2, Text = "0 KM/H", TextColor3 = Color3.fromRGB(190, 205, 225),
	TextScaled = true, TextStrokeTransparency = 0.7,
}, top)

-- momentum bar
local barBG = new("Frame", {
	Size = UDim2.new(0, 320, 0, 14), Position = UDim2.new(0.5, -160, 0, 104),
	BackgroundColor3 = Color3.fromRGB(16, 17, 26), BackgroundTransparency = 0.15,
	BorderSizePixel = 0,
}, gui)
new("UICorner", { CornerRadius = UDim.new(1, 0) }, barBG)
new("UIStroke", {
	Color = Color3.fromRGB(70, 78, 96), Thickness = 1.4, Transparency = 0.35,
}, barBG)

local barFill = new("Frame", {
	Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = C.TIER_COLORS[1],
	BorderSizePixel = 0, ZIndex = 2,
}, barBG)
new("UICorner", { CornerRadius = UDim.new(1, 0) }, barFill)
-- gloss across the top half sells it as a filled meter, not a flat rectangle
local barGloss = new("Frame", {
	Size = UDim2.new(1, 0, 0.45, 0), Position = UDim2.new(0, 0, 0, 1),
	BackgroundColor3 = Color3.fromRGB(255, 255, 255), BackgroundTransparency = 0.78,
	BorderSizePixel = 0, ZIndex = 3,
}, barFill)
new("UICorner", { CornerRadius = UDim.new(1, 0) }, barGloss)
-- bright cap at the leading edge so charging is visible at a glance
local barTip = new("Frame", {
	Size = UDim2.new(0, 4, 1, 0), Position = UDim2.new(1, -4, 0, 0),
	BackgroundColor3 = Color3.fromRGB(255, 255, 255), BackgroundTransparency = 0.25,
	BorderSizePixel = 0, ZIndex = 4,
}, barFill)
new("UICorner", { CornerRadius = UDim.new(1, 0) }, barTip)
-- tier boundary ticks: shows how close the next tier is
for i = 1, C.MAX_TIER - 1 do
	new("Frame", {
		Name = "Tick", Size = UDim2.new(0, 2, 0.55, 0),
		Position = UDim2.new(i / C.MAX_TIER, -1, 0.225, 0),
		BackgroundColor3 = Color3.fromRGB(120, 130, 150), BackgroundTransparency = 0.45,
		BorderSizePixel = 0, ZIndex = 5,
	}, barBG)
end
local tierLabel = new("TextLabel", {
	BackgroundTransparency = 1, Size = UDim2.new(0, 300, 0, 22),
	Position = UDim2.new(0.5, -150, 0, 119),
	Font = FONT, Text = "", TextColor3 = Color3.new(1,1,1),
	TextScaled = true, TextStrokeTransparency = 0.5,
}, gui)

-- position / leaderboard (top right)
local boardFrame = new("Frame", {
	BackgroundColor3 = Color3.fromRGB(12, 13, 21), BackgroundTransparency = 0.28,
	Size = UDim2.new(0, 182, 0, 124), Position = UDim2.new(1, -192, 0, 10),
	BorderSizePixel = 0,
}, gui)
new("UICorner", { CornerRadius = UDim.new(0, 12) }, boardFrame)
new("UIStroke", { Color = Color3.fromRGB(88, 96, 118), Thickness = 1.2, Transparency = 0.55 }, boardFrame)
new("UIGradient", {
	Color = ColorSequence.new(Color3.fromRGB(46, 50, 70), Color3.fromRGB(12, 13, 21)),
	Rotation = 90,
}, boardFrame)
-- header so the panel reads as a leaderboard, not an unlabelled box
new("TextLabel", {
	Name = "BoardTitle", BackgroundTransparency = 1,
	Size = UDim2.new(1, -12, 0, 15), Position = UDim2.new(0, 8, 0, 4),
	Font = FONT2, Text = "LEADERBOARD", TextColor3 = Color3.fromRGB(140, 150, 175),
	TextScaled = true, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 2,
}, boardFrame)
local miniBoardList = new("Frame", {
	BackgroundTransparency = 1, Size = UDim2.new(1, -12, 1, -26), Position = UDim2.new(0, 6, 0, 21),
}, boardFrame)
new("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, miniBoardList)

-- centre message (countdown / max momentum / crash)
local centre = new("TextLabel", {
	BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 150),
	Position = UDim2.new(0, 0, 0.34, 0), Font = FONT, Text = "",
	TextColor3 = Color3.new(1,1,1), TextScaled = true, TextStrokeTransparency = 0.35,
}, gui)
new("UITextSizeConstraint", { MaxTextSize = 54 }, centre)

-- crash panel
local crashPanel = new("Frame", {
	BackgroundColor3 = Color3.fromRGB(10, 10, 18), BackgroundTransparency = 0.15,
	Size = UDim2.new(0, 340, 0, 300), Position = UDim2.new(0.5, -170, 0.5, -150),
	BorderSizePixel = 0, Visible = false, ZIndex = 3,
}, gui)
new("UICorner", { CornerRadius = UDim.new(0, 16) }, crashPanel)
local crashPanelStroke = new("UIStroke", {
	Color = Color3.fromRGB(96, 104, 128), Thickness = 1.6, Transparency = 0.4,
}, crashPanel)
new("UIGradient", {
	Color = ColorSequence.new(Color3.fromRGB(34, 36, 52), Color3.fromRGB(10, 10, 18)),
	Rotation = 90,
}, crashPanel)
local crashTitle = new("TextLabel", {
	BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 44), Position = UDim2.new(0, 0, 0, 16),
	Font = FONT, Text = "CRASHED", TextColor3 = Color3.fromRGB(255, 96, 92), TextScaled = true,
}, crashPanel)
local crashDist = new("TextLabel", {
	BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 62), Position = UDim2.new(0, 0, 0, 68),
	Font = FONT, Text = "0m", TextColor3 = Color3.new(1,1,1), TextScaled = true,
}, crashPanel)
local crashReason = new("TextLabel", {
	Name = "CrashReason",
	BackgroundTransparency = 1, Size = UDim2.new(1, -24, 0, 22), Position = UDim2.new(0, 12, 0, 108),
	Font = FONT2, Text = "", TextColor3 = Color3.fromRGB(170, 185, 205),
	TextScaled = true, ZIndex = 4,
}, crashPanel)
new("UITextSizeConstraint", { MaxTextSize = 18 }, crashReason)

local crashBest = new("TextLabel", {
	BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28), Position = UDim2.new(0, 0, 0, 136),
	Font = FONT2, Text = "BEST 0m", TextColor3 = Color3.fromRGB(190, 205, 225), TextScaled = true,
}, crashPanel)
local crashRecord = new("TextLabel", {
	BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), Position = UDim2.new(0, 0, 0, 170),
	Font = FONT, Text = "", TextColor3 = Color3.fromRGB(255, 220, 110), TextScaled = true,
}, crashPanel)
local crashCoins = new("TextLabel", {
	BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26), Position = UDim2.new(0, 0, 0, 200),
	Font = FONT2, Text = "", TextColor3 = Color3.fromRGB(255, 220, 110), TextScaled = true,
}, crashPanel)

local crashNext = new("TextLabel", {
	BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), Position = UDim2.new(0, 0, 1, -56),
	Font = FONT2, Text = "NEXT RIDE SOON", TextColor3 = Color3.fromRGB(120, 240, 255), TextScaled = true,
}, crashPanel)

local rideAgain = new("TextButton", {
	Name = "RideAgain",
	Size = UDim2.new(1, -48, 0, 56), Position = UDim2.new(0, 24, 1, -72),
	BackgroundColor3 = Color3.fromRGB(120, 255, 170), AutoButtonColor = false,
	Text = "RIDE AGAIN", TextColor3 = Color3.fromRGB(8, 20, 14),
	Font = FONT, TextScaled = true, BorderSizePixel = 0, Visible = false,
}, crashPanel)
new("UICorner", { CornerRadius = UDim.new(0, 12) }, rideAgain)

local function requestRestart()
	if not rideAgain.Visible then return end
	rideAgain.Visible = false
	crashNext.Visible = true
	RE_Restart:FireServer()
end
rideAgain.Activated:Connect(requestRestart)
onConfirm = requestRestart
local coinFrame = new("Frame", {
	BackgroundColor3 = Color3.fromRGB(14, 15, 24), BackgroundTransparency = 0.35,
	Size = UDim2.new(0, 118, 0, 34), Position = UDim2.new(0, 12, 0, 10), BorderSizePixel = 0,
}, gui)
new("UICorner", { CornerRadius = UDim.new(0, 10) }, coinFrame)
new("UIStroke", { Color = Color3.fromRGB(120, 100, 50), Thickness = 1.2, Transparency = 0.5 }, coinFrame)
new("UIGradient", {
	Color = ColorSequence.new(Color3.fromRGB(44, 40, 28), Color3.fromRGB(14, 15, 22)),
	Rotation = 90,
}, coinFrame)
local coinAccent = new("Frame", {
	Name = "CoinAccent", Size = UDim2.new(0, 3, 0.6, 0), Position = UDim2.new(0, 0, 0.2, 0),
	BackgroundColor3 = Color3.fromRGB(255, 220, 110), BorderSizePixel = 0, ZIndex = 2,
}, coinFrame)
local coinLabel = new("TextLabel", {
	BackgroundTransparency = 1, Size = UDim2.new(1, -16, 1, -10), Position = UDim2.new(0, 8, 0, 5),
	Font = FONT, Text = "0", TextColor3 = Color3.fromRGB(255, 220, 110),
	TextScaled = true, TextXAlignment = Enum.TextXAlignment.Left,
}, coinFrame)

local function commas(n: number): string
	local s = tostring(math.floor(n))
	local k
	repeat
		s, k = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
	until k == 0
	return s
end


------------------------------------------------------------------ shop
local myProfile = nil
local equippedTrail = C.BIKES[1].trail

local shopBtn = new("TextButton", {
	Name = "ShopBtn",
	Size = UDim2.new(0, 104, 0, 40), Position = UDim2.new(0, 12, 0, 50),
	BackgroundColor3 = Color3.fromRGB(120, 240, 255), AutoButtonColor = false,
	Text = "BIKES", TextColor3 = Color3.fromRGB(8, 18, 24),
	Font = FONT, TextScaled = true, BorderSizePixel = 0,
}, gui)
new("UICorner", { CornerRadius = UDim.new(0, 10) }, shopBtn)

local shopPanel = new("Frame", {
	Name = "ShopPanel", Visible = false,
	BackgroundColor3 = Color3.fromRGB(10, 11, 20), BackgroundTransparency = 0.06,
	Size = UDim2.new(0, 380, 0, 356), Position = UDim2.new(0.5, -190, 0.5, -178),
	BorderSizePixel = 0, ZIndex = 5,
}, gui)
new("UICorner", { CornerRadius = UDim.new(0, 16) }, shopPanel)

new("TextLabel", {
	BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), Position = UDim2.new(0, 0, 0, 12),
	Font = FONT, Text = "BIKES", TextColor3 = Color3.new(1,1,1), TextScaled = true, ZIndex = 6,
}, shopPanel)

local shopMsg = new("TextLabel", {
	BackgroundTransparency = 1, Size = UDim2.new(1, -24, 0, 22), Position = UDim2.new(0, 12, 0, 52),
	Font = FONT2, Text = "", TextColor3 = Color3.fromRGB(255, 220, 110), TextScaled = true, ZIndex = 6,
}, shopPanel)

local closeBtn = new("TextButton", {
	Size = UDim2.new(0, 44, 0, 44), Position = UDim2.new(1, -54, 0, 10),
	BackgroundColor3 = Color3.fromRGB(60, 30, 40), AutoButtonColor = false,
	Text = "X", TextColor3 = Color3.new(1,1,1), Font = FONT, TextScaled = true,
	BorderSizePixel = 0, ZIndex = 6,
}, shopPanel)
new("UICorner", { CornerRadius = UDim.new(0, 10) }, closeBtn)

local list = new("ScrollingFrame", {
	BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 6,
	Size = UDim2.new(1, -24, 1, -96), Position = UDim2.new(0, 12, 0, 82),
	CanvasSize = UDim2.new(0, 0, 0, 0), ScrollBarThickness = 5,
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, shopPanel)
new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, list)

local shopTab = "bike"
local refreshShop   -- forward declaration: tab buttons close over this

local eventBanner = new("TextLabel", {
	BackgroundColor3 = Color3.fromRGB(40, 34, 70), BackgroundTransparency = 0.15,
	Size = UDim2.new(1, -24, 0, 30), Position = UDim2.new(0, 12, 0, 74),
	Font = FONT2, Text = "", TextColor3 = Color3.fromRGB(190, 205, 255),
	TextScaled = true, BorderSizePixel = 0, Visible = false, ZIndex = 7,
}, shopPanel)
new("UICorner", { CornerRadius = UDim.new(0, 8) }, eventBanner)

local function mkTab(text, key, x)
	local b = new("TextButton", {
		Size = UDim2.new(0, 120, 0, 38), Position = UDim2.new(0, x, 0, 108),
		BackgroundColor3 = Color3.fromRGB(30, 33, 48), AutoButtonColor = false,
		Text = text, TextColor3 = Color3.new(1,1,1), Font = FONT,
		TextScaled = true, BorderSizePixel = 0, ZIndex = 7,
	}, shopPanel)
	new("UICorner", { CornerRadius = UDim.new(0, 9) }, b)
	b.Activated:Connect(function()
		shopTab = key
		refreshShop()
	end)
	return b
end
local tabBike = mkTab("BIKES", "bike", 12)
local tabTrail = mkTab("TRAILS", "trail", 140)

local rowPool = {}

function refreshShop()
	local p = myProfile
	tabBike.BackgroundColor3 = shopTab == "bike" and Color3.fromRGB(120, 240, 255) or Color3.fromRGB(30, 33, 48)
	tabBike.TextColor3 = shopTab == "bike" and Color3.fromRGB(8, 18, 24) or Color3.new(1, 1, 1)
	tabTrail.BackgroundColor3 = shopTab == "trail" and Color3.fromRGB(120, 240, 255) or Color3.fromRGB(30, 33, 48)
	tabTrail.TextColor3 = shopTab == "trail" and Color3.fromRGB(8, 18, 24) or Color3.new(1, 1, 1)

	if C.eventActive() then
		local d = math.floor(C.eventSecondsLeft() / 86400)
		local h = math.floor((C.eventSecondsLeft() % 86400) / 3600)
		eventBanner.Visible = true
		eventBanner.Text = C.EVENT.name .. " - " .. d .. "d " .. h .. "h LEFT"
	else
		eventBanner.Visible = false
	end

	for _, r in ipairs(rowPool) do r.frame:Destroy() end
	table.clear(rowPool)

	local defs = (shopTab == "trail") and C.TRAILS or C.BIKES
	local ownedSet = (shopTab == "trail") and (p and p.trails) or (p and p.bikes)
	local equippedId = (shopTab == "trail") and (p and p.equippedTrail or "t_stock") or (p and p.equippedBike or "starter")

	for i, item in ipairs(defs) do
		local locked = item.event and not C.eventActive()
		local owned = ownedSet and ownedSet[item.id]
		if locked and not owned then
			-- event over and never bought: hide rather than tease
		else
			local row = new("Frame", {
				Size = UDim2.new(1, -6, 0, 62), BackgroundColor3 = Color3.fromRGB(22, 24, 36),
				BorderSizePixel = 0, LayoutOrder = i, ZIndex = 6,
			}, list)
			new("UICorner", { CornerRadius = UDim.new(0, 10) }, row)
			new("Frame", {
				Size = UDim2.new(0, 8, 1, -16), Position = UDim2.new(0, 10, 0, 8),
				BackgroundColor3 = item.frame or item.color, BorderSizePixel = 0, ZIndex = 7,
			}, row)
			new("TextLabel", {
				BackgroundTransparency = 1, Size = UDim2.new(0, 190, 0, 26), Position = UDim2.new(0, 28, 0, 8),
				Font = FONT, Text = item.name .. (item.event and "  \u{2726}" or ""),
				TextColor3 = item.event and Color3.fromRGB(190, 205, 255) or Color3.new(1,1,1),
				TextScaled = true, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 7,
			}, row)
			local sub = new("TextLabel", {
				BackgroundTransparency = 1, Size = UDim2.new(0, 190, 0, 20), Position = UDim2.new(0, 28, 0, 34),
				Font = FONT2, Text = "", TextColor3 = Color3.fromRGB(170, 180, 200), TextScaled = true,
				TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 7,
			}, row)
			local act = new("TextButton", {
				Size = UDim2.new(0, 104, 0, 44), Position = UDim2.new(1, -114, 0, 9),
				AutoButtonColor = false, TextColor3 = Color3.fromRGB(8, 20, 14),
				Font = FONT, TextScaled = true, BorderSizePixel = 0, ZIndex = 7, Text = "BUY",
				BackgroundColor3 = Color3.fromRGB(120, 255, 170),
			}, row)
			new("UICorner", { CornerRadius = UDim.new(0, 9) }, act)

			if equippedId == item.id then
				sub.Text = "EQUIPPED"; act.Text = "EQUIPPED"
				act.BackgroundColor3 = Color3.fromRGB(70, 80, 95)
			elseif owned then
				sub.Text = "Owned"; act.Text = "EQUIP"
				act.BackgroundColor3 = Color3.fromRGB(120, 240, 255)
			else
				sub.Text = commas(item.price) .. " coins" .. (item.event and "  (LIMITED)" or "")
				act.Text = "BUY"
				local afford = p and (p.coins or 0) >= item.price
				act.BackgroundColor3 = afford and Color3.fromRGB(120, 255, 170) or Color3.fromRGB(70, 60, 65)
			end

			local cat = shopTab
			act.Activated:Connect(function()
				local isOwned = ownedSet and ownedSet[item.id]
				RE_Shop:FireServer(isOwned and "equip" or "buy", item.id, cat)
			end)
			table.insert(rowPool, { frame = row })
		end
	end
end

shopBtn.Activated:Connect(function()
	shopPanel.Visible = not shopPanel.Visible
	closeOverlays(shopPanel.Visible and "ShopPanel" or nil)
	if shopPanel.Visible then refreshShop() end
end)
closeBtn.Activated:Connect(function() shopPanel.Visible = false end)

RE_Shop.OnClientEvent:Connect(function(ok, msg)
	shopMsg.Text = tostring(msg)
	shopMsg.TextColor3 = ok and Color3.fromRGB(120, 255, 170) or Color3.fromRGB(255, 130, 130)
	Audio.play(ok and "tierUp" or "hit", ok and 1.3 or 1)
	task.delay(2.5, function()
		if shopMsg.Text == tostring(msg) then shopMsg.Text = "" end
	end)
end)

------------------------------------------------------------------ challenges
local chalBtn = new("TextButton", {
	Name = "ChalBtn",
	Size = UDim2.new(0, 104, 0, 40), Position = UDim2.new(0, 12, 0, 96),
	BackgroundColor3 = Color3.fromRGB(255, 220, 110), AutoButtonColor = false,
	Text = "GOALS", TextColor3 = Color3.fromRGB(26, 20, 6),
	Font = FONT, TextScaled = true, BorderSizePixel = 0,
}, gui)
new("UICorner", { CornerRadius = UDim.new(0, 10) }, chalBtn)

local chalPanel = new("Frame", {
	Name = "ChalPanel", Visible = false,
	BackgroundColor3 = Color3.fromRGB(10, 11, 20), BackgroundTransparency = 0.06,
	Size = UDim2.new(0, 380, 0, 356), Position = UDim2.new(0.5, -190, 0.5, -178),
	BorderSizePixel = 0, ZIndex = 5,
}, gui)
new("UICorner", { CornerRadius = UDim.new(0, 16) }, chalPanel)
new("TextLabel", {
	BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), Position = UDim2.new(0, 0, 0, 12),
	Font = FONT, Text = "GOALS", TextColor3 = Color3.new(1,1,1), TextScaled = true, ZIndex = 6,
}, chalPanel)
local chalClose = new("TextButton", {
	Size = UDim2.new(0, 44, 0, 44), Position = UDim2.new(1, -54, 0, 10),
	BackgroundColor3 = Color3.fromRGB(60, 30, 40), AutoButtonColor = false,
	Text = "X", TextColor3 = Color3.new(1,1,1), Font = FONT, TextScaled = true,
	BorderSizePixel = 0, ZIndex = 6,
}, chalPanel)
new("UICorner", { CornerRadius = UDim.new(0, 10) }, chalClose)

local chalList = new("ScrollingFrame", {
	BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 6,
	Size = UDim2.new(1, -24, 1, -70), Position = UDim2.new(0, 12, 0, 58),
	CanvasSize = UDim2.new(0, 0, 0, 0), ScrollBarThickness = 5,
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, chalPanel)
new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, chalList)

local function buildChalRows(snapshot)
	for _, ch in ipairs(chalList:GetChildren()) do
		if not ch:IsA("UIListLayout") then ch:Destroy() end
	end
	local order = 0
	local function section(title, items)
		order += 1
		new("TextLabel", {
			BackgroundTransparency = 1, Size = UDim2.new(1, -6, 0, 26), LayoutOrder = order,
			Font = FONT, Text = title, TextColor3 = Color3.fromRGB(120, 240, 255),
			TextScaled = true, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 7,
		}, chalList)
		for _, it in ipairs(items) do
			order += 1
			local row = new("Frame", {
				Size = UDim2.new(1, -6, 0, 54), BackgroundColor3 = Color3.fromRGB(22, 24, 36),
				BorderSizePixel = 0, LayoutOrder = order, ZIndex = 6,
			}, chalList)
			new("UICorner", { CornerRadius = UDim.new(0, 10) }, row)
			new("TextLabel", {
				BackgroundTransparency = 1, Size = UDim2.new(1, -100, 0, 22), Position = UDim2.new(0, 12, 0, 6),
				Font = FONT2, Text = it.text, TextColor3 = Color3.new(1,1,1), TextScaled = true,
				TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 7,
			}, row)
			local pct = math.clamp(it.have / math.max(it.target, 1), 0, 1)
			local barBg = new("Frame", {
				Size = UDim2.new(1, -110, 0, 10), Position = UDim2.new(0, 12, 0, 33),
				BackgroundColor3 = Color3.fromRGB(38, 40, 55), BorderSizePixel = 0, ZIndex = 7,
			}, row)
			new("UICorner", { CornerRadius = UDim.new(1, 0) }, barBg)
			local fill = new("Frame", {
				Size = UDim2.new(pct, 0, 1, 0), BorderSizePixel = 0, ZIndex = 8,
				BackgroundColor3 = it.done and Color3.fromRGB(120, 255, 170) or Color3.fromRGB(255, 220, 110),
			}, barBg)
			new("UICorner", { CornerRadius = UDim.new(1, 0) }, fill)
			new("TextLabel", {
				BackgroundTransparency = 1, Size = UDim2.new(0, 88, 1, -10), Position = UDim2.new(1, -94, 0, 5),
				Font = FONT, TextScaled = true, ZIndex = 7,
				Text = it.done and "DONE" or (commas(it.have) .. "/" .. commas(it.target)),
				TextColor3 = it.done and Color3.fromRGB(120, 255, 170) or Color3.fromRGB(190, 200, 220),
			}, row)
		end
	end
	section("DAILY", snapshot.daily or {})
	section("WEEKLY", snapshot.weekly or {})
end

chalBtn.Activated:Connect(function()
	chalPanel.Visible = not chalPanel.Visible
	closeOverlays(chalPanel.Visible and "ChalPanel" or nil)
	if chalPanel.Visible then RE_Chal:FireServer() end
end)
chalClose.Activated:Connect(function() chalPanel.Visible = false end)

-- completion toast
local toast = new("TextLabel", {
	BackgroundColor3 = Color3.fromRGB(20, 40, 30), BackgroundTransparency = 0.15,
	Size = UDim2.new(0, 320, 0, 46), Position = UDim2.new(0.5, -160, 0, 170),
	Font = FONT, Text = "", TextColor3 = Color3.fromRGB(120, 255, 170),
	TextScaled = true, Visible = false, BorderSizePixel = 0, ZIndex = 9,
}, gui)
new("UICorner", { CornerRadius = UDim.new(0, 10) }, toast)

RE_Chal.OnClientEvent:Connect(function(p)
	if type(p) ~= "table" then return end
	if p.snapshot then buildChalRows(p.snapshot) end
	if p.completed then
		task.spawn(function()
			for _, done in ipairs(p.completed) do
				toast.Text = done.label .. " DONE  +" .. commas(done.reward)
				toast.Visible = true
				Audio.play("tierUp", 1.4)
				task.wait(2.2)
			end
			toast.Visible = false
		end)
	end
end)
------------------------------------------------------------------ onboarding
-- Shown only for a player's first few rides. Device-aware, because telling a
-- phone player to "press SPACE" is worse than saying nothing.
local hintLabel = new("TextLabel", {
	Name = "Hint",
	BackgroundColor3 = Color3.fromRGB(12, 14, 24), BackgroundTransparency = 0.25,
	Size = UDim2.new(0, 330, 0, 38), Position = UDim2.new(0.5, -165, 0, 146),
	Font = FONT, Text = "", TextColor3 = Color3.fromRGB(120, 240, 255),
	TextScaled = true, Visible = false, BorderSizePixel = 0, ZIndex = 9,
}, gui)
new("UICorner", { CornerRadius = UDim.new(0, 10) }, hintLabel)

local hintQueue = {}
local hintShown = {}
local hintBusy = false

local function showHint(key: string, text: string, seconds: number?)
	if hintShown[key] then return end
	hintShown[key] = true
	table.insert(hintQueue, { text = text, secs = seconds or 3.2 })
end

task.spawn(function()
	while true do
		if #hintQueue > 0 and not hintBusy then
			hintBusy = true
			local h = table.remove(hintQueue, 1)
			hintLabel.Text = h.text
			hintLabel.Visible = true
			task.wait(h.secs)
			hintLabel.Visible = false
			task.wait(0.35)
			hintBusy = false
		end
		task.wait(0.15)
	end
end)

local function tutorialActive(): boolean
	-- first three rides only; after that the player has seen everything
	return not myProfile or (myProfile.runs or 0) < 3
end

local steerHint = isTouch and "USE < > TO STEER" or "A / D TO STEER"
local jumpHint  = isTouch and "TAP JUMP TO CLEAR GAPS" or "SPACE TO JUMP"
------------------------------------------------------------------ settings
local prefs = { shake = true, sfx = 1, music = 1 }

local setBtn = new("TextButton", {
	Name = "SetBtn",
	Size = UDim2.new(0, 116, 0, 44), Position = UDim2.new(0, 14, 0, 158),
	BackgroundColor3 = Color3.fromRGB(70, 78, 98), AutoButtonColor = false,
	Text = "SETTINGS", TextColor3 = Color3.new(1,1,1),
	Font = FONT, TextScaled = true, BorderSizePixel = 0,
}, gui)
new("UICorner", { CornerRadius = UDim.new(0, 10) }, setBtn)

local setPanel = new("Frame", {
	Name = "SetPanel", Visible = false,
	BackgroundColor3 = Color3.fromRGB(10, 11, 20), BackgroundTransparency = 0.06,
	Size = UDim2.new(0, 360, 0, 250), Position = UDim2.new(0.5, -180, 0.5, -125),
	BorderSizePixel = 0, ZIndex = 5,
}, gui)
new("UICorner", { CornerRadius = UDim.new(0, 16) }, setPanel)
new("TextLabel", {
	BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 38), Position = UDim2.new(0, 0, 0, 12),
	Font = FONT, Text = "SETTINGS", TextColor3 = Color3.new(1,1,1), TextScaled = true, ZIndex = 6,
}, setPanel)
local setClose = new("TextButton", {
	Size = UDim2.new(0, 44, 0, 44), Position = UDim2.new(1, -54, 0, 10),
	BackgroundColor3 = Color3.fromRGB(60, 30, 40), AutoButtonColor = false,
	Text = "X", TextColor3 = Color3.new(1,1,1), Font = FONT, TextScaled = true,
	BorderSizePixel = 0, ZIndex = 6,
}, setPanel)
new("UICorner", { CornerRadius = UDim.new(0, 10) }, setClose)

local function toggleRow(y, label, key, cycle)
	new("TextLabel", {
		BackgroundTransparency = 1, Size = UDim2.new(0, 180, 0, 44), Position = UDim2.new(0, 18, 0, y),
		Font = FONT2, Text = label, TextColor3 = Color3.new(1,1,1), TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 6,
	}, setPanel)
	local b = new("TextButton", {
		Size = UDim2.new(0, 130, 0, 44), Position = UDim2.new(1, -148, 0, y),
		BackgroundColor3 = Color3.fromRGB(120, 240, 255), AutoButtonColor = false,
		Text = "-", TextColor3 = Color3.fromRGB(8, 18, 24), Font = FONT,
		TextScaled = true, BorderSizePixel = 0, ZIndex = 6,
	}, setPanel)
	new("UICorner", { CornerRadius = UDim.new(0, 9) }, b)
	b.Activated:Connect(function()
		local nv = cycle(prefs[key])
		prefs[key] = nv
		RE_Settings:FireServer(key, nv)
	end)
	return b
end

local shakeBtn = toggleRow(70, "SCREEN SHAKE", "shake", function(v) return not v end)
local sfxBtn = toggleRow(126, "SOUND", "sfx", function(v)
	local n = (v or 1) - 0.25
	if n < 0 then n = 1 end
	return n
end)

local function refreshSettings()
	shakeBtn.Text = prefs.shake and "ON" or "OFF"
	shakeBtn.BackgroundColor3 = prefs.shake and Color3.fromRGB(120, 255, 170) or Color3.fromRGB(70, 60, 65)
	sfxBtn.Text = (prefs.sfx or 1) <= 0 and "MUTED" or (math.floor((prefs.sfx or 1) * 100) .. "%")
	sfxBtn.BackgroundColor3 = (prefs.sfx or 1) <= 0 and Color3.fromRGB(70, 60, 65) or Color3.fromRGB(120, 240, 255)
	Audio.setVolumeScale(prefs.sfx or 1)
end

setBtn.Activated:Connect(function()
	setPanel.Visible = not setPanel.Visible
	if setPanel.Visible then refreshSettings() end
end)
setClose.Activated:Connect(function() setPanel.Visible = false end)
refreshSettings()

RE_Profile.OnClientEvent:Connect(function(prof)
	if type(prof) ~= "table" then return end
	myProfile = prof
	if type(prof.settings) == "table" then
		if type(prof.settings.shake) == "boolean" then prefs.shake = prof.settings.shake end
		if type(prof.settings.sfx) == "number" then prefs.sfx = prof.settings.sfx end
		refreshSettings()
	end
	equippedTrail = C.getTrail(prof.equippedTrail).color
	if shopPanel.Visible then refreshShop() end
	coinLabel.Text = commas(prof.coins or 0)
	if dsrLevelLabel then
		dsrLevelLabel.Text = "RIDER LV. " .. C.riderLevel(prof.totalDistance)
	end
	if prof.bestDistance then
		crashBest.Text = "BEST " .. commas(prof.bestDistance) .. "m"
	end
end)
------------------------------------------------------------------ leaderboards
local boardPeriod = "alltime"
local refreshBoard

local boardBtn = new("TextButton", {
	Name = "BoardBtn",
	Size = UDim2.new(0, 116, 0, 44), Position = UDim2.new(0, 14, 0, 208),
	BackgroundColor3 = Color3.fromRGB(190, 160, 255), AutoButtonColor = false,
	Text = "RANKS", TextColor3 = Color3.fromRGB(16, 10, 30),
	Font = FONT, TextScaled = true, BorderSizePixel = 0,
}, gui)
new("UICorner", { CornerRadius = UDim.new(0, 10) }, boardBtn)

local boardPanel = new("Frame", {
	Name = "BoardPanel", Visible = false,
	BackgroundColor3 = Color3.fromRGB(10, 11, 20), BackgroundTransparency = 0.06,
	Size = UDim2.new(0, 380, 0, 430), Position = UDim2.new(0.5, -190, 0.5, -215),
	BorderSizePixel = 0, ZIndex = 5,
}, gui)
new("UICorner", { CornerRadius = UDim.new(0, 16) }, boardPanel)
new("TextLabel", {
	BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 38), Position = UDim2.new(0, 0, 0, 12),
	Font = FONT, Text = "BEST DISTANCE", TextColor3 = Color3.new(1,1,1), TextScaled = true, ZIndex = 6,
}, boardPanel)
local boardClose = new("TextButton", {
	Size = UDim2.new(0, 44, 0, 44), Position = UDim2.new(1, -54, 0, 10),
	BackgroundColor3 = Color3.fromRGB(60, 30, 40), AutoButtonColor = false,
	Text = "X", TextColor3 = Color3.new(1,1,1), Font = FONT, TextScaled = true,
	BorderSizePixel = 0, ZIndex = 6,
}, boardPanel)
new("UICorner", { CornerRadius = UDim.new(0, 10) }, boardClose)

local boardNote = new("TextLabel", {
	BackgroundTransparency = 1, Size = UDim2.new(1, -24, 0, 18), Position = UDim2.new(0, 12, 1, -26),
	Font = FONT2, Text = "", TextColor3 = Color3.fromRGB(140, 150, 175), TextScaled = true, ZIndex = 6,
}, boardPanel)

local boardTabs = {}
local function mkBoardTab(label, key, x)
	local b = new("TextButton", {
		Size = UDim2.new(0, 112, 0, 36), Position = UDim2.new(0, x, 0, 56),
		BackgroundColor3 = Color3.fromRGB(30, 33, 48), AutoButtonColor = false,
		Text = label, TextColor3 = Color3.new(1,1,1), Font = FONT,
		TextScaled = true, BorderSizePixel = 0, ZIndex = 7,
	}, boardPanel)
	new("UICorner", { CornerRadius = UDim.new(0, 9) }, b)
	b.Activated:Connect(function()
		boardPeriod = key
		RE_Board:FireServer(key)
		if refreshBoard then refreshBoard({}) end
	end)
	boardTabs[key] = b
	return b
end
mkBoardTab("ALL TIME", "alltime", 12)
mkBoardTab("TODAY", "daily", 130)
mkBoardTab("WEEK", "weekly", 248)

local boardList = new("ScrollingFrame", {
	BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 6,
	Size = UDim2.new(1, -24, 1, -132), Position = UDim2.new(0, 12, 0, 100),
	CanvasSize = UDim2.new(0, 0, 0, 0), ScrollBarThickness = 5,
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, boardPanel)
new("UIListLayout", { Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder }, boardList)

refreshBoard = function(rows)
	for k, b in pairs(boardTabs) do
		local on = (k == boardPeriod)
		b.BackgroundColor3 = on and Color3.fromRGB(190, 160, 255) or Color3.fromRGB(30, 33, 48)
		b.TextColor3 = on and Color3.fromRGB(16, 10, 30) or Color3.new(1, 1, 1)
	end
	for _, ch in ipairs(boardList:GetChildren()) do
		if not ch:IsA("UIListLayout") then ch:Destroy() end
	end
	if #rows == 0 then
		new("TextLabel", {
			BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 1,
			Font = FONT2, Text = "No rides recorded yet", TextColor3 = Color3.fromRGB(140, 150, 175),
			TextScaled = true, ZIndex = 7,
		}, boardList)
		return
	end
	for i, r in ipairs(rows) do
		local row = new("Frame", {
			Size = UDim2.new(1, -6, 0, 34), BackgroundColor3 = Color3.fromRGB(22, 24, 36),
			BorderSizePixel = 0, LayoutOrder = i, ZIndex = 6,
		}, boardList)
		new("UICorner", { CornerRadius = UDim.new(0, 8) }, row)
		new("TextLabel", {
			BackgroundTransparency = 1, Size = UDim2.new(0, 40, 1, 0), Position = UDim2.new(0, 8, 0, 0),
			Font = FONT, Text = "#" .. i, TextScaled = true, ZIndex = 7,
			TextColor3 = i <= 3 and Color3.fromRGB(255, 220, 110) or Color3.fromRGB(160, 170, 190),
		}, row)
		new("TextLabel", {
			BackgroundTransparency = 1, Size = UDim2.new(1, -170, 1, 0), Position = UDim2.new(0, 52, 0, 0),
			Font = FONT2, Text = r.name, TextColor3 = Color3.new(1,1,1), TextScaled = true,
			TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 7,
		}, row)
		new("TextLabel", {
			BackgroundTransparency = 1, Size = UDim2.new(0, 110, 1, 0), Position = UDim2.new(1, -118, 0, 0),
			Font = FONT, Text = commas(r.score) .. "m", TextColor3 = Color3.fromRGB(120, 240, 255),
			TextScaled = true, TextXAlignment = Enum.TextXAlignment.Right, ZIndex = 7,
		}, row)
	end
end

boardBtn.Activated:Connect(function()
	boardPanel.Visible = not boardPanel.Visible
	if boardPanel.Visible then RE_Board:FireServer(boardPeriod) end
end)
boardClose.Activated:Connect(function() boardPanel.Visible = false end)

RE_Board.OnClientEvent:Connect(function(p)
	if type(p) ~= "table" or p.period ~= boardPeriod then return end
	refreshBoard(p.rows or {})
	boardNote.Text = p.global and "" or "Server-local board (global ranks need a published place)"
end)

------------------------------------------------------------------ mobile controls
-- kill Roblox's built-in touch controls: we supply our own, and having both
-- on screen at once is both confusing and physically overlapping.
-- The control module re-enables itself on respawn and initialises late, so a
-- single Disable() call loses the race. Keep asserting it.
task.spawn(function()
	local controls = nil
	local ok = pcall(function()
		local ps = plr:WaitForChild("PlayerScripts", 10)
		local mod = ps and ps:WaitForChild("PlayerModule", 10)
		if not mod then return end
		local pm = require(mod)
		controls = pm:GetControls()
	end)
	if not ok or not controls then return end

	local function kill()
		pcall(function() controls:Disable() end)
		pcall(function()
			local pg = plr:FindFirstChild("PlayerGui")
			local tg = pg and pg:FindFirstChild("TouchGui")
			if tg then tg.Enabled = false end
		end)
	end

	kill()
	plr.CharacterAdded:Connect(function()
		for _ = 1, 10 do
			task.wait(0.2)
			kill()
		end
	end)
	-- cover late initialisation on first join
	for _ = 1, 40 do
		task.wait(0.25)
		kill()
	end
end)

pcall(function()
	game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
end)

-- Independent of PlayerModule (that require can fail, and previously took the
-- whole disable routine down with it). TouchGui is recreated on respawn, so
-- watch for it rather than disabling once.
local function suppressTouchGui()
	local pg = plr:FindFirstChild("PlayerGui")
	if not pg then return end
	local tg = pg:FindFirstChild("TouchGui")
	if tg and tg:IsA("ScreenGui") and tg.Enabled then
		tg.Enabled = false
	end
end

task.spawn(function()
	local pg = plr:WaitForChild("PlayerGui")
	pg.ChildAdded:Connect(function(ch)
		if ch.Name == "TouchGui" then
			task.wait()
			suppressTouchGui()
		end
	end)
	while true do
		suppressTouchGui()
		task.wait(0.5)
	end
end)


local touchGui
if isTouch then
	local function pad(name, pos, size, color, text)
		local b = new("TextButton", {
			Name = name, Size = size, Position = pos, Text = text,
			BackgroundColor3 = color, BackgroundTransparency = 0.25,
			TextColor3 = Color3.new(1,1,1), Font = FONT, TextScaled = true,
			AutoButtonColor = false, BorderSizePixel = 0,
		}, gui)
		new("UICorner", { CornerRadius = UDim.new(0, 14) }, b)
		new("UITextSizeConstraint", { MaxTextSize = 22 }, b)
		new("UIPadding", {
			PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6),
			PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6),
		}, b)
		return b
	end
	local S = UDim2.new(0, 92, 0, 92)
	-- single bottom row: steering left, drive controls right. nothing stacks
	-- upward into the leaderboard on short phone viewports.
	local left  = pad("Left",  UDim2.new(0, 18,   1, -110), S, Color3.fromRGB(40, 46, 66),    "<")
	local right = pad("Right", UDim2.new(0, 118,  1, -110), S, Color3.fromRGB(40, 46, 66),    ">")
	local jump  = pad("Jump",  UDim2.new(1, -110, 1, -110), S, Color3.fromRGB(120, 240, 255), "JUMP")
	local gas   = pad("Gas",   UDim2.new(1, -210, 1, -110), S, Color3.fromRGB(120, 255, 170), "GAS")
	local brake = pad("Brake", UDim2.new(1, -310, 1, -110), S, Color3.fromRGB(255, 130, 110), "SLOW")

	local function hold(btn, onDown, onUp)
		btn.InputBegan:Connect(function(io)
			if io.UserInputType == Enum.UserInputType.Touch then onDown() end
		end)
		btn.InputEnded:Connect(function(io)
			if io.UserInputType == Enum.UserInputType.Touch then onUp() end
		end)
	end
	hold(left, function() input.touchSteer = -1 end, function() input.touchSteer = 0 end)
	hold(right, function() input.touchSteer = 1 end, function() input.touchSteer = 0 end)
	hold(gas, function() input.touchThrottle = 1 end, function() input.touchThrottle = 0 end)
	hold(brake, function() input.touchBrake = 1 end, function() input.touchBrake = 0 end)
	jump.InputBegan:Connect(function(io)
		if io.UserInputType == Enum.UserInputType.Touch then input.jump = true end
	end)
end

------------------------------------------------------------------ character hookup
local hrp: BasePart? = nil
local trail: Trail? = nil

local function resetSim()
	dsrLastGate = 0
	dsrRecordFired = false
	dsrGhostX = 0
	dsrRunClock = 0
	sim.x, sim.z, sim.y = -30, 0, C.RIDE_HEIGHT
	sim.vy = 0; sim.speed = C.BASE_SPEED; sim.lateralV = 0
	sim.tier = 0; sim.momentum = 0; sim.airborne = false; sim.stun = 0
	sim.airTime = 0; sim.lastSlope = 0; sim.dist = 0
	table.clear(credited)
end

-- non-yielding: safe to call every frame. never clobbers a good reference with nil.
local function acquire()
	local char = plr.Character
	if not char or not char.Parent then return end
	local root = char:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then return end
	if hrp ~= root then
		hrp = root
		trail = root:FindFirstChild("MomentumTrail") :: Trail?
	elseif not trail then
		trail = root:FindFirstChild("MomentumTrail") :: Trail?
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum and not hum.PlatformStand then
		hum.PlatformStand = true
		hum.AutoRotate = false
		hum.WalkSpeed = 0
		hum.JumpPower = 0
		hum:ChangeState(Enum.HumanoidStateType.Physics)
	end
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("BasePart") and (d.CanCollide or d.CanQuery) then
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end

	-- silence default character sounds.
	-- The rider is on a bike, so Roblox's built-in footstep/landing/jump audio
	-- (parented to HumanoidRootPart and driven by the Animate script) is wrong.
	-- Volume alone is not enough: the engine re-triggers these, so disable the
	-- Sound instances outright. Our own Audio module provides bike SFX.
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("Sound") and DEFAULT_CHAR_SOUNDS[d.Name] then
			d.Volume = 0
			d.Playing = false
			d.Archivable = false
			pcall(function() d:Stop() end)
		end
	end
	-- the walk/run animation also drives footstep timing; stop it looping
	local animate = char:FindFirstChild("Animate")
	if animate and animate:IsA("LocalScript") and animate.Enabled then
		animate.Enabled = false
		local h = char:FindFirstChildOfClass("Humanoid")
		local animator = h and h:FindFirstChildOfClass("Animator")
		if animator then
			for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
				track:Stop(0)
			end
		end
	end
end

plr.CharacterAdded:Connect(function(char)
	hrp = nil
	trail = nil
	resetSim()

	-- catch sounds added after spawn: Roblox parents several of these a moment
	-- after the character replicates, so a one-shot sweep in acquire() can miss
	-- them and a footstep slips through on the first ride.
	char.DescendantAdded:Connect(function(d)
		if d:IsA("Sound") and DEFAULT_CHAR_SOUNDS[d.Name] then
			task.defer(function()
				if d.Parent then
					d.Volume = 0
					d.Playing = false
					pcall(function() d:Stop() end)
				end
			end)
		end
	end)
end)

------------------------------------------------------------------ crash / respawn
local function crash(reason: string)
	if not sim.alive then return end
	sim.alive = false
	dsrComboReset()
	if dsrGhostFinish then dsrGhostFinish(sim.dist) end
	shake = 1.4
	Audio.play("crash")
	if burst then burst(Color3.fromRGB(255, 90, 100), 60) end
	RE_Crash:FireServer(math.floor(sim.dist))
	centre.Text = ""
	local titles = {
		edge   = "YOU RODE OFF THE EDGE",
		void   = "THE ROAD RAN OUT",
		hazard = "YOU HIT A HAZARD",
	}
	local tips = {
		edge   = "Stay between the white lines",
		void   = "Tap JUMP before the road ends",
		hazard = "Steer around it or jump over",
	}
	crashTitle.Text = titles[reason] or "CRASHED"
	crashReason.Text = tips[reason] or ""
end

------------------------------------------------------------------ momentum helpers
local function addMomentum(n)
	sim.momentum = math.min(sim.momentum + n, (C.MAX_TIER + 1) * C.MOM_PER_TIER - 1)
	sim.tier = math.min(C.MAX_TIER, math.floor(sim.momentum / C.MOM_PER_TIER))
end
local function loseTier()
	sim.tier = math.max(0, sim.tier - 1)
	sim.momentum = tierFloor(sim.tier)
end

------------------------------------------------------------------ VFX
-- Local-only: these are feedback for YOUR bike, so there is no reason to pay
-- replication cost for them. The momentum trail (which others must see) stays
-- server-built. Emitters are created once and reused, never per-frame.
local vfxRoot: Attachment? = nil
local speedFx: ParticleEmitter? = nil
local burstFx: ParticleEmitter? = nil

ensureVfx = function(root: BasePart)
	if vfxRoot and vfxRoot.Parent == root then return end
	local existing = root:FindFirstChild("DSR_VFX")
	if existing then existing:Destroy() end

	local a = Instance.new("Attachment")
	a.Name = "DSR_VFX"
	a.Position = Vector3.new(-2.5, -1.2, 0)
	a.Parent = root
	vfxRoot = a

	local s = Instance.new("ParticleEmitter")
	s.Name = "Speed"
	s.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	s.Rate = 0
	s.Lifetime = NumberRange.new(0.18, 0.34)
	s.Speed = NumberRange.new(26, 40)
	s.SpreadAngle = Vector2.new(9, 9)
	s.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.85),
		NumberSequenceKeypoint.new(1, 0),
	})
	s.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	s.LightEmission = 1
	s.EmissionDirection = Enum.NormalId.Back
	s.Acceleration = Vector3.new(-40, 0, 0)
	s.Parent = a
	speedFx = s

	local b = s:Clone()
	b.Name = "Burst"
	b.Rate = 0
	b.Speed = NumberRange.new(18, 46)
	b.SpreadAngle = Vector2.new(180, 180)
	b.Lifetime = NumberRange.new(0.3, 0.7)
	b.Acceleration = Vector3.new(0, -60, 0)
	b.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.6),
		NumberSequenceKeypoint.new(1, 0),
	})
	b.Parent = a
	burstFx = b
end

burst = function(color: Color3, n: number)
	if not burstFx then return end
	burstFx.Color = ColorSequence.new(color)
	burstFx:Emit(n)
end

------------------------------------------------------------------ wheel spin
-- Purely visual, purely local. Wheels are welded to the root, so we rotate each
-- weld's C0 about the axle. Rotation rate is derived from real speed and wheel
-- radius, so the wheels never look like they are sliding.
local dsrWheelSpin = 0
local dsrWheelWelds: { { weld: Weld, base: CFrame } } = {}
local dsrWheelOwner: Instance? = nil

local function dsrCollectWheels(char: Instance)
	if dsrWheelOwner == char and #dsrWheelWelds > 0 then return end
	dsrWheelOwner = char
	table.clear(dsrWheelWelds)
	local bike = char:FindFirstChild("Bike")
	if not bike then return end
	for _, p in ipairs(bike:GetChildren()) do
		if p:IsA("BasePart") and p:GetAttribute("DSRWheel") then
			local w = p:FindFirstChildOfClass("Weld")
			if w then
				table.insert(dsrWheelWelds, { weld = w, base = w.C0 })
			end
		end
	end
end

local function dsrSpinWheels(dt: number, speed: number, moving: boolean)
	if #dsrWheelWelds == 0 then return end
	if moving then
		-- angular velocity = v / r  (WHEEL_R is 2.5 studs)
		dsrWheelSpin += (speed / 2.5) * dt
	end
	for _, e in ipairs(dsrWheelWelds) do
		e.weld.C0 = e.base * CFrame.Angles(dsrWheelSpin, 0, 0)
	end
end

------------------------------------------------------------------ ghost rider
-- Records your run at 10Hz and replays your personal best as a translucent
-- rider on the next attempt. This is the single biggest addition to the core
-- loop: "beat your record" becomes something you can literally see and chase
-- rather than a number on a screen. Entirely local -- no replication cost.
local dsrGhostRec: { number } = {}      -- flat triples: t, x, z (y is looked up)
local dsrGhostBest: { number } = {}
local dsrGhostBestDist = 0
local dsrGhostAcc = 0
local dsrGhostModel: Model? = nil
local dsrGhostParts: { BasePart } = {}
local dsrGhostLabel: BillboardGui? = nil

local function dsrGhostBuild()
	if dsrGhostModel and dsrGhostModel.Parent then return end
	local m = Instance.new("Model")
	m.Name = "DSRGhost"

	local function gp(size, offset, colour)
		local p = Instance.new("Part")
		p.Size = size
		p.Color = colour
		p.Material = Enum.Material.Neon
		p.Transparency = 0.62
		p.CanCollide = false; p.CanQuery = false; p.CanTouch = false
		p.Anchored = true
		p.Parent = m
		table.insert(dsrGhostParts, p)
		p:SetAttribute("Off", true)
		p.CFrame = CFrame.new(offset)
		return p
	end

	local ghostCol = Color3.fromRGB(150, 210, 255)
	-- deliberately simple: a readable silhouette, not a second full bike
	gp(Vector3.new(7.4, 0.4, 0.4), Vector3.new(0, 1.0, 0), ghostCol)
	gp(Vector3.new(0.4, 2.4, 0.4), Vector3.new(-2.0, 2.0, 0), ghostCol)
	gp(Vector3.new(0.4, 2.6, 0.4), Vector3.new(3.4, 1.9, 0), ghostCol)
	gp(Vector3.new(0.34, 0.34, 3.0), Vector3.new(3.4, 3.1, 0), ghostCol)
	for _, dx in ipairs({ 3.9, -3.9 }) do
		local w = gp(Vector3.new(0.5, 5, 5), Vector3.new(dx, 0, 0), ghostCol)
		w.Shape = Enum.PartType.Cylinder
	end

	local anchorPart = dsrGhostParts[1]
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.new(0, 120, 0, 28)
	bb.StudsOffset = Vector3.new(0, 6.5, 0)
	bb.AlwaysOnTop = true
	bb.Adornee = anchorPart
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.new(1, 0, 1, 0)
	lbl.Font = Enum.Font.GothamBold
	lbl.Text = "BEST"
	lbl.TextColor3 = ghostCol
	lbl.TextScaled = true
	lbl.TextStrokeTransparency = 0.6
	lbl.Parent = bb
	bb.Parent = anchorPart
	dsrGhostLabel = bb

	m.Parent = workspace
	dsrGhostModel = m
end

local function dsrGhostShow(on: boolean)
	for _, p in ipairs(dsrGhostParts) do
		p.Transparency = on and 0.62 or 1
	end
	if dsrGhostLabel then dsrGhostLabel.Enabled = on end
end

-- sample the live run
local function dsrGhostRecord(dt: number, t: number, x: number, z: number)
	dsrGhostAcc += dt
	if dsrGhostAcc < 0.1 then return end
	dsrGhostAcc = 0
	local n = #dsrGhostRec
	dsrGhostRec[n + 1] = t
	dsrGhostRec[n + 2] = x
	dsrGhostRec[n + 3] = z
end

-- position the ghost at run-time t by interpolating the stored trace
local function dsrGhostPlay(t: number, groundParams: RaycastParams)
	local rec = dsrGhostBest
	if #rec < 6 then dsrGhostShow(false) return end
	if t > rec[#rec - 2] then dsrGhostX = 0 dsrGhostShow(false) return end

	local x, z = rec[2], rec[3]
	for i = 1, #rec - 5, 3 do
		local t0, t1 = rec[i], rec[i + 3]
		if t >= t0 and t <= t1 then
			local a = (t1 > t0) and (t - t0) / (t1 - t0) or 0
			x = rec[i + 1] + (rec[i + 4] - rec[i + 1]) * a
            z = rec[i + 2] + (rec[i + 5] - rec[i + 2]) * a
			break
		end
	end

	-- rest the ghost on whatever road is under that point
	local y = C.RIDE_HEIGHT
	local hit = workspace:Raycast(Vector3.new(x, 60, z), Vector3.new(0, -300, 0), groundParams)
	if hit then y = hit.Position.Y + C.RIDE_HEIGHT end

	-- offset into a neighbouring lane so the ghost is legible as a separate
	-- rider rather than z-fighting with the player's own bike
	local GHOST_LANE = 6.5
	local lane = z + GHOST_LANE
	if math.abs(lane) > C.ROAD_HALF - 4 then lane = z - GHOST_LANE end
	local laneHit = workspace:Raycast(Vector3.new(x, 60, lane), Vector3.new(0, -300, 0), groundParams)
	if not laneHit then lane = z end

	dsrGhostX = x
	dsrGhostShow(true)
	local base = CFrame.new(x, y, lane)
	local offsets = {
		Vector3.new(0, 1.0, 0), Vector3.new(-2.0, 2.0, 0), Vector3.new(3.4, 1.9, 0),
		Vector3.new(3.4, 3.1, 0), Vector3.new(3.9, 0, 0), Vector3.new(-3.9, 0, 0),
	}
	for i, p in ipairs(dsrGhostParts) do
		local off = offsets[i] or Vector3.zero
		if p.Shape == Enum.PartType.Cylinder then
			p.CFrame = base * CFrame.new(off) * CFrame.Angles(0, math.rad(90), 0)
		else
			p.CFrame = base * CFrame.new(off)
		end
	end
end

dsrGhostFinish = function(dist: number)
	if dist > dsrGhostBestDist and #dsrGhostRec >= 6 then
		dsrGhostBestDist = dist
		dsrGhostBest = table.clone(dsrGhostRec)
	end
	dsrGhostRec = {}
	dsrGhostAcc = 0
end

------------------------------------------------------------------ combo chain
-- Consecutive near-misses escalate. Momentum tiers already reward speed, but
-- nothing rewarded riding CLOSE to danger -- so the safe line was also the
-- optimal one. Chaining makes threading the gap the correct play, which is what
-- turns speed into tension.
local function dsrComboUi()
	if dsrComboLabel then return dsrComboLabel end
	local l = new("TextLabel", {
		Name = "ComboLabel", BackgroundTransparency = 1,
		Size = UDim2.new(0, 260, 0, 38), Position = UDim2.new(0.5, -130, 0, 196),
		Font = FONT, Text = "", TextScaled = true,
		TextColor3 = Color3.fromRGB(255, 220, 110),
		TextStrokeTransparency = 0.4, Visible = false, ZIndex = 8,
	}, gui)
	new("UITextSizeConstraint", { MaxTextSize = 32 }, l)
	dsrComboLabel = l
	return l
end

dsrComboReset = function()
	dsrCombo = 0
	if dsrComboLabel then dsrComboLabel.Visible = false end
end

local function dsrComboHit(): number
	local now = os.clock()
	if now - dsrComboLast > 2.5 then dsrCombo = 0 end
	dsrCombo += 1
	dsrComboLast = now
	if dsrCombo >= 2 then
		local l = dsrComboUi()
		l.Text = "x" .. dsrCombo .. "  CLOSE!"
		l.TextColor3 = C.TIER_COLORS[math.min(dsrCombo, #C.TIER_COLORS)]
		local comboPitch = 1.15 + math.min(dsrCombo, 8) * 0.07
		Audio.play("nearMiss", comboPitch)
		l.Visible = true
	end
	return math.min(1 + (dsrCombo - 1) * 0.5, 3.5)
end

------------------------------------------------------------------ pace vs best
-- Rider level sits beside coins rather than adding a HUD row, so the riding
-- area stays clear on mobile.
dsrLevelLabel = new("TextLabel", {
	Name = "RiderLevel", BackgroundTransparency = 1,
	Size = UDim2.new(0, 118, 0, 16), Position = UDim2.new(0, 12, 0, 44),
	Font = FONT2, Text = "", TextColor3 = Color3.fromRGB(190, 160, 255),
	TextScaled = true, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 6,
}, gui)
new("UITextSizeConstraint", { MaxTextSize = 15 }, dsrLevelLabel)


-- The ghost gives you an opponent; this tells you whether you are beating it.
-- Turning every run into a live race against your own record is the cheapest
-- retention hook available, because the data already exists.
dsrBestLabel = new("TextLabel", {
	Name = "BestLabel", BackgroundTransparency = 1,
	Size = UDim2.new(0, 300, 0, 20), Position = UDim2.new(0.5, -150, 0, 136),
	Font = FONT2, Text = "", TextColor3 = Color3.fromRGB(150, 165, 190),
	TextScaled = true, TextStrokeTransparency = 0.7, ZIndex = 6,
}, gui)
new("UITextSizeConstraint", { MaxTextSize = 18 }, dsrBestLabel)

dsrPaceLabel = new("TextLabel", {
	Name = "PaceLabel", BackgroundTransparency = 1,
	Size = UDim2.new(0, 300, 0, 26), Position = UDim2.new(0.5, -150, 0, 156),
	Font = FONT, Text = "", TextColor3 = Color3.fromRGB(150, 210, 255),
	TextScaled = true, TextStrokeTransparency = 0.5, ZIndex = 6,
}, gui)
new("UITextSizeConstraint", { MaxTextSize = 24 }, dsrPaceLabel)

local function dsrUpdatePace(dist: number, alive: boolean)
	local best = (myProfile and myProfile.bestDistance) or 0
	if not alive or best <= 0 then
		dsrPaceLabel.Text = ""
		dsrBestLabel.Text = best > 0 and ("BEST " .. commas(best) .. "m") or ""
		return
	end
	dsrBestLabel.Text = "BEST " .. commas(best) .. "m"

	-- gap to the ghost, which is replaying that best run
	-- milestone popup: only on the way UP, once per run, and never while the
	-- record banner is showing so the two never fight for the centre slot
	local gate = math.floor(dist / 500)
	if gate > dsrLastGate then
		dsrLastGate = gate
		hudPulse = 1
		local m = gate * 500
		if centre.Text == "" then
			centre.Text = (m >= 1000) and (string.format("%.1fK", m / 1000):gsub("%.0K", "K") .. "  RIDE ON") or (m .. "m")
			Audio.play("tierUp", 1.15)
			task.delay(1.1, function()
				if centre.Text:find("RIDE ON", 1, true) or centre.Text == (m .. "m") then centre.Text = "" end
			end)
		end
	end

	local gap = math.floor(dist - dsrGhostX)
	if dsrGhostX > 0 and math.abs(gap) < 4000 then
		if gap >= 0 then
			dsrPaceLabel.Text = "+" .. commas(gap) .. "m AHEAD"
			dsrPaceLabel.TextColor3 = Color3.fromRGB(120, 255, 170)
		else
			dsrPaceLabel.Text = commas(gap) .. "m BEHIND"
			dsrPaceLabel.TextColor3 = Color3.fromRGB(255, 150, 150)
		end
	else
		dsrPaceLabel.Text = ""
	end

	-- the moment you pass your record, mid-run, while still riding
	if not dsrRecordFired and dist > best then
		dsrRecordFired = true
		hudPulse = 1
		centre.Text = "NEW RECORD!"
		shake = math.max(shake, 0.8)
		Audio.play("record", 1.3)
		if burst then burst(Color3.fromRGB(255, 220, 110), 45) end
		task.delay(2.0, function()
			if centre.Text == "NEW RECORD!" then centre.Text = "" end
		end)
	end
end

------------------------------------------------------------------ polish FX
-- Four feedback layers the game was missing. All local, all cheap: one Blur,
-- one frame of speed lines, one flash frame, and pooled coin labels. None of
-- them replicate, and none allocate per frame.
local function dsrPolishInit()
	if dsrBlur then return end

	-- motion blur: only engages near max momentum, so it reads as "too fast"
	-- rather than muddying normal riding
	dsrBlur = Instance.new("BlurEffect")
	dsrBlur.Size = 0
	dsrBlur.Parent = game:GetService("Lighting")

	-- speed lines: radial streaks at the screen edges, hidden until fast
	dsrSpeedLines = new("Frame", {
		Name = "SpeedLines", BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 1, 0), Visible = false, ZIndex = 2,
	}, gui)
	for i = 1, 14 do
		local a = (i / 14) * math.pi * 2
		local len = 0.16 + (i % 3) * 0.05
		new("Frame", {
			Name = "Line", BorderSizePixel = 0,
			BackgroundColor3 = Color3.fromRGB(255, 255, 255),
			BackgroundTransparency = 0.72,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5 + math.cos(a) * 0.46, 0, 0.5 + math.sin(a) * 0.46, 0),
			Size = UDim2.new(len, 0, 0, 2),
			Rotation = math.deg(a),
		}, dsrSpeedLines)
	end

	-- damage flash: a red vignette frame on impact
	dsrHitFlash = new("Frame", {
		Name = "HitFlash", BorderSizePixel = 0,
		BackgroundColor3 = Color3.fromRGB(255, 60, 70),
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 1, 0), ZIndex = 3,
	}, gui)

	dsrCoinLayer = new("Frame", {
		Name = "CoinLayer", BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 1, 0), ZIndex = 7,
	}, gui)
end

local function dsrFlash()
	if not dsrHitFlash then return end
	dsrHitFlash.BackgroundTransparency = 0.72
	TweenService:Create(dsrHitFlash, TweenInfo.new(0.42), { BackgroundTransparency = 1 }):Play()
end

-- floating "+$N" that drifts up and fades. Pooled by reuse of the layer only;
-- labels are short-lived and explicitly destroyed.
local function dsrCoinPop(amount: number, colour: Color3?)
	if not dsrCoinLayer or amount <= 0 then return end
	local lbl = new("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 150, 0, 34),
		Position = UDim2.new(0.5, -75 + math.random(-40, 40), 0.42, 0),
		Font = FONT, Text = "+" .. amount,
		TextColor3 = colour or Color3.fromRGB(255, 220, 110),
		TextScaled = true, TextStrokeTransparency = 0.45, ZIndex = 8,
	}, dsrCoinLayer)
	new("UITextSizeConstraint", { MaxTextSize = 26 }, lbl)
	TweenService:Create(lbl, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = lbl.Position - UDim2.new(0, 0, 0.09, 0),
		TextTransparency = 1, TextStrokeTransparency = 1,
	}):Play()
	task.delay(1, function() if lbl and lbl.Parent then lbl:Destroy() end end)
end

-- driven once per frame from the main step
local function dsrPolish(dt: number, speed: number, tier: number, alive: boolean)
	if not dsrBlur then return end
	local over = math.clamp((speed - C.BASE_SPEED) / (C.MAX_TIER * C.TIER_SPEED), 0, 1)
	local hot = alive and over > 0.55

	local targetBlur = hot and (over - 0.55) / 0.45 * 12 or 0
	dsrBlur.Size += (targetBlur - dsrBlur.Size) * smooth(dt, 5)

	if dsrSpeedLines then
		dsrSpeedLines.Visible = hot
		if hot then
			local t = math.clamp((over - 0.55) / 0.45, 0, 1)
			for _, l in ipairs(dsrSpeedLines:GetChildren()) do
				if l:IsA("Frame") then
					l.BackgroundTransparency = 0.9 - t * 0.35
				end
			end
		end
	end
end

------------------------------------------------------------------ main step
local flash = 0
local telemAcc = 0
local hitCount = 0
local currentBiome = 0
local collapseOn = false
local Lighting = game:GetService("Lighting")
local lastTier = 0
RunService.Heartbeat:Connect(function(dt)
	dt = math.min(dt, 1 / 20)
	readInput()
	dsrPolishInit()
	if not hrp or not hrp.Parent then acquire() end
	if plr.Character then
		dsrCollectWheels(plr.Character)
		dsrSpinWheels(dt, sim.speed, sim.alive)
	end
	local root = hrp
	if not root or not root.Parent then return end
	if ensureVfx then ensureVfx(root) end

	if sim.alive then
		---------------------------------------------------------- speed
		local tgt = targetSpeed()
		local want
		if input.brake > 0 then
			want = C.BASE_SPEED * 0.42
			sim.momentum = math.max(0, sim.momentum - 60 * dt)
			sim.tier = math.min(sim.tier, math.floor(sim.momentum / C.MOM_PER_TIER))
		elseif input.throttle > 0 then
			want = tgt
		else
			want = tgt * 0.86
		end
		if sim.stun > 0 then
			sim.stun -= dt
			want = math.min(want, C.BASE_SPEED * 0.55)
		end
		local accel = (want > sim.speed) and 90 or 150
		sim.speed += math.clamp(want - sim.speed, -accel * dt, accel * dt)

		---------------------------------------------------------- steering
		local steerMax = sim.onIce and C.STEER_SPEED_ICE or C.STEER_SPEED
		local airMul = sim.airborne and 0.55 or 1
		-- carve response: steering authority falls slightly at very high speed so
		-- max momentum feels heavy and committed rather than twitchy, and the
		-- approach is eased rather than a linear ramp.
		local speedFrac = math.clamp((sim.speed - C.BASE_SPEED) / (C.MAX_TIER * C.TIER_SPEED), 0, 1)
		local authority = 1 - speedFrac * 0.18
		local wantLat = input.steer * steerMax * airMul * authority
		local sAcc = (sim.onIce and 3.5 or C.STEER_ACCEL) * (sim.airborne and 0.6 or 1)
		-- release is quicker than engage, so letting go recentres crisply while
		-- turning in still has weight
		local releasing = math.abs(wantLat) < math.abs(sim.lateralV)
		local rate = sAcc * (releasing and 1.35 or 1.0)
		sim.lateralV += math.clamp(wantLat - sim.lateralV, -rate * 60 * dt, rate * 60 * dt)
		sim.z += sim.lateralV * dt
		sim.z = math.clamp(sim.z, -C.LATERAL_LIMIT, C.LATERAL_LIMIT)

		---------------------------------------------------------- forward
		sim.x += sim.speed * dt
		sim.dist = math.max(sim.dist, sim.x)

		---------------------------------------------------------- ground
		local origin = Vector3.new(sim.x, sim.y + 8, sim.z)
		local hit = workspace:Raycast(origin, Vector3.new(0, -C.GROUND_PROBE, 0), groundParams)
		local groundY, hasGround = nil, false
		if hit then
			groundY = hit.Position.Y
			hasGround = true
			sim.onIce = (hit.Instance:GetAttribute("DSR") == "ice")
		else
			sim.onIce = false
		end

		-- biome is stamped on the slab we are riding on
		if hit and hit.Instance then
			local b = hit.Instance:GetAttribute("Biome")
			if b and b ~= currentBiome then
				currentBiome = b
				local bi = C.BIOMES[b]
				if bi then
					centre.Text = bi.name
					Audio.play("tierUp", 0.75)
					task.delay(1.6, function()
						if centre.Text == bi.name then centre.Text = "" end
					end)
				end
			end
		end

		if input.jump then
			input.jump = false
			if not sim.airborne then
				sim.airborne = true
				sim.vy = C.JUMP_VELOCITY
				sim.airTime = 0
				Audio.play("jump", 1 + sim.tier * 0.05)
			end
		end

		if sim.airborne then
			sim.vy -= C.GRAVITY * dt
			sim.y += sim.vy * dt
			sim.airTime += dt
			if hasGround and sim.vy <= 0 then
				local desired = (groundY :: number) + C.RIDE_HEIGHT
				if sim.y <= desired then
					sim.y = desired
					sim.airborne = false
					sim.vy = 0
					if sim.airTime > 0.3 then
						addMomentum(math.min(sim.airTime, 1.8) * C.MOM_AIR_PER_SEC)
						flash = 0.35
						Audio.play("land", 1, math.min(1, 0.5 + sim.airTime))
						if burst then burst(Color3.fromRGB(200, 210, 225), math.floor(10 + sim.airTime * 14)) end
					else
						Audio.play("land", 1.15, 0.35)
					end
					sim.airTime = 0
				end
			end
			if sim.y < C.KILL_Y then
				-- off the side of the road is a steering mistake; anywhere else
				-- the road simply ended ahead of them
				local wentOffEdge = math.abs(sim.z) > C.ROAD_HALF - 1
				crash(wentOffEdge and "edge" or "void")
			end
		else
			if hasGround then
				local desired = (groundY :: number) + C.RIDE_HEIGHT
				local rate = (desired - sim.y) / dt
				if rate < -260 then
					-- ground fell away: launch with whatever upward slope momentum we had
					sim.airborne = true
					sim.vy = math.max(sim.lastSlope * 0.55, 0)
					sim.airTime = 0
				else
					sim.lastSlope = math.clamp(rate, -400, 400)
					sim.y = desired
				end
			else
				sim.airborne = true
				sim.vy = math.max(sim.lastSlope * 0.55, 0)
				sim.airTime = 0
			end
		end

		---------------------------------------------------------- hazards
		local pos = Vector3.new(sim.x, sim.y, sim.z)
		local hitBox = workspace:GetPartBoundsInBox(CFrame.new(pos), Vector3.new(6, 6, 5), hazParams)
		for _, p in ipairs(hitBox) do
			local kind = p:GetAttribute("DSR")
			if kind == "kill" then
				crash("hazard")
				break
			elseif kind == "boost" then
				if not credited[p] then
					credited[p] = true
					addMomentum(C.MOM_BOOSTPAD)
					flash = 0.4
					Audio.play("boost")
					if burst then burst(Color3.fromRGB(120, 255, 170), 28) end
					if tutorialActive() then showHint("boost", "GREEN PADS = BOOST", 2.8) end
				end
			elseif kind == "obstacle" then
				if sim.stun <= 0 then
					sim.stun = C.HIT_STUN
					dsrComboReset()
					dsrFlash()
					loseTier()
					shake = 0.9
					hitCount += 1
					Audio.play("hit")
					if burst then burst(Color3.fromRGB(255, 170, 60), 22) end
					credited[p] = true
				end
			end
		end
		-- near miss ring
		local nearBox = workspace:GetPartBoundsInBox(CFrame.new(pos), Vector3.new(10, 10, 18), hazParams)
		for _, p in ipairs(nearBox) do
			if not credited[p] and p:GetAttribute("DSR") == "obstacle" then
				credited[p] = true
				addMomentum(C.MOM_NEARMISS * dsrComboHit())
				Audio.play("nearMiss", 1.25)
			end
		end

		if dsrCombo > 0 and os.clock() - dsrComboLast > 2.5 then dsrComboReset() end

		---------------------------------------------------------- ghost rider
		dsrGhostBuild()
		dsrRunClock += dt
		dsrGhostRecord(dt, dsrRunClock, sim.x, sim.z)
		dsrGhostPlay(dsrRunClock, groundParams)

		---------------------------------------------------------- momentum decay
		if sim.stun <= 0 and not sim.airborne and input.brake <= 0 then
			addMomentum(C.MOM_CLEAN_PER_SEC * dt)
		end
		sim.momentum = math.max(0, sim.momentum - C.MOM_DECAY * dt)
		sim.tier = math.min(sim.tier, math.floor(sim.momentum / C.MOM_PER_TIER))
	end

	---------------------------------------------------------- apply transform
	local leanTarget = math.clamp(-sim.lateralV / C.STEER_SPEED, -1, 1) * 0.46
	leanSmooth += (leanTarget - leanSmooth) * smooth(dt, 8)
	local lean = leanSmooth
	local pitch = sim.airborne and math.clamp(sim.vy / 220, -0.35, 0.35) or 0
	local cf = CFrame.fromMatrix(
		Vector3.new(sim.x, sim.y, sim.z),
		Vector3.new(1, 0, 0),
		Vector3.new(0, 1, 0)
	) * CFrame.Angles(pitch, 0, lean)
	root.CFrame = cf
	root.AssemblyLinearVelocity = Vector3.new(sim.speed, 0, sim.lateralV)

	---------------------------------------------------------- camera
	local maxT = (sim.tier >= C.MAX_TIER)
	local back = 24 + sim.tier * 0.55 + (sim.speed - C.BASE_SPEED) * 0.022
	local up = 11.0 + sim.tier * 0.22 + (sim.speed - C.BASE_SPEED) * 0.020
	local target = Vector3.new(sim.x - back, sim.y + up, sim.z * 0.65)
	-- readability: keep a constant *time* horizon, not a constant distance
	local lookDist = 34 + sim.speed * 0.55
	local look = Vector3.new(sim.x + lookDist, sim.y + 2.5, sim.z * 0.4)
	shake = math.max(0, shake - dt * 2.2)
	local sh = prefs.shake and (shake + (maxT and 0.13 or 0) + (collapseOn and 0.16 or 0)) or 0
	local jitter = Vector3.new(
		(math.random() - 0.5) * sh * 3,
		(math.random() - 0.5) * sh * 3,
		(math.random() - 0.5) * sh * 3
	)
	cam.CameraType = Enum.CameraType.Scriptable
	local goal = CFrame.lookAt(target + jitter, look)
	cam.CFrame = cam.CFrame:Lerp(goal, smooth(dt, 9))
	local wantFov = 72 + (sim.speed - C.BASE_SPEED) * 0.17 + (maxT and 4 or 0)
	cam.FieldOfView += (math.clamp(wantFov, 68, 92) - cam.FieldOfView) * smooth(dt, 3.5)

	---------------------------------------------------------- telemetry (10Hz)
	-- Player attributes replicate to the server AND every other client, so this
	-- debug telemetry is a real bandwidth cost at 8-12 players and leaks internal
	-- state. Studio-only; never runs in a live game.
	telemAcc += dt
	if TEST_HOOKS and telemAcc >= 0.1 then
		telemAcc = 0
		plr:SetAttribute("DSR_Y", math.floor(sim.y * 10) / 10)
		plr:SetAttribute("DSR_Z", math.floor(sim.z * 10) / 10)
		plr:SetAttribute("DSR_Speed", math.floor(sim.speed))
		plr:SetAttribute("DSR_Dist", math.floor(sim.dist))
		plr:SetAttribute("DSR_Tier", sim.tier)
		plr:SetAttribute("DSR_GhostRec", #dsrGhostRec)
		plr:SetAttribute("DSR_GhostBest", #dsrGhostBest)
		plr:SetAttribute("DSR_GhostBestDist", dsrGhostBestDist)
		plr:SetAttribute("DSR_Mom", math.floor(sim.momentum))
		plr:SetAttribute("DSR_Stun", sim.stun > 0)
		plr:SetAttribute("DSR_Hits", hitCount)
		plr:SetAttribute("DSR_Air", sim.airborne)
		plr:SetAttribute("DSR_Alive", sim.alive)
		local pk = plr:GetAttribute("DSR_PeakY") or -1e9
		if sim.y > pk then plr:SetAttribute("DSR_PeakY", math.floor(sim.y * 10) / 10) end
	end

	---------------------------------------------------------- biome lighting
	local bi = C.BIOMES[currentBiome] or C.BIOMES[1]
	local last = C.BIOMES[#C.BIOMES]
	local k = smooth(dt, 1.6)
	local tFog = collapseOn and last.fog or bi.fog
	local tAmb = collapseOn and last.ambient or bi.ambient
	local tEnd = collapseOn and 620 or bi.fogEnd
	Lighting.FogColor = Lighting.FogColor:Lerp(tFog, k)
	Lighting.Ambient = Lighting.Ambient:Lerp(tAmb, k)
	Lighting.OutdoorAmbient = Lighting.OutdoorAmbient:Lerp(tAmb, k)
	Lighting.FogEnd += (tEnd - Lighting.FogEnd) * k
	Lighting.ClockTime += (bi.clock - Lighting.ClockTime) * k * 0.5

	dsrPolish(dt, sim.speed, sim.tier, sim.alive)
	dsrUpdatePace(sim.dist, sim.alive)

	---------------------------------------------------------- hud
	local kmh = math.floor(sim.speed * 0.28 * 3.6)
	local distText = string.format("%dm", math.floor(sim.dist))
	distLabel.Text = distText
	if distShadow then distShadow.Text = distText end

	-- reactive HUD: the distance readout swells slightly with momentum tier and
	-- kicks on a milestone, so the number feels alive instead of static
	hudPulse = math.max(0, hudPulse - dt * 3.2)
	local tierBoost = 1 + math.min(sim.tier, C.MAX_TIER) * 0.012
	local scale = tierBoost + hudPulse * 0.10
	top.Size = UDim2.new(0, 420 * scale, 0, 130 * scale)
	top.Position = UDim2.new(0.5, -210 * scale, 0, 14)
	if sim.tier >= C.MAX_TIER and sim.alive then
		-- at max momentum the readout takes the tier colour
		distLabel.TextColor3 = C.TIER_COLORS[#C.TIER_COLORS]
	else
		distLabel.TextColor3 = Color3.new(1, 1, 1)
	end
	speedLabel.Text = string.format("%d KM/H", kmh)
	if sim.tier > lastTier and sim.alive then
		Audio.play("tierUp", 0.9 + sim.tier * 0.12)
		if tutorialActive() and sim.tier == 1 then
			showHint("momentum", "RIDE CLEAN TO BUILD MOMENTUM", 3.0)
		end
	end
	lastTier = sim.tier
	Audio.setWind(math.clamp((sim.speed - C.BASE_SPEED) / (C.MAX_TIER * C.TIER_SPEED), 0, 1), sim.alive)
	Audio.setMusic(math.clamp((sim.speed - C.BASE_SPEED) / (C.MAX_TIER * C.TIER_SPEED), 0, 1), sim.alive, collapseOn)

	local within = (sim.momentum % C.MOM_PER_TIER) / C.MOM_PER_TIER
	if sim.tier >= C.MAX_TIER then within = 1 end
	barFill.Size = UDim2.new(barFill.Size.X.Scale + (within - barFill.Size.X.Scale) * smooth(dt, 12), 0, 1, 0)
	local col = C.TIER_COLORS[math.min(sim.tier + 1, #C.TIER_COLORS)]
	barFill.BackgroundColor3 = col
	if barTip then
		barTip.BackgroundTransparency = (within > 0.02 and sim.alive) and 0.25 or 1
	end
	tierLabel.Text = C.TIER_NAMES[math.min(sim.tier + 1, #C.TIER_NAMES)]
	tierLabel.TextColor3 = col
	if speedFx then
		-- only above tier 2, so particles signal "you are fast" rather than
		-- constantly cluttering the screen
		local t = sim.alive and sim.tier or 0
		speedFx.Rate = (t >= 2) and (t - 1) * 22 or 0
		speedFx.Color = ColorSequence.new(C.TIER_COLORS[math.min(t + 1, #C.TIER_COLORS)])
	end
	if trail then
		trail.Enabled = sim.alive and sim.tier >= 2
		if sim.tier >= 2 then
			trail.Color = ColorSequence.new(equippedTrail, col)
			trail.Lifetime = 0.3 + sim.tier * 0.09
		end
	end
	if flash > 0 then
		flash -= dt
		centre.TextTransparency = 0
	end
end)
------------------------------------------------------------------ watchdog
-- if the character loses its root (fell out of the world, bad respawn), ask
-- the server to rebuild it rather than sitting in a dead render loop forever.
task.spawn(function()
	-- only nag when genuinely stuck: the engine respawns automatically, so
	-- firing every second during a normal death spams a redundant reload
	local missingFor = 0
	while true do
		task.wait(1)
		local ch = plr.Character
		if not ch or not ch:FindFirstChild("HumanoidRootPart") then
			missingFor += 1
			if missingFor >= 8 then
				RE_Revive:FireServer()
				missingFor = 0
			end
		else
			missingFor = 0
		end
	end
end)

------------------------------------------------------------------ progress reporting
task.spawn(function()
	while true do
		task.wait(1)
		if sim.alive then
			RE_Progress:FireServer(math.floor(sim.dist), sim.tier)
		end
	end
end)

------------------------------------------------------------------ server state
local lastCountdown = nil
RE_State.OnClientEvent:Connect(function(p)
	phase = p.phase
	phaseTime = p.timeLeft or 0
	if p.board then board = p.board end
	if p.collapse ~= nil and p.collapse ~= collapseOn then
		collapseOn = p.collapse
		if collapseOn then
			centre.Text = "COLLAPSE MODE"
			local collapseStinger = true
			Audio.play("crash", 0.55, 1.2)
			shake = 1.2
			Audio.play("crash", 0.7)
			task.delay(2.2, function()
				if centre.Text == "COLLAPSE MODE" then centre.Text = "" end
			end)
		end
	end

	if p.crashed then
		crashPanel.Visible = true
		crashNext.Visible = false
		rideAgain.Visible = false
		task.delay(0.7, function()
			if crashPanel.Visible then rideAgain.Visible = true end
		end)
		crashDist.Text = string.format("%dm", p.dist or 0)
		crashBest.Text = string.format("BEST %dm", p.best or 0)
		crashRecord.Text = p.record and "NEW RECORD!" or ""
		if p.record then task.delay(0.45, function() Audio.play("record", 1.35) end) end
		crashCoins.Text = p.coins and ("+" .. commas(p.coins) .. " COINS") or ""
		if p.coins and p.coins > 0 then dsrCoinPop(p.coins) end
	end
	if p.go then
		if tutorialActive() then
			table.clear(hintShown)
			table.clear(hintQueue)
			showHint("steer", steerHint, 3.4)
			showHint("jump", jumpHint, 3.4)
		end
		sim.alive = true
		crashPanel.Visible = false
		rideAgain.Visible = false
		centre.Text = "GO!"
		task.delay(1.1, function() if centre.Text == "GO!" then centre.Text = "" end end)
		resetSim()
	end
	-- round ended: stop simulating so the player is not riding a run that no
	-- longer scores. (Found by the self-test: client stayed alive during RESULTS.)
	if p.phase and p.phase ~= "RIDING" and sim.alive then
		sim.alive = false
	end
	if p.newRound then
		crashPanel.Visible = false
		sim.alive = false
	end

	-- rebuild mini leaderboard
	for _, ch in ipairs(miniBoardList:GetChildren()) do
		if ch:IsA("TextLabel") then ch:Destroy() end
	end
	local medals = { "1.", "2.", "3." }
	for i, e in ipairs(board) do
		if i > 4 then break end
		local isMe = (e.id == plr.UserId)
		new("TextLabel", {
			BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 18), LayoutOrder = i,
			Font = isMe and FONT or FONT2,
			Text = string.format("%s %s  %dm", medals[i] or (tostring(i) .. "."), e.name, e.dist),
			TextColor3 = e.alive and (isMe and Color3.fromRGB(255, 220, 110) or Color3.new(1,1,1))
				or Color3.fromRGB(120, 125, 140),
			TextScaled = true, TextXAlignment = Enum.TextXAlignment.Left,
		}, miniBoardList)
	end
end)

-- countdown display
task.spawn(function()
	while true do
		task.wait(0.1)
		phaseTime = math.max(0, phaseTime - 0.1)
		if phase == "INTERMISSION" and not crashPanel.Visible then
			if phaseTime <= 3.2 and phaseTime > 0.2 then
				local n = math.ceil(phaseTime - 0.2)
				if n >= 1 and n <= 3 and centre.Text ~= tostring(n) then
					centre.Text = tostring(n)
					Audio.play("countdown", 1 + (3 - n) * 0.1)
				end
			elseif phaseTime > 3.2 then
				centre.Text = "GET ON YOUR BIKE"
			end
		elseif phase == "INTERMISSION" and crashPanel.Visible then
			crashNext.Text = string.format("NEXT RIDE IN %ds", math.ceil(phaseTime))
		end
	end
end)

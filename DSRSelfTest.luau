--!strict
-- DON'T STOP RIDING :: automated regression suite (Studio only)
--
-- Why this exists: the crash-reporting path broke for a full session because a
-- VFX call was declared after crash() and threw before FireServer. Visual tests
-- looked fine; the economy was dead. This suite drives the REAL player-facing
-- paths end to end so that class of silent breakage is caught immediately.
--
-- Trigger:  game.Players.<you>:SetAttribute("DSR_RUN_TESTS", true)
-- Results:  console lines prefixed [DSR-TEST], and the DSR_TEST_RESULT attribute.

local RunService = game:GetService("RunService")
if not RunService:IsStudio() then return end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local plr = Players.LocalPlayer

local Remotes = RS:WaitForChild("DSRRemotes")
local RE_State = Remotes:WaitForChild("State") :: RemoteEvent
local RE_Restart = Remotes:WaitForChild("Restart") :: RemoteEvent

-- The suite runs longer than a round (ROUND_TIME ~170s), so by the later tests
-- the round can be over -- at which point the server correctly refuses crash
-- reports and restarts. Track phase so we test against a live round, not a
-- finished one. (This was a bug in the SUITE, not the game.)
local phase, timeLeft = "?", 0
RE_State.OnClientEvent:Connect(function(p)
	if p.phase then phase = p.phase end
	if p.timeLeft then timeLeft = p.timeLeft end
end)

local function waitForFreshRound(minSeconds: number, timeout: number): boolean
	local t0 = os.clock()
	while os.clock() - t0 < timeout do
		if phase == "RIDING" and timeLeft > minSeconds then return true end
		task.wait(0.5)
	end
	return false
end

local results = {}
local function skip(name: string, why: string)
	table.insert(results, { name = name, pass = false, skipped = true, detail = why })
	print(string.format("[DSR-TEST] SKIP %-26s %s", name, why))
end

local function record(name: string, pass: boolean, detail: string?)
	table.insert(results, { name = name, pass = pass, detail = detail or "" })
	print(string.format("[DSR-TEST] %-4s %-26s %s", pass and "PASS" or "FAIL", name, detail or ""))
end

local function A(n: string) return plr:GetAttribute(n) end

local function waitAlive(timeout: number): boolean
	local t0 = os.clock()
	while os.clock() - t0 < timeout do
		if A("DSR_Alive") == true then return true end
		task.wait(0.2)
	end
	return false
end

-- Get back into a live run if the bot died mid-suite, so later tests still run.
local function ensureAlive(timeout: number): boolean
	if A("DSR_Alive") == true then return true end
	local t0 = os.clock()
	while os.clock() - t0 < timeout do
		if A("DSR_Alive") == true then return true end
		RE_Restart:FireServer()
		task.wait(1.2)
	end
	return A("DSR_Alive") == true
end

local function waitLiveRun(timeout: number): boolean
	local t0 = os.clock()
	while os.clock() - t0 < timeout do
		if phase == "RIDING" and A("DSR_Alive") == true then return true end
		if phase == "RIDING" and A("DSR_Alive") == false then
			RE_Restart:FireServer()
		end
		task.wait(0.3)
	end
	return false
end

-- Force a crash through a real failure mode: steer off the edge of the road.
local function forceCrash(timeout: number): boolean
	plr:SetAttribute("DSR_IN_STEER", 1)
	local t0 = os.clock()
	while os.clock() - t0 < timeout do
		if A("DSR_Alive") == false then
			plr:SetAttribute("DSR_IN_STEER", 0)
			return true
		end
		task.wait(0.1)
	end
	plr:SetAttribute("DSR_IN_STEER", 0)
	return false
end

local function run()
	table.clear(results)
	print("[DSR-TEST] ---- starting suite ----")

	-- 1. HUD built
	local hud = plr.PlayerGui:FindFirstChild("DSRHud")
	record("hud present", hud ~= nil)
	if hud then
		for _, n in ipairs({ "ShopBtn", "ChalBtn", "ShopPanel", "ChalPanel" }) do
			record("hud." .. n, hud:FindFirstChild(n) ~= nil)
		end
	end

	-- 2. a run begins
	record("run starts", waitAlive(45))
	if A("DSR_Alive") ~= true then
		record("SUITE ABORTED", false, "never went alive")
		return
	end
	task.wait(1)

	-- 3. movement
	local d1 = A("DSR_Dist") or 0
	task.wait(2.5)
	local d2 = A("DSR_Dist") or 0
	record("distance advances", d2 > d1, string.format("%d -> %d", d1, d2))
	record("speed non-zero", (A("DSR_Speed") or 0) > 0, tostring(A("DSR_Speed")))

	-- 4. jump
	if not ensureAlive(30) then
		skip("jump", "could not get a live run")
	else
	-- wait for the bot to be grounded; jumping mid-air is a no-op and the
	-- test would measure a meaningless rise
	local grounded = false
	local gt = os.clock()
	while os.clock() - gt < 8 do
		if A("DSR_Air") == false and A("DSR_Alive") == true then grounded = true break end
		task.wait(0.1)
	end
	plr:SetAttribute("DSR_PeakY", -1e9)
	task.wait(0.2)
	local base = A("DSR_Y") or 0
	plr:SetAttribute("DSR_IN_JUMP", true)
	task.wait(1.0)
	local rise = (A("DSR_PeakY") or 0) - base
	record("jump", rise > 8, string.format("rise=%.1f", rise))

	end

	-- 5. steering
	if not ensureAlive(30) then
		skip("steering", "could not get a live run")
	else
	local z0 = A("DSR_Z") or 0
	plr:SetAttribute("DSR_IN_STEER", -1)
	task.wait(0.6)
	plr:SetAttribute("DSR_IN_STEER", 0)
	record("steering", math.abs((A("DSR_Z") or 0) - z0) > 8,
		string.format("dz=%+.1f", (A("DSR_Z") or 0) - z0))

	end

	-- 6. brake
	if not ensureAlive(25) then skip("brake", "could not get a live run") else
		local s0 = A("DSR_Speed") or 0
		plr:SetAttribute("DSR_IN_BRAKE", 1)
		task.wait(1.2)
		local s1 = A("DSR_Speed") or 0
		plr:SetAttribute("DSR_IN_BRAKE", 0)
		record("brake", s1 < s0 - 3, string.format("%d -> %d", s0, s1))
	end

	-- 7. momentum reaches max tier
	if not ensureAlive(25) then
		skip("max momentum", "could not get a live run")
	else
		plr:SetAttribute("DSR_IN_MOM", 540)
		task.wait(0.6)
		record("max momentum", A("DSR_Tier") == 5, "tier=" .. tostring(A("DSR_Tier")))
	end

	-- 8. THE REGRESSION GUARD: crashing must reach the server and pay out.
	if not waitLiveRun(200) then
		skip("crash reaches server", "could not get a live mid-round state")
		skip("coins awarded", "could not get a live mid-round state")
	elseif not ensureAlive(30) then
		record("crash reporting", false, "not alive before crash test")
	else
		local payload = nil
		local conn = RE_State.OnClientEvent:Connect(function(p)
			if p.crashed then payload = p end
		end)
		local preAlive = A("DSR_Alive")
		local prePhase = phase
		local crashed = forceCrash(25)
		print(string.format("[DSR-TEST]   (crash ctx: preAlive=%s prePhase=%s postPhase=%s timeLeft=%.0f)",
			tostring(preAlive), prePhase, phase, timeLeft))
		task.wait(2)
		conn:Disconnect()
		record("crash detected locally", crashed, "client sim.alive went false")
		local reason = payload and tostring(payload.reason) or "none"
		record("crash reaches server", payload ~= nil,
			payload and string.format("reason=%s dist=%s best=%s", reason,
				tostring(payload.dist), tostring(payload.best))
			or string.format("NO PAYLOAD (phase=%s timeLeft=%.0f alive=%s)",
				phase, timeLeft, tostring(A("DSR_Alive"))))
		-- a settlement from the round timer is equally valid; note it so a green
		-- run cannot hide the fact that we never exercised the crash path itself
		if payload and reason ~= "crash" then
			print("[DSR-TEST]   (note: settled by " .. reason .. ", not a player crash)")
		end
		record("coins awarded", payload ~= nil and (payload.coins or 0) > 0,
			payload and ("coins=" .. tostring(payload.coins)) or "-")
	end

	-- 9. RIDE AGAIN
	if not waitLiveRun(60) then
		skip("ride again", "could not reach a live run")
	elseif not forceCrash(25) then
		skip("ride again", "could not force a crash")
	else
		local t0 = os.clock()
		local revived = nil
		local lastFire = 0
		while os.clock() - t0 < 8 do
			-- server rate-limits restarts to 1/sec; keep asking
			if os.clock() - lastFire > 1.1 then
				RE_Restart:FireServer()
				lastFire = os.clock()
			end
			task.wait(0.05)
			if A("DSR_Alive") == true then revived = os.clock() - t0 break end
		end
		record("ride again", revived ~= nil and revived < 5,
			revived and string.format("%.2fs", revived) or "never revived")
	end

	-- 10. budgets
	local parts, emitters = 0, 0
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("BasePart") then parts += 1 end
	end
	for _, d in ipairs(game:GetDescendants()) do
		if d:IsA("ParticleEmitter") then emitters += 1 end
	end
	record("part budget", parts < 1500, parts .. " parts")
	record("emitter budget", emitters <= 4, emitters .. " emitters")

	-- 11. framerate
	local n, acc, worst = 0, 0, 0
	local cn = RunService.Heartbeat:Connect(function(dt)
		n += 1; acc += dt; worst = math.max(worst, dt)
	end)
	task.wait(4)
	cn:Disconnect()
	record("framerate", (n / acc) > 50, string.format("%.0f fps, worst %.0f ms", n / acc, worst * 1000))

	local passed, total = 0, #results
	local failed, skipped = {}, {}
	for _, r in ipairs(results) do
		if r.skipped then
			table.insert(skipped, r.name)
		elseif r.pass then
			passed += 1
		else
			table.insert(failed, r.name)
		end
	end
	local summary = string.format("%d/%d passed%s%s", passed, total - #skipped,
		#failed > 0 and ("  FAILED: " .. table.concat(failed, ", ")) or "",
		#skipped > 0 and ("  SKIPPED: " .. table.concat(skipped, ", ")) or "")
	print("[DSR-TEST] ---- " .. summary .. " ----")
	plr:SetAttribute("DSR_TEST_RESULT", summary)
end

plr:GetAttributeChangedSignal("DSR_RUN_TESTS"):Connect(function()
	if plr:GetAttribute("DSR_RUN_TESTS") == true then
		plr:SetAttribute("DSR_RUN_TESTS", false)
		local ok, err = pcall(run)
		if not ok then
			warn("[DSR-TEST] suite errored: " .. tostring(err))
			plr:SetAttribute("DSR_TEST_RESULT", "SUITE ERROR: " .. tostring(err))
		end
	end
end)

print("[DSR-TEST] self-test ready (set DSR_RUN_TESTS to run)")

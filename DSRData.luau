--!strict
-- DON'T STOP RIDING :: persistence
-- Rules: never overwrite a valid save with failed/empty data; retry with backoff;
-- session-lock so two servers can't clobber each other; always save on close.
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Data = {}

local STORE_VERSION = "v1"
-- GetDataStore throws in an unpublished place / with API access off.
-- Never let that take down the game server: fall back to volatile profiles.
local store = nil
do
	local ok, res = pcall(function()
		return DataStoreService:GetDataStore("DSR_Profiles_" .. STORE_VERSION)
	end)
	if ok then
		store = res
	else
		warn("[DSR] DataStore unavailable, profiles will not persist this session: " .. tostring(res))
	end
end

local SCHEMA = 1

-- A published place with "Studio Access to API Services" disabled will throw on
-- every DataStore call. Probe once, then degrade to volatile profiles quietly
-- rather than logging an error per player.
local apiAvailable = nil

local function probeApi(): boolean
	if apiAvailable ~= nil then return apiAvailable end
	if store == nil then
		apiAvailable = false
		return false
	end
	local ok = pcall(function()
		store:GetAsync("__api_probe__")
	end)
	apiAvailable = ok
	if not ok then
		warn("[DSR] DataStore unreachable (Studio API access off, or no network). " ..
			"Profiles will not persist this session.")
	end
	return ok
end

local function defaultProfile()
	return {
		schema = SCHEMA,
		coins = 0,
		bestDistance = 0,
		totalDistance = 0,
		runs = 0,
		bikes = { starter = true },
		trails = { t_stock = true },
		equippedTrail = "t_stock",
		equippedBike = "starter",
		cosmetics = {},
		equipped = {},
		daily = { day = 0, progress = {}, claimed = {} },
		weekly = { week = 0, progress = {}, claimed = {} },
		event = { id = "", progress = {}, claimed = {} },
		settings = {},
		sessionId = "",
	}
end
Data.defaultProfile = defaultProfile

-- migrate older saves forward instead of discarding them
local function migrate(p)
	if type(p) ~= "table" then return nil end
	local d = defaultProfile()
	for k, v in pairs(d) do
		if p[k] == nil then p[k] = v end
	end
	p.schema = SCHEMA
	return p
end

local cache: { [Player]: any } = {}
local loaded: { [Player]: boolean } = {}
local dirty: { [Player]: boolean } = {}
Data.cache = cache

local function key(plr: Player) return "u_" .. plr.UserId end

local function retry(fn, tries)
	tries = tries or 4
	local wait = 0.5
	local lastErr
	for i = 1, tries do
		local ok, res = pcall(fn)
		if ok then return true, res end
		lastErr = res
		task.wait(wait)
		wait *= 2
	end
	return false, lastErr
end

function Data.load(plr: Player)
	if not probeApi() then
		-- datastore unreachable: volatile in-memory profile (never saved)
		local ok, res = false, nil
		if apiAvailable then
			ok, res = pcall(function() return store:GetAsync(key(plr)) end)
		end
		local prof = (ok and type(res) == "table") and migrate(res) or defaultProfile()
		cache[plr] = prof
		loaded[plr] = true
		return prof
	end

	local sessionId = tostring(os.time()) .. "_" .. tostring(math.random(1e6))
	local ok, res = retry(function()
		return store:UpdateAsync(key(plr), function(old)
			local prof = migrate(old) or defaultProfile()
			prof.sessionId = sessionId
			return prof
		end)
	end)

	if ok and type(res) == "table" then
		cache[plr] = res
		loaded[plr] = true
		return res
	end

	-- load failed: give a temporary profile but mark it unloaded so we NEVER save
	-- over whatever is really in the datastore.
	cache[plr] = defaultProfile()
	loaded[plr] = false
	warn(("[DSR] profile load failed for %s: %s"):format(plr.Name, tostring(res)))
	return cache[plr]
end

function Data.get(plr: Player)
	return cache[plr]
end

function Data.isLoaded(plr: Player)
	return loaded[plr] == true
end

function Data.markDirty(plr: Player)
	dirty[plr] = true
end

function Data.save(plr: Player, force: boolean?)
	local prof = cache[plr]
	if not prof then return false, "no profile" end
	if not loaded[plr] then return false, "profile never loaded - refusing to save" end
	if not force and not dirty[plr] then return true, "clean" end
	if not probeApi() then
		dirty[plr] = false
		return true, "volatile-noop"
	end
	local ok, err = retry(function()
		return store:UpdateAsync(key(plr), function(old)
			-- session protection: if another server claimed this profile, back off
			if type(old) == "table" and old.sessionId ~= "" and prof.sessionId ~= ""
				and old.sessionId ~= prof.sessionId then
				return nil
			end
			return prof
		end)
	end)
	if ok then
		dirty[plr] = false
	else
		warn(("[DSR] save failed for %s: %s"):format(plr.Name, tostring(err)))
	end
	return ok, err
end

function Data.release(plr: Player)
	Data.save(plr, true)
	cache[plr] = nil
	loaded[plr] = nil
	dirty[plr] = nil
end

-- autosave loop
function Data.startAutosave(interval: number)
	task.spawn(function()
		while true do
			task.wait(interval or 60)
			for _, plr in ipairs(Players:GetPlayers()) do
				if dirty[plr] then
					Data.save(plr)
				end
			end
		end
	end)
end

function Data.bindToClose()
	game:BindToClose(function()
		local jobs = {}
		for _, plr in ipairs(Players:GetPlayers()) do
			table.insert(jobs, task.spawn(function()
				Data.save(plr, true)
			end))
		end
		-- give saves a chance to land
		local t0 = os.clock()
		while os.clock() - t0 < 12 do
			local anyRunning = false
			for _, th in ipairs(jobs) do
				if coroutine.status(th) ~= "dead" then anyRunning = true break end
			end
			if not anyRunning then break end
			task.wait(0.2)
		end
	end)
end

return Data

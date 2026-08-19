--!strict
-- DON'T STOP RIDING :: analytics
--
-- Purpose is narrow: answer WHERE PLAYERS QUIT. Not to collect everything.
-- No personal data beyond UserId, which the server already has.
--
-- Events are aggregated per-session and flushed once on leave, so this costs
-- one DataStore write per player per session rather than a write per event.
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local A = {}

local store = nil
do
	local ok, res = pcall(function()
		return DataStoreService:GetDataStore("DSR_Analytics_v1")
	end)
	if ok then store = res end
end

local sessions: { [Player]: any } = {}

function A.begin(plr: Player)
	sessions[plr] = {
		joinedAt = os.clock(),
		runs = 0,
		crashes = 0,
		firstCrashTime = -1,
		bestDistance = 0,
		totalDistance = 0,
		maxTier = 0,
		shopOpens = 0,
		purchases = 0,
		challengesDone = 0,
		reachedCollapse = false,
	}
end

function A.get(plr: Player)
	return sessions[plr]
end

-- one run finished (crash or round end)
function A.run(plr: Player, distance: number, tier: number, collapse: boolean)
	local s = sessions[plr]
	if not s then return end
	s.runs += 1
	s.crashes += 1
	if s.firstCrashTime < 0 then
		s.firstCrashTime = os.clock() - s.joinedAt
	end
	s.bestDistance = math.max(s.bestDistance, distance)
	s.totalDistance += distance
	s.maxTier = math.max(s.maxTier, tier or 0)
	if collapse then s.reachedCollapse = true end
end

function A.event(plr: Player, name: string)
	local s = sessions[plr]
	if not s then return end
	if name == "shop_open" then s.shopOpens += 1
	elseif name == "purchase" then s.purchases += 1
	elseif name == "challenge" then s.challengesDone += 1 end
end

-- Flush once, on leave. Keyed by day so daily aggregates are cheap to read.
function A.finish(plr: Player)
	local s = sessions[plr]
	sessions[plr] = nil
	if not s or not store then return end

	s.sessionLength = os.clock() - s.joinedAt
	-- a session with no runs is the strongest quit signal we have
	s.quitWithoutRiding = (s.runs == 0)

	local day = math.floor(os.time() / 86400)
	local key = ("d%d_u%d"):format(day, plr.UserId)
	pcall(function()
		store:SetAsync(key, {
			runs = s.runs,
			sessionLength = math.floor(s.sessionLength),
			firstCrashTime = math.floor(s.firstCrashTime),
			bestDistance = math.floor(s.bestDistance),
			avgDistance = s.runs > 0 and math.floor(s.totalDistance / s.runs) or 0,
			maxTier = s.maxTier,
			shopOpens = s.shopOpens,
			purchases = s.purchases,
			challengesDone = s.challengesDone,
			reachedCollapse = s.reachedCollapse,
			quitWithoutRiding = s.quitWithoutRiding,
			at = os.time(),
		})
	end)

	-- D1/D7 return: record the last day this player was seen
	pcall(function()
		store:UpdateAsync("seen_u" .. plr.UserId, function(old)
			old = (type(old) == "table") and old or { days = {}, first = day }
			old.days = old.days or {}
			if not table.find(old.days, day) then
				table.insert(old.days, day)
				-- keep it bounded
				while #old.days > 30 do table.remove(old.days, 1) end
			end
			old.last = day
			return old
		end)
	end)
end

function A.bindLifecycle()
	Players.PlayerAdded:Connect(function(plr) A.begin(plr) end)
	Players.PlayerRemoving:Connect(function(plr) A.finish(plr) end)
	game:BindToClose(function()
		for _, plr in ipairs(Players:GetPlayers()) do
			A.finish(plr)
		end
	end)
	for _, plr in ipairs(Players:GetPlayers()) do A.begin(plr) end
end

return A

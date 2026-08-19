--!strict
-- DON'T STOP RIDING :: daily & weekly challenges (server-authoritative)
local RS = game:GetService("ReplicatedStorage")
local C = require(RS:WaitForChild("DSRConfig"))

local Ch = {}

local function blank()
	return { dayDistance = 0, bestRun = 0, runs = 0, bestTime = 0, collapse = 0 }
end

-- Roll the period over if the day/week changed. Progress resets; anything the
-- player already earned stays paid out (we never claw rewards back).
function Ch.refresh(prof)
	prof.daily = prof.daily or { day = 0, progress = blank(), claimed = {} }
	prof.weekly = prof.weekly or { week = 0, progress = blank(), claimed = {} }

	local d, w = C.dayIndex(), C.weekIndex()
	if prof.daily.day ~= d then
		prof.daily.day = d
		prof.daily.progress = blank()
		prof.daily.claimed = {}
	end
	if prof.weekly.week ~= w then
		prof.weekly.week = w
		prof.weekly.progress = blank()
		prof.weekly.claimed = {}
	end
	-- guard against a partially-migrated save
	for _, key in ipairs({ "dayDistance", "bestRun", "runs", "bestTime", "collapse" }) do
		prof.daily.progress[key] = prof.daily.progress[key] or 0
		prof.weekly.progress[key] = prof.weekly.progress[key] or 0
	end
end

-- Record one completed run. All inputs come from the server's own view.
-- Returns a list of newly completed challenges (for the toast) and total coins.
function Ch.recordRun(prof, distance: number, seconds: number, reachedCollapse: boolean)
	Ch.refresh(prof)
	local newly, coins = {}, 0

	for _, bucket in ipairs({
		{ store = prof.daily,  defs = C.DAILY,  label = "DAILY" },
		{ store = prof.weekly, defs = C.WEEKLY, label = "WEEKLY" },
	}) do
		local p = bucket.store.progress
		p.dayDistance += distance
		p.bestRun = math.max(p.bestRun, distance)
		p.runs += 1
		p.bestTime = math.max(p.bestTime, seconds)
		if reachedCollapse then p.collapse = 1 end

		for _, def in ipairs(bucket.defs) do
			if not bucket.store.claimed[def.id] then
				local have = p[def.stat] or 0
				if have >= def.target then
					bucket.store.claimed[def.id] = true
					coins += def.reward
					table.insert(newly, { text = def.text, reward = def.reward, label = bucket.label })
				end
			end
		end
	end

	if coins > 0 then
		prof.coins = (prof.coins or 0) + coins
	end
	return newly, coins
end

-- Snapshot for the client UI.
function Ch.snapshot(prof)
	Ch.refresh(prof)
	local function pack(defs, store)
		local out = {}
		for _, def in ipairs(defs) do
			table.insert(out, {
				id = def.id, text = def.text, target = def.target, reward = def.reward,
				have = math.floor(store.progress[def.stat] or 0),
				done = store.claimed[def.id] == true,
			})
		end
		return out
	end
	return { daily = pack(C.DAILY, prof.daily), weekly = pack(C.WEEKLY, prof.weekly) }
end

return Ch

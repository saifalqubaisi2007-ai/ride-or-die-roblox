--!strict
-- DON'T STOP RIDING :: global leaderboards (OrderedDataStore)
-- Degrades safely when the place is unpublished: falls back to a server-local
-- board so the UI always has something to show and nothing ever errors.
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local L = {}

local PERIODS = {
	{ key = "alltime", label = "ALL TIME", bucket = function() return "all" end },
	{ key = "daily",   label = "TODAY",    bucket = function() return "d" .. math.floor(os.time() / 86400) end },
	{ key = "weekly",  label = "WEEKLY",   bucket = function() return "w" .. math.floor(os.time() / 604800) end },
}
L.PERIODS = PERIODS

local stores: { [string]: OrderedDataStore? } = {}
local available = true

local function storeFor(period)
	local name = "DSR_LB_" .. period.key .. "_" .. period.bucket()
	if stores[name] ~= nil then return stores[name] end
	local ok, res = pcall(function()
		return DataStoreService:GetOrderedDataStore(name)
	end)
	if ok then
		stores[name] = res
	else
		stores[name] = nil
		available = false
		warn("[DSR] leaderboards unavailable: " .. tostring(res))
	end
	return stores[name]
end

-- server-local fallback so the panel is never empty in an unpublished place
local localBoard: { [number]: { name: string, score: number } } = {}

function L.submit(plr: Player, distance: number)
	if typeof(distance) ~= "number" or distance ~= distance or distance <= 0 then return end
	local score = math.floor(distance)

	local prev = localBoard[plr.UserId]
	if not prev or score > prev.score then
		localBoard[plr.UserId] = { name = plr.DisplayName, score = score }
	end

	for _, period in ipairs(PERIODS) do
		local store = storeFor(period)
		if store then
			task.spawn(function()
				pcall(function()
					store:UpdateAsync(tostring(plr.UserId), function(old)
						if old and old >= score then return nil end
						return score
					end)
				end)
			end)
		end
	end
end

local cache: { [string]: { at: number, rows: any } } = {}

function L.top(periodKey: string, count: number?)
	count = math.clamp(count or 10, 1, 25)
	local c = cache[periodKey]
	if c and os.clock() - c.at < 45 then
		return c.rows
	end

	local period
	for _, p in ipairs(PERIODS) do
		if p.key == periodKey then period = p end
	end
	if not period then return {} end

	local rows = {}
	local store = storeFor(period)
	if store then
		local ok, pages = pcall(function()
			return store:GetSortedAsync(false, count)
		end)
		if ok and pages then
			local okPage, page = pcall(function() return pages:GetCurrentPage() end)
			if okPage and page then
				for _, entry in ipairs(page) do
					local uid = tonumber(entry.key)
					local name = "Player"
					if uid then
						local okn, n = pcall(function() return Players:GetNameFromUserIdAsync(uid) end)
						if okn and n then name = n end
					end
					table.insert(rows, { name = name, score = entry.value })
				end
			end
		end
	end

	if #rows == 0 then
		-- fallback: this server's own best distances
		for uid, rec in pairs(localBoard) do
			table.insert(rows, { name = rec.name, score = rec.score })
		end
		table.sort(rows, function(a, b) return a.score > b.score end)
		while #rows > count do table.remove(rows) end
	end

	cache[periodKey] = { at = os.clock(), rows = rows }
	return rows
end

function L.isGlobal(): boolean
	return available
end

return L

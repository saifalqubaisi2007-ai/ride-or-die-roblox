--!strict
-- DON'T STOP RIDING :: monetization
--
-- IMPORTANT: the IDs below are placeholders. Create the products/passes in the
-- Creator Dashboard once the place is published and paste the real IDs here.
-- Anything left at 0 is treated as "not configured" and is never prompted,
-- so the game runs correctly with none of them set up.
--
-- Design rule from the brief: cosmetics and convenience only. Nothing here
-- grants speed, invincibility, distance, or any gameplay advantage.
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local M = {}

M.PASSES = {
	vip      = { id = 0, name = "VIP COSMETIC PACK", perk = "Exclusive trail + 10% coin bonus" },
	doubleCoins = { id = 0, name = "2X COINS",        perk = "Double coins from every ride" },
}

M.PRODUCTS = {
	[0] = nil,  -- placeholder table; real entries keyed by product id
}

-- coin packs: productId -> coins granted
M.COIN_PACKS = {
	-- [123456789] = 1000,
	-- [123456790] = 5500,
}

local Data
function M.init(dataModule)
	Data = dataModule
end

local ownedCache: { [Player]: { [string]: boolean } } = {}

function M.owns(plr: Player, passKey: string): boolean
	local pass = M.PASSES[passKey]
	if not pass or pass.id == 0 then return false end
	ownedCache[plr] = ownedCache[plr] or {}
	local cached = ownedCache[plr][passKey]
	if cached ~= nil then return cached end
	local ok, res = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(plr.UserId, pass.id)
	end)
	local owns = ok and res == true
	ownedCache[plr][passKey] = owns
	return owns
end

-- coin multiplier applied at payout time (server-side only)
function M.coinMultiplier(plr: Player): number
	local mult = 1
	if M.owns(plr, "doubleCoins") then mult *= 2 end
	if M.owns(plr, "vip") then mult *= 1.1 end
	return mult
end

function M.prompt(plr: Player, kind: string, key)
	if kind == "pass" then
		local pass = M.PASSES[key]
		if not pass or pass.id == 0 then return false, "Not available yet" end
		pcall(function() MarketplaceService:PromptGamePassPurchase(plr, pass.id) end)
		return true
	elseif kind == "product" then
		local id = tonumber(key)
		if not id or id == 0 or not M.COIN_PACKS[id] then return false, "Not available yet" end
		pcall(function() MarketplaceService:PromptProductPurchase(plr, id) end)
		return true
	end
	return false, "Unknown purchase"
end

-- Receipt handling. Grant FIRST, persist, and only then report granted --
-- returning PurchaseGranted before a successful save would let a crash eat a
-- paid purchase with no way to recover it.
function M.setupReceipts()
	MarketplaceService.ProcessReceipt = function(info)
		local plr = Players:GetPlayerByUserId(info.PlayerId)
		if not plr then
			-- player left: do not consume the receipt, Roblox will retry
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local prof = Data and Data.get(plr)
		if not prof or not Data.isLoaded(plr) then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		prof.receipts = prof.receipts or {}
		if prof.receipts[info.PurchaseId] then
			-- already granted in a previous attempt
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end

		local coins = M.COIN_PACKS[info.ProductId]
		if not coins then
			-- Unknown product: we must consume it (NotProcessedYet would retry
			-- forever), but the player has paid for nothing. Loud warning so a
			-- product added in the dashboard but not in COIN_PACKS is caught.
			warn(("[DSR] UNCONFIGURED PRODUCT %d purchased by %s -- add it to COIN_PACKS")
				:format(info.ProductId, plr.Name))
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end

		prof.coins = (prof.coins or 0) + coins
		prof.receipts[info.PurchaseId] = os.time()

		-- keep the receipt ledger bounded; Roblox stops retrying long before
		-- this many purchases accumulate, so older entries are safe to drop
		local ids = {}
		for id, t in pairs(prof.receipts) do
			table.insert(ids, { id = id, t = (type(t) == "number") and t or 0 })
		end
		if #ids > 40 then
			table.sort(ids, function(a, b) return a.t < b.t end)
			for i = 1, #ids - 40 do
				prof.receipts[ids[i].id] = nil
			end
		end

		Data.markDirty(plr)

		local ok = Data.save(plr, true)
		if not ok then
			-- roll back the in-memory grant so the retry can apply it cleanly
			prof.coins -= coins
			prof.receipts[info.PurchaseId] = nil
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
end

Players.PlayerRemoving:Connect(function(plr)
	ownedCache[plr] = nil
end)

-- Ownership was cached for the whole session, so buying a pass mid-session left
-- owns() returning false until rejoin: the player paid and saw no perk. Clear
-- the cache the moment a purchase completes so the next check re-queries.
MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(plr, passId, wasPurchased)
	if not wasPurchased then return end
	if ownedCache[plr] then
		for key, pass in pairs(M.PASSES) do
			if pass.id == passId then
				ownedCache[plr][key] = nil
			end
		end
	end
end)

function M.configured(): boolean
	if next(M.COIN_PACKS) ~= nil then return true end
	for _, p in pairs(M.PASSES) do
		if p.id ~= 0 then return true end
	end
	return false
end

return M

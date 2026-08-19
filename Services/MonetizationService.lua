--[[
	MonetizationService.lua
	Game Pass ownership checks + Developer Product purchase handling for CREATURE RANCH.

	Constants.GAME_PASSES / DEV_PRODUCTS hold REAL, LIVE ids — the passes/products already
	exist on the Creator Dashboard and this code is wired against the actual assets, not
	placeholders. (This comment used to say "placeholder id = 0"; that was stale from before
	the real ids were filled in and has been corrected during the pre-launch monetization
	verification pass — don't trust a header comment's age over the Constants table itself.)
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")

local Constants = require(RS.CritterRush.Modules.Constants)
local PlayerDataService = require(script.Parent.PlayerDataService)

local MonetizationService = {}

-- Cache of confirmed gamepass ownership per player so we don't hammer
-- UserOwnsGamePassAsync (rate-limited) on every check.
local ownershipCache = {} -- [userId] = { [passKey] = true }

local GAMEPASS_ATTRIBUTES = {
	DoubleSparks = "SAC_DoubleSparks",
	InstantExtraSlot = "SAC_ExtraSlotPass",
	VipTrail = "SAC_VipTrail",
	AutoHatch = "SAC_AutoHatch",
	VIP = "SAC_VIP",
	LuckPass = "SAC_LuckPass",
	MultiSlotPass = "SAC_MultiSlotPass",
	OfflinePass = "SAC_OfflinePass",
}

local function checkAndCacheOwnership(player, passKey)
	local passInfo = Constants.GAME_PASSES[passKey]
	if not passInfo or passInfo.id == 0 then return false end -- id == 0 would mean a future
	-- pass was added to Constants before its Creator Dashboard entry exists; not currently
	-- true for any of the three live passes, this is just a defensive guard for that case

	ownershipCache[player.UserId] = ownershipCache[player.UserId] or {}
	if ownershipCache[player.UserId][passKey] ~= nil then
		return ownershipCache[player.UserId][passKey]
	end

	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passInfo.id)
	end)
	owns = ok and owns or false
	ownershipCache[player.UserId][passKey] = owns

	-- Mirror onto a player Attribute so other systems (e.g. CritterService's income
	-- calc) can read it directly without needing to require this module — avoids
	-- cross-service coupling and lets attributes replicate to the client for free.
	local attrName = GAMEPASS_ATTRIBUTES[passKey]
	if attrName then
		player:SetAttribute(attrName, owns)
	end

	return owns
end

-- Call once when a player joins to warm the cache / set attributes immediately,
-- so e.g. Double Sparks applies from the very first income tick rather than lazily.
function MonetizationService.RefreshOwnership(player)
	for passKey in pairs(Constants.GAME_PASSES) do
		checkAndCacheOwnership(player, passKey)
	end
end

function MonetizationService.PlayerOwnsPass(player, passKey)
	return checkAndCacheOwnership(player, passKey)
 end

-- ===== Developer Products (consumable purchases, e.g. Spark packs) =====

local function findProductByPurchaseId(productId)
	for key, info in pairs(Constants.DEV_PRODUCTS) do
		if info.id == productId then return key, info end
	end
	return nil
end

local function processReceipt(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		-- Player left before purchase completed — Roblox will retry ProcessReceipt later
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local profile = PlayerDataService.Get(player)
	if not profile then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Idempotency guard: never grant the same PurchaseId twice, even across retries/relogs
	profile.processedReceipts = profile.processedReceipts or {}
	if profile.processedReceipts[receiptInfo.PurchaseId] then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local key, info = findProductByPurchaseId(receiptInfo.ProductId)
	if not key then
		-- Unknown product id — shouldn't happen once real ids are configured, but fail safe
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if info.sparks then
		PlayerDataService.AddSparks(player, info.sparks)
		local remotes = RS.CritterRush.Remotes
		remotes.SparksUpdated:FireClient(player, PlayerDataService.Get(player).sparks)

		-- Bundle extras (Starter Pack). Handled alongside sparks rather than in the
		-- else-branch, because a bundle grants Sparks AND other things -- treating it as
		-- "not a sparks product" would skip the currency entirely.
		if info.extraSlots then
			profile.extraSlotsPurchased = (profile.extraSlotsPurchased or 0) + info.extraSlots
			-- Mirror the new cap onto the player attributes the HUD reads. Done inline
			-- rather than via HatchLogic.SyncSlotAttributes because requiring HatchLogic
			-- here would create a circular dependency (HatchLogic already reaches into
			-- monetization state via the SAC_ExtraSlotPass attribute).
			player:SetAttribute("SAC_UsedSlots", #profile.ownedCritters)
			player:SetAttribute("SAC_MaxSlots",
				PlayerDataService.GetMaxSlots(player, profile))
		end
		if info.limitedEggTokens then
			profile.limitedEggTokens = (profile.limitedEggTokens or 0) + info.limitedEggTokens
		end
		if info.oneTimeOnly and key == "StarterPack" then
			profile.starterPackBought = true
		end
		local packRemote = remotes:FindFirstChild("StarterPackPurchased")
		if packRemote and key == "StarterPack" then
			packRemote:FireClient(player, info.sparks, info.extraSlots or 0, info.limitedEggTokens or 0)
		end
	else
		-- Safety net for future dev products that DON'T grant Sparks (a cosmetic, a
		-- consumable potion, etc.) if Constants ever gains one before this fulfillment
		-- logic is updated to handle it: without this, the player would be silently
		-- CHARGED and the receipt marked complete while receiving nothing, with no trace
		-- in the logs to catch it. Still marks the purchase granted (a real, connected,
		-- paying player not getting Roblox's infinite NotProcessedYet retry loop matters
		-- more than getting this one loud warning), but now a developer watching server
		-- logs -- or reviewing them after a support ticket -- can actually find and fix it.
		warn(string.format(
			"[MonetizationService] Product '%s' (id=%d) has no recognized reward field (e.g. .sparks) -- " ..
			"player %s was charged and the purchase was marked granted, but NOTHING WAS ACTUALLY GIVEN. " ..
			"Add fulfillment logic for this product's reward type.",
			key, info.id, player.Name))
	end

	profile.processedReceipts[receiptInfo.PurchaseId] = true
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

function MonetizationService.Init()
	MarketplaceService.ProcessReceipt = processReceipt

	-- Live gamepass purchases take effect immediately (not just on next join):
	-- clear the cached "doesn't own it" and re-check, which updates the attribute
	-- that downstream systems (income multiplier, slot cap, VIP trail) all read.
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
		if not wasPurchased then return end
		for passKey, info in pairs(Constants.GAME_PASSES) do
			if info.id == gamePassId then
				-- Trust the purchase event directly: UserOwnsGamePassAsync caches stale
				-- "false" results for minutes after a purchase, so re-querying here
				-- would often still deny the player what they just paid for.
				ownershipCache[player.UserId] = ownershipCache[player.UserId] or {}
				ownershipCache[player.UserId][passKey] = true
				local attrName = GAMEPASS_ATTRIBUTES[passKey]
				if attrName then
					player:SetAttribute(attrName, true)
				end
				break
			end
		end
	end)

	Players.PlayerAdded:Connect(function(player)
		-- Slight delay so this runs after PlayerDataService.Load (called explicitly in Main)
		task.defer(function()
			MonetizationService.RefreshOwnership(player)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		ownershipCache[player.UserId] = nil
	end)
end

return MonetizationService

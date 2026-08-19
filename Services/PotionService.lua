--[[
	PotionService.lua
	Timed consumable boosts bought with Sparks.

	Two decisions worth stating:
	 * Buying a potion you already hold EXTENDS its timer rather than stacking the
	   multiplier. Stacking would let a wealthy player chain 20 Luck potions into a 2^20
	   multiplier -- an obvious economy break.
	 * Expiry is an absolute timestamp, so potions tick down while offline. Otherwise
	   "buy one, log off" would preserve a boost indefinitely.
]]

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Constants = require(RS.CritterRush.Modules.Constants)
local PlayerDataService = require(script.Parent.PlayerDataService)
local AnalyticsService = require(script.Parent.AnalyticsService)

local remotes = RS.CritterRush.Remotes

local PotionService = {}

-- Pushes each potion's live multiplier onto player attributes. Attributes are what the
-- luck/income systems already read, so this is the ONLY place potions need to integrate.
local function syncAttributes(player, profile)
	local now = os.time()
	for _, potion in pairs(Constants.POTIONS) do
		local expiry = profile.activePotions[potion.id]
		if expiry and expiry > now then
			player:SetAttribute(potion.attribute, potion.multiplier)
		else
			player:SetAttribute(potion.attribute, nil)
			if expiry then profile.activePotions[potion.id] = nil end
		end
	end
end

function PotionService.SyncPlayer(player)
	local profile = PlayerDataService.Get(player)
	if not profile then return end
	profile.activePotions = profile.activePotions or {}
	syncAttributes(player, profile)
	PotionService.PushState(player)
end

function PotionService.PushState(player)
	local profile = PlayerDataService.Get(player)
	if not profile then return end
	local now = os.time()
	local state = {}
	for _, potion in pairs(Constants.POTIONS) do
		local expiry = profile.activePotions[potion.id]
		state[potion.id] = (expiry and expiry > now) and (expiry - now) or 0
	end
	local r = remotes:FindFirstChild("PotionState")
	if r then r:FireClient(player, state) end
end

-- Returns (true, secondsRemaining) or (false, reason).
function PotionService.Buy(player, potionId)
	local potion = Constants.POTIONS[potionId]
	if not potion then return false, "UnknownPotion" end
	local profile = PlayerDataService.Get(player)
	if not profile then return false, "NoProfile" end
	profile.activePotions = profile.activePotions or {}

	local now = os.time()
	local current = profile.activePotions[potion.id]
	local base = (current and current > now) and current or now
	-- Cap total stacked duration so a player can't buy an entire day of boost at once.
	if (base + potion.durationSeconds) - now > Constants.POTION_MAX_STACK_SECONDS then
		return false, "MaxDuration"
	end

	if not PlayerDataService.TrySpendSparks(player, potion.cost) then
		return false, "InsufficientSparks"
	end

	profile.activePotions[potion.id] = base + potion.durationSeconds
	syncAttributes(player, profile)

	remotes.SparksUpdated:FireClient(player, PlayerDataService.Get(player).sparks)
	AnalyticsService.LogPotionPurchase(player, potion.cost, PlayerDataService.Get(player).sparks, potion.id)
	PotionService.PushState(player)
	return true, profile.activePotions[potion.id] - now
end

function PotionService.Init()
	remotes.RequestBuyPotion.OnServerEvent:Connect(function(player, potionId)
		if typeof(potionId) ~= "string" then return end
		local ok, result = PotionService.Buy(player, potionId)
		remotes.PotionPurchased:FireClient(player, ok, potionId, result)
	end)

	remotes.RequestPotionState.OnServerEvent:Connect(function(player)
		PotionService.PushState(player)
	end)

	-- Expiry sweep. Attributes must be cleared the moment a potion lapses, or the
	-- player would keep the boost until their next purchase happened to resync.
	task.spawn(function()
		while true do
			task.wait(5)
			for _, player in ipairs(Players:GetPlayers()) do
				local profile = PlayerDataService.Get(player)
				if profile and profile.activePotions then
					local hadAny = next(profile.activePotions) ~= nil
					syncAttributes(player, profile)
					if hadAny then PotionService.PushState(player) end
				end
			end
		end
	end)
end

return PotionService

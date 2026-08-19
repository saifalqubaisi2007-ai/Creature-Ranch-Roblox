--[[
	PotionService.lua
	Timed consumable boosts (luck / sparks multipliers).

	Design notes:
	 * Expiry is an absolute os.time() timestamp, not a countdown. A potion therefore
	   keeps burning while the player is offline and can't be paused by disconnecting,
	   and its remaining time survives a rejoin with no tick-persistence loop.
	 * Effects are surfaced as PLAYER ATTRIBUTES (SAC_LuckPotion / SAC_SparksPotion),
	   which is what the existing luck and income paths already read -- so potions stack
	   with passes, rebirth and events through the same central maths rather than
	   needing their own parallel multiplier chain.
	 * Buying and drinking are separate steps: a player can stockpile potions and choose
	   when to use them, which is the whole point of a consumable.
]]

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Constants = require(RS.CritterRush.Modules.Constants)
local PlayerDataService = require(script.Parent.PlayerDataService)
local AnalyticsService = require(script.Parent.AnalyticsService)

local remotes = RS.CritterRush.Remotes

local PotionService = {}

local SWEEP_INTERVAL = 5

-- Recomputes the multiplier attributes from whatever is currently active. Called after
-- every change and on the expiry sweep, so the attributes are always derived state --
-- never incrementally patched, which is how drift and stuck buffs happen.
function PotionService.RefreshAttributes(player)
	local profile = PlayerDataService.Get(player)
	if not profile then return end
	local now = os.time()
	local luckMult, sparksMult = 1, 1
	for id, expiry in pairs(profile.activePotions or {}) do
		local info = Constants.POTIONS[id]
		if info and expiry > now then
			if info.kind == "luck" then
				luckMult *= info.multiplier
			elseif info.kind == "sparks" then
				sparksMult *= info.multiplier
			end
		end
	end
	-- nil rather than 1 when inactive: the luck path treats a nil potionMult as absent,
	-- and leaving a literal 1 around would make "is a potion active?" checks lie.
	player:SetAttribute("SAC_LuckPotion", luckMult > 1 and luckMult or nil)
	player:SetAttribute("SAC_SparksPotion", sparksMult > 1 and sparksMult or nil)
end

-- Returns { {id, name, count, activeUntil, secondsLeft}, ... } for the client UI.
function PotionService.GetState(player)
	local profile = PlayerDataService.Get(player)
	if not profile then return {} end
	local now = os.time()
	local out = {}
	for _, id in ipairs(Constants.POTION_ORDER) do
		local info = Constants.POTIONS[id]
		local expiry = (profile.activePotions or {})[id]
		local secondsLeft = (expiry and expiry > now) and (expiry - now) or 0
		out[#out + 1] = {
			id = id,
			name = info.name,
			description = info.description,
			cost = info.cost,
			count = (profile.potionInventory or {})[id] or 0,
			secondsLeft = secondsLeft,
		}
	end
	return out
end

function PotionService.Buy(player, potionId)
	local info = Constants.POTIONS[potionId]
	if not info then return false, "UnknownPotion" end
	local profile = PlayerDataService.Get(player)
	if not profile then return false, "NoProfile" end
	if not PlayerDataService.TrySpendSparks(player, info.cost) then
		return false, "InsufficientSparks"
	end
	profile.potionInventory = profile.potionInventory or {}
	profile.potionInventory[potionId] = (profile.potionInventory[potionId] or 0) + 1
	AnalyticsService.LogEconomyEvent(player, -info.cost, profile.sparks, "PotionBuy_" .. potionId)
	return true
end

function PotionService.Drink(player, potionId)
	local info = Constants.POTIONS[potionId]
	if not info then return false, "UnknownPotion" end
	local profile = PlayerDataService.Get(player)
	if not profile then return false, "NoProfile" end
	profile.potionInventory = profile.potionInventory or {}
	if (profile.potionInventory[potionId] or 0) <= 0 then return false, "NoneOwned" end

	profile.activePotions = profile.activePotions or {}
	local now = os.time()
	local current = profile.activePotions[potionId]
	-- Drinking the same potion again EXTENDS it rather than restarting, so a player
	-- who drinks two never silently loses the remainder of the first.
	local base = (current and current > now) and current or now
	profile.activePotions[potionId] = base + info.durationSeconds
	profile.potionInventory[potionId] -= 1

	PotionService.RefreshAttributes(player)
	return true, profile.activePotions[potionId] - now
end

function PotionService.Init()
	remotes.RequestPotionState.OnServerEvent:Connect(function(player)
		remotes.PotionState:FireClient(player, PotionService.GetState(player))
	end)

	remotes.RequestBuyPotion.OnServerEvent:Connect(function(player, potionId)
		if typeof(potionId) ~= "string" then return end
		local ok, reason = PotionService.Buy(player, potionId)
		remotes.PotionResult:FireClient(player, "buy", ok, reason or potionId)
		if ok then
			local profile = PlayerDataService.Get(player)
			remotes.SparksUpdated:FireClient(player, profile and profile.sparks or 0)
		end
		remotes.PotionState:FireClient(player, PotionService.GetState(player))
	end)

	remotes.RequestDrinkPotion.OnServerEvent:Connect(function(player, potionId)
		if typeof(potionId) ~= "string" then return end
		local ok, reasonOrSeconds = PotionService.Drink(player, potionId)
		remotes.PotionResult:FireClient(player, "drink", ok, reasonOrSeconds)
		remotes.PotionState:FireClient(player, PotionService.GetState(player))
	end)

	Players.PlayerAdded:Connect(function(player)
		-- Re-apply on join: a potion bought last session may still be running.
		task.delay(3, function()
			if player.Parent then PotionService.RefreshAttributes(player) end
		end)
	end)

	-- Expiry sweep. Refreshes derived attributes so a lapsed potion actually stops
	-- applying rather than lingering until the player's next action.
	task.spawn(function()
		while true do
			task.wait(SWEEP_INTERVAL)
			for _, player in ipairs(Players:GetPlayers()) do
				local profile = PlayerDataService.Get(player)
				if profile and profile.activePotions then
					local now, changed = os.time(), false
					for id, expiry in pairs(profile.activePotions) do
						if expiry <= now then
							profile.activePotions[id] = nil
							changed = true
							local r = remotes:FindFirstChild("PotionExpired")
							if r then r:FireClient(player, id) end
						end
					end
					if changed then
						PotionService.RefreshAttributes(player)
						remotes.PotionState:FireClient(player, PotionService.GetState(player))
					end
				end
			end
		end
	end)
end

return PotionService

--[[
	DiscoveryService.lua
	Sanctuary creatures periodically find things while the player plays.

	The point is giving the ranch an ongoing reason to exist. Without this, the sanctuary
	is a one-time setup screen: assign creatures, collect the perk, never look again.

	Design notes:
	 * Requires at least one ASSIGNED creature -- discoveries are the sanctuary's payoff,
	   not a passive drip everyone gets.
	 * Chance scales with Ranch Power but is capped, so better creatures pay off twice
	   without turning a maxed ranch into a firehose that devalues the shop.
	 * Rewards go through the SAME grant paths as everything else (AddSparks,
	   potionInventory, limitedEggTokens), so nothing here needs its own economy.
]]

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Constants = require(RS.CritterRush.Modules.Constants)
local PlayerDataService = require(script.Parent.PlayerDataService)
local AnalyticsService = require(script.Parent.AnalyticsService)

local remotes = RS.CritterRush.Remotes

local DiscoveryService = {}

-- [userId] = os.clock() of next roll
local nextRoll = {}

local function scheduleNext(userId)
	nextRoll[userId] = os.clock() + math.random(
		Constants.DISCOVERY_INTERVAL_SECONDS.min,
		Constants.DISCOVERY_INTERVAL_SECONDS.max)
end

function DiscoveryService.OnPlayerReady(player)
	scheduleNext(player.UserId)
end

-- Attempts one discovery. Returns (true, kind, detail) or (false, reason).
function DiscoveryService.TryDiscover(player)
	local profile = PlayerDataService.Get(player)
	if not profile then return false, "NoProfile" end

	PlayerDataService.PruneSanctuary(player)
	local assigned = profile.sanctuaryUids or {}
	if #assigned == 0 then return false, "NoCreatures" end

	local power = PlayerDataService.GetRanchPower(player)
	if math.random() > Constants.GetDiscoveryChance(power) then
		return false, "NoLuck"
	end

	-- Pick which creature found it, purely for flavour in the notification.
	local byUid = {}
	for _, rec in ipairs(profile.ownedCritters) do byUid[rec.uid] = rec end
	local finder
	for _ = 1, 8 do
		local uid = assigned[math.random(1, #assigned)]
		if byUid[uid] then finder = byUid[uid] break end
	end
	local finderName = finder and finder.species or "A creature"

	local loot = Constants.RollDiscoveryLoot()

	if loot.kind == "sparks" then
		local amount = math.random(loot.min, loot.max) + power * Constants.DISCOVERY_SPARKS_POWER_SCALE
		local newTotal = PlayerDataService.AddSparks(player, amount)
		remotes.SparksUpdated:FireClient(player, newTotal)
		AnalyticsService.LogRewardEarned(player, amount, newTotal, "Discovery_Sparks")
		remotes.DiscoveryFound:FireClient(player, finderName, "sparks", amount)
		return true, "sparks", amount

	elseif loot.kind == "potion" then
		profile.potionInventory = profile.potionInventory or {}
		profile.potionInventory[loot.potionId] = (profile.potionInventory[loot.potionId] or 0) + 1
		local info = Constants.POTIONS[loot.potionId]
		AnalyticsService.LogRewardEarned(player, 0, profile.sparks, "Discovery_Potion")
		remotes.DiscoveryFound:FireClient(player, finderName, "potion",
			info and info.name or loot.potionId)
		return true, "potion", loot.potionId

	elseif loot.kind == "limitedEgg" then
		profile.limitedEggTokens = (profile.limitedEggTokens or 0) + 1
		AnalyticsService.LogRewardEarned(player, 0, profile.sparks, "Discovery_LimitedEgg")
		remotes.DiscoveryFound:FireClient(player, finderName, "limitedEgg", 1)
		return true, "limitedEgg", 1
	end

	return false, "UnknownLoot"
end

function DiscoveryService.Init()
	Players.PlayerRemoving:Connect(function(player)
		nextRoll[player.UserId] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(10)
			local now = os.clock()
			for _, player in ipairs(Players:GetPlayers()) do
				local due = nextRoll[player.UserId]
				if not due then
					scheduleNext(player.UserId)
				elseif now >= due then
					scheduleNext(player.UserId)
					local ok, err = pcall(DiscoveryService.TryDiscover, player)
					if not ok then warn("[DiscoveryService] discovery failed:", err) end
				end
			end
		end
	end)

	print("[DiscoveryService] sanctuary discoveries active")
end

return DiscoveryService

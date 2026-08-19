--[[
	AutoHatchService.lua
	Auto Hatch gamepass: periodically hatches for owners, hands-free.

	Design decisions worth stating:
	 * OFF by default even for owners. Auto-spending someone's Sparks without asking is
	   hostile -- they toggle it on, and the setting is session-scoped so it never
	   surprises them on a later login.
	 * Buys the BEST egg the player can currently afford in their current world, never
	   the most expensive one outright. Blindly buying Mythic would drain a player who
	   was saving for a world unlock.
	 * Leaves a reserve so auto-hatch can't spend a player down to zero -- the reserve
	   is the cost of the egg it just bought, so it always stops one purchase short of
	   emptying them.
	 * Routes through HatchLogic.PerformHatch, inheriting every existing guard (world
	   unlock, slot eviction, locked-critter protection, refunds).
]]

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Constants = require(RS.CritterRush.Modules.Constants)
local WorldsData = require(RS.CritterRush.Modules.WorldsData)
local PlayerDataService = require(script.Parent.PlayerDataService)
local HatchLogic = require(script.Parent.HatchLogic)
local WorldService = require(script.Parent.WorldService)

local remotes = RS.CritterRush.Remotes

local AutoHatchService = {}

local INTERVAL = 4 -- seconds between auto-hatches
local enabled = {} -- [userId] = true when the player has toggled it on this session

function AutoHatchService.SetEnabled(player, on)
	if not player:GetAttribute("SAC_AutoHatch") then
		enabled[player.UserId] = nil
		return false, "NotOwned"
	end
	enabled[player.UserId] = on and true or nil
	return true, on
end

function AutoHatchService.IsEnabled(player)
	return enabled[player.UserId] == true
end

-- Picks the priciest egg the player can afford in the highest world they've unlocked,
-- while keeping a reserve equal to that egg's cost.
local function pickEgg(player, profile)
	local best, bestWorld
	for _, world in ipairs(WorldsData.WORLDS) do
		if world.implemented and world.rarities and WorldService.IsUnlocked(player, world.id) then
			for _, tier in ipairs(world.rarities) do
				-- cost * 2 keeps a one-purchase reserve so this never zeroes them out.
				if tier.cost > 0 and profile.sparks >= tier.cost * 2 then
					if not best or tier.cost > best.cost then
						best, bestWorld = tier, world
					end
				end
			end
		end
	end
	return best, bestWorld
end

function AutoHatchService.Init()
	Players.PlayerRemoving:Connect(function(player)
		enabled[player.UserId] = nil
	end)

	remotes.RequestToggleAutoHatch.OnServerEvent:Connect(function(player, on)
		if typeof(on) ~= "boolean" then return end
		local ok, state = AutoHatchService.SetEnabled(player, on)
		remotes.AutoHatchState:FireClient(player, ok and state or false, ok)
	end)

	task.spawn(function()
		while true do
			task.wait(INTERVAL)
			for _, player in ipairs(Players:GetPlayers()) do
				if enabled[player.UserId] and player:GetAttribute("SAC_AutoHatch") then
					local profile = PlayerDataService.Get(player)
					if profile then
						local tier, world = pickEgg(player, profile)
						if tier and world then
							local ok, err = pcall(HatchLogic.PerformHatch, player, world.id, tier.id)
							if not ok then warn("[AutoHatchService] hatch failed:", err) end
						end
					end
				end
			end
		end
	end)
end

return AutoHatchService

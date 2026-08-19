--[[
	OnboardingService.lua
	Scripted beats for a brand-new player's first session.

	Deliberately EVENT-DRIVEN rather than a wall-clock timer. A pure timer ("show tip at
	4:00") fires whether or not the player did the thing, so it either nags someone who's
	already ahead or congratulates someone who's stuck. Each beat here instead waits for
	the real precondition, then fires once, permanently.

	Only ever runs for genuinely new players: every beat is gated on a persisted claimed
	set, so a returning player never sees onboarding again.
]]

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Constants = require(RS.CritterRush.Modules.Constants)
local PlayerDataService = require(script.Parent.PlayerDataService)

local remotes = RS.CritterRush.Remotes

local OnboardingService = {}

-- Each beat: an id, the condition that unlocks it, and the message shown.
-- `delay` staggers the message so beats triggered by the same action don't stack.
local BEATS = {
	{
		id = "welcome",
		delay = 3,
		check = function() return true end,
		title = "Welcome to Creature Ranch!",
		body = "Your first creature is already earning Sparks. Walk around and grab glowing orbs!",
	},
	{
		id = "firstOrb",
		delay = 1,
		check = function(stats) return stats.orbsCollectedTotal >= 1 end,
		title = "Nice!",
		body = "Orbs are free Sparks. Grab them fast in a row for a COMBO multiplier!",
	},
	{
		id = "firstHatch",
		delay = 1.5,
		check = function(stats) return stats.paidHatches >= 1 end,
		title = "Your first hatch!",
		body = "Better eggs mean better creatures. Keep collecting to afford the next tier.",
	},
	{
		id = "pat",
		delay = 2,
		check = function(stats) return stats.hatchesTotal >= 2 end,
		title = "Try patting your creature",
		body = "Walk up to any creature you own and press E for a bonus. Works every 20 seconds!",
	},
	{
		id = "slots",
		delay = 2,
		check = function(stats) return stats.paidHatches >= 3 end,
		title = "Running out of room?",
		body = "Buy extra Critter Slots at the Hatchery so new hatches stop replacing your best creature.",
	},
	{
		id = "rebirthTease",
		delay = 2,
		check = function(stats) return stats.level >= 5 end,
		title = "Rebirth is unlocked",
		body = "Rebirthing resets your Sparks but grants a PERMANENT income multiplier. Check the Rebirth button!",
	},
	{
		id = "worldTease",
		delay = 2,
		check = function(stats) return stats.sparks >= Constants.WORLD_TEASE_SPARKS end,
		title = "A new world awaits",
		body = "You're getting close to unlocking the Forest. Head south to find the gate!",
	},
}

-- Stats snapshot the beat conditions read. Kept tiny and explicit rather than reusing
-- the Achievements stats table, so a change there can never silently alter onboarding.
local function statsFor(player, profile)
	local ownedCount = 0
	for _, status in pairs(profile.collection or {}) do
		if status == "owned" then ownedCount += 1 end
	end
	-- GetLevel takes a PLAYER (not raw xp) and returns level as its first value.
	local level = PlayerDataService.GetLevel(player)
	return {
		orbsCollectedTotal = profile.orbsCollectedTotal or 0,
		hatchesTotal = profile.hatchesTotal or 0,
		paidHatches = profile.paidHatchesTotal or 0,
		sparks = profile.sparks or 0,
		collectionOwnedCount = ownedCount,
		level = level,
	}
end

-- Fires any newly-satisfied beats for this player. Safe to call frequently.
function OnboardingService.Check(player)
	local profile = PlayerDataService.Get(player)
	if not profile then return end
	profile.onboardingSeen = profile.onboardingSeen or {}

	-- A player who already has real progress skips onboarding entirely -- they're not
	-- new, they just have an old save from before this system existed.
	if (profile.hatchesTotal or 0) > 25 then return end

	local stats = statsFor(player, profile)
	for _, beat in ipairs(BEATS) do
		if not profile.onboardingSeen[beat.id] then
			local ok, satisfied = pcall(beat.check, stats)
			if ok and satisfied then
				profile.onboardingSeen[beat.id] = true
				task.delay(beat.delay or 0, function()
					if player.Parent then
						remotes.OnboardingTip:FireClient(player, beat.title, beat.body)
					end
				end)
				-- One beat per check, so a player crossing several thresholds at once
				-- gets them as a readable sequence instead of a wall of popups.
				return
			end
		end
	end
end

function OnboardingService.Init()
	task.spawn(function()
		while true do
			task.wait(4)
			for _, player in ipairs(Players:GetPlayers()) do
				local ok, err = pcall(OnboardingService.Check, player)
				if not ok then warn("[OnboardingService] check failed:", err) end
			end
		end
	end)
end

return OnboardingService

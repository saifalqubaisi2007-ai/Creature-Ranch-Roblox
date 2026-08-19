--[[
	RebirthService.lua
	Prestige loop: reset Sparks + all Critters for a permanent income multiplier and a
	visible aura tier. The multiplier is mirrored onto a player attribute so
	CritterService's income calc can read it with zero cross-require coupling, same
	pattern as the gamepass/world-event multipliers.
]]

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Constants = require(RS.CritterRush.Modules.Constants)
local WorldsData = require(RS.CritterRush.Modules.WorldsData)
local PlayerDataService = require(script.Parent.PlayerDataService)
local CritterService = require(script.Parent.CritterService)
local HatchLogic = require(script.Parent.HatchLogic)
local AnalyticsService = require(script.Parent.AnalyticsService)
local BadgeAwardService = require(script.Parent.BadgeAwardService)

local remotes = RS.CritterRush.Remotes

local RebirthService = {}

local function tierFor(rebirthCount)
	return Constants.GetRebirthTier(rebirthCount) -- nil once maxed, handled by callers
end

-- Mirrors the CURRENT (already-earned) multiplier onto an attribute for CritterService
-- to read. Called on join and immediately after a successful rebirth.
function RebirthService.SyncAttribute(player)
	local profile = PlayerDataService.Get(player)
	if not profile then return end
	local mult = 1
	if profile.rebirths > 0 then
		mult = Constants.GetRebirthTier(profile.rebirths).multiplier
	end
	player:SetAttribute("SAC_RebirthMultiplier", mult)
	player:SetAttribute("SAC_RebirthCount", profile.rebirths)
end

function RebirthService.GetNextTierInfo(player)
	local profile = PlayerDataService.Get(player)
	if not profile then return nil end
	return tierFor(profile.rebirths + 1)
end

function RebirthService.PerformRebirth(player)
	local profile = PlayerDataService.Get(player)
	if not profile then return false, "no profile" end

	local nextTier = tierFor(profile.rebirths + 1)
	if not nextTier then return false, "max rebirth reached" end
	if profile.sparks < nextTier.cost then return false, "not enough sparks" end

	-- Reset: spend ALL sparks (not just the cost — rebirth is a full wipe, matching
	-- every genre precedent) and clear every owned critter.
	local sparksBeforeReset = profile.sparks
	for _, saved in ipairs(profile.ownedCritters) do
		CritterService.RemoveCritter(saved.uid)
	end
	profile.ownedCritters = {}
	profile.sparks = 0
	profile.extraSlotsPurchased = 0 -- slots reset too; the multiplier is the permanent reward
	profile.rebirths += 1

	-- Seasonal leaderboard accrual. Lazily resets when the season rolls over, so no
	-- scheduled job is needed -- same pattern as the weekly Sparks board.
	local season = Constants.GetSeasonIndex()
	if profile.seasonRebirthsSeason ~= season then
		profile.seasonRebirthsSeason = season
		profile.seasonRebirths = 0
	end
	profile.seasonRebirths = (profile.seasonRebirths or 0) + 1

	AnalyticsService.LogRebirthReset(player, sparksBeforeReset)
	AnalyticsService.LogRebirthProgression(player, profile.rebirths, nextTier.title)
	AnalyticsService.LogFirstRebirth(player)
	BadgeAwardService.CheckAll(player, PlayerDataService.Get(player))

	RebirthService.SyncAttribute(player)
	HatchLogic.SyncSlotAttributes(player) -- critical: used-slots must reflect the wipe, not the pre-rebirth count
	remotes.SparksUpdated:FireClient(player, 0)
	remotes.RebirthCompleted:FireClient(player, profile.rebirths, nextTier.title, nextTier.multiplier)
	remotes.ServerAnnouncement:FireAllClients(
		string.format("\u{1F31F} %s REBIRTHED! Now \"%s\" (%.1fx income)",
			player.DisplayName:upper(), nextTier.title, nextTier.multiplier))

	local bonusXP = Constants.XP_REWARDS.rebirth
	if bonusXP and bonusXP > 0 then
		local newXP, level, xpIntoLevel, xpNeeded, leveledUp = PlayerDataService.AddXP(player, bonusXP)
		remotes.XPUpdated:FireClient(player, newXP, level, xpIntoLevel, xpNeeded)
		if leveledUp then remotes.LevelUp:FireClient(player, level) end
	end

	-- Grant a fresh starter critter so the player isn't left with nothing to do
	task.wait(0.3)
	-- Rebirth always grants a World 1 (Starter Meadow) Common critter, regardless of which
	-- worlds the player has unlocked -- matches the pre-multi-world design intent exactly
	-- ("reset and start over with a humble beginning"), and Common is guaranteed to exist
	-- since StarterMeadow is the one world that's always implemented.
	local startWorld = WorldsData.GetWorld(WorldsData.DEFAULT_WORLD_ID)
	local tier = startWorld.rarities[1]
	local species = startWorld.species[tier.id][math.random(1, #startWorld.species[tier.id])]
	local record = CritterService.SpawnForPlayer(player, tier, species, WorldsData.DEFAULT_WORLD_ID)
	if record then
		PlayerDataService.AddOwnedCritter(player, {
			uid = record.uid, rarity = tier.id, species = species, worldId = WorldsData.DEFAULT_WORLD_ID,
			sparksPerSecond = record.sparksPerSecond, isShiny = record.isShiny,
		})
		remotes.HatchResult:FireClient(player, true, tier.id, species, record.uid, record.isShiny, record.personality)
		HatchLogic.SyncSlotAttributes(player) -- reflect the +1 used slot from the fresh starter
	end

	-- Achievement check LAST, after the starter grant above -- catches "rebirths" (this
	-- rebirth itself), plus whatever hatchesTotal/hasOwnedShiny/collectionOwnedCount the
	-- starter critter grant may have just moved, all in one pass.
	local unlocked = PlayerDataService.CheckAchievements(player)
	if #unlocked > 0 then
		local freshLevel, freshInto, freshNeeded = PlayerDataService.GetLevel(player)
		local freshProfile = PlayerDataService.Get(player)
		remotes.XPUpdated:FireClient(player, freshProfile.xp, freshLevel, freshInto, freshNeeded)
		for _, ach in ipairs(unlocked) do
			remotes.SparksUpdated:FireClient(player, freshProfile.sparks)
			remotes.AchievementUnlocked:FireClient(player, ach.id, ach.title, ach.reward)
		end
	end

	return true
end

return RebirthService

--[[
	BadgeAwardService.lua
	Awards Roblox badges for genuine milestones.

	Design notes:
	 * An unconfigured badge (id == 0) is skipped SILENTLY. The game must not error or
	   warn-spam just because badges haven't been created on the Dashboard yet -- that
	   would make a normal pre-launch state look broken.
	 * Every BadgeService call is pcall-wrapped. These are web requests: they can fail,
	   rate-limit, or hang, and a badge failing must never break the action that earned
	   it. Awarding a badge is the least important thing happening in that moment.
	 * UserHasBadgeAsync is checked before awarding, and the result cached per session,
	   because AwardBadge on an already-owned badge still costs a web call.
]]

local BadgeService = game:GetService("BadgeService")
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")

local Constants = require(RS.CritterRush.Modules.Constants)

local BadgeAwardService = {}

-- [userId] = { [badgeKey] = true } -- badges we know this player already has, so
-- repeated milestone triggers in one session don't each cost a web request.
local knownOwned = {}

function BadgeAwardService.Award(player, badgeKey)
	local badge = Constants.BADGES[badgeKey]
	if not badge then return false, "UnknownBadge" end
	-- Not configured yet: silent no-op, not an error.
	if badge.id == 0 then return false, "NotConfigured" end
	if not player or not player.Parent then return false, "PlayerGone" end

	local cache = knownOwned[player.UserId]
	if cache and cache[badgeKey] then return false, "AlreadyOwned" end

	-- Off the main thread: BadgeService calls are web requests and can block.
	task.spawn(function()
		local ok, hasBadge = pcall(function()
			return BadgeService:UserHasBadgeAsync(player.UserId, badge.id)
		end)
		if not ok then return end

		if hasBadge then
			knownOwned[player.UserId] = knownOwned[player.UserId] or {}
			knownOwned[player.UserId][badgeKey] = true
			return
		end

		local awarded = pcall(function()
			BadgeService:AwardBadge(player.UserId, badge.id)
		end)
		if awarded then
			knownOwned[player.UserId] = knownOwned[player.UserId] or {}
			knownOwned[player.UserId][badgeKey] = true
			local r = RS.CritterRush.Remotes:FindFirstChild("BadgeAwarded")
			if r and player.Parent then
				r:FireClient(player, badge.name, badge.desc)
			end
		end
	end)
	return true
end

-- Convenience: evaluates every milestone against a profile and awards what applies.
-- Called after actions that could cross several thresholds at once (a rebirth can also
-- complete the collection, for example).
function BadgeAwardService.CheckAll(player, profile)
	if not profile then return end

	if (profile.hatchesTotal or 0) >= 1 then
		BadgeAwardService.Award(player, "FirstHatch")
	end
	if (profile.rebirths or 0) >= 1 then
		BadgeAwardService.Award(player, "FirstRebirth")
	end
	if profile.hasOwnedShiny then
		BadgeAwardService.Award(player, "FirstShiny")
	end
	if (profile.fusionsTotal or 0) >= 1 then
		BadgeAwardService.Award(player, "FirstFusion")
	end

	local unlocked = profile.unlockedWorlds or {}
	if unlocked.Forest then BadgeAwardService.Award(player, "ReachForest") end
	if unlocked.Volcano then BadgeAwardService.Award(player, "ReachVolcano") end
	if unlocked.SkyIslands then BadgeAwardService.Award(player, "ReachSky") end

	-- Species discovered (owned OR seen -- discovery is the milestone, not ownership).
	local discovered, owned = 0, 0
	for _, status in pairs(profile.collection or {}) do
		discovered += 1
		if status == "owned" then owned += 1 end
	end
	if discovered >= 50 then BadgeAwardService.Award(player, "Collector50") end

	local WorldsData = require(RS.CritterRush.Modules.WorldsData)
	local totalSpecies = 0
	for _, w in ipairs(WorldsData.WORLDS) do
		if w.species then
			for _, list in pairs(w.species) do totalSpecies += #list end
		end
	end
	if totalSpecies > 0 and owned >= totalSpecies then
		BadgeAwardService.Award(player, "CollectorMax")
	end

	-- Mythic ownership.
	for _, rec in ipairs(profile.ownedCritters or {}) do
		if rec.rarity == "Mythic" then
			BadgeAwardService.Award(player, "Mythic")
			break
		end
	end
end

function BadgeAwardService.Init()
	Players.PlayerRemoving:Connect(function(player)
		knownOwned[player.UserId] = nil
	end)

	local configured = 0
	for _, b in pairs(Constants.BADGES) do
		if b.id ~= 0 then configured += 1 end
	end
	print(string.format("[BadgeAwardService] active (%d/%d badges configured)",
		configured, (function()
			local n = 0
			for _ in pairs(Constants.BADGES) do n += 1 end
			return n
		end)()))
end

return BadgeAwardService

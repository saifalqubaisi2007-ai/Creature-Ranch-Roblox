--[[
	PlaytimeRewardService.lua
	Escalating rewards at in-session playtime milestones (5/15/30/60/90 min).

	Session-scoped by design: tracked in memory and reset on every join, NOT persisted.
	The purpose is extending the current session, so a returning player should face the
	full ladder again rather than finding it already exhausted forever.
]]

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Constants = require(RS.CritterRush.Modules.Constants)
local PlayerDataService = require(script.Parent.PlayerDataService)
local QuestService = require(script.Parent.QuestService)
local AnalyticsService = require(script.Parent.AnalyticsService)

local remotes = RS.CritterRush.Remotes

local PlaytimeRewardService = {}

-- [userId] = { joinedAt = os.clock(), claimed = { [milestoneIndex] = true } }
local sessions = {}

local CHECK_INTERVAL = 15 -- seconds between sweeps; milestones are minutes apart

function PlaytimeRewardService.OnPlayerReady(player)
	sessions[player.UserId] = { joinedAt = os.clock(), claimed = {} }
end

local function grantMilestone(player, index, milestone)
	local newTotal = PlayerDataService.AddSparks(player, milestone.sparks)
	remotes.SparksUpdated:FireClient(player, newTotal)
	QuestService.ReportProgress(player, "sparks", milestone.sparks)
	AnalyticsService.LogRewardEarned(player, milestone.sparks, newTotal,
		"Playtime_" .. milestone.minutes .. "min")

	local rewardRemote = remotes:FindFirstChild("PlaytimeReward")
	if rewardRemote then
		rewardRemote:FireClient(player, milestone.minutes, milestone.sparks)
	end
end

-- Returns the player's session progress for the client's progress display:
-- (minutesPlayed, nextMilestoneMinutes, nextMilestoneSparks) or nil once all claimed.
function PlaytimeRewardService.GetProgress(player)
	local session = sessions[player.UserId]
	if not session then return 0, nil, nil end
	local minutes = (os.clock() - session.joinedAt) / 60
	for i, m in ipairs(Constants.PLAYTIME_REWARDS) do
		if not session.claimed[i] then
			return minutes, m.minutes, m.sparks
		end
	end
	return minutes, nil, nil
end

function PlaytimeRewardService.Init()
	Players.PlayerRemoving:Connect(function(player)
		sessions[player.UserId] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(CHECK_INTERVAL)
			for _, player in ipairs(Players:GetPlayers()) do
				local session = sessions[player.UserId]
				if session then
					local minutes = (os.clock() - session.joinedAt) / 60
					for i, milestone in ipairs(Constants.PLAYTIME_REWARDS) do
						if not session.claimed[i] and minutes >= milestone.minutes then
							session.claimed[i] = true
							local ok, err = pcall(grantMilestone, player, i, milestone)
							if not ok then
								warn("[PlaytimeRewardService] grant failed:", err)
							end
						end
					end
				end
			end
		end
	end)
end

return PlaytimeRewardService

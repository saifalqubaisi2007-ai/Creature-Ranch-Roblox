--[[
	LandmarkService.lua
	Design-review fix (MEDIUM #5 + #7): a periodic proximity check that reports "explore"
	quest progress the first time a player enters any built landmark's zone each session.
	Previously nothing in the game routed a new player toward the Dock, Waterfall, or
	Rope Bridge -- a player could play a perfectly normal first 30 minutes and never see
	any of the built environment beyond the Hatchery's immediate clearing.

	Deliberately simple: a slow poll (every 2s, not every Heartbeat -- this doesn't need
	frame-perfect timing and 22,000+ per-second distance checks across all players would
	be pure waste), rising-edge detection per player so entering a zone reports exactly
	once, not continuously while standing in it.
]]

local Players = game:GetService("Players")
local QuestService = require(script.Parent.QuestService)

local LandmarkService = {}

-- Real coordinates pulled live from the built landmarks, not guessed.
local ZONES = {
	{ name = "Waterfall", position = Vector3.new(-70.125, 29.6, -57.25), radius = 25 },
	{ name = "Dock", position = Vector3.new(131.925, 11.4, 0), radius = 25 },
	{ name = "RopeBridge", position = Vector3.new(-40, 12.8, 53.75), radius = 25 },
}

-- [userId] = true once they've triggered a report THIS SESSION -- prevents leaving and
-- re-entering the same zone from spamming ReportProgress (which would be harmless
-- data-wise thanks to QuestService's own completion guard, but still wasteful remote
-- traffic). Deliberately NOT per-landmark: reaching any ONE landmark satisfies the
-- design goal ("route players past AT LEAST ONE landmark"), and resets naturally each
-- new Play session since this is in-memory only, not persisted.
local hasReportedThisSession = {}

function LandmarkService.Init()
	task.spawn(function()
		while true do
			task.wait(2)
			for _, player in ipairs(Players:GetPlayers()) do
				if not hasReportedThisSession[player.UserId] then
					local char = player.Character
					local hrp = char and char:FindFirstChild("HumanoidRootPart")
					if hrp then
						for _, zone in ipairs(ZONES) do
							if (hrp.Position - zone.position).Magnitude <= zone.radius then
								hasReportedThisSession[player.UserId] = true
								QuestService.ReportProgress(player, "explore", 1)
								break
							end
						end
					end
				end
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		hasReportedThisSession[player.UserId] = nil
	end)
end

return LandmarkService

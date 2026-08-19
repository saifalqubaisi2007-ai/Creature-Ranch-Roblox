--[[
	LeaderboardService.server.lua
	Physical all-time Top Sparks leaderboard at the spawn plaza.
	OrderedDataStore "SAC_TopSparks": each player's best-ever Sparks balance is pushed
	every UPDATE_INTERVAL, and the top 10 rendered on a SurfaceGui board everyone can
	walk up to — permanent, physical social proof in the world (GDD social pillar).
	Degrades silently to a "come back later" board if DataStores are unavailable.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local PlayerDataService = require(script.Parent.Services.PlayerDataService)

local UPDATE_INTERVAL = 60

local orderedStore
pcall(function()
	orderedStore = DataStoreService:GetOrderedDataStore("SAC_TopSparks")
end)

-- Weekly board lives in a store keyed BY WEEK INDEX, so a new week starts a genuinely
-- empty board rather than needing anything cleared. Last week's store still exists and
-- is what reward distribution reads from.
local Constants = require(game.ReplicatedStorage.CritterRush.Modules.Constants)
local function weeklyStoreFor(weekIndex)
	local store
	pcall(function()
		store = DataStoreService:GetOrderedDataStore("SAC_WeeklySparks_" .. weekIndex)
	end)
	return store
end

local function seasonalStoreFor(seasonIndex)
	local store
	pcall(function()
		store = DataStoreService:GetOrderedDataStore("SAC_SeasonRebirths_" .. seasonIndex)
	end)
	return store
end

-- The physical board CYCLES between the three tracks rather than showing only all-time.
-- A second and third board would each be a wall nobody walks to; rotating one board that
-- players already look at is what makes the extra tracks actually visible.
local BOARD_TRACKS = {
	{ id = "alltime", title = "\u{1F3C6} TOP SPARKS (ALL TIME) \u{1F3C6}", unit = "\u{2728}" },
	{ id = "weekly",  title = "\u{1F525} TOP SPARKS THIS WEEK \u{1F525}",  unit = "\u{2728}" },
	{ id = "season",  title = "\u{1F31F} TOP REBIRTHS THIS SEASON \u{1F31F}", unit = "\u{1F501}" },
}
local BOARD_CYCLE_SECONDS = 15
local currentTrack = 1

-- ===== Build the physical board at the plaza edge =====
local existing = workspace:FindFirstChild("LeaderboardBoard")
if existing then existing:Destroy() end

local board = Instance.new("Part")
board.Name = "LeaderboardBoard"
board.Size = Vector3.new(14, 10, 1)
board.CFrame = CFrame.new(24, 12, 8) * CFrame.Angles(0, math.rad(-65), 0)
board.Anchored = true
board.Material = Enum.Material.Slate
board.Color = Color3.fromRGB(45, 40, 60)
board.Parent = workspace

local frame = Instance.new("Part")
frame.Name = "BoardTrim"
frame.Size = Vector3.new(14.6, 10.6, 0.6)
-- Fully recessed inside the board's depth (±0.3 vs board's ±0.5) so the trim edge
-- shows around the border without covering either face.
frame.CFrame = board.CFrame
frame.Anchored = true
frame.Material = Enum.Material.SmoothPlastic
frame.Color = Color3.fromRGB(255, 200, 80)
frame.Parent = board

local surfaceGui = Instance.new("SurfaceGui")
surfaceGui.Name = "BoardGui"
surfaceGui.Face = Enum.NormalId.Front
surfaceGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
surfaceGui.PixelsPerStud = 40
surfaceGui.LightInfluence = 0 -- self-lit: readable at night/dusk, not dimmed by scene lighting
surfaceGui.Brightness = 1.5
surfaceGui.Parent = board

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Size = UDim2.new(1, 0, 0.15, 0)
title.Text = "\u{1F3C6} TOP SPARKS \u{1F3C6}"
title.TextColor3 = Color3.fromRGB(255, 210, 90)
title.Font = Enum.Font.FredokaOne
title.TextScaled = true
title.Parent = surfaceGui

local listFrame = Instance.new("Frame")
listFrame.BackgroundTransparency = 1
listFrame.Size = UDim2.new(0.94, 0, 0.8, 0)
listFrame.Position = UDim2.new(0.03, 0, 0.17, 0)
listFrame.Parent = surfaceGui

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 4)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = listFrame

local rows = {}
for i = 1, 10 do
	local row = Instance.new("TextLabel")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0.093, 0)
	row.LayoutOrder = i
	row.Text = i .. ".  ---"
	row.TextColor3 = (i <= 3) and Color3.fromRGB(255, 220, 120) or Color3.fromRGB(220, 215, 235)
	row.Font = Enum.Font.GothamMedium
	row.TextScaled = true
	row.TextXAlignment = Enum.TextXAlignment.Left
	row.Parent = listFrame
	rows[i] = row
end

if not orderedStore then
	title.Text = "\u{1F3C6} TOP SPARKS (soon!) \u{1F3C6}"
	return
end

-- ===== Update loop =====
local nameCache = {} -- [userId] = displayName

local function getName(userId)
	if nameCache[userId] then return nameCache[userId] end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	nameCache[userId] = ok and name or ("User " .. userId)
	return nameCache[userId]
end

task.spawn(function()
	task.wait(12) -- let first players join and their profiles load before the first cycle;
	-- without this the boot iteration pushes nothing and the board sits empty for a full minute
	while true do
		-- Push current balances (only if they beat the stored best, so the board is
		-- "highest ever reached", not punished by spending)
		for _, player in ipairs(Players:GetPlayers()) do
			local profile = PlayerDataService.Get(player)
			if profile then
				pcall(function()
					orderedStore:UpdateAsync(tostring(player.UserId), function(old)
						return math.max(old or 0, profile.sparks)
					end)
				end)
			end
		end

		-- Push weekly scores alongside the all-time board, same cadence.
		local week = Constants.GetWeekIndex()
		local weeklyStore = weeklyStoreFor(week)
		if weeklyStore then
			for _, player in ipairs(Players:GetPlayers()) do
				local profile = PlayerDataService.Get(player)
				if profile and (profile.weeklySparksWeek == week) and (profile.weeklySparks or 0) > 0 then
					pcall(function()
						weeklyStore:SetAsync(tostring(player.UserId), math.floor(profile.weeklySparks))
					end)
				end
			end
		end

		-- Push seasonal rebirth counts.
		local season = Constants.GetSeasonIndex()
		local seasonStore = seasonalStoreFor(season)
		if seasonStore then
			for _, player in ipairs(Players:GetPlayers()) do
				local profile = PlayerDataService.Get(player)
				if profile and (profile.seasonRebirthsSeason == season) and (profile.seasonRebirths or 0) > 0 then
					pcall(function()
						seasonStore:SetAsync(tostring(player.UserId), math.floor(profile.seasonRebirths))
					end)
				end
			end
		end

		-- Render whichever track is currently up, cycling between them so all three are
		-- seen without needing three separate physical boards.
		local cycles = math.max(1, math.floor(UPDATE_INTERVAL / BOARD_CYCLE_SECONDS))
		for _ = 1, cycles do
			local track = BOARD_TRACKS[currentTrack]
			local store = orderedStore
			if track.id == "weekly" then store = weeklyStore
			elseif track.id == "season" then store = seasonStore end

			title.Text = track.title
			if track.id == "season" then
				local rem = Constants.GetSeasonSecondsRemaining()
				title.Text = string.format("%s  (%dd left)", track.title, math.floor(rem / 86400))
			end

			if store then
				local ok, pages = pcall(function()
					return store:GetSortedAsync(false, 10)
				end)
				if ok and pages then
					local top = pages:GetCurrentPage()
					for i = 1, 10 do
						local entry = top[i]
						if entry then
							local name = getName(tonumber(entry.key))
							-- FormatNumber, not %d: balances reach trillions and a raw digit
							-- string is unreadable at that scale.
							rows[i].Text = string.format("%d.  %s \u{2014} %s %s", i, name,
								Constants.FormatNumber(entry.value), track.unit)
						else
							rows[i].Text = i .. ".  ---"
						end
					end
				end
			else
				-- No store for this track yet (fresh week/season, or DataStores down).
				for i = 1, 10 do rows[i].Text = i .. ".  ---" end
			end

			currentTrack = (currentTrack % #BOARD_TRACKS) + 1
			task.wait(BOARD_CYCLE_SECONDS)
		end
	end
end)

-- ===== Weekly reward distribution =====
-- Paid on JOIN rather than on a schedule: a player who wasn't online at the reset moment
-- must still receive what they earned, and there's no reliable "everyone is here" moment
-- on Roblox. lastWeeklyRewardWeek makes this idempotent -- a player rejoining ten times
-- in a week is paid exactly once.
local function grantWeeklyRewards(player)
	local profile = PlayerDataService.Get(player)
	if not profile then return end

	local currentWeek = Constants.GetWeekIndex()
	local lastPaid = profile.lastWeeklyRewardWeek or 0
	-- Nothing to pay if they've already been paid for the most recently COMPLETED week.
	local completedWeek = currentWeek - 1
	if lastPaid >= completedWeek then return end
	-- Mark first, pay second: if the payout errors we must not retry into a double-grant.
	profile.lastWeeklyRewardWeek = completedWeek

	local store = weeklyStoreFor(completedWeek)
	if not store then return end

	-- Find this player's rank in last week's board. Scanning the top N is enough --
	-- rewards only exist down to rank 50, so anyone past that gets nothing anyway.
	local maxRewardedRank = 0
	for _, r in ipairs(Constants.WEEKLY_LEADERBOARD_REWARDS) do
		if r.rank > maxRewardedRank then maxRewardedRank = r.rank end
	end

	local ok, pages = pcall(function()
		return store:GetSortedAsync(false, math.min(maxRewardedRank, 100))
	end)
	if not ok or not pages then return end

	local page = pages:GetCurrentPage()
	local rank
	for i, entry in ipairs(page) do
		if tonumber(entry.key) == player.UserId then rank = i break end
	end
	if not rank then return end

	local reward = Constants.GetWeeklyReward(rank)
	if not reward then return end

	local newTotal = PlayerDataService.AddSparks(player, reward.sparks)
	local remotes = game:GetService("ReplicatedStorage").CritterRush.Remotes
	remotes.SparksUpdated:FireClient(player, newTotal)
	local r = remotes:FindFirstChild("WeeklyRewardGranted")
	if r then r:FireClient(player, rank, reward.sparks, reward.label) end
	print(string.format("[LeaderboardService] weekly reward: %s rank %d -> %d sparks",
		player.Name, rank, reward.sparks))
end

Players.PlayerAdded:Connect(function(player)
	-- Delay so PlayerDataService.Load has completed before we read the profile.
	task.delay(5, function()
		if player.Parent then
			local ok, err = pcall(grantWeeklyRewards, player)
			if not ok then warn("[LeaderboardService] weekly reward failed:", err) end
		end
	end)
end)
for _, player in ipairs(Players:GetPlayers()) do
	task.delay(5, function()
		if player.Parent then pcall(grantWeeklyRewards, player) end
	end)
end

print("[LeaderboardService] board active")

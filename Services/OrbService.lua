--[[
	OrbService.lua
	Spark Orbs: the missing "active verb" — collectible glowing orbs scattered across the
	island that respawn continuously. Gives players something to physically DO between
	hatches, pulls them around the whole map, and feeds the core steal design: chasing
	orbs means leaving your critter wandering unattended (risk/reward on every trip).
]]

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local PlayerDataService = require(script.Parent.PlayerDataService)
local QuestService = require(script.Parent.QuestService)
local Constants = require(RS.CritterRush.Modules.Constants)

local remotes = RS.CritterRush.Remotes

local OrbService = {}

local MAX_ORBS = 22
local ORB_VALUE_RANGE = { min = 25, max = 55 }
local RESPAWN_DELAY = { min = 3, max = 7 }
local ISLAND_RADIUS = { min = 15, max = 105 } -- inside the sand ring, avoids water

-- Combo system: the actual answer to "never let the optimal strategy be standing
-- still" -- collecting orbs QUICKLY in succession builds a combo that multiplies
-- every subsequent orb's value, decaying back to 1x the moment you stop for more than
-- COMBO_WINDOW seconds. Per-player, in-memory only (deliberately not persisted --
-- a combo is a right-now momentum thing, not a permanent stat).
local COMBO_WINDOW = 2.5
local COMBO_TIERS = {
	{ min = 10, mult = 2.0 },
	{ min = 6, mult = 1.6 },
	{ min = 3, mult = 1.3 },
	{ min = 1, mult = 1.0 },
}
local comboState = {} -- [userId] = { count, lastCollectTime }

local function multiplierForCombo(count)
	for _, tier in ipairs(COMBO_TIERS) do
		if count >= tier.min then return tier.mult end
	end
	return 1.0
end

-- Called from the orb Touched handler. Returns (finalValue, comboCount, multiplier).
local function applyCombo(player, baseValue)
	local now = os.clock()
	local state = comboState[player.UserId]
	if state and (now - state.lastCollectTime) <= COMBO_WINDOW then
		state.count += 1
	else
		state = { count = 1 }
		comboState[player.UserId] = state
	end
	state.lastCollectTime = now
	local mult = multiplierForCombo(state.count)
	return math.floor(baseValue * mult), state.count, mult
end

Players.PlayerRemoving:Connect(function(player)
	comboState[player.UserId] = nil
end)

local orbsFolder
local activeCount = 0

local function randomIslandPoint()
	local angle = math.random() * math.pi * 2
	local r = ISLAND_RADIUS.min + math.random() * (ISLAND_RADIUS.max - ISLAND_RADIUS.min)
	return Vector3.new(math.cos(angle) * r, 7, math.sin(angle) * r)
end

-- Permanent Rebirth magnet (item #6 + closes item #1's magnet gap): finds the
-- CLOSEST player whose permanent magnet radius (earned from rebirth tier) currently
-- reaches this orb's position. Returns (player, radius) or nil. Reads SAC_RebirthCount
-- directly off the player attribute -- same decoupled pattern as every other
-- cross-system flag in this codebase, no PlayerDataService require needed here.
local function findMagnetPuller(orbPos)
	local closestPlayer, closestDist = nil, math.huge
	for _, player in ipairs(Players:GetPlayers()) do
		local rebirthCount = player:GetAttribute("SAC_RebirthCount") or 0
		if rebirthCount > 0 then
			local tier = Constants.REBIRTH_TIERS[rebirthCount]
			local radius = tier and tier.magnetRadius or 0
			if radius > 0 then
				local char = player.Character
				local hrp = char and char:FindFirstChild("HumanoidRootPart")
				if hrp then
					local dist = (hrp.Position - orbPos).Magnitude
					if dist <= radius and dist < closestDist then
						closestPlayer, closestDist = player, dist
					end
				end
			end
		end
	end
	return closestPlayer
end

local function spawnOrb()
	if activeCount >= MAX_ORBS then return end
	activeCount += 1

	local value = math.random(ORB_VALUE_RANGE.min, ORB_VALUE_RANGE.max)
	local pos = randomIslandPoint()

	local orb = Instance.new("Part")
	orb.Name = "SparkOrb"
	orb.Shape = Enum.PartType.Ball
	orb.Size = Vector3.new(1.6, 1.6, 1.6)
	orb.Position = pos
	orb.Anchored = true
	orb.CanCollide = false
	orb.Material = Enum.Material.Neon
	orb.Color = Color3.fromRGB(140, 255, 160)
	orb.Parent = orbsFolder
	orb:SetAttribute("Value", value)

	local sparkle = Instance.new("ParticleEmitter")
	sparkle.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	sparkle.Color = ColorSequence.new(Color3.fromRGB(160, 255, 180))
	sparkle.Rate = 8
	sparkle.Lifetime = NumberRange.new(0.4, 0.7)
	sparkle.Speed = NumberRange.new(0.5, 1.2)
	sparkle.LightEmission = 1
	sparkle.Parent = orb

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(160, 255, 180)
	light.Range = 10
	light.Brightness = 1.5
	light.Parent = orb

	-- gentle bob so orbs read as "alive" and grab attention from a distance -- also pulls
	-- pos itself toward a magnet-eligible player (item #6), so the orb visibly FLIES in
	-- rather than instantly vanishing at range, then lets the existing, unchanged Touched
	-- handler below do the actual collection once contact happens naturally.
	local bobPhase = math.random() * math.pi * 2
	local MAGNET_PULL_SPEED = 40 -- studs/sec
	local bobConn
	bobConn = game:GetService("RunService").Heartbeat:Connect(function(dt)
		if not orb.Parent then
			bobConn:Disconnect()
			return
		end
		local puller = findMagnetPuller(pos)
		if puller then
			local char = puller.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hrp then
				local toPlayer = hrp.Position - pos
				local dist = toPlayer.Magnitude
				if dist > 0.5 then
					pos = pos + toPlayer.Unit * math.min(MAGNET_PULL_SPEED * dt, dist)
				end
			end
		end
		local t = os.clock() * 2 + bobPhase
		orb.CFrame = CFrame.new(pos + Vector3.new(0, math.sin(t) * 0.6, 0)) * CFrame.Angles(0, t, 0)
	end)

	local collected = false
	orb.Touched:Connect(function(hit)
		if collected then return end
		local char = hit:FindFirstAncestorOfClass("Model")
		local player = char and Players:GetPlayerFromCharacter(char)
		if not player then return end
		collected = true

		local finalValue, comboCount, comboMult = applyCombo(player, value)
		-- Whiteout doubles orb value. Snow's mechanic is passive ice physics with no
		-- reward of its own, so the event boosts what players actually DO there --
		-- sliding around collecting orbs -- rather than inventing a new payout.
		if workspace:GetAttribute("SAC_EventWhiteout") then finalValue *= 2 end
		local newTotal = PlayerDataService.AddSparks(player, finalValue)
		remotes.SparksUpdated:FireClient(player, newTotal)
		-- Single broadcast to everyone (collector included) keeps the +N text and burst
		-- visible as a small shared spectacle, and avoids a mismatched-args double-fire.
		remotes.OrbCollected:FireAllClients(finalValue, orb.Position)
		-- Combo feedback is PERSONAL (only the collector sees their own streak building),
		-- unlike the shared +N text above -- FireClient, not FireAllClients.
		remotes.ComboUpdated:FireClient(player, comboCount, comboMult)
		QuestService.ReportProgress(player, "orbs", 1)
		QuestService.ReportProgress(player, "sparks", finalValue)

		local profile = PlayerDataService.Get(player)
		if profile then
			profile.orbsCollectedTotal = (profile.orbsCollectedTotal or 0) + 1
		end

		orb:Destroy()
		activeCount -= 1
		task.wait(math.random(RESPAWN_DELAY.min, RESPAWN_DELAY.max))
		spawnOrb()
	end)
end

-- Giant Spark Clusters: every few minutes, a tight burst of gold orbs appears at one
-- random point on the island -- a real "everyone rush over there" moment, distinct
-- from the steady background trickle of normal green orbs. Deliberately does NOT
-- count against MAX_ORBS/activeCount -- this is a bonus burst on top of the normal
-- population, not a replacement for it, and cleans itself up on its own timer.
local CLUSTER_INTERVAL = 90
local CLUSTER_SIZE = 6
local CLUSTER_ORB_VALUE = 30
local CLUSTER_LIFETIME = 20

local function spawnCluster()
	local centerPos = randomIslandPoint()
	local clusterFolder = Instance.new("Folder")
	clusterFolder.Name = "SparkCluster"
	clusterFolder.Parent = orbsFolder

	remotes.ServerAnnouncement:FireAllClients("\u{1F48E} A SPARK CLUSTER has appeared! Find it fast!")

	for i = 1, CLUSTER_SIZE do
		local angle = (i / CLUSTER_SIZE) * math.pi * 2
		local offset = Vector3.new(math.cos(angle) * 3, math.sin(i) * 1.5, math.sin(angle) * 3)
		local pos = centerPos + offset

		local orb = Instance.new("Part")
		orb.Name = "ClusterOrb"
		orb.Shape = Enum.PartType.Ball
		orb.Size = Vector3.new(2.0, 2.0, 2.0)
		orb.Position = pos
		orb.Anchored = true
		orb.CanCollide = false
		orb.Material = Enum.Material.Neon
		orb.Color = Color3.fromRGB(255, 215, 60) -- gold, distinct from normal orbs' green
		orb.Parent = clusterFolder

		local sparkle = Instance.new("ParticleEmitter")
		sparkle.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		sparkle.Color = ColorSequence.new(Color3.fromRGB(255, 230, 130))
		sparkle.Rate = 14
		sparkle.Lifetime = NumberRange.new(0.4, 0.8)
		sparkle.Speed = NumberRange.new(0.6, 1.4)
		sparkle.LightEmission = 1
		sparkle.Parent = orb

		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 220, 120)
		light.Range = 14
		light.Brightness = 2.5
		light.Parent = orb

		local collected = false
		orb.Touched:Connect(function(hit)
			if collected then return end
			local char = hit:FindFirstAncestorOfClass("Model")
			local player = char and Players:GetPlayerFromCharacter(char)
			if not player then return end
			collected = true

			local finalValue, comboCount, comboMult = applyCombo(player, CLUSTER_ORB_VALUE)
			local newTotal = PlayerDataService.AddSparks(player, finalValue)
			remotes.SparksUpdated:FireClient(player, newTotal)
			remotes.OrbCollected:FireAllClients(finalValue, orb.Position)
			remotes.ComboUpdated:FireClient(player, comboCount, comboMult)
			QuestService.ReportProgress(player, "orbs", 1)
			QuestService.ReportProgress(player, "sparks", finalValue)

			local profile = PlayerDataService.Get(player)
			if profile then
				profile.orbsCollectedTotal = (profile.orbsCollectedTotal or 0) + 1
			end

			orb:Destroy()
		end)

		task.delay(CLUSTER_LIFETIME, function()
			if orb.Parent then orb:Destroy() end
		end)
	end

	task.delay(CLUSTER_LIFETIME + 1, function()
		if clusterFolder.Parent then clusterFolder:Destroy() end
	end)
end

function OrbService.Init()
	orbsFolder = workspace:FindFirstChild("SparkOrbs")
	if orbsFolder then orbsFolder:Destroy() end
	orbsFolder = Instance.new("Folder")
	orbsFolder.Name = "SparkOrbs"
	orbsFolder.Parent = workspace

	for _ = 1, MAX_ORBS do
		spawnOrb()
		task.wait(0.05) -- stagger creation, avoid a single-frame spike
	end
	print("[OrbService] " .. MAX_ORBS .. " Spark Orbs seeded across the island")

	task.spawn(function()
		while true do
			task.wait(CLUSTER_INTERVAL)
			local ok, err = pcall(spawnCluster)
			if not ok then warn("[OrbService] cluster spawn failed:", err) end
		end
	end)
end

return OrbService

--[[
	CrystalExplosionService.lua
	World identity mechanic (item #7: "Crystal Caves: Crystals explode"): a crystal
	spawns and visibly GROWS/pulses over a charge period, then bursts into scattered
	collectible shards. A genuine "buildup and payoff" pattern -- distinct from Forest
	(find hidden), Beach (catch fleeing), Desert (survive event), and Snow (persistent
	physics). The tension here is watching it grow, then scrambling to grab shards once
	it goes off.
]]

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local WorldsData = require(RS.CritterRush.Modules.WorldsData)
local PlayerDataService = require(script.Parent.PlayerDataService)
local QuestService = require(script.Parent.QuestService)
local AnalyticsService = require(script.Parent.AnalyticsService)

local remotes = RS.CritterRush.Remotes

local CrystalExplosionService = {}

local SPAWN_INTERVAL_SECONDS = { min = 30, max = 50 }
local CHARGE_DURATION = 8
local SHARD_COUNT = 6
local SHARD_VALUE = { min = 15, max = 35 }
local SHARD_LIFETIME = 15
local SCATTER_RADIUS = 55 -- inside the ~70-stud zone ground platform

local function randomPoint(center)
	local angle = math.random() * math.pi * 2
	local r = math.random() * SCATTER_RADIUS
	return center + Vector3.new(math.cos(angle) * r, 3, math.sin(angle) * r)
end

local function spawnShards(shardsFolder, burstPos)
	for i = 1, SHARD_COUNT do
		local angle = (i / SHARD_COUNT) * math.pi * 2
		local offset = Vector3.new(math.cos(angle) * 4, 1, math.sin(angle) * 4)
		local pos = burstPos + offset

		local shard = Instance.new("Part")
		shard.Name = "CrystalShard"
		shard.Size = Vector3.new(1.2, 1.6, 1.2)
		shard.Color = Color3.fromRGB(150, 110, 255)
		shard.Material = Enum.Material.Neon
		shard.CanCollide = false
		shard.Anchored = true
		shard.CFrame = CFrame.new(pos) * CFrame.Angles(0, math.random() * math.pi * 2, math.rad(math.random(-15, 15)))
		shard.Parent = shardsFolder

		local sparkle = Instance.new("ParticleEmitter")
		sparkle.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		sparkle.Color = ColorSequence.new(Color3.fromRGB(190, 150, 255))
		sparkle.Rate = 8
		sparkle.Lifetime = NumberRange.new(0.4, 0.7)
		sparkle.Speed = NumberRange.new(0.4, 1)
		sparkle.LightEmission = 1
		sparkle.Parent = shard

		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(180, 140, 255)
		light.Range = 8
		light.Brightness = 1.5
		light.Parent = shard

		local collected = false
		shard.Touched:Connect(function(hit)
			if collected then return end
			local char = hit:FindFirstAncestorOfClass("Model")
			local player = char and Players:GetPlayerFromCharacter(char)
			if not player then return end
			collected = true

			local reward = math.random(SHARD_VALUE.min, SHARD_VALUE.max)
		-- Geode Rush: more valuable shards.
		if workspace:GetAttribute("SAC_EventGeodeRush") then reward *= 2 end
			local newTotal = PlayerDataService.AddSparks(player, reward)
		-- Relic roll: a rare persistent drop so this mechanic keeps mattering
		-- after its Sparks stop being meaningful.
		local relic, relicCount = PlayerDataService.TryDropRelic(player, "CrystalCaves")
		if relic then
			local rr = remotes:FindFirstChild("RelicFound")
			if rr then rr:FireClient(player, relic.icon, relic.name, relicCount) end
		end
			remotes.SparksUpdated:FireClient(player, newTotal)
			QuestService.ReportProgress(player, "sparks", reward)
			AnalyticsService.LogRewardEarned(player, reward, newTotal, "CrystalShard")
			remotes.OrbCollected:FireAllClients(reward, shard.Position)

			shard:Destroy()
		end)

		task.delay(SHARD_LIFETIME, function()
			if shard.Parent then shard:Destroy() end
		end)
	end
end

local function runCrystal(crystalsFolder, shardsFolder, center)
	local pos = randomPoint(center)

	local crystal = Instance.new("Part")
	crystal.Name = "GrowingCrystal"
	crystal.Shape = Enum.PartType.Block
	crystal.Size = Vector3.new(1, 1, 1) -- starts tiny, grows over the charge period
	crystal.Color = Color3.fromRGB(150, 110, 255)
	crystal.Material = Enum.Material.Neon
	crystal.CanCollide = false
	crystal.Anchored = true
	crystal.CFrame = CFrame.new(pos) * CFrame.Angles(0, math.rad(45), math.rad(20))
	crystal.Parent = crystalsFolder

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(180, 140, 255)
	light.Range = 6
	light.Brightness = 1
	light.Parent = crystal

	remotes.ServerAnnouncement:FireAllClients("\u{1F48E} A crystal is growing in the Caves... stand back!")

	-- Grows in visible stages rather than one smooth tween, so the escalating danger
	-- reads clearly even to someone glancing at it mid-charge.
	local stages = 4
	for stage = 1, stages do
		if not crystal.Parent then return end
		local scale = 1 + (stage / stages) * 5 -- grows from 1x up to 6x size
		local tween = TweenService:Create(crystal, TweenInfo.new(CHARGE_DURATION / stages, Enum.EasingStyle.Sine),
			{ Size = Vector3.new(scale, scale, scale) })
		tween:Play()
		light.Brightness = 1 + stage * 1.5
		task.wait(CHARGE_DURATION / stages)
	end

	if not crystal.Parent then return end
	local burstPos = crystal.Position
	crystal:Destroy()

	-- Burst flash + shard scatter
	local flash = Instance.new("Part")
	flash.Shape = Enum.PartType.Ball
	flash.Size = Vector3.new(2, 2, 2)
	flash.Color = Color3.fromRGB(220, 200, 255)
	flash.Material = Enum.Material.Neon
	flash.CanCollide = false
	flash.Anchored = true
	flash.Position = burstPos
	flash.Parent = shardsFolder
	TweenService:Create(flash, TweenInfo.new(0.4, Enum.EasingStyle.Quad), { Size = Vector3.new(14, 14, 14), Transparency = 1 }):Play()
	task.delay(0.5, function() if flash.Parent then flash:Destroy() end end)

	remotes.ServerAnnouncement:FireAllClients("\u{1F4A5} The crystal EXPLODED! Grab the shards!")
	spawnShards(shardsFolder, burstPos)
end

function CrystalExplosionService.Init()
	local caves = WorldsData.GetWorld("CrystalCaves")
	if not caves or not caves.zonePosition then return end
	local center = caves.zonePosition

	local crystalsFolder = workspace:FindFirstChild("GrowingCrystals")
	if crystalsFolder then crystalsFolder:Destroy() end
	crystalsFolder = Instance.new("Folder")
	crystalsFolder.Name = "GrowingCrystals"
	crystalsFolder.Parent = workspace

	local shardsFolder = workspace:FindFirstChild("CrystalShards")
	if shardsFolder then shardsFolder:Destroy() end
	shardsFolder = Instance.new("Folder")
	shardsFolder.Name = "CrystalShards"
	shardsFolder.Parent = workspace

	task.spawn(function()
		while true do
			task.wait(math.random(SPAWN_INTERVAL_SECONDS.min, SPAWN_INTERVAL_SECONDS.max))
			local ok, err = pcall(runCrystal, crystalsFolder, shardsFolder, center)
			if not ok then warn("[CrystalExplosionService] crystal cycle failed:", err) end
		end
	end)
end

return CrystalExplosionService

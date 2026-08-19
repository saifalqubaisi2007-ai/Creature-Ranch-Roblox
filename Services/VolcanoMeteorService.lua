--[[
	VolcanoMeteorService.lua
	World identity mechanic (item #7, final world: "Volcano: Meteor shower"): a burst of
	meteors falls on the Volcano zone. Each telegraphs its impact point with a warning
	marker BEFORE landing, then drops molten ore the player can grab. The distinct hook
	here is the telegraph -- unlike Forest (find), Beach (catch), Desert (survive), Snow
	(physics), or Crystal Caves (grow/burst), this one gives the player advance warning
	and a real "get there fast, but the ore only lasts a moment" decision.
]]

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local WorldsData = require(RS.CritterRush.Modules.WorldsData)
local PlayerDataService = require(script.Parent.PlayerDataService)
local QuestService = require(script.Parent.QuestService)
local AnalyticsService = require(script.Parent.AnalyticsService)

local remotes = RS.CritterRush.Remotes

local VolcanoMeteorService = {}

local SHOWER_INTERVAL_SECONDS = { min = 60, max = 120 }
local METEORS_PER_SHOWER = 5
local METEOR_STAGGER = 1.2
local TELEGRAPH_DURATION = 1.5
local FALL_DURATION = 0.7
local ORE_LIFETIME = 10
local ORE_VALUE = { min = 50, max = 120 }
local SCATTER_RADIUS = 50

local function randomPoint(center)
	local angle = math.random() * math.pi * 2
	local r = math.random() * SCATTER_RADIUS
	return center + Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r)
end

local function dropOre(oreFolder, pos)
	local ore = Instance.new("Part")
	ore.Name = "MoltenOre"
	ore.Shape = Enum.PartType.Ball
	ore.Size = Vector3.new(2.2, 2.2, 2.2)
	ore.Color = Color3.fromRGB(255, 130, 40)
	ore.Material = Enum.Material.Neon
	ore.CanCollide = false
	ore.Anchored = true
	ore.CFrame = CFrame.new(pos + Vector3.new(0, 2, 0))
	ore.Parent = oreFolder

	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(255, 150, 60)
	glow.Range = 12
	glow.Brightness = 3
	glow.Parent = ore

	local embers = Instance.new("ParticleEmitter")
	embers.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	embers.Color = ColorSequence.new(Color3.fromRGB(255, 180, 90))
	embers.Rate = 12
	embers.Lifetime = NumberRange.new(0.4, 0.9)
	embers.Speed = NumberRange.new(0.6, 1.4)
	embers.LightEmission = 1
	embers.Parent = ore

	local collected = false
	ore.Touched:Connect(function(hit)
		if collected then return end
		local char = hit:FindFirstAncestorOfClass("Model")
		local player = char and Players:GetPlayerFromCharacter(char)
		if not player then return end
		collected = true

		local reward = math.random(ORE_VALUE.min, ORE_VALUE.max)
		-- Volcanic Fury event doubles the payout.
		if workspace:GetAttribute("SAC_EventVolcanicFury") then reward *= 2 end
		local newTotal = PlayerDataService.AddSparks(player, reward)
		-- Relic roll: a rare persistent drop so this mechanic keeps mattering
		-- after its Sparks stop being meaningful.
		local relic, relicCount = PlayerDataService.TryDropRelic(player, "Volcano")
		if relic then
			local rr = remotes:FindFirstChild("RelicFound")
			if rr then rr:FireClient(player, relic.icon, relic.name, relicCount) end
		end
		remotes.SparksUpdated:FireClient(player, newTotal)
		QuestService.ReportProgress(player, "sparks", reward)
		AnalyticsService.LogRewardEarned(player, reward, newTotal, "MoltenOre")
		remotes.OrbCollected:FireAllClients(reward, ore.Position)

		local oreRemote = remotes:FindFirstChild("MoltenOreCollected")
		if oreRemote then
			oreRemote:FireClient(player, reward)
		end

		ore:Destroy()
	end)

	task.delay(ORE_LIFETIME, function()
		if ore.Parent then ore:Destroy() end
	end)
end

local function dropMeteor(meteorFolder, oreFolder, center)
	local impactPos = randomPoint(center)

	-- Telegraph marker: a flat warning ring on the ground showing exactly where this
	-- meteor will land. This is the mechanic's signature -- advance warning turns a
	-- random hazard into a real decision about where to position yourself.
	local marker = Instance.new("Part")
	marker.Name = "ImpactMarker"
	marker.Shape = Enum.PartType.Cylinder
	marker.Size = Vector3.new(0.4, 10, 10)
	marker.Color = Color3.fromRGB(255, 80, 40)
	marker.Material = Enum.Material.Neon
	marker.Transparency = 0.5
	marker.CanCollide = false
	marker.Anchored = true
	marker.CFrame = CFrame.new(impactPos + Vector3.new(0, 2.5, 0)) * CFrame.Angles(0, 0, math.rad(90))
	marker.Parent = meteorFolder
	TweenService:Create(marker, TweenInfo.new(TELEGRAPH_DURATION, Enum.EasingStyle.Linear),
		{ Transparency = 0.15 }):Play()

	-- The falling meteor itself, starting high above the impact point.
	local meteor = Instance.new("Part")
	meteor.Name = "Meteor"
	meteor.Shape = Enum.PartType.Ball
	meteor.Size = Vector3.new(4, 4, 4)
	meteor.Color = Color3.fromRGB(90, 40, 30)
	meteor.Material = Enum.Material.Slate
	meteor.CanCollide = false
	meteor.Anchored = true
	meteor.CFrame = CFrame.new(impactPos + Vector3.new(0, 200, 0))
	meteor.Parent = meteorFolder

	local trail = Instance.new("ParticleEmitter")
	trail.Texture = "rbxasset://textures/particles/fire_main.dds"
	trail.Color = ColorSequence.new(Color3.fromRGB(255, 140, 50))
	trail.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 4), NumberSequenceKeypoint.new(1, 0) })
	trail.Rate = 40
	trail.Lifetime = NumberRange.new(0.3, 0.6)
	trail.Speed = NumberRange.new(1, 3)
	trail.LightEmission = 1
	trail.Parent = meteor

	task.wait(TELEGRAPH_DURATION)
	if not meteor.Parent then return end

	TweenService:Create(meteor, TweenInfo.new(FALL_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ CFrame = CFrame.new(impactPos + Vector3.new(0, 2, 0)) }):Play()
	task.wait(FALL_DURATION)

	-- Impact: flash, clean up marker + meteor, leave collectable ore behind.
	local flash = Instance.new("Part")
	flash.Shape = Enum.PartType.Ball
	flash.Size = Vector3.new(3, 3, 3)
	flash.Color = Color3.fromRGB(255, 190, 120)
	flash.Material = Enum.Material.Neon
	flash.CanCollide = false
	flash.Anchored = true
	flash.Position = impactPos + Vector3.new(0, 2, 0)
	flash.Parent = meteorFolder
	TweenService:Create(flash, TweenInfo.new(0.4, Enum.EasingStyle.Quad),
		{ Size = Vector3.new(18, 18, 18), Transparency = 1 }):Play()

	if marker.Parent then marker:Destroy() end
	if meteor.Parent then meteor:Destroy() end
	task.delay(0.5, function() if flash.Parent then flash:Destroy() end end)

	dropOre(oreFolder, impactPos)
end

local function runShower(meteorFolder, oreFolder, center)
	-- Skip if nobody's in the zone -- same discipline as every other world mechanic.
	local anyoneNear = false
	for _, player in ipairs(Players:GetPlayers()) do
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp and (hrp.Position - center).Magnitude <= 70 then
			anyoneNear = true
			break
		end
	end
	if not anyoneNear then return end

	remotes.ServerAnnouncement:FireAllClients("\u{2604}\u{FE0F} METEOR SHOWER over the Volcano! Grab the molten ore!")

	for i = 1, METEORS_PER_SHOWER do
		task.spawn(function()
			local ok, err = pcall(dropMeteor, meteorFolder, oreFolder, center)
			if not ok then warn("[VolcanoMeteorService] meteor failed:", err) end
		end)
		task.wait(METEOR_STAGGER)
	end
end

function VolcanoMeteorService.Init()
	local volcano = WorldsData.GetWorld("Volcano")
	if not volcano or not volcano.zonePosition then return end
	local center = volcano.zonePosition

	local meteorFolder = workspace:FindFirstChild("VolcanoMeteors")
	if meteorFolder then meteorFolder:Destroy() end
	meteorFolder = Instance.new("Folder")
	meteorFolder.Name = "VolcanoMeteors"
	meteorFolder.Parent = workspace

	local oreFolder = workspace:FindFirstChild("MoltenOre")
	if oreFolder then oreFolder:Destroy() end
	oreFolder = Instance.new("Folder")
	oreFolder.Name = "MoltenOre"
	oreFolder.Parent = workspace

	task.spawn(function()
		while true do
			task.wait(math.random(SHOWER_INTERVAL_SECONDS.min, SHOWER_INTERVAL_SECONDS.max))
			local ok, err = pcall(runShower, meteorFolder, oreFolder, center)
			if not ok then warn("[VolcanoMeteorService] shower failed:", err) end
		end
	end)
end

return VolcanoMeteorService

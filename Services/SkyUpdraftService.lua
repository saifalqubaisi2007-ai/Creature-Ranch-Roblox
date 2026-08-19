--[[
	SkyUpdraftService.lua
	World identity mechanic for Sky Islands: rising updrafts that launch the player
	upward to reach floating Wind Crystals suspended above the zone.

	Deliberately the VERTICAL axis, which no other world uses:
	  Forest = find hidden      Beach = catch fleeing      Desert = survive weather
	  Snow   = ground physics   Crystal = grow/burst       Volcano = telegraph/dodge
	This is the only mechanic where the reward is out of walking reach entirely, so it
	reads as a genuinely different kind of challenge rather than a reskin.

	Uses real physics (BodyVelocity on the character) rather than teleporting, so the
	launch feels like being carried rather than snapped -- and so a player can steer
	mid-flight toward whichever crystal they want.
]]

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local WorldsData = require(RS.CritterRush.Modules.WorldsData)
local PlayerDataService = require(script.Parent.PlayerDataService)
local QuestService = require(script.Parent.QuestService)
local AnalyticsService = require(script.Parent.AnalyticsService)

local remotes = RS.CritterRush.Remotes

local SkyUpdraftService = {}

local CYCLE_SECONDS = { min = 50, max = 90 }
local UPDRAFT_COUNT = 3
local UPDRAFT_RADIUS = 9
local UPDRAFT_LIFETIME = 30
local LAUNCH_VELOCITY = 90
local CRYSTAL_COUNT = 5
local CRYSTAL_HEIGHT = { min = 45, max = 75 }
local CRYSTAL_VALUE = { min = 120, max = 260 }
local CRYSTAL_LIFETIME = 35
local SCATTER_RADIUS = 45

local function randomPoint(center, radius, y)
	local a = math.random() * math.pi * 2
	local r = math.random() * radius
	return center + Vector3.new(math.cos(a) * r, y, math.sin(a) * r)
end

-- Floating reward. Deliberately spawned ABOVE walking height so the updraft is the
-- only way to reach it -- otherwise the mechanic is decorative.
local function spawnCrystal(folder, center)
	local height = math.random(CRYSTAL_HEIGHT.min, CRYSTAL_HEIGHT.max)
	local pos = randomPoint(center, SCATTER_RADIUS, height)

	local c = Instance.new("Part")
	c.Name = "WindCrystal"
	c.Shape = Enum.PartType.Ball
	c.Size = Vector3.new(3.0, 3.6, 3.0)
	c.Color = Color3.fromRGB(190, 235, 255)
	c.Material = Enum.Material.Neon
	c.CanCollide = false
	c.Anchored = true
	c.CFrame = CFrame.new(pos)
	c.Parent = folder

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(200, 240, 255)
	light.Range = 16
	light.Brightness = 2.5
	light.Parent = c

	local sparkle = Instance.new("ParticleEmitter")
	sparkle.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	sparkle.Color = ColorSequence.new(Color3.fromRGB(215, 245, 255))
	sparkle.Rate = 14
	sparkle.Lifetime = NumberRange.new(0.5, 1.0)
	sparkle.Speed = NumberRange.new(0.5, 1.2)
	sparkle.LightEmission = 1
	sparkle.Parent = c

	-- Slow bob so it reads as floating rather than pinned in the air.
	local phase = math.random() * math.pi * 2
	local conn
	conn = game:GetService("RunService").Heartbeat:Connect(function()
		if not c.Parent then conn:Disconnect() return end
		c.CFrame = CFrame.new(pos + Vector3.new(0, math.sin(os.clock() * 1.2 + phase) * 1.8, 0))
			* CFrame.Angles(0, os.clock() * 0.8, 0)
	end)

	local claimed = false
	c.Touched:Connect(function(hit)
		if claimed then return end
		local char = hit:FindFirstAncestorOfClass("Model")
		local player = char and Players:GetPlayerFromCharacter(char)
		if not player then return end
		claimed = true

		local reward = math.random(CRYSTAL_VALUE.min, CRYSTAL_VALUE.max)
		-- Sky Tempest event triples Wind Crystal value.
		if workspace:GetAttribute("SAC_EventSkyTempest") then reward *= 3 end
		local newTotal = PlayerDataService.AddSparks(player, reward)
		-- Relic roll: a rare persistent drop so this mechanic keeps mattering
		-- after its Sparks stop being meaningful.
		local relic, relicCount = PlayerDataService.TryDropRelic(player, "SkyIslands")
		if relic then
			local rr = remotes:FindFirstChild("RelicFound")
			if rr then rr:FireClient(player, relic.icon, relic.name, relicCount) end
		end
		remotes.SparksUpdated:FireClient(player, newTotal)
		QuestService.ReportProgress(player, "sparks", reward)
		AnalyticsService.LogRewardEarned(player, reward, newTotal, "WindCrystal")
		local r = remotes:FindFirstChild("WindCrystalCollected")
		if r then r:FireClient(player, reward) end

		conn:Disconnect()
		c:Destroy()
	end)

	task.delay(CRYSTAL_LIFETIME, function()
		if c.Parent then conn:Disconnect() c:Destroy() end
	end)
end

-- The updraft itself: a visible column that launches anyone standing in it.
local function spawnUpdraft(folder, center)
	local pos = randomPoint(center, SCATTER_RADIUS, 3)

	local column = Instance.new("Part")
	column.Name = "Updraft"
	column.Shape = Enum.PartType.Cylinder
	column.Size = Vector3.new(40, UPDRAFT_RADIUS * 2, UPDRAFT_RADIUS * 2)
	column.CFrame = CFrame.new(pos + Vector3.new(0, 20, 0)) * CFrame.Angles(0, 0, math.rad(90))
	column.Color = Color3.fromRGB(200, 240, 255)
	column.Material = Enum.Material.Neon
	column.Transparency = 0.75
	column.CanCollide = false
	column.Anchored = true
	column.Parent = folder

	local swirl = Instance.new("ParticleEmitter")
	swirl.Texture = "rbxasset://textures/particles/smoke_main.dds"
	swirl.Color = ColorSequence.new(Color3.fromRGB(225, 245, 255))
	swirl.Size = NumberSequence.new(3)
	swirl.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1),
	})
	swirl.Rate = 30
	swirl.Lifetime = NumberRange.new(1.2, 2.0)
	swirl.Speed = NumberRange.new(18, 26)
	swirl.Acceleration = Vector3.new(0, 30, 0)
	swirl.Parent = column

	-- Launch anyone inside. Re-checked on a loop rather than Touched, because a player
	-- standing still inside the column never fires a new Touched event.
	local active = true
	task.spawn(function()
		while active and column.Parent do
			for _, player in ipairs(Players:GetPlayers()) do
				local char = player.Character
				local hrp = char and char:FindFirstChild("HumanoidRootPart")
				if hrp then
					local flat = Vector3.new(hrp.Position.X - pos.X, 0, hrp.Position.Z - pos.Z)
					if flat.Magnitude <= UPDRAFT_RADIUS and hrp.Position.Y < pos.Y + 45 then
						-- Only add lift if they're not already rising fast, so repeated
						-- ticks don't compound into an uncontrollable launch.
						if hrp.AssemblyLinearVelocity.Y < LAUNCH_VELOCITY * 0.6 then
							hrp.AssemblyLinearVelocity = Vector3.new(
								hrp.AssemblyLinearVelocity.X,
								LAUNCH_VELOCITY,
								hrp.AssemblyLinearVelocity.Z)
						end
					end
				end
			end
			task.wait(0.15)
		end
	end)

	task.delay(UPDRAFT_LIFETIME, function()
		active = false
		if column.Parent then column:Destroy() end
	end)
end

function SkyUpdraftService.Init()
	local world = WorldsData.GetWorld("SkyIslands")
	if not world or not world.zonePosition then return end
	local center = world.zonePosition

	local folder = workspace:FindFirstChild("SkyUpdrafts")
	if folder then folder:Destroy() end
	folder = Instance.new("Folder")
	folder.Name = "SkyUpdrafts"
	folder.Parent = workspace

	task.spawn(function()
		while true do
			task.wait(math.random(CYCLE_SECONDS.min, CYCLE_SECONDS.max))
			-- Skip when nobody's present, same discipline as every other world mechanic.
			local anyone = false
			for _, player in ipairs(Players:GetPlayers()) do
				local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
				if hrp and (hrp.Position - center).Magnitude <= 80 then anyone = true break end
			end
			if anyone then
				remotes.ServerAnnouncement:FireAllClients(
					"\u{1F32C}\u{FE0F} UPDRAFTS rising over the Sky Islands! Ride them to the Wind Crystals!")
				for _ = 1, UPDRAFT_COUNT do
					local ok, err = pcall(spawnUpdraft, folder, center)
					if not ok then warn("[SkyUpdraftService] updraft failed:", err) end
				end
				for _ = 1, CRYSTAL_COUNT do
					local ok, err = pcall(spawnCrystal, folder, center)
					if not ok then warn("[SkyUpdraftService] crystal failed:", err) end
				end
			end
		end
	end)
end

return SkyUpdraftService

--[[
	ForestSpriteService.lua
	World identity mechanic (item #7: "Forest: Creatures hide"): small wild Sprite
	critters periodically spawn hidden around the Forest zone's ground. First player to
	find one gets a real Sparks bonus. Deliberately Forest-ONLY and separate from the
	island-wide World Events / Golden Critter systems -- this is what makes Forest feel
	distinct rather than "the same events, different scenery".
]]

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local WorldsData = require(RS.CritterRush.Modules.WorldsData)
local PlayerDataService = require(script.Parent.PlayerDataService)
local QuestService = require(script.Parent.QuestService)
local AnalyticsService = require(script.Parent.AnalyticsService)

local remotes = RS.CritterRush.Remotes

local ForestSpriteService = {}

local SPAWN_INTERVAL_SECONDS = { min = 45, max = 90 }
local SPRITE_LIFETIME = 40
local SPRITE_REWARD = { min = 40, max = 100 }
local SCATTER_RADIUS = 55 -- comfortably inside the ~70-stud Forest zone ground platform

local function randomForestPoint(center)
	local angle = math.random() * math.pi * 2
	local r = math.random() * SCATTER_RADIUS
	return center + Vector3.new(math.cos(angle) * r, 3, math.sin(angle) * r)
end

local function spawnSprite(spritesFolder, center)
	local pos = randomForestPoint(center)

	local model = Instance.new("Model")
	model.Name = "ForestSprite"

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Shape = Enum.PartType.Ball
	body.Size = Vector3.new(2.4, 2.2, 2.4)
	body.Color = Color3.fromRGB(140, 255, 170)
	body.Material = Enum.Material.Neon
	body.CanCollide = false
	body.Anchored = true
	body.CFrame = CFrame.new(pos)
	body.Parent = model
	model.PrimaryPart = body

	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(160, 255, 180)
	glow.Range = 10
	glow.Brightness = 2
	glow.Parent = body

	local sparkle = Instance.new("ParticleEmitter")
	sparkle.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	sparkle.Color = ColorSequence.new(Color3.fromRGB(180, 255, 190))
	sparkle.Rate = 6
	sparkle.Lifetime = NumberRange.new(0.4, 0.8)
	sparkle.Speed = NumberRange.new(0.3, 0.7)
	sparkle.LightEmission = 1
	sparkle.Parent = body

	-- Gentle bob so a sprite reads as "alive and hiding", not just a static prop --
	-- same proven pattern as OrbService's orb bob.
	local bobPhase = math.random() * math.pi * 2
	local bobConn
	bobConn = game:GetService("RunService").Heartbeat:Connect(function()
		if not body.Parent then
			bobConn:Disconnect()
			return
		end
		local t = os.clock() * 1.5 + bobPhase
		body.CFrame = CFrame.new(pos + Vector3.new(0, math.sin(t) * 0.5, 0))
	end)

	model.Parent = spritesFolder

	local claimed = false
	body.Touched:Connect(function(hit)
		if claimed then return end
		local char = hit:FindFirstAncestorOfClass("Model")
		local player = char and Players:GetPlayerFromCharacter(char)
		if not player then return end
		claimed = true

		local reward = math.random(SPRITE_REWARD.min, SPRITE_REWARD.max)
		local newTotal = PlayerDataService.AddSparks(player, reward)
		-- Relic roll: a rare persistent drop so this mechanic keeps mattering
		-- after its Sparks stop being meaningful.
		local relic, relicCount = PlayerDataService.TryDropRelic(player, "Forest")
		if relic then
			local rr = remotes:FindFirstChild("RelicFound")
			if rr then rr:FireClient(player, relic.icon, relic.name, relicCount) end
		end
		remotes.SparksUpdated:FireClient(player, newTotal)
		QuestService.ReportProgress(player, "sparks", reward)
		AnalyticsService.LogRewardEarned(player, reward, newTotal, "ForestSprite")

		local foundRemote = remotes:FindFirstChild("ForestSpriteFound")
		if foundRemote then
			foundRemote:FireClient(player, reward)
		end

		bobConn:Disconnect()
		model:Destroy()
	end)

	task.delay(SPRITE_LIFETIME, function()
		if model.Parent then
			bobConn:Disconnect()
			model:Destroy()
		end
	end)
end

function ForestSpriteService.Init()
	local forest = WorldsData.GetWorld("Forest")
	if not forest or not forest.zonePosition then return end
	local center = forest.zonePosition

	local spritesFolder = workspace:FindFirstChild("ForestSprites")
	if spritesFolder then spritesFolder:Destroy() end
	spritesFolder = Instance.new("Folder")
	spritesFolder.Name = "ForestSprites"
	spritesFolder.Parent = workspace

	task.spawn(function()
		while true do
			local waitFor = math.random(SPAWN_INTERVAL_SECONDS.min, SPAWN_INTERVAL_SECONDS.max)
			-- Forest Bloom event halves the gap between sprite spawns.
			if workspace:GetAttribute("SAC_EventForestBloom") then waitFor = waitFor / 2 end
			task.wait(waitFor)
			local ok, err = pcall(spawnSprite, spritesFolder, center)
			if not ok then warn("[ForestSpriteService] spawn failed:", err) end
		end
	end)
end

return ForestSpriteService

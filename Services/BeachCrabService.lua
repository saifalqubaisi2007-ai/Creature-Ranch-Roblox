--[[
	BeachCrabService.lua
	World identity mechanic (item #7: "Beach: Crabs steal Sparks"): a crab periodically
	spawns near a targeted player on the Beach, scuttles for a short window, and either
	gets CAUGHT (touch it -> real bonus reward) or ESCAPES (timer expires -> steals a
	small amount of Sparks from the player it targeted). Genuine stakes, distinct from
	Forest Sprites' pure-reward "find the hidden creature" -- this is "catch it before
	it gets away with your Sparks".
]]

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local WorldsData = require(RS.CritterRush.Modules.WorldsData)
local PlayerDataService = require(script.Parent.PlayerDataService)
local QuestService = require(script.Parent.QuestService)
local AnalyticsService = require(script.Parent.AnalyticsService)

local remotes = RS.CritterRush.Remotes

local BeachCrabService = {}

local SPAWN_INTERVAL_SECONDS = { min = 45, max = 90 }
local CRAB_LIFETIME = 12 -- shorter than Forest Sprites -- genuine urgency to catch it
local CATCH_REWARD = { min = 40, max = 80 }
local STEAL_AMOUNT = { min = 10, max = 25 } -- deliberately small -- a "gotcha", not a real economic hit
local SPAWN_RADIUS_FROM_PLAYER = 12 -- close enough to notice, far enough to require a real chase

-- Finds a player currently near the Beach zone to target -- crabs only spawn when
-- there's genuinely someone around to chase them, same spirit as not wasting a Golden
-- Critter sighting on an empty server.
local function findNearbyPlayer(center)
	local candidates = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp and (hrp.Position - center).Magnitude <= 70 then
			table.insert(candidates, player)
		end
	end
	if #candidates == 0 then return nil end
	return candidates[math.random(1, #candidates)]
end

local function spawnCrab(crabsFolder, center)
	local target = findNearbyPlayer(center)
	if not target then return end -- nobody around; skip this cycle silently

	local targetChar = target.Character
	local targetHrp = targetChar and targetChar:FindFirstChild("HumanoidRootPart")
	if not targetHrp then return end

	local angle = math.random() * math.pi * 2
	local spawnPos = targetHrp.Position + Vector3.new(math.cos(angle) * SPAWN_RADIUS_FROM_PLAYER, 0,
		math.sin(angle) * SPAWN_RADIUS_FROM_PLAYER)

	local model = Instance.new("Model")
	model.Name = "BeachCrab"

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = Vector3.new(2.4, 1.1, 1.8)
	body.Color = Color3.fromRGB(220, 90, 60)
	body.Material = Enum.Material.SmoothPlastic
	body.CanCollide = false
	body.Anchored = true
	body.CFrame = CFrame.new(spawnPos)
	body.Parent = model
	model.PrimaryPart = body

	local function claw(xOffset)
		local c = Instance.new("Part")
		c.Shape = Enum.PartType.Ball
		c.Size = Vector3.new(0.7, 0.7, 0.7)
		c.Color = Color3.fromRGB(235, 110, 75)
		c.Material = Enum.Material.SmoothPlastic
		c.CanCollide = false
		c.Anchored = true
		c.CFrame = body.CFrame * CFrame.new(xOffset, 0.2, -1.0)
		c.Parent = model
	end
	claw(-1.0)
	claw(1.0)

	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(255, 150, 100)
	glow.Range = 8
	glow.Brightness = 1.2
	glow.Parent = body

	model.Parent = crabsFolder

	-- Scuttle: rapid side-to-side motion, distinct from Forest Sprites' calm vertical
	-- bob -- reads as genuinely trying to escape, not just idling in place.
	local scuttlePhase = math.random() * math.pi * 2
	local scuttleConn
	scuttleConn = RunService.Heartbeat:Connect(function()
		if not body.Parent then
			scuttleConn:Disconnect()
			return
		end
		local t = os.clock() * 5 + scuttlePhase
		body.CFrame = CFrame.new(spawnPos + Vector3.new(math.sin(t) * 1.5, 0, math.cos(t * 0.6) * 0.5))
			* CFrame.Angles(0, math.sin(t) * 0.3, 0)
	end)

	local resolved = false

	local function cleanup()
		if scuttleConn then scuttleConn:Disconnect() end
		if model.Parent then model:Destroy() end
	end

	body.Touched:Connect(function(hit)
		if resolved then return end
		local char = hit:FindFirstAncestorOfClass("Model")
		local player = char and Players:GetPlayerFromCharacter(char)
		if not player then return end
		resolved = true

		local reward = math.random(CATCH_REWARD.min, CATCH_REWARD.max)
		-- King Tide doubles the payout. Read at grant time (not spawn) so an event
		-- starting mid-chase still counts.
		if workspace:GetAttribute("SAC_EventKingTide") then reward *= 2 end
		local newTotal = PlayerDataService.AddSparks(player, reward)
		-- Relic roll: a rare persistent drop so this mechanic keeps mattering
		-- after its Sparks stop being meaningful.
		local relic, relicCount = PlayerDataService.TryDropRelic(player, "Beach")
		if relic then
			local rr = remotes:FindFirstChild("RelicFound")
			if rr then rr:FireClient(player, relic.icon, relic.name, relicCount) end
		end
		remotes.SparksUpdated:FireClient(player, newTotal)
		QuestService.ReportProgress(player, "sparks", reward)
		AnalyticsService.LogRewardEarned(player, reward, newTotal, "BeachCrabCaught")

		local caughtRemote = remotes:FindFirstChild("BeachCrabResult")
		if caughtRemote then
			caughtRemote:FireClient(player, true, reward)
		end

		cleanup()
	end)

	task.delay(CRAB_LIFETIME, function()
		if resolved then return end
		resolved = true

		-- Escaped -- steals a small amount from the player it was targeting, IF that
		-- player still has a live profile and enough Sparks (TrySpendSparks safely
		-- refuses rather than going negative -- a near-empty player just isn't worth
		-- stealing from this time, a reasonable non-punishing edge case).
		local stealAmount = math.random(STEAL_AMOUNT.min, STEAL_AMOUNT.max)
		local stole = PlayerDataService.TrySpendSparks(target, stealAmount)
		if stole then
			local profile = PlayerDataService.Get(target)
			remotes.SparksUpdated:FireClient(target, profile and profile.sparks or 0)
			local resultRemote = remotes:FindFirstChild("BeachCrabResult")
			if resultRemote then
				resultRemote:FireClient(target, false, stealAmount)
			end
		end

		cleanup()
	end)
end

function BeachCrabService.Init()
	local beach = WorldsData.GetWorld("Beach")
	if not beach or not beach.zonePosition then return end
	local center = beach.zonePosition

	local crabsFolder = workspace:FindFirstChild("BeachCrabs")
	if crabsFolder then crabsFolder:Destroy() end
	crabsFolder = Instance.new("Folder")
	crabsFolder.Name = "BeachCrabs"
	crabsFolder.Parent = workspace

	task.spawn(function()
		while true do
			task.wait(math.random(SPAWN_INTERVAL_SECONDS.min, SPAWN_INTERVAL_SECONDS.max))
			local ok, err = pcall(spawnCrab, crabsFolder, center)
			if not ok then warn("[BeachCrabService] spawn failed:", err) end
		end
	end)
end

return BeachCrabService

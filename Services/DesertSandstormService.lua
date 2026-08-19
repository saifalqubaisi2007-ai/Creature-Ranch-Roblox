--[[
	DesertSandstormService.lua
	World identity mechanic (item #7: "Desert: Sandstorm"): a periodic environmental
	event scoped ONLY to the Desert zone -- unlike Beach/Forest, this isn't a creature to
	catch, it's a weather event to WEATHER. Real, visible particle effect (not global
	Lighting.Fog, which would incorrectly affect every player everywhere), and anyone
	still standing in the zone when it clears gets a genuine "survived it" bonus.
]]

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local WorldsData = require(RS.CritterRush.Modules.WorldsData)
local PlayerDataService = require(script.Parent.PlayerDataService)
local QuestService = require(script.Parent.QuestService)
local AnalyticsService = require(script.Parent.AnalyticsService)

local remotes = RS.CritterRush.Remotes

local DesertSandstormService = {}

local STORM_INTERVAL_SECONDS = { min = 120, max = 240 }
local STORM_DURATION = 25
local ZONE_RADIUS = 65 -- matches the ~70-stud Desert zone ground platform, staying inside it
local SURVIVAL_REWARD = { min = 60, max = 140 }

local function playersInZone(center)
	local inZone = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp and (hrp.Position - center).Magnitude <= ZONE_RADIUS then
			table.insert(inZone, player)
		end
	end
	return inZone
end

local function runSandstorm(center)
	-- Skip entirely if nobody's around to experience it -- same "don't waste it on an
	-- empty server" discipline as Golden Critter / Beach Crabs.
	if #playersInZone(center) == 0 then return end

	local stormFolder = Instance.new("Folder")
	stormFolder.Name = "DesertSandstorm"
	stormFolder.Parent = workspace

	-- Scoped visual: a cluster of large sand-dust ParticleEmitters anchored at the zone
	-- center, visible to anyone nearby -- deliberately NOT Lighting.FogColor/FogStart/
	-- FogEnd, since those are GLOBAL properties that would incorrectly fog the view for
	-- every player on the server, not just the ones actually in the Desert.
	for i = 1, 6 do
		local angle = (i / 6) * math.pi * 2
		local anchor = Instance.new("Part")
		anchor.Name = "SandCloudAnchor"
		anchor.Size = Vector3.new(1, 1, 1)
		anchor.Transparency = 1
		anchor.CanCollide = false
		anchor.Anchored = true
		anchor.Position = center + Vector3.new(math.cos(angle) * 30, 15, math.sin(angle) * 30)
		anchor.Parent = stormFolder

		local dust = Instance.new("ParticleEmitter")
		dust.Texture = "rbxasset://textures/particles/smoke_main.dds"
		dust.Color = ColorSequence.new(Color3.fromRGB(210, 180, 130))
		dust.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 4), NumberSequenceKeypoint.new(1, 10) })
		dust.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1),
		})
		dust.Lifetime = NumberRange.new(2, 3.5)
		dust.Speed = NumberRange.new(4, 9)
		dust.Rate = 25
		dust.SpreadAngle = Vector2.new(180, 180)
		dust.Parent = anchor
	end

	remotes.ServerAnnouncement:FireAllClients("\u{1F4A8} A SANDSTORM is sweeping the Desert! Weather it for a bonus!")
	local stormRemote = remotes:FindFirstChild("SandstormStatus")
	if stormRemote then
		stormRemote:FireAllClients(true, STORM_DURATION)
	end

	task.wait(STORM_DURATION)

	-- Reward everyone STILL in the zone when it clears -- a real "you stuck it out"
	-- moment, checked fresh at the end rather than assumed from who was there at start.
	for _, player in ipairs(playersInZone(center)) do
		local reward = math.random(SURVIVAL_REWARD.min, SURVIVAL_REWARD.max)
		-- Mirage Hour doubles survival rewards.
		if workspace:GetAttribute("SAC_EventMirageHour") then reward *= 2 end
		local newTotal = PlayerDataService.AddSparks(player, reward)
		-- Relic roll: a rare persistent drop so this mechanic keeps mattering
		-- after its Sparks stop being meaningful.
		local relic, relicCount = PlayerDataService.TryDropRelic(player, "Desert")
		if relic then
			local rr = remotes:FindFirstChild("RelicFound")
			if rr then rr:FireClient(player, relic.icon, relic.name, relicCount) end
		end
		remotes.SparksUpdated:FireClient(player, newTotal)
		QuestService.ReportProgress(player, "sparks", reward)
		AnalyticsService.LogRewardEarned(player, reward, newTotal, "SandstormSurvival")
		local survivedRemote = remotes:FindFirstChild("SandstormSurvived")
		if survivedRemote then
			survivedRemote:FireClient(player, reward)
		end
	end

	if stormRemote then
		stormRemote:FireAllClients(false, 0)
	end
	stormFolder:Destroy()
end

function DesertSandstormService.Init()
	local desert = WorldsData.GetWorld("Desert")
	if not desert or not desert.zonePosition then return end
	local center = desert.zonePosition

	local existing = workspace:FindFirstChild("DesertSandstorm")
	if existing then existing:Destroy() end

	task.spawn(function()
		while true do
			task.wait(math.random(STORM_INTERVAL_SECONDS.min, STORM_INTERVAL_SECONDS.max))
			local ok, err = pcall(runSandstorm, center)
			if not ok then warn("[DesertSandstormService] storm failed:", err) end
		end
	end)
end

return DesertSandstormService

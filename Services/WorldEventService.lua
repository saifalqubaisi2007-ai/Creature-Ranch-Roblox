--[[
	WorldEventService.lua
	Rotating server-wide events for CREATURE RANCH (v1.0 Phase 5).
	Every EVENT_INTERVAL a random event runs for EVENT_DURATION, announced server-wide
	with a countdown pushed to clients. Events hook existing systems rather than adding
	new mechanics to learn:
	  • DoubleSparks — global 2x passive income (stacks with the gamepass)
	  • GoldenRain — collectible gold droplets rain over the island; touch to collect Sparks
]]

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local PlayerDataService = require(script.Parent.PlayerDataService)
local QuestService = require(script.Parent.QuestService)
local CritterService = require(script.Parent.CritterService)
local WorldsData = require(RS.CritterRush.Modules.WorldsData)

local remotes = RS.CritterRush.Remotes

local WorldEventService = {}

local EVENT_INTERVAL = 6 * 60 -- seconds of calm between events
local EVENT_DURATION = 90 -- how long each event runs

-- Global state other services read via workspace attributes (same decoupling pattern
-- as the gamepass attributes — no cross-requires needed)
local function setGlobalEventAttribute(name, value)
	workspace:SetAttribute(name, value)
end

-- ===== Golden Critter Sighting -- a real, rare, one-of-a-kind moment (P-"create
-- clips"). Deliberately NOT in the regular EVENTS rotation below -- triggered by its
-- own much-lower-probability roll in Init() so it feels genuinely rare, not just
-- another scheduled buff. Uses pre-verified-safe ground positions from earlier this
-- session (Waterfall/Dock/RopeBridge/spawn/Ancient Tree) rather than random
-- coordinates, avoiding the exact "floating with nothing underneath" mistake found
-- and fixed on the Forest/Beach zones.
local GOLDEN_CRITTER_SPAWN_POINTS = {
	Vector3.new(-70, 30, -57), -- Waterfall
	Vector3.new(132, 12, 0), -- Dock
	Vector3.new(-40, 13, 54), -- RopeBridge
	Vector3.new(0, 11, 15), -- Spawn
	Vector3.new(70, 13, 70), -- Ancient Tree area
}
local GOLDEN_CRITTER_REWARD = 1500
local GOLDEN_CRITTER_LIFETIME = 75 -- vanishes if nobody finds it in time -- real tension

local function runGoldenCritterSighting()
	local spawnPos = GOLDEN_CRITTER_SPAWN_POINTS[math.random(1, #GOLDEN_CRITTER_SPAWN_POINTS)]

	local model = Instance.new("Model")
	model.Name = "GoldenCritterSighting"

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Shape = Enum.PartType.Ball
	body.Size = Vector3.new(6, 5.5, 6)
	body.Color = Color3.fromRGB(255, 215, 90)
	body.Material = Enum.Material.Neon
	body.CanCollide = false
	body.Anchored = true
	body.CFrame = CFrame.new(spawnPos + Vector3.new(0, 4, 0))
	body.Parent = model
	model.PrimaryPart = body

	local function eye(xOffset)
		local e = Instance.new("Part")
		e.Shape = Enum.PartType.Ball
		e.Size = Vector3.new(1.4, 1.4, 1.4)
		e.Color = Color3.new(1, 1, 1)
		e.Material = Enum.Material.SmoothPlastic
		e.CanCollide = false
		e.Anchored = true
		e.CFrame = body.CFrame * CFrame.new(xOffset, 0.3, -2.6)
		e.Parent = model
		local pupil = Instance.new("Part")
		pupil.Shape = Enum.PartType.Ball
		pupil.Size = Vector3.new(0.7, 0.7, 0.7)
		pupil.Color = Color3.fromRGB(120, 80, 20)
		pupil.Material = Enum.Material.SmoothPlastic
		pupil.CanCollide = false
		pupil.Anchored = true
		pupil.CFrame = body.CFrame * CFrame.new(xOffset, 0.3, -3.1)
		pupil.Parent = model
	end
	eye(-1.3)
	eye(1.3)

	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(255, 220, 130)
	glow.Brightness = 3
	glow.Range = 30
	glow.Parent = body

	local sparkle = Instance.new("ParticleEmitter")
	sparkle.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	sparkle.Color = ColorSequence.new(Color3.fromRGB(255, 230, 150))
	sparkle.Rate = 14
	sparkle.Lifetime = NumberRange.new(0.6, 1.1)
	sparkle.Speed = NumberRange.new(0.5, 1.3)
	sparkle.SpreadAngle = Vector2.new(180, 180)
	sparkle.LightEmission = 1
	sparkle.Parent = body

	model.Parent = workspace

	remotes.ServerAnnouncement:FireAllClients(
		"\u{1F31F} A GOLDEN CRITTER has been spotted! First to find it wins big!")
	remotes.WorldEventStarted:FireAllClients("GoldenCritter", "\u{1F31F} GOLDEN CRITTER SIGHTING!", GOLDEN_CRITTER_LIFETIME)

	local claimed = false
	body.Touched:Connect(function(hit)
		if claimed then return end
		local char = hit:FindFirstAncestorOfClass("Model")
		local player = char and Players:GetPlayerFromCharacter(char)
		if not player then return end
		claimed = true

		local newTotal = PlayerDataService.AddSparks(player, GOLDEN_CRITTER_REWARD)
		remotes.SparksUpdated:FireClient(player, newTotal)
		QuestService.ReportProgress(player, "sparks", GOLDEN_CRITTER_REWARD)

		-- Guaranteed-shiny bonus critter -- a real, ownable prize, not just a Sparks
		-- number, reusing RebirthService's exact starter-critter-grant pattern
		-- (SpawnForPlayer + AddOwnedCritter + HatchResult) with forceShiny=true.
		local startWorld = WorldsData.GetWorld(WorldsData.DEFAULT_WORLD_ID)
		local tier = startWorld.rarities[1]
		local species = startWorld.species[tier.id][math.random(1, #startWorld.species[tier.id])]
		local record = CritterService.SpawnForPlayer(player, tier, species, WorldsData.DEFAULT_WORLD_ID, nil, true)
		if record then
			PlayerDataService.AddOwnedCritter(player, {
				uid = record.uid, rarity = tier.id, species = species, worldId = WorldsData.DEFAULT_WORLD_ID,
				sparksPerSecond = record.sparksPerSecond, isShiny = record.isShiny,
			})
			remotes.HatchResult:FireClient(player, true, tier.id, species, record.uid, record.isShiny, record.personality)
		end

		remotes.ServerAnnouncement:FireAllClients(
			string.format("\u{1F31F} %s found the GOLDEN CRITTER! +%d Sparks and a free Shiny!",
				player.DisplayName:upper(), GOLDEN_CRITTER_REWARD))
		remotes.WorldEventEnded:FireAllClients("GoldenCritter")
		model:Destroy()
	end)

	task.delay(GOLDEN_CRITTER_LIFETIME, function()
		if not claimed and model.Parent then
			claimed = true
			remotes.ServerAnnouncement:FireAllClients("\u{1F31F} The Golden Critter vanished into the mist...")
			remotes.WorldEventEnded:FireAllClients("GoldenCritter")
			model:Destroy()
		end
	end)
end

local EVENTS = {
	-- ===== World-flavoured events =====
	-- The seven events below this block are global and fire regardless of where anyone
	-- is standing, which means a player in Volcano gets the same "Golden Rain over the
	-- island" as someone in the Meadow -- content they can't even see.
	--
	-- These three are scoped to a specific world's zone. They reuse the SAME event
	-- machinery (title/subtitle/start/stop) rather than a parallel system, so they
	-- rotate in alongside the global ones with no scheduler changes.
	--
	-- `requiresWorld` is checked by the scheduler: the event is skipped unless at least
	-- one player is actually in that zone, so nobody gets an announcement for something
	-- happening somewhere they aren't.
	{
		id = "ForestBloom",
		requiresWorld = "Forest",
		title = "\u{1F338} FOREST BLOOM!",
		subtitle = "Forest Sprites appear twice as often!",
		start = function()
			setGlobalEventAttribute("SAC_EventForestBloom", true)
		end,
		stop = function()
			setGlobalEventAttribute("SAC_EventForestBloom", false)
		end,
	},
	{
		id = "VolcanicFury",
		requiresWorld = "Volcano",
		title = "\u{1F30B} VOLCANIC FURY!",
		subtitle = "Meteor showers intensify -- and pay double!",
		start = function()
			setGlobalEventAttribute("SAC_EventVolcanicFury", true)
		end,
		stop = function()
			setGlobalEventAttribute("SAC_EventVolcanicFury", false)
		end,
	},
	{
		id = "SkyTempest",
		requiresWorld = "SkyIslands",
		title = "\u{1F32A}\u{FE0F} SKY TEMPEST!",
		subtitle = "Updrafts everywhere -- Wind Crystals worth triple!",
		start = function()
			setGlobalEventAttribute("SAC_EventSkyTempest", true)
		end,
		stop = function()
			setGlobalEventAttribute("SAC_EventSkyTempest", false)
		end,
	},

	-- Per-world events for the four remaining worlds with a unique mechanic. Each
	-- amplifies THAT WORLD'S mechanic rather than granting generic Sparks -- a global
	-- "+2x income" event gives a player no reason to be in Beach specifically, which is
	-- the whole point of a per-world event.
	{
		id = "KingTide",
		requiresWorld = "Beach",
		title = "\u{1F30A} KING TIDE!",
		subtitle = "Crabs swarm the shore -- and carry twice the treasure!",
		start = function()
			setGlobalEventAttribute("SAC_EventKingTide", true)
		end,
		stop = function()
			setGlobalEventAttribute("SAC_EventKingTide", false)
		end,
	},
	{
		id = "MirageHour",
		requiresWorld = "Desert",
		title = "\u{1F3DC}\u{FE0F} MIRAGE HOUR!",
		subtitle = "Sandstorms roll in fast -- survive them for double rewards!",
		start = function()
			setGlobalEventAttribute("SAC_EventMirageHour", true)
		end,
		stop = function()
			setGlobalEventAttribute("SAC_EventMirageHour", false)
		end,
	},
	{
		id = "Whiteout",
		requiresWorld = "Snow",
		title = "\u{2744}\u{FE0F} WHITEOUT!",
		subtitle = "The ice turns slick -- and every orb is worth double!",
		start = function()
			setGlobalEventAttribute("SAC_EventWhiteout", true)
		end,
		stop = function()
			setGlobalEventAttribute("SAC_EventWhiteout", false)
		end,
	},
	{
		id = "GeodeRush",
		requiresWorld = "CrystalCaves",
		title = "\u{1F48E} GEODE RUSH!",
		subtitle = "Crystals grow in half the time and burst with more shards!",
		start = function()
			setGlobalEventAttribute("SAC_EventGeodeRush", true)
		end,
		stop = function()
			setGlobalEventAttribute("SAC_EventGeodeRush", false)
		end,
	},
	{
		id = "DoubleSparks",
		title = "\u{26A1} DOUBLE SPARKS!",
		subtitle = "All Critters earn 2x Sparks!",
		start = function()
			setGlobalEventAttribute("SAC_EventDoubleSparks", true)
		end,
		stop = function()
			setGlobalEventAttribute("SAC_EventDoubleSparks", false)
		end,
	},
	{
		id = "GoldenRain",
		title = "\u{1F4B0} GOLDEN RAIN!",
		subtitle = "Grab the falling gold before it disappears!",
		start = function(eventState)
			eventState.dropFolder = Instance.new("Folder")
			eventState.dropFolder.Name = "GoldenRainDrops"
			eventState.dropFolder.Parent = workspace
			eventState.running = true

			task.spawn(function()
				while eventState.running do
					-- Spawn a droplet at a random point over the island
					local angle = math.random() * math.pi * 2
					local r = math.random() * 100
					local drop = Instance.new("Part")
					drop.Name = "GoldDrop"
					drop.Shape = Enum.PartType.Ball
					drop.Size = Vector3.new(2, 2, 2)
					drop.Position = Vector3.new(math.cos(angle) * r, 60, math.sin(angle) * r)
					drop.Material = Enum.Material.Neon
					drop.Color = Color3.fromRGB(255, 210, 60)
					drop.CanCollide = false
					drop.Anchored = false
					drop.Parent = eventState.dropFolder

					local sparkle = Instance.new("ParticleEmitter")
					sparkle.Texture = "rbxasset://textures/particles/sparkles_main.dds"
					sparkle.Color = ColorSequence.new(Color3.fromRGB(255, 220, 100))
					sparkle.Rate = 6
					sparkle.Lifetime = NumberRange.new(0.4, 0.8)
					sparkle.Speed = NumberRange.new(0.5, 1)
					sparkle.LightEmission = 1
					sparkle.Parent = drop

					local collected = false
					drop.Touched:Connect(function(hit)
						if collected then return end
						local char = hit:FindFirstAncestorOfClass("Model")
						local player = char and Players:GetPlayerFromCharacter(char)
						if not player then return end
						collected = true
						local newTotal = PlayerDataService.AddSparks(player, 25)
						remotes.SparksUpdated:FireClient(player, newTotal)
						QuestService.ReportProgress(player, "sparks", 25)
						drop:Destroy()
					end)

					-- Clean up drops that hit the ground uncollected
					task.delay(12, function()
						if drop.Parent then drop:Destroy() end
					end)

					task.wait(0.7)
				end
			end)
		end,
		stop = function(eventState)
			eventState.running = false
			if eventState.dropFolder then
				eventState.dropFolder:Destroy()
				eventState.dropFolder = nil
			end
		end,
	},
	{
		id = "LuckyHour",
		title = "\u{1F340} LUCKY HOUR!",
		subtitle = "3x Shiny odds on every hatch!",
		start = function()
			setGlobalEventAttribute("SAC_EventShinyMultiplier", 3)
		end,
		stop = function()
			setGlobalEventAttribute("SAC_EventShinyMultiplier", 1)
		end,
	},
	{
		id = "DoubleXP",
		title = "\u{2728} DOUBLE XP!",
		subtitle = "Earn 2x XP from every action!",
		start = function()
			setGlobalEventAttribute("SAC_EventXPMultiplier", 2)
		end,
		stop = function()
			setGlobalEventAttribute("SAC_EventXPMultiplier", 1)
		end,
	},
	{
		id = "HalfPriceHatch",
		title = "\u{1F947} HALF-PRICE HATCHING!",
		subtitle = "Every egg costs 50% less!",
		start = function()
			setGlobalEventAttribute("SAC_EventHatchCostMultiplier", 0.5)
		end,
		stop = function()
			setGlobalEventAttribute("SAC_EventHatchCostMultiplier", 1)
		end,
	},
	{
		-- "Double hatch" from the Rare Events list -- every hatch during this window grants
		-- a second, freshly-rolled Critter of the same tier at no extra cost. Same simple
		-- attribute-flag pattern as HalfPriceHatch/DoubleSparks; the actual second-spawn
		-- logic lives in HatchLogic.PerformHatch, which checks this flag directly.
		id = "DoubleHatch",
		title = "\u{1F95A} DOUBLE HATCH!",
		subtitle = "Every egg hatches TWO Critters!",
		start = function()
			setGlobalEventAttribute("SAC_EventDoubleHatch", true)
		end,
		stop = function()
			setGlobalEventAttribute("SAC_EventDoubleHatch", false)
		end,
	},
	{
		-- Deliberately reuses GoldenRain's exact physics-drop-and-Touch pattern, adapted
		-- to be rare/heavy instead of frequent/light -- a genuinely different feel
		-- ("a few big wins" vs "a constant light shower") from the same proven mechanism,
		-- rather than a second copy of the same event under a new name.
		id = "TreasureRain",
		title = "\u{1F48E} TREASURE RAIN!",
		subtitle = "Rare treasure chests worth big Sparks!",
		start = function(eventState)
			eventState.dropFolder = Instance.new("Folder")
			eventState.dropFolder.Name = "TreasureRainDrops"
			eventState.dropFolder.Parent = workspace
			eventState.running = true

			task.spawn(function()
				while eventState.running do
					local angle = math.random() * math.pi * 2
					local r = math.random() * 95
					local chest = Instance.new("Part")
					chest.Name = "TreasureChest"
					chest.Size = Vector3.new(3, 2.4, 2.2)
					chest.Position = Vector3.new(math.cos(angle) * r, 60, math.sin(angle) * r)
					chest.Material = Enum.Material.Wood
					chest.Color = Color3.fromRGB(140, 95, 55)
					chest.CanCollide = false
					chest.Anchored = false
					chest.Parent = eventState.dropFolder

					local lid = Instance.new("Part")
					lid.Name = "Lid"
					lid.Size = Vector3.new(3.1, 0.6, 2.3)
					lid.Material = Enum.Material.Neon
					lid.Color = Color3.fromRGB(255, 210, 70)
					lid.CanCollide = false
					lid.Anchored = false
					lid.CFrame = chest.CFrame * CFrame.new(0, 1.3, 0)
					lid.Parent = eventState.dropFolder
					local weld = Instance.new("WeldConstraint")
					weld.Part0 = chest
					weld.Part1 = lid
					weld.Parent = chest

					local sparkle = Instance.new("ParticleEmitter")
					sparkle.Texture = "rbxasset://textures/particles/sparkles_main.dds"
					sparkle.Color = ColorSequence.new(Color3.fromRGB(255, 220, 110))
					sparkle.Rate = 10
					sparkle.Lifetime = NumberRange.new(0.5, 0.9)
					sparkle.Speed = NumberRange.new(0.5, 1.2)
					sparkle.LightEmission = 1
					sparkle.Parent = chest

					local collected = false
					chest.Touched:Connect(function(hit)
						if collected then return end
						local char = hit:FindFirstAncestorOfClass("Model")
						local player = char and Players:GetPlayerFromCharacter(char)
						if not player then return end
						collected = true
						local reward = math.random(150, 300)
						local newTotal = PlayerDataService.AddSparks(player, reward)
						remotes.SparksUpdated:FireClient(player, newTotal)
						QuestService.ReportProgress(player, "sparks", reward)
						remotes.OrbCollected:FireAllClients(reward, chest.Position)
						chest:Destroy()
						lid:Destroy()
					end)

					task.delay(14, function()
						if chest.Parent then chest:Destroy() end
						if lid.Parent then lid:Destroy() end
					end)

					task.wait(4.5) -- rare: a handful over the event, not a constant shower
				end
			end)
		end,
		stop = function(eventState)
			eventState.running = false
			if eventState.dropFolder then
				eventState.dropFolder:Destroy()
				eventState.dropFolder = nil
			end
		end,
	},
}

function WorldEventService.Init()
	task.spawn(function()
		while true do
			task.wait(EVENT_INTERVAL)

			-- Rare Golden Critter roll, checked BEFORE the regular event pool -- roughly a
			-- 1-in-8 chance per cycle (averages out to about once an hour at the real
			-- 6-minute interval), genuinely rarer than every other event so it keeps its
			-- "wow, right now?" quality instead of blending into the regular rotation.
			if math.random(1, 8) == 1 then
				local ok, err = pcall(runGoldenCritterSighting)
				if not ok then warn("[WorldEventService] Golden Critter sighting failed:", err) end
				continue
			end

			-- Pick from events that are actually RELEVANT right now. A world-scoped
			-- event fires only if someone is standing in that world -- otherwise the
			-- server announces "Volcanic Fury!" to a lobby of people in the Meadow who
			-- can neither see nor benefit from it.
			local eligible = {}
			for _, e in ipairs(EVENTS) do
				if not e.requiresWorld then
					eligible[#eligible + 1] = e
				else
					local world = WorldsData.GetWorld(e.requiresWorld)
					if world and world.zonePosition then
						for _, player in ipairs(Players:GetPlayers()) do
							local hrp = player.Character
								and player.Character:FindFirstChild("HumanoidRootPart")
							if hrp and (hrp.Position - world.zonePosition).Magnitude <= 120 then
								eligible[#eligible + 1] = e
								break
							end
						end
					end
				end
			end
			if #eligible == 0 then continue end

			local event = eligible[math.random(1, #eligible)]
			local eventState = {}

			remotes.ServerAnnouncement:FireAllClients(event.title .. " " .. event.subtitle)
			remotes.WorldEventStarted:FireAllClients(event.id, event.title, EVENT_DURATION)

			local ok, err = pcall(event.start, eventState)
			if not ok then warn("[WorldEventService] event start failed:", err) end

			task.wait(EVENT_DURATION)

			ok, err = pcall(event.stop, eventState)
			if not ok then warn("[WorldEventService] event stop failed:", err) end

			remotes.WorldEventEnded:FireAllClients(event.id)
		end
	end)
end

return WorldEventService

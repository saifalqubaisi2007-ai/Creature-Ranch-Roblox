--[[
	WorldService.lua
	Owns per-player world-unlock state and sequential gate validation for CREATURE
	RANCH's multi-world progression system. Deliberately generic -- contains zero
	hardcoded world names or content; every decision routes through WorldsData.
]]

local RS = game:GetService("ReplicatedStorage")
local WorldsData = require(RS.CritterRush.Modules.WorldsData)
local Constants = require(RS.CritterRush.Modules.Constants)
local PlayerDataService = require(script.Parent.PlayerDataService)
local AnalyticsService = require(script.Parent.AnalyticsService)
local BadgeAwardService = require(script.Parent.BadgeAwardService)

local remotes = RS.CritterRush.Remotes

local WorldService = {}

local function newPart(name, size, color, material, cf)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material
	p.CFrame = cf
	p.Anchored = true
	p.Parent = nil -- caller sets Parent
	return p
end

function WorldService.IsUnlocked(player, worldId)
	local profile = PlayerDataService.Get(player)
	if not profile then return false end
	if worldId == WorldsData.DEFAULT_WORLD_ID then return true end -- always unlocked
	return profile.unlockedWorlds and profile.unlockedWorlds[worldId] == true
end

-- Returns the highest-order world this player currently has unlocked (used to find
-- "what's the next one to unlock" without the caller needing to iterate itself).
function WorldService.GetHighestUnlockedWorld(player)
	local highest = WorldsData.GetWorld(WorldsData.DEFAULT_WORLD_ID)
	for _, world in ipairs(WorldsData.GetAllWorlds()) do
		if WorldService.IsUnlocked(player, world.id) and world.order > highest.order then
			highest = world
		end
	end
	return highest
end

-- Attempts to unlock worldId for player. Enforces SEQUENTIAL gating (can't skip World 3
-- to unlock World 4 -- matches the "polish each world before the next" design intent
-- at the data level, not just in how content gets built), a REBIRTH requirement (the
-- core fix for "rebirth is just another number" -- past Beach, no amount of Sparks
-- alone unlocks the next world; you must have actually rebirthed), and the Sparks cost.
-- Returns (true) on success, (false, reason) on failure -- reason is one of
-- "AlreadyUnlocked", "NotImplemented", "MustUnlockPreviousFirst", "InsufficientRebirths",
-- "InsufficientSparks", "UnknownWorld".
function WorldService.TryUnlockWorld(player, worldId)
	local world = WorldsData.GetWorld(worldId)
	if not world then return false, "UnknownWorld" end
	if not world.implemented then return false, "NotImplemented" end
	if WorldService.IsUnlocked(player, worldId) then return false, "AlreadyUnlocked" end

	-- Sequential gate: every world except the previous-in-order must already be unlocked.
	local allWorlds = WorldsData.GetAllWorlds()
	for _, other in ipairs(allWorlds) do
		if other.order == world.order - 1 and not WorldService.IsUnlocked(player, other.id) then
			return false, "MustUnlockPreviousFirst"
		end
	end

	-- Rebirth gate: checked BEFORE spending Sparks, so a player missing both rebirths
	-- AND Sparks sees the more fundamental blocker first, not "you're just a bit short"
	-- when they're actually nowhere close.
	local requiredRebirths = world.requiredRebirths or 0
	if requiredRebirths > 0 then
		local profile = PlayerDataService.Get(player)
		if not profile or profile.rebirths < requiredRebirths then
			return false, "InsufficientRebirths"
		end
	end

	-- Collection gate: must have actually COLLECTED from the previous world, not just
	-- banked enough Sparks while ignoring it. Checked before spending, alongside the
	-- rebirth gate, so the player sees the real blocker rather than a Sparks message.
	local requiredPrev = world.requiredPrevSpecies or 0
	if requiredPrev > 0 then
		local prevWorld
		for _, other in ipairs(allWorlds) do
			if other.order == world.order - 1 then prevWorld = other end
		end
		if prevWorld and prevWorld.species then
			local profile = PlayerDataService.Get(player)
			local owned = 0
			if profile then
				for _, list in pairs(prevWorld.species) do
					for _, sp in ipairs(list) do
						if profile.collection[sp] == "owned" then owned += 1 end
					end
				end
			end
			if owned < requiredPrev then
				return false, "InsufficientCollection", owned, requiredPrev, prevWorld.displayName
			end
		end
	end

	if not PlayerDataService.TrySpendSparks(player, world.unlockCost) then
		return false, "InsufficientSparks"
	end

	local profile = PlayerDataService.Get(player)
	profile.unlockedWorlds = profile.unlockedWorlds or {}
	profile.unlockedWorlds[worldId] = true

	AnalyticsService.LogWorldUnlock(player, world.unlockCost, profile.sparks, worldId)
	AnalyticsService.LogWorldUnlockProgression(player, world.order, world.displayName)
	AnalyticsService.LogFirstWorldUnlock(player)
	BadgeAwardService.CheckAll(player, PlayerDataService.Get(player))

	remotes.SparksUpdated:FireClient(player, profile.sparks)
	local worldUnlockedRemote = remotes:FindFirstChild("WorldUnlocked")
	if worldUnlockedRemote then
		worldUnlockedRemote:FireClient(player, worldId, world.displayName)
	end
	remotes.ServerAnnouncement:FireAllClients(
		string.format("\u{1F30D} %s UNLOCKED %s!", player.DisplayName:upper(), world.displayName:upper()))

	return true
end

-- Builds a physical archway + ProximityPrompt for ANY world that defines a
-- gatePosition -- deliberately generic (reads only from WorldsData), so a future
-- world just needs its own gatePosition/zonePosition added to unlock this automatically,
-- no logic changes here.
local function buildGate(world, gatesFolder)
	local pos = world.gatePosition
	local group = Instance.new("Model")
	group.Name = "Gate_" .. world.id

	local pillarColor = Color3.fromRGB(140, 130, 120)
	local leftPillar = newPart("LeftPillar", Vector3.new(3, 14, 3), pillarColor, Enum.Material.Rock,
		CFrame.new(pos + Vector3.new(-8, 0, 0)))
	leftPillar.Parent = group
	local rightPillar = newPart("RightPillar", Vector3.new(3, 14, 3), pillarColor, Enum.Material.Rock,
		CFrame.new(pos + Vector3.new(8, 0, 0)))
	rightPillar.Parent = group
	local beam = newPart("Beam", Vector3.new(19, 3, 3), pillarColor, Enum.Material.Rock,
		CFrame.new(pos + Vector3.new(0, 8, 0)))
	beam.Parent = group

	-- Floating world name above the arch
	local nameGui = Instance.new("BillboardGui")
	nameGui.Size = UDim2.new(0, 260, 0, 60)
	nameGui.StudsOffset = Vector3.new(0, 4, 0)
	nameGui.AlwaysOnTop = true
	nameGui.Parent = beam
	local nameLabel = Instance.new("TextLabel")
	nameLabel.BackgroundTransparency = 1
	nameLabel.Size = UDim2.new(1, 0, 1, 0)
	nameLabel.Text = "\u{1F332} " .. world.displayName:upper()
	nameLabel.TextColor3 = Color3.new(1, 1, 1)
	nameLabel.TextStrokeTransparency = 0.2
	nameLabel.Font = Enum.Font.FredokaOne
	nameLabel.TextScaled = true
	nameLabel.Parent = nameGui

	local prompt = Instance.new("ProximityPrompt")
	-- Static text set once, matching HatcheryController's proven-working pattern
	-- exactly (that one never uses PromptShown at all) -- found via live comparison
	-- that PromptShown-driven dynamic per-player text was never firing in this
	-- environment, while the structurally-identical-otherwise Hatchery prompts
	-- (static text, Triggered only) work correctly. Generic wording that reads fine
	-- either way -- the real unlock-vs-enter branch still happens correctly inside
	-- Triggered below regardless of what the label says beforehand.
	prompt.ActionText = "Enter " .. world.displayName
	-- Mentions the rebirth requirement in the static label itself when one exists, so a
	-- player sees the real requirement before ever triggering the prompt, not just
	-- after being denied.
	if world.requiredRebirths and world.requiredRebirths > 0 then
		prompt.ObjectText = string.format("Unlock: %d Sparks + %d Rebirth%s",
			world.unlockCost, world.requiredRebirths, world.requiredRebirths == 1 and "" or "s")
	else
		prompt.ObjectText = string.format("Unlock: %d Sparks", world.unlockCost)
	end
	prompt.MaxActivationDistance = 12
	prompt.HoldDuration = 0.3
	prompt.RequiresLineOfSight = false
	prompt.Parent = leftPillar

	prompt.Triggered:Connect(function(player)
		if WorldService.IsUnlocked(player, world.id) then
			local char = player.Character
			if not char then return end
			char:PivotTo(CFrame.new(world.zonePosition + Vector3.new(0, 8, 15), world.zonePosition))
		else
			-- Extra returns carry the collection-gate detail (owned, required, worldName)
			-- so the denial message can state actual progress rather than a vague refusal.
			local ok, reason, extraA, extraB, extraC = WorldService.TryUnlockWorld(player, world.id)
			if not ok then
				local remote = remotes:FindFirstChild("WorldGateDenied")
				-- Pre-formatted, ready-to-display text -- same "server computes, client just
				-- renders" discipline as ElderDialogue, rather than making the client
				-- reconstruct a message from raw reason codes. This remote object existed
				-- since the gate was first built, but genuinely had no client listener
				-- wired to it until now -- every denial before this was firing into the
				-- void with zero player-visible feedback.
				if remote then
					if reason == "InsufficientSparks" then
						-- FormatNumber, not %d: unlock costs run to billions and a raw
						-- digit string is unreadable at that scale.
						remote:FireClient(player, string.format(
							"Not enough Sparks -- %s costs %s.", world.displayName,
							Constants.FormatNumber(world.unlockCost)))
					elseif reason == "InsufficientCollection" then
						remote:FireClient(player, string.format(
							"Collect %d/%d %s species first!", extraA or 0, extraB or 0,
							tostring(extraC)))
					elseif reason == "InsufficientRebirths" then
						remote:FireClient(player, string.format(
							"%s requires %d Rebirth%s first.", world.displayName, world.requiredRebirths,
							world.requiredRebirths == 1 and "" or "s"))
					elseif reason == "MustUnlockPreviousFirst" then
						remote:FireClient(player, "Unlock the previous world first.")
					end
				end
			end
		end
	end)

	group.Parent = gatesFolder
end

function WorldService.Init()
	local gatesFolder = workspace:FindFirstChild("WorldGates")
	if gatesFolder then gatesFolder:Destroy() end
	gatesFolder = Instance.new("Folder")
	gatesFolder.Name = "WorldGates"
	gatesFolder.Parent = workspace

	for _, world in ipairs(WorldsData.GetAllWorlds()) do
		if world.gatePosition and world.implemented then
			buildGate(world, gatesFolder)
		end
	end
end

return WorldService

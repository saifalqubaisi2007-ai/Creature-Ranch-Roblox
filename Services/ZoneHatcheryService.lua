--[[
	ZoneHatcheryService.lua
	Builds a physical Hatchery -- egg stands, one per purchasable rarity -- at every
	implemented world's zonePosition, EXCEPT Starter Meadow (which already has its own
	dedicated, hand-placed Hatchery via HatcheryController). Reuses that exact same
	visual design (pedestal, glowing egg, billboard, single-prompt-per-stand) rather
	than inventing a new look, so every world's Hatchery reads as the same landmark type.

	Deliberately a SEPARATE module from WorldService, not an addition to it: HatchLogic
	already requires WorldService (for the unlock check), so WorldService requiring
	HatchLogic back would create a circular require and likely return a broken partial
	module. This module sits one layer above both instead.
]]

local RS = game:GetService("ReplicatedStorage")
local WorldsData = require(RS.CritterRush.Modules.WorldsData)
local Constants = require(RS.CritterRush.Modules.Constants)
local HatchLogic = require(script.Parent.HatchLogic)

local ZoneHatcheryService = {}

local function buildStand(standsFolder, position, labelText, subText, eggColor, promptAction, promptObject, onTriggered)
	local stand = Instance.new("Model")
	stand.Parent = standsFolder

	local pedestal = Instance.new("Part")
	pedestal.Name = "Pedestal"
	pedestal.Shape = Enum.PartType.Cylinder
	pedestal.Size = Vector3.new(3, 4.5, 4.5)
	pedestal.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	pedestal.Anchored = true
	pedestal.Material = Enum.Material.Marble
	pedestal.Color = Color3.fromRGB(240, 232, 215)
	pedestal.Parent = stand

	local egg = Instance.new("Part")
	egg.Name = "Egg"
	egg.Shape = Enum.PartType.Ball
	egg.Size = Vector3.new(2.6, 3.3, 2.6)
	egg.CFrame = CFrame.new(position + Vector3.new(0, 3.2, 0))
	egg.Anchored = true
	egg.CanCollide = false
	egg.Material = Enum.Material.SmoothPlastic
	egg.Color = eggColor
	egg.Parent = stand

	local glow = Instance.new("PointLight")
	glow.Color = eggColor
	glow.Range = 8
	glow.Brightness = 1.2
	glow.Parent = egg

	local tag = Instance.new("BillboardGui")
	tag.Size = UDim2.new(0, 150, 0, 56)
	tag.StudsOffset = Vector3.new(0, 3, 0)
	tag.AlwaysOnTop = false
	tag.Parent = egg

	local nameLabel = Instance.new("TextLabel")
	nameLabel.BackgroundTransparency = 1
	nameLabel.Size = UDim2.new(1, 0, 0.55, 0)
	nameLabel.Text = labelText
	nameLabel.TextColor3 = eggColor
	nameLabel.Font = Enum.Font.FredokaOne
	nameLabel.TextScaled = true
	nameLabel.TextStrokeTransparency = 0.3
	nameLabel.Parent = tag

	local priceLabel = Instance.new("TextLabel")
	priceLabel.BackgroundTransparency = 1
	priceLabel.Size = UDim2.new(1, 0, 0.45, 0)
	priceLabel.Position = UDim2.new(0, 0, 0.55, 0)
	priceLabel.Text = subText
	priceLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	priceLabel.Font = Enum.Font.GothamMedium
	priceLabel.TextScaled = true
	priceLabel.TextStrokeTransparency = 0.3
	priceLabel.Parent = tag

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = promptAction
	prompt.ObjectText = promptObject
	prompt.HoldDuration = 0.25
	prompt.MaxActivationDistance = 7
	prompt.RequiresLineOfSight = false
	prompt.Parent = egg
	prompt.Triggered:Connect(onTriggered)

	return stand
end

-- The ground platform beneath everything else at this zone -- without this, the
-- gate's teleport destination and every stand built here are floating in empty void
-- space with nothing for a player to stand on. Found this the hard way: built the
-- Hatchery stands first, teleported to check them, and fell straight through into the
-- void because no ground had ever actually been built at either zone position.
local function buildZoneGround(world, parentFolder)
	local ground = Instance.new("Part")
	ground.Name = "Ground_" .. world.id
	ground.Shape = Enum.PartType.Cylinder
	ground.Size = Vector3.new(4, 140, 140)
	ground.Color = world.groundColor or Color3.fromRGB(120, 190, 90)
	ground.Material = world.groundMaterial or Enum.Material.Grass
	ground.CFrame = CFrame.new(world.zonePosition) * CFrame.Angles(0, 0, math.rad(90))
	ground.Anchored = true
	ground.Parent = parentFolder
end

local function buildZoneHatchery(world, parentFolder)
	local standsFolder = Instance.new("Folder")
	standsFolder.Name = "Hatchery_" .. world.id
	standsFolder.Parent = parentFolder

	-- ONE themed egg per world, matching the main Hatchery. Replaces the old
	-- five-rarity-eggs layout so every world reads as a distinct, memorable pull.
	local themed = world.themedEgg
	if not themed then
		warn("[ZoneHatcheryService] no themedEgg for world " .. tostring(world.id))
		return
	end

	local pos = world.zonePosition + Vector3.new(0, 3, -8)
	local stand = buildStand(
		standsFolder, pos,
		themed.name,
		Constants.FormatNumber(themed.cost) .. " \u{2728}",
		Color3.fromRGB(255, 215, 120),
		"Hatch",
		themed.name,
		function(player)
			HatchLogic.PerformThemedHatch(player, world.id)
		end
	)

	local egg = stand and stand:FindFirstChild("Egg")
	if egg then
		local tag = egg:FindFirstChildOfClass("BillboardGui")
		if tag then
			tag.Size = UDim2.new(0, 190, 0, 132)
			for _, lbl in ipairs(tag:GetChildren()) do
				if lbl:IsA("TextLabel") then
					lbl.Size = UDim2.new(1, 0, 0.17, 0)
					lbl.Position = UDim2.new(0, 0, lbl.Position.Y.Scale * 0.34, 0)
				end
			end
			local totalWeight = 0
			for _, t in ipairs(world.rarities) do totalWeight += (t.weight or 0) end
			local y = 0.34
			for _, t in ipairs(world.rarities) do
				local row = Instance.new("TextLabel")
				row.Name = "Odds_" .. t.id
				row.BackgroundTransparency = 1
				row.Size = UDim2.new(1, 0, 0.132, 0)
				row.Position = UDim2.new(0, 0, y, 0)
				row.Text = string.format("%s  %.1f%%", t.id, (t.weight / totalWeight) * 100)
				row.TextColor3 = t.auraColor
				row.Font = Enum.Font.GothamMedium
				row.TextScaled = true
				row.TextStrokeTransparency = 0.4
				row.Parent = tag
				y = y + 0.132
			end
			local shinyRow = Instance.new("TextLabel")
			shinyRow.Name = "ShinyOddsLabel"
			shinyRow.BackgroundTransparency = 1
			shinyRow.Size = UDim2.new(1, 0, 0.132, 0)
			shinyRow.Position = UDim2.new(0, 0, y, 0)
			shinyRow.Text = string.format("\u{2728} Shiny: %.1f%%", Constants.SHINY_CHANCE * 100)
			shinyRow.TextColor3 = Color3.fromRGB(255, 220, 120)
			shinyRow.Font = Enum.Font.GothamMedium
			shinyRow.TextScaled = true
			shinyRow.TextStrokeTransparency = 0.4
			shinyRow.Parent = tag
		end

		local keys = { [3] = Enum.KeyCode.F, [8] = Enum.KeyCode.G, [25] = Enum.KeyCode.H }
		for _, count in ipairs(Constants.MULTI_HATCH_TIERS) do
			if count > 1 then
				local p = Instance.new("ProximityPrompt")
				p.Name = "MultiHatch_x" .. count
				p.ActionText = "Hatch x" .. count
				p.ObjectText = string.format("%s (%s \u{2728})", themed.name,
					Constants.FormatNumber(themed.cost * count))
				p.KeyboardKeyCode = keys[count] or Enum.KeyCode.F
				p.HoldDuration = 0.25
				p.MaxActivationDistance = 7
				p.RequiresLineOfSight = false
				p.Parent = egg
				p.Triggered:Connect(function(player)
					for _ = 1, count do
						HatchLogic.PerformThemedHatch(player, world.id)
					end
				end)
			end
		end
	end
end

function ZoneHatcheryService.Init()
	local zoneHatcheriesFolder = workspace:FindFirstChild("ZoneHatcheries")
	if zoneHatcheriesFolder then zoneHatcheriesFolder:Destroy() end
	zoneHatcheriesFolder = Instance.new("Folder")
	zoneHatcheriesFolder.Name = "ZoneHatcheries"
	zoneHatcheriesFolder.Parent = workspace

	for _, world in ipairs(WorldsData.WORLDS) do
		-- Every implemented world EXCEPT Starter Meadow, which has its own physical
		-- Hatchery landmark built by HatcheryController.
		if world.implemented and world.zonePosition and world.id ~= WorldsData.DEFAULT_WORLD_ID then
			buildZoneGround(world, zoneHatcheriesFolder)
			buildZoneHatchery(world, zoneHatcheriesFolder)
		end
	end
end

return ZoneHatcheryService

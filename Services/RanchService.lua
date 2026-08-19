--[[
	RanchService.lua
	Builds and grows each player's private Ranch plot as they level up. Reaching a new
	RanchData tier ADDS decorations on top of whatever's already there -- a tier-up
	should never look like something was taken away.
]]

local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local RanchData = require(RS.CritterRush.Modules.RanchData)
local Constants = require(RS.CritterRush.Modules.Constants)

local RanchService = {}

local function newPart(name, shape, size, color, material, cf, opts)
	opts = opts or {}
	local p = Instance.new("Part")
	p.Name = name
	if shape then p.Shape = shape end
	p.Size = size
	p.Color = color
	p.Material = material
	p.CFrame = cf
	p.Anchored = true
	p.CanCollide = opts.collide ~= false
	if opts.transparency then p.Transparency = opts.transparency end
	return p
end

local plotsFolder
local function getPlotFolder(player)
	local name = "Plot_" .. player.UserId
	local existing = plotsFolder:FindFirstChild(name)
	if existing then return existing end
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = plotsFolder
	return f
end

-- ===== Tier 1: Homestead -- the baseline every player starts with =====
local function buildTier1(plotFolder, plotPos)
	local group = Instance.new("Model")
	group.Name = "Tier1_Homestead"

	-- Circular grass platform: the plot's ground, since plots sit in the void far from
	-- the main island's terrain
	newPart("Ground", Enum.PartType.Cylinder, Vector3.new(4, 110, 110), Color3.fromRGB(120, 190, 90),
		Enum.Material.Grass, CFrame.new(plotPos) * CFrame.Angles(0, 0, math.rad(90))).Parent = group

	-- A dirt patch near center -- "tiny fence, dirt" per spec, gives the starting plot
	-- a lived-in, not-just-a-green-disc feel
	newPart("DirtPatch", Enum.PartType.Cylinder, Vector3.new(0.3, 18, 18), Color3.fromRGB(115, 90, 60),
		Enum.Material.Ground, CFrame.new(plotPos + Vector3.new(0, 2.15, 0)) * CFrame.Angles(0, 0, math.rad(90))).Parent = group

	-- Small wooden fence ring around the plot's edge
	local fenceRadius = 27
	local postCount = 16
	for i = 0, postCount - 1 do
		local angle = (i / postCount) * math.pi * 2
		local pos = plotPos + Vector3.new(math.cos(angle) * fenceRadius, 3, math.sin(angle) * fenceRadius)
		newPart("FencePost", nil, Vector3.new(0.8, 3.5, 0.8), Color3.fromRGB(150, 105, 65), Enum.Material.Wood,
			CFrame.new(pos)).Parent = group
		-- Connecting rail to the next post. CFrame.new(mid, nextPos) points the part's LOOK
		-- axis (local -Z) at the next post, but the rail's LENGTH is on X (Size.X = dist) --
		-- a 90-degree mismatch that rendered every rail tilted/wrong rather than lying flat
		-- between its two posts. The extra Angles(0, 90, 0) rotates local X onto the look
		-- direction instead, fixing it.
		local nextAngle = ((i + 1) / postCount) * math.pi * 2
		local nextPos = plotPos + Vector3.new(math.cos(nextAngle) * fenceRadius, 3.3, math.sin(nextAngle) * fenceRadius)
		local mid = (pos + nextPos) / 2
		local dist = (nextPos - pos).Magnitude
		newPart("FenceRail", nil, Vector3.new(dist, 0.4, 0.15), Color3.fromRGB(170, 125, 80), Enum.Material.Wood,
			CFrame.new(mid, nextPos) * CFrame.Angles(0, math.rad(90), 0)).Parent = group
	end

	-- A small welcome sign, personal-touch detail
	newPart("SignPost", Enum.PartType.Cylinder, Vector3.new(3.5, 0.3, 0.3), Color3.fromRGB(130, 90, 55), Enum.Material.Wood,
		CFrame.new(plotPos + Vector3.new(-20, 4, -20)) * CFrame.Angles(0, 0, math.rad(90))).Parent = group
	newPart("SignBoard", nil, Vector3.new(4, 2, 0.3), Color3.fromRGB(160, 120, 75), Enum.Material.WoodPlanks,
		CFrame.new(plotPos + Vector3.new(-20, 5.5, -20))).Parent = group

	group.Parent = plotFolder
end

-- ===== Tier 2: Growing Ranch -- flowers, stone path, small pond =====
local function buildTier2(plotFolder, plotPos)
	local group = Instance.new("Model")
	group.Name = "Tier2_GrowingRanch"

	-- Small pond, offset from center so it doesn't collide with the tier-1 dirt patch
	local pondCenter = plotPos + Vector3.new(15, 0, 12)
	newPart("Pond", Enum.PartType.Cylinder, Vector3.new(0.6, 12, 12), Color3.fromRGB(110, 195, 225), Enum.Material.Glass,
		CFrame.new(pondCenter + Vector3.new(0, 2.4, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		{ collide = false, transparency = 0.3 }).Parent = group
	newPart("PondRim", Enum.PartType.Cylinder, Vector3.new(0.5, 13, 13), Color3.fromRGB(160, 150, 130), Enum.Material.Slate,
		CFrame.new(pondCenter + Vector3.new(0, 2.1, 0)) * CFrame.Angles(0, 0, math.rad(90))).Parent = group

	-- Stone path from the fence entrance toward the pond
	local pathStart = plotPos + Vector3.new(-27, 2.3, 0)
	local pathEnd = pondCenter
	local steps = 10
	for i = 0, steps do
		local alpha = i / steps
		local pos = pathStart:Lerp(pathEnd, alpha)
		newPart("PathStone", nil, Vector3.new(2.6, 0.3, 2.2), Color3.fromRGB(150, 148, 145), Enum.Material.Slate,
			CFrame.new(pos) * CFrame.Angles(0, math.random() * 0.3, 0)).Parent = group
	end

	-- Flower patches scattered near the fence line
	local flowerColors = { Color3.fromRGB(255, 120, 150), Color3.fromRGB(255, 210, 90), Color3.fromRGB(180, 130, 255) }
	for i = 1, 10 do
		local angle = math.random() * math.pi * 2
		local r = 20 + math.random() * 5
		local pos = plotPos + Vector3.new(math.cos(angle) * r, 2.4, math.sin(angle) * r)
		newPart("Flower" .. i, Enum.PartType.Ball, Vector3.new(0.8, 0.8, 0.8), flowerColors[math.random(1, #flowerColors)],
			Enum.Material.Neon, CFrame.new(pos), { collide = false }).Parent = group
	end

	group.Parent = plotFolder
end

-- ===== Tier 3: Blooming Ranch -- elevates Tier 2's small pond into a proper
-- centerpiece (fountain rock, small bridge) plus denser flower beds. Built as an
-- ADDITION near the existing pond rather than a separate structure -- the fenced plot
-- has limited space, and this tier is explicitly about the pond "growing up", not
-- competing with it.
local function buildTier3(plotFolder, plotPos)
	local group = Instance.new("Model")
	group.Name = "Tier3_BloomingRanch"

	local pondCenter = plotPos + Vector3.new(15, 0, 12)

	-- Fountain rock centerpiece, rising from the middle of the existing pond
	newPart("FountainRock", Enum.PartType.Cylinder, Vector3.new(4, 3.5, 3.5), Color3.fromRGB(150, 145, 135),
		Enum.Material.Rock, CFrame.new(pondCenter + Vector3.new(0, 4, 0)) * CFrame.Angles(0, 0, math.rad(90))).Parent = group
	newPart("FountainTop", Enum.PartType.Ball, Vector3.new(2, 1.6, 2), Color3.fromRGB(160, 155, 145), Enum.Material.Rock,
		CFrame.new(pondCenter + Vector3.new(0, 6.2, 0))).Parent = group
	local fountainWater = Instance.new("ParticleEmitter")
	fountainWater.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	fountainWater.Color = ColorSequence.new(Color3.fromRGB(150, 210, 235))
	fountainWater.Lifetime = NumberRange.new(0.6, 1)
	fountainWater.Speed = NumberRange.new(3, 5)
	fountainWater.SpreadAngle = Vector2.new(25, 25)
	fountainWater.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0) })
	fountainWater.Rate = 12
	local fountainSource = newPart("FountainSource", nil, Vector3.new(0.5, 0.5, 0.5), Color3.new(1, 1, 1),
		Enum.Material.Neon, CFrame.new(pondCenter + Vector3.new(0, 7, 0)), { collide = false, transparency = 1 })
	fountainSource.Parent = group
	fountainWater.Parent = fountainSource

	-- Small wooden bridge crossing the edge of the pond
	local bridgeStart = pondCenter + Vector3.new(-13, 2.3, 0)
	local bridgeEnd = pondCenter + Vector3.new(-6, 2.3, 0)
	local bridgeMid = (bridgeStart + bridgeEnd) / 2
	newPart("BridgePlank", nil, Vector3.new((bridgeEnd - bridgeStart).Magnitude, 0.4, 3.2),
		Color3.fromRGB(150, 110, 70), Enum.Material.Wood, CFrame.new(bridgeMid, bridgeEnd)).Parent = group
	for _, sign in ipairs({ -1, 1 }) do
		newPart("BridgeRail", nil, Vector3.new((bridgeEnd - bridgeStart).Magnitude, 1.2, 0.2),
			Color3.fromRGB(160, 120, 75), Enum.Material.Wood,
			CFrame.new(bridgeMid, bridgeEnd) * CFrame.new(0, 0.9, sign * 1.5)).Parent = group
	end

	-- Denser, more varied flower beds around the fence line -- upgrading Tier 2's sparse
	-- scattering into proper blooming beds
	local flowerColors = {
		Color3.fromRGB(255, 120, 150), Color3.fromRGB(255, 210, 90), Color3.fromRGB(180, 130, 255),
		Color3.fromRGB(255, 160, 200), Color3.fromRGB(140, 200, 255),
	}
	for i = 1, 18 do
		local angle = math.random() * math.pi * 2
		local r = 21 + math.random() * 4
		local pos = plotPos + Vector3.new(math.cos(angle) * r, 2.4, math.sin(angle) * r)
		newPart("BloomFlower" .. i, Enum.PartType.Ball, Vector3.new(0.9, 0.9, 0.9),
			flowerColors[math.random(1, #flowerColors)], Enum.Material.Neon, CFrame.new(pos), { collide = false }).Parent = group
	end

	group.Parent = plotFolder
end

-- Registry of blade-assembly Models to spin every frame -- populated as each Tier 4
-- is built, rather than scanning plotsFolder's full descendant tree every Heartbeat,
-- which would get more expensive as more plots exist.
local spinningBlades = {}

-- Registry of gently-bobbing crystal shards (Tier 6) -- {part, baseCFrame, phase}.
-- Shares the SAME Heartbeat connection as spinningBlades (see Init()) rather than a
-- second one, since both are cheap per-entry updates.
local floatingCrystals = {}

-- ===== Tier 4: Windmill Ranch -- a real, continuously-rotating windmill (RunService
-- Heartbeat, not just a static prop) plus a small wheat field for flavor =====
local function buildTier4(plotFolder, plotPos)
	local group = Instance.new("Model")
	group.Name = "Tier4_WindmillRanch"

	local millPos = plotPos + Vector3.new(-15, 0, -8)
	local stoneColor = Color3.fromRGB(150, 140, 125)

	-- Tapered stone tower
	newPart("MillTowerBase", Enum.PartType.Cylinder, Vector3.new(10, 7, 7), stoneColor, Enum.Material.Concrete,
		CFrame.new(millPos + Vector3.new(0, 5, 0)) * CFrame.Angles(0, 0, math.rad(90))).Parent = group
	newPart("MillTowerTop", Enum.PartType.Cylinder, Vector3.new(6, 4.5, 4.5), stoneColor, Enum.Material.Concrete,
		CFrame.new(millPos + Vector3.new(0, 13, 0)) * CFrame.Angles(0, 0, math.rad(90))).Parent = group
	-- Conical cap
	newPart("MillCap", Enum.PartType.Cylinder, Vector3.new(3, 5, 5), Color3.fromRGB(120, 70, 55), Enum.Material.Wood,
		CFrame.new(millPos + Vector3.new(0, 17.5, 0)) * CFrame.Angles(0, 0, math.rad(90))).Parent = group

	-- Blade assembly: a small Model so all 4 blades rotate together via PivotTo each
	-- frame (parts alone have no hierarchical transform, only Models do)
	local blades = Instance.new("Model")
	blades.Name = "WindmillBlades"
	local hubPos = millPos + Vector3.new(0, 16, 4.2)
	local hub = newPart("Hub", Enum.PartType.Cylinder, Vector3.new(1.2, 2, 2), Color3.fromRGB(90, 65, 50),
		Enum.Material.Wood, CFrame.new(hubPos) * CFrame.Angles(0, math.rad(90), 0))
	hub.Parent = blades
	blades.PrimaryPart = hub
	local bladeColor = Color3.fromRGB(225, 220, 205)
	for i = 0, 3 do
		local angle = math.rad(i * 90)
		local bladeCF = CFrame.new(hubPos) * CFrame.Angles(0, math.rad(90), 0) * CFrame.Angles(0, 0, angle) * CFrame.new(0, 6, 0)
		newPart("Blade", nil, Vector3.new(1.6, 11, 0.3), bladeColor, Enum.Material.Wood, bladeCF).Parent = blades
	end
	blades.Parent = group
	table.insert(spinningBlades, blades)

	-- Small millhouse base at the tower's foot
	newPart("MillDoor", nil, Vector3.new(2.5, 4, 0.3), Color3.fromRGB(90, 60, 45), Enum.Material.Wood,
		CFrame.new(millPos + Vector3.new(0, 2, 3.4))).Parent = group

	-- Small wheat field patch nearby -- thin golden stalks, quick but adds flavor
	for i = 1, 24 do
		local ox = (math.random() - 0.5) * 10
		local oz = (math.random() - 0.5) * 6
		local pos = millPos + Vector3.new(ox, 0, oz + 9)
		newPart("WheatStalk", Enum.PartType.Cylinder, Vector3.new(2.2, 0.15, 0.15), Color3.fromRGB(215, 190, 90),
			Enum.Material.Grass, CFrame.new(pos + Vector3.new(0, 1.1, 0)) * CFrame.Angles(0, 0, math.rad(90) + (math.random() - 0.5) * 0.3),
			{ collide = false }).Parent = group
	end

	group.Parent = plotFolder
end

-- ===== Tier 5: Flourishing Ranch -- a small rocky waterfall cascading into a splash
-- pool, reusing the same tiered-rock-formation technique proven on the main island's
-- Waterfall landmark, scaled down to fit a personal plot =====
local function buildTier5(plotFolder, plotPos)
	local group = Instance.new("Model")
	group.Name = "Tier5_FlourishingRanch"

	local fallPos = plotPos + Vector3.new(18, 0, -14)
	local rockColor = Color3.fromRGB(120, 115, 105)

	-- Tiered rock cliff face, each tier slightly narrower going up (same silhouette
	-- logic as the main island's waterfall)
	local cliffTiers = { { y = 0, h = 6, w = 11 }, { y = 5, h = 6, w = 9 }, { y = 10, h = 5, w = 7 } }
	for _, t in ipairs(cliffTiers) do
		newPart("CliffRock", nil, Vector3.new(t.w, t.h, 6), rockColor, Enum.Material.Rock,
			CFrame.new(fallPos + Vector3.new(0, t.y + t.h / 2, 0))).Parent = group
	end

	-- Cascading water sheet down the cliff face
	local waterSheet = newPart("WaterSheet", nil, Vector3.new(4, 15, 0.6), Color3.fromRGB(140, 205, 230),
		Enum.Material.Glass, CFrame.new(fallPos + Vector3.new(0, 7.5, 3.2)), { collide = false, transparency = 0.2 })
	waterSheet.Parent = group

	-- Falling mist/spray particles at the base for a sense of motion and impact
	local mistSource = newPart("MistSource", nil, Vector3.new(4, 0.5, 2), Color3.new(1, 1, 1), Enum.Material.Neon,
		CFrame.new(fallPos + Vector3.new(0, 0.5, 4)), { collide = false, transparency = 1 })
	mistSource.Parent = group
	local mist = Instance.new("ParticleEmitter")
	mist.Texture = "rbxasset://textures/particles/smoke_main.dds"
	mist.Color = ColorSequence.new(Color3.fromRGB(220, 240, 250))
	mist.Lifetime = NumberRange.new(0.8, 1.4)
	mist.Speed = NumberRange.new(1, 2)
	mist.SpreadAngle = Vector2.new(40, 15)
	mist.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2), NumberSequenceKeypoint.new(1, 4) })
	mist.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1) })
	mist.Rate = 8
	mist.Parent = mistSource

	-- Splash pool at the base, same pond technique used elsewhere on the plot
	local poolCenter = fallPos + Vector3.new(0, 0, 8)
	newPart("SplashPool", Enum.PartType.Cylinder, Vector3.new(0.5, 9, 9), Color3.fromRGB(130, 200, 225),
		Enum.Material.Glass, CFrame.new(poolCenter + Vector3.new(0, 0.5, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		{ collide = false, transparency = 0.25 }).Parent = group
	newPart("SplashPoolRim", Enum.PartType.Cylinder, Vector3.new(0.4, 9.6, 9.6), Color3.fromRGB(150, 145, 135),
		Enum.Material.Rock, CFrame.new(poolCenter + Vector3.new(0, 0.2, 0)) * CFrame.Angles(0, 0, math.rad(90))).Parent = group

	group.Parent = plotFolder
end

-- ===== Tier 6: Crystal Ranch -- a cluster of large glowing crystal formations plus a
-- few smaller shards that gently bob in place =====
local function buildTier6(plotFolder, plotPos)
	local group = Instance.new("Model")
	group.Name = "Tier6_CrystalRanch"

	local clusterCenter = plotPos + Vector3.new(-8, 0, 22)
	local crystalColors = {
		Color3.fromRGB(140, 100, 255), Color3.fromRGB(90, 220, 255),
		Color3.fromRGB(255, 120, 220), Color3.fromRGB(150, 255, 200),
	}

	-- Rocky base the crystals emerge from
	newPart("CrystalBase", Enum.PartType.Cylinder, Vector3.new(2, 9, 9), Color3.fromRGB(95, 90, 100),
		Enum.Material.Slate, CFrame.new(clusterCenter + Vector3.new(0, 1, 0)) * CFrame.Angles(0, 0, math.rad(90))).Parent = group

	-- Large glowing crystal spires, varied heights/angles for an organic cluster
	local largeCrystals = {
		{ offset = Vector3.new(0, 0, 0), height = 12, tilt = 0, colorIdx = 1 },
		{ offset = Vector3.new(-3, 0, 2), height = 8, tilt = 12, colorIdx = 2 },
		{ offset = Vector3.new(3, 0, -1), height = 9, tilt = -10, colorIdx = 3 },
		{ offset = Vector3.new(-2, 0, -3), height = 6, tilt = 15, colorIdx = 4 },
		{ offset = Vector3.new(2.5, 0, 3), height = 7, tilt = -8, colorIdx = 2 },
	}
	for i, c in ipairs(largeCrystals) do
		local pos = clusterCenter + c.offset + Vector3.new(0, 2 + c.height / 2, 0)
		local crystal = newPart("CrystalSpire", nil, Vector3.new(1.8, c.height, 1.8), crystalColors[c.colorIdx],
			Enum.Material.Neon, CFrame.new(pos) * CFrame.Angles(math.rad(c.tilt), math.rad(i * 40), 0), { collide = false })
		crystal.Parent = group
		local light = Instance.new("PointLight")
		light.Color = crystalColors[c.colorIdx]
		light.Brightness = 1.5
		light.Range = 12
		light.Parent = crystal
	end

	-- A few smaller shards that gently bob in place -- registered for the shared
	-- Heartbeat loop in Init()
	for i = 1, 4 do
		local angle = (i / 4) * math.pi * 2
		local pos = clusterCenter + Vector3.new(math.cos(angle) * 6, 4, math.sin(angle) * 6)
		local shard = newPart("FloatingShard", nil, Vector3.new(1, 2, 1), crystalColors[(i % #crystalColors) + 1],
			Enum.Material.Neon, CFrame.new(pos) * CFrame.Angles(0, math.rad(i * 30), math.rad(20)), { collide = false })
		shard.Parent = group
		table.insert(floatingCrystals, { part = shard, baseCFrame = shard.CFrame, phase = i * 1.3 })
	end

	group.Parent = plotFolder
end

-- ===== Tier 7: Mythic Ranch -- the capstone tier. A scaled-down echo of the Ancient
-- Tree itself (same tapered-trunk/layered-canopy/glow-leaf technique), but in a
-- distinct jewel-toned palette (deep purple/magenta/gold rather than the Ancient
-- Tree's natural green) so it reads as its own "final reward" rather than a copy-paste,
-- while still being recognizably part of the same visual family. Reduced footprint to
-- fit the one remaining open pocket in an increasingly crowded plot -- height carries
-- the "this is the capstone" weight instead of ground area.
local function buildTier7(plotFolder, plotPos)
	local group = Instance.new("Model")
	group.Name = "Tier7_MythicRanch"

	local treeBase = plotPos + Vector3.new(3, 2, -20)
	local trunkColor = Color3.fromRGB(70, 50, 75)

	local trunkSegments = {
		{ y = 0, height = 12, radius = 4.5 },
		{ y = 11, height = 10, radius = 3.2 },
		{ y = 20, height = 9, radius = 2.2 },
	}
	for _, seg in ipairs(trunkSegments) do
		newPart("MythicTrunk", Enum.PartType.Cylinder, Vector3.new(seg.height, seg.radius * 2, seg.radius * 2), trunkColor,
			Enum.Material.Wood, CFrame.new(treeBase + Vector3.new(0, seg.y + seg.height / 2, 0)) * CFrame.Angles(0, 0, math.rad(90))).Parent = group
	end

	-- Root flares, same technique as the Ancient Tree, scaled down
	for i = 1, 6 do
		local angle = (i / 6) * math.pi * 2 + 0.3
		local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local rootPos = treeBase + dir * 3.5 + Vector3.new(0, 1.5, 0)
		newPart("MythicRoot", Enum.PartType.Cylinder, Vector3.new(6, 1.8, 1.8), trunkColor, Enum.Material.Wood,
			CFrame.new(rootPos, rootPos + dir) * CFrame.Angles(0, math.rad(90), 0)).Parent = group
	end

	-- Jewel-toned layered canopy
	local canopyY = treeBase.Y + 26
	local canopyColors = {
		Color3.fromRGB(120, 60, 150),   -- deep purple undertone
		Color3.fromRGB(180, 80, 190),   -- magenta
		Color3.fromRGB(230, 180, 90),   -- gold accent
		Color3.fromRGB(90, 190, 220),   -- cyan highlight, ties back to Tier 6's crystals
	}
	local canopyClusters = {
		{ offset = Vector3.new(0, 3, 0), size = 16, colorIdx = 1 },
		{ offset = Vector3.new(-6, 1, -4), size = 11, colorIdx = 2 },
		{ offset = Vector3.new(6.5, 2, -2), size = 12, colorIdx = 2 },
		{ offset = Vector3.new(-3, 6, 4), size = 9, colorIdx = 3 },
		{ offset = Vector3.new(4, 7, 3), size = 10, colorIdx = 4 },
	}
	for _, c in ipairs(canopyClusters) do
		newPart("MythicCanopy", Enum.PartType.Ball, Vector3.new(c.size, c.size, c.size), canopyColors[c.colorIdx],
			Enum.Material.Neon, CFrame.new(treeBase + Vector3.new(0, canopyY, 0) + c.offset), { collide = false }).Parent = group
	end

	-- Ring of small floating light orbs around the canopy -- the capstone-tier flourish
	-- that distinguishes this from every earlier tier
	for i = 1, 6 do
		local angle = (i / 6) * math.pi * 2
		local orbPos = treeBase + Vector3.new(math.cos(angle) * 12, canopyY, math.sin(angle) * 12)
		local orb = newPart("MythicOrb", Enum.PartType.Ball, Vector3.new(1.3, 1.3, 1.3),
			canopyColors[(i % #canopyColors) + 1], Enum.Material.Neon, CFrame.new(orbPos), { collide = false })
		orb.Parent = group
		local orbLight = Instance.new("PointLight")
		orbLight.Color = orb.Color
		orbLight.Brightness = 1.5
		orbLight.Range = 10
		orbLight.Parent = orb
		table.insert(floatingCrystals, { part = orb, baseCFrame = orb.CFrame, phase = i * 0.9 })
	end

	-- Ambient glow + motes, same technique as the Ancient Tree
	local moteSource = newPart("MythicMoteSource", nil, Vector3.new(1, 1, 1), Color3.new(1, 1, 1), Enum.Material.Neon,
		CFrame.new(treeBase + Vector3.new(0, canopyY, 0)), { collide = false, transparency = 1 })
	moteSource.Parent = group
	local motes = Instance.new("ParticleEmitter")
	motes.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	motes.Color = ColorSequence.new(Color3.fromRGB(220, 160, 255))
	motes.Lifetime = NumberRange.new(3, 5)
	motes.Speed = NumberRange.new(0.5, 1.5)
	motes.SpreadAngle = Vector2.new(180, 180)
	motes.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 0) })
	motes.Rate = 8
	motes.LightEmission = 1
	motes.Parent = moteSource
	local canopyGlow = Instance.new("PointLight")
	canopyGlow.Color = Color3.fromRGB(210, 160, 255)
	canopyGlow.Brightness = 2
	canopyGlow.Range = 40
	canopyGlow.Parent = moteSource

	group.Parent = plotFolder
end

local TIER_BUILDERS = {
	[1] = buildTier1,
	[2] = buildTier2,
	[3] = buildTier3,
	[4] = buildTier4,
	[5] = buildTier5,
	[6] = buildTier6,
	[7] = buildTier7,
}

-- Idempotent: only builds a tier's decorations if they don't already exist for this plot.
function RanchService.EnsureTier(player, tierOrder)
	local builder = TIER_BUILDERS[tierOrder]
	if not builder then return end
	local plotFolder = getPlotFolder(player)
	local tierName = RanchData.TIERS[tierOrder] and ("Tier" .. tierOrder .. "_" .. RanchData.TIERS[tierOrder].name:gsub(" ", ""))
	if not tierName or plotFolder:FindFirstChild(tierName) then return end
	local plotPos = RanchData.GetPlotPosition(player.UserId)
	builder(plotFolder, plotPos)
end

-- Builds every tier up to and including the player's current level-derived tier. Called
-- on join (catches up a returning player instantly, no need to re-watch old tier-ups)
-- and on live level-up (adds exactly the new tier, since lower ones are already there).
function RanchService.SyncPlotToLevel(player, level)
	local tier = RanchData.GetTierForLevel(level)
	for order = 1, tier.order do
		RanchService.EnsureTier(player, order)
	end
	return tier
end

-- ===== Player-placed decorations =====
-- Slots ring the plot edge at a fixed radius, so decorations frame the ranch rather than
-- crowding the centre where the player and their critters actually stand.
-- Pushed 22 -> 44 to match the widened 110-stud ground. At 22 the decorations sat
-- clustered in the middle of a much larger disc with the sanctuary creatures, rather
-- than framing the plot edge as intended.
local DECO_RADIUS = 44

local function decoSlotCFrame(plotPos, slot)
	local angle = ((slot - 1) / Constants.RANCH_DECORATION_SLOTS) * math.pi * 2
	local pos = plotPos + Vector3.new(math.cos(angle) * DECO_RADIUS, 2, math.sin(angle) * DECO_RADIUS)
	-- Face inward toward the plot centre.
	return CFrame.new(pos, Vector3.new(plotPos.X, pos.Y, plotPos.Z))
end

local function buildDecoration(kind, cf)
	local model = Instance.new("Model")
	model.Name = "Deco_" .. kind

	if kind == "flowers" then
		local bed = newPart("Bed", nil, Vector3.new(5, 0.6, 3), Color3.fromRGB(110, 80, 60),
			Enum.Material.Ground, cf)
		bed.Parent = model
		for i = 1, 7 do
			local hue = (i / 7)
			local f = newPart("Flower", Enum.PartType.Ball, Vector3.new(0.7, 0.7, 0.7),
				Color3.fromHSV(hue, 0.8, 1), Enum.Material.SmoothPlastic,
				cf * CFrame.new(-2 + (i - 1) * 0.7, 0.5, math.sin(i) * 0.6), { collide = false })
			f.Parent = model
		end

	elseif kind == "lamp" then
		local post = newPart("Post", Enum.PartType.Cylinder, Vector3.new(7, 0.5, 0.5),
			Color3.fromRGB(60, 55, 70), Enum.Material.Metal,
			cf * CFrame.new(0, 3.5, 0) * CFrame.Angles(0, 0, math.rad(90)))
		post.Parent = model
		local bulb = newPart("Bulb", Enum.PartType.Ball, Vector3.new(1.6, 1.6, 1.6),
			Color3.fromRGB(255, 240, 180), Enum.Material.Neon, cf * CFrame.new(0, 7.2, 0),
			{ collide = false })
		bulb.Parent = model
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 235, 170)
		light.Range = 18
		light.Brightness = 2
		light.Parent = bulb

	elseif kind == "fountain" then
		local basin = newPart("Basin", Enum.PartType.Cylinder, Vector3.new(1.6, 8, 8),
			Color3.fromRGB(170, 165, 180), Enum.Material.Slate,
			cf * CFrame.new(0, 0.8, 0) * CFrame.Angles(0, 0, math.rad(90)))
		basin.Parent = model
		local water = newPart("Water", Enum.PartType.Cylinder, Vector3.new(0.4, 7, 7),
			Color3.fromRGB(110, 190, 235), Enum.Material.Glass,
			cf * CFrame.new(0, 1.5, 0) * CFrame.Angles(0, 0, math.rad(90)), { collide = false, transparency = 0.35 })
		water.Parent = model
		local spout = newPart("Spout", Enum.PartType.Cylinder, Vector3.new(3, 1, 1),
			Color3.fromRGB(170, 165, 180), Enum.Material.Slate,
			cf * CFrame.new(0, 3, 0) * CFrame.Angles(0, 0, math.rad(90)))
		spout.Parent = model

	elseif kind == "statue" then
		local base = newPart("Base", nil, Vector3.new(4, 1.5, 4), Color3.fromRGB(150, 145, 160),
			Enum.Material.Slate, cf * CFrame.new(0, 0.75, 0))
		base.Parent = model
		local body = newPart("Body", Enum.PartType.Ball, Vector3.new(3.4, 3.2, 3.4),
			Color3.fromRGB(200, 195, 210), Enum.Material.Marble, cf * CFrame.new(0, 3.2, 0),
			{ collide = false })
		body.Parent = model
		for _, side in ipairs({-1, 1}) do
			local ear = newPart("Ear", Enum.PartType.Ball, Vector3.new(1.1, 1.7, 0.8),
				Color3.fromRGB(190, 185, 200), Enum.Material.Marble,
				cf * CFrame.new(side * 1, 4.9, 0), { collide = false })
			ear.Parent = model
		end

	elseif kind == "topiary" then
		local trunk = newPart("Trunk", Enum.PartType.Cylinder, Vector3.new(3, 1, 1),
			Color3.fromRGB(110, 80, 55), Enum.Material.Wood,
			cf * CFrame.new(0, 1.5, 0) * CFrame.Angles(0, 0, math.rad(90)))
		trunk.Parent = model
		for i = 1, 3 do
			local ball = newPart("Hedge", Enum.PartType.Ball, Vector3.new(4 - i * 0.7, 4 - i * 0.7, 4 - i * 0.7),
				Color3.fromRGB(70, 140, 70), Enum.Material.Grass,
				cf * CFrame.new(0, 3 + (i - 1) * 2.2, 0), { collide = false })
			ball.Parent = model
		end

	elseif kind == "crystaltree" then
		local trunk = newPart("Trunk", Enum.PartType.Cylinder, Vector3.new(6, 1.2, 1.2),
			Color3.fromRGB(90, 70, 110), Enum.Material.Slate,
			cf * CFrame.new(0, 3, 0) * CFrame.Angles(0, 0, math.rad(90)))
		trunk.Parent = model
		for i = 1, 6 do
			local angle = (i / 6) * math.pi * 2
			local shard = newPart("Shard", nil, Vector3.new(1, 3.2, 1),
				Color3.fromHSV((i / 6), 0.7, 1), Enum.Material.Neon,
				cf * CFrame.new(math.cos(angle) * 1.8, 6.5, math.sin(angle) * 1.8)
					* CFrame.Angles(math.rad(20), 0, math.rad(math.cos(angle) * 25)),
				{ collide = false })
			shard.Parent = model
		end
		local glow = Instance.new("PointLight")
		glow.Color = Color3.fromRGB(180, 150, 255)
		glow.Range = 20
		glow.Brightness = 2
		glow.Parent = trunk

	elseif kind == "archway" then
		for _, side in ipairs({-3.5, 3.5}) do
			local pillar = newPart("Pillar", Enum.PartType.Cylinder, Vector3.new(9, 1.4, 1.4),
				Color3.fromRGB(240, 200, 90), Enum.Material.Metal,
				cf * CFrame.new(side, 4.5, 0) * CFrame.Angles(0, 0, math.rad(90)))
			pillar.Parent = model
		end
		local top = newPart("Arch", nil, Vector3.new(9, 1.2, 1.4), Color3.fromRGB(255, 215, 110),
			Enum.Material.Metal, cf * CFrame.new(0, 9.5, 0))
		top.Parent = model

	elseif kind == "obelisk" then
		local base = newPart("Base", nil, Vector3.new(5, 1.2, 5), Color3.fromRGB(50, 45, 65),
			Enum.Material.Slate, cf * CFrame.new(0, 0.6, 0))
		base.Parent = model
		local shaft = newPart("Shaft", nil, Vector3.new(2.6, 14, 2.6), Color3.fromRGB(70, 60, 95),
			Enum.Material.Slate, cf * CFrame.new(0, 8, 0))
		shaft.Parent = model
		local cap = newPart("Cap", nil, Vector3.new(1.6, 2.2, 1.6), Color3.fromRGB(255, 230, 130),
			Enum.Material.Neon, cf * CFrame.new(0, 16, 0), { collide = false })
		cap.Parent = model
		local glow = Instance.new("PointLight")
		glow.Color = Color3.fromRGB(255, 230, 150)
		glow.Range = 26
		glow.Brightness = 3
		glow.Parent = cap
	end

	return model
end

-- Rebuilds every owned decoration on a plot. Called after a purchase and on plot build,
-- so a rejoining player sees everything they own without any separate restore path.
function RanchService.SyncDecorations(player, owned)
	local plotFolder = getPlotFolder(player)
	local existing = plotFolder:FindFirstChild("Decorations")
	if existing then existing:Destroy() end
	if not owned or not next(owned) then return end

	local container = Instance.new("Folder")
	container.Name = "Decorations"
	container.Parent = plotFolder

	local plotPos = RanchData.GetPlotPosition(player.UserId)
	for _, entry in ipairs(Constants.RANCH_DECORATIONS) do
		local slot = owned[entry.id]
		if slot then
			local ok, model = pcall(buildDecoration, entry.kind, decoSlotCFrame(plotPos, slot))
			if ok and model then
				model.Parent = container
			elseif not ok then
				warn("[RanchService] decoration build failed for " .. entry.id .. ": " .. tostring(model))
			end
		end
	end
end

-- ===== Sanctuary creatures =====
-- Assigned creatures physically live on the plot and wander it. Rebuilt wholesale on
-- change rather than diffed: the assigned set is small (max 50) and rebuilding is far
-- less error-prone than tracking adds/removes against live models.
local sanctuaryFolders = {} -- [userId] = Folder

function RanchService.SyncSanctuaryCreatures(player)
	local PlayerDataService = require(script.Parent.PlayerDataService)
	local state = PlayerDataService.GetSanctuaryState(player)
	local plotPos = RanchService.GetPlotPosition(player)
	if not plotPos then return end

	local folder = sanctuaryFolders[player.UserId]
	if folder and folder.Parent then folder:Destroy() end
	folder = Instance.new("Folder")
	folder.Name = "Sanctuary_" .. player.UserId
	folder.Parent = workspace
	sanctuaryFolders[player.UserId] = folder

	local assetsFolder = RS.CritterRush.Assets:FindFirstChild("Critters")
	for i, entry in ipairs(state.assigned) do
		local template = assetsFolder and assetsFolder:FindFirstChild(entry.species)
		local model
		if template then
			model = template:Clone()
		else
			model = Instance.new("Model")
			local p = Instance.new("Part")
			p.Shape = Enum.PartType.Ball
			p.Size = Vector3.new(2, 2, 2)
			p.Anchored, p.CanCollide = true, false
			p.Parent = model
			model.PrimaryPart = p
		end
		-- Scale creatures DOWN when the sanctuary is crowded. A 60x60 plot cannot fit 50
		-- full-size creatures with clear gaps -- measured live, 37 at full size left the
		-- closest pair 4 studs apart with bodies 5-7 studs wide, and widening the rings
		-- just pushed them off the plot instead.
		--
		-- Shrinking is the honest fix: a ranch of many small creatures reads as a
		-- thriving sanctuary, whereas the same creatures clipping through each other
		-- reads as broken. Full size up to 12 housed, tapering to half size at 50.
		local crowd = #state.assigned
		local scale = 1.0
		if crowd > 30 then
			scale = math.max(0.75, 1.0 - (crowd - 30) / 80)
		end
		if model.PrimaryPart and scale < 1 then
			-- Scale SIZE and OFFSET together. Scaling size alone left every wing, crown
			-- and eye at its original distance from the body -- verified live, a body
			-- shrunk to 4.6 studs still had parts sitting 6.7 studs away, so the
			-- creature came apart. ScaleTo handles both correctly.
			local ok = pcall(function() model:ScaleTo(scale) end)
			if not ok then
				-- Fallback for models without a scale origin: move each part toward the
				-- PrimaryPart proportionally as it shrinks.
				local origin = model.PrimaryPart.Position
				for _, d in ipairs(model:GetDescendants()) do
					if d:IsA("BasePart") then
						local offset = d.Position - origin
						d.Size = d.Size * scale
						d.CFrame = CFrame.new(origin + offset * scale) * (d.CFrame - d.Position)
					end
				end
			end
		end
		model.Name = "Sanctuary_" .. entry.species
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then d.Anchored = true d.CanCollide = false end
		end

		-- Spread them across CONCENTRIC RINGS, not one circle. The original packed every
		-- creature onto 3 radii, so at 37 assigned the closest pair sat 1.3 studs apart
		-- with bodies 5-7 studs wide -- they clipped through each other in a heap.
		--
		-- Ring capacity scales with circumference, so density stays constant however many
		-- are housed: ring 1 holds 6, ring 2 holds 12, ring 3 holds 18, and so on.
		-- The plot Ground part is 60x60, so the usable half-width is 30 studs. Leaving a
		-- 4-stud margin gives a hard 26-stud ceiling: beyond that creatures stand on
		-- nothing -- verified live, a 45-stud spread left 13 of 37 floating over the void.
		local MAX_RADIUS = 46  -- ground is now 110 wide (55 radius); 9-stud margin
		local FIRST_RING = 8
		local RING_SPACING = 7

		-- How many rings fit inside MAX_RADIUS, and can they hold everyone? If not, rings
		-- are packed tighter rather than allowed to spill off the plot -- a slightly
		-- crowded ranch beats creatures floating in mid-air.
		local maxRings = math.max(1, math.floor((MAX_RADIUS - FIRST_RING) / RING_SPACING) + 1)
		local totalCapacity = 0
		for r = 1, maxRings do totalCapacity += r * 4 end
		local spacing = RING_SPACING
		if #state.assigned > totalCapacity then
			-- Compress: fit the needed rings into the same radius.
			local needed = 1
			local acc = 0
			while acc < #state.assigned do
				acc += needed * 4
				needed += 1
			end
			maxRings = needed
			-- Never compress below 7 studs: the closest pair ended up on ADJACENT RINGS
			-- (r=18 and r=22) rather than beside each other on one ring, so radial gap
			-- matters as much as angular. Overflow past the plot is handled by the
			-- radius clamp below instead of by squeezing rings together.
			spacing = math.max((MAX_RADIUS - FIRST_RING) / math.max(needed - 1, 1), 7)
		end

		local ring, indexInRing = 1, i - 1
		while ring < maxRings do
			local capacity = ring * 5
			if indexInRing < capacity then break end
			indexInRing -= capacity
			ring += 1
		end
		local radius = math.min(FIRST_RING + (ring - 1) * spacing, MAX_RADIUS)
		local perRing = ring * 5
		-- Offset alternate rings by half a step so creatures don't line up radially.
		local angle = ((indexInRing + (ring % 2) * 0.5) / perRing) * math.pi * 2
		local home = plotPos + Vector3.new(math.cos(angle) * radius, 3, math.sin(angle) * radius)
		if model.PrimaryPart then model:PivotTo(CFrame.new(home)) end
		model.Parent = folder

		-- Gentle wander around a fixed home point. Anchored + PivotTo rather than
		-- physics, so 50 creatures can't turn a ranch into a physics simulation.
		task.spawn(function()
			-- Phase is derived from the creature's ANGLE around the ring, not random. With
			-- random phases two neighbours 6 studs apart could each drift 1.5 studs toward
			-- the other and close to 3 -- back into overlap. Sharing a phase with your
			-- neighbour means the whole ring sways together and the gap never shrinks.
			local phase = angle
			-- Drift is TANGENTIAL (along the ring) rather than free XZ, so movement can
			-- never carry a creature toward the ring's centre or off its outer edge.
			local tangent = Vector3.new(-math.sin(angle), 0, math.cos(angle))
			-- Creatures FACE THE PLOT CENTRE rather than spinning. The old code applied a
			-- continuously increasing yaw, so every creature rotated forever like a
			-- display turntable -- mechanical rather than alive. Facing inward also means
			-- a visitor walking into the ranch is looked at, which reads as inhabited.
			-- Yaw that points AT the plot centre. The direction is (centre - position), and
			-- Roblox yaw for a look direction is atan2(X, Z) -- an earlier version negated
			-- the wrong side and left every creature facing exactly backwards, measured
			-- as a 3.34 rad (~pi) error.
			-- Roblox's LookVector points along -Z, so the yaw that faces a direction is
			-- atan2(dir.X, dir.Z) with the direction NEGATED. Measured both signs: the
			-- un-negated form gave a dot of exactly -1.00 (facing precisely backwards).
			local toCentre = (home - plotPos)
			local facing = math.atan2(toCentre.X, toCentre.Z)

			-- Bob and sway run at DIFFERENT rates, and each creature gets its own small
			-- speed variation. Previously every creature shared one timer, so the whole
			-- ranch pulsed in unison like a single animation rather than 37 individuals.
			local bobRate = 2.4 + (i % 5) * 0.22
			local swayRate = 0.30 + (i % 7) * 0.015
			local lookPhase = (i % 11) * 0.9

			while model.Parent do
				local now = os.clock()
				local sway = math.sin(now * swayRate + phase) * 1.2
				local bob = math.abs(math.sin(now * bobRate + phase)) * 0.45
				-- Occasional slow head-turn instead of constant spin: mostly still, with
				-- a gentle glance either side.
				local look = math.sin(now * 0.25 + lookPhase) * 0.5
				local offset = tangent * sway + Vector3.new(0, bob, 0)
				model:PivotTo(CFrame.new(home + offset) * CFrame.Angles(0, facing + look, 0))
				task.wait(0.1)
			end
		end)
	end
end

function RanchService.GetPlotPosition(player)
	return RanchData.GetPlotPosition(player.UserId)
end

function RanchService.Init()
	plotsFolder = workspace:FindFirstChild("RanchPlots")
	if plotsFolder then plotsFolder:Destroy() end
	plotsFolder = Instance.new("Folder")
	plotsFolder.Name = "RanchPlots"
	plotsFolder.Parent = workspace

	-- Spins every Tier 4 windmill's blades. A flat per-frame rotation rate (not
	-- framerate-scaled via dt) would drift inconsistent across clients/server load, so
	-- this uses dt properly -- same discipline as CritterService's idle-anim timing.
	-- Also bobs every Tier 6 floating crystal shard -- same connection, both are cheap
	-- per-entry updates, no reason to pay for a second Heartbeat subscription.
	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		for _, blades in ipairs(spinningBlades) do
			if blades.Parent then
				blades:PivotTo(blades:GetPivot() * CFrame.Angles(0, 0, dt * 1.2))
			end
		end
		for _, entry in ipairs(floatingCrystals) do
			if entry.part.Parent then
				local bobOffset = math.sin(elapsed * 1.5 + entry.phase) * 1.2
				entry.part.CFrame = entry.baseCFrame * CFrame.new(0, bobOffset, 0)
			end
		end
	end)
end

return RanchService

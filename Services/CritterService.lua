--[[
	CritterService.lua
	Server-authoritative Critter lifecycle: spawning, per-heartbeat following movement,
	passive Sparks income, and expressive idle animations. The steal/grab/hit/reclaim
	mechanic that used to live here was deliberately removed -- a Critter now always stays
	with its owner and always earns passively, no vulnerability window, no PvP.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")
local RS = game:GetService("ReplicatedStorage")

local Constants = require(RS.CritterRush.Modules.Constants)
local PlayerDataService = require(script.Parent.PlayerDataService)
local CritterVFX = require(script.Parent.CritterVFX)
local QuestService = require(script.Parent.QuestService)
local AnalyticsService = require(script.Parent.AnalyticsService)

local remotes = RS.CritterRush.Remotes

local CritterService = {}

-- live critter registry: [uid] = CritterRecord
-- CritterRecord = {
--   uid, ownerUserId, rarity, species, sparksPerSecond, state, model (Instance),
--   nextIdleAnimAt
-- }
-- VFX budgets. Kept well under Roblox's practical limits because these are PER
-- SERVER, not per player -- 20 players each with a few glowing critters adds up fast.
-- Live VFX counts. These are a coarse spawn-time guard; the real protection is the
-- distance-culling sweep below, which scales with collection size instead of
-- privileging whichever critters happened to spawn first.
local vfxLightCount, vfxParticleCount = 0, 0
local MAX_CRITTER_LIGHTS = 12
local MAX_CRITTER_PARTICLES = 40

local critters = {}

local function newUid()
	return HttpService:GenerateGUID(false)
end

local function weightedRandomRarity()
	local total = 0
	for _, tier in ipairs(Constants.RARITIES) do
		total += tier.weight
	end
	local roll = math.random() * total
	local acc = 0
	for _, tier in ipairs(Constants.RARITIES) do
		acc += tier.weight
		if roll <= acc then
			return tier
		end
	end
	return Constants.RARITIES[1]
end

local function findModelTemplate(rarityId, species)
	local assetsFolder = RS.CritterRush.Assets:FindFirstChild("Critters")
	if not assetsFolder then return nil end
	return assetsFolder:FindFirstChild(species)
end

-- Forward declarations (defined below; referenced by updateFollowing)
local getAnimBiasOffset

-- ===== Spawning =====

-- existingUid: pass a saved critter's uid to RESPAWN it (keeps identity, skips re-adding
-- to the player's profile). Omit for brand-new hatches.
-- forceShiny: pass true/false to force the shiny state on respawn (matches the saved
-- record); omit on a fresh hatch to let it roll naturally.
-- forcePersonality: pass a saved critter's personality id to preserve it on respawn --
-- personality is rolled ONCE at hatch and is permanent for that individual creature's
-- life, exactly like a name. Omit on a fresh hatch to roll a new one.
-- tier: the RESOLVED tier table (not just an id string) -- the caller looks this up
-- from the correct WORLD's rarity table via WorldsData.GetWorld(worldId).rarities,
-- since two different worlds can both have a tier literally named "Rare" with entirely
-- different stats. Passing the resolved table (instead of re-deriving it here from a
-- single global Constants.RARITIES, which is what this function used to do) is what
-- makes multi-world hatching unambiguous.
function CritterService.SpawnForPlayer(player, tier, species, worldId, existingUid, forceShiny, forcePersonality)
	if not tier then return nil end

	-- Guard: never double-spawn a critter that's already live (e.g. character respawn)
	if existingUid and critters[existingUid] then
		return critters[existingUid]
	end

	local uid = existingUid or newUid()
	-- NOTE: deliberately NOT the "a and b or c" idiom here — that pattern silently
	-- breaks when b (forceShiny) is `false`, since `true and false` collapses to
	-- false and falls through to the `or` branch regardless of intent. An explicit
	-- if/else is required to correctly distinguish "force non-shiny" from "roll it".
	local isShiny
	if forceShiny ~= nil then
		isShiny = forceShiny
	else
		-- Lucky Hour world event stacks as a straight chance multiplier via a workspace
		-- attribute, same decoupled-flag pattern as SAC_EventDoubleSparks -- clamped to 1
		-- so a very high multiplier can never exceed a guaranteed roll.
		local luckyMult = workspace:GetAttribute("SAC_EventShinyMultiplier") or 1
		-- Permanent Rebirth luck (item #6): stacks multiplicatively with the temporary
		-- Lucky Hour event above -- rebirthing genuinely makes every future hatch
		-- luckier, forever, not just during an event window.
		local rebirthCount = player:GetAttribute("SAC_RebirthCount") or 0
		local rebirthTier = Constants.GetRebirthTier(rebirthCount)
		local rebirthLuckMult = (rebirthTier and rebirthTier.luckBonus) or 1
		-- Shiny odds now route through the single central luck calculation, so the Luck
		-- pass, VIP, potions, rebirth luck and Lucky Hour all stack consistently -- and
		-- match exactly what the posted odds label shows.
		isShiny = math.random() < Constants.GetEffectiveShinyChance(
			player:GetAttribute("SAC_RebirthCount") or 0,
			workspace:GetAttribute("SAC_EventShinyMultiplier") or 1,
			{
				hasLuckPass = player:GetAttribute("SAC_LuckPass") == true,
				hasVip = player:GetAttribute("SAC_VIP") == true,
				potionMult = player:GetAttribute("SAC_LuckPotion"),
				collectionLuckBonus = player:GetAttribute("SAC_CollectionLuckBonus"),
		levelLuckBonus = player:GetAttribute("SAC_LevelLuckBonus"),
		ranchLuckBonus = player:GetAttribute("SAC_RanchLuckBonus"),
		relicLuckBonus = player:GetAttribute("SAC_RelicLuckBonus"),
			})
	end
	local incomeMult = isShiny and Constants.SHINY_INCOME_MULTIPLIER or 1
	-- Same explicit if/else as isShiny above, same reason: forcePersonality could in
	-- principle be any truthy string, so this isn't actually the a-and-b-or-c trap, but
	-- keeping the pattern consistent makes the intent obvious at a glance either way.
	local personality
	if forcePersonality then
		personality = forcePersonality
	else
		personality = Constants.PERSONALITY_IDS[math.random(1, #Constants.PERSONALITY_IDS)]
	end
	local record = {
		uid = uid,
		ownerUserId = player.UserId,
		rarity = tier.id,
		species = species,
		worldId = worldId,
		personality = personality,
		sparksPerSecond = tier.sparksPerSecond * incomeMult,
		isShiny = isShiny,
		state = Constants.CRITTER_STATE.FOLLOWING,
		model = nil,
		nextIdleAnimAt = os.clock() + math.random(Constants.IDLE_ANIM_INTERVAL_SECONDS.min, Constants.IDLE_ANIM_INTERVAL_SECONDS.max),
		nextTreasureCheckAt = os.clock() + math.random(
			Constants.TREASURE_FIND_CHECK_INTERVAL_SECONDS.min, Constants.TREASURE_FIND_CHECK_INTERVAL_SECONDS.max),
	}

	local template = findModelTemplate(tier.id, species)
	local model
	if template then
		model = template:Clone()
	else
		-- Fallback placeholder so the loop is testable before art is dropped in;
		-- flagged clearly so it's never mistaken for final art.
		model = Instance.new("Model")
		local part = Instance.new("Part")
		part.Name = "PLACEHOLDER_NeedsArt"
		part.Shape = Enum.PartType.Ball
		part.Size = Vector3.new(2, 2, 2) * tier.sizeScale
		part.Color = tier.auraColor
		part.Material = Enum.Material.Neon
		part.Anchored = true -- movement is driven manually via PivotTo, not physics
		part.CanCollide = false
		part.Parent = model
		model.PrimaryPart = part
	end

	model.Name = "Critter_" .. species .. "_" .. uid:sub(1, 8)
	model:SetAttribute("CritterUid", uid)
	model:SetAttribute("Rarity", tier.id)
	model:SetAttribute("IsShiny", isShiny)
	-- All critter movement is driven manually via PivotTo (there's only one state,
	-- Following), so every part must be anchored regardless of whether it's the
	-- placeholder or real art -- an unanchored part would fall under gravity and get
	-- destroyed by the engine's fallen-parts cleanup within seconds.
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
		end
	end
	-- ===== Rarity-scaled VFX =====
	-- Rarity previously affected ONLY model size, so a Mythic and a Common were the
	-- same object at different scales. These make tier readable at a glance from across
	-- the map, which is most of what makes a rare pull feel rare.
	--
	-- Deliberately tiered rather than applied to everything: a PointLight per Common
	-- would put dozens of dynamic lights on screen at once, and lights are the single
	-- most expensive thing to over-use here.
	do
		local rank = ({ Common = 1, Rare = 2, Epic = 3, Legendary = 4, Mythic = 5 })[tier.id] or 1
		local base = model.PrimaryPart

		-- GLOBAL BUDGET, not just per-rarity gating. Measured live: 83 owned critters
		-- produced 139 PointLights and 385 ParticleEmitters, and the client hit script
		-- timeouts. Roblox's practical ceiling is well under 20 dynamic lights, so tier
		-- alone is not a sufficient filter once a player owns a large collection.
		--
		-- The budget is checked at spawn time and counts what's ALREADY live, so the
		-- first few high-rarity critters get the full treatment and the rest fall back
		-- to cheaper effects rather than compounding.
		-- Budget is measured from the ACTUAL live critter models, not a maintained
		-- counter. Two bugs made the counter approach fail outright, both verified live:
		--   * critters reconstructed on join spawn outside this function, so they added
		--     lights the counter never saw -- counter said 12, reality was 47.
		--   * RemoveCritter decremented for those same uncounted critters, driving the
		--     counter to 0 and re-opening the budget forever -- particles read 0 while
		--     335 were live.
		-- Iterating `critters` (tens of entries) is far cheaper than the workspace scan
		-- I first replaced, and it cannot drift from reality by construction.
				-- Load is handled by CritterVFX.StartCulling (distance-based), not by refusing
		-- to create effects at spawn. A spawn-time cap decided the wrong thing: it kept
		-- effects on whichever critters happened to hatch FIRST, rather than on the ones
		-- the player can actually see.
		local lightBudgetLeft = true
		local liveParticles = 0

		if base then
			-- Epic+ get a glow, budget permitting.
			if rank >= 3 and lightBudgetLeft then
				local light = Instance.new("PointLight")
				light.Color = tier.auraColor or Color3.new(1, 1, 1)
				light.Range = 6 + rank * 2
				light.Brightness = 0.8 + rank * 0.35
				light.Shadows = false -- shadow-casting lights are far costlier
				light.Parent = base
				vfxLightCount += 1
			end

			-- Legendary+ get orbiting sparkles.
			-- Legendary+ sparkles, also budgeted -- particles are cheaper than lights
			-- but 385 emitters is still enough to stall a client.
			if rank >= 4 and liveParticles < MAX_CRITTER_PARTICLES then
				local sparkle = Instance.new("ParticleEmitter")
				sparkle.Texture = "rbxasset://textures/particles/sparkles_main.dds"
				sparkle.Color = ColorSequence.new(tier.auraColor or Color3.new(1, 1, 1))
				sparkle.Rate = rank * 3
				sparkle.Lifetime = NumberRange.new(0.6, 1.1)
				sparkle.Speed = NumberRange.new(0.5, 1.5)
				sparkle.Size = NumberSequence.new(0.35)
				sparkle.LightEmission = 1
				sparkle.Parent = base
				vfxParticleCount += 1
			end

			-- Mythic gets a ground beam so it's visible before you reach it.
			if rank >= 5 then
				local beam = Instance.new("Part")
				beam.Name = "MythicBeam"
				beam.Size = Vector3.new(2.2, 40, 2.2)
				beam.Color = tier.auraColor or Color3.new(1, 1, 1)
				beam.Material = Enum.Material.Neon
				beam.Transparency = 0.82
				beam.CanCollide = false
				beam.Anchored = true
				beam.CFrame = base.CFrame * CFrame.new(0, 18, 0)
				beam.Parent = model
			end

			-- Shiny is a separate axis from rarity: a Shiny Common should still stand
			-- out, so it gets its own treatment regardless of tier.
			if isShiny and liveParticles < MAX_CRITTER_PARTICLES then
				local shimmer = Instance.new("ParticleEmitter")
				shimmer.Texture = "rbxasset://textures/particles/sparkles_main.dds"
				shimmer.Color = ColorSequence.new(Color3.fromRGB(255, 255, 210))
				shimmer.Rate = 12
				shimmer.Lifetime = NumberRange.new(0.5, 0.9)
				shimmer.Speed = NumberRange.new(1, 2)
				shimmer.Size = NumberSequence.new(0.3)
				shimmer.LightEmission = 1
				shimmer.Parent = base
				vfxParticleCount += 1
			end
		end
	end

	model.Parent = workspace
	model:SetAttribute("OwnerUserId", player.UserId)

	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp and model.PrimaryPart then
		model:PivotTo(hrp.CFrame * CFrame.new(Constants.FOLLOW_OFFSET_STUDS, 0, 0))
	end

	record.model = model
	critters[uid] = record

	-- Critter Pat prompts REMOVED. With up to 20 equipped creatures following the
	-- player and clustering at the ranch, every one of them showed a floating "Pat"
	-- prompt -- a wall of overlapping UI that made the ranch unpleasant to look at.
	-- The reward was small and the visual cost was constant, so the trade was bad.
	-- CritterService.PerformPat is kept (nothing calls it now) so the mechanic can be
	-- reattached to a single deliberate interaction later if wanted.
	if not existingUid then
		PlayerDataService.AddOwnedCritter(player, {
			uid = uid, rarity = tier.id, species = species, worldId = worldId, personality = personality,
			sparksPerSecond = tier.sparksPerSecond * incomeMult, isShiny = isShiny,
		})
	-- Auto-equip into a FREE slot. Every creature enters through here, so this is the
	-- one place that guarantees a new player's first hatch actually earns.
	--
	-- If slots are FULL the equip fails and the model must be destroyed again: only
	-- equipped creatures get a physical body, and leaving one behind is exactly what
	-- filled the island with 90+ idle critters. The record stays in the inventory --
	-- the player can equip it later and it will respawn then.
	local equipped = PlayerDataService.EquipCritter(player, uid)
	if not equipped then
		if model and model.Parent then model:Destroy() end
		critters[uid] = nil
	end
		-- Single choke point for EVERY fresh grant (starter, paid hatch, rebirth-starter,
		-- any world) -- onboarding steps are idempotent (Roblox only counts the first
		-- occurrence), so calling this unconditionally here is correct and simpler than
		-- trying to be surgical about which specific call site is "the" first hatch.
		AnalyticsService.LogFirstHatch(player)
	end
	PlayerDataService.MarkCollection(player, species, "owned")
	local milestoneReward, milestoneCount, newXP, xpLevel, xpIntoLevel, xpNeeded, leveledUp =
		PlayerDataService.CheckCollectionMilestone(player)
	if milestoneReward then
		remotes.SparksUpdated:FireClient(player, PlayerDataService.Get(player).sparks)
		local milestoneRemote = remotes:FindFirstChild("CollectionMilestone")
		if milestoneRemote then
			milestoneRemote:FireClient(player, milestoneCount, milestoneReward)
		end
		if newXP then
			remotes.XPUpdated:FireClient(player, newXP, xpLevel, xpIntoLevel, xpNeeded)
			if leveledUp then remotes.LevelUp:FireClient(player, xpLevel) end
		end
	end
	-- Everyone else on the server marks it "seen" — walking past a rare critter
	-- fills your collection book, which quietly rewards spectating/social play.
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			PlayerDataService.MarkCollection(other, species, "seen")
		end
	end
	local collectionRemote = remotes:FindFirstChild("CollectionData")
	if collectionRemote then
		for _, p in ipairs(Players:GetPlayers()) do
			local prof = PlayerDataService.Get(p)
			if prof then
				collectionRemote:FireClient(p, prof.collection)
			end
		end
	end

	remotes.CritterStateChanged:FireAllClients(uid, record.state, { ownerUserId = player.UserId, species = species, isShiny = isShiny, personality = personality })
	CritterVFX.ApplyStateEffect(model, record.state)
	CritterVFX.PlayGoldBurst(model)

	-- VIP trail (gamepass cosmetic). The ownership attribute is set asynchronously on
	-- join and can also flip mid-session on a live purchase, so apply now if present
	-- and otherwise listen for the flip — connection dies with the model automatically
	-- since it's parented to the attribute signal on the Player but guarded by model.Parent.
	if player:GetAttribute("SAC_VipTrail") then
		CritterVFX.ApplyVipTrail(model)
	else
		local conn
		conn = player:GetAttributeChangedSignal("SAC_VipTrail"):Connect(function()
			if not model.Parent then
				conn:Disconnect()
				return
			end
			if player:GetAttribute("SAC_VipTrail") then
				CritterVFX.ApplyVipTrail(model)
				conn:Disconnect()
			end
		end)
	end
	if isShiny then
		CritterVFX.ApplyShinyAura(model)
	end
	local rebirthCount = player:GetAttribute("SAC_RebirthCount")
	if rebirthCount and rebirthCount > 0 then
		local tierInfo = Constants.GetRebirthTier(rebirthCount)
		if tierInfo then
			CritterVFX.ApplyRebirthAura(model, tierInfo.auraColor)
		end
	end
	return record
end

-- Removes a critter entirely: destroys its model and clears it from the live registry.
-- Used when a player hatches a replacement egg with no free slot (launch-scope
-- "hatch a better egg" upgrades your critter rather than requiring a slot purchase first).
-- Live critter models, for CritterVFX's distance culling. Returns models rather than
-- records so the culler needs no knowledge of the record shape.
function CritterService.GetCritterModels()
	local out = {}
	for _, rec in pairs(critters) do
		if rec.model and rec.model.Parent then out[#out + 1] = rec.model end
	end
	return out
end

function CritterService.RemoveCritter(uid)
	local record = critters[uid]
	if not record then return false end
	if record.model then
		record.model:Destroy()
	end
	critters[uid] = nil
	return true
end

-- Grants the Critter Pat bonus. Public (rather than inline in the ProximityPrompt
-- handler) so this is independently callable and testable -- prompts can't be fired
-- programmatically, so inline-only logic would be unverifiable without a human.
-- Returns (true, reward) on success, or (false, reason) -- reasons: "NoRecord",
-- "NotOwner", "OnCooldown".
function CritterService.PerformPat(player, uid)
	local record = critters[uid]
	if not record then return false, "NoRecord" end
	-- Only the OWNER can pat their own critter -- this isn't a shared/social
	-- interaction, just a personal "check in on your creature" action.
	if player.UserId ~= record.ownerUserId then return false, "NotOwner" end
	if os.clock() - (record.lastPatAt or 0) < Constants.PAT_COOLDOWN_SECONDS then
		return false, "OnCooldown"
	end
	record.lastPatAt = os.clock()

	local reward = math.random(Constants.PAT_REWARD.min, Constants.PAT_REWARD.max)
	local newTotal = PlayerDataService.AddSparks(player, reward)
	remotes.SparksUpdated:FireClient(player, newTotal)
	QuestService.ReportProgress(player, "sparks", reward)
	AnalyticsService.LogRewardEarned(player, reward, newTotal, "CritterPat")

	-- Reuses the EXISTING idle-animation motion system for feedback -- a happy
	-- bounce, not a new bespoke effect.
	applyIdleAnimEffect(record, "Bounce")
	remotes.CritterStateChanged:FireAllClients(record.uid, record.state, { playIdleAnim = "Bounce" })

	local patRemote = remotes:FindFirstChild("CritterPatted")
	if patRemote then
		-- Rarity goes with the reward so the client can voice the creature by size --
		-- a Mythic answering with the same chirp as a Common flattens the roster.
		patRemote:FireClient(player, reward, record.rarity)
	end
	return true, reward
end

-- ===== VFX distance culling =====
-- A spawn-time count budget alone is not enough: it can't account for critters
-- reconstructed on join, and it makes the FIRST few critters permanently privileged
-- regardless of where the player actually is.
--
-- This sweep enables lights only on the critters nearest each player, so the effect
-- scales with collection size instead of degrading. A player with 5 critters sees them
-- all lit; a player with 200 sees the closest few lit and the rest plain -- which is
-- visually identical from where they're standing, at a fraction of the cost.
local VFX_LIGHT_RADIUS = 60
local VFX_LIGHTS_PER_PLAYER = 3

local function sweepVfxCulling()
	-- Collect every critter light once, grouped by owner.
	local byOwner = {}
	for uid, record in pairs(critters) do
		local model = record.model
		if model and model.Parent then
			-- Collect ALL lights on the model, not just the first: a model can end up
			-- with more than one (observed live -- a duplicate spawn left two on the
			-- same Celestrix), and FindFirstChildOfClass would leave the extras
			-- permanently enabled and outside the cap.
			local lights = {}
			for _, d in ipairs(model:GetDescendants()) do
				if d:IsA("PointLight") then lights[#lights + 1] = d end
			end
			if #lights > 0 then
				local list = byOwner[record.ownerUserId] or {}
				list[#list + 1] = { lights = lights, model = model }
				byOwner[record.ownerUserId] = list
			end
		end
	end

	for userId, list in pairs(byOwner) do
		local owner = Players:GetPlayerByUserId(userId)
		local hrp = owner and owner.Character and owner.Character:FindFirstChild("HumanoidRootPart")
		if not hrp then
			-- Owner isn't around to see them; nothing needs to be lit.
			for _, entry in ipairs(list) do
				for _, l in ipairs(entry.lights) do l.Enabled = false end
			end
		else
			for _, entry in ipairs(list) do
				entry.dist = (entry.model:GetPivot().Position - hrp.Position).Magnitude
			end
			table.sort(list, function(a, b) return a.dist < b.dist end)
			for i, entry in ipairs(list) do
				local on = (i <= VFX_LIGHTS_PER_PLAYER) and (entry.dist <= VFX_LIGHT_RADIUS)
				-- Only the FIRST light on a model is ever lit, so a duplicate-spawned
				-- model can't consume two slots' worth of cost.
				for li, l in ipairs(entry.lights) do l.Enabled = on and li == 1 end
			end
		end
	end
end

-- ===== Per-heartbeat update: movement + passive income + idle anims =====

local function updateFollowing(record, ownerHrp, dt)
	if not ownerHrp or not record.model.PrimaryPart then return end
	local targetPos = ownerHrp.Position + (ownerHrp.CFrame.RightVector * Constants.FOLLOW_OFFSET_STUDS)
	local current = record.model.PrimaryPart.Position
	local newPos = current:Lerp(targetPos, math.clamp(dt * (Constants.FOLLOW_CATCHUP_SPEED / 10), 0, 1))
	local biasPos, biasYaw = getAnimBiasOffset(record)
	local finalCFrame = (CFrame.new(newPos, targetPos + Vector3.new(0, newPos.Y, 0)) + biasPos) * CFrame.Angles(0, biasYaw, 0)
	record.model:PivotTo(finalCFrame)
end

-- ===== Idle animation effects (expressive personality — GDD priority) =====
-- Server-authoritative so there's a single source of truth and zero fighting with the
-- replicated PivotTo movement: Size-tweens for face/body squash reads (safe, since PivotTo
-- never touches Size), and a short positional/rotational bias blended into the movement
-- target for motion-based ones (read by updateFollowing below).
local SQUASH_ANIM_KINDS = { Blink = true, Yawn = true, Sneeze = true, Scratch = true }
local MOTION_ANIM_KINDS = { Bounce = true, Wave = true, LookAround = true, Trip = true, Dance = true, Spin = true, Shiver = true, Hop = true }

local function playSquashEffect(record, animId)
	local model = record.model
	if not model then return end

	if animId == "Blink" then
		for _, part in ipairs(model:GetDescendants()) do
			if part.Name == "Eye" then
				local originalSize = part.Size
				local closed = Vector3.new(originalSize.X, originalSize.Y * 0.12, originalSize.Z)
				local closeTween = TweenService:Create(part, TweenInfo.new(0.08), { Size = closed })
				closeTween:Play()
				closeTween.Completed:Connect(function()
					TweenService:Create(part, TweenInfo.new(0.1), { Size = originalSize }):Play()
				end)
			end
		end
	elseif animId == "Yawn" then
		local body = model.PrimaryPart
		if not body then return end
		local originalSize = body.Size
		local stretched = originalSize * Vector3.new(0.9, 1.18, 0.9)
		local outTween = TweenService:Create(body, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = stretched })
		outTween:Play()
		outTween.Completed:Connect(function()
			TweenService:Create(body, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Size = originalSize }):Play()
		end)
	elseif animId == "Sneeze" then
		local body = model.PrimaryPart
		if not body then return end
		local originalSize = body.Size
		local scrunched = originalSize * Vector3.new(1.12, 0.85, 1.12)
		local inTween = TweenService:Create(body, TweenInfo.new(0.09), { Size = scrunched })
		inTween:Play()
		inTween.Completed:Connect(function()
			TweenService:Create(body, TweenInfo.new(0.22, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out), { Size = originalSize }):Play()
		end)
	elseif animId == "Scratch" then
		local body = model.PrimaryPart
		if not body then return end
		local originalSize = body.Size
		for i = 1, 3 do
			task.delay((i - 1) * 0.15, function()
				if not body.Parent then return end
				local pulse = originalSize * Vector3.new(1.04, 0.96, 1.04)
				local t1 = TweenService:Create(body, TweenInfo.new(0.07), { Size = pulse })
				t1:Play()
				t1.Completed:Connect(function()
					TweenService:Create(body, TweenInfo.new(0.07), { Size = originalSize }):Play()
				end)
			end)
		end
	end
end

function applyIdleAnimEffect(record, animId)
	if SQUASH_ANIM_KINDS[animId] then
		playSquashEffect(record, animId)
	elseif MOTION_ANIM_KINDS[animId] then
		record.animBias = {
			kind = animId,
			startTime = os.clock(),
			duration = (animId == "Trip") and 0.5
				or (animId == "Dance" and 1.1)
				or (animId == "Spin" and 0.6)
				or (animId == "Shiver" and 0.8)
				or (animId == "Hop" and 0.9)
				or 0.7,
		}
	end
end

-- Returns (positionOffset, yawOffset) for whatever motion-based idle anim is currently
-- playing on this critter, clearing it once its duration has elapsed.
function getAnimBiasOffset(record)
	local bias = record.animBias
	if not bias then return Vector3.new(0, 0, 0), 0 end
	local elapsed = os.clock() - bias.startTime
	if elapsed >= bias.duration then
		record.animBias = nil
		return Vector3.new(0, 0, 0), 0
	end
	local t = elapsed / bias.duration
	local kind = bias.kind
	if kind == "Bounce" then
		return Vector3.new(0, math.sin(t * math.pi) * 1.6, 0), 0
	elseif kind == "Wave" then
		return Vector3.new(0, 0, 0), math.sin(t * math.pi * 3) * math.rad(18)
	elseif kind == "LookAround" then
		return Vector3.new(0, 0, 0), math.sin(t * math.pi * 2) * math.rad(35)
	elseif kind == "Trip" then
		return Vector3.new(0, -math.sin(t * math.pi) * 0.7, 0), math.sin(t * math.pi) * math.rad(15)
	elseif kind == "Dance" then
		return Vector3.new(0, math.abs(math.sin(t * math.pi * 4)) * 1.2, 0), t * math.rad(360)
	elseif kind == "Spin" then
		-- one quick full rotation, eased so it snaps then settles
		return Vector3.new(0, 0, 0), t * t * math.rad(360)
	elseif kind == "Shiver" then
		-- rapid tiny yaw oscillation, like shaking off water
		return Vector3.new(0, 0, 0), math.sin(t * math.pi * 12) * math.rad(8)
	elseif kind == "Hop" then
		-- two small hops in a row
		return Vector3.new(0, math.abs(math.sin(t * math.pi * 2)) * 1.4, 0), 0
	end
	return Vector3.new(0, 0, 0), 0
end

-- Picks a weighted-random idle anim for this creature's personality: its 3 favorite
-- anims are PERSONALITY_FAVORITE_WEIGHT times more likely to be picked than any other
-- anim in the pool. A creature with no recognized personality (shouldn't happen for any
-- creature spawned after this system existed, but defends old/malformed data) falls
-- back to the original uniform-random behavior rather than erroring.
local function pickIdleAnim(record)
	local profile = Constants.PERSONALITIES[record.personality]
	if not profile then
		return Constants.IDLE_ANIM_IDS[math.random(1, #Constants.IDLE_ANIM_IDS)]
	end
	local favorites = {}
	for _, animId in ipairs(profile.favoriteAnims) do
		favorites[animId] = true
	end
	local totalWeight = 0
	for _, animId in ipairs(Constants.IDLE_ANIM_IDS) do
		totalWeight += favorites[animId] and Constants.PERSONALITY_FAVORITE_WEIGHT or 1
	end
	local roll = math.random() * totalWeight
	local acc = 0
	for _, animId in ipairs(Constants.IDLE_ANIM_IDS) do
		acc += favorites[animId] and Constants.PERSONALITY_FAVORITE_WEIGHT or 1
		if roll <= acc then
			return animId
		end
	end
	return Constants.IDLE_ANIM_IDS[1] -- unreachable in practice, defensive fallback
end

local function tickIdleAnimation(record)
	if os.clock() < record.nextIdleAnimAt then return end
	local animId = pickIdleAnim(record)
	-- intervalMult scales how OFTEN this creature animates at all -- a Lazy creature
	-- (1.8x) visibly moves less than a Curious one (0.6x), independent of which specific
	-- anims it favors. This is what makes personality readable even at a glance, before
	-- a player consciously registers which animation just played.
	local personalityProfile = Constants.PERSONALITIES[record.personality]
	local intervalMult = personalityProfile and personalityProfile.intervalMult or 1
	record.nextIdleAnimAt = os.clock() + math.random(
		Constants.IDLE_ANIM_INTERVAL_SECONDS.min, Constants.IDLE_ANIM_INTERVAL_SECONDS.max) * intervalMult
	remotes.CritterStateChanged:FireAllClients(record.uid, record.state, { playIdleAnim = animId })
	applyIdleAnimEffect(record, animId)
end

-- Treasure Find (item #2: "give every creature a job"). Chance-per-check, not a fixed
-- timer, so it genuinely reads as a surprise. A small, real Sparks bonus with its own
-- visible burst and personal toast -- distinct from silent passive income, this is a
-- moment the owner actually notices and can credit to a SPECIFIC creature by name.
local function tickTreasureFind(record, owner)
	if os.clock() < record.nextTreasureCheckAt then return end
	record.nextTreasureCheckAt = os.clock() + math.random(
		Constants.TREASURE_FIND_CHECK_INTERVAL_SECONDS.min, Constants.TREASURE_FIND_CHECK_INTERVAL_SECONDS.max)
	if not owner then return end -- owner not currently in-game; skip this roll silently
	if math.random() > Constants.TREASURE_FIND_CHANCE then return end

	local reward = math.random(Constants.TREASURE_FIND_REWARD.min, Constants.TREASURE_FIND_REWARD.max)
	local newTotal = PlayerDataService.AddSparks(owner, reward)
	remotes.SparksUpdated:FireClient(owner, newTotal)
	QuestService.ReportProgress(owner, "sparks", reward)
	AnalyticsService.LogRewardEarned(owner, reward, newTotal, "TreasureFind")

	if record.model and record.model.PrimaryPart then
		CritterVFX.PlayGoldBurst(record.model)
	end
	local treasureRemote = remotes:FindFirstChild("TreasureFound")
	if treasureRemote then
		treasureRemote:FireClient(owner, record.species, reward)
	end
end

function CritterService.Init()
	-- VFX culling on a 1s timer rather than the Heartbeat: this only needs to react to
	-- the player walking around, and running a sort over every critter 60x/sec would
	-- cost more than the lights it's saving.
	task.spawn(function()
		while true do
			task.wait(1)
			local ok, err = pcall(sweepVfxCulling)
			if not ok then warn("[CritterService] VFX cull failed:", err) end
		end
	end)
	RunService.Heartbeat:Connect(function(dt)
		for uid, record in pairs(critters) do
			if not record.model or not record.model.Parent then
				critters[uid] = nil
				continue
			end

			local owner = Players:GetPlayerByUserId(record.ownerUserId)
			local ownerChar = owner and owner.Character
			local ownerHrp = ownerChar and ownerChar:FindFirstChild("HumanoidRootPart")
			updateFollowing(record, ownerHrp, dt)

			-- Passive income, always -- no more "only while not stolen" gate, since nothing
			-- can steal a critter anymore.
			-- Only EQUIPPED creatures earn. Checked per-critter rather than filtering
			-- the loop, because equip state changes at runtime and a cached list would
			-- go stale the moment a player swaps.
			if owner and PlayerDataService.IsEquipped(owner, uid) then
				local incomeMultiplier = owner:GetAttribute("SAC_DoubleSparks") and 2 or 1
				if workspace:GetAttribute("SAC_EventDoubleSparks") then
					incomeMultiplier *= 2 -- world event stacks with the gamepass
				end
				local rebirthMult = owner:GetAttribute("SAC_RebirthMultiplier")
				if rebirthMult then
					incomeMultiplier *= rebirthMult -- permanent prestige multiplier stacks on top
				end
				-- VIP: a modest permanent bonus that stacks with everything above.
				if owner:GetAttribute("SAC_VIP") then
					incomeMultiplier *= Constants.VIP_INCOME_MULTIPLIER
				end
				-- Sparks Potion: temporary, stacks multiplicatively like every other source.
				local potionMult = owner:GetAttribute("SAC_SparksPotion")
				if potionMult then incomeMultiplier *= potionMult end
				-- Permanent bonus from completed Collection Book worlds.
				local collBonus = owner:GetAttribute("SAC_CollectionIncomeBonus")
				if collBonus then incomeMultiplier *= (1 + collBonus) end
				-- Friend proximity bonus: only active while friends are genuinely nearby.
				local friendBonus = owner:GetAttribute("SAC_FriendBonus")
				if friendBonus then incomeMultiplier *= (1 + friendBonus) end
				-- Ranch Power income perk.
				local ranchBonus = owner:GetAttribute("SAC_RanchIncomeBonus")
				if ranchBonus then incomeMultiplier *= (1 + ranchBonus) end
				-- Group membership bonus.
				local groupBonus = owner:GetAttribute("SAC_GroupBonus")
				if groupBonus then incomeMultiplier *= (1 + groupBonus) end
				-- World relic milestones.
				local relicBonus = owner:GetAttribute("SAC_RelicIncomeBonus")
				if relicBonus then incomeMultiplier *= (1 + relicBonus) end
				local gained = record.sparksPerSecond * incomeMultiplier * dt
				record._incomeAccum = (record._incomeAccum or 0) + gained
				if record._incomeAccum >= 1 then
					local whole = math.floor(record._incomeAccum)
					record._incomeAccum -= whole
					local newTotal = PlayerDataService.AddSparks(owner, whole)
					remotes.SparksUpdated:FireClient(owner, newTotal)
					QuestService.ReportProgress(owner, "sparks", whole)
				end
			end

			tickIdleAnimation(record)
			tickTreasureFind(record, owner)
		end
	end)
end

CritterService.weightedRandomRarity = weightedRandomRarity
CritterService._critters = critters

return CritterService

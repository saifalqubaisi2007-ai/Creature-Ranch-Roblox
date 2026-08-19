--[[
	HatchCinematicUI.lua
	The full-screen hatch reveal, extracted verbatim from ClientMain.

	ClientMain had reached 199,832 of Luau's hard 200,000-character source cap (and 229
	of its 200-local limit), which made every further UI change impossible. This block
	was the largest self-contained candidate at ~19.7k chars.

	Takes a context table rather than 22 separate parameters. The block body is
	UNCHANGED -- every dependency is re-localised below under its original name, so the
	extracted code reads identically to how it did inline and diffs cleanly.

	Exports nothing: verified before extraction that no name defined here is referenced
	outside it. (Three that were -- tradeIsActive, pendingGiftUid, RARITY_COLORS_CINEMATIC
	-- were hoisted into ClientMain first, because Trade/Inventory/EggOdds read them.)
]]

local HatchCinematicUI = {}

function HatchCinematicUI.init(ctx)
	local RS = ctx.RS
	local TweenService = ctx.TweenService
	local RunService = ctx.RunService
	local Constants = ctx.Constants
	local remotes = ctx.remotes
	local PALETTE = ctx.PALETTE
	local FONT_HEAVY = ctx.FONT_HEAVY
	local SFX = ctx.SFX
	local shakeCamera = ctx.shakeCamera
	local DEFAULT_FOV = ctx.DEFAULT_FOV
	local tweenFOV = ctx.tweenFOV
	local resetFOV = ctx.resetFOV
	local playSound = ctx.playSound
	local screenGui = ctx.screenGui
	local corner = ctx.corner
	local stroke = ctx.stroke
	local setCritterNameDisplay = ctx.setCritterNameDisplay
	local critterNameLabel = ctx.critterNameLabel
	local sparksCard = ctx.sparksCard
	local critterCard = ctx.critterCard
	local showGrabBanner = ctx.showGrabBanner
	local RARITY_COLORS_CINEMATIC = ctx.RARITY_COLORS_CINEMATIC

	-- ================= First-30-seconds Hatch Cinematic (GDD Section 2A) =================
	local cinematicGui = Instance.new("Frame")
	cinematicGui.Name = "HatchCinematic"
	cinematicGui.BackgroundColor3 = Color3.new(0, 0, 0)
	cinematicGui.BackgroundTransparency = 1
	cinematicGui.Size = UDim2.new(1, 0, 1, 0)
	cinematicGui.Visible = false
	cinematicGui.ZIndex = 50
	cinematicGui.Parent = screenGui

	local eggIcon = Instance.new("TextLabel")
	eggIcon.BackgroundTransparency = 1
	eggIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	eggIcon.Position = UDim2.new(0.5, 0, 0.5, 0)
	eggIcon.Size = UDim2.new(0, 180, 0, 180)
	eggIcon.Text = "\u{1F95A}"
	eggIcon.TextScaled = true
	eggIcon.Font = FONT_HEAVY
	eggIcon.ZIndex = 51
	eggIcon.Parent = cinematicGui

	local hatchLabel = Instance.new("TextLabel")
	hatchLabel.BackgroundTransparency = 1
	hatchLabel.AnchorPoint = Vector2.new(0.5, 0)
	hatchLabel.Position = UDim2.new(0.5, 0, 0.68, 0)
	hatchLabel.Size = UDim2.new(0, 600, 0, 80)
	hatchLabel.TextColor3 = Color3.new(1, 1, 1)
	hatchLabel.TextScaled = true
	hatchLabel.Font = FONT_HEAVY
	hatchLabel.Text = ""
	hatchLabel.TextTransparency = 1
	hatchLabel.ZIndex = 51
	hatchLabel.Parent = cinematicGui

	local flashFrame = Instance.new("Frame")
	flashFrame.BackgroundColor3 = Color3.new(1, 1, 1)
	flashFrame.BackgroundTransparency = 1
	flashFrame.Size = UDim2.new(1, 0, 1, 0)
	flashFrame.ZIndex = 52
	flashFrame.Parent = cinematicGui

	-- Real-model reveal viewport: the ACTUAL hatched species spins in 3D at the center of
	-- the cinematic, replacing the old chick-glyph stand-in. Strokes are created ONCE here
	-- because the old per-hatch UIStroke instances leaked (every shiny/Legendary hatch
	-- stacked another stroke on the egg icon forever).
	local critterViewport = Instance.new("ViewportFrame")
	critterViewport.BackgroundTransparency = 1
	critterViewport.AnchorPoint = Vector2.new(0.5, 0.5)
	critterViewport.Position = UDim2.new(0.5, 0, 0.47, 0)
	critterViewport.Size = UDim2.new(0, 260, 0, 260)
	critterViewport.Ambient = Color3.fromRGB(160, 160, 170)
	critterViewport.LightColor = Color3.fromRGB(255, 255, 255)
	critterViewport.LightDirection = Vector3.new(-0.4, -1, -0.6)
	critterViewport.Visible = false
	critterViewport.ZIndex = 51
	critterViewport.Parent = cinematicGui
	corner(critterViewport, 24)

	local viewportCamera = Instance.new("Camera")
	viewportCamera.FieldOfView = 50
	viewportCamera.Parent = critterViewport
	critterViewport.CurrentCamera = viewportCamera

	local shinyStroke = Instance.new("UIStroke")
	shinyStroke.Color = Color3.fromRGB(255, 170, 230)
	shinyStroke.Thickness = 0
	shinyStroke.Enabled = false
	shinyStroke.Parent = critterViewport

	local legendaryStroke = Instance.new("UIStroke")
	legendaryStroke.Color = PALETTE.accentGold
	legendaryStroke.Thickness = 0
	legendaryStroke.Enabled = false
	legendaryStroke.Parent = critterViewport

	local viewportSpinConn = nil
	local viewportModel = nil
	local function clearViewportModel()
		if viewportSpinConn then viewportSpinConn:Disconnect(); viewportSpinConn = nil end
		if viewportModel then viewportModel:Destroy(); viewportModel = nil end
	end

	-- Clones the species model into the viewport, frames the camera on its face (models
	-- face -Z), starts a slow spin. Returns false if the template is missing so the caller
	-- can fall back to the chick glyph.
	local function showCritterInViewport(species)
		clearViewportModel()
		local template = RS.CritterRush.Assets.Critters:FindFirstChild(species)
		if not template then return false end
		viewportModel = template:Clone()
		viewportModel:PivotTo(CFrame.new(0, 0, 0))
		viewportModel.Parent = critterViewport
		-- Frame on the model's true bounding center (decorations skew it upward from the
		-- pivot), with enough distance that ears/wings/auras don't clip the frame edges
		local boundsCFrame, boundsSize = viewportModel:GetBoundingBox()
		local center = boundsCFrame.Position
		local dist = boundsSize.Magnitude * 0.82
		viewportCamera.CFrame = CFrame.new(center + Vector3.new(0, boundsSize.Y * 0.06, -dist), center)
		viewportSpinConn = RunService.RenderStepped:Connect(function(dt)
			if viewportModel then
				viewportModel:PivotTo(viewportModel:GetPivot() * CFrame.Angles(0, dt * 1.1, 0))
			end
		end)
		return true
	end

	local RARITY_HATCH_LINES = {
		Common = "A new friend hatched!",
		Rare = "A Rare Critter hatched!",
		Epic = "An Epic Critter hatched!",
		Legendary = "\u{2b50} A LEGENDARY CRITTER HATCHED! \u{2b50}",
		Mythic = "\u{1F31F} A MYTHIC CRITTER HATCHED! \u{1F31F}",
	}

	local hatchTierOrder = { "Common", "Rare", "Epic", "Legendary", "Mythic" }
	local function tierRank(id)
		for i, name in ipairs(hatchTierOrder) do
			if name == id then return i end
		end
		return 1
	end

	-- Hatch cinematic speed + skip.
	--
	-- The full cinematic runs ~4s. That's the right weight for a first hatch and far too
	-- long by the fiftieth -- so it auto-shortens once the player has seen it, and can be
	-- skipped outright with a click/tap at any point.
	--
	-- skipRequested is checked between phases rather than aborting mid-tween, so a skip
	-- always lands on a clean state (no half-faded overlay or stuck zoom).
	local hatchSkipRequested = false
	local hatchesSeen = 0

	local function requestHatchSkip()
		hatchSkipRequested = true
	end

	-- Any click/tap during a cinematic skips it. Bound once, checked only while playing.
	-- Fetches the service directly rather than using the top-level UserInputService local,
	-- which is declared much further down this file and would be nil at this point.
	local hatchInputService = game:GetService("UserInputService")
	hatchInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		if not cinematicGui.Visible then return end
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
			or input.KeyCode == Enum.KeyCode.Space then
			requestHatchSkip()
		end
	end)

	-- Waits in small slices so a skip request interrupts promptly instead of stalling for
	-- the full duration. Returns true if the wait completed, false if it was skipped.
	local function hatchWait(duration)
		local elapsed = 0
		while elapsed < duration do
			if hatchSkipRequested then return false end
			local step = math.min(0.05, duration - elapsed)
			task.wait(step)
			elapsed += step
		end
		return true
	end

	-- Rarity tints used by the anticipation buildup. Matches the aura colours in
	-- Constants.RARITIES so the buildup glow and the creature's own aura agree.
	-- Shared flag: true while a trade session is open. Declared at top level because BOTH
	-- the inventory block (which shows an offer button per card) and the trade panel block
	-- need it, and they're in separate do...end scopes.
	-- uid awaiting a recipient: set by an inventory Gift button, consumed by the player
	-- picker. Cleared after use so a stale uid can't be gifted by a later unrelated tap.


	-- Shared teardown so a SKIP lands on exactly the same clean state as a full playthrough.
	-- Without this, an early return left the dark overlay up and the HUD cards hidden --
	-- the player would be staring at a frozen screen with no way back.
	local function finishHatchCinematic(species, personality)
		cinematicGui.Visible = false
		critterViewport.Visible = false
		clearViewportModel()
		sparksCard.Visible = true
		critterCard.Visible = true
		sparksCard.BackgroundTransparency = 0
		critterCard.BackgroundTransparency = 0
		setCritterNameDisplay(critterNameLabel, species, personality)
		resetFOV()
	end

	-- Rarity-scaled confetti burst for the crack moment. Pure UI (2D frames tweening
	-- outward from centre) rather than 3D ParticleEmitters, because the cinematic is a
	-- full-screen overlay -- world particles would render BEHIND it and be invisible.
	--
	-- Count and colour both scale with rarity, so a Mythic visibly rains where a Common
	-- gives a modest puff. Shiny overrides the palette entirely, matching how the
	-- announcement text already treats shiny as outranking base rarity.
	local CONFETTI_COLORS = {
		Color3.fromRGB(255, 205, 60), Color3.fromRGB(255, 120, 200),
		Color3.fromRGB(120, 220, 255), PALETTE.success,
		Color3.fromRGB(200, 150, 255),
	}
	local function spawnHatchConfetti(rank, isShiny)
		local count = 10 + rank * 8          -- Common ~18, Mythic ~50
		if isShiny then count = count + 20 end
		for i = 1, count do
			local piece = Instance.new("Frame")
			piece.Size = UDim2.new(0, math.random(5, 11), 0, math.random(8, 16))
			piece.AnchorPoint = Vector2.new(0.5, 0.5)
			piece.Position = UDim2.new(0.5, math.random(-40, 40), 0.5, math.random(-30, 30))
			piece.BackgroundColor3 = isShiny
				and Color3.fromRGB(255, 235, math.random(120, 200))
				or CONFETTI_COLORS[math.random(1, #CONFETTI_COLORS)]
			piece.BorderSizePixel = 0
			piece.Rotation = math.random(0, 360)
			piece.ZIndex = 33
			piece.Parent = cinematicGui

			-- Fan outward and fall, with a slight arc so it doesn't read as a uniform ring.
			local angle = math.rad(math.random(0, 360))
			local dist = math.random(120, 340)
			local dur = 0.7 + math.random() * 0.6
			TweenService:Create(piece, TweenInfo.new(dur, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Position = UDim2.new(0.5, math.cos(angle) * dist, 0.5, math.sin(angle) * dist + 120),
				Rotation = piece.Rotation + math.random(-540, 540),
				BackgroundTransparency = 1,
			}):Play()
			task.delay(dur + 0.1, function()
				if piece and piece.Parent then piece:Destroy() end
			end)
		end
	end

	local function playHatchCinematic(rarityId, species, isShiny, personality)
		-- Fresh skip state per play, and a speed that ramps up as the player sees more
		-- hatches: full weight for the first few, then progressively tighter so a veteran
		-- isn't sitting through a 4-second ceremony on every egg.
		hatchSkipRequested = false
		hatchesSeen += 1
		local speed = (hatchesSeen <= 3) and 1.0 or (hatchesSeen <= 10 and 1.8 or 2.6)
		resetFOV() -- safety net: guarantees a fresh cinematic never inherits a stuck zoom
		local rank = tierRank(rarityId) -- computed early so buildup zoom can scale by rarity too
		cinematicGui.Visible = true
		cinematicGui.BackgroundTransparency = 1
		eggIcon.Text = "\u{1F95A}"
		eggIcon.Rotation = 0
		eggIcon.Size = UDim2.new(0, 180, 0, 180) -- was never reset; a second hatch inherited the popped size
		eggIcon.TextTransparency = 0
		eggIcon.TextColor3 = Color3.new(1, 1, 1) -- reset: a previous Mythic glow must not carry over
		hatchLabel.TextTransparency = 1
		hatchLabel.Text = ""
		flashFrame.BackgroundTransparency = 1
		critterViewport.Visible = false
		critterViewport.ImageTransparency = 0
		shinyStroke.Enabled = false
		legendaryStroke.Enabled = false
		clearViewportModel()

		-- 1. Fade in a dim background, quiet beat
		TweenService:Create(cinematicGui, TweenInfo.new(0.4), { BackgroundTransparency = 0.55 }):Play()
		if not hatchWait(0.5 / speed) then finishHatchCinematic(species, personality) return end

		-- 2. Egg shake (quick rotation wobble building in intensity) + a slow FOV creep-in
		-- synced to the same buildup, rarer hatches zoom in tighter. Legendary+ also gets a
		-- slightly slower wobble cadence here -- Roblox has no true timescale/slowmo, so
		-- stretching the buildup's own pacing is the honest way to make the moment feel
		-- heavier before the payoff, rather than faking a global slow-motion effect.
		playSound(SFX.HatchShake, 0.4, 0.9)
		tweenFOV(DEFAULT_FOV - 6 - rank * 2, 0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)

		-- ANTICIPATION (the actual slot-machine feel): the buildup now TELEGRAPHS the
		-- outcome instead of being identical every time. Rarer hatches shake harder, glow
		-- brighter, and tick faster as they build -- so a player learns to read the buildup
		-- and gets a genuine "wait... is this a big one?" moment before the reveal.
		--
		-- Previously every hatch had an identical wobble, which meant the reveal was the
		-- only information and there was no tension leading into it.
		local buildSteps = 8 + rank * 2  -- rarer = longer, more drawn-out buildup
		local wobbleGap = 0.06 + ((rank >= tierRank("Legendary")) and 0.03 or 0)
		for i = 1, buildSteps do
			local progress = i / buildSteps
			-- Shake amplitude scales with BOTH progress and rarity.
			local wobble = (6 + i * 2) * (1 + rank * 0.35)
			TweenService:Create(eggIcon, TweenInfo.new(0.05, Enum.EasingStyle.Sine),
				{ Rotation = (i % 2 == 0) and wobble or -wobble }):Play()

			-- Glow ramp: the egg brightens toward its rarity colour as the buildup peaks.
			-- On a Common this stays near-white and unremarkable; on a Mythic it becomes
			-- unmistakable well before the crack.
			if rank >= 2 then
				local tint = RARITY_COLORS_CINEMATIC[rarityId] or Color3.new(1, 1, 1)
				eggIcon.TextColor3 = Color3.new(1, 1, 1):Lerp(tint, progress * 0.9)
			end

			-- Accelerating heartbeat ticks, pitch climbing with progress -- the audio cue
			-- that something big is coming. Only for Rare+ so Commons stay quick and quiet.
			if rank >= 1 and i % 2 == 0 then
				playSound(SFX.UiTick, 0.18 + progress * 0.22, 0.9 + progress * 0.9 + rank * 0.1)
			end

			-- Late-buildup camera shake on high rarities: the physical "this is big" tell.
			if rank >= 3 and progress > 0.6 then
				shakeCamera(0.06 * rank, 0.08)
			end

			-- Ticks accelerate as the buildup peaks (gap shrinks toward the end).
			local gap = wobbleGap * (1 - progress * 0.45)
			if not hatchWait(gap / speed) then break end
		end

		-- 3. CRACK — flash + scale pop + reveal species + camera punch (quick FOV kick outward
		-- then an elastic settle back to default, paired with the existing shake for impact)
		playSound(SFX.HatchCrack, 0.7, 1)
		shakeCamera(0.35, 0.3)
		tweenFOV(DEFAULT_FOV + 8 + rank * 2, 0.08, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
		task.delay(0.08, function()
			tweenFOV(DEFAULT_FOV, 0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		end)
		flashFrame.BackgroundTransparency = 0
		TweenService:Create(flashFrame, TweenInfo.new(0.35), { BackgroundTransparency = 1 }):Play()
		spawnHatchConfetti(rank, isShiny)
		-- Reveal the ACTUAL hatched species spinning in 3D (chick glyph only as a fallback
		-- if the template is somehow missing)
		if showCritterInViewport(species) then
			eggIcon.TextTransparency = 1
			critterViewport.Visible = true
			critterViewport.Size = UDim2.new(0, 200, 0, 200)
			TweenService:Create(critterViewport,
				TweenInfo.new(0.4, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out),
				{ Size = UDim2.new(0, 260, 0, 260) }):Play()
		else
			eggIcon.Text = "\u{1F423}"
			eggIcon.Rotation = 0
			TweenService:Create(eggIcon,
				TweenInfo.new(0.4, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out),
				{ Size = UDim2.new(0, 220, 0, 220) }):Play()
		end

		-- 4. Rarity-scaled announcement text (Shiny overrides everything — the whole point
		-- of a shiny is that it's a bigger deal than the base rarity text)
		if isShiny then
			hatchLabel.Text = "\u{2728} SHINY " .. species:upper() .. "! \u{2728}"
			hatchLabel.TextColor3 = Color3.fromRGB(255, 170, 230)
		else
			hatchLabel.Text = RARITY_HATCH_LINES[rarityId] or ("A " .. rarityId .. " Critter hatched!")
			hatchLabel.TextColor3 = (rarityId == "Legendary" or rarityId == "Mythic") and PALETTE.accentGold or PALETTE.textMain
		end
		TweenService:Create(hatchLabel, TweenInfo.new(0.4), { TextTransparency = 0 }):Play()

		-- Fanfare volume/pitch scales with rarity so Legendary+ genuinely sounds like a bigger deal
		playSound(SFX.HatchFanfare, 0.3 + rank * 0.12, 0.85 + rank * 0.08)
		if isShiny then
			task.delay(0.15, function() playSound(SFX.HatchFanfare, 0.6, 1.4) end) -- second layered chime
			shakeCamera(0.45, 0.5)
			critterViewport.LightColor = Color3.fromRGB(255, 190, 235) -- pink shiny light on the model itself
			shinyStroke.Enabled = true
			shinyStroke.Thickness = 5
			TweenService:Create(shinyStroke, TweenInfo.new(0.4, Enum.EasingStyle.Sine, Enum.EasingDirection.Out, 4, true),
				{ Thickness = 14 }):Play()
		else
			critterViewport.LightColor = Color3.fromRGB(255, 255, 255)
		end

		-- Mythic+/Legendary+ get an extra sky-beam-style flourish (simple scaling glow, upgradeable
		-- to real VFX once particle assets are dropped in)
		if tierRank(rarityId) >= tierRank("Legendary") then
			critterViewport.Ambient = Color3.fromRGB(200, 175, 120) -- warm gold wash on the model
			legendaryStroke.Enabled = true
			legendaryStroke.Thickness = 4
			TweenService:Create(legendaryStroke, TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.Out, 3, true),
				{ Thickness = 12 }):Play()
		else
			critterViewport.Ambient = Color3.fromRGB(160, 160, 170)
		end

		if not hatchWait(2.4 / speed) then finishHatchCinematic(species, personality) return end

		-- 5. Fade the cinematic out, revealing the HUD only now (per GDD: HUD fades in only
		-- after the hatch, so nothing distracts from the moment)
		TweenService:Create(cinematicGui, TweenInfo.new(0.5), { BackgroundTransparency = 1 }):Play()
		TweenService:Create(hatchLabel, TweenInfo.new(0.5), { TextTransparency = 1 }):Play()
		TweenService:Create(eggIcon, TweenInfo.new(0.5), { TextTransparency = 1 }):Play()
		TweenService:Create(critterViewport, TweenInfo.new(0.5), { ImageTransparency = 1 }):Play()
		sparksCard.Visible = false
		critterCard.Visible = false
		sparksCard.BackgroundTransparency = 1
		critterCard.BackgroundTransparency = 1
		hatchWait(0.55 / speed) -- final beat; a skip here just lands on cleanup immediately
		cinematicGui.Visible = false
		critterViewport.Visible = false
		clearViewportModel()

		sparksCard.Visible = true
		critterCard.Visible = true
		sparksCard.BackgroundTransparency = 1
		critterCard.BackgroundTransparency = 1
		setCritterNameDisplay(critterNameLabel, species, personality)
		TweenService:Create(sparksCard, TweenInfo.new(0.4), { BackgroundTransparency = 0 }):Play()
		TweenService:Create(critterCard, TweenInfo.new(0.4), { BackgroundTransparency = 0 }):Play()

		resetFOV() -- final safety net; the step-3 tween should already have settled here
	end

	-- Hide HUD cards until the very first hatch resolves, per the GDD's "nothing distracts
	-- from the hatch itself" beat
	sparksCard.Visible = false
	critterCard.Visible = false

	local hasPlayedFirstHatch = false
	local cinematicPlaying = false
	remotes.HatchResult.OnClientEvent:Connect(function(success, rarityId, species, critterUid, isShiny, personality)
		if not success then return end
		if cinematicPlaying then
			-- Rapid consecutive hatches (prompt spam): don't stack a second cinematic coroutine
			-- mutating the same GUI state — acknowledge with the lightweight banner instead.
			playSound(SFX.HatchFanfare, 0.45, 1.1)
			local line = isShiny and ("\u{2728} SHINY " .. species .. " hatched!") or (species .. " hatched!")
			showGrabBanner("\u{1F95A} " .. line)
			setCritterNameDisplay(critterNameLabel, species, personality)
			return
		end
		cinematicPlaying = true
		-- pcall guarantees the flag clears even if the cinematic errors mid-play — same
		-- "guard must not be able to stick" lesson as the QuestService re-entrancy fix.
		local ok, err = pcall(playHatchCinematic, rarityId, species, isShiny, personality)
		cinematicPlaying = false
		if not ok then
			resetFOV()
			warn("[ClientMain] hatch cinematic error: " .. tostring(err))
		end
		if not hasPlayedFirstHatch then
			-- Design-review fix (CRITICAL #1): a brand-new player's first 5 minutes were a
			-- ~4-minute dead zone if they didn't independently stumble onto orb-hunting as the
			-- active income accelerant (base Common income is only 1 Spark/s; the cheapest
			-- paid egg costs 250 -- pure AFK waiting took over 4 minutes with zero guidance).
			-- Delayed 3s so it doesn't compete with the hatch cinematic's own reveal, but
			-- fires reliably and unmissably right after, every single time, for every new
			-- player -- this is the single highest-priority finding from the World 1 review.
			task.delay(3, function()
				showGrabBanner("\u{1F3AF} Collect glowing Spark Orbs to earn faster!")
			end)
		end
		hasPlayedFirstHatch = true
	end)

end

return HatchCinematicUI

--[[
	InventoryUI.lua
	The Creature Inventory panel, extracted verbatim from ClientMain.

	Boundaries were found by COMPILER TEST, not line arithmetic: an earlier attempt cut
	one line short, moved an enclosing block's `end` into this module, and broke the
	whole client. Every candidate boundary here was validated with loadstring first.

	Takes a context table rather than 17 parameters; each dependency is re-localised
	below under its original name so the block body is UNCHANGED and diffs cleanly.

	tradeIsActive / pendingGiftUid come in as accessors, not values -- they are mutable
	shared state, so a by-value pass would hand this module a stale copy and silently
	drop its writes.
]]

local InventoryUI = {}

function InventoryUI.init(ctx)
	local TweenService = ctx.TweenService
	local Constants = ctx.Constants
	local WorldsData = ctx.WorldsData
	local remotes = ctx.remotes
	local PALETTE = ctx.PALETTE
	local FONT_HEAVY = ctx.FONT_HEAVY
	local FONT_BODY = ctx.FONT_BODY
	local SFX = ctx.SFX
	local playSound = ctx.playSound
	local screenGui = ctx.screenGui
	local corner = ctx.corner
	local stroke = ctx.stroke
	local addHoverFeedback = ctx.addHoverFeedback
	local showGrabBanner = ctx.showGrabBanner
	local RARITY_COLORS = ctx.RARITY_COLORS

	-- ================= Creature Inventory =================
	-- Answers the questions a collection game needs answered: what do I own, which is my
	-- best, what am I missing, how much does each earn. Pull-based like Achievements/Shop
	-- Trails -- server sends a fresh snapshot on open and after every favorite/lock toggle.
	-- (Second RARITY_COLORS removed: it defined DIFFERENT colours for the same
	-- rarities than the table at L618, so an Epic rendered as two different purples
	-- depending on which panel you looked at. Both now share the one definition.)
	local function worldDisplayName(worldId)
		local world = WorldsData.GetWorld(worldId)
		return world and world.displayName or worldId or "?"
	end

	local inventoryButton = Instance.new("TextButton")
	inventoryButton.Name = "InventoryButton"
	inventoryButton.Text = "\u{1F4E6} Inventory"
	inventoryButton.Font = FONT_HEAVY
	inventoryButton.TextScaled = true
	inventoryButton.TextColor3 = Color3.new(1, 1, 1)
	inventoryButton.BackgroundColor3 = Color3.fromRGB(170, 130, 200)
	inventoryButton.Size = UDim2.new(0, 110, 0, 44)
	inventoryButton.AnchorPoint = Vector2.new(1, 0)
	inventoryButton.Position = UDim2.new(1, -20, 0, 384)
	inventoryButton.Parent = screenGui
	addHoverFeedback(inventoryButton)
	corner(inventoryButton, 12)
	stroke(inventoryButton, Color3.new(1, 1, 1), 2)

	local inventoryPanel = Instance.new("Frame")
	inventoryPanel.Name = "InventoryPanel"
	inventoryPanel.BackgroundColor3 = PALETTE.card
	inventoryPanel.Size = UDim2.new(0, 380, 0.88, 0)
	local invSizeCap = Instance.new("UISizeConstraint")
	invSizeCap.MaxSize = Vector2.new(380, 560)
	invSizeCap.Parent = inventoryPanel
	inventoryPanel.AnchorPoint = Vector2.new(0.5, 0.5)
	inventoryPanel.Position = UDim2.new(0.5, 0, 0.5, 0)
	inventoryPanel.Visible = false
	inventoryPanel.ZIndex = 20
	inventoryPanel.Parent = screenGui
	corner(inventoryPanel, 18)
	stroke(inventoryPanel, Color3.fromRGB(170, 130, 200), 3)

	local invTitle = Instance.new("TextLabel")
	invTitle.BackgroundTransparency = 1
	invTitle.Size = UDim2.new(1, -60, 0, 32)
	invTitle.Position = UDim2.new(0, 12, 0, 8)
	invTitle.Text = "\u{1F4E6} CREATURE INVENTORY"
	invTitle.TextColor3 = Color3.new(1, 1, 1)
	invTitle.Font = FONT_HEAVY
	invTitle.TextScaled = true
	invTitle.TextXAlignment = Enum.TextXAlignment.Left
	invTitle.ZIndex = 21
	invTitle.Parent = inventoryPanel

	local invCloseButton = Instance.new("TextButton")
	invCloseButton.BackgroundColor3 = PALETTE.danger
	invCloseButton.Size = UDim2.new(0, 36, 0, 36)
	invCloseButton.AnchorPoint = Vector2.new(1, 0)
	invCloseButton.Position = UDim2.new(1, -8, 0, 6)
	invCloseButton.Text = "X"
	invCloseButton.Font = FONT_HEAVY
	invCloseButton.TextScaled = true
	invCloseButton.TextColor3 = Color3.new(1, 1, 1)
	invCloseButton.ZIndex = 21
	invCloseButton.Parent = inventoryPanel
	corner(invCloseButton, 10)

	-- Summary header: Total Creatures / Total Income / Best Creature
	local invSummary = Instance.new("TextLabel")
	invSummary.BackgroundTransparency = 1
	invSummary.Size = UDim2.new(1, -20, 0, 54)
	invSummary.Position = UDim2.new(0, 10, 0, 42)
	invSummary.Text = "Loading..."
	invSummary.TextColor3 = PALETTE.textDim
	invSummary.Font = FONT_BODY
	invSummary.TextScaled = true
	invSummary.TextWrapped = true
	invSummary.TextXAlignment = Enum.TextXAlignment.Left
	invSummary.TextYAlignment = Enum.TextYAlignment.Top
	invSummary.ZIndex = 21
	invSummary.Parent = inventoryPanel

	-- Sort row
	local SORT_MODES = { "Income", "Rarity", "World", "Newest", "A-Z" }
	local currentSort = "Income"
	-- Search + filter state. With 80+ creatures the list is unusable without these --
	-- finding one specific Mythic meant scrolling past everything you own.
	local searchText = ""
	local FILTER_MODES = { "All", "Shiny", "Favorite", "Locked", "Fusable" }
	local currentFilter = "All"

	-- Returns true if a record should be shown under the current search + filter.
	local function passesSearchAndFilter(c, fusableUids)
		if searchText ~= "" then
			local hay = string.lower(tostring(c.species) .. " " .. tostring(c.rarity) ..
				" " .. tostring(c.variant or "") .. " " .. tostring(c.worldId or ""))
			if not string.find(hay, searchText, 1, true) then return false end
		end
		if currentFilter == "Shiny" then return c.isShiny == true
		elseif currentFilter == "Favorite" then return c.favorite == true
		elseif currentFilter == "Locked" then return c.locked == true
		elseif currentFilter == "Fusable" then
			-- "Fusable" means this creature belongs to a group with enough duplicates to
			-- fuse -- the single most common reason to go hunting through the list.
			local key = tostring(c.species) .. "|" .. tostring(c.variant or "Normal")
			return fusableUids and fusableUids[key] == true
		end
		return true
	end
	local invSortRow = Instance.new("Frame")
	invSortRow.BackgroundTransparency = 1
	invSortRow.Size = UDim2.new(1, -20, 0, 30)
	invSortRow.Position = UDim2.new(0, 10, 0, 98)
	invSortRow.ZIndex = 21
	invSortRow.Parent = inventoryPanel
	local invSortLayout = Instance.new("UIListLayout")
	invSortLayout.FillDirection = Enum.FillDirection.Horizontal
	invSortLayout.Padding = UDim.new(0, 4)
	invSortLayout.Parent = invSortRow

	local invList = Instance.new("ScrollingFrame")
	invList.BackgroundTransparency = 1
	invList.Size = UDim2.new(1, -20, 1, -198)
	invList.Position = UDim2.new(0, 10, 0, 194)
	invList.CanvasSize = UDim2.new(0, 0, 0, 0)
	invList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	invList.ScrollBarThickness = 6
	invList.ZIndex = 21
	invList.Parent = inventoryPanel
	local invListLayout = Instance.new("UIListLayout")
	invListLayout.Padding = UDim.new(0, 6)
	invListLayout.SortOrder = Enum.SortOrder.LayoutOrder
	invListLayout.Parent = invList

	local latestInventoryData = { critters = {}, totalIncome = 0, bestCritter = nil }

	-- Fusion banner: appears above the card list whenever the player has 5+ duplicates
	-- of any species+variant. Built as a rebuilt-on-refresh list (same pattern as the
	-- inventory cards themselves) rather than persistent rows, since what's fusable
	-- changes on every hatch, fuse, lock toggle, and eviction.
	--
	-- Parented to the PANEL, not to invList: renderInventory() calls
	-- invList:ClearAllChildren() on every refresh, which would silently destroy this
	-- container. Found that the hard way -- the banner existed in code but never appeared.
	local fusionContainer = Instance.new("Frame")
	fusionContainer.Name = "FusionContainer"
	fusionContainer.BackgroundTransparency = 1
	fusionContainer.Size = UDim2.new(1, -20, 0, 0)
	fusionContainer.AutomaticSize = Enum.AutomaticSize.Y
	fusionContainer.Position = UDim2.new(0, 10, 0, 134)
	fusionContainer.Visible = false
	fusionContainer.ZIndex = 24
	fusionContainer.Parent = inventoryPanel
	local fusionLayout = Instance.new("UIListLayout")
	fusionLayout.Padding = UDim.new(0, 6)
	fusionLayout.SortOrder = Enum.SortOrder.LayoutOrder
	fusionLayout.Parent = fusionContainer

	local latestFusableGroups = {}
	-- Which uids are currently earning. Kept as a set for O(1) lookup while rendering
	-- 80+ cards.
	local equippedUids = {}
	local latestEquipState = nil

	local VARIANT_COLORS_AUTHORED = {
		Normal = Color3.fromRGB(200, 200, 210),
		Gold = Color3.fromRGB(255, 205, 60),
		Rainbow = Color3.fromRGB(255, 120, 220),
	}

	-- Variant tiers are infinite (generated past Rainbow), so a fixed colour table would
	-- leave every generated tier unstyled. Falls through to the generator, which assigns a
	-- cycling hue per tier.
	local VARIANT_COLORS = setmetatable({}, {
		__index = function(_, variantId)
			local authored = VARIANT_COLORS_AUTHORED[variantId]
			if authored then return authored end
			local idx = Constants.GetVariantIndex(variantId)
			local tier = idx and Constants.GetVariantTier(idx)
			return tier and tier.color or Color3.fromRGB(200, 200, 210)
		end,
	})

	local function renderFusionBanner()
		fusionContainer:ClearAllChildren()
		local relayout = Instance.new("UIListLayout")
		relayout.Padding = UDim.new(0, 6)
		relayout.SortOrder = Enum.SortOrder.LayoutOrder
		relayout.Parent = fusionContainer

		if #latestFusableGroups == 0 then
			fusionContainer.Visible = false
			-- Restore the card list to its full height when nothing is fusable.
			invList.Position = UDim2.new(0, 10, 0, 134)
			invList.Size = UDim2.new(1, -20, 1, -138)
			return
		end
		fusionContainer.Visible = true

		local header = Instance.new("TextLabel")
		header.BackgroundTransparency = 1
		header.Size = UDim2.new(1, 0, 0, 24)
		header.Text = "\u{2728} READY TO FUSE"
		header.TextColor3 = Color3.fromRGB(255, 205, 60)
		header.Font = FONT_HEAVY
		header.TextScaled = true
		header.TextXAlignment = Enum.TextXAlignment.Left
		header.LayoutOrder = 0
		header.ZIndex = 22
		header.Parent = fusionContainer

		for i, g in ipairs(latestFusableGroups) do
			local row = Instance.new("Frame")
			row.BackgroundColor3 = PALETTE.bg
			row.Size = UDim2.new(1, 0, 0, 52)
			row.LayoutOrder = i
			row.ZIndex = 22
			row.Parent = fusionContainer
			corner(row, 10)
			stroke(row, VARIANT_COLORS[g.nextVariant] or PALETTE.accentGold, 2)

			local label = Instance.new("TextLabel")
			label.BackgroundTransparency = 1
			label.Size = UDim2.new(1, -96, 0, 22)
			label.Position = UDim2.new(0, 10, 0, 5)
			label.Text = string.format("%d\u{00D7} %s", g.count, g.species)
			label.TextColor3 = Color3.new(1, 1, 1)
			label.Font = FONT_HEAVY
			label.TextScaled = true
			label.TextXAlignment = Enum.TextXAlignment.Left
			label.ZIndex = 23
			label.Parent = row

			local sub = Instance.new("TextLabel")
			sub.BackgroundTransparency = 1
			sub.Size = UDim2.new(1, -96, 0, 18)
			sub.Position = UDim2.new(0, 10, 0, 28)
			sub.Text = string.format("%d \u{2192} 1 %s", Constants.FUSION_REQUIRED_COUNT, g.nextVariant)
			sub.TextColor3 = VARIANT_COLORS[g.nextVariant] or PALETTE.textDim
			sub.Font = FONT_BODY
			sub.TextScaled = true
			sub.TextXAlignment = Enum.TextXAlignment.Left
			sub.ZIndex = 23
			sub.Parent = row

			local fuseBtn = Instance.new("TextButton")
			fuseBtn.Size = UDim2.new(0, 78, 0, 38)
			fuseBtn.AnchorPoint = Vector2.new(1, 0.5)
			fuseBtn.Position = UDim2.new(1, -8, 0.5, 0)
			fuseBtn.Text = "FUSE"
			fuseBtn.Font = FONT_HEAVY
			fuseBtn.TextScaled = true
			fuseBtn.BackgroundColor3 = VARIANT_COLORS[g.nextVariant] or PALETTE.accentGold
			fuseBtn.TextColor3 = Color3.fromRGB(40, 30, 10)
			fuseBtn.ZIndex = 23
			fuseBtn.Parent = row
			corner(fuseBtn, 9)
			addHoverFeedback(fuseBtn)
			fuseBtn.MouseButton1Click:Connect(function()
				playSound(SFX.UiTick, 0.4, 1.2)
				remotes.RequestFuse:FireServer(g.species, g.variant)
			end)
		end

		-- Push the card list down so it clears the banner. Height is computed from the real
		-- row count (header + 52px per row + padding) rather than a fixed guess, so it stays
		-- correct whether there's one fusable group or six.
		local bannerHeight = 24 + (#latestFusableGroups * 58) + 8
		invList.Position = UDim2.new(0, 10, 0, 134 + bannerHeight)
		invList.Size = UDim2.new(1, -20, 1, -(138 + bannerHeight))
	end

	remotes.FusableGroupsData.OnClientEvent:Connect(function(groups)
		latestFusableGroups = groups or {}
		renderFusionBanner()
	end)

	remotes.FuseResult.OnClientEvent:Connect(function(ok, variantOrReason, species)
		if ok then
			playSound(SFX.HatchFanfare, 0.6, 1.0)
			task.delay(0.15, function() playSound(SFX.HatchFanfare, 0.5, 1.6) end)
			showGrabBanner(string.format("\u{2728} Fused into a %s %s!", variantOrReason, species))
		elseif variantOrReason == "NotEnough" then
			showGrabBanner("Not enough duplicates to fuse!")
		end
	end)

	local function renderInventory()
		-- Leads with EQUIPPED income and slot usage: under the equip model those are
		-- the numbers a player acts on. Total owned is now just a collection stat.
		local eq = latestEquipState
		invSummary.Text = string.format(
			"Equipped: %s/%s   \u{2022}   Earning: %s Sparks/sec\nOwned: %d / %d",
			eq and tostring(#eq.equipped) or "?", eq and tostring(eq.capacity) or "?",
			Constants.FormatNumber(eq and eq.totalIncome or 0),
			#latestInventoryData.critters, eq and eq.inventoryCap or 500)

		local sorted = table.clone(latestInventoryData.critters)
		local rarityOrder = { Common = 1, Rare = 2, Epic = 3, Legendary = 4, Mythic = 5 }
		if currentSort == "Income" then
			table.sort(sorted, function(a, b) return (a.sparksPerSecond or 0) > (b.sparksPerSecond or 0) end)
		elseif currentSort == "Rarity" then
			table.sort(sorted, function(a, b) return (rarityOrder[a.rarity] or 0) > (rarityOrder[b.rarity] or 0) end)
		elseif currentSort == "World" then
			table.sort(sorted, function(a, b) return worldDisplayName(a.worldId) < worldDisplayName(b.worldId) end)
		elseif currentSort == "Newest" then
			sorted = table.clone(latestInventoryData.critters)
			-- ownedCritters is already insertion-ordered oldest-first, so newest is just reverse
			local reversed = {}
			for i = #sorted, 1, -1 do table.insert(reversed, sorted[i]) end
			sorted = reversed
		elseif currentSort == "A-Z" then
			table.sort(sorted, function(a, b) return a.species < b.species end)
		end

		invList:ClearAllChildren()
		local relayout = Instance.new("UIListLayout")
		relayout.Padding = UDim.new(0, 6)
		relayout.SortOrder = Enum.SortOrder.LayoutOrder
		relayout.Parent = invList

		-- Build the fusable set once per render rather than per row. Groups carry
		-- species+variant (NOT uids -- verified against GetFusableGroups; assuming a
		-- uids field would have silently matched nothing and shown an empty list).
		local fusableUids = {}
		for _, g in ipairs(latestFusableGroups or {}) do
			fusableUids[tostring(g.species) .. "|" .. tostring(g.variant)] = true
		end

		local shown = 0
		for i, c in ipairs(sorted) do
			if not passesSearchAndFilter(c, fusableUids) then continue end
			shown += 1
			local card = Instance.new("Frame")
			card.BackgroundColor3 = c.favorite and Color3.fromRGB(70, 60, 30) or PALETTE.bg
			card.Size = UDim2.new(1, 0, 0, 84)
			card.LayoutOrder = i
			card.ZIndex = 21
			card.Parent = invList
			corner(card, 10)
			-- Favorite glow: a real persistent visual on the CARD itself (thicker, brighter
			-- gold stroke), not just the star button -- so a favorited creature stands out
			-- at a glance while scrolling, not only when you look at its buttons.
			local cardStroke = stroke(card, c.favorite and Color3.fromRGB(255, 210, 90)
				or (RARITY_COLORS[c.rarity] or PALETTE.locked), c.favorite and 3 or 2)

			-- Hover feedback: Frame-compatible version of addHoverFeedback (that helper uses
			-- MouseButton1Down/Up, which only exist on GuiButtons -- cards are Frames, so a
			-- lighter MouseEnter/MouseLeave-only version is used here instead).
			local cardScale = Instance.new("UIScale")
			cardScale.Scale = 1
			cardScale.Parent = card
			card.MouseEnter:Connect(function()
				TweenService:Create(cardScale, TweenInfo.new(0.12, Enum.EasingStyle.Quad), { Scale = 1.02 }):Play()
			end)
			card.MouseLeave:Connect(function()
				TweenService:Create(cardScale, TweenInfo.new(0.12, Enum.EasingStyle.Quad), { Scale = 1 }):Play()
			end)

			local nameLabel = Instance.new("TextLabel")
			nameLabel.BackgroundTransparency = 1
			nameLabel.Size = UDim2.new(1, -100, 0, 24)
			nameLabel.Position = UDim2.new(0, 10, 0, 4)
			-- Variant prefix (Gold/Rainbow) sits alongside the Shiny sparkle rather than
			-- replacing it -- they're independent axes, so a Shiny Gold shows both.
			local variantId = c.variant or "Normal"
			local variantPrefix = (variantId ~= "Normal") and (variantId .. " ") or ""
			nameLabel.Text = (c.isShiny and "\u{2728} " or "") .. variantPrefix .. c.species
			nameLabel.TextColor3 = VARIANT_COLORS[variantId] ~= nil and variantId ~= "Normal"
				and VARIANT_COLORS[variantId]
				or (c.isShiny and Color3.fromRGB(255, 220, 100) or Color3.new(1, 1, 1))
			nameLabel.Font = FONT_HEAVY
			nameLabel.TextScaled = true
			nameLabel.TextXAlignment = Enum.TextXAlignment.Left
			nameLabel.ZIndex = 22
			nameLabel.Parent = card

			local detailLabel = Instance.new("TextLabel")
			detailLabel.BackgroundTransparency = 1
			detailLabel.Size = UDim2.new(1, -100, 0, 20)
			detailLabel.Position = UDim2.new(0, 10, 0, 26)
			detailLabel.Text = string.format("%s \u{2022} %s", c.rarity, worldDisplayName(c.worldId))
			detailLabel.TextColor3 = RARITY_COLORS[c.rarity] or PALETTE.textDim
			detailLabel.Font = FONT_BODY
			detailLabel.TextScaled = true
			detailLabel.TextXAlignment = Enum.TextXAlignment.Left
			detailLabel.ZIndex = 22
			detailLabel.Parent = card

			local incomeLabel = Instance.new("TextLabel")
			incomeLabel.BackgroundTransparency = 1
			incomeLabel.Size = UDim2.new(1, -100, 0, 18)
			incomeLabel.Position = UDim2.new(0, 10, 0, 46)
			incomeLabel.Text = string.format("+%.1f Sparks/sec%s", c.sparksPerSecond or 0,
				c.personality and (" \u{2022} " .. c.personality) or "")
			incomeLabel.TextColor3 = PALETTE.textDim
			incomeLabel.Font = FONT_BODY
			incomeLabel.TextScaled = true
			incomeLabel.TextXAlignment = Enum.TextXAlignment.Left
			incomeLabel.ZIndex = 22
			incomeLabel.Parent = card

			-- Time owned (item #9): a real "birthday" for the creature, computed from the
			-- server-stamped hatchedAt timestamp rather than anything client-guessed.
			local ownedLabel = Instance.new("TextLabel")
			ownedLabel.BackgroundTransparency = 1
			ownedLabel.Size = UDim2.new(1, -100, 0, 16)
			ownedLabel.Position = UDim2.new(0, 10, 0, 64)
			local ownedSeconds = os.time() - (c.hatchedAt or os.time())
			local ownedDays = math.floor(ownedSeconds / 86400)
			if ownedDays < 1 then
				ownedLabel.Text = "\u{1F423} Hatched today!"
			elseif ownedDays == 1 then
				ownedLabel.Text = "\u{1F423} Owned for 1 day"
			else
				ownedLabel.Text = string.format("\u{1F423} Owned for %d days", ownedDays)
			end
			ownedLabel.TextColor3 = Color3.fromRGB(150, 145, 165)
			ownedLabel.Font = FONT_BODY
			ownedLabel.TextScaled = true
			ownedLabel.TextXAlignment = Enum.TextXAlignment.Left
			ownedLabel.ZIndex = 22
			ownedLabel.Parent = card

			local favButton = Instance.new("TextButton")
			favButton.Size = UDim2.new(0, 36, 0, 30)
			favButton.AnchorPoint = Vector2.new(1, 0)
			favButton.Position = UDim2.new(1, -8, 0, 4)
			favButton.Text = c.favorite and "\u{2B50}" or "\u{2606}"
			favButton.Font = FONT_HEAVY
			favButton.TextScaled = true
			favButton.BackgroundColor3 = c.favorite and Color3.fromRGB(255, 210, 90) or Color3.fromRGB(70, 66, 84)
			favButton.TextColor3 = Color3.new(1, 1, 1)
			favButton.ZIndex = 22
			favButton.Parent = card
			corner(favButton, 8)
			favButton.MouseButton1Click:Connect(function()
				playSound(SFX.UiTick, 0.4, 1.3)
				remotes.RequestToggleFavorite:FireServer(c.uid)
			end)

			-- Trade offer toggle. Only meaningful during an active trade, so it's hidden
			-- otherwise rather than cluttering the card with a dead control.
			local offerButton = Instance.new("TextButton")
			offerButton.Name = "OfferButton"
			offerButton.Size = UDim2.new(0, 36, 0, 30)
			offerButton.AnchorPoint = Vector2.new(1, 0)
			offerButton.Position = UDim2.new(1, -48, 0, 4)
			offerButton.Text = "\u{1F91D}"
			offerButton.Font = FONT_HEAVY
			offerButton.TextScaled = true
			offerButton.BackgroundColor3 = Color3.fromRGB(120, 200, 255)
			offerButton.TextColor3 = Color3.fromRGB(20, 40, 60)
			offerButton.ZIndex = 22
			offerButton.Visible = ctx.getTradeActive()
			offerButton.Parent = card
			corner(offerButton, 8)
			offerButton.MouseButton1Click:Connect(function()
				playSound(SFX.UiTick, 0.4, 1.2)
				remotes.RequestTradeOffer:FireServer(c.uid)
			end)

			-- Gift button. Sets the pending gift uid and opens the player picker, reusing the
			-- Visit Ranch list rather than building a second recipient chooser.
			local giftButton = Instance.new("TextButton")
			giftButton.Name = "GiftButton"
			giftButton.Size = UDim2.new(0, 36, 0, 30)
			giftButton.AnchorPoint = Vector2.new(1, 0)
			giftButton.Position = UDim2.new(1, -48, 0, 38)
			giftButton.Text = "\u{1F381}"
			giftButton.Font = FONT_HEAVY
			giftButton.TextScaled = true
			giftButton.BackgroundColor3 = Color3.fromRGB(200, 120, 190)
			giftButton.TextColor3 = Color3.new(1, 1, 1)
			giftButton.ZIndex = 22
			giftButton.Parent = card
			corner(giftButton, 8)
			giftButton.MouseButton1Click:Connect(function()
				if c.locked then
					showGrabBanner("That critter is locked. Unlock it to gift.")
					return
				end
				playSound(SFX.UiTick, 0.4, 1.3)
				ctx.setPendingGift(c.uid)
				showGrabBanner("\u{1F381} Now pick who to gift your " .. tostring(c.species) .. " to.")
				inventoryPanel.Visible = false
				visitPanel.Visible = true
				renderVisitList()
				remotes.RequestFriendsInServer:FireServer()
			end)

			local lockButton = Instance.new("TextButton")
			lockButton.Size = UDim2.new(0, 36, 0, 30)
			lockButton.AnchorPoint = Vector2.new(1, 0)
			lockButton.Position = UDim2.new(1, -8, 0, 38)
			lockButton.Text = c.locked and "\u{1F512}" or "\u{1F513}"
			lockButton.Font = FONT_HEAVY
			lockButton.TextScaled = true
			lockButton.BackgroundColor3 = c.locked and Color3.fromRGB(220, 100, 100) or Color3.fromRGB(70, 66, 84)
			lockButton.TextColor3 = Color3.new(1, 1, 1)
			lockButton.ZIndex = 22
			lockButton.Parent = card
			corner(lockButton, 8)
			lockButton.MouseButton1Click:Connect(function()
				playSound(SFX.UiTick, 0.4, 1.3)
				remotes.RequestToggleLock:FireServer(c.uid)
			end)

			-- Equip toggle. The single most important button on the card now that only
			-- equipped creatures earn -- so it's the widest, leftmost and colour-coded
			-- rather than another small emoji square lost among the others.
			local isEquipped = equippedUids[c.uid] == true
			local equipButton = Instance.new("TextButton")
			equipButton.Size = UDim2.new(0, 78, 0, 30)
			equipButton.AnchorPoint = Vector2.new(1, 0)
			equipButton.Position = UDim2.new(1, -50, 0, 38)
			equipButton.Text = isEquipped and "Equipped" or "Equip"
			equipButton.Font = FONT_HEAVY
			equipButton.TextScaled = true
			equipButton.BackgroundColor3 = isEquipped and PALETTE.successDim or PALETTE.accentBlue
			equipButton.TextColor3 = PALETTE.textMain
			equipButton.ZIndex = 22
			equipButton.Parent = card
			corner(equipButton, 8)
			addHoverFeedback(equipButton)
			equipButton.MouseButton1Click:Connect(function()
				playSound(SFX.UiTick, 0.4, isEquipped and 0.9 or 1.35)
				if isEquipped then
					remotes.RequestUnequip:FireServer(c.uid)
				else
					remotes.RequestEquip:FireServer(c.uid)
				end
			end)

			-- Equipped cards get a bright stroke so the earning set is obvious while
			-- scrolling, without having to read every button.
			if isEquipped then
				cardStroke.Color = PALETTE.success
				cardStroke.Thickness = 3
			end
		end
	end

	-- Search box. TextBox rather than a filter-only approach because with 80+ owned
	-- creatures the common need is "where is my Skysovereign", which no filter answers.
	local searchBox = Instance.new("TextBox")
	searchBox.Name = "InvSearch"
	searchBox.Size = UDim2.new(1, -24, 0, 28)
	searchBox.Position = UDim2.new(0, 12, 0, 132)
	searchBox.BackgroundColor3 = PALETTE.panelInset
	searchBox.PlaceholderText = "Search name, rarity, variant..."
	searchBox.Text = ""
	searchBox.TextColor3 = PALETTE.textMain
	searchBox.PlaceholderColor3 = PALETTE.textDim
	searchBox.Font = FONT_BODY
	searchBox.TextScaled = true
	searchBox.ClearTextOnFocus = false
	searchBox.ZIndex = 22
	searchBox.Parent = inventoryPanel
	corner(searchBox, 8)

	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		searchText = string.lower(searchBox.Text)
		if latestInventoryData then renderInventory() end
	end)

	-- Filter chips.
	local filterRow = Instance.new("Frame")
	filterRow.Name = "InvFilterRow"
	filterRow.BackgroundTransparency = 1
	filterRow.Size = UDim2.new(1, -124, 0, 26) -- narrowed to make room for Equip Best
	filterRow.Position = UDim2.new(0, 12, 0, 164)
	filterRow.ZIndex = 22
	filterRow.Parent = inventoryPanel
	local filterLayout = Instance.new("UIListLayout")
	filterLayout.FillDirection = Enum.FillDirection.Horizontal
	filterLayout.Padding = UDim.new(0, 4)
	filterLayout.Parent = filterRow

	-- Equip Best: with a 500-slot inventory, hand-picking the top N is tedious and the
	-- optimal answer is unambiguous, so a one-tap version is a genuine convenience
	-- rather than a shortcut past a decision.
	local equipBestBtn = Instance.new("TextButton")
	equipBestBtn.Name = "EquipBestButton"
	equipBestBtn.Size = UDim2.new(0, 96, 0, 26)
	equipBestBtn.AnchorPoint = Vector2.new(1, 0)
	equipBestBtn.Position = UDim2.new(1, -12, 0, 164)
	equipBestBtn.Text = "\u{2B50} Equip Best"
	equipBestBtn.Font = FONT_HEAVY
	equipBestBtn.TextScaled = true
	equipBestBtn.BackgroundColor3 = PALETTE.accentGold
	equipBestBtn.TextColor3 = Color3.fromRGB(40, 30, 10)
	equipBestBtn.ZIndex = 23
	equipBestBtn.Parent = inventoryPanel
	corner(equipBestBtn, 8)
	addHoverFeedback(equipBestBtn)
	equipBestBtn.MouseButton1Click:Connect(function()
		playSound(SFX.UiTick, 0.45, 1.4)
		remotes.RequestEquipBest:FireServer()
	end)

	for _, mode in ipairs(FILTER_MODES) do
		local chip = Instance.new("TextButton")
		chip.Size = UDim2.new(0, 62, 1, 0)
		chip.Text = mode
		chip.Font = FONT_BODY
		chip.TextScaled = true
		chip.BackgroundColor3 = mode == currentFilter and PALETTE.accentBlue or PALETTE.panelInset
		chip.TextColor3 = PALETTE.textMain
		chip.ZIndex = 23
		chip.Parent = filterRow
		corner(chip, 8)
		chip.MouseButton1Click:Connect(function()
			playSound(SFX.UiTick, 0.4, 1.3)
			currentFilter = mode
			for _, b in ipairs(filterRow:GetChildren()) do
				if b:IsA("TextButton") then
					b.BackgroundColor3 = b.Text == mode and PALETTE.accentBlue or PALETTE.panelInset
				end
			end
			if latestInventoryData then renderInventory() end
		end)
	end

	for _, mode in ipairs(SORT_MODES) do
		local sortButton = Instance.new("TextButton")
		sortButton.Size = UDim2.new(0, 62, 1, 0)
		sortButton.Text = mode
		sortButton.Font = FONT_BODY
		sortButton.TextScaled = true
		sortButton.BackgroundColor3 = mode == currentSort and PALETTE.accentBlue or Color3.fromRGB(70, 66, 84)
		sortButton.TextColor3 = Color3.new(1, 1, 1)
		sortButton.ZIndex = 22
		sortButton.Parent = invSortRow
		corner(sortButton, 8)
		sortButton.MouseButton1Click:Connect(function()
			playSound(SFX.UiTick, 0.4, 1.3)
			currentSort = mode
			for _, btn in ipairs(invSortRow:GetChildren()) do
				if btn:IsA("TextButton") then
					btn.BackgroundColor3 = btn.Text == mode and PALETTE.accentBlue or Color3.fromRGB(70, 66, 84)
				end
			end
			renderInventory()
		end)
	end

	remotes.EquipState.OnClientEvent:Connect(function(state)
		latestEquipState = state
		equippedUids = {}
		for _, e in ipairs(state.equipped or {}) do equippedUids[e.uid] = true end
		if latestInventoryData then renderInventory() end
	end)

	remotes.EquipResult.OnClientEvent:Connect(function(ok, reason)
		if not ok then
			if reason == "NoFreeSlots" then
				showGrabBanner("All equip slots full \u{2014} unequip one first!")
			elseif reason == "AlreadyEquipped" then
				showGrabBanner("That creature is already equipped.")
			end
		end
	end)

	remotes.InventoryData.OnClientEvent:Connect(function(data)
		latestInventoryData = data
		renderInventory()
	end)

	inventoryButton.MouseButton1Click:Connect(function()
		playSound(SFX.UiTick, 0.4, 1.2)
		inventoryPanel.Visible = not inventoryPanel.Visible
		if inventoryPanel.Visible then
			remotes.RequestInventoryData:FireServer()
		remotes.RequestEquipState:FireServer()
			remotes.RequestFusableGroups:FireServer()
		end
	end)
	invCloseButton.MouseButton1Click:Connect(function()
		inventoryPanel.Visible = false
	end)



	-- Tier-up celebration: same visual language as the Daily Reward / Achievement popups
	-- (slides down from off-screen top, holds, slides back up) -- a ranch tier-up is a rare,
	-- meaningful, once-per-tier moment, not a routine action, so it earns a full popup
	-- rather than the smaller in-place burst level-ups get.
	remotes.RanchTierUp.OnClientEvent:Connect(function(tierName, tierOrder)
		playSound(SFX.HatchFanfare, 0.6, 0.9)
		task.delay(0.2, function() playSound(SFX.HatchFanfare, 0.5, 1.3) end)

		local popup = Instance.new("Frame")
		popup.BackgroundColor3 = Color3.fromRGB(110, 170, 90)
		popup.Size = UDim2.new(0, 360, 0, 90)
		popup.AnchorPoint = Vector2.new(0.5, 0)
		popup.Position = UDim2.new(0.5, 0, 0, -110)
		popup.ZIndex = 30
		popup.Parent = screenGui
		corner(popup, 16)
		stroke(popup, Color3.new(1, 1, 1), 3)

		local title = Instance.new("TextLabel")
		title.BackgroundTransparency = 1
		title.Size = UDim2.new(1, -20, 0, 40)
		title.Position = UDim2.new(0, 10, 0, 8)
		title.Text = "\u{1F3E1} YOUR RANCH GREW!"
		title.TextColor3 = Color3.new(1, 1, 1)
		title.Font = FONT_HEAVY
		title.TextScaled = true
		title.ZIndex = 31
		title.Parent = popup

		local detail = Instance.new("TextLabel")
		detail.BackgroundTransparency = 1
		detail.Size = UDim2.new(1, -20, 0, 40)
		detail.Position = UDim2.new(0, 10, 0, 42)
		detail.Text = "Now a " .. tierName .. "!"
		detail.TextColor3 = Color3.fromRGB(230, 255, 220)
		detail.Font = FONT_BODY
		detail.TextScaled = true
		detail.ZIndex = 31
		detail.Parent = popup

		TweenService:Create(popup, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Position = UDim2.new(0.5, 0, 0, 170) }):Play()
		task.delay(4.5, function()
			local hide = TweenService:Create(popup, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.In),
				{ Position = UDim2.new(0.5, 0, 0, -110) })
			hide:Play()
			hide.Completed:Connect(function() popup:Destroy() end)
		end)
	end)


end

return InventoryUI

--[[
	ShopUI.lua
	Shop panel (game passes, dev products, daily shop, cosmetic trails), extracted
	verbatim from ClientMain.

	Boundaries found by COMPILER TEST rather than line arithmetic -- an earlier
	extraction attempt in this project cut one line short, moved an enclosing block's
	`end` into the module, and broke the entire client.

	Takes a context table; each dependency is re-localised below under its original name
	so the block body is UNCHANGED and diffs cleanly. Exports nothing (verified).
]]

local ShopUI = {}

function ShopUI.init(ctx)
	local MarketplaceService = ctx.MarketplaceService
	local Constants = ctx.Constants
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
	local LocalPlayer = ctx.LocalPlayer

	-- ================= Shop (Game Passes + Dev Products) =================
	local MarketplaceService = game:GetService("MarketplaceService")

	local shopButton = Instance.new("TextButton")
	shopButton.Name = "ShopButton"
	shopButton.Text = "\u{1F6D2} Shop"
	shopButton.Font = FONT_HEAVY
	shopButton.TextScaled = true
	shopButton.TextColor3 = Color3.new(1, 1, 1)
	shopButton.BackgroundColor3 = PALETTE.accentPink
	shopButton.Size = UDim2.new(0, 110, 0, 44)
	shopButton.AnchorPoint = Vector2.new(1, 0)
	shopButton.Position = UDim2.new(1, -20, 0, 20)
	shopButton.Parent = screenGui
	addHoverFeedback(shopButton)
	corner(shopButton, 12)
	stroke(shopButton, Color3.new(1, 1, 1), 2)

	local shopPanel = Instance.new("Frame")
	shopPanel.Name = "ShopPanel"
	shopPanel.BackgroundColor3 = PALETTE.card
	shopPanel.Size = UDim2.new(0, 340, 0.85, 0)
	local shopSizeCap = Instance.new("UISizeConstraint")
	shopSizeCap.MaxSize = Vector2.new(340, 420)
	shopSizeCap.Parent = shopPanel
	shopPanel.AnchorPoint = Vector2.new(0.5, 0.5)
	shopPanel.Position = UDim2.new(0.5, 0, 0.5, 0)
	shopPanel.Visible = false
	shopPanel.ZIndex = 20
	shopPanel.Parent = screenGui
	corner(shopPanel, 18)
	stroke(shopPanel, PALETTE.accentPink, 3)

	local shopTitle = Instance.new("TextLabel")
	shopTitle.BackgroundTransparency = 1
	shopTitle.Size = UDim2.new(1, -20, 0, 44)
	shopTitle.Position = UDim2.new(0, 10, 0, 8)
	shopTitle.Text = "SHOP"
	shopTitle.TextColor3 = Color3.new(1, 1, 1)
	shopTitle.Font = FONT_HEAVY
	shopTitle.TextScaled = true
	shopTitle.ZIndex = 21
	shopTitle.Parent = shopPanel

	local shopCloseButton = Instance.new("TextButton")
	shopCloseButton.BackgroundColor3 = PALETTE.danger
	shopCloseButton.Size = UDim2.new(0, 36, 0, 36)
	shopCloseButton.AnchorPoint = Vector2.new(1, 0)
	shopCloseButton.Position = UDim2.new(1, -8, 0, 8)
	shopCloseButton.Text = "X"
	shopCloseButton.Font = FONT_HEAVY
	shopCloseButton.TextScaled = true
	shopCloseButton.TextColor3 = Color3.new(1, 1, 1)
	shopCloseButton.ZIndex = 21
	shopCloseButton.Parent = shopPanel
	addHoverFeedback(shopCloseButton)
	corner(shopCloseButton, 10)

	local shopList = Instance.new("ScrollingFrame")
	shopList.BackgroundTransparency = 1
	shopList.Size = UDim2.new(1, -20, 1, -70)
	shopList.Position = UDim2.new(0, 10, 0, 58)
	shopList.CanvasSize = UDim2.new(0, 0, 0, 0)
	shopList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	shopList.ScrollBarThickness = 6
	shopList.ZIndex = 21
	shopList.Parent = shopPanel

	local shopListLayout = Instance.new("UIListLayout")
	shopListLayout.Padding = UDim.new(0, 8)
	shopListLayout.SortOrder = Enum.SortOrder.LayoutOrder
	shopListLayout.Parent = shopList

	local function addShopEntry(name, description, buyLabel, onBuy, opts)
		opts = opts or {}
		local row = Instance.new("Frame")
		row.BackgroundColor3 = PALETTE.bg
		-- Badged rows are taller so the badge sits below the description rather than on it.
		row.Size = UDim2.new(1, 0, 0, opts.badge and 94 or 74)
		row.LayoutOrder = opts.sortOrder or 99
		row.ZIndex = 21
		row.Parent = shopList
		corner(row, 12)

		-- Badged rows get a coloured outline as well as the tag, so the anchor offer is
		-- distinguishable at a glance rather than requiring the player to read every row.
		if opts.badge then
			stroke(row, opts.badgeColor or PALETTE.accentGold, 2)
			local badge = Instance.new("TextLabel")
			badge.Name = "Badge"
			badge.BackgroundColor3 = opts.badgeColor or PALETTE.accentGold
			badge.Size = UDim2.new(0, 78, 0, 15)
			-- Bottom-LEFT, not top-right: the right side is occupied by the buy button
			-- (80px wide, right-anchored), and the badge would have rendered directly on
			-- top of it. The description label is only 36px tall, leaving clear space here.
			badge.AnchorPoint = Vector2.new(0, 1)
			badge.Position = UDim2.new(0, 10, 1, -5)
			badge.Text = opts.badge
			badge.TextColor3 = Color3.fromRGB(30, 25, 10)
			badge.Font = FONT_HEAVY
			badge.TextScaled = true
			badge.ZIndex = 23
			badge.Parent = row
			corner(badge, 6)
		end

		local nameLabel = Instance.new("TextLabel")
		nameLabel.BackgroundTransparency = 1
		nameLabel.Size = UDim2.new(1, -100, 0, 26)
		nameLabel.Position = UDim2.new(0, 10, 0, 6)
		nameLabel.Text = name
		nameLabel.TextColor3 = Color3.new(1, 1, 1)
		nameLabel.Font = FONT_HEAVY
		nameLabel.TextScaled = true
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.ZIndex = 21
		nameLabel.Parent = row

		local descLabel = Instance.new("TextLabel")
		descLabel.BackgroundTransparency = 1
		descLabel.Size = UDim2.new(1, -100, 0, 36)
		descLabel.Position = UDim2.new(0, 10, 0, 32)
		descLabel.Text = description
		descLabel.TextColor3 = PALETTE.textDim
		descLabel.Font = FONT_BODY
		descLabel.TextWrapped = true
		descLabel.TextScaled = true
		descLabel.TextXAlignment = Enum.TextXAlignment.Left
		descLabel.ZIndex = 21
		descLabel.Parent = row

		local buyButton = Instance.new("TextButton")
		-- Owned rows get a muted green button instead of the gold call-to-action, so an
		-- already-purchased pass reads as settled rather than as another thing to buy.
		local isOwned = buyLabel == "OWNED"
		buyButton.BackgroundColor3 = isOwned and Color3.fromRGB(70, 130, 90) or PALETTE.accentGold
		buyButton.Size = UDim2.new(0, 80, 0, 56)
		buyButton.AnchorPoint = Vector2.new(1, 0.5)
		buyButton.Position = UDim2.new(1, -8, 0.5, 0)
		buyButton.Text = buyLabel
		buyButton.Font = FONT_HEAVY
		buyButton.TextScaled = true
		buyButton.TextColor3 = isOwned and Color3.fromRGB(230, 255, 235) or Color3.fromRGB(40, 30, 10)
		buyButton.ZIndex = 21
		buyButton.Parent = row
		corner(buyButton, 10)
		addHoverFeedback(buyButton)
		buyButton.MouseButton1Click:Connect(onBuy)
		-- Returned so callers can tag the row (e.g. marking pass rows for selective
		-- re-render when ownership changes) without re-finding it in shopList.
		return row
	end

	-- Iterate by KEY so each entry can look up its sortOrder/badge. pairs() order is
	-- non-deterministic, but LayoutOrder makes the rendered result stable regardless.
	-- Gamepass attribute per key, so the shop can show OWNED instead of a Buy button the
	-- player would tap only to be told they already own it.
	local PASS_ATTRIBUTES = {
		DoubleSparks = "SAC_DoubleSparks",
		InstantExtraSlot = "SAC_ExtraSlotPass",
		VipTrail = "SAC_VipTrail",
		AutoHatch = "SAC_AutoHatch",
		VIP = "SAC_VIP",
		LuckPass = "SAC_LuckPass",
	}

	local function renderPassRows()
		-- Clear only the pass rows; dev-product rows and the Daily Shop header are rebuilt
		-- by their own code paths and must not be destroyed here.
		for _, child in ipairs(shopList:GetChildren()) do
			if child:IsA("Frame") and child:GetAttribute("ShopRowKind") == "pass" then
				child:Destroy()
			end
		end
		for key, info in pairs(Constants.GAME_PASSES) do
			local presentation = Constants.SHOP_ORDER[key] or {}
			local attr = PASS_ATTRIBUTES[key]
			local owned = attr and LocalPlayer:GetAttribute(attr) == true
			local row = addShopEntry(
				info.name, info.description,
				owned and "OWNED" or "Buy",
				function()
					if owned then return end
					if info.id == 0 then return end -- not configured yet
					MarketplaceService:PromptGamePassPurchase(LocalPlayer, info.id)
				end,
				presentation
			)
			if row then
				row:SetAttribute("ShopRowKind", "pass")
			end
		end
	end

	renderPassRows()

	-- Re-render when any pass attribute changes, so a purchase updates the shop live
	-- rather than waiting for a rejoin.
	for _, attr in pairs(PASS_ATTRIBUTES) do
		LocalPlayer:GetAttributeChangedSignal(attr):Connect(renderPassRows)
	end

	for key, info in pairs(Constants.DEV_PRODUCTS) do
		-- Bundles describe their full contents rather than just their Sparks value -- a
		-- Starter Pack listed as "+25.0K Sparks" hides the slots and Limited Egg token,
		-- which are most of why it's worth buying.
		local desc
		if info.extraSlots or info.limitedEggTokens then
			local bits = { "+" .. Constants.FormatNumber(info.sparks) .. " Sparks" }
			if info.extraSlots then bits[#bits+1] = "+" .. info.extraSlots .. " Critter slots" end
			if info.limitedEggTokens then bits[#bits+1] = "+" .. info.limitedEggTokens .. " Limited Egg" end
			desc = table.concat(bits, "  \u{2022}  ")
		else
			desc = ("+%s Sparks"):format(Constants.FormatNumber(info.sparks))
		end
		addShopEntry(info.name, desc, "Buy", function()
			if info.id == 0 then return end -- not configured yet
			MarketplaceService:PromptProductPurchase(LocalPlayer, info.id)
		end, Constants.SHOP_ORDER[key] or {})
	end

	-- ===== Daily Shop section (item #16) =====
	-- One rotating deal per real day, resets at midnight -- a genuine "come back tomorrow"
	-- hook distinct from the Elder gift and login streak, living right in the Shop the
	-- player already opens for gamepasses/dev-products/trails.
	do
	local dailyShopHeader = Instance.new("TextLabel")
	dailyShopHeader.BackgroundTransparency = 1
	dailyShopHeader.Size = UDim2.new(1, 0, 0, 30)
	dailyShopHeader.Text = "\u{1F4C5} TODAY'S DEAL"
	dailyShopHeader.TextColor3 = Color3.fromRGB(255, 190, 60)
	dailyShopHeader.Font = FONT_HEAVY
	dailyShopHeader.TextScaled = true
	dailyShopHeader.TextXAlignment = Enum.TextXAlignment.Left
	dailyShopHeader.LayoutOrder = -10
	dailyShopHeader.ZIndex = 21
	dailyShopHeader.Parent = shopList

	local dailyShopRow = Instance.new("Frame")
	dailyShopRow.BackgroundColor3 = PALETTE.bg
	dailyShopRow.Size = UDim2.new(1, 0, 0, 74)
	dailyShopRow.LayoutOrder = -9
	dailyShopRow.ZIndex = 21
	dailyShopRow.Parent = shopList
	corner(dailyShopRow, 12)
	local dailyShopStroke = stroke(dailyShopRow, Color3.fromRGB(255, 190, 60), 2)

	local dailyShopNameLabel = Instance.new("TextLabel")
	dailyShopNameLabel.BackgroundTransparency = 1
	dailyShopNameLabel.Size = UDim2.new(1, -100, 0, 26)
	dailyShopNameLabel.Position = UDim2.new(0, 10, 0, 6)
	dailyShopNameLabel.Text = "Loading..."
	dailyShopNameLabel.TextColor3 = Color3.new(1, 1, 1)
	dailyShopNameLabel.Font = FONT_HEAVY
	dailyShopNameLabel.TextScaled = true
	dailyShopNameLabel.TextXAlignment = Enum.TextXAlignment.Left
	dailyShopNameLabel.ZIndex = 21
	dailyShopNameLabel.Parent = dailyShopRow

	local dailyShopDescLabel = Instance.new("TextLabel")
	dailyShopDescLabel.BackgroundTransparency = 1
	dailyShopDescLabel.Size = UDim2.new(1, -100, 0, 36)
	dailyShopDescLabel.Position = UDim2.new(0, 10, 0, 32)
	dailyShopDescLabel.Text = ""
	dailyShopDescLabel.TextColor3 = PALETTE.textDim
	dailyShopDescLabel.Font = FONT_BODY
	dailyShopDescLabel.TextWrapped = true
	dailyShopDescLabel.TextScaled = true
	dailyShopDescLabel.TextXAlignment = Enum.TextXAlignment.Left
	dailyShopDescLabel.ZIndex = 21
	dailyShopDescLabel.Parent = dailyShopRow

	local dailyShopButton = Instance.new("TextButton")
	dailyShopButton.Size = UDim2.new(0, 80, 0, 56)
	dailyShopButton.AnchorPoint = Vector2.new(1, 0.5)
	dailyShopButton.Position = UDim2.new(1, -8, 0.5, 0)
	dailyShopButton.Text = "..."
	dailyShopButton.Font = FONT_HEAVY
	dailyShopButton.TextScaled = true
	dailyShopButton.TextColor3 = Color3.fromRGB(40, 30, 10)
	dailyShopButton.ZIndex = 21
	dailyShopButton.Parent = dailyShopRow
	corner(dailyShopButton, 10)

	local function renderDailyShop(offer)
		if not offer then return end
		if offer.type == "trail" then
			dailyShopNameLabel.Text = offer.trailName
			dailyShopDescLabel.Text = string.format("30%% OFF! %s Sparks (was %s)", Constants.FormatNumber(offer.discountedCost), Constants.FormatNumber(offer.originalCost))
		else
			dailyShopNameLabel.Text = "Daily Bonus"
			dailyShopDescLabel.Text = string.format("+%s free Sparks, just for stopping by!", Constants.FormatNumber(offer.amount))
		end

		if offer.claimed then
			dailyShopButton.Text = "\u{2705}"
			dailyShopButton.BackgroundColor3 = PALETTE.success
			dailyShopStroke.Color = PALETTE.success
		else
			dailyShopButton.Text = offer.type == "trail" and "Buy" or "Claim"
			dailyShopButton.BackgroundColor3 = Color3.fromRGB(255, 190, 60)
			dailyShopStroke.Color = Color3.fromRGB(255, 190, 60)
		end
	end

	dailyShopButton.MouseButton1Click:Connect(function()
		playSound(SFX.UiTick, 0.4, 1.2)
		remotes.RequestPurchaseDailyShopOffer:FireServer()
	end)

	remotes.DailyShopData.OnClientEvent:Connect(renderDailyShop)
	end

	-- ===== Cosmetic Trails section =====
	-- A dedicated header + a container that fully rebuilds on every TrailsData refresh --
	-- unlike the static gamepass/dev-product rows above, trail rows need to show three
	-- different states (Buy / Equip / Equipped) that change live as the player buys and
	-- switches, so a static addShopEntry call can't represent them.
	local trailsHeader = Instance.new("TextLabel")
	trailsHeader.BackgroundTransparency = 1
	trailsHeader.Size = UDim2.new(1, 0, 0, 30)
	trailsHeader.Text = "\u{2728} COSMETIC TRAILS"
	trailsHeader.TextColor3 = PALETTE.accentGold
	trailsHeader.Font = FONT_HEAVY
	trailsHeader.TextScaled = true
	trailsHeader.TextXAlignment = Enum.TextXAlignment.Left
	trailsHeader.LayoutOrder = 1000
	trailsHeader.ZIndex = 21
	trailsHeader.Parent = shopList

	local trailsContainer = Instance.new("Frame")
	trailsContainer.BackgroundTransparency = 1
	trailsContainer.Size = UDim2.new(1, 0, 0, 0)
	trailsContainer.AutomaticSize = Enum.AutomaticSize.Y
	trailsContainer.LayoutOrder = 1001
	trailsContainer.ZIndex = 21
	trailsContainer.Parent = shopList
	local trailsLayout = Instance.new("UIListLayout")
	trailsLayout.Padding = UDim.new(0, 8)
	trailsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	trailsLayout.Parent = trailsContainer

	local function renderTrails(data)
		trailsContainer:ClearAllChildren()
		local relayout = Instance.new("UIListLayout")
		relayout.Padding = UDim.new(0, 8)
		relayout.SortOrder = Enum.SortOrder.LayoutOrder
		relayout.Parent = trailsContainer

		for i, t in ipairs(data) do
			local row = Instance.new("Frame")
			row.BackgroundColor3 = PALETTE.bg
			row.Size = UDim2.new(1, 0, 0, 60)
			row.LayoutOrder = i
			row.ZIndex = 21
			row.Parent = trailsContainer
			corner(row, 12)
			if t.equipped then stroke(row, PALETTE.accentGold, 2) end

			local nameLabel = Instance.new("TextLabel")
			nameLabel.BackgroundTransparency = 1
			nameLabel.Size = UDim2.new(1, -100, 1, 0)
			nameLabel.Position = UDim2.new(0, 10, 0, 0)
			nameLabel.Text = t.name
			nameLabel.TextColor3 = Color3.new(1, 1, 1)
			nameLabel.Font = FONT_BODY
			nameLabel.TextScaled = true
			nameLabel.TextXAlignment = Enum.TextXAlignment.Left
			nameLabel.ZIndex = 21
			nameLabel.Parent = row

			local actionButton = Instance.new("TextButton")
			actionButton.Size = UDim2.new(0, 90, 0, 44)
			actionButton.AnchorPoint = Vector2.new(1, 0.5)
			actionButton.Position = UDim2.new(1, -8, 0.5, 0)
			actionButton.Font = FONT_HEAVY
			actionButton.TextScaled = true
			actionButton.ZIndex = 21
			actionButton.Parent = row
			corner(actionButton, 10)
			addHoverFeedback(actionButton)

			if t.equipped then
				actionButton.Text = "Equipped"
				actionButton.BackgroundColor3 = PALETTE.success
				actionButton.TextColor3 = Color3.fromRGB(20, 60, 30)
				actionButton.MouseButton1Click:Connect(function()
					remotes.RequestEquipTrail:FireServer(nil) -- click again to unequip
				end)
			elseif t.owned then
				actionButton.Text = "Equip"
				actionButton.BackgroundColor3 = PALETTE.accentBlue
				actionButton.TextColor3 = Color3.new(1, 1, 1)
				actionButton.MouseButton1Click:Connect(function()
					remotes.RequestEquipTrail:FireServer(t.id)
				end)
			else
				actionButton.Text = t.cost .. " \u{2728}"
				actionButton.BackgroundColor3 = PALETTE.accentGold
				actionButton.TextColor3 = Color3.fromRGB(40, 30, 10)
				actionButton.MouseButton1Click:Connect(function()
					remotes.RequestPurchaseTrail:FireServer(t.id)
				end)
			end
		end
	end

	remotes.TrailsData.OnClientEvent:Connect(renderTrails)
	remotes.TrailPurchaseResult.OnClientEvent:Connect(function(ok, reason)
		if not ok and reason == "InsufficientSparks" then
			showGrabBanner("Not enough Sparks for that trail!")
		end
	end)

	shopButton.MouseButton1Click:Connect(function()
		playSound(SFX.UiTick, 0.4, 1.2)
		shopPanel.Visible = not shopPanel.Visible
		if shopPanel.Visible then
			remotes.RequestTrailsData:FireServer()
			remotes.RequestDailyShopData:FireServer()
		end
	end)
	shopCloseButton.MouseButton1Click:Connect(function()
		playSound(SFX.UiTick, 0.35, 0.85)
		shopPanel.Visible = false
	end)

	-- ================= Codes + Credits panel =================
	-- One panel covering promo codes, the group reward, and credits. Grouped because all
	-- three are "meta" content a player visits rarely and never mid-action -- three separate
	-- buttons for three rarely-used screens is exactly the HUD clutter the button dock pass
	-- was meant to remove.
	do
		local codesButton = Instance.new("TextButton")
		codesButton.Name = "CodesButton"
		codesButton.Text = "\u{1F381} Codes"
		codesButton.Font = FONT_HEAVY
		codesButton.TextScaled = true
		codesButton.TextColor3 = PALETTE.textMain
		codesButton.BackgroundColor3 = PALETTE.accentPink
		codesButton.Size = UDim2.new(0, 110, 0, 44)
		codesButton.AnchorPoint = Vector2.new(1, 0)
		codesButton.Position = UDim2.new(1, -20, 0, 536)
		codesButton.ZIndex = 12
		codesButton.Parent = screenGui
		addHoverFeedback(codesButton)
		corner(codesButton, 12)
		stroke(codesButton, PALETTE.textMain, 2)

		local panel = Instance.new("Frame")
		panel.Name = "CodesPanel"
		panel.BackgroundColor3 = PALETTE.card
		panel.Size = UDim2.new(0, 360, 0, 400)
		panel.AnchorPoint = Vector2.new(0.5, 0.5)
		panel.Position = UDim2.new(0.5, 0, 0.5, 0)
		panel.Visible = false
		panel.ZIndex = 20
		panel.Parent = screenGui
		corner(panel, 18)
		stroke(panel, PALETTE.accentPink, 3)

		local title = Instance.new("TextLabel")
		title.BackgroundTransparency = 1
		title.Size = UDim2.new(1, -60, 0, 32)
		title.Position = UDim2.new(0, 12, 0, 8)
		title.Text = "\u{1F381} CODES & INFO"
		title.TextColor3 = PALETTE.accentPink
		title.Font = FONT_HEAVY
		title.TextScaled = true
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.ZIndex = 21
		title.Parent = panel

		local closeBtn = Instance.new("TextButton")
		closeBtn.BackgroundColor3 = PALETTE.danger
		closeBtn.Size = UDim2.new(0, 32, 0, 32)
		closeBtn.AnchorPoint = Vector2.new(1, 0)
		closeBtn.Position = UDim2.new(1, -8, 0, 8)
		closeBtn.Text = "X"
		closeBtn.Font = FONT_HEAVY
		closeBtn.TextScaled = true
		closeBtn.TextColor3 = PALETTE.textMain
		closeBtn.ZIndex = 21
		closeBtn.Parent = panel
		corner(closeBtn, 10)

		-- Code entry
		local codeBox = Instance.new("TextBox")
		codeBox.Size = UDim2.new(1, -110, 0, 36)
		codeBox.Position = UDim2.new(0, 12, 0, 50)
		codeBox.BackgroundColor3 = PALETTE.panelInset
		codeBox.PlaceholderText = "Enter code..."
		codeBox.Text = ""
		codeBox.TextColor3 = PALETTE.textMain
		codeBox.PlaceholderColor3 = PALETTE.textDim
		codeBox.Font = FONT_BODY
		codeBox.TextScaled = true
		codeBox.ClearTextOnFocus = false
		codeBox.ZIndex = 21
		codeBox.Parent = panel
		corner(codeBox, 8)

		local submitBtn = Instance.new("TextButton")
		submitBtn.Size = UDim2.new(0, 86, 0, 36)
		submitBtn.AnchorPoint = Vector2.new(1, 0)
		submitBtn.Position = UDim2.new(1, -12, 0, 50)
		submitBtn.Text = "Redeem"
		submitBtn.Font = FONT_HEAVY
		submitBtn.TextScaled = true
		submitBtn.BackgroundColor3 = PALETTE.successDim
		submitBtn.TextColor3 = PALETTE.textMain
		submitBtn.ZIndex = 21
		submitBtn.Parent = panel
		corner(submitBtn, 8)
		addHoverFeedback(submitBtn)

		local statusLabel = Instance.new("TextLabel")
		statusLabel.BackgroundTransparency = 1
		statusLabel.Size = UDim2.new(1, -24, 0, 24)
		statusLabel.Position = UDim2.new(0, 12, 0, 92)
		statusLabel.Text = ""
		statusLabel.TextColor3 = PALETTE.textDim
		statusLabel.Font = FONT_BODY
		statusLabel.TextScaled = true
		statusLabel.ZIndex = 21
		statusLabel.Parent = panel

		local function submitCode()
			local text = codeBox.Text
			if text == "" then return end
			playSound(SFX.UiTick, 0.4, 1.2)
			remotes.RequestRedeemCode:FireServer(text)
		end
		submitBtn.MouseButton1Click:Connect(submitCode)
		codeBox.FocusLost:Connect(function(enterPressed)
			if enterPressed then submitCode() end
		end)

		-- Friendly wording for every server reason. Raw codes like "AlreadyRedeemed" read as
		-- an error message rather than an answer.
		local REASON_TEXT = {
			Invalid = "That code isn't valid.",
			Expired = "That code has expired.",
			AlreadyRedeemed = "You've already used that code!",
			TooFast = "Slow down a moment...",
			NoProfile = "Something went wrong -- try again.",
		}
		remotes.RedeemCodeResult.OnClientEvent:Connect(function(ok, detail)
			if ok then
				statusLabel.Text = "\u{2705} " .. tostring(detail)
				statusLabel.TextColor3 = PALETTE.success
				codeBox.Text = ""
				playSound(SFX.QuestComplete, 0.5, 1.3)
			else
				statusLabel.Text = REASON_TEXT[detail] or tostring(detail)
				statusLabel.TextColor3 = PALETTE.danger
			end
		end)

		-- Group reward + credits, in a scrolling area so this panel can grow without a
		-- layout rewrite.
		local info = Instance.new("ScrollingFrame")
		info.BackgroundTransparency = 1
		info.Size = UDim2.new(1, -24, 1, -132)
		info.Position = UDim2.new(0, 12, 0, 122)
		info.AutomaticCanvasSize = Enum.AutomaticSize.Y
		info.CanvasSize = UDim2.new(0, 0, 0, 0)
		info.ScrollBarThickness = 5
		info.ZIndex = 21
		info.Parent = panel
		local infoLayout = Instance.new("UIListLayout")
		infoLayout.Padding = UDim.new(0, 8)
		infoLayout.SortOrder = Enum.SortOrder.LayoutOrder
		infoLayout.Parent = info

		local function addSection(order, heading, body, colour)
			local card = Instance.new("Frame")
			card.BackgroundColor3 = PALETTE.panelInset
			card.Size = UDim2.new(1, -6, 0, 78)
			card.LayoutOrder = order
			card.ZIndex = 21
			card.Parent = info
			corner(card, 10)

			local h = Instance.new("TextLabel")
			h.BackgroundTransparency = 1
			h.Size = UDim2.new(1, -16, 0, 22)
			h.Position = UDim2.new(0, 8, 0, 6)
			h.Text = heading
			h.TextColor3 = colour or PALETTE.accentGold
			h.Font = FONT_HEAVY
			h.TextScaled = true
			h.TextXAlignment = Enum.TextXAlignment.Left
			h.ZIndex = 22
			h.Parent = card

			local b = Instance.new("TextLabel")
			b.BackgroundTransparency = 1
			b.Size = UDim2.new(1, -16, 0, 44)
			b.Position = UDim2.new(0, 8, 0, 30)
			b.Text = body
			b.TextColor3 = PALETTE.textDim
			b.Font = FONT_BODY
			b.TextScaled = true
			b.TextWrapped = true
			b.TextXAlignment = Enum.TextXAlignment.Left
			b.ZIndex = 22
			b.Parent = card
		end

		local groupCard = nil
		addSection(1, "\u{1F465} GROUP REWARD",
			"Join the Roblox group for a permanent +10% Sparks bonus. Rejoin the game after joining to claim it.",
			PALETTE.accentBlue)
		addSection(2, "\u{1F195} LATEST UPDATE",
			"Sky Islands world, Creature Sanctuary, trading, promo codes, and inventory search.",
			PALETTE.success)
		addSection(3, "\u{1F6E0}\u{FE0F} COMING SOON",
			"Creature breeding, ranch expansions, seasonal events, and more worlds.",
			PALETTE.warning)
		addSection(4, "\u{2764}\u{FE0F} CREDITS",
			"Creature Ranch -- built with Roblox Studio. Thanks for playing!",
			PALETTE.accentPink)

		codesButton.MouseButton1Click:Connect(function()
			playSound(SFX.UiTick, 0.4, 1.2)
			panel.Visible = not panel.Visible
			if panel.Visible then statusLabel.Text = "" end
		end)
		closeBtn.MouseButton1Click:Connect(function()
			playSound(SFX.UiTick, 0.35, 0.85)
			panel.Visible = false
		end)
	end

end

return ShopUI

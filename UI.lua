-- GoldScribe: UI.lua
-- A small movable window with tabs:
--   Grinding   always shown; grinding numbers plus the session total of
--              everything (with a line each for fishing and gathering)
--   Fishing    appears once you've fished this session (or hold a pole)
--   Gathering  appears once you've mined, picked herbs or skinned
-- It switches to the tab for whatever you last looted. Hover a line for the
-- item breakdown.

local addonName, ns = ...

local frame, lines, startBtn, tabs
local W = 270
local TOP = 52 -- where the first line starts, below the tabs

local function Gold(c) return "|cffffd24d" .. ns.FormatMoney(c) .. "|r" end
local function Grey(s) return "|cff888888" .. s .. "|r" end
local function White(s) return "|cffffffff" .. s .. "|r" end

local function Clock(sec)
	sec = math.floor(sec)
	return ("%d:%02d:%02d"):format(sec / 3600, (sec % 3600) / 60, sec % 60)
end

local TITLES = {
	grind = "Grinding loot",
	opened = "From opened Bloated fish, clams and crates",
	mining = "Mining", herb = "Herbalism", skin = "Skinning",
}

local function ShowBreakdown(owner, key, cooked)
	local sum = ns.Summarize()
	local keys = key == "gather" and ns.GATHER_KEYS or { key }
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	for n, k in ipairs(keys) do
		local b = sum[k]
		if #keys == 1 or b.total > 0 or #b.list > 0 then
			if n > 1 then GameTooltip:AddLine(" ") end
			GameTooltip:AddLine(TITLES[k] or (cooked and "Fish caught, if cooked" or "Fish caught, sold raw"), 1, 1, 1)
			if b.money > 0 or k == "grind" or k == "fish" then
				GameTooltip:AddDoubleLine("Coin looted", ns.FormatMoney(b.money), 1, 1, 1, 1, 0.82, 0.3)
			end
			if #b.list == 0 then
				GameTooltip:AddLine("No items yet.", 0.6, 0.6, 0.6)
			end
			for i, e in ipairs(b.list) do
				local name = C_Item.GetItemInfo(e.id) or ("item " .. e.id)
				local value, how = e.value, e.how
				if cooked and e.cooked then
					value = e.cooked
					how = "cooked: " .. (C_Item.GetItemInfo(e.cookedOut) or "?")
				end
				GameTooltip:AddDoubleLine(("%dx %s"):format(e.count, name), ("%s  |cff888888%s|r"):format(ns.FormatMoney(value), how),
					1, 1, 1, 1, 0.82, 0.3)
				if i >= 20 then
					GameTooltip:AddLine(("...and %d more"):format(#b.list - 20), 0.6, 0.6, 0.6)
					break
				end
			end
		end
	end
	if key == "fish" and not (ns.db.cooking and next(ns.db.cooking)) then
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("Open your Cooking window once so GoldScribe can learn your recipes.", 1, 0.5, 0.25, true)
	end
	GameTooltip:Show()
end

local function MakeLine(key, cooked)
	local b = CreateFrame("Button", nil, frame)
	b:SetSize(W - 20, 16)
	b.left = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	b.left:SetPoint("LEFT")
	b.right = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	b.right:SetPoint("RIGHT")
	if key then
		b:SetScript("OnEnter", function(self) ShowBreakdown(self, key, cooked) end)
		b:SetScript("OnLeave", GameTooltip_Hide)
	end
	return b
end

--------------------------------------------------------------------------
-- Tabs
--------------------------------------------------------------------------

local TAB_ORDER = { "grind", "fish", "gather" }
local TAB_LABEL = { grind = "Grinding", fish = "Fishing", gather = "Gathering" }

local function Available(sum)
	return {
		grind = true,
		fish = sum.hasFishing or ns.IsFishingPoleEquipped(),
		gather = sum.hasGathering,
	}
end

local function SelectTab(key)
	ns.db.tab = key
	if ns.RefreshUI then ns.RefreshUI() end
end

-- Core calls this when you loot something from a different activity.
function ns.OnActivity(a)
	ns.db.tab = a
	if ns.RefreshUI then ns.RefreshUI() end
end

local function LayoutTabs(avail, current)
	local x = 8
	for _, key in ipairs(TAB_ORDER) do
		local t = tabs[key]
		if avail[key] then
			t:ClearAllPoints()
			t:SetPoint("TOPLEFT", x, -26)
			t:Show()
			x = x + t:GetWidth() + 2
			local on = key == current
			t.text:SetTextColor(on and 1 or 0.6, on and 0.82 or 0.6, on and 0 or 0.6)
			t.bg:SetColorTexture(1, 1, 1, on and 0.15 or 0.05)
			t.line:SetShown(on)
		else
			t:Hide()
		end
	end
end

local function MakeTab(key)
	local t = CreateFrame("Button", nil, frame)
	t:SetSize(78, 18)
	t.bg = t:CreateTexture(nil, "BACKGROUND")
	t.bg:SetAllPoints()
	t.line = t:CreateTexture(nil, "ARTWORK")
	t.line:SetColorTexture(1, 0.82, 0, 0.9)
	t.line:SetPoint("BOTTOMLEFT")
	t.line:SetPoint("BOTTOMRIGHT")
	t.line:SetHeight(2)
	t.text = t:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	t.text:SetPoint("CENTER")
	t.text:SetText(TAB_LABEL[key])
	t:SetScript("OnClick", function() SelectTab(key) end)
	return t
end

--------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------

function ns.RefreshUI()
	if not (frame and frame:IsShown()) then return end
	local s = ns.Session()
	local sum = ns.Summarize()
	local ph = sum.perHour

	local avail = Available(sum)
	local tab = ns.db.tab
	if not avail[tab] then tab = "grind" end
	LayoutTabs(avail, tab)

	lines.time.left:SetText(s.running and "Time" or "Time " .. Grey("(paused)"))
	lines.time.right:SetText(Clock(sum.elapsed))

	local order
	if tab == "fish" then
		order = { "time", "fish", "cooked", "opened", "fishTotal" }
	elseif tab == "gather" then
		order = { "time" }
		for _, key in ipairs(ns.GATHER_KEYS) do
			if sum.gathers[key] > 0 or sum[key].total > 0 then order[#order + 1] = key end
		end
		order[#order + 1] = "gatherTotal"
		order[#order + 1] = "perGather"
	else
		order = { "time", "grind", "kills", "perKill" }
		local others = 0
		if sum.fishingTotal > 0 then order[#order + 1] = "sumFish"; others = others + 1 end
		if sum.gatherTotal > 0 then order[#order + 1] = "sumGather"; others = others + 1 end
		if others > 0 then order[#order + 1] = "total" end
	end

	for _, b in pairs(lines) do b:Hide() end
	for i, key in ipairs(order) do
		local b = lines[key]
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", 10, -TOP - (i - 1) * 17)
		b:Show()
	end
	frame:SetHeight(TOP + #order * 17 + 34)

	-- Grinding
	lines.grind.left:SetText("Grinding  " .. Grey(ns.FormatMoney(sum.grind.total)))
	lines.grind.right:SetText(Gold(ph(sum.grind.total)) .. "/h")
	lines.kills.left:SetText("Kills  " .. Grey(tostring(sum.kills)))
	lines.kills.right:SetText(("%d/h"):format(math.floor(ph(sum.kills) + 0.5)))
	lines.perKill.left:SetText("Average per kill")
	lines.perKill.right:SetText(sum.perKill and Gold(sum.perKill) or Grey("no kills yet"))
	lines.sumFish.left:SetText("Fishing  " .. Grey(ns.FormatMoney(sum.fishingTotal)))
	lines.sumFish.right:SetText(Gold(ph(sum.fishingTotal)) .. "/h")
	lines.sumGather.left:SetText("Gathering  " .. Grey(ns.FormatMoney(sum.gatherTotal)))
	lines.sumGather.right:SetText(Gold(ph(sum.gatherTotal)) .. "/h")
	lines.total.left:SetText(White("Session total") .. "  " .. Grey(ns.FormatMoney(sum.total)))
	lines.total.right:SetText(White(ns.FormatMoney(ph(sum.total)) .. "/h"))

	-- Fishing
	lines.fish.left:SetText("Fish caught  " .. Grey(ns.FormatMoney(sum.fish.total)))
	lines.fish.right:SetText(Gold(ph(sum.fish.total)) .. "/h")
	local diff = sum.fish.cookedTotal - sum.fish.total
	local diffText = diff > 0.5 and (" |cff40ff40+" .. ns.FormatMoney(diff) .. "|r") or ""
	lines.cooked.left:SetText("Fish, if cooked" .. diffText)
	lines.cooked.right:SetText(Gold(ph(sum.fish.cookedTotal)) .. "/h")
	lines.opened.left:SetText("Opened (Bloated, clams)  " .. Grey(ns.FormatMoney(sum.opened.total)))
	lines.opened.right:SetText(Gold(ph(sum.opened.total)) .. "/h")
	local cookedExtra = sum.fishingCookedTotal - sum.fishingTotal
	lines.fishTotal.left:SetText(White("Fishing total") .. "  " .. Grey(ns.FormatMoney(sum.fishingTotal))
		.. (cookedExtra > 0.5 and (" |cff40ff40+" .. ns.FormatMoney(cookedExtra) .. " cooked|r") or ""))
	lines.fishTotal.right:SetText(White(ns.FormatMoney(ph(sum.fishingTotal)) .. "/h"))

	-- Gathering
	local unit = { mining = "node", herb = "herb", skin = "skin" }
	for _, key in ipairs(ns.GATHER_KEYS) do
		local n = sum.gathers[key]
		lines[key].left:SetText(("%s  %s"):format(ns.GATHER_NAMES[key],
			Grey(("%d %s%s, %s"):format(n, unit[key], n == 1 and "" or "s", ns.FormatMoney(sum[key].total)))))
		lines[key].right:SetText(Gold(ph(sum[key].total)) .. "/h")
	end
	lines.gatherTotal.left:SetText(White("Gathering total") .. "  " .. Grey(ns.FormatMoney(sum.gatherTotal)))
	lines.gatherTotal.right:SetText(White(ns.FormatMoney(ph(sum.gatherTotal)) .. "/h"))
	lines.perGather.left:SetText("Average per gather  " .. Grey(("%d/h"):format(math.floor(ph(sum.gatherCount) + 0.5))))
	lines.perGather.right:SetText(sum.perGather and Gold(sum.perGather) or Grey("none yet"))

	startBtn:SetText(s.running and "Pause" or "Start")
end

local function Build()
	frame = CreateFrame("Frame", "GoldScribeFrame", UIParent, "BackdropTemplate")
	frame:SetSize(W, 160)
	frame:SetBackdrop({
		bgFile = "Interface/Tooltips/UI-Tooltip-Background",
		edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 14,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	frame:SetBackdropColor(0.05, 0.05, 0.05, 0.85)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetClampedToScreen(true)
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, rel, x, y = self:GetPoint()
		ns.db.pos = { point, rel, x, y }
	end)
	local pos = ns.db.pos
	if pos then
		frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
	else
		frame:SetPoint("RIGHT", UIParent, "RIGHT", -60, 120)
	end

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", 10, -9)
	title:SetText("GoldScribe")

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 2, 2)
	close:SetScale(0.8)
	close:SetScript("OnClick", function() frame:Hide(); ns.db.hidden = true end)

	tabs = {}
	for _, key in ipairs(TAB_ORDER) do tabs[key] = MakeTab(key) end

	lines = {
		time = MakeLine(),
		-- Grinding tab
		grind = MakeLine("grind"),
		kills = MakeLine(),
		perKill = MakeLine("grind"),
		sumFish = MakeLine(),
		sumGather = MakeLine("gather"),
		total = MakeLine(),
		-- Fishing tab
		fish = MakeLine("fish", false),
		cooked = MakeLine("fish", true),
		opened = MakeLine("opened"),
		fishTotal = MakeLine(),
		-- Gathering tab
		mining = MakeLine("mining"),
		herb = MakeLine("herb"),
		skin = MakeLine("skin"),
		gatherTotal = MakeLine("gather"),
		perGather = MakeLine(),
	}

	startBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	startBtn:SetSize(70, 20)
	startBtn:SetPoint("BOTTOMLEFT", 10, 9)
	startBtn:SetScript("OnClick", function()
		if ns.Session().running then ns.Pause() else ns.Start() end
	end)

	local resetBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	resetBtn:SetSize(70, 20)
	resetBtn:SetPoint("LEFT", startBtn, "RIGHT", 6, 0)
	resetBtn:SetText("Reset")
	resetBtn:SetScript("OnClick", ns.Reset)

	frame:SetScript("OnShow", ns.RefreshUI)
	C_Timer.NewTicker(1, ns.RefreshUI) -- keeps the clock and per-hour live
end

function ns.ToggleUI()
	if not frame then Build() end
	if frame:IsShown() then
		frame:Hide()
		ns.db.hidden = true
	else
		ns.db.hidden = false
		frame:Show()
	end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
	if ns.IsFishingPoleEquipped() then ns.db.tab = "fish" end
	Build()
	if ns.db.hidden then frame:Hide() else frame:Show() end
end)

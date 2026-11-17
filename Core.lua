-- GoldScribe: Core.lua
--
-- Gold per hour for grinding and fishing, valued with MarketScribe prices.
--
-- How loot is valued (per item, at the moment you look at the numbers, so
-- prices refresh as MarketScribe scans):
--   Grey (Poor)                        -> vendor price
--   Green weapon/armor that can be DE'd -> disenchant value (MarketScribe),
--                                         falling back to AH, then vendor
--   Everything else, White and up      -> AH price after the 5% cut, or the
--                                         vendor price if that pays more;
--                                         Bind-on-Pickup items can't go to
--                                         the AH, so they use vendor price
--   Containers (clams, bloated fish)   -> 0; their contents are counted when
--                                         you open them
--
-- While fishing, what you get from opening Bloated fish, clams and crates
-- goes in its own "opened" bucket, separate from the fish you catch; the
-- fishing total adds the two together.
--
-- Fishing loot is kept in its own bucket, and for that bucket a second
-- "if cooked" value is worked out from the Cooking recipes you know (open
-- your Cooking window once so GoldScribe can learn them).
--
-- Only loot from loot windows counts: quest rewards, purchases, crafts and
-- mail never touch the numbers. Coin looted is counted too.
--
-- Kills: counted from the corpses you loot (each mob once, so skinning or
-- AoE looting doesn't double count). This client doesn't let addons read
-- the combat log, so a mob whose corpse has nothing on it isn't counted.
-- The grinding total divided by kills gives the average value per kill.
--
-- Gathering: loot from Mining, Herb Gathering and Skinning goes in its own
-- buckets (one per profession), recognised by the gather spell you cast
-- just before the loot window opened. Each gather is counted once.
--
-- The window has tabs: Grinding (always there, and it also shows the
-- session total of everything), plus Fishing and Gathering tabs that only
-- appear once you've done that in the session. It switches to the tab for
-- whatever you last looted, and to Fishing when you equip a Fishing Pole.

local addonName, ns = ...

local PREFIX = "|cffffd24dGoldScribe|r"
local AH_CUT = 0.95
local FISHING_MEMORY = 120 -- seconds after a fishing loot that opened containers still count as fishing
local GATHER_WINDOW = 4 -- seconds between a gather cast and its loot window

-- Gather spells by name -> bucket. Checked against the spell's name, so the
-- rank or spell ID doesn't matter.
local GATHER_SPELLS = {
	["Mining"] = "mining",
	["Herb Gathering"] = "herb", ["Herbalism"] = "herb",
	["Skinning"] = "skin",
}
ns.GATHER_KEYS = { "mining", "herb", "skin" }
ns.GATHER_NAMES = { mining = "Mining", herb = "Herbalism", skin = "Skinning" }

GoldScribeDB = GoldScribeDB or {}
local db

function ns.Print(msg)
	print(PREFIX .. ": " .. msg)
end

local function MS()
	return _G.MarketScribeAPI
end

--------------------------------------------------------------------------
-- Session state
--------------------------------------------------------------------------

-- session = {
--   running, startedAt (time() when last resumed), elapsed (seconds banked),
--   buckets = { grind = { money, items = { [id] = count } }, fish = {...}, opened = {...} }
-- }
local function NewSession()
	return {
		running = false,
		startedAt = nil,
		elapsed = 0,
		kills = 0,
		buckets = {
			grind = { money = 0, items = {} },
			fish = { money = 0, items = {} },
			opened = { money = 0, items = {} },
			mining = { money = 0, items = {} },
			herb = { money = 0, items = {} },
			skin = { money = 0, items = {} },
		},
		gathers = { mining = 0, herb = 0, skin = 0 },
	}
end

-- Which tab the last thing you looted belongs to: "grind", "fish" or "gather".
ns.activity = nil
function ns.SetActivity(a)
	if ns.activity ~= a then
		ns.activity = a
		if ns.OnActivity then ns.OnActivity(a) end
	end
end

function ns.Session()
	return db.session
end

function ns.Elapsed()
	local s = db.session
	local t = s.elapsed
	if s.running and s.startedAt then
		t = t + (time() - s.startedAt)
	end
	return t
end

function ns.Start()
	local s = db.session
	if s.running then return end
	s.running = true
	s.userPaused = nil
	s.startedAt = time()
	ns.Print("tracking started.")
	if ns.RefreshUI then ns.RefreshUI() end
end

function ns.Pause()
	local s = db.session
	if not s.running then return end
	s.elapsed = ns.Elapsed()
	s.userPaused = true
	s.running = false
	s.startedAt = nil
	ns.Print("paused.")
	if ns.RefreshUI then ns.RefreshUI() end
end

function ns.Reset()
	local s = db.session
	-- keep a short history of finished sessions
	if ns.Elapsed() > 60 then
		local summary = ns.Summarize()
		db.history = db.history or {}
		table.insert(db.history, 1, {
			ended = time(), elapsed = ns.Elapsed(),
			grind = summary.grind.total, fish = summary.fish.total, fishCooked = summary.fish.cookedTotal,
			opened = summary.opened.total, gather = summary.gatherTotal,
			gathers = summary.gatherCount,
			kills = summary.kills,
		})
		while #db.history > 20 do table.remove(db.history) end
	end
	db.session = NewSession()
	ns.Print("session reset.")
	if ns.RefreshUI then ns.RefreshUI() end
end

--------------------------------------------------------------------------
-- Item valuation
--------------------------------------------------------------------------

local function IsSecret(v)
	return issecretvalue and issecretvalue(v)
end

local openableCache = {}
local function IsOpenable(itemID)
	if openableCache[itemID] ~= nil then
		return openableCache[itemID]
	end
	local result = false
	if C_TooltipInfo and C_TooltipInfo.GetItemByID then
		local ok, data = pcall(C_TooltipInfo.GetItemByID, itemID)
		if ok and data and data.lines then
			for _, line in ipairs(data.lines) do
				local t = line.leftText
				if t and (t == ITEM_OPENABLE or t:find("Right Click to Open", 1, true)) then
					result = true
					break
				end
			end
			openableCache[itemID] = result
		end
	end
	return result
end

local function VendorPrice(itemID)
	return select(11, C_Item.GetItemInfo(itemID)) or 0
end

-- What one item sells for: AH after cut or vendor, whichever pays more.
-- BoP items can't be listed, so they're vendor-only. Returns value, how.
local function SellValue(itemID)
	local vendor = VendorPrice(itemID)
	local bind = select(14, C_Item.GetItemInfo(itemID))
	local api = MS()
	if bind ~= 1 and api and api.GetMarketPrice then
		local ah = api.GetMarketPrice(itemID)
		if ah and ah * AH_CUT > vendor then
			return ah * AH_CUT, "AH"
		end
		if not ah and api.QueueItem then
			api.QueueItem(itemID) -- get it priced next time the AH is open
		end
	end
	return vendor, "vendor"
end

-- Returns value per item (copper), and a short label for how it was valued.
function ns.ItemValue(itemID)
	local name, _, quality, _, _, _, _, _, _, _, _, classID = C_Item.GetItemInfo(itemID)
	if not name then
		C_Item.RequestLoadItemDataByID(itemID)
		return 0, "loading"
	end
	if IsOpenable(itemID) then
		return 0, "opened"
	end
	if quality == 0 then
		return VendorPrice(itemID), "vendor"
	end
	local api = MS()
	local isGear = classID == 2 or classID == 4
	if quality == 2 and isGear and api and api.GetDisenchantEV
		and not (api.IsNotDisenchantable and api.IsNotDisenchantable(itemID)) then
		local de = api.GetDisenchantEV(itemID)
		if de and de > 0 then
			return de, "DE"
		end
	end
	return SellValue(itemID)
end

--------------------------------------------------------------------------
-- Cooking: learn which recipes use which raw fish
--------------------------------------------------------------------------

-- db.cooking[rawItemID] = { { out = id, need = qty, yield = avg, other = { [id] = qty } }, ... }

local function LearnCooking()
	if not (C_TradeSkillUI and C_TradeSkillUI.GetBaseProfessionInfo and C_TradeSkillUI.GetAllRecipeIDs) then
		return
	end
	local ok, prof = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
	if not (ok and prof and prof.professionName == (PROFESSIONS_COOKING or "Cooking")) then
		return
	end
	local api = MS()
	if not (api and api.GetRecipeOutputItemID) then
		return
	end
	local learned = {}
	for _, recipeID in ipairs(C_TradeSkillUI.GetAllRecipeIDs() or {}) do
		local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
		local schematic = info and info.learned and C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
		local out = schematic and api.GetRecipeOutputItemID(recipeID, schematic)
		if out and schematic.reagentSlotSchematics then
			local reagents = {}
			for _, slot in ipairs(schematic.reagentSlotSchematics) do
				local isBasic = slot.reagentType == Enum.CraftingReagentType.Basic
				if (isBasic or slot.required) and slot.reagents and slot.reagents[1] then
					reagents[slot.reagents[1].itemID] = (reagents[slot.reagents[1].itemID] or 0) + (slot.quantityRequired or 1)
				end
			end
			local yield = ((schematic.quantityMin or 1) + (schematic.quantityMax or schematic.quantityMin or 1)) / 2
			for rawID, need in pairs(reagents) do
				local other = {}
				for id, q in pairs(reagents) do
					if id ~= rawID then other[id] = q end
				end
				learned[rawID] = learned[rawID] or {}
				table.insert(learned[rawID], { out = out, need = need, yield = yield, other = other })
			end
		end
	end
	local count = 0
	for _ in pairs(learned) do count = count + 1 end
	local before = db.cookingCount
	db.cooking = learned
	db.cookingCount = count
	db.cookingLearnedAt = time()
	if count ~= before then
		ns.Print(("learned %d Cooking ingredients for the \"if cooked\" fishing value."):format(count))
	end
end

-- Best value of one raw item if cooked (copper per raw item), or nil if no
-- known recipe uses it.
function ns.CookedValue(rawID)
	local options = db.cooking and db.cooking[rawID]
	if not options then
		return nil
	end
	local api = MS()
	local best, bestOut
	for _, r in ipairs(options) do
		local sell = SellValue(r.out)
		local cost = 0
		for id, q in pairs(r.other) do
			local p = api and api.GetPrice and api.GetPrice(id) or VendorPrice(id)
			cost = cost + (p or 0) * q
		end
		local perRaw = (sell * r.yield - cost) / r.need
		if not best or perRaw > best then
			best, bestOut = perRaw, r.out
		end
	end
	return best, bestOut
end

--------------------------------------------------------------------------
-- Totals
--------------------------------------------------------------------------

-- Returns { grind = {...}, fish = {...}, total, perHour, elapsed }
function ns.Summarize()
	local s = db.session
	local out = { elapsed = ns.Elapsed() }
	for key, b in pairs(s.buckets) do
		local items, cooked, list = 0, 0, {}
		for id, count in pairs(b.items) do
			local each, how = ns.ItemValue(id)
			local value = each * count
			items = items + value
			local entry = { id = id, count = count, value = value, how = how }
			if key == "fish" then
				local c, cookedOut = ns.CookedValue(id)
				if c and c > each then
					entry.cooked = c * count
					entry.cookedOut = cookedOut
					cooked = cooked + c * count
				else
					cooked = cooked + value
				end
			end
			table.insert(list, entry)
		end
		table.sort(list, function(a, b2) return a.value > b2.value end)
		out[key] = {
			money = b.money, items = items, total = b.money + items,
			cookedTotal = b.money + cooked, list = list,
		}
	end
	out.opened = out.opened or { money = 0, items = 0, total = 0, cookedTotal = 0, list = {} }
	out.fishingTotal = out.fish.total + out.opened.total
	out.fishingCookedTotal = out.fish.cookedTotal + out.opened.total
	out.gatherTotal, out.gatherCount = 0, 0
	out.gathers = {}
	for _, key in ipairs(ns.GATHER_KEYS) do
		out[key] = out[key] or { money = 0, items = 0, total = 0, cookedTotal = 0, list = {} }
		out.gatherTotal = out.gatherTotal + out[key].total
		out.gathers[key] = s.gathers and s.gathers[key] or 0
		out.gatherCount = out.gatherCount + out.gathers[key]
	end
	out.perGather = out.gatherCount > 0 and out.gatherTotal / out.gatherCount or nil
	out.hasFishing = out.fishingTotal > 0 or next(s.buckets.fish.items) ~= nil or next(s.buckets.opened.items) ~= nil
	out.hasGathering = out.gatherCount > 0 or out.gatherTotal > 0
	out.total = out.grind.total + out.fishingTotal + out.gatherTotal
	out.kills = s.kills or 0
	out.perKill = out.kills > 0 and out.grind.total / out.kills or nil
	local hours = out.elapsed / 3600
	out.perHour = function(v) return hours > 0 and v / hours or 0 end
	return out
end

function ns.FormatMoney(c)
	local api = MS()
	if api and api.FormatMoney then
		return api.FormatMoney(c)
	end
	c = math.floor((c or 0) + 0.5)
	if c >= 10000 then return ("%.2fg"):format(c / 10000) end
	if c >= 100 then return ("%.2fs"):format(c / 100) end
	return c .. "c"
end

--------------------------------------------------------------------------
-- Loot capture
--------------------------------------------------------------------------

local lootOpen, lootIsFishing, lootIsContainer = false, false, false
local lootGather -- "mining"/"herb"/"skin" when this loot window is from gathering
local lootClosing = false
local lootSerial, gatherCounted = 0, false
local lastFishingLoot = 0
local lastGather -- { key, t } from the last gather spell you cast

-- Turn a GlobalStrings format like "You receive loot: %sx%d." into a pattern.
local function ToPattern(fmt)
	if not fmt then return nil end
	local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
	p = p:gsub("%%%%s", "(.+)"):gsub("%%%%d", "(%%d+)")
	return "^" .. p .. "$"
end

local LOOT_PATTERNS = {
	ToPattern(LOOT_ITEM_SELF_MULTIPLE),
	ToPattern(LOOT_ITEM_SELF),
	ToPattern(LOOT_ITEM_PUSHED_SELF_MULTIPLE),
	ToPattern(LOOT_ITEM_PUSHED_SELF),
}

local function FishingContext()
	return (time() - lastFishingLoot) <= FISHING_MEMORY or (ns.IsFishingPoleEquipped and ns.IsFishingPoleEquipped())
end

local function CurrentBucket()
	if lootIsFishing then
		return "fish"
	end
	if lootGather then
		return lootGather
	end
	-- a Bloated fish, clam or crate opened while you're fishing
	if lootIsContainer and FishingContext() and not UnitAffectingCombat("player") then
		return "opened"
	end
	return "grind"
end

-- Did this loot window come from opening an item (rather than a corpse/node)?
local function LootFromItem()
	if not (GetNumLootItems and GetLootSourceInfo) then
		return FishingContext() -- can't tell; guess from context
	end
	for slot = 1, GetNumLootItems() or 0 do
		local ok, guid = pcall(GetLootSourceInfo, slot)
		if ok and type(guid) == "string" and not (issecretvalue and issecretvalue(guid)) then
			return guid:find("^Item") ~= nil
		end
	end
	return false
end

local function Activity(bucket)
	if bucket == "fish" or bucket == "opened" then return "fish" end
	if ns.GATHER_NAMES[bucket] then return "gather" end
	return "grind"
end

local function OnLootMessage(msg)
	if not (db.session.running and lootOpen) then
		return
	end
	for _, pattern in ipairs(LOOT_PATTERNS) do
		if pattern then
			local link, qty = msg:match(pattern)
			if link then
				local id = tonumber(link:match("item:(%d+)"))
				if id then
					local bucket = CurrentBucket()
					local items = db.session.buckets[bucket].items
					items[id] = (items[id] or 0) + (tonumber(qty) or 1)
					ns.SetActivity(Activity(bucket))
					if ns.RefreshUI then ns.RefreshUI() end
				end
				return
			end
		end
	end
end

local function ParseMoney(msg)
	local total = 0
	local g = msg:match("(%d+) " .. (GOLD_AMOUNT and GOLD_AMOUNT:match("%%d (.+)") or "Gold"))
	local s = msg:match("(%d+) " .. (SILVER_AMOUNT and SILVER_AMOUNT:match("%%d (.+)") or "Silver"))
	local c = msg:match("(%d+) " .. (COPPER_AMOUNT and COPPER_AMOUNT:match("%%d (.+)") or "Copper"))
	total = (tonumber(g) or 0) * 10000 + (tonumber(s) or 0) * 100 + (tonumber(c) or 0)
	return total
end

local function OnMoneyMessage(msg)
	if not db.session.running then
		return
	end
	local amount = ParseMoney(msg)
	if amount > 0 then
		local bucket = CurrentBucket()
		local b = db.session.buckets[bucket]
		b.money = b.money + amount
		ns.SetActivity(Activity(bucket))
		if ns.RefreshUI then ns.RefreshUI() end
	end
end

--------------------------------------------------------------------------
-- Fishing Pole check
--------------------------------------------------------------------------

local FISHING_POLE_SUBCLASS = (Enum and Enum.ItemWeaponSubclass and Enum.ItemWeaponSubclass.Fishingpole) or 20

function ns.IsFishingPoleEquipped()
	local id = GetInventoryItemID("player", INVSLOT_MAINHAND or 16)
	if not id then return false end
	local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(id)
	return classID == 2 and subClassID == FISHING_POLE_SUBCLASS
end

--------------------------------------------------------------------------
-- Gathering casts
--------------------------------------------------------------------------

local function SpellName(spellID)
	if C_Spell and C_Spell.GetSpellName then
		local ok, n = pcall(C_Spell.GetSpellName, spellID)
		if ok and n then return n end
	end
	if GetSpellInfo then return (GetSpellInfo(spellID)) end
end

local function OnSpellSucceeded(unit, spellID)
	if unit ~= "player" or not spellID or IsSecret(spellID) then return end
	local name = SpellName(spellID)
	local key = name and GATHER_SPELLS[name]
	if key then lastGather = { key = key, t = GetTime() } end
	ns.lastSpell = name -- for /gph debug
end

-- Gather spell that this loot window belongs to, if any.
local function RecentGather()
	if lastGather and GetTime() - lastGather.t <= GATHER_WINDOW then
		return lastGather.key
	end
end

--------------------------------------------------------------------------
-- Kill counting
--------------------------------------------------------------------------

-- looted[guid] = time first looted, so each corpse counts once
local looted = {}

-- Called when a (non-fishing) loot window opens. Counts each creature
-- corpse in it the first time it's looted.
local function CountLootedCorpses()
	if not (GetNumLootItems and GetLootSourceInfo) then return end
	local s = db.session
	local new = 0
	for slot = 1, GetNumLootItems() or 0 do
		local ok, sources = pcall(function() return { GetLootSourceInfo(slot) } end)
		if ok then
			for i = 1, #sources, 2 do
				local guid = sources[i]
				if type(guid) == "string" and not IsSecret(guid) and not looted[guid]
					and (guid:find("^Creature") or guid:find("^Vehicle")) then
					looted[guid] = time()
					new = new + 1
				end
			end
		end
	end
	if new > 0 and s.running then
		s.kills = (s.kills or 0) + new
		if ns.RefreshUI then ns.RefreshUI() end
	end
end

--------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------

SLASH_GOLDSCRIBE1 = "/gph"
SLASH_GOLDSCRIBE2 = "/goldscribe"
SlashCmdList.GOLDSCRIBE = function(msg)
	msg = (msg or ""):lower():match("^%s*(.-)%s*$")
	if msg == "" or msg == "show" then
		ns.ToggleUI()
	elseif msg == "start" then
		ns.Start()
	elseif msg == "pause" or msg == "stop" then
		ns.Pause()
	elseif msg == "reset" then
		ns.Reset()
	elseif msg == "history" then
		if not (db.history and #db.history > 0) then
			ns.Print("no finished sessions yet.")
			return
		end
		ns.Print("last sessions:")
		for i, h in ipairs(db.history) do
			local hours = math.max(h.elapsed, 1) / 3600
			local kills = ""
			if h.kills and h.kills > 0 then
				kills = (", %d kills (%s each)"):format(h.kills, ns.FormatMoney(h.grind / h.kills))
			end
			local opened = h.opened and (", opened %s/h"):format(ns.FormatMoney(h.opened / hours)) or ""
			local gather = (h.gather and h.gather > 0) and (", gathering %s/h (%d gathers)"):format(ns.FormatMoney(h.gather / hours), h.gathers or 0) or ""
			print(("  %d. %s, %s: grind %s/h%s, fish %s/h (cooked %s/h)%s%s"):format(i, date("%d %b %H:%M", h.ended),
				SecondsToTime and SecondsToTime(h.elapsed) or (math.floor(h.elapsed / 60) .. "m"),
				ns.FormatMoney(h.grind / hours), kills, ns.FormatMoney(h.fish / hours), ns.FormatMoney(h.fishCooked / hours), opened, gather))
			if i >= 10 then break end
		end
	elseif msg == "debug" then
		local sum = ns.Summarize()
		ns.Print(("last spell cast: %s; gathers this session: mining %d, herbs %d, skinning %d; tab: %s"):format(
			tostring(ns.lastSpell), sum.gathers.mining, sum.gathers.herb, sum.gathers.skin, tostring(db.tab)))
	elseif msg == "items" then
		local sum = ns.Summarize()
		local titles = { grind = "grinding loot:", fish = "fish caught:", opened = "from opened Bloated fish/clams/crates:",
			mining = "mining:", herb = "herbalism:", skin = "skinning:" }
		for _, key in ipairs({ "grind", "fish", "opened", "mining", "herb", "skin" }) do
			local b = sum[key]
			if #b.list > 0 then
				ns.Print(titles[key])
				for i, e in ipairs(b.list) do
					local name = C_Item.GetItemInfo(e.id) or ("item " .. e.id)
					local line = ("  %dx %s: %s (%s)"):format(e.count, name, ns.FormatMoney(e.value), e.how)
					if e.cooked then
						line = line .. (" -> cooked %s"):format(ns.FormatMoney(e.cooked))
					end
					print(line)
					if i >= 15 then break end
				end
			end
		end
	else
		ns.Print("/gph (window), /gph start, /gph pause, /gph reset, /gph items, /gph history, /gph debug")
	end
end

--------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("LOOT_READY")
frame:RegisterEvent("LOOT_OPENED")
frame:RegisterEvent("LOOT_CLOSED")
frame:RegisterEvent("CHAT_MSG_LOOT")
frame:RegisterEvent("CHAT_MSG_MONEY")
frame:RegisterEvent("TRADE_SKILL_SHOW")
frame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
frame:SetScript("OnEvent", function(_, event, a, b, c)
	if event == "ADDON_LOADED" and a == addonName then
		GoldScribeDB = GoldScribeDB or {}
		db = GoldScribeDB
		db.session = db.session or NewSession()
		local bk = db.session.buckets
		for _, key in ipairs({ "opened", "mining", "herb", "skin" }) do
			bk[key] = bk[key] or { money = 0, items = {} }
		end
		db.session.gathers = db.session.gathers or { mining = 0, herb = 0, skin = 0 }
		-- a session that was running when you logged out resumes paused
		if db.session.running then
			db.session.elapsed = db.session.elapsed + math.max(0, (db.lastSeen or time()) - (db.session.startedAt or time()))
			db.session.running = false
			db.session.startedAt = nil
		end
		if db.autoStart == nil then db.autoStart = true end
		ns.db = db
	elseif event == "LOOT_READY" or event == "LOOT_OPENED" then
		-- LOOT_READY and LOOT_OPENED both fire for one window: work out where
		-- the loot came from only once, on the first of them
		local newWindow = not lootOpen or lootClosing
		lootOpen, lootClosing = true, false
		lootSerial = lootSerial + 1
		if newWindow then
			gatherCounted = false
			lootIsFishing = IsFishingLoot and IsFishingLoot() or false
			lootGather = not lootIsFishing and RecentGather() or nil
			lootIsContainer = not lootIsFishing and not lootGather and LootFromItem()
		end
		if lootIsFishing then
			lastFishingLoot = time()
		end
		-- start automatically on the first loot of a session
		if db.autoStart and not db.session.running and not db.session.userPaused then
			ns.Start()
		end
		if lootGather then
			if not gatherCounted and db.session.running then
				gatherCounted = true
				lastGather = nil -- one cast, one gather
				local g = db.session.gathers
				g[lootGather] = (g[lootGather] or 0) + 1
				ns.SetActivity("gather")
				if ns.RefreshUI then ns.RefreshUI() end
			end
		elseif not lootIsFishing then
			CountLootedCorpses()
		end
	elseif event == "LOOT_CLOSED" then
		-- chat loot messages can arrive just after the window closes; a new
		-- loot window opening in that second keeps it open
		lootClosing = true
		local serial = lootSerial
		C_Timer.After(1, function()
			if lootSerial == serial then lootOpen, lootClosing = false, false end
		end)
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		OnSpellSucceeded(a, c)
	elseif event == "CHAT_MSG_LOOT" then
		OnLootMessage(a)
	elseif event == "CHAT_MSG_MONEY" then
		OnMoneyMessage(a)
	elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_LIST_UPDATE" then
		LearnCooking()
	elseif event == "PLAYER_EQUIPMENT_CHANGED" then
		local pole = ns.IsFishingPoleEquipped()
		if pole then ns.SetActivity("fish")
		elseif ns.activity == "fish" then ns.SetActivity("grind") end
		if ns.RefreshUI then ns.RefreshUI() end
	end
end)

-- remember when we were last online, so an unpaused session doesn't count
-- logged-out time
C_Timer.NewTicker(30, function()
	if db then db.lastSeen = time() end
	-- corpses despawn long before this, so old entries can go
	local now = time()
	for guid, t in pairs(looted) do
		if now - t > 1800 then looted[guid] = nil end
	end
end)

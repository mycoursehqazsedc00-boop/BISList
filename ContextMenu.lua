-- BISList Context Menu: Item link click hooking
BISListContextMenu = {}

local currentItemLink = nil
local lastHoveredItemLink = nil
local lastHoveredItemName = nil
local lastHoveredSourceInfo = nil
local hideTimer = 0

-- Debug mode flag (off by default to reduce spam)
local DEBUG_MODE = false

-- Debug logging helper
local function DebugLog(msg)
	if DEBUG_MODE then
		DEFAULT_CHAT_FRAME:AddMessage("|cffFFFF00[BISList Debug]|r " .. msg)
	end
end

-- Optional ClassicAPI support: RequestLoadItemDataByID asks the server for
-- an item's data when it isn't in the local cache yet, and fires
-- ITEM_DATA_LOAD_RESULT when it lands. Without this, adding an item the
-- client has never seen (common with AtlasLoot entries for gear you don't
-- own) makes GetItemInfo return nil, GetItemSlot return nil, and the add
-- silently fail with nothing but a debug line.
local hasClassicItemLoad = (type(C_Item) == "table"
	and type(C_Item.RequestLoadItemDataByID) == "function")

-- Items we asked the server for, waiting on ITEM_DATA_LOAD_RESULT, mapped
-- to the info needed to finish the add once the data arrives.
local pendingItemLoads = {}

if hasClassicItemLoad then
	local loadFrame = CreateFrame("Frame")
	loadFrame:RegisterEvent("ITEM_DATA_LOAD_RESULT")
	loadFrame:SetScript("OnEvent", function()
		if event ~= "ITEM_DATA_LOAD_RESULT" then return end
		local itemId = arg1
		local success = arg2
		local pending = itemId and pendingItemLoads[itemId]
		if not pending then return end
		pendingItemLoads[itemId] = nil

		if not success then
			DEFAULT_CHAT_FRAME:AddMessage("|cffff0000BISList:|r Could not load item data for item " ..
				tostring(itemId) .. " - try again once you've seen the item in-game.")
			return
		end

		-- Data is cached now, so the normal path will resolve the slot.
		local slotId = BISListContextMenu:GetItemSlot(pending.link)
		if slotId then
			BISList:AddItem(pending.link, slotId, pending.name, pending.source)
			if BISListUI and BISListUI.Refresh and BISListUI:IsVisible() then
				BISListUI:Refresh()
			end
		else
			-- Still nil after loading means it's a one-hander needing the
			-- Main/Off Hand prompt, or genuinely not equippable.
			local _, _, _, _, _, _, _, itemEquipLoc = GetItemInfo(itemId)
			if itemEquipLoc == "INVTYPE_WEAPON" then
				BISListContextMenu:ShowWeaponSlotDialog(pending.link, pending.name, pending.source)
			else
				DEFAULT_CHAT_FRAME:AddMessage("|cffff0000BISList:|r That item doesn't appear to be equippable.")
			end
		end
	end)
end

-- Ask the server for an item's data and finish the add when it arrives.
-- Returns true if a request was started (caller should stop and wait).
function BISListContextMenu:RequestItemThenAdd(itemLink, itemName, sourceInfo)
	if not hasClassicItemLoad then return false end
	local itemId = BISList:GetItemIdFromLink(itemLink)
	if not itemId then return false end
	if pendingItemLoads[itemId] then return true end -- already waiting

	-- The pending entry must be set BEFORE the request, because
	-- ITEM_DATA_LOAD_RESULT fires synchronously when the item turns out to
	-- already be cached - the handler would otherwise see no pending entry
	-- and drop the add on the floor.
	pendingItemLoads[itemId] = {link = itemLink, name = itemName, source = sourceInfo}
	local started = C_Item.RequestLoadItemDataByID(itemId)
	if started then
		-- If the event already fired synchronously, the handler has cleared
		-- the entry and finished the add, so don't claim it's still loading.
		if pendingItemLoads[itemId] then
			DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00BISList:|r Loading item data, adding shortly...")
		end
		return true
	end

	pendingItemLoads[itemId] = nil
	return false
end

-- Get the equipment slot for an item
function BISListContextMenu:GetItemSlot(itemLink)
	if not itemLink then return nil end

	-- Extract item ID from link
	local _, _, itemId = string.find(itemLink, "item:(%d+)")
	if not itemId then
		DebugLog("GetItemSlot: Failed to extract item ID from link")
		return nil
	end

	DebugLog("GetItemSlot: Extracted item ID: " .. itemId)

	-- Correct order for vanilla 1.12.1:
	-- itemName, itemLink, itemRarity, itemLevel, itemType, itemSubType, itemStackCount, itemEquipLoc, itemTexture
	local itemName, itemLink2, itemRarity, itemLevel, itemType, itemSubType, itemStackCount, itemEquipLoc, itemTexture = GetItemInfo(itemId)

	DebugLog("GetItemSlot: GetItemInfo results:")
	DebugLog("  itemName: " .. tostring(itemName))
	DebugLog("  itemEquipLoc: " .. tostring(itemEquipLoc))
	DebugLog("  itemType: " .. tostring(itemType))
	DebugLog("  itemSubType: " .. tostring(itemSubType))

	if not itemEquipLoc or itemEquipLoc == "" then
		DebugLog("GetItemSlot: No equipment location (not equippable or not cached)")
		return nil
	end

	-- INVTYPE_WEAPON means one-hand weapon - it can go in either Main Hand
	-- or Off Hand and we can't auto-decide which, so return nil here and
	-- let the caller prompt (see BISList_AddHoveredItem's fallback branch
	-- and ShowWeaponSlotDialog below).
	--
	-- NOTE: this used to return the standalone "One-Hand" slot (19)
	-- directly, which silently bypassed the documented Main Hand / Off
	-- Hand prompt for every one-hander added via ALT-B, and meant the
	-- item's acquisition status was tracked separately from wherever it
	-- actually gets equipped. Existing items already saved under slot 19
	-- are untouched and still display correctly (BISList.Slots keeps that
	-- entry) - only where NEW one-handers get filed has changed.
	if itemEquipLoc == "INVTYPE_WEAPON" then
		DebugLog("GetItemSlot: INVTYPE_WEAPON detected, deferring to Main/Off Hand prompt")
		return nil
	end

	-- Map itemEquipLoc to slot IDs
	local slotMap = {
		["INVTYPE_HEAD"] = 1,
		["INVTYPE_NECK"] = 2,
		["INVTYPE_SHOULDER"] = 3,
		["INVTYPE_BODY"] = 4,
		["INVTYPE_CHEST"] = 5,
		["INVTYPE_ROBE"] = 5,
		["INVTYPE_WAIST"] = 6,
		["INVTYPE_LEGS"] = 7,
		["INVTYPE_FEET"] = 8,
		["INVTYPE_WRIST"] = 9,
		["INVTYPE_HAND"] = 10,
		["INVTYPE_FINGER"] = 11,
		["INVTYPE_TRINKET"] = 13,
		["INVTYPE_CLOAK"] = 15,
		["INVTYPE_2HWEAPON"] = 16,
		["INVTYPE_WEAPONMAINHAND"] = 16,
		["INVTYPE_WEAPONOFFHAND"] = 17,
		["INVTYPE_SHIELD"] = 17,
		["INVTYPE_HOLDABLE"] = 17,
		["INVTYPE_RANGED"] = 18,
		["INVTYPE_RANGEDRIGHT"] = 18,
		["INVTYPE_THROWN"] = 18,
		["INVTYPE_RELIC"] = 18,
	}

	local slotId = slotMap[itemEquipLoc]
	DebugLog("GetItemSlot: Mapped to slot ID: " .. tostring(slotId))
	return slotId
end

-- Show slot selection dialog
function BISListContextMenu:ShowSlotSelectionDialog(itemLink)
	StaticPopupDialogs["BISLIST_SELECT_SLOT"] = {
		text = "Select equipment slot for " .. itemLink .. ":",
		button1 = "Cancel",
		hasEditBox = 0,
		timeout = 0,
		whileDead = 1,
		hideOnEscape = 1,
		OnShow = function()
			-- Create buttons for each slot
			local yOffset = -60
			for i, slot in ipairs(BISList.Slots) do
				local button = CreateFrame("Button", "BISListSlotButton"..i, this, "UIPanelButtonTemplate")
				button:SetWidth(180)
				button:SetHeight(25)
				button:SetPoint("TOP", 0, yOffset)
				button:SetText(slot.name)
				button:SetScript("OnClick", function()
					BISListContextMenu:AddItemToSlot(itemLink, slot.id)
					this:GetParent():Hide()
				end)
				yOffset = yOffset - 30
			end
		end,
		OnHide = function()
			-- Clean up buttons
			for i = 1, 17 do
				local button = getglobal("BISListSlotButton"..i)
				if button then
					button:Hide()
					button:SetParent(nil)
				end
			end
		end
	}
	StaticPopup_Show("BISLIST_SELECT_SLOT")
end

-- Show weapon slot selection dialog (Main Hand / Off Hand)
-- Used for INVTYPE_WEAPON items that can go in either hand
local pendingWeaponItemLink = nil
local pendingWeaponItemName = nil
local pendingWeaponSourceInfo = nil

function BISListContextMenu:ShowWeaponSlotDialog(itemLink, itemName, sourceInfo)
	pendingWeaponItemLink = itemLink
	pendingWeaponItemName = itemName
	pendingWeaponSourceInfo = sourceInfo

	StaticPopupDialogs["BISLIST_WEAPON_SLOT"] = {
		text = "Select slot for one-hand weapon:",
		button1 = "Main Hand",
		button2 = "Off Hand",
		button3 = "Cancel",
		OnAccept = function()
			-- Main Hand (slot 16)
			local itemId = BISList:GetItemIdFromLink(pendingWeaponItemLink)
			if itemId then
				BISList:AddItem(pendingWeaponItemLink, 16, pendingWeaponItemName, pendingWeaponSourceInfo)
				if BISListUI and BISListUI.Refresh and BISListUI:IsVisible() then
					BISListUI:Refresh()
				end
			end
		end,
		OnCancel = function()
			-- Off Hand (slot 17)
			local itemId = BISList:GetItemIdFromLink(pendingWeaponItemLink)
			if itemId then
				BISList:AddItem(pendingWeaponItemLink, 17, pendingWeaponItemName, pendingWeaponSourceInfo)
				if BISListUI and BISListUI.Refresh and BISListUI:IsVisible() then
					BISListUI:Refresh()
				end
			end
		end,
		OnAlt = function()
			-- Cancel - do nothing
		end,
		timeout = 0,
		whileDead = 1,
		hideOnEscape = 1
	}
	StaticPopup_Show("BISLIST_WEAPON_SLOT")
end

-- Add item to a specific slot with notes dialog
function BISListContextMenu:AddItemToSlot(itemLink, slotId)
	StaticPopupDialogs["BISLIST_ADD_NOTES"] = {
		text = "Add notes for " .. itemLink .. ":",
		button1 = "Add",
		button2 = "Skip",
		hasEditBox = 1,
		maxLetters = 100,
		OnAccept = function()
			local editBox = getglobal(this:GetParent():GetName().."EditBox")
			local notes = editBox:GetText()
			BISList:AddItem(itemLink, slotId, notes)
			if BISListUI and BISListUI.Refresh then
				BISListUI:Refresh()
			end
		end,
		OnCancel = function()
			-- Add without notes
			BISList:AddItem(itemLink, slotId, "")
			if BISListUI and BISListUI.Refresh then
				BISListUI:Refresh()
			end
		end,
		timeout = 0,
		whileDead = 1,
		hideOnEscape = 1
	}
	StaticPopup_Show("BISLIST_ADD_NOTES")
end

-- Handle context menu click
function BISListContextMenu:OnMenuClick(itemLink)
	if not itemLink then return end

	-- Try to auto-detect slot
	local slotId = self:GetItemSlot(itemLink)
	if slotId then
		-- Show notes dialog
		self:AddItemToSlot(itemLink, slotId)
	else
		-- GetItemSlot returns nil both for "couldn't determine" and for
		-- one-hand weapons (which need an explicit Main/Off Hand choice) -
		-- tell those two cases apart here so weapons get the dedicated
		-- dialog instead of the generic full slot list.
		local itemId = BISList:GetItemIdFromLink(itemLink)
		local _, _, _, _, _, _, _, itemEquipLoc = GetItemInfo(itemId or "")
		if itemEquipLoc == "INVTYPE_WEAPON" then
			self:ShowWeaponSlotDialog(itemLink, nil, nil)
		else
			self:ShowSlotSelectionDialog(itemLink)
		end
	end
end

-- Shared helper to add or toggle an item in BISList from any click or keybind
function BISListContextMenu:AddOrToggleItem(itemLink, itemName, sourceInfo)
	if not itemLink then return false end

	if itemName == "" then
		itemName = nil
	end

	local itemId = BISList:GetItemIdFromLink(itemLink)
	if not itemId then
		DebugLog("AddOrToggleItem: Could not extract item ID from link: " .. tostring(itemLink))
		return false
	end

	local slotId = self:GetItemSlot(itemLink)
	if slotId then
		if BISList:ItemExistsInSlot(slotId, itemId) then
			DebugLog("AddOrToggleItem: Item exists, removing")
			BISList:RemoveItem(slotId, itemId)
		else
			if not itemName or string.find(itemName, "^item:") then
				if AtlasLootTooltip and AtlasLootTooltip:IsVisible() and AtlasLootTooltipTextLeft1 then
					itemName = AtlasLootTooltipTextLeft1:GetText()
				end
				if not itemName or itemName == "" then
					local cachedName = GetItemInfo(itemId)
					if cachedName then
						itemName = cachedName
					end
				end
			end
			if itemName == "" then itemName = nil end

			DebugLog("AddOrToggleItem: Adding item " .. tostring(itemId) .. " to slot " .. tostring(slotId))
			BISList:AddItem(itemLink, slotId, itemName, sourceInfo)
		end

		if BISListUI and BISListUI.Refresh and BISListUI:IsVisible() then
			BISListUI:Refresh()
		end
		return true
	end

	-- Slot couldn't be auto-resolved: either one-hand weapon, uncached, or non-equippable
	local _, _, _, _, _, _, _, itemEquipLoc = GetItemInfo(itemId)
	if itemEquipLoc == "INVTYPE_WEAPON" then
		DebugLog("AddOrToggleItem: INVTYPE_WEAPON detected, showing slot selection dialog")
		if not itemName or string.find(itemName, "^item:") then
			if AtlasLootTooltip and AtlasLootTooltip:IsVisible() and AtlasLootTooltipTextLeft1 then
				itemName = AtlasLootTooltipTextLeft1:GetText()
			end
			if not itemName or itemName == "" then
				local cachedName = GetItemInfo(itemId)
				if cachedName then
					itemName = cachedName
				end
			end
		end
		if itemName == "" then itemName = nil end
		self:ShowWeaponSlotDialog(itemLink, itemName, sourceInfo)
		return true
	elseif not itemEquipLoc then
		DebugLog("AddOrToggleItem: Item data not cached, requesting from server")
		if not self:RequestItemThenAdd(itemLink, itemName, sourceInfo) then
			DEFAULT_CHAT_FRAME:AddMessage("|cffff0000BISList:|r Item data isn't loaded yet - hover the item again in a moment, or install ClassicAPI to have BISList fetch it automatically.")
		end
		return true
	else
		DebugLog("AddOrToggleItem: Item is not equippable (equipLoc: " .. tostring(itemEquipLoc) .. ")")
		DEFAULT_CHAT_FRAME:AddMessage("|cffff0000BISList:|r That item doesn't appear to be equippable.")
		return false
	end
end

-- Hook SetItemRef to catch item link clicks with Ctrl+Alt modifier
-- (Works for chat links, pfQuest browser items, InstanceJournal links, etc.)
local originalSetItemRef = SetItemRef
function SetItemRef(link, text, button)
	-- If Ctrl+Alt-clicking an item link, add/toggle in BIS list
	-- (Avoids plain Alt+Click which conflicts with other addons)
	if IsControlKeyDown() and IsAltKeyDown() and link and string.find(link, "item:") then
		BISListContextMenu:AddOrToggleItem(link, nil, nil)
		return
	end

	-- Call original function
	return originalSetItemRef(link, text, button)
end

-- Helper to capture a GameTooltip item link and clear stale AtlasLoot source
local function CaptureTooltipLink(link)
	if link and string.find(link, "item:") then
		lastHoveredItemLink = link
		lastHoveredItemName = link
		lastHoveredSourceInfo = nil
	end
end

-- Hook GameTooltip to track hovered items from chat/pfQuest links
local originalTooltipSetItem = GameTooltip.SetHyperlink
GameTooltip.SetHyperlink = function(self, link)
	originalTooltipSetItem(self, link)
	CaptureTooltipLink(link)
end

-- Hook ChatEdit_InsertLink to intercept Ctrl+Alt+Shift+Click and fix raw item links
local originalChatEdit_InsertLink = ChatEdit_InsertLink
function ChatEdit_InsertLink(link)
	if IsControlKeyDown() and IsAltKeyDown() and link and string.find(link, "item:") then
		BISListContextMenu:AddOrToggleItem(link, nil, nil)
		return
	end

	-- Fix raw item links (e.g., "item:12345:0:0:0") to proper hyperlink format
	if link and string.find(link, "^item:%d+") and not string.find(link, "|H") then
		local _, _, itemId = string.find(link, "item:(%d+)")
		if itemId then
			local itemName, _, itemRarity = GetItemInfo(tonumber(itemId))
			local nameToUse = itemName or ("Item " .. itemId)

			-- Get color based on rarity
			local colorCode = "ffffffff" -- default white
			if itemRarity then
				local r, g, b = GetItemQualityColor(itemRarity)
				if r then
					colorCode = string.format("ff%02x%02x%02x", r * 255, g * 255, b * 255)
				end
			end

			link = "|c" .. colorCode .. "|Hitem:" .. itemId .. ":0:0:0|h[" .. nameToUse .. "]|h|r"
		end
	end

	-- Only call original if it exists
	if originalChatEdit_InsertLink then
		return originalChatEdit_InsertLink(link)
	end
end

-- Hook GameTooltip:SetBagItem to capture bag item hovers
local originalSetBagItem = GameTooltip.SetBagItem
GameTooltip.SetBagItem = function(self, bag, slot)
	local result = originalSetBagItem(self, bag, slot)
	CaptureTooltipLink(GetContainerItemLink(bag, slot))
	return result
end

-- Hook GameTooltip:SetInventoryItem to capture equipped/inspect item hovers
local originalSetInventoryItem = GameTooltip.SetInventoryItem
GameTooltip.SetInventoryItem = function(self, unit, slot)
	local result = originalSetInventoryItem(self, unit, slot)
	CaptureTooltipLink(GetInventoryItemLink(unit, slot))
	return result
end

-- Hook GameTooltip:SetLootItem for loot window
local originalSetLootItem = GameTooltip.SetLootItem
GameTooltip.SetLootItem = function(self, slot)
	local result = originalSetLootItem(self, slot)
	CaptureTooltipLink(GetLootSlotLink(slot))
	return result
end

-- Hook additional standard GameTooltip setters (Quest, Merchant, Auction, LootRoll, Mail)
if GameTooltip.SetQuestItem then
	local orig = GameTooltip.SetQuestItem
	GameTooltip.SetQuestItem = function(self, qtype, slot)
		local result = orig(self, qtype, slot)
		CaptureTooltipLink(GetQuestItemLink(qtype, slot))
		return result
	end
end

if GameTooltip.SetQuestLogItem then
	local orig = GameTooltip.SetQuestLogItem
	GameTooltip.SetQuestLogItem = function(self, qtype, slot)
		local result = orig(self, qtype, slot)
		CaptureTooltipLink(GetQuestLogItemLink(qtype, slot))
		return result
	end
end

if GameTooltip.SetMerchantItem then
	local orig = GameTooltip.SetMerchantItem
	GameTooltip.SetMerchantItem = function(self, slot)
		local result = orig(self, slot)
		CaptureTooltipLink(GetMerchantItemLink(slot))
		return result
	end
end

if GameTooltip.SetAuctionItem then
	local orig = GameTooltip.SetAuctionItem
	GameTooltip.SetAuctionItem = function(self, atype, index)
		local result = orig(self, atype, index)
		CaptureTooltipLink(GetAuctionItemLink(atype, index))
		return result
	end
end

if GameTooltip.SetLootRollItem then
	local orig = GameTooltip.SetLootRollItem
	GameTooltip.SetLootRollItem = function(self, rollId)
		local result = orig(self, rollId)
		CaptureTooltipLink(GetLootRollItemLink(rollId))
		return result
	end
end

if GameTooltip.SetInboxItem then
	local orig = GameTooltip.SetInboxItem
	GameTooltip.SetInboxItem = function(self, index, attachmentIndex)
		local result = orig(self, index, attachmentIndex)
		CaptureTooltipLink(GetInboxItemLink(index, attachmentIndex))
		return result
	end
end

-- Continuously check for AtlasLoot and other addon item tooltips
local updateFrame = CreateFrame("Frame")
local lastLoggedItemID = nil
local lastLoggedFrame = nil
local scanTimer = 0
local SCAN_INTERVAL = 0.05

updateFrame:SetScript("OnUpdate", function()
	-- Handle hide timer countdown
	if hideTimer > 0 then
		hideTimer = hideTimer - arg1
		if hideTimer <= 0 then
			lastHoveredItemLink = nil
			lastHoveredItemName = nil
			lastHoveredSourceInfo = nil
			lastLoggedItemID = nil
			lastLoggedFrame = nil
		end
	end

	-- Check both GameTooltip and AtlasLootTooltip
	local tooltipVisible = GameTooltip:IsVisible() or (AtlasLootTooltip and AtlasLootTooltip:IsVisible())
	if not tooltipVisible then
		scanTimer = 0
		return
	end

	-- Reset hide timer since tooltip is visible
	hideTimer = 0

	-- Throttle per-frame tooltip inspection
	scanTimer = scanTimer + arg1
	if scanTimer < SCAN_INTERVAL then
		return
	end
	scanTimer = 0

	-- Debug: Log tooltip state periodically
	if not lastLoggedItemID then
		DebugLog("Tooltip became visible")
		DebugLog("  GameTooltip visible: " .. tostring(GameTooltip:IsVisible()))
		DebugLog("  AtlasLootTooltip visible: " .. tostring(AtlasLootTooltip and AtlasLootTooltip:IsVisible()))
	end

	-- Check mouse focus for AtlasLoot item buttons
	local mouseFocus = GetMouseFocus()
	local itemCaptured = false

	-- Debug: Always log frame info when tooltip is visible (not just when frame changes)
	if mouseFocus then
		local frameName = mouseFocus:GetName() or "unnamed"
		-- Only log if we haven't captured an item for this tooltip yet
		if not lastLoggedItemID or lastLoggedItemID == "noitem" then
			DebugLog("=== Tooltip visible, checking frame ===")
			DebugLog("Frame name: " .. frameName)
			DebugLog("Frame type: " .. (mouseFocus:GetObjectType() or "unknown"))
			-- Always check for item-related properties when debugging
			DebugLog("Checking properties:")
			DebugLog("  itemID: " .. tostring(mouseFocus.itemID))
			DebugLog("  link: " .. tostring(mouseFocus.link))
			DebugLog("  itemLink: " .. tostring(mouseFocus.itemLink))
			DebugLog("  itemIDName: " .. tostring(mouseFocus.itemIDName))
			DebugLog("  lootpage: " .. tostring(mouseFocus.lootpage))
			DebugLog("  buttoninfo: " .. tostring(mouseFocus.buttoninfo))
			lastLoggedFrame = mouseFocus
		end
	else
		if not lastLoggedItemID then
			DebugLog("WARNING: Tooltip visible but no mouse focus!")
		end
	end

	if mouseFocus then
		local rawID = nil
		local itemID = nil

		-- Check for itemID (regular AtlasLoot items)
		if mouseFocus.itemID then
			rawID = tostring(mouseFocus.itemID)
			-- If itemID has 's' prefix (set/special item), prefer dressingroomID as the real item ID
			if string.find(rawID, "^s%d+$") and mouseFocus.dressingroomID then
				itemID = tonumber(mouseFocus.dressingroomID)
				DebugLog("Item has 's' prefix, using dressingroomID: " .. tostring(itemID))
			else
				-- Try direct conversion for regular numeric IDs
				itemID = tonumber(rawID)
				-- If that fails, extract from 's' prefix as fallback
				if not itemID then
					local _, _, numPart = string.find(rawID, "^s(%d+)$")
					if numPart then
						itemID = tonumber(numPart)
						DebugLog("Extracted item ID from 's' prefix: " .. itemID)
					end
				end
			end
		-- Check for dressingroomID (container items like Tier Sets preview)
		elseif mouseFocus.dressingroomID then
			itemID = tonumber(mouseFocus.dressingroomID)
			DebugLog("Found dressingroomID: " .. tostring(itemID))
		end

		if itemID and itemID ~= 0 then
			-- Store the basic link format
			lastHoveredItemLink = "item:" .. itemID .. ":0:0:0"
			itemCaptured = true

			-- Only log when item changes to avoid spam
			if itemID ~= lastLoggedItemID then
				DebugLog("MouseFocus itemID: " .. itemID)
				DebugLog("  Frame name: " .. (mouseFocus:GetName() or "unnamed"))
				DebugLog("  Link: " .. lastHoveredItemLink)
				lastLoggedItemID = itemID
			end

			-- Capture item name from AtlasLoot database or GetItemInfo
			if mouseFocus.itemIDName then
				lastHoveredItemName = mouseFocus.itemIDName
			else
				local itemName = GetItemInfo(itemID)
				if itemName then
					lastHoveredItemName = itemName
				else
					lastHoveredItemName = nil
				end
			end

			-- Capture source information if available
			if mouseFocus.sourcePage then
				lastHoveredSourceInfo = mouseFocus.sourcePage
			elseif AtlasLootItemsFrame and AtlasLootItemsFrame.refresh then
				local dataID = AtlasLootItemsFrame.refresh[1]
				local dataSource = AtlasLootItemsFrame.refresh[2]
				if dataID and dataSource then
					lastHoveredSourceInfo = dataID .. "|" .. dataSource
				end
			end
		end
	end

	-- AtlasLoot stores itemID directly on GameTooltip
	if not itemCaptured then
		if GameTooltip.itemID then
			local itemID = tonumber(GameTooltip.itemID)
			if itemID and itemID ~= 0 then
				lastHoveredItemLink = "item:" .. itemID .. ":0:0:0"
				lastHoveredSourceInfo = nil
				itemCaptured = true

				if itemID ~= lastLoggedItemID then
					DebugLog("GameTooltip itemID: " .. itemID)
					DebugLog("  Link: " .. lastHoveredItemLink)
					lastLoggedItemID = itemID
				end
			end
		end
	end

	-- Check common item link storage fields on mouse focus
	if not itemCaptured and mouseFocus then
		local itemLink = mouseFocus.link or mouseFocus.itemLink or mouseFocus.itemlink
		if itemLink and string.find(itemLink, "item:") then
			lastHoveredItemLink = itemLink
			lastHoveredSourceInfo = nil
			itemCaptured = true
		end
	end

	-- ClassicAPI fallback: GameTooltip:GetItem() covers any addon/frame using GameTooltip
	if not itemCaptured and GameTooltip:IsVisible() and type(GameTooltip.GetItem) == "function" then
		local _, gtLink, gtId = GameTooltip:GetItem()
		if gtLink and string.find(gtLink, "item:") then
			lastHoveredItemLink = gtLink
			lastHoveredItemName = gtLink
			lastHoveredSourceInfo = nil
			itemCaptured = true
		elseif gtId and gtId ~= 0 then
			lastHoveredItemLink = "item:" .. gtId .. ":0:0:0"
			lastHoveredSourceInfo = nil
			itemCaptured = true
		end
	end

	-- Debug: Check if we failed to capture an item
	if not itemCaptured and GameTooltip:NumLines() > 0 then
		if not lastLoggedItemID or lastLoggedItemID ~= "noitem" then
			DebugLog("=== FAILED to capture item ===")
			DebugLog("GameTooltip.itemID: " .. tostring(GameTooltip.itemID))
			DebugLog("NumLines: " .. GameTooltip:NumLines())
			if GameTooltipTextLeft1 then
				DebugLog("Tooltip text: " .. tostring(GameTooltipTextLeft1:GetText()))
			end
			if mouseFocus then
				DebugLog("MouseFocus: " .. tostring(mouseFocus:GetName()))
			end
			lastLoggedItemID = "noitem"
		end
	end
end)

-- Hook GameTooltip:Hide with delayed clear to handle rapid tooltip changes
local originalHide = GameTooltip.Hide
GameTooltip.Hide = function(self)
	-- Don't clear immediately, set a timer to clear after 0.5 seconds
	hideTimer = 0.5
	return originalHide(self)
end

-- Helper function to convert AtlasLoot format to colored text
local function AtlasLoot_FixText(text)
	if not text then return nil end
	-- Convert AtlasLoot color codes to WoW color codes
	text = gsub(text, "=q1=", "|cffFFFFFF") -- common
	text = gsub(text, "=q2=", "|cff1eff00") -- uncommon
	text = gsub(text, "=q3=", "|cff0070dd") -- rare
	text = gsub(text, "=q4=", "|cffa335ee") -- epic
	text = gsub(text, "=q5=", "|cffFF8000") -- legendary
	return text
end

-- Function to add/remove currently hovered item (called by keybinding)
function BISList_AddHoveredItem()
	DebugLog("=== BISList_AddHoveredItem called ===")
	DebugLog("lastHoveredItemLink: " .. tostring(lastHoveredItemLink))

	-- Live fallback via ClassicAPI GameTooltip:GetItem() in case key was pressed
	-- before the 0.05s OnUpdate scan ran
	if not lastHoveredItemLink and GameTooltip:IsVisible() and type(GameTooltip.GetItem) == "function" then
		local _, gtLink, gtId = GameTooltip:GetItem()
		if gtLink and string.find(gtLink, "item:") then
			lastHoveredItemLink = gtLink
			lastHoveredItemName = gtLink
			lastHoveredSourceInfo = nil
		elseif gtId and gtId ~= 0 then
			lastHoveredItemLink = "item:" .. gtId .. ":0:0:0"
			lastHoveredSourceInfo = nil
		end
	end

	if lastHoveredItemLink then
		BISListContextMenu:AddOrToggleItem(lastHoveredItemLink, lastHoveredItemName, lastHoveredSourceInfo)
	else
		DebugLog("ERROR: No item link captured (lastHoveredItemLink is nil)")
	end
end

-- Slash command for manual testing
SLASH_BISTEST1 = "/bistest"
SlashCmdList["BISTEST"] = function(msg)
	BISList_AddHoveredItem()
end

-- Slash command to toggle debug mode
SLASH_BISDEBUG1 = "/bisdebug"
SlashCmdList["BISDEBUG"] = function(msg)
	DEBUG_MODE = not DEBUG_MODE
	if DEBUG_MODE then
		DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00BISList:|r Debug mode enabled")
	else
		DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00BISList:|r Debug mode disabled")
	end
end

-- Slash command to manually check current mouse focus
SLASH_BISCHECK1 = "/bischeck"
SlashCmdList["BISCHECK"] = function(msg)
	-- Always output, regardless of DEBUG_MODE
	DEFAULT_CHAT_FRAME:AddMessage("|cffFFFF00[BISCheck]|r === Manual check requested ===")
	local mouseFocus = GetMouseFocus()
	if mouseFocus then
		DEFAULT_CHAT_FRAME:AddMessage("|cffFFFF00[BISCheck]|r Mouse focus frame: " .. tostring(mouseFocus:GetName()))
		DEFAULT_CHAT_FRAME:AddMessage("|cffFFFF00[BISCheck]|r Type: " .. tostring(mouseFocus:GetObjectType()))
		DEFAULT_CHAT_FRAME:AddMessage("|cffFFFF00[BISCheck]|r itemID: " .. tostring(mouseFocus.itemID))
		DEFAULT_CHAT_FRAME:AddMessage("|cffFFFF00[BISCheck]|r dressingroomID: " .. tostring(mouseFocus.dressingroomID))
		DEFAULT_CHAT_FRAME:AddMessage("|cffFFFF00[BISCheck]|r link: " .. tostring(mouseFocus.link))
		DEFAULT_CHAT_FRAME:AddMessage("|cffFFFF00[BISCheck]|r itemLink: " .. tostring(mouseFocus.itemLink))
		DEFAULT_CHAT_FRAME:AddMessage("|cffFFFF00[BISCheck]|r itemIDName: " .. tostring(mouseFocus.itemIDName))
		DEFAULT_CHAT_FRAME:AddMessage("|cffFFFF00[BISCheck]|r container: " .. tostring(mouseFocus.container))

		-- Check parent
		local parent = mouseFocus:GetParent()
		if parent then
			DEFAULT_CHAT_FRAME:AddMessage("|cffFFFF00[BISCheck]|r Parent: " .. tostring(parent:GetName()))
			if parent.itemID then
				DEFAULT_CHAT_FRAME:AddMessage("|cffFFFF00[BISCheck]|r Parent.itemID: " .. tostring(parent.itemID))
			end
			if parent.container then
				DEFAULT_CHAT_FRAME:AddMessage("|cffFFFF00[BISCheck]|r Parent.container: " .. tostring(parent.container))
			end
		end

		-- Check all child frames
		local numChildren = mouseFocus:GetNumChildren()
		if numChildren > 0 then
			DEFAULT_CHAT_FRAME:AddMessage("|cffFFFF00[BISCheck]|r NumChildren: " .. numChildren)
		end
	else
		DEFAULT_CHAT_FRAME:AddMessage("|cffFFFF00[BISCheck]|r No mouse focus!")
	end

	DEFAULT_CHAT_FRAME:AddMessage("|cffFFFF00[BISCheck]|r GameTooltip visible: " .. tostring(GameTooltip:IsVisible()))
	DEFAULT_CHAT_FRAME:AddMessage("|cffFFFF00[BISCheck]|r GameTooltip.itemID: " .. tostring(GameTooltip.itemID))
	if GameTooltipTextLeft1 then
		DEFAULT_CHAT_FRAME:AddMessage("|cffFFFF00[BISCheck]|r GameTooltip text: " .. tostring(GameTooltipTextLeft1:GetText()))
	end

	-- Check AtlasLootTooltip
	if AtlasLootTooltip then
		DEFAULT_CHAT_FRAME:AddMessage("|cffFFFF00[BISCheck]|r AtlasLootTooltip visible: " .. tostring(AtlasLootTooltip:IsVisible()))
		DEFAULT_CHAT_FRAME:AddMessage("|cffFFFF00[BISCheck]|r AtlasLootTooltip.itemID: " .. tostring(AtlasLootTooltip.itemID))
		if AtlasLootTooltipTextLeft1 then
			DEFAULT_CHAT_FRAME:AddMessage("|cffFFFF00[BISCheck]|r AtlasLootTooltip text: " .. tostring(AtlasLootTooltipTextLeft1:GetText()))
		end
	end

	DEFAULT_CHAT_FRAME:AddMessage("|cffFFFF00[BISCheck]|r lastHoveredItemLink: " .. tostring(lastHoveredItemLink))

	-- Try to parse item from tooltip text
	if GameTooltip:IsVisible() and GameTooltipTextLeft1 then
		local text = GameTooltipTextLeft1:GetText()
		if text then
			DEFAULT_CHAT_FRAME:AddMessage("|cffFFFF00[BISCheck]|r Attempting to find item by name: " .. text)
		end
	end
end

-- Hook AtlasLoot item clicks so Ctrl+Alt+Click adds to BISList instead of AtlasLoot WishList
local atlasLootHooked = false
local function HookAtlasLoot()
	if atlasLootHooked then return end
	if type(AtlasLoot) ~= "table" then return end

	if type(AtlasLoot.Item_OnClick) == "function" then
		local origItemOnClick = AtlasLoot.Item_OnClick
		AtlasLoot.Item_OnClick = function(self, button)
			if IsControlKeyDown() and IsAltKeyDown() and self then
				local rawID = self.itemID and tostring(self.itemID) or ""
				-- Skip pure enchant entries ("e1234"), handle items & crafted spells ("s1234")
				if not string.find(rawID, "^e%d+$") then
					local itemID = nil
					if string.find(rawID, "^s%d+$") and self.dressingroomID and tonumber(self.dressingroomID) ~= 0 then
						itemID = tonumber(self.dressingroomID)
					else
						itemID = tonumber(rawID)
					end
					if (not itemID or itemID == 0) and self.dressingroomID then
						itemID = tonumber(self.dressingroomID)
					end
					if itemID and itemID ~= 0 then
						local sourceInfo = self.sourcePage
						if not sourceInfo and AtlasLootItemsFrame and AtlasLootItemsFrame.refresh then
							local dataID = AtlasLootItemsFrame.refresh[1]
							local dataSource = AtlasLootItemsFrame.refresh[2]
							if dataID and dataSource then
								sourceInfo = dataID .. "|" .. dataSource
							end
						end
						local itemName = self.itemIDName or (self._Name and self._Name:GetText())
						BISListContextMenu:AddOrToggleItem("item:" .. itemID .. ":0:0:0", itemName, sourceInfo)
						return
					end
				end
			end
			return origItemOnClick(self, button)
		end
	end

	if type(AtlasLoot.ContainerItem_OnClick) == "function" then
		local origContainerOnClick = AtlasLoot.ContainerItem_OnClick
		AtlasLoot.ContainerItem_OnClick = function(self, button)
			if IsControlKeyDown() and IsAltKeyDown() and self then
				local itemID = tonumber(self.itemID)
				if itemID and itemID ~= 0 then
					local sourceInfo = self.sourcePage
					if not sourceInfo and AtlasLootItemsFrame and AtlasLootItemsFrame.refresh then
						local dataID = AtlasLootItemsFrame.refresh[1]
						local dataSource = AtlasLootItemsFrame.refresh[2]
						if dataID and dataSource then
							sourceInfo = dataID .. "|" .. dataSource
						end
					end
					local itemName = GetItemInfo(itemID)
					BISListContextMenu:AddOrToggleItem("item:" .. itemID .. ":0:0:0", itemName, sourceInfo)
					return
				end
			end
			return origContainerOnClick(self, button)
		end
	end

	atlasLootHooked = true
end

-- Hook into the UI
local hookFrame = CreateFrame("Frame")
hookFrame:RegisterEvent("PLAYER_LOGIN")
hookFrame:RegisterEvent("ADDON_LOADED")
hookFrame:SetScript("OnEvent", function()
	if event == "ADDON_LOADED" and arg1 == "AtlasLoot" then
		HookAtlasLoot()
	elseif event == "PLAYER_LOGIN" then
		HookAtlasLoot()

		-- Set default keybinding to ALT-SHIFT-B (avoids ALT-B bag conflict) if none is set
		local key1, key2 = GetBindingKey("BISLIST_ADD")
		if not key1 and not key2 then
			local existing = GetBindingAction("ALT-SHIFT-B")
			if not existing or existing == "" then
				SetBinding("ALT-SHIFT-B", "BISLIST_ADD")
				SaveBindings(GetCurrentBindingSet())
				key1 = "ALT-SHIFT-B"
			end
		end

		local activeKey = key1 or key2 or "unbound"
		DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00BISList:|r Loaded! Use |cffffffffCtrl+Alt+Click|r (AtlasLoot/pfQuest/chat) or hover + |cffffffff" .. activeKey .. "|r to add/remove items, or |cffffffff/bis|r to view.")
	end
end)

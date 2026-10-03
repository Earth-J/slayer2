-- Safe loader for UI library
local function safeLoad(url, label)
    local ok, src = pcall(game.HttpGet, game, url)
    if not ok or type(src) ~= "string" or #src < 10 then
        error(string.format("[AutoFish] HttpGet failed for %s: %s", label, tostring(src)), 2)
    end
    if src:sub(1, 1) == "<" then
        error(string.format("[AutoFish] %s returned HTML (404). URL is dead.", label), 2)
    end
    local fn, err = loadstring(src)
    if not fn then
        error(string.format("[AutoFish] loadstring failed for %s: %s", label, tostring(err)), 2)
    end
    local rok, result = pcall(fn)
    if not rok then
        error(string.format("[AutoFish] Execution failed for %s: %s", label, tostring(result)), 2)
    end
    return result
end

local Library = safeLoad(
    "https://raw.githubusercontent.com/sametexe001/sametlibs/refs/heads/main/Mentality/Library.lua",
    "Mentality UI"
)
local Window = Library:Window({
	Name    = "Auto Fish",
	SubName = "Slayers 2 Fishing Automation",
	Logo    = "120959262762131"
})

local FishPage    = Window:Page({ Name = "Auto Fish", Icon = "138827881557940" })
local PerfPage    = Window:Page({ Name = "Perf",      Icon = "123944728972740" })
local WebhookPage = Window:Page({ Name = "Webhook",   Icon = "134236649319095" })
local SettingsPage = Library:CreateSettingsPage(Window)

-- =================== SERVICES / STATE ===================

local Players           = game:GetService("Players")
local HttpService       = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local LocalPlayer       = Players.LocalPlayer

local autoFishing  = false
local instantReel  = true
local customRod    = ''
local fishCaught   = 0
local lastCaught   = 'None'
local lastAttempt  = 'None'
local fishStatus   = 'Idle'
local stopList     = {}
local running      = false
local manualEquip  = false

-- Webhook state
local webhookEnabled  = false
local webhookURL      = ''
local webhookOnCatch  = true
local webhookOnStop   = true
local webhookOnStart  = true
local webhookQueue    = {}
local webhookSending  = false
local webhookSent     = 0
local webhookFailed   = 0
local WEBHOOK_RATE    = 1.1
local webhookStatsLabel = nil

-- =================== BAIT / ROD PRIORITY ===================

-- Priority order for bait auto-equip (best → worst)
local BAIT_PRIORITY = {
	'Golden Tentacle',
	'Fish Head',
	'Worm',
}

-- Auto-equip best rod toggle state
local autoBestRod  = true
local autoBait     = true

-- =================== PRESET STOP ITEMS ===================

local PRESET_STOP_ITEMS = {
	'Lost Shotgun',
	'Lost Mask',
	'Lost Lantern',
	'Lost Outfit',
	'Lost Cape',
}

-- =================== ENV ===================

local Env = {}
local setIdentity = setthreadidentity or set_thread_identity or setidentity or setthreadcontext

function Env.elevate()
	if setIdentity then pcall(setIdentity, 8) end
end

function Env.call(fn, ...)
	local results = table.pack(pcall(fn, ...))
	Env.elevate()
	return table.unpack(results, 1, results.n)
end

function Env.need(parent, name, seconds)
	local child = parent:WaitForChild(name, seconds or 30)
	Env.elevate()
	if not child then
		error(string.format('%s.%s is missing (is this Slayers 2?)', parent:GetFullName(), name), 2)
	end
	return child
end

function Env.firePrompt(prompt)
	if fireproximityprompt and pcall(fireproximityprompt, prompt) then
		Env.elevate()
		return true
	end
	local hold, sight = prompt.HoldDuration, prompt.RequiresLineOfSight
	local ok = pcall(function()
		prompt.HoldDuration = 0
		prompt.RequiresLineOfSight = false
		task.wait(0.1)
		prompt:InputHoldBegin()
		task.wait()
		prompt:InputHoldEnd()
	end)
	pcall(function()
		prompt.HoldDuration, prompt.RequiresLineOfSight = hold, sight
	end)
	Env.elevate()
	return ok
end

local GAME_MODULES = {
	Utility     = { 'CAM', 'Global', 'Utility' },
	SignalEvent = { 'Communication', 'ServerAndClient', 'Signals', 'SignalEvent' },
	Items       = { 'CAM', 'Global', 'Collectibles', 'Items' },
}
local moduleCache = {}
local function gameModule(name)
	if moduleCache[name] ~= nil then return moduleCache[name] end
	local node = ReplicatedStorage
	for _, part in ipairs(GAME_MODULES[name]) do
		node = node:WaitForChild(part, 10)
		assert(node, string.format('game module %s is missing (%s) - is this Slayers 2?', name, part))
	end
	local module = require(node)
	Env.elevate()
	moduleCache[name] = module
	return module
end

-- =================== DATA ===================

local Data = {}
Data.TOOLBAR_SLOTS = { 'One', 'Two', 'Three', 'Four', 'Five' }

function Data.slot()
	local ok, slot = Env.call(gameModule('Utility').GetData, LocalPlayer, true)
	return ok and slot or nil
end

function Data.inventory()
	local slot = Data.slot()
	local inventory = slot and slot:FindFirstChild('Inventory')
	return inventory and inventory:FindFirstChild('Inventory'), inventory and inventory:FindFirstChild('Toolbar')
end

function Data.counts()
	local owned = Data.inventory()
	local counts = {}
	for _, item in ipairs(owned and owned:GetChildren() or {}) do
		local amount = item:FindFirstChild('Amount')
		counts[item.Name] = amount and amount.Value or 1
	end
	return counts
end

function Data.hotbarIndex(name)
	local owned, toolbar = Data.inventory()
	local item = owned and owned:FindFirstChild(name)
	local id = item and item:FindFirstChild('Id')
	if not id or not toolbar then return nil end
	for index, key in ipairs(Data.TOOLBAR_SLOTS) do
		local entry = toolbar:FindFirstChild(key)
		if entry and entry.Value == id.Value then
			return index
		end
	end
	return nil
end

local function emptySlot(toolbar)
	for _, key in ipairs(Data.TOOLBAR_SLOTS) do
		local entry = toolbar:FindFirstChild(key)
		if entry and (entry.Value == 0 or entry.Value == '') then
			return key
		end
	end
	return nil
end

function Data.putOnHotbar(name, slotKey)
	local index = Data.hotbarIndex(name)
	if index then return index end
	local owned, toolbar = Data.inventory()
	local item = owned and owned:FindFirstChild(name)
	local id = item and item:FindFirstChild('Id')
	if not id or not toolbar then return nil end
	slotKey = slotKey or emptySlot(toolbar)
	if not slotKey then return nil end
	gameModule('SignalEvent').ToServer('Toolbar_Equip', slotKey, id.Value)
	local deadline = os.clock() + 2
	while not Data.hotbarIndex(name) and os.clock() < deadline do
		task.wait(0.1)
	end
	Env.elevate()
	return Data.hotbarIndex(name)
end

function Data.character()
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild('HumanoidRootPart')
	local humanoid = char and char:FindFirstChildOfClass('Humanoid')
	return root, humanoid, char
end

function Data.equipped()
	local config = LocalPlayer:FindFirstChild('Items_Config')
	return config and config:FindFirstChild('Equipped')
end

-- =================== BAIT & BEST ROD HELPERS ===================

-- Equip the highest-rarity rod from inventory into its hotbar slot.
-- Runs via SignalEvent exactly like the inventory menu does.
local function doEquipBestRod()
	if not autoBestRod then return end
	pcall(function()
		local items   = gameModule('Items')
		local counts  = Data.counts()
		local best    = nil
		local bestRarity = -1
		for name in pairs(counts) do
			local def = items[name]
			if type(def) == 'table' and def.Category == 'Fishing' and def.EquipType == 2 then
				local r = tonumber(def.Rarity) or 0
				if r > bestRarity then
					bestRarity = r
					best = name
				end
			end
		end
		if not best then return end
		-- Put on hotbar if not already there
		local index = Data.hotbarIndex(best)
		if not index then
			local _, toolbar = Data.inventory()
			local slotKey = emptySlot(toolbar)
			if slotKey then
				Data.putOnHotbar(best, slotKey)
				task.wait(0.5)
			end
		end
	end)
	Env.elevate()
end

-- Equip the best available bait via SignalEvent EquipBait.
local function doEquipBait()
	if not autoBait then return end
	pcall(function()
		local owned = Data.inventory()
		if not owned then return end
		for _, baitName in ipairs(BAIT_PRIORITY) do
			local item = owned:FindFirstChild(baitName)
			if item and item:FindFirstChild('Id') then
				gameModule('SignalEvent').ToServer('EquipBait', item.Id.Value)
				Env.elevate()
				return
			end
		end
	end)
end

-- =================== RARITY HELPERS ===================

local RARITY_MAP = {
	{ keys = { 'legendary', 'mythic', 'divine', 'godly' },        color = 0xFFD700 },
	{ keys = { 'epic', 'ancient', 'arcane' },                      color = 0x9B59B6 },
	{ keys = { 'rare', 'unique' },                                  color = 0x3498DB },
	{ keys = { 'uncommon', 'special' },                             color = 0x2ECC71 },
	{ keys = { 'common', 'normal', 'trash', 'junk', 'boot' },      color = 0x95A5A6 },
}

local function rarityColor(itemName)
	local low = string.lower(itemName)
	for _, entry in ipairs(RARITY_MAP) do
		for _, k in ipairs(entry.keys) do
			if low:find(k) then return entry.color end
		end
	end
	return 0x50B4FF
end

local function rarityLabel(itemName)
	local low = string.lower(itemName)
	for _, entry in ipairs(RARITY_MAP) do
		for _, k in ipairs(entry.keys) do
			if low:find(k) then
				return k:sub(1,1):upper() .. k:sub(2)
			end
		end
	end
	return 'Unknown'
end

-- =================== WEBHOOK ENGINE ===================

local function getAvatarURL()
	return 'https://www.roblox.com/headshot-thumbnail/image?userId='
		.. tostring(LocalPlayer.UserId) .. '&width=48&height=48&format=png'
end

local function getGameInfo()
	local ok, placeName = pcall(function()
		return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId).Name
	end)
	return ok and placeName or ('Place ' .. tostring(game.PlaceId))
end

local function buildCatchEmbed(itemName, total)
	return {
		embeds = {
			{
				title = '🎣  Fish Caught!',
				color = rarityColor(itemName),
				thumbnail = { url = getAvatarURL() },
				fields = {
					{ name = 'Player', value = LocalPlayer.Name,       inline = true },
					{ name = 'Item',   value = '`' .. itemName .. '`', inline = true },
					{ name = 'Rarity', value = rarityLabel(itemName),  inline = true },
					{ name = 'Total',  value = tostring(total),        inline = true },
					{ name = 'Game',   value = getGameInfo(),          inline = true },
					{ name = 'Server', value = game.JobId ~= '' and game.JobId:sub(1,8) .. '…' or 'Private', inline = true },
				},
				footer = { text = 'AutoFish • slopix style' },
				timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ')
			}
		}
	}
end

local function buildStopEmbed(itemName, total)
	return {
		embeds = {
			{
				title = '🛑  Auto Fish Stopped',
				color = 0xFF4444,
				thumbnail = { url = getAvatarURL() },
				fields = {
					{ name = 'Player',       value = LocalPlayer.Name,       inline = true },
					{ name = 'Trigger Item', value = '`' .. itemName .. '`', inline = true },
					{ name = 'Total Caught', value = tostring(total),        inline = true },
					{ name = 'Game',         value = getGameInfo(),          inline = false },
				},
				footer = { text = 'AutoFish • slopix style' },
				timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ')
			}
		}
	}
end

local function buildStartEmbed()
	return {
		embeds = {
			{
				title = '▶️  Auto Fish Started',
				color = 0x50B4FF,
				thumbnail = { url = getAvatarURL() },
				fields = {
					{ name = 'Player', value = LocalPlayer.Name, inline = true },
					{ name = 'Game',   value = getGameInfo(),    inline = true },
				},
				footer = { text = 'AutoFish • slopix style' },
				timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ')
			}
		}
	}
end

local function queueWebhook(payload)
	if not webhookEnabled or webhookURL == '' then return end
	table.insert(webhookQueue, payload)
end

local function startWebhookDrain()
	if webhookSending then return end
	webhookSending = true
	task.spawn(function()
		while #webhookQueue > 0 do
			if not webhookEnabled or webhookURL == '' then
				webhookQueue = {}
				break
			end
			local payload = table.remove(webhookQueue, 1)
			local ok, err = pcall(function()
				local body = HttpService:JSONEncode(payload)
				local res = syn and syn.request or (http and http.request) or request
				if not res then
					game:HttpPost(webhookURL, body, 'application/json')
				else
					res({
						Url     = webhookURL,
						Method  = 'POST',
						Headers = { ['Content-Type'] = 'application/json' },
						Body    = body
					})
				end
			end)
			if ok then
				webhookSent += 1
			else
				webhookFailed += 1
				if err and tostring(err):find('rate') then
					table.insert(webhookQueue, 1, payload)
					task.wait(5)
				end
			end
			if webhookStatsLabel then
				pcall(function()
					webhookStatsLabel:Update(
						'Sent: ' .. webhookSent .. '  |  Failed: ' .. webhookFailed
						.. '\nQueue: ' .. #webhookQueue
					)
				end)
			end
			task.wait(WEBHOOK_RATE)
		end
		webhookSending = false
	end)
end

-- =================== POSITION FREEZE ===================

local function startFreeze()
	local root = Data.character()
	if root then
		pcall(function() root.Anchored = true end)
	end
end

local function stopFreeze()
	local root = Data.character()
	if root then
		pcall(function() root.Anchored = false end)
	end
end

-- =================== STATS ===================

local statsLabel
local function updateStats()
	if statsLabel then
		local names = {}
		for k, v in pairs(stopList) do
			if v then table.insert(names, k) end
		end
		pcall(function()
			statsLabel:Update(
				'Items Caught: ' .. fishCaught
				.. '\nLast Caught: ' .. lastCaught
				.. '\nLast Attempt: ' .. lastAttempt
				.. '\nStatus: ' .. fishStatus
				.. '\nAuto Fish: ' .. (autoFishing and 'ON' or 'OFF')
				.. '\nStop Items: ' .. (#names > 0 and table.concat(names, ', ') or 'None')
			)
		end)
	end
end

local function setStatus(text)
	fishStatus = text
	updateStats()
end

local function shouldStop(items)
	for _, name in ipairs(items) do
		for stopItem, enabled in pairs(stopList) do
			if enabled and string.lower(name):find(string.lower(stopItem), 1, true) then
				return true, name
			end
		end
	end
	return false, nil
end

local mainToggleRef

local function notify(title, desc, duration)
	Library:Notification({
		Title       = title,
		Description = desc,
		Duration    = duration or 3,
		Icon        = "73789337996373",
	})
end

local function stopAutoFish(reason, triggerItem)
	stopFreeze()
	autoFishing = false
	if mainToggleRef then
		pcall(function() mainToggleRef:Update(false) end)
	end
	if webhookOnStop then
		queueWebhook(buildStopEmbed(triggerItem or 'Manual', fishCaught))
		startWebhookDrain()
	end
	notify('🛑 Auto Fish Stopped', reason or 'Stopped.', 5)
	updateStats()
end

-- =================== INDEPENDENT AUTO-PICKUP LOOP ===================

local autoPickup       = true
local pickupConn       = nil
local PICKUP_RANGE     = 50   -- studs

local function startPickupLoop()
	if pickupConn then
		pickupConn:Disconnect()
		pickupConn = nil
	end
	pickupConn = RunService.Heartbeat:Connect(function()
		if not autoPickup or not autoFishing then return end
		local root = Data.character()
		local debree = workspace:FindFirstChild('Debree')
		if not root or not debree then return end
		for _, child in ipairs(debree:GetChildren()) do
			if child:GetAttribute('CatchItem') ~= nil then
				local part = child:IsA('BasePart') and child
					or child:FindFirstChildWhichIsA('BasePart', true)
				if part and (part.Position - root.Position).Magnitude <= PICKUP_RANGE then
					local prompt = child:FindFirstChildWhichIsA('ProximityPrompt', true)
					if prompt and prompt.Enabled then
						pcall(function()
							if fireproximityprompt then
								fireproximityprompt(prompt)
							else
								prompt:InputHoldBegin()
								task.wait(0.05)
								prompt:InputHoldEnd()
							end
						end)
					end
				end
			end
		end
	end)
end

local function stopPickupLoop()
	if pickupConn then
		pickupConn:Disconnect()
		pickupConn = nil
	end
end

-- =================== FISHING ENGINE ===================

local BITE_TIMEOUT = 30
local REEL_DELAY   = 4.6
local UNCAST_TIME  = 1.5
local CAST_TRIES   = 2
local MAX_STRIKES  = 3

local PortalEvent, Debree
local biteToken, biteAt, biteMissed, biteCancelled = nil, nil, nil, nil
local myBobber, myCatch = nil, nil
local connections = {}
local closingUi = false
local fishingSlot, strikes = nil, 0
local lastSpot = nil

local function setupGame()
	if PortalEvent and Debree and Debree.Parent then return end
	PortalEvent = Env.need(ReplicatedStorage.CAM.Global.ServerClientPortal, 'Event')
	Debree = Env.need(workspace, 'Debree')
end

local function isRod(definition)
	return type(definition) == 'table' and definition.Category == 'Fishing' and definition.EquipType == 2
end

local function ownedRods()
	local items = gameModule('Items')
	local list = {}
	for name in pairs(Data.counts()) do
		local definition = items[name]
		if isRod(definition) then
			list[#list + 1] = { name = name, rarity = tonumber(definition.Rarity) or 0 }
		end
	end
	table.sort(list, function(a, b)
		if a.rarity ~= b.rarity then return a.rarity > b.rarity end
		return a.name < b.name
	end)
	local names = {}
	for index, rod in ipairs(list) do names[index] = rod.name end
	return names
end

local function pickedRod()
	local owned = ownedRods()
	if customRod ~= '' then
		for _, name in ipairs(owned) do
			if name:lower() == customRod:lower() then return name end
		end
	end
	return owned[1], owned[1] == nil and 'You own no fishing rod' or nil
end

local function rodSlot(rod)
	local index = Data.hotbarIndex(rod)
	if index then return index end
	local _, toolbar = Data.inventory()
	local slotKey
	for _, other in ipairs(ownedRods()) do
		local otherIndex = other ~= rod and Data.hotbarIndex(other)
		if otherIndex then
			slotKey = Data.TOOLBAR_SLOTS[otherIndex]
			break
		end
	end
	index = toolbar and Data.putOnHotbar(rod, slotKey)
	if not index then
		return nil, string.format('No free hotbar slot for %s. Free one, or put it on the hotbar yourself', rod)
	end
	return index
end

local function onOurLine(model)
	local line = model:FindFirstChild('FishingLine', true)
	local tip = line and line:IsA('RopeConstraint') and line.Attachment0
	local char = LocalPlayer.Character
	return tip ~= nil and tip ~= false and char ~= nil and tip:IsDescendantOf(char)
end

local function minigameLoops()
	local loops = {}
	if not getconnections then return loops end
	for _, connection in ipairs(getconnections(RunService.RenderStepped)) do
		local fn = connection.Function
		local ok, source = false, nil
		if fn then
			ok, source = pcall(debug.info, fn, 's')
		end
		if ok and type(source) == 'string' and string.find(source, 'BarKeepup', 1, true) then
			loops[#loops + 1] = connection
		end
	end
	return loops
end

local function disconnectMinigameLoops()
	for _, connection in ipairs(minigameLoops()) do
		pcall(function() connection:Disconnect() end)
	end
	return #minigameLoops() == 0
end

local function closeBiteUi()
	if not getconnections or #minigameLoops() == 0 or not disconnectMinigameLoops() then
		Env.elevate()
		return false
	end
	closingUi = true
	for _, connection in ipairs(getconnections(PortalEvent.OnClientEvent)) do
		if connection.Function then
			pcall(connection.Function, 'FishingRod', 'BiteCancel')
		end
	end
	closingUi = false
	Env.elevate()
	return true
end

local function catchSnapshot()
	local existing = {}
	for _, model in ipairs(Debree:GetChildren()) do
		existing[model] = true
	end
	return existing
end

local function newCatch(root, existing)
	local best, bestDistance
	for _, model in ipairs(Debree:GetChildren()) do
		if not existing[model] and model:GetAttribute('CatchItem') then
			local prompt = model:FindFirstChildWhichIsA('ProximityPrompt', true)
			local part = prompt and prompt.Parent
			if part and part:IsA('BasePart') then
				local distance = (part.Position - root.Position).Magnitude
				if not bestDistance or distance < bestDistance then
					best, bestDistance = model, distance
				end
			end
		end
	end
	return best
end

local function waterTarget(root, char)
	local water = RaycastParams.new()
	water.FilterType = Enum.RaycastFilterType.Include
	water.BruteForceAllSlow = true
	local parts = {}
	for _, part in ipairs(CollectionService:GetTagged('SwimParts')) do
		parts[#parts + 1] = part.Parent or part
	end
	water.FilterDescendantsInstances = parts
	local ground = RaycastParams.new()
	ground.FilterType = Enum.RaycastFilterType.Exclude
	ground.FilterDescendantsInstances = { char, Debree }
	for radius = 8, 32, 4 do
		for index = 0, 15 do
			local angle = index * math.pi / 8
			local origin = root.Position + Vector3.new(math.cos(angle) * radius, 50, math.sin(angle) * radius)
			local direction = Vector3.new(0, -150, 0)
			local hit = workspace:Raycast(origin, direction, water)
			local obstruction = workspace:Raycast(origin, direction, ground)
			if hit and (hit.Instance.Name == 'Texture' or hit.Instance.Name == 'TouchPart')
				and (not obstruction or obstruction.Position.Y <= hit.Position.Y + 0.1) then
				return hit.Position
			end
		end
	end
	return nil
end

local function stillOn()
	return autoFishing or manualEquip
end

local function waitUntil(done, seconds)
	local deadline = os.clock() + seconds
	local nextCheck = 0
	while not done() do
		local now = os.clock()
		if now >= deadline then return false end
		if now >= nextCheck then
			if not stillOn() then return nil end
			nextCheck = now + 0.1
		end
		task.wait()
	end
	return true
end

local function never() return false end

local function waitOn(seconds)
	return waitUntil(never, seconds) ~= nil
end

local function reel()
	if not getconnections then
		return false, 'Your executor has no getconnections, which playing the reel needs: turn Instant Reel on'
	end
	local lastY, lastTime, held, currentGui
	local deadline = os.clock() + 45
	while stillOn() and LocalPlayer:GetAttribute('FishingBite') do
		if os.clock() >= deadline then
			return false, 'Reeling timed out'
		end
		local misc = LocalPlayer.PlayerGui:FindFirstChild('Misc')
		local tracker = misc and misc:FindFirstChild('tracker', true)
		local bar = tracker and tracker.Parent:FindFirstChild('Bar')
		if bar then
			local gui = tracker:FindFirstAncestorOfClass('CanvasGroup')
			if currentGui ~= gui then
				lastY, lastTime, held, currentGui = nil, nil, nil, gui
			end
			local now = os.clock()
			local y = bar.AbsolutePosition.Y + bar.AbsoluteSize.Y / 2
			local target = tracker.AbsolutePosition.Y + tracker.AbsoluteSize.Y / 2
			local velocity = lastY and (y - lastY) / math.max(now - lastTime, 0.001) or 0
			local press = y + velocity * 0.18 > target
			if gui and press ~= held then
				local invoked = false
				for _, connection in ipairs(getconnections(press and gui.InputBegan or gui.InputEnded)) do
					if connection.Function then
						connection.Function({ UserInputType = Enum.UserInputType.MouseButton1 })
						invoked = true
					end
				end
				if not invoked then
					return false, 'The fishing input handler is unavailable'
				end
				held = press
			end
			lastY, lastTime = y, now
		end
		task.wait(0.025)
	end
	return true
end

-- =================== COLLECT CATCH ===================

local function collectCatch(root, existing)
	local model = nil
	local found = waitUntil(function()
		model = myCatch
		return model ~= nil or biteMissed
	end, 0.8)
	if found == false then
		found = waitUntil(function()
			model = myCatch or newCatch(root, existing)
			return model ~= nil or biteMissed
		end, 1.2)
	end
	if not model or not model.Parent then
		return nil
	end
	local item = tostring(model:GetAttribute('CatchItem'))

	local willStop, _ = shouldStop({ item })
	if willStop then
		return 'skip', item
	end

	local prompt = model:FindFirstChildWhichIsA('ProximityPrompt', true)
	if not found or not prompt then
		return false, item
	end
	setStatus(string.format('Pulling in %s...', item))
	local shown, seen, holding, triggered = false, false, false, false
	local promptConnections = {
		prompt.PromptShown:Connect(function() shown, seen = true, true end),
		prompt.PromptHidden:Connect(function() shown, seen = false, true end),
		prompt.PromptButtonHoldEnded:Connect(function() holding = false end),
		prompt.Triggered:Connect(function() triggered = true end),
	}
	local inRangeSince = nil
	local function ready()
		if shown or not model.Parent then return true end
		local part = prompt.Parent
		if not seen and part:IsA('BasePart')
			and (part.Position - root.Position).Magnitude <= prompt.MaxActivationDistance - 0.5 then
			inRangeSince = inRangeSince or os.clock()
			return os.clock() - inRangeSince >= 0.15
		end
		inRangeSince = nil
		return false
	end
	local deadline = os.clock() + 8
	while model.Parent and not triggered and os.clock() < deadline do
		if not waitUntil(ready, deadline - os.clock()) or not model.Parent then
			break
		end
		setStatus(string.format('Collecting %s...', item))
		holding = true
		pcall(prompt.InputHoldBegin, prompt)
		local ended = waitUntil(function()
			return model.Parent == nil or triggered or not holding
		end, prompt.HoldDuration + 1)
		pcall(prompt.InputHoldEnd, prompt)
		if ended == nil then break end
		if ended == false then
			shown, seen = false, true
		end
	end
	if triggered then
		waitUntil(function() return model.Parent == nil end, 1)
	end
	for _, connection in ipairs(promptConnections) do
		connection:Disconnect()
	end
	if model.Parent and stillOn() then
		Env.firePrompt(prompt)
		waitUntil(function() return model.Parent == nil end, 1)
	end
	Env.elevate()
	return model.Parent == nil, item
end

-- =================== RECORD CATCH ===================

local function readGains(before, collected)
	local total, names, labels = 0, {}, {}
	local deadline = os.clock() + (collected and 2 or 0)
	repeat
		total, names, labels = 0, {}, {}
		for name, amount in pairs(Data.counts()) do
			local gain = amount - (before[name] or 0)
			if gain > 0 then
				total += gain
				names[#names + 1] = name
				labels[#labels + 1] = string.format('%s x%d', name, gain)
			end
		end
		if total > 0 or os.clock() >= deadline then break end
		task.wait(0.1)
	until false
	return total, names, labels
end

local function recordCatch(before, collected, item, missed)
	local total, names, labels = readGains(before, collected)
	if total > 0 then
		fishCaught += total
		lastCaught = names[1]
		lastAttempt = table.concat(labels, ', ')
		notify('Fish Caught!', 'Got: ' .. lastAttempt .. '  |  Total: ' .. fishCaught, 2)
		if webhookOnCatch then
			queueWebhook(buildCatchEmbed(names[1], fishCaught))
			startWebhookDrain()
		end
		updateStats()
		local stop, hitItem = shouldStop(names)
		if stop then
			stopAutoFish('หยุดเพราะได้ "' .. hitItem .. '" ที่ตั้งไว้', hitItem)
			return true
		end
	else
		lastAttempt = missed and 'The fish got away'
			or item and ('Could not collect ' .. item)
			or 'Nothing on the line'
		updateStats()
	end
	return false
end

-- =================== FISHING LOOP ===================

local function ensureSpot()
	local root, humanoid, char = Data.character()
	if not root or not humanoid or humanoid.Health <= 0 then
		return nil, 'Character is not ready', true
	end
	local deadline = os.clock() + 3
	while humanoid.FloorMaterial == Enum.Material.Air or (char:GetAttribute('SwimState') or 0) > 0 do
		if os.clock() >= deadline then break end
		task.wait(0.2)
	end
	local grounded = humanoid.FloorMaterial ~= Enum.Material.Air and (char:GetAttribute('SwimState') or 0) == 0
	local target = nil
	if grounded then
		if lastSpot and (root.Position - lastSpot.from).Magnitude < 2 then
			target = lastSpot.target
		else
			target = waterTarget(root, char)
			lastSpot = target and { from = root.Position, target = target } or nil
		end
	end
	if target then return target end
	if grounded then
		return nil, 'No open water nearby. Walk up to the water (the dock, a shore) and turn it on again'
	end
	return nil, 'Stand on the dock or shore before fishing', true
end

local function rodInHand(rod)
	local _, _, char = Data.character()
	local accessories = char and char:FindFirstChild('Tool_Accessories')
	return accessories ~= nil and accessories:FindFirstChild(rod) ~= nil
end

local function equipRod(index, rod)
	local equipped = Data.equipped()
	if not equipped then return false end
	local function holding()
		return equipped.Value == index and rodInHand(rod)
	end
	if holding() then return true end
	for _ = 1, 3 do
		if equipped.Value ~= 0 then
			equipped.Value = 0
			if not waitOn(0.5) then return nil end
		end
		equipped.Value = index
		local held = waitUntil(holding, 2)
		if held == nil then return nil end
		if held then
			return waitOn(0.2) or nil
		end
	end
	return false
end

local function resetRod(index, rod)
	local equipped = Data.equipped()
	if not equipped then return false end
	equipped.Value = 0
	local cleared = waitUntil(function() return not rodInHand(rod) end, 1.5)
	if cleared == nil or not waitOn(0.3) then return nil end
	return equipRod(index, rod)
end

local function castLine(target)
	local signal = gameModule('SignalEvent')
	for _ = 1, CAST_TRIES do
		myBobber = nil
		signal.ToServer('Tool_Mouse', 'Up', target)
		Env.elevate()
		local landed = waitUntil(function() return myBobber ~= nil end, 1.5)
		if landed ~= false then return landed end
	end
	return false
end

local function fishOnce()
	startFreeze()
	local target, why, retry = ensureSpot()
	if not target then return false, why, retry end
	local root = Data.character()
	local rod, noRod = pickedRod()
	if not rod then return false, noRod end
	local index, noSlot = rodSlot(rod)
	if not index then return false, noSlot end
	fishingSlot = index
	local held = equipRod(index, rod)
	if held == nil then return true end
	if not held then return false, 'The game refused to equip ' .. rod, true end

	local before = Data.counts()
	local instant = instantReel
	biteToken, biteAt, biteMissed, biteCancelled, myCatch = nil, nil, nil, nil, nil
	setStatus('Casting with ' .. rod .. '...')
	local cast = castLine(target)
	if cast == false then
		setStatus('Resetting the rod...')
		cast = resetRod(index, rod)
		if cast then cast = castLine(target) end
	end
	if cast == nil then return true end
	if not cast then
		lastSpot = nil
		return false, 'The game did not take the cast', true
	end

	setStatus('Waiting for a bite...')
	local function bitten()
		if instant then return biteToken ~= nil end
		return LocalPlayer:GetAttribute('FishingBite') == true
	end
	local bobber = myBobber
	local bite = waitUntil(function()
		return bitten() or bobber.Parent == nil
	end, BITE_TIMEOUT)
	if bite == nil then return true end
	if not bitten() then
		lastSpot = nil
		return false, 'No bite. Move closer to open water and retry', true
	end

	local existing = catchSnapshot()
	if instant then
		setStatus('Reeling...')
		if waitUntil(function()
			return LocalPlayer:GetAttribute('FishingBite') == true
		end, 0.5) == nil then
			return true
		end
		if closeBiteUi() then
			setStatus('Reeling (the game makes you wait 4.5s)...')
			local dropped = waitUntil(function()
				return biteCancelled == true
			end, biteAt + REEL_DELAY - os.clock())
			if dropped == nil then return true end
			if dropped then
				return false, 'The game reeled the line in before the fish was landed', true
			end
			myCatch, existing = nil, catchSnapshot()
			PortalEvent:FireServer('FishingRod', biteToken, true)
		elseif not getconnections then
			return false, 'Your executor has no getconnections, which skipping the reel minigame needs'
		else
			instant = false
		end
	end
	if not instant then
		setStatus('Reeling (playing the minigame)...')
		local reeled, reelWhy = reel()
		if getconnections then
			pcall(disconnectMinigameLoops)
			Env.elevate()
		end
		if not reeled then
			return reelWhy == nil, reelWhy, true
		end
	end
	local verdictAt = os.clock()

	local collected, item = collectCatch(root, existing)

	if collected == 'skip' then
		lastAttempt = 'Skipped (stop list): ' .. (item or '?')
		updateStats()
		stopAutoFish('หยุดเพราะได้ "' .. (item or '?') .. '" ที่ตั้งไว้', item)
		return true
	end

	if recordCatch(before, collected, item, biteMissed) then
		return true
	end
	if not collected then
		waitOn(verdictAt + UNCAST_TIME - os.clock())
	end
	return true
end

local function disconnectAll()
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function connectEvents()
	disconnectAll()
	connections[#connections + 1] = PortalEvent.OnClientEvent:Connect(function(channel, kind, token)
		if channel ~= 'FishingRod' then return end
		if kind == 'Bite' then
			biteToken, biteAt = token, os.clock()
		elseif kind == 'BiteMissed' then
			biteMissed = true
		elseif kind == 'BiteCancel' and not closingUi then
			biteCancelled = true
		end
	end)
	connections[#connections + 1] = Debree.ChildAdded:Connect(function(child)
		if child:GetAttribute('CatchItem') ~= nil then
			if onOurLine(child) then
				myCatch = child
				return
			end
			task.spawn(function()
				for _ = 1, 15 do
					task.wait()
					if not child.Parent then return end
					if onOurLine(child) then
						myCatch = child
						return
					end
				end
			end)
		elseif string.sub(child.Name, 1, 12) == 'FishingLine_' and onOurLine(child) then
			myBobber = child
		end
	end)
end

local function cleanupFishing()
	disconnectAll()
	stopPickupLoop()
	stopFreeze()
	local equipped = Data.equipped()
	if equipped and fishingSlot and (equipped.Value == fishingSlot or equipped.Value == 0) then
		equipped.Value = 0
	end
	fishingSlot = nil
end

local function fishingLoop()
	if running then return end
	running = true

	local ok, err = pcall(setupGame)
	if not ok then
		running = false
		stopAutoFish(tostring(err))
		return
	end
	-- Equip best rod into hotbar, then equip best bait
	doEquipBestRod()
	task.wait(0.5)
	doEquipBait()
	task.wait(0.3)

	startPickupLoop()
	connectEvents()
	strikes = 0

	while autoFishing do
		local okStep, fine, why, retry = pcall(fishOnce)
		Env.elevate()
		if okStep and fine then
			strikes = 0
		else
			local reason = tostring(okStep and why or fine)
			if (retry or not okStep) and strikes < MAX_STRIKES then
				strikes += 1
				setStatus(string.format('%s. Retrying (%d/%d)...', reason, strikes, MAX_STRIKES))
				waitOn(1)
			else
				strikes = 0
				setStatus(reason)
				stopAutoFish(reason)
				break
			end
		end
		task.wait(0.1)
	end

	cleanupFishing()
	setStatus('Stopped')
	running = false
end

-- =================== PERFORMANCE SYSTEMS ===================

local Lighting        = game:GetService("Lighting")
local StarterGui      = game:GetService("StarterGui")
local RenderSvc       = game:GetService("RunService")
local UserGameSettings = UserSettings():GetService("UserGameSettings")

-- ── Anti AFK ──────────────────────────────────────────────────────────────────
local afkConn = nil

local function setAntiAfk(enabled)
	if enabled then
		if afkConn then return end
		-- Fires a fake VR input every 15 min to prevent idle kick (fires the
		-- same RemoteEvent the Roblox idle detector listens to internally).
		afkConn = RunService.Heartbeat:Connect(function()
			-- reset idle timer via hidden API; fallback: simulate a tiny VR event
			pcall(function()
				LocalPlayer:GetMouse() -- touch keeps idle timer alive in most executors
			end)
		end)
		-- Also hook the AFK popup before it fires
		pcall(function()
			local idleConn
			idleConn = LocalPlayer.Idled:Connect(function()
				pcall(function()
					-- dismiss the kick countdown by firing a fake input
					game:GetService("VirtualUser"):CaptureController()
					game:GetService("VirtualUser"):ClickButton2(Vector2.new())
				end)
			end)
		end)
	else
		if afkConn then
			afkConn:Disconnect()
			afkConn = nil
		end
	end
end

-- ── FPS Cap ───────────────────────────────────────────────────────────────────
local fpsCap     = 60
local fpsCapConn = nil

local function setFpsCap(cap)
	fpsCap = cap
	-- setfpscap is available on most modern executors
	if setfpscap then
		pcall(setfpscap, cap)
	else
		-- Fallback: throttle via RenderStepped sleep
		if fpsCapConn then fpsCapConn:Disconnect() fpsCapConn = nil end
		if cap < 300 then
			local frameTime = 1 / cap
			fpsCapConn = RunService.RenderStepped:Connect(function(dt)
				if dt < frameTime then
					pcall(task.wait, frameTime - dt)
				end
			end)
		end
	end
end

-- ── No 3D Render (freeze renderer client-side) ────────────────────────────────
local no3DActive = false

local function setNo3DRender(enabled)
	no3DActive = enabled
	pcall(function()
		local settings = settings()
		if settings then
			-- Disabling rendering passes reduces GPU load significantly
			settings.Rendering.QualityLevel = enabled
				and Enum.QualityLevel.Level01
				or  Enum.QualityLevel.Automatic
		end
	end)
	pcall(function()
		workspace.StreamingEnabled = false
	end)
	-- Collapse shadow and light detail
	pcall(function()
		Lighting.GlobalShadows      = not enabled
		Lighting.FogEnd             = enabled and 1    or 100000
		Lighting.Brightness         = enabled and 0    or 2
	end)
end

-- ── Potato Mode ───────────────────────────────────────────────────────────────
-- Combines low quality level + disables textures/decorations/particles
local potatoOriginals = {}
local potatoActive    = false

local function setPotatoMode(enabled)
	if enabled == potatoActive then return end
	potatoActive = enabled
	pcall(function()
		UserGameSettings.SavedQualityLevel = enabled
			and Enum.SavedQualitySetting.QualityLevel1
			or  Enum.SavedQualitySetting.Automatic
	end)
	-- Kill/restore every Texture, Decal, ParticleEmitter, Trail, Beam in workspace
	for _, obj in ipairs(workspace:GetDescendants()) do
		local t = obj.ClassName
		if t == 'Texture' or t == 'Decal' or t == 'ParticleEmitter'
			or t == 'Trail'  or t == 'Beam' or t == 'SpecialMesh' then
			if enabled then
				potatoOriginals[obj] = obj.Enabled ~= nil and obj.Enabled or true
				pcall(function() obj.Enabled = false end)
			else
				local orig = potatoOriginals[obj]
				if orig ~= nil then
					pcall(function() obj.Enabled = orig end)
				end
			end
		end
	end
	-- Mute atmosphere & sky
	for _, obj in ipairs(Lighting:GetChildren()) do
		if obj:IsA('Atmosphere') or obj:IsA('Sky') then
			if enabled then
				potatoOriginals[obj] = obj.Parent
				pcall(function() obj.Parent = nil end)
			end
		end
	end
	if not enabled then
		-- Restore sky/atmosphere
		for obj, parent in pairs(potatoOriginals) do
			if typeof(parent) == 'Instance' then
				pcall(function() obj.Parent = parent end)
			end
		end
		potatoOriginals = {}
	end
end

-- ── Hide Map ──────────────────────────────────────────────────────────────────
-- Hides the map layer inside PlayerGui (Slayers 2 keeps the minimap in a
-- ScreenGui named "Map" or "Minimap" / "HUD").  Tries several known names.
local MAP_GUI_NAMES  = { 'Map', 'Minimap', 'HUD_Map', 'WorldMap', 'MapGui' }
local hiddenMapGuis  = {}

local function setHideMap(enabled)
	if enabled then
		for _, gui in ipairs(LocalPlayer.PlayerGui:GetChildren()) do
			for _, name in ipairs(MAP_GUI_NAMES) do
				if gui.Name == name and gui:IsA('ScreenGui') then
					hiddenMapGuis[gui] = gui.Enabled
					pcall(function() gui.Enabled = false end)
				end
			end
		end
	else
		for gui, wasEnabled in pairs(hiddenMapGuis) do
			pcall(function() gui.Enabled = wasEnabled end)
		end
		hiddenMapGuis = {}
	end
end

-- =================== PERFORMANCE PAGE UI ===================

local PerfSection = PerfPage:Section({ Name = 'Client Performance', Side = 1 })

PerfSection:Toggle({
	Name     = 'Anti AFK',
	Flag     = 'AntiAfk',
	Default  = false,
	Callback = function(v) setAntiAfk(v) end
})

PerfSection:Slider({
	Name     = 'FPS Cap',
	Flag     = 'FpsCap',
	Min      = 10,
	Max      = 300,
	Default  = 60,
	Suffix   = ' fps',
	Decimals = 0,
	Callback = function(v) setFpsCap(v) end
})

PerfSection:Toggle({
	Name     = 'No 3D Render',
	Flag     = 'No3DRender',
	Default  = false,
	Callback = function(v) setNo3DRender(v) end
})

PerfSection:Toggle({
	Name     = 'Potato Mode',
	Flag     = 'PotatoMode',
	Default  = false,
	Callback = function(v) setPotatoMode(v) end
})

local MapSection = PerfPage:Section({ Name = 'Visibility', Side = 2 })

MapSection:Toggle({
	Name     = 'Hide Map',
	Flag     = 'HideMap',
	Default  = false,
	Callback = function(v) setHideMap(v) end
})

-- =================== DYNAMIC ISLAND ===================

local DI_Frame     = nil
local DI_Dragging  = false
local DI_DragInput = nil
local DI_DragStart = nil
local DI_StartPos  = nil
local libMainFrame = nil

local MENU_KEY = Enum.KeyCode.RightShift   -- เปลี่ยน key ที่นี่

local function buildDynamicIsland()
	local UIS = game:GetService("UserInputService")

	local sg = Instance.new("ScreenGui")
	sg.Name           = "AutoFish_DynamicIsland"
	sg.ResetOnSpawn   = false
	sg.DisplayOrder   = 9999
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	pcall(function() sg.Parent = game:GetService("CoreGui") end)
	if not sg.Parent then sg.Parent = LocalPlayer.PlayerGui end

	local pill = Instance.new("Frame")
	pill.Name             = "Island"
	pill.AnchorPoint      = Vector2.new(0.5, 0)
	pill.Size             = UDim2.new(0, 152, 0, 36)
	pill.Position         = UDim2.new(0.5, 0, 0, 10)
	pill.BackgroundColor3 = Color3.fromRGB(10, 10, 10)
	pill.BorderSizePixel  = 0
	pill.Visible          = false
	pill.ZIndex           = 10
	pill.Parent           = sg

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = pill

	local stroke = Instance.new("UIStroke")
	stroke.Color        = Color3.fromRGB(80, 180, 255)
	stroke.Thickness    = 1.2
	stroke.Transparency = 0.35
	stroke.Parent = pill

	local dot = Instance.new("Frame")
	dot.Size             = UDim2.new(0, 8, 0, 8)
	dot.AnchorPoint      = Vector2.new(0, 0.5)
	dot.Position         = UDim2.new(0, 12, 0.5, 0)
	dot.BackgroundColor3 = Color3.fromRGB(120, 120, 120)
	dot.BorderSizePixel  = 0
	dot.ZIndex           = 11
	dot.Parent           = pill
	local dotCorner = Instance.new("UICorner")
	dotCorner.CornerRadius = UDim.new(1, 0)
	dotCorner.Parent = dot

	local lbl = Instance.new("TextLabel")
	lbl.Size               = UDim2.new(1, -10, 1, 0)
	lbl.Position           = UDim2.new(0, 10, 0, 0)
	lbl.BackgroundTransparency = 1
	lbl.Text               = "🎣  Auto Fish"
	lbl.TextColor3         = Color3.fromRGB(255, 255, 255)
	lbl.Font               = Enum.Font.GothamBold
	lbl.TextSize           = 13
	lbl.ZIndex             = 11
	lbl.Parent             = pill

	pill.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
			DI_Dragging  = true
			DI_DragInput = input
			DI_DragStart = input.Position
			DI_StartPos  = pill.Position
		end
	end)

	UIS.InputChanged:Connect(function(input)
		if DI_Dragging and input == DI_DragInput then
			local d = input.Position - DI_DragStart
			pill.Position = UDim2.new(
				DI_StartPos.X.Scale, DI_StartPos.X.Offset + d.X,
				DI_StartPos.Y.Scale, DI_StartPos.Y.Offset + d.Y
			)
		end
	end)

	UIS.InputEnded:Connect(function(input)
		if input == DI_DragInput and DI_Dragging then
			local d = input.Position - DI_DragStart
			if math.abs(d.X) < 6 and math.abs(d.Y) < 6 then
				-- reset กลับ top-center ทุกครั้งก่อน hide
				pill.Position = UDim2.new(0.5, 0, 0, 10)
				pill.Visible = false
				if libMainFrame then
					libMainFrame.Visible = true
				end
			end
			DI_Dragging = false
		end
	end)

	RunService.Heartbeat:Connect(function()
		if pill.Visible then
			dot.BackgroundColor3 = autoFishing
				and Color3.fromRGB(80, 220, 100)
				or  Color3.fromRGB(120, 120, 120)
			lbl.Text = autoFishing and "🎣  Fishing..." or "🎣  Auto Fish"
		end
	end)

	DI_Frame = pill
end

-- =================== FISH PAGE UI ===================

local FishSection = FishPage:Section({ Name = 'Fishing Controls', Side = 1 })
mainToggleRef = FishSection:Toggle({
	Name     = 'Enable Auto Fish',
	Flag     = 'AutoFish',
	Default  = false,
	Callback = function(value)
		if value == autoFishing and (value == false or running) then return end
		autoFishing = value
		if value then
			startFreeze()
			task.spawn(fishingLoop)
			if webhookOnStart then
				queueWebhook(buildStartEmbed())
				startWebhookDrain()
			end
			notify('Auto Fish', 'เริ่ม fishing loop', 2)
		else
			stopFreeze()
			notify('Auto Fish', 'หยุด fishing loop', 2)
		end
		updateStats()
	end
})

FishSection:Toggle({
	Name     = 'Auto Equip Best Rod',
	Flag     = 'AutoBestRod',
	Default  = true,
	Callback = function(v)
		autoBestRod = v
		if v and running then
			task.spawn(doEquipBestRod)
		end
	end
})

FishSection:Toggle({
	Name     = 'Auto Equip Bait',
	Flag     = 'AutoBait',
	Default  = true,
	Callback = function(v)
		autoBait = v
		if v and running then
			task.spawn(doEquipBait)
		end
	end
})

FishSection:Toggle({
	Name     = 'Auto Pickup (Heartbeat)',
	Flag     = 'AutoPickup',
	Default  = true,
	Callback = function(v)
		autoPickup = v
		if v and autoFishing then
			startPickupLoop()
		elseif not v then
			stopPickupLoop()
		end
	end
})

-- =================== STOP ON CATCH ===================

local PresetSection = FishPage:Section({ Name = 'Stop On Catch — Lost Items', Side = 1 })

for _, itemName in ipairs(PRESET_STOP_ITEMS) do
	local flagKey = 'StopPreset_' .. itemName:gsub('%s+', '_')
	PresetSection:Toggle({
		Name     = itemName,
		Flag     = flagKey,
		Default  = false,
		Callback = function(v)
			stopList[itemName] = v or nil
			updateStats()
		end
	})
end

-- =================== STATS ===================

local StatsSection = FishPage:Section({ Name = 'Live Stats', Side = 2 })

statsLabel = StatsSection:Label('Items Caught: 0\nLast Caught: None\nLast Attempt: None\nStatus: Idle\nAuto Fish: OFF\nStop Items: None')

task.defer(function()
	task.wait(0.5)
	for _, obj in ipairs(game:GetService("CoreGui"):GetDescendants()) do
		if obj:IsA("TextLabel") and tostring(obj.Text):find("Items Caught") then
			obj.TextXAlignment = Enum.TextXAlignment.Left
			obj.TextWrapped    = true
		end
	end
end)

StatsSection:Button({
	Name     = 'Refresh',
	Flag     = 'RefreshStats',
	Callback = function() updateStats() end
})

-- =================== WEBHOOK PAGE UI ===================

local WebSection = WebhookPage:Section({ Name = 'Discord Webhook', Side = 1 })
WebSection:Textbox({
	Flag        = 'WebhookURL',
	Default     = '',
	Numeric     = false,
	Placeholder = 'https://discord.com/api/webhooks/...',
	Finished    = true,
	Callback    = function(text) webhookURL = text end
})

WebSection:Toggle({
	Name     = 'Enable Webhook',
	Flag     = 'WebhookEnabled',
	Default  = false,
	Callback = function(v)
		webhookEnabled = v
		notify('Webhook', v and 'เปิด webhook แล้ว' or 'ปิด webhook แล้ว', 2)
	end
})

local WebEventsSection = WebhookPage:Section({ Name = 'Notification Events', Side = 2 })

WebEventsSection:Toggle({
	Name     = 'Notify on Start',
	Flag     = 'WebhookOnStart',
	Default  = true,
	Callback = function(v) webhookOnStart = v end
})

WebEventsSection:Toggle({
	Name     = 'Notify on Catch',
	Flag     = 'WebhookOnCatch',
	Default  = true,
	Callback = function(v) webhookOnCatch = v end
})

WebEventsSection:Toggle({
	Name     = 'Notify on Stop',
	Flag     = 'WebhookOnStop',
	Default  = true,
	Callback = function(v) webhookOnStop = v end
})

local WebToolsSection = WebhookPage:Section({ Name = 'Tools & Stats', Side = 1 })

WebToolsSection:Button({
	Name     = 'Send Test Embed',
	Flag     = 'WebhookTest',
	Callback = function()
		if webhookURL == '' then
			notify('Webhook', 'ใส่ URL ก่อนนะ', 3)
			return
		end
		local prev = webhookEnabled
		webhookEnabled = true
		queueWebhook(buildCatchEmbed('Test Fish [Rare]', fishCaught))
		startWebhookDrain()
		webhookEnabled = prev
		notify('Webhook', 'Test embed ส่งแล้ว ตรวจ Discord ได้เลย', 3)
	end
})

WebToolsSection:Button({
	Name     = 'Clear Queue',
	Flag     = 'WebhookClearQueue',
	Callback = function()
		webhookQueue = {}
		notify('Webhook', 'Queue cleared.', 2)
	end
})

WebToolsSection:Button({
	Name     = 'Refresh Stats',
	Flag     = 'WebhookRefresh',
	Callback = function()
		if webhookStatsLabel then
			pcall(function()
				webhookStatsLabel:Update(
					'Sent: ' .. webhookSent .. '  |  Failed: ' .. webhookFailed
					.. '\nQueue: ' .. #webhookQueue
				)
			end)
		end
	end
})

-- =================== INIT ===================

notify(
	'Auto Fish Loaded',
	'ยืนที่ชายน้ำก่อนเปิด | ตั้ง webhook ใน tab "Webhook" | Lost items อยู่ใน "Auto Fish" | [RightShift] เปิด/ปิด UI',
	5
)

local preInitGuis = {}
for _, gui in ipairs(game:GetService("CoreGui"):GetChildren()) do
	preInitGuis[gui] = true
end

Window:Init()

buildDynamicIsland()

-- =================== MENU KEYBIND ===================

do
	local UIS = game:GetService("UserInputService")
	UIS.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.KeyCode ~= MENU_KEY then return end
		if not libMainFrame then return end
		local show = not libMainFrame.Visible
		libMainFrame.Visible = show
		if DI_Frame then
			if not show then
				DI_Frame.Position = UDim2.new(0.5, 0, 0, 10)
			end
			DI_Frame.Visible = not show
		end
	end)
end

-- =================== END MENU KEYBIND ===================

task.defer(function()
	task.wait(0.3)
	for _, gui in ipairs(game:GetService("CoreGui"):GetChildren()) do
		if not preInitGuis[gui] and gui:IsA("ScreenGui") then
			for _, child in ipairs(gui:GetChildren()) do
				if child:IsA("Frame") then
					libMainFrame = child
					child:GetPropertyChangedSignal("Visible"):Connect(function()
						if DI_Frame then
							if not child.Visible then
								-- reset position ก่อนโชว์ทุกครั้ง
								DI_Frame.Position = UDim2.new(0.5, 0, 0, 10)
							end
							DI_Frame.Visible = not child.Visible
						end
					end)
					break
				end
			end
			break
		end
	end
end)

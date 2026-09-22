--!strict

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local PlotTypes = require(ReplicatedStorage.Shared.Types.PlotTypes)
local TileCatalog = require(ReplicatedStorage.Shared.Config.TileCatalog)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local NetworkService = require(ReplicatedStorage.Network.NetworkService)
local EconomyService = require(ServerScriptService.Server.Services.EconomyService)
local DataService = require(ServerScriptService.Server.Services.DataService)
local InteractableComponent = require(ServerScriptService.Server.Components.InteractableComponent)
local RateLimiter = require(ServerScriptService.Server.Util.RateLimiter)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

local PlotService = {}

PlotService.ItemRemoved = Signal.new()
PlotService.ItemAdded = Signal.new()

local GRID_COLUMNS: number = 4
local PLOT_SPACING: number = 140
local PLACED_CONTAINER_NAME: string = "PlacedObjects"
local DEFAULT_PLOT_SIZE: Vector2 = Vector2.new(80, 80)
local MIN_MARGIN: Vector3 = Vector3.new(0.2, 0.2, 0.2)
local FALLBACK_ITEM_SIZE: Vector3 = Vector3.new(3, 3, 3)

local MAX_INTERACTION_DISTANCE: number = 85.0
local MAX_Y_DEVIATION_TOLERANCE: number = 2.0

local activePlots: { [Player]: PlotTypes.PlotState } = {}
local instanceToUuidMap: { [Instance]: string } = {}
local uuidToInstanceMap: { [string]: Model } = {}
local occupiedSlots: { [number]: boolean } = {}

local placementLimiter = RateLimiter.new(6, 2)
local removalLimiter = RateLimiter.new(10, 4)

local placedContainer: Folder do
	local existing = workspace:FindFirstChild(PLACED_CONTAINER_NAME)
	if existing and existing:IsA("Folder") then
		placedContainer = existing
	else
		local folder = Instance.new("Folder")
		folder.Name = PLACED_CONTAINER_NAME
		folder.Parent = workspace
		placedContainer = folder
	end
end

local spatialOverlapParams: OverlapParams = OverlapParams.new()
spatialOverlapParams.FilterType = Enum.RaycastFilterType.Include
spatialOverlapParams.FilterDescendantsInstances = { placedContainer }
spatialOverlapParams.MaxParts = 50

local function allocatePlotSlot(): (number, CFrame)
	local slotId = 1
	while occupiedSlots[slotId] do
		slotId += 1
	end
	occupiedSlots[slotId] = true

	local col = (slotId - 1) % GRID_COLUMNS
	local row = math.floor((slotId - 1) / GRID_COLUMNS)
	local x = col * PLOT_SPACING
	local z = row * PLOT_SPACING

	return slotId, CFrame.new(x, 0, z)
end

local function releasePlotSlot(slotId: number)
	occupiedSlots[slotId] = nil
end

local function createFallbackModel(itemId: string, size: Vector3): Model
	local itemModel = Instance.new("Model")
	itemModel.Name = `Model_{itemId}`

	local mainPart = Instance.new("Part")
	mainPart.Name = "MainPart"
	mainPart.Size = size
	mainPart.Anchored = true
	mainPart.CanCollide = true
	mainPart.CanQuery = true
	mainPart.Material = Enum.Material.SmoothPlastic
	mainPart.Color = if itemId == "stove" then Color3.fromRGB(210, 105, 30) else Color3.fromRGB(50, 130, 230)
	mainPart.Parent = itemModel

	itemModel.PrimaryPart = mainPart
	return itemModel
end

local function instantiatePlacedItem(userId: number, serialized: PlotTypes.SerializedItem): Model
	local itemId = serialized.itemId
	local config = TileCatalog.GetItemConfig(itemId)
	local targetCF = MathUtil.TransformToCFrame(serialized.transform)

	local prefabs = ServerStorage:FindFirstChild("Prefabs")
	local template = if prefabs then prefabs:FindFirstChild(itemId) :: Model? else nil

	local itemModel: Model = if template
		then template:Clone()
		else createFallbackModel(itemId, if config then config.size else FALLBACK_ITEM_SIZE)

	itemModel.Name = string.format("Placed_%s_%d", itemId, userId)
	itemModel:PivotTo(targetCF)
	itemModel.Parent = placedContainer

	local mainPart = itemModel.PrimaryPart or itemModel:FindFirstChildWhichIsA("BasePart")
	if not mainPart then
		mainPart = Instance.new("Part")
		mainPart.Size = if config then config.size else FALLBACK_ITEM_SIZE
		mainPart.CFrame = targetCF
		mainPart.Anchored = true
		mainPart.Transparency = 1
		mainPart.Parent = itemModel
		itemModel.PrimaryPart = mainPart
	end

	mainPart.CanCollide = true
	mainPart.CanQuery = true

	local pathModifier = itemModel:FindFirstChildWhichIsA("PathfindingModifier") or Instance.new("PathfindingModifier")
	pathModifier.PassThrough = false
	pathModifier.Parent = itemModel

	itemModel:SetAttribute("UUID", serialized.uuid)
	itemModel:SetAttribute("OwnerUserId", userId)
	mainPart:SetAttribute("UUID", serialized.uuid)
	mainPart:SetAttribute("OwnerUserId", userId)

	uuidToInstanceMap[serialized.uuid] = itemModel
	instanceToUuidMap[mainPart] = serialized.uuid

	InteractableComponent.Register(mainPart, itemId, userId, serialized.uuid)
	PlotService.ItemAdded:Fire(serialized.uuid, itemId, userId, itemModel)

	local destroyingConn: RBXScriptConnection? = nil
	destroyingConn = itemModel.Destroying:Connect(function()
		if destroyingConn then
			destroyingConn:Disconnect()
			destroyingConn = nil
		end

		InteractableComponent.Unregister(mainPart)
		instanceToUuidMap[mainPart] = nil
		uuidToInstanceMap[serialized.uuid] = nil
	end)

	return itemModel
end

local function teleportCharacterToPlot(character: Model, originCF: CFrame)
	local hrp = character:WaitForChild("HumanoidRootPart", 5) :: BasePart?
	if hrp then
		task.wait(0.1)
		hrp.CFrame = originCF * CFrame.new(0, 3.5, 15)
	end
end

local function validatePlayerProximity(player: Player, targetWorldPos: Vector3): (boolean, string?)
	local character = player.Character
	if not character then
		return false, "NoCharacter"
	end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character:FindFirstChildOfClass("Humanoid")

	if not hrp or not humanoid or humanoid.Health <= 0 then
		return false, "CharacterUnavailable"
	end

	local dist = (Vector3.new(hrp.Position.X, 0, hrp.Position.Z) - Vector3.new(targetWorldPos.X, 0, targetWorldPos.Z)).Magnitude
	if dist > MAX_INTERACTION_DISTANCE then
		warn(string.format("[Security] Anti-Cheat triggered: %s attempted interaction at distance %.1f (Limit: %d)", player.Name, dist, MAX_INTERACTION_DISTANCE))
		return false, "DistanceLimitExceeded"
	end

	return true, nil
end

function PlotService.AssignPlot(player: Player): PlotTypes.PlotState?
	if activePlots[player] then
		return activePlots[player]
	end

	local slotId, originCF = allocatePlotSlot()

	local loadSuccess, _ = pcall(function()
		DataService.LoadProfile(player)
	end)

	if not loadSuccess or not player:IsDescendantOf(Players) then
		releasePlotSlot(slotId)
		return nil
	end

	local placedItemsCopy = DataService.GetPlacedItems(player) or {}

	local floorName = `PlotFloor_{slotId}`
	local existingFloor = workspace:FindFirstChild(floorName)
	if not existingFloor then
		local floor = Instance.new("Part")
		floor.Name = floorName
		floor.Size = Vector3.new(DEFAULT_PLOT_SIZE.X, 1, DEFAULT_PLOT_SIZE.Y)
		floor.CFrame = originCF * CFrame.new(0, -0.5, 0)
		floor.Anchored = true
		floor.CanCollide = true
		floor.Material = Enum.Material.SmoothPlastic
		floor.Color = Color3.fromRGB(40, 45, 55)
		floor.Parent = workspace
	end

	local hasAnyItem = false
	for _ in pairs(placedItemsCopy) do
		hasAnyItem = true
		break
	end

	if not hasAnyItem then
		local stoveUUID = HttpService:GenerateGUID(false)
		local stoveCF = originCF * CFrame.new(6, 2, 0)
		local starterStove: PlotTypes.SerializedItem = {
			uuid = stoveUUID,
			itemId = "stove",
			transform = MathUtil.CFrameToTransform(stoveCF),
		}
		placedItemsCopy[stoveUUID] = starterStove
		DataService.SetPlacedItem(player, stoveUUID, starterStove)

		local regUUID = HttpService:GenerateGUID(false)
		local regCF = originCF * CFrame.new(-6, 1.5, 0)
		local starterRegister: PlotTypes.SerializedItem = {
			uuid = regUUID,
			itemId = "cash_register",
			transform = MathUtil.CFrameToTransform(regCF),
		}
		placedItemsCopy[regUUID] = starterRegister
		DataService.SetPlacedItem(player, regUUID, starterRegister)
	end

	local plotState: PlotTypes.PlotState = {
		plotId = slotId,
		ownerUserId = player.UserId,
		originCFrame = originCF,
		size = DEFAULT_PLOT_SIZE,
		placedItems = placedItemsCopy,
	}

	activePlots[player] = plotState

	for _, item in pairs(placedItemsCopy) do
		instantiatePlacedItem(player.UserId, item)
	end

	if player.Character then
		task.spawn(teleportCharacterToPlot, player.Character, originCF)
	end
	player.CharacterAdded:Connect(function(char)
		teleportCharacterToPlot(char, originCF)
	end)

	return plotState
end

function PlotService.ReleasePlot(player: Player)
	local state = activePlots[player]
	if not state then
		return
	end

	for uuid, item in pairs(state.placedItems) do
		PlotService.ItemRemoved:Fire(uuid, item.itemId, player.UserId)
		local model = uuidToInstanceMap[uuid]
		if model then
			model:Destroy()
		end
	end

	releasePlotSlot(state.plotId)
	activePlots[player] = nil
end

function PlotService.GetPlot(player: Player): PlotTypes.PlotState?
	return activePlots[player]
end

function PlotService.GetInstanceByUuid(uuid: string): Model?
	return uuidToInstanceMap[uuid]
end

function PlotService.RequestPlacement(player: Player, itemId: string, targetCFrame: CFrame): boolean
	local resultEvent = NetworkService.GetEvent("PlacementResult")
	local plot = activePlots[player]
	if not plot then
		if resultEvent then resultEvent:FireClient(player, false, "PlotNotFound") end
		return false
	end

	local itemConfig = TileCatalog.GetItemConfig(itemId)
	if not itemConfig then
		if resultEvent then resultEvent:FireClient(player, false, "InvalidItem") end
		return false
	end

	if not MathUtil.IsSafeCFrame(targetCFrame) then
		if resultEvent then resultEvent:FireClient(player, false, "MalformedData") end
		return false
	end

	local isProximityOk, reason = validatePlayerProximity(player, targetCFrame.Position)
	if not isProximityOk then
		if resultEvent then resultEvent:FireClient(player, false, reason) end
		return false
	end

	local expectedY = plot.originCFrame.Position.Y + (itemConfig.size.Y / 2)
	if math.abs(targetCFrame.Position.Y - expectedY) > MAX_Y_DEVIATION_TOLERANCE then
		targetCFrame = CFrame.new(targetCFrame.Position.X, expectedY, targetCFrame.Position.Z) * targetCFrame.Rotation
	end

	local fixedPosition = Vector3.new(targetCFrame.Position.X, expectedY, targetCFrame.Position.Z)
	local _, ry, _ = targetCFrame:ToOrientation()
	local sanitizedCFrame = CFrame.new(fixedPosition) * CFrame.Angles(0, ry, 0)

	if not MathUtil.AreCornersInsidePlot(sanitizedCFrame, itemConfig.size, plot.originCFrame, plot.size) then
		if resultEvent then resultEvent:FireClient(player, false, "OutOfBounds") end
		return false
	end

	local testSize = itemConfig.size - MIN_MARGIN
	if testSize.X <= 0 or testSize.Y <= 0 or testSize.Z <= 0 then
		testSize = itemConfig.size * 0.9
	end

	local collidingParts = workspace:GetPartBoundsInBox(sanitizedCFrame, testSize, spatialOverlapParams)
	for _, part in ipairs(collidingParts) do
		if part:GetAttribute("OwnerUserId") ~= nil or part:GetAttribute("UUID") ~= nil then
			if resultEvent then resultEvent:FireClient(player, false, "SpaceOccupied") end
			return false
		end
	end

	if not EconomyService.RemoveBalance(player, itemConfig.price) then
		if resultEvent then resultEvent:FireClient(player, false, "InsufficientFunds") end
		return false
	end

	local uuid = HttpService:GenerateGUID(false)
	local serializedItem: PlotTypes.SerializedItem = {
		uuid = uuid,
		itemId = itemId,
		transform = MathUtil.CFrameToTransform(sanitizedCFrame),
	}

	plot.placedItems[uuid] = serializedItem
	DataService.SetPlacedItem(player, uuid, serializedItem)

	instantiatePlacedItem(player.UserId, serializedItem)

	local updateEvent = NetworkService.GetEvent("PlotStateUpdated")
	if updateEvent then
		updateEvent:FireClient(player, "ItemAdded", serializedItem)
	end

	if resultEvent then
		resultEvent:FireClient(player, true, "Success")
	end

	return true
end

function PlotService.RequestRemoval(player: Player, targetUuid: string): boolean
	if typeof(targetUuid) ~= "string" then
		return false
	end

	local plot = activePlots[player]
	if not plot or not plot.placedItems[targetUuid] then
		return false
	end

	local model = uuidToInstanceMap[targetUuid]
	if model and model.PrimaryPart then
		local isProximityOk = validatePlayerProximity(player, model.PrimaryPart.Position)
		if not isProximityOk then
			return false
		end
	end

	local itemId = plot.placedItems[targetUuid].itemId

	plot.placedItems[targetUuid] = nil
	DataService.RemovePlacedItem(player, targetUuid)

	PlotService.ItemRemoved:Fire(targetUuid, itemId, player.UserId)

	if model then
		model:Destroy()
	end

	local updateEvent = NetworkService.GetEvent("PlotStateUpdated")
	if updateEvent then
		updateEvent:FireClient(player, "ItemRemoved", targetUuid)
	end

	return true
end

function PlotService.Init()
	local requestEvent = NetworkService.GetEvent("RequestPlacement")
	local removeEvent = NetworkService.GetEvent("RequestRemoval")
	local getPlotFunction = NetworkService.GetFunction("GetPlotData")

	getPlotFunction.OnServerInvoke = function(player: Player)
		local plot = activePlots[player]
		if not plot then
			return nil
		end

		return {
			plotId = plot.plotId,
			originCFrame = plot.originCFrame,
			size = plot.size,
			placedItems = plot.placedItems,
		}
	end

	requestEvent.OnServerEvent:Connect(function(player: Player, itemId: unknown, cf: unknown)
		if not placementLimiter:Check(player, "Placement") then
			warn(string.format("[Security] Spam detected from %s (Placement dropped)", player.Name))
			local resultEvent = NetworkService.GetEvent("PlacementResult")
			if resultEvent then
				resultEvent:FireClient(player, false, "RateLimited")
			end
			return
		end

		if typeof(itemId) == "string" and typeof(cf) == "CFrame" then
			PlotService.RequestPlacement(player, itemId, cf)
		end
	end)

	removeEvent.OnServerEvent:Connect(function(player: Player, target: unknown)
		if not removalLimiter:Check(player, "Removal") then
			warn(string.format("[Security] Spam detected from %s (Removal dropped)", player.Name))
			return
		end

		if typeof(target) == "string" then
			PlotService.RequestRemoval(player, target)
		elseif typeof(target) == "Instance" then
			local uuid = instanceToUuidMap[target] or target:GetAttribute("UUID")
			if typeof(uuid) == "string" then
				PlotService.RequestRemoval(player, uuid)
			end
		end
	end)

	Players.PlayerAdded:Connect(function(player: Player)
		PlotService.AssignPlot(player)
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(PlotService.AssignPlot, player)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		placementLimiter:CleanupPlayer(player)
		removalLimiter:CleanupPlayer(player)
		PlotService.ReleasePlot(player)
	end)
end

return PlotService

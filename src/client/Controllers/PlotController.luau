--!strict

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local NetworkService = require(ReplicatedStorage.Network.NetworkService)
local TileCatalog = require(ReplicatedStorage.Shared.Config.TileCatalog)
local Maid = require(ReplicatedStorage.Shared.Util.Maid)

type ItemConfig = {
	size: Vector3,
	[string]: any,
}

type PlotData = {
	originCFrame: CFrame,
	[string]: any,
}

local GRID_SIZE = 2
local MAX_RAY_DISTANCE = 500
local DEFAULT_GHOST_COLOR = Color3.fromRGB(0, 255, 100)
local ERROR_FLASH_COLOR = Color3.fromRGB(255, 60, 60)
local CANCEL_ACTION = "PlotController_CancelPlacement"
local ROTATE_ACTION = "PlotController_RotatePlacement"

local PlotController = {}

local activeItemId: string? = nil
local ghostModel: Model? = nil
local currentRotation: number = 0
local currentCFrame: CFrame? = nil
local currentPlotOriginY: number = 0

local activeFlashTween: Tween? = nil
local playerConnections: { [Player]: { RBXScriptConnection } } = {}

local cachedRayParams = RaycastParams.new()
cachedRayParams.FilterType = Enum.RaycastFilterType.Exclude

local placementMaid = Maid.new()

local function updateRayFilter()
	local filterList: { Instance } = {}

	if ghostModel then
		table.insert(filterList, ghostModel)
	end

	for _, p in ipairs(Players:GetPlayers()) do
		local char = p.Character
		if char then
			table.insert(filterList, char)
		end
	end

	cachedRayParams.FilterDescendantsInstances = filterList
end

local function trackPlayer(targetPlayer: Player)
	local conns: { RBXScriptConnection } = {}

	table.insert(conns, targetPlayer.CharacterAdded:Connect(function()
		updateRayFilter()
	end))

	table.insert(conns, targetPlayer.CharacterRemoving:Connect(function()
		task.defer(updateRayFilter)
	end))

	playerConnections[targetPlayer] = conns

	if targetPlayer.Character then
		updateRayFilter()
	end
end

local function untrackPlayer(targetPlayer: Player)
	local conns = playerConnections[targetPlayer]
	if conns then
		for _, conn in ipairs(conns) do
			conn:Disconnect()
		end
		playerConnections[targetPlayer] = nil
	end
	updateRayFilter()
end

local function flashGhostColor(color: Color3)
	if not ghostModel or not ghostModel.PrimaryPart then return end
	local part = ghostModel.PrimaryPart

	if activeFlashTween then
		activeFlashTween:Cancel()
		activeFlashTween = nil
	end

	part.Color = color
	local tweenInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	activeFlashTween = TweenService:Create(part, tweenInfo, { Color = DEFAULT_GHOST_COLOR })
	activeFlashTween:Play()
end

function PlotController.CancelPlacement()
	if activeFlashTween then
		activeFlashTween:Cancel()
		activeFlashTween = nil
	end

	placementMaid:DoCleaning()

	activeItemId = nil
	ghostModel = nil
	currentRotation = 0
	currentCFrame = nil

	updateRayFilter()
end

local function handlePlaceRequest()
	if not activeItemId or not currentCFrame then return end

	local requestEvent = NetworkService.GetEvent("RequestPlacement")
	if requestEvent then
		requestEvent:FireServer(activeItemId, currentCFrame)
	end
end

function PlotController.StartPlacement(itemId: string)
	if activeItemId == itemId then
		PlotController.CancelPlacement()
		return
	end

	PlotController.CancelPlacement()

	local config: ItemConfig? = TileCatalog.GetItemConfig(itemId)
	if not config then 
		warn(string.format("[PlotController]: Config not found for itemId '%s'", tostring(itemId)))
		return 
	end

	activeItemId = itemId

	local preview = Instance.new("Part")
	preview.Name = "GhostPreview"
	preview.Size = config.size
	preview.Color = DEFAULT_GHOST_COLOR
	preview.Transparency = 0.5
	preview.CanCollide = false
	preview.CanTouch = false
	preview.CanQuery = false
	preview.CastShadow = false
	preview.Anchored = true

	local model = Instance.new("Model")
	model.Name = "GhostModel_" .. itemId
	preview.Parent = model
	model.PrimaryPart = preview
	model.Parent = workspace
	ghostModel = model

	placementMaid:GiveTask(model)
	updateRayFilter()

	ContextActionService:BindAction(CANCEL_ACTION, function(_, state)
		if state == Enum.UserInputState.Begin then
			PlotController.CancelPlacement()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.UserInputType.MouseButton2, Enum.KeyCode.Escape)

	placementMaid:GiveTask(function()
		ContextActionService:UnbindAction(CANCEL_ACTION)
	end)

	ContextActionService:BindAction(ROTATE_ACTION, function(_, state)
		if state == Enum.UserInputState.Begin then
			currentRotation = (currentRotation + 90) % 360
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.R)

	placementMaid:GiveTask(function()
		ContextActionService:UnbindAction(ROTATE_ACTION)
	end)

	placementMaid:GiveTask(UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			handlePlaceRequest()
		end
	end))

	placementMaid:GiveTask(RunService.RenderStepped:Connect(function()
		if not ghostModel or not ghostModel.PrimaryPart then return end

		local camera = workspace.CurrentCamera
		if not camera then return end

		local mousePos = UserInputService:GetMouseLocation()
		local ray = camera:ViewportPointToRay(mousePos.X, mousePos.Y)

		local result = workspace:Raycast(ray.Origin, ray.Direction * MAX_RAY_DISTANCE, cachedRayParams)
		local targetPos: Vector3? = nil

		if result then
			targetPos = result.Position
		else
			if math.abs(ray.Direction.Y) > 0.0001 then
				local t = (currentPlotOriginY - ray.Origin.Y) / ray.Direction.Y
				if t > 0 then
					targetPos = ray.Origin + ray.Direction * t
				end
			end
		end

		if targetPos then
			local snappedX = math.floor(targetPos.X / GRID_SIZE + 0.5) * GRID_SIZE
			local snappedZ = math.floor(targetPos.Z / GRID_SIZE + 0.5) * GRID_SIZE
			local posY = currentPlotOriginY + (config.size.Y / 2)

			local targetCFrame = CFrame.new(snappedX, posY, snappedZ) * CFrame.Angles(0, math.rad(currentRotation), 0)
			currentCFrame = targetCFrame
			ghostModel:PivotTo(targetCFrame)
		end
	end))
end

function PlotController.Init()
	task.spawn(function()
		local getPlotFunc = NetworkService.GetFunction("GetPlotData")
		if not getPlotFunc then
			warn("[PlotController]: RemoteFunction 'GetPlotData' not found.")
			return
		end

		local plotData: PlotData? = nil
		local attempts = 0
		local maxAttempts = 15

		while not plotData and attempts < maxAttempts do
			attempts += 1
			local success, result = pcall(function()
				return getPlotFunc:InvokeServer()
			end)

			if success and result then
				plotData = result
				break
			end

			task.wait(1)
		end

		if plotData and plotData.originCFrame then
			currentPlotOriginY = plotData.originCFrame.Position.Y
		else
			warn("[PlotController]: Failed to retrieve plot data after max attempts.")
		end
	end)

	local resultEvent = NetworkService.GetEvent("PlacementResult")
	if resultEvent then
		resultEvent.OnClientEvent:Connect(function(success: boolean, reason: string?)
			if not success then
				flashGhostColor(ERROR_FLASH_COLOR)
				warn(string.format("[PlotController - Placement Rejected]: %s", tostring(reason)))
			end
		end)
	end

	for _, p in ipairs(Players:GetPlayers()) do
		trackPlayer(p)
	end
	Players.PlayerAdded:Connect(trackPlayer)
	Players.PlayerRemoving:Connect(untrackPlayer)
end

return PlotController

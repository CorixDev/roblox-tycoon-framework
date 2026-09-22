--!strict

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local NPCTypes = require(ReplicatedStorage.Shared.Types.NPCTypes)
local FSM = require(ReplicatedStorage.Shared.Util.FSM)
local InteractableComponent = require(ServerScriptService.Server.Components.InteractableComponent)
local OrderService = require(ServerScriptService.Server.Services.OrderService)
local MovementService = require(ServerScriptService.Server.Services.MovementService)
local CollisionService = require(ServerScriptService.Server.Services.CollisionService)
local PlotService = require(ServerScriptService.Server.Services.PlotService)

local NPCService = {}

type WorkerContext = {
	npcId: string,
	model: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	ownerUserId: number,
	role: NPCTypes.NPCRole,
	assignedStationUuid: string?,
	currentOrderId: string?,
	currentMovementToken: NPCTypes.CancellationToken?,
	statusLabel: TextLabel?,
	isAlive: boolean,
	fsm: any,
}

local activeWorkers: { [string]: WorkerContext } = {}
local occupiedStationsByUuid: { [string]: string } = {}

local function setWorkerStatus(ctx: WorkerContext, text: string)
	if ctx.statusLabel then ctx.statusLabel.Text = text end
end

local function getStationBasePart(inst: Instance?): BasePart?
	if not inst then return nil end
	if inst:IsA("BasePart") then return inst end
	if inst:IsA("Model") then
		return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart")
	end
	return nil
end

local function getStationStandPosition(station: BasePart, isBehind: boolean): Vector3
	local safeOffset = (station.Size.Z / 2) + 2.5
	local dir = if isBehind then -station.CFrame.LookVector else station.CFrame.LookVector
	local floorY = station.Position.Y - (station.Size.Y / 2)
	local flatPos = station.Position + (dir * safeOffset)
	return Vector3.new(flatPos.X, floorY + 2.0, flatPos.Z)
end

local function getStationDockCFrame(station: BasePart, isBehind: boolean): CFrame
	local standPos = getStationStandPosition(station, isBehind)
	return CFrame.lookAt(standPos, Vector3.new(station.Position.X, standPos.Y, station.Position.Z))
end

local function findFreeStation(ctx: WorkerContext): (BasePart?, string?)
	local targetItemId = if ctx.role == "Cook" then "stove" else "cash_register"
	for instance, data in pairs(InteractableComponent.GetActiveInteractables()) do
		if data.ownerUserId == ctx.ownerUserId and data.itemId == targetItemId then
			if not occupiedStationsByUuid[data.uuid] and instance.Parent then
				local part = getStationBasePart(instance)
				if part then return part, data.uuid end
			end
		end
	end
	return nil, nil
end

local IdleState = {
	Name = "Idle",
	OnEnter = function(_, ctx: WorkerContext)
		setWorkerStatus(ctx, if ctx.role == "Cook" then "🍳 Looking for stove..." else "💵 Looking for register...")
	end,
	OnUpdate = function(_, ctx: WorkerContext)
		local stationPart, stationUuid = findFreeStation(ctx)
		if stationPart and stationUuid then
			occupiedStationsByUuid[stationUuid] = ctx.npcId
			ctx.assignedStationUuid = stationUuid
			ctx.fsm:ChangeState("WalkingToStation", stationPart, stationUuid)
		end
	end,
}

local WalkingToStationState = {
	Name = "WalkingToStation",
	OnEnter = function(_, ctx: WorkerContext, stationPart: BasePart, stationUuid: string)
		task.spawn(function()
			local targetPos = getStationStandPosition(stationPart, true)
			local initialDist = (ctx.rootPart.Position - targetPos).Magnitude

			local arrived = false
			if initialDist <= 3.5 then
				arrived = true
			else
				local token = MovementService.CreateCancellationToken()
				ctx.currentMovementToken = token
				arrived = MovementService.WalkTo(ctx.model, ctx.humanoid, ctx.rootPart, targetPos, 16, token, stationPart.Position)
				ctx.currentMovementToken = nil
			end

			local finalDist = (ctx.rootPart.Position - targetPos).Magnitude

			if (arrived or finalDist <= 5.5) and ctx.isAlive and ctx.model.Parent and stationPart.Parent then
				MovementService.DockTo(ctx.rootPart, getStationDockCFrame(stationPart, true), 0.25)
				ctx.fsm:ChangeState("Working")
			else
				if ctx.isAlive and ctx.model.Parent and stationPart.Parent and finalDist <= 12.0 then
					MovementService.DockTo(ctx.rootPart, getStationDockCFrame(stationPart, true), 0.3)
					ctx.fsm:ChangeState("Working")
				else
					occupiedStationsByUuid[stationUuid] = nil
					ctx.assignedStationUuid = nil
					ctx.fsm:ChangeState("Idle")
				end
			end
		end)
	end,
}

local WorkingState = {
	Name = "Working",
	OnEnter = function(_, ctx: WorkerContext)
		setWorkerStatus(ctx, "⏳ Waiting for order...")
	end,
	OnUpdate = function(_, ctx: WorkerContext)
		local assignedUuid = ctx.assignedStationUuid
		local currentStationInst = if assignedUuid then PlotService.GetInstanceByUuid(assignedUuid) else nil
		local stationPart = getStationBasePart(currentStationInst)

		if not stationPart or not stationPart.Parent then
			if assignedUuid then occupiedStationsByUuid[assignedUuid] = nil end
			ctx.assignedStationUuid = nil
			ctx.fsm:ChangeState("Idle")
			return
		end

		if ctx.role == "Cook" then
			local pendingOrder = OrderService.GetPendingOrderForCook(ctx.ownerUserId)
			if pendingOrder then
				OrderService.SetOrderStatus(pendingOrder.orderId, "Cooking")
				ctx.currentOrderId = pendingOrder.orderId
				ctx.fsm:ChangeState("Cooking", pendingOrder, stationPart)
			end
		end
	end,
}

local CookingState = {
	Name = "Cooking",
	OnEnter = function(_, ctx: WorkerContext, order: any, stovePart: BasePart)
		setWorkerStatus(ctx, "🔥 Cooking food (2 sec)...")
		task.spawn(function()
			task.wait(2.0)
			if not ctx.isAlive or not ctx.model.Parent then return end
			ctx.fsm:ChangeState("DeliveringFood", order, stovePart)
		end)
	end,
}

local DeliveringFoodState = {
	Name = "DeliveringFood",
	OnEnter = function(_, ctx: WorkerContext, order: any, stovePart: BasePart)
		setWorkerStatus(ctx, "🍔 Delivering to register...")
		task.spawn(function()
			local regInst = PlotService.GetInstanceByUuid(order.registerUuid)
			local regPart = getStationBasePart(regInst)

			if regPart and regPart.Parent then
				local startDist = (ctx.rootPart.Position - regPart.Position).Magnitude

				if startDist <= 6.5 then
					local regDockCF = CFrame.lookAt(
						ctx.rootPart.Position,
						Vector3.new(regPart.Position.X, ctx.rootPart.Position.Y, regPart.Position.Z)
					)
					MovementService.DockTo(ctx.rootPart, regDockCF, 0.2)
					task.wait(0.35)
					OrderService.SetOrderStatus(order.orderId, "Ready")
					setWorkerStatus(ctx, "✅ Order delivered!")
				else
					local regStandPos = getStationStandPosition(regPart, true)
					local sideOffset = regPart.CFrame.RightVector * 2.0
					local posRight = regStandPos + sideOffset
					local posLeft = regStandPos - sideOffset

					local targetDeliveryPos = if (ctx.rootPart.Position - posRight).Magnitude < (ctx.rootPart.Position - posLeft).Magnitude
						then posRight
						else posLeft

					local token = MovementService.CreateCancellationToken()
					ctx.currentMovementToken = token

					local reached = MovementService.WalkTo(
						ctx.model,
						ctx.humanoid,
						ctx.rootPart,
						targetDeliveryPos,
						16,
						token,
						regPart.Position
					)
					ctx.currentMovementToken = nil

					local finalDist = (ctx.rootPart.Position - regPart.Position).Magnitude

					if (reached or finalDist <= 6.5) and ctx.isAlive and ctx.model.Parent then
						local regDockCF = CFrame.lookAt(
							ctx.rootPart.Position,
							Vector3.new(regPart.Position.X, ctx.rootPart.Position.Y, regPart.Position.Z)
						)
						MovementService.DockTo(ctx.rootPart, regDockCF, 0.2)
						OrderService.SetOrderStatus(order.orderId, "Ready")
						setWorkerStatus(ctx, "✅ Order delivered!")
					else
						setWorkerStatus(ctx, "⚠️ Path blocked!")
						OrderService.SetOrderStatus(order.orderId, "Pending")
						task.wait(1.5)
					end
				end
			else
				OrderService.CompleteOrder(order.orderId)
			end

			if stovePart and stovePart.Parent and ctx.isAlive and ctx.model.Parent then
				local stovePos = getStationStandPosition(stovePart, true)
				local distToStove = (ctx.rootPart.Position - stovePos).Magnitude

				if distToStove > 3.0 then
					setWorkerStatus(ctx, "🍳 Returning to stove...")
					local returnToken = MovementService.CreateCancellationToken()
					ctx.currentMovementToken = returnToken
					MovementService.WalkTo(ctx.model, ctx.humanoid, ctx.rootPart, stovePos, 16, returnToken, stovePart.Position)
					ctx.currentMovementToken = nil
				end

				if ctx.rootPart and ctx.rootPart.Parent and stovePart.Parent then
					MovementService.DockTo(ctx.rootPart, getStationDockCFrame(stovePart, true), 0.25)
				end
			end

			ctx.currentOrderId = nil
			ctx.fsm:ChangeState("Working")
		end)
	end,
}

function NPCService.SpawnWorker(player: Player, role: NPCTypes.NPCRole, spawnCFrame: CFrame): Model
	local npcModel = Instance.new("Model")
	npcModel.Name = string.format("Worker_%s_%d", role, player.UserId)

	local humanoid = Instance.new("Humanoid")
	humanoid.WalkSpeed = 16
	humanoid.AutoRotate = false
	humanoid.Parent = npcModel
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)

	local plot = PlotService.GetPlot(player)
	local floorY = if plot then plot.originCFrame.Position.Y else 0

	local rootPart = Instance.new("Part")
	rootPart.Name = "HumanoidRootPart"
	rootPart.Size = Vector3.new(2, 4, 1.5)
	rootPart.CFrame = CFrame.new(spawnCFrame.Position.X, floorY + 2.0, spawnCFrame.Position.Z)
	rootPart.CanCollide = false
	rootPart.Anchored = true
	rootPart.Color = if role == "Cook" then Color3.fromRGB(255, 170, 0) else Color3.fromRGB(0, 170, 255)
	rootPart.Parent = npcModel
	npcModel.PrimaryPart = rootPart

	local bb = Instance.new("BillboardGui")
	bb.Name = "StatusGui"
	bb.Size = UDim2.new(0, 140, 0, 35)
	bb.StudsOffset = Vector3.new(0, 3.2, 0)
	bb.AlwaysOnTop = true
	bb.Parent = rootPart

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0
	label.Font = Enum.Font.GothamBold
	label.TextSize = 13
	label.Text = role .. ": Ready"
	label.Parent = bb

	local npcId = string.format("worker_%d_%s_%f", player.UserId, role, os.clock())
	npcModel:SetAttribute("NPC_ID", npcId)

	CollectionService:AddTag(npcModel, "NPC_ENTITY")
	npcModel.Parent = workspace
	CollisionService.ApplyToNPC(npcModel)

	local workerContext: WorkerContext = {
		npcId = npcId,
		model = npcModel,
		humanoid = humanoid,
		rootPart = rootPart,
		ownerUserId = player.UserId,
		role = role,
		assignedStationUuid = nil,
		currentOrderId = nil,
		currentMovementToken = nil,
		statusLabel = label,
		isAlive = true,
		fsm = nil,
	}

	local fsm = FSM.new(workerContext)
	fsm:AddState(IdleState)
	fsm:AddState(WalkingToStationState)
	fsm:AddState(WorkingState)
	fsm:AddState(CookingState)
	fsm:AddState(DeliveringFoodState)

	workerContext.fsm = fsm
	fsm:ChangeState("Idle")
	activeWorkers[npcId] = workerContext

	task.spawn(function()
		while workerContext.isAlive and npcModel.Parent and humanoid.Health > 0 do
			fsm:Update(0.35)
			task.wait(0.35)
		end
	end)

	return npcModel
end

function NPCService.GetWorkerAtStation(stationUuid: string): any
	local workerId = occupiedStationsByUuid[stationUuid]
	local ctx = if workerId then activeWorkers[workerId] else nil
	if ctx then
		return {
			state = if ctx.fsm:GetCurrentStateName() == "Working" then "Working" else "Idle",
			role = ctx.role,
		}
	end
	return nil
end

function NPCService.CleanupPlayerWorkers(ownerUserId: number)
	for npcId, worker in pairs(activeWorkers) do
		if worker.ownerUserId == ownerUserId then
			worker.isAlive = false
			if worker.currentMovementToken then
				worker.currentMovementToken:Cancel()
			end
			if worker.assignedStationUuid then
				occupiedStationsByUuid[worker.assignedStationUuid] = nil
			end
			worker.fsm:Destroy()
			if worker.model and worker.model.Parent then
				worker.model:Destroy()
			end
			activeWorkers[npcId] = nil
		end
	end
end

function NPCService.Init()
	InteractableComponent.Init()

	PlotService.ItemRemoved:Connect(function(uuid: string, itemId: string, ownerUserId: number)
		local workerId = occupiedStationsByUuid[uuid]
		occupiedStationsByUuid[uuid] = nil

		if workerId and activeWorkers[workerId] then
			local worker = activeWorkers[workerId]
			if worker.assignedStationUuid == uuid then
				worker.assignedStationUuid = nil
				if worker.currentMovementToken then
					worker.currentMovementToken:Cancel()
				end
				worker.fsm:ChangeState("Idle")
				setWorkerStatus(worker, "⚠️ Station removed!")
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		NPCService.CleanupPlayerWorkers(player.UserId)
	end)
end

return NPCService

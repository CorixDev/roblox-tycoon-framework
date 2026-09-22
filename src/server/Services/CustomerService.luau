--!strict

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")

local FSM = require(ReplicatedStorage.Shared.Util.FSM)
local InteractableComponent = require(ServerScriptService.Server.Components.InteractableComponent)
local OrderService = require(ServerScriptService.Server.Services.OrderService)
local EconomyService = require(ServerScriptService.Server.Services.EconomyService)
local NPCService = require(ServerScriptService.Server.Services.NPCService)
local PlotService = require(ServerScriptService.Server.Services.PlotService)
local MovementService = require(ServerScriptService.Server.Services.MovementService)
local CollisionService = require(ServerScriptService.Server.Services.CollisionService)

local CustomerService = {}

local CONFIG = {
	MAX_CUSTOMERS_PER_PLAYER = 2,
	QUEUE_SPACING = 3.2,
	FRONT_OFFSET_BASE_EXTRA = 2.5,

	PATIENCE_TIMEOUT = 45,
	ORDER_WAIT_TIMEOUT = 40,
	ORDER_PRICE = 75,

	SPEED_APPROACH = 14,
	SPEED_QUEUE_STEP = 10,
	SPEED_LEAVING = 14,

	DIST_TOLERANCE_FRONT = 1.5,
	DIST_TOLERANCE_QUEUE = 1.8,

	FSM_TICK_RATE = 0.4,
	SPAWN_INTERVAL = 5,
}

type CancellationToken = any

type CustomerContext = {
	userId: number,
	player: Player,
	customerNpcId: string,
	model: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	register: BasePart,
	registerUuid: string,
	spawnPos: Vector3,
	moveToken: CancellationToken?,
	isMoving: boolean,
	isAlive: boolean,
	queueWaitStartTime: number,
	lastQueueIndex: number?,
	fsm: any,
}

local activeCustomerCounts: { [number]: number } = {}
local activeCustomersById: { [string]: CustomerContext } = {}
local activeCustomersByUser: { [number]: { [string]: CustomerContext } } = {}
local registerQueuesByUuid: { [string]: { string } } = {}

local function getRegisterQueuePosition(register: BasePart, offsetDist: number): Vector3
	local floorY = register.Position.Y - (register.Size.Y / 2)
	local flatPos = register.Position + (register.CFrame.LookVector * offsetDist)
	return Vector3.new(flatPos.X, floorY + 2.0, flatPos.Z)
end

local function cancelMovement(ctx: CustomerContext)
	local token = ctx.moveToken
	if token then
		if typeof(MovementService.Cancel) == "function" then
			MovementService.Cancel(token)
		elseif typeof(token) == "table" and typeof(token.Cancel) == "function" then
			token:Cancel()
		end
	end
	ctx.moveToken = nil
	ctx.isMoving = false
end

local function walkAsync(
	ctx: CustomerContext,
	targetPos: Vector3,
	speed: number,
	lookAt: Vector3?
): boolean
	cancelMovement(ctx)

	local token = MovementService.CreateCancellationToken()
	ctx.moveToken = token
	ctx.isMoving = true

	MovementService.WalkTo(ctx.model, ctx.humanoid, ctx.rootPart, targetPos, speed, token, lookAt)

	local completed = (ctx.moveToken == token)
	if completed then
		ctx.isMoving = false
		ctx.moveToken = nil
	end
	return completed
end

local function removeFromQueue(registerUuid: string, customerNpcId: string)
	local queue = registerQueuesByUuid[registerUuid]
	if queue then
		local idx = table.find(queue, customerNpcId)
		if idx then
			table.remove(queue, idx)
		end
	end
end

local function cleanupCustomer(ctx: CustomerContext)
	if not ctx.isAlive then
		return
	end
	ctx.isAlive = false

	cancelMovement(ctx)
	removeFromQueue(ctx.registerUuid, ctx.customerNpcId)

	activeCustomersById[ctx.customerNpcId] = nil

	if activeCustomersByUser[ctx.userId] then
		activeCustomersByUser[ctx.userId][ctx.customerNpcId] = nil
	end

	if activeCustomerCounts[ctx.userId] then
		activeCustomerCounts[ctx.userId] = math.max(0, activeCustomerCounts[ctx.userId] - 1)
		if activeCustomerCounts[ctx.userId] == 0 then
			activeCustomerCounts[ctx.userId] = nil
		end
	end

	if ctx.fsm then
		pcall(function()
			ctx.fsm:Destroy()
		end)
		ctx.fsm = nil
	end

	if ctx.model and ctx.model.Parent then
		ctx.model:Destroy()
	end
end

local function spawnMoneyPopup(position: Vector3, amount: number)
	local part = Instance.new("Part")
	part.Name = "MoneyPopup"
	part.Size = Vector3.new(1, 1, 1)
	part.Position = position + Vector3.new(0, 2.5, 0)
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Parent = workspace

	local bbGui = Instance.new("BillboardGui")
	bbGui.Name = "PopupGui"
	bbGui.Size = UDim2.new(0, 100, 0, 40)
	bbGui.AlwaysOnTop = true
	bbGui.Adornee = part
	bbGui.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = string.format("+$%d", amount)
	label.TextColor3 = Color3.fromRGB(0, 230, 100)
	label.TextScaled = true
	label.Font = Enum.Font.FredokaOne
	label.Parent = bbGui

	local tweenInfo = TweenInfo.new(1.2, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out)
	TweenService:Create(part, tweenInfo, { Position = part.Position + Vector3.new(0, 3, 0) }):Play()
	TweenService:Create(label, tweenInfo, { TextTransparency = 1 }):Play()

	task.delay(1.2, function()
		part:Destroy()
	end)
end

local function findCashRegister(ownerUserId: number): (BasePart?, string?)
	local activeInteractables = InteractableComponent.GetActiveInteractables()
	if not activeInteractables then
		return nil, nil
	end

	for instance, data in pairs(activeInteractables) do
		if data.ownerUserId == ownerUserId and data.itemId == "cash_register" and instance.Parent and instance:IsA("BasePart") then
			return instance, data.uuid
		end
	end
	return nil, nil
end


local ApproachingQueueState = {
	Name = "ApproachingQueue",
	OnEnter = function(_, ctx: CustomerContext)
		task.spawn(function()
			if not ctx.isAlive or not ctx.register.Parent then
				ctx.fsm:ChangeState("Leaving")
				return
			end

			local frontOffsetBase = (ctx.register.Size.Z / 2) + CONFIG.FRONT_OFFSET_BASE_EXTRA
			local queue = registerQueuesByUuid[ctx.registerUuid]
			local queueIndex = if queue then (table.find(queue, ctx.customerNpcId) or 1) else 1
			local targetWaitPos = getRegisterQueuePosition(
				ctx.register,
				frontOffsetBase + (queueIndex - 1) * CONFIG.QUEUE_SPACING
			)

			local completed = walkAsync(ctx, targetWaitPos, CONFIG.SPEED_APPROACH, ctx.register.Position)
			if ctx.isAlive and completed then
				ctx.fsm:ChangeState("WaitingInQueue")
			end
		end)
	end,
	OnExit = function(_, ctx: CustomerContext)
		cancelMovement(ctx)
	end,
}

local WaitingInQueueState = {
	Name = "WaitingInQueue",
	OnEnter = function(_, ctx: CustomerContext)
		ctx.queueWaitStartTime = os.clock()
		ctx.isMoving = false
		ctx.lastQueueIndex = nil
	end,
	OnExit = function(_, ctx: CustomerContext)
		cancelMovement(ctx)
	end,
	OnUpdate = function(_, ctx: CustomerContext)
		if not ctx.isAlive then
			return
		end

		if not ctx.register.Parent or not ctx.player.Parent then
			ctx.fsm:ChangeState("Leaving")
			return
		end

		if (os.clock() - ctx.queueWaitStartTime) > CONFIG.PATIENCE_TIMEOUT then
			ctx.fsm:ChangeState("Leaving")
			return
		end

		local curQueue = registerQueuesByUuid[ctx.registerUuid]
		local curIdx = if curQueue then table.find(curQueue, ctx.customerNpcId) else nil
		if not curIdx then
			ctx.fsm:ChangeState("Leaving")
			return
		end

		if ctx.lastQueueIndex and ctx.lastQueueIndex ~= curIdx then
			cancelMovement(ctx)
		end
		ctx.lastQueueIndex = curIdx

		local frontOffsetBase = (ctx.register.Size.Z / 2) + CONFIG.FRONT_OFFSET_BASE_EXTRA

		if curIdx == 1 then
			local frontPos = getRegisterQueuePosition(ctx.register, frontOffsetBase)
			local distToFront = (Vector3.new(ctx.rootPart.Position.X - frontPos.X, 0, ctx.rootPart.Position.Z - frontPos.Z)).Magnitude

			if distToFront > CONFIG.DIST_TOLERANCE_FRONT then
				if not ctx.isMoving then
					task.spawn(function()
						walkAsync(ctx, frontPos, CONFIG.SPEED_QUEUE_STEP, ctx.register.Position)
					end)
				end
			else
				local worker = NPCService.GetWorkerAtStation(ctx.registerUuid)
				if worker and worker.state == "Working" then
					cancelMovement(ctx)
					ctx.fsm:ChangeState("Ordering")
				end
			end
		else
			local waitPos = getRegisterQueuePosition(ctx.register, frontOffsetBase + (curIdx - 1) * CONFIG.QUEUE_SPACING)
			local distToWait = (Vector3.new(ctx.rootPart.Position.X - waitPos.X, 0, ctx.rootPart.Position.Z - waitPos.Z)).Magnitude

			if distToWait > CONFIG.DIST_TOLERANCE_QUEUE then
				if not ctx.isMoving then
					task.spawn(function()
						walkAsync(ctx, waitPos, CONFIG.SPEED_QUEUE_STEP, ctx.register.Position)
					end)
				end
			end
		end
	end,
}

local OrderingState = {
	Name = "Ordering",
	OnEnter = function(_, ctx: CustomerContext)
		task.spawn(function()
			if not ctx.isAlive or not ctx.register.Parent or not ctx.player.Parent then
				ctx.fsm:ChangeState("Leaving")
				return
			end

			local order = OrderService.CreateOrder(ctx.userId, ctx.customerNpcId, ctx.registerUuid, CONFIG.ORDER_PRICE)
			if not order then
				ctx.fsm:ChangeState("Leaving")
				return
			end

			local isSuccess = OrderService.WaitForOrderReady(order.orderId, CONFIG.ORDER_WAIT_TIMEOUT)

			if not ctx.isAlive then
				OrderService.CompleteOrder(order.orderId)
				return
			end

			if isSuccess and ctx.player.Parent and ctx.model.Parent then
				EconomyService.AddBalance(ctx.player, order.price)
				if ctx.register.Parent then
					spawnMoneyPopup(ctx.register.Position, order.price)
				end
			end

			OrderService.CompleteOrder(order.orderId)

			if ctx.isAlive then
				ctx.fsm:ChangeState("Leaving")
			end
		end)
	end,
}

local LeavingState = {
	Name = "Leaving",
	OnEnter = function(_, ctx: CustomerContext)
		task.spawn(function()
			removeFromQueue(ctx.registerUuid, ctx.customerNpcId)

			if ctx.isAlive and ctx.model.Parent then
				walkAsync(ctx, ctx.spawnPos, CONFIG.SPEED_LEAVING, ctx.spawnPos)
			end

			cleanupCustomer(ctx)
		end)
	end,
}

local function handleCustomerLifeCycle(player: Player)
	local userId = player.UserId
	local plot = PlotService.GetPlot(player)
	if not plot then
		return
	end

	local register, registerUuid = findCashRegister(userId)
	if not register or not registerUuid then
		return
	end

	local curCount = activeCustomerCounts[userId] or 0
	if curCount >= CONFIG.MAX_CUSTOMERS_PER_PLAYER then
		return
	end

	activeCustomerCounts[userId] = curCount + 1

	local spawnSuccess, spawnErr = pcall(function()
		local floorY = plot.originCFrame.Position.Y
		local spawnPos = Vector3.new(plot.originCFrame.Position.X, floorY + 2.0, plot.originCFrame.Position.Z - 35)
		local customerNpcId = string.format("cust_%d_%f", userId, os.clock())

		registerQueuesByUuid[registerUuid] = registerQueuesByUuid[registerUuid] or {}
		table.insert(registerQueuesByUuid[registerUuid], customerNpcId)

		local customerModel = Instance.new("Model")
		customerModel.Name = "Customer_" .. userId
		customerModel:SetAttribute("NPC_ID", customerNpcId)

		local humanoid = Instance.new("Humanoid")
		humanoid.WalkSpeed = 15
		humanoid.AutoRotate = false
		humanoid.Parent = customerModel
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)

		local rootPart = Instance.new("Part")
		rootPart.Name = "HumanoidRootPart"
		rootPart.Size = Vector3.new(2, 4, 1.5)
		rootPart.CFrame = CFrame.new(spawnPos)
		rootPart.CanCollide = false
		rootPart.Anchored = true
		rootPart.Color = Color3.fromRGB(100, 255, 100)
		rootPart.Parent = customerModel
		customerModel.PrimaryPart = rootPart

		CollectionService:AddTag(customerModel, "NPC_ENTITY")
		customerModel.Parent = workspace
		CollisionService.ApplyToNPC(customerModel)

		local customerContext: CustomerContext = {
			userId = userId,
			player = player,
			customerNpcId = customerNpcId,
			model = customerModel,
			humanoid = humanoid,
			rootPart = rootPart,
			register = register,
			registerUuid = registerUuid,
			spawnPos = spawnPos,
			moveToken = nil,
			isMoving = false,
			isAlive = true,
			queueWaitStartTime = os.clock(),
			lastQueueIndex = nil,
			fsm = nil,
		}

		activeCustomersById[customerNpcId] = customerContext
		activeCustomersByUser[userId] = activeCustomersByUser[userId] or {}
		activeCustomersByUser[userId][customerNpcId] = customerContext

		local fsm = FSM.new(customerContext)
		fsm:AddState(ApproachingQueueState)
		fsm:AddState(WaitingInQueueState)
		fsm:AddState(OrderingState)
		fsm:AddState(LeavingState)

		customerContext.fsm = fsm
		fsm:ChangeState("ApproachingQueue")

		task.spawn(function()
			while customerContext.isAlive and customerModel.Parent do
				fsm:Update(CONFIG.FSM_TICK_RATE)
				task.wait(CONFIG.FSM_TICK_RATE)
			end

			if customerContext.isAlive then
				cleanupCustomer(customerContext)
			end
		end)
	end)

	if not spawnSuccess then
		warn(string.format("[CustomerService] Failed to spawn customer for user %d: %s", userId, tostring(spawnErr)))
		if activeCustomerCounts[userId] then
			activeCustomerCounts[userId] = math.max(0, activeCustomerCounts[userId] - 1)
		end
	end
end

function CustomerService.RemoveCustomerRecord(userId: number, model: Model)
	local npcId = model:GetAttribute("NPC_ID")
	if typeof(npcId) == "string" then
		local ctx = activeCustomersById[npcId]
		if ctx then
			cleanupCustomer(ctx)
			return
		end
	end

	if activeCustomerCounts[userId] then
		activeCustomerCounts[userId] = math.max(0, activeCustomerCounts[userId] - 1)
		if activeCustomerCounts[userId] == 0 then
			activeCustomerCounts[userId] = nil
		end
	end
end

function CustomerService.CleanupPlayerCustomers(ownerUserId: number)
	activeCustomerCounts[ownerUserId] = nil

	local userCustomers = activeCustomersByUser[ownerUserId]
	if userCustomers then
		local toCleanup: { CustomerContext } = {}
		for _, ctx in pairs(userCustomers) do
			table.insert(toCleanup, ctx)
		end
		for _, ctx in ipairs(toCleanup) do
			cleanupCustomer(ctx)
		end
		activeCustomersByUser[ownerUserId] = nil
	end

	OrderService.CleanupPlayer(ownerUserId)
end

function CustomerService.Init()
	PlotService.ItemRemoved:Connect(function(uuid: string, itemId: string, ownerUserId: number)
		local queue = registerQueuesByUuid[uuid]
		registerQueuesByUuid[uuid] = nil

		OrderService.CancelOrdersForRegister(uuid)

		if queue then
			for _, customerNpcId in ipairs(queue) do
				local ctx = activeCustomersById[customerNpcId]
				if ctx then
					cleanupCustomer(ctx)
				end
			end
		end
	end)

	task.spawn(function()
		while true do
			task.wait(CONFIG.SPAWN_INTERVAL)
			for _, player in ipairs(Players:GetPlayers()) do
				local cur = activeCustomerCounts[player.UserId] or 0
				if cur < CONFIG.MAX_CUSTOMERS_PER_PLAYER then
					task.spawn(handleCustomerLifeCycle, player)
				end
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		CustomerService.CleanupPlayerCustomers(player.UserId)
	end)
end

return CustomerService

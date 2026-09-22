--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local NPCTypes = require(ReplicatedStorage.Shared.Types.NPCTypes)

local OrderService = {}

local activeOrders: { [string]: NPCTypes.OrderData } = {}
local userOrdersQueue: { [number]: { string } } = {}

local registerOrdersIndex: { [string]: { string } } = {}

local waitingThreads: { [string]: thread } = {}
local timeoutTasks: { [string]: thread } = {}

local function detachOrderFromRegister(orderId: string)
	local order = activeOrders[orderId]
	if not order then return end

	local regList = registerOrdersIndex[order.registerUuid]
	if regList then
		local idx = table.find(regList, orderId)
		if idx then table.remove(regList, idx) end
		if #regList == 0 then
			registerOrdersIndex[order.registerUuid] = nil
		end
	end
end

function OrderService.CreateOrder(ownerUserId: number, customerNpcId: string, registerUuid: string, price: number): NPCTypes.OrderData
	local orderId = string.format("order_%d_%f", ownerUserId, os.clock())
	local order: NPCTypes.OrderData = {
		orderId = orderId,
		ownerUserId = ownerUserId,
		customerNpcId = customerNpcId,
		registerUuid = registerUuid,
		price = price,
		status = "Pending",
	}

	activeOrders[orderId] = order
	userOrdersQueue[ownerUserId] = userOrdersQueue[ownerUserId] or {}
	table.insert(userOrdersQueue[ownerUserId], orderId)

	registerOrdersIndex[registerUuid] = registerOrdersIndex[registerUuid] or {}
	table.insert(registerOrdersIndex[registerUuid], orderId)

	return order
end

function OrderService.GetPendingOrderForCook(ownerUserId: number): NPCTypes.OrderData?
	local queue = userOrdersQueue[ownerUserId]
	if not queue then return nil end

	for _, orderId in ipairs(queue) do
		local order = activeOrders[orderId]
		if order and order.status == "Pending" then
			return order
		end
	end
	return nil
end

function OrderService.GetOrder(orderId: string): NPCTypes.OrderData?
	return activeOrders[orderId]
end

function OrderService.SetOrderStatus(orderId: string, status: NPCTypes.OrderStatus)
	local order = activeOrders[orderId]
	if not order then return end
	order.status = status

	if status == "Ready" then
		local resumeThread = waitingThreads[orderId]
		if resumeThread then
			waitingThreads[orderId] = nil
			local timeoutTask = timeoutTasks[orderId]
			if timeoutTask then
				task.cancel(timeoutTask)
				timeoutTasks[orderId] = nil
			end
			task.spawn(resumeThread, true)
		end
	end
end

function OrderService.WaitForOrderReady(orderId: string, timeout: number): boolean
	local existingOrder = activeOrders[orderId]
	if not existingOrder then return false end
	if existingOrder.status == "Ready" then return true end

	local currentThread = coroutine.running()
	waitingThreads[orderId] = currentThread

	local timeoutTask = task.delay(timeout, function()
		if waitingThreads[orderId] == currentThread then
			waitingThreads[orderId] = nil
			timeoutTasks[orderId] = nil
			task.spawn(currentThread, false)
		end
	end)
	timeoutTasks[orderId] = timeoutTask

	return coroutine.yield()
end

function OrderService.CompleteOrder(orderId: string)
	local order = activeOrders[orderId]
	if order then
		local queue = userOrdersQueue[order.ownerUserId]
		if queue then
			local idx = table.find(queue, orderId)
			if idx then
				table.remove(queue, idx)
			end
		end
		if timeoutTasks[orderId] then
			task.cancel(timeoutTasks[orderId])
			timeoutTasks[orderId] = nil
		end
		if waitingThreads[orderId] then
			task.spawn(waitingThreads[orderId], false)
			waitingThreads[orderId] = nil
		end
		detachOrderFromRegister(orderId)
		activeOrders[orderId] = nil
	end
end

function OrderService.CancelOrdersForRegister(registerUuid: string)
	local orderIds = registerOrdersIndex[registerUuid]
	if not orderIds then return end

	local snapshot = table.clone(orderIds)

	for _, orderId in ipairs(snapshot) do
		local order = activeOrders[orderId]
		if order then
			if timeoutTasks[orderId] then
				task.cancel(timeoutTasks[orderId])
				timeoutTasks[orderId] = nil
			end
			if waitingThreads[orderId] then
				task.spawn(waitingThreads[orderId], false)
				waitingThreads[orderId] = nil
			end

			local queue = userOrdersQueue[order.ownerUserId]
			if queue then
				local idx = table.find(queue, orderId)
				if idx then table.remove(queue, idx) end
			end

			activeOrders[orderId] = nil
		end
	end

	registerOrdersIndex[registerUuid] = nil
end

function OrderService.CleanupPlayer(ownerUserId: number)
	local queue = userOrdersQueue[ownerUserId]
	if queue then
		for _, orderId in ipairs(queue) do
			if timeoutTasks[orderId] then
				task.cancel(timeoutTasks[orderId])
				timeoutTasks[orderId] = nil
			end
			if waitingThreads[orderId] then
				task.spawn(waitingThreads[orderId], false)
				waitingThreads[orderId] = nil
			end
			detachOrderFromRegister(orderId)
			activeOrders[orderId] = nil
		end
		userOrdersQueue[ownerUserId] = nil
	end
end

function OrderService.Init()
end

return OrderService

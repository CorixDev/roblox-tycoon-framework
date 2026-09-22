--!strict

export type Destroyable = {
	Destroy: (self: any) -> (),
} | RBXScriptConnection | (() -> ())

local Maid = {}
Maid.__index = Maid

export type Maid = typeof(setmetatable({} :: {
	_tasks: { [any]: Destroyable },
}, Maid))

function Maid.new(): Maid
	local self = setmetatable({
		_tasks = {},
	}, Maid)
	return self
end

function Maid.GiveTask(self: Maid, task: Destroyable): any
	local taskId = #self._tasks + 1
	self._tasks[taskId] = task
	return taskId
end

function Maid.DoCleaning(self: Maid)
	for key, task in pairs(self._tasks) do
		if typeof(task) == "RBXScriptConnection" then
			task:Disconnect()
		elseif type(task) == "function" then
			task()
		elseif typeof(task) == "table" and type((task :: any).Destroy) == "function" then
			(task :: any):Destroy()
		elseif typeof(task) == "Instance" then
			task:Destroy()
		end
		self._tasks[key] = nil
	end
end

function Maid.Destroy(self: Maid)
	self:DoCleaning()
end

return Maid

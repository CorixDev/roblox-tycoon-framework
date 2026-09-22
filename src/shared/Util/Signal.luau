--!strict

export type Connection = {
	Disconnect: (self: Connection) -> (),
	Connected: boolean,
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Fire: (self: Signal<T...>, T...) -> (),
	Wait: (self: Signal<T...>) -> T...,
	Destroy: (self: Signal<T...>) -> (),
}

type Listener = {
	fn: (...any) -> (),
	Connected: boolean,
}

local Signal = {}
Signal.__index = Signal

function Signal.new<T...>(): Signal<T...>
	local self = setmetatable({
		_listeners = {} :: { Listener },
		_firingDepth = 0,
		_modifiedDuringFire = false,
	}, Signal)
	return (self :: any)
end

function Signal.Connect<T...>(self: any, fn: (T...) -> ()): Connection
	if self._firingDepth > 0 and not self._modifiedDuringFire then
		self._listeners = table.clone(self._listeners)
		self._modifiedDuringFire = true
	end

	local listener: Listener = { fn = fn, Connected = true }
	table.insert(self._listeners, listener)

	local connection
	connection = {
		Connected = true,
		Disconnect = function(_)
			if not listener.Connected then return end
			listener.Connected = false
			connection.Connected = false

			if self._firingDepth > 0 and not self._modifiedDuringFire then
				self._listeners = table.clone(self._listeners)
				self._modifiedDuringFire = true
			end

			local idx = table.find(self._listeners, listener)
			if idx then
				table.remove(self._listeners, idx)
			end
		end,
	}
	return connection
end

function Signal.Once<T...>(self: any, fn: (T...) -> ()): Connection
	local connection: Connection? = nil
	connection = self:Connect(function(...)
		if connection then connection:Disconnect() end
		fn(...)
	end)
	return connection :: Connection
end

function Signal.Fire<T...>(self: any, ...: T...)
	self._firingDepth += 1
	local listeners = self._listeners
	local count = #listeners

	for i = 1, count do
		local listener = listeners[i]
		if listener and listener.Connected then
			task.spawn(listener.fn, ...)
		end
	end

	self._firingDepth -= 1
	if self._firingDepth == 0 then
		self._modifiedDuringFire = false
	end
end

function Signal.Wait<T...>(self: any): T...
	local thread = coroutine.running()
	self:Once(function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal.Destroy(self: any)
	for _, listener in ipairs(self._listeners) do
		listener.Connected = false
	end
	table.clear(self._listeners)
end

return Signal

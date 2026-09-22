--!strict

export type State<T> = {
	Name: string,
	OnEnter: (self: State<T>, ctx: T, ...any) -> (),
	OnUpdate: ((self: State<T>, ctx: T, dt: number) -> ())?,
	OnExit: ((self: State<T>, ctx: T) -> ())?,
}

export type FSM<T> = {
	Context: T,
	CurrentState: State<T>?,
	AddState: (self: FSM<T>, state: State<T>) -> (),
	ChangeState: (self: FSM<T>, stateName: string, ...any) -> (),
	Update: (self: FSM<T>, dt: number) -> (),
	GetCurrentStateName: (self: FSM<T>) -> string?,
	Destroy: (self: FSM<T>) -> (),
}

local FSMImpl = {}
FSMImpl.__index = FSMImpl

function FSMImpl.new<T>(context: T): FSM<T>
	local self = setmetatable({
		Context = context,
		CurrentState = nil :: State<T>?,
		_states = {} :: { [string]: State<T> },
		_isDestroyed = false,
	}, FSMImpl)
	return (self :: any)
end

function FSMImpl.AddState<T>(self: any, state: State<T>)
	self._states[state.Name] = state
end

function FSMImpl.ChangeState<T>(self: any, stateName: string, ...: any)
	if self._isDestroyed then return end

	local nextState = self._states[stateName]
	if not nextState then
		warn(string.format("[FSM] State '%s' not registered!", stateName))
		return
	end

	if self.CurrentState and self.CurrentState.OnExit then
		self.CurrentState:OnExit(self.Context)
	end

	self.CurrentState = nextState
	nextState:OnEnter(self.Context, ...)
end

function FSMImpl.Update<T>(self: any, dt: number)
	if self._isDestroyed or not self.CurrentState then return end
	if self.CurrentState.OnUpdate then
		self.CurrentState:OnUpdate(self.Context, dt)
	end
end

function FSMImpl.GetCurrentStateName<T>(self: any): string?
	return if self.CurrentState then self.CurrentState.Name else nil
end

function FSMImpl.Destroy<T>(self: any)
	if self._isDestroyed then return end
	self._isDestroyed = true
	if self.CurrentState and self.CurrentState.OnExit then
		self.CurrentState:OnExit(self.Context)
	end
	table.clear(self._states)
	self.CurrentState = nil
end

return FSMImpl

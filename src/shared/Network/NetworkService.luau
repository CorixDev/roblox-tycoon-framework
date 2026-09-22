--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local NetworkService = {}

export type RemoteEventName = 
	| "RequestPlacement" 
| "RequestRemoval" 
| "PlotStateUpdated" 
| "BalanceUpdated" 
| "PlacementResult"
| "NpcPathReplication"
| "NpcStopReplication"

export type RemoteFunctionName = "GetPlotData"

local REMOTE_EVENTS: { RemoteEventName } = {
	"RequestPlacement",
	"RequestRemoval",
	"PlotStateUpdated",
	"BalanceUpdated",
	"PlacementResult",
	"NpcPathReplication",
	"NpcStopReplication",
}

local REMOTE_FUNCTIONS: { RemoteFunctionName } = {
	"GetPlotData",
}

local eventsFolder: Folder? = nil
local functionsFolder: Folder? = nil

local function getEventsFolder(): Folder
	if eventsFolder then
		return eventsFolder
	end

	if RunService:IsServer() then
		local folder = ReplicatedStorage:FindFirstChild("Events")
		if not folder or not folder:IsA("Folder") then
			folder = Instance.new("Folder")
			folder.Name = "Events"
			folder.Parent = ReplicatedStorage
		end
		eventsFolder = folder :: Folder
	else
		eventsFolder = ReplicatedStorage:WaitForChild("Events") :: Folder
	end

	return eventsFolder :: Folder
end

local function getFunctionsFolder(): Folder
	if functionsFolder then
		return functionsFolder
	end

	if RunService:IsServer() then
		local folder = ReplicatedStorage:FindFirstChild("Functions")
		if not folder or not folder:IsA("Folder") then
			folder = Instance.new("Folder")
			folder.Name = "Functions"
			folder.Parent = ReplicatedStorage
		end
		functionsFolder = folder :: Folder
	else
		functionsFolder = ReplicatedStorage:WaitForChild("Functions") :: Folder
	end

	return functionsFolder :: Folder
end

function NetworkService.Init()
	if RunService:IsServer() then
		local evFolder = getEventsFolder()
		local fnFolder = getFunctionsFolder()

		for _, eventName in ipairs(REMOTE_EVENTS) do
			if not evFolder:FindFirstChild(eventName) then
				local event = Instance.new("RemoteEvent")
				event.Name = eventName
				event.Parent = evFolder
			end
		end

		for _, funcName in ipairs(REMOTE_FUNCTIONS) do
			if not fnFolder:FindFirstChild(funcName) then
				local func = Instance.new("RemoteFunction")
				func.Name = funcName
				func.Parent = fnFolder
			end
		end
	else
		getEventsFolder()
		getFunctionsFolder()
	end
end

function NetworkService.GetEvent(name: RemoteEventName): RemoteEvent
	local folder = getEventsFolder()
	if RunService:IsServer() then
		local ev = folder:FindFirstChild(name)
		if not ev or not ev:IsA("RemoteEvent") then
			local newEv = Instance.new("RemoteEvent")
			newEv.Name = name
			newEv.Parent = folder
			return newEv
		end
		return ev :: RemoteEvent
	else
		local ev = folder:WaitForChild(name)
		return ev :: RemoteEvent
	end
end

function NetworkService.GetFunction(name: RemoteFunctionName): RemoteFunction
	local folder = getFunctionsFolder()
	if RunService:IsServer() then
		local fn = folder:FindFirstChild(name)
		if not fn or not fn:IsA("RemoteFunction") then
			local newFn = Instance.new("RemoteFunction")
			newFn.Name = name
			newFn.Parent = folder
			return newFn
		end
		return fn :: RemoteFunction
	else
		local fn = folder:WaitForChild(name)
		return fn :: RemoteFunction
	end
end

return NetworkService

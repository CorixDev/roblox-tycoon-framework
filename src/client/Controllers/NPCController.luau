--!strict

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local NetworkService = require(ReplicatedStorage.Network.NetworkService)
local SplineUtil = require(ReplicatedStorage.Shared.Util.SplineUtil)
local PathBufferUtil = require(ReplicatedStorage.Shared.Util.PathBufferUtil)

local NPCController = {}

type ClientTrajectory = {
	model: Model,
	trajectory: SplineUtil.PrecomputedTrajectory,
	startTime: number,
	speed: number,
	finalLookTarget: Vector3?,
}

local activeTrajectories: { [string]: ClientTrajectory } = {}
local npcModelRegistry: { [string]: Model } = {}

local function registerNPC(model: Model)
	local npcId = model:GetAttribute("NPC_ID") or model.Name
	npcModelRegistry[npcId] = model

	model.Destroying:Connect(function()
		npcModelRegistry[npcId] = nil
		activeTrajectories[npcId] = nil
	end)
end

function NPCController.Init()
	for _, inst in ipairs(CollectionService:GetTagged("NPC_ENTITY")) do
		if inst:IsA("Model") then registerNPC(inst) end
	end

	CollectionService:GetInstanceAddedSignal("NPC_ENTITY"):Connect(function(inst)
		if inst:IsA("Model") then registerNPC(inst) end
	end)

	CollectionService:GetInstanceRemovedSignal("NPC_ENTITY"):Connect(function(inst)
		if inst:IsA("Model") then
			local id = inst:GetAttribute("NPC_ID") or inst.Name
			npcModelRegistry[id] = nil
			activeTrajectories[id] = nil
		end
	end)

	local pathEvent = NetworkService.GetEvent("NpcPathReplication")
	local stopEvent = NetworkService.GetEvent("NpcStopReplication")

	pathEvent.OnClientEvent:Connect(function(payload: any)
		local npcId: string
		local rawPoints: { Vector3 }
		local startTime: number
		local speed: number
		local totalLength: number
		local finalLookTarget: Vector3?

		if typeof(payload) == "buffer" then
			npcId, rawPoints, startTime, speed, totalLength, finalLookTarget = PathBufferUtil.Deserialize(payload)
		else
			return
		end

		local model = npcModelRegistry[npcId]
		if not model then
			task.delay(0.1, function()
				local retryModel = npcModelRegistry[npcId]
				if retryModel then
					activeTrajectories[npcId] = {
						model = retryModel,
						trajectory = SplineUtil.PrecomputeTrajectory(rawPoints),
						startTime = startTime,
						speed = speed,
						finalLookTarget = finalLookTarget,
					}
				end
			end)
			return
		end

		activeTrajectories[npcId] = {
			model = model,
			trajectory = SplineUtil.PrecomputeTrajectory(rawPoints),
			startTime = startTime,
			speed = speed,
			finalLookTarget = finalLookTarget,
		}
	end)

	stopEvent.OnClientEvent:Connect(function(npcId: string)
		activeTrajectories[npcId] = nil
	end)

	RunService.RenderStepped:Connect(function()
		local now = workspace:GetServerTimeNow()

		for npcId, data in pairs(activeTrajectories) do
			if not data.model.Parent then
				activeTrajectories[npcId] = nil
				continue
			end

			local elapsed = math.max(0, now - data.startTime)
			local dist = elapsed * data.speed
			local traj = data.trajectory

			if dist >= traj.totalLength then
				local finalPos = traj.points[#traj.points]
				local flatLook: Vector3

				if data.finalLookTarget then
					local diff = Vector3.new(data.finalLookTarget.X - finalPos.X, 0, data.finalLookTarget.Z - finalPos.Z)
					flatLook = if diff.Magnitude > 0.05 then diff.Unit else Vector3.new(0, 0, 1)
				else
					local prevPos = traj.points[math.max(1, #traj.points - 1)]
					local look = (Vector3.new(finalPos.X, 0, finalPos.Z) - Vector3.new(prevPos.X, 0, prevPos.Z))
					flatLook = if look.Magnitude > 0.001 then look.Unit else Vector3.new(0, 0, 1)
				end

				data.model:PivotTo(CFrame.lookAt(finalPos, finalPos + flatLook))
				activeTrajectories[npcId] = nil
			else
				local currentPos, lookDir = SplineUtil.SamplePathPrecomputed(traj, dist, data.finalLookTarget)
				data.model:PivotTo(CFrame.lookAt(currentPos, currentPos + lookDir))
			end
		end
	end)
end

return NPCController

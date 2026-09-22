--!strict
--!native

local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local NetworkService = require(ReplicatedStorage.Network.NetworkService)
local SplineUtil = require(ReplicatedStorage.Shared.Util.SplineUtil)
local PathBufferUtil = require(ReplicatedStorage.Shared.Util.PathBufferUtil)
local NPCTypes = require(ReplicatedStorage.Shared.Types.NPCTypes)

local MovementService = {}

local PATH_CONFIG = {
	AgentRadius = 1.0,
	AgentHeight = 4.5,
	AgentCanJump = false,
	WaypointSpacing = 2.5,
	Costs = {
		Water = math.huge,
	},
}

local MAX_CONCURRENT_COMPUTES = 6
local COMPUTE_TIMEOUT_SECONDS = 0.5
local DIRECT_SHORT_CIRCUIT_DISTANCE = 25.0

local activeComputeCount = 0
local computeQueue: { thread } = {}

local safeRayParams = RaycastParams.new()
safeRayParams.FilterType = Enum.RaycastFilterType.Exclude

local pathPool: { Path } = {}
local POOL_MAX_SIZE = 30

local function acquireComputeSlot(): boolean
	if activeComputeCount < MAX_CONCURRENT_COMPUTES then
		activeComputeCount += 1
		return true
	end

	local curThread = coroutine.running()
	table.insert(computeQueue, curThread)

	local timedOut = false
	local timeoutThread = task.delay(COMPUTE_TIMEOUT_SECONDS, function()
		timedOut = true
		local idx = table.find(computeQueue, curThread)
		if idx then
			table.remove(computeQueue, idx)
		end
		if coroutine.status(curThread) == "suspended" then
			task.spawn(curThread)
		end
	end)

	coroutine.yield()

	if timedOut then
		return false
	end

	task.cancel(timeoutThread)
	return true
end

local function releaseComputeSlot()
	activeComputeCount = math.max(0, activeComputeCount - 1)
	if #computeQueue > 0 then
		local nextThread = table.remove(computeQueue, 1)
		activeComputeCount += 1
		if coroutine.status(nextThread) == "suspended" then
			task.spawn(nextThread)
		end
	end
end

local function acquirePath(): Path
	local path = table.remove(pathPool)
	if path then
		return path
	end
	return PathfindingService:CreatePath(PATH_CONFIG)
end

local function releasePath(path: Path)
	if #pathPool < POOL_MAX_SIZE then
		table.insert(pathPool, path)
	end
end

function MovementService.CreateCancellationToken(): NPCTypes.CancellationToken
	local isCancelled = false
	return {
		IsCancelled = function(_)
			return isCancelled
		end,
		Cancel = function(_)
			isCancelled = true
		end,
	}
end

local function filterCollinearWaypoints(rawPoints: { Vector3 }): { Vector3 }
	local total = #rawPoints
	if total <= 2 then return rawPoints end

	local filtered: { Vector3 } = { rawPoints[1] }
	for i = 2, total - 1 do
		local prev = filtered[#filtered]
		local cur = rawPoints[i]
		local nextP = rawPoints[i + 1]

		local vPrev = Vector3.new(cur.X - prev.X, 0, cur.Z - prev.Z)
		local vNext = Vector3.new(nextP.X - cur.X, 0, nextP.Z - cur.Z)

		if vPrev.Magnitude > 0.05 and vNext.Magnitude > 0.05 then
			if vPrev.Unit:Dot(vNext.Unit) < 0.995 then
				table.insert(filtered, cur)
			end
		end
	end

	table.insert(filtered, rawPoints[total])
	return filtered
end

local function isDirectPathClear(startPos: Vector3, targetPos: Vector3, ignoreModel: Model?): boolean
	local filterList: { Instance } = {}
	local placedFolder = workspace:FindFirstChild("PlacedObjects")
	if placedFolder then
		table.insert(filterList, placedFolder)
	end
	if ignoreModel then
		table.insert(filterList, ignoreModel)
	end

	safeRayParams.FilterType = Enum.RaycastFilterType.Exclude
	safeRayParams.FilterDescendantsInstances = filterList
	safeRayParams.CollisionGroup = "NPCs"

	local origin = startPos + Vector3.new(0, 1.0, 0)
	local target = targetPos + Vector3.new(0, 1.0, 0)
	local dir = target - origin

	local dist = dir.Magnitude
	if dist <= 2.5 then return true end
	local castDir = dir.Unit * (dist - 1.5)

	local hit = workspace:Spherecast(origin, 0.8, castDir, safeRayParams)
	if hit and hit.Instance and hit.Instance.CanCollide and hit.Normal.Y < 0.7 then
		return false
	end
	return true
end

function MovementService.SmoothRotate(rootPart: BasePart, lookTarget: Vector3, duration: number?)
	if not rootPart or not rootPart.Parent then return end
	local time = duration or 0.2
	local flatTarget = Vector3.new(lookTarget.X, rootPart.Position.Y, lookTarget.Z)
	local targetCF = CFrame.lookAt(rootPart.Position, flatTarget)
	local tween = TweenService:Create(rootPart, TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = targetCF })
	tween:Play()
	tween.Completed:Wait()
end

function MovementService.DockTo(rootPart: BasePart, targetCFrame: CFrame, duration: number?)
	if not rootPart or not rootPart.Parent then return end
	local time = duration or 0.2
	local tween = TweenService:Create(rootPart, TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = targetCFrame })
	tween:Play()
	tween.Completed:Wait()
	rootPart.Anchored = true
end

function MovementService.WalkTo(
	model: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	targetPos: Vector3,
	speedOverride: number?,
	token: NPCTypes.CancellationToken?,
	finalLookTarget: Vector3?
): boolean
	if not rootPart.Parent or not model.Parent then return false end

	local speed = speedOverride or humanoid.WalkSpeed
	local startPos = rootPart.Position
	local flatDist = (Vector3.new(targetPos.X - startPos.X, 0, targetPos.Z - startPos.Z)).Magnitude

	if flatDist < 0.5 then
		if finalLookTarget then
			MovementService.SmoothRotate(rootPart, finalLookTarget, 0.2)
		end
		return true
	end

	local visualHeight = targetPos.Y
	local floorY = visualHeight - 2.0
	local exactTargetVec = Vector3.new(targetPos.X, visualHeight, targetPos.Z)
	local directStart = Vector3.new(startPos.X, visualHeight, startPos.Z)
	local smoothPoints: { Vector3 }? = nil

	if flatDist <= DIRECT_SHORT_CIRCUIT_DISTANCE and isDirectPathClear(startPos, targetPos, model) then
		smoothPoints = { directStart, exactTargetVec }
	else
		local slotGranted = acquireComputeSlot()
		if slotGranted then
			local path = acquirePath()
			local ok = pcall(function()
				path:ComputeAsync(
					Vector3.new(startPos.X, floorY, startPos.Z),
					Vector3.new(targetPos.X, floorY, targetPos.Z)
				)
			end)

			local isSuccess = ok and path.Status == Enum.PathStatus.Success
			local waypoints = if isSuccess then path:GetWaypoints() else nil
			releasePath(path)
			releaseComputeSlot()

			if isSuccess and waypoints and #waypoints > 0 then
				local rawPoints: { Vector3 } = table.create(#waypoints + 2)
				rawPoints[1] = directStart

				for i, wp in ipairs(waypoints) do
					rawPoints[i + 1] = Vector3.new(wp.Position.X, visualHeight, wp.Position.Z)
				end

				local lastWp = rawPoints[#rawPoints]
				if (lastWp - exactTargetVec).Magnitude > 0.2 then
					table.insert(rawPoints, exactTargetVec)
				else
					rawPoints[#rawPoints] = exactTargetVec
				end

				smoothPoints = SplineUtil.ChaikinSmooth(filterCollinearWaypoints(rawPoints), 2)
			end
		end

		if not smoothPoints then
			if flatDist <= 120.0 and isDirectPathClear(startPos, targetPos, model) then
				smoothPoints = { directStart, exactTargetVec }
			else
				return false
			end
		end
	end

	local precomputed = SplineUtil.PrecomputeTrajectory(smoothPoints :: { Vector3 })
	if precomputed.totalLength < 0.1 then return true end

	local totalTime = precomputed.totalLength / speed
	local startTime = workspace:GetServerTimeNow()
	local npcId = model:GetAttribute("NPC_ID") or model.Name

	local pathBuffer = PathBufferUtil.Serialize(
		npcId,
		smoothPoints :: { Vector3 },
		startTime,
		speed,
		precomputed.totalLength,
		finalLookTarget
	)

	local pathEvent = NetworkService.GetEvent("NpcPathReplication")
	if pathEvent then
		pathEvent:FireAllClients(pathBuffer)
	end

	local elapsedWait = 0
	while elapsedWait < totalTime do
		if token and token:IsCancelled() then
			local stopEvent = NetworkService.GetEvent("NpcStopReplication")
			if stopEvent then stopEvent:FireAllClients(npcId) end
			return false
		end
		if not model.Parent or not rootPart.Parent then return false end

		local step = task.wait(0.2)
		elapsedWait += step
	end

	if model.Parent and rootPart.Parent and not (token and token:IsCancelled()) then
		local pts = smoothPoints :: { Vector3 }
		local finalPos = pts[#pts]
		local flatLook: Vector3
		if finalLookTarget then
			local diff = Vector3.new(finalLookTarget.X - finalPos.X, 0, finalLookTarget.Z - finalPos.Z)
			flatLook = if diff.Magnitude > 0.05 then diff.Unit else rootPart.CFrame.LookVector
		else
			local prevPos = pts[math.max(1, #pts - 1)]
			local delta = Vector3.new(finalPos.X - prevPos.X, 0, finalPos.Z - prevPos.Z)
			flatLook = if delta.Magnitude > 0.05 then delta.Unit else rootPart.CFrame.LookVector
		end
		rootPart.CFrame = CFrame.lookAt(finalPos, finalPos + flatLook)
		return true
	end

	return false
end

return MovementService

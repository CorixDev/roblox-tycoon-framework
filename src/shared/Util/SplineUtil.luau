--!strict

local SplineUtil = {}

export type PrecomputedTrajectory = {
	points: { Vector3 },
	cumDistances: { number },
	totalLength: number,
}

function SplineUtil.ChaikinSmooth(points: { Vector3 }, iterations: number): { Vector3 }
	if #points <= 2 then
		return points
	end

	local current = points
	for _ = 1, iterations do
		local nextPts: { Vector3 } = { current[1] }

		for i = 1, #current - 1 do
			local p0 = current[i]
			local p1 = current[i + 1]

			local q = p0 * 0.75 + p1 * 0.25
			local r = p0 * 0.25 + p1 * 0.75

			table.insert(nextPts, q)
			table.insert(nextPts, r)
		end

		table.insert(nextPts, current[#current])
		current = nextPts
	end

	return current
end

function SplineUtil.PrecomputeTrajectory(points: { Vector3 }): PrecomputedTrajectory
	local count = #points
	local cumDistances: { number } = table.create(count, 0)
	local total = 0

	for i = 2, count do
		local segLen = (points[i] - points[i - 1]).Magnitude
		total += segLen
		cumDistances[i] = total
	end

	return {
		points = points,
		cumDistances = cumDistances,
		totalLength = total,
	}
end

local function findSegmentIndex(cumDistances: { number }, distance: number): number
	local low = 1
	local high = #cumDistances - 1

	while low <= high do
		local mid = math.floor((low + high) / 2)
		if distance < cumDistances[mid] then
			high = mid - 1
		elseif distance > cumDistances[mid + 1] then
			low = mid + 1
		else
			return mid
		end
	end

	return math.clamp(low, 1, #cumDistances - 1)
end

function SplineUtil.GetPositionAtDistancePrecomputed(traj: PrecomputedTrajectory, distance: number): Vector3
	local pts = traj.points
	local count = #pts
	if count == 0 then return Vector3.zero end
	if distance <= 0 or count == 1 then return pts[1] end
	if distance >= traj.totalLength then return pts[count] end

	local idx = findSegmentIndex(traj.cumDistances, distance)
	local segStartDist = traj.cumDistances[idx]
	local segEndDist = traj.cumDistances[idx + 1]
	local segLen = segEndDist - segStartDist

	local t = if segLen > 0.0001 then (distance - segStartDist) / segLen else 0
	return pts[idx]:Lerp(pts[idx + 1], t)
end

function SplineUtil.SamplePathPrecomputed(
	traj: PrecomputedTrajectory,
	distance: number,
	finalLookTarget: Vector3?
): (Vector3, Vector3)
	local pts = traj.points
	local count = #pts
	if count <= 1 then
		local p = if count == 1 then pts[1] else Vector3.zero
		local look = if finalLookTarget then (Vector3.new(finalLookTarget.X - p.X, 0, finalLookTarget.Z - p.Z)).Unit else Vector3.new(0, 0, 1)
		return p, look
	end

	local curPos = SplineUtil.GetPositionAtDistancePrecomputed(traj, distance)
	local lookAheadDist = math.min(traj.totalLength, distance + 1.5)
	local aheadPos = SplineUtil.GetPositionAtDistancePrecomputed(traj, lookAheadDist)
	local lookDir = aheadPos - curPos

	if lookDir.Magnitude < 0.001 then
		lookDir = pts[count] - pts[math.max(1, count - 1)]
	end

	local flatLook = Vector3.new(lookDir.X, 0, lookDir.Z)
	local safeLook = if flatLook.Magnitude > 0.001 then flatLook.Unit else Vector3.new(0, 0, 1)

	if finalLookTarget then
		local remainDist = traj.totalLength - distance
		local blendThreshold = 4.0
		if remainDist < blendThreshold then
			local t = math.clamp((blendThreshold - remainDist) / blendThreshold, 0, 1)
			local smoothT = t * t * (3 - 2 * t)

			local targetDir = Vector3.new(finalLookTarget.X - curPos.X, 0, finalLookTarget.Z - curPos.Z)
			if targetDir.Magnitude > 0.05 then
				safeLook = safeLook:Lerp(targetDir.Unit, smoothT).Unit
			end
		end
	end

	return curPos, safeLook
end

return SplineUtil

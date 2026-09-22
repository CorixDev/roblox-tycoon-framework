--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlotTypes = require(ReplicatedStorage.Shared.Types.PlotTypes)

local MathUtil = {}

function MathUtil.IsFiniteNumber(num: number): boolean
	return num == num and num ~= math.huge and num ~= -math.huge
end

function MathUtil.IsSafeVector3(vec: Vector3): boolean
	return MathUtil.IsFiniteNumber(vec.X)
		and MathUtil.IsFiniteNumber(vec.Y)
		and MathUtil.IsFiniteNumber(vec.Z)
end

function MathUtil.IsSafeCFrame(cf: CFrame): boolean
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	return MathUtil.IsFiniteNumber(x) and MathUtil.IsFiniteNumber(y) and MathUtil.IsFiniteNumber(z)
		and MathUtil.IsFiniteNumber(r00) and MathUtil.IsFiniteNumber(r01) and MathUtil.IsFiniteNumber(r02)
		and MathUtil.IsFiniteNumber(r10) and MathUtil.IsFiniteNumber(r11) and MathUtil.IsFiniteNumber(r12)
		and MathUtil.IsFiniteNumber(r20) and MathUtil.IsFiniteNumber(r21) and MathUtil.IsFiniteNumber(r22)
end

function MathUtil.IsPointInsidePlot(point: Vector3, plotOrigin: CFrame, plotSize: Vector2): boolean
	local localPoint = plotOrigin:PointToObjectSpace(point)
	local halfX = plotSize.X / 2
	local halfZ = plotSize.Y / 2
	return math.abs(localPoint.X) <= halfX and math.abs(localPoint.Z) <= halfZ
end

function MathUtil.AreCornersInsidePlot(itemCF: CFrame, itemSize: Vector3, plotOrigin: CFrame, plotSize: Vector2): boolean
	if not MathUtil.IsSafeCFrame(itemCF) or not MathUtil.IsSafeVector3(itemSize) then
		return false
	end

	local halfX = itemSize.X / 2
	local halfZ = itemSize.Z / 2

	local corners = {
		itemCF * Vector3.new(halfX, 0, halfZ),
		itemCF * Vector3.new(-halfX, 0, halfZ),
		itemCF * Vector3.new(halfX, 0, -halfZ),
		itemCF * Vector3.new(-halfX, 0, -halfZ),
	}

	for _, corner in corners do
		if not MathUtil.IsPointInsidePlot(corner, plotOrigin, plotSize) then
			return false
		end
	end

	return true
end

function MathUtil.CFrameToTransform(cf: CFrame): PlotTypes.SerializedTransform
	local rx, ry, rz = cf:ToOrientation()
	return {
		x = cf.Position.X,
		y = cf.Position.Y,
		z = cf.Position.Z,
		rx = rx,
		ry = ry,
		rz = rz,
	}
end

function MathUtil.TransformToCFrame(t: PlotTypes.SerializedTransform): CFrame
	return CFrame.new(t.x, t.y, t.z) * CFrame.fromOrientation(t.rx, t.ry, t.rz)
end

return MathUtil

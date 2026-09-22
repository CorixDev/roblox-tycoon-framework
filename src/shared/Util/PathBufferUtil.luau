--!strict

local PathBufferUtil = {}

function PathBufferUtil.Serialize(
	npcId: string,
	points: { Vector3 },
	startTime: number,
	speed: number,
	totalLength: number,
	finalLookTarget: Vector3?
): buffer
	local numPoints = #points
	local idLen = #npcId
	local headerSize = 32 + idLen
	local totalSize = headerSize + (numPoints * 12)

	local b = buffer.create(totalSize)
	buffer.writeu16(b, 0, numPoints)
	buffer.writef64(b, 2, startTime)
	buffer.writef32(b, 10, speed)
	buffer.writef32(b, 14, totalLength)

	if finalLookTarget then
		buffer.writeu8(b, 18, 1)
		buffer.writef32(b, 19, finalLookTarget.X)
		buffer.writef32(b, 23, finalLookTarget.Y)
		buffer.writef32(b, 27, finalLookTarget.Z)
	else
		buffer.writeu8(b, 18, 0)
	end

	buffer.writeu8(b, 31, idLen)
	buffer.writestring(b, 32, npcId, idLen)

	local offset = headerSize
	for _, pt in ipairs(points) do
		buffer.writef32(b, offset, pt.X)
		buffer.writef32(b, offset + 4, pt.Y)
		buffer.writef32(b, offset + 8, pt.Z)
		offset += 12
	end

	return b
end

function PathBufferUtil.Deserialize(b: buffer): (string, { Vector3 }, number, number, number, Vector3?)
	local numPoints = buffer.readu16(b, 0)
	local startTime = buffer.readf64(b, 2)
	local speed = buffer.readf32(b, 10)
	local totalLength = buffer.readf32(b, 14)

	local hasLook = buffer.readu8(b, 18) == 1
	local finalLook: Vector3? = nil
	if hasLook then
		finalLook = Vector3.new(
			buffer.readf32(b, 19),
			buffer.readf32(b, 23),
			buffer.readf32(b, 27)
		)
	end

	local idLen = buffer.readu8(b, 31)
	local npcId = buffer.readstring(b, 32, idLen)
	local offset = 32 + idLen

	local points: { Vector3 } = table.create(numPoints)
	for i = 1, numPoints do
		points[i] = Vector3.new(
			buffer.readf32(b, offset),
			buffer.readf32(b, offset + 4),
			buffer.readf32(b, offset + 8)
		)
		offset += 12
	end

	return npcId, points, startTime, speed, totalLength, finalLook
end

return PathBufferUtil

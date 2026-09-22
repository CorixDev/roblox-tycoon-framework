--!strict

export type ItemCategory = "Structure" | "Furniture" | "Decoration" | "Spawner" | "Processor"

export type SerializedTransform = {
	x: number,
	y: number,
	z: number,
	rx: number,
	ry: number,
	rz: number,
}

export type SerializedItem = {
	uuid: string,
	itemId: string,
	transform: SerializedTransform,
}

export type PlotGridData = {
	[string]: SerializedItem,
}

export type ItemConfig = {
	itemId: string,
	name: string,
	category: ItemCategory,
	size: Vector3,
	price: number,
	modelAssetId: number?,
}

export type PlotState = {
	plotId: number,
	ownerUserId: number?,
	originCFrame: CFrame,
	size: Vector2,
	placedItems: PlotGridData,
}

return nil

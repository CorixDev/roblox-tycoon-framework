--!strict

export type NPCRole = "Cook" | "Cashier" | "Customer"
export type WorkerState = "Idle" | "WalkingToWorkstation" | "Working" | "CarryingFood"
export type CustomerState = "Spawning" | "WalkingToRegister" | "WaitingInLine" | "Ordering" | "WaitingForFood" | "Leaving"

export type OrderStatus = "Pending" | "Cooking" | "Ready" | "Completed"

export type OrderData = {
	orderId: string,
	ownerUserId: number,
	customerNpcId: string,
	registerUuid: string,
	price: number,
	status: OrderStatus,
}

export type CancellationToken = {
	IsCancelled: (self: CancellationToken) -> boolean,
	Cancel: (self: CancellationToken) -> (),
}

export type WorkerData = {
	npcId: string,
	model: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	ownerUserId: number,
	role: NPCRole,
	state: WorkerState,
	assignedStationUuid: string?,
	currentOrderId: string?,
	currentMovementToken: CancellationToken?,
}

return nil

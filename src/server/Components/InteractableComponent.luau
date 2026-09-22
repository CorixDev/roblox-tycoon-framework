--!strict

local InteractableComponent = {}

export type InteractableData = {
	itemId: string,
	ownerUserId: number,
	instance: Instance,
	uuid: string,
}

local activeInteractables: { [Instance]: InteractableData } = {}
local uuidToInteractable: { [string]: InteractableData } = {}

function InteractableComponent.Register(instance: Instance, itemId: string, ownerUserId: number, uuid: string)
	local data: InteractableData = {
		itemId = itemId,
		ownerUserId = ownerUserId,
		instance = instance,
		uuid = uuid,
	}
	activeInteractables[instance] = data
	uuidToInteractable[uuid] = data

	instance.Destroying:Connect(function()
		activeInteractables[instance] = nil
		uuidToInteractable[uuid] = nil
	end)
end

function InteractableComponent.Unregister(instance: Instance)
	local data = activeInteractables[instance]
	if data then
		uuidToInteractable[data.uuid] = nil
		activeInteractables[instance] = nil
	end
end

function InteractableComponent.Get(instance: Instance): InteractableData?
	return activeInteractables[instance]
end

function InteractableComponent.GetByUuid(uuid: string): InteractableData?
	return uuidToInteractable[uuid]
end

function InteractableComponent.GetActiveInteractables(): { [Instance]: InteractableData }
	return activeInteractables
end

function InteractableComponent.ClearPlayer(ownerUserId: number)
	for instance, data in pairs(activeInteractables) do
		if data.ownerUserId == ownerUserId then
			uuidToInteractable[data.uuid] = nil
			activeInteractables[instance] = nil
		end
	end
end

function InteractableComponent.Init()
end

return InteractableComponent

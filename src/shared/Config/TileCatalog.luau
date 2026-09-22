--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlotTypes = require(ReplicatedStorage.Shared.Types.PlotTypes)

local TileCatalog = {}

local ITEMS: { [string]: PlotTypes.ItemConfig } = {
	["wooden_chair"] = {
		itemId = "wooden_chair",
		name = "Wooden Chair",
		category = "Furniture",
		size = Vector3.new(2, 3, 2),
		price = 50,
	},
	["wooden_table"] = {
		itemId = "wooden_table",
		name = "Wooden Table",
		category = "Furniture",
		size = Vector3.new(4, 3, 4),
		price = 120,
	},
	["stove"] = {
		itemId = "stove",
		name = "Kitchen Stove",
		category = "Processor",
		size = Vector3.new(4, 4, 3),
		price = 250,
	},
	["cash_register"] = {
		itemId = "cash_register",
		name = "Cash Register",
		category = "Structure",
		size = Vector3.new(3, 3, 3),
		price = 150,
	},
}

function TileCatalog.GetItemConfig(itemId: string): PlotTypes.ItemConfig?
	return ITEMS[itemId]
end

function TileCatalog.IsValidItem(itemId: string): boolean
	return ITEMS[itemId] ~= nil
end

function TileCatalog.GetAllItems(): { [string]: PlotTypes.ItemConfig }
	return ITEMS
end

return TileCatalog

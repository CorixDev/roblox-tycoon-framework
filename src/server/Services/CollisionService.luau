--!strict

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")

local CollisionService = {}

local GROUP_PLAYERS = "Players"
local GROUP_NPCS = "NPCs"

local function setupCollisionGroups()
	pcall(function()
		PhysicsService:RegisterCollisionGroup(GROUP_PLAYERS)
	end)
	pcall(function()
		PhysicsService:RegisterCollisionGroup(GROUP_NPCS)
	end)

	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(GROUP_PLAYERS, GROUP_NPCS, false)
	end)
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(GROUP_NPCS, GROUP_NPCS, false)
	end)
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(GROUP_PLAYERS, GROUP_PLAYERS, false)
	end)
end

local function applyCollisionGroupToModel(model: Model, groupName: string)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			pcall(function()
				descendant.CollisionGroup = groupName
			end)
		end
	end

	model.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			pcall(function()
				descendant.CollisionGroup = groupName
			end)
		end
	end)
end

function CollisionService.ApplyToNPC(npcModel: Model)
	applyCollisionGroupToModel(npcModel, GROUP_NPCS)
end

function CollisionService.Init()
	setupCollisionGroups()

	local function onCharacterAdded(character: Model)
		applyCollisionGroupToModel(character, GROUP_PLAYERS)

		local pathModifier = character:FindFirstChildOfClass("PathfindingModifier") or Instance.new("PathfindingModifier")
		pathModifier.PassThrough = true
		pathModifier.Parent = character
	end

	local function onPlayerAdded(player: Player)
		if player.Character then
			onCharacterAdded(player.Character)
		end
		player.CharacterAdded:Connect(onCharacterAdded)
	end

	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
end

return CollisionService

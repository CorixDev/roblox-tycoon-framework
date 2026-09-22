--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local function findModule(name: string): any
	local found = ServerScriptService:FindFirstChild(name, true) or ReplicatedStorage:FindFirstChild(name, true)
	if found and found:IsA("ModuleScript") then
		return require(found)
	end
	error(string.format("[SERVER FATAL] Module '%s' not found! Check Explorer.", name))
end

local NetworkService = findModule("NetworkService")
local CollisionService = findModule("CollisionService")
local DataService = findModule("DataService")
local EconomyService = findModule("EconomyService")
local OrderService = findModule("OrderService")
local PlotService = findModule("PlotService")
local NPCService = findModule("NPCService")
local CustomerService = findModule("CustomerService")

local services = {
	{ "NetworkService", function() NetworkService.Init() end },
	{ "CollisionService", function() CollisionService.Init() end },
	{ "DataService", function() DataService.Init() end },
	{ "EconomyService", function() EconomyService.Init(NetworkService, DataService) end },
	{ "PlotService", function() PlotService.Init() end },
	{ "OrderService", function() OrderService.Init() end },
	{ "NPCService", function() NPCService.Init() end },
	{ "CustomerService", function() CustomerService.Init() end },
}

for _, svc in ipairs(services) do
	local name = svc[1]
	local initFn = svc[2]
	local ok, err = pcall(initFn)
	if not ok then
		warn(string.format("[SERVER ERROR] Failed to initialize %s: %s", name, tostring(err)))
	end
end

local function setupPlayer(player: Player)
	task.spawn(function()
		local plotState = nil
		local startWait = os.clock()

		while not plotState and (os.clock() - startWait < 15) do
			if not player.Parent then
				return
			end
			plotState = PlotService.GetPlot(player)
			if not plotState then
				task.wait(0.2)
			end
		end

		if not player.Parent then
			return
		end

		if not plotState then 
			warn(string.format("[SERVER] Plot assignment timeout for player %s", player.Name))
			return 
		end

		local origin = plotState.originCFrame

		NPCService.SpawnWorker(player, "Cook", origin * CFrame.new(6, 2, 4))
		NPCService.SpawnWorker(player, "Cashier", origin * CFrame.new(-6, 2, 4))
	end)
end

Players.PlayerAdded:Connect(setupPlayer)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(setupPlayer, player)
end

--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ProfileService = require(ServerScriptService.Libs.ProfileService)
local PlotTypes = require(ReplicatedStorage.Shared.Types.PlotTypes)

type Profile<T> = {
	Data: T,
	AddUserId: (self: Profile<T>, userId: number) -> (),
	Reconcile: (self: Profile<T>) -> (),
	ListenToRelease: (self: Profile<T>, listener: () -> ()) -> (),
	Release: (self: Profile<T>) -> (),
	Save: (self: Profile<T>) -> (),
	IsActive: (self: Profile<T>) -> boolean,
	[any]: any,
}

export type PlayerProfileData = {
	SchemaVersion: number,
	Balance: number,
	PlacedItems: PlotTypes.PlotGridData,
	Stats: {
		TotalOrdersCompleted: number,
		PlayTimeSeconds: number,
	},
}

local CURRENT_SCHEMA_VERSION = 2

local PROFILE_TEMPLATE: PlayerProfileData = {
	SchemaVersion = CURRENT_SCHEMA_VERSION,
	Balance = 1000,
	PlacedItems = {},
	Stats = {
		TotalOrdersCompleted = 0,
		PlayTimeSeconds = 0,
	},
}

local MIGRATIONS: { [number]: (data: any) -> () } = {
	[1] = function(data)
		if not data.Stats then
			data.Stats = {
				TotalOrdersCompleted = 0,
				PlayTimeSeconds = 0,
			}
		end
	end,
}

local function applyMigrations(data: any)
	local ver = data.SchemaVersion or 1
	while ver < CURRENT_SCHEMA_VERSION do
		local migrateFn = MIGRATIONS[ver]
		if migrateFn then
			local ok, err = pcall(migrateFn, data)
			if not ok then
				warn(string.format("[DataService] Migration failed v%d -> v%d: %s", ver, ver + 1, tostring(err)))
				break
			end
		end
		ver += 1
		data.SchemaVersion = ver
	end
	data.SchemaVersion = CURRENT_SCHEMA_VERSION
end

local ProfileStore = ProfileService.GetProfileStore("TycoonSave_v4", PROFILE_TEMPLATE)

local DataService = {}

local activeProfiles: { [Player]: Profile<PlayerProfileData> } = {}
local loadingThreads: { [Player]: { thread } } = {}

local function resumeWaiters(player: Player)
	local waiters = loadingThreads[player]
	if not waiters then
		return
	end

	loadingThreads[player] = nil
	for _, waitingThread in waiters do
		if coroutine.status(waitingThread) == "suspended" then
			task.spawn(waitingThread)
		end
	end
end

function DataService.LoadProfile(player: Player): PlayerProfileData?
	local existingProfile = activeProfiles[player]
	if existingProfile then
		return existingProfile.Data
	end

	if not player:IsDescendantOf(Players) then
		return nil
	end

	local waiters = loadingThreads[player]
	if waiters ~= nil then
		table.insert(waiters, coroutine.running())
		coroutine.yield()
		local loaded = activeProfiles[player]
		return if loaded ~= nil then loaded.Data else nil
	end

	loadingThreads[player] = {}

	local success, profileOrError = pcall(function()
		return ProfileStore:LoadProfileAsync(`Player_{player.UserId}`)
	end)

	if not success or not profileOrError then
		warn(string.format(
			"[DataService] Failed to load profile for %s (Id: %d): %s",
			player.Name,
			player.UserId,
			tostring(profileOrError)
			))

		resumeWaiters(player)

		if player:IsDescendantOf(Players) then
			player:Kick("Failed to load save data. Please rejoin.")
		end
		return nil
	end

	local profile: Profile<PlayerProfileData> = profileOrError

	if not player:IsDescendantOf(Players) then
		profile:Release()
		resumeWaiters(player)
		return nil
	end

	profile:AddUserId(player.UserId)
	profile:Reconcile()
	applyMigrations(profile.Data)

	profile:ListenToRelease(function()
		activeProfiles[player] = nil
		if player:IsDescendantOf(Players) then
			player:Kick("Your session has been launched on another server.")
		end
	end)

	if not player:IsDescendantOf(Players) then
		profile:Release()
		resumeWaiters(player)
		return nil
	end

	activeProfiles[player] = profile
	resumeWaiters(player)

	return profile.Data
end

function DataService.GetProfile(player: Player): PlayerProfileData?
	local profile = activeProfiles[player]
	return if profile then profile.Data else nil
end

function DataService.IsProfileLoaded(player: Player): boolean
	return activeProfiles[player] ~= nil
end

function DataService.SetPlacedItem(player: Player, uuid: string, item: PlotTypes.SerializedItem)
	local profile = activeProfiles[player]
	if profile and profile.Data and profile.Data.PlacedItems then
		profile.Data.PlacedItems[uuid] = item
	else
		warn(string.format("[DataService] SetPlacedItem ignored: profile not loaded for %s", player.Name))
	end
end

function DataService.RemovePlacedItem(player: Player, uuid: string)
	local profile = activeProfiles[player]
	if profile and profile.Data and profile.Data.PlacedItems then
		profile.Data.PlacedItems[uuid] = nil
	else
		warn(string.format("[DataService] RemovePlacedItem ignored: profile not loaded for %s", player.Name))
	end
end

function DataService.GetPlacedItems(player: Player): PlotTypes.PlotGridData
	local profile = activeProfiles[player]
	if profile and profile.Data and profile.Data.PlacedItems then
		return table.clone(profile.Data.PlacedItems)
	end
	return {}
end

function DataService.SetBalance(player: Player, newBalance: number, _epoch: number?)
	local profile = activeProfiles[player]
	if profile and profile.Data then
		profile.Data.Balance = newBalance
	else
		warn(string.format("[DataService] SetBalance ignored: profile not loaded for %s", player.Name))
	end
end

function DataService.GetBalance(player: Player): number
	local profile = activeProfiles[player]
	if profile and profile.Data then
		return profile.Data.Balance
	end
	return 0
end

function DataService.ReleaseSession(player: Player)
	resumeWaiters(player)
	local profile = activeProfiles[player]
	if profile then
		profile:Release()
		activeProfiles[player] = nil
	end
end

function DataService.RenewLease(player: Player): boolean
	local profile = activeProfiles[player]
	return profile ~= nil and profile:IsActive()
end

function DataService.SaveProfile(player: Player)
	local profile = activeProfiles[player]
	if profile and profile:IsActive() then
		profile:Save()
	end
end

function DataService.Init()
	Players.PlayerRemoving:Connect(function(player)
		resumeWaiters(player)
		local profile = activeProfiles[player]
		if profile then
			profile:Release()
			activeProfiles[player] = nil
		end
	end)
end

return DataService

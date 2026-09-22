--!strict

local SETTINGS = {
	AutoSaveInterval = 30,
	LoadProfileTimeout = 120,
	IssueWarnings = true,
}

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local CURRENT_JOB_ID: string = if game.JobId ~= ""
	then game.JobId
	else (if RunService:IsStudio() then "Studio_Persistent_Session" else HttpService:GenerateGUID(false))
local CURRENT_SESSION_TOKEN = { game.PlaceId, CURRENT_JOB_ID }

local StudioMockStorage: { [string]: any } = {}

local function issueWarning(message: string)
	if SETTINGS.IssueWarnings then
		warn(string.format("[ProfileService]: %s", message))
	end
end

local function isSameSession(sessionA: any, sessionB: any): boolean
	if type(sessionA) ~= "table" or type(sessionB) ~= "table" then
		return false
	end
	return sessionA[1] == sessionB[1] and sessionA[2] == sessionB[2]
end

local function deepCopy<T>(tbl: T): T
	if type(tbl) ~= "table" then
		return tbl
	end
	local copy = {}
	for k, v in pairs(tbl :: any) do
		copy[k] = if type(v) == "table" then deepCopy(v) else v
	end
	return copy :: any
end

local function reconcileTable(target: any, template: any)
	for k, v in pairs(template) do
		if target[k] == nil then
			target[k] = if type(v) == "table" then deepCopy(v) else v
		elseif type(target[k]) == "table" and type(v) == "table" then
			reconcileTable(target[k], v)
		end
	end
end

export type SessionToken = { [number]: any }

export type ProfileMetaData = {
	ProfileCreateTime: number,
	SessionLoadCount: number,
	ActiveSession: SessionToken?,
	LastSaveTime: number?,
	ForceLoadPending: boolean,
	MetaTags: { [string]: any },
}

export type Profile<T> = {
	Data: T,
	MetaData: ProfileMetaData,
	AddUserId: (self: Profile<T>, userId: number) -> (),
	Reconcile: (self: Profile<T>) -> (),
	ListenToRelease: (self: Profile<T>, listener: (placeId: number, gameJobId: string) -> ()) -> (),
	Release: (self: Profile<T>) -> (),
	Save: (self: Profile<T>) -> (),
	IsActive: (self: Profile<T>) -> boolean,
}

export type ProfileStore<T> = {
	LoadProfileAsync: (self: ProfileStore<T>, profileKey: string) -> Profile<T>?,
	ViewProfileAsync: (self: ProfileStore<T>, profileKey: string, version: string?) -> Profile<T>?,
}

local ProfileService = {}
local ActiveProfiles: { [any]: boolean } = {}

game:BindToClose(function()
	local activeList = {}
	for profile in pairs(ActiveProfiles) do
		if profile:IsActive() then
			table.insert(activeList, profile)
		end
	end

	local remaining = #activeList
	if remaining == 0 then return end

	for _, profile in ipairs(activeList) do
		task.spawn(function()
			profile:Release()
			remaining -= 1
		end)
	end

	local startTime = os.clock()
	while remaining > 0 and (os.clock() - startTime < 28) do
		task.wait(0.1)
	end
end)

function ProfileService.GetProfileStore<T>(storeName: string, profileTemplate: T): ProfileStore<T>
	local store = {}
	local activeInStore: { [string]: any } = {}

	local dataStore: DataStore? = nil
	local initSuccess, initErr = pcall(function()
		dataStore = DataStoreService:GetDataStore(storeName)
	end)

	if not initSuccess then
		issueWarning(`Failed to connect to DataStore "{storeName}": {tostring(initErr)}`)
	end

	function store:ViewProfileAsync(profileKey: string, version: string?): Profile<T>?
		if not dataStore then
			issueWarning("Attempted ViewProfileAsync without an active DataStore")
			return nil
		end

		local rawData: any = nil
		local success, _ = pcall(function()
			if version and version ~= "" then
				rawData = (dataStore :: DataStore):GetVersionAsync(profileKey, version)
			else
				rawData = (dataStore :: DataStore):GetAsync(profileKey)
			end
		end)

		if not success or not rawData then
			return nil
		end

		local readOnlyProfile: any = {
			Data = rawData.Data or deepCopy(profileTemplate),
			MetaData = rawData.MetaData or {
				ProfileCreateTime = os.time(),
				SessionLoadCount = 0,
				ActiveSession = nil,
				ForceLoadPending = false,
				MetaTags = {},
			},
		}

		function readOnlyProfile:IsActive(): boolean return false end
		function readOnlyProfile:AddUserId(_: number) end
		function readOnlyProfile:Reconcile() reconcileTable(self.Data, profileTemplate) end
		function readOnlyProfile:ListenToRelease(_: any) end
		function readOnlyProfile:Save() issueWarning("Cannot save profile in View mode") end
		function readOnlyProfile:Release() end

		return readOnlyProfile
	end

	function store:LoadProfileAsync(profileKey: string): Profile<T>?
		if activeInStore[profileKey] then
			return activeInStore[profileKey]
		end

		local loadedData: any = nil
		local loadedMetaData: ProfileMetaData? = nil
		local inMockFallback = false

		if dataStore then
			local success, result = pcall(function()
				return (dataStore :: DataStore):UpdateAsync(profileKey, function(current: any)
					current = current or {
						Data = deepCopy(profileTemplate),
						MetaData = {
							ProfileCreateTime = os.time(),
							SessionLoadCount = 0,
							ActiveSession = nil,
							ForceLoadPending = false,
							MetaTags = {},
						},
					}

					local active = current.MetaData.ActiveSession
					local now = os.time()
					local lastSave = current.MetaData.LastSaveTime or now

					if active then
						local isOurs = isSameSession(active, CURRENT_SESSION_TOKEN)
						local isExpired = (now - lastSave) >= SETTINGS.LoadProfileTimeout

						if RunService:IsStudio() then
							isOurs = true
						end

						if not isOurs and not isExpired then
							return nil
						end
					end

					current.MetaData.ActiveSession = CURRENT_SESSION_TOKEN
					current.MetaData.SessionLoadCount = (current.MetaData.SessionLoadCount or 0) + 1
					current.MetaData.LastSaveTime = now
					return current
				end)
			end)

			if not success then
				if RunService:IsStudio() then
					issueWarning(`API Services are disabled in Studio. Switched to Mock Storage for "{profileKey}".`)
					inMockFallback = true
				else
					issueWarning(`Failed to load key "{profileKey}": network error or session busy ({tostring(result)})`)
					return nil
				end
			elseif not result then
				issueWarning(`Session for key "{profileKey}" is locked by another server.`)
				return nil
			else
				loadedData = result.Data
				loadedMetaData = result.MetaData
			end
		else
			inMockFallback = true
		end

		if inMockFallback then
			local existingMock = StudioMockStorage[profileKey]
			if existingMock then
				loadedData = existingMock.Data
				loadedMetaData = existingMock.MetaData
			else
				loadedData = deepCopy(profileTemplate)
				loadedMetaData = {
					ProfileCreateTime = os.time(),
					SessionLoadCount = 1,
					ActiveSession = CURRENT_SESSION_TOKEN,
					LastSaveTime = os.time(),
					ForceLoadPending = false,
					MetaTags = {},
				}
				StudioMockStorage[profileKey] = {
					Data = loadedData,
					MetaData = loadedMetaData,
				}
			end
		end

		local profileObj: any = {
			Data = loadedData or deepCopy(profileTemplate),
			MetaData = loadedMetaData :: ProfileMetaData,
			_key = profileKey,
			_released = false,
			_listeners = {},
			_userIds = {} :: { number },
			_inMock = inMockFallback,
		}

		function profileObj:_triggerRelease(placeId: number, jobId: string)
			if self._released then return end
			self._released = true
			activeInStore[self._key] = nil
			ActiveProfiles[self] = nil

			for _, listener in ipairs(self._listeners) do
				task.spawn(listener, placeId, jobId)
			end
		end

		function profileObj:AddUserId(userId: number)
			if not table.find(self._userIds, userId) then
				table.insert(self._userIds, userId)
			end
		end

		function profileObj:Reconcile()
			reconcileTable(self.Data, profileTemplate)
		end

		function profileObj:ListenToRelease(listener: (placeId: number, gameJobId: string) -> ())
			table.insert(self._listeners, listener)
		end

		function profileObj:IsActive(): boolean
			return not self._released
		end

		function profileObj:Save()
			if self._released then return end

			if self._inMock then
				StudioMockStorage[self._key] = {
					Data = deepCopy(self.Data),
					MetaData = self.MetaData,
				}
				self.MetaData.LastSaveTime = os.time()
				return
			end

			if not dataStore then return end

			local sessionLost = false
			local thiefSession: SessionToken? = nil

			local success, saveErr = pcall(function()
				(dataStore :: DataStore):UpdateAsync(self._key, function(current: any)
					if not current then return nil end

					if not isSameSession(current.MetaData.ActiveSession, CURRENT_SESSION_TOKEN) and not RunService:IsStudio() then
						sessionLost = true
						thiefSession = current.MetaData.ActiveSession
						return nil
					end

					current.Data = self.Data
					current.MetaData.LastSaveTime = os.time()
					current.MetaData.MetaTags = self.MetaData.MetaTags
					return current, self._userIds, current.MetaData.MetaTags
				end)
			end)

			if not success then
				issueWarning(`Failed to save key "{self._key}": {tostring(saveErr)}`)
				return
			end

			if sessionLost then
				issueWarning(`Session for key "{self._key}" was acquired by another server.`)
				local placeId = if thiefSession and thiefSession[1] then thiefSession[1] else 0
				local jobId = if thiefSession and thiefSession[2] then thiefSession[2] else ""
				self:_triggerRelease(placeId, jobId)
			else
				self.MetaData.LastSaveTime = os.time()
			end
		end

		function profileObj:Release()
			if self._released then return end

			if not self._inMock and dataStore then
				pcall(function()
					(dataStore :: DataStore):UpdateAsync(self._key, function(current: any)
						if not current then return nil end
						if isSameSession(current.MetaData.ActiveSession, CURRENT_SESSION_TOKEN) or RunService:IsStudio() then
							current.Data = self.Data
							current.MetaData.ActiveSession = nil
							current.MetaData.LastSaveTime = os.time()
							return current, self._userIds, current.MetaData.MetaTags
						end
						return nil
					end)
				end)
			end

			self:_triggerRelease(game.PlaceId, CURRENT_JOB_ID)
		end

		activeInStore[profileKey] = profileObj
		ActiveProfiles[profileObj] = true
		return profileObj
	end

	task.spawn(function()
		while true do
			task.wait(SETTINGS.AutoSaveInterval)
			local activeProfiles = {}
			for _, profile in pairs(activeInStore) do
				if profile:IsActive() then
					table.insert(activeProfiles, profile)
				end
			end

			local count = #activeProfiles
			if count > 0 then
				local delayBetween = math.max(0.1, SETTINGS.AutoSaveInterval / count)
				for _, profile in ipairs(activeProfiles) do
					if profile:IsActive() then
						task.spawn(function()
							profile:Save()
						end)
					end
					task.wait(delayBetween)
				end
			end
		end
	end)

	return (store :: any) :: ProfileStore<T>
end

return ProfileService

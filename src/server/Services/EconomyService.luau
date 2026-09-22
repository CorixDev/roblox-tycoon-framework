--!strict
--!native

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local MAX_SAFE_INTEGER: number = 9007199254740991
local MIN_SAFE_INTEGER: number = 0
local DEFAULT_STARTING_BALANCE: number = 1000

local NETWORK_BUFFER_SIZE_BYTES: number = 22
local PACKET_ID_BALANCE_SYNC: number = 1
local IDEMPOTENCY_RING_CAPACITY: number = 32

local REASON_CODE_MULTI_OP: number = 255
local MIN_IMMEDIATE_FLUSH_INTERVAL_SECONDS: number = 0.033

local MAX_TXID_STRING_LENGTH: number = 64
local MAX_IDEMPOTENCY_KEY_LENGTH: number = 128
local MAX_PLAYERS_CAPACITY: number = 256

local AUTOSAVE_INTERVAL_SECONDS: number = 30
local AUTOSAVE_BATCH_CHUNK_SIZE: number = 8
local AUTOSAVE_BATCH_INTERVAL_SECONDS: number = 0.5

local LEASE_HEARTBEAT_INTERVAL_SECONDS: number = 20
local LEASE_RENEW_BATCH_SIZE: number = 24
local LEASE_RENEW_BATCH_INTERVAL_SECONDS: number = 0.05

local MAX_CONCURRENT_DRAIN_SAVES: number = 8
local HARD_ENGINE_SHUTDOWN_LIMIT_SECONDS: number = 28.5
local LEADERSTAT_SYNC_INTERVAL_SECONDS: number = 0.5
local PERSIST_WAIT_DEADLINE_SECONDS: number = 5.0
local INIT_GRACE_WINDOW_SECONDS: number = 4.0

local ServerTxCounter: number = 0

local function generateTxId(): number
	ServerTxCounter = (ServerTxCounter + 1) % MAX_SAFE_INTEGER
	return ServerTxCounter
end

export type TransactionErrorCode =
	| "INVALID_AMOUNT"
| "NAN_OR_INFINITY_DETECTED"
| "FRACTIONAL_VALUE_NOT_ALLOWED"
| "INSUFFICIENT_FUNDS"
| "OVERFLOW_RISK"
| "LEDGER_LOCKED"
| "SESSION_TERMINATED"
| "PLAYER_NOT_FOUND"
| "SERVICE_DESTROYED"

export type TransactionContext = {
	txId: (string | number)?,
	source: string?,
	idempotencyKey: string?,
	reasonCode: number?,
	timestamp: number?,
}

export type TransactionResult =
	| {
		type: "SUCCESS",
		balance: number,
		delta: number,
		sequenceNumber: number,
		txId: string | number,
	}
| {
	type: "FAILED",
	error: TransactionErrorCode,
	currentBalance: number,
	txId: string | number,
}

export type PlayerLedgerState =
	| { status: "UNLOADED" }
| { status: "ACQUIRING_LOCK", attempt: number, lockTime: number }
| {
	status: "READY",
	balance: number,
	sequenceNumber: number,
	isDirty: boolean,
	lastSyncTime: number,
}
| { status: "SAVING", balance: number, sequenceNumber: number }
| { status: "CORRUPTED", reason: string }
| { status: "TERMINATED" }

type InternalLedger = {
	player: Player,
	status: "UNLOADED" | "ACQUIRING_LOCK" | "READY" | "SAVING" | "CORRUPTED" | "TERMINATED",
	balance: number,
	sequenceNumber: number,
	lastSyncedSeq: number,
	isDirty: boolean,
	inDirtyQueue: boolean,
	isPersistDirty: boolean,
	isPersisting: boolean,
	currentSaveEpoch: number,
	persistWaitThread: thread?,
	lastDelta: number,
	lastReason: number,
	lastSyncTime: number,
	lastPersistTime: number,
	lastLeaseTime: number,
	lastImmediateFlushTime: number,
	cachedLeaderstat: IntValue?,
	networkBuffer: buffer,
	idempotencyKeys: { string },
	idempotencyResults: { TransactionResult? },
	idempotencyHead: number,
	initThread: thread?,
}

export type INetworkRemote = {
	FireClient: (self: any, player: Player, ...any) -> (),
}

export type INetworkService = {
	GetEvent: (name: any) -> any,
}

export type IDataProfile = {
	Balance: number,
	JobId: string?,
	LockTimestamp: number?,
	Epoch: number?,
}

export type IDataService = {
	GetBalance: (player: Player) -> number,
	SetBalance: (player: Player, newBalance: number, epoch: number?) -> (),
	LoadProfile: (player: Player) -> any,
	ReleaseSession: ((player: Player) -> ())?,
	RenewLease: ((player: Player) -> boolean)?,
	SaveProfile: ((player: Player) -> ())?,
}

local NetworkService: INetworkService? = nil
local DataService: IDataService? = nil

local InFlightSavesCount: number = 0
local DrainWaitingThread: thread? = nil

local function incrementInFlight()
	InFlightSavesCount += 1
end

local function decrementInFlight()
	InFlightSavesCount = math.max(0, InFlightSavesCount - 1)
	if InFlightSavesCount == 0 and DrainWaitingThread then
		local t = DrainWaitingThread
		DrainWaitingThread = nil
		if coroutine.status(t) ~= "dead" then
			task.spawn(t)
		end
	end
end

local Ledgers: { [Player]: InternalLedger } = {}
local DirtyPlayers: { Player } = table.create(MAX_PLAYERS_CAPACITY, nil :: any)
local DirtyCount: number = 0

local PostSimulationConnection: RBXScriptConnection? = nil
local PlayerAddedConnection: RBXScriptConnection? = nil
local PlayerRemovingConnection: RBXScriptConnection? = nil
local AutoSaveThread: thread? = nil
local LeaseHeartbeatThread: thread? = nil
local LeaderstatThread: thread? = nil

local IsInitialized: boolean = false
local IsDestroyed: boolean = false
local IsDraining: boolean = false
local IsDrainComplete: boolean = false

local function safeCancelThread(threadRef: thread?)
	if threadRef and coroutine.status(threadRef) ~= "dead" then
		task.cancel(threadRef)
	end
end

local function releasePersistLock(ledger: InternalLedger, completedEpoch: number)
	if ledger.currentSaveEpoch == completedEpoch then
		ledger.isPersisting = false

		if ledger.persistWaitThread then
			local waitingThread = ledger.persistWaitThread
			ledger.persistWaitThread = nil
			if coroutine.status(waitingThread) ~= "dead" then
				task.spawn(waitingThread)
			end
		end
	end
end

local function executePersistenceWithRetry(
	player: Player,
	balance: number,
	epoch: number?,
	maxAttempts: number?
): (boolean, any)
	if not DataService then
		return false, "DataService is nil"
	end

	local attempts = maxAttempts or 3
	local success = false
	local err: any = nil

	for attempt = 1, attempts do
		success, err = pcall(function()
			DataService.SetBalance(player, balance, epoch)
			if DataService.SaveProfile then
				DataService.SaveProfile(player)
			end
		end)
		if success then
			break
		end
		if attempt < attempts then
			task.wait(0.4 * attempt)
		end
	end

	return success, err
end

local function safeReleaseSession(player: Player)
	if DataService and DataService.ReleaseSession then
		pcall(function()
			DataService.ReleaseSession(player)
		end)
	end
end

local function validateBalanceValue(balance: any): boolean
	if typeof(balance) ~= "number" then
		return false
	end
	if balance ~= balance or balance <= -math.huge or balance >= math.huge then
		return false
	end
	return balance >= MIN_SAFE_INTEGER and balance <= MAX_SAFE_INTEGER and balance == math.floor(balance)
end

local function validateDeltaAmount(amount: any): (boolean, TransactionErrorCode?)
	if typeof(amount) ~= "number" then
		return false, "INVALID_AMOUNT"
	end
	if amount ~= amount or amount <= -math.huge or amount >= math.huge then
		return false, "NAN_OR_INFINITY_DETECTED"
	end
	if amount == 0 then
		return false, "INVALID_AMOUNT"
	end
	if amount ~= math.floor(amount) then
		return false, "FRACTIONAL_VALUE_NOT_ALLOWED"
	end

	return true, nil
end

local function getCachedIdempotentResult(ledger: InternalLedger, key: string?): TransactionResult?
	if not key or key == "" then
		return nil
	end

	local keys = ledger.idempotencyKeys
	local results = ledger.idempotencyResults

	for i = 1, IDEMPOTENCY_RING_CAPACITY do
		if keys[i] == key then
			return results[i]
		end
	end
	return nil
end

local function commitIdempotencyRecord(
	ledger: InternalLedger,
	key: string?,
	balance: number,
	delta: number,
	seq: number,
	txId: string | number
): TransactionResult
	local res: TransactionResult = table.freeze({
		type = "SUCCESS",
		balance = balance,
		delta = delta,
		sequenceNumber = seq,
		txId = txId,
	})

	if key and key ~= "" then
		local head = (ledger.idempotencyHead % IDEMPOTENCY_RING_CAPACITY) + 1
		ledger.idempotencyHead = head
		ledger.idempotencyKeys[head] = key
		ledger.idempotencyResults[head] = res
	end

	return res
end

local function markPlayerDirty(player: Player, ledger: InternalLedger)
	ledger.isDirty = true
	if not ledger.inDirtyQueue then
		ledger.inDirtyQueue = true
		DirtyCount += 1
		DirtyPlayers[DirtyCount] = player
	end
end

local function writeNaturallyAlignedBuffer(buf: buffer, balance: number, delta: number, seq: number, reason: number)
	buffer.writef64(buf, 0, balance)
	buffer.writef64(buf, 8, delta)
	buffer.writeu32(buf, 16, seq)
	buffer.writeu8(buf, 20, PACKET_ID_BALANCE_SYNC)
	buffer.writeu8(buf, 21, reason)
end

local function flushSinglePlayerImmediate(player: Player, ledger: InternalLedger)
	if ledger.sequenceNumber == ledger.lastSyncedSeq then
		return
	end

	local buf = ledger.networkBuffer
	writeNaturallyAlignedBuffer(buf, ledger.balance, ledger.lastDelta, ledger.sequenceNumber, ledger.lastReason)

	local balanceEvent = if NetworkService then NetworkService.GetEvent("BalanceUpdated") else nil
	if balanceEvent and player.Parent == Players then
		balanceEvent:FireClient(player, buf)
	end

	ledger.lastSyncedSeq = ledger.sequenceNumber
	ledger.lastDelta = 0
	ledger.lastReason = 0
	ledger.lastSyncTime = os.clock()
end

local function flushDirtyQueue()
	if DirtyCount == 0 then
		return
	end

	local balanceEvent = if NetworkService then NetworkService.GetEvent("BalanceUpdated") else nil
	local now = os.clock()

	for i = 1, DirtyCount do
		local player = DirtyPlayers[i]
		DirtyPlayers[i] = nil :: any

		if player then
			local ledger = Ledgers[player]
			if ledger then
				ledger.inDirtyQueue = false

				if ledger.status == "READY" and ledger.isDirty then
					ledger.isDirty = false

					if ledger.sequenceNumber ~= ledger.lastSyncedSeq then
						local buf = ledger.networkBuffer
						writeNaturallyAlignedBuffer(buf, ledger.balance, ledger.lastDelta, ledger.sequenceNumber, ledger.lastReason)

						if balanceEvent and player.Parent == Players then
							balanceEvent:FireClient(player, buf)
						end

						ledger.lastSyncedSeq = ledger.sequenceNumber
						ledger.lastDelta = 0
						ledger.lastReason = 0
						ledger.lastSyncTime = now
					end
				end
			end
		end
	end

	DirtyCount = 0
end

local function leaderstatSyncWorker()
	while IsInitialized and not IsDestroyed do
		task.wait(LEADERSTAT_SYNC_INTERVAL_SECONDS)

		if not IsInitialized or IsDestroyed then
			break
		end

		for _, ledger in Ledgers do
			if ledger.status == "READY" or ledger.status == "SAVING" then
				local moneyVal = ledger.cachedLeaderstat
				if moneyVal and moneyVal.Parent ~= nil then
					local currentMemBalance = ledger.balance
					if moneyVal.Value ~= currentMemBalance then
						moneyVal.Value = currentMemBalance
					end
				end
			end
		end
	end
end

local function leaseHeartbeatWorker()
	while IsInitialized and not IsDestroyed and not IsDraining do
		task.wait(LEASE_HEARTBEAT_INTERVAL_SECONDS)

		if not IsInitialized or IsDestroyed or IsDraining or not DataService or not DataService.RenewLease then
			continue
		end

		local activeSessions: { Player } = table.create(MAX_PLAYERS_CAPACITY, nil :: any)
		local activeCount = 0

		for player, ledger in Ledgers do
			if ledger.status == "READY" and player.Parent == Players then
				activeCount += 1
				activeSessions[activeCount] = player
			end
		end

		for i = 1, activeCount, LEASE_RENEW_BATCH_SIZE do
			if not IsInitialized or IsDestroyed or IsDraining then
				break
			end

			local batchEnd = math.min(i + LEASE_RENEW_BATCH_SIZE - 1, activeCount)
			for j = i, batchEnd do
				local player = activeSessions[j]
				task.spawn(function()
					local preCheckLedger = Ledgers[player]
					if not preCheckLedger or preCheckLedger.status ~= "READY" or player.Parent ~= Players then
						return
					end

					local success, renewed = pcall(function()
						if DataService and DataService.RenewLease then
							return DataService.RenewLease(player)
						end
						return false
					end)

					local postCheckLedger = Ledgers[player]
					if not postCheckLedger or postCheckLedger.status ~= "READY" or player.Parent ~= Players then
						return
					end

					if success and renewed == true then
						postCheckLedger.lastLeaseTime = os.clock()
					elseif success and renewed == false then
						postCheckLedger.status = "CORRUPTED"
						warn(string.format("[EconomyService] Lease STOLEN for Player %d!", player.UserId))
						player:Kick("Session acquired by another node.")
					end
				end)
			end

			if batchEnd < activeCount then
				task.wait(LEASE_RENEW_BATCH_INTERVAL_SECONDS)
			end
		end
	end
end

local function autoSaveWorker()
	while IsInitialized and not IsDestroyed and not IsDraining do
		task.wait(AUTOSAVE_INTERVAL_SECONDS)

		if not IsInitialized or IsDestroyed or IsDraining or not DataService then
			break
		end

		local snapshot: { Player } = table.create(MAX_PLAYERS_CAPACITY, nil :: any)
		local snapshotCount = 0

		for player, ledger in Ledgers do
			if ledger.status == "READY" and ledger.isPersistDirty and not ledger.isPersisting then
				snapshotCount += 1
				snapshot[snapshotCount] = player
			end
		end

		for i = 1, snapshotCount, AUTOSAVE_BATCH_CHUNK_SIZE do
			if not IsInitialized or IsDestroyed or IsDraining then
				break
			end

			local batchEnd = math.min(i + AUTOSAVE_BATCH_CHUNK_SIZE - 1, snapshotCount)

			for j = i, batchEnd do
				local player = snapshot[j]
				local ledger = Ledgers[player]

				if ledger and ledger.status == "READY" and ledger.isPersistDirty and not ledger.isPersisting then
					ledger.isPersisting = true
					ledger.currentSaveEpoch += 1
					local thisEpoch = ledger.currentSaveEpoch
					local versionToSave = ledger.sequenceNumber
					local balanceToSave = ledger.balance

					incrementInFlight()

					task.spawn(function()
						local executionOk, saveSuccess, saveErr = pcall(executePersistenceWithRetry, player, balanceToSave, thisEpoch, 2)

						if executionOk and saveSuccess then
							ledger.lastPersistTime = os.clock()
							ledger.lastLeaseTime = os.clock()

							if ledger.currentSaveEpoch == thisEpoch and ledger.sequenceNumber == versionToSave then
								ledger.isPersistDirty = false
							end
						else
							ledger.isPersistDirty = true
							local errText = if not executionOk then tostring(saveSuccess) else tostring(saveErr)
							warn(string.format("[EconomyService] AutoSave failed for Player %d: %s", player.UserId, errText))
						end

						releasePersistLock(ledger, thisEpoch)
						decrementInFlight()
					end)
				end
			end

			if batchEnd < snapshotCount then
				task.wait(AUTOSAVE_BATCH_INTERVAL_SECONDS)
			end
		end
	end
end

local function onPlayerAdded(player: Player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end

	if IsDestroyed or IsDraining or not DataService or Ledgers[player] ~= nil then
		return
	end

	local ledgerBuf = buffer.create(NETWORK_BUFFER_SIZE_BYTES)
	local idKeys: { string } = table.create(IDEMPOTENCY_RING_CAPACITY, "")
	local idResults: { TransactionResult? } = table.create(IDEMPOTENCY_RING_CAPACITY, nil)

	local ledger: InternalLedger = {
		player = player,
		status = "ACQUIRING_LOCK",
		balance = 0,
		sequenceNumber = 0,
		lastSyncedSeq = -1,
		isDirty = false,
		inDirtyQueue = false,
		isPersistDirty = false,
		isPersisting = false,
		currentSaveEpoch = 0,
		persistWaitThread = nil,
		lastDelta = 0,
		lastReason = 0,
		lastSyncTime = os.clock(),
		lastPersistTime = os.clock(),
		lastLeaseTime = os.clock(),
		lastImmediateFlushTime = 0,
		cachedLeaderstat = nil,
		networkBuffer = ledgerBuf,
		idempotencyKeys = idKeys,
		idempotencyResults = idResults,
		idempotencyHead = 0,
		initThread = nil,
	}

	Ledgers[player] = ledger

	ledger.initThread = task.spawn(function()
		local profileData: any = nil
		local maxLoadAttempts = 3

		for attempt = 1, maxLoadAttempts do
			if player.Parent ~= Players or IsDestroyed or IsDraining then
				break
			end

			local loadSuccess, result = pcall(function()
				return DataService.LoadProfile(player)
			end)

			if loadSuccess and result ~= nil then
				profileData = result
				break
			end

			if attempt < maxLoadAttempts then
				task.wait(0.5 * attempt)
			end
		end

		if player.Parent ~= Players or IsDestroyed or IsDraining then
			if profileData ~= nil then
				safeReleaseSession(player)
			end
			Ledgers[player] = nil
			ledger.initThread = nil
			return
		end

		if not profileData then
			warn(string.format("[EconomyService] Failed to acquire profile for Player %d.", player.UserId))
			ledger.status = "CORRUPTED"
			ledger.initThread = nil
			return
		end

		local initialBalance = profileData.Balance or DEFAULT_STARTING_BALANCE
		if not validateBalanceValue(initialBalance) then
			initialBalance = DEFAULT_STARTING_BALANCE
		end

		local leaderstats = player:FindFirstChild("leaderstats") :: Folder?
		local shouldMountFolder = false

		if not leaderstats then
			local newFolder = Instance.new("Folder")
			newFolder.Name = "leaderstats"
			leaderstats = newFolder
			shouldMountFolder = true
		end

		local moneyVal = leaderstats:FindFirstChild("Money") :: IntValue?
		if not moneyVal then
			local newMoney = Instance.new("IntValue")
			newMoney.Name = "Money"
			newMoney.Value = initialBalance
			newMoney.Parent = leaderstats
			moneyVal = newMoney
		else
			moneyVal.Value = initialBalance
		end

		if shouldMountFolder then
			leaderstats.Parent = player
		end

		ledger.cachedLeaderstat = moneyVal
		ledger.balance = initialBalance
		ledger.status = "READY"
		ledger.initThread = nil

		markPlayerDirty(player, ledger)
	end)
end

local function onPlayerRemoving(player: Player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end

	if IsDraining then
		return
	end

	local ledger = Ledgers[player]
	if not ledger then
		return
	end

	if ledger.initThread then
		local initDeadline = os.clock() + INIT_GRACE_WINDOW_SECONDS
		while ledger.initThread and coroutine.status(ledger.initThread) ~= "dead" and os.clock() < initDeadline do
			task.wait(0.1)
		end
		if ledger.initThread and coroutine.status(ledger.initThread) ~= "dead" then
			safeCancelThread(ledger.initThread)
			ledger.initThread = nil
		end
	end

	if ledger.isPersisting then
		ledger.persistWaitThread = coroutine.running()
		local timeoutThread = task.delay(PERSIST_WAIT_DEADLINE_SECONDS, function()
			if ledger.persistWaitThread then
				local t = ledger.persistWaitThread
				ledger.persistWaitThread = nil
				if coroutine.status(t) ~= "dead" then
					task.spawn(t)
				end
			end
		end)
		coroutine.yield()
		safeCancelThread(timeoutThread)
	end

	local hadActiveOwnership = (ledger.status == "READY" or ledger.status == "SAVING")

	if hadActiveOwnership and DataService then
		ledger.status = "SAVING"
		DataService.SetBalance(player, ledger.balance)
		if DataService.SaveProfile then
			pcall(DataService.SaveProfile, player)
		end
		safeReleaseSession(player)
	end

	ledger.status = "TERMINATED"
	ledger.cachedLeaderstat = nil
	Ledgers[player] = nil
end

local function executeDrainProcedure(callerSource: string)
	if not DataService then
		IsDrainComplete = true
		return
	end

	if IsDraining then return end
	IsDraining = true

	safeCancelThread(AutoSaveThread)
	AutoSaveThread = nil
	safeCancelThread(LeaseHeartbeatThread)
	LeaseHeartbeatThread = nil
	safeCancelThread(LeaderstatThread)
	LeaderstatThread = nil

	for player, ledger in Ledgers do
		safeCancelThread(ledger.initThread)
		ledger.initThread = nil

		if ledger.status == "READY" or ledger.status == "SAVING" then
			DataService.SetBalance(player, ledger.balance)
			safeReleaseSession(player)
		end
		ledger.status = "TERMINATED"
	end

	IsDrainComplete = true
end

local EconomyService = {}

function EconomyService.TryMutate(
	player: Player,
	delta: number,
	ctx: TransactionContext
): TransactionResult
	local safeTxId: string | number
	if typeof(ctx) == "table" and ctx.txId ~= nil then
		local tid = ctx.txId
		if typeof(tid) == "string" and #tid <= MAX_TXID_STRING_LENGTH then
			safeTxId = tid
		elseif typeof(tid) == "number" and tid == tid and tid > -math.huge and tid < math.huge then
			safeTxId = tid
		else
			safeTxId = generateTxId()
		end
	else
		safeTxId = generateTxId()
	end

	if typeof(player) ~= "Instance" or not player:IsA("Player") or player.Parent ~= Players then
		return {
			type = "FAILED",
			error = "PLAYER_NOT_FOUND",
			currentBalance = 0,
			txId = safeTxId,
		}
	end

	if IsDestroyed or IsDraining then
		return {
			type = "FAILED",
			error = "SESSION_TERMINATED",
			currentBalance = 0,
			txId = safeTxId,
		}
	end

	local ledger = Ledgers[player]
	if not ledger then
		return {
			type = "FAILED",
			error = "PLAYER_NOT_FOUND",
			currentBalance = 0,
			txId = safeTxId,
		}
	end

	if ledger.status ~= "READY" then
		return {
			type = "FAILED",
			error = "LEDGER_LOCKED",
			currentBalance = ledger.balance,
			txId = safeTxId,
		}
	end

	local safeIdempotencyKey: string? = nil
	if typeof(ctx) == "table" and typeof(ctx.idempotencyKey) == "string" and #ctx.idempotencyKey > 0 and #ctx.idempotencyKey <= MAX_IDEMPOTENCY_KEY_LENGTH then
		safeIdempotencyKey = ctx.idempotencyKey
	end

	local cachedResult = getCachedIdempotentResult(ledger, safeIdempotencyKey)
	if cachedResult then
		return cachedResult
	end

	local isValid, errCode = validateDeltaAmount(delta)
	if not isValid then
		return {
			type = "FAILED",
			error = errCode :: TransactionErrorCode,
			currentBalance = ledger.balance,
			txId = safeTxId,
		}
	end

	local currentBalance = ledger.balance
	local targetBalance = currentBalance + delta

	if targetBalance < MIN_SAFE_INTEGER then
		return {
			type = "FAILED",
			error = "INSUFFICIENT_FUNDS",
			currentBalance = currentBalance,
			txId = safeTxId,
		}
	end

	if targetBalance > MAX_SAFE_INTEGER then
		return {
			type = "FAILED",
			error = "OVERFLOW_RISK",
			currentBalance = currentBalance,
			txId = safeTxId,
		}
	end

	local incomingReason: number = 1
	if typeof(ctx) == "table" and ctx.reasonCode ~= nil then
		local rc = ctx.reasonCode
		if typeof(rc) == "number" and rc == rc and rc > -math.huge and rc < math.huge then
			incomingReason = math.clamp(math.floor(math.abs(rc)) % 256, 0, 254)
		end
	end

	local now = os.clock()
	local nextReason = incomingReason

	if ledger.isDirty and ledger.lastReason ~= 0 and ledger.lastReason ~= incomingReason then
		if (now - ledger.lastImmediateFlushTime) >= MIN_IMMEDIATE_FLUSH_INTERVAL_SECONDS then
			flushSinglePlayerImmediate(player, ledger)
			ledger.lastImmediateFlushTime = now
		else
			nextReason = REASON_CODE_MULTI_OP
		end
	elseif ledger.lastReason == REASON_CODE_MULTI_OP then
		nextReason = REASON_CODE_MULTI_OP
	end

	ledger.balance = targetBalance
	ledger.sequenceNumber = (ledger.sequenceNumber + 1) % 4294967296
	ledger.lastDelta += delta
	ledger.lastReason = nextReason
	ledger.isPersistDirty = true

	if DataService then
		DataService.SetBalance(player, targetBalance)
	end

	local committedResult = commitIdempotencyRecord(
		ledger,
		safeIdempotencyKey,
		targetBalance,
		delta,
		ledger.sequenceNumber,
		safeTxId
	)

	markPlayerDirty(player, ledger)
	return committedResult
end

function EconomyService.GetState(player: Player): PlayerLedgerState
	if typeof(player) ~= "Instance" or not player:IsA("Player") or player.Parent ~= Players then
		return { status = "UNLOADED" }
	end

	local ledger = Ledgers[player]
	if not ledger then
		return { status = "UNLOADED" }
	end

	if ledger.status == "READY" then
		return {
			status = "READY",
			balance = ledger.balance,
			sequenceNumber = ledger.sequenceNumber,
			isDirty = ledger.isDirty,
			lastSyncTime = ledger.lastSyncTime,
		}
	elseif ledger.status == "ACQUIRING_LOCK" then
		return {
			status = "ACQUIRING_LOCK",
			attempt = 1,
			lockTime = ledger.lastSyncTime,
		}
	elseif ledger.status == "SAVING" then
		return {
			status = "SAVING",
			balance = ledger.balance,
			sequenceNumber = ledger.sequenceNumber,
		}
	elseif ledger.status == "CORRUPTED" then
		return {
			status = "CORRUPTED",
			reason = "Data integrity check failure",
		}
	else
		return { status = "TERMINATED" }
	end
end

function EconomyService.FlushDirtyState(player: Player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") or player.Parent ~= Players then
		return
	end

	local ledger = Ledgers[player]
	if ledger and ledger.status == "READY" and ledger.sequenceNumber ~= ledger.lastSyncedSeq then
		flushSinglePlayerImmediate(player, ledger)
	end
end

function EconomyService.GetBalance(player: Player): number
	if typeof(player) ~= "Instance" or not player:IsA("Player") or player.Parent ~= Players then
		return 0
	end

	local ledger = Ledgers[player]
	if ledger and (ledger.status == "READY" or ledger.status == "SAVING") then
		return ledger.balance
	end

	if DataService then
		local success, balance = pcall(function()
			return DataService.GetBalance(player)
		end)
		return if success and typeof(balance) == "number" then balance else 0
	end
	return 0
end

function EconomyService.AddBalance(player: Player, amount: number)
	if amount <= 0 then
		return
	end

	EconomyService.TryMutate(player, amount, {
		txId = generateTxId(),
		source = "AddBalance",
		reasonCode = 1,
		timestamp = os.clock(),
	})
end

function EconomyService.RemoveBalance(player: Player, amount: number): boolean
	if amount <= 0 then
		return false
	end

	local result = EconomyService.TryMutate(player, -amount, {
		txId = generateTxId(),
		source = "RemoveBalance",
		reasonCode = 2,
		timestamp = os.clock(),
	})

	return result.type == "SUCCESS"
end

function EconomyService.Init(customNetworkService: INetworkService?, customDataService: IDataService?)
	if IsInitialized or IsDestroyed then
		return
	end
	IsInitialized = true

	if customNetworkService then
		NetworkService = customNetworkService
	else
		local networkModule = ReplicatedStorage:FindFirstChild("Network")
		if networkModule and networkModule:FindFirstChild("NetworkService") then
			NetworkService = require(networkModule:FindFirstChild("NetworkService") :: ModuleScript) :: any
		end
	end

	if customDataService then
		DataService = customDataService
	else
		local serverModule = ServerScriptService:FindFirstChild("Server")
		local servicesModule = if serverModule then serverModule:FindFirstChild("Services") else nil
		if servicesModule and servicesModule:FindFirstChild("DataService") then
			DataService = require(servicesModule:FindFirstChild("DataService") :: ModuleScript) :: any
		end
	end

	PlayerAddedConnection = Players.PlayerAdded:Connect(onPlayerAdded)
	PlayerRemovingConnection = Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, player)
	end

	PostSimulationConnection = RunService.PostSimulation:Connect(flushDirtyQueue)
	AutoSaveThread = task.spawn(autoSaveWorker)
	LeaseHeartbeatThread = task.spawn(leaseHeartbeatWorker)
	LeaderstatThread = task.spawn(leaderstatSyncWorker)

	game:BindToClose(function()
		executeDrainProcedure("BindToClose")
	end)
end

function EconomyService.Destroy()
	if IsDestroyed then return end
	IsDestroyed = true
	IsInitialized = false

	if PostSimulationConnection then
		PostSimulationConnection:Disconnect()
		PostSimulationConnection = nil
	end
	if PlayerAddedConnection then
		PlayerAddedConnection:Disconnect()
		PlayerAddedConnection = nil
	end
	if PlayerRemovingConnection then
		PlayerRemovingConnection:Disconnect()
		PlayerRemovingConnection = nil
	end

	executeDrainProcedure("Destroy")
	table.clear(Ledgers)
	table.clear(DirtyPlayers)
	DirtyCount = 0
end

return EconomyService

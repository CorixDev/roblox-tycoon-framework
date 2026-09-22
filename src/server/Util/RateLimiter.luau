--!strict

local RateLimiter = {}
RateLimiter.__index = RateLimiter

export type RateLimiter = typeof(setmetatable({} :: {
	_rates: { [Player]: { [string]: { tokens: number, lastCheck: number } } },
	_maxTokens: number,
	_refillRate: number,
}, RateLimiter))

function RateLimiter.new(maxTokens: number, refillRatePerSec: number): RateLimiter
	local self = setmetatable({
		_rates = {},
		_maxTokens = maxTokens,
		_refillRate = refillRatePerSec,
	}, RateLimiter)
	return self
end

function RateLimiter.Check(self: RateLimiter, player: Player, action: string): boolean
	local now = os.clock()
	local playerBuckets = self._rates[player]
	if not playerBuckets then
		playerBuckets = {}
		self._rates[player] = playerBuckets
	end

	local bucket = playerBuckets[action]
	if not bucket then
		bucket = { tokens = self._maxTokens - 1, lastCheck = now }
		playerBuckets[action] = bucket
		return true
	end

	local elapsed = now - bucket.lastCheck
	bucket.tokens = math.min(self._maxTokens, bucket.tokens + elapsed * self._refillRate)
	bucket.lastCheck = now

	if bucket.tokens >= 1 then
		bucket.tokens -= 1
		return true
	end

	return false
end

function RateLimiter.CleanupPlayer(self: RateLimiter, player: Player)
	self._rates[player] = nil
end

return RateLimiter

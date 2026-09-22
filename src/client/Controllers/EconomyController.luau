--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local NetworkService = require(ReplicatedStorage.Network.NetworkService)

local EconomyController = {}

local player = Players.LocalPlayer
local displayBalance: number = 0
local targetBalance: number = 0

local balanceLabel: TextLabel? = nil
local hudFrame: Frame? = nil

local function formatNumber(value: number): string
	local formatted = tostring(math.floor(value))
	while true do
		local count: number
		formatted, count = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
		if count == 0 then break end
	end
	return formatted
end

local function createHUD(): (Frame, TextLabel)
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

	local screenGui = playerGui:FindFirstChild("MainHUD") :: ScreenGui?
	if not screenGui then
		screenGui = Instance.new("ScreenGui")
		screenGui.Name = "MainHUD"
		screenGui.ResetOnSpawn = false
		screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		screenGui.Parent = playerGui
	end

	local moneyFrame = Instance.new("Frame")
	moneyFrame.Name = "MoneyFrame"
	moneyFrame.Size = UDim2.new(0, 180, 0, 48)
	moneyFrame.Position = UDim2.new(0, 20, 0, 20)
	moneyFrame.BackgroundColor3 = Color3.fromRGB(20, 25, 35)
	moneyFrame.BackgroundTransparency = 0.15
	moneyFrame.BorderSizePixel = 0
	moneyFrame.Parent = screenGui

	local uiCorner = Instance.new("UICorner")
	uiCorner.CornerRadius = UDim.new(0, 12)
	uiCorner.Parent = moneyFrame

	local uiStroke = Instance.new("UIStroke")
	uiStroke.Color = Color3.fromRGB(0, 220, 100)
	uiStroke.Thickness = 2
	uiStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	uiStroke.Parent = moneyFrame

	local iconLabel = Instance.new("TextLabel")
	iconLabel.Name = "Icon"
	iconLabel.Size = UDim2.new(0, 40, 1, 0)
	iconLabel.Position = UDim2.new(0, 8, 0, 0)
	iconLabel.BackgroundTransparency = 1
	iconLabel.Text = "$"
	iconLabel.TextColor3 = Color3.fromRGB(0, 230, 110)
	iconLabel.TextSize = 28
	iconLabel.Font = Enum.Font.FredokaOne
	iconLabel.Parent = moneyFrame

	local amountLabel = Instance.new("TextLabel")
	amountLabel.Name = "AmountLabel"
	amountLabel.Size = UDim2.new(1, -52, 1, 0)
	amountLabel.Position = UDim2.new(0, 44, 0, 0)
	amountLabel.BackgroundTransparency = 1
	amountLabel.Text = "$0"
	amountLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	amountLabel.TextSize = 22
	amountLabel.Font = Enum.Font.FredokaOne
	amountLabel.TextXAlignment = Enum.TextXAlignment.Left
	amountLabel.Parent = moneyFrame

	return moneyFrame, amountLabel
end

local function showDeltaEffect(parentFrame: Frame, delta: number)
	if delta == 0 then return end

	local deltaLabel = Instance.new("TextLabel")
	deltaLabel.Size = UDim2.new(0, 100, 0, 30)
	deltaLabel.Position = UDim2.new(1, 10, 0, 8)
	deltaLabel.BackgroundTransparency = 1
	deltaLabel.Font = Enum.Font.FredokaOne
	deltaLabel.TextSize = 20

	if delta > 0 then
		deltaLabel.Text = string.format("+$%s", formatNumber(delta))
		deltaLabel.TextColor3 = Color3.fromRGB(0, 255, 120)
	else
		deltaLabel.Text = string.format("-$%s", formatNumber(math.abs(delta)))
		deltaLabel.TextColor3 = Color3.fromRGB(255, 80, 80)
	end

	deltaLabel.Parent = parentFrame

	local tweenInfo = TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local moveTween = TweenService:Create(deltaLabel, tweenInfo, {
		Position = deltaLabel.Position + UDim2.new(0, 0, 0, -25),
		TextTransparency = 1,
	})

	moveTween:Play()
	moveTween.Completed:Connect(function()
		deltaLabel:Destroy()
	end)
end

function EconomyController.Init()
	local frame, label = createHUD()
	hudFrame = frame
	balanceLabel = label

	task.spawn(function()
		local leaderstats = player:WaitForChild("leaderstats", 5) :: Folder?
		if leaderstats then
			local moneyVal = leaderstats:WaitForChild("Money", 5) :: IntValue?
			if moneyVal then
				targetBalance = moneyVal.Value
				displayBalance = moneyVal.Value
				if balanceLabel then
					balanceLabel.Text = "$" .. formatNumber(displayBalance)
				end
			end
		end
	end)

	RunService.RenderStepped:Connect(function(dt)
		if math.abs(targetBalance - displayBalance) > 0.1 then
			displayBalance = displayBalance + (targetBalance - displayBalance) * math.min(dt * 12, 1)
			if balanceLabel then
				balanceLabel.Text = "$" .. formatNumber(math.round(displayBalance))
			end
		else
			displayBalance = targetBalance
			if balanceLabel then
				balanceLabel.Text = "$" .. formatNumber(targetBalance)
			end
		end
	end)

	local balanceEvent = NetworkService.GetEvent("BalanceUpdated")
	if balanceEvent then
		balanceEvent.OnClientEvent:Connect(function(payload: any, legacyDelta: number?)
			local newBalance: number
			local delta: number = 0

			if typeof(payload) == "buffer" then
				newBalance = buffer.readf64(payload, 0)
				delta = buffer.readf64(payload, 8)
			elseif typeof(payload) == "number" then
				newBalance = payload
				delta = legacyDelta or 0
			else
				return
			end

			targetBalance = newBalance
			if hudFrame and delta ~= 0 then
				showDeltaEffect(hudFrame, delta)
			end
		end)
	end
end

return EconomyController

--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local NetworkService = require(ReplicatedStorage.Network.NetworkService)
local PlotController = require(StarterPlayer.StarterPlayerScripts.Client.Controllers.PlotController)
local EconomyController = require(StarterPlayer.StarterPlayerScripts.Client.Controllers.EconomyController)
local NPCController = require(StarterPlayer.StarterPlayerScripts.Client.Controllers.NPCController)
local UIFactory = require(StarterPlayer.StarterPlayerScripts.Client.UI.UIFactory)

NetworkService.Init()
PlotController.Init()
EconomyController.Init()
NPCController.Init()

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

local screenGui = UIFactory.Create("ScreenGui", {
	Name = "TycoonHUD",
	ResetOnSpawn = false,
	Parent = playerGui,
})

local stoveButton = UIFactory.CreateButton("Place Stove", UDim2.new(0.02, 0, 0.80, 0), UDim2.new(0, 140, 0, 40), function()
	PlotController.StartPlacement("stove")
end)
stoveButton.Parent = screenGui

local registerButton = UIFactory.CreateButton("Place Register", UDim2.new(0.02, 0, 0.87, 0), UDim2.new(0, 140, 0, 40), function()
	PlotController.StartPlacement("cash_register")
end)
registerButton.Parent = screenGui

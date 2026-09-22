--!strict

local UIFactory = {}

type PropertyTable = { [string]: any }
type ChildrenTable = { Instance }

function UIFactory.Create<T>(className: string, properties: PropertyTable?, children: ChildrenTable?): T
	local instance = Instance.new(className)

	if properties then
		for prop, value in properties do
			(instance :: any)[prop] = value
		end
	end

	if children then
		for _, child in children do
			child.Parent = instance
		end
	end

	return instance :: any
end

function UIFactory.CreateButton(text: string, position: UDim2, size: UDim2, onClick: () -> ()): TextButton
	local button = UIFactory.Create("TextButton", {
		Text = text,
		Position = position,
		Size = size,
		BackgroundColor3 = Color3.fromRGB(45, 45, 50),
		TextColor3 = Color3.fromRGB(255, 255, 255),
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		BorderSizePixel = 0,
	}, {
		UIFactory.Create("UICorner", { CornerRadius = UDim.new(0, 8) }),
	}) :: TextButton

	button.MouseButton1Click:Connect(onClick)
	return button
end

return UIFactory

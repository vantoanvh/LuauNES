# LuauNES
**NES** emulator ported to roblox luau inspired/based on **[LuaNES](https://github.com/nico-abram/LuaNES)** by the original creator **[nico-abram](https://github.com/nico-abram)**<br><br>
This is very performant and able to run **Kirby Adventure** with ~120 FPS ( 13th Gen Intel® Core™ i7-13620H )<br>
also **Donkey Kong Classics** with ~180 FPS.
<br><br>
But for low/mid-end devices, it gonna explodes. ( 20 FPS )
<br>
Supports 2 player mode, sounds, PPU dot-based and, cycle-accurate CPU.

Moreover, you should upload your audio files as your own ( I cannot distrub the sounds because I am unverified )<br>
The audio files you can download in the [Sounds](https://github.com/vantoanvh/LuauNES/tree/main/Sounds) folder<br>

> <h3>Disclamer</h3> Your device should have native code generation to make this run effectively.<br>This used <strong>EditableImage</strong> so you need ID Verification for this.

This emulator currently supports 16 mappers:

- `Mapper 0` **NROM**
- `Mapper 1` **MMC1**
- `Mapper 2` **UNROM**
- `Mapper 3` **CNROM**
- `Mapper 4` **MMC3**
- `Mapper 5` **MMC5**
- `Mapper 7` **AOROM**
- `Mapper 9` **MMC2**
- `Mapper 10` **MMC4**
- `Mapper 11` **Color Dreams**
- `Mapper 30` UNROM512,
- `Mapper 66` **GxROM**
- `Mapper 69` = **FME7** *(untested)*
- `Mapper 71` = **Camerica** *(untested)*
- `Mapper 79` = **NINA03_06** *(untested)*
- `Mapper 206` = **DxROM** *(untested)*

## Code usage

You can download the **ROMs** in the internet and convert it into **rbxmx** using [my website](https://vantoanvh.github.io/LuauNES/)!
or testing pregenerated roms in [test](https://github.com/vantoanvh/LuauNES/tree/main/test)

```luau
--!native
--!optimize 2
--!strict

local UserInputService = game:GetService'UserInputService'
local AssetService = game:GetService'AssetService'
local RunService = game:GetService'RunService'

local LuauNES = require'@self/LuauNES'

local Display = script.Parent.Display

local Screen = AssetService:CreateEditableImage{ Size = LuauNES.size }
Display.ImageContent = Content.fromObject(Screen)

local WritePixels = Screen.WritePixelsBuffer

-- Load the ROM!
LuauNES.load(require'@game/ReplicatedStorage/Roms/KongClassic')

-- Key mapping for player 1
local keyMapP1 = {
	[Enum.KeyCode.X] = LuauNES.Buttons.A,
	[Enum.KeyCode.Z] = LuauNES.Buttons.B,

	[Enum.KeyCode.LeftShift] = LuauNES.Buttons.Select,
	[Enum.KeyCode.Return] = LuauNES.Buttons.Start,

	[Enum.KeyCode.Up] = LuauNES.Buttons.Up,
	[Enum.KeyCode.Down] = LuauNES.Buttons.Down,
	[Enum.KeyCode.Left] = LuauNES.Buttons.Left,
	[Enum.KeyCode.Right] = LuauNES.Buttons.Right,
}

-- Key mapping for player 2
local keyMapP2 = {
	[Enum.KeyCode.Q] = LuauNES.Buttons.A,
	[Enum.KeyCode.E] = LuauNES.Buttons.B,

	[Enum.KeyCode.RightShift] = LuauNES.Buttons.Select,
	[Enum.KeyCode.RightControl] = LuauNES.Buttons.Start,

	[Enum.KeyCode.W] = LuauNES.Buttons.Up,
	[Enum.KeyCode.S] = LuauNES.Buttons.Down,
	[Enum.KeyCode.A] = LuauNES.Buttons.Left,
	[Enum.KeyCode.D] = LuauNES.Buttons.Right,
}

-- Fixed emulation
local FIXED_DELTA_TIME = 1 / 60
local accumulator = 0

local function onRendered(dt: number)
	accumulator += dt

	while accumulator >= FIXED_DELTA_TIME do
		local frame = LuauNES.render()
		
		if frame then
			WritePixels(Screen, Vector2.zero, LuauNES.size, frame)
		end
		
		accumulator -= FIXED_DELTA_TIME
	end
end

local function Pressed(input: InputObject)
	local btn = keyMapP1[input.KeyCode]
	if btn then LuauNES.press(btn) end

	local btn = keyMapP2[input.KeyCode]
	if btn then LuauNES.press(btn, 2) end
end

local function Released(input: InputObject)
	local btn = keyMapP1[input.KeyCode]
	if btn then LuauNES.release(btn) end

	local btn = keyMapP2[input.KeyCode]
	if btn then LuauNES.release(btn, 2) end
end

UserInputService.InputBegan:Connect(Pressed)
UserInputService.InputEnded:Connect(Released)

RunService.PostSimulation:Connect(onRendered)
```

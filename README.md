# LuauNES, The fastest and most accurate NES emulator in roblox.

![Ver](https://img.shields.io/badge/version-v1.5.0-blue?style=plastic)
[![License](https://img.shields.io/badge/license-MIT-97ca00?style=plastic)](https://github.com/vantoanvh/LuauParser/blob/main/LICENSE)
[![Release](https://img.shields.io/badge/release-latest-darkblue?style=plastic)](https://github.com/vantoanvh/LuauNES/releases/latest)

**NES** emulator ported to roblox luau inspired/based on **[Mesen2](https://github.com/SourMesen/Mesen2/tree/master)** ( one of the most accurate nes emulators )<br><br>
This is very performant and able to run **Kirby Adventure** with ~150 FPS ( 13th Gen Intel® Core™ i7-13620H )<br>
also **Donkey Kong Classics** with ~220 FPS.
<br><br>
But for low/mid-end devices, it still run pretty smooth. ( ~30-70 FPS )
<br>

Moreover, you should upload your audio files as your own ( I cannot distrub the sounds because I am unverified )<br>
The audio files you can download in the [Sounds](https://github.com/vantoanvh/LuauNES/tree/main/Sounds) folder<br>

> <h3>Disclamer</h3> Your device should have native code generation to make this run effectively.<br>This used <strong>EditableImage</strong> so you need ID Verification for this.

## Features

- **2-player support.**
- **zapper support ( in other word, mouse ).**
- Fully 32 noises sequences ( 16 long noises, 16 short noises ), 4 unique Pulses, 4 MMC5/VRC6 pulses, Traingle, and other more. Make this become the most "sound"-accurate.
- PPU dot-based ( 3 PPU per 1 CPU cycles )
- cycle-accurate CPU.

# Supported Mappers:

### Nintendo

- `0` - NROM
- `1` - MMC1 / SxROM
- `2` - UxROM (UNROM/UOROM)
- `3` - CNROM
- `4` - MMC3 / TxROM
- `5` - MMC5 / ExROM
- `7` - AxROM / AOROM
- `9` - MMC2 / PxROM
- `10` - MMC4 / FxROM
- `13` - CPROM
- `37` - MMC3 multicart variant
- `47` - MMC3 multicart variant
- `66` - GxROM
- `94` - UN1ROM
- `105` - NES-EVENT (MMC1)
- `118` - TxSROM (TKSROM/TLSROM)
- `155` - MMC1A variant
- `180` - UxROM (inverted)
- `185` - CNROM security / CHR-disable variant

### Namco

- `19` - Namco 163 family
- `76` - NAMCOT-3446
- `88` - Namco 108 variant
- `95` - NAMCOT-3425
- `154` - NAMCOT-3453
- `206` - Namco 108 / Namco 118 / MIMIC-1 / DxROM
- `210` - Namco 175 / Namco 340

### Konami

- `21` - VRC2 / VRC4 family
- `22` - VRC2 / VRC4 family
- `23` - VRC2 / VRC4 family
- `24` - VRC6
- `25` - VRC2 / VRC4 family
- `26` - VRC6
- `27` - VRC2 / VRC4 family
- `73` - VRC3
- `75` - VRC1
- `85` - VRC7

### Sunsoft

- `67` - Sunsoft-3
- `68` - Sunsoft-4
- `69` - FME-7
- `89` - Sunsoft-2 on Sunsoft-3 board
- `93` - Sunsoft-2 on Sunsoft-3R board
- `184` - Sunsoft-1

### Homebrew

- `30` - UNROM 512

### Unlicensed

- `11` - Color Dreams
- `71` - Camerica / Codemasters
- `79` - NINA-03 / NINA-06
- `116` - Huang / Gouder SOMARI-P
- `163` - Nanjing FC-001

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
local GuiService = game:GetService'GuiService'

-- Import the LuauNES module.
local LuauNES = require'@game/ReplicatedStorage/Shared/LuauNES'
local Rom = require'@game/ReplicatedStorage/Roms/DonkeyKong' -- Import your rom too

-- UI element that displays the NES output.
local Display = script.Parent.Display

-- Size is defined by the emulator (typically 256x240 for NES).
local Screen = AssetService:CreateEditableImage{ Size = LuauNES.size }
Display.ImageContent = Content.fromObject(Screen)

-- Cache the WritePixelsBuffer function for faster repeated calls.
local WritePixels = Screen.WritePixelsBuffer

-- Load the NES ROM into the emulator.
LuauNES.load(Rom)

-- Key mapping for player 1.
local keyMapP1 = {
	-- Face buttons
	[Enum.KeyCode.X] = LuauNES.Buttons.A,
	[Enum.KeyCode.Z] = LuauNES.Buttons.B,
	
	-- System buttons
	[Enum.KeyCode.LeftShift] = LuauNES.Buttons.Select,
	[Enum.KeyCode.Return] = LuauNES.Buttons.Start,
	
	-- Directional pad
	[Enum.KeyCode.Up] = LuauNES.Buttons.Up,
	[Enum.KeyCode.Down] = LuauNES.Buttons.Down,
	[Enum.KeyCode.Left] = LuauNES.Buttons.Left,
	[Enum.KeyCode.Right] = LuauNES.Buttons.Right,
}

-- Key mapping for player 2.
local keyMapP2 = {
	-- Face buttons
	[Enum.KeyCode.J] = LuauNES.Buttons.A,
	[Enum.KeyCode.K] = LuauNES.Buttons.B,
	
	-- System buttons
	[Enum.KeyCode.RightShift] = LuauNES.Buttons.Select,
	[Enum.KeyCode.RightControl] = LuauNES.Buttons.Start,
	
	-- Directional pad
	[Enum.KeyCode.W] = LuauNES.Buttons.Up,
	[Enum.KeyCode.S] = LuauNES.Buttons.Down,
	[Enum.KeyCode.A] = LuauNES.Buttons.Left,
	[Enum.KeyCode.D] = LuauNES.Buttons.Right,
}

local function updateZapper()
	local pos = UserInputService:GetMouseLocation()
	
	local guiSize = Display.AbsoluteSize
	local guiPos = Display.AbsolutePosition + Vector2.new(0, GuiService.TopbarInset.Height)

	local x = (pos.X - guiPos.X) / guiSize.X * 256
	local y = (pos.Y - guiPos.Y) / guiSize.Y * 240
	
	LuauNES.point(x // 1, y // 1) -- Update zapper position
end

-- Accumulator allows the emulator to step multiple frames if Roblox lags.
local accumulator = 0

-- This is used as the main emulator update loop.
local function onRendered(dt: number)
	-- NES runs at ~60.0988 FPS, so we need to accumulate it.
	accumulator += dt
	
	while accumulator >= 0.01663926733 do
		-- Render a frame from the emulator.
		local frame = LuauNES.render()

		-- If a frame was produced, write it into the EditableImage.
		if frame then
			WritePixels(Screen, Vector2.zero, LuauNES.size, frame)
		end

		-- Remove the processed frame time from the accumulator.
		accumulator -= 0.01663926733
	end
end

-- Handles press events.
local function Pressed(input: InputObject)
	-- Check if the key pressed by player 1
	local btn = keyMapP1[input.KeyCode]
	if btn then LuauNES.press(btn, 1) end

	-- Check if the key pressed by player 2
	local btn = keyMapP2[input.KeyCode]
	if btn then LuauNES.press(btn, 2) end
	
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		LuauNES.trigger() -- Triggered zapper
	end
end

-- Handles release events.
local function Released(input: InputObject)
	-- Check if the key released by player 1
	local btn = keyMapP1[input.KeyCode]
	if btn then LuauNES.release(btn, 1) end
	
	-- Check if the key released by player 2
	local btn = keyMapP2[input.KeyCode]
	if btn then LuauNES.release(btn, 2) end
end

-- Connect events to the handler.
UserInputService.InputBegan:Connect(Pressed)
UserInputService.InputEnded:Connect(Released)

-- PostSimulation runs once per simulation step,
-- so the emulator work is done before PreRender
-- and does not block rendering as much.
-- it's a good pratice to do this way
RunService.PostSimulation:Connect(onRendered)
RunService.PreRender:Connect(updateZapper)
```

--!optimize 2
--!native
--!strict

local Base = require'./Base'

type MapperConfig = Base.MapperConfig

local atLeastOne = Base.atLeastOne
local wrapBank = Base.wrapBank

--// MAPPER_030
local function UNROM512(config: MapperConfig)
	local prg_banks_16k = atLeastOne(config.prgSize // 0x4000)
	local chr_banks_8k = atLeastOne(config.chrSize // 0x2000)
	local four_screen = config.fourScreen
	local submapper = config.submapper or 0
	local hv_switch_mode = (not four_screen) and submapper == 3
	local one_screen_switchable = (not four_screen)
		and (not hv_switch_mode)
		and (config.initialMirroring == 0 or config.initialMirroring == 1)
	local mirroring = if four_screen then 2 else config.initialMirroring

	local prg_bank = 0
	local chr_bank = 0

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return 0
		end

		if addr < 0xC000 then
			return prg_bank * 0x4000 + bit32.band(addr, 0x3FFF)
		end

		return (prg_banks_16k - 1) * 0x4000 + bit32.band(addr, 0x3FFF)
	end

	local function map_chr_addr(addr: number, _fetch_kind: number?, _sprite_16: boolean?): number
		addr = bit32.band(addr, 0x1FFF)
		return chr_bank * 0x2000 + addr
	end

	local function write_cpu(addr: number, value: number)
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return
		end

		prg_bank = wrapBank(bit32.band(value, 0x1F), prg_banks_16k)
		chr_bank = wrapBank(bit32.band(bit32.rshift(value, 5), 0x03), chr_banks_8k)
		if one_screen_switchable then
			mirroring = if bit32.btest(value, 0x80) then 1 else 0
		elseif hv_switch_mode then
			mirroring = if bit32.btest(value, 0x80) then 3 else 2
		end
	end

	local function reset_mapper()
		prg_bank = 0
		chr_bank = 0
		mirroring = if four_screen then 2 else config.initialMirroring
	end

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = write_cpu,
		readCpu = nil,
		readNametable = nil,
		writeNametable = nil,
		mapPrgRamAddr = nil,
		clockCpu = nil,
		clockA12 = nil,
		clockScanline = nil,
		onPpuAddress = nil,
		reset = reset_mapper,
		irqPending = nil,
		clearIrq = function() end,
		getMirroring = function(): number
			return mirroring
		end,
		prgRamReadable = nil,
		prgRamWritable = nil,
	}
end

return  {
	[30] = UNROM512,
}
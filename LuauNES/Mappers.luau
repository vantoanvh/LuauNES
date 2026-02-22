--!optimize 2
--!native
--!strict

--// ARRAYS AND TYPES

local Mirroring = {
	ONE_SCREEN_LOW = 0,
	ONE_SCREEN_HIGH = 1,
	VERTICAL = 2,
	HORIZONTAL = 3,
}

export type MapperConfig = {
	id: number,
	fourScreen: boolean,
	initialMirroring: number,
	prgBanks16: number,
	chrBanks8: number,
	prgSize: number,
	chrSize: number,
	chrIsRam: boolean,
	prgRamSize: number,
	hasBattery: boolean,
	vram: buffer?,
}

export type Mapper = {
	mapPrgAddr: (addr: number) -> number,
	mapChrAddr: (addr: number, fetchKind: number?, sprite16: boolean?) -> number,
	write: (addr: number, value: number) -> (),

	readCpu: ((addr: number) -> number?)?,
	readNametable: ((addr: number) -> number?)?,
	writeNametable: ((addr: number, value: number) -> boolean)?,
	mapPrgRamAddr: ((addr: number) -> number?)?,

	clockA12: ((a12High: boolean) -> ())?,
	clockScanline: ((scanline: number?) -> ())?,
	onPpuAddress: ((addr: number, scanline: number, cycle: number, rendering: boolean) -> ())?,

	reset: () -> (),
	irqPending: () -> boolean,
	clearIrq: () -> (),
	getMirroring: () -> number,
	prgRamReadable: () -> boolean,
	prgRamWritable: () -> boolean,
}

--// BANKING HELPERS
local function atLeastOne(value: number): number
	return if value < 1 then 1 else value
end

local function wrapBank(bank: number, count: number): number
	if count <= 0 then
		return 0
	end

	local wrapped = bank % count
	if wrapped < 0 then
		return wrapped + count
	end

	return wrapped
end

local function normalizeOffset(offset: number, size: number): number
	if size <= 0 then
		return 0
	end

	if bit32.band(size, size - 1) == 0 then
		return bit32.band(offset, size - 1)
	end

	local wrapped = offset % size
	if wrapped < 0 then
		return wrapped + size
	end

	return wrapped
end

--// MAPPER_000
local function NROM(config: MapperConfig): Mapper
	local prg_banks_16k = atLeastOne(config.prgSize // 0x4000)
	local prg_ram_size = config.prgRamSize
	local mirroring = config.initialMirroring

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return 0
		end

		if prg_banks_16k <= 1 then
			return bit32.band(addr - 0x8000, 0x3FFF)
		end

		return bit32.band(addr - 0x8000, 0x7FFF)
	end

	local function map_chr_addr(addr: number, _fetch_kind: number?, _sprite_16: boolean?): number
		return bit32.band(addr, 0x1FFF)
	end

	local function map_prg_ram_addr(addr: number): number?
		if prg_ram_size <= 0 then
			return nil
		end

		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x6000 or addr >= 0x8000 then
			return nil
		end

		return normalizeOffset(addr - 0x6000, prg_ram_size)
	end

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = function(_addr: number, _value: number) end,
		readCpu = nil,
		readNametable = nil,
		writeNametable = nil,
		mapPrgRamAddr = map_prg_ram_addr,
		clockA12 = nil,
		clockScanline = nil,
		onPpuAddress = nil,
		reset = function() end,
		irqPending = function(): boolean
			return false
		end,
		clearIrq = function() end,
		getMirroring = function(): number
			return if config.fourScreen then Mirroring.VERTICAL else mirroring
		end,
		prgRamReadable = function(): boolean
			return prg_ram_size > 0
		end,
		prgRamWritable = function(): boolean
			return prg_ram_size > 0
		end,
	}
end

--// MAPPER_001
local function MMC1(config: MapperConfig): Mapper
	local prg_banks_16k = atLeastOne(config.prgSize // 0x4000)
	local chr_banks_4k = atLeastOne(config.chrSize // 0x1000)
	local chr_banks_8k = atLeastOne(config.chrSize // 0x2000)
	local prg_banks_32k = atLeastOne(prg_banks_16k // 2)

	local prg_ram_size = config.prgRamSize
	local prg_ram_available = prg_ram_size > 0

	local mirroring = config.initialMirroring
	local shift = 0x10
	local control = bit32.bor(0x0C, bit32.band(config.initialMirroring, 0x03))
	local chr0 = 0
	local chr1 = 0
	local prg = 0
	local prg_ram_enabled = prg_ram_available

	local function update_mirroring()
		mirroring = bit32.band(control, 0x03)
	end

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return 0
		end

		local prg_mode = bit32.band(bit32.rshift(control, 2), 0x03)
		local prg_bank = bit32.band(prg, 0x0F)

		if prg_mode == 0 or prg_mode == 1 then
			local bank32 = wrapBank(bit32.rshift(bit32.band(prg_bank, 0x0E), 1), prg_banks_32k)
			return bank32 * 0x8000 + bit32.band(addr - 0x8000, 0x7FFF)
		end

		if prg_mode == 2 then
			if addr < 0xC000 then
				return bit32.band(addr - 0x8000, 0x3FFF)
			end

			local bank = wrapBank(prg_bank, prg_banks_16k)
			return bank * 0x4000 + bit32.band(addr, 0x3FFF)
		end

		if addr < 0xC000 then
			local bank = wrapBank(prg_bank, prg_banks_16k)
			return bank * 0x4000 + bit32.band(addr, 0x3FFF)
		end

		return (prg_banks_16k - 1) * 0x4000 + bit32.band(addr, 0x3FFF)
	end

	local function map_chr_addr(addr: number, _fetch_kind: number?, _sprite_16: boolean?): number
		addr = bit32.band(addr, 0x1FFF)
		local chr_mode = bit32.band(bit32.rshift(control, 4), 0x01)

		if chr_mode == 0 then
			local bank8 = wrapBank(bit32.rshift(bit32.band(chr0, 0x1E), 1), chr_banks_8k)
			return bank8 * 0x2000 + addr
		end

		if addr < 0x1000 then
			local bank4 = wrapBank(chr0, chr_banks_4k)
			return bank4 * 0x1000 + bit32.band(addr, 0x0FFF)
		end

		local bank4 = wrapBank(chr1, chr_banks_4k)
		return bank4 * 0x1000 + bit32.band(addr, 0x0FFF)
	end

	local function write_cpu(addr: number, value: number)
		addr = bit32.band(addr, 0xFFFF)
		value = bit32.band(value, 0xFF)
		if addr < 0x8000 then
			return
		end

		if bit32.btest(value, 0x80) then
			shift = 0x10
			control = bit32.bor(control, 0x0C)
			update_mirroring()
			return
		end

		local complete = bit32.band(shift, 0x01) ~= 0
		shift = bit32.rshift(shift, 1)
		shift = bit32.bor(shift, bit32.lshift(bit32.band(value, 0x01), 4))

		if not complete then
			return
		end

		local reg = bit32.band(bit32.rshift(addr, 13), 0x03)
		local data = bit32.band(shift, 0x1F)

		if reg == 0 then
			control = data
			update_mirroring()
		elseif reg == 1 then
			chr0 = data
		elseif reg == 2 then
			chr1 = data
		else
			prg = bit32.band(data, 0x0F)
			prg_ram_enabled = prg_ram_available and not bit32.btest(data, 0x10)
		end

		shift = 0x10
	end

	local function map_prg_ram_addr(addr: number): number?
		if not prg_ram_available then
			return nil
		end

		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x6000 or addr >= 0x8000 then
			return nil
		end

		return normalizeOffset(addr - 0x6000, prg_ram_size)
	end

	local function reset_mapper()
		mirroring = config.initialMirroring
		shift = 0x10
		control = bit32.bor(0x0C, bit32.band(config.initialMirroring, 0x03))
		chr0 = 0
		chr1 = 0
		prg = 0
		prg_ram_enabled = prg_ram_available
		update_mirroring()
	end

	reset_mapper()

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = write_cpu,
		readCpu = nil,
		readNametable = nil,
		writeNametable = nil,
		mapPrgRamAddr = map_prg_ram_addr,
		clockA12 = nil,
		clockScanline = nil,
		onPpuAddress = nil,
		reset = reset_mapper,
		irqPending = function(): boolean
			return false
		end,
		clearIrq = function() end,
		getMirroring = function(): number
			return mirroring
		end,
		prgRamReadable = function(): boolean
			return prg_ram_enabled
		end,
		prgRamWritable = function(): boolean
			return prg_ram_enabled
		end,
	}
end

--// MAPPER_002
local function UNROM(config: MapperConfig): Mapper
	local prg_banks_16k = atLeastOne(config.prgSize // 0x4000)
	local mirroring = config.initialMirroring
	local bank_select = 0

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return 0
		end

		if addr < 0xC000 then
			return bank_select * 0x4000 + bit32.band(addr, 0x3FFF)
		end

		return (prg_banks_16k - 1) * 0x4000 + bit32.band(addr, 0x3FFF)
	end

	local function map_chr_addr(addr: number, _fetch_kind: number?, _sprite_16: boolean?): number
		return bit32.band(addr, 0x1FFF)
	end

	local function write_cpu(addr: number, value: number)
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return
		end

		bank_select = wrapBank(bit32.band(value, 0xFF), prg_banks_16k)
	end

	local function reset_mapper()
		bank_select = 0
	end

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = write_cpu,
		readCpu = nil,
		readNametable = nil,
		writeNametable = nil,
		mapPrgRamAddr = nil,
		clockA12 = nil,
		clockScanline = nil,
		onPpuAddress = nil,
		reset = reset_mapper,
		irqPending = function(): boolean
			return false
		end,
		clearIrq = function() end,
		getMirroring = function(): number
			return mirroring
		end,
		prgRamReadable = function(): boolean
			return false
		end,
		prgRamWritable = function(): boolean
			return false
		end,
	}
end

--// MAPPER_003
local function CNROM(config: MapperConfig): Mapper
	local prg_banks_16k = atLeastOne(config.prgSize // 0x4000)
	local chr_banks_8k = atLeastOne(config.chrSize // 0x2000)
	local mirroring = config.initialMirroring
	local chr_bank = 0

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return 0
		end

		if prg_banks_16k <= 1 then
			return bit32.band(addr - 0x8000, 0x3FFF)
		end

		return bit32.band(addr - 0x8000, 0x7FFF)
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

		chr_bank = wrapBank(bit32.band(value, 0xFF), chr_banks_8k)
	end

	local function reset_mapper()
		chr_bank = 0
	end

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = write_cpu,
		readCpu = nil,
		readNametable = nil,
		writeNametable = nil,
		mapPrgRamAddr = nil,
		clockA12 = nil,
		clockScanline = nil,
		onPpuAddress = nil,
		reset = reset_mapper,
		irqPending = function(): boolean
			return false
		end,
		clearIrq = function() end,
		getMirroring = function(): number
			return mirroring
		end,
		prgRamReadable = function(): boolean
			return false
		end,
		prgRamWritable = function(): boolean
			return false
		end,
	}
end

--// MAPPER_004
local function MMC3(config: MapperConfig): Mapper
	local prg_total_8k = atLeastOne(config.prgSize // 0x2000)
	local chr_total_1k = atLeastOne(config.chrSize // 0x0400)
	local prg_ram_size = config.prgRamSize
	local prg_ram_available = prg_ram_size > 0

	local four_screen = config.fourScreen
	local mirroring = config.initialMirroring

	local regs = table.create(8, 0)
	local bank_select = 0
	local prg_mode = 0
	local chr_mode = 0

	local prg_slots = table.create(4, 0)
	local chr_slots = table.create(8, 0)

	local irq_latch = 0
	local irq_counter = 0
	local irq_reload = false
	local irq_enabled = false
	local irq_pending = false

	local a12_prev = false
	local a12_low_cycles = 8

	local prg_ram_enabled = prg_ram_available
	local prg_ram_write_protect = true

	local function recalc_prg_slots()
		local last_bank = prg_total_8k - 1
		local second_last = math.max(last_bank - 1, 0)
		local r6 = wrapBank(regs[7], prg_total_8k)
		local r7 = wrapBank(regs[8], prg_total_8k)

		if prg_mode == 0 then
			prg_slots[1] = r6
			prg_slots[2] = r7
			prg_slots[3] = second_last
			prg_slots[4] = last_bank
		else
			prg_slots[1] = second_last
			prg_slots[2] = r7
			prg_slots[3] = r6
			prg_slots[4] = last_bank
		end
	end

	local function recalc_chr_slots()
		local r0 = regs[1]
		local r1 = regs[2]
		local r2 = regs[3]
		local r3 = regs[4]
		local r4 = regs[5]
		local r5 = regs[6]

		if chr_mode == 0 then
			chr_slots[1] = wrapBank(bit32.band(r0, 0xFE), chr_total_1k)
			chr_slots[2] = wrapBank(bit32.band(r0, 0xFE) + 1, chr_total_1k)
			chr_slots[3] = wrapBank(bit32.band(r1, 0xFE), chr_total_1k)
			chr_slots[4] = wrapBank(bit32.band(r1, 0xFE) + 1, chr_total_1k)
			chr_slots[5] = wrapBank(r2, chr_total_1k)
			chr_slots[6] = wrapBank(r3, chr_total_1k)
			chr_slots[7] = wrapBank(r4, chr_total_1k)
			chr_slots[8] = wrapBank(r5, chr_total_1k)
		else
			chr_slots[1] = wrapBank(r2, chr_total_1k)
			chr_slots[2] = wrapBank(r3, chr_total_1k)
			chr_slots[3] = wrapBank(r4, chr_total_1k)
			chr_slots[4] = wrapBank(r5, chr_total_1k)
			chr_slots[5] = wrapBank(bit32.band(r0, 0xFE), chr_total_1k)
			chr_slots[6] = wrapBank(bit32.band(r0, 0xFE) + 1, chr_total_1k)
			chr_slots[7] = wrapBank(bit32.band(r1, 0xFE), chr_total_1k)
			chr_slots[8] = wrapBank(bit32.band(r1, 0xFE) + 1, chr_total_1k)
		end
	end

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return 0
		end

		local slot = bit32.rshift(addr - 0x8000, 13)
		local bank = prg_slots[slot + 1]
		return bank * 0x2000 + bit32.band(addr, 0x1FFF)
	end

	local function map_chr_addr(addr: number, _fetch_kind: number?, _sprite_16: boolean?): number
		addr = bit32.band(addr, 0x1FFF)
		local segment = bit32.rshift(addr, 10)
		local bank = chr_slots[segment + 1]
		return bank * 0x0400 + bit32.band(addr, 0x03FF)
	end

	local function write_cpu(addr: number, value: number)
		addr = bit32.band(addr, 0xFFFF)
		value = bit32.band(value, 0xFF)
		if addr < 0x8000 then
			return
		end

		local even = bit32.band(addr, 1) == 0

		if addr < 0xA000 then
			if even then
				bank_select = bit32.band(value, 0x07)
				prg_mode = bit32.band(bit32.rshift(value, 6), 0x01)
				chr_mode = bit32.band(bit32.rshift(value, 7), 0x01)
				recalc_prg_slots()
				recalc_chr_slots()
			else
				regs[bank_select + 1] = value
				if bank_select <= 5 then
					recalc_chr_slots()
				else
					recalc_prg_slots()
				end
			end
			return
		end

		if addr < 0xC000 then
			if even and not four_screen then
				mirroring = if bit32.band(value, 0x01) == 0 then Mirroring.VERTICAL else Mirroring.HORIZONTAL
			elseif not even then
				prg_ram_enabled = prg_ram_available and bit32.btest(value, 0x80)
				prg_ram_write_protect = bit32.btest(value, 0x40)
			end
			return
		end

		if addr < 0xE000 then
			if even then
				irq_latch = value
			else
				irq_reload = true
			end
			return
		end

		if even then
			irq_enabled = false
			irq_pending = false
		else
			irq_enabled = true
		end
	end

	local function map_prg_ram_addr(addr: number): number?
		if not prg_ram_available then
			return nil
		end

		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x6000 or addr >= 0x8000 then
			return nil
		end

		return normalizeOffset(addr - 0x6000, prg_ram_size)
	end

	local function clock_irq_counter()
		if irq_counter == 0 or irq_reload then
			irq_counter = irq_latch
			irq_reload = false
		else
			irq_counter = bit32.band(irq_counter - 1, 0xFF)
		end

		if irq_counter == 0 and irq_enabled then
			irq_pending = true
		end
	end

	local function clock_a12(a12_high: boolean)
		if not a12_high then
			a12_prev = false
			a12_low_cycles = math.min(a12_low_cycles + 1, 0x7FFFFFFF)
			return
		end

		if (not a12_prev) and a12_low_cycles >= 8 then
			clock_irq_counter()
		end

		a12_prev = true
		a12_low_cycles = 0
	end

	local function reset_mapper()
		mirroring = config.initialMirroring

		for i = 1, 8 do
			regs[i] = 0
		end

		bank_select = 0
		prg_mode = 0
		chr_mode = 0
		recalc_prg_slots()
		recalc_chr_slots()

		irq_latch = 0
		irq_counter = 0
		irq_reload = false
		irq_enabled = false
		irq_pending = false

		a12_prev = false
		a12_low_cycles = 8

		prg_ram_enabled = prg_ram_available
		prg_ram_write_protect = true
	end

	reset_mapper()

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = write_cpu,
		readCpu = nil,
		readNametable = nil,
		writeNametable = nil,
		mapPrgRamAddr = map_prg_ram_addr,
		clockA12 = clock_a12,
		clockScanline = nil,
		onPpuAddress = nil,
		reset = reset_mapper,
		irqPending = function(): boolean
			return irq_pending
		end,
		clearIrq = function()
			irq_pending = false
		end,
		getMirroring = function(): number
			return mirroring
		end,
		prgRamReadable = function(): boolean
			return prg_ram_enabled
		end,
		prgRamWritable = function(): boolean
			return prg_ram_enabled and (not prg_ram_write_protect)
		end,
	}
end

--// MAPPER_005
local function MMC5(config: MapperConfig): Mapper
	local four_screen = config.fourScreen
	local vram_buf = config.vram

	local prg_total_8k = atLeastOne(config.prgSize // 0x2000)
	local prg_total_16k = atLeastOne(prg_total_8k // 2)
	local prg_total_32k = atLeastOne(prg_total_8k // 4)
	local chr_total_1k = atLeastOne(config.chrSize // 0x0400)

	local prg_ram_size = config.prgRamSize
	local prg_ram_available = prg_ram_size > 0
	local prg_ram_total_8k = atLeastOne(prg_ram_size // 0x2000)
	local prg_ram_total_16k = atLeastOne(prg_ram_size // 0x4000)

	local mirroring = config.initialMirroring

	local mmc5_prg_mode = 3
	local mmc5_chr_mode = 3
	local mmc5_prg_regs = table.create(4, 0)
	local mmc5_chr_regs = table.create(12, 0)
	local mmc5_chr_high = 0
	local mmc5_last_chr_set = 0

	local mmc5_exram_mode = 0
	local mmc5_nt_map = table.create(4, 0)
	local mmc5_exram = buffer.create(0x400)
	local mmc5_fill_tile = 0
	local mmc5_fill_attr = 0

	local mmc5_ram_protect_0 = 0
	local mmc5_ram_protect_1 = 0
	local mmc5_prg_ram_bank = 0

	local mmc5_mul_a = 0
	local mmc5_mul_b = 0

	local _mmc5_split_control = 0
	local _mmc5_split_scroll = 0
	local _mmc5_split_bank = 0

	local mmc5_irq_line = 0
	local mmc5_irq_enabled = false
	local mmc5_irq_pending = false
	local mmc5_scanline = -1
	local mmc5_in_frame = false

	local function mmc5_prg_reg_value(reg_index: number): number
		return mmc5_prg_regs[reg_index + 1]
	end

	local function mmc5_prg_bank_8k(reg_index: number): number
		return wrapBank(bit32.band(mmc5_prg_reg_value(reg_index), 0x7F), prg_total_8k)
	end

	local function mmc5_prg_reg_maps_ram(reg_index: number): boolean
		if reg_index >= 3 then
			return false
		end

		return not bit32.btest(mmc5_prg_reg_value(reg_index), 0x80)
	end

	local function mmc5_chr_reg_value(reg_index: number): number
		return mmc5_chr_regs[reg_index + 1]
	end

	local function mmc5_set_chr_reg(reg_index: number, value: number)
		mmc5_chr_regs[reg_index + 1] = bit32.bor(bit32.band(value, 0xFF), bit32.lshift(mmc5_chr_high, 8))
	end

	local function mmc5_chr_bank_from_set_a(mode: number, segment: number): number
		if mode == 0 then
			return mmc5_chr_reg_value(7) * 8 + segment
		end

		if mode == 1 then
			local reg = if segment < 4 then 3 else 7
			return mmc5_chr_reg_value(reg) * 4 + bit32.band(segment, 0x03)
		end

		if mode == 2 then
			local reg = bit32.bor(bit32.band(segment, 0x06), 0x01)
			return mmc5_chr_reg_value(reg) * 2 + bit32.band(segment, 0x01)
		end

		return mmc5_chr_reg_value(segment)
	end

	local function mmc5_chr_bank_from_set_b(mode: number, segment: number): number
		if mode == 0 then
			return mmc5_chr_reg_value(11) * 8 + segment
		end

		if mode == 1 then
			return mmc5_chr_reg_value(11) * 4 + bit32.band(segment, 0x03)
		end

		if mode == 2 then
			local reg = if bit32.btest(segment, 0x02) then 11 else 9
			return mmc5_chr_reg_value(reg) * 2 + bit32.band(segment, 0x01)
		end

		local reg = 8 + bit32.band(segment, 0x03)
		return mmc5_chr_reg_value(reg)
	end

	local function mmc5_prg_ram_offset(addr: number): number?
		if not prg_ram_available then
			return nil
		end

		if addr >= 0x6000 and addr < 0x8000 then
			local bank8 = wrapBank(mmc5_prg_ram_bank, prg_ram_total_8k)
			return bank8 * 0x2000 + bit32.band(addr - 0x6000, 0x1FFF)
		end

		if addr < 0x8000 or addr >= 0xE000 then
			return nil
		end

		if mmc5_prg_mode == 0 then
			return nil
		end

		if mmc5_prg_mode == 1 then
			if addr >= 0xC000 then
				return nil
			end

			if mmc5_prg_reg_maps_ram(1) then
				local reg = mmc5_prg_reg_value(1)
				local bank16 = wrapBank(bit32.rshift(bit32.band(reg, 0x7F), 1), prg_ram_total_16k)
				return bank16 * 0x4000 + bit32.band(addr - 0x8000, 0x3FFF)
			end

			return nil
		end

		if mmc5_prg_mode == 2 then
			if addr < 0xC000 then
				if mmc5_prg_reg_maps_ram(1) then
					local reg = mmc5_prg_reg_value(1)
					local bank16 = wrapBank(bit32.rshift(bit32.band(reg, 0x7F), 1), prg_ram_total_16k)
					return bank16 * 0x4000 + bit32.band(addr - 0x8000, 0x3FFF)
				end

				return nil
			end

			if mmc5_prg_reg_maps_ram(2) then
				local reg = mmc5_prg_reg_value(2)
				local bank8 = wrapBank(bit32.band(reg, 0x7F), prg_ram_total_8k)
				return bank8 * 0x2000 + bit32.band(addr - 0xC000, 0x1FFF)
			end

			return nil
		end

		local slot = bit32.rshift(addr - 0x8000, 13)
		if slot >= 3 or not mmc5_prg_reg_maps_ram(slot) then
			return nil
		end

		local reg = mmc5_prg_reg_value(slot)
		local bank8 = wrapBank(bit32.band(reg, 0x7F), prg_ram_total_8k)
		return bank8 * 0x2000 + bit32.band(addr, 0x1FFF)
	end

	local function update_mmc5_simple_mirroring()
		if four_screen then
			return
		end

		local n0 = mmc5_nt_map[1]
		local n1 = mmc5_nt_map[2]
		local n2 = mmc5_nt_map[3]
		local n3 = mmc5_nt_map[4]

		if n0 == n1 and n2 == n3 and n0 ~= n2 then
			mirroring = Mirroring.HORIZONTAL
		elseif n0 == n2 and n1 == n3 and n0 ~= n1 then
			mirroring = Mirroring.VERTICAL
		elseif n0 == n1 and n1 == n2 and n2 == n3 then
			mirroring = if n0 == 1 then Mirroring.ONE_SCREEN_HIGH else Mirroring.ONE_SCREEN_LOW
		end
	end

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return 0
		end

		if mmc5_prg_mode == 0 then
			local bank32 = wrapBank(bit32.rshift(mmc5_prg_bank_8k(3), 2), prg_total_32k)
			return bank32 * 0x8000 + bit32.band(addr - 0x8000, 0x7FFF)
		end

		if mmc5_prg_mode == 1 then
			if addr < 0xC000 then
				local bank16 = wrapBank(bit32.rshift(mmc5_prg_bank_8k(1), 1), prg_total_16k)
				return bank16 * 0x4000 + bit32.band(addr - 0x8000, 0x3FFF)
			end

			local bank16 = wrapBank(bit32.rshift(mmc5_prg_bank_8k(3), 1), prg_total_16k)
			return bank16 * 0x4000 + bit32.band(addr, 0x3FFF)
		end

		if mmc5_prg_mode == 2 then
			if addr < 0xC000 then
				local bank16 = wrapBank(bit32.rshift(mmc5_prg_bank_8k(1), 1), prg_total_16k)
				return bank16 * 0x4000 + bit32.band(addr - 0x8000, 0x3FFF)
			end

			if addr < 0xE000 then
				return mmc5_prg_bank_8k(2) * 0x2000 + bit32.band(addr, 0x1FFF)
			end

			return mmc5_prg_bank_8k(3) * 0x2000 + bit32.band(addr, 0x1FFF)
		end

		local slot = bit32.rshift(addr - 0x8000, 13)
		return mmc5_prg_bank_8k(slot) * 0x2000 + bit32.band(addr, 0x1FFF)
	end

	local function map_chr_addr(addr: number, fetch_kind: number?, sprite_16: boolean?): number
		addr = bit32.band(addr, 0x1FFF)
		local segment = bit32.rshift(addr, 10)
		local inner = bit32.band(addr, 0x03FF)
		local kind = fetch_kind or 0
		local use_set_b = false

		if sprite_16 == true then
			if kind == 1 then
				use_set_b = true
			elseif kind == 0 then
				use_set_b = mmc5_last_chr_set == 1
			end
		end

		local bank_1k = if use_set_b
			then mmc5_chr_bank_from_set_b(mmc5_chr_mode, segment)
			else mmc5_chr_bank_from_set_a(mmc5_chr_mode, segment)

		bank_1k = wrapBank(bank_1k, chr_total_1k)
		return bank_1k * 0x0400 + inner
	end

	local function write_cpu(addr: number, value: number)
		addr = bit32.band(addr, 0xFFFF)
		value = bit32.band(value, 0xFF)

		if addr >= 0x5C00 and addr <= 0x5FFF then
			buffer.writeu8(mmc5_exram, bit32.band(addr - 0x5C00, 0x03FF), value)
			return
		end

		if addr == 0x5100 then
			mmc5_prg_mode = bit32.band(value, 0x03)
			return
		end
		if addr == 0x5101 then
			mmc5_chr_mode = bit32.band(value, 0x03)
			return
		end
		if addr == 0x5102 then
			mmc5_ram_protect_0 = bit32.band(value, 0x03)
			return
		end
		if addr == 0x5103 then
			mmc5_ram_protect_1 = bit32.band(value, 0x03)
			return
		end
		if addr == 0x5104 then
			mmc5_exram_mode = bit32.band(value, 0x03)
			return
		end
		if addr == 0x5105 then
			for i = 0, 3 do
				mmc5_nt_map[i + 1] = bit32.band(bit32.rshift(value, i * 2), 0x03)
			end
			update_mmc5_simple_mirroring()
			return
		end
		if addr == 0x5106 then
			mmc5_fill_tile = value
			return
		end
		if addr == 0x5107 then
			mmc5_fill_attr = bit32.band(value, 0x03)
			return
		end
		if addr == 0x5113 then
			mmc5_prg_ram_bank = bit32.band(value, 0x07)
			return
		end
		if addr >= 0x5114 and addr <= 0x5117 then
			mmc5_prg_regs[addr - 0x5114 + 1] = value
			return
		end
		if addr >= 0x5120 and addr <= 0x5127 then
			mmc5_set_chr_reg(addr - 0x5120, value)
			mmc5_last_chr_set = 0
			return
		end
		if addr >= 0x5128 and addr <= 0x512B then
			local idx = addr - 0x5128
			mmc5_set_chr_reg(8 + idx, value)
			mmc5_last_chr_set = 1
			return
		end
		if addr == 0x5130 then
			mmc5_chr_high = bit32.band(value, 0x03)
			return
		end
		if addr == 0x5200 then
			_mmc5_split_control = value
			return
		end
		if addr == 0x5201 then
			_mmc5_split_scroll = value
			return
		end
		if addr == 0x5202 then
			_mmc5_split_bank = value
			return
		end
		if addr == 0x5203 then
			mmc5_irq_line = value
			return
		end
		if addr == 0x5204 then
			mmc5_irq_enabled = bit32.btest(value, 0x80)
			return
		end
		if addr == 0x5205 then
			mmc5_mul_a = value
			return
		end
		if addr == 0x5206 then
			mmc5_mul_b = value
			return
		end
	end

	local function read_cpu(addr: number): number?
		addr = bit32.band(addr, 0xFFFF)

		if addr >= 0x5C00 and addr <= 0x5FFF then
			return buffer.readu8(mmc5_exram, bit32.band(addr - 0x5C00, 0x03FF))
		end

		if addr == 0x5204 then
			local value = 0
			if mmc5_irq_pending then
				value = bit32.bor(value, 0x80)
			end
			if mmc5_in_frame then
				value = bit32.bor(value, 0x40)
			end
			mmc5_irq_pending = false
			return value
		end

		if addr == 0x5205 then
			return bit32.band(mmc5_mul_a * mmc5_mul_b, 0xFF)
		end

		if addr == 0x5206 then
			return bit32.band(bit32.rshift(mmc5_mul_a * mmc5_mul_b, 8), 0xFF)
		end

		return nil
	end

	local function read_nametable(addr: number): number?
		if vram_buf == nil then
			return nil
		end

		local offset = bit32.band(addr, 0x0FFF)
		local nt = bit32.band(bit32.rshift(offset, 10), 0x03)
		local inner = bit32.band(offset, 0x03FF)
		local source = mmc5_nt_map[nt + 1]

		if source == 0 then
			return buffer.readu8(vram_buf, inner)
		end
		if source == 1 then
			return buffer.readu8(vram_buf, 0x0400 + inner)
		end
		if source == 2 then
			if mmc5_exram_mode >= 2 then
				return 0
			end
			return buffer.readu8(mmc5_exram, inner)
		end

		if inner < 0x03C0 then
			return mmc5_fill_tile
		end

		return bit32.band(mmc5_fill_attr * 0x55, 0xFF)
	end

	local function write_nametable(addr: number, value: number): boolean
		if vram_buf == nil then
			return false
		end

		local offset = bit32.band(addr, 0x0FFF)
		local nt = bit32.band(bit32.rshift(offset, 10), 0x03)
		local inner = bit32.band(offset, 0x03FF)
		local source = mmc5_nt_map[nt + 1]
		value = bit32.band(value, 0xFF)

		if source == 0 then
			buffer.writeu8(vram_buf, inner, value)
		elseif source == 1 then
			buffer.writeu8(vram_buf, 0x0400 + inner, value)
		elseif source == 2 then
			if mmc5_exram_mode < 2 then
				buffer.writeu8(mmc5_exram, inner, value)
			end
		end

		return true
	end

	local function map_prg_ram_addr(addr: number): number?
		addr = bit32.band(addr, 0xFFFF)
		return mmc5_prg_ram_offset(addr)
	end

	local function clock_scanline(scanline_value: number?)
		if scanline_value == nil then
			return
		end

		if scanline_value >= 240 and scanline_value <= 261 then
			mmc5_in_frame = false
		end

		if scanline_value == 261 then
			mmc5_scanline = -1
		end
	end

	local function on_ppu_address(_addr: number, scanline: number, cycle: number, rendering: boolean)
		if not rendering then
			return
		end

		if scanline < 0 or scanline >= 240 then
			return
		end

		if cycle < 1 or cycle > 340 then
			return
		end

		if mmc5_scanline == scanline then
			return
		end

		mmc5_scanline = scanline
		mmc5_in_frame = true

		if mmc5_irq_line ~= 0 and scanline == mmc5_irq_line then
			mmc5_irq_pending = true
		end
	end

	local function reset_mapper()
		mirroring = config.initialMirroring

		mmc5_prg_mode = 3
		mmc5_chr_mode = 3

		for i = 1, 4 do
			mmc5_prg_regs[i] = 0
		end

		for i = 1, 12 do
			mmc5_chr_regs[i] = 0
		end

		mmc5_chr_high = 0
		mmc5_last_chr_set = 0
		mmc5_exram_mode = 0

		mmc5_nt_map[1] = 0
		mmc5_nt_map[2] = 1
		mmc5_nt_map[3] = 0
		mmc5_nt_map[4] = 1

		buffer.fill(mmc5_exram, 0, 0, 0x400)
		mmc5_fill_tile = 0
		mmc5_fill_attr = 0

		mmc5_ram_protect_0 = 0
		mmc5_ram_protect_1 = 0
		mmc5_prg_ram_bank = 0

		mmc5_mul_a = 0
		mmc5_mul_b = 0

		_mmc5_split_control = 0
		_mmc5_split_scroll = 0
		_mmc5_split_bank = 0

		mmc5_irq_line = 0
		mmc5_irq_enabled = false
		mmc5_irq_pending = false
		mmc5_scanline = -1
		mmc5_in_frame = false

		mmc5_prg_regs[1] = 0x80
		mmc5_prg_regs[2] = 0x80
		mmc5_prg_regs[3] = 0x80
		mmc5_prg_regs[4] = bit32.bor(0x80, bit32.band(prg_total_8k - 1, 0x7F))

		update_mmc5_simple_mirroring()
	end

	reset_mapper()

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = write_cpu,
		readCpu = read_cpu,
		readNametable = read_nametable,
		writeNametable = write_nametable,
		mapPrgRamAddr = map_prg_ram_addr,
		clockA12 = nil,
		clockScanline = clock_scanline,
		onPpuAddress = on_ppu_address,
		reset = reset_mapper,
		irqPending = function(): boolean
			return mmc5_irq_pending and mmc5_irq_enabled
		end,
		clearIrq = function()
			mmc5_irq_pending = false
		end,
		getMirroring = function(): number
			return mirroring
		end,
		prgRamReadable = function(): boolean
			return prg_ram_available
		end,
		prgRamWritable = function(): boolean
			return prg_ram_available and mmc5_ram_protect_0 == 0x02 and mmc5_ram_protect_1 == 0x01
		end,
	}
end

--// MAPPER_007
local function AOROM(config: MapperConfig): Mapper
	local prg_banks_32k = atLeastOne(config.prgSize // 0x8000)
	local four_screen = config.fourScreen
	local bank_select = 0
	local mirroring = if four_screen then Mirroring.VERTICAL else Mirroring.ONE_SCREEN_LOW

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return 0
		end

		return bank_select * 0x8000 + bit32.band(addr - 0x8000, 0x7FFF)
	end

	local function map_chr_addr(addr: number, _fetch_kind: number?, _sprite_16: boolean?): number
		return bit32.band(addr, 0x1FFF)
	end

	local function write_cpu(addr: number, value: number)
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return
		end

		value = bit32.band(value, 0xFF)
		bank_select = wrapBank(bit32.band(value, 0x07), prg_banks_32k)

		if not four_screen then
			mirroring = if bit32.btest(value, 0x10) then Mirroring.ONE_SCREEN_HIGH else Mirroring.ONE_SCREEN_LOW
		end
	end

	local function reset_mapper()
		bank_select = 0
		mirroring = if four_screen then Mirroring.VERTICAL else Mirroring.ONE_SCREEN_LOW
	end

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = write_cpu,
		readCpu = nil,
		readNametable = nil,
		writeNametable = nil,
		mapPrgRamAddr = nil,
		clockA12 = nil,
		clockScanline = nil,
		onPpuAddress = nil,
		reset = reset_mapper,
		irqPending = function(): boolean
			return false
		end,
		clearIrq = function() end,
		getMirroring = function(): number
			return mirroring
		end,
		prgRamReadable = function(): boolean
			return false
		end,
		prgRamWritable = function(): boolean
			return false
		end,
	}
end

--// MAPPER_009
local function MMC2(config: MapperConfig): Mapper
	local prg_total_8k = atLeastOne(config.prgSize // 0x2000)
	local chr_total_4k = atLeastOne(config.chrSize // 0x1000)
	local mirroring = config.initialMirroring

	local prg_bank = 0
	local chr_fd_0 = 0
	local chr_fe_0 = 0
	local chr_fd_1 = 0
	local chr_fe_1 = 0
	local latch0_fe = false
	local latch1_fe = false

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return 0
		end

		local bank = 0
		if addr < 0xA000 then
			bank = wrapBank(prg_bank, prg_total_8k)
		elseif addr < 0xC000 then
			bank = wrapBank(prg_total_8k - 3, prg_total_8k)
		elseif addr < 0xE000 then
			bank = wrapBank(prg_total_8k - 2, prg_total_8k)
		else
			bank = wrapBank(prg_total_8k - 1, prg_total_8k)
		end

		return bank * 0x2000 + bit32.band(addr, 0x1FFF)
	end

	local function map_chr_addr(addr: number, _fetch_kind: number?, _sprite_16: boolean?): number
		addr = bit32.band(addr, 0x1FFF)
		local bank4 = 0

		if addr < 0x1000 then
			bank4 = if latch0_fe then chr_fe_0 else chr_fd_0
		else
			bank4 = if latch1_fe then chr_fe_1 else chr_fd_1
		end

		bank4 = wrapBank(bank4, chr_total_4k)
		return bank4 * 0x1000 + bit32.band(addr, 0x0FFF)
	end

	local function write_cpu(addr: number, value: number)
		addr = bit32.band(addr, 0xFFFF)
		value = bit32.band(value, 0xFF)
		if addr < 0xA000 then
			return
		end

		if addr < 0xB000 then
			prg_bank = bit32.band(value, 0x0F)
		elseif addr < 0xC000 then
			chr_fd_0 = bit32.band(value, 0x1F)
		elseif addr < 0xD000 then
			chr_fe_0 = bit32.band(value, 0x1F)
		elseif addr < 0xE000 then
			chr_fd_1 = bit32.band(value, 0x1F)
		elseif addr < 0xF000 then
			chr_fe_1 = bit32.band(value, 0x1F)
		elseif not config.fourScreen then
			mirroring = if bit32.band(value, 0x01) == 0 then Mirroring.VERTICAL else Mirroring.HORIZONTAL
		end
	end

	local function on_ppu_address(addr: number, _scanline: number, _cycle: number, _rendering: boolean)
		addr = bit32.band(addr, 0x1FFF)

		if addr == 0x0FD8 then
			latch0_fe = false
		elseif addr == 0x0FE8 then
			latch0_fe = true
		elseif addr >= 0x1FD8 and addr <= 0x1FDF then
			latch1_fe = false
		elseif addr >= 0x1FE8 and addr <= 0x1FEF then
			latch1_fe = true
		end
	end

	local function reset_mapper()
		mirroring = config.initialMirroring
		prg_bank = 0
		chr_fd_0 = 0
		chr_fe_0 = 0
		chr_fd_1 = 0
		chr_fe_1 = 0
		latch0_fe = false
		latch1_fe = false
	end

	reset_mapper()

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = write_cpu,
		readCpu = nil,
		readNametable = nil,
		writeNametable = nil,
		mapPrgRamAddr = nil,
		clockA12 = nil,
		clockScanline = nil,
		onPpuAddress = on_ppu_address,
		reset = reset_mapper,
		irqPending = function(): boolean
			return false
		end,
		clearIrq = function() end,
		getMirroring = function(): number
			return mirroring
		end,
		prgRamReadable = function(): boolean
			return false
		end,
		prgRamWritable = function(): boolean
			return false
		end,
	}
end

--// MAPPER_010
local function MMC4(config: MapperConfig): Mapper
	local prg_total_16k = atLeastOne(config.prgSize // 0x4000)
	local chr_total_4k = atLeastOne(config.chrSize // 0x1000)
	local mirroring = config.initialMirroring

	local prg_bank = 0
	local chr_fd_0 = 0
	local chr_fe_0 = 0
	local chr_fd_1 = 0
	local chr_fe_1 = 0
	local latch0_fe = false
	local latch1_fe = false

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return 0
		end

		local bank16 = 0
		if addr < 0xC000 then
			bank16 = wrapBank(prg_bank, prg_total_16k)
		else
			bank16 = wrapBank(prg_total_16k - 1, prg_total_16k)
		end

		return bank16 * 0x4000 + bit32.band(addr, 0x3FFF)
	end

	local function map_chr_addr(addr: number, _fetch_kind: number?, _sprite_16: boolean?): number
		addr = bit32.band(addr, 0x1FFF)
		local bank4 = 0

		if addr < 0x1000 then
			bank4 = if latch0_fe then chr_fe_0 else chr_fd_0
		else
			bank4 = if latch1_fe then chr_fe_1 else chr_fd_1
		end

		bank4 = wrapBank(bank4, chr_total_4k)
		return bank4 * 0x1000 + bit32.band(addr, 0x0FFF)
	end

	local function write_cpu(addr: number, value: number)
		addr = bit32.band(addr, 0xFFFF)
		value = bit32.band(value, 0xFF)
		if addr < 0xA000 then
			return
		end

		if addr < 0xB000 then
			prg_bank = bit32.band(value, 0x0F)
		elseif addr < 0xC000 then
			chr_fd_0 = bit32.band(value, 0x1F)
		elseif addr < 0xD000 then
			chr_fe_0 = bit32.band(value, 0x1F)
		elseif addr < 0xE000 then
			chr_fd_1 = bit32.band(value, 0x1F)
		elseif addr < 0xF000 then
			chr_fe_1 = bit32.band(value, 0x1F)
		elseif not config.fourScreen then
			mirroring = if bit32.band(value, 0x01) == 0 then Mirroring.VERTICAL else Mirroring.HORIZONTAL
		end
	end

	local function on_ppu_address(addr: number, _scanline: number, _cycle: number, _rendering: boolean)
		addr = bit32.band(addr, 0x1FFF)

		if addr == 0x0FD8 then
			latch0_fe = false
		elseif addr == 0x0FE8 then
			latch0_fe = true
		elseif addr == 0x1FD8 then
			latch1_fe = false
		elseif addr == 0x1FE8 then
			latch1_fe = true
		end
	end

	local function reset_mapper()
		mirroring = config.initialMirroring
		prg_bank = 0
		chr_fd_0 = 0
		chr_fe_0 = 0
		chr_fd_1 = 0
		chr_fe_1 = 0
		latch0_fe = false
		latch1_fe = false
	end

	reset_mapper()

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = write_cpu,
		readCpu = nil,
		readNametable = nil,
		writeNametable = nil,
		mapPrgRamAddr = nil,
		clockA12 = nil,
		clockScanline = nil,
		onPpuAddress = on_ppu_address,
		reset = reset_mapper,
		irqPending = function(): boolean
			return false
		end,
		clearIrq = function() end,
		getMirroring = function(): number
			return mirroring
		end,
		prgRamReadable = function(): boolean
			return false
		end,
		prgRamWritable = function(): boolean
			return false
		end,
	}
end

--// MAPPER_011
local function ColorDreams(config: MapperConfig): Mapper
	local prg_banks_32k = atLeastOne(config.prgSize // 0x8000)
	local chr_banks_8k = atLeastOne(config.chrSize // 0x2000)
	local mirroring = config.initialMirroring

	local prg_bank = 0
	local chr_bank = 0

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return 0
		end

		return prg_bank * 0x8000 + bit32.band(addr - 0x8000, 0x7FFF)
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

		value = bit32.band(value, 0xFF)
		prg_bank = wrapBank(bit32.band(value, 0x03), prg_banks_32k)
		chr_bank = wrapBank(bit32.band(bit32.rshift(value, 4), 0x0F), chr_banks_8k)
	end

	local function reset_mapper()
		prg_bank = 0
		chr_bank = 0
	end

	reset_mapper()

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = write_cpu,
		readCpu = nil,
		readNametable = nil,
		writeNametable = nil,
		mapPrgRamAddr = nil,
		clockA12 = nil,
		clockScanline = nil,
		onPpuAddress = nil,
		reset = reset_mapper,
		irqPending = function(): boolean
			return false
		end,
		clearIrq = function() end,
		getMirroring = function(): number
			return mirroring
		end,
		prgRamReadable = function(): boolean
			return false
		end,
		prgRamWritable = function(): boolean
			return false
		end,
	}
end

--// MAPPER_066
local function GXROM(config: MapperConfig): Mapper
	local prg_banks_32k = atLeastOne(config.prgSize // 0x8000)
	local chr_banks_8k = atLeastOne(config.chrSize // 0x2000)
	local mirroring = config.initialMirroring

	local prg_bank = 0
	local chr_bank = 0

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return 0
		end

		return prg_bank * 0x8000 + bit32.band(addr - 0x8000, 0x7FFF)
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

		value = bit32.band(value, 0xFF)
		prg_bank = wrapBank(bit32.band(bit32.rshift(value, 4), 0x03), prg_banks_32k)
		chr_bank = wrapBank(bit32.band(value, 0x03), chr_banks_8k)
	end

	local function reset_mapper()
		prg_bank = 0
		chr_bank = 0
	end

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = write_cpu,
		readCpu = nil,
		readNametable = nil,
		writeNametable = nil,
		mapPrgRamAddr = nil,
		clockA12 = nil,
		clockScanline = nil,
		onPpuAddress = nil,
		reset = reset_mapper,
		irqPending = function(): boolean
			return false
		end,
		clearIrq = function() end,
		getMirroring = function(): number
			return mirroring
		end,
		prgRamReadable = function(): boolean
			return false
		end,
		prgRamWritable = function(): boolean
			return false
		end,
	}
end

--// INIT

local factories: {[number]: (config: MapperConfig) -> Mapper} = {

	[0] = NROM,
	[1] = MMC1,
	[2] = UNROM,
	[3] = CNROM,
	[4] = MMC3,
	[5] = MMC5,
	[9] = MMC2,
	[10] = MMC4,
	[11] = ColorDreams,
	[7] = AOROM,
	[66] = GXROM,

}

return {
	supports = function(mapper_id: number): boolean
		return factories[mapper_id] ~= nil
	end,

	create = function(config: MapperConfig): Mapper
		local factory = factories[config.id]
		assert(factory ~= nil, string.format("Unsupported mapper: %d", config.id))
		return factory(config)
	end,
}

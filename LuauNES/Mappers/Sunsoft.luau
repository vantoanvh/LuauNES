--!optimize 2
--!native
--!strict

local Base = require'./Base'

type MapperConfig = Base.MapperConfig

local atLeastOne = Base.atLeastOne
local wrapBank = Base.wrapBank
local normalizeOffset = Base.normalizeOffset

local function read_buffer_u8(buf: buffer?, len: number, offset: number): number
	if buf ~= nil and offset >= 0 and offset < len then
		return buffer.readu8(buf, offset)
	end

	return 0
end

local function write_buffer_u8(buf: buffer?, len: number, offset: number, value: number)
	if buf ~= nil and offset >= 0 and offset < len then
		buffer.writeu8(buf, offset, value)
	end
end

--// MAPPER_067
local function Sunsoft3(config: MapperConfig)
	local prg_total_16k = atLeastOne(config.prgSize // 0x4000)
	local chr_total_2k = atLeastOne(config.chrSize // 0x0800)

	local mirroring = config.initialMirroring
	local prg_bank = 0
	local prg_base_8000 = 0
	local prg_base_C000 = wrapBank(prg_total_16k - 1, prg_total_16k) * 0x4000
	local chr_base0 = 0
	local chr_base1 = 0
	local chr_base2 = 0
	local chr_base3 = 0
	local irq_latch = false
	local irq_enabled = false
	local irq_counter = 0
	local irq_pending = false

	local function set_chr_base(index: number, value: number)
		local base = wrapBank(value, chr_total_2k) * 0x0800
		if index == 0 then
			chr_base0 = base
		elseif index == 1 then
			chr_base1 = base
		elseif index == 2 then
			chr_base2 = base
		else
			chr_base3 = base
		end
	end

	local function recalc_prg_base()
		prg_base_8000 = wrapBank(prg_bank, prg_total_16k) * 0x4000
	end

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return 0
		end

		if addr < 0xC000 then
			return prg_base_8000 + bit32.band(addr, 0x3FFF)
		end

		return prg_base_C000 + bit32.band(addr, 0x3FFF)
	end

	local function map_chr_addr(addr: number, _fetch_kind: number?, _sprite_16: boolean?): number
		addr = bit32.band(addr, 0x1FFF)
		local segment = bit32.rshift(addr, 11)
		if segment == 0 then
			return chr_base0 + bit32.band(addr, 0x07FF)
		end
		if segment == 1 then
			return chr_base1 + bit32.band(addr, 0x07FF)
		end
		if segment == 2 then
			return chr_base2 + bit32.band(addr, 0x07FF)
		end
		return chr_base3 + bit32.band(addr, 0x07FF)
	end

	local function write_cpu(addr: number, value: number)
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return
		end

		local reg = bit32.band(addr, 0xF800)
		if reg == 0x8800 then
			set_chr_base(0, value)
		elseif reg == 0x9800 then
			set_chr_base(1, value)
		elseif reg == 0xA800 then
			set_chr_base(2, value)
		elseif reg == 0xB800 then
			set_chr_base(3, value)
		elseif reg == 0xC800 then
			irq_counter = if irq_latch
				then bit32.bor(bit32.band(irq_counter, 0xFF00), value)
				else bit32.bor(bit32.band(irq_counter, 0x00FF), value * 256)
			irq_latch = not irq_latch
		elseif reg == 0xD800 then
			irq_enabled = bit32.btest(value, 0x10)
			irq_latch = false
			irq_pending = false
		elseif reg == 0xE800 then
			local mode = bit32.band(value, 0x03)
			if mode == 0 then
				mirroring = 2
			elseif mode == 1 then
				mirroring = 3
			elseif mode == 2 then
				mirroring = 0
			else
				mirroring = 1
			end
		elseif reg == 0xF800 then
			prg_bank = value
			recalc_prg_base()
		end
	end

	local function clock_cpu(cycles: number)
		if not irq_enabled or cycles <= 0 then
			return
		end

		if cycles <= irq_counter then
			irq_counter = bit32.band(irq_counter - cycles, 0xFFFF)
			return
		end

		irq_counter = 0xFFFF
		irq_enabled = false
		irq_pending = true
	end

	local function reset_mapper()
		mirroring = config.initialMirroring
		prg_bank = 0
		recalc_prg_base()
		chr_base0 = 0
		chr_base1 = 0
		chr_base2 = 0
		chr_base3 = 0
		irq_latch = false
		irq_enabled = false
		irq_counter = 0
		irq_pending = false
	end

	reset_mapper()

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = write_cpu,
		readPpu = nil,
		writePpu = nil,
		readCpu = nil,
		readNametable = nil,
		writeNametable = nil,
		mapPrgRamAddr = nil,
		clockCpu = clock_cpu,
		clockA12 = nil,
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
		prgRamReadable = nil,
		prgRamWritable = nil,
	}
end

--// MAPPER_068
local function Sunsoft4(config: MapperConfig)
	local prg_total_16k = atLeastOne(config.prgSize // 0x4000)
	local internal_prg_total_16k = if prg_total_16k < 8 then prg_total_16k else 8
	local chr_total_1k = atLeastOne(config.chrSize // 0x0400)
	local chr_buf = config.chr
	local chr_size = config.chrSize
	local chr_is_ram = config.chrIsRam
	local prg_ram_size = config.prgRamSize
	local prg_ram_available = prg_ram_size > 0

	local mirroring = config.initialMirroring
	local chr_base0 = 0
	local chr_base1 = 0
	local chr_base2 = 0
	local chr_base3 = 0
	local nt_reg0 = 0
	local nt_reg1 = 0
	local use_chr_for_nametables = false
	local prg_ram_enabled = false
	local licensing_timer = 0
	local using_external_rom = false
	local external_page = 0
	local prg_base_8000 = 0
	local prg_base_C000 = wrapBank(7, prg_total_16k) * 0x4000

	local function set_chr_base(index: number, value: number)
		local base = wrapBank(value, chr_total_1k) * 0x0400
		if index == 0 then
			chr_base0 = base
		elseif index == 1 then
			chr_base1 = base
		elseif index == 2 then
			chr_base2 = base
		else
			chr_base3 = base
		end
	end

	local function recalc_prg_base(value: number)
		local internal_bank = wrapBank(bit32.band(value, 0x07), internal_prg_total_16k)
		local external_count = prg_total_16k - 8
		local wants_external = bit32.band(value, 0x08) == 0

		if wants_external and external_count > 0 then
			using_external_rom = true
			external_page = 0x08 + bit32.band(value, 0x07) % external_count
			prg_base_8000 = external_page * 0x4000
		else
			using_external_rom = false
			external_page = 0
			prg_base_8000 = internal_bank * 0x4000
		end
	end

	local function nametable_chr_base(slot: number): number
		local reg_select = 0
		if mirroring == 2 then
			reg_select = bit32.band(slot, 0x01)
		elseif mirroring == 3 then
			reg_select = bit32.rshift(bit32.band(slot, 0x02), 1)
		elseif mirroring == 1 then
			reg_select = 1
		end

		local page = if reg_select == 0 then nt_reg0 else nt_reg1
		return wrapBank(page, chr_total_1k) * 0x0400
	end

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return 0
		end

		if addr < 0xC000 then
			if using_external_rom and licensing_timer == 0 then
				return -1
			end
			return prg_base_8000 + bit32.band(addr, 0x3FFF)
		end

		return prg_base_C000 + bit32.band(addr, 0x3FFF)
	end

	local function map_chr_addr(addr: number, _fetch_kind: number?, _sprite_16: boolean?): number
		addr = bit32.band(addr, 0x1FFF)
		local segment = bit32.rshift(addr, 11)
		if segment == 0 then
			return chr_base0 + bit32.band(addr, 0x07FF)
		end
		if segment == 1 then
			return chr_base1 + bit32.band(addr, 0x07FF)
		end
		if segment == 2 then
			return chr_base2 + bit32.band(addr, 0x07FF)
		end
		return chr_base3 + bit32.band(addr, 0x07FF)
	end

	local function read_nametable(addr: number): number?
		if not use_chr_for_nametables then
			return nil
		end

		local offset = bit32.band(addr, 0x0FFF)
		local slot = bit32.rshift(offset, 10)
		local inner = bit32.band(offset, 0x03FF)
		return read_buffer_u8(chr_buf, chr_size, nametable_chr_base(slot) + inner)
	end

	local function write_nametable(addr: number, value: number): boolean
		if not use_chr_for_nametables then
			return false
		end

		if chr_is_ram then
			local offset = bit32.band(addr, 0x0FFF)
			local slot = bit32.rshift(offset, 10)
			local inner = bit32.band(offset, 0x03FF)
			write_buffer_u8(chr_buf, chr_size, nametable_chr_base(slot) + inner, value)
		end

		return true
	end

	local function map_prg_ram_addr(addr: number): number?
		if not prg_ram_available or not prg_ram_enabled then
			return nil
		end

		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x6000 or addr >= 0x8000 then
			return nil
		end

		return normalizeOffset(addr - 0x6000, prg_ram_size)
	end

	local function write_cpu(addr: number, value: number)
		addr = bit32.band(addr, 0xFFFF)
		if addr >= 0x6000 and addr < 0x8000 then
			licensing_timer = 1024 * 105
			return
		end

		if addr < 0x8000 then
			return
		end

		local reg = bit32.band(addr, 0xF000)
		if reg == 0x8000 then
			set_chr_base(0, value)
		elseif reg == 0x9000 then
			set_chr_base(1, value)
		elseif reg == 0xA000 then
			set_chr_base(2, value)
		elseif reg == 0xB000 then
			set_chr_base(3, value)
		elseif reg == 0xC000 then
			nt_reg0 = bit32.bor(value, 0x80)
		elseif reg == 0xD000 then
			nt_reg1 = bit32.bor(value, 0x80)
		elseif reg == 0xE000 then
			local mode = bit32.band(value, 0x03)
			if mode == 0 then
				mirroring = 2
			elseif mode == 1 then
				mirroring = 3
			elseif mode == 2 then
				mirroring = 0
			else
				mirroring = 1
			end
			use_chr_for_nametables = bit32.btest(value, 0x10)
		elseif reg == 0xF000 then
			recalc_prg_base(value)
			prg_ram_enabled = bit32.btest(value, 0x10)
		end
	end

	local function clock_cpu(cycles: number)
		if licensing_timer <= 0 or cycles <= 0 then
			return
		end

		if cycles >= licensing_timer then
			licensing_timer = 0
		else
			licensing_timer -= cycles
		end
	end

	local function reset_mapper()
		mirroring = config.initialMirroring
		chr_base0 = 0
		chr_base1 = 0
		chr_base2 = 0
		chr_base3 = 0
		nt_reg0 = 0
		nt_reg1 = 0
		use_chr_for_nametables = false
		prg_ram_enabled = false
		licensing_timer = 0
		using_external_rom = false
		external_page = 0
		prg_base_C000 = wrapBank(7, prg_total_16k) * 0x4000
		recalc_prg_base(0)
	end

	reset_mapper()

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = write_cpu,
		readPpu = nil,
		writePpu = nil,
		readCpu = nil,
		readNametable = read_nametable,
		writeNametable = write_nametable,
		mapPrgRamAddr = map_prg_ram_addr,
		clockCpu = clock_cpu,
		clockA12 = nil,
		clockScanline = nil,
		onPpuAddress = nil,
		reset = reset_mapper,
		irqPending = nil,
		clearIrq = function() end,
		getMirroring = function(): number
			return mirroring
		end,
		prgRamReadable = function(): boolean
			return prg_ram_available and prg_ram_enabled
		end,
		prgRamWritable = function(): boolean
			return prg_ram_available and prg_ram_enabled
		end,
	}
end

--// MAPPER_089
local function Sunsoft89(config: MapperConfig)
	local prg_total_16k = atLeastOne(config.prgSize // 0x4000)
	local chr_total_8k = atLeastOne(config.chrSize // 0x2000)

	local mirroring = config.initialMirroring
	local prg_bank = 0
	local chr_bank = 0
	local prg_base_8000 = 0
	local prg_base_C000 = wrapBank(prg_total_16k - 1, prg_total_16k) * 0x4000

	local function recalc_bases()
		prg_base_8000 = wrapBank(prg_bank, prg_total_16k) * 0x4000
	end

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return 0
		end

		if addr < 0xC000 then
			return prg_base_8000 + bit32.band(addr, 0x3FFF)
		end

		return prg_base_C000 + bit32.band(addr, 0x3FFF)
	end

	local function map_chr_addr(addr: number, _fetch_kind: number?, _sprite_16: boolean?): number
		addr = bit32.band(addr, 0x1FFF)
		return chr_bank * 0x2000 + addr
	end

	local function write_cpu(addr: number, value: number)
		if bit32.band(addr, 0xFFFF) < 0x8000 then
			return
		end

		prg_bank = bit32.band(bit32.rshift(value, 4), 0x07)
		chr_bank = wrapBank(
			bit32.bor(bit32.band(value, 0x07), bit32.rshift(bit32.band(value, 0x80), 4)),
			chr_total_8k
		)
		mirroring = if bit32.btest(value, 0x08) then 1 else 0
		recalc_bases()
	end

	local function reset_mapper()
		mirroring = config.initialMirroring
		prg_bank = 0
		chr_bank = 0
		recalc_bases()
	end

	reset_mapper()

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = write_cpu,
		readPpu = nil,
		writePpu = nil,
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

--// MAPPER_093
local function Sunsoft93(config: MapperConfig)
	local prg_total_16k = atLeastOne(config.prgSize // 0x4000)

	local chr_enabled = true
	local prg_bank = 0
	local prg_base_8000 = 0
	local prg_base_C000 = wrapBank(prg_total_16k - 1, prg_total_16k) * 0x4000

	local function recalc_prg_base()
		prg_base_8000 = wrapBank(prg_bank, prg_total_16k) * 0x4000
	end

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return 0
		end

		if addr < 0xC000 then
			return prg_base_8000 + bit32.band(addr, 0x3FFF)
		end

		return prg_base_C000 + bit32.band(addr, 0x3FFF)
	end

	local function map_chr_addr(addr: number, _fetch_kind: number?, _sprite_16: boolean?): number
		if chr_enabled then
			return bit32.band(addr, 0x1FFF)
		end

		return -1
	end

	local function write_cpu(addr: number, value: number)
		if bit32.band(addr, 0xFFFF) < 0x8000 then
			return
		end

		prg_bank = bit32.band(bit32.rshift(value, 4), 0x07)
		chr_enabled = bit32.btest(value, 0x01)
		recalc_prg_base()
	end

	local function reset_mapper()
		chr_enabled = true
		prg_bank = 0
		recalc_prg_base()
	end

	reset_mapper()

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = write_cpu,
		readPpu = nil,
		writePpu = nil,
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
		getMirroring = nil,
		prgRamReadable = nil,
		prgRamWritable = nil,
	}
end

--// MAPPER_184
local function Sunsoft184(config: MapperConfig)
	local chr_total_4k = atLeastOne(config.chrSize // 0x1000)

	local chr_base0 = 0
	local chr_base1 = 0

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return 0
		end

		return bit32.band(addr - 0x8000, 0x7FFF)
	end

	local function map_chr_addr(addr: number, _fetch_kind: number?, _sprite_16: boolean?): number
		addr = bit32.band(addr, 0x1FFF)
		if addr < 0x1000 then
			return chr_base0 + addr
		end

		return chr_base1 + bit32.band(addr, 0x0FFF)
	end

	local function write_cpu(addr: number, value: number)
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x6000 or addr >= 0x8000 then
			return
		end

		chr_base0 = wrapBank(bit32.band(value, 0x07), chr_total_4k) * 0x1000
		chr_base1 = wrapBank(bit32.bor(0x80, bit32.band(bit32.rshift(value, 4), 0x07)), chr_total_4k) * 0x1000
	end

	local function reset_mapper()
		chr_base0 = 0
		chr_base1 = wrapBank(1, chr_total_4k) * 0x1000
	end

	reset_mapper()

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = write_cpu,
		readPpu = nil,
		writePpu = nil,
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
		getMirroring = nil,
		prgRamReadable = nil,
		prgRamWritable = nil,
	}
end

--// MAPPER_069
local function FME7(config: MapperConfig)
	local prg_total_8k = atLeastOne(config.prgSize // 0x2000)
	local chr_total_1k = atLeastOne(config.chrSize // 0x0400)
	local prg_ram_size = config.prgRamSize
	local prg_ram_available = prg_ram_size > 0
	local four_screen = config.fourScreen
	local mirroring = config.initialMirroring

	local command = 0
	local chr_reg0 = 0
	local chr_reg1 = 0
	local chr_reg2 = 0
	local chr_reg3 = 0
	local chr_reg4 = 0
	local chr_reg5 = 0
	local chr_reg6 = 0
	local chr_reg7 = 0
	local chr_base0 = 0
	local chr_base1 = 0
	local chr_base2 = 0
	local chr_base3 = 0
	local chr_base4 = 0
	local chr_base5 = 0
	local chr_base6 = 0
	local chr_base7 = 0

	local prg_bank_8000 = 0
	local prg_bank_A000 = 1
	local prg_bank_C000 = 2
	local prg_base_8000 = 0
	local prg_base_A000 = 0
	local prg_base_C000 = 0
	local prg_base_E000 = (prg_total_8k - 1) * 0x2000

	local prg_ram_bank = 0
	local prg_6000_rom_base = 0
	local prg_ram_enabled = false
	local prg_ram_mapped = false

	local irq_counter = 0
	local irq_enabled = false
	local irq_counter_enabled = false
	local irq_pending = false

	local function recalc_prg_bases()
		prg_base_8000 = wrapBank(prg_bank_8000, prg_total_8k) * 0x2000
		prg_base_A000 = wrapBank(prg_bank_A000, prg_total_8k) * 0x2000
		prg_base_C000 = wrapBank(prg_bank_C000, prg_total_8k) * 0x2000
	end

	local function recalc_chr_bases()
		chr_base0 = wrapBank(chr_reg0, chr_total_1k) * 0x0400
		chr_base1 = wrapBank(chr_reg1, chr_total_1k) * 0x0400
		chr_base2 = wrapBank(chr_reg2, chr_total_1k) * 0x0400
		chr_base3 = wrapBank(chr_reg3, chr_total_1k) * 0x0400
		chr_base4 = wrapBank(chr_reg4, chr_total_1k) * 0x0400
		chr_base5 = wrapBank(chr_reg5, chr_total_1k) * 0x0400
		chr_base6 = wrapBank(chr_reg6, chr_total_1k) * 0x0400
		chr_base7 = wrapBank(chr_reg7, chr_total_1k) * 0x0400
	end

	local function recalc_prg_6000_base()
		prg_6000_rom_base = wrapBank(prg_ram_bank, prg_total_8k) * 0x2000
	end

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr >= 0x6000 and addr < 0x8000 then
			if not prg_ram_mapped then
				return prg_6000_rom_base + bit32.band(addr, 0x1FFF)
			end
			return -1
		end

		if addr < 0x8000 then
			return -1
		end

		if addr < 0xA000 then
			return prg_base_8000 + bit32.band(addr, 0x1FFF)
		end
		if addr < 0xC000 then
			return prg_base_A000 + bit32.band(addr, 0x1FFF)
		end
		if addr < 0xE000 then
			return prg_base_C000 + bit32.band(addr, 0x1FFF)
		end
		return prg_base_E000 + bit32.band(addr, 0x1FFF)
	end

	local function map_chr_addr(addr: number, _fetch_kind: number?, _sprite_16: boolean?): number
		addr = bit32.band(addr, 0x1FFF)
		local segment = bit32.rshift(addr, 10)
		if segment == 0 then
			return chr_base0 + bit32.band(addr, 0x03FF)
		end
		if segment == 1 then
			return chr_base1 + bit32.band(addr, 0x03FF)
		end
		if segment == 2 then
			return chr_base2 + bit32.band(addr, 0x03FF)
		end
		if segment == 3 then
			return chr_base3 + bit32.band(addr, 0x03FF)
		end
		if segment == 4 then
			return chr_base4 + bit32.band(addr, 0x03FF)
		end
		if segment == 5 then
			return chr_base5 + bit32.band(addr, 0x03FF)
		end
		if segment == 6 then
			return chr_base6 + bit32.band(addr, 0x03FF)
		end
		return chr_base7 + bit32.band(addr, 0x03FF)
	end

	local function map_prg_ram_addr(addr: number): number?
		if not prg_ram_available or not prg_ram_enabled or not prg_ram_mapped then
			return nil
		end

		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x6000 or addr >= 0x8000 then
			return nil
		end

		local bank_offset = bit32.band(prg_ram_bank, 0x3F) * 0x2000
		local ram_offset = bank_offset + bit32.band(addr, 0x1FFF)
		return normalizeOffset(ram_offset, prg_ram_size)
	end

	local function write_cpu(addr: number, value: number)
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return
		end

		if addr < 0xA000 then
			command = bit32.band(value, 0x0F)
			return
		end

		if addr >= 0xC000 then
			return
		end

		if command <= 0x07 then
			if command == 0 then
				chr_reg0 = value
				chr_base0 = wrapBank(value, chr_total_1k) * 0x0400
			elseif command == 1 then
				chr_reg1 = value
				chr_base1 = wrapBank(value, chr_total_1k) * 0x0400
			elseif command == 2 then
				chr_reg2 = value
				chr_base2 = wrapBank(value, chr_total_1k) * 0x0400
			elseif command == 3 then
				chr_reg3 = value
				chr_base3 = wrapBank(value, chr_total_1k) * 0x0400
			elseif command == 4 then
				chr_reg4 = value
				chr_base4 = wrapBank(value, chr_total_1k) * 0x0400
			elseif command == 5 then
				chr_reg5 = value
				chr_base5 = wrapBank(value, chr_total_1k) * 0x0400
			elseif command == 6 then
				chr_reg6 = value
				chr_base6 = wrapBank(value, chr_total_1k) * 0x0400
			else
				chr_reg7 = value
				chr_base7 = wrapBank(value, chr_total_1k) * 0x0400
			end
		elseif command == 0x08 then
			prg_ram_enabled = bit32.btest(value, 0x80)
			prg_ram_mapped = bit32.btest(value, 0x40)
			prg_ram_bank = bit32.band(value, 0x3F)
			recalc_prg_6000_base()
		elseif command == 0x09 then
			prg_bank_8000 = value
			prg_base_8000 = wrapBank(value, prg_total_8k) * 0x2000
		elseif command == 0x0A then
			prg_bank_A000 = value
			prg_base_A000 = wrapBank(value, prg_total_8k) * 0x2000
		elseif command == 0x0B then
			prg_bank_C000 = value
			prg_base_C000 = wrapBank(value, prg_total_8k) * 0x2000
		elseif command == 0x0C then
			if not four_screen then
				local mode = bit32.band(value, 0x03)
				if mode == 0 then
					mirroring = 2
				elseif mode == 1 then
					mirroring = 3
				elseif mode == 2 then
					mirroring = 0
				else
					mirroring = 1
				end
			end
		elseif command == 0x0D then
			irq_enabled = bit32.btest(value, 0x01)
			irq_counter_enabled = bit32.btest(value, 0x80)
			irq_pending = false
		elseif command == 0x0E then
			irq_counter = bit32.bor(bit32.band(irq_counter, 0xFF00), value)
		elseif command == 0x0F then
			irq_counter = bit32.bor(bit32.band(irq_counter, 0x00FF), value * 256)
		end
	end

	local function clock_cpu(cycles: number)
		if not irq_counter_enabled or cycles <= 0 then
			return
		end

		local old_counter = irq_counter
		if cycles <= old_counter then
			irq_counter = bit32.band(old_counter - cycles, 0xFFFF)
			return
		end

		local remaining = cycles - old_counter - 1
		irq_counter = bit32.band(0xFFFF - (remaining % 0x10000), 0xFFFF)
		if irq_enabled then
			irq_pending = true
		end
	end

	local function reset_mapper()
		mirroring = config.initialMirroring
		command = 0
		chr_reg0 = 0
		chr_reg1 = 0
		chr_reg2 = 0
		chr_reg3 = 0
		chr_reg4 = 0
		chr_reg5 = 0
		chr_reg6 = 0
		chr_reg7 = 0
		recalc_chr_bases()

		prg_bank_8000 = 0
		prg_bank_A000 = 1
		prg_bank_C000 = 2
		recalc_prg_bases()

		prg_ram_bank = 0
		recalc_prg_6000_base()
		prg_ram_enabled = false
		prg_ram_mapped = false
		irq_counter = 0
		irq_enabled = false
		irq_counter_enabled = false
		irq_pending = false
	end

	reset_mapper()

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = write_cpu,
		readPpu = nil,
		writePpu = nil,
		readCpu = nil,
		readNametable = nil,
		writeNametable = nil,
		mapPrgRamAddr = map_prg_ram_addr,
		clockCpu = clock_cpu,
		clockA12 = nil,
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
			return prg_ram_available and prg_ram_enabled and prg_ram_mapped
		end,
		prgRamWritable = function(): boolean
			return prg_ram_available and prg_ram_enabled and prg_ram_mapped
		end,
	}
end

return {
	[67] = Sunsoft3,
	[68] = Sunsoft4,
	[69] = FME7,
	[89] = Sunsoft89,
	[93] = Sunsoft93,
	[184] = Sunsoft184,
}

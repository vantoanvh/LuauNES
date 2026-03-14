--!optimize 2
--!native
--!strict

local Base = require'./Base'

type MapperConfig = Base.MapperConfig

local atLeastOne = Base.atLeastOne
local wrapBank = Base.wrapBank
local normalizeOffset = Base.normalizeOffset

--// MAPPER_000
local function NROM(config: MapperConfig)
	local prg_banks_16k = atLeastOne(config.prgSize // 0x4000)
	local prg_ram_size = config.prgRamSize

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return 0
		end

		return prg_banks_16k <= 1 and bit32.band(addr - 0x8000, 0x3FFF) or bit32.band(addr - 0x8000, 0x7FFF)
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

		local offset = addr - 0x6000
		local size = prg_ram_size

		if not bit32.btest(size, size - 1) then
			return bit32.band(offset, size - 1)
		end

		local wrapped = offset % size
		return wrapped < 0 and wrapped + size or wrapped
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
		irqPending = nil,
		clearIrq = function() end,
		getMirroring = nil,
		prgRamReadable = nil,
		prgRamWritable = nil,
	}
end

--// MAPPER_001/105/155
local function MMC1(config: MapperConfig)
	local mapper_id = config.id
	local is_mapper_105 = mapper_id == 105
	local is_mapper_155 = mapper_id == 155
	local prg_banks_16k = atLeastOne(config.prgSize // 0x4000)
	local chr_banks_4k = atLeastOne(config.chrSize // 0x1000)
	local chr_banks_8k = atLeastOne(config.chrSize // 0x2000)
	local prg_banks_32k = atLeastOne(prg_banks_16k // 2)

	local prg_ram_size = config.prgRamSize
	local prg_ram_available = prg_ram_size > 0
	local dip_switches = 0

	local mirroring = config.initialMirroring
	local shift = 0x10
	local control = bit32.bor(0x0C, bit32.band(config.initialMirroring, 0x03))
	local chr0 = if is_mapper_105 then 0x10 else 0
	local chr1 = 0
	local prg = 0
	local prg_ram_enabled = prg_ram_available
	local mmc1_105_init_state = 0
	local mmc1_105_irq_counter = 0
	local mmc1_105_irq_enabled = false
	local mmc1_105_irq_pending = false

	local prg_32k_mode = false
	local prg_base_32k = 0
	local prg_base_8000 = 0
	local prg_base_c000 = (prg_banks_16k - 1) * 0x4000

	local chr_8k_mode = false
	local chr_base_8k = 0
	local chr_base_0000 = 0
	local chr_base_1000 = 0

	local function recalc_prg_map()
		local prg_mode = bit32.band(bit32.rshift(control, 2), 0x03)

		if is_mapper_105 then
			if mmc1_105_init_state == 0 and not bit32.btest(chr0, 0x10) then
				mmc1_105_init_state = 1
			elseif mmc1_105_init_state == 1 and bit32.btest(chr0, 0x10) then
				mmc1_105_init_state = 2
			end

			if bit32.btest(chr0, 0x10) then
				mmc1_105_irq_enabled = false
				mmc1_105_irq_counter = 0
				mmc1_105_irq_pending = false
			else
				mmc1_105_irq_enabled = true
			end

			if mmc1_105_init_state ~= 2 then
				prg_32k_mode = true
				prg_base_32k = 0
				return
			end

			if not bit32.btest(chr0, 0x08) then
				prg_32k_mode = true
				prg_base_32k = wrapBank(bit32.rshift(bit32.band(chr0, 0x06), 1), prg_banks_32k) * 0x8000
				return
			end

			local prg_bank = bit32.bor(bit32.band(prg, 0x07), 0x08)
			if prg_mode == 0 or prg_mode == 1 then
				prg_32k_mode = true
				prg_base_32k = wrapBank(bit32.rshift(bit32.band(prg_bank, 0x0E), 1), prg_banks_32k) * 0x8000
				return
			end

			prg_32k_mode = false
			if prg_mode == 2 then
				prg_base_8000 = wrapBank(0x08, prg_banks_16k) * 0x4000
				prg_base_c000 = wrapBank(prg_bank, prg_banks_16k) * 0x4000
			else
				prg_base_8000 = wrapBank(prg_bank, prg_banks_16k) * 0x4000
				prg_base_c000 = wrapBank(0x0F, prg_banks_16k) * 0x4000
			end
			return
		end

		local prg_bank = bit32.band(prg, 0x0F)

		if prg_mode == 0 or prg_mode == 1 then
			prg_32k_mode = true
			local bank32 = wrapBank(bit32.rshift(bit32.band(prg_bank, 0x0E), 1), prg_banks_32k)
			prg_base_32k = bank32 * 0x8000
			return
		end

		prg_32k_mode = false
		if prg_mode == 2 then
			prg_base_8000 = 0
			prg_base_c000 = wrapBank(prg_bank, prg_banks_16k) * 0x4000
		else
			prg_base_8000 = wrapBank(prg_bank, prg_banks_16k) * 0x4000
			prg_base_c000 = (prg_banks_16k - 1) * 0x4000
		end
	end

	local function recalc_chr_map()
		local chr_mode = bit32.band(bit32.rshift(control, 4), 0x01)
		if chr_mode == 0 then
			chr_8k_mode = true
			local bank8 = wrapBank(bit32.rshift(bit32.band(chr0, 0x1E), 1), chr_banks_8k)
			chr_base_8k = bank8 * 0x2000
		else
			chr_8k_mode = false
			chr_base_0000 = wrapBank(chr0, chr_banks_4k) * 0x1000
			chr_base_1000 = wrapBank(chr1, chr_banks_4k) * 0x1000
		end
	end

	local function update_control_dependent_state()
		mirroring = bit32.band(control, 0x03)
		recalc_prg_map()
		recalc_chr_map()
	end

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return 0
		end

		if prg_32k_mode then
			return prg_base_32k + bit32.band(addr - 0x8000, 0x7FFF)
		end

		if addr < 0xC000 then
			return prg_base_8000 + bit32.band(addr, 0x3FFF)
		end

		return prg_base_c000 + bit32.band(addr, 0x3FFF)
	end

	local function map_chr_addr(addr: number, _fetch_kind: number?, _sprite_16: boolean?): number
		addr = bit32.band(addr, 0x1FFF)
		if chr_8k_mode then
			return chr_base_8k + addr
		end

		if addr < 0x1000 then
			return chr_base_0000 + bit32.band(addr, 0x0FFF)
		end

		return chr_base_1000 + bit32.band(addr, 0x0FFF)
	end

	local function write_cpu(addr: number, value: number)
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return
		end

		if bit32.btest(value, 0x80) then
			shift = 0x10
			control = bit32.bor(control, 0x0C)
			update_control_dependent_state()
			return
		end

		local complete = bit32.band(shift, 0x01) ~= 0
		shift = bit32.rshift(shift, 1)
		shift = bit32.bor(shift, bit32.band(value, 0x01) * 16)

		if not complete then
			return
		end

		local reg = bit32.band(bit32.rshift(addr, 13), 0x03)
		local data = bit32.band(shift, 0x1F)

		if reg == 0 then
			control = data
			update_control_dependent_state()
		elseif reg == 1 then
			chr0 = data
			recalc_chr_map()
		elseif reg == 2 then
			chr1 = data
			recalc_chr_map()
		else
			prg = data
			prg_ram_enabled = if is_mapper_155 then prg_ram_available else prg_ram_available and not bit32.btest(data, 0x10)
			recalc_prg_map()
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

	local function clock_cpu(cycles: number)
		if not is_mapper_105 or cycles <= 0 or not mmc1_105_irq_enabled then
			return
		end

		local max_counter = 0x20000000 + bit32.band(dip_switches, 0x0F) * 0x02000000
		for _ = 1, cycles do
			mmc1_105_irq_counter += 1
			if mmc1_105_irq_counter >= max_counter then
				mmc1_105_irq_enabled = false
				mmc1_105_irq_pending = true
				break
			end
		end
	end

	local function reset_mapper()
		mirroring = config.initialMirroring
		shift = 0x10
		control = bit32.bor(0x0C, bit32.band(config.initialMirroring, 0x03))
		chr0 = if is_mapper_105 then 0x10 else 0
		chr1 = 0
		prg = 0
		prg_ram_enabled = prg_ram_available
		mmc1_105_init_state = 0
		mmc1_105_irq_counter = 0
		mmc1_105_irq_enabled = false
		mmc1_105_irq_pending = false
		update_control_dependent_state()
	end

	reset_mapper()

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = write_cpu,
		readPpu = nil,
		readCpu = nil,
		readNametable = nil,
		writeNametable = nil,
		mapPrgRamAddr = map_prg_ram_addr,
		clockCpu = if is_mapper_105 then clock_cpu else nil,
		clockA12 = nil,
		clockScanline = nil,
		onPpuAddress = nil,
		reset = reset_mapper,
		irqPending = if is_mapper_105 then function(): boolean
			return mmc1_105_irq_pending
		end else nil,
		clearIrq = function()
			if is_mapper_105 then
				mmc1_105_irq_pending = false
			end
		end,
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
local function UNROM(config: MapperConfig)
	local mapper_id = config.id
	local is_mapper_94 = mapper_id == 94
	local is_mapper_180 = mapper_id == 180
	local prg_banks_16k = atLeastOne(config.prgSize // 0x4000)
	local bank_select = 0

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return 0
		end

		if is_mapper_180 then
			if addr < 0xC000 then
				return bit32.band(addr - 0x8000, 0x3FFF)
			end

			return bank_select * 0x4000 + bit32.band(addr, 0x3FFF)
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

		local bank = value
		if is_mapper_94 then
			bank = bit32.band(bit32.rshift(bank, 2), 0x07)
		elseif is_mapper_180 then
			bank = bit32.band(bank, 0x07)
		end

		bank_select = wrapBank(bank, prg_banks_16k)
	end

	local function reset_mapper()
		bank_select = 0
	end

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = write_cpu,
		readPpu = nil,
		readCpu = nil,
		readNametable = nil,
		writeNametable = nil,
		mapPrgRamAddr = nil,
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

--// MAPPER_013
local function CpROM(config: MapperConfig)
	local chr_banks_4k = atLeastOne(config.chrSize // 0x1000)
	local chr_bank_1000 = 0

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
			return addr
		end

		return chr_bank_1000 * 0x1000 + bit32.band(addr, 0x0FFF)
	end

	local function write_cpu(addr: number, value: number)
		if bit32.band(addr, 0xFFFF) < 0x8000 then
			return
		end

		chr_bank_1000 = wrapBank(bit32.band(value, 0x03), chr_banks_4k)
	end

	local function reset_mapper()
		chr_bank_1000 = 0
	end

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = write_cpu,
		readPpu = nil,
		readCpu = nil,
		readNametable = nil,
		writeNametable = nil,
		mapPrgRamAddr = nil,
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

--// MAPPER_003
local function CNROM(config: MapperConfig)
	local prg_banks_16k = atLeastOne(config.prgSize // 0x4000)
	local chr_banks_8k = atLeastOne(config.chrSize // 0x2000)
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

		chr_bank = wrapBank(value, chr_banks_8k)
	end

	local function reset_mapper()
		chr_bank = 0
	end

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = write_cpu,
		readPpu = nil,
		readCpu = nil,
		readNametable = nil,
		writeNametable = nil,
		mapPrgRamAddr = nil,
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

--// MAPPER_185
local function CnromProtect(config: MapperConfig)
	local prg_banks_16k = atLeastOne(config.prgSize // 0x4000)
	local submapper = config.submapper or 0
	local chr_enabled = true

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
		if chr_enabled then
			return bit32.band(addr, 0x1FFF)
		end

		return -1
	end

	local function read_ppu(addr: number, _fetch_kind: number?, _sprite_16: boolean?): number?
		if not chr_enabled and addr >= 0 and addr < 0x2000 then
			return 0x01
		end

		return nil
	end

	local function write_cpu(addr: number, value: number)
		if bit32.band(addr, 0xFFFF) < 0x8000 then
			return
		end

		chr_enabled = (
			(submapper == 0 and bit32.band(value, 0x0F) ~= 0 and value ~= 0x13)
			or (submapper == 4 and bit32.band(value, 0x03) == 0)
			or (submapper == 5 and bit32.band(value, 0x03) == 1)
			or (submapper == 6 and bit32.band(value, 0x03) == 2)
			or (submapper == 7 and bit32.band(value, 0x03) == 3)
		)
	end

	local function reset_mapper()
		chr_enabled = true
	end

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = write_cpu,
		readPpu = read_ppu,
		readCpu = nil,
		readNametable = nil,
		writeNametable = nil,
		mapPrgRamAddr = nil,
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

--// MAPPER_004
local function MMC3(config: MapperConfig)
	local prg_total_8k = atLeastOne(config.prgSize // 0x2000)
	local chr_total_1k = atLeastOne(config.chrSize // 0x0400)
	local prg_ram_size = config.prgRamSize
	local prg_ram_available = prg_ram_size > 0

	local four_screen = config.fourScreen
	local mirroring = config.initialMirroring

	-- MMC3 bank registers R0-R7
	local reg0 = 0
	local reg1 = 0
	local reg2 = 0
	local reg3 = 0
	local reg4 = 0
	local reg5 = 0
	local reg6 = 0
	local reg7 = 0

	local bank_select = 0
	local prg_mode = 0
	local chr_mode = 0

	-- 4x 8 KiB PRG slots
	local prg_slot0 = 0
	local prg_slot1 = 0
	local prg_slot2 = 0
	local prg_slot3 = 0
	local prg_base0 = 0
	local prg_base1 = 0
	local prg_base2 = 0
	local prg_base3 = 0

	-- 8x 1 KiB CHR slots
	local chr_slot0 = 0
	local chr_slot1 = 0
	local chr_slot2 = 0
	local chr_slot3 = 0
	local chr_slot4 = 0
	local chr_slot5 = 0
	local chr_slot6 = 0
	local chr_slot7 = 0
	local chr_base0 = 0
	local chr_base1 = 0
	local chr_base2 = 0
	local chr_base3 = 0
	local chr_base4 = 0
	local chr_base5 = 0
	local chr_base6 = 0
	local chr_base7 = 0

	local irq_latch = 0
	local irq_counter = 0
	local irq_reload = false
	local irq_enabled = false
	local irq_pending = false

	local a12_prev = false
	-- MMC3 IRQ counter requires A12 low for >= 3 CPU cycles (12 PPU cycles).
	local a12_low_cycles = 12

	local prg_ram_enabled = prg_ram_available
	local prg_ram_write_protect = true

	local function set_reg(index: number, value: number)
		if index == 0 then
			reg0 = value
		elseif index == 1 then
			reg1 = value
		elseif index == 2 then
			reg2 = value
		elseif index == 3 then
			reg3 = value
		elseif index == 4 then
			reg4 = value
		elseif index == 5 then
			reg5 = value
		elseif index == 6 then
			reg6 = value
		else
			reg7 = value
		end
	end

	local function recalc_prg_slots()
		local count = prg_total_8k

		if prg_mode == 0 then
			prg_slot0 = wrapBank(reg6, count)
			prg_slot1 = wrapBank(reg7, count)
			prg_slot2 = wrapBank(-2, count)
			prg_slot3 = wrapBank(-1, count)
		else
			prg_slot0 = wrapBank(-2, count)
			prg_slot1 = wrapBank(reg7, count)
			prg_slot2 = wrapBank(reg6, count)
			prg_slot3 = wrapBank(-1, count)
		end

		prg_base0 = prg_slot0 * 0x2000
		prg_base1 = prg_slot1 * 0x2000
		prg_base2 = prg_slot2 * 0x2000
		prg_base3 = prg_slot3 * 0x2000
	end

	local function recalc_chr_slots()
		local r0 = bit32.band(reg0, 0xFE)
		local r1 = bit32.band(reg1, 0xFE)
		local r2 = reg2
		local r3 = reg3
		local r4 = reg4
		local r5 = reg5
		local count = chr_total_1k

		if chr_mode == 0 then
			chr_slot0 = wrapBank(r0, count)
			chr_slot1 = wrapBank(r0 + 1, count)
			chr_slot2 = wrapBank(r1, count)
			chr_slot3 = wrapBank(r1 + 1, count)
			chr_slot4 = wrapBank(r2, count)
			chr_slot5 = wrapBank(r3, count)
			chr_slot6 = wrapBank(r4, count)
			chr_slot7 = wrapBank(r5, count)
		else
			chr_slot0 = wrapBank(r2, count)
			chr_slot1 = wrapBank(r3, count)
			chr_slot2 = wrapBank(r4, count)
			chr_slot3 = wrapBank(r5, count)
			chr_slot4 = wrapBank(r0, count)
			chr_slot5 = wrapBank(r0 + 1, count)
			chr_slot6 = wrapBank(r1, count)
			chr_slot7 = wrapBank(r1 + 1, count)
		end

		chr_base0 = chr_slot0 * 0x0400
		chr_base1 = chr_slot1 * 0x0400
		chr_base2 = chr_slot2 * 0x0400
		chr_base3 = chr_slot3 * 0x0400
		chr_base4 = chr_slot4 * 0x0400
		chr_base5 = chr_slot5 * 0x0400
		chr_base6 = chr_slot6 * 0x0400
		chr_base7 = chr_slot7 * 0x0400
	end

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return 0
		end

		local slot = bit32.rshift(addr - 0x8000, 13)
		if slot == 0 then
			return prg_base0 + bit32.band(addr, 0x1FFF)
		end
		if slot == 1 then
			return prg_base1 + bit32.band(addr, 0x1FFF)
		end
		if slot == 2 then
			return prg_base2 + bit32.band(addr, 0x1FFF)
		end
		return prg_base3 + bit32.band(addr, 0x1FFF)
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

	local function write_cpu(addr: number, value: number)
		addr = bit32.band(addr, 0xFFFF)

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
				set_reg(bank_select, value)
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
				mirroring = if bit32.band(value, 0x01) == 0 then 2 else 3
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
		if prg_ram_available then
			addr = bit32.band(addr, 0xFFFF)
			return if addr >= 0x6000 and addr < 0x8000 then normalizeOffset(addr - 0x6000, prg_ram_size) else nil
		end

		return nil
	end

	local function clock_a12(a12_high: boolean)
		if a12_high then
			if not a12_prev and a12_low_cycles >= 12 then
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

			a12_prev = true
			a12_low_cycles = 0
		else
			a12_prev = false
			a12_low_cycles = math.min(a12_low_cycles + 1, 0x7FFFFFFF)
		end
	end

	local function reset_mapper()
		mirroring = config.initialMirroring

		reg0 = 0
		reg1 = 0
		reg2 = 0
		reg3 = 0
		reg4 = 0
		reg5 = 0
		reg6 = 0
		reg7 = 0

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
		a12_low_cycles = 12

		prg_ram_enabled = prg_ram_available
		prg_ram_write_protect = true
	end

	reset_mapper()

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = write_cpu,
		readPpu = nil,
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

--// MAPPER_004 variants
local function MMC3_VAR(config: MapperConfig)
	local mapper_id = config.id
	local is_mapper_37 = mapper_id == 37
	local is_mapper_47 = mapper_id == 47
	local is_mapper_118 = mapper_id == 118
	local prg_total_8k = atLeastOne(config.prgSize // 0x2000)
	local chr_total_1k = atLeastOne(config.chrSize // 0x0400)
	local prg_ram_size = config.prgRamSize
	local prg_ram_available = prg_ram_size > 0

	local four_screen = config.fourScreen
	local vram_buf = config.vram
	local mirroring = config.initialMirroring

	-- MMC3 bank registers R0-R7
	local reg0 = 0
	local reg1 = 0
	local reg2 = 0
	local reg3 = 0
	local reg4 = 0
	local reg5 = 0
	local reg6 = 0
	local reg7 = 0

	local bank_select = 0
	local prg_mode = 0
	local chr_mode = 0

	-- 4x 8 KiB PRG slots
	local prg_slot0 = 0
	local prg_slot1 = 0
	local prg_slot2 = 0
	local prg_slot3 = 0
	local prg_base0 = 0
	local prg_base1 = 0
	local prg_base2 = 0
	local prg_base3 = 0

	-- 8x 1 KiB CHR slots
	local chr_slot0 = 0
	local chr_slot1 = 0
	local chr_slot2 = 0
	local chr_slot3 = 0
	local chr_slot4 = 0
	local chr_slot5 = 0
	local chr_slot6 = 0
	local chr_slot7 = 0
	local chr_base0 = 0
	local chr_base1 = 0
	local chr_base2 = 0
	local chr_base3 = 0
	local chr_base4 = 0
	local chr_base5 = 0
	local chr_base6 = 0
	local chr_base7 = 0

	local irq_latch = 0
	local irq_counter = 0
	local irq_reload = false
	local irq_enabled = false
	local irq_pending = false

	local a12_prev = false
	-- MMC3 IRQ counter requires A12 low for >= 3 CPU cycles (12 PPU cycles).
	local a12_low_cycles = 12

	local prg_ram_enabled = prg_ram_available
	local prg_ram_write_protect = true
	local selected_block = 0
	local nametable_page0 = 0
	local nametable_page1 = 1
	local nametable_page2 = 0
	local nametable_page3 = 1

	local function apply_variant_prg_bank(page: number): number
		if is_mapper_37 then
			if selected_block <= 2 then
				page = bit32.band(page, 0x07)
			elseif selected_block == 3 then
				page = bit32.bor(bit32.band(page, 0x07), 0x08)
			elseif selected_block == 7 then
				page = bit32.bor(bit32.band(page, 0x07), 0x20)
			else
				page = bit32.bor(bit32.band(page, 0x0F), 0x10)
			end
		elseif is_mapper_47 then
			page = bit32.band(page, 0x0F)
			if selected_block == 1 then
				page = bit32.bor(page, 0x10)
			end
		end

		return wrapBank(page, prg_total_8k)
	end

	local function apply_variant_chr_bank(page: number): number
		if is_mapper_37 then
			if selected_block >= 4 then
				page = bit32.bor(page, 0x80)
			end
		elseif is_mapper_47 then
			page = bit32.band(page, 0x7F)
			if selected_block == 1 then
				page = bit32.bor(page, 0x80)
			end
		end

		return wrapBank(page, chr_total_1k)
	end

	local function reset_txsrom_nametables()
		if mirroring == 3 then
			nametable_page0 = 0
			nametable_page1 = 0
			nametable_page2 = 1
			nametable_page3 = 1
		elseif mirroring == 0 then
			nametable_page0 = 0
			nametable_page1 = 0
			nametable_page2 = 0
			nametable_page3 = 0
		elseif mirroring == 1 then
			nametable_page0 = 1
			nametable_page1 = 1
			nametable_page2 = 1
			nametable_page3 = 1
		else
			nametable_page0 = 0
			nametable_page1 = 1
			nametable_page2 = 0
			nametable_page3 = 1
		end
	end

	local function update_txsrom_nametables(value: number)
		local nametable = bit32.band(bit32.rshift(value, 7), 0x01)

		if chr_mode == 0 then
			if bank_select == 0 then
				nametable_page0 = nametable
				nametable_page1 = nametable
			elseif bank_select == 1 then
				nametable_page2 = nametable
				nametable_page3 = nametable
			end
			return
		end

		if bank_select == 2 then
			nametable_page0 = nametable
		elseif bank_select == 3 then
			nametable_page1 = nametable
		elseif bank_select == 4 then
			nametable_page2 = nametable
		elseif bank_select == 5 then
			nametable_page3 = nametable
		end
	end

	local function set_reg(index: number, value: number)
		if index == 0 then
			reg0 = value
		elseif index == 1 then
			reg1 = value
		elseif index == 2 then
			reg2 = value
		elseif index == 3 then
			reg3 = value
		elseif index == 4 then
			reg4 = value
		elseif index == 5 then
			reg5 = value
		elseif index == 6 then
			reg6 = value
		else
			reg7 = value
		end
	end

	local function recalc_prg_slots()
		if prg_mode == 0 then
			prg_slot0 = apply_variant_prg_bank(reg6)
			prg_slot1 = apply_variant_prg_bank(reg7)
			prg_slot2 = apply_variant_prg_bank(-2)
			prg_slot3 = apply_variant_prg_bank(-1)
		else
			prg_slot0 = apply_variant_prg_bank(-2)
			prg_slot1 = apply_variant_prg_bank(reg7)
			prg_slot2 = apply_variant_prg_bank(reg6)
			prg_slot3 = apply_variant_prg_bank(-1)
		end

		prg_base0 = prg_slot0 * 0x2000
		prg_base1 = prg_slot1 * 0x2000
		prg_base2 = prg_slot2 * 0x2000
		prg_base3 = prg_slot3 * 0x2000
	end

	local function recalc_chr_slots()
		local r0 = bit32.band(reg0, 0xFE)
		local r1 = bit32.band(reg1, 0xFE)
		local r2 = reg2
		local r3 = reg3
		local r4 = reg4
		local r5 = reg5

		if chr_mode == 0 then
			chr_slot0 = apply_variant_chr_bank(r0)
			chr_slot1 = apply_variant_chr_bank(r0 + 1)
			chr_slot2 = apply_variant_chr_bank(r1)
			chr_slot3 = apply_variant_chr_bank(r1 + 1)
			chr_slot4 = apply_variant_chr_bank(r2)
			chr_slot5 = apply_variant_chr_bank(r3)
			chr_slot6 = apply_variant_chr_bank(r4)
			chr_slot7 = apply_variant_chr_bank(r5)
		else
			chr_slot0 = apply_variant_chr_bank(r2)
			chr_slot1 = apply_variant_chr_bank(r3)
			chr_slot2 = apply_variant_chr_bank(r4)
			chr_slot3 = apply_variant_chr_bank(r5)
			chr_slot4 = apply_variant_chr_bank(r0)
			chr_slot5 = apply_variant_chr_bank(r0 + 1)
			chr_slot6 = apply_variant_chr_bank(r1)
			chr_slot7 = apply_variant_chr_bank(r1 + 1)
		end

		chr_base0 = chr_slot0 * 0x0400
		chr_base1 = chr_slot1 * 0x0400
		chr_base2 = chr_slot2 * 0x0400
		chr_base3 = chr_slot3 * 0x0400
		chr_base4 = chr_slot4 * 0x0400
		chr_base5 = chr_slot5 * 0x0400
		chr_base6 = chr_slot6 * 0x0400
		chr_base7 = chr_slot7 * 0x0400
	end

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return 0
		end

		local slot = bit32.rshift(addr - 0x8000, 13)
		if slot == 0 then
			return prg_base0 + bit32.band(addr, 0x1FFF)
		end
		if slot == 1 then
			return prg_base1 + bit32.band(addr, 0x1FFF)
		end
		if slot == 2 then
			return prg_base2 + bit32.band(addr, 0x1FFF)
		end
		return prg_base3 + bit32.band(addr, 0x1FFF)
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

	local function write_cpu(addr: number, value: number)
		addr = bit32.band(addr, 0xFFFF)

		if (is_mapper_37 or is_mapper_47) and addr < 0x8000 then
			if prg_ram_enabled and not prg_ram_write_protect then
				selected_block = bit32.band(value, if is_mapper_37 then 0x07 else 0x01)
				recalc_prg_slots()
				recalc_chr_slots()
			end
			return
		end

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
				if is_mapper_118 then
					update_txsrom_nametables(value)
				end
				set_reg(bank_select, value)
				if bank_select <= 5 then
					recalc_chr_slots()
				else
					recalc_prg_slots()
				end
			end
			return
		end

		if addr < 0xC000 then
			if even and not four_screen and not is_mapper_118 then
				mirroring = if bit32.band(value, 0x01) == 0 then 2 else 3
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
		if prg_ram_available then
			addr = bit32.band(addr, 0xFFFF)
			return if addr >= 0x6000 and addr < 0x8000 then normalizeOffset(addr - 0x6000, prg_ram_size) else nil
		end

		return nil
	end

	local function read_nametable(addr: number): number?
		if vram_buf then
			local offset = bit32.band(addr, 0x0FFF)
			local nt = bit32.rshift(offset, 10)
			local inner = bit32.band(offset, 0x03FF)
			local page = if nt == 0 then nametable_page0 elseif nt == 1 then nametable_page1 elseif nt == 2 then nametable_page2 else nametable_page3
			return buffer.readu8(vram_buf, page * 0x400 + inner)
		end

		return nil
	end

	local function write_nametable(addr: number, value: number): boolean
		if vram_buf then
			local offset = bit32.band(addr, 0x0FFF)
			local nt = bit32.rshift(offset, 10)
			local inner = bit32.band(offset, 0x03FF)
			local page = if nt == 0 then nametable_page0 elseif nt == 1 then nametable_page1 elseif nt == 2 then nametable_page2 else nametable_page3
			buffer.writeu8(vram_buf, page * 0x400 + inner, value)
			return true
		end

		return false
	end

	local function clock_a12(a12_high: boolean)
		if a12_high then
			if not a12_prev and a12_low_cycles >= 12 then
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

			a12_prev = true
			a12_low_cycles = 0
		else
			a12_prev = false
			a12_low_cycles = math.min(a12_low_cycles + 1, 0x7FFFFFFF)
		end
	end

	local function reset_mapper()
		mirroring = config.initialMirroring

		reg0 = 0
		reg1 = 0
		reg2 = 0
		reg3 = 0
		reg4 = 0
		reg5 = 0
		reg6 = 0
		reg7 = 0

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
		a12_low_cycles = 12

		prg_ram_enabled = prg_ram_available
		prg_ram_write_protect = true
		selected_block = 0
		if is_mapper_118 then
			reset_txsrom_nametables()
		end
	end

	reset_mapper()

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = write_cpu,
		readPpu = nil,
		readCpu = nil,
		readNametable = if is_mapper_118 then read_nametable else nil,
		writeNametable = if is_mapper_118 then write_nametable else nil,
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
local function MMC5(config: MapperConfig)
	local four_screen = config.fourScreen
	local vram_buf = config.vram

	local prg_total_8k = atLeastOne(config.prgSize // 0x2000)
	local prg_total_16k = atLeastOne(prg_total_8k // 2)
	local prg_total_32k = atLeastOne(prg_total_8k // 4)
	local chr_total_1k = atLeastOne(config.chrSize // 0x0400)
	local chr_total_bytes = chr_total_1k * 0x0400

	local prg_ram_size = config.prgRamSize
	local prg_ram_available = prg_ram_size > 0
	local prg_ram_total_8k = atLeastOne(prg_ram_size // 0x2000)
	local prg_ram_total_16k = atLeastOne(prg_ram_size // 0x4000)

	local mirroring = config.initialMirroring

	local mmc5_prg_mode = 3
	local mmc5_chr_mode = 3
	local mmc5_prg_regs = buffer.create(4)
	local mmc5_chr_regs = buffer.create(12 * 2)
	local mmc5_chr_high = 0
	local mmc5_last_chr_reg = 0x5120

	local mmc5_exram_mode = 0
	local mmc5_nt_map = buffer.create(4)
	local mmc5_exram = buffer.create(0x400)
	local mmc5_fill_tile = 0
	local mmc5_fill_attr = 0

	local mmc5_ram_protect_0 = 0
	local mmc5_ram_protect_1 = 0
	local mmc5_prg_ram_bank = 0

	local mmc5_mul_a = 0
	local mmc5_mul_b = 0

	local mmc5_split_control = 0
	local mmc5_split_scroll = 0
	local mmc5_split_bank = 0
	local mmc5_split_in_region = false
	local mmc5_split_vertical_scroll = 0
	local mmc5_split_tile = 0
	local mmc5_split_tile_number = 0

	local mmc5_irq_line = 0
	local mmc5_irq_enabled = false
	local mmc5_irq_pending = false
	local mmc5_scanline_counter = 0
	local mmc5_in_frame = false
	local mmc5_need_in_frame = false
	local mmc5_last_ppu_read_addr = -1
	local mmc5_last_ppu_read_scanline = -1
	local mmc5_last_ppu_read_cycle = -1
	local mmc5_nt_read_counter = 0

	local mmc5_exattr_last_nt_fetch = 0
	local mmc5_exattr_fetch_counter = 0
	local mmc5_exattr_selected_chr_bank = 0

	local mmc5_prg_base_mode0 = 0
	local mmc5_prg_base_mode1_low = 0
	local mmc5_prg_base_mode1_high = 0
	local mmc5_prg_base_mode2_low = 0
	local mmc5_prg_base_mode2_mid = 0
	local mmc5_prg_base_mode2_high = 0
	local mmc5_prg_base_slot0 = 0
	local mmc5_prg_base_slot1 = 0
	local mmc5_prg_base_slot2 = 0
	local mmc5_prg_base_slot3 = 0

	local mmc5_prg_ram_base_6000 = 0
	local mmc5_prg_reg0_maps_ram = false
	local mmc5_prg_reg1_maps_ram = false
	local mmc5_prg_reg2_maps_ram = false
	local mmc5_prg_ram_reg0_base_8k = 0
	local mmc5_prg_ram_reg1_base_8k = 0
	local mmc5_prg_ram_reg2_base_8k = 0
	local mmc5_prg_ram_reg1_base_16k = 0

	local mmc5_chr_set_a_base0 = 0
	local mmc5_chr_set_a_base1 = 0
	local mmc5_chr_set_a_base2 = 0
	local mmc5_chr_set_a_base3 = 0
	local mmc5_chr_set_a_base4 = 0
	local mmc5_chr_set_a_base5 = 0
	local mmc5_chr_set_a_base6 = 0
	local mmc5_chr_set_a_base7 = 0
	local mmc5_chr_set_b_base0 = 0
	local mmc5_chr_set_b_base1 = 0
	local mmc5_chr_set_b_base2 = 0
	local mmc5_chr_set_b_base3 = 0
	local mmc5_chr_set_b_base4 = 0
	local mmc5_chr_set_b_base5 = 0
	local mmc5_chr_set_b_base6 = 0
	local mmc5_chr_set_b_base7 = 0

	local function recalc_mmc5_prg_slots()
		local reg0 = buffer.readu8(mmc5_prg_regs, 0)
		local reg1 = buffer.readu8(mmc5_prg_regs, 1)
		local reg2 = buffer.readu8(mmc5_prg_regs, 2)
		local reg3 = buffer.readu8(mmc5_prg_regs, 3)

		local bank8_0 = wrapBank(bit32.band(reg0, 0x7F), prg_total_8k)
		local bank8_1 = wrapBank(bit32.band(reg1, 0x7F), prg_total_8k)
		local bank8_2 = wrapBank(bit32.band(reg2, 0x7F), prg_total_8k)
		local bank8_3 = wrapBank(bit32.band(reg3, 0x7F), prg_total_8k)

		mmc5_prg_base_mode0 = wrapBank(bit32.rshift(bank8_3, 2), prg_total_32k) * 0x8000
		mmc5_prg_base_mode1_low = wrapBank(bit32.rshift(bank8_1, 1), prg_total_16k) * 0x4000
		mmc5_prg_base_mode1_high = wrapBank(bit32.rshift(bank8_3, 1), prg_total_16k) * 0x4000
		mmc5_prg_base_mode2_low = mmc5_prg_base_mode1_low
		mmc5_prg_base_mode2_mid = bank8_2 * 0x2000
		mmc5_prg_base_mode2_high = bank8_3 * 0x2000
		mmc5_prg_base_slot0 = bank8_0 * 0x2000
		mmc5_prg_base_slot1 = bank8_1 * 0x2000
		mmc5_prg_base_slot2 = bank8_2 * 0x2000
		mmc5_prg_base_slot3 = bank8_3 * 0x2000

		mmc5_prg_reg0_maps_ram = not bit32.btest(reg0, 0x80)
		mmc5_prg_reg1_maps_ram = not bit32.btest(reg1, 0x80)
		mmc5_prg_reg2_maps_ram = not bit32.btest(reg2, 0x80)
		mmc5_prg_ram_reg0_base_8k = wrapBank(bit32.band(reg0, 0x7F), prg_ram_total_8k) * 0x2000
		mmc5_prg_ram_reg1_base_8k = wrapBank(bit32.band(reg1, 0x7F), prg_ram_total_8k) * 0x2000
		mmc5_prg_ram_reg2_base_8k = wrapBank(bit32.band(reg2, 0x7F), prg_ram_total_8k) * 0x2000
		mmc5_prg_ram_reg1_base_16k = wrapBank(bit32.rshift(bit32.band(reg1, 0x7F), 1), prg_ram_total_16k) * 0x4000
		mmc5_prg_ram_base_6000 = wrapBank(mmc5_prg_ram_bank, prg_ram_total_8k) * 0x2000
	end

	local function mmc5_wrap_chr_base(bank_1k: number): number
		return wrapBank(bank_1k, chr_total_1k) * 0x0400
	end

	local function recalc_mmc5_chr_slots()
		local r0 = buffer.readu16(mmc5_chr_regs, 0)
		local r1 = buffer.readu16(mmc5_chr_regs, 2)
		local r2 = buffer.readu16(mmc5_chr_regs, 4)
		local r3 = buffer.readu16(mmc5_chr_regs, 6)
		local r4 = buffer.readu16(mmc5_chr_regs, 8)
		local r5 = buffer.readu16(mmc5_chr_regs, 10)
		local r6 = buffer.readu16(mmc5_chr_regs, 12)
		local r7 = buffer.readu16(mmc5_chr_regs, 14)
		local r8 = buffer.readu16(mmc5_chr_regs, 16)
		local r9 = buffer.readu16(mmc5_chr_regs, 18)
		local r10 = buffer.readu16(mmc5_chr_regs, 20)
		local r11 = buffer.readu16(mmc5_chr_regs, 22)

		if mmc5_chr_mode == 0 then
			local a = r7 * 8
			local b = r11 * 8
			mmc5_chr_set_a_base0 = mmc5_wrap_chr_base(a)
			mmc5_chr_set_a_base1 = mmc5_wrap_chr_base(a + 1)
			mmc5_chr_set_a_base2 = mmc5_wrap_chr_base(a + 2)
			mmc5_chr_set_a_base3 = mmc5_wrap_chr_base(a + 3)
			mmc5_chr_set_a_base4 = mmc5_wrap_chr_base(a + 4)
			mmc5_chr_set_a_base5 = mmc5_wrap_chr_base(a + 5)
			mmc5_chr_set_a_base6 = mmc5_wrap_chr_base(a + 6)
			mmc5_chr_set_a_base7 = mmc5_wrap_chr_base(a + 7)
			mmc5_chr_set_b_base0 = mmc5_wrap_chr_base(b)
			mmc5_chr_set_b_base1 = mmc5_wrap_chr_base(b + 1)
			mmc5_chr_set_b_base2 = mmc5_wrap_chr_base(b + 2)
			mmc5_chr_set_b_base3 = mmc5_wrap_chr_base(b + 3)
			mmc5_chr_set_b_base4 = mmc5_wrap_chr_base(b + 4)
			mmc5_chr_set_b_base5 = mmc5_wrap_chr_base(b + 5)
			mmc5_chr_set_b_base6 = mmc5_wrap_chr_base(b + 6)
			mmc5_chr_set_b_base7 = mmc5_wrap_chr_base(b + 7)
			return
		end

		if mmc5_chr_mode == 1 then
			local a_low = r3 * 4
			local a_high = r7 * 4
			local b = r11 * 4
			mmc5_chr_set_a_base0 = mmc5_wrap_chr_base(a_low)
			mmc5_chr_set_a_base1 = mmc5_wrap_chr_base(a_low + 1)
			mmc5_chr_set_a_base2 = mmc5_wrap_chr_base(a_low + 2)
			mmc5_chr_set_a_base3 = mmc5_wrap_chr_base(a_low + 3)
			mmc5_chr_set_a_base4 = mmc5_wrap_chr_base(a_high)
			mmc5_chr_set_a_base5 = mmc5_wrap_chr_base(a_high + 1)
			mmc5_chr_set_a_base6 = mmc5_wrap_chr_base(a_high + 2)
			mmc5_chr_set_a_base7 = mmc5_wrap_chr_base(a_high + 3)
			mmc5_chr_set_b_base0 = mmc5_wrap_chr_base(b)
			mmc5_chr_set_b_base1 = mmc5_wrap_chr_base(b + 1)
			mmc5_chr_set_b_base2 = mmc5_wrap_chr_base(b + 2)
			mmc5_chr_set_b_base3 = mmc5_wrap_chr_base(b + 3)
			mmc5_chr_set_b_base4 = mmc5_wrap_chr_base(b)
			mmc5_chr_set_b_base5 = mmc5_wrap_chr_base(b + 1)
			mmc5_chr_set_b_base6 = mmc5_wrap_chr_base(b + 2)
			mmc5_chr_set_b_base7 = mmc5_wrap_chr_base(b + 3)
			return
		end

		if mmc5_chr_mode == 2 then
			local a1 = r1 * 2
			local a3 = r3 * 2
			local a5 = r5 * 2
			local a7 = r7 * 2
			local b9 = r9 * 2
			local b11 = r11 * 2
			mmc5_chr_set_a_base0 = mmc5_wrap_chr_base(a1)
			mmc5_chr_set_a_base1 = mmc5_wrap_chr_base(a1 + 1)
			mmc5_chr_set_a_base2 = mmc5_wrap_chr_base(a3)
			mmc5_chr_set_a_base3 = mmc5_wrap_chr_base(a3 + 1)
			mmc5_chr_set_a_base4 = mmc5_wrap_chr_base(a5)
			mmc5_chr_set_a_base5 = mmc5_wrap_chr_base(a5 + 1)
			mmc5_chr_set_a_base6 = mmc5_wrap_chr_base(a7)
			mmc5_chr_set_a_base7 = mmc5_wrap_chr_base(a7 + 1)
			mmc5_chr_set_b_base0 = mmc5_wrap_chr_base(b9)
			mmc5_chr_set_b_base1 = mmc5_wrap_chr_base(b9 + 1)
			mmc5_chr_set_b_base2 = mmc5_wrap_chr_base(b11)
			mmc5_chr_set_b_base3 = mmc5_wrap_chr_base(b11 + 1)
			mmc5_chr_set_b_base4 = mmc5_wrap_chr_base(b9)
			mmc5_chr_set_b_base5 = mmc5_wrap_chr_base(b9 + 1)
			mmc5_chr_set_b_base6 = mmc5_wrap_chr_base(b11)
			mmc5_chr_set_b_base7 = mmc5_wrap_chr_base(b11 + 1)
			return
		end

		mmc5_chr_set_a_base0 = mmc5_wrap_chr_base(r0)
		mmc5_chr_set_a_base1 = mmc5_wrap_chr_base(r1)
		mmc5_chr_set_a_base2 = mmc5_wrap_chr_base(r2)
		mmc5_chr_set_a_base3 = mmc5_wrap_chr_base(r3)
		mmc5_chr_set_a_base4 = mmc5_wrap_chr_base(r4)
		mmc5_chr_set_a_base5 = mmc5_wrap_chr_base(r5)
		mmc5_chr_set_a_base6 = mmc5_wrap_chr_base(r6)
		mmc5_chr_set_a_base7 = mmc5_wrap_chr_base(r7)
		mmc5_chr_set_b_base0 = mmc5_wrap_chr_base(r8)
		mmc5_chr_set_b_base1 = mmc5_wrap_chr_base(r9)
		mmc5_chr_set_b_base2 = mmc5_wrap_chr_base(r10)
		mmc5_chr_set_b_base3 = mmc5_wrap_chr_base(r11)
		mmc5_chr_set_b_base4 = mmc5_wrap_chr_base(r8)
		mmc5_chr_set_b_base5 = mmc5_wrap_chr_base(r9)
		mmc5_chr_set_b_base6 = mmc5_wrap_chr_base(r10)
		mmc5_chr_set_b_base7 = mmc5_wrap_chr_base(r11)
	end

	local function mmc5_set_chr_reg(reg_index: number, value: number)
		buffer.writeu16(
			mmc5_chr_regs,
			reg_index * 2,
			value + mmc5_chr_high * 256
		)
		recalc_mmc5_chr_slots()
	end

	local function mmc5_prg_ram_offset(addr: number): number?
		if not prg_ram_available then
			return nil
		end

		if addr >= 0x6000 and addr < 0x8000 then
			return mmc5_prg_ram_base_6000 + bit32.band(addr - 0x6000, 0x1FFF)
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

			if mmc5_prg_reg1_maps_ram then
				return mmc5_prg_ram_reg1_base_16k + bit32.band(addr - 0x8000, 0x3FFF)
			end

			return nil
		end

		if mmc5_prg_mode == 2 then
			if addr < 0xC000 then
				if mmc5_prg_reg1_maps_ram then
					return mmc5_prg_ram_reg1_base_16k + bit32.band(addr - 0x8000, 0x3FFF)
				end

				return nil
			end

			if mmc5_prg_reg2_maps_ram then
				return mmc5_prg_ram_reg2_base_8k + bit32.band(addr - 0xC000, 0x1FFF)
			end

			return nil
		end

		local slot = bit32.rshift(addr - 0x8000, 13)
		if slot >= 3 then
			return nil
		end

		if slot == 0 then
			return if mmc5_prg_reg0_maps_ram then mmc5_prg_ram_reg0_base_8k + bit32.band(addr, 0x1FFF) else nil
		end
		if slot == 1 then
			return if mmc5_prg_reg1_maps_ram then mmc5_prg_ram_reg1_base_8k + bit32.band(addr, 0x1FFF) else nil
		end
		return if mmc5_prg_reg2_maps_ram then mmc5_prg_ram_reg2_base_8k + bit32.band(addr, 0x1FFF) else nil
	end

	local function update_mmc5_simple_mirroring()
		if four_screen then
			return
		end

		local n0 = buffer.readu8(mmc5_nt_map, 0)
		local n1 = buffer.readu8(mmc5_nt_map, 1)
		local n2 = buffer.readu8(mmc5_nt_map, 2)
		local n3 = buffer.readu8(mmc5_nt_map, 3)

		if n0 == n1 and n2 == n3 and n0 ~= n2 then
			mirroring = 3
		elseif n0 == n2 and n1 == n3 and n0 ~= n1 then
			mirroring = 2
		elseif n0 == n1 and n1 == n2 and n2 == n3 then
			mirroring = if n0 == 1 then 1 else 0
		end
	end

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return 0
		end

		if mmc5_prg_mode == 0 then
			return mmc5_prg_base_mode0 + bit32.band(addr - 0x8000, 0x7FFF)
		end

		if mmc5_prg_mode == 1 then
			if addr < 0xC000 then
				return mmc5_prg_base_mode1_low + bit32.band(addr - 0x8000, 0x3FFF)
			end

			return mmc5_prg_base_mode1_high + bit32.band(addr, 0x3FFF)
		end

		if mmc5_prg_mode == 2 then
			if addr < 0xC000 then
				return mmc5_prg_base_mode2_low + bit32.band(addr - 0x8000, 0x3FFF)
			end

			if addr < 0xE000 then
				return mmc5_prg_base_mode2_mid + bit32.band(addr, 0x1FFF)
			end

			return mmc5_prg_base_mode2_high + bit32.band(addr, 0x1FFF)
		end

		local slot = bit32.rshift(addr - 0x8000, 13)
		if slot == 0 then
			return mmc5_prg_base_slot0 + bit32.band(addr, 0x1FFF)
		end
		if slot == 1 then
			return mmc5_prg_base_slot1 + bit32.band(addr, 0x1FFF)
		end
		if slot == 2 then
			return mmc5_prg_base_slot2 + bit32.band(addr, 0x1FFF)
		end
		return mmc5_prg_base_slot3 + bit32.band(addr, 0x1FFF)
	end

	local function map_chr_addr(addr: number, fetch_kind: number?, sprite_16: boolean?): number
		addr = bit32.band(addr, 0x1FFF)
		local kind = fetch_kind or 0

		if kind == 1 and mmc5_exram_mode <= 1 and mmc5_in_frame and bit32.btest(mmc5_split_control, 0x80) and mmc5_split_in_region then
			local split_addr = bit32.band(mmc5_split_bank, 0x3F) * 0x1000
			split_addr += bit32.band(
				bit32.bor(bit32.band(addr, 0x1FF8), bit32.band(mmc5_split_vertical_scroll, 0x07)),
				0x0FFF
			)
			return normalizeOffset(split_addr, chr_total_bytes)
		end

		if kind == 1
			and mmc5_exram_mode == 1
			and mmc5_in_frame
			and (mmc5_split_tile_number < 32 or mmc5_split_tile_number >= 40)
			and mmc5_exattr_fetch_counter > 0
			and mmc5_exattr_fetch_counter <= 2
		then
			mmc5_exattr_fetch_counter -= 1
			local ex_attr_addr = bit32.band(mmc5_exattr_selected_chr_bank, 0xFF) * 0x1000
				+ bit32.band(addr, 0x0FFF)
			return normalizeOffset(ex_attr_addr, chr_total_bytes)
		end

		local segment = bit32.rshift(addr, 10)
		local inner = bit32.band(addr, 0x03FF)
		local use_set_b = false
		if sprite_16 == true then
			if kind == 2 then
				-- 8x16 sprite pattern fetch phase: use set A.
				use_set_b = false
			elseif kind == 1 then
				-- Background pattern fetch phase: use set B.
				use_set_b = true
			else
				-- Non-render/unknown fetch context: fall back to last-known MMC5 phase heuristic.
				use_set_b = not (
					(mmc5_split_tile_number >= 32 and mmc5_split_tile_number < 40)
						or ((not mmc5_in_frame) and mmc5_last_chr_reg <= 0x5127)
				)
			end
		end

		if use_set_b then
			if segment == 0 then
				return mmc5_chr_set_b_base0 + inner
			end
			if segment == 1 then
				return mmc5_chr_set_b_base1 + inner
			end
			if segment == 2 then
				return mmc5_chr_set_b_base2 + inner
			end
			if segment == 3 then
				return mmc5_chr_set_b_base3 + inner
			end
			if segment == 4 then
				return mmc5_chr_set_b_base4 + inner
			end
			if segment == 5 then
				return mmc5_chr_set_b_base5 + inner
			end
			if segment == 6 then
				return mmc5_chr_set_b_base6 + inner
			end
			return mmc5_chr_set_b_base7 + inner
		end

		if segment == 0 then
			return mmc5_chr_set_a_base0 + inner
		end
		if segment == 1 then
			return mmc5_chr_set_a_base1 + inner
		end
		if segment == 2 then
			return mmc5_chr_set_a_base2 + inner
		end
		if segment == 3 then
			return mmc5_chr_set_a_base3 + inner
		end
		if segment == 4 then
			return mmc5_chr_set_a_base4 + inner
		end
		if segment == 5 then
			return mmc5_chr_set_a_base5 + inner
		end
		if segment == 6 then
			return mmc5_chr_set_a_base6 + inner
		end
		return mmc5_chr_set_a_base7 + inner
	end

	local function write_cpu(addr: number, value: number)
		addr = bit32.band(addr, 0xFFFF)

		if addr >= 0x5C00 and addr <= 0x5FFF then
			local index = bit32.band(addr - 0x5C00, 0x03FF)
			if mmc5_exram_mode == 2 then
				buffer.writeu8(mmc5_exram, index, value)
			elseif mmc5_exram_mode <= 1 then
				local write_value = if mmc5_in_frame then value else 0
				buffer.writeu8(mmc5_exram, index, write_value)
			end
			return
		end

		if addr == 0x5100 then
			mmc5_prg_mode = bit32.band(value, 0x03)
			return
		end
		if addr == 0x5101 then
			mmc5_chr_mode = bit32.band(value, 0x03)
			recalc_mmc5_chr_slots()
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
				buffer.writeu8(mmc5_nt_map, i, bit32.band(bit32.rshift(value, i * 2), 0x03))
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
			recalc_mmc5_prg_slots()
			return
		end
		if addr >= 0x5114 and addr <= 0x5117 then
			buffer.writeu8(mmc5_prg_regs, addr - 0x5114, value)
			recalc_mmc5_prg_slots()
			return
		end
		if addr >= 0x5120 and addr <= 0x5127 then
			mmc5_set_chr_reg(addr - 0x5120, value)
			mmc5_last_chr_reg = addr
			return
		end
		if addr >= 0x5128 and addr <= 0x512B then
			local idx = addr - 0x5128
			mmc5_set_chr_reg(8 + idx, value)
			mmc5_last_chr_reg = addr
			return
		end
		if addr == 0x5130 then
			mmc5_chr_high = bit32.band(value, 0x03)
			return
		end
		if addr == 0x5200 then
			mmc5_split_control = value
			return
		end
		if addr == 0x5201 then
			mmc5_split_scroll = value
			return
		end
		if addr == 0x5202 then
			mmc5_split_bank = value
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
			if mmc5_exram_mode >= 2 then
				return buffer.readu8(mmc5_exram, bit32.band(addr - 0x5C00, 0x03FF))
			end
			return nil
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
			return bit32.rshift(mmc5_mul_a * mmc5_mul_b, 8)
		end

		return nil
	end

	local function read_nametable(addr: number): number?
		if vram_buf == nil then
			return nil
		end

		local offset = bit32.band(addr, 0x0FFF)
		local nt = bit32.rshift(offset, 10)
		local inner = bit32.band(offset, 0x03FF)
		local source = buffer.readu8(mmc5_nt_map, nt)
		local is_nt_fetch = inner < 0x03C0

		if mmc5_exram_mode <= 1 and mmc5_in_frame then
			if bit32.btest(mmc5_split_control, 0x80) then
				local split_scanline = if mmc5_split_tile_number >= 41 then mmc5_scanline_counter + 1 else mmc5_scanline_counter
				mmc5_split_vertical_scroll = (split_scanline + mmc5_split_scroll) % 240
				local column = (mmc5_split_tile_number + 2) % 42

				if is_nt_fetch then
					if column == 0 then
						mmc5_split_in_region = not bit32.btest(mmc5_split_control, 0x40)
					end

					if column == bit32.band(mmc5_split_control, 0x1F) and mmc5_split_tile_number < 42 then
						mmc5_split_in_region = not mmc5_split_in_region
					elseif column > 32 then
						mmc5_split_in_region = false
					end

					if mmc5_split_in_region then
						mmc5_split_tile = bit32.band(
							bit32.bor(
								bit32.band(mmc5_split_vertical_scroll, 0xF8) * 4,
								column
							),
							0x03FF
						)
						return buffer.readu8(mmc5_exram, mmc5_split_tile)
					end
				elseif mmc5_split_in_region then
					local shift = bit32.bor(
						bit32.band(bit32.rshift(mmc5_split_tile, 4), 0x04),
						bit32.band(mmc5_split_tile, 0x02)
					)
					local at_addr = bit32.bor(
						0x03C0,
						bit32.rshift(bit32.band(mmc5_split_tile, 0x0380), 4),
						bit32.rshift(bit32.band(mmc5_split_tile, 0x001F), 2)
					)
					local palette_bits = bit32.band(bit32.rshift(buffer.readu8(mmc5_exram, at_addr), shift), 0x03)
					return palette_bits * 0x55
				end
			end

			if mmc5_exram_mode == 1 and (mmc5_split_tile_number < 32 or mmc5_split_tile_number >= 40) then
				if is_nt_fetch then
					mmc5_exattr_last_nt_fetch = inner
					mmc5_exattr_fetch_counter = 3
				elseif mmc5_exattr_fetch_counter > 0 then
					mmc5_exattr_fetch_counter -= 1
					if mmc5_exattr_fetch_counter == 2 then
						local ex_value = buffer.readu8(mmc5_exram, mmc5_exattr_last_nt_fetch)
						mmc5_exattr_selected_chr_bank = bit32.bor(
							bit32.band(ex_value, 0x3F),
							mmc5_chr_high * 64
						)
						local palette_bits = bit32.band(bit32.rshift(ex_value, 6), 0x03)
						return palette_bits * 0x55
					end
				end
			end
		end

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

		return mmc5_fill_attr * 0x55
	end

	local function write_nametable(addr: number, value: number): boolean
		if vram_buf == nil then
			return false
		end

		local offset = bit32.band(addr, 0x0FFF)
		local nt = bit32.rshift(offset, 10)
		local inner = bit32.band(offset, 0x03FF)
		local source = buffer.readu8(mmc5_nt_map, nt)
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

	local function mmc5_detect_scanline_start(addr: number)
		if mmc5_nt_read_counter >= 2 then
			if not mmc5_in_frame and not mmc5_need_in_frame then
				mmc5_need_in_frame = true
				mmc5_scanline_counter = 0
			else
				mmc5_scanline_counter = bit32.band(mmc5_scanline_counter + 1, 0xFF)
				if mmc5_scanline_counter == mmc5_irq_line then
					mmc5_irq_pending = true
				end
			end
		elseif addr >= 0x2000 and addr <= 0x2FFF and mmc5_last_ppu_read_addr == addr then
			mmc5_nt_read_counter += 1
			if mmc5_nt_read_counter >= 2 then
				mmc5_split_tile_number = 0
			end
		end

		if mmc5_last_ppu_read_addr ~= addr then
			mmc5_nt_read_counter = 0
		end
	end

	local function clock_scanline(scanline_value: number?)
		if scanline_value == nil then
			return
		end

		if scanline_value >= 240 and scanline_value <= 261 then
			mmc5_in_frame = false
			mmc5_need_in_frame = false
			mmc5_nt_read_counter = 0
			mmc5_split_in_region = false
			mmc5_exattr_fetch_counter = 0
			mmc5_last_ppu_read_addr = -1
			mmc5_last_ppu_read_scanline = -1
			mmc5_last_ppu_read_cycle = -1
			mmc5_split_tile_number = 0
		end

		if scanline_value == 261 then
			mmc5_scanline_counter = 0
		end
	end

	local mmc5_dots_per_scanline = 341
	local mmc5_dots_per_frame = 262 * mmc5_dots_per_scanline

	local function on_ppu_address(addr: number, scanline: number, cycle: number, rendering: boolean)
		if mmc5_last_ppu_read_scanline >= 0 and mmc5_last_ppu_read_cycle >= 1 then
			local prev_dot = mmc5_last_ppu_read_scanline * mmc5_dots_per_scanline + mmc5_last_ppu_read_cycle
			local curr_dot = scanline * mmc5_dots_per_scanline + cycle
			local dot_delta = curr_dot - prev_dot
			if dot_delta < 0 then
				dot_delta += mmc5_dots_per_frame
			end

			-- 3 CPU cycles ~= 9 PPU dots.
			if dot_delta >= 9 then
				mmc5_in_frame = false
				mmc5_need_in_frame = false
				mmc5_split_in_region = false
				mmc5_exattr_fetch_counter = 0
				mmc5_nt_read_counter = 0
				mmc5_last_ppu_read_addr = -1
			end
		end

		mmc5_last_ppu_read_scanline = scanline
		mmc5_last_ppu_read_cycle = cycle

		if not rendering then
			mmc5_split_in_region = false
			mmc5_exattr_fetch_counter = 0
			mmc5_nt_read_counter = 0
			mmc5_last_ppu_read_addr = addr
			return
		end

		if scanline >= 240 and scanline ~= 261 then
			return
		end

		if cycle < 1 or cycle > 340 then
			return
		end

		local is_nt_fetch = addr >= 0x2000 and addr <= 0x2FFF and bit32.band(addr, 0x03FF) < 0x03C0
		if is_nt_fetch then
			mmc5_split_tile_number += 1
			if mmc5_need_in_frame then
				mmc5_need_in_frame = false
				mmc5_in_frame = true
			end
		end

		mmc5_detect_scanline_start(addr)
		mmc5_last_ppu_read_addr = addr
	end

	local function reset_mapper()
		mirroring = config.initialMirroring

		mmc5_prg_mode = 3
		mmc5_chr_mode = 3

		buffer.fill(mmc5_prg_regs, 0, 0, 4)
		buffer.fill(mmc5_chr_regs, 0, 0, 12 * 2)
		recalc_mmc5_chr_slots()

		mmc5_chr_high = 0
		mmc5_last_chr_reg = 0x5120
		mmc5_exram_mode = 0

		buffer.writeu8(mmc5_nt_map, 0, 0)
		buffer.writeu8(mmc5_nt_map, 1, 1)
		buffer.writeu8(mmc5_nt_map, 2, 0)
		buffer.writeu8(mmc5_nt_map, 3, 1)

		buffer.fill(mmc5_exram, 0, 0, 0x400)
		mmc5_fill_tile = 0
		mmc5_fill_attr = 0

		mmc5_ram_protect_0 = 0
		mmc5_ram_protect_1 = 0
		mmc5_prg_ram_bank = 0

		mmc5_mul_a = 0
		mmc5_mul_b = 0

		mmc5_split_control = 0
		mmc5_split_scroll = 0
		mmc5_split_bank = 0
		mmc5_split_in_region = false
		mmc5_split_vertical_scroll = 0
		mmc5_split_tile = 0
		mmc5_split_tile_number = 0

		mmc5_irq_line = 0
		mmc5_irq_enabled = false
		mmc5_irq_pending = false
		mmc5_scanline_counter = 0
		mmc5_in_frame = false
		mmc5_need_in_frame = false
		mmc5_last_ppu_read_addr = -1
		mmc5_last_ppu_read_scanline = -1
		mmc5_last_ppu_read_cycle = -1
		mmc5_nt_read_counter = 0

		mmc5_exattr_last_nt_fetch = 0
		mmc5_exattr_fetch_counter = 0
		mmc5_exattr_selected_chr_bank = 0

		buffer.writeu8(mmc5_prg_regs, 0, 0x80)
		buffer.writeu8(mmc5_prg_regs, 1, 0x80)
		buffer.writeu8(mmc5_prg_regs, 2, 0x80)
		buffer.writeu8(mmc5_prg_regs, 3, 0xFF)
		recalc_mmc5_prg_slots()

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
local function AOROM(config: MapperConfig)
	local prg_banks_32k = atLeastOne(config.prgSize // 0x8000)
	local four_screen = config.fourScreen
	local bank_select = 0
	local mirroring = if four_screen then 2 else 0

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

		bank_select = wrapBank(bit32.band(value, 0x07), prg_banks_32k)

		if not four_screen then
			mirroring = if bit32.btest(value, 0x10) then 1 else 0
		end
	end

	local function reset_mapper()
		bank_select = 0
		mirroring = if four_screen then 2 else 0
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
		irqPending = nil,
		clearIrq = function() end,
		getMirroring = function(): number
			return mirroring
		end,
		prgRamReadable = nil,
		prgRamWritable = nil,
	}
end

--// MAPPER_009
local function MMC2(config: MapperConfig)
	local prg_total_8k = atLeastOne(config.prgSize // 0x2000)
	local chr_total_4k = atLeastOne(config.chrSize // 0x1000)
	local mirroring = config.initialMirroring

	local prg_bank = 0
	local prg_base_8000 = 0
	local prg_base_A000 = wrapBank(prg_total_8k - 3, prg_total_8k) * 0x2000
	local prg_base_C000 = wrapBank(prg_total_8k - 2, prg_total_8k) * 0x2000
	local prg_base_E000 = wrapBank(prg_total_8k - 1, prg_total_8k) * 0x2000

	local chr_fd_0 = 0
	local chr_fe_0 = 0
	local chr_fd_1 = 0
	local chr_fe_1 = 0
	local chr_fd_0_base = 0
	local chr_fe_0_base = 0
	local chr_fd_1_base = 0
	local chr_fe_1_base = 0

	local latch0_fe = false
	local latch1_fe = false

	local function recalc_prg_base_8000()
		prg_base_8000 = wrapBank(prg_bank, prg_total_8k) * 0x2000
	end

	local function recalc_chr_bases()
		chr_fd_0_base = wrapBank(chr_fd_0, chr_total_4k) * 0x1000
		chr_fe_0_base = wrapBank(chr_fe_0, chr_total_4k) * 0x1000
		chr_fd_1_base = wrapBank(chr_fd_1, chr_total_4k) * 0x1000
		chr_fe_1_base = wrapBank(chr_fe_1, chr_total_4k) * 0x1000
	end

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return 0
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
		local mapped_base = 0

		if addr < 0x1000 then
			mapped_base = if latch0_fe then chr_fe_0_base else chr_fd_0_base
		else
			mapped_base = if latch1_fe then chr_fe_1_base else chr_fd_1_base
		end

		local mapped = mapped_base + bit32.band(addr, 0x0FFF)

		-- Apply latch updates after mapping so the triggering fetch still uses the old bank.
		if addr == 0x0FD8 then
			latch0_fe = false
		elseif addr == 0x0FE8 then
			latch0_fe = true
		elseif addr >= 0x1FD8 and addr <= 0x1FDF then
			latch1_fe = false
		elseif addr >= 0x1FE8 and addr <= 0x1FEF then
			latch1_fe = true
		end

		return mapped
	end

	local function write_cpu(addr: number, value: number)
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0xA000 then
			return
		end

		if addr < 0xB000 then
			prg_bank = bit32.band(value, 0x0F)
			recalc_prg_base_8000()
		elseif addr < 0xC000 then
			chr_fd_0 = bit32.band(value, 0x1F)
			chr_fd_0_base = wrapBank(chr_fd_0, chr_total_4k) * 0x1000
		elseif addr < 0xD000 then
			chr_fe_0 = bit32.band(value, 0x1F)
			chr_fe_0_base = wrapBank(chr_fe_0, chr_total_4k) * 0x1000
		elseif addr < 0xE000 then
			chr_fd_1 = bit32.band(value, 0x1F)
			chr_fd_1_base = wrapBank(chr_fd_1, chr_total_4k) * 0x1000
		elseif addr < 0xF000 then
			chr_fe_1 = bit32.band(value, 0x1F)
			chr_fe_1_base = wrapBank(chr_fe_1, chr_total_4k) * 0x1000
		elseif not config.fourScreen then
			mirroring = if bit32.band(value, 0x01) == 0 then 2 else 3
		end
	end

	local function reset_mapper()
		mirroring = config.initialMirroring
		prg_bank = 0
		chr_fd_0 = 0
		chr_fe_0 = 0
		chr_fd_1 = 0
		chr_fe_1 = 0
		recalc_prg_base_8000()
		recalc_chr_bases()
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

--// MAPPER_010
local function MMC4(config: MapperConfig)
	local prg_total_16k = atLeastOne(config.prgSize // 0x4000)
	local chr_total_4k = atLeastOne(config.chrSize // 0x1000)
	local prg_ram_size = config.prgRamSize
	local prg_ram_available = prg_ram_size > 0
	local mirroring = config.initialMirroring

	local prg_bank = 0
	local prg_base_8000 = 0
	local prg_base_C000 = wrapBank(prg_total_16k - 1, prg_total_16k) * 0x4000

	local chr_fd_0 = 0
	local chr_fe_0 = 0
	local chr_fd_1 = 0
	local chr_fe_1 = 0
	local chr_fd_0_base = 0
	local chr_fe_0_base = 0
	local chr_fd_1_base = 0
	local chr_fe_1_base = 0

	local latch0_fe = false
	local latch1_fe = false

	local function recalc_prg_base_8000()
		prg_base_8000 = wrapBank(prg_bank, prg_total_16k) * 0x4000
	end

	local function recalc_chr_bases()
		chr_fd_0_base = wrapBank(chr_fd_0, chr_total_4k) * 0x1000
		chr_fe_0_base = wrapBank(chr_fe_0, chr_total_4k) * 0x1000
		chr_fd_1_base = wrapBank(chr_fd_1, chr_total_4k) * 0x1000
		chr_fe_1_base = wrapBank(chr_fe_1, chr_total_4k) * 0x1000
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
		local mapped_base = 0

		if addr < 0x1000 then
			mapped_base = if latch0_fe then chr_fe_0_base else chr_fd_0_base
		else
			mapped_base = if latch1_fe then chr_fe_1_base else chr_fd_1_base
		end

		local mapped = mapped_base + bit32.band(addr, 0x0FFF)

		-- Apply latch updates after mapping so the triggering fetch still uses the old bank.
		if addr >= 0x0FD8 and addr <= 0x0FDF then
			latch0_fe = false
		elseif addr >= 0x0FE8 and addr <= 0x0FEF then
			latch0_fe = true
		elseif addr >= 0x1FD8 and addr <= 0x1FDF then
			latch1_fe = false
		elseif addr >= 0x1FE8 and addr <= 0x1FEF then
			latch1_fe = true
		end

		return mapped
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

	local function write_cpu(addr: number, value: number)
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0xA000 then
			return
		end

		if addr < 0xB000 then
			prg_bank = bit32.band(value, 0x0F)
			recalc_prg_base_8000()
		elseif addr < 0xC000 then
			chr_fd_0 = bit32.band(value, 0x1F)
			chr_fd_0_base = wrapBank(chr_fd_0, chr_total_4k) * 0x1000
		elseif addr < 0xD000 then
			chr_fe_0 = bit32.band(value, 0x1F)
			chr_fe_0_base = wrapBank(chr_fe_0, chr_total_4k) * 0x1000
		elseif addr < 0xE000 then
			chr_fd_1 = bit32.band(value, 0x1F)
			chr_fd_1_base = wrapBank(chr_fd_1, chr_total_4k) * 0x1000
		elseif addr < 0xF000 then
			chr_fe_1 = bit32.band(value, 0x1F)
			chr_fe_1_base = wrapBank(chr_fe_1, chr_total_4k) * 0x1000
		elseif not config.fourScreen then
			mirroring = if bit32.band(value, 0x01) == 0 then 2 else 3
		end
	end

	local function reset_mapper()
		mirroring = config.initialMirroring
		prg_bank = 0
		chr_fd_0 = 0
		chr_fe_0 = 0
		chr_fd_1 = 0
		chr_fe_1 = 0
		recalc_prg_base_8000()
		recalc_chr_bases()
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
		mapPrgRamAddr = map_prg_ram_addr,
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

--// MAPPER_066
local function GXROM(config: MapperConfig)
	local prg_banks_32k = atLeastOne(config.prgSize // 0x8000)
	local chr_banks_8k = atLeastOne(config.chrSize // 0x2000)

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
		irqPending = nil,
		clearIrq = function() end,
		getMirroring = nil,
		prgRamReadable = nil,
		prgRamWritable = nil,
	}
end

return {
	[0] = NROM,
	[1] = MMC1,
	[2] = UNROM,
	[3] = CNROM,
	[4] = MMC3,
	[5] = MMC5,
	[7] = AOROM,
	[9] = MMC2,
	[10] = MMC4,
	[13] = CpROM,
	[37] = MMC3_VAR,
	[47] = MMC3_VAR,
	[66] = GXROM,
	[94] = UNROM,
	[105] = MMC1,
	[118] = MMC3_VAR,
	[155] = MMC1,
	[180] = UNROM,
	[185] = CnromProtect,
}
--!optimize 2
--!native
--!strict

local Base = require'./Base'

type MapperConfig = Base.MapperConfig

local atLeastOne = Base.atLeastOne
local wrapBank = Base.wrapBank
local normalizeOffset = Base.normalizeOffset

type VrcIrqState = {
	reloadValue: number,
	counter: number,
	prescaler: number,
	enabled: boolean,
	enabledAfterAck: boolean,
	cycleMode: boolean,
	pending: boolean,
}

local VRC2A = 0
local VRC2B = 1
local VRC2C = 2
local VRC4A = 3
local VRC4B = 4
local VRC4C = 5
local VRC4D = 6
local VRC4E = 7
local VRC4_27 = 8

local function create_vrc_irq(): VrcIrqState
	return {
		reloadValue = 0,
		counter = 0,
		prescaler = 0,
		enabled = false,
		enabledAfterAck = false,
		cycleMode = false,
		pending = false,
	}
end

local function reset_vrc_irq(irq: VrcIrqState)
	irq.reloadValue = 0
	irq.counter = 0
	irq.prescaler = 0
	irq.enabled = false
	irq.enabledAfterAck = false
	irq.cycleMode = false
	irq.pending = false
end

local function step_vrc_irq_counter(irq: VrcIrqState)
	if irq.counter == 0xFF then
		irq.counter = irq.reloadValue
		irq.pending = true
	else
		irq.counter = bit32.band(irq.counter + 1, 0xFF)
	end
end

local function clock_vrc_irq(irq: VrcIrqState, cycles: number)
	if not irq.enabled or cycles <= 0 then
		return
	end

	for _ = 1, cycles do
		irq.prescaler -= 3
		if irq.cycleMode or irq.prescaler <= 0 then
			step_vrc_irq_counter(irq)
			irq.prescaler += 341
		end
	end
end

local function set_vrc_irq_reload_value(irq: VrcIrqState, value: number)
	irq.reloadValue = value
end

local function set_vrc_irq_reload_nibble(irq: VrcIrqState, value: number, high_bits: boolean)
	value = bit32.band(value, 0x0F)
	if high_bits then
		irq.reloadValue = bit32.bor(bit32.band(irq.reloadValue, 0x0F), value * 16)
	else
		irq.reloadValue = bit32.bor(bit32.band(irq.reloadValue, 0xF0), value)
	end
end

local function set_vrc_irq_control(irq: VrcIrqState, value: number)
	irq.enabledAfterAck = bit32.btest(value, 0x01)
	irq.enabled = bit32.btest(value, 0x02)
	irq.cycleMode = bit32.btest(value, 0x04)
	if irq.enabled then
		irq.counter = irq.reloadValue
		irq.prescaler = 341
	end
	irq.pending = false
end

local function acknowledge_vrc_irq(irq: VrcIrqState)
	irq.enabled = irq.enabledAfterAck
	irq.pending = false
end

local function translated_vrc2_4_addr(addr: number, variant: number, use_heuristics: boolean): number
	local a0 = 0
	local a1 = 0

	if use_heuristics then
		if variant == VRC2C or variant == VRC4B or variant == VRC4D then
			a0 = bit32.band(bit32.rshift(addr, 1), 0x01)
			a1 = bit32.band(addr, 0x01)
			a0 = bit32.bor(a0, bit32.band(bit32.rshift(addr, 3), 0x01))
			a1 = bit32.bor(a1, bit32.band(bit32.rshift(addr, 2), 0x01))
		elseif variant == VRC4A or variant == VRC4C then
			a0 = bit32.band(bit32.rshift(addr, 1), 0x01)
			a1 = bit32.band(bit32.rshift(addr, 2), 0x01)
			a0 = bit32.bor(a0, bit32.band(bit32.rshift(addr, 6), 0x01))
			a1 = bit32.bor(a1, bit32.band(bit32.rshift(addr, 7), 0x01))
		else
			a0 = bit32.band(addr, 0x01)
			a1 = bit32.band(bit32.rshift(addr, 1), 0x01)
			a0 = bit32.bor(a0, bit32.band(bit32.rshift(addr, 2), 0x01))
			a1 = bit32.bor(a1, bit32.band(bit32.rshift(addr, 3), 0x01))
		end
	else
		if variant == VRC2A then
			a0 = bit32.band(bit32.rshift(addr, 1), 0x01)
			a1 = bit32.band(addr, 0x01)
		elseif variant == VRC4_27 then
			a0 = bit32.band(addr, 0x01)
			a1 = bit32.band(bit32.rshift(addr, 1), 0x01)
		elseif variant == VRC2C or variant == VRC4B then
			a0 = bit32.band(bit32.rshift(addr, 1), 0x01)
			a1 = bit32.band(addr, 0x01)
		elseif variant == VRC4D then
			a0 = bit32.band(bit32.rshift(addr, 3), 0x01)
			a1 = bit32.band(bit32.rshift(addr, 2), 0x01)
		elseif variant == VRC4A then
			a0 = bit32.band(bit32.rshift(addr, 1), 0x01)
			a1 = bit32.band(bit32.rshift(addr, 2), 0x01)
		elseif variant == VRC4C then
			a0 = bit32.band(bit32.rshift(addr, 6), 0x01)
			a1 = bit32.band(bit32.rshift(addr, 7), 0x01)
		elseif variant == VRC2B then
			a0 = bit32.band(addr, 0x01)
			a1 = bit32.band(bit32.rshift(addr, 1), 0x01)
		else
			a0 = bit32.band(bit32.rshift(addr, 2), 0x01)
			a1 = bit32.band(bit32.rshift(addr, 3), 0x01)
		end
	end

	return bit32.bor(bit32.band(addr, 0xFF00), a1 * 2, a0)
end

local function detect_vrc2_4_variant(config: MapperConfig): (number, boolean)
	local submapper = config.submapper or 0
	local mapper_id = config.id

	if mapper_id == 21 then
		if submapper == 2 then
			return VRC4C, false
		end
		return VRC4A, submapper == 0
	end

	if mapper_id == 22 then
		return VRC2A, false
	end

	if mapper_id == 23 then
		if submapper == 2 then
			return VRC4E, false
		end
		return VRC2B, submapper == 0
	end

	if mapper_id == 25 then
		if submapper == 2 then
			return VRC4D, false
		end
		if submapper == 3 then
			return VRC2C, false
		end
		return VRC4B, submapper == 0
	end

	return VRC4_27, false
end

--// MAPPER_075
local function VRC1(config: MapperConfig)
	local prg_total_8k = atLeastOne(config.prgSize // 0x2000)
	local chr_total_4k = atLeastOne(config.chrSize // 0x1000)
	local prg_ram_size = config.prgRamSize
	local prg_ram_available = prg_ram_size > 0
	local four_screen = config.fourScreen
	local mirroring = config.initialMirroring

	local prg_base_8000 = 0
	local prg_base_A000 = 0
	local prg_base_C000 = 0
	local prg_base_E000 = wrapBank(prg_total_8k - 1, prg_total_8k) * 0x2000
	local chr_bank_0000 = 0
	local chr_bank_1000 = 0
	local chr_base_0000 = 0
	local chr_base_1000 = 0

	local function recalc_chr_base_0000()
		chr_base_0000 = wrapBank(chr_bank_0000, chr_total_4k) * 0x1000
	end

	local function recalc_chr_base_1000()
		chr_base_1000 = wrapBank(chr_bank_1000, chr_total_4k) * 0x1000
	end

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
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
		if addr < 0x1000 then
			return chr_base_0000 + bit32.band(addr, 0x0FFF)
		end

		return chr_base_1000 + bit32.band(addr, 0x0FFF)
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
		if addr < 0x8000 then
			return
		end

		local region = bit32.band(addr, 0xF000)
		if region == 0x8000 then
			prg_base_8000 = wrapBank(value, prg_total_8k) * 0x2000
		elseif region == 0x9000 then
			if not four_screen then
				mirroring = if bit32.btest(value, 0x01) then 3 else 2
			end
			chr_bank_0000 = bit32.bor(bit32.band(chr_bank_0000, 0x0F), bit32.band(bit32.rshift(value, 1), 0x01) * 16)
			chr_bank_1000 = bit32.bor(bit32.band(chr_bank_1000, 0x0F), bit32.band(bit32.rshift(value, 2), 0x01) * 16)
			recalc_chr_base_0000()
			recalc_chr_base_1000()
		elseif region == 0xA000 then
			prg_base_A000 = wrapBank(value, prg_total_8k) * 0x2000
		elseif region == 0xC000 then
			prg_base_C000 = wrapBank(value, prg_total_8k) * 0x2000
		elseif region == 0xE000 then
			chr_bank_0000 = bit32.bor(bit32.band(chr_bank_0000, 0x10), bit32.band(value, 0x0F))
			recalc_chr_base_0000()
		elseif region == 0xF000 then
			chr_bank_1000 = bit32.bor(bit32.band(chr_bank_1000, 0x10), bit32.band(value, 0x0F))
			recalc_chr_base_1000()
		end
	end

	local function reset_mapper()
		mirroring = config.initialMirroring
		prg_base_8000 = 0
		prg_base_A000 = wrapBank(1, prg_total_8k) * 0x2000
		prg_base_C000 = wrapBank(2, prg_total_8k) * 0x2000
		prg_base_E000 = wrapBank(prg_total_8k - 1, prg_total_8k) * 0x2000
		chr_bank_0000 = 0
		chr_bank_1000 = 0
		recalc_chr_base_0000()
		recalc_chr_base_1000()
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

local function VRC2_4(config: MapperConfig)
	local prg_total_8k = atLeastOne(config.prgSize // 0x2000)
	local chr_total_1k = atLeastOne(config.chrSize // 0x0400)
	local prg_ram_size = config.prgRamSize
	local prg_ram_available = prg_ram_size > 0
	local four_screen = config.fourScreen
	local mirroring = config.initialMirroring

	local variant, use_heuristics = detect_vrc2_4_variant(config)
	local supports_vrc4_features = use_heuristics or variant >= VRC4A
	local certain_vrc2 = (not use_heuristics) and variant <= VRC2C
	local latch_enabled = certain_vrc2 and not prg_ram_available

	local prg_fixed_C000 = wrapBank(prg_total_8k - 2, prg_total_8k) * 0x2000
	local prg_fixed_E000 = wrapBank(prg_total_8k - 1, prg_total_8k) * 0x2000
	local prg_reg0 = 0
	local prg_reg1 = 0
	local prg_mode = 0
	local prg_base_8000 = 0
	local prg_base_A000 = 0
	local prg_base_C000 = prg_fixed_C000
	local prg_base_E000 = prg_fixed_E000

	local chr_lo = buffer.create(8)
	local chr_hi = buffer.create(8)
	local chr_base_0000 = 0
	local chr_base_0400 = 0
	local chr_base_0800 = 0
	local chr_base_0C00 = 0
	local chr_base_1000 = 0
	local chr_base_1400 = 0
	local chr_base_1800 = 0
	local chr_base_1C00 = 0
	local latch = 0
	local irq = create_vrc_irq()

	local function set_chr_base(index: number, base: number)
		if index == 1 then
			chr_base_0000 = base
		elseif index == 2 then
			chr_base_0400 = base
		elseif index == 3 then
			chr_base_0800 = base
		elseif index == 4 then
			chr_base_0C00 = base
		elseif index == 5 then
			chr_base_1000 = base
		elseif index == 6 then
			chr_base_1400 = base
		elseif index == 7 then
			chr_base_1800 = base
		else
			chr_base_1C00 = base
		end
	end

	local function recalc_chr_base(index: number)
		local offset = index - 1
		local page = bit32.bor(buffer.readu8(chr_lo, offset), buffer.readu8(chr_hi, offset) * 16)
		if variant == VRC2A then
			page = bit32.rshift(page, 1)
		end
		set_chr_base(index, wrapBank(page, chr_total_1k) * 0x0400)
	end

	local function recalc_prg_bases()
		local reg0_base = wrapBank(prg_reg0, prg_total_8k) * 0x2000
		local reg1_base = wrapBank(prg_reg1, prg_total_8k) * 0x2000

		if prg_mode == 0 then
			prg_base_8000 = reg0_base
			prg_base_A000 = reg1_base
			prg_base_C000 = prg_fixed_C000
		else
			prg_base_8000 = prg_fixed_C000
			prg_base_A000 = reg1_base
			prg_base_C000 = reg0_base
		end

		prg_base_E000 = prg_fixed_E000
	end

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
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
		if addr < 0x0400 then
			return chr_base_0000 + addr
		end
		if addr < 0x0800 then
			return chr_base_0400 + bit32.band(addr, 0x03FF)
		end
		if addr < 0x0C00 then
			return chr_base_0800 + bit32.band(addr, 0x03FF)
		end
		if addr < 0x1000 then
			return chr_base_0C00 + bit32.band(addr, 0x03FF)
		end
		if addr < 0x1400 then
			return chr_base_1000 + bit32.band(addr, 0x03FF)
		end
		if addr < 0x1800 then
			return chr_base_1400 + bit32.band(addr, 0x03FF)
		end
		if addr < 0x1C00 then
			return chr_base_1800 + bit32.band(addr, 0x03FF)
		end

		return chr_base_1C00 + bit32.band(addr, 0x03FF)
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

	local function read_cpu(addr: number): number?
		addr = bit32.band(addr, 0xFFFF)
		if latch_enabled and addr >= 0x6000 and addr < 0x8000 then
			return latch
		end
		return nil
	end

	local function write_cpu(addr: number, value: number)
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			if latch_enabled and addr >= 0x6000 then
				latch = bit32.band(value, 0x01)
			end
			return
		end

		local reg = bit32.band(translated_vrc2_4_addr(addr, variant, use_heuristics), 0xF00F)

		if reg >= 0x8000 and reg <= 0x8006 then
			prg_reg0 = bit32.band(value, 0x1F)
			recalc_prg_bases()
			return
		end

		if ((certain_vrc2 and reg >= 0x9000 and reg <= 0x9003) or (supports_vrc4_features and reg >= 0x9000 and reg <= 0x9001)) and not four_screen then
			local mask = if certain_vrc2 then 0x01 else 0x03
			local mode = bit32.band(value, mask)
			if mode == 0 then
				mirroring = 2
			elseif mode == 1 then
				mirroring = 3
			elseif mode == 2 then
				mirroring = 0
			else
				mirroring = 1
			end
			return
		end

		if supports_vrc4_features and reg >= 0x9002 and reg <= 0x9003 then
			prg_mode = bit32.band(bit32.rshift(value, 1), 0x01)
			recalc_prg_bases()
			return
		end

		if reg >= 0xA000 and reg <= 0xA006 then
			prg_reg1 = bit32.band(value, 0x1F)
			recalc_prg_bases()
			return
		end

		if reg >= 0xB000 and reg <= 0xE006 then
			local reg_number = ((((bit32.band(bit32.rshift(reg, 12), 0x07)) - 3) * 2) + bit32.band(bit32.rshift(reg, 1), 0x01)) + 1
			local offset = reg_number - 1
			if bit32.band(reg, 0x01) == 0 then
				buffer.writeu8(chr_lo, offset, bit32.band(value, 0x0F))
			else
				buffer.writeu8(chr_hi, offset, bit32.band(value, 0x1F))
			end
			recalc_chr_base(reg_number)
			return
		end

		if reg == 0xF000 then
			set_vrc_irq_reload_nibble(irq, value, false)
		elseif reg == 0xF001 then
			set_vrc_irq_reload_nibble(irq, value, true)
		elseif reg == 0xF002 then
			set_vrc_irq_control(irq, value)
		elseif reg == 0xF003 then
			acknowledge_vrc_irq(irq)
		end
	end

	local function clock_cpu(cycles: number)
		if supports_vrc4_features then
			clock_vrc_irq(irq, cycles)
		end
	end

	local function reset_mapper()
		mirroring = config.initialMirroring
		prg_reg0 = 0
		prg_reg1 = 0
		prg_mode = 0
		prg_base_8000 = 0
		prg_base_A000 = 0
		prg_base_C000 = prg_fixed_C000
		prg_base_E000 = prg_fixed_E000
		latch = 0
		buffer.fill(chr_lo, 0, 0, 8)
		buffer.fill(chr_hi, 0, 0, 8)
		chr_base_0000 = 0
		chr_base_0400 = 0
		chr_base_0800 = 0
		chr_base_0C00 = 0
		chr_base_1000 = 0
		chr_base_1400 = 0
		chr_base_1800 = 0
		chr_base_1C00 = 0
		recalc_prg_bases()
		reset_vrc_irq(irq)
	end

	reset_mapper()

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = write_cpu,
		readCpu = read_cpu,
		readNametable = nil,
		writeNametable = nil,
		mapPrgRamAddr = map_prg_ram_addr,
		clockCpu = clock_cpu,
		clockA12 = nil,
		clockScanline = nil,
		onPpuAddress = nil,
		reset = reset_mapper,
		irqPending = if supports_vrc4_features then function(): boolean
			return irq.pending
		end else nil,
		clearIrq = function()
			irq.pending = false
		end,
		getMirroring = function(): number
			return mirroring
		end,
		prgRamReadable = nil,
		prgRamWritable = nil,
	}
end

--// MAPPER_073
local function VRC3(config: MapperConfig)
	local prg_total_16k = atLeastOne(config.prgSize // 0x4000)
	local prg_ram_size = config.prgRamSize
	local prg_ram_available = prg_ram_size > 0

	local prg_base_8000 = 0
	local prg_base_C000 = wrapBank(prg_total_16k - 1, prg_total_16k) * 0x4000
	local irq_reload = 0
	local irq_counter = 0
	local irq_enabled = false
	local irq_enable_on_ack = false
	local irq_small_counter = false
	local irq_pending = false

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return -1
		end

		if addr < 0xC000 then
			return prg_base_8000 + bit32.band(addr, 0x3FFF)
		end

		return prg_base_C000 + bit32.band(addr, 0x3FFF)
	end

	local function map_chr_addr(addr: number, _fetch_kind: number?, _sprite_16: boolean?): number
		return bit32.band(addr, 0x1FFF)
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
		addr = bit32.band(addr, 0xF000)
		if addr == 0x8000 then
			irq_reload = bit32.bor(bit32.band(irq_reload, 0xFFF0), bit32.band(value, 0x0F))
		elseif addr == 0x9000 then
			irq_reload = bit32.bor(bit32.band(irq_reload, 0xFF0F), bit32.band(value, 0x0F) * 16)
		elseif addr == 0xA000 then
			irq_reload = bit32.bor(bit32.band(irq_reload, 0xF0FF), bit32.band(value, 0x0F) * 256)
		elseif addr == 0xB000 then
			irq_reload = bit32.bor(bit32.band(irq_reload, 0x0FFF), bit32.band(value, 0x0F) * 4096)
		elseif addr == 0xC000 then
			irq_enable_on_ack = bit32.btest(value, 0x01)
			irq_enabled = bit32.btest(value, 0x02)
			irq_small_counter = bit32.btest(value, 0x04)
			irq_pending = false
			if irq_enabled then
				irq_counter = irq_reload
			end
		elseif addr == 0xD000 then
			irq_pending = false
			irq_enabled = irq_enable_on_ack
		elseif addr == 0xF000 then
			prg_base_8000 = wrapBank(bit32.band(value, 0x07), prg_total_16k) * 0x4000
		end
	end

	local function clock_cpu(cycles: number)
		if not irq_enabled or cycles <= 0 then
			return
		end

		if irq_small_counter then
			local low_counter = bit32.band(irq_counter, 0xFF)
			for _ = 1, cycles do
				if low_counter == 0xFF then
					low_counter = bit32.band(irq_reload, 0xFF)
					irq_pending = true
				else
					low_counter = bit32.band(low_counter + 1, 0xFF)
				end
			end
			irq_counter = bit32.bor(bit32.band(irq_counter, 0xFF00), low_counter)
			return
		end

		for _ = 1, cycles do
			if irq_counter == 0xFFFF then
				irq_counter = irq_reload
				irq_pending = true
			else
				irq_counter = bit32.band(irq_counter + 1, 0xFFFF)
			end
		end
	end

	local function reset_mapper()
		prg_base_8000 = 0
		prg_base_C000 = wrapBank(prg_total_16k - 1, prg_total_16k) * 0x4000
		irq_reload = 0
		irq_counter = 0
		irq_enabled = false
		irq_enable_on_ack = false
		irq_small_counter = false
		irq_pending = false
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
		getMirroring = nil,
		prgRamReadable = nil,
		prgRamWritable = nil,
	}
end

local function VRC6(config: MapperConfig)
	local prg_total_8k = atLeastOne(config.prgSize // 0x2000)
	local prg_total_16k = atLeastOne(config.prgSize // 0x4000)
	local chr_total_1k = atLeastOne(config.chrSize // 0x0400)
	local prg_ram_size = config.prgRamSize
	local prg_ram_available = prg_ram_size > 0
	local four_screen = config.fourScreen
	local swap_register_bits = config.id == 26
	local mirroring = config.initialMirroring

	local prg_base_8000 = 0
	local prg_base_C000 = 0
	local prg_base_E000 = wrapBank(prg_total_8k - 1, prg_total_8k) * 0x2000
	local banking_mode = 0
	local chr_regs = buffer.create(8)
	local chr_base_0000 = 0
	local chr_base_0400 = 0
	local chr_base_0800 = 0
	local chr_base_0C00 = 0
	local chr_base_1000 = 0
	local chr_base_1400 = 0
	local chr_base_1800 = 0
	local chr_base_1C00 = 0
	local irq = create_vrc_irq()

	local function refresh_vrc6_state()
		local chr0 = buffer.readu8(chr_regs, 0)
		local chr1 = buffer.readu8(chr_regs, 1)
		local chr2 = buffer.readu8(chr_regs, 2)
		local chr3 = buffer.readu8(chr_regs, 3)
		local chr4 = buffer.readu8(chr_regs, 4)
		local chr5 = buffer.readu8(chr_regs, 5)
		local chr6 = buffer.readu8(chr_regs, 6)
		local chr7 = buffer.readu8(chr_regs, 7)
		local mask = if bit32.btest(banking_mode, 0x20) then 0xFE else 0xFF
		local or_mask = if bit32.btest(banking_mode, 0x20) then 0x01 else 0x00
		local chr_mode = bit32.band(banking_mode, 0x03)
		local mode_low = bit32.band(banking_mode, 0x07)

		if chr_mode == 0 then
			chr_base_0000 = wrapBank(chr0, chr_total_1k) * 0x0400
			chr_base_0400 = wrapBank(chr1, chr_total_1k) * 0x0400
			chr_base_0800 = wrapBank(chr2, chr_total_1k) * 0x0400
			chr_base_0C00 = wrapBank(chr3, chr_total_1k) * 0x0400
			chr_base_1000 = wrapBank(chr4, chr_total_1k) * 0x0400
			chr_base_1400 = wrapBank(chr5, chr_total_1k) * 0x0400
			chr_base_1800 = wrapBank(chr6, chr_total_1k) * 0x0400
			chr_base_1C00 = wrapBank(chr7, chr_total_1k) * 0x0400
		elseif chr_mode == 1 then
			local chr0_pair = bit32.band(chr0, mask)
			local chr1_pair = bit32.band(chr1, mask)
			local chr2_pair = bit32.band(chr2, mask)
			local chr3_pair = bit32.band(chr3, mask)
			chr_base_0000 = wrapBank(chr0_pair, chr_total_1k) * 0x0400
			chr_base_0400 = wrapBank(bit32.bor(chr0_pair, or_mask), chr_total_1k) * 0x0400
			chr_base_0800 = wrapBank(chr1_pair, chr_total_1k) * 0x0400
			chr_base_0C00 = wrapBank(bit32.bor(chr1_pair, or_mask), chr_total_1k) * 0x0400
			chr_base_1000 = wrapBank(chr2_pair, chr_total_1k) * 0x0400
			chr_base_1400 = wrapBank(bit32.bor(chr2_pair, or_mask), chr_total_1k) * 0x0400
			chr_base_1800 = wrapBank(chr3_pair, chr_total_1k) * 0x0400
			chr_base_1C00 = wrapBank(bit32.bor(chr3_pair, or_mask), chr_total_1k) * 0x0400
		else
			local chr4_pair = bit32.band(chr4, mask)
			local chr5_pair = bit32.band(chr5, mask)
			chr_base_0000 = wrapBank(chr0, chr_total_1k) * 0x0400
			chr_base_0400 = wrapBank(chr1, chr_total_1k) * 0x0400
			chr_base_0800 = wrapBank(chr2, chr_total_1k) * 0x0400
			chr_base_0C00 = wrapBank(chr3, chr_total_1k) * 0x0400
			chr_base_1000 = wrapBank(chr4_pair, chr_total_1k) * 0x0400
			chr_base_1400 = wrapBank(bit32.bor(chr4_pair, or_mask), chr_total_1k) * 0x0400
			chr_base_1800 = wrapBank(chr5_pair, chr_total_1k) * 0x0400
			chr_base_1C00 = wrapBank(bit32.bor(chr5_pair, or_mask), chr_total_1k) * 0x0400
		end

		if four_screen or bit32.btest(banking_mode, 0x10) then
			return
		end

		local mode = bit32.band(banking_mode, 0x2F)
		if mode == 0x20 or mode == 0x27 then
			mirroring = 2
			return
		end
		if mode == 0x23 or mode == 0x24 then
			mirroring = 3
			return
		end
		if mode == 0x28 or mode == 0x2F then
			mirroring = 0
			return
		end
		if mode == 0x2B or mode == 0x2C then
			mirroring = 1
			return
		end

		local n0 = 0
		local n1 = 0
		local n2 = 0
		local n3 = 0
		if mode_low == 0 or mode_low == 6 or mode_low == 7 then
			n0 = bit32.band(chr6, 0x01)
			n1 = n0
			n2 = bit32.band(chr7, 0x01)
			n3 = n2
		elseif mode_low == 1 or mode_low == 5 then
			n0 = bit32.band(chr4, 0x01)
			n1 = bit32.band(chr5, 0x01)
			n2 = bit32.band(chr6, 0x01)
			n3 = bit32.band(chr7, 0x01)
		else
			n0 = bit32.band(chr6, 0x01)
			n1 = bit32.band(chr7, 0x01)
			n2 = n0
			n3 = n1
		end

		if n0 == n1 and n2 == n3 and n0 ~= n2 then
			mirroring = 3
		elseif n0 == n2 and n1 == n3 and n0 ~= n1 then
			mirroring = 2
		elseif n0 == n1 and n1 == n2 and n2 == n3 then
			mirroring = if n0 == 0 then 0 else 1
		end
	end

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return -1
		end

		if addr < 0xC000 then
			return prg_base_8000 + bit32.band(addr - 0x8000, 0x3FFF)
		end
		if addr < 0xE000 then
			return prg_base_C000 + bit32.band(addr, 0x1FFF)
		end
		return prg_base_E000 + bit32.band(addr, 0x1FFF)
	end

	local function map_chr_addr(addr: number, _fetch_kind: number?, _sprite_16: boolean?): number
		addr = bit32.band(addr, 0x1FFF)
		if addr < 0x0400 then
			return chr_base_0000 + addr
		end
		if addr < 0x0800 then
			return chr_base_0400 + bit32.band(addr, 0x03FF)
		end
		if addr < 0x0C00 then
			return chr_base_0800 + bit32.band(addr, 0x03FF)
		end
		if addr < 0x1000 then
			return chr_base_0C00 + bit32.band(addr, 0x03FF)
		end
		if addr < 0x1400 then
			return chr_base_1000 + bit32.band(addr, 0x03FF)
		end
		if addr < 0x1800 then
			return chr_base_1400 + bit32.band(addr, 0x03FF)
		end
		if addr < 0x1C00 then
			return chr_base_1800 + bit32.band(addr, 0x03FF)
		end

		return chr_base_1C00 + bit32.band(addr, 0x03FF)
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
		if addr < 0x8000 then
			return
		end

		if swap_register_bits then
			addr = bit32.bor(
				bit32.band(addr, 0xFFFC),
				bit32.band(addr, 0x01) * 2,
				bit32.rshift(bit32.band(addr, 0x02), 1)
			)
		end

		local reg = bit32.band(addr, 0xF003)
		if reg >= 0x8000 and reg <= 0x8003 then
			prg_base_8000 = wrapBank(bit32.band(value, 0x0F), prg_total_16k) * 0x4000
		elseif reg == 0xB003 then
			banking_mode = value
			refresh_vrc6_state()
		elseif reg >= 0xC000 and reg <= 0xC003 then
			prg_base_C000 = wrapBank(bit32.band(value, 0x1F), prg_total_8k) * 0x2000
		elseif reg >= 0xD000 and reg <= 0xD003 then
			buffer.writeu8(chr_regs, bit32.band(reg, 0x03), value)
			refresh_vrc6_state()
		elseif reg >= 0xE000 and reg <= 0xE003 then
			buffer.writeu8(chr_regs, bit32.band(reg, 0x03) + 4, value)
			refresh_vrc6_state()
		elseif reg == 0xF000 then
			set_vrc_irq_reload_value(irq, value)
		elseif reg == 0xF001 then
			set_vrc_irq_control(irq, value)
		elseif reg == 0xF002 then
			acknowledge_vrc_irq(irq)
		end
	end

	local function clock_cpu(cycles: number)
		clock_vrc_irq(irq, cycles)
	end

	local function reset_mapper()
		mirroring = config.initialMirroring
		prg_base_8000 = 0
		prg_base_C000 = 0
		prg_base_E000 = wrapBank(prg_total_8k - 1, prg_total_8k) * 0x2000
		banking_mode = 0
		buffer.fill(chr_regs, 0, 0, 8)
		chr_base_0000 = 0
		chr_base_0400 = 0
		chr_base_0800 = 0
		chr_base_0C00 = 0
		chr_base_1000 = 0
		chr_base_1400 = 0
		chr_base_1800 = 0
		chr_base_1C00 = 0
		reset_vrc_irq(irq)
		refresh_vrc6_state()
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
		clockCpu = clock_cpu,
		clockA12 = nil,
		clockScanline = nil,
		onPpuAddress = nil,
		reset = reset_mapper,
		irqPending = function(): boolean
			return irq.pending
		end,
		clearIrq = function()
			irq.pending = false
		end,
		getMirroring = function(): number
			return mirroring
		end,
		prgRamReadable = function(): boolean
			return prg_ram_available and bit32.btest(banking_mode, 0x80)
		end,
		prgRamWritable = function(): boolean
			return prg_ram_available and bit32.btest(banking_mode, 0x80)
		end,
	}
end

--// MAPPER_085
local function VRC7(config: MapperConfig)
	local prg_total_8k = atLeastOne(config.prgSize // 0x2000)
	local chr_total_1k = atLeastOne(config.chrSize // 0x0400)
	local prg_ram_size = config.prgRamSize
	local prg_ram_available = prg_ram_size > 0
	local four_screen = config.fourScreen
	local mirroring = config.initialMirroring

	local prg_base_8000 = 0
	local prg_base_A000 = 0
	local prg_base_C000 = 0
	local prg_base_E000 = wrapBank(prg_total_8k - 1, prg_total_8k) * 0x2000
	local chr_base_0000 = 0
	local chr_base_0400 = 0
	local chr_base_0800 = 0
	local chr_base_0C00 = 0
	local chr_base_1000 = 0
	local chr_base_1400 = 0
	local chr_base_1800 = 0
	local chr_base_1C00 = 0
	local control_flags = 0
	local irq = create_vrc_irq()

	local function update_state()
		if not four_screen then
			local mode = bit32.band(control_flags, 0x03)
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
	end

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
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
		if addr < 0x0400 then
			return chr_base_0000 + addr
		end
		if addr < 0x0800 then
			return chr_base_0400 + bit32.band(addr, 0x03FF)
		end
		if addr < 0x0C00 then
			return chr_base_0800 + bit32.band(addr, 0x03FF)
		end
		if addr < 0x1000 then
			return chr_base_0C00 + bit32.band(addr, 0x03FF)
		end
		if addr < 0x1400 then
			return chr_base_1000 + bit32.band(addr, 0x03FF)
		end
		if addr < 0x1800 then
			return chr_base_1400 + bit32.band(addr, 0x03FF)
		end
		if addr < 0x1C00 then
			return chr_base_1800 + bit32.band(addr, 0x03FF)
		end

		return chr_base_1C00 + bit32.band(addr, 0x03FF)
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
		if addr < 0x8000 then
			return
		end

		if bit32.btest(addr, 0x10) and bit32.band(addr, 0xF010) ~= 0x9010 then
			addr = bit32.band(bit32.bor(addr, 0x08), 0xFFEF)
		end

		local reg = bit32.band(addr, 0xF038)
		if reg == 0x8000 then
			prg_base_8000 = wrapBank(bit32.band(value, 0x3F), prg_total_8k) * 0x2000
		elseif reg == 0x8008 then
			prg_base_A000 = wrapBank(bit32.band(value, 0x3F), prg_total_8k) * 0x2000
		elseif reg == 0x9000 then
			prg_base_C000 = wrapBank(bit32.band(value, 0x3F), prg_total_8k) * 0x2000
		elseif reg == 0xA000 then
			chr_base_0000 = wrapBank(value, chr_total_1k) * 0x0400
		elseif reg == 0xA008 then
			chr_base_0400 = wrapBank(value, chr_total_1k) * 0x0400
		elseif reg == 0xB000 then
			chr_base_0800 = wrapBank(value, chr_total_1k) * 0x0400
		elseif reg == 0xB008 then
			chr_base_0C00 = wrapBank(value, chr_total_1k) * 0x0400
		elseif reg == 0xC000 then
			chr_base_1000 = wrapBank(value, chr_total_1k) * 0x0400
		elseif reg == 0xC008 then
			chr_base_1400 = wrapBank(value, chr_total_1k) * 0x0400
		elseif reg == 0xD000 then
			chr_base_1800 = wrapBank(value, chr_total_1k) * 0x0400
		elseif reg == 0xD008 then
			chr_base_1C00 = wrapBank(value, chr_total_1k) * 0x0400
		elseif reg == 0xE000 then
			control_flags = value
			update_state()
		elseif reg == 0xE008 then
			set_vrc_irq_reload_value(irq, value)
		elseif reg == 0xF000 then
			set_vrc_irq_control(irq, value)
		elseif reg == 0xF008 then
			acknowledge_vrc_irq(irq)
		end
	end

	local function clock_cpu(cycles: number)
		clock_vrc_irq(irq, cycles)
	end

	local function reset_mapper()
		mirroring = config.initialMirroring
		prg_base_8000 = 0
		prg_base_A000 = 0
		prg_base_C000 = 0
		prg_base_E000 = wrapBank(prg_total_8k - 1, prg_total_8k) * 0x2000
		control_flags = 0
		chr_base_0000 = 0
		chr_base_0400 = 0
		chr_base_0800 = 0
		chr_base_0C00 = 0
		chr_base_1000 = 0
		chr_base_1400 = 0
		chr_base_1800 = 0
		chr_base_1C00 = 0
		reset_vrc_irq(irq)
		update_state()
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
		clockCpu = clock_cpu,
		clockA12 = nil,
		clockScanline = nil,
		onPpuAddress = nil,
		reset = reset_mapper,
		irqPending = function(): boolean
			return irq.pending
		end,
		clearIrq = function()
			irq.pending = false
		end,
		getMirroring = function(): number
			return mirroring
		end,
		prgRamReadable = function(): boolean
			return prg_ram_available and bit32.btest(control_flags, 0x80)
		end,
		prgRamWritable = function(): boolean
			return prg_ram_available and bit32.btest(control_flags, 0x80)
		end,
	}
end

return {
	[21] = VRC2_4,
	[22] = VRC2_4,
	[23] = VRC2_4,
	[24] = VRC6,
	[25] = VRC2_4,
	[26] = VRC6,
	[27] = VRC2_4,
	[73] = VRC3,
	[75] = VRC1,
	[85] = VRC7,
}

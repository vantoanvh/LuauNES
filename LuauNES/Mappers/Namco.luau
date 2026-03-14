--!optimize 2
--!native
--!strict

local Base = require'./Base'

type MapperConfig = Base.MapperConfig

local atLeastOne = Base.atLeastOne
local normalizeOffset = Base.normalizeOffset
local wrapBank = Base.wrapBank

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

local function reset_mirroring_pages(mode: number): (number, number, number, number)
	if mode == 0 then
		return 0, 0, 0, 0
	end

	if mode == 1 then
		return 1, 1, 1, 1
	end

	if mode == 2 then
		return 0, 1, 0, 1
	end

	return 0, 0, 1, 1
end

local function create_namco108(config: MapperConfig, variant: string)
	local prg_total_8k = atLeastOne(config.prgSize // 0x2000)
	local chr_total_1k = atLeastOne(config.chrSize // 0x0400)
	local chr_total_2k = atLeastOne(config.chrSize // 0x0800)
	local prg_ram_size = config.prgRamSize
	local prg_ram_available = prg_ram_size > 0
	local vram_buf = config.vram

	local is_mapper_76 = variant == '76'
	local is_mapper_88 = variant == '88' or variant == '154'
	local is_mapper_95 = variant == '95'
	local is_mapper_154 = variant == '154'

	local bank_select = 0
	local reg0 = 0
	local reg1 = 0
	local reg2 = 0
	local reg3 = 0
	local reg4 = 0
	local reg5 = 0
	local reg6 = 0
	local reg7 = 0

	local prg_base0 = 0
	local prg_base1 = 0
	local prg_base2 = 0
	local prg_base3 = 0

	local chr_base0 = 0
	local chr_base1 = 0
	local chr_base2 = 0
	local chr_base3 = 0
	local chr_base4 = 0
	local chr_base5 = 0
	local chr_base6 = 0
	local chr_base7 = 0

	local mirroring = config.initialMirroring
	local nametable_page0 = 0
	local nametable_page1 = 1
	local nametable_page2 = 0
	local nametable_page3 = 1

	local function recalc_prg_slots()
		local r6 = wrapBank(reg6, prg_total_8k)
		local r7 = wrapBank(reg7, prg_total_8k)
		local last = math.max(prg_total_8k - 1, 0)
		local second_last = math.max(prg_total_8k - 2, 0)

		prg_base0 = r6 * 0x2000
		prg_base1 = r7 * 0x2000
		prg_base2 = second_last * 0x2000
		prg_base3 = last * 0x2000
	end

	local function recalc_chr_slots()
		if is_mapper_76 then
			chr_base0 = wrapBank(reg2, chr_total_2k) * 0x0800
			chr_base1 = wrapBank(reg3, chr_total_2k) * 0x0800
			chr_base2 = wrapBank(reg4, chr_total_2k) * 0x0800
			chr_base3 = wrapBank(reg5, chr_total_2k) * 0x0800
			return
		end

		local r0 = reg0
		local r1 = reg1
		local r2 = reg2
		local r3 = reg3
		local r4 = reg4
		local r5 = reg5

		if is_mapper_88 then
			r0 = bit32.band(r0, 0x3F)
			r1 = bit32.band(r1, 0x3F)
			r2 = bit32.bor(r2, 0x40)
			r3 = bit32.bor(r3, 0x40)
			r4 = bit32.bor(r4, 0x40)
			r5 = bit32.bor(r5, 0x40)
		end

		chr_base0 = wrapBank(bit32.band(r0, 0xFE), chr_total_1k) * 0x0400
		chr_base1 = wrapBank(bit32.band(r0, 0xFE) + 1, chr_total_1k) * 0x0400
		chr_base2 = wrapBank(bit32.band(r1, 0xFE), chr_total_1k) * 0x0400
		chr_base3 = wrapBank(bit32.band(r1, 0xFE) + 1, chr_total_1k) * 0x0400
		chr_base4 = wrapBank(r2, chr_total_1k) * 0x0400
		chr_base5 = wrapBank(r3, chr_total_1k) * 0x0400
		chr_base6 = wrapBank(r4, chr_total_1k) * 0x0400
		chr_base7 = wrapBank(r5, chr_total_1k) * 0x0400
	end

	local function update_nametable_pages()
		if not is_mapper_95 then
			return
		end

		nametable_page0 = bit32.band(bit32.rshift(reg0, 5), 0x01)
		nametable_page1 = nametable_page0
		nametable_page2 = bit32.band(bit32.rshift(reg1, 5), 0x01)
		nametable_page3 = nametable_page2
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

		if is_mapper_76 then
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
		if not prg_ram_available then
			return nil
		end

		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x6000 or addr >= 0x8000 then
			return nil
		end

		return normalizeOffset(addr - 0x6000, prg_ram_size)
	end

	local function read_nametable(addr: number): number?
		if vram_buf then
			local offset = bit32.band(addr, 0x0FFF)
			local nt = bit32.rshift(offset, 10)
			local inner = bit32.band(offset, 0x03FF)
			local page = if nt == 0 then nametable_page0 elseif nt == 1 then nametable_page1 elseif nt == 2 then nametable_page2 else nametable_page3
			return buffer.readu8(vram_buf, page * 0x0400 + inner)
		end

		return nil
	end

	local function write_nametable(addr: number, value: number): boolean
		if vram_buf then
			local offset = bit32.band(addr, 0x0FFF)
			local nt = bit32.rshift(offset, 10)
			local inner = bit32.band(offset, 0x03FF)
			local page = if nt == 0 then nametable_page0 elseif nt == 1 then nametable_page1 elseif nt == 2 then nametable_page2 else nametable_page3
			buffer.writeu8(vram_buf, page * 0x0400 + inner, value)
		end

		return true
	end

	local function write_cpu(addr: number, value: number)
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return
		end

		if is_mapper_154 then
			mirroring = if bit32.btest(value, 0x40) then 1 else 0
		end

		addr = bit32.band(addr, 0x8001)
		if addr == 0x8000 then
			bank_select = bit32.band(value, 0x07)
			return
		end

		if bank_select == 0 then
			reg0 = value
			recalc_chr_slots()
		elseif bank_select == 1 then
			reg1 = value
			recalc_chr_slots()
		elseif bank_select == 2 then
			reg2 = value
			recalc_chr_slots()
		elseif bank_select == 3 then
			reg3 = value
			recalc_chr_slots()
		elseif bank_select == 4 then
			reg4 = value
			recalc_chr_slots()
		elseif bank_select == 5 then
			reg5 = value
			recalc_chr_slots()
		elseif bank_select == 6 then
			reg6 = value
			recalc_prg_slots()
		else
			reg7 = value
			recalc_prg_slots()
		end

		update_nametable_pages()
	end

	local function reset_mapper()
		local page0, page1, page2, page3 = reset_mirroring_pages(config.initialMirroring)

		bank_select = 0
		reg0 = 0
		reg1 = 0
		reg2 = 0
		reg3 = 0
		reg4 = 0
		reg5 = 0
		reg6 = 0
		reg7 = 0
		mirroring = config.initialMirroring
		nametable_page0 = page0
		nametable_page1 = page1
		nametable_page2 = page2
		nametable_page3 = page3
		recalc_prg_slots()
		recalc_chr_slots()
	end

	reset_mapper()

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = write_cpu,
		readPpu = nil,
		writePpu = nil,
		readCpu = nil,
		readNametable = if is_mapper_95 then read_nametable else nil,
		writeNametable = if is_mapper_95 then write_nametable else nil,
		mapPrgRamAddr = map_prg_ram_addr,
		clockCpu = nil,
		clockA12 = nil,
		clockScanline = nil,
		onPpuAddress = nil,
		reset = reset_mapper,
		irqPending = nil,
		clearIrq = function() end,
		getMirroring = if is_mapper_154 then function(): number
			return mirroring
		end else nil,
		prgRamReadable = nil,
		prgRamWritable = nil,
	}
end

local NAMCO_VARIANT_UNKNOWN = 0
local NAMCO_VARIANT_163 = 1
local NAMCO_VARIANT_175 = 2
local NAMCO_VARIANT_340 = 3

local function Namco163(config: MapperConfig)
	local prg_total_8k = atLeastOne(config.prgSize // 0x2000)
	local chr_total_1k = atLeastOne(config.chrSize // 0x0400)
	local prg_ram_buf = config.prgRam
	local prg_ram_size = config.prgRamSize
	local chr_buf = config.chr
	local chr_size = config.chrSize
	local chr_is_ram = config.chrIsRam
	local vram_buf = config.vram
	local submapper = config.submapper or 0

	local prg_base0 = 0
	local prg_base1 = 0
	local prg_base2 = 0
	local prg_base3 = wrapBank(prg_total_8k - 1, prg_total_8k) * 0x2000

	local pattern_regs = buffer.create(8)
	local nametable_regs = buffer.create(4)
	local audio_ram = buffer.create(0x80)

	local chr_slot_nt = table.create(8, false) :: {boolean}
	local chr_slot_base = table.create(8, 0) :: {number}
	local nt_slot_chr = table.create(4, false) :: {boolean}
	local nt_slot_base = table.create(4, 0) :: {number}

	local variant = NAMCO_VARIANT_163
	local mirroring = config.initialMirroring
	local auto_detect_variant = false
	local not_namco340 = false
	local write_protect = 0
	local low_chr_nt_mode = false
	local high_chr_nt_mode = false
	local irq_counter = 0
	local irq_pending = false
	local audio_ram_pos = 0
	local audio_auto_increment = false
	local _audio_disable_sound = false

	local function set_variant(new_variant: number)
		if auto_detect_variant and (not not_namco340 or new_variant ~= NAMCO_VARIANT_340) then
			variant = new_variant
		end
	end

	local function recalc_pattern_slot(slot: number)
		local value = buffer.readu8(pattern_regs, slot - 1)
		local use_nt = variant == NAMCO_VARIANT_163
			and value >= 0xE0
			and ((slot <= 4 and not low_chr_nt_mode) or (slot > 4 and not high_chr_nt_mode))

		chr_slot_nt[slot] = use_nt
		chr_slot_base[slot] = (use_nt and bit32.band(value, 0x01) or wrapBank(value, chr_total_1k)) * 0x0400
	end

	local function recalc_nametable_slot(slot: number)
		local value = buffer.readu8(nametable_regs, slot - 1)
		local use_chr = value < 0xE0

		nt_slot_chr[slot] = use_chr
		nt_slot_base[slot] = (use_chr and wrapBank(value, chr_total_1k) or bit32.band(value, 0x01)) * 0x0400
	end

	local function recalc_pattern_slots()
		for slot = 1, 8 do
			recalc_pattern_slot(slot)
		end
	end

	local function recalc_nametable_slots()
		for slot = 1, 4 do
			recalc_nametable_slot(slot)
		end
	end

	local function namco163_prg_ram_offset(addr: number): number
		local inner = bit32.band(addr, 0x07FF)
		local page = bit32.rshift(addr - 0x6000, 11)
		return normalizeOffset(page * 0x0800 + inner, prg_ram_size)
	end

	local function namco163_prg_ram_readable(addr: number): boolean
		if prg_ram_buf == nil or prg_ram_size <= 0 or addr < 0x6000 or addr >= 0x8000 then
			return false
		end

		if variant == NAMCO_VARIANT_163 then
			return true
		end

		if variant == NAMCO_VARIANT_175 then
			return true
		end

		return false
	end

	local function namco163_prg_ram_writable(addr: number): boolean
		if prg_ram_buf == nil or prg_ram_size <= 0 or addr < 0x6000 or addr >= 0x8000 then
			return false
		end

		if variant == NAMCO_VARIANT_163 then
			if not bit32.btest(write_protect, 0x40) then
				return false
			end

			local page_bit = bit32.lshift(1, bit32.rshift(addr - 0x6000, 11))
			return not bit32.btest(write_protect, page_bit)
		end

		if variant == NAMCO_VARIANT_175 then
			return bit32.btest(write_protect, 0x01)
		end

		return false
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
		local slot = bit32.rshift(addr, 10) + 1
		if chr_slot_nt[slot] then
			return -1
		end

		return chr_slot_base[slot] + bit32.band(addr, 0x03FF)
	end

	local function read_ppu(addr: number, _fetch_kind: number?, _sprite_16: boolean?): number?
		if vram_buf == nil then
			return nil
		end

		addr = bit32.band(addr, 0x1FFF)
		local slot = bit32.rshift(addr, 10) + 1
		if not chr_slot_nt[slot] then
			return nil
		end

		return buffer.readu8(vram_buf, chr_slot_base[slot] + bit32.band(addr, 0x03FF))
	end

	local function write_ppu(addr: number, value: number): boolean
		if vram_buf == nil then
			return false
		end

		addr = bit32.band(addr, 0x1FFF)
		local slot = bit32.rshift(addr, 10) + 1
		if not chr_slot_nt[slot] then
			return false
		end

		buffer.writeu8(vram_buf, chr_slot_base[slot] + bit32.band(addr, 0x03FF), value)
		return true
	end

	local function read_nametable(addr: number): number?
		local offset = bit32.band(addr, 0x0FFF)
		local slot = bit32.rshift(offset, 10) + 1
		local base = nt_slot_base[slot] + bit32.band(offset, 0x03FF)

		if nt_slot_chr[slot] then
			return read_buffer_u8(chr_buf, chr_size, base)
		end

		if vram_buf == nil then
			return 0
		end

		return buffer.readu8(vram_buf, base)
	end

	local function write_nametable(addr: number, value: number): boolean
		local offset = bit32.band(addr, 0x0FFF)
		local slot = bit32.rshift(offset, 10) + 1
		local base = nt_slot_base[slot] + bit32.band(offset, 0x03FF)

		if nt_slot_chr[slot] then
			if chr_is_ram then
				write_buffer_u8(chr_buf, chr_size, base, value)
			end
			return true
		end

		if vram_buf ~= nil then
			buffer.writeu8(vram_buf, base, value)
			return true
		end

		return false
	end

	local function read_cpu(addr: number): number?
		addr = bit32.band(addr, 0xFFFF)

		local reg = bit32.band(addr, 0xF800)
		if reg == 0x4800 then
			local value = buffer.readu8(audio_ram, audio_ram_pos)
			if audio_auto_increment then
				audio_ram_pos = bit32.band(audio_ram_pos + 1, 0x7F)
			end
			return value
		end
		if reg == 0x5000 then
			return bit32.band(irq_counter, 0xFF)
		end
		if reg == 0x5800 then
			return bit32.rshift(irq_counter, 8)
		end

		if namco163_prg_ram_readable(addr) then
			return buffer.readu8(prg_ram_buf :: buffer, namco163_prg_ram_offset(addr))
		end

		return nil
	end

	local function write_audio_register(addr: number, value: number)
		local reg = bit32.band(addr, 0xF800)
		if reg == 0x4800 then
			buffer.writeu8(audio_ram, audio_ram_pos, value)
			if audio_auto_increment then
				audio_ram_pos = bit32.band(audio_ram_pos + 1, 0x7F)
			end
		elseif reg == 0xE000 then
			_audio_disable_sound = bit32.btest(value, 0x40)
		elseif reg == 0xF800 then
			audio_ram_pos = bit32.band(value, 0x7F)
			audio_auto_increment = bit32.btest(value, 0x80)
		end
	end

	local function write_cpu(addr: number, value: number)
		addr = bit32.band(addr, 0xFFFF)

		if addr >= 0x6000 and addr < 0x8000 then
			not_namco340 = true
			if variant == NAMCO_VARIANT_340 then
				set_variant(NAMCO_VARIANT_UNKNOWN)
			end

			if namco163_prg_ram_writable(addr) then
				buffer.writeu8(prg_ram_buf :: buffer, namco163_prg_ram_offset(addr), value)
			end
			return
		end

		local reg = bit32.band(addr, 0xF800)
		if reg == 0x4800 then
			set_variant(NAMCO_VARIANT_163)
			write_audio_register(addr, value)
			return
		end

		if reg == 0x5000 then
			set_variant(NAMCO_VARIANT_163)
			irq_counter = bit32.bor(bit32.band(irq_counter, 0xFF00), value)
			irq_pending = false
			return
		end

		if reg == 0x5800 then
			set_variant(NAMCO_VARIANT_163)
			irq_counter = bit32.bor(bit32.band(irq_counter, 0x00FF), value * 256)
			irq_pending = false
			return
		end

		if reg == 0x8000 or reg == 0x8800 or reg == 0x9000 or reg == 0x9800 then
			local slot = bit32.rshift(reg - 0x8000, 11) + 1
			buffer.writeu8(pattern_regs, slot - 1, value)
			recalc_pattern_slot(slot)
			return
		end

		if reg == 0xA000 or reg == 0xA800 or reg == 0xB000 or reg == 0xB800 then
			local slot = bit32.rshift(reg - 0xA000, 11) + 5
			buffer.writeu8(pattern_regs, slot - 1, value)
			recalc_pattern_slot(slot)
			return
		end

		if reg == 0xC000 or reg == 0xC800 or reg == 0xD000 or reg == 0xD800 then
			if reg >= 0xC800 then
				set_variant(NAMCO_VARIANT_163)
			elseif variant ~= NAMCO_VARIANT_163 then
				set_variant(NAMCO_VARIANT_175)
			end

			if variant == NAMCO_VARIANT_175 then
				write_protect = value
			else
				local slot = bit32.rshift(reg - 0xC000, 11) + 1
				buffer.writeu8(nametable_regs, slot - 1, value)
				recalc_nametable_slot(slot)
			end
			return
		end

		if reg == 0xE000 then
			if bit32.btest(value, 0x80) then
				set_variant(NAMCO_VARIANT_340)
			elseif bit32.btest(value, 0x40) and variant ~= NAMCO_VARIANT_163 then
				set_variant(NAMCO_VARIANT_340)
			end

			prg_base0 = wrapBank(bit32.band(value, 0x3F), prg_total_8k) * 0x2000

			if variant == NAMCO_VARIANT_340 then
				local mode = bit32.band(bit32.rshift(value, 6), 0x03)
				mirroring = if mode == 0 then 0 elseif mode == 1 then 2 elseif mode == 2 then 3 else 1
			elseif variant == NAMCO_VARIANT_163 then
				write_audio_register(addr, value)
			end
			return
		end

		if reg == 0xE800 then
			prg_base1 = wrapBank(bit32.band(value, 0x3F), prg_total_8k) * 0x2000
			if variant == NAMCO_VARIANT_163 then
				low_chr_nt_mode = bit32.btest(value, 0x40)
				high_chr_nt_mode = bit32.btest(value, 0x80)
				recalc_pattern_slots()
			end
			return
		end

		if reg == 0xF000 then
			prg_base2 = wrapBank(bit32.band(value, 0x3F), prg_total_8k) * 0x2000
			return
		end

		if reg == 0xF800 then
			set_variant(NAMCO_VARIANT_163)
			if variant == NAMCO_VARIANT_163 then
				write_protect = value
				write_audio_register(addr, value)
			end
		end
	end

	local function clock_cpu(cycles: number)
		if cycles <= 0 or not bit32.btest(irq_counter, 0x8000) then
			return
		end

		local low = bit32.band(irq_counter, 0x7FFF)
		if low == 0x7FFF then
			return
		end

		local advanced = low + cycles
		if advanced >= 0x7FFF then
			irq_counter = 0xFFFF
			irq_pending = true
		else
			irq_counter = 0x8000 + advanced
		end
	end

	local function reset_mapper()
		mirroring = config.initialMirroring
		not_namco340 = false
		write_protect = 0
		low_chr_nt_mode = false
		high_chr_nt_mode = false
		irq_counter = 0
		irq_pending = false
		audio_ram_pos = 0
		audio_auto_increment = false
		_audio_disable_sound = false
		prg_base0 = 0
		prg_base1 = 0
		prg_base2 = 0
		prg_base3 = wrapBank(prg_total_8k - 1, prg_total_8k) * 0x2000

		buffer.fill(pattern_regs, 0, 0, 8)
		buffer.fill(nametable_regs, 0, 0, 4)
		buffer.fill(audio_ram, 0, 0, 0x80)

		if config.id == 19 then
			variant = NAMCO_VARIANT_163
			auto_detect_variant = true
		else
			if submapper == 1 then
				variant = NAMCO_VARIANT_175
				auto_detect_variant = false
			elseif submapper == 2 then
				variant = NAMCO_VARIANT_340
				auto_detect_variant = false
			else
				variant = NAMCO_VARIANT_UNKNOWN
				auto_detect_variant = true
			end
		end

		recalc_pattern_slots()
		recalc_nametable_slots()
	end

	reset_mapper()

	return {
		mapPrgAddr = map_prg_addr,
		mapChrAddr = map_chr_addr,
		write = write_cpu,
		readPpu = read_ppu,
		writePpu = write_ppu,
		readCpu = read_cpu,
		readNametable = read_nametable,
		writeNametable = write_nametable,
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

return {
	[19] = Namco163,
	[76] = function(config: MapperConfig)
		return create_namco108(config, '76')
	end,
	[88] = function(config: MapperConfig)
		return create_namco108(config, '88')
	end,
	[95] = function(config: MapperConfig)
		return create_namco108(config, '95')
	end,
	[154] = function(config: MapperConfig)
		return create_namco108(config, '154')
	end,
	[206] = function(config: MapperConfig)
		return create_namco108(config, '206')
	end,
	[210] = Namco163,
}

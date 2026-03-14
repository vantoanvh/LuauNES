--!optimize 2
--!native
--!strict

local Base = require'./Base'

type MapperConfig = Base.MapperConfig

local atLeastOne = Base.atLeastOne
local wrapBank = Base.wrapBank
local normalizeOffset = Base.normalizeOffset

--// MAPPER_116
local function Huang116(config: MapperConfig)
	local submapper = config.submapper or 0
	local four_screen = config.fourScreen
	local prg_total_8k = atLeastOne(config.prgSize // 0x2000)
	local prg_total_16k = atLeastOne(config.prgSize // 0x4000)
	local prg_total_32k = atLeastOne(config.prgSize // 0x8000)
	local chr_total_1k = atLeastOne(config.chrSize // 0x0400)
	local chr_total_4k = atLeastOne(config.chrSize // 0x1000)
	local chr_total_8k = atLeastOne(config.chrSize // 0x2000)
	local prg_ram_size = config.prgRamSize
	local prg_ram_available = prg_ram_size > 0

	local supervisor = 0x01
	local mirroring = if four_screen then 2 else config.initialMirroring

	local vrc2_chr = buffer.create(8)
	local vrc2_prg0 = 0
	local vrc2_prg1 = 1
	local vrc2_mirr = 0
	local vrc2_chr_base0 = 0
	local vrc2_chr_base1 = 0
	local vrc2_chr_base2 = 0
	local vrc2_chr_base3 = 0
	local vrc2_chr_base4 = 0
	local vrc2_chr_base5 = 0
	local vrc2_chr_base6 = 0
	local vrc2_chr_base7 = 0
	local vrc2_prg_base0 = 0
	local vrc2_prg_base1 = 0
	local vrc2_prg_base2 = 0
	local vrc2_prg_base3 = 0

	local mmc3_reg0 = 0
	local mmc3_reg1 = 2
	local mmc3_reg2 = 4
	local mmc3_reg3 = 5
	local mmc3_reg4 = 6
	local mmc3_reg5 = 7
	local mmc3_reg6 = 0xFC
	local mmc3_reg7 = 0xFD
	local mmc3_ctrl = 0
	local mmc3_mirr = 0
	local mmc3_prg_base0 = 0
	local mmc3_prg_base1 = 0
	local mmc3_prg_base2 = 0
	local mmc3_prg_base3 = 0
	local mmc3_chr_base0 = 0
	local mmc3_chr_base1 = 0
	local mmc3_chr_base2 = 0
	local mmc3_chr_base3 = 0
	local mmc3_chr_base4 = 0
	local mmc3_chr_base5 = 0
	local mmc3_chr_base6 = 0
	local mmc3_chr_base7 = 0
	local mmc3_irq_latch = 0
	local mmc3_irq_counter = 0
	local mmc3_irq_reload = false
	local mmc3_irq_enabled = false
	local mmc3_irq_pending = false
	local mmc3_a12_prev = false
	local mmc3_a12_low_cycles = 12

	local mmc1_control = 0x0C
	local mmc1_chr0 = 0
	local mmc1_chr1 = 0
	local mmc1_prg = 0
	local mmc1_shift = 0x10
	local mmc1_prg_32k_mode = false
	local mmc1_prg_base_32k = 0
	local mmc1_prg_base_8000 = 0
	local mmc1_prg_base_C000 = 0
	local mmc1_chr_8k_mode = false
	local mmc1_chr_base_8k = 0
	local mmc1_chr_base_0000 = 0
	local mmc1_chr_base_1000 = 0

	local function sync_active_mirroring()
		if four_screen then
			mirroring = 2
			return
		end

		local active_mode = bit32.band(supervisor, 0x03)
		if active_mode == 0 then
			mirroring = if bit32.band(vrc2_mirr, 0x01) == 0 then 2 else 3
		elseif active_mode == 1 then
			mirroring = if bit32.band(mmc3_mirr, 0x01) == 0 then 2 else 3
		else
			mirroring = bit32.band(mmc1_control, 0x03)
		end
	end

	local function current_chr_outer_base(): number
		return if bit32.btest(supervisor, 0x04) then 0x40000 else 0
	end

	local function set_vrc2_chr_reg(index: number, value: number)
		buffer.writeu8(vrc2_chr, index, value)
		local base = wrapBank(value, chr_total_1k) * 0x0400

		if index == 0 then
			vrc2_chr_base0 = base
		elseif index == 1 then
			vrc2_chr_base1 = base
		elseif index == 2 then
			vrc2_chr_base2 = base
		elseif index == 3 then
			vrc2_chr_base3 = base
		elseif index == 4 then
			vrc2_chr_base4 = base
		elseif index == 5 then
			vrc2_chr_base5 = base
		elseif index == 6 then
			vrc2_chr_base6 = base
		else
			vrc2_chr_base7 = base
		end
	end

	local function recalc_vrc2_prg_bases()
		vrc2_prg_base0 = wrapBank(vrc2_prg0, prg_total_8k) * 0x2000
		vrc2_prg_base1 = wrapBank(vrc2_prg1, prg_total_8k) * 0x2000
		vrc2_prg_base2 = wrapBank(prg_total_8k - 2, prg_total_8k) * 0x2000
		vrc2_prg_base3 = wrapBank(prg_total_8k - 1, prg_total_8k) * 0x2000
	end

	local function set_mmc3_reg(index: number, value: number)
		if index == 0 then
			mmc3_reg0 = value
		elseif index == 1 then
			mmc3_reg1 = value
		elseif index == 2 then
			mmc3_reg2 = value
		elseif index == 3 then
			mmc3_reg3 = value
		elseif index == 4 then
			mmc3_reg4 = value
		elseif index == 5 then
			mmc3_reg5 = value
		elseif index == 6 then
			mmc3_reg6 = value
		else
			mmc3_reg7 = value
		end
	end

	local function recalc_mmc3_prg_bases()
		local swap = bit32.band(bit32.rshift(mmc3_ctrl, 5), 0x02)
		local fixed_second_last = wrapBank(prg_total_8k - 2, prg_total_8k) * 0x2000
		local fixed_last = wrapBank(prg_total_8k - 1, prg_total_8k) * 0x2000
		local reg6_base = wrapBank(mmc3_reg6, prg_total_8k) * 0x2000
		local reg7_base = wrapBank(mmc3_reg7, prg_total_8k) * 0x2000

		if swap == 0 then
			mmc3_prg_base0 = reg6_base
			mmc3_prg_base2 = fixed_second_last
		else
			mmc3_prg_base0 = fixed_second_last
			mmc3_prg_base2 = reg6_base
		end

		mmc3_prg_base1 = reg7_base
		mmc3_prg_base3 = fixed_last
	end

	local function recalc_mmc3_chr_bases()
		local swap = bit32.band(mmc3_ctrl, 0x80) ~= 0
		local r0 = bit32.band(mmc3_reg0, 0xFE)
		local r1 = bit32.band(mmc3_reg1, 0xFE)
		local r2 = mmc3_reg2
		local r3 = mmc3_reg3
		local r4 = mmc3_reg4
		local r5 = mmc3_reg5

		if not swap then
			mmc3_chr_base0 = wrapBank(r0, chr_total_1k) * 0x0400
			mmc3_chr_base1 = wrapBank(r0 + 1, chr_total_1k) * 0x0400
			mmc3_chr_base2 = wrapBank(r1, chr_total_1k) * 0x0400
			mmc3_chr_base3 = wrapBank(r1 + 1, chr_total_1k) * 0x0400
			mmc3_chr_base4 = wrapBank(r2, chr_total_1k) * 0x0400
			mmc3_chr_base5 = wrapBank(r3, chr_total_1k) * 0x0400
			mmc3_chr_base6 = wrapBank(r4, chr_total_1k) * 0x0400
			mmc3_chr_base7 = wrapBank(r5, chr_total_1k) * 0x0400
		else
			mmc3_chr_base0 = wrapBank(r2, chr_total_1k) * 0x0400
			mmc3_chr_base1 = wrapBank(r3, chr_total_1k) * 0x0400
			mmc3_chr_base2 = wrapBank(r4, chr_total_1k) * 0x0400
			mmc3_chr_base3 = wrapBank(r5, chr_total_1k) * 0x0400
			mmc3_chr_base4 = wrapBank(r0, chr_total_1k) * 0x0400
			mmc3_chr_base5 = wrapBank(r0 + 1, chr_total_1k) * 0x0400
			mmc3_chr_base6 = wrapBank(r1, chr_total_1k) * 0x0400
			mmc3_chr_base7 = wrapBank(r1 + 1, chr_total_1k) * 0x0400
		end
	end

	local function recalc_mmc1_prg_map()
		local prg_mode = bit32.band(bit32.rshift(mmc1_control, 2), 0x03)
		local prg_bank_raw = bit32.band(mmc1_prg, 0x1F)
		if submapper == 2 then
			prg_bank_raw = bit32.rshift(prg_bank_raw, 1)
		end

		local prg_bank = bit32.band(prg_bank_raw, 0x0F)

		if prg_mode == 0 or prg_mode == 1 then
			mmc1_prg_32k_mode = true
			local bank32 = wrapBank(bit32.rshift(bit32.band(prg_bank_raw, 0x1E), 1), prg_total_32k)
			mmc1_prg_base_32k = bank32 * 0x8000
			return
		end

		mmc1_prg_32k_mode = false
		if prg_mode == 2 then
			mmc1_prg_base_8000 = 0
			mmc1_prg_base_C000 = wrapBank(prg_bank, prg_total_16k) * 0x4000
		else
			mmc1_prg_base_8000 = wrapBank(prg_bank, prg_total_16k) * 0x4000
			mmc1_prg_base_C000 = wrapBank(prg_total_16k - 1, prg_total_16k) * 0x4000
		end
	end

	local function recalc_mmc1_chr_map()
		if bit32.band(mmc1_control, 0x10) == 0 then
			mmc1_chr_8k_mode = true
			mmc1_chr_base_8k = wrapBank(bit32.rshift(bit32.band(mmc1_chr0, 0x1E), 1), chr_total_8k) * 0x2000
		else
			mmc1_chr_8k_mode = false
			mmc1_chr_base_0000 = wrapBank(bit32.band(mmc1_chr0, 0x1F), chr_total_4k) * 0x1000
			mmc1_chr_base_1000 = wrapBank(bit32.band(mmc1_chr1, 0x1F), chr_total_4k) * 0x1000
		end
	end

	local function mmc1_apply_control()
		recalc_mmc1_prg_map()
		recalc_mmc1_chr_map()
		sync_active_mirroring()
	end

	local function mmc1_reset_shift()
		mmc1_shift = 0x10
		mmc1_control = bit32.bor(mmc1_control, 0x0C)
		mmc1_apply_control()
	end

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return 0
		end

		local active_mode = bit32.band(supervisor, 0x03)
		if active_mode == 0 then
			local slot = bit32.rshift(addr - 0x8000, 13)
			if slot == 0 then
				return vrc2_prg_base0 + bit32.band(addr, 0x1FFF)
			end
			if slot == 1 then
				return vrc2_prg_base1 + bit32.band(addr, 0x1FFF)
			end
			if slot == 2 then
				return vrc2_prg_base2 + bit32.band(addr, 0x1FFF)
			end
			return vrc2_prg_base3 + bit32.band(addr, 0x1FFF)
		end

		if active_mode == 1 then
			local slot = bit32.rshift(addr - 0x8000, 13)
			if slot == 0 then
				return mmc3_prg_base0 + bit32.band(addr, 0x1FFF)
			end
			if slot == 1 then
				return mmc3_prg_base1 + bit32.band(addr, 0x1FFF)
			end
			if slot == 2 then
				return mmc3_prg_base2 + bit32.band(addr, 0x1FFF)
			end
			return mmc3_prg_base3 + bit32.band(addr, 0x1FFF)
		end

		if mmc1_prg_32k_mode then
			return mmc1_prg_base_32k + bit32.band(addr - 0x8000, 0x7FFF)
		end

		if addr < 0xC000 then
			return mmc1_prg_base_8000 + bit32.band(addr, 0x3FFF)
		end

		return mmc1_prg_base_C000 + bit32.band(addr, 0x3FFF)
	end

	local function map_chr_addr(addr: number, _fetch_kind: number?, _sprite_16: boolean?): number
		addr = bit32.band(addr, 0x1FFF)
		local outer_base = current_chr_outer_base()
		local active_mode = bit32.band(supervisor, 0x03)

		if active_mode == 0 then
			local segment = bit32.rshift(addr, 10)
			if segment == 0 then
				return outer_base + vrc2_chr_base0 + bit32.band(addr, 0x03FF)
			end
			if segment == 1 then
				return outer_base + vrc2_chr_base1 + bit32.band(addr, 0x03FF)
			end
			if segment == 2 then
				return outer_base + vrc2_chr_base2 + bit32.band(addr, 0x03FF)
			end
			if segment == 3 then
				return outer_base + vrc2_chr_base3 + bit32.band(addr, 0x03FF)
			end
			if segment == 4 then
				return outer_base + vrc2_chr_base4 + bit32.band(addr, 0x03FF)
			end
			if segment == 5 then
				return outer_base + vrc2_chr_base5 + bit32.band(addr, 0x03FF)
			end
			if segment == 6 then
				return outer_base + vrc2_chr_base6 + bit32.band(addr, 0x03FF)
			end
			return outer_base + vrc2_chr_base7 + bit32.band(addr, 0x03FF)
		end

		if active_mode == 1 then
			local segment = bit32.rshift(addr, 10)
			if segment == 0 then
				return outer_base + mmc3_chr_base0 + bit32.band(addr, 0x03FF)
			end
			if segment == 1 then
				return outer_base + mmc3_chr_base1 + bit32.band(addr, 0x03FF)
			end
			if segment == 2 then
				return outer_base + mmc3_chr_base2 + bit32.band(addr, 0x03FF)
			end
			if segment == 3 then
				return outer_base + mmc3_chr_base3 + bit32.band(addr, 0x03FF)
			end
			if segment == 4 then
				return outer_base + mmc3_chr_base4 + bit32.band(addr, 0x03FF)
			end
			if segment == 5 then
				return outer_base + mmc3_chr_base5 + bit32.band(addr, 0x03FF)
			end
			if segment == 6 then
				return outer_base + mmc3_chr_base6 + bit32.band(addr, 0x03FF)
			end
			return outer_base + mmc3_chr_base7 + bit32.band(addr, 0x03FF)
		end

		if mmc1_chr_8k_mode then
			return outer_base + mmc1_chr_base_8k + addr
		end

		if addr < 0x1000 then
			return outer_base + mmc1_chr_base_0000 + bit32.band(addr, 0x0FFF)
		end

		return outer_base + mmc1_chr_base_1000 + bit32.band(addr, 0x0FFF)
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

	local function write_vrc2(addr: number, value: number)
		if addr >= 0xB000 and addr <= 0xE003 then
			local index = bit32.band(bit32.rshift(bit32.bor(bit32.band(addr, 0x02), bit32.rshift(addr, 10)), 1) + 2, 0x07)
			local nibble_shift = bit32.band(addr, 0x01) * 4
			local old_value = buffer.readu8(vrc2_chr, index)
			local keep_mask = bit32.rshift(0xF0, nibble_shift)
			local new_value = bit32.bor(bit32.band(old_value, keep_mask), bit32.lshift(bit32.band(value, 0x0F), nibble_shift))

			set_vrc2_chr_reg(index, new_value)
			return
		end

		local region = bit32.band(addr, 0xF000)
		if region == 0x8000 then
			vrc2_prg0 = value
			vrc2_prg_base0 = wrapBank(value, prg_total_8k) * 0x2000
		elseif region == 0xA000 then
			vrc2_prg1 = value
			vrc2_prg_base1 = wrapBank(value, prg_total_8k) * 0x2000
		elseif region == 0x9000 then
			vrc2_mirr = value
			sync_active_mirroring()
		end
	end

	local function write_mmc3(addr: number, value: number)
		local even = bit32.band(addr, 0x01) == 0

		if addr < 0xA000 then
			if even then
				local old_ctrl = mmc3_ctrl
				mmc3_ctrl = value
				if bit32.band(old_ctrl, 0x40) ~= bit32.band(mmc3_ctrl, 0x40) then
					recalc_mmc3_prg_bases()
				end
				if bit32.band(old_ctrl, 0x80) ~= bit32.band(mmc3_ctrl, 0x80) then
					recalc_mmc3_chr_bases()
				end
			else
				local register_index = bit32.band(mmc3_ctrl, 0x07)
				set_mmc3_reg(register_index, value)
				if register_index < 6 then
					recalc_mmc3_chr_bases()
				else
					recalc_mmc3_prg_bases()
				end
			end
			return
		end

		if addr < 0xC000 then
			if even then
				mmc3_mirr = value
				sync_active_mirroring()
			end
			return
		end

		if addr < 0xE000 then
			if even then
				mmc3_irq_latch = value
			else
				mmc3_irq_reload = true
			end
			return
		end

		if even then
			mmc3_irq_enabled = false
			mmc3_irq_pending = false
		else
			mmc3_irq_enabled = true
		end
	end

	local function write_mmc1(addr: number, value: number)
		if bit32.btest(value, 0x80) then
			mmc1_reset_shift()
			return
		end

		local complete = bit32.band(mmc1_shift, 0x01) ~= 0
		mmc1_shift = bit32.rshift(mmc1_shift, 1)
		mmc1_shift = bit32.bor(mmc1_shift, bit32.band(value, 0x01) * 16)

		if not complete then
			return
		end

		local register_index = bit32.band(bit32.rshift(addr, 13), 0x03)
		local data = bit32.band(mmc1_shift, 0x1F)

		if register_index == 0 then
			mmc1_control = data
			mmc1_apply_control()
		elseif register_index == 1 then
			mmc1_chr0 = data
			recalc_mmc1_chr_map()
		elseif register_index == 2 then
			mmc1_chr1 = data
			recalc_mmc1_chr_map()
		else
			mmc1_prg = data
			recalc_mmc1_prg_map()
		end

		mmc1_shift = 0x10
	end

	local function write_cpu(addr: number, value: number)
		addr = bit32.band(addr, 0xFFFF)

		if addr < 0x6000 and bit32.band(addr, 0xE100) == 0x4100 then
			local old_mode = bit32.band(supervisor, 0x03)
			supervisor = bit32.band(value, 0x07)
			local new_mode = bit32.band(supervisor, 0x03)

			if submapper == 0 and old_mode < 2 and new_mode >= 2 then
				mmc1_reset_shift()
			else
				sync_active_mirroring()
			end

			return
		end

		if addr < 0x8000 then
			return
		end

		local active_mode = bit32.band(supervisor, 0x03)
		if active_mode == 0 then
			write_vrc2(addr, value)
		elseif active_mode == 1 then
			write_mmc3(addr, value)
		else
			write_mmc1(addr, value)
		end
	end

	local function clock_a12(a12_high: boolean)
		if bit32.band(supervisor, 0x03) ~= 1 then
			return
		end

		if a12_high then
			if not mmc3_a12_prev and mmc3_a12_low_cycles >= 12 then
				if mmc3_irq_counter == 0 or mmc3_irq_reload then
					mmc3_irq_counter = mmc3_irq_latch
					mmc3_irq_reload = false
				else
					mmc3_irq_counter = bit32.band(mmc3_irq_counter - 1, 0xFF)
				end

				if mmc3_irq_counter == 0 and mmc3_irq_enabled then
					mmc3_irq_pending = true
				end
			end

			mmc3_a12_prev = true
			mmc3_a12_low_cycles = 0
		else
			mmc3_a12_prev = false
			mmc3_a12_low_cycles = math.min(mmc3_a12_low_cycles + 1, 0x7FFFFFFF)
		end
	end

	local function reset_mapper()
		supervisor = 0x01
		mirroring = if four_screen then 2 else config.initialMirroring

		buffer.fill(vrc2_chr, 0, 0, 8)
		set_vrc2_chr_reg(0, 0xFF)
		set_vrc2_chr_reg(1, 0xFF)
		set_vrc2_chr_reg(2, 0xFF)
		set_vrc2_chr_reg(3, 0xFF)
		set_vrc2_chr_reg(4, 0x04)
		set_vrc2_chr_reg(5, 0x05)
		set_vrc2_chr_reg(6, 0x06)
		set_vrc2_chr_reg(7, 0x07)
		vrc2_prg0 = 0
		vrc2_prg1 = 1
		vrc2_mirr = 0
		recalc_vrc2_prg_bases()

		mmc3_reg0 = 0
		mmc3_reg1 = 2
		mmc3_reg2 = 4
		mmc3_reg3 = 5
		mmc3_reg4 = 6
		mmc3_reg5 = 7
		mmc3_reg6 = 0xFC
		mmc3_reg7 = 0xFD
		mmc3_ctrl = 0
		mmc3_mirr = 0
		recalc_mmc3_prg_bases()
		recalc_mmc3_chr_bases()
		mmc3_irq_latch = 0
		mmc3_irq_counter = 0
		mmc3_irq_reload = false
		mmc3_irq_enabled = false
		mmc3_irq_pending = false
		mmc3_a12_prev = false
		mmc3_a12_low_cycles = 12

		mmc1_control = 0x0C
		mmc1_chr0 = 0
		mmc1_chr1 = 0
		mmc1_prg = 0
		mmc1_shift = 0x10
		recalc_mmc1_prg_map()
		recalc_mmc1_chr_map()
		sync_active_mirroring()
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
		clockA12 = clock_a12,
		clockScanline = nil,
		onPpuAddress = nil,
		reset = reset_mapper,
		irqPending = function(): boolean
			return bit32.band(supervisor, 0x03) == 1 and mmc3_irq_pending
		end,
		clearIrq = function()
			mmc3_irq_pending = false
		end,
		getMirroring = function(): number
			return mirroring
		end,
		prgRamReadable = nil,
		prgRamWritable = nil,
	}
end

--// MAPPER_163
local function FC001_163(config: MapperConfig)
	local prg_banks_32k = atLeastOne(config.prgSize // 0x8000)
	local prg_ram_size = config.prgRamSize
	local prg_ram_available = prg_ram_size > 0

	local reg0 = 0
	local reg1 = 0
	local reg2 = 0
	local reg3 = 0
	local reg4 = 0
	local prg_base = 0
	local toggle = true
	local chr_auto_switch = false
	local chr_base_0000 = 0
	local chr_base_1000 = 0
	local current_scanline = 0

	local function set_chr_pages(page0: number, page1: number)
		chr_base_0000 = bit32.band(page0, 0x01) * 0x1000
		chr_base_1000 = bit32.band(page1, 0x01) * 0x1000
	end

	local function recalc_prg_base()
		local bank = bit32.bor(bit32.band(reg0, 0x0F), bit32.band(reg2, 0x0F) * 16)
		prg_base = wrapBank(bank, prg_banks_32k) * 0x8000
		chr_auto_switch = bit32.btest(reg0, 0x80)
	end

	local function map_prg_addr(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x8000 then
			return 0
		end

		return prg_base + bit32.band(addr - 0x8000, 0x7FFF)
	end

	local function map_chr_addr(addr: number, _fetch_kind: number?, _sprite_16: boolean?): number
		addr = bit32.band(addr, 0x1FFF)
		if addr < 0x1000 then
			return chr_base_0000 + addr
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

	local function read_cpu(addr: number): number?
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x5000 or addr > 0x5FFF then
			return nil
		end

		local masked = bit32.band(addr, 0x7700)
		if masked == 0x5100 then
			return bit32.bor(reg3, reg1, reg0, bit32.bxor(reg2, 0xFF))
		elseif masked == 0x5500 then
			return if toggle then bit32.bor(reg3, reg0) else 0
		end

		return 0x04
	end

	local function write_cpu(addr: number, value: number)
		addr = bit32.band(addr, 0xFFFF)
		if addr < 0x5000 or addr > 0x5FFF then
			return
		end

		if addr == 0x5101 then
			if reg4 ~= 0 and value == 0 then
				toggle = not toggle
			end
			reg4 = value
			return
		end

		if addr == 0x5100 and value == 0x06 then
			prg_base = wrapBank(3, prg_banks_32k) * 0x8000
			return
		end

		local masked = bit32.band(addr, 0x7300)
		if masked == 0x5000 then
			reg0 = value
			if not bit32.btest(reg0, 0x80) and current_scanline < 128 then
				set_chr_pages(0, 1)
			end
			recalc_prg_base()
			return
		end

		if masked == 0x5100 then
			reg1 = value
			if value == 0x06 then
				prg_base = wrapBank(3, prg_banks_32k) * 0x8000
			end
			return
		end

		if masked == 0x5200 then
			reg2 = value
			recalc_prg_base()
			return
		end

		if masked == 0x5300 then
			reg3 = value
		end
	end

	local function clock_scanline(scanline_value: number?)
		if scanline_value ~= nil then
			current_scanline = scanline_value
		end
	end

	local function on_ppu_address(_addr: number, scanline: number, cycle: number, _rendering: boolean)
		if not chr_auto_switch or cycle <= 256 then
			return
		end

		if scanline == 127 then
			set_chr_pages(1, 1)
		elseif scanline == 239 then
			set_chr_pages(0, 0)
		end
	end

	local function reset_mapper()
		reg0 = 0
		reg1 = 0
		reg2 = 0
		reg3 = 0
		reg4 = 0
		prg_base = 0
		toggle = true
		chr_auto_switch = false
		current_scanline = 0
		set_chr_pages(0, 0)
		recalc_prg_base()
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
		clockCpu = nil,
		clockA12 = nil,
		clockScanline = clock_scanline,
		onPpuAddress = on_ppu_address,
		reset = reset_mapper,
		irqPending = nil,
		clearIrq = function() end,
		getMirroring = nil,
		prgRamReadable = nil,
		prgRamWritable = nil,
	}
end

--// MAPPER_011
local function ColorDreams(config: MapperConfig)
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
		irqPending = nil,
		clearIrq = function() end,
		getMirroring = nil,
		prgRamReadable = nil,
		prgRamWritable = nil,
	}
end


--// MAPPER_071
local function Camerica(config: MapperConfig)
	local prg_banks_16k = atLeastOne(config.prgSize // 0x4000)
	local four_screen = config.fourScreen
	local mirroring = if four_screen then 2 else config.initialMirroring
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

		if addr >= 0x9000 and addr < 0xA000 and not four_screen then
			mirroring = if bit32.btest(value, 0x10) then 1 else 0
		end

		if addr >= 0xC000 then
			bank_select = wrapBank(bit32.band(value, 0x0F), prg_banks_16k)
		end
	end

	local function reset_mapper()
		bank_select = 0
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

--// MAPPER_079
local function NINA03_06(config: MapperConfig)
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
		if bit32.band(addr, 0xE100) ~= 0x4100 then
			return
		end

		chr_bank = wrapBank(bit32.band(value, 0x07), chr_banks_8k)
		prg_bank = wrapBank(bit32.band(bit32.rshift(value, 3), 0x01), prg_banks_32k)
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

return {
	[11] = ColorDreams,
	[71] = Camerica,
	[79] = NINA03_06,
	[116] = Huang116,
	[163] = FC001_163,
}

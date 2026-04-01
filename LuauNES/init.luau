--!native
--!nocheck
--!optimize 2

--// Modules

local Mappers = require'@self/Mappers'
local APU = require'@self/APU'

--// Buffers and data

local palette_rgba32 = buffer.create(256)
local nes_rgba32 = buffer.create(256)

local SPRITE_NORMAL_PIXEL = buffer.create(524288)
local SPRITE_FLIP_PIXEL = buffer.create(524288)

local prg_ram = buffer.create(8192)
local vram = buffer.create(4096)
local ram = buffer.create(2048)
local oam = buffer.create(256)

local NAMETABLE_1 = buffer.create(8192)
local NAMETABLE_2 = buffer.create(8192)
local NAMETABLE_3 = buffer.create(8192)
local NAMETABLE_4 = buffer.create(8192)
local NAMETABLE_5 = buffer.create(8192)

local PALETTE_ADDR_LUT = buffer.create(32)

local framebuffer = buffer.create(245760)
local palette = buffer.create(32)

local sprite_pattern_addr_next = buffer.create(16)
local sprite_scanline_data = buffer.create(1024)

local CRC32_TABLE = buffer.create(1024)

local sprite_slots_next = buffer.create(32)
local sprite_slots = buffer.create(32)

local prg_rom = buffer.create(0)
local chr_rom = buffer.create(0)

--// Unlocalized variables

local mapper = nil

local mapper_read_nametable = nil
local mapper_write_nametable = nil
local mapper_map_prg_ram_addr = nil

local mapper_map_prg_addr = nil
local mapper_map_chr_addr = nil
local mapper_write_cpu = nil
local mapper_read_cpu = nil
local mapper_read_ppu = nil
local mapper_write_ppu = nil

local mapper_clock_scanline = nil
local mapper_clock_cpu = nil
local mapper_clock_a12 = nil

local mapper_on_ppu_address = nil
local mapper_get_mirroring = nil
local mapper_irq_pending = nil

local mapper_prg_ram_readable = nil
local mapper_prg_ram_writable = nil

--// Booleans

local mapper_has_read_cpu = false
local mapper_has_write_cpu = false
local mapper_has_read_ppu = false
local mapper_has_write_ppu = false
local mapper_has_a12_clock = false
local mapper_has_cpu_clock = false
local mapper_has_irq_pending = false
local mapper_has_get_mirroring = false
local mapper_has_read_nametable = false
local mapper_has_scanline_clock = false
local mapper_has_write_nametable = false
local mapper_has_ppu_address_hook = false
local mapper_has_map_prg_ram_addr = false

local mapper_prg_read_side_effect = nil
local mapper_special_low_read = nil
local mapper_write_high_cpu = nil

local mapper_needs_sprite_fetch = false
local mapper_irq_pending_fast = false
local mapper_has_vrc7_audio = false

local sprite_overflow_next = false
local sprite_eval_active = false

local four_screen_mode = false

local zapper_enabled = false
local zapper_min_x = 255
local zapper_max_x = 0
local zapper_min_y = 239
local zapper_max_y = 0
local zapper_light = 0
local zapper_trigger_frames = 0

local mask_show_bg = false
local mask_show_sp = false
local mask_bg_left = false
local mask_sp_left = false
local mask_grayscale = false
local mask_rendering = false

local mapper_has_prg_ram_readable = false
local mapper_has_prg_ram_writable = false

local mapper_prg_ram_readable_state = true
local mapper_prg_ram_writable_state = true

local mapper_cpu_irq_current = false
local mapper_cpu_irq_prev = false
local mapper_branch_irq_delay = false

local mapper_is_mmc3 = false
local mapper_is_mmc5 = false
local mapper_is_vrc6 = false
local mapper_is_vrc7 = false

local mmc3_a12_prev = false
local mmc3_irq_reload = false
local mmc3_irq_enabled = false
local mmc3_irq_pending = false
local mmc3_a12_sampled = false

local nmi_pending_flag = false
local nmi_output = false
local nmi_line_state = false
local nmi_delay_cycles = 0
local irq_poll_delay = 0

local ctrl_sprite_8x16 = false
local page_crossed = false

local frame_ready = false
local chr_is_ram = false
local odd_frame = false

local cpu_instruction_active = false
local in_dma_transfer = false
local in_ppu_step = false
local cpu_jammed = false

--// Tables and data

local opcode_execute: {[number]: () -> ()} = {}

local MMC5_WRAM_UNITS_BY_CRC: {[number]: number} = {
	[0x6F4E4312] = 4,
	[0x15FE6D0F] = 2,
	[0x671F23A8] = 0,
	[0xCD4E7430] = 0,
	[0xED2465BE] = 0,
	[0xFE3488D1] = 2,
	[0x0EC6C023] = 1,
	[0x0AFB395E] = 0,
	[0x1CED086F] = 2,
	[0x9CBADC25] = 1,
	[0x6396B988] = 2,
	[0x9C18762B] = 2,
	[0xB0480AE9] = 0,
	[0xB4735FAC] = 0,
	[0xF540677B] = 4,
	[0xEEE9A682] = 2,
	[0xF9B4240F] = 2,
	[0x8CE478DB] = 2,
	[0xF011E490] = 4,
	[0xBC80FB52] = 1,
	[0x184C2124] = 4,
	[0xEE8E6553] = 4,
	[0xD532E98F] = 1,
	[0x39F2CE4B] = 2,
	[0xBB7F829A] = 0,
	[0xACA15643] = 2,
}

--// Values and Variables

local active_nametable_lut = NAMETABLE_4

local scanline = 0
local ppu_cycle = 0
local frame_row_start = 0
local oam_addr = 0
local visible_sprite_count = 0
local next_visible_sprite_count = 0

local sprite_scanline_generation = 1

local prg_rom_len = 0
local chr_rom_len = 0

local prg_ram_len = 0x2000

local status = 36

local a = 0
local x = 0
local y = 0

local sp = 253
local pc = 0

local data_buffer = 0
local ppu_status = 0
local addr_value = 0
local dma_cycles = 0

local mirroring_mode = 3

local sprite_eval_target_scanline = -1
local sprite_eval_sprite_height = 8
local sprite_eval_pattern_base = 0
local sprite_eval_stage = 0
local sprite_eval_n = 0
local sprite_eval_overflow_m = 0
local sprite_eval_latch = 0
local sprite_eval_candidate_y = 0
local sprite_eval_candidate_tile = 0
local sprite_eval_candidate_attr = 0

local fine_x = 0

local bg_nt_byte = 0
local bg_at_byte = 0
local bg_low_byte = 0
local bg_high_byte = 0

local bg_attr_latch_low = 0
local bg_attr_latch_high = 0
local bg_shift_pat_low = 0
local bg_shift_pat_high = 0
local bg_shift_attr_low = 0
local bg_shift_attr_high = 0

local cycles = 0

local ctrl_vram_increment = 1
local ctrl_bg_pattern_base = 0
local ctrl_sprite_pattern_base = 0
local ctrl_sprite_height = 8

local cpu_total_cycles = 0

local v = 0
local t = 0
local w = 0

local pad1_state = 0
local pad2_state = 0
local pad1_index = 0
local pad2_index = 0
local pad_strobe = 0
local jsr_target_low = 0
local indexed_high_plus_one = 0
local indexed_dummy_addr = 0
local open_bus = 0
local ppu_open_bus = 0

local mmc3_irq_latch = 0
local mmc3_irq_counter = 0
local mmc3_a12_low_cycles = 12

local cpu_bus_cycles = 0
local cpu_pending_cycles = 0
local apu_pending_cycles = 0

--// Connects APU to the main script

local apu = APU(function(addr: number): number
	local offset = mapper_map_prg_addr(addr)
	if offset < 0 or offset >= prg_rom_len then
		return 0
	end

	return buffer.readu8(prg_rom, offset)
end)

local apu_consume_dma_stall_cycles = apu.consumeDmaStallCycles
local apu_on_mmc5_cpu_read = apu.onMmc5CpuRead
local apu_irq_pending = apu.irqPending
local apu_read_status = apu.readStatus
local apu_sync_mixer = apu.syncMixer
local apu_write = apu.write
local apu_step = apu.step

local apu_write_vrc6 = apu.writeVrc6
local apu_write_vrc7 = apu.writeVrc7
local apu_write_mmc5 = apu.writeMmc5
local apu_read_mmc5 = apu.readMmc5

--// Helpers

local function build_nametable_lut(target: buffer, mode: number, is_four_screen: boolean)
	for offset = 0, 0x0FFF do
		local mapped = offset
		if not is_four_screen then
			local table_index = bit32.rshift(offset, 10)
			local inner = bit32.band(offset, 0x03FF)
			if mode == 0 then
				mapped = inner
			elseif mode == 1 then
				mapped = 0x0400 + inner
			elseif mode == 2 then
				mapped = bit32.band(table_index, 1) * 0x0400 + inner
			else
				mapped = if table_index < 2 then inner else 0x0400 + inner
			end
		end
		buffer.writeu16(target, offset * 2, mapped)
	end
end

--// Initialization

for i = 0, 31 do
	buffer.writeu8(PALETTE_ADDR_LUT, i, bit32.band(i, 0x13) == 16 and i - 16 or i)

	local base_color_index = bit32.band(buffer.readu8(palette, i), 0x3F)

	buffer.writeu32(
		palette_rgba32,
		i * 4,
		buffer.readu32(nes_rgba32, base_color_index * 4)
	)

	buffer.writeu32(
		palette_rgba32,
		(i + 32) * 4,
		buffer.readu32(nes_rgba32, bit32.band(base_color_index, 0x30) * 4)
	)
end

for i = 0, 255 do
	local low_shifted = i * 256
	for high = 0, 255 do
		local pattern_base = (low_shifted + high) * 8
		for offset = 0, 7 do
			local normal_bit = 7 - offset

			buffer.writeu8(SPRITE_NORMAL_PIXEL, pattern_base + offset,
				bit32.band(bit32.rshift(i, normal_bit), 1)
					+ bit32.band(bit32.rshift(high, normal_bit), 1) * 2
			)

			buffer.writeu8(SPRITE_FLIP_PIXEL, pattern_base + offset,
				bit32.band(bit32.rshift(i, offset), 1)
					+ bit32.band(bit32.rshift(high, offset), 1) * 2
			)
		end
	end

	local c = i

	for _ = 1, 8 do
		c = if bit32.btest(c, 1) then bit32.bxor(bit32.rshift(c, 1), 0xEDB88320) else bit32.rshift(c, 1)
	end 

	buffer.writeu32(CRC32_TABLE, i * 4, c)
end

--// Color Palettes

build_nametable_lut(NAMETABLE_1, 0, false)
build_nametable_lut(NAMETABLE_2, 1, false)
build_nametable_lut(NAMETABLE_3, 2, false)
build_nametable_lut(NAMETABLE_4, 3, false)
build_nametable_lut(NAMETABLE_5, 0, true)

for i, rgb in {

	0x626262, 0x001FB2, 0x2404C8, 0x5200B2, 0x730076, 0x800024, 0x730B00, 0x522800,
	0x244400, 0x005700, 0x005C00, 0x005324, 0x003C76, 0x000000, 0x000000, 0x000000,
	0xABABAB, 0x0D57FF, 0x4B30FF, 0x8A13FF, 0xBC08D6, 0xD21269, 0xC72E00, 0x9D5400,
	0x607B00, 0x209800, 0x00A300, 0x009942, 0x007DB4, 0x000000, 0x000000, 0x000000,
	0xFFFFFF, 0x53AEFF, 0x9085FF, 0xD365FF, 0xFF57FF, 0xFF5DCF, 0xFF7757, 0xFA9E00,
	0xBDC700, 0x7AE700, 0x43F611, 0x26EF7E, 0x2CD5F6, 0x4E4E4E, 0x000000, 0x000000,
	0xFFFFFF, 0xB6E1FF, 0xCED1FF, 0xE9C3FF, 0xFFBCFF, 0xFFBDF4, 0xFFC6C3, 0xFFD59A,
	0xE9E681, 0xCEF481, 0xB6FB9A, 0xA9FAC3, 0xA9F0F4, 0xB8B8B8, 0x000000, 0x000000

	} do

	buffer.writeu32(nes_rgba32, (i - 1) * 4,
		bit32.rshift(rgb, 16)
			+ bit32.band(bit32.rshift(rgb, 8), 255) * 256
			+ bit32.band(rgb, 255) * 65536
			+ 0xFF000000
	)
end

--// Main Functions

local function clock_mapper_cpu_cycles(cycles: number)
	if cycles <= 0 then
		return
	end

	if mapper_has_cpu_clock then
		local clock_cpu = mapper_clock_cpu
		local irq_pending = mapper_irq_pending_fast
		local irq_prev = mapper_cpu_irq_prev
		local irq_current = mapper_cpu_irq_current

		for _ = 1, cycles do
			clock_cpu(1)
			irq_prev = irq_current
			irq_current = irq_pending()
		end

		mapper_cpu_irq_prev = irq_prev
		mapper_cpu_irq_current = irq_current
	elseif mapper_has_irq_pending then
		mapper_cpu_irq_prev = mapper_cpu_irq_current
		mapper_cpu_irq_current = mapper_irq_pending_fast()
	else
		mapper_cpu_irq_prev = false
		mapper_cpu_irq_current = false
	end
end

local function sync_mapper_dynamic_state()
	if mapper_has_get_mirroring then
		local mapper_mirroring = mapper_get_mirroring()
		if mapper_mirroring ~= mirroring_mode then
			mirroring_mode = mapper_mirroring
			if four_screen_mode then
				active_nametable_lut = NAMETABLE_5
			elseif mapper_mirroring == 0 then
				active_nametable_lut = NAMETABLE_1
			elseif mapper_mirroring == 1 then
				active_nametable_lut = NAMETABLE_2
			elseif mapper_mirroring == 2 then
				active_nametable_lut = NAMETABLE_3
			else
				active_nametable_lut = NAMETABLE_4
			end
		end
	end

	mapper_prg_ram_readable_state = not mapper_has_prg_ram_readable or mapper_prg_ram_readable()
	mapper_prg_ram_writable_state = not mapper_has_prg_ram_writable or mapper_prg_ram_writable()
end

local function ppu_read(addr: number, fetch_kind: number?)
	local value = 0
	if addr >= 0x4000 then
		addr = bit32.band(addr, 0x3FFF)
	end

	if mapper_has_ppu_address_hook then
		mapper_on_ppu_address(addr, scanline, ppu_cycle + 1, mask_rendering)
	end

	if addr < 0x2000 then
		if mapper_is_mmc3 then
			local a12_high = addr >= 0x1000
			if in_ppu_step then
				mmc3_a12_sampled = a12_high
			else
				if a12_high then
					if not mmc3_a12_prev and mmc3_a12_low_cycles >= 12 then
						if mmc3_irq_counter == 0 or mmc3_irq_reload then
							mmc3_irq_counter = mmc3_irq_latch
							mmc3_irq_reload = false
						else
							mmc3_irq_counter = bit32.band(mmc3_irq_counter - 1, 255)
						end

						if mmc3_irq_counter == 0 and mmc3_irq_enabled then
							mmc3_irq_pending = true
						end
					end

					mmc3_a12_prev = true
					mmc3_a12_low_cycles = 0
				else
					mmc3_a12_prev = false
					if mmc3_a12_low_cycles < 12 then
						mmc3_a12_low_cycles += 1
					end
				end
			end
		elseif mapper_has_a12_clock then
			local a12_high = addr >= 0x1000
			if in_ppu_step then
				mmc3_a12_sampled = a12_high
			else
				mapper_clock_a12(a12_high)
			end
		end

		local kind = fetch_kind or 0
		if mapper_has_read_ppu then
			local mapper_value = mapper_read_ppu(addr, kind, ctrl_sprite_8x16)
			if mapper_value ~= nil then
				ppu_open_bus = mapper_value
				return mapper_value
			end
		end

		local mapped = mapper_map_chr_addr(addr, kind, ctrl_sprite_8x16)
		value = if mapped < 0 or mapped >= chr_rom_len then 0 else buffer.readu8(chr_rom, mapped)
		ppu_open_bus = value
		return value
	end

	if addr < 0x3F00 then
		if mapper_has_read_nametable then
			value = mapper_read_nametable(addr)
			if value then
				ppu_open_bus = value
				return value
			end
		end
		value = buffer.readu8(vram, buffer.readu16(active_nametable_lut, bit32.band(addr, 0x0FFF) * 2))
		ppu_open_bus = value
		return value
	end

	value = bit32.bor(
		bit32.band(ppu_open_bus, 0xC0),
		bit32.band(buffer.readu8(palette, buffer.readu8(PALETTE_ADDR_LUT, bit32.band(addr, 0x1F))), 0x3F)
	)
	ppu_open_bus = value
	return value
end

local function run_ppu_cycles(count: number)
	local mmc3_inline_a12 = mapper_is_mmc3
	local has_a12_clock = mapper_has_a12_clock
	local clock_a12 = mapper_clock_a12
	local needs_mapper_sprite_fetch = mapper_needs_sprite_fetch
	local has_scanline_clock = mapper_has_scanline_clock
	local clock_scanline = mapper_clock_scanline
	local map_chr_addr = mapper_map_chr_addr
	local chr_len = chr_rom_len
	local chr_buf = chr_rom
	local sprite_pattern_addr_next_buf = sprite_pattern_addr_next
	local sprite_8x16 = ctrl_sprite_8x16

	local show_bg = mask_show_bg
	local show_sp = mask_show_sp

	local bg_left_min_px = if mask_bg_left then 0 else 8
	local sp_left_min_px = if mask_sp_left then 0 else 8

	local grayscale_palette_offset = if mask_grayscale then 32 else 0

	local rendering = mask_rendering

	local bg_mux = bit32.rshift(0x8000, fine_x)
	local bg_pat_shift = 15 - fine_x
	local bg_attr_shift = bg_pat_shift - 2

	local sprite_height = ctrl_sprite_height
	local sprite_pattern_base = ctrl_sprite_pattern_base
	local bg_pattern_base = ctrl_bg_pattern_base
	local sprite_scanline_data_buf = sprite_scanline_data

	local zapper_min_x_local = zapper_min_x
	local zapper_max_x_local = zapper_max_x
	local zapper_min_y_local = zapper_min_y
	local zapper_max_y_local = zapper_max_y
	local zapper_light_local = zapper_light
	local zapper_active = zapper_enabled and zapper_min_x_local <= zapper_max_x_local and zapper_min_y_local <= zapper_max_y_local

	local sprite_pixel_lut_normal = SPRITE_NORMAL_PIXEL
	local sprite_pixel_lut_flip = SPRITE_FLIP_PIXEL
	local bg_shift_pat_low_local = bg_shift_pat_low
	local bg_shift_pat_high_local = bg_shift_pat_high
	local bg_shift_attr_low_local = bg_shift_attr_low
	local bg_shift_attr_high_local = bg_shift_attr_high
	local mmc3_irq_latch_local = mmc3_irq_latch
	local mmc3_irq_counter_local = mmc3_irq_counter
	local mmc3_irq_reload_local = mmc3_irq_reload
	local mmc3_irq_enabled_local = mmc3_irq_enabled
	local mmc3_irq_pending_local = mmc3_irq_pending
	local mmc3_a12_prev_local = mmc3_a12_prev
	local mmc3_a12_low_cycles_local = mmc3_a12_low_cycles

	local fr_row_start = frame_row_start
	local scanline_local = scanline

	local sprite_slots_next_buf = sprite_slots_next
	local sprite_slots_buf = sprite_slots

	local sprite_generation_tag = sprite_scanline_generation * 65536

	local visible_line = scanline_local < 240
	local pre_render_line = scanline_local == 261

	local sprite_eval_latch_cache = sprite_eval_latch
	local sprite_eval_stage_cache = sprite_eval_stage

	local framebuffer_cache = framebuffer

	local _v = v
	local _t = t

	in_ppu_step = true

	for _ = 1, count do
		local cycle = ppu_cycle + 1

		mmc3_a12_sampled = false

		if ppu_cycle == 0 then
			if zapper_light_local > 0 then
				zapper_light_local -= 1
			end

			if has_scanline_clock then
				clock_scanline(scanline_local)
			end

			if visible_line then
				fr_row_start = scanline_local * 1024
				if rendering then
					sprite_slots_buf, sprite_slots_next_buf = sprite_slots_next_buf, sprite_slots_buf

					visible_sprite_count = next_visible_sprite_count
					if sprite_overflow_next then
						ppu_status = bit32.bor(ppu_status, 0x20)
					end
				else
					visible_sprite_count = 0
					next_visible_sprite_count = 0
					sprite_overflow_next = false
				end

				if sprite_scanline_generation == 255 then
					buffer.fill(sprite_scanline_data_buf, 0, 0, 1024)
					sprite_scanline_generation = 1
				else
					sprite_scanline_generation += 1
				end

				-- Tag sprite-cache entries by generation so most scanlines avoid a full clear.
				-- Compare the packed generation bits directly to avoid per-pixel shift/mask work.
				sprite_generation_tag = sprite_scanline_generation * 65536

				for i = 0, visible_sprite_count - 1 do
					local sprite_slot = buffer.readu32(sprite_slots_buf, i * 4)
					local sx = bit32.band(sprite_slot, 0xFF)

					local sp_low = bit32.band(bit32.rshift(sprite_slot, 8), 0xFF)
					local sp_high = bit32.band(bit32.rshift(sprite_slot, 16), 0xFF)

					if sp_low == 0 and sp_high == 0 then
						continue
					end

					local meta = bit32.rshift(sprite_slot, 24)

					local pixel_lut = if bit32.btest(meta, 0x20) then sprite_pixel_lut_flip else sprite_pixel_lut_normal

					local pixel_base = (sp_low * 256 + sp_high) * 8
					local scanline_meta_base = sprite_generation_tag + meta * 256 + bit32.band(meta, 0x1F)

					for offset = 0, 7 do
						local px = sx + offset
						if px >= 256 then
							break
						end

						local scanline_off = px * 4
						if bit32.band(buffer.readu32(sprite_scanline_data_buf, scanline_off), 0x00FF0000) ~= sprite_generation_tag then
							local pixel = buffer.readu8(pixel_lut, pixel_base + offset)
							if pixel ~= 0 then
								buffer.writeu32(sprite_scanline_data_buf, scanline_off, scanline_meta_base + pixel)
							end
						end
					end
				end
			end

			if pre_render_line and not rendering then
				next_visible_sprite_count = 0
				sprite_overflow_next = false
			end
			sprite_eval_active = false
			sprite_eval_stage_cache = 0
			sprite_eval_n = 0
			sprite_eval_overflow_m = 0
		end

		if visible_line and cycle <= 256 then
			local px = cycle - 1
			local pixel_offset = px * 4
			local bg = 0
			if show_bg and px >= bg_left_min_px then
				bg =
					bit32.rshift(bit32.band(bg_shift_attr_low_local, bg_mux), bg_attr_shift)
					+ bit32.rshift(bit32.band(bg_shift_attr_high_local, bg_mux), bg_attr_shift - 1)
					+ bit32.rshift(bit32.band(bg_shift_pat_low_local, bg_mux), bg_pat_shift)
					+ bit32.rshift(bit32.band(bg_shift_pat_high_local, bg_mux), bg_pat_shift - 1)
			end

			local is_bg_pixel = bit32.band(bg, 3) == 0
			local is_sp_pixel = true

			local sp_color_index = 0
			local sprite_entry = 0

			if show_sp and px >= sp_left_min_px then
				sprite_entry = buffer.readu32(sprite_scanline_data_buf, pixel_offset)
				if bit32.band(sprite_entry, 0x00FF0000) == sprite_generation_tag then
					sp_color_index = bit32.band(sprite_entry, 255)
					is_sp_pixel = bit32.band(sp_color_index, 3) == 0
				else
					sprite_entry = 0
				end
			end

			local color_index = 0

			-- Resolve sprite/background priority after both pixel sources are known.
			if is_bg_pixel and is_sp_pixel then
				-- do nothing
			elseif is_bg_pixel then
				color_index = sp_color_index
			elseif is_sp_pixel then
				color_index = bg
			else
				if bit32.btest(sprite_entry, 0x8000) and px < 255 then
					ppu_status = bit32.bor(ppu_status, 0x40)
				end

				color_index = bit32.btest(sprite_entry, 0x4000) and bg or sp_color_index
			end

			local pixel_rgba = buffer.readu32(palette_rgba32, (color_index + grayscale_palette_offset) * 4)
			buffer.writeu32(framebuffer_cache, fr_row_start + pixel_offset, pixel_rgba)

			if zapper_active and scanline_local >= zapper_min_y_local and scanline_local <= zapper_max_y_local and px >= zapper_min_x_local and px <= zapper_max_x_local then
				local r = bit32.band(pixel_rgba, 0xFF)
				local g = bit32.band(bit32.rshift(pixel_rgba, 8), 0xFF)
				local b = bit32.band(bit32.rshift(pixel_rgba, 16), 0xFF)
				if r * 30 + g * 59 + b * 11 >= 12000 and zapper_light_local < 24 then
					zapper_light_local = 24
				end
			end
		end

		if pre_render_line and cycle == 1 then
			ppu_status = bit32.band(ppu_status, 0x1F)
			local current_line = nmi_output and bit32.btest(ppu_status, 0x80)
			if current_line then
				if not nmi_line_state then
					nmi_delay_cycles = 2
				end
			elseif nmi_delay_cycles > 0 then
				nmi_delay_cycles = 0
			end
			nmi_line_state = current_line
		elseif scanline_local == 241 and cycle == 1 then
			ppu_status = bit32.bor(ppu_status, 0x80)
			local current_line = nmi_output and bit32.btest(ppu_status, 0x80)
			if current_line then
				if not nmi_line_state then
					nmi_delay_cycles = 2
				end
			elseif nmi_delay_cycles > 0 then
				nmi_delay_cycles = 0
			end
			nmi_line_state = current_line
		end

		if rendering and (visible_line or pre_render_line) then

			-- Begin the next scanline's sprite-evaluation state machine.
			if cycle == 64 then
				local line_y = if pre_render_line then 0 else scanline_local + 1

				next_visible_sprite_count = 0
				sprite_overflow_next = false

				sprite_eval_target_scanline = line_y
				sprite_eval_sprite_height = sprite_height
				sprite_eval_pattern_base = sprite_pattern_base
				sprite_eval_stage_cache = 0
				sprite_eval_n = 0
				sprite_eval_overflow_m = 0
				sprite_eval_latch_cache = 0
				sprite_eval_candidate_y = 0
				sprite_eval_candidate_tile = 0
				sprite_eval_candidate_attr = 0

				sprite_eval_active = line_y < 240 and show_sp
			end

			if cycle == 256 then
				if bit32.band(_v, 0x7000) ~= 0x7000 then
					_v = bit32.band(_v + 0x1000, 0x7FFF)
				else
					_v = bit32.band(_v, bit32.bnot(0x7000))

					local coarse_y = bit32.band(bit32.rshift(_v, 5), 0x1F)
					if coarse_y == 29 then
						coarse_y = 0
						_v = bit32.bxor(_v, 0x0800)
					elseif coarse_y == 31 then
						coarse_y = 0
					else
						coarse_y += 1
					end

					_v = bit32.bor(bit32.band(_v, bit32.bnot(0x03E0)), coarse_y * 32)
				end
			end

			if cycle == 257 then
				_v = bit32.bor(
					bit32.band(_v, 0x7BE0),
					bit32.band(_t, 0x041F)
				)
			end

			if pre_render_line and cycle >= 280 and cycle <= 304 then
				_v = bit32.bor(
					bit32.band(_v, 0x041F),
					bit32.band(_t, 0x7BE0)
				)
			end

			if sprite_eval_active and cycle >= 65 and cycle <= 256 then
				if sprite_eval_n >= 64 then
					sprite_eval_active = false
				else
					if bit32.btest(cycle, 1) then
						sprite_eval_latch_cache = buffer.readu8(oam, sprite_eval_n * 4 + (sprite_eval_stage_cache == 4 and sprite_eval_overflow_m or sprite_eval_stage_cache))
					elseif sprite_eval_stage_cache == 0 then
						local row = sprite_eval_target_scanline - sprite_eval_latch_cache - 1
						if row < 0 or row >= sprite_eval_sprite_height then
							sprite_eval_n += 1
							if sprite_eval_n >= 64 then
								sprite_eval_active = false
							end
						elseif next_visible_sprite_count >= 8 then
							sprite_overflow_next = true
							ppu_status = bit32.bor(ppu_status, 0x20)
							sprite_eval_stage_cache = 4
							sprite_eval_overflow_m = 1
						else
							sprite_eval_candidate_y = sprite_eval_latch_cache
							sprite_eval_stage_cache = 1
						end
					elseif sprite_eval_stage_cache == 1 then
						sprite_eval_candidate_tile = sprite_eval_latch_cache
						sprite_eval_stage_cache = 2
					elseif sprite_eval_stage_cache == 2 then
						sprite_eval_candidate_attr = sprite_eval_latch_cache
						sprite_eval_stage_cache = 3
					elseif sprite_eval_stage_cache == 3 then
						local tile = sprite_eval_candidate_tile
						local attr = sprite_eval_candidate_attr

						local row = sprite_eval_target_scanline - sprite_eval_candidate_y - 1

						if bit32.btest(attr, 0x80) then
							row = sprite_eval_sprite_height - 1 - row
						end

						local pattern_bank = sprite_eval_pattern_base
						local tile_index = tile
						if sprite_eval_sprite_height == 16 then
							pattern_bank = bit32.btest(tile, 1) and 0x1000 or 0
							tile_index = bit32.band(tile, 0xFE)
							if row >= 8 then
								tile_index += 1
								row -= 8
							end
						end

						local pattern_addr = pattern_bank + tile_index * 16 + row
						local meta = (bit32.band(attr, 3) + 4) * 4
						if bit32.btest(attr, 0x40) then
							meta += 0x20
						end
						if bit32.btest(attr, 0x20) then
							meta += 0x40
						end
						if sprite_eval_n == 0 then
							meta += 0x80
						end

						local out_index = next_visible_sprite_count

						buffer.writeu32(sprite_slots_next, out_index * 4, sprite_eval_latch_cache + meta * 16777216)
						buffer.writeu16(sprite_pattern_addr_next, out_index * 2, pattern_addr)

						next_visible_sprite_count += 1

						sprite_eval_n += 1
						sprite_eval_stage_cache = 0
						if sprite_eval_n >= 64 then
							sprite_eval_active = false
						end
					else
						-- Overflow bug mode: diagonal scan over primary OAM bytes (n increments with m).
						local row = sprite_eval_target_scanline - sprite_eval_latch_cache - 1
						if row >= 0 and row < sprite_eval_sprite_height then
							sprite_overflow_next = true
							ppu_status = bit32.bor(ppu_status, 0x20)
						end

						sprite_eval_n += 1
						sprite_eval_overflow_m = bit32.band(sprite_eval_overflow_m + 1, 3)
						if sprite_eval_n >= 64 then
							sprite_eval_active = false
						end
					end
				end
			end

			-- Advance the background fetch pipeline on visible/fetch dots.
			if cycle <= 256 or (cycle >= 321 and cycle <= 336) then
				bg_shift_pat_low_local = bit32.band(bg_shift_pat_low_local * 2 + 1, 0xFFFF)
				bg_shift_pat_high_local = bit32.band(bg_shift_pat_high_local * 2 + 1, 0xFFFF)
				bg_shift_attr_low_local = bit32.band(bg_shift_attr_low_local * 2 + 1, 0xFFFF)
				bg_shift_attr_high_local = bit32.band(bg_shift_attr_high_local * 2 + 1, 0xFFFF)

				local phase = bit32.band(cycle, 7)

				if phase == 1 then
					bg_nt_byte = ppu_read(bit32.bor(0x2000, bit32.band(_v, 0x0FFF)))
				elseif phase == 3 then
					bg_at_byte = ppu_read(
						bit32.bor(
							0x23C0,
							bit32.band(_v, 0x0C00),
							bit32.band(bit32.rshift(_v, 4), 0x38),
							bit32.band(bit32.rshift(_v, 2), 7)
						)
					)

					bg_at_byte = bit32.band(bit32.rshift(bg_at_byte, bit32.bor(
						bit32.band(bit32.rshift(_v, 4), 4),
						bit32.band(_v, 2)
						)), 3
					)

					bg_attr_latch_low = bit32.band(bg_at_byte, 1) * 255
					bg_attr_latch_high = bit32.band(bit32.rshift(bg_at_byte, 1), 1) * 255
				elseif phase == 5 then
					bg_low_byte = ppu_read(bg_pattern_base + bg_nt_byte * 16 + bit32.band(bit32.rshift(_v, 12), 7), 1)
				elseif phase == 7 then
					bg_high_byte = ppu_read(bg_pattern_base + bg_nt_byte * 16 + bit32.band(bit32.rshift(_v, 12), 7) + 8, 1)
				elseif phase == 0 then
					bg_shift_pat_low_local = bit32.bor(bit32.band(bg_shift_pat_low_local, 0xFF00), bg_low_byte)
					bg_shift_pat_high_local = bit32.bor(bit32.band(bg_shift_pat_high_local, 0xFF00), bg_high_byte)
					bg_shift_attr_low_local = bit32.bor(bit32.band(bg_shift_attr_low_local, 0xFF00), bg_attr_latch_low)
					bg_shift_attr_high_local = bit32.bor(bit32.band(bg_shift_attr_high_local, 0xFF00), bg_attr_latch_high)

					_v = if bit32.band(_v, 0x001F) == 31 then bit32.bxor(bit32.band(_v, 0x7FE0), 0x0400) else _v == 32767 and 0 or _v + 1
				end
			end

			if cycle == 337 or cycle == 339 then
				ppu_read(bit32.bor(0x2000, bit32.band(_v, 0x0FFF)))
			end

			if cycle >= 257 and cycle <= 320 then
				local slot_phase = bit32.band(cycle - 257, 7)
				if slot_phase == 4 or slot_phase == 6 then
					local slot = bit32.rshift(cycle - 257, 3)
					local pattern_addr = 0x1FF0
					local has_sprite = slot < next_visible_sprite_count

					if has_sprite or needs_mapper_sprite_fetch then
						if has_sprite then
							pattern_addr = buffer.readu16(sprite_pattern_addr_next_buf, slot * 2)
						end

						local value_addr = slot_phase == 4 and pattern_addr or pattern_addr + 8
						local value = 0
						if needs_mapper_sprite_fetch then
							value = ppu_read(value_addr, 2)
						else
							local mapped = map_chr_addr(value_addr, 2, sprite_8x16)
							value = if mapped < 0 or mapped >= chr_len then 0 else buffer.readu8(chr_buf, mapped)
						end

						if has_sprite then
							buffer.writeu8(sprite_slots_next, slot * 4 + (slot_phase == 4 and 1 or 2), value)
						end
					end
				end
			end
		end

		if mmc3_inline_a12 then
			if mmc3_a12_sampled then
				if not mmc3_a12_prev_local and mmc3_a12_low_cycles_local >= 12 then
					if mmc3_irq_counter_local == 0 or mmc3_irq_reload_local then
						mmc3_irq_counter_local = mmc3_irq_latch_local
						mmc3_irq_reload_local = false
					else
						mmc3_irq_counter_local = mmc3_irq_counter_local == 0 and 255 or mmc3_irq_counter_local - 1
					end

					if mmc3_irq_counter_local == 0 and mmc3_irq_enabled_local then
						mmc3_irq_pending_local = true
					end
				end

				mmc3_a12_prev_local = true
				mmc3_a12_low_cycles_local = 0
			else
				mmc3_a12_prev_local = false
				if mmc3_a12_low_cycles_local < 12 then
					mmc3_a12_low_cycles_local += 1
				end
			end
		elseif has_a12_clock then
			clock_a12(mmc3_a12_sampled)
		end

		if rendering and pre_render_line and odd_frame and ppu_cycle == 339 then
			ppu_cycle = 0
			scanline_local = 0
			visible_line = false
			pre_render_line = false
			frame_ready = true
			odd_frame = false
			continue
		end

		ppu_cycle = cycle
		if ppu_cycle > 340 then
			ppu_cycle = 0

			if scanline_local > 260 then
				scanline_local = 0
				frame_ready = true
				odd_frame = not odd_frame
			else
				scanline_local += 1
			end

			visible_line = scanline_local < 240
			pre_render_line = scanline_local == 261
		end
	end

	sprite_eval_stage = sprite_eval_stage_cache
	sprite_eval_latch = sprite_eval_latch_cache
	v = _v

	sprite_slots = sprite_slots_buf
	sprite_slots_next = sprite_slots_next_buf

	scanline = scanline_local
	frame_row_start = fr_row_start

	in_ppu_step = false
	bg_shift_pat_low = bg_shift_pat_low_local
	bg_shift_pat_high = bg_shift_pat_high_local
	bg_shift_attr_low = bg_shift_attr_low_local
	bg_shift_attr_high = bg_shift_attr_high_local
	zapper_light = zapper_light_local

	if mmc3_inline_a12 then
		mmc3_irq_counter = mmc3_irq_counter_local
		mmc3_irq_reload = mmc3_irq_reload_local
		mmc3_irq_pending = mmc3_irq_pending_local
		mmc3_a12_prev = mmc3_a12_prev_local
		mmc3_a12_low_cycles = mmc3_a12_low_cycles_local
	end
end

local function flush_cpu_timing()
	if cpu_pending_cycles > 0 then
		local pending = cpu_pending_cycles
		cpu_pending_cycles = 0
		cpu_total_cycles += pending
		run_ppu_cycles(pending * 3)
		
		if nmi_delay_cycles > 0 then
			nmi_delay_cycles -= pending
			if nmi_delay_cycles <= 0 then
				nmi_delay_cycles = 0
				nmi_pending_flag = true
			end
		end
		
		clock_mapper_cpu_cycles(pending)
		apu_pending_cycles += pending
	end
end

local function flush_cpu_timing_apuflush()
	if cpu_pending_cycles > 0 then
		local pending = cpu_pending_cycles
		cpu_total_cycles += pending
		cpu_pending_cycles = 0
		run_ppu_cycles(pending * 3)
		
		if nmi_delay_cycles > 0 then
			nmi_delay_cycles -= pending
			if nmi_delay_cycles <= 0 then
				nmi_delay_cycles = 0
				nmi_pending_flag = true
			end
		end
		
		clock_mapper_cpu_cycles(pending)
		apu_pending_cycles += pending
	end

	local stalls = apu_consume_dma_stall_cycles()
	while stalls > 0 do
		cpu_total_cycles += stalls
		run_ppu_cycles(stalls * 3)
		
		if nmi_delay_cycles > 0 then
			nmi_delay_cycles -= stalls
			if nmi_delay_cycles <= 0 then
				nmi_delay_cycles = 0
				nmi_pending_flag = true
			end
		end
		
		clock_mapper_cpu_cycles(stalls)
		apu_step(stalls)
		stalls = apu_consume_dma_stall_cycles()
	end

	if apu_pending_cycles <= 0 then
		apu_sync_mixer()
	else
		local pending = apu_pending_cycles
		apu_pending_cycles = 0
		apu_step(pending)
		apu_sync_mixer()
	end
end

local function bus_read(addr)
	if cpu_instruction_active and not in_dma_transfer then
		cpu_bus_cycles += 1
		cpu_pending_cycles += 1
	end

	if addr >= 0x10000 or addr < 0 then
		addr = bit32.band(addr, 0xFFFF)
	end

	if addr < 0x2000 then
		local value = buffer.readu8(ram, bit32.band(addr, 0x07FF))
		open_bus = value
		return value
	end

	if addr >= 0x8000 then
		local offset = mapper_map_prg_addr(addr)
		local value = if offset >= 0 and offset < prg_rom_len then buffer.readu8(prg_rom, offset) else 0
		if mapper_prg_read_side_effect and addr <= 0xBFFF then
			mapper_prg_read_side_effect(addr, value)
		end
		open_bus = value
		return value
	end

	if addr < 0x4000 then -- register read
		flush_cpu_timing()
		local reg = bit32.band(addr, 7)

		if reg == 2 then
			local value = bit32.bor(bit32.band(ppu_status, 0xE0), bit32.band(ppu_open_bus, 0x1F))
			ppu_status = bit32.band(ppu_status, 0x7F)
			local current_line = nmi_output and bit32.btest(ppu_status, 0x80)
			if current_line then
				if not nmi_line_state then
					nmi_delay_cycles = 2
				end
			elseif nmi_delay_cycles > 0 then
				nmi_delay_cycles = 0
			end
			nmi_line_state = current_line
			w = 0
			ppu_open_bus = value
			open_bus = value
			return value
		elseif reg == 4 then
			local value = buffer.readu8(oam, oam_addr)
			ppu_open_bus = value
			open_bus = value
			return value
		elseif reg == 7 then
			local value = data_buffer
			data_buffer = ppu_read(v)
			if v >= 0x3F00 then
				value = data_buffer
				data_buffer = ppu_read(v - 0x1000)
			end
			
			if mask_rendering and (scanline < 240 or scanline == 261) then
				if bit32.band(v, 0x7000) ~= 0x7000 then
					v = bit32.band(v + 0x1000, 0x7FFF)
				else
					v = bit32.band(v, bit32.bnot(0x7000))

					local coarse_y = bit32.band(bit32.rshift(v, 5), 0x1F)
					if coarse_y == 29 then
						coarse_y = 0
						v = bit32.bxor(v, 0x0800)
					elseif coarse_y == 31 then
						coarse_y = 0
					else
						coarse_y += 1
					end

					v = bit32.bor(bit32.band(v, bit32.bnot(0x03E0)), coarse_y * 32)
				end
			else
				v = bit32.band(v + ctrl_vram_increment, 0x7FFF)
			end
			
			ppu_open_bus = value
			open_bus = value
			return value
		else
			open_bus = ppu_open_bus
			return ppu_open_bus
		end
	end

	if addr == 0x4015 then
		flush_cpu_timing_apuflush()
		local value = apu_read_status()
		open_bus = value
		return value
	end

	if addr == 0x4016 then
		flush_cpu_timing()
		local index = pad1_index

		if index > 7 then
			local value = 0x41
			open_bus = value
			return value
		else
			local value = bit32.bor(bit32.band(bit32.rshift(pad1_state, index), 1), 0x40)
			if pad_strobe == 0 then
				pad1_index = index + 1
			end

			open_bus = value
			return value
		end
	end

	if addr == 0x4017 then
		flush_cpu_timing()
		local index = pad2_index
		local value = 0x41

		if index <= 7 then
			value = bit32.bor(bit32.band(bit32.rshift(pad2_state, index), 1), 0x40)
			if pad_strobe == 0 then
				pad2_index = index + 1
			end
		end

		if zapper_enabled then
			if zapper_light <= 0 then
				value = bit32.bor(value, 0x08)
			end
			if zapper_trigger_frames > 0 then
				value = bit32.bor(value, 0x10)
			end
		end

		open_bus = value
		return value
	end

	if addr < 0x4020 then
		return open_bus
	end

	if mapper_special_low_read and (addr == 0x5010 or addr == 0x5015) then
		flush_cpu_timing_apuflush()
		local special_value = mapper_special_low_read(addr)
		if special_value then
			open_bus = special_value
			return special_value
		end
	end

	if addr < 0x6000 then
		flush_cpu_timing()
		if mapper_has_read_cpu then
			local mapper_value = mapper_read_cpu(addr)
			if mapper_value then
				open_bus = mapper_value
				return mapper_value
			end
		end
		return open_bus
	end

	if mapper_has_map_prg_ram_addr then
		local ram_addr = mapper_map_prg_ram_addr(addr)
		if ram_addr then
			if ram_addr < 0 or ram_addr >= prg_ram_len or not mapper_prg_ram_readable_state then
				return open_bus
			end

			local value = buffer.readu8(prg_ram, ram_addr)
			open_bus = value
			return value
		end
	end

	if mapper_has_read_cpu then
		local mapper_value = mapper_read_cpu(addr)
		if mapper_value then
			open_bus = mapper_value
			return mapper_value
		end
	end

	return open_bus
end

local function bus_write(addr: number, value: number)
	if cpu_instruction_active and not in_dma_transfer then
		cpu_bus_cycles += 1
		cpu_pending_cycles += 1
	end

	if addr >= 0x10000 or addr < 0 then
		addr = bit32.band(addr, 0xFFFF)
	end

	value = bit32.band(value, 255)
	open_bus = value

	if addr < 0x2000 then
		buffer.writeu8(ram, bit32.band(addr, 0x07FF), value)
	elseif addr < 0x4000 then
		flush_cpu_timing()
		local reg = bit32.band(addr, 7)
		
		ppu_open_bus = value
		if reg == 0 then
			local old_nmi_output = nmi_output

			ctrl_vram_increment = bit32.btest(value, 4) and 32 or 1
			ctrl_sprite_pattern_base = bit32.btest(value, 8) and 0x1000 or 0
			ctrl_bg_pattern_base = bit32.btest(value, 16) and 0x1000 or 0
			ctrl_sprite_8x16 = bit32.btest(value, 0x20)
			nmi_output = bit32.btest(value, 0x80)

			ctrl_sprite_height = ctrl_sprite_8x16 and 16 or 8

			if old_nmi_output ~= nmi_output then
				local current_line = nmi_output and bit32.btest(ppu_status, 0x80)
				if current_line then
					if not nmi_line_state then
						nmi_delay_cycles = 2
					end
				elseif nmi_delay_cycles > 0 then
					nmi_delay_cycles = 0
				end
				nmi_line_state = current_line
			end
			t = bit32.bor(bit32.band(t, 0x73FF), bit32.band(value, 3) * 1024)
		elseif reg == 1 then
			mask_show_bg = bit32.btest(value, 8)
			mask_show_sp = bit32.btest(value, 16)
			mask_bg_left = bit32.btest(value, 2)
			mask_sp_left = bit32.btest(value, 4)
			mask_grayscale = bit32.btest(value, 1)
			mask_rendering = mask_show_bg or mask_show_sp
		elseif reg == 3 then
			oam_addr = value
		elseif reg == 4 then
			buffer.writeu8(oam, oam_addr, value)
			oam_addr = oam_addr == 255 and 0 or oam_addr + 1
		elseif reg == 5 then
			if w == 0 then
				t = bit32.bor(bit32.band(t, 0x7FE0), bit32.rshift(value, 3))
				fine_x = bit32.band(value, 7)
				w = 1
			else
				t = bit32.bor(
					bit32.band(t, 0x0C1F),
					bit32.band(value, 7) * 4096,
					bit32.band(value, 0xF8) * 4
				)
				w = 0
			end
		elseif reg == 6 then
			if w == 0 then
				t = bit32.bor(bit32.band(t, 0x00FF), bit32.band(value, 0x3F) * 256)
				w = 1
			else
				t = bit32.bor(bit32.band(t, 0x7F00), value)
				v = t
				w = 0
			end
		elseif reg == 7 then
			local _addr = v
			if _addr >= 0x4000 then
				_addr = bit32.band(_addr, 0x3FFF)
			end

			-- PPUDATA writes mirror the same decode/A12 side effects as PPU reads.
			if _addr < 0x2000 then
				if mapper_is_mmc3 then
					local a12_high = _addr >= 0x1000
					if in_ppu_step then
						mmc3_a12_sampled = a12_high
					else
						if a12_high then
							if not mmc3_a12_prev and mmc3_a12_low_cycles >= 12 then
								if mmc3_irq_counter == 0 or mmc3_irq_reload then
									mmc3_irq_counter = mmc3_irq_latch
									mmc3_irq_reload = false
								else
									mmc3_irq_counter = mmc3_irq_counter == 0 and 255 or mmc3_irq_counter - 1
								end

								if mmc3_irq_counter == 0 and mmc3_irq_enabled then
									mmc3_irq_pending = true
								end
							end

							mmc3_a12_prev = true
							mmc3_a12_low_cycles = 0
						else
							mmc3_a12_prev = false
							if mmc3_a12_low_cycles < 12 then
								mmc3_a12_low_cycles += 1
							end
						end
					end
				elseif mapper_has_a12_clock then
					if in_ppu_step then
						mmc3_a12_sampled = _addr >= 0x1000
					else
						mapper_clock_a12(_addr >= 0x1000)
					end
				end

				if chr_is_ram then
					if not mapper_has_write_ppu or not mapper_write_ppu(_addr, value) then
						local mapped = mapper_map_chr_addr(_addr, 0, ctrl_sprite_8x16)

						if mapped >= 0 and mapped < chr_rom_len then
							buffer.writeu8(chr_rom, mapped, value)
						end
					end
				elseif mapper_has_write_ppu then
					mapper_write_ppu(_addr, value)
				end
			else
				if _addr < 0x3F00 then
					if not mapper_has_write_nametable or not mapper_write_nametable(_addr, value) then
						buffer.writeu8(vram, buffer.readu16(active_nametable_lut, bit32.band(_addr, 0x0FFF) * 2), value)
					end
				else
					local index = buffer.readu8(PALETTE_ADDR_LUT, bit32.band(_addr, 0x1F))

					buffer.writeu8(palette, index, value)
					-- The palette write already stored `value`, so there is no need to reread it.
					local base_color_index = bit32.band(value, 0x3F)

					buffer.writeu32(
						palette_rgba32,
						index * 4,
						buffer.readu32(nes_rgba32, base_color_index * 4)
					)

					buffer.writeu32(
						palette_rgba32,
						(index + 32) * 4,
						buffer.readu32(nes_rgba32, bit32.band(base_color_index, 0x30) * 4)
					)
				end
			end

			if mask_rendering and (scanline < 240 or scanline == 261) then
				if bit32.band(v, 0x7000) ~= 0x7000 then
					v = bit32.band(v + 0x1000, 0x7FFF)
				else
					v = bit32.band(v, bit32.bnot(0x7000))

					local coarse_y = bit32.band(bit32.rshift(v, 5), 0x1F)
					if coarse_y == 29 then
						coarse_y = 0
						v = bit32.bxor(v, 0x0800)
					elseif coarse_y == 31 then
						coarse_y = 0
					else
						coarse_y += 1
					end

					v = bit32.bor(bit32.band(v, bit32.bnot(0x03E0)), coarse_y * 32)
				end
			else
				v = bit32.band(v + ctrl_vram_increment, 0x7FFF)
			end
		end
	elseif addr >= 0x8000 then
		flush_cpu_timing()
		if mapper_write_high_cpu then
			mapper_write_high_cpu(addr, value)
		end
	elseif addr == 0x4014 then
		flush_cpu_timing()

		local base = value * 256
		local saved = oam_addr

		in_dma_transfer = true
		for i = 0, 255 do
			buffer.writeu8(oam, bit32.band(saved + i, 255), bus_read(base + i))
		end
		in_dma_transfer = false

		dma_cycles = 513 + bit32.band(cpu_total_cycles + 1, 1)
	elseif addr == 0x4016 then
		flush_cpu_timing()
		pad_strobe = bit32.band(value, 1)
		if pad_strobe == 1 then
			pad1_index = 0
			pad2_index = 0
		end
	elseif addr == 0x4017 then
		flush_cpu_timing_apuflush()
		apu_write(addr, value)
		local stalls = apu_consume_dma_stall_cycles()
		while stalls > 0 do
			cpu_total_cycles += stalls
			run_ppu_cycles(stalls * 3)
			clock_mapper_cpu_cycles(stalls)
			apu_step(stalls)
			stalls = apu_consume_dma_stall_cycles()
		end
	elseif addr >= 0x4000 and addr <= 0x4015 then
		flush_cpu_timing_apuflush()
		apu_write(addr, value)
		local stalls = apu_consume_dma_stall_cycles()
		while stalls > 0 do
			cpu_total_cycles += stalls
			run_ppu_cycles(stalls * 3)
			clock_mapper_cpu_cycles(stalls)
			apu_step(stalls)
			stalls = apu_consume_dma_stall_cycles()
		end
	elseif addr < 0x4020 then
		-- do nothing
	elseif addr < 0x6000 then
		if mapper_is_mmc5 and addr >= 0x5000 and addr <= 0x5015 then
			flush_cpu_timing_apuflush()
			apu_write_mmc5(addr, value)
		else
			flush_cpu_timing()
			if mapper_has_write_cpu then
				mapper_write_cpu(addr, value)
				sync_mapper_dynamic_state()
				if mapper_has_cpu_clock and mapper_has_irq_pending then
					mapper_cpu_irq_current = mapper_irq_pending_fast()
				end
			end
		end
	else
		if mapper_has_map_prg_ram_addr then
			local ram_addr = mapper_map_prg_ram_addr(addr)
			if ram_addr then
				if ram_addr >= 0 and ram_addr < prg_ram_len and mapper_prg_ram_writable_state then
					buffer.writeu8(prg_ram, ram_addr, value)
				end
			end
		end

		if mapper_has_write_cpu then
			mapper_write_cpu(addr, value)
			sync_mapper_dynamic_state()
			if mapper_has_cpu_clock and mapper_has_irq_pending then
				mapper_cpu_irq_current = mapper_irq_pending_fast()
			end
		end
	end
end

function opcodes_init()
	local indexed_dummy_always = buffer.create(256)
	local page_cross_penalty = buffer.create(256)
	local zn_flag_lut = buffer.create(256)

	for i = 0, 255 do
		local zn = bit32.band(i, 0x80)
		if i == 0 then
			zn = bit32.bor(zn, 2)
		end
		buffer.writeu8(zn_flag_lut, i, zn)
	end

	local function imm()
		addr_value = pc
		pc += 1
		if pc == 0x10000 then
			pc = 0
		end
	end

	local function zp()
		addr_value = bus_read(pc)
		pc += 1
		if pc == 0x10000 then
			pc = 0
		end
	end

	local function zpx()
		addr_value = bit32.band(bus_read(pc) + x, 255)
		pc += 1
		if pc == 0x10000 then
			pc = 0
		end
	end

	local function zpy()
		addr_value = bit32.band(bus_read(pc) + y, 255)
		pc += 1
		if pc == 0x10000 then
			pc = 0
		end
	end

	local function abs()
		addr_value = bus_read(pc) + bus_read(pc + 1) * 256
		pc += 2
		if pc >= 0x10000 then
			pc -= 0x10000
		end
	end

	local function jsr_abs()
		jsr_target_low = bus_read(pc)
		pc += 1
		if pc == 0x10000 then
			pc = 0
		end
	end

	local function abx()
		local base = bus_read(pc) + bus_read(pc + 1) * 256
		local low_sum = bit32.band(base, 255) + x
		addr_value = bit32.band(base + x, 0xFFFF)
		page_crossed = low_sum > 255
		indexed_high_plus_one = bit32.band(bit32.rshift(base, 8) + 1, 255)
		indexed_dummy_addr = bit32.bor(bit32.band(base, 0xFF00), bit32.band(low_sum, 0x00FF))
		pc += 2
		if pc >= 0x10000 then
			pc -= 0x10000
		end
	end

	local function aby()
		local base = bus_read(pc) + bus_read(pc + 1) * 256
		local low_sum = bit32.band(base, 255) + y
		addr_value = bit32.band(base + y, 0xFFFF)
		page_crossed = low_sum > 255
		indexed_high_plus_one = bit32.band(bit32.rshift(base, 8) + 1, 255)
		indexed_dummy_addr = bit32.bor(bit32.band(base, 0xFF00), bit32.band(low_sum, 0x00FF))
		pc += 2
		if pc >= 0x10000 then
			pc -= 0x10000
		end
	end

	local function ind()
		local ptr = bus_read(pc) + bus_read(pc + 1) * 256
		addr_value = bus_read(ptr) + bus_read(bit32.bor(bit32.band(ptr, 0xFF00), bit32.band(ptr + 1, 0x00FF))) * 256

		pc += 2
		if pc >= 0x10000 then
			pc -= 0x10000
		end
	end

	local function izx()
		local base = bit32.band(bus_read(pc) + x, 255)
		addr_value = bus_read(base) + bus_read(bit32.band(base + 1, 255)) * 256
		pc += 1
		if pc == 0x10000 then
			pc = 0
		end
	end

	local function izy()
		local base = bus_read(pc)
		local addr = bus_read(base) + bus_read(bit32.band(base + 1, 255)) * 256
		local low_sum = bit32.band(addr, 255) + y
		addr_value = bit32.band(addr + y, 0xFFFF)
		page_crossed = low_sum > 255
		indexed_high_plus_one = bit32.band(bit32.rshift(addr, 8) + 1, 255)
		indexed_dummy_addr = bit32.bor(bit32.band(addr, 0xFF00), bit32.band(low_sum, 0x00FF))
		pc += 1
		if pc == 0x10000 then
			pc = 0
		end
	end

	local function rel()
		local offset = bus_read(pc)
		pc += 1
		if pc == 0x10000 then
			pc = 0
		end
		addr_value = bit32.band(offset >= 128 and pc + offset - 256 or pc + offset, 0xFFFF)
	end

	local function adc()
		local m = bus_read(addr_value)
		local sum = a + m + bit32.band(status, 1)
		local cv = if sum > 255 then 1 else 0
		if bit32.btest(bit32.band(bit32.bxor(a, sum), bit32.bxor(m, sum), 0x80), 0x80) then
			cv = bit32.bor(cv, 0x40)
		end
		a = bit32.band(sum, 255)
		status = bit32.bor(bit32.band(status, 0x3C), cv, buffer.readu8(zn_flag_lut, a))
	end

	local function op_and()
		a = bit32.band(a, bus_read(addr_value))
		status = bit32.bor(bit32.band(status, 0x7D), buffer.readu8(zn_flag_lut, a))
	end

	local function asl_a()
		local result = bit32.band(a * 2, 255)
		status = bit32.bor(bit32.band(status, 0x7C), bit32.rshift(a, 7), buffer.readu8(zn_flag_lut, result))
		a = result
	end

	local function asl()
		local m = bus_read(addr_value)
		local result = bit32.band(m * 2, 255)
		status = bit32.bor(bit32.band(status, 0x7C), bit32.rshift(m, 7), buffer.readu8(zn_flag_lut, result))

		bus_write(addr_value, m)
		bus_write(addr_value, result)
	end

	local function op_bit()
		local m = bus_read(addr_value)
		local znv = bit32.band(m, 0xC0)
		if bit32.band(a, m) == 0 then
			znv = bit32.bor(znv, 2)
		end
		status = bit32.bor(bit32.band(status, 0x3D), znv)
	end

	local function brk()
		pc = pc == 65535 and 0 or pc + 1

		bus_write(0x0100 + sp, bit32.rshift(pc, 8))
		sp = bit32.band(sp - 1, 255)

		bus_write(0x0100 + sp, bit32.band(pc, 255))
		sp = bit32.band(sp - 1, 255)

		bus_write(0x0100 + sp, bit32.bor(status, 16, 32))
		sp = bit32.band(sp - 1, 255)

		status = bit32.bor(status, 4)
		irq_poll_delay = 0
		if nmi_pending_flag or (nmi_delay_cycles > 0 and nmi_delay_cycles <= 4) then
			nmi_pending_flag = false
			nmi_delay_cycles = 0
			pc = bus_read(0xFFFA) + bus_read(0xFFFB) * 256
		else
			pc = bus_read(0xFFFE) + bus_read(0xFFFF) * 256
		end
	end

	local function cmp()
		local m = bus_read(addr_value)
		local diff = a - m
		status = bit32.bor(bit32.band(status, 0x7C), if diff >= 0 then 1 else 0, buffer.readu8(zn_flag_lut, bit32.band(diff, 255)))
	end

	local function cpx()
		local m = bus_read(addr_value)
		local diff = x - m
		status = bit32.bor(bit32.band(status, 0x7C), if diff >= 0 then 1 else 0, buffer.readu8(zn_flag_lut, bit32.band(diff, 255)))
	end

	local function cpy()
		local m = bus_read(addr_value)
		local diff = y - m
		status = bit32.bor(bit32.band(status, 0x7C), if diff >= 0 then 1 else 0, buffer.readu8(zn_flag_lut, bit32.band(diff, 255)))
	end

	local function dec()
		local m = bus_read(addr_value)
		local result = bit32.band(m - 1, 255)
		status = bit32.bor(bit32.band(status, 0x7D), buffer.readu8(zn_flag_lut, result))

		bus_write(addr_value, m)
		bus_write(addr_value, result)
	end

	local function dex()
		x = bit32.band(x - 1, 255)
		status = bit32.bor(bit32.band(status, 0x7D), buffer.readu8(zn_flag_lut, x))
	end

	local function dey()
		y = bit32.band(y - 1, 255)
		status = bit32.bor(bit32.band(status, 0x7D), buffer.readu8(zn_flag_lut, y))
	end

	local function eor()
		a = bit32.bxor(a, bus_read(addr_value))
		status = bit32.bor(bit32.band(status, 0x7D), buffer.readu8(zn_flag_lut, a))
	end

	local function inc()
		local m = bus_read(addr_value)
		local result = m == 255 and 0 or m + 1
		status = bit32.bor(bit32.band(status, 0x7D), buffer.readu8(zn_flag_lut, result))

		bus_write(addr_value, m)
		bus_write(addr_value, result)
	end

	local function inx()
		x = x == 255 and 0 or x + 1
		status = bit32.bor(bit32.band(status, 0x7D), buffer.readu8(zn_flag_lut, x))
	end

	local function iny()
		y = y == 255 and 0 or y + 1
		status = bit32.bor(bit32.band(status, 0x7D), buffer.readu8(zn_flag_lut, y))
	end

	local function jmp()
		pc = addr_value
	end

	local function jsr()
		local value = pc

		bus_write(0x0100 + sp, bit32.rshift(value, 8))
		sp = bit32.band(sp - 1, 255)

		bus_write(0x0100 + sp, bit32.band(value, 255))
		sp = bit32.band(sp - 1, 255)

		pc = jsr_target_low + bus_read(pc) * 256
	end

	local function lda()
		a = bus_read(addr_value)
		status = bit32.bor(bit32.band(status, 0x7D), buffer.readu8(zn_flag_lut, a))
	end

	local function ldx()
		x = bus_read(addr_value)
		status = bit32.bor(bit32.band(status, 0x7D), buffer.readu8(zn_flag_lut, x))
	end

	local function ldy()
		y = bus_read(addr_value)
		status = bit32.bor(bit32.band(status, 0x7D), buffer.readu8(zn_flag_lut, y))
	end

	local function lsr_a()
		local carry = bit32.band(a, 1)
		a = bit32.rshift(a, 1)
		status = bit32.bor(bit32.band(status, 0x7C), carry, buffer.readu8(zn_flag_lut, a))
	end

	local function lsr()
		local m = bus_read(addr_value)
		local result = bit32.rshift(m, 1)
		status = bit32.bor(bit32.band(status, 0x7C), bit32.band(m, 1), buffer.readu8(zn_flag_lut, result))

		bus_write(addr_value, m)
		bus_write(addr_value, result)
	end

	local function ora()
		a = bit32.bor(a, bus_read(addr_value))
		status = bit32.bor(bit32.band(status, 0x7D), buffer.readu8(zn_flag_lut, a))
	end

	local function pha()
		bus_write(0x0100 + sp, a)
		sp = bit32.band(sp - 1, 255)
	end

	local function php()
		bus_write(0x0100 + sp, bit32.bor(status, 16, 32))
		sp = bit32.band(sp - 1, 255)
	end

	local function pla()
		sp = bit32.band(sp + 1, 255)
		a = bus_read(0x0100 + sp)
		status = bit32.bor(bit32.band(status, 0x7D), buffer.readu8(zn_flag_lut, a))
	end

	local function plp()
		sp = bit32.band(sp + 1, 255)
		local old_i = bit32.btest(status, 4)
		status = bit32.bor(bit32.band(bus_read(0x0100 + sp), 0xEF), 32)
		if old_i and not bit32.btest(status, 4) then
			irq_poll_delay = 2
		elseif bit32.btest(status, 4) then
			irq_poll_delay = 0
		end
	end

	local function rol_a()
		local carry = bit32.rshift(a, 7)
		a = bit32.band(bit32.bor(a * 2, bit32.band(status, 1)), 255)
		status = bit32.bor(bit32.band(status, 0x7C), carry, buffer.readu8(zn_flag_lut, a))
	end

	local function rol()
		local m = bus_read(addr_value)
		local result = bit32.band(bit32.bor(m * 2, bit32.band(status, 1)), 255)
		status = bit32.bor(bit32.band(status, 0x7C), bit32.rshift(m, 7), buffer.readu8(zn_flag_lut, result))

		bus_write(addr_value, m)
		bus_write(addr_value, result)
	end

	local function ror_a()
		local carry = bit32.band(a, 1)
		a = bit32.rshift(a, 1) + bit32.band(status, 1) * 128
		status = bit32.bor(bit32.band(status, 0x7C), carry, buffer.readu8(zn_flag_lut, a))
	end

	local function ror()
		local m = bus_read(addr_value)
		local result = bit32.rshift(m, 1) + bit32.band(status, 1) * 128
		status = bit32.bor(bit32.band(status, 0x7C), bit32.band(m, 1), buffer.readu8(zn_flag_lut, result))

		bus_write(addr_value, m)
		bus_write(addr_value, result)
	end

	local function rti()
		sp = bit32.band(sp + 1, 255)
		local old_i = bit32.btest(status, 4)
		status = bit32.bor(bit32.band(bus_read(0x0100 + sp), 0xEF), 32)
		if old_i and not bit32.btest(status, 4) then
			irq_poll_delay = 2
		elseif bit32.btest(status, 4) then
			irq_poll_delay = 0
		end
		sp = bit32.band(sp + 1, 255)
		local pulled = bus_read(0x0100 + sp)
		sp = bit32.band(sp + 1, 255)
		pc = pulled + bus_read(0x0100 + sp) * 256
	end

	local function rts()
		sp = bit32.band(sp + 1, 255)
		local pulled = bus_read(0x0100 + sp)
		sp = bit32.band(sp + 1, 255)
		pc = bit32.band(pulled + bus_read(0x0100 + sp) * 256 + 1, 0xFFFF)
	end

	local function sbc()
		local m = bus_read(addr_value)
		local diff = a - m - 1 + bit32.band(status, 1)
		local cv = if diff >= 0 then 1 else 0
		if bit32.btest(bit32.band(bit32.bxor(a, diff), bit32.bxor(a, m), 0x80), 0x80) then
			cv = bit32.bor(cv, 0x40)
		end
		a = bit32.band(diff, 255)
		status = bit32.bor(bit32.band(status, 0x3C), cv, buffer.readu8(zn_flag_lut, a))
	end

	local function sta()
		bus_write(addr_value, a)
	end

	local function stx()
		bus_write(addr_value, x)
	end

	local function sty()
		bus_write(addr_value, y)
	end

	local function tax()
		x = a
		status = bit32.bor(bit32.band(status, 0x7D), buffer.readu8(zn_flag_lut, x))
	end

	local function tay()
		y = a
		status = bit32.bor(bit32.band(status, 0x7D), buffer.readu8(zn_flag_lut, y))
	end

	local function tsx()
		x = sp
		status = bit32.bor(bit32.band(status, 0x7D), buffer.readu8(zn_flag_lut, x))
	end

	local function txa()
		a = x
		status = bit32.bor(bit32.band(status, 0x7D), buffer.readu8(zn_flag_lut, a))
	end

	local function txs()
		sp = x
	end

	local function tya()
		a = y
		status = bit32.bor(bit32.band(status, 0x7D), buffer.readu8(zn_flag_lut, a))
	end

	local function op_lax()
		a = bus_read(addr_value)
		x = a
		status = bit32.bor(bit32.band(status, 0x7D), buffer.readu8(zn_flag_lut, a))
	end

	local function op_sax()
		bus_write(addr_value, bit32.band(a, x))
	end

	local function op_dcp()
		local old_m = bus_read(addr_value)
		local m = bit32.band(old_m - 1, 255)

		bus_write(addr_value, old_m)
		bus_write(addr_value, m)

		local diff = a - m
		status = bit32.bor(bit32.band(status, 0x7C), if diff >= 0 then 1 else 0, buffer.readu8(zn_flag_lut, bit32.band(diff, 255)))
	end

	local function op_isc()
		local old_m = bus_read(addr_value)
		local m = old_m == 255 and 0 or old_m + 1

		bus_write(addr_value, old_m)
		bus_write(addr_value, m)

		local diff = a - m - 1 + bit32.band(status, 1)
		local cv = if diff >= 0 then 1 else 0
		if bit32.btest(bit32.band(bit32.bxor(a, diff), bit32.bxor(a, m), 0x80), 0x80) then
			cv = bit32.bor(cv, 0x40)
		end
		a = bit32.band(diff, 255)
		status = bit32.bor(bit32.band(status, 0x3C), cv, buffer.readu8(zn_flag_lut, a))
	end

	local function op_rla()
		local old_m = bus_read(addr_value)
		local m = bit32.band(bit32.bor(old_m * 2, bit32.band(status, 1)), 255)

		bus_write(addr_value, old_m)
		bus_write(addr_value, m)

		a = bit32.band(a, m)
		status = bit32.bor(bit32.band(status, 0x7C), bit32.rshift(old_m, 7), buffer.readu8(zn_flag_lut, a))
	end

	local function op_rra()
		local old_m = bus_read(addr_value)
		local m = bit32.rshift(old_m, 1) + bit32.band(status, 1) * 128

		bus_write(addr_value, old_m)
		bus_write(addr_value, m)

		local sum = a + m + bit32.band(old_m, 1)
		local cv = if sum > 255 then 1 else 0
		if bit32.btest(bit32.band(bit32.bxor(a, sum), bit32.bxor(m, sum), 0x80), 0x80) then
			cv = bit32.bor(cv, 0x40)
		end
		a = bit32.band(sum, 255)
		status = bit32.bor(bit32.band(status, 0x3C), cv, buffer.readu8(zn_flag_lut, a))
	end

	local function op_slo()
		local old_m = bus_read(addr_value)
		local m = bit32.band(old_m * 2, 255)

		bus_write(addr_value, old_m)
		bus_write(addr_value, m)

		a = bit32.bor(a, m)
		status = bit32.bor(bit32.band(status, 0x7C), bit32.rshift(old_m, 7), buffer.readu8(zn_flag_lut, a))
	end

	local function op_sre()
		local old_m = bus_read(addr_value)
		local m = bit32.rshift(old_m, 1)

		bus_write(addr_value, old_m)
		bus_write(addr_value, m)

		a = bit32.bxor(a, m)
		status = bit32.bor(bit32.band(status, 0x7C), bit32.band(old_m, 1), buffer.readu8(zn_flag_lut, a))
	end

	local function op_anc()
		a = bit32.band(a, bus_read(addr_value))
		status = bit32.bor(bit32.band(status, 0x7C), bit32.rshift(a, 7), buffer.readu8(zn_flag_lut, a))
	end

	local function op_alr()
		a = bit32.band(a, bus_read(addr_value))
		local carry = bit32.band(a, 1)
		a = bit32.rshift(a, 1)
		status = bit32.bor(bit32.band(status, 0x7C), carry, buffer.readu8(zn_flag_lut, a))
	end

	local function op_arr()
		a = bit32.band(a, bus_read(addr_value))
		a = bit32.rshift(a, 1) + bit32.band(status, 1) * 128
		local cv = bit32.band(bit32.rshift(a, 6), 1)
		if bit32.band(bit32.rshift(a, 5), 1) ~= cv then
			cv = bit32.bor(cv, 0x40)
		end
		status = bit32.bor(bit32.band(status, 0x3C), cv, buffer.readu8(zn_flag_lut, a))
	end

	local function op_sbx()
		local t = bit32.band(a, x) - bus_read(addr_value)
		x = bit32.band(t, 255)
		status = bit32.bor(bit32.band(status, 0x7C), if t >= 0 then 1 else 0, buffer.readu8(zn_flag_lut, x))
	end

	local opcodes = {
		[0x00] = {brk, nil, 7}, [1] = {ora, izx, 6}, [5] = {ora, zp, 3},
		[6] = {asl, zp, 5}, [8] = {php, nil, 3}, [9] = {ora, imm, 2},
		[0x0A] = {asl_a, nil, 2}, [0x0D] = {ora, abs, 4}, [0x0E] = {asl, abs, 6},
		[0x11] = {ora, izy, 5}, [0x15] = {ora, zpx, 4},
		[0x16] = {asl, zpx, 6}, [0x19] = {ora, aby, 4},
		[0x1D] = {ora, abx, 4}, [0x1E] = {asl, abx, 7},
		[0x20] = {jsr, jsr_abs, 6}, [0x21] = {op_and, izx, 6}, [0x24] = {op_bit, zp, 3},
		[0x25] = {op_and, zp, 3}, [0x26] = {rol, zp, 5}, [0x28] = {plp, nil, 4},
		[0x29] = {op_and, imm, 2}, [0x2A] = {rol_a, nil, 2}, [0x2C] = {op_bit, abs, 4},
		[0x2D] = {op_and, abs, 4}, [0x2E] = {rol, abs, 6},
		[0x31] = {op_and, izy, 5}, [0x35] = {op_and, zpx, 4},
		[0x36] = {rol, zpx, 6}, [0x39] = {op_and, aby, 4},
		[0x3D] = {op_and, abx, 4}, [0x3E] = {rol, abx, 7},
		[0x40] = {rti, nil, 6}, [0x41] = {eor, izx, 6}, [0x45] = {eor, zp, 3},
		[0x46] = {lsr, zp, 5}, [0x48] = {pha, nil, 3}, [0x49] = {eor, imm, 2},
		[0x4A] = {lsr_a, nil, 2}, [0x4C] = {jmp, abs, 3}, [0x4D] = {eor, abs, 4},
		[0x4E] = {lsr, abs, 6},
		[0x51] = {eor, izy, 5}, [0x55] = {eor, zpx, 4},
		[0x56] = {lsr, zpx, 6}, [0x59] = {eor, aby, 4},
		[0x5D] = {eor, abx, 4}, [0x5E] = {lsr, abx, 7},
		[0x60] = {rts, nil, 6}, [0x61] = {adc, izx, 6}, [0x65] = {adc, zp, 3},
		[0x66] = {ror, zp, 5}, [0x68] = {pla, nil, 4}, [0x69] = {adc, imm, 2},
		[0x6A] = {ror_a, nil, 2}, [0x6C] = {jmp, ind, 5}, [0x6D] = {adc, abs, 4},
		[0x6E] = {ror, abs, 6},
		[0x71] = {adc, izy, 5}, [0x75] = {adc, zpx, 4},
		[0x76] = {ror, zpx, 6}, [0x79] = {adc, aby, 4},
		[0x7D] = {adc, abx, 4}, [0x7E] = {ror, abx, 7},
		[0x81] = {sta, izx, 6}, [0x84] = {sty, zp, 3}, [0x85] = {sta, zp, 3},
		[0x86] = {stx, zp, 3}, [0x88] = {dey, nil, 2}, [0x8A] = {txa, nil, 2},
		[0x8C] = {sty, abs, 4}, [0x8D] = {sta, abs, 4}, [0x8E] = {stx, abs, 4},
		[0x91] = {sta, izy, 6}, [0x94] = {sty, zpx, 4},
		[0x95] = {sta, zpx, 4}, [0x96] = {stx, zpy, 4}, [0x98] = {tya, nil, 2},
		[0x99] = {sta, aby, 5}, [0x9A] = {txs, nil, 2}, [0x9D] = {sta, abx, 5},
		[0xA0] = {ldy, imm, 2}, [0xA1] = {lda, izx, 6}, [0xA2] = {ldx, imm, 2},
		[0xA4] = {ldy, zp, 3}, [0xA5] = {lda, zp, 3}, [0xA6] = {ldx, zp, 3},
		[0xA8] = {tay, nil, 2}, [0xA9] = {lda, imm, 2}, [0xAA] = {tax, nil, 2},
		[0xAC] = {ldy, abs, 4}, [0xAD] = {lda, abs, 4}, [0xAE] = {ldx, abs, 4},
		[0xB1] = {lda, izy, 5}, [0xB4] = {ldy, zpx, 4},
		[0xB5] = {lda, zpx, 4}, [0xB6] = {ldx, zpy, 4},
		[0xB9] = {lda, aby, 4}, [0xBA] = {tsx, nil, 2}, [0xBC] = {ldy, abx, 4},
		[0xBD] = {lda, abx, 4}, [0xBE] = {ldx, aby, 4},
		[0xC0] = {cpy, imm, 2}, [0xC1] = {cmp, izx, 6}, [0xC4] = {cpy, zp, 3},
		[0xC5] = {cmp, zp, 3}, [0xC6] = {dec, zp, 5}, [0xC8] = {iny, nil, 2},
		[0xC9] = {cmp, imm, 2}, [0xCA] = {dex, nil, 2}, [0xCC] = {cpy, abs, 4},
		[0xCD] = {cmp, abs, 4}, [0xCE] = {dec, abs, 6},
		[0xD1] = {cmp, izy, 5}, [0xD5] = {cmp, zpx, 4},
		[0xD6] = {dec, zpx, 6}, [0xD9] = {cmp, aby, 4},
		[0xDD] = {cmp, abx, 4}, [0xDE] = {dec, abx, 7},
		[0xE0] = {cpx, imm, 2}, [0xE1] = {sbc, izx, 6}, [0xE4] = {cpx, zp, 3},
		[0xE5] = {sbc, zp, 3}, [0xE6] = {inc, zp, 5}, [0xE8] = {inx, nil, 2},
		[0xE9] = {sbc, imm, 2}, [0xEA] = {nil, nil, 2}, [0xEC] = {cpx, abs, 4},
		[0xED] = {sbc, abs, 4}, [0xEE] = {inc, abs, 6},
		[0xF1] = {sbc, izy, 5}, [0xF5] = {sbc, zpx, 4},
		[0xF6] = {inc, zpx, 6}, [0xF9] = {sbc, aby, 4},
		[0xFD] = {sbc, abx, 4}, [0xFE] = {inc, abx, 7}
	}

	local function clc()
			status = bit32.band(status, 0xFE)
		end

		local function sec()
			status = bit32.bor(status, 1)
		end

		local function cli()
			local old_i = bit32.btest(status, 4)
			status = bit32.band(status, 0xFB)
			if old_i then
				irq_poll_delay = 2
			end
		end

		local function sei()
			status = bit32.bor(status, 4)
			irq_poll_delay = 0
		end

		local function clv()
			status = bit32.band(status, 0xBF)
		end

		local function cld()
			status = bit32.band(status, 0xF7)
		end

		local function sed()
			status = bit32.bor(status, 8)
		end

		opcodes[0x18] = {clc, nil, 2}
		opcodes[0x38] = {sec, nil, 2}
		opcodes[0x58] = {cli, nil, 2}
		opcodes[0x78] = {sei, nil, 2}
		opcodes[0xB8] = {clv, nil, 2}
		opcodes[0xD8] = {cld, nil, 2}
		opcodes[0xF8] = {sed, nil, 2}

	local function prepare_taken_branch_mapper_irq_delay(page_crossed: boolean)
			if page_crossed or not mapper_has_cpu_clock or not mapper_has_irq_pending then
				return
			end

			-- Taken non-page-crossing branches delay a newly-raised IRQ by one instruction.
			flush_cpu_timing()
			if mapper_cpu_irq_current and not mapper_cpu_irq_prev then
				mapper_branch_irq_delay = true
			end
		end

		local function branch_if(cond: boolean)
			if cond then
				local pc_page = bit32.band(pc, 0xFF00)
				local page_crossed = pc_page ~= bit32.band(addr_value, 0xFF00)
				prepare_taken_branch_mapper_irq_delay(page_crossed)
				bus_read(pc)
				cycles += 1
				if page_crossed then
					bus_read(bit32.bor(pc_page, bit32.band(addr_value, 0x00FF)))
					cycles += 1
				end
				pc = addr_value
			end
		end

		local function bpl()
			branch_if(not bit32.btest(status, 0x80))
		end

		local function bmi()
			branch_if(bit32.btest(status, 0x80))
		end

		local function bvc()
			branch_if(not bit32.btest(status, 0x40))
		end

		local function bvs()
			branch_if(bit32.btest(status, 0x40))
		end

		local function bcc()
			branch_if(not bit32.btest(status, 1))
		end

		local function bcs()
			branch_if(bit32.btest(status, 1))
		end

		local function bne()
			branch_if(not bit32.btest(status, 2))
		end

		local function beq()
			branch_if(bit32.btest(status, 2))
		end

		opcodes[0x10] = {bpl, rel, 2}
		opcodes[0x30] = {bmi, rel, 2}
		opcodes[0x50] = {bvc, rel, 2}
		opcodes[0x70] = {bvs, rel, 2}
		opcodes[0x90] = {bcc, rel, 2}
		opcodes[0xB0] = {bcs, rel, 2}
		opcodes[0xD0] = {bne, rel, 2}
		opcodes[0xF0] = {beq, rel, 2}

	-- Unofficial opcodes commonly used by test ROMs and some games.
	opcodes[3] = {op_slo, izx, 8}
	opcodes[7] = {op_slo, zp, 5}
	opcodes[0x0F] = {op_slo, abs, 6}
	opcodes[0x13] = {op_slo, izy, 8}
	opcodes[0x17] = {op_slo, zpx, 6}
	opcodes[0x1B] = {op_slo, aby, 7}
	opcodes[0x1F] = {op_slo, abx, 7}

	opcodes[0x23] = {op_rla, izx, 8}
	opcodes[0x27] = {op_rla, zp, 5}
	opcodes[0x2F] = {op_rla, abs, 6}
	opcodes[0x33] = {op_rla, izy, 8}
	opcodes[0x37] = {op_rla, zpx, 6}
	opcodes[0x3B] = {op_rla, aby, 7}
	opcodes[0x3F] = {op_rla, abx, 7}

	opcodes[0x43] = {op_sre, izx, 8}
	opcodes[0x47] = {op_sre, zp, 5}
	opcodes[0x4F] = {op_sre, abs, 6}
	opcodes[0x53] = {op_sre, izy, 8}
	opcodes[0x57] = {op_sre, zpx, 6}
	opcodes[0x5B] = {op_sre, aby, 7}
	opcodes[0x5F] = {op_sre, abx, 7}

	opcodes[0x63] = {op_rra, izx, 8}
	opcodes[0x67] = {op_rra, zp, 5}
	opcodes[0x6F] = {op_rra, abs, 6}
	opcodes[0x73] = {op_rra, izy, 8}
	opcodes[0x77] = {op_rra, zpx, 6}
	opcodes[0x7B] = {op_rra, aby, 7}
	opcodes[0x7F] = {op_rra, abx, 7}

	opcodes[0x83] = {op_sax, izx, 6}
	opcodes[0x87] = {op_sax, zp, 3}
	opcodes[0x8F] = {op_sax, abs, 4}
	opcodes[0x97] = {op_sax, zpy, 4}

	opcodes[0xA3] = {op_lax, izx, 6}
	opcodes[0xA7] = {op_lax, zp, 3}
	opcodes[0xAF] = {op_lax, abs, 4}
	opcodes[0xB3] = {op_lax, izy, 5}
	opcodes[0xB7] = {op_lax, zpy, 4}
	opcodes[0xBF] = {op_lax, aby, 4}

	opcodes[0xC3] = {op_dcp, izx, 8}
	opcodes[0xC7] = {op_dcp, zp, 5}
	opcodes[0xCF] = {op_dcp, abs, 6}
	opcodes[0xD3] = {op_dcp, izy, 8}
	opcodes[0xD7] = {op_dcp, zpx, 6}
	opcodes[0xDB] = {op_dcp, aby, 7}
	opcodes[0xDF] = {op_dcp, abx, 7}

	opcodes[0xE3] = {op_isc, izx, 8}
	opcodes[0xE7] = {op_isc, zp, 5}
	opcodes[0xEB] = {sbc, imm, 2}
	opcodes[0xEF] = {op_isc, abs, 6}
	opcodes[0xF3] = {op_isc, izy, 8}
	opcodes[0xF7] = {op_isc, zpx, 6}
	opcodes[0xFB] = {op_isc, aby, 7}
	opcodes[255] = {op_isc, abx, 7}

	opcodes[0x0B] = {op_anc, imm, 2}
	opcodes[0x2B] = {op_anc, imm, 2}
	opcodes[0x4B] = {op_alr, imm, 2}
	opcodes[0x6B] = {op_arr, imm, 2}
	opcodes[0xCB] = {op_sbx, imm, 2}

	do
		local function op_las()
			local val = bit32.band(bus_read(addr_value), sp)
			sp = val
			a = val
			x = val
			status = bit32.bor(bit32.band(status, 0x7D), buffer.readu8(zn_flag_lut, val))
		end

		local function op_xaa()
			a = bit32.band(bit32.bor(a, 0xEE), x, bus_read(addr_value))
			status = bit32.bor(bit32.band(status, 0x7D), buffer.readu8(zn_flag_lut, a))
		end

		local function op_lxa()
			a = bus_read(addr_value)
			status = bit32.bor(bit32.band(status, 0x7D), buffer.readu8(zn_flag_lut, a))
			x = a
		end

		local function op_ahx()
			bus_write(addr_value, bit32.band(a, x, indexed_high_plus_one))
		end

		local function op_tas()
			sp = bit32.band(a, x)
			bus_write(addr_value, bit32.band(sp, indexed_high_plus_one))
		end

		local function op_shy()
			local value = bit32.band(y, indexed_high_plus_one)
			addr_value = value * 256 + bit32.band(addr_value, 255)
			bus_write(addr_value, value)
		end

		local function op_shx()
			local value = bit32.band(x, indexed_high_plus_one)
			addr_value = value * 256 + bit32.band(addr_value, 255)
			bus_write(addr_value, value)
		end

		local function op_jam()
			pc = bit32.band(pc - 1, 0xFFFF)
			cpu_jammed = true
		end

		local function op_nop_read()
			bus_read(addr_value)
		end

		opcodes[0x8B] = {op_xaa, imm, 2}
		opcodes[0xAB] = {op_lxa, imm, 2}
		opcodes[0xBB] = {op_las, aby, 4}
		opcodes[0x93] = {op_ahx, izy, 6}
		opcodes[0x9B] = {op_tas, aby, 5}
		opcodes[0x9C] = {op_shy, abx, 5}
		opcodes[0x9E] = {op_shx, aby, 5}
		opcodes[0x9F] = {op_ahx, aby, 5}

		for _, jam_opcode in {2, 0x12, 0x22, 0x32, 0x42, 0x52, 0x62, 0x72, 0x92, 0xB2, 0xD2, 0xF2} do
			opcodes[jam_opcode] = {op_jam, nil, 2}
		end

		opcodes[0x1A] = {nil, nil, 2}
		opcodes[0x3A] = {nil, nil, 2}
		opcodes[0x5A] = {nil, nil, 2}
		opcodes[0x7A] = {nil, nil, 2}
		opcodes[0xDA] = {nil, nil, 2}
		opcodes[0xFA] = {nil, nil, 2}

		opcodes[0x80] = {op_nop_read, imm, 2}
		opcodes[0x82] = {op_nop_read, imm, 2}
		opcodes[0x89] = {op_nop_read, imm, 2}
		opcodes[0xC2] = {op_nop_read, imm, 2}
		opcodes[0xE2] = {op_nop_read, imm, 2}
		opcodes[4] = {op_nop_read, zp, 3}
		opcodes[0x44] = {op_nop_read, zp, 3}
		opcodes[0x64] = {op_nop_read, zp, 3}
		opcodes[0x14] = {op_nop_read, zpx, 4}
		opcodes[0x34] = {op_nop_read, zpx, 4}
		opcodes[0x54] = {op_nop_read, zpx, 4}
		opcodes[0x74] = {op_nop_read, zpx, 4}
		opcodes[0xD4] = {op_nop_read, zpx, 4}
		opcodes[0xF4] = {op_nop_read, zpx, 4}
		opcodes[0x0C] = {op_nop_read, abs, 4}
		opcodes[0x1C] = {op_nop_read, abx, 4}
		opcodes[0x3C] = {op_nop_read, abx, 4}
		opcodes[0x5C] = {op_nop_read, abx, 4}
		opcodes[0x7C] = {op_nop_read, abx, 4}
		opcodes[0xDC] = {op_nop_read, abx, 4}
		opcodes[0xFC] = {op_nop_read, abx, 4}
	end

	for i = 0, 255 do
		if not opcodes[i] then
			opcodes[i] = {nil, nil, 2}
		end
	end

	local indexed_dummy_always_list = {
		0x91, 0x99, 0x9D,
		0x93, 0x9B, 0x9C,
		0x9E, 0x9F,
		0x1E, 0x3E, 0x5E,
		0x7E, 0xDE, 0xFE,
		0x13, 0x1B, 0x1F,
		0x33, 0x3B, 0x3F,
		0x53, 0x5B, 0x5F,
		0x73, 0x7B, 0x7F,
		0xD3, 0xDB, 0xDF,
		0xF3, 0xFB, 255
	}

	for _, opcode in indexed_dummy_always_list do
		buffer.writeu8(indexed_dummy_always, opcode, 1)
	end

	local page_cross_penalty_list = {
		0x11, 0x19, 0x1D,
		0x31, 0x39, 0x3D,
		0x51, 0x59, 0x5D,
		0x71, 0x79, 0x7D,
		0xB1, 0xB9, 0xBD,
		0xB3, 0xBF, 0xBB,
		0xBE, 0xBC,
		0x1C, 0x3C, 0x5C,
		0x7C, 0xDC, 0xFC,
		0xD1, 0xD9, 0xDD,
		0xF1, 0xF9, 0xFD
	}

	for _, opcode in page_cross_penalty_list do
		buffer.writeu8(page_cross_penalty, opcode, 1)
	end

	for opcode = 0, 255 do
		local op = opcodes[opcode]
		local op_exec = op[1]
		local addr_exec = op[2]
		local base_cycles = op[3]
		local has_page_cross_penalty = buffer.readu8(page_cross_penalty, opcode) ~= 0
		local always_dummy_read = buffer.readu8(indexed_dummy_always, opcode) ~= 0

		if always_dummy_read then
			if has_page_cross_penalty then
				if op_exec and addr_exec then
					opcode_execute[opcode] = function()
						cycles = base_cycles

						addr_exec()
						bus_read(indexed_dummy_addr)

						op_exec()

						if page_crossed then
							cycles += 1
						end
					end
				elseif op_exec then
					opcode_execute[opcode] = function()
						cycles = base_cycles

						bus_read(indexed_dummy_addr)
						op_exec()

						if page_crossed then
							cycles += 1
						end
					end
				else
					opcode_execute[opcode] = function()
						cycles = base_cycles

						addr_exec()
						bus_read(indexed_dummy_addr)

						if page_crossed then
							cycles += 1
						end
					end
				end
			else
				if op_exec and addr_exec then
					opcode_execute[opcode] = function()
						cycles = base_cycles

						addr_exec()
						bus_read(indexed_dummy_addr)

						op_exec()
					end
				elseif op_exec then
					opcode_execute[opcode] = function()
						cycles = base_cycles

						bus_read(indexed_dummy_addr)
						op_exec()
					end
				else
					opcode_execute[opcode] = function()
						cycles = base_cycles

						addr_exec()
						bus_read(indexed_dummy_addr)
					end
				end
			end
		elseif has_page_cross_penalty then
			if op_exec and addr_exec then
				opcode_execute[opcode] = function()
					cycles = base_cycles

					addr_exec()
					if page_crossed then
						bus_read(indexed_dummy_addr)
					end

					op_exec()

					if page_crossed then
						cycles += 1
					end
				end
			elseif op_exec then
				opcode_execute[opcode] = function()
					cycles = base_cycles

					if page_crossed then
						bus_read(indexed_dummy_addr)
					end
					op_exec()

					if page_crossed then
						cycles += 1
					end
				end
			else
				opcode_execute[opcode] = function()
					cycles = base_cycles

					addr_exec()
					if page_crossed then
						bus_read(indexed_dummy_addr)
					end

					if page_crossed then
						cycles += 1
					end
				end
			end
		else
			if op_exec and addr_exec then
				opcode_execute[opcode] = function()
					cycles = base_cycles
					addr_exec()
					op_exec()
				end
			elseif op_exec then
				opcode_execute[opcode] = function()
					cycles = base_cycles
					op_exec()
				end
			else
				opcode_execute[opcode] = function()
					cycles = base_cycles
				end
			end
		end
	end
end

opcodes_init()

--// Public APIs

return {
	load = function(data: string)
		local rom = buffer.fromstring(data)
		local rom_len = buffer.len(rom)

		assert(rom_len >= 16, 'Invalid iNES ROM: header too short')

		local h1 = buffer.readu8(rom, 0)
		local h2 = buffer.readu8(rom, 1)
		local h3 = buffer.readu8(rom, 2)
		local h4 = buffer.readu8(rom, 3)

		assert(h1 == 0x4E and h2 == 0x45 and h3 == 0x53 and h4 == 0x1A, 'Invalid iNES header')

		local prg_banks = buffer.readu8(rom, 4)
		local chr_banks = buffer.readu8(rom, 5)

		local flags6 = buffer.readu8(rom, 6)
		local flags7 = buffer.readu8(rom, 7)
		local flags8 = buffer.readu8(rom, 8)
		local flags9 = buffer.readu8(rom, 9)
		local flags10 = buffer.readu8(rom, 10)
		local flags11 = buffer.readu8(rom, 11)
		local flags12 = buffer.readu8(rom, 12)
		local flags13 = buffer.readu8(rom, 13)
		local flags14 = buffer.readu8(rom, 14)
		local flags15 = buffer.readu8(rom, 15)

		local header_padding_is_zero = flags12 == 0 and flags13 == 0 and flags14 == 0 and flags15 == 0

		local is_ines2 = bit32.band(flags7, 0x0C) == 8
		local submapper: number? = nil

		local mapper_lower_nibble = bit32.rshift(bit32.band(flags6, 0xF0), 4)
		local mapper_upper_nibble = bit32.band(flags7, 0xF0)
		local mapper_number = bit32.bor(
			mapper_lower_nibble,
			mapper_upper_nibble
		)
		if (not is_ines2) and (not header_padding_is_zero) then
			-- Archaic/dirty iNES headers often store tag data in bytes 7-15 ('DiskDude!' style).
			-- In that case, ignore flags7 upper nibble for mapper selection.
			mapper_number = mapper_lower_nibble
		end
		if is_ines2 then
			mapper_number = bit32.bor(mapper_number, bit32.band(flags8, 0x0F) * 256)
			submapper = bit32.rshift(flags8, 4)
		end

		if is_ines2 then
			local prg_msb = bit32.band(flags9, 0x0F)
			local chr_msb = bit32.band(bit32.rshift(flags9, 4), 0x0F)

			-- Exponent/multiplier encoding exists in NES2 but is uncommon; keep parser strict.
			assert(prg_msb ~= 0x0F, 'NES2 PRG exponent size encoding is not supported')
			assert(chr_msb ~= 0x0F, 'NES2 CHR exponent size encoding is not supported')

			prg_banks = bit32.bor(prg_banks, prg_msb * 256)
			chr_banks = bit32.bor(chr_banks, chr_msb * 256)
		end

		local mapper_id = mapper_number
		mapper_is_mmc3 = mapper_id == 4
		mapper_is_mmc5 = mapper_id == 5
		mapper_is_vrc6 = mapper_id == 24 or mapper_id == 26
		mapper_is_vrc7 = mapper_id == 85
		mapper_has_vrc7_audio = mapper_id == 85 and submapper ~= 1
		assert(Mappers.supports(mapper_id), string.format('Unsupported mapper: %d', mapper_id))

		four_screen_mode = bit32.btest(flags6, 8)
		if four_screen_mode then
			mirroring_mode = 2
		else
			mirroring_mode = bit32.band(flags6, 1) == 0 and 3 or 2
		end
		if four_screen_mode then
			active_nametable_lut = NAMETABLE_5
		elseif mirroring_mode == 0 then
			active_nametable_lut = NAMETABLE_1
		elseif mirroring_mode == 1 then
			active_nametable_lut = NAMETABLE_2
		elseif mirroring_mode == 2 then
			active_nametable_lut = NAMETABLE_3
		else
			active_nametable_lut = NAMETABLE_4
		end

		local has_trainer = bit32.btest(flags6, 4)
		local has_battery = bit32.btest(flags6, 2)

		local prg_ram_size = 0
		if is_ines2 then
			local prg_ram_shift = bit32.band(flags10, 0x0F)
			local prg_nvram_shift = bit32.band(bit32.rshift(flags10, 4), 0x0F)

			local prg_ram_volatile = if prg_ram_shift == 0 then 0 else bit32.lshift(64, prg_ram_shift)
			local prg_ram_nonvolatile = if prg_nvram_shift == 0 then 0 else bit32.lshift(64, prg_nvram_shift)

			prg_ram_size = prg_ram_volatile + prg_ram_nonvolatile
		else
			prg_ram_size = (flags8 == 0 and 1 or flags8) * 0x2000
		end

		local offset = 16

		if has_trainer then
			offset += 512
		end

		local prg_size = prg_banks * 16384
		assert(prg_banks > 0, 'Invalid iNES ROM: no PRG banks')
		assert(rom_len >= offset + prg_size, 'Invalid iNES ROM: PRG section truncated')

		prg_rom = buffer.create(prg_size)
		prg_rom_len = prg_size

		if prg_size > 0 then
			buffer.copy(prg_rom, 0, rom, offset, prg_size)
		end

		offset += prg_size

		local chr_size = chr_banks * 8192

		if chr_size == 0 then
			if mapper_number == 13 then
				chr_size = 0x4000
			end
			if is_ines2 then
				local chr_ram_shift = bit32.band(flags11, 0x0F)
				local chr_nvram_shift = bit32.band(bit32.rshift(flags11, 4), 0x0F)
				local chr_ram_volatile = if chr_ram_shift == 0 then 0 else bit32.lshift(64, chr_ram_shift)
				local chr_ram_nonvolatile = if chr_nvram_shift == 0 then 0 else bit32.lshift(64, chr_nvram_shift)
				chr_size = chr_ram_volatile + chr_ram_nonvolatile
			end
			if chr_size <= 0 then
				chr_size = 8192
			end
			chr_is_ram = true

			chr_rom = buffer.create(chr_size)
			buffer.fill(chr_rom, 0, 0, chr_size)
		else
			chr_is_ram = false
			assert(rom_len >= offset + chr_size, 'Invalid iNES ROM: CHR section truncated')

			chr_rom = buffer.create(chr_size)
			buffer.copy(chr_rom, 0, rom, offset, chr_size)
		end
		chr_rom_len = chr_size

		if mapper_number == 5 then
			local crc_len = prg_size + (if chr_is_ram then 0 else chr_size)
			local crc = 0xFFFFFFFF

			local known_units = nil

			if crc_len <= 0 then
				local empty_u32 = bit32.bnot(crc) % 0x100000000

				if empty_u32 < 0 then
					empty_u32 += 0x100000000
				end

				known_units = MMC5_WRAM_UNITS_BY_CRC[empty_u32]
			else
				local start = offset - prg_size

				for i = start, start + crc_len - 1 do
					local b = buffer.readu8(rom, i)
					local idx = bit32.band(bit32.bxor(crc, b), 255)
					crc = bit32.bxor(bit32.rshift(crc, 8), buffer.readu32(CRC32_TABLE, idx * 4))
				end

				local final_u32 = bit32.bnot(crc) % 0x100000000
				if final_u32 < 0 then
					final_u32 += 0x100000000
				end

				known_units = MMC5_WRAM_UNITS_BY_CRC[final_u32]
			end

			if known_units then
				prg_ram_size = known_units * 0x2000
			elseif prg_ram_size < 0x10000 then
				prg_ram_size = 0x10000
			end
		end

		prg_ram = buffer.create(prg_ram_size)
		prg_ram_len = prg_ram_size

		mapper = Mappers.create({
			id = mapper_id,
			fourScreen = four_screen_mode,
			initialMirroring = mirroring_mode,
			prgBanks16 = prg_banks,
			chrBanks8 = chr_banks,
			prgSize = prg_size,
			chrSize = chr_size,
			chrIsRam = chr_is_ram,
			prgRamSize = prg_ram_size,
			hasBattery = has_battery,
			submapper = submapper,
			prgRam = prg_ram,
			chr = chr_rom,
			vram = vram,
		})

		if mapper then
			mapper_map_prg_addr = mapper.mapPrgAddr
			mapper_map_chr_addr = mapper.mapChrAddr
			mapper_write_cpu = mapper.write
			mapper_read_cpu = mapper.readCpu
			mapper_read_ppu = mapper.readPpu
			mapper_write_ppu = mapper.writePpu
			mapper_read_nametable = mapper.readNametable
			mapper_write_nametable = mapper.writeNametable
			mapper_map_prg_ram_addr = mapper.mapPrgRamAddr
			mapper_clock_cpu = mapper.clockCpu
			mapper_clock_scanline = mapper.clockScanline
			mapper_clock_a12 = mapper.clockA12
			mapper_on_ppu_address = mapper.onPpuAddress
			mapper_irq_pending = mapper.irqPending
			mapper_get_mirroring = mapper.getMirroring
			mapper_prg_ram_readable = mapper.prgRamReadable
			mapper_prg_ram_writable = mapper.prgRamWritable
			mapper_has_read_cpu = mapper_read_cpu ~= nil
			mapper_has_write_cpu = mapper_write_cpu ~= nil
			mapper_has_read_ppu = mapper_read_ppu ~= nil
			mapper_has_write_ppu = mapper_write_ppu ~= nil
			mapper_has_read_nametable = mapper_read_nametable ~= nil
			mapper_has_write_nametable = mapper_write_nametable ~= nil
			mapper_has_map_prg_ram_addr = mapper_map_prg_ram_addr ~= nil
			mapper_has_cpu_clock = mapper_clock_cpu ~= nil
			mapper_has_irq_pending = mapper_irq_pending ~= nil
			mapper_has_get_mirroring = mapper_get_mirroring ~= nil
			mapper_has_scanline_clock = mapper_clock_scanline ~= nil
			mapper_has_a12_clock = mapper_clock_a12 ~= nil
			mapper_has_ppu_address_hook = mapper_on_ppu_address ~= nil
			mapper_has_prg_ram_readable = mapper_prg_ram_readable ~= nil
			mapper_has_prg_ram_writable = mapper_prg_ram_writable ~= nil

			if mapper_is_mmc3 then
				mapper_clock_a12 = nil
				mapper_has_a12_clock = false
				mapper_has_irq_pending = false
			end

			mapper_needs_sprite_fetch = mapper_is_mmc3 or mapper_has_a12_clock or mapper_has_ppu_address_hook or mapper_has_read_ppu
			mapper_prg_read_side_effect = if mapper_is_mmc5 then apu_on_mmc5_cpu_read else nil

			mapper_special_low_read = mapper_is_mmc5 and function(addr: number): number?
				return if addr == 0x5010 or addr == 0x5015 then apu_read_mmc5(addr) else nil
			end or nil

			if mapper_has_write_cpu then
				if mapper_is_mmc3 then
					mapper_write_high_cpu = function(addr: number, value: number)
						mapper_write_cpu(addr, value)

						if addr >= 0xC000 then
							local even = bit32.band(addr, 1) == 0
							if addr < 0xE000 then
								if even then
									mmc3_irq_latch = value
								else
									mmc3_irq_reload = true
								end
							else
								if even then
									mmc3_irq_enabled = false
									mmc3_irq_pending = false
								else
									mmc3_irq_enabled = true
								end
							end
						end

						sync_mapper_dynamic_state()

						mapper_cpu_irq_current = if mapper_has_cpu_clock and mapper_has_irq_pending then
							mapper_irq_pending_fast() else false
					end
				elseif mapper_is_vrc6 then
					mapper_write_high_cpu = function(addr: number, value: number)
						mapper_write_cpu(addr, value)
						apu_write_vrc6(addr, value)
						sync_mapper_dynamic_state()

						mapper_cpu_irq_current = if mapper_has_cpu_clock and mapper_has_irq_pending then
							mapper_irq_pending_fast() else false
					end
				elseif mapper_is_vrc7 and mapper_has_vrc7_audio then
					mapper_write_high_cpu = function(addr: number, value: number)
						mapper_write_cpu(addr, value)
						apu_write_vrc7(addr, value)
						sync_mapper_dynamic_state()

						mapper_cpu_irq_current = if mapper_has_cpu_clock and mapper_has_irq_pending then
							mapper_irq_pending_fast() else false
					end
				else
					mapper_write_high_cpu = function(addr: number, value: number)
						mapper_write_cpu(addr, value)
						sync_mapper_dynamic_state()

						mapper_cpu_irq_current = if mapper_has_cpu_clock and mapper_has_irq_pending then
							mapper_irq_pending_fast() else false
					end
				end
			else
				mapper_write_high_cpu = nil
			end
			if mapper_is_mmc3 then
				mapper_irq_pending_fast = function(): boolean
					return mmc3_irq_pending
				end
			elseif mapper_has_irq_pending then
				mapper_irq_pending_fast = mapper_irq_pending
			else
				mapper_irq_pending_fast = nil
			end
			mapper_cpu_irq_prev = false
			mapper_cpu_irq_current = false
			mapper_branch_irq_delay = false

			mapper_cpu_irq_current = if mapper_has_cpu_clock and mapper_has_irq_pending then
				mapper_irq_pending_fast() else false

			sync_mapper_dynamic_state()
		else
			mapper_map_prg_addr = nil
			mapper_map_chr_addr = nil
			mapper_write_cpu = nil
			mapper_read_cpu = nil
			mapper_read_ppu = nil
			mapper_write_ppu = nil
			mapper_read_nametable = nil
			mapper_write_nametable = nil
			mapper_map_prg_ram_addr = nil
			mapper_clock_cpu = nil
			mapper_clock_scanline = nil
			mapper_clock_a12 = nil
			mapper_on_ppu_address = nil
			mapper_irq_pending = nil
			mapper_get_mirroring = nil
			mapper_prg_ram_readable = nil
			mapper_prg_ram_writable = nil
			mapper_has_read_cpu = false
			mapper_has_write_cpu = false
			mapper_has_read_ppu = false
			mapper_has_write_ppu = false
			mapper_has_read_nametable = false
			mapper_has_write_nametable = false
			mapper_has_map_prg_ram_addr = false
			mapper_has_cpu_clock = false
			mapper_has_irq_pending = false
			mapper_has_get_mirroring = false
			mapper_has_scanline_clock = false
			mapper_has_a12_clock = false
			mapper_has_ppu_address_hook = false
			mapper_has_prg_ram_readable = false
			mapper_has_prg_ram_writable = false
			mapper_prg_ram_readable_state = true
			mapper_prg_ram_writable_state = true
			mapper_needs_sprite_fetch = false
			mapper_prg_read_side_effect = nil
			mapper_special_low_read = nil
			mapper_write_high_cpu = nil
			mapper_irq_pending_fast = nil
			mapper_cpu_irq_prev = false
			mapper_cpu_irq_current = false
			mapper_branch_irq_delay = false
			
			if four_screen_mode then
				active_nametable_lut = NAMETABLE_5
			elseif mirroring_mode == 0 then
				active_nametable_lut = NAMETABLE_1
			elseif mirroring_mode == 1 then
				active_nametable_lut = NAMETABLE_2
			elseif mirroring_mode == 2 then
				active_nametable_lut = NAMETABLE_3
			else
				active_nametable_lut = NAMETABLE_4
			end
		end

		buffer.fill(prg_ram, 0, 0, prg_ram_len)
		buffer.fill(ram, 0, 0, 0x800)
		buffer.fill(vram, 0, 0, 0x1000)
		buffer.fill(oam, 0, 0, 0x100)
		buffer.fill(palette, 0, 0, 32)

		for i = 0, 31 do
			local base_color_index = bit32.band(buffer.readu8(palette, i), 0x3F)

			buffer.writeu32(
				palette_rgba32,
				i * 4,
				buffer.readu32(nes_rgba32, base_color_index * 4)
			)

			buffer.writeu32(
				palette_rgba32,
				(i + 32) * 4,
				buffer.readu32(nes_rgba32, bit32.band(base_color_index, 0x30) * 4)
			)
		end

		buffer.fill(framebuffer, 0, 0)
		cpu_total_cycles = 0
		dma_cycles = 0
		nmi_pending_flag = false
		nmi_line_state = false
		nmi_delay_cycles = 0
		irq_poll_delay = 0
		scanline = 0
		ppu_cycle = 0
		frame_row_start = 0
		visible_sprite_count = 0
		next_visible_sprite_count = 0
		sprite_overflow_next = false
		sprite_eval_active = false
		sprite_eval_target_scanline = -1
		sprite_eval_sprite_height = 8
		sprite_eval_pattern_base = 0
		sprite_eval_stage = 0
		sprite_eval_n = 0
		sprite_eval_overflow_m = 0
		sprite_eval_latch = 0
		sprite_eval_candidate_y = 0
		sprite_eval_candidate_tile = 0
		sprite_eval_candidate_attr = 0
		frame_ready = false
		pad_strobe = 0
		odd_frame = false
		mmc3_irq_latch = 0
		mmc3_irq_counter = 0
		mmc3_irq_reload = false
		mmc3_irq_enabled = false
		mmc3_irq_pending = false
		mmc3_a12_prev = false
		mmc3_a12_low_cycles = 12
		mmc3_a12_sampled = false
		in_ppu_step = false
		cpu_instruction_active = false
		cpu_bus_cycles = 0
		cpu_pending_cycles = 0
		apu_pending_cycles = 0
		in_dma_transfer = false
		cpu_jammed = false
		data_buffer = 0
		ppu_status = 0

		ctrl_vram_increment = 1
		ctrl_sprite_pattern_base = 0
		ctrl_bg_pattern_base = 0
		ctrl_sprite_8x16 = false
		nmi_output = false

		ctrl_sprite_height = 8

		mask_show_bg = false
		mask_show_sp = false
		mask_bg_left = false
		mask_sp_left = false
		mask_grayscale = false
		mask_rendering = false

		open_bus = 0
		ppu_open_bus = 0
		v = 0
		t = 0
		w = 0
		fine_x = 0
		oam_addr = 0

		-- NES 2.0 byte 15 identifies the standard port-2 Zapper variants this core exposes on $4017.
		zapper_enabled = is_ines2 and (flags15 == 0x08 or flags15 == 0x09)

		zapper_min_x = 255
		zapper_max_x = 0
		zapper_min_y = 239
		zapper_max_y = 0
		zapper_light = 0
		zapper_trigger_frames = 0
		pad1_state = 0
		pad2_state = 0
		pad1_index = 0
		pad2_index = 0
		sprite_scanline_generation = 1
		buffer.fill(sprite_scanline_data, 0, 0, 1024)
		buffer.fill(sprite_slots, 0, 0, 32)
		buffer.fill(sprite_slots_next, 0, 0, 32)
		bg_nt_byte = 0
		bg_at_byte = 0
		bg_low_byte = 0
		bg_high_byte = 0
		bg_attr_latch_low = 0
		bg_attr_latch_high = 0
		bg_shift_pat_low = 0
		bg_shift_pat_high = 0
		bg_shift_attr_low = 0
		bg_shift_attr_high = 0

		apu.reset()
		apu.setMmc5Enabled(mapper_is_mmc5)
		apu.setVrc6Enabled(mapper_is_vrc6)
		apu.setVrc7Enabled(mapper_has_vrc7_audio)
		pc = bus_read(0xFFFC) + bus_read(0xFFFD) * 256
	end,

	reset = function()
		sp = 0xFD
		status = bit32.bor(bit32.band(status, 0xCF), 0x24)
		status = bit32.bor(status, 4)
		cpu_total_cycles = 0
		dma_cycles = 0
		nmi_pending_flag = false
		nmi_line_state = false
		nmi_delay_cycles = 0
		irq_poll_delay = 0
		scanline = 0
		ppu_cycle = 0
		frame_row_start = 0
		visible_sprite_count = 0
		next_visible_sprite_count = 0
		sprite_overflow_next = false
		sprite_eval_active = false
		sprite_eval_target_scanline = -1
		sprite_eval_sprite_height = 8
		sprite_eval_pattern_base = 0
		sprite_eval_stage = 0
		sprite_eval_n = 0
		sprite_eval_overflow_m = 0
		sprite_eval_latch = 0
		sprite_eval_candidate_y = 0
		sprite_eval_candidate_tile = 0
		sprite_eval_candidate_attr = 0
		frame_ready = false
		pad_strobe = 0
		odd_frame = false
		mmc3_irq_latch = 0
		mmc3_irq_counter = 0
		mmc3_irq_reload = false
		mmc3_irq_enabled = false
		mmc3_irq_pending = false
		mmc3_a12_prev = false
		mmc3_a12_low_cycles = 12
		mmc3_a12_sampled = false
		in_ppu_step = false
		cpu_instruction_active = false
		cpu_bus_cycles = 0
		cpu_pending_cycles = 0
		apu_pending_cycles = 0
		in_dma_transfer = false
		cpu_jammed = false
		data_buffer = 0
		ppu_status = 0

		ctrl_vram_increment = 1
		ctrl_sprite_pattern_base = 0
		ctrl_bg_pattern_base = 0
		ctrl_sprite_8x16 = false
		nmi_output = false

		ctrl_sprite_height = 8

		mask_show_bg = false
		mask_show_sp = false
		mask_bg_left = false
		mask_sp_left = false
		mask_grayscale = false
		mask_rendering = false

		open_bus = 0
		ppu_open_bus = 0
		v = 0
		t = 0
		w = 0
		fine_x = 0
		oam_addr = 0

		zapper_light = 0
		zapper_trigger_frames = 0
		pad1_index = 0
		pad2_index = 0
		sprite_scanline_generation = 1
		buffer.fill(sprite_scanline_data, 0, 0, 1024)
		buffer.fill(sprite_slots, 0, 0, 32)
		buffer.fill(sprite_slots_next, 0, 0, 32)
		bg_nt_byte = 0
		bg_at_byte = 0
		bg_low_byte = 0
		bg_high_byte = 0
		bg_attr_latch_low = 0
		bg_attr_latch_high = 0
		bg_shift_pat_low = 0
		bg_shift_pat_high = 0
		bg_shift_attr_low = 0
		bg_shift_attr_high = 0

		if mapper then
			mapper.reset()
			sync_mapper_dynamic_state()
			mapper_cpu_irq_prev = false
			mapper_cpu_irq_current = false
			mapper_branch_irq_delay = false

			mapper_cpu_irq_current = if mapper_has_cpu_clock and mapper_has_irq_pending then
				mapper_irq_pending_fast() else false
		end

		apu.reset()
		apu.setMmc5Enabled(mapper_is_mmc5)
		apu.setVrc6Enabled(mapper_is_vrc6)
		apu.setVrc7Enabled(mapper_has_vrc7_audio)
		pc = bus_read(0xFFFC) + bus_read(0xFFFD) * 256
	end,

	render = function(): buffer?
		while not frame_ready do
			if cpu_jammed then
				cpu_instruction_active = true
				cpu_bus_cycles = 0
				cpu_pending_cycles = 0

				cycles = 2
				local remaining = cpu_bus_cycles > 2 and 0 or 2 - cpu_bus_cycles

				if remaining > 0 then
					cpu_pending_cycles += remaining
				end

				flush_cpu_timing_apuflush()
				cpu_bus_cycles = 0
				cpu_pending_cycles = 0
				cpu_instruction_active = false
			elseif nmi_pending_flag then
				cpu_instruction_active = true
				cpu_bus_cycles = 0
				cpu_pending_cycles = 0
				nmi_pending_flag = false

				bus_write(0x0100 + sp, bit32.rshift(pc, 8))
				sp = bit32.band(sp - 1, 255)

				bus_write(0x0100 + sp, bit32.band(pc, 255))
				sp = bit32.band(sp - 1, 255)

				bus_write(0x0100 + sp, bit32.bor(bit32.band(status, 0xEF), 0x20))
				sp = bit32.band(sp - 1, 255)

				status = bit32.bor(status, 4)
				irq_poll_delay = 0
				pc = bus_read(0xFFFA) + bus_read(0xFFFB) * 256

				local remaining = 7 - cpu_bus_cycles
				if remaining < 0 then
					remaining = 0
				end

				if remaining > 0 then
					cpu_pending_cycles += remaining
				end

				flush_cpu_timing_apuflush()
				cpu_bus_cycles = 0
				cpu_pending_cycles = 0
				cpu_instruction_active = false
			elseif irq_poll_delay == 0 and not bit32.btest(status, 4) and (apu_irq_pending() or (mapper_has_cpu_clock and mapper_cpu_irq_prev) or ((not mapper_has_cpu_clock) and mapper_irq_pending_fast and mapper_irq_pending_fast())) then
				cpu_instruction_active = true
				cpu_bus_cycles = 0
				cpu_pending_cycles = 0

				bus_write(0x0100 + sp, bit32.rshift(pc, 8))
				sp = bit32.band(sp - 1, 255)

				bus_write(0x0100 + sp, bit32.band(pc, 255))
				sp = bit32.band(sp - 1, 255)

				bus_write(0x0100 + sp, bit32.bor(bit32.band(status, 0xEF), 0x20))
				sp = bit32.band(sp - 1, 255)

				status = bit32.bor(status, 4)
				irq_poll_delay = 0
				if nmi_pending_flag or (nmi_delay_cycles > 0 and nmi_delay_cycles <= 4) then
					nmi_pending_flag = false
					nmi_delay_cycles = 0
					pc = bus_read(0xFFFA) + bus_read(0xFFFB) * 256
				else
					pc = bus_read(0xFFFE) + bus_read(0xFFFF) * 256
				end

				local remaining = cpu_bus_cycles > 2 and 0 or 7 - cpu_bus_cycles

				if remaining > 0 then
					cpu_pending_cycles += remaining
				end

				flush_cpu_timing_apuflush()
				cpu_bus_cycles = 0
				cpu_pending_cycles = 0
				cpu_instruction_active = false
			else
				cpu_instruction_active = true
				cpu_bus_cycles = 0
				cpu_pending_cycles = 0

				local opcode = bus_read(pc)
				pc += 1
				if pc == 0x10000 then
					pc = 0
				end
				opcode_execute[opcode]()

				cycles += dma_cycles
				dma_cycles = 0

				local remaining = cycles - cpu_bus_cycles
				if remaining < 0 then
					remaining = 0
				end

				if remaining > 0 then
					cpu_pending_cycles += remaining
				end

				flush_cpu_timing_apuflush()
				cpu_bus_cycles = 0
				cpu_pending_cycles = 0
				cpu_instruction_active = false
				if irq_poll_delay > 0 then
					irq_poll_delay -= 1
				end
				if mapper_branch_irq_delay then
					mapper_cpu_irq_prev = false
					mapper_branch_irq_delay = false
				end
			end
		end

		frame_ready = false
		if zapper_trigger_frames > 0 then
			zapper_trigger_frames -= 1
		end
		return framebuffer
	end,

	press = function(button: number, player: number?)
		if player == 2 then
			pad2_state = bit32.bor(pad2_state, button)
		else
			pad1_state = bit32.bor(pad1_state, button)
		end
	end,

	release = function(button: number, player: number?)
		if player == 2 then
			pad2_state = bit32.band(pad2_state, bit32.bnot(button))
		else
			pad1_state = bit32.band(pad1_state, bit32.bnot(button))
		end
	end,

	point = function(px: number, py: number)
		if px >= 0 and px < 256 and py >= 0 and py < 240 then
			zapper_min_x = math.max(px - 4, 0)
			zapper_max_x = math.min(px + 4, 255)
			zapper_min_y = math.max(py - 4, 0)
			zapper_max_y = math.min(py + 4, 239)
		else
			zapper_min_x = 255
			zapper_max_x = 0
			zapper_min_y = 239
			zapper_max_y = 0
		end
	end,

	trigger = function()
		zapper_trigger_frames = 2
	end,

	size = Vector2.new(256, 240),

	Buttons = {
		A = 1,
		B = 2,
		Select = 4,
		Start = 8,
		Up = 16,
		Down = 32,
		Left = 64,
		Right = 128,
	},
}

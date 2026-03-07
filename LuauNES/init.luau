--!native
--!nocheck
--!optimize 2

local Mappers = require('@self/Mappers')
local MMC5ID = require('@self/MMC5ID')
local APU = require('@self/APU')

type Mapper = Mappers.Mapper

local FRAMEBUFFER_SIZE = 256 * 240 * 4

local PALETTE_SIZE = 32
local PALETTE_ADDR_LUT = buffer.create(PALETTE_SIZE)
local NAMETABLE_LUTS = {
	buffer.create(0x1000 * 2),
	buffer.create(0x1000 * 2),
	buffer.create(0x1000 * 2),
	buffer.create(0x1000 * 2),
	buffer.create(0x1000 * 2),
}

for i = 0, PALETTE_SIZE - 1 do
	local mapped = i
	if bit32.band(i, 0x13) == 0x10 then
		mapped = i - 0x10
	end
	buffer.writeu8(PALETTE_ADDR_LUT, i, mapped)
end

local SPRITE_NORMAL_PIXEL = buffer.create(0x10000 * 8)
local SPRITE_FLIP_PIXEL = buffer.create(0x10000 * 8)

for low = 0, 255 do
	local low_shifted = bit32.lshift(low, 8)
	for high = 0, 255 do
		local pattern = low_shifted + high
		local pattern_base = bit32.lshift(pattern, 3)
		for offset = 0, 7 do
			local normal_bit = 7 - offset
			local normal_pixel =
				bit32.band(bit32.rshift(low, normal_bit), 1)
				+ bit32.lshift(bit32.band(bit32.rshift(high, normal_bit), 1), 1)
			local flip_pixel =
				bit32.band(bit32.rshift(low, offset), 1)
				+ bit32.lshift(bit32.band(bit32.rshift(high, offset), 1), 1)

			buffer.writeu8(SPRITE_NORMAL_PIXEL, pattern_base + offset, normal_pixel)
			buffer.writeu8(SPRITE_FLIP_PIXEL, pattern_base + offset, flip_pixel)
		end
	end
end

local framebuffer = buffer.create(FRAMEBUFFER_SIZE)
local palette = buffer.create(PALETTE_SIZE)
local prg_ram = buffer.create(0x2000)
local vram = buffer.create(0x1000)
local oam = buffer.create(0x100)
local ram = buffer.create(0x800)

local pad_state = buffer.create(2)
local pad_index = buffer.create(2)

local sprite_high = buffer.create(8)
local sprite_meta = buffer.create(8)
local sprite_low = buffer.create(8)
local sprite_x = buffer.create(8)
local sprite_high_next = buffer.create(8)
local sprite_meta_next = buffer.create(8)
local sprite_low_next = buffer.create(8)
local sprite_x_next = buffer.create(8)
local sprite_pattern_addr_next = buffer.create(16)
local sprite_scanline_data = buffer.create(1024)
local sprite_scanline_generation = 1

local prg_rom = buffer.create(0)
local chr_rom = buffer.create(0)
local prg_rom_len = 0
local chr_rom_len = 0
local prg_ram_len = 0x2000

local status = 36

local a, x, y, sp, pc = 0, 0, 0, 253, 0

local data_buffer = 0
local ppu_status = 0
local addr_value = 0
local dma_cycles = 0

local function default_map_prg_addr(_addr: number): number
	return -1
end

local function default_map_chr_addr(addr: number, _fetch_kind: number?, _sprite_16: boolean?): number
	return bit32.band(addr, 0x1FFF)
end

local mirroring_mode = 3
local mapper = nil :: Mapper?

local mapper_map_prg_addr = default_map_prg_addr
local mapper_map_chr_addr = default_map_chr_addr
local mapper_write_cpu = nil :: ((number, number) -> ())?
local mapper_read_cpu = nil :: ((number) -> number?)?
local mapper_read_nametable = nil :: ((number) -> number?)?
local mapper_write_nametable = nil :: ((number, number) -> boolean)?
local mapper_map_prg_ram_addr = nil :: ((number) -> number?)?
local mapper_clock_scanline = nil :: ((number?) -> ())?
local mapper_clock_a12 = nil :: ((boolean) -> ())?
local mapper_on_ppu_address = nil :: ((number, number, number, boolean) -> ())?
local mapper_irq_pending = nil :: (() -> boolean)?
local mapper_get_mirroring = nil :: (() -> number)?
local mapper_prg_ram_readable = nil :: (() -> boolean)?
local mapper_prg_ram_writable = nil :: (() -> boolean)?
local mapper_has_read_cpu = false
local mapper_has_write_cpu = false
local mapper_has_read_nametable = false
local mapper_has_write_nametable = false
local mapper_has_map_prg_ram_addr = false
local mapper_has_irq_pending = false
local mapper_has_get_mirroring = false
local mapper_has_scanline_clock = false
local mapper_has_a12_clock = false
local mapper_has_ppu_address_hook = false
local mapper_has_prg_ram_readable = false
local mapper_has_prg_ram_writable = false
local mapper_prg_ram_readable_state = true
local mapper_prg_ram_writable_state = true
local mapper_needs_sprite_fetch = false
local mapper_is_mmc3 = false
local mapper_is_mmc5 = false
local four_screen_mode = false
local active_nametable_lut = NAMETABLE_LUTS[4]

local scanline = 0
local ppu_cycle = 0
local frame_row_start = 0
local oam_addr = 0
local visible_sprite_count = 0
local next_visible_sprite_count = 0
local sprite_overflow_next = false
local sprite_eval_active = false
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
local ctrl = 0
local mask = 0
local ctrl_vram_increment = 1
local ctrl_bg_pattern_base = 0
local ctrl_sprite_pattern_base = 0
local ctrl_sprite_8x16 = false
local ctrl_sprite_height = 8
local mask_show_bg = false
local mask_show_sp = false
local mask_bg_left = false
local mask_sp_left = false
local mask_grayscale = false
local mask_rendering = false
local cpu_total_cycles = 0

local v = 0
local t = 0
local w = 0

local nmi_pending_flag = false
local nmi_output = false
local pad_strobe = 0

local page_crossed = false
local indexed_dummy_addr = 0
local frame_ready = false
local chr_is_ram = false
local odd_frame = false
local open_bus = 0
local mmc3_irq_latch = 0
local mmc3_irq_counter = 0
local mmc3_irq_reload = false
local mmc3_irq_enabled = false
local mmc3_irq_pending = false
local mmc3_a12_prev = false
local mmc3_a12_low_cycles = 12
local mmc3_a12_sampled = false
local in_ppu_step = false
local cpu_instruction_active = false
local cpu_bus_cycles = 0
local cpu_pending_cycles = 0
local apu_pending_cycles = 0
local in_dma_transfer = false
local cpu_jammed = false

local function set_ctrl(value: number)
	ctrl = bit32.band(value, 0xFF)

	ctrl_vram_increment = if bit32.btest(ctrl, 0x04) then 32 else 1
	ctrl_sprite_pattern_base = if bit32.btest(ctrl, 0x08) then 0x1000 else 0
	ctrl_bg_pattern_base = if bit32.btest(ctrl, 0x10) then 0x1000 else 0
	ctrl_sprite_8x16 = bit32.btest(ctrl, 0x20)

	ctrl_sprite_height = if ctrl_sprite_8x16 then 16 else 8
end

local function set_mask(value: number)
	mask = bit32.band(value, 0xFF)
	mask_show_bg = bit32.btest(mask, 0x08)
	mask_show_sp = bit32.btest(mask, 0x10)
	mask_bg_left = bit32.btest(mask, 0x02)
	mask_sp_left = bit32.btest(mask, 0x04)
	mask_grayscale = bit32.btest(mask, 0x01)
	mask_rendering = mask_show_bg or mask_show_sp
end

local RAW_PALETTE = {

	0x626262, 0x001FB2, 0x2404C8, 0x5200B2, 0x730076, 0x800024, 0x730B00, 0x522800,
	0x244400, 0x005700, 0x005C00, 0x005324, 0x003C76, 0x000000, 0x000000, 0x000000,
	0xABABAB, 0x0D57FF, 0x4B30FF, 0x8A13FF, 0xBC08D6, 0xD21269, 0xC72E00, 0x9D5400,
	0x607B00, 0x209800, 0x00A300, 0x009942, 0x007DB4, 0x000000, 0x000000, 0x000000,
	0xFFFFFF, 0x53AEFF, 0x9085FF, 0xD365FF, 0xFF57FF, 0xFF5DCF, 0xFF7757, 0xFA9E00,
	0xBDC700, 0x7AE700, 0x43F611, 0x26EF7E, 0x2CD5F6, 0x4E4E4E, 0x000000, 0x000000,
	0xFFFFFF, 0xB6E1FF, 0xCED1FF, 0xE9C3FF, 0xFFBCFF, 0xFFBDF4, 0xFFC6C3, 0xFFD59A,
	0xE9E681, 0xCEF481, 0xB6FB9A, 0xA9FAC3, 0xA9F0F4, 0xB8B8B8, 0x000000, 0x000000

}

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

build_nametable_lut(NAMETABLE_LUTS[1], 0, false)
build_nametable_lut(NAMETABLE_LUTS[2], 1, false)
build_nametable_lut(NAMETABLE_LUTS[3], 2, false)
build_nametable_lut(NAMETABLE_LUTS[4], 3, false)
build_nametable_lut(NAMETABLE_LUTS[5], 0, true)

local function refresh_nametable_lut()
	if four_screen_mode then
		active_nametable_lut = NAMETABLE_LUTS[5]
	elseif mirroring_mode == 0 then
		active_nametable_lut = NAMETABLE_LUTS[1]
	elseif mirroring_mode == 1 then
		active_nametable_lut = NAMETABLE_LUTS[2]
	elseif mirroring_mode == 2 then
		active_nametable_lut = NAMETABLE_LUTS[3]
	else
		active_nametable_lut = NAMETABLE_LUTS[4]
	end
end

local nes_rgba32 = buffer.create(64 * 4)
local palette_rgba32 = buffer.create(64 * 4)

for i = 0, 63 do
	local rgb = RAW_PALETTE[i + 1]

	local r = bit32.band(bit32.rshift(rgb, 16), 255)
	local g = bit32.band(bit32.rshift(rgb, 8), 255)
	local b = bit32.band(rgb, 0xFF)

	buffer.writeu32(nes_rgba32, i * 4, r + bit32.lshift(g, 8) + bit32.lshift(b, 16) + 0xFF000000)
end

local function sync_mapper_dynamic_state()
	if mapper_has_get_mirroring then
		local mapper_mirroring = mapper_get_mirroring()
		if mapper_mirroring ~= mirroring_mode then
			mirroring_mode = mapper_mirroring
			refresh_nametable_lut()
		end
	end

	mapper_prg_ram_readable_state = not mapper_has_prg_ram_readable or mapper_prg_ram_readable()
	mapper_prg_ram_writable_state = not mapper_has_prg_ram_writable or mapper_prg_ram_writable()
end

local function bind_mapper(mapper_value: Mapper?)
	mapper = mapper_value

	if mapper then
		mapper_map_prg_addr = mapper.mapPrgAddr
		mapper_map_chr_addr = mapper.mapChrAddr
		mapper_write_cpu = mapper.write
		mapper_read_cpu = mapper.readCpu
		mapper_read_nametable = mapper.readNametable
		mapper_write_nametable = mapper.writeNametable
		mapper_map_prg_ram_addr = mapper.mapPrgRamAddr
		mapper_clock_scanline = mapper.clockScanline
		mapper_clock_a12 = mapper.clockA12
		mapper_on_ppu_address = mapper.onPpuAddress
		mapper_irq_pending = mapper.irqPending
		mapper_get_mirroring = mapper.getMirroring
		mapper_prg_ram_readable = mapper.prgRamReadable
		mapper_prg_ram_writable = mapper.prgRamWritable
		mapper_has_read_cpu = mapper_read_cpu ~= nil
		mapper_has_write_cpu = mapper_write_cpu ~= nil
		mapper_has_read_nametable = mapper_read_nametable ~= nil
		mapper_has_write_nametable = mapper_write_nametable ~= nil
		mapper_has_map_prg_ram_addr = mapper_map_prg_ram_addr ~= nil
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
		mapper_needs_sprite_fetch = mapper_is_mmc3 or mapper_has_a12_clock or mapper_has_ppu_address_hook
		sync_mapper_dynamic_state()
	else
		mapper_map_prg_addr = default_map_prg_addr
		mapper_map_chr_addr = default_map_chr_addr
		mapper_write_cpu = nil
		mapper_read_cpu = nil
		mapper_read_nametable = nil
		mapper_write_nametable = nil
		mapper_map_prg_ram_addr = nil
		mapper_clock_scanline = nil
		mapper_clock_a12 = nil
		mapper_on_ppu_address = nil
		mapper_irq_pending = nil
		mapper_get_mirroring = nil
		mapper_prg_ram_readable = nil
		mapper_prg_ram_writable = nil
		mapper_has_read_cpu = false
		mapper_has_write_cpu = false
		mapper_has_read_nametable = false
		mapper_has_write_nametable = false
		mapper_has_map_prg_ram_addr = false
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
		refresh_nametable_lut()
	end
end

local function prg_read(addr: number): number
	local offset = mapper_map_prg_addr(addr)
	if offset < 0 or offset >= prg_rom_len then
		return 0
	end

	return buffer.readu8(prg_rom, offset)
end

for i = 0, PALETTE_SIZE - 1 do
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

local apu = APU(prg_read)

local apu_step = apu.step
local apu_sync_mixer = apu.syncMixer
local apu_read_status = apu.readStatus
local apu_write = apu.write
local apu_read_mmc5 = apu.readMmc5
local apu_write_mmc5 = apu.writeMmc5
local apu_on_mmc5_cpu_read = apu.onMmc5CpuRead
local apu_set_mmc5_enabled = apu.setMmc5Enabled
local apu_reset = apu.reset
local apu_irq_pending = apu.irqPending
local apu_consume_dma_stall_cycles = apu.consumeDmaStallCycles

local function clock_mmc3_a12_now(a12_high: boolean)
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
		-- Only the >= 12 threshold matters for MMC3 IRQ edge qualification.
		if mmc3_a12_low_cycles < 12 then
			mmc3_a12_low_cycles += 1
		end
	end
end

local function sync_mmc3_irq_write(addr: number, value: number)
	if addr < 0xC000 then
		return
	end

	local even = bit32.band(addr, 1) == 0
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

local function ppu_read(addr: number, fetch_kind: number?)
	if addr >= 0x4000 then
		addr = bit32.band(addr, 0x3FFF)
	end

	if mapper_is_mmc5 then
		mapper_on_ppu_address(addr, scanline, ppu_cycle + 1, mask_rendering)
	elseif mapper_has_ppu_address_hook then
		mapper_on_ppu_address(addr, scanline, ppu_cycle + 1, mask_rendering)
	end

	if addr < 0x2000 then
		if mapper_is_mmc3 then
			local a12_high = addr >= 0x1000
			if in_ppu_step then
				mmc3_a12_sampled = a12_high
			else
				clock_mmc3_a12_now(a12_high)
			end
		elseif mapper_has_a12_clock then
			if in_ppu_step then
				mmc3_a12_sampled = addr >= 0x1000
			else
				mapper_clock_a12(addr >= 0x1000)
			end
		end

		local mapped = mapper_map_chr_addr(addr, fetch_kind or 0, ctrl_sprite_8x16)
		return if mapped < 0 or mapped >= chr_rom_len then 0 else buffer.readu8(chr_rom, mapped)
	end

	if addr < 0x3F00 then
		if mapper_is_mmc5 then
			local value = mapper_read_nametable(addr)
			if value then
				return bit32.band(value, 0xFF)
			end
		elseif mapper_has_read_nametable then
			local value = mapper_read_nametable(addr)
			if value then
				return bit32.band(value, 0xFF)
			end
		end
		return buffer.readu8(vram, buffer.readu16(active_nametable_lut, bit32.band(addr, 0x0FFF) * 2))
	end

	return buffer.readu8(palette, buffer.readu8(PALETTE_ADDR_LUT, bit32.band(addr, 0x1F)))
end

local function reset_bg_pipeline()
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
	local sprite_low_next_buf = sprite_low_next
	local sprite_high_next_buf = sprite_high_next
	local sprite_8x16 = ctrl_sprite_8x16

	local show_bg = mask_show_bg
	local show_sp = mask_show_sp

	local bg_left_min_px = if mask_bg_left then 0 else 8
	local sp_left_min_px = if mask_sp_left then 0 else 8

	local grayscale_palette_offset = if mask_grayscale then 32 else 0

	local rendering = mask_rendering

	local bg_mux = bit32.rshift(0x8000, fine_x)

	local sprite_height = ctrl_sprite_height
	local sprite_pattern_base = ctrl_sprite_pattern_base
	local bg_pattern_base = ctrl_bg_pattern_base
	local sprite_scanline_data_buf = sprite_scanline_data

	local sprite_pixel_lut_normal = SPRITE_NORMAL_PIXEL
	local sprite_pixel_lut_flip = SPRITE_FLIP_PIXEL
	local sprite_generation_tag = bit32.lshift(sprite_scanline_generation, 16)
	local mmc3_irq_latch_local = mmc3_irq_latch
	local mmc3_irq_counter_local = mmc3_irq_counter
	local mmc3_irq_reload_local = mmc3_irq_reload
	local mmc3_irq_enabled_local = mmc3_irq_enabled
	local mmc3_irq_pending_local = mmc3_irq_pending
	local mmc3_a12_prev_local = mmc3_a12_prev
	local mmc3_a12_low_cycles_local = mmc3_a12_low_cycles

	for _ = 1, count do
		in_ppu_step = true

		local cycle = ppu_cycle + 1

		local visible_line = scanline < 240
		local pre_render_line = scanline == 261

		mmc3_a12_sampled = false

		if ppu_cycle == 0 then
			if has_scanline_clock then
				clock_scanline(scanline)
			end

			if visible_line then
				frame_row_start = scanline * 1024
				if rendering then
					-- Swap the next-scanline sprite buffers into the active set at dot 0.
					local tmp_x = sprite_x
					local tmp_low = sprite_low
					local tmp_high = sprite_high
					local tmp_meta = sprite_meta

					sprite_x = sprite_x_next
					sprite_low = sprite_low_next
					sprite_high = sprite_high_next
					sprite_meta = sprite_meta_next

					sprite_x_next = tmp_x
					sprite_low_next = tmp_low
					sprite_high_next = tmp_high
					sprite_meta_next = tmp_meta

					visible_sprite_count = next_visible_sprite_count
					if sprite_overflow_next then
						ppu_status = bit32.bor(ppu_status, 0x20)
					end
				else
					visible_sprite_count = 0
					next_visible_sprite_count = 0
					sprite_overflow_next = false
				end

				if sprite_scanline_generation == 0xFF then
					buffer.fill(sprite_scanline_data_buf, 0, 0, 1024)
					sprite_scanline_generation = 1
				else
					sprite_scanline_generation += 1
				end

				-- Tag sprite-cache entries by generation so most scanlines avoid a full clear.
				-- Compare the packed generation bits directly to avoid per-pixel shift/mask work.
				sprite_generation_tag = bit32.lshift(sprite_scanline_generation, 16)

				for i = 0, visible_sprite_count - 1 do
					local sx = buffer.readu8(sprite_x, i)
					if sx >= 256 then
						continue
					end

					local meta = buffer.readu8(sprite_meta, i)
					local sp_low = buffer.readu8(sprite_low, i)
					local sp_high = buffer.readu8(sprite_high, i)
					if sp_low == 0 and sp_high == 0 then
						continue
					end

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
			sprite_eval_stage = 0
			sprite_eval_n = 0
			sprite_eval_overflow_m = 0
		end

		if visible_line and cycle <= 256 then
			local px = cycle - 1
			local pixel_offset = px * 4
			local bg = 0
			if show_bg and px >= bg_left_min_px then
				bg = bit32.bor(bit32.lshift(
					bit32.bor( -- palette_bits
						bit32.btest(bg_shift_attr_low, bg_mux) and 1 or 0,
						bit32.btest(bg_shift_attr_high, bg_mux) and 2 or 0
					), 2),

					bit32.bor( -- pixel
						bit32.btest(bg_shift_pat_low, bg_mux) and 1 or 0,
						bit32.btest(bg_shift_pat_high, bg_mux) and 2 or 0
					)
				)
			end

			local is_bg_pixel = bit32.band(bg, 0x03) == 0
			local is_sp_pixel = true

			local sp_color_index = 0
			local sprite_entry = 0

			if show_sp and px >= sp_left_min_px then
				sprite_entry = buffer.readu32(sprite_scanline_data_buf, pixel_offset)
				if bit32.band(sprite_entry, 0x00FF0000) == sprite_generation_tag then
					sp_color_index = bit32.band(sprite_entry, 0xFF)
					is_sp_pixel = bit32.band(sp_color_index, 0x03) == 0
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

			buffer.writeu32(framebuffer, frame_row_start + pixel_offset,
				buffer.readu32(palette_rgba32, (color_index + grayscale_palette_offset) * 4)
			)
		end

		if pre_render_line and cycle == 1 then
			ppu_status = bit32.band(ppu_status, 0x1F)
			nmi_pending_flag = false
		elseif scanline == 241 and cycle == 1 then
			ppu_status = bit32.bor(ppu_status, 0x80)
			if nmi_output then
				nmi_pending_flag = true
			end
		end

		if rendering and (visible_line or pre_render_line) then

			-- Begin the next scanline's sprite-evaluation state machine.
			if cycle == 64 then
				local line_y = if pre_render_line then 0 else scanline + 1

				next_visible_sprite_count = 0
				sprite_overflow_next = false

				sprite_eval_target_scanline = line_y
				sprite_eval_sprite_height = sprite_height
				sprite_eval_pattern_base = sprite_pattern_base
				sprite_eval_stage = 0
				sprite_eval_n = 0
				sprite_eval_overflow_m = 0
				sprite_eval_latch = 0
				sprite_eval_candidate_y = 0
				sprite_eval_candidate_tile = 0
				sprite_eval_candidate_attr = 0

				sprite_eval_active = line_y < 240 and show_sp
			end

			if cycle == 256 then
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

					v = bit32.bor(bit32.band(v, bit32.bnot(0x03E0)), bit32.lshift(coarse_y, 5))
				end
			end

			if cycle == 257 then
				v = bit32.bor(
					bit32.band(v, 0x7BE0),
					bit32.band(t, 0x041F)
				)
			end

			if pre_render_line and cycle >= 280 and cycle <= 304 then
				v = bit32.bor(
					bit32.band(v, 0x041F),
					bit32.band(t, 0x7BE0)
				)
			end

			if sprite_eval_active and cycle >= 65 and cycle <= 256 then
				if sprite_eval_n >= 64 then
					sprite_eval_active = false
				else
					if bit32.btest(cycle, 1) then
						sprite_eval_latch = buffer.readu8(oam, sprite_eval_n * 4 + (sprite_eval_stage == 4 and sprite_eval_overflow_m or sprite_eval_stage))
					elseif sprite_eval_stage == 0 then
						local row = sprite_eval_target_scanline - (sprite_eval_latch + 1)
						if row < 0 or row >= sprite_eval_sprite_height then
							sprite_eval_n += 1
							if sprite_eval_n >= 64 then
								sprite_eval_active = false
							end
						elseif next_visible_sprite_count >= 8 then
							sprite_overflow_next = true
							ppu_status = bit32.bor(ppu_status, 0x20)
							sprite_eval_stage = 4
							sprite_eval_overflow_m = 1
						else
							sprite_eval_candidate_y = sprite_eval_latch
							sprite_eval_stage = 1
						end
					elseif sprite_eval_stage == 1 then
						sprite_eval_candidate_tile = sprite_eval_latch
						sprite_eval_stage = 2
					elseif sprite_eval_stage == 2 then
						sprite_eval_candidate_attr = sprite_eval_latch
						sprite_eval_stage = 3
					elseif sprite_eval_stage == 3 then
						local tile = sprite_eval_candidate_tile
						local attr = sprite_eval_candidate_attr

						local row = sprite_eval_target_scanline - (sprite_eval_candidate_y + 1)

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
						local meta = bit32.lshift(bit32.band(attr, 0x03) + 4, 2)
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

						buffer.writeu8(sprite_x_next, out_index, sprite_eval_latch)
						buffer.writeu16(sprite_pattern_addr_next, out_index * 2, pattern_addr)
						buffer.writeu8(sprite_meta_next, out_index, meta)

						next_visible_sprite_count += 1

						sprite_eval_n += 1
						sprite_eval_stage = 0
						if sprite_eval_n >= 64 then
							sprite_eval_active = false
						end
					else
						-- Overflow bug mode: diagonal scan over primary OAM bytes (n increments with m).
						local row = sprite_eval_target_scanline - (sprite_eval_latch + 1)
						if row >= 0 and row < sprite_eval_sprite_height then
							sprite_overflow_next = true
							ppu_status = bit32.bor(ppu_status, 0x20)
						end

						sprite_eval_n += 1
						sprite_eval_overflow_m = bit32.band(sprite_eval_overflow_m + 1, 0x03)
						if sprite_eval_n >= 64 then
							sprite_eval_active = false
						end
					end
				end
			end

			-- Advance the background fetch pipeline on visible/fetch dots.
			if show_bg and (cycle <= 256 or (cycle >= 321 and cycle <= 336)) then
				bg_shift_pat_low = bit32.band(bg_shift_pat_low * 2, 0xFFFF)
				bg_shift_pat_high = bit32.band(bg_shift_pat_high * 2, 0xFFFF)
				bg_shift_attr_low = bit32.band(bg_shift_attr_low * 2, 0xFFFF)
				bg_shift_attr_high = bit32.band(bg_shift_attr_high * 2, 0xFFFF)

				local phase = bit32.band(cycle, 0x07)

				if phase == 1 then
					bg_nt_byte = ppu_read(bit32.bor(0x2000, bit32.band(v, 0x0FFF)))
				elseif phase == 3 then
					bg_at_byte = ppu_read(
						bit32.bor(
							0x23C0,
							bit32.band(v, 0x0C00),
							bit32.band(bit32.rshift(v, 4), 0x38),
							bit32.band(bit32.rshift(v, 2), 0x07)
						)
					)

					bg_at_byte = bit32.band(bit32.rshift(bg_at_byte, bit32.bor(
						bit32.band(bit32.rshift(v, 4), 0x04),
						bit32.band(v, 0x02)
						)), 0x03
					)

					bg_attr_latch_low = bit32.band(bg_at_byte, 0x01)
					bg_attr_latch_high = bit32.band(bit32.rshift(bg_at_byte, 1), 0x01)
				elseif phase == 5 then
					bg_low_byte = ppu_read(bg_pattern_base + bg_nt_byte * 16 + bit32.band(bit32.rshift(v, 12), 0x07), 1)
				elseif phase == 7 then
					bg_high_byte = ppu_read(bg_pattern_base + bg_nt_byte * 16 + bit32.band(bit32.rshift(v, 12), 0x07) + 8, 1)
				elseif phase == 0 then
					bg_shift_pat_low = bit32.bor(bit32.band(bg_shift_pat_low, 0xFF00), bg_low_byte)
					bg_shift_pat_high = bit32.bor(bit32.band(bg_shift_pat_high, 0xFF00), bg_high_byte)
					bg_shift_attr_low = bit32.bor(bit32.band(bg_shift_attr_low, 0xFF00), bg_attr_latch_low * 0xFF)
					bg_shift_attr_high = bit32.bor(bit32.band(bg_shift_attr_high, 0xFF00), bg_attr_latch_high * 0xFF)

					if bit32.band(v, 0x001F) == 31 then
						v = bit32.band(v, bit32.bnot(0x001F))
						v = bit32.bxor(v, 0x0400)
					else
						v = bit32.band(v + 1, 0x7FFF)
					end
				end
			end

			if cycle == 337 or cycle == 339 then
				ppu_read(bit32.bor(0x2000, bit32.band(v, 0x0FFF)))
			end

			if cycle >= 257 and cycle <= 320 then
				local slot_phase = bit32.band(cycle - 257, 0x07)
				if slot_phase == 4 or slot_phase == 6 then
					local slot = bit32.rshift(cycle - 257, 3)
					local pattern_addr = 0x1FF0
					local has_sprite = slot < next_visible_sprite_count

					if has_sprite or needs_mapper_sprite_fetch then
						if has_sprite then
							pattern_addr = buffer.readu16(sprite_pattern_addr_next_buf, bit32.lshift(slot, 1))
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
							buffer.writeu8(slot_phase == 4 and sprite_low_next_buf or sprite_high_next_buf, slot, value)
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
						mmc3_irq_counter_local = bit32.band(mmc3_irq_counter_local - 1, 0xFF)
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
			scanline = 0
			frame_ready = true
			odd_frame = not odd_frame
			in_ppu_step = false
			continue
		end

		ppu_cycle = cycle
		if ppu_cycle > 340 then
			ppu_cycle = 0
			scanline += 1

			if scanline > 261 then
				scanline = 0
				frame_ready = true
				odd_frame = not odd_frame
			end
		end

		in_ppu_step = false
	end

	if mmc3_inline_a12 then
		mmc3_irq_counter = mmc3_irq_counter_local
		mmc3_irq_reload = mmc3_irq_reload_local
		mmc3_irq_pending = mmc3_irq_pending_local
		mmc3_a12_prev = mmc3_a12_prev_local
		mmc3_a12_low_cycles = mmc3_a12_low_cycles_local
	end
end

local function begin_cpu_event()
	cpu_instruction_active = true
	cpu_bus_cycles = 0
	cpu_pending_cycles = 0
end

local function apply_apu_dma_stalls()
	local stalls = apu_consume_dma_stall_cycles()
	while stalls > 0 do
		cpu_total_cycles += stalls
		run_ppu_cycles(stalls * 3)
		apu_step(stalls)
		stalls = apu_consume_dma_stall_cycles()
	end
end

local function flush_apu_timing()
	if apu_pending_cycles <= 0 then
		apply_apu_dma_stalls()
		apu_sync_mixer()
		return
	end

	local pending = apu_pending_cycles
	apu_pending_cycles = 0
	apu_step(pending)
	apply_apu_dma_stalls()
	apu_sync_mixer()
end

local function flush_cpu_timing(flush_apu: boolean?)
	if cpu_pending_cycles <= 0 then
		if flush_apu == true then
			flush_apu_timing()
		end
		return
	end

	local pending = cpu_pending_cycles
	cpu_pending_cycles = 0
	cpu_total_cycles += pending
	run_ppu_cycles(pending * 3)
	apu_pending_cycles += pending

	if flush_apu == true then
		flush_apu_timing()
	end
end

local function finalize_cpu_event(total_cycles: number)
	local remaining = total_cycles - cpu_bus_cycles
	if remaining < 0 then
		remaining = 0
	end

	if remaining > 0 then
		cpu_pending_cycles += remaining
	end

	flush_cpu_timing(true)
	cpu_bus_cycles = 0
	cpu_pending_cycles = 0
	cpu_instruction_active = false
end

local function register_read(reg: number): number
	if reg == 2 then
		local value = bit32.bor(bit32.band(ppu_status, 0xE0), bit32.band(open_bus, 0x1F))
		ppu_status = bit32.band(ppu_status, 0x7F)
		nmi_pending_flag = false
		w = 0
		return value
	end

	if reg == 4 then
		return buffer.readu8(oam, oam_addr)
	end

	if reg == 7 then
		local value = data_buffer
		data_buffer = ppu_read(v)
		if v >= 0x3F00 then
			value = data_buffer
			data_buffer = ppu_read(v - 0x1000)
		end
		v = bit32.band(v + ctrl_vram_increment, 0x7FFF)
		return value
	end

	return open_bus
end

local function register_write(reg: number, value: number)
	value = bit32.band(value, 0xFF)

	if reg == 0 then
		local old_nmi_output = nmi_output
		set_ctrl(value)
		nmi_output = bit32.btest(ctrl, 0x80)
		if not old_nmi_output and nmi_output and bit32.btest(ppu_status, 0x80) then
			nmi_pending_flag = true
		end
		t = bit32.bor(bit32.band(t, 0x73FF), bit32.lshift(bit32.band(value, 0x03), 10))
	elseif reg == 1 then
		set_mask(value)
	elseif reg == 3 then
		oam_addr = value
	elseif reg == 4 then
		buffer.writeu8(oam, oam_addr, value)
		oam_addr = bit32.band(oam_addr + 1, 0xFF)
	elseif reg == 5 then
		if w == 0 then
			t = bit32.bor(bit32.band(t, 0x7FE0), bit32.rshift(value, 3))
			fine_x = bit32.band(value, 0x07)
			w = 1
		else
			t = bit32.bor(
				bit32.band(t, 0x0C1F),
				bit32.lshift(bit32.band(value, 0x07), 12),
				bit32.lshift(bit32.band(value, 0xF8), 2)
			)
			w = 0
		end
	elseif reg == 6 then
		if w == 0 then
			t = bit32.bor(bit32.band(t, 0x00FF), bit32.lshift(bit32.band(value, 0x3F), 8))
			w = 1
		else
			t = bit32.bor(bit32.band(t, 0x7F00), value)
			v = t
			w = 0
		end
	elseif reg == 7 then
		local addr = v
		if addr >= 0x4000 then
			addr = bit32.band(addr, 0x3FFF)
		end

		-- PPUDATA writes mirror the same decode/A12 side effects as PPU reads.
		if addr < 0x2000 then
			if mapper_is_mmc3 then
				local a12_high = addr >= 0x1000
				if in_ppu_step then
					mmc3_a12_sampled = a12_high
				else
					clock_mmc3_a12_now(a12_high)
				end
			elseif mapper_has_a12_clock then
				if in_ppu_step then
					mmc3_a12_sampled = addr >= 0x1000
				else
					mapper_clock_a12(addr >= 0x1000)
				end
			end

			if chr_is_ram then
				local mapped = mapper_map_chr_addr(addr, 0, ctrl_sprite_8x16)

				if mapped >= 0 and mapped < chr_rom_len then
					buffer.writeu8(chr_rom, mapped, value)
				end
			end
		else
			if addr < 0x3F00 then
				if mapper_is_mmc5 then
					if not mapper_write_nametable(addr, value) then
						buffer.writeu8(vram, buffer.readu16(active_nametable_lut, bit32.band(addr, 0x0FFF) * 2), value)
					end
				elseif not mapper_has_write_nametable or not mapper_write_nametable(addr, value) then
					buffer.writeu8(vram, buffer.readu16(active_nametable_lut, bit32.band(addr, 0x0FFF) * 2), value)
				end
			else
				local index = buffer.readu8(PALETTE_ADDR_LUT, bit32.band(addr, 0x1F))

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
		v = bit32.band(v + ctrl_vram_increment, 0x7FFF)
	end
end

local function inp_read(port)
	if port == 0 or port == 1 then
		local index = buffer.readu8(pad_index, port)

		if index > 7 then
			return 0x41
		end

		local value = bit32.band(bit32.rshift(buffer.readu8(pad_state, port), index), 1)
		if pad_strobe == 0 then
			buffer.writeu8(pad_index, port, index + 1)
		end

		return bit32.bor(value, 0x40)
	end

	return 0x40
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
		if mapper_is_mmc5 and addr <= 0xBFFF then
			apu_on_mmc5_cpu_read(addr, value)
		end
		open_bus = value
		return value
	end

	if addr < 0x4000 then
		flush_cpu_timing(false)
		local value = bit32.band(register_read(bit32.band(addr, 7)), 0xFF)
		open_bus = value
		return value
	end

	if addr == 0x4015 then
		flush_cpu_timing(true)
		local value = bit32.band(apu_read_status(), 0xFF)
		open_bus = value
		return value
	end

	if addr == 0x4016 then
		flush_cpu_timing(false)
		local value = bit32.band(inp_read(0), 0xFF)
		open_bus = value
		return value
	end

	if addr == 0x4017 then
		flush_cpu_timing(false)
		local value = bit32.band(inp_read(1), 0xFF)
		open_bus = value
		return value
	end

	if addr < 0x4020 then
		return open_bus
	end

	if mapper_is_mmc5 and (addr == 0x5010 or addr == 0x5015) then
		flush_cpu_timing(true)
		local value = bit32.band(apu_read_mmc5(addr), 0xFF)
		open_bus = value
		return value
	end

	if addr < 0x6000 then
		flush_cpu_timing(false)
		if mapper_is_mmc5 then
			local mapper_value = mapper_read_cpu(addr)
			if mapper_value then
				local value = bit32.band(mapper_value, 0xFF)
				open_bus = value
				return value
			end
		elseif mapper_has_read_cpu then
			local mapper_value = mapper_read_cpu(addr)
			if mapper_value then
				local value = bit32.band(mapper_value, 0xFF)
				open_bus = value
				return value
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

	return open_bus
end

local function oam_dma(page: number)
	local base = bit32.lshift(page, 8)
	local saved = oam_addr

	in_dma_transfer = true
	for i = 0, 255 do
		local data = bus_read(base + i)
		buffer.writeu8(oam, bit32.band(saved + i, 0xFF), data)
	end
	in_dma_transfer = false

	dma_cycles = 513 + bit32.band(cpu_total_cycles + 1, 0x01)
end

local function bus_write(addr: number, value: number)
	if cpu_instruction_active and not in_dma_transfer then
		cpu_bus_cycles += 1
		cpu_pending_cycles += 1
	end

	if addr >= 0x10000 or addr < 0 then
		addr = bit32.band(addr, 0xFFFF)
	end
	value = bit32.band(value, 0xFF)
	open_bus = value

	if addr < 0x2000 then
		buffer.writeu8(ram, bit32.band(addr, 0x07FF), value)
		return
	end

	if addr < 0x4000 then
		flush_cpu_timing(false)
		register_write(bit32.band(addr, 7), value)
		return
	end

	if addr >= 0x8000 then
		flush_cpu_timing(false)
		if mapper_has_write_cpu then
			mapper_write_cpu(addr, value)
			if mapper_is_mmc3 then
				sync_mmc3_irq_write(addr, value)
			end
			sync_mapper_dynamic_state()
		end
		return
	end

	if addr == 0x4014 then
		flush_cpu_timing(false)
		oam_dma(value)
		return
	end

	if addr == 0x4016 then
		flush_cpu_timing(false)
		pad_strobe = bit32.band(value, 0x01)
		if pad_strobe == 1 then
			buffer.writeu16(pad_index, 0, 0)
		end
		return
	end

	if addr == 0x4017 then
		flush_cpu_timing(true)
		apu_write(addr, value)
		apply_apu_dma_stalls()
		return
	end

	if addr >= 0x4000 and addr <= 0x4015 then
		flush_cpu_timing(true)
		apu_write(addr, value)
		apply_apu_dma_stalls()
		return
	end

	if addr < 0x4020 then
		return
	end

	if addr < 0x6000 then
		if mapper_is_mmc5 and addr >= 0x5000 and addr <= 0x5015 then
			flush_cpu_timing(true)
			apu_write_mmc5(addr, value)
			return
		end
		flush_cpu_timing(false)
		if mapper_has_write_cpu then
			mapper_write_cpu(addr, value)
			sync_mapper_dynamic_state()
		end
		return
	end

	if mapper_has_map_prg_ram_addr then
		local ram_addr = mapper_map_prg_ram_addr(addr)
		if ram_addr then
			if ram_addr < 0 or ram_addr >= prg_ram_len or not mapper_prg_ram_writable_state then
				return
			end
			buffer.writeu8(prg_ram, ram_addr, value)
			return
		end
	end
end

local function read16(addr)
	local lo = bus_read(addr)
	local hi = bus_read(addr + 1)
	return bit32.bor(lo, bit32.lshift(hi, 8))
end

local indexed_dummy_always = buffer.create(256)
local page_cross_penalty = buffer.create(256)
local opcode_execute = table.create(256)
local zn_flag_lut = table.create(256)

for i = 0, 255 do
	local zn = bit32.band(i, 0x80)
	if i == 0 then
		zn = bit32.bor(zn, 0x02)
	end
	zn_flag_lut[i] = zn
end

local function opcodes_init()
	local zn_lut = zn_flag_lut

	local function set_zn(value)
		value = bit32.band(value, 0xFF)
		status = bit32.bor(bit32.band(status, 0x7D), zn_lut[value])
		return value
	end

	local function imp() end
	local function acc() end

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
		addr_value = bit32.band(bus_read(pc) + x, 0xFF)
		pc += 1
		if pc == 0x10000 then
			pc = 0
		end
	end

	local function zpy()
		addr_value = bit32.band(bus_read(pc) + y, 0xFF)
		pc += 1
		if pc == 0x10000 then
			pc = 0
		end
	end

	local function abs()
		local lo = bus_read(pc)
		local hi = bus_read(pc + 1)
		addr_value = bit32.bor(lo, bit32.lshift(hi, 8))
		pc += 2
		if pc >= 0x10000 then
			pc -= 0x10000
		end
	end

	local function abx()
		local lo = bus_read(pc)
		local hi = bus_read(pc + 1)
		local base = bit32.bor(lo, bit32.lshift(hi, 8))
		local low_sum = bit32.band(base, 0xFF) + x
		addr_value = bit32.band(base + x, 0xFFFF)
		page_crossed = low_sum > 0xFF
		indexed_dummy_addr = bit32.bor(bit32.band(base, 0xFF00), bit32.band(low_sum, 0x00FF))
		pc += 2
		if pc >= 0x10000 then
			pc -= 0x10000
		end
	end

	local function aby()
		local lo = bus_read(pc)
		local hi = bus_read(pc + 1)
		local base = bit32.bor(lo, bit32.lshift(hi, 8))
		local low_sum = bit32.band(base, 0xFF) + y
		addr_value = bit32.band(base + y, 0xFFFF)
		page_crossed = low_sum > 0xFF
		indexed_dummy_addr = bit32.bor(bit32.band(base, 0xFF00), bit32.band(low_sum, 0x00FF))
		pc += 2
		if pc >= 0x10000 then
			pc -= 0x10000
		end
	end

	local function ind()
		local ptr_lo = bus_read(pc)
		local ptr_hi = bus_read(pc + 1)
		local ptr = bit32.bor(ptr_lo, bit32.lshift(ptr_hi, 8))

		local lo = bus_read(ptr)
		local hi = bus_read(bit32.bor(bit32.band(ptr, 0xFF00), bit32.band(ptr + 1, 0x00FF)))
		addr_value = bit32.bor(lo, bit32.lshift(hi, 8))
		pc += 2
		if pc >= 0x10000 then
			pc -= 0x10000
		end
	end

	local function izx()
		local base = bit32.band(bus_read(pc) + x, 0xFF)
		local lo = bus_read(base)
		local hi = bus_read(bit32.band(base + 1, 0xFF))
		addr_value = bit32.bor(lo, bit32.lshift(hi, 8))
		pc += 1
		if pc == 0x10000 then
			pc = 0
		end
	end

	local function izy()
		local base = bus_read(pc)
		local lo = bus_read(base)
		local hi = bus_read(bit32.band(base + 1, 0xFF))
		local addr = bit32.bor(lo, bit32.lshift(hi, 8))
		local low_sum = bit32.band(addr, 0xFF) + y
		addr_value = bit32.band(addr + y, 0xFFFF)
		page_crossed = low_sum > 0xFF
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
		if offset >= 128 then
			offset = offset - 256
		end
		addr_value = bit32.band(pc + offset, 0xFFFF)
	end

	local function write_op_rmw(old_value: number, new_value: number)
		bus_write(addr_value, bit32.band(old_value, 0xFF))
		bus_write(addr_value, bit32.band(new_value, 0xFF))
	end

	local function adc()
		local m = bus_read(addr_value)
		local c = bit32.btest(status, 1) and 1 or 0
		local sum = a + m + c
		if sum > 255 then
			status = bit32.bor(status, 0x01)
		else
			status = bit32.band(status, 0xFE)
		end
		if bit32.btest(bit32.band(bit32.bxor(a, sum), bit32.bxor(m, sum), 0x80), 0x80) then
			status = bit32.bor(status, 0x40)
		else
			status = bit32.band(status, 0xBF)
		end
		a = set_zn(bit32.band(sum, 0xFF))
	end

	local function op_and()
		a = set_zn(bit32.band(a, bus_read(addr_value)))
	end

	local function asl_a()
		status = bit32.bor(bit32.band(status, 0xFE), bit32.band(bit32.rshift(a, 7), 0x01))
		a = set_zn(bit32.band(bit32.lshift(a, 1), 0xFF))
	end

	local function asl()
		local m = bus_read(addr_value)
		status = bit32.bor(bit32.band(status, 0xFE), bit32.band(bit32.rshift(m, 7), 0x01))
		local result = set_zn(bit32.band(bit32.lshift(m, 1), 0xFF))
		write_op_rmw(m, result)
	end

	-- Branch opcodes stay separate here to avoid an extra closure/helper call in a hot path.
	local function bpl()
		if not bit32.btest(status, 0x80) then
			bus_read(pc)
			cycles = cycles + 1
			if bit32.band(pc, 0xFF00) ~= bit32.band(addr_value, 0xFF00) then
				bus_read(bit32.bor(bit32.band(pc, 0xFF00), bit32.band(addr_value, 0x00FF)))
				cycles = cycles + 1
			end
			pc = addr_value
		end
	end

	local function bmi()
		if bit32.btest(status, 0x80) then
			bus_read(pc)
			cycles = cycles + 1
			if bit32.band(pc, 0xFF00) ~= bit32.band(addr_value, 0xFF00) then
				bus_read(bit32.bor(bit32.band(pc, 0xFF00), bit32.band(addr_value, 0x00FF)))
				cycles = cycles + 1
			end
			pc = addr_value
		end
	end

	local function bvc()
		if not bit32.btest(status, 0x40) then
			bus_read(pc)
			cycles = cycles + 1
			if bit32.band(pc, 0xFF00) ~= bit32.band(addr_value, 0xFF00) then
				bus_read(bit32.bor(bit32.band(pc, 0xFF00), bit32.band(addr_value, 0x00FF)))
				cycles = cycles + 1
			end
			pc = addr_value
		end
	end

	local function bvs()
		if bit32.btest(status, 0x40) then
			bus_read(pc)
			cycles = cycles + 1
			if bit32.band(pc, 0xFF00) ~= bit32.band(addr_value, 0xFF00) then
				bus_read(bit32.bor(bit32.band(pc, 0xFF00), bit32.band(addr_value, 0x00FF)))
				cycles = cycles + 1
			end
			pc = addr_value
		end
	end

	local function bcc()
		if not bit32.btest(status, 0x01) then
			bus_read(pc)
			cycles = cycles + 1
			if bit32.band(pc, 0xFF00) ~= bit32.band(addr_value, 0xFF00) then
				bus_read(bit32.bor(bit32.band(pc, 0xFF00), bit32.band(addr_value, 0x00FF)))
				cycles = cycles + 1
			end
			pc = addr_value
		end
	end

	local function bcs()
		if bit32.btest(status, 0x01) then
			bus_read(pc)
			cycles = cycles + 1
			if bit32.band(pc, 0xFF00) ~= bit32.band(addr_value, 0xFF00) then
				bus_read(bit32.bor(bit32.band(pc, 0xFF00), bit32.band(addr_value, 0x00FF)))
				cycles = cycles + 1
			end
			pc = addr_value
		end
	end

	local function bne()
		if not bit32.btest(status, 0x02) then
			bus_read(pc)
			cycles = cycles + 1
			if bit32.band(pc, 0xFF00) ~= bit32.band(addr_value, 0xFF00) then
				bus_read(bit32.bor(bit32.band(pc, 0xFF00), bit32.band(addr_value, 0x00FF)))
				cycles = cycles + 1
			end
			pc = addr_value
		end
	end

	local function beq()
		if bit32.btest(status, 0x02) then
			bus_read(pc)
			cycles = cycles + 1
			if bit32.band(pc, 0xFF00) ~= bit32.band(addr_value, 0xFF00) then
				bus_read(bit32.bor(bit32.band(pc, 0xFF00), bit32.band(addr_value, 0x00FF)))
				cycles = cycles + 1
			end
			pc = addr_value
		end
	end

	local function op_bit()
		local m = bus_read(addr_value)
		local znv = bit32.band(m, 0xC0)
		if bit32.band(a, m) == 0 then
			znv = bit32.bor(znv, 0x02)
		end
		status = bit32.bor(bit32.band(status, 0x3D), znv)
	end

	local function brk()
		pc = bit32.band(pc + 1, 0xFFFF)

		bus_write(0x0100 + sp, bit32.rshift(pc, 8))
		sp = bit32.band(sp - 1, 0xFF)

		bus_write(0x0100 + sp, bit32.band(pc, 0xFF))
		sp = bit32.band(sp - 1, 0xFF)

		bus_write(0x0100 + sp, bit32.bor(status, 16, 32))
		sp = bit32.band(sp - 1, 0xFF)

		status = bit32.bor(status, 0x04)
		pc = read16(0xFFFE)
	end

	local function cmp()
		local m = bus_read(addr_value)
		status = bit32.bor(bit32.band(status, 0xFE), if a >= m then 1 else 0)
		set_zn(bit32.band(a - m, 0xFF))
	end

	local function cpx()
		local m = bus_read(addr_value)
		status = bit32.bor(bit32.band(status, 0xFE), if x >= m then 1 else 0)
		set_zn(bit32.band(x - m, 0xFF))
	end

	local function cpy()
		local m = bus_read(addr_value)
		status = bit32.bor(bit32.band(status, 0xFE), if y >= m then 1 else 0)
		set_zn(bit32.band(y - m, 0xFF))
	end

	local function dec()
		local m = bus_read(addr_value)
		local result = set_zn(bit32.band(m - 1, 0xFF))
		write_op_rmw(m, result)
	end

	local function dex()
		x = set_zn(bit32.band(x - 1, 0xFF))
	end

	local function dey()
		y = set_zn(bit32.band(y - 1, 0xFF))
	end

	local function eor()
		a = set_zn(bit32.bxor(a, bus_read(addr_value)))
	end

	local function inc()
		local m = bus_read(addr_value)
		local result = set_zn(bit32.band(m + 1, 0xFF))
		write_op_rmw(m, result)
	end

	local function inx()
		x = set_zn(bit32.band(x + 1, 0xFF))
	end

	local function iny()
		y = set_zn(bit32.band(y + 1, 0xFF))
	end

	local function jmp()
		pc = addr_value
	end

	local function jsr()
		local value = bit32.band(pc - 1, 0xFFFF)

		bus_write(0x0100 + sp, bit32.rshift(value, 8))
		sp = bit32.band(sp - 1, 0xFF)

		bus_write(0x0100 + sp, bit32.band(value, 0xFF))
		sp = bit32.band(sp - 1, 0xFF)

		pc = addr_value
	end

	local function lda()
		a = set_zn(bus_read(addr_value))
	end

	local function ldx()
		x = set_zn(bus_read(addr_value))
	end

	local function ldy()
		y = set_zn(bus_read(addr_value))
	end

	local function lsr_a()
		status = bit32.bor(bit32.band(status, 0xFE), bit32.band(a, 0x01))
		a = set_zn(bit32.rshift(a, 1))
	end

	local function lsr()
		local m = bus_read(addr_value)
		status = bit32.bor(bit32.band(status, 0xFE), bit32.band(m, 0x01))
		local result = set_zn(bit32.rshift(m, 1))
		write_op_rmw(m, result)
	end

	local function ora()
		a = set_zn(bit32.bor(a, bus_read(addr_value)))
	end

	local function pha()
		bus_write(0x0100 + sp, a)
		sp = bit32.band(sp - 1, 0xFF)
	end

	local function php()
		bus_write(0x0100 + sp, bit32.bor(status, 16, 32))
		sp = bit32.band(sp - 1, 0xFF)
	end

	local function pla()
		sp = bit32.band(sp + 1, 0xFF)
		a = set_zn(bus_read(0x0100 + sp))
	end

	local function plp()
		sp = bit32.band(sp + 1, 0xFF)
		status = bit32.bor(bit32.band(bus_read(0x0100 + sp), 0xEF), 32)
	end

	local function rol_a()
		local c = bit32.btest(status, 1) and 1 or 0
		status = bit32.bor(bit32.band(status, 0xFE), bit32.band(bit32.rshift(a, 7), 0x01))
		a = set_zn(bit32.band(bit32.bor(bit32.lshift(a, 1), c), 0xFF))
	end

	local function rol()
		local m = bus_read(addr_value)
		local c = bit32.btest(status, 1) and 1 or 0
		status = bit32.bor(bit32.band(status, 0xFE), bit32.band(bit32.rshift(m, 7), 0x01))
		local result = set_zn(bit32.band(bit32.bor(bit32.lshift(m, 1), c), 0xFF))
		write_op_rmw(m, result)
	end

	local function ror_a()
		local c = bit32.btest(status, 1) and 0x80 or 0
		status = bit32.bor(bit32.band(status, 0xFE), bit32.band(a, 0x01))
		a = set_zn(bit32.bor(bit32.rshift(a, 1), c))
	end

	local function ror()
		local m = bus_read(addr_value)
		local c = bit32.btest(status, 1) and 0x80 or 0
		status = bit32.bor(bit32.band(status, 0xFE), bit32.band(m, 0x01))
		local result = set_zn(bit32.bor(bit32.rshift(m, 1), c))
		write_op_rmw(m, result)
	end

	local function rti()
		sp = bit32.band(sp + 1, 0xFF)
		status = bit32.bor(bit32.band(bus_read(0x0100 + sp), 0xEF), 32)
		sp = bit32.band(sp + 1, 0xFF)
		local pulled = bus_read(0x0100 + sp)
		sp = bit32.band(sp + 1, 0xFF)
		pc = bit32.bor(pulled, bit32.lshift(bus_read(0x0100 + sp), 8))
	end

	local function rts()
		sp = bit32.band(sp + 1, 0xFF)
		local pulled = bus_read(0x0100 + sp)
		sp = bit32.band(sp + 1, 0xFF)
		pc = bit32.band(bit32.bor(pulled, bit32.lshift(bus_read(0x0100 + sp), 8)) + 1, 0xFFFF)
	end

	local function sbc()
		local m = bus_read(addr_value)
		local c = bit32.btest(status, 1) and 0 or 1
		local diff = a - m - c
		if diff >= 0 then
			status = bit32.bor(status, 0x01)
		else
			status = bit32.band(status, 0xFE)
		end
		if bit32.btest(bit32.band(bit32.bxor(a, diff), bit32.bxor(a, m), 0x80), 0x80) then
			status = bit32.bor(status, 0x40)
		else
			status = bit32.band(status, 0xBF)
		end
		a = set_zn(bit32.band(diff, 0xFF))
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
		x = set_zn(a)
	end

	local function tay()
		y = set_zn(a)
	end

	local function tsx()
		x = set_zn(sp)
	end

	local function txa()
		a = set_zn(x)
	end

	local function txs()
		sp = x
	end

	local function tya()
		a = set_zn(y)
	end

	local function op_lax()
		local m = bus_read(addr_value)
		a = set_zn(m)
		x = a
	end

	local function op_sax()
		bus_write(addr_value, bit32.band(a, x))
	end

	local function op_dcp()
		local old_m = bus_read(addr_value)
		local m = bit32.band(old_m - 1, 0xFF)
		write_op_rmw(old_m, m)
		status = bit32.bor(bit32.band(status, 0xFE), if a >= m then 1 else 0)
		set_zn(bit32.band(a - m, 0xFF))
	end

	local function op_isc()
		local old_m = bus_read(addr_value)
		local m = bit32.band(old_m + 1, 0xFF)
		write_op_rmw(old_m, m)
		-- Inline the SBC half here so this unofficial op avoids another helper call.
		local c = bit32.btest(status, 1) and 0 or 1
		local diff = a - m - c
		if diff >= 0 then
			status = bit32.bor(status, 0x01)
		else
			status = bit32.band(status, 0xFE)
		end
		if bit32.btest(bit32.band(bit32.bxor(a, diff), bit32.bxor(a, m), 0x80), 0x80) then
			status = bit32.bor(status, 0x40)
		else
			status = bit32.band(status, 0xBF)
		end
		a = set_zn(bit32.band(diff, 0xFF))
	end

	local function op_rla()
		local old_m = bus_read(addr_value)
		local c = bit32.btest(status, 1) and 1 or 0
		status = bit32.bor(bit32.band(status, 0xFE), bit32.band(bit32.rshift(old_m, 7), 0x01))
		local m = bit32.band(bit32.bor(bit32.lshift(old_m, 1), c), 0xFF)
		write_op_rmw(old_m, m)
		a = set_zn(bit32.band(a, m))
	end

	local function op_rra()
		local old_m = bus_read(addr_value)
		local c = bit32.btest(status, 1) and 0x80 or 0
		status = bit32.bor(bit32.band(status, 0xFE), bit32.band(old_m, 0x01))
		local m = bit32.band(bit32.bor(bit32.rshift(old_m, 1), c), 0xFF)
		write_op_rmw(old_m, m)
		local carry = bit32.btest(status, 1) and 1 or 0
		local sum = a + m + carry
		if sum > 255 then
			status = bit32.bor(status, 0x01)
		else
			status = bit32.band(status, 0xFE)
		end
		if bit32.btest(bit32.band(bit32.bxor(a, sum), bit32.bxor(m, sum), 0x80), 0x80) then
			status = bit32.bor(status, 0x40)
		else
			status = bit32.band(status, 0xBF)
		end
		a = set_zn(bit32.band(sum, 0xFF))
	end

	local function op_slo()
		local old_m = bus_read(addr_value)
		status = bit32.bor(bit32.band(status, 0xFE), bit32.band(bit32.rshift(old_m, 7), 0x01))
		local m = bit32.band(bit32.lshift(old_m, 1), 0xFF)
		write_op_rmw(old_m, m)
		a = set_zn(bit32.bor(a, m))
	end

	local function op_sre()
		local old_m = bus_read(addr_value)
		status = bit32.bor(bit32.band(status, 0xFE), bit32.band(old_m, 0x01))
		local m = bit32.rshift(old_m, 1)
		write_op_rmw(old_m, m)
		a = set_zn(bit32.bxor(a, m))
	end

	local function op_anc()
		a = set_zn(bit32.band(a, bus_read(addr_value)))
		status = bit32.bor(bit32.band(status, 0xFE), bit32.band(bit32.rshift(a, 7), 0x01))
	end

	local function op_alr()
		a = bit32.band(a, bus_read(addr_value))
		status = bit32.bor(bit32.band(status, 0xFE), bit32.band(a, 0x01))
		a = set_zn(bit32.rshift(a, 1))
	end

	local function op_arr()
		a = bit32.band(a, bus_read(addr_value))
		a = bit32.band(bit32.bor(bit32.rshift(a, 1), (bit32.btest(status, 1) and 0x80 or 0)), 0xFF)
		a = set_zn(a)
		local cv = bit32.band(bit32.rshift(a, 6), 0x01)
		local b5 = bit32.band(bit32.rshift(a, 5), 0x01)
		local b6 = bit32.band(bit32.rshift(a, 6), 0x01)
		if b5 ~= b6 then
			cv = bit32.bor(cv, 0x40)
		end
		status = bit32.bor(bit32.band(status, 0xBE), cv)
	end

	local function op_sbx()
		local t = bit32.band(a, x) - bus_read(addr_value)
		status = bit32.bor(bit32.band(status, 0xFE), if t >= 0 then 1 else 0)
		x = set_zn(bit32.band(t, 0xFF))
	end

	local function clc()
		status = bit32.band(status, 0xFE)
	end

	local function sec()
		status = bit32.bor(status, 0x01)
	end

	local function cli()
		status = bit32.band(status, 0xFB)
	end

	local function sei()
		status = bit32.bor(status, 0x04)
	end

	local function clv()
		status = bit32.band(status, 0xBF)
	end

	local function cld()
		status = bit32.band(status, 0xF7)
	end

	local function sed()
		status = bit32.bor(status, 0x08)
	end

	local function op_las()
		local m = bit32.band(bus_read(addr_value), sp)
		a = m
		x = m
		sp = m
		set_zn(m)
	end

	local function op_xaa()
		a = set_zn(bit32.band(bit32.bor(a, 0xEE), x, bus_read(addr_value)))
	end

	local function op_lxa()
		local v = bus_read(addr_value)
		a = set_zn(v)
		x = a
	end

	local function op_ahx()
		bus_write(addr_value, bit32.band(a, x, bit32.band(bit32.rshift(addr_value, 8) + 1, 0xFF)))
	end

	local function op_tas()
		sp = bit32.band(a, x)
		local high_plus_one = bit32.band(bit32.rshift(addr_value, 8) + 1, 0xFF)
		bus_write(addr_value, bit32.band(sp, high_plus_one))
	end

	local function op_shy()
		local value = bit32.band(y, bit32.band(bit32.rshift(addr_value, 8) + 1, 0xFF))
		addr_value = bit32.bor(bit32.lshift(value, 8), bit32.band(addr_value, 0xFF))
		bus_write(addr_value, value)
	end

	local function op_shx()
		local high_plus_one = bit32.band(bit32.rshift(addr_value, 8) + 1, 0xFF)
		local value = bit32.band(x, high_plus_one)
		addr_value = bit32.bor(bit32.lshift(value, 8), bit32.band(addr_value, 0xFF))
		bus_write(addr_value, value)
	end

	local function op_jam()
		pc = bit32.band(pc - 1, 0xFFFF)
		cpu_jammed = true
	end

	local function op_nop_read()
		bus_read(addr_value)
	end

	local function ill()
	end

	local opcodes = {
		[0x00] = {brk, imp, 7}, [0x01] = {ora, izx, 6}, [0x05] = {ora, zp, 3},
		[0x06] = {asl, zp, 5}, [0x08] = {php, imp, 3}, [0x09] = {ora, imm, 2},
		[0x0A] = {asl_a, acc, 2}, [0x0D] = {ora, abs, 4}, [0x0E] = {asl, abs, 6},
		[0x10] = {bpl, rel, 2}, [0x11] = {ora, izy, 5}, [0x15] = {ora, zpx, 4},
		[0x16] = {asl, zpx, 6}, [0x18] = {clc, imp, 2}, [0x19] = {ora, aby, 4},
		[0x1D] = {ora, abx, 4}, [0x1E] = {asl, abx, 7},
		[0x20] = {jsr, abs, 6}, [0x21] = {op_and, izx, 6}, [0x24] = {op_bit, zp, 3},
		[0x25] = {op_and, zp, 3}, [0x26] = {rol, zp, 5}, [0x28] = {plp, imp, 4},
		[0x29] = {op_and, imm, 2}, [0x2A] = {rol_a, acc, 2}, [0x2C] = {op_bit, abs, 4},
		[0x2D] = {op_and, abs, 4}, [0x2E] = {rol, abs, 6},
		[0x30] = {bmi, rel, 2}, [0x31] = {op_and, izy, 5}, [0x35] = {op_and, zpx, 4},
		[0x36] = {rol, zpx, 6}, [0x38] = {sec, imp, 2}, [0x39] = {op_and, aby, 4},
		[0x3D] = {op_and, abx, 4}, [0x3E] = {rol, abx, 7},
		[0x40] = {rti, imp, 6}, [0x41] = {eor, izx, 6}, [0x45] = {eor, zp, 3},
		[0x46] = {lsr, zp, 5}, [0x48] = {pha, imp, 3}, [0x49] = {eor, imm, 2},
		[0x4A] = {lsr_a, acc, 2}, [0x4C] = {jmp, abs, 3}, [0x4D] = {eor, abs, 4},
		[0x4E] = {lsr, abs, 6},
		[0x50] = {bvc, rel, 2}, [0x51] = {eor, izy, 5}, [0x55] = {eor, zpx, 4},
		[0x56] = {lsr, zpx, 6}, [0x58] = {cli, imp, 2}, [0x59] = {eor, aby, 4},
		[0x5D] = {eor, abx, 4}, [0x5E] = {lsr, abx, 7},
		[0x60] = {rts, imp, 6}, [0x61] = {adc, izx, 6}, [0x65] = {adc, zp, 3},
		[0x66] = {ror, zp, 5}, [0x68] = {pla, imp, 4}, [0x69] = {adc, imm, 2},
		[0x6A] = {ror_a, acc, 2}, [0x6C] = {jmp, ind, 5}, [0x6D] = {adc, abs, 4},
		[0x6E] = {ror, abs, 6},
		[0x70] = {bvs, rel, 2}, [0x71] = {adc, izy, 5}, [0x75] = {adc, zpx, 4},
		[0x76] = {ror, zpx, 6}, [0x78] = {sei, imp, 2}, [0x79] = {adc, aby, 4},
		[0x7D] = {adc, abx, 4}, [0x7E] = {ror, abx, 7},
		[0x81] = {sta, izx, 6}, [0x84] = {sty, zp, 3}, [0x85] = {sta, zp, 3},
		[0x86] = {stx, zp, 3}, [0x88] = {dey, imp, 2}, [0x8A] = {txa, imp, 2},
		[0x8C] = {sty, abs, 4}, [0x8D] = {sta, abs, 4}, [0x8E] = {stx, abs, 4},
		[0x90] = {bcc, rel, 2}, [0x91] = {sta, izy, 6}, [0x94] = {sty, zpx, 4},
		[0x95] = {sta, zpx, 4}, [0x96] = {stx, zpy, 4}, [0x98] = {tya, imp, 2},
		[0x99] = {sta, aby, 5}, [0x9A] = {txs, imp, 2}, [0x9D] = {sta, abx, 5},
		[0xA0] = {ldy, imm, 2}, [0xA1] = {lda, izx, 6}, [0xA2] = {ldx, imm, 2},
		[0xA4] = {ldy, zp, 3}, [0xA5] = {lda, zp, 3}, [0xA6] = {ldx, zp, 3},
		[0xA8] = {tay, imp, 2}, [0xA9] = {lda, imm, 2}, [0xAA] = {tax, imp, 2},
		[0xAC] = {ldy, abs, 4}, [0xAD] = {lda, abs, 4}, [0xAE] = {ldx, abs, 4},
		[0xB0] = {bcs, rel, 2}, [0xB1] = {lda, izy, 5}, [0xB4] = {ldy, zpx, 4},
		[0xB5] = {lda, zpx, 4}, [0xB6] = {ldx, zpy, 4}, [0xB8] = {clv, imp, 2},
		[0xB9] = {lda, aby, 4}, [0xBA] = {tsx, imp, 2}, [0xBC] = {ldy, abx, 4},
		[0xBD] = {lda, abx, 4}, [0xBE] = {ldx, aby, 4},
		[0xC0] = {cpy, imm, 2}, [0xC1] = {cmp, izx, 6}, [0xC4] = {cpy, zp, 3},
		[0xC5] = {cmp, zp, 3}, [0xC6] = {dec, zp, 5}, [0xC8] = {iny, imp, 2},
		[0xC9] = {cmp, imm, 2}, [0xCA] = {dex, imp, 2}, [0xCC] = {cpy, abs, 4},
		[0xCD] = {cmp, abs, 4}, [0xCE] = {dec, abs, 6},
		[0xD0] = {bne, rel, 2}, [0xD1] = {cmp, izy, 5}, [0xD5] = {cmp, zpx, 4},
		[0xD6] = {dec, zpx, 6}, [0xD8] = {cld, imp, 2}, [0xD9] = {cmp, aby, 4},
		[0xDD] = {cmp, abx, 4}, [0xDE] = {dec, abx, 7},
		[0xE0] = {cpx, imm, 2}, [0xE1] = {sbc, izx, 6}, [0xE4] = {cpx, zp, 3},
		[0xE5] = {sbc, zp, 3}, [0xE6] = {inc, zp, 5}, [0xE8] = {inx, imp, 2},
		[0xE9] = {sbc, imm, 2}, [0xEA] = {imp, imp, 2}, [0xEC] = {cpx, abs, 4},
		[0xED] = {sbc, abs, 4}, [0xEE] = {inc, abs, 6},
		[0xF0] = {beq, rel, 2}, [0xF1] = {sbc, izy, 5}, [0xF5] = {sbc, zpx, 4},
		[0xF6] = {inc, zpx, 6}, [0xF8] = {sed, imp, 2}, [0xF9] = {sbc, aby, 4},
		[0xFD] = {sbc, abx, 4}, [0xFE] = {inc, abx, 7}
	}

	-- Unofficial opcodes commonly used by test ROMs and some games.
	opcodes[0x03] = {op_slo, izx, 8}
	opcodes[0x07] = {op_slo, zp, 5}
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
	opcodes[0xFF] = {op_isc, abx, 7}

	opcodes[0x0B] = {op_anc, imm, 2}
	opcodes[0x2B] = {op_anc, imm, 2}
	opcodes[0x4B] = {op_alr, imm, 2}
	opcodes[0x6B] = {op_arr, imm, 2}
	opcodes[0x8B] = {op_xaa, imm, 2}
	opcodes[0xAB] = {op_lxa, imm, 2}
	opcodes[0xCB] = {op_sbx, imm, 2}
	opcodes[0xBB] = {op_las, aby, 4}
	opcodes[0x93] = {op_ahx, izy, 6}
	opcodes[0x9B] = {op_tas, aby, 5}
	opcodes[0x9C] = {op_shy, abx, 5}
	opcodes[0x9E] = {op_shx, aby, 5}
	opcodes[0x9F] = {op_ahx, aby, 5}

	for _, jam_opcode in {0x02, 0x12, 0x22, 0x32, 0x42, 0x52, 0x62, 0x72, 0x92, 0xB2, 0xD2, 0xF2} do
		opcodes[jam_opcode] = {op_jam, imp, 2}
	end

	opcodes[0x1A] = {imp, imp, 2}
	opcodes[0x3A] = {imp, imp, 2}
	opcodes[0x5A] = {imp, imp, 2}
	opcodes[0x7A] = {imp, imp, 2}
	opcodes[0xDA] = {imp, imp, 2}
	opcodes[0xFA] = {imp, imp, 2}

	opcodes[0x80] = {op_nop_read, imm, 2}
	opcodes[0x82] = {op_nop_read, imm, 2}
	opcodes[0x89] = {op_nop_read, imm, 2}
	opcodes[0xC2] = {op_nop_read, imm, 2}
	opcodes[0xE2] = {op_nop_read, imm, 2}
	opcodes[0x04] = {op_nop_read, zp, 3}
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

	for i = 0, 255 do
		if not opcodes[i] then
			opcodes[i] = {ill, imp, 2}
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
		0xF3, 0xFB, 0xFF
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
				opcode_execute[opcode] = function()
					cycles = base_cycles

					addr_exec()
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

					op_exec()
				end
			end
		elseif has_page_cross_penalty then
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
		else
			opcode_execute[opcode] = function()
				cycles = base_cycles

				addr_exec()
				op_exec()
			end
		end
	end
end

opcodes_init()

local function reset()
	sp = 0xFD
	status = bit32.bor(bit32.band(status, 0xCF), 0x24)
	status = bit32.bor(status, 0x04)
	cpu_total_cycles = 0
	dma_cycles = 0
	nmi_pending_flag = false
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
	set_ctrl(0)
	set_mask(0)
	nmi_output = false
	open_bus = 0
	v = 0
	t = 0
	w = 0
	fine_x = 0
	oam_addr = 0
	buffer.fill(pad_index, 0, 0, 2)
	sprite_scanline_generation = 1
	buffer.fill(sprite_scanline_data, 0, 0, 1024)
	buffer.fill(sprite_x, 0, 0, 8)
	buffer.fill(sprite_low, 0, 0, 8)
	buffer.fill(sprite_high, 0, 0, 8)
	buffer.fill(sprite_meta, 0, 0, 8)
	buffer.fill(sprite_x_next, 0, 0, 8)
	buffer.fill(sprite_low_next, 0, 0, 8)
	buffer.fill(sprite_high_next, 0, 0, 8)
	buffer.fill(sprite_meta_next, 0, 0, 8)
	reset_bg_pipeline()

	if mapper then
		mapper.reset()
		sync_mapper_dynamic_state()
	end

	apu_reset()
	apu_set_mmc5_enabled(mapper_is_mmc5)
	pc = read16(0xFFFC)
end

local function nmi(): number
	bus_write(0x0100 + sp, bit32.rshift(pc, 8))
	sp = bit32.band(sp - 1, 0xFF)

	bus_write(0x0100 + sp, bit32.band(pc, 0xFF))
	sp = bit32.band(sp - 1, 0xFF)

	bus_write(0x0100 + sp, bit32.bor(bit32.band(status, 0xEF), 0x20))
	sp = bit32.band(sp - 1, 0xFF)

	status = bit32.bor(status, 0x04)
	pc = read16(0xFFFA)
	return 7
end

local function irq(): number
	bus_write(0x0100 + sp, bit32.rshift(pc, 8))
	sp = bit32.band(sp - 1, 0xFF)

	bus_write(0x0100 + sp, bit32.band(pc, 0xFF))
	sp = bit32.band(sp - 1, 0xFF)

	bus_write(0x0100 + sp, bit32.bor(bit32.band(status, 0xEF), 0x20))
	sp = bit32.band(sp - 1, 0xFF)

	status = bit32.bor(status, 0x04)
	pc = read16(0xFFFE)
	return 7
end

local function step()
	begin_cpu_event()
	if cpu_jammed then
		cycles = 2
		finalize_cpu_event(cycles)
		return cycles
	end

	local opcode = bus_read(pc)
	pc += 1
	if pc == 0x10000 then
		pc = 0
	end
	opcode_execute[opcode]()

	cycles += dma_cycles
	dma_cycles = 0

	finalize_cpu_event(cycles)

	return cycles
end

local function load(data: string)
	local rom = buffer.fromstring(data)
	local rom_len = buffer.len(rom)

	assert(rom_len >= 16, "Invalid iNES ROM: header too short")

	local h1 = buffer.readu8(rom, 0)
	local h2 = buffer.readu8(rom, 1)
	local h3 = buffer.readu8(rom, 2)
	local h4 = buffer.readu8(rom, 3)

	assert(h1 == 0x4E and h2 == 0x45 and h3 == 0x53 and h4 == 0x1A, "Invalid iNES header")

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

	local is_ines2 = bit32.band(flags7, 0x0C) == 0x08
	local submapper: number? = nil

	local mapper_lower_nibble = bit32.rshift(bit32.band(flags6, 0xF0), 4)
	local mapper_upper_nibble = bit32.band(flags7, 0xF0)
	local mapper_number = bit32.bor(
		mapper_lower_nibble,
		mapper_upper_nibble
	)
	if (not is_ines2) and (not header_padding_is_zero) then
		-- Archaic/dirty iNES headers often store tag data in bytes 7-15 ("DiskDude!" style).
		-- In that case, ignore flags7 upper nibble for mapper selection.
		mapper_number = mapper_lower_nibble
	end
	if is_ines2 then
		mapper_number = bit32.bor(mapper_number, bit32.lshift(bit32.band(flags8, 0x0F), 8))
		submapper = bit32.rshift(flags8, 4)
	end

	if is_ines2 then
		local prg_msb = bit32.band(flags9, 0x0F)
		local chr_msb = bit32.band(bit32.rshift(flags9, 4), 0x0F)

		-- Exponent/multiplier encoding exists in NES2 but is uncommon; keep parser strict.
		assert(prg_msb ~= 0x0F, "NES2 PRG exponent size encoding is not supported")
		assert(chr_msb ~= 0x0F, "NES2 CHR exponent size encoding is not supported")

		prg_banks = bit32.bor(prg_banks, bit32.lshift(prg_msb, 8))
		chr_banks = bit32.bor(chr_banks, bit32.lshift(chr_msb, 8))
	end

	local mapper_id = mapper_number
	mapper_is_mmc3 = mapper_id == 4
	mapper_is_mmc5 = mapper_id == 5
	assert(Mappers.supports(mapper_id), string.format("Unsupported mapper: %d", mapper_id))

	four_screen_mode = bit32.btest(flags6, 0x08)
	if four_screen_mode then
		mirroring_mode = 2
	else
		mirroring_mode = bit32.band(flags6, 0x01) == 0 and 3 or 2
	end
	refresh_nametable_lut()

	local has_trainer = bit32.btest(flags6, 0x04)
	local has_battery = bit32.btest(flags6, 0x02)

	local prg_ram_size = 0
	if is_ines2 then
		local prg_ram_shift = bit32.band(flags10, 0x0F)
		local prg_nvram_shift = bit32.band(bit32.rshift(flags10, 4), 0x0F)
		local prg_ram_volatile = if prg_ram_shift == 0 then 0 else bit32.lshift(64, prg_ram_shift)
		local prg_ram_nonvolatile = if prg_nvram_shift == 0 then 0 else bit32.lshift(64, prg_nvram_shift)
		prg_ram_size = prg_ram_volatile + prg_ram_nonvolatile
	else
		local prg_ram_units = flags8
		if prg_ram_units == 0 then
			prg_ram_units = 1
		end
		prg_ram_size = prg_ram_units * 0x2000
	end

	local offset = 16

	if has_trainer then
		offset += 512
	end

	local prg_size = prg_banks * 16384
	assert(prg_banks > 0, "Invalid iNES ROM: no PRG banks")
	assert(rom_len >= offset + prg_size, "Invalid iNES ROM: PRG section truncated")

	prg_rom = buffer.create(prg_size)
	prg_rom_len = prg_size

	if prg_size > 0 then
		buffer.copy(prg_rom, 0, rom, offset, prg_size)
	end

	offset += prg_size

	local chr_size = chr_banks * 8192

	if chr_size == 0 then
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
		assert(rom_len >= offset + chr_size, "Invalid iNES ROM: CHR section truncated")

		chr_rom = buffer.create(chr_size)
		buffer.copy(chr_rom, 0, rom, offset, chr_size)
	end
	chr_rom_len = chr_size

	if mapper_number == 5 then
		local crc_len = prg_size + (if chr_is_ram then 0 else chr_size)
		local known_units = MMC5ID(rom, offset - prg_size, crc_len)
		if known_units then
			prg_ram_size = known_units * 0x2000
		elseif prg_ram_size < 0x10000 then
			prg_ram_size = 0x10000
		end
	end

	prg_ram = buffer.create(prg_ram_size)
	prg_ram_len = prg_ram_size

	local created_mapper = Mappers.create({
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
		vram = vram,
	})

	bind_mapper(created_mapper)

	buffer.fill(prg_ram, 0, 0, prg_ram_len)
	buffer.fill(ram, 0, 0, 0x800)
	buffer.fill(vram, 0, 0, 0x1000)
	buffer.fill(oam, 0, 0, 0x100)
	buffer.fill(palette, 0, 0, PALETTE_SIZE)

	for i = 0, PALETTE_SIZE - 1 do
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

	buffer.fill(framebuffer, 0, 0, FRAMEBUFFER_SIZE)
	cpu_total_cycles = 0
	dma_cycles = 0
	nmi_pending_flag = false
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
	set_ctrl(0)
	set_mask(0)
	nmi_output = false
	open_bus = 0
	v = 0
	t = 0
	w = 0
	fine_x = 0
	oam_addr = 0
	buffer.fill(pad_state, 0, 0, 2)
	buffer.fill(pad_index, 0, 0, 2)
	sprite_scanline_generation = 1
	buffer.fill(sprite_scanline_data, 0, 0, 1024)
	buffer.fill(sprite_x, 0, 0, 8)
	buffer.fill(sprite_low, 0, 0, 8)
	buffer.fill(sprite_high, 0, 0, 8)
	buffer.fill(sprite_meta, 0, 0, 8)
	buffer.fill(sprite_x_next, 0, 0, 8)
	buffer.fill(sprite_low_next, 0, 0, 8)
	buffer.fill(sprite_high_next, 0, 0, 8)
	buffer.fill(sprite_meta_next, 0, 0, 8)
	reset_bg_pipeline()

	apu_reset()
	apu_set_mmc5_enabled(mapper_is_mmc5)
	pc = read16(0xFFFC)
end

return {
	load = load,
	reset = reset,

	render = function(): buffer?
		while not frame_ready do
			if cpu_jammed then
				step()
			elseif nmi_pending_flag then
				begin_cpu_event()
				local nmi_cycles = nmi()
				finalize_cpu_event(nmi_cycles)
				nmi_pending_flag = false
			elseif not bit32.btest(status, 4) and (apu_irq_pending() or (mapper_is_mmc3 and mmc3_irq_pending) or (mapper_has_irq_pending and mapper_irq_pending())) then
				begin_cpu_event()
				local irq_cycles = irq()
				finalize_cpu_event(irq_cycles)
			else
				step()
			end
		end

		frame_ready = false
		return framebuffer
	end,

	press = function(button: number, player: number?)
		local port = if player ~= 2 then 0 else 1
		local current = buffer.readu8(pad_state, port)

		current = bit32.bor(current, button)

		buffer.writeu8(pad_state, port, current)
	end,

	release = function(button: number, player: number?)
		local port = if player ~= 2 then 0 else 1
		local current = buffer.readu8(pad_state, port)

		current = bit32.band(current, bit32.bnot(button))

		buffer.writeu8(pad_state, port, current)
	end,

	size = Vector2.new(256, 240),

	Buttons = {
		A = 0x01,
		B = 0x02,
		Select = 0x04,
		Start = 0x08,
		Up = 0x10,
		Down = 0x20,
		Left = 0x40,
		Right = 0x80,
	},
}

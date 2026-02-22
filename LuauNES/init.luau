--!native
--!nocheck
--!optimize 2

local SOUND_ASSET_IDS = {
	pulse_12_5 = "rbxassetid://137987182789405",
	pulse_25 = "rbxassetid://108267815293395",
	pulse_50 = "rbxassetid://74193770330344",
	pulse_75 = "rbxassetid://100273244108902",
	
	triangle = "rbxassetid://135072236414372",
	noise = "rbxassetid://77447526849899",
}

local Mappers = require('@self/Mappers')
local APU = require('@self/APU')

type Mapper = Mappers.Mapper

local FRAME_WIDTH = 256
local FRAME_HEIGHT = 240

local FRAMEBUFFER_SIZE = FRAME_WIDTH * FRAME_HEIGHT * 4
local FRAME_STRIDE = FRAME_WIDTH * 4

local PALETTE_SIZE = 32

local framebuffer = buffer.create(FRAMEBUFFER_SIZE)
local palette = buffer.create(PALETTE_SIZE)
local bg_data = buffer.create(FRAME_WIDTH)
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
local sprite_tile = buffer.create(8)
local sprite_pattern_addr = table.create(8, 0)
local sprite_high_next = buffer.create(8)
local sprite_meta_next = buffer.create(8)
local sprite_low_next = buffer.create(8)
local sprite_x_next = buffer.create(8)
local sprite_tile_next = buffer.create(8)
local sprite_pattern_addr_next = table.create(8, 0)
local sprite_scanline_color = buffer.create(FRAME_WIDTH)
local sprite_scanline_meta = buffer.create(FRAME_WIDTH)
local sprite_scanline_stamp = buffer.create(FRAME_WIDTH)
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

local prg_banks = 0
local chr_banks = 0
local mirroring_mode = 3
local mapper_id = 0
local mapper = nil :: Mapper?

local mapper_map_prg_addr = nil :: ((number) -> number)?
local mapper_map_chr_addr = nil :: ((number, number?, boolean?) -> number)?
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
local four_screen_mode = false

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
local indexed_dummy_valid = false
local indexed_dummy_addr = 0
local frame_ready = false
local chr_is_ram = false
local odd_frame = false
local open_bus = 0
local frame_index = 0
local mmc3_a12_sampled = false
local in_ppu_step = false
local cpu_instruction_active = false
local cpu_bus_cycles = 0
local cpu_pending_cycles = 0
local apu_pending_cycles = 0
local in_dma_transfer = false
local cpu_jammed = false

local apu_step: (number) -> ()
local apu_read_status: () -> number
local apu_write: (number, number) -> ()
local apu_reset: () -> ()
local apu_irq_pending: () -> boolean
local apu_consume_dma_stall_cycles: () -> number

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

local nes_rgba32 = table.create(64, 0xFF000000)
local palette_rgba32 = table.create(32, 0xFF000000)

palette_rgba32[0] = 0xFF000000

for i = 0, 63 do
	local rgb = RAW_PALETTE[i + 1]

	local r = bit32.band(bit32.rshift(rgb, 16), 255)
	local g = bit32.band(bit32.rshift(rgb, 8), 255)
	local b = bit32.band(rgb, 0xFF)

	nes_rgba32[i] = r + bit32.lshift(g, 8) + bit32.lshift(b, 16) + 0xFF000000
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
	else
		mapper_map_prg_addr = nil
		mapper_map_chr_addr = nil
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
	end
end

local function prg_read(addr: number): number
	if mapper_map_prg_addr == nil or prg_rom_len <= 0 then
		return 0
	end

	local offset = mapper_map_prg_addr(addr)
	if offset < 0 or offset >= prg_rom_len then
		return 0
	end

	return buffer.readu8(prg_rom, offset)
end

local function map_chr_addr(addr: number, fetch_kind: number?): number
	if mapper_map_chr_addr == nil then
		return bit32.band(addr, 0x1FFF)
	end

	return mapper_map_chr_addr(addr, fetch_kind or 0, ctrl_sprite_8x16)
end

local function chr_read(addr: number, fetch_kind: number?): number
	if chr_rom_len <= 0 then
		return 0
	end

	local mapped = map_chr_addr(addr, fetch_kind)
	if mapped < 0 or mapped >= chr_rom_len then
		return 0
	end

	return buffer.readu8(chr_rom, mapped)
end

local function chr_write(addr: number, value: number, fetch_kind: number?)
	if chr_is_ram then
		if chr_rom_len <= 0 then
			return
		end

		local mapped = map_chr_addr(addr, fetch_kind)
		if mapped < 0 or mapped >= chr_rom_len then
			return
		end

		buffer.writeu8(chr_rom, mapped, value)
	end
end

local function mirror_nametable(addr: number): number
	local offset = bit32.band(addr, 0x0FFF)

	if four_screen_mode then
		return offset
	end

	local table_index = bit32.band(bit32.rshift(offset, 10), 0x03)
	local inner = bit32.band(offset, 0x03FF)

	if mirroring_mode == 0 then
		return inner
	elseif mirroring_mode == 1 then
		return 0x0400 + inner
	elseif mirroring_mode == 2 then
		return bit32.band(table_index, 1) * 0x0400 + inner
	end

	if table_index < 2 then
		return inner
	end

	return 0x0400 + inner
end

local function sync_palette_cache(index: number)
	palette_rgba32[index] = nes_rgba32[bit32.band(buffer.readu8(palette, index), 0x3F)] or 0xFF000000
end

local function normalize_palette_addr(addr: number)
	local index = bit32.band(addr, 0x1F)
	if bit32.band(index, 0x13) == 0x10 then
		index -= 0x10
	end
	return index
end

local function read_palette(addr: number)
	return buffer.readu8(palette, normalize_palette_addr(addr))
end

for i = 0, PALETTE_SIZE - 1 do
	sync_palette_cache(i)
end

local apu = APU.new(SOUND_ASSET_IDS, prg_read)

apu_step = apu.step
apu_read_status = apu.readStatus
apu_write = apu.write
apu_reset = apu.reset
apu_irq_pending = apu.irqPending
apu_consume_dma_stall_cycles = apu.consumeDmaStallCycles

local function sample_mmc3_a12(addr: number)
	if mapper_id == 4 and addr < 0x2000 then
		local a12_high = bit32.btest(addr, 0x1000)
		if in_ppu_step then
			mmc3_a12_sampled = a12_high
		elseif mapper_clock_a12 ~= nil then
			mapper_clock_a12(a12_high)
		end
	end
end

local function ppu_read(addr: number, fetch_kind: number?)
	addr = bit32.band(addr, 0x3FFF)

	if mapper_on_ppu_address ~= nil then
		mapper_on_ppu_address(addr, scanline, ppu_cycle + 1, mask_rendering)
	end

	if addr < 0x2000 then
		sample_mmc3_a12(addr)
		return chr_read(addr, fetch_kind)
	end

	if addr < 0x3F00 then
		if mapper_read_nametable ~= nil then
			local value = mapper_read_nametable(addr)
			if value ~= nil then
				return bit32.band(value, 0xFF)
			end
		end
		return buffer.readu8(vram, mirror_nametable(addr))
	end

	return read_palette(addr)
end

local function ppu_write(addr: number, value: number, fetch_kind: number?)
	addr = bit32.band(addr, 0x3FFF)
	value = bit32.band(value, 0xFF)

	if addr < 0x2000 then
		sample_mmc3_a12(addr)
		chr_write(addr, value, fetch_kind)
		return
	end

	if addr < 0x3F00 then
		if mapper_write_nametable ~= nil and mapper_write_nametable(addr, value) then
			return
		end
		buffer.writeu8(vram, mirror_nametable(addr), value)
		return
	end

	local index = normalize_palette_addr(addr)
	buffer.writeu8(palette, index, value)
	sync_palette_cache(index)
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
	for _ = 1, count do
		in_ppu_step = true

		local current_scanline = scanline
		local current_dot = ppu_cycle
		local cycle = current_dot + 1
		
		local visible_line = current_scanline < 240
		local pre_render_line = current_scanline == 261
		
		local show_bg = mask_show_bg
		local show_sp = mask_show_sp
		local bg_left = mask_bg_left
		local sp_left = mask_sp_left
		local grayscale = mask_grayscale
		local rendering = mask_rendering
		
		local bg_mux = bit32.rshift(0x8000, fine_x)

		mmc3_a12_sampled = false

		if current_dot == 0 then
			if mapper_clock_scanline ~= nil then
				mapper_clock_scanline(current_scanline)
			end

			if mapper_get_mirroring ~= nil then
				mirroring_mode = mapper_get_mirroring()
			end
			
			if visible_line then
				frame_row_start = current_scanline * FRAME_STRIDE
				if rendering then
					local tmp_x = sprite_x
					local tmp_tile = sprite_tile
					local tmp_low = sprite_low
					local tmp_high = sprite_high
					local tmp_meta = sprite_meta
					local tmp_pattern_addr = sprite_pattern_addr

					sprite_x = sprite_x_next
					sprite_tile = sprite_tile_next
					sprite_low = sprite_low_next
					sprite_high = sprite_high_next
					sprite_meta = sprite_meta_next
					sprite_pattern_addr = sprite_pattern_addr_next

					sprite_x_next = tmp_x
					sprite_tile_next = tmp_tile
					sprite_low_next = tmp_low
					sprite_high_next = tmp_high
					sprite_meta_next = tmp_meta
					sprite_pattern_addr_next = tmp_pattern_addr
					
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
					buffer.fill(sprite_scanline_stamp, 0, 0, FRAME_WIDTH)
					sprite_scanline_generation = 1
				else
					sprite_scanline_generation += 1
				end

				local generation = sprite_scanline_generation

				for i = 0, visible_sprite_count - 1 do
					local sx = buffer.readu8(sprite_x, i)
					if sx >= FRAME_WIDTH then
						continue
					end

					local meta = buffer.readu8(sprite_meta, i)
					local sp_low = buffer.readu8(sprite_low, i)
					local sp_high = buffer.readu8(sprite_high, i)
					if sp_low == 0 and sp_high == 0 then
						continue
					end

					local palette_base = bit32.band(meta, 0x1F)
					local flip_horizontal = bit32.btest(meta, 0x20)

					if flip_horizontal then
						for offset = 0, 7 do
							local px = sx + offset
							if px >= FRAME_WIDTH then
								break
							end

							if buffer.readu8(sprite_scanline_stamp, px) == generation then
								continue
							end

							local sp_lo = bit32.band(bit32.rshift(sp_low, offset), 1)
							local sp_hi = bit32.lshift(bit32.band(bit32.rshift(sp_high, offset), 1), 1)
							local pixel = bit32.bor(sp_lo, sp_hi)
							if pixel == 0 then
								continue
							end

							buffer.writeu8(sprite_scanline_color, px, palette_base + pixel)
							buffer.writeu8(sprite_scanline_meta, px, meta)
							buffer.writeu8(sprite_scanline_stamp, px, generation)
						end
					else
						for offset = 0, 7 do
							local px = sx + offset
							if px >= FRAME_WIDTH then
								break
							end

							if buffer.readu8(sprite_scanline_stamp, px) == generation then
								continue
							end

							local bit_pos = 7 - offset
							local sp_lo = bit32.band(bit32.rshift(sp_low, bit_pos), 1)
							local sp_hi = bit32.lshift(bit32.band(bit32.rshift(sp_high, bit_pos), 1), 1)
							local pixel = bit32.bor(sp_lo, sp_hi)
							if pixel == 0 then
								continue
							end

							buffer.writeu8(sprite_scanline_color, px, palette_base + pixel)
							buffer.writeu8(sprite_scanline_meta, px, meta)
							buffer.writeu8(sprite_scanline_stamp, px, generation)
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

		local sprite_generation = sprite_scanline_generation

		if visible_line and cycle >= 1 and cycle <= 256 then
			local px = cycle - 1
			local bg = 0
			if show_bg and (px >= 8 or bg_left) then
				local bg_lo = bit32.band(bg_shift_pat_low, bg_mux) ~= 0 and 1 or 0
				local bg_hi = bit32.band(bg_shift_pat_high, bg_mux) ~= 0 and 1 or 0
				local at_lo = bit32.band(bg_shift_attr_low, bg_mux) ~= 0 and 1 or 0
				local at_hi = bit32.band(bg_shift_attr_high, bg_mux) ~= 0 and 1 or 0
				
				local pixel = bit32.bor(bg_lo, bit32.lshift(bg_hi, 1))
				local palette_bits = bit32.bor(at_lo, bit32.lshift(at_hi, 1))
				
				bg = bit32.bor(bit32.lshift(palette_bits, 2), pixel)
			end
			
			local bg_pixel = bit32.band(bg, 0x03)

			local sp_pixel = 0
			local sp_color_index = 0
			local sp_is_behind = false
			local is_sprite_zero = false

			if show_sp and (px >= 8 or sp_left) then
				if buffer.readu8(sprite_scanline_stamp, px) == sprite_generation then
					local meta = buffer.readu8(sprite_scanline_meta, px)
					sp_color_index = buffer.readu8(sprite_scanline_color, px)
					sp_pixel = bit32.band(sp_color_index, 0x03)
					sp_is_behind = bit32.btest(meta, 0x40)
					is_sprite_zero = bit32.btest(meta, 0x80)
				end
			end

			local color_index = 0
			if bg_pixel == 0 and sp_pixel == 0 then
				color_index = 0
			elseif bg_pixel == 0 then
				color_index = sp_color_index
			elseif sp_pixel == 0 then
				color_index = bg
			else
				if is_sprite_zero and px < 255 then
					ppu_status = bit32.bor(ppu_status, 0x40)
				end

				if sp_is_behind then
					color_index = bg
				else
					color_index = sp_color_index
				end
			end

			local out_color = palette_rgba32[color_index] or 0xFF000000
			if grayscale then
				local gray = bit32.band(read_palette(color_index), 0x30)
				out_color = nes_rgba32[gray] or 0xFF000000
			end

			buffer.writeu32(framebuffer, frame_row_start + px * 4, out_color)
		end

		if pre_render_line and cycle == 1 then
			ppu_status = bit32.band(ppu_status, 0x1F)
			nmi_pending_flag = false
		elseif current_scanline == 241 and cycle == 1 then
			ppu_status = bit32.bor(ppu_status, 0x80)
			if nmi_output then
				nmi_pending_flag = true
			end
		end

		if rendering and (visible_line or pre_render_line) then
			
			--// begin next scanline sprite evaluation
			if cycle == 64 then
				local line_y = if pre_render_line then 0 else current_scanline + 1
				
				buffer.fill(sprite_x_next, 0, 0xFF, 8)
				buffer.fill(sprite_tile_next, 0, 0x00, 8)
				buffer.fill(sprite_low_next, 0, 0x00, 8)
				buffer.fill(sprite_high_next, 0, 0x00, 8)
				buffer.fill(sprite_meta_next, 0, 0x00, 8)

				for i = 1, 8 do
					sprite_pattern_addr_next[i] = 0x1FF0
				end

				next_visible_sprite_count = 0
				sprite_overflow_next = false

				sprite_eval_target_scanline = line_y
				sprite_eval_sprite_height = ctrl_sprite_height
				sprite_eval_pattern_base = ctrl_sprite_pattern_base
				sprite_eval_stage = 0
				sprite_eval_n = 0
				sprite_eval_overflow_m = 0
				sprite_eval_latch = 0
				sprite_eval_candidate_y = 0
				sprite_eval_candidate_tile = 0
				sprite_eval_candidate_attr = 0

				if line_y < 0 or line_y >= 240 or (not mask_show_sp) then
					sprite_eval_active = false
				else
					sprite_eval_active = true
				end
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
					local odd_cycle = bit32.band(cycle, 1) == 1
					if odd_cycle then
						local oam_base = sprite_eval_n * 4
						if sprite_eval_stage == 4 then
							sprite_eval_latch = buffer.readu8(oam, oam_base + sprite_eval_overflow_m)
						else
							sprite_eval_latch = buffer.readu8(oam, oam_base + sprite_eval_stage)
						end
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
						local sprite_index = sprite_eval_n
						local sy = sprite_eval_candidate_y
						local tile = sprite_eval_candidate_tile
						local attr = sprite_eval_candidate_attr
						local sx = sprite_eval_latch

						local row = sprite_eval_target_scanline - (sy + 1)
						local row_in_tile = row
						if bit32.btest(attr, 0x80) then
							row_in_tile = sprite_eval_sprite_height - 1 - row
						end

						local pattern_bank = sprite_eval_pattern_base
						local tile_index = tile
						if sprite_eval_sprite_height == 16 then
							pattern_bank = bit32.btest(tile, 1) and 0x1000 or 0
							tile_index = bit32.band(tile, 0xFE)
							if row_in_tile >= 8 then
								tile_index += 1
								row_in_tile -= 8
							end
						end

						local pattern_addr = pattern_bank + tile_index * 16 + row_in_tile
						local meta = bit32.lshift(bit32.band(attr, 0x03) + 4, 2)
						if bit32.btest(attr, 0x40) then
							meta += 0x20
						end
						if bit32.btest(attr, 0x20) then
							meta += 0x40
						end
						if sprite_index == 0 then
							meta += 0x80
						end

						local out_index = next_visible_sprite_count
						buffer.writeu8(sprite_x_next, out_index, sx)
						buffer.writeu8(sprite_tile_next, out_index, tile)
						sprite_pattern_addr_next[out_index + 1] = pattern_addr
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
			
			-- // tick bg fetch pi
			if show_bg and ((cycle >= 1 and cycle <= 256) or (cycle >= 321 and cycle <= 336)) then
				bg_shift_pat_low = bit32.band(bit32.lshift(bg_shift_pat_low, 1), 0xFFFF)
				bg_shift_pat_high = bit32.band(bit32.lshift(bg_shift_pat_high, 1), 0xFFFF)
				bg_shift_attr_low = bit32.band(bit32.lshift(bg_shift_attr_low, 1), 0xFFFF)
				bg_shift_attr_high = bit32.band(bit32.lshift(bg_shift_attr_high, 1), 0xFFFF)

				local phase = bit32.band(cycle, 0x07)

				if phase == 1 then
					bg_nt_byte = ppu_read(bit32.bor(0x2000, bit32.band(v, 0x0FFF)))
				elseif phase == 3 then
					local attr_addr = bit32.bor(
						0x23C0,
						bit32.band(v, 0x0C00),
						bit32.band(bit32.rshift(v, 4), 0x38),
						bit32.band(bit32.rshift(v, 2), 0x07)
					)
					bg_at_byte = ppu_read(attr_addr)

					local attr_shift = bit32.bor(
						bit32.band(bit32.rshift(v, 4), 0x04),
						bit32.band(v, 0x02)
					)
					local attr_bits = bit32.band(bit32.rshift(bg_at_byte, attr_shift), 0x03)
					bg_attr_latch_low = bit32.band(attr_bits, 0x01)
					bg_attr_latch_high = bit32.band(bit32.rshift(attr_bits, 1), 0x01)
				elseif phase == 5 then
					local fine_y = bit32.band(bit32.rshift(v, 12), 0x07)
					local pattern_addr = ctrl_bg_pattern_base + bg_nt_byte * 16 + fine_y
					bg_low_byte = ppu_read(pattern_addr, 1)
				elseif phase == 7 then
					local fine_y = bit32.band(bit32.rshift(v, 12), 0x07)
					local pattern_addr = ctrl_bg_pattern_base + bg_nt_byte * 16 + fine_y
					bg_high_byte = ppu_read(pattern_addr + 8, 1)
				elseif phase == 0 then
					bg_shift_pat_low = bit32.bor(bit32.band(bg_shift_pat_low, 0xFF00), bg_low_byte)
					bg_shift_pat_high = bit32.bor(bit32.band(bg_shift_pat_high, 0xFF00), bg_high_byte)

					local attr_fill_low = if bg_attr_latch_low ~= 0 then 0xFF else 0x00
					local attr_fill_high = if bg_attr_latch_high ~= 0 then 0xFF else 0x00
					bg_shift_attr_low = bit32.bor(bit32.band(bg_shift_attr_low, 0xFF00), attr_fill_low)
					bg_shift_attr_high = bit32.bor(bit32.band(bg_shift_attr_high, 0xFF00), attr_fill_high)

					if bit32.band(v, 0x001F) == 31 then
						v = bit32.band(v, bit32.bnot(0x001F))
						v = bit32.bxor(v, 0x0400)
					else
						v = bit32.band(v + 1, 0x7FFF)
					end
				end
			end
			
			if cycle >= 257 and cycle <= 320 and show_sp then
				local slot_phase = bit32.band(cycle - 257, 0x07)
				if slot_phase == 4 or slot_phase == 6 then
					local slot = bit32.rshift(cycle - 257, 3)
					local pattern_addr = 0x1FF0
					local has_sprite = slot < next_visible_sprite_count

					if has_sprite or mapper_id == 4 then
						if has_sprite then
							pattern_addr = bit32.band(sprite_pattern_addr_next[slot + 1], 0x1FFF)
						end

						local value_addr = if slot_phase == 4 then pattern_addr else bit32.band(pattern_addr + 8, 0x1FFF)
						local value = 0
						if mapper_id == 4 or mapper_on_ppu_address ~= nil then
							value = ppu_read(value_addr, 2)
						else
							value = chr_read(value_addr, 2)
						end

						if has_sprite then
							if slot_phase == 4 then
								buffer.writeu8(sprite_low_next, slot, value)
							else
								buffer.writeu8(sprite_high_next, slot, value)
							end
						end
					end
				end
			end
		end

		if mapper_id == 4 and mapper_clock_a12 ~= nil then
			mapper_clock_a12(mmc3_a12_sampled)
		end

		if rendering and pre_render_line and odd_frame and current_dot == 339 then
			ppu_cycle = 0
			scanline = 0
			frame_ready = true
			odd_frame = not odd_frame
			frame_index += 1
			in_ppu_step = false
			continue
		end

		ppu_cycle = current_dot + 1
		if ppu_cycle > 340 then
			ppu_cycle = 0
			scanline = current_scanline + 1

			if scanline > 261 then
				scanline = 0
				frame_ready = true
				odd_frame = not odd_frame
				frame_index += 1
			end
		end

		in_ppu_step = false
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
		return
	end

	local pending = apu_pending_cycles
	apu_pending_cycles = 0
	apu_step(pending)
	apply_apu_dma_stalls()
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

local function cpu_bus_tick()
	if not cpu_instruction_active or in_dma_transfer then
		return
	end

	cpu_bus_cycles += 1
	cpu_pending_cycles += 1
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

	return 0
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
		return
	end

	if reg == 1 then
		set_mask(value)
		return
	end

	if reg == 3 then
		oam_addr = value
		return
	end

	if reg == 4 then
		buffer.writeu8(oam, oam_addr, value)
		oam_addr = bit32.band(oam_addr + 1, 0xFF)
		return
	end

	if reg == 5 then
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
		return
	end

	if reg == 6 then
		if w == 0 then
			t = bit32.bor(bit32.band(t, 0x00FF), bit32.lshift(bit32.band(value, 0x3F), 8))
			w = 1
		else
			t = bit32.bor(bit32.band(t, 0x7F00), value)
			v = t
			w = 0
		end
		return
	end

	if reg == 7 then
		ppu_write(v, value)

		v = bit32.band(v + ctrl_vram_increment, 0x7FFF)
	end
end

local function strobe(value)
	pad_strobe = bit32.band(value, 0x01)
	if pad_strobe == 1 then
		buffer.writeu8(pad_index, 0, 0)
		buffer.writeu8(pad_index, 1, 0)
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

local function mapper_write(addr: number, value: number)
	if mapper_write_cpu then
		mapper_write_cpu(addr, value)
		if mapper_get_mirroring then
			mirroring_mode = mapper_get_mirroring()
		end
	end
end

local function resolve_prg_ram_addr(addr: number): number?
	return if mapper_map_prg_ram_addr then mapper_map_prg_ram_addr(addr) else nil
end

local function prg_ram_read_enabled(): boolean
	return if mapper_prg_ram_readable then mapper_prg_ram_readable() else true
end

local function prg_ram_write_enabled(): boolean
	return if mapper_prg_ram_writable then mapper_prg_ram_writable() else true
end

local function bus_read(addr)
	cpu_bus_tick()

	addr = bit32.band(addr, 0xFFFF)

	if addr < 0x2000 then
		local value = buffer.readu8(ram, bit32.band(addr, 0x07FF))
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
		open_bus = 0
		return 0
	end

	if addr < 0x6000 then
		flush_cpu_timing(false)
		if mapper_read_cpu ~= nil then
			local mapper_value = mapper_read_cpu(addr)
			if mapper_value ~= nil then
				local value = bit32.band(mapper_value, 0xFF)
				open_bus = value
				return value
			end
		end
		open_bus = 0
		return 0
	end

	local ram_addr = resolve_prg_ram_addr(addr)
	if ram_addr ~= nil then
		if ram_addr < 0 or ram_addr >= prg_ram_len or (not prg_ram_read_enabled()) then
			open_bus = 0
			return 0
		end

		local value = buffer.readu8(prg_ram, ram_addr)
		open_bus = value
		return value
	end

	if addr >= 0x8000 then
		local value = bit32.band(prg_read(addr), 0xFF)
		open_bus = value
		return value
	end

	open_bus = 0
	return 0
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
	cpu_bus_tick()

	addr = bit32.band(addr, 0xFFFF)
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

	if addr == 0x4014 then
		flush_cpu_timing(false)
		oam_dma(value)
		return
	end

	if addr == 0x4016 then
		flush_cpu_timing(false)
		strobe(value)
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
		flush_cpu_timing(false)
		mapper_write(addr, value)
		return
	end

	local ram_addr = resolve_prg_ram_addr(addr)
	if ram_addr ~= nil then
		if ram_addr < 0 or ram_addr >= prg_ram_len or (not prg_ram_write_enabled()) then
			return
		end
		buffer.writeu8(prg_ram, ram_addr, value)
		return
	end

	if addr >= 0x8000 then
		flush_cpu_timing(false)
		mapper_write(addr, value)
	end
end

local function read16(addr)
	local lo = bus_read(addr)
	local hi = bus_read(addr + 1)
	return bit32.bor(lo, bit32.lshift(hi, 8))
end

local function read16_wrap(addr)
	local lo = bus_read(addr)
	local hi = bus_read(bit32.band(addr, 0xFF00) + bit32.band(addr + 1, 0x00FF))
	return bit32.bor(lo, bit32.lshift(hi, 8))
end

local function set_flag(flag, cond)
	if cond then
		status = bit32.bor(status, flag)
	else
		status = bit32.band(status, bit32.bxor(0xFF, flag))
	end
end

local function push(value)
	bus_write(0x0100 + sp, value)
	sp = bit32.band(sp - 1, 0xFF)
end

local function pull()
	sp = bit32.band(sp + 1, 0xFF)
	return bus_read(0x0100 + sp)
end

local opcodes do
	local function set_zn(value)
		value = bit32.band(value, 0xFF)
		set_flag(2, value == 0)
		set_flag(128, bit32.btest(value, 0x80))
		return value
	end
	
	function imp() end
	function acc() end

	local function calc_indexed_addr(base: number, index: number): (number, number, boolean)
		local low_sum = bit32.band(base, 0xFF) + index
		local final_addr = bit32.band(base + index, 0xFFFF)
		local dummy_addr = bit32.bor(
			bit32.band(base, 0xFF00),
			bit32.band(low_sum, 0x00FF)
		)
		return final_addr, dummy_addr, low_sum > 0xFF
	end

	function imm()
		addr_value = pc
		pc = bit32.band(pc + 1, 0xFFFF)
	end

	function zp()
		addr_value = bus_read(pc)
		pc = bit32.band(pc + 1, 0xFFFF)
	end

	function zpx()
		addr_value = bit32.band(bus_read(pc) + x, 0xFF)
		pc = bit32.band(pc + 1, 0xFFFF)
	end

	function zpy()
		addr_value = bit32.band(bus_read(pc) + y, 0xFF)
		pc = bit32.band(pc + 1, 0xFFFF)
	end

	function abs()
		addr_value = read16(pc)
		pc = bit32.band(pc + 2, 0xFFFF)
	end

	function abx()
		local base = read16(pc)
		local final_addr, dummy_addr, crossed = calc_indexed_addr(base, x)
		addr_value = final_addr
		page_crossed = crossed
		indexed_dummy_addr = dummy_addr
		indexed_dummy_valid = true
		pc = bit32.band(pc + 2, 0xFFFF)
	end

	function aby()
		local base = read16(pc)
		local final_addr, dummy_addr, crossed = calc_indexed_addr(base, y)
		addr_value = final_addr
		page_crossed = crossed
		indexed_dummy_addr = dummy_addr
		indexed_dummy_valid = true
		pc = bit32.band(pc + 2, 0xFFFF)
	end

	function ind()
		local ptr = read16(pc)
		addr_value = read16_wrap(ptr)
		pc = bit32.band(pc + 2, 0xFFFF)
	end

	function izx()
		local base = bit32.band(bus_read(pc) + x, 0xFF)
		local lo = bus_read(base)
		local hi = bus_read(bit32.band(base + 1, 0xFF))
		addr_value = bit32.bor(lo, bit32.lshift(hi, 8))
		pc = bit32.band(pc + 1, 0xFFFF)
	end

	function izy()
		local base = bus_read(pc)
		local lo = bus_read(base)
		local hi = bus_read(bit32.band(base + 1, 0xFF))
		local addr = bit32.bor(lo, bit32.lshift(hi, 8))
		local final_addr, dummy_addr, crossed = calc_indexed_addr(addr, y)
		addr_value = final_addr
		page_crossed = crossed
		indexed_dummy_addr = dummy_addr
		indexed_dummy_valid = true
		pc = bit32.band(pc + 1, 0xFFFF)
	end

	function rel()
		local offset = bus_read(pc)
		pc = bit32.band(pc + 1, 0xFFFF)
		if offset >= 128 then
			offset = offset - 256
		end
		addr_value = bit32.band(pc + offset, 0xFFFF)
	end

	function read_op()
		return bus_read(addr_value)
	end

	function write_op(v)
		bus_write(addr_value, v)
	end

	function write_op_rmw(old_value: number, new_value: number)
		write_op(bit32.band(old_value, 0xFF))
		write_op(bit32.band(new_value, 0xFF))
	end

	function adc()
		local m = read_op()
		local c = bit32.btest(status, 1) and 1 or 0
		local sum = a + m + c
		set_flag(1, sum > 255)
		set_flag(64, bit32.btest(bit32.band(bit32.bxor(a, sum), bit32.bxor(m, sum), 0x80), 0x80))
		a = set_zn(bit32.band(sum, 0xFF))
	end

	function op_and()
		a = set_zn(bit32.band(a, read_op()))
	end

	function asl_a()
		set_flag(1, bit32.btest(a, 0x80))
		a = set_zn(bit32.band(bit32.lshift(a, 1), 0xFF))
	end

	function asl()
		local m = read_op()
		set_flag(1, bit32.btest(m, 0x80))
		local result = set_zn(bit32.band(bit32.lshift(m, 1), 0xFF))
		write_op_rmw(m, result)
	end

	function branch(cond)
		if cond then
			bus_read(pc)
			cycles = cycles + 1
			if bit32.band(pc, 0xFF00) ~= bit32.band(addr_value, 0xFF00) then
				local page_fix_addr = bit32.bor(
					bit32.band(pc, 0xFF00),
					bit32.band(addr_value, 0x00FF)
				)
				bus_read(page_fix_addr)
				cycles = cycles + 1
			end
			pc = addr_value
		end
	end

	function op_bit()
		local m = read_op()
		set_flag(2, bit32.band(a, m) == 0)
		set_flag(64, bit32.btest(m, 0x40))
		set_flag(128, bit32.btest(m, 0x80))
	end

	function brk()
		pc = bit32.band(pc + 1, 0xFFFF)
		
		push(bit32.rshift(pc, 8))
		push(bit32.band(pc, 0xFF))
		
		push(bit32.bor(status, 16, 32))
		set_flag(4, true)
		pc = read16(0xFFFE)
	end

	function cmp()
		local m = read_op()
		set_flag(1, a >= m)
		set_zn(bit32.band(a - m, 0xFF))
	end

	function cpx()
		local m = read_op()
		set_flag(1, x >= m)
		set_zn(bit32.band(x - m, 0xFF))
	end

	function cpy()
		local m = read_op()
		set_flag(1, y >= m)
		set_zn(bit32.band(y - m, 0xFF))
	end

	function dec()
		local m = read_op()
		local result = set_zn(bit32.band(m - 1, 0xFF))
		write_op_rmw(m, result)
	end

	function dex()
		x = set_zn(bit32.band(x - 1, 0xFF))
	end

	function dey()
		y = set_zn(bit32.band(y - 1, 0xFF))
	end

	function eor()
		a = set_zn(bit32.bxor(a, read_op()))
	end

	function inc()
		local m = read_op()
		local result = set_zn(bit32.band(m + 1, 0xFF))
		write_op_rmw(m, result)
	end

	function inx()
		x = set_zn(bit32.band(x + 1, 0xFF))
	end

	function iny()
		y = set_zn(bit32.band(y + 1, 0xFF))
	end

	function jmp()
		pc = addr_value
	end

	function jsr()
		local value = bit32.band(pc - 1, 0xFFFF)
		
		push(bit32.rshift(value, 8))
		push(bit32.band(value, 0xFF))
		
		pc = addr_value
	end

	function lda()
		a = set_zn(read_op())
	end

	function ldx()
		x = set_zn(read_op())
	end

	function ldy()
		y = set_zn(read_op())
	end

	function lsr_a()
		set_flag(1, bit32.btest(a, 0x01))
		a = set_zn(bit32.rshift(a, 1))
	end

	function lsr()
		local m = read_op()
		set_flag(1, bit32.btest(m, 0x01))
		local result = set_zn(bit32.rshift(m, 1))
		write_op_rmw(m, result)
	end

	function ora()
		a = set_zn(bit32.bor(a, read_op()))
	end

	function pha()
		push(a)
	end

	function php()
		push(bit32.bor(status, 16, 32))
	end

	function pla()
		a = set_zn(pull())
	end

	function plp()
		status = bit32.bor(bit32.band(pull(), 0xEF), 32)
	end

	function rol_a()
		local c = bit32.btest(status, 1) and 1 or 0
		set_flag(1, bit32.btest(a, 0x80))
		a = set_zn(bit32.band(bit32.bor(bit32.lshift(a, 1), c), 0xFF))
	end

	function rol()
		local m = read_op()
		local c = bit32.btest(status, 1) and 1 or 0
		set_flag(1, bit32.btest(m, 0x80))
		local result = set_zn(bit32.band(bit32.bor(bit32.lshift(m, 1), c), 0xFF))
		write_op_rmw(m, result)
	end

	function ror_a()
		local c = bit32.btest(status, 1) and 0x80 or 0
		set_flag(1, bit32.btest(a, 0x01))
		a = set_zn(bit32.bor(bit32.rshift(a, 1), c))
	end

	function ror()
		local m = read_op()
		local c = bit32.btest(status, 1) and 0x80 or 0
		set_flag(1, bit32.btest(m, 0x01))
		local result = set_zn(bit32.bor(bit32.rshift(m, 1), c))
		write_op_rmw(m, result)
	end

	function rti()
		status = bit32.bor(bit32.band(pull(), 0xEF), 32)
		pc = bit32.bor(pull(), bit32.lshift(pull(), 8))
	end

	function rts()
		pc = bit32.band(bit32.bor(pull(), bit32.lshift(pull(), 8)) + 1, 0xFFFF)
	end

	function sbc()
		local m = read_op()
		local c = bit32.btest(status, 1) and 0 or 1
		local diff = a - m - c
		set_flag(1, diff >= 0)
		set_flag(64, bit32.btest(bit32.band(bit32.bxor(a, diff), bit32.bxor(a, m), 0x80), 0x80))
		a = set_zn(bit32.band(diff, 0xFF))
	end

	function sta()
		write_op(a)
	end

	function stx()
		write_op(x)
	end

	function sty()
		write_op(y)
	end

	function tax()
		x = set_zn(a)
	end

	function tay()
		y = set_zn(a)
	end

	function tsx()
		x = set_zn(sp)
	end

	function txa()
		a = set_zn(x)
	end

	function txs()
		sp = x
	end

	function tya()
		a = set_zn(y)
	end

	function add_with_carry(m: number)
		local c = bit32.btest(status, 1) and 1 or 0
		local sum = a + m + c
		set_flag(1, sum > 255)
		set_flag(64, bit32.btest(bit32.band(bit32.bxor(a, sum), bit32.bxor(m, sum), 0x80), 0x80))
		a = set_zn(bit32.band(sum, 0xFF))
	end

	function sub_with_borrow(m: number)
		local c = bit32.btest(status, 1) and 0 or 1
		local diff = a - m - c
		set_flag(1, diff >= 0)
		set_flag(64, bit32.btest(bit32.band(bit32.bxor(a, diff), bit32.bxor(a, m), 0x80), 0x80))
		a = set_zn(bit32.band(diff, 0xFF))
	end

	function op_lax()
		local m = read_op()
		a = set_zn(m)
		x = a
	end

	function op_sax()
		write_op(bit32.band(a, x))
	end

	function op_dcp()
		local old_m = read_op()
		local m = bit32.band(old_m - 1, 0xFF)
		write_op_rmw(old_m, m)
		set_flag(1, a >= m)
		set_zn(bit32.band(a - m, 0xFF))
	end

	function op_isc()
		local old_m = read_op()
		local m = bit32.band(old_m + 1, 0xFF)
		write_op_rmw(old_m, m)
		sub_with_borrow(m)
	end

	function op_rla()
		local old_m = read_op()
		local c = bit32.btest(status, 1) and 1 or 0
		set_flag(1, bit32.btest(old_m, 0x80))
		local m = bit32.band(bit32.bor(bit32.lshift(old_m, 1), c), 0xFF)
		write_op_rmw(old_m, m)
		a = set_zn(bit32.band(a, m))
	end

	function op_rra()
		local old_m = read_op()
		local c = bit32.btest(status, 1) and 0x80 or 0
		set_flag(1, bit32.btest(old_m, 0x01))
		local m = bit32.band(bit32.bor(bit32.rshift(old_m, 1), c), 0xFF)
		write_op_rmw(old_m, m)
		add_with_carry(m)
	end

	function op_slo()
		local old_m = read_op()
		set_flag(1, bit32.btest(old_m, 0x80))
		local m = bit32.band(bit32.lshift(old_m, 1), 0xFF)
		write_op_rmw(old_m, m)
		a = set_zn(bit32.bor(a, m))
	end

	function op_sre()
		local old_m = read_op()
		set_flag(1, bit32.btest(old_m, 0x01))
		local m = bit32.rshift(old_m, 1)
		write_op_rmw(old_m, m)
		a = set_zn(bit32.bxor(a, m))
	end

	function op_anc()
		a = set_zn(bit32.band(a, read_op()))
		set_flag(1, bit32.btest(a, 0x80))
	end

	function op_alr()
		a = bit32.band(a, read_op())
		set_flag(1, bit32.btest(a, 0x01))
		a = set_zn(bit32.rshift(a, 1))
	end

	function op_arr()
		a = bit32.band(a, read_op())
		a = bit32.band(bit32.bor(bit32.rshift(a, 1), (bit32.btest(status, 1) and 0x80 or 0)), 0xFF)
		a = set_zn(a)
		set_flag(1, bit32.btest(a, 0x40))
		local b5 = bit32.band(bit32.rshift(a, 5), 0x01)
		local b6 = bit32.band(bit32.rshift(a, 6), 0x01)
		set_flag(64, b5 ~= b6)
	end

	function op_sbx()
		local t = bit32.band(a, x) - read_op()
		set_flag(1, t >= 0)
		x = set_zn(bit32.band(t, 0xFF))
	end

	function op_las()
		local m = bit32.band(read_op(), sp)
		a = m
		x = m
		sp = m
		set_zn(m)
	end

	function op_xaa()
		a = set_zn(bit32.band(bit32.bor(a, 0xEE), x, read_op()))
	end

	function op_lxa()
		local v = read_op()
		a = set_zn(v)
		x = a
	end

	function op_ahx()
		local high_plus_one = bit32.band(bit32.rshift(addr_value, 8) + 1, 0xFF)
		write_op(bit32.band(a, x, high_plus_one))
	end

	function op_tas()
		sp = bit32.band(a, x)
		local high_plus_one = bit32.band(bit32.rshift(addr_value, 8) + 1, 0xFF)
		write_op(bit32.band(sp, high_plus_one))
	end

	function op_shy()
		local high_plus_one = bit32.band(bit32.rshift(addr_value, 8) + 1, 0xFF)
		local value = bit32.band(y, high_plus_one)
		addr_value = bit32.bor(bit32.lshift(value, 8), bit32.band(addr_value, 0xFF))
		write_op(value)
	end

	function op_shx()
		local high_plus_one = bit32.band(bit32.rshift(addr_value, 8) + 1, 0xFF)
		local value = bit32.band(x, high_plus_one)
		addr_value = bit32.bor(bit32.lshift(value, 8), bit32.band(addr_value, 0xFF))
		write_op(value)
	end

	function op_jam()
		pc = bit32.band(pc - 1, 0xFFFF)
		cpu_jammed = true
	end

	function op_nop_read()
		read_op()
	end

	function ill()
	end

	opcodes = {
		[0x00] = {brk, imp, 7}, [0x01] = {ora, izx, 6}, [0x05] = {ora, zp, 3},
		[0x06] = {asl, zp, 5}, [0x08] = {php, imp, 3}, [0x09] = {ora, imm, 2},
		[0x0A] = {asl_a, acc, 2}, [0x0D] = {ora, abs, 4}, [0x0E] = {asl, abs, 6},
		[0x10] = {function() branch(not bit32.btest(status, 128)) end, rel, 2}, [0x11] = {ora, izy, 5}, [0x15] = {ora, zpx, 4},
		[0x16] = {asl, zpx, 6}, [0x18] = {function() set_flag(1, false) end, imp, 2}, [0x19] = {ora, aby, 4},
		[0x1D] = {ora, abx, 4}, [0x1E] = {asl, abx, 7},
		[0x20] = {jsr, abs, 6}, [0x21] = {op_and, izx, 6}, [0x24] = {op_bit, zp, 3},
		[0x25] = {op_and, zp, 3}, [0x26] = {rol, zp, 5}, [0x28] = {plp, imp, 4},
		[0x29] = {op_and, imm, 2}, [0x2A] = {rol_a, acc, 2}, [0x2C] = {op_bit, abs, 4},
		[0x2D] = {op_and, abs, 4}, [0x2E] = {rol, abs, 6},
		[0x30] = {function() branch(bit32.btest(status, 128)) end, rel, 2}, [0x31] = {op_and, izy, 5}, [0x35] = {op_and, zpx, 4},
		[0x36] = {rol, zpx, 6}, [0x38] = {function() set_flag(1, true) end, imp, 2}, [0x39] = {op_and, aby, 4},
		[0x3D] = {op_and, abx, 4}, [0x3E] = {rol, abx, 7},
		[0x40] = {rti, imp, 6}, [0x41] = {eor, izx, 6}, [0x45] = {eor, zp, 3},
		[0x46] = {lsr, zp, 5}, [0x48] = {pha, imp, 3}, [0x49] = {eor, imm, 2},
		[0x4A] = {lsr_a, acc, 2}, [0x4C] = {jmp, abs, 3}, [0x4D] = {eor, abs, 4},
		[0x4E] = {lsr, abs, 6},
		[0x50] = {function() branch(not bit32.btest(status, 64)) end, rel, 2}, [0x51] = {eor, izy, 5}, [0x55] = {eor, zpx, 4},
		[0x56] = {lsr, zpx, 6}, [0x58] = {function() set_flag(4, false) end, imp, 2}, [0x59] = {eor, aby, 4},
		[0x5D] = {eor, abx, 4}, [0x5E] = {lsr, abx, 7},
		[0x60] = {rts, imp, 6}, [0x61] = {adc, izx, 6}, [0x65] = {adc, zp, 3},
		[0x66] = {ror, zp, 5}, [0x68] = {pla, imp, 4}, [0x69] = {adc, imm, 2},
		[0x6A] = {ror_a, acc, 2}, [0x6C] = {jmp, ind, 5}, [0x6D] = {adc, abs, 4},
		[0x6E] = {ror, abs, 6},
		[0x70] = {function() branch(bit32.btest(status, 64)) end, rel, 2}, [0x71] = {adc, izy, 5}, [0x75] = {adc, zpx, 4},
		[0x76] = {ror, zpx, 6}, [0x78] = {function() set_flag(4, true) end, imp, 2}, [0x79] = {adc, aby, 4},
		[0x7D] = {adc, abx, 4}, [0x7E] = {ror, abx, 7},
		[0x81] = {sta, izx, 6}, [0x84] = {sty, zp, 3}, [0x85] = {sta, zp, 3},
		[0x86] = {stx, zp, 3}, [0x88] = {dey, imp, 2}, [0x8A] = {txa, imp, 2},
		[0x8C] = {sty, abs, 4}, [0x8D] = {sta, abs, 4}, [0x8E] = {stx, abs, 4},
		[0x90] = {function() branch(not bit32.btest(status, 1)) end, rel, 2}, [0x91] = {sta, izy, 6}, [0x94] = {sty, zpx, 4},
		[0x95] = {sta, zpx, 4}, [0x96] = {stx, zpy, 4}, [0x98] = {tya, imp, 2},
		[0x99] = {sta, aby, 5}, [0x9A] = {txs, imp, 2}, [0x9D] = {sta, abx, 5},
		[0xA0] = {ldy, imm, 2}, [0xA1] = {lda, izx, 6}, [0xA2] = {ldx, imm, 2},
		[0xA4] = {ldy, zp, 3}, [0xA5] = {lda, zp, 3}, [0xA6] = {ldx, zp, 3},
		[0xA8] = {tay, imp, 2}, [0xA9] = {lda, imm, 2}, [0xAA] = {tax, imp, 2},
		[0xAC] = {ldy, abs, 4}, [0xAD] = {lda, abs, 4}, [0xAE] = {ldx, abs, 4},
		[0xB0] = {function() branch(bit32.btest(status, 1)) end, rel, 2}, [0xB1] = {lda, izy, 5}, [0xB4] = {ldy, zpx, 4},
		[0xB5] = {lda, zpx, 4}, [0xB6] = {ldx, zpy, 4}, [0xB8] = {function() set_flag(64, false) end, imp, 2},
		[0xB9] = {lda, aby, 4}, [0xBA] = {tsx, imp, 2}, [0xBC] = {ldy, abx, 4},
		[0xBD] = {lda, abx, 4}, [0xBE] = {ldx, aby, 4},
		[0xC0] = {cpy, imm, 2}, [0xC1] = {cmp, izx, 6}, [0xC4] = {cpy, zp, 3},
		[0xC5] = {cmp, zp, 3}, [0xC6] = {dec, zp, 5}, [0xC8] = {iny, imp, 2},
		[0xC9] = {cmp, imm, 2}, [0xCA] = {dex, imp, 2}, [0xCC] = {cpy, abs, 4},
		[0xCD] = {cmp, abs, 4}, [0xCE] = {dec, abs, 6},
		[0xD0] = {function() branch(not bit32.btest(status, 2)) end, rel, 2}, [0xD1] = {cmp, izy, 5}, [0xD5] = {cmp, zpx, 4},
		[0xD6] = {dec, zpx, 6}, [0xD8] = {function() set_flag(8, false) end, imp, 2}, [0xD9] = {cmp, aby, 4},
		[0xDD] = {cmp, abx, 4}, [0xDE] = {dec, abx, 7},
		[0xE0] = {cpx, imm, 2}, [0xE1] = {sbc, izx, 6}, [0xE4] = {cpx, zp, 3},
		[0xE5] = {sbc, zp, 3}, [0xE6] = {inc, zp, 5}, [0xE8] = {inx, imp, 2},
		[0xE9] = {sbc, imm, 2}, [0xEA] = {imp, imp, 2}, [0xEC] = {cpx, abs, 4},
		[0xED] = {sbc, abs, 4}, [0xEE] = {inc, abs, 6},
		[0xF0] = {function() branch(bit32.btest(status, 2)) end, rel, 2}, [0xF1] = {sbc, izy, 5}, [0xF5] = {sbc, zpx, 4},
		[0xF6] = {inc, zpx, 6}, [0xF8] = {function() set_flag(8, true) end, imp, 2}, [0xF9] = {sbc, aby, 4},
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
end

local indexed_dummy_always = buffer.create(256) do
	local list = {
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
	
	for _, opcode in list do
		buffer.writeu8(indexed_dummy_always, opcode, 1)
	end
end

local page_cross_penalty = buffer.create(256) do
	local list = {
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
	
	for _, opcode in list do
		buffer.writeu8(page_cross_penalty, opcode, 1)
	end
end

local opcode_execute = table.create(256)

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
				page_crossed = false
				indexed_dummy_valid = false
				indexed_dummy_addr = 0
				cycles = base_cycles

				addr_exec()
				if indexed_dummy_valid then
					bus_read(indexed_dummy_addr)
				end

				op_exec()

				if page_crossed then
					cycles += 1
				end
			end
		else
			opcode_execute[opcode] = function()
				page_crossed = false
				indexed_dummy_valid = false
				indexed_dummy_addr = 0
				cycles = base_cycles

				addr_exec()
				if indexed_dummy_valid then
					bus_read(indexed_dummy_addr)
				end

				op_exec()
			end
		end
	elseif has_page_cross_penalty then
		opcode_execute[opcode] = function()
			page_crossed = false
			indexed_dummy_valid = false
			indexed_dummy_addr = 0
			cycles = base_cycles

			addr_exec()
			if indexed_dummy_valid and page_crossed then
				bus_read(indexed_dummy_addr)
			end

			op_exec()

			if page_crossed then
				cycles += 1
			end
		end
	else
		opcode_execute[opcode] = function()
			page_crossed = false
			indexed_dummy_valid = false
			indexed_dummy_addr = 0
			cycles = base_cycles

			addr_exec()
			op_exec()
		end
	end
end

local function reset()
	sp = 0xFD
	status = bit32.bor(bit32.band(status, 0xCF), 0x24)
	set_flag(4, true)
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
	frame_index = 0
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
	buffer.fill(bg_data, 0, 0, FRAME_WIDTH)
	sprite_scanline_generation = 1
	buffer.fill(sprite_scanline_stamp, 0, 0, FRAME_WIDTH)
	buffer.fill(sprite_scanline_color, 0, 0, FRAME_WIDTH)
	buffer.fill(sprite_scanline_meta, 0, 0, FRAME_WIDTH)
	buffer.fill(sprite_x, 0, 0, 8)
	buffer.fill(sprite_tile, 0, 0, 8)
	buffer.fill(sprite_low, 0, 0, 8)
	buffer.fill(sprite_high, 0, 0, 8)
	buffer.fill(sprite_meta, 0, 0, 8)
	buffer.fill(sprite_x_next, 0, 0, 8)
	buffer.fill(sprite_tile_next, 0, 0, 8)
	buffer.fill(sprite_low_next, 0, 0, 8)
	buffer.fill(sprite_high_next, 0, 0, 8)
	buffer.fill(sprite_meta_next, 0, 0, 8)
	for i = 1, 8 do
		sprite_pattern_addr[i] = 0x1FF0
		sprite_pattern_addr_next[i] = 0x1FF0
	end
	reset_bg_pipeline()

	if mapper ~= nil then
		mapper.reset()
		if mapper_get_mirroring ~= nil then
			mirroring_mode = mapper_get_mirroring()
		end
	end

	apu_reset()
	pc = read16(0xFFFC)
end

local function nmi(): number
	push(bit32.rshift(pc, 8))
	push(bit32.band(pc, 0xFF))
	
	push(bit32.bor(bit32.band(status, 0xEF), 0x20))
	set_flag(4, true)
	pc = read16(0xFFFA)
	return 7
end

local function irq(): number
	push(bit32.rshift(pc, 8))
	push(bit32.band(pc, 0xFF))
	
	push(bit32.bor(bit32.band(status, 0xEF), 0x20))
	set_flag(4, true)
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
	pc = bit32.band(pc + 1, 0xFFFF)
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

	prg_banks = buffer.readu8(rom, 4)
	chr_banks = buffer.readu8(rom, 5)

	local flags6 = buffer.readu8(rom, 6)
	local flags7 = buffer.readu8(rom, 7)
	local flags8 = buffer.readu8(rom, 8)

	local mapper_number = bit32.bor(
		bit32.rshift(bit32.band(flags6, 0xF0), 4),
		bit32.band(flags7, 0xF0)
	)

	mapper_id = mapper_number
	assert(Mappers.supports(mapper_id), string.format("Unsupported mapper: %d", mapper_id))

	four_screen_mode = bit32.btest(flags6, 0x08)
	if four_screen_mode then
		mirroring_mode = 2
	else
		mirroring_mode = bit32.band(flags6, 0x01) == 0 and 3 or 2
	end

	local has_trainer = bit32.btest(flags6, 0x04)
	local has_battery = bit32.btest(flags6, 0x02)

	local prg_ram_units = flags8
	if prg_ram_units == 0 then
		prg_ram_units = 1
	end
	local prg_ram_size = prg_ram_units * 0x2000

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
		chr_size = 8192
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
		vram = vram,
	})

	bind_mapper(created_mapper)
	if mapper_get_mirroring ~= nil then
		mirroring_mode = mapper_get_mirroring()
	end

	buffer.fill(prg_ram, 0, 0, prg_ram_len)
	buffer.fill(ram, 0, 0, 0x800)
	buffer.fill(vram, 0, 0, 0x1000)
	buffer.fill(oam, 0, 0, 0x100)
	buffer.fill(palette, 0, 0, PALETTE_SIZE)

	for i = 0, PALETTE_SIZE - 1 do
		sync_palette_cache(i)
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
	frame_index = 0
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
	buffer.fill(bg_data, 0, 0, FRAME_WIDTH)
	sprite_scanline_generation = 1
	buffer.fill(sprite_scanline_stamp, 0, 0, FRAME_WIDTH)
	buffer.fill(sprite_scanline_color, 0, 0, FRAME_WIDTH)
	buffer.fill(sprite_scanline_meta, 0, 0, FRAME_WIDTH)
	buffer.fill(sprite_x, 0, 0, 8)
	buffer.fill(sprite_tile, 0, 0, 8)
	buffer.fill(sprite_low, 0, 0, 8)
	buffer.fill(sprite_high, 0, 0, 8)
	buffer.fill(sprite_meta, 0, 0, 8)
	buffer.fill(sprite_x_next, 0, 0, 8)
	buffer.fill(sprite_tile_next, 0, 0, 8)
	buffer.fill(sprite_low_next, 0, 0, 8)
	buffer.fill(sprite_high_next, 0, 0, 8)
	buffer.fill(sprite_meta_next, 0, 0, 8)
	for i = 1, 8 do
		sprite_pattern_addr[i] = 0x1FF0
		sprite_pattern_addr_next[i] = 0x1FF0
	end
	reset_bg_pipeline()

	apu_reset()
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
			elseif (apu_irq_pending() or mapper_irq_pending and mapper_irq_pending()) and not bit32.btest(status, 4) then
				begin_cpu_event()
				local irq_cycles = irq()
				finalize_cpu_event(irq_cycles)
			else
				step()
			end
		end

		local ready = frame_ready
		frame_ready = false
		return if ready then framebuffer else nil
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
	
	setAudioParent = apu.setAudioParent,
	setAudioEnabled = apu.setAudioEnabled,
	setMasterVolume = apu.setMasterVolume,

	size = Vector2.new(FRAME_WIDTH, FRAME_HEIGHT),

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

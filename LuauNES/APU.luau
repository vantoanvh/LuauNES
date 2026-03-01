--!native
--!nocheck
--!optimize 2

local ASSETS = {
	pulse_12_5 = "rbxassetid://137987182789405",
	pulse_25 = "rbxassetid://108267815293395",
	pulse_50 = "rbxassetid://74193770330344",
	pulse_75 = "rbxassetid://100273244108902",
	triangle = "rbxassetid://135072236414372",
	noise_mix = "rbxassetid://137650960613979",
}

type SoundAssetIds = {[string]: string}
export type SoundAssetIdOverrides = {[string]: string | number}

type DmcReader = (number) -> number

export type APUInstance = {
	step: (number) -> (),
	readStatus: () -> number,
	write: (number, number) -> (),
	writeMmc5: (number, number) -> (),
	readMmc5: (number) -> number,
	onMmc5CpuRead: (number, number) -> (),
	setMmc5Enabled: (boolean) -> (),
	reset: () -> (),
	irqPending: () -> boolean,
	consumeDmaStallCycles: () -> number,
}

return function (dmc_reader: DmcReader): APUInstance
	local apu_frame_irq = false
	local apu_dmc_irq = false

	-- narrow luau bridge optimization
	local _, newindex = xpcall(function() game._____ = {} end, function() return debug.info(2, "f") end)

	local CPU_CLOCK_HZ = 1789773
	local APU_FRAME_4_LENGTH = 29830
	local APU_FRAME_5_LENGTH = 37282
	local APU_FRAME_Q1 = 7457
	local APU_FRAME_Q2 = 14913
	local APU_FRAME_Q3 = 22371
	local APU_FRAME_Q4_4STEP = 29829
	local APU_FRAME_Q4_5STEP = 37281

	local LENGTH_TABLE = {
		10, 254, 20, 2, 40, 4, 80, 6,
		160, 8, 60, 10, 14, 12, 26, 14,
		12, 16, 24, 18, 48, 20, 96, 22,
		192, 24, 72, 26, 16, 28, 32, 30
	}

	local LENGTH_BUFFER = buffer.create(#LENGTH_TABLE)

	for i, v in LENGTH_TABLE do
		buffer.writeu8(LENGTH_BUFFER, i - 1, v)
	end

	local DMC_PERIOD_TABLE = {
		428, 380, 340, 320, 286, 254, 226, 214,
		190, 160, 142, 128, 106, 85, 72, 54
	}

	local PULSE_GAIN_TRIM = 1.00
	local TRIANGLE_GAIN_TRIM = 1.00
	local NOISE_GAIN_TRIM = 1.00
	local DMC_GAIN_TRIM = 1.00
	local MMC5_PULSE_GAIN_TRIM = 0.22
	local DMC_MIX_REFRESH_CYCLES = 1

	local SOURCE_BASE_FREQUENCY_HZ = 441 -- must match manifest actual_base_frequency_hz
	local PULSE_SPEED_NUM = CPU_CLOCK_HZ / (16 * SOURCE_BASE_FREQUENCY_HZ)
	local TRIANGLE_SPEED_NUM = CPU_CLOCK_HZ / (32 * SOURCE_BASE_FREQUENCY_HZ)

	local channel_enabled_mask = 0

	local pulse_control = { 0, 0 }
	local pulse_sweep = { 0, 0 }
	local pulse_timer_low = { 0, 0 }
	local pulse_timer = { 0, 0 }
	local pulse_length = { 0, 0 }
	local pulse_envelope_start = { false, false }
	local pulse_envelope_divider = { 0, 0 }
	local pulse_envelope_decay = { 0, 0 }
	local pulse_sweep_divider = { 0, 0 }
	local pulse_sweep_reload = { false, false }

	local triangle_control = 0
	local triangle_timer_low = 0
	local triangle_timer = 0
	local triangle_length = 0
	local triangle_linear_reload_value = 0
	local triangle_linear_counter = 0
	local triangle_linear_reload = false

	local noise_control = 0
	local noise_period_index = 0
	local noise_length = 0
	local noise_envelope_start = false
	local noise_envelope_divider = 0
	local noise_envelope_decay = 0
	local noise_short_mode = false

	local dmc_irq_enabled = false
	local dmc_loop = false
	local dmc_period_index = 0
	local dmc_timer_counter = DMC_PERIOD_TABLE[1]
	local dmc_output_level = 0
	local dmc_sample_addr_reg = 0
	local dmc_sample_length_reg = 0
	local dmc_current_addr = 0xC000
	local dmc_bytes_remaining = 0
	local dmc_shift = 0
	local dmc_bits_remaining = 8
	local dmc_buffer = 0
	local dmc_buffer_empty = true
	local dmc_silence = true
	local dmc_dma_stall_cycles = 0

	local mmc5_enabled = false
	local mmc5_pulse_control = { 0, 0 }
	local mmc5_pulse_timer_low = { 0, 0 }
	local mmc5_pulse_timer = { 0, 0 }
	local mmc5_pulse_running = 0
	local mmc5_pulse_enable = 0
	local mmc5_pcm_control = 0
	local mmc5_pcm_irq_enabled = false
	local mmc5_pcm_irq_trip = false
	local mmc5_pcm_read_mode = false

	local apu_irq_inhibit = true
	local apu_frame_mode_5step = false
	local apu_frame_cycle = 0
	local dmc_mix_pending = false
	local dmc_mix_counter = 0

	local MASTER_SAMPLE_RATE = 44100
	local MASTER_REGION_SOURCE_SECONDS = 4.0
	local MASTER_OUTPUT_GAIN = 1.00
	local REGION_GUARD_SAMPLES = 2048
	local NOISE_PERIOD_TABLE = {
		4, 8, 16, 32, 64, 96, 128, 160,
		202, 254, 380, 508, 762, 1016, 2034, 4068
	}
	local NOISE_LONG_CYCLE_BITS = 32767
	local NOISE_SHORT_CYCLE_BITS = 93
	local NOISE_MIN_REGION_SECONDS = 0.10
	local PULSE_ASSET_KEYS = {
		"pulse_12_5",
		"pulse_25",
		"pulse_50",
		"pulse_75",
	}

	local function round_to_nearest(value: number): number
		return math.floor(value + 0.5)
	end

	local function round_div_nearest(numerator: number, denominator: number): number
		return math.floor(((numerator * 2) + denominator) / (denominator * 2))
	end

	local function samples_to_seconds(sample_count: number): number
		return sample_count / MASTER_SAMPLE_RATE
	end

	local function build_packed_regions(sample_counts: {number}): {NumberRange}
		local cursor = 0
		local regions = table.create(#sample_counts) :: {NumberRange}
		for i, sample_count in sample_counts do
			local start_sample = cursor
			cursor += sample_count
			local region = NumberRange.new(samples_to_seconds(start_sample), samples_to_seconds(cursor))
			cursor += REGION_GUARD_SAMPLES
			regions[i] = region
		end
		return regions
	end

	local function build_noise_region_banks(): ({NumberRange}, {NumberRange})
		local cursor = 0
		local min_region_samples = math.max(1, round_to_nearest(NOISE_MIN_REGION_SECONDS * MASTER_SAMPLE_RATE))

		local function allocate_region(sample_count: number): NumberRange
			local start_sample = cursor
			cursor += sample_count
			local region = NumberRange.new(samples_to_seconds(start_sample), samples_to_seconds(cursor))
			cursor += REGION_GUARD_SAMPLES
			return region
		end

		local function build_regions(cycle_bits: number): {NumberRange}
			local regions = table.create(#NOISE_PERIOD_TABLE) :: {NumberRange}
			for i, period in NOISE_PERIOD_TABLE do
				local base_cycle_samples = math.max(
					1,
					round_div_nearest(cycle_bits * period * MASTER_SAMPLE_RATE, CPU_CLOCK_HZ)
				)
				local cycle_repeats = math.max(1, math.ceil(min_region_samples / base_cycle_samples))
				local sample_count = base_cycle_samples * cycle_repeats
				regions[i] = allocate_region(sample_count)
			end
			return regions
		end

		local long_regions = build_regions(NOISE_LONG_CYCLE_BITS)
		local short_regions = build_regions(NOISE_SHORT_CYCLE_BITS)
		return long_regions, short_regions
	end

	local function build_dmc_regions(): {NumberRange}
		local source_region_samples = math.max(1, round_to_nearest(MASTER_REGION_SOURCE_SECONDS * MASTER_SAMPLE_RATE))
		local sample_counts = table.create(#DMC_PERIOD_TABLE) :: {number}
		for i = 1, #DMC_PERIOD_TABLE do
			sample_counts[i] = source_region_samples
		end
		return build_packed_regions(sample_counts)
	end

	local NOISE_LONG_REGIONS, NOISE_SHORT_REGIONS = build_noise_region_banks()
	local DMC_REGIONS = build_dmc_regions()

	local function create_looped_sound(name: string, asset_key: string, region: NumberRange?): Sound
		local sound = Instance.new("Sound")
		sound.Name = name
		sound.Looped = true
		sound.Volume = 0
		sound.SoundId = ASSETS[asset_key] or ""
		sound.PlaybackSpeed = 1
		sound.Parent = script
		if region ~= nil then
			sound.PlaybackRegionsEnabled = true
			sound.LoopRegion = region
			sound.PlaybackRegion = region
			sound.TimePosition = region.Min
		end
		sound:Play()
		return sound
	end

	local pulse_sound_bank = { {} :: {Sound}, {} :: {Sound} }
	for channel = 1, 2 do
		local prefix = `Pulse_{channel}`
		local bank = pulse_sound_bank[channel]
		for duty = 1, #PULSE_ASSET_KEYS do
			bank[duty] = create_looped_sound(prefix .. "_" .. duty, PULSE_ASSET_KEYS[duty], nil)
		end
	end

	local mmc5_pulse_sound_bank = { {} :: {Sound}, {} :: {Sound} }
	for channel = 1, 2 do
		local prefix = `MMC5_{channel}`
		local bank = mmc5_pulse_sound_bank[channel]
		for duty = 1, #PULSE_ASSET_KEYS do
			bank[duty] = create_looped_sound(prefix .. "_" .. duty, PULSE_ASSET_KEYS[duty], nil)
		end
	end

	local triangle_sound = create_looped_sound("Triangle", "triangle", nil)

	local function create_region_bank(prefix: string, asset_key: string, regions: {NumberRange}): {Sound}
		local bank = table.create(#regions) :: {Sound}
		for i = 1, #regions do
			bank[i] = create_looped_sound(prefix .. i, asset_key, regions[i])
		end
		return bank
	end

	local noise_long_sound_bank = create_region_bank("NoiseLong", "noise_mix", NOISE_LONG_REGIONS)
	local noise_short_sound_bank = create_region_bank("NoiseShort", "noise_mix", NOISE_SHORT_REGIONS)

	local function dmc_restart_sample()
		dmc_current_addr = bit32.bor(0xC000, bit32.lshift(dmc_sample_addr_reg, 6))
		dmc_bytes_remaining = bit32.lshift(dmc_sample_length_reg, 4) + 1
	end

	local function dmc_try_fill_buffer()
		if dmc_buffer_empty and dmc_bytes_remaining > 0 then
			dmc_buffer = bit32.band(dmc_reader(dmc_current_addr), 0xFF)
			dmc_buffer_empty = false
			dmc_dma_stall_cycles += 4
			dmc_current_addr = bit32.band(dmc_current_addr + 1, 0xFFFF)

			if dmc_current_addr == 0 then
				dmc_current_addr = 0x8000
			end

			dmc_bytes_remaining -= 1
			if dmc_bytes_remaining <= 0 then
				dmc_bytes_remaining = 0
				if dmc_loop then
					dmc_restart_sample()
				elseif dmc_irq_enabled then
					apu_dmc_irq = true
				end
			end
		end
	end

	local function dmc_clock_output(): boolean
		local level_before = dmc_output_level
		local silence_before = dmc_silence

		if dmc_silence == false then
			if bit32.btest(dmc_shift, 0x01) then
				if dmc_output_level <= 125 then
					dmc_output_level += 2
				end
			else
				if dmc_output_level >= 2 then
					dmc_output_level -= 2
				end
			end
		end

		dmc_shift = bit32.rshift(dmc_shift, 1)
		dmc_bits_remaining -= 1

		if dmc_bits_remaining <= 0 then
			dmc_bits_remaining = 8
			if dmc_buffer_empty then
				dmc_silence = true
			else
				dmc_silence = false
				dmc_shift = dmc_buffer
				dmc_buffer_empty = true
			end
		end

		dmc_try_fill_buffer()

		return dmc_output_level ~= level_before or dmc_silence ~= silence_before
	end

	local function pulse_muted(index: number): boolean
		if not bit32.btest(channel_enabled_mask, bit32.lshift(1, index - 1)) then
			return true
		end

		if pulse_length[index] <= 0 then
			return true
		end

		if pulse_timer[index] < 8 or pulse_timer[index] > 0x7FF then
			return true
		end

		local sweep = pulse_sweep[index]
		local shift = bit32.band(sweep, 0x07)
		if bit32.btest(sweep, 0x80) and shift > 0 then
			local timer = pulse_timer[index]
			local delta = bit32.rshift(timer, shift)
			local target = if bit32.btest(sweep, 0x08)
				then timer - delta - (if index == 1 then 1 else 0)
				else timer + delta
			if target > 0x7FF then
				return true
			end
		end

		return false
	end


	local function update_audio_mixer()
		dmc_mix_pending = false
		dmc_mix_counter = 0

		local pulse1_raw = 0
		if not pulse_muted(1) then
			local control = pulse_control[1]
			pulse1_raw = if bit32.btest(control, 0x10) then bit32.band(control, 0x0F) else pulse_envelope_decay[1]
		end

		local pulse2_raw = 0
		if not pulse_muted(2) then
			local control = pulse_control[2]
			pulse2_raw = if bit32.btest(control, 0x10) then bit32.band(control, 0x0F) else pulse_envelope_decay[2]
		end

		local triangle_raw = 0
		if bit32.btest(channel_enabled_mask, 0x04) and triangle_length > 0 and triangle_linear_counter > 0 and triangle_timer > 1 then
			triangle_raw = 15
		end

		local noise_raw = 0
		if bit32.btest(channel_enabled_mask, 0x08) and noise_length > 0 then
			noise_raw = if bit32.btest(noise_control, 0x10) then bit32.band(noise_control, 0x0F) else noise_envelope_decay
		end

		local dmc_raw = dmc_output_level
		local mmc5_pulse1_raw = 0
		local mmc5_pulse2_raw = 0

		if mmc5_enabled and bit32.btest(mmc5_pulse_enable, 0x01) and bit32.btest(mmc5_pulse_running, 0x01) and mmc5_pulse_timer[1] >= 8 then
			mmc5_pulse1_raw = bit32.band(mmc5_pulse_control[1], 0x0F)
		end
		if mmc5_enabled and bit32.btest(mmc5_pulse_enable, 0x02) and bit32.btest(mmc5_pulse_running, 0x02) and mmc5_pulse_timer[2] >= 8 then
			mmc5_pulse2_raw = bit32.band(mmc5_pulse_control[2], 0x0F)
		end

		local pulse_total = pulse1_raw + pulse2_raw
		local pulse_mix = if pulse_total > 0 then 95.88 / ((8128 / pulse_total) + 100) else 0
		local pulse1_gain = 0
		local pulse2_gain = 0
		if pulse_mix > 0 and pulse_total > 0 then
			pulse1_gain = pulse_mix * (pulse1_raw / pulse_total)
			pulse2_gain = pulse_mix * (pulse2_raw / pulse_total)
		end
		pulse1_gain *= PULSE_GAIN_TRIM
		pulse2_gain *= PULSE_GAIN_TRIM

		local mmc5_pulse_total = mmc5_pulse1_raw + mmc5_pulse2_raw
		local mmc5_pulse1_gain = 0
		local mmc5_pulse2_gain = 0

		if mmc5_pulse_total > 0 then
			local mmc5_gain = MMC5_PULSE_GAIN_TRIM * (mmc5_pulse_total / 30)
			mmc5_pulse1_gain = mmc5_gain * (mmc5_pulse1_raw / mmc5_pulse_total)
			mmc5_pulse2_gain = mmc5_gain * (mmc5_pulse2_raw / mmc5_pulse_total)
		end

		local triangle_term = triangle_raw / 8227
		local noise_term = noise_raw / 12241
		local dmc_term = dmc_raw / 22638

		local tnd_total = triangle_term + noise_term + dmc_term
		local tnd_mix = if tnd_total > 0 then 159.79 / ((1 / tnd_total) + 100) else 0

		local triangle_gain = 0
		local noise_gain = 0
		local dmc_gain = 0

		if tnd_mix > 0 and tnd_total > 0 then
			triangle_gain = tnd_mix * (triangle_term / tnd_total)
			noise_gain = tnd_mix * (noise_term / tnd_total)
			dmc_gain = tnd_mix * (dmc_term / tnd_total)
		end

		triangle_gain *= TRIANGLE_GAIN_TRIM
		noise_gain *= NOISE_GAIN_TRIM
		dmc_gain *= DMC_GAIN_TRIM

		if dmc_bytes_remaining <= 0 and dmc_buffer_empty and dmc_silence then
			dmc_gain = 0
		end

		pulse1_gain *= MASTER_OUTPUT_GAIN
		pulse2_gain *= MASTER_OUTPUT_GAIN
		mmc5_pulse1_gain *= MASTER_OUTPUT_GAIN
		mmc5_pulse2_gain *= MASTER_OUTPUT_GAIN
		triangle_gain *= MASTER_OUTPUT_GAIN
		noise_gain *= MASTER_OUTPUT_GAIN * 6.7
		dmc_gain *= MASTER_OUTPUT_GAIN * 0.5

		for channel = 1, 2 do
			local bank = pulse_sound_bank[channel]
			local raw_level = if channel == 1 then pulse1_raw else pulse2_raw
			if raw_level <= 0 then
				for i = 1, #bank do
					newindex(bank[i], "Volume", 0)
				end
			else
				local duty = bit32.band(bit32.rshift(pulse_control[channel], 6), 0x03) + 1
				local speed = PULSE_SPEED_NUM / (pulse_timer[channel] + 1)
				local gain = if channel == 1 then pulse1_gain else pulse2_gain

				for i = 1, #bank do
					local sound = bank[i]
					local target_volume = if i == duty then gain else 0
					newindex(sound, "PlaybackSpeed", speed)
					newindex(sound, "Volume", target_volume)
				end
			end
		end

		for channel = 1, 2 do
			local bank = mmc5_pulse_sound_bank[channel]
			local raw_level = if channel == 1 then mmc5_pulse1_raw else mmc5_pulse2_raw
			if raw_level <= 0 then
				for i = 1, #bank do
					newindex(bank[i], "Volume", 0)
				end
			else
				local duty = bit32.band(bit32.rshift(mmc5_pulse_control[channel], 6), 0x03) + 1
				local speed = PULSE_SPEED_NUM / (mmc5_pulse_timer[channel] + 1)
				local gain = if channel == 1 then mmc5_pulse1_gain else mmc5_pulse2_gain

				for i = 1, #bank do
					local sound = bank[i]
					local target_volume = if i == duty then gain else 0
					newindex(sound, "PlaybackSpeed", speed)
					newindex(sound, "Volume", target_volume)
				end
			end
		end

		if triangle_raw > 0 then
			newindex(triangle_sound, "PlaybackSpeed", TRIANGLE_SPEED_NUM / (triangle_timer + 1))
			newindex(triangle_sound, "Volume", triangle_gain)
		else
			newindex(triangle_sound, "Volume", 0)
		end

		if #noise_long_sound_bank > 0 and #noise_short_sound_bank > 0 then
			local active_index = noise_period_index + 1
			local active_bank = if noise_short_mode then noise_short_sound_bank else noise_long_sound_bank
			local inactive_bank = if noise_short_mode then noise_long_sound_bank else noise_short_sound_bank

			for i = 1, #active_bank do
				local target = if noise_raw > 0 and i == active_index then noise_gain else 0
				newindex(active_bank[i], "Volume", target)
			end
			for i = 1, #inactive_bank do
				newindex(inactive_bank[i], "Volume", 0)
			end
		end
	end

	local function clock_pulse_envelope(index: number)
		if pulse_envelope_start[index] then
			pulse_envelope_start[index] = false
			pulse_envelope_decay[index] = 15
			pulse_envelope_divider[index] = bit32.band(pulse_control[index], 0x0F)
			return
		end

		if pulse_envelope_divider[index] > 0 then
			pulse_envelope_divider[index] -= 1
			return
		end

		pulse_envelope_divider[index] = bit32.band(pulse_control[index], 0x0F)
		if pulse_envelope_decay[index] > 0 then
			pulse_envelope_decay[index] -= 1
		elseif bit32.btest(pulse_control[index], 0x20) then
			pulse_envelope_decay[index] = 15
		end
	end

	local function clock_noise_envelope()
		if noise_envelope_start then
			noise_envelope_start = false
			noise_envelope_decay = 15
			noise_envelope_divider = bit32.band(noise_control, 0x0F)
			return
		end

		if noise_envelope_divider > 0 then
			noise_envelope_divider -= 1
			return
		end

		noise_envelope_divider = bit32.band(noise_control, 0x0F)
		if noise_envelope_decay > 0 then
			noise_envelope_decay -= 1
		elseif bit32.btest(noise_control, 0x20) then
			noise_envelope_decay = 15
		end
	end

	local function clock_triangle_linear_counter()
		if triangle_linear_reload then
			triangle_linear_counter = triangle_linear_reload_value
		elseif triangle_linear_counter > 0 then
			triangle_linear_counter -= 1
		end

		if not bit32.btest(triangle_control, 0x80) then
			triangle_linear_reload = false
		end
	end

	local function clock_length_counters()
		for channel = 1, 2 do
			if pulse_length[channel] > 0 and not bit32.btest(pulse_control[channel], 0x20) then
				pulse_length[channel] -= 1
			end
		end

		if triangle_length > 0 and not bit32.btest(triangle_control, 0x80) then
			triangle_length -= 1
		end

		if noise_length > 0 and not bit32.btest(noise_control, 0x20) then
			noise_length -= 1
		end
	end

	local function clock_pulse_sweep(index: number)
		local sweep = pulse_sweep[index]
		local shift = bit32.band(sweep, 0x07)
		local divider_period = bit32.band(bit32.rshift(sweep, 4), 0x07)
		local timer = pulse_timer[index]
		local delta = if shift > 0 then bit32.rshift(timer, shift) else 0
		local target = if bit32.btest(sweep, 0x08)
			then timer - delta - (if index == 1 then 1 else 0)
			else timer + delta
		local enabled = bit32.btest(sweep, 0x80) and shift > 0

		if pulse_sweep_divider[index] == 0 then
			if enabled and timer >= 8 and target >= 0 and target <= 0x7FF then
				pulse_timer[index] = target
			end
			pulse_sweep_divider[index] = divider_period
		else
			pulse_sweep_divider[index] -= 1
		end

		if pulse_sweep_reload[index] then
			pulse_sweep_reload[index] = false
			pulse_sweep_divider[index] = divider_period
		end
	end

	local function apu_step(cycle_count: number)
		local should_mix = false
		local remaining = cycle_count
		local dmc_counter = dmc_timer_counter
		local mix_pending = dmc_mix_pending
		local mix_counter = dmc_mix_counter
		local frame_len = if apu_frame_mode_5step then APU_FRAME_5_LENGTH else APU_FRAME_4_LENGTH
		local frame_q4 = if apu_frame_mode_5step then APU_FRAME_Q4_5STEP else APU_FRAME_Q4_4STEP
		if dmc_counter <= 0 then
			dmc_counter = DMC_PERIOD_TABLE[dmc_period_index + 1]
		end

		while remaining > 0 do
			local event_cycle = frame_q4
			if apu_frame_cycle < APU_FRAME_Q1 then
				event_cycle = APU_FRAME_Q1
			elseif apu_frame_cycle < APU_FRAME_Q2 then
				event_cycle = APU_FRAME_Q2
			elseif apu_frame_cycle < APU_FRAME_Q3 then
				event_cycle = APU_FRAME_Q3
			elseif apu_frame_cycle < frame_q4 then
				event_cycle = frame_q4
			end
			local until_event = event_cycle - apu_frame_cycle
			local until_wrap = frame_len - apu_frame_cycle
			local until_dmc = dmc_counter

			local advance = remaining
			if until_event > 0 and until_event < advance then
				advance = until_event
			end
			if until_wrap > 0 and until_wrap < advance then
				advance = until_wrap
			end
			if until_dmc > 0 and until_dmc < advance then
				advance = until_dmc
			end

			apu_frame_cycle += advance
			dmc_counter -= advance
			mix_counter += advance
			remaining -= advance

			local clock_quarter = false
			local clock_half = false
			local set_irq = false
			if apu_frame_cycle == APU_FRAME_Q1 or apu_frame_cycle == APU_FRAME_Q3 then
				clock_quarter = true
			elseif apu_frame_cycle == APU_FRAME_Q2 then
				clock_quarter = true
				clock_half = true
			elseif apu_frame_mode_5step then
				if apu_frame_cycle == APU_FRAME_Q4_5STEP then
					clock_quarter = true
					clock_half = true
				end
			elseif apu_frame_cycle == APU_FRAME_Q4_4STEP then
				clock_quarter = true
				clock_half = true
				set_irq = true
			end

			if clock_quarter then
				clock_pulse_envelope(1)
				clock_pulse_envelope(2)
				clock_noise_envelope()
				clock_triangle_linear_counter()
				should_mix = true
			end

			if clock_half then
				clock_length_counters()
				clock_pulse_sweep(1)
				clock_pulse_sweep(2)
				should_mix = true
			end

			if set_irq and not apu_irq_inhibit then
				apu_frame_irq = true
			end

			if apu_frame_cycle >= frame_len then
				apu_frame_cycle = 0
			end

			if dmc_counter <= 0 then
				if dmc_clock_output() then
					mix_pending = true
				end
				dmc_counter = DMC_PERIOD_TABLE[dmc_period_index + 1]
			end

			if mix_pending and mix_counter >= DMC_MIX_REFRESH_CYCLES then
				should_mix = true
				mix_pending = false
				mix_counter = bit32.band(mix_counter, DMC_MIX_REFRESH_CYCLES - 1)
			end
		end

		dmc_timer_counter = dmc_counter
		dmc_mix_pending = mix_pending
		dmc_mix_counter = mix_counter

		if should_mix then
			update_audio_mixer()
			dmc_mix_pending = false
			dmc_mix_counter = 0
		end
	end

	local function apu_read_status(): number
		local value = 0

		if pulse_length[1] > 0 then
			value = bit32.bor(value, 0x01)
		end
		if pulse_length[2] > 0 then
			value = bit32.bor(value, 0x02)
		end
		if triangle_length > 0 then
			value = bit32.bor(value, 0x04)
		end
		if noise_length > 0 then
			value = bit32.bor(value, 0x08)
		end
		if dmc_bytes_remaining > 0 then
			value = bit32.bor(value, 0x10)
		end
		if apu_frame_irq then
			value = bit32.bor(value, 0x40)
		end
		if apu_dmc_irq then
			value = bit32.bor(value, 0x80)
		end

		apu_frame_irq = false
		return value
	end

	local function apu_write(addr: number, value: number)
		local LENGTH_BUF = LENGTH_BUFFER

		addr = bit32.band(addr, 0xFFFF)
		value = bit32.band(value, 0xFF)

		if addr == 0x4000 then
			pulse_control[1] = value
		elseif addr == 0x4001 then
			pulse_sweep[1] = value
			pulse_sweep_reload[1] = true
		elseif addr == 0x4002 then
			pulse_timer_low[1] = value
			pulse_timer[1] = bit32.bor(bit32.band(pulse_timer[1], 0x0700), value)
		elseif addr == 0x4003 then
			pulse_timer[1] = bit32.bor(bit32.lshift(bit32.band(value, 0x07), 8), pulse_timer_low[1])
			if bit32.btest(channel_enabled_mask, 0x01) then
				pulse_length[1] = buffer.readu8(LENGTH_BUF, bit32.rshift(value, 3))
			end
			pulse_envelope_start[1] = true
		elseif addr == 0x4004 then
			pulse_control[2] = value
		elseif addr == 0x4005 then
			pulse_sweep[2] = value
			pulse_sweep_reload[2] = true
		elseif addr == 0x4006 then
			pulse_timer_low[2] = value
			pulse_timer[2] = bit32.bor(bit32.band(pulse_timer[2], 0x0700), value)
		elseif addr == 0x4007 then
			pulse_timer[2] = bit32.bor(bit32.lshift(bit32.band(value, 0x07), 8), pulse_timer_low[2])
			if bit32.btest(channel_enabled_mask, 0x02) then
				pulse_length[2] = buffer.readu8(LENGTH_BUF, bit32.rshift(value, 3))
			end
			pulse_envelope_start[2] = true
		elseif addr == 0x4008 then
			triangle_control = value
			triangle_linear_reload_value = bit32.band(value, 0x7F)
		elseif addr == 0x400A then
			triangle_timer_low = value
			triangle_timer = bit32.bor(bit32.band(triangle_timer, 0x0700), value)
		elseif addr == 0x400B then
			triangle_timer = bit32.bor(bit32.lshift(bit32.band(value, 0x07), 8), triangle_timer_low)
			if bit32.btest(channel_enabled_mask, 0x04) then
				triangle_length = buffer.readu8(LENGTH_BUF, bit32.rshift(value, 3))
			end
			triangle_linear_reload = true
		elseif addr == 0x400C then
			noise_control = value
		elseif addr == 0x400E then
			noise_short_mode = bit32.btest(value, 0x80)
			noise_period_index = bit32.band(value, 0x0F)
		elseif addr == 0x400F then
			if bit32.btest(channel_enabled_mask, 0x08) then
				noise_length = buffer.readu8(LENGTH_BUF, bit32.rshift(value, 3))
			end
			noise_envelope_start = true
		elseif addr == 0x4010 then
			dmc_irq_enabled = bit32.btest(value, 0x80)
			dmc_loop = bit32.btest(value, 0x40)
			dmc_period_index = bit32.band(value, 0x0F)
			if not dmc_irq_enabled then
				apu_dmc_irq = false
			end
		elseif addr == 0x4011 then
			dmc_output_level = bit32.band(value, 0x7F)
		elseif addr == 0x4012 then
			dmc_sample_addr_reg = value
		elseif addr == 0x4013 then
			dmc_sample_length_reg = value
		elseif addr == 0x4015 then
			channel_enabled_mask = bit32.band(value, 0x1F)
			apu_dmc_irq = false
			if not bit32.btest(channel_enabled_mask, 0x01) then
				pulse_length[1] = 0
			end
			if not bit32.btest(channel_enabled_mask, 0x02) then
				pulse_length[2] = 0
			end
			if not bit32.btest(channel_enabled_mask, 0x04) then
				triangle_length = 0
			end
			if not bit32.btest(channel_enabled_mask, 0x08) then
				noise_length = 0
			end

			if not bit32.btest(channel_enabled_mask, 0x10) then
				dmc_bytes_remaining = 0
			elseif dmc_bytes_remaining == 0 then
				dmc_restart_sample()
				dmc_try_fill_buffer()
			end

			apu_frame_irq = false
		elseif addr == 0x4017 then
			apu_irq_inhibit = bit32.btest(value, 0x40)
			apu_frame_irq = false
			apu_frame_mode_5step = bit32.btest(value, 0x80)
			apu_frame_cycle = 0

			if apu_frame_mode_5step then
				clock_pulse_envelope(1)
				clock_pulse_envelope(2)
				clock_noise_envelope()
				clock_triangle_linear_counter()
				clock_length_counters()
				clock_pulse_sweep(1)
				clock_pulse_sweep(2)
			end
		end

		update_audio_mixer()
	end

	local function set_mmc5_enabled(enabled: boolean)
		mmc5_enabled = enabled
		update_audio_mixer()
	end

	local function apu_mmc5_cpu_read(addr: number, value: number)
		if not mmc5_enabled or not mmc5_pcm_read_mode then
			return
		end

		addr = bit32.band(addr, 0xFFFF)
		if addr >= 0x8000 and addr <= 0xBFFF then
			value = bit32.band(value, 0xFF)
			if value == 0 then
				mmc5_pcm_irq_trip = true
			else
				mmc5_pcm_irq_trip = false
			end
		end
	end

	local function apu_write_mmc5(addr: number, value: number)
		addr = bit32.band(addr, 0xFFFF)
		value = bit32.band(value, 0xFF)

		if addr == 0x5000 then
			mmc5_pulse_control[1] = value
		elseif addr == 0x5002 then
			mmc5_pulse_timer_low[1] = value
			mmc5_pulse_timer[1] = bit32.bor(bit32.band(mmc5_pulse_timer[1], 0x0700), value)
		elseif addr == 0x5003 then
			mmc5_pulse_timer[1] = bit32.bor(bit32.lshift(bit32.band(value, 0x07), 8), mmc5_pulse_timer_low[1])
			mmc5_pulse_running = bit32.bor(mmc5_pulse_running, 0x01)
		elseif addr == 0x5004 then
			mmc5_pulse_control[2] = value
		elseif addr == 0x5006 then
			mmc5_pulse_timer_low[2] = value
			mmc5_pulse_timer[2] = bit32.bor(bit32.band(mmc5_pulse_timer[2], 0x0700), value)
		elseif addr == 0x5007 then
			mmc5_pulse_timer[2] = bit32.bor(bit32.lshift(bit32.band(value, 0x07), 8), mmc5_pulse_timer_low[2])
			mmc5_pulse_running = bit32.bor(mmc5_pulse_running, 0x02)
		elseif addr == 0x5010 then
			mmc5_pcm_control = bit32.band(value, 0x81)
			mmc5_pcm_irq_enabled = bit32.btest(value, 0x80)
			mmc5_pcm_read_mode = bit32.btest(value, 0x01)
		elseif addr == 0x5011 then
			if not mmc5_pcm_read_mode then
				if value == 0 then
					mmc5_pcm_irq_trip = true
				else
					mmc5_pcm_irq_trip = false
				end
			end
		elseif addr == 0x5015 then
			mmc5_pulse_enable = bit32.band(value, 0x03)
			mmc5_pulse_running = bit32.band(mmc5_pulse_running, mmc5_pulse_enable)
		end

		update_audio_mixer()
	end

	local function apu_read_mmc5(addr: number): number
		addr = bit32.band(addr, 0xFFFF)
		if addr == 0x5010 then
			local value = bit32.band(mmc5_pcm_control, 0x01)
			if mmc5_pcm_irq_enabled and mmc5_pcm_irq_trip then
				value = bit32.bor(value, 0x80)
			end
			mmc5_pcm_irq_trip = false
			return value
		end
		if addr == 0x5015 then
			return bit32.band(mmc5_pulse_running, 0x03)
		end
		return 0
	end

	local function apu_reset()
		channel_enabled_mask = 0

		pulse_control[1] = 0
		pulse_control[2] = 0
		pulse_sweep[1] = 0
		pulse_sweep[2] = 0
		pulse_timer_low[1] = 0
		pulse_timer_low[2] = 0
		pulse_timer[1] = 0
		pulse_timer[2] = 0
		pulse_length[1] = 0
		pulse_length[2] = 0
		pulse_envelope_start[1] = false
		pulse_envelope_start[2] = false
		pulse_envelope_divider[1] = 0
		pulse_envelope_divider[2] = 0
		pulse_envelope_decay[1] = 0
		pulse_envelope_decay[2] = 0
		pulse_sweep_divider[1] = 0
		pulse_sweep_divider[2] = 0
		pulse_sweep_reload[1] = false
		pulse_sweep_reload[2] = false

		triangle_control = 0
		triangle_timer_low = 0
		triangle_timer = 0
		triangle_length = 0
		triangle_linear_reload_value = 0
		triangle_linear_counter = 0
		triangle_linear_reload = false

		noise_control = 0
		noise_period_index = 0
		noise_length = 0
		noise_envelope_start = false
		noise_envelope_divider = 0
		noise_envelope_decay = 0
		noise_short_mode = false

		dmc_irq_enabled = false
		dmc_loop = false
		dmc_period_index = 0
		dmc_timer_counter = DMC_PERIOD_TABLE[1]
		dmc_output_level = 0
		dmc_sample_addr_reg = 0
		dmc_sample_length_reg = 0
		dmc_current_addr = 0xC000
		dmc_bytes_remaining = 0
		dmc_shift = 0
		dmc_bits_remaining = 8
		dmc_buffer = 0
		dmc_buffer_empty = true
		dmc_silence = true
		dmc_dma_stall_cycles = 0

		mmc5_pulse_control[1] = 0
		mmc5_pulse_control[2] = 0
		mmc5_pulse_timer_low[1] = 0
		mmc5_pulse_timer_low[2] = 0
		mmc5_pulse_timer[1] = 0
		mmc5_pulse_timer[2] = 0
		mmc5_pulse_running = 0
		mmc5_pulse_enable = 0
		mmc5_pcm_control = 0
		mmc5_pcm_irq_enabled = false
		mmc5_pcm_irq_trip = false
		mmc5_pcm_read_mode = false

		apu_frame_irq = false
		apu_dmc_irq = false
		apu_irq_inhibit = true
		apu_frame_mode_5step = false
		apu_frame_cycle = 0
		dmc_mix_pending = false
		dmc_mix_counter = 0

		update_audio_mixer()
	end

	local function apu_irq_pending(): boolean
		return apu_frame_irq or apu_dmc_irq or (mmc5_enabled and mmc5_pcm_irq_enabled and mmc5_pcm_irq_trip)
	end

	local function consume_dmc_dma_stall_cycles(): number
		local cycles = dmc_dma_stall_cycles
		dmc_dma_stall_cycles = 0
		return cycles
	end

	apu_reset()

	return {
		step = apu_step,
		readStatus = apu_read_status,
		write = apu_write,
		writeMmc5 = apu_write_mmc5,
		readMmc5 = apu_read_mmc5,
		onMmc5CpuRead = apu_mmc5_cpu_read,
		setMmc5Enabled = set_mmc5_enabled,
		reset = apu_reset,
		irqPending = apu_irq_pending,
		consumeDmaStallCycles = consume_dmc_dma_stall_cycles,
	}
end

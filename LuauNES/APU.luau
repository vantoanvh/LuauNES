--!native
--!nocheck
--!optimize 2

local ASSETS = {
	pulse_12_5 = 'rbxassetid://137987182789405',
	pulse_25 = 'rbxassetid://108267815293395',
	pulse_50 = 'rbxassetid://74193770330344',
	pulse_75 = 'rbxassetid://100273244108902',
	triangle = 'rbxassetid://135072236414372',
	noise_mix = 'rbxassetid://137650960613979',
}

export type APUInstance = {
	step: (number) -> (),
	syncMixer: () -> (),
	readStatus: () -> number,
	write: (number, number) -> (),
	writeMmc5: (number, number) -> (),
	writeVrc6: (number, number) -> (),
	writeVrc7: (number, number) -> (),
	readMmc5: (number) -> number,
	onMmc5CpuRead: (number, number) -> (),
	setMmc5Enabled: (boolean) -> (),
	setVrc6Enabled: (boolean) -> (),
	setVrc7Enabled: (boolean) -> (),
	reset: () -> (),
	irqPending: () -> boolean,
	consumeDmaStallCycles: () -> number,
}

return function(dmc_reader: (number) -> number): APUInstance
	local apu_frame_irq = false
	local apu_dmc_irq = false
	local mixer_dirty = false

	-- narrow luau bridge optimization
	local _, newindex = xpcall(function() game._____ = {} end, function() return debug.info(2, 'f') end)

	local CPU_CLOCK_HZ = 1789773

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

	local NOISE_PERIOD_TABLE = {
		4, 8, 16, 32, 64, 96, 128, 160,
		202, 254, 380, 508, 762, 1016, 2034, 4068
	}

	local PULSE_SPEED_NUM = CPU_CLOCK_HZ / (16 * 441)
	local TRIANGLE_SPEED_NUM = CPU_CLOCK_HZ / (32 * 441)
	local SAW_SPEED_NUM = CPU_CLOCK_HZ / (14 * 441)

	local pulse1_enabled = false
	local pulse2_enabled = false
	local triangle_enabled = false
	local noise_enabled = false
	local dmc_enabled = false

	local pulse1_duty = 0
	local pulse2_duty = 0
	local pulse1_constant_volume = false
	local pulse2_constant_volume = false
	local pulse1_length_halt = false
	local pulse2_length_halt = false
	local pulse1_envelope_period = 0
	local pulse2_envelope_period = 0
	local pulse1_sweep_shift = 0
	local pulse2_sweep_shift = 0
	local pulse1_sweep_divider_period = 0
	local pulse2_sweep_divider_period = 0
	local pulse1_sweep_active = false
	local pulse2_sweep_active = false
	local pulse1_sweep_negate = false
	local pulse2_sweep_negate = false
	local pulse1_timer_low = 0
	local pulse2_timer_low = 0
	local pulse1_timer = 0
	local pulse2_timer = 0
	local pulse1_length = 0
	local pulse2_length = 0
	local pulse1_envelope_start = false
	local pulse2_envelope_start = false
	local pulse1_envelope_divider = 0
	local pulse2_envelope_divider = 0
	local pulse1_envelope_decay = 0
	local pulse2_envelope_decay = 0
	local pulse1_sweep_divider = 0
	local pulse2_sweep_divider = 0
	local pulse1_sweep_reload = false
	local pulse2_sweep_reload = false

	local triangle_length_halt = false
	local triangle_timer_low = 0
	local triangle_timer = 0
	local triangle_length = 0
	local triangle_linear_reload_value = 0
	local triangle_linear_counter = 0
	local triangle_linear_reload = false

	local noise_constant_volume = false
	local noise_length_halt = false
	local noise_envelope_period = 0
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
	local mmc5_pulse1_duty = 0
	local mmc5_pulse2_duty = 0
	local mmc5_pulse1_volume = 0
	local mmc5_pulse2_volume = 0
	local mmc5_pulse1_timer_low = 0
	local mmc5_pulse2_timer_low = 0
	local mmc5_pulse1_timer = 0
	local mmc5_pulse2_timer = 0
	local mmc5_pulse_running = 0
	local mmc5_pulse_enable = 0
	local mmc5_pcm_control = 0
	local mmc5_pcm_irq_enabled = false
	local mmc5_pcm_irq_trip = false
	local mmc5_pcm_read_mode = false

	local vrc6_enabled = false
	local vrc6_halt_audio = false
	local vrc6_frequency_shift = 0
	local vrc6_pulse1_wave = 1
	local vrc6_pulse2_wave = 1
	local vrc6_pulse1_volume = 0
	local vrc6_pulse2_volume = 0
	local vrc6_pulse1_timer = 0
	local vrc6_pulse2_timer = 0
	local vrc6_pulse1_enable = false
	local vrc6_pulse2_enable = false
	local vrc6_saw_rate = 0
	local vrc6_saw_timer = 0
	local vrc6_saw_enable = false

	local vrc7_enabled = false
	local vrc7_control = 0
	local vrc7_current_reg = 0
	local vrc7_fnum_low = buffer.create(6)
	local vrc7_key_block = buffer.create(6)
	local vrc7_inst_volume = buffer.create(6)
	local vrc7_raw = buffer.create(6)

	local apu_irq_inhibit = true
	local apu_frame_mode_5step = false
	local apu_frame_cycle = 0
	local dmc_mix_pending = false
	local dmc_mix_counter = 0

	local MASTER_SAMPLE_RATE = 44100
	local REGION_GUARD_SAMPLES = 2048

	local NOISE_LONG_CYCLE_BITS = 32767
	local NOISE_SHORT_CYCLE_BITS = 93
	local NOISE_MIN_REGION_SECONDS = 0.10

	local PULSE_ASSET_KEYS = {
		'pulse_12_5',
		'pulse_25',
		'pulse_50',
		'pulse_75',
	}

	local VOICE_ASSET_KEYS = {
		'pulse_12_5',
		'pulse_25',
		'pulse_50',
		'pulse_75',
		'triangle',
	}

	-- Approximate VRC7 presets with the small looped waveform set available in this project.
	local VRC7_INSTRUMENT_WAVES = {
		5, 1, 3, 5, 5, 2, 3, 1,
		3, 1, 5, 5, 4, 5, 2, 4,
	}

	local function round_div_nearest(numerator: number, denominator: number): number
		return ((numerator * 2) + denominator) // (denominator * 2)
	end

	local function samples_to_seconds(sample_count: number): number
		return sample_count / MASTER_SAMPLE_RATE
	end

	local function build_noise_region_banks(): ({NumberRange}, {NumberRange})
		local cursor = 0
		local min_region_samples = math.max(1, math.round(NOISE_MIN_REGION_SECONDS * MASTER_SAMPLE_RATE))

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

	local NOISE_LONG_REGIONS, NOISE_SHORT_REGIONS = build_noise_region_banks()

	local function create_looped_sound(name: string, asset_key: string, region: NumberRange?): Sound
		local sound = Instance.new('Sound')
		sound.Name = name
		sound.Looped = true
		sound.Volume = 0
		sound.SoundId = ASSETS[asset_key] or ''
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
			bank[duty] = create_looped_sound(prefix .. '_' .. duty, PULSE_ASSET_KEYS[duty], nil)
		end
	end

	local pulse1_duty1_sound = pulse_sound_bank[1][1]
	local pulse1_duty2_sound = pulse_sound_bank[1][2]
	local pulse1_duty3_sound = pulse_sound_bank[1][3]
	local pulse1_duty4_sound = pulse_sound_bank[1][4]
	local pulse2_duty1_sound = pulse_sound_bank[2][1]
	local pulse2_duty2_sound = pulse_sound_bank[2][2]
	local pulse2_duty3_sound = pulse_sound_bank[2][3]
	local pulse2_duty4_sound = pulse_sound_bank[2][4]

	local triangle_sound = create_looped_sound('Triangle', 'triangle', nil)

	local extra_pulse_sound_bank = nil :: {{Sound}}?
	local extra_pulse1_duty1_sound = nil :: Sound?
	local extra_pulse1_duty2_sound = nil :: Sound?
	local extra_pulse1_duty3_sound = nil :: Sound?
	local extra_pulse1_duty4_sound = nil :: Sound?
	local extra_pulse2_duty1_sound = nil :: Sound?
	local extra_pulse2_duty2_sound = nil :: Sound?
	local extra_pulse2_duty3_sound = nil :: Sound?
	local extra_pulse2_duty4_sound = nil :: Sound?
	local vrc6_saw_sound = nil :: Sound?

	local vrc7_voice_sound_bank = nil :: {{Sound}}?

	local function create_region_bank(prefix: string, asset_key: string, regions: {NumberRange}): {Sound}
		local bank = table.create(#regions) :: {Sound}
		for i = 1, #regions do
			bank[i] = create_looped_sound(prefix .. i, asset_key, regions[i])
		end
		return bank
	end

	local noise_long_sound_bank = create_region_bank('NoiseLong', 'noise_mix', NOISE_LONG_REGIONS)
	local noise_short_sound_bank = create_region_bank('NoiseShort', 'noise_mix', NOISE_SHORT_REGIONS)

	local function create_pulse_bank(prefix: string): {{Sound}}
		local sound_bank = { {} :: {Sound}, {} :: {Sound} }
		for channel = 1, 2 do
			local bank = sound_bank[channel]
			local channel_prefix = `{prefix}_{channel}`
			for duty = 1, #PULSE_ASSET_KEYS do
				bank[duty] = create_looped_sound(channel_prefix .. '_' .. duty, PULSE_ASSET_KEYS[duty], nil)
			end
		end
		return sound_bank
	end

	local function destroy_sound_bank(bank: {Sound}?)
		if bank == nil then
			return
		end

		for _, sound in bank do
			sound:Destroy()
		end
	end

	local function ensure_extra_pulse_sounds()
		if extra_pulse_sound_bank ~= nil then
			return
		end

		extra_pulse_sound_bank = create_pulse_bank('Extra')
		extra_pulse1_duty1_sound = extra_pulse_sound_bank[1][1]
		extra_pulse1_duty2_sound = extra_pulse_sound_bank[1][2]
		extra_pulse1_duty3_sound = extra_pulse_sound_bank[1][3]
		extra_pulse1_duty4_sound = extra_pulse_sound_bank[1][4]
		extra_pulse2_duty1_sound = extra_pulse_sound_bank[2][1]
		extra_pulse2_duty2_sound = extra_pulse_sound_bank[2][2]
		extra_pulse2_duty3_sound = extra_pulse_sound_bank[2][3]
		extra_pulse2_duty4_sound = extra_pulse_sound_bank[2][4]
	end

	local function release_extra_pulse_sounds()
		if extra_pulse_sound_bank == nil then
			return
		end

		destroy_sound_bank(extra_pulse_sound_bank[1])
		destroy_sound_bank(extra_pulse_sound_bank[2])
		extra_pulse_sound_bank = nil
		extra_pulse1_duty1_sound = nil
		extra_pulse1_duty2_sound = nil
		extra_pulse1_duty3_sound = nil
		extra_pulse1_duty4_sound = nil
		extra_pulse2_duty1_sound = nil
		extra_pulse2_duty2_sound = nil
		extra_pulse2_duty3_sound = nil
		extra_pulse2_duty4_sound = nil
	end

	local function ensure_vrc6_saw_sound()
		if vrc6_saw_sound == nil then
			vrc6_saw_sound = create_looped_sound('VRC6_Saw', 'triangle', nil)
		end
	end

	local function release_vrc6_saw_sound()
		if vrc6_saw_sound ~= nil then
			vrc6_saw_sound:Destroy()
			vrc6_saw_sound = nil
		end
	end

	local function ensure_vrc7_voice_sounds()
		if vrc7_voice_sound_bank ~= nil then
			return
		end

		local voice_bank = {} :: {{Sound}}
		for channel = 1, 6 do
			local bank = {} :: {Sound}
			local prefix = `VRC7_{channel}`
			for wave = 1, #VOICE_ASSET_KEYS do
				bank[wave] = create_looped_sound(prefix .. '_' .. wave, VOICE_ASSET_KEYS[wave], nil)
			end
			voice_bank[channel] = bank
		end
		vrc7_voice_sound_bank = voice_bank
	end

	local function release_vrc7_voice_sounds()
		if vrc7_voice_sound_bank == nil then
			return
		end

		for _, bank in vrc7_voice_sound_bank do
			destroy_sound_bank(bank)
		end
		vrc7_voice_sound_bank = nil
	end

	local function dmc_try_fill_buffer()
		if dmc_buffer_empty and dmc_bytes_remaining > 0 then
			dmc_buffer = dmc_reader(dmc_current_addr)
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
					dmc_current_addr = 0xC000 + dmc_sample_addr_reg * 64
					dmc_bytes_remaining = dmc_sample_length_reg * 16 + 1
				elseif dmc_irq_enabled then
					apu_dmc_irq = true
				end
			end
		end
	end

	local function update_audio_mixer()
		dmc_mix_pending = false
		dmc_mix_counter = 0

		local tri_sound = triangle_sound

		local pulse1_raw = 0
		local pulse1_timer_local = pulse1_timer
		if pulse1_enabled and pulse1_length > 0 and pulse1_timer_local >= 8 and pulse1_timer_local <= 0x7FF then
			local pulse1_muted = false
			if pulse1_sweep_active then
				local delta = bit32.rshift(pulse1_timer_local, pulse1_sweep_shift)
				if (if pulse1_sweep_negate then pulse1_timer_local - delta - 1 else pulse1_timer_local + delta) > 0x7FF then
					pulse1_muted = true
				end
			end

			if not pulse1_muted then
				pulse1_raw = if pulse1_constant_volume then pulse1_envelope_period else pulse1_envelope_decay
			end
		end

		local pulse2_raw = 0
		local pulse2_timer_local = pulse2_timer
		if pulse2_enabled and pulse2_length > 0 and pulse2_timer_local >= 8 and pulse2_timer_local <= 0x7FF then
			local pulse2_muted = false
			if pulse2_sweep_active then
				local delta = bit32.rshift(pulse2_timer_local, pulse2_sweep_shift)
				if (if pulse2_sweep_negate then pulse2_timer_local - delta else pulse2_timer_local + delta) > 0x7FF then
					pulse2_muted = true
				end
			end

			if not pulse2_muted then
				pulse2_raw = if pulse2_constant_volume then pulse2_envelope_period else pulse2_envelope_decay
			end
		end

		local triangle_raw = 0
		if triangle_enabled and triangle_length > 0 and triangle_linear_counter > 0 and triangle_timer > 1 then
			triangle_raw = 15
		end

		local noise_raw = 0
		if noise_enabled and noise_length > 0 then
			noise_raw = if noise_constant_volume then noise_envelope_period else noise_envelope_decay
		end

		local mmc5_pulse1_raw = 0
		local mmc5_pulse2_raw = 0
		local vrc6_pulse1_raw = 0
		local vrc6_pulse2_raw = 0
		local vrc6_saw_raw = 0
		
		local vrc7_block = vrc7_key_block
		local vrc7_vol = vrc7_inst_volume
		local vrc7_rawb = vrc7_raw
		
		if vrc7_enabled then
			buffer.fill(vrc7_rawb, 0, 0, 6)
		end

		if mmc5_enabled and bit32.btest(mmc5_pulse_enable, 0x01) and bit32.btest(mmc5_pulse_running, 0x01) and mmc5_pulse1_timer >= 8 then
			mmc5_pulse1_raw = mmc5_pulse1_volume
		end
		if mmc5_enabled and bit32.btest(mmc5_pulse_enable, 0x02) and bit32.btest(mmc5_pulse_running, 0x02) and mmc5_pulse2_timer >= 8 then
			mmc5_pulse2_raw = mmc5_pulse2_volume
		end

		if vrc6_enabled and not vrc6_halt_audio then
			local pulse1_timer = bit32.rshift(vrc6_pulse1_timer, vrc6_frequency_shift)
			local pulse2_timer = bit32.rshift(vrc6_pulse2_timer, vrc6_frequency_shift)
			local saw_timer = bit32.rshift(vrc6_saw_timer, vrc6_frequency_shift)

			if vrc6_pulse1_enable and pulse1_timer >= 8 then
				vrc6_pulse1_raw = vrc6_pulse1_volume
			end
			if vrc6_pulse2_enable and pulse2_timer >= 8 then
				vrc6_pulse2_raw = vrc6_pulse2_volume
			end
			if vrc6_saw_enable and saw_timer >= 1 then
				vrc6_saw_raw = math.min(bit32.rshift(vrc6_saw_rate, 1), 31)
			end
		end

		local pulse_total = pulse1_raw + pulse2_raw
		local pulse_mix = if pulse_total > 0 then 95.88 / ((8128 / pulse_total) + 100) else 0
		local pulse1_gain = 0
		local pulse2_gain = 0
		if pulse_mix > 0 and pulse_total > 0 then
			pulse1_gain = pulse_mix * (pulse1_raw / pulse_total)
			pulse2_gain = pulse_mix * (pulse2_raw / pulse_total)
		end

		local mmc5_pulse_total = mmc5_pulse1_raw + mmc5_pulse2_raw
		local mmc5_pulse1_gain = 0
		local mmc5_pulse2_gain = 0
		local vrc6_total = vrc6_pulse1_raw + vrc6_pulse2_raw + vrc6_saw_raw
		local vrc6_pulse1_gain = 0
		local vrc6_pulse2_gain = 0
		local vrc6_saw_gain = 0
		local vrc7_total = 0
		local vrc7_gain_total = 0

		if mmc5_pulse_total > 0 then
			local mmc5_gain = 0.22 * (mmc5_pulse_total / 30)
			mmc5_pulse1_gain = mmc5_gain * (mmc5_pulse1_raw / mmc5_pulse_total)
			mmc5_pulse2_gain = mmc5_gain * (mmc5_pulse2_raw / mmc5_pulse_total)
		end

		if vrc6_total > 0 then
			local vrc6_gain = 0.28 * (vrc6_total / 61)
			vrc6_pulse1_gain = vrc6_gain * (vrc6_pulse1_raw / vrc6_total)
			vrc6_pulse2_gain = vrc6_gain * (vrc6_pulse2_raw / vrc6_total)
			vrc6_saw_gain = vrc6_gain * (vrc6_saw_raw / vrc6_total)
		end

		if vrc7_enabled and not bit32.btest(vrc7_control, 0x40) then
			for i = 1, 6 do
				local key_block = buffer.readu8(vrc7_block, i - 1)
				if bit32.btest(key_block, 0x10) then
					local raw = 15 - bit32.band(buffer.readu8(vrc7_vol, i - 1), 0x0F)
					buffer.writeu8(vrc7_rawb, i - 1, raw)
					vrc7_total += raw
				end
			end
		end

		if vrc7_total > 0 then
			vrc7_gain_total = 0.24 * (vrc7_total / 90)
		end

		local triangle_term = triangle_raw / 8227
		local noise_term = noise_raw / 12241

		local tnd_total = triangle_term + noise_term + dmc_output_level / 22638
		local tnd_mix = if tnd_total > 0 then 159.79 / ((1 / tnd_total) + 100) else 0

		local triangle_gain = 0
		local noise_gain = 0

		if tnd_mix > 0 and tnd_total > 0 then
			triangle_gain = tnd_mix * (triangle_term / tnd_total)
			noise_gain = tnd_mix * (noise_term / tnd_total) * 6.7 -- tuning this because noise is too quiet ( prevents weird moderation )
		end

		if pulse1_raw <= 0 then
			newindex(pulse1_duty1_sound, 'Volume', 0)
			newindex(pulse1_duty2_sound, 'Volume', 0)
			newindex(pulse1_duty3_sound, 'Volume', 0)
			newindex(pulse1_duty4_sound, 'Volume', 0)
		else
			local duty = pulse1_duty
			local speed = PULSE_SPEED_NUM / (pulse1_timer_local + 1)

			newindex(pulse1_duty1_sound, 'PlaybackSpeed', speed)
			newindex(pulse1_duty2_sound, 'PlaybackSpeed', speed)
			newindex(pulse1_duty3_sound, 'PlaybackSpeed', speed)
			newindex(pulse1_duty4_sound, 'PlaybackSpeed', speed)

			newindex(pulse1_duty1_sound, 'Volume', duty == 0 and pulse1_gain or 0)
			newindex(pulse1_duty2_sound, 'Volume', duty == 1 and pulse1_gain or 0)
			newindex(pulse1_duty3_sound, 'Volume', duty == 2 and pulse1_gain or 0)
			newindex(pulse1_duty4_sound, 'Volume', duty == 3 and pulse1_gain or 0)
		end

		if pulse2_raw <= 0 then
			newindex(pulse2_duty1_sound, 'Volume', 0)
			newindex(pulse2_duty2_sound, 'Volume', 0)
			newindex(pulse2_duty3_sound, 'Volume', 0)
			newindex(pulse2_duty4_sound, 'Volume', 0)
		else
			local duty = pulse2_duty
			local speed = PULSE_SPEED_NUM / (pulse2_timer_local + 1)

			newindex(pulse2_duty1_sound, 'PlaybackSpeed', speed)
			newindex(pulse2_duty2_sound, 'PlaybackSpeed', speed)
			newindex(pulse2_duty3_sound, 'PlaybackSpeed', speed)
			newindex(pulse2_duty4_sound, 'PlaybackSpeed', speed)

			newindex(pulse2_duty1_sound, 'Volume', duty == 0 and pulse2_gain or 0)
			newindex(pulse2_duty2_sound, 'Volume', duty == 1 and pulse2_gain or 0)
			newindex(pulse2_duty3_sound, 'Volume', duty == 2 and pulse2_gain or 0)
			newindex(pulse2_duty4_sound, 'Volume', duty == 3 and pulse2_gain or 0)
		end

		if mmc5_enabled then
			if mmc5_pulse1_raw <= 0 then
				newindex(extra_pulse1_duty1_sound, 'Volume', 0)
				newindex(extra_pulse1_duty2_sound, 'Volume', 0)
				newindex(extra_pulse1_duty3_sound, 'Volume', 0)
				newindex(extra_pulse1_duty4_sound, 'Volume', 0)
			else
				local duty = mmc5_pulse1_duty
				local speed = PULSE_SPEED_NUM / (mmc5_pulse1_timer + 1)

				newindex(extra_pulse1_duty1_sound, 'PlaybackSpeed', speed)
				newindex(extra_pulse1_duty2_sound, 'PlaybackSpeed', speed)
				newindex(extra_pulse1_duty3_sound, 'PlaybackSpeed', speed)
				newindex(extra_pulse1_duty4_sound, 'PlaybackSpeed', speed)

				newindex(extra_pulse1_duty1_sound, 'Volume', duty == 0 and mmc5_pulse1_gain or 0)
				newindex(extra_pulse1_duty2_sound, 'Volume', duty == 1 and mmc5_pulse1_gain or 0)
				newindex(extra_pulse1_duty3_sound, 'Volume', duty == 2 and mmc5_pulse1_gain or 0)
				newindex(extra_pulse1_duty4_sound, 'Volume', duty == 3 and mmc5_pulse1_gain or 0)
			end

			if mmc5_pulse2_raw <= 0 then
				newindex(extra_pulse2_duty1_sound, 'Volume', 0)
				newindex(extra_pulse2_duty2_sound, 'Volume', 0)
				newindex(extra_pulse2_duty3_sound, 'Volume', 0)
				newindex(extra_pulse2_duty4_sound, 'Volume', 0)
			else
				local duty = mmc5_pulse2_duty
				local speed = PULSE_SPEED_NUM / (mmc5_pulse2_timer + 1)

				newindex(extra_pulse2_duty1_sound, 'PlaybackSpeed', speed)
				newindex(extra_pulse2_duty2_sound, 'PlaybackSpeed', speed)
				newindex(extra_pulse2_duty3_sound, 'PlaybackSpeed', speed)
				newindex(extra_pulse2_duty4_sound, 'PlaybackSpeed', speed)

				newindex(extra_pulse2_duty1_sound, 'Volume', duty == 0 and mmc5_pulse2_gain or 0)
				newindex(extra_pulse2_duty2_sound, 'Volume', duty == 1 and mmc5_pulse2_gain or 0)
				newindex(extra_pulse2_duty3_sound, 'Volume', duty == 2 and mmc5_pulse2_gain or 0)
				newindex(extra_pulse2_duty4_sound, 'Volume', duty == 3 and mmc5_pulse2_gain or 0)
			end
		end

		if vrc6_enabled then
			if vrc6_pulse1_raw <= 0 then
				newindex(extra_pulse1_duty1_sound, 'Volume', 0)
				newindex(extra_pulse1_duty2_sound, 'Volume', 0)
				newindex(extra_pulse1_duty3_sound, 'Volume', 0)
				newindex(extra_pulse1_duty4_sound, 'Volume', 0)
			else
				local speed = PULSE_SPEED_NUM / (bit32.rshift(vrc6_pulse1_timer, vrc6_frequency_shift) + 1)
				local duty = vrc6_pulse1_wave

				newindex(extra_pulse1_duty1_sound, 'PlaybackSpeed', speed)
				newindex(extra_pulse1_duty2_sound, 'PlaybackSpeed', speed)
				newindex(extra_pulse1_duty3_sound, 'PlaybackSpeed', speed)
				newindex(extra_pulse1_duty4_sound, 'PlaybackSpeed', speed)

				newindex(extra_pulse1_duty1_sound, 'Volume', duty == 1 and vrc6_pulse1_gain or 0)
				newindex(extra_pulse1_duty2_sound, 'Volume', duty == 2 and vrc6_pulse1_gain or 0)
				newindex(extra_pulse1_duty3_sound, 'Volume', duty == 3 and vrc6_pulse1_gain or 0)
				newindex(extra_pulse1_duty4_sound, 'Volume', duty == 4 and vrc6_pulse1_gain or 0)
			end

			if vrc6_pulse2_raw <= 0 then
				newindex(extra_pulse2_duty1_sound, 'Volume', 0)
				newindex(extra_pulse2_duty2_sound, 'Volume', 0)
				newindex(extra_pulse2_duty3_sound, 'Volume', 0)
				newindex(extra_pulse2_duty4_sound, 'Volume', 0)
			else
				local speed = PULSE_SPEED_NUM / (bit32.rshift(vrc6_pulse2_timer, vrc6_frequency_shift) + 1)
				local duty = vrc6_pulse2_wave

				newindex(extra_pulse2_duty1_sound, 'PlaybackSpeed', speed)
				newindex(extra_pulse2_duty2_sound, 'PlaybackSpeed', speed)
				newindex(extra_pulse2_duty3_sound, 'PlaybackSpeed', speed)
				newindex(extra_pulse2_duty4_sound, 'PlaybackSpeed', speed)

				newindex(extra_pulse2_duty1_sound, 'Volume', duty == 1 and vrc6_pulse2_gain or 0)
				newindex(extra_pulse2_duty2_sound, 'Volume', duty == 2 and vrc6_pulse2_gain or 0)
				newindex(extra_pulse2_duty3_sound, 'Volume', duty == 3 and vrc6_pulse2_gain or 0)
				newindex(extra_pulse2_duty4_sound, 'Volume', duty == 4 and vrc6_pulse2_gain or 0)
			end

			if vrc6_saw_sound ~= nil then
				if vrc6_saw_raw > 0 then
					newindex(vrc6_saw_sound, 'PlaybackSpeed', SAW_SPEED_NUM / (bit32.rshift(vrc6_saw_timer, vrc6_frequency_shift) + 1))
					newindex(vrc6_saw_sound, 'Volume', vrc6_saw_gain)
				else
					newindex(vrc6_saw_sound, 'Volume', 0)
				end
			end
		end

		if triangle_raw > 0 then
			newindex(tri_sound, 'PlaybackSpeed', TRIANGLE_SPEED_NUM / (triangle_timer + 1))
			newindex(tri_sound, 'Volume', triangle_gain)
		else
			newindex(tri_sound, 'Volume', 0)
		end

		if #noise_long_sound_bank > 0 and #noise_short_sound_bank > 0 then
			local active_index = noise_period_index + 1

			for i, v in noise_short_mode and noise_short_sound_bank or noise_long_sound_bank do
				newindex(v, 'Volume', if noise_raw > 0 and i == active_index then noise_gain else 0)
			end
			
			for _, v in noise_short_mode and noise_long_sound_bank or noise_short_sound_bank do
				newindex(v, 'Volume', 0)
			end
		end

		if vrc7_enabled and vrc7_voice_sound_bank ~= nil then
			for i, bank in vrc7_voice_sound_bank do
				local raw = buffer.readu8(vrc7_rawb, i - 1)
				if raw <= 0 then
					for _, sound in bank do
						newindex(sound, 'Volume', 0)
					end
				else
					local key_block = buffer.readu8(vrc7_block, i - 1)
					local fnum = bit32.bor(
						buffer.readu8(vrc7_fnum_low, i - 1),
						bit32.band(key_block, 0x01) * 256
					)
					if fnum <= 0 then
						for _, sound in bank do
							newindex(sound, 'Volume', 0)
						end
						continue
					end

					local speed = (49716 * fnum) / (2 ^ (19 - bit32.band(bit32.rshift(key_block, 1), 0x07))) / 441
					local active_wave = VRC7_INSTRUMENT_WAVES[bit32.band(bit32.rshift(buffer.readu8(vrc7_vol, i - 1), 4), 0x0F) + 1]
					local gain = vrc7_gain_total * (raw / vrc7_total)
					local clamped_speed = speed < 0.01 and 0.01 or speed

					-- This is a coarse audible fallback, not real YM2413/OPLL synthesis.
					for index, sound in bank do
						newindex(sound, 'PlaybackSpeed', clamped_speed)
						newindex(sound, 'Volume', index == active_wave and gain or 0)
					end
				end
			end
		end
	end

	local function sync_audio_mixer()
		if mixer_dirty then
			update_audio_mixer()
			mixer_dirty = false
		end
	end

	local function clock_quarter_frame()
		if pulse1_envelope_start then
			pulse1_envelope_start = false
			pulse1_envelope_decay = 15
			pulse1_envelope_divider = pulse1_envelope_period
		elseif pulse1_envelope_divider > 0 then
			pulse1_envelope_divider -= 1
		else
			pulse1_envelope_divider = pulse1_envelope_period
			if pulse1_envelope_decay > 0 then
				pulse1_envelope_decay -= 1
			elseif pulse1_length_halt then
				pulse1_envelope_decay = 15
			end
		end

		if pulse2_envelope_start then
			pulse2_envelope_start = false
			pulse2_envelope_decay = 15
			pulse2_envelope_divider = pulse2_envelope_period
		elseif pulse2_envelope_divider > 0 then
			pulse2_envelope_divider -= 1
		else
			pulse2_envelope_divider = pulse2_envelope_period
			if pulse2_envelope_decay > 0 then
				pulse2_envelope_decay -= 1
			elseif pulse2_length_halt then
				pulse2_envelope_decay = 15
			end
		end

		if noise_envelope_start then
			noise_envelope_start = false
			noise_envelope_decay = 15
			noise_envelope_divider = noise_envelope_period
		elseif noise_envelope_divider > 0 then
			noise_envelope_divider -= 1
		else
			noise_envelope_divider = noise_envelope_period
			if noise_envelope_decay > 0 then
				noise_envelope_decay -= 1
			elseif noise_length_halt then
				noise_envelope_decay = 15
			end
		end

		if triangle_linear_reload then
			triangle_linear_counter = triangle_linear_reload_value
		elseif triangle_linear_counter > 0 then
			triangle_linear_counter -= 1
		end

		if not triangle_length_halt then
			triangle_linear_reload = false
		end
	end

	local function clock_half_frame()
		if pulse1_length > 0 and not pulse1_length_halt then
			pulse1_length -= 1
		end
		if pulse2_length > 0 and not pulse2_length_halt then
			pulse2_length -= 1
		end
		if triangle_length > 0 and not triangle_length_halt then
			triangle_length -= 1
		end
		if noise_length > 0 and not noise_length_halt then
			noise_length -= 1
		end

		-- clock_pulse1_sweep
		if pulse1_sweep_divider == 0 then
			if pulse1_sweep_active then
				local timer = pulse1_timer
				local delta = bit32.rshift(timer, pulse1_sweep_shift)
				local target = if pulse1_sweep_negate
					then timer - delta - 1
					else timer + delta
				if timer >= 8 and target >= 0 and target <= 0x7FF then
					pulse1_timer = target
				end
			end
			pulse1_sweep_divider = pulse1_sweep_divider_period
		else
			pulse1_sweep_divider -= 1
		end

		if pulse1_sweep_reload then
			pulse1_sweep_reload = false
			pulse1_sweep_divider = pulse1_sweep_divider_period
		end
		
		-- clock_pulse2_sweep
		if pulse2_sweep_divider == 0 then
			if pulse2_sweep_active then
				local timer = pulse2_timer
				local delta = bit32.rshift(timer, pulse2_sweep_shift)
				local target = if pulse2_sweep_negate
					then timer - delta
					else timer + delta

				if timer >= 8 and target >= 0 and target <= 0x7FF then
					pulse2_timer = target
				end
			end
			pulse2_sweep_divider = pulse2_sweep_divider_period
		else
			pulse2_sweep_divider -= 1
		end

		if pulse2_sweep_reload then
			pulse2_sweep_reload = false
			pulse2_sweep_divider = pulse2_sweep_divider_period
		end
	end

	local function apu_step(cycle_count: number)
		if cycle_count <= 0 then
			if mixer_dirty then
				update_audio_mixer()
				mixer_dirty = false
			end
			return
		end

		local should_mix = false
		local remaining = cycle_count
		local dmc_counter = dmc_timer_counter
		local mix_pending = dmc_mix_pending
		local mix_counter = dmc_mix_counter
		local frame_len = if apu_frame_mode_5step then 37282 else 29830
		local frame_q4 = if apu_frame_mode_5step then 37281 else 29829
		if dmc_counter <= 0 then
			dmc_counter = DMC_PERIOD_TABLE[dmc_period_index + 1]
		end

		while remaining > 0 do
			local event_cycle = frame_q4
			if apu_frame_cycle < 7457 then
				event_cycle = 7457
			elseif apu_frame_cycle < 14913 then
				event_cycle = 14913
			elseif apu_frame_cycle < 22371 then
				event_cycle = 22371
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
			if apu_frame_cycle == 7457 or apu_frame_cycle == 22371 then
				clock_quarter = true
			elseif apu_frame_cycle == 14913 then
				clock_quarter = true
				clock_half = true
			elseif apu_frame_mode_5step then
				if apu_frame_cycle == 37281 then
					clock_quarter = true
					clock_half = true
				end
			elseif apu_frame_cycle == 29829 then
				clock_quarter = true
				clock_half = true
				set_irq = true
			end

			if clock_quarter then
				clock_quarter_frame()
				should_mix = true
			end

			if clock_half then
				clock_half_frame()
				should_mix = true
			end

			if set_irq and not apu_irq_inhibit then
				apu_frame_irq = true
			end

			if apu_frame_cycle >= frame_len then
				apu_frame_cycle = 0
			end

			if dmc_counter <= 0 then
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

				if dmc_output_level ~= level_before or dmc_silence ~= silence_before then
					mix_pending = true
				end
				dmc_counter = DMC_PERIOD_TABLE[dmc_period_index + 1]
			end

			if mix_pending and mix_counter >= 1 then
				should_mix = true
				mix_pending = false
				mix_counter = 0
			end
		end

		dmc_timer_counter = dmc_counter
		dmc_mix_pending = mix_pending
		dmc_mix_counter = mix_counter

		if should_mix or mixer_dirty then
			update_audio_mixer()
			mixer_dirty = false
		end
	end

	local function apu_read_status(): number
		local value = 0

		if pulse1_length > 0 then
			value = bit32.bor(value, 0x01)
		end
		if pulse2_length > 0 then
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

		if addr == 0x4000 then
			pulse1_duty = bit32.band(bit32.rshift(value, 6), 0x03)
			pulse1_constant_volume = bit32.btest(value, 0x10)
			pulse1_length_halt = bit32.btest(value, 0x20)
			pulse1_envelope_period = bit32.band(value, 0x0F)
		elseif addr == 0x4001 then
			pulse1_sweep_shift = bit32.band(value, 0x07)
			pulse1_sweep_divider_period = bit32.band(bit32.rshift(value, 4), 0x07)
			pulse1_sweep_negate = bit32.btest(value, 0x08)
			pulse1_sweep_active = bit32.btest(value, 0x80) and pulse1_sweep_shift > 0
			pulse1_sweep_reload = true
		elseif addr == 0x4002 then
			pulse1_timer_low = value
			pulse1_timer = bit32.bor(bit32.band(pulse1_timer, 0x0700), value)
		elseif addr == 0x4003 then
			pulse1_timer = bit32.band(value, 0x07) * 256 + pulse1_timer_low
			if pulse1_enabled then
				pulse1_length = buffer.readu8(LENGTH_BUF, bit32.rshift(value, 3))
			end
			pulse1_envelope_start = true
		elseif addr == 0x4004 then
			pulse2_duty = bit32.band(bit32.rshift(value, 6), 0x03)
			pulse2_constant_volume = bit32.btest(value, 0x10)
			pulse2_length_halt = bit32.btest(value, 0x20)
			pulse2_envelope_period = bit32.band(value, 0x0F)
		elseif addr == 0x4005 then
			pulse2_sweep_shift = bit32.band(value, 0x07)
			pulse2_sweep_divider_period = bit32.band(bit32.rshift(value, 4), 0x07)
			pulse2_sweep_negate = bit32.btest(value, 0x08)
			pulse2_sweep_active = bit32.btest(value, 0x80) and pulse2_sweep_shift > 0
			pulse2_sweep_reload = true
		elseif addr == 0x4006 then
			pulse2_timer_low = value
			pulse2_timer = bit32.bor(bit32.band(pulse2_timer, 0x0700), value)
		elseif addr == 0x4007 then
			pulse2_timer = bit32.band(value, 0x07) * 256 + pulse2_timer_low
			if pulse2_enabled then
				pulse2_length = buffer.readu8(LENGTH_BUF, bit32.rshift(value, 3))
			end
			pulse2_envelope_start = true
		elseif addr == 0x4008 then
			triangle_length_halt = bit32.btest(value, 0x80)
			triangle_linear_reload_value = bit32.band(value, 0x7F)
		elseif addr == 0x400A then
			triangle_timer_low = value
			triangle_timer = bit32.bor(bit32.band(triangle_timer, 0x0700), value)
		elseif addr == 0x400B then
			triangle_timer = bit32.band(value, 0x07) * 256 + triangle_timer_low
			if triangle_enabled then
				triangle_length = buffer.readu8(LENGTH_BUF, bit32.rshift(value, 3))
			end
			triangle_linear_reload = true
		elseif addr == 0x400C then
			noise_constant_volume = bit32.btest(value, 0x10)
			noise_length_halt = bit32.btest(value, 0x20)
			noise_envelope_period = bit32.band(value, 0x0F)
		elseif addr == 0x400E then
			noise_short_mode = bit32.btest(value, 0x80)
			noise_period_index = bit32.band(value, 0x0F)
		elseif addr == 0x400F then
			if noise_enabled then
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
			local mask =  bit32.band(value, 0x1F)
			
			pulse1_enabled = bit32.btest(mask, 0x01)
			pulse2_enabled = bit32.btest(mask, 0x02)
			triangle_enabled = bit32.btest(mask, 0x04)
			noise_enabled = bit32.btest(mask, 0x08)
			dmc_enabled = bit32.btest(mask, 0x10)
			
			apu_dmc_irq = false
			if not pulse1_enabled then
				pulse1_length = 0
			end
			if not pulse2_enabled then
				pulse2_length = 0
			end
			if not triangle_enabled then
				triangle_length = 0
			end
			if not noise_enabled then
				noise_length = 0
			end

			if not dmc_enabled then
				dmc_bytes_remaining = 0
			elseif dmc_bytes_remaining == 0 then
				dmc_current_addr = 0xC000 + dmc_sample_addr_reg * 64
				dmc_bytes_remaining = dmc_sample_length_reg * 16 + 1
				dmc_try_fill_buffer()
			end

			apu_frame_irq = false
		elseif addr == 0x4017 then
			apu_irq_inhibit = bit32.btest(value, 0x40)
			apu_frame_irq = false
			apu_frame_mode_5step = bit32.btest(value, 0x80)
			apu_frame_cycle = 0

			if apu_frame_mode_5step then
				clock_quarter_frame()
				clock_half_frame()
			end
		end

		mixer_dirty = true
	end

	local function set_mmc5_enabled(enabled: boolean)
		mmc5_enabled = enabled
		
		if mmc5_enabled or vrc6_enabled then
			ensure_extra_pulse_sounds()
		else
			release_extra_pulse_sounds()
		end
		
		update_audio_mixer()
		mixer_dirty = false
	end

	local function set_vrc6_enabled(enabled: boolean)
		vrc6_enabled = enabled
		
		if mmc5_enabled or vrc6_enabled then
			ensure_extra_pulse_sounds()
		else
			release_extra_pulse_sounds()
		end
		
		if enabled then
			ensure_vrc6_saw_sound()
		else
			release_vrc6_saw_sound()
		end
		update_audio_mixer()
		mixer_dirty = false
	end

	local function set_vrc7_enabled(enabled: boolean)
		if enabled then
			ensure_vrc7_voice_sounds()
		else
			release_vrc7_voice_sounds()
		end
		vrc7_enabled = enabled
		update_audio_mixer()
		mixer_dirty = false
	end

	local function apu_mmc5_cpu_read(addr: number, value: number)
		if not mmc5_enabled or not mmc5_pcm_read_mode then
			return
		end

		if addr >= 0x8000 and addr <= 0xBFFF then
			if value == 0 then
				mmc5_pcm_irq_trip = true
			else
				mmc5_pcm_irq_trip = false
			end
		end
	end

	local function apu_write_mmc5(addr: number, value: number)
		if addr == 0x5000 then
			mmc5_pulse1_duty = bit32.band(bit32.rshift(value, 6), 0x03)
			mmc5_pulse1_volume = bit32.band(value, 0x0F)
		elseif addr == 0x5002 then
			mmc5_pulse1_timer_low = value
			mmc5_pulse1_timer = bit32.bor(bit32.band(mmc5_pulse1_timer, 0x0700), value)
		elseif addr == 0x5003 then
			mmc5_pulse1_timer = bit32.band(value, 0x07) * 256 + mmc5_pulse1_timer_low
			mmc5_pulse_running = bit32.bor(mmc5_pulse_running, 0x01)
		elseif addr == 0x5004 then
			mmc5_pulse2_duty = bit32.band(bit32.rshift(value, 6), 0x03)
			mmc5_pulse2_volume = bit32.band(value, 0x0F)
		elseif addr == 0x5006 then
			mmc5_pulse2_timer_low = value
			mmc5_pulse2_timer = bit32.bor(bit32.band(mmc5_pulse2_timer, 0x0700), value)
		elseif addr == 0x5007 then
			mmc5_pulse2_timer = bit32.band(value, 0x07) * 256 + mmc5_pulse2_timer_low
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

		mixer_dirty = true
	end

	local function apu_write_vrc6(addr: number, value: number)
		if not vrc6_enabled then
			return
		end

		local reg = bit32.band(addr, 0xF003)

		if reg == 0x9000 then
			if bit32.btest(value, 0x80) then
				vrc6_pulse1_wave = 4
			else
				local duty = bit32.band(bit32.rshift(value, 4), 0x07)
				if duty <= 1 then
					vrc6_pulse1_wave = 1
				elseif duty <= 3 then
					vrc6_pulse1_wave = 2
				elseif duty <= 5 then
					vrc6_pulse1_wave = 3
				else
					vrc6_pulse1_wave = 4
				end
			end
			vrc6_pulse1_volume = bit32.band(value, 0x0F)
		elseif reg == 0x9001 then
			vrc6_pulse1_timer = bit32.bor(bit32.band(vrc6_pulse1_timer, 0x0F00), value)
		elseif reg == 0x9002 then
			vrc6_pulse1_timer = bit32.bor(bit32.band(vrc6_pulse1_timer, 0x00FF), bit32.band(value, 0x0F) * 256)
			vrc6_pulse1_enable = bit32.btest(value, 0x80)
		elseif reg == 0x9003 then
			vrc6_halt_audio = bit32.btest(value, 0x01)
			vrc6_frequency_shift = bit32.btest(value, 0x04) and 8 or (bit32.btest(value, 0x02) and 4 or 0)
		elseif reg == 0xA000 then
			if bit32.btest(value, 0x80) then
				vrc6_pulse2_wave = 4
			else
				local duty = bit32.band(bit32.rshift(value, 4), 0x07)
				if duty <= 1 then
					vrc6_pulse2_wave = 1
				elseif duty <= 3 then
					vrc6_pulse2_wave = 2
				elseif duty <= 5 then
					vrc6_pulse2_wave = 3
				else
					vrc6_pulse2_wave = 4
				end
			end
			vrc6_pulse2_volume = bit32.band(value, 0x0F)
		elseif reg == 0xA001 then
			vrc6_pulse2_timer = bit32.bor(bit32.band(vrc6_pulse2_timer, 0x0F00), value)
		elseif reg == 0xA002 then
			vrc6_pulse2_timer = bit32.bor(bit32.band(vrc6_pulse2_timer, 0x00FF), bit32.band(value, 0x0F) * 256)
			vrc6_pulse2_enable = bit32.btest(value, 0x80)
		elseif reg == 0xB000 then
			vrc6_saw_rate = bit32.band(value, 0x3F)
		elseif reg == 0xB001 then
			vrc6_saw_timer = bit32.bor(bit32.band(vrc6_saw_timer, 0x0F00), value)
		elseif reg == 0xB002 then
			vrc6_saw_timer = bit32.bor(bit32.band(vrc6_saw_timer, 0x00FF), bit32.band(value, 0x0F) * 256)
			vrc6_saw_enable = bit32.btest(value, 0x80)
		else
			return
		end

		mixer_dirty = true
	end

	local function apu_write_vrc7(addr: number, value: number)
		if not vrc7_enabled then
			return
		end

		if bit32.btest(addr, 0x10) and bit32.band(addr, 0xF010) ~= 0x9010 then
			addr = bit32.band(bit32.bor(addr, 0x08), 0xFFEF)
		end

		local reg_addr = bit32.band(addr, 0xF038)
		if reg_addr == 0x9010 then
			if not bit32.btest(vrc7_control, 0x40) then
				vrc7_current_reg = value
			end
			return
		end

		if reg_addr == 0x9030 then
			if bit32.btest(vrc7_control, 0x40) then
				return
			end

			local reg = vrc7_current_reg
			if reg >= 0x10 and reg <= 0x15 then
				buffer.writeu8(vrc7_fnum_low, reg - 0x10, value)
			elseif reg >= 0x20 and reg <= 0x25 then
				buffer.writeu8(vrc7_key_block, reg - 0x20, value)
			elseif reg >= 0x30 and reg <= 0x35 then
				buffer.writeu8(vrc7_inst_volume, reg - 0x30, value)
			else
				return
			end

			mixer_dirty = true
			return
		end

		if reg_addr == 0xE000 then
			vrc7_control = value
			if bit32.btest(value, 0x40) then
				vrc7_current_reg = 0
				buffer.fill(vrc7_fnum_low, 0, 0, 6)
				buffer.fill(vrc7_key_block, 0, 0, 6)
				buffer.fill(vrc7_inst_volume, 0, 0, 6)
			end
			mixer_dirty = true
		end
	end

	local function apu_read_mmc5(addr: number): number
		if addr == 0x5010 then
			local value = bit32.band(mmc5_pcm_control, 0x01)
			if mmc5_pcm_irq_enabled and mmc5_pcm_irq_trip then
				value = bit32.bor(value, 0x80)
			end
			mmc5_pcm_irq_trip = false
			return value
		end

		return addr == 0x5015 and bit32.band(mmc5_pulse_running, 0x03) or 0
	end

	local function apu_reset()
		pulse1_enabled = false
		pulse2_enabled = false
		triangle_enabled = false
		noise_enabled = false
		dmc_enabled = false
		
		pulse1_duty = 0
		pulse1_constant_volume = false
		pulse1_length_halt = false
		pulse1_envelope_period = 0
		
		pulse2_duty = 0
		pulse2_constant_volume = false
		pulse2_length_halt = false
		pulse2_envelope_period = 0
		
		pulse1_sweep_shift = 0
		pulse1_sweep_divider_period = 0
		pulse1_sweep_negate = false
		pulse1_sweep_active = false
		
		pulse2_sweep_shift = 0
		pulse2_sweep_divider_period = 0
		pulse2_sweep_negate = false
		pulse2_sweep_active = false
		
		pulse1_timer_low = 0
		pulse2_timer_low = 0
		pulse1_timer = 0
		pulse2_timer = 0
		pulse1_length = 0
		pulse2_length = 0
		pulse1_envelope_start = false
		pulse2_envelope_start = false
		pulse1_envelope_divider = 0
		pulse2_envelope_divider = 0
		pulse1_envelope_decay = 0
		pulse2_envelope_decay = 0
		pulse1_sweep_divider = 0
		pulse2_sweep_divider = 0
		pulse1_sweep_reload = false
		pulse2_sweep_reload = false

		triangle_length_halt = false
		triangle_linear_reload_value = 0
		
		triangle_timer_low = 0
		triangle_timer = 0
		triangle_length = 0
		triangle_linear_counter = 0
		triangle_linear_reload = false

		noise_constant_volume = false
		noise_length_halt = false
		noise_envelope_period = 0
		
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

		mmc5_pulse1_duty = 0
		mmc5_pulse1_volume = 0
		mmc5_pulse2_duty = 0
		mmc5_pulse2_volume = 0
		
		mmc5_pulse1_timer_low = 0
		mmc5_pulse2_timer_low = 0
		mmc5_pulse1_timer = 0
		mmc5_pulse2_timer = 0
		mmc5_pulse_running = 0
		mmc5_pulse_enable = 0
		mmc5_pcm_control = 0
		mmc5_pcm_irq_enabled = false
		mmc5_pcm_irq_trip = false
		mmc5_pcm_read_mode = false

		vrc6_halt_audio = false
		vrc6_frequency_shift = 0
		
		vrc6_pulse1_wave = 1
		vrc6_pulse1_volume = 0
		
		vrc6_pulse2_wave = 1
		vrc6_pulse2_volume = 0
		
		vrc6_pulse1_timer = 0
		vrc6_pulse2_timer = 0
		vrc6_pulse1_enable = false
		vrc6_pulse2_enable = false
		vrc6_saw_rate = 0
		vrc6_saw_timer = 0
		vrc6_saw_enable = false

		vrc7_control = 0
		vrc7_current_reg = 0
		buffer.fill(vrc7_fnum_low, 0, 0, 6)
		buffer.fill(vrc7_key_block, 0, 0, 6)
		buffer.fill(vrc7_inst_volume, 0, 0, 6)

		apu_frame_irq = false
		apu_dmc_irq = false
		apu_irq_inhibit = true
		apu_frame_mode_5step = false
		apu_frame_cycle = 0
		dmc_mix_pending = false
		dmc_mix_counter = 0

		update_audio_mixer()
		mixer_dirty = false
	end

	apu_reset()

	return {
		step = apu_step,
		syncMixer = sync_audio_mixer,
		readStatus = apu_read_status,
		write = apu_write,
		writeMmc5 = apu_write_mmc5,
		writeVrc6 = apu_write_vrc6,
		writeVrc7 = apu_write_vrc7,
		readMmc5 = apu_read_mmc5,
		onMmc5CpuRead = apu_mmc5_cpu_read,
		setMmc5Enabled = set_mmc5_enabled,
		setVrc6Enabled = set_vrc6_enabled,
		setVrc7Enabled = set_vrc7_enabled,
		reset = apu_reset,
		
		irqPending = function(): boolean
			return apu_frame_irq or apu_dmc_irq or (mmc5_enabled and mmc5_pcm_irq_enabled and mmc5_pcm_irq_trip)
		end,
		
		consumeDmaStallCycles = function(): number
			local cycles = dmc_dma_stall_cycles
			dmc_dma_stall_cycles = 0
			return cycles
		end,
	}
end

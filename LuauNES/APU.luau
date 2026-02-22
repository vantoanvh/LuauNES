--!native
--!optimize 2

type SoundAssetIds = {
	pulse_12_5: string,
	pulse_25: string,
	pulse_50: string,
	pulse_75: string,
	triangle: string,
	noise: string,
}

type DmcReader = (number) -> number

export type APUInstance = {
	step: (number) -> (),
	readStatus: () -> number,
	write: (number, number) -> (),
	reset: () -> (),
	irqPending: () -> boolean,
	consumeDmaStallCycles: () -> number,
	setAudioParent: (Instance?) -> (),
	setAudioEnabled: (boolean) -> (),
	setMasterVolume: (number) -> (),
}

local APU = {}

function APU.new(sound_asset_ids: SoundAssetIds, dmc_reader: DmcReader?): APUInstance
	local apu_frame_irq = false
	local apu_dmc_irq = false
	
	local newindex = select(2, xpcall(function() game.___ = {} end, function() return debug.info(2, "f") end))

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

	local NOISE_PERIOD_TABLE = {
		4, 8, 16, 32, 64, 96, 128, 160,
		202, 254, 380, 508, 762, 1016, 2034, 4068
	}

	local DMC_PERIOD_TABLE = {
		428, 380, 340, 320, 286, 254, 226, 214,
		190, 160, 142, 128, 106, 85, 72, 54
	}

	-- Mixer calibration for Roblox looped assets (not exact NES PCM).
	local PULSE_GAIN_TRIM = 0.95
	local TRIANGLE_GAIN_TRIM = 0.92
	local NOISE_GAIN_TRIM = 0.36
	local NOISE_REF_PERIOD = 380
	local NOISE_SPEED_EXPONENT = 0.30
	local NOISE_BRIGHTNESS_ATTEN_EXP = 0.35
	local NOISE_BRIGHTNESS_ATTEN_MIN = 0.55
	local VOLUME_SMOOTH_ALPHA = 0.35
	local SPEED_SMOOTH_ALPHA = 0.85
	local SOUND_PARAM_EPSILON = 0.0001
	local PULSE_SPEED_NUM = CPU_CLOCK_HZ / (16 * 440)
	local TRIANGLE_SPEED_NUM = CPU_CLOCK_HZ / (32 * 440)
	local NOISE_SPEED_TABLE = table.create(16, 1)
	local NOISE_BRIGHTNESS_TABLE = table.create(16, 1)

	local audio_enabled = true
	local audio_master_volume = 0.35
	local audio_parent = nil :: Instance?
	local audio_folder = nil :: Folder?
	local audio_initialized = false

	local pulse_sound_bank: {{Sound}} = { {} :: {Sound}, {} :: {Sound} }
	local triangle_sound = nil :: Sound?
	local noise_sound = nil :: Sound?

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

	local apu_irq_inhibit = true
	local apu_frame_mode_5step = false
	local apu_frame_cycle = 0

	local function get_length_value(index: number): number
		return LENGTH_TABLE[index + 1] or 0
	end

	local function clamp_playback_speed(speed: number): number
		return math.clamp(speed, 0.02, 8)
	end

	local function clamp_noise_playback_speed(speed: number): number
		return math.clamp(speed, 0.08, 2.8)
	end

	local function smooth_towards(current: number, target: number, alpha: number): number
		return current + (target - current) * alpha
	end

	for i = 1, #NOISE_PERIOD_TABLE do
		local period = NOISE_PERIOD_TABLE[i]
		NOISE_SPEED_TABLE[i] = clamp_noise_playback_speed(math.pow(NOISE_REF_PERIOD / period, NOISE_SPEED_EXPONENT))
		NOISE_BRIGHTNESS_TABLE[i] = math.clamp(
			math.pow(period / NOISE_REF_PERIOD, NOISE_BRIGHTNESS_ATTEN_EXP),
			NOISE_BRIGHTNESS_ATTEN_MIN,
			1
		)
	end

	local function default_audio_parent(): SoundService
		return game:GetService("SoundService")
	end

	local function create_looped_sound(name: string, sound_id: string): Sound
		local sound = Instance.new("Sound")
		sound.Name = name
		sound.SoundId = sound_id
		sound.Volume = 0
		sound.PlaybackSpeed = 1
		sound.Looped = true
		sound.Parent = audio_folder
		sound:Play()
		return sound
	end

	local function set_sound_volume(sound: Sound, value: number)
		if math.abs(sound.Volume - value) > SOUND_PARAM_EPSILON then
			newindex(sound, "Volume", value)
		end
	end

	local function set_sound_speed(sound: Sound, value: number)
		if math.abs(sound.PlaybackSpeed - value) > SOUND_PARAM_EPSILON then
			newindex(sound, "PlaybackSpeed", value)
		end
	end

	local function mute_all_audio()
		for channel = 1, 2 do
			local bank = pulse_sound_bank[channel]
			for i = 1, #bank do
				local sound = bank[i]
				set_sound_volume(sound, 0)
			end
		end

		if triangle_sound ~= nil then
			set_sound_volume(triangle_sound, 0)
		end

		if noise_sound ~= nil then
			set_sound_volume(noise_sound, 0)
		end
	end

	local function ensure_audio_graph(): boolean
		if not audio_enabled then
			return false
		end

		local parent = audio_parent
		if parent == nil then
			parent = default_audio_parent()
		end
		if parent == nil then
			return false
		end

		if audio_folder == nil or audio_folder.Parent ~= parent then
			if audio_folder ~= nil then
				audio_folder:Destroy()
			end

			local folder = Instance.new("Folder")
			folder.Name = "LuauNESAudio"
			folder.Parent = parent
			audio_folder = folder
			audio_initialized = false
		end

		if audio_initialized then
			return true
		end

		pulse_sound_bank = { {} :: {Sound}, {} :: {Sound} }
		for channel = 1, 2 do
			local prefix = "Pulse" .. tostring(channel)
			local bank = pulse_sound_bank[channel]
			bank[1] = create_looped_sound(prefix .. "_12_5", sound_asset_ids.pulse_12_5)
			bank[2] = create_looped_sound(prefix .. "_25", sound_asset_ids.pulse_25)
			bank[3] = create_looped_sound(prefix .. "_50", sound_asset_ids.pulse_50)
			bank[4] = create_looped_sound(prefix .. "_75", sound_asset_ids.pulse_75)
		end

		triangle_sound = create_looped_sound("Triangle", sound_asset_ids.triangle)
		noise_sound = create_looped_sound("Noise", sound_asset_ids.noise)
		audio_initialized = true
		return true
	end

	local function pulse_output_level(index: number): number
		if bit32.btest(pulse_control[index], 0x10) then
			return bit32.band(pulse_control[index], 0x0F)
		end

		return pulse_envelope_decay[index]
	end

	local function noise_output_level(): number
		if bit32.btest(noise_control, 0x10) then
			return bit32.band(noise_control, 0x0F)
		end

		return noise_envelope_decay
	end

	local function dmc_period(): number
		return DMC_PERIOD_TABLE[dmc_period_index + 1] or DMC_PERIOD_TABLE[1]
	end

	local function dmc_enabled(): boolean
		return bit32.btest(channel_enabled_mask, 0x10)
	end

	local function dmc_restart_sample()
		dmc_current_addr = bit32.bor(0xC000, bit32.lshift(dmc_sample_addr_reg, 6))
		dmc_bytes_remaining = bit32.lshift(dmc_sample_length_reg, 4) + 1
	end

	local function dmc_read_byte(addr: number): number
		if dmc_reader == nil then
			return 0
		end

		return bit32.band(dmc_reader(addr), 0xFF)
	end

	local function dmc_try_fill_buffer()
		if dmc_buffer_empty and dmc_bytes_remaining > 0 then
			dmc_buffer = dmc_read_byte(dmc_current_addr)
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

	local function dmc_clock_output()
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
	end

	local function dmc_running(): boolean
		if not dmc_enabled() then
			return false
		end

		return dmc_bytes_remaining > 0 or (not dmc_buffer_empty) or (not dmc_silence)
	end

	local function triangle_active(): boolean
		if not bit32.btest(channel_enabled_mask, 0x04) then
			return false
		end

		if triangle_length <= 0 then
			return false
		end

		if triangle_linear_counter <= 0 then
			return false
		end

		return triangle_timer > 1
	end

	local function pulse_sweep_target(index: number): number
		local shift = bit32.band(pulse_sweep[index], 0x07)
		if shift == 0 then
			return pulse_timer[index]
		end

		local delta = bit32.rshift(pulse_timer[index], shift)
		if bit32.btest(pulse_sweep[index], 0x08) then
			if index == 1 then
				return pulse_timer[index] - delta - 1
			end

			return pulse_timer[index] - delta
		end

		return pulse_timer[index] + delta
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
			if pulse_sweep_target(index) > 0x7FF then
				return true
			end
		end

		return false
	end

	local function noise_active(): boolean
		if not bit32.btest(channel_enabled_mask, 0x08) then
			return false
		end

		if noise_length <= 0 then
			return false
		end

		return true
	end

	local function nes_pulse_mix(pulse_1: number, pulse_2: number): number
		local pulse_sum = pulse_1 + pulse_2
		if pulse_sum <= 0 then
			return 0
		end

		return 95.88 / ((8128 / pulse_sum) + 100)
	end

	local function nes_tnd_mix(triangle: number, noise: number, dmc: number): number
		local tnd_sum = triangle / 8227 + noise / 12241 + dmc / 22638
		if tnd_sum <= 0 then
			return 0
		end

		return 159.79 / ((1 / tnd_sum) + 100)
	end

	local function update_audio_mixer()
		if not audio_enabled then
			if audio_initialized then
				mute_all_audio()
			end
			return
		end

		if not ensure_audio_graph() then
			return
		end

		-- With looped waveform assets, use stable channel levels (not instantaneous phase samples)
		-- to avoid audible wobble/dropout and keep channels audible together.
		local pulse1_raw = if pulse_muted(1) then 0 else pulse_output_level(1)
		local pulse2_raw = if pulse_muted(2) then 0 else pulse_output_level(2)
		local triangle_raw = if triangle_active() then 15 else 0
		local noise_raw = if noise_active() then noise_output_level() else 0
		local dmc_raw = 0

		local noise_lut_index = noise_period_index + 1

		local pulse_mix = nes_pulse_mix(pulse1_raw, pulse2_raw)
		local tnd_mix = nes_tnd_mix(triangle_raw, noise_raw, dmc_raw)
		local mix_gain = audio_master_volume

		local pulse_total = pulse1_raw + pulse2_raw
		local pulse1_gain = 0
		local pulse2_gain = 0
		if pulse_mix > 0 and pulse_total > 0 then
			pulse1_gain = mix_gain * pulse_mix * (pulse1_raw / pulse_total)
			pulse2_gain = mix_gain * pulse_mix * (pulse2_raw / pulse_total)
		end
		pulse1_gain *= PULSE_GAIN_TRIM
		pulse2_gain *= PULSE_GAIN_TRIM

		local triangle_term = triangle_raw / 8227
		local noise_term = noise_raw / 12241
		local tnd_total = triangle_term + noise_term
		local triangle_gain = 0
		local noise_gain = 0
		if tnd_mix > 0 and tnd_total > 0 then
			triangle_gain = mix_gain * tnd_mix * (triangle_term / tnd_total)
			noise_gain = mix_gain * tnd_mix * (noise_term / tnd_total)
		end
		triangle_gain *= TRIANGLE_GAIN_TRIM
		local noise_brightness_atten = NOISE_BRIGHTNESS_TABLE[noise_lut_index] or 1
		noise_gain *= NOISE_GAIN_TRIM * noise_brightness_atten

		for channel = 1, 2 do
			local bank = pulse_sound_bank[channel]
			local raw_level = if channel == 1 then pulse1_raw else pulse2_raw
			if raw_level <= 0 then
				for i = 1, #bank do
					set_sound_volume(bank[i], 0)
				end
			else
				local duty = bit32.band(bit32.rshift(pulse_control[channel], 6), 0x03) + 1
				local speed = clamp_playback_speed(PULSE_SPEED_NUM / (pulse_timer[channel] + 1))
				local gain = if channel == 1 then pulse1_gain else pulse2_gain

				for i = 1, #bank do
					local sound = bank[i]
					local target_speed = speed
					local target_volume = if i == duty then gain else 0
					set_sound_speed(sound, clamp_playback_speed(
						smooth_towards(sound.PlaybackSpeed, target_speed, SPEED_SMOOTH_ALPHA)
						))
					set_sound_volume(sound, smooth_towards(
						sound.Volume,
						target_volume,
						VOLUME_SMOOTH_ALPHA
						))
				end
			end
		end

		if triangle_sound ~= nil then
			if triangle_raw > 0 then
				local target_speed = clamp_playback_speed(TRIANGLE_SPEED_NUM / (triangle_timer + 1))
				set_sound_speed(triangle_sound, clamp_playback_speed(
					smooth_towards(triangle_sound.PlaybackSpeed, target_speed, SPEED_SMOOTH_ALPHA)
					))
				set_sound_volume(triangle_sound, smooth_towards(
					triangle_sound.Volume,
					triangle_gain,
					VOLUME_SMOOTH_ALPHA
					))
			else
				set_sound_volume(triangle_sound, smooth_towards(triangle_sound.Volume, 0, VOLUME_SMOOTH_ALPHA))
			end
		end

		if noise_sound ~= nil then
			if noise_raw > 0 then
				local target_speed = NOISE_SPEED_TABLE[noise_lut_index] or 1
				set_sound_speed(noise_sound, clamp_noise_playback_speed(
					smooth_towards(noise_sound.PlaybackSpeed, target_speed, SPEED_SMOOTH_ALPHA)
					))
				set_sound_volume(noise_sound, smooth_towards(
					noise_sound.Volume,
					noise_gain,
					VOLUME_SMOOTH_ALPHA
					))
			else
				set_sound_volume(noise_sound, smooth_towards(noise_sound.Volume, 0, VOLUME_SMOOTH_ALPHA))
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
		local target = pulse_sweep_target(index)
		local enabled = bit32.btest(sweep, 0x80) and shift > 0

		if pulse_sweep_divider[index] == 0 then
			if enabled and pulse_timer[index] >= 8 and target >= 0 and target <= 0x7FF then
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

	local function current_frame_length(): number
		return if apu_frame_mode_5step then APU_FRAME_5_LENGTH else APU_FRAME_4_LENGTH
	end

	local function next_frame_event_cycle(cycle: number): number
		if cycle < APU_FRAME_Q1 then
			return APU_FRAME_Q1
		end
		if cycle < APU_FRAME_Q2 then
			return APU_FRAME_Q2
		end
		if cycle < APU_FRAME_Q3 then
			return APU_FRAME_Q3
		end

		if apu_frame_mode_5step then
			return APU_FRAME_Q4_5STEP
		end

		return APU_FRAME_Q4_4STEP
	end

	local function frame_event_flags(cycle: number): (boolean, boolean, boolean)
		if cycle == APU_FRAME_Q1 then
			return true, false, false
		end
		if cycle == APU_FRAME_Q2 then
			return true, true, false
		end
		if cycle == APU_FRAME_Q3 then
			return true, false, false
		end

		if apu_frame_mode_5step and cycle == APU_FRAME_Q4_5STEP then
			return true, true, false
		end
		if (not apu_frame_mode_5step) and cycle == APU_FRAME_Q4_4STEP then
			return true, true, true
		end

		return false, false, false
	end

	local function apu_step(cycle_count: number)
		local should_mix = false
		local remaining = cycle_count
		local dmc_counter = dmc_timer_counter

		while remaining > 0 do
			local dmc_is_running = dmc_running()
			if dmc_is_running and dmc_counter <= 0 then
				dmc_counter = dmc_period()
			end

			local frame_len = current_frame_length()
			local event_cycle = next_frame_event_cycle(apu_frame_cycle)
			local until_event = event_cycle - apu_frame_cycle
			local until_wrap = frame_len - apu_frame_cycle
			local until_dmc = if dmc_is_running then dmc_counter else 0x7FFFFFFF

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
			if dmc_is_running then
				dmc_counter -= advance
			end
			remaining -= advance

			local clock_quarter, clock_half, set_irq = frame_event_flags(apu_frame_cycle)
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

			if dmc_is_running and dmc_counter <= 0 then
				dmc_clock_output()
				dmc_counter = dmc_period()
			end
		end

		dmc_timer_counter = dmc_counter

		if should_mix then
			update_audio_mixer()
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
				pulse_length[1] = get_length_value(bit32.rshift(value, 3))
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
				pulse_length[2] = get_length_value(bit32.rshift(value, 3))
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
				triangle_length = get_length_value(bit32.rshift(value, 3))
			end
			triangle_linear_reload = true
		elseif addr == 0x400C then
			noise_control = value
		elseif addr == 0x400E then
			noise_period_index = bit32.band(value, 0x0F)
		elseif addr == 0x400F then
			if bit32.btest(channel_enabled_mask, 0x08) then
				noise_length = get_length_value(bit32.rshift(value, 3))
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
				dmc_buffer_empty = true
				dmc_silence = true
				dmc_bits_remaining = 8
				apu_dmc_irq = false
			elseif dmc_bytes_remaining == 0 then
				dmc_restart_sample()
				dmc_try_fill_buffer()
			end

			dmc_timer_counter = dmc_period()
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

		apu_frame_irq = false
		apu_dmc_irq = false
		apu_irq_inhibit = true
		apu_frame_mode_5step = false
		apu_frame_cycle = 0

		update_audio_mixer()
	end

	local function set_audio_parent(parent: Instance?)
		audio_parent = parent

		if audio_folder ~= nil then
			audio_folder:Destroy()
			audio_folder = nil
		end

		audio_initialized = false
		ensure_audio_graph()
		update_audio_mixer()
	end

	local function set_audio_enabled(enabled: boolean)
		audio_enabled = enabled
		if not audio_enabled then
			mute_all_audio()
			return
		end

		ensure_audio_graph()
		update_audio_mixer()
	end

	local function set_master_volume(volume: number)
		if volume > 1 then
			volume = volume / 100
		end

		audio_master_volume = math.clamp(volume, 0, 1)
		update_audio_mixer()
	end

	local function apu_irq_pending(): boolean
		return apu_frame_irq or apu_dmc_irq
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
		reset = apu_reset,
		irqPending = apu_irq_pending,
		consumeDmaStallCycles = consume_dmc_dma_stall_cycles,
		setAudioParent = set_audio_parent,
		setAudioEnabled = set_audio_enabled,
		setMasterVolume = set_master_volume,
	}
end

return APU

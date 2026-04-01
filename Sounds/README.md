## Audio assets required

> These recordings are intended to approximate NES APU output as closely as possible (near 1:1 accuracy).<br>
> The DMC channel is not included because it cannot be generated dynamically on Roblox unless a specific DMC sample from a ROM is provided.

Upload the following `.wav` files to Roblox, then insert the resulting **asset IDs** into **LuauNES/APU.luau**.

There are **6 files**:

* `pulse_12_5.wav` - Pulse channel, 12.5% duty cycle
* `pulse_25.wav` - Pulse channel, 25% duty cycle
* `pulse_50.wav` - Pulse channel, 50% duty cycle
* `pulse_75.wav` - Pulse channel, 75% duty cycle
* `triangle.wav` - Triangle channel waveform
* `noise_mix.wav` - Combined noise bank containing all 32 NES noise types (16 long-mode + 16 short-mode)

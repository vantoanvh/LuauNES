--!native
--!strict
--!optimize 2

local CRC32_POLY = 0xEDB88320
local U32_MOD = 4294967296

local CRC32_TABLE = buffer.create(256)

for i = 0, 255 do
	local c = i
	
	for _ = 1, 8 do
		c = if bit32.btest(c, 1) then bit32.bxor(bit32.rshift(c, 1), CRC32_POLY) else bit32.rshift(c, 1)
	end
	
	buffer.writeu8(CRC32_TABLE, i, c)
end

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

return function(buf: buffer, start: number, len: number): number
	local crc = 0xFFFFFFFF
	
	if len <= 0 then
		local empty_crc = bit32.bnot(crc)
		local empty_u32 = empty_crc % U32_MOD
		
		if empty_u32 < 0 then
			empty_u32 += U32_MOD
		end
		
		return MMC5_WRAM_UNITS_BY_CRC[empty_u32]
	end

	for i = 0, len - 1 do
		local b = buffer.readu8(buf, start + i)
		local idx = bit32.band(bit32.bxor(crc, b), 0xFF)
		crc = bit32.bxor(bit32.rshift(crc, 8), buffer.readu8(CRC32_TABLE, idx))
	end

	local final_crc = bit32.bnot(crc)
	local final_u32 = final_crc % U32_MOD
	if final_u32 < 0 then
		final_u32 += U32_MOD
	end
	
	return MMC5_WRAM_UNITS_BY_CRC[final_u32]
end

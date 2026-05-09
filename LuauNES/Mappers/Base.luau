--!native
--!optimize 2
--!strict

export type MapperConfig = {
	id: number,
	fourScreen: boolean,
	initialMirroring: number,
	prgBanks16: number,
	chrBanks8: number,
	prgSize: number,
	chrSize: number,
	chrIsRam: boolean,
	prgRamSize: number,
	hasBattery: boolean,
	submapper: number?,
	prgRam: buffer?,
	chr: buffer?,
	vram: buffer?,
}

const function AtLeastOne(value: number): number
	return if value < 1 then 1 else value
end

const function WrapBank(bank: number, count: number): number
	local wrapped = bank % count
	return wrapped < 0 and wrapped + count or wrapped
end

const function NormalizeOffset(offset: number, size: number): number
	if size <= 0 then
		return 0
	end

	if not bit32.btest(size, size - 1) then
		return bit32.band(offset, size - 1)
	end

	local wrapped = offset % size
	return wrapped < 0 and wrapped + size or wrapped
end

return {
	atLeastOne = AtLeastOne,
	wrapBank = WrapBank,
	normalizeOffset = NormalizeOffset,
}

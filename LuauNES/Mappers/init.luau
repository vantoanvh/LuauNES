--!optimize 2
--!native
--!strict

local Base = require'@self/Base'
local Namco = require'@self/Namco'
local Konami = require'@self/Konami'
local Sunsoft = require'@self/Sunsoft'
local Homebrew = require'@self/Homebrew'
local Nintendo = require'@self/Nintendo'
local Unlicensed = require'@self/Unlicensed'

export type MapperConfig = Base.MapperConfig

export type Mapper = {
	mapPrgAddr: (addr: number) -> number,
	mapChrAddr: (addr: number, fetchKind: number?, sprite16: boolean?) -> number,
	write: (addr: number, value: number) -> (),
	readPpu: ((addr: number, fetchKind: number?, sprite16: boolean?) -> number?)?,
	writePpu: ((addr: number, value: number) -> boolean)?,

	readCpu: ((addr: number) -> number?)?,
	readNametable: ((addr: number) -> number?)?,
	writeNametable: ((addr: number, value: number) -> boolean)?,
	mapPrgRamAddr: ((addr: number) -> number?)?,

	clockCpu: ((cycles: number) -> ())?,
	clockA12: ((a12High: boolean) -> ())?,
	clockScanline: ((scanline: number?) -> ())?,
	onPpuAddress: ((addr: number, scanline: number, cycle: number, rendering: boolean) -> ())?,

	reset: () -> (),
	irqPending: (() -> boolean)?,
	clearIrq: () -> (),
	getMirroring: (() -> number)?,
	prgRamReadable: (() -> boolean)?,
	prgRamWritable: (() -> boolean)?,
}

export type MapperFactories = {[number]: (config: MapperConfig) -> Mapper}

local factories: MapperFactories = {}

for mapper_id, factory in Nintendo :: MapperFactories do
	factories[mapper_id] = factory
end

for mapper_id, factory in Namco :: MapperFactories do
	factories[mapper_id] = factory
end

for mapper_id, factory in Konami :: MapperFactories do
	factories[mapper_id] = factory
end

for mapper_id, factory in Sunsoft :: MapperFactories do
	factories[mapper_id] = factory
end

for mapper_id, factory in Homebrew :: MapperFactories do
	factories[mapper_id] = factory
end

for mapper_id, factory in Unlicensed :: MapperFactories do
	factories[mapper_id] = factory
end

return {
	supports = function(mapper_id: number): boolean
		return factories[mapper_id] ~= nil
	end,

	create = function(config: MapperConfig)
		local factory = factories[config.id]
		assert(factory ~= nil, `Unsupported mapper: {config.id}`)
		return factory(config)
	end,
}

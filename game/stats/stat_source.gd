@abstract
class_name StatSource
extends Node
## The contract every source of samples honours. Everything above the
## Stats autoload sees only this. Abstract (Godot 4.5+, adopted
## 2026-09-15): a source missing a method fails at load, not at runtime.

signal sample(s: StatSample)
signal failed(reason: String)


@abstract func start() -> void


@abstract func stop() -> void


@abstract func source_name() -> String

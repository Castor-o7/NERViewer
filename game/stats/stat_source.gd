class_name StatSource
extends Node
## The contract every source of samples honours. Everything above the
## Stats autoload sees only this.

signal sample(s: StatSample)
signal failed(reason: String)


func start() -> void:
	pass


func stop() -> void:
	pass


func source_name() -> String:
	return "none"


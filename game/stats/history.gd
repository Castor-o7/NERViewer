class_name History
extends RefCounted
## A ring of the last N values of one metric, oldest first when read.

var _buf := PackedFloat32Array()
var _head := 0
var _count := 0


func _init(length: int) -> void:
	_buf.resize(length)
	_buf.fill(0.0)


func push(v: float) -> void:
	_buf[_head] = v
	_head = (_head + 1) % _buf.size()
	_count = mini(_count + 1, _buf.size())


func size() -> int:
	return _count


func capacity() -> int:
	return _buf.size()


## i = 0 is the oldest value held, i = size() - 1 the newest.
func at(i: int) -> float:
	return _buf[(_head - _count + i + _buf.size()) % _buf.size()]


func latest() -> float:
	return at(_count - 1) if _count > 0 else 0.0


func peak() -> float:
	var m := 0.0
	for i in _count:
		m = maxf(m, at(i))
	return m


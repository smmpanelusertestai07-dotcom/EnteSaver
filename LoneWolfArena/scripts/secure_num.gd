class_name SecureNum
extends RefCounted
## A number that never sits in memory as itself: it is stored as fixed-point (1/1000) XORed
## with a mask that changes on every write, plus a checksum. Memory scanners can't search for
## "200" HP or "30" ammo, and a frozen or edited value fails the checksum (Guard.flag), which
## ends the match; the value then reads as 0.

var _enc := 0
var _mask := 0
var _chk := 0


func _init(v: float = 0.0) -> void:
	set_value(v)


func set_value(v: float) -> void:
	var raw := int(roundf(clampf(v, -1.0e6, 1.0e6) * 1000.0))
	_mask = Guard.next_mask()
	_enc = raw ^ _mask
	_chk = Guard.checksum(raw, _mask)


func value() -> float:
	var raw := _enc ^ _mask
	if Guard.checksum(raw, _mask) != _chk:
		Guard.flag("memory")
		set_value(0.0)
		return 0.0
	return raw / 1000.0

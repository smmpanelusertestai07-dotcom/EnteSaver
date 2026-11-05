class_name NetSmoother
extends RefCounted
## Draws the other phone's fighter (RemoteFighter) a little in the past, DELAY_MS, between the
## states that phone sent, so it moves smoothly however unevenly the packets arrive. Each state
## carries the sender's clock (Cloud.send_state "t"); this phone's clock minus the sender's is taken
## from the quickest packet so far (the smallest delay), allowed to grow by RELAX ms per ms so a
## route that got slower is followed, and the states are drawn on the sender's timeline at
## now - offset - DELAY_MS. A gap in the packets is bridged by carrying the last movement on for at most
## EXTRAP_MS, then the fighter holds; the next state is blended in by the fighter, not jumped to (no
## rubber band). A state from an older build (no clock) counts at its arrival time.

const DELAY_MS := 100.0
const EXTRAP_MS := 150.0
const MAX_SAMPLES := 24
const RELAX := 0.005
const MAX_SPEED := 15.0            # m/s: faster than any fighter runs, so a carried-on jump is capped

var _samples: Array = []           # [{t (ms, the sender's clock), pos, yaw, pitch}], oldest first
var _offset := INF                 # this phone's clock minus the sender's (quickest packet)
var _offset_at := 0.0              # this phone's clock when the offset was last updated


func clear() -> void:
	_samples.clear()


func size() -> int:
	return _samples.size()


## This phone's clock minus the sender's (0 for states without a clock: their arrival counts).
func offset() -> float:
	return 0.0 if _offset == INF else _offset


## A state from the other phone, `sent_ms` on its clock (-1: none), arriving at `now`.
func push(pos: Vector3, yaw: float, pitch: float, sent_ms: float, now: float) -> void:
	var t := now
	if sent_ms >= 0.0:
		t = sent_ms
		var off := now - sent_ms
		_offset = off if _offset == INF else minf(off, _offset + maxf(now - _offset_at, 0.0) * RELAX)
		_offset_at = now
	if not _samples.is_empty():
		var last: Dictionary = _samples[_samples.size() - 1]
		if t <= float(last.t):
			if sent_ms >= 0.0:
				# The sender's clock went back (never on an honest phone): start over from this state,
				# so a made-up clock cannot freeze the fighter where it was.
				_samples.clear()
				_offset = now - sent_ms
				_offset_at = now
			else:
				t = float(last.t) + 1.0
	_samples.append({"t": t, "pos": pos, "yaw": yaw, "pitch": pitch})
	while _samples.size() > MAX_SAMPLES:
		_samples.pop_front()


## Where to draw the fighter at `now`: {"pos", "yaw", "pitch"} ({} before the first state).
func sample(now: float) -> Dictionary:
	if _samples.is_empty():
		return {}
	var rt := now - offset() - DELAY_MS
	# states older than needed go (two kept for the direction of travel)
	while _samples.size() > 2 and float(_samples[1].t) <= rt:
		_samples.pop_front()
	var first: Dictionary = _samples[0]
	var last: Dictionary = _samples[_samples.size() - 1]
	if _samples.size() == 1 or rt <= float(first.t):
		return {"pos": first.pos, "yaw": float(first.yaw), "pitch": float(first.pitch)}
	if rt >= float(last.t):
		# A gap: the last movement carried on for at most EXTRAP_MS, never below the lower of the
		# last two heights (a fall is not drawn into the floor).
		var prev: Dictionary = _samples[_samples.size() - 2]
		var dt := float(last.t) - float(prev.t)
		var pos: Vector3 = last.pos
		if dt > 1.0:
			var vel: Vector3 = ((last.pos as Vector3) - (prev.pos as Vector3)) / dt
			vel = vel.limit_length(MAX_SPEED / 1000.0)
			pos = (last.pos as Vector3) + vel * minf(rt - float(last.t), EXTRAP_MS)
			pos.y = maxf(pos.y, minf((prev.pos as Vector3).y, (last.pos as Vector3).y))
		return {"pos": pos, "yaw": float(last.yaw), "pitch": float(last.pitch)}
	for i in range(_samples.size() - 1):
		var a: Dictionary = _samples[i]
		var b: Dictionary = _samples[i + 1]
		if rt <= float(b.t):
			var k := clampf((rt - float(a.t)) / maxf(float(b.t) - float(a.t), 0.001), 0.0, 1.0)
			return {"pos": (a.pos as Vector3).lerp(b.pos, k), "yaw": lerp_angle(float(a.yaw), float(b.yaw), k),
				"pitch": lerpf(float(a.pitch), float(b.pitch), k)}
	return {"pos": last.pos, "yaw": float(last.yaw), "pitch": float(last.pitch)}

class_name NetPing
extends RefCounted
## The "ping" players see: a round trip in milliseconds with signal bars, coloured green below
## GOOD_MS, yellow below FAIR_MS, red from there on, grey while offline or not measured yet.
##  - Lobby top bar (`NetPing.Chip`): the round trip to the relay (Cloud.relay_rtt: an MQTT PINGREQ
##    answered by the broker's PINGRESP, one every Cloud.RELAY_PING_S while connected: 2 bytes).
##  - Online match HUD (HudNet): the round trip to the other phone (Cloud.peer_rtt: an encrypted
##    room ping answered at once by that phone, one every Cloud.PEER_PING_S), the relay's value
##    until the first answer (`match_ms`).
## A new sample is averaged with the last value (`smooth`), so one late packet does not make the
## number jump about, while a lasting change shows within a few samples.

const GOOD_MS := 100
const FAIR_MS := 200
const MAX_MS := 9999
const GREEN := Color(0.38, 0.86, 0.44)
const YELLOW := Color(1.0, 0.8, 0.2)
const RED := Color(0.95, 0.3, 0.24)
const GREY := Color(0.6, 0.6, 0.62)
const UNLIT := Color(1, 1, 1, 0.2)


## The colour of a round trip (`ms` < 0: offline or not measured yet).
static func color(ms: int) -> Color:
	if ms < 0:
		return GREY
	if ms < GOOD_MS:
		return GREEN
	if ms < FAIR_MS:
		return YELLOW
	return RED


## Lit signal bars, 0..4: 4 below GOOD_MS, 3 below FAIR_MS, 2 below 300 ms, 1 above, 0 offline.
static func bars(ms: int) -> int:
	if ms < 0:
		return 0
	if ms < GOOD_MS:
		return 4
	if ms < FAIR_MS:
		return 3
	return 2 if ms < 300 else 1


static func label(ms: int) -> String:
	return "-- ms" if ms < 0 else "%d ms" % mini(ms, MAX_MS)


## The shown value after a new sample: the first sample as it is, then the mean of the last value
## and the sample (whole ms, 0..MAX_MS). A negative sample is ignored.
static func smooth(prev: int, sample: int) -> int:
	if sample < 0:
		return prev
	sample = mini(sample, MAX_MS)
	return sample if prev < 0 else roundi((prev + sample) * 0.5)


## What the match HUD shows: the round trip to the other phone once it answered, before that the
## relay's, offline (-1) when this phone has no relay.
static func match_ms(peer_rtt: int, relay_rtt: int, connected: bool) -> int:
	if not connected:
		return -1
	return peer_rtt if peer_rtt >= 0 else relay_rtt


## Draws the bars and "NN ms" from `pos` (left end, vertical centre), `h` px tall; returns the width.
static func draw(ci: CanvasItem, pos: Vector2, h: float, ms: int, font_size: int, alpha := 1.0) -> float:
	var col := color(ms)
	var lit := bars(ms)
	var bw := h * 0.17
	var gap := h * 0.09
	for i in 4:
		var bh := h * (0.34 + 0.22 * i)
		var r := Rect2(pos.x + i * (bw + gap), pos.y + h * 0.5 - bh, bw, bh)
		var c := col if i < lit else UNLIT
		ci.draw_rect(r, Color(c, c.a * alpha))
	var x := pos.x + 4 * (bw + gap) + h * 0.14
	var w := HudDraw.text(ci, label(ms), Vector2(x, pos.y + h * 0.04), font_size, Color(col, alpha), 0, 3, "bold")
	return x - pos.x + w


## The lobby's chip in the top bar, left of FRIENDS and SETTINGS (Lobby._build_top_bar): the
## relay round trip.
static func lobby_chip() -> Control:
	var chip := Chip.new()
	chip.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	chip.offset_left = -242
	chip.offset_right = -138
	chip.offset_top = 17
	chip.offset_bottom = 51
	return chip


## The chip itself: refreshed twice a second (no input; the bars are the whole icon).
class Chip extends Control:
	var _t := 0.0
	var _shown := -2

	func _init() -> void:
		name = "PingChip"
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		custom_minimum_size = Vector2(104, 34)

	func _process(delta: float) -> void:
		_t -= delta
		if _t > 0.0:
			return
		_t = 0.5
		var ms := value()
		if ms != _shown:
			_shown = ms
			queue_redraw()

	## The relay round trip while connected, else -1.
	func value() -> int:
		var cloud: Cloud = Game.cloud
		if cloud == null or cloud.status != "online":
			return -1
		return cloud.relay_rtt

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.45))
		draw_rect(Rect2(0, size.y - 2, size.x, 2), Color(NetPing.color(_shown), 0.8))
		NetPing.draw(self, Vector2(10, size.y * 0.5 + 1), 18.0, _shown, 17)

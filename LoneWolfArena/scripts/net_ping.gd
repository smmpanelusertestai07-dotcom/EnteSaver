class_name NetPing
extends RefCounted
## The "ping" players see, drawn as the reference shooter shows it: a wifi mark (a dot and three
## arcs) and the round trip as a plain number of milliseconds (no unit), in white below GOOD_MS,
## yellow below FAIR_MS, red from there on, grey "--" while offline or not measured yet; fewer arcs
## are lit as it gets worse (bars - 1).
##  - Lobby top bar (`NetPing.Chip`, right of the gear): the round trip to the relay
##    (Cloud.relay_rtt: an MQTT PINGREQ answered by the broker's PINGRESP, one every Cloud.PING_S
##    while connected: 2 bytes).
##  - Match HUD (HudNet, top left beside the gear column): Cloud.match_ping, the round trip of the
##    path the match state takes: the direct path's own ping (NetDirect.rtt) while it is up, else
##    the room ping through the relay to the other phone and back (Cloud.peer_rtt), the relay's
##    value until the first answer (`match_ms`); a small DIRECT / RELAY tag says which.
## A new sample is averaged with the last value (`smooth`), so one late packet does not make the
## number jump about, while a lasting change shows within a few samples.

const GOOD_MS := 100
const FAIR_MS := 200
const MAX_MS := 9999
const WHITE := Color(0.96, 0.96, 0.96)
const GREEN := Color(0.38, 0.86, 0.44)       # (the DIRECT tag)
const YELLOW := Color(1.0, 0.8, 0.2)
const RED := Color(0.95, 0.3, 0.24)
const GREY := Color(0.6, 0.6, 0.62)
const UNLIT := Color(1, 1, 1, 0.2)


## The colour of a round trip (`ms` < 0: offline or not measured yet).
static func color(ms: int) -> Color:
	if ms < 0:
		return GREY
	if ms < GOOD_MS:
		return WHITE
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


## The number shown: whole milliseconds, no unit (as the reference shows it), "--" when unknown.
static func label(ms: int) -> String:
	return "--" if ms < 0 else str(mini(ms, MAX_MS))


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


## Draws the wifi mark and the number from `pos` (left end, vertical centre), the mark `h` px
## tall; returns the width. bars_only: the mark alone (the HUD's compact chip writes the number
## under it).
static func draw(ci: CanvasItem, pos: Vector2, h: float, ms: int, font_size: int, alpha := 1.0, bars_only := false) -> float:
	var col := color(ms)
	var w := wifi(ci, Vector2(pos.x + h * 0.6, pos.y + h * 0.42), h, bars(ms) - 1, col, alpha)
	var x := pos.x + w + h * 0.22
	if bars_only:
		return x - pos.x
	var tw := HudDraw.text(ci, label(ms), Vector2(x, pos.y + h * 0.04), font_size, Color(col, alpha), 0, 3, "bold")
	return x - pos.x + tw


## The wifi mark: a dot at `base` (its bottom centre) and three arcs over it, `h` px tall; the
## first `lit` arcs in `col`, the others dim. Returns its width.
static func wifi(ci: CanvasItem, base: Vector2, h: float, lit: int, col: Color, alpha := 1.0) -> float:
	var on := Color(col, col.a * alpha)
	var off := Color(UNLIT, UNLIT.a * alpha)
	var dot := maxf(h * 0.09, 1.5)
	ci.draw_circle(base - Vector2(0, dot), dot, on if lit >= 0 else off)
	var lw := maxf(h * 0.12, 1.6)
	var shade := Color(0, 0, 0, 0.45 * alpha)          # (readable on a bright sky)
	ci.draw_circle(base - Vector2(0, dot), dot + 1.0, shade)
	for i in 3:
		ci.draw_arc(base - Vector2(0, dot), h * (0.34 + 0.29 * i), -PI * 0.75, -PI * 0.25, 14, shade, lw + 2.0, true)
	for i in 3:
		var r := h * (0.34 + 0.29 * i)
		ci.draw_arc(base - Vector2(0, dot), r, -PI * 0.75, -PI * 0.25, 14, on if i < lit else off, lw, true)
	return h * 1.2


## The lobby's chip, the last item of the top bar's right group (right of FRIENDS and SETTINGS, as
## the reference puts its wifi mark; Lobby._build_top_bar): the relay round trip.
static func lobby_chip() -> Control:
	return Chip.new()


## The chip itself: refreshed twice a second (no input; the bars are the whole icon).
class Chip extends Control:
	var _t := 0.0
	var _shown := -2

	func _init() -> void:
		name = "PingChip"
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		custom_minimum_size = Vector2(68, 56)

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
		NetPing.draw(self, Vector2(2, size.y * 0.5), 20.0, _shown, 17)

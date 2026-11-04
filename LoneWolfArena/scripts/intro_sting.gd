class_name IntroSting
extends Control
## The launch sting over the boot screen, about 2.4 s, synced to assets/audio/intro_sting.wav
## (tools/media/make_sfx.py intro_sting): on black, a gold streak grows out of the middle of the
## screen with the whoosh (speed lines racing in, a glint on each metal tick of the build-up) and
## is pulled back into a hot point for the short suck; at the impact (HIT, 0.90 s) the emblem
## falls in and slams down with a white flash, a shock ring, light rays, sparks and a light screen
## shake; the wordmark is written out beside it as it slides left, glints twinkle with the shimmer
## and the lockup settles. Then the black fades and the lockup flies onto the boot screen's own
## logo, so the sting hands over to the boot screen (key art, progress bar, tips) without a cut.
## A tap or Android back after SKIP_AFTER fades it out at once.
## Cheap on any phone: a few Controls, two custom-drawn layers (lines and polygons), no shaders,
## no video. The timeline is a function of the time since the sound started (the wall clock,
## less the audio latency), so a slow frame skips ahead instead of drifting off the sound.
## The boot preloads keep loading on their threads underneath (loading.gd adds the sting before it
## starts them); the boot screen only waits for the sting before it leaves (IntroSting.playing).
## Automated runs skip it unless a screenshot tour sets `show_for_test`; hold_at() freezes it.

signal finished

const LENGTH := 2.4             # the natural end (s): the lockup has landed on the boot logo
const HIT := 0.90               # the impact in intro_sting.wav (make_sfx.py INTRO_HIT)
const BUILD_END := HIT - 0.035  # the build-up is cut here: the suck that makes the hit land
const SKIP_AFTER := 0.4         # a tap skips the sting only after this
const OUT_START := 2.0          # the black starts to fade and the lockup flies to the boot logo
const SKIP_FADE := 0.22
const LAYER_NAME := "IntroLayer"
const LOGO := "logo.png"
const LOGO_SIZE := Vector2(900, 266)
const SPLIT := 272.0            # logo.png: the emblem is x 0..272, the wordmark the rest
## The metal ticks of the build-up (start 0.22 s, gaps from 0.17 s shrinking by 0.8).
const TICKS := [0.22, 0.39, 0.526, 0.635, 0.722, 0.791]
const HOT := Color(1.0, 0.95, 0.8)
const GOLD := Color(1.0, 0.74, 0.2)
const EMBER := Color(1.0, 0.48, 0.1)

## Screenshot tours set this to see the sting in an automated run.
static var show_for_test := false

var done := false
var _host: Node
var _layer: CanvasLayer
var _player: AudioStreamPlayer
var _t0 := -1                   # ticks (usec) when the sound started; -1 = not yet
var _delay := 0.0               # audio latency (s): the visuals wait for the sound
var _hold := -1.0               # a frozen time (tours), or -1
var _skip_at := -1.0            # the time of a skip, or -1
var _now := 0.0
var _slide := 0.0               # 0..1: the emblem's slide left / the wordmark being written
var _scale := 1.0               # the lockup's scale
var _target := Rect2()          # the boot screen's logo (size 0: none found)
var _target_known := false
var _boot_logo: TextureRect     # hidden while the lockup flies onto it (one logo, not two)
var _haze: Texture2D
var _bg: ColorRect
var _under: Control             # under the lockup: the streak, rays, rings and the glow
var _over: Control              # over it: sparks, the writing edge, glints
var _glow: TextureRect
var _lockup: Control
var _emblem: TextureRect
var _word_clip: Control
var _flash: ColorRect
var _sparks: Array[Dictionary] = []
var _lines: Array[Dictionary] = []
var _glints: Array[Dictionary] = []


## Puts the sting over the boot screen `host`, in its own canvas layer on top, unless this is an
## automated run (see show_for_test); returns it, or null.
static func play_over(host: Node) -> IntroSting:
	if Game.autotest != "" and not show_for_test:
		return null
	var layer := CanvasLayer.new()
	layer.name = LAYER_NAME
	layer.layer = 90
	var s := IntroSting.new()
	s._host = host
	s._layer = layer
	layer.add_child(s)
	host.add_child(layer)
	return s


## Whether a sting still covers `host` (the boot screen leaves only once it is done).
static func playing(host: Node) -> bool:
	var layer := host.get_node_or_null(LAYER_NAME)
	return layer != null and not layer.is_queued_for_deletion()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	UI.full_rect(self)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	_player = AudioStreamPlayer.new()
	_player.bus = "SFX"
	_player.stream = Audio.stream("intro_sting")
	add_child(_player)
	Game.mark("intro sting")
	_apply(0.0)


## The timeline's time in seconds: since the sound started, less the audio latency.
func now() -> float:
	if _hold >= 0.0:
		return _hold
	if _t0 < 0:
		return 0.0
	return float(Time.get_ticks_usec() - _t0) / 1000000.0 - _delay


## Fades the sting out at once (a tap or back); false before SKIP_AFTER and once it is ending.
func skip() -> bool:
	var t := now()
	if done or _skip_at >= 0.0 or t < SKIP_AFTER or t >= OUT_START:
		return false
	_skip_at = t
	create_tween().tween_property(_player, "volume_db", -36.0, SKIP_FADE)
	return true


## Tours: freezes the sting at `t` seconds; a negative `t` lets it run on from the frozen time.
func hold_at(t: float) -> void:
	if t >= 0.0:
		_hold = t
		_apply(t)
	elif _hold >= 0.0:
		_t0 = Time.get_ticks_usec() - int((_hold + _delay) * 1000000.0)
		_hold = -1.0


func _process(_delta: float) -> void:
	if done:
		return
	if _t0 < 0:
		# the clock starts with the sound, on the first frame (after the boot screen's build)
		_t0 = Time.get_ticks_usec()
		_delay = clampf(AudioServer.get_time_to_next_mix() + AudioServer.get_output_latency(), 0.0, 0.3)
		if _player.stream:
			_player.play()
	var t := now()
	_apply(t)
	var end := _skip_at + SKIP_FADE if _skip_at >= 0.0 else LENGTH
	if _hold < 0.0 and t >= end:
		_finish()


func _input(event: InputEvent) -> void:
	if done:
		return
	var touch := event as InputEventScreenTouch
	var click := event as InputEventMouseButton
	if (touch and touch.pressed) or (click and click.pressed):
		get_viewport().set_input_as_handled()
		skip()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		skip()


func _finish() -> void:
	done = true
	_show_boot_logo()
	Game.mark("intro done")
	finished.emit()
	if _layer:
		_layer.queue_free()
	else:
		queue_free()


func _exit_tree() -> void:
	_show_boot_logo()


func _show_boot_logo() -> void:
	if is_instance_valid(_boot_logo):
		_boot_logo.self_modulate.a = 1.0


# ---------------------------------------------------------------- build

func _build() -> void:
	_bg = ColorRect.new()
	_bg.color = Color.BLACK
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UI.full_rect(_bg)
	add_child(_bg)
	_under = _draw_layer(_draw_under)
	_glow = TextureRect.new()
	_glow.texture = UI.radial_glow(Color(1.0, 0.6, 0.15, 0.9))
	_glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_glow.stretch_mode = TextureRect.STRETCH_SCALE
	_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_under.add_child(_glow)
	_haze = UI.radial_glow(Color(1.0, 0.6, 0.16, 0.8))
	_lockup = Control.new()
	_lockup.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lockup.size = LOGO_SIZE
	add_child(_lockup)
	var logo := UI.texture(LOGO)
	if logo:
		_word_clip = Control.new()
		_word_clip.clip_contents = true
		_word_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_lockup.add_child(_word_clip)
		var word := _part(logo, Rect2(SPLIT, 0.0, LOGO_SIZE.x - SPLIT, LOGO_SIZE.y))
		word.position = Vector2(8.0, 0.0)
		_word_clip.add_child(word)
		_emblem = _part(logo, Rect2(0.0, 0.0, SPLIT, LOGO_SIZE.y))
		_emblem.pivot_offset = _emblem.size * 0.5
		_lockup.add_child(_emblem)
	_over = _draw_layer(_draw_over)
	_flash = ColorRect.new()
	_flash.color = Color(1.0, 0.96, 0.86, 0.0)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UI.full_rect(_flash)
	add_child(_flash)
	# The same particles on every launch (and in every screenshot).
	var rng := RandomNumberGenerator.new()
	rng.seed = 2626
	for i in 30:
		var a := rng.randf() * TAU
		_sparks.append({"dir": Vector2(cos(a), sin(a)), "speed": rng.randf_range(420.0, 1150.0),
			"life": rng.randf_range(0.35, 0.85), "len": rng.randf_range(14.0, 44.0), "w": rng.randf_range(1.6, 3.2)})
	for i in 14:
		_lines.append({"t": 0.06 + 0.72 * sqrt(i / 14.0) + rng.randf_range(-0.03, 0.03), "dur": rng.randf_range(0.16, 0.3),
			"y": rng.randf_range(-0.34, 0.34), "len": rng.randf_range(0.14, 0.34), "a": rng.randf_range(0.2, 0.5),
			"w": rng.randf_range(1.0, 2.4), "side": 1 if i % 2 == 0 else -1})
	for i in 11:
		_glints.append({"t": rng.randf_range(0.95, 1.9), "x": rng.randf_range(0.02, 0.98), "y": rng.randf_range(0.05, 0.95),
			"r": rng.randf_range(9.0, 18.0)})


func _draw_layer(on_draw: Callable) -> Control:
	var c := Control.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UI.full_rect(c)
	c.draw.connect(on_draw)
	add_child(c)
	return c


## A part of the logo lockup (the emblem or the wordmark) at its texture size.
static func _part(tex: Texture2D, region: Rect2) -> TextureRect:
	var at := AtlasTexture.new()
	at.atlas = tex
	at.region = region
	var r := TextureRect.new()
	r.texture = at
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE
	r.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.size = region.size
	return r


## Where the boot screen draws its own logo (the same texture, under the host), or an empty rect;
## remembers that logo in _boot_logo.
func _boot_logo_rect() -> Rect2:
	var logo := UI.texture(LOGO)
	if _host == null or logo == null:
		return Rect2()
	for n in _host.find_children("*", "TextureRect", true, false):
		var shown := n as TextureRect
		if shown.texture == logo and shown.is_visible_in_tree() and not is_ancestor_of(shown):
			_boot_logo = shown
			# STRETCH_KEEP_ASPECT: the logo fills the rect's height or width from its top-left
			var r := shown.get_global_rect()
			var aspect := LOGO_SIZE.x / LOGO_SIZE.y
			var h := minf(r.size.y, r.size.x / aspect)
			return Rect2(r.position, Vector2(h * aspect, h))
	return Rect2()


# ---------------------------------------------------------------- the timeline

func _apply(t_in: float) -> void:
	var t := maxf(t_in, 0.0)
	_now = t
	var vs := get_viewport_rect().size
	var shake := Vector2.ZERO
	if t >= HIT:
		var tau := t - HIT
		shake = Vector2(sin(tau * 61.0 + 1.1), cos(tau * 47.0 + 0.4)) * 11.0 * (vs.y / 720.0) * exp(-tau / 0.11)
	var out := _smooth((t - OUT_START) / (LENGTH - OUT_START))
	var gone := 0.0
	if _skip_at >= 0.0:
		gone = clampf((t - _skip_at) / SKIP_FADE, 0.0, 1.0)
		out = 0.0
	modulate.a = 1.0 - gone
	_bg.color.a = 1.0 - out
	_under.modulate.a = 1.0 - out
	_over.modulate.a = 1.0 - out
	_under.position = shake
	_over.position = shake
	_flash.color.a = 0.9 * exp(-(t - HIT) / 0.06) if t >= HIT else 0.0
	_place_lockup(t, vs, shake, out)
	_under.queue_redraw()
	_over.queue_redraw()


## The lockup: centred, 0.3 of the screen height tall, pushing in slowly once it is whole; in the
## outro it flies onto the boot screen's logo. The emblem falls in just before the hit, slams down
## on it, then slides left while the wordmark is written out beside it.
func _place_lockup(t: float, vs: Vector2, shake: Vector2, out: float) -> void:
	_lockup.visible = _emblem != null
	if _emblem == null:
		return
	var k := minf(vs.y * 0.3 / LOGO_SIZE.y, vs.x * 0.62 / LOGO_SIZE.x)
	var scl := k * (1.0 + 0.035 * _smooth((t - 1.1) / (OUT_START - 1.1)))
	var pos := vs * 0.5 - LOGO_SIZE * scl * 0.5
	_lockup.modulate.a = 1.0
	if out > 0.0:
		if not _target_known:
			_target_known = true
			_target = _boot_logo_rect()
		if _target.size.y > 1.0:
			if _boot_logo:
				_boot_logo.self_modulate.a = 0.0
			var e := _ease_in_out(out)
			pos = pos.lerp(_target.position, e)
			scl = lerpf(scl, _target.size.y / LOGO_SIZE.y, e)
		else:
			_lockup.modulate.a = 1.0 - out
	_scale = scl
	_lockup.position = pos + shake
	_lockup.scale = Vector2(scl, scl)
	_slide = _ease_out_cubic((t - 1.0) / 0.42)
	_emblem.position.x = (LOGO_SIZE.x - SPLIT) * 0.5 * (1.0 - _slide)
	var es := 1.0
	var ea := 1.0
	if t < HIT - 0.1:
		ea = 0.0
	elif t < HIT:
		var q := (t - (HIT - 0.1)) / 0.1
		es = lerpf(3.4, 1.0, q * q)
		ea = clampf(q * 2.5, 0.0, 1.0)
	elif t < HIT + 0.22:
		var v := (t - HIT) / 0.22
		es = 1.0 - 0.1 * sin(v * PI) * (1.0 - v)
	_emblem.scale = Vector2(es, es)
	_emblem.modulate.a = ea
	_word_clip.position = Vector2(_emblem.position.x + SPLIT - 8.0, 0.0)
	_word_clip.size = Vector2((LOGO_SIZE.x - SPLIT + 8.0) * _slide, LOGO_SIZE.y)
	_word_clip.visible = _slide > 0.0
	# the glow behind the emblem: a burst on the hit that settles into a warm halo
	var g := 0.0
	var ga := 0.0
	if t >= HIT:
		var tau := t - HIT
		g = lerpf(3.3, 1.9, _ease_out_cubic(tau / 0.6))
		ga = lerpf(1.0, 0.42, clampf(tau / 0.8, 0.0, 1.0))
	elif t >= HIT - 0.1:
		g = 1.2
		ga = (t - (HIT - 0.1)) / 0.1 * 0.5
	var gs := LOGO_SIZE.y * scl * g
	var center := pos + (_emblem.position + _emblem.size * 0.5) * scl
	_glow.size = Vector2(gs, gs)
	_glow.position = center - Vector2(gs, gs) * 0.5
	_glow.modulate.a = ga


func _draw_under() -> void:
	var vs := _under.size
	var c := vs * 0.5
	var u := vs.y / 720.0
	if _now < HIT:
		_draw_build_up(_now, vs, c, u)
	else:
		_draw_burst(_now - HIT, c, u)


## The build-up: speed lines racing in from both sides, the streak growing out of the centre with
## the whoosh (stacked lens shapes, wide and faint to thin and hot), a glint on each metal tick,
## and in the last moment the pull back into a hot point.
func _draw_build_up(t: float, vs: Vector2, c: Vector2, u: float) -> void:
	var k := clampf(t / BUILD_END, 0.0, 1.0)
	var pull := clampf((t - (BUILD_END - 0.025)) / 0.06, 0.0, 1.0)
	var e := pow(k, 1.6)
	var half := vs.x * 0.5 * pow(k, 0.85) * (1.0 - pull)
	# a warm haze around the streak
	if half > 2.0:
		var hh := vs.y * (0.05 + 0.13 * e)
		_under.draw_texture_rect(_haze, Rect2(c.x - half * 1.15, c.y - hh, half * 2.3, hh * 2.0), false,
			Color(1, 1, 1, 0.18 + 0.5 * e))
	for ln: Dictionary in _lines:
		var p := (t - float(ln.t)) / float(ln.dur)
		if p < 0.0 or p > 1.0:
			continue
		var dir := float(ln.side)
		var length := float(ln.len) * vs.x
		var head := lerpf(-length, vs.x + length, p) if dir > 0.0 else lerpf(vs.x + length, -length, p)
		var y := c.y + float(ln.y) * vs.y * (1.0 - 0.65 * k)
		var w := float(ln.w) * 1.3 * u
		var a := minf(1.0, float(ln.a) * 1.5 * (0.6 + 0.4 * e)) * (1.0 - pull)
		_under.draw_polygon(PackedVector2Array([Vector2(head - dir * length, y), Vector2(head, y - w), Vector2(head, y + w)]),
			PackedColorArray([Color(GOLD, 0.0), Color(1.0, 0.86, 0.48, a), Color(1.0, 0.86, 0.48, a)]))
	if half > 2.0:
		for band: Array in [[22.0, 0.06], [10.0, 0.12], [4.5, 0.32], [1.8, 1.0]]:
			var th := float(band[0]) * u * (0.45 + 1.1 * e) * (1.0 + 1.5 * pull)
			var col := GOLD.lerp(HOT, 0.6 if float(band[0]) < 2.5 else 0.15)
			col.a = float(band[1]) * (0.2 + 0.8 * e)
			_under.draw_colored_polygon(PackedVector2Array([c - Vector2(half, 0.0), c - Vector2(0.0, th), c + Vector2(half, 0.0),
				c + Vector2(0.0, th)]), col)
	var core := (3.0 + 5.0 * e + 16.0 * pull) * u
	_under.draw_circle(c, core * 2.2, Color(GOLD, 0.12 + 0.2 * e))
	_under.draw_circle(c, core, Color(HOT, 0.35 + 0.6 * maxf(e, pull)))
	for i in TICKS.size():
		var dt := t - float(TICKS[i])
		if dt >= 0.0 and dt < 0.14:
			var f := 1.0 - dt / 0.14
			var side := 1.0 if i % 2 == 0 else -1.0
			_star(_under, c + Vector2(side * half * (0.82 - 0.09 * i), 0.0), (12.0 + 4.0 * i) * u * (0.5 + 0.5 * f), Color(HOT, f))


## The hit: light rays for an instant and two shock rings.
func _draw_burst(tau: float, c: Vector2, u: float) -> void:
	if tau < 0.3:
		var f := 1.0 - tau / 0.3
		for i in 12:
			var a := TAU * i / 12.0 + 0.13
			var d := Vector2(cos(a), sin(a))
			var n := Vector2(-d.y, d.x) * 9.0 * u * f
			var r0 := 30.0 * u
			var r1 := (260.0 + 420.0 * (1.0 - f)) * u
			_under.draw_polygon(PackedVector2Array([c + d * r0 + n, c + d * r1, c + d * r0 - n]),
				PackedColorArray([Color(HOT, 0.5 * f), Color(GOLD, 0.0), Color(HOT, 0.5 * f)]))
	for i in 2:
		var tt := tau - 0.06 * i
		if tt < 0.0 or tt > 0.6:
			continue
		var p := tt / 0.6
		var r := (60.0 + 600.0 * (1.0 - pow(1.0 - p, 3.0))) * u
		var col := Color(HOT, (1.0 - p) * (0.8 if i == 0 else 0.45))
		_under.draw_arc(c, r, 0.0, TAU, 96, col, maxf(1.0, (10.0 - 8.0 * p) * u * (1.0 if i == 0 else 0.55)), true)


## Sparks flying out of the hit (drag and a little gravity), the bright edge that writes the
## wordmark and the glints around the lockup.
func _draw_over() -> void:
	var t := _now
	if t < HIT or _emblem == null:
		return
	var vs := _over.size
	var c := vs * 0.5
	var u := vs.y / 720.0
	var tau := t - HIT
	var rim := LOGO_SIZE.y * 0.42 * _scale          # sparks leave from the emblem's edge
	for s: Dictionary in _sparks:
		var life := float(s.life)
		if tau >= life:
			continue
		var f := tau / life
		var v := float(s.speed) * u
		var dir: Vector2 = s.dir
		var p := c + dir * (rim + v * (1.0 - exp(-tau * 3.2)) / 3.2) + Vector2(0.0, 300.0 * u * tau * tau)
		var vel := dir * v * exp(-tau * 3.2) + Vector2(0.0, 600.0 * u * tau)
		var tail := vel.normalized() * minf(float(s.len) * u, vel.length() * 0.06)
		var col := HOT.lerp(EMBER, f)
		col.a = pow(1.0 - f, 1.3)
		_over.draw_line(p - tail, p, col, maxf(1.0, float(s.w) * u * (1.0 - 0.5 * f)), true)
	var origin := _lockup.position - _over.position
	if _slide > 0.0 and _slide < 1.0:
		var x := origin.x + (_word_clip.position.x + _word_clip.size.x) * _scale
		var y0 := origin.y + 12.0 * _scale
		var y1 := origin.y + 214.0 * _scale
		var a := sin(_slide * PI)
		var w := 7.0 * u
		_over.draw_colored_polygon(PackedVector2Array([Vector2(x, y0), Vector2(x + w, (y0 + y1) * 0.5), Vector2(x, y1),
			Vector2(x - w, (y0 + y1) * 0.5)]), Color(GOLD, 0.35 * a))
		_over.draw_line(Vector2(x, y0), Vector2(x, y1), Color(HOT, 0.9 * a), maxf(1.0, 2.0 * u), true)
	var lsize := LOGO_SIZE * _scale
	for g: Dictionary in _glints:
		var gt := t - float(g.t)
		if gt < 0.0 or gt > 0.34:
			continue
		var f := sin(gt / 0.34 * PI)
		_star(_over, origin + Vector2(float(g.x), float(g.y)) * lsize, float(g.r) * u * f, Color(HOT, 0.9 * f))


## A four-pointed glint.
static func _star(ci: CanvasItem, p: Vector2, r: float, col: Color) -> void:
	if r < 0.5:
		return
	var w := r * 0.16
	ci.draw_colored_polygon(PackedVector2Array([p + Vector2(-r, 0.0), p + Vector2(0.0, -w), p + Vector2(r, 0.0), p + Vector2(0.0, w)]), col)
	ci.draw_colored_polygon(PackedVector2Array([p + Vector2(0.0, -r), p + Vector2(w, 0.0), p + Vector2(0.0, r), p + Vector2(-w, 0.0)]), col)
	ci.draw_circle(p, w * 1.4, col)


static func _smooth(x: float) -> float:
	var c := clampf(x, 0.0, 1.0)
	return c * c * (3.0 - 2.0 * c)


static func _ease_out_cubic(x: float) -> float:
	return 1.0 - pow(1.0 - clampf(x, 0.0, 1.0), 3.0)


static func _ease_in_out(x: float) -> float:
	var c := clampf(x, 0.0, 1.0)
	return 4.0 * c * c * c if c < 0.5 else 1.0 - pow(-2.0 * c + 2.0, 3.0) / 2.0

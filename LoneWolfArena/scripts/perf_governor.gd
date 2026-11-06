class_name PerfGovernor
extends Node
## Keeps the frame rate up on weak phones (the arena) and measures a phone for AUTO graphics (the
## lobby and the arena). A scene adds it with attach() whenever it applies a graphics level.
##
## Dynamic resolution (the arena): while the average frame time stays over the frame target x SLOW
## for SLOW_HOLD s, the 3D view renders STEP smaller (the viewport's scaling_3d_scale, upscaled
## bilinear: all the Compatibility renderer offers), down to FLOOR at the least; after a stretch of
## frames on target it steps back up, never past the graphics level's own scale (the ceiling). The
## HUD is 2D: it keeps its full resolution. Hysteresis, so the picture does not pump:
##  - an average between FAST and SLOW x the target changes nothing;
##  - a step up waits RAISE_HOLD s on target, twice as long after each step up that had to be
##    undone within RAISE_TRIAL s (up to RAISE_MAX);
##  - a step down that did not make the frames shorter (HELPED: the CPU, not the GPU, holds them
##    back) is undone and lowering pauses for BLOCK s (doubling up to BLOCK_MAX).
## Nothing changes in the first ROUND_HOLD s of a round (PREP or FIGHT), for SETTLE s after a
## change, or while the game is paused; a frame over SKIP s (a load, a pause) is left out and a long
## one counts as HITCH x the target at most. The target is Engine.max_fps or the screen's refresh
## rate, whichever is lower (vsync never runs faster than the screen).
##
## AUTO graphics (Game.graphics_auto): device_level() is the first guess from the hardware; while
## Game.auto_graphics_pending the scene's governor measures PROBE_TIME s of frames (PROBE_MIN at
## least, or whatever 3 x PROBE_TIME s gave on a very slow phone) after a settle of PROBE_SETTLE s
## and PROBE_SETTLE_FRAMES frames (the first frames compile shaders), the dynamic resolution
## holding meanwhile, and hands refine_level()'s answer to Game.finish_auto_graphics().
##
## Automated runs (Game.autotest) keep the level and the scale fixed, so screenshots and budgets
## stay comparable; the unit tests drive advance() and the static helpers directly.

const FLOOR := 0.6
const STEP := 0.05
const SLOW := 1.15
const SLOW_HOLD := 2.0
const FAST := 1.04
const RAISE_HOLD := 6.0
const RAISE_TRIAL := 8.0
const RAISE_MAX := 48.0
const HELPED := 0.98
const BLOCK := 20.0
const BLOCK_MAX := 120.0
const ROUND_HOLD := 1.0
const SETTLE := 0.75
const AVG_TAU := 0.5             # s, time constant of the average frame time
const HITCH := 4.0
const SKIP := 0.5
const PROBE_SETTLE := 1.0
const PROBE_SETTLE_FRAMES := 10
const PROBE_TIME := 3.0
const PROBE_MIN := 20
const REFINE_MIN := 5            # frames refine_level() needs to tell anything
const AUTO_MAX := 2              # AUTO picks LOW..HIGH, never EXTREME
## Arena phases that start a round (Arena.Phase.PREP and FIGHT).
const ROUND_PHASES := [0, 1]

## Dynamic resolution on (the arena); off: AUTO's measuring only (the lobby).
var dynamic := true
## The graphics level's own 3D scale: the governor never goes above it.
var ceiling := 1.0
## The 3D scale wanted now (the viewport follows it).
var scale := 1.0
## Frame target in seconds (set every frame from the frame cap and the screen).
var target_s := 1.0 / 60.0
var _avg := 0.0                  # average frame time in s (0: no frame yet)
var _slow_t := 0.0               # s the average has been over target x SLOW
var _fast_t := 0.0               # s it has been on target (under target x FAST)
var _settle_t := 0.0
var _raise_wait := RAISE_HOLD
var _since_raise := INF
var _step_avg := 0.0             # the average before the last step down (0: no verdict pending)
var _block_t := 0.0
var _block_len := BLOCK
var _round_t := INF              # s since the round began
var _phase := -1
var _last_us := 0
var _probing := false
var _probe_wait := 0.0
var _probe_skip := 0
var _probe_t := 0.0
var _probe_ms := PackedFloat32Array()
var _probe_busy := PackedFloat32Array()


## The scene's governor (added on the first call), reset for a graphics level whose own 3D scale
## is `level_scale` (the scene has just set the viewport to it). dyn = false: measuring only.
static func attach(scene: Node, level_scale: float, dyn := true) -> PerfGovernor:
	var g := scene.get_node_or_null(^"PerfGovernor") as PerfGovernor
	if g == null:
		g = PerfGovernor.new()
		g.name = "PerfGovernor"
		scene.add_child(g)
	g.dynamic = dyn
	g.reset(level_scale)
	return g


## Starts over at a graphics level's own 3D scale (a level change also restarts a measurement).
func reset(level_scale: float) -> void:
	ceiling = clampf(level_scale, FLOOR, 1.0)
	scale = ceiling
	_avg = 0.0
	_slow_t = 0.0
	_fast_t = 0.0
	_settle_t = SETTLE
	_raise_wait = RAISE_HOLD
	_since_raise = INF
	_step_avg = 0.0
	_block_t = 0.0
	_block_len = BLOCK
	_stop_probe()


func _exit_tree() -> void:
	_stop_probe()


func _process(_delta: float) -> void:
	# The real time between frames: Engine.time_scale (the kill slow motion) does not change it.
	var now := Time.get_ticks_usec()
	var frame := float(now - _last_us) / 1000000.0 if _last_us > 0 else 0.0
	_last_us = now
	if Game.autotest != "" or frame <= 0.0:
		return
	target_s = 1.0 / target_fps(Engine.max_fps, DisplayServer.screen_get_refresh_rate())
	if Game.auto_graphics_pending:
		_probe_frame(frame)
		return
	_stop_probe()
	if not dynamic:
		return
	var ph: Variant = get_parent().get(&"phase")
	var phase := int(ph) if ph is int else -1
	if phase != _phase:
		_phase = phase
		if phase in ROUND_PHASES:
			_round_t = 0.0
	_round_t += frame
	var want := advance(frame, _round_t)
	var vp := get_viewport()
	if vp and not is_equal_approx(vp.scaling_3d_scale, want):
		vp.scaling_3d_scale = want


## One frame that took `frame` s, `round_t` s into the round: updates the average and the timers
## and returns the 3D scale wanted now (also kept in `scale`).
func advance(frame: float, round_t: float) -> float:
	if frame <= 0.0 or frame > SKIP:
		return scale
	var f := minf(frame, target_s * HITCH)
	_avg = f if _avg <= 0.0 else lerpf(_avg, f, 1.0 - exp(-f / AVG_TAU))
	_since_raise += f
	_block_t = maxf(_block_t - f, 0.0)
	if _settle_t > 0.0 or round_t < ROUND_HOLD:
		_settle_t = maxf(_settle_t - f, 0.0)
		_slow_t = 0.0
		_fast_t = 0.0
		return scale
	if _avg > target_s * SLOW:
		_fast_t = 0.0
		_slow_t += f
		if _slow_t >= SLOW_HOLD:
			_slow_t = 0.0
			_step_down()
	elif _avg <= target_s * FAST:
		_slow_t = 0.0
		_step_avg = 0.0
		_fast_t += f
		if _fast_t >= _raise_wait and scale < ceiling - 0.001:
			_fast_t = 0.0
			_set_scale(scale + STEP)
			_since_raise = 0.0
	else:
		_slow_t = 0.0
		_fast_t = 0.0
		_step_avg = 0.0
	return scale


## Frames stayed long: a step down, unless the last one did not shorten them (then the GPU is not
## what holds them back: that step is undone and lowering pauses).
func _step_down() -> void:
	if _step_avg > 0.0 and _avg > _step_avg * HELPED:
		_step_avg = 0.0
		_set_scale(scale + STEP)
		_block_t = _block_len
		_block_len = minf(_block_len * 2.0, BLOCK_MAX)
		return
	if _block_t > 0.0 or scale <= FLOOR + 0.001:
		return
	if _since_raise < RAISE_TRIAL:
		_raise_wait = minf(_raise_wait * 2.0, RAISE_MAX)      # that step up was one too many
	_step_avg = _avg
	_set_scale(scale - STEP)


func _set_scale(s: float) -> void:
	scale = snappedf(clampf(s, FLOOR, ceiling), 0.001)
	_settle_t = SETTLE


## Frames per second the game can show: the frame cap (0 = none) or the screen's refresh rate,
## whichever is lower; 60 when the screen does not say (NaN or 0 on some systems).
static func target_fps(max_fps: int, refresh: float) -> float:
	var hz := refresh if refresh > 1.0 else 60.0         # false for NaN too
	return minf(float(max_fps), hz) if max_fps > 0 else hz


# ---------------------------------------------------------------- AUTO graphics

## A frame while AUTO measures: the settle (shaders, the scene's first frames), then the frame
## times (a long one counts as 1 s at most) and the time the CPU or the GPU was busy per frame (the
## driver reports the GPU's where it can; 0 where it cannot).
func _probe_frame(frame: float) -> void:
	var vp := get_viewport()
	if not _probing:
		_probing = true
		_probe_wait = PROBE_SETTLE
		_probe_skip = PROBE_SETTLE_FRAMES
		_probe_t = 0.0
		_probe_ms.clear()
		_probe_busy.clear()
		RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), true)
		return
	if _probe_wait > 0.0 or _probe_skip > 0:
		_probe_wait -= frame
		_probe_skip -= 1
		return
	_probe_t += frame
	_probe_ms.append(minf(frame, 1.0) * 1000.0)
	var rid := vp.get_viewport_rid()
	var cpu := RenderingServer.viewport_get_measured_render_time_cpu(rid) \
		+ (Performance.get_monitor(Performance.TIME_PROCESS) + Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0
	var gpu := RenderingServer.viewport_get_measured_render_time_gpu(rid)
	_probe_busy.append(maxf(cpu, gpu) if gpu > 0.0 else 0.0)
	if (_probe_t < PROBE_TIME or _probe_ms.size() < PROBE_MIN) and _probe_t < PROBE_TIME * 3.0:
		return
	var busy := _probe_busy.duplicate()
	busy.sort()
	var level := refine_level(int(Game.settings.graphics), _probe_ms, busy[busy.size() / 2], target_s * 1000.0,
		Game.auto_graphics_first_pass())
	_stop_probe()
	Game.finish_auto_graphics(level)


func _stop_probe() -> void:
	if not _probing:
		return
	_probing = false
	if is_inside_tree():
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), false)


## AUTO's measuring step: the level after a measuring window at `level` (LOW..HIGH). frame_ms holds
## the window's frame times, busy_ms is the median time the CPU or the GPU was busy per frame (0:
## the driver does not tell), target_ms the frame target. A median frame over target x SLOW, or
## one frame in ten over twice the target, is a level down (two when the median is over 1.6 x the
## target); when going up is allowed, a window well inside the budget (busy under 45 % of the
## target, one frame in ten at most 1.25 x it) is a level up, never past HIGH.
static func refine_level(level: int, frame_ms: PackedFloat32Array, busy_ms: float, target_ms: float, allow_up := true) -> int:
	var lv := clampi(level, 0, AUTO_MAX)
	if frame_ms.size() < REFINE_MIN or target_ms <= 0.0:
		return lv
	var s := frame_ms.duplicate()
	s.sort()
	var median := s[s.size() / 2]
	var p90 := s[mini(int(s.size() * 0.9), s.size() - 1)]
	if median > target_ms * 1.6:
		return maxi(lv - 2, 0)
	if median > target_ms * SLOW or p90 > target_ms * 2.0:
		return maxi(lv - 1, 0)
	if allow_up and busy_ms > 0.0 and busy_ms < target_ms * 0.45 and p90 <= target_ms * 1.25:
		return mini(lv + 1, AUTO_MAX)
	return lv


## AUTO's first guess for a device, before anything is measured (LOW 0 .. HIGH 2). A software
## renderer gets LOW and a desktop HIGH (MEDIUM with 2 cores or fewer). A phone starts at MEDIUM,
## its GPU family moves it a level (gpu_tier: entry level down, flagship up), then 4 cores or
## fewer, under 3 GiB of memory and a screen of over 3.2 million pixels (unless the GPU is a
## flagship one) each take a level off. 0 for cores or memory means unknown.
static func device_level(gpu: String, cores: int, memory: int, screen: Vector2i, mobile: bool) -> int:
	var g := gpu.to_lower()
	for soft: String in ["llvmpipe", "softpipe", "swiftshader", "lavapipe", "software"]:
		if soft in g:
			return 0
	if not mobile:
		return AUTO_MAX if cores > 2 or cores <= 0 else 1
	var tier := gpu_tier(g)
	var level := 1 + tier
	if cores > 0 and cores <= 4:
		level -= 1
	if memory > 0 and memory < 3 * 1024 * 1024 * 1024:
		level -= 1
	if screen.x * screen.y > 3200000 and tier < 1:
		level -= 1
	return clampi(level, 0, AUTO_MAX)


## A mobile GPU's class from the name the driver gives: 1 flagship, -1 entry level, 0 mid range or
## unknown. Adreno: the hundreds are the generation, the rest the class within it (6x0-6x14 and
## 7x0-7x09 entry, up to x29 mid, x30 and over flagship; 5xx and older entry, 530/540 mid). Mali:
## G31-G52 and the T/4xx series entry, G57-G72 and G6xx mid, G76-G78 and G7xx/G9xx flagship.
## Immortalis and Xclipse flagship, PowerVR entry.
static func gpu_tier(gpu: String) -> int:
	var g := gpu.to_lower()
	if "immortalis" in g or "xclipse" in g:
		return 1
	if "powervr" in g:
		return -1
	var m := RegEx.create_from_string("adreno[^0-9]*([0-9]{3})").search(g)
	if m:
		var n := int(m.get_string(1))
		var gen := n / 100
		var sub := n % 100
		if gen <= 5:
			return 0 if sub >= 30 else -1
		if sub < (15 if gen == 6 else 10):
			return -1
		return 0 if sub < 30 else 1
	if "mali-t" in g or "mali-4" in g:
		return -1
	m = RegEx.create_from_string("mali-g([0-9]+)").search(g)
	if m:
		var n := int(m.get_string(1))
		if n >= 100:
			var series := n / 100
			return -1 if series <= 5 else (0 if series == 6 else 1)
		return -1 if n <= 52 else (0 if n < 76 else 1)
	return 0

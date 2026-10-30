class_name Player
extends Fighter
## Local player: over-the-shoulder camera, touch look / drag-fire, scopes, recoil and aim assist.

const CAM_HEIGHT := 1.62
const CAM_SHOULDER := 0.55
const CAM_DIST := 3.25
const ADS_DIST := 1.5
const FOV_HIP := 68.0
const PITCH_MIN := -70.0
const PITCH_MAX := 62.0

## Aim assist tuning. The feel being matched: the crosshair slows down and "sticks" to an enemy
## it is over and follows them when they strafe; firing pulls it sideways onto the body and holds
## it on the part it is on (body or head) against the recoil. An upward drag from the body meets
## the head as a "stop" that takes a fixed share of the screen in thumb travel at any distance:
## a tiny drag stays on the body, a normal one ends on the head, only a very long one goes over
## it (a short overshoot is pulled back onto the head). The first shot waits a moment for a drag
## that starts with the press.
const ASSIST := {
	"strength": 0.9,            # overall assist; each gun scales it by its "assist" factor
	"range_hip": 30.0,          # metres, hip fire / red dot
	"range_scope": 80.0,        # metres, sniper scope
	"cone_deg": 9.0,            # acquisition cone half-angle at 10 m (wider up close)
	"cone_scope_deg": 2.5,
	"bubble_deg": 1.2,          # angular margin around the body that still counts as "on target"
	"track_deg": 3.0,           # tracking keeps following while the crosshair is this close to the body
	"friction": 0.4,            # look sensitivity multiplier on the body (lower = stickier)
	"head_band": HEAD_RADIUS,   # m around the head centre that counts as the head: its hit zone
	"lip": 0.25,                # m over the head band that still slows a drag and pulls back to the head
	"neck_drag": 0.04,          # screen heights of drag from the chest up to the head band
	"head_drag": 0.26,          # screen heights of drag the head band takes up: the head "stop"
	"lip_drag": 0.08,           # and the lip over it; a longer drag goes over the head
	"drag_net": 0.004,          # screen heights of net vertical drag over the last 3 ticks that count
	                            # as dragging (a resting thumb's jitter cancels out)
	"drag_side": 0.35,          # sideways share an upward drag on the target keeps (the body lock)
	"track": 1.0,               # share of the target's angular motion the aim follows on target
	"pull_rate": 20.0,          # 1/s exponential pull toward the aim point while firing (body lock)
	"pull_max_deg": 160.0,      # deg/s cap of that pull (a fast drag still breaks away)
	"drag_free": 0.0,           # s after a drag before firing holds the height again
	"on_target_spread": 0.35,   # spread multiplier while the crosshair is on the target (full strength)
}
const DRAG_SHOT_WINDOW := 0.15   # s the first shot may wait for a drag that starts with the press
const DRAG_SHOT_START := 0.04    # no drag by then (or the drag paused): it fires
const DRAG_SHOT_SETTLE := 0.15   # more s it waits while a drag that ended high on the head or just over it is pulled in

var rig: Node3D
var yaw_node: Node3D
var pitch_node: Node3D
var spring: SpringArm3D
var camera: Camera3D
var firing := false
var recoil_pitch := 0.0
var recoil_yaw := 0.0
var shake := 0.0
var assist_target: Fighter
var assist_on := true                 # tests compare the aim with and without the assist
var aim_zone := ""                    # crosshair on the assist target: "head", "body" or ""
var _shot_wait := -1.0                # s since the press while the first shot waits (-1: not waiting)
var _v_drag := 0.0                    # vertical look drag since the last physics tick (screen heights)
var _v_recent: Array[float] = [0.0, 0.0, 0.0]   # that drag over the last ticks (jitter cancels out)
var _since_v_drag := 99.0             # s since the last steady vertical drag (firing holds the height)
var _since_v_move := 99.0             # s since the last vertical movement at all (the first shot)
var _on_column := false               # crosshair level with the target (the drag regions apply)
var _chest_p := 0.0                   # aim pitch of the chest, the head band's bottom and top and
var _head_lo := 0.0                   # the lip's top (the drag regions' edges)
var _head_hi := 0.0
var _head_in := 0.0                   # top of the head's inner half (a drag from over it settles there)
var _lip_hi := 0.0
var _col_yaw := 0.0                   # aim yaw of the target's column and the half width counted on it
var _col_tol := 0.0
var _head_yaw := 0.0                  # aim yaw of the target's head (the column's top)
var _anchor := ""                     # what firing holds since the last drag: "head", "body", "over"
var victory_cam := false
var crosshair_on_target := false      # HUD: crosshair turns red
var _track_dir := Vector3.ZERO        # last camera->target chest direction (for tracking)
var _track_target: Fighter
var _victory_yaw := INF
var _faded := false
var _cam_y := CAM_HEIGHT
var _fov := FOV_HIP
var _scope_hold := false              # "hold fire to scope" for snipers: fire on release


func _ready() -> void:
	is_player = true
	add_to_group("fighters")
	_build_camera()


func _build_camera() -> void:
	rig = Node3D.new()
	rig.name = "CameraRig"
	rig.top_level = true
	add_child(rig)
	yaw_node = Node3D.new()
	rig.add_child(yaw_node)
	pitch_node = Node3D.new()
	yaw_node.add_child(pitch_node)
	spring = SpringArm3D.new()
	spring.spring_length = CAM_DIST
	spring.collision_mask = LAYER_WORLD
	spring.margin = 0.15
	spring.position = Vector3(CAM_SHOULDER, 0, 0)
	var sph := SphereShape3D.new()
	sph.radius = 0.15
	spring.shape = sph
	pitch_node.add_child(spring)
	camera = Camera3D.new()
	camera.fov = FOV_HIP
	camera.near = 0.06
	camera.far = 600.0
	spring.add_child(camera)
	camera.current = true
	spring.add_excluded_object(get_rid())
	rig.global_position = global_position + Vector3.UP * CAM_HEIGHT


# ---------------------------------------------------------------- input API (called by HUD)

func scope_type() -> String:
	return String(weapon().def.get("scope", "none"))


func is_scoped() -> bool:
	return ads and scope_type() == "sniper"


## Sensitivity for the current view (settings are 1..200, 100 = default speed).
func _sensitivity() -> float:
	var s: float = Game.settings.sens_general
	if ads:
		s = Game.settings.sens_sniper if scope_type() == "sniper" else Game.settings.sens_reddot
	return maxf(s, 1.0) / 100.0


func reset_for_round(pos: Vector3, yaw: float) -> void:
	super(pos, yaw)
	firing = false
	_shot_wait = -1.0
	_v_drag = 0.0
	_v_recent = [0.0, 0.0, 0.0]
	_anchor = ""
	_scope_hold = false
	recoil_pitch = 0.0
	recoil_yaw = 0.0
	shake = 0.0
	victory_cam = false
	_victory_yaw = INF
	_track_target = null


## The aim was set directly (not dragged): firing decides afresh what to hold.
func forget_aim_hold() -> void:
	_anchor = ""


func _assist_active() -> bool:
	return assist_on


func add_look(rel: Vector2, from_fire_button := false) -> void:
	if not alive:
		return
	var s := _sensitivity()
	if from_fire_button:
		s *= float(Game.settings.sens_fire) / 100.0
	var vh := get_viewport().get_visible_rect().size.y
	var deg_per_px := 130.0 / maxf(vh, 1.0) * s
	if ads:
		deg_per_px *= _fov / FOV_HIP
	var fx := 1.0
	if aim_zone != "" and _assist_active():
		fx = lerpf(1.0, float(ASSIST.friction), _assist_strength())
	var upward := assist_target != null and _assist_active() and rel.y < 0.0 and absf(rel.x) < absf(rel.y) * 2.0
	# A mostly upward drag on the target (a drag shot is never quite straight) keeps to its column.
	if upward and _on_column:
		fx *= float(ASSIST.drag_side)
	aim_yaw -= deg_to_rad(rel.x * deg_per_px * fx)
	# ... and one that starts beside it slides onto it: by the time the drag has covered the
	# neck share of the screen the crosshair is on the column, so the head stop catches it.
	var per := float(ASSIST.neck_drag) * deg_to_rad(deg_per_px * vh)
	var share := clampf(deg_to_rad(-rel.y * deg_per_px) / maxf(per, 1e-5), 0.0, 1.0) * clampf(_assist_strength(), 0.0, 1.0)
	if upward and not _on_column:
		aim_yaw += wrapf(_col_yaw - aim_yaw, -PI, PI) * share
		_on_column = absf(wrapf(_col_yaw - aim_yaw, -PI, PI)) <= _col_tol
	var dy := -deg_to_rad(rel.y * deg_per_px)
	if _on_column and assist_target != null and _assist_active():
		aim_pitch = _slowed_pitch(aim_pitch, dy, deg_to_rad(deg_per_px * vh))
	else:
		aim_pitch += dy
	aim_pitch = clampf(aim_pitch, deg_to_rad(PITCH_MIN), deg_to_rad(PITCH_MAX))
	# On the column the drag follows the body up to the head, which an aiming stance holds off to
	# one side of the chest (straight up from the chest would graze the side of the head).
	if upward and _on_column:
		aim_yaw += wrapf(_column_yaw(aim_pitch) - aim_yaw, -PI, PI) * share
	_v_drag += rel.y / maxf(vh, 1.0)


## Aim yaw of the target's column at pitch p: the chest's up to the chest, turning to the head's
## over the neck.
func _column_yaw(p: float) -> float:
	var t := clampf((p - _chest_p) / maxf(_head_lo - _chest_p, 1e-4), 0.0, 1.0)
	return _col_yaw + wrapf(_head_yaw - _col_yaw, -PI, PI) * t


## Moves the pitch by dy (radians, + = up) through the target's regions. per_screen is the raw
## pitch one screen height of drag gives; each region takes its share of the screen in drag
## whatever the distance (scaled by the assist): the neck from the chest to the head band, the
## head band (the stop), the lip over it. The body below the chest has the plain friction and
## free air is above the lip. Exact for any event size: one big touch event can't skip the head.
func _slowed_pitch(p: float, dy: float, per_screen: float) -> float:
	var k := clampf(_assist_strength(), 0.0, 1.0)
	if k <= 0.0:
		return p + dy
	var f_body := lerpf(1.0, float(ASSIST.friction), k)
	var edges := [minf(_chest_p, _head_lo - 1e-4), _head_lo, _head_hi, _lip_hi]
	var shares := [float(ASSIST.neck_drag), float(ASSIST.head_drag), float(ASSIST.lip_drag)]
	var f := [f_body, 1.0, 1.0, 1.0, 1.0]       # below the chest, neck, head band, lip, above
	for i in 3:
		var budget := float(shares[i]) * k * per_screen
		f[i + 1] = clampf((float(edges[i + 1]) - float(edges[i])) / maxf(budget, 1e-6), 0.02, f_body if i < 2 else 1.0)
	var left := dy
	for step in 6:
		if absf(left) < 1e-7:
			break
		var probe := p + signf(left) * 1e-6
		var region := 0
		while region < 4 and probe > float(edges[region]):
			region += 1
		var fr: float = f[region]
		var edge := INF if left > 0.0 else -INF
		if left > 0.0 and region < 4:
			edge = float(edges[region])
		elif left < 0.0 and region > 0:
			edge = float(edges[region - 1])
		if is_inf(edge) or absf(left * fr) <= absf(edge - p):
			return p + left * fr
		left -= (edge - p) / fr
		p = edge
	return p


func _assist_strength() -> float:
	return float(ASSIST.strength) * float(weapon().def.get("assist", 1.0))


## Bullets stay on a target the crosshair is locked on (the reference's bullet magnetism): the
## spread shrinks with the aim assist strength while the crosshair is on the body or head.
func current_spread() -> float:
	var s := super()
	var w := weapon()
	# On target (or held on it while the kick throws the camera about) the spray's growth counts
	# a quarter, so a held trigger keeps to the body.
	if (crosshair_on_target or (_on_column and (_anchor == "body" or _anchor == "head"))) and _assist_active():
		s = (s - w.bloom * 0.75) * lerpf(1.0, float(ASSIST.on_target_spread), _assist_strength())
	if int(w.def.pellets) == 1 and w.since_shot > 0.35:
		s *= 0.5                 # the first bullet after a pause goes where the crosshair is
	return s


## Lets go of FIRE without the release shooting (pause, end of the round): a held sniper scope
## closes instead of firing.
func cancel_input() -> void:
	if _scope_hold:
		_scope_hold = false
		ads = false
	firing = false


func set_firing(on: bool) -> void:
	var was := firing
	firing = on and alive
	if firing and not was and scope_type() != "sniper":
		_shot_wait = 0.0
	elif not firing and was and _shot_wait >= 0.0:
		_shot_wait = -1.0
		_fire_once()          # a quick tap still fires
	if firing and healing:
		cancel_heal()
	if firing:
		sprinting = false
	# Snipers: holding FIRE scopes in, releasing shoots (setting "hold fire to scope").
	if scope_type() == "sniper" and Game.settings.hold_fire_scope:
		if firing and not was and not ads:
			ads = true
			_scope_hold = true
			firing = false
		elif not on and _scope_hold:
			_scope_hold = false
			_fire_once()
			ads = false


func _fire_once() -> void:
	if weapon().can_fire():
		_try_fire()


func toggle_ads() -> void:
	if not alive or healing or Weapons.is_melee(weapon().def):
		return
	ads = not ads
	sprinting = false
	_scope_hold = false
	Audio.play("ui_select", -10.0)


func do_jump() -> void:
	want_jump = true


## Crouch button: toggles stand <-> crouch (from prone it goes to crouch), like the reference mode.
func toggle_crouch() -> void:
	set_stance(Stance.STAND if stance == Stance.CROUCH else Stance.CROUCH)


func toggle_prone() -> void:
	set_stance(Stance.STAND if stance == Stance.PRONE else Stance.PRONE)


func set_sprint(on: bool) -> void:
	sprinting = on and stance == Stance.STAND and not ads and not healing


func do_reload() -> void:
	start_reload()


func select_weapon(i: int) -> void:
	switch_weapon(i)
	ads = false


func use_medkit() -> void:
	if healing:
		cancel_heal()
	else:
		start_heal()


func use_shield() -> void:
	deploy_shield()


func use_grenade() -> void:
	throw_grenade()


# ---------------------------------------------------------------- tick

func _think(delta: float) -> void:
	_keyboard_fallback()
	if move_dir.length() > 0.5:
		Game.mark("player moved")
	# Vertical drag: its net amount over the last ticks decides whether firing holds the height (a
	# resting thumb's jitter cancels out, the end of a drag shows at once); any movement at all
	# delays the first shot.
	_v_recent.pop_front()
	_v_recent.append(_v_drag)
	var net := 0.0
	for v in _v_recent:
		net += v
	_since_v_move = 0.0 if absf(_v_drag) > 0.004 else _since_v_move + delta
	_since_v_drag = 0.0 if absf(net) > float(ASSIST.drag_net) else _since_v_drag + delta
	_v_drag = 0.0
	_update_aim_assist(delta)
	if firing and _shot_wait >= 0.0:
		# The first shot leaves when the drag that began with the press stops (or never came).
		_shot_wait += delta
		var settling := _on_column and assist_target != null and aim_pitch > _head_in and aim_pitch <= _lip_hi \
			and _shot_wait < DRAG_SHOT_WINDOW + DRAG_SHOT_SETTLE
		# just beside a target: the pull puts the crosshair on it first (at most DRAG_SHOT_WINDOW)
		settling = settling or (assist_target != null and aim_zone == "" and not _on_column and _shot_wait < DRAG_SHOT_WINDOW)
		if (_shot_wait >= DRAG_SHOT_WINDOW or (_shot_wait >= DRAG_SHOT_START and _since_v_move >= 0.03)) and not settling:
			_shot_wait = -1.0
			_try_fire()
	elif firing:
		_try_fire()
	elif not weapon().infinite() and weapon().ammo <= 0 and not weapon().reloading:
		start_reload()


func _keyboard_fallback() -> void:
	if OS.has_feature("mobile"):
		return
	var k := Vector2.ZERO
	if Input.is_key_pressed(KEY_W):
		k.y += 1
	if Input.is_key_pressed(KEY_S):
		k.y -= 1
	if Input.is_key_pressed(KEY_A):
		k.x -= 1
	if Input.is_key_pressed(KEY_D):
		k.x += 1
	if k != Vector2.ZERO:
		move_dir = k.normalized()
		sprinting = Input.is_key_pressed(KEY_SHIFT)


func _try_fire() -> void:
	var w := weapon()
	if w.reloading or w.cooldown > 0.0 or stance_lock > 0.0:
		return
	if not w.infinite() and w.ammo <= 0:
		start_reload()
		return
	_sync_aim_rig()
	var ray := _shot_ray()
	var start: Vector3 = ray[0]
	var fwd: Vector3 = ray[1]
	if perform_shot(start, fwd):
		Game.mark("player fired")
		if arena and arena.has_method("net_shot"):
			arena.net_shot(start, fwd)
		_apply_recoil(w)
		if scope_type() == "sniper" and ads and not _scope_hold:
			ads = false        # bolt action: the scope drops after each shot


func _apply_recoil(w: WeaponState) -> void:
	var d := w.def
	var k := 1.0
	if ads:
		k *= 0.8
	if crouching:
		k *= 0.75
	elif prone:
		k *= 0.6
	var ramp := 1.0 + float(d.recoil_ramp) * minf(w.burst, 14)
	recoil_pitch += float(d.recoil_v) * ramp * k
	recoil_yaw += rng.randf_range(-float(d.recoil_h), float(d.recoil_h)) * k
	shake = minf(shake + (0.35 if int(d.pellets) > 1 else 0.1), 0.7)
	if int(d.pellets) > 1 or String(d["class"]) == "SNIPER":
		Game.vibrate(25)


## Yaw/pitch (radians) the aim needs so the camera's crosshair (including recoil) points at p.
func _aim_angles_for(p: Vector3) -> Vector2:
	var d := (p - camera.global_position).normalized()
	return Vector2(atan2(-d.x, -d.z) - deg_to_rad(recoil_yaw), asin(clampf(d.y, -1.0, 1.0)) - deg_to_rad(recoil_pitch))


## Angular distance (radians) between the crosshair ray and the target's body, a capsule from
## the feet to the top of the head with the body's half width. 0 = the crosshair is on them.
func _body_miss_angle(f: Fighter) -> float:
	var xf := camera.global_transform
	var o := xf.origin
	var dir := -xf.basis.z
	# Head top to the feet (behind the body when prone).
	var top := f.head_position() + f.model.head_up() * 0.12
	var bottom := (f.model.bone_position("foot_l") + f.model.bone_position("foot_r")) * 0.5 + Vector3.UP * 0.08
	var seg := top - bottom
	var w := bottom - o
	var a := seg.dot(seg)
	var b := seg.dot(dir)
	var c := dir.dot(dir)
	var d := seg.dot(w)
	var e := dir.dot(w)
	var den := a * c - b * b
	var t := clampf((b * e - c * d) / den, 0.0, 1.0) if absf(den) > 1e-6 else 0.0
	var p := bottom + seg * t
	var dist := o.distance_to(p)
	var ang := dir.angle_to((p - o) / maxf(dist, 0.01))
	var radius := atan(0.32 / maxf(dist, 0.5))
	return maxf(ang - radius, 0.0)


## The line a shot leaves along before spread: the crosshair's ray from level with the eyes.
func _shot_ray() -> Array:
	var xf := camera.global_transform
	var fwd := -xf.basis.z
	return [xf.origin + fwd * maxf((eye_position() - xf.origin).dot(fwd), 0.0), fwd]


## True when that line meets f before any cover, within the gun's reach: the red crosshair.
func _crosshair_meets(f: Fighter) -> bool:
	var ray := _shot_ray()
	var res := trace(ray[0], ray[1], float(weapon().def.range) * 1.6)
	return not res.is_empty() and owner_of(res.collider) == f


## The camera turns with the aim in _process; physics (shots, the assist) first turns it to the
## aim of this very moment, so a drag that ended since the last frame still counts.
func _sync_aim_rig() -> void:
	if yaw_node == null or victory_cam or not alive:
		return
	yaw_node.rotation.y = aim_yaw + deg_to_rad(recoil_yaw)
	pitch_node.rotation.x = aim_pitch + deg_to_rad(recoil_pitch)


func _update_aim_assist(delta: float) -> void:
	_sync_aim_rig()
	assist_target = null
	crosshair_on_target = false
	aim_zone = ""
	_on_column = false
	if arena == null or camera == null:
		return
	var xf := camera.global_transform
	var scoped := is_scoped()
	var max_range := float(ASSIST.range_scope if scoped else ASSIST.range_hip)
	var best_score := INF
	var best_miss := PI
	for f: Fighter in arena.fighters:
		if f == self or not f.alive:
			continue
		var chest := f.chest_position()
		var dist := xf.origin.distance_to(chest)
		var miss := _body_miss_angle(f)
		var zone := _zone_on(f)
		# The red crosshair: a shot (before spread) would hit them, at any range the gun reaches;
		# the assist works only inside max_range.
		if _crosshair_meets(f):
			crosshair_on_target = true
		if dist > max_range:
			continue
		var cone := deg_to_rad(float(ASSIST.cone_scope_deg if scoped else ASSIST.cone_deg))
		if not scoped:
			cone *= clampf(10.0 / maxf(dist, 1.0), 0.6, 3.0)
		if miss > cone or not (can_see(chest) or can_see(f.head_position())):
			continue
		if miss < best_score:
			best_score = miss
			best_miss = miss
			assist_target = f
			aim_zone = zone      # the aim works the same at any range; the red crosshair only in range
	if assist_target == null:
		_track_target = null
		_anchor = ""
		return
	if not _assist_active():
		_track_target = null
		_anchor = ""
		return
	var strength := _assist_strength()
	var head := assist_target.head_position()
	var band := float(ASSIST.head_band)
	var chest_aim := _aim_angles_for(assist_target.chest_position())
	_chest_p = chest_aim.y
	_head_lo = _aim_angles_for(head - Vector3.UP * band).y
	_head_hi = _aim_angles_for(head + Vector3.UP * band).y
	_head_in = _aim_angles_for(head + Vector3.UP * band * 0.5).y
	_lip_hi = _aim_angles_for(head + Vector3.UP * (band + float(ASSIST.lip))).y
	var d := xf.origin.distance_to(head)
	_col_yaw = chest_aim.x
	_head_yaw = _aim_angles_for(head).x
	_col_tol = atan(0.35 / maxf(d, 0.5)) + deg_to_rad(float(ASSIST.bubble_deg) + 1.5)
	_on_column = absf(wrapf(_col_yaw - aim_yaw, -PI, PI)) <= _col_tol
	var on_body := best_miss <= deg_to_rad(float(ASSIST.track_deg))
	# Tracking: follow the target's angular motion while on (or right next to) them.
	var chest_dir := (assist_target.chest_position() - xf.origin).normalized()
	if _track_target == assist_target and on_body:
		var prev := Vector2(atan2(-_track_dir.x, -_track_dir.z), asin(clampf(_track_dir.y, -1.0, 1.0)))
		var now := Vector2(atan2(-chest_dir.x, -chest_dir.z), asin(clampf(chest_dir.y, -1.0, 1.0)))
		var k := clampf(float(ASSIST.track) * strength, 0.0, 1.0)
		aim_yaw += wrapf(now.x - prev.x, -PI, PI) * k
		aim_pitch += (now.y - prev.y) * k
	if _track_target != assist_target:
		_anchor = ""
	_track_target = assist_target
	_track_dir = chest_dir
	# The drag decides what firing holds: where the aim is when it stops (head, also from the lip
	# just over it; the body; or over the head). The choice stays until the next drag, so a gun's
	# kick throwing the camera over the head band for a moment can't switch it.
	if _since_v_drag <= float(ASSIST.drag_free):          # dragging (or just stopped): undecided
		_anchor = ""
	elif _anchor == "":
		if not _on_column or aim_pitch < _head_lo:
			_anchor = "body"
		else:
			_anchor = "head" if aim_pitch <= _lip_hi else "over"
	# Pull while firing: sideways onto the body always; the height only once the drag has
	# stopped, onto what it chose (the head or the body) against the recoil; never down from over
	# the head.
	if firing and strength > 0.0:
		var want := _aim_angles_for(head) if _anchor == "head" else chest_aim
		var err := Vector2(wrapf(want.x - aim_yaw, -PI, PI), want.y - aim_pitch)
		if _anchor == "" or _anchor == "over":
			err.y = 0.0
		var rate := float(ASSIST.pull_rate) * strength
		var cap := deg_to_rad(float(ASSIST.pull_max_deg)) * strength * delta
		var step := err * (1.0 - exp(-rate * delta))
		aim_yaw += clampf(step.x, -cap, cap)
		aim_pitch += clampf(step.y, -cap, cap)


## Where the crosshair is on f: "head" (within the head band), "" over the head or off them,
## "body" anywhere else on them (with the on-target margin).
func _zone_on(f: Fighter) -> String:
	var xf := camera.global_transform
	var dir := -xf.basis.z
	var band := float(ASSIST.head_band)
	var to_head := f.head_position() - xf.origin
	var hd := to_head.length()
	if dir.angle_to(to_head / maxf(hd, 0.01)) <= atan(band / maxf(hd, 0.3)):
		return "head"
	var top := (f.head_position() + Vector3.UP * band - xf.origin).normalized()
	if dir.y > top.y and dir.angle_to(to_head / maxf(hd, 0.01)) < deg_to_rad(25.0):
		return ""
	return "body" if _body_miss_angle(f) <= deg_to_rad(float(ASSIST.bubble_deg)) else ""


func _process(delta: float) -> void:
	super._process(delta)
	if rig == null:
		return
	var w := weapon()
	var rec := 1.0 - exp(-(9.0 if w.since_shot > 0.08 else 3.5) * delta)
	recoil_pitch = lerpf(recoil_pitch, 0.0, rec)
	recoil_yaw = lerpf(recoil_yaw, 0.0, rec)
	shake = maxf(shake - delta * 2.5, 0.0)
	var target_y := eye_height() + 0.02 if alive else 0.6
	if victory_cam:
		target_y = 1.25
	_cam_y = lerpf(_cam_y, target_y, 1.0 - exp(-10.0 * delta))
	rig.global_position = global_position + Vector3.UP * _cam_y
	var sx := (randf() - 0.5) * shake * 0.6
	var sy := (randf() - 0.5) * shake * 0.6
	if victory_cam or not alive:
		# Orbit to the front (victory) or look down at the body (eliminated).
		if victory_cam and _victory_yaw == INF:
			_victory_yaw = _pick_victory_yaw()
		var want_yaw := _victory_yaw if victory_cam else aim_yaw
		var want_pitch := deg_to_rad(-8.0 if victory_cam else -38.0)
		var k := 1.0 - exp(-2.5 * delta)
		yaw_node.rotation.y = lerp_angle(yaw_node.rotation.y, want_yaw, k)
		pitch_node.rotation.x = lerpf(pitch_node.rotation.x, want_pitch, k)
	else:
		yaw_node.rotation.y = aim_yaw + deg_to_rad(recoil_yaw + sx)
		pitch_node.rotation.x = aim_pitch + deg_to_rad(recoil_pitch + sy)
	var scoped := is_scoped()
	var dist := ADS_DIST if ads else CAM_DIST
	if scoped:
		dist = 0.05                  # the scope view is first person
	elif prone:
		dist *= 0.9
	if not alive:
		dist = 4.5
	elif victory_cam:
		dist = 3.2
	spring.spring_length = lerpf(spring.spring_length, dist, 1.0 - exp(-(30.0 if scoped else 12.0) * delta))
	var fov_target := float(w.def.ads_fov) if ads else FOV_HIP
	_fov = lerpf(_fov, fov_target, 1.0 - exp(-14.0 * delta))
	camera.fov = _fov
	_update_fade(scoped)
	var shoulder := 0.0 if (victory_cam or scoped) else (0.42 if ads else CAM_SHOULDER)
	# Keep the shoulder offset out of walls (right side against a container): the spring arm
	# only guards the line behind the shoulder, not the sideways step to it.
	var walled := false
	if shoulder > 0.0:
		var origin := pitch_node.global_position
		var res := trace(origin, pitch_node.global_basis.x, shoulder + 0.2, LAYER_WORLD)
		if not res.is_empty():
			shoulder = maxf(origin.distance_to(res.position) - 0.2, 0.0)
			walled = true
	if walled and shoulder < spring.position.x:
		spring.position.x = shoulder        # pull in at once, ease back out
	else:
		spring.position.x = lerpf(spring.position.x, shoulder, 1.0 - exp(-(30.0 if scoped else 12.0) * delta))


## Finds an orbit angle with a clear 3 m view of the character (avoids walls).
func _pick_victory_yaw() -> float:
	var head := global_position + Vector3.UP * 1.3
	var best := aim_yaw + PI
	var best_len := -1.0
	for off in [PI, PI - 0.9, PI + 0.9, PI * 0.5, -PI * 0.5, 0.0]:
		var yaw: float = aim_yaw + off
		var back := Basis(Vector3.UP, yaw) * Vector3(0, 0.45, 1.0).normalized()
		var res := trace(head, back, 3.4, LAYER_WORLD | LAYER_SHIELD)
		var free_len := 3.4 if res.is_empty() else head.distance_to(res.position)
		if free_len >= 3.3:
			return yaw
		if free_len > best_len:
			best_len = free_len
			best = yaw
	return best


func _update_fade(scoped := false) -> void:
	# The scope is a first-person view: the own model (head, hair, gun) would fill it.
	if model.visible == scoped:
		model.visible = not scoped
	var close := spring.get_hit_length() < 0.95 and alive and not scoped
	if close == _faded:
		return
	_faded = close
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).transparency = 0.75 if close else 0.0


func add_shake(amount: float) -> void:
	shake = minf(shake + amount, 1.5)

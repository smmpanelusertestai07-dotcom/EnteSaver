class_name Player
extends Fighter
## Local player: over-the-shoulder camera, touch look / drag-fire, recoil and aim assist.

const CAM_HEIGHT := 1.6
const CAM_SHOULDER := 0.55
const CAM_DIST := 3.1
const ADS_DIST := 1.55
const FOV_HIP := 68.0
const PITCH_MIN := -70.0
const PITCH_MAX := 62.0

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
var head_lock := 0.0    # s left of the armed head stop
var input_enabled := true
var victory_cam := false
var _victory_yaw := INF
var _faded := false
var _cam_y := CAM_HEIGHT
var _fov := FOV_HIP


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
	camera.far = 1500.0
	spring.add_child(camera)
	camera.current = true
	spring.add_excluded_object(get_rid())
	rig.global_position = global_position + Vector3.UP * CAM_HEIGHT


# ---------------------------------------------------------------- input API (called by HUD)

## Aim assist tuning. The feel being matched: the crosshair slows down and "sticks" to an enemy
## it is over, follows them when they strafe, gets pulled onto the body while firing, and a
## quick upward drag while firing stops on the head instead of flying past it.
const ASSIST := {
	"range": 65.0,             # metres
	"cone_deg": 6.0,           # acquisition cone half-angle at 10 m (wider up close)
	"bubble_deg": 0.9,         # angular margin around the body that still counts as "on target"
	"friction": 0.5,           # look sensitivity multiplier while on target (lower = stickier)
	"track": 0.8,              # share of the target's angular motion the aim follows on target
	"pull_rate": 9.0,          # 1/s exponential pull toward the aim point while firing
	"pull_max_deg": 55.0,      # deg/s cap of that pull
	"head_window": 0.5,        # s the head stop stays armed after an upward drag while firing
	"head_drag_px": 1.2,       # minimum upward drag per event (px) that arms the head stop
}

var crosshair_on_target := false      # HUD: crosshair turns red
var _track_dir := Vector3.ZERO        # last camera->target chest direction (for tracking)
var _track_target: Fighter


func add_look(rel: Vector2, from_fire_button := false) -> void:
	if not alive or not input_enabled:
		return
	var s: float = Game.settings.sens_reddot if ads else Game.settings.sens_general
	if from_fire_button:
		s *= float(Game.settings.sens_fire) / 55.0
	var vh := get_viewport().get_visible_rect().size.y
	var deg_per_px := 120.0 / maxf(vh, 1.0) * (s / 50.0)
	var friction := 1.0
	if crosshair_on_target and Game.settings.aim_assist:
		friction = lerpf(1.0, float(ASSIST.friction), _assist_strength())
	aim_yaw -= deg_to_rad(rel.x * deg_per_px * friction)
	aim_pitch = clampf(aim_pitch - deg_to_rad(rel.y * deg_per_px * friction), deg_to_rad(PITCH_MIN), deg_to_rad(PITCH_MAX))
	# Upward drag while firing near a target arms the head stop ("drag headshot").
	if firing and rel.y < -float(ASSIST.head_drag_px) and assist_target and Game.settings.aim_assist:
		head_lock = float(ASSIST.head_window) * float(weapon().def.get("head_lock", 0.6)) / 0.6
	_apply_head_stop()


func _assist_strength() -> float:
	return clampf(float(Game.settings.aim_assist_strength) / 100.0, 0.0, 1.0)


func set_firing(on: bool) -> void:
	firing = on and alive and input_enabled
	if firing and healing:
		cancel_heal()


func toggle_ads() -> void:
	if not alive or healing:
		return
	ads = not ads
	Audio.play("ui_select", -10.0)


func do_jump() -> void:
	if input_enabled:
		want_jump = true


func toggle_crouch() -> void:
	if input_enabled:
		set_crouch(not crouching)


func do_reload() -> void:
	if input_enabled:
		start_reload()


func select_weapon(i: int) -> void:
	if input_enabled:
		switch_weapon(i)
		ads = false


func use_medkit() -> void:
	if input_enabled:
		if healing:
			cancel_heal()
		else:
			start_heal()


func use_shield() -> void:
	if input_enabled:
		deploy_shield()


func use_grenade() -> void:
	if input_enabled:
		throw_grenade()


# ---------------------------------------------------------------- tick

func _think(delta: float) -> void:
	if not input_enabled:
		move_dir = Vector2.ZERO
		firing = false
		return
	_keyboard_fallback()
	if move_dir.length() > 0.5:
		Game.mark("player moved")
	_update_aim_assist(delta)
	if firing:
		_try_fire()
	elif weapon().ammo <= 0 and not weapon().reloading:
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


func _try_fire() -> void:
	var w := weapon()
	if w.reloading or w.cooldown > 0.0:
		return
	if w.ammo <= 0:
		start_reload()
		return
	var xf := camera.global_transform
	var fwd := -xf.basis.z
	var head := eye_position()
	var start := xf.origin + fwd * maxf((head - xf.origin).dot(fwd), 0.0)
	if perform_shot(start, fwd):
		Game.mark("player fired")
		_apply_recoil(w)


func _apply_recoil(w: WeaponState) -> void:
	var d := w.def
	var k := 1.0
	if ads:
		k *= 0.8
	if crouching:
		k *= 0.75
	var ramp := 1.0 + float(d.recoil_ramp) * minf(w.burst, 14)
	recoil_pitch += float(d.recoil_v) * ramp * k
	recoil_yaw += rng.randf_range(-float(d.recoil_h), float(d.recoil_h)) * k
	shake = minf(shake + (0.35 if w.id == "sg" else 0.1), 0.7)
	if w.id == "sg":
		Game.vibrate(25)


func _assist_angle(point: Vector3) -> float:
	if camera == null:
		return PI
	var xf := camera.global_transform
	return (-xf.basis.z).angle_to((point - xf.origin).normalized())


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
	var top := f.head_position() + Vector3.UP * 0.12
	var bottom := f.global_position + Vector3.UP * 0.15
	# closest point on the body segment to the ray
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


func _update_aim_assist(delta: float) -> void:
	head_lock = maxf(head_lock - delta, 0.0)
	assist_target = null
	crosshair_on_target = false
	if arena == null or camera == null:
		return
	var xf := camera.global_transform
	var best_score := INF
	var best_miss := PI
	for f: Fighter in arena.fighters:
		if f == self or not f.alive:
			continue
		var chest := f.chest_position()
		var dist := xf.origin.distance_to(chest)
		if dist > float(ASSIST.range):
			continue
		var miss := _body_miss_angle(f)
		var cone := deg_to_rad(float(ASSIST.cone_deg)) * clampf(10.0 / maxf(dist, 1.0), 0.6, 3.0)
		if ads:
			cone *= 0.75
		if miss > cone or not (can_see(chest) or can_see(f.head_position())):
			continue
		if miss < best_score:
			best_score = miss
			best_miss = miss
			assist_target = f
	if assist_target == null:
		_track_target = null
		head_lock = 0.0
		return
	crosshair_on_target = best_miss <= deg_to_rad(float(ASSIST.bubble_deg))
	if not Game.settings.aim_assist:
		_track_target = null
		return
	var strength := _assist_strength()
	# Tracking: follow the target's angular motion while on (or right next to) them.
	var chest_dir := (assist_target.chest_position() - xf.origin).normalized()
	if _track_target == assist_target and crosshair_on_target:
		var prev := Vector2(atan2(-_track_dir.x, -_track_dir.z), asin(clampf(_track_dir.y, -1.0, 1.0)))
		var now := Vector2(atan2(-chest_dir.x, -chest_dir.z), asin(clampf(chest_dir.y, -1.0, 1.0)))
		var k := float(ASSIST.track) * strength
		aim_yaw += wrapf(now.x - prev.x, -PI, PI) * k
		aim_pitch += (now.y - prev.y) * k
	_track_target = assist_target
	_track_dir = chest_dir
	# Pull while firing (or while the head stop is armed): onto the chest, or the head.
	if (firing or head_lock > 0.0) and strength > 0.0:
		var point := assist_target.head_position() if head_lock > 0.0 else assist_target.chest_position()
		var want := _aim_angles_for(point)
		var err := Vector2(wrapf(want.x - aim_yaw, -PI, PI), want.y - aim_pitch)
		var step := err * (1.0 - exp(-float(ASSIST.pull_rate) * strength * delta))
		var cap := deg_to_rad(float(ASSIST.pull_max_deg)) * strength * delta
		if head_lock > 0.0:
			cap *= 2.5
		aim_yaw += clampf(step.x, -cap, cap)
		aim_pitch += clampf(step.y, -cap, cap)
	_apply_head_stop()


## While the head stop is armed, the crosshair can't be dragged above the target's head.
func _apply_head_stop() -> void:
	if head_lock <= 0.0 or assist_target == null or camera == null:
		return
	var want := _aim_angles_for(assist_target.head_position() + Vector3.UP * 0.03)
	if aim_pitch > want.y:
		aim_pitch = want.y


func _process(delta: float) -> void:
	super._process(delta)
	if rig == null:
		return
	var w := weapon()
	if w.since_shot > 0.12:
		var rec := 1.0 - exp(-7.0 * delta)
		recoil_pitch = lerpf(recoil_pitch, 0.0, rec)
		recoil_yaw = lerpf(recoil_yaw, 0.0, rec)
	shake = maxf(shake - delta * 2.5, 0.0)
	var target_y := (CROUCH_EYE if crouching else CAM_HEIGHT) if alive else 0.6
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
	var dist := ADS_DIST if ads else CAM_DIST
	if not alive:
		dist = 4.5
	elif victory_cam:
		dist = 3.2
	spring.spring_length = lerpf(spring.spring_length, dist, 1.0 - exp(-12.0 * delta))
	var fov_target := float(w.def.ads_fov) if ads else FOV_HIP
	_fov = lerpf(_fov, fov_target, 1.0 - exp(-12.0 * delta))
	camera.fov = _fov
	_update_fade()
	var shoulder := 0.0 if victory_cam else (0.42 if ads else CAM_SHOULDER)
	spring.position.x = lerpf(spring.position.x, shoulder, 1.0 - exp(-12.0 * delta))


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


func _update_fade() -> void:
	var close := spring.get_hit_length() < 0.95 and alive
	if close == _faded:
		return
	_faded = close
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).transparency = 0.75 if close else 0.0


func add_shake(amount: float) -> void:
	shake = minf(shake + amount, 1.5)

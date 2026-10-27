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
var head_lock := 0.0
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

func add_look(rel: Vector2, from_fire_button := false) -> void:
	if not alive or not input_enabled:
		return
	var s: float = Game.settings.sens_reddot if ads else Game.settings.sens_general
	if from_fire_button:
		s *= float(Game.settings.sens_fire) / 55.0
	var vh := get_viewport().get_visible_rect().size.y
	var deg_per_px := 120.0 / maxf(vh, 1.0) * (s / 50.0)
	var friction := 1.0
	if assist_target and _assist_angle(assist_target.chest_position()) < deg_to_rad(4.0):
		friction = lerpf(1.0, 0.55, float(Game.settings.aim_assist_strength) / 100.0)
	aim_yaw -= deg_to_rad(rel.x * deg_per_px * friction)
	aim_pitch = clampf(aim_pitch - deg_to_rad(rel.y * deg_per_px * friction), deg_to_rad(PITCH_MIN), deg_to_rad(PITCH_MAX))
	# FF-style "drag headshot": dragging up while firing near the head snaps briefly to it.
	if firing and rel.y < -1.5 and assist_target and Game.settings.aim_assist:
		var strength := float(Game.settings.aim_assist_strength) / 100.0
		if _assist_angle(assist_target.head_position()) < deg_to_rad(2.0 + 3.0 * strength):
			head_lock = 0.2


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


func _update_aim_assist(delta: float) -> void:
	head_lock = maxf(head_lock - delta, 0.0)
	assist_target = null
	if not Game.settings.aim_assist or arena == null or camera == null:
		return
	var strength := float(Game.settings.aim_assist_strength) / 100.0
	var xf := camera.global_transform
	var best_score := INF
	for f: Fighter in arena.fighters:
		if f == self or not f.alive:
			continue
		var chest := f.chest_position()
		var dist := eye_position().distance_to(chest)
		if dist > 70.0:
			continue
		var limit := deg_to_rad(7.0 if ads else 9.0) * (1.0 + clampf(5.0 / maxf(dist, 1.0), 0.0, 1.5))
		var ang := _assist_angle(chest)
		if ang > limit or not can_see(chest):
			continue
		if ang < best_score:
			best_score = ang
			assist_target = f
	if assist_target == null or strength <= 0.0:
		return
	if not firing and head_lock <= 0.0:
		return
	var point := assist_target.head_position() if head_lock > 0.0 else assist_target.chest_position()
	var desired := (point - xf.origin).normalized()
	var want_yaw := atan2(-desired.x, -desired.z) - deg_to_rad(recoil_yaw)
	var want_pitch := asin(clampf(desired.y, -1.0, 1.0)) - deg_to_rad(recoil_pitch)
	var rate := deg_to_rad(lerpf(4.0, 16.0, strength)) * delta
	if head_lock > 0.0:
		rate *= 4.0
	aim_yaw += clampf(wrapf(want_yaw - aim_yaw, -PI, PI), -rate, rate)
	aim_pitch += clampf(want_pitch - aim_pitch, -rate, rate)


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

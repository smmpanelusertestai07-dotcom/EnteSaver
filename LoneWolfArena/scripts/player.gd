class_name Player
extends Fighter
## Local player: over-the-shoulder camera, touch look / drag-fire, scopes, recoil and aim assist.

const CAM_HEIGHT := 1.62
const CAM_SHOULDER := 0.5
const CAM_DIST := 3.25
const ADS_DIST := 1.5
const FOV_HIP := 68.0
const PITCH_MIN := -70.0
const PITCH_MAX := 62.0

## Aim assist tuning. The feel being matched: the crosshair slows down and "sticks" to an enemy
## it is over, follows them when they strafe, gets pulled onto the body while firing, and a
## quick upward drag while firing stops on the head instead of flying past it.
const ASSIST := {
	"range_hip": 30.0,          # metres, hip fire / red dot
	"range_scope": 80.0,        # metres, sniper scope
	"cone_deg": 6.0,            # acquisition cone half-angle at 10 m (wider up close)
	"cone_scope_deg": 2.5,
	"bubble_deg": 0.9,          # angular margin around the body that still counts as "on target"
	"friction": 0.55,           # look sensitivity multiplier while on target (lower = stickier)
	"track": 0.7,               # share of the target's angular motion the aim follows on target
	"pull_rate": 9.0,           # 1/s exponential pull toward the aim point while firing
	"pull_max_deg": 55.0,       # deg/s cap of that pull
	"head_window": 0.5,         # s the head stop stays armed after an upward drag while firing
	"head_drag_px": 1.2,        # minimum upward drag per event (px) that arms the head stop
}

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


## Sensitivity for the current view (settings are 0..200, 100 = default speed).
func _sensitivity() -> float:
	var s: float = Game.settings.sens_general
	if ads:
		s = Game.settings.sens_sniper if scope_type() == "sniper" else Game.settings.sens_reddot
	return maxf(s, 1.0) / 100.0


## Whether aim assist applies right now (Aim Precision: default / precise on scope / full control).
func _assist_active() -> bool:
	if not Game.settings.aim_assist:
		return false
	match int(Game.settings.aim_precision):
		1:
			return not ads
		2:
			return false
	return true


func add_look(rel: Vector2, from_fire_button := false) -> void:
	if not alive or not input_enabled:
		return
	var s := _sensitivity()
	if from_fire_button:
		s *= float(Game.settings.sens_fire) / 100.0
	var vh := get_viewport().get_visible_rect().size.y
	var deg_per_px := 130.0 / maxf(vh, 1.0) * s
	if ads:
		deg_per_px *= _fov / FOV_HIP
	var friction := 1.0
	if crosshair_on_target and _assist_active():
		friction = lerpf(1.0, float(ASSIST.friction), _assist_strength())
	aim_yaw -= deg_to_rad(rel.x * deg_per_px * friction)
	aim_pitch = clampf(aim_pitch - deg_to_rad(rel.y * deg_per_px * friction), deg_to_rad(PITCH_MIN), deg_to_rad(PITCH_MAX))
	# Upward drag while firing near a target arms the head stop ("drag headshot").
	if firing and rel.y < -float(ASSIST.head_drag_px) and assist_target and _assist_active():
		head_lock = float(ASSIST.head_window) * float(weapon().def.get("head_lock", 0.6)) / 0.6
	_apply_head_stop()


func _assist_strength() -> float:
	return clampf(float(Game.settings.aim_assist_strength) / 100.0, 0.0, 1.0) * float(weapon().def.get("assist", 1.0))


func set_firing(on: bool) -> void:
	var was := firing
	firing = on and alive and input_enabled
	if firing and healing:
		cancel_heal()
	if firing:
		sprinting = false
	# Snipers: holding FIRE scopes in, releasing shoots (setting "hold fire to scope").
	if scope_type() == "sniper" and Game.settings.hold_fire_scope and input_enabled:
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
	if input_enabled:
		want_jump = true


## FF-style: crouch toggles stand <-> crouch (from prone it goes to crouch).
func toggle_crouch() -> void:
	if input_enabled:
		set_stance(Stance.STAND if stance == Stance.CROUCH else Stance.CROUCH)


func toggle_prone() -> void:
	if input_enabled:
		set_stance(Stance.STAND if stance == Stance.PRONE else Stance.PRONE)


func set_sprint(on: bool) -> void:
	if input_enabled:
		sprinting = on and stance == Stance.STAND and not ads and not healing


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
	var xf := camera.global_transform
	var fwd := -xf.basis.z
	var head := eye_position()
	var start := xf.origin + fwd * maxf((head - xf.origin).dot(fwd), 0.0)
	if perform_shot(start, fwd):
		Game.mark("player fired")
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


func _update_aim_assist(delta: float) -> void:
	head_lock = maxf(head_lock - delta, 0.0)
	assist_target = null
	crosshair_on_target = false
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
		# The red crosshair works at any range the gun reaches; assist only inside max_range.
		if miss <= deg_to_rad(float(ASSIST.bubble_deg)) and dist <= float(weapon().def.range) * 1.6 \
				and (can_see(chest) or can_see(f.head_position())):
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
	if assist_target == null:
		_track_target = null
		head_lock = 0.0
		return
	if not _assist_active():
		_track_target = null
		return
	var strength := _assist_strength()
	var on_body := best_miss <= deg_to_rad(float(ASSIST.bubble_deg))
	# Tracking: follow the target's angular motion while on (or right next to) them.
	var chest_dir := (assist_target.chest_position() - xf.origin).normalized()
	if _track_target == assist_target and on_body:
		var prev := Vector2(atan2(-_track_dir.x, -_track_dir.z), asin(clampf(_track_dir.y, -1.0, 1.0)))
		var now := Vector2(atan2(-chest_dir.x, -chest_dir.z), asin(clampf(chest_dir.y, -1.0, 1.0)))
		var k := clampf(float(ASSIST.track) * strength, 0.0, 1.0)
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
	var close := (spring.get_hit_length() < 0.95 or scoped) and alive
	if close == _faded:
		return
	_faded = close
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).transparency = (1.0 if scoped else 0.75) if close else 0.0


func add_shake(amount: float) -> void:
	shake = minf(shake + amount, 1.5)

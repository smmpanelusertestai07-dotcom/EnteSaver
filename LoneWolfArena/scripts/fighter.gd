class_name Fighter
extends CharacterBody3D
## Shared combat logic for the player and bots: health/armor, weapons, items,
## hitboxes, movement and animation hookup. Subclasses implement _think().

signal died(victim: Fighter, killer: Fighter, headshot: bool)
signal damaged(amount: float, from_pos: Vector3, headshot: bool, attacker: Fighter)
signal hit_landed(target: Fighter, amount: float, headshot: bool, pos: Vector3, killed: bool)
signal fired(w: WeaponState)
signal weapon_switched

const LAYER_WORLD := 1
const LAYER_BODY := 2
const LAYER_HITBOX := 4
const LAYER_SHIELD := 8
const MASK_SHOT := LAYER_WORLD | LAYER_HITBOX | LAYER_SHIELD
const MASK_SIGHT := LAYER_WORLD | LAYER_SHIELD

const MAX_HP := 200.0
const GRAVITY := 22.0
const JUMP_V := 7.0
const RUN_SPEED := 5.3
const ADS_SPEED := 3.0
const CROUCH_SPEED := 2.4
const HEAL_SPEED := 1.8
const HEAL_TIME := 3.0
const HEAL_AMOUNT := 75.0
const EYE_HEIGHT := 1.6
const CROUCH_EYE := 1.12
const STAND_HEIGHT := 1.8
const CROUCH_HEIGHT := 1.25

var display_name := "PLAYER"
var is_player := false
var hp := MAX_HP
var alive := true
var vest_reduction := 0.30
var helmet_reduction := 0.35
var weapons: Array[WeaponState] = []
var current := 0
var crouching := false
var ads := false
var medkits := 2
var shields := 2
var grenades := 1
var healing := false
var heal_left := 0.0
var aim_yaw := 0.0
var aim_pitch := 0.0
var move_dir := Vector2.ZERO
var want_jump := false
var frozen := false
var stats := {"shots": 0, "hits": 0, "headshots": 0, "damage": 0.0, "kills": 0, "taken": 0.0}
var model: CharacterModel
var arena: Node
var hitboxes: Array[Area3D] = []
var rng := RandomNumberGenerator.new()
var bundle_id := "default"
var last_damage_time := -99.0
var last_shot_time := -99.0
var invulnerable := false

var _exclude: Array[RID] = []
var _collider: CollisionShape3D
var _capsule: CapsuleShape3D
var _step_timer := 0.0
var _boxes := {}
var _was_air := false


func setup_fighter(bundle: String) -> void:
	bundle_id = bundle
	rng.randomize()
	collision_layer = LAYER_BODY
	collision_mask = LAYER_WORLD | LAYER_BODY | LAYER_SHIELD
	floor_snap_length = 0.35
	floor_max_angle = deg_to_rad(50)
	_capsule = CapsuleShape3D.new()
	_capsule.radius = 0.36
	_capsule.height = STAND_HEIGHT
	_collider = CollisionShape3D.new()
	_collider.shape = _capsule
	_collider.position.y = STAND_HEIGHT * 0.5
	add_child(_collider)
	model = CharacterModel.new()
	model.name = "Model"
	add_child(model)
	model.setup(bundle)
	for id in Weapons.LOADOUT:
		weapons.append(WeaponState.new(id))
	model.equip_weapon(weapons[current].def.model)
	_build_hitboxes()
	_exclude = [get_rid()]
	for hb in hitboxes:
		_exclude.append(hb.get_rid())


# ---------------------------------------------------------------- hitboxes

func _build_hitboxes() -> void:
	# zone, anchor roles (midpoint), radius
	var defs := [
		["head", "head", ["head"], 0.14],
		["chest", "body", ["spine2", "spine3"], 0.21],
		["belly", "body", ["spine1", "pelvis"], 0.2],
		["thigh_l", "limb", ["thigh_l", "calf_l"], 0.11],
		["thigh_r", "limb", ["thigh_r", "calf_r"], 0.11],
		["calf_l", "limb", ["calf_l", "foot_l"], 0.09],
		["calf_r", "limb", ["calf_r", "foot_r"], 0.09],
		["arm_l", "limb", ["upperarm_l", "lowerarm_l"], 0.08],
		["arm_r", "limb", ["upperarm_r", "lowerarm_r"], 0.08],
	]
	for d in defs:
		var area := Area3D.new()
		area.name = "HB_" + d[0]
		area.collision_layer = LAYER_HITBOX
		area.collision_mask = 0
		area.monitoring = false
		area.monitorable = true
		area.top_level = true
		var cs := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = d[3]
		cs.shape = sph
		area.add_child(cs)
		area.set_meta("fighter", self)
		area.set_meta("zone", d[1])
		add_child(area)
		hitboxes.append(area)
		_boxes[d[0]] = [area, d[2]]
	_update_hitboxes()


func _update_hitboxes() -> void:
	for key in _boxes:
		var entry: Array = _boxes[key]
		var area: Area3D = entry[0]
		var roles: Array = entry[1]
		var p := Vector3.ZERO
		for r in roles:
			p += model.bone_position(r)
		p /= roles.size()
		if key == "head":
			p += Vector3.UP * 0.07
		area.global_position = p


func head_position() -> Vector3:
	return (_boxes["head"][0] as Area3D).global_position


func chest_position() -> Vector3:
	return (_boxes["chest"][0] as Area3D).global_position


func eye_height() -> float:
	return CROUCH_EYE if crouching else EYE_HEIGHT


func eye_position() -> Vector3:
	return global_position + Vector3.UP * eye_height()


func aim_forward() -> Vector3:
	var b := Basis(Vector3.UP, aim_yaw) * Basis(Vector3.RIGHT, aim_pitch)
	return -b.z


func weapon() -> WeaponState:
	return weapons[current]


# ---------------------------------------------------------------- damage

func take_damage(amount: float, zone: String, attacker: Fighter, from_pos: Vector3) -> float:
	if not alive or invulnerable:
		return 0.0
	var dmg := minf(Weapons.after_armor(amount, zone, vest_reduction, helmet_reduction), hp)
	hp -= dmg
	stats.taken += dmg
	last_damage_time = _now()
	if healing:
		cancel_heal()
	damaged.emit(dmg, from_pos, zone == "head", attacker)
	if hp <= 0.001:
		hp = 0.0
		die(attacker, zone == "head")
	return dmg


func die(killer: Fighter, headshot := false) -> void:
	if not alive:
		return
	alive = false
	healing = false
	ads = false
	velocity = Vector3(0, minf(velocity.y, 0.0), 0)
	_collider.set_deferred("disabled", true)
	for hb in hitboxes:
		hb.collision_layer = 0
	model.play_death()
	died.emit(self, killer, headshot)


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


# ---------------------------------------------------------------- shooting

func trace(from: Vector3, dir: Vector3, dist: float, mask := MASK_SHOT) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * dist, mask, _exclude)
	q.collide_with_areas = true
	q.collide_with_bodies = true
	return get_world_3d().direct_space_state.intersect_ray(q)


func can_see(point: Vector3, from := Vector3.INF) -> bool:
	var origin := eye_position() if from == Vector3.INF else from
	var dir := point - origin
	var dist := dir.length()
	if dist < 0.01:
		return true
	var res := trace(origin, dir / dist, dist - 0.05, MASK_SIGHT)
	return res.is_empty()


func current_spread() -> float:
	var w := weapon()
	var d := w.def
	var s: float = d.spread_ads if ads else d.spread_hip
	var hs := Vector2(velocity.x, velocity.z).length()
	s += float(d.spread_move) * clampf(hs / RUN_SPEED, 0.0, 1.0)
	if not is_on_floor():
		s += float(d.spread_air)
	if crouching:
		s *= 0.75
	return s + w.bloom


## Fires the current weapon along base_dir. ray_origin is where the hit-scan starts
## (camera-aligned for the player, eyes for bots). Returns true if a shot happened.
func perform_shot(ray_origin: Vector3, base_dir: Vector3) -> bool:
	var w := weapon()
	if not w.can_fire() or healing or not alive:
		return false
	w.on_fire()
	stats.shots += 1
	last_shot_time = _now()
	var d := w.def
	var spread := current_spread()
	var muzzle := model.muzzle_position()
	var total := 0.0
	var any_head := false
	var killed := false
	var hit_target: Fighter = null
	var last_pos := Vector3.ZERO
	var pellets := int(d.pellets)
	for i in pellets:
		var dir := Weapons.spread_dir(base_dir, spread, rng)
		var res := trace(ray_origin, dir, d.range)
		var end_pos: Vector3 = ray_origin + dir * float(d.range)
		if not res.is_empty():
			end_pos = res.position
			var to_end := end_pos - muzzle
			var md := to_end.length()
			if md > 0.3:
				var res2 := trace(muzzle, to_end / md, md - 0.12)
				if not res2.is_empty() and res2.collider != res.collider:
					res = res2
					end_pos = res2.position
		if i == 0 or i % 3 == 0:
			Effects.tracer(self, muzzle, end_pos)
		if res.is_empty():
			continue
		var col: Object = res.collider
		var normal: Vector3 = res.get("normal", Vector3.UP)
		if col is Area3D and col.has_meta("fighter"):
			var target: Fighter = col.get_meta("fighter")
			var zone: String = col.get_meta("zone")
			var dist := ray_origin.distance_to(end_pos)
			var dmg := Weapons.damage_at(d, float(d.damage) * Weapons.zone_mult(d, zone), dist)
			var dealt := target.take_damage(dmg, zone, self, global_position)
			Effects.hit_spark(self, end_pos, -dir, zone == "head")
			if dealt > 0.0:
				total += dealt
				hit_target = target
				last_pos = end_pos
				if zone == "head":
					any_head = true
				if not target.alive:
					killed = true
		elif col != null and col.has_method("take_bullet"):
			col.take_bullet(float(d.damage), self)
			Effects.shield_hit(self, end_pos, normal)
		else:
			Effects.impact(self, end_pos, normal)
	if hit_target != null:
		stats.hits += 1
		stats.damage += total
		if any_head:
			stats.headshots += 1
		if killed:
			stats.kills += 1
		hit_landed.emit(hit_target, total, any_head, last_pos, killed)
	model.on_fire()
	Effects.muzzle_flash(self, muzzle, aim_forward(), w.id == "sg")
	if is_player:
		Audio.play(String(d.sound), -1.0, rng.randf_range(0.96, 1.04))
	else:
		Audio.play_at(String(d.sound), muzzle, 2.0, rng.randf_range(0.95, 1.05), 120.0)
	fired.emit(w)
	if arena and arena.has_method("on_gunshot"):
		arena.on_gunshot(self)
	return true


func start_reload() -> bool:
	if healing or not alive:
		return false
	var w := weapon()
	if w.start_reload():
		Audio.play_at("reload_mag" if w.id != "sg" else "reload_shell", global_position, -4.0 if is_player else -8.0)
		return true
	return false


func _on_reload_done() -> void:
	if weapon().id == "sg":
		Audio.play_at("pump", global_position, -5.0)


func switch_weapon(index: int) -> void:
	if index == current or index < 0 or index >= weapons.size() or not alive:
		return
	weapon().cancel_reload()
	current = index
	var w := weapon()
	w.cooldown = maxf(w.cooldown, float(w.def.equip))
	model.equip_weapon(String(w.def.model))
	Audio.play_at("ui_select", global_position, -10.0)
	weapon_switched.emit()


# ---------------------------------------------------------------- items

func start_heal() -> bool:
	if healing or medkits <= 0 or hp >= MAX_HP or not alive:
		return false
	healing = true
	heal_left = HEAL_TIME
	ads = false
	weapon().cancel_reload()
	Audio.play_at("heal", global_position, -6.0)
	return true


func cancel_heal() -> void:
	healing = false


func _update_heal(delta: float) -> void:
	if not healing:
		return
	heal_left -= delta
	if heal_left <= 0.0:
		healing = false
		medkits -= 1
		hp = minf(MAX_HP, hp + HEAL_AMOUNT)
		Audio.play_at("heal_done", global_position, -4.0)


func heal_progress() -> float:
	return clampf(1.0 - heal_left / HEAL_TIME, 0.0, 1.0) if healing else 0.0


func deploy_shield(toward := Vector3.ZERO) -> bool:
	if shields <= 0 or not alive:
		return false
	var fwd := -global_basis.z if toward == Vector3.ZERO else toward
	fwd.y = 0.0
	if fwd.length() < 0.1:
		return false
	fwd = fwd.normalized()
	var dist := 2.0
	var res := trace(global_position + Vector3.UP * 1.0, fwd, dist + 0.6, LAYER_WORLD | LAYER_SHIELD)
	if not res.is_empty():
		dist = maxf(global_position.distance_to(res.position) - 0.7, 0.9)
	var wall := ShieldWall.new()
	wall.owner_fighter = self
	get_tree().current_scene.add_child(wall)
	var pos := global_position + fwd * dist
	wall.global_position = pos
	wall.look_at(pos + fwd, Vector3.UP)
	shields -= 1
	return true


func throw_grenade() -> bool:
	if grenades <= 0 or not alive or healing:
		return false
	grenades -= 1
	var g := Grenade.new()
	g.thrower = self
	get_tree().current_scene.add_child(g)
	var dir := aim_forward()
	g.global_position = eye_position() + dir * 0.6 + global_basis.x * 0.25
	g.linear_velocity = dir * 15.0 + Vector3.UP * 4.5 + Vector3(velocity.x, 0, velocity.z) * 0.5
	Audio.play_at("grenade_throw", global_position, -4.0)
	return true


func set_crouch(on: bool) -> void:
	if on == crouching:
		return
	if not on:
		var res := trace(global_position + Vector3.UP * 1.0, Vector3.UP, 0.9, LAYER_WORLD)
		if not res.is_empty():
			return
	crouching = on
	_capsule.height = CROUCH_HEIGHT if on else STAND_HEIGHT
	_collider.position.y = _capsule.height * 0.5


# ---------------------------------------------------------------- movement / tick

func _think(_delta: float) -> void:
	pass


func _physics_process(delta: float) -> void:
	if not alive:
		velocity.x = 0.0
		velocity.z = 0.0
		if not is_on_floor():
			velocity.y -= GRAVITY * delta
		move_and_slide()
		return
	if not frozen:
		_think(delta)
	else:
		move_dir = Vector2.ZERO
	var w := weapon()
	if w.tick(delta):
		_on_reload_done()
	_update_heal(delta)
	rotation.y = aim_yaw
	var speed := RUN_SPEED
	if crouching:
		speed = CROUCH_SPEED
	elif ads:
		speed = ADS_SPEED
	if healing:
		speed = minf(speed, HEAL_SPEED)
	var flat := Basis(Vector3.UP, aim_yaw)
	var wish := flat * Vector3(move_dir.x, 0.0, -move_dir.y)
	if wish.length() > 1.0:
		wish = wish.normalized()
	var target_v := wish * speed
	var on_floor := is_on_floor()
	var accel := 38.0 if on_floor else 9.0
	velocity.x = move_toward(velocity.x, target_v.x, accel * delta)
	velocity.z = move_toward(velocity.z, target_v.z, accel * delta)
	if on_floor:
		if want_jump and not crouching and not healing:
			velocity.y = JUMP_V
			Audio.play_at("jump", global_position, -9.0)
			model.on_jump()
	else:
		velocity.y -= GRAVITY * delta
	want_jump = false
	move_and_slide()
	var now_floor := is_on_floor()
	if _was_air and now_floor:
		Audio.play_at("land", global_position, -9.0)
	_was_air = not now_floor
	_footsteps(delta)
	var local_v := flat.inverse() * velocity
	model.update_locomotion(Vector2(local_v.x, -local_v.z) / RUN_SPEED, crouching, now_floor, delta)
	model.set_aim(aim_pitch, aim_forward())


func _process(_delta: float) -> void:
	_update_hitboxes()


func _footsteps(delta: float) -> void:
	if not is_on_floor():
		return
	var hs := Vector2(velocity.x, velocity.z).length()
	if hs < 1.4:
		_step_timer = 0.0
		return
	_step_timer += delta * (hs / RUN_SPEED)
	var interval := 0.34 if not crouching else 0.5
	if _step_timer >= interval:
		_step_timer = 0.0
		var vol := -12.0 if is_player else (-3.0 if not crouching else -14.0)
		Audio.play_at("footstep_%d" % (rng.randi() % 4 + 1), global_position, vol, rng.randf_range(0.9, 1.1), 40.0)
		if arena and arena.has_method("on_footstep") and not crouching:
			arena.on_footstep(self)

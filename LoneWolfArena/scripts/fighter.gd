class_name Fighter
extends CharacterBody3D
## Shared combat logic for the player and bots: health/armour, the round's gun + fists,
## items, hitboxes, stances (stand / crouch / prone), movement and animation hookup.
## Subclasses implement _think().

signal died(victim: Fighter, killer: Fighter, headshot: bool)
signal damaged(amount: float, from_pos: Vector3, headshot: bool, attacker: Fighter)
signal hit_landed(target: Fighter, amount: float, headshot: bool, pos: Vector3, killed: bool)
signal fired(w: WeaponState)
signal weapon_switched
signal stance_changed(stance: int)

enum Stance { STAND, CROUCH, PRONE }

const LAYER_WORLD := 1
const LAYER_BODY := 2
const LAYER_HITBOX := 4
const LAYER_SHIELD := 8
const MASK_SHOT := LAYER_WORLD | LAYER_HITBOX | LAYER_SHIELD
const MASK_SIGHT := LAYER_WORLD | LAYER_SHIELD

const MAX_HP := 200.0
const GRAVITY := 22.0
const JUMP_V := 7.6              # apex ~1.3 m: a 1.2 m crate can be jumped onto
const RUN_SPEED := 5.0
const SPRINT_SPEED := 6.0
const WALK_SPEED := 2.0
const CROUCH_SPEED := 1.75
const PRONE_SPEED := 0.75
const ADS_MULT := 0.7
const HEAL_MULT := 0.6
const HEAL_WINDUP := 1.0
const HEAL_RATE := 25.0          # HP/s after the wind-up
const HEAL_AMOUNT := 75.0
const HEAL_TIME := HEAL_WINDUP + HEAL_AMOUNT / HEAL_RATE
const FALL_SAFE := 4.0
const FALL_DMG_PER_M := 12.0
const EYE_HEIGHT := 1.6
const CROUCH_EYE := 1.12
const PRONE_EYE := 0.40
const STAND_HEIGHT := 1.8
const CROUCH_HEIGHT := 1.25
const PRONE_HEIGHT := 0.7
const STANCE_TIME := [0.0, 0.2, 0.45]
const MELEE_RANGE := 2.0
const THROW_RELEASE := 0.43      # s from the throw input to the grenade leaving the hand

var display_name := "PLAYER"
var is_player := false
var hp: float:
	get:
		return _hp.value()
	set(v):
		_hp.set_value(v)
var alive := true
var weapons: Array[WeaponState] = []
var current := 0
var stance := Stance.STAND
var crouching: bool:
	get:
		return stance == Stance.CROUCH
var prone: bool:
	get:
		return stance == Stance.PRONE
var sprinting := false
var ads := false
var medkits: int:
	get:
		return int(_medkits.value())
	set(v):
		_medkits.set_value(v)
var shields: int:
	get:
		return int(_shields.value())
	set(v):
		_shields.set_value(v)
var grenades: int:
	get:
		return int(_grenades.value())
	set(v):
		_grenades.set_value(v)
var healing := false
var heal_left := 0.0
var aim_yaw := 0.0
var aim_pitch := 0.0
var move_dir := Vector2.ZERO
var want_jump := false
var frozen := false
var round_over := false        # the result is decided: no more shots or damage (a grenade in the air)
var endless_hp := false        # practice: hits land and show their damage, HP never drops
var stats := {"shots": 0, "hits": 0, "headshots": 0, "damage": 0.0, "kills": 0, "taken": 0.0, "healed": 0.0}
var model: CharacterModel
var arena: Node
var hitboxes: Array[Area3D] = []
var rng := RandomNumberGenerator.new()
var bundle_id := "default"
var last_damage_time := -99.0
var last_attacked_time := -99.0   # last damage from the enemy (not the zone or a fall)
var last_shot_time := -99.0
var invulnerable := false
var stance_lock := 0.0           # s until the stance change finishes (can't fire meanwhile)
var hold_fire := false           # prep phase: may move, may not shoot or use items

# HP and item counts are kept masked in memory (see SecureNum / Guard).
var _hp := SecureNum.new(MAX_HP)
var _medkits := SecureNum.new(2)
var _shields := SecureNum.new(2)
var _grenades := SecureNum.new(1)
var _heal_t := 0.0
var _heal_used := false
var _throwing := false
var _throw_target := Vector3.INF
var _exclude: Array[RID] = []
var _collider: CollisionShape3D
var _heal_sound: AudioStreamPlayer3D
var _capsule: CapsuleShape3D
var _step_timer := 0.0
var _boxes := {}
var _was_air := false
var _peak_y := 0.0


func setup_fighter(bundle: String, weapon_id := Weapons.DEFAULT_PICK) -> void:
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
	set_loadout(weapon_id)
	_build_hitboxes()
	_exclude = [get_rid()]
	for hb in hitboxes:
		_exclude.append(hb.get_rid())


## The round's gun in slot 0 and fists in slot 1 (Lone Wolf: both players get the same gun).
func set_loadout(weapon_id: String) -> void:
	if not Weapons.DEFS.has(weapon_id):
		weapon_id = Weapons.DEFAULT_PICK
	weapons.clear()
	weapons.append(WeaponState.new(weapon_id))
	weapons.append(WeaponState.new("fists"))
	current = 0
	if model:
		model.equip_weapon(String(weapons[0].def.model), weapons[0].def.get("tint", Color.WHITE))
	weapon_switched.emit()


# ---------------------------------------------------------------- hitboxes

func _build_hitboxes() -> void:
	# zone, anchor roles (midpoint), radius
	var defs := [
		["head", "head", ["head"], 0.16],
		["neck", "body", ["neck", "head"], 0.1],          # closes the gap between the head and the chest
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
			p += model.head_up() * 0.07
		area.global_position = p


func head_position() -> Vector3:
	return (_boxes["head"][0] as Area3D).global_position


func chest_position() -> Vector3:
	return (_boxes["chest"][0] as Area3D).global_position


func eye_height() -> float:
	match stance:
		Stance.CROUCH:
			return CROUCH_EYE
		Stance.PRONE:
			return PRONE_EYE
	return EYE_HEIGHT


func eye_position() -> Vector3:
	return global_position + Vector3.UP * eye_height()


func aim_forward() -> Vector3:
	var b := Basis(Vector3.UP, aim_yaw) * Basis(Vector3.RIGHT, aim_pitch)
	return -b.z


func weapon() -> WeaponState:
	return weapons[current]


func gun() -> WeaponState:
	return weapons[0]


# ---------------------------------------------------------------- damage

func take_damage(amount: float, zone: String, attacker: Fighter, from_pos: Vector3) -> float:
	if not alive or round_over or (invulnerable and not OS.has_feature("template")):     # invulnerable: a test switch only
		return 0.0
	# Armour is read from the constants (a per-fighter value could be frozen in memory).
	var dmg := clampf(Weapons.after_armor(amount, zone, Weapons.VEST_REDUCTION, Weapons.HELMET_REDUCTION), 0.0, INF if endless_hp else hp)
	if endless_hp:
		stats.taken += dmg
		last_damage_time = _now()
		damaged.emit(dmg, from_pos, zone == "head", attacker)
		if attacker != null and dmg > 0.0:
			model.play_hit()
		return dmg
	hp -= dmg
	stats.taken += dmg
	last_damage_time = _now()
	if attacker != null:
		last_attacked_time = last_damage_time
	if healing and zone != "zone":
		cancel_heal()
	damaged.emit(dmg, from_pos, zone == "head", attacker)
	if hp <= 0.001:
		hp = 0.0
		die(attacker, zone == "head")
	elif attacker != null and dmg > 0.0:
		model.play_hit()
	return dmg


func die(killer: Fighter, headshot := false) -> void:
	if not alive:
		return
	alive = false
	healing = false
	_stop_heal_sound()
	ads = false
	sprinting = false
	velocity = Vector3(0, minf(velocity.y, 0.0), 0)
	# The body keeps resting on the floor (a disabled shape fell through it, and the death
	# camera with it); nothing collides with it any more.
	set_deferred("collision_layer", 0)
	set_deferred("collision_mask", LAYER_WORLD)
	for hb in hitboxes:
		hb.collision_layer = 0
	model.play_death()
	died.emit(self, killer, headshot)


## Back on its feet at a spawn for the next round: full HP and items, the round's gun with a full
## magazine, collisions on again. The stats carry over (they are the match's).
func reset_for_round(pos: Vector3, yaw: float) -> void:
	alive = true
	round_over = false
	cancel_heal()
	_stop_heal_sound()
	healing = false
	_throwing = false
	_throw_target = Vector3.INF
	hp = MAX_HP
	medkits = 2
	shields = 2
	grenades = 1
	ads = false
	sprinting = false
	move_dir = Vector2.ZERO
	want_jump = false
	velocity = Vector3.ZERO
	global_position = pos
	aim_yaw = yaw
	aim_pitch = 0.0
	set_stance(Stance.STAND, true)
	collision_layer = LAYER_BODY
	collision_mask = LAYER_WORLD | LAYER_BODY | LAYER_SHIELD
	for hb in hitboxes:
		hb.collision_layer = LAYER_HITBOX
	model.revive()
	set_loadout(weapons[0].id if not weapons.is_empty() else Weapons.DEFAULT_PICK)
	last_damage_time = -99.0
	last_attacked_time = -99.0


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


func horizontal_speed() -> float:
	return Vector2(velocity.x, velocity.z).length()


func current_spread() -> float:
	var w := weapon()
	var d := w.def
	var s: float = d.spread_ads if ads else d.spread_hip
	s += float(d.spread_move) * clampf(horizontal_speed() / RUN_SPEED, 0.0, 1.0)
	if not is_on_floor():
		s += float(d.spread_air)
	if crouching:
		s *= 0.75
	elif prone:
		s *= 0.6
	return s + w.bloom


func is_firing_recently() -> bool:
	return _now() - last_shot_time < 0.2


## Fires the current weapon along base_dir. ray_origin is where the hit-scan starts
## (camera-aligned for the player, eyes for bots). Returns true if a shot happened.
func perform_shot(ray_origin: Vector3, base_dir: Vector3) -> bool:
	var w := weapon()
	if not w.can_fire() or healing or not alive or stance_lock > 0.0 or hold_fire or round_over:
		return false
	if sprinting:
		sprinting = false
	if Weapons.is_melee(w.def):
		return _melee(w, base_dir)
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
		var res := trace(ray_origin, dir, d.range * 1.6)
		var end_pos: Vector3 = ray_origin + dir * float(d.range) * 1.6
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
			var dmg := Weapons.damage_at(d, float(d.damage), dist) * Weapons.zone_mult(d, zone, dist)
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
			col.take_bullet(Weapons.damage_at(d, float(d.damage), ray_origin.distance_to(end_pos)), self)
			Effects.shield_hit(self, end_pos, normal)
		else:
			Effects.impact(self, end_pos, normal)
	_after_shot(w, hit_target, total, any_head, last_pos, killed)
	model.on_fire()
	Effects.muzzle_flash(self, muzzle, aim_forward(), int(d.pellets) > 1)
	if is_player:
		Audio.play(String(d.sound), -1.0, rng.randf_range(0.96, 1.04))
	else:
		Audio.play_at(String(d.sound), muzzle, 2.0, rng.randf_range(0.95, 1.05), 120.0)
	if arena and arena.has_method("on_gunshot"):
		arena.on_gunshot(self)
	return true


func _after_shot(w: WeaponState, hit_target: Fighter, total: float, any_head: bool, last_pos: Vector3, killed: bool) -> void:
	if hit_target != null:
		stats.hits += 1
		stats.damage += total
		if any_head:
			stats.headshots += 1
		if killed:
			stats.kills += 1
		hit_landed.emit(hit_target, total, any_head, last_pos, killed)
	fired.emit(w)


func _melee(w: WeaponState, base_dir: Vector3) -> bool:
	w.on_fire()
	last_shot_time = _now()
	stats.shots += 1
	var origin := eye_position()
	var res := trace(origin, base_dir, MELEE_RANGE)
	var hit_target: Fighter = null
	var total := 0.0
	var head := false
	var killed := false
	var pos := origin + base_dir * MELEE_RANGE
	if not res.is_empty() and res.collider is Area3D and (res.collider as Area3D).has_meta("fighter"):
		hit_target = (res.collider as Area3D).get_meta("fighter")
		var zone: String = (res.collider as Area3D).get_meta("zone")
		head = zone == "head"
		pos = res.position
		total = hit_target.take_damage(float(w.def.damage) * Weapons.zone_mult(w.def, zone), zone, self, global_position)
		killed = not hit_target.alive
		Effects.hit_spark(self, pos, -base_dir, head)
	if total <= 0.0:
		hit_target = null
	model.on_punch()
	Audio.play_at("jump", global_position, -8.0, 1.5)
	_after_shot(w, hit_target, total, head, pos, killed)
	return true


func start_reload() -> bool:
	if healing or not alive:
		return false
	var w := weapon()
	if w.start_reload():
		Audio.play_at("reload_mag" if int(w.def.pellets) == 1 else "reload_shell", global_position, -4.0 if is_player else -8.0)
		model.play_reload(float(w.def.reload))
		return true
	return false


func _on_reload_done() -> void:
	if int(weapon().def.pellets) > 1:
		Audio.play_at("pump", global_position, -5.0)


func switch_weapon(index: int) -> void:
	if index == current or index < 0 or index >= weapons.size() or not alive:
		return
	weapon().cancel_reload()
	current = index
	var w := weapon()
	w.cooldown = maxf(w.cooldown, float(w.def.equip))
	model.play_swap(String(w.def.model), w.def.get("tint", Color.WHITE), float(w.def.equip))
	Audio.play_at("ui_select", global_position, -10.0)
	weapon_switched.emit()


# ---------------------------------------------------------------- items

func start_heal() -> bool:
	if healing or medkits <= 0 or hp >= MAX_HP or not alive:
		return false
	healing = true
	sprinting = false
	_heal_t = 0.0
	_heal_used = false
	heal_left = HEAL_TIME
	ads = false
	weapon().cancel_reload()
	model.play_heal(true)
	_heal_sound = Audio.play_at("heal", global_position, -6.0)
	return true


func cancel_heal() -> void:
	if healing:
		healing = false
		model.play_heal(false)
		_stop_heal_sound()


## The heal sound loops, so it never finishes on its own.
func _stop_heal_sound() -> void:
	if is_instance_valid(_heal_sound):
		_heal_sound.queue_free()
	_heal_sound = null


func _update_heal(delta: float) -> void:
	if not healing:
		return
	_heal_t += delta
	heal_left = maxf(HEAL_TIME - _heal_t, 0.0)
	if _heal_t >= HEAL_WINDUP:
		if not _heal_used:
			_heal_used = true
			medkits -= 1
		var add := minf(HEAL_RATE * delta, MAX_HP - hp)
		if add > 0.0:
			hp += add
			stats.healed += add
	if _heal_t >= HEAL_TIME or hp >= MAX_HP - 0.001:
		healing = false
		model.play_heal(false)
		_stop_heal_sound()
		Audio.play_at("heal_done", global_position, -4.0)


func heal_progress() -> float:
	return clampf(_heal_t / HEAL_TIME, 0.0, 1.0) if healing else 0.0


func deploy_shield(toward := Vector3.ZERO) -> bool:
	if shields <= 0 or not alive or hold_fire:
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
	get_tree().current_scene.add_child(wall)
	var pos := global_position + fwd * dist
	wall.global_position = pos
	wall.look_at(pos + fwd, Vector3.UP)
	shields -= 1
	if is_player and arena and arena.has_method("net_wall"):
		arena.net_wall(pos, fwd)
	return true


## Throws along the aim; with a target point (bots) the arc is solved to land there.
func throw_grenade(target := Vector3.INF) -> bool:
	if grenades <= 0 or not alive or healing or hold_fire or _throwing:
		return false
	grenades -= 1
	sprinting = false
	_throwing = true
	_throw_target = target
	model.play_throw()
	# The grenade leaves the hand at the release frame of the throw clip, aimed where the
	# thrower aims at that moment; a thrower killed during the wind-up drops nothing.
	get_tree().create_timer(THROW_RELEASE, false).timeout.connect(_release_grenade)
	return true


func _release_grenade() -> void:
	_throwing = false
	if not alive or not is_inside_tree():
		return
	var g := Grenade.new()
	g.thrower = self
	get_tree().current_scene.add_child(g)
	var dir := aim_forward()
	g.global_position = eye_position() + dir * 0.6 + global_basis.x * 0.25
	g.linear_velocity = dir * 17.0 + Vector3.UP * 4.0 + Vector3(velocity.x, 0, velocity.z) * 0.5
	if _throw_target != Vector3.INF:
		var to := _throw_target - g.global_position
		var flat := Vector2(to.x, to.z).length()
		var t := clampf(flat / 13.0, 0.5, 1.6)
		var grav := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)) * g.gravity_scale
		g.linear_velocity = (to / t + Vector3.UP * 0.5 * grav * t).limit_length(22.0)
	Audio.play_at("grenade_throw", global_position, -4.0)
	if is_player and arena and arena.has_method("net_grenade"):
		arena.net_grenade(g.global_position, g.linear_velocity)


# ---------------------------------------------------------------- stances

func set_stance(s: Stance, instant := false) -> bool:
	if s == stance:
		return true
	if not alive:
		return false
	# Standing/crouching up needs head room.
	var h := _stance_height(s)
	if h > _capsule.height:
		var res := trace(global_position + Vector3.UP * (_capsule.height - 0.1), Vector3.UP, h - _capsule.height + 0.15, LAYER_WORLD)
		if not res.is_empty():
			return false
	stance = s
	sprinting = sprinting and s == Stance.STAND
	_capsule.radius = 0.32 if s == Stance.PRONE else 0.36
	_capsule.height = h
	_collider.position.y = h * 0.5
	stance_lock = 0.0 if instant else float(STANCE_TIME[s])
	stance_changed.emit(s)
	return true


func _stance_height(s: int) -> float:
	match s:
		Stance.CROUCH:
			return CROUCH_HEIGHT
		Stance.PRONE:
			return PRONE_HEIGHT
	return STAND_HEIGHT


## Crouch on/off (the bot's cover logic).
func set_crouch(on: bool) -> void:
	set_stance(Stance.CROUCH if on else Stance.STAND)


# ---------------------------------------------------------------- movement / tick

func _think(_delta: float) -> void:
	pass


func move_speed() -> float:
	var deflect := clampf(move_dir.length(), 0.0, 1.0)
	var speed := RUN_SPEED
	match stance:
		Stance.CROUCH:
			speed = CROUCH_SPEED
		Stance.PRONE:
			speed = PRONE_SPEED
		_:
			if sprinting and move_dir.y > 0.3:
				speed = SPRINT_SPEED
			elif deflect < 0.6:
				speed = WALK_SPEED * deflect / 0.6
	var d := weapon().def
	speed *= float(d.get("move", 1.0))
	if ads:
		speed *= ADS_MULT
	if is_firing_recently():
		speed *= float(d.get("fire_move", 0.85))
	if healing:
		speed *= HEAL_MULT
	return speed


func _physics_process(delta: float) -> void:
	if not alive:
		velocity.x = 0.0
		velocity.z = 0.0
		if not is_on_floor():
			velocity.y -= GRAVITY * delta
		move_and_slide()
		return
	stance_lock = maxf(stance_lock - delta, 0.0)
	if not frozen:
		_think(delta)
	else:
		move_dir = Vector2.ZERO
	var w := weapon()
	if w.tick(delta):
		_on_reload_done()
	_update_heal(delta)
	rotation.y = aim_yaw
	var flat := Basis(Vector3.UP, aim_yaw)
	var dir2 := move_dir.limit_length(1.0)
	var wish := flat * Vector3(dir2.x, 0.0, -dir2.y)
	if wish.length() > 0.001:
		wish = wish.normalized()
	if sprinting and (dir2.length() < 0.3 or dir2.y < 0.3 or stance != Stance.STAND or ads or healing):
		sprinting = false
	var target_v := wish * (move_speed() if dir2.length() > 0.08 else 0.0)
	var on_floor := is_on_floor()
	var accel := 38.0 if on_floor else 9.0
	velocity.x = move_toward(velocity.x, target_v.x, accel * delta)
	velocity.z = move_toward(velocity.z, target_v.z, accel * delta)
	if on_floor:
		if want_jump and not healing:
			if stance != Stance.STAND:
				set_stance(Stance.STAND)
			else:
				velocity.y = JUMP_V
				_peak_y = global_position.y
				Audio.play_at("jump", global_position, -9.0)
				model.on_jump()
	else:
		velocity.y -= GRAVITY * delta
		_peak_y = maxf(_peak_y, global_position.y)
	want_jump = false
	move_and_slide()
	var now_floor := is_on_floor()
	if _was_air and now_floor:
		_land()
	if now_floor:
		_peak_y = global_position.y
	_was_air = not now_floor
	_footsteps(delta)
	var local_v := flat.inverse() * velocity
	model.update_locomotion(Vector2(local_v.x, -local_v.z), stance, now_floor, delta)
	model.set_aim(aim_pitch, aim_forward())


func _land() -> void:
	var drop := _peak_y - global_position.y
	Audio.play_at("land", global_position, -9.0)
	if drop > FALL_SAFE:
		take_damage((drop - FALL_SAFE) * FALL_DMG_PER_M, "fall", null, global_position)


func _process(_delta: float) -> void:
	_update_hitboxes()


func _footsteps(delta: float) -> void:
	if not is_on_floor():
		return
	var hs := horizontal_speed()
	if hs < 1.4:
		_step_timer = 0.0
		return
	_step_timer += delta * (hs / RUN_SPEED)
	var interval := 0.34 if stance == Stance.STAND else 0.5
	if _step_timer >= interval:
		_step_timer = 0.0
		var quiet := stance != Stance.STAND or hs < WALK_SPEED + 0.3
		var vol := -12.0 if is_player else (-3.0 if not quiet else -14.0)
		Audio.play_at("footstep_%d" % (rng.randi() % 4 + 1), global_position, vol, rng.randf_range(0.9, 1.1), 40.0)
		if arena and arena.has_method("on_footstep") and not quiet:
			arena.on_footstep(self)

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
## DUO / SQUAD (TeamArena, PLAN_TEAMS): a fighter whose HP runs out while a teammate still stands is
## knocked down (on the floor, crawling at KNOCK_SPEED, no gun or items) with KNOCK_HP that runs out
## over BLEED_S, until a teammate revives it (REVIVE_S next to it, within REVIVE_RANGE: back up with
## REVIVE_HP) or it is finished. TeamReferee decides; team -1 (the 1 vs 1) never knocks.
@warning_ignore("unused_signal")
signal knocked_down(victim: Fighter, killer: Fighter, headshot: bool)
@warning_ignore("unused_signal")
signal revived(victim: Fighter, by: Fighter)
## Team modes: a KNOCKED fighter's knock HP ran out (finished off by a hit or the zone, or bled out:
## killer null, last_hit_cause "bleed"). It stays down until the referee's word (TeamArena).
signal knock_finished(victim: Fighter, killer: Fighter, headshot: bool)

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
## Base speeds (m/s) with a rifle in hand, what the M4A1 always ran at; Weapons.CLASS_MOVE scales
## them per weapon class (fists 1.15 x, an SMG a little faster, the heavy guns slower).
const RUN_SPEED := 4.6
const SPRINT_SPEED := 5.5
const WALK_SPEED := 1.85
const CROUCH_SPEED := 1.6
const PRONE_SPEED := 0.7
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
const START_MEDKITS := 2         # the items every round starts with
const START_SHIELDS := 3
const START_GRENADES := 1
const KNOCK_HP := 100.0
const BLEED_S := 30.0
const KNOCK_SPEED := 0.8
const REVIVE_S := 5.0
const REVIVE_HP := 50.0
const REVIVE_RANGE := 2.0

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
var stats := {"shots": 0, "hits": 0, "headshots": 0, "damage": 0.0, "kills": 0, "taken": 0.0, "healed": 0.0,
	"knocks": 0, "revives": 0}
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
var last_hit_cause := ""         # the last damage's cause when not a gun ("frag": see take_damage)
var team := -1                   # DUO / SQUAD: 0 or 1 (-1: no teams, the 1 vs 1)
var slot := -1                   # DUO / SQUAD: the roster slot (Game.team_match)
var knocked := false             # down on the floor, waiting for a revive (team modes only)
var knock_hp := 0.0              # what is left of KNOCK_HP while knocked
var knocked_by: Fighter          # who knocked it (the kill goes to them when nobody finishes it)
var reviving: Fighter            # the knocked teammate this fighter is reviving (null: none)
var revive_t := 0.0              # s of that revive done so far
## Run on this phone in an online team match (the player; on the host also the bots): its hits on a
## fighter the other phone runs (RemoteFighter) are sent there, and its shots, frags and walls go
## through arena.net_shot_by / net_grenade_by / net_wall_by (TeamArena) instead of the 1 vs 1 calls.
var net_local := false
var revived_by: Fighter          # the teammate reviving this knocked fighter now (null: nobody; it bleeds)
var last_attacker: Fighter       # the last enemy whose damage landed (bots in teams turn to it)

# HP and item counts are kept masked in memory (see SecureNum / Guard).
var _hp := SecureNum.new(MAX_HP)
var _medkits := SecureNum.new(START_MEDKITS)
var _shields := SecureNum.new(START_SHIELDS)
var _grenades := SecureNum.new(START_GRENADES)
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

## Hit zones that follow the skeleton: a sphere on the head and capsules along the bones
## (torso, shoulders, hips, arms with the hands, legs with the feet), so a shot that lands on any
## visible part of the body counts (spheres left gaps at the shoulders, hips, knees and limbs).
## Zones: "head", "body" (the arms too) and "limb" (legs and feet, less damage).
## Entry: zone, end A, end B ("" = a sphere at A), radius, extension past B (m).
const HEAD_RADIUS := 0.15            # the head's hit zone, a sphere (the aim's head band too)
const HITBOX_DEFS := {
	"head": ["head", "head", "", HEAD_RADIUS, 0.0],
	"neck": ["body", "neck", "head", 0.075, 0.0],
	"chest": ["body", "spine2", "spine3", 0.18, 0.0],
	"belly": ["body", "spine1", "pelvis", 0.165, 0.0],
	"shoulders": ["body", "upperarm_l", "upperarm_r", 0.085, 0.0],
	"hips": ["body", "thigh_l", "thigh_r", 0.12, 0.0],
	"upperarm_l": ["body", "upperarm_l", "lowerarm_l", 0.062, 0.0],
	"upperarm_r": ["body", "upperarm_r", "lowerarm_r", 0.062, 0.0],
	"forearm_l": ["body", "lowerarm_l", "hand_l", 0.052, 0.09],
	"forearm_r": ["body", "lowerarm_r", "hand_r", 0.052, 0.09],
	"thigh_l": ["limb", "thigh_l", "calf_l", 0.088, 0.0],
	"thigh_r": ["limb", "thigh_r", "calf_r", 0.088, 0.0],
	"calf_l": ["limb", "calf_l", "foot_l", 0.066, 0.0],
	"calf_r": ["limb", "calf_r", "foot_r", 0.066, 0.0],
	"foot_l": ["limb", "foot_l", "ball_l", 0.055, 0.06],
	"foot_r": ["limb", "foot_r", "ball_r", 0.055, 0.06],
}


func _build_hitboxes() -> void:
	for key: String in HITBOX_DEFS:
		var d: Array = HITBOX_DEFS[key]
		var area := Area3D.new()
		area.name = "HB_" + key
		area.collision_layer = LAYER_HITBOX
		area.collision_mask = 0
		area.monitoring = false
		area.monitorable = true
		area.top_level = true
		var cs := CollisionShape3D.new()
		if String(d[2]) == "":
			var sph := SphereShape3D.new()
			sph.radius = d[3]
			cs.shape = sph
		else:
			# bone lengths are constant: the capsule is sized once from the current pose
			var cap := CapsuleShape3D.new()
			cap.radius = d[3]
			var length := model.bone_position(String(d[1])).distance_to(model.bone_position(String(d[2]))) + float(d[4])
			cap.height = length + 2.0 * float(d[3])
			cs.shape = cap
		area.add_child(cs)
		area.set_meta("fighter", self)
		area.set_meta("zone", d[0])
		add_child(area)
		hitboxes.append(area)
		_boxes[key] = area
	_update_hitboxes()


func _update_hitboxes() -> void:
	for key: String in _boxes:
		var d: Array = HITBOX_DEFS[key]
		var area: Area3D = _boxes[key]
		var a := model.bone_position(String(d[1]))
		if String(d[2]) == "":
			area.global_position = a + (model.head_up() * 0.07 if key == "head" else Vector3.ZERO)
			continue
		var b := model.bone_position(String(d[2]))
		var axis := b - a
		var length := axis.length()
		if length < 0.001:
			area.global_position = a
			continue
		axis /= length
		b += axis * float(d[4])
		# capsules run along local Y
		var side := axis.cross(Vector3.FORWARD if absf(axis.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
		area.global_transform = Transform3D(Basis(side, axis, side.cross(axis)), (a + b) * 0.5)


## The fighter a hit zone belongs to (null for anything else).
static func owner_of(o: Object) -> Fighter:
	return o.get_meta("fighter") as Fighter if o is Area3D and o.has_meta("fighter") else null


func head_position() -> Vector3:
	return (_boxes["head"] as Area3D).global_position


func chest_position() -> Vector3:
	return (_boxes["chest"] as Area3D).global_position


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

## cause: what dealt it when it was not the attacker's gun ("frag"); the kill feed names it.
## Returns the HP it really took (what the damage numbers, the stats and the results count): a hit
## after armour in whole points (hit_points), never more than the HP that was left.
func take_damage(amount: float, zone: String, attacker: Fighter, from_pos: Vector3, cause := "") -> float:
	if not alive or round_over or (invulnerable and not OS.has_feature("template")):     # invulnerable: a test switch only
		return 0.0
	if attacker != null and ally_of(attacker):
		return 0.0                       # friendly fire is off (a fighter's own frag still hurts it)
	if knocked:
		return _take_knock_damage(amount, zone, attacker, from_pos, cause)
	last_hit_cause = cause
	var dmg := clampf(hit_points(amount, zone), 0.0, INF if endless_hp else hp)
	if endless_hp:
		stats.taken += dmg
		last_damage_time = _now()
		damaged.emit(dmg, from_pos, zone == "head", attacker)
		if attacker != null and dmg > 0.0 and model:
			model.play_hit()
		return dmg
	hp -= dmg
	stats.taken += dmg
	last_damage_time = _now()
	if attacker != null:
		last_attacked_time = last_damage_time
		if attacker != self:
			last_attacker = attacker
	if healing and zone != "zone":
		cancel_heal()
	damaged.emit(dmg, from_pos, zone == "head", attacker)
	if hp <= 0.001:
		hp = 0.0
		if team >= 0:
			knock(attacker, zone == "head")       # team modes: down first, the referee decides (TeamArena)
		else:
			die(attacker, zone == "head")
	elif attacker != null and dmg > 0.0 and model:
		model.play_hit()
	return dmg


## A hit on a KNOCKED fighter takes its knock HP; at 0 it is finished (knock_finished), and stays
## down until the referee's word.
func _take_knock_damage(amount: float, zone: String, attacker: Fighter, from_pos: Vector3, cause: String) -> float:
	if knock_hp <= 0.0:
		return 0.0
	last_hit_cause = cause
	var dmg := clampf(hit_points(amount, zone), 0.0, knock_hp)
	knock_hp -= dmg
	stats.taken += dmg
	last_damage_time = _now()
	damaged.emit(dmg, from_pos, zone == "head", attacker)
	if knock_hp <= 0.001:
		knock_hp = 0.0
		knock_finished.emit(self, attacker, zone == "head")
	return dmg


## Team modes: HP gone, down on the floor (prone, crawling at KNOCK_SPEED, no gun, items, jump or
## stance change) with KNOCK_HP that bleeds out over BLEED_S unless a teammate revives it.
## knocked_down tells the arena (which reports it to the referee). Also applied to the other phone's
## fighters by the referee's "ko" (TeamArena._apply_decision).
func knock(by: Fighter, headshot := false) -> void:
	if knocked or not alive:
		return
	hp = 0.0
	cancel_heal()
	ads = false
	sprinting = false
	want_jump = false
	_throwing = false
	if not weapons.is_empty():
		weapon().cancel_reload()
	if _capsule != null:
		set_stance(Stance.PRONE, true)
	else:
		stance = Stance.PRONE
	knocked = true
	knock_hp = KNOCK_HP
	knocked_by = by if by != self else null
	_stop_reviving()
	revived_by = null
	knocked_down.emit(self, by, headshot)


## Stops the revive this fighter was doing (knocked, out): the teammate bleeds again.
func _stop_reviving() -> void:
	if reviving != null and is_instance_valid(reviving) and reviving.revived_by == self:
		reviving.revived_by = null
	if reviving != null and model and not healing:
		model.play_heal(false)
	reviving = null
	revive_t = 0.0


## Revived: up again with `with_hp` HP (Fighter.REVIVE_HP), crouched (a stand needs head room).
func stand_up(with_hp: float, by: Fighter) -> void:
	if not knocked or not alive:
		return
	knocked = false
	knock_hp = 0.0
	knocked_by = null
	revived_by = null
	hp = clampf(with_hp, 1.0, MAX_HP)
	last_hit_cause = ""
	if _capsule != null and not set_stance(Stance.STAND, true):
		set_stance(Stance.CROUCH, true)
	revived.emit(self, by)


## Team modes: bullets and sight lines pass through these (teammates).
func ignore_fighters(others: Array) -> void:
	for o: Fighter in others:
		if o == null or o == self:
			continue
		for rid: RID in [o.get_rid()] + o.hitboxes.map(func(hb: Area3D) -> RID: return hb.get_rid()):
			if not rid in _exclude:
				_exclude.append(rid)


## What a hit of `amount` (before armour) takes in this zone: after the armour (armor_mult), and a
## bullet, pellet, punch or frag in whole points, so the numbers shown add up to the HP lost (the
## zone and falls keep their fractions: they hurt a little every frame).
func hit_points(amount: float, zone: String) -> float:
	var dmg := amount * armor_mult(zone)
	return dmg if zone == "zone" or zone == "fall" else roundf(dmg)


## The share of a hit's damage that gets through this fighter's armour in a zone. Lone Wolf gives
## both fighters level 2 helmet and vest every round; read from the constants (a per-fighter value
## could be frozen in memory). Tests override it for a fighter without armour.
func armor_mult(zone: String) -> float:
	return Weapons.after_armor(1.0, zone, Weapons.VEST_REDUCTION, Weapons.HELMET_REDUCTION)


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
	knocked = false
	knock_hp = 0.0
	_stop_reviving()
	revived_by = null
	if model:
		model.play_death()
	died.emit(self, killer, headshot)


## Back on its feet at a spawn for the next round: full HP and items, the round's gun with a full
## magazine, collisions on again. The stats carry over (they are the match's).
func reset_for_round(pos: Vector3, yaw: float) -> void:
	alive = true
	round_over = false
	knocked = false                  # (before the stance: a knocked fighter may not change it)
	knock_hp = 0.0
	knocked_by = null
	_stop_reviving()
	revived_by = null
	last_attacker = null
	cancel_heal()
	_stop_heal_sound()
	healing = false
	_throwing = false
	_throw_target = Vector3.INF
	hp = MAX_HP
	medkits = START_MEDKITS
	shields = START_SHIELDS
	grenades = START_GRENADES
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


## On the same team (team modes only; never itself).
func ally_of(other: Fighter) -> bool:
	return team >= 0 and other != null and other != self and other.team == team


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
	if not w.can_fire() or healing or not alive or stance_lock > 0.0 or hold_fire or round_over or knocked or reviving != null:
		return false
	if sprinting:
		sprinting = false
	if Weapons.is_melee(w.def):
		return _melee(w, base_dir)
	var spread := current_spread()      # before this shot's own bloom: a first shot goes true
	w.on_fire()
	stats.shots += 1
	last_shot_time = _now()
	var d := w.def
	var muzzle := model.muzzle_position()
	var tally := new_tally()
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
				# Cover between the gun and that point stops the shot; the target's own other hit
				# zones don't (the gun sits lower than the crosshair: a head on the crosshair is hit).
				var res2 := trace(muzzle, to_end / md, md - 0.12)
				if not res2.is_empty() and res2.collider != res.collider \
						and (owner_of(res2.collider) == null or owner_of(res2.collider) != owner_of(res.collider)):
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
			var dmg := Weapons.damage_at(d, float(d.damage), dist) * Weapons.zone_mult(d, zone, dist) * Weapons.pen_mult(d, zone)
			land(tally, target, zone, dmg, end_pos)
			Effects.hit_spark(self, end_pos, -dir, zone == "head")
		elif col != null and col.has_method("take_bullet"):
			col.take_bullet(Weapons.damage_at(d, float(d.damage), ray_origin.distance_to(end_pos)), self)
			Effects.shield_hit(self, end_pos, normal)
		else:
			Effects.impact(self, end_pos, normal)
	_after_shot(w, tally)
	model.on_fire()
	Effects.muzzle_flash(self, muzzle, aim_forward(), int(d.pellets) > 1)
	var pitch := float(d.get("pitch", 1.0))
	if is_player:
		Audio.play(String(d.sound), -1.0, pitch * rng.randf_range(0.96, 1.04))
	else:
		Audio.play_at(String(d.sound), muzzle, 2.0, pitch * rng.randf_range(0.95, 1.05), 120.0)
	if arena and arena.has_method("on_gunshot"):
		arena.on_gunshot(self)
	return true


## One shot's (or punch's) damage so far: what its pellets took from the fighter they hit, the body
## part (arms and legs too) and the head part apart, where each part last landed, and whether the
## shot killed.
static func new_tally() -> Dictionary:
	return {"target": null, "body": 0.0, "head": 0.0, "body_pos": Vector3.ZERO, "head_pos": Vector3.ZERO, "killed": false}


## A pellet (bullet, punch) that met `target`: `amount` is its damage before armour; the tally gets
## what the target's HP really lost (take_damage). Returns that.
func land(tally: Dictionary, target: Fighter, zone: String, amount: float, pos: Vector3) -> float:
	var dealt := target.take_damage(amount, zone, self, global_position)
	if dealt > 0.0:
		var part := "head" if zone == "head" else "body"
		tally.target = target
		tally[part] = float(tally[part]) + dealt
		tally[part + "_pos"] = pos
		if not target.alive:
			tally.killed = true
	return dealt


## A shot's hits as [target, zone, damage before armour, point] (the screen-free path of a shot:
## the unit tests' way to land exactly these hits).
func land_hits(hits: Array) -> void:
	var tally := new_tally()
	for h: Array in hits:
		land(tally, h[0], String(h[1]), float(h[2]), h[3])
	_after_shot(weapon(), tally)


## Counts a shot and reports what it took: hit_landed once for its head part (shown orange-red,
## the headshot marker) and once for its body part, each the HP really lost, so a shotgun shell
## with one pellet on the head shows that pellet as the headshot and the rest as a body hit; the
## kill goes with the last report.
func _after_shot(w: WeaponState, tally: Dictionary) -> void:
	var target: Fighter = tally.target
	if target != null:
		var body := float(tally.body)
		var head := float(tally.head)
		var killed := bool(tally.killed)
		stats.hits += 1
		stats.damage += body + head
		if head > 0.0:
			stats.headshots += 1
		if killed and team < 0:
			stats.kills += 1             # (team modes: TeamArena counts the referee's eliminations)
		if head > 0.0:
			hit_landed.emit(target, head, true, tally.head_pos, killed and body <= 0.0)
		if body > 0.0:
			hit_landed.emit(target, body, false, tally.body_pos, killed)
	fired.emit(w)


func _melee(w: WeaponState, base_dir: Vector3) -> bool:
	w.on_fire()
	last_shot_time = _now()
	stats.shots += 1
	var origin := eye_position()
	var res := trace(origin, base_dir, MELEE_RANGE)
	var tally := new_tally()
	if not res.is_empty() and res.collider is Area3D and (res.collider as Area3D).has_meta("fighter"):
		var hit_target: Fighter = (res.collider as Area3D).get_meta("fighter")
		var zone: String = (res.collider as Area3D).get_meta("zone")
		var pos: Vector3 = res.position
		land(tally, hit_target, zone, float(w.def.damage) * Weapons.zone_mult(w.def, zone) * Weapons.pen_mult(w.def, zone), pos)
		Effects.hit_spark(self, pos, -base_dir, zone == "head")
	model.on_punch()
	Audio.play_at("jump", global_position, -8.0, 1.5)
	_after_shot(w, tally)
	return true


func start_reload() -> bool:
	if healing or not alive or knocked:
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
	if index == current or index < 0 or index >= weapons.size() or not alive or knocked:
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
	if healing or medkits <= 0 or hp >= MAX_HP or not alive or knocked or reviving != null:
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


## Where a wall put down toward `toward` (flattened; default ahead) stands: [position, facing],
## `dist` m ahead or nearer when something is in the way; empty without a direction.
func shield_spot(toward := Vector3.ZERO, dist := 2.0) -> Array:
	var fwd := -global_basis.z if toward == Vector3.ZERO else toward
	fwd.y = 0.0
	if fwd.length() < 0.1:
		return []
	fwd = fwd.normalized()
	var res := trace(global_position + Vector3.UP * 1.0, fwd, dist + 0.6, LAYER_WORLD | LAYER_SHIELD)
	if not res.is_empty():
		var hit: Vector3 = res.position - global_position
		hit.y = 0.0
		dist = clampf(hit.length() - 0.7, 0.9, dist)
	return [global_position + fwd * dist, fwd]


func deploy_shield(toward := Vector3.ZERO, dist := 2.0) -> bool:
	if shields <= 0 or not alive or hold_fire or knocked or reviving != null:
		return false
	var spot := shield_spot(toward, dist)
	if spot.is_empty():
		return false
	var pos: Vector3 = spot[0]
	var fwd: Vector3 = spot[1]
	var wall := ShieldWall.new()
	get_tree().current_scene.add_child(wall)
	wall.global_position = pos
	wall.look_at(pos + fwd, Vector3.UP)
	shields -= 1
	if net_local and arena and arena.has_method("net_wall_by"):
		arena.net_wall_by(self, pos, fwd)
	elif is_player and arena and arena.has_method("net_wall"):
		arena.net_wall(pos, fwd)
	return true


## Throws along the aim; with a target point (bots) the arc is solved to land there.
func throw_grenade(target := Vector3.INF) -> bool:
	if grenades <= 0 or not alive or healing or hold_fire or _throwing or knocked or reviving != null:
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


## Where a grenade thrown along the aim now would leave the hand, and how fast: [position, velocity].
func grenade_launch() -> Array:
	var dir := aim_forward()
	return [eye_position() + dir * 0.6 + global_basis.x * 0.25,
		dir * 17.0 + Vector3.UP * 4.0 + Vector3(velocity.x, 0, velocity.z) * 0.5]


func _release_grenade() -> void:
	_throwing = false
	if not alive or knocked or not is_inside_tree():
		return
	var g := Grenade.new()
	g.thrower = self
	get_tree().current_scene.add_child(g)
	var launch := grenade_launch()
	g.global_position = launch[0]
	g.linear_velocity = launch[1]
	if _throw_target != Vector3.INF:
		var to := _throw_target - g.global_position
		var flat := Vector2(to.x, to.z).length()
		var t := clampf(flat / 13.0, 0.5, 1.6)
		var grav := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)) * g.gravity_scale
		g.linear_velocity = (to / t + Vector3.UP * 0.5 * grav * t).limit_length(22.0)
	Audio.play_at("grenade_throw", global_position, -4.0)
	if net_local and arena and arena.has_method("net_grenade_by"):
		arena.net_grenade_by(self, g.global_position, g.linear_velocity)
	elif is_player and arena and arena.has_method("net_grenade"):
		arena.net_grenade(g.global_position, g.linear_velocity)


# ---------------------------------------------------------------- stances

func set_stance(s: Stance, instant := false) -> bool:
	if s == stance:
		return true
	if not alive or knocked:
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
	if knocked:
		return KNOCK_SPEED               # crawling, whatever the gun
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
			elif deflect < 0.45:
				speed = WALK_SPEED * deflect / 0.45      # a light push walks, a normal push runs
	var d := weapon().def
	speed *= Weapons.move_mult(d)
	if ads:
		speed *= ADS_MULT
	if is_firing_recently():
		speed *= float(d.get("fire_move", 0.85))
	if healing:
		speed *= HEAL_MULT
	if reviving != null:
		speed = 0.0                      # a revive is done standing still (moving cancels it)
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
	if knocked and not frozen and revived_by == null and knock_hp > 0.0:
		# Bleeding out: KNOCK_HP over BLEED_S while nobody revives it.
		knock_hp = maxf(knock_hp - KNOCK_HP / BLEED_S * delta, 0.0)
		if knock_hp <= 0.0:
			last_hit_cause = "bleed"
			knock_finished.emit(self, null, false)
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
		if want_jump and not healing and not knocked:
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
	_footsteps(delta, now_floor)
	var local_v := flat.inverse() * velocity
	model.update_locomotion(Vector2(local_v.x, -local_v.z), stance, now_floor, delta)
	model.set_aim(aim_pitch, aim_forward())


func _land() -> void:
	var drop := _peak_y - global_position.y
	Audio.play_at("land", global_position, -9.0)
	if drop > FALL_SAFE:
		take_damage((drop - FALL_SAFE) * FALL_DMG_PER_M, "fall", null, global_position, "fall")


func _process(_delta: float) -> void:
	_update_hitboxes()


## Step sounds (and, for anyone but this phone's player, the minimap's footprints) at the pace of
## the horizontal speed; on_floor: the fighter stands on something (an online opponent's comes
## with its state, it never runs move_and_slide here).
func _footsteps(delta: float, on_floor: bool) -> void:
	if not on_floor:
		return
	var hs := horizontal_speed()
	if hs < 1.4:
		_step_timer = 0.0
		return
	_step_timer += delta * (hs / RUN_SPEED)
	var interval := 0.3 if stance == Stance.STAND else 0.5      # half a run cycle (runx_*) at RUN_SPEED
	if _step_timer >= interval:
		_step_timer = 0.0
		var quiet := stance != Stance.STAND or hs < WALK_SPEED + 0.3
		# Someone else's run is loud and carries (it gives them away); a walk or a crouch only
		# close by. Your own steps stay soft.
		var vol := -12.0 if is_player else (1.0 if not quiet else -11.0)
		var reach := 40.0 if is_player else (48.0 if not quiet else 16.0)
		Audio.play_at("footstep_%d" % (rng.randi() % 4 + 1), global_position, vol, rng.randf_range(0.9, 1.1), reach)
		if arena and arena.has_method("on_footstep") and not quiet:
			arena.on_footstep(self)

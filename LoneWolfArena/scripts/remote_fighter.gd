class_name RemoteFighter
extends Bot
## The other phone's player in a Wi-Fi match (stands in for the bot, so the arena, HUD and
## results treat it the same). It has no AI: it follows the state that phone sends 20 times a
## second (smoothed), shows its shots, and never loses HP by itself: hits on it are sent to its
## phone, which applies them and reports its HP and its death back.

const STATE_SIZE := 10

var _net_pos := Vector3.INF
var _net_yaw := 0.0
var _net_pitch := 0.0
var _net_floor := true
var _net_heal := false


## [x, y, z, yaw, pitch, stance, flags, weapon index, hp, round]; flags: 1 sprint, 2 ads,
## 4 healing, 8 on the floor.
static func pack(f: Fighter, round_index := 1) -> PackedFloat32Array:
	var flags := (1 if f.sprinting else 0) | (2 if f.ads else 0) | (4 if f.healing else 0) | (8 if f.is_on_floor() else 0)
	var at := f.global_position
	return PackedFloat32Array([at.x, at.y, at.z, f.aim_yaw, f.aim_pitch, float(f.stance), float(flags), float(f.current), f.hp, float(round_index)])


func reset_for_round(pos: Vector3, yaw: float) -> void:
	super(pos, yaw)
	_net_pos = pos
	_net_yaw = yaw
	_net_pitch = 0.0
	_net_heal = false


func apply_state(s: PackedFloat32Array) -> void:
	if not alive:
		return
	var pos := Vector3(s[0], s[1], s[2])
	if not (is_finite(pos.x) and is_finite(pos.y) and is_finite(pos.z)) or pos.length() > 500.0:
		return
	_net_pos = pos
	_net_yaw = s[3]
	_net_pitch = clampf(s[4], -1.5, 1.5)
	var st := clampi(int(s[5]), 0, 2)
	if st != int(stance):
		set_stance(st as Fighter.Stance, true)
	var flags := int(s[6])
	sprinting = (flags & 1) != 0
	ads = (flags & 2) != 0
	_net_floor = (flags & 8) != 0
	var heal := (flags & 4) != 0
	if heal != _net_heal:
		_net_heal = heal
		model.play_heal(heal)
	var wi := clampi(int(s[7]), 0, weapons.size() - 1)
	if wi != current:
		switch_weapon(wi)
	hp = clampf(s[8], 0.0, MAX_HP)


func _physics_process(delta: float) -> void:
	if not alive:
		return
	if _net_pos == Vector3.INF:
		_net_pos = global_position
		_net_yaw = aim_yaw
	var prev := global_position
	if global_position.distance_to(_net_pos) > 4.0:
		global_position = _net_pos          # too far behind (a hitch): jump
	else:
		global_position = global_position.lerp(_net_pos, 1.0 - exp(-14.0 * delta))
	velocity = (global_position - prev) / maxf(delta, 0.0001)
	aim_yaw = lerp_angle(aim_yaw, _net_yaw, 1.0 - exp(-18.0 * delta))
	aim_pitch = lerpf(aim_pitch, _net_pitch, 1.0 - exp(-18.0 * delta))
	rotation.y = aim_yaw
	var w := weapon()
	w.tick(delta)
	var local_v := Basis(Vector3.UP, aim_yaw).inverse() * velocity
	model.update_locomotion(Vector2(local_v.x, -local_v.z), stance, _net_floor, delta)
	model.set_aim(aim_pitch, aim_forward())


## Hits from this phone's player are sent to the other phone; its HP comes back in its state.
func take_damage(amount: float, zone: String, attacker: Fighter, from_pos: Vector3) -> float:
	if not alive or round_over or attacker == null or attacker == self or not attacker.is_player:
		return 0.0
	var dmg := maxf(Weapons.after_armor(amount, zone, Weapons.VEST_REDUCTION, Weapons.HELMET_REDUCTION), 0.0)
	if arena and arena.has_method("net_hit"):
		arena.net_hit(amount, zone, from_pos)
	damaged.emit(dmg, from_pos, zone == "head", attacker)
	if dmg > 0.0:
		model.play_hit()
	return dmg


## Its shot as the other phone fired it: muzzle flash, sound and one tracer (no damage here).
func remote_shot(origin: Vector3, dir: Vector3) -> void:
	if not alive or dir.length() < 0.5:
		return
	dir = dir.normalized()
	var d := weapon().def
	var muzzle := model.muzzle_position()
	model.on_fire()
	if Weapons.is_melee(d):
		return
	var res := trace(origin, dir, float(d.range) * 1.6)
	var end_pos: Vector3 = res.position if not res.is_empty() else origin + dir * float(d.range) * 1.6
	Effects.tracer(self, muzzle, end_pos)
	if not res.is_empty() and not (res.collider is Area3D):
		Effects.impact(self, end_pos, res.get("normal", Vector3.UP))
	Effects.muzzle_flash(self, muzzle, aim_forward(), int(d.pellets) > 1)
	Audio.play_at(String(d.sound), muzzle, 2.0, float(d.get("pitch", 1.0)) * rng.randf_range(0.95, 1.05), 120.0)
	if arena and arena.has_method("on_gunshot"):
		arena.on_gunshot(self)

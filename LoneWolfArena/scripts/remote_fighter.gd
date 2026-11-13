class_name RemoteFighter
extends Bot
## The other phone's player in an online match (stands in for the bot, so the arena, HUD and
## results treat it the same). It has no AI: it follows the state that phone sends (Cloud: 20
## times a second, drawn a little in the past between the states: NetSmoother), shows its shots, and never loses HP by itself: hits on it are sent
## to its phone, which applies them and reports its HP and its death back.
## In an online DUO / SQUAD match (TeamArenaNet) every fighter the other phone runs is one of
## these: its player, and on the guest also the host's bots (their states come packed in the
## host's "tk"). Hits on it come from this phone's player or, on the host, its bots (net_local),
## never from a teammate, and go out through arena.net_hit_by; knocked, it shows the knock HP its
## phone reports.

const STATE_SIZE := 10

var _net_pos := Vector3.INF
var _net_yaw := 0.0
var _net_pitch := 0.0
var _net_floor := true
var _net_heal := false
## Its HP as this phone's own hits leave it: its reports come back a round trip late, so a hit
## shows (and counts) what it will really take there, never more than is left (hit_points: the
## same armour and whole points its phone applies). Back in step with its reports once no hit
## has been sent for RESYNC_S, or at once when they show less (the zone, a fall).
var hp_left := MAX_HP
var _hp_reported := MAX_HP
var _hit_sent_at := -99.0
const RESYNC_S := 0.8
var _smooth := NetSmoother.new()
## Its player is AWAY (Cloud.peer_away_changed: no link, the app in the background): it stands
## where its last state left it, moves and shoots no more. `decided_here`: this phone decides its HP
## meanwhile (1 vs 1: the phone still there; DUO / SQUAD: the host): hits and the zone take it here
## as a fighter's own (Fighter.take_damage), so it can go down, and knocked it bleeds out here.
## Back, its reports may not heal what it lost meanwhile: hp_cap holds them down until its phone
## took the word ("sync").
var away := false
var decided_here := false
var hp_cap := -1.0
## The kit index each of its states reported, with when (this phone's clock, ms): the hit checks
## allow what a weapon it held within HELD_GRACE_MS can do, since a hit and the state that says the
## hand changed may arrive in either order, and late: states may take the direct path while hits
## always take the relay, which can lag by a second or more. An older build's index 2 does not
## exist (it has no sidearm); this build's index 2 reads as the sidearm on an older build's phone
## as its fists.
const HELD_GRACE_MS := 3000
var _held_ms := {}


## Its player went away (frozen; `here`: decided by this phone) or came back.
func set_away(on: bool, here: bool) -> void:
	if on == away:
		decided_here = on and here
		return
	away = on
	decided_here = on and here
	_smooth.clear()
	_net_pos = global_position
	if not on and alive:
		hp_cap = hp


## Whether its states had weapon `index` in hand now or within HELD_GRACE_MS.
func held_recently(index: int) -> bool:
	return index == current or Time.get_ticks_msec() - int(_held_ms.get(index, -1000000)) <= HELD_GRACE_MS


## [x, y, z, yaw, pitch, stance, flags, weapon index, hp, round]; the weapon index is the kit's
## (Weapons.GUN, FISTS, SIDE), clamped to the kit on arrival; flags: 1 sprint, 2 ads,
## 4 healing, 8 on the floor; DUO / SQUAD only (never in the 1 vs 1): 16 knocked (the hp value is
## then the knock HP), 32 reviving a teammate.
static func pack(f: Fighter, round_index := 1) -> PackedFloat32Array:
	var flags := (1 if f.sprinting else 0) | (2 if f.ads else 0) | (4 if f.healing else 0) | (8 if f.is_on_floor() else 0) \
		| (16 if f.knocked else 0) | (32 if f.reviving != null else 0)
	var at := f.global_position
	return PackedFloat32Array([at.x, at.y, at.z, f.aim_yaw, f.aim_pitch, float(f.stance), float(flags), float(f.current),
		f.knock_hp if f.knocked else f.hp, float(round_index)])


func reset_for_round(pos: Vector3, yaw: float) -> void:
	super(pos, yaw)
	_net_pos = pos
	_net_yaw = yaw
	_net_pitch = 0.0
	_net_heal = false
	hp_left = hp
	_hp_reported = hp
	hp_cap = -1.0
	_held_ms.clear()
	_smooth.clear()


## A state from the other phone; `sent_ms` is its clock when it sent it (-1: an older build).
func apply_state(s: PackedFloat32Array, sent_ms := -1) -> void:
	if not alive:
		return
	var pos := Vector3(s[0], s[1], s[2])
	if not (is_finite(pos.x) and is_finite(pos.y) and is_finite(pos.z)) or pos.length() > 500.0 or not is_finite(s[3]) \
			or not is_finite(s[4]):
		return
	_smooth.push(pos, s[3], clampf(s[4], -1.5, 1.5), float(sent_ms), float(Time.get_ticks_msec()))
	var st := clampi(int(s[5]), 0, 2)
	if st != int(stance):
		set_stance(st as Fighter.Stance, true)
	var flags := int(s[6])
	sprinting = (flags & 1) != 0
	ads = (flags & 2) != 0
	var on_floor := (flags & 8) != 0
	if on_floor and not _net_floor:
		Audio.play_at("land", pos, -9.0)       # back on its feet after a jump or a drop
	_net_floor = on_floor
	var heal := (flags & 4) != 0 or (flags & 32) != 0      # (a revive plays the healing motion)
	if heal != _net_heal:
		_net_heal = heal
		model.play_heal(heal)
	var wi := clampi(int(s[7]), 0, weapons.size() - 1)
	_held_ms[wi] = Time.get_ticks_msec()
	if wi != current:
		switch_weapon(wi)
	if (flags & 16) != 0:
		# Knocked on its phone: the number is its knock HP (shown once the referee's word knocked
		# it here too); its HP is 0 meanwhile.
		if knocked:
			knock_hp = clampf(s[8], 0.0, KNOCK_HP)
		return
	var reported := clampf(s[8], 0.0, hp_max)
	if hp_cap >= 0.0:
		if reported <= hp_cap + 0.5:
			hp_cap = -1.0                # its phone took the word on its HP
		else:
			reported = hp_cap            # (no healing back what it lost while away)
	hp = reported
	if hp > _hp_reported:
		hp_left = minf(hp_left + hp - _hp_reported, hp_max)      # it healed
	_hp_reported = hp
	if hp < hp_left or _now() - _hit_sent_at > RESYNC_S:
		hp_left = hp


func _physics_process(delta: float) -> void:
	if not alive:
		return
	if away:
		velocity = Vector3.ZERO          # frozen where it was (its phone sends nothing)
		model.update_locomotion(Vector2.ZERO, stance, _net_floor, delta)
		if decided_here and knocked and revived_by == null and knock_hp > 0.0:
			# Knocked and away, decided here: it bleeds out as a fighter run here does (the referee
			# hears knock_finished, "bleed"); its phone, back, takes that word.
			knock_hp = maxf(knock_hp - KNOCK_HP / BLEED_S * delta, 0.0)
			if knock_hp <= 0.0:
				last_hit_cause = "bleed"
				knock_finished.emit(self, null, false)
		return
	if _net_pos == Vector3.INF:
		_net_pos = global_position
		_net_yaw = aim_yaw
	var at := _smooth.sample(float(Time.get_ticks_msec()))
	if not at.is_empty():
		_net_pos = at.pos
		_net_yaw = float(at.yaw)
		_net_pitch = float(at.pitch)
	var prev := global_position
	if global_position.distance_to(_net_pos) > 4.0:
		global_position = _net_pos          # too far behind (a hitch): jump (no run, no step sound)
		prev = global_position
	else:
		# Already smooth (NetSmoother): a quick blend only takes the edge off a correction.
		global_position = global_position.lerp(_net_pos, 1.0 - exp(-30.0 * delta))
	velocity = (global_position - prev) / maxf(delta, 0.0001)
	aim_yaw = lerp_angle(aim_yaw, _net_yaw, 1.0 - exp(-30.0 * delta))
	aim_pitch = lerpf(aim_pitch, _net_pitch, 1.0 - exp(-30.0 * delta))
	rotation.y = aim_yaw
	var w := weapon()
	w.tick(delta)
	var local_v := Basis(Vector3.UP, aim_yaw).inverse() * velocity
	model.sprint = sprinting
	model.update_locomotion(Vector2(local_v.x, -local_v.z), stance, _net_floor, delta)
	model.set_aim(aim_pitch, aim_forward())
	# Its steps as loud as a bot's (a run carries, a walk or a crouch only close by) and its
	# footprints on the minimap: the other phone sends no steps, they follow its movement here.
	_footsteps(delta, _net_floor)


## Hits from this phone's player (DUO / SQUAD: from any fighter running here, never a teammate) are
## sent to the other phone; its HP comes back in its state.
func take_damage(amount: float, zone: String, attacker: Fighter, from_pos: Vector3, cause := "") -> float:
	if away and decided_here:
		var dmg0 := super(amount, zone, attacker, from_pos, cause)
		hp_left = hp
		_hp_reported = hp
		return dmg0
	if not alive or round_over or attacker == null or attacker == self or not (attacker.is_player or attacker.net_local) \
			or attacker.ally_of(self):
		return 0.0
	last_hit_cause = cause
	var dmg := clampf(hit_points(amount, zone), 0.0, knock_hp if knocked else hp_left)
	if not knocked:
		hp_left -= dmg
	_hit_sent_at = _now()
	if arena and arena.has_method("net_hit_by"):
		arena.net_hit_by(self, attacker, amount, zone, from_pos)
	elif arena and arena.has_method("net_hit"):
		arena.net_hit(amount, zone, from_pos)
	damaged.emit(dmg, from_pos, zone == "head", attacker)
	if dmg > 0.0 and model:
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

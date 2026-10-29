class_name Bot
extends Fighter
## AI opponent: perception (sight + hearing), state machine, human-like aim with
## reaction time and tracking error, strafing, cover, healing and shield walls.

enum S { SEARCH, ENGAGE, CHASE, COVER, HEAL }

const DIFF := [
	{"reaction": 0.85, "error": 6.5, "head": 0.06, "burst_min": 3, "burst_max": 5, "pause": 0.75, "turn": 150.0, "strafe": 0.55, "shield": 0.2, "crouch": 0.0, "hear": 30.0, "sg_range": 5.0, "jump": 0.0, "grenade": 0.0},
	{"reaction": 0.5, "error": 4.0, "head": 0.16, "burst_min": 4, "burst_max": 8, "pause": 0.45, "turn": 240.0, "strafe": 0.8, "shield": 0.45, "crouch": 0.15, "hear": 45.0, "sg_range": 7.0, "jump": 0.12, "grenade": 0.35},
	{"reaction": 0.24, "error": 2.0, "head": 0.3, "burst_min": 6, "burst_max": 12, "pause": 0.28, "turn": 380.0, "strafe": 1.0, "shield": 0.75, "crouch": 0.35, "hear": 60.0, "sg_range": 9.0, "jump": 0.25, "grenade": 0.6},
]
## The zone keeps closing: stay this far inside its edge (m), and start moving in this many
## seconds before the shrink begins.
const ZONE_MARGIN := 2.5
const ZONE_EARLY := 6.0

var target: Fighter
var state := S.SEARCH
var difficulty := 1
var p := {}
var agent: NavigationAgent3D
var see_target := false
var last_seen_pos := Vector3.ZERO
var last_seen_time := -999.0
var has_info := false
var reaction := 0.0
var track_time := 0.0
var aim_head := false
var aim_err := Vector3.ZERO
var _err_timer := 0.0
var strafe_dir := 1.0
var strafe_timer := 0.0
var burst_left := 0
var burst_pause := 0.0
var perceive_timer := 0.0
var cover_point := Vector3.INF
var wander_point := Vector3.INF
var _stuck_timer := 0.0
var _last_pos := Vector3.ZERO
var _shield_cooldown := 0.0
var _decision_timer := 0.0
var _grenade_timer := 0.0
var _zone_goal := Vector3.INF
var _zone_goal_timer := 0.0
var nav_ready := false


func _ready() -> void:
	add_to_group("fighters")
	agent = NavigationAgent3D.new()
	agent.path_desired_distance = 0.7
	agent.target_desired_distance = 0.9
	agent.radius = 0.45
	agent.height = 1.8
	agent.avoidance_enabled = false
	add_child(agent)


func configure(diff: int, enemy: Fighter) -> void:
	difficulty = clampi(diff, 0, 2)
	p = DIFF[difficulty]
	target = enemy
	strafe_dir = 1.0 if rng.randf() < 0.5 else -1.0


func reset_for_round(pos: Vector3, yaw: float) -> void:
	super(pos, yaw)
	state = S.SEARCH
	see_target = false
	has_info = false
	last_seen_time = -999.0
	reaction = 0.0
	track_time = 0.0
	burst_left = 0
	burst_pause = 0.0
	cover_point = Vector3.INF
	wander_point = Vector3.INF
	_stuck_timer = 0.0
	_last_pos = pos
	_shield_cooldown = 0.0
	_decision_timer = 0.0
	_grenade_timer = 0.0
	_zone_goal = Vector3.INF
	_zone_goal_timer = 0.0


# ---------------------------------------------------------------- perception

func _perceive() -> void:
	var was := see_target
	see_target = false
	if target == null or not target.alive:
		return
	var head := target.head_position()
	var chest := target.chest_position()
	var to := chest - eye_position()
	var dist := to.length()
	if dist > 85.0:
		return
	var facing := -global_basis.z
	var in_fov := facing.angle_to(to / maxf(dist, 0.01)) < deg_to_rad(70.0)
	var alerted := _now() - last_seen_time < 4.0 or _now() - last_attacked_time < 3.0
	if not in_fov and not alerted and dist > 6.0:
		return
	if can_see(chest) or can_see(head):
		see_target = true
		last_seen_pos = target.global_position
		last_seen_time = _now()
		has_info = true
		if not was:
			reaction = float(p.reaction) * rng.randf_range(0.8, 1.25)
			track_time = 0.0
			aim_head = rng.randf() < float(p.head)


func hear(pos: Vector3, loudness: float) -> void:
	if global_position.distance_to(pos) <= float(p.get("hear", 40.0)) * loudness:
		if not see_target:
			last_seen_pos = pos
			has_info = true
			if _now() - last_seen_time > 1.0:
				last_seen_time = _now() - 1.0


# ---------------------------------------------------------------- brain

func _think(delta: float) -> void:
	if p.is_empty():
		configure(1, target)
	perceive_timer -= delta
	if perceive_timer <= 0.0:
		perceive_timer = 0.1
		_perceive()
	_shield_cooldown -= delta
	_grenade_timer -= delta
	reaction -= delta
	if see_target:
		track_time += delta
	_decide(delta)
	if _zone_pressure(delta):
		# Get inside the safe zone first; keep shooting on the way if the enemy is in sight.
		if healing:
			cancel_heal()
		if state == S.HEAL or state == S.COVER:
			state = S.ENGAGE if see_target else S.CHASE
		_move_to(_zone_goal, delta)
		if see_target:
			_aim_and_shoot(delta)
		else:
			_face_point(_zone_goal + Vector3.UP * 1.5, delta, 0.6)
		if weapon().ammo <= 0 and not weapon().reloading:
			start_reload()
		_check_stuck(delta)
		return
	_maybe_grenade()
	match state:
		S.ENGAGE:
			_engage(delta)
		S.CHASE:
			_move_to(last_seen_pos, delta)
			_face_point(last_seen_pos + Vector3.UP * 1.4, delta, 0.6)
		S.COVER:
			_cover(delta)
		S.HEAL:
			move_dir = Vector2.ZERO
			if see_target:
				_face_point(target.chest_position(), delta, 0.8)
			if not healing:
				if hp < MAX_HP and medkits > 0 and not start_heal():
					state = S.ENGAGE
				elif hp >= MAX_HP or medkits <= 0:
					state = S.ENGAGE
		_:
			_search(delta)
	if weapon().ammo <= 0 and not weapon().reloading:
		start_reload()
	_zone_clamp_move()
	_check_stuck(delta)


func _decide(delta: float) -> void:
	_decision_timer -= delta
	var low := hp < MAX_HP * 0.42
	if state == S.HEAL:
		if see_target and _now() - last_attacked_time < 0.5:
			cancel_heal()
			state = S.ENGAGE
		return
	if low and medkits > 0 and state != S.COVER and _decision_timer <= 0.0:
		_decision_timer = 3.0
		if see_target and shields > 0 and _shield_cooldown <= 0.0 and rng.randf() < float(p.shield):
			_shield_cooldown = 8.0
			deploy_shield((target.global_position - global_position))
			state = S.HEAL
			set_crouch(true)
			return
		cover_point = _find_cover()
		if cover_point != Vector3.INF:
			state = S.COVER
			return
	if state == S.COVER:
		return
	if see_target and shields > 0 and _shield_cooldown <= 0.0 and _now() - last_attacked_time < 0.25 \
			and global_position.distance_to(target.global_position) > 5.0 and rng.randf() < float(p.shield) * 0.3:
		# Under fire in the open: drop a wall toward the shooter and keep fighting around it.
		_shield_cooldown = 10.0
		deploy_shield(target.global_position - global_position)
	if see_target:
		state = S.ENGAGE
	elif has_info and _now() - last_seen_time < 12.0:
		state = S.CHASE
		if global_position.distance_to(last_seen_pos) < 1.5:
			has_info = false
			state = S.SEARCH
	else:
		state = S.SEARCH


## True while the bot should head into the safe zone; keeps _zone_goal (a nav point well inside).
func _zone_pressure(delta: float) -> bool:
	if arena == null or arena.get("phase") != 1:
		return false
	var c: Vector3 = arena.zone_center
	var flat := Vector2(global_position.x - c.x, global_position.z - c.z).length()
	var r: float = arena.zone_radius
	var st := String(arena.zone_state)
	if st == "stationary":
		if float(arena.zone_next()) > ZONE_EARLY:
			if flat <= r - 0.5:
				return false
		r = minf(r, float(arena.zone_start_radius) * 0.7)
	elif st == "shrinking":
		r = maxf(r - 4.0, 3.0)     # where the edge will be in a few seconds
	var need := flat > r - minf(ZONE_MARGIN, r * 0.3)
	if not need:
		_zone_goal = Vector3.INF
		return false
	_zone_goal_timer -= delta
	if _zone_goal == Vector3.INF or _zone_goal_timer <= 0.0 or global_position.distance_to(_zone_goal) < 1.2:
		_zone_goal_timer = 2.0
		# A spot inside on the bot's own side of the centre (no detours around central cover).
		var out := Vector3(global_position.x - c.x, 0.0, global_position.z - c.z)
		var keep := clampf(r * 0.45, 0.5, 8.0)
		var spot := c + (out.normalized() * keep if out.length() > 0.1 else Vector3.ZERO)
		spot += Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)) * minf(keep * 0.3, 2.0)
		_zone_goal = arena.closest_nav_point(spot)
	return true


## While the zone is closing, never step outward across the edge (strafing / backing off).
func _zone_clamp_move() -> void:
	if arena == null or arena.get("phase") != 1 or String(arena.zone_state) == "stationary" or move_dir.length() < 0.05:
		return
	var c: Vector3 = arena.zone_center
	var out := Vector3(global_position.x - c.x, 0.0, global_position.z - c.z)
	var flat := out.length()
	var r: float = arena.zone_radius
	if flat < 0.1 or flat < r - 2.0:
		return
	out /= flat
	var world := Basis(Vector3.UP, aim_yaw) * Vector3(move_dir.x, 0.0, -move_dir.y)
	var radial := world.dot(out)
	if radial > 0.0:
		world -= out * (radial + 0.35)      # drop the outward part and lean back in
		var local := Basis(Vector3.UP, aim_yaw).inverse() * world
		move_dir = Vector2(local.x, -local.z).limit_length(1.0)


## Frag the enemy out of cover: it was seen a moment ago, is hiding now, and is in throwing range.
func _maybe_grenade() -> void:
	if grenades <= 0 or _grenade_timer > 0.0 or see_target or not has_info or healing or target == null:
		return
	var since := _now() - last_seen_time
	if since < 0.8 or since > 5.0:
		return
	_grenade_timer = 2.5
	var d := global_position.distance_to(last_seen_pos)
	if d < 7.0 or d > 22.0 or rng.randf() >= float(p.get("grenade", 0.0)):
		return
	_face_point(last_seen_pos + Vector3.UP * 1.0, 1.0, 100.0)
	throw_grenade(last_seen_pos)


func _engage(delta: float) -> void:
	var tpos := target.global_position
	var to := tpos - global_position
	to.y = 0.0
	var dist := to.length()
	# One gun per round (Lone Wolf): keep the range that suits it; fists only when it is dry.
	if current != 0 and (gun().ammo > 0 or gun().reserve > 0):
		switch_weapon(0)
	elif current == 0 and gun().ammo <= 0 and gun().reserve <= 0 and not gun().reloading:
		switch_weapon(1)
	# Strafe left/right, keep a comfortable distance.
	strafe_timer -= delta
	if strafe_timer <= 0.0:
		strafe_timer = rng.randf_range(0.35, 1.2)
		if rng.randf() < 0.7:
			strafe_dir = -strafe_dir
		var cls := String(weapon().def["class"])
		if cls == "SNIPER" and dist > 18.0 and rng.randf() < float(p.crouch) * 1.5:
			set_stance(Stance.PRONE if stance != Stance.PRONE else Stance.CROUCH)
		elif rng.randf() < float(p.crouch):
			set_crouch(not crouching)
		elif stance != Stance.STAND and rng.randf() < 0.5:
			set_stance(Stance.STAND)
		elif stance == Stance.STAND and is_on_floor() and cls != "SNIPER" and rng.randf() < float(p.get("jump", 0.0)):
			want_jump = true      # jump-strafe while shooting, like players do
	var band := _range_band()
	var desired_min: float = band.x
	var desired_max: float = band.y
	var fwd_amt := 0.0
	if dist > desired_max:
		fwd_amt = 1.0
	elif dist < desired_min:
		fwd_amt = -0.7
	var side := strafe_dir * float(p.strafe)
	if _blocked(global_basis.x * signf(side)):
		strafe_dir = -strafe_dir
		side = -side
	if fwd_amt > 0.0 and _blocked(-global_basis.z):
		fwd_amt = 0.0
	move_dir = Vector2(side, fwd_amt).limit_length(1.0)
	_aim_and_shoot(delta)


func _aim_and_shoot(delta: float) -> void:
	var aim_point := target.head_position() if aim_head else target.chest_position()
	_err_timer -= delta
	if _err_timer <= 0.0:
		_err_timer = 0.22
		var tv := Vector2(target.velocity.x, target.velocity.z).length()
		var err_deg := float(p.error) * (1.0 + 1.4 * exp(-track_time * 1.6)) * (0.75 + tv / 5.0 * 0.6)
		if target.crouching:
			err_deg *= 1.1
		var dist := eye_position().distance_to(aim_point)
		var err_m := tan(deg_to_rad(err_deg)) * dist
		aim_err = aim_err.lerp(Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.6, 0.8), rng.randf_range(-1, 1)).normalized() * err_m * rng.randf(), 0.6)
	var goal := aim_point + aim_err
	var facing_ok := _face_point(goal, delta, 1.0)
	if reaction > 0.0 or not facing_ok:
		return
	if burst_pause > 0.0:
		burst_pause -= delta
		return
	if burst_left <= 0:
		burst_left = rng.randi_range(int(p.burst_min), int(p.burst_max))
		aim_head = rng.randf() < float(p.head)
	var w := weapon()
	if w.can_fire():
		var origin := eye_position()
		var dir := (goal - origin).normalized()
		if perform_shot(origin, dir):
			burst_left -= 1
			if burst_left <= 0:
				burst_pause = float(p.pause) * rng.randf_range(0.7, 1.4)


## Preferred fighting distance (min, max) for the round's gun.
func _range_band() -> Vector2:
	match String(weapon().def["class"]):
		"SG":
			return Vector2(2.5, 7.0)
		"SMG":
			return Vector2(4.0, 12.0)
		"PISTOL":
			return Vector2(7.0, 18.0)
		"SNIPER":
			return Vector2(16.0, 32.0)
		"MELEE":
			return Vector2(0.8, 1.6)
	return Vector2(9.0, 22.0)


func _face_point(point: Vector3, delta: float, speed_mult: float) -> bool:
	var dir := point - eye_position()
	if dir.length() < 0.05:
		return true
	dir = dir.normalized()
	var want_yaw := atan2(-dir.x, -dir.z)
	var want_pitch := asin(clampf(dir.y, -1.0, 1.0))
	var rate := deg_to_rad(float(p.turn) * speed_mult) * delta
	var dy := wrapf(want_yaw - aim_yaw, -PI, PI)
	aim_yaw += clampf(dy, -rate, rate)
	aim_pitch += clampf(want_pitch - aim_pitch, -rate, rate)
	return absf(wrapf(want_yaw - aim_yaw, -PI, PI)) < deg_to_rad(6.0) and absf(want_pitch - aim_pitch) < deg_to_rad(6.0)


func _search(delta: float) -> void:
	if wander_point == Vector3.INF or global_position.distance_to(wander_point) < 1.5:
		wander_point = arena.random_nav_point() if arena else global_position
		if target and rng.randf() < 0.55:
			# Drift toward the opponent's general area (bots "hunt" in Lone Wolf).
			wander_point = arena.closest_nav_point(target.global_position + Vector3(rng.randf_range(-12, 12), 0, rng.randf_range(-12, 12))) if arena else wander_point
	_move_to(wander_point, delta)
	var look := wander_point + Vector3.UP * 1.5
	_face_point(look, delta, 0.5)


func _cover(delta: float) -> void:
	if cover_point == Vector3.INF:
		state = S.ENGAGE
		return
	_move_to(cover_point, delta)
	if see_target:
		_face_point(target.chest_position(), delta, 0.8)
	else:
		_face_point(cover_point + (cover_point - global_position) + Vector3.UP * 1.4, delta, 0.5)
	if global_position.distance_to(cover_point) < 1.0 or (not see_target and global_position.distance_to(cover_point) < 3.0):
		state = S.HEAL
		cover_point = Vector3.INF


func _find_cover() -> Vector3:
	if arena == null or target == null:
		return Vector3.INF
	var best := Vector3.INF
	var best_score := INF
	var teye := target.eye_position()
	var pts: Array = arena.cover_points
	var tries := 0
	for cp: Vector3 in pts:
		var d := global_position.distance_to(cp)
		if d > 20.0 or d < 1.5:
			continue
		tries += 1
		if tries > 40:
			break
		var probe := cp + Vector3.UP * 1.1
		var q := PhysicsRayQueryParameters3D.create(teye, probe, MASK_SIGHT)
		if get_world_3d().direct_space_state.intersect_ray(q).is_empty():
			continue
		var score := d - cp.distance_to(target.global_position) * 0.3
		if score < best_score:
			best_score = score
			best = cp
	return best


func _move_to(point: Vector3, _delta: float) -> void:
	# Sprint when the destination is far and nothing is in sight (like players running in).
	sprinting = not see_target and global_position.distance_to(point) > 8.0 and stance == Stance.STAND and not healing
	if not nav_ready:
		var dir := point - global_position
		dir.y = 0.0
		_set_move_world(dir)
		return
	if agent.target_position.distance_to(point) > 0.6:
		agent.target_position = point
	if agent.is_navigation_finished():
		move_dir = Vector2.ZERO
		return
	var next := agent.get_next_path_position()
	var dir2 := next - global_position
	dir2.y = 0.0
	_set_move_world(dir2)


func _set_move_world(dir: Vector3) -> void:
	if dir.length() < 0.05:
		move_dir = Vector2.ZERO
		return
	dir = dir.normalized()
	var local := Basis(Vector3.UP, aim_yaw).inverse() * dir
	move_dir = Vector2(local.x, -local.z)


func _blocked(dir: Vector3) -> bool:
	var d := dir
	d.y = 0.0
	if d.length() < 0.1:
		return false
	d = d.normalized()
	var res := trace(global_position + Vector3.UP * 0.6, d, 1.3, LAYER_WORLD | LAYER_SHIELD)
	return not res.is_empty()


func _check_stuck(delta: float) -> void:
	if move_dir.length() < 0.2:
		_stuck_timer = 0.0
		_last_pos = global_position
		return
	_stuck_timer += delta
	if _stuck_timer > 1.2:
		if global_position.distance_to(_last_pos) < 0.5:
			strafe_dir = -strafe_dir
			wander_point = arena.random_nav_point() if arena else wander_point
			if is_on_floor() and rng.randf() < 0.3:
				want_jump = true
		_stuck_timer = 0.0
		_last_pos = global_position

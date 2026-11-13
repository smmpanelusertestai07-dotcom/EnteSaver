class_name Bot
extends Fighter
## AI opponent: perception (sight + hearing), state machine, human-like aim with
## reaction time and tracking error, strafing, cover, healing and shield walls.

enum S { SEARCH, ENGAGE, CHASE, COVER, HEAL }
## How long a bot walks its sidestep when it gets stuck on cover (_start_detour).
const DETOUR_S := 0.8
## Seconds without getting closer to the zone's centre before the bot tries another way in.
const ZONE_REROUTE_S := 2.5

## The levels EASY, NORMAL, HARD. NORMAL is for a casual player on a phone (one lost 0-5 in 2.5
## minutes to its earlier, sharper numbers): it sits nearer EASY than HARD in reaction and aim.
## Every number keeps EASY <= NORMAL <= HARD in strength (tests/match_unit_check.gd).
const DIFF := [
	{"reaction": 0.85, "error": 6.5, "head": 0.06, "burst_min": 3, "burst_max": 5, "pause": 0.75, "turn": 150.0, "strafe": 0.55, "shield": 0.2, "crouch": 0.0, "hear": 30.0, "sg_range": 5.0, "jump": 0.0, "grenade": 0.0},
	{"reaction": 0.68, "error": 5.4, "head": 0.1, "burst_min": 3, "burst_max": 6, "pause": 0.6, "turn": 185.0, "strafe": 0.65, "shield": 0.3, "crouch": 0.08, "hear": 38.0, "sg_range": 6.0, "jump": 0.06, "grenade": 0.2},
	{"reaction": 0.24, "error": 2.0, "head": 0.3, "burst_min": 6, "burst_max": 12, "pause": 0.28, "turn": 380.0, "strafe": 1.0, "shield": 0.75, "crouch": 0.35, "hear": 60.0, "sg_range": 9.0, "jump": 0.25, "grenade": 0.6},
]
## The zone keeps closing: stay this far inside the edge (m) of where it will be ZONE_AHEAD_S from
## now (Arena.zone_at). The circles of stage 2 are nested, so a spot inside that one stays inside
## the zone meanwhile; the bot starts heading in that long before the closing begins.
const ZONE_MARGIN := 2.5
## EASY / NORMAL: how far over the chest point a chest-aimed shot may stray (under the head box).
const HEAD_CLEAR_M := 0.12
const ZONE_AHEAD_S := 8.0
## Where the zone is going is this small (m): the bot walks straight to its centre and stands there.
const ZONE_HOLD_R := 3.0
## ... and walks the last this many metres straight (the navigation path ends 0.9 m short).
const ZONE_STEP_M := 1.5
## The sidearm (_choose_arm): drawn when the gun's magazine runs empty with the enemy in sight this
## close (m), instead of a reload in the open; put away for the gun past SIDEARM_KEEP_M.
const SIDEARM_DRAW_M := 8.0
const SIDEARM_KEEP_M := 12.0

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
## A short sidestep around whatever snagged the bot (see _check_stuck): the point and the time left.
var _detour := Vector3.INF
var _detour_t := 0.0
## Zone approach progress: the closest the bot got to the centre, how long it has not got closer,
## and the angle its goal is turned around the centre to try another way in (see _zone_pressure).
var _zone_best := INF
var _zone_progress_t := 0.0
var _zone_turn := 0.0
var _shield_cooldown := 0.0
var _decision_timer := 0.0
var _grenade_timer := 0.0
var _zone_goal := Vector3.INF
var _zone_hold := false         # _zone_goal is the zone's last spot, walked to straight (_zone_pressure)
var _zone_goal_timer := 0.0
var nav_ready := false
## DUO / SQUAD (TeamArena sets them; empty in the 1 vs 1, where `target` stays the one opponent):
## the other team's fighters and this bot's teammates. Every RETARGET_S the bot turns to the UP
## enemy it sees nearest, else the one that hit it in the last 3 s, else the nearest one left (a
## knocked enemy only when no UP one is in sight). With nobody in sight it revives a knocked
## teammate nearby (REVIVE_QUIET_S of quiet, within REVIVE_SEEK_M) and keeps near a human
## teammate (FOLLOW_M), never while the zone presses.
var enemies: Array[Fighter] = []
var allies: Array[Fighter] = []
const RETARGET_S := 0.5
const REVIVE_QUIET_S := 1.5
const REVIVE_SEEK_M := 15.0
const FOLLOW_M := 7.0
var _retarget_t := 0.0
var _following := false


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
	_detour_t = 0.0
	_zone_best = INF
	_zone_progress_t = 0.0
	_zone_turn = 0.0


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
			# A first sight of a player who has not fired yet: a moment more before the first shot
			# (NORMAL 0.6-0.9 s, EASY longer; HARD as before), so an idle newcomer is not dropped at GO.
			if difficulty < 2 and _now() - target.last_shot_time > 3.0:
				var lo := 0.6 if difficulty == 1 else 0.9
				reaction = maxf(reaction, rng.randf_range(lo, lo + 0.3))


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
	if knocked:
		_crawl(delta)
		return
	if not enemies.is_empty():
		_retarget_t -= delta
		if _retarget_t <= 0.0:
			_retarget_t = RETARGET_S
			_retarget()
	if reviving != null:
		# Reviving a teammate (TeamArena runs it): still, unless shot at.
		move_dir = Vector2.ZERO
		if _now() - last_attacked_time < 0.3 and arena and arena.has_method("cancel_revive"):
			arena.cancel_revive(self)
		return
	perceive_timer -= delta
	if perceive_timer <= 0.0:
		perceive_timer = 0.1
		_perceive()
	_shield_cooldown -= delta
	_grenade_timer -= delta
	reaction -= delta
	if see_target:
		track_time += delta
	if _throwing:
		# The throw's wind-up (Fighter.THROW_RELEASE): stand still and keep facing, so the frag
		# leaves the hand from where the bot solved its arc (not from a step into cover).
		move_dir = Vector2.ZERO
		sprinting = false
		return
	_decide(delta)
	if _zone_pressure(delta):
		# Get inside the safe zone first; keep shooting on the way if the enemy is in sight.
		if healing:
			cancel_heal()
		if state == S.HEAL or state == S.COVER:
			state = S.ENGAGE if see_target else S.CHASE
		if _zone_hold:
			# Straight onto the zone's last spot (it is off the cover), and stand still there.
			var to := _zone_goal - global_position
			to.y = 0.0
			_set_move_world(to if to.length() > 0.2 else Vector3.ZERO)
			sprinting = false
		else:
			_move_to(_zone_goal, delta)
		if see_target:
			_aim_and_shoot(delta)
		else:
			_face_point(_zone_goal + Vector3.UP * 1.5, delta, 0.6)
		_arm_up()
		if weapon().ammo <= 0 and not weapon().reloading:
			start_reload()
		_check_stuck(delta)
		return
	_maybe_grenade()
	if (state == S.SEARCH or state == S.CHASE) and not allies.is_empty() and _team_errand(delta, state == S.SEARCH):
		_arm_up()
		if weapon().ammo <= 0 and not weapon().reloading:
			start_reload()
		_check_stuck(delta)
		return
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
				if hp < hp_max and medkits > 0 and not start_heal():
					state = S.ENGAGE
				elif hp >= hp_max or medkits <= 0:
					state = S.ENGAGE
		_:
			_search(delta)
	_arm_up()
	if weapon().ammo <= 0 and not weapon().reloading:
		start_reload()
	_zone_clamp_move()
	_check_stuck(delta)


func _decide(delta: float) -> void:
	_decision_timer -= delta
	var low := hp < hp_max * 0.42
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


## True while the bot should head into the safe zone; keeps _zone_goal (a nav point well inside
## the circle the zone will be ZONE_AHEAD_S from now, on the bot's own side of its centre).
func _zone_pressure(delta: float) -> bool:
	if arena == null or arena.get("phase") != 1:
		return false
	var ahead: Array = arena.zone_at(float(arena.get("elapsed")) + ZONE_AHEAD_S)
	var c: Vector3 = ahead[0]
	var r: float = ahead[1]
	var flat := Vector2(global_position.x - c.x, global_position.z - c.z).length()
	if r <= ZONE_HOLD_R:
		# The last seconds: the zone ends on a spot, so go and stand on it: along the navigation
		# path (around the cover) until it is a step away, then straight onto it.
		var close := flat < ZONE_STEP_M
		if close or flat > r - minf(ZONE_MARGIN, r * 0.3):
			_zone_goal = Vector3(c.x, global_position.y, c.z) if close else arena.closest_nav_point(c)
			_zone_hold = close
			return true
	var need := flat > r - minf(ZONE_MARGIN, r * 0.3)
	_zone_hold = false
	if not need:
		_zone_goal = Vector3.INF
		_zone_best = INF
		_zone_turn = 0.0
		return false
	# Moving about without getting closer to the centre (a snag the path keeps leading into):
	# after ZONE_REROUTE_S, aim for a spot turned around the centre so the path takes another way.
	if flat < _zone_best - 0.5:
		_zone_best = flat
		_zone_progress_t = 0.0
	else:
		_zone_progress_t += delta
		if _zone_progress_t > ZONE_REROUTE_S:
			_zone_progress_t = 0.0
			_zone_best = flat
			_zone_turn = 0.4 * PI if _zone_turn == 0.0 else -signf(_zone_turn) * minf(absf(_zone_turn) + 0.4 * PI, PI)
			_zone_goal_timer = 0.0
	_zone_goal_timer -= delta
	if _zone_goal == Vector3.INF or _zone_goal_timer <= 0.0 or global_position.distance_to(_zone_goal) < 1.2:
		_zone_goal_timer = 2.0
		# A spot inside on the bot's own side of the centre (no detours around central cover).
		var out := Vector3(global_position.x - c.x, 0.0, global_position.z - c.z)
		if _zone_turn != 0.0:
			out = out.rotated(Vector3.UP, _zone_turn)
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
	# One gun per round (Lone Wolf): keep the range that suits it; the sidearm when the gun runs
	# empty up close, the fists only when both are dry.
	_choose_arm(dist)
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
	if difficulty < 2 and not aim_head:
		# EASY / NORMAL aiming at the chest: the spread stays under the neck, so headshots come
		# only from the few bursts aimed at the head (p.head), at most about a quarter of hits.
		goal.y = minf(goal.y, aim_point.y + HEAD_CLEAR_M)
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
			if net_local and arena and arena.has_method("net_shot_by"):
				arena.net_shot_by(self, origin, dir)
			burst_left -= 1
			if burst_left <= 0:
				burst_pause = float(p.pause) * rng.randf_range(0.7, 1.4)


## Which weapon of the kit to hold in a fight with the enemy `dist` m away: the gun while it has
## rounds; its magazine empty with the enemy within SIDEARM_DRAW_M, the sidearm instead of a reload
## in the open (unless the reload is nearly done); back to the gun (which _think then reloads) once
## the sidearm's magazine is empty (even with its reload begun: the gun's reserve first) or the
## enemy is past SIDEARM_KEEP_M (out of sight, or the fight over: _arm_up); the fists only when
## the gun and the sidearm are both dry.
func _choose_arm(dist: float) -> void:
	var g := gun()
	var sa := sidearm()
	var gun_dry := g.ammo <= 0 and g.reserve <= 0 and not g.reloading
	var side_dry := sa == null or (sa.ammo <= 0 and sa.reserve <= 0 and not sa.reloading)
	match current:
		Weapons.SIDE:
			if not gun_dry and (sa.ammo <= 0 or dist > SIDEARM_KEEP_M):
				switch_weapon(Weapons.GUN)
			elif gun_dry and side_dry:
				switch_weapon(Weapons.FISTS)
		Weapons.GUN:
			if g.ammo <= 0 and dist <= SIDEARM_DRAW_M and sa != null and sa.ammo > 0 \
					and not (g.reloading and g.reload_progress() > 0.6):
				switch_weapon(Weapons.SIDE)
			elif gun_dry:
				switch_weapon(Weapons.FISTS if side_dry else Weapons.SIDE)
		_:
			if not gun_dry:
				switch_weapon(Weapons.GUN)
			elif not side_dry:
				switch_weapon(Weapons.SIDE)


## The kit at the end of every path of _think, just before its reload of an empty magazine: in a
## fight with the enemy in sight, _choose_arm (so a magazine emptied this frame is answered now:
## the sidearm drawn up close, or the gun back for an emptied sidearm, never a reload of the
## sidearm while the gun has rounds); otherwise (fight broken off, healing, heading into the zone,
## on a team errand) the sidearm goes away for the gun, reloaded out of sight.
func _arm_up() -> void:
	if state == S.ENGAGE and see_target and target != null:
		var to := target.global_position - global_position
		to.y = 0.0
		_choose_arm(to.length())
	elif current == Weapons.SIDE and (gun().ammo > 0 or gun().reserve > 0 or gun().reloading):
		switch_weapon(Weapons.GUN)


## Preferred fighting distance (min, max) for the round's gun.
func _range_band() -> Vector2:
	match String(weapon().def["class"]):
		"SG":
			return Vector2(2.5, 7.0)
		"SMG":
			return Vector2(4.0, 12.0)
		"PISTOL":
			return Vector2(7.0, 18.0)
		"DMR":
			return Vector2(12.0, 26.0)
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


func _move_to(point: Vector3, delta: float) -> void:
	if _detour_t > 0.0:
		_detour_t -= delta
		point = _detour
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


## Sets a detour point about 2.5 m to the side of the way the bot was trying to go (the side
## flips each time it gets stuck), walked to for DETOUR_S before the path is asked again.
func _start_detour() -> void:
	if arena == null:
		return
	var ahead := Vector3.ZERO
	if nav_ready and not agent.is_navigation_finished():
		ahead = agent.get_next_path_position() - global_position
	ahead.y = 0.0
	if ahead.length() < 0.1:
		ahead = Basis(Vector3.UP, aim_yaw) * Vector3.FORWARD
	ahead = ahead.normalized()
	var side := Vector3(-ahead.z, 0.0, ahead.x) * (1.0 if float(strafe_dir) >= 0.0 else -1.0)
	_detour = arena.closest_nav_point(global_position + side * 2.5 - ahead * 0.5)
	_detour_t = DETOUR_S


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
			# Step sideways around the snag for a moment instead of pushing into the same corner,
			# and hop it at once while the zone is closing (a stuck bot there loses HP every second).
			_start_detour()
			if is_on_floor() and (_zone_goal != Vector3.INF or rng.randf() < 0.3):
				want_jump = true
			_zone_goal_timer = 0.0      # and pick a fresh spot inside the zone
		_stuck_timer = 0.0
		_last_pos = global_position


# ---------------------------------------------------------------- teams (DUO / SQUAD)

## Picks whom to fight (see `enemies`).
func _retarget() -> void:
	var best: Fighter = null
	var best_d := INF
	for e: Fighter in enemies:
		if e.alive and not e.knocked:
			var d := global_position.distance_to(e.global_position)
			if d < best_d and d < 85.0 and (can_see(e.chest_position()) or can_see(e.head_position())):
				best = e
				best_d = d
	if best == null and last_attacker != null and is_instance_valid(last_attacker) and last_attacker.alive \
			and _now() - last_attacked_time < 3.0 and last_attacker in enemies:
		best = last_attacker
	if best == null:
		for e: Fighter in enemies:
			if e.alive and e.knocked:
				var d := global_position.distance_to(e.global_position)
				if d < best_d and can_see(e.chest_position()):
					best = e
					best_d = d
	if best == null:
		for e: Fighter in enemies:
			if e.alive:
				var d := global_position.distance_to(e.global_position) + (30.0 if e.knocked else 0.0)
				if d < best_d:
					best = e
					best_d = d
	if best != null and best != target:
		target = best
		see_target = false               # a new face: the reaction time again
		track_time = 0.0


## With no enemy in sight: revive a knocked teammate nearby, or (may_follow) keep near a human
## teammate. True when it moved the bot.
func _team_errand(delta: float, may_follow: bool) -> bool:
	if _now() - last_seen_time > REVIVE_QUIET_S and _now() - last_attacked_time > REVIVE_QUIET_S:
		var down: Fighter = null
		var down_d := REVIVE_SEEK_M
		for a: Fighter in allies:
			if a.alive and a.knocked and (a.revived_by == null or a.revived_by == self):
				var d := global_position.distance_to(a.global_position)
				if d < down_d:
					down = a
					down_d = d
		if down != null:
			if down_d <= Fighter.REVIVE_RANGE - 0.4:
				move_dir = Vector2.ZERO
				sprinting = false
				_face_point(down.global_position + Vector3.UP * 0.3, delta, 0.8)
				if arena and arena.has_method("start_revive"):
					arena.start_revive(self, down)
			else:
				_move_to(down.global_position, delta)
				_face_point(down.global_position + Vector3.UP * 1.2, delta, 0.6)
			return true
	if not may_follow:
		return false
	for a: Fighter in allies:
		if a.alive and not a.knocked and (a is Player or a is RemoteFighter):
			var d := global_position.distance_to(a.global_position)
			if d > FOLLOW_M or (_following and d > 4.0):
				_following = true
				var behind := a.global_position + Basis(Vector3.UP, a.aim_yaw) * Vector3(1.2 if slot % 2 == 0 else -1.2, 0.0, 3.0)
				var goal: Vector3 = arena.closest_nav_point(behind) if arena else behind
				_move_to(goal, delta)
				_face_point(goal + (goal - global_position) + Vector3.UP * 1.4, delta, 0.5)
				return true
			break
	_following = false
	return false


## Knocked: crawl toward the nearest teammate still UP (no gun, no items).
func _crawl(delta: float) -> void:
	var best: Fighter = null
	var best_d := INF
	for a: Fighter in allies:
		if a.alive and not a.knocked:
			var d := global_position.distance_to(a.global_position)
			if d < best_d:
				best = a
				best_d = d
	if best == null or best_d < 1.5 or revived_by != null:
		move_dir = Vector2.ZERO
		return
	_move_to(best.global_position, delta)
	_face_point(best.global_position + Vector3.UP * 0.4, delta, 0.5)

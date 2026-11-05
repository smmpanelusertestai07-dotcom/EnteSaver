extends Node
## TRAINING GROUND DUO / SQUAD on this phone (run with LW_ROUNDS_TO_WIN=1): a SQUAD match with 8
## fighters, 4 a team, scripted through its rules (the bots held still): an ally in the crosshair
## gets no assist and no red crosshair (an enemy there does); friendly fire takes nothing and a
## fighter's own frag still hurts; a knock comes before any elimination; the player revives a
## knocked bot teammate, which stands up with REVIVE_HP after REVIVE_S; the pause menu pauses this
## offline match; the player knocked has no gun, finished is out, and the camera then follows a
## teammate still UP; three enemies knocked do not end the round, the last one UP down wipes their
## team, and a teammate knocked at the round's end stands up in the next round, played to 2-0;
## the results hold 8 rows and the profile counts the match as TRAINING. Then a DUO match: a
## bot revives its knocked teammate, then the bots play it to its end. No damage is ever taken from
## a teammate.
## Prints "TEAM OFFLINE CHECK DONE bad=N".

var bad := 0
var at: Node
var _knocks := 0
var _outs_before_knock := 0
var _ally_damage := 0


func run(autotest: Node) -> int:
	at = autotest
	Game.settings.difficulty = 1
	await _squad()
	await _duo()
	return _done("")


func _watch(arena: TeamArena) -> void:
	for f: Fighter in arena.fighters:
		f.damaged.connect(func(amount: float, _from: Vector3, _head: bool, attacker: Fighter) -> void:
			if attacker != null and attacker != f and attacker.team == f.team and amount > 0.0:
				_ally_damage += 1
				_fail("%s took %.0f from teammate %s" % [f.display_name, amount, attacker.display_name]))
		f.knocked_down.connect(func(_v: Fighter, _k: Fighter, _h: bool) -> void: _knocks += 1)
		f.died.connect(func(_v: Fighter, _k: Fighter, _h: bool) -> void:
			if _knocks == 0:
				_outs_before_knock += 1)


func _start(size: int) -> TeamArena:
	Game.team_match = TeamArena.offline_match(size, "training", 1)
	Game.goto_arena()
	await at.wait(1.0)
	var arena := get_tree().current_scene as TeamArena
	if arena == null:
		return null
	_watch(arena)
	Engine.time_scale = 3.0
	await at.wait_for_phase(arena, 1, 40.0)
	return arena


func _aim_at(p: Player, point: Vector3) -> void:
	var dir := (point - p.eye_position()).normalized()
	p.aim_yaw = atan2(-dir.x, -dir.z)
	p.aim_pitch = asin(clampf(dir.y, -1.0, 1.0))


func _squad() -> void:
	var arena := await _start(4)
	if arena == null or arena.phase != 1:
		_fail("TRAINING SQUAD never reached the fight")
		return
	var p := arena.player
	var mates := arena.members(p.team)
	var foes := arena.members(1 - p.team)
	at.log_line("squad: %d fighters, %d / %d, mode %s, round time %.0f" % [arena.fighters.size(), mates.size(), foes.size(), arena.mode, arena.time_left])
	if arena.fighters.size() != 8 or mates.size() != 4 or foes.size() != 4:
		_fail("TRAINING SQUAD is not 8 fighters, 4 a team")
		return
	for f in arena.fighters:
		if f != p:
			f.frozen = true
	var a1 := arena.slot_fighter(1)
	var e4 := foes[0]
	# The crosshair: an ally there gets nothing, an enemy there gets the assist.
	var fwd := Basis(Vector3.UP, p.aim_yaw) * Vector3.FORWARD
	var spot := arena.closest_nav_point(p.global_position + fwd * 7.0)
	var e_home := e4.global_position
	for who: Fighter in [a1, e4]:
		who.global_position = spot
		await at.wait(0.1)
		_aim_at(p, who.chest_position())
		await at.wait(0.4)
		_aim_at(p, who.chest_position())
		await at.wait(0.2)
		var tgt := p.assist_target
		at.log_line("crosshair on %s: assist %s, red %s" % [who.display_name, tgt.display_name if tgt else "none", p.crosshair_on_target])
		if who == a1 and (tgt != null or p.crosshair_on_target):
			_fail("an ally in the crosshair got the aim assist or the red crosshair")
		if who == e4 and tgt != e4 and not p.crosshair_on_target:
			_fail("an enemy in the crosshair got no assist (the check itself is off)")
		who.global_position = e_home if who == e4 else p.global_position + Basis(Vector3.UP, p.aim_yaw) * Vector3(1.3, 0.0, 0.0)
	await at.wait(0.2)
	# Friendly fire off, the own frag still hurts.
	if a1.take_damage(50.0, "body", p, p.global_position) != 0.0 or a1.hp != Fighter.MAX_HP:
		_fail("friendly fire took HP")
	if p.take_damage(10.0, "body", p, p.global_position, "frag") <= 0.0:
		_fail("the player's own frag did not hurt")
	# A knock, then the player's revive.
	a1.take_damage(9999.0, "head", e4, e4.global_position)
	await at.wait(0.2)
	at.log_line("ally knocked: %s, knock hp %.0f, status %s, knocks by %s: %d" % [a1.knocked, a1.knock_hp, arena.status_of(a1), e4.display_name, int(e4.stats.knocks)])
	if not a1.knocked or not a1.alive or arena.status_of(a1) != "knocked" or int(e4.stats.knocks) != 1:
		_fail("a teammate down with others UP is not KNOCKED")
	if arena.revive_candidate(p) != a1:
		_fail("the knocked teammate next to the player is no revive candidate")
	if not arena.start_revive(p, a1):
		_fail("the player could not start the revive")
	var t := 0.0
	while a1.knocked and t < 6.0:
		await at.wait(0.1)
		t += 0.1
	at.log_line("revive: knocked %s, hp %.0f, revives %d, after %.1f s (real)" % [a1.knocked, a1.hp, int(p.stats.revives), t])
	if a1.knocked or a1.hp != Fighter.REVIVE_HP or int(p.stats.revives) != 1:
		_fail("the revive did not stand the teammate up with REVIVE_HP")
	if t < Fighter.REVIVE_S / 3.0 - 0.3:
		_fail("the revive was quicker than REVIVE_S")
	# The pause menu pauses an offline match.
	arena.open_pause()
	await at.wait(0.3)
	var paused := get_tree().paused
	arena.close_pause()
	await at.wait(0.3)
	at.log_line("pause: paused %s, after closing %s" % [paused, get_tree().paused])
	if not paused or get_tree().paused:
		_fail("the pause menu does not pause this offline match (or stays paused)")
	# The player knocked (no gun), finished: out, the camera on a teammate still UP.
	p.take_damage(9999.0, "head", e4, e4.global_position)
	p.set_firing(true)
	var fired := p.firing
	p.set_firing(false)
	if not p.knocked or fired or p.perform_shot(p.eye_position(), Vector3.FORWARD):
		_fail("a knocked player can still fire")
	p.take_damage(9999.0, "head", e4, e4.global_position)
	await at.wait(0.8)
	var watched := arena.spectated()
	at.log_line("player out: alive %s, spectating %s" % [p.alive, watched.display_name if watched else "nobody"])
	if p.alive or watched == null or watched.team != p.team or not watched.alive or watched.knocked:
		_fail("once out, the camera does not follow a teammate still UP")
	# Three enemies knocked: the round goes on; the last one UP down wipes the team (a teammate
	# knocked just before stays down to the round's end: the next round stands it up).
	arena.rounds_to_win = 2
	var a2 := arena.slot_fighter(2)
	a2.take_damage(9999.0, "head", e4, e4.global_position)
	for e: Fighter in foes.slice(1):
		e.take_damage(9999.0, "head", a1, a1.global_position)
	await at.wait(0.3)
	if arena.phase != 1:
		_fail("the round ended while the other team still had a fighter UP")
	if foes.slice(1).any(func(e: Fighter) -> bool: return not e.knocked):
		_fail("enemies down with a teammate UP were not knocked")
	e4.take_damage(9999.0, "head", a1, a1.global_position)
	await at.wait(0.1)
	var wiped := foes.all(func(e: Fighter) -> bool: return not e.alive)
	at.log_line("last enemy down: team wiped %s, kills by %s: %d, knocks %d" % [wiped, a1.display_name, int(a1.stats.kills), int(a1.stats.knocks)])
	if not wiped or int(a1.stats.kills) != 4 or int(a1.stats.knocks) != 3:
		_fail("the last one UP down did not wipe the team (or the kills are off)")
	t = 0.0
	while arena.phase == 1 and t < 3.0:
		await at.wait(0.05)
		t += 0.05
	if not a2.knocked or arena.team_score != [1, 0] or arena.phase != 3:
		_fail("round 1 did not go to the player's team (score %s, phase %d)" % [str(arena.team_score), arena.phase])
	# Round 2: everyone back on their feet, then the other team wiped again.
	t = 0.0
	while not (arena.phase == 0 and arena.round_index == 2) and t < 20.0:
		await at.wait(0.2)
		t += 0.2
	Engine.time_scale = 3.0
	var reset_ok := arena.phase == 0 and arena.round_index == 2
	for f in arena.fighters:
		reset_ok = reset_ok and f.alive and not f.knocked and f.stance == Fighter.Stance.STAND and f.hp == Fighter.MAX_HP
	at.log_line("round 2: phase %d, everyone up and standing %s, %s %s" % [arena.phase, reset_ok, a2.display_name, Fighter.Stance.keys()[a2.stance]])
	if not reset_ok:
		_fail("the next round did not stand everyone up with full HP")
	await at.wait_for_phase(arena, 1, 30.0)
	for f in arena.fighters:
		if f != p:
			f.frozen = true
	for e: Fighter in foes.slice(1):
		e.take_damage(9999.0, "head", a1, a1.global_position)
	e4.take_damage(9999.0, "head", a1, a1.global_position)
	t = 0.0
	while not arena._result_shown and t < 20.0:
		await at.wait(0.25)
		t += 0.25
	Engine.time_scale = 1.0
	var r: Dictionary = Game.last_result
	var training: Dictionary = Game.profile.modes.get("training", {})
	at.log_line("squad result: shown %s, won %s, score %s, rows %d, mode %s, training matches %d" % [arena._result_shown, r.get("won"),
		str(arena.team_score), (r.get("rows", []) as Array).size(), r.get("mode_id"), int(training.get("matches", 0))])
	if not arena._result_shown or not bool(r.get("won", false)) or not bool(r.get("team", false)) or arena.team_score != [2, 0]:
		_fail("the SQUAD match did not end in a 2-0 win with team results")
	if (r.get("rows", []) as Array).size() != 8 or String(r.get("mode_id", "")) != "training" or int(training.get("matches", 0)) != 1:
		_fail("the results rows or the profile's TRAINING count are off")
	if _outs_before_knock > 0:
		_fail("someone was out before any knock")


func _duo() -> void:
	var arena := await _start(2)
	if arena == null or arena.phase != 1:
		_fail("TRAINING DUO never reached the fight")
		return
	at.log_line("duo: %d fighters, round time %.0f" % [arena.fighters.size(), arena.time_left])
	# A bot revives its knocked teammate when no enemy is in sight (the others held still).
	var foes := arena.members(1 - arena.player.team)
	for f in arena.fighters:
		if f != arena.player:
			f.frozen = true
	foes[0].take_damage(9999.0, "head", arena.player, arena.player.global_position)
	foes[1].frozen = false
	var t := 0.0
	while foes[0].knocked and t < 8.0:
		await at.wait(0.1)
		t += 0.1
	at.log_line("bot revive: knocked %s, hp %.0f, revives by %s: %d, after %.1f s (real)" % [foes[0].knocked, foes[0].hp,
		foes[1].display_name, int(foes[1].stats.revives), t])
	if foes[0].knocked or foes[0].hp != Fighter.REVIVE_HP or int(foes[1].stats.revives) != 1:
		_fail("a bot did not revive its knocked teammate")
	for f in arena.fighters:
		f.frozen = false
	t = 0.0
	while not arena._result_shown and t < 70.0:
		await at.wait(0.5)
		t += 0.5
	Engine.time_scale = 1.0
	var r: Dictionary = Game.last_result
	var stats := []
	for f in arena.fighters:
		stats.append("%s k%d kn%d rv%d dmg%d" % [f.display_name, int(f.stats.kills), int(f.stats.knocks), int(f.stats.revives), roundi(f.stats.damage)])
	at.log_line("duo result after %.0f s: shown %s, score %s, rows %d, %s" % [t, arena._result_shown, str(arena.team_score),
		(r.get("rows", []) as Array).size(), ", ".join(stats)])
	if not arena._result_shown or (r.get("rows", []) as Array).size() != 4 or int(Game.profile.matches) != 2:
		_fail("the DUO match did not play to its results")


func _fail(what: String) -> void:
	bad += 1
	at.log_line("FAIL " + what)


func _done(error: String) -> int:
	if error != "":
		_fail(error)
	at.log_line("TEAM OFFLINE CHECK DONE bad=%d" % bad)
	return bad

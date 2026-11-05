extends Node
## The two phones agree on every round (the host decides them: Arena._net_decide, "rend"), with
## two copies of the game (LW_NET_ROLE host / guest) through tests/mqtt_mock.gd holding every
## message 300 ms (a 600 ms round trip, as between two phones on a slow relay; tools/qa/run_checks.sh
## step "sync", first to 2 rounds):
## - round 1: both players die in the zone about together (each phone's own, 2 s into the fight):
##   no kill credit for either; the round ends the same way on both;
## - round 2: the guest opens its pause menu: online the match runs on under it (its clock does not
##   stop); the host shoots the guest down (a real kill, credited), which closes the guest's menu;
## - round 3 (if one is still needed): the guest dies in the zone, nobody's kill.
## Each copy writes the match as the host sees it (score, winner, rounds, kills) to LW_SYNC_OUT;
## the step compares the two files. Prints "SYNC CHECK DONE bad=N".

var bad := 0
var at: Node
var host := false


func run(autotest: Node) -> int:
	at = autotest
	host = OS.get_environment("LW_NET_ROLE") == "host"
	var cloud := Game.cloud_service()
	cloud.start_lobby()
	var started := [false]
	cloud.session_started.connect(func(_h: bool) -> void: started[0] = true)
	if not host:
		cloud.invited.connect(func(_who: String) -> void: cloud.answer(true))
	if host:
		if not await _until(func() -> bool: return not cloud.peers.is_empty() and cloud.status == "online", 40.0):
			return _done("the guest was never discovered")
		if not cloud.invite(String(cloud.peers.keys()[0])):
			return _done("invite failed")
	if not await _until(func() -> bool: return started[0], 50.0):
		return _done("no session")
	if not await _until(func() -> bool: return get_tree().current_scene != null and get_tree().current_scene.name == "Arena", 40.0):
		return _done("the lobby never started the match")
	var arena: Node = get_tree().current_scene
	var p: Fighter = arena.get("player")
	var b: Fighter = arena.get("bot")
	var outcomes := []
	var r := 1
	while is_instance_valid(arena) and not bool(arena.get("_result_shown")):
		if not await _until(func() -> bool: return int(arena.get("round_index")) == r and arena.get("phase") == 1, 40.0):
			return _done("round %d never began its fight" % r)
		if r == 1:
			await at.wait(2.0)
			p.take_damage(999.0, "zone", null, p.global_position, "zone")      # both in the zone, ~together
		elif r == 2:
			if not host:
				var e0 := float(arena.get("elapsed"))
				arena.call("open_pause")
				await at.wait(2.0)
				var ran := float(arena.get("elapsed")) - e0
				at.log_line("guest paused: the match clock ran %.2f s under the menu, tree paused %s" % [ran, get_tree().paused])
				if ran < 1.5 or get_tree().paused or _pause_menus(arena) != 1:
					_fail("online, the pause menu stopped the match clock")
			else:
				await at.wait(3.0)
				await _shoot_down(arena, p, b)
		elif not host:
			await at.wait(1.0)
			p.take_damage(999.0, "zone", null, p.global_position, "zone")
		if not await _until(func() -> bool: return arena.get("phase") == 3 or arena.get("phase") == 2, 30.0):
			return _done("round %d never ended" % r)
		var rsc: Dictionary = arena.get("score")
		var line := "r%d %d:%d" % [r, int(rsc.player if host else rsc.bot), int(rsc.bot if host else rsc.player)]
		outcomes.append(line)
		at.log_line("round %d over: %s, kills me %d, phase %d" % [r, line, int(p.stats.kills), int(arena.get("phase"))])
		if r == 2 and not host:
			await at.wait(0.3)
			if _pause_menus(arena) != 0:
				_fail("the round's end did not close the online pause menu")
		if arena.get("phase") == 2:
			break
		r += 1
	if not await _until(func() -> bool: return is_instance_valid(arena) and bool(arena.get("_result_shown")), 20.0):
		return _done("the match never showed its result")
	var sc: Dictionary = arena.get("score")
	var w: Variant = arena.get("_winner")
	var winner := "draw" if bool(arena.get("_draw")) else ("host" if (w == p) == host else "guest")
	var res: Dictionary = arena.get("result")
	var host_kills := int(p.stats.kills) if host else -1
	var guest_kills := int(p.stats.kills) if not host else -1
	at.log_line("match: %s; %s; winner %s; kills %d; result score %d:%d" % [str(outcomes), str(sc), winner, int(p.stats.kills),
		int(res.get("score_player", -1)), int(res.get("score_bot", -1))])
	# Kill credit: only the host's shots in round 2 took the guest out; the zone credits nobody.
	if host and host_kills != (1 if r >= 2 else 0):
		_fail("the host's kills (%d) count something else than its one real kill" % host_kills)
	if not host and guest_kills != 0:
		_fail("the guest got kill credit (%d) for deaths in the zone" % guest_kills)
	if int(res.get("score_player", -1)) != int(sc.player) or int(res.get("score_bot", -1)) != int(sc.bot):
		_fail("the results screen shows another score than the match")
	var summary := "rounds %d; %s; final %d:%d; winner %s\n" % [int(arena.get("round_index")), " ".join(outcomes),
		int(sc.player if host else sc.bot), int(sc.bot if host else sc.player), winner]
	var out := OS.get_environment("LW_SYNC_OUT")
	if out != "":
		var f := FileAccess.open(out, FileAccess.WRITE)
		if f:
			f.store_string(summary)
			f.close()
	at.log_line("as the host sees it: " + summary.strip_edges())
	await at.wait(1.5)
	return _done("")


func _pause_menus(arena: Node) -> int:
	var n := 0
	for c in (arena.get("pause_layer") as Node).get_children():
		n += 1 if c is PauseMenu and not c.is_queued_for_deletion() else 0
	return n


## The host lands real headshots (one bullet each, at the gun's rate) until the guest goes down.
func _shoot_down(arena: Node, shooter: Fighter, target: Fighter) -> void:
	var d: Dictionary = Weapons.DEFS[String(arena.call("_round_gun"))]
	var hit := float(d.damage) * float(d.head_mult) * Weapons.pen_mult(d, "head")
	for _i in 30:
		if not target.alive or arena.get("phase") != 1:
			return
		target.take_damage(hit, "head", shooter, shooter.global_position)
		await at.wait(maxf(float(d.interval), 0.12))


## Waits (game time) until cond() is true or `seconds` pass; returns whether it came true.
func _until(cond: Callable, seconds: float) -> bool:
	var t := 0.0
	while not cond.call() and t < seconds:
		await at.wait(0.1)
		t += 0.1
	return cond.call()


func _fail(what: String) -> void:
	bad += 1
	at.log_line("FAIL " + what)


func _done(error: String) -> int:
	if error != "":
		_fail(error)
	at.log_line("SYNC CHECK DONE bad=%d" % bad)
	return bad

extends Node
## The two phones agree on every round (the host decides them: Arena._net_decide, "rend"), with
## two copies of the game (LW_NET_ROLE host / guest) through tests/mqtt_mock.gd holding every
## message 300 ms (a 600 ms round trip, as between two phones on a slow relay; tools/qa/run_checks.sh
## step "sync", first to 2 rounds):
## - round 1: both players die in the zone about together (each phone's own, 2 s into the fight):
##   no kill credit for either; the round ends the same way on both;
## - round 2: the guest opens its pause menu: online the match runs on under it (its clock does not
##   stop); the host shoots the guest down (a real kill, credited), which closes the guest's menu;
## - round 3 (if one is still needed): the guest dies in the zone, nobody's kill: the host shows the
##   zone's line, not the elimination badge (that only for its real kill in round 2).
## The guest is made to believe the match lasts a round longer: the host's word ("fin") ends it.
## Each copy writes the match as the host sees it (score, winner, rounds, kills, and both rows of
## its results table: the guest shows the host's time and HP, each row the numbers of that
## player's own phone) to LW_SYNC_OUT; the step compares the two files. Prints "SYNC CHECK DONE bad=N".

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
	if not host:
		# The guest believes the match lasts longer than the host does: the host still decides when
		# it ends (its "fin"), and both phones end it alike.
		arena.set("rounds_to_win", int(arena.get("rounds_to_win")) + 1)
	var outcomes := []
	var r := 1
	while is_instance_valid(arena) and not bool(arena.get("_result_shown")):
		if not await _until(func() -> bool: return (int(arena.get("round_index")) == r and arena.get("phase") == 1) or arena.get("phase") == 2, 40.0):
			return _done("round %d never began its fight" % r)
		if arena.get("phase") == 2:
			break
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
		var banner := (arena.get("hud") as HUD).banner_kind()
		at.log_line("round %d over: %s, kills me %d, phase %d, banner \"%s\"" % [r, line, int(p.stats.kills), int(arena.get("phase")), banner])
		# The winner's banner: the elimination badge only for a real kill (round 2, the host's); the
		# guest down in the zone (round 3) is nobody's kill: the zone's own line, never ELIMINATED.
		if host and r == 2 and banner != "kill":
			_fail("the host's kill in round 2 did not show the elimination badge")
		if host and r == 3 and banner != "zone":
			_fail("the guest down in the zone showed \"%s\", not the zone's line" % banner)
		if not host and r >= 2 and banner != "":
			_fail("the guest, down in round %d, shows a banner \"%s\"" % [r, banner])
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
	# The results table as each phone shows it, the host's row first: both must read the same (the
	# guest takes the time and the HP from the host, each row's numbers come from that player's phone).
	var screen: Node = (arena.get("pause_layer") as Node).find_child("Stats", true, false)
	var mine := _row_text(screen, "YourRow")
	var theirs := _row_text(screen, "EnemyRow")
	var summary := "rounds %d; %s; final %d:%d; winner %s; host row %s; guest row %s\n" % [int(arena.get("round_index")), " ".join(outcomes),
		int(sc.player if host else sc.bot), int(sc.bot if host else sc.player), winner, mine if host else theirs, theirs if host else mine]
	if mine == "" or theirs == "":
		_fail("the results table is missing a row")
	var fin: Dictionary = arena.get("_their_final")
	if fin.is_empty() or (not host and float(fin.get("time", -1.0)) < 0.0):
		_fail("the other phone's end-of-match numbers (\"fin\") never came")
	if not host:
		var goal := int(arena.get("rounds_to_win"))
		var own_rule := int(sc.player) >= goal or int(sc.bot) >= goal or int(arena.get("round_index")) >= mini(2 * goal - 1, 9)
		at.log_line("the guest's own count (first to %d) %s the match over: %s" % [goal, "said" if own_rule else "did not say",
			"its own rule" if own_rule else "the host's word ended it"])
	var out := OS.get_environment("LW_SYNC_OUT")
	if out != "":
		var f := FileAccess.open(out, FileAccess.WRITE)
		if f:
			f.store_string(summary)
			f.close()
	at.log_line("as the host sees it: " + summary.strip_edges())
	await at.wait(1.5)
	return _done("")


## A results table row's numbers as shown (ELIMINATIONS .. HP LEFT), "" without the row.
func _row_text(table: Node, row_name: String) -> String:
	var row := table.find_child(row_name, true, false) if table else null
	if row == null:
		return ""
	var parts := PackedStringArray()
	for c in ResultsScreen.COLUMNS:
		var l := row.find_child("Value_" + String(c).replace(" ", "_"), true, false) as Label
		parts.append(l.text if l else "?")
	return " ".join(parts)


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

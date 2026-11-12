extends Node
## A match over several rounds against the bot (run with LW_ROUNDS_TO_WIN=2): each round ends
## with an elimination; the next one puts both back at their spawns with full HP, items,
## collisions and the full kit (the gun in hand, the sidearm spent in round 1 refilled); the gun is picked every two rounds by alternating sides (round 3 is the bot's
## pick, and both hold that gun, never the one of rounds 1-2, which rests on its cooldown); each
## fight starts in stage 1 of the two-stage clock (00:20); the player's elimination in round 2 fills
## the ELIMINATED BY card (the bot, its gun, the 200 damage it dealt); the match ends at 2 wins with the right result, which the
## profile's HISTORY and CAREER hold as played. Then a second match, quit with QUIT MATCH in
## round 2: HISTORY says LEFT (a defeat) with the round won before, CAREER counts it, no win.
## Prints one line per round and "ROUNDS CHECK DONE bad=N".

var bad := 0
var at: Node


func run(autotest: Node) -> int:
	at = autotest
	Game.goto_arena()
	await at.wait(1.0)
	var arena: Node = get_tree().current_scene
	var p: Fighter = arena.get("player")
	var b: Fighter = arena.get("bot")
	var map: MapBuilder = arena.get("map")
	Engine.time_scale = 3.0
	var first_gun := ""
	# Round 1: the bot goes down; round 2: the player; round 3 (the bot's pick): the bot.
	for r in [1, 2, 3]:
		await at.wait_for_phase(arena, 1, 60.0)
		if arena.get("phase") != 1 or int(arena.get("round_index")) != r:
			return _done("round %d never started (phase %d, round %d)" % [r, arena.get("phase"), arena.get("round_index")])
		var gun_p := String(p.gun().id)
		var gun_b := String(b.gun().id)
		at.log_line("round %d: hp %.0f / %.0f, guns %s / %s, picked %s, score %s" % [r, p.hp, b.hp, gun_p, gun_b, arena.get("picked_weapon"), str(arena.get("score"))])
		if r > 1:
			if not p.alive or not b.alive or p.hp < Fighter.MAX_HP or b.hp < Fighter.MAX_HP:
				_fail("round %d: the fighters were not reset (alive %s/%s)" % [r, p.alive, b.alive])
			if p.medkits != 2 or p.shields != Fighter.START_SHIELDS or b.grenades != 1:
				_fail("round %d: the items were not refilled" % r)
			if p.global_position.distance_to(map.spawn_a) > 3.0 or b.global_position.distance_to(map.spawn_b) > 4.0:
				_fail("round %d: not back at the spawns" % r)
			if b.collision_layer != Fighter.LAYER_BODY or b.hitboxes[0].collision_layer != Fighter.LAYER_HITBOX:
				_fail("round %d: collisions not back on" % r)
			for f: Fighter in [p, b]:
				if f.weapons.size() != 3 or f.current != Weapons.GUN or f.sidearm() == null or f.sidearm().id != Weapons.SIDEARM \
						or f.sidearm().ammo != 12 or f.sidearm().reserve != int(Weapons.DEFS[Weapons.SIDEARM].reserve):
					_fail("round %d: %s's kit was not given back full (%d weapons, holding %d)" % [r, f.display_name, f.weapons.size(), f.current])
		if gun_p != gun_b:
			_fail("round %d: the fighters hold different guns" % r)
		if r == 3 and String(arena.get("picked_weapon")) == "":
			_fail("round 3: the bot never picked the gun")
		if r == 1:
			first_gun = gun_p
		if r == 3 and gun_p == first_gun:
			_fail("round 3: the bot picked %s, which rests after rounds 1-2" % gun_p)
		if int(arena.call("stage")) != 1 or HudDraw.time_text(float(arena.call("stage_left"))) not in ["00:20", "00:19"]:
			_fail("round %d: the fight did not start in stage 1 (stage %d, %.1f s)" % [r, arena.call("stage"), arena.call("stage_left")])
		if r == 1:
			p.switch_weapon(Weapons.SIDE)        # the sidearm partly spent: the next round refills it
			p.sidearm().ammo = 3
			b.switch_weapon(Weapons.FISTS)
		await at.wait(0.6)
		var victim := p if r == 2 else b
		var killer := b if r == 2 else p
		victim.take_damage(9999.0, "head", killer, killer.global_position)
		var wait_end := 0.0
		while arena.get("phase") == 1 and wait_end < 10.0:
			await at.wait(0.1)
			wait_end += 0.1
		if r == 2:
			var e: Dictionary = arena.get("eliminated_by")
			at.log_line("round 2: eliminated by %s" % str(e))
			if String(e.get("cause", "")) != "gun" or String(e.get("name", "")) != b.display_name or int(e.get("damage", 0)) != 200 \
					or String(e.get("gun", "")) != String(b.gun().def.name):
				_fail("round 2: the ELIMINATED BY card does not name the bot, its gun and its 200 damage")
	var t := 0.0
	while not arena.get("_result_shown") and t < 30.0:
		await at.wait(0.25)
		t += 0.25
	Engine.time_scale = 1.0
	var sc: Dictionary = arena.get("score")
	at.log_line("result: score %s, winner %s, won %s" % [str(sc), "player" if arena.get("_winner") == p else "other", Game.last_result.get("won")])
	if not arena.get("_result_shown"):
		return _done("results never shown")
	if int(sc.player) != 2 or int(sc.bot) != 1 or arena.get("_winner") != p or not bool(Game.last_result.get("won", false)):
		_fail("the match result is wrong")
	# The profile (an automated run starts from a new one): the match in HISTORY, and CAREER with
	# the player's one death (round 2) and the numbers of their stats (the kills here are scripted,
	# not shot: their stats count none).
	var kills := int(p.stats.kills)
	var h := _last_match()
	var prof: Dictionary = Game.profile
	at.log_line("history: %s; matches %d, wins %d, deaths %d, rounds %d-%d" % [str(h), prof.matches, prof.wins, prof.deaths,
		prof.rounds_won, prof.rounds_lost])
	if (h.get("result") != "won" or h.get("mode") != "training" or h.get("enemy") != Game.clean_name(b.display_name) or h.get("id") != ""
			or h.get("score") != 2 or h.get("enemy_score") != 1 or h.get("kills") != kills):
		_fail("HISTORY does not hold the match as played")
	if prof.matches != 1 or prof.wins != 1 or prof.deaths != 1 or prof.kills != kills or prof.rounds_won != 2 or prof.rounds_lost != 1:
		_fail("CAREER does not count the match as played")
	# QUIT MATCH in round 2 of the next match (round 1 won).
	Game.goto_arena()
	await at.wait(1.0)
	arena = get_tree().current_scene
	p = arena.get("player")
	b = arena.get("bot")
	Engine.time_scale = 3.0
	await at.wait_for_phase(arena, 1, 60.0)
	await at.wait(0.6)
	b.take_damage(9999.0, "head", p, p.global_position)
	t = 0.0
	while not (arena.get("phase") == 1 and int(arena.get("round_index")) == 2) and t < 60.0:
		await at.wait(0.25)
		t += 0.25
	Engine.time_scale = 1.0
	if int(arena.get("round_index")) != 2:
		return _done("the second match never reached round 2")
	kills += int(p.stats.kills)
	arena.call("open_pause")
	await at.wait(0.3)
	var pm := arena.find_child("PauseMenu", true, false)
	if pm == null:
		return _done("no pause menu")
	var quit := pm.find_child("Quit", true, false) as Button
	if quit == null:
		return _done("the in-match settings have no QUIT MATCH")
	quit.pressed.emit()                    # QUIT MATCH (TRAINING GROUND: one tap; online it asks first)
	t = 0.0
	while (get_tree().current_scene == arena or get_tree().current_scene == null or get_tree().current_scene.name != "Lobby") and t < 20.0:
		await at.wait(0.25)
		t += 0.25
	h = _last_match()
	at.log_line("after QUIT MATCH: %s; matches %d, wins %d" % [str(h), prof.matches, prof.wins])
	if h.get("result") != "left" or h.get("score") != 1 or h.get("enemy_score") != 0:
		_fail("a match left with QUIT MATCH is not in HISTORY as LEFT")
	if prof.matches != 2 or prof.wins != 1 or prof.kills != kills or prof.rounds_won != 3 or (prof.history as Array).size() != 2:
		_fail("CAREER and HISTORY disagree about the match left")
	return _done("")


## The profile's newest HISTORY entry ({} when there is none).
func _last_match() -> Dictionary:
	var history: Array = Game.profile.history
	return history[0] if not history.is_empty() else {}


func _fail(what: String) -> void:
	bad += 1
	at.log_line("FAIL " + what)


func _done(error: String) -> int:
	if error != "":
		_fail(error)
	at.log_line("ROUNDS CHECK DONE bad=%d" % bad)
	return bad

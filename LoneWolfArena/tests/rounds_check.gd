extends Node
## A match over several rounds against the bot (run with LW_ROUNDS_TO_WIN=2): each round ends
## with an elimination; the next one puts both back at their spawns with full HP, items and
## collisions; the gun is picked every two rounds by alternating sides (round 3 is the bot's
## pick, and both hold that gun); the match ends at 2 wins with the right result.
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
			if p.medkits != 2 or p.shields != 2 or b.grenades != 1:
				_fail("round %d: the items were not refilled" % r)
			if p.global_position.distance_to(map.spawn_a) > 3.0 or b.global_position.distance_to(map.spawn_b) > 4.0:
				_fail("round %d: not back at the spawns" % r)
			if b.collision_layer != Fighter.LAYER_BODY or b.hitboxes[0].collision_layer != Fighter.LAYER_HITBOX:
				_fail("round %d: collisions not back on" % r)
		if gun_p != gun_b:
			_fail("round %d: the fighters hold different guns" % r)
		if r == 3 and String(arena.get("picked_weapon")) == "":
			_fail("round 3: the bot never picked the gun")
		await at.wait(0.6)
		var victim := p if r == 2 else b
		var killer := b if r == 2 else p
		victim.take_damage(9999.0, "head", killer, killer.global_position)
		var wait_end := 0.0
		while arena.get("phase") == 1 and wait_end < 10.0:
			await at.wait(0.1)
			wait_end += 0.1
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
	return _done("")


func _fail(what: String) -> void:
	bad += 1
	at.log_line("FAIL " + what)


func _done(error: String) -> int:
	if error != "":
		_fail(error)
	at.log_line("ROUNDS CHECK DONE bad=%d" % bad)
	return bad

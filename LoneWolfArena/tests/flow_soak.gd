extends Node
## Long-session stability: lobby -> match -> results -> lobby, N times in ONE process, watching
## object / node / memory counts for leaks (headless is fine):
##   LW_ROUNDS=8 godot --headless --path . -- --autotest=script:res://tests/flow_soak.gd
## Each match: prep (weapon pick timer), fight until the bot is killed (alternating with the
## player being killed or a time-out), results screen, back to the lobby.
## Prints one line per round and "FLOW SOAK DONE bad=N".

var bad := 0
var at: Node


func run(autotest: Node) -> int:
	at = autotest
	var rounds := maxi(int(OS.get_environment("LW_ROUNDS")), 1) if OS.get_environment("LW_ROUNDS") != "" else 6
	var base_nodes := 0
	var base_objects := 0
	var base_mem := 0
	for i in rounds:
		Game.goto_arena()
		await at.wait(1.0)
		var arena: Node = get_tree().current_scene
		Engine.time_scale = 4.0
		await at.wait_for_phase(arena, 1, 60.0)
		if arena.get("phase") != 1:
			_fail("round %d: never reached FIGHT" % i)
			break
		var p: Fighter = arena.get("player")
		var b: Fighter = arena.get("bot")
		await at.wait(1.5)
		match i % 3:
			0:
				b.take_damage(9999.0, "head", p, p.global_position)
			1:
				p.take_damage(9999.0, "body", b, b.global_position)
			_:
				p.invulnerable = true
				b.invulnerable = true
		var t := 0.0
		while not arena.get("_result_shown") and t < 200.0:
			await at.wait(0.5)
			t += 0.5
		Engine.time_scale = 1.0
		if not arena.get("_result_shown"):
			_fail("round %d: results never shown" % i)
			break
		await at.wait(0.8)
		Game.goto_lobby()
		await at.wait(1.5)
		var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		var objects := int(Performance.get_monitor(Performance.OBJECT_COUNT))
		var orphans := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
		var mem := int(Performance.get_monitor(Performance.MEMORY_STATIC))
		if i == 1:      # round 0 warms caches (shared clips, weapon scenes, textures)
			base_nodes = nodes
			base_objects = objects
			base_mem = mem
		at.log_line("round %d (%s): nodes=%d objects=%d orphans=%d static_mem=%.1f MB" % [
			i, ["bot killed", "player killed", "time-out"][i % 3], nodes, objects, orphans, mem / 1048576.0])
		if orphans > 0:
			_fail("round %d: %d orphan nodes" % [i, orphans])
	if rounds >= 4:
		var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		var objects := int(Performance.get_monitor(Performance.OBJECT_COUNT))
		var mem := int(Performance.get_monitor(Performance.MEMORY_STATIC))
		if nodes > base_nodes + 5:
			_fail("node count grew from %d to %d across rounds" % [base_nodes, nodes])
		if objects > base_objects + 400:
			_fail("object count grew from %d to %d across rounds" % [base_objects, objects])
		if mem > base_mem + 24 * 1048576:
			_fail("static memory grew %.1f MB across rounds" % ((mem - base_mem) / 1048576.0))
	at.log_line("FLOW SOAK DONE bad=%d" % bad)
	return bad


func _fail(what: String) -> void:
	bad += 1
	at.log_line("FAIL " + what)

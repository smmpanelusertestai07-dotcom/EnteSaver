extends Node
## Bot behaviour check (headless is fine):
##   godot --headless --path . -- --autotest=script:res://tests/bot_check.gd
## - a solved grenade arc lands near the point the bot threw it at
## - the bot gets into the safe zone while it closes and is still alive inside it at the end
##   (the player is invulnerable and stands still, so the match runs to the time limit)
## Prints "BOT CHECK DONE bad=N" and exits with N.

var bad := 0
var at: Node


func run(autotest: Node) -> int:
	at = autotest
	Game.settings.difficulty = 1
	Game.goto_arena()
	await at.wait(1.0)
	var arena: Node = get_tree().current_scene
	await at.wait_for_phase(arena, 1, 40.0)
	var p: Fighter = arena.get("player")
	var b: Bot = arena.get("bot")
	_expect(p != null and b != null and arena.get("phase") == 1, "arena reached FIGHT")
	if p == null or b == null:
		return _done()
	await _check_grenade_arc(arena, b)
	await _check_zone(arena, p, b)
	return _done()


func _done() -> int:
	at.log_line("BOT CHECK DONE bad=%d" % bad)
	return bad


func _expect(ok: bool, what: String) -> void:
	if not ok:
		bad += 1
	at.log_line(("ok   " if ok else "FAIL ") + what)


func _check_grenade_arc(arena: Node, b: Bot) -> void:
	# Aim at a floor point ~12 m in front of the bot (the closest walkable spot to it).
	var fwd := -b.global_basis.z
	fwd.y = 0.0
	var goal: Vector3 = arena.closest_nav_point(b.global_position + fwd.normalized() * 12.0)
	var before := _grenades()
	_expect(b.throw_grenade(goal), "bot throw accepted")
	await at.wait(Fighter.THROW_RELEASE + 0.1)
	var g: Grenade = null
	for c in get_tree().current_scene.get_children():
		if c is Grenade and not before.has(c):
			g = c
	_expect(g != null, "grenade released")
	if g == null:
		return
	var landed := Vector3.INF
	var t := 0.0
	while is_instance_valid(g) and t < 2.8:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		if g.linear_velocity.y < 0.0 and g.global_position.y < goal.y + 0.35:
			landed = g.global_position
			break
	if landed == Vector3.INF:
		_expect(false, "grenade landed within 2.5 s")
		return
	var miss := Vector2(landed.x - goal.x, landed.z - goal.z).length()
	_expect(miss < 2.0, "grenade lands near the aimed point (miss %.2f m over %.1f m)" % [miss, b.global_position.distance_to(goal)])
	await at.wait(3.0)      # let it go off before the zone test


func _check_zone(arena: Node, p: Fighter, b: Bot) -> void:
	p.invulnerable = true
	p.frozen = true
	b.hp = Fighter.MAX_HP
	Engine.time_scale = 4.0
	var outside_late := 0.0
	var worst_r := 0.0
	while arena.get("phase") == 1 and b.alive:
		await get_tree().physics_frame
		var dt := get_physics_process_delta_time()
		var c: Vector3 = arena.zone_center
		var r: float = arena.zone_radius
		var d := Vector2(b.global_position.x - c.x, b.global_position.z - c.z).length()
		if String(arena.zone_state) != "stationary":
			worst_r = maxf(worst_r, d - r)
			if d > r:
				outside_late += dt
		if OS.get_environment("LW_DEBUG") != "" and Engine.get_physics_frames() % 30 == 0:
			at.log_line("dbg t=%.1f state=%s r=%.1f d=%.2f goal=%s bot=%s c=%s st=%d" % [arena.get("elapsed"), arena.zone_state, r, d, str(b._zone_goal), str(b.global_position), str(c), b.state])
	Engine.time_scale = 1.0
	_expect(b.alive, "bot survived to the end of the round (zone + shots), hp %d" % roundi(b.hp))
	_expect(outside_late < 4.0, "bot spent %.1f s outside the closing zone" % outside_late)
	_expect(worst_r < 2.5, "bot was never more than %.1f m outside the edge" % worst_r)


func _grenades() -> Array:
	var out := []
	for c in get_tree().current_scene.get_children():
		if c is Grenade:
			out.append(c)
	return out

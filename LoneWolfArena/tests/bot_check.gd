extends Node
## Bot behaviour check (headless is fine):
##   godot --headless --path . -- --autotest=script:res://tests/bot_check.gd
## - a solved grenade arc lands near the point the bot threw it at
## - the bot gets into the safe zone while it closes and is still alive inside it at the end
##   (the player is invulnerable and stands still, so the match runs to the time limit)
## - the player's camera (run first, the bot held still): in the open the crosshair's ray passes
##   clear of the own body, the head below and left of the crosshair; beside and in front of every
##   container side (it at the right, it behind) the camera is never inside a wall, never at the
##   head with the model shown, and the body never covers the crosshair without being see-through
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
	await _check_camera(arena, p as Player, b)
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
	# A floor spot 7-13 m from the bot with an open lane for the arc (the map has plenty of
	# cover, which would make the bounce, not the aim, decide where it lands).
	var goal := Vector3.INF
	for dist in [10.0, 12.0, 8.0]:
		for ang in [0.0, 30.0, -30.0, 60.0, -60.0, 90.0, -90.0, 135.0, -135.0, 180.0]:
			var dir := (-b.global_basis.z).rotated(Vector3.UP, deg_to_rad(ang))
			dir.y = 0.0
			var p: Vector3 = arena.closest_nav_point(b.global_position + dir.normalized() * dist)
			var d := Vector2(p.x - b.global_position.x, p.z - b.global_position.z).length()
			if d < 7.0 or d > 13.0 or absf(p.y - b.global_position.y) > 0.8:     # nav points sit ~0.5 m up
				continue
			if _lane_clear(b, b.eye_position(), p + Vector3.UP * 0.3) and _lane_clear(b, b.eye_position(), (b.eye_position() + p) * 0.5 + Vector3.UP * 2.5) \
					and _lane_clear(b, (b.eye_position() + p) * 0.5 + Vector3.UP * 2.5, p + Vector3.UP * 0.3):
				goal = p
				break
		if goal != Vector3.INF:
			break
	_expect(goal != Vector3.INF, "found an open throwing lane")
	if goal == Vector3.INF:
		return
	var before := _grenades()
	var throw_dist := Vector2(goal.x - b.global_position.x, goal.z - b.global_position.z).length()
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
	_expect(miss < 2.0, "grenade lands near the aimed point (miss %.2f m on a %.1f m throw)" % [miss, throw_dist])
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


## The over-the-shoulder camera and its collision (see the header).
func _check_camera(arena: Node, p: Player, b: Bot) -> void:
	b.process_mode = Node.PROCESS_MODE_DISABLED
	p.invulnerable = true
	p.frozen = true
	var home := p.global_position
	var home_yaw := p.aim_yaw
	var vs := get_viewport().get_visible_rect().size
	var mid := vs * 0.5
	var open_bad := PackedStringArray()
	for pitch in [0.0, -25.0, 25.0]:
		p.aim_pitch = deg_to_rad(pitch)
		await _settle_camera()
		var head := p.camera.unproject_position(p.head_position())
		if p.covers_crosshair(0.0) or p._faded or not p.model.visible or head.x >= mid.x - vs.y * 0.05 or head.y <= mid.y:
			open_bad.append("pitch %d: covers %s, head at %s of %s" % [pitch, p.covers_crosshair(0.0), str(head), str(vs)])
	_expect(open_bad.is_empty(), "in the open the crosshair passes clear of the body, the head below-left of it %s" % open_bad)
	p.aim_pitch = 0.0
	var q := PhysicsShapeQueryParameters3D.new()
	var sph := SphereShape3D.new()
	q.shape = sph
	q.collision_mask = Fighter.LAYER_WORLD | Fighter.LAYER_SHIELD
	q.exclude = [p.get_rid()]
	var space := p.get_world_3d().direct_space_state
	var samples := 0
	var in_wall := PackedStringArray()
	var at_head := PackedStringArray()
	var covered := PackedStringArray()
	var pulled := 0
	for r: Rect2 in arena.get("obstacles"):
		if samples >= 28:
			break
		var c := r.get_center()
		# Each side's middle, 0.45 m out; facing along the side (it at the right) or away from it.
		for side: Array in [[Vector2(r.position.x - 0.45, c.y), Vector2(0, -1)], [Vector2(r.end.x + 0.45, c.y), Vector2(0, 1)],
				[Vector2(c.x, r.position.y - 0.45), Vector2(1, 0)], [Vector2(c.x, r.end.y + 0.45), Vector2(-1, 0)]]:
			var spot := Vector3((side[0] as Vector2).x, home.y, (side[0] as Vector2).y)
			sph.radius = 0.3
			q.transform = Transform3D(Basis.IDENTITY, spot + Vector3.UP * 1.0)
			var floor_hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(spot + Vector3.UP * 0.6, spot + Vector3.DOWN * 0.6, Fighter.LAYER_WORLD))
			if not space.intersect_shape(q, 1).is_empty() or floor_hit.is_empty() or absf((floor_hit.position as Vector3).y - home.y) > 0.3 \
					or not (arena.get("map_rect") as Rect2).has_point(Vector2(spot.x, spot.z)):
				continue
			var fwd := side[1] as Vector2
			var out := Vector2(spot.x - c.x, spot.z - c.y).normalized()
			for yaw: float in [atan2(-fwd.x, -fwd.y), atan2(out.x, out.y) + PI]:
				p.global_position = spot
				p.velocity = Vector3.ZERO
				p.aim_yaw = yaw
				await _settle_camera()
				samples += 1
				var cam := p.camera.global_position
				sph.radius = 0.1
				q.transform = Transform3D(Basis.IDENTITY, cam)
				var tag := "%s yaw %d" % [str(spot.snapped(Vector3.ONE * 0.1)), roundi(rad_to_deg(yaw))]
				if not space.intersect_shape(q, 1).is_empty():
					in_wall.append(tag)
				if p.model.visible and cam.distance_to(p.head_position()) < Player.HEAD_CLEAR:
					at_head.append(tag)
				if p.model.visible and p.covers_crosshair(0.0) and not p._faded:
					covered.append(tag)
				if p.spring.position.length() < Vector2(Player.CAM_SHOULDER, Player.CAM_RAISE).length() - 0.1 or p.spring.get_hit_length() < Player.CAM_DIST - 0.5:
					pulled += 1
	at.log_line("camera: %d places beside and in front of cover, the camera pulled in at %d" % [samples, pulled])
	_expect(samples >= 12 and pulled >= 4, "the camera was tried beside cover (%d places, pulled in at %d)" % [samples, pulled])
	_expect(in_wall.is_empty(), "the camera is never inside a wall %s" % in_wall)
	_expect(at_head.is_empty(), "the camera never looks from inside the head %s" % at_head)
	_expect(covered.is_empty(), "the body never covers the crosshair unless it is see-through %s" % covered)
	p.global_position = home
	p.aim_yaw = home_yaw
	p.frozen = false
	p.invulnerable = false
	b.process_mode = Node.PROCESS_MODE_INHERIT
	await _settle_camera()


## Time for the camera to settle (the spring arm sweeps in physics ticks, the pivot eases in frames).
func _settle_camera() -> void:
	await at.wait(0.7)
	await get_tree().process_frame


func _lane_clear(f: Fighter, a: Vector3, z: Vector3) -> bool:
	var d := z - a
	return f.trace(a, d.normalized(), d.length(), Fighter.LAYER_WORLD | Fighter.LAYER_SHIELD).is_empty()


func _grenades() -> Array:
	var out := []
	for c in get_tree().current_scene.get_children():
		if c is Grenade:
			out.append(c)
	return out

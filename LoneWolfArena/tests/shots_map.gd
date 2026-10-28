extends Node
## Map tour for "CARGO CAGE" (scripts/map_builder.gd):
##   tools/qa/capture.sh <dir> 1560x720 script:res://tests/shots_map.gd
## Spawn views in PREP (barrier on) and FIGHT, lanes, high ground, ceiling, a 3D overview and a
## top-down debug view with the navmesh islands, the minimap texture, per-view draw calls and
## primitives (MAPPERF lines), navmesh path checks (MAPNAV lines) and a collider dump
## (colliders.json) for offline gap analysis. Exit code 1 if a navmesh check fails.

var at: Node
var arena: Node
var cam: Camera3D
var fails := 0


func run(autotest: Node) -> int:
	at = autotest
	Game.settings.difficulty = 0
	Game.goto_arena()
	await at.wait(1.6)
	arena = at.get_tree().current_scene
	var map: MapBuilder = arena.get("map")
	var p: Player = arena.get("player")
	var b: Bot = arena.get("bot")
	var hud: Control = arena.get("hud")
	p.invulnerable = true
	b.invulnerable = true
	cam = Camera3D.new()
	cam.fov = 70.0
	cam.far = 300.0
	arena.add_child(cam)
	# ---- PREP: barrier on
	await at.shot("map_prep_a_hud")
	hud.visible = false
	# the HUD writes the joystick into player.move_dir every frame: park it for the scripted moves
	hud.process_mode = Node.PROCESS_MODE_DISABLED
	await _perf("prep_a")
	await at.shot("map_prep_a")
	await _view("map_prep_b", map.spawn_b + _back(map.spawn_b_yaw, 3.3) + Vector3(0, 2.0, 0), map.spawn_b + _fwd(map.spawn_b_yaw, 10.0) + Vector3(0, 1.2, 0))
	await _view("map_prep_inside_a", map.spawn_a + Vector3(1.0, 1.7, 0), map.spawn_a + Vector3(-6.0, 1.2, 0), 75.0)
	_use_player_cam(p)
	# the barrier must hold the player in the alcove during PREP
	p.aim_yaw = map.spawn_a_yaw
	p.move_dir = Vector2(0, 1)
	await at.wait(2.5)
	p.move_dir = Vector2.ZERO
	var held: bool = p.global_position.x < -MapBuilder.HX + 0.1
	at.log_line("MAPNAV %s barrier holds the player in PREP (x=%.2f)" % ["OK" if held else "FAIL", p.global_position.x])
	if not held:
		fails += 1
	p.global_position = map.spawn_a
	# ---- FIGHT
	await at.wait_for_phase(arena, 1)
	b.frozen = true
	p.aim_yaw = map.spawn_a_yaw
	p.move_dir = Vector2(0, 1)
	await at.wait(1.6)
	p.move_dir = Vector2.ZERO
	var out: bool = p.global_position.x > -MapBuilder.HX + 0.5
	at.log_line("MAPNAV %s barrier released in FIGHT (x=%.2f)" % ["OK" if out else "FAIL", p.global_position.x])
	if not out:
		fails += 1
	p.global_position = map.spawn_a
	p.aim_yaw = map.spawn_a_yaw
	await at.wait(1.2)
	await _perf("fight_a")
	await at.shot("map_fight_a")
	await _view("map_fight_b", map.spawn_b + _back(map.spawn_b_yaw, 3.3) + Vector3(0, 2.0, 0), map.spawn_b + _fwd(map.spawn_b_yaw, 10.0) + Vector3(0, 1.2, 0))
	_use_player_cam(p)
	await _player_view(p, Vector3(-15.5, 0, 3.2), -PI * 0.5, -0.05, "map_hall_a")
	# cost breakdown at the same view: without the fighters, then without sun shadows
	p.visible = false
	b.visible = false
	await _perf("hall_a_no_fighters")
	map.sun.shadow_enabled = false
	await _perf("hall_a_no_fighters_no_shadows")
	map.sun.shadow_enabled = true
	p.visible = true
	b.visible = true
	await _player_view(p, Vector3(-9.5, 0, -2.0), -PI * 0.5 - 0.35, -0.02, "map_ramp_a")
	await _player_view(p, Vector3(-1.2, MapBuilder.C_H, -1.0), PI * 0.5, -0.12, "map_high_west")
	await _player_view(p, Vector3(1.2, MapBuilder.C_H, 1.0), -PI * 0.5, -0.12, "map_high_east")
	await _player_view(p, Vector3(-14.5, 0, -8.7), -PI * 0.5, 0.0, "map_open_container")
	await _player_view(p, Vector3(-4.0, 0, -9.0), -PI * 0.5, 0.0, "map_north_lane")
	await _player_view(p, Vector3(6.0, 0, 9.5), PI * 0.5, 0.0, "map_south_lane")
	await _player_view(p, Vector3(-12.0, 0, 3.5), PI * 0.82, 0.05, "map_sw_corner")
	await _player_view(p, Vector3(-12.0, 0, -5.0), PI * 0.2, 0.1, "map_nw_corner")
	await _perf("lanes")
	await _view("map_ceiling", Vector3(-10, 1.7, 2), Vector3(4, 9.5, -3), 80.0)
	# ---- overview without the roof (layer 2 hidden)
	cam.cull_mask = 0xFFFFF & ~2
	await _view("map_overview", Vector3(-27, 17, 21), Vector3(-1, 0, -1), 60.0)
	await _view("map_overview_b", Vector3(27, 17, -21), Vector3(1, 0, 1), 60.0)
	# ---- top-down debug (orthographic) + navmesh islands
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 33.0
	cam.near = 0.5
	cam.far = 80.0
	cam.global_transform = Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(0, 40, 0))
	await at.wait(0.4)
	await at.shot("map_top")
	await _nav_checks(map, arena)
	var overlay := _nav_overlay(map)
	if overlay:
		arena.add_child(overlay)
		await at.wait(0.3)
		await at.shot("map_nav")
		overlay.queue_free()
	_dump_colliders(map)
	# ---- the minimap texture the HUD uses
	var mm: Texture2D = arena.get("minimap_texture")
	if mm:
		var img := mm.get_image()
		img.save_png(String(at.get("shots_dir")).path_join("map_minimap.png"))
		at.log_line("minimap %dx%d" % [img.get_width(), img.get_height()])
	else:
		at.log_line("MAPNAV FAIL minimap texture missing")
		fails += 1
	# ---- quality levels
	for g in [0, 3]:
		map.apply_quality(g)
		cam.projection = Camera3D.PROJECTION_PERSPECTIVE
		cam.cull_mask = 0xFFFFF
		await _view("map_quality_%d" % g, Vector3(-14, 1.8, 6), Vector3(0, 1.5, -2), 70.0)
	map.apply_quality(int(Game.settings.graphics))
	at.log_line("MAPNAV RESULT fails=%d" % fails)
	return 1 if fails > 0 else 0


func _fwd(yaw: float, d: float) -> Vector3:
	return Vector3(-sin(yaw), 0, -cos(yaw)) * d


func _back(yaw: float, d: float) -> Vector3:
	return -_fwd(yaw, d)


func _view(shot_name: String, from: Vector3, to: Vector3, fov := 70.0) -> void:
	cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	cam.fov = fov
	cam.near = 0.05
	cam.far = 300.0
	cam.global_position = from
	cam.look_at(to)
	cam.current = true
	await at.wait(0.35)
	await _perf(shot_name)
	await at.shot(shot_name)


func _use_player_cam(p: Player) -> void:
	p.camera.current = true


func _player_view(p: Player, pos: Vector3, yaw: float, pitch: float, shot_name: String) -> void:
	p.camera.current = true
	p.global_position = pos + Vector3(0, 0.05, 0)
	p.velocity = Vector3.ZERO
	p.aim_yaw = yaw
	p.aim_pitch = pitch
	await at.wait(0.6)
	p.aim_yaw = yaw
	p.aim_pitch = pitch
	await at.wait(0.3)
	await _perf(shot_name)
	await at.shot(shot_name)


func _perf(tag: String) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var vp := at.get_viewport().get_viewport_rid()
	var V := RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE
	var S := RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW
	var dc := RenderingServer.viewport_get_render_info(vp, V, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var pr := RenderingServer.viewport_get_render_info(vp, V, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)
	var ob := RenderingServer.viewport_get_render_info(vp, V, RenderingServer.VIEWPORT_RENDER_INFO_OBJECTS_IN_FRAME)
	var sdc := RenderingServer.viewport_get_render_info(vp, S, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var spr := RenderingServer.viewport_get_render_info(vp, S, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)
	at.log_line("MAPPERF %s draw_calls=%d primitives=%d objects=%d shadow_draw_calls=%d shadow_primitives=%d fps=%d" % [tag, dc, pr, ob, sdc, spr, Engine.get_frames_per_second()])


func _nav_checks(map: MapBuilder, ar: Node) -> void:
	var t := 0.0
	while not (ar.get("nav_map") as RID).is_valid() and t < 10.0:
		await at.wait(0.2)
		t += 0.2
	var nav_map: RID = ar.get("nav_map")
	if not nav_map.is_valid():
		at.log_line("MAPNAV FAIL navmesh never baked")
		fails += 1
		return
	await at.wait(0.3)
	var targets := {
		"spawn_b": map.spawn_b, "high_ground": Vector3(-1.2, MapBuilder.C_H, 0.0), "high_ground_far": Vector3(1.2, MapBuilder.C_H, 5.0),
		"open_container_a": Vector3(-9.2, 0.12, -8.7), "open_container_b": Vector3(9.2, 0.12, 8.7),
		"sw_pocket": Vector3(-19.0, 0, 8.5), "ne_pocket": Vector3(19.0, 0, -8.5), "nw_pad": Vector3(-17.0, 0, -8.0),
		"north_lane": Vector3(0.0, 0, -9.0), "south_lane": Vector3(0.0, 0, 9.0), "behind_crates_a": Vector3(-13.8, 0, 0.0),
	}
	for key: String in targets:
		var to: Vector3 = targets[key]
		var path := NavigationServer3D.map_get_path(nav_map, map.spawn_a, to, true)
		var end := path[path.size() - 1] if path.size() > 0 else Vector3.INF
		var ok := path.size() > 1 and end.distance_to(to) < 1.2
		var length := 0.0
		for i in range(1, path.size()):
			length += path[i].distance_to(path[i - 1])
		at.log_line("MAPNAV %s %s path_points=%d length=%.1f end=%s" % ["OK" if ok else "FAIL", key, path.size(), length, str(end)])
		if not ok:
			fails += 1
	# random navmesh points must all be reachable from spawn A
	var bad := 0
	for i in 60:
		var rp := NavigationServer3D.map_get_random_point(nav_map, 1, false)
		var path := NavigationServer3D.map_get_path(nav_map, map.spawn_a, rp, true)
		if path.size() == 0 or path[path.size() - 1].distance_to(rp) > 0.8:
			bad += 1
			at.log_line("MAPNAV unreachable random point %s" % str(rp))
	at.log_line("MAPNAV random points unreachable=%d/60" % bad)
	if bad > 0:
		fails += 1


## Translucent overlay of the baked navmesh, one colour per connected island.
func _nav_overlay(map: MapBuilder) -> MeshInstance3D:
	var nm := map.nav.navigation_mesh
	if nm == null:
		return null
	var verts := nm.get_vertices()
	var n := nm.get_polygon_count()
	var parent := []
	parent.resize(n)
	for i in n:
		parent[i] = i
	var edge_owner := {}
	for i in n:
		var poly := nm.get_polygon(i)
		for k in poly.size():
			var a := poly[k]
			var c := poly[(k + 1) % poly.size()]
			var key := "%d_%d" % [mini(a, c), maxi(a, c)]
			if edge_owner.has(key):
				_union(parent, i, int(edge_owner[key]))
			else:
				edge_owner[key] = i
	var island_area := {}
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var palette := [Color(0.1, 1.0, 0.3, 0.45), Color(1.0, 0.2, 0.9, 0.6), Color(1.0, 0.9, 0.1, 0.6), Color(0.2, 0.6, 1.0, 0.6), Color(1.0, 0.4, 0.1, 0.6)]
	var ids := {}
	for i in n:
		var r: int = _find(parent, i)
		if not ids.has(r):
			ids[r] = ids.size()
		var poly := nm.get_polygon(i)
		var col: Color = palette[mini(int(ids[r]), palette.size() - 1)]
		for k in range(1, poly.size() - 1):
			var a := verts[poly[0]]
			var b := verts[poly[k]]
			var c := verts[poly[k + 1]]
			island_area[r] = float(island_area.get(r, 0.0)) + 0.5 * (b - a).cross(c - a).length()
			for v in [a, c, b]:
				st.set_color(col)
				st.add_vertex(v + Vector3(0, 0.08, 0))
	for r in island_area:
		at.log_line("MAPNAV island %d area=%.1f m2" % [int(ids[r]), float(island_area[r])])
	at.log_line("MAPNAV islands=%d polygons=%d" % [island_area.size(), n])
	if island_area.size() > 1:
		at.log_line("MAPNAV FAIL navmesh has %d islands" % island_area.size())
		fails += 1
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	return mi


func _find(parent: Array, i: int) -> int:
	while int(parent[i]) != i:
		parent[i] = parent[int(parent[i])]
		i = int(parent[i])
	return i


func _union(parent: Array, a: int, b: int) -> void:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra != rb:
		parent[ra] = rb


## Writes every box collider of the map (world-layer bodies) + obstacles to colliders.json.
func _dump_colliders(map: MapBuilder) -> void:
	var boxes := []
	for root: Node in [map.nav, map.deco]:
		for cs in root.find_children("*", "CollisionShape3D", true, false):
			var shape := (cs as CollisionShape3D).shape
			if shape is BoxShape3D:
				var xf := (cs as CollisionShape3D).global_transform
				boxes.append({"size": [shape.size.x, shape.size.y, shape.size.z], "origin": [xf.origin.x, xf.origin.y, xf.origin.z],
					"basis": [xf.basis.x.x, xf.basis.x.y, xf.basis.x.z, xf.basis.y.x, xf.basis.y.y, xf.basis.y.z, xf.basis.z.x, xf.basis.z.y, xf.basis.z.z],
					"disabled": (cs as CollisionShape3D).disabled})
	var obs := []
	for r in map.obstacles:
		obs.append([r.position.x, r.position.y, r.size.x, r.size.y])
	var data := {"boxes": boxes, "obstacles": obs, "map_rect": [map.map_rect.position.x, map.map_rect.position.y, map.map_rect.size.x, map.map_rect.size.y],
		"spawn_a": [map.spawn_a.x, map.spawn_a.z], "spawn_b": [map.spawn_b.x, map.spawn_b.z], "cover_points": map.cover_points.size()}
	var f := FileAccess.open(String(at.get("shots_dir")).path_join("colliders.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()
	at.log_line("colliders=%d obstacles=%d cover_points=%d" % [boxes.size(), obs.size(), map.cover_points.size()])

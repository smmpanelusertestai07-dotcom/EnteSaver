extends Node
## Map tour for "CARGO CAGE" (scripts/map_builder.gd):
##   tools/qa/capture.sh <dir> 1560x720 script:res://tests/shots_map.gd
## Spawn views in PREP (barrier on) and FIGHT, lanes, high ground, the open centre bay, ceiling,
## a 3D overview and a top-down debug view with the navmesh islands, the minimap texture,
## per-view draw calls and primitives (MAPPERF lines) plus a SMOOTH..MAX quality sweep against
## the 220 draw call / 250k primitive budget, navmesh path checks and the zone-centre open-floor
## check (MAPNAV lines) and a collider dump (colliders.json) for offline gap analysis. Exit code
## 1 if a check fails.
## About the numbers: the Compatibility (GLES3) renderer adds the shadow pass's draw calls to the
## VISIBLE draw-call counter (its SHADOW draw-call counter stays 0) and reports the shadow pass's
## primitives separately. So "draw_calls" below is the whole frame, shadow maps included, and
## "total_primitives" adds the shadow primitives. The shadow pass's share of the draw calls is
## modelled (_shadow_estimate) and cross-checked once against the drop with shadows switched off.

const BUDGET_DRAW_CALLS := 220
const BUDGET_PRIMITIVES := 250000

var at: Node
var arena: Node
var cam: Camera3D
var fails := 0
var map: MapBuilder
var _mesh_tris := {}            # mesh RID -> [triangles per surface]
var _worst := {}                # tag group -> {"dc": int, "pr": int}


func run(autotest: Node) -> int:
	at = autotest
	Game.settings.difficulty = 0
	await at.wait(2.0)          # let the lobby finish its _ready before switching scenes
	Game.goto_arena()
	await at.wait(1.6)
	arena = at.get_tree().current_scene
	map = arena.get("map")
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
	await _walk(p, 150)
	var held: bool = p.global_position.x < -MapBuilder.HX + 0.1
	at.log_line("MAPNAV %s barrier holds the player in PREP (x=%.2f)" % ["OK" if held else "FAIL", p.global_position.x])
	if not held:
		fails += 1
	p.global_position = map.spawn_a
	# ---- FIGHT
	await at.wait_for_phase(arena, 1)
	b.frozen = true
	p.aim_yaw = map.spawn_a_yaw
	await _walk(p, 100)
	var out: bool = p.global_position.x > -MapBuilder.HX + 0.5
	at.log_line("MAPNAV %s barrier released in FIGHT (x=%.2f)" % ["OK" if out else "FAIL", p.global_position.x])
	if not out:
		fails += 1
	# crate steps: floor -> single crate -> 2-stack -> high ground (jump apex ~1.3 m)
	var roof_x := -MapBuilder.BAY_HW - MapBuilder.C40.z      # outer face of the west container
	p.global_position = Vector3(roof_x - 4.0, 0.05, -4.7)
	p.velocity = Vector3.ZERO
	p.aim_yaw = -PI * 0.5
	await at.wait(0.3)
	var top := 0.0
	for i in 360:
		p.move_dir = Vector2(0, 1)
		if i % 12 == 0:
			p.do_jump()
		await at.get_tree().physics_frame
		top = maxf(top, p.global_position.y)
		if p.global_position.y > MapBuilder.C_H - 0.1 and p.global_position.x > roof_x + 0.15:
			break
	p.move_dir = Vector2.ZERO
	var climbed: bool = p.global_position.y > MapBuilder.C_H - 0.1
	at.log_line("MAPNAV %s crate steps reach the high ground (pos=%s, max y %.2f)" % ["OK" if climbed else "FAIL", str(p.global_position), top])
	if not climbed:
		fails += 1
	# the steel ramp is walkable without jumping (stop on the roof, before the bay edge)
	p.global_position = Vector3(roof_x - MapBuilder.RAMP_RUN - 2.0, 0.05, 2.75)
	p.velocity = Vector3.ZERO
	await at.wait(0.3)
	for i in 240:
		p.move_dir = Vector2(0, 1)
		await at.get_tree().physics_frame
		if p.global_position.y > MapBuilder.C_H - 0.1 and p.global_position.x > roof_x + 0.4:
			break
	p.move_dir = Vector2.ZERO
	var up_ramp: bool = p.global_position.y > MapBuilder.C_H - 0.1
	at.log_line("MAPNAV %s ramp walk reaches the high ground (pos=%s)" % ["OK" if up_ramp else "FAIL", str(p.global_position)])
	if not up_ramp:
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
	var with_shadows: int = await _perf("hall_a_no_fighters")
	var model := _shadow_estimate(at.get_viewport().get_camera_3d()).x
	map.sun.shadow_enabled = false
	var without: int = await _perf("hall_a_no_fighters_no_shadows")
	map.sun.shadow_enabled = true
	at.log_line("MAPPERF shadow pass: switching sun shadows off removes %d draw calls from the frame count (model: %d)" % [with_shadows - without, model])
	p.visible = true
	b.visible = true
	await _player_view(p, Vector3(-14.0, 0, 0.3), -PI * 0.5 - 0.35, -0.02, "map_ramp_a")
	# on the west roof looking across the open bay to the east one, then the east roof outward
	await _player_view(p, Vector3(-5.5, MapBuilder.C_H, 3.6), -PI * 0.5 + 0.12, -0.16, "map_high_west")
	await _player_view(p, Vector3(5.5, MapBuilder.C_H, -3.6), -PI * 0.5, -0.12, "map_high_east")
	# down in the bay (the zone's final circle), looking along it to the north lane
	await _player_view(p, Vector3(0.0, 0, 5.2), 0.0, 0.02, "map_bay")
	await _player_view(p, Vector3(-14.5, 0, -8.7), -PI * 0.5, 0.0, "map_open_container")
	await _player_view(p, Vector3(-4.0, 0, -9.0), -PI * 0.5, 0.0, "map_north_lane")
	await _player_view(p, Vector3(6.0, 0, 9.5), PI * 0.5, 0.0, "map_south_lane")
	await _player_view(p, Vector3(-12.0, 0, 3.5), PI * 0.82, 0.05, "map_sw_corner")
	await _player_view(p, Vector3(-12.0, 0, -5.0), PI * 0.2, 0.1, "map_nw_corner")
	await _perf("lanes")
	# Draw calls and primitives per quality level (visible pass + estimated shadow pass) from
	# the views with the most on screen.
	var views := [[map.spawn_a + Vector3(2.5, 0, 0), map.spawn_a_yaw], [Vector3(-15.5, 0, 3.2), -PI * 0.5],
		[Vector3(-5.5, MapBuilder.C_H, 3.6), -PI * 0.5 + 0.12], [Vector3(-12.0, 0, -5.0), PI * 0.2], [Vector3(15.0, 0, -4.0), PI * 0.62]]
	var graphics_before := int(Game.settings.graphics)
	for g in [0, 1, 2, 3]:
		Game.settings.graphics = g
		arena.call("apply_graphics")
		for v in views:
			p.global_position = (v[0] as Vector3) + Vector3(0, 0.05, 0)
			p.velocity = Vector3.ZERO
			p.aim_yaw = float(v[1])
			p.aim_pitch = 0.0
			await at.wait(0.4)
			await _perf("quality_%d" % g, "q%d" % g)
		var w: Dictionary = _worst.get("q%d" % g, {"dc": 0, "pr": 0})
		var ok: bool = int(w.dc) <= BUDGET_DRAW_CALLS and int(w.pr) <= BUDGET_PRIMITIVES
		at.log_line("MAPPERF %s quality %d worst frame (shadow pass included) draw_calls=%d primitives=%d budget %d / %d" % [
			"OK" if ok else "OVER", g, int(w.dc), int(w.pr), BUDGET_DRAW_CALLS, BUDGET_PRIMITIVES])
		if not ok:
			fails += 1
	Game.settings.graphics = graphics_before
	arena.call("apply_graphics")
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


## Walks forward for a number of physics frames (independent of the render frame rate).
func _walk(p: Player, frames: int) -> void:
	for i in frames:
		p.move_dir = Vector2(0, 1)
		await at.get_tree().physics_frame
	p.move_dir = Vector2.ZERO


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


func _perf(tag: String, group := "") -> int:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var vp := at.get_viewport().get_viewport_rid()
	var V := RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE
	var S := RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW
	var dc := RenderingServer.viewport_get_render_info(vp, V, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var pr := RenderingServer.viewport_get_render_info(vp, V, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)
	var ob := RenderingServer.viewport_get_render_info(vp, V, RenderingServer.VIEWPORT_RENDER_INFO_OBJECTS_IN_FRAME)
	var spr := RenderingServer.viewport_get_render_info(vp, S, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)
	var est := _shadow_estimate(at.get_viewport().get_camera_3d())
	at.log_line("MAPPERF %s draw_calls=%d (shadow pass inside, modelled ~%d) primitives=%d shadow_primitives=%d total_primitives=%d objects=%d fps=%d" % [
		tag, dc, est.x, pr, spr, pr + spr, ob, Engine.get_frames_per_second()])
	if group != "":
		var w: Dictionary = _worst.get(group, {"dc": 0, "pr": 0})
		w.dc = maxi(int(w.dc), dc)
		w.pr = maxi(int(w.pr), pr + spr)
		_worst[group] = w
	return dc


## Shadow pass of the sun (2 PSSM splits). The Compatibility renderer reports its primitives but
## not its draw calls, so both are modelled here: each split's shadow map covers the bounding
## sphere of its slice of the view frustum (as seen from the light), and every shadow-casting
## surface whose bounds overlap that square is one draw call (a MultiMesh draws all its
## instances in one). The modelled primitives are logged next to the renderer's own count, which
## shows how far the model can be trusted. Returns (draw calls, primitives).
func _shadow_estimate(view_cam: Camera3D) -> Vector2i:
	var sun: DirectionalLight3D = map.sun
	if view_cam == null or not sun.shadow_enabled or not sun.is_visible_in_tree():
		return Vector2i.ZERO
	var lx := sun.global_basis.x.normalized()
	var ly := sun.global_basis.y.normalized()
	var caster_mask := 0xFFFFF
	var scm: Variant = sun.get("shadow_caster_mask")
	if scm is int:
		caster_mask = int(scm)
	var casters := []
	for node in arena.find_children("*", "GeometryInstance3D", true, false):
		var g := node as GeometryInstance3D
		if not g.is_visible_in_tree() or g.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF or (g.layers & caster_mask) == 0:
			continue
		var tris := _surface_tris(g)
		if not tris.is_empty():
			casters.append([g.global_transform * g.get_aabb(), tris])
	var vs := at.get_viewport().get_visible_rect().size
	var splits := [0.0, sun.directional_shadow_split_1, 1.0]
	var dc := 0
	var pr := 0
	for i in 2:
		var d0 := maxf(view_cam.near, sun.directional_shadow_max_distance * float(splits[i]))
		var d1 := sun.directional_shadow_max_distance * float(splits[i + 1])
		var pts: Array[Vector3] = []
		for corner: Vector2 in [Vector2.ZERO, Vector2(vs.x, 0), vs, Vector2(0, vs.y)]:
			pts.append(view_cam.project_position(corner, d0))
			pts.append(view_cam.project_position(corner, d1))
		var centre := Vector3.ZERO
		for q in pts:
			centre += q
		centre /= pts.size()
		var rad := 0.0
		for q in pts:
			rad = maxf(rad, q.distance_to(centre))
		var c2 := Vector2(centre.dot(lx), centre.dot(ly))
		var square := Rect2(c2 - Vector2(rad, rad), Vector2(rad, rad) * 2.0)
		for cst in casters:
			var b: AABB = cst[0]
			var mn := Vector2(INF, INF)
			var mx := Vector2(-INF, -INF)
			for k in 8:
				var e := b.get_endpoint(k)
				var p2 := Vector2(e.dot(lx), e.dot(ly))
				mn = mn.min(p2)
				mx = mx.max(p2)
			if Rect2(mn, mx - mn).intersects(square, true):
				var tris: Array = cst[1]
				dc += tris.size()
				for t in tris:
					pr += int(t)
	return Vector2i(dc, pr)


## Triangles per surface of a mesh / MultiMesh instance (x instance count), cached per mesh.
func _surface_tris(g: GeometryInstance3D) -> Array:
	var mesh: Mesh = null
	var count := 1
	if g is MeshInstance3D:
		mesh = (g as MeshInstance3D).mesh
	elif g is MultiMeshInstance3D:
		var mm := (g as MultiMeshInstance3D).multimesh
		if mm == null:
			return []
		mesh = mm.mesh
		count = mm.visible_instance_count if mm.visible_instance_count >= 0 else mm.instance_count
	if mesh == null:
		return []
	var per: Array = _mesh_tris.get(mesh.get_rid(), [])
	if per.is_empty():
		for si in mesh.get_surface_count():
			var arr := mesh.surface_get_arrays(si)
			var idx: Variant = arr[Mesh.ARRAY_INDEX]
			var n := (idx as PackedInt32Array).size() if idx is PackedInt32Array and (idx as PackedInt32Array).size() > 0 \
				else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			per.append(n / 3)
		_mesh_tris[mesh.get_rid()] = per
	var out := []
	for t in per:
		out.append(int(t) * count)
	return out


func _nav_checks(map: MapBuilder, ar: Node) -> void:
	# The safe zone ends as a 4 m circle around zone_center: that must be open floor (no
	# obstacle footprint), and so should most of the 6 m ring around it.
	for rad: float in [4.0, 6.0]:
		var inside := 0
		var blocked := 0
		var c := Vector2(map.zone_center.x, map.zone_center.z)
		for ix in range(-40, 41):
			for iz in range(-40, 41):
				var q := c + Vector2(ix, iz) * (rad / 40.0)
				if q.distance_to(c) > rad - 0.05:      # the interior (a wall touching the edge is fine)
					continue
				inside += 1
				for r: Rect2 in map.obstacles:
					if r.has_point(q):
						blocked += 1
						break
		var frac := float(blocked) / maxf(inside, 1)
		var ok := frac <= (0.0 if rad <= 4.0 else 0.25)
		at.log_line("MAPNAV %s zone centre r=%.0f m: obstacles cover %.1f %% of the circle" % ["OK" if ok else "FAIL", rad, frac * 100.0])
		if not ok:
			fails += 1
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
		"spawn_b": map.spawn_b, "high_ground": Vector3(-5.2, MapBuilder.C_H, 1.0), "high_ground_far": Vector3(5.2, MapBuilder.C_H, -1.0),
		"bay_centre": map.zone_center, "bay_north": Vector3(0.0, 0, -4.5), "bay_south": Vector3(0.0, 0, 4.5),
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

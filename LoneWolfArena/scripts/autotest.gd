extends Node
## Automated runs used for testing (never active in normal play):
##   --autotest=screens : walks through every screen, plays a scripted fight and saves PNGs.
##   --autotest=sim     : headless full match simulation (scripted player vs bot), prints results.
## Pass with: godot --path . -- --autotest=screens --shots=/abs/dir

const BOOT_SCENE := "res://scenes/loading.tscn"

var shots_dir := ""
var log_lines: PackedStringArray = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	shots_dir = Game.shots_dir if Game.shots_dir != "" else OS.get_user_data_dir().path_join("shots")
	DirAccess.make_dir_recursive_absolute(shots_dir)
	_log("autotest mode=%s shots=%s" % [Game.autotest, shots_dir])
	# The boot screen hands over to the lobby by itself. Start once it has, so that a test's own
	# scene change is not undone by that handover.
	while get_tree().current_scene == null or get_tree().current_scene.scene_file_path == BOOT_SCENE:
		await get_tree().process_frame
	match Game.autotest:
		"screens":
			_run_screens.call_deferred()
		"sim":
			_run_sim.call_deferred()
		"death":
			_run_death.call_deferred()
		"pose":
			_run_pose.call_deferred()
		"victory":
			_run_victory.call_deferred()
		"perf":
			_run_perf.call_deferred()
		"aim":
			_run_aim.call_deferred()
		_:
			# --autotest=script:res://tests/shots_xxx.gd runs that script's run(autotest)
			# coroutine (screenshot tours owned by the HUD, map and menu work).
			if Game.autotest.begins_with("script:"):
				_run_script.call_deferred(Game.autotest.substr(7))


func _run_script(path: String) -> void:
	# Only the project's own test scripts (never a file from elsewhere on the device).
	if not path.begins_with("res://tests/") or ".." in path:
		_log("refusing script outside res://tests/: " + path)
		get_tree().quit(2)
		return
	var scr: Script = load(path)
	if scr == null:
		_log("cannot load " + path)
		get_tree().quit(2)
		return
	var runner: Node = scr.new()
	add_child(runner)
	var code: Variant = await runner.call("run", self)
	get_tree().quit(int(code) if typeof(code) == TYPE_INT else 0)


## Helpers for tour scripts: shot(name), wait(sec), touch(index, pos, pressed), drag(index, pos, rel).
func shot(shot_name: String) -> void:
	await _shot(shot_name)


func wait(sec: float) -> void:
	await _wait(sec)


## touch()/drag() take window pixels (what Input.parse_input_event expects); see _win().
func touch(index: int, pos: Vector2, pressed: bool) -> void:
	_touch(index, pos, pressed)


func drag(index: int, pos: Vector2, rel: Vector2) -> void:
	_drag(index, pos, rel)


## Canvas (viewport) coordinates -> window pixels: differ on stretched windows (e.g. 2400x1080).
func _win(canvas_pos: Vector2) -> Vector2:
	return get_tree().root.get_final_transform() * canvas_pos


func log_line(t: String) -> void:
	_log(t)


func wait_for_phase(arena: Node, want: int, timeout := 60.0) -> void:
	var t := 0.0
	while arena.get("phase") != want and t < timeout:
		await _wait(0.1)
		t += 0.1


func _log(t: String) -> void:
	print("[autotest] ", t)
	log_lines.append(t)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec, true, false, true).timeout


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := shots_dir.path_join(shot_name + ".png")
	img.save_png(path)
	_log("saved " + path)


func _scene() -> Node:
	return get_tree().current_scene


func _touch(index: int, pos: Vector2, pressed: bool) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = index
	ev.position = pos
	ev.pressed = pressed
	Input.parse_input_event(ev)


func _drag(index: int, pos: Vector2, rel: Vector2) -> void:
	var ev := InputEventScreenDrag.new()
	ev.index = index
	ev.position = pos
	ev.relative = rel
	Input.parse_input_event(ev)


func _aim_at(p: Player, target: Vector3) -> void:
	# Aim like a skilled player: compensate the camera recoil offset.
	var dir := (target - p.camera.global_position).normalized()
	p.aim_yaw = atan2(-dir.x, -dir.z) - deg_to_rad(p.recoil_yaw)
	p.aim_pitch = asin(clampf(dir.y, -1.0, 1.0)) - deg_to_rad(p.recoil_pitch)


# ---------------------------------------------------------------- screenshots walkthrough

func _run_screens() -> void:
	Game.settings.difficulty = 0
	await _wait(3.0)
	await _shot("01_lobby")
	var lobby := _scene()
	lobby.call("_open_wardrobe")
	await _wait(0.6)
	var card := lobby.find_child("Bundle_neon", true, false)
	if card:
		card.button_pressed = true
		card.emit_signal("pressed")
	await _wait(1.2)
	await _shot("02_bundles")
	lobby.call("_close_wardrobe")
	(lobby.get("model") as CharacterModel).apply_bundle(String(Game.profile.bundle))
	lobby.call("_open_settings")
	await _wait(0.8)
	await _shot("03_settings")
	var sp := lobby.find_child("*", true, false)
	for n in lobby.get("ui").get_children():
		if n is SettingsPanel:
			(n as SettingsPanel).call("_show_tab", 2)
			await _wait(0.5)
			await _shot("04_settings_controls")
			(n as SettingsPanel).call("_close")
	Game.goto_hud_editor()
	await _wait(1.5)
	await _shot("05_hud_editor")
	Game.goto_arena()
	await _wait(1.2)
	await _shot("06_countdown")
	var arena := _scene()
	var guard := 0.0
	while arena.get("phase") != 1 and guard < 60.0:
		await _wait(0.25)
		guard += 0.25
	await _wait(1.5)
	var p: Player = arena.get("player")
	var b: Bot = arena.get("bot")
	p.move_dir = Vector2(0, 1)
	await _wait(1.0)
	await _shot("07_running")
	# Bring the bot into view for a deterministic fight screenshot.
	var fwd := -p.global_basis.z
	b.global_position = arena.call("closest_nav_point", p.global_position + fwd * 13.0)
	await _wait(0.4)
	var vs := get_viewport().get_visible_rect().size
	var fire_c := HudLayout.center(HudLayout.current().fire_r, vs)
	_aim_at(p, b.chest_position())
	_touch(5, _win(fire_c), true)
	for i in 30:
		await _wait(0.05)
		if not b.alive:
			break
		_aim_at(p, b.chest_position() + Vector3(0, randf_range(-0.05, 0.12), 0))
		_drag(5, _win(fire_c + Vector2(randf_range(-2, 2), randf_range(-2, 2))), get_tree().root.get_final_transform().basis_xform(Vector2(randf_range(-1, 1), randf_range(-1, 1))))
		if i == 12:
			await _shot("08_firing")
	var t := 0.0
	while b.alive and p.alive and t < 12.0:
		_aim_at(p, b.head_position() if randf() < 0.3 else b.chest_position())
		await _wait(0.05)
		t += 0.05
	_touch(5, _win(fire_c), false)
	await _wait(1.2)
	await _shot("09_end")
	var waited := 0.0
	while not arena.get("_result_shown") and waited < 20.0:
		await _wait(0.5)
		waited += 0.5
	await _wait(1.0)
	await _shot("10_results")
	_log("screens done: player_hp=%d bot_hp=%d" % [roundi(p.hp), roundi(b.hp)])
	get_tree().quit(0)


# ---------------------------------------------------------------- headless match simulation

func _run_sim() -> void:
	Engine.time_scale = 3.0
	Game.settings.difficulty = 1
	Game.goto_arena()
	await _wait(0.5)
	var arena := _scene()
	var p: Player = arena.get("player")
	var b: Bot = arena.get("bot")
	var start := Time.get_ticks_msec()
	var path_timer := 0.0
	var path: PackedVector3Array = []
	var idx := 0
	while arena.get("phase") != 2 and Time.get_ticks_msec() - start < 240000:
		await get_tree().physics_frame
		if arena.get("phase") != 1:
			continue
		var sees := p.can_see(b.chest_position())
		if sees and p.global_position.distance_to(b.global_position) < 40.0:
			_aim_at(p, b.chest_position() + Vector3(randf_range(-0.25, 0.25), randf_range(-0.2, 0.25), 0))
			p.set_firing(true)
			p.move_dir = Vector2(sin(Time.get_ticks_msec() / 400.0), 0.0)
			if p.hp < 90 and p.medkits > 0 and not p.healing and randf() < 0.01:
				p.set_firing(false)
				p.use_medkit()
		else:
			p.set_firing(false)
			path_timer -= get_physics_process_delta_time()
			var nav_map: RID = arena.get("nav_map")
			if path_timer <= 0.0 and nav_map.is_valid():
				path_timer = 0.5
				path = NavigationServer3D.map_get_path(nav_map, p.global_position, b.global_position, true)
				idx = 0
			if idx < path.size():
				var to := path[idx] - p.global_position
				to.y = 0.0
				if to.length() < 0.8:
					idx += 1
				else:
					var dir := to.normalized()
					p.aim_yaw = atan2(-dir.x, -dir.z)
					p.aim_pitch = 0.0
					p.move_dir = Vector2(0, 1)
	var st := p.stats
	var bs := b.stats
	_log("SIM RESULT phase=%d elapsed=%.1fs player_hp=%d bot_hp=%d" % [arena.get("phase"), arena.get("elapsed"), roundi(p.hp), roundi(b.hp)])
	_log("player shots=%d hits=%d heads=%d dmg=%d | bot shots=%d hits=%d heads=%d dmg=%d" % [st.shots, st.hits, st.headshots, st.damage, bs.shots, bs.hits, bs.headshots, bs.damage])
	_log("winner=%s" % ("player" if p.alive and not b.alive else ("bot" if b.alive and not p.alive else "timeout")))
	await _wait(3.5)
	_log("results_shown=%s matches=%d" % [arena.get("_result_shown"), Game.profile.matches])
	get_tree().quit(0 if arena.get("phase") == 2 else 1)


func _run_death() -> void:
	Game.goto_arena()
	await _wait(4.5)
	var arena := _scene()
	var p: Player = arena.get("player")
	var b: Bot = arena.get("bot")
	p.take_damage(9999.0, "body", b, b.global_position)
	for i in 10:
		await _wait(0.5)
		_log("t=%.1f phase=%d end_t=%.2f shown=%s ts=%.2f" % [0.5 * (i + 1), arena.get("phase"), arena.get("_end_t"), arena.get("_result_shown"), Engine.time_scale])
	get_tree().quit(0)


func _run_pose() -> void:
	Game.goto_arena()
	var arena: Node = null
	for i in 400:
		await _wait(0.1)
		arena = _scene()
		if arena and arena.get("phase") == 1:
			break
	var p: Player = arena.get("player")
	var b: Bot = arena.get("bot")
	b.frozen = true
	b.global_position = arena.call("closest_nav_point", p.global_position + Vector3(0, 0, 8))
	b.aim_yaw = PI * 0.0
	await _wait(1.0)
	var hud: Node = arena.get("hud")
	hud.visible = false
	var cam := Camera3D.new()
	arena.add_child(cam)
	cam.fov = 40.0
	var views := [["pose_side", Vector3(2.4, 1.5, 0.0)], ["pose_front", Vector3(0.6, 1.5, 2.6)], ["pose_back", Vector3(0.5, 1.6, -2.4)]]
	for v in views:
		var off: Vector3 = v[1]
		var base := p.global_basis
		cam.global_position = p.global_position + base.x * off.x + Vector3.UP * off.y - base.z * off.z
		cam.look_at(p.global_position + Vector3.UP * 1.25)
		cam.current = true
		await _wait(0.6)
		await _shot(String(v[0]))
	p.set_stance(Fighter.Stance.STAND, true)
	p.set_crouch(true)
	await _wait(0.8)
	cam.global_position = p.global_position + p.global_basis.x * 2.4 + Vector3.UP * 1.2
	cam.look_at(p.global_position + Vector3.UP * 0.9)
	await _wait(0.4)
	await _shot("pose_crouch")
	p.set_crouch(false)
	p.aim_pitch = deg_to_rad(35)
	await _wait(0.6)
	cam.global_position = p.global_position + p.global_basis.x * 2.4 + Vector3.UP * 1.4
	cam.look_at(p.global_position + Vector3.UP * 1.3)
	await _wait(0.4)
	await _shot("pose_aim_up")
	p.aim_pitch = 0.0
	cam.global_position = b.global_position + b.global_basis.x * 1.6 - b.global_basis.z * 2.6 + Vector3.UP * 1.5
	cam.look_at(b.global_position + Vector3.UP * 1.3)
	await _wait(0.6)
	await _shot("pose_bot")
	get_tree().quit(0)


## Plays a real scripted fight until somebody wins (the scripted player aims and chases),
## then captures the end banner and the results screen.
func _run_victory() -> void:
	Game.settings.difficulty = 0
	Game.goto_arena()
	var arena: Node = null
	for i in 600:
		await _wait(0.1)
		arena = _scene()
		if arena and arena.get("phase") == 1:
			break
	var p: Player = arena.get("player")
	var b: Bot = arena.get("bot")
	var vs := get_viewport().get_visible_rect().size
	var fire_c := HudLayout.center(HudLayout.current().fire_r, vs)
	var firing := false
	var path: PackedVector3Array = []
	var idx := 0
	var path_t := 0.0
	var t := 0.0
	var shot_taken := false
	while b.alive and p.alive and t < 90.0:
		await _wait(0.05)
		t += 0.05
		if p.can_see(b.chest_position()) and p.global_position.distance_to(b.global_position) < 45.0:
			_aim_at(p, b.head_position() if randf() < 0.25 else b.chest_position())
			p.move_dir = Vector2(sin(t * 2.0) * 0.6, 0.0)
			if not firing:
				_touch(6, _win(fire_c), true)
				firing = true
			if not shot_taken and t > 1.0:
				shot_taken = true
				await _shot("v1_fight")
		else:
			if firing:
				_touch(6, _win(fire_c), false)
				firing = false
			path_t -= 0.05
			var nav_map: RID = arena.get("nav_map")
			if path_t <= 0.0 and nav_map.is_valid():
				path_t = 0.6
				path = NavigationServer3D.map_get_path(nav_map, p.global_position, b.global_position, true)
				idx = 0
			if idx < path.size():
				var to := path[idx] - p.global_position
				to.y = 0.0
				if to.length() < 0.8:
					idx += 1
				else:
					var dir := to.normalized()
					p.aim_yaw = atan2(-dir.x, -dir.z)
					p.aim_pitch = 0.0
					p.move_dir = Vector2(0, 1)
	if firing:
		_touch(6, _win(fire_c), false)
	_log("victory run: player_hp=%d bot_hp=%d t=%.1f" % [roundi(p.hp), roundi(b.hp), t])
	await _wait(1.5)
	await _shot("v2_end")
	var waited := 0.0
	while not arena.get("_result_shown") and waited < 30.0:
		await _wait(0.5)
		waited += 0.5
	await _wait(1.0)
	await _shot("v3_results")
	get_tree().quit(0)


## Renders the arena from a few spots and prints draw calls / primitives / objects per frame
## and node counts after two back-to-back matches (leak check). Needs a real renderer (Xvfb).
func _run_perf() -> void:
	var report := {}
	for round_i in 2:
		Game.goto_arena()
		var arena: Node = null
		for i in 300:
			await _wait(0.1)
			arena = _scene()
			if arena and arena.get("phase") == 1:
				break
		var p: Player = arena.get("player")
		var worst := {"draw_calls": 0, "primitives": 0, "objects": 0}
		for k in 8:
			p.aim_yaw = k * TAU / 8.0
			await _wait(0.4)
			var vp := get_viewport().get_viewport_rid()
			var dc := RenderingServer.viewport_get_render_info(vp, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
			var pr := RenderingServer.viewport_get_render_info(vp, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)
			var ob := RenderingServer.viewport_get_render_info(vp, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_OBJECTS_IN_FRAME)
			worst.draw_calls = maxi(worst.draw_calls, dc)
			worst.primitives = maxi(worst.primitives, pr)
			worst.objects = maxi(worst.objects, ob)
		report["round_%d" % round_i] = {"worst": worst, "nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
				"objects": Performance.get_monitor(Performance.OBJECT_COUNT), "orphans": Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
				"static_mem_mb": snappedf(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, 0.1)}
		_log("PERF round %d %s" % [round_i, JSON.stringify(report["round_%d" % round_i])])
	Game.goto_lobby()
	await _wait(1.0)
	_log("PERF lobby nodes=%d orphans=%d" % [Performance.get_monitor(Performance.OBJECT_NODE_COUNT), Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)])
	get_tree().quit(0)


## Aim-assist checks (headless): a frozen bot stands 14 m in front of the player.
##  1. start 3 deg off the chest, hold FIRE: the pull must bring the crosshair onto the body;
##  2. on the body, a fast upward drag while firing must stop on the head (no overshoot);
##  3. the bot strafes: with assist the crosshair stays on target more often than without;
##  4. crosshair_on_target (red crosshair) is true on the body, false 8 deg away.
## Prints AIM lines and exits 1 if a check fails.
func _run_aim() -> void:
	Game.settings.aim_assist = true
	Game.settings.aim_assist_strength = 60
	Game.goto_arena()
	var arena: Node = null
	for i in 300:
		await _wait(0.1)
		arena = _scene()
		if arena and arena.get("phase") == 1:
			break
	var p: Player = arena.get("player")
	var b: Bot = arena.get("bot")
	b.frozen = true
	b.invulnerable = true
	p.invulnerable = true
	# Same gun and settings every run (settings persist in user://, the map keeps changing).
	Game.settings.aim_precision = 0
	p.set_loadout("ar")
	b.set_loadout("ar")
	# Stand the bot 10-16 m from the player where the player has a clear view of its head and
	# chest (cover moves with map work, so a fixed spot is not enough).
	var placed := false
	for dist in [14.0, 12.0, 16.0, 10.0]:
		for ang in [0.0, 12.0, -12.0, 25.0, -25.0, 40.0, -40.0, 60.0, -60.0, 90.0, -90.0, 180.0]:
			var dir := Vector3(0, 0, -1).rotated(Vector3.UP, p.aim_yaw + deg_to_rad(ang))
			b.global_position = arena.call("closest_nav_point", p.global_position + dir * dist)
			await get_tree().physics_frame
			await get_tree().process_frame
			if absf(p.global_position.distance_to(b.global_position) - dist) < 3.0 \
					and p.can_see(b.chest_position()) and p.can_see(b.head_position()):
				placed = true
				break
		if placed:
			break
	_log("AIM setup: bot at %.1f m in clear view=%s" % [p.global_position.distance_to(b.global_position), placed])
	await _wait(0.5)
	var fails := 0 if placed else 1
	# 1. pull onto the body while firing
	_aim_at(p, b.chest_position())
	p.aim_yaw += deg_to_rad(3.0)
	p.set_firing(true)
	var acquired := -1.0
	for i in 60:
		await get_tree().physics_frame
		if p.crosshair_on_target and acquired < 0.0:
			acquired = i / 60.0
	p.set_firing(false)
	_log("AIM pull: on target after %.2fs (want < 0.6s)" % acquired)
	if acquired < 0.0 or acquired > 0.6:
		fails += 1
	# 2. drag up while firing -> head stop
	await _wait(0.3)
	_aim_at(p, b.chest_position())
	p.set_firing(true)
	await get_tree().physics_frame
	for i in 12:
		p.add_look(Vector2(0, -25), true)
		await get_tree().physics_frame
	var cam_dir := -p.camera.global_basis.z
	var head := b.head_position()
	var to_head := (head - p.camera.global_position).normalized()
	var pitch_err := rad_to_deg(asin(clampf(cam_dir.y, -1, 1)) - asin(clampf(to_head.y, -1, 1)))
	p.set_firing(false)
	_log("AIM head stop: crosshair %.2f deg vs head centre after a 300 px upward drag (want -1.5..+0.8)" % pitch_err)
	if pitch_err > 0.8 or pitch_err < -1.5:
		fails += 1
	# 3. strafing target, with and without assist
	var on := {}
	for assist in [false, true]:
		Game.settings.aim_assist = assist
		await _wait(0.3)
		_aim_at(p, b.chest_position())
		var base: Vector3 = b.global_position
		var hits := 0
		for i in 90:
			b.global_position = base + p.camera.global_basis.x * sin(i / 60.0 * 5.0) * 1.2
			await get_tree().physics_frame
			if p.crosshair_on_target:
				hits += 1
		b.global_position = base
		on[assist] = hits / 90.0
	_log("AIM tracking: on-target %.0f%% with assist vs %.0f%% without (want more with)" % [on[true] * 100.0, on[false] * 100.0])
	if on[true] <= on[false]:
		fails += 1
	# 4. red crosshair flag
	Game.settings.aim_assist = true
	for k in 3:   # the camera sits on the shoulder, so re-aim once it has moved
		_aim_at(p, b.chest_position())
		await get_tree().process_frame
		await get_tree().physics_frame
	var red_on := p.crosshair_on_target
	p.aim_yaw += deg_to_rad(8.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var red_off := p.crosshair_on_target
	_log("AIM red crosshair: on body=%s, 8 deg away=%s" % [red_on, red_off])
	if not red_on or red_off:
		fails += 1
	_log("AIM RESULT fails=%d" % fails)
	get_tree().quit(1 if fails > 0 else 0)

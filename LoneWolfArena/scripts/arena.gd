extends Node3D
## Match controller for one Lone Wolf round (1 vs 1 bot): builds the world, spawns the
## fighters, runs countdown -> fight -> result, the shrinking safe zone, pause menu and
## the results screen.

enum Phase { COUNTDOWN, FIGHT, END }

const MATCH_TIME := 180.0
const ZONE_START := 60.0
const ZONE_END := 165.0
const ZONE_MAX := 50.0
const ZONE_MIN := 9.0
const ZONE_DPS := 6.0
const BOT_NAMES := ["KAI", "REX", "VIPER", "NOVA", "BLAZE", "GHOST", "RAPTOR", "ONYX", "TITAN", "ZED"]

var fighters: Array[Fighter] = []
var player: Player
var bot: Bot
var hud: HUD
var map: MapBuilder
var phase := Phase.COUNTDOWN
var time_left := MATCH_TIME
var elapsed := 0.0
var countdown := 3.6
var zone_center := Vector3.ZERO
var zone_radius := 999.0
var zone_shrinking := false
var zone_warning := ""
var map_half := MapBuilder.HALF
var obstacles: Array[Rect2] = []
var cover_points: Array[Vector3] = []
var nav_map := RID()
var env: WorldEnvironment
var sun: DirectionalLight3D
var ui_layer: CanvasLayer
var pause_layer: CanvasLayer
var _zone_mesh: MeshInstance3D
var _last_count := 99
var _end_t := 0.0
var _result_shown := false
var _winner: Fighter
var _draw := false
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	Effects.load_textures()
	_build_environment()
	map = MapBuilder.new()
	map.build(self)
	obstacles = map.obstacles
	cover_points = map.cover_points
	_build_zone()
	_spawn_fighters()
	ui_layer = CanvasLayer.new()
	ui_layer.layer = 5
	add_child(ui_layer)
	hud = HUD.new()
	ui_layer.add_child(hud)
	hud.bind(player, self)
	hud.pause_pressed.connect(open_pause)
	pause_layer = CanvasLayer.new()
	pause_layer.layer = 10
	pause_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(pause_layer)
	map.nav.bake_finished.connect(_on_nav_baked)
	map.nav.bake_navigation_mesh(true)
	apply_graphics()
	Game.settings_changed.connect(apply_graphics)
	Audio.stop_music()
	Audio.play_ambience("match_ambience", -14.0)
	hud.show_center("LONE WOLF", 1.6, UI.ACCENT, 84, "Defeat %s" % bot.display_name)
	if int(Game.profile.matches) < 3:
		hud.tips_time = 9.0


func _exit_tree() -> void:
	Engine.time_scale = 1.0
	Audio.stop_ambience()


# ---------------------------------------------------------------- world

func _build_environment() -> void:
	env = WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.22, 0.45, 0.84)
	sm.sky_horizon_color = Color(0.7, 0.81, 0.93)
	sm.ground_bottom_color = Color(0.25, 0.28, 0.25)
	sm.ground_horizon_color = Color(0.7, 0.8, 0.88)
	sm.sun_angle_max = 25.0
	sm.sun_curve = 0.12
	sky.sky_material = sm
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.65
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.tonemap_exposure = 0.95
	e.glow_enabled = true
	e.glow_intensity = 0.35
	e.glow_bloom = 0.04
	e.glow_hdr_threshold = 1.1
	e.fog_enabled = true
	e.fog_light_color = Color(0.72, 0.8, 0.9)
	e.fog_density = 0.0028
	e.fog_sky_affect = 0.25
	e.adjustment_enabled = true
	e.adjustment_saturation = 1.12
	e.adjustment_contrast = 1.04
	env.environment = e
	add_child(env)
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -35, 0)
	sun.light_color = Color(1.0, 0.95, 0.86)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 55.0
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.2
	sun.shadow_blur = 1.2
	add_child(sun)


func _build_zone() -> void:
	_zone_mesh = MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 1.0
	cm.bottom_radius = 1.0
	cm.height = 40.0
	cm.cap_top = false
	cm.cap_bottom = false
	cm.radial_segments = 64
	_zone_mesh.mesh = cm
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled;
uniform vec4 tint : source_color = vec4(0.35, 0.6, 1.0, 0.32);
void fragment() {
	float stripes = 0.5 + 0.5 * sin(UV.x * 220.0 + TIME * 3.0);
	float fade = smoothstep(1.0, 0.55, UV.y) * smoothstep(0.0, 0.25, UV.y);
	ALBEDO = tint.rgb;
	ALPHA = tint.a * (0.45 + 0.55 * stripes) * fade;
}
"""
	var m := ShaderMaterial.new()
	m.shader = sh
	_zone_mesh.material_override = m
	_zone_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_zone_mesh.visible = false
	add_child(_zone_mesh)


func _spawn_fighters() -> void:
	var bundle := String(Game.profile.bundle)
	player = Player.new()
	player.name = "Player"
	player.display_name = String(Game.profile.name)
	player.arena = self
	add_child(player)
	player.global_position = map.spawn_a
	player.setup_fighter(bundle)
	player.aim_yaw = PI
	player.frozen = true
	fighters.append(player)
	bot = Bot.new()
	bot.name = "Bot"
	bot.display_name = "BOT " + String(BOT_NAMES[_rng.randi() % BOT_NAMES.size()])
	bot.arena = self
	add_child(bot)
	bot.global_position = map.spawn_b
	var bot_bundles := ["desert", "neon", "shadow", "royal", "default"]
	bot.setup_fighter(String(bot_bundles[_rng.randi() % bot_bundles.size()]))
	bot.aim_yaw = 0.0
	bot.configure(int(Game.settings.difficulty), player)
	bot.frozen = true
	fighters.append(bot)
	for f in fighters:
		f.died.connect(_on_fighter_died)


func _on_nav_baked() -> void:
	nav_map = map.nav.get_navigation_map()
	bot.nav_ready = true


func random_nav_point() -> Vector3:
	if nav_map.is_valid():
		var p := NavigationServer3D.map_get_random_point(nav_map, 1, false)
		if p != Vector3.ZERO:
			return p
	return Vector3(_rng.randf_range(-30, 30), 0, _rng.randf_range(-30, 30))


func closest_nav_point(p: Vector3) -> Vector3:
	if nav_map.is_valid():
		return NavigationServer3D.map_get_closest_point(nav_map, p)
	return p


# ---------------------------------------------------------------- settings

func apply_graphics() -> void:
	var g := int(Game.settings.graphics)
	var vp := get_viewport()
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = [0.72, 0.88, 1.0][g]
	vp.msaa_3d = Viewport.MSAA_2X if g == 2 else Viewport.MSAA_DISABLED
	sun.shadow_enabled = g >= 1
	RenderingServer.directional_shadow_atlas_set_size(4096 if g == 2 else 2048, true)
	env.environment.glow_enabled = g >= 1
	Effects.lights_enabled = g >= 2
	if hud:
		hud.reload_layout()


# ---------------------------------------------------------------- match flow

func _physics_process(delta: float) -> void:
	match phase:
		Phase.COUNTDOWN:
			countdown -= delta
			var n := ceili(countdown)
			if countdown <= 3.0 and n != _last_count and n > 0:
				_last_count = n
				hud.show_center(str(n), 0.9, Color.WHITE, 130)
				Audio.play("countdown_beep", -2.0)
			if countdown <= 0.0:
				phase = Phase.FIGHT
				Game.mark("match started")
				hud.show_center("FIGHT!", 1.0, UI.ACCENT, 120)
				Audio.play("countdown_go", 0.0)
				for f in fighters:
					f.frozen = false
		Phase.FIGHT:
			time_left -= delta
			elapsed += delta
			_update_zone(delta)
			if time_left <= 0.0:
				_timeout()
		Phase.END:
			_end_t += delta / maxf(Engine.time_scale, 0.01)
			if _end_t > 1.0 and Engine.time_scale < 1.0:
				Engine.time_scale = 1.0
			if _end_t > 2.4 and not _result_shown:
				_show_results()


func _update_zone(delta: float) -> void:
	var to_start := ZONE_START - elapsed
	if to_start > 0.0 and to_start < 10.0:
		zone_warning = "SAFE ZONE SHRINKS IN %ds" % ceili(to_start)
	else:
		zone_warning = ""
	if elapsed < ZONE_START:
		return
	if not zone_shrinking:
		zone_shrinking = true
		_zone_mesh.visible = true
		hud.show_center("ZONE SHRINKING", 1.6, Color(0.5, 0.75, 1.0), 64)
	var t := clampf((elapsed - ZONE_START) / (ZONE_END - ZONE_START), 0.0, 1.0)
	zone_radius = lerpf(ZONE_MAX, ZONE_MIN, t)
	_zone_mesh.scale = Vector3(zone_radius, 1.0, zone_radius)
	_zone_mesh.global_position = zone_center + Vector3.UP * 19.0
	for f in fighters:
		if f.alive and not in_zone(f.global_position):
			f.take_damage(ZONE_DPS * delta, "zone", null, f.global_position)


func in_zone(p: Vector3) -> bool:
	return Vector2(p.x - zone_center.x, p.z - zone_center.z).length() <= zone_radius


func _timeout() -> void:
	if phase == Phase.END:
		return
	phase = Phase.END
	Game.mark("match over: time up")
	if absf(player.hp - bot.hp) < 0.5:
		_draw = true
	else:
		_winner = player if player.hp > bot.hp else bot
	hud.show_center("TIME UP", 2.0, Color.WHITE, 96)
	hud.match_over = true
	for f in fighters:
		f.frozen = true
	if _winner == player:
		player.model.play_victory()
		player.victory_cam = true
	hud.release_all()


func _on_fighter_died(victim: Fighter, killer: Fighter, headshot: bool) -> void:
	Game.mark("match over: %s eliminated" % ("player" if victim == player else "bot"))
	var weapon_name := ""
	if killer and is_instance_valid(killer):
		weapon_name = String(killer.weapon().def.name)
	var text := "%s  »  %s" % [killer.display_name if killer else "ZONE", victim.display_name]
	if weapon_name != "":
		text = "%s  [%s]  %s" % [killer.display_name, weapon_name, victim.display_name]
	if headshot:
		text += "  · HEADSHOT"
	hud.add_kill_feed(text, UI.ACCENT if killer == player else Color(1, 0.6, 0.55))
	if phase == Phase.END:
		return
	phase = Phase.END
	_winner = killer if killer and killer != victim else (player if victim == bot else bot)
	Engine.time_scale = 0.35
	for f in fighters:
		f.frozen = true
	hud.release_all()
	hud.match_over = true
	if victim == bot:
		hud.show_center("BOOYAH!", 2.5, UI.ACCENT, 110, "%s eliminated" % bot.display_name)
		player.model.play_victory()
		player.victory_cam = true
		Audio.play("victory_sting", 0.0)
	else:
		hud.show_center("ELIMINATED", 2.5, UI.BAD, 100, "by %s" % bot.display_name)
		Audio.play("defeat_sting", 0.0)


func on_gunshot(shooter: Fighter) -> void:
	for f in fighters:
		if f is Bot and f != shooter:
			(f as Bot).hear(shooter.global_position, 1.0)
	if shooter != player and hud:
		hud.reveal(shooter, 2.5)


func on_footstep(f: Fighter) -> void:
	for other in fighters:
		if other is Bot and other != f:
			(other as Bot).hear(f.global_position, 0.35)


func shake_camera(pos: Vector3, amount: float) -> void:
	if player and player.alive:
		var d := player.global_position.distance_to(pos)
		player.add_shake(amount * clampf(1.0 - d / 25.0, 0.0, 1.0))


# ---------------------------------------------------------------- results / pause

func _show_results() -> void:
	_result_shown = true
	Engine.time_scale = 1.0
	var won := _winner == player and not _draw
	var st := player.stats
	var acc := 0.0 if int(st.shots) == 0 else float(st.hits) / float(st.shots) * 100.0
	var xp := 40 + (120 if won else 0) + int(st.kills) * 60 + int(float(st.damage) / 4.0) + int(st.headshots) * 10
	var result := {
		"won": won, "draw": _draw, "kills": int(st.kills), "damage": int(st.damage), "headshots": int(st.headshots),
		"accuracy": acc, "time": elapsed, "xp": xp, "enemy": bot.display_name,
	}
	Game.record_match(result)
	var overlay := ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.55)
	UI.full_rect(overlay)
	pause_layer.add_child(overlay)
	var center := CenterContainer.new()
	UI.full_rect(center)
	pause_layer.add_child(center)
	var panel := UI.panel(UI.PANEL, 16)
	panel.custom_minimum_size = Vector2(640, 0)
	center.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	panel.add_child(v)
	var title_txt := "DRAW" if _draw else ("VICTORY" if won else "DEFEAT")
	var title_col := Color.WHITE if _draw else (UI.ACCENT if won else UI.BAD)
	var title := UI.outlined(UI.label(title_txt, 76, title_col, "title"), 6)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)
	var sub := UI.label("LONE WOLF  ·  vs %s  (%s)" % [bot.display_name, Game.DIFFICULTY_NAMES[int(Game.settings.difficulty)]], 20, UI.TEXT_DIM, "semi")
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(sub)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 14)
	v.add_child(grid)
	var cells := [
		["KILLS", str(int(st.kills))], ["DAMAGE", str(int(st.damage))], ["HEADSHOTS", str(int(st.headshots))],
		["ACCURACY", "%d%%" % roundi(acc)], ["TIME", "%d:%02d" % [int(elapsed) / 60, int(elapsed) % 60]], ["XP", "+%d" % xp],
	]
	for c in cells:
		var cell := UI.panel(UI.PANEL_2, 10)
		cell.custom_minimum_size = Vector2(190, 92)
		var cv := VBoxContainer.new()
		cv.alignment = BoxContainer.ALIGNMENT_CENTER
		var val := UI.label(String(c[1]), 40, UI.TEXT, "number")
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var cap := UI.label(String(c[0]), 16, UI.TEXT_DIM, "semi")
		cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cv.add_child(val)
		cv.add_child(cap)
		cell.add_child(cv)
		grid.add_child(cell)
	var lvl := UI.label("LEVEL %d" % Game.level(), 18, UI.ACCENT, "semi")
	lvl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(lvl)
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 10)
	bar.value = Game.level_progress() * 100.0
	bar.add_theme_stylebox_override("background", UI.box(Color(1, 1, 1, 0.1), 5, 0, Color.TRANSPARENT, 0.0))
	bar.add_theme_stylebox_override("fill", UI.box(UI.ACCENT, 5, 0, Color.TRANSPARENT, 0.0))
	v.add_child(bar)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 14)
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	var again := UI.button("PLAY AGAIN", 26, "primary", Vector2(260, 64))
	again.name = "PlayAgain"
	again.pressed.connect(Game.goto_arena)
	var lobby := UI.button("LOBBY", 26, "dark", Vector2(200, 64))
	lobby.name = "Lobby"
	lobby.pressed.connect(Game.goto_lobby)
	buttons.add_child(again)
	buttons.add_child(lobby)
	v.add_child(buttons)
	panel.modulate.a = 0.0
	panel.create_tween().tween_property(panel, "modulate:a", 1.0, 0.35)


func open_pause() -> void:
	if phase == Phase.END or get_tree().paused:
		return
	hud.release_all()
	get_tree().paused = true
	var root := Control.new()
	root.name = "PauseMenu"
	UI.full_rect(root)
	pause_layer.add_child(root)
	var overlay := ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.6)
	UI.full_rect(overlay)
	root.add_child(overlay)
	var center := CenterContainer.new()
	UI.full_rect(center)
	root.add_child(center)
	var panel := UI.panel(UI.PANEL, 16)
	panel.custom_minimum_size = Vector2(420, 0)
	center.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	panel.add_child(v)
	var title := UI.label("PAUSED", 48, UI.TEXT, "title")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)
	var resume := UI.button("RESUME", 26, "primary", Vector2(0, 62))
	resume.pressed.connect(func() -> void:
		root.queue_free()
		get_tree().paused = false)
	v.add_child(resume)
	var settings := UI.button("SETTINGS", 24, "dark", Vector2(0, 58))
	settings.pressed.connect(func() -> void:
		var sp := SettingsPanel.new()
		root.add_child(sp)
		sp.closed.connect(func() -> void:
			hud.reload_layout()))
	v.add_child(settings)
	var quit := UI.button("QUIT MATCH", 24, "danger", Vector2(0, 58))
	quit.pressed.connect(func() -> void:
		get_tree().paused = false
		Game.goto_lobby())
	v.add_child(quit)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if phase != Phase.END:
			open_pause()
	elif what == NOTIFICATION_APPLICATION_PAUSED:
		if phase == Phase.FIGHT and not get_tree().paused:
			open_pause()

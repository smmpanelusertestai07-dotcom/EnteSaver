extends Node3D
## Match controller for one Lone Wolf round (1 vs 1 bot) on the warehouse arena:
## PREP (spawn alcoves behind a red barrier, weapon pick for both players, red countdown)
## -> FIGHT (round banner, 90 s timer, safe zone that holds then shrinks) -> END (kill, time-out
## on HP, or an integrity flag) -> results screen. Also renders the top-down minimap image once,
## runs the pause menu and feeds the HUD and scoreboard.

enum Phase { PREP, FIGHT, END }

const PREP_TIME := 10.0
const ROUND_TIME := 90.0
const ZONE_HOLD := 25.0
const ZONE_SHRINK := 40.0
const ZONE_MIN := 4.0
const ROUNDS_TO_WIN := 1
const MODE_NAME := "LONE WOLF"
const BOT_NAMES := ["KAI", "REX", "VIPER", "NOVA", "BLAZE", "GHOST", "RAPTOR", "ONYX", "TITAN", "ZED"]

var fighters: Array[Fighter] = []
var player: Player
var bot: Bot
var hud: HUD
var map: MapBuilder
var phase := Phase.PREP
var prep_left := PREP_TIME
var time_left := ROUND_TIME
var elapsed := 0.0
var round_index := 1
var rounds_to_win := ROUNDS_TO_WIN
var score := {"player": 0, "bot": 0}
var picked_weapon := ""
var zone_center := Vector3.ZERO
var zone_radius := 999.0
var zone_start_radius := 30.0
var zone_state := "stationary"      # "stationary" (before the shrink), "shrinking", "closed"
var zone_shrinking := false
var zone_warning := ""
var map_name := "CARGO CAGE"
var map_rect := Rect2(-22, -16, 44, 32)   # world XZ area shown by the minimap
var minimap_texture: Texture2D
var obstacles: Array[Rect2] = []
var cover_points: Array[Vector3] = []
var nav_map := RID()
var env: WorldEnvironment
var sun: DirectionalLight3D
var ui_layer: CanvasLayer
var pause_layer: CanvasLayer
var result := {}
var _zone_mesh: MeshInstance3D
var _outside := {}                  # fighter -> seconds outside the zone (never reset, like the reference)
var _last_count := 99
var _end_t := 0.0
var _result_shown := false
var _winner: Fighter
var _draw := false
var _invalid := false
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	Effects.load_textures()
	map = MapBuilder.new()
	map.build(self)
	env = map.env
	sun = map.sun
	obstacles = map.obstacles
	cover_points = map.cover_points
	map_rect = map.map_rect
	map_name = map.map_name
	zone_center = map.zone_center
	zone_start_radius = map.zone_start_radius
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
	Guard.tampered.connect(_on_tampered)
	Audio.stop_music()
	Audio.play_ambience("match_ambience", -16.0)
	Effects.warm_up(self)
	_render_minimap.call_deferred()
	_start_prep()


func _exit_tree() -> void:
	Engine.time_scale = 1.0
	Audio.stop_ambience()


# ---------------------------------------------------------------- world

func _build_zone() -> void:
	_zone_mesh = MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 1.0
	cm.bottom_radius = 1.0
	cm.height = 12.0
	cm.cap_top = false
	cm.cap_bottom = false
	cm.radial_segments = 64
	_zone_mesh.mesh = cm
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled;
uniform vec4 tint : source_color = vec4(0.35, 0.62, 1.0, 0.42);
void fragment() {
	float stripes = 0.5 + 0.5 * sin((UV.x * 260.0 + UV.y * 30.0) + TIME * 3.0);
	float fade = smoothstep(1.0, 0.35, UV.y) * smoothstep(0.0, 0.08, UV.y);
	ALBEDO = mix(tint.rgb, vec3(1.0), 0.25 * stripes);
	ALPHA = tint.a * (0.4 + 0.6 * stripes) * fade;
}
"""
	var m := ShaderMaterial.new()
	m.shader = sh
	_zone_mesh.material_override = m
	_zone_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_zone_mesh.visible = false
	add_child(_zone_mesh)


func _spawn_fighters() -> void:
	var pick := String(Game.settings.get("last_pick", Weapons.DEFAULT_PICK))
	if not Weapons.DEFS.has(pick):
		pick = Weapons.DEFAULT_PICK
	player = Player.new()
	player.name = "Player"
	player.display_name = String(Game.profile.name)
	player.arena = self
	add_child(player)
	player.global_position = map.spawn_a
	player.setup_fighter(String(Game.profile.bundle), pick)
	player.aim_yaw = map.spawn_a_yaw
	player.hold_fire = true
	fighters.append(player)
	bot = Bot.new()
	bot.name = "Bot"
	bot.display_name = "BOT " + String(BOT_NAMES[_rng.randi() % BOT_NAMES.size()])
	bot.arena = self
	add_child(bot)
	bot.global_position = map.spawn_b
	var bot_bundles := ["desert", "neon", "shadow", "royal", "default"]
	bot.setup_fighter(String(bot_bundles[_rng.randi() % bot_bundles.size()]), pick)
	bot.aim_yaw = map.spawn_b_yaw
	bot.configure(int(Game.settings.difficulty), player)
	bot.hold_fire = true
	bot.frozen = true
	fighters.append(bot)
	for f in fighters:
		f.died.connect(_on_fighter_died)
		_outside[f] = 0.0


func _on_nav_baked() -> void:
	nav_map = map.nav.get_navigation_map()
	bot.nav_ready = true


func random_nav_point() -> Vector3:
	if nav_map.is_valid():
		for i in 6:
			var p := NavigationServer3D.map_get_random_point(nav_map, 1, false)
			if p != Vector3.ZERO and in_zone(p):
				return p
	return zone_center + Vector3(_rng.randf_range(-8, 8), 0, _rng.randf_range(-8, 8))


func closest_nav_point(p: Vector3) -> Vector3:
	if nav_map.is_valid():
		return NavigationServer3D.map_get_closest_point(nav_map, p)
	return p


## Renders the arena once from straight above (roof and ceiling live on visual layer 2 and
## are skipped) into the minimap texture.
func _render_minimap() -> void:
	await get_tree().process_frame
	var vp := SubViewport.new()
	var aspect := map_rect.size.x / maxf(map_rect.size.y, 0.01)
	vp.size = Vector2i(roundi(512 * aspect), 512)
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	vp.transparent_bg = false
	add_child(vp)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = map_rect.size.y
	cam.cull_mask = 1
	cam.near = 0.5
	cam.far = 60.0
	vp.add_child(cam)
	var c := map_rect.get_center()
	cam.global_transform = Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(c.x, 30.0, c.y))
	cam.current = true
	var hidden: Array[Node3D] = []
	for f in fighters:
		if f.visible:
			f.visible = false
			hidden.append(f)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	for n in hidden:
		if is_instance_valid(n):
			n.visible = true
	var img := vp.get_texture().get_image()
	if img and not img.is_empty():
		minimap_texture = ImageTexture.create_from_image(img)
	vp.queue_free()


# ---------------------------------------------------------------- settings

func apply_graphics() -> void:
	var g := int(Game.settings.graphics)
	var vp := get_viewport()
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = [0.7, 0.85, 1.0, 1.0][clampi(g, 0, 3)]
	vp.msaa_3d = Viewport.MSAA_2X if g >= 2 else Viewport.MSAA_DISABLED
	if sun:
		sun.shadow_enabled = g >= 1
	RenderingServer.directional_shadow_atlas_set_size(4096 if g >= 3 else 2048, true)
	if env:
		env.environment.glow_enabled = g >= 1
	Effects.lights_enabled = g >= 2
	if map:
		map.apply_quality(g)
	if hud:
		hud.reload_layout()


# ---------------------------------------------------------------- match flow

func _start_prep() -> void:
	phase = Phase.PREP
	prep_left = PREP_TIME
	map.set_barriers(true)
	for f in fighters:
		f.hold_fire = true
	bot.frozen = true
	hud.show_center("LONE WOLF", 1.6, UI.ACCENT, 84, "%s  vs  %s" % [player.display_name, bot.display_name])
	hud.open_weapon_pick(Weapons.PICKABLE, String(Game.settings.get("last_pick", Weapons.DEFAULT_PICK)), PREP_TIME - 1.0, _on_weapon_picked)
	if int(Game.profile.matches) < 3:
		hud.tips_time = 9.0
	Game.mark("prep started")


## Both fighters get the picked gun (the reference mode's rule).
func _on_weapon_picked(id: String) -> void:
	if not Weapons.DEFS.has(id):
		id = Weapons.DEFAULT_PICK
	picked_weapon = id
	Game.settings.last_pick = id
	Game.save_settings()
	for f in fighters:
		f.set_loadout(id)
	Game.mark("weapon picked: " + id)


func _start_fight() -> void:
	phase = Phase.FIGHT
	if picked_weapon == "":
		hud.close_weapon_pick()
		_on_weapon_picked(String(Game.settings.get("last_pick", Weapons.DEFAULT_PICK)))
	map.set_barriers(false)
	for f in fighters:
		f.hold_fire = false
		f.frozen = false
	time_left = ROUND_TIME
	elapsed = 0.0
	zone_radius = zone_start_radius
	zone_state = "stationary"
	_zone_mesh.visible = true
	_update_zone_mesh()
	Game.mark("match started")
	hud.show_round_banner(round_index, map_name)
	Audio.play("countdown_go", 0.0)


func _physics_process(delta: float) -> void:
	match phase:
		Phase.PREP:
			prep_left -= delta
			var n := ceili(prep_left)
			if prep_left <= 3.0 and n != _last_count and n > 0:
				_last_count = n
				hud.show_center(str(n), 0.9, UI.BAD, 140)
				Audio.play("countdown_beep", -2.0)
			if prep_left <= 0.0:
				_start_fight()
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
			if _end_t > 2.6 and not _result_shown:
				_show_results()


## Seconds until the zone changes state (for the HUD's "SAFE ZONE SHRINKS IN" text).
func zone_next() -> float:
	if zone_state == "stationary":
		return maxf(ZONE_HOLD - elapsed, 0.0)
	if zone_state == "shrinking":
		return maxf(ZONE_HOLD + ZONE_SHRINK - elapsed, 0.0)
	return 0.0


func _update_zone(delta: float) -> void:
	var to_start := ZONE_HOLD - elapsed
	zone_warning = "SAFE ZONE SHRINKS IN %ds" % ceili(to_start) if to_start > 0.0 and to_start < 10.0 else ""
	if elapsed >= ZONE_HOLD:
		if zone_state == "stationary":
			zone_state = "shrinking"
			zone_shrinking = true
			hud.show_center("ZONE SHRINKING", 1.6, Color(0.5, 0.75, 1.0), 64)
			Audio.play("countdown_beep", -6.0, 0.7)
		var t := clampf((elapsed - ZONE_HOLD) / ZONE_SHRINK, 0.0, 1.0)
		zone_radius = lerpf(zone_start_radius, ZONE_MIN, t)
		if t >= 1.0:
			zone_state = "closed"
		_update_zone_mesh()
	for f in fighters:
		if f.alive and not in_zone(f.global_position):
			_outside[f] = float(_outside[f]) + delta
			var o: float = _outside[f]
			var dps := 5.0 if o < 10.0 else (10.0 if o < 20.0 else 20.0)
			f.take_damage(dps * delta, "zone", null, f.global_position)


func _update_zone_mesh() -> void:
	_zone_mesh.scale = Vector3(zone_radius, 1.0, zone_radius)
	_zone_mesh.global_position = zone_center + Vector3.UP * 6.0


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
		score["player" if _winner == player else "bot"] += 1
	hud.show_center("TIME UP", 2.0, Color.WHITE, 96, "DRAW" if _draw else ("HIGHER HP WINS: " + _winner.display_name))
	_freeze_all()
	if _winner == player:
		player.model.play_victory()
		player.victory_cam = true


func _freeze_all() -> void:
	hud.match_over = true
	hud.release_all()
	for f in fighters:
		f.frozen = true


func _on_fighter_died(victim: Fighter, killer: Fighter, headshot: bool) -> void:
	Game.mark("match over: %s eliminated" % ("player" if victim == player else "bot"))
	var weapon_icon := ""
	var weapon_name := "ZONE"
	if killer and is_instance_valid(killer):
		weapon_icon = String(killer.weapon().def.icon)
		weapon_name = String(killer.weapon().def.name)
	hud.add_kill_feed(killer.display_name if killer else "ZONE", victim.display_name, weapon_name, weapon_icon, headshot, killer == player)
	if phase == Phase.END:
		return
	phase = Phase.END
	_winner = killer if killer and killer != victim else (player if victim == bot else bot)
	score["player" if _winner == player else "bot"] += 1
	Engine.time_scale = 0.35
	_freeze_all()
	if victim == bot:
		hud.show_center("VICTORY!", 2.5, UI.ACCENT, 110, "%s eliminated" % bot.display_name)
		hud.kill_banner(bot.display_name, headshot)
		player.model.play_victory()
		player.victory_cam = true
		Audio.play("victory_sting", 0.0)
	else:
		hud.show_center("ELIMINATED", 2.5, UI.BAD, 100, "by %s" % (killer.display_name if killer else "the zone"))
		Audio.play("defeat_sting", 0.0)


func _on_tampered(reason: String) -> void:
	if phase == Phase.END:
		return
	_invalid = true
	phase = Phase.END
	_freeze_all()
	hud.show_center("INTEGRITY CHECK FAILED", 3.0, UI.BAD, 60, "this match will not count (%s)" % reason)


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
	if f != player and hud:
		hud.reveal(f, 1.0)


func shake_camera(pos: Vector3, amount: float) -> void:
	if player and player.alive:
		var d := player.global_position.distance_to(pos)
		player.add_shake(amount * clampf(1.0 - d / 25.0, 0.0, 1.0))


## Rows for the in-match scoreboard: you first, then the bot.
func scoreboard_rows() -> Array:
	var rows := []
	for f in [player, bot]:
		var st: Dictionary = f.stats
		var acc := 0.0 if int(st.shots) == 0 else float(st.hits) / float(st.shots) * 100.0
		rows.append({"name": f.display_name, "me": f == player, "alive": f.alive, "hp": roundi(f.hp),
			"kills": int(st.kills), "damage": int(st.damage), "headshots": int(st.headshots),
			"accuracy": roundi(acc), "rounds": int(score["player" if f == player else "bot"]),
			"weapon": String(f.gun().def.name)})
	return rows


# ---------------------------------------------------------------- results / pause

func _show_results() -> void:
	_result_shown = true
	Engine.time_scale = 1.0
	var won := _winner == player and not _draw and not _invalid
	var st := player.stats
	var acc := 0.0 if int(st.shots) == 0 else float(st.hits) / float(st.shots) * 100.0
	var xp := 0
	if not _invalid:
		# capped: a 1v1 round has one opponent
		xp = 40 + (120 if won else 0) + mini(int(st.kills), 1) * 60 + mini(int(float(st.damage) / 4.0), 120) + mini(int(st.headshots), 20) * 10
	result = {
		"won": won, "draw": _draw, "invalid": _invalid, "kills": int(st.kills), "damage": int(st.damage),
		"headshots": int(st.headshots), "accuracy": acc, "time": elapsed, "xp": xp, "enemy": bot.display_name,
		"mode": MODE_NAME, "map": map_name, "weapon": String(player.gun().def.name),
		"score_player": int(score.player), "score_bot": int(score.bot), "hp_left": roundi(player.hp),
		"difficulty": Game.DIFFICULTY_NAMES[int(Game.settings.difficulty)], "taken": int(st.taken),
	}
	if not _invalid:
		Game.record_match(result)
	var screen := ResultsScreen.new()
	pause_layer.add_child(screen)
	screen.setup(result)
	Game.mark("results shown")


func open_pause() -> void:
	if phase == Phase.END or get_tree().paused:
		return
	hud.release_all()
	get_tree().paused = true
	var menu := PauseMenu.new()
	pause_layer.add_child(menu)
	menu.closed.connect(func() -> void:
		get_tree().paused = false
		hud.reload_layout())


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if phase != Phase.END:
			open_pause()
	elif what == NOTIFICATION_APPLICATION_PAUSED:
		if phase == Phase.FIGHT and not get_tree().paused:
			open_pause()

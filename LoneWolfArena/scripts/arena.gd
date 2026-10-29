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
var practice := false      # Game.practice: a training dummy with endless HP, no zone, no clock, no record
var online := false        # Game.online: the "bot" is the other phone's player (RemoteFighter, see Lan/Cloud)
var _net_t := 0.0
var _net_begun := false
var _net_their_ready := false
var _net_timeup_t := -1.0


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
	practice = Game.practice
	online = Game.online and Game.session != null and bool(Game.session.get("in_session"))
	if Game.online and not online:
		Game.online = false
		Game.goto_lobby.call_deferred()        # the other phone left while this one was loading
		return
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
	if online:
		_net_setup()
	else:
		_start_prep()
	# A detection from before this match (a speed hack switched on in the lobby, a re-signed
	# APK) voids it too: Guard reports each reason only once per session.
	for reason in ["signature", "speed", "memory"]:
		if reason in Guard.flags:
			_on_tampered.call_deferred(reason)
			break


func _exit_tree() -> void:
	Engine.time_scale = 1.0
	Audio.stop_ambience()
	if online:
		Game.online = false
		Game.session.event_received.disconnect(_on_net_event)
		Game.session.state_received.disconnect(_on_net_state)
		Game.session.session_ended.disconnect(_on_net_ended)
		Game.session.end_session("left")


# ---------------------------------------------------------------- match against another phone (Lan or Cloud)

## Both phones load the arena at their own pace: each says "ready", and the host starts the prep
## on both once it has heard the guest.
func _net_setup() -> void:
	Game.session.event_received.connect(_on_net_event)
	Game.session.state_received.connect(_on_net_state)
	Game.session.session_ended.connect(_on_net_ended)
	var queued: Array = Game.session.queue.duplicate()
	Game.session.queue.clear()
	Game.session.send_event("ready")
	for q: Array in queued:
		_on_net_event(String(q[0]), q[1])
	Game.mark("wifi match: " + ("host" if Game.session.is_host else "guest"))


func _net_begin() -> void:
	if _net_begun:
		return
	_net_begun = true
	if Game.session.is_host:
		Game.session.send_event("begin")
	_start_prep()


func _on_net_state(s: PackedFloat32Array) -> void:
	(bot as RemoteFighter).apply_state(s)


func _on_net_event(kind: String, data: Array) -> void:
	var remote := bot as RemoteFighter
	match kind:
		"ready":
			_net_their_ready = true
			if Game.session.is_host:
				_net_begin()
		"begin":
			if not Game.session.is_host:
				_net_begin()
		"pick":
			if data.size() == 1 and Weapons.PICKABLE.has(String(data[0])):
				remote.set_loadout(String(data[0]))
		"shot":
			if data.size() == 6:
				remote.remote_shot(Vector3(float(data[0]), float(data[1]), float(data[2])), Vector3(float(data[3]), float(data[4]), float(data[5])))
		"hit":
			if data.size() == 5 and String(data[1]) in ["head", "body", "limb"]:
				player.take_damage(clampf(float(data[0]), 0.0, 2000.0), String(data[1]), remote, Vector3(float(data[2]), float(data[3]), float(data[4])))
		"died":
			if remote.alive and data.size() == 1:
				player.stats.kills += 1
				remote.die(player, bool(data[0]))
		"grenade":
			if data.size() == 6:
				var g := Grenade.new()
				g.thrower = remote
				g.cosmetic = true          # the thrower's phone deals its damage
				add_child(g)
				g.global_position = Vector3(float(data[0]), float(data[1]), float(data[2]))
				g.linear_velocity = Vector3(float(data[3]), float(data[4]), float(data[5])).limit_length(30.0)
		"wall":
			if data.size() == 4:
				var wall := ShieldWall.new()
				add_child(wall)
				var pos := Vector3(float(data[0]), float(data[1]), float(data[2]))
				var yaw := float(data[3])
				wall.global_position = pos
				wall.look_at(pos + Vector3(-sin(yaw), 0, -cos(yaw)), Vector3.UP)
		"timeup":
			if data.size() == 2 and not Game.session.is_host:
				_timeout(float(data[0]), float(data[1]))


func _on_net_ended(_reason: String) -> void:
	if phase == Phase.END:
		return
	hud.show_center("OPPONENT LEFT", 2.5, Color.WHITE, 80, "YOU WIN")
	var remote := bot as RemoteFighter
	if remote.alive:
		remote.die(null, false)


## Called by RemoteFighter for every hit this phone's player lands on it.
func net_hit(amount: float, zone: String, from_pos: Vector3) -> void:
	Game.session.send_event("hit", [amount, zone, from_pos.x, from_pos.y, from_pos.z])


func net_shot(origin: Vector3, dir: Vector3) -> void:
	if online:
		Game.session.send_event("shot", [origin.x, origin.y, origin.z, dir.x, dir.y, dir.z])


func net_grenade(pos: Vector3, vel: Vector3) -> void:
	if online:
		Game.session.send_event("grenade", [pos.x, pos.y, pos.z, vel.x, vel.y, vel.z])


func net_wall(pos: Vector3, fwd: Vector3) -> void:
	if online:
		Game.session.send_event("wall", [pos.x, pos.y, pos.z, atan2(-fwd.x, -fwd.z)])


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
	_zone_mesh.layers = CharacterModel.LAYER_ACTORS
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
	var guest: bool = online and not Game.session.is_host       # the invited phone starts at the other end
	player.global_position = map.spawn_b if guest else map.spawn_a
	player.setup_fighter(String(Game.profile.bundle), pick)
	player.aim_yaw = map.spawn_b_yaw if guest else map.spawn_a_yaw
	player.hold_fire = true
	fighters.append(player)
	bot = RemoteFighter.new() if online else Bot.new()
	bot.name = "Bot"
	bot.display_name = "BOT " + String(BOT_NAMES[_rng.randi() % BOT_NAMES.size()])
	bot.arena = self
	add_child(bot)
	bot.global_position = map.spawn_a if guest else map.spawn_b
	var bot_bundles := ["desert", "neon", "shadow", "royal", "default"]
	var bot_bundle := String(bot_bundles[_rng.randi() % bot_bundles.size()])
	if online:
		bot.display_name = String(Game.session.opponent.get("name", "PLAYER"))
		bot_bundle = String(Game.session.opponent.get("bundle", "default"))
	bot.setup_fighter(bot_bundle, pick)
	bot.aim_yaw = map.spawn_a_yaw if guest else map.spawn_b_yaw
	bot.configure(int(Game.settings.difficulty), player)
	bot.hold_fire = true
	bot.frozen = true
	if practice:
		bot.display_name = "TRAINING DUMMY"
		bot.endless_hp = true
		player.endless_hp = true
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
	# Characters, weapons and the zone wall live on visual layer 3, so the minimap camera
	# (cull mask 1) sees only the floor plan.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	if not is_inside_tree() or not is_instance_valid(vp):
		return
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
	hud.open_weapon_pick(Weapons.PICKABLE, String(Game.settings.get("last_pick", Weapons.DEFAULT_PICK)), PREP_TIME - 1.0, _on_weapon_picked)
	if int(Game.profile.matches) < 3:
		hud.tips_time = 9.0
	Game.mark("prep started")


## Both fighters get the picked gun (the reference mode's rule); on Wi-Fi each phone picks its
## own and tells the other.
func _on_weapon_picked(id: String) -> void:
	if not Weapons.DEFS.has(id):
		id = Weapons.DEFAULT_PICK
	picked_weapon = id
	Game.settings.last_pick = id
	Game.save_settings()
	for f in fighters:
		if not online or f == player:
			f.set_loadout(id)
	if online:
		Game.session.send_event("pick", [id])
	Game.mark("weapon picked: " + id)


func _start_fight() -> void:
	phase = Phase.FIGHT
	_net_timeup_t = -1.0
	if not practice:
		Game.count_match()
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
	_zone_mesh.visible = not practice
	_update_zone_mesh()
	Game.mark("match started")
	if practice:
		_place_dummy()
		zone_radius = 999.0
		hud.show_center("PRACTICE", 2.0, Color(1.0, 0.82, 0.22), 80, "THE DUMMY NEVER GOES DOWN")
	else:
		hud.show_round_banner(round_index, map_name)
	Audio.play("countdown_go", 0.0)


func _physics_process(delta: float) -> void:
	if online and phase != Phase.END:
		_net_t += delta
		if _net_t >= float(Game.session.state_interval):
			_net_t = 0.0
			Game.session.send_state(RemoteFighter.pack(player))
	match phase:
		Phase.PREP:
			prep_left -= delta
			var n := ceili(prep_left)
			if prep_left <= 3.0 and n != _last_count and n > 0:
				_last_count = n      # the HUD draws the prep countdown; this only beeps
				Audio.play("countdown_beep", -2.0)
			if prep_left <= 0.0:
				_start_fight()
		Phase.FIGHT:
			elapsed += delta
			if practice:
				time_left = elapsed          # the clock counts the practice time up
				_refill_practice_ammo()
			else:
				time_left -= delta
				_update_zone(delta)
				if time_left <= 0.0:
					if online and not Game.session.is_host:
						# The host's clock decides a time-out; decide alone if its word never comes.
						_net_timeup_t = maxf(_net_timeup_t, 0.0) + delta
						if _net_timeup_t > 3.0:
							_timeout()
					else:
						_timeout()
		Phase.END:
			_end_t += delta / maxf(Engine.time_scale, 0.01)
			if _end_t > 1.0 and Engine.time_scale < 1.0:
				Engine.time_scale = 1.0
			if _end_t > 2.6 and not _result_shown:
				_show_results()


## Practice: the bot stands still in the open centre bay, facing the player's spawn, and takes
## every hit without going down.
func _place_dummy() -> void:
	bot.frozen = true
	bot.hold_fire = true
	bot.global_position = closest_nav_point(zone_center)
	var d := player.global_position - bot.global_position
	bot.aim_yaw = atan2(-d.x, -d.z)


## Practice: the gun never runs dry (the magazine still needs reloading).
func _refill_practice_ammo() -> void:
	var w := player.weapon()
	if not w.infinite() and w.reserve < int(w.def.mag):
		w.reserve = int(w.def.get("reserve", 0))


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


func _timeout(my_hp := -1.0, their_hp := -1.0) -> void:
	if phase == Phase.END:
		return
	phase = Phase.END
	Game.mark("match over: time up")
	if my_hp < 0.0:
		my_hp = player.hp
		their_hp = bot.hp
		if online and Game.session.is_host:
			Game.session.send_event("timeup", [their_hp, my_hp])     # as the guest sees it: its HP first
	if absf(my_hp - their_hp) < 0.5:
		_draw = true
	else:
		_winner = (player as Fighter) if my_hp > their_hp else (bot as Fighter)
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
		f.round_over = true


func _on_fighter_died(victim: Fighter, killer: Fighter, headshot: bool) -> void:
	Game.mark("match over: %s eliminated" % ("player" if victim == player else "bot"))
	if online and victim == player:
		Game.session.send_event("died", [headshot])
	var weapon_icon := ""
	var weapon_name := "ZONE"
	if killer and is_instance_valid(killer):
		weapon_icon = String(killer.weapon().def.icon)
		weapon_name = String(killer.weapon().def.name)
	hud.add_kill_feed(killer.display_name if killer else "ZONE", victim.display_name, weapon_name, weapon_icon, headshot, killer == player)
	if phase == Phase.END:
		return
	phase = Phase.END
	_winner = killer if killer and killer != victim else ((player as Fighter) if victim == bot else (bot as Fighter))
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
	if _result_shown:
		return
	_invalid = true          # also when the fight is over but its result not yet recorded
	if phase == Phase.END:
		return
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
	# Read the masked values first: a tamper flag raised by that read still voids the match.
	var hp_left := roundi(player.hp)
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
		"score_player": int(score.player), "score_bot": int(score.bot), "hp_left": hp_left,
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
	if not online:                      # a Wi-Fi match keeps running on the other phone
		get_tree().paused = true
	var menu := PauseMenu.new()
	pause_layer.add_child(menu)
	Game.mark("pause opened")
	menu.closed.connect(func() -> void:
		if not online:
			get_tree().paused = false
		Game.mark("pause closed")
		hud.reload_layout())


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if phase != Phase.END:
			open_pause()
	elif what == NOTIFICATION_APPLICATION_PAUSED:
		if phase == Phase.FIGHT and not get_tree().paused:
			open_pause()

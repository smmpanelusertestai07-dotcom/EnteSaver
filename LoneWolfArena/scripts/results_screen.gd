class_name ResultsScreen
extends Control
## End-of-match results over the (still rendering) arena, in two pages. setup(result) gets the
## dictionary built by arena.gd: won, draw, invalid, kills, damage, headshots, accuracy, time, xp,
## enemy, mode (the name shown: TRAINING GROUND / LONE WOLF), mode_id ("training" / "lonewolf"),
## map, weapon, score_player, score_bot, hp_left, difficulty (the bot's level, or ONLINE against a
## player), taken, deaths; shots, hits and enemy_id go to the profile (Game.record_match).
## Mode + map stay top-left on both pages (node Head).
## Page 1 (node Page1, the first one shown): the player's own character in its outfit (HeroView: a
## CharacterModel with the profile's bundle in its own small 3D world; the victory pose for a win,
## the calm lobby stand otherwise) left of centre; on the right the medal, the big title (gold
## VICTORY / grey DEFEAT / white DRAW / red INVALID, node Title) with a short line of our own under
## it (Tagline), and a plate (HeroPlate) with the player's NAME, ELIMINATIONS and DAMAGE; the
## honour tag and the XP gained with an animated level bar bottom-left; CONTINUE (node Continue,
## 0.836-0.992 W) opens page 2.
## Page 2 (node Page2): the two sides under names drawn from SIDE_NAMES (side_names(): two
## different ones, the same all through a match; online both phones draw the same pair from the
## session and the host's side takes the first) with the round score "a VS b" (SideScore), then a
## table per side: K/D/A, DAMAGE first, then HEADSHOTS, ACCURACY, TIME, HP LEFT (node Stats with
## YourRow in blue and, when the arena offers scoreboard_rows(), EnemyRow in orange); LOBBY (grey,
## node Lobby) in CONTINUE's place.
## On both pages: PLAY AGAIN (yellow, node PlayAgain, 0.661-0.819 W) or the online REMATCH / PLAY
## AGAIN TOGETHER in its place, with the status line over it; buttons in the 0.88-0.96 H band.
## Works unpaused at time scale 1. Android back on page 2 = back to page 1; on page 1 = LOBBY
## (ignored while PLAY AGAIN's match loading runs).
## DUO / SQUAD (result.team, built by TeamArena._match_result): page 2 has both teams' tables side
## by side (TeamTables: TeamTable_0 blue, the player's team with the player first, and TeamTable_1
## orange; rows TeamRow_<n>, n the row's index in result.rows: name, K/D/A, DAMAGE, KNOCKS,
## REVIVES, HS, ACC); PLAY AGAIN for a match on this phone. A match between two phones offers the
## same two humans another one (see _build_online): PLAY AGAIN TOGETHER (node PlayAgainTogether) after
## a co-op TEAM INVITE match, REMATCH (node Rematch) after one against the other player, in PLAY
## AGAIN's place; none after a forfeit or once a player left (LOBBY only). ADD FRIEND for the other
## player of an online match against them, on the head of the opponent's table on page 2.

## The 1 vs 1 table's columns (value labels: value_name(column)).
const COLUMNS := ["K/D/A", "DAMAGE", "HEADSHOTS", "ACCURACY", "TIME", "HP LEFT"]
const NAME_W := 250.0
const MEDAL_SCALE := 0.62
## Our own side names: page 2 draws two different ones for a match (side_names).
const SIDE_NAMES := ["IRON WOLVES", "RED FANGS", "STORM RIDERS", "MIDNIGHT FOXES", "STEEL JACKALS", "ASH RAVENS",
	"GHOST PACK", "EMBER CLAWS", "FROST HOUNDS", "RUST VIPERS", "THUNDER MAWS", "SILENT TALONS", "CINDER BEARS",
	"NEON LYNX", "GRIM COYOTES", "SAND HAWKS", "VOLT SHARKS", "DUSK PANTHERS", "CRIMSON OWLS", "JADE SCORPIONS"]
## The short line under the title on page 1 (one picked per match).
const TAGLINES := {
	"victory": ["THE ARENA IS YOURS", "LAST ONE STANDING", "CLEAN WORK, WOLF", "THE PACK FOLLOWS YOU"],
	"defeat": ["SHAKE IT OFF AND HUNT AGAIN", "THIS ONE GOT AWAY", "EVERY WOLF FALLS ONCE", "THE NEXT ROUND IS YOURS"],
	"draw": ["NEITHER SIDE BACKED DOWN", "DEAD EVEN", "A STANDOFF TO REMEMBER"],
	"invalid": ["THIS MATCH DOES NOT COUNT"],
}

var _result := {}
var _kind := "victory"            # victory | defeat | draw | invalid
var _medal: Control
var _xp_bar: Control
var _xp_fill := 0.0               # 0..1 shown in the bar
var _xp_from := 0.0
var _level_label: Label
var _t := 0.0
var _built := false
var _again: Button
var _table: Control
var _levelled := false
var _xp_to := 0.0
var _lv_before := 1
var _xp_t0 := 0                   # ticks (ms) when the XP bar starts filling (real time)
var _intro_t0 := 0                # ticks (ms) of the intro (fade, medal pop, title slide)
var _title: Control
var _title_x := 0.0
var page := 1                     # the page shown: 1 (character, title, XP) or 2 (sides and tables)
var _page1: Control
var _page2: Control
var _continue: Button
var _lobby: Button
var _hero_vp: SubViewport         # the character's own 3D world (page 1)
var _friend_slot: Control         # where ADD FRIEND goes: the head of the opponent's table (page 2)
var _sides: PackedStringArray     # [this player's side name, the other side's]
var _enemy := {}                  # the opponent's scoreboard row ({} when the scene has none)
var _shades: Array[Control] = []  # the full-screen shades behind the content (see _fit_cutout)
var _team := false                # a DUO / SQUAD result (result.team)
var _team_online := false         # ... played between two phones
var _team_again := false          # ... that offers PLAY AGAIN TOGETHER / REMATCH (team_again_offered)
var _again_team := {}             # ... the same team again: {"size", "coop"} (Game.team_match)
const TEAM_COLUMNS := ["K/D/A", "DAMAGE", "KNOCKS", "REVIVES", "HS", "ACC"]
# An internet match (not one without internet): REMATCH and ADD FRIEND (see _build_online).
const INVITE_DELAY_MS := 700      # the fresh challenge goes out this long after the old session is left
const AWAIT_MS := 12000           # how long a phone waits for the other's fresh challenge
const GUEST_GRACE_MS := 2500      # with the session gone the old guest first waits this long for the host's
var _online := false
var _enemy_id := ""
var _peer_id := ""                # the other phone's player (the 1 vs 1 opponent, the teammate or the other team's player)
var _peer_name := ""
var _rematch: Button
var _friend: Button
var _status: Label
var _want := false                # this player tapped REMATCH
var _they_want := false           # the other player asked for it (their "rm", or their challenge came)
var _they_take := true            # the other phone takes this one's challenges (their "rm" said)
var _starting := false            # both want it: a fresh challenge is on its way
var _loading := false             # the rematch's match is loading
var _invite_ms := 0               # when this phone sends the fresh challenge (0: not now)
var _await_ms := 0                # until when this phone waits for the other's (0: not waiting)
const REMATCH_GREY_MS := 5000     # an opponent who left: REMATCH greys out this long after the results open
var _grey_at_ms := 0


func setup(result: Dictionary) -> void:
	_result = result
	UI.full_rect(self)
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_STOP
	if _built:
		return
	_built = true
	var won: bool = result.get("won", false)
	var is_draw: bool = result.get("draw", false)
	var invalid: bool = result.get("invalid", false)
	_kind = "invalid" if invalid else ("draw" if is_draw else ("victory" if won else "defeat"))
	_enemy_id = String(result.get("enemy_id", ""))
	_online = String(result.get("mode_id", "")) == "lonewolf" and result.get("local", false) != true and Game.is_player_id(_enemy_id)
	_peer_id = _enemy_id
	_peer_name = String(result.get("enemy", "THE OPPONENT"))
	_team = result.get("team", false) == true
	if _team:
		_online = false                   # (the 1 vs 1's REMATCH; a team match's own: _team_again)
		_team_online = result.get("online", Game.online or Game.team_match.get("online", false) == true) == true
		var other := other_player(Game.team_match)
		_team_again = _team_online and team_again_offered(result, Game.team_match)
		if _team_again:
			_peer_id = String(other.id)
			_peer_name = String(other.name)
			_again_team = {"size": int(Game.team_match.size), "coop": bool(Game.team_match.coop)}
	_hide_match_hud()
	_enemy = {} if _team else _enemy_row()
	_build()
	_animate_in()


## The in-match HUD (score bar, buttons, kill feed) goes away under the results.
func _hide_match_hud() -> void:
	var scene := get_tree().current_scene if is_inside_tree() else null
	var h: Variant = scene.get("hud") if scene else null
	if h is CanvasItem:
		(h as CanvasItem).visible = false


## The opponent's row from the arena's scoreboard (Arena.scoreboard_rows(), see
## design/INTERFACES.txt): kills, damage, headshots, accuracy, hp. {} without one.
func _enemy_row() -> Dictionary:
	var scene := get_tree().current_scene if is_inside_tree() else null
	if scene == null or not scene.has_method("scoreboard_rows"):
		return {}
	var rows: Variant = scene.call("scoreboard_rows")
	if rows is Array:
		for row: Variant in rows:
			if row is Dictionary and not bool((row as Dictionary).get("me", false)):
				return row
	return {}


static func honour(result: Dictionary) -> String:
	if result.get("invalid", false):
		return ""
	var alive := int(result.get("hp_left", 0)) > 0
	if int(result.get("headshots", 0)) >= 2:
		return "SHARPSHOOTER"
	if int(result.get("taken", 999)) < 50 and alive:
		return "UNTOUCHABLE"
	if bool(result.get("won", false)) and alive and int(result.get("hp_left", 0)) < 30:
		return "CLUTCH"
	return "FIGHTER"


func _title_text() -> String:
	return {"victory": "VICTORY", "defeat": "DEFEAT", "draw": "DRAW", "invalid": "INVALID"}[_kind]


func _palette() -> Array:
	# [title top, title bottom, medal light, medal dark]
	match _kind:
		"victory":
			return [Color(1, 0.97, 0.8), Color(1.0, 0.70, 0.08), Color(1.0, 0.84, 0.32), Color(0.78, 0.48, 0.02)]
		"defeat":
			return [Color(0.86, 0.86, 0.88), Color(0.52, 0.53, 0.56), Color(0.66, 0.67, 0.70), Color(0.33, 0.34, 0.37)]
		"draw":
			return [Color(1, 1, 1), Color(0.78, 0.84, 0.92), Color(0.86, 0.9, 0.96), Color(0.45, 0.52, 0.62)]
		_:
			return [Color(1, 0.62, 0.55), Color(0.86, 0.18, 0.14), Color(0.95, 0.4, 0.32), Color(0.55, 0.1, 0.08)]


## The screen's content stays clear of a camera cutout (UI.safe_margins); its shades reach under it.
func _fit_cutout() -> void:
	if not is_inside_tree():
		return
	var m := UI.safe_margins(get_viewport())
	offset_left = m.x
	offset_right = -m.y
	for s: Control in _shades:
		s.offset_left = -m.x
		s.offset_right = m.y


func _build() -> void:
	var r := _result
	var pal := _palette()
	# Backdrop: darken the arena, more on the left and at the bottom.
	var shade := ColorRect.new()
	shade.color = Color(0.02, 0.02, 0.04, 0.42)
	UI.full_rect(shade)
	add_child(shade)
	var side := UI.gradient_rect([[0.0, Color(0, 0, 0, 0.55)], [0.45, Color(0, 0, 0, 0.1)], [1.0, Color(0, 0, 0, 0.35)]], true)
	UI.full_rect(side)
	add_child(side)
	var low := UI.gradient_rect([[0.0, Color(0, 0, 0, 0)], [0.6, Color(0, 0, 0, 0.0)], [1.0, Color(0, 0, 0, 0.7)]])
	UI.full_rect(low)
	add_child(low)
	# Off a camera cutout: the screen keeps its content clear of it, its shades still reach the edges.
	_shades = [shade, side, low]
	var fit := Timer.new()
	fit.wait_time = 1.0
	fit.autostart = true
	fit.timeout.connect(_fit_cutout)
	add_child(fit)
	_fit_cutout.call_deferred()
	_sides = _pick_sides()
	_page1 = _page("Page1")
	_page2 = _page("Page2")
	_page2.visible = false
	# Mode + map, top-left (both pages).
	var head := VBoxContainer.new()
	head.name = "Head"
	head.position = Vector2(40, 24)
	head.add_theme_constant_override("separation", -6)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(head)
	head.add_child(UI.shadowed(UI.label(String(r.get("mode", Game.mode_name(String(r.get("mode_id", ""))))).to_upper(), 36, UI.TEXT, "heavy")))
	head.add_child(UI.shadowed(UI.label(String(r.get("map", "CARGO CAGE")).to_upper(), 28, Color(0.72, 0.72, 0.74), "heavy")))
	# (mode, map and the opponent only: a match of several picks has no one gun to name)
	var sub := UI.outlined(UI.label("VS %s  ·  %s" % [String(r.get("enemy", "BOT")).to_upper(), String(r.get("difficulty", "")).to_upper()],
		16, UI.TEXT, "bold"), 4)          # (outlined: readable over page 1's bright stage)
	head.add_child(UI.spacer(8))
	head.add_child(sub)
	# ---- page 1: the character, the medal and the big title with its line, the player's plate.
	_build_hero_view()
	_medal = Control.new()
	_medal.name = "Medal"
	_medal.anchor_left = 0.85
	_medal.anchor_right = 0.85
	_medal.offset_left = -190
	_medal.offset_right = 190
	_medal.offset_top = 70
	_medal.offset_bottom = 240
	_medal.pivot_offset = Vector2(190, 85)
	_medal.scale = Vector2.ONE * MEDAL_SCALE
	_medal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_medal.draw.connect(_draw_medal)
	if _kind == "defeat":
		_medal.material = _desaturate()
	_page1.add_child(_medal)
	var title := UI.shadowed(UI.outlined(UI.label(_title_text(), 80, Color.WHITE, "italic"), 11, Color(0.06, 0.04, 0.02, 0.95)), Vector2(0, 6), Color(0, 0, 0, 0.45))
	title.name = "Title"
	title.anchor_left = 0.25
	title.anchor_right = 0.75
	title.offset_top = 52
	title.offset_bottom = 148
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.material = Loading.gradient_text_material(pal[0], pal[1], 118.0)
	title.pivot_offset = Vector2(0, 59)
	UI.center_italic(title, 80)
	_page1.add_child(title)
	var line := UI.outlined(UI.label(tagline(_kind, _seed()), 22, Color(pal[0]).lerp(Color.WHITE, 0.4), "bold"), 4)
	line.name = "Tagline"
	line.anchor_left = 0.25
	line.anchor_right = 0.75
	line.offset_top = 140
	line.offset_bottom = 168
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_page1.add_child(line)
	var note := ""
	if _kind == "invalid":
		note = "INTEGRITY CHECK FAILED  -  THIS MATCH DOES NOT COUNT"
	elif bool(r.get("opponent_left", false)):
		note = "%s LEFT THE MATCH  -  THE WIN IS YOURS" % String(r.get("enemy", "THE OPPONENT")).to_upper()
	if note != "":
		var why := UI.outlined(UI.label(note, 17, Color(1, 0.6, 0.55) if _kind == "invalid" else Color(1.0, 0.86, 0.45), "bold"), 4)
		why.name = "InvalidNote" if _kind == "invalid" else "OpponentLeft"
		why.anchor_left = 0.25
		why.anchor_right = 0.75
		why.offset_top = 168
		why.offset_bottom = 192
		why.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		UI.ellipsis(why)
		_page1.add_child(why)
	_page1.add_child(_hero_plate())
	# ---- page 2: the side names with the round score, a table per side.
	_page2.add_child(_side_score())
	if _team:
		_build_team_tables()
	else:
		_build_table()
	_build_footer()


## A full-screen page layer (mouse passes through to its buttons).
func _page(node_name: String) -> Control:
	var c := Control.new()
	c.name = node_name
	UI.full_rect(c)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(c)
	return c


## Shows page `n` (1 or 2): CONTINUE on page 1, LOBBY on page 2; the character's world draws only
## while page 1 shows.
func show_page(n: int) -> void:
	page = clampi(n, 1, 2)
	if _page1:
		_page1.visible = page == 1
	if _page2:
		_page2.visible = page == 2
	if _continue:
		_continue.visible = page == 1
	if _lobby:
		_lobby.visible = page == 2
	if page == 2 and _page2:
		_page2.modulate.a = 0.0
		create_tween().tween_property(_page2, "modulate:a", 1.0, 0.2)


## The number this match's picks (side names, the tagline) come from: online the session's own
## (both phones alike), else one made from the result (the same for as long as the screen shows).
func _seed() -> int:
	var sess: Variant = Game.session if Game.online else null
	if sess != null and is_instance_valid(sess) and (sess as Object).has_method("match_seed"):
		return int((sess as Object).call("match_seed", "sides"))
	var r := _result
	return hash([String(r.get("mode_id", "")), String(r.get("enemy", "")), int(r.get("score_player", 0)), int(r.get("score_bot", 0)),
		int(r.get("damage", 0)), snappedf(float(r.get("time", 0.0)), 0.01)])


## Two different side names from SIDE_NAMES for `seed_value`: [first, second], always the same pair
## for the same number.
static func side_names(seed_value: int) -> PackedStringArray:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var a := rng.randi_range(0, SIDE_NAMES.size() - 1)
	var b := (a + rng.randi_range(1, SIDE_NAMES.size() - 1)) % SIDE_NAMES.size()
	return PackedStringArray([SIDE_NAMES[a], SIDE_NAMES[b]])


## The line under the title for a result of kind `kind` (victory / defeat / draw / invalid).
static func tagline(kind: String, seed_value: int) -> String:
	var lines: Array = TAGLINES.get(kind, TAGLINES.draw)
	return String(lines[absi(seed_value) % lines.size()])


## [this player's side name, the other side's]: every phone shows the same name for the same side
## (see sides_for).
func _pick_sides() -> PackedStringArray:
	return sides_for(side_names(_seed()), Game.team_match if _team else {}, Game.online and not _am_host())


## [this player's side name, the other side's] from the match's `pair` (side_names). A DUO / SQUAD
## (`team_match`: Game.team_match, not empty) names sides by team: team 0 (BLUE) takes the first of
## the pair, team 1 the second, so a co-op guest and the host, or every teammate of a group match,
## see one name for their own side. The 1 vs 1 (`team_match` empty) gives the host's side the first;
## `swap` is true on the other phone of an online 1 vs 1.
static func sides_for(pair: PackedStringArray, team_match: Dictionary, swap: bool) -> PackedStringArray:
	if not team_match.is_empty():
		var my_team := 0
		var slot := int(team_match.get("my_slot", 0))
		for e: Variant in team_match.get("roster", []):
			if e is Dictionary and int((e as Dictionary).get("slot", -1)) == slot:
				my_team = clampi(int((e as Dictionary).get("team", 0)), 0, 1)
		return PackedStringArray([pair[my_team], pair[1 - my_team]])
	if swap:
		return PackedStringArray([pair[1], pair[0]])
	return pair


func _am_host() -> bool:
	if _team:
		return bool(Game.team_match.get("host", true))
	var s := get_tree().current_scene if is_inside_tree() else null
	if s != null and s.has_method("hosted"):
		return bool(s.call("hosted"))
	var sess: Variant = Game.session
	return sess == null or not is_instance_valid(sess) or bool((sess as Object).get("is_host"))


## Page 1: the player's own character in its outfit, in a small 3D world of its own (transparent
## over the arena): the victory pose for a win, the calm lobby stand for a defeat or a draw; it
## turns a little toward the camera on a glowing disc in the side's blue.
func _build_hero_view() -> void:
	# The arena fades back behind page 1 (its own fighter must not read as a second character); a soft
	# glow in the result's colour stands behind ours.
	# Round 8: a bright stage of our own behind the hero (a lit hall: pale walls over a warm floor),
	# not the dimmed arena.
	var dim := UI.gradient_rect([[0.0, Color(0.56, 0.6, 0.66, 0.97)], [0.55, Color(0.78, 0.8, 0.84, 0.97)],
		[0.56, Color(0.5, 0.48, 0.44, 0.97)], [1.0, Color(0.3, 0.29, 0.28, 0.97)]])
	dim.name = "HeroBackdrop"
	UI.full_rect(dim)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_page1.add_child(dim)
	var g := Gradient.new()
	var glow_c: Color = Color(UI.ACCENT, 0.30) if _kind == "victory" else Color(UI.BLUE, 0.26)
	g.colors = PackedColorArray([glow_c, Color(glow_c, 0.0)])
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)
	var halo := TextureRect.new()
	halo.texture = gt
	halo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	halo.anchor_left = 0.26
	halo.anchor_right = 0.74
	halo.anchor_top = 0.12
	halo.anchor_bottom = 0.98
	halo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_page1.add_child(halo)
	var box := SubViewportContainer.new()
	box.name = "HeroView"
	box.anchor_left = 0.3
	box.anchor_right = 0.7
	box.anchor_top = 0.2
	box.anchor_bottom = 0.99
	box.stretch = true
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_page1.add_child(box)
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	box.add_child(vp)
	_hero_vp = vp
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.66, 0.74)
	env.ambient_light_energy = 0.8
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var cam := Camera3D.new()
	cam.fov = 36.0
	vp.add_child(cam)
	cam.look_at_from_position(Vector3(0, 1.0, 3.9), Vector3(0, 0.92, 0))
	cam.current = true
	var key := DirectionalLight3D.new()
	key.light_energy = 1.25
	key.light_color = Color(1.0, 0.93, 0.84)
	vp.add_child(key)
	key.look_at_from_position(Vector3(2.0, 3.0, 3.0), Vector3(0, 1, 0))
	for rim: Array in [[Vector3(-2.2, 2.4, -1.6), Color(0.3, 0.72, 1.0)], [Vector3(2.4, 2.2, -1.6), Color(1.0, 0.55, 0.25)]]:
		var l := OmniLight3D.new()
		l.position = rim[0]
		l.light_color = rim[1]
		l.light_energy = 3.0
		l.omni_range = 6.0
		vp.add_child(l)
	var disc := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.62
	cm.bottom_radius = 0.62
	cm.height = 0.02
	disc.mesh = cm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var glow: Color = UI.ACCENT if _kind == "victory" else UI.BLUE
	mat.albedo_color = Color(glow, 0.45)
	disc.material_override = mat
	vp.add_child(disc)
	var model := CharacterModel.new()
	model.name = "HeroModel"
	vp.add_child(model)
	model.rotation.y = PI - 0.15             # (faces the camera, a little turned)
	model.setup(String(Game.profile.get("bundle", "default")), false)
	if _kind == "victory":
		# WARDROBE > VICTORY POSE ("" = the game's own choice, the victory pose)
		var pose := String(Game.profile.get("victory_pose", ""))
		model.play_victory(pose if pose in Game.VICTORY_POSES and pose != "" else "victory_pose")
	else:
		model.play_lobby()


## Page 1's plate: the player's NAME (and level) over two cells, ELIMINATIONS and DAMAGE.
func _hero_plate() -> Control:
	var r := _result
	var plate := PanelContainer.new()
	plate.name = "HeroPlate"
	# Over the hero's chest (round 8, like the reference): x 0.42-0.58, y 0.57-0.67.
	plate.anchor_left = 0.42
	plate.anchor_right = 0.58
	plate.anchor_top = 0.57
	plate.anchor_bottom = 0.67
	plate.grow_horizontal = Control.GROW_DIRECTION_BOTH
	var st := UI.chamfer(Color(0.03, 0.05, 0.08, 0.82), 8, 0, Color.TRANSPARENT, 8.0, ["tl", "br"])
	plate.add_theme_stylebox_override("panel", st)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	plate.add_child(v)
	var top := HBoxContainer.new()
	v.add_child(top)
	var nm := UI.ellipsis(UI.label(String(Game.profile.get("name", "PLAYER")).to_upper(), 16, UI.TEXT, "heavy"))
	nm.name = "HeroName"
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(nm)
	var lv := UI.label("LV %d" % Game.level(), 12, UI.ACCENT, "bold")
	lv.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top.add_child(lv)
	var bar := ColorRect.new()
	bar.color = Color(UI.BLUE, 0.85)
	bar.custom_minimum_size = Vector2(0, 2)
	v.add_child(bar)
	var cells := HBoxContainer.new()
	cells.add_theme_constant_override("separation", 6)
	v.add_child(cells)
	for c: Array in [["ELIMINATIONS", int(r.get("kills", 0)), "HeroKills"], ["DAMAGE", int(r.get("damage", 0)), "HeroDamage"]]:
		var cell := VBoxContainer.new()
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.add_theme_constant_override("separation", -4)
		cells.add_child(cell)
		cell.add_child(UI.label(String(c[0]), 10, UI.TEXT_DIM, "bold"))
		var n := UI.label(str(c[1]), 22, UI.TEXT, "number")
		n.name = String(c[2])
		cell.add_child(n)
	return plate


## Page 2's top: [side name][a] VS [b][other side name], the player's side in blue.
func _side_score() -> Control:
	var r := _result
	var bar := HBoxContainer.new()
	bar.name = "SideScore"
	bar.anchor_left = 0.5
	bar.anchor_right = 0.5
	bar.offset_left = -330
	bar.offset_right = 330
	bar.offset_top = 128
	bar.offset_bottom = 176
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 10)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for i in 2:
		var nm := UI.ellipsis(UI.label(_sides[i], 24, UI.TEXT, "heavy"))
		nm.name = "SideName_%d" % i
		nm.custom_minimum_size = Vector2(210, 0)
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if i == 0 else HORIZONTAL_ALIGNMENT_LEFT
		nm.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		var num_p := PanelContainer.new()
		num_p.add_theme_stylebox_override("panel", UI.box(UI.BLUE if i == 0 else UI.ORANGE, 0, 0, Color.TRANSPARENT, 12.0))
		num_p.custom_minimum_size = Vector2(56, 48)
		var num := UI.label(str(int(r.get("score_player" if i == 0 else "score_bot", 0))), 34, UI.TEXT, "number")
		num.name = "SideRounds_%d" % i
		num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		num.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		num_p.add_child(num)
		if i == 0:
			bar.add_child(nm)
			bar.add_child(num_p)
			var vs := UI.outlined(UI.label("VS", 28, UI.TEXT, "italic"), 4)
			vs.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			bar.add_child(vs)
		else:
			bar.add_child(num_p)
			bar.add_child(nm)
	return bar


## Page 2, the 1 vs 1: a table per side (Stats: the player's side, then the opponent's when the
## arena has a scoreboard), each under its side name: K/D/A, DAMAGE, HEADSHOTS, ACCURACY, TIME,
## HP LEFT. ADD FRIEND (online) goes on the head of the opponent's table.
func _build_table() -> void:
	var r := _result
	var table := VBoxContainer.new()
	table.name = "Stats"
	table.anchor_left = 0.5
	table.anchor_right = 0.5
	table.offset_left = -560
	table.offset_right = 560
	table.offset_top = 192
	table.offset_bottom = 560
	table.add_theme_constant_override("separation", 2)
	_page2.add_child(table)
	_table = table
	resized.connect(_layout_table)
	_layout_table.call_deferred()
	# Your row (blue), then the opponent's (orange) when the arena has a scoreboard.
	var t := float(r.get("time", 0.0))
	table.add_child(_side_head(0))
	table.add_child(_column_head())
	table.add_child(_stat_row("YourRow", String(Game.profile.get("name", "PLAYER")), "LV %d" % Game.level(), [
		[kda(int(r.get("kills", 0)), int(r.get("deaths", 0)), int(r.get("assists", 0))), "raw"], [float(r.get("damage", 0)), "%d"],
		[float(r.get("headshots", 0)), "%d"], [float(r.get("accuracy", 0.0)), "%d%%"], [t, "time"], [float(r.get("hp_left", 0)), "%d"],
	], true))
	if not _enemy.is_empty():
		var e := _enemy
		table.add_child(UI.spacer(12))
		table.add_child(_side_head(1))
		table.add_child(_column_head())
		# Under the opponent's name: ONLINE (LOCAL without internet) for another player (LEFT once they
		# left the match), else BOT and its level.
		var online := String(r.get("mode_id", "")) == "lonewolf"
		var tag := "LEFT" if r.get("opponent_left", false) == true else ("LOCAL" if r.get("local", false) == true else "ONLINE")
		table.add_child(_stat_row("EnemyRow", String(e.get("name", r.get("enemy", "BOT"))).to_upper(),
			tag if online else "BOT  ·  %s" % String(r.get("difficulty", "")).to_upper(), [
			[kda(int(e.get("kills", 0)), int(e.get("deaths", 0)), int(e.get("assists", 0))), "raw"], [float(e.get("damage", 0)), "%d"],
			[float(e.get("headshots", 0)), "%d"], [float(e.get("accuracy", 0)), "%d%%"], [t, "time"], [float(e.get("hp", 0)), "%d"],
		], false))


## "kills/deaths/assists" as the tables show it.
static func kda(kills: int, deaths: int, assists: int) -> String:
	return "%d/%d/%d" % [kills, deaths, assists]


## The value label's node name of a 1 vs 1 table column ("K/D/A" -> Value_KDA, "HP LEFT" -> Value_HP_LEFT).
static func value_name(column: String) -> String:
	return "Value_" + column.replace("/", "").replace(" ", "_")


## The head of side `i`'s table (0: the player's, blue; 1: the other side's, orange): the side name,
## and on the other side's the place for ADD FRIEND (_friend_slot).
func _side_head(i: int) -> Control:
	var head := PanelContainer.new()
	head.name = "SideHead_%d" % i
	head.add_theme_stylebox_override("panel", UI.box(Color(UI.BLUE if i == 0 else UI.ORANGE, 0.9), 0, 0, Color.TRANSPARENT, 10.0))
	head.custom_minimum_size = Vector2(0, 48)
	var hh := HBoxContainer.new()
	hh.add_theme_constant_override("separation", 10)
	head.add_child(hh)
	var tl := UI.label(_sides[i], 20, UI.TEXT, "heavy")
	tl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hh.add_child(UI.ellipsis(tl))
	if i == 1:
		_friend_slot = hh
	return head


## The column names over a 1 vs 1 row.
func _column_head() -> Control:
	var header := PanelContainer.new()
	header.add_theme_stylebox_override("panel", UI.box(Color(0.19, 0.185, 0.18, 0.92), 0, 0, Color.TRANSPARENT, 0.0))
	header.custom_minimum_size = Vector2(0, 30)
	var hh := HBoxContainer.new()
	header.add_child(hh)
	var name_h := UI.label("NAME", 15, UI.TEXT_DIM, "bold")
	name_h.custom_minimum_size = Vector2(NAME_W, 0)
	name_h.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_h.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hh.add_child(name_h)
	for c: String in COLUMNS:
		var l := UI.label(c, 15, UI.TEXT_DIM, "bold")
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		hh.add_child(l)
	return header


## One table row: [avatar | name + sub] then the six values. Own row: blue, 64 px, bigger
## digits; opponent: orange tint, 54 px. Final values at once (a screenshot or a slow frame
## never shows placeholders); each number pops in turn.
func _stat_row(node_name: String, who_name: String, sub: String, values: Array, own: bool) -> Control:
	var row := Control.new()
	row.name = node_name
	row.custom_minimum_size = Vector2(0, 64 if own else 54)
	var base := Color(0.0, 0.32, 0.55, 0.92) if own else Color(0.36, 0.15, 0.06, 0.9)
	var cells := Color(0.02, 0.39, 0.6, 0.95) if own else Color(0.50, 0.21, 0.07, 0.9)
	var edge := Color(0.35, 0.75, 1.0, 0.9) if own else Color(1.0, 0.55, 0.3, 0.75)
	row.draw.connect(func() -> void:
		var s := row.size
		row.draw_rect(Rect2(Vector2.ZERO, s), base)
		row.draw_rect(Rect2(NAME_W, 0, s.x - NAME_W, s.y), cells)
		row.draw_rect(Rect2(NAME_W, 0, s.x - NAME_W, 2), edge)
		row.draw_rect(Rect2(NAME_W, s.y - 2, s.x - NAME_W, 2), edge)
		row.draw_rect(Rect2(0, 0, NAME_W, s.y), Color(0, 0, 0, 0.35)))
	var rh := HBoxContainer.new()
	UI.full_rect(rh)
	row.add_child(rh)
	var who := HBoxContainer.new()
	who.custom_minimum_size = Vector2(NAME_W, 0)
	who.add_theme_constant_override("separation", 10)
	rh.add_child(who)
	who.add_child(UI.spacer(0))
	var av := UI.texture("emblem.png")
	if av:
		var a := TextureRect.new()
		a.texture = av
		a.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		a.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		a.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		a.custom_minimum_size = Vector2(50, 50) if own else Vector2(42, 42)
		a.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		if not own:
			a.modulate = Color(1.0, 0.62, 0.48)
		who.add_child(a)
	if sub == "LEFT":
		who.add_child(left_mark())
	var nv := VBoxContainer.new()
	nv.alignment = BoxContainer.ALIGNMENT_CENTER
	nv.add_theme_constant_override("separation", -4)
	var pname := UI.ellipsis(UI.label(who_name, 24 if own else 21, UI.TEXT, "bold"))
	pname.custom_minimum_size = Vector2(168, 0)
	nv.add_child(pname)
	nv.add_child(UI.label(sub, 15 if own else 13, UI.ACCENT if own else Color(1.0, 0.72, 0.55), "bold"))
	who.add_child(nv)
	var i := 0
	for v in values:
		var txt := String(v[0]) if String(v[1]) == "raw" else _fmt(float(v[0]), String(v[1]))
		var l := UI.label(txt, 36 if own else 30, UI.TEXT, "number")
		l.name = value_name(COLUMNS[i])
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		rh.add_child(l)
		l.resized.connect(func() -> void: l.pivot_offset = l.size * 0.5)
		var tw := create_tween()
		tw.tween_interval(0.3 + i * 0.06 + (0.0 if own else 0.2))
		tw.tween_property(l, "scale", Vector2(1.3, 1.3), 0.08)
		tw.tween_property(l, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		i += 1
	return row


## Page 2, DUO / SQUAD: both teams' tables side by side under their side names (rows: result.rows,
## else the arena's scoreboard); ADD FRIEND (online, against them) on the head of the orange one.
func _build_team_tables() -> void:
	var rows: Array = _result.get("rows", []) if _result.get("rows") is Array else []
	if rows.is_empty():
		var scene := get_tree().current_scene if is_inside_tree() else null
		if scene != null and scene.has_method("scoreboard_rows"):
			rows = scene.call("scoreboard_rows")
	var box := HBoxContainer.new()
	box.name = "TeamTables"
	box.anchor_left = 0.5
	box.anchor_right = 0.5
	box.offset_left = -560
	box.offset_right = 560
	box.offset_top = 192
	box.offset_bottom = 580
	box.add_theme_constant_override("separation", 20)
	_page2.add_child(box)
	_table = box
	resized.connect(_layout_table)
	_layout_table.call_deferred()
	var n := maxi(int(_result.get("team_size", 0)), 1)
	for side in 2:
		var mine := side == 0
		var col := VBoxContainer.new()
		col.name = "TeamTable_%d" % side
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_theme_constant_override("separation", 2)
		box.add_child(col)
		col.add_child(_side_head(side))
		col.add_child(_team_cells("TeamHeader_%d" % side, "NAME", "", TEAM_COLUMNS, Color(0.19, 0.185, 0.18, 0.92), UI.TEXT_DIM, 14, 26))
		var shown := 0
		for i in rows.size():
			var row: Variant = rows[i]
			if not row is Dictionary:
				continue
			var d: Dictionary = row
			if bool(d.get("ally", bool(d.get("me", false)))) != mine:
				continue
			shown += 1
			var me := bool(d.get("me", false))
			var sub := "YOU" if me else ("BOT" if bool(d.get("bot", false)) else ("LEFT" if String(d.get("status", "")) == "left" else "PLAYER"))
			var vals := [kda(int(d.get("kills", 0)), int(d.get("deaths", 0)), int(d.get("assists", 0))), str(int(d.get("damage", 0))),
				str(int(d.get("knocks", 0))), str(int(d.get("revives", 0))), str(int(d.get("headshots", 0))), "%d%%" % int(d.get("accuracy", 0))]
			var base := Color(0.0, 0.32, 0.55, 0.92) if mine else Color(0.36, 0.15, 0.06, 0.9)
			if me:
				base = Color(0.02, 0.42, 0.68, 0.96)
			var line := _team_cells("TeamRow_%d" % i, String(d.get("name", "?")).to_upper(), sub, vals, base, UI.TEXT, 22 if n <= 2 else 19,
				44 if n <= 2 else 36)
			col.add_child(line)
		if shown == 0:
			col.add_child(UI.label("NO PLAYERS", 15, UI.TEXT_DIM, "bold"))


## Page 2 (round 8): a small red LEFT mark in front of the row of a player who left the match.
static func left_mark() -> Control:
	var l := UI.label("LEFT", 11, Color.WHITE, "bold")
	l.name = "LeftMark"
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UI.box(Color(0.82, 0.12, 0.1, 0.95), 0, 0, Color.TRANSPARENT, 3.0))
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.add_child(l)
	return p


## One row of a team table: name (+ a small line under it) then the values, each in its own cell.
func _team_cells(node_name: String, who: String, sub: String, values: Array, bg: Color, ink: Color, fs: int, h: int) -> Control:
	var row := PanelContainer.new()
	row.name = node_name
	row.add_theme_stylebox_override("panel", UI.box(bg, 0, 0, Color.TRANSPARENT, 4.0))
	row.custom_minimum_size = Vector2(0, h)
	var rh := HBoxContainer.new()
	rh.add_theme_constant_override("separation", 0)
	row.add_child(rh)
	if sub == "LEFT":
		rh.add_child(left_mark())
	var nv := VBoxContainer.new()
	nv.alignment = BoxContainer.ALIGNMENT_CENTER
	nv.add_theme_constant_override("separation", -4)
	nv.custom_minimum_size = Vector2(150, 0)
	nv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nv.size_flags_stretch_ratio = 2.3
	var nl := UI.ellipsis(UI.label(who, fs if sub != "" else 14, ink, "bold"))
	nl.name = "Name"
	nv.add_child(nl)
	if sub != "":
		nv.add_child(UI.label(sub, 11, UI.ACCENT if sub == "YOU" else Color(1, 1, 1, 0.65), "bold"))
	rh.add_child(nv)
	for i in values.size():
		var l := UI.label(String(values[i]), fs if sub != "" else 13, ink, "number" if sub != "" else "bold")
		l.name = "Value_%d" % i
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.size_flags_stretch_ratio = 1.5 if i == 0 else 1.0       # (K/D/A: "12/3/1")
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.clip_text = true
		rh.add_child(l)
	return row


func _layout_table() -> void:
	if _table == null:
		return
	var vw := size.x if size.x > 10.0 else get_viewport_rect().size.x
	var w := minf(vw - 80.0, 1120.0)
	_table.offset_left = -w * 0.5
	_table.offset_right = w * 0.5


func _fmt(x: float, fmt: String) -> String:
	if fmt == "time":
		var s := int(x)
		return "%d:%02d" % [s / 60, s % 60]
	return fmt % roundi(x)


func _build_footer() -> void:
	var r := _result
	# Honour tag: right end at 0.37 W, just above the XP row (reference tag: x .18-.37, y .83-.88).
	var tag := honour(r)
	if tag != "":
		var slot := HBoxContainer.new()
		slot.name = "HonourSlot"
		slot.anchor_left = 0.026
		slot.anchor_right = 0.37
		slot.anchor_top = 0.828
		slot.anchor_bottom = 0.882
		slot.alignment = BoxContainer.ALIGNMENT_END
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_page1.add_child(slot)
		var tp := PanelContainer.new()
		tp.name = "Honour"
		var st := UI.chamfer(UI.ACCENT, 10, 0, Color.TRANSPARENT, 14.0, ["tl", "br"], 0.0)
		st.content_margin_top = 2
		st.content_margin_bottom = 2
		tp.add_theme_stylebox_override("panel", st)
		tp.size_flags_vertical = Control.SIZE_FILL
		tp.draw.connect(func() -> void:
			UI.draw_hazard(tp, Rect2(tp.size.x - 34, tp.size.y - 6, 24, 4), 4.0, Color(UI.INK, 0.6), Color.TRANSPARENT))
		var th := HBoxContainer.new()
		th.add_theme_constant_override("separation", 8)
		var icon_name: String = {"SHARPSHOOTER": "v_headshot", "UNTOUCHABLE": "v_helmet", "CLUTCH": "v_medkit"}.get(tag, "v_fist")
		var ic := UI.icon(icon_name, 26, UI.INK)
		ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		th.add_child(ic)
		var tl := UI.label(tag, 25, UI.INK, "heavy")
		tl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		th.add_child(tl)
		var note := UI.label({"SHARPSHOOTER": "2+ HEADSHOTS", "UNTOUCHABLE": "UNDER 50 DAMAGE TAKEN", "CLUTCH": "WON UNDER 30 HP"}.get(tag, "STOOD YOUR GROUND"), 13, Color(UI.INK, 0.7), "bold")
		note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		th.add_child(note)
		tp.add_child(th)
		slot.add_child(tp)
	# XP gained + level bar, bottom-left in the buttons' band: [+XP]  [LV n ... a / b XP][bar].
	var xp := int(r.get("xp", 0))
	var total := int(Game.profile.get("xp", 0))
	var recorded := Game.last_result == r
	var before := maxi(total - xp, 0) if recorded else total
	var after := before + xp
	var lv_before := 1 + before / Game.XP_PER_LEVEL
	var lv_after := 1 + after / Game.XP_PER_LEVEL
	_xp_from = float(before % Game.XP_PER_LEVEL) / Game.XP_PER_LEVEL
	var to := float(after % Game.XP_PER_LEVEL) / Game.XP_PER_LEVEL + float(lv_after - lv_before)
	var xr := HBoxContainer.new()
	xr.name = "XpRow"
	xr.anchor_left = 0.026
	xr.anchor_right = 0.37
	xr.anchor_top = 0.88
	xr.anchor_bottom = 0.96
	xr.add_theme_constant_override("separation", 14)
	xr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_page1.add_child(xr)
	var xpl := UI.shadowed(UI.label("+%d XP" % xp, 32, UI.ACCENT if xp > 0 else UI.TEXT_DIM, "number_italic"))
	xpl.name = "XpGain"
	xpl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	xr.add_child(xpl)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 3)
	xr.add_child(col)
	var top := HBoxContainer.new()
	col.add_child(top)
	_level_label = UI.label("LV %d" % lv_before, 17, UI.TEXT, "bold")
	_level_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_level_label)
	var lv_note := UI.label("%d / %d XP" % [after % Game.XP_PER_LEVEL, Game.XP_PER_LEVEL], 14, UI.TEXT_DIM, "bold")
	lv_note.name = "XpNote"
	top.add_child(lv_note)
	_xp_bar = Control.new()
	_xp_bar.custom_minimum_size = Vector2(0, 12)
	_xp_bar.draw.connect(_draw_xp)
	col.add_child(_xp_bar)
	_xp_fill = _xp_from
	_levelled = lv_after != lv_before
	_xp_to = to
	_lv_before = lv_before
	_xp_t0 = Time.get_ticks_msec() + 450
	# Buttons in the reference band: PLAY AGAIN (yellow) 0.661-0.819 W on both pages, CONTINUE (page 1)
	# and LOBBY (page 2, grey) 0.836-0.992 W; an internet match has REMATCH in PLAY AGAIN's place and
	# ADD FRIEND on the opponent's table (page 2).
	if _online:
		_build_online()
	elif _team and _team_online:
		_build_team_online()
	else:
		var again := UI.hero_button("PLAY AGAIN", 30, Vector2(0, 46))
		again.name = "PlayAgain"
		_place(again, 0.661, 0.819)
		_again = again
		again.pressed.connect(_play_again)
		add_child(again)
	var lobby := UI.button("LOBBY", 26, "light", Vector2(0, 46))
	lobby.name = "Lobby"
	_place(lobby, 0.836, 0.992)
	lobby.pressed.connect(Game.goto_lobby)
	add_child(lobby)
	_lobby = lobby
	var go := UI.button("CONTINUE", 26, "light", Vector2(0, 46))
	go.name = "Continue"
	_place(go, 0.836, 0.992)
	go.pressed.connect(show_page.bind(2))
	add_child(go)
	_continue = go
	show_page(1)
	_page2.modulate.a = 1.0


func _place(c: Control, x0: float, x1: float) -> void:
	c.anchor_left = x0
	c.anchor_right = x1
	c.anchor_top = 0.88                # 58 px on the 720 px canvas: a full touch target
	c.anchor_bottom = 0.96
	c.offset_left = 0
	c.offset_right = 0
	c.offset_top = 0
	c.offset_bottom = 0


func _play_again() -> void:
	if _again.disabled:
		return
	_again.disabled = true
	if Game.online:
		Game.goto_lobby()          # (a match without internet: the next one is paired in the lobby)
		return
	Loading.start_match(get_tree().current_scene)


## Android back: on page 2 back to page 1; on page 1 LOBBY, except while PLAY AGAIN's (or a
## rematch's) match loading runs.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST and is_inside_tree() and _built:
		if page == 2:
			show_page(1)
			return
		if (_again and _again.disabled) or _loading:
			return
		Game.goto_lobby()


# ---------------------------------------------------------------- online: REMATCH and ADD FRIEND

## An internet match's buttons: REMATCH (yellow, PLAY AGAIN's place), ADD FRIEND left of it while
## the two are not friends, and a status line above them.
## REMATCH needs both players. While the match's session is still up a tap tells the other phone
## ("rm", Arena.ask_rematch, with whether this phone takes their challenges), whose screen then says
## "<NAME> WANTS A REMATCH". Once both want it, both leave the old session and a fresh duel
## challenge goes from the phone whose challenge the other takes (the old host when both do: no two
## challenges crossing), INVITE_DELAY_MS later; the other phone takes it at once. With the session
## gone (the other went back to the lobby) a tap sends the fresh challenge itself (the old guest
## first waits GUEST_GRACE_MS for the host's). A challenge from the old opponent that comes here is
## their rematch: REMATCH takes it. After a forfeit (they left the match) REMATCH is off.
## DUO / SQUAD between two phones (_team_again) works the same way with the other phone's player:
## PLAY AGAIN TOGETHER after a co-op match ("<NAME> WANTS TO PLAY AGAIN"), REMATCH after one against
## them. The fresh invite is a team invite with the same size and coop (Cloud.team_invite, not
## quick), and once both want it only the old host sends it (it runs the bots: the same roles and
## sides). While the screen offers the button, Cloud lets that player's team invite of the same size
## and coop through to it (Cloud.play_again), friend or not: as ACCEPT, or taken at once after this
## player's tap. The new match is the team match of the session it starts (_on_session).
func _build_online() -> void:
	_status = UI.outlined(UI.label("", 19, UI.TEXT, "bold"), 4)
	_status.name = "RematchStatus"
	_status.anchor_left = 0.40
	_status.anchor_right = 0.992
	_status.anchor_top = 0.815
	_status.anchor_bottom = 0.87
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_status)
	_rematch = UI.hero_button(_caption(), 22 if _coop_again() else 30, Vector2(0, 46))
	_rematch.name = "PlayAgainTogether" if _coop_again() else "Rematch"
	_place(_rematch, 0.56 if _coop_again() else 0.661, 0.819)      # (co-op: no ADD FRIEND, room for the longer word)
	# Its Caption shows the state (_set_rematch); the button's own text stays for checks, never drawn.
	_rematch.clip_text = true
	for c: String in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color", "font_disabled_color"]:
		_rematch.add_theme_color_override(c, Color.TRANSPARENT)
	_rematch.pressed.connect(_on_rematch)
	add_child(_rematch)
	if bool(_result.get("opponent_left", false)):
		# Round 8, like the reference: the button keeps its yellow a moment (it cannot be taken),
		# then greys out with OPPONENT LEFT over it (_step_rematch, REMATCH_GREY_MS).
		_set_rematch(_caption(), false)
		_rematch.modulate.a = 1.0
		_grey_at_ms = Time.get_ticks_msec() + REMATCH_GREY_MS
		_say("%s LEFT: NO REMATCH" % _name(), UI.TEXT_DIM)
	if not _coop_again() and not Game.is_friend(_peer_id) and not Game.is_blocked(_peer_id):
		var asked := Game.cloud_service().friend_asked(_peer_id)
		_friend = UI.button("REQUEST SENT" if asked else "ADD FRIEND", 22, "dark" if asked else "light", Vector2(0, 46))
		_friend.name = "AddFriend"
		_friend.disabled = asked
		_friend.pressed.connect(_on_add_friend)
		_add_friend_button()
	if _rematch.disabled:
		return
	var cl := Game.cloud_service()
	if _team_again:
		# Their team invite reaches this screen (as ACCEPT, or taken at once after this player's tap)
		# for as long as the screen offers the button, not only after the tap: once the old session
		# is gone (a phone away, the relay dropped), each phone's fresh invite must still get through.
		cl.play_again = {"id": _peer_id, "size": int(_again_team.size), "coop": bool(_again_team.coop)}
	cl.invited.connect(_on_invited)
	cl.invite_answered.connect(_on_answered)
	cl.invite_cancelled.connect(_on_their_challenge_gone)
	cl.invite_failed.connect(_on_failed)
	cl.session_started.connect(_on_session)
	cl.session_ended.connect(_on_session_ended)
	var a := _arena()
	if a != null and a.has_signal("rematch_asked"):
		a.connect("rematch_asked", _on_they_want)
		if a.get("rematch_wanted") == true:
			_on_they_want.call_deferred()


## ADD FRIEND on the head of the opponent's table (page 2), else in the button band.
func _add_friend_button() -> void:
	if _friend_slot != null:
		_friend.custom_minimum_size = Vector2(190, 44)
		_friend.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_friend_slot.add_child(_friend)
	else:
		_place(_friend, 0.47, 0.645)
		_page2.add_child(_friend)


## DUO / SQUAD between two phones: PLAY AGAIN TOGETHER / REMATCH as the 1 vs 1's REMATCH
## (_build_online) when the results offer it (_team_again). Otherwise (a forfeit, a player left) no
## PLAY AGAIN: LOBBY, and ADD FRIEND for the other player of a match against them (in PLAY AGAIN's
## place) while the two are not friends.
func _build_team_online() -> void:
	if _team_again:
		_build_online()
		return
	if not Game.is_player_id(_enemy_id) or Game.is_friend(_enemy_id) or Game.is_blocked(_enemy_id):
		return
	_status = UI.outlined(UI.label("", 19, UI.TEXT, "bold"), 4)
	_status.name = "RematchStatus"
	_status.anchor_left = 0.40
	_status.anchor_right = 0.992
	_status.anchor_top = 0.815
	_status.anchor_bottom = 0.87
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_status)
	var asked := Game.cloud != null and Game.cloud.friend_asked(_enemy_id)
	_friend = UI.button("REQUEST SENT" if asked else "ADD FRIEND", 22, "dark" if asked else "light", Vector2(0, 46))
	_friend.name = "AddFriend"
	_friend.disabled = asked
	_friend.pressed.connect(_on_add_friend)
	_add_friend_button()


## The other phone's player in an online team match (`tm`: Game.team_match): {"id", "name"} of the
## roster's human who is not this player, {} when there is none.
static func other_player(tm: Dictionary) -> Dictionary:
	var roster: Variant = tm.get("roster")
	if not roster is Array or not bool(tm.get("online", false)):
		return {}
	for e: Variant in roster:
		if e is Dictionary and not bool((e as Dictionary).get("bot", true)) and int((e as Dictionary).get("slot", -1)) != int(tm.get("my_slot", 0)) \
				and Game.is_player_id((e as Dictionary).get("id")):
			return {"id": String(e.id), "name": String((e as Dictionary).get("name", "PLAYER"))}
	return {}


## Whether an online team match's results offer PLAY AGAIN TOGETHER / REMATCH (`r`: the result, `tm`:
## Game.team_match): only with the other phone's player known, never after a forfeit (they left:
## result.opponent_left), once a player left (a row LEFT), or after a match that ended early or was
## left (result.ended / left).
## After an all-human match (a GROUP's, Game.team_match "multi") only LOBBY: the group stays together
## in the lobby and its leader starts again from there.
static func team_again_offered(r: Dictionary, tm: Dictionary) -> bool:
	if bool(tm.get("multi", false)):
		return false
	if other_player(tm).is_empty() or bool(r.get("opponent_left", false)) or bool(r.get("ended", false)) or bool(r.get("left", false)) \
			or bool(r.get("invalid", false)):
		return false
	var rows: Variant = r.get("rows")
	if rows is Array:
		for row: Variant in rows:
			if row is Dictionary and String((row as Dictionary).get("status", "")) == "left":
				return false
	return true


## PLAY AGAIN TOGETHER after a co-op team match between two phones, else REMATCH.
func _caption() -> String:
	return "PLAY AGAIN TOGETHER" if _coop_again() else "REMATCH"


func _coop_again() -> bool:
	return _team_again and bool(_again_team.get("coop", false))


## The word in the status line: PLAY AGAIN (co-op) or REMATCH.
func _word() -> String:
	return "PLAY AGAIN" if _coop_again() else "REMATCH"


## What starts or loads: THE NEXT MATCH (co-op) or THE REMATCH.
func _what() -> String:
	return "THE NEXT MATCH" if _coop_again() else "THE REMATCH"


func _wants() -> String:
	return "WANTS TO PLAY AGAIN" if _coop_again() else "WANTS A REMATCH"


## The arena behind (the current scene) when it offers the rematch's calls, else null.
func _arena() -> Node:
	var s := get_tree().current_scene if is_inside_tree() else null
	return s if s != null and s.has_method("leave_session") and s.has_method("ask_rematch") else null


func _name() -> String:
	return _peer_name.to_upper()


## Whether this phone's DUEL CHALLENGES FROM lets the opponent's challenge through.
func _takes_challenges() -> bool:
	var who := int(Game.settings.get("challenges_from", Game.CHALLENGES_EVERYONE))
	return who == Game.CHALLENGES_EVERYONE or (who == Game.CHALLENGES_FRIENDS and Game.is_friend(_peer_id))


func _say(text: String, col := UI.TEXT) -> void:
	if _status:
		_status.text = text
		_status.add_theme_color_override("font_color", col)


func _set_rematch(text: String, enabled: bool) -> void:
	if _rematch:
		_rematch.text = text
		UI.set_caption(_rematch, text)
		_rematch.disabled = not enabled
		_rematch.modulate.a = 1.0 if enabled else 0.6


func _on_rematch() -> void:
	if _starting or _rematch.disabled:
		return
	var cl := Game.cloud_service()
	if cl.has_invite() and is_rematch_invite(cl.invite_from(), _peer_id, _again_team if _team_again else {}):
		_take_challenge()                # their fresh challenge is here already: this tap takes it
		return
	_want = true
	if _team_again:
		cl.play_again = {"id": _peer_id, "size": int(_again_team.size), "coop": bool(_again_team.coop)}
	var a := _arena()
	if a != null and bool(a.call("ask_rematch", _takes_challenges())):
		if _they_want:
			_agree()
		else:
			_set_rematch("ASKED", false)
			_say("%s ASKED: WAITING FOR %s" % [_word(), _name()])
		return
	_challenge_now()                     # the match's session is gone


## The other player tapped REMATCH ("rm"): this screen asks, or both want it now.
func _on_they_want() -> void:
	if _they_want:
		return
	_they_want = true
	var a := _arena()
	_they_take = a == null or a.get("rematch_they_take") != false
	if _want:
		_agree()
	elif not _starting:
		_set_rematch(_caption(), true)
		_say("%s %s" % [_name(), _wants()], UI.ACCENT)


## Both want the rematch: out of the old session; the phone whose challenge the other takes sends
## a fresh one a moment later, the other one waits for it (and takes it at once). A team match's
## comes from the old host only (it runs the bots), so the old guest must take the host's.
func _agree() -> void:
	var a := _arena()
	var i_take := _takes_challenges()
	var host := a == null or bool(a.call("hosted"))
	# Who invites: the host when the guest takes its challenge, else the guest when the host takes
	# theirs (both phones work it out alike from the two answers).
	var guest_takes := _they_take if host else i_take
	var host_takes := i_take if host else _they_take
	var i_invite := guest_takes if host else (not guest_takes and host_takes)
	if _team_again and not guest_takes:
		_stop_wanting()
		_say("DUEL CHALLENGES FROM LEAVES THE HOST OUT: NO %s" % _word(), UI.BAD)
		_set_rematch(_caption(), false)
		return
	if not guest_takes and not host_takes:
		_stop_wanting()
		_say("DUEL CHALLENGES ARE OFF ON BOTH PHONES: NO REMATCH", UI.BAD)
		_set_rematch("REMATCH", false)
		return
	_starting = true
	_set_rematch("STARTING", false)
	_say("STARTING %s..." % _what(), UI.ACCENT)
	if a != null:
		a.call("leave_session")
	if i_invite:
		_invite_ms = Time.get_ticks_msec() + INVITE_DELAY_MS
	else:
		_await_ms = Time.get_ticks_msec() + AWAIT_MS
		var cl := Game.cloud_service()
		if cl.has_invite() and is_rematch_invite(cl.invite_from(), _peer_id, _again_team if _team_again else {}):
			_take_challenge()


## The match's session is gone: a fresh challenge from here (the old guest first gives the old
## host's a moment, so two do not cross).
func _challenge_now() -> void:
	_starting = true
	_set_rematch("STARTING", false)
	_say(("INVITING %s AGAIN..." if _coop_again() else "SENDING %s A REMATCH CHALLENGE...") % _name())
	var a := _arena()
	if a != null:
		a.call("leave_session")
	var host := a == null or bool(a.call("hosted"))
	_invite_ms = Time.get_ticks_msec() + (INVITE_DELAY_MS if host else GUEST_GRACE_MS)


func _send_challenge() -> void:
	var cl := Game.cloud_service()
	if cl.has_invite() and String(cl.invite_from().get("id", "")) == _peer_id:
		_take_challenge()                # theirs came first: take it rather than cross it
		return
	if cl.waiting_for() != "" and String(cl.opponent.get("id", "")) == _peer_id:
		return                           # (already sent)
	if not cl.peers.has(_peer_id):
		_give_up("%s IS NOT ONLINE NOW" % _name())
	elif not (cl.team_invite(_peer_id, int(_again_team.size), bool(_again_team.coop)) if _team_again else cl.invite(_peer_id)):
		_give_up("COULD NOT SEND THE CHALLENGE: TAP %s AGAIN" % _caption())
	else:
		_say("%s: WAITING FOR %s..." % [_word(), _name()], UI.ACCENT)


## Takes the old opponent's fresh challenge (out of the old session first: the new room is not
## this match's, which the arena leaving the tree later must not end).
func _take_challenge() -> void:
	_starting = true
	_invite_ms = 0
	_await_ms = 0
	var a := _arena()
	if a != null:
		a.call("leave_session")
	Game.cloud_service().answer(true)
	_set_rematch("STARTING", false)
	_say("STARTING %s..." % _what(), UI.ACCENT)


func _give_up(why: String) -> void:
	_starting = false
	_want = false
	_invite_ms = 0
	_await_ms = 0
	_say(why, UI.BAD)                    # (Cloud.play_again stays: their next invite still comes here)
	_set_rematch(_caption(), true)


## The rematch cannot be (a refusal shown): nothing goes out later either (_on_session_ended would
## otherwise send it once the old session ends), and Cloud no longer takes their team invite.
func _stop_wanting() -> void:
	_want = false
	_forget_play_again()


## Cloud stops showing that player's team invite here (Cloud.play_again: set while the screen offers
## PLAY AGAIN TOGETHER / REMATCH).
func _forget_play_again() -> void:
	if _team_again and Game.cloud != null and String(Game.cloud.play_again.get("id", "")) == _peer_id:
		Game.cloud.play_again = {}


## A challenge came in here: the old opponent's is their rematch (taken at once when this player
## wants one too); anyone else's is declined (no lobby to show it). After a team match only that
## player's team invite with the same size and coop is theirs; after a 1 vs 1 only their duel
## challenge (a TEAM INVITE from them is not the rematch).
func _on_invited(_who: String) -> void:
	var cl := Game.cloud_service()
	if not cl.has_invite():
		return                           # (answered already)
	var inv := cl.invite_from()
	if _loading or not is_rematch_invite(inv, _peer_id, _again_team if _team_again else {}):
		cl.answer(false)
		return
	if _want or _starting:
		_take_challenge()
	else:
		_they_want = true
		_set_rematch("ACCEPT", true)
		_say("%s %s" % [_name(), _wants()], UI.ACCENT)


## Whether an invite that came in on these results is the rematch: from the old opponent, with the
## team wanted (a team match's size and coop; after a 1 vs 1 none, a duel challenge).
static func is_rematch_invite(inv: Dictionary, peer_id: String, wanted_team: Dictionary) -> bool:
	var team: Variant = inv.get("team", {})
	return peer_id != "" and String(inv.get("id", "")) == peer_id and team is Dictionary and team == wanted_team


func _on_answered(accepted: bool, _who: String) -> void:
	if not accepted and _starting and not _loading:
		_give_up("%s DID NOT TAKE %s" % [_name(), _what()])


func _on_their_challenge_gone() -> void:
	if _they_want and not _starting and not _loading:
		_they_want = false
		_set_rematch(_caption(), true)
		_say("%s CALLED %s OFF" % [_name(), _what()], UI.TEXT_DIM)


func _on_failed(_who: String) -> void:
	if _starting and not _loading:
		_give_up("COULD NOT REACH %s" % _name())


## The rematch's session is up: its match loads (as an accepted challenge does in the lobby). After
## a team match it is the team match of that session (LobbyFriends.session_team_match: the same two
## humans, the old host hosting again), so team_arena_net loads.
func _on_session(_host: bool) -> void:
	if not _starting or _loading:
		return
	var cl := Game.cloud_service()
	if _team_again:
		var tm := LobbyFriends.session_team_match(cl) if cl.session_team == _again_team else {}
		if tm.is_empty():
			cl.end_session("left")         # (not the team asked for: nothing loads)
			_give_up("COULD NOT START %s" % _what())
			return
		Game.team_match = tm
	elif not cl.session_team.is_empty():
		cl.end_session("left")             # (a team session on a 1 vs 1's results never loads as a duel)
		_give_up("COULD NOT START %s" % _what())
		return
	_loading = true
	_invite_ms = 0
	_await_ms = 0
	_forget_play_again()
	Game.online = true
	Game.session = cl
	Game.room_rules = cl.session_rules.duplicate()
	_set_rematch("LOADING", false)
	if _friend:
		_friend.disabled = true
	_say("LOADING %s..." % _what(), UI.ACCENT)
	Loading.start_match(get_tree().current_scene)


## The match's session ended: the other player went back to the lobby. One that wanted the
## rematch gets a fresh challenge there.
func _on_session_ended(_reason: String) -> void:
	if _want and not _starting and not _loading:
		_challenge_now()


func _on_add_friend() -> void:
	if _friend == null or _friend.disabled:
		return
	if Game.cloud_service().request_friend(_enemy_id):
		_friend.text = "REQUEST SENT"
		_friend.disabled = true
	else:
		_say("COULD NOT SEND THE FRIEND REQUEST: TRY AGAIN", UI.BAD)


func _step_rematch() -> void:
	var now := Time.get_ticks_msec()
	if _grey_at_ms > 0 and now >= _grey_at_ms:
		_grey_at_ms = 0
		if _rematch:
			_rematch.modulate = Color(0.55, 0.55, 0.58, 0.85)
		_say("OPPONENT LEFT", UI.TEXT_DIM)
	if _invite_ms > 0 and now >= _invite_ms:
		_invite_ms = 0
		_send_challenge()
	if _await_ms > 0 and now >= _await_ms:
		_await_ms = 0
		if not _loading:
			_give_up("NO CHALLENGE CAME FROM %s" % _name())    # (a team match's play-again stops here too)


## Leaving (LOBBY, back): the old opponent's challenge waiting here is declined (the lobby would not
## show it), the fresh challenge or team invite this screen sent and nobody took yet is called off
## (the player left for the lobby and is not pulled into a match from there), and Cloud no longer
## takes a team invite for this screen (Cloud.play_again).
func _exit_tree() -> void:
	if not (_online or _team_again) or Game.cloud == null:
		return
	_forget_play_again()
	if _loading:
		return
	var cl := Game.cloud_service()
	if cl.has_invite() and String(cl.invite_from().get("id", "")) == _peer_id:
		cl.answer(false)
	if _starting and not cl.in_session and cl.waiting_for_id() == _peer_id and _peer_id != "":
		cl.cancel_invite()


## The XP bar fills over 0.9 s of real time (it never lags behind on slow frames).
func _step_xp() -> void:
	if _xp_bar == null or _xp_t0 == 0:
		return
	var k := clampf((Time.get_ticks_msec() - _xp_t0) / 900.0, 0.0, 1.0)
	if k <= 0.0:
		return
	var x := lerpf(_xp_from, _xp_to, 1.0 - pow(1.0 - k, 2.0))
	var lv := _lv_before + int(floor(x))
	_xp_fill = x - floor(x)
	if lv != _lv_before and _level_label.text != "LV %d" % lv:
		_level_label.text = "LV %d" % lv
		Audio.play("kill_confirm", -8.0)
	_xp_bar.queue_redraw()
	if k >= 1.0:
		_xp_t0 = 0


func _draw_xp() -> void:
	var s := _xp_bar.size
	var pts := UI.chamfer_points(Rect2(Vector2.ZERO, s), 5.0, ["br"])
	_xp_bar.draw_colored_polygon(pts, Color(0, 0, 0, 0.55))
	var w := s.x * clampf(_xp_fill, 0.0, 1.0)
	if w > 1.0:
		_xp_bar.draw_rect(Rect2(2, 2, w - 4, s.y - 4), UI.ACCENT)
		_xp_bar.draw_rect(Rect2(2, 2, w - 4, 3), Color(1, 0.95, 0.75))
	var old := s.x * clampf(_xp_from, 0.0, 1.0)
	if old > 1.0 and not _levelled:
		_xp_bar.draw_rect(Rect2(2, 2, old - 4, s.y - 4), Color(0.85, 0.6, 0.05))
	_xp_bar.draw_polyline(pts + PackedVector2Array([pts[0]]), Color(1, 1, 1, 0.25), 1.0)


func _draw_medal() -> void:
	var pal := _palette()
	var light: Color = pal[2]
	var dark: Color = pal[3]
	var c := Vector2(_medal.size.x * 0.5, 80)
	var shine := _kind == "victory" or _kind == "draw"
	# rays
	if shine:
		var n := 18
		for i in n:
			var a := TAU * i / n + _t * 0.15
			var a2 := a + TAU / n * 0.35
			_medal.draw_colored_polygon(PackedVector2Array([c, c + Vector2(cos(a), sin(a)) * 150.0, c + Vector2(cos(a2), sin(a2)) * 150.0]),
				Color(light, 0.10))
	# wings: three slanted bars each side
	for sgn: float in [-1.0, 1.0]:
		for k in 3:
			var y := c.y - 30 + k * 22
			var x0 := c.x + sgn * (78 + k * 6)
			var bar := 92.0 - k * 22.0
			var pts := PackedVector2Array([Vector2(x0, y), Vector2(x0 + sgn * bar, y - 10), Vector2(x0 + sgn * (bar - 14), y + 8), Vector2(x0, y + 14)])
			var cols := PackedColorArray([light, light.lerp(dark, 0.4), dark, dark])
			_medal.draw_polygon(pts, cols)
	# hexagon shield
	var hexo := PackedVector2Array()
	var hexi := PackedVector2Array()
	var colso := PackedColorArray()
	for i in 6:
		var a := TAU * i / 6.0 + PI / 6.0
		hexo.append(c + Vector2(cos(a), sin(a)) * 78.0)
		hexi.append(c + Vector2(cos(a), sin(a)) * 64.0)
		colso.append(light.lerp(dark, clampf((sin(a) + 1.0) * 0.5, 0.0, 1.0)))
	_medal.draw_polygon(hexo, colso)
	_medal.draw_colored_polygon(hexi, Color(0.07, 0.065, 0.06))
	var em := UI.texture("emblem.png")
	if em:
		var tint := Color.WHITE if _kind == "victory" else (Color(0.75, 0.75, 0.78) if _kind != "invalid" else Color(1, 0.5, 0.45))
		_medal.draw_texture_rect(em, Rect2(c - Vector2(56, 56), Vector2(112, 112)), false, tint)
	var outline := hexo.duplicate()
	outline.append(hexo[0])
	_medal.draw_polyline(outline, Color(1, 1, 1, 0.5), 2.0, true)


## Grey-out for the DEFEAT medal (the emblem art is orange).
static func _desaturate() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = "shader_type canvas_item;\nvoid fragment() {\n\tvec4 c = texture(TEXTURE, UV) * COLOR;\n\tfloat l = dot(c.rgb, vec3(0.299, 0.587, 0.114));\n\tCOLOR = vec4(vec3(l) * vec3(0.95, 0.97, 1.0), c.a);\n}\n"
	var m := ShaderMaterial.new()
	m.shader = sh
	return m


## Intro in real time (it finishes on time even when frames are slow): fade in, the medal pops,
## the title slides in from the left.
func _animate_in() -> void:
	_title = get_node_or_null("Title") as Control
	if _title:
		_title_x = _title.position.x
	_intro_t0 = Time.get_ticks_msec()
	_step_intro()


func _step_intro() -> void:
	if _intro_t0 == 0:
		return
	var e := (Time.get_ticks_msec() - _intro_t0) / 1000.0
	modulate.a = clampf(e / 0.25, 0.0, 1.0)
	var k := clampf(e / 0.5, 0.0, 1.0) - 1.0
	var pop := 1.0 + 2.70158 * k * k * k + 1.70158 * k * k          # back ease-out
	_medal.scale = Vector2.ONE * lerpf(0.4, 1.0, pop) * MEDAL_SCALE
	if _title:
		var kt := clampf((e - 0.1) / 0.4, 0.0, 1.0)
		_title.modulate.a = kt
		_title.position.x = _title_x - 60.0 * pow(1.0 - kt, 3.0)
	if e >= 0.6:
		_intro_t0 = 0


func _process(delta: float) -> void:
	_t += delta
	_step_intro()
	_step_xp()
	_step_rematch()
	if _medal and (_kind == "victory" or _kind == "draw"):
		_medal.queue_redraw()
	if _again:
		_again.queue_redraw()

class_name Loading
extends Control
## Boot / loading screen (the main scene) and the short "match loading" overlay.
##
## BOOT: full-bleed key art (assets/ui/keyart_clean.jpg, slow zoom), the logo lockup top-left,
## a very thin gold progress bar near the bottom with the percentage, rotating tips and the
## version. Meanwhile the heavy resources (character + animation GLBs, the props the arena and
## the fighters use, every sound) load on worker threads (ResourceLoader.load_threaded_request).
## They stay referenced by a small holder node under the root ("LoadingCache"), so later scene
## changes reuse them instead of reading the disk again; the sounds also go into Audio's cache.
## Then Game.goto_login() (the guest login, or the lobby). It never hangs: after TIMEOUT_S it moves
## on anyway; the files that are still loading then are collected by the holder as they finish
## (every threaded request gets its load_threaded_get, so no load token is left behind).
## On launch the intro sting (IntroSting) plays on top while the loads run; this screen leaves only
## after it. Automated runs (Game.autotest) skip both and go to the lobby (their scripts expect
## it) unless a screenshot tour sets `hold_for_test` to look at this screen.
##
## MATCH: Loading.start_match(host) puts an overlay on top of `host`: a teaching card (one of
## TOPICS drawn by us with dashed callouts, the logo top right), the match's own card under the
## topic's title (the mode, "TRAINING GROUND" or "LONE WOLF", with the match's chips, see
## match_info(), or for DUO / SQUAD team_info()) and "LOADING <MODE> (CARGO CAGE)..." over the
## progress line), loads the arena scene
## (Game.arena_scene()) on a thread for at least MATCH_MIN_S, then Game.goto_arena().

const TIMEOUT_S := 12.0
const BOOT_MIN_S := 2.4
const MATCH_MIN_S := 1.2
const MATCH_MAX_S := 6.0
## Prop GLBs loaded at boot. forklift and tank have no GLB yet (the map builds them from boxes
## and the loader skips missing files).
const PROPS := ["container", "container_40", "container_open", "crate", "wall_bay", "wall_column", "rollup_door",
	"roof_truss", "lamp_tube", "barrel", "pallet", "bollard", "fire_cabinet", "forklift", "tank",
	"weapon_ar", "weapon_smg", "weapon_sg", "weapon_pistol", "weapon_sniper", "medkit", "grenade", "shield_wall"]
const TIPS := [
	"Hold FIRE and drag to keep aiming while you shoot.",
	"Headshots hit 2 to 4 times harder, legs take less. Aim for the head.",
	"A medkit heals 75 HP over 4 seconds. Firing cancels it.",
	"Tap the wall or frag button to take it in hand, then FIRE to put it down or throw it.",
	"Put up a shield wall, then heal behind it.",
	"Push the joystick past the ring to sprint.",
	"Pick the gun in the 15-second prep: a 1 VS 1 shares it, DUO and SQUAD pick their own.",
	"In a 1 VS 1 a gun picked for two rounds rests for the 4 rounds after.",
	"Magazine empty up close? SWITCH to the WREN 9 sidearm: quicker than a reload.",
	"The first 20 seconds the zone covers the hall; then it closes until the clock runs out. Stay inside.",
	"Crouch or go prone to make yourself a smaller target.",
	"A frag does up to 150 damage after a 3-second fuse. A vest stops a third of it.",
]
const GOLD := Color(0.94, 0.745, 0.24)

## Screenshot tours set this to keep the boot screen up (no automatic lobby).
static var hold_for_test := false
## Checks set this to keep the match overlay up at least this many seconds (a slow phone's load).
static var delay_for_test := 0.0


## The root node "LoadingCache": keeps the boot preloads referenced (meta "resources") and
## collects the requests that were still in flight when the boot screen timed out.
class Cache extends Node:
	var pending: Array[String] = []

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		set_process(not pending.is_empty())

	func collect(paths: Array[String]) -> void:
		pending.append_array(paths)
		set_process(not pending.is_empty())

	func _process(_delta: float) -> void:
		var keep: Array = get_meta("resources", [])
		for i in range(pending.size() - 1, -1, -1):
			var st := ResourceLoader.load_threaded_get_status(pending[i])
			if st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				continue
			if st == ResourceLoader.THREAD_LOAD_LOADED or st == ResourceLoader.THREAD_LOAD_FAILED:
				var r := ResourceLoader.load_threaded_get(pending[i])
				if r:
					keep.append(r)
			pending.remove_at(i)
		set_meta("resources", keep)
		if pending.is_empty():
			set_process(false)

var mode := "boot"
var progress := 0.0                # shown value 0..1 (smoothed, never goes back)
var done := false
var _target := 0.0
var _paths: Array[String] = []
var _weights: Array[float] = []
var _t := 0.0
var _tip_t := 0.0
var _tip_i := 0
var _bar: Control
var _pct: Label
var _status: Label
var _tip: Label
var _art: TextureRect
var _arena_scene: Resource
var _match_status := "LOADING..."
## The teaching topic the match card shows (TOPICS key; a test may set it), random when "".
static var topic_for_test := ""
var _leaving := false
var _start_ms := 0


## Shows the match loading overlay above `host` and then starts the match.
static func start_match(host: Node) -> void:
	var layer := CanvasLayer.new()
	layer.layer = 100
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	var l := Loading.new()
	l.mode = "match"
	layer.add_child(l)
	host.add_child(layer)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	UI.full_rect(self)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_start_ms = Time.get_ticks_msec()
	_tip_i = randi() % TIPS.size()
	if mode == "boot":
		if Game.autotest != "" and not hold_for_test:
			Game.goto_login.call_deferred()
			return
		Game.mark("boot screen")
		_build_boot()
		IntroSting.play_over(self)          # the launch sting on top: the loads below run under it
		_start_boot_loads()
	else:
		_build_match()
		if ResourceLoader.exists("res://scenes/arena.tscn"):
			ResourceLoader.load_threaded_request("res://scenes/arena.tscn")
	modulate.a = 0.0
	create_tween().tween_property(self, "modulate:a", 1.0, 0.2 if mode == "boot" else 0.12)


# ---------------------------------------------------------------- layout

func _backdrop(zoom_from := 1.0) -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.05, 0.08)
	UI.full_rect(bg)
	add_child(bg)
	var tex := UI.texture("keyart_clean.jpg")
	if tex:
		_art = UI.cover(tex)
		_art.pivot_offset = Vector2.ZERO
		add_child(_art)
		_art.scale = Vector2(zoom_from, zoom_from)
	var top := UI.gradient_rect([[0.0, Color(0, 0, 0, 0.55)], [0.28, Color(0, 0, 0, 0.0)], [0.62, Color(0, 0, 0, 0.0)], [1.0, Color(0, 0, 0, 0.88)]])
	UI.full_rect(top)
	add_child(top)


func _build_boot() -> void:
	_backdrop(1.0)
	var lg_tex := UI.texture("logo.png")
	if lg_tex:
		var lg := TextureRect.new()
		lg.texture = lg_tex
		lg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		lg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
		lg.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		lg.anchor_left = 0.035
		lg.anchor_top = 0.045
		lg.anchor_right = 0.035
		lg.anchor_bottom = 0.045
		var h := 132.0
		lg.offset_right = h * lg_tex.get_width() / float(lg_tex.get_height())
		lg.offset_bottom = h
		lg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(lg)
	else:
		var t := UI.shadowed(UI.label("LONE WOLF ARENA", 54, UI.TEXT, "italic"))
		t.position = Vector2(48, 36)
		add_child(t)
	_build_bar("LOADING GAME FILES")
	var ver := UI.label("v%s" % ProjectSettings.get_setting("application/config/version", "1.0"), 15, Color(1, 1, 1, 0.55), "semi")
	ver.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	ver.offset_left = -260
	ver.offset_right = -22
	ver.offset_top = -34
	ver.offset_bottom = -10
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(ver)


## The progress line as the reference's loading card: 4 px at y = 0.92 H from x = 0.04 W to
## 0.96 W, the percentage above its right end, the status ("LOADING LONE WOLF (CARGO CAGE)...", small
## caps) above its left end, the tip in caps centred under it.
func _build_bar(status: String) -> void:
	_bar = Control.new()
	_bar.name = "ProgressLine"
	_bar.anchor_left = 0.04
	_bar.anchor_right = 0.96
	_bar.anchor_top = 0.92
	_bar.anchor_bottom = 0.92
	_bar.offset_top = -2
	_bar.offset_bottom = 2
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.draw.connect(_draw_bar)
	add_child(_bar)
	_pct = UI.label("0%", 20, UI.TEXT, "number")
	_pct.name = "ProgressPct"
	_pct.anchor_left = 0.8
	_pct.anchor_right = 0.96
	_pct.anchor_top = 0.92
	_pct.anchor_bottom = 0.92
	_pct.offset_top = -30
	_pct.offset_bottom = -6
	_pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_pct.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(_pct)
	_status = UI.label(status, 16, Color(1, 1, 1, 0.85), "heavy")
	_status.name = "ProgressStatus"
	_status.anchor_left = 0.04
	_status.anchor_right = 0.7
	_status.anchor_top = 0.92
	_status.anchor_bottom = 0.92
	_status.offset_top = -30
	_status.offset_bottom = -6
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(_status)
	_tip = UI.label("", 16, Color(1, 1, 1, 0.92), "heavy")
	_tip.name = "ProgressTip"
	_tip.anchor_left = 0.06
	_tip.anchor_right = 0.94
	_tip.anchor_top = 0.92
	_tip.anchor_bottom = 0.92
	_tip.offset_top = 8
	_tip.offset_bottom = 34
	_tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_tip.clip_text = true
	_tip.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	add_child(_tip)
	_show_tip()


func _draw_bar() -> void:
	var s := _bar.size
	_bar.draw_rect(Rect2(Vector2(0, 1), Vector2(s.x, s.y - 2)), Color(0, 0, 0, 0.6))
	_bar.draw_rect(Rect2(Vector2(0, 1), Vector2(s.x, 1)), Color(1, 1, 1, 0.08))
	var w := s.x * clampf(progress, 0.0, 1.0)
	if w > 0.5:
		_bar.draw_rect(Rect2(Vector2(0, 0), Vector2(w, s.y)), GOLD)
		_bar.draw_rect(Rect2(Vector2(0, 0), Vector2(w, 1.5)), Color(1, 0.93, 0.7, 0.9))
		# bright head with a soft glow
		_bar.draw_rect(Rect2(Vector2(w - 3, -2), Vector2(3, s.y + 4)), Color(1, 0.97, 0.85))
		_bar.draw_circle(Vector2(w - 1, s.y * 0.5), 9.0, Color(1, 0.8, 0.35, 0.18))


func _show_tip() -> void:
	if _tip == null:
		return
	_tip.text = String(TIPS[_tip_i % TIPS.size()]).to_upper()
	_tip.modulate.a = 0.0
	create_tween().tween_property(_tip, "modulate:a", 1.0, 0.35)


## What the match card says about the match being loaded: {"mode", "badge", "chips", "desc"}.
## Online it is LONE WOLF (FIRST TO n, 1 VS 1 ONLINE, the opponent's name), else TRAINING GROUND
## against the bot (FIRST TO n, 1 VS BOT, its level) or the target dummy.
static func match_info(online: bool, opponent: String, dummy: bool, difficulty: int, rounds: int, local := false) -> Dictionary:
	if online:
		return {"mode": Game.mode_name("lonewolf"), "badge": "1 VS 1",
			"chips": ["FIRST TO %d" % rounds, "1 VS 1 LOCAL" if local else "1 VS 1 ONLINE", "VS " + opponent],
			"desc": "Win the duel before the zone closes in."}
	if dummy:
		return {"mode": Game.mode_name("training"), "badge": "TRAINING",
			"chips": ["TARGET DUMMY", "ENDLESS HP", "NO ZONE"],
			"desc": "Practise your aim: the dummy never goes down."}
	var level := String(Game.DIFFICULTY_NAMES[clampi(difficulty, 0, Game.DIFFICULTY_NAMES.size() - 1)])
	return {"mode": Game.mode_name("training"), "badge": "1 VS 1",
		"chips": ["FIRST TO %d" % rounds, "1 VS BOT", "BOT: " + level],
		"desc": "Win the duel before the zone closes in."}


## The rounds a DUO / SQUAD match is played to: TeamArena.TEAM_ROUNDS_TO_WIN, or LW_ROUNDS_TO_WIN
## in test runs of the editor binary (never an exported game).
static func team_rounds_to_win() -> int:
	if not OS.has_feature("template") and OS.get_environment("LW_ROUNDS_TO_WIN") != "":
		return maxi(int(OS.get_environment("LW_ROUNDS_TO_WIN")), 1)
	return TeamArena.TEAM_ROUNDS_TO_WIN


## What the match card says about a DUO / SQUAD match (`tm`: Game.team_match): "2 VS 2" / "4 VS 4",
## FIRST TO n, and who plays: "WITH <NAME> VS BOTS" (a TEAM INVITE), "VS <NAME>" (a player found by
## the team search), "VS BOTS" (on this phone: TRAINING GROUND, or a search that found nobody, which
## says so: "NO PLAYER FOUND: YOUR TEAM VS BOTS").
static func team_info(tm: Dictionary, rounds: int) -> Dictionary:
	var n := int(tm.get("size", 2))
	var word := "DUO" if n <= 2 else "SQUAD"
	var mine := int(tm.get("my_slot", 0))
	var my_team := 0
	var mate := ""
	var foe := ""
	var level := 1
	for e: Variant in tm.get("roster", []):
		if e is Dictionary and int((e as Dictionary).get("slot", -1)) == mine:
			my_team = int((e as Dictionary).get("team", 0))
	for e: Variant in tm.get("roster", []):
		if not e is Dictionary:
			continue
		var d := e as Dictionary
		if bool(d.get("bot", true)):
			level = int(d.get("diff", 1))
		elif int(d.get("slot", -1)) != mine:
			if int(d.get("team", 0)) == my_team:
				mate = String(d.get("name", "PLAYER"))
			else:
				foe = String(d.get("name", "PLAYER"))
	var online := bool(tm.get("online", false))
	var training := String(tm.get("mode_id", "")) == "training"
	var chips := ["FIRST TO %d" % rounds, "%d VS %d" % [n, n]]
	var desc := "Knock the other team down, revive your teammates, win the round together."
	if online and mate != "":
		chips.append("WITH %s VS BOTS" % mate)
	elif online:
		chips.append("VS %s" % (foe if foe != "" else "PLAYER"))
	else:
		chips.append("VS BOTS")
		chips.append("BOT: " + String(Game.DIFFICULTY_NAMES[clampi(level, 0, Game.DIFFICULTY_NAMES.size() - 1)]))
		if not training:
			desc = "NO PLAYER FOUND: YOUR TEAM VS BOTS"
	return {"mode": Game.mode_name("training" if training else "lonewolf"), "badge": word,
		"chips": chips, "desc": desc}


## The match card is a teaching card, as the reference's loading screen: the topic's title by a
## yellow bar with a grey line under it (top left), a big diagram of it drawn by us with dashed
## yellow callouts (TeachCard), the logo top right, the match's own card (MatchCard: the mode, the
## chips, one line) under the title, and the progress line with "LOADING <MODE> (CARGO CAGE)...".
const TOPICS := {
	"zone": ["THE CLOSING ZONE", "Where the round is fought"],
	"wall": ["SHIELD WALL", "Cover you carry with you"],
	"rounds": ["ROUNDS", "How a match is won"],
}


func _build_match() -> void:
	_backdrop(1.12)
	var shade := ColorRect.new()
	shade.color = Color(0.02, 0.02, 0.04, 0.72)          # the art dim behind the diagram
	UI.full_rect(shade)
	add_child(shade)
	var online := Game.online and Game.session != null
	var opponent := String(Game.session.opponent.get("name", "")) if online else ""
	var info := match_info(online, opponent if opponent != "" else "PLAYER", Game.practice and not online,
		int(Game.settings.difficulty), Game.rounds_to_win(online), online and Game.session is Lan)
	if not Game.team_match.is_empty():
		info = team_info(Game.team_match, team_rounds_to_win())
	var topic := topic_for_test if TOPICS.has(topic_for_test) else String(TOPICS.keys()[randi() % TOPICS.size()])
	# The topic's title and line, top left.
	var head := VBoxContainer.new()
	head.name = "TeachHead"
	head.position = Vector2(48, 40)
	head.add_theme_constant_override("separation", 2)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(head)
	var title := UI.section(String(TOPICS[topic][0]), 32)
	title.name = "TeachTitle"
	head.add_child(title)
	var sub := UI.label(String(TOPICS[topic][1]), 19, UI.TEXT_DIM, "semi")
	sub.name = "TeachSub"
	head.add_child(sub)
	head.add_child(UI.spacer(14))
	# The match's own card under it: the mode, the chips, one line.
	var card := PanelContainer.new()
	card.name = "MatchCard"
	card.add_theme_stylebox_override("panel", UI.chamfer(Color(0.07, 0.065, 0.06, 0.82), 10, 1, Color(1, 1, 1, 0.1), 12.0, ["br"]))
	card.custom_minimum_size = Vector2(300, 0)
	card.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	head.add_child(card)
	var bv := VBoxContainer.new()
	bv.add_theme_constant_override("separation", 4)
	card.add_child(bv)
	var t_row := HBoxContainer.new()
	t_row.add_theme_constant_override("separation", 10)
	var badge := UI.label(" %s " % String(info.badge), 14, UI.INK, "heavy")
	badge.add_theme_stylebox_override("normal", UI.chamfer(UI.ACCENT, 5, 0, Color.TRANSPARENT, 4.0, ["br"]))
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	t_row.add_child(badge)
	var mode_l := UI.label(String(info.mode), 24, UI.AMBER, "heavy")
	mode_l.name = "MatchMode"
	t_row.add_child(mode_l)
	bv.add_child(t_row)
	var chips := HFlowContainer.new()
	chips.name = "MatchChips"
	chips.add_theme_constant_override("h_separation", 4)
	chips.add_theme_constant_override("v_separation", 4)
	for c: String in info.chips:
		var cp := PanelContainer.new()
		cp.add_theme_stylebox_override("panel", UI.chamfer(Color(1, 1, 1, 0.1), 4, 0, Color.TRANSPARENT, 8.0, []))
		cp.add_child(UI.label(c, 14, UI.TEXT, "bold"))
		chips.add_child(cp)
	bv.add_child(chips)
	var said := String(info.desc).begins_with("NO PLAYER FOUND")      # the team search found nobody: said plainly
	var desc := UI.label(String(info.desc), 16 if said else 14, UI.ACCENT if said else UI.TEXT_DIM, "heavy" if said else "semi")
	desc.name = "MatchDesc"
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(280, 0)
	bv.add_child(desc)
	# The logo, top right.
	var lg_tex := UI.texture("logo.png")
	if lg_tex:
		var lg := TextureRect.new()
		lg.name = "MatchLogo"
		lg.texture = lg_tex
		lg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		lg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
		lg.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		var h := 84.0
		var w := h * lg_tex.get_width() / float(lg_tex.get_height())
		lg.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
		lg.offset_left = -40.0 - w
		lg.offset_right = -40.0
		lg.offset_top = 30.0
		lg.offset_bottom = 30.0 + h
		lg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(lg)
	# The diagram in the middle.
	var teach := TeachCard.new()
	teach.name = "TeachCard"
	teach.topic = topic
	teach.rounds = Game.rounds_to_win(online) if Game.team_match.is_empty() else team_rounds_to_win()
	teach.anchor_left = 0.33
	teach.anchor_right = 0.75
	teach.anchor_top = 0.2
	teach.anchor_bottom = 0.8
	teach.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(teach)
	_match_status = "LOADING %s (CARGO CAGE)..." % String(info.mode)
	_build_bar(_match_status)


## The teaching diagram (ours, drawn): ZONE the arena from above with the closing ring, SHIELD WALL
## a fighter crouched behind a wall with shots stopping on it, ROUNDS the score band; each with
## dashed yellow callouts to short labels.
class TeachCard extends Control:
	var topic := "zone"
	var rounds := 5

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, Color(0.05, 0.05, 0.06, 0.85))
		draw_rect(r, Color(1, 1, 1, 0.85), false, 3.0)
		match topic:
			"wall":
				_wall(r)
			"rounds":
				_rounds(r)
			_:
				_zone(r)

	func _callout(at: Vector2, to: Vector2, text: String) -> void:
		draw_dashed_line(at, to, UI.ACCENT, 3.0, 9.0)
		draw_circle(at, 5.0, UI.ACCENT)
		var right := to.x >= at.x
		HudDraw.text(self, text, to + Vector2(8.0 if right else -8.0, 0), 18, UI.TEXT, 0 if right else 2, 3, "heavy")

	func _zone(r: Rect2) -> void:
		var c := r.get_center()
		var s := minf(r.size.x, r.size.y)
		# the hall from above: the floor, its containers
		var floor_r := Rect2(c - Vector2(s * 0.42, s * 0.42), Vector2(s * 0.84, s * 0.84))
		draw_rect(floor_r, Color(0.2, 0.21, 0.24))
		for b: Array in [[0.12, 0.15, 0.22, 0.1, Color(0.62, 0.22, 0.16)], [0.6, 0.12, 0.1, 0.24, Color(0.18, 0.36, 0.62)],
				[0.18, 0.66, 0.1, 0.22, Color(0.7, 0.48, 0.14)], [0.58, 0.7, 0.26, 0.1, Color(0.24, 0.5, 0.3)], [0.42, 0.42, 0.14, 0.14, Color(0.5, 0.5, 0.52)]]:
			draw_rect(Rect2(floor_r.position + Vector2(b[0], b[1]) * floor_r.size, Vector2(b[2], b[3]) * floor_r.size), b[4])
		# outside the ring: the zone's colour; the ring and where it closes to
		var ring_c := c + Vector2(s * 0.05, s * 0.03)
		var ring_r := s * 0.3
		draw_rect(floor_r, Color(0.3, 0.45, 0.95, 0.22))
		draw_circle(ring_c, ring_r, Color(0.2, 0.21, 0.24, 0.55))
		draw_arc(ring_c, ring_r, 0.0, TAU, 72, Color(1, 1, 1, 0.95), 3.0, true)
		draw_arc(ring_c, ring_r * 0.45, 0.0, TAU, 48, Color(1, 1, 1, 0.6), 2.0, true)
		for i in 4:
			var a := TAU * i / 4.0 + 0.6
			var p0 := ring_c + Vector2.from_angle(a) * ring_r * 0.92
			var p1 := ring_c + Vector2.from_angle(a) * ring_r * 0.55
			draw_line(p0, p1, Color(1, 1, 1, 0.7), 2.0, true)
			draw_colored_polygon(PackedVector2Array([p1, p1 + Vector2.from_angle(a + 2.6) * 9.0, p1 + Vector2.from_angle(a - 2.6) * 9.0]), Color(1, 1, 1, 0.7))
		_callout(ring_c + Vector2(-ring_r * 0.2, -ring_r * 0.1), Vector2(r.position.x - 30.0, r.position.y + r.size.y * 0.55), "SAFE ZONE")
		_callout(ring_c + Vector2.from_angle(-0.7) * ring_r, Vector2(r.end.x + 30.0, r.position.y + r.size.y * 0.18), "IT CLOSES IN")
		_callout(floor_r.position + floor_r.size * Vector2(0.92, 0.92), Vector2(r.end.x + 30.0, r.position.y + r.size.y * 0.82), "OUTSIDE: YOU LOSE HP")

	func _wall(r: Rect2) -> void:
		var g := r.position.y + r.size.y * 0.78
		draw_rect(Rect2(r.position.x + 6, g, r.size.x - 12, r.end.y - g - 6), Color(0.18, 0.18, 0.2))
		# the wall: a tall panel with its hazard stripes
		var wall := Rect2(r.position.x + r.size.x * 0.52, r.position.y + r.size.y * 0.34, r.size.x * 0.06, g - r.position.y - r.size.y * 0.34)
		draw_rect(wall, Color(0.35, 0.62, 0.95, 0.85))
		draw_rect(wall, Color(0.8, 0.9, 1.0), false, 2.0)
		UI.draw_hazard(self, Rect2(wall.position.x, wall.position.y, wall.size.x, 10.0), 6.0)
		# the fighter crouched behind it (a simple figure of ours)
		var fx := r.position.x + r.size.x * 0.4
		var col := Color(0.92, 0.92, 0.94)
		draw_circle(Vector2(fx, g - r.size.y * 0.3), r.size.y * 0.045, col)
		draw_colored_polygon(PackedVector2Array([Vector2(fx - r.size.x * 0.05, g - r.size.y * 0.25), Vector2(fx + r.size.x * 0.04, g - r.size.y * 0.25),
			Vector2(fx + r.size.x * 0.06, g - r.size.y * 0.1), Vector2(fx - r.size.x * 0.06, g - r.size.y * 0.1)]), col)
		draw_rect(Rect2(fx - r.size.x * 0.06, g - r.size.y * 0.1, r.size.x * 0.12, r.size.y * 0.1), col.darkened(0.25))
		# the medkit's cross by it
		var mk := Vector2(fx - r.size.x * 0.13, g - r.size.y * 0.06)
		draw_rect(Rect2(mk - Vector2(14, 14), Vector2(28, 28)), Color(0.9, 0.2, 0.2))
		draw_rect(Rect2(mk - Vector2(3, 10), Vector2(6, 20)), Color.WHITE)
		draw_rect(Rect2(mk - Vector2(10, 3), Vector2(20, 6)), Color.WHITE)
		# shots from the right stopping on it
		for i in 3:
			var y := wall.position.y + wall.size.y * (0.25 + 0.25 * i)
			draw_dashed_line(Vector2(r.end.x - 20.0, y - 10.0 + i * 6.0), Vector2(wall.end.x + 4.0, y), Color(1, 0.6, 0.2, 0.9), 2.0, 12.0)
			draw_circle(Vector2(wall.end.x + 2.0, y), 4.0, Color(1, 0.85, 0.4))
		_callout(wall.position + Vector2(wall.size.x * 0.5, 4.0), Vector2(r.end.x + 30.0, r.position.y + r.size.y * 0.16), "SHIELD WALL")
		_callout(mk, Vector2(r.position.x - 30.0, r.position.y + r.size.y * 0.5), "HEAL BEHIND IT")
		_callout(Vector2(wall.end.x + 2.0, wall.position.y + wall.size.y * 0.75), Vector2(r.end.x + 30.0, r.position.y + r.size.y * 0.74), "SHOTS STOP HERE")

	func _rounds(r: Rect2) -> void:
		var c := r.get_center()
		var band := Rect2(c.x - r.size.x * 0.4, c.y - 44.0, r.size.x * 0.8, 88.0)
		draw_rect(band, Color(0.08, 0.08, 0.1, 0.95))
		var half := band.size.x * 0.5
		draw_rect(Rect2(band.position, Vector2(half - 30.0, band.size.y)), Color(0.18, 0.4, 0.85, 0.85))
		draw_rect(Rect2(band.position + Vector2(half + 30.0, 0), Vector2(half - 30.0, band.size.y)), Color(0.9, 0.42, 0.14, 0.85))
		HudDraw.text(self, "3", Vector2(band.position.x + half * 0.5, c.y), 56, Color.WHITE, 1, 4, "number")
		HudDraw.text(self, "2", Vector2(band.end.x - half * 0.5, c.y), 56, Color.WHITE, 1, 4, "number")
		HudDraw.text(self, "VS", c, 22, UI.TEXT_DIM, 1, 0, "heavy")
		# the round pips under the band: won ones lit
		var n := clampi(rounds, 1, 9)
		for side in 2:
			for i in n:
				var won := i < (3 if side == 0 else 2)
				var x := band.position.x + 18.0 + i * 22.0 if side == 0 else band.end.x - 18.0 - i * 22.0
				var pc := Vector2(x, band.end.y + 22.0)
				draw_circle(pc, 7.0, (Color(0.4, 0.65, 1.0) if side == 0 else Color(1, 0.6, 0.3)) if won else Color(1, 1, 1, 0.18))
		_callout(Vector2(band.position.x + half * 0.5, band.position.y), Vector2(r.position.x - 30.0, r.position.y + r.size.y * 0.62), "YOUR ROUNDS")
		_callout(Vector2(band.end.x - half * 0.5, band.position.y), Vector2(r.end.x + 30.0, r.position.y + r.size.y * 0.15), "THEIRS")
		_callout(Vector2(band.position.x + 18.0 + (n - 1) * 22.0, band.end.y + 22.0), Vector2(r.end.x + 30.0, r.position.y + r.size.y * 0.86),
			"FIRST TO %d WINS" % n)


## Vertical gradient for big outlined titles: glyph fill fades from `top` to `bottom` over
## `height` px of the label; the (dark) outline keeps its colour.
static func gradient_text_material(top: Color, bottom: Color, height: float) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = "shader_type canvas_item;\nuniform vec4 top_col : source_color;\nuniform vec4 bottom_col : source_color;\nuniform float height = 100.0;\nvarying float vy;\nvoid vertex() { vy = clamp(VERTEX.y / height, 0.0, 1.0); }\nvoid fragment() {\n\tvec4 tex = texture(TEXTURE, UV);\n\tfloat fill = step(0.5, COLOR.r + COLOR.g + COLOR.b - 1.0);\n\tvec3 g = mix(top_col.rgb, bottom_col.rgb, smoothstep(0.25, 0.8, vy));\n\tCOLOR = vec4(mix(COLOR.rgb, g, fill), COLOR.a * tex.a);\n}\n"
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("top_col", top)
	m.set_shader_parameter("bottom_col", bottom)
	m.set_shader_parameter("height", height)
	return m


# ---------------------------------------------------------------- loading

func _start_boot_loads() -> void:
	var paths: Array[String] = []
	var weights: Array[float] = []
	for p in ["res://assets/character/character.glb"] + CharacterModel.EXTRA_GLBS:
		paths.append(p)
		weights.append(8.0 if p.ends_with("character.glb") else 2.0)
	for n in PROPS:
		paths.append("res://assets/props/%s.glb" % n)
		weights.append(1.0)
	for f in _list("res://assets/audio/"):
		if f.ends_with(".wav") or f.ends_with(".ogg"):
			paths.append("res://assets/audio/" + f)
			weights.append(0.25)
	paths.append("res://scenes/lobby.tscn")
	weights.append(0.5)
	# One worker task per file (no sub-threads: with them the engine leaks its load tokens).
	for i in paths.size():
		if ResourceLoader.exists(paths[i]) and ResourceLoader.load_threaded_request(paths[i], "", false) == OK:
			_paths.append(paths[i])
			_weights.append(weights[i])


## File names in a res:// folder (works in exported builds, where the originals are remapped).
func _list(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	for f in ResourceLoader.list_directory(dir):
		if not f.ends_with("/"):
			out.append(f)
	return out


func _poll_boot() -> void:
	var total := 0.0
	var got := 0.0
	var finished := true
	var prog := []
	for i in _paths.size():
		var st := ResourceLoader.load_threaded_get_status(_paths[i], prog)
		total += _weights[i]
		match st:
			ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				finished = false
				got += _weights[i] * (float(prog[0]) if prog.size() > 0 else 0.0)
			_:
				got += _weights[i]
	_target = 1.0 if total <= 0.0 else got / total
	if finished:
		_target = 1.0


## Takes every finished request (load_threaded_get) into the holder; requests still in flight
## (only after a timeout) are left to the holder, which collects them when they finish (a get
## now would block the main thread).
func _finish_boot() -> void:
	var keep: Array[Resource] = []
	var pending: Array[String] = []
	for p in _paths:
		var st := ResourceLoader.load_threaded_get_status(p)
		if st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			pending.append(p)
		elif st == ResourceLoader.THREAD_LOAD_LOADED or st == ResourceLoader.THREAD_LOAD_FAILED:
			var r := ResourceLoader.load_threaded_get(p)
			if r:
				keep.append(r)
				if p.begins_with("res://assets/audio/"):
					Audio.stream(p.get_file().get_basename())
	if not CharacterModel.EXTRA_GLBS.any(func(q: String) -> bool: return pending.has(q)):
		CharacterModel.extra_animations()
	var root := get_tree().root
	var holder := root.get_node_or_null("LoadingCache")
	if holder == null:
		holder = Cache.new()
		holder.name = "LoadingCache"
		root.add_child.call_deferred(holder)
	holder.set_meta("resources", keep)
	if holder is Cache:
		(holder as Cache).collect(pending)
	if pending.is_empty():
		Game.mark("boot loaded %d files in %.1fs" % [keep.size(), _t])
	else:
		Game.mark("boot timeout: %d files still loading" % pending.size())
	# The arena's shaders compile now, under the boot screen, not in a match's first frames (an
	# online match waits for a loading phone only so long). Under the root: it outlives the boot.
	if not hold_for_test and Game.autotest == "" and DisplayServer.get_name() != "headless":
		root.add_child.call_deferred(ShaderWarmup.new())


func _process(delta: float) -> void:
	if _bar == null:
		return
	_t += delta
	_tip_t += delta
	if _tip_t > 3.6:
		_tip_t = 0.0
		_tip_i += 1
		_show_tip()
	if _art:
		# slow push-in on the hero (boot) / drift toward the rival (match)
		var z := (1.0 + 0.035 * clampf(_t / 12.0, 0.0, 1.0)) if mode == "boot" else (1.12 - 0.06 * clampf(_t / 2.0, 0.0, 1.0))
		_art.pivot_offset = _art.size * (Vector2(0.36, 0.42) if mode == "boot" else Vector2(0.72, 0.42))
		_art.scale = Vector2(z, z)
	if mode == "boot":
		_process_boot(delta)
	else:
		_process_match(delta)
	_pct.text = "%d%%" % roundi(progress * 100.0)
	_bar.queue_redraw()


func _process_boot(delta: float) -> void:
	if not done:
		_poll_boot()
		# Time floor so the screen is seen; real progress drives the rest.
		var floor_p := clampf(_t / BOOT_MIN_S, 0.0, 1.0)
		var shown := minf(_target, floor_p)
		progress = maxf(progress, lerpf(progress, shown, minf(1.0, delta * 6.0)))
		if _target >= 1.0 and _t >= BOOT_MIN_S and progress > 0.985:
			progress = 1.0
			done = true
			_status.text = "READY"
			_finish_boot()
		elif (Time.get_ticks_msec() - _start_ms) / 1000.0 > TIMEOUT_S:   # real time: never hangs
			done = true
			Game.mark("boot timeout")
			_finish_boot()
		else:
			_status.text = "LOADING GAME FILES" if progress < 0.6 else "PREPARING THE ARENA"
	elif not _leaving and not hold_for_test and not IntroSting.playing(self):
		_leaving = true
		# Fade to the login screen's own near-black (it fades in from it), not to transparent:
		# a transparent boot screen would show the project's light-blue clear colour for a moment.
		var fade := ColorRect.new()
		fade.name = "FadeOut"
		fade.color = Color(0.02, 0.02, 0.03, 0.0)
		fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
		UI.full_rect(fade)
		add_child(fade)
		var tw := create_tween()
		tw.tween_interval(0.15)
		tw.tween_property(fade, "color:a", 1.0, 0.25)
		tw.tween_callback(Game.goto_login)


func _process_match(delta: float) -> void:
	var path := Game.arena_scene()
	var loaded := true
	if _arena_scene == null and ResourceLoader.exists(path):
		var st := ResourceLoader.load_threaded_get_status(path)
		if st == ResourceLoader.THREAD_LOAD_LOADED:
			_arena_scene = ResourceLoader.load_threaded_get(path)
		elif st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			loaded = false
	var goal := clampf(_t / MATCH_MIN_S, 0.0, 1.0) * (1.0 if loaded else 0.85)
	progress = maxf(progress, lerpf(progress, goal, minf(1.0, delta * 8.0)))
	_status.text = _match_status
	var real_s := (Time.get_ticks_msec() - _start_ms) / 1000.0
	if not _leaving and real_s >= delay_for_test and ((loaded and _t >= MATCH_MIN_S) or real_s >= MATCH_MAX_S):
		_leaving = true
		progress = 1.0
		_pct.text = "100%"
		_bar.queue_redraw()
		# one more frame so 100% is on screen while the arena builds
		get_tree().create_timer(0.05, true, false, true).timeout.connect(Game.goto_arena)

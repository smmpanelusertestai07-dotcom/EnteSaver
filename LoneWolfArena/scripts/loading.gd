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
## Then Game.goto_lobby(). It never hangs: after TIMEOUT_S it goes to the lobby anyway.
## Automated runs (Game.autotest) skip straight to the lobby (their scripts expect it) unless a
## screenshot tour sets `hold_for_test` to look at this screen.
##
## MATCH: Loading.start_match(host) puts an overlay on top of `host` (mode + map card
## "LONE WOLF / CARGO CAGE", the map name, the bar), loads the arena scene on a thread for at
## least MATCH_MIN_S, then Game.goto_arena().

const TIMEOUT_S := 12.0
const BOOT_MIN_S := 2.4
const MATCH_MIN_S := 1.2
const MATCH_MAX_S := 6.0
const PROPS := ["container", "container_40", "container_open", "crate", "wall_bay", "wall_column", "rollup_door",
	"roof_truss", "lamp_tube", "barrel", "pallet", "bollard", "fire_cabinet", "forklift", "tank", "barrier",
	"weapon_ar", "weapon_smg", "weapon_sg", "weapon_pistol", "weapon_sniper", "medkit", "grenade", "shield_wall"]
const TIPS := [
	"Hold FIRE and drag to keep aiming while you shoot.",
	"Headshots hit up to 5.5x harder. Aim for the head.",
	"A medkit heals 75 HP over 4 seconds. Firing cancels it.",
	"Throw a shield wall, then heal behind it.",
	"Push the joystick past the ring to sprint.",
	"Pick your gun in the 10-second prep. Both of you use it.",
	"The safe zone starts closing after 25 seconds. Stay inside.",
	"Crouch or go prone to make yourself a smaller target.",
	"A frag grenade does up to 150 damage. Cook it near cover.",
]
const GOLD := Color(0.94, 0.745, 0.24)

## Screenshot tours set this to keep the boot screen up (no automatic lobby).
static var hold_for_test := false

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
var _leaving := false


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
	_tip_i = randi() % TIPS.size()
	if mode == "boot":
		if Game.autotest != "" and not hold_for_test:
			Game.goto_lobby.call_deferred()
			return
		Game.mark("boot screen")
		_build_boot()
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
	var ver := UI.label("v%s  ·  OFFLINE" % ProjectSettings.get_setting("application/config/version", "1.0"), 15, Color(1, 1, 1, 0.55), "semi")
	ver.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	ver.offset_left = -260
	ver.offset_right = -22
	ver.offset_top = -34
	ver.offset_bottom = -10
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(ver)
	var note := UI.label("Made with Godot Engine", 14, Color(1, 1, 1, 0.4), "semi")
	note.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	note.offset_left = 22
	note.offset_right = 300
	note.offset_top = -34
	note.offset_bottom = -10
	add_child(note)


## Bar at y = 0.905 H from x = 0.155 W to 0.84 W, percent at its right, status above its left
## end, the tip line centred below it.
func _build_bar(status: String) -> void:
	_bar = Control.new()
	_bar.anchor_left = 0.155
	_bar.anchor_right = 0.84
	_bar.anchor_top = 0.905
	_bar.anchor_bottom = 0.905
	_bar.offset_top = -3
	_bar.offset_bottom = 3
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.draw.connect(_draw_bar)
	add_child(_bar)
	_pct = UI.label("0%", 22, UI.TEXT, "number")
	_pct.anchor_left = 0.848
	_pct.anchor_right = 0.95
	_pct.anchor_top = 0.905
	_pct.anchor_bottom = 0.905
	_pct.offset_top = -16
	_pct.offset_bottom = 16
	_pct.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(_pct)
	_status = UI.label(status, 15, Color(1, 1, 1, 0.75), "bold")
	_status.anchor_left = 0.155
	_status.anchor_right = 0.6
	_status.anchor_top = 0.905
	_status.anchor_bottom = 0.905
	_status.offset_top = -30
	_status.offset_bottom = -8
	add_child(_status)
	_tip = UI.label("", 18, Color(1, 1, 1, 0.92), "semi")
	_tip.anchor_left = 0.1
	_tip.anchor_right = 0.9
	_tip.anchor_top = 0.955
	_tip.anchor_bottom = 0.955
	_tip.offset_top = -14
	_tip.offset_bottom = 14
	_tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
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
	_tip.text = "TIP:  " + String(TIPS[_tip_i % TIPS.size()])
	_tip.modulate.a = 0.0
	create_tween().tween_property(_tip, "modulate:a", 1.0, 0.35)


func _build_match() -> void:
	_backdrop(1.12)
	var shade := ColorRect.new()
	shade.color = Color(0.02, 0.02, 0.05, 0.35)
	UI.full_rect(shade)
	add_child(shade)
	# Mode + map card, top-left.
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UI.chamfer(Color(0.07, 0.065, 0.06, 0.9), 14, 1, Color(1, 1, 1, 0.12), 0.0, ["br"]))
	card.position = Vector2(40, 34)
	card.custom_minimum_size = Vector2(360, 0)
	add_child(card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	card.add_child(v)
	var thumb_tex := UI.texture("mode_lonewolf.jpg")
	if thumb_tex:
		var thumb := TextureRect.new()
		thumb.texture = thumb_tex
		thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		thumb.custom_minimum_size = Vector2(360, 190)
		thumb.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		thumb.clip_contents = true
		v.add_child(thumb)
		var badge := UI.label(" 1 VS 1 ", 16, UI.INK, "heavy")
		var bp := PanelContainer.new()
		bp.add_theme_stylebox_override("panel", UI.chamfer(UI.ACCENT, 6, 0, Color.TRANSPARENT, 6.0, ["br"]))
		bp.add_child(badge)
		bp.position = Vector2(10, 10)
		thumb.add_child(bp)
	var body := MarginContainer.new()
	for side in ["left", "right"]:
		body.add_theme_constant_override("margin_" + side, 16)
	body.add_theme_constant_override("margin_top", 10)
	body.add_theme_constant_override("margin_bottom", 14)
	v.add_child(body)
	var bv := VBoxContainer.new()
	bv.add_theme_constant_override("separation", 4)
	body.add_child(bv)
	var t_row := HBoxContainer.new()
	t_row.add_theme_constant_override("separation", 12)
	t_row.add_child(UI.label("LONE WOLF", 32, UI.AMBER, "heavy"))
	var map_l := UI.label("CARGO CAGE", 32, UI.TEXT, "heavy")
	t_row.add_child(map_l)
	bv.add_child(t_row)
	var chips := HBoxContainer.new()
	chips.add_theme_constant_override("separation", 4)
	for c in ["ROUNDS 1", "1 VS BOT", "BOT: " + String(Game.DIFFICULTY_NAMES[int(Game.settings.difficulty)])]:
		var cp := PanelContainer.new()
		cp.add_theme_stylebox_override("panel", UI.chamfer(Color(1, 1, 1, 0.1), 4, 0, Color.TRANSPARENT, 10.0, []))
		cp.add_child(UI.label(c, 15, UI.TEXT, "bold"))
		chips.add_child(cp)
	bv.add_child(chips)
	var desc := UI.label("Win the duel before the zone closes in.", 16, UI.TEXT_DIM, "semi")
	bv.add_child(desc)
	# The map name, big, above the bar.
	var big := UI.shadowed(UI.outlined(UI.label("CARGO CAGE", 132, UI.TEXT, "italic"), 10, Color(0.05, 0.04, 0.03, 0.95)), Vector2(0, 8), Color(0, 0, 0, 0.5))
	big.anchor_left = 0.0
	big.anchor_right = 1.0
	big.anchor_top = 0.62
	big.anchor_bottom = 0.62
	big.offset_top = -80
	big.offset_bottom = 90
	big.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	big.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	big.material = gradient_text_material(Color(1, 1, 1), Color(1.0, 0.72, 0.2), 170.0)
	add_child(big)
	_build_bar("ENTERING THE ARENA")


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
	for p in ["res://assets/character/character.glb", "res://assets/character/anims_extra.glb"]:
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
	for i in paths.size():
		if ResourceLoader.exists(paths[i]) and ResourceLoader.load_threaded_request(paths[i], "", true) == OK:
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


func _finish_boot() -> void:
	var keep: Array[Resource] = []
	for p in _paths:
		if ResourceLoader.load_threaded_get_status(p) == ResourceLoader.THREAD_LOAD_LOADED:
			var r := ResourceLoader.load_threaded_get(p)
			if r:
				keep.append(r)
				if p.begins_with("res://assets/audio/"):
					Audio.stream(p.get_file().get_basename())
	CharacterModel.extra_animations()
	var root := get_tree().root
	var holder := root.get_node_or_null("LoadingCache")
	if holder == null:
		holder = Node.new()
		holder.name = "LoadingCache"
		root.add_child.call_deferred(holder)
	holder.set_meta("resources", keep)
	Game.mark("boot loaded %d files in %.1fs" % [keep.size(), _t])


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
		elif _t > TIMEOUT_S:
			done = true
			Game.mark("boot timeout")
		else:
			_status.text = "LOADING GAME FILES" if progress < 0.6 else "PREPARING THE ARENA"
	elif not _leaving and not hold_for_test:
		_leaving = true
		var tw := create_tween()
		tw.tween_interval(0.15)
		tw.tween_property(self, "modulate:a", 0.0, 0.25)
		tw.tween_callback(Game.goto_lobby)


func _process_match(delta: float) -> void:
	var path := "res://scenes/arena.tscn"
	var loaded := true
	if _arena_scene == null and ResourceLoader.exists(path):
		var st := ResourceLoader.load_threaded_get_status(path)
		if st == ResourceLoader.THREAD_LOAD_LOADED:
			_arena_scene = ResourceLoader.load_threaded_get(path)
		elif st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			loaded = false
	var goal := clampf(_t / MATCH_MIN_S, 0.0, 1.0) * (1.0 if loaded else 0.85)
	progress = maxf(progress, lerpf(progress, goal, minf(1.0, delta * 8.0)))
	_status.text = "PREPARING WEAPONS" if progress < 0.5 else "ENTERING THE ARENA"
	if not _leaving and ((loaded and _t >= MATCH_MIN_S) or _t >= MATCH_MAX_S):
		_leaving = true
		progress = 1.0
		_pct.text = "100%"
		_bar.queue_redraw()
		# one more frame so 100% is on screen while the arena builds
		get_tree().create_timer(0.05, true, false, true).timeout.connect(Game.goto_arena)

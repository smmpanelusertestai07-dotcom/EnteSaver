class_name SettingsPanel
extends Control
## Settings: a full-screen modal with a tab column on the left, sectioned rows on dark plates, a
## close X (node "Close") top-right; under the tabs HOW TO PLAY (node "HowToPlay") and a per-tab
## RESET that, once confirmed, puts the tab's settings (TAB_KEYS) back to their defaults. Every
## change applies at once (Game.settings + Game.apply_settings(); graphics and visual effects also
## through Game.settings_changed, which the arena and the lobby follow); closing saves
## (Game.save_settings()) and emits `closed`. Works while the tree is paused. What the reference
## offers, in its groups and order, plus what the owner asked for:
##  - DISPLAY: graphics AUTO / LOW .. EXTREME (AUTO marks the level it picked for this phone and
##    picks again after a frame-rate change; EXTREME asks first, it can heat the phone), frame rate
##    (30 and 60; 90 and 120 where the screen refreshes that fast), visual effects;
##  - CONTROLS: SHOOTING (aim precision, the left fire button OFF / ALWAYS / WHEN AIMING, hold
##    fire to scope), QUICK BUTTONS (weapon switch, reload, the reload ring, free look), MOVEMENT
##    (joystick DYNAMIC / FIXED, run mode), VIBRATION (enemy footsteps, taking damage, shooting:
##    Game.vibrate), custom HUD;
##  - SENSITIVITY: General, Red Dot, 2x Scope, Sniper Scope and Free Look, with the STANDARD /
##    FAST presets;
##  - SOUND: effects, music, voice chat (the other player's voice), all applied at once;
##  - ONLINE: chat, friends chat, SHOW MY CAREER, voice chat, who may challenge you, friend
##    requests, the lobby's vibration, direct connection (scripts/settings_online.gd);
##  - ACCOUNT: the guest profile's player ID, CLEAR CACHE (CacheCleaner: asks first, then says how
##    much it freed) and along the bottom DELETE MY DATA, the Terms of Use and the Privacy Notice
##    (scripts/settings_account.gd).
## Questions (RESET, EXTREME, CLEAR CACHE, DELETE MY DATA) open over the panel as node "Confirm"
## (buttons "ConfirmOk" and "ConfirmCancel"); HOW TO PLAY and the two documents as a page over it
## (open_sheet: node "Sheet", its header X "Close", "SheetOk"); back closes them first.
## _show_tab(i) takes the index in TABS (the screenshot walkthrough opens 2 = CONTROLS).
## In a match (the in-match menu, PauseMenu, sets edit_hud) EDIT CUSTOM HUD opens the editor over
## the match; opened over the arena any other way it is a note: the lobby's editor would end it
## (DELETE MY DATA is a note in a match too).

signal closed

const TABS := ["DISPLAY", "SENSITIVITY", "CONTROLS", "SOUND", "ONLINE", "ACCOUNT"]
## Menu order on screen (indices into TABS).
const ORDER := [0, 2, 1, 3, 4, 5]
## The settings each tab shows, and its RESET puts back (ACCOUNT has none: no RESET there).
const TAB_KEYS := [
	["graphics_auto", "graphics", "fps", "visual_effects"],
	["sens_general", "sens_reddot", "sens_2x", "sens_sniper", "sens_freelook"],
	["aim_precision", "left_fire", "hold_fire_scope", "switch_button", "reload_button", "reload_on_crosshair",
		"freelook_button", "dynamic_joystick", "run_mode", "vibrate_footsteps", "vibrate_damage", "vibrate_shooting"],
	["vol_sfx", "vol_music", "vol_voice"],
	["chat", "friend_chat", "show_career", "voice_chat", "challenges_from", "friend_requests", "vibration", "direct_connect"],
	[],
]
## Settings the scene applies when they change (Game.settings_changed); the rest are read live.
const SCENE_KEYS := ["visual_effects"]
## Settings no tab shows: chosen elsewhere (the mode and the bot level in SELECT MODE, the gun at
## the pick) or the game's own bookkeeping.
const NOT_SHOWN := ["settings_version", "mode", "difficulty", "last_pick", "graphics_auto_done"]
const GRAPHICS_CHOICES := ["AUTO", "LOW", "MEDIUM", "HIGH", "EXTREME"]
## The joystick (setting dynamic_joystick: DYNAMIC true, FIXED false) and what each does.
const JOYSTICK_NAMES := ["DYNAMIC", "FIXED"]
const JOYSTICK_NOTES := [
	"The stick starts where your thumb lands on the left and follows it",
	"The stick stays in its place",
]
## The VIBRATION rows (Game.VIBRATE_KEYS: the reference's): [title, setting, note].
const VIBRATION_ROWS := [
	["Enemy footsteps", "vibrate_footsteps", "A light buzz with each step of an enemy running close by"],
	["Taking damage", "vibrate_damage", "A buzz when you are hit"],
	["Shooting", "vibrate_shooting", "A buzz with each shotgun or sniper shot, and on a kill"],
]
## The choices of the settings aim_precision and left_fire, by value, with aim precision's notes.
const PRECISION_NAMES := ["ASSISTED", "MANUAL IN SCOPE", "FULL MANUAL"]
const PRECISION_NOTES := [
	"The aim sticks to an enemy and holds the head or body you drag to",
	"No aim assist while aiming down a sight; assisted from the hip",
	"No aim assist: shots go exactly where you aim",
]
const LEFT_FIRE_NAMES := ["OFF", "ALWAYS", "WHEN AIMING"]
## Sprint (setting run_mode, by value) and what each does.
const RUN_MODE_NAMES := ["TAP", "DRAG", "MIXED"]
const RUN_MODE_NOTES := [
	"Tap the sprint button to run until you stop",
	"Push the stick past its ring to sprint (no sprint button)",
	"The sprint button, or the stick pushed past its ring",
]
## The left fire choices left to right as values of the setting (0 always, 1 while aiming, 2 off:
## the values of version 5 keep their meaning).
const LEFT_FIRE_VALUES := [2, 0, 1]
## The sensitivity rows top to bottom: [title, setting, note].
const SENS_ROWS := [
	["General", "sens_general", "Camera turn when dragging the right side"],
	["Red Dot", "sens_reddot", "While aiming down the red-dot sight"],
	["2x Scope", "sens_2x", "While aiming through a 2x scope"],
	["Sniper Scope", "sens_sniper", "While looking through the sniper scope"],
	["Free Look", "sens_freelook", "Turning the camera with the eye button"],
]
## STANDARD is the defaults; FAST our quicker set, in the usual order (Red Dot >= General > 2x >
## Sniper).
const PRESET_NAMES := ["STANDARD", "FAST"]
const SENS_PRESETS := {
	"STANDARD": {"sens_general": 100, "sens_reddot": 100, "sens_2x": 100, "sens_sniper": 71, "sens_freelook": 100},
	"FAST": {"sens_general": 165, "sens_reddot": 170, "sens_2x": 150, "sens_sniper": 125, "sens_freelook": 140},
}
const MENU_W := 230.0

var _body: VBoxContainer
var _scroll: ScrollContainer
var _menu: VBoxContainer
var _menu_buttons := {}
var _current := 0
var _sens_rows := {}
var _preset_seg: HBoxContainer
var _graphics_seg: HBoxContainer
var _graphics_note: Label
var _aim_note: Label
var _run_note: Label
var _joy_note: Label
var _cache_note: Label
var _ask_layer: Control
var _sheet: Control
var _hint: Label
var _reset_btn: Button
## The ACCOUNT tab's links along the bottom (in the hint's place), while that tab shows.
var _footer: Control
## A task that must not be left halfway (DELETE MY DATA): back and the X do nothing meanwhile.
var busy := false
## True when opened during a match (set by the pause menu; also detected from the scene).
var in_match := false
## Set by the in-match menu (PauseMenu): EDIT CUSTOM HUD then opens the editor over the match.
var edit_hud := Callable()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var scene := get_tree().current_scene
	if scene and scene.has_method("open_pause"):
		in_match = true
	UI.full_rect(self)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var shade := ColorRect.new()
	shade.color = Color(0.02, 0.02, 0.025, 0.8)
	UI.full_rect(shade)
	add_child(shade)
	var bg := UI.gradient_rect([[0.0, Color(0.11, 0.09, 0.07, 0.96)], [0.55, Color(0.07, 0.065, 0.06, 0.97)], [1.0, Color(0.05, 0.05, 0.055, 0.98)]], true)
	UI.full_rect(bg)
	add_child(bg)
	# Left tab column.
	var col := Panel.new()
	col.add_theme_stylebox_override("panel", UI.box(Color(0, 0, 0, 0.45), 0, 0, Color.TRANSPARENT, 0.0))
	col.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	col.offset_right = MENU_W
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(col)
	_menu = VBoxContainer.new()
	_menu.add_theme_constant_override("separation", 6)
	_menu.position = Vector2(0, 74)
	_menu.custom_minimum_size = Vector2(MENU_W, 0)
	add_child(_menu)
	for i in ORDER:
		var b := _menu_button(TABS[i], i)
		_menu.add_child(b)
		_menu_buttons[i] = b
	# Under the tabs: HOW TO PLAY (the game's help, in the lobby and in a match), then RESET.
	var help := UI.button("HOW TO PLAY", 18, "ghost", Vector2(190, UI.TOUCH_MIN))
	help.name = "HowToPlay"
	help.icon = UI.icon_texture("v_info")
	help.expand_icon = true
	help.add_theme_constant_override("icon_max_width", 22)
	help.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	help.offset_left = 24
	help.offset_right = 24 + 190
	help.offset_top = -136
	help.offset_bottom = -136 + UI.TOUCH_MIN
	help.pressed.connect(open_help)
	add_child(help)
	_reset_btn = UI.button("RESET", 18, "ghost", Vector2(150, UI.TOUCH_MIN))
	_reset_btn.name = "Reset"
	_reset_btn.icon = UI.icon_texture("v_reload")
	_reset_btn.expand_icon = true
	_reset_btn.add_theme_constant_override("icon_max_width", 22)
	_reset_btn.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_reset_btn.position = Vector2(24, -70)
	_reset_btn.pressed.connect(_ask_reset)
	add_child(_reset_btn)
	# Header: title + close.
	var title := UI.label("SETTINGS", 30, UI.TEXT, "heavy")
	title.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	title.offset_left = -360
	title.offset_right = -84
	title.offset_top = 16
	title.offset_bottom = 60
	add_child(title)
	var close := UI.close_button(UI.TOUCH_MIN)
	close.name = "Close"
	close.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	close.offset_left = -66
	close.offset_right = -12
	close.offset_top = 10
	close.offset_bottom = 64
	close.pressed.connect(_close)
	add_child(close)
	var underline := ColorRect.new()
	underline.color = Color(UI.ACCENT, 0.85)
	underline.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	underline.offset_left = -126
	underline.offset_right = -84
	underline.offset_top = 58
	underline.offset_bottom = 61
	underline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(underline)
	# Content.
	_scroll = ScrollContainer.new()
	_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scroll.offset_left = MENU_W + 28
	_scroll.offset_right = -28
	_scroll.offset_top = 74
	_scroll.offset_bottom = -64
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	UI.style_scroll(_scroll)
	add_child(_scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 8)
	_scroll.add_child(_body)
	_hint = UI.label("", 16, UI.TEXT_DIM, "semi")
	_hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_hint.offset_left = MENU_W + 28
	_hint.offset_right = -28
	_hint.offset_top = -52
	_hint.offset_bottom = -16
	_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_hint)
	# AUTO's pick can arrive while the panel is open (the measurement ends): BASIC shows it.
	Game.settings_changed.connect(_refresh_graphics)
	_show_tab(0)
	modulate.a = 0.0
	create_tween().tween_property(self, "modulate:a", 1.0, 0.18)


func _menu_button(text: String, idx: int) -> Button:
	var b := Button.new()
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(MENU_W, 58)
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_font_override("font", UI.font("bold"))
	b.add_theme_font_size_override("font_size", 24)
	var normal := UI.box(Color(0, 0, 0, 0), 0, 0, Color.TRANSPARENT, 24.0)
	var hover := UI.box(Color(1, 1, 1, 0.06), 0, 0, Color.TRANSPARENT, 24.0)
	var on := UI.chamfer(UI.ACCENT, 12, 0, Color.TRANSPARENT, 24.0, ["br"])
	for st in [normal, hover, on]:
		st.content_margin_left = 26
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", on)
	b.add_theme_stylebox_override("hover_pressed", on)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("font_color", UI.TEXT)
	b.add_theme_color_override("font_hover_color", UI.TEXT)
	b.add_theme_color_override("font_pressed_color", UI.INK)
	b.add_theme_color_override("font_hover_pressed_color", UI.INK)
	# hazard stripes, corner cut and notch on the selected (yellow) tab
	b.draw.connect(func() -> void:
		if b.button_pressed:
			UI.draw_tab_selected(b, b.size))
	b.pressed.connect(func() -> void:
		Audio.play("ui_select", -6.0)
		_show_tab(idx))
	return b


## A setting changed on the panel: it applies at once (the scene reads most of them live; it
## re-applies SCENE_KEYS on settings_changed).
func _apply(key: String, value: Variant) -> void:
	Game.settings[key] = value
	Game.apply_settings()
	if key in SCENE_KEYS:
		Game.settings_changed.emit()
	var kind: Variant = Game.VIBRATE_KEYS.find_key(key)
	if kind != null and bool(value):
		Game.vibrate(40, String(kind))  # a short buzz: this is what it does


func _show_tab(i: int) -> void:
	_current = clampi(i, 0, TABS.size() - 1)
	for k in _menu_buttons:
		var b: Button = _menu_buttons[k]
		b.set_pressed_no_signal(k == _current)
		b.queue_redraw()
	for c in _body.get_children():
		_body.remove_child(c)
		c.queue_free()
	_sens_rows.clear()
	_preset_seg = null
	_graphics_seg = null
	_graphics_note = null
	_aim_note = null
	_run_note = null
	_joy_note = null
	_cache_note = null
	if _footer and is_instance_valid(_footer):
		_footer.queue_free()
	_footer = null
	_hint.visible = true
	_reset_btn.visible = not (TAB_KEYS[_current] as Array).is_empty()
	_scroll.scroll_vertical = 0
	match _current:
		0:
			_build_display()
		1:
			_build_sensitivity()
		2:
			_build_controls()
		3:
			_build_sound()
		4:
			SettingsOnline.build(self)
		5:
			SettingsAccount.build(self)
	# A finger drag that starts on a row scrolls the tab (a tap still presses); a slider keeps its
	# own drag, so moving one never scrolls the list.
	UI.drag_scroll(_scroll, _body)
	for s in _body.find_children("*", "Slider", true, false):
		(s as Control).mouse_filter = Control.MOUSE_FILTER_STOP


# ---------------------------------------------------------------- DISPLAY

func _build_display() -> void:
	_body.add_child(UI.section("GRAPHICS"))
	var sel := 0 if bool(Game.settings.graphics_auto) else int(Game.settings.graphics) + 1
	_graphics_seg = UI.segmented(GRAPHICS_CHOICES, sel, _on_graphics, 17, 104.0)
	_graphics_seg.name = "GraphicsChoice"
	for i in range(1, _graphics_seg.get_child_count()):
		var b := _graphics_seg.get_child(i) as Button
		var level := i - 1
		b.draw.connect(func() -> void:
			# AUTO's pick: a short accent bar under its caption
			if bool(Game.settings.graphics_auto) and int(Game.settings.graphics) == level:
				b.draw_rect(Rect2(b.size.x * 0.3, b.size.y - 8.0, b.size.x * 0.4, 3.0), UI.ACCENT))
	var row := UI.plate_row("Graphics", _graphics_seg, "-")
	_graphics_note = _note_of(row)
	_body.add_child(row)
	_refresh_graphics()
	var fps_opts := Game.fps_choices()
	var labels := []
	var fps_sel := 0
	for k in fps_opts.size():
		labels.append("%d FPS" % int(fps_opts[k]))
		if int(fps_opts[k]) <= int(Game.settings.fps):
			fps_sel = k        # a saved rate this screen can't show: the fastest it can
	var fps_seg := UI.segmented(labels, fps_sel, func(v: int) -> void: _set_fps(int(fps_opts[v])), 17, 104.0)
	fps_seg.name = "FpsChoice"
	_body.add_child(UI.plate_row("Frame rate", fps_seg, _fps_note(fps_opts)))
	_body.add_child(UI.plate_row("Visual effects", _toggle("visual_effects"), "Lights on shots and blasts, full sparks; off helps weak phones"))
	_hint.text = "Changes apply at once. In a match the 3D view draws a little smaller while frames run slow; the HUD stays sharp."


## The cache row (ACCOUNT, TOOLS): what CLEAR CACHE would free now, the button (node ClearCache).
func cache_row() -> Control:
	var clear_btn := UI.button("CLEAR", 18, "light", Vector2(170, 52))
	clear_btn.name = "ClearCache"
	clear_btn.pressed.connect(_ask_clear_cache)
	var row := UI.plate_row("Cache", clear_btn, "Shader cache, old logs, leftover temporary files: %s" % CacheCleaner.size_text(int(CacheCleaner.scan().bytes)))
	clear_btn.size_flags_horizontal = Control.SIZE_EXPAND | Control.SIZE_SHRINK_END      # at the row's end
	_cache_note = _note_of(row)
	return row


## CLEAR CACHE asks first (what goes, what stays), then says how much it freed.
func _ask_clear_cache() -> void:
	var bytes := int(CacheCleaner.scan().bytes)
	if bytes == 0:
		_cache_note.text = "Nothing to clear"
		return
	_ask("CLEAR CACHE", ("Delete %s: the shader cache (rebuilt as you play, the next match may stutter for a moment), "
		+ "old logs and leftover temporary files? Your profile, settings, player ID and HUD layout stay.") % CacheCleaner.size_text(bytes),
		"CLEAR", func() -> void:
			var freed := CacheCleaner.size_text(CacheCleaner.clear())
			if _cache_note and is_instance_valid(_cache_note):
				_cache_note.text = "Freed %s" % freed)


## The frame-rate row's note: which rates this screen can't show, if any.
func _fps_note(shown: Array) -> String:
	var missing := PackedStringArray()
	for f: int in Game.FPS_OPTIONS:
		if not (f in shown):
			missing.append(str(f))
	if missing.is_empty():
		return "Higher is smoother, lower saves battery"
	return "%s FPS %s a faster screen" % [" and ".join(missing), "needs" if missing.size() == 1 else "need"]


## A graphics choice: 0 AUTO, then LOW .. EXTREME. EXTREME asks first (it can heat the phone); until
## the answer the row keeps showing the current choice.
func _on_graphics(i: int) -> void:
	if i == GRAPHICS_CHOICES.size() - 1 and not (int(Game.settings.graphics) == i - 1 and not bool(Game.settings.graphics_auto)):
		_refresh_graphics()
		_ask("EXTREME GRAPHICS", "Extreme can make the phone hot and empty the battery faster, and frames may drop. Use it anyway?",
			"USE EXTREME", func() -> void: _set_graphics(i))
		return
	_set_graphics(i)


func _set_graphics(i: int) -> void:
	if i == 0:
		Game.start_auto_graphics()
	else:
		Game.stop_auto_graphics()
		Game.settings.graphics = i - 1
	Game.apply_settings()
	Game.settings_changed.emit()          # the arena / lobby re-apply graphics at once
	_refresh_graphics()


func _set_fps(f: int) -> void:
	if f == int(Game.settings.fps):
		return
	Game.settings.fps = f
	Game.apply_settings()
	if bool(Game.settings.graphics_auto):
		Game.start_auto_graphics()        # AUTO picks again for the new frame rate
		Game.settings_changed.emit()


## The graphics row as the settings are now: AUTO or the level selected, AUTO's pick marked
## (accent caption and bar) and named in the note.
func _refresh_graphics() -> void:
	if _graphics_seg == null or not is_instance_valid(_graphics_seg):
		return
	var auto := bool(Game.settings.graphics_auto)
	var level := clampi(int(Game.settings.graphics), 0, Game.GRAPHICS_NAMES.size() - 1)
	for i in _graphics_seg.get_child_count():
		var b := _graphics_seg.get_child(i) as Button
		b.set_pressed_no_signal(i == (0 if auto else level + 1))
		var col := UI.ACCENT if auto and i == level + 1 else UI.TEXT
		b.add_theme_color_override("font_color", col)
		b.add_theme_color_override("font_hover_color", col)
		b.queue_redraw()
	if _graphics_note and is_instance_valid(_graphics_note):
		var picked := String(Game.GRAPHICS_NAMES[level])
		if auto and Game.auto_graphics_pending:
			_graphics_note.text = "AUTO: %s for now, checking this phone" % picked
		elif auto:
			_graphics_note.text = "AUTO picked %s for this phone" % picked
		else:
			_graphics_note.text = "Low runs best on older phones; Extreme adds shadows, MSAA and glow"


## The dim note under a UI.plate_row's title.
static func _note_of(row: Control) -> Label:
	var v := row.get_child(0).get_child(0)
	return v.get_child(v.get_child_count() - 1) as Label


# ---------------------------------------------------------------- SENSITIVITY

func _build_sensitivity() -> void:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	var sec := UI.section("SENSITIVITY")
	sec.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sec)
	head.add_child(UI.label("PRESET", 16, UI.TEXT_DIM, "bold"))
	_preset_seg = UI.segmented(PRESET_NAMES, _preset_index(), _apply_preset, 16, 110.0)
	head.add_child(_preset_seg)
	_body.add_child(head)
	var defaults := PackedStringArray()
	for r: Array in SENS_ROWS:
		var note := String(r[2])
		if r[1] == "sens_2x":
			note += " (%s)" % ", ".join(guns_with_sight("2x"))
		_sens_row(String(r[0]), String(r[1]), note)
		defaults.append(str(SENS_PRESETS.STANDARD[r[1]]))
	_hint.text = "1-200. Higher turns faster for the same swipe. STANDARD = %s." % " / ".join(defaults)


## The pickable guns' names that aim through `sight` (Player.sight_of).
static func guns_with_sight(sight: String) -> PackedStringArray:
	var out := PackedStringArray()
	for id: String in Weapons.PICKABLE:
		if Player.sight_of(Weapons.DEFS[id]) == sight:
			out.append(String(Weapons.DEFS[id].name))
	return out


func _sens_row(title: String, key: String, note: String) -> void:
	var st := UI.stepper(Game.settings[key], 1, 200, func(v: float) -> void:
		_apply(key, int(v))
		_refresh_preset())
	st.name = "Sens_" + key
	_sens_rows[key] = st
	_body.add_child(UI.plate_row(title, st, note))


func _preset_index() -> int:
	for i in PRESET_NAMES.size():
		var p: Dictionary = SENS_PRESETS[PRESET_NAMES[i]]
		var same := true
		for k: String in p:
			if int(Game.settings[k]) != int(p[k]):
				same = false
		if same:
			return i
	return -1


func _apply_preset(i: int) -> void:
	var p: Dictionary = SENS_PRESETS[PRESET_NAMES[i]]
	for k: String in p:
		_apply(k, int(p[k]))
		if _sens_rows.has(k):
			var s: HSlider = (_sens_rows[k] as Control).get_meta("slider")
			s.set_value_no_signal(float(p[k]))
			var v := (_sens_rows[k] as HBoxContainer).get_child(0) as Label
			v.text = str(int(p[k]))
	_refresh_preset()


## The preset buttons show which preset the sliders match (none after a slider moved off it).
func _refresh_preset() -> void:
	if _preset_seg == null or not is_instance_valid(_preset_seg):
		return
	var at := _preset_index()
	for i in _preset_seg.get_child_count():
		(_preset_seg.get_child(i) as Button).set_pressed_no_signal(i == at)


# ---------------------------------------------------------------- CONTROLS

func _build_controls() -> void:
	_body.add_child(UI.section("SHOOTING"))
	var precision := clampi(int(Game.settings.aim_precision), 0, PRECISION_NAMES.size() - 1)
	var aim_seg := UI.segmented(PRECISION_NAMES, precision, _set_precision, 16, 172.0)
	aim_seg.name = "AimPrecision"
	var aim_row := UI.plate_row("Aim precision", aim_seg, String(PRECISION_NOTES[precision]))
	_aim_note = _note_of(aim_row)
	_body.add_child(aim_row)
	var lf_at := maxi(LEFT_FIRE_VALUES.find(int(Game.settings.left_fire)), 0)
	var left_fire := UI.segmented(LEFT_FIRE_NAMES, lf_at, func(v: int) -> void: _apply("left_fire", int(LEFT_FIRE_VALUES[v])), 16, 150.0)
	left_fire.name = "LeftFire"
	_body.add_child(UI.plate_row("Left fire button", left_fire, "Off, always shown, or only while aiming down a sight"))
	_body.add_child(UI.plate_row("Hold fire to scope", _toggle("hold_fire_scope"), "Sniper rifles: hold FIRE to look through the scope, let go to shoot"))
	_body.add_child(UI.spacer(4))
	_body.add_child(UI.section("QUICK BUTTONS"))
	_body.add_child(UI.plate_row("Weapon switch button", _toggle("switch_button"), "Swaps the gun and the fists; it shows the one it swaps to"))
	_body.add_child(UI.plate_row("Reload button", _toggle("reload_button"), "RELOAD beside FIRE (tapping the weapon panel reloads too)"))
	_body.add_child(UI.plate_row("Reload ring", _toggle("reload_on_crosshair"), "The reload's progress around the crosshair"))
	_body.add_child(UI.plate_row("Free look button", _toggle("freelook_button"), "Hold the eye button and drag to look around while you run on"))
	_body.add_child(UI.spacer(4))
	_body.add_child(UI.section("MOVEMENT"))
	var dynamic := bool(Game.settings.dynamic_joystick)
	var joy_seg := UI.segmented(JOYSTICK_NAMES, 0 if dynamic else 1, _set_joystick, 16, 150.0)
	joy_seg.name = "Toggle_dynamic_joystick"
	var joy_row := UI.plate_row("Joystick", joy_seg, String(JOYSTICK_NOTES[0 if dynamic else 1]))
	_joy_note = _note_of(joy_row)
	_body.add_child(joy_row)
	var run := clampi(int(Game.settings.run_mode), 0, RUN_MODE_NAMES.size() - 1)
	var run_seg := UI.segmented(RUN_MODE_NAMES, run, _set_run_mode, 16, 130.0)
	run_seg.name = "RunMode"
	var run_row := UI.plate_row("Run mode", run_seg, String(RUN_MODE_NOTES[run]))
	_run_note = _note_of(run_row)
	_body.add_child(run_row)
	_body.add_child(UI.spacer(4))
	_body.add_child(UI.section("VIBRATION"))
	for r: Array in VIBRATION_ROWS:
		_body.add_child(UI.plate_row(String(r[0]), _toggle(String(r[1])), String(r[2])))
	_body.add_child(UI.spacer(6))
	if in_match:
		if edit_hud.is_valid():
			_body.add_child(_edit_hud_row(edit_hud))
			_hint.text = "Custom HUD: move, resize and fade every in-match button; SAVE uses it in this match at once."
		else:
			var note := UI.label("IN THE LOBBY", 17, UI.TEXT_DIM, "bold")
			note.name = "EditHudNote"
			_body.add_child(UI.plate_row("Custom HUD", note, "Leaving for the editor now would end this match"))
			_hint.text = "Custom HUD: open it from the lobby to move, resize and fade every in-match button."
	else:
		_body.add_child(_edit_hud_row(Game.goto_hud_editor))
		_hint.text = "Custom HUD: move, resize and fade every in-match button."


## EDIT CUSTOM HUD: saves the settings, then `open` opens the editor (the lobby's scene, or in a
## match the in-match menu's editor over it).
func _edit_hud_row(open: Callable) -> HBoxContainer:
	var hud_btn := UI.button("EDIT CUSTOM HUD", 20, "light", Vector2(300, 52))
	hud_btn.name = "EditHud"
	hud_btn.pressed.connect(func() -> void:
		Game.save_settings()
		open.call())
	var r := HBoxContainer.new()
	r.add_child(hud_btn)
	return r


func _set_run_mode(v: int) -> void:
	_apply("run_mode", v)
	if _run_note and is_instance_valid(_run_note):
		_run_note.text = String(RUN_MODE_NOTES[v])


## The joystick choice: 0 DYNAMIC, 1 FIXED.
func _set_joystick(v: int) -> void:
	_apply("dynamic_joystick", v == 0)
	if _joy_note and is_instance_valid(_joy_note):
		_joy_note.text = String(JOYSTICK_NOTES[v])


func _set_precision(v: int) -> void:
	_apply("aim_precision", v)
	if _aim_note and is_instance_valid(_aim_note):
		_aim_note.text = String(PRECISION_NOTES[v])


# ---------------------------------------------------------------- SOUND

func _build_sound() -> void:
	_body.add_child(UI.section("VOLUME"))
	_body.add_child(UI.plate_row("Effects", UI.stepper(Game.settings.vol_sfx, 0, 100, func(v: float) -> void: _apply("vol_sfx", int(v)), 5.0)))
	_body.add_child(UI.plate_row("Music", UI.stepper(Game.settings.vol_music, 0, 100, func(v: float) -> void: _apply("vol_music", int(v)), 5.0)))
	var voice := UI.stepper(Game.settings.vol_voice, 0, 100, func(v: float) -> void: _apply("vol_voice", int(v)), 5.0)
	voice.name = "Stepper_vol_voice"
	_body.add_child(UI.plate_row("Voice chat", voice, "Your opponent's voice in an online match (push to talk)"))
	_hint.text = "0 mutes a channel. Changes are heard at once."


func _toggle(key: String) -> Control:
	var t := UI.segmented(["OFF", "ON"], 1 if Game.settings[key] else 0, func(v: int) -> void: _apply(key, v == 1), 17, 104.0)
	t.name = "Toggle_" + key
	return t


## RESET asks before it puts the current tab back.
func _ask_reset() -> void:
	var tab := String(TABS[_current])
	_ask("RESET " + tab, "Put every %s setting back to its default?" % tab, "RESET", _reset_tab)


## A question over the panel: ok_text runs on_ok, CANCEL (or back) only closes it; `danger` makes
## the OK button red (a step that cannot be undone).
func _ask(title: String, text: String, ok_text: String, on_ok: Callable, danger := false) -> void:
	_close_ask()
	var layer := Control.new()
	layer.name = "Confirm"
	UI.full_rect(layer)
	layer.mouse_filter = Control.MOUSE_FILTER_STOP
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.62)
	UI.full_rect(shade)
	layer.add_child(shade)
	var center := CenterContainer.new()
	UI.full_rect(center)
	layer.add_child(center)
	var box := UI.panel(Color(0.085, 0.08, 0.075, 0.98), 12, 1)
	center.add_child(box)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 16)
	box.add_child(v)
	v.add_child(UI.section(title, 24))
	var l := UI.label(text, 19, UI.TEXT, "semi")
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(540, 0)
	v.add_child(l)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 12)
	var no := UI.button("CANCEL", 18, "light", Vector2(170, 50))
	no.name = "ConfirmCancel"
	no.pressed.connect(_close_ask)
	var yes := UI.button(ok_text, 18, "danger" if danger else "primary", Vector2(200, 50))
	yes.name = "ConfirmOk"
	yes.pressed.connect(func() -> void:
		_close_ask()
		on_ok.call())
	row.add_child(no)
	row.add_child(yes)
	v.add_child(row)
	add_child(layer)
	_ask_layer = layer


func _close_ask() -> void:
	if _ask_layer and is_instance_valid(_ask_layer):
		_ask_layer.name = "ConfirmClosed"       # a question asked right after takes the name "Confirm"
		_ask_layer.queue_free()
	_ask_layer = null


## A page over the panel (HOW TO PLAY, the Terms of Use, the Privacy Notice) in the popup look:
## the light header with the title and its X ("Close"), the dark body, at most `width` px wide and
## most of the screen tall. Returns the body's column, whose content should fill it (a scroll box
## that expands); open_doc adds an OK under it. Back and the X close it (close_sheet).
func open_sheet(title: String, width := 1000.0) -> VBoxContainer:
	close_sheet()
	_sheet = Control.new()
	_sheet.name = "Sheet"
	UI.full_rect(_sheet)
	_sheet.mouse_filter = Control.MOUSE_FILTER_STOP
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.74)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UI.full_rect(shade)
	_sheet.add_child(shade)
	var vs := get_viewport_rect().size
	var w := minf(width, vs.x - 64.0)
	var h := minf(660.0, vs.y - 40.0)
	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 0)
	frame.anchor_left = 0.5
	frame.anchor_right = 0.5
	frame.anchor_top = 0.5
	frame.anchor_bottom = 0.5
	frame.offset_left = -w * 0.5
	frame.offset_right = w * 0.5
	frame.offset_top = -h * 0.5
	frame.offset_bottom = h * 0.5
	_sheet.add_child(frame)
	var head := UI.popup_header(title, 26, 54.0)
	(head.get_node("Close") as Button).pressed.connect(close_sheet)
	frame.add_child(head)
	var body := UI.popup_body()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	frame.add_child(body)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	body.add_child(v)
	add_child(_sheet)
	if _ask_layer and is_instance_valid(_ask_layer):
		move_child(_ask_layer, -1)          # a question stays on top
	_sheet.modulate.a = 0.0
	_sheet.create_tween().tween_property(_sheet, "modulate:a", 1.0, 0.15)
	return v


func close_sheet() -> void:
	if _sheet and is_instance_valid(_sheet):
		_sheet.name = "SheetClosed"             # a page opened right after takes the name "Sheet"
		_sheet.queue_free()
	_sheet = null


## HOW TO PLAY (the button under the tabs): the game's help as a page over the panel.
func open_help() -> void:
	var v := open_sheet("HOW TO PLAY", 1060.0)
	v.add_child(HowToPlay.page())


## A document (Login.terms_sections / privacy_sections: [title, text] sections) as a page over the
## panel, the text scrolling (node "DocScroll"), OK ("SheetOk") under it.
func open_doc(title: String, sections: Array) -> void:
	var v := open_sheet(title)
	var scroll := ScrollContainer.new()
	scroll.name = "DocScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	UI.style_scroll(scroll)
	v.add_child(scroll)
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_constant_override("separation", 6)
	scroll.add_child(text)
	for s: Array in sections:
		if String(s[0]) != "":
			text.add_child(UI.spacer(4))
			text.add_child(UI.section(String(s[0]), 19))
		var l := UI.label(String(s[1]), 18, Color(1, 1, 1, 0.9) if String(s[0]) != "" else UI.TEXT_DIM, "semi")
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text.add_child(l)
	UI.drag_scroll(scroll, text)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	var ok := UI.button("OK", 22, "primary", Vector2(200, 56))
	ok.name = "SheetOk"
	ok.pressed.connect(close_sheet)
	row.add_child(ok)
	v.add_child(row)


## What a tab shows along the bottom instead of its hint (the ACCOUNT tab's links); the next tab
## takes it away.
func set_footer(c: Control) -> void:
	_hint.visible = false
	_footer = c
	c.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	c.offset_left = MENU_W + 28
	c.offset_right = -28
	c.offset_top = -4 - UI.TOUCH_MIN
	c.offset_bottom = -4
	add_child(c)
	if _sheet and is_instance_valid(_sheet):
		move_child(_sheet, -1)
	if _ask_layer and is_instance_valid(_ask_layer):
		move_child(_ask_layer, -1)


## RESET (once confirmed) puts the current tab's settings back to their defaults (DISPLAY: AUTO
## graphics picks afresh for this phone).
func _reset_tab() -> void:
	var keys: Array = TAB_KEYS[_current]
	for k: String in keys:
		Game.settings[k] = Game.DEFAULT_SETTINGS[k]
	if "graphics_auto" in keys:
		if bool(Game.settings.graphics_auto):
			Game.start_auto_graphics()
		else:
			Game.stop_auto_graphics()
	Game.apply_settings()
	if "graphics" in keys or keys.any(func(k: String) -> bool: return k in SCENE_KEYS):
		Game.settings_changed.emit()
	_show_tab(_current)


func _close() -> void:
	if busy:
		return
	Game.save_settings()
	closed.emit()
	queue_free()


## Android back: answers an open question first, then closes an open page, else closes the panel;
## never while something was opened on top of it (a challenge popup in the lobby: that one takes
## the back) or a task runs (busy).
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST and is_inside_tree():
		if covered() or busy:
			return
		if _ask_layer and is_instance_valid(_ask_layer):
			_close_ask()            # back answers an open question first
		elif _sheet and is_instance_valid(_sheet):
			close_sheet()
		else:
			_close()


## True while a visible Control was put on top of this panel (a later sibling: the lobby's popup
## for a challenge or a friend request that came in meanwhile).
func covered() -> bool:
	var p := get_parent()
	if p == null:
		return false
	for i in range(get_index() + 1, p.get_child_count()):
		var c := p.get_child(i) as Control
		if c != null and c.visible and not c.is_queued_for_deletion():
			return true
	return false

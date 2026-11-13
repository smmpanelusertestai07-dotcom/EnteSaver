class_name SettingsPanel
extends Control
## Settings: a full-screen modal in the reference's settings layout (our own words and pictures):
## a tab column on the left (IN-MATCH, DISPLAY, SOUND, then our ONLINE and ACCOUNT), the title
## SETTINGS and a close X (node "Close") top-right, and IN-MATCH's second row of sub-tabs (HUD,
## CONTROLS, SENSITIVITY, VIBRATION: node "SubTabs"). Pages are indices into TABS; MENU groups
## them into the column. Every change applies at once (Game.settings + Game.apply_settings();
## graphics and visual effects also through Game.settings_changed, which the arena and the lobby
## follow); there is no save button: closing saves (Game.save_settings()) and emits `closed`.
## Works while the tree is paused.
##  - HUD: a picture of our HUD (assets/ui/settings/hud.png) with CUSTOM (node "EditHud") on it.
##  - CONTROLS and SENSITIVITY: the reference's preview pages. A picture on the left (node
##    "Preview": a screenshot of our own HUD with the button the row is about ringed in dashed
##    yellow and a yellow callout; "PreviewText" under it says what the row's current value does);
##    the rows on the right, the selected one outlined in yellow (tapping a row or its control
##    selects it). CONTROLS: SHOOTING (aim precision, left fire button OFF / ALWAYS / WHEN AIMING,
##    hold fire to scope), QUICK BUTTONS (weapon switch, reload, the reload ring, free look button),
##    MOVEMENT (joystick DYNAMIC / FIXED, run mode). SENSITIVITY: General, Red Dot, 2x Scope,
##    Sniper Scope and Free Look on the reference's 0-100 scale (sens_shown / sens_value map it to
##    our stored 1-200 values; the reference's defaults show for ours) with the DEFAULT / HIGH
##    presets.
##  - VIBRATION: enemy footsteps, taking damage, shooting (Game.vibrate).
##  - DISPLAY: graphics AUTO / LOW .. EXTREME (AUTO marks the level it picked for this phone and
##    picks again after a frame-rate change; EXTREME asks first, it can heat the phone) with picture
##    tiles of our arena at each level under it (node "GraphicsTiles"), frame rate (30 and 60; 90
##    and 120 where the screen refreshes that fast), visual effects; MINIMAP as two picture tiles
##    (TURNS WITH VIEW, the default, or NORTH UP: setting minimap_turns, HudMinimap).
##  - SOUND: music, effects, then the other player's voice, all heard at once.
##  - ONLINE: chat, friends chat, SHOW MY CAREER, voice chat, who may challenge you, friend
##    requests, the lobby's vibration, direct connection (scripts/settings_online.gd);
##  - ACCOUNT: the guest profile's player ID, CLEAR CACHE (CacheCleaner: asks first, then says how
##    much it freed) and along the bottom DELETE MY DATA, the Terms of Use and the Privacy Notice
##    (scripts/settings_account.gd).
## The pictures are made by tests/shots_settings_pics.gd (our arena and HUD); a missing picture
## draws as a dark plate. Under the tab column: HOW TO PLAY and the player's name; bottom-left of
## the content a square RESET (node "Reset") that, once confirmed, puts the page's settings
## (TAB_KEYS) back to their defaults (pages without settings have none).
## Questions (RESET, EXTREME, CLEAR CACHE, DELETE MY DATA) open over the panel as node "Confirm"
## (buttons "ConfirmOk" and "ConfirmCancel"); HOW TO PLAY and the two documents as a page over it
## (open_sheet: node "Sheet", its header X "Close", "SheetOk"); back closes them first.
## _show_tab(i) takes the index in TABS (the screenshot walkthrough opens 2 = CONTROLS).
## In a match (the in-match menu, PauseMenu, sets edit_hud) CUSTOM opens the HUD editor over
## the match; opened over the arena any other way it is a note: the lobby's editor would end it
## (DELETE MY DATA is a note in a match too).

signal closed

const TABS := ["DISPLAY", "SENSITIVITY", "CONTROLS", "SOUND", "ONLINE", "ACCOUNT", "HUD", "VIBRATION"]
## The tab column top to bottom: [caption, its pages (indices into TABS; more than one: sub-tabs)].
const MENU := [["IN-MATCH", [6, 2, 1, 7]], ["DISPLAY", [0]], ["SOUND", [3]], ["ONLINE", [4]], ["ACCOUNT", [5]]]
## The settings each page shows, and its RESET puts back (HUD and ACCOUNT have none: no RESET).
const TAB_KEYS := [
	["graphics_auto", "graphics", "fps", "visual_effects", "minimap_turns"],
	["sens_general", "sens_reddot", "sens_2x", "sens_sniper", "sens_freelook"],
	["aim_precision", "left_fire", "hold_fire_scope", "switch_button", "reload_button", "reload_on_crosshair",
		"freelook_button", "dynamic_joystick", "run_mode"],
	["vol_sfx", "vol_music", "vol_voice"],
	["chat", "friend_chat", "show_career", "voice_chat", "challenges_from", "friend_requests", "vibration", "direct_connect"],
	[],
	[],
	["vibrate_footsteps", "vibrate_damage", "vibrate_shooting"],
]
## The pages with the preview picture on the left (CONTROLS, SENSITIVITY).
const PREVIEW_TABS := [1, 2]
## Settings the scene applies when they change (Game.settings_changed); the rest are read live.
const SCENE_KEYS := ["visual_effects"]
## Settings no tab shows: chosen elsewhere (the mode and the bot level in SELECT MODE, the gun at
## the pick) or the game's own bookkeeping.
const NOT_SHOWN := ["settings_version", "mode", "difficulty", "last_pick", "graphics_auto_done", "team_size"]
const GRAPHICS_CHOICES := ["AUTO", "LOW", "MEDIUM", "HIGH", "EXTREME"]
## The minimap (setting minimap_turns: TURNS WITH VIEW true, NORTH UP false) and what each does.
const MINIMAP_NAMES := ["TURNS WITH VIEW", "NORTH UP"]
const MINIMAP_NOTES := [
	"The map turns as you look around: what is ahead of you is always up",
	"North stays up and your arrow turns on the map",
]
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
## What each left fire choice does (left to right as LEFT_FIRE_NAMES).
const LEFT_FIRE_NOTES := [
	"No fire button on the left: fire with the right thumb",
	"A second fire button on the left, always on screen (it fires, it does not aim)",
	"The left fire button shows only while you aim down a sight",
]
## Sprint (setting run_mode, by value) and what each does.
const RUN_MODE_NAMES := ["TAP", "DRAG", "MIXED"]
const RUN_MODE_NOTES := [
	"Tap the sprint button to run until you stop",
	"Push the stick past its ring to sprint (no sprint button)",
	"The sprint button, or the stick pushed past its ring",
]
## The free look button (setting freelook_button: OFF, ON) and what each does. Free look itself
## needs no button: a drag while standing already turns the camera round the fighter; the eye
## button only matters while running (the run keeps its direction while the view turns).
const FREELOOK_NOTES := [
	"No eye button. Standing still, a drag on the right side already turns the camera round you; while you run, a drag turns the run with it",
	"Hold the eye button and drag to look around while you run: the run keeps its direction. Standing still, a drag already turns the camera round",
]
## The left fire choices left to right as values of the setting (0 always, 1 while aiming, 2 off:
## the values of version 5 keep their meaning).
const LEFT_FIRE_VALUES := [2, 0, 1]
## The sensitivity rows top to bottom: [title, setting, note].
const SENS_ROWS := [
	["General", "sens_general", "How fast the camera turns when you drag the right side"],
	["Red Dot", "sens_reddot", "Turning while aiming down the red-dot sight"],
	["2x Scope", "sens_2x", "Turning while aiming through a 2x scope"],
	["Sniper Scope", "sens_sniper", "Turning while looking through the sniper scope"],
	["Free Look", "sens_freelook", "Turning the camera with the eye button"],
]
## The sensitivity scale the rows show (0-100, the reference's) and where our default sits on it:
## sens_shown / sens_value map it to the stored 1-200 (our default shows as this number).
const SENS_SHOWN := {"sens_general": 65, "sens_reddot": 85, "sens_2x": 65, "sens_sniper": 75, "sens_freelook": 65}
## DEFAULT is the defaults; HIGH our quicker set, in the usual order (Red Dot >= General > 2x >
## Sniper).
const PRESET_NAMES := ["DEFAULT", "HIGH"]
const SENS_PRESETS := {
	"DEFAULT": {"sens_general": 100, "sens_reddot": 100, "sens_2x": 100, "sens_sniper": 71, "sens_freelook": 100},
	"HIGH": {"sens_general": 165, "sens_reddot": 170, "sens_2x": 150, "sens_sniper": 125, "sens_freelook": 140},
}
const MENU_W := 210.0
const PIC_DIR := "res://assets/ui/settings/"
## Where the HUD's widgets are in hud.png / hud_eye.png (fractions of the picture; r: radius in
## picture heights), as tests/shots_settings_pics.gd measured them. "center" is the crosshair.
const SPOTS := {
	"fire_r": {"x": 0.748, "y": 0.68, "r": 0.13}, "fire_l": {"x": 0.112, "y": 0.39, "r": 0.075},
	"scope": {"x": 0.794, "y": 0.4, "r": 0.052}, "freelook": {"x": 0.931, "y": 0.375, "r": 0.045},
	"reload": {"x": 0.663, "y": 0.52, "r": 0.05}, "swap": {"x": 0.59, "y": 0.52, "r": 0.05},
	"sprint": {"x": 0.226, "y": 0.438, "r": 0.066}, "joystick": {"x": 0.225, "y": 0.71, "r": 0.115},
	"center": {"x": 0.5, "y": 0.5, "r": 0.05},
}
## Colours of this page (design/STYLE_SPEC.txt, SETTINGS). The column and the rows are the kit's
## own (ui.gd: TAB_DARK for side columns, ROW for setting rows), so the settings look like the
## other full pages (FRIENDS, PROFILE); the column's tabs are UI.side_tab. Only the settings have
## these: the unselected segment, the sub-tab bar and the open sub-tab's light grey.
const COLUMN_BG := UI.TAB_DARK
const ROW_BG := UI.ROW
const SEG_OFF := Color(0.051, 0.043, 0.055, 0.95)
const SUBBAR_BG := Color(0.192, 0.184, 0.196, 0.9)
const SUBTAB_ON := Color(0.906, 0.906, 0.906)

var _body: VBoxContainer
var _scroll: ScrollContainer
var _menu: VBoxContainer
var _menu_buttons := {}
var _subbar: HBoxContainer
var _current := 6
var _sens_rows := {}
var _preset_seg: HBoxContainer
var _graphics_seg: HBoxContainer
var _graphics_tiles: HBoxContainer
var _graphics_note: Label
var _minimap_note: Label
var _cache_note: Label
var _ask_layer: Control
var _ask_col: VBoxContainer     # the open question's column (ask)
var _sheet: Control
var _hint: Label
var _reset_btn: Button
## The preview pages' picture (node "Preview") and its text (node "PreviewText").
var _pane: Control
var _desc: RichTextLabel
## The preview rows: id -> [row, info Callable] (info() -> {pic, spot, callout, title, value, text}).
var _prows := {}
var _sel := ""
## The ACCOUNT tab's links along the bottom (in the hint's place), while that tab shows.
var _footer: Control
## A task that must not be left halfway (DELETE MY DATA): back and the X do nothing meanwhile.
var busy := false
## True when opened during a match (set by the pause menu; also detected from the scene).
var in_match := false
## Set by the in-match menu (PauseMenu): CUSTOM then opens the editor over the match.
var edit_hud := Callable()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var scene := get_tree().current_scene
	if scene and scene.has_method("open_pause"):
		in_match = true
	UI.full_rect(self)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var shade := ColorRect.new()
	shade.color = Color(0.02, 0.015, 0.025, 0.82)
	UI.full_rect(shade)
	add_child(shade)
	var bg := Control.new()          # the full pages' backdrop (UI.draw_page_bg), as FRIENDS and PROFILE
	bg.name = "PageBg"
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UI.full_rect(bg)
	bg.draw.connect(func() -> void: UI.draw_page_bg(bg, bg.size))
	add_child(bg)
	# Left tab column.
	var col := Panel.new()
	col.add_theme_stylebox_override("panel", UI.box(COLUMN_BG, 0, 0, Color.TRANSPARENT, 0.0))
	col.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	col.offset_right = MENU_W
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(col)
	_menu = VBoxContainer.new()
	_menu.add_theme_constant_override("separation", 6)
	_menu.position = Vector2(8, 68)
	_menu.custom_minimum_size = Vector2(MENU_W - 16.0, 0)
	add_child(_menu)
	for m in MENU.size():
		var b := _menu_button(String(MENU[m][0]), m)
		_menu.add_child(b)
		_menu_buttons[m] = b
	# Under the tabs: HOW TO PLAY (the game's help, in the lobby and in a match), then the player.
	var help := UI.button("HOW TO PLAY", 17, "ghost", Vector2(MENU_W - 36.0, UI.TOUCH_MIN))
	help.name = "HowToPlay"
	help.icon = UI.icon_texture("v_info")
	help.expand_icon = true
	help.add_theme_constant_override("icon_max_width", 22)
	help.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	help.offset_left = 18
	help.offset_right = MENU_W - 18
	help.offset_top = -136
	help.offset_bottom = -136 + UI.TOUCH_MIN
	help.pressed.connect(open_help)
	add_child(help)
	var line := ColorRect.new()
	line.color = Color(1, 1, 1, 0.12)
	line.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	line.offset_left = 10
	line.offset_right = MENU_W - 10
	line.offset_top = -70
	line.offset_bottom = -69
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(line)
	var who := UI.label(String(Game.profile.get("name", "")), 18, UI.TEXT_DIM, "semi")
	who.name = "PlayerLine"
	UI.ellipsis(who)
	who.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	who.offset_left = 18
	who.offset_right = MENU_W - 12
	who.offset_top = -62
	who.offset_bottom = -22
	who.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(who)
	# Header: title + close.
	var title := UI.label("SETTINGS", 26, UI.TEXT, "bold")
	title.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.offset_left = -360
	title.offset_right = -78
	title.offset_top = 8
	title.offset_bottom = 58
	add_child(title)
	var close := UI.close_button(UI.TOUCH_MIN)
	close.name = "Close"
	close.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	close.offset_left = -64
	close.offset_right = -8
	close.offset_top = 4
	close.offset_bottom = 60
	close.pressed.connect(_close)
	add_child(close)
	# IN-MATCH's sub-tabs.
	_subbar = HBoxContainer.new()
	_subbar.name = "SubTabs"
	_subbar.add_theme_constant_override("separation", 0)
	_subbar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_subbar.offset_left = MENU_W + 34
	_subbar.offset_right = -40
	_subbar.offset_top = 66
	_subbar.offset_bottom = 66 + UI.TOUCH_MIN
	_subbar.draw.connect(func() -> void:
		_subbar.draw_rect(Rect2(Vector2.ZERO, _subbar.size), SUBBAR_BG)
		_subbar.draw_rect(Rect2(0, _subbar.size.y - 1.0, _subbar.size.x, 1.0), Color(UI.ACCENT, 0.85)))
	add_child(_subbar)
	# The preview pages' picture and its text.
	_pane = Control.new()
	_pane.name = "Preview"
	_pane.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pane.draw.connect(_draw_preview)
	add_child(_pane)
	_desc = RichTextLabel.new()
	_desc.name = "PreviewText"
	_desc.bbcode_enabled = true
	_desc.scroll_active = false
	_desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_desc.add_theme_font_override("normal_font", UI.font("semi"))
	_desc.add_theme_font_size_override("normal_font_size", 17)
	_desc.add_theme_color_override("default_color", UI.TEXT)
	_pane.add_child(_desc)
	# Content.
	_scroll = ScrollContainer.new()
	_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	UI.style_scroll(_scroll)
	add_child(_scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 6)
	_scroll.add_child(_body)
	# Bottom-left of the content: the square RESET, then a short hint.
	_reset_btn = Button.new()
	_reset_btn.name = "Reset"
	_reset_btn.focus_mode = Control.FOCUS_NONE
	_reset_btn.tooltip_text = "RESET"
	_reset_btn.icon = UI.icon_texture("v_reload")
	_reset_btn.expand_icon = true
	_reset_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_reset_btn.add_theme_constant_override("icon_max_width", 30)
	var rs := UI.chamfer(Color(0.03, 0.025, 0.035, 0.9), 8, 1, Color(1, 1, 1, 0.25), 10.0, ["br"])
	var rp := UI.chamfer(Color(UI.ACCENT, 0.35), 8, 1, UI.ACCENT, 10.0, ["br"])
	_reset_btn.add_theme_stylebox_override("normal", rs)
	_reset_btn.add_theme_stylebox_override("hover", rs)
	_reset_btn.add_theme_stylebox_override("pressed", rp)
	_reset_btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_reset_btn.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_reset_btn.offset_left = MENU_W + 34
	_reset_btn.offset_right = MENU_W + 34 + UI.TOUCH_MIN
	_reset_btn.offset_top = -16 - UI.TOUCH_MIN
	_reset_btn.offset_bottom = -16
	_reset_btn.pressed.connect(_ask_reset)
	add_child(_reset_btn)
	_hint = UI.label("", 15, UI.TEXT_DIM, "semi")
	_hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_hint.offset_left = MENU_W + 34 + UI.TOUCH_MIN + 16
	_hint.offset_right = -40
	_hint.offset_top = -16 - UI.TOUCH_MIN
	_hint.offset_bottom = -16
	_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_hint)
	# AUTO's pick can arrive while the panel is open (the measurement ends): DISPLAY shows it.
	Game.settings_changed.connect(_refresh_graphics)
	resized.connect(_layout)
	_show_tab(6)
	modulate.a = 0.0
	create_tween().tween_property(self, "modulate:a", 1.0, 0.18)


## A tab of the column: the kit's side tab (UI.side_tab, as FRIENDS' and PROFILE's tabs: a dark box
## with a light lower edge; the open one yellow with hazard stripes, a cut line and a notch).
func _menu_button(text: String, m: int) -> Button:
	var b := UI.side_tab(text, false, 22, Vector2(MENU_W - 16.0, 58))
	b.name = "Menu_" + text
	b.pressed.connect(func() -> void:
		var pages: Array = MENU[m][1]
		_show_tab(_current if _current in pages else int(pages[0])))
	return b


## A sub-tab (IN-MATCH's second row): light grey when selected, with hazard stripes along its
## right and bottom edges and a cut top-left corner (the reference's), else plain text on the bar.
func _sub_button(page: int) -> Button:
	var b := Button.new()
	b.name = "Sub_" + String(TABS[page])
	b.toggle_mode = true
	b.button_pressed = page == _current
	b.focus_mode = Control.FOCUS_NONE
	b.text = String(TABS[page])
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(0, UI.TOUCH_MIN)
	b.add_theme_font_override("font", UI.font("bold"))
	b.add_theme_font_size_override("font_size", 19)
	var off := StyleBoxEmpty.new()
	var on := UI.chamfer(SUBTAB_ON, 10, 0, Color.TRANSPARENT, 8.0, ["tl"])
	on.content_margin_bottom = 12
	b.add_theme_stylebox_override("normal", off)
	b.add_theme_stylebox_override("hover", off)
	b.add_theme_stylebox_override("pressed", on)
	b.add_theme_stylebox_override("hover_pressed", on)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("font_color", UI.TEXT)
	b.add_theme_color_override("font_hover_color", UI.ACCENT)
	b.add_theme_color_override("font_pressed_color", UI.INK)
	b.add_theme_color_override("font_hover_pressed_color", UI.INK)
	b.draw.connect(func() -> void:
		if b.button_pressed:
			UI.draw_hazard(b, Rect2(0, b.size.y - 6.0, b.size.x, 6.0), 5.0, Color(0.08, 0.07, 0.06), UI.ACCENT)
			UI.draw_hazard(b, Rect2(b.size.x - 6.0, 0, 6.0, b.size.y - 6.0), 5.0, Color(0.08, 0.07, 0.06), UI.ACCENT))
	b.pressed.connect(func() -> void:
		Audio.play("ui_select", -6.0)
		_show_tab(page))
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
	if _prows.has(_sel):
		_refresh_preview()


## The MENU entry that holds page `page`.
static func menu_of(page: int) -> int:
	for m in MENU.size():
		if page in (MENU[m][1] as Array):
			return m
	return 0


func _show_tab(i: int) -> void:
	_current = clampi(i, 0, TABS.size() - 1)
	var m := menu_of(_current)
	for k in _menu_buttons:
		UI.style_side_tab(_menu_buttons[k] as Button, k == m)
	for c in _subbar.get_children():
		_subbar.remove_child(c)
		c.queue_free()
	var pages: Array = MENU[m][1]
	_subbar.visible = pages.size() > 1
	if _subbar.visible:
		for p: int in pages:
			_subbar.add_child(_sub_button(p))
	for c in _body.get_children():
		_body.remove_child(c)
		c.queue_free()
	_sens_rows.clear()
	_prows.clear()
	_sel = ""
	_preset_seg = null
	_graphics_seg = null
	_graphics_tiles = null
	_graphics_note = null
	_minimap_note = null
	_cache_note = null
	if _footer and is_instance_valid(_footer):
		_footer.queue_free()
	_footer = null
	_hint.text = ""
	_hint.visible = true
	_reset_btn.visible = not (TAB_KEYS[_current] as Array).is_empty()
	_pane.visible = _current in PREVIEW_TABS
	_layout()
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
		6:
			_build_hud()
		7:
			_build_vibration()
	if not _prows.is_empty():
		_select(String(_prows.keys()[0]))
	# A finger drag that starts on a row scrolls the tab (a tap still presses); a slider keeps its
	# own drag, so moving one never scrolls the list.
	UI.drag_scroll(_scroll, _body)
	for s in _body.find_children("*", "Slider", true, false):
		(s as Control).mouse_filter = Control.MOUSE_FILTER_STOP


## Places the content, the preview pane and its text for this page and screen.
func _layout() -> void:
	if _scroll == null:
		return
	var vs := size if size.x > 0.0 else get_viewport_rect().size
	var left := MENU_W + 34.0
	var top := 132.0 if _subbar.visible else 76.0
	var bottom := 16.0 + UI.TOUCH_MIN + 12.0
	var x := left
	if _pane.visible:
		var w := clampf((vs.x - left - 40.0) * 0.38, 330.0, 520.0)
		_pane.position = Vector2(left, top)
		_pane.size = Vector2(w, minf(vs.y - top - bottom, w * 0.8 + 90.0))
		var pic_h := _pic_h()
		_desc.position = Vector2(12, pic_h + 8.0)
		_desc.size = Vector2(w - 24.0, _pane.size.y - pic_h - 12.0)
		_pane.queue_redraw()
		x = left + w + 8.0
	_scroll.offset_left = x
	_scroll.offset_right = -40
	_scroll.offset_top = top
	_scroll.offset_bottom = -bottom


func _pic_h() -> float:
	return maxf(_pane.size.y - 90.0, 120.0)


# ---------------------------------------------------------------- rows and pictures

## A setting row on its own dark plate (the reference's): the title, an optional dim help line
## under it, the control at the right end.
func _plate(title: String, control: Control, note := "") -> PanelContainer:
	var row := UI.plate_row(title, control, note)
	row.add_theme_stylebox_override("panel", _row_style(false))
	_dark_segments(control)
	if note != "":
		# The help line takes the row's free width (at least plate_row's title width): the control
		# keeps its own width at the right end; a slider shares the room with the text.
		(row.get_child(0).get_child(0) as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if not control.has_meta("slider"):
			control.size_flags_horizontal = Control.SIZE_SHRINK_END
	return row


func _row_style(selected: bool) -> StyleBoxFlat:
	var st := UI.chamfer(ROW_BG, 6, 2 if selected else 0, UI.ACCENT if selected else Color.TRANSPARENT, 14.0, ["br"])
	st.content_margin_top = 6
	st.content_margin_bottom = 6
	return st


## The reference's segments: the chosen one light grey, the others near-black.
func _dark_segments(c: Control) -> void:
	if not (c is HBoxContainer):
		return
	var seg := false
	for b in c.get_children():
		if b is Button and (b as Button).toggle_mode and (b as Button).button_group != null:
			var st := (b as Button).get_theme_stylebox("normal")
			if st is StyleBoxFlat:
				var dark := (st as StyleBoxFlat).duplicate() as StyleBoxFlat
				dark.bg_color = SEG_OFF
				dark.border_color = Color(1, 1, 1, 0.35)
				(b as Button).add_theme_stylebox_override("normal", dark)
				seg = true
	if seg:
		(c as HBoxContainer).alignment = BoxContainer.ALIGNMENT_END      # at the row's right end


## An indented sub-row (the reference's: a grey bar on its left).
func _indent(c: Control) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	var bar := ColorRect.new()
	bar.color = Color(1, 1, 1, 0.18)
	bar.custom_minimum_size = Vector2(4, 0)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(bar)
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(c)
	return h


## A row of a preview page: only the title and the control (the help is under the picture).
## `info` returns what the picture shows for the row's current value: {pic, spot, callout, value,
## text}. Tapping the row or using its control selects it.
func _prow(id: String, title: String, control: Control, info: Callable) -> PanelContainer:
	var row := UI.plate_row(title, control, "", 170.0)
	row.name = "Row_" + id
	row.add_theme_stylebox_override("panel", _row_style(false))
	_dark_segments(control)
	_prows[id] = [row, info]
	# A tap on the row selects it when the finger lifts, and only if it moved less than the
	# list's scroll dead zone: a drag that scrolls the page leaves the selection (and the picture)
	# alone. The row's own controls select it through their signals below.
	var down := {}       # where the finger (or the mouse, which the engine doubles as touches) went down
	row.gui_input.connect(func(e: InputEvent) -> void:
		var kind := ""
		var at := Vector2.ZERO
		var pressed := false
		if e is InputEventMouseButton and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			kind = "mouse"
			at = (e as InputEventMouseButton).global_position
			pressed = (e as InputEventMouseButton).pressed
		elif e is InputEventScreenTouch:
			kind = "touch"
			at = row.get_global_transform_with_canvas() * (e as InputEventScreenTouch).position
			pressed = (e as InputEventScreenTouch).pressed
		if kind == "":
			return
		if pressed:
			down[kind] = at
		elif down.has(kind):
			if at.distance_to(down[kind]) < float(UI.SCROLL_DEADZONE):
				_select(id)
			down.erase(kind))
	for b in control.find_children("*", "Button", true, false):
		(b as Button).pressed.connect(func() -> void: _select(id))
	for s in control.find_children("*", "Slider", true, false):
		(s as Slider).value_changed.connect(func(_v: float) -> void: _select(id))
	_body.add_child(row)
	return row


## Selects a preview row: its yellow outline, its picture and text.
func _select(id: String) -> void:
	if not _prows.has(id):
		return
	if _prows.has(_sel) and _sel != id:
		((_prows[_sel] as Array)[0] as PanelContainer).add_theme_stylebox_override("panel", _row_style(false))
	_sel = id
	((_prows[id] as Array)[0] as PanelContainer).add_theme_stylebox_override("panel", _row_style(true))
	_refresh_preview()


## What the picture and its text show now (the selected row's info for its current value).
func preview_info() -> Dictionary:
	if not _prows.has(_sel):
		return {}
	return ((_prows[_sel] as Array)[1] as Callable).call()


func _refresh_preview() -> void:
	var inf := preview_info()
	if inf.is_empty():
		_desc.text = ""
	else:
		var v := String(inf.get("value", ""))
		_desc.text = ("[color=#%s]%s[/color]  " % [UI.ACCENT.to_html(false), v] if v != "" else "") + String(inf.get("text", ""))
	_pane.queue_redraw()


## The preview picture: our screenshot cropped around the row's button, the button ringed in
## dashed yellow with a yellow callout; "swipe" draws a drag on the right side with the camera's
## turn arrows instead.
func _draw_preview() -> void:
	var w := _pane.size.x
	var ph := _pic_h()
	_pane.draw_rect(Rect2(Vector2.ZERO, _pane.size), Color(0.03, 0.025, 0.035, 0.85))
	var box := Rect2(4, 4, w - 8.0, ph - 4.0)
	var inf := preview_info()
	var tex := UI.texture(PIC_DIR + String(inf.get("pic", "hud.png")))
	var spot_id := String(inf.get("spot", ""))
	var spot: Dictionary = SPOTS.get(spot_id, {"x": 0.62, "y": 0.5, "r": 0.0})
	if tex == null:
		_pane.draw_rect(box, Color(0.12, 0.1, 0.13))
		return
	var ts := tex.get_size()
	var crop := Rect2(Vector2.ZERO, ts)
	if ts.x / ts.y > box.size.x / box.size.y:
		crop.size.x = ts.y * box.size.x / box.size.y
		crop.position.x = clampf(float(spot.x) * ts.x - crop.size.x * 0.5, 0.0, ts.x - crop.size.x)
	else:
		crop.size.y = ts.x * box.size.y / box.size.x
		crop.position.y = clampf(float(spot.y) * ts.y - crop.size.y * 0.5, 0.0, ts.y - crop.size.y)
	_pane.draw_texture_rect_region(tex, box, crop)
	var k := box.size.x / crop.size.x
	var p := box.position + (Vector2(float(spot.x), float(spot.y)) * ts - crop.position) * k
	var callout := String(inf.get("callout", ""))
	var font := UI.font("bold")
	if spot_id == "swipe" or spot_id == "":
		_draw_swipe(box)
		if callout != "":
			var cw := font.get_string_size(callout, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
			_callout(font, callout, Vector2(box.get_center().x - cw * 0.5, box.end.y - 22.0))
		return
	var r := float(spot.r) * ts.y * k + 8.0
	var n := 18
	for i in n:
		var a0 := TAU * float(i) / float(n)
		_pane.draw_arc(p, r, a0, a0 + TAU / float(n) * 0.55, 6, UI.ACCENT, 3.0, true)
	if callout != "":
		var cw2 := font.get_string_size(callout, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
		var at := Vector2(p.x - r - 10.0 - cw2, p.y + 6.0) if p.x > box.get_center().x else Vector2(p.x + r + 10.0, p.y + 6.0)
		at.x = clampf(at.x, box.position.x + 6.0, box.end.x - cw2 - 6.0)
		if at.x < p.x + r and at.x + cw2 > p.x - r:
			at.y = p.y - r - 10.0 if p.y > box.get_center().y else p.y + r + 24.0     # no room beside it: above or below
		at.y = clampf(at.y, box.position.y + 22.0, box.end.y - 8.0)
		_callout(font, callout, at)


func _callout(font: Font, text: String, at: Vector2) -> void:
	var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
	_pane.draw_rect(Rect2(at.x - 6.0, at.y - 19.0, tw + 12.0, 26.0), Color(0, 0, 0, 0.55))
	_pane.draw_string(font, at + Vector2(1.5, 1.5), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0, 0, 0, 0.85))
	_pane.draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, UI.ACCENT)


## A finger's drag on the right side (a white trail) and the camera's turn (two yellow arrows).
func _draw_swipe(box: Rect2) -> void:
	var c := box.position + box.size * Vector2(0.62, 0.42)
	var trail := PackedVector2Array()
	for i in 13:
		var t := float(i) / 12.0
		trail.append(box.position + box.size * Vector2(0.86 - 0.22 * t, 0.62 - 0.22 * t + 0.25 * t * (1.0 - t)))
	_pane.draw_polyline(trail, Color(1, 1, 1, 0.85), 4.0, true)
	_pane.draw_circle(trail[0], 9.0, Color(1, 1, 1, 0.6))
	var rr := box.size.y * 0.2
	for side: float in [-1.0, 1.0]:
		var a0 := PI * 0.5 + side * 0.35
		var a1 := PI * 0.5 + side * 1.25
		_pane.draw_arc(c, rr, a0, a1, 12, UI.ACCENT, 5.0, true)
		var tip := c + Vector2(cos(a1), sin(a1)) * rr
		var dir := Vector2(-sin(a1), cos(a1)) * side
		var nrm := Vector2(-dir.y, dir.x)
		_pane.draw_colored_polygon(PackedVector2Array([tip + dir * 14.0, tip + nrm * 9.0, tip - nrm * 9.0]), UI.ACCENT)


## Picture tiles in a row (the reference's filter and minimap choices): each a toggle Button
## (child index = choice) drawing its picture, a caption under it and a yellow frame when chosen.
func _tiles(names: Array, pics: Array, selected: int, on_change: Callable, tile: Vector2) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 16)
	var group := ButtonGroup.new()
	group.allow_unpress = false
	for i in names.size():
		var b := Button.new()
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = i == selected
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = tile + Vector2(0, 28)
		b.tooltip_text = String(names[i])
		for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
			b.add_theme_stylebox_override(st, StyleBoxEmpty.new())
		var tex := UI.texture(PIC_DIR + String(pics[i]))
		var caption := String(names[i])
		b.draw.connect(func() -> void:
			var r := Rect2(Vector2(2, 2), tile - Vector2(4, 4))
			if tex:
				b.draw_texture_rect(tex, r, false)
			else:
				b.draw_rect(r, Color(0.14, 0.12, 0.15))
			if b.button_pressed:
				b.draw_rect(Rect2(Vector2(1, 1), tile - Vector2(2, 2)), UI.ACCENT, false, 3.0)
			else:
				b.draw_rect(Rect2(Vector2(1, 1), tile - Vector2(2, 2)), Color(1, 1, 1, 0.22), false, 1.0)
			var f := UI.font("semi")
			var fs := 16
			while fs > 11 and f.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > b.size.x:
				fs -= 1
			b.draw_string(f, Vector2(0, tile.y + 21.0), caption, HORIZONTAL_ALIGNMENT_CENTER, b.size.x, fs,
				UI.ACCENT if b.button_pressed else UI.TEXT))
		var idx := i
		b.pressed.connect(func() -> void:
			Audio.play("ui_select", -6.0)
			on_change.call(idx))
		h.add_child(b)
	return h


# ---------------------------------------------------------------- HUD

func _build_hud() -> void:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 22)
	var vs := size if size.x > 0.0 else get_viewport_rect().size
	var tw := clampf((vs.x - MENU_W - 74.0) * 0.62, 420.0, 760.0)
	var tile := Control.new()
	tile.name = "HudTile"
	tile.custom_minimum_size = Vector2(tw, tw * 9.0 / 16.0 + 30.0)
	var tex := UI.texture(PIC_DIR + "hud.png")
	tile.draw.connect(func() -> void:
		var r := Rect2(0, 30, tile.size.x, tile.size.y - 30.0)
		if tex:
			tile.draw_texture_rect(tex, r, false)
		else:
			tile.draw_rect(r, Color(0.14, 0.12, 0.15))
		tile.draw_rect(r.grow(-1.0), UI.ACCENT, false, 2.0)
		# the header tab over the picture: a yellow trapezoid with the layout's name
		var cx := tile.size.x * 0.5
		tile.draw_colored_polygon(PackedVector2Array([Vector2(cx - 90, 2), Vector2(cx + 90, 2), Vector2(cx + 74, 32), Vector2(cx - 74, 32)]), UI.ACCENT)
		tile.draw_string(UI.font("bold"), Vector2(cx - 90, 25), "MY HUD", HORIZONTAL_ALIGNMENT_CENTER, 180, 20, UI.INK))
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.offset_top = 30
	tile.add_child(center)
	if in_match and not edit_hud.is_valid():
		var note := UI.label("CUSTOM HUD: IN THE LOBBY", 18, UI.TEXT, "bold")
		note.name = "EditHudNote"
		UI.outlined(note, 5)
		center.add_child(note)
	else:
		center.add_child(_edit_hud_button(edit_hud if in_match else Game.goto_hud_editor))
	h.add_child(tile)
	var side := VBoxContainer.new()
	side.add_theme_constant_override("separation", 10)
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side.add_child(UI.section("CUSTOM HUD"))
	for t in ["Move every button where your thumbs want it.", "Make each one bigger or smaller, and see-through.",
			"SAVE in the editor uses it in your next match" + (" and in this one at once." if in_match else ".")]:
		var l := UI.label(t, 17, UI.TEXT_DIM, "semi")
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		side.add_child(l)
	h.add_child(side)
	_body.add_child(h)
	if in_match and not edit_hud.is_valid():
		_hint.text = "Leaving for the editor now would end this match: open it from the lobby."


## CUSTOM (node EditHud): saves the settings, then `open` opens the editor (the lobby's scene, or
## in a match the in-match menu's editor over it).
func _edit_hud_button(open: Callable) -> Button:
	var hud_btn := UI.button("CUSTOM", 22, "primary", Vector2(230, 58))
	hud_btn.name = "EditHud"
	hud_btn.icon = UI.icon_texture("v_hud")
	hud_btn.expand_icon = true
	hud_btn.add_theme_constant_override("icon_max_width", 26)
	hud_btn.pressed.connect(func() -> void:
		Game.save_settings()
		open.call())
	return hud_btn


# ---------------------------------------------------------------- DISPLAY

func _build_display() -> void:
	_body.add_child(UI.section("GRAPHICS"))
	var sel := 0 if bool(Game.settings.graphics_auto) else int(Game.settings.graphics) + 1
	_graphics_seg = UI.segmented(GRAPHICS_CHOICES, sel, _on_graphics, 17, 96.0)
	_graphics_seg.name = "GraphicsChoice"
	for i in range(1, _graphics_seg.get_child_count()):
		var b := _graphics_seg.get_child(i) as Button
		var level := i - 1
		b.draw.connect(func() -> void:
			# AUTO's pick: a short accent bar under its caption
			if bool(Game.settings.graphics_auto) and int(Game.settings.graphics) == level:
				b.draw_rect(Rect2(b.size.x * 0.3, b.size.y - 8.0, b.size.x * 0.4, 3.0), UI.ACCENT))
	var row := _plate("Graphics", _graphics_seg, "-")
	_graphics_note = _note_of(row)
	_body.add_child(row)
	# Our arena at each level, as picture tiles (a tap picks that level, as the segment does).
	var pics := []
	for i in Game.GRAPHICS_NAMES.size():
		pics.append("gfx_%d.png" % i)
	_graphics_tiles = _tiles(Game.GRAPHICS_NAMES, pics, int(Game.settings.graphics), func(v: int) -> void: _on_graphics(v + 1), Vector2(144, 81))
	_graphics_tiles.name = "GraphicsTiles"
	_body.add_child(_indent(_plate("Preview", _graphics_tiles, "How the arena looks at each level")))
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
	_body.add_child(_plate("Frame rate", fps_seg, _fps_note(fps_opts)))
	_body.add_child(_plate("Visual effects", _toggle("visual_effects"), "Lights on shots and blasts, full sparks; off helps weak phones"))
	_body.add_child(UI.spacer(4))
	_body.add_child(UI.section("MINIMAP"))
	var turns := bool(Game.settings.minimap_turns)
	var mm := _tiles(MINIMAP_NAMES, ["map_turn.png", "map_north.png"], 0 if turns else 1, _set_minimap, Vector2(118, 118))
	mm.name = "Toggle_minimap_turns"
	var mm_row := _plate("Minimap", mm, String(MINIMAP_NOTES[0 if turns else 1]))
	_minimap_note = _note_of(mm_row)
	_body.add_child(mm_row)
	_hint.text = "In a match the 3D view draws a little smaller while frames run slow; the HUD stays sharp."


## The cache row (ACCOUNT, TOOLS): what CLEAR CACHE would free now, the button (node ClearCache).
func cache_row() -> Control:
	var clear_btn := UI.button("CLEAR", 18, "light", Vector2(170, 52))
	clear_btn.name = "ClearCache"
	clear_btn.pressed.connect(_ask_clear_cache)
	var row := _plate("Cache", clear_btn, "Shader cache, old logs, leftover temporary files: %s" % CacheCleaner.size_text(int(CacheCleaner.scan().bytes)))
	clear_btn.size_flags_horizontal = Control.SIZE_SHRINK_END      # at the row's end (the note takes the rest)
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
## (accent caption and bar) and named in the note; the picture of the level in use framed.
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
	if _graphics_tiles and is_instance_valid(_graphics_tiles):
		for i in _graphics_tiles.get_child_count():
			var t := _graphics_tiles.get_child(i) as Button
			t.set_pressed_no_signal(i == level)
			t.queue_redraw()
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
	_preset_seg = UI.segmented(PRESET_NAMES, _preset_index(), _apply_preset, 16, 104.0)
	_preset_seg.name = "SensPreset"
	_dark_segments(_preset_seg)
	head.add_child(_preset_seg)
	_body.add_child(head)
	for r: Array in SENS_ROWS:
		var note := String(r[2])
		if r[1] == "sens_2x":
			note += " (%s)" % ", ".join(guns_with_sight("2x"))
		_sens_row(String(r[0]), String(r[1]), note)
	_hint.text = "0-100. Higher turns faster for the same swipe."


## The pickable guns' names that aim through `sight` (Player.sight_of).
static func guns_with_sight(sight: String) -> PackedStringArray:
	var out := PackedStringArray()
	for id: String in Weapons.PICKABLE:
		if Player.sight_of(Weapons.DEFS[id]) == sight:
			out.append(String(Weapons.DEFS[id].name))
	return out


## A stored sensitivity (1-200, ours) as the row shows it (0-100): our default shows as
## SENS_SHOWN, the ends as 0 and 100, straight lines between.
static func sens_shown(key: String, stored: int) -> int:
	var lim: Array = Game.SETTING_RANGES[key]
	var lo := float(lim[0])
	var hi := float(lim[1])
	var s0 := float(Game.DEFAULT_SETTINGS[key])
	var d := float(SENS_SHOWN[key])
	var s := clampf(float(stored), lo, hi)
	if s <= s0:
		return roundi(d * (s - lo) / (s0 - lo))
	return roundi(d + (100.0 - d) * (s - s0) / (hi - s0))


## The stored value (1-200) of a sensitivity the row shows as `shown` (0-100): sens_shown's inverse.
static func sens_value(key: String, shown: int) -> int:
	var lim: Array = Game.SETTING_RANGES[key]
	var lo := float(lim[0])
	var hi := float(lim[1])
	var s0 := float(Game.DEFAULT_SETTINGS[key])
	var d := float(SENS_SHOWN[key])
	var x := clampf(float(shown), 0.0, 100.0)
	if x <= d:
		return roundi(lo + (s0 - lo) * x / d)
	return roundi(s0 + (hi - s0) * (x - d) / (100.0 - d))


func _sens_row(title: String, key: String, note: String) -> void:
	var st := UI.stepper(sens_shown(key, int(Game.settings[key])), 0, 100, func(v: float) -> void:
		_apply(key, sens_stored(key, int(v)))
		_refresh_preset())
	st.name = "Sens_" + key
	(st.get_meta("slider") as Control).custom_minimum_size.x = 150.0
	_sens_rows[key] = st
	var spot := "swipe"
	var pic := "hud.png"
	var callout := "Drag here to turn"
	if key == "sens_freelook":
		spot = "freelook"
		pic = "hud_eye.png"
		callout = "Hold and drag to look around"
	elif key != "sens_general":
		spot = "scope"
		callout = "Aim, then drag to turn"
	_prow(key, title, st, func() -> Dictionary:
		return {"pic": pic, "spot": spot, "callout": callout, "value": "", "text": note})


## What a sensitivity row stores for the number `shown` it was set to: a preset's own value where
## that preset reads `shown` (so stepping back to a preset's number is that preset exactly, though
## the 0-100 steps do not land on every stored value), else sens_value.
static func sens_stored(key: String, shown: int) -> int:
	for n: String in PRESET_NAMES:
		var p: Dictionary = SENS_PRESETS[n]
		if p.has(key) and sens_shown(key, int(p[key])) == shown:
			return int(p[key])
	return sens_value(key, shown)


## The preset the sensitivities match as the rows show them (0-100), or -1.
func _preset_index() -> int:
	for i in PRESET_NAMES.size():
		var p: Dictionary = SENS_PRESETS[PRESET_NAMES[i]]
		var same := true
		for k: String in p:
			if sens_shown(k, int(Game.settings[k])) != sens_shown(k, int(p[k])):
				same = false
		if same:
			return i
	return -1


func _apply_preset(i: int) -> void:
	var p: Dictionary = SENS_PRESETS[PRESET_NAMES[i]]
	for k: String in p:
		_apply(k, int(p[k]))
		if _sens_rows.has(k):
			var shown := sens_shown(k, int(p[k]))
			var s: HSlider = (_sens_rows[k] as Control).get_meta("slider")
			s.set_value_no_signal(float(shown))
			var v := (_sens_rows[k] as HBoxContainer).get_child(0) as Label
			v.text = str(shown)
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
	var aim_seg := UI.segmented(PRECISION_NAMES, precision, _set_precision, 14, 124.0)
	aim_seg.name = "AimPrecision"
	_prow("aim", "Aim precision", aim_seg, func() -> Dictionary:
		var v := clampi(int(Game.settings.aim_precision), 0, PRECISION_NAMES.size() - 1)
		return {"pic": "hud.png", "spot": "fire_r", "callout": "Fire when the crosshair turns red",
			"value": PRECISION_NAMES[v], "text": PRECISION_NOTES[v]})
	var lf_at := maxi(LEFT_FIRE_VALUES.find(int(Game.settings.left_fire)), 0)
	var left_fire := UI.segmented(LEFT_FIRE_NAMES, lf_at, func(v: int) -> void: _apply("left_fire", int(LEFT_FIRE_VALUES[v])), 14, 108.0)
	left_fire.name = "LeftFire"
	_prow("left_fire", "Left fire button", left_fire, func() -> Dictionary:
		var at := maxi(LEFT_FIRE_VALUES.find(int(Game.settings.left_fire)), 0)
		return {"pic": "hud.png", "spot": "fire_l", "callout": "Fire with your left thumb",
			"value": LEFT_FIRE_NAMES[at], "text": LEFT_FIRE_NOTES[at]})
	_switch_prow("hold_fire_scope", "Hold fire to scope", "fire_r", "HOLD to look through the scope",
		"Sniper rifles: hold FIRE to look through the scope, let go to shoot", "Sniper rifles: FIRE shoots at once, SCOPE aims")
	_body.add_child(UI.spacer(2))
	_body.add_child(UI.section("QUICK BUTTONS"))
	_switch_prow("switch_button", "Weapon switch button", "swap", "Swap the gun and the fists",
		"A SWITCH button beside RELOAD; it shows the weapon it swaps to", "No SWITCH button: tap a slot on the weapon panel")
	_switch_prow("reload_button", "Reload button", "reload", "TAP to reload",
		"A RELOAD button beside FIRE (tapping the weapon panel reloads too)", "No RELOAD button: tap the weapon panel to reload")
	_switch_prow("reload_on_crosshair", "Reload ring", "center", "Reloading",
		"The reload's progress shows as a ring around the crosshair", "No ring around the crosshair while reloading")
	_prow("freelook_button", "Free look button", _toggle("freelook_button"), func() -> Dictionary:
		if bool(Game.settings.freelook_button):
			return {"pic": "hud_eye.png", "spot": "freelook", "callout": "Hold and drag to look around", "value": "ON",
				"text": FREELOOK_NOTES[1]}
		return {"pic": "hud.png", "spot": "swipe", "callout": "Drag the right side to look around", "value": "OFF",
			"text": FREELOOK_NOTES[0]})
	_body.add_child(UI.spacer(2))
	_body.add_child(UI.section("MOVEMENT"))
	var dynamic := bool(Game.settings.dynamic_joystick)
	var joy_seg := UI.segmented(JOYSTICK_NAMES, 0 if dynamic else 1, _set_joystick, 16, 130.0)
	joy_seg.name = "Toggle_dynamic_joystick"
	_prow("joystick", "Joystick", joy_seg, func() -> Dictionary:
		var v := 0 if bool(Game.settings.dynamic_joystick) else 1
		return {"pic": "hud.png", "spot": "joystick", "callout": "Move beyond the ring" if v == 0 else "The stick stays here",
			"value": JOYSTICK_NAMES[v], "text": JOYSTICK_NOTES[v]})
	var run := clampi(int(Game.settings.run_mode), 0, RUN_MODE_NAMES.size() - 1)
	var run_seg := UI.segmented(RUN_MODE_NAMES, run, _set_run_mode, 16, 104.0)
	run_seg.name = "RunMode"
	_prow("run_mode", "Run mode", run_seg, func() -> Dictionary:
		var v := clampi(int(Game.settings.run_mode), 0, RUN_MODE_NAMES.size() - 1)
		return {"pic": "hud.png", "spot": "joystick" if v == 1 else "sprint", "callout": ["Tap to sprint", "Push past the ring", "Tap, or push past the ring"][v],
			"value": RUN_MODE_NAMES[v], "text": RUN_MODE_NOTES[v]})


## An OFF / ON row of CONTROLS with its picture: the button `spot` ringed, the text for each value.
func _switch_prow(key: String, title: String, spot: String, callout: String, on_text: String, off_text: String) -> void:
	_prow(key, title, _toggle(key), func() -> Dictionary:
		var on := bool(Game.settings[key])
		return {"pic": "hud.png", "spot": spot, "callout": callout, "value": "ON" if on else "OFF", "text": on_text if on else off_text})


func _set_run_mode(v: int) -> void:
	_apply("run_mode", v)


## The minimap choice: 0 TURNS WITH VIEW, 1 NORTH UP (read live by the HUD's minimap).
func _set_minimap(v: int) -> void:
	_apply("minimap_turns", v == 0)
	if _minimap_note and is_instance_valid(_minimap_note):
		_minimap_note.text = String(MINIMAP_NOTES[v])


## The joystick choice: 0 DYNAMIC, 1 FIXED.
func _set_joystick(v: int) -> void:
	_apply("dynamic_joystick", v == 0)


func _set_precision(v: int) -> void:
	_apply("aim_precision", v)


# ---------------------------------------------------------------- VIBRATION

func _build_vibration() -> void:
	_body.add_child(UI.section("ENEMIES NEARBY"))
	var r0: Array = VIBRATION_ROWS[0]
	_body.add_child(_plate(String(r0[0]), _toggle(String(r0[1])), String(r0[2])))
	_body.add_child(UI.spacer(2))
	_body.add_child(UI.section("YOU"))
	for r: Array in VIBRATION_ROWS.slice(1):
		_body.add_child(_plate(String(r[0]), _toggle(String(r[1])), String(r[2])))
	_hint.text = "Each switch buzzes once when you turn it on."


# ---------------------------------------------------------------- SOUND

func _build_sound() -> void:
	_body.add_child(UI.section("GAME AUDIO"))
	var music := UI.stepper(Game.settings.vol_music, 0, 100, func(v: float) -> void: _apply("vol_music", int(v)), 5.0)
	music.name = "Stepper_vol_music"
	_body.add_child(_plate("Music", music))
	var sfx := UI.stepper(Game.settings.vol_sfx, 0, 100, func(v: float) -> void: _apply("vol_sfx", int(v)), 5.0)
	sfx.name = "Stepper_vol_sfx"
	_body.add_child(_plate("Sound effects", sfx))
	_body.add_child(UI.spacer(2))
	_body.add_child(UI.section("VOICE CHAT"))
	var voice := UI.stepper(Game.settings.vol_voice, 0, 100, func(v: float) -> void: _apply("vol_voice", int(v)), 5.0)
	voice.name = "Stepper_vol_voice"
	_body.add_child(_plate("Voice", voice, "Your opponent's voice in an online match (push to talk: ONLINE)"))
	_hint.text = "0 mutes a channel. Changes are heard at once."


func _toggle(key: String) -> Control:
	var t := UI.segmented(["OFF", "ON"], 1 if Game.settings[key] else 0, func(v: int) -> void: _apply(key, v == 1), 17, 104.0)
	t.name = "Toggle_" + key
	_dark_segments(t)
	return t


## RESET asks before it puts the current tab back.
func _ask_reset() -> void:
	var tab := String(TABS[_current])
	_ask("RESET " + tab, "Put every %s setting back to its default?" % tab, "RESET", _reset_tab)


## A question over the panel (the in-match QUIT MATCH asks with it too): ok_text runs on_ok,
## CANCEL (or back) only closes it; `danger` makes the OK button red (a step that cannot be undone).
## Returns the question's column (title, text, then the buttons' row) for a caller's extra line.
func ask(title: String, text: String, ok_text: String, on_ok: Callable, danger := false) -> VBoxContainer:
	_ask(title, text, ok_text, on_ok, danger)
	return _ask_col


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
	_ask_col = v


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
	c.offset_left = MENU_W + 34
	c.offset_right = -40
	c.offset_top = -10 - UI.TOUCH_MIN
	c.offset_bottom = -10
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


## Closes the panel the way its X does (saved, `closed` emitted, freed); nothing while a task runs
## (busy: DELETE MY DATA keeps its waiting screen). The lobby calls it when a match is found.
func close_panel() -> void:
	_close()


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

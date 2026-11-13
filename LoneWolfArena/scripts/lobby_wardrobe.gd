class_name LobbyWardrobe
extends RefCounted
## WARDROBE in the lobby: the picker over the 3D stage while the camera moves so the character
## stands on the right. Left: the categories OUTFIT / LOBBY POSE / VICTORY POSE (WardTab_<kind>);
## then the items: outfit cards (the outfit's portrait and its own colour) or pose tiles; the info
## strip under them; the page frame's X in the corner (WardrobeClose) and EQUIP / BACK under the
## preview. A tap on an item shows it on the character at once (the outfit worn, the pose played)
## with its name on a tag by the character (WardrobeTag); EQUIP saves it (Game.profile bundle,
## lobby_pose, victory_pose) and turns into a grey EQUIPPED; leaving without EQUIP (X, BACK, Android
## back) puts the equipped outfit back. Every item is free and unlocked: no prices, no ranks. The
## lobby makes it (Lobby.wardrobe_ui) and opens it from WARDROBE in its bottom bar.
## Node names used by the screenshot walkthrough: Wardrobe, WardTab_<outfit|lobby|victory>,
## Bundle_<id>, Pose_<clip or random>, EquipButton, BackButton, WardrobeClose, WardrobeTag.

const CARD_SIZE := Vector2(168, 222)
## Each outfit's own accent (card glow and bar, its name in the lobby): a colour that goes with
## the clothes, not a rank.
const OUTFIT_COLORS := {
	"default": Color(0.80, 0.82, 0.86),     # ROOKIE: white tee, light grey
	"desert": Color(0.88, 0.67, 0.38),      # DESERT FOX: sand
	"neon": Color(0.22, 0.86, 0.96),        # NEON STRIKER: its cyan edge
	"shadow": Color(0.92, 0.33, 0.30),      # SHADOW OPS: red night light
	"royal": Color(1.0, 0.74, 0.18),        # ROYAL GOLD: gold
}

## The categories: [kind, tab caption] and each pose's name and line ("" = the game's choice).
const KINDS := [["outfit", "OUTFIT"], ["lobby", "LOBBY POSE"], ["victory", "VICTORY POSE"]]
const POSE_INFO := {
	"lobby": {"": ["RANDOM", "A different gesture now and then, as before."],
		"lobby_hip": ["HAND ON HIP", "Waits in the lobby with a hand on the hip."],
		"lobby_shift": ["WEIGHT SHIFT", "Shifts the weight from foot to foot."],
		"lobby_look": ["LOOK AROUND", "Looks round the yard now and then."]},
	"victory": {"": ["THE GAME'S CHOICE", "The results screen picks the pose."],
		"victory": ["CHEER", "Both arms up after a win."],
		"victory_pose": ["FIST UP", "A fist up, the other hand on the hip."]},
}
const POSE_SIZE := Vector2(258, 96)

var lobby: Lobby
## The wardrobe layer (node "Wardrobe") while it is open, else null.
var layer: Control
## The open category (a KINDS key).
var kind := "outfit"
## The outfit on the podium while the wardrobe is open (the selected card's).
var preview_bundle := ""
## The poses shown (tapped) in each pose category while the wardrobe is open.
var preview_pose := {"lobby": "", "victory": ""}
var _tabs: VBoxContainer
var _tag: Label
var _ward_grid: GridContainer
var _ward_scroll: ScrollContainer
var _ward_info_name: Label
var _ward_info_state: Label
var _ward_info_desc: Label
var _ward_equip: Button


func _init(owner_lobby: Lobby) -> void:
	lobby = owner_lobby


## The saved choice of a category (profile bundle, lobby_pose or victory_pose).
static func equipped(k: String) -> String:
	match k:
		"lobby":
			return String(Game.profile.get("lobby_pose", ""))
		"victory":
			return String(Game.profile.get("victory_pose", ""))
	return String(Game.profile.bundle)


## The item shown in a category now.
func previewed(k: String) -> String:
	return preview_bundle if k == "outfit" else String(preview_pose.get(k, ""))


## An outfit's accent colour (OUTFIT_COLORS; plain text colour for an unknown id).
static func outfit_color(id: String) -> Color:
	return OUTFIT_COLORS.get(id, UI.TEXT)


func open() -> void:
	if layer:
		return
	lobby.dialogs.close_modal()
	preview_bundle = String(Game.profile.bundle)
	preview_pose = {"lobby": equipped("lobby"), "victory": equipped("victory")}
	layer = Control.new()
	layer.name = "Wardrobe"
	UI.full_rect(layer)
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lobby.ui.add_child(layer)
	lobby._main_ui.visible = false
	var view := lobby._ward_view()
	lobby._move_camera(view[0], view[1])
	var shade := UI.gradient_rect([[0.0, Color(0.03, 0.03, 0.04, 0.94)], [0.5, Color(0.03, 0.03, 0.04, 0.88)], [0.66, Color(0, 0, 0, 0.0)], [1.0, Color(0, 0, 0, 0.0)]], true)
	UI.full_rect(shade)
	layer.add_child(shade)
	# The page frame's corner: the X (as BACK) and WARDROBE right-aligned beside it.
	var corner := UI.page_corner(layer, "WARDROBE", leave)
	(corner[0] as Button).name = "WardrobeClose"
	var note := UI.label("EVERYTHING IS FREE AND UNLOCKED", 15, UI.TEXT_DIM, "bold")
	note.position = Vector2(26, 22)
	note.custom_minimum_size = Vector2(0, 36)
	note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	layer.add_child(note)
	# The categories down the left.
	_tabs = VBoxContainer.new()
	_tabs.name = "WardTabs"
	_tabs.position = Vector2(26, 74)
	_tabs.add_theme_constant_override("separation", 8)
	layer.add_child(_tabs)
	for k: Array in KINDS:
		var tb := UI.side_tab(String(k[1]), k[0] == kind, 18, Vector2(150, 58))
		tb.name = "WardTab_" + String(k[0])
		tb.pressed.connect(show_kind.bind(String(k[0])))
		_tabs.add_child(tb)
	# Item grid with the item info strip under it.
	var col := VBoxContainer.new()
	col.anchor_bottom = 1.0
	col.offset_left = 26 + 150 + 12
	col.offset_right = col.offset_left + 3 * CARD_SIZE.x + 2 * 10
	col.offset_top = 74
	col.offset_bottom = -16
	col.add_theme_constant_override("separation", 10)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(col)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	_ward_scroll = scroll
	_ward_grid = GridContainer.new()
	_ward_grid.columns = 3
	_ward_grid.add_theme_constant_override("h_separation", 10)
	_ward_grid.add_theme_constant_override("v_separation", 10)
	scroll.add_child(_ward_grid)
	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 0)
	col.add_child(info)
	var ih := PanelContainer.new()
	ih.add_theme_stylebox_override("panel", UI.chamfer(Color(0.05, 0.42, 0.48, 0.95), 8, 0, Color.TRANSPARENT, 14.0, ["tl"]))
	var ihh := HBoxContainer.new()
	ihh.add_theme_constant_override("separation", 12)
	ihh.add_child(UI.icon("v_wardrobe", 24, UI.TEXT))
	_ward_info_name = UI.label("", 24, UI.TEXT, "bold")
	_ward_info_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ihh.add_child(_ward_info_name)
	_ward_info_state = UI.label("", 16, UI.ACCENT, "heavy")
	_ward_info_state.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	ihh.add_child(_ward_info_state)
	ih.add_child(ihh)
	info.add_child(ih)
	var ib := PanelContainer.new()
	ib.add_theme_stylebox_override("panel", UI.chamfer(Color(0.06, 0.06, 0.07, 0.9), 8, 0, Color.TRANSPARENT, 14.0, ["br"]))
	_ward_info_desc = UI.label("", 17, UI.TEXT, "semi")
	_ward_info_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ib.add_child(_ward_info_desc)
	info.add_child(ib)
	# EQUIP / BACK under the preview.
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	row.offset_left = -460
	row.offset_right = -20
	row.offset_top = -80
	row.offset_bottom = -14
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 14)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(row)
	var back := UI.button("BACK", 26, "light", Vector2(170, 64))
	back.name = "BackButton"
	back.pressed.connect(leave)
	row.add_child(back)
	_ward_equip = UI.hero_button("EQUIP", 38, Vector2(240, 64))
	_ward_equip.name = "EquipButton"
	_ward_equip.pressed.connect(equip)
	row.add_child(_ward_equip)
	# the shown item's name on a tag by the character (over EQUIP / BACK)
	_tag = UI.label("", 20, UI.TEXT, "heavy")
	_tag.name = "WardrobeTag"
	_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var tag_st := UI.chamfer(Color(0.03, 0.03, 0.035, 0.78), 8, 0, Color.TRANSPARENT, 14.0, ["tl", "br"])
	tag_st.border_width_bottom = 3
	_tag.add_theme_stylebox_override("normal", tag_st)
	_tag.anchor_left = Lobby.WARD_X
	_tag.anchor_right = Lobby.WARD_X
	_tag.anchor_top = 1.0
	_tag.anchor_bottom = 1.0
	_tag.offset_left = -150
	_tag.offset_right = 150
	_tag.offset_top = -140
	_tag.offset_bottom = -96
	layer.add_child(_tag)
	_fill_wardrobe()
	layer.modulate.a = 0.0
	layer.create_tween().tween_property(layer, "modulate:a", 1.0, 0.2)


## Another category: its items, the info strip and EQUIP follow.
func show_kind(k: String) -> void:
	kind = k
	if _tabs:
		for tb in _tabs.get_children():
			UI.style_side_tab(tb as Button, String(tb.name) == "WardTab_" + k)
	_fill_wardrobe()


## EQUIP: the shown item of the open category is saved (it stays on; EQUIP turns into EQUIPPED).
func equip() -> void:
	match kind:
		"outfit":
			Game.profile.bundle = preview_bundle
		"lobby":
			Game.profile.lobby_pose = previewed("lobby")
			lobby.model.pose_choice = previewed("lobby")
		"victory":
			Game.profile.victory_pose = previewed("victory")
	Game.save_profile()
	_update_ward_info()
	for other in _ward_grid.get_children():
		(other as Control).queue_redraw()


## X, BACK and Android back: closes; what was not equipped goes back to the saved choice.
func leave() -> void:
	close()


## The open category's items: every outfit in the game's order (the starter first), or the poses.
func _fill_wardrobe() -> void:
	for c in _ward_grid.get_children():
		_ward_grid.remove_child(c)
		c.queue_free()
	var group := ButtonGroup.new()
	if kind == "outfit":
		_ward_grid.columns = 3
		for b: Dictionary in CharacterModel.BUNDLE_INFO:
			_ward_grid.add_child(_bundle_card(b, group))
	else:
		_ward_grid.columns = 2
		for clip: String in (Game.LOBBY_POSES if kind == "lobby" else Game.VICTORY_POSES):
			_ward_grid.add_child(_pose_tile(kind, clip, group))
	UI.drag_scroll(_ward_scroll, _ward_grid)        # a drag that starts on a card scrolls the items
	_update_ward_info()


## A pose tile: its name and line; a tap plays it on the character.
func _pose_tile(k: String, clip: String, group: ButtonGroup) -> Button:
	var info: Array = (POSE_INFO[k] as Dictionary).get(clip, [clip.to_upper(), ""])
	var t := Button.new()
	t.name = "Pose_" + (clip if clip != "" else "random")
	t.toggle_mode = true
	t.button_group = group
	t.button_pressed = clip == previewed(k)
	t.focus_mode = Control.FOCUS_NONE
	t.custom_minimum_size = POSE_SIZE
	for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		t.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	t.draw.connect(func() -> void:
		var sz := t.size
		t.draw_colored_polygon(UI.chamfer_points(Rect2(Vector2.ZERO, sz), 10.0, ["br"]), Color(0.075, 0.072, 0.07, 0.97))
		HudDraw.text(t, String(info[0]), Vector2(16, 30), 22, UI.TEXT, 0, 0, "heavy")
		var line := String(info[1])
		HudDraw.text(t, line, Vector2(16, 62), 14, UI.TEXT_DIM, 0, 0, "semi")
		var on := clip == equipped(k)
		if on:
			t.draw_rect(Rect2(Vector2(1.5, 1.5), sz - Vector2(3, 3)), UI.ACCENT, false, 3.0)
			UI.draw_tick_corner(t, sz, 30.0)
		elif t.button_pressed:
			t.draw_rect(Rect2(Vector2(1.5, 1.5), sz - Vector2(3, 3)), Color(1, 1, 1, 0.95), false, 3.0)
		else:
			t.draw_rect(Rect2(Vector2(0.5, 0.5), sz - Vector2(1, 1)), Color(1, 1, 1, 0.1), false, 1.0))
	t.toggled.connect(func(_on: bool) -> void: t.queue_redraw())
	t.pressed.connect(func() -> void:
		Audio.play("ui_select", -6.0)
		preview_pose[k] = clip
		_play_pose(k, clip)
		_update_ward_info()
		for other in _ward_grid.get_children():
			(other as Control).queue_redraw())
	return t


## The pose on the character now ("" plays the lobby's own idle, or the cheer for VICTORY POSE).
func _play_pose(k: String, clip: String) -> void:
	var m := lobby.model
	if m == null:
		return
	if k == "victory":
		m.play_victory(clip if clip != "" else "victory_pose")
	elif clip != "" and m.anim and m.anim.has_animation(clip):
		m.play_lobby(true)
		m.anim.play(clip, 0.3)
	else:
		m.play_lobby(true)


func _bundle_card(b: Dictionary, group: ButtonGroup) -> Button:
	var id := String(b.id)
	var rc := outfit_color(id)
	var card := Button.new()
	card.name = "Bundle_" + id
	card.toggle_mode = true
	card.button_group = group
	card.button_pressed = id == preview_bundle
	card.focus_mode = Control.FOCUS_NONE
	card.custom_minimum_size = CARD_SIZE
	for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		card.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	var portrait := UI.texture("bundle_%s.png" % id)
	var glow := UI.radial_glow(Color(rc, 0.62))
	var floor_glow := UI.radial_glow(Color(rc.lightened(0.15), 0.5))
	card.draw.connect(func() -> void:
		var s := card.size
		card.draw_rect(Rect2(Vector2.ZERO, s), Color(0.075, 0.072, 0.07, 0.97))
		# the outfit's colour as a glow: a smooth radial gradient behind it, inside the card,
		# plus a brighter pool at the feet
		card.draw_texture_rect(glow, Rect2(0, 0, s.x, s.y - 46), false)
		card.draw_texture_rect(floor_glow, Rect2(s.x * 0.12, s.y * 0.62, s.x * 0.76, s.y * 0.2), false)
		card.draw_rect(Rect2(0, 0, s.x, s.y * 0.5), Color(1, 1, 1, 0.02))
		if portrait:
			var ph := s.y - 58
			var pw := ph * 0.75
			card.draw_texture_rect(portrait, Rect2((s.x - pw) * 0.5, 8, pw, ph), false)
		# name strip + the outfit's colour bar
		card.draw_rect(Rect2(0, s.y - 52, s.x, 48), Color(0, 0, 0, 0.6))
		card.draw_rect(Rect2(0, s.y - 5, s.x, 5), rc)
		# equipped: yellow outline + tick; previewed: white outline
		var worn := id == String(Game.profile.bundle)
		if worn:
			card.draw_rect(Rect2(Vector2(1.5, 1.5), s - Vector2(3, 3)), UI.ACCENT, false, 3.0)
			UI.draw_tick_corner(card, Vector2(s.x, s.y - 5), 34.0)
		if card.button_pressed and not worn:
			card.draw_rect(Rect2(Vector2(1.5, 1.5), s - Vector2(3, 3)), Color(1, 1, 1, 0.95), false, 3.0)
		elif card.is_hovered() and not worn:
			card.draw_rect(Rect2(Vector2(1, 1), s - Vector2(2, 2)), Color(1, 1, 1, 0.5), false, 2.0)
		elif not worn:
			card.draw_rect(Rect2(Vector2(0.5, 0.5), s - Vector2(1, 1)), Color(1, 1, 1, 0.1), false, 1.0))
	var nm := UI.ellipsis(UI.label(String(b.name), 18, UI.TEXT, "bold"))
	nm.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	nm.position = Vector2(9, CARD_SIZE.y - 52)
	nm.size = Vector2(CARD_SIZE.x - 18, 47)
	card.add_child(nm)
	card.mouse_entered.connect(card.queue_redraw)
	card.mouse_exited.connect(card.queue_redraw)
	card.toggled.connect(func(_on: bool) -> void: card.queue_redraw())
	card.pressed.connect(func() -> void:
		Audio.play("ui_select", -6.0)
		preview_bundle = id
		lobby.model.apply_bundle(id)
		_update_ward_info()
		for other in _ward_grid.get_children():
			(other as Control).queue_redraw())
	return card


func _update_ward_info() -> void:
	if _ward_info_name == null:
		return
	var shown := previewed(kind)
	var title := ""
	var desc := ""
	if kind == "outfit":
		var info := CharacterModel.bundle_info(shown)
		title = String(info.name)
		desc = String(info.desc)
	else:
		var pi: Array = (POSE_INFO[kind] as Dictionary).get(shown, [shown.to_upper(), ""])
		title = String(pi[0])
		desc = String(pi[1])
	_ward_info_name.text = title
	var on := shown == equipped(kind)
	_ward_info_state.text = "EQUIPPED" if on else ""
	_ward_info_desc.text = desc
	if _tag:
		_tag.text = title
		var st := _tag.get_theme_stylebox("normal") as StyleBoxFlat
		if st:
			st.border_color = outfit_color(shown) if kind == "outfit" else UI.ACCENT
	if _ward_equip:
		# the equipped item: a grey EQUIPPED that does nothing; another one: the yellow EQUIP
		UI.set_caption(_ward_equip, "EQUIPPED" if on else "EQUIP")
		_ward_equip.disabled = on
		_ward_equip.set_meta("style", "dark" if on else "primary")
		var cap := _ward_equip.get_node_or_null("Caption") as Label
		if cap:
			cap.add_theme_color_override("font_color", UI.TEXT_DIM if on else UI.INK)
		_ward_equip.queue_redraw()


func close() -> void:
	if layer:
		layer.queue_free()
		layer = null
		_ward_grid = null
		_ward_scroll = null
		_ward_info_name = null
		_ward_equip = null
		_tabs = null
		_tag = null
		# what was not equipped goes back: the saved outfit and the lobby's own pose
		var m := lobby.model
		if m:
			if m.bundle != String(Game.profile.bundle):
				m.apply_bundle(String(Game.profile.bundle))
			m.pose_choice = String(Game.profile.lobby_pose)
			m.play_lobby(true)
		preview_bundle = String(Game.profile.bundle)
		kind = "outfit"
	lobby._main_ui.visible = true
	var view := lobby._main_view()
	lobby._move_camera(view[0], view[1])


## Every frame: EQUIP is a hero button, which animates.
func process() -> void:
	if _ward_equip:
		_ward_equip.queue_redraw()

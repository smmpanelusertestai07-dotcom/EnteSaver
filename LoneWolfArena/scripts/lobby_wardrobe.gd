class_name LobbyWardrobe
extends RefCounted
## BUNDLES in the lobby: the wardrobe over the 3D stage (vault-like: rarity tabs, item cards with
## rarity glow and bar, the info strip, EQUIP / BACK) while the camera moves so the character
## stands on the right, wearing the outfit the selected card shows. The lobby makes it
## (Lobby.wardrobe_ui) and opens it from BUNDLES; back closes it there too.
## Node names used by the screenshot walkthrough: Wardrobe, Tab_<filter>, Bundle_<id>,
## EquipButton, BackButton.

const RARITY_ORDER := ["legendary", "epic", "rare", "common"]
const CARD_SIZE := Vector2(168, 222)

var lobby: Lobby
## The wardrobe layer (node "Wardrobe") while it is open, else null.
var layer: Control
## The outfit on the podium while the wardrobe is open (the selected card's).
var preview_bundle := ""
var _ward_grid: GridContainer
var _ward_filter := "all"
var _ward_info_name: Label
var _ward_info_rarity: Label
var _ward_info_desc: Label
var _ward_equip: Button
var _ward_tabs := {}


func _init(owner_lobby: Lobby) -> void:
	lobby = owner_lobby


func open() -> void:
	if layer:
		return
	lobby.dialogs.close_modal()
	preview_bundle = String(Game.profile.bundle)
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
	# Header.
	var head := HBoxContainer.new()
	head.position = Vector2(26, 16)
	head.add_theme_constant_override("separation", 16)
	layer.add_child(head)
	head.add_child(UI.section("BUNDLES", 30))
	var note := UI.label("ALL OUTFITS UNLOCKED  ·  OFFLINE", 15, UI.TEXT_DIM, "bold")
	note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	note.custom_minimum_size = Vector2(0, 36)
	head.add_child(note)
	# Rarity tabs (left).
	var tabs := VBoxContainer.new()
	tabs.position = Vector2(0, 76)
	tabs.add_theme_constant_override("separation", 4)
	layer.add_child(tabs)
	_ward_tabs.clear()
	for f in ["all", "legendary", "epic", "rare", "common"]:
		var tb := _ward_tab(f)
		tabs.add_child(tb)
		_ward_tabs[f] = tb
	# Item grid with the item info strip under it.
	var col := VBoxContainer.new()
	col.anchor_bottom = 1.0
	col.offset_left = 196
	col.offset_right = 196 + 3 * CARD_SIZE.x + 2 * 10
	col.offset_top = 74
	col.offset_bottom = -16
	col.add_theme_constant_override("separation", 10)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(col)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
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
	_ward_info_rarity = UI.label("", 16, UI.TEXT, "heavy")
	_ward_info_rarity.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	ihh.add_child(_ward_info_rarity)
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
	back.pressed.connect(func() -> void:
		lobby.model.apply_bundle(String(Game.profile.bundle))
		lobby._update_bundle_label(String(Game.profile.bundle))
		close())
	row.add_child(back)
	_ward_equip = UI.hero_button("EQUIP", 38, Vector2(240, 64))
	_ward_equip.name = "EquipButton"
	_ward_equip.pressed.connect(func() -> void:
		Game.profile.bundle = preview_bundle
		Game.save_profile()
		lobby._update_bundle_label(preview_bundle)
		close())
	row.add_child(_ward_equip)
	_fill_wardrobe()
	layer.modulate.a = 0.0
	layer.create_tween().tween_property(layer, "modulate:a", 1.0, 0.2)


func _ward_tab(f: String) -> Button:
	var b := Button.new()
	b.name = "Tab_" + f
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(190, 52)
	b.text = f.to_upper()
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.button_pressed = f == _ward_filter
	b.add_theme_font_override("font", UI.font("bold"))
	b.add_theme_font_size_override("font_size", 22)
	var normal := UI.box(Color(0, 0, 0, 0), 0, 0, Color.TRANSPARENT, 0.0)
	var hover := UI.box(Color(1, 1, 1, 0.06), 0, 0, Color.TRANSPARENT, 0.0)
	var on := UI.chamfer(UI.ACCENT, 12, 0, Color.TRANSPARENT, 0.0, ["br"])
	for st in [normal, hover, on]:
		st.content_margin_left = 30
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", on)
	b.add_theme_stylebox_override("hover_pressed", on)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("font_color", UI.TEXT if f == "all" else UI.RARITY_COLORS.get(f, UI.TEXT))
	b.add_theme_color_override("font_hover_color", UI.TEXT)
	b.add_theme_color_override("font_pressed_color", UI.INK)
	b.add_theme_color_override("font_hover_pressed_color", UI.INK)
	b.draw.connect(func() -> void:
		if b.button_pressed:
			UI.draw_tab_selected(b, b.size))
	b.pressed.connect(func() -> void:
		Audio.play("ui_select", -6.0)
		_ward_filter = f
		for k in _ward_tabs:
			(_ward_tabs[k] as Button).set_pressed_no_signal(k == f)
			(_ward_tabs[k] as Button).queue_redraw()
		_fill_wardrobe())
	return b


func _fill_wardrobe() -> void:
	for c in _ward_grid.get_children():
		_ward_grid.remove_child(c)
		c.queue_free()
	var group := ButtonGroup.new()
	var list := []
	for r in RARITY_ORDER:
		for b in CharacterModel.BUNDLE_INFO:
			if b.rarity == r and (_ward_filter == "all" or _ward_filter == r):
				list.append(b)
	# The info box and the podium follow the first card when the previewed one is filtered out.
	if not list.is_empty() and not list.any(func(b: Dictionary) -> bool: return String(b.id) == preview_bundle):
		preview_bundle = String(list[0].id)
		lobby.model.apply_bundle(preview_bundle)
		lobby._update_bundle_label(preview_bundle)
	for b in list:
		_ward_grid.add_child(_bundle_card(b, group))
	_update_ward_info()


func _bundle_card(b: Dictionary, group: ButtonGroup) -> Button:
	var id := String(b.id)
	var rc: Color = UI.RARITY_COLORS[b.rarity]
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
		# rarity glow: a smooth radial gradient behind the outfit, inside the card, plus a
		# brighter pool at the feet
		card.draw_texture_rect(glow, Rect2(0, 0, s.x, s.y - 46), false)
		card.draw_texture_rect(floor_glow, Rect2(s.x * 0.12, s.y * 0.62, s.x * 0.76, s.y * 0.2), false)
		card.draw_rect(Rect2(0, 0, s.x, s.y * 0.5), Color(1, 1, 1, 0.02))
		if portrait:
			var ph := s.y - 58
			var pw := ph * 0.75
			card.draw_texture_rect(portrait, Rect2((s.x - pw) * 0.5, 8, pw, ph), false)
		# name strip + rarity bar
		card.draw_rect(Rect2(0, s.y - 52, s.x, 48), Color(0, 0, 0, 0.6))
		card.draw_rect(Rect2(0, s.y - 5, s.x, 5), rc)
		# equipped: yellow outline + tick; previewed: white outline
		var equipped := id == String(Game.profile.bundle)
		if equipped:
			card.draw_rect(Rect2(Vector2(1.5, 1.5), s - Vector2(3, 3)), UI.ACCENT, false, 3.0)
			UI.draw_tick_corner(card, Vector2(s.x, s.y - 5), 34.0)
		if card.button_pressed and not equipped:
			card.draw_rect(Rect2(Vector2(1.5, 1.5), s - Vector2(3, 3)), Color(1, 1, 1, 0.95), false, 3.0)
		elif card.is_hovered() and not equipped:
			card.draw_rect(Rect2(Vector2(1, 1), s - Vector2(2, 2)), Color(1, 1, 1, 0.5), false, 2.0)
		elif not equipped:
			card.draw_rect(Rect2(Vector2(0.5, 0.5), s - Vector2(1, 1)), Color(1, 1, 1, 0.1), false, 1.0))
	var nm := UI.ellipsis(UI.label(String(b.name), 18, UI.TEXT, "bold"))
	nm.position = Vector2(9, CARD_SIZE.y - 50)
	nm.size = Vector2(CARD_SIZE.x - 18, 24)
	card.add_child(nm)
	var rl := UI.label(String(b.rarity).to_upper(), 14, rc, "bold")
	rl.position = Vector2(9, CARD_SIZE.y - 28)
	card.add_child(rl)
	card.mouse_entered.connect(card.queue_redraw)
	card.mouse_exited.connect(card.queue_redraw)
	card.toggled.connect(func(_on: bool) -> void: card.queue_redraw())
	card.pressed.connect(func() -> void:
		Audio.play("ui_select", -6.0)
		preview_bundle = id
		lobby.model.apply_bundle(id)
		lobby._update_bundle_label(id)
		_update_ward_info()
		for other in _ward_grid.get_children():
			(other as Control).queue_redraw())
	return card


func _update_ward_info() -> void:
	if _ward_info_name == null:
		return
	var info := CharacterModel.bundle_info(preview_bundle)
	_ward_info_name.text = String(info.name)
	_ward_info_rarity.text = String(info.rarity).to_upper()
	_ward_info_rarity.add_theme_color_override("font_color", UI.RARITY_COLORS[info.rarity].lightened(0.25))
	var equipped := preview_bundle == String(Game.profile.bundle)
	_ward_info_desc.text = String(info.desc) + ("   EQUIPPED" if equipped else "")
	if _ward_equip:
		UI.set_caption(_ward_equip, "EQUIPPED" if equipped else "EQUIP")


func close() -> void:
	if layer:
		layer.queue_free()
		layer = null
		_ward_grid = null
		_ward_info_name = null
		_ward_equip = null
	lobby._main_ui.visible = true
	var view := lobby._main_view()
	lobby._move_camera(view[0], view[1])


## Every frame: EQUIP is a hero button, which animates.
func process() -> void:
	if _ward_equip:
		_ward_equip.queue_redraw()

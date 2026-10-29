class_name CreditsPanel
extends CanvasLayer
## Credits and licences: what the game is made with and the notices their licences ask for
## (Godot's MIT licence and its third-party components, read from the engine itself; the
## CC0 character assets; the fonts' SIL Open Font Licence, shipped in assets/fonts/LICENSE.txt).

signal closed

const FONT_LICENCE := "res://assets/fonts/LICENSE.txt"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 60
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.72)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(shade)
	# Built like the lobby's popups: the header flush on top of a near-black body.
	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 0)
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.offset_left = 60
	frame.offset_right = -60
	frame.offset_top = 40
	frame.offset_bottom = -40
	root.add_child(frame)
	var head := UI.popup_header("CREDITS & LICENCES", 26, 54.0)
	frame.add_child(head)
	(head.get_node("Close") as Button).pressed.connect(func() -> void:
		closed.emit()
		queue_free())
	var panel := PanelContainer.new()
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var st := UI.box(Color(0.075, 0.072, 0.068, 0.97), 0, 0, Color.TRANSPARENT, 26.0)
	st.border_width_left = 1
	st.border_width_right = 1
	st.border_width_bottom = 1
	st.border_color = Color(1, 1, 1, 0.1)
	st.content_margin_top = 18
	st.content_margin_bottom = 22
	panel.add_theme_stylebox_override("panel", st)
	panel.draw.connect(func() -> void:
		var s := panel.size
		panel.draw_colored_polygon(PackedVector2Array([Vector2(s.x, s.y - 18), Vector2(s.x, s.y), Vector2(s.x - 18, s.y)]), UI.ACCENT))
	frame.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	var text := Label.new()
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_font_override("font", UI.font("semi"))
	text.add_theme_font_size_override("font_size", 17)
	text.add_theme_color_override("font_color", UI.TEXT_DIM)
	text.text = credits_text()
	scroll.add_child(text)


static func credits_text() -> String:
	var out := PackedStringArray()
	out.append("LONE WOLF ARENA - an original offline game. Everything in it (character outfits and animations, guns, map, icons, sounds and music) was made for this game with the scripts in its source, except the parts credited below.")
	out.append("")
	out.append("CHARACTER - base body, skin, hair and clothes from the MakeHuman / MPFB2 asset packs, CC0 1.0 (public domain dedication), assembled, recoloured, rigged and animated for this game.")
	out.append("")
	out.append("FONTS - Rajdhani, Teko, Bebas Neue: SIL Open Font License 1.1.")
	if FileAccess.file_exists(FONT_LICENCE):
		out.append(FileAccess.get_file_as_string(FONT_LICENCE).strip_edges())
	out.append("")
	out.append("ENGINE - made with Godot Engine (godotengine.org).")
	out.append(Engine.get_license_text().strip_edges())
	out.append("")
	out.append("GODOT THIRD-PARTY COMPONENTS")
	for comp: Dictionary in Engine.get_copyright_info():
		var parts: Array = comp.get("parts", [])
		for part: Dictionary in parts:
			var who := PackedStringArray()
			for c in part.get("copyright", []):
				who.append(String(c))
			out.append("%s - %s (%s)" % [comp.get("name", ""), ", ".join(who), part.get("license", "")])
	out.append("")
	out.append("LICENCE TEXTS")
	var lic: Dictionary = Engine.get_license_info()
	for name in lic:
		out.append(String(name))
		out.append(String(lic[name]).strip_edges())
		out.append("")
	return "\n".join(out)

class_name UI
extends RefCounted
## Shared UI styling helpers (battle-royale look: dark translucent panels, amber accents).

const ACCENT := Color(1.0, 0.74, 0.16)
const ACCENT_DARK := Color(0.86, 0.52, 0.05)
const INK := Color(0.1, 0.07, 0.02)
const PANEL := Color(0.05, 0.06, 0.08, 0.88)
const PANEL_2 := Color(0.12, 0.13, 0.17, 0.94)
const LINE := Color(1, 1, 1, 0.12)
const TEXT := Color(0.96, 0.97, 1.0)
const TEXT_DIM := Color(0.66, 0.70, 0.78)
const GOOD := Color(0.35, 0.92, 0.45)
const BAD := Color(1.0, 0.32, 0.3)
const RARITY_COLORS := {
	"common": Color(0.62, 0.67, 0.74),
	"rare": Color(0.25, 0.6, 1.0),
	"epic": Color(0.72, 0.38, 1.0),
	"legendary": Color(1.0, 0.66, 0.12),
}
const FONT_FILES := {
	"bold": "res://assets/fonts/ui_bold",
	"semi": "res://assets/fonts/ui_semibold",
	"title": "res://assets/fonts/title",
	"number": "res://assets/fonts/number",
}

static var _fonts := {}


static func font(kind := "bold") -> Font:
	if _fonts.has(kind):
		return _fonts[kind]
	var f: Font = null
	var base: String = FONT_FILES.get(kind, "")
	for ext in [".ttf", ".otf", ".woff2", ".woff"]:
		if base != "" and ResourceLoader.exists(base + ext):
			f = load(base + ext)
			break
	if f == null and kind != "bold":
		f = font("bold")
	if f == null:
		f = ThemeDB.fallback_font
	_fonts[kind] = f
	return f


static func box(color: Color, radius := 8, border := 0, border_color := Color(1, 1, 1, 0.15), margin := 12.0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(radius)
	if border > 0:
		s.set_border_width_all(border)
		s.border_color = border_color
	s.content_margin_left = margin
	s.content_margin_right = margin
	s.content_margin_top = margin * 0.6
	s.content_margin_bottom = margin * 0.6
	s.anti_aliasing = true
	return s


static func label(text: String, size := 22, color := TEXT, kind := "bold") -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font(kind))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


static func outlined(l: Label, size := 5, color := Color(0, 0, 0, 0.8)) -> Label:
	l.add_theme_constant_override("outline_size", size)
	l.add_theme_color_override("font_outline_color", color)
	return l


static func button(text: String, size := 22, style := "dark", min_size := Vector2(0, 54)) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = min_size
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_override("font", font("bold"))
	b.add_theme_font_size_override("font_size", size)
	var base: Color
	var fg: Color = TEXT
	match style:
		"primary":
			base = ACCENT
			fg = INK
		"danger":
			base = Color(0.82, 0.2, 0.2)
		"ghost":
			base = Color(1, 1, 1, 0.07)
		_:
			base = PANEL_2
	for st in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(st, fg)
	b.add_theme_color_override("font_disabled_color", Color(fg, 0.4))
	b.add_theme_stylebox_override("normal", box(base, 8, 1, Color(1, 1, 1, 0.12)))
	b.add_theme_stylebox_override("hover", box(base.lightened(0.08), 8, 1, Color(1, 1, 1, 0.22)))
	b.add_theme_stylebox_override("pressed", box(base.darkened(0.18), 8, 1, Color(1, 1, 1, 0.25)))
	b.add_theme_stylebox_override("disabled", box(Color(base, base.a * 0.45), 8))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.pressed.connect(func() -> void: Audio.play("ui_click", -4.0))
	return b


static func segmented(options: Array, selected: int, on_change: Callable, size := 18, min_w := 92.0) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	var group := ButtonGroup.new()
	for i in options.size():
		var b := Button.new()
		b.text = str(options[i])
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = i == selected
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(min_w, 46)
		b.add_theme_font_override("font", font("bold"))
		b.add_theme_font_size_override("font_size", size)
		b.add_theme_stylebox_override("normal", box(Color(1, 1, 1, 0.07), 6))
		b.add_theme_stylebox_override("hover", box(Color(1, 1, 1, 0.13), 6))
		b.add_theme_stylebox_override("pressed", box(ACCENT, 6))
		b.add_theme_stylebox_override("hover_pressed", box(ACCENT.lightened(0.1), 6))
		b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		b.add_theme_color_override("font_color", TEXT)
		b.add_theme_color_override("font_hover_color", TEXT)
		b.add_theme_color_override("font_pressed_color", INK)
		b.add_theme_color_override("font_hover_pressed_color", INK)
		var idx := i
		b.pressed.connect(func() -> void:
			Audio.play("ui_select", -6.0)
			on_change.call(idx))
		h.add_child(b)
	return h


static func slider(value: float, min_v: float, max_v: float, on_change: Callable) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	var s := HSlider.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = 1
	s.value = value
	s.custom_minimum_size = Vector2(280, 44)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.focus_mode = Control.FOCUS_NONE
	var track := box(Color(1, 1, 1, 0.13), 4, 0, Color.TRANSPARENT, 0.0)
	track.content_margin_top = 4
	track.content_margin_bottom = 4
	var fill := box(ACCENT, 4, 0, Color.TRANSPARENT, 0.0)
	fill.content_margin_top = 4
	fill.content_margin_bottom = 4
	s.add_theme_stylebox_override("slider", track)
	s.add_theme_stylebox_override("grabber_area", fill)
	s.add_theme_stylebox_override("grabber_area_highlight", fill)
	s.add_theme_icon_override("grabber", _knob_texture(Color.WHITE))
	s.add_theme_icon_override("grabber_highlight", _knob_texture(ACCENT.lightened(0.4)))
	var v := label(str(int(value)), 22, ACCENT)
	v.custom_minimum_size = Vector2(54, 0)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	s.value_changed.connect(func(val: float) -> void:
		v.text = str(int(val))
		on_change.call(val))
	h.add_child(s)
	h.add_child(v)
	return h


static var _knobs := {}


static func _knob_texture(c: Color) -> Texture2D:
	var key := c.to_html()
	if _knobs.has(key):
		return _knobs[key]
	var size := 30
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var r := size * 0.5 - 1.0
	for y in size:
		for x in size:
			var d := Vector2(x + 0.5 - size * 0.5, y + 0.5 - size * 0.5).length()
			var a := clampf(r - d + 0.5, 0.0, 1.0)
			img.set_pixel(x, y, Color(c, a))
	var tex := ImageTexture.create_from_image(img)
	_knobs[key] = tex
	return tex


static func row(title: String, control: Control, title_w := 270.0) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 16)
	var l := label(title, 21, TEXT, "semi")
	l.custom_minimum_size = Vector2(title_w, 0)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(l)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(control)
	return h


static func panel(color := PANEL, radius := 14, border := 1) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", box(color, radius, border, Color(1, 1, 1, 0.1), 18.0))
	return p


static func spacer(h := 8.0) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func full_rect(c: Control) -> Control:
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return c

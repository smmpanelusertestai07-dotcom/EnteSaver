class_name UI
extends RefCounted
## Shared UI kit (original art in a battle-royale menu language): near-black translucent panels,
## chamfered and slanted shapes, a thin yellow bar before section headers, yellow main buttons
## with black heavy condensed text, light-grey secondary buttons, yellow outline + tick for the
## selection, bold condensed caps. Everything is drawn with StyleBoxFlat / polygons (no image
## skins), so it scales to any screen. Textures (icons, key art) are loaded once and cached.

const ACCENT := Color(1.0, 0.76, 0.055)           # main yellow (#FFC20E)
const ACCENT_DARK := Color(0.86, 0.56, 0.0)
const GOLD := Color(0.965, 0.71, 0.0)             # victory gold
const AMBER := Color(0.89, 0.667, 0.16)           # casual mode names
const BLUE := Color(0.106, 0.569, 0.851)          # own side
const ORANGE := Color(0.875, 0.447, 0.216)        # enemy side
const INK := Color(0.07, 0.065, 0.05)             # text on yellow / light buttons
const PANEL := Color(0.075, 0.07, 0.065, 0.88)    # near-black translucent panels
const PANEL_2 := Color(0.19, 0.185, 0.176, 0.94)  # cards inside panels
const ROW := Color(1, 1, 1, 0.045)                # setting rows on a panel
const LIGHT := Color(0.851, 0.847, 0.839)         # secondary buttons (#D9D8D6)
const LINE := Color(1, 1, 1, 0.12)
const TEXT := Color(0.97, 0.97, 0.96)
const TEXT_DIM := Color(0.64, 0.64, 0.66)
const GOOD := Color(0.36, 0.86, 0.42)
const BAD := Color(0.95, 0.30, 0.24)
const RARITY_COLORS := {
	"common": Color(0.62, 0.63, 0.65),
	"rare": Color(0.20, 0.58, 1.0),
	"epic": Color(0.66, 0.30, 1.0),
	"legendary": Color(1.0, 0.74, 0.18),
}
const FONT_FILES := {
	"bold": "res://assets/fonts/ui_bold",
	"semi": "res://assets/fonts/ui_semibold",
	"title": "res://assets/fonts/title",
	"number": "res://assets/fonts/number",
}
const ICON_DIR := "res://assets/ui/icons/"
const ART_DIR := "res://assets/ui/"

static var _fonts := {}
static var _textures := {}


## Fonts: "bold" / "semi" (UI text), "title" (condensed caps), "number" (digits) and the derived
## "heavy" (emboldened title: main buttons), "italic" (heavy + slant: banners) and
## "number_italic" (slanted digits).
static func font(kind := "bold") -> Font:
	if _fonts.has(kind):
		return _fonts[kind]
	var f: Font = null
	match kind:
		"heavy", "italic", "number_italic":
			var fv := FontVariation.new()
			fv.base_font = font("number" if kind == "number_italic" else "title")
			fv.variation_embolden = 0.5 if kind != "number_italic" else 0.3
			if kind != "heavy":
				# slant (Godot's documented italic: Transform2D(1, slant, 0, 1, 0, 0))
				fv.variation_transform = Transform2D(Vector2(1.0, 0.2), Vector2(0.0, 1.0), Vector2.ZERO)
			f = fv
		_:
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


## A texture from assets/ui/ (key art, logo, portraits) or its icons/ folder, loaded once;
## null when missing (callers fall back to drawn shapes).
static func texture(path: String) -> Texture2D:
	if _textures.has(path):
		return _textures[path]
	var full := path if path.begins_with("res://") else ART_DIR + path
	var t: Texture2D = load(full) if ResourceLoader.exists(full) else null
	_textures[path] = t
	return t


static func icon_texture(icon_name: String) -> Texture2D:
	return texture(ICON_DIR + icon_name + ".png")


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


## Chamfered box: straight 45-degree cuts of `cut` px on the given corners ("tl", "tr", "br",
## "bl"; default top-left + bottom-right like the main buttons), optional border and skew
## (x shift of the top edge relative to the bottom, as a fraction of the height).
static func chamfer(color: Color, cut := 10, border := 0, border_color := Color(1, 1, 1, 0.15),
		margin := 12.0, corners := ["tl", "br"], skew := 0.0) -> StyleBoxFlat:
	var s := box(color, 0, border, border_color, margin)
	s.corner_detail = 1
	s.corner_radius_top_left = cut if "tl" in corners else 0
	s.corner_radius_top_right = cut if "tr" in corners else 0
	s.corner_radius_bottom_right = cut if "br" in corners else 0
	s.corner_radius_bottom_left = cut if "bl" in corners else 0
	if skew != 0.0:
		s.skew = Vector2(skew, 0)
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


## Drop shadow under a label's glyphs (big titles over art).
static func shadowed(l: Label, offset := Vector2(0, 3), color := Color(0, 0, 0, 0.55)) -> Label:
	l.add_theme_color_override("font_shadow_color", color)
	l.add_theme_constant_override("shadow_offset_x", int(offset.x))
	l.add_theme_constant_override("shadow_offset_y", int(offset.y))
	return l


## Buttons. style: "primary" (yellow, black heavy text), "light" (light grey, dark text),
## "dark" (near-black translucent, white text), "ghost" (outline only), "danger" (red).
static func button(text: String, size := 22, style := "dark", min_size := Vector2(0, 54)) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = min_size
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_override("font", font("heavy" if style in ["primary", "light"] else "bold"))
	b.add_theme_font_size_override("font_size", size + (4 if style in ["primary", "light"] else 0))
	var base: Color
	var fg: Color = TEXT
	var border := 0
	var border_col := Color(1, 1, 1, 0.14)
	match style:
		"primary":
			base = ACCENT
			fg = INK
		"light":
			base = LIGHT
			fg = INK
		"danger":
			base = Color(0.80, 0.22, 0.17)
		"ghost":
			base = Color(1, 1, 1, 0.05)
			border = 1
			border_col = Color(1, 1, 1, 0.3)
		_:
			base = Color(0.12, 0.115, 0.11, 0.9)
			border = 1
	for st in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(st, fg)
	b.add_theme_color_override("font_disabled_color", Color(fg, 0.45))
	var cut := clampi(int(min_size.y * 0.2), 6, 14)
	var normal := chamfer(base, cut, border, border_col)
	if style in ["primary", "light"]:
		normal.border_width_bottom = 3
		normal.border_color = base.darkened(0.28)
	b.add_theme_stylebox_override("normal", normal)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = base.lightened(0.08)
	b.add_theme_stylebox_override("hover", hover)
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = base.darkened(0.16)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("hover_pressed", pressed)
	var disabled := normal.duplicate() as StyleBoxFlat
	disabled.bg_color = Color(base.darkened(0.35), base.a * 0.6)
	b.add_theme_stylebox_override("disabled", disabled)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.pressed.connect(func() -> void: Audio.play("ui_click", -4.0))
	return b


## The big call-to-action button (START, PLAY AGAIN, EQUIP): chamfered yellow slab with a
## vertical gradient, a glossy diagonal highlight, dark chevrons on the right and a light sweep
## that crosses it every few seconds. The caption is a child Label named "Caption".
static func hero_button(text: String, size := 44, min_size := Vector2(300, 80), style := "primary") -> Button:
	var b := Button.new()
	b.custom_minimum_size = min_size
	b.focus_mode = Control.FOCUS_NONE
	for st in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		b.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	b.set_meta("style", style)
	b.set_meta("t0", Time.get_ticks_msec() / 1000.0)
	var cap := label(text, size, INK if style != "dark" else TEXT, "heavy")
	cap.name = "Caption"
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cap.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cap.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cap.offset_right = -min_size.y * 0.25
	b.add_child(cap)
	b.draw.connect(func() -> void: _draw_hero(b))
	b.pressed.connect(func() -> void: Audio.play("ui_select", -2.0))
	return b


static func set_caption(b: Button, text: String) -> void:
	var cap := b.get_node_or_null("Caption") as Label
	if cap:
		cap.text = text


static func _draw_hero(b: Button) -> void:
	var r := Rect2(Vector2.ZERO, b.size)
	var style := String(b.get_meta("style", "primary"))
	var cut := minf(r.size.y * 0.24, 22.0)
	var top := Color(1.0, 0.88, 0.30)
	var bottom := Color(1.0, 0.72, 0.0)
	if style == "light":
		top = Color(0.93, 0.93, 0.92)
		bottom = LIGHT.darkened(0.06)
	elif style == "dark":
		top = Color(0.2, 0.19, 0.18, 0.95)
		bottom = Color(0.1, 0.095, 0.09, 0.95)
	if b.disabled:
		top = top.darkened(0.35)
		bottom = bottom.darkened(0.35)
	elif b.button_pressed or b.is_pressed():
		top = top.darkened(0.12)
		bottom = bottom.darkened(0.12)
	var pts := chamfer_points(r, cut, ["tl", "br"])
	var cols := PackedColorArray()
	for p in pts:
		cols.append(top.lerp(bottom, p.y / maxf(r.size.y, 1.0)))
	b.draw_polygon(pts, cols)
	# darker lower lip
	var lip := Rect2(r.position.x, r.end.y - 4.0, r.size.x - cut, 4.0)
	b.draw_rect(lip, Color(0, 0, 0, 0.12))
	# glossy diagonal highlight across the upper-left
	var g := PackedVector2Array([Vector2(cut, 0), Vector2(r.size.x * 0.52, 0), Vector2(r.size.x * 0.40, r.size.y * 0.48),
		Vector2(0, r.size.y * 0.48), Vector2(0, cut)])
	b.draw_colored_polygon(g, Color(1, 1, 1, 0.16 if style != "dark" else 0.05))
	# chevrons on the right
	var ink := Color(0, 0, 0, 0.16) if style != "dark" else Color(1, 1, 1, 0.12)
	var h := r.size.y
	for i in 3:
		var x0 := r.size.x - h * 0.95 + i * h * 0.2
		var chev := PackedVector2Array([Vector2(x0, h * 0.24), Vector2(x0 + h * 0.1, h * 0.24), Vector2(x0 + h * 0.3, h * 0.5),
			Vector2(x0 + h * 0.1, h * 0.76), Vector2(x0, h * 0.76), Vector2(x0 + h * 0.2, h * 0.5)])
		b.draw_colored_polygon(chev, ink)
	# a light sweep every 3.2 s (only while enabled)
	if not b.disabled and style != "dark":
		var t := fmod(Time.get_ticks_msec() / 1000.0 - float(b.get_meta("t0", 0.0)), 3.2) / 1.1
		if t < 1.0:
			var x := lerpf(-h, r.size.x + h, t)
			var sweep := PackedVector2Array([Vector2(x, 0), Vector2(x + h * 0.35, 0), Vector2(x + h * 0.05, h), Vector2(x - h * 0.3, h)])
			var clipped := Geometry2D.intersect_polygons(sweep, pts)
			for poly in clipped:
				b.draw_colored_polygon(poly, Color(1, 1, 1, 0.28))
	# outline
	var outline := pts.duplicate()
	outline.append(pts[0])
	b.draw_polyline(outline, Color(0, 0, 0, 0.35) if style != "dark" else Color(1, 1, 1, 0.25), 1.5, true)


## Corner points of a chamfered rectangle (clockwise from the top-left).
static func chamfer_points(r: Rect2, cut: float, corners := ["tl", "br"]) -> PackedVector2Array:
	var p := PackedVector2Array()
	var a := r.position
	var e := r.end
	if "tl" in corners:
		p.append(Vector2(a.x, a.y + cut))
		p.append(Vector2(a.x + cut, a.y))
	else:
		p.append(a)
	if "tr" in corners:
		p.append(Vector2(e.x - cut, a.y))
		p.append(Vector2(e.x, a.y + cut))
	else:
		p.append(Vector2(e.x, a.y))
	if "br" in corners:
		p.append(Vector2(e.x, e.y - cut))
		p.append(Vector2(e.x - cut, e.y))
	else:
		p.append(e)
	if "bl" in corners:
		p.append(Vector2(a.x + cut, e.y))
		p.append(Vector2(a.x, e.y - cut))
	else:
		p.append(Vector2(a.x, e.y))
	return p


## Segmented choice (reference settings look): a dark strip with a thin border; the selected
## option is a light slab with dark text.
static func segmented(options: Array, selected: int, on_change: Callable, size := 18, min_w := 92.0) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 2)
	var group := ButtonGroup.new()
	for i in options.size():
		var b := Button.new()
		b.text = str(options[i])
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = i == selected
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(min_w, 42)
		b.clip_text = true
		b.add_theme_font_override("font", font("bold"))
		b.add_theme_font_size_override("font_size", size)
		var first := i == 0
		var last := i == options.size() - 1
		var normal := chamfer(Color(0, 0, 0, 0.35), 6, 1, Color(1, 1, 1, 0.22), 8.0,
			(["tl"] if first else []) + (["br"] if last else []))
		var hover := normal.duplicate() as StyleBoxFlat
		hover.bg_color = Color(1, 1, 1, 0.08)
		var on := chamfer(LIGHT, 6, 1, LIGHT, 8.0, (["tl"] if first else []) + (["br"] if last else []))
		b.add_theme_stylebox_override("normal", normal)
		b.add_theme_stylebox_override("hover", hover)
		b.add_theme_stylebox_override("pressed", on)
		b.add_theme_stylebox_override("hover_pressed", on)
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
	var s := styled_slider(value, min_v, max_v)
	s.custom_minimum_size = Vector2(280, 44)
	var v := label(str(int(value)), 22, ACCENT, "number")
	v.custom_minimum_size = Vector2(54, 0)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	s.value_changed.connect(func(val: float) -> void:
		v.text = str(int(val))
		on_change.call(val))
	h.add_child(s)
	h.add_child(v)
	return h


## HSlider in the kit's look: dark track, yellow fill, white grip.
static func styled_slider(value: float, min_v: float, max_v: float) -> HSlider:
	var s := HSlider.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = 1
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.focus_mode = Control.FOCUS_NONE
	var track := box(Color(1, 1, 1, 0.16), 2, 0, Color.TRANSPARENT, 0.0)
	track.content_margin_top = 3
	track.content_margin_bottom = 3
	var fill := box(ACCENT, 2, 0, Color.TRANSPARENT, 0.0)
	fill.content_margin_top = 3
	fill.content_margin_bottom = 3
	s.add_theme_stylebox_override("slider", track)
	s.add_theme_stylebox_override("grabber_area", fill)
	s.add_theme_stylebox_override("grabber_area_highlight", fill)
	s.add_theme_icon_override("grabber", _knob_texture(Color.WHITE))
	s.add_theme_icon_override("grabber_highlight", _knob_texture(Color(1, 0.95, 0.8)))
	return s


## Value, [-], slider, [+] in one row (the sensitivity rows). The slider is the "slider" meta of
## the returned box so presets can move it.
static func stepper(value: float, min_v: float, max_v: float, on_change: Callable, step := 1.0) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	var v := label(str(int(value)), 24, TEXT, "number")
	v.custom_minimum_size = Vector2(52, 0)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var s := styled_slider(value, min_v, max_v)
	s.custom_minimum_size = Vector2(200, 40)
	var minus := _step_button("-")
	var plus := _step_button("+")
	minus.pressed.connect(func() -> void: s.value = clampf(s.value - step, min_v, max_v))
	plus.pressed.connect(func() -> void: s.value = clampf(s.value + step, min_v, max_v))
	s.value_changed.connect(func(val: float) -> void:
		v.text = str(int(val))
		on_change.call(val))
	h.add_child(v)
	h.add_child(minus)
	h.add_child(s)
	h.add_child(plus)
	h.set_meta("slider", s)
	return h


static func _step_button(t: String) -> Button:
	var b := Button.new()
	b.text = t
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(40, 36)
	b.add_theme_font_override("font", font("bold"))
	b.add_theme_font_size_override("font_size", 26)
	var st := box(Color(0.88, 0.88, 0.87), 2, 0, Color.TRANSPARENT, 0.0)
	var hv := box(Color(1, 1, 1), 2, 0, Color.TRANSPARENT, 0.0)
	var pr := box(ACCENT, 2, 0, Color.TRANSPARENT, 0.0)
	b.add_theme_stylebox_override("normal", st)
	b.add_theme_stylebox_override("hover", hv)
	b.add_theme_stylebox_override("pressed", pr)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	for c in ["font_color", "font_hover_color", "font_pressed_color"]:
		b.add_theme_color_override(c, INK)
	b.pressed.connect(func() -> void: Audio.play("ui_click", -8.0))
	return b


static var _knobs := {}


## Slider grip: a white rounded slab with two grip lines (cached per colour).
static func _knob_texture(c: Color) -> Texture2D:
	var key := c.to_html()
	if _knobs.has(key):
		return _knobs[key]
	var w := 16
	var hh := 30
	var img := Image.create(w, hh, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in hh:
		for x in w:
			var inside := x >= 1 and x <= w - 2 and y >= 2 and y <= hh - 3
			var edge := (x == 1 or x == w - 2) and (y == 2 or y == hh - 3)
			if inside and not edge:
				var col := c
				if (y == hh / 2 - 3 or y == hh / 2 + 2) and x >= 4 and x <= w - 5:
					col = Color(0.45, 0.45, 0.45)
				img.set_pixel(x, y, col)
			elif inside:
				img.set_pixel(x, y, Color(c, 0.5))
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


## A setting row on its own dark plate: title (and an optional dim note under it) on the
## left, the control on the right.
static func plate_row(title: String, control: Control, note := "", title_w := 300.0) -> PanelContainer:
	var p := PanelContainer.new()
	var st := chamfer(ROW, 6, 0, Color.TRANSPARENT, 14.0, ["br"])
	st.content_margin_top = 6
	st.content_margin_bottom = 6
	p.add_theme_stylebox_override("panel", st)
	p.custom_minimum_size = Vector2(0, 54)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 16)
	p.add_child(h)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", -2)
	v.custom_minimum_size = Vector2(title_w, 0)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.size_flags_vertical = Control.SIZE_FILL
	v.add_child(label(title, 21, TEXT, "bold"))
	if note != "":
		var n := label(note, 15, TEXT_DIM, "semi")
		n.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		n.custom_minimum_size = Vector2(title_w, 0)
		v.add_child(n)
	h.add_child(v)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(control)
	return p


## Section header: a thin yellow bar, then the title in white bold caps.
static func section(title: String, size := 20) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	var bar := ColorRect.new()
	bar.color = ACCENT
	bar.custom_minimum_size = Vector2(4, size * 0.95)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(bar)
	var l := label(title.to_upper(), size, TEXT, "bold")
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(l)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return h


static func panel(color := PANEL, radius := 14, border := 1) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", chamfer(color, clampi(radius, 4, 18), border, Color(1, 1, 1, 0.1), 18.0))
	return p


static func spacer(h := 8.0) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func full_rect(c: Control) -> Control:
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return c


## Thin scrollbar in the kit's look (dark track, light grip that turns yellow when dragged).
static func style_scroll(sc: ScrollContainer) -> void:
	var bar := sc.get_v_scroll_bar()
	var track := box(Color(1, 1, 1, 0.06), 2, 0, Color.TRANSPARENT, 0.0)
	track.content_margin_left = 3
	track.content_margin_right = 3
	var grip := box(Color(1, 1, 1, 0.35), 2, 0, Color.TRANSPARENT, 0.0)
	var grip_hi := box(Color(1, 1, 1, 0.55), 2, 0, Color.TRANSPARENT, 0.0)
	var grip_on := box(ACCENT, 2, 0, Color.TRANSPARENT, 0.0)
	bar.add_theme_stylebox_override("scroll", track)
	bar.add_theme_stylebox_override("scroll_focus", track)
	bar.add_theme_stylebox_override("grabber", grip)
	bar.add_theme_stylebox_override("grabber_highlight", grip_hi)
	bar.add_theme_stylebox_override("grabber_pressed", grip_on)
	bar.custom_minimum_size = Vector2(8, 0)


## A white glyph from assets/ui/icons/ (tinted), fitted into `size` px.
static func icon(icon_name: String, size := 28.0, tint := TEXT) -> TextureRect:
	var t := TextureRect.new()
	t.texture = icon_texture(icon_name)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.custom_minimum_size = Vector2(size, size)
	t.modulate = tint
	t.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return t


## A small square glyph button (top-bar settings, close): dark translucent tile, white glyph;
## falls back to `fallback_text` when the icon file is missing.
static func glyph_button(icon_name: String, size := 48.0, fallback_text := "") -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(size, size)
	b.focus_mode = Control.FOCUS_NONE
	var tex := icon_texture(icon_name)
	if tex:
		b.icon = tex
		b.expand_icon = true
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.add_theme_constant_override("icon_max_width", int(size * 0.62))
	else:
		b.text = fallback_text
		b.add_theme_font_override("font", font("bold"))
		b.add_theme_font_size_override("font_size", int(size * 0.42))
	var st := chamfer(Color(0, 0, 0, 0.45), 6, 1, Color(1, 1, 1, 0.16), 6.0, ["br"])
	var hv := chamfer(Color(1, 1, 1, 0.12), 6, 1, Color(1, 1, 1, 0.3), 6.0, ["br"])
	var pr := chamfer(Color(ACCENT, 0.35), 6, 1, ACCENT, 6.0, ["br"])
	b.add_theme_stylebox_override("normal", st)
	b.add_theme_stylebox_override("hover", hv)
	b.add_theme_stylebox_override("pressed", pr)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("icon_normal_color", TEXT)
	b.add_theme_color_override("icon_hover_color", Color.WHITE)
	b.add_theme_color_override("icon_pressed_color", ACCENT)
	b.pressed.connect(func() -> void: Audio.play("ui_click", -4.0))
	return b


## Close button: a square tile with a drawn X (node name "Close" is set by the caller).
static func close_button(size := 52.0) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(size, size)
	b.focus_mode = Control.FOCUS_NONE
	var st := chamfer(Color(0, 0, 0, 0.5), 8, 1, Color(1, 1, 1, 0.2), 0.0, ["bl"])
	var hv := chamfer(Color(1, 1, 1, 0.12), 8, 1, Color(1, 1, 1, 0.35), 0.0, ["bl"])
	var pr := chamfer(Color(ACCENT, 0.4), 8, 1, ACCENT, 0.0, ["bl"])
	b.add_theme_stylebox_override("normal", st)
	b.add_theme_stylebox_override("hover", hv)
	b.add_theme_stylebox_override("pressed", pr)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.draw.connect(func() -> void:
		var c := b.size * 0.5
		var r := b.size.x * 0.22
		b.draw_line(c - Vector2(r, r), c + Vector2(r, r), TEXT, 3.0, true)
		b.draw_line(c + Vector2(-r, r), c + Vector2(r, -r), TEXT, 3.0, true))
	b.pressed.connect(func() -> void: Audio.play("ui_back", -4.0))
	return b


## Yellow corner triangle with a black tick (selected / equipped marker) for a card of
## `card_size`, placed in its bottom-right corner.
static func draw_tick_corner(ci: CanvasItem, card_size: Vector2, s := 30.0) -> void:
	var e := card_size
	ci.draw_colored_polygon(PackedVector2Array([Vector2(e.x, e.y - s), e, Vector2(e.x - s, e.y)]), ACCENT)
	var a := Vector2(e.x - s * 0.40, e.y - s * 0.22)
	ci.draw_polyline(PackedVector2Array([a + Vector2(-s * 0.16, -s * 0.14), a, a + Vector2(s * 0.26, -s * 0.34)]), INK, maxf(2.0, s * 0.08), true)


## Hazard stripes filling `r`, slanted like the rest of the kit: `col` stripes over `bg` (dark
## by default; Color.TRANSPARENT stripes straight onto what is below, e.g. black on a yellow tab).
static func draw_hazard(ci: CanvasItem, r: Rect2, stripe := 8.0, col := ACCENT, bg := Color(0.05, 0.05, 0.05, 0.9)) -> void:
	if bg.a > 0.0:
		ci.draw_rect(r, bg)
	var x := r.position.x - r.size.y
	while x < r.end.x:
		var p := PackedVector2Array([Vector2(x, r.end.y), Vector2(x + r.size.y, r.position.y),
			Vector2(x + r.size.y + stripe, r.position.y), Vector2(x + stripe, r.end.y)])
		var clipped := Geometry2D.intersect_polygons(p, PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]))
		for poly in clipped:
			ci.draw_colored_polygon(poly, col)
		x += stripe * 2.0


## Marks of a selected (yellow) tab, like the reference vault tabs: black hazard stripes down
## the left edge, a thin cut line across the top-left corner and a dark notch bottom-right.
static func draw_tab_selected(ci: CanvasItem, s: Vector2) -> void:
	draw_hazard(ci, Rect2(0, 0, 9, s.y), 4.0, Color(INK, 0.85), Color.TRANSPARENT)
	ci.draw_line(Vector2(9, 15), Vector2(24, 0), Color(INK, 0.55), 1.5, true)
	var n := 13.0
	ci.draw_colored_polygon(PackedVector2Array([Vector2(s.x - n - 4, s.y), Vector2(s.x - 4, s.y - n), Vector2(s.x - 4, s.y)]), Color(INK, 0.5))


static var _glows := {}


## Soft radial glow (cached per colour): `col` in the middle fading out at the edge of the
## rect it is drawn into, so it never spills outside a card.
static func radial_glow(col: Color) -> Texture2D:
	var key := col.to_html()
	if _glows.has(key):
		return _glows[key]
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.35, 0.7, 1.0])
	g.colors = PackedColorArray([col, Color(col, col.a * 0.55), Color(col, col.a * 0.16), Color(col, 0.0)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 128
	t.height = 128
	_glows[key] = t
	return t


## Light popup header (reference popups): a light-grey strip with the title in dark caps, a
## darker slanted plate toward the right, a hazard line along its bottom edge and the close X on
## a dark tile at the right end (the tile is a Button named "Close": connect its `pressed`).
static func popup_header(title: String, size := 26, height := 56.0) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 0)
	h.custom_minimum_size = Vector2(0, height)
	var strip := Control.new()
	strip.name = "Strip"
	strip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	strip.draw.connect(func() -> void:
		var s := strip.size
		strip.draw_rect(Rect2(Vector2.ZERO, s), Color(0.925, 0.925, 0.915))
		var x0 := s.x * 0.62
		strip.draw_colored_polygon(PackedVector2Array([Vector2(x0 + s.y, 0), Vector2(s.x, 0), Vector2(s.x, s.y - 6),
			Vector2(x0, s.y - 6)]), Color(0.80, 0.80, 0.79))
		strip.draw_line(Vector2(s.x - 54, 3), Vector2(s.x - 14, s.y - 9), Color(0.55, 0.55, 0.54), 1.0, true)
		draw_hazard(strip, Rect2(0, s.y - 6, s.x * 0.74, 6), 5.0, ACCENT, Color(0.09, 0.08, 0.06)))
	h.add_child(strip)
	var t := label(title.to_upper(), size, Color(0.17, 0.17, 0.17), "bold")
	t.name = "Title"
	t.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	t.offset_left = 26
	t.offset_bottom = -6
	t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	strip.add_child(t)
	var close := Button.new()
	close.name = "Close"
	close.custom_minimum_size = Vector2(height + 4, height)
	close.focus_mode = Control.FOCUS_NONE
	var st := box(Color(0.10, 0.095, 0.09), 0, 0, Color.TRANSPARENT, 0.0)
	var pr := box(Color(ACCENT, 0.45), 0, 0, Color.TRANSPARENT, 0.0)
	close.add_theme_stylebox_override("normal", st)
	close.add_theme_stylebox_override("hover", box(Color(0.18, 0.17, 0.16), 0, 0, Color.TRANSPARENT, 0.0))
	close.add_theme_stylebox_override("pressed", pr)
	close.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	close.draw.connect(func() -> void:
		var s := close.size
		draw_hazard(close, Rect2(0, 0, s.x - 3, s.y), 7.0, Color(1, 1, 1, 0.045), Color.TRANSPARENT)
		close.draw_rect(Rect2(s.x - 3, 0, 3, s.y), ACCENT)
		var c := Vector2((s.x - 3) * 0.5, s.y * 0.5)
		var r := s.y * 0.2
		close.draw_line(c - Vector2(r, r), c + Vector2(r, r), TEXT, 3.0, true)
		close.draw_line(c + Vector2(-r, r), c + Vector2(r, -r), TEXT, 3.0, true))
	close.pressed.connect(func() -> void: Audio.play("ui_back", -4.0))
	h.add_child(close)
	return h


## The system-dialog band (reference information dialog, pause menu, quit dialog): full width,
## near-black warm brown, a lighter wash on the left, faint diagonal streaks on the right, a
## hazard tab top-left and a thin accent line along the bottom.
static func draw_dialog_band(ci: CanvasItem, s: Vector2, line := ACCENT) -> void:
	ci.draw_rect(Rect2(Vector2.ZERO, s), Color(0.114, 0.10, 0.075, 0.95))
	ci.draw_rect(Rect2(0, 0, s.x * 0.45, s.y), Color(1, 1, 1, 0.022))
	for i in 7:
		var x := s.x * (0.72 + i * 0.035)
		ci.draw_line(Vector2(x + s.y * 0.35, s.y * 0.08), Vector2(x, s.y * 0.6), Color(1, 1, 1, 0.035), 1.0, true)
	draw_hazard(ci, Rect2(0, 0, 150, 7), 7.0)
	ci.draw_rect(Rect2(0, 7, s.x, 1), Color(1, 1, 1, 0.07))
	draw_hazard(ci, Rect2(0, s.y - 9, s.x, 5), 6.0, Color(1, 1, 1, 0.05), Color.TRANSPARENT)
	ci.draw_rect(Rect2(0, s.y - 3, s.x, 3), Color(line, 0.8))


## Long names end in "..." inside the label's width (instead of growing or cutting a glyph).
static func ellipsis(l: Label) -> Label:
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return l


## A full-rect TextureRect showing `tex` like CSS "cover" (crops, never letterboxes).
static func cover(tex: Texture2D) -> TextureRect:
	var t := TextureRect.new()
	t.texture = tex
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	full_rect(t)
	return t


## Vertical (or horizontal) colour ramp as a full-rect TextureRect: overlays that darken art.
static func gradient_rect(stops: Array, horizontal := false) -> TextureRect:
	var g := Gradient.new()
	var offs := PackedFloat32Array()
	var cols := PackedColorArray()
	for s in stops:
		offs.append(float(s[0]))
		cols.append(s[1])
	g.offsets = offs
	g.colors = cols
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.width = 64 if horizontal else 4
	gt.height = 4 if horizontal else 64
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(1, 0) if horizontal else Vector2(0, 1)
	var t := TextureRect.new()
	t.texture = gt
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_SCALE
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return t

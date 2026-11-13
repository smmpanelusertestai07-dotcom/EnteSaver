class_name UI
extends RefCounted
## Shared UI kit (original art in a battle-royale menu language): near-black translucent panels
## with square corners, a small 45-degree cut at the bottom-right of buttons and tabs, a thin
## yellow bar before section headers, yellow main buttons with black heavy condensed text,
## light-grey secondary buttons, yellow 2 px frames + tick for the selection, boxed side tabs (the
## open one yellow with black hazard stripes), bold condensed caps. Everything is drawn with
## StyleBoxFlat / polygons (no image skins), so it scales to any screen. Textures (icons, key art)
## are loaded once and cached. The tokens are listed in design/STYLE_SPEC.txt (section 6).

const ACCENT := Color(0.976, 0.749, 0.024)        # main yellow (#F9BF06)
const ACCENT_EDGE := Color(0.737, 0.51, 0.0)      # its darker lower edge (#BC8200)
const GOLD := Color(0.965, 0.71, 0.0)             # victory gold
const AMBER := Color(0.89, 0.667, 0.16)           # casual mode names
const BLUE := Color(0.106, 0.569, 0.851)          # own side
const ORANGE := Color(0.875, 0.447, 0.216)        # enemy side
const INK := Color(0.07, 0.065, 0.05)             # text on yellow / light buttons
const PANEL := Color(0.067, 0.059, 0.071, 0.9)    # near-black translucent panels (#110F12)
const ROW := Color(0.13, 0.094, 0.114, 0.62)      # list and setting rows on a page (#21181D, translucent)
const LIGHT := Color(0.847, 0.847, 0.847)         # secondary buttons (#D8D8D8)
const TAB_DARK := Color(0.059, 0.031, 0.063, 0.92)  # side tabs and page columns (#0F0810)
const PAGE_TOP := Color(0.122, 0.094, 0.125)      # full pages: a dark purple-brown ramp (#1F1820 ..
const PAGE_BOTTOM := Color(0.2, 0.15, 0.27)       # .. #33264A)
const CHAT_BG := Color(0.086, 0.055, 0.098, 0.97)   # the chat panel (#160E19)
const BUBBLE := Color(0.078, 0.071, 0.082)        # a chat message bubble (#141215, thin grey border)
const STATUS_ON := Color(1.0, 0.71, 0.13)         # ONLINE / IN A MATCH in player lists
const TEXT := Color(0.97, 0.97, 0.96)
const TEXT_DIM := Color(0.64, 0.64, 0.66)
const BAD := Color(0.95, 0.30, 0.24)
const FONT_FILES := {
	"bold": "res://assets/fonts/ui_bold",
	"semi": "res://assets/fonts/ui_semibold",
	"title": "res://assets/fonts/title",
	"number": "res://assets/fonts/number",
}
const ICON_DIR := "res://assets/ui/icons/"
## The smallest touch target (canvas px on the 720 px tall canvas: about 9 mm on a phone).
const TOUCH_MIN := 56.0
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
			base = Color(0.067, 0.059, 0.071, 0.88)
			border = 1
			border_col = Color(1, 1, 1, 0.2)
	for st in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(st, fg)
	b.add_theme_color_override("font_disabled_color", Color(fg, 0.45))
	var cut := clampi(int(min_size.y * 0.16), 6, 11)
	var normal := chamfer(base, cut, border, border_col, 12.0, ["br"])
	if style in ["primary", "light"]:
		normal.border_width_bottom = 3
		normal.border_color = ACCENT_EDGE if style == "primary" else base.darkened(0.3)
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


## Screenshot tours and checks set this to stand in for a phone's camera cutout (x >= 0).
static var margins_for_test := Vector2(-1.0, -1.0)


## Keeps a full-screen Control's left and right edges clear of the camera cutout (safe_margins):
## its offsets follow the cutout now, on a size change and every second (turning the phone over
## moves the cutout to the other side without one).
static func keep_clear_of_cutout(c: Control) -> void:
	var apply := func() -> void:
		if c.is_inside_tree():
			var m := safe_margins(c.get_viewport())
			c.offset_left = m.x
			c.offset_right = -m.y
	var t := Timer.new()
	t.wait_time = 1.0
	t.autostart = true
	t.timeout.connect(apply)
	c.add_child(t)
	c.resized.connect(apply, CONNECT_DEFERRED)
	apply.call_deferred()


## The sides of the screen that a camera cutout covers, in `vp`'s canvas pixels (x left, y right;
## the display's safe area, which immersive full screen does not keep clear by itself). In
## landscape a punch-hole camera sits on a short side. Zero where the whole screen is safe and on
## desktop builds; at most 12 % of the width a side.
static func safe_margins(vp: Viewport) -> Vector2:
	if margins_for_test.x >= 0.0 and not OS.has_feature("template"):
		return margins_for_test
	if vp == null or not OS.has_feature("mobile"):
		return Vector2.ZERO
	var safe := DisplayServer.get_display_safe_area()
	var at := DisplayServer.window_get_position()
	var win := DisplayServer.window_get_size()
	var canvas_w := vp.get_visible_rect().size.x
	if safe.size.x <= 0 or win.x <= 0:
		return Vector2.ZERO
	var k := canvas_w / float(win.x)
	return Vector2(clampf(float(safe.position.x - at.x) * k, 0.0, canvas_w * 0.12),
		clampf(float(at.x + win.x - safe.end.x) * k, 0.0, canvas_w * 0.12))


## A button's caption: a hero button's "Caption" label, else the button's own text.
static func set_caption(b: Button, text: String) -> void:
	var cap := b.get_node_or_null("Caption") as Label
	if cap:
		cap.text = text
	else:
		b.text = text


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
	var pts := hero_points(r, cut)
	var cols := PackedColorArray()
	for p in pts:
		cols.append(top.lerp(bottom, p.y / maxf(r.size.y, 1.0)))
	b.draw_polygon(pts, cols)
	# darker lower lip
	var lip := PackedVector2Array([Vector2(0, r.end.y), Vector2(r.size.y * 0.016, r.end.y - 4.0),
		Vector2(r.size.x - cut + 4.0, r.end.y - 4.0), Vector2(r.size.x - cut, r.end.y)])
	b.draw_colored_polygon(lip, Color(0, 0, 0, 0.14) if style != "primary" else Color(ACCENT_EDGE, 0.55))
	# glossy diagonal highlight across the upper-left
	var k := r.size.y * 0.2
	var g := PackedVector2Array([Vector2(k, 0), Vector2(r.size.x * 0.52, 0), Vector2(r.size.x * 0.40, r.size.y * 0.48),
		Vector2(k * 0.52, r.size.y * 0.48)])
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


## The big CTA's outline: the left edge slanted (its foot a fifth of the height in), the
## bottom-right corner cut.
static func hero_points(r: Rect2, cut: float) -> PackedVector2Array:
	var k := r.size.y * 0.2
	return PackedVector2Array([Vector2(r.position.x + k, r.position.y), Vector2(r.end.x, r.position.y),
		Vector2(r.end.x, r.end.y - cut), Vector2(r.end.x - cut, r.end.y), Vector2(r.position.x, r.end.y)])


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
		b.custom_minimum_size = Vector2(min_w, TOUCH_MIN)
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
	b.custom_minimum_size = Vector2(TOUCH_MIN, TOUCH_MIN)
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


## How far (canvas px) a finger moves on a scrolling list before the touch becomes a scroll: a
## smaller wobble is still a tap on the button under it (with no dead zone a 3 px wobble turned a
## tap into a fling).
const SCROLL_DEADZONE := 12


## A finger drag scrolls `sc` wherever it starts on its rows. Buttons and plates keep a touch to
## themselves (MOUSE_FILTER_STOP), so only the gaps between rows would scroll: every such control
## under `content` passes the touch on to `sc` too. A tap still presses the button under it; once
## the finger moves SCROLL_DEADZONE px the list scrolls and that press is dropped. Call it again
## whenever the rows are built again.
static func drag_scroll(sc: ScrollContainer, content: Control) -> void:
	sc.scroll_deadzone = SCROLL_DEADZONE
	for n in content.find_children("*", "Control", true, false):
		var c := n as Control
		if c.mouse_filter == Control.MOUSE_FILTER_STOP:
			c.mouse_filter = Control.MOUSE_FILTER_PASS


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
	var st := box(Color(0.05, 0.04, 0.055, 0.82), 0, 1, Color(1, 1, 1, 0.2), 0.0)
	var hv := box(Color(0.16, 0.15, 0.17, 0.9), 0, 1, Color(1, 1, 1, 0.35), 0.0)
	var pr := box(Color(ACCENT, 0.4), 0, 1, ACCENT, 0.0)
	b.add_theme_stylebox_override("normal", st)
	b.add_theme_stylebox_override("hover", hv)
	b.add_theme_stylebox_override("pressed", pr)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.draw.connect(func() -> void:
		var c := b.size * 0.5
		var r := b.size.x * 0.22
		b.draw_line(c - Vector2(r, r), c + Vector2(r, r), TEXT, 2.5, true)
		b.draw_line(c + Vector2(-r, r), c + Vector2(r, -r), TEXT, 2.5, true)
		# the yellow diagonal accent across the top-right corner
		var k := b.size.x * 0.24
		b.draw_colored_polygon(PackedVector2Array([Vector2(b.size.x - k, 0), Vector2(b.size.x, 0), Vector2(b.size.x, k)]), ACCENT))
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
		strip.draw_polygon(PackedVector2Array([Vector2.ZERO, Vector2(s.x, 0), Vector2(s.x, s.y), Vector2(0, s.y)]),
			PackedColorArray([Color(0.945, 0.945, 0.945), Color(0.945, 0.945, 0.945), Color(0.82, 0.82, 0.82), Color(0.82, 0.82, 0.82)]))
		var x0 := s.x * 0.62
		strip.draw_colored_polygon(PackedVector2Array([Vector2(x0 + s.y, 0), Vector2(s.x, 0), Vector2(s.x, s.y - 6),
			Vector2(x0, s.y - 6)]), Color(0.76, 0.76, 0.76, 0.6))
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
	var st := box(Color(0.09, 0.08, 0.1), 0, 0, Color.TRANSPARENT, 0.0)
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


## The near-black body under a popup_header, flush with it: a faint border on three sides and
## the accent corner mark bottom-right. Add the content to the returned panel.
static func popup_body() -> PanelContainer:
	var body := PanelContainer.new()
	var st := box(Color(0.094, 0.082, 0.11, 0.97), 0, 0, Color.TRANSPARENT, 26.0)
	st.border_width_left = 1
	st.border_width_right = 1
	st.border_width_bottom = 1
	st.border_color = Color(1, 1, 1, 0.1)
	st.content_margin_top = 18
	st.content_margin_bottom = 22
	body.add_theme_stylebox_override("panel", st)
	body.draw.connect(func() -> void:
		var s := body.size
		body.draw_colored_polygon(PackedVector2Array([Vector2(s.x, s.y - 18), Vector2(s.x, s.y), Vector2(s.x - 18, s.y)]), ACCENT))
	return body


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


## The synthetic italic ("italic" font) leans the glyph tops right while a label centres the
## upright advances: a centred italic title looks about 0.11 x its size right of centre. This
## shifts such a label back (call after its anchors/offsets are set).
static func center_italic(l: Label, size: int) -> Label:
	var dx := roundf(size * 0.11)
	l.offset_left -= dx
	l.offset_right -= dx
	return l


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


## A boxed side tab of a full page (FRIENDS, PROFILE): a dark box with a light lower edge; the
## open one solid yellow with dark text, black hazard stripes down its left edge and a cut corner.
## Call it again with `on` to restyle (style_side_tab).
static func side_tab(text: String, on: bool, size := 22, min_size := Vector2(200, 64)) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size = min_size
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	b.add_theme_font_override("font", font("heavy"))
	b.add_theme_font_size_override("font_size", size)
	b.draw.connect(func() -> void:
		if b.has_meta("on") and bool(b.get_meta("on")):
			draw_tab_selected(b, b.size))
	style_side_tab(b, on)
	b.pressed.connect(func() -> void: Audio.play("ui_select", -6.0))
	return b


static func style_side_tab(b: Button, on: bool) -> void:
	b.set_meta("on", on)
	var base := ACCENT if on else TAB_DARK
	var st := chamfer(base, 10, 0, Color.TRANSPARENT, 0.0, ["br"])
	st.content_margin_left = 22
	st.content_margin_right = 10
	if not on:
		st.border_width_bottom = 2
		st.border_color = Color(1, 1, 1, 0.16)
	var hover := st.duplicate() as StyleBoxFlat
	hover.bg_color = base.lightened(0.08) if on else Color(0.16, 0.13, 0.17, 0.95)
	for state: String in ["normal", "pressed", "hover_pressed", "disabled"]:
		b.add_theme_stylebox_override(state, st)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var fg := INK if on else TEXT
	for c: String in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(c, fg)
	b.queue_redraw()


## A tab along the top of a panel (the chat's channels): the open one a light tile with dark text
## and a hazard stripe down its right edge; the others plain white caps on the panel.
static func top_tab(text: String, on: bool, size := 22, min_size := Vector2(150, 56)) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = min_size
	b.add_theme_font_override("font", font("heavy"))
	b.add_theme_font_size_override("font_size", size)
	var st := box(Color(0.92, 0.92, 0.92) if on else Color(0, 0, 0, 0), 0, 0, Color.TRANSPARENT, 12.0)
	var hv := st.duplicate() as StyleBoxFlat
	if not on:
		hv.bg_color = Color(1, 1, 1, 0.08)
	for state: String in ["normal", "pressed", "hover_pressed"]:
		b.add_theme_stylebox_override(state, st)
	b.add_theme_stylebox_override("hover", hv)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var fg := INK if on else TEXT
	for c: String in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(c, fg)
	if on:
		b.draw.connect(func() -> void:
			draw_hazard(b, Rect2(b.size.x - 8, 0, 8, b.size.y), 4.0, Color(INK, 0.9), ACCENT))
	b.pressed.connect(func() -> void: Audio.play("ui_select", -6.0))
	return b


## A yellow underlined link ending in ">>" (ADD FRIEND >>): a flat button on a 56 px touch strip.
static func link_button(text: String, size := 20) -> Button:
	var b := Button.new()
	b.text = text + " >>"
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, TOUCH_MIN)
	b.add_theme_font_override("font", font("bold"))
	b.add_theme_font_size_override("font_size", size)
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		b.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	for c: String in ["font_color", "font_hover_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(c, ACCENT)
	b.add_theme_color_override("font_pressed_color", ACCENT.lightened(0.3))
	b.draw.connect(func() -> void:
		var w := font("bold").get_string_size(b.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		var x0 := (b.size.x - w) * 0.5
		b.draw_line(Vector2(x0, b.size.y * 0.5 + size * 0.62), Vector2(x0 + w, b.size.y * 0.5 + size * 0.62), ACCENT, 1.5))
	b.pressed.connect(func() -> void: Audio.play("ui_click", -4.0))
	return b


## An empty list's look: a small grey block of hatched stripes, the grey caps line under it and,
## when `link_text` is set, a yellow link (its Button is the box's "link" meta).
static func empty_state(text: String, link_text := "") -> VBoxContainer:
	var v := VBoxContainer.new()
	v.name = "EmptyState"
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 10)
	var mark := Control.new()
	mark.custom_minimum_size = Vector2(0, 54)
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mark.draw.connect(func() -> void:
		var r := Rect2(mark.size.x * 0.5 - 34, 4, 68, 46)
		draw_hazard(mark, r, 6.0, Color(1, 1, 1, 0.16), Color(1, 1, 1, 0.05))
		mark.draw_rect(r, Color(1, 1, 1, 0.22), false, 1.5))
	v.add_child(mark)
	var l := label(text, 20, TEXT_DIM, "bold")
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(l)
	if link_text != "":
		var b := link_button(link_text)
		b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		v.add_child(b)
		v.set_meta("link", b)
	return v


## A full page's backdrop: the dark purple-brown ramp with a soft warm glow up right.
static func draw_page_bg(ci: CanvasItem, s: Vector2) -> void:
	ci.draw_polygon(PackedVector2Array([Vector2.ZERO, Vector2(s.x, 0), s, Vector2(0, s.y)]),
		PackedColorArray([Color(PAGE_TOP, 0.97), Color(PAGE_TOP.lerp(PAGE_BOTTOM, 0.4), 0.97), Color(PAGE_BOTTOM, 0.97), Color(PAGE_TOP.lerp(PAGE_BOTTOM, 0.6), 0.97)]))
	ci.draw_texture_rect(radial_glow(Color(0.85, 0.45, 0.25, 0.14)), Rect2(s.x * 0.45, -s.y * 0.35, s.x * 0.7, s.y * 0.9), false)

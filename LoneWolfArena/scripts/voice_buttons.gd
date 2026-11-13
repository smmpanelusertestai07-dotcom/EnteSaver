class_name VoiceButtons
extends Control
## Voice controls (NetVoice) as the reference places them:
##  - in the LOBBY (`lobby_pill`): a small dark pill [mic | speaker] under the player's character,
##    shown also when alone (it follows the character on screen; hidden with the wardrobe, PROFILE
##    or a popup open). A mic tap opens MIC MODE: OFF / ALL / GROUP and a PUSH TO TALK tick box
##    (unticked by default); a speaker tap opens OFF / ALL / GROUP. The chosen item is yellow, a tap
##    outside closes the popup. Under the modes: the players of the voice channel, each with a MUTE
##    switch (kept for this session; a blocked player is always muted) and a speaking mark.
##  - in a MATCH HudNet draws round speaker and mic buttons beside the minimap and opens the same
##    MIC MODE popup (`open_popup` with in_match: GROUP only when the player has teammates).
## The icons are drawn here (`draw_mic`, `draw_speaker`): ours, outline mic and speaker, a red
## slash when OFF, a small people mark for GROUP.

const PILL := Vector2(112, 44)
const LIFT := 0.12                 # the pill's height over the character's feet (model units)
const ITEM := Vector2(78, 70)

var lobby: Node                    # the Lobby (camera, model, wardrobe, profile_ui, team)
var popup: Control                 # the open popup's full-screen catcher
var note := ""                     # why the mic went OFF (Android refused it), shown under the pill
var _note_t := 0.0


## The lobby's pill, added over the lobby's UI (`root`).
static func lobby_pill(l: Node, root: Control) -> VoiceButtons:
	var v := VoiceButtons.new()
	v.name = "VoicePill"
	v.lobby = l
	v.size = PILL
	v.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(v)
	var hub := NetVoice.hub()
	hub.changed.connect(v.queue_redraw)
	hub.mic_refused.connect(func() -> void:
		v.note = NetVoice.REFUSED_NOTE
		v._note_t = 6.0
		v.queue_redraw())
	return v


func _process(delta: float) -> void:
	_note_t = maxf(_note_t - delta, 0.0)
	if lobby == null:
		return
	var cam := lobby.get("camera") as Camera3D
	var hero := lobby.get("model") as Node3D
	var on := cam != null and hero != null and lobby.get("wardrobe") == null
	var prof: Variant = lobby.get("profile_ui")
	if prof != null and prof.get("layer") != null:
		on = false
	if on and cam != null and hero != null:
		var p := hero.global_position + Vector3(0, LIFT, 0)
		if cam.is_position_behind(p):
			on = false
		else:
			var at := cam.unproject_position(p) - Vector2(PILL.x * 0.5, PILL.y * 0.5)
			var vs := get_viewport_rect().size
			at.x = clampf(at.x, 8.0, vs.x - PILL.x - 8.0)
			at.y = clampf(at.y, 80.0, vs.y - 92.0 - PILL.y)       # over the bottom bar
			global_position = at.round()
	visible = on
	queue_redraw()


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, PILL)
	draw_style_box(UI.box(Color(0.02, 0.02, 0.025, 0.66), 22, 1, Color(1, 1, 1, 0.16), 0.0), r)
	draw_line(Vector2(PILL.x * 0.5, 9.0), Vector2(PILL.x * 0.5, PILL.y - 9.0), Color(1, 1, 1, 0.22), 1.5)
	var mic := NetVoice.mic_mode()
	var spk := NetVoice.speaker_mode()
	var talking := NetVoice.speaking(NetVoice.ME)
	draw_mic(self, Vector2(PILL.x * 0.25, PILL.y * 0.5), 20.0, UI.ACCENT if talking else UI.TEXT, mic == NetVoice.OFF, mic == NetVoice.GROUP)
	draw_speaker(self, Vector2(PILL.x * 0.75, PILL.y * 0.5), 20.0, UI.TEXT, spk == NetVoice.OFF, spk == NetVoice.GROUP)
	if _note_t > 0.0:
		HudDraw.text(self, note, Vector2(PILL.x * 0.5, PILL.y + 16.0), 14, Color(UI.BAD, minf(_note_t, 1.0)), 1, 3)


func _gui_input(event: InputEvent) -> void:
	var at := Vector2.ZERO
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		at = (event as InputEventMouseButton).position
	elif event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed:
		at = (event as InputEventScreenTouch).position
	else:
		return
	accept_event()
	Audio.play("ui_click", -6.0)
	var kind := "mic" if at.x < PILL.x * 0.5 else "speaker"
	var root := get_parent() as Control
	if root:
		popup = open_popup(root, kind, global_position + Vector2(PILL.x * 0.5, -10.0), false)
		popup.tree_exited.connect(func() -> void: popup = null)


# ---------------------------------------------------------------- the popup

## The MIC MODE (kind "mic") or speaker (kind "speaker") popup over `host`, its bottom centre at
## `at` (in_match: its top-left at `at`, beside the HUD's column). Returns its full-screen catcher:
## a tap outside the box frees it.
static func open_popup(host: Control, kind: String, at: Vector2, in_match: bool) -> Control:
	var catcher := Control.new()
	catcher.name = "VoicePopup"
	catcher.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	catcher.mouse_filter = Control.MOUSE_FILTER_STOP
	catcher.gui_input.connect(func(e: InputEvent) -> void:
		if (e is InputEventMouseButton and (e as InputEventMouseButton).pressed) or (e is InputEventScreenTouch and (e as InputEventScreenTouch).pressed):
			catcher.accept_event()
			catcher.queue_free())
	host.add_child(catcher)
	var box := PanelContainer.new()
	box.name = "MicModeBox" if kind == "mic" else "SpeakerBox"
	box.add_theme_stylebox_override("panel", UI.box(Color(0.03, 0.03, 0.035, 0.86), 6, 0, Color(0, 0, 0, 0), 10.0))
	catcher.add_child(box)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	box.add_child(v)
	if kind == "mic":
		v.add_child(UI.label("MIC MODE", 15, UI.TEXT, "bold"))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	v.add_child(row)
	var hub := NetVoice.hub()
	var modes := [NetVoice.OFF, NetVoice.ALL, NetVoice.GROUP]
	if in_match and kind == "mic" and NetVoice.mates() == 0:
		modes = [NetVoice.OFF, NetVoice.ALL]          # (the reference: no GROUP without teammates)
	var current := NetVoice.mic_mode() if kind == "mic" else NetVoice.speaker_mode()
	for m: int in modes:
		var b := _item(kind, m, m == current)
		b.pressed.connect(func() -> void:
			Audio.play("ui_click", -6.0)
			if kind == "mic":
				hub.set_mic_mode(m)
			else:
				hub.set_speaker_mode(m)
			catcher.queue_free())
		row.add_child(b)
	if kind == "mic":
		var ptt := CheckBox.new()
		ptt.name = "PushToTalk"
		ptt.text = "PUSH TO TALK"
		ptt.focus_mode = Control.FOCUS_NONE
		ptt.button_pressed = NetVoice.push_to_talk()
		ptt.add_theme_font_override("font", UI.font("bold"))
		ptt.add_theme_font_size_override("font_size", 15)
		ptt.add_theme_color_override("font_color", UI.TEXT_DIM)
		ptt.add_theme_color_override("font_pressed_color", UI.ACCENT)
		ptt.toggled.connect(func(on: bool) -> void: hub.set_push_to_talk(on))
		v.add_child(ptt)
	var players := channel_players()
	if not players.is_empty():
		v.add_child(UI.label("PLAYERS", 13, UI.TEXT_DIM, "bold"))
		for p: Dictionary in players:
			v.add_child(_mute_row(String(p.id), String(p.name)))
	box.reset_size()
	var vs := host.get_viewport_rect().size
	var pos := at if in_match else at - Vector2(box.size.x * 0.5, box.size.y)
	box.position = Vector2(clampf(pos.x, 8.0, vs.x - box.size.x - 8.0), clampf(pos.y, 8.0, vs.y - box.size.y - 8.0)) - host.global_position
	return catcher


## One mode: its icon over its name; the chosen one yellow.
static func _item(kind: String, m: int, chosen: bool) -> Button:
	var b := Button.new()
	b.name = "%s_%s" % [kind.capitalize(), NetVoice.MODE_NAMES[m]]
	b.custom_minimum_size = ITEM
	b.focus_mode = Control.FOCUS_NONE
	b.flat = true
	var ink := UI.ACCENT if chosen else UI.TEXT
	var icon := ModeIcon.new()
	icon.kind = kind
	icon.mode = m
	icon.ink = ink
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.position = Vector2(ITEM.x * 0.5 - 18.0, 6.0)
	icon.size = Vector2(36, 36)
	b.add_child(icon)
	var l := UI.label(String(NetVoice.MODE_NAMES[m]), 15, ink, "bold")
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.position = Vector2(0, 44)
	l.size = Vector2(ITEM.x, 22)
	b.add_child(l)
	return b


## A player of the channel: the speaking mark, the name, MUTE / MUTED (a blocked one stays MUTED).
static func _mute_row(id: String, who: String) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.name = "Voice_%s" % id.left(8)
	h.add_theme_constant_override("separation", 8)
	var mark := SpeakingMark.new()
	mark.id = id
	mark.custom_minimum_size = Vector2(18, 30)
	h.add_child(mark)
	var l := UI.label(who, 15, UI.TEXT, "semi")
	l.custom_minimum_size = Vector2(150, 30)
	l.clip_text = true
	h.add_child(l)
	var blocked := id != "" and Game.is_blocked(id)
	var b := UI.button("MUTED" if NetVoice.is_muted(id) else "MUTE", 14, "dark", Vector2(86, 34))
	b.name = "Mute"
	b.disabled = blocked
	b.pressed.connect(func() -> void:
		NetVoice.set_muted(id, not NetVoice.is_muted(id))
		b.text = "MUTED" if NetVoice.is_muted(id) else "MUTE")
	h.add_child(b)
	return h


## The other players of the voice channel now: [{"id", "name"}].
static func channel_players() -> Array:
	var out := []
	match NetVoice.channel():
		"match":
			var s: Cloud = Game.session
			if s.session_multi:
				for e: Dictionary in s.session_roster:
					if String(e.get("id", "")) != s.my_id and String(e.get("id", "")) != "":
						out.append({"id": String(e.id), "name": String(e.get("name", "PLAYER"))})
			elif String(s.opponent.get("id", "")) != "":
				out.append({"id": String(s.opponent.id), "name": String(s.opponent.get("name", "PLAYER"))})
		"group":
			for m: Dictionary in Game.cloud.group_members():
				if not bool(m.me):
					out.append({"id": String(m.id), "name": String(m.name)})
	return out


# ---------------------------------------------------------------- icons

## A microphone (outline head, stand), a red slash when `off`, a people mark for `group`.
static func draw_mic(ci: CanvasItem, c: Vector2, r: float, ink: Color, off := false, group := false) -> void:
	var w := r * 0.36
	var top := c.y - r * 0.55
	var head := Rect2(c.x - w * 0.5, top, w, r * 0.62)
	ci.draw_style_box(UI.box(Color(0, 0, 0, 0), int(w * 0.5), 2, ink, 0.0), head)
	ci.draw_arc(Vector2(c.x, top + r * 0.36), r * 0.34, 0.1, PI - 0.1, 14, ink, 2.0, true)
	ci.draw_line(Vector2(c.x, top + r * 0.7), Vector2(c.x, c.y + r * 0.42), ink, 2.0)
	ci.draw_line(Vector2(c.x - r * 0.2, c.y + r * 0.42), Vector2(c.x + r * 0.2, c.y + r * 0.42), ink, 2.0)
	if group:
		_people(ci, c + Vector2(r * 0.5, r * 0.18), r * 0.3, ink)
	if off:
		_slash(ci, c, r)


## A speaker with two waves, a red slash when `off`, a people mark for `group`.
static func draw_speaker(ci: CanvasItem, c: Vector2, r: float, ink: Color, off := false, group := false) -> void:
	var x := c.x - r * 0.48
	ci.draw_colored_polygon(PackedVector2Array([Vector2(x, c.y - r * 0.16), Vector2(x + r * 0.22, c.y - r * 0.16),
		Vector2(x + r * 0.5, c.y - r * 0.42), Vector2(x + r * 0.5, c.y + r * 0.42), Vector2(x + r * 0.22, c.y + r * 0.16),
		Vector2(x, c.y + r * 0.16)]), ink)
	if not off:
		for i in (1 if group else 2):
			ci.draw_arc(Vector2(x + r * 0.5, c.y), r * (0.24 + 0.2 * i), -0.9, 0.9, 12, ink, 2.0, true)
	if group:
		_people(ci, c + Vector2(r * 0.42, r * 0.2), r * 0.3, ink)
	if off:
		_slash(ci, c, r)


static func _people(ci: CanvasItem, c: Vector2, s: float, ink: Color) -> void:
	ci.draw_circle(c + Vector2(0, -s * 0.55), s * 0.38, ink, true, -1.0, true)
	ci.draw_arc(c + Vector2(0, s * 0.55), s * 0.7, PI, TAU, 10, ink, 2.0, true)


static func _slash(ci: CanvasItem, c: Vector2, r: float) -> void:
	ci.draw_line(c + Vector2(-r * 0.55, -r * 0.55), c + Vector2(r * 0.55, r * 0.55), Color(0, 0, 0, 0.7), 5.0, true)
	ci.draw_line(c + Vector2(-r * 0.55, -r * 0.55), c + Vector2(r * 0.55, r * 0.55), UI.BAD, 2.5, true)


## A mode's icon in the popup.
class ModeIcon extends Control:
	var kind := "mic"
	var mode := 0
	var ink := Color.WHITE

	func _draw() -> void:
		var c := size * 0.5
		if kind == "mic":
			VoiceButtons.draw_mic(self, c, 17.0, ink, mode == NetVoice.OFF, mode == NetVoice.GROUP)
		else:
			VoiceButtons.draw_speaker(self, c, 17.0, ink, mode == NetVoice.OFF, mode == NetVoice.GROUP)


## A small sound mark that lights while that player speaks (NetVoice.speaking).
class SpeakingMark extends Control:
	var id := ""

	func _process(_delta: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var on := NetVoice.speaking(id)
		var col := UI.ACCENT if on else Color(1, 1, 1, 0.25)
		var c := size * 0.5
		for i in 3:
			var h := (6.0 + 5.0 * float(i % 2 + (1 if on else 0))) if on else 4.0
			draw_rect(Rect2(c.x - 7.0 + i * 5.0, c.y - h * 0.5, 3.0, h), col)


# ---------------------------------------------------------------- MIC TEST (SOUND > VOICE CHAT)

## MIC TEST: START asks for the microphone (once) and plays the own voice back here through the
## codec (local only, nothing is sent) with a level meter; STOP, or leaving the page, ends it.
static func mic_test() -> HBoxContainer:
	var h := HBoxContainer.new()
	h.name = "MicTest"
	h.add_theme_constant_override("separation", 10)
	var meter := LevelMeter.new()
	meter.name = "MicLevel"
	meter.custom_minimum_size = Vector2(150, 18)
	meter.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var b := UI.button("START", 16, "dark", Vector2(104, 44))
	b.name = "MicTestButton"
	b.pressed.connect(func() -> void:
		var hub := NetVoice.hub()
		hub.test_loop = not hub.test_loop and hub.ask_mic()
		if not hub.test_loop and not NetVoice.mic_allowed():
			meter.note = "ALLOW THE MICROPHONE FIRST"
		b.text = "STOP" if hub.test_loop else "START")
	h.add_child(meter)
	h.add_child(b)
	return h


## The microphone's level while MIC TEST runs (NetVoice.level), green to yellow; a note under it.
class LevelMeter extends Control:
	var note := ""

	func _process(_delta: float) -> void:
		queue_redraw()

	func _exit_tree() -> void:
		var hub := NetVoice.hub()
		hub.test_loop = false

	func _draw() -> void:
		var hub := NetVoice.hub()
		draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.5))
		var k := clampf(hub.level / 0.25, 0.0, 1.0) if hub.test_loop else 0.0
		draw_rect(Rect2(Vector2(2, 2), Vector2((size.x - 4.0) * k, size.y - 4.0)), Color(0.36, 0.85, 0.42).lerp(UI.ACCENT, k))
		var gate := clampf(NetVoice.GATE_OPEN / 0.25, 0.0, 1.0) * (size.x - 4.0) + 2.0
		draw_line(Vector2(gate, 0), Vector2(gate, size.y), Color(1, 1, 1, 0.6), 1.5)
		if note != "" and not hub.test_loop:
			HudDraw.text(self, note, Vector2(0, size.y + 12.0), 12, UI.BAD, 0, 2)

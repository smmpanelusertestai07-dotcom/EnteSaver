class_name HudNet
extends Control
## The match HUD's network layer (HUD.bind adds it to every match: HudNet.attach). Offline
## (TRAINING GROUND, `net` false) it is only the ping chip: the relay's round trip while this
## phone is connected to it (Cloud.relay_ping), else a grey "--", with no tag. Online (and LOCAL):
##  - top right, in the column under the gear beside the weapon panel: the round trip to the other
##    phone (NetPing: Cloud.match_ping: the direct round trip while the direct path is up, else
##    Cloud.peer_rtt, the relay's Cloud.relay_rtt until the other phone answered), with a small
##    DIRECT / RELAY tag under it (how the state travels, NetDirect);
##  - beside the minimap, at the reference's places (HudLayout keys "speaker" and "mic"): round
##    SPEAKER (a tap turns it OFF / back ON at once, a slash when off) and MIC (a tap opens MIC
##    MODE: OFF / ALL, GROUP with teammates, PUSH TO TALK; VoiceButtons.open_popup) buttons, the
##    voice (NetVoice.hub(): it runs whatever the HUD shows); with PUSH TO TALK and the mic on, TALK
##    under the mic (hold to talk); right of them CHAT (opens the chat panel: quick messages
##    NetChat.QUICK and free text, NetChat.MATCH_MAX characters) and MUTE (the feed hides the
##    opponent's lines), with CHAT on; under them the players speaking now (a sound mark and the
##    name);
##  - under the score bar: the chat feed, the last FEED_LINES lines for FEED_S seconds.
## Its buttons take their touches before the HUD does (a child's _input runs first) and mark them
## handled; while the chat panel is open the HUD's own input is off (its touches released first),
## so the panel's buttons and text field get the touches.

const R := 26.0                  # button radius (touch radius x 1.15: 60 px)
const GAP := 12.0
const FEED_S := 9.0
const FEED_LINES := 3
const IDS := ["speaker", "mic", "talk", "chat", "mute"]
const SPEAK_ROW := 22.0          # the speaking list's line height

var hud: HUD
var feed: Array = []             # [{"who", "text", "mine", "t"}], newest last
var feed_muted := false
var voice: NetVoice              # NetVoice.hub() in an online match
var panel: PanelContainer        # the chat panel while it is open
var voice_popup: Control         # MIC MODE while it is open (VoiceButtons.open_popup's catcher)
var _touch := {}                 # touch index -> button id
var _note := ""
var _note_t := 0.0
var _time := 0.0
var _field: LineEdit
var _panel_note: Label
## An online (or LOCAL) match: chat, voice and the other phone's round trip; false: the ping only.
var net := true


static func attach(h: HUD, online := true) -> HudNet:
	var n := HudNet.new()
	n.name = "HudNet"
	n.hud = h
	n.net = online
	h.add_child(n)
	return n


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cloud := Game.session
	if cloud == null or not net:
		return
	cloud.chat_received.connect(_on_chat)
	voice = NetVoice.hub()
	voice.mic_refused.connect(_on_mic_refused)


func _exit_tree() -> void:
	var cloud := Game.session
	if cloud and net:
		if cloud.chat_received.is_connected(_on_chat):
			cloud.chat_received.disconnect(_on_chat)
	if voice and is_instance_valid(voice):
		voice.ptt_held = false
		if voice.mic_refused.is_connected(_on_mic_refused):
			voice.mic_refused.disconnect(_on_mic_refused)
	if (panel or voice_popup) and hud:
		hud.set_process_input(true)


func shown(id: String) -> bool:
	if not net:
		return false
	match id:
		"chat", "mute":
			return bool(Game.settings.chat)
		"speaker", "mic":
			return voice != null
		"talk":
			return voice != null and NetVoice.push_to_talk() and NetVoice.mic_mode() != NetVoice.OFF
	return false


## The buttons' centres: SPEAKER and MIC at their layout places (HudLayout "speaker", "mic": the
## reference's column beside the minimap), TALK under MIC, then CHAT and MUTE in the column right
## of them (left of the minimap when it was moved to the right half).
func button_centers() -> Dictionary:
	var mr := Rect2(hud.minimap.position, hud.minimap.size) if hud and hud.minimap else Rect2(16, 12, 190, 190)
	var vs := size if size.x > 0.0 else Vector2(1560, 720)
	var lay: Dictionary = hud.layout if hud else {}
	var pitch := Vector2(R * 2.3 + 6.0, R * 2.0 + 26.0)
	var out := {}
	var col_x := mr.end.x + GAP + R * 1.15
	var y0 := mr.position.y + R + 2.0
	if shown("speaker"):
		var sp: Vector2 = HudLayout.center(lay.speaker, vs) if lay.has("speaker") else Vector2(col_x, y0)
		var mc: Vector2 = HudLayout.center(lay.mic, vs) if lay.has("mic") else Vector2(col_x, y0 + pitch.y)
		out.speaker = sp
		out.mic = mc
		if shown("talk"):
			out.talk = mc + Vector2(0, mc.y - sp.y if mc.y > sp.y else pitch.y)
		col_x = maxf(sp.x, mc.x) + pitch.x
		y0 = sp.y
	var x0 := col_x
	if x0 + R > size.x * 0.5 - 10.0 and mr.position.x > size.x * 0.5:
		x0 = mr.position.x - GAP - R * 1.15
	var i := 0
	for id: String in ["chat", "mute"]:
		if shown(id):
			out[id] = Vector2(x0, y0 + i * pitch.y)
			i += 1
	return out


func button_at(pos: Vector2) -> String:
	var c := button_centers()
	for id: String in c:
		if pos.distance_to(c[id]) <= R * 1.15:
			return id
	return ""


# ---------------------------------------------------------------- input

func _input(event: InputEvent) -> void:
	if hud == null:
		return
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed:
			if not is_visible_in_tree():
				return
			var id := button_at(t.position)
			if id != "":
				_touch[t.index] = id
				press(id)
				get_viewport().set_input_as_handled()
			elif panel != null and not panel.get_global_rect().has_point(t.position):
				close_panel()            # a tap beside the open panel closes it
				_touch[t.index] = ""
				get_viewport().set_input_as_handled()
		elif _touch.has(t.index):        # (a release counts even after the HUD was hidden)
			var id: String = _touch[t.index]
			_touch.erase(t.index)
			if id == "talk":
				set_talk(false)
			get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag and _touch.has((event as InputEventScreenDrag).index):
		get_viewport().set_input_as_handled()


func press(id: String) -> void:
	Audio.play("ui_click", -8.0)
	match id:
		"chat":
			if panel:
				close_panel()
			else:
				open_panel()
		"mute":
			feed_muted = not feed_muted
			_say("CHAT MUTED" if feed_muted else "CHAT ON")
		"talk":
			set_talk(true)
		"speaker":
			if voice:
				voice.toggle_speaker()
				_say("SPEAKER OFF" if NetVoice.speaker_mode() == NetVoice.OFF else "SPEAKER ON")
		"mic":
			open_voice_popup()


## PUSH TO TALK's TALK: the microphone runs only while it is held (Android asks for it if it was
## taken back since the mic was turned on).
func set_talk(on: bool) -> void:
	if voice == null:
		return
	if on and not voice.ask_mic():
		_say("ALLOW THE MICROPHONE TO TALK")
		return
	voice.ptt_held = on


## MIC MODE beside the column; the HUD's own touches are off while it is open (a tap outside
## closes it).
func open_voice_popup() -> void:
	if voice_popup != null or voice == null:
		return
	if panel:
		close_panel()
	hud.release_all()
	hud.set_process_input(false)
	var c := button_centers()
	var at: Vector2 = c.get("mic", Vector2(260, 120))
	voice_popup = VoiceButtons.open_popup(self, "mic", at + Vector2(R + 12.0, -R), true)
	voice_popup.tree_exited.connect(func() -> void:
		voice_popup = null
		if hud and is_instance_valid(hud) and panel == null:
			hud.set_process_input(true))


func _on_mic_refused() -> void:
	_say("MICROPHONE NOT ALLOWED: SEE YOUR PHONE'S SETTINGS")


func _say(text: String) -> void:
	_note = text
	_note_t = 1.6


# ---------------------------------------------------------------- chat

func _on_chat(text: String) -> void:
	if feed_muted:
		return
	add_line(String(Game.session.opponent.get("name", "PLAYER")) if Game.session else "PLAYER", text, false)
	Audio.play("ui_click", -6.0)


func add_line(who: String, text: String, mine: bool) -> void:
	feed.append({"who": who, "text": text, "mine": mine, "t": _time})
	while feed.size() > FEED_LINES:
		feed.pop_front()


## Sends a line (a quick message or the text field's): shown in the feed as YOU, else the panel
## says why not (too soon, chat off).
func send(text: String) -> bool:
	var why := Game.session.send_chat(text) if Game.session else "OFF"
	if why == "":
		add_line("YOU", NetChat.clean(text, NetChat.MATCH_MAX), true)
		close_panel()
		return true
	if _panel_note and is_instance_valid(_panel_note):
		_panel_note.text = {"WAIT": "ONE MESSAGE EVERY %d SECONDS" % int(NetChat.RATE_S), "EMPTY": "TYPE A MESSAGE FIRST"}.get(why,
			"CHAT IS OFF")
	return false


func open_panel() -> void:
	if panel or not bool(Game.settings.chat):
		return
	hud.release_all()
	hud.set_process_input(false)          # the panel's buttons and text field get the touches
	panel = PanelContainer.new()
	panel.name = "ChatPanel"
	panel.add_theme_stylebox_override("panel", UI.box(Color(0.06, 0.06, 0.065, 0.9), 10, 1, Color(1, 1, 1, 0.18), 12.0))
	var c := button_centers()
	var at: Vector2 = c.get("talk", c.get("chat", Vector2(240, 40)))
	panel.position = Vector2(clampf(at.x - R * 1.2, 8.0, maxf(size.x - 560.0, 8.0)), at.y + R + 26.0)
	add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	v.add_child(top)
	_field = LineEdit.new()
	_field.name = "ChatField"
	_field.max_length = NetChat.MATCH_MAX
	_field.placeholder_text = "TYPE A MESSAGE"
	_field.custom_minimum_size = Vector2(300, 52)
	_field.virtual_keyboard_enabled = true
	_field.add_theme_font_override("font", UI.font("bold"))
	_field.add_theme_font_size_override("font_size", 20)
	_field.text_submitted.connect(func(t: String) -> void: send(t))
	top.add_child(_field)
	var sb := UI.button("SEND", 18, "primary", Vector2(96, 52))
	sb.name = "ChatSend"
	sb.pressed.connect(func() -> void: send(_field.text))
	top.add_child(sb)
	var x := UI.button("X", 18, "dark", Vector2(56, 52))
	x.name = "ChatClose"
	x.pressed.connect(close_panel)
	top.add_child(x)
	_panel_note = UI.label("QUICK MESSAGES", 15, UI.TEXT_DIM, "bold")
	v.add_child(_panel_note)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	v.add_child(grid)
	for i in NetChat.QUICK.size():
		var q := String(NetChat.QUICK[i])
		var b := UI.button(q, 17, "dark", Vector2(226, 48))
		b.name = "Quick_%d" % i
		b.pressed.connect(func() -> void: send(q))
		grid.add_child(b)


func close_panel() -> void:
	if panel == null:
		return
	panel.queue_free()
	panel = null
	_field = null
	_panel_note = null
	DisplayServer.virtual_keyboard_hide()
	if hud:
		hud.set_process_input(true)


# ---------------------------------------------------------------- drawing

func _process(delta: float) -> void:
	_time += delta
	_note_t = maxf(_note_t - delta, 0.0)
	if voice and voice.ptt_held and not is_visible_in_tree():
		voice.ptt_held = false           # the pause menu or the results came over the HUD: no hidden talking
	queue_redraw()


func ping_ms() -> int:
	if not net:
		return Game.cloud.relay_ping() if Game.cloud != null else -1
	var cloud := Game.session
	if cloud == null:
		return -1
	return cloud.match_ping()


## The tag under the ping (Cloud.link_tag): "DIRECT" while the state goes straight to the other
## phone (NetDirect), else "RELAY".
func link_tag() -> String:
	var cloud := Game.session
	return cloud.link_tag() if cloud != null and net else ""


func _draw() -> void:
	if hud == null or hud.layout.is_empty():
		return
	_draw_ping()
	var c := button_centers()
	for id: String in c:
		_draw_button(id, c[id])
	_draw_speaking(c)
	_draw_feed()
	if _note_t > 0.0 and c.size() > 0:
		var first: Vector2 = c.values()[0]
		HudDraw.text(self, _note, Vector2(first.x - R, first.y + R * 2.0 + 56.0 if c.size() > 2 else first.y + R + 30.0), 15,
			Color(UI.ACCENT, minf(_note_t * 2.0, 1.0)), 0, 3)


## Under the gear, in the column beside the weapon panel (under the panel's right end when the
## layout leaves no such column).
func _draw_ping() -> void:
	var vs := size
	var ms := ping_ms()
	var col := NetPing.color(ms)
	var wp: Dictionary = hud.layout.weapons
	var pr := HudLayout.weapon_main(wp, vs)
	for r: Rect2 in HudLayout.weapon_slots(wp, vs):
		pr = pr.merge(r)
	var right := vs.x - HudLayout.inset.y - 3.0
	var gear: Dictionary = hud.layout.settings
	var gc := HudLayout.center(gear, vs)
	var top := gc.y + HudLayout.radius(gear, vs) + 8.0 if gc.x > pr.end.x else 8.0
	if right - pr.end.x >= 34.0:
		var w := right - pr.end.x - 2.0
		var box := Rect2(right - w, top, w, 66.0)
		draw_rect(box, Color(0, 0, 0, 0.42))
		draw_rect(Rect2(box.position.x, box.end.y - 2.0, box.size.x, 2.0), Color(col, 0.85))
		var bw := 4.0
		var x0 := box.get_center().x - (4 * bw + 3 * 2.5) * 0.5
		for i in 4:
			var bh := 6.0 + 3.5 * i
			var c := col if i < NetPing.bars(ms) else NetPing.UNLIT
			draw_rect(Rect2(x0 + i * (bw + 2.5), top + 22.0 - bh, bw, bh), c)
		HudDraw.text(self, "--" if ms < 0 else str(mini(ms, 999)), Vector2(box.get_center().x, top + 37.0), 17, col, 1, 3)
		HudDraw.text(self, "MS", Vector2(box.get_center().x, top + 54.0), 12, Color(UI.TEXT, 0.85), 1, 3)
		_draw_tag(Vector2(box.get_center().x, box.end.y + 11.0), 1)
	else:
		var w := 112.0
		var box := Rect2(pr.end.x - w, pr.end.y + 6.0, w, 26.0)
		draw_rect(box, Color(0, 0, 0, 0.42))
		NetPing.draw(self, Vector2(box.position.x + 8.0, box.get_center().y), 16.0, ms, 15)
		_draw_tag(Vector2(box.end.x, box.end.y + 11.0), 2)


## The small DIRECT / RELAY tag under the ping (centre or right end at `at`).
func _draw_tag(at: Vector2, align: int) -> void:
	var tag := link_tag()
	HudDraw.text(self, tag, at, 11, Color(NetPing.GREEN if tag == "DIRECT" else UI.TEXT, 0.9), align, 3, "bold")


func _draw_button(id: String, c: Vector2) -> void:
	var on := false
	var crossed := false
	var label := ""
	match id:
		"chat":
			on = panel != null
			label = "CHAT"
		"mute":
			crossed = feed_muted
			label = "MUTED" if feed_muted else "MUTE"
		"talk":
			on = voice != null and voice.ptt_held
			label = "TALK"
		"speaker", "mic":
			on = id == "mic" and (voice_popup != null or NetVoice.speaking(NetVoice.ME))
	HudDraw.disk(self, c, R, Color(0.06, 0.06, 0.07, 0.6 if not on else 0.8))
	HudDraw.ring(self, c, R - 0.75, Color(UI.ACCENT, 0.95) if on else Color(1, 1, 1, 0.35), 2.0 if on else 1.5)
	var ink := UI.ACCENT if on else Color(1, 1, 1, 0.95)
	match id:
		"chat":
			_bubble(c, ink, true)
		"mute":
			_bubble(c, ink, false)
		"talk":
			_mic(c, ink)
		"speaker":
			VoiceButtons.draw_speaker(self, c, R * 0.95, ink, NetVoice.speaker_mode() == NetVoice.OFF, NetVoice.speaker_mode() == NetVoice.GROUP)
		"mic":
			VoiceButtons.draw_mic(self, c, R * 0.95, ink, NetVoice.mic_mode() == NetVoice.OFF, NetVoice.mic_mode() == NetVoice.GROUP)
	if crossed:
		draw_line(c + Vector2(-R * 0.55, -R * 0.55), c + Vector2(R * 0.55, R * 0.55), Color(0, 0, 0, 0.7), 5.0, true)
		draw_line(c + Vector2(-R * 0.55, -R * 0.55), c + Vector2(R * 0.55, R * 0.55), UI.BAD, 3.0, true)
	if label != "":
		HudDraw.text(self, label, c + Vector2(0, R + 9.0), 11, Color(UI.TEXT, 0.9), 1, 3)


## A speech bubble (filled with three dots, or an outline).
func _bubble(c: Vector2, ink: Color, filled: bool) -> void:
	var r := Rect2(c + Vector2(-R * 0.5, -R * 0.42), Vector2(R, R * 0.68))
	var tail := PackedVector2Array([Vector2(r.position.x + R * 0.18, r.end.y - 1.0), Vector2(r.position.x + R * 0.46, r.end.y - 1.0),
		Vector2(r.position.x + R * 0.12, r.end.y + R * 0.26)])
	if filled:
		draw_rect(r, ink)
		draw_colored_polygon(tail, ink)
		for i in 3:
			draw_circle(r.get_center() + Vector2((i - 1) * R * 0.27, 0), R * 0.07, Color(0.06, 0.06, 0.07), true, -1.0, true)
	else:
		draw_rect(r, ink, false, 2.0)
		draw_polyline(PackedVector2Array([tail[0], tail[2], tail[1]]), ink, 2.0, true)


func _mic(c: Vector2, ink: Color) -> void:
	var w := R * 0.34
	var top := c.y - R * 0.5
	draw_circle(Vector2(c.x, top + w * 0.5), w * 0.5, ink, true, -1.0, true)
	draw_rect(Rect2(c.x - w * 0.5, top + w * 0.5, w, R * 0.34), ink)
	draw_circle(Vector2(c.x, top + w * 0.5 + R * 0.34), w * 0.5, ink, true, -1.0, true)
	draw_arc(Vector2(c.x, top + w * 0.5 + R * 0.3), R * 0.33, 0.15, PI - 0.15, 16, ink, 2.0, true)
	draw_line(Vector2(c.x, c.y + R * 0.32), Vector2(c.x, c.y + R * 0.5), ink, 2.0)
	draw_line(Vector2(c.x - R * 0.2, c.y + R * 0.5), Vector2(c.x + R * 0.2, c.y + R * 0.5), ink, 2.0)


## The players speaking now (NetVoice.speaking), under the voice buttons: a sound mark and the name
## (the reference's speaking mark; ours also says who).
func _draw_speaking(c: Dictionary) -> void:
	if voice == null or not c.has("mic"):
		return
	var names := []
	for p: Dictionary in VoiceButtons.channel_players():
		if NetVoice.speaking(String(p.id)):
			names.append(String(p.name))
	if NetVoice.speaking(NetVoice.ME):
		names.push_front("YOU")
	var low: Vector2 = c.get("talk", c.mic)
	var y := low.y + R + 26.0
	for n: String in names:
		var w := HudDraw.text_width(n, 14) + 34.0
		draw_rect(Rect2(low.x - R, y - SPEAK_ROW * 0.5, w, SPEAK_ROW), Color(0, 0, 0, 0.45))
		for i in 3:
			var h := 6.0 + 4.0 * float((i + int(_time * 8.0)) % 3)
			draw_rect(Rect2(low.x - R + 6.0 + i * 5.0, y - h * 0.5, 3.0, h), UI.ACCENT)
		HudDraw.text(self, n, Vector2(low.x - R + 26.0, y), 14, UI.TEXT, 0, 2)
		y += SPEAK_ROW + 4.0


## The feed under the score bar: who (orange: the opponent, blue: you) and the line, wrapped to the
## bar's width, fading out at the end.
func _draw_feed() -> void:
	var sr := hud.score_rect()
	var y := sr.end.y + 14.0
	for e: Dictionary in feed:
		var age := _time - float(e.t)
		if age > FEED_S:
			continue
		var a := clampf(FEED_S - age, 0.0, 1.0)
		var who := String(e.who) + ": "
		var lines := wrap_words(String(e.text), 16, sr.size.x - 24.0 - HudDraw.text_width(who, 16))
		var h := 24.0 * lines.size()
		var w := HudDraw.text_width(who, 16)
		for l: String in lines:
			w = maxf(w, HudDraw.text_width(who, 16) + HudDraw.text_width(l, 16, "semi"))
		var box := Rect2(sr.get_center().x - w * 0.5 - 10.0, y - 2.0, w + 20.0, h + 4.0)
		draw_rect(box, Color(0, 0, 0, 0.45 * a))
		HudDraw.text(self, who, Vector2(box.position.x + 10.0, y + 11.0), 16, Color(UI.BLUE if bool(e.mine) else UI.ORANGE, a), 0, 2)
		for i in lines.size():
			HudDraw.text(self, lines[i], Vector2(box.position.x + 10.0 + HudDraw.text_width(who, 16), y + 11.0 + 24.0 * i), 16,
				Color(UI.TEXT, a), 0, 2, "semi")
		y += h + 8.0


## Words on lines no wider than max_w (a word longer than a line is cut).
static func wrap_words(text: String, font_size: int, max_w: float) -> PackedStringArray:
	var out := PackedStringArray()
	var line := ""
	for word in text.split(" ", false):
		var next := word if line == "" else line + " " + word
		if line != "" and HudDraw.text_width(next, font_size, "semi") > max_w:
			out.append(line)
			line = word
		else:
			line = next
	if line != "" or out.is_empty():
		out.append(line)
	return out

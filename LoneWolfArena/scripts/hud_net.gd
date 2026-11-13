class_name HudNet
extends Control
## The match HUD's network layer (HUD.bind adds it to every match: HudNet.attach). Offline
## (TRAINING GROUND, `net` false) it is only the ping chip: the relay's round trip while this
## phone is connected to it (Cloud.relay_ping), else a grey "--", with no tag. Online (and LOCAL):
##  - beside the gear (top left, right of the minimap's column, the reference's place; under the
##    weapon panel when the player moved the gear to the right): the round trip of the path to the other
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
const IDS := ["speaker", "mic", "talk", "chat", "mute", "quickchat", "marker"]
const SPEAK_ROW := 22.0          # the speaking list's line height
const PING_AT := Vector2(0.278, 0.031)   # the ping's centre, fractions of the screen (the reference's place)

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
## The chat's channel in a DUO / SQUAD with human teammates (team_tabs): "team" (the default: only
## the own team reads it) or "all"; a 1 vs 1 has only "all".
var channel := "all"
var _tabs: Dictionary = {}       # "team" / "all" -> the panel's tab Button
## The quick-chat bubble's panel (HudLayout "quickchat": a round bubble right of the crosshair that
## turns into a round X while open): tabs QUICK (NetChat.QUICK, and in a DUO / SQUAD the team set
## NetChat.TEAM_QUICK) and STICKERS (NetChat.STICKERS), plus the TEAM / ALL switch with teammates.
## Phrases and stickers go as ids (Cloud.send_quick, send_sticker). MARKER (HudLayout "marker",
## DUO / SQUAD with teammates): a map marker where the crosshair points (Cloud.send_marker), shown
## to the team as a diamond in the player's colour with its distance, kept on screen at the edges.
var bubble: PanelContainer
var bubble_tab := "quick"
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
	cloud.chat_from.connect(_on_chat_from)
	cloud.sticker_from.connect(_on_sticker)
	channel = "team" if team_tabs() else "all"
	voice = NetVoice.hub()
	voice.mic_refused.connect(_on_mic_refused)


func _exit_tree() -> void:
	var cloud := Game.session
	if cloud and net:
		if cloud.chat_from.is_connected(_on_chat_from):
			cloud.chat_from.disconnect(_on_chat_from)
		if cloud.sticker_from.is_connected(_on_sticker):
			cloud.sticker_from.disconnect(_on_sticker)
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
		"quickchat":
			return bool(Game.settings.chat) and hud != null and hud.layout.has("quickchat")
		"marker":
			return team_tabs() and hud != null and hud.layout.has("marker")
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
	elif lay.has("settings"):
		# No voice buttons, and the gear in this column (the reference's place, right of the
		# minimap): CHAT and MUTE go below it.
		var gear: Dictionary = lay.settings
		var gc := HudLayout.center(gear, vs)
		if absf(gc.x - col_x) < R * 2.0 + pitch.x:
			y0 = maxf(y0, gc.y + HudLayout.touch_radius(gear, vs) * 1.15 + R * 1.15 + 6.0)
	var x0 := col_x
	if x0 + R > size.x * 0.5 - 10.0 and mr.position.x > size.x * 0.5:
		x0 = mr.position.x - GAP - R * 1.15
	var i := 0
	for id: String in ["chat", "mute"]:
		if shown(id):
			out[id] = Vector2(x0, y0 + i * pitch.y)
			i += 1
	for id: String in ["quickchat", "marker"]:
		if shown(id):
			out[id] = HudLayout.center(lay[id], vs)
	return out


func button_at(pos: Vector2) -> String:
	var c := button_centers()
	for id: String in c:
		if pos.distance_to(c[id]) <= _radius(id) * 1.15:
			return id
	return ""


## A button's radius: the layout's for the bubble and the marker, else R.
func _radius(id: String) -> float:
	if id in ["quickchat", "marker"] and hud != null and hud.layout.has(id):
		return maxf(HudLayout.touch_radius(hud.layout[id], size if size.x > 0.0 else Vector2(1560, 720)), R * 0.9)
	return R


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
			elif bubble != null and not bubble.get_global_rect().has_point(t.position):
				close_bubble()
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
		"quickchat":
			if bubble:
				close_bubble()
			else:
				open_bubble()
		"marker":
			place_marker()


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

## Whether the chat has TEAM and ALL: a DUO / SQUAD match with human teammates (Cloud.voice_mates:
## an all-human match's own side, or the two-phone co-op's other phone).
func team_tabs() -> bool:
	var s: Cloud = Game.session
	return net and s != null and s.in_session and s.voice_mates() > 0


## A match chat line with its sender (Cloud.chat_from): never from a muted or blocked player, nor
## while the feed is muted. A teammate's line carries its number (the team list's colour), an
## enemy's (ALL) the enemy orange and a small ALL tag.
func _on_chat_from(text: String, from_id: String, team_only: bool) -> void:
	if feed_muted or NetVoice.is_muted(from_id) or Game.is_blocked(from_id):
		return
	var s: Cloud = Game.session
	var who := "PLAYER"
	var num := 0
	var mate := s != null and s.voice_mate(from_id)
	if s != null and s.session_multi:
		var mine_team := -1
		for e: Dictionary in s.session_roster:
			if String(e.get("id", "")) == s.my_id:
				mine_team = int(e.get("team", -1))
		var n := 0
		for e: Dictionary in s.session_roster:
			if int(e.get("team", -2)) == mine_team:
				n += 1
				if String(e.get("id", "")) == from_id:
					num = n
			if String(e.get("id", "")) == from_id:
				who = String(e.get("name", who))
	elif s != null:
		who = String(s.opponent.get("name", who))
		num = 2 if mate else 0
	add_line(who, text, false, num if mate else 0, not team_only and team_tabs())
	Audio.play("ui_click", -6.0)


## A feed line: `num` the teammate's number (0: none), `all` an ALL line from the other team (tagged).
func add_line(who: String, text: String, mine: bool, num := 0, all := false) -> void:
	feed.append({"who": who, "text": text, "mine": mine, "t": _time, "num": num, "all": all})
	while feed.size() > FEED_LINES:
		feed.pop_front()


## Sends a line (a quick message or the text field's): shown in the feed as YOU, else the panel
## says why not (too soon, chat off).
func send(text: String) -> bool:
	var why := Game.session.send_chat(text, team_tabs() and channel == "team") if Game.session else "OFF"
	if why == "":
		add_line("YOU", NetChat.clean(text, NetChat.MATCH_MAX), true)
		close_panel()
		return true
	if _panel_note and is_instance_valid(_panel_note):
		_panel_note.text = {"WAIT": "ONE MESSAGE EVERY %d SECONDS" % int(NetChat.RATE_S), "EMPTY": "TYPE A MESSAGE FIRST", "NO TEAM": "NO TEAMMATE TO READ IT"}.get(why,
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
	_tabs = {}
	if team_tabs():
		# TEAM first (the default), then ALL: where the next line goes.
		var tabs := HBoxContainer.new()
		tabs.name = "ChatTabs"
		tabs.add_theme_constant_override("separation", 6)
		v.add_child(tabs)
		for ch: String in ["team", "all"]:
			var tb := UI.button(ch.to_upper(), 17, "primary" if channel == ch else "dark", Vector2(110, 40))
			tb.name = "Tab_" + ch
			tb.pressed.connect(func() -> void: set_channel(ch))
			tabs.add_child(tb)
			_tabs[ch] = tb
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	v.add_child(top)
	_field = LineEdit.new()
	_field.name = "ChatField"
	_field.max_length = NetChat.MATCH_MAX
	_field.placeholder_text = "TYPE A MESSAGE" if _tabs.is_empty() else ("MESSAGE TO YOUR TEAM" if channel == "team" else "MESSAGE TO EVERYONE")
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


## TEAM or ALL for the next line (the panel's tabs).
func set_channel(ch: String) -> void:
	if not ch in ["team", "all"] or (ch == "team" and not team_tabs()):
		return
	channel = ch
	for k: String in _tabs:
		var b: Button = _tabs[k]
		if is_instance_valid(b):
			_restyle(b, "primary" if k == ch else "dark")
	if _field and is_instance_valid(_field):
		_field.placeholder_text = "MESSAGE TO YOUR TEAM" if ch == "team" else "MESSAGE TO EVERYONE"


## A button takes another UI.button style (its boxes and text colours).
static func _restyle(b: Button, style: String) -> void:
	var tmp := UI.button(b.text, 17, style, b.custom_minimum_size)
	for st: String in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		b.add_theme_stylebox_override(st, tmp.get_theme_stylebox(st))
	for st: String in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(st, tmp.get_theme_color(st))
	b.add_theme_font_override("font", tmp.get_theme_font("font"))
	b.add_theme_font_size_override("font_size", tmp.get_theme_font_size("font_size"))
	tmp.free()


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


# ---------------------------------------------------------------- quick-chat bubble and marker

## A sticker from a player (Cloud.sticker_from): a feed line with its name and the sticker's icon.
func _on_sticker(id: int, from_id: String) -> void:
	if feed_muted or NetVoice.is_muted(from_id) or Game.is_blocked(from_id) or not NetChat.sticker_ok(id):
		return
	_on_chat_from(String(NetChat.STICKERS[id]), from_id, false)
	if not feed.is_empty():
		feed[feed.size() - 1]["stk"] = id


## The bubble's panel (x 0.405-0.61, y 0.32-0.81 of the screen): a tab column (QUICK, STICKERS and,
## with teammates, TEAM / ALL) and the tab's big rows.
func open_bubble() -> void:
	if bubble or not bool(Game.settings.chat):
		return
	if panel:
		close_panel()
	hud.release_all()
	hud.set_process_input(false)
	var vs := size if size.x > 0.0 else Vector2(1560, 720)
	bubble = PanelContainer.new()
	bubble.name = "QuickBubble"
	bubble.add_theme_stylebox_override("panel", UI.box(Color(0.05, 0.05, 0.06, 0.92), 10, 1, Color(1, 1, 1, 0.16), 8.0))
	bubble.position = Vector2(vs.x * 0.405, vs.y * 0.32)
	bubble.custom_minimum_size = Vector2(vs.x * 0.205, vs.y * 0.49)
	bubble.size = bubble.custom_minimum_size
	add_child(bubble)
	_fill_bubble()


func _fill_bubble() -> void:
	for c in bubble.get_children():
		bubble.remove_child(c)
		c.queue_free()
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	bubble.add_child(h)
	var tabs := VBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	h.add_child(tabs)
	var list := [["quick", "QUICK"], ["stickers", "STICK"]]
	for t: Array in list:
		var key := String(t[0])
		var b := UI.button(String(t[1]), 12, "primary" if bubble_tab == key else "dark", Vector2(64, 52))
		b.name = "BubbleTab_" + key
		b.pressed.connect(func() -> void:
			bubble_tab = key
			_fill_bubble())
		tabs.add_child(b)
	if team_tabs():
		var sw := UI.button("TEAM" if channel == "team" else "ALL", 12, "light", Vector2(64, 52))
		sw.name = "BubbleChannel"
		sw.pressed.connect(func() -> void:
			set_channel("all" if channel == "team" else "team")
			_fill_bubble())
		tabs.add_child(sw)
	var sc := ScrollContainer.new()
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	UI.style_scroll(sc)
	h.add_child(sc)
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 6)
	sc.add_child(rows)
	if bubble_tab == "stickers":
		var grid := GridContainer.new()
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 6)
		grid.add_theme_constant_override("v_separation", 6)
		rows.add_child(grid)
		for i in NetChat.STICKERS.size():
			var b := Button.new()
			b.name = "Sticker_%d" % i
			b.custom_minimum_size = Vector2(76, 76)
			b.focus_mode = Control.FOCUS_NONE
			b.add_theme_stylebox_override("normal", UI.box(Color(1, 1, 1, 0.06), 8, 0, Color.TRANSPARENT, 0.0))
			b.add_theme_stylebox_override("pressed", UI.box(Color(UI.ACCENT, 0.3), 8, 0, Color.TRANSPARENT, 0.0))
			b.add_theme_stylebox_override("hover", UI.box(Color(1, 1, 1, 0.1), 8, 0, Color.TRANSPARENT, 0.0))
			var id := i
			b.draw.connect(func() -> void: draw_sticker(b, b.size * 0.5, 28.0, id))
			b.pressed.connect(func() -> void: send_sticker(id))
			grid.add_child(b)
		UI.drag_scroll(sc, rows)
		return
	var ids: Array = []
	if team_tabs():
		for i in NetChat.TEAM_QUICK.size():
			ids.append(NetChat.TEAM_BASE + i)
	for i in NetChat.QUICK.size():
		ids.append(i)
	for id: int in ids:
		var b := UI.button(NetChat.quick_text(id), 15, "dark", Vector2(0, 48))
		b.name = "BubbleQuick_%d" % id
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(func() -> void: send_quick(id))
		rows.add_child(b)
	UI.drag_scroll(sc, rows)


func close_bubble() -> void:
	if bubble == null:
		return
	bubble.queue_free()
	bubble = null
	if hud and panel == null:
		hud.set_process_input(true)


## A quick phrase by id from the bubble (TEAM or ALL as the switch says): shown as YOU in the feed.
func send_quick(id: int) -> bool:
	var why := Game.session.send_quick(id, team_tabs() and channel == "team") if Game.session else "OFF"
	if why == "":
		add_line("YOU", NetChat.quick_text(id), true)
		close_bubble()
		return true
	_say({"WAIT": "ONE MESSAGE EVERY %d SECONDS" % int(NetChat.RATE_S), "NO TEAM": "NO TEAMMATE TO READ IT"}.get(why, "CHAT IS OFF"))
	return false


func send_sticker(id: int) -> bool:
	var why := Game.session.send_sticker(id) if Game.session else "OFF"
	if why == "":
		add_line("YOU", String(NetChat.STICKERS[id]), true)
		feed[feed.size() - 1]["stk"] = id
		close_bubble()
		return true
	_say("ONE MESSAGE EVERY %d SECONDS" % int(NetChat.RATE_S) if why == "WAIT" else "CHAT IS OFF")
	return false


## MARKER: the first ground or wall point under the crosshair within Cloud.MARKER_MAX_M, to the team.
func place_marker() -> void:
	var p: Variant = aim_point()
	if p == null:
		_say("NOTHING TO MARK THERE")
		return
	var why := Game.session.send_marker(p as Vector3) if Game.session else "OFF"
	if why == "WAIT":
		_say("ONE MARKER EVERY %d SECONDS" % int(Cloud.MARKER_EVERY_MS / 1000))
	elif why == "":
		_say("MARKED")


## The point the crosshair is on (a ray from the camera through the screen's centre to the first
## body that is not the player, at most Cloud.MARKER_MAX_M from the player), or null.
func aim_point() -> Variant:
	var cam := get_viewport().get_camera_3d()
	if cam == null or hud == null or hud.player == null:
		return null
	var vs := get_viewport_rect().size
	var from := cam.project_ray_origin(vs * 0.5)
	var to := from + cam.project_ray_normal(vs * 0.5) * (Cloud.MARKER_MAX_M + from.distance_to(hud.player.global_position))
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [hud.player.get_rid()]
	var hit := hud.player.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty() or (hit.position as Vector3).distance_to(hud.player.global_position) > Cloud.MARKER_MAX_M:
		return null
	return hit.position


## The team's live markers (Cloud.live_markers): a diamond in the player's colour with the distance,
## pinned to the screen's edge when off screen or behind.
func _draw_markers() -> void:
	var s: Cloud = Game.session
	var cam := get_viewport().get_camera_3d()
	if s == null or cam == null or hud == null or hud.player == null:
		return
	var vs := size
	for id: String in s.live_markers():
		var w: Vector3 = s.markers[id].p
		var behind := cam.is_position_behind(w)
		var m := HudTeam.edge_point(cam.unproject_position(w), behind, vs, 48.0)
		var col := HudTeam.slot_color(maxi(member_number(id), 1))
		var c: Vector2 = m.pos
		var d := 13.0
		var pts := PackedVector2Array([c + Vector2(0, -d), c + Vector2(d, 0), c + Vector2(0, d), c + Vector2(-d, 0)])
		draw_colored_polygon(pts, Color(0, 0, 0, 0.45))
		var inner := PackedVector2Array()
		for q in pts:
			inner.append(c + (q - c) * 0.72)
		draw_colored_polygon(inner, col)
		HudDraw.text(self, "%d M" % roundi(hud.player.global_position.distance_to(w)), c + Vector2(0, d + 11.0), 12, UI.TEXT, 1, 3, "bold")


## A teammate's number in the team list's order (1..; 0 for anyone else; this phone counts too).
func member_number(id: String) -> int:
	var s: Cloud = Game.session
	if s == null:
		return 0
	if not s.session_multi:
		return 1 if id == s.my_id else (2 if s.voice_mate(id) else 0)
	var mine := -1
	for e: Dictionary in s.session_roster:
		if String(e.get("id", "")) == s.my_id:
			mine = int(e.get("team", -1))
	var n := 0
	for e: Dictionary in s.session_roster:
		if int(e.get("team", -2)) == mine:
			n += 1
			if String(e.get("id", "")) == id:
				return n
	return 0


## One of our own stickers (NetChat.STICKERS) drawn at `c`, radius `r`: a round face or a hand.
static func draw_sticker(ci: CanvasItem, c: Vector2, r: float, id: int) -> void:
	var face := Color(1.0, 0.8, 0.22)
	var ink := Color(0.12, 0.08, 0.05)
	match id:
		0:      # thumbs up: a fist with the thumb raised
			ci.draw_rect(Rect2(c + Vector2(-r * 0.55, -r * 0.05), Vector2(r * 1.0, r * 0.75)), face)
			ci.draw_rect(Rect2(c + Vector2(-r * 0.2, -r * 0.8), Vector2(r * 0.32, r * 0.8)), face)
			ci.draw_rect(Rect2(c + Vector2(-r * 0.85, r * 0.0), Vector2(r * 0.25, r * 0.65)), Color(0.3, 0.6, 1.0))
		4:      # wave: an open hand
			ci.draw_circle(c + Vector2(0, r * 0.25), r * 0.5, face)
			for i in 4:
				ci.draw_rect(Rect2(c + Vector2(-r * 0.48 + i * r * 0.26, -r * 0.75), Vector2(r * 0.2, r * 0.75)), face)
			ci.draw_arc(c + Vector2(r * 0.2, -r * 0.2), r * 1.0, -1.2, -0.4, 8, Color(1, 1, 1, 0.7), 2.0)
		5:      # GG on a round badge
			ci.draw_circle(c, r, Color(0.3, 0.75, 0.45))
			HudDraw.text(ci, "GG", c + Vector2(0, 1), int(r * 0.9), Color.WHITE, 1, 2, "heavy")
		_:
			ci.draw_circle(c, r, face)
			var eye_y := c.y - r * 0.2
			match id:
				1:  # laugh: closed eyes, a wide open mouth
					for sx in [-1.0, 1.0]:
						ci.draw_arc(Vector2(c.x + sx * r * 0.35, eye_y + 2.0), r * 0.16, PI, TAU, 8, ink, 2.5)
					ci.draw_colored_polygon(PackedVector2Array([c + Vector2(-r * 0.5, r * 0.1), c + Vector2(r * 0.5, r * 0.1),
						c + Vector2(0, r * 0.62)]), ink)
				2:  # angry: slanted brows, a flat mouth, red cheeks
					ci.draw_circle(c, r, Color(0.95, 0.45, 0.25))
					ci.draw_line(Vector2(c.x - r * 0.55, eye_y - r * 0.2), Vector2(c.x - r * 0.15, eye_y), ink, 3.0)
					ci.draw_line(Vector2(c.x + r * 0.55, eye_y - r * 0.2), Vector2(c.x + r * 0.15, eye_y), ink, 3.0)
					ci.draw_line(c + Vector2(-r * 0.35, r * 0.4), c + Vector2(r * 0.35, r * 0.4), ink, 3.0)
				3:  # cry: tears under the eyes, a sad mouth
					for sx in [-1.0, 1.0]:
						ci.draw_circle(Vector2(c.x + sx * r * 0.35, eye_y), r * 0.1, ink)
						ci.draw_rect(Rect2(c.x + sx * r * 0.35 - r * 0.07, eye_y + r * 0.12, r * 0.14, r * 0.45), Color(0.35, 0.65, 1.0))
					ci.draw_arc(c + Vector2(0, r * 0.62), r * 0.32, PI + 0.4, TAU - 0.4, 10, ink, 3.0)


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
	_draw_markers()
	_draw_feed()
	if _note_t > 0.0 and c.size() > 0:
		var first: Vector2 = c.values()[0]
		HudDraw.text(self, _note, Vector2(first.x - R, first.y + R * 2.0 + 56.0 if c.size() > 2 else first.y + R + 30.0), 15,
			Color(UI.ACCENT, minf(_note_t * 2.0, 1.0)), 0, 3)


## Beside the gear when it sits on the left (the default, the reference's place: HudLayout.ping_spot,
## about PING_AT); a gear moved to the right: under the weapon panel's right end. The wifi mark and
## the number, no plate, the DIRECT / RELAY tag under it.
func _draw_ping() -> void:
	var vs := size
	var ms := ping_ms()
	var col := NetPing.color(ms)
	var chip := HudLayout.ping_box(hud.layout.settings, vs, hud.score_rect())
	if not chip.is_empty():
		# Beside the gear (the reference's place): the wifi mark and the number, the DIRECT / RELAY
		# tag under; clear of the score bar (HudLayout.ping_box: compact, the number under the mark).
		var spot: Vector2 = chip.pos
		var h := float(chip.h)
		if bool(chip.compact):
			NetPing.draw(self, spot, h, ms, 12, 1.0, true)
			HudDraw.text(self, NetPing.label(ms), Vector2(spot.x, spot.y + h * 0.5 + 10.0), 12, col, 0, 3, "bold")
			_draw_tag(Vector2(spot.x, spot.y + h * 0.5 + 23.0), 0)
			return
		NetPing.draw(self, spot, h, ms, 15)
		_draw_tag(Vector2(spot.x, spot.y + h * 0.5 + 9.0), 0)
		return
	# A gear the player moved to the right: under the weapon panel's right end.
	var wp: Dictionary = hud.layout.weapons
	var pr := HudLayout.weapon_main(wp, vs)
	for r: Rect2 in HudLayout.weapon_slots(wp, vs):
		pr = pr.merge(r)
	var h2 := clampf(vs.y * 0.025, 14.0, 24.0)
	var c := Vector2(pr.end.x - h2 * 1.6, pr.end.y + h2)
	NetPing.draw(self, Vector2(c.x - h2 * 1.5, c.y), h2, ms, int(round(h2 * 0.9)))
	_draw_tag(Vector2(c.x, c.y + h2 * 0.5 + 10.0), 1)


## The small DIRECT / RELAY tag under the ping (centre or right end at `at`).
func _draw_tag(at: Vector2, align: int) -> void:
	var tag := link_tag()
	HudDraw.text(self, tag, at, 10, Color(NetPing.GREEN if tag == "DIRECT" else UI.TEXT, 0.85), align, 3, "bold")


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
	if id in ["quickchat", "marker"]:
		_draw_round(id, c)
		return
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
	if id == "mic" and voice != null and voice.capturing and voice.no_input:
		HudDraw.text(self, NetVoice.NO_INPUT_NOTE, c + Vector2(0, R + 10.0), 11, UI.BAD, 1, 3, "bold")


## The quick-chat bubble (a round X while its panel is open) and the marker (a map pin's diamond).
func _draw_round(id: String, c: Vector2) -> void:
	var r := _radius(id)
	var open := id == "quickchat" and bubble != null
	HudDraw.disk(self, c, r, Color(0.06, 0.06, 0.07, 0.8 if open else 0.55))
	HudDraw.ring(self, c, r - 0.75, Color(UI.ACCENT, 0.95) if open else Color(1, 1, 1, 0.4), 2.0)
	var ink := Color(1, 1, 1, 0.95)
	if open:
		var k := r * 0.36
		draw_line(c + Vector2(-k, -k), c + Vector2(k, k), UI.ACCENT, 3.0, true)
		draw_line(c + Vector2(-k, k), c + Vector2(k, -k), UI.ACCENT, 3.0, true)
	elif id == "quickchat":
		var b := Rect2(c + Vector2(-r * 0.45, -r * 0.36), Vector2(r * 0.9, r * 0.6))
		draw_rect(b, ink)
		draw_colored_polygon(PackedVector2Array([Vector2(b.position.x + r * 0.15, b.end.y), Vector2(b.position.x + r * 0.42, b.end.y),
			Vector2(b.position.x + r * 0.08, b.end.y + r * 0.24)]), ink)
		for i in 3:
			draw_circle(b.get_center() + Vector2((i - 1) * r * 0.24, 0), r * 0.065, Color(0.06, 0.06, 0.07), true, -1.0, true)
	else:
		var d := r * 0.42
		var top := c + Vector2(0, -r * 0.12)
		draw_colored_polygon(PackedVector2Array([top + Vector2(0, -d), top + Vector2(d * 0.8, 0), top + Vector2(0, d), top + Vector2(-d * 0.8, 0)]),
			HudTeam.slot_color(maxi(member_number(Game.session.my_id if Game.session else ""), 1)))
		draw_line(top + Vector2(0, d), c + Vector2(0, r * 0.62), ink, 2.0)


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
		var num := int(e.get("num", 0))
		var tag := "ALL" if bool(e.get("all", false)) else ""
		# [n] (the teammate's number box) or a small ALL tag, then NAME: and the line
		var lead := 0.0 if num == 0 and tag == "" else (24.0 if num > 0 else HudDraw.text_width(tag, 11) + 10.0) + 6.0
		var stk := int(e.get("stk", -1))
		var who := String(e.who) + ": "
		var who_w := lead + HudDraw.text_width(who, 16)
		var lines := wrap_words(String(e.text), 16, sr.size.x - 24.0 - who_w)
		if stk >= 0:
			lines = PackedStringArray([""])
		var h := 24.0 * lines.size()
		var w := who_w
		for l: String in lines:
			w = maxf(w, who_w + HudDraw.text_width(l, 16, "semi"))
		var box := Rect2(sr.get_center().x - w * 0.5 - 10.0, y - 2.0, w + 20.0, h + 4.0)
		draw_rect(box, Color(0, 0, 0, 0.45 * a))
		var x := box.position.x + 10.0
		if num > 0:
			draw_rect(Rect2(x, y + 1.0, 22.0, 20.0), Color(HudTeam.slot_color(num), a))
			HudDraw.text(self, str(num), Vector2(x + 11.0, y + 11.0), 14, Color(0.05, 0.05, 0.06, a), 1, 0, "bold")
		elif tag != "":
			var tw := HudDraw.text_width(tag, 11) + 10.0
			draw_rect(Rect2(x, y + 3.0, tw, 16.0), Color(UI.ORANGE, 0.85 * a))
			HudDraw.text(self, tag, Vector2(x + tw * 0.5, y + 11.0), 11, Color(0.05, 0.05, 0.06, a), 1, 0, "bold")
		var ink: Color = UI.BLUE if bool(e.mine) else (HudTeam.slot_color(num) if num > 0 else UI.ORANGE)
		HudDraw.text(self, who, Vector2(x + lead, y + 11.0), 16, Color(ink, a), 0, 2)
		if stk >= 0:
			# (a sticker: its icon, 0.06 of the screen's height, after the name)
			var ir := size.y * 0.03
			draw_rect(Rect2(box.end.x, box.position.y, ir * 2.0 + 8.0, maxf(box.size.y, ir * 2.0 + 4.0)), Color(0, 0, 0, 0.45 * a))
			draw_sticker(self, Vector2(box.end.x + ir + 4.0, box.position.y + maxf(box.size.y, ir * 2.0 + 4.0) * 0.5), ir, stk)
			h = maxf(h, ir * 2.0)
		else:
			for i in lines.size():
				HudDraw.text(self, lines[i], Vector2(box.position.x + 10.0 + who_w, y + 11.0 + 24.0 * i), 16,
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

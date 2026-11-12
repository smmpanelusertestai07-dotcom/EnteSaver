class_name HowToPlay
extends RefCounted
## HOW TO PLAY: the game's help, in our own words (no tutorial levels, no web page). SETTINGS opens
## it from the HOW TO PLAY button under its tabs, in the lobby and in a match (SettingsPanel
## `open_help()`): MODES across the top, then MOVE & LOOK beside ITEMS and THE MATCH.
## Node names: HowToScroll (the page), HowToModes (the two modes side by side).

## Texts may hold {rounds} (Game.ROUNDS_TO_WIN). MODES spans the width on top, the other groups
## fill two columns under it: [icon, title, text].
const MODES := ["MODES", [
	["v_crosshair", "TRAINING GROUND", "1 vs a bot (EASY, NORMAL or HARD, picked in SELECT MODE), first to {rounds} rounds on CARGO CAGE. Or the TARGET DUMMY: it never goes down, no zone, no clock, nothing counted; CHANGE GUN on the weapon panel switches guns."],
	["v_player", "LONE WOLF", "1 vs 1 online against another player, first to {rounds}. START opens the ONLINE list: duel a player online, a friend or a CUSTOM ROOM."],
]]
const GROUPS := [
	["MOVE & LOOK", [
		["stance_sprint", "MOVE", "Left thumb on the joystick. Push it past the ring to sprint."],
		["v_eye", "LOOK  ·  FREE LOOK", "Drag on the right side to turn the camera. With the free look button on (SETTINGS, CONTROLS), hold the eye and drag to look all around, even at your own face."],
		["v_fire", "FIRE", "Hold the big button to shoot; keep holding and drag to aim while firing."],
		["v_scope", "SCOPE", "Aim down the red dot, or the sniper scope with a sniper rifle."],
		["stance_crouch", "CROUCH · PRONE · JUMP", "Crouch and prone make you a smaller target; jump onto crates."],
		["v_reload", "RELOAD", "Tap RELOAD beside FIRE or the weapon panel (or it reloads by itself when the magazine is empty)."],
		["v_fist", "SWITCH  ·  FISTS", "SWITCH swaps the gun and the fists (it shows the other one). Fists out you run 15 % faster."],
	]],
	["ITEMS", [
		["v_medkit", "MEDKIT  x2", "+75 HP over 4 seconds. You walk slower; firing cancels it."],
		["v_wall", "SHIELD WALL  x3", "Tap it, then FIRE: frozen-foam cover that soaks 600 damage for 45 seconds."],
		["item_grenade", "FRAG GRENADE  x1", "Tap it, then FIRE to throw along the arc. Up to 150 damage (a vest stops a third), 3 s fuse."],
	]],
	["THE MATCH", [
		["v_player", "FIRST TO {rounds} ROUNDS", "1 vs 1, 200 HP each, Lv2 helmet and vest. Win {rounds} rounds to win the match."],
		["v_timer", "PICK THE GUN", "Every 2 rounds one side picks the gun you both use in the 15 s prep (12 guns, fixed attachments); the pick takes turns. A gun picked rests for the 4 rounds after."],
		["v_zone", "SAFE ZONE", "A round has two stages on the clock: 20 s with the zone over the whole hall, then 90 s (SQUAD 120 s) while it closes to a spot. Outside it you lose HP; at time-out more HP wins."],
	]],
]


## The whole page in a scroll box that fills the height it is given (a finger drag that starts on
## an item scrolls it).
static func page() -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.name = "HowToScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	UI.style_scroll(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 6)
	scroll.add_child(body)
	body.add_child(UI.section(String(MODES[0]), 18))
	var modes := HBoxContainer.new()
	modes.name = "HowToModes"
	modes.add_theme_constant_override("separation", 24)
	body.add_child(modes)
	for it: Array in MODES[1]:
		var item := _item(String(it[0]), rounds_text(String(it[1])), rounds_text(String(it[2])))
		item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		modes.add_child(item)
	body.add_child(UI.spacer(6))
	var cols := HBoxContainer.new()
	cols.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 24)
	body.add_child(cols)
	var left := VBoxContainer.new()
	var right := VBoxContainer.new()
	for col: VBoxContainer in [left, right]:
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_theme_constant_override("separation", 6)
		cols.add_child(col)
	for gi in GROUPS.size():
		var g: Array = GROUPS[gi]
		var col := left if gi == 0 else right
		if gi > 1:
			col.add_child(UI.spacer(6))
		col.add_child(UI.section(String(g[0]), 18))
		for it: Array in g[1]:
			col.add_child(_item(String(it[0]), rounds_text(String(it[1])), rounds_text(String(it[2]))))
	UI.drag_scroll(scroll, body)
	return scroll


## A help text with {rounds} filled in (the rounds a match is played to).
static func rounds_text(t: String) -> String:
	return t.format({"rounds": Game.ROUNDS_TO_WIN})


static func _item(icon_name: String, title: String, text: String) -> Control:
	var p := PanelContainer.new()
	var st := UI.chamfer(Color(1, 1, 1, 0.045), 6, 0, Color.TRANSPARENT, 10.0, ["br"])
	st.content_margin_top = 5
	st.content_margin_bottom = 5
	p.add_theme_stylebox_override("panel", st)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	var ic := PanelContainer.new()
	var ics := UI.box(Color(0, 0, 0, 0.45), 21, 1, Color(1, 1, 1, 0.18), 0.0)
	ics.set_content_margin_all(7)
	ic.add_theme_stylebox_override("panel", ics)
	ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ic.add_child(UI.icon(icon_name, 28, UI.TEXT))
	h.add_child(ic)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", -3)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(UI.label(title, 17, UI.ACCENT, "bold"))
	var t := UI.label(text, 15, UI.TEXT, "semi")
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	t.custom_minimum_size = Vector2(380, 0)
	v.add_child(t)
	h.add_child(v)
	p.add_child(h)
	return p

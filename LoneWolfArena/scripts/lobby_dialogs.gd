class_name LobbyDialogs
extends RefCounted
## The lobby's popups: the popup frame they share (open_modal / close_modal, one at a time, in
## `modal`; back() is the header X and Android back: a popup's own way back, else close), the
## full pages' frame (open_page: FRIENDS, SELECT MODE, HOW TO PLAY from it), SELECT MODE (a full
## page with the mode cards, TRAINING GROUND's opponent chips and the other ways to play; the "?" on
## each card opens that mode's picture help, mode_help: scripts/mode_help.gd), the player name editor with the first-start name
## prompt, a confirmation (confirm()), a message with one OK (notice()) and the "Quit the game?"
## dialog. The lobby makes it (Lobby.dialogs) and its parts open popups through it; everything is
## built under the lobby's UI layer. (HOW TO PLAY is in SETTINGS, and on SELECT MODE's bottom row:
## scripts/how_to_play.gd.)
## Node names: Modal (or QuitDialog) with its Frame (a page: PageBg, PageTitle, PageTabs, PageFoot,
## PageBody), Close, ModeTabs / ModeTab, ModeCards, Mode_<training|lonewolf> (ModeTitle, ModeStart),
## ModeWays with ModeWay_<room|local|help>, Sizes with
## Size_<1|2|4> (SOLO, DUO, SQUAD: on both mode cards; LONE WOLF's SOLO in a group of two reads
## DUEL · YOU VS <NAME>: size_chip_text), Difficulty with
## Diff_<EASY|NORMAL|HARD|DUMMY>, ModeStats, NameEdit, NameRandom, NamePreview, NameOk,
## Help_<training|lonewolf> (the "?" on a card) opening ModeHelp, SizeBox (the mode card's
## team-size box: SizeBoxPanel with SizeTile_<1|2|4>), ConfirmCancel, ConfirmOk, NoticeText, NoticeOk, QuitCancel, QuitConfirm. Markers: "name prompt"
## and "ui name_ok" (the emulator test taps OK there).

## SELECT MODE: what each mode's card says under its name ({rounds}: Game.ROUNDS_TO_WIN).
const MODE_INFO := {
	"training": {"tag": "VS BOT", "lines": ["1 VS A BOT, OR THE TARGET DUMMY TO PRACTISE YOUR AIM:"]},
	"lonewolf": {"tag": "ONLINE", "lines": ["1 VS 1 AGAINST ANOTHER PLAYER", "PLAYERS ONLINE, FRIENDS OR A CUSTOM ROOM"]},
}
## TRAINING GROUND's opponents in SELECT MODE: the bot's levels (Game.DIFFICULTY_NAMES), then the
## target dummy (SOLO only: a team match is always against bots).
const DUMMY := "DUMMY"
## SELECT MODE's size chips (Game.TEAM_SIZES): the players a team, on both mode cards.
const SIZE_NAMES := {1: "SOLO", 2: "DUO", 4: "SQUAD"}

## A popup closed (also when another one replaces it): a challenge that waited shows then.
signal modal_closed

var lobby: Lobby
## The open popup (node "Modal", or "QuitDialog"); null when none is open.
var modal: Control


func _init(owner_lobby: Lobby) -> void:
	lobby = owner_lobby


# ---------------------------------------------------------------- the popup frame

## A popup in the reference look: the light header strip (dark caps title, hazard line, X on a
## dark tile), then the near-black body with a yellow corner mark. Returns the body column.
## top: the frame sits at the top of the screen, clear of the on-screen keyboard (text entry).
func open_modal(title: String, width := 980.0, top := false) -> VBoxContainer:
	close_modal()
	modal = Control.new()
	modal.name = "Modal"
	UI.full_rect(modal)
	modal.mouse_filter = Control.MOUSE_FILTER_STOP
	lobby.ui.add_child(modal)
	var shade := UI.blur_shade(0.72)         # the lobby blurred and darkened behind (plain at LOW)
	UI.full_rect(shade)
	modal.add_child(shade)
	var frame := VBoxContainer.new()
	frame.name = "Frame"
	frame.add_theme_constant_override("separation", 0)
	frame.anchor_left = 0.5
	frame.anchor_right = 0.5
	frame.anchor_top = 0.0 if top else 0.5
	frame.anchor_bottom = 0.0 if top else 0.5
	frame.offset_left = -width * 0.5
	frame.offset_right = width * 0.5
	frame.offset_top = 18.0 if top else 0.0
	frame.grow_vertical = Control.GROW_DIRECTION_END if top else Control.GROW_DIRECTION_BOTH
	modal.add_child(frame)
	var head := UI.popup_header(title, 26, 56.0)
	(head.get_node("Close") as Button).pressed.connect(back)
	frame.add_child(head)
	var panel := UI.popup_body()
	frame.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	panel.add_child(v)
	modal.modulate.a = 0.0
	modal.create_tween().tween_property(modal, "modulate:a", 1.0, 0.15)
	return v


## A full page in the reference look (FRIENDS): the lobby hidden under the page's dark ramp, the
## title in caps at the top right beside the X box in the corner ("Close": back()), a column of
## boxed side tabs on the left (the returned "tabs" VBox, PAGE_TAB_W wide), a foot strip under it
## ("foot": light buttons such as BLOCKED) and the content column on the right ("body", node
## "PageBody"). One page or popup at a time, in `modal` like a popup.
## side_tabs false (SELECT MODE, HOW TO PLAY): no side tabs or foot strip, the body spans the page;
## with no title the body starts at the top (the page puts its own tab bar there).
const PAGE_TAB_W := 0.16
func open_page(title: String, side_tabs := true) -> Dictionary:
	close_modal()
	modal = Control.new()
	modal.name = "Modal"
	modal.set_meta("page", true)
	UI.full_rect(modal)
	modal.mouse_filter = Control.MOUSE_FILTER_STOP
	lobby.ui.add_child(modal)
	var bg := Control.new()
	bg.name = "PageBg"
	UI.full_rect(bg)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.draw.connect(func() -> void: UI.draw_page_bg(bg, bg.size))
	modal.add_child(bg)
	var inner := Control.new()
	UI.full_rect(inner)
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	modal.add_child(inner)
	UI.keep_clear_of_cutout(inner)
	var corner := UI.page_corner(inner, title, back)      # the X box and the title beside it
	var close := corner[0] as Button
	var t := corner[1] as Label
	var tabs := VBoxContainer.new()
	tabs.name = "PageTabs"
	tabs.add_theme_constant_override("separation", 6)
	tabs.anchor_right = PAGE_TAB_W
	tabs.offset_left = 8
	tabs.offset_top = 92
	tabs.offset_right = -6
	inner.add_child(tabs)
	var foot := VBoxContainer.new()
	foot.name = "PageFoot"
	foot.add_theme_constant_override("separation", 8)
	foot.anchor_top = 1.0
	foot.anchor_bottom = 1.0
	foot.anchor_right = PAGE_TAB_W
	foot.offset_left = 8
	foot.offset_right = -6
	foot.offset_bottom = -14
	foot.grow_vertical = Control.GROW_DIRECTION_BEGIN
	inner.add_child(foot)
	var body := VBoxContainer.new()
	body.name = "PageBody"
	body.add_theme_constant_override("separation", 10)
	body.anchor_left = PAGE_TAB_W
	body.anchor_right = 1.0
	body.anchor_bottom = 1.0
	body.offset_left = 18
	body.offset_right = -22
	body.offset_top = 76
	body.offset_bottom = -14
	inner.add_child(body)
	if not side_tabs:
		tabs.visible = false
		foot.visible = false
		body.anchor_left = 0.0
		body.offset_left = 22
		if title == "":
			body.offset_top = 4
	# the X last, so it is hit-tested before a body that reaches up beside it (no title)
	inner.move_child(close, -1)
	modal.modulate.a = 0.0
	modal.create_tween().tween_property(modal, "modulate:a", 1.0, 0.12)
	return {"tabs": tabs, "foot": foot, "body": body, "title": t}


func close_modal() -> void:
	if modal:
		modal.queue_free()
		modal = null
		DisplayServer.virtual_keyboard_hide()     # a text field in it may have opened the keyboard
		modal_closed.emit()


## The popup's X and Android back: its own way back when it set one (meta "on_back", a Callable:
## a player card goes back to the list it came from, a confirmation to what asked), else close.
func back() -> void:
	if modal == null:
		return
	var to: Variant = modal.get_meta("on_back") if modal.has_meta("on_back") else null
	if to is Callable and (to as Callable).is_valid():
		(to as Callable).call()
	else:
		close_modal()


## A yes / no question in a popup: CANCEL (and X, back) calls on_cancel, else just closes; the
## OK button (yellow, or red when `danger`) calls on_ok after closing.
func confirm(title: String, text: String, ok_text: String, on_ok: Callable, on_cancel := Callable(), danger := false) -> void:
	var v := open_modal(title, 680.0)
	var t := UI.label(text, 20, UI.TEXT, "semi")
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	t.custom_minimum_size = Vector2(600, 0)
	v.add_child(t)
	v.add_child(UI.spacer(4))
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 12)
	v.add_child(row)
	var cancel := UI.button("CANCEL", 20, "light", Vector2(190, 56))
	cancel.name = "ConfirmCancel"
	row.add_child(cancel)
	var ok := UI.button(ok_text, 22, "danger" if danger else "primary", Vector2(210, 56))
	ok.name = "ConfirmOk"
	row.add_child(ok)
	if on_cancel.is_valid():
		modal.set_meta("on_back", on_cancel)
	cancel.pressed.connect(back)
	ok.pressed.connect(func() -> void:
		close_modal()
		on_ok.call())


## A message with one OK (X and back close it too): an online match that was called off, a
## challenge that never got going.
func notice(title: String, text: String) -> void:
	var v := open_modal(title, 680.0)
	var t := UI.label(text, 21, UI.TEXT, "semi")
	t.name = "NoticeText"
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	t.custom_minimum_size = Vector2(600, 0)
	v.add_child(t)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	v.add_child(row)
	var ok := UI.button("OK", 22, "primary", Vector2(190, 56))
	ok.name = "NoticeOk"
	ok.pressed.connect(close_modal)
	row.add_child(ok)


# ---------------------------------------------------------------- select mode

## SELECT MODE (the lobby's mode card opens it): a full page laid out like the reference's mode
## page (open_page without side tabs: the X box top right, Android back closes it). A tab bar at the
## top centre with its one tab MODES (ModeTabs / ModeTab: yellow caps over a yellow underline); the
## two modes as big picture cards side by side (Mode_<m>: the mode's art filling the card, the name
## in big white caps at the lower left, CARGO CAGE and what START plays under it, the size chips,
## TRAINING GROUND's opponent chips, the player's numbers ModeStats, the "?" Help_<m> in the top
## right corner; the picked card has a 2 px yellow frame); and a bottom row of dark buttons with an
## icon and a caps label for the other ways to play (ModeWays: ModeWay_rooms CUSTOM ROOM and
## ModeWay_local PLAY WITHOUT INTERNET open those pages of their own, ModeWay_help HOW TO PLAY opens
## the help as a page whose X and back come back here). A tap on a card picks its mode, which START
## then plays (kept as the setting "mode"), and closes the page; on TRAINING GROUND's card the
## chips pick its opponent too (a bot's level, kept as the setting "difficulty", or the target dummy
## for this session: Game.practice), which also picks TRAINING GROUND. A group member gets a notice
## instead (the leader picks).
const MODE_WAYS := [["rooms", "CUSTOM ROOM", "v_friends"], ["local", "PLAY WITHOUT INTERNET", "v_online"],
	["help", "HOW TO PLAY", "v_info"]]


func select_mode() -> void:
	if LobbyTeam.is_member():
		# In a group the leader picks (Cloud.group's mode / size, shown on the mode card).
		var who := LobbyTeam.leader_name(LobbyTeam.members())
		notice("SELECT MODE", "%s picks the mode while you are in their group: %s %s. EXIT GROUP to pick your own." % [
			who if who != "" else "The leader", Game.mode_name(), String(SIZE_NAMES.get(Game.team_size, "SOLO"))])
		return
	var page := open_page("", false)
	modal.set_meta("mode_page", true)
	var v: VBoxContainer = page.body
	v.add_child(_mode_tabs())
	var row := HBoxContainer.new()
	row.name = "ModeCards"
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 18)
	v.add_child(row)
	for m: String in Game.MODE_NAMES:
		row.add_child(_mode_choice(m))
	var ways := HBoxContainer.new()
	ways.name = "ModeWays"
	ways.alignment = BoxContainer.ALIGNMENT_END
	ways.add_theme_constant_override("separation", 8)
	v.add_child(ways)
	for w: Array in MODE_WAYS:
		ways.add_child(_mode_way(String(w[0]), String(w[1]), String(w[2])))


## The mode page's tab bar (ModeTabs): one tab, MODES (ModeTab), yellow caps over a 3 px yellow
## underline, on a thin line across the top centre (the reference's tab bar, our one tab).
func _mode_tabs() -> Control:
	var bar := Control.new()
	bar.name = "ModeTabs"
	bar.custom_minimum_size = Vector2(0, 60)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.draw.connect(func() -> void:
		var s := bar.size
		var y := s.y - 1.0
		bar.draw_line(Vector2(s.x * 0.28, y), Vector2(s.x * 0.72, y), Color(1, 1, 1, 0.16), 1.0))
	var tab := UI.label("MODES", 28, UI.ACCENT, "heavy")
	tab.name = "ModeTab"
	tab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tab.anchor_left = 0.5
	tab.anchor_right = 0.5
	tab.anchor_bottom = 1.0
	tab.offset_left = -130
	tab.offset_right = 130
	tab.offset_bottom = -4
	tab.draw.connect(func() -> void:
		var w := UI.font("heavy").get_string_size(tab.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 28).x + 48.0
		tab.draw_rect(Rect2((tab.size.x - w) * 0.5, tab.size.y, w, 3), UI.ACCENT))
	bar.add_child(tab)
	return bar


## A button of the mode page's bottom row (ModeWay_<kind>): dark, an icon and a caps label.
func _mode_way(kind: String, text: String, icon_name: String) -> Button:
	var b := UI.button(text, 18, "dark", Vector2(0, 60))
	b.name = "ModeWay_" + kind
	b.icon = UI.icon_texture(icon_name)
	b.add_theme_constant_override("icon_max_width", 28)
	b.add_theme_constant_override("h_separation", 10)
	b.custom_minimum_size.x = maxf(200.0, UI.font("bold").get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x + 84.0)
	b.pressed.connect(func() -> void:
		if kind == "help":
			how_to_play()
		else:
			lobby.friends.open(kind))
	return b


## HOW TO PLAY from the mode page: the help (HowToPlay.page()) as a full page; its X and Android
## back come back to SELECT MODE.
func how_to_play() -> void:
	var page := open_page("HOW TO PLAY", false)
	(page.body as VBoxContainer).add_child(HowToPlay.page())
	modal.set_meta("on_back", select_mode)


## What START plays in a mode at the current team size, for its card on the mode page (the lobby's
## mode card says the same for the picked mode: Lobby.mode_format).
static func start_line(m: String, size := Game.team_size, teams_online := Game.TEAMS_ONLINE) -> String:
	var word := String(SIZE_NAMES.get(size, "SOLO"))
	if m != "training":
		if size == 1:
			return "1 VS 1 ONLINE"
		return "%s  ·  %d VS %d ONLINE" % [word, size, size] if teams_online else "%s: NEXT UPDATE" % word
	var level := String(Game.DIFFICULTY_NAMES[clampi(int(Game.settings.difficulty), 0, Game.DIFFICULTY_NAMES.size() - 1)])
	if size > 1:
		return "%s  ·  BOT: %s" % [word, level]
	if Game.practice and Game.mode == "training":
		return "TARGET DUMMY"
	return "1 VS BOT: %s  ·  FIRST TO %d" % [level, Game.rounds_to_win()]


## What a mode's card in SELECT MODE says under its name for a team size (1 SOLO, 2 DUO, 4 SQUAD):
## the lines of MODE_INFO for SOLO; DUO and SQUAD say who plays whom (TRAINING GROUND: the bot's
## level; LONE WOLF: real players only, never bots, or "NEXT UPDATE" while Game.TEAMS_ONLINE is off).
static func mode_lines(m: String, size: int, teams_online := Game.TEAMS_ONLINE) -> Array:
	if size <= 1:
		var info: Dictionary = MODE_INFO.get(m, MODE_INFO[Game.DEFAULT_MODE])
		return info.lines
	var word := String(SIZE_NAMES.get(size, "DUO"))
	var mates := "A BOT" if size == 2 else "%d BOTS" % (size - 1)
	if m == "lonewolf":
		if not teams_online:
			return ["ONLINE DUO / SQUAD: NEXT UPDATE", "PLAY DUO AND SQUAD IN TRAINING GROUND"]
		return ["%s · %d VS %d · REAL PLAYERS" % [word, size, size], "YOUR GROUP OF FRIENDS, OR PLAYERS FOUND ONLINE"]
	var level := String(Game.DIFFICULTY_NAMES[clampi(int(Game.settings.difficulty), 0, Game.DIFFICULTY_NAMES.size() - 1)])
	return ["%s · YOU + %s VS %d BOTS · BOT: %s" % [word, mates, size, level], "DUMMY IS SOLO ONLY"]


## One mode's card on the mode page (node Mode_<m>): the mode's art filling the card, darkened
## towards its foot where the words sit; a 2 px yellow frame on the current mode. TRAINING GROUND's
## has the opponent chips (row Difficulty); LONE WOLF's keeps their height empty so both cards' names
## and size chips line up.
func _mode_choice(m: String) -> Button:
	var info: Dictionary = MODE_INFO.get(m, MODE_INFO[Game.DEFAULT_MODE])
	var card := Button.new()
	card.name = "Mode_" + m
	card.focus_mode = Control.FOCUS_NONE
	card.custom_minimum_size = Vector2(420, 380)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card.clip_contents = true
	for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		card.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	card.draw.connect(func() -> void:
		var s := card.size
		Lobby.draw_mode_art(card, m, Rect2(Vector2.ZERO, s))
		var y0 := s.y * 0.22
		var y1 := maxf(s.y - 300.0, y0 + 40.0)
		var clear := Color(0.03, 0.025, 0.04, 0.0)
		var dark := Color(0.03, 0.025, 0.04, 0.86)
		card.draw_polygon(PackedVector2Array([Vector2(0, y0), Vector2(s.x, y0), Vector2(s.x, y1), Vector2(0, y1)]),
			PackedColorArray([clear, clear, dark, dark]))
		card.draw_rect(Rect2(0, y1, s.x, s.y - y1), dark)
		if card.is_pressed():
			card.draw_rect(Rect2(Vector2.ZERO, s), Color(0, 0, 0, 0.15))
		if Game.mode == m:
			card.draw_rect(Rect2(Vector2(1, 1), s - Vector2(2, 2)), UI.ACCENT, false, 2.0)
		elif card.is_hovered() or card.is_pressed():
			card.draw_rect(Rect2(Vector2(1, 1), s - Vector2(2, 2)), Color(1, 1, 1, 0.6), false, 2.0)
		else:
			card.draw_rect(Rect2(Vector2(0.5, 0.5), s - Vector2(1, 1)), Color(1, 1, 1, 0.16), false, 1.0))
	for sig in ["mouse_entered", "mouse_exited", "button_down", "button_up"]:
		card.connect(sig, card.queue_redraw)
	card.add_child(_help_button(m))
	var tag := PanelContainer.new()
	tag.add_theme_stylebox_override("panel", UI.chamfer(UI.ACCENT, 6, 0, Color.TRANSPARENT, 8.0, ["br"]))
	tag.add_child(UI.label(String(info.tag), 16, UI.INK, "heavy"))
	tag.position = Vector2(12, 12)
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(tag)
	# The words sit at the card's foot over the darkened art, the numbers on the bottom line.
	var v := VBoxContainer.new()
	v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	v.offset_left = 20
	v.offset_right = -20
	v.offset_bottom = -12
	v.alignment = BoxContainer.ALIGNMENT_END
	v.add_theme_constant_override("separation", 0)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(v)
	var name_l := UI.shadowed(UI.label(Game.mode_name(m), 44, UI.TEXT, "heavy"), Vector2(0, 3), Color(0, 0, 0, 0.7))
	name_l.name = "ModeTitle"
	v.add_child(name_l)
	var where := UI.label("CARGO CAGE  ·  START: %s" % start_line(m), 18, UI.ACCENT, "heavy")
	where.name = "ModeStart"
	UI.ellipsis(where)
	v.add_child(where)
	var lines := mode_lines(m, Game.team_size)
	for i in maxi(lines.size(), 2):         # two lines on both cards: their chips line up
		var l := UI.label(String(lines[i]) if i < lines.size() else " ", 15, Color(UI.TEXT, 0.78), "bold")
		UI.ellipsis(l)
		v.add_child(l)
	v.add_child(UI.spacer(8))
	v.add_child(_size_chips(m))
	v.add_child(UI.spacer(6))
	if m == "training":
		v.add_child(_opponent_chips())
	else:
		var keep := UI.spacer(UI.TOUCH_MIN)
		keep.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(keep)
	v.add_child(UI.spacer(8))
	var n: Dictionary = (Game.profile.modes as Dictionary).get(m, {})
	var stats := UI.label("MATCHES %d   ·   WINS %d   ·   KILLS %d" % [int(n.get("matches", 0)), int(n.get("wins", 0)), int(n.get("kills", 0))],
		15, UI.TEXT_DIM, "bold")
	stats.name = "ModeStats"
	v.add_child(stats)
	card.pressed.connect(func() -> void:
		Audio.play("ui_select", -6.0)
		_pick(m))
	return card


## The "?" at the top right of a mode card's art (node Help_<m>): a small dark disc with a
## yellow "?" on a 56 px touch area; a tap opens the mode's picture help instead of picking it.
func _help_button(m: String) -> Button:
	var b := Button.new()
	b.name = "Help_" + m
	b.focus_mode = Control.FOCUS_NONE
	b.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	b.offset_left = -UI.TOUCH_MIN - 4.0
	b.offset_right = -4.0
	b.offset_top = 4.0
	b.offset_bottom = UI.TOUCH_MIN + 4.0
	for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		b.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	b.draw.connect(func() -> void:
		var c := b.size * 0.5
		var hot := b.is_hovered() or b.is_pressed()
		b.draw_circle(c, 18.0, Color(0, 0, 0, 0.72), true, -1.0, true)
		b.draw_circle(c, 18.0, UI.ACCENT if hot else Color(1, 1, 1, 0.55), false, 2.0, true)
		HudDraw.text(b, "?", c + Vector2(0, 1), 24, UI.ACCENT, 1, 0, "heavy"))
	for sig in ["mouse_entered", "mouse_exited", "button_down", "button_up"]:
		b.connect(sig, b.queue_redraw)
	b.pressed.connect(func() -> void:
		Audio.play("ui_click", -4.0)
		mode_help(m))
	return b


## A mode's picture help (ModeHelp: its pages with dots, arrows and swipe) in a popup; its X and
## Android back go back to the mode page (SELECT MODE).
func mode_help(m: String) -> ModeHelp:
	var v := open_modal("%s · HOW IT PLAYS" % Game.mode_name(m), 980.0)
	var help := ModeHelp.new(m)
	v.add_child(help)
	modal.set_meta("on_back", select_mode)
	return help


## A mode card's team sizes (row Sizes: Size_1 SOLO, Size_2 DUO, Size_4 SQUAD); the current one
## (Game.team_size) is lit. A tap picks the size with the card's mode and closes SELECT MODE; a team
## is never against the target dummy, so DUO and SQUAD pick the bot again.
func _size_chips(m: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "Sizes"
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var group := ButtonGroup.new()
	for n: int in Game.TEAM_SIZES:
		var word := size_chip_text(m, n, LobbyTeam.members())
		var b := _chip(word, "Size_%d" % n, n == Game.team_size, group)
		if word.length() > 8:
			b.add_theme_font_size_override("font_size", 14)
		b.pressed.connect(func() -> void:
			Audio.play("ui_select", -6.0)
			pick_size(m, n))
		row.add_child(b)
	return row


## A team size picked with a mode, from SELECT MODE's chips and the mode card's team-size box
## alike: the size (a team is never against the target dummy, so DUO and SQUAD pick the bot
## again), then the mode as a tap on its card (_pick: kept, the popup closes, the lobby's card and
## a group follow).
func pick_size(m: String, n: int) -> void:
	if not (n in Game.TEAM_SIZES):
		return
	Game.team_size = n
	if n > 1:
		Game.practice = false
	_pick(m)


## A size chip's word: SOLO / DUO / SQUAD; in LONE WOLF with a group of exactly two, SOLO is the
## duel between the two: "DUEL · YOU VS <NAME>" (START plays it: Lobby.start_duel). `members`:
## Cloud.group_members() (this player marked "me").
static func size_chip_text(m: String, n: int, members: Array) -> String:
	if m == "lonewolf" and n == 1 and members.size() == 2:
		for p: Dictionary in members:
			if not bool(p.get("me", false)):
				return "DUEL · YOU VS %s" % String(p.get("name", "PLAYER"))
	return String(SIZE_NAMES.get(n, "SOLO"))


## TRAINING GROUND's opponent (row Difficulty): EASY, NORMAL and HARD bots, then the target dummy
## (Diff_<name>, SOLO only: greyed in DUO and SQUAD); the current one is lit while TRAINING GROUND
## is the mode.
func _opponent_chips() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "Difficulty"
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var group := ButtonGroup.new()
	for i in Game.DIFFICULTY_NAMES.size():
		row.add_child(_opponent_chip(String(Game.DIFFICULTY_NAMES[i]), i, group))
	row.add_child(_opponent_chip(DUMMY, -1, group))
	return row


## A chip for TRAINING GROUND's opponent: a bot level (idx into Game.DIFFICULTY_NAMES) or, with
## idx -1, the target dummy. A tap picks it with TRAINING GROUND and closes SELECT MODE.
func _opponent_chip(text: String, idx: int, group: ButtonGroup) -> Button:
	var b := _chip(text, "Diff_" + text, Game.practice if idx < 0 else (not Game.practice and idx == int(Game.settings.difficulty)), group)
	if idx < 0 and Game.team_size > 1:
		b.disabled = true                 # DUMMY IS SOLO ONLY (the card's line says so)
	b.pressed.connect(func() -> void:
		Audio.play("ui_select", -6.0)
		Game.practice = idx < 0
		if idx >= 0:
			Game.settings.difficulty = idx
		else:
			Game.team_size = 1
		_pick("training"))
	return b


## One chip of SELECT MODE (a size or an opponent): toggled in its group, lit when picked.
func _chip(text: String, node_name: String, lit: bool, group: ButtonGroup) -> Button:
	var b := Button.new()
	b.name = node_name
	b.toggle_mode = true
	b.button_group = group
	b.button_pressed = lit
	b.focus_mode = Control.FOCUS_NONE
	b.text = text
	b.custom_minimum_size = Vector2(96, UI.TOUCH_MIN)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_override("font", UI.font("bold"))
	b.add_theme_font_size_override("font_size", 17)
	var off := UI.chamfer(Color(0, 0, 0, 0.55), 8, 1, Color(1, 1, 1, 0.2), 8.0, ["tl", "br"], 0.0)
	var hov := UI.chamfer(Color(1, 1, 1, 0.1), 8, 1, Color(1, 1, 1, 0.35), 8.0, ["tl", "br"], 0.0)
	var on := UI.chamfer(UI.ACCENT, 8, 0, Color.TRANSPARENT, 8.0, ["tl", "br"], 0.0)
	b.add_theme_stylebox_override("normal", off)
	b.add_theme_stylebox_override("hover", hov)
	b.add_theme_stylebox_override("pressed", on)
	b.add_theme_stylebox_override("hover_pressed", on)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("font_color", UI.TEXT)
	b.add_theme_color_override("font_hover_color", UI.TEXT)
	b.add_theme_color_override("font_pressed_color", UI.INK)
	b.add_theme_color_override("font_hover_pressed_color", UI.INK)
	b.add_theme_color_override("font_disabled_color", Color(UI.TEXT_DIM, 0.45))
	b.add_theme_stylebox_override("disabled", UI.chamfer(Color(0, 0, 0, 0.3), 8, 1, Color(1, 1, 1, 0.08), 8.0, ["tl", "br"], 0.0))
	return b


## A mode picked in SELECT MODE: kept (the setting "mode", saved with the bot's level), the popup
## closes and the lobby's mode card follows.
func _pick(m: String) -> void:
	if LobbyTeam.is_member():
		close_modal()                   # (the leader's choice stands: Lobby.on_group_changed)
		lobby.on_group_changed()
		return
	Game.mode = m
	Game.save_settings()
	close_modal()
	lobby._refresh_mode()
	if LobbyTeam.in_group():
		Game.cloud_service().set_group_mode(Game.mode, Game.team_size)   # the members' cards follow


# ---------------------------------------------------------------- the TEAM panel (team-size box)

## The mode card's TEAM panel (node SizeBox, open while not null; the panel SizeBoxPanel): the
## figure on the card's right end (Lobby: SizeBoxButton) opens it just above the card, its right
## edge on the card's. In LONE WOLF with online teams (the group's place, LobbyTeam.bar_shown) and
## not in a room: the GROUP CODE row (LobbyTeam.code_row: the code and COPY; a member's only while
## the leader's JOIN BY CODE is on, else THE LEADER SHARES THE GROUP CODE), the tick JOIN BY CODE
## (GroupCodeSwitch: Cloud.set_code_join, the leader's or a solo's; a member sees the leader's
## read-only) and the tick FILL EMPTY PLACES (TeamFillTick, the leader's or a solo's: the setting
## team_fill, on by default; off, a DUO / SQUAD START never puts other players in the group's own
## team, so only a whole team starts, still searching for opponents: Lobby.fill_needed). Then a picture tile per team
## size of the card's mode (SizeTile_<1|2|4>: SOLO / DUO / SQUAD with one, two or four figures; in
## LONE WOLF with a group of exactly two SOLO reads DUEL with YOU VS <NAME> under it, as SELECT
## MODE's chip: size_tile_text); the current one has a yellow frame and the tick corner. A tile
## picks that size as SELECT MODE's chip does (pick_size) and closes the panel; a group member's
## tiles show the leader's choice and do nothing. A tap anywhere outside it, or Android back,
## closes it. Not during a search (the lobby hides the figure then and closes an open panel:
## size_box_allowed).
var size_box: Control


## Whether the TEAM panel may open now: not while searching (a member sees it read-only).
static func size_box_allowed(_member: bool, searching: bool) -> bool:
	return not searching


## A tile's words in the TEAM panel: [the big word, the small line under it]. SOLO in LONE WOLF
## with a group of two is the DUEL between the two (Lobby.start_duel plays it).
static func size_tile_text(m: String, n: int, members: Array) -> Array:
	var chip := size_chip_text(m, n, members)
	if chip.begins_with("DUEL · "):
		return ["DUEL", chip.trim_prefix("DUEL · ")]
	match n:
		2:
			return ["DUO", "2 VS 2"]
		4:
			return ["SQUAD", "4 VS 4"]
	return ["SOLO", "1 VS 1"]


## Whether the TEAM panel shows the group's rows (code, JOIN BY CODE, FILL EMPTY PLACES): where the
## group lives (LONE WOLF with online teams, or already in a group), never in a custom room.
static func team_rows_shown(m: String, grouped: bool, in_room: bool, teams_online := Game.TEAMS_ONLINE) -> bool:
	return LobbyTeam.bar_shown(m, grouped, teams_online) and not in_room


func open_size_box(fade := true) -> void:
	close_size_box()
	if not size_box_allowed(LobbyTeam.is_member(), lobby.search_kind() != ""):
		return
	var card := lobby.mode_card
	var member := LobbyTeam.is_member()
	var cloud := Game.cloud_service()
	size_box = Control.new()
	size_box.name = "SizeBox"
	UI.full_rect(size_box)
	size_box.mouse_filter = Control.MOUSE_FILTER_STOP
	size_box.gui_input.connect(func(e: InputEvent) -> void:
		if (e is InputEventMouseButton and (e as InputEventMouseButton).pressed) \
				or (e is InputEventScreenTouch and (e as InputEventScreenTouch).pressed):
			close_size_box())
	lobby.ui.add_child(size_box)
	var panel := PanelContainer.new()
	panel.name = "SizeBoxPanel"
	panel.add_theme_stylebox_override("panel", UI.chamfer(Color(0.06, 0.055, 0.05, 0.96), 12, 1, Color(UI.ACCENT, 0.5), 12.0, ["tl"]))
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	size_box.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	panel.add_child(v)
	var m := Game.mode
	if team_rows_shown(m, LobbyTeam.in_group(), cloud.in_room()):
		var code := cloud.group_code()
		if code != "" and (not member or cloud.code_open()):
			v.add_child(lobby.team.code_row(code, not member))
		elif member:
			v.add_child(lobby.team.code_note())
		var join := _tick_row("JOIN BY CODE", cloud.code_open(), not member, func() -> void:
			cloud.set_code_join(not cloud.code_join))
		join.name = "GroupCodeSwitch"
		v.add_child(join)
		if not member:
			var fill := _tick_row("FILL EMPTY PLACES", bool(Game.settings.get("team_fill", true)), true, func() -> void:
				Game.settings.team_fill = not bool(Game.settings.get("team_fill", true))
				Game.save_settings())
			fill.name = "TeamFillTick"
			v.add_child(fill)
	else:
		v.add_child(UI.label("TEAM SIZE  ·  %s" % Game.mode_name(), 16, UI.TEXT_DIM, "bold"))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	v.add_child(row)
	for n: int in Game.TEAM_SIZES:
		row.add_child(_size_tile(m, n, not member))
	# Just above the mode card, its right edge on the card's.
	var r := card.get_global_rect()
	var w := r.size.x
	panel.size = Vector2(w, 0)
	panel.reset_size()
	panel.custom_minimum_size.x = w
	var h := panel.get_combined_minimum_size().y
	panel.position = Vector2(r.end.x - w, r.position.y - 8.0 - h)
	if fade:
		panel.modulate.a = 0.0
		panel.create_tween().tween_property(panel, "modulate:a", 1.0, 0.12)


func close_size_box() -> void:
	if size_box:
		size_box.queue_free()
		size_box = null


## The open TEAM panel follows the group (a member sees the leader's choice; the code's switch).
func refresh_size_box() -> void:
	if size_box != null and is_instance_valid(size_box):
		open_size_box(false)


## A tick row of the TEAM panel: a yellow box with a tick when on, the words beside it; `on_tap`
## then the panel redraws. Read-only (`may` false): greyed, a tap does nothing.
func _tick_row(text: String, on: bool, may: bool, on_tap: Callable) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, UI.TOUCH_MIN)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.disabled = not may
	b.set_meta("on", on)
	for st in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
		b.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	b.draw.connect(func() -> void:
		var sz := b.size
		var a := 1.0 if may else 0.5
		if b.is_pressed():
			b.draw_rect(Rect2(Vector2.ZERO, sz), Color(1, 1, 1, 0.08))
		var bx := Rect2(Vector2(8, sz.y * 0.5 - 12.0), Vector2(24, 24))
		if on:
			b.draw_rect(bx, Color(UI.ACCENT, a))
			b.draw_polyline(PackedVector2Array([bx.position + Vector2(5, 12), bx.position + Vector2(10, 18), bx.position + Vector2(19, 6)]),
				Color(UI.INK, a), 3.0, true)
		else:
			b.draw_rect(bx, Color(0, 0, 0, 0.5))
			b.draw_rect(bx, Color(1, 1, 1, 0.5 * a), false, 2.0)
		HudDraw.text(b, text, Vector2(44, sz.y * 0.5), 17, Color(UI.TEXT, a), 0, 0, "bold"))
	for sig in ["button_down", "button_up"]:
		b.connect(sig, b.queue_redraw)
	b.pressed.connect(func() -> void:
		Audio.play("ui_click", -4.0)
		on_tap.call()
		refresh_size_box())
	return b


## One tile of the TEAM panel (SizeTile_<n>): one, two or four figures, the word and its line; the
## current size framed yellow with the tick corner. `may` false (a group member): the leader's
## choice, shown only.
func _size_tile(m: String, n: int, may := true) -> Button:
	var words := size_tile_text(m, n, LobbyTeam.members())
	var b := Button.new()
	b.name = "SizeTile_%d" % n
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 104)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.disabled = not may
	for st in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
		b.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	var lit := n == Game.team_size
	b.draw.connect(func() -> void:
		var sz := b.size
		var a := 1.0 if may else 0.5          # a member's tiles: read-only, dimmed like the tick rows
		b.draw_rect(Rect2(Vector2.ZERO, sz), Color(1, 1, 1, 0.1 * a) if b.is_pressed() else Color(0, 0, 0, 0.5 * a))
		# the figures: one for SOLO, two for DUO, four (two rows deep) for SQUAD
		var fig := HudDraw.tex("v_player")
		var ink := Color(UI.ACCENT if lit else Color(1, 1, 1, 0.9), a * (UI.ACCENT.a if lit else 0.9))
		var spots: Array = [[Vector2(0, 0), 1.0]]
		if n == 2:
			spots = [[Vector2(-11, 0), 1.0], [Vector2(11, 0), 1.0]]
		elif n >= 4:
			spots = [[Vector2(-17, -5), 0.8], [Vector2(17, -5), 0.8], [Vector2(-7, 2), 0.95], [Vector2(9, 2), 0.95]]
		for sp: Array in spots:
			HudDraw.icon(b, fig, Vector2(sz.x * 0.5, sz.y * 0.32) + (sp[0] as Vector2), Vector2(34, 34) * float(sp[1]), ink)
		HudDraw.text(b, String(words[0]), Vector2(sz.x * 0.5, sz.y * 0.66), 19, Color(UI.ACCENT if lit else UI.TEXT, a), 1, 0, "heavy")
		var sub := String(words[1])
		var fs := 12
		while fs > 9 and HudDraw.text_width(sub, fs, "bold") > sz.x - 10.0:
			fs -= 1
		HudDraw.text(b, sub, Vector2(sz.x * 0.5, sz.y * 0.86), fs, Color(UI.TEXT_DIM, UI.TEXT_DIM.a * a), 1, 0, "bold")
		if lit:
			b.draw_rect(Rect2(Vector2(1.5, 1.5), sz - Vector2(3, 3)), Color(UI.ACCENT, a), false, 3.0)
			UI.draw_tick_corner(b, sz, 26.0)
		else:
			b.draw_rect(Rect2(Vector2(0.5, 0.5), sz - Vector2(1, 1)), Color(1, 1, 1, 0.18 * a), false, 1.0))
	for sig in ["mouse_entered", "mouse_exited", "button_down", "button_up"]:
		b.connect(sig, b.queue_redraw)
	b.pressed.connect(func() -> void:
		Audio.play("ui_select", -6.0)
		close_size_box()
		pick_size(m, n))
	return b


# ---------------------------------------------------------------- player name

## The name editor. first: asked once at start (new installs and ones from before this prompt):
## type a name or roll a random one; closing it keeps the current name.
func edit_name(first := false) -> void:
	var v := open_modal("CHOOSE YOUR NAME" if first else "PLAYER NAME", 640.0, true)
	v.add_child(UI.label("Type a name or tap RANDOM. Up to 14 letters or digits; shown in matches.", 16, UI.TEXT_DIM, "semi"))
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 10)
	var le := LineEdit.new()
	le.name = "NameEdit"
	le.text = String(Game.profile.name)
	le.max_length = 14
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.custom_minimum_size = Vector2(0, 56)
	le.virtual_keyboard_enabled = true
	le.virtual_keyboard_show_on_focus = true
	le.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_DEFAULT
	le.select_all_on_focus = first
	le.add_theme_font_override("font", UI.font("bold"))
	le.add_theme_font_size_override("font_size", 26)
	le.add_theme_stylebox_override("normal", UI.chamfer(Color(0, 0, 0, 0.5), 8, 1, Color(1, 1, 1, 0.25), 14.0, ["br"]))
	le.add_theme_stylebox_override("focus", UI.chamfer(Color(0, 0, 0, 0.5), 8, 2, UI.ACCENT, 14.0, ["br"]))
	le.add_theme_color_override("font_color", UI.TEXT)
	le.add_theme_color_override("caret_color", UI.ACCENT)
	line.add_child(le)
	var dice := UI.button("RANDOM", 20, "light", Vector2(150, 56))
	dice.name = "NameRandom"
	dice.pressed.connect(func() -> void:
		le.text = Game.random_name()
		le.caret_column = le.text.length()
		Audio.play("ui_click", -4.0))
	line.add_child(dice)
	v.add_child(line)
	# What other players will see, as it is typed (accents become plain letters, other scripts
	# and symbols are left out, Game.clean_name).
	var preview := UI.label("", 18, UI.TEXT_DIM, "bold")
	preview.name = "NamePreview"
	v.add_child(preview)
	var show_preview := func(t: String) -> void:
		var shown := Game.clean_name(t)
		preview.text = "SHOWN AS:  " + shown if shown != "" else "USE LETTERS A-Z OR DIGITS: NOTHING HERE CAN BE SHOWN"
		preview.add_theme_color_override("font_color", UI.TEXT_DIM if shown != "" else UI.BAD)
	le.text_changed.connect(show_preview)
	show_preview.call(le.text)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 12)
	var cancel := UI.button("KEEP" if first else "CANCEL", 20, "light", Vector2(170, 56))
	var keep := func() -> void:
		if first:
			Game.profile.name_set = true
			Game.save_profile()
		close_modal()
	cancel.pressed.connect(keep)
	var ok := UI.button("OK", 22, "primary", Vector2(170, 56))
	ok.name = "NameOk"
	var apply := func() -> void:
		var n := Game.clean_name(le.text)
		if n == "":
			show_preview.call(le.text)     # nothing that can be shown: the editor stays open and says so
			return
		Game.profile.name = n
		lobby._name_label.text = n
		Game.profile.name_set = true
		Game.save_profile()
		close_modal()
	ok.pressed.connect(apply)
	le.text_submitted.connect(func(_t: String) -> void: apply.call())
	row.add_child(cancel)
	row.add_child(ok)
	v.add_child(row)
	# The two calls below come after this frame / 0.2 s, when the lobby may be gone already (a
	# test or a quick START leaves it at once): they carry the controls' ids, not the controls,
	# and are dropped with this object.
	if first:
		var x := modal.find_child("Close", true, false) as Button
		if x:
			x.pressed.connect(keep)
		lobby.get_tree().process_frame.connect(_mark_name_prompt.bind(ok.get_instance_id()), CONNECT_ONE_SHOT | CONNECT_DEFERRED)
	# Focus once the dialog is up: the keyboard then opens under it, with the field in view.
	lobby.get_tree().create_timer(0.2).timeout.connect(_focus_name_field.bind(le.get_instance_id()))


## Where the first-start prompt's OK is, once it is laid out (the emulator test taps it).
func _mark_name_prompt(ok_id: int) -> void:
	var ok := instance_from_id(ok_id) as Control
	if ok and ok.is_inside_tree():
		Game.mark("name prompt")
		Game.mark_ui("name_ok", ok, ok.size / 2.0)


func _focus_name_field(field_id: int) -> void:
	var le := instance_from_id(field_id) as LineEdit
	if le and le.is_inside_tree():
		le.grab_focus()
		le.caret_column = le.text.length()


# ---------------------------------------------------------------- quit

## "QUIT THE GAME?" in the normal popup frame, as every other question (quit_popup).
func confirm_quit() -> void:
	close_modal()
	modal = quit_popup(lobby.ui, close_modal, func() -> void: lobby.get_tree().quit(),
		"Your name, outfits, settings and progress stay saved on this phone.")


## The quit question as the normal popup (the light header with its X, the dark body, CANCEL and
## QUIT), on `parent`; the lobby's and the login's. Node names: QuitDialog, QuitCancel, QuitConfirm.
static func quit_popup(parent: Node, on_cancel: Callable, on_quit: Callable, text: String) -> Control:
	var m := Control.new()
	m.name = "QuitDialog"
	UI.full_rect(m)
	m.mouse_filter = Control.MOUSE_FILTER_STOP
	parent.add_child(m)
	var shade := UI.blur_shade(0.72)
	UI.full_rect(shade)
	m.add_child(shade)
	var frame := VBoxContainer.new()
	frame.name = "Frame"
	frame.add_theme_constant_override("separation", 0)
	frame.anchor_left = 0.5
	frame.anchor_right = 0.5
	frame.anchor_top = 0.5
	frame.anchor_bottom = 0.5
	frame.offset_left = -340
	frame.offset_right = 340
	frame.grow_vertical = Control.GROW_DIRECTION_BOTH
	m.add_child(frame)
	var head := UI.popup_header("QUIT THE GAME?", 26, 56.0)
	(head.get_node("Close") as Button).pressed.connect(on_cancel)
	frame.add_child(head)
	var panel := UI.popup_body()
	frame.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	panel.add_child(v)
	var t := UI.label(text, 20, UI.TEXT, "semi")
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	t.custom_minimum_size = Vector2(600, 0)
	v.add_child(t)
	v.add_child(UI.spacer(4))
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 12)
	v.add_child(row)
	var cancel := UI.button("CANCEL", 20, "light", Vector2(190, 56))
	cancel.name = "QuitCancel"
	cancel.pressed.connect(on_cancel)
	row.add_child(cancel)
	var quit := UI.button("QUIT", 22, "primary", Vector2(210, 56))
	quit.name = "QuitConfirm"
	quit.pressed.connect(on_quit)
	row.add_child(quit)
	m.modulate.a = 0.0
	m.create_tween().tween_property(m, "modulate:a", 1.0, 0.12)
	return m

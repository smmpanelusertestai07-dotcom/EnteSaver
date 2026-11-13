class_name LobbyProfile
extends RefCounted
## PROFILE in the lobby, and another player's card.
##
## PROFILE (the lobby's player card top-left opens it; CLOSE or Android back closes it) is a
## full-screen layer over the stage in the landscape layout of the reference's profile, in our own
## words: vertical tabs on the left, the open tab in the middle, this player's name card on the
## right. CAREER: the lifetime numbers with their rates and averages ("-" while there is nothing to
## divide by), then one row per mode the profile counts (Game.RECORD_MODES: TRAINING GROUND, LONE
## WOLF, LONE WOLF DUO, LONE WOLF SQUAD). HISTORY: the last Game.MAX_HISTORY counted matches, newest
## first (profile "history", Game.record_match; a match quit with QUIT MATCH shows as LEFT, a team
## match the host ended as ENDED; a DUO / SQUAD row reads "DUO · VS BOTS", "SQUAD · WITH <NAME>"
## or "DUO · VS <NAME>": history_texts); a row against another player opens their card. NAME CARD: the banner and the profile picture,
## saved at once; the name card shows them live. BLOCKED: the blocked players with UNBLOCK, by the
## name known for them (kept with the block) else their short ID; it follows blocks made elsewhere,
## and while it shows, the player cards are listened to (Cloud.start_directory), so names and cards
## arrive.
## The name card: the banner art behind the profile picture (a tap opens NAME CARD), the name with
## EDIT (the lobby's name editor), the level with an XP bar to the next one, the PLAYER ID (short;
## COPY puts the whole id on the clipboard), the signature line with EDIT, the outfit and PLAYING
## SINCE (profile "created"). It is what other players get: Cloud's signed card (Cloud.my_card).
##
## The player card (open_player) is another player's name card in a popup (Lobby.dialogs), opened by
## a tap on a player in the ONLINE window's lists (LobbyFriends), in BLOCKED or on a HISTORY row. It
## shows their public card (Cloud.directory: picture, banner, level, signature, name and outfit),
## online now or when last seen, and what can be done: DUEL 1 VS 1 (online now:
## LobbyFriends.challenge), ADD FRIEND / REQUEST SENT / REMOVE FRIEND and BLOCK / UNBLOCK (both
## asked again). Its X and back go back to the list it came from.
## The lobby makes it (Lobby.profile_ui), opens it from the player card and calls process() every
## frame; everything is built under the lobby's UI layer.
## Node names: Profile, ProfileClose, ProfileTab_<career|history|namecard|blocked>, NameCard,
## CardAvatar, CardName, CardEditName, CardLevel, CardXp, CardId, CardCopy, CardSignature,
## CardEditSignature, CardOutfit, CardSince, Career_<stat key>, CareerMode_<mode>, HistoryRow_<n>,
## HistoryEmpty, Banner_<id>, Avatar_<id>, BlockedRow_<code>, Unblock_<code>, BlockedEmpty,
## SignatureEdit, SignatureOk; in the player card: PlayerCardPopup, PlayerStatus, PlayerId,
## PlayerCopy, PlayerOutfit, PlayerSignature, PlayerNote, PlayerBlock, PlayerFriend, PlayerDuel.

const TABS := [["career", "CAREER"], ["history", "HISTORY"], ["namecard", "NAME CARD"], ["blocked", "BLOCKED"]]
## Each Game.BANNERS id's name in the banner picker (the art: Login.banner_texture,
## tools/media/make_banners.py).
const BANNER_NAMES := {"default": "EMBER RIDGE", "gold_rush": "GOLD RUSH", "hive": "HIVE", "contour": "CONTOUR",
	"shards": "SHARDS", "scope": "SCOPE"}
const RESULT_WORDS := {"won": "VICTORY", "lost": "DEFEAT", "draw": "DRAW", "left": "LEFT", "ended": "ENDED"}
const MONTHS := ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
const MARGIN := 26.0
const TOP := 88.0                  # the tabs, the open tab and the name card start here
const TAB_W := 204.0
const POPUP_W := 760.0
const ONLINE_GREEN := Color(0.38, 0.86, 0.44)

var lobby: Lobby
## The PROFILE layer (node "Profile") while it is open, else null.
var layer: Control
## The open tab (a key of TABS).
var tab := "career"
var _scroll: ScrollContainer
var _list: VBoxContainer           # the open tab's content
var _card_box: VBoxContainer       # the name card column
var _card_w := 384.0
var _card_shown := ""              # what the name card shows (_card_key): it is built again on a change
var _player_id := ""               # the player card's player
var _player_back := ""             # the ONLINE window tab it goes back to ("" = it just closes)
var _player_box: VBoxContainer     # its content while it is open
var _player_shown := ""            # what it shows (_player_state)
var _player_t := 0.0
var _player_note := ""
var _blocked_shown := ""           # what BLOCKED lists (_blocked_key): it is built again on a change
var _blocked_t := 0.0
var _dir_on := false               # BLOCKED or a card opened here wants the player cards (Cloud.start_directory)


func _init(owner_lobby: Lobby) -> void:
	lobby = owner_lobby


# ---------------------------------------------------------------- shared (static) helpers

## The art of a Game.BANNERS id (Login.banner_texture; the first banner's for an unknown one).
static func banner_texture(id: String) -> Texture2D:
	var t := Login.banner_texture(id)
	return t if t != null else Login.banner_texture(String(Game.BANNERS[0]))


static func banner_name(id: String) -> String:
	return String(BANNER_NAMES.get(id, BANNER_NAMES["default"]))


## A profile picture's name in the picker: EMBLEM or the outfit's name.
static func avatar_name(avatar: String) -> String:
	if avatar == String(Game.DEFAULT_PROFILE.avatar):
		return "EMBLEM"
	return String(CharacterModel.bundle_info(avatar).name)


## Draws `tex` over `r` like CSS "cover": scaled to fill it, centred, the overflow cut off.
static func draw_cover(ci: CanvasItem, tex: Texture2D, r: Rect2) -> void:
	if tex == null:
		ci.draw_rect(r, Color(0.1, 0.1, 0.12))
		return
	var ts := tex.get_size()
	var want := r.size.x / maxf(r.size.y, 1.0)
	var src := Rect2(Vector2.ZERO, ts)
	if ts.x / ts.y > want:
		src = Rect2((ts.x - ts.y * want) * 0.5, 0.0, ts.y * want, ts.y)
	else:
		src = Rect2(0.0, (ts.y - ts.x / want) * 0.5, ts.x, ts.x / want)
	ci.draw_texture_rect_region(tex, r, src)


## Draws a profile picture into the square `r` (Login.avatar_texture: the emblem, or an outfit
## portrait's head, the art the first profile setup shows). Anything unknown shows the emblem.
static func draw_avatar(ci: CanvasItem, avatar: String, r: Rect2) -> void:
	var tex := Login.avatar_texture(avatar if avatar in Game.avatar_ids() else String(Game.DEFAULT_PROFILE.avatar))
	if tex:
		ci.draw_texture_rect(tex, r, false)


## A whole number with thousands separators ("61,234").
static func thousands(n: int) -> String:
	var digits := str(absi(n))
	var out := ""
	while digits.length() > 3:
		out = "," + digits.right(3) + out
		digits = digits.left(digits.length() - 3)
	return ("-" if n < 0 else "") + digits + out


## part of whole as a percentage with one decimal ("37.3%"); "-" when whole is 0 (no data).
static func percent(part: int, whole: int) -> String:
	if whole <= 0:
		return "-"
	return "%.1f%%" % clampf(100.0 * part / whole, 0.0, 100.0)


## Kills per death ("1.56"); before the first death the kills themselves, "-" with neither.
static func kd_text(kills: int, deaths: int) -> String:
	if kills <= 0 and deaths <= 0:
		return "-"
	return "%.2f" % (float(maxi(kills, 0)) / float(maxi(deaths, 1)))


## Seconds as hours and minutes ("8H 24M"; "12M" under an hour).
static func play_time(seconds: int) -> String:
	var m := maxi(seconds, 0) / 60
	return "%dH %02dM" % [m / 60, m % 60] if m >= 60 else "%dM" % m


## How long ago a unix time was ("5 MIN AGO", "2 DAYS AGO"; "" for none).
static func time_ago(t: int, now: int) -> String:
	if t <= 0:
		return ""
	var s := maxi(now - t, 0)
	if s < 60:
		return "JUST NOW"
	if s < 3600:
		return "%d MIN AGO" % (s / 60)
	if s < 86400:
		return "%d H AGO" % (s / 3600)
	var days := s / 86400
	return "%d DAY%s AGO" % [days, "" if days == 1 else "S"]


## "PLAYING SINCE 4 NOV 2026" (the phone's time zone); a profile never saved yet starts today.
static func since_text(created: int, now: int) -> String:
	var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var d := Time.get_datetime_dict_from_unix_time((created if created > 0 else now) + bias)
	return "PLAYING SINCE %d %s %d" % [int(d.day), MONTHS[clampi(int(d.month) - 1, 0, 11)], int(d.year)]


## The largest font size from `size` down to `smallest` at which `text` fits `width` (a 14
## character name on the narrower name card); the label's "..." ends what still does not fit.
static func fit_size(text: String, kind: String, size: int, smallest: int, width: float) -> int:
	var f := UI.font(kind)
	var fs := size
	while fs > smallest and f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > width:
		fs -= 1
	return fs


## A counter of a profile dictionary (0 for anything but a number, never negative).
static func _num(p: Dictionary, k: String) -> int:
	var v: Variant = p.get(k, 0)
	return maxi(int(v), 0) if (v is int or v is float) else 0


## CAREER's lifetime numbers from a profile, in the order shown (pairs: the page has two
## columns): [key, caption, value text]. Headshot rate is headshots per hit (its caption says so:
## players often read it per kill), accuracy hits per shot (Fighter.stats). A rate or an average
## with nothing to divide by shows "-": no division by zero.
static func career_stats(p: Dictionary) -> Array:
	var matches := _num(p, "matches")
	var wins := _num(p, "wins")
	var kills := _num(p, "kills")
	var deaths := _num(p, "deaths")
	var headshots := _num(p, "headshots")
	var hits := _num(p, "hits")
	var damage := _num(p, "damage")
	return [
		["matches", "MATCHES", thousands(matches)],
		["wins", "WINS", thousands(wins)],
		["win_rate", "WIN RATE", percent(wins, matches)],
		["time_played", "TIME PLAYED", play_time(_num(p, "time_played"))],
		["kills", "KILLS", thousands(kills)],
		["deaths", "DEATHS", thousands(deaths)],
		["kd", "K/D", kd_text(kills, deaths)],
		["accuracy", "ACCURACY", percent(hits, _num(p, "shots"))],
		["headshots", "HEADSHOTS", thousands(headshots)],
		["headshot_rate", "HEADSHOT RATE (PER HIT)", percent(headshots, hits)],
		["damage", "DAMAGE", thousands(damage)],
		["avg_damage", "AVG DAMAGE / MATCH", "-" if matches == 0 else thousands(roundi(float(damage) / matches))],
		["rounds_won", "ROUNDS WON", thousands(_num(p, "rounds_won"))],
		["rounds_lost", "ROUNDS LOST", thousands(_num(p, "rounds_lost"))],
	]


## A mode's numbers in a profile ({"matches", "wins", "kills"}, 0 when missing).
static func mode_stats(p: Dictionary, m: String) -> Dictionary:
	var modes: Variant = p.get("modes")
	var src: Variant = (modes as Dictionary).get(m) if modes is Dictionary else null
	var out := {}
	for k: String in Game.MODE_COUNTERS:
		out[k] = _num(src as Dictionary, k) if src is Dictionary else 0
	return out


## A player's name when this phone knows it (friends and requests, the lobby, the player cards,
## the name kept with a block, recent opponents, HISTORY), else "".
static func known_name(id: String) -> String:
	var p: Dictionary = Game.profile
	for k: String in ["friends", "friend_in", "friend_out"]:
		var m: Dictionary = p[k]
		if m.has(id) and String(m[id].name) != "":
			return String(m[id].name)
	var cloud := Game.cloud
	if cloud and cloud.peers.has(id):
		return String(cloud.peers[id].name)
	if cloud and cloud.directory.has(id):
		return String(cloud.directory[id].name)
	for e: Dictionary in p.blocked:
		if e.id == id and String(e.name) != "":
			return String(e.name)
	for e: Dictionary in p.recent:
		if String(e.id) == id and String(e.name) != "":
			return String(e.name)
	for e: Dictionary in p.history:
		if String(e.id) == id:
			return String(e.enemy)
	return ""


## A player's name in a list as a flat button (node Player_<friend code>) over a faint plate with a
## ">" at its end; the caller connects `pressed` (it opens the player card).
static func player_button(id: String, text: String) -> Button:
	var b := Button.new()
	b.name = "Player_" + Cloud.friend_code(id)
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(0, 56)
	b.clip_text = true
	b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	b.add_theme_font_override("font", UI.font("heavy"))
	b.add_theme_font_size_override("font_size", 24)
	for st: String in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(st, UI.TEXT)
	var normal := UI.chamfer(Color(1, 1, 1, 0.05), 6, 0, Color.TRANSPARENT, 14.0, ["br"])
	normal.content_margin_right = 40
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(1, 1, 1, 0.1)
	var down := normal.duplicate() as StyleBoxFlat
	down.bg_color = Color(UI.ACCENT, 0.25)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", down)
	b.add_theme_stylebox_override("hover_pressed", down)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.draw.connect(_draw_chevron.bind(b))
	b.pressed.connect(func() -> void: Audio.play("ui_click", -4.0))
	return b


## The ">" at the right end of a row that opens a player's card (yellow while touched).
static func _draw_chevron(b: Button) -> void:
	var c := Vector2(b.size.x - 20, b.size.y * 0.5)
	b.draw_polyline(PackedVector2Array([c + Vector2(-4, -8), c + Vector2(4, 0), c + Vector2(-4, 8)]),
		UI.ACCENT if b.is_hovered() or b.is_pressed() else Color(1, 1, 1, 0.55), 2.5, true)


## A HISTORY entry's two lines: [who it was against, the mode]. 1 vs 1: "VS  <NAME>" and the mode;
## DUO / SQUAD ("size"): "DUO · VS BOTS", "SQUAD · WITH <NAME>" (a friend's TEAM INVITE), "DUO · VS
## <NAME>" (a player the team search found), and the mode START played (TRAINING GROUND or LONE
## WOLF).
static func history_texts(e: Dictionary) -> Array:
	var m := String(e.get("mode", ""))
	var size := int(e.get("size", 1))
	if not size in [2, 4]:
		return ["VS  " + String(e.get("enemy", "PLAYER")), Game.mode_name(m)]
	var word := "DUO" if size == 2 else "SQUAD"
	var mate := String(e.get("with", ""))
	var who := "VS BOTS"
	if mate != "":
		who = "WITH " + mate
	elif Game.is_player_id(e.get("id", "")):
		who = "VS " + String(e.get("enemy", "PLAYER"))
	return ["%s · %s" % [word, who], Game.mode_name("training" if m == "training" else "lonewolf")]


static func _result_color(r: String) -> Color:
	match r:
		"won":
			return UI.GOLD
		"draw":
			return UI.TEXT
	return Color(0.66, 0.67, 0.7)


# ---------------------------------------------------------------- the PROFILE layer

## Opens PROFILE on a tab (a key of TABS); open already, it switches to that tab.
func open(start_tab := "career") -> void:
	if layer:
		_show_tab(start_tab)
		return
	lobby.dialogs.close_modal()
	layer = Control.new()
	layer.name = "Profile"
	UI.full_rect(layer)
	layer.mouse_filter = Control.MOUSE_FILTER_STOP
	lobby.ui.add_child(layer)
	lobby._main_ui.visible = false
	# the lobby blurred behind the page (plain at LOW graphics), then the page's dark ramp over it
	var blur := UI.blur_shade(0.8)
	UI.full_rect(blur)
	layer.add_child(blur)
	var shade := UI.gradient_rect([[0.0, Color(0.035, 0.035, 0.045, 0.9)], [0.55, Color(0.045, 0.042, 0.045, 0.78)],
		[1.0, Color(0.075, 0.058, 0.045, 0.72)]], true)
	UI.full_rect(shade)
	layer.add_child(shade)
	# the page frame's corner as on FRIENDS: the X box in the corner, PROFILE right-aligned beside it
	var close_b := UI.page_corner(layer, "PROFILE", close)[0] as Button
	close_b.name = "ProfileClose"
	var tabs := VBoxContainer.new()
	tabs.name = "ProfileTabs"
	tabs.position = Vector2(MARGIN, TOP)
	tabs.add_theme_constant_override("separation", 10)
	layer.add_child(tabs)
	for t: Array in TABS:
		tabs.add_child(_tab_button(String(t[0]), String(t[1])))
	# The name card is about 30 % of the width; the open tab gets the rest (at least 590 px).
	_card_w = clampf(roundf(lobby.get_viewport().get_visible_rect().size.x * 0.3), 384.0, 460.0)
	_scroll = ScrollContainer.new()
	_scroll.name = "ProfileBody"
	_scroll.anchor_right = 1.0
	_scroll.anchor_bottom = 1.0
	_scroll.offset_left = MARGIN + TAB_W + 24.0
	_scroll.offset_right = -(MARGIN + _card_w + 24.0)
	_scroll.offset_top = TOP
	_scroll.offset_bottom = -20.0
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	UI.style_scroll(_scroll)
	layer.add_child(_scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 10)
	_scroll.add_child(_list)
	_card_box = VBoxContainer.new()
	_card_box.name = "NameCard"
	_card_box.anchor_left = 1.0
	_card_box.anchor_right = 1.0
	_card_box.offset_left = -(MARGIN + _card_w)
	_card_box.offset_right = -MARGIN
	_card_box.offset_top = TOP
	_card_box.offset_bottom = TOP
	_card_box.add_theme_constant_override("separation", 0)
	layer.add_child(_card_box)
	_build_card()
	_show_tab(start_tab)
	layer.modulate.a = 0.0
	layer.create_tween().tween_property(layer, "modulate:a", 1.0, 0.15)


func close() -> void:
	if layer:
		layer.queue_free()
		layer = null
		_scroll = null
		_list = null
		_card_box = null
	lobby._main_ui.visible = true
	lobby.refresh_player_card()
	_want_directory(false)


## The lobby is leaving the tree (a match starts): the player cards are not wanted any more.
func on_lobby_exit() -> void:
	_want_directory(false)


## Every frame: the name card follows the profile (the name editor, the signature, a new id),
## BLOCKED and an open player card follow what changes elsewhere (a block or unblock made from
## the ONLINE window over PROFILE, a name card that arrives), and the player cards are listened
## to while BLOCKED or a player card opened from PROFILE shows (their names and cards).
func process(delta: float) -> void:
	if layer and _card_box and _card_key() != _card_shown:
		_build_card()
	var card_open := _player_box != null and is_instance_valid(_player_box) and _player_box.is_inside_tree()
	if card_open:
		_player_t -= delta
		if _player_t <= 0.0:
			_player_t = 0.5
			if _player_state() != _player_shown:
				_fill_player()
	elif _player_box:
		_player_box = null
	if layer and tab == "blocked":
		_blocked_t -= delta
		if _blocked_t <= 0.0:
			_blocked_t = 0.5
			if _blocked_key() != _blocked_shown:
				_show_tab("blocked", true)
	_want_directory(layer != null and (tab == "blocked" or (card_open and _player_back == "")))


func _want_directory(on: bool) -> void:
	if on == _dir_on:
		return
	_dir_on = on
	if on:
		Game.cloud_service().start_directory("profile")
	elif Game.cloud:
		Game.cloud.stop_directory("profile")


func _tab_button(key: String, text: String) -> Button:
	var b := Button.new()
	b.name = "ProfileTab_" + key
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size = Vector2(TAB_W, 64)
	b.add_theme_font_override("font", UI.font("heavy"))
	b.add_theme_font_size_override("font_size", 25)
	b.draw.connect(func() -> void:
		if key == tab:
			UI.draw_tab_selected(b, b.size))
	b.pressed.connect(func() -> void:
		if key != tab:
			Audio.play("ui_select", -6.0)
			_show_tab(key))
	return b


## A tab's look: the open one yellow with dark text and the marks of a selected tab, the others dark.
func _style_tab(b: Button, on: bool) -> void:
	var base := UI.ACCENT if on else Color(0, 0, 0, 0.55)
	var st := UI.chamfer(base, 10, 0 if on else 1, Color(1, 1, 1, 0.12), 0.0, ["br"])
	st.content_margin_left = 24
	var hover := st.duplicate() as StyleBoxFlat
	hover.bg_color = base.lightened(0.08) if on else Color(1, 1, 1, 0.1)
	for state: String in ["normal", "pressed", "hover_pressed"]:
		b.add_theme_stylebox_override(state, st)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var fg := UI.INK if on else UI.TEXT
	for c: String in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(c, fg)
	b.queue_redraw()


## Shows a tab; again: built anew where it was scrolled to (keep_scroll, BLOCKED after a change).
func _show_tab(key: String, keep_scroll := false) -> void:
	if layer == null:
		return
	var was := _scroll.scroll_vertical
	tab = "career"
	for known: Array in TABS:
		if known[0] == key:
			tab = key
	for t: Array in TABS:
		var b := layer.find_child("ProfileTab_" + String(t[0]), true, false) as Button
		if b:
			_style_tab(b, String(t[0]) == tab)
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	_scroll.scroll_vertical = 0
	if keep_scroll and was > 0:
		_scroll.set_deferred("scroll_vertical", was)      # after the new rows are laid out
	match tab:
		"history":
			_fill_history()
		"namecard":
			_fill_namecard()
		"blocked":
			_fill_blocked()
		_:
			_fill_career()
	UI.drag_scroll(_scroll, _list)          # a finger drag on a row scrolls the tab


## A section title with a dim note after it.
func _head_row(title: String, note: String) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	h.add_child(UI.section(title, 21))
	var n := UI.label(note, 15, UI.TEXT_DIM, "bold")
	n.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	n.size_flags_vertical = Control.SIZE_FILL
	h.add_child(n)
	return h


## A plate with a big title and a dim line under it (a tab with nothing to list).
func _empty_plate(node_name: String, title: String, text: String) -> PanelContainer:
	var p := PanelContainer.new()
	p.name = node_name
	var st := UI.chamfer(Color(1, 1, 1, 0.04), 10, 1, Color(1, 1, 1, 0.08), 24.0, ["br"])
	st.content_margin_top = 26
	st.content_margin_bottom = 26
	p.add_theme_stylebox_override("panel", st)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	p.add_child(v)
	var t := UI.label(title, 28, UI.TEXT, "heavy")
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var l := UI.label(text, 17, UI.TEXT_DIM, "semi")
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(360, 0)
	v.add_child(l)
	return p


# ---------------------------------------------------------------- CAREER

func _fill_career() -> void:
	var p: Dictionary = Game.profile
	_list.add_child(_head_row("TOTALS", "EVERY COUNTED MATCH"))
	var grid := GridContainer.new()
	grid.name = "Career"
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 6)
	_list.add_child(grid)
	for s: Array in career_stats(p):
		grid.add_child(_stat_plate(String(s[0]), String(s[1]), String(s[2])))
	_list.add_child(UI.spacer(4))
	_list.add_child(_head_row("BY MODE", "MATCHES, WINS AND KILLS"))
	for m: String in Game.RECORD_MODES:
		_list.add_child(_mode_plate(m, mode_stats(p, m)))


func _stat_plate(key: String, caption: String, value: String) -> PanelContainer:
	var plate := PanelContainer.new()
	var st := UI.chamfer(Color(1, 1, 1, 0.05), 6, 0, Color.TRANSPARENT, 14.0, ["br"])
	st.content_margin_top = 3
	st.content_margin_bottom = 3
	plate.add_theme_stylebox_override("panel", st)
	plate.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	plate.custom_minimum_size = Vector2(0, 42)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	plate.add_child(h)
	var cap := UI.label(caption, 16, UI.TEXT_DIM, "bold")
	cap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cap.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(cap)
	var rate := key in ["win_rate", "kd", "headshot_rate", "accuracy"]
	var val := UI.label(value, 24, UI.TEXT_DIM if value == "-" else (UI.ACCENT if rate else UI.TEXT), "number")
	val.name = "Career_" + key
	val.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(val)
	return plate


func _mode_plate(m: String, n: Dictionary) -> PanelContainer:
	var plate := PanelContainer.new()
	plate.name = "CareerMode_" + m
	var st := UI.chamfer(Color(1, 1, 1, 0.05), 8, 0, Color.TRANSPARENT, 16.0, ["br"])
	st.content_margin_top = 3
	st.content_margin_bottom = 3
	st.border_width_left = 4
	st.border_color = UI.AMBER
	plate.add_theme_stylebox_override("panel", st)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	plate.add_child(h)
	var title := UI.label(Game.mode_name(m), 25, UI.AMBER, "heavy")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(title)
	for k: Array in [["matches", "MATCHES"], ["wins", "WINS"], ["kills", "KILLS"]]:
		var v := VBoxContainer.new()
		v.custom_minimum_size = Vector2(88, 0)
		v.add_theme_constant_override("separation", -4)
		var num := UI.label(thousands(int(n.get(k[0], 0))), 24, UI.TEXT, "number")
		num.name = String(k[0]).capitalize()
		num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(num)
		var cap := UI.label(String(k[1]), 12, UI.TEXT_DIM, "bold")
		cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(cap)
		h.add_child(v)
	return plate


# ---------------------------------------------------------------- HISTORY

func _fill_history() -> void:
	var history: Array = Game.profile.history
	_list.add_child(_head_row("LAST MATCHES", "NEWEST FIRST  ·  THE LAST %d" % Game.MAX_HISTORY))
	if history.is_empty():
		_list.add_child(_empty_plate("HistoryEmpty", "NO MATCHES YET",
			"Your last %d matches show up here: TRAINING GROUND against bots, LONE WOLF online, SOLO, DUO and SQUAD. A match you quit counts as LEFT, a defeat. The target dummy is not counted." % Game.MAX_HISTORY))
		return
	var now := int(Time.get_unix_time_from_system())
	for i in history.size():
		_list.add_child(_history_row(history[i], i, now))


## One HISTORY row (node HistoryRow_<n>). A match against another player (LONE WOLF: the entry
## keeps their id) is a button with a ">" that opens their card (open_player: ADD FRIEND, DUEL 1 VS
## 1, BLOCK); a match against the bot is a plain plate.
func _history_row(e: Dictionary, i: int, now: int) -> Control:
	var hb := _history_content(e, now)
	var st := UI.chamfer(Color(1, 1, 1, 0.05), 8, 0, Color.TRANSPARENT, 12.0, ["br"])
	st.content_margin_left = 0
	st.content_margin_top = 0
	st.content_margin_bottom = 0
	st.content_margin_right = 40               # every row keeps the ">" room: the columns line up
	var id := String(e.get("id", ""))
	if not Game.is_player_id(id):
		var plate := PanelContainer.new()
		plate.name = "HistoryRow_%d" % i
		plate.add_theme_stylebox_override("panel", st)
		plate.custom_minimum_size = Vector2(0, 64)
		plate.add_child(hb)
		return plate
	var b := Button.new()
	b.name = "HistoryRow_%d" % i
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 64)
	var hover := st.duplicate() as StyleBoxFlat
	hover.bg_color = Color(1, 1, 1, 0.1)
	var down := st.duplicate() as StyleBoxFlat
	down.bg_color = Color(UI.ACCENT, 0.25)
	b.add_theme_stylebox_override("normal", st)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", down)
	b.add_theme_stylebox_override("hover_pressed", down)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	hb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hb.offset_right = -st.content_margin_right       # room for the ">"
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for n in hb.find_children("*", "Control", true, false):
		(n as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE      # the touch is the row button's
	b.add_child(hb)
	b.draw.connect(_draw_chevron.bind(b))
	b.pressed.connect(func() -> void:
		Audio.play("ui_click", -4.0)
		open_player(id, ""))
	return b


## A HISTORY row's content: the result slab (word, rounds), VS the opponent, the mode and how long
## ago, then kills, damage and headshots.
func _history_content(e: Dictionary, now: int) -> HBoxContainer:
	var r := String(e.get("result", "lost"))
	var col := _result_color(r)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)
	var slab := PanelContainer.new()
	var ss := UI.box(Color(col, 0.17), 0, 0, Color.TRANSPARENT, 12.0)
	ss.border_width_left = 5
	ss.border_color = col
	ss.content_margin_top = 4
	ss.content_margin_bottom = 4
	slab.add_theme_stylebox_override("panel", ss)
	slab.custom_minimum_size = Vector2(112, 0)
	var sv := VBoxContainer.new()
	sv.alignment = BoxContainer.ALIGNMENT_CENTER
	sv.add_theme_constant_override("separation", -5)
	slab.add_child(sv)
	var word := UI.label(String(RESULT_WORDS.get(r, "DEFEAT")), 23, col, "heavy")
	word.name = "Result"
	sv.add_child(word)
	if e.get("left_by_them", false) == true:
		# a win because the opponent left: the rounds (often 0 - 2) would read as a loss
		var gone := UI.label("OPPONENT LEFT", 12, UI.TEXT_DIM, "heavy")
		gone.name = "OpponentLeft"
		sv.add_child(gone)
	else:
		var score := UI.label("%d - %d" % [int(e.get("score", 0)), int(e.get("enemy_score", 0))], 20, UI.TEXT, "number")
		score.name = "Score"
		sv.add_child(score)
	hb.add_child(slab)
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.alignment = BoxContainer.ALIGNMENT_CENTER
	info.add_theme_constant_override("separation", -2)
	var texts := history_texts(e)
	var who := UI.ellipsis(UI.label(String(texts[0]), 21, UI.TEXT, "bold"))
	who.name = "Enemy"
	info.add_child(who)
	var when := time_ago(int(e.get("t", 0)), now)
	var sub := UI.ellipsis(UI.label(String(texts[1]) + (" · LOCAL" if e.get("local", false) == true else "")
		+ ("  ·  " + when if when != "" else ""), 14,
		UI.TEXT_DIM, "bold"))
	sub.name = "When"
	info.add_child(sub)
	hb.add_child(info)
	for s: Array in [["kills", "KILLS"], ["damage", "DAMAGE"], ["headshots", "HEADSHOTS"]]:
		var c := VBoxContainer.new()
		c.custom_minimum_size = Vector2(66, 0)
		c.alignment = BoxContainer.ALIGNMENT_CENTER
		c.add_theme_constant_override("separation", -4)
		var val := UI.label(thousands(int(e.get(s[0], 0))), 22, UI.TEXT, "number")
		val.name = String(s[0]).capitalize()
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		c.add_child(val)
		var cap := UI.label(String(s[1]), 12, UI.TEXT_DIM, "bold")
		cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		c.add_child(cap)
		hb.add_child(c)
	return hb


# ---------------------------------------------------------------- NAME CARD

func _fill_namecard() -> void:
	_list.add_child(_head_row("BANNER", "THE ART BEHIND YOUR NAME CARD"))
	var grid := GridContainer.new()
	grid.name = "Banners"
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	_list.add_child(grid)
	for id: String in Game.BANNERS:
		grid.add_child(_banner_choice(id))
	_list.add_child(UI.spacer(4))
	_list.add_child(_head_row("PROFILE PICTURE", "THE EMBLEM OR AN OUTFIT"))
	var row := HBoxContainer.new()
	row.name = "Avatars"
	row.add_theme_constant_override("separation", 12)
	_list.add_child(row)
	for a: String in Game.avatar_ids():
		row.add_child(_avatar_choice(a))
	var note := UI.label("Saved at once. Other players see your name card when they tap your name in their ONLINE window.", 16,
		UI.TEXT_DIM, "semi")
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size = Vector2(300, 0)
	_list.add_child(note)


## Empty styleboxes: the button draws itself.
static func _plain(b: Button) -> void:
	b.focus_mode = Control.FOCUS_NONE
	for st: String in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		b.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	for sig: String in ["mouse_entered", "mouse_exited", "button_down", "button_up"]:
		b.connect(sig, b.queue_redraw)


func _banner_choice(id: String) -> Button:
	var b := Button.new()
	b.name = "Banner_" + id
	b.custom_minimum_size = Vector2(150, 76)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_plain(b)
	var art := banner_texture(id)
	var title := banner_name(id)
	b.draw.connect(func() -> void:
		var sz := b.size
		draw_cover(b, art, Rect2(Vector2.ZERO, sz))
		b.draw_rect(Rect2(0, sz.y - 25, sz.x, 25), Color(0, 0, 0, 0.62))
		b.draw_string(UI.font("bold"), Vector2(10, sz.y - 7), title, HORIZONTAL_ALIGNMENT_LEFT, sz.x - 44, 16, UI.TEXT)
		if String(Game.profile.banner) == id:
			b.draw_rect(Rect2(Vector2(1.5, 1.5), sz - Vector2(3, 3)), UI.ACCENT, false, 3.0)
			UI.draw_tick_corner(b, sz, 30.0)
		elif b.is_hovered() or b.is_pressed():
			b.draw_rect(Rect2(Vector2(1, 1), sz - Vector2(2, 2)), Color(1, 1, 1, 0.75), false, 2.0)
		else:
			b.draw_rect(Rect2(Vector2(0.5, 0.5), sz - Vector2(1, 1)), Color(1, 1, 1, 0.16), false, 1.0))
	b.pressed.connect(func() -> void:
		Audio.play("ui_select", -6.0)
		Game.profile.banner = id
		Game.save_profile()
		_after_card_change())
	return b


func _avatar_choice(avatar: String) -> Button:
	var b := Button.new()
	b.name = "Avatar_" + avatar
	b.custom_minimum_size = Vector2(88, 114)
	b.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_plain(b)
	var title := avatar_name(avatar)
	b.draw.connect(func() -> void:
		var w := b.size.x
		var tile := Rect2(0, 0, w, w)
		b.draw_rect(tile, Color(0.075, 0.075, 0.085, 0.95))
		draw_avatar(b, avatar, tile.grow(-4.0))
		var picked := String(Game.profile.avatar) == avatar
		if picked:
			b.draw_rect(Rect2(Vector2(1.5, 1.5), tile.size - Vector2(3, 3)), UI.ACCENT, false, 3.0)
			UI.draw_tick_corner(b, tile.size, 26.0)
		elif b.is_hovered() or b.is_pressed():
			b.draw_rect(Rect2(Vector2(1, 1), tile.size - Vector2(2, 2)), Color(1, 1, 1, 0.75), false, 2.0)
		else:
			b.draw_rect(Rect2(Vector2(0.5, 0.5), tile.size - Vector2(1, 1)), Color(1, 1, 1, 0.16), false, 1.0)
		b.draw_string(UI.font("bold"), Vector2(0, b.size.y - 6), title, HORIZONTAL_ALIGNMENT_CENTER, w, 13,
			UI.TEXT if picked else UI.TEXT_DIM))
	b.pressed.connect(func() -> void:
		Audio.play("ui_select", -6.0)
		Game.profile.avatar = avatar
		Game.save_profile()
		_after_card_change())
	return b


## A banner or picture was picked: the pickers, the name card and the lobby's player card follow.
func _after_card_change() -> void:
	for n: String in ["Banners", "Avatars"]:
		var box: Node = _list.find_child(n, false, false) if _list else null
		if box:
			for c in box.get_children():
				(c as Control).queue_redraw()
	_build_card()
	lobby.refresh_player_card()


# ---------------------------------------------------------------- BLOCKED

func _fill_blocked() -> void:
	var blocked: Array = Game.profile.blocked
	_blocked_shown = _blocked_key()
	_list.add_child(_head_row("BLOCKED PLAYERS", "%d OF %d" % [blocked.size(), Game.MAX_BLOCKED]))
	var note := UI.label("Their challenges, friend requests and room requests are ignored, and they are left out of your lists. Tap a player to see their card.",
		16, UI.TEXT_DIM, "semi")
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size = Vector2(300, 0)
	_list.add_child(note)
	if blocked.is_empty():
		_list.add_child(_empty_plate("BlockedEmpty", "NO BLOCKED PLAYERS",
			"To block a player, tap their name in the ONLINE window and choose BLOCK on their card."))
		return
	for i in range(blocked.size() - 1, -1, -1):          # the latest block first
		var id := String(blocked[i].id)
		var code := Cloud.friend_code(id)
		var row := HBoxContainer.new()
		row.name = "BlockedRow_" + code
		row.add_theme_constant_override("separation", 12)
		var nb := player_button(id, who_label(id))
		nb.pressed.connect(open_player.bind(id, ""))
		row.add_child(nb)
		var un := UI.button("UNBLOCK", 19, "light", Vector2(170, 56))
		un.name = "Unblock_" + code
		un.pressed.connect(_ask_unblock_listed.bind(id, who_label(id)))
		row.add_child(un)
		_list.add_child(row)


## A player as BLOCKED names them: "NAME  #CODE", or "#CODE" while their name is unknown.
static func who_label(id: String) -> String:
	var who := known_name(id)
	var code := Cloud.friend_code(id)
	return "%s  #%s" % [who, code] if who != "" else "#" + code


## What BLOCKED shows, in one string: the blocks and the names known for them.
func _blocked_key() -> String:
	var parts := PackedStringArray()
	for e: Dictionary in Game.profile.blocked:
		parts.append(who_label(String(e.id)))
	return "|".join(parts)


func _ask_unblock_listed(id: String, who: String) -> void:
	var done := func() -> void:
		Game.unblock(id)
		_show_tab("blocked", true)
	lobby.dialogs.confirm("UNBLOCK PLAYER", "Unblock %s? They can challenge you and send you friend requests again." % who,
		"UNBLOCK", done)


# ---------------------------------------------------------------- the name card (own)

## What the name card shows, in one string: it is built again when this changes.
func _card_key() -> String:
	var p: Dictionary = Game.profile
	return "%s|%s|%s|%s|%s|%d|%d|%s" % [p.name, p.avatar, p.banner, p.signature, p.bundle, int(p.xp), int(p.created),
		Game.cloud_service().my_id]


func _build_card() -> void:
	if _card_box == null:
		return
	for c in _card_box.get_children():
		_card_box.remove_child(c)
		c.queue_free()
	_card_shown = _card_key()
	var p: Dictionary = Game.profile
	_card_box.add_child(_banner_head({"name": String(p.name), "avatar": String(p.avatar), "banner": String(p.banner),
		"level": Game.level()}, _card_w, roundf(_card_w / 3.0), true))
	var body := PanelContainer.new()
	var st := UI.chamfer(Color(0.085, 0.08, 0.075, 0.97), 14, 1, Color(1, 1, 1, 0.08), 16.0, ["br"])
	st.content_margin_top = 10
	st.content_margin_bottom = 14
	st.border_width_top = 0
	body.add_theme_stylebox_override("panel", st)
	_card_box.add_child(body)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	body.add_child(v)
	var my_id := Game.cloud_service().my_id
	var id_row := HBoxContainer.new()
	id_row.add_theme_constant_override("separation", 12)
	v.add_child(id_row)
	var idf := _field("PLAYER ID", "#" + Cloud.friend_code(my_id) if my_id != "" else "GETTING READY...", 26, "heavy", UI.TEXT, "CardId")
	idf.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	id_row.add_child(idf)
	var copy := UI.button("COPY", 18, "light", Vector2(124, 56))
	copy.name = "CardCopy"
	copy.disabled = my_id == ""
	copy.pressed.connect(func() -> void:
		var full := Game.cloud_service().my_id
		if full != "":
			DisplayServer.clipboard_set(full)        # the whole id: a search finds a player by its start
			_copied(copy))
	id_row.add_child(copy)
	var sig_row := HBoxContainer.new()
	sig_row.add_theme_constant_override("separation", 12)
	v.add_child(sig_row)
	var sig := String(p.signature)
	var sig_text := "“%s”" % sig if sig != "" else "NO SIGNATURE YET"
	# The line beside EDIT (the card's inner width less EDIT and the gap) shrinks a long signature
	# to fit, as the name does: other players see it whole on their wider popup.
	var sig_w := _card_w - 32.0 - 56.0 - 12.0
	var sf := _field("SIGNATURE", sig_text, fit_size(sig_text, "semi", 19, 14, sig_w - 4.0), "semi", UI.TEXT if sig != "" else UI.TEXT_DIM,
		"CardSignature")
	sf.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sig_row.add_child(sf)
	var edit := lobby._pencil_button()
	edit.name = "CardEditSignature"
	edit.pressed.connect(edit_signature)
	sig_row.add_child(edit)
	var outfit := CharacterModel.bundle_info(String(p.bundle))
	v.add_child(_field("OUTFIT", String(outfit.name), 20, "bold", LobbyWardrobe.outfit_color(String(outfit.id)), "CardOutfit"))
	var since := UI.label(since_text(int(p.created), int(Time.get_unix_time_from_system())), 15, UI.TEXT_DIM, "bold")
	since.name = "CardSince"
	v.add_child(since)
	_card_box.add_child(UI.spacer(10))
	var note := UI.label("Other players see this name card. Your career and history stay on this phone.", 15, UI.TEXT_DIM, "semi")
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size = Vector2(_card_w, 0)
	_card_box.add_child(note)


## A small caption over a value (the name card's rows); the value label is named `value_name`.
func _field(caption: String, value: String, font_size: int, kind: String, color: Color, value_name: String) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", -3)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(UI.label(caption, 13, UI.TEXT_DIM, "bold"))
	var l := UI.ellipsis(UI.label(value, font_size, color, kind))
	l.name = value_name
	v.add_child(l)
	return v


## COPY says COPIED for a moment.
func _copied(b: Button) -> void:
	b.text = "COPIED"
	lobby.get_tree().create_timer(1.5).timeout.connect(_uncopied.bind(b.get_instance_id()))


func _uncopied(button_id: int) -> void:
	var b := instance_from_id(button_id) as Button
	if b and b.is_inside_tree():
		b.text = "COPY"


## The top of a name card: the banner art with the profile picture, the name and the level over
## its darker left part. own: this player's (the picture opens NAME CARD, the name has EDIT, an
## XP bar to the next level); else another player's (info "status", "online", "friend",
## "blocked": the line under the level).
func _banner_head(info: Dictionary, w: float, h: float, own: bool) -> Control:
	var head := Control.new()
	head.name = "CardHead"
	head.custom_minimum_size = Vector2(w, h)
	head.clip_contents = true
	head.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	var art := banner_texture(String(info.banner))
	head.draw.connect(func() -> void:
		var sz := head.size
		draw_cover(head, art, Rect2(Vector2.ZERO, sz))
		# the left part darker, so the name reads over any banner (their motifs sit on the right)
		var x1 := sz.x * 0.46
		var x2 := sz.x * 0.92
		var a := Color(0, 0, 0, 0.8)
		var b := Color(0, 0, 0, 0.5)
		var c := Color(0, 0, 0, 0.0)
		head.draw_polygon(PackedVector2Array([Vector2.ZERO, Vector2(x1, 0), Vector2(x1, sz.y), Vector2(0, sz.y)]),
			PackedColorArray([a, b, b, a]))
		head.draw_polygon(PackedVector2Array([Vector2(x1, 0), Vector2(x2, 0), Vector2(x2, sz.y), Vector2(x1, sz.y)]),
			PackedColorArray([b, c, c, b]))
		head.draw_rect(Rect2(0, sz.y - 3, sz.x, 3), UI.ACCENT))
	var av_s := h - 36.0
	var avatar := String(info.avatar)
	var av: Control
	if own:
		var ab := Button.new()
		_plain(ab)
		ab.pressed.connect(func() -> void:
			Audio.play("ui_click", -4.0)
			_show_tab("namecard"))
		av = ab
	else:
		av = Control.new()
		av.mouse_filter = Control.MOUSE_FILTER_IGNORE
	av.name = "CardAvatar"
	av.position = Vector2(16, 18)
	av.size = Vector2(av_s, av_s)
	av.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	av.draw.connect(func() -> void: _draw_avatar_tile(av, avatar, own))
	head.add_child(av)
	var x := 16.0 + av_s + 16.0
	var name_w := w - x - (80.0 if own else 16.0)
	var who := String(info.name)
	var nm := UI.ellipsis(UI.outlined(UI.label(who, fit_size(who, "heavy", 31 if own else 36, 22, name_w - 8.0), UI.TEXT, "heavy"),
		4, Color(0, 0, 0, 0.55)))
	nm.name = "CardName"
	nm.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	nm.position = Vector2(x, 10 if own else 14)
	nm.size = Vector2(name_w, 44)
	head.add_child(nm)
	var level := int(info.get("level", 0))
	var lv_row := HBoxContainer.new()
	lv_row.add_theme_constant_override("separation", 10)
	lv_row.position = Vector2(x, 52 if own else 62)
	lv_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(lv_row)
	if level > 0:                          # 0: unknown (a card from before v2, or none yet)
		var lv := UI.outlined(UI.label("LV %d" % level, 23, UI.ACCENT, "heavy"), 3, Color(0, 0, 0, 0.5))
		lv.name = "CardLevel"
		lv_row.add_child(lv)
	if own:
		var edit := lobby._pencil_button()
		edit.name = "CardEditName"
		edit.position = Vector2(w - 12.0 - 56.0, 8)
		edit.pressed.connect(lobby._edit_name)
		head.add_child(edit)
		var xp_now := int(Game.profile.xp) % Game.XP_PER_LEVEL
		var xp_l := UI.outlined(UI.label("%d / %d XP" % [xp_now, Game.XP_PER_LEVEL], 15, UI.TEXT, "bold"), 3, Color(0, 0, 0, 0.5))
		xp_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		xp_l.size_flags_vertical = Control.SIZE_FILL
		lv_row.add_child(xp_l)
		var bar := Control.new()
		bar.name = "CardXp"
		bar.position = Vector2(x, h - 26.0)
		bar.size = Vector2(w - x - 18.0, 8)
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bar.draw.connect(func() -> void:
			bar.draw_rect(Rect2(Vector2.ZERO, bar.size), Color(1, 1, 1, 0.18))
			bar.draw_rect(Rect2(Vector2.ZERO, Vector2(bar.size.x * Game.level_progress(), bar.size.y)), UI.ACCENT))
		head.add_child(bar)
		return head
	for chip: Array in [["FRIEND", UI.ACCENT, UI.INK, bool(info.get("friend", false))],
			["BLOCKED", UI.BAD, UI.TEXT, bool(info.get("blocked", false))]]:
		if chip[3]:
			var pc := PanelContainer.new()
			var cs := UI.chamfer(chip[1], 6, 0, Color.TRANSPARENT, 9.0, ["br"])
			cs.content_margin_top = 1
			cs.content_margin_bottom = 1
			pc.add_theme_stylebox_override("panel", cs)
			pc.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			pc.add_child(UI.label(String(chip[0]), 15, chip[2], "heavy"))
			lv_row.add_child(pc)
	var online := bool(info.get("online", false))
	var st_row := HBoxContainer.new()
	st_row.add_theme_constant_override("separation", 8)
	st_row.position = Vector2(x, 104)
	st_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(st_row)
	var dot := Control.new()
	dot.custom_minimum_size = Vector2(14, 14)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.draw.connect(func() -> void:
		dot.draw_circle(Vector2(7, 7), 6.0, ONLINE_GREEN if online else Color(0.55, 0.55, 0.58))
		dot.draw_circle(Vector2(7, 7), 6.0, Color(0, 0, 0, 0.5), false, 1.5, true))
	st_row.add_child(dot)
	var status := UI.outlined(UI.label(String(info.get("status", "")), 19, ONLINE_GREEN if online else UI.TEXT, "bold"), 3, Color(0, 0, 0, 0.5))
	status.name = "PlayerStatus"
	st_row.add_child(status)
	return head


## A profile picture on its tile with an accent frame; this player's own one (a button) says
## CHANGE along its foot.
func _draw_avatar_tile(c: Control, avatar: String, button: bool) -> void:
	var sz := c.size
	c.draw_rect(Rect2(Vector2.ZERO, sz), Color(0.07, 0.07, 0.08, 0.95))
	draw_avatar(c, avatar, Rect2(Vector2(3, 3), sz - Vector2(6, 6)))
	var hot := button and ((c as Button).is_hovered() or (c as Button).is_pressed())
	if button:
		c.draw_rect(Rect2(3, sz.y - 23, sz.x - 6, 20), Color(0, 0, 0, 0.66))
		c.draw_string(UI.font("bold"), Vector2(3, sz.y - 8), "CHANGE", HORIZONTAL_ALIGNMENT_CENTER, sz.x - 6, 14,
			UI.ACCENT if hot else UI.TEXT)
	c.draw_rect(Rect2(Vector2(1, 1), sz - Vector2(2, 2)), Color.WHITE if hot else UI.ACCENT, false, 2.0)


## The signature line's editor (the name card's EDIT): one line for every player to see, up to
## Game.SIGNATURE_MAX of the name characters (Game.clean_text); empty removes it.
func edit_signature() -> void:
	var v := lobby.dialogs.open_modal("SIGNATURE", 680.0, true)
	var hint := UI.label("A line under your name on your name card, for every player to see: up to %d letters, digits, spaces and _ - ."
		% Game.SIGNATURE_MAX, 16, UI.TEXT_DIM, "semi")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(620, 0)
	v.add_child(hint)
	var le := LineEdit.new()
	le.name = "SignatureEdit"
	le.text = String(Game.profile.signature)
	le.placeholder_text = "E.G. ONE MORE ROUND"
	le.max_length = Game.SIGNATURE_MAX
	le.custom_minimum_size = Vector2(0, 56)
	le.virtual_keyboard_enabled = true
	le.virtual_keyboard_show_on_focus = true
	le.add_theme_font_override("font", UI.font("bold"))
	le.add_theme_font_size_override("font_size", 24)
	le.add_theme_stylebox_override("normal", UI.chamfer(Color(0, 0, 0, 0.5), 8, 1, Color(1, 1, 1, 0.25), 14.0, ["br"]))
	le.add_theme_stylebox_override("focus", UI.chamfer(Color(0, 0, 0, 0.5), 8, 2, UI.ACCENT, 14.0, ["br"]))
	le.add_theme_color_override("font_color", UI.TEXT)
	le.add_theme_color_override("font_placeholder_color", Color(1, 1, 1, 0.35))
	le.add_theme_color_override("caret_color", UI.ACCENT)
	v.add_child(le)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 12)
	var cancel := UI.button("CANCEL", 20, "light", Vector2(170, 56))
	cancel.pressed.connect(lobby.dialogs.close_modal)
	var ok := UI.button("OK", 22, "primary", Vector2(170, 56))
	ok.name = "SignatureOk"
	var apply := func() -> void:
		Game.profile.signature = Game.clean_text(le.text, Game.SIGNATURE_MAX)
		Game.save_profile()
		lobby.dialogs.close_modal()
		_build_card()
	ok.pressed.connect(apply)
	le.text_submitted.connect(func(_t: String) -> void: apply.call())
	row.add_child(cancel)
	row.add_child(ok)
	v.add_child(row)
	# Focus once the popup is up (the keyboard opens under it); carries the field's id, not the
	# field, in case the lobby is gone by then.
	lobby.get_tree().create_timer(0.2).timeout.connect(_focus_field.bind(le.get_instance_id()))


func _focus_field(field_id: int) -> void:
	var le := instance_from_id(field_id) as LineEdit
	if le and le.is_inside_tree():
		le.grab_focus()
		le.caret_column = le.text.length()


# ---------------------------------------------------------------- another player's card

## Another player's card in a popup. back_to: the ONLINE window's tab it was opened from
## ("online", "friends"), opened again when it closes; "" just closes it (PROFILE stays below).
func open_player(id: String, back_to := "") -> void:
	if not Game.is_player_id(id):
		return
	_player_id = id
	_player_back = back_to
	_player_note = ""
	var v := lobby.dialogs.open_modal("PLAYER CARD", POPUP_W)
	lobby.dialogs.modal.set_meta("on_back", _close_player)
	_player_box = VBoxContainer.new()
	_player_box.name = "PlayerCardPopup"
	_player_box.add_theme_constant_override("separation", 12)
	v.add_child(_player_box)
	_fill_player()


## The player card's X and back: to the list it came from.
func _close_player() -> void:
	_player_box = null
	if _player_back != "":
		lobby.friends.open(_player_back, true)          # where the list was scrolled to
		return
	lobby.dialogs.close_modal()
	if layer and tab == "blocked":
		_show_tab("blocked", true)


## What the player card shows that can change while it is open (presence, their card, friends,
## blocks, a challenge): it is filled again on a change.
func _player_state() -> String:
	var cloud := Game.cloud_service()
	var card: Dictionary = cloud.directory.get(_player_id, {})
	var peer: Dictionary = cloud.peers.get(_player_id, {})
	return "%s|%s|%d|%s|%s|%s|%s|%s" % [peer.get("name", "-"), peer.get("bundle", "-"), int(card.get("ts", 0)),
		Game.is_friend(_player_id), cloud.friend_asked(_player_id), Game.is_blocked(_player_id), cloud.waiting_for(), _player_note]


func _fill_player() -> void:
	if _player_box == null or not is_instance_valid(_player_box):
		return
	for c in _player_box.get_children():
		_player_box.remove_child(c)
		c.queue_free()
	_player_shown = _player_state()
	_player_t = 0.5
	var id := _player_id
	var cloud := Game.cloud_service()
	var peer: Dictionary = cloud.peers.get(id, {})
	var card: Dictionary = cloud.directory.get(id, {})
	var online := not peer.is_empty()
	var blocked := Game.is_blocked(id)
	var friend := Game.is_friend(id)
	var who := String(peer.get("name", card.get("name", "")))
	if who == "":
		who = known_name(id)
	if who == "":
		who = "PLAYER"
	var status := "ONLINE NOW"
	if not online:
		status = LobbyFriends._ago(int(card.ts)) if card.has("ts") else "OFFLINE"
	var w := POPUP_W - 52.0
	_player_box.add_child(_banner_head({"name": who, "avatar": String(card.get("avatar", Game.DEFAULT_PROFILE.avatar)),
		"banner": String(card.get("banner", Game.DEFAULT_PROFILE.banner)), "level": int(card.get("level", 0)), "status": status,
		"online": online, "friend": friend, "blocked": blocked}, w, 168.0, false))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	_player_box.add_child(row)
	var idf := _field("PLAYER ID", "#" + Cloud.friend_code(id), 26, "heavy", UI.TEXT, "PlayerId")
	idf.custom_minimum_size = Vector2(190, 0)
	row.add_child(idf)
	var copy := UI.button("COPY", 18, "light", Vector2(124, 56))
	copy.name = "PlayerCopy"
	copy.pressed.connect(func() -> void:
		DisplayServer.clipboard_set(id)
		_copied(copy))
	row.add_child(copy)
	if friend and not blocked:
		row.add_child(LobbyNet.chat_button(lobby, id, who, "card:" + _player_back, 124.0))     # (scripts/lobby_net.gd)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(gap)
	if not (peer.is_empty() and card.is_empty()):           # the outfit only when this phone has seen it
		var outfit := CharacterModel.bundle_info(String(peer.get("bundle", card.get("bundle", "default"))))
		var of := _field("OUTFIT", String(outfit.name), 21, "bold", LobbyWardrobe.outfit_color(String(outfit.id)), "PlayerOutfit")
		of.custom_minimum_size = Vector2(200, 0)
		row.add_child(of)
	var sig := String(card.get("signature", ""))
	var sig_text := "“%s”" % sig
	if sig == "":
		sig_text = "NO SIGNATURE YET" if not card.is_empty() else "NO NAME CARD SEEN YET"
	_player_box.add_child(_field("SIGNATURE", sig_text, 21, "semi", UI.TEXT if sig != "" else UI.TEXT_DIM, "PlayerSignature"))
	var career := LobbyNet.career_block(card, w)        # card v3: their CAREER, or that they hide it
	if career:
		_player_box.add_child(career)
	var note := _player_note
	if note == "" and blocked:
		note = "BLOCKED: THEIR CHALLENGES AND FRIEND REQUESTS ARE IGNORED"
	if note != "":
		var nl := UI.label(note, 17, UI.ACCENT, "bold")
		nl.name = "PlayerNote"
		nl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		nl.custom_minimum_size = Vector2(w, 0)
		_player_box.add_child(nl)
	var acts := HBoxContainer.new()
	acts.alignment = BoxContainer.ALIGNMENT_END
	acts.add_theme_constant_override("separation", 12)
	_player_box.add_child(acts)
	var block_b := UI.button("UNBLOCK" if blocked else "BLOCK", 19, "light" if blocked else "dark", Vector2(170, 56))
	block_b.name = "PlayerBlock"
	block_b.pressed.connect(_ask_block.bind(id, who, blocked))
	acts.add_child(block_b)
	if blocked:
		return
	var fb: Button
	if friend:
		fb = UI.button("REMOVE FRIEND", 19, "dark", Vector2(220, 56))
		fb.pressed.connect(_ask_remove.bind(id, who))
	elif cloud.friend_asked(id):
		fb = UI.button("REQUEST SENT", 19, "dark", Vector2(220, 56))
		fb.disabled = true
	else:
		fb = UI.button("ADD FRIEND", 19, "light", Vector2(220, 56))
		fb.pressed.connect(_add_friend.bind(id))
	fb.name = "PlayerFriend"
	acts.add_child(fb)
	if online:
		var waiting := cloud.waiting_for() != ""
		var duel := UI.button("CANCEL CHALLENGE" if waiting else "DUEL 1 VS 1", 21, "light" if waiting else "primary", Vector2(236, 56))
		duel.name = "PlayerDuel"
		duel.pressed.connect(_duel.bind(id))
		acts.add_child(duel)


## DUEL 1 VS 1 on a player card: back to the ONLINE window, which then shows the challenge waiting
## for an answer (LobbyFriends.challenge; a second tap there or here cancels it).
func _duel(id: String) -> void:
	lobby.friends.open(_player_back if _player_back != "" else "online", _player_back != "")
	lobby.friends.challenge(id)


func _add_friend(id: String) -> void:
	lobby.friends.add_friend(id)
	_player_note = "" if Game.cloud_service().friend_asked(id) else "COULD NOT SEND THE REQUEST (NO CONNECTION?): TRY AGAIN"
	_fill_player()


func _ask_remove(id: String, who: String) -> void:
	var reopen := open_player.bind(id, _player_back)
	var done := func() -> void:
		Game.remove_friend(id)
		reopen.call()
	lobby.dialogs.confirm("REMOVE FRIEND", "Remove %s from your friends? You can send a new friend request later." % who, "REMOVE",
		done, reopen, true)


## BLOCK / UNBLOCK on a player card, asked again. A block hides the player (Game.block): from a
## list, back to it (they are gone from it); else the card shows UNBLOCK.
func _ask_block(id: String, who: String, unblock: bool) -> void:
	var back_to := _player_back
	var reopen := open_player.bind(id, back_to)
	if unblock:
		var undo := func() -> void:
			Game.unblock(id)
			reopen.call()
		lobby.dialogs.confirm("UNBLOCK PLAYER", "Unblock %s? They can challenge you and send you friend requests again." % who,
			"UNBLOCK", undo, reopen)
		return
	var done := func() -> void:
		_block(id)
		if back_to != "":
			lobby.friends.open(back_to, true)
			lobby.friends.note("%s BLOCKED" % who)        # they are gone from the list: say why
		else:
			reopen.call()
	lobby.dialogs.confirm("BLOCK PLAYER", block_question(who), "BLOCK", done, reopen, true)


## The BLOCK question. With BLOCKED full it names the block that a new one lifts (the oldest:
## Game.block_lifts), as that player can challenge and send requests again.
static func block_question(who: String) -> String:
	var t := ("Block %s? Their challenges and friend requests will be ignored, they stop being your friend and they are " +
		"left out of your lists. You can unblock them in PROFILE (tap your player card, top left), under BLOCKED.") % who
	var lifted := Game.block_lifts()
	if not lifted.is_empty():
		t += " BLOCKED is full (%d): this lifts your oldest block, %s." % [Game.MAX_BLOCKED, who_label(String(lifted.id))]
	return t


## A block, online part first (Cloud.drop_player: a challenge either way, their room seat and the
## friend request sent to them end), then the profile (Game.block, with the name this phone knows
## them by, so BLOCKED names them after a restart).
func _block(id: String) -> void:
	var who := known_name(id)
	Game.cloud_service().drop_player(id)
	Game.block(id, who)

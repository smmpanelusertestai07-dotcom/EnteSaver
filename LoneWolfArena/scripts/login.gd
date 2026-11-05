class_name Login
extends Control
## The guest login and the first profile setup (scenes/login.tscn). Game.goto_login() starts a
## session here until the player has passed it (profile.guest_ok); returning players go straight
## to the lobby.
## 1. GUEST LOGIN: the key art with a slow push-in and the logo where the boot screen has them (the
##    hand-over keeps them in place), PLAY AS GUEST, the note that guest progress lives only on
##    this phone, and the consent line whose Terms of Use and Privacy Notice open as in-game
##    popups (no web links; nothing on this screen goes online). Version bottom-right.
## 2. CREATE PROFILE (first time only): the name (the name editor's rules: 14 characters at most,
##    Game.clean_name, RANDOM rolls one), a profile picture (Game.avatar_ids()), a name card
##    (Game.BANNERS), a live preview of the card and the player ID, made on the phone without
##    going online (Cloud.prepare_identity). CONFIRM writes name, name_set, guest_ok, avatar and
##    banner (create_profile), shows WELCOME and goes to the lobby, whose own name prompt then
##    stays shut.
## Android back closes a popup, takes the profile step back to the guest step and on the guest step
## asks before quitting. The Privacy Notice states what scripts/cloud.gd and autoload/game.gd
## really do: change it together with them (tests/login_check.gd holds the two together).
## Node names (tours, tests): GuestButton, TermsLink, PrivacyLink, Modal, Close, ModalOk, DocScroll,
## QuitDialog, QuitCancel, QuitConfirm, BackButton, NameField, NameRandom, NameHint, Avatar_<id>,
## Banner_<id>, NameCard, PlayerId, GuestBadge, ConfirmButton, Welcome. Log markers: "login ready",
## "profile setup", "profile created", and "ui guest", "ui name_field", "ui confirm" (the CI
## emulator test taps there).

const GUEST_NOTE := "Guest progress is saved only on this phone. Uninstalling the game or clearing its data deletes it."
const NAME_HINT := "Up to 14 letters or digits (spaces and . _ - too). Other players see it in matches."
const NAME_EMPTY := "TYPE A NAME OR TAP RANDOM"
## The outfit portraits (assets/ui/bundle_<id>.png, 300 x 400) as profile pictures: head and
## shoulders.
const PORTRAIT_CROP := Rect2(88, 2, 104, 104)
const LOGO_H := 132.0                 # the boot screen's logo (loading.gd _build_boot)
const COL_W := 576.0                  # the profile step's left column (name, pictures, cards)
const CARD := Vector2(600, 200)       # the name card preview (the banners' 3:1)
const BOX_H := 720.0
const TILE := Vector2(86, 86)         # a profile picture
const BANNER_TILE := Vector2(186, 62)

static var _art := {}
static var _dice: Texture2D

var _step := "guest"                  # "guest", "profile", "welcome"
var _modal: Control                   # the open popup (Terms, Privacy, the quit dialog)
var _t := 0.0
var _id_t := 0.0
var _avatar := ""
var _banner := ""
var _keyart: TextureRect
var _fade: ColorRect
var _guest_ui: Control
var _guest_btn: Button
var _profile_ui: Control
var _box: Control
var _fading: Array[Control] = []      # the profile step's parts that leave for WELCOME
var _name_field: LineEdit
var _name_hint: Label
var _confirm_btn: Button
var _tiles: Array[Button] = []
var _card: Control
var _card_art: TextureRect
var _card_avatar: TextureRect
var _card_name: Label
var _card_id: Label
var _id_value: Label
var _id_note: Label


# ---------------------------------------------------------------- shared helpers

## A profile picture's art: the game's emblem, or an outfit portrait's head and shoulders.
static func avatar_texture(id: String) -> Texture2D:
	var key := "avatar:" + id
	if not _art.has(key):
		var t: Texture2D = null
		if id == String(Game.DEFAULT_PROFILE.avatar):
			t = UI.texture("emblem.png")
		elif id in Game.avatar_ids():
			var portrait := UI.texture("bundle_%s.png" % id)
			if portrait:
				var at := AtlasTexture.new()
				at.atlas = portrait
				at.region = PORTRAIT_CROP
				t = at
		_art[key] = t
	return _art[key]


## A name card's art: Game.BANNERS[i] is assets/ui/banners/banner_<i + 1>.png (null if unknown).
static func banner_texture(id: String) -> Texture2D:
	var i := Game.BANNERS.find(id)
	return UI.texture("banners/banner_%d.png" % (i + 1)) if i >= 0 else null


## What CONFIRM writes: the name (cleaned; an empty one keeps the current name), the picture and
## the card (unknown ids keep the current ones), name_set and guest_ok, then the signed save.
static func create_profile(player_name: String, avatar: String, banner: String) -> void:
	var n := Game.clean_name(player_name)
	if n != "":
		Game.profile.name = n
	if avatar in Game.avatar_ids():
		Game.profile.avatar = avatar
	if banner in Game.BANNERS:
		Game.profile.banner = banner
	Game.profile.name_set = true
	Game.profile.guest_ok = true
	Game.save_profile()


## The Privacy Notice as [title, text] sections, true to scripts/cloud.gd and autoload/game.gd:
## the relays are Cloud.BROKERS, the ages Cloud.CARD_MAX_AGE_S and REQUEST_MAX_AGE_S, the chat's
## limits NetChat.HISTORY_MAX, the voice NetVoice (only while TALK is held).
static func privacy_sections() -> Array:
	var hosts := PackedStringArray()
	for url: String in Cloud.BROKERS:
		hosts.append(url.get_slice("://", 1).get_slice("/", 0).get_slice(":", 0))
	var relay := hosts[0]
	if hosts.size() > 1:
		relay += ", or " + ", ".join(hosts.slice(1)) + " as a backup"
	var stun := PackedStringArray()
	for srv: Array in NetDirect.STUN_SERVERS:
		stun.append(String(srv[0]))
	var card_days := roundi(Cloud.CARD_MAX_AGE_S / 86400.0)
	var request_days := roundi(Cloud.REQUEST_MAX_AGE_S / 86400.0)
	return [
		["", "Wolf Arena has no accounts and no servers of its own. This is everything it keeps and everything "
			+ "it shares."],
		["Stored only on this phone", "Your player name, profile picture, name card and outfit, your settings and "
			+ "control layout, your match stats, match history and level, your friends list, friend requests and "
			+ ("blocked players, your last %d chat messages with each friend, and the random key pair behind your player ID. ") % NetChat.HISTORY_MAX
			+ "They stay in the game's private storage on this phone and are left "
			+ "out of phone backups. To spot edited saves, the game signs them with a key made from this phone's "
			+ "device ID; that ID never leaves the phone."],
		["Shared only when online", ("While you play and the phone has internet, the game connects to a free public "
			+ "message relay (%s) so friends can see you online, add you and challenge you. It shares your random "
			+ "player ID, name, outfit and public key there, your name card (profile picture, banner and signature "
			+ "line) and level, your career summary (matches, wins, kills, K/D and headshot rate) unless you turn "
			+ "SHOW MY CAREER off (Settings, ONLINE), and the time you were last online: your player card, which the "
			+ "relay keeps so friends can find you and send you requests while you are offline. Invites and friend "
			+ "requests carry no more than that. Like any internet service, the relay sees your phone's internet (IP) "
			+ "address while it is connected.") % relay],
		["Matches and chat are end-to-end encrypted", "Everything sent during an online match, chat included, is "
			+ "encrypted on the two phones, with keys only they hold, before it leaves them: the relay only passes on "
			+ "scrambled data. A chat message to a friend is encrypted so that only your friend's phone can read it; "
			+ "while they are offline the relay keeps your last unread message for them, and their game deletes it "
			+ "from the relay once it has it. Only friends can message you, never a blocked player; Settings, ONLINE "
			+ "turns chat off."],
		["Direct connection", ("On unless you turn DIRECT CONNECTION off (Settings, ONLINE). For a faster match, "
			+ "the two phones then try to send the game's moves straight to each other instead of through the "
			+ "relay. To find the way, your phone asks public STUN servers (%s) for the internet address they see, "
			+ "so they see your phone's IP address, and the two phones swap their network addresses, encrypted, "
			+ "inside the match. So your opponent's game learns your phone's IP address (and yours learns theirs); "
			+ "the game never shows or keeps it. What goes directly is end-to-end encrypted too. Both players need "
			+ "it on. Turned off, your phone never sends its address and the match goes only through the relay.") % ", ".join(stun)],
		["Voice chat", "Off unless you turn VOICE CHAT on (Settings, ONLINE), which asks for the microphone. The "
			+ "microphone is used only while you hold TALK in an online match: the sound goes straight to the other "
			+ "phone, end-to-end encrypted, and is never stored or recorded, here or anywhere else."],
		["Play without internet", "PLAY WITHOUT INTERNET connects two phones on the same Wi-Fi, or on one phone's "
			+ "hotspot, straight to each other: no relay, no internet, and these games never leave the local network. "
			+ "While you HOST, phones on that network can see your name, outfit, player ID and public key so they can "
			+ "find you; nobody joins without the pairing code your screen shows. The match, chat and voice included, "
			+ "is end-to-end encrypted with keys only the two phones hold. The game uses the Wi-Fi permissions only to "
			+ "find the other phone, never to know where you are."],
		["What the game never does", "No account, no e-mail address or phone number, no ads, no analytics or "
			+ "tracking, no location, no contacts or camera, no microphone except while you hold TALK, and nothing "
			+ "to buy. Apart from the relay and the direct connection above, and the phone you play with on your "
			+ "own network, nothing leaves your phone."],
		["Remove everything", ("Uninstall the game, or clear its data (Android Settings, Apps, Wolf Arena, Storage). "
			+ "That deletes everything the game keeps on this phone, your player ID included, for good. Your last "
			+ "player card stays on the relay: other players' games stop showing it %d days after you were last "
			+ "online, and friend requests and chat messages you sent are dropped after %d days.") % [card_days, request_days]],
	]


## The Terms of Use as [title, text] sections: short, plain, our own words.
static func terms_sections() -> Array:
	return [
		["", "Short and plain: by playing Wolf Arena you accept these terms."],
		["Free to play", "The game is free. There is nothing to buy and there are no ads."],
		["Play fair", "No cheats, hacks, modified game files or tools that give you an edge. A match in which the game "
			+ "detects tampering does not count."],
		["Be decent", "Pick a name that does not insult, threaten or pretend to be someone else. Do not harass other "
			+ "players or flood them with invites, friend requests or messages."],
		["Online play", "Online play runs over free public message relays that we do not run. They can be slow or "
			+ "unavailable at any time, and a match can drop."],
		["Your progress", "Your progress is kept only on this phone. If you uninstall the game or clear its data, it is "
			+ "gone for good."],
		["As is", "The game is provided as is, without any warranty. As far as the law allows, we are not liable "
			+ "for any loss that comes from using it."],
		["Changes", "These terms can change with an update of the game; the version in your game applies."],
	]


# ---------------------------------------------------------------- the scene

func _ready() -> void:
	UI.full_rect(self)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_avatar = String(Game.profile.avatar)
	_banner = String(Game.profile.banner)
	_build_backdrop()
	_build_guest()
	_fade = ColorRect.new()
	_fade.name = "Fade"
	_fade.color = Color(0.02, 0.02, 0.03, 1.0)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UI.full_rect(_fade)
	add_child(_fade)
	create_tween().tween_property(_fade, "color:a", 0.0, 0.35)
	Audio.play_music("lobby_music", -4.0)
	# Where PLAY AS GUEST is, once laid out (a method connection is dropped if the scene goes).
	get_tree().process_frame.connect(_mark_guest, CONNECT_ONE_SHOT | CONNECT_DEFERRED)


func _mark_guest() -> void:
	Game.mark("login ready")
	Game.mark_ui("guest", _guest_btn, _guest_btn.size / 2.0)


func _process(delta: float) -> void:
	_t += delta
	if _keyart:
		# the boot screen's slow push-in on the hero
		var z := 1.0 + 0.035 * clampf(_t / 12.0, 0.0, 1.0)
		_keyart.pivot_offset = _keyart.size * Vector2(0.36, 0.42)
		_keyart.scale = Vector2(z, z)
	if _step != "guest":
		_update_id(delta)


## Android back: closes the popup, goes from the profile step back to the guest step and asks
## before quitting on the guest step.
func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_GO_BACK_REQUEST:
		return
	if _modal:
		_close_modal()
	elif _step == "profile":
		_back_to_guest()
	elif _step == "guest":
		_confirm_quit()


func _build_backdrop() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.05, 0.08)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UI.full_rect(bg)
	add_child(bg)
	var tex := UI.texture("keyart_clean.jpg")
	if tex:
		_keyart = UI.cover(tex)
		add_child(_keyart)
	var shade := UI.gradient_rect([[0.0, Color(0, 0, 0, 0.55)], [0.26, Color(0, 0, 0, 0.0)], [0.5, Color(0, 0, 0, 0.0)],
		[0.76, Color(0, 0, 0, 0.62)], [1.0, Color(0, 0, 0, 0.92)]])
	UI.full_rect(shade)
	add_child(shade)


# ---------------------------------------------------------------- guest login

func _build_guest() -> void:
	_guest_ui = Control.new()
	_guest_ui.name = "GuestStep"
	_guest_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UI.full_rect(_guest_ui)
	add_child(_guest_ui)
	var lg_tex := UI.texture("logo.png")
	if lg_tex:
		# the boot screen's logo, at its place and size
		var lg := TextureRect.new()
		lg.name = "Logo"
		lg.texture = lg_tex
		lg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		lg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
		lg.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		lg.anchor_left = 0.035
		lg.anchor_top = 0.045
		lg.anchor_right = 0.035
		lg.anchor_bottom = 0.045
		lg.offset_right = LOGO_H * lg_tex.get_width() / float(lg_tex.get_height())
		lg.offset_bottom = LOGO_H
		lg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_guest_ui.add_child(lg)
	var col := VBoxContainer.new()
	col.name = "GuestColumn"
	col.alignment = BoxContainer.ALIGNMENT_END
	col.add_theme_constant_override("separation", 8)
	col.anchor_left = 0.5
	col.anchor_right = 0.5
	col.anchor_top = 1.0
	col.anchor_bottom = 1.0
	col.offset_left = -390
	col.offset_right = 390
	col.offset_top = -8
	col.offset_bottom = -8
	col.grow_vertical = Control.GROW_DIRECTION_BEGIN
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_guest_ui.add_child(col)
	_guest_btn = _guest_button()
	col.add_child(_guest_btn)
	col.add_child(UI.spacer(4))
	var note := UI.shadowed(UI.label(GUEST_NOTE, 18, Color(1, 1, 1, 0.88), "semi"), Vector2(0, 2), Color(0, 0, 0, 0.7))
	note.name = "GuestNote"
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(note)
	var consent := HBoxContainer.new()
	consent.name = "Consent"
	consent.alignment = BoxContainer.ALIGNMENT_CENTER
	consent.add_theme_constant_override("separation", 0)
	consent.mouse_filter = Control.MOUSE_FILTER_IGNORE
	consent.add_child(_plain("By playing you accept the "))
	consent.add_child(_link("Terms of Use", "TermsLink", func() -> void: _open_doc("TERMS OF USE", terms_sections())))
	consent.add_child(_plain(" and the "))
	consent.add_child(_link("Privacy Notice", "PrivacyLink", func() -> void: _open_doc("PRIVACY NOTICE", privacy_sections())))
	col.add_child(consent)
	var ver := UI.label("v%s" % ProjectSettings.get_setting("application/config/version", "1.0"), 15, Color(1, 1, 1, 0.55), "semi")
	ver.name = "Version"
	ver.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	ver.offset_left = -160
	ver.offset_right = -22
	ver.offset_top = -34
	ver.offset_bottom = -10
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_guest_ui.add_child(ver)
	_guest_ui.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_interval(0.12)
	tw.tween_property(_guest_ui, "modulate:a", 1.0, 0.3)


## PLAY AS GUEST: the big yellow slab with the guest glyph before the caption (centred as one).
func _guest_button() -> Button:
	var text := "PLAY AS GUEST"
	var size_px := 36
	var b := UI.hero_button(text, size_px, Vector2(480, 84))
	b.name = "GuestButton"
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	b.pressed.connect(_open_profile)
	var glyph := UI.icon("v_guest", 46.0, UI.INK)
	var cap := b.get_node("Caption") as Label
	var avail := 480.0 - 84.0 * 0.25
	var text_w := UI.font("heavy").get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size_px).x
	var x0 := roundf((avail - (46.0 + 14.0 + text_w)) * 0.5)
	glyph.position = Vector2(x0, 19)
	glyph.size = Vector2(46, 46)
	b.add_child(glyph)
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	cap.offset_left = x0 + 60.0
	return b


func _plain(text: String) -> Label:
	var l := UI.shadowed(UI.label(text, 18, Color(1, 1, 1, 0.8), "semi"), Vector2(0, 2), Color(0, 0, 0, 0.7))
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.custom_minimum_size = Vector2(0, UI.TOUCH_MIN)
	return l


## A link in the consent line: accent text with an underline, a full touch target tall.
func _link(text: String, node_name: String, open: Callable) -> Button:
	var b := Button.new()
	b.name = node_name
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, UI.TOUCH_MIN)
	var font := UI.font("bold")
	b.add_theme_font_override("font", font)
	b.add_theme_font_size_override("font_size", 18)
	for st in ["font_color", "font_hover_color", "font_focus_color"]:
		b.add_theme_color_override(st, UI.ACCENT)
	for st in ["font_pressed_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(st, Color(1.0, 0.9, 0.6))
	b.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	b.add_theme_constant_override("outline_size", 3)
	for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		b.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	b.draw.connect(func() -> void:
		var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
		var y := (b.size.y + font.get_height(18)) * 0.5 - font.get_descent(18) + 3.0
		var x := (b.size.x - w) * 0.5
		b.draw_line(Vector2(x, y), Vector2(x + w, y), Color(UI.ACCENT, 0.85), 1.5))
	b.pressed.connect(func() -> void:
		Audio.play("ui_click", -4.0)
		open.call())
	return b


# ---------------------------------------------------------------- the popups

## Terms of Use / Privacy Notice: the lobby's popup look (light header strip with the X, the dark
## body), the text scrolling in the body, OK under it.
func _open_doc(title: String, sections: Array) -> void:
	_close_modal()
	_modal = Control.new()
	_modal.name = "Modal"
	_modal.mouse_filter = Control.MOUSE_FILTER_STOP
	UI.full_rect(_modal)
	add_child(_modal)
	move_child(_fade, -1)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.74)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UI.full_rect(shade)
	_modal.add_child(shade)
	var vs := get_viewport_rect().size
	var w := minf(1000.0, vs.x - 64.0)
	var h := minf(660.0, vs.y - 40.0)
	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 0)
	frame.anchor_left = 0.5
	frame.anchor_right = 0.5
	frame.anchor_top = 0.5
	frame.anchor_bottom = 0.5
	frame.offset_left = -w * 0.5
	frame.offset_right = w * 0.5
	frame.offset_top = -h * 0.5
	frame.offset_bottom = h * 0.5
	_modal.add_child(frame)
	var head := UI.popup_header(title, 26, 54.0)
	(head.get_node("Close") as Button).pressed.connect(_close_modal)
	frame.add_child(head)
	var body := UI.popup_body()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	frame.add_child(body)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	body.add_child(v)
	var scroll := ScrollContainer.new()
	scroll.name = "DocScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	UI.style_scroll(scroll)
	v.add_child(scroll)
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_constant_override("separation", 6)
	scroll.add_child(text)
	for s: Array in sections:
		if String(s[0]) != "":
			text.add_child(UI.spacer(4))
			text.add_child(UI.section(String(s[0]), 19))
		var l := UI.label(String(s[1]), 18, Color(1, 1, 1, 0.9) if String(s[0]) != "" else UI.TEXT_DIM, "semi")
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text.add_child(l)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	var ok := UI.button("OK", 22, "primary", Vector2(200, 56))
	ok.name = "ModalOk"
	ok.pressed.connect(_close_modal)
	row.add_child(ok)
	v.add_child(row)
	_modal.modulate.a = 0.0
	_modal.create_tween().tween_property(_modal, "modulate:a", 1.0, 0.15)


func _close_modal() -> void:
	if _modal:
		_modal.queue_free()
		_modal = null


## "Quit the game?" as the lobby's system dialog: a full-width dark band with the emblem, the
## question, CANCEL (grey) and QUIT (yellow). Back or CANCEL closes it.
func _confirm_quit() -> void:
	_close_modal()
	_modal = Control.new()
	_modal.name = "QuitDialog"
	_modal.mouse_filter = Control.MOUSE_FILTER_STOP
	UI.full_rect(_modal)
	add_child(_modal)
	move_child(_fade, -1)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.62)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UI.full_rect(shade)
	_modal.add_child(shade)
	var band := Control.new()
	band.anchor_right = 1.0
	band.anchor_top = 0.30
	band.anchor_bottom = 0.70
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	band.draw.connect(func() -> void: UI.draw_dialog_band(band, band.size))
	_modal.add_child(band)
	var em := UI.texture("emblem.png")
	if em:
		var t := TextureRect.new()
		t.texture = em
		t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		t.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		t.anchor_left = 0.16
		t.anchor_right = 0.16
		t.anchor_top = 0.5
		t.anchor_bottom = 0.5
		t.offset_left = -84
		t.offset_right = 84
		t.offset_top = -84
		t.offset_bottom = 84
		t.modulate = Color(1, 1, 1, 0.9)
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		band.add_child(t)
	var v := VBoxContainer.new()
	v.anchor_left = 0.3
	v.anchor_right = 0.95
	v.anchor_bottom = 1.0
	v.offset_top = 30
	v.offset_bottom = -24
	v.add_theme_constant_override("separation", 8)
	band.add_child(v)
	v.add_child(UI.label("QUIT THE GAME?", 38, UI.TEXT, "bold"))
	var bar := ColorRect.new()
	bar.color = UI.ACCENT
	bar.custom_minimum_size = Vector2(64, 4)
	bar.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(bar)
	v.add_child(UI.spacer(2))
	v.add_child(UI.label("Come back any time to create your profile.", 19, Color(1, 1, 1, 0.86), "semi"))
	var fill := UI.spacer(0)
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(fill)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 14)
	v.add_child(row)
	var cancel := UI.button("CANCEL", 20, "light", Vector2(190, 56))
	cancel.name = "QuitCancel"
	cancel.pressed.connect(_close_modal)
	row.add_child(cancel)
	var quit := UI.button("QUIT", 22, "primary", Vector2(190, 56))
	quit.name = "QuitConfirm"
	quit.pressed.connect(func() -> void: get_tree().quit())
	row.add_child(quit)
	_modal.modulate.a = 0.0
	_modal.create_tween().tween_property(_modal, "modulate:a", 1.0, 0.12)


# ---------------------------------------------------------------- create profile

## PLAY AS GUEST: the profile step (built once; going back and forth keeps the choices). The
## player ID starts to be made now, on the phone (nothing goes online here).
func _open_profile() -> void:
	if _step != "guest" or _modal:
		return
	_step = "profile"
	Game.cloud_service().prepare_identity()
	if _profile_ui == null:
		_build_profile()
	_profile_ui.visible = true
	_guest_ui.visible = false
	_profile_ui.modulate.a = 0.0
	create_tween().tween_property(_profile_ui, "modulate:a", 1.0, 0.25)
	get_tree().process_frame.connect(_mark_profile, CONNECT_ONE_SHOT | CONNECT_DEFERRED)


func _mark_profile() -> void:
	if _step != "profile":
		return
	Game.mark("profile setup")
	Game.mark_ui("name_field", _name_field, _name_field.size / 2.0)
	Game.mark_ui("confirm", _confirm_btn, _confirm_btn.size / 2.0)


func _back_to_guest() -> void:
	if _step != "profile":
		return
	_step = "guest"
	_name_field.release_focus()
	_hide_keyboard()
	_profile_ui.visible = false
	_guest_ui.visible = true
	_guest_ui.modulate.a = 0.0
	create_tween().tween_property(_guest_ui, "modulate:a", 1.0, 0.2)


func _build_profile() -> void:
	_profile_ui = Control.new()
	_profile_ui.name = "ProfileStep"
	_profile_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UI.full_rect(_profile_ui)
	add_child(_profile_ui)
	move_child(_fade, -1)
	var shade := ColorRect.new()
	shade.color = Color(0.025, 0.025, 0.035, 0.8)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UI.full_rect(shade)
	_profile_ui.add_child(shade)
	var side := UI.gradient_rect([[0.0, Color(0, 0, 0, 0.45)], [0.5, Color(0, 0, 0, 0.0)], [1.0, Color(0, 0, 0, 0.3)]], true)
	UI.full_rect(side)
	_profile_ui.add_child(side)
	# The content: a box centred on the screen, the left column (name, pictures, cards) and the
	# right one (preview, player ID, CONFIRM) with a gap that grows on wide screens.
	var vs := get_viewport_rect().size
	var gap := clampf(vs.x - 80.0 - COL_W - CARD.x, 32.0, 110.0)
	var bw := COL_W + gap + CARD.x
	_box = Control.new()
	_box.name = "ProfileBox"
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.anchor_left = 0.5
	_box.anchor_right = 0.5
	_box.anchor_top = 0.5
	_box.anchor_bottom = 0.5
	_box.offset_left = -bw * 0.5
	_box.offset_right = bw * 0.5
	_box.offset_top = -BOX_H * 0.5
	_box.offset_bottom = BOX_H * 0.5
	_profile_ui.add_child(_box)
	var head := Control.new()
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.size = Vector2(bw, 90)
	_box.add_child(head)
	head.add_child(_back_button())
	var title := UI.label("CREATE YOUR PROFILE", 42, UI.TEXT, "heavy")
	title.position = Vector2(76, 16)
	head.add_child(title)
	var sub := UI.label("Pick a name, a profile picture and a name card.", 18, UI.TEXT_DIM, "semi")
	sub.position = Vector2(78, 62)
	head.add_child(sub)
	_fading.append(head)
	var left := _build_left()
	left.position = Vector2(0, 108)
	left.size = Vector2(COL_W, 0)
	_box.add_child(left)
	_fading.append(left)
	var rx := COL_W + gap
	var prev := UI.section("PREVIEW", 20)
	prev.position = Vector2(rx, 108)
	_box.add_child(prev)
	_fading.append(prev)
	_card = _build_card()
	_card.position = Vector2(rx, 144)
	_box.add_child(_card)
	var id_row := HBoxContainer.new()
	id_row.add_theme_constant_override("separation", 14)
	id_row.position = Vector2(rx, 360)
	id_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var id_cap := UI.label("PLAYER ID", 19, UI.TEXT_DIM, "bold")
	id_cap.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	id_cap.size_flags_vertical = Control.SIZE_FILL
	id_row.add_child(id_cap)
	_id_value = UI.label("", 30, UI.TEXT, "heavy")
	_id_value.name = "PlayerId"
	id_row.add_child(_id_value)
	_box.add_child(id_row)
	_fading.append(id_row)
	_id_note = UI.label("", 17, UI.TEXT_DIM, "semi")
	_id_note.position = Vector2(rx, 400)
	_id_note.size = Vector2(CARD.x, 24)
	_box.add_child(_id_note)
	_fading.append(_id_note)
	var badge := _guest_badge()
	badge.position = Vector2(rx, 452)
	_box.add_child(badge)
	_fading.append(badge)
	_confirm_btn = UI.hero_button("CONFIRM", 40, Vector2(340, 84))
	_confirm_btn.name = "ConfirmButton"
	_confirm_btn.position = Vector2(rx + CARD.x - 340.0, BOX_H - 30.0 - 84.0)
	_confirm_btn.size = Vector2(340, 84)
	_confirm_btn.pressed.connect(_confirm)
	_box.add_child(_confirm_btn)
	_fading.append(_confirm_btn)
	_refresh()
	_update_id(0.0)


## What a guest profile is: kept only on this phone, the name can change later.
func _guest_badge() -> PanelContainer:
	var p := PanelContainer.new()
	p.name = "GuestBadge"
	p.custom_minimum_size = Vector2(CARD.x, 0)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var st := UI.chamfer(Color(1, 1, 1, 0.05), 8, 1, Color(1, 1, 1, 0.1), 14.0, ["br"])
	st.content_margin_top = 10
	st.content_margin_bottom = 10
	p.add_theme_stylebox_override("panel", st)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	h.add_child(UI.icon("v_guest", 42.0, UI.ACCENT))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", -2)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(UI.label("GUEST PROFILE", 19, UI.TEXT, "bold"))
	var l := UI.label("Saved only on this phone. You can change your name later in the lobby.", 16, UI.TEXT_DIM, "semi")
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(l)
	h.add_child(v)
	p.add_child(h)
	return p


func _back_button() -> Button:
	var b := Button.new()
	b.name = "BackButton"
	b.position = Vector2(0, 20)
	b.size = Vector2(56, 56)
	b.custom_minimum_size = b.size
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_stylebox_override("normal", UI.chamfer(Color(0, 0, 0, 0.45), 6, 1, Color(1, 1, 1, 0.2), 6.0, ["br"]))
	b.add_theme_stylebox_override("hover", UI.chamfer(Color(1, 1, 1, 0.12), 6, 1, Color(1, 1, 1, 0.3), 6.0, ["br"]))
	b.add_theme_stylebox_override("pressed", UI.chamfer(Color(UI.ACCENT, 0.35), 6, 1, UI.ACCENT, 6.0, ["br"]))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.draw.connect(func() -> void:
		var c := b.size * 0.5
		var r := b.size.y * 0.17
		b.draw_polyline(PackedVector2Array([c + Vector2(r * 0.5, -r * 1.25), c + Vector2(-r * 0.75, 0.0),
			c + Vector2(r * 0.5, r * 1.25)]), UI.TEXT, 3.5, true))
	b.pressed.connect(func() -> void:
		Audio.play("ui_back", -4.0)
		_back_to_guest())
	return b


## The left column: PLAYER NAME (field, RANDOM, the rules), PROFILE PICTURE, NAME CARD.
func _build_left() -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(UI.section("PLAYER NAME", 20))
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 10)
	_name_field = LineEdit.new()
	_name_field.name = "NameField"
	_name_field.text = String(Game.profile.name) if bool(Game.profile.name_set) else Game.random_name()
	_name_field.placeholder_text = "YOUR NAME"
	_name_field.max_length = Game.NAME_MAX
	_name_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_field.custom_minimum_size = Vector2(0, 56)
	_name_field.virtual_keyboard_enabled = true
	_name_field.virtual_keyboard_show_on_focus = true
	_name_field.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_DEFAULT
	_name_field.select_all_on_focus = true
	_name_field.add_theme_font_override("font", UI.font("bold"))
	_name_field.add_theme_font_size_override("font_size", 26)
	_name_field.add_theme_stylebox_override("normal", UI.chamfer(Color(0, 0, 0, 0.5), 8, 1, Color(1, 1, 1, 0.25), 14.0, ["br"]))
	_name_field.add_theme_stylebox_override("focus", UI.chamfer(Color(0, 0, 0, 0.5), 8, 2, UI.ACCENT, 14.0, ["br"]))
	_name_field.add_theme_color_override("font_color", UI.TEXT)
	_name_field.add_theme_color_override("font_placeholder_color", Color(1, 1, 1, 0.35))
	_name_field.add_theme_color_override("caret_color", UI.ACCENT)
	_name_field.text_changed.connect(func(_new: String) -> void: _refresh())
	_name_field.text_submitted.connect(func(_new: String) -> void:
		_name_field.release_focus()
		_hide_keyboard())
	line.add_child(_name_field)
	var dice := UI.button("RANDOM", 20, "light", Vector2(164, 56))
	dice.name = "NameRandom"
	dice.icon = _dice_texture()
	dice.add_theme_constant_override("h_separation", 10)
	dice.pressed.connect(func() -> void:
		_name_field.text = Game.random_name()
		_name_field.caret_column = _name_field.text.length()
		_refresh())
	line.add_child(dice)
	v.add_child(line)
	_name_hint = UI.label(NAME_HINT, 16, UI.TEXT_DIM, "semi")
	_name_hint.name = "NameHint"
	v.add_child(_name_hint)
	v.add_child(UI.spacer(4))
	v.add_child(UI.section("PROFILE PICTURE", 20))
	var pics := HBoxContainer.new()
	pics.add_theme_constant_override("separation", 12)
	for id: String in Game.avatar_ids():
		pics.add_child(_tile("Avatar_" + id, TILE, avatar_texture(id), func() -> bool: return _avatar == id,
			func() -> void: _avatar = id))
	v.add_child(pics)
	v.add_child(UI.spacer(4))
	v.add_child(UI.section("NAME CARD", 20))
	var cards := GridContainer.new()
	cards.columns = 3
	cards.add_theme_constant_override("h_separation", 9)
	cards.add_theme_constant_override("v_separation", 9)
	for id: String in Game.BANNERS:
		cards.add_child(_tile("Banner_" + id, BANNER_TILE, banner_texture(id), func() -> bool: return _banner == id,
			func() -> void: _banner = id))
	v.add_child(cards)
	return v


## A picture choice: the art in a dark frame; the chosen one gets the yellow outline and tick.
func _tile(node_name: String, tile_size: Vector2, tex: Texture2D, chosen: Callable, choose: Callable) -> Button:
	var b := Button.new()
	b.name = node_name
	b.custom_minimum_size = tile_size
	b.focus_mode = Control.FOCUS_NONE
	b.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		b.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	b.draw.connect(func() -> void:
		var s := b.size
		var on := bool(chosen.call())
		b.draw_rect(Rect2(Vector2.ZERO, s), Color(0.1, 0.1, 0.12, 0.92))
		if tex:
			_draw_cover(b, tex, Rect2(Vector2(3, 3), s - Vector2(6, 6)), Color(1, 1, 1) if on else Color(0.82, 0.82, 0.82))
		if b.is_pressed():
			b.draw_rect(Rect2(Vector2.ZERO, s), Color(1, 1, 1, 0.12))
		b.draw_rect(Rect2(Vector2(1.5, 1.5), s - Vector2(3, 3)), UI.ACCENT if on else Color(1, 1, 1, 0.2), false, 3.0 if on else 1.0)
		if on:
			UI.draw_tick_corner(b, s, 26.0))
	b.button_down.connect(b.queue_redraw)
	b.button_up.connect(b.queue_redraw)
	b.pressed.connect(func() -> void:
		Audio.play("ui_select", -6.0)
		choose.call()
		_refresh())
	_tiles.append(b)
	return b


## The name card preview: the banner, the picture in a yellow frame, the name, the level and the
## player ID.
func _build_card() -> Control:
	var card := Control.new()
	card.name = "NameCard"
	card.size = CARD
	card.pivot_offset = CARD * 0.5
	card.clip_contents = true
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card_art = TextureRect.new()
	_card_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_card_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_card_art.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_card_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card_art.size = CARD
	card.add_child(_card_art)
	var shade := UI.gradient_rect([[0.0, Color(0, 0, 0, 0.8)], [0.45, Color(0, 0, 0, 0.42)], [0.8, Color(0, 0, 0, 0.0)]], true)
	shade.size = CARD
	card.add_child(shade)
	var frame := Panel.new()
	frame.position = Vector2(26, 30)
	frame.size = Vector2(140, 140)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_theme_stylebox_override("panel", UI.box(Color(0.08, 0.08, 0.1), 0, 3, UI.ACCENT, 0.0))
	card.add_child(frame)
	_card_avatar = TextureRect.new()
	_card_avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_card_avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_card_avatar.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_card_avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card_avatar.position = Vector2(3, 3)
	_card_avatar.size = Vector2(134, 134)
	frame.add_child(_card_avatar)
	_card_name = UI.ellipsis(UI.shadowed(UI.label("", 44, UI.TEXT, "heavy"), Vector2(0, 3), Color(0, 0, 0, 0.6)))
	_card_name.position = Vector2(190, 36)
	_card_name.size = Vector2(390, 52)
	card.add_child(_card_name)
	var lv := PanelContainer.new()
	lv.position = Vector2(192, 98)
	lv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lv.add_theme_stylebox_override("panel", UI.chamfer(UI.ACCENT, 6, 0, Color.TRANSPARENT, 10.0, ["br"]))
	lv.add_child(UI.label("LV %d" % Game.level(), 20, UI.INK, "heavy"))
	card.add_child(lv)
	_card_id = UI.shadowed(UI.label("", 18, Color(1, 1, 1, 0.82), "bold"), Vector2(0, 2), Color(0, 0, 0, 0.6))
	_card_id.position = Vector2(192, 138)
	_card_id.size = Vector2(390, 26)
	card.add_child(_card_id)
	var edge := ColorRect.new()
	edge.color = UI.ACCENT
	edge.position = Vector2(0, CARD.y - 4.0)
	edge.size = Vector2(CARD.x, 4)
	edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(edge)
	var border := Panel.new()
	border.size = CARD
	border.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bs := UI.box(Color.TRANSPARENT, 0, 1, Color(1, 1, 1, 0.22), 0.0)
	bs.draw_center = false
	border.add_theme_stylebox_override("panel", bs)
	card.add_child(border)
	return card


## Brings the preview and the choices in line with the field and the picks.
func _refresh() -> void:
	if _card == null:
		return
	var n := Game.clean_name(_name_field.text)
	_card_name.text = n if n != "" else "YOUR NAME"
	_card_name.modulate.a = 1.0 if n != "" else 0.45
	_card_avatar.texture = avatar_texture(_avatar)
	_card_art.texture = banner_texture(_banner)
	if n != "" and _name_hint.text != NAME_HINT:
		_name_hint.text = NAME_HINT
		_name_hint.add_theme_color_override("font_color", UI.TEXT_DIM)
	for b in _tiles:
		b.queue_redraw()


## The player ID: "creating..." until the key exists (it is made off the main thread), then the
## short code friends add this player by (Cloud.friend_code).
func _update_id(delta: float) -> void:
	if _id_value == null:
		return
	_id_t += delta
	var id := Game.cloud.my_id if Game.cloud else ""
	if id != "":
		var code := Cloud.friend_code(id)
		if _id_value.text != code:
			_id_value.text = code
			_id_value.add_theme_color_override("font_color", UI.TEXT)
			_id_note.text = "Made on this phone. Friends can add you by this ID."
			_card_id.text = "ID  " + code
	else:
		var dots := ".".repeat(1 + int(_id_t * 3.0) % 3)
		_id_value.text = "CREATING" + dots
		_id_value.add_theme_color_override("font_color", UI.TEXT_DIM)
		_id_note.text = "Creating your player ID on this phone..."
		_card_id.text = "ID  --------"


func _confirm() -> void:
	if _step != "profile":
		return
	var n := Game.clean_name(_name_field.text)
	if n == "":
		_name_hint.text = NAME_EMPTY
		_name_hint.add_theme_color_override("font_color", UI.BAD)
		var x := _name_field.position.x
		var tw := create_tween()
		for dx in [10.0, -8.0, 6.0, -3.0, 0.0]:
			tw.tween_property(_name_field, "position:x", x + float(dx), 0.04)
		return
	_name_field.release_focus()
	_hide_keyboard()
	create_profile(n, _avatar, _banner)
	Game.mark("profile created")
	_welcome()


## WELCOME: the choices fade, the name card moves to the middle and grows, WELCOME pops in above
## it; then a fade to the lobby.
func _welcome() -> void:
	_step = "welcome"
	_name_field.editable = false
	for c in _fading:
		create_tween().tween_property(c, "modulate:a", 0.0, 0.2)
	var to := Vector2((_box.size.x - CARD.x) * 0.5, (BOX_H - CARD.y) * 0.5 + 30.0)
	var tw := create_tween().set_parallel()
	tw.tween_property(_card, "position", to, 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_card, "scale", Vector2(1.1, 1.1), 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	var hi := UI.shadowed(UI.outlined(UI.label("WELCOME", 88, UI.ACCENT, "italic"), 8, Color(0.06, 0.05, 0.03, 0.95)),
		Vector2(0, 6), Color(0, 0, 0, 0.5))
	hi.name = "Welcome"
	hi.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hi.position = Vector2(0, to.y - 150.0)
	hi.size = Vector2(_box.size.x, 110)
	UI.center_italic(hi, 88)
	hi.pivot_offset = hi.size * 0.5
	hi.modulate.a = 0.0
	hi.scale = Vector2(1.4, 1.4)
	_box.add_child(hi)
	var ready_l := UI.label("YOUR PROFILE IS READY", 24, UI.TEXT, "bold")
	ready_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ready_l.position = Vector2(0, to.y + CARD.y + 34.0)
	ready_l.size = Vector2(_box.size.x, 30)
	ready_l.modulate.a = 0.0
	_box.add_child(ready_l)
	var pop := create_tween().set_parallel()
	pop.tween_property(hi, "modulate:a", 1.0, 0.2).set_delay(0.25)
	pop.tween_property(hi, "scale", Vector2.ONE, 0.3).set_delay(0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	pop.tween_property(ready_l, "modulate:a", 1.0, 0.25).set_delay(0.45)
	var go := create_tween()
	go.tween_interval(1.5)
	go.tween_property(_fade, "color:a", 1.0, 0.3)
	go.tween_callback(Game.goto_lobby)


## Puts the on-screen keyboard away (where there is one: a desktop has none and would warn).
static func _hide_keyboard() -> void:
	if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		DisplayServer.virtual_keyboard_hide()


## Draws `tex` filling `r` like CSS "cover" (centred crop, never stretched).
static func _draw_cover(ci: CanvasItem, tex: Texture2D, r: Rect2, col: Color) -> void:
	var ts := tex.get_size()
	var want := r.size.x / maxf(r.size.y, 1.0)
	var src := Rect2(Vector2.ZERO, ts)
	if ts.x / ts.y > want:
		src = Rect2((ts.x - ts.y * want) * 0.5, 0.0, ts.y * want, ts.y)
	else:
		src = Rect2(0.0, (ts.y - ts.x / want) * 0.5, ts.x, ts.x / want)
	ci.draw_texture_rect_region(tex, r, src, col)


## A small die for RANDOM (dark, three light pips), made once.
static func _dice_texture() -> Texture2D:
	if _dice:
		return _dice
	var n := 30
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var pips := [Vector2(8.5, 8.5), Vector2(15.0, 15.0), Vector2(21.5, 21.5)]
	for y in n:
		for x in n:
			var p := Vector2(x + 0.5, y + 0.5)
			# a rounded square with 6 px corners, anti-aliased over a pixel
			var q := Vector2(maxf(absf(p.x - 15.0) - 8.0, 0.0), maxf(absf(p.y - 15.0) - 8.0, 0.0))
			var a := clampf(0.5 - (q.length() - 6.0), 0.0, 1.0)
			if a <= 0.0:
				continue
			var col := Color(UI.INK, a)
			for c: Vector2 in pips:
				var pa := clampf(0.5 - (p.distance_to(c) - 2.9), 0.0, 1.0)
				if pa > 0.0:
					col = Color(UI.INK.lerp(UI.LIGHT, pa), a)
			img.set_pixel(x, y, col)
	_dice = ImageTexture.create_from_image(img)
	return _dice

class_name SettingsAccount
extends RefCounted
## SettingsPanel's ACCOUNT tab, in the reference's account-section style (our own words; there is
## no account: a guest profile lives on this phone only):
##  - ACCOUNT: the player ID (the short code friends add you by) and COPY (the whole ID to the
##    clipboard);
##  - TOOLS: CLEAR CACHE (SettingsPanel.cache_row);
##  - along the bottom, as links in the hint's place: DELETE MY DATA on the left (in a match a note
##    instead: it belongs to the lobby), the TERMS OF USE and the PRIVACY NOTICE on the right
##    (Login's own texts, as pages over the panel: SettingsPanel.open_doc).
## DELETE MY DATA asks twice, then shows a screen that waits (back and the X do nothing, the panel
## is `busy`): a relay still connecting is waited for (RELAY_WAIT_S at most, with challenges and
## friend requests shut off meanwhile), forget_everything() asks it to delete what this phone left
## there and resets the game's memory, and FLUSH_S later erase_files() deletes the saves, the key,
## the chats and the caches. A notice says what was done; its OK goes to the guest login.
## Node names: PlayerIdValue, CopyId, ClearCache, AccountLinks, DeleteData, DeleteNote, TermsLink,
## PrivacyLink, Erasing (EraseText, EraseOk).

const RELAY_WAIT_S := 6.0
const FLUSH_S := 1.2
## What a save, its .bak / .tmp or a key is kept in at the top of user:// (erase_files).
const SAVE_EXTENSIONS := ["json", "key", "bak", "tmp", "bin"]     # (bin: the session file a match is rejoined from, Cloud.resume_path)
const DELETE_TEXT := ("Delete everything Wolf Arena keeps on this phone: your profile and player ID, level, stats and "
	+ "match history, friends, blocked players and chats, your settings and HUD layout? Online, the game also asks "
	+ "the relay to delete your player card and the friend requests and messages waiting there.")
const SURE_TEXT := "%s and all your progress will be gone for good: this cannot be undone. The game then starts again at the guest login."


static func build(panel: SettingsPanel) -> void:
	var body: VBoxContainer = panel._body
	body.add_child(UI.section("ACCOUNT"))
	var id := String(Game.cloud.my_id) if Game.cloud else ""
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	box.alignment = BoxContainer.ALIGNMENT_END
	var value := UI.label(Cloud.friend_code(id) if id != "" else "--------", 26, UI.TEXT if id != "" else UI.TEXT_DIM, "number")
	value.name = "PlayerIdValue"
	value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	box.add_child(value)
	var copy := UI.button("COPY", 18, "light", Vector2(130, UI.TOUCH_MIN))
	copy.name = "CopyId"
	copy.disabled = id == ""
	copy.pressed.connect(func() -> void:
		DisplayServer.clipboard_set(id)
		copy.text = "COPIED")
	box.add_child(copy)
	body.add_child(panel._plate("Player ID", box, "A guest profile: no account, kept only on this phone. Friends add you by this ID"))
	body.add_child(UI.spacer(4))
	body.add_child(UI.section("TOOLS"))
	body.add_child(panel.cache_row())
	var links := HBoxContainer.new()
	links.name = "AccountLinks"
	links.add_theme_constant_override("separation", 30)
	if panel.in_match:
		var note := UI.label("DELETE MY DATA: IN THE LOBBY", 16, UI.TEXT_DIM, "bold")
		note.name = "DeleteNote"
		note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		note.size_flags_vertical = Control.SIZE_FILL
		links.add_child(note)
	else:
		links.add_child(link("Delete my data", "DeleteData", func() -> void: ask_delete(panel)))
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	links.add_child(gap)
	links.add_child(link("Terms of Use", "TermsLink", func() -> void: panel.open_doc("TERMS OF USE", Login.terms_sections())))
	links.add_child(link("Privacy Notice", "PrivacyLink", func() -> void: panel.open_doc("PRIVACY NOTICE", Login.privacy_sections())))
	panel.set_footer(links)


## A link along the bottom: light underlined text, a full touch target tall.
static func link(text: String, node_name: String, open: Callable) -> Button:
	var b := Button.new()
	b.name = node_name
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, UI.TOUCH_MIN)
	var font := UI.font("semi")
	b.add_theme_font_override("font", font)
	b.add_theme_font_size_override("font_size", 18)
	for st in ["font_color", "font_hover_color", "font_focus_color"]:
		b.add_theme_color_override(st, Color(UI.TEXT, 0.88))
	for st in ["font_pressed_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(st, UI.ACCENT)
	var pad := StyleBoxEmpty.new()
	pad.content_margin_left = 6
	pad.content_margin_right = 6
	for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		b.add_theme_stylebox_override(st, pad)
	b.draw.connect(func() -> void:
		var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
		var y := (b.size.y + font.get_height(18)) * 0.5 - font.get_descent(18) + 3.0
		var x := (b.size.x - w) * 0.5
		b.draw_line(Vector2(x, y), Vector2(x + w, y), UI.ACCENT if b.is_pressed() else Color(UI.TEXT, 0.6), 1.5))
	b.pressed.connect(func() -> void:
		Audio.play("ui_click", -4.0)
		open.call())
	return b


# ---------------------------------------------------------------- DELETE MY DATA

## DELETE MY DATA asks twice (the second time naming the player ID), then deletes (run_delete).
static func ask_delete(panel: SettingsPanel) -> void:
	panel._ask("DELETE MY DATA", DELETE_TEXT, "DELETE", func() -> void:
		var id := String(Game.cloud.my_id) if Game.cloud else ""
		var who := ("Your player ID %s" % Cloud.friend_code(id)) if id != "" else "Your profile"
		panel._ask("ARE YOU SURE?", SURE_TEXT % who, "DELETE FOREVER", func() -> void: run_delete(panel), true), true)


## The deletion behind its waiting screen, then the notice whose OK opens the guest login.
static func run_delete(panel: SettingsPanel) -> void:
	panel.busy = true
	var layer := _erasing_screen(panel)
	var text := layer.find_child("EraseText", true, false) as Label
	var tree := panel.get_tree()
	var cloud: Cloud = Game.cloud
	if cloud and cloud.my_id != "" and cloud.status != "online":
		# The relay is still connecting (or there is no internet): wait a little for it, with
		# nobody able to reach this player meanwhile (a challenge or request is turned away).
		Game.settings.challenges_from = Game.CHALLENGES_NOBODY
		Game.settings.friend_requests = false
		text.text = "Reaching the relay to delete your player card..."
		var waited := 0.0
		while waited < RELAY_WAIT_S and cloud.status != "online":
			await tree.create_timer(0.25).timeout
			waited += 0.25
	if not is_instance_valid(panel):
		return
	text.text = "Deleting your data..."
	var told := forget_everything()
	await tree.create_timer(FLUSH_S).timeout     # the relay's deletes go out meanwhile
	if Game.autotest == "":
		erase_files()
	if not is_instance_valid(panel):
		return
	text.text = done_text(told)
	var ok := layer.find_child("EraseOk", true, false) as Button
	ok.visible = true
	ok.pressed.connect(func() -> void:
		panel.busy = false
		tree.paused = false
		Engine.time_scale = 1.0
		tree.change_scene_to_file("res://scenes/login.tscn"))


## What the notice after the deletion says: everything on the phone is gone, and whether the relay
## was asked to delete its copies (else how long the old card stays listed).
static func done_text(told: bool) -> String:
	if told:
		return ("Everything Wolf Arena kept on this phone is deleted, and the relay was asked to delete your player card, "
			+ "friend requests and messages.")
	return ("Everything Wolf Arena kept on this phone is deleted. The relay could not be reached: if this phone was ever "
		+ "online, other players' games stop showing your old player card %d days after you were last online.") \
		% roundi(Cloud.CARD_MAX_AGE_S / 86400.0)


## The waiting screen over the panel (node "Erasing"): a dark box with the title, a line that
## says what happens (EraseText) and an OK (EraseOk) hidden until the end.
static func _erasing_screen(panel: SettingsPanel) -> Control:
	var layer := Control.new()
	layer.name = "Erasing"
	UI.full_rect(layer)
	layer.mouse_filter = Control.MOUSE_FILTER_STOP
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.74)
	UI.full_rect(shade)
	layer.add_child(shade)
	var center := CenterContainer.new()
	UI.full_rect(center)
	layer.add_child(center)
	var box := UI.panel(Color(0.085, 0.08, 0.075, 0.98), 12, 1)
	center.add_child(box)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 16)
	box.add_child(v)
	v.add_child(UI.section("DELETE MY DATA", 24))
	var t := UI.label("", 19, UI.TEXT, "semi")
	t.name = "EraseText"
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	t.custom_minimum_size = Vector2(560, 0)
	v.add_child(t)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	var ok := UI.button("OK", 20, "primary", Vector2(200, UI.TOUCH_MIN))
	ok.name = "EraseOk"
	ok.visible = false
	row.add_child(ok)
	v.add_child(row)
	panel.add_child(layer)
	return layer


## Forgets this player everywhere the game can (DELETE MY DATA): the relay's copies and the
## identity (Cloud.forget_me; PLAY WITHOUT INTERNET's copy of it too), then the game's memory as
## on a new install: settings, profile (the guest login comes back), HUD layout, the chats and the
## session's choices. The files are erase_files'. Returns whether the relay was told.
static func forget_everything() -> bool:
	var told := false
	if Game.cloud:
		told = Game.cloud.forget_me()
	if Game.lan:
		Game.lan.stop()
		Game.lan.forget_me()
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	Game.hud_layout = {}
	Game.last_result = {}
	Game.practice = false
	Game.online = false
	Game.session = null
	Game.room_rules = {}
	Game.match_notice = []
	Game.reset_settings()
	# The chats: an empty store that is not read from the file again (erase_files deletes it).
	NetChat._store = {}
	NetChat._loaded = true
	return told


## Deletes the game's files under `root` (user:// in the game): every file at its top level that a
## save, its .bak / .tmp or the identity key is kept in (profile, settings, HUD layout, chats), and
## what CLEAR CACHE deletes (shader caches, old logs). Returns how many files went.
static func erase_files(root := "user://") -> int:
	var n := 0
	if DirAccess.dir_exists_absolute(root):
		for f in DirAccess.get_files_at(root):
			if f.get_extension() in SAVE_EXTENSIONS and DirAccess.remove_absolute(root.path_join(f)) == OK:
				n += 1
	n += CacheCleaner.scan(root).files.size()
	CacheCleaner.clear(root)
	return n

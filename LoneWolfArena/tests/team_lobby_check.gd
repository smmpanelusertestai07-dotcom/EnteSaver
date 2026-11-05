extends Node
## DUO / SQUAD in the lobby (WP-B1), one copy of the game, run by tools/qa/run_checks.sh with
## LW_FILL_S=3 and a relay that is never there (LW_MQTT_URL=ws://127.0.0.1:9: nothing leaves the
## machine). Real taps where a player taps:
## - a team match left over is cleared when the lobby opens;
## - SELECT MODE has the size chips Size_1 / 2 / 4 on both mode cards; DUO updates the mode card;
##   the DUMMY is SOLO only;
## - the TEAM bar shows in DUO (+ INVITE) and SQUAD (+ INVITE, two BOT tiles), hides in SOLO;
## - INVITE lists stand-in friends (online first, INVITE only on them; offline ones greyed); the
##   TEAM INVITE waiting popup says WAITING FOR, then DECLINED;
## - a stand-in TEAM INVITE (Cloud._incoming with a team) shows TEAM INVITE; DECLINE closes it;
## - START in LONE WOLF SOLO clears a team match left over (the 1 vs 1 QUICK MATCH);
## - LONE WOLF x DUO opens the team search (CANCEL stops it); left alone, the match against bots
##   loads with its card "NO PLAYER FOUND: YOUR TEAM VS BOTS", counted as DUO;
## - TRAINING GROUND x SQUAD loads scenes/team_arena.tscn with eight fighters' roster;
## - every touch target on the way is at least 56 px.
## Screenshots when run through tools/qa/capture.sh (script:res://tests/team_lobby_check.gd).
## Prints "TEAM LOBBY CHECK DONE bad=N".

var bad := 0
var at: Node


func run(autotest: Node) -> int:
	at = autotest
	Game.settings.difficulty = 1
	Game.profile.name_set = true         # (no first-start name prompt over the lobby)
	Game.practice = false
	Game.mode = "training"
	Game.team_size = 1
	if not await _until(func() -> bool: return get_tree().current_scene is Lobby, 30.0):
		return _done("the lobby never came up")
	# A team match left over from before is cleared when a lobby opens.
	Game.team_match = TeamArena.offline_match(2, "training", 1)
	var first := get_tree().current_scene
	Game.goto_lobby()
	var lobby := await _new_lobby(first)
	if lobby == null:
		return _done("the lobby did not open again")
	if not Game.team_match.is_empty():
		_fail("a lobby that opens keeps an old team match")
	await at.wait(0.5)
	await _select_mode(lobby)
	await _team_bar(lobby)
	await _invite_list(lobby)
	await _team_invite(lobby)
	await _quick_clears(lobby)
	lobby = await _team_search(lobby)
	if lobby:
		await _training_squad(lobby)
	Game.team_size = 1
	Game.mode = "training"
	return _done("")


## SELECT MODE: Size_1 / 2 / 4 on both cards, 56 px; DUO on TRAINING GROUND's card picks it and the
## mode card says DUO; the DUMMY is greyed in DUO.
func _select_mode(lobby: Lobby) -> void:
	var card := lobby.find_child("ModeCard", true, false) as Control
	await _tap(card)
	await at.wait(0.5)
	var popup := lobby.dialogs.modal
	if popup == null:
		_fail("the mode card does not open SELECT MODE")
		return
	for m: String in ["training", "lonewolf"]:
		var mc := popup.find_child("Mode_" + m, true, false)
		for n in [1, 2, 4]:
			var chip := mc.find_child("Size_%d" % n, true, false) as Button if mc else null
			if chip == null:
				_fail("SELECT MODE's %s card has no Size_%d" % [m, n])
			elif chip.size.y < UI.TOUCH_MIN or chip.size.x < UI.TOUCH_MIN:
				_fail("Size_%d is smaller than 56 px (%s)" % [n, str(chip.size)])
	var solo := popup.find_child("Size_1", true, false) as Button
	if solo == null or not solo.button_pressed or solo.text != "SOLO":
		_fail("SOLO is not the size lit on a new install")
	await at.shot("t01_select_mode_sizes")
	var duo := popup.find_child("Mode_training", true, false).find_child("Size_2", true, false) as Control
	await _tap(duo)
	await at.wait(0.5)
	var fmt := _text(card, "ModeFormat")
	if Game.team_size != 2 or Game.mode != "training" or lobby.dialogs.modal != null or not fmt.begins_with("DUO  ·  BOT: NORMAL"):
		_fail("DUO did not pick TRAINING DUO (size %d, card %s)" % [Game.team_size, fmt])
	await _tap(card)
	await at.wait(0.5)
	popup = lobby.dialogs.modal
	var dummy := popup.find_child("Diff_DUMMY", true, false) as Button if popup else null
	var lines := popup.find_child("Mode_training", true, false) if popup else null
	if dummy == null or not dummy.disabled or _find_label(lines, "DUMMY IS SOLO ONLY") == null:
		_fail("the DUMMY is not SOLO only in DUO")
	if popup and _find_label(popup.find_child("Mode_lonewolf", true, false), "DUO · 2 VS 2 ONLINE · EACH PLAYER + A BOT") == null:
		_fail("LONE WOLF's card does not say what DUO plays online")
	await at.shot("t02_select_mode_duo")
	lobby.dialogs.back()
	await at.wait(0.3)


## The TEAM bar: DUO + INVITE, SQUAD + INVITE and two BOT tiles, none in SOLO.
func _team_bar(lobby: Lobby) -> void:
	var team_bar := lobby.find_child("TeamBar", true, false) as Control
	if team_bar == null or not team_bar.is_visible_in_tree():
		_fail("no TEAM bar in DUO")
		return
	var invite := team_bar.find_child("TeamInvite", true, false) as Control
	if invite == null or team_bar.find_child("TeamBot_3", true, false) != null:
		_fail("DUO's TEAM bar is not one + INVITE tile")
	_touch_ok(team_bar)
	await at.shot("t03_lobby_team_bar_duo")
	await _pick_size(lobby, "lonewolf", 4)
	team_bar = lobby.find_child("TeamBar", true, false) as Control
	if Game.team_size != 4 or Game.mode != "lonewolf" or team_bar == null or not team_bar.is_visible_in_tree() \
			or team_bar.find_child("TeamInvite", true, false) == null or team_bar.find_child("TeamBot_3", true, false) == null \
			or team_bar.find_child("TeamBot_4", true, false) == null:
		_fail("SQUAD's TEAM bar is not + INVITE and two BOT tiles")
	if _text(lobby, "ModeFormat") != "SQUAD  ·  4 VS 4 ONLINE":
		_fail("the mode card in LONE WOLF SQUAD says %s" % _text(lobby, "ModeFormat"))
	_touch_ok(team_bar)
	await at.shot("t04_lobby_team_bar_squad")
	await _pick_size(lobby, "training", 1)
	team_bar = lobby.find_child("TeamBar", true, false) as Control
	if team_bar != null and team_bar.is_visible_in_tree():
		_fail("the TEAM bar shows in SOLO")
	if _text(lobby, "ModeFormat") != "BOT: NORMAL  ·  FIRST TO %d" % Game.rounds_to_win():
		_fail("TRAINING SOLO's mode card changed: %s" % _text(lobby, "ModeFormat"))
	await _pick_size(lobby, "training", 2)


## INVITE: the friends, online ones first with INVITE, offline ones greyed; TEAM INVITE waits.
func _invite_list(lobby: Lobby) -> void:
	var cloud := Game.cloud_service()
	var on_id := "online pal".sha256_text().left(32)
	var off_id := "offline pal".sha256_text().left(32)
	var saved_friends: Dictionary = Game.profile.friends
	Game.profile.friends = {off_id: {"name": "ABEL"}, on_id: {"name": "ZORA"}}
	cloud.peers[on_id] = {"name": "ZORA", "bundle": "neon", "pk": "", "seen": Time.get_ticks_msec() + 600000}
	await _tap(lobby.find_child("TeamInvite", true, false) as Control)
	await at.wait(0.8)
	var popup := lobby.dialogs.modal
	var list := popup.find_child("TeamInviteList", true, false) if popup else null
	var on_row := list.find_child("TeamFriend_" + Cloud.friend_code(on_id), true, false) if list else null
	var off_row := list.find_child("TeamFriend_" + Cloud.friend_code(off_id), true, false) if list else null
	var ask := on_row.find_child("TeamAsk_" + Cloud.friend_code(on_id), true, false) as Button if on_row else null
	var ask_off := off_row.find_child("TeamAsk_" + Cloud.friend_code(off_id), true, false) as Button if off_row else null
	if list == null or on_row == null or off_row == null or ask == null or ask_off == null:
		_fail("+ INVITE does not list the friends (%s)" % str(list.get_children().map(func(c: Node) -> String: return c.name) if list else []))
	else:
		if on_row.get_index() > off_row.get_index():
			_fail("an online friend is not listed first")
		if ask.disabled or not ask_off.disabled or off_row.modulate.a > 0.9:
			_fail("INVITE is not on online friends only, or an offline friend is not greyed")
		_touch_ok(list)
		await at.shot("t05_team_invite_list")
		# No relay here: the invite cannot go out, and the list says so.
		await _tap(ask)
		await at.wait(0.6)
		if lobby.dialogs.modal == null or _find_label(lobby.dialogs.modal, "ZORA COULD NOT BE REACHED") == null:
			_fail("an invite that cannot go out does not say so")
	# The waiting popup (as after an invite that went out: Cloud keeps it), then the answer no.
	cloud.set("_outgoing", {"id": on_id, "name": "ZORA", "bundle": "neon", "room": "00".repeat(16),
		"aes": Crypto.new().generate_random_bytes(32), "mac": Crypto.new().generate_random_bytes(32), "t": Time.get_ticks_msec()})
	lobby.team._wait_name = "ZORA"
	lobby.team.call("_show_wait")
	await at.wait(0.4)
	var wait := lobby.dialogs.modal.find_child("TeamWait", true, false) as Label if lobby.dialogs.modal else null
	if wait == null or wait.text != "WAITING FOR ZORA" or lobby.dialogs.modal.find_child("TeamWaitCancel", true, false) == null:
		_fail("TEAM INVITE does not wait for the friend")
	lobby.team.refresh()
	await at.wait(0.2)
	var tile := lobby.find_child("TeamInvite", true, false)
	if tile == null or _find_label(tile, "ZORA") == null:
		_fail("the TEAM bar does not say who the invite waits for")
	await at.shot("t06_team_invite_waiting")
	cloud.set("_outgoing", {})
	lobby.team.on_answered(false, "ZORA")
	await at.wait(0.3)
	if wait == null or not is_instance_valid(wait) or wait.text != "ZORA DECLINED":
		_fail("a declined TEAM INVITE does not say DECLINED")
	await _tap(lobby.dialogs.modal.find_child("TeamWaitCancel", true, false) as Control if lobby.dialogs.modal else null)
	await at.wait(0.3)
	if lobby.dialogs.modal != null or _find_label(lobby.find_child("TeamInvite", true, false), "+ INVITE") == null:
		_fail("OK does not close the TEAM INVITE, or the tile still waits")
	cloud.peers.erase(on_id)
	Game.profile.friends = saved_friends


## A stand-in TEAM INVITE (what Cloud keeps for a "tinv"): the popup TEAM INVITE; DECLINE closes it.
func _team_invite(lobby: Lobby) -> void:
	var cloud := Game.cloud_service()
	var from := "inviter".sha256_text().left(32)
	cloud.set("_incoming", {"id": from, "name": "VIPER", "bundle": "neon", "room": "00".repeat(16),
		"aes": Crypto.new().generate_random_bytes(32), "mac": Crypto.new().generate_random_bytes(32),
		"t": Time.get_ticks_msec(), "team": {"size": 2, "coop": true}})
	lobby.friends.call("_on_net_invited", "VIPER")
	await at.wait(0.5)
	var popup := lobby.dialogs.modal
	var text := popup.find_child("ChallengeText", true, false) as Label if popup else null
	if text == null or text.text != "VIPER wants you in their DUO team: YOU TWO VS BOTS" or _find_label(popup, "TEAM INVITE") == null:
		_fail("a TEAM INVITE does not show as one (%s)" % (text.text if text else "no popup"))
	if popup:
		_touch_ok(popup)
	await at.shot("t07_team_invite_popup")
	await _tap(popup.find_child("DeclineButton", true, false) as Control if popup else null)
	await at.wait(0.4)
	if lobby.dialogs.modal != null or cloud.has_invite():
		_fail("DECLINE does not close the TEAM INVITE")


## START in LONE WOLF SOLO (the 1 vs 1 QUICK MATCH) clears a team match left over.
func _quick_clears(lobby: Lobby) -> void:
	await _pick_size(lobby, "lonewolf", 1)
	Game.team_match = TeamArena.offline_match(2, "training", 1)
	await _tap(lobby.start_btn)
	await at.wait(0.6)
	var nm := lobby.get_node_or_null("NetMatch") as NetMatch
	if nm == null or not nm.searching or not Game.team_match.is_empty():
		_fail("START in LONE WOLF SOLO did not start the 1 vs 1 search with no team match")
	if nm:
		nm.cancel()
	await at.wait(0.3)


## LONE WOLF x DUO: the team search (CANCEL stops it); left alone, the match against bots.
func _team_search(lobby: Lobby) -> Lobby:
	await _pick_size(lobby, "lonewolf", 2)
	await _tap(lobby.start_btn)
	await at.wait(1.2)
	var popup := lobby.dialogs.modal
	var tm := lobby.get_node_or_null("TeamMatch") as TeamMatch
	if popup == null or tm == null or not tm.searching or popup.find_child("TeamCancel", true, false) == null \
			or popup.find_child("TeamStatus", true, false) == null or popup.find_child("TeamTimer", true, false) == null:
		_fail("START in LONE WOLF DUO does not open the team search")
		return lobby
	var fill := popup.find_child("TeamFill", true, false) as Label
	if fill == null or not fill.text.begins_with("BOTS IN 0:0"):
		_fail("the search does not count down to the bots (%s)" % (fill.text if fill else "none"))
	_touch_ok(popup)
	await at.shot("t08_team_search")
	await _tap(popup.find_child("TeamCancel", true, false) as Control)
	await at.wait(0.4)
	if tm.searching or lobby.dialogs.modal != null:
		_fail("CANCEL does not stop the team search")
	# Again, left alone this time: after LW_FILL_S the team plays bots here, said on its card.
	Loading.delay_for_test = 1.5
	await _tap(lobby.start_btn)
	var shown := [false, ""]
	var t := 0.0
	while t < 20.0 and not get_tree().current_scene is TeamArena:
		await at.wait(0.1)
		t += 0.1
		var desc := get_tree().root.find_child("MatchDesc", true, false) as Label
		if desc and not shown[0]:
			shown[0] = true
			shown[1] = desc.text
			await at.shot("t09_team_fill_card")
	Loading.delay_for_test = 0.0
	if not shown[0] or String(shown[1]) != "NO PLAYER FOUND: YOUR TEAM VS BOTS":
		_fail("the match against bots does not say NO PLAYER FOUND (%s)" % str(shown))
	if not get_tree().current_scene is TeamArena or String(get_tree().current_scene.scene_file_path) != "res://scenes/team_arena.tscn" \
			or String(Game.team_match.get("mode_id", "")) != "duo" or Game.online:
		_fail("nobody found does not load the DUO match against bots (%s)" % str(get_tree().current_scene))
	await at.wait(1.0)
	Game.goto_lobby()
	return await _new_lobby(null)


## TRAINING GROUND x SQUAD loads the team arena on this phone.
func _training_squad(lobby: Lobby) -> void:
	await _pick_size(lobby, "training", 4)
	await _tap(lobby.start_btn)
	if not await _until(func() -> bool: return get_tree().current_scene is TeamArena, 20.0):
		_fail("TRAINING SQUAD did not load the team arena")
		return
	var tm := Game.team_match
	if String(get_tree().current_scene.scene_file_path) != "res://scenes/team_arena.tscn" or int(tm.get("size", 0)) != 4 \
			or (tm.get("roster", []) as Array).size() != 8 or String(tm.get("mode_id", "")) != "training" or Game.online:
		_fail("TRAINING SQUAD is not the 4 vs 4 team match on this phone (%s)" % str(tm.get("size")))
	await at.wait(1.0)
	Game.goto_lobby()
	await _new_lobby(null)


# ---------------------------------------------------------------- helpers

## Picks a mode and size the way a player does: the mode card, then the size chip on that mode's card.
func _pick_size(lobby: Lobby, m: String, n: int) -> void:
	await _tap(lobby.find_child("ModeCard", true, false) as Control)
	await at.wait(0.5)
	var popup := lobby.dialogs.modal
	var mc := popup.find_child("Mode_" + m, true, false) if popup else null
	await _tap(mc.find_child("Size_%d" % n, true, false) as Control if mc else null)
	await at.wait(0.4)
	if Game.mode != m or Game.team_size != n:
		_fail("could not pick %s at size %d" % [m, n])


func _new_lobby(old: Node) -> Lobby:
	var old_id := old.get_instance_id() if old else 0
	var ok := await _until(func() -> bool:
		var s := get_tree().current_scene
		return s is Lobby and s.get_instance_id() != old_id and s.is_node_ready(), 30.0)
	await at.wait(0.6)
	return get_tree().current_scene as Lobby if ok else null


## Every visible button under `root` is a 56 px touch target.
func _touch_ok(root: Node) -> void:
	for b in root.find_children("*", "BaseButton", true, false):
		var c := b as Control
		if c.is_visible_in_tree() and (c.size.y < UI.TOUCH_MIN - 0.5 or c.size.x < UI.TOUCH_MIN - 0.5):
			_fail("%s is smaller than 56 px (%s)" % [c.name, str(c.size)])


## A real tap in the middle of a control (window pixels, as the engine gets a touch).
func _tap(c: Control) -> void:
	if c == null or not is_instance_valid(c):
		_fail("tap target exists")
		return
	var w: Vector2 = get_tree().root.get_final_transform() * c.get_global_rect().get_center()
	at.touch(0, w, true)
	await at.wait(0.08)
	at.touch(0, w, false)
	await at.wait(0.12)


func _text(root: Node, node_name: String) -> String:
	var l := root.find_child(node_name, true, false) as Label if root else null
	return l.text if l else ""


func _find_label(root: Node, text: String) -> Label:
	if root == null:
		return null
	for l in root.find_children("*", "Label", true, false):
		if (l as Label).text == text:
			return l as Label
	return null


func _until(cond: Callable, seconds: float) -> bool:
	var t := 0.0
	while not cond.call() and t < seconds:
		await at.wait(0.25)
		t += 0.25
	return cond.call()


func _fail(what: String) -> void:
	bad += 1
	at.log_line("FAIL " + what)


func _done(error: String) -> int:
	if error != "":
		_fail(error)
	at.log_line("TEAM LOBBY CHECK DONE bad=%d" % bad)
	return bad

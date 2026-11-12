extends Node
## DUO / SQUAD in the lobby (WP-B1), one copy of the game, run by tools/qa/run_checks.sh with
## LW_FILL_S=3 and a relay that is never there (LW_MQTT_URL=ws://127.0.0.1:9: nothing leaves the
## machine). Real taps where a player taps:
## - a team match left over is cleared when the lobby opens;
## - SELECT MODE has the size chips Size_1 / 2 / 4 on both mode cards; DUO updates the mode card;
##   the DUMMY is SOLO only; LONE WOLF's card says DUO plays real players;
## - the mode card's line in LONE WOLF SQUAD and TRAINING SOLO (the GROUP bar that replaced the
##   TEAM bar in 1.5 has its own check: tests/group_lobby_check.gd);
## - a stand-in TEAM INVITE (Cloud._incoming with a team) shows TEAM INVITE; DECLINE closes it;
## - START in LONE WOLF SOLO clears a team match left over (the 1 vs 1 QUICK MATCH);
## - LONE WOLF x DUO searches real players only (Cloud's search: the search tab PLAYERS 1/4, no bots, no
##   match against bots ever); CANCEL stops it;
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
	await _mode_lines(lobby)
	await _team_invite(lobby)
	await _quick_clears(lobby)
	await _team_search(lobby)
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
	if popup and _find_label(popup.find_child("Mode_lonewolf", true, false), "DUO · 2 VS 2 · REAL PLAYERS") == null:
		_fail("LONE WOLF's card does not say what DUO plays online")
	await at.shot("t02_select_mode_duo")
	lobby.dialogs.back()
	await at.wait(0.3)


## The mode card's line: LONE WOLF SQUAD online, TRAINING SOLO unchanged.
func _mode_lines(lobby: Lobby) -> void:
	await _pick_size(lobby, "lonewolf", 4)
	if _text(lobby, "ModeFormat") != "SQUAD  ·  4 VS 4 ONLINE":
		_fail("the mode card in LONE WOLF SQUAD says %s" % _text(lobby, "ModeFormat"))
	var group_bar := lobby.find_child("GroupBar", true, false) as Control
	if group_bar == null or not group_bar.is_visible_in_tree() or lobby.find_child("TeamBar", true, false) != null:
		_fail("LONE WOLF does not show the GROUP bar (the TEAM bar is gone)")
	await at.shot("t04_lobby_squad")
	await _pick_size(lobby, "training", 1)
	if _text(lobby, "ModeFormat") != "BOT: NORMAL  ·  FIRST TO %d" % Game.rounds_to_win():
		_fail("TRAINING SOLO's mode card changed: %s" % _text(lobby, "ModeFormat"))
	await _pick_size(lobby, "training", 2)


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


## LONE WOLF x DUO: the search for real players (Cloud.group_start: a solo is a unit of one),
## the search tab (no popup) with PLAYERS 1/4 and no word of bots, START a greyed MATCHING... plate,
## the mode card saying CANCEL THE SEARCH FIRST; the tab's X stops it. Never a match against bots.
func _team_search(lobby: Lobby) -> void:
	await _pick_size(lobby, "lonewolf", 2)
	var cloud := Game.cloud_service()
	await _tap(lobby.start_btn)
	await at.wait(1.2)
	var tab := lobby.search_tab
	if lobby.dialogs.modal != null or not tab.is_visible_in_tree() or tab.find_child("SearchCancel", true, false) == null \
			or _text(tab, "SearchPlayers") != "PLAYERS 1/4" or cloud.search_needed != 4:
		_fail("START in LONE WOLF DUO does not show the search tab for real players (%s)" % _text(tab, "SearchPlayers"))
		return
	var plate := lobby.find_child("MatchingPlate", true, false) as Control
	if plate == null or not plate.is_visible_in_tree() or lobby.start_btn.is_visible_in_tree():
		_fail("START does not turn into the MATCHING... plate while searching")
	for l in tab.find_children("*", "Label", true, false):
		if (l as Label).text.contains("BOT"):
			_fail("the search mentions bots: %s" % (l as Label).text)
	if _text(tab, "SearchLine") != ("ESTIMATED 0:10" if cloud.status == "online" else "CONNECTING..."):     # (no relay here)
		_fail("the search tab's first line is not the estimate (%s)" % _text(tab, "SearchLine"))
	_touch_ok(tab)
	await at.shot("t08_team_search")
	# The lobby stays usable: the mode card answers CANCEL THE SEARCH FIRST, WARDROBE opens.
	await _tap(lobby.mode_card)
	await at.wait(0.3)
	if _text(lobby.dialogs.modal, "NoticeText") != "CANCEL THE SEARCH FIRST":
		_fail("a tap on the mode card during a search does not say CANCEL THE SEARCH FIRST")
	lobby.dialogs.close_modal()
	await at.wait(3.5)                   # (longer than the old LW_FILL_S: no match against bots comes)
	if get_tree().current_scene != lobby or not Game.team_match.is_empty():
		_fail("the search loaded a match on its own")
	await _tap(tab.find_child("SearchCancel", true, false) as Control)
	await at.wait(0.4)
	if cloud.search_needed != 0 or tab.is_visible_in_tree() or not lobby.start_btn.is_visible_in_tree():
		_fail("the search tab's X does not stop the search")


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

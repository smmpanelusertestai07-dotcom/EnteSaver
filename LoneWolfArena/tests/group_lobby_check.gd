extends Node
## GROUPS in the lobby (design/GROUPS.txt 1, UI), one copy of the game, run by tools/qa/run_checks.sh
## (step group_lobby) with a relay that is never there (LW_MQTT_URL=ws://127.0.0.1:9: nothing
## leaves the machine). Cloud's own group API, with no relay: the check puts a group in Cloud (its
## `group` and keys, as a roster or an invite brings them) and emits group_changed as Cloud does.
## Real taps where a player taps:
## - a solo in LONE WOLF: no TEAM bar, no "+" plate by the hero; the mode card's TEAM panel (code,
##   COPY, the JOIN BY CODE and FILL EMPTY PLACES ticks, SOLO / DUO / SQUAD tiles that pick the
##   size); the social panel's "+" only on an online friend; an invite that cannot go out (no relay)
##   says so; its GROUP CODE keypad (JOIN BY CODE); a friend in a match (the announce's "im") reads
##   IN A MATCH there and in FRIENDS, "+" and DUEL 1 VS 1 greyed;
## - the leader of 4: the hero steps left, three member models to its right with name plates; the
##   TEAM bar under the player card opens the TEAM panel: REMOVE on each other member (asked first)
##   drops them, DISBAND GROUP, + INVITE greyed (full), TEAMS, the 10-digit code with COPY unclipped,
##   all on the screen;
## - START (leader, DUO): a group of 3 is told why it cannot start offline; a group of 2 searches:
##   the search tab with PLAYERS n/N and its X (no popup); TEAMS: the slot panel moves a member (Cloud.set_group_team);
## - a member: the TEAM panel's GROUP CODE with COPY only while the leader's JOIN BY CODE is on (else THE LEADER
##   SHARES THE GROUP CODE); WAITING FOR <LEADER> TO START in START's place, the LEADER mark on the leader's model,
##   the mode card follows the leader's mode and its TEAM panel is read-only, EXIT GROUP (asked
##   first) leaves and the models go;
## - GROUP INVITE: "<NAME> invites you to their group", waiting behind a question, ACCEPT;
## - the DUEL in a group of two: the leader's START shows MATCHING... until the member's phone
##   takes it; one never taken gives START back with a notice;
## - CUSTOM ROOM with slots: CREATE with SQUAD shows 8 places with the HOST tag; in a DUO room a
##   player who joined sits on ORANGE with the host's KICK, START goes once both teams have a
##   player, a tap on an empty place moves the host there, KICK removes the player (START waits
##   again); a player kicked out of a room is told so;
## - every touch target on the way is at least 56 px.
## Prints "GROUP LOBBY CHECK DONE bad=N".

var bad := 0
var at: Node
var cloud: Cloud
var ids := {}


func run(autotest: Node) -> int:
	at = autotest
	Game.profile.name_set = true         # (no first-start name prompt over the lobby)
	Game.practice = false
	Game.mode = "lonewolf"
	Game.team_size = 2
	if not await _until(func() -> bool: return get_tree().current_scene is Lobby, 30.0):
		return _done("the lobby never came up")
	cloud = Game.cloud_service()
	for n: String in ["ZORA", "ABEL", "KITE", "OFFLINE PAL", "VIPER"]:
		ids[n] = (n + " id").sha256_text().left(32)
	var first := get_tree().current_scene
	Game.goto_lobby()                    # a lobby built in LONE WOLF DUO
	var lobby := await _new_lobby(first)
	if lobby == null:
		return _done("the lobby did not open again")
	var saved_friends: Dictionary = Game.profile.friends
	await _solo(lobby)
	await _leader(lobby)
	await _start_and_search(lobby)
	await _teams(lobby)
	await _member(lobby)
	await _group_invite(lobby)
	await _duel_plate(lobby)
	await _room(lobby)
	cloud.leave_group()
	Game.profile.friends = saved_friends
	Game.team_size = 1
	Game.mode = "training"
	return _done("")


## A solo in LONE WOLF (moved on purpose in round 7: the left GROUP column is gone): no TEAM bar
## and no "+" plate by the hero; the social panel's "+" invites (on the online friend only), an
## invite that cannot go out says so; a friend in a match reads IN A MATCH with "+" greyed; the
## social panel's GROUP CODE keypad joins by code; the mode card's TEAM panel has the code with
## COPY, the JOIN BY CODE and FILL EMPTY PLACES ticks and the SOLO / DUO / SQUAD tiles.
func _solo(lobby: Lobby) -> void:
	var team_bar := lobby.find_child("TeamBar", true, false) as Control
	if team_bar == null or team_bar.is_visible_in_tree():
		_fail("a solo sees the TEAM bar (only a group has one)")
	if lobby.find_child("GroupBar", true, false) != null or lobby.find_child("PodiumInvite", true, false) != null:
		_fail("the old GROUP column or the podium's + plate is still in the lobby")
	await _team_box_solo(lobby)
	Game.profile.friends = {ids.ZORA: {"name": "ZORA"}, ids["OFFLINE PAL"]: {"name": "ABBY"}}
	cloud.peers[ids.ZORA] = {"name": "ZORA", "bundle": "neon", "pk": "", "seen": Time.get_ticks_msec() + 600000}
	var arrow := lobby.find_child("SocialArrow", true, false) as Control
	await _tap(arrow)
	await at.wait(0.6)
	var popup := lobby.dialogs.modal
	var ask := popup.find_child("SocialInvite_" + Cloud.friend_code(ids.ZORA), true, false) as Button if popup else null
	var ask_off := popup.find_child("SocialInvite_" + Cloud.friend_code(ids["OFFLINE PAL"]), true, false) as Button if popup else null
	if ask == null or ask_off == null or ask.disabled or not ask_off.disabled:
		_fail("the social panel does not list the friends with \"+\" on the online one only")
		return
	_touch_ok(popup.find_child("SocialPanel", true, false))
	await at.shot("g01_group_invite_list")
	await _tap(ask)
	await at.wait(0.6)
	if not _find_text(lobby.get_node_or_null(^"NoticeLayer"), "ZORA COULD NOT BE REACHED") or not cloud.group.is_empty():
		_fail("an invite that cannot go out (no relay here) does not say so")
	lobby.dialogs.close_modal()
	cloud.peers.erase(ids.ZORA)
	# JOIN BY CODE: the social panel's keypad (the old GROUP column's JOIN BY CODE).
	await _tap(arrow)
	await at.wait(0.5)
	await _tap(lobby.dialogs.modal.find_child("SocialGroupCode", true, false) as Control if lobby.dialogs.modal else null)
	await at.wait(0.4)
	if lobby.dialogs.modal == null or lobby.dialogs.modal.find_child("CodeKeyGo", true, false) == null:
		_fail("JOIN BY CODE is not reachable from the social panel's GROUP CODE keypad")
	lobby.dialogs.close_modal()
	# A friend whose lobby announce says it plays a match: IN A MATCH, "+" and DUEL 1 VS 1 greyed.
	var friends_was: Dictionary = Game.profile.friends.duplicate(true)
	Game.profile.friends[ids.KITE] = {"name": "KITE"}
	cloud.peers[ids.KITE] = {"name": "KITE", "bundle": "default", "pk": "", "seen": Time.get_ticks_msec() + 600000, "im": true}
	await _tap(arrow)
	await at.wait(0.6)
	var row := lobby.dialogs.modal.find_child("SocialRow_" + Cloud.friend_code(ids.KITE), true, false) if lobby.dialogs.modal else null
	var ask_busy := lobby.dialogs.modal.find_child("SocialInvite_" + Cloud.friend_code(ids.KITE), true, false) as Button if lobby.dialogs.modal else null
	if ask_busy == null or not ask_busy.disabled or not _find_text(row, "IN A MATCH"):
		_fail("a friend in a match is not IN A MATCH with \"+\" greyed in the social panel")
	lobby.dialogs.close_modal()
	lobby.friends.open("friends")
	await at.wait(0.8)
	var duel := lobby.dialogs.modal.find_child("Duel_" + Cloud.friend_code(ids.KITE), true, false) as Button if lobby.dialogs.modal else null
	if duel == null or not duel.disabled or not _shows(lobby.dialogs.modal, "IN A MATCH"):
		_fail("a friend in a match is not IN A MATCH with DUEL 1 VS 1 greyed in FRIENDS")
	await at.shot("g01b_friend_in_match")
	cloud.peers[ids.KITE].erase("im")                     # back in the lobby (or an older build: no flag)
	cloud.peers_changed.emit()
	await at.wait(0.8)
	duel = lobby.dialogs.modal.find_child("Duel_" + Cloud.friend_code(ids.KITE), true, false) as Button if lobby.dialogs.modal else null
	if duel == null or duel.disabled or _shows(lobby.dialogs.modal, "IN A MATCH"):
		_fail("a friend back in the lobby does not read ONLINE with DUEL 1 VS 1 on again")
	lobby.dialogs.close_modal()
	cloud.peers.erase(ids.KITE)
	Game.profile.friends = friends_was


## The mode card's TEAM panel for a solo leader: the 10-digit code with COPY, the JOIN BY CODE tick
## (Cloud.code_join), the FILL EMPTY PLACES tick (setting team_fill) and a tile per size that picks
## it; everything inside the panel, nothing overlapping, every target 56 px.
func _team_box_solo(lobby: Lobby) -> void:
	if not await _until(func() -> bool: return cloud.group_code() != "", 20.0):     # (made once the key is ready)
		_fail("a solo has no GROUP CODE")
	var fig := lobby.mode_card.find_child("SizeBoxButton", true, false) as Control
	await _tap(fig)
	await at.wait(0.4)
	var box := lobby.dialogs.size_box
	var panel := box.find_child("SizeBoxPanel", true, false) as Control if box else null
	if panel == null:
		_fail("the mode card's figure does not open the TEAM panel")
		return
	var parts := ["GroupCodeRow", "GroupCode", "GroupCodeCopy", "GroupCodeSwitch", "TeamFillTick", "SizeTile_1", "SizeTile_2", "SizeTile_4"]
	for part: String in parts:
		var c := panel.find_child(part, true, false) as Control
		if c == null or not c.is_visible_in_tree() or not panel.get_global_rect().grow(0.5).encloses(c.get_global_rect()):
			_fail("the TEAM panel's %s is missing or clipped" % part)
	if _text(panel, "GroupCode").replace(" ", "").length() != Cloud.CODE_LEN:
		_fail("the TEAM panel's code is not %d digits (%s)" % [Cloud.CODE_LEN, _text(panel, "GroupCode")])
	_no_overlap([panel.find_child("GroupCodeRow", true, false), panel.find_child("GroupCodeSwitch", true, false),
		panel.find_child("TeamFillTick", true, false), panel.find_child("SizeTile_1", true, false)])
	_no_overlap([panel, lobby.mode_card, lobby.start_btn])
	_touch_ok(panel)
	await at.shot("g00_team_panel_solo")
	# JOIN BY CODE: the tick turns the switch on and off.
	var was := cloud.code_join
	await _tap(panel.find_child("GroupCodeSwitch", true, false) as Control)
	await at.wait(0.3)
	if cloud.code_join == was or lobby.dialogs.size_box == null:
		_fail("the TEAM panel's JOIN BY CODE tick does not switch Cloud.code_join (or closed the panel)")
	cloud.set_code_join(was)
	await at.wait(0.3)
	# FILL EMPTY PLACES: on by default, the tick flips the setting.
	var fill_was := bool(Game.settings.get("team_fill", true))
	box = lobby.dialogs.size_box
	await _tap(box.find_child("TeamFillTick", true, false) as Control if box else null)
	await at.wait(0.3)
	if bool(Game.settings.get("team_fill", true)) == fill_was:
		_fail("the FILL EMPTY PLACES tick does not change the setting")
	Game.settings.team_fill = fill_was
	await at.wait(0.3)
	# A tile picks its size (as SELECT MODE's chip does) and closes the panel.
	box = lobby.dialogs.size_box
	await _tap(box.find_child("SizeTile_4", true, false) as Control if box else null)
	await at.wait(0.4)
	if Game.team_size != 4 or lobby.dialogs.size_box != null:
		_fail("the TEAM panel's SQUAD tile does not pick SQUAD (team size %d)" % Game.team_size)
	await _tap(fig)
	await at.wait(0.4)
	box = lobby.dialogs.size_box
	await _tap(box.find_child("SizeTile_2", true, false) as Control if box else null)
	await at.wait(0.4)
	if Game.team_size != 2:
		_fail("the TEAM panel's DUO tile does not pick DUO")


## Taps the TEAM bar and gives the TEAM panel (null when it did not open).
func _open_team_panel(lobby: Lobby) -> Control:
	var team_bar := lobby.find_child("TeamBar", true, false) as Control
	if team_bar == null or not team_bar.is_visible_in_tree():
		_fail("no TEAM bar while in a group")
		return null
	await _tap(team_bar)
	await at.wait(0.4)
	var panel := lobby.dialogs.modal.find_child("TeamPanel", true, false) as Control if lobby.dialogs.modal else null
	if panel == null:
		_fail("the TEAM bar does not open the TEAM panel")
	return panel


## The leader of 4: three models besides the hero with name plates; REMOVE, DISBAND, INVITE greyed.
func _leader(lobby: Lobby) -> void:
	_set_group(cloud.my_id, "lonewolf", 2)
	await at.wait(0.6)
	var models := _models(lobby)
	if models.size() != 3:
		_fail("the podium has %d member models, not 3" % models.size())
	var names: Array = []
	for cm: CharacterModel in models:
		var plate := cm.get_node_or_null(^"NamePlate") as Label3D
		names.append(plate.text if plate else "")
		var mark := cm.get_node_or_null(^"LeaderMark") as Label3D
		if mark == null or mark.visible:
			_fail("a member's model shows a LEADER mark while this player leads")
		if not cm.is_visible_in_tree() or cm.bundle == "":
			_fail("a member's model is hidden or has no outfit")
	names.sort()
	if names != ["ABEL", "KITE", "ZORA"]:
		_fail("the name plates are %s" % str(names))
	var heroes := lobby.find_children("*", "CharacterModel", true, false).filter(func(n: Node) -> bool: return not n.is_queued_for_deletion())
	if heroes.size() != 4:
		_fail("the lobby has %d character models, not the hero + 3" % heroes.size())
	# The hero steps left, the members stand to its right (no + plate anywhere).
	if not is_equal_approx(lobby.hero_x(), Lobby.HERO_X_GROUP):
		_fail("the hero does not step left with members beside it")
	await at.wait(0.6)
	var hero_px := lobby.camera.unproject_position(lobby.model.global_position).x
	for cm: CharacterModel in models:
		if lobby.camera.unproject_position(cm.global_position).x <= hero_px:
			_fail("a member's model does not stand right of the hero")
	# The voice's mic / speaker pill (112 x 44, centred under the hero's feet, kept over the bottom
	# bar) stays clear of the chat strip with the hero further left, also with a left camera cutout
	# (the strip moves right, the 3D hero does not).
	var win := get_tree().root
	var win_was := win.size
	win.size = Vector2i(1280, 720)          # (a 16:9 phone: the headless window is square)
	for cut: float in [0.0, 90.0]:
		UI.margins_for_test = Vector2(cut, 0.0)
		await at.wait(1.2)
		var vs := lobby.get_viewport().get_visible_rect().size
		var feet := lobby.camera.unproject_position(lobby.model.global_position + Vector3(0, 0.12, 0))
		var pill := Rect2(feet - Vector2(56, 22), Vector2(112, 44))
		pill.position.y = clampf(pill.position.y, 80.0, vs.y - 92.0 - 44.0)
		var strip := lobby.find_child("ChatStrip", true, false) as Control
		if strip == null or not strip.is_visible_in_tree() or strip.get_global_rect().intersects(pill):
			_fail("the chat strip %s runs into the voice pill's place %s under the hero (cutout %d)" % [str(strip.get_global_rect() if strip else Rect2()), str(pill), int(cut)])
	UI.margins_for_test = Vector2(-1, -1)
	win.size = win_was
	await at.wait(0.3)
	var team_bar := lobby.find_child("TeamBar", true, false) as Control
	var card := lobby.find_child("PlayerCard", true, false) as Control
	if team_bar == null or not team_bar.is_visible_in_tree() or card == null or team_bar.get_global_rect().position.y < card.get_global_rect().end.y - 1.0:
		_fail("the TEAM bar is not under the player card")
	await at.shot("g02a_team_bar")
	var bar := await _open_team_panel(lobby)
	if bar == null:
		return
	for n in [1, 2, 3, 4]:
		if bar.find_child("GroupMember_%d" % n, true, false) == null or bar.find_child("SpeakMark_%d" % n, true, false) == null:
			_fail("no GroupMember_%d (with its speaking mark's place)" % n)
	if bar.find_child("GroupRemove_1", true, false) != null or bar.find_child("GroupRemove_2", true, false) == null \
			or bar.find_child("GroupRemove_4", true, false) == null:
		_fail("REMOVE is not on every other member only")
	if bar.find_child("GroupDisband", true, false) == null or bar.find_child("GroupExit", true, false) != null:
		_fail("the leader does not see DISBAND GROUP (alone)")
	if bar.find_child("GroupMember_1", true, false).find_child("LeaderTag", true, false) == null:
		_fail("the leader's row has no leader flag")
	# (moved on purpose: a full group's + INVITE stays, greyed, instead of no row)
	var inv := bar.find_child("GroupInvite", true, false) as Button
	if inv == null or not inv.disabled:
		_fail("a full group's + INVITE is not greyed")
	if bar.find_child("GroupTeams", true, false) == null:
		_fail("the TEAM panel has no TEAMS")
	var view := lobby.get_viewport().get_visible_rect()
	for c: Node in bar.find_children("Group*", "Control", true, false):
		if (c as Control).is_visible_in_tree() and not view.encloses((c as Control).get_global_rect().grow(-0.5)):
			_fail("%s runs off the screen in the TEAM panel of 4" % c.name)
	var code_row := bar.find_child("GroupCodeRow", true, false) as Control
	if code_row == null or _text(code_row, "GroupCode").length() != 12:
		_fail("the leader's TEAM panel has no 10-digit code (%s)" % (_text(code_row, "GroupCode") if code_row else "none"))
	else:
		for part: String in ["GroupCode", "GroupCodeCopy"]:
			var c := code_row.find_child(part, true, false) as Control
			if c == null or not c.is_visible_in_tree() or not code_row.get_global_rect().grow(0.5).encloses(c.get_global_rect()):
				_fail("%s is missing or clipped out of the code row" % part)
		_no_overlap([code_row.find_child("GroupCode", true, false), code_row.find_child("GroupCodeCopy", true, false)])
	_touch_ok(bar)
	await at.shot("g02_leader_of_four")
	await _tap(bar.find_child("GroupRemove_3", true, false) as Control)
	await at.wait(0.4)
	await _tap(lobby.dialogs.modal.find_child("ConfirmOk", true, false) as Control if lobby.dialogs.modal else null)
	await at.wait(0.3)
	if cloud.group_members().size() != 3 or _models(lobby).size() != 2:
		_fail("REMOVE did not drop the member (%d left)" % cloud.group_members().size())


## START (the leader, DUO): a group of 3 (2 VS 1) is told it needs the internet; a group of 2 (one
## team) searches: the search tab with PLAYERS n/N, its X.
func _start_and_search(lobby: Lobby) -> void:
	if not lobby.start_btn.is_visible_in_tree():
		_fail("the leader has no START")
	await _tap(lobby.start_btn)
	await at.wait(0.4)
	if _text(lobby.dialogs.modal, "NoticeText") != "OFFLINE: THE MATCH NEEDS THE INTERNET":
		_fail("group_start's answer is not shown (%s)" % _text(lobby.dialogs.modal, "NoticeText"))
	lobby.dialogs.close_modal()
	await at.wait(0.2)
	var other := String(cloud.group_members()[2].id)
	cloud.kick_from_group(other)
	await at.wait(0.3)
	await _tap(lobby.start_btn)
	await at.wait(0.5)
	var tab := lobby.search_tab
	if lobby.dialogs.modal != null or not tab.is_visible_in_tree() or _text(tab, "SearchPlayers") != "PLAYERS 2/4" \
			or cloud.search_needed != 4:
		_fail("no search tab with PLAYERS 2/4 (and no popup) (%s)" % _text(tab, "SearchPlayers"))
	if _find_text(tab, "BOT") or _text(tab, "SearchTimer") == "":
		_fail("the search tab mentions bots or has no timer")
	cloud.search_found = 3
	await at.wait(0.3)
	if _text(tab, "SearchPlayers") != "PLAYERS 3/4":
		_fail("the search count does not follow Cloud.search_found")
	_touch_ok(tab)
	await at.shot("g03_searching_players")
	await _tap(tab.find_child("SearchCancel", true, false) as Control)
	await at.wait(0.3)
	if cloud.search_needed != 0 or tab.is_visible_in_tree():
		_fail("the search tab's X does not stop the search")


## TEAMS: the leader's slot panel; tap a member, then a place: Cloud.set_group_team.
func _teams(lobby: Lobby) -> void:
	var bar := await _open_team_panel(lobby)
	await _tap(bar.find_child("GroupTeams", true, false) as Control if bar else null)
	await at.wait(0.4)
	var panel := lobby.dialogs.modal.find_child("SlotPanel", true, false) if lobby.dialogs.modal else null
	if panel == null or panel.find_child("Slot_0_0", true, false) == null or panel.find_child("Slot_1_1", true, false) == null \
			or panel.find_child("HostTag", true, false) == null:
		_fail("TEAMS has no BLUE / ORANGE slot panel with the leader's tag")
		return
	_touch_ok(panel)
	await at.shot("g04_group_teams")
	var who := String(cloud.group_members()[1].id)
	await _tap(panel.find_child("Slot_0_1", true, false) as Control)
	await at.wait(0.2)
	panel = lobby.dialogs.modal.find_child("SlotPanel", true, false)
	await _tap(panel.find_child("Slot_1_1", true, false) as Control if panel else null)
	await at.wait(0.3)
	var moved: Dictionary = cloud.group_members()[1]
	if String(moved.id) != who or int(moved.team) != 1 or int(moved.slot) != 3:
		_fail("moving a member did not reach Cloud.set_group_team (%s)" % str(moved))
	lobby.dialogs.close_modal()
	await at.wait(0.2)


## A member: WAITING FOR <LEADER>, the leader's LEADER mark, the leader's mode, EXIT GROUP.
func _member(lobby: Lobby) -> void:
	_set_group(ids.ZORA, "lonewolf", 4)
	await at.wait(0.6)
	if Game.team_size != 4 or Game.mode != "lonewolf":
		_fail("the member's mode does not follow the leader's (%s %d)" % [Game.mode, Game.team_size])
	var wait := lobby.find_child("GroupWaitLeader", true, false) as Control
	if wait == null or not wait.is_visible_in_tree() or lobby.start_btn.is_visible_in_tree() \
			or _find_label(wait, "WAITING FOR ZORA TO START") == null:
		_fail("a member does not see WAITING FOR ZORA TO START in START's place")
	var marks := 0
	for cm: CharacterModel in _models(lobby):
		var mark := cm.get_node_or_null(^"LeaderMark") as Label3D
		var name_plate := cm.get_node_or_null(^"NamePlate") as Label3D
		if mark and mark.visible:
			marks += 1
			if name_plate == null or name_plate.text != "ZORA":
				_fail("the LEADER mark is not on ZORA's model")
	if marks != 1:
		_fail("%d models show the LEADER mark, not 1" % marks)
	var bar := await _open_team_panel(lobby)
	if bar == null:
		return
	if bar.find_child("GroupExit", true, false) == null or bar.find_child("GroupDisband", true, false) != null \
			or bar.find_child("GroupRemove_2", true, false) != null or not (bar.find_child("GroupInvite", true, false) as Button).disabled:
		_fail("a member does not see EXIT GROUP alone (+ INVITE greyed)")
	# The leader's JOIN BY CODE off: no code, no COPY, the line that the leader shares it; on: the
	# code with COPY (no switch: it is the leader's).
	cloud.group.code = "4213579086"
	cloud.group.code_join = false
	cloud.group_changed.emit()
	await at.wait(0.3)
	bar = lobby.dialogs.modal.find_child("TeamPanel", true, false) as Control if lobby.dialogs.modal else null
	if bar == null or bar.find_child("GroupCodeRow", true, false) != null or bar.find_child("GroupCodeNote", true, false) == null \
			or not _find_text(bar, LobbyTeam.CODE_NOTE):
		_fail("a member sees the GROUP CODE while the leader's JOIN BY CODE is off (or the panel closed)")
	cloud.group.code_join = true
	cloud.group_changed.emit()
	await at.wait(0.3)
	var m_row := bar.find_child("GroupCodeRow", true, false) as Control if bar else null
	if m_row == null or _text(m_row, "GroupCode") != "42 1357 9086" or m_row.find_child("GroupCodeCopy", true, false) == null \
			or bar.find_child("GroupCodeNote", true, false) != null:
		_fail("a member does not see the code with COPY while the leader's JOIN BY CODE is on")
	await at.shot("g05a_member_code_on")
	lobby.dialogs.close_modal()
	await at.wait(0.2)
	# The mode card's TEAM panel opens for a member too, read-only: the leader's size lit, the JOIN BY
	# CODE tick shown greyed, no FILL EMPTY PLACES, a tile tap changes nothing.
	var fig := lobby.mode_card.find_child("SizeBoxButton", true, false) as Control
	await _tap(fig)
	await at.wait(0.4)
	var box := lobby.dialogs.size_box
	var t2 := box.find_child("SizeTile_2", true, false) as Button if box else null
	var jt := box.find_child("GroupCodeSwitch", true, false) as Button if box else null
	if t2 == null or not t2.disabled or jt == null or not jt.disabled or box.find_child("TeamFillTick", true, false) != null:
		_fail("a member's TEAM panel is not read-only (tiles and JOIN BY CODE greyed, no FILL EMPTY PLACES)")
	await at.shot("g05d_member_team_panel")
	await _tap(t2)
	await at.wait(0.3)
	if Game.team_size != 4:
		_fail("a member's tile tap changed the size")
	lobby.dialogs.close_size_box()
	var before := JSON.stringify(cloud.group)
	await _tap(wait)
	await _tap(lobby.find_child("ModeCard", true, false) as Control)
	await at.wait(0.4)
	if lobby.dialogs.modal == null or lobby.dialogs.modal.find_child("Mode_lonewolf", true, false) != null:
		_fail("a member could open SELECT MODE")
	lobby.dialogs.close_modal()
	if JSON.stringify(cloud.group) != before or cloud.search_needed != 0:
		_fail("a member's taps changed the group")
	cloud.search_found = 5
	cloud.search_needed = 8
	await at.wait(0.5)
	# The group's search: the same tab as the leader's, without the X (the leader cancels), and
	# the MATCHING... plate in START's place instead of WAITING FOR.
	var tab := lobby.search_tab
	var x := tab.find_child("SearchCancel", true, false) as Control
	var matching := lobby.find_child("MatchingPlate", true, false) as Control
	if not tab.is_visible_in_tree() or _text(tab, "SearchPlayers") != "PLAYERS 5/8" or x.is_visible_in_tree() \
			or wait.is_visible_in_tree() or matching == null or not matching.is_visible_in_tree():
		_fail("a member does not see the group's search tab without its X (%s)" % _text(tab, "SearchPlayers"))
	_no_overlap([tab, matching, lobby.find_child("TeamBar", true, false)])
	await at.shot("g05b_member_searching")
	# TEAMS opened meanwhile (from the TEAM panel): its popup stays clear of the search tab.
	bar = await _open_team_panel(lobby)
	await _tap(bar.find_child("GroupTeams", true, false) as Control if bar else null)
	await at.wait(0.4)
	var frame := lobby.dialogs.modal.find_child("Frame", true, false) as Control if lobby.dialogs.modal else null
	if frame == null:
		_fail("a member's TEAMS did not open")
	else:
		_no_overlap([tab, frame])
		await at.shot("g05c_member_teams_searching")
	lobby.dialogs.close_modal()
	await at.wait(0.2)
	cloud.search_found = 0
	cloud.search_needed = 0
	await at.wait(0.3)
	await at.shot("g05_member_view")
	bar = await _open_team_panel(lobby)
	await _tap(bar.find_child("GroupExit", true, false) as Control if bar else null)
	await at.wait(0.4)
	await _tap(lobby.dialogs.modal.find_child("ConfirmOk", true, false) as Control if lobby.dialogs.modal else null)
	await at.wait(0.6)
	if not cloud.group.is_empty() or not _models(lobby).is_empty() or not lobby.start_btn.is_visible_in_tree():
		_fail("EXIT GROUP did not leave (models %d)" % _models(lobby).size())


## The DUEL in a group of two: the leader's START shows MATCHING... (and the podium's + plate,
## in a group with room, stands right of the hero meanwhile no more: a challenge is out) until the
## member's phone takes it; a duel it never takes gives START back with a notice. No relay here: the
## check lets Cloud think it is connected so the challenge "goes out" (to nowhere).
func _duel_plate(lobby: Lobby) -> void:
	cloud.leave_group()
	lobby.dialogs.close_modal()
	var size_was := Game.team_size
	Game.team_size = 1
	_set_group(cloud.my_id, "lonewolf", 1)
	(cloud.group.members as Array).resize(2)                 # this player and ZORA
	cloud.group_changed.emit()
	await at.wait(0.5)
	var zora := ids.ZORA as String
	cloud.peers[zora] = {"name": "ZORA", "bundle": "neon", "pk": Crypto.new().generate_rsa(1024).save_to_string(true),
		"seen": Time.get_ticks_msec() + 600000}
	var was_connected := cloud._connected
	# (the lobby's relay attempts to 127.0.0.1:9 would drop the stand-in link the moment a closed
	# socket is polled: no socket, no retry while the stand-in holds)
	if cloud._ws != null:
		cloud._ws.close()
		cloud._ws = null
	cloud._retry_t = 1.0e9
	cloud._connected = true
	await _tap(lobby.start_btn)
	await at.wait(0.6)
	var matching := lobby.find_child("MatchingPlate", true, false) as Control
	if cloud.waiting_for_id() != zora or matching == null or not matching.is_visible_in_tree() or lobby.start_btn.is_visible_in_tree() \
			or lobby.dialogs.modal != null:
		_fail("the leader's DUEL start does not show MATCHING... while the member's phone answers (to %s; notice %s; team size %d)"
			% [cloud.waiting_for(), _text(lobby.dialogs.modal, "NoticeText"), Game.team_size])
	await at.shot("g09_duel_matching")
	# The member's phone never takes it: START comes back, a notice says so.
	cloud.cancel_invite(false)
	cloud.invite_answered.emit(false, "ZORA")
	await at.wait(0.6)
	if matching.is_visible_in_tree() or not lobby.start_btn.is_visible_in_tree() or lobby.dialogs.modal == null \
			or not _find_text(lobby.dialogs.modal, "ZORA did not take the duel"):
		_fail("a DUEL never taken does not give START back with a notice")
	lobby.dialogs.close_modal()
	await at.wait(0.3)
	cloud._connected = was_connected
	cloud._retry_t = 0.5
	cloud.peers.erase(zora)
	cloud.leave_group()
	Game.team_size = size_was
	await at.wait(0.3)


## GROUP INVITE: the popup, waiting behind a question, ACCEPT.
func _group_invite(lobby: Lobby) -> void:
	lobby.dialogs.confirm("A QUESTION", "Waiting here.", "OK", func() -> void: pass)
	var key := Crypto.new().generate_random_bytes(32)
	cloud._ginv = {"id": ids.VIPER, "name": "VIPER", "bundle": "default", "gid": "b2".repeat(16), "room": "b2".repeat(16),
		"aes": key, "mac": key, "size": 2, "t": Time.get_ticks_msec()}
	cloud.group_invited.emit("VIPER")
	await at.wait(0.3)
	if lobby.dialogs.modal == null or lobby.dialogs.modal.find_child("GroupInvitePopup", true, false) != null:
		_fail("the GROUP INVITE did not wait behind the open question")
	await _tap(lobby.dialogs.modal.find_child("ConfirmCancel", true, false) as Control if lobby.dialogs.modal else null)
	await at.wait(0.4)
	var popup := lobby.dialogs.modal
	var body := popup.find_child("GroupInvitePopup", true, false) if popup else null
	if body == null or _text(body, "GroupInviteText") != "VIPER invites you to their group" \
			or body.find_child("AcceptButton", true, false) == null or body.find_child("DeclineButton", true, false) == null:
		_fail("no GROUP INVITE popup with ACCEPT / DECLINE after the question closed")
		return
	_touch_ok(popup)
	await at.shot("g06_group_invite_popup")
	await _tap(body.find_child("AcceptButton", true, false) as Control)
	await at.wait(0.3)
	if String(cloud.group.get("leader", "")) != ids.VIPER or String(cloud.group.get("status", "")) != "joining" or lobby.dialogs.modal != null:
		_fail("ACCEPT did not join VIPER's group and close (%s)" % str(cloud.group.get("status")))


## CUSTOM ROOM with slots (the ONLINE window's CUSTOM ROOM tab), with no relay: a room this phone
## hosts, a player put in it as its "gjoin" would, KICK, and a kicked player's notice.
func _room(lobby: Lobby) -> void:
	lobby.friends.open("room")
	await at.wait(0.4)
	var popup := lobby.dialogs.modal
	for n in [1, 2, 4]:
		if popup == null or popup.find_child("RoomMode_%d" % n, true, false) == null:
			_fail("CREATE has no RoomMode_%d" % n)
	await _tap(popup.find_child("RoomMode_4", true, false) as Control if popup else null)
	await at.wait(0.3)
	await _tap(lobby.dialogs.modal.find_child("RoomCreate", true, false) as Control if lobby.dialogs.modal else null)
	await at.wait(0.4)
	var panel := lobby.dialogs.modal.find_child("SlotPanel", true, false) if lobby.dialogs.modal else null
	if not cloud.in_room() or int(cloud.group.get("size", 0)) != 4 or panel == null or panel.find_child("Slot_1_3", true, false) == null \
			or panel.find_child("HostTag", true, false) == null or panel.find_child("SlotKick_0", true, false) != null:
		_fail("CREATE with SQUAD does not open a room with 8 places and the HOST tag")
	await at.shot("g07_room_squad")
	cloud.close_room()
	cloud.open_room("4821", {}, "424242", 2)
	(cloud._grp.invited as Dictionary)[ids.ZORA] = Time.get_ticks_msec()     # (the right password let ZORA in)
	cloud._on_gjoin(ids.ZORA, {"name": "ZORA", "bundle": "neon"})
	lobby.friends.open("room")
	await at.wait(0.4)
	popup = lobby.dialogs.modal
	panel = popup.find_child("SlotPanel", true, false) if popup else null
	var start := popup.find_child("RoomStart", true, false) as Button if popup else null
	var kick := panel.find_child("SlotKick_2", true, false) as Button if panel else null
	if panel == null or kick == null or start == null or start.disabled or _find_label(panel.find_child("Slot_1_0", true, false), "ZORA") == null:
		_fail("a DUO room does not show ZORA on ORANGE with KICK and START")
		return
	_touch_ok(popup)
	await at.shot("g08_room_duo")
	await _tap(panel.find_child("Slot_0_1", true, false) as Control)
	await at.wait(0.4)
	if int(cloud.group_members()[0].slot) != 1:
		_fail("a tap on an empty place does not move the host there (%s)" % str(cloud.group_members()[0]))
	panel = lobby.dialogs.modal.find_child("SlotPanel", true, false) if lobby.dialogs.modal else null
	await _tap(panel.find_child("SlotKick_2", true, false) as Control if panel else null)
	await at.wait(0.4)
	start = lobby.dialogs.modal.find_child("RoomStart", true, false) as Button if lobby.dialogs.modal else null
	if cloud.group_members().size() != 1 or start == null or not start.disabled:
		_fail("KICK does not remove the player (or START does not wait again)")
	cloud.close_room()
	# A player in someone's room, KICKed: back in the lobby with a notice.
	var key := Crypto.new().generate_random_bytes(32)
	cloud._grp = {"gid": "c3".repeat(16), "aes": key, "mac": key, "seq": 0, "their": {}, "seen": {}, "invited": {}, "beat_t": 3.0,
		"join_t": 0.0, "leader_ms": Time.get_ticks_msec(), "joining": false, "manual": true}
	cloud.group = {"gid": "c3".repeat(16), "leader": ids.KITE, "status": "idle", "mode": "lonewolf", "size": 2, "room": "135790", "members": [
		{"id": ids.KITE, "name": "KITE", "bundle": "neon", "team": 0, "slot": 0}, {"id": cloud.my_id, "name": "ME", "bundle": "default", "team": 1, "slot": 2}]}
	cloud.group_changed.emit()
	await at.wait(0.3)
	cloud._room_gone("THE HOST REMOVED YOU FROM ROOM %s")
	await at.wait(0.4)
	if _text(lobby.dialogs.modal, "NoticeText") != "THE HOST REMOVED YOU FROM ROOM 135790" or cloud.in_room():
		_fail("a kicked player is not told (%s)" % _text(lobby.dialogs.modal, "NoticeText"))
	lobby.dialogs.close_modal()
	await at.wait(0.2)


# ---------------------------------------------------------------- helpers

## A group of 4 (this player, ZORA, ABEL, KITE) led by `leader` in Cloud, as its roster brings it
## (the leader first, the default sides), with the group's keys; then group_changed as Cloud emits it.
func _set_group(leader: String, m: String, n: int) -> void:
	var me := {"id": cloud.my_id, "name": "ME", "bundle": "default"}
	var list: Array = [{"id": ids.ZORA, "name": "ZORA", "bundle": "neon"}, {"id": ids.ABEL, "name": "ABEL", "bundle": "default"},
		{"id": ids.KITE, "name": "KITE", "bundle": "neon"}]
	list.insert(0 if leader == cloud.my_id else 1, me)
	var key := Crypto.new().generate_random_bytes(32)
	cloud._grp = {"gid": "a1".repeat(16), "aes": key, "mac": key, "seq": 0, "their": {}, "seen": {}, "invited": {}, "beat_t": 3.0,
		"join_t": 0.0, "leader_ms": Time.get_ticks_msec(), "joining": false, "manual": false}
	cloud.group = {"gid": "a1".repeat(16), "leader": leader, "status": "idle", "mode": m, "size": n, "members": list}
	NetGroup.arrange(list, n, false)
	cloud.group_changed.emit()


## The member models on the podium (not the hero; none on their way out).
func _models(lobby: Lobby) -> Array:
	var gv := lobby.find_child("GroupMembers", true, false)
	if gv == null:
		return []
	return gv.get_children().filter(func(n: Node) -> bool: return n is CharacterModel and not n.is_queued_for_deletion() \
		and String(n.name) != "GroupModelGone")


func _new_lobby(old: Node) -> Lobby:
	var old_id := old.get_instance_id() if old else 0
	var ok := await _until(func() -> bool:
		var s := get_tree().current_scene
		return s is Lobby and s.get_instance_id() != old_id and s.is_node_ready(), 30.0)
	await at.wait(0.6)
	return get_tree().current_scene as Lobby if ok else null


## Every visible button under `root` is a 56 px touch target.
## None of these (the visible ones) overlap on the screen.
func _no_overlap(nodes: Array) -> void:
	var shown: Array = []
	for n: Variant in nodes:
		if n is Control and (n as Control).is_visible_in_tree():
			shown.append(n)
	for i in shown.size():
		for j in range(i + 1, shown.size()):
			var a := (shown[i] as Control).get_global_rect()
			var b := (shown[j] as Control).get_global_rect()
			if a.intersects(b):
				_fail("%s %s overlaps %s %s" % [(shown[i] as Control).name, str(a), (shown[j] as Control).name, str(b)])


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


## A label's or a button's text under `root` holds `part`.
func _shows(root: Node, part: String) -> bool:
	for c in root.find_children("*", "", true, false):
		if (c is Label and (c as Label).text.contains(part)) or (c is Button and (c as Button).text.contains(part)):
			return true
	return false


func _find_text(root: Node, part: String) -> bool:
	for l in root.find_children("*", "Label", true, false):
		if (l as Label).text.contains(part):
			return true
	return false


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
	at.log_line("GROUP LOBBY CHECK DONE bad=%d" % bad)
	return bad

extends Node
## GROUPS in the lobby (design/GROUPS.txt 1, UI), one copy of the game, run by tools/qa/run_checks.sh
## (step group_lobby) with a relay that is never there (LW_MQTT_URL=ws://127.0.0.1:9: nothing
## leaves the machine). The Cloud group API is CORE's: a stand-in (tests/group_stub.gd, put in
## LobbyTeam.stand_in before the lobby opens) plays it; the check sets its `group` and emits
## group_changed as Cloud would. Real taps where a player taps:
## - a solo in LONE WOLF: the GROUP bar with + INVITE; the invite list (GroupAsk_<code> only on an
##   online friend) sends Cloud.group_invite and says INVITED <NAME>, then JOINED;
## - the leader of 4: three member models on the podium besides the hero, with name plates; REMOVE
##   on each other member (asked first), DISBAND GROUP, INVITE greyed (full); TEAMS: the slot panel
##   moves a member (Cloud.set_group_team);
## - START (leader, DUO): Cloud.group_start; SEARCHING PLAYERS n/N with CANCEL; a notice when
##   group_start says why it cannot start;
## - a member: WAITING FOR <LEADER> TO START in START's place, the LEADER mark on the leader's model,
##   the mode card follows the leader's mode, EXIT GROUP (asked first) leaves and the models go;
## - GROUP INVITE: "<NAME> invites you to their group", waiting behind a question, ACCEPT;
## - every touch target on the way is at least 56 px.
## Prints "GROUP LOBBY CHECK DONE bad=N".

const GroupStub := preload("res://tests/group_stub.gd")

var bad := 0
var at: Node
var stub: RefCounted
var ids := {}


func run(autotest: Node) -> int:
	at = autotest
	Game.profile.name_set = true         # (no first-start name prompt over the lobby)
	Game.practice = false
	Game.mode = "lonewolf"
	Game.team_size = 2
	if not await _until(func() -> bool: return get_tree().current_scene is Lobby, 30.0):
		return _done("the lobby never came up")
	stub = GroupStub.new()
	LobbyTeam.stand_in = stub
	for n: String in ["ZORA", "ABEL", "KITE", "OFFLINE PAL", "VIPER"]:
		ids[n] = (n + " id").sha256_text().left(32)
	var first := get_tree().current_scene
	Game.goto_lobby()                    # a lobby that listens to the stand-in
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
	Game.profile.friends = saved_friends
	LobbyTeam.stand_in = null
	Game.team_size = 1
	Game.mode = "training"
	return _done("")


## A solo in LONE WOLF: + INVITE, the list of friends, INVITED <NAME>.
func _solo(lobby: Lobby) -> void:
	var bar := lobby.find_child("GroupBar", true, false) as Control
	if bar == null or not bar.is_visible_in_tree():
		_fail("no GROUP bar in LONE WOLF")
		return
	var invite := bar.find_child("GroupInvite", true, false) as Button
	if invite == null or invite.disabled or bar.find_child("GroupExit", true, false) or bar.find_child("GroupDisband", true, false):
		_fail("a solo's GROUP bar is not + INVITE alone")
	_touch_ok(bar)
	var cloud := Game.cloud_service()
	Game.profile.friends = {ids.ZORA: {"name": "ZORA"}, ids["OFFLINE PAL"]: {"name": "ABBY"}}
	cloud.peers[ids.ZORA] = {"name": "ZORA", "bundle": "neon", "pk": "", "seen": Time.get_ticks_msec() + 600000}
	await _tap(invite)
	await at.wait(0.8)
	var popup := lobby.dialogs.modal
	var list := popup.find_child("GroupInviteList", true, false) if popup else null
	var ask := list.find_child("GroupAsk_" + Cloud.friend_code(ids.ZORA), true, false) as Button if list else null
	var ask_off := list.find_child("GroupAsk_" + Cloud.friend_code(ids["OFFLINE PAL"]), true, false) as Button if list else null
	if ask == null or ask_off == null or ask.disabled or not ask_off.disabled:
		_fail("+ INVITE does not list the friends with INVITE on the online one only")
		return
	_touch_ok(list)
	await at.shot("g01_group_invite_list")
	await _tap(ask)
	await at.wait(0.5)
	if stub.call("last", "group_invite") != ["group_invite", ids.ZORA]:
		_fail("INVITE did not call Cloud.group_invite (%s)" % str(stub.get("calls")))
	if _text(lobby.dialogs.modal, "GroupInvited") != "INVITED ZORA":
		_fail("no INVITED ZORA popup (%s)" % _text(lobby.dialogs.modal, "GroupInvited"))
	cloud.peers.erase(ids.ZORA)


## The leader of 4: three models besides the hero with name plates; REMOVE, DISBAND, INVITE greyed.
func _leader(lobby: Lobby) -> void:
	var me := String(stub.get("my_id"))
	_set_group(me, "lonewolf", 2)
	await at.wait(0.6)
	if _text(lobby.dialogs.modal, "GroupInvited") != "ZORA JOINED YOUR GROUP":
		_fail("the invite's popup does not say ZORA JOINED (%s)" % _text(lobby.dialogs.modal, "GroupInvited"))
	await _tap(lobby.dialogs.modal.find_child("GroupInvitedOk", true, false) as Control if lobby.dialogs.modal else null)
	await at.wait(0.3)
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
	var bar := lobby.find_child("GroupBar", true, false) as Control
	for n in [1, 2, 3, 4]:
		if bar.find_child("GroupMember_%d" % n, true, false) == null:
			_fail("no GroupMember_%d" % n)
	if bar.find_child("GroupRemove_1", true, false) != null or bar.find_child("GroupRemove_2", true, false) == null \
			or bar.find_child("GroupRemove_4", true, false) == null:
		_fail("REMOVE is not on every other member only")
	if bar.find_child("GroupDisband", true, false) == null or bar.find_child("GroupExit", true, false) != null:
		_fail("the leader does not see DISBAND GROUP (alone)")
	if _find_label(bar.find_child("GroupMember_1", true, false), "LEADER") == null:
		_fail("the leader's row has no LEADER tag")
	var invite := bar.find_child("GroupInvite", true, false) as Button
	if invite == null or not invite.disabled:
		_fail("+ INVITE is not greyed in a full group")
	_touch_ok(bar)
	await at.shot("g02_leader_of_four")
	await _tap(bar.find_child("GroupRemove_3", true, false) as Control)
	await at.wait(0.4)
	await _tap(lobby.dialogs.modal.find_child("ConfirmOk", true, false) as Control if lobby.dialogs.modal else null)
	await at.wait(0.3)
	var kicked: Array = stub.call("last", "kick_from_group")
	if kicked.size() != 2 or not String(kicked[1]) in [ids.ZORA, ids.ABEL, ids.KITE]:
		_fail("REMOVE did not call Cloud.kick_from_group (%s)" % str(kicked))


## START (the leader, DUO): group_start, SEARCHING PLAYERS n/N, CANCEL; a notice when it cannot.
func _start_and_search(lobby: Lobby) -> void:
	stub.set("start_answer", "")
	stub.set("search_found", 3)
	stub.set("search_needed", 4)
	if not lobby.start_btn.is_visible_in_tree():
		_fail("the leader has no START")
	await _tap(lobby.start_btn)
	await at.wait(0.5)
	if stub.call("last", "group_start") != ["group_start", 2]:
		_fail("START did not call Cloud.group_start(2) (%s)" % str(stub.get("calls")))
	var popup := lobby.dialogs.modal
	if popup == null or popup.find_child("GroupSearch", true, false) == null or _text(popup, "GroupSearchCount") != "SEARCHING PLAYERS 3/4":
		_fail("no SEARCHING PLAYERS 3/4 popup (%s)" % _text(popup, "GroupSearchCount"))
	if popup and (_find_text(popup, "BOT") or _text(popup, "GroupSearchTimer") == ""):
		_fail("the search popup mentions bots or has no timer")
	stub.set("search_found", 4)
	await at.wait(0.2)
	if _text(lobby.dialogs.modal, "GroupSearchCount") != "SEARCHING PLAYERS 4/4":
		_fail("the search count does not follow Cloud.search_found")
	if popup:
		_touch_ok(popup)
	await at.shot("g03_searching_players")
	await _tap(popup.find_child("GroupSearchCancel", true, false) as Control if popup else null)
	await at.wait(0.3)
	if stub.call("last", "group_search_stop").is_empty() or lobby.dialogs.modal != null:
		_fail("CANCEL does not stop the search and close its popup")
	stub.set("start_answer", "DUO needs a group of 1, 2 or 4")
	await _tap(lobby.start_btn)
	await at.wait(0.4)
	if _text(lobby.dialogs.modal, "NoticeText") != "DUO needs a group of 1, 2 or 4":
		_fail("group_start's answer is not shown (%s)" % _text(lobby.dialogs.modal, "NoticeText"))
	lobby.dialogs.close_modal()
	await at.wait(0.2)
	stub.set("start_answer", "")
	stub.set("search_needed", 0)
	stub.set("search_found", 0)


## TEAMS: the leader's slot panel; tap a member, then a place: Cloud.set_group_team.
func _teams(lobby: Lobby) -> void:
	var bar := lobby.find_child("GroupBar", true, false) as Control
	await _tap(bar.find_child("GroupTeams", true, false) as Control if bar else null)
	await at.wait(0.4)
	var panel := lobby.dialogs.modal.find_child("SlotPanel", true, false) if lobby.dialogs.modal else null
	if panel == null or panel.find_child("Slot_0_0", true, false) == null or panel.find_child("Slot_1_1", true, false) == null \
			or panel.find_child("HostTag", true, false) == null:
		_fail("TEAMS has no BLUE / ORANGE slot panel with the leader's tag")
		return
	_touch_ok(panel)
	await at.shot("g04_group_teams")
	await _tap(panel.find_child("Slot_1_1", true, false) as Control)
	await at.wait(0.2)
	panel = lobby.dialogs.modal.find_child("SlotPanel", true, false)
	await _tap(panel.find_child("Slot_0_1", true, false) as Control if panel else null)
	await at.wait(0.3)
	var moved: Array = stub.call("last", "set_group_team")
	if moved.size() != 4 or int(moved[2]) != 0 or int(moved[3]) != 1:
		_fail("moving a member did not call Cloud.set_group_team (%s)" % str(moved))
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
		var plate := cm.get_node_or_null(^"NamePlate") as Label3D
		if mark and mark.visible:
			marks += 1
			if plate == null or plate.text != "ZORA":
				_fail("the LEADER mark is not on ZORA's model")
	if marks != 1:
		_fail("%d models show the LEADER mark, not 1" % marks)
	var bar := lobby.find_child("GroupBar", true, false) as Control
	if bar.find_child("GroupExit", true, false) == null or bar.find_child("GroupDisband", true, false) != null \
			or bar.find_child("GroupRemove_2", true, false) != null:
		_fail("a member does not see EXIT GROUP alone")
	var calls_before: int = (stub.get("calls") as Array).size()
	await _tap(wait)
	await _tap(lobby.find_child("ModeCard", true, false) as Control)
	await at.wait(0.4)
	if lobby.dialogs.modal == null or lobby.dialogs.modal.find_child("Mode_lonewolf", true, false) != null:
		_fail("a member could open SELECT MODE")
	lobby.dialogs.close_modal()
	if (stub.get("calls") as Array).size() != calls_before:
		_fail("a member's taps reached the group API (%s)" % str(stub.get("calls")))
	stub.set("search_found", 5)
	stub.set("search_needed", 8)
	await at.wait(0.5)
	if _find_label(wait, "SEARCHING PLAYERS 5/8") == null:
		_fail("a member does not see the group's search")
	stub.set("search_needed", 0)
	await at.wait(0.3)
	await at.shot("g05_member_view")
	await _tap(bar.find_child("GroupExit", true, false) as Control)
	await at.wait(0.4)
	await _tap(lobby.dialogs.modal.find_child("ConfirmOk", true, false) as Control if lobby.dialogs.modal else null)
	await at.wait(0.6)
	if stub.call("last", "leave_group").is_empty() or not _models(lobby).is_empty() or not lobby.start_btn.is_visible_in_tree():
		_fail("EXIT GROUP did not leave (models %d)" % _models(lobby).size())


## GROUP INVITE: the popup, waiting behind a question, ACCEPT.
func _group_invite(lobby: Lobby) -> void:
	lobby.dialogs.confirm("A QUESTION", "Waiting here.", "OK", func() -> void: pass)
	stub.call("send_invite", ids.VIPER, "VIPER")
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
	if stub.call("last", "answer_group_invite") != ["answer_group_invite", true] or lobby.dialogs.modal != null:
		_fail("ACCEPT did not call Cloud.answer_group_invite(true) and close")


# ---------------------------------------------------------------- helpers

## A group of 4 (this player, ZORA, ABEL, KITE) led by `leader`, as Cloud's group_changed brings it.
func _set_group(leader: String, m: String, n: int) -> void:
	var me := String(stub.get("my_id"))
	stub.set("group", {"gid": "a1".repeat(16), "leader": leader, "status": "idle", "mode": m, "size": n, "members": [
		{"id": me, "name": "ME", "bundle": "default"}, {"id": ids.ZORA, "name": "ZORA", "bundle": "neon"},
		{"id": ids.ABEL, "name": "ABEL", "bundle": "default"}, {"id": ids.KITE, "name": "KITE", "bundle": "neon"}]})
	stub.emit_signal("group_changed")


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

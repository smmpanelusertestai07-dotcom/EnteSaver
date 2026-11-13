extends RefCounted
## Unit tests of the screens out of the match (round 8, run from tests/run_tests.gd):
## - HISTORY: a win because the opponent left keeps "left_by_them" through a save and a load; old
##   entries read as false; a loss never carries it.
## - PUBLIC rooms (NetRooms): a signed card is listed; a wrong signature, another key's id, a card
##   older than 2 minutes or from the future, a blocked host, this phone's own, malformed or
##   over-long fields are not; one card per host (a newer one replaces it, an empty message takes
##   it away); at most MAX_CARDS kept; QUICK JOIN picks the newest open room without a password.
## - CREATE: a private room starts with a made-up password; switching PUBLIC on clears it (a public
##   room has none unless the player types one); a typed password stays.
## - WARDROBE's poses: profile lobby_pose / victory_pose are kept when known, else "" (random).

var t: Node


## A LobbyFriends whose page redraw only counts (the create form is built by hand here).
class DraftFriends extends LobbyFriends:
	var redraws := 0

	func redraw_room() -> void:
		redraws += 1


static func run(runner: Node) -> void:
	var me := new()
	me.t = runner
	me._history_left_by_them()
	me._poses()
	me._rooms()
	me._room_draft()


func _check(ok: bool, what: String) -> void:
	t._check(ok, what)


func _history_left_by_them() -> void:
	var saved_profile := Game.profile.duplicate(true)
	var saved_result: Dictionary = Game.last_result
	var at := Game.autotest
	Game.autotest = "unit"          # nothing is written to user://
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	var rival := "rival-left".sha256_text().left(32)
	Game.record_match({"won": true, "opponent_left": true, "kills": 0, "mode_id": "lonewolf", "enemy": "RIVAL",
		"score_player": 0, "score_bot": 2, "enemy_id": rival})
	Game.record_match({"won": false, "opponent_left": true, "kills": 1, "mode_id": "lonewolf", "enemy": "RIVAL",
		"score_player": 1, "score_bot": 2, "enemy_id": rival})
	Game.record_match({"won": true, "kills": 3, "mode_id": "lonewolf", "enemy": "RIVAL", "score_player": 2, "enemy_id": rival})
	var h: Array = Game.profile.history
	_check(h.size() == 3 and h[2].get("left_by_them", false) == true and not h[1].has("left_by_them")
		and not h[0].has("left_by_them") and (h[0] as Dictionary).size() == 10,
		"HISTORY: only a win because the opponent left is flagged (%s)" % str(h))
	# through the saved file's path: signed, verified, migrated, sanitised
	var raw: Dictionary = JSON.parse_string(JSON.stringify(Guard.sign_dict(Game.profile)))
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	var ok := Game._apply_saved_profile(raw)
	h = Game.profile.history
	_check(ok and h.size() == 3 and h[2].get("left_by_them", false) == true and not h[0].has("left_by_them"),
		"the OPPONENT LEFT flag survives a save and a load")
	# an old entry (1.9.1 and before) has no flag: false; a wrong value is dropped
	Game.profile.history = [{"result": "won", "mode": "lonewolf", "enemy": "OLD", "score": 0, "enemy_score": 2},
		{"result": "won", "mode": "lonewolf", "enemy": "ODD", "left_by_them": "yes"}]
	Game._sanitize_profile()
	h = Game.profile.history
	_check(h.size() == 2 and h[0].get("left_by_them", false) == false and not h[1].has("left_by_them"),
		"old HISTORY entries read as not left; a wrong flag is dropped")
	Game.profile = saved_profile
	Game.last_result = saved_result
	Game.autotest = at


func _poses() -> void:
	var saved_profile := Game.profile.duplicate(true)
	_check(Game.DEFAULT_PROFILE.lobby_pose == "" and Game.DEFAULT_PROFILE.victory_pose == "", "no pose chosen by default (random)")
	Game.profile.lobby_pose = "lobby_hip"
	Game.profile.victory_pose = "victory"
	Game._sanitize_profile()
	_check(Game.profile.lobby_pose == "lobby_hip" and Game.profile.victory_pose == "victory", "known poses are kept")
	for bad: Variant in ["dance", 42, null, ["lobby_hip"], "victory_pose "]:
		Game.profile.lobby_pose = bad
		Game.profile.victory_pose = bad
		Game._sanitize_profile()
		_check(Game.profile.lobby_pose == "" and Game.profile.victory_pose == "", "an unknown pose reads as random (%s)" % str(bad))
	Game.profile.lobby_pose = "victory"         # a victory clip is not a lobby pose
	Game._sanitize_profile()
	_check(Game.profile.lobby_pose == "", "a victory clip is no lobby pose")
	for clip: String in Game.LOBBY_POSES:
		_check(clip == "" or CharacterModel.LOBBY_GESTURES.has(clip), "lobby pose %s is a lobby gesture" % clip)
	Game.profile = saved_profile


func _room_card(key: CryptoKey, f: Dictionary, ts: int, id_override := "") -> PackedByteArray:
	var pk := key.save_to_string(true)
	var id := id_override if id_override != "" else pk.sha256_text().left(32)
	return NetRooms.card_json(f, id, pk, ts, key).to_utf8_buffer()


func _rooms() -> void:
	var saved_blocked: Variant = Game.profile.blocked.duplicate(true)
	var key := Crypto.new().generate_rsa(2048)       # (Cloud.verify_signed takes 2048-bit keys, as the phones make)
	var other := Crypto.new().generate_rsa(2048)
	var id := key.save_to_string(true).sha256_text().left(32)
	var oid := other.save_to_string(true).sha256_text().left(32)
	var now := int(Time.get_unix_time_from_system())
	var f := {"host": "HOSTY", "name": "FRIDAY FIGHTS", "size": 2, "filled": 1, "total": 4, "rules": "FIRST TO 4 - HP 200",
		"pw": false, "code": "123456"}
	var r := NetRooms.new()
	_check(r.take(id, _room_card(key, f, now), now) and r.list(now).size() == 1 and String(r.list(now)[0].name) == "FRIDAY FIGHTS"
		and int(r.list(now)[0].total) == 4, "a signed public room card is listed")
	# one per host: a newer card replaces it, an older one does not, an empty message removes it
	var f2 := f.duplicate()
	f2.filled = 3
	_check(r.take(id, _room_card(key, f2, now + 1), now + 1) and r.cards.size() == 1 and int(r.cards[id].filled) == 3, "a newer card replaces the host's card")
	_check(not r.take(id, _room_card(key, f, now - 5), now + 1) and int(r.cards[id].filled) == 3, "an older card does not")
	_check(r.take(id, PackedByteArray(), now) and r.cards.is_empty(), "an empty message takes the card away")
	# the signature, the key and the topic must agree
	var bad_sig: Dictionary = JSON.parse_string(_room_card(key, f, now).get_string_from_utf8())
	bad_sig.name = "CHANGED"
	_check(NetRooms.check(JSON.stringify(bad_sig).to_utf8_buffer(), id, now).is_empty(), "a changed field breaks the signature")
	_check(NetRooms.check(_room_card(other, f, now, id), id, now).is_empty(), "a card for another key's id is refused")
	_check(NetRooms.check(_room_card(key, f, now), oid, now).is_empty(), "a card on another host's topic is refused")
	_check(NetRooms.check(_room_card(key, f, now), id, now, id).is_empty(), "this phone's own card is not listed")
	# expiry: older than 2 minutes, or from the future
	_check(NetRooms.check(_room_card(key, f, now - NetRooms.MAX_AGE_S - 1), id, now).is_empty(), "a card older than 2 minutes is dropped")
	_check(NetRooms.check(_room_card(key, f, now + 600), id, now).is_empty(), "a card from the future is dropped")
	r.take(id, _room_card(key, f, now - 100), now - 100)
	_check(r.list(now + 30).is_empty(), "a listed card expires after 2 minutes")
	# blocked hosts never show
	Game.profile.blocked = [{"id": id, "name": "HOSTY", "t": now}]
	_check(NetRooms.check(_room_card(key, f, now), id, now).is_empty(), "a blocked host's card is refused")
	r.cards[id] = {"id": id, "ts": now, "filled": 1, "total": 2, "pw": false, "code": "123456"}
	_check(r.list(now).is_empty(), "a host blocked later leaves the list")
	Game.profile.blocked = saved_blocked
	r.cards.clear()
	# malformed and over-long fields
	for m: Array in [["size", 3], ["total", 6], ["filled", 0], ["filled", 9], ["code", "12345"], ["code", "12a456"], ["pw", "no"],
			["name", "X".repeat(RoomRules.NAME_MAX + 1)], ["host", "H".repeat(NetRooms.FIELD_MAX + 1)], ["rules", "a|b"],
			["rules", "R".repeat(NetRooms.FIELD_MAX + 1)]]:
		var g := f.duplicate()
		g[m[0]] = m[1]
		var raw := _room_card(key, g, now)
		_check(NetRooms.check(raw, id, now).is_empty(), "a card with %s = %s is refused" % [m[0], str(m[1])])
	var big := PackedByteArray()
	big.resize(Cloud.MAX_MESSAGE + 1)
	_check(NetRooms.check(big, id, now).is_empty() and NetRooms.check("[1,2]".to_utf8_buffer(), id, now).is_empty(), "junk is refused")
	# the list keeps MAX_CARDS at most (the oldest go), QUICK JOIN the newest open room without a password
	for i in NetRooms.MAX_CARDS + 5:
		r.cards["h%03d" % i] = {"id": "h%03d" % i, "ts": now - 60 + i % 50, "filled": 2, "total": 2, "pw": false, "code": "%06d" % i}
	r.take(id, _room_card(key, f, now), now)
	_check(r.cards.size() == NetRooms.MAX_CARDS and r.cards.has(id), "at most %d room cards are kept" % NetRooms.MAX_CARDS)
	_check(String(r.quick_pick(now).get("code", "")) == "123456", "QUICK JOIN: the newest room with a free place")
	var locked := f.duplicate()
	locked.pw = true
	r.take(id, _room_card(key, locked, now + 1), now + 1)
	_check(r.quick_pick(now + 1).is_empty() and bool(r.by_code("123456", now + 1).pw), "QUICK JOIN skips a room with a password")


func _room_draft() -> void:
	var saved_cloud := Game.cloud
	var cl := Cloud.new()
	Game.cloud = cl
	var lf := DraftFriends.new(null)
	var d: Dictionary = lf.room_draft
	var v := VBoxContainer.new()
	lf._build_room_tab(v)
	var auto_pin := String(d.pin)
	_check(auto_pin.length() == 4 and bool(d.pin_auto), "a private room starts with a made-up password (%s)" % auto_pin)
	(v.find_child("RoomPublic_yes", true, false) as Button).pressed.emit()
	_check(bool(d.public) and String(d.pin) == "" and lf.redraws == 1, "switching PUBLIC on clears the made-up password")
	v.free()
	v = VBoxContainer.new()
	lf._build_room_tab(v)
	_check(String(d.pin) == "" and (v.find_child("RoomPin", true, false) as LineEdit).placeholder_text == "OPTIONAL",
		"a PUBLIC room's form leaves the password empty (OPTIONAL)")
	(v.find_child("RoomPin", true, false) as LineEdit).text_changed.emit("2468")
	(v.find_child("RoomPublic_no", true, false) as Button).pressed.emit()
	(v.find_child("RoomPublic_yes", true, false) as Button).pressed.emit()
	_check(String(d.pin) == "2468" and not bool(d.pin_auto), "a password the player typed stays when PUBLIC is switched")
	v.free()
	lf.lan = null
	Game.cloud = saved_cloud
	cl.free()

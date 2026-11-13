extends RefCounted
## Unit tests of the screens out of the match (round 8, run from tests/run_tests.gd):
## - HISTORY: a win because the opponent left keeps "left_by_them" through a save and a load; old
##   entries read as false; a loss never carries it.
## - WARDROBE's poses: profile lobby_pose / victory_pose are kept when known, else "" (random).

var t: Node


static func run(runner: Node) -> void:
	var me := new()
	me.t = runner
	me._history_left_by_them()
	me._poses()


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

extends Node
## Results tour: both pages of a win, a loss, a draw, a SQUAD result, an online win with REMATCH and
## one whose opponent left ("<NAME> LEFT: NO REMATCH"), each over the key art with a stub scoreboard.
## Run: tools/qa/capture.sh /abs/dir 1280x720 script:res://tests/shots_results.gd
## Checks on the way: page 1 shows the character, the title, the plate and CONTINUE (no LOBBY);
## CONTINUE opens page 2 (side names, both tables, LOBBY); Android back goes back to page 1.

var _at: Node
var _fails := 0


func run(at: Node) -> int:
	_at = at
	var saved_name := String(Game.profile.get("name", "PLAYER"))
	Game.profile.name = "ROOKIE"
	for kind in ["victory", "defeat", "draw", "squad", "online", "left"]:
		var rs := await _scene(_sample(kind))
		await at.wait(2.4)
		_check(rs.page == 1 and rs.find_child("Page1", true, false).visible and not rs.find_child("Page2", true, false).visible,
			"%s: the results open on page 1" % kind)
		_check(rs.find_child("HeroModel", true, false) is CharacterModel and rs.find_child("HeroPlate", true, false) != null,
			"%s: page 1 has the character and its plate" % kind)
		var go := rs.find_child("Continue", true, false) as Button
		_check(go != null and go.visible and not (rs.find_child("Lobby", true, false) as Control).visible, "%s: CONTINUE, no LOBBY on page 1" % kind)
		await at.shot("res_%s_1" % kind)
		await _tap(go)
		await at.wait(0.6)
		_check(rs.page == 2 and (rs.find_child("Lobby", true, false) as Control).visible, "%s: CONTINUE opens page 2 with LOBBY" % kind)
		var s0 := (rs.find_child("SideName_0", true, false) as Label).text
		var s1 := (rs.find_child("SideName_1", true, false) as Label).text
		_check(s0 != s1 and ResultsScreen.SIDE_NAMES.has(s0) and ResultsScreen.SIDE_NAMES.has(s1), "%s: two side names (%s / %s)" % [kind, s0, s1])
		await at.shot("res_%s_2" % kind)
		rs.notification(NOTIFICATION_WM_GO_BACK_REQUEST)
		await at.wait(0.2)
		_check(rs.page == 1 and get_tree().current_scene.name == "ResultsTest", "%s: back on page 2 goes back to page 1" % kind)
	Game.profile.name = saved_name
	at.log_line("RESULTS TOUR DONE fails=%d" % _fails)
	return 1 if _fails > 0 else 0


func _sample(kind: String) -> Dictionary:
	var online := kind == "online" or kind == "left"
	var won := kind in ["victory", "online", "left", "squad"]
	var n: Array = {"victory": [5, 2, 5, 1176, 3, 112, 330], "defeat": [2, 5, 2, 537, 1, 0, 74], "draw": [4, 4, 4, 912, 1, 84, 150],
		"squad": [4, 2, 6, 1420, 2, 96, 420], "online": [5, 3, 5, 1214, 3, 96, 330], "left": [2, 1, 2, 400, 0, 160, 220]}[kind]
	var r := {"kind": kind, "won": won, "draw": kind == "draw", "invalid": false, "kills": int(n[2]), "damage": int(n[3]),
		"headshots": int(n[4]), "accuracy": 46.7, "time": 412.0, "xp": int(n[6]), "deaths": 2 if won else 5,
		"enemy": "SHADOWHUNTER77" if online else "BOT VIPER", "mode": Game.mode_name("lonewolf" if online else "training"),
		"mode_id": "lonewolf" if online else "training", "map": "CARGO CAGE", "weapon": String(Weapons.DEFS[Weapons.DEFAULT_PICK].name),
		"score_player": int(n[0]), "score_bot": int(n[1]), "hp_left": int(n[5]), "difficulty": "ONLINE" if online else "NORMAL",
		"taken": 88 if won else 200, "enemy_id": "shadowhunter77".sha256_text().left(32) if online else "",
		"opponent_left": kind == "left"}
	if kind == "squad":
		var rows := []
		for i in 8:
			var mine := i < 4
			rows.append({"name": ["ROOKIE", "KAI", "NOVA", "REX", "ONYX", "TITAN", "ZED", "BLAZE"][i], "me": i == 0, "ally": mine,
				"team": 0 if mine else 1, "slot": i, "status": "up" if i < 6 else "down", "bot": i > 0, "kills": [6, 3, 2, 1, 2, 1, 1, 0][i],
				"deaths": [1, 2, 2, 3, 4, 4, 4, 4][i], "knocks": [5, 2, 2, 1, 2, 1, 1, 0][i], "revives": [1, 2, 0, 1, 0, 1, 0, 0][i],
				"damage": [1420, 860, 702, 455, 690, 540, 320, 110][i], "headshots": [2, 1, 0, 0, 1, 0, 0, 0][i], "accuracy": 38, "hp": 96, "alive": i < 6})
		r.merge({"team": true, "team_size": 4, "rows": rows, "mode": "SQUAD", "mode_id": "squad", "enemy": "ORANGE TEAM", "knocks": 5,
			"revives": 1, "bots": 7, "online": false}, true)
	return r


## An empty scene with the key art and a stub `scoreboard_rows()`, the results on top.
func _scene(r: Dictionary) -> ResultsScreen:
	var stub := GDScript.new()
	stub.source_code = "extends Control\nvar rows: Array = []\nfunc scoreboard_rows() -> Array:\n\treturn rows\n"
	stub.reload()
	var root := Control.new()
	root.set_script(stub)
	root.name = "ResultsTest"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.set("rows", [
		{"name": "ROOKIE", "me": true, "hp": int(r.hp_left), "kills": int(r.kills), "damage": int(r.damage), "headshots": int(r.headshots),
			"accuracy": 47, "deaths": int(r.deaths)},
		{"name": String(r.enemy), "me": false, "hp": 0 if bool(r.won) else 64, "kills": int(r.score_bot), "damage": 652,
			"headshots": 1, "accuracy": 31, "deaths": int(r.score_player)},
	])
	var tex := UI.texture("keyart_clean.jpg")
	if tex:
		root.add_child(UI.cover(tex))
	get_tree().change_scene_to_node(root)
	await _at.wait(0.3)
	var rs := ResultsScreen.new()
	root.add_child(rs)
	rs.setup(r)
	return rs


func _tap(c: Control) -> void:
	if c == null:
		_check(false, "tap target exists")
		return
	var w: Vector2 = get_tree().root.get_final_transform() * c.get_global_rect().get_center()
	_at.touch(0, w, true)
	await _at.wait(0.08)
	_at.touch(0, w, false)
	await _at.wait(0.12)


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
	_at.log_line(("ok   " if ok else "FAIL ") + what)

extends Node
## Settings screenshot tour (every page of the lobby's settings, a selected CONTROLS row, the
## lower half of the long pages):
##   tools/qa/capture.sh <out_dir> 1280x720 script:res://tests/shots_settings.gd
## Checks that every page builds, no row's control runs past the screen's right edge, the
## preview pages show their picture and the HUD page draws the player's own layout (set_6_hud_moved:
## FIRE moved to the bottom middle, no left fire button). Returns the number of failed checks.

var _fails := 0


func run(at: Node) -> int:
	await at.wait(1.5)
	var lobby: Node = at.get_tree().current_scene
	lobby.call("_open_settings")
	await at.wait(0.6)
	var sp: SettingsPanel = lobby.call("_find_settings")
	_check(sp != null, "the settings open", at)
	if sp == null:
		return _fails
	var vs := sp.get_viewport_rect().size
	for page in [6, 2, 1, 7, 0, 3, 4, 5]:
		sp._show_tab(page)
		await at.wait(0.5)
		var tab_name := String(SettingsPanel.TABS[page]).to_lower()
		await at.shot("set_%d_%s" % [page, tab_name])
		var wide := false
		for c in sp._body.find_children("*", "Control", true, false):
			if (c as Control).is_visible_in_tree() and (c as Control).get_global_rect().end.x > vs.x + 1.0:
				wide = true
		_check(not wide, "%s: nothing runs past the right edge" % tab_name, at)
		if page in SettingsPanel.PREVIEW_TABS:
			_check(sp._pane.visible and sp._sel != "", "%s: the picture of the selected row" % tab_name, at)
		if page in [2, 0, 4]:
			sp._scroll.scroll_vertical = 100000
			await at.wait(0.4)
			if page == 2:
				sp._select("freelook_button")
				await at.wait(0.3)
			await at.shot("set_%d_%s_more" % [page, tab_name])
	# The HUD page shows the player's own layout: FIRE moved to the middle and made smaller, the
	# left fire button off (the picture follows a layout saved while it shows).
	var saved_layout: Dictionary = Game.hud_layout
	var saved_left := int(Game.settings.left_fire)
	sp._show_tab(6)
	await at.wait(0.3)
	var lay := HudLayout.current()
	lay.fire_r.x = 0.5
	lay.fire_r.y = 0.82
	lay.fire_r.a = "c"
	lay.fire_r.s = 0.18
	Game.settings.left_fire = HUD.LEFT_FIRE_OFF
	Game.hud_layout = HudLayout.to_save(lay)
	await at.wait(0.4)
	_check(sp.find_child("HudTile", true, false) != null and is_same(sp._hud_seen, Game.hud_layout), "hud: the picture follows the saved layout", at)
	await at.shot("set_6_hud_moved")
	Game.hud_layout = saved_layout
	Game.settings.left_fire = saved_left
	sp._show_tab(2)
	sp._select("joystick")
	await at.wait(0.4)
	await at.shot("set_2_controls_joystick")
	sp.close_panel()
	await at.wait(0.3)
	at.log_line("SETTINGS TOUR fails=%d" % _fails)
	return _fails


func _check(ok: bool, what: String, at: Node) -> void:
	if not ok:
		_fails += 1
	at.log_line(("ok   " if ok else "FAIL ") + what)

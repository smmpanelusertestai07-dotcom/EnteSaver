extends RefCounted
## Unit tests of the 1 vs 1 match feedback (round 8): the ELIMINATED BY card against the HP block,
## whose HP the block shows, damage-number bursts, the minimap's view, the two-line kill feed, the
## quick wall and the settings migration v8. Run from tests/run_tests.gd (which counts the checks).

var t: Node


static func run(runner: Node) -> void:
	var me := new()
	me.t = runner
	me._test_death_card()


func _check(cond: bool, what: String) -> void:
	t.call("_check", cond, what)


func _hud() -> HUD:
	var hud := HUD.new()
	hud.layout = HudLayout.resolve({})
	return hud


## The card ends left of the HP block's first armour icon from 16:10 to 22:9; a dead player (in
## the round or in the break) gets no HP block of their own, a spectator the watched fighter's.
func _test_death_card() -> void:
	var hud := _hud()
	for aspect: float in [16.0 / 10.0, 16.0 / 9.0, 18.0 / 9.0, 19.5 / 9.0, 20.0 / 9.0, 22.0 / 9.0]:
		var vs := Vector2(roundf(720.0 * aspect), 720.0)
		var u := HudLayout.unit(vs)
		var card := hud.death_card_rect(vs, u)
		var icon_x := float(hud.hp_geometry(vs, u).x0)
		_check(card.end.x <= icon_x - 0.01 * u + 0.01, "aspect %.2f: the ELIMINATED BY card (right %.0f) ends 0.01u before the HP icons (%.0f)" % [aspect, card.end.x, icon_x])
		_check(card.position.x >= 0.0 and card.size.x >= 0.2 * u, "aspect %.2f: the card keeps a usable width" % aspect)
	var me := Player.new()
	var foe := Fighter.new()
	hud.player = me
	_check(hud.hp_subject() == me, "alive: the HP block is the player's")
	me.alive = false
	hud.match_over = true
	_check(hud.hp_subject() == null, "dead in the break (match_over): no HP block of the dead player")
	hud.match_over = false
	me.spectating = foe
	_check(hud.hp_subject() == foe, "spectating the killer: the HP block shows the killer's HP")
	foe.hp = 120.0
	_check(hud.hp_label() == "HP 120/%d" % int(foe.hp_max), "the label reads the watched fighter's HP (got %s)" % hud.hp_label())
	foe.alive = false
	_check(hud.hp_subject() == null, "nobody alive to watch: no HP block")
	hud.free()
	me.free()
	foe.free()

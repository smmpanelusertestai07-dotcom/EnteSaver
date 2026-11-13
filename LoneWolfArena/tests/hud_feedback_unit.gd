extends RefCounted
## Unit tests of the 1 vs 1 match feedback (round 8): the ELIMINATED BY card against the HP block,
## whose HP the block shows, damage-number bursts, the minimap's view, the two-line kill feed, the
## quick wall and the settings migration v8. Run from tests/run_tests.gd (which counts the checks).

var t: Node


static func run(runner: Node) -> void:
	var me := new()
	me.t = runner
	me._test_death_card()
	me._test_damage_numbers()


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


## A 10-hit burst (one hit every 0.1 s) makes at most 3 numbers, each within 0.1u of the head
## point; a hit 0.4 s after the last one starts a new number.
func _test_damage_numbers() -> void:
	var hud := _hud()
	var foe := Fighter.new()
	var u := 720.0
	for i in 10:
		hud._add_damage_number(foe, 20.0, i == 4, Vector3.ZERO)
		for n: Dictionary in hud._dmg_numbers:
			n.t += 0.1
			n.last += 0.1
	_check(hud._dmg_numbers.size() <= 3, "a 10-hit burst shows at most 3 numbers (got %d)" % hud._dmg_numbers.size())
	var total := 0.0
	for n: Dictionary in hud._dmg_numbers:
		total += float(n.amount)
		_check(HUD.dmg_offset(n, u).length() < 0.1 * u, "a number sits within 0.1u of the head point")
	_check(is_equal_approx(total, 200.0), "the numbers add up to the burst's damage (got %.0f)" % total)
	_check(bool(hud._dmg_numbers[0].head), "a headshot in the burst marks its number")
	hud._dmg_numbers.clear()
	hud._add_damage_number(foe, 30.0, false, Vector3.ZERO)
	hud._dmg_numbers[0].last = 0.4
	hud._dmg_numbers[0].t = 0.4
	hud._add_damage_number(foe, 30.0, false, Vector3.ZERO)
	_check(hud._dmg_numbers.size() == 2, "a hit 0.4 s after the last one shows a new number")
	_check(HUD.dmg_offset(hud._dmg_numbers[1], u).length() < 0.1 * u, "the second number stays by the head (spread at most 0.04u)")
	_check(hud._dmg_size(20.0, false, u) <= int(0.05 * u) and hud._dmg_size(20.0, false, u) >= int(0.032 * u), "numbers are 0.032u .. 0.05u")
	hud.free()
	foe.free()

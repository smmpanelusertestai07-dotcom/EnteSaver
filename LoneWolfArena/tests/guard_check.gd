extends Node
## Anti-tamper flow check (headless is fine; run it in its own process, it leaves a flag set):
##   godot --headless --path . -- --autotest=script:res://tests/guard_check.gd
## A detection raised before the match (e.g. a speed hack switched on in the lobby) must void
## the next match: INTEGRITY CHECK FAILED, results marked invalid, no XP.


func run(at: Node) -> int:
	var xp_before := int(Game.profile.get("xp", 0))
	Guard.flag("speed")
	Game.goto_arena()
	await at.wait(5.0)
	var arena: Node = get_tree().current_scene
	var bad := 0
	if arena.get("_invalid") != true:
		bad += 1
		at.log_line("FAIL match not voided by an earlier speed flag")
	if arena.get("_result_shown") != true:
		bad += 1
		at.log_line("FAIL results not shown for the voided match")
	if int(Game.profile.get("xp", 0)) != xp_before:
		bad += 1
		at.log_line("FAIL a voided match gave XP")
	at.log_line("GUARD CHECK DONE bad=%d" % bad)
	return bad

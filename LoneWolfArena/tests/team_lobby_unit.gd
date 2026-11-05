extends RefCounted
## STEP-0 STUB. Unit tests of DUO / SQUAD, WP-B1: lobby, START routing, TEAM invites, team search, records.
## Run from tests/run_tests.gd (which counts the checks); the owner package fills it in.

var t: Node


static func run(runner: Node) -> void:
	var me := new()
	me.t = runner


func _check(cond: bool, what: String) -> void:
	t.call("_check", cond, what)

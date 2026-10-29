extends Node
## Example screenshot tour: godot --path . -- --autotest=script:res://tests/shots_example.gd --shots=/abs/dir
## run(at) gets the autotest node with helpers: shot(name), wait(s), touch(), drag(),
## log_line(), wait_for_phase(arena, phase). Return an exit code.


func run(at: Node) -> int:
	await at.wait(2.0)
	await at.shot("ex_lobby")
	Game.goto_arena()
	await at.wait(1.5)
	await at.shot("ex_prep")
	return 0

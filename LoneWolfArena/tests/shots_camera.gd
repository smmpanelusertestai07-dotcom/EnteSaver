extends Node
## Camera sequence for visual QA of the free look with no button (the default camera):
##   tools/qa/capture.sh /tmp/cam 1280x720 script:res://tests/shots_camera.gd
## In a match, standing still: a drag takes the camera round the character in 45 degree steps to
## its face and on round to its back; FIRE turns the body to the crosshair; the stick runs away
## from the camera; a drag while running turns the run (the back stays to the camera). Real touch
## drags on the HUD's free area, so the HUD's routing is in the pictures too.

var at: Node


func run(autotest: Node) -> int:
	at = autotest
	Game.goto_arena()
	await at.wait(1.0)
	var arena: Node = get_tree().current_scene
	await at.wait_for_phase(arena, 1, 40.0)
	var p: Player = arena.get("player")
	if p == null:
		return 1
	for f: Fighter in arena.get("fighters"):
		if f != p:
			f.frozen = true
	p.global_position = arena.call("closest_nav_point", arena.get("zone_center"))
	await at.wait(1.0)
	var vs := get_viewport().get_visible_rect().size
	var px_per_deg := vs.y / 130.0 / (maxf(float(Game.settings.sens_general), 1.0) / 100.0)
	var from := Vector2(vs.x * 0.62, vs.y * 0.42)          # the free area right of centre
	await at.shot("cam_00_behind")
	for step in 8:
		await _drag(from, 45.0 * px_per_deg)
		await at.wait(0.35)
		await at.shot("cam_%02d_orbit_%d" % [step + 1, (step + 1) * 45])
		if step == 3:
			# the face: also from a little lower and higher (a vertical drag)
			await _drag(from, 0.0, -12.0 * px_per_deg)
			await at.wait(0.3)
			await at.shot("cam_04b_face_low")
			await _drag(from, 0.0, 24.0 * px_per_deg)
			await at.wait(0.3)
			await at.shot("cam_04c_face_high")
			await _drag(from, 0.0, -12.0 * px_per_deg)
	await _drag(from, 135.0 * px_per_deg)                   # to the side again
	await at.wait(0.4)
	await at.shot("cam_10_side_again")
	p.set_firing(true)
	await at.wait(0.05)
	await at.shot("cam_11_fire_turns_body")
	p.set_firing(false)
	await at.wait(0.5)
	await _drag(from, 120.0 * px_per_deg)
	await at.wait(0.3)
	await at.shot("cam_12_turned_away")
	var hud: Node = arena.get("hud")
	hud.process_mode = Node.PROCESS_MODE_DISABLED            # hold the stick forward by hand
	for i in 12:
		p.move_dir = Vector2(0, 1)
		await get_tree().physics_frame
	await at.shot("cam_13_stick_turns_back")
	for i in 30:
		p.move_dir = Vector2(0, 1)
		await get_tree().physics_frame
	await at.shot("cam_14_running")
	for i in 6:
		p.move_dir = Vector2(0, 1)
		p.add_look(Vector2(-10.0 * px_per_deg, 0.0))
		await get_tree().physics_frame
	for i in 10:
		p.move_dir = Vector2(0, 1)
		await get_tree().physics_frame
	await at.shot("cam_15_running_drag_turns_run")
	p.move_dir = Vector2.ZERO
	hud.process_mode = Node.PROCESS_MODE_INHERIT
	at.log_line("CAMERA SHOTS DONE")
	return 0


## A one-finger drag on the HUD's free area: dx / dy pixels in a few touch events (left = the
## camera goes round to the character's right).
func _drag(from: Vector2, dx: float, dy := 0.0) -> void:
	var steps := 8
	var pos := from
	at.touch(5, at._win(pos), true)
	await get_tree().process_frame
	for i in steps:
		var rel := Vector2(-dx, dy) / steps
		pos += rel
		at.drag(5, at._win(pos), rel)
		await get_tree().process_frame
	at.touch(5, at._win(pos), false)
	await get_tree().process_frame

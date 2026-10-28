extends Node
## Pose sheet for visual QA of the character clips with the held gun (and the medkit in heal):
##   tools/qa/capture.sh /tmp/poses 1280x720 script:res://tests/shots_poses.gd
## Each shot shows one clip frame from the side and from the front-left.

const POSES_ALL := [
	["idle", 0.0], ["reload", 0.45], ["reload", 1.0], ["heal", 0.3], ["throw", 0.3], ["throw", 0.43],
	["swap", 0.25], ["hit_react", 0.06], ["pump", 0.18], ["prone_idle", 0.0], ["prone_fwd", 0.4], ["run_fwd", 0.2],
]
## LW_POSES=heal,reload limits the sheet to those clips (quicker iterations).
var POSES: Array = []


func _ready() -> void:
	var only := OS.get_environment("LW_POSES")
	for p in POSES_ALL:
		if only == "" or String(p[0]) in only.split(",") or p[0] == "idle":
			POSES.append(p)


func run(at: Node) -> int:
	# Clean stage: drop the lobby (the autotest node lives under the Game autoload).
	get_tree().current_scene.queue_free()
	await at.wait(0.2)
	var world := Node3D.new()
	add_child(world)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.32, 0.35, 0.4)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.7, 0.7, 0.75)
	world.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	world.add_child(sun)
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(8, 8)
	floor_mi.mesh = pm
	world.add_child(floor_mi)
	var models: Array[CharacterModel] = []
	var cams: Array[Camera3D] = []
	for i in 2:
		var m := CharacterModel.new()
		world.add_child(m)
		m.setup("default", true)
		m.equip_weapon("weapon_ar")
		m.position = Vector3(-0.9 + 1.8 * i, 0, 0)
		models.append(m)
	var cam := Camera3D.new()
	world.add_child(cam)
	cam.current = true
	cam.fov = 40
	# left model faces screen-left (side view), right model faces the camera's front-left
	models[0].rotation.y = PI * 0.5
	models[1].rotation.y = PI * 0.75
	for pose in POSES:
		var clip: String = pose[0]
		var t: float = pose[1]
		for m in models:
			if not m.anim.has_animation(clip):
				continue
			m.set_aim(0.0, -m.global_basis.z)
			m.tree.active = false
			m.anim.play(clip)
			m.anim.seek(t, true)
			m.anim.pause()
			# as in the game: the gun follows the hand in these clips and is put away to throw
			m._hand_follow = 1.0 if clip in ["reload", "heal", "swap", "hit_react"] else 0.0
			m.weapon_node.visible = clip != "throw"
			if m._kit == null and clip == "heal":
				m._build_kit()
			if m._kit:
				m._kit.visible = clip == "heal"
		var low := clip.begins_with("prone")
		cam.position = Vector3(0, 0.7 if low else 1.15, 4.0 if low else 4.4)
		cam.look_at(Vector3(0, 0.25 if low else 0.95, 0))
		await at.wait(0.3)
		await at.shot("pose_%s_%02d" % [clip, int(t * 100)])
		if clip == "heal":
			var front := models[1].global_position - models[1].global_basis.z * 1.3 + Vector3(0.3, 1.25, 0)
			cam.position = front
			cam.look_at(models[1].global_position + Vector3(0, 1.0, 0))
			await at.wait(0.2)
			await at.shot("pose_heal_close")
	return 0

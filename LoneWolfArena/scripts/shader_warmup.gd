class_name ShaderWarmup
extends SubViewport
## Builds the arena (MapBuilder: its floor, walls, props, lights and environment, and a fighter) once in a tiny
## off-screen viewport of its own world while the boot screen is up (Loading), draws it for a few
## frames from a player's spawn and from above, then frees it. The renderer (Compatibility) compiles
## a material's shaders the first time it is drawn: on a phone's first match that froze the arena's
## first frames for seconds. The materials stay referenced (`kept`), so their compiled shaders are
## still there when the real arena builds the same ones. Automated runs skip it (Loading).

const FRAMES := 4                 # frames drawn from each camera
static var kept: Array = []       # the warmed materials (their shaders stay compiled)

var _cam: Camera3D
var _map: MapBuilder
var _frames := 0
var _t0 := 0


func _ready() -> void:
	name = "ShaderWarmup"
	_t0 = Time.get_ticks_msec()
	own_world_3d = true
	size = Vector2i(160, 90)
	render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var root := Node3D.new()
	add_child(root)
	_map = MapBuilder.new()
	_map.build(root)
	_cam = Camera3D.new()
	_cam.fov = 75.0
	add_child(_cam)
	_cam.global_position = _map.spawn_a + Vector3(0, 1.6, 0)
	_cam.look_at(_map.zone_center + Vector3(0, 1.0, 0), Vector3.UP)
	_cam.current = true
	# A fighter (outfit and gun) in front of that camera, as a match shows one at once.
	var model := CharacterModel.new()
	root.add_child(model)
	model.setup(String(Game.profile.get("bundle", "default")))
	model.global_position = _map.spawn_a + (_map.zone_center - _map.spawn_a).normalized() * 3.0


func _process(_delta: float) -> void:
	_frames += 1
	if _frames == FRAMES:
		_cam.global_position = _map.spawn_b + Vector3(0, 1.6, 0)
		_cam.look_at(_map.zone_center + Vector3(0, 1.0, 0), Vector3.UP)
	elif _frames == FRAMES * 2:
		_cam.global_transform = Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(0, 30.0, 0))
	elif _frames >= FRAMES * 3:
		_keep_materials(self)
		Game.mark("shader warm-up: %d materials in %.1f s" % [kept.size(), (Time.get_ticks_msec() - _t0) / 1000.0])
		set_process(false)
		queue_free()


static func _keep_materials(n: Node) -> void:
	if n is GeometryInstance3D:
		var g := n as GeometryInstance3D
		for m: Material in [g.material_override, g.material_overlay]:
			if m and not kept.has(m):
				kept.append(m)
		if n is MeshInstance3D and (n as MeshInstance3D).mesh:
			var mi := n as MeshInstance3D
			for i in mi.mesh.get_surface_count():
				for m: Material in [mi.get_surface_override_material(i), mi.mesh.surface_get_material(i)]:
					if m and not kept.has(m):
						kept.append(m)
	for c in n.get_children():
		_keep_materials(c)

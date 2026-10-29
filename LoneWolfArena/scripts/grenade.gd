class_name Grenade
extends RigidBody3D
## Thrown frag grenade with a fuse; damages fighters in radius with line of sight.

const FUSE := 3.0
const RADIUS := 6.0
const MAX_DAMAGE := 150.0     # at the centre
const EDGE_DAMAGE := 60.0     # at 5 m, then fading out to RADIUS
const MODEL := "res://assets/props/grenade.glb"

var thrower: Fighter
var cosmetic := false      # a Wi-Fi copy of the other phone's grenade: it hurts no fighter here
var _fuse := FUSE
var _bounced := false


func _ready() -> void:
	collision_layer = 16
	collision_mask = Fighter.LAYER_WORLD | Fighter.LAYER_SHIELD
	mass = 0.45
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = 2
	var pm := PhysicsMaterial.new()
	pm.bounce = 0.35
	pm.friction = 0.8
	physics_material_override = pm
	var cs := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = 0.07
	cs.shape = sh
	add_child(cs)
	if ResourceLoader.exists(MODEL):
		add_child((load(MODEL) as PackedScene).instantiate())
	else:
		var mi := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.07
		sm.height = 0.14
		mi.mesh = sm
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.25, 0.3, 0.2)
		mi.material_override = mat
		add_child(mi)
	body_entered.connect(func(_b: Node) -> void:
		if not _bounced:
			_bounced = true
			Audio.play_at("land", global_position, -14.0, 1.6))
	angular_velocity = Vector3(randf_range(-8, 8), randf_range(-8, 8), randf_range(-8, 8))


func _physics_process(delta: float) -> void:
	_fuse -= delta
	if _fuse <= 0.0:
		_explode()


func _explode() -> void:
	set_physics_process(false)
	var pos := global_position + Vector3.UP * 0.25
	Effects.explosion(self, pos)
	Audio.play_at("explosion", pos, 4.0, 1.0, 140.0)
	var space := get_world_3d().direct_space_state
	var scene := get_tree().current_scene
	if scene and scene.has_method("shake_camera"):
		scene.shake_camera(pos, 1.0)
	for node in get_tree().get_nodes_in_group("fighters"):
		var f := node as Fighter
		if f == null or not f.alive or cosmetic:
			continue
		var target := f.chest_position()
		var d := pos.distance_to(target)
		if d > RADIUS:
			continue
		var q := PhysicsRayQueryParameters3D.create(pos, target, Fighter.MASK_SIGHT)
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			continue
		var dmg := lerpf(MAX_DAMAGE, EDGE_DAMAGE, clampf(d / 5.0, 0.0, 1.0)) * clampf((RADIUS - d) / 1.0, 0.0, 1.0)
		var dealt := f.take_damage(dmg, "body", thrower, pos)
		if thrower and is_instance_valid(thrower) and f != thrower and dealt > 0.0:
			thrower.stats.damage += dealt
			thrower.hit_landed.emit(f, dealt, false, target, not f.alive)
			if not f.alive:
				thrower.stats.kills += 1
	for w in get_tree().get_nodes_in_group("shield_walls"):
		if (w as Node3D).global_position.distance_to(pos) < RADIUS:
			w.take_explosion(250.0)
	queue_free()

extends Node
## Loads every script so compile errors surface with autoloads available.
func _ready() -> void:
	var bad := 0
	for dir in ["res://autoload", "res://scripts"]:
		for f in DirAccess.get_files_at(dir):
			if f.ends_with(".gd"):
				var s: Script = load(dir.path_join(f))
				if s == null or not s.can_instantiate():
					print("CHECK FAIL: ", f)
					bad += 1
	print("CHECK DONE bad=", bad)
	get_tree().quit(bad)

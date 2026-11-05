class_name CacheCleaner
extends RefCounted
## CLEAR CACHE (SETTINGS > BASIC): deletes what the game can rebuild or no longer needs, never a
## save. Under user:// that is
##  - shader_cache/ and vulkan/: the engine's compiled shaders and pipelines (rebuilt when they are
##    needed again: the next match may stutter for a moment while they compile);
##  - logs/: the engine's old log files (the current one, godot.log, stays);
##  - what the safe saves (Game.write_json) leave behind: "<save>.tmp" (a write cut short) and
##    "<save>.bak" (the save before the last one) once the save itself reads as whole JSON and is
##    at least as new as it.
## Never touched: profile.json, settings.json, hud_layout.json, the identity key
## (net_identity*.key) or any other file. Folders stay (the engine writes into them again).

const CACHE_DIRS := ["shader_cache", "vulkan"]
const LOG_DIR := "logs"
const CURRENT_LOG := "godot.log"


## What CLEAR CACHE would delete under `root` now: {"files": PackedStringArray, "bytes": int}.
static func scan(root := "user://") -> Dictionary:
	var files := PackedStringArray()
	for d: String in CACHE_DIRS:
		_collect(root.path_join(d), files)
	var logs := root.path_join(LOG_DIR)
	if DirAccess.dir_exists_absolute(logs):
		for f in DirAccess.get_files_at(logs):
			if f != CURRENT_LOG:
				files.append(logs.path_join(f))
	for path: String in [Game.SETTINGS_PATH, Game.PROFILE_PATH, Game.HUD_PATH]:
		var save := root.path_join(path.get_file())
		if FileAccess.file_exists(save + ".tmp"):
			files.append(save + ".tmp")
		if FileAccess.file_exists(save + ".bak") and _whole_json(save) \
				and FileAccess.get_modified_time(save) >= FileAccess.get_modified_time(save + ".bak"):
			files.append(save + ".bak")
	var bytes := 0
	for f in files:
		bytes += _size(f)
	return {"files": files, "bytes": bytes}


## Deletes what scan() finds; returns the bytes freed.
static func clear(root := "user://") -> int:
	var freed := 0
	for f: String in scan(root).files:
		var n := _size(f)
		if DirAccess.remove_absolute(f) == OK:
			freed += n
	return freed


## "0 B", "640 KB", "12.4 MB".
static func size_text(bytes: int) -> String:
	if bytes < 1024:
		return "%d B" % bytes
	if bytes < 1024 * 1024:
		return "%d KB" % ceili(bytes / 1024.0)
	return "%.1f MB" % (bytes / 1048576.0)


static func _collect(dir: String, files: PackedStringArray) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		files.append(dir.path_join(f))
	for sub in DirAccess.get_directories_at(dir):
		_collect(dir.path_join(sub), files)


static func _size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_length() if f else 0


## The save reads as a whole JSON object (its backup is then not needed).
static func _whole_json(path: String) -> bool:
	var json := JSON.new()
	return FileAccess.file_exists(path) and json.parse(FileAccess.get_file_as_string(path)) == OK and json.data is Dictionary

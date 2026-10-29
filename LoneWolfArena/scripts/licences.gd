class_name Licences
extends RefCounted
## The notices the shipped parts' licences ask for: Godot's MIT licence and its third-party
## components (read from the engine itself), the AndroidX and Kotlin libraries the Android
## template adds, the CC0 character assets and the fonts' SIL Open Font Licence (also shipped as
## assets/fonts/LICENSE.txt). The game has no credits screen: Game prints them to the system log
## (logcat on Android) at start, which Godot's licence guide accepts on Android and desktop.

const FONT_LICENCE := "res://assets/fonts/LICENSE.txt"


static func publish() -> void:
	print(text())


static func text() -> String:
	var out := PackedStringArray()
	out.append("LONE WOLF ARENA - an original game. Everything in it (character outfits and animations, guns, map, icons, sounds and music) was made for this game with the scripts in its source, except the parts credited below.")
	out.append("")
	out.append("CHARACTER - base body, skin, hair and clothes from the MakeHuman / MPFB2 asset packs, CC0 1.0 (public domain dedication), assembled, recoloured, rigged and animated for this game.")
	out.append("")
	out.append("FONTS - Rajdhani, Teko, Bebas Neue: SIL Open Font License 1.1.")
	if FileAccess.file_exists(FONT_LICENCE):
		out.append(FileAccess.get_file_as_string(FONT_LICENCE).strip_edges())
	out.append("")
	out.append("ENGINE - made with Godot Engine (godotengine.org).")
	out.append(Engine.get_license_text().strip_edges())
	out.append("")
	out.append("GODOT THIRD-PARTY COMPONENTS")
	for comp: Dictionary in Engine.get_copyright_info():
		var parts: Array = comp.get("parts", [])
		for part: Dictionary in parts:
			var who := PackedStringArray()
			for c in part.get("copyright", []):
				who.append(String(c))
			out.append("%s - %s (%s)" % [comp.get("name", ""), ", ".join(who), part.get("license", "")])
	out.append("")
	out.append("ANDROID LIBRARIES - the AndroidX (Jetpack) libraries, the Kotlin standard library with the JetBrains annotations, and Guava's ListenableFuture, all included by Godot's Android export template: Apache License 2.0 (text below).")
	out.append("")
	out.append("LICENCE TEXTS")
	var lic: Dictionary = Engine.get_license_info()
	for licence in lic:
		out.append(String(licence))
		out.append(String(lic[licence]).strip_edges())
		out.append("")
	return "\n".join(out)

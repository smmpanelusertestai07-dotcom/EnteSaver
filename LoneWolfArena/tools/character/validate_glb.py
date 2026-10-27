"""Re-import character.glb into an empty scene and report meshes/triangles, bones, animations,
textures (also parsed straight from the GLB JSON chunk). Writes WORK/validation.json"""
import os
import sys
import json
import struct

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
import char_config as CFG

path = os.path.join(CFG.OUT_DIR, "character.glb")
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.context.scene.render.fps = 30
bpy.ops.import_scene.gltf(filepath=path)

rep = {"file": path, "size_mb": round(os.path.getsize(path) / 1e6, 3)}
meshes = [o for o in bpy.data.objects if o.type == 'MESH']
rep["meshes"] = {}
for o in sorted(meshes, key=lambda o: o.name):
    me = o.data
    me.calc_loop_triangles()
    rep["meshes"][o.name] = {"triangles": len(me.loop_triangles), "verts": len(me.vertices),
                             "materials": [m.name for m in me.materials if m],
                             "skinned": any(m.type == 'ARMATURE' for m in o.modifiers),
                             "shape_keys": me.shape_keys is not None}
arms = [o for o in bpy.data.objects if o.type == 'ARMATURE']
rep["armatures"] = len(arms)
a = arms[0]
rep["bone_count"] = len(a.data.bones)
rep["bones"] = [b.name for b in a.data.bones]
rep["animations"] = {}
for act in bpy.data.actions:
    fr = act.frame_range
    rep["animations"][act.name] = [round(fr[0], 2), round(fr[1], 2)]
# bounds in Blender space after import (importer converts Y-up back to Z-up)
import numpy as np
allco = []
for o in meshes:
    M = np.array(o.matrix_world)
    co = np.array([v.co[:] for v in o.data.vertices])
    allco.append(co @ M[:3, :3].T + M[:3, 3])
allco = np.concatenate(allco)
rep["bounds_min"] = allco.min(0).round(3).tolist()
rep["bounds_max"] = allco.max(0).round(3).tolist()

# raw GLB JSON
with open(path, "rb") as f:
    data = f.read()
magic, ver, length = struct.unpack("<III", data[:12])
clen, ctype = struct.unpack("<II", data[12:20])
gj = json.loads(data[20:20 + clen])
bin_off = 20 + clen + 8
imgs = []
from PIL import Image
import io
for i, im in enumerate(gj.get("images", [])):
    bv = gj["bufferViews"][im["bufferView"]]
    raw = data[bin_off + bv.get("byteOffset", 0): bin_off + bv.get("byteOffset", 0) + bv["byteLength"]]
    pil = Image.open(io.BytesIO(raw))
    imgs.append({"name": im.get("name"), "mime": im.get("mimeType"), "size": list(pil.size),
                 "kb": round(len(raw) / 1024, 1)})
rep["textures"] = imgs
rep["texture_count"] = len(imgs)
rep["gltf_animations"] = []
for an in gj.get("animations", []):
    tmax = 0.0
    for smp in an["samplers"]:
        acc = gj["accessors"][smp["input"]]
        tmax = max(tmax, acc["max"][0])
    rep["gltf_animations"].append({"name": an["name"], "duration_s": round(tmax, 4), "channels": len(an["channels"])})
rep["gltf_meshes_with_morphs"] = [m["name"] for m in gj["meshes"] if any("targets" in p for p in m["primitives"])]
rep["materials"] = [{"name": m["name"], "alphaMode": m.get("alphaMode", "OPAQUE"), "doubleSided": m.get("doubleSided", False)}
                    for m in gj.get("materials", [])]
rep["skins"] = len(gj.get("skins", []))
rep["skin_joints"] = len(gj["skins"][0]["joints"]) if gj.get("skins") else 0

print(json.dumps(rep, indent=1))
with open(os.path.join(CFG.WORK, "validation.json"), "w") as f:
    json.dump(rep, f, indent=1)

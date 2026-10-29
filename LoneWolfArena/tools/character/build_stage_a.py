"""Stage A: build the MPFB human (macros tuned to target height), game_engine rig,
eyes/eyebrows/eyelashes/hair and every outfit piece of every bundle, all fitted and
weighted by MPFB. Saves WORK/stage_a.blend."""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
import numpy as np
import mpfb_boot
import char_config as CFG

t0 = time.time()
S = mpfb_boot.boot(verbose=True)
os.makedirs(CFG.WORK, exist_ok=True)


def clear_scene():
    for ob in list(bpy.data.objects):
        bpy.data.objects.remove(ob, do_unlink=True)
    for coll in (bpy.data.meshes, bpy.data.armatures, bpy.data.materials, bpy.data.images):
        for item in list(coll):
            if item.users == 0:
                coll.remove(item)


def body_height(bm):
    dg = bpy.context.evaluated_depsgraph_get()
    ev = bm.evaluated_get(dg)
    me = ev.to_mesh()
    co = np.empty(len(me.vertices) * 3)
    me.vertices.foreach_get("co", co)
    ev.to_mesh_clear()
    co = co.reshape(-1, 3)
    return co[:, 2].max() - co[:, 2].min()


def make_human(height_macro):
    macro = dict(CFG.MACRO)
    macro["race"] = dict(CFG.MACRO["race"])
    macro["height"] = height_macro
    bm = S.HumanService.create_human(mask_helpers=True, detailed_helpers=True, extra_vertex_groups=True,
                                     feet_on_ground=True, scale=0.1, macro_detail_dict=macro)
    for rel, w in CFG.EXTRA_TARGETS:
        full = S.LocationService.get_mpfb_data(os.path.join("targets", rel + ".target.gz"))
        S.TargetService.load_target(bm, full, weight=w)
    if CFG.EXTRA_TARGETS:
        # re-ground the feet after detail targets
        pass
    return bm


clear_scene()
# --- secant search on the height macro to hit TARGET_HEIGHT
h_lo, h_hi = 0.3, 0.7
vals = {}
for h in (h_lo, h_hi):
    bm = make_human(h)
    vals[h] = body_height(bm)
    bpy.data.objects.remove(bm, do_unlink=True)
h = h_lo + (CFG.TARGET_HEIGHT - vals[h_lo]) * (h_hi - h_lo) / (vals[h_hi] - vals[h_lo])
for it in range(4):
    bm = make_human(h)
    cur = body_height(bm)
    print("height macro %.4f -> %.4f m" % (h, cur))
    if abs(cur - CFG.TARGET_HEIGHT) < 0.003:
        break
    bpy.data.objects.remove(bm, do_unlink=True)
    vals[h] = cur
    ks = sorted(vals.keys(), key=lambda k: abs(vals[k] - CFG.TARGET_HEIGHT))[:2]
    a, b = ks
    h = a + (CFG.TARGET_HEIGHT - vals[a]) * (b - a) / (vals[b] - vals[a])
HEIGHT_MACRO = h
print("final height macro", HEIGHT_MACRO, "height", body_height(bm))

# re-ground (detail targets may have moved the soles)
dg = bpy.context.evaluated_depsgraph_get()
bm.name = "Human"
basemesh = bm

rig = S.HumanService.add_builtin_rig(basemesh, "game_engine", import_weights=True)
rig.name = "Armature"
rig.data.name = "Armature"
print("rig bones", len(rig.data.bones))

# --- bodyparts
names = {"Eyes": "Eyes", "Eyebrows": "Eyebrows", "Eyelashes": "Eyelashes", "Hair": "Hair_Default"}
for atype, path in CFG.BODYPARTS.items():
    ob = S.HumanService.add_mhclo_asset(path, basemesh, asset_type=atype, subdiv_levels=0, material_type="MAKESKIN")
    ob.name = names[atype]
    ob.data.name = ob.name      # the mesh keeps our name, not the upstream asset's (it ships in the GLB)
    ob["mhclo"] = path
    print("added", ob.name, len(ob.data.polygons))

# --- clothes for every bundle
for bid, disp, parts in CFG.BUNDLES:
    for part, path in parts:
        ob = S.HumanService.add_mhclo_asset(path, basemesh, asset_type="Clothes", subdiv_levels=0, material_type="MAKESKIN")
        ob.name = "Outfit_%s_%s" % (bid, part)
        ob.data.name = ob.name
        ob["mhclo"] = path
        ob["bundle"] = bid
        ob["part"] = part
        print("added", ob.name, len(ob.data.polygons), "faces")

# remove the delete-group mask modifiers from the body (game toggles body parts instead)
for m in list(basemesh.modifiers):
    if m.type == 'MASK' and m.name != "Hide helpers":
        basemesh.modifiers.remove(m)

basemesh["height_macro"] = HEIGHT_MACRO
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(CFG.WORK, "stage_a.blend"))
print("STAGE A DONE in %.1fs" % (time.time() - t0))

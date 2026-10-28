"""Close-up render of a GLB: blender -b --python closeup.py -- name cx cy cz size az el out.png  (blender coords)"""
import bpy, sys, math, os
from mathutils import Vector
A = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else sys.argv[1:]
name, cx, cy, cz, size, az, el, out = A[0], *map(float, A[1:7]), A[7]
bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene
w = bpy.data.worlds.new('W'); sc.world = w; w.use_nodes = True
w.node_tree.nodes['Background'].inputs[0].default_value = (0.42, 0.42, 0.42, 1)
sc.view_settings.view_transform = 'Standard'
sc.render.engine = 'CYCLES'; sc.cycles.samples = 32; sc.cycles.device = 'CPU'
sc.render.resolution_x = 960; sc.render.resolution_y = 720
sun = bpy.data.lights.new('Sun', 'SUN'); sun.energy = 3.2; sun.angle = math.radians(4)
so = bpy.data.objects.new('Sun', sun); so.rotation_euler = (math.radians(40), 0, math.radians(35)); sc.collection.objects.link(so)
bpy.ops.import_scene.gltf(filepath=os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'assets', 'props', name + '.glb'))
cam_d = bpy.data.cameras.new('C'); cam_d.type = 'ORTHO'; cam_d.ortho_scale = size; cam_d.clip_start = 0.001; cam_d.clip_end = 5000
cam = bpy.data.objects.new('C', cam_d); sc.collection.objects.link(cam); sc.camera = cam
a, e = math.radians(az), math.radians(el)
d = Vector((math.sin(a) * math.cos(e), math.cos(a) * math.cos(e), math.sin(e)))
c = Vector((cx, cy, cz))
cam.location = c + d * max(size * 4, 5)
cam.rotation_euler = (c - cam.location).to_track_quat('-Z', 'Y').to_euler()
sc.render.filepath = out
bpy.ops.render.render(write_still=True)

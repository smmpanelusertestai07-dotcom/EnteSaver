"""Parse every shipped prop GLB in assets/props directly (no Blender) and write the developer report
tools/props/manifest.json (outside res://: the game does not read it and it must not ship).
glTF axes == Godot axes (Y up, -Z forward), so values are reported as-is."""
import json, struct, os, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
PROPS = os.path.normpath(os.path.join(HERE, '..', '..', 'assets', 'props'))
OUT = os.path.join(HERE, 'manifest.json')
# Triangle budgets, the same as each build_*.py passes to report().
BUDGET = {'weapon_ar': 3000, 'weapon_smg': 2000, 'weapon_sg': 3000, 'weapon_pistol': 1200, 'weapon_sniper': 3000,
          'medkit': 600, 'grenade': 500, 'shield_wall': 2000,
          'container': 2000, 'container_40': 3600, 'container_open': 3200, 'crate': 400, 'wall_bay': 1600,
          'wall_column': 120, 'rollup_door': 900, 'roof_truss': 1600, 'lamp_tube': 260, 'barrel': 360,
          'pallet': 320, 'bollard': 280, 'fire_cabinet': 700}
ORDER = list(BUDGET.keys())
COMP = {5120: ('b', 1), 5121: ('B', 1), 5122: ('h', 2), 5123: ('H', 2), 5125: ('I', 4), 5126: ('f', 4)}
NCOMP = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16}


def load_glb(path):
    data = open(path, 'rb').read()
    magic, ver, length = struct.unpack_from('<4sII', data, 0)
    assert magic == b'glTF' and ver == 2
    off = 12
    js, binc = None, None
    while off < length:
        clen, ctype = struct.unpack_from('<II', data, off)
        chunk = data[off + 8: off + 8 + clen]
        if ctype == 0x4E4F534A:
            js = json.loads(chunk)
        elif ctype == 0x004E4942:
            binc = chunk
        off += 8 + clen
    return js, binc


def accessor(js, binc, i):
    a = js['accessors'][i]
    bv = js['bufferViews'][a['bufferView']]
    fmt, size = COMP[a['componentType']]
    n = NCOMP[a['type']]
    start = bv.get('byteOffset', 0) + a.get('byteOffset', 0)
    stride = bv.get('byteStride', 0) or size * n
    arr = np.frombuffer(binc, dtype=np.dtype(fmt).newbyteorder('<'), count=a['count'] * stride // size, offset=start)
    arr = arr.reshape(a['count'], stride // size)[:, :n]
    return arr


def quat_mat(q):
    x, y, z, w = q
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def local_matrix(node):
    if 'matrix' in node:
        return np.array(node['matrix'], dtype=float).reshape(4, 4).T
    M = np.eye(4)
    S = np.diag(node.get('scale', [1, 1, 1]))
    R = quat_mat(node.get('rotation', [0, 0, 0, 1]))
    M[:3, :3] = R @ S
    M[:3, 3] = node.get('translation', [0, 0, 0])
    return M


def r(v, n=4):
    return [round(float(x), n) for x in v]


def analyse(name):
    js, binc = load_glb(os.path.join(PROPS, name + '.glb'))
    nodes = js['nodes']
    scene = js['scenes'][js.get('scene', 0)]
    world = {}

    def walk(i, parent):
        M = parent @ local_matrix(nodes[i])
        world[i] = M
        for c in nodes[i].get('children', []):
            walk(c, M)
    for i in scene['nodes']:
        walk(i, np.eye(4))
    pts, tris, mats, empties, mesh_nodes, transforms_identity = [], 0, [], {}, [], True
    for i, M in world.items():
        nd = nodes[i]
        if not np.allclose(local_matrix(nd)[:3, :3], np.eye(3)):
            transforms_identity = False
        if 'mesh' in nd:
            mesh_nodes.append(nd.get('name'))
            if not np.allclose(M, np.eye(4)):
                transforms_identity = False
            for prim in js['meshes'][nd['mesh']]['primitives']:
                P = accessor(js, binc, prim['attributes']['POSITION']).astype(float)
                P = (M[:3, :3] @ P.T).T + M[:3, 3]
                pts.append(P)
                if 'indices' in prim:
                    tris += js['accessors'][prim['indices']]['count'] // 3
                else:
                    tris += len(P) // 3
                if 'material' in prim:
                    mats.append(js['materials'][prim['material']]['name'])
        else:
            empties[nd.get('name')] = r(M[:3, 3])
    P = np.concatenate(pts)
    mn, mx = P.min(0), P.max(0)
    matinfo = {}
    for m in js.get('materials', []):
        pbr = m.get('pbrMetallicRoughness', {})
        bc = pbr.get('baseColorFactor', [1, 1, 1, 1])
        srgb = [((c * 12.92) if c <= 0.0031308 else (1.055 * c ** (1 / 2.4) - 0.055)) for c in bc[:3]]
        info = dict(base_color_srgb='#%02x%02x%02x' % tuple(int(round(max(0, min(1, c)) * 255)) for c in srgb),
                    metallic=round(pbr.get('metallicFactor', 1.0), 3), roughness=round(pbr.get('roughnessFactor', 1.0), 3))
        if 'emissiveFactor' in m:
            info['emissive'] = r(m['emissiveFactor'], 3)
        matinfo[m['name']] = info
    has_uv = all('TEXCOORD_0' in p['attributes'] for mm in js['meshes'] for p in mm['primitives'])
    has_n = all('NORMAL' in p['attributes'] for mm in js['meshes'] for p in mm['primitives'])
    out = dict(triangles=int(tris), triangle_budget=BUDGET[name], within_budget=tris <= BUDGET[name],
               materials=sorted(set(mats)), material_params=matinfo,
               bbox=dict(size=r(mx - mn), center=r((mx + mn) / 2), min=r(mn), max=r(mx)),
               mesh_nodes=mesh_nodes, has_normals=has_n, has_uv0=has_uv, node_transforms_identity=transforms_identity)
    if empties:
        out['marker_nodes'] = empties
    return out


def main():
    manifest = dict(
        description='Arena props & weapons for the Godot 4 1v1 Lone Wolf shooter. All values in meters, Godot axes '
                    '(+Y up, -Z forward, +X right) = glTF axes. Blender (x,y,z) -> Godot (x, z, -y).',
        conventions=dict(
            weapons='Origin = right-hand pistol-grip point (centre of the grip). Barrel points -Z (Godot forward), top +Y. '
                    'Marker nodes: "Muzzle" = barrel tip; "LeftHand" = support-hand point (AR: centre of handguard just '
                    'behind the hand-stop; SMG: front grip; SG: centre of the pump; pistol: on the grip, offset 1.2 cm to '
                    'the left/1 cm down; sniper: forend).',
            props='Origin at bottom centre (Y=0 is the floor) unless noted: lamp_tube hangs from its ceiling hook (origin; '
                  'the fixture reaches down to Y=-1.2), roof_truss = centre of the bottom chord underside, rollup_door and '
                  'fire_cabinet = bottom centre on the wall (mounting) plane. Front faces -Z (Blender +Y) where it matters: '
                  'shield convex side, wall_bay inner face, rollup_door, fire_cabinet. Container doors are at +X '
                  '(container_open: open at both ends, door leaves folded back against the side walls).',
            uv='UV0 = world-space box projection, 1 UV unit = 1 m, for tileable textures by material name.',
            shading='Smooth shading with sharp edges > ~60 deg and weighted (face-area) custom normals; bevels applied.'),
        assets={})
    for name in ORDER:
        info = analyse(name)
        manifest['assets'][name + '.glb'] = info
        flag = 'ok' if info['within_budget'] else 'OVER'
        print(f"{name:14s} tris={info['triangles']:5d}/{info['triangle_budget']:<5d} {flag}  size={info['bbox']['size']} "
              f"center={info['bbox']['center']} mats={info['materials']} markers={info.get('marker_nodes', {})}")
    unlisted = sorted(f[:-4] for f in os.listdir(PROPS) if f.endswith('.glb') and f[:-4] not in BUDGET)
    if unlisted:
        print('WARNING: GLBs in assets/props not listed in BUDGET (stale, or a new prop to add here):', ', '.join(unlisted))
    json.dump(manifest, open(OUT, 'w'), indent=2)
    print('wrote', OUT)


main()

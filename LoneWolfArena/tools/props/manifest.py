"""Parse every GLB directly (no Blender) and write assets/props/manifest.json.
glTF axes == Godot axes (Y up, -Z forward), so values are reported as-is."""
import json, struct, os, sys
import numpy as np

PROPS = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'assets', 'props'))
META = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'meta')
BUDGET = {'weapon_ar': 3000, 'weapon_sg': 3000, 'weapon_pistol': 1200, 'medkit': 600, 'grenade': 500,
          'shield_wall': 2000, 'container': 2000, 'crate': 400, 'barrier': 300, 'sandbags': 1500,
          'tree_pine': 800, 'tree_round': 800, 'rock': 300, 'mountains': 6000, 'watchtower': 2000,
          'lamp_post': 400, 'house': 1500}
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
                    'behind the hand-stop; SG: centre of the pump; pistol: on the grip, offset 1.2 cm to the left/1 cm down).',
            props='Origin at bottom centre (Y=0 is the ground). Front faces -Z (Blender +Y) where it matters: lamp arm, '
                  'watchtower ladder, shield convex side, sandbag convex side, house front door. Container doors are at +X.',
            uv='UV0 = world-space box projection, 1 UV unit = 1 m (mountains: 1 UV unit = 10 m), for tileable textures by material name.',
            shading='Smooth shading with sharp edges > ~60 deg and weighted (face-area) custom normals; bevels applied.'),
        assets={})
    for name in ORDER:
        info = analyse(name)
        meta = os.path.join(META, name + '.json')
        if os.path.exists(meta):
            info.update(json.load(open(meta)))
        manifest['assets'][name + '.glb'] = info
        flag = 'ok' if info['within_budget'] else 'OVER'
        print(f"{name:14s} tris={info['triangles']:5d}/{info['triangle_budget']:<5d} {flag}  size={info['bbox']['size']} "
              f"center={info['bbox']['center']} mats={info['materials']} markers={info.get('marker_nodes', {})}")
    json.dump(manifest, open(os.path.join(PROPS, 'manifest.json'), 'w'), indent=2)
    print('wrote', os.path.join(PROPS, 'manifest.json'))


main()

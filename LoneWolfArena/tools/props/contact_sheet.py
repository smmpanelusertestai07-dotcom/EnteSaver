"""Assemble previews/<name>.png strips into previews/contact_sheet.png."""
from PIL import Image, ImageDraw
import os
P = '/root/work/assets/props/previews'
names = ['weapon_ar', 'weapon_sg', 'weapon_pistol', 'container', 'shield_wall', 'house', 'watchtower', 'medkit', 'grenade',
         'crate', 'barrier', 'sandbags', 'tree_pine', 'tree_round', 'rock', 'lamp_post', 'mountains']
cw = 1280
tiles = []
for n in names:
    im = Image.open(os.path.join(P, n + '.png')).convert('RGB')
    head = im.crop((0, 0, im.width, 26))
    body = im.crop((0, 26, min(im.width, 1280 * 2 if n.startswith('weapon') else 1280), im.height))
    body = body.resize((cw, int(body.height * cw / body.width)))
    t = Image.new('RGB', (cw, body.height + 26), (60, 60, 60))
    t.paste(head.crop((0, 0, cw, 26)), (0, 0)); t.paste(body, (0, 26))
    tiles.append(t)
cols = 2
rows = (len(tiles) + cols - 1) // cols
rh = [max(t.height for t in tiles[r * cols:(r + 1) * cols]) for r in range(rows)]
sheet = Image.new('RGB', (cols * cw, sum(rh)), (45, 45, 45))
y = 0
for r in range(rows):
    for c in range(cols):
        i = r * cols + c
        if i < len(tiles):
            sheet.paste(tiles[i], (c * cw, y))
    y += rh[r]
sheet = sheet.resize((sheet.width * 3 // 4, sheet.height * 3 // 4), Image.LANCZOS)
sheet.save(os.path.join(P, 'contact_sheet.png'))
print(sheet.size)

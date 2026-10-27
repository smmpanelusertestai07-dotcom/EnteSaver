"""Per-outfit-piece texture recolour recipes. recipe(object_name, mhmat_textures) returns a
dict with 'tex' (processed texture path) and/or 'color', plus roughness etc."""
import numpy as np
import textures as TX

WHITE = (0.93, 0.93, 0.91)
CHARCOAL = (0.16, 0.165, 0.175)
KHAKI = (0.70, 0.60, 0.42)
OLIVE = (0.25, 0.26, 0.14)
BROWN = (0.36, 0.22, 0.12)
TAN = (0.60, 0.48, 0.31)
BLACK = (0.055, 0.055, 0.06)
CYAN = (0.0, 0.85, 1.0)
GOLD = (0.82, 0.56, 0.10)


def _regions(a, rules, default=None, keep_detail=0.8):
    """rules: list of (mask, colour). Each region is luminance-tinted to its colour."""
    rgb = a[..., :3]
    lin = TX.srgb_to_lin(rgb)
    lum = TX.luminance(lin)
    out = rgb.copy()
    for mask, col in rules:
        m = mask > 0.5
        if not m.any():
            continue
        med = np.median(lum[m])
        rel = 1.0 + (np.clip(lum / max(med, 1e-4), 0.35, 1.8) - 1.0) * keep_detail
        tinted = TX.lin_to_srgb(TX.srgb_to_lin(np.array(col))[None, None, :] * rel[..., None])
        w = TX.soften(mask, 1.2)[..., None]
        out = out * (1 - w) + tinted * w
    a = a.copy()
    a[..., :3] = out
    return a


def recipe(name, texs):
    d = texs.get("diffuseTexture")
    key = name[len("Outfit_"):]
    if key == "default_Top":
        return {"color": WHITE + (1.0,), "rough": 0.85}
    if key == "default_Shorts":
        return {"tex": TX.save(TX.tint(d, CHARCOAL, keep_detail=0.9), key, 1024), "rough": 0.9, "double": True}
    if key == "default_Shoes":
        a = TX.load_rgba(d)
        g = TX.hue_mask(a, 70, 170, sat_min=0.3)
        a = _regions(a, [(g, (0.55, 0.57, 0.6))])
        return {"tex": TX.save(a, key, 512), "rough": 0.6}
    if key == "neon_Shoes":
        a = TX.load_rgba(d)
        g = TX.hue_mask(a, 70, 170, sat_min=0.3)
        a = _regions(a, [(g, CYAN)], keep_detail=0.4)
        return {"tex": TX.save(a, key, 512), "rough": 0.6}
    if key == "desert_Shirt":
        return {"tex": TX.save(TX.tint(d, KHAKI, keep_detail=0.9), key, 1024), "rough": 0.9}
    if key == "desert_Pants":
        return {"tex": TX.save(TX.tint(d, OLIVE, keep_detail=0.9), key, 1024), "rough": 0.9}
    if key == "desert_Boots":
        return {"tex": TX.save(TX.tint(d, BROWN, keep_detail=0.8), key, 512), "rough": 0.7}
    if key == "desert_Cap":
        return {"color": TAN + (1.0,), "rough": 0.9}
    if key == "neon_Jacket":
        a = TX.load_rgba(d)
        jacket = TX.hue_mask(a, 50, 170, sat_min=0.06, val_min=0.05)
        jeans = TX.hue_mask(a, 185, 250, sat_min=0.12, val_min=0.05)
        shirt = TX.hue_mask(a, 300, 30, sat_min=0.2, val_min=0.05)
        a = _regions(a, [(jacket, BLACK), (jeans, (0.10, 0.11, 0.14)), (shirt, CYAN)], keep_detail=0.7)
        return {"tex": TX.save(a, key, 1024), "rough": 0.75}
    if key == "neon_Mask":
        a = TX.load_rgba(d)
        blue = TX.hue_mask(a, 180, 260, sat_min=0.08, val_min=0.2)
        rest = 1.0 - blue
        a = _regions(a, [(blue, BLACK), (rest, CYAN)], keep_detail=0.3)
        return {"tex": TX.save(a, key, 256), "rough": 0.8, "double": True}
    if key == "shadow_Top":
        return {"tex": TX.save(TX.tint(d, (0.07, 0.07, 0.08), keep_detail=0.9), key, 1024), "rough": 0.95}
    if key == "shadow_Pants":
        return {"tex": TX.save(TX.tint(d, (0.07, 0.07, 0.075), keep_detail=0.9), key, 1024), "rough": 0.9}
    if key == "shadow_Boots":
        return {"tex": TX.save(TX.tint(d, (0.05, 0.05, 0.05), keep_detail=0.9), key, 512), "rough": 0.6}
    if key == "shadow_Helmet":
        return {"tex": TX.save(TX.tint(d, (0.09, 0.095, 0.085), keep_detail=0.7), key, 512), "rough": 0.7}
    if key == "shadow_Gloves":
        return {"tex": TX.save(TX.tint(d, (0.05, 0.05, 0.05), keep_detail=0.7), key, 512), "rough": 0.7}
    if key == "royal_Suit":
        a = TX.load_rgba(d)
        maroon = TX.hue_mask(a, 320, 25, sat_min=0.25, val_min=0.08)
        belt = TX.hue_mask(a, 25, 60, sat_min=0.35, val_min=0.1)
        cyan = TX.hue_mask(a, 160, 210, sat_min=0.3, val_min=0.2)
        cream = (TX.hue_mask(a, 0, 360, sat_min=0.0, val_min=0.55) * (1 - maroon) * (1 - belt) * (1 - cyan))
        a = _regions(a, [(cream, (0.95, 0.95, 0.94)), (maroon, GOLD), (belt, (0.95, 0.75, 0.3)),
                         (cyan, (1.0, 0.85, 0.45))], keep_detail=0.7)
        return {"tex": TX.save(a, key, 1024), "rough": 0.5, "metal": 0.0}
    if key == "royal_Shoes":
        a = TX.load_rgba(d)
        leather = TX.hue_mask(a, 5, 50, sat_min=0.25, val_min=0.05)
        a = _regions(a, [(leather, GOLD)], keep_detail=0.6)
        return {"tex": TX.save(a, key, 512), "rough": 0.35, "metal": 0.6}
    # fallback: keep original texture
    if d:
        return {"tex": TX.save(TX.load_rgba(d), key, 512)}
    return {"color": (0.5, 0.5, 0.5, 1.0)}

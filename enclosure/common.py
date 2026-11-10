"""Shared geometry for the DIBS nRF52 v21 enclosures (build123d).

Device frame: X, Y = KiCad board coordinates, Z = height from the skin face (see pcbdata.py).
The PCB F side (mic sound hole) faces the skin in every design.
"""
from build123d import Align, Box, Cone, Cylinder, Pos, RectangleRounded, extrude

import pcbdata

P = dict(
    # board (KiCad coordinates)
    board=(149.5, 99.5, 159.5, 109.5), board_r=0.5,
    mic_hole=(151.2, 104.6),                   # MK2 (ICS-41350, bottom port) 0.65 mm NPTH
    j3_pads=[(150.6, 100.6), (154.2, 100.6)],  # battery wire through-holes
    j1=(157.18, 103.6, 159.18, 109.0), j1_h=1.45,  # JST SM06B-XSRS side entry, mates from +X
    # PCB pocket
    pcb_clr=0.30,          # per side
    rib_protrude=0.25,     # crush ribs centre the board: nominal gap 0.05/side; shave if too tight
    rib_r=0.4,
    wall=1.4, floor=1.6,
    f_gap=1.05,            # F-side parts <= 0.8 mm (ANT1) -> 0.25 mm to the floor
    ledge_w=0.65,          # from pocket wall; 0.35 mm under the board edge
    part_clr=0.35,         # ledge clearance around F-side parts (covers a 0.3 mm board shift)
    # gasket + mic boss
    gasket_t=0.5, gasket_squeeze=0.30,
    boss=(149.8, 103.45, 152.2, 105.15), boss_r=0.3,
    channel_d=0.8,
    # B-side supports that press the PCB down onto ledges + gasket
    legs=[(155.6, 101.9), (157.9, 100.6)], leg=0.7,  # centres; free B-side copper
    mic_pad=(1.6, 2.0),    # pad on the MK2 lid, directly above the gasket
    # battery
    batt=(12.0, 10.0, 3.0), comp_size=(14.0, 11.0), batt_squeeze=0.10,
    # lid
    lid_t=1.0, rebate_w=0.75, rebate_h=1.0, lip_clr=0.05,
    outer_r=2.0, bottom_fillet=1.0, lid_fillet=0.6,
    j1_window=(103.0, 109.6, 2.05),  # y0, y1, height above B surface
)

# v3 / side-v2 (after the first print, 2026-11-09): lid would not go on an empty base, PCB
# slightly too tight, battery thicker than 3.0, 0.8 mm channel printed shut.
P3 = {**P,
      "pcb_clr": 0.40, "rib_protrude": 0.15,   # nominal gap 0.25/side with ribs
      "ledge_w": 0.85, "part_clr": 0.45,       # ledge still under the board when shifted
      "lip_clr": 0.20,                         # lid lip vs rebate, per side (was 0.05)
      "plate_clr": 0.25,
      "comp_size": (14.4, 11.4),
      "batt": (12.0, 10.0, 3.4),               # thick-battery case for the fit check
      "batt_room_h": 3.6, "batt_squeeze": 0.0, # battery no longer carries the clamp force
      "channel_d": 1.0, "channel_chamfer": 0.2,
      # boss grows under R4 (R4 underside is 0.12 above the boss top) so the 1.0 channel has walls
      "boss": (149.8, 103.65, 152.2, 105.75),
      "gasket_rect": (149.8, 103.65, 152.2, 105.05),  # gasket stays in the clear patch
      }

VARIANTS = {  # name: (cavity diameter, depth)
    "A_d6_h1.0": (6.0, 1.0),
    "B_d8_h1.0": (8.0, 1.0),
    "C_d10_h0.8": (10.0, 0.8),
}


# ---------------- helpers ----------------
def rr(x0, y0, x1, y1, r, z0, z1):
    r = min(r, (x1 - x0) / 2 - 1e-3, (y1 - y0) / 2 - 1e-3)
    return Pos((x0 + x1) / 2, (y0 + y1) / 2, z0) * extrude(RectangleRounded(x1 - x0, y1 - y0, r), z1 - z0)


def grow(rect, d):
    x0, y0, x1, y1 = rect
    return (x0 - d, y0 - d, x1 + d, y1 + d)


def bbox(*rects):
    return (min(r[0] for r in rects), min(r[1] for r in rects), max(r[2] for r in rects), max(r[3] for r in rects))


def box(x0, y0, x1, y1, z0, z1):
    return Pos(x0, y0, z0) * Box(x1 - x0, y1 - y0, z1 - z0, align=(Align.MIN, Align.MIN, Align.MIN))


def cyl(x, y, d, z0, z1):
    return Pos(x, y, z0) * Cylinder(d / 2, z1 - z0, align=(Align.CENTER, Align.CENTER, Align.MIN))


def board_levels(p=P):
    zF = p["floor"] + p["f_gap"]
    zB = zF + pcbdata.PCB_T
    return dict(zF=zF, zB=zB, shelf=zB + 0.3, boss_top=zF - p["gasket_t"] * (1 - p["gasket_squeeze"]),
                j1_top=zB + p["j1_h"])


def pocket(p=P):
    return grow(p["board"], p["pcb_clr"])


# ---------------- features shared by every base ----------------
def pcb_features(body, fp, Zl, p=P):
    """Cut the PCB pocket (floor -> shelf) and add ledges, crush ribs and the mic boss."""
    pk = pocket(p)
    body -= rr(*pk, p["board_r"] + p["pcb_clr"], p["floor"], Zl["shelf"])

    inner = grow(pk, -p["ledge_w"])
    ledge = rr(*pk, p["board_r"] + p["pcb_clr"], p["floor"], Zl["zF"]) - rr(*inner, 0.2, p["floor"] - 1, Zl["zF"] + 1)
    for side, x0, y0, x1, y1, *_ in fp.values():
        if side == "F":
            ledge -= box(*grow((x0, y0, x1, y1), p["part_clr"]), p["floor"] - 1, Zl["zF"] + 1)
    for x, y in p["j3_pads"]:
        ledge -= cyl(x, y, 2.0, p["floor"] - 1, Zl["zF"] + 1)
    body += ledge

    # crush ribs: half-cylinders on the pocket walls, touching only the board edge
    off = p["rib_r"] - p["rib_protrude"]
    x0, y0, x1, y1 = pk
    ribs = [(x0 - off, 101.5), (x0 - off, 107.5), (x1 + off, 101.5),       # x+ wall: avoid J1 window
            (151.5, y0 - off), (157.5, y0 - off), (152.5, y1 + off), (157.5, y1 + off)]
    for rx, ry in ribs:
        body += cyl(rx, ry, 2 * p["rib_r"], Zl["zF"] - 0.3, Zl["shelf"])

    body += rr(*p["boss"], p["boss_r"], p["floor"] - 0.01, Zl["boss_top"])
    return body


def skin_cavity(body, cav_d, cav_h, Zl, p=P):
    mx, my = p["mic_hole"]
    body -= cyl(mx, my, cav_d, -0.01, cav_h)
    body -= Pos(mx, my, -0.01) * Cone(cav_d / 2 + 0.3, cav_d / 2, 0.31, align=(Align.CENTER, Align.CENTER, Align.MIN))
    body -= cyl(mx, my, p["channel_d"], -0.1, Zl["boss_top"] + 0.1)
    c = p.get("channel_chamfer", 0)
    if c:  # 45 deg lead-ins at both channel ends: easier to clear with a needle / drill
        d = p["channel_d"]
        body -= Pos(mx, my, cav_h - 0.01) * Cone(d / 2 + c, d / 2, c + 0.01, align=(Align.CENTER, Align.CENTER, Align.MIN))
        body -= Pos(mx, my, Zl["boss_top"] - c) * Cone(d / 2, d / 2 + c, c + 0.01, align=(Align.CENTER, Align.CENTER, Align.MIN))
    return body


def supports(fp, z_top, Zl, p=P):
    """Legs to the B surface + a pad on the MK2 lid, hanging down from z_top."""
    s = None
    h = p["leg"] / 2
    for lx, ly in p["legs"]:
        leg = box(lx - h, ly - h, lx + h, ly + h, Zl["zB"], z_top + 0.01)
        s = leg if s is None else s + leg
    _, x0, y0, x1, y1, _, ztop_mic = fp["MK2"]
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    w, d = p["mic_pad"]
    s += box(cx - w / 2, cy - d / 2, cx + w / 2, cy + d / 2, ztop_mic, z_top + 0.01)
    return s


def gasket_template(Zl, p=P):
    g = rr(*p.get("gasket_rect", p["boss"]), p["boss_r"], Zl["boss_top"], Zl["boss_top"] + p["gasket_t"])
    return g - cyl(*p["mic_hole"], 0.7, Zl["boss_top"] - 1, Zl["zF"] + 1)


def lid_with_lip(outer, openings, rim, p=P):
    """Flat lid over `outer`; press-fit lip sits in a rebate around the union of `openings` (rects)."""
    lid = rr(*outer, p["outer_r"], rim, rim + p["lid_t"])
    from build123d import Axis, fillet
    lid = fillet(lid.edges().group_by(Axis.Z)[-1], p["lid_fillet"])
    lip = None
    for o in openings:
        part = rr(*grow(o, p["rebate_w"] - p["lip_clr"]), 0.8 + p["rebate_w"], rim - p["rebate_h"] + 0.05, rim + 0.01)
        lip = part if lip is None else lip + part
    for o in openings:
        lip -= rr(*grow(o, p["lip_clr"]), 0.8, rim - 5, rim + 1)
    return lid + lip


def export_print_copies(parts, out, flip=("lid", "plate")):
    """Write out/print/*.stl in print orientation: bases as built; lid/plate flipped flat-face-down."""
    from build123d import Rot, export_stl
    d = out / "print"
    d.mkdir(exist_ok=True)
    for name, part in parts.items():
        if name == "gasket_template":
            continue
        if name in flip:  # real flip (180 deg about X), not a mirror: keeps legs/pad chirality
            part = Rot(180, 0, 0) * part
        part = Pos(0, 0, -part.bounding_box().min.Z) * part
        export_stl(part, str(d / f"{name}.stl"), tolerance=0.01, angular_tolerance=0.1)


def rebate(body, openings, rim, p=P):
    for o in openings:
        body -= rr(*grow(o, p["rebate_w"]), 0.8 + p["rebate_w"], rim - p["rebate_h"], rim + 1)
    return body

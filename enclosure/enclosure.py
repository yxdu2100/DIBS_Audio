#!/usr/bin/env python3
"""
DIBS nRF52 v21 body-sound sensor enclosure, v1  (build123d)

Stack, skin side first (Z up = away from skin):
  base floor with acoustic cavity -> F-side clearance (ledges + mic boss + gasket)
  -> PCB (F side DOWN, mic sound hole faces skin) -> B-side parts -> clamp plate (legs press PCB)
  -> 30 mAh LiPo -> lid (press-fit lip in a rebate)

Parts printed (all PETG, one printer):
  base_<variant>.stl  one-piece bowl incl. skin cavity; reprint to change the cavity
  plate.stl           battery tray + 3 legs that press the PCB onto the gasket
  lid.stl             press-fit back cover
Gasket: 0.5 mm silicone sheet / double-sided foam tape, ~2.4 x 1.7 mm, pierce a ~0.7 mm
hole with a needle, place on the boss over the channel. Template: gasket_template.stl.

Usage:  python enclosure.py [--out DIR]
"""
import argparse
from pathlib import Path

from build123d import (Align, Axis, Box, Cone, Cylinder, Part, Pos, RectangleRounded,
                       export_step, export_stl, extrude, fillet)

import pcbdata

# ---------------- parameters (mm) ----------------
P = dict(
    # board (KiCad coordinates)
    board=(149.5, 99.5, 159.5, 109.5), board_r=0.5,
    mic_hole=(151.2, 104.6),                  # MK2 NPTH, 0.65 mm, through the PCB
    j3_pads=[(150.6, 100.6), (154.2, 100.6)],  # battery wire through-holes
    j1=(157.18, 103.6, 159.18, 109.0),         # JST SM06B-XSRS side-entry, mates from +X edge
    # fits
    pcb_clr=0.15,          # PCB-to-pocket wall, per side
    wall=1.4, floor=1.6,
    f_gap=1.05,            # F-side parts <= 0.8 mm tall (ANT1) -> 0.25 mm to the floor
    b_parts=1.35,          # plate underside above B surface (J1 1.54 mm gets a cut-out)
    plate_t=0.6, plate_clr=0.15,
    batt=(12.0, 10.0, 3.0), comp=(145.8, 99.0, 159.8, 110.0),  # battery compartment 14 x 11
    batt_squeeze=0.10,     # lid presses battery -> plate -> PCB -> gasket
    gasket_t=0.5, gasket_squeeze=0.30,  # fraction compressed when the PCB sits on the ledges
    ledge_w=0.5,           # ledge width from the pocket wall (=0.35 under the board)
    part_clr=0.2,          # ledge/leg clearance around components
    boss=(149.8, 103.45, 152.2, 105.15), boss_r=0.3,
    channel_d=0.8,
    legs=[(152.95, 101.7), (158.6, 99.6), (156.1, 105.45)], leg=0.8,  # lower-left corners
    lid_t=1.0, rebate_w=0.75, rebate_h=1.0, lip_clr=0.05,
    outer_r=2.0, bottom_fillet=1.0, lid_fillet=0.6,
    j1_window=(103.0, 109.6, 2.05),  # y0, y1, height above B surface
)
VARIANTS = {  # name: (cavity diameter, depth)
    "A_d6_h1.0": (6.0, 1.0),
    "B_d8_h1.0": (8.0, 1.0),
    "C_d10_h0.8": (10.0, 0.8),
}


def z_levels(p=P):
    zF = p["floor"] + p["f_gap"]
    zB = zF + pcbdata.PCB_T
    shelf = zB + 0.3
    pb = zB + p["b_parts"]
    pt = pb + p["plate_t"]
    rim = pt + p["batt"][2] - p["batt_squeeze"]
    boss_top = zF - p["gasket_t"] * (1 - p["gasket_squeeze"])
    return dict(zF=zF, zB=zB, shelf=shelf, plate_bot=pb, plate_top=pt, rim=rim,
                top=rim + p["lid_t"], boss_top=boss_top)


def rr(x0, y0, x1, y1, r, z0, z1):
    """Rounded-rectangle prism."""
    r = min(r, (x1 - x0) / 2 - 1e-3, (y1 - y0) / 2 - 1e-3)
    return Pos((x0 + x1) / 2, (y0 + y1) / 2, z0) * extrude(RectangleRounded(x1 - x0, y1 - y0, r), z1 - z0)


def grow(rect, d):
    x0, y0, x1, y1 = rect
    return (x0 - d, y0 - d, x1 + d, y1 + d)


def box(x0, y0, x1, y1, z0, z1):
    return Pos(x0, y0, z0) * Box(x1 - x0, y1 - y0, z1 - z0, align=(Align.MIN, Align.MIN, Align.MIN))


def cyl(x, y, d, z0, z1):
    return Pos(x, y, z0) * Cylinder(d / 2, z1 - z0, align=(Align.CENTER, Align.CENTER, Align.MIN))


def outline(p=P):
    pocket = grow(p["board"], p["pcb_clr"])
    c = p["comp"]
    bb = (min(pocket[0], c[0]), min(pocket[1], c[1]), max(pocket[2], c[2]), max(pocket[3], c[3]))
    return grow(bb, p["wall"]), pocket


def make_base(cav_d, cav_h, fp, p=P):
    Z = z_levels(p)
    out, pocket = outline(p)
    body = rr(*out, p["outer_r"], 0, Z["rim"])
    body = fillet(body.edges().group_by(Axis.Z)[0], p["bottom_fillet"])

    # cavities: PCB pocket (incl. F clearance), battery compartment, lid rebate
    body -= rr(*pocket, p["board_r"] + p["pcb_clr"], p["floor"], Z["shelf"])
    body -= rr(*p["comp"], 0.8, Z["shelf"], Z["rim"] + 1)
    body -= rr(*grow(p["comp"], p["rebate_w"]), 0.8 + p["rebate_w"], Z["rim"] - p["rebate_h"], Z["rim"] + 1)

    # PCB support ledges (F side), notched around F-side parts and the battery-wire pads
    inner = grow(pocket, -p["ledge_w"])
    ledge = rr(*pocket, p["board_r"] + p["pcb_clr"], p["floor"], Z["zF"]) - rr(*inner, 0.2, p["floor"] - 1, Z["zF"] + 1)
    for name, (side, x0, y0, x1, y1, *_ ) in fp.items():
        if side == "F":
            ledge -= box(*grow((x0, y0, x1, y1), p["part_clr"]), p["floor"] - 1, Z["zF"] + 1)
    for x, y in p["j3_pads"]:
        ledge -= cyl(x, y, 2.0, p["floor"] - 1, Z["zF"] + 1)
    body += ledge

    # mic boss: carries the gasket, sealed to the PCB around the 0.65 mm sound hole
    body += rr(*p["boss"], p["boss_r"], p["floor"] - 0.01, Z["boss_top"])

    # skin cavity (flat bridged roof prints cleanly) + 0.3 mm mouth chamfer + channel
    mx, my = p["mic_hole"]
    body -= cyl(mx, my, cav_d, -0.01, cav_h)
    body -= Pos(mx, my, -0.01) * Cone(cav_d / 2 + 0.3, cav_d / 2, 0.31, align=(Align.CENTER, Align.CENTER, Align.MIN))
    body -= cyl(mx, my, p["channel_d"], -0.1, Z["boss_top"] + 0.1)

    # J1 side window (plug inserts along -X)
    wy0, wy1, wh = p["j1_window"]
    body -= box(pocket[2] - 0.5, wy0, out[2] + 1, wy1, Z["zB"], Z["zB"] + wh)

    # pry notch for the lid on the -Y side
    body -= box(150.5, out[1] - 1, 154.5, out[1] + 0.45, Z["rim"] - 0.7, Z["rim"] + 1)
    return body


def make_plate(p=P):
    Z = z_levels(p)
    c = grow(p["comp"], -p["plate_clr"])
    plate = rr(*c, 0.6, Z["plate_bot"], Z["plate_top"])
    x0, y0, x1, y1 = p["j1"]
    plate -= box(x0 - 0.25, y0 - 0.25, c[2] + 1, y1 + 0.25, Z["plate_bot"] - 1, Z["plate_top"] + 1)  # J1 1.54 mm
    plate -= box(149.6, c[1] - 1, 155.2, 101.55, Z["plate_bot"] - 1, Z["plate_top"] + 1)  # battery wires from J3
    for lx, ly in p["legs"]:
        plate += box(lx, ly, lx + p["leg"], ly + p["leg"], Z["zB"], Z["plate_bot"] + 0.01)
    return plate


def make_lid(p=P):
    Z = z_levels(p)
    out, _ = outline(p)
    lid = rr(*out, p["outer_r"], Z["rim"], Z["top"])
    lid = fillet(lid.edges().group_by(Axis.Z)[-1], p["lid_fillet"])
    lip_o = grow(p["comp"], p["rebate_w"] - p["lip_clr"])
    lip = rr(*lip_o, 0.8 + p["rebate_w"] - p["lip_clr"], Z["rim"] - p["rebate_h"] + 0.05, Z["rim"] + 0.01)
    lip -= rr(*grow(p["comp"], p["lip_clr"]), 0.8, Z["rim"] - 5, Z["rim"] + 1)
    return lid + lip


def make_gasket_template(p=P):
    Z = z_levels(p)
    g = rr(*p["boss"], p["boss_r"], Z["boss_top"], Z["boss_top"] + p["gasket_t"])
    return g - cyl(*p["mic_hole"], 0.7, Z["boss_top"] - 1, Z["zF"] + 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(Path(__file__).parent / "out"))
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    Z = z_levels()
    fp = pcbdata.footprints(Z["zF"])
    o, _ = outline()
    print("levels:", {k: round(v, 3) for k, v in Z.items()})
    print(f"outer size: {o[2]-o[0]:.1f} x {o[3]-o[1]:.1f} x {Z['top']:.1f} mm")

    parts = {f"base_{k}": make_base(d, h, fp) for k, (d, h) in VARIANTS.items()}
    parts["plate"] = make_plate()
    parts["lid"] = make_lid()
    parts["gasket_template"] = make_gasket_template()
    for name, part in parts.items():
        export_stl(part, str(out / f"{name}.stl"), tolerance=0.01, angular_tolerance=0.1)
        export_step(part, str(out / f"{name}.step"))
        print(f"{name:20s} volume {part.volume:8.1f} mm^3  valid={part.is_valid}")


if __name__ == "__main__":
    main()

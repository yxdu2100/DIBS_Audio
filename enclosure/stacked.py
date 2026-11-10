#!/usr/bin/env python3
"""Stacked enclosure: skin | base(cavity) | gasket | PCB (F down) | plate | battery | lid.

  python stacked.py --version v3     (default)  -> out_stacked_v3/
  python stacked.py --version v2                -> out_stacked_v2/  (reproduces the first print)

v2: PCB clearance 0.30 + crush ribs; plate sits on J1, presses the PCB via 2 legs + a pad on MK2;
    battery squeezed 0.1 by the lid (battery carries the clamp force).
v3: PCB clearance 0.40, lid lip clearance 0.20, battery room 3.6 mm with no squeeze, 1.0 mm
    channel with lead-in chamfers. Gasket = double-sided foam tape (holds the PCB by itself);
    the plate only carries the battery.
"""
import argparse
from pathlib import Path

from build123d import Axis, export_step, export_stl, fillet

import common as C
import pcbdata

HERE = Path(__file__).parent
VERSIONS = {"v2": (C.P, HERE / "out_stacked_v2"), "v3": (C.P3, HERE / "out_stacked_v3")}
P, OUT = VERSIONS["v3"]
PLATE_T = 0.6


def use(version):
    global P, OUT
    P, OUT = VERSIONS[version]


def comp_rect(p=None):
    p = p or P
    pk = C.pocket(p)
    w, h = p["comp_size"]
    cy = (pk[1] + pk[3]) / 2
    return (pk[2] - w, cy - h / 2, pk[2], cy + h / 2)


def levels(p=None):
    p = p or P
    Z = C.board_levels(p)
    Z["plate_bot"] = Z["j1_top"]
    Z["plate_top"] = Z["plate_bot"] + PLATE_T
    Z["rim"] = Z["plate_top"] + p.get("batt_room_h", p["batt"][2] - p["batt_squeeze"])
    Z["top"] = Z["rim"] + p["lid_t"]
    return Z


def outer(p=None):
    p = p or P
    return C.grow(C.bbox(C.pocket(p), comp_rect(p)), p["wall"])


def battery_box(p=None):
    p = p or P
    Z, c = levels(p), comp_rect(p)
    bx, by, bz = p["batt"]
    x0, y0 = c[0] + 0.3, (c[1] + c[3]) / 2 - by / 2
    return (x0, y0, Z["plate_top"], x0 + bx, y0 + by, Z["plate_top"] + bz)


def make_base(cav_d, cav_h, fp, p):
    Z, o, c = levels(p), outer(p), comp_rect(p)
    body = C.rr(*o, p["outer_r"], 0, Z["rim"])
    body = fillet(body.edges().group_by(Axis.Z)[0], p["bottom_fillet"])
    body = C.pcb_features(body, fp, Z, p)
    body -= C.rr(*c, 0.8, Z["shelf"], Z["rim"] + 1)
    body = C.rebate(body, [c], Z["rim"], p)
    body = C.skin_cavity(body, cav_d, cav_h, Z, p)
    wy0, wy1, wh = p["j1_window"]
    body -= C.box(C.pocket(p)[2] - 0.5, wy0, o[2] + 1, wy1, Z["zB"], Z["zB"] + wh)
    body -= C.box(150.5, o[1] - 1, 154.5, o[1] + 0.45, Z["rim"] - 0.7, Z["rim"] + 1)  # pry notch
    return body


def make_plate(fp, p):
    Z = levels(p)
    c = C.grow(comp_rect(p), -p.get("plate_clr", 0.15))
    plate = C.rr(*c, 0.6, Z["plate_bot"], Z["plate_top"])
    plate -= C.box(149.6, c[1] - 1, 155.0, 101.5, Z["plate_bot"] - 1, Z["plate_top"] + 1)  # J3 wires
    return plate + C.supports(fp, Z["plate_bot"], Z, p)


def make_lid(p):
    return C.lid_with_lip(outer(p), [comp_rect(p)], levels(p)["rim"], p)


def build():
    p = P
    OUT.mkdir(parents=True, exist_ok=True)
    Z = levels(p)
    fp = pcbdata.footprints(Z["zF"])
    o = outer(p)
    print(f"{OUT.name} levels:", {k: round(v, 3) for k, v in Z.items()})
    print(f"outer size: {o[2]-o[0]:.1f} x {o[3]-o[1]:.1f} x {Z['top']:.2f} mm")
    parts = {f"base_{k}": make_base(d, h, fp, p) for k, (d, h) in C.VARIANTS.items()}
    parts["plate"] = make_plate(fp, p)
    parts["lid"] = make_lid(p)
    parts["gasket_template"] = C.gasket_template(Z, p)
    for name, part in parts.items():
        export_stl(part, str(OUT / f"{name}.stl"), tolerance=0.01, angular_tolerance=0.1)
        export_step(part, str(OUT / f"{name}.step"))
        print(f"  {name:20s} {part.volume:8.1f} mm^3 valid={part.is_valid}")
    C.export_print_copies(parts, OUT)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default="v3", choices=list(VERSIONS))
    use(ap.parse_args().version)
    build()

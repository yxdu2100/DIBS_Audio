#!/usr/bin/env python3
"""Side-by-side enclosure (flat): battery next to the PCB on the mic (-X) side, away from ANT1.

skin | base(cavity) | gasket | PCB (F down)      | lid (legs + mic pad press the PCB)
                               battery on a raised floor
  python side.py --version v2     (default)  -> out_side_v2/   (v3 parameter set, see common.P3)
  python side.py --version v1                -> out_side_v1/   (reproduces the first print)
"""
import argparse
from pathlib import Path

from build123d import Axis, export_step, export_stl, fillet

import common as C
import pcbdata

HERE = Path(__file__).parent
VERSIONS = {"v1": (C.P, HERE / "out_side_v1"), "v2": (C.P3, HERE / "out_side_v2")}
P, OUT = VERSIONS["v2"]
DIVIDER = 0.8


def use(version):
    global P, OUT
    P, OUT = VERSIONS[version]


def comp_rect(p=None):
    p = p or P
    pk = C.pocket(p)
    w, h = p["comp_size"]
    cy = (pk[1] + pk[3]) / 2
    return (pk[0] - DIVIDER - w, cy - h / 2, pk[0] - DIVIDER, cy + h / 2)


def bridge_rect(p=None):
    p = p or P
    pk, c = C.pocket(p), comp_rect(p)
    return (c[2] - 0.5, pk[1], pk[0] + 0.5, pk[3])


def levels(p=None):
    p = p or P
    Z = C.board_levels(p)
    Z["rim"] = Z["j1_top"]                        # lid underside rests on the J1 housing
    Z["batt_floor"] = Z["rim"] - p.get("batt_room_h", p["batt"][2] - p["batt_squeeze"])
    Z["top"] = Z["rim"] + p["lid_t"]
    return Z


def outer(p=None):
    p = p or P
    return C.grow(C.bbox(C.pocket(p), comp_rect(p)), p["wall"])


def battery_box(p=None):
    p = p or P
    Z, c = levels(p), comp_rect(p)
    bx, by, bz = p["batt"]
    x0, y0 = c[0] + 1.0, (c[1] + c[3]) / 2 - by / 2
    return (x0, y0, Z["batt_floor"], x0 + bx, y0 + by, Z["batt_floor"] + bz)


def make_base(cav_d, cav_h, fp, p):
    Z, o, c, b = levels(p), outer(p), comp_rect(p), bridge_rect(p)
    pk = C.pocket(p)
    body = C.rr(*o, p["outer_r"], 0, Z["rim"])
    body = fillet(body.edges().group_by(Axis.Z)[0], p["bottom_fillet"])
    body = C.pcb_features(body, fp, Z, p)
    body -= C.rr(*pk, 0.8, Z["shelf"], Z["rim"] + 1)
    body -= C.rr(*c, 0.8, Z["batt_floor"], Z["rim"] + 1)
    body -= C.box(*b, Z["shelf"], Z["rim"] + 1)
    body = C.rebate(body, [pk, c, b], Z["rim"], p)
    body = C.skin_cavity(body, cav_d, cav_h, Z, p)
    wy0, wy1, _ = p["j1_window"]
    body -= C.box(pk[2] - 0.5, wy0, o[2] + 1, wy1, Z["zB"], Z["rim"] + 1)  # J1 window, open top
    body -= C.box(c[0] + 3, o[1] - 1, c[0] + 7, o[1] + 0.45, Z["rim"] - 0.7, Z["rim"] + 1)  # pry notch
    return body


def make_lid(fp, p):
    Z, pk, c, b = levels(p), C.pocket(p), comp_rect(p), bridge_rect(p)
    lid = C.lid_with_lip(outer(p), [pk, c, b], Z["rim"], p)
    wy0, wy1, _ = p["j1_window"]
    lid -= C.box(pk[2] - 0.6, wy0 - 0.05, outer(p)[2] + 1, wy1 + 0.05, Z["rim"] - 2, Z["rim"])
    return lid + C.supports(fp, Z["rim"], Z, p)


def build():
    p = P
    OUT.mkdir(parents=True, exist_ok=True)
    Z = levels(p)
    fp = pcbdata.footprints(Z["zF"])
    o = outer(p)
    print(f"{OUT.name} levels:", {k: round(v, 3) for k, v in Z.items()})
    print(f"outer size: {o[2]-o[0]:.1f} x {o[3]-o[1]:.1f} x {Z['top']:.2f} mm")
    parts = {f"base_{k}": make_base(d, h, fp, p) for k, (d, h) in C.VARIANTS.items()}
    parts["lid"] = make_lid(fp, p)
    parts["gasket_template"] = C.gasket_template(Z, p)
    for name, part in parts.items():
        export_stl(part, str(OUT / f"{name}.stl"), tolerance=0.01, angular_tolerance=0.1)
        export_step(part, str(OUT / f"{name}.step"))
        print(f"  {name:20s} {part.volume:8.1f} mm^3 valid={part.is_valid}")
    C.export_print_copies(parts, OUT)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default="v2", choices=list(VERSIONS))
    use(ap.parse_args().version)
    build()

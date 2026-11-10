#!/usr/bin/env python3
"""Tolerance test coupon (print with the same filament / settings as the enclosure).

  python coupon.py  -> out_coupon/
    pcb_frames.stl   5 PCB pockets in one strip, clearance per side 0.20 / 0.30 / 0.40 / 0.50 mm,
                     plus "40R" = 0.40 with the v3 crush ribs (0.15 mm). Drop the real PCB in.
    lid_frame.stl    the v3 stacked rebate (14.4 x 11.4 opening, rebate 0.75 x 1.0)
    lid_10 .. lid_30 lids with lip clearance 0.10 / 0.15 / 0.20 / 0.30 mm per side (v3 = 0.20)
    holes.stl        2.4 mm thick bar, through holes 0.6 / 0.8 / 1.0 / 1.2 / 1.5 mm;
                     top row plain, bottom row with the v3 0.2 mm lead-in chamfers.
Print all flat, as exported. Labels are embossed numbers (clearance in 1/100 mm, hole in 1/10 mm).
"""
from pathlib import Path

from build123d import Align, Cone, Plane, Pos, Text, export_stl, extrude, mirror

import common as C

OUT = Path(__file__).parent / "out_coupon"
P = C.P3
WALL = 1.4


def label(txt, x, y, z, size=2.6, h=0.4):
    return Pos(x, y, z) * extrude(Text(txt, font_size=size, align=(Align.CENTER, Align.CENTER)), h)


def pcb_frames():
    bw = P["board"][2] - P["board"][0]           # 10.0
    cases = [("20", 0.20, 0), ("30", 0.30, 0), ("40", 0.40, 0), ("50", 0.50, 0), ("40R", 0.40, 0.15)]
    pitch = bw + 2 * 0.5 + 2 * WALL
    H = 2.0
    strip = None
    for i, (txt, clr, rib) in enumerate(cases):
        cx = i * pitch
        ox = (cx - pitch / 2, -bw / 2 - clr - WALL, cx + pitch / 2, bw / 2 + clr + WALL + 4.0)  # +4 label tab
        f = C.rr(*ox, 1.0, 0, H)
        pk = (cx - bw / 2 - clr, -bw / 2 - clr, cx + bw / 2 + clr, bw / 2 + clr)
        f -= C.rr(*pk, P["board_r"] + clr, -1, H + 1)
        if rib:
            off = P["rib_r"] - rib
            for rx, ry in [(pk[0] - off, -2.5), (pk[0] - off, 2.5), (pk[2] + off, -2.5), (pk[2] + off, 2.5),
                           (cx - 2.5, pk[1] - off), (cx + 2.5, pk[1] - off), (cx, pk[3] + off)]:
                f += C.cyl(rx, ry, 2 * P["rib_r"], 0, H)
        f += label(txt, cx, bw / 2 + clr + WALL + 2.0, H)
        strip = f if strip is None else strip + f
    return strip


def lid_frame_and_lids():
    w, h = P["comp_size"]
    comp = (-w / 2, -h / 2, w / 2, h / 2)
    o = C.grow(comp, P["rebate_w"] + 0.65)          # same wall as the real base at the rim
    H, rim = 2.5, 2.5
    frame = C.rr(*o, P["outer_r"], 0, H) - C.rr(*comp, 0.8, -1, H + 1)
    frame = C.rebate(frame, [comp], rim, P)
    lids = {}
    top = rim + P["lid_t"]
    for txt, clr in [("10", 0.10), ("15", 0.15), ("20", 0.20), ("30", 0.30)]:
        q = {**P, "lip_clr": clr}
        lid = C.lid_with_lip(o, [comp], rim, q)
        lid -= Pos(0, 0, rim - 0.01) * extrude(Text(txt, font_size=4.0, align=(Align.CENTER, Align.CENTER)), 0.4)
        # print orientation: outer face on the bed, lip up
        lid = mirror(lid, Plane.XY.offset(top))
        lid = Pos(0, 0, -top) * lid
        lids[txt] = lid
    return frame, lids


def holes():
    ds = [0.6, 0.8, 1.0, 1.2, 1.5]
    T = 2.4
    bar = C.rr(-2, -4.5, len(ds) * 4.0 + 1, 7.5, 0.8, 0, T)
    c = P["channel_chamfer"]
    for i, d in enumerate(ds):
        x = i * 4.0 + 1.5
        bar -= C.cyl(x, 0, d, -1, T + 1)                       # plain
        bar -= C.cyl(x, -3, d, -1, T + 1)                      # chamfered
        bar -= Pos(x, -3, -0.01) * Cone(d / 2 + c, d / 2, c + 0.01, align=(Align.CENTER, Align.CENTER, Align.MIN))
        bar -= Pos(x, -3, T - c) * Cone(d / 2, d / 2 + c, c + 0.01, align=(Align.CENTER, Align.CENTER, Align.MIN))
        bar += label(f"{int(round(d*10))}", x, 4.5, T, size=2.2)
    return bar


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    export_stl(pcb_frames(), str(OUT / "pcb_frames.stl"), tolerance=0.01, angular_tolerance=0.1)
    frame, lids = lid_frame_and_lids()
    export_stl(frame, str(OUT / "lid_frame.stl"), tolerance=0.01, angular_tolerance=0.1)
    for txt, lid in lids.items():
        export_stl(lid, str(OUT / f"lid_{txt}.stl"), tolerance=0.01, angular_tolerance=0.1)
    export_stl(holes(), str(OUT / "holes.stl"), tolerance=0.01, angular_tolerance=0.1)
    print("wrote", sorted(p.name for p in OUT.iterdir()))


if __name__ == "__main__":
    main()

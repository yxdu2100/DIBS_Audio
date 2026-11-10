#!/usr/bin/env python3
"""Drop the real PCB 3D model (GLB) + a battery block into the printed parts and check the fit.

  python check_fit.py --design stacked --variant B_d8_h1.0
  python check_fit.py --design side    --variant A_d6_h1.0

Reports penetration / clearance per component at the nominal position and with the PCB shifted
+-0.3 mm in X/Y (crush ribs shaved off, worst case). Writes fit_sections_<variant>.png.
"""
import argparse
import importlib

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import trimesh

import common as C
import pcbdata

EXPECTED = {("BOARD", "base"): "PCB on ledges / ribs", ("BOARD", "plate"): "legs press PCB",
            ("BOARD", "lid"): "legs press PCB", ("BOARD", "gasket"): "gasket squeeze",
            ("J1", "plate"): "plate rests on J1", ("J1", "lid"): "lid rests on J1",
            ("MK2", "plate"): "pad on mic lid", ("MK2", "lid"): "pad on mic lid",
            ("BATTERY", "lid"): "battery squeeze", ("BATTERY", "plate"): "battery on plate",
            ("BATTERY", "base"): "battery on floor"}


def load(design, variant, version=None):
    mod = importlib.import_module(design)
    if version:
        mod.use(version)
    names = {"base": f"base_{variant}", "lid": "lid", "gasket": "gasket_template"}
    if (mod.OUT / "plate.stl").exists():
        names["plate"] = "plate"
    parts = {k: trimesh.load(mod.OUT / f"{v}.stl") for k, v in names.items()}
    for k, m in parts.items():
        assert m.is_watertight, k
    Z = mod.levels()
    comps = {k: trimesh.Trimesh(v, f, process=False) for k, (v, f) in pcbdata.load_components(Z["zF"]).items()}
    x0, y0, z0, x1, y1, z1 = mod.battery_box()
    b = trimesh.creation.box(extents=(x1 - x0, y1 - y0, z1 - z0))
    b.apply_translation(((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2))
    return mod, Z, parts, comps, b


def check(parts, comps, battery, shift=(0, 0), verbose=True):
    rows, problems = [], []
    items = dict(comps)
    for k in items:
        if shift != (0, 0):
            m = items[k].copy()
            m.apply_translation((shift[0], shift[1], 0))
            items[k] = m
    items["BATTERY"] = battery
    for cname, cm in sorted(items.items()):
        pts = np.vstack([cm.vertices, cm.sample(3000, seed=1)])
        for pname, pm in parts.items():
            if pname == "gasket" and cname != "BOARD":
                continue
            lo, hi = pm.bounds
            near = np.all((pts > lo - 1.0) & (pts < hi + 1.0), axis=1)
            if not near.any():
                continue
            sd = trimesh.proximity.signed_distance(pm, pts[near])
            pen = sd.max()
            note = EXPECTED.get((cname, pname), "")
            if shift != (0, 0) and cname == "BOARD" and pname == "base":
                note = "ribs crushed (expected when shifted)"
            flag = pen > 0.03 and not note
            if pen > -0.35 or note:
                rows.append((cname, pname, max(pen, 0), max(-pen, 0), note, flag))
            if flag:
                problems.append((cname, pname, round(float(pen), 3)))
    if verbose:
        print(f"{'component':10s} {'part':7s} {'penetr.':>8s} {'clear.':>7s}  note")
        for r in rows:
            print(f"{r[0]:10s} {r[1]:7s} {r[2]:8.3f} {r[3]:7.3f}  {r[4]}{'  <-- COLLISION' if r[5] else ''}")
    return problems


def sections(mod, Z, parts, comps, battery, variant):
    mx, my = C.P["mic_hole"]
    pc = {"base": "#1f6feb", "plate": "#d97706", "lid": "#16a34a", "gasket": "#db2777"}
    views = [
        ("XZ @ Y=mic hole (skin at bottom)", (0, my, 0), (0, 1, 0), (0, 2)),
        ("YZ @ X=mic hole", (mx, 0, 0), (1, 0, 0), (1, 2)),
        ("YZ @ X=158.2 (J1 window)", (158.2, 0, 0), (1, 0, 0), (1, 2)),
        (f"XY @ Z={Z['zF']-0.2:.2f} (F side: ledges, ribs, boss)", (0, 0, Z["zF"] - 0.2), (0, 0, 1), (0, 1)),
        (f"XY @ Z={Z['zB']+0.5:.2f} (B side: legs, mic pad)", (0, 0, Z["zB"] + 0.5), (0, 0, 1), (0, 1)),
        (f"XY @ Z={Z['zF']+0.8:.2f} (mid-PCB: crush ribs vs board edge)", (0, 0, Z["zF"] + 0.8), (0, 0, 1), (0, 1)),
    ]
    allc = dict(comps)
    allc["BATTERY"] = battery
    fig, axs = plt.subplots(2, 3, figsize=(22, 11))
    for ax, (title, o, n, axes) in zip(axs.flat, views):
        for pname, pm in parts.items():
            s = pm.section(plane_origin=o, plane_normal=n)
            if s is not None:
                for seg in s.discrete:
                    ax.plot(seg[:, axes[0]], seg[:, axes[1]], color=pc[pname], lw=1.6)
        for cname, cm in allc.items():
            s = cm.section(plane_origin=o, plane_normal=n)
            col = "#111" if cname == "BOARD" else ("#7c3aed" if cname == "BATTERY" else "#dc2626")
            if s is not None:
                for seg in s.discrete:
                    ax.plot(seg[:, axes[0]], seg[:, axes[1]], color=col, lw=0.7)
        ax.set_title(title, fontsize=10)
        ax.set_aspect("equal")
        ax.grid(alpha=0.25)
        if axes[1] == 1:
            ax.invert_yaxis()
    handles = [plt.Line2D([], [], color=c, lw=2, label=k) for k, c in pc.items() if k in parts] + [
        plt.Line2D([], [], color="#111", label="PCB"), plt.Line2D([], [], color="#dc2626", label="components"),
        plt.Line2D([], [], color="#7c3aed", label="battery 12x10x3")]
    fig.legend(handles=handles, loc="lower center", ncol=7)
    fig.suptitle(f"{mod.__name__} - {variant} - sections with the KiCad 3D model", fontsize=13)
    fig.tight_layout(rect=(0, 0.04, 1, 0.97))
    p = mod.OUT / f"fit_sections_{variant}.png"
    fig.savefig(p, dpi=105)
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--design", default="stacked", choices=["stacked", "side"])
    ap.add_argument("--variant", default="B_d8_h1.0")
    ap.add_argument("--version", default=None, help="stacked: v2|v3, side: v1|v2 (default: newest)")
    ap.add_argument("--no-shift", action="store_true")
    a = ap.parse_args()
    mod, Z, parts, comps, battery = load(a.design, a.variant, a.version)
    print(f"== {mod.OUT.name} {a.variant}  levels {({k: round(v, 2) for k, v in Z.items()})}")
    probs = check(parts, comps, battery)
    print("nominal:", "COLLISIONS " + str(probs) if probs else "no unexpected collisions")

    board = comps["BOARD"]
    mx, my = C.P["mic_hole"]
    for r in (0.0, 0.2):
        hits = len(board.ray.intersects_location([[mx + r, my, 0]], [[0, 0, 1]])[0])
        print(f"mic hole ray (+{r} mm): {'OPEN' if hits == 0 else 'BLOCKED'}")

    if not a.no_shift:
        p = mod.P
        for label, d in (("ribs intact", round(p["pcb_clr"] - p["rib_protrude"], 3)), ("ribs shaved", p["pcb_clr"])):
            for s in [(d, 0), (-d, 0), (0, d), (0, -d), (d, d), (-d, -d), (d, -d), (-d, d)]:
                pr = check(parts, comps, battery, s, verbose=False)
                print(f"PCB shifted {s} ({label}): {'COLLISIONS ' + str(pr) if pr else 'ok'}")
    print("wrote", sections(mod, Z, parts, comps, battery, a.variant))


if __name__ == "__main__":
    main()

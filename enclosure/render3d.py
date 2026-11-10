"""Exploded isometric render of the assembly (base variant B) with the KiCad PCB model."""
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt, numpy as np, trimesh
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
from pathlib import Path
import enclosure as E, pcbdata
OUT = Path(__file__).parent / "out"
Z = E.z_levels()
def add(ax, m, col, dz, alpha=1.0):
    m = m.copy(); m.apply_translation((0, 0, dz))
    pc = Poly3DCollection(m.vertices[m.faces], facecolor=col, edgecolor="none", alpha=alpha)
    n = m.face_normals; shade = 0.55 + 0.45 * np.clip(n @ np.array([0.3, -0.5, 0.8]), 0, 1)
    pc.set_facecolor([tuple(np.array(matplotlib.colors.to_rgb(col)) * s) + (alpha,) for s in shade])
    ax.add_collection3d(pc)
comps = pcbdata.load_components(Z["zF"])
fig = plt.figure(figsize=(14, 7))
for k, (title, flip) in enumerate([("back side up (assembly order: base -> gasket -> PCB -> plate -> battery -> lid)", 1), ("skin side up", -1)]):
    ax = fig.add_subplot(1, 2, k + 1, projection="3d")
    ex = [0, 4, 8, 13, 18, 24]
    add(ax, trimesh.load(OUT / "base_B_d8_h1.0.stl"), "#5b8def", ex[0])
    add(ax, trimesh.load(OUT / "gasket_template.stl"), "#db2777", ex[1])
    v, f = comps["BOARD"]; add(ax, trimesh.Trimesh(v, f), "#2f6f3e", ex[2])
    for c, (v, f) in comps.items():
        if c != "BOARD": add(ax, trimesh.Trimesh(v, f), "#999999", ex[2])
    add(ax, trimesh.load(OUT / "plate.stl"), "#f59e0b", ex[3])
    b = trimesh.creation.box(extents=(12, 10, 3)); b.apply_translation((146.1 + 6, 104.5, Z["plate_top"] + 1.5))
    add(ax, b, "#a78bfa", ex[4])
    add(ax, trimesh.load(OUT / "lid.stl"), "#34d399", ex[5])
    ax.set_xlim(144, 162); ax.set_ylim(96, 114); ax.set_zlim(-2, 36)
    ax.set_box_aspect((18, 18, 38 * 0.75)); ax.view_init(elev=22 * flip, azim=-60); ax.invert_yaxis(); ax.set_axis_off()
    ax.set_title(title, fontsize=10)
fig.tight_layout(); fig.savefig(OUT / "exploded.png", dpi=120); print("ok")

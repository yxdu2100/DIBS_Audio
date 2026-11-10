"""Load the KiCad-exported GLB of dibs_nrf52_v21 into the enclosure ("device") frame.

Device frame (mm):
  X, Y = KiCad board coordinates (X right, Y down in pcbnew)
  Z    = height, measured from the skin face of the enclosure. +Z points from the
         skin toward the back. The PCB F side (mic sound hole side) faces the skin,
         so the F copper surface sits at Z = zF and the B surface at Z = zF + 1.6.

KiCad's glTF is Y-up with z_glb = +KiCad Y and the F surface at y_glb = 1.6 mm, so
  X = x_glb, Y = z_glb, Z = zF + 1.6 - y_glb      (a proper rotation, no mirroring)
"""
import json
import struct
from pathlib import Path

import numpy as np

GLB_DEFAULT = Path("/Users/yuxindu/Documents/KiCad/9.0/projects/dibs_nrf52_v21/dibs_nrf52_v21.glb")
PCB_T = 1.6

_CTYPE = {5120: np.int8, 5121: np.uint8, 5122: np.int16, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
_NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def _q2m(q):
    x, y, z, w = q
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def _T(n):
    if "matrix" in n:
        return np.array(n["matrix"]).reshape(4, 4).T
    M = np.eye(4)
    M[:3, :3] = _q2m(n.get("rotation", [0, 0, 0, 1])) @ np.diag(n.get("scale", [1, 1, 1]))
    M[:3, 3] = n.get("translation", [0, 0, 0])
    return M


def load_components(zF, glb=GLB_DEFAULT):
    """Return {name: (vertices Nx3 mm in device frame, faces Mx3)}.
    The bare board (all '=>' nodes) is returned as 'BOARD'."""
    data = Path(glb).read_bytes()
    jlen = struct.unpack("<I", data[12:16])[0]
    j = json.loads(data[20:20 + jlen])
    bin_off = 20 + jlen + 8
    acc, bvs = j["accessors"], j["bufferViews"]

    def read(ai):
        a = acc[ai]
        bv = bvs[a["bufferView"]]
        n = _NCOMP[a["type"]]
        dt = np.dtype(_CTYPE[a["componentType"]])
        start = bin_off + bv.get("byteOffset", 0) + a.get("byteOffset", 0)
        stride = bv.get("byteStride", 0)
        if stride and stride != n * dt.itemsize:
            raw = np.frombuffer(data, np.uint8, count=stride * a["count"], offset=start).reshape(-1, stride)
            return raw[:, :n * dt.itemsize].copy().view(dt).reshape(-1, n)
        return np.frombuffer(data, dt, count=a["count"] * n, offset=start).reshape(-1, n)

    R = np.array([[1, 0, 0], [0, 0, 1], [0, -1, 0]], float)
    parts = {}

    def walk(i, M, top):
        n = j["nodes"][i]
        M2 = M @ _T(n)
        if "mesh" in n:
            for p in j["meshes"][n["mesh"]]["primitives"]:
                v = read(p["attributes"]["POSITION"]).astype(float)
                v = (M2[:3, :3] @ v.T).T + M2[:3, 3]
                v = v * 1000.0
                v = (R @ v.T).T
                v[:, 2] += zF + PCB_T
                f = read(p["indices"]).reshape(-1, 3).astype(np.int64) if "indices" in p \
                    else np.arange(len(v)).reshape(-1, 3)
                vs, fs = parts.setdefault(top, ([], []))
                off = sum(len(x) for x in vs)
                vs.append(v)
                fs.append(f + off)
        for c in n.get("children", []):
            walk(c, M2, top)

    for r in j["scenes"][0]["nodes"]:
        rn = j["nodes"][r]
        Mr = _T(rn)
        for c in rn.get("children", []):
            nm = j["nodes"][c].get("name", "?")
            walk(c, Mr, "BOARD" if nm.startswith("=>") else nm)
    return {k: (np.vstack(v), np.vstack(f)) for k, (v, f) in parts.items()}


def footprints(zF, glb=GLB_DEFAULT):
    """{name: (side, xmin, ymin, xmax, ymax, zmin, zmax)} for every component (not the board)."""
    out = {}
    for k, (v, _) in load_components(zF, glb).items():
        if k == "BOARD":
            continue
        lo, hi = v.min(0), v.max(0)
        side = "F" if hi[2] <= zF + 0.05 + 1e-6 or lo[2] < zF - 0.05 else "B"
        out[k] = (side, lo[0], lo[1], hi[0], hi[1], lo[2], hi[2])
    return out

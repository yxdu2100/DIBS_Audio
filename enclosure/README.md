# DIBS nRF52 v21 Enclosure

Body-sound sensor enclosure (fetal / chewing / swallowing). The PCB **F side faces the skin**: MK2 (ICS-41350) is a bottom-port mic, and its 0.65 mm sound hole goes through the PCB to the F side.

## Versions (each in its own folder)

| Folder | Notes | External size |
|---|---|---|
| `out/` | Stacked v1 (first design, PCB clearance 0.15, never printed) | 16.8 × 13.8 × 10.1 |
| `out_stacked_v2/`, `out_side_v1/` | **First print, 2026-11-09.** Lid wouldn't go on an empty base, PCB slightly too tight, battery thicker than expected, 0.8 mm channel printed shut | 16.8 × 13.8 × 10.2 / 28.2 × 13.8 × 6.7 |
| `out_stacked_v3/` | Stacked, v3 parameters (below) | 17.2 × 14.2 × 10.9 |
| `out_side_v2/` | Side by side, v3 parameters (below) | 28.8 × 14.2 × 6.7 |
| `out_coupon/` | Tolerance test coupon | — |

In each version folder, **`print/` holds STLs already in print orientation**: the lid and plate are flipped flat-face-down. Drag them into the slicer as-is. The STLs in the top level of each folder are in the assembled position and are used by `check_fit.py`.

## v3 parameter set (`common.P3`) vs. the first print

| Item | First print | v3 |
|---|---|---|
| PCB pocket clearance (per side) | 0.30, ribs 0.25 → gap 0.05 | **0.40**, ribs 0.15 → gap 0.25 |
| Lid lip clearance (per side) | 0.05 | **0.20** |
| Plate clearance | 0.15 | 0.25 |
| Battery compartment | 14 × 11, battery height 3.0 squeezed 0.1 | **14.4 × 11.4, height 3.6, no squeeze** |
| Channel | Ø0.8 | **Ø1.0**, 0.2 mm 45° chamfer at both ends |
| Boss | 2.4 × 1.7 | Extends under R4 (0.12 mm below it), 2.4 × 2.1 |
| Gasket | Silicone, pressed via the battery | **Double-sided foam tape**: sticks to both boss and PCB, no clamping force needed |

## Tolerance coupon (`out_coupon/`, print alongside)

| File | What to test | How to read it |
|---|---|---|
| `pcb_frames.stl` | Drop the PCB into each pocket | Labels 20 / 30 / 40 / 50 = clearance in 0.01 mm per side; 40R = 0.40 with v3 ribs |
| `lid_frame.stl` + `lid_10/15/20/30.stl` | Press each lid into the frame | The number is cut into the inside of the lid = lip clearance in 0.01 mm. v3 uses 20 |
| `holes.stl` | Look through each hole / poke a needle through | Labels 6 / 8 / 10 / 12 / 15 = hole diameter in 0.1 mm; top row plain, bottom row with chamfers |

**After printing:** pick the smallest clearance that goes in smoothly and the smallest hole that comes out open. Tell me the numbers and I'll update `P3` and regenerate.

## Printing (Bambu P1P, PETG, 0.4 mm nozzle)

- **Layer height:** 0.1 mm.
- **Walls:** 4. **Infill:** 100% rectilinear.
- **Wall generator: Arachne**, and **Detect thin wall** on.
- **Outer wall speed:** 60–80 mm/s.
- **Support:** off.
- **Bases:** skin face on the bed. **Lid and plate:** use the `print/` copies.

## Assembly

1. Cut the gasket from double-sided foam tape using `gasket_template` as a guide (about 2.4 × 1.4 mm). Pierce a ~0.7 mm hole with a needle and stick it on the boss, hole aligned with the channel.
2. Clear the channel: push a 0.8–1.0 mm drill bit (pin vise) or a needle through from the cavity side.
3. Solder the battery wires to J3 **from the B side**; cut the F-side ends flush.
4. PCB in **F side down**, J1 toward the side window. Press it so it sticks to the gasket.
5. *(Stacked)* Plate, then battery, then lid.
   *(Side by side)* Battery into its compartment (wires over the divider), then lid.
   The battery now has about 0.2 mm of room; if it rattles, put a piece of tape under it.

## Scripts

```
python stacked.py --version v3        # -> out_stacked_v3/   (v2 reproduces the first print)
python side.py --version v2           # -> out_side_v2/      (v1 reproduces the first print)
python coupon.py                      # -> out_coupon/
python check_fit.py --design stacked --version v3 --variant B_d8_h1.0
```

`check_fit.py` overlays the KiCad GLB and checks interference. It checks the nominal position, ±0.25 mm (ribs intact) and ±0.40 mm (ribs shaved).

Dependencies: `build123d trimesh rtree matplotlib scipy shapely networkx`.

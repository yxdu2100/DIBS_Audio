#!/usr/bin/env python3
"""Tap test for audio/IMU alignment.

Tap the board sharply a few times (a second or more apart) while recording,
then run:

    python3 tools/tap_check.py "<session folder>"

Each tap is a click in audio.wav and an acceleration spike in
imu_aligned.csv. For every click the script takes the loudest audio sample
and the largest IMU sample-to-sample change near it and prints IMU minus
audio. Peaks are used rather than threshold crossings: a finger touching the
board before the tap moves it slightly, which would trip an IMU threshold
early. A constant difference is the fixed
delay between the two signal paths (set it as fixedDelayCorrectionMs); a
difference that changes over the session would mean the clocks drift.
"""
import csv
import json
import sys
import wave
from pathlib import Path

import numpy as np

MIN_GAP_S = 0.5  # taps closer than this are treated as one


def onsets(t, x, k, min_gap):
    """Times where |x| first rises above k * its median after a quiet gap."""
    level = np.abs(x)
    thr = k * np.median(level)
    above = np.flatnonzero(level > thr)
    out, last = [], -np.inf
    for i in above:
        if t[i] - last > min_gap:
            out.append(t[i])
        last = t[i]
    return np.array(out), thr


def main(folder):
    folder = Path(folder)
    with wave.open(str(folder / "audio.wav")) as w:
        audio = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(float)
    # The WAV header holds the rounded rate; time from the exact one.
    meta = json.loads((folder / "session.json").read_text())
    exact = meta["audio"]["sampleRateHz"]
    t_audio = np.arange(len(audio)) / exact

    rows = list(csv.DictReader(open(folder / "imu_aligned.csv")))
    t_imu = np.array([float(r["time_s"]) for r in rows])
    acc = np.array([[float(r[k]) for k in ("ax_mps2", "ay_mps2", "az_mps2")] for r in rows])
    # Sample-to-sample change of the acceleration vector: gravity drops out.
    jerk = np.r_[0.0, np.linalg.norm(np.diff(acc, axis=0), axis=1)]

    a_on, a_thr = onsets(t_audio, audio - np.median(audio), 12, MIN_GAP_S)
    i_on, i_thr = onsets(t_imu, jerk, 12, MIN_GAP_S)
    print(f"audio: {len(a_on)} taps (threshold {a_thr:.0f}), "
          f"imu: {len(i_on)} taps (threshold {i_thr:.3f} m/s^2 per sample)")

    diffs = []
    for ta in a_on:
        # Loudest point of the click, then the sharpest IMU change near it.
        win = (t_audio >= ta) & (t_audio < ta + 0.03)
        tpk = t_audio[win][np.argmax(np.abs(audio[win] - np.median(audio)))]
        near = np.abs(t_imu - tpk) < 0.06
        if not near.any() or jerk[near].max() < i_thr:
            print(f"  tap at {tpk:8.3f} s   no IMU spike within 60 ms")
            continue
        ti = t_imu[near][np.argmax(jerk[near])]
        d = (ti - tpk) * 1000
        diffs.append(d)
        print(f"  tap at {tpk:8.3f} s   imu - audio = {d:+7.2f} ms")
    if diffs:
        d = np.array(diffs)
        print(f"mean {d.mean():+.2f} ms, std {d.std():.2f} ms, "
              f"range {d.min():+.2f} .. {d.max():+.2f} ms over {len(d)} taps")
        period = np.median(np.diff(t_imu)) * 1000
        print(f"(IMU samples are {period:.1f} ms apart, so expect a few ms of spread)")


if __name__ == "__main__":
    main(sys.argv[1])

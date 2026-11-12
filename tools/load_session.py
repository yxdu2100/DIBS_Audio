#!/usr/bin/env python3
"""Load a DIBS session folder onto one timeline.

    from load_session import load
    s = load("path/to/DIBS 2026-11-11 13.35.29")
    s["audio"], s["audio_t"]          # int16 samples, seconds
    s["accel"], s["accel_t"]          # (N, 3) m/s^2, seconds   (high-rate: every sample)
    s["accel_valid"]                  # False where a lost BLE packet was zero-filled
    s["imu"]                          # imu_aligned.csv as a dict of arrays

Times are seconds from the first sample of audio.wav, the same clock for
every stream; IMU-only sessions (no audio.wav) use seconds from the session
start on the board's clock instead, and "audio" is empty. Standard sessions give accel from imu_aligned.csv (120 Hz);
high-rate sessions give every accel sample from imu_accel.wav, timed by
interpolating imu_accel_timeline.csv (exact between FIFO timestamps).

    python3 tools/load_session.py "<session folder>"   prints a summary
"""
import csv
import json
import sys
import wave
from pathlib import Path

import numpy as np

G = 9.80665


def _wav(path):
    with wave.open(str(path)) as w:
        x = np.frombuffer(w.readframes(w.getnframes()), "<i2")
        return x.reshape(-1, w.getnchannels()), w.getframerate()


def _csv(path):
    rows = list(csv.DictReader(open(path)))
    return {k: np.array([float(r[k]) for r in rows]) for k in (rows[0] if rows else [])}


def load(folder):
    folder = Path(folder)
    meta = json.loads((folder / "session.json").read_text())
    if (folder / "audio.wav").exists():
        audio, _ = _wav(folder / "audio.wav")
    else:
        audio = np.zeros((0, 1), np.int16)
    rate = meta["audio"]["sampleRateHz"]
    out = {
        "meta": meta,
        "audio": audio[:, 0],
        "audio_t": np.arange(len(audio)) / rate,
        "imu": _csv(folder / "imu_aligned.csv") if (folder / "imu_aligned.csv").exists() else {},
    }
    imu = meta["imu"]
    lsb = imu["accelMicroGPerLSB"] * 1e-6 * G
    if imu.get("mode") in ("highRate", "highRateIMUOnly", 1, 2):
        raw, _ = _wav(folder / "imu_accel.wav")
        tl = _csv(folder / "imu_accel_timeline.csv")
        k = np.arange(len(raw))
        out["accel"] = raw * lsb
        out["accel_t"] = np.interp(k, tl["accel_index"], tl["time_s"])
        out["accel_valid"] = np.any(raw != 0, axis=1)
    elif out["imu"]:
        i = out["imu"]
        out["accel"] = np.column_stack([i["ax_mps2"], i["ay_mps2"], i["az_mps2"]])
        out["accel_t"] = i["time_s"]
        out["accel_valid"] = np.ones(len(i["time_s"]), bool)
    return out


if __name__ == "__main__":
    s = load(sys.argv[1])
    m = s["meta"]
    if len(s["audio"]):
        print(f"audio: {len(s['audio'])} samples, {s['audio_t'][-1]:.2f} s")
    else:
        print("audio: none (IMU-only session)")
    if "accel" in s:
        t, v = s["accel_t"], s["accel_valid"]
        rate = (len(t) - 1) / (t[-1] - t[0])
        print(f"accel ({m['imu'].get('mode', 'standard')}): {len(t)} samples, {rate:.2f} Hz, "
              f"{t[0]:.3f}..{t[-1]:.3f} s, {100 * (1 - v.mean()):.1f} % zero-filled")
        print(f"mean |a| = {np.linalg.norm(s['accel'][v], axis=1).mean() / G:.3f} g")

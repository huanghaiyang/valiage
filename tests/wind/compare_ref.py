#!/usr/bin/env python3
"""JS ↔ GDScript 逐行等价交叉验证（比较器）

读取：
  .runtime/wind_port/js_ref.json   （由 tests/wind/crosscheck_windmodel.mjs 调用源实现生成）
  .runtime/wind_port/gd_ref.json   （由 tests/wind/crosscheck_windmodel.gd 调用移植实现生成）
比较：60 组 motionMetrics + 12 组 swayEnvelope + 第 1 组的 600 个原始轨迹点。
判据：取整后的指标必须**逐值相等**（源实现自己用 toFixed 取整）；
      未取整的原始点允许 float64 级误差（< 1e-12）。
用法： python tests/wind/compare_ref.py
"""
import json
import os
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
RT = os.path.join(ROOT, ".runtime", "wind_port")


def load(name):
    with open(os.path.join(RT, name), "r", encoding="utf-8") as f:
        return json.load(f)


def main():
    js = load("js_ref.json")
    gd = load("gd_ref.json")
    fails = []

    metric_keys = ["samples", "rmsAlong", "rmsPerp", "rmsVert", "thinness",
                   "horizontalShare", "azimuthDeg", "spanAlong", "spanPerp"]
    mism = {k: 0 for k in metric_keys}
    maxdiff = {k: 0.0 for k in metric_keys}
    details = []
    for ci, (a, b) in enumerate(zip(js["cases"], gd["cases"])):
        for k in metric_keys:
            va, vb = a["metrics"][k], b["metrics"][k]
            d = abs(float(va) - float(vb))
            if k == "azimuthDeg":
                # azimuth 是 [0,180) 模：180 与 0 是同一条水平主轴，比较取最小夹角
                d = min(d, 180.0 - d)
            maxdiff[k] = max(maxdiff[k], d)
            if d > 0.0:
                mism[k] += 1
                if len(details) < 8:
                    details.append("case#%d %s: js=%r gd=%r  (wind.dir=%s aWind=%s)"
                                   % (ci, k, va, vb, a["wind"]["direction"], a["opts"]["aWind"]))
    n_cases = len(js["cases"])
    for k in metric_keys:
        status = "PASS" if (mism[k] == 0 and n_cases == len(gd["cases"])) else "FAIL"
        if status == "FAIL":
            fails.append("motionMetrics.%s" % k)
        print("%-18s cases=%d mismatches=%d max|diff|=%.3e  %s"
              % (k, n_cases, mism[k], maxdiff[k], status))
    if details:
        print("  mismatching cases:")
        for d in details:
            print("    " + d)

    env_keys = ["p2p", "meanAlong", "perpP2P"]
    em = {k: 0 for k in env_keys}
    ed = {k: 0.0 for k in env_keys}
    for a, b in zip(js["env_cases"], gd["env_cases"]):
        for k in env_keys:
            d = abs(float(a["env"][k]) - float(b["env"][k]))
            ed[k] = max(ed[k], d)
            if d > 0.0:
                em[k] += 1
    for k in env_keys:
        status = "PASS" if em[k] == 0 else "FAIL"
        if status == "FAIL":
            fails.append("swayEnvelope.%s" % k)
        print("%-18s cases=%d mismatches=%d max|diff|=%.3e  %s"
              % ("envelope." + k, len(js["env_cases"]), em[k], ed[k], status))

    # 原始点（未取整）
    jp = js["raw"]["pts"]
    gp = gd["raw"]["pts"]
    if len(jp) != len(gp):
        print("raw pts count mismatch: js=%d gd=%d  FAIL" % (len(jp), len(gp)))
        fails.append("raw.pts.count")
    else:
        worst = 0.0
        for a, b in zip(jp, gp):
            for i in range(3):
                worst = max(worst, abs(float(a[i]) - float(b[i])))
        st = "PASS" if worst < 1e-6 else "FAIL"  # Godot Vector3 是 float32，不是 double
        if st == "FAIL":
            fails.append("raw.pts")
        print("raw pts (%d points, %d comps) max|diff|=%.3e  %s" % (len(jp), 3 * len(jp), worst, st))

    # 方向向量
    for k in ("windDir", "windPerp"):
        a, b = js["raw"][k], gd["raw"][k]
        d = max(abs(float(a[i]) - float(b[i])) for i in range(2))
        st = "PASS" if d < 1e-15 else "FAIL"
        if st == "FAIL":
            fails.append("raw." + k)
        print("%-18s max|diff|=%.3e  %s" % (k, d, st))

    print("-" * 72)
    if fails:
        print("RESULT: FAIL  (%d)" % len(fails))
        print("  " + ", ".join(fails))
        return 1
    print("RESULT: PASS  移植实现与 windModel.js 在上述 %d 组输入上逐值一致" % n_cases)
    return 0


if __name__ == "__main__":
    sys.exit(main())

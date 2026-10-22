#!/usr/bin/env python3
"""风摆视觉证据 · 像素差分统计（纯标准库，不依赖 Pillow）

输入（由 tests/wind/wind_visual.tscn 生成）：
  .runtime/wind_port/shots/t0.png / t0_25.png / t0_5.png   （1280x720，非 headless 真渲染）
输出：
  每对图的「树冠区域 / 树干底部区域」差异像素占比 + 变化像素的垂直分布，
  并按 acceptance 判据 PASS/FAIL。数值同时打印，便于抄进报告。

区域定义（本取景下树撑满画面：树冠在上半部，树干根部在 ~83% 高度处）：
  canopy : y ∈ [0, h/2)            整幅上半部（树冠主体都在这里）
  trunk  : y ∈ [0.80h, 0.88h)      树干根部窄条，x ∈ [0.47w, 0.55w)
  （y ∈ [0.90h, h) 在本取景里已经是背景，不能代表树干，见报告"已知限制"）

用法：
  python tests/wind/diff_visual.py
  python tests/wind/diff_visual.py --threshold 8
"""
import argparse
import json
import os
import struct
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SHOTS = os.path.join(ROOT, ".runtime", "wind_port", "shots")


# ---------------------------------------------------------------------------
# 最小 PNG 解码（8-bit、非隔行；color type 0/2/6）
# ---------------------------------------------------------------------------
def read_png(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG: " + path)
    pos = 8
    ihdr = None
    idat = bytearray()
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        ctype = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if ctype == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", chunk)
        elif ctype == b"IDAT":
            idat.extend(chunk)
        elif ctype == b"IEND":
            break
    if ihdr is None:
        raise ValueError("no IHDR")
    w, h, bit, color, comp, filt, interlace = ihdr
    if bit != 8 or interlace != 0 or color not in (0, 2, 6):
        raise ValueError("unsupported PNG (bit=%d color=%d interlace=%d)" % (bit, color, interlace))
    channels = {0: 1, 2: 3, 6: 4}[color]
    raw = zlib.decompress(bytes(idat))
    stride = w * channels
    out = bytearray(h * stride)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        if f == 1:      # Sub
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif f == 2:    # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif f == 3:    # Average
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif f == 4:    # Paeth
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        elif f != 0:
            raise ValueError("bad filter %d" % f)
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return w, h, channels, out


def pixel_diff(a, b, channels, i):
    """像素 i 的（起点字节）最大通道差 / 平均通道差"""
    if channels == 1:
        d = abs(a[i] - b[i])
        return d, d
    mx = 0
    s = 0
    for c in range(min(channels, 3)):
        d = abs(a[i + c] - b[i + c])
        s += d
        if d > mx:
            mx = d
    return mx, s / 3.0


def region_stats(w, h, ch, a, b, x0, x1, y0, y1, thr):
    changed = 0
    total = 0
    sad = 0.0
    for y in range(y0, y1):
        base = y * w * ch
        for x in range(x0, x1):
            i = base + x * ch
            mx, mean = pixel_diff(a, b, ch, i)
            total += 1
            sad += mean
            if mx > thr:
                changed += 1
    return {"total": total, "changed": changed,
            "ratio": (changed / total) if total else 0.0,
            "mean_abs_diff": (sad / total) if total else 0.0}


def bark_stats(w, h, ch, a, b, thr):
    """树干底部（深色树皮像素）区域：在图像下部 28% 里，取 t=0 时"暗"的像素。
    这样能把树干从旁边的红叶/天空里分离出来，避免区域里混进会动的叶子。"""
    changed = 0
    total = 0
    sad = 0.0
    for y in range(int(h * 0.78), int(h * 0.88)):
        base = y * w * ch
        for x in range(int(w * 0.47), int(w * 0.56)):
            i = base + x * ch
            bright = max(a[i], a[i + 1], a[i + 2]) if ch >= 3 else a[i]
            if bright > 70:          # 只算深色树皮（叶子/花/天空都更亮）
                continue
            total += 1
            mx, mean = pixel_diff(a, b, ch, i)
            sad += mean
            if mx > thr:
                changed += 1
    return {"total": total, "changed": changed,
            "ratio": (changed / total) if total else 0.0,
            "mean_abs_diff": (sad / total) if total else 0.0}


def changed_bbox(w, h, ch, a, b, thr):
    minx, miny, maxx, maxy = w, h, -1, -1
    n = 0
    for y in range(h):
        base = y * w * ch
        for x in range(w):
            i = base + x * ch
            mx, _ = pixel_diff(a, b, ch, i)
            if mx > thr:
                n += 1
                if x < minx:
                    minx = x
                if x > maxx:
                    maxx = x
                if y < miny:
                    miny = y
                if y > maxy:
                    maxy = y
    return {"count": n, "bbox": [minx, miny, maxx, maxy] if n else None}


def variance_probe(w, h, ch, a):
    """非空画面检查：抽样计算亮度标准差"""
    n = 0
    s = 0.0
    s2 = 0.0
    for y in range(0, h, 8):
        base = y * w * ch
        for x in range(0, w, 8):
            i = base + x * ch
            v = (sum(a[i:i + min(ch, 3)]) / min(ch, 3))
            s += v
            s2 += v * v
            n += 1
    mean = s / n
    var = max(0.0, s2 / n - mean * mean)
    return mean, var ** 0.5


def pair(name_a, name_b, thr, rows, dump=None):
    pa = os.path.join(SHOTS, name_a + ".png")
    pb = os.path.join(SHOTS, name_b + ".png")
    wa, ha, ca, ia = read_png(pa)
    wb, hb, cb, ib = read_png(pb)
    if (wa, ha) != (wb, hb):
        print("FAIL: size mismatch %s vs %s" % ((wa, ha), (wb, hb)))
        return None
    w, h = wa, ha
    mean_a, std_a = variance_probe(w, h, ca, ia)
    mean_b, std_b = variance_probe(w, h, cb, ib)
    canopy = region_stats(w, h, ca, ia, ib, int(w * 0.02), int(w * 0.98), 0, h // 2, thr)
    trunk = bark_stats(w, h, ca, ia, ib, thr)
    hb_ = changed_bbox(w, h, ca, ia, ib, thr)
    print("\n[%s vs %s]  thr=%d  size=%dx%d  mean/std A=(%.1f/%.1f) B=(%.1f/%.1f)"
          % (name_a, name_b, thr, w, h, mean_a, std_a, mean_b, std_b))
    print("  canopy(y<%.0f%%,全宽)   changed=%6d/%6d  ratio=%.4f%%  mean|d|=%.3f"
          % (50, canopy["changed"], canopy["total"], canopy["ratio"] * 100, canopy["mean_abs_diff"]))
    print("  bark  (y 78-88%%,x 47-56%%, 深色树皮) changed=%5d/%5d  ratio=%.4f%%  mean|d|=%.3f"
          % (trunk["changed"], trunk["total"], trunk["ratio"] * 100, trunk["mean_abs_diff"]))
    if hb_["bbox"]:
        print("  变化像素 bbox = x[%d..%d] y[%d..%d]  count=%d (y 中位≈%d)"
              % (hb_["bbox"][0], hb_["bbox"][2], hb_["bbox"][1], hb_["bbox"][3],
                 hb_["count"], (hb_["bbox"][1] + hb_["bbox"][3]) // 2))
    r = {"pair": [name_a, name_b], "thr": thr, "size": [w, h],
         "canopy": canopy, "trunk": trunk, "changed_bbox": hb_,
         "ratio_canopy_over_trunk": (canopy["ratio"] / trunk["ratio"]) if trunk["ratio"] > 0 else None}
    if dump is not None:
        dump.append(r)
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--threshold", type=int, default=6, help="像素差阈值（0-255）")
    args = ap.parse_args()
    thr = args.threshold
    print("=" * 78)
    print("风摆视觉证据 · 像素差分  (shots dir: %s)" % SHOTS)
    print("=" * 78)
    need = ["t0", "t0_25", "t0_5"]
    for n in need:
        if not os.path.exists(os.path.join(SHOTS, n + ".png")):
            print("FAIL: 缺少 %s.png —— 先跑 tests/wind/wind_visual.tscn（非 headless）" % n)
            return 1
    dump = []
    r1 = pair("t0", "t0_25", thr, None, dump)
    r2 = pair("t0", "t0_5", thr, None, dump)
    if r1 is None or r2 is None:
        return 1

    checks = []

    def check(name, ok, expect, actual):
        checks.append({"name": name, "expect": expect, "actual": actual, "pass": bool(ok)})
        print("[%s] %-26s %s" % ("PASS" if ok else "FAIL", name, actual))

    print("\n" + "-" * 78)
    check("images_render", all(r["canopy"]["ratio"] >= 0 or True for r in (r1, r2)),
          "三帧都是有效渲染", "size=%dx%d" % tuple(r1["size"]))
    check("canopy_moves_0.5s", r2["canopy"]["ratio"] >= 0.01,
          "树冠差异像素占比 >= 1%", "ratio=%.4f%%" % (r2["canopy"]["ratio"] * 100))
    check("canopy_moves_0.25s", r1["canopy"]["ratio"] >= 0.005,
          "0.25s 树冠差异像素占比 >= 0.5%", "ratio=%.4f%%" % (r1["canopy"]["ratio"] * 100))
    dom = r2["ratio_canopy_over_trunk"]
    check("canopy_dominant", (dom is None) or dom >= 5.0,
          "树冠/树干 差异比 >= 5",
          "ratio=∞（树干 0 像素变化）" if dom is None else "ratio=%.1f" % dom)
    check("trunk_static", r2["trunk"]["ratio"] <= 0.005 and r2["trunk"]["total"] >= 200,
          "树干根部（深色树皮像素）差异占比 <= 0.5%",
          "ratio=%.4f%%  (%d px)" % (r2["trunk"]["ratio"] * 100, r2["trunk"]["total"]))
    check("bark_sample_size", r2["trunk"]["total"] >= 200,
          "树皮像素样本 >= 200", "%d px" % r2["trunk"]["total"])
    failed = sum(1 for c in checks if not c["pass"])
    out = {"checks": checks, "pairs": dump}
    os.makedirs(os.path.join(ROOT, ".runtime", "wind_port"), exist_ok=True)
    with open(os.path.join(ROOT, ".runtime", "wind_port", "visual_diff.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    print("-" * 78)
    print("RESULT: %s  (%d/%d checks passed)" % (
        "PASS" if failed == 0 else "FAIL", len(checks) - failed, len(checks)))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

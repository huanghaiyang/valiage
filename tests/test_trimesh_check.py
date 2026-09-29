# -*- coding: utf-8 -*-
"""三角网校验器（tools/trimesh_check.py）的回归测试。

跑法：
    cd <项目根>
    python tests/test_trimesh_check.py

每个检查项都用**单独隔离**的缺陷网格验证（缺陷叠在一起会互相掩盖，之前就吃过亏：
把"翻转的面"做成了原面的完全重复，结果被算成"重复面"而不是"绕序冲突"）。
真实场景文件的顺带体检是可选的（文件不在就跳过）。
"""

from __future__ import annotations

import os
import re
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from trimesh_check import analyze, clean, format_report  # noqa: E402

A, B, C, D = (0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0)
TETRA = [(A, C, B), (A, B, D), (A, D, C), (B, C, D)]          # 4 面闭合、绕序一致
# 把 (A,D,C) 翻转（注意不能用 (B,D,A)——那正好是 (A,B,D) 的重复面）
FLIP_ONE = [(A, C, B), (A, B, D), (C, D, A), (B, C, D)]

_failed = 0


def check(name, tris, **expect):
    global _failed
    rep = analyze(tris)
    bad = {k: (rep[k], v) for k, v in expect.items() if rep[k] != v}
    if bad:
        _failed += 1
        print("  [!] %s -> %s" % (name, bad))
    else:
        print("  [OK] %s" % name)
    return rep


def main():
    print("=== 每个检查项单独验证 ===")
    check("干净闭合四面体", TETRA, faces=4, boundary_edges=0, nonmanifold_edges=0,
          nonmanifold_vertices=0, winding_inconsistent_edges=0,
          degenerate_faces=0, duplicate_faces=0)
    check("+1 个退化面", TETRA + [(A, A, B)], degenerate_faces=1,
          duplicate_faces=0, winding_inconsistent_edges=0)
    check("+1 个重复面", TETRA + [(A, C, B)], duplicate_faces=1,
          degenerate_faces=0, winding_inconsistent_edges=0)
    check("+1 个面压在同一条边上（非流形边）", TETRA + [(A, B, (0.0, 0.0, -1.0))],
          nonmanifold_edges=1, nonmanifold_vertices=0, winding_inconsistent_edges=0)
    check("+1 个面只共顶点（蝴蝶结）", TETRA + [(A, (2.0, 0.0, 0.0), (0.0, 2.0, 0.0))],
          nonmanifold_vertices=1, nonmanifold_edges=0)
    rep = check("翻转 1 个面（绕序冲突）", FLIP_ONE,
                winding_inconsistent_edges=3, duplicate_faces=0)

    fixed, stats = clean(FLIP_ONE, rep, fix_winding=True)
    check("清理+修绕序后", fixed, winding_inconsistent_edges=0, duplicate_faces=0)
    print("  清理统计：%s" % stats)
    # 这四条断言是用来防"清理把好面误删"的：4 个面一个都不能少，只该翻 1 个
    if stats["kept"] != 4 or stats["dropped_duplicate"] != 0 or stats["flipped"] != 1:
        global _failed
        _failed += 1
        print("  [!] 清理统计不对：应 kept=4 dropped_duplicate=0 flipped=1，实际 %s" % stats)
    else:
        print("  [OK] 清理没有误删面（kept=4，只翻 1 个）")

    print("\n=== 可选：顺带体检项目里的真实场景 ===")
    found = None
    for name in os.listdir(os.path.join(ROOT, "scenes", "墓园")) if os.path.isdir(
            os.path.join(ROOT, "scenes", "墓园")) else []:
        if name.endswith(".tscn"):
            found = os.path.join(ROOT, "scenes", "墓园", name)
    sc = found or os.path.join(ROOT, "scenes", "墓园", "墓地地面.tscn")
    if os.path.isfile(sc):
        text = open(sc, encoding="utf-8", errors="surrogateescape").read()
        m = re.search(r"data = PackedVector3Array\(([^)]*)\)", text)
        if m:
            nums = [float(t) for t in m.group(1).split(",") if t.strip()]
            tris = [((nums[i], nums[i + 1], nums[i + 2]),
                     (nums[i + 3], nums[i + 4], nums[i + 5]),
                     (nums[i + 6], nums[i + 7], nums[i + 8]))
                    for i in range(0, len(nums), 9)]
            t0 = time.time()
            print("文件 %s（%d 面）" % (os.path.basename(sc), len(tris)))
            print(format_report(analyze(tris)))
            print("分析耗时 %.1f 秒" % (time.time() - t0))
    else:
        print("（没有可体检的场景，跳过）")

    print("\n%s" % ("全部检查项通过" if _failed == 0 else "有 %d 项不符合预期" % _failed))
    return 1 if _failed else 0


if __name__ == "__main__":
    sys.exit(main())

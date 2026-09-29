#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""三角网碰撞的拓扑 / 流形校验，以及可选的自动清理。

检查项与"对碰撞意味着什么"：

  * **退化面**（面积为 0 / 有重合顶点）—— 物理里是垃圾数据，建议清掉。
  * **重复面**（同三个顶点出现多次）—— 冗余，建议清掉。
  * **边界边**（只被 1 个面用到）—— 说明网格是**开放**的。静态三角网碰撞**允许**开放
    （不是必须水密），但数量异常多通常意味着抽面把面片打碎了。
  * **非流形边**（被 ≥3 个面用到）—— 真问题：物理里会出现不可预测的接触。
  * **非流形顶点**（蝴蝶结：顶点周围的面不连通）—— 真问题，同样建议修。
  * **绕序一致性**（共享边在两个面里方向是否相反）—— **对碰撞最要命**：
    `ConcavePolygonShape3D.backface_collision` 默认 false，绕序反了的那部分会变成
    "单向墙"（从背面能穿过去），而在视口里完全看不出来。
  * **自交**：本工具**不检查**（成本高；静态碰撞里自交通常无害）。

用法:
  python tools/trimesh_check.py --in faces.f32              # 打印报告
  python tools/trimesh_check.py --in faces.f32 --json       # 额外输出一行 JSON
  python tools/trimesh_check.py --in faces.f32 --clean --out fixed.f32 [--fix-winding]
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from raw_faces import read_raw_triangles, write_raw_faces  # noqa: E402

# Windows 控制台/管道的编码千奇百怪（GBK/UTF-8/cp1252），宁可丢字符也别让打印崩掉。
# 插件那边不依赖 stdout，而是读 --report 写出的 UTF-8 文件。
try:
    sys.stdout.reconfigure(errors="replace")
except Exception:
    pass

AREA_EPS = 1e-12


def _area(a, b, c) -> float:
    ux, uy, uz = b[0] - a[0], b[1] - a[1], b[2] - a[2]
    vx, vy, vz = c[0] - a[0], c[1] - a[1], c[2] - a[2]
    cx, cy, cz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
    return 0.5 * math.sqrt(cx * cx + cy * cy + cz * cz)


def analyze(tris, weld_digits: int = 6) -> dict:
    """对三角面列表做拓扑分析，返回指标字典。"""
    def key(v):
        return (round(v[0], weld_digits), round(v[1], weld_digits), round(v[2], weld_digits))

    vid: dict = {}
    faces = []
    for tri in tris:
        idx = []
        for v in tri:
            k = key(v)
            j = vid.get(k)
            if j is None:
                j = len(vid)
                vid[k] = j
            idx.append(j)
        faces.append(tuple(idx))

    degenerate = []
    for i, f in enumerate(faces):
        if len({f[0], f[1], f[2]}) < 3 or _area(tris[i][0], tris[i][1], tris[i][2]) <= AREA_EPS:
            degenerate.append(i)

    seen: set = set()
    duplicate = 0
    for f in faces:
        s = tuple(sorted(f))
        if s in seen:
            duplicate += 1
        else:
            seen.add(s)

    # 边 -> [(面下标, 该面里这条边的方向)]；方向 +1 表示在面里按 (小, 大) 走
    edges: dict = {}
    for fi, f in enumerate(faces):
        for a, b in ((f[0], f[1]), (f[1], f[2]), (f[2], f[0])):
            k = (a, b) if a < b else (b, a)
            edges.setdefault(k, []).append((fi, 1 if a < b else -1))

    boundary = sum(1 for v in edges.values() if len(v) == 1)
    nonmanifold_edges = sum(1 for v in edges.values() if len(v) >= 3)
    # 绕序：共享边（正好 2 个面）应当是相反方向
    winding_bad = sum(1 for v in edges.values() if len(v) == 2 and v[0][1] == v[1][1])

    # 非流形顶点（蝴蝶结）：该顶点周围的面，通过"同样含该顶点的边"连不起来
    inc: dict = {}
    for fi, f in enumerate(faces):
        for v in set(f):
            inc.setdefault(v, []).append(fi)
    bowties = 0
    for v, fl in inc.items():
        if len(fl) < 2:
            continue
        flset = set(fl)
        # 建邻接：两个面共享一条含 v 的边
        adj: dict = {fi: set() for fi in fl}
        for e, users in edges.items():
            if v != e[0] and v != e[1]:
                continue
            us = [u for u, _d in users if u in flset]
            for i in range(len(us)):
                for j in range(i + 1, len(us)):
                    adj[us[i]].add(us[j])
                    adj[us[j]].add(us[i])
        # 连通分量数
        left = set(fl)
        comps = 0
        while left:
            comps += 1
            stack = [left.pop()]
            while stack:
                cur = stack.pop()
                for nb in adj[cur]:
                    if nb in left:
                        left.discard(nb)
                        stack.append(nb)
        if comps > 1:
            bowties += 1

    return {
        "faces": len(faces),
        "vertices": len(vid),
        "edges": len(edges),
        "degenerate_faces": len(degenerate),
        "duplicate_faces": duplicate,
        "boundary_edges": boundary,
        "nonmanifold_edges": nonmanifold_edges,
        "nonmanifold_vertices": bowties,
        "winding_inconsistent_edges": winding_bad,
        "weld_digits": weld_digits,
        "degenerate_indices": degenerate,
    }


def clean(tris, report: dict, fix_winding: bool = False):
    """丢掉退化面/重复面；可选地把绕序统一（按共享边传播朝向）。返回 (新面, 统计)。"""
    drop = set(report["degenerate_indices"])
    keep = []
    seen: set = set()
    dropped_dup = 0
    for i, tri in enumerate(tris):
        if i in drop:
            continue
        # 去重键必须按"三个顶点"排序；把 9 个坐标整体排序会把不同面判成同一张
        # （(A,C,B) 与 (A,B,D) 的坐标多重集恰好相同 -> 会被误删，实测四面体被删到只剩 2 面）
        key = tuple(sorted(tuple(round(c, report["weld_digits"]) for c in v) for v in tri))
        if key in seen:
            dropped_dup += 1
            continue
        seen.add(key)
        keep.append([list(v) for v in tri])

    flipped = 0
    if fix_winding and keep:
        # 用位置做顶点 id
        def key(v):
            return tuple(round(c, report["weld_digits"]) for c in v)
        vid: dict = {}
        faces = []
        for tri in keep:
            idx = []
            for v in tri:
                k = key(v)
                j = vid.get(k)
                if j is None:
                    j = len(vid)
                    vid[k] = j
                idx.append(j)
            faces.append(idx)
        # 边 -> 面
        e2f: dict = {}
        for fi, f in enumerate(faces):
            for a, b in ((f[0], f[1]), (f[1], f[2]), (f[2], f[0])):
                k = (a, b) if a < b else (b, a)
                e2f.setdefault(k, []).append(fi)
        visited = [False] * len(faces)
        for seed in range(len(faces)):
            if visited[seed]:
                continue
            visited[seed] = True
            stack = [seed]
            while stack:
                fi = stack.pop()
                f = faces[fi]
                for a, b in ((f[0], f[1]), (f[1], f[2]), (f[2], f[0])):
                    k = (a, b) if a < b else (b, a)
                    users = e2f.get(k, ())
                    # 只在"正好两个面共享"的边上传播朝向：非流形边(≥3)和边界边(1)上
                    # 朝向本来就没有定义，顺着它们传播只会把错误扩散出去（实测会把
                    # 冲突从 6 条搞到 690 条）
                    if len(users) != 2:
                        continue
                    for nb in users:
                        if nb == fi or visited[nb]:
                            continue
                        g = faces[nb]
                        d1 = 1 if (f[0], f[1]) == k or (f[1], f[2]) == k or (f[2], f[0]) == k else -1
                        d2 = 1 if (g[0], g[1]) == k or (g[1], g[2]) == k or (g[2], g[0]) == k else -1
                        if d1 == d2:      # 同向 -> 需要翻
                            faces[nb] = [g[0], g[2], g[1]]
                            keep[nb] = [keep[nb][0], keep[nb][2], keep[nb][1]]
                            flipped += 1
                        visited[nb] = True
                        stack.append(nb)

    out = [tuple(tuple(v) for v in tri) for tri in keep]
    return out, {"dropped_degenerate": len(drop), "dropped_duplicate": dropped_dup,
                 "flipped": flipped, "kept": len(out)}


def summary_line(rep: dict) -> str:
    """一行摘要：插件读这一行显示，人也能直接看。"""
    bad = (rep["degenerate_faces"] + rep["nonmanifold_edges"]
           + rep["nonmanifold_vertices"] + rep["winding_inconsistent_edges"])
    return ("TOPOLOGY %s 面=%d 退化=%d 重复=%d 非流形边=%d 蝴蝶结=%d 绕序冲突=%d 边界边=%d"
            % ("OK" if bad == 0 else "WARN", rep["faces"], rep["degenerate_faces"],
               rep["duplicate_faces"], rep["nonmanifold_edges"],
               rep["nonmanifold_vertices"], rep["winding_inconsistent_edges"],
               rep["boundary_edges"]))


def format_report(rep: dict) -> str:
    lines = []
    lines.append("三角面 %d ／ 焊接后顶点 %d ／ 边 %d（坐标按 %d 位小数焊接）"
                 % (rep["faces"], rep["vertices"], rep["edges"], rep["weld_digits"]))
    lines.append("退化面 %d ／ 重复面 %d" % (rep["degenerate_faces"], rep["duplicate_faces"]))
    lines.append("边界边 %d（开放网格；静态三角网碰撞允许不水密）" % rep["boundary_edges"])
    lines.append("非流形边 %d ／ 非流形顶点(蝴蝶结) %d"
                 % (rep["nonmanifold_edges"], rep["nonmanifold_vertices"]))
    if rep["winding_inconsistent_edges"] == 0:
        lines.append("绕序：一致 [OK]（backface_collision=false 时不会被单向穿墙）")
    else:
        lines.append("绕序：**%d 条共享边朝向冲突** [!] —— backface_collision 关闭时这部分是单向墙"
                     % rep["winding_inconsistent_edges"])
    bad = (rep["degenerate_faces"] + rep["nonmanifold_edges"]
           + rep["nonmanifold_vertices"] + rep["winding_inconsistent_edges"])
    lines.append("结论：%s" % ("可直接用作静态三角网碰撞 [OK]" if bad == 0
                             else "有 %d 项建议修（可用 --clean 自动清理）" % bad))
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description="三角网碰撞拓扑校验")
    ap.add_argument("--in", dest="src", required=True, help="输入裸三角面文件（.f32）")
    ap.add_argument("--json", action="store_true", help="额外输出一行 JSON 结果")
    ap.add_argument("--clean", action="store_true", help="顺手清理退化面/重复面")
    ap.add_argument("--fix-winding", action="store_true", help="并把绕序统一（需配合 --clean）")
    ap.add_argument("--out", default=None, help="清理结果写到哪里（.f32）")
    ap.add_argument("--report", default=None,
                    help="把报告写成 UTF-8 文件（给插件读；不要依赖调用方解码 stdout）")
    args = ap.parse_args()

    tris = read_raw_triangles(args.src)
    rep = analyze(tris)
    print(format_report(rep))
    if args.json:
        slim = {k: v for k, v in rep.items() if k != "degenerate_indices"}
        print("JSON " + json.dumps(slim, ensure_ascii=False))

    if args.clean:
        out, stats = clean(tris, rep, args.fix_winding)
        print("清理：丢退化 %d ／ 丢重复 %d ／ 翻转 %d ／ 保留 %d 面"
              % (stats["dropped_degenerate"], stats["dropped_duplicate"],
                 stats["flipped"], stats["kept"]))
        if args.out:
            write_raw_faces(out, args.out)
            print("已写出 " + args.out)
        after = analyze(out)
        print("清理后：" + format_report(after).splitlines()[-1])

    if args.report:
        lines = [format_report(rep)]
        if args.clean:
            lines.append("清理：丢退化 %d ／ 丢重复 %d ／ 翻转 %d ／ 保留 %d 面"
                         % (stats["dropped_degenerate"], stats["dropped_duplicate"],
                            stats["flipped"], stats["kept"]))
            lines.append("清理后：" + format_report(after).splitlines()[-1])
        with open(args.report, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines))


if __name__ == "__main__":
    main()

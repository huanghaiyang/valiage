#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""「凹多边形碰撞调参」插件用的桥：把一堆三角面按比例抽面。

输入/输出都是**裸 float32 三角面**（每 9 个 float 一个三角形，非索引展开），
这样 GDScript 侧只要 dump / load 二进制，插件里不用解析 GLB。

用法:
  # 插件走这条：从 Godot 导出的裸三角面 -> 抽面 -> 裸三角面
  python tools/mesh_decimate.py --in faces.f32 --ratio 0.02 --out faces_low.f32

  # 也支持直接从模型取（方便命令行验证）
  python tools/mesh_decimate.py --from-glb assets/models/buildings/墓地地面.glb \
      --mesh-index 0 --ratio 0.02 --out faces_low.f32

参数:
  --ratio  目标面数比例（相对输入面数），默认 0.02
  --error  几何误差上限（占网格半径），默认 0.5；设小更贴合但减不了那么多
"""

from __future__ import annotations

import argparse
import os
import struct
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from raw_faces import read_raw_triangles, write_raw_faces  # noqa: E402
from simplify_collision import (  # noqa: E402
    find_project_root,
    glb_triangle_count,
    glb_triangles,
    resolve_executable,
    run,
    write_position_only_glb,
    write_positions_glb,
)
from trimesh_check import analyze, clean, summary_line  # noqa: E402

# 控制台编码不可信（GBK/UTF-8/cp1252），打印宁可丢字符也别崩；插件走 --report 文件
try:
    sys.stdout.reconfigure(errors="replace")
except Exception:
    pass


def main():
    ap = argparse.ArgumentParser(description="抽面（裸三角面进 / 裸三角面出）")
    ap.add_argument("--in", dest="src", default=None, help="输入裸三角面文件（.f32）")
    ap.add_argument("--from-glb", default=None, help="也可以直接从 GLB 取面")
    ap.add_argument("--mesh-index", type=int, default=0, help="配合 --from-glb 用")
    ap.add_argument("--out", required=True, help="输出裸三角面文件（.f32）")
    ap.add_argument("--ratio", type=float, default=0.02, help="目标面数比例，默认 0.02")
    ap.add_argument("--error", type=float, default=0.5, help="几何误差上限，默认 0.5")
    ap.add_argument("--clean", action="store_true",
                    help="顺手清掉退化面/重复面（抽面后经常出现）")
    ap.add_argument("--fix-winding", action="store_true",
                    help="并把绕序统一（backface_collision 关闭时，绕序反了会变单向墙）")
    ap.add_argument("--project", default=None, help="项目根目录（默认从工具位置推断）")
    ap.add_argument("--report", default=None,
                    help="把结果摘要写成 UTF-8 文件（给插件读；不要依赖调用方解码 stdout）")
    args = ap.parse_args()

    if bool(args.src) == bool(args.from_glb):
        sys.exit("--in 和 --from-glb 必须二选一")

    project_root = args.project or find_project_root(os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "x"))
    npx = resolve_executable("npx")
    if npx is None:
        sys.exit("找不到 npx（需要 Node.js/npm：抽面靠 @gltf-transform/cli 里的 meshoptimizer）")
    env = dict(os.environ)
    env.setdefault("npm_config_cache", os.path.join(project_root, ".runtime", "npm-cache"))
    os.makedirs(env["npm_config_cache"], exist_ok=True)

    tmp_dir = tempfile.mkdtemp(prefix="mesh_decimate_")
    try:
        src_glb = os.path.join(tmp_dir, "src.glb")
        welded = os.path.join(tmp_dir, "welded.glb")
        out_glb = os.path.join(tmp_dir, "out.glb")

        if args.from_glb:
            write_position_only_glb(args.from_glb, src_glb, args.mesh_index)
            in_faces = glb_triangle_count(args.from_glb, args.mesh_index)
        else:
            tris_in = read_raw_triangles(args.src)
            in_faces = len(tris_in)
            write_positions_glb([v for tri in tris_in for v in tri], src_glb)

        # weld：裸三角面是"未焊"的，先焊接出连通性，简化才有东西可抽
        run([npx, "--yes", "@gltf-transform/cli", "weld", src_glb, welded], env=env)
        run([npx, "--yes", "@gltf-transform/cli", "simplify", welded, out_glb,
             "--ratio", "%.6f" % max(0.0, min(1.0, args.ratio)),
             "--error", "%g" % args.error, "--lock-border", "false"], env=env)

        tris = glb_triangles(out_glb)
        if not tris:
            sys.exit("抽面后没有三角面")
        rep = analyze(tris)
        stats = None
        if args.clean or args.fix_winding:
            tris, stats = clean(tris, rep, args.fix_winding)
        written = write_raw_faces(tris, args.out)
        lines = ["输入 %s 面 -> 输出 %d 面 (%.3f%%)" % (
            in_faces if in_faces is not None else "?", written,
            100.0 * written / in_faces if in_faces else 0.0)]
        if stats:
            lines.append("清理：丢退化 %d ／ 丢重复 %d ／ 翻绕序 %d" % (
                stats["dropped_degenerate"], stats["dropped_duplicate"], stats["flipped"]))
        lines.append(summary_line(analyze(tris) if stats else rep))
        for line in lines:
            print(line)
        if args.report:
            # 插件读这个 UTF-8 文件：Godot 的 OS.execute 在 Windows 上按系统
            # ANSI 代码页解码子进程输出，中文会变乱码，不能依赖它
            with open(args.report, "w", encoding="utf-8") as fh:
                fh.write("\n".join(lines))
    finally:
        import shutil
        shutil.rmtree(tmp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()

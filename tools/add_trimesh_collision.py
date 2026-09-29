#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给场景里已有的 StaticBody3D 补一个三角网碰撞（ConcavePolygonShape3D）。

适用场景：包装场景里已经有 `MeshInstance3D → StaticBody3D`，但缺 `CollisionShape3D`
（编辑器里「网格 → 创建碰撞形状 → 三角网格」对超高模会很慢、而且会把**全量**三角面
写进 .tscn，让文件涨到几百 MB、物理 BVH 也吃不消）。本工具直接按目标面数生成。

流程：
  1. 从场景里找到目标 StaticBody3D（默认取第一个），确认它还没有 CollisionShape3D
  2. 找到源模型（场景里的贴图名 / --glb 指定），用 `--mesh-index` 取对应网格
  3. 校对该网格与场景内联网格的 AABB（防拿错网格）
  4. 剥属性 → weld → simplify（meshoptimizer）到目标比例
  5. 把结果按 Godot 的格式写进 .tscn：新增一个 ConcavePolygonShape3D 子资源 +
     StaticBody3D 下的 CollisionShape3D 节点

用法:
  python tools/add_trimesh_collision.py scenes/墓园/墓园地面.tscn --glb assets/models/buildings/墓地场景3d模型.glb --mesh-index 0
  python tools/add_trimesh_collision.py scenes/xxx.tscn --ratio 0.05 --error 0.005
  python tools/add_trimesh_collision.py scenes/xxx.tscn --dry-run     # 只看数，不改文件

关键参数:
  --ratio   目标面数比例（相对该网格原始面数），默认 0.02 = 2%
  --error   几何误差上限，占网格半径的比例，默认 0.005（0.5%，地面类要保精度）
            —— 误差先到顶就停，所以实际面数可能高于目标；这比"硬减到 2%"安全。

注意:
  * 顶点写在网格自身的顶点空间里（和 Godot「创建碰撞形状」一致）。
  * 碰撞体默认沿用 StaticBody3D 已有的 collision_layer/mask（本项目建筑/树 = 4）。
"""

from __future__ import annotations

import argparse
import os
import random
import re
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from simplify_collision import (  # noqa: E402
    build_data_line,
    glb_triangle_count,
    glb_triangles,
    load_glb,
    resolve_executable,
    run,
    write_position_only_glb,
)

_AABB_RE = re.compile(r'"aabb": AABB\(([^)]*)\)')
_NODE_RE = re.compile(r'^\[node name="([^"]+)" type="([^"]+)" parent="([^"]*)"')
_SUB_ID_RE = re.compile(r'^\[sub_resource type="(\w+)" id="([^"]+)"')


def find_project_root(start):
    """从 start 往上找含 project.godot 的目录（场景可能在 scenes/子目录 下，不能只上两级）。"""
    cur = os.path.dirname(os.path.abspath(start))
    while True:
        if os.path.isfile(os.path.join(cur, "project.godot")):
            return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            return os.path.dirname(os.path.abspath(start))
        cur = parent


def find_body(text):
    """返回 (name, parent, 报文行号)；找不到返回 None。"""
    for lineno, line in enumerate(text.split("\n")):
        m = _NODE_RE.match(line)
        if m and m.group(2) == "StaticBody3D":
            return m.group(1), m.group(3), lineno
    return None


def body_has_shape(text, body_parent, body_name):
    child_path = (body_parent + "/" + body_name) if body_parent else body_name
    for line in text.split("\n"):
        m = _NODE_RE.match(line)
        if m and m.group(3) == child_path and m.group(2) in ("CollisionShape3D", "CollisionPolygon3D"):
            return m.group(1)
    return None


def scene_mesh_aabb(text, node_name=None):
    """取场景里第一个（或指定节点之后的）内联网格 AABB。"""
    matches = list(_AABB_RE.finditer(text))
    if not matches:
        return None
    m = matches[0] if node_name is None else matches[-1]
    return [float(v) for v in m.group(1).split(",")]


def detect_glb(text, project_root):
    """从场景里的贴图路径猜源模型。
    贴图名形如 <模型名>_<...>_tripo_part_0_basecolor.jpg，模型名取第一个下划线前那段。"""
    m = re.search(r'path="res://[^"]*?/([^"/_]+)_[^"/]*basecolor\.jpg"', text)
    if not m:
        return None
    stem = m.group(1)
    for root, _dirs, files in os.walk(os.path.join(project_root, "assets")):
        for f in files:
            if f == stem + ".glb":
                return os.path.join(root, f)
    return None


def new_unique_id(text):
    used = set(int(v) for v in re.findall(r"unique_id=(\d+)", text))
    while True:
        cand = random.randint(100000000, 2000000000)
        if cand not in used:
            return cand


def main():
    ap = argparse.ArgumentParser(description="给 StaticBody3D 补三角网碰撞")
    ap.add_argument("scene", help="场景 .tscn 路径")
    ap.add_argument("--glb", default=None, help="源模型；默认从场景贴图名推断")
    ap.add_argument("--mesh-index", type=int, default=0, help="取源模型的第几个网格，默认 0")
    ap.add_argument("--ratio", type=float, default=0.02, help="目标面数比例，默认 0.02")
    ap.add_argument("--error", type=float, default=0.005, help="几何误差上限（占网格半径），默认 0.005")
    ap.add_argument("--body", default=None, help="指定 StaticBody3D 的节点名（默认第一个）")
    ap.add_argument("--no-backup", action="store_true")
    ap.add_argument("--dry-run", action="store_true", help="只报告不写文件")
    args = ap.parse_args()

    scene = os.path.abspath(args.scene)
    if not os.path.isfile(scene):
        sys.exit("场景不存在: %s" % scene)
    with open(scene, "r", encoding="utf-8", errors="surrogateescape") as fh:
        text = fh.read()
    project_root = find_project_root(scene)

    body = find_body(text)
    if body is None:
        sys.exit("场景里没有 StaticBody3D；请先在编辑器里给网格加一个（或告诉我节点名）")
    body_name, body_parent, _lineno = body
    if args.body and body_name != args.body:
        sys.exit("指定的 StaticBody3D 名字不对：场景里是 %s" % body_name)
    existing = body_has_shape(text, body_parent, body_name)
    if existing:
        sys.exit("这个 StaticBody3D 已经有碰撞形状了（%s），不重复添加" % existing)

    glb = args.glb or detect_glb(text, project_root)
    if not glb or not os.path.isfile(glb):
        sys.exit("找不到源模型，请用 --glb 指定（推断结果: %s）" % glb)

    raw_tris = glb_triangle_count(glb, args.mesh_index)
    target = max(4, int(raw_tris * args.ratio))
    print("场景        : %s (%.2f MB)" % (scene, os.path.getsize(scene) / 1048576))
    print("碰撞体父节点: %s/%s" % (body_parent, body_name))
    print("源模型      : %s  网格[%d]" % (glb, args.mesh_index))
    print("原始面数    : %d  -> 目标 %d 面 (比例 %.4f)" % (raw_tris, target, args.ratio))

    # AABB 校对：确认拿的是场景里那块网格
    js, _blob = load_glb(glb)
    acc = js["accessors"][js["meshes"][args.mesh_index]["primitives"][0]["attributes"]["POSITION"]]
    glb_min, glb_max = list(acc["min"]), list(acc["max"])
    scene_aabb = scene_mesh_aabb(text)
    if scene_aabb:
        s_min = scene_aabb[:3]
        s_max = [scene_aabb[0] + scene_aabb[3], scene_aabb[1] + scene_aabb[4],
                 scene_aabb[2] + scene_aabb[5]]
        drift = max(max(abs(a - b) for a, b in zip(glb_min, s_min)),
                    max(abs(a - b) for a, b in zip(glb_max, s_max)))
        print("AABB 校对   : 偏差 %.6f  (%s)" % (drift, "一致 ✓" if drift < 1e-4 else "不一致，请核对网格索引！"))
        if drift >= 1e-3:
            sys.exit("源网格和场景内联网格不是同一块几何，已放弃")

    npx = resolve_executable("npx")
    if npx is None:
        sys.exit("找不到 npx：需要 Node.js/npm")
    env = dict(os.environ)
    env.setdefault("npm_config_cache", os.path.join(project_root, ".runtime", "npm-cache"))
    os.makedirs(env["npm_config_cache"], exist_ok=True)

    tmp_dir = tempfile.mkdtemp(prefix="add_collision_")
    try:
        pos_only = os.path.join(tmp_dir, "position_only.glb")
        welded = os.path.join(tmp_dir, "welded.glb")
        simplified = os.path.join(tmp_dir, "simplified.glb")
        verts, stripped = write_position_only_glb(glb, pos_only, args.mesh_index)
        print("剥离属性    : 顶点 %d 三角面 %d（UV/法线接缝会锁死简化）" % (verts, stripped))
        run([npx, "--yes", "@gltf-transform/cli", "weld", pos_only, welded], env=env)
        run([npx, "--yes", "@gltf-transform/cli", "simplify", welded, simplified,
             "--ratio", "%.6f" % min(1.0, target / float(raw_tris)),
             "--error", "%g" % args.error, "--lock-border", "false"], env=env)
        tris = glb_triangles(simplified)
        print("结果        : %d 面 (%.2f%% of %d)" % (len(tris), 100.0 * len(tris) / raw_tris, raw_tris))
        if not tris:
            sys.exit("简化后没有三角面，已放弃（原文件不动）")

        shape_id = "ConcavePolygonShape3D_%s" % os.urandom(2).hex()
        shape_block = '[sub_resource type="ConcavePolygonShape3D" id="%s"]\n%s\n' % (
            shape_id, build_data_line(tris))

        # 子资源必须插在第一个 [node 之前
        first_node = text.find("[node ")
        if first_node < 0:
            sys.exit("场景里没有节点块，格式不符合预期")
        child_path = (body_parent + "/" + body_name) if body_parent else body_name
        node_block = ('\n[node name="CollisionShape3D" type="CollisionShape3D" '
                      'parent="%s" unique_id=%d]\nshape = SubResource("%s")\n'
                      % (child_path, new_unique_id(text), shape_id))
        new_text = text[:first_node] + shape_block + "\n" + text[first_node:]
        if not new_text.endswith("\n"):
            new_text += "\n"
        new_text += node_block

        if args.dry_run:
            print("[dry-run] 不写文件。预计场景 %.2f MB" %
                  (len(new_text.encode("utf-8", "surrogateescape")) / 1048576))
            return

        old_mb = os.path.getsize(scene) / 1048576
        if not args.no_backup:
            bdir = os.path.join(project_root, ".runtime", "collision_backups")
            os.makedirs(bdir, exist_ok=True)
            shutil.copy2(scene, os.path.join(bdir, os.path.basename(scene) + ".bak"))
        with open(scene, "w", encoding="utf-8", errors="surrogateescape", newline="") as fh:
            fh.write(new_text)
        print("完成        : 新增 CollisionShape3D 于 %s，场景 %.2f MB -> %.2f MB" % (
            child_path, old_mb, os.path.getsize(scene) / 1048576))
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()

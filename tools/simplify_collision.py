#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把包装场景里的三角网碰撞（ConcavePolygonShape3D）精简到指定比例。

背景：用编辑器「网格 → 创建碰撞形状 → 三角网格」给高模做碰撞，会把模型**全量**
三角面写进 .tscn 的 `data = PackedVector3Array(...)` 里。复杂模型（90 万面）会让
.tscn 涨到 80+ MB，物理端还要为它建一棵同样巨大的 BVH，帧率和内存都吃不消。

流程（4 步）：
  1. 从 .tscn 读出当前碰撞三角面数，以及它引用的 .glb（ext_resource）
  2. 把模型另存一份**只保留 POSITION + 索引**的副本 —— 关键一步：
     meshoptimizer 会被 UV/法线接缝锁住（扫描类模型 UV 岛极多），实测带属性时
     无论如何都只能减到 ~10.9%，剥掉属性后同一比例能到 1%。
  3. weld + simplify（`--error 1 --lock-border false`）到目标面数，解出三角面
  4. 按 Godot 的序列化格式写回 .tscn（其余内容逐字节不动）

用法:
  python tools/simplify_collision.py scenes/破碎家园_mid.tscn            # 默认精简到 1%
  python tools/simplify_collision.py scenes/xxx.tscn --ratio 0.05       # 精简到 5%
  python tools/simplify_collision.py scenes/xxx.tscn --dry-run          # 只看数不改文件
  python tools/simplify_collision.py scenes/xxx.tscn --no-backup        # 不生成 .bak

注意:
  * 1% 是**很激进**的抽面：薄墙、细柱、栏杆这类结构可能塌掉，碰撞会漏（能穿墙）。
    改完务必实机走一遍建筑内部；要更稳就把 --ratio 放到 0.05~0.1。
  * 只处理 `ConcavePolygonShape3D`；`ConvexPolygonShape3D`/基本体本来就很省。
  * 顶点空间按模型自身的顶点空间处理（Godot 的「创建碰撞形状」就是这么写的）。
  * 会先备份到 <场景>.bak，失败时原文件不动。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

# ---------------------------------------------------------------- glTF 读写

_COMPONENT_FMT = {
    5120: "b",   # BYTE
    5121: "B",   # UNSIGNED_BYTE
    5122: "h",   # SHORT
    5123: "H",   # UNSIGNED_SHORT
    5125: "I",   # UNSIGNED_INT
    5126: "f",   # FLOAT
}
_TYPE_COUNT = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def load_glb(path):
    """返回 (gltf_json, bin_chunk)。"""
    with open(path, "rb") as fh:
        buf = fh.read()
    if buf[:4] != b"glTF":
        raise ValueError("不是 GLB 文件: %s" % path)
    _ver, total = struct.unpack_from("<II", buf, 4)
    off, js, blob = 12, None, b""
    while off < total:
        clen, ctype = struct.unpack_from("<II", buf, off)
        chunk = buf[off + 8: off + 8 + clen]
        if ctype == 0x4E4F534A:      # 'JSON'
            js = json.loads(chunk.decode("utf-8"))
        elif ctype == 0x004E4942:    # 'BIN'
            blob = chunk
        off += 8 + clen + ((4 - clen % 4) % 4)
    if js is None:
        raise ValueError("GLB 里没有 JSON chunk")
    return js, blob


def read_accessor(js, blob, index):
    acc = js["accessors"][index]
    bv = js["bufferViews"][acc["bufferView"]]
    fmt = _COMPONENT_FMT[acc["componentType"]]
    n = _TYPE_COUNT[acc["type"]]
    elem = struct.calcsize("<" + fmt * n)
    stride = bv.get("byteStride") or elem
    base = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    return [struct.unpack_from("<" + fmt * n, blob, base + k * stride)
            for k in range(acc["count"])]


def _pad4(data, fill=b"\x00"):
    return data + fill * ((4 - len(data) % 4) % 4)


def glb_triangle_count(path, mesh_index=None):
    """只数三角面（不解顶点），复杂模型上这是读头操作。
    mesh_index 指定时只数该网格。"""
    js, _blob = load_glb(path)
    meshes = js.get("meshes", [])
    if mesh_index is not None:
        meshes = [meshes[mesh_index]]
    total = 0
    for mesh in meshes:
        for prim in mesh.get("primitives", []):
            if prim.get("mode", 4) != 4:
                continue
            if prim.get("indices") is not None:
                total += js["accessors"][prim["indices"]]["count"] // 3
            else:
                total += js["accessors"][prim["attributes"]["POSITION"]]["count"] // 3
    return total


def glb_triangles(path, mesh_index=None):
    """解出三角面（非索引展开，顶点用模型自身空间）。mesh_index 指定时只解该网格。"""
    js, blob = load_glb(path)
    meshes = js.get("meshes", [])
    if mesh_index is None:
        meshes = [(i, m) for i, m in enumerate(meshes)]
    else:
        meshes = [(mesh_index, meshes[mesh_index])]
    tris = []
    for _mi, mesh in meshes:
        for prim in mesh.get("primitives", []):
            if prim.get("mode", 4) != 4:
                continue
            pos = read_accessor(js, blob, prim["attributes"]["POSITION"])
            if prim.get("indices") is not None:
                order = [v[0] for v in read_accessor(js, blob, prim["indices"])]
            else:
                order = range(len(pos))
            for k in range(0, len(order) - 2, 3):
                tris.append((pos[order[k]], pos[order[k + 1]], pos[order[k + 2]]))
    return tris


def write_positions_glb(positions, dst, indices=None):
    """把一串顶点（可选索引）写成极简 GLB（只有 POSITION[+索引]），供 meshoptimizer 简化。
    参数是"顶点列表"（每项 (x,y,z)）；indices 为空时按顺序三角形展开。"""
    if not positions:
        raise ValueError("没有顶点")
    if indices is None:
        indices = list(range(len(positions)))
    pos_bytes = b"".join(struct.pack("<3f", *p) for p in positions)
    idx_bytes = b"".join(struct.pack("<I", i) for i in indices)
    bin_chunk = _pad4(pos_bytes) + _pad4(idx_bytes)
    out = {
        "asset": {"version": "2.0", "generator": "simplify_collision.py"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0}],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1, "mode": 4}]}],
        "buffers": [{"byteLength": len(bin_chunk)}],
        "bufferViews": [
            {"buffer": 0, "byteOffset": 0, "byteLength": len(pos_bytes)},
            {"buffer": 0, "byteOffset": len(_pad4(pos_bytes)), "byteLength": len(idx_bytes)},
        ],
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": len(positions), "type": "VEC3",
             "min": [min(p[i] for p in positions) for i in range(3)],
             "max": [max(p[i] for p in positions) for i in range(3)]},
            {"bufferView": 1, "componentType": 5125, "count": len(indices), "type": "SCALAR"},
        ],
    }
    js_bytes = _pad4(json.dumps(out, separators=(",", ":")).encode("utf-8"), b" ")
    glb = b"glTF" + struct.pack("<II", 2, 12 + 8 + len(js_bytes) + 8 + len(bin_chunk))
    glb += struct.pack("<II", len(js_bytes), 0x4E4F534A) + js_bytes
    glb += struct.pack("<II", len(bin_chunk), 0x004E4942) + bin_chunk
    with open(dst, "wb") as fh:
        fh.write(glb)
    return len(positions), len(indices) // 3


def write_position_only_glb(src, dst, mesh_index=None):
    """只保留 POSITION + 索引写一份极简 GLB，供简化用（剥掉 UV/法线接缝）。
    mesh_index 指定时只写该网格；顶点用模型自身空间（不套节点变换），
    这样简化后的坐标能直接写进 Godot 的 CollisionShape3D。"""
    js, blob = load_glb(src)
    meshes = js.get("meshes", [])
    if mesh_index is not None:
        meshes = [meshes[mesh_index]]
    positions, indices = [], []
    for mesh in meshes:
        for prim in mesh.get("primitives", []):
            if prim.get("mode", 4) != 4:
                continue
            pos = read_accessor(js, blob, prim["attributes"]["POSITION"])
            base = len(positions)
            positions.extend(pos)
            if prim.get("indices") is not None:
                indices.extend(i + base for i in
                               (v[0] for v in read_accessor(js, blob, prim["indices"])))
            else:
                indices.extend(range(base, base + len(pos)))
    if not positions or not indices:
        raise ValueError("源模型里没有可用的三角面: %s" % src)
    return write_positions_glb(positions, dst, indices)


# ---------------------------------------------------------------- 场景读写

_DATA_RE = re.compile(r"data = PackedVector3Array\(([^)]*)\)")
_EXT_RE = re.compile(r'path="res://([^"]+\.glb)"')


def read_scene(path):
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as fh:
        text = fh.read()
    match = _DATA_RE.search(text)
    tri_count = 0
    if match:
        tri_count = ((match.group(1).count(",") + 1) // 9) if match.group(1).strip() else 0
    ext = _EXT_RE.search(text)
    return text, match, tri_count, (ext.group(1) if ext else None)


def fmt_float(value):
    """贴近 Godot 的写法：短且够准（7 位有效数字 ≈ 10 纳米）。"""
    out = "%.7g" % value
    return "0" if out == "-0" else out


def build_data_line(tris):
    parts = []
    for tri in tris:
        for v in tri:
            parts.append(fmt_float(v[0]))
            parts.append(fmt_float(v[1]))
            parts.append(fmt_float(v[2]))
    return "data = PackedVector3Array(" + ", ".join(parts) + ")"


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


def resolve_executable(name):
    """Windows 上 npx 实际是 npx.cmd，msys/裸 Python 直接调会 WinError 2。"""
    for cand in (name, name + ".cmd", name + ".exe", name + ".bat", name + ".ps1"):
        found = shutil.which(cand)
        if found:
            return found
    return None


def run(cmd, env=None):
    # 不要用 text=True：npm 在中文 Windows 上输出 GBK，硬解码会 UnicodeDecodeError
    proc = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = proc.stdout.decode("utf-8", "replace")
    if proc.returncode != 0:
        sys.stderr.write(out)
        raise RuntimeError("命令失败: %s" % " ".join(cmd))
    return out


# ---------------------------------------------------------------- 主流程

def main():
    ap = argparse.ArgumentParser(description="精简三角网碰撞到指定比例")
    ap.add_argument("scene", help="包装场景 .tscn 路径")
    ap.add_argument("--ratio", type=float, default=0.01,
                    help="目标比例（相对当前碰撞三角面数），默认 0.01 = 1%%")
    ap.add_argument("--error", type=float, default=1.0,
                    help="meshoptimizer 几何误差上限，默认 1（不设限，优先给够抽面量）")
    ap.add_argument("--glb", default=None, help="手动指定源模型（默认读场景里的 ext_resource）")
    ap.add_argument("--no-backup", action="store_true", help="不生成备份")
    ap.add_argument("--backup-dir", default=None,
                    help="备份目录，默认 <项目>/.runtime/collision_backups（该目录被 gitignore）")
    ap.add_argument("--dry-run", action="store_true", help="只报告，不写文件")
    args = ap.parse_args()

    scene = os.path.abspath(args.scene)
    if not os.path.isfile(scene):
        sys.exit("场景不存在: %s" % scene)
    text, match, cur_tris, glb_rel = read_scene(scene)
    if match is None:
        sys.exit("这个场景里没有 ConcavePolygonShape3D 的 data 字段（可能不是三角网碰撞）")
    if cur_tris <= 0:
        sys.exit("当前碰撞三角面数为 0，没什么可精简的")

    project_root = find_project_root(scene)     # <root>/scenes/... 任意层级都行
    glb = args.glb or (os.path.join(project_root, glb_rel) if glb_rel else None)
    if glb is None or not os.path.isfile(glb):
        sys.exit("找不到源模型（可用 --glb 指定）: %s" % glb)

    target = max(4, int(cur_tris * args.ratio))
    print("场景        : %s  (%.2f MB)" % (scene, os.path.getsize(scene) / 1048576))
    print("源模型      : %s" % glb)
    print("当前碰撞面数: %d" % cur_tris)
    print("目标        : %d 面 (比例 %.4f)" % (target, args.ratio))

    npx = resolve_executable("npx")
    if npx is None:
        sys.exit("找不到 npx：需要 Node.js/npm（简化靠 @gltf-transform/cli 里的 meshoptimizer）")
    env = dict(os.environ)
    env.setdefault("npm_config_cache", os.path.join(project_root, ".runtime", "npm-cache"))
    os.makedirs(env["npm_config_cache"], exist_ok=True)

    tmp_dir = tempfile.mkdtemp(prefix="simplify_collision_")
    try:
        pos_only = os.path.join(tmp_dir, "position_only.glb")
        welded = os.path.join(tmp_dir, "welded.glb")
        simplified = os.path.join(tmp_dir, "simplified.glb")
        verts, raw_tris = write_position_only_glb(glb, pos_only)
        print("剥离属性    : 顶点 %d 三角面 %d（UV/法线接缝会锁死简化，必须先剥掉）"
              % (verts, raw_tris))
        run([npx, "--yes", "@gltf-transform/cli", "weld", pos_only, welded], env=env)
        model_ratio = min(1.0, target / float(raw_tris))
        print("简化比例    : %.6f -> 目标 %d 面" % (model_ratio, target))
        run([npx, "--yes", "@gltf-transform/cli", "simplify", welded, simplified,
             "--ratio", "%.6f" % model_ratio, "--error", "%g" % args.error,
             "--lock-border", "false"], env=env)

        tris = glb_triangles(simplified)
        print("简化结果    : %d 面 (%.2f%%)" % (len(tris), 100.0 * len(tris) / max(1, cur_tris)))
        if not tris:
            sys.exit("简化后没有三角面，已放弃（原文件未动）")

        new_line = build_data_line(tris)
        new_text = _DATA_RE.sub(lambda _m: new_line, text, count=1)
        if new_text == text:
            sys.exit("替换失败（原文件未动）")

        if args.dry_run:
            print("[dry-run] 不写文件。预计新场景 %.2f MB" %
                  (len(new_text.encode("utf-8", "surrogateescape")) / 1048576))
            return

        old_mb = os.path.getsize(scene) / 1048576
        backup = None
        if not args.no_backup:
            # 备份放到 .runtime（被 gitignore）：82MB 的 .bak 躺在 scenes/ 里会进仓库
            backup_dir = args.backup_dir or os.path.join(project_root, ".runtime", "collision_backups")
            os.makedirs(backup_dir, exist_ok=True)
            backup = os.path.join(backup_dir, os.path.basename(scene) + ".bak")
            shutil.copy2(scene, backup)
        with open(scene, "w", encoding="utf-8", errors="surrogateescape", newline="") as fh:
            fh.write(new_text)
        print("完成        : %d 面 -> %d 面 (%.2f%%), 场景 %.2f MB -> %.2f MB" % (
            cur_tris, len(tris), 100.0 * len(tris) / max(1, cur_tris),
            old_mb, os.path.getsize(scene) / 1048576))
        if backup:
            print("备份        : %s" % backup)
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()

# -*- coding: utf-8 -*-
"""裸 float32 三角面的读写（插件与各工具之间的公共格式）。

格式：每 9 个 float32 = 1 个三角面（3 个顶点 × 3 个分量），非索引展开，**无文件头**。
注意两个读取函数的区别（容易搞混，这里明确分开）：
  * read_raw_triangles() -> [(v0, v1, v2), ...]   ← 拓扑分析要这个
  * read_raw_vertices()  -> [(x, y, z), ...]      ← 喂给 GLB 写入器要这个
"""

from __future__ import annotations

import struct


def read_raw_triangles(path):
    """裸 float32 -> 三角面列表 [(v0, v1, v2), ...]，每个 v 是 (x, y, z)。"""
    flat = _read_flat(path)
    return [((flat[i], flat[i + 1], flat[i + 2]),
             (flat[i + 3], flat[i + 4], flat[i + 5]),
             (flat[i + 6], flat[i + 7], flat[i + 8])) for i in range(0, len(flat), 9)]


def read_raw_vertices(path):
    """裸 float32 -> 扁平顶点序列 [(x, y, z), ...]（每 3 个顶点一个三角面）。"""
    flat = _read_flat(path)
    return [(flat[i], flat[i + 1], flat[i + 2]) for i in range(0, len(flat), 3)]


def write_raw_faces(tris, path):
    """三角面列表 -> 裸 float32 文件。返回写入的三角面数。"""
    flat = []
    for tri in tris:
        for v in tri:
            flat.extend((float(v[0]), float(v[1]), float(v[2])))
    with open(path, "wb") as fh:
        fh.write(struct.pack("<%df" % len(flat), *flat))
    return len(flat) // 9


def _read_flat(path):
    with open(path, "rb") as fh:
        blob = fh.read()
    count = len(blob) // 4
    if count < 9 or count % 9 != 0:
        raise SystemExit("输入不是三角形列表（float 数 %d，应为 9 的倍数且 ≥9）" % count)
    return struct.unpack("<%df" % count, blob)

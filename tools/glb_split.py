# -*- coding: utf-8 -*-
"""GLB 切割工具（Blender 无头运行）

用法：
  blender -b --python tools/glb_split.py -- <源.glb> <输出目录> [选项]

选项：
  --decimate=N     每块目标三角数（默认 6000；0 = 不减面）
  --box=x0,y0,z0,x1,y1,z1   只保留这个立方体区域内的部分（世界坐标）
  --keep-origin    不重置中心（默认每个零件中心平移到自身原点 ✓）
  --min-tris=N     忽略小于 N 面的碎片（默认 50，清掉毛刺）
  --order=rowcol   命名顺序：rowcol = 按 Z 分行、行内按 X（默认）| z = 仅按 Z

原理：
  ① import glb → 合并成一个网格
  ② separate(type='LOOSE') = 按**连通块**分离 —— 视觉不相干的模型本来就是互不相连的壳 ✓
  ③ 每块：重置中心 ✓ → 减面 ✓ → 导出独立 .glb ✓
  ④ 可选：--box 只保留立方体内的部分（用 numpy 快速选点 ✓）
"""
import bpy, sys, os, json, math
import numpy as np
from mathutils import Vector, Matrix

argv = sys.argv[sys.argv.index('--') + 1:]
src, outdir = argv[0], argv[1]
DECIMATE = 6000
RATIO = 1.0          # ★ 新增：按**面数比例**减面（0.01~1.0；1.0 = 不减面，优先于 --decimate ✓）
BOX = None
KEEP_ORIGIN = False
MIN_TRIS = 50
ORDER = 'rowcol'
CLUSTERS = 0        # >0 = 把连通块按空间聚成 N 组（AI 生成的模型往往是上千个补丁壳 ✓）
for a in argv[2:]:
    if a.startswith('--decimate='): DECIMATE = int(a.split('=')[1])
    elif a.startswith('--ratio='): RATIO = float(a.split('=')[1])     # ★ 例：--ratio=0.35 = 保留 35% 面数 ✓
    elif a.startswith('--box='): BOX = [float(v) for v in a.split('=')[1].split(',')]
    elif a == '--keep-origin': KEEP_ORIGIN = True
    elif a.startswith('--min-tris='): MIN_TRIS = int(a.split('=')[1])
    elif a.startswith('--order='): ORDER = a.split('=')[1]
    elif a.startswith('--clusters='): CLUSTERS = int(a.split('=')[1])

os.makedirs(outdir, exist_ok=True)
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)

objs = [o for o in bpy.context.scene.objects if o.type == 'MESH']
if not objs:
    print('ERR 没有网格'); sys.exit(1)
bpy.ops.object.select_all(action='DESELECT')
for o in objs:
    o.select_set(True)
bpy.context.view_layer.objects.active = objs[0]
if len(objs) > 1:
    bpy.ops.object.join()
obj = bpy.context.view_layer.objects.active
print('SRC tris=%d verts=%d' % (len(obj.data.polygons), len(obj.data.vertices)))

# ---- 可选：立方体区域裁剪（numpy 选点，快 ✓）----
if BOX:
    n = len(obj.data.vertices)
    co = np.empty(n * 3, dtype=np.float32)
    obj.data.vertices.foreach_get('co', co)
    co = co.reshape(n, 3)
    M = np.array(obj.matrix_world)
    w = co @ M[:3, :3].T + M[:3, 3]
    inside = ((w[:, 0] >= BOX[0]) & (w[:, 0] <= BOX[3]) &
              (w[:, 1] >= BOX[1]) & (w[:, 1] <= BOX[4]) &
              (w[:, 2] >= BOX[2]) & (w[:, 2] <= BOX[5]))
    sel = np.zeros(n, dtype=bool)
    sel[inside] = True
    obj.data.vertices.foreach_set('select', sel)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_mode(type='VERT')
    bpy.ops.mesh.select_all(action='DESELECT')
    bpy.ops.object.mode_set(mode='OBJECT')
    obj.data.vertices.foreach_set('select', sel)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.delete(type='VERT')          # 删掉框外的 ✓ 只留框内
    bpy.ops.object.mode_set(mode='OBJECT')
    print('BOX kept_tris=%d' % len(obj.data.polygons))

# ---- ★ 连通块分离 = 切割 ✓ ----
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_all(action='SELECT')
bpy.ops.mesh.separate(type='LOOSE')
bpy.ops.object.mode_set(mode='OBJECT')
parts = [o for o in bpy.context.scene.objects if o.type == 'MESH']
print('SPLIT parts=%d' % len(parts))

# ---- 收集每块的中心（世界坐标）与面数 ----
info = []
for p in parts:
    cnt = len(p.data.polygons)
    if cnt < MIN_TRIS:
        continue
    # ★ 先清父级并保持世界位置 ✓ —— separate() 出的对象仍挂在原节点下 ✗，
    #   只烘 matrix_world 的话父级会**再叠一次**变换 → 坐标全歪 ✗（实测所有零件 x 都挤在 -0.14 ✓）
    mw = p.matrix_world.copy()
    p.parent = None
    p.matrix_world = mw
    # 把世界变换烘进网格 ✓（之后坐标就是世界坐标 ✓）
    p.data.transform(p.matrix_world)
    p.matrix_world = Matrix.Identity(4)
    cos = np.empty(len(p.data.vertices) * 3, dtype=np.float32)
    p.data.vertices.foreach_get('co', cos)
    cos = cos.reshape(-1, 3)
    c = cos.mean(axis=0)
    mn, mx = cos.min(axis=0), cos.max(axis=0)
    info.append({'o': p, 'tris': cnt, 'center': [float(v) for v in c], 'min': [float(v) for v in mn], 'max': [float(v) for v in mx]})

# ---- ★ 空间聚类：把上千个补丁壳归并成 N 组 ✓（按 X-Z 平面，忽略向上的 Y 轴 ✓）----
if CLUSTERS > 0 and len(info) > CLUSTERS:
    P = np.array([[i['center'][0], i['center'][2]] for i in info], dtype=np.float64)
    W = np.array([i['tris'] for i in info], dtype=np.float64)
    # k-means++ 初始化 ✓ 用面数加权 ✓
    rng = np.random.default_rng(3)
    C = P[rng.choice(len(P), size=CLUSTERS, replace=False)]
    for _ in range(60):
        d = ((P[:, None, :] - C[None, :, :]) ** 2).sum(axis=2)
        lab = d.argmin(axis=1)
        newC = np.array([ (P[lab == k] * W[lab == k, None]).sum(axis=0) / max(W[lab == k].sum(), 1e-9)
                          if (lab == k).any() else C[k] for k in range(CLUSTERS)])
        if np.allclose(newC, C, atol=1e-6): C = newC; break
        C = newC
    grouped = {}
    for k, it in zip(lab, info):
        grouped.setdefault(int(k), []).append(it)
    # 每组把网格 join 成一个 ✓
    merged_info = []
    for k, items in grouped.items():
        bpy.ops.object.select_all(action='DESELECT')
        for it in items:
            it['o'].select_set(True)
        bpy.context.view_layer.objects.active = items[0]['o']
        if len(items) > 1:
            bpy.ops.object.join()
        o = bpy.context.view_layer.objects.active
        o.name = 'cluster_%d' % k
        cos = np.empty(len(o.data.vertices) * 3, dtype=np.float32)
        o.data.vertices.foreach_get('co', cos); cos = cos.reshape(-1, 3)
        merged_info.append({'o': o, 'tris': len(o.data.polygons),
                            'center': [float(v) for v in cos.mean(axis=0)],
                            'min': [float(v) for v in cos.min(axis=0)],
                            'max': [float(v) for v in cos.max(axis=0)]})
    info = merged_info
    print('CLUSTER groups=%d (from %d shells)' % (len(info), len(parts)))

# ---- 排序：3 行 → 行内 3 列 ✓ ----
if ORDER == 'rowcol':
    zs = sorted(set(round(i['center'][2], 3) for i in info))
    # 按 Z 聚类成"行"（相邻差 < 0.08 视为同一行 ✓）
    rows = []
    for z in sorted([i['center'][2] for i in info], reverse=True):
        for r in rows:
            if abs(r[-1] - z) < 0.08:
                r.append(z); break
        else:
            rows.append([z])
    def row_of(z):
        for k, r in enumerate(rows):
            if any(abs(z - v) < 0.08 for v in r):
                return k
        return 0
    info.sort(key=lambda i: (row_of(i['center'][2]), i['center'][0]))
else:
    info.sort(key=lambda i: -i['center'][2])

base = os.path.splitext(os.path.basename(src))[0]
manifest = []
for idx, it in enumerate(info, 1):
    p, c = it['o'], Vector(it['center'])
    # ★ 中心重置：网格平移到自身原点，对象位置 = 原中心 ✓
    if not KEEP_ORIGIN:
        p.data.transform(Matrix.Translation(-c))
        p.location = c
    # 减面 ✓
    if DECIMATE > 0 and it['tris'] > DECIMATE:
        m = p.modifiers.new('dec', 'DECIMATE')
        m.decimate_type = 'COLLAPSE'
        if RATIO < 1.0:
            # ★ 按比例减面（用户新增选项 ✓）：每块都缩到原本面数的 RATIO 倍 ✓
            #   例：--ratio=0.35 → 90 万面的块 → 约 31.5 万面 ✓
            m.ratio = max(0.01, min(1.0, RATIO))
        else:
            m.ratio = max(0.01, DECIMATE / float(it['tris']))
        bpy.context.view_layer.objects.active = p
        bpy.ops.object.modifier_apply(modifier=m.name)
    p.name = '%s_%02d' % (base, idx)
    bpy.ops.object.select_all(action='DESELECT')
    p.select_set(True)
    bpy.context.view_layer.objects.active = p
    out = os.path.join(outdir, '%s_%02d.glb' % (base, idx))
    bpy.ops.export_scene.gltf(filepath=out, use_selection=True, export_format='GLB',
                              export_apply=True, export_yup=True)
    manifest.append({'index': idx, 'file': os.path.basename(out),
                     'tris_before': it['tris'], 'tris_after': len(p.data.polygons),
                     'center': [round(v, 4) for v in it['center']],
                     'size': [round(it['max'][k] - it['min'][k], 4) for k in range(3)]})
    print('PART %02d tris %d→%d center=(%.3f, %.3f, %.3f) size=(%.3f, %.3f, %.3f)' % (
        idx, it['tris'], len(p.data.polygons), it['center'][0], it['center'][1], it['center'][2],
        it['max'][0]-it['min'][0], it['max'][1]-it['min'][1], it['max'][2]-it['min'][2]))

with open(os.path.join(outdir, '_split_manifest.json'), 'w', encoding='utf-8') as f:
    json.dump({'source': os.path.basename(src), 'parts': len(manifest), 'decimate_target': DECIMATE,
               'box': BOX, 'items': manifest}, f, ensure_ascii=False, indent=2)
print('DONE parts=%d' % len(manifest))
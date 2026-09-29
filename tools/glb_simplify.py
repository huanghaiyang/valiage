"""把一个 .glb 整体降模（保留 UV / 法线 / 材质），用于"GLB 降模工具"的精确模式。

为什么不用 Godot 自己简化：Godot 没有开放网格简化 API，只有内置的 LOD 链
（`ImporterMesh.generate_lods`，底层同样是 meshoptimizer，但**不能指定比例**，
只能给出约 50%/25%/12.5%… 的阶梯）。要做 1%~100% 里任意比例，就得到这边来。

做法：gltf-transform（内含 meshoptimizer）
    npx --yes @gltf-transform/cli weld     in.glb  tmp.glb
    npx --yes @gltf-transform/cli simplify tmp.glb out.glb --ratio R --error E
weld 是必须的：simplify 只对"焊接后"的顶点有效，否则基本降不动。

用法：
    python tools/glb_simplify.py --in a.glb --out b.glb --ratio 0.3 \
        [--error 0.5] [--lock-border] [--report r.txt] [--project D:/proj]
"""
import argparse
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from simplify_collision import (find_project_root, glb_triangle_count,  # noqa: E402
                                resolve_executable)

try:
    sys.stdout.reconfigure(errors="replace")
except Exception:
    pass


def run_npx(args, project_root, timeout=600):
    """跑 npx。两个坑：
    ① Windows 上可执行名是 npx.cmd（直接调 npx 会 WinError 2）—— 用 resolve_executable
    ② 不能让它往 %LOCALAPPDATA% 写缓存（本机没权限，会报 npm error permissions）——
       把 npm_config_cache 指到项目内的 .runtime/npm-cache
    """
    npx = resolve_executable("npx")
    if npx is None:
        raise RuntimeError("找不到 npx：需要 Node.js/npm（降模靠 @gltf-transform/cli 里的 meshoptimizer）")
    env = dict(os.environ)
    env.setdefault("npm_config_cache", os.path.join(project_root, ".runtime", "npm-cache"))
    os.makedirs(env["npm_config_cache"], exist_ok=True)
    # 不要 text=True：npm 在中文 Windows 上输出 GBK，硬解码会 UnicodeDecodeError
    proc = subprocess.run(
        [npx, "--yes"] + args, cwd=project_root, env=env, timeout=timeout,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return proc.returncode, proc.stdout.decode("utf-8", "replace")


def weld_only(in_glb, out_glb, project_root=None, report=None, in_place=False):
    """只做 weld：合并重复顶点、丢掉没被引用的顶点 —— 体积就真的下来了。

    用途：Godot 的 LOD 降模只换索引表、不动顶点表，导出的 glb 体积降不下来；
    导出后再过一遍 weld，顶点数据才真正被压掉（实测 2 秒左右）。
    """
    project_root = project_root or find_project_root(in_glb)
    size_before = os.path.getsize(in_glb)      # 必须在替换前量
    # 注意：--in-place 时临时文件必须放在**目标同目录**。os.replace 不能跨盘，
    # 放系统临时目录（C:）再去替换 D: 上的文件会 WinError 17。
    tmp_dir = ""
    if in_place:
        target = os.path.join(os.path.dirname(os.path.abspath(in_glb)), ".weld_tmp.glb")
    else:
        tmp_dir = tempfile.mkdtemp(prefix="glb_weld_")
        target = os.path.join(tmp_dir, "welded.glb")
    try:
        rc, log = run_npx(["@gltf-transform/cli", "weld", in_glb, target], project_root)
        if rc != 0 or not os.path.exists(target):
            raise RuntimeError("weld 失败（rc=%d）：%s" % (rc, log.strip()[-400:]))
        if in_place:
            os.replace(target, in_glb)
    finally:
        try:
            import shutil
            if tmp_dir:
                shutil.rmtree(tmp_dir, ignore_errors=True)
            elif os.path.exists(target):
                os.remove(target)
        except Exception:
            pass
    out = in_glb if in_place else out_glb
    before = size_before
    after = os.path.getsize(out)
    lines = ["weld 压缩：%d -> %d 字节（%.1f%%）" % (
        before, after, 100.0 * after / before if before else 0.0)]
    if report:
        with open(report, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines))
    return before, after, lines


def simplify(in_glb, out_glb, ratio, error=0.5, lock_border=False,
             project_root=None, report=None):
    project_root = project_root or find_project_root(in_glb)
    tmp_dir = tempfile.mkdtemp(prefix="glb_simplify_")
    welded = os.path.join(tmp_dir, "welded.glb")
    try:
        rc, log = run_npx(["@gltf-transform/cli", "weld", in_glb, welded], project_root)
        if rc != 0 or not os.path.exists(welded):
            raise RuntimeError("weld 失败（rc=%d）：%s" % (rc, log.strip()[-400:]))

        args = ["@gltf-transform/cli", "simplify", welded, out_glb,
                "--ratio", "%.6f" % ratio, "--error", "%.6f" % error]
        if not lock_border:
            args += ["--lock-border", "false"]
        rc, log = run_npx(args, project_root)
        if rc != 0 or not os.path.exists(out_glb):
            raise RuntimeError("simplify 失败（rc=%d）：%s" % (rc, log.strip()[-400:]))
    finally:
        try:
            import shutil
            shutil.rmtree(tmp_dir, ignore_errors=True)
        except Exception:
            pass

    before = glb_triangle_count(in_glb)
    after = glb_triangle_count(out_glb)
    lines = [
        "输入 %d 面 -> 输出 %d 面（实际 %.3f%%，目标 %.3f%%）" % (
            before, after, 100.0 * after / before if before else 0.0, 100.0 * ratio),
    ]
    if report:
        with open(report, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines))
    return before, after, lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="src", required=True)
    ap.add_argument("--out", dest="dst", required=True)
    ap.add_argument("--ratio", type=float, default=0.3, help="0.01~1.0")
    ap.add_argument("--error", type=float, default=0.5)
    ap.add_argument("--lock-border", action="store_true")
    ap.add_argument("--project", default=None)
    ap.add_argument("--report", default=None)
    ap.add_argument("--weld-only", action="store_true",
                    help="只做 weld（压掉重复/未引用顶点），不降面")
    ap.add_argument("--in-place", action="store_true",
                    help="直接改原文件（先写临时文件再替换，失败不会损坏原文件）")
    args = ap.parse_args()

    if args.weld_only:
        before, after, lines = weld_only(
            args.src, args.dst, args.project, args.report, args.in_place)
        for line in lines:
            print(line)
        return

    ratio = min(max(args.ratio, 0.01), 1.0)
    before, after, lines = simplify(
        args.src, args.dst, ratio, args.error, args.lock_border, args.project, args.report)
    for line in lines:
        print(line)


if __name__ == "__main__":
    main()

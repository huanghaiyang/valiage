// ============================================================================
// fast-tree 风摆 · JS ↔ GDScript 逐行等价交叉验证（JS 侧）
// ============================================================================
// 直接 import 源实现 windModel.js（不复制、不改），用与
// tests/wind/crosscheck_windmodel.gd 完全相同的输入生成参照输出。
//
// 用法：
//   node tests/wind/crosscheck_windmodel.mjs
//   产物：.runtime/wind_port/js_ref.json
// ============================================================================
import { writeFileSync, mkdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = resolve(HERE, '..', '..')
const SRC = 'D:/sgames/fast-tree/src/core/windModel.js'
const mod = await import(pathToFileURL(SRC).href)

const CASES = []
for (let i = 0; i < 60; i++) {
  CASES.push({
    wind: {
      direction: (i * 37) % 360,
      strength: [0.05, 0.12, 0.3][i % 3],
      speed: [0.45, 0.8, 3.6][(i * 2) % 3],
      frequency: [0.05, 1, 3][(i * 5) % 3],
      gust: [0, 0.35, 1][i % 3],
      gustSpeed: [0.06, 0.16, 0.4][(i * 7) % 3],
      turbulence: [0, 0.12, 1][(i * 11) % 3],
      bias: [0, 0.3, 0.9][(i * 13) % 3],
      leafFlutter: [0.25, 0.6, 1.2][(i * 17) % 3],
      leafTwist: [0.15, 0.5, 1.1][(i * 19) % 3],
    },
    opts: {
      aWind: [0, 0.5, 1][(i * 3) % 3],
      stemDist: [0.05, 0.35, 0.9][(i * 23) % 3],
      phase: [0, 1.234, 5.5][(i * 29) % 3],
      dt: 1 / 60,
      steps: 600,
    },
  })
}

const ENV_CASES = []
for (let i = 0; i < 12; i++) {
  ENV_CASES.push({
    wind: {
      direction: (i * 53) % 360,
      strength: [0.05, 0.15, 0.3][i % 3],
      speed: [0.45, 0.8, 3.6][(i * 2) % 3],
      frequency: [0.05, 1, 3][(i * 5) % 3],
      gust: [0, 0.35, 1][(i * 7) % 3],
      gustSpeed: [0.06, 0.16, 0.4][(i * 11) % 3],
      turbulence: [0, 0.12, 1][(i * 13) % 3],
      bias: [0, 0.3, 0.9][(i * 17) % 3],
    },
    opts: { dt: 1 / 60, steps: 2400, phase: [0.7, 2.5, 0][i % 3], flex: [1, 0.4, 0][(i * 19) % 3] },
  })
}

const out = { source: SRC, defaults: mod.DEFAULTS ?? null, cases: [], env_cases: [], raw: null }

for (const c of CASES) {
  const m = mod.motionMetrics(c.wind, 'current', c.opts)
  out.cases.push({ wind: c.wind, opts: c.opts, metrics: m })
}
for (const c of ENV_CASES) {
  out.env_cases.push({ wind: c.wind, opts: c.opts, env: mod.swayEnvelope(c.wind, c.opts) })
}

// 原始点集（未取整）：逐点比较，证明公式逐行一致
{
  const c = CASES[0]
  const { pts, windDir, windPerp } = mod.leafTrajectory(c.wind, 'current', c.opts)
  out.raw = { wind: c.wind, opts: c.opts, windDir, windPerp, pts }
}

const dir = resolve(ROOT, '.runtime/wind_port')
mkdirSync(dir, { recursive: true })
const dest = resolve(dir, 'js_ref.json')
writeFileSync(dest, JSON.stringify(out), 'utf8')
console.log(`[js] wrote ${dest}  cases=${out.cases.length} env=${out.env_cases.length} raw_pts=${out.raw.pts.length}`)

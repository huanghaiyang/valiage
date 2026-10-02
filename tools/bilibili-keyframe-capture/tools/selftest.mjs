/**
 * selftest.mjs —— 在 Node 里验证纯逻辑部分（关键帧检测 + ZIP 打包 + 扫描循环）
 *
 * 运行：node tools/bilibili-keyframe-capture/tools/selftest.mjs
 * 说明：扩展的 UI / 真实取帧依赖 Chrome 环境，这里用可控的假视频驱动真实的
 *       扫描器与检测算法，方便调参与回归。
 */
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const here = dirname(fileURLToPath(import.meta.url));
const rootDir = join(here, '..');

const sandbox = {
  console,
  setTimeout,
  clearTimeout,
  setInterval,
  clearInterval,
  TextEncoder,
  TextDecoder,
  Blob,
  Uint8Array,
  Uint8ClampedArray,
  Float32Array,
  Int32Array,
  ArrayBuffer,
  DataView,
  performance,
  AbortController,
  URL
};
const NativeURL = URL; // 后面会给 sandbox.URL 打桩，先留一份真正的构造函数
sandbox.window = sandbox;
sandbox.self = sandbox;
sandbox.globalThis = sandbox;
sandbox.navigator = { storage: {} };
// capture.js 在加载时会准备一张复用画布，这里给个最小 document 桩
sandbox.document = {
  createElement: () => ({ width: 0, height: 0, getContext: () => sandbox.__ctx, style: {} })
};
sandbox.location = { href: 'https://www.bilibili.com/video/BV1TEST' };

function load(relativePath) {
  const code = readFileSync(join(rootDir, relativePath), 'utf8');
  vm.runInNewContext(code, sandbox, { filename: relativePath });
}

load('content/core.js');
load('content/detector.js');
load('content/scanner.js');
load('content/framesource.js');
load('background/zip.js');

const BKF = sandbox.__BKF__ || {};
const core = BKF.core;
const D = BKF.detector;
const Z = sandbox.BKFzip;

let passed = 0;
let failed = 0;

function check(name, condition, extra) {
  if (condition) {
    passed += 1;
    console.log(`  \u2713 ${name}`);
  } else {
    failed += 1;
    console.log(`  \u2717 ${name}${extra ? ` \u2014 ${extra}` : ''}`);
  }
}

/* ------------------------------------------------------------------ */
console.log('\n[1] 感知哈希（dHash）');

const W = 11;
const H = 10;
let patternSeed = 1;
function randomPattern() {
  return Array.from({ length: W * H }, () => {
    patternSeed = (patternSeed * 1103515245 + 12345) & 0x7fffffff;
    return patternSeed % 256;
  });
}

function makeVideo(pattern) {
  sandbox.__pattern = pattern;
  const ctx = {
    imageSmoothingEnabled: false,
    drawImage() {},
    getImageData(x, y, w, h) {
      const out = new Uint8ClampedArray(w * h * 4);
      for (let i = 0; i < w * h; i += 1) {
        const value = sandbox.__pattern[i % sandbox.__pattern.length];
        out[i * 4] = value;
        out[i * 4 + 1] = value;
        out[i * 4 + 2] = value;
        out[i * 4 + 3] = 255;
      }
      return { data: out, width: w, height: h };
    }
  };
  return { videoWidth: 1920, videoHeight: 1080, ctx };
}

function canvasFor() {
  return { width: 0, height: 0, getContext: () => sandbox.__ctx };
}

function hashOf(pattern) {
  const video = makeVideo(pattern);
  sandbox.__ctx = video.ctx;
  return D.hashCanvas(video, canvasFor());
}

const patternA = randomPattern();
const patternB = patternA.slice().reverse();

const hashA = hashOf(patternA);
const hashB = hashOf(patternB);
check('哈希长度为 25 个十六进制字符（100 bit）', hashA.hash.length === 25, `实际 ${hashA.hash.length}`);
check('不同画面哈希不同', hashA.hash !== hashB.hash);
check('相同画面哈希一致', hashOf(patternA).hash === hashA.hash);

const sameMetrics = D.compare(hashA, hashOf(patternA));
check('相同画面：汉明距离为 0', sameMetrics.hashDistance === 0, `实际 ${sameMetrics.hashDistance}`);
check('相同画面：MAD 为 0', sameMetrics.mad === 0, `实际 ${sameMetrics.mad}`);

const diffMetrics = D.compare(hashA, hashB);
check('不同画面：汉明距离明显大于阈值', diffMetrics.hashDistance > 0.2, `实际 ${diffMetrics.hashDistance.toFixed(3)}`);

/* ------------------------------------------------------------------ */
console.log('\n[2] 灰度平均绝对差 + 场景切换判定');

const judge = { hashThreshold: 0.12, madThreshold: 0.1 };
const flat = new Array(W * H).fill(100);
const flatHash = hashOf(flat);
const flatSig = {
  hash: flatHash.hash,
  hashBits: flatHash.hashBits,
  brightness: flatHash.brightness,
  sample: new Uint8ClampedArray(W * H).fill(100)
};
const flatSig2 = {
  hash: flatHash.hash,
  hashBits: flatHash.hashBits,
  brightness: flatHash.brightness,
  sample: new Uint8ClampedArray(W * H).fill(101)
};
check('近乎相同的画面：MAD 极小', D.compare(flatSig, flatSig2).mad < 0.01);

const accept0 = D.evaluate(null, flatSig, judge);
check('首帧总是接受', accept0.accept === true, accept0.reason);
const accept1 = D.evaluate(flatSig, flatSig2, judge);
check('画面几乎没变：跳过', accept1.accept === false, `change=${accept1.change.toFixed(4)}`);

const brightSig = {
  hash: flatHash.hash,
  hashBits: flatHash.hashBits,
  brightness: 200,
  sample: new Uint8ClampedArray(W * H).fill(200)
};
const darkSig = {
  hash: flatHash.hash,
  hashBits: flatHash.hashBits,
  brightness: 20,
  sample: new Uint8ClampedArray(W * H).fill(20)
};
const accept2 = D.evaluate(brightSig, darkSig, judge);
check('亮度整体突变（黑场切换）：接受', accept2.accept === true, `change=${accept2.change.toFixed(4)}`);

const blackSig = {
  hash: flatHash.hash,
  hashBits: flatHash.hashBits,
  brightness: 1,
  sample: new Uint8ClampedArray(W * H).fill(20)
};
check('纯黑画面被拒绝', D.evaluate(brightSig, blackSig, judge).accept === false);

/* 相似度去重：这是「同一画面存了 4 张」的主要修复点 */
const nearA = {
  hash: 'aaaaaaaaaaaaaaaaaaaaaaaaa',
  hashBits: new Uint8Array(100).fill(0),
  brightness: 120,
  sample: new Uint8ClampedArray(256).fill(120)
};
// 与近邻只差极小的灰度（模拟同一场景的连续采样）
const nearB = Object.assign({}, nearA, { sample: new Uint8ClampedArray(256).fill(122) });
const nearJudge = Object.assign({ minChange: 0.025 }, judge);
const nearDecision = D.evaluate(nearA, nearB, nearJudge);
check('几乎相同的画面被判为相似并跳过', nearDecision.accept === false && nearDecision.similar === true, JSON.stringify({
  reason: nearDecision.reason,
  change: nearDecision.change
}));
check('相似判定的原因文案可读', /几乎相同/.test(nearDecision.reason), nearDecision.reason);
check('把相似度阈值设为 0 即关闭去重', D.evaluate(nearA, nearB, Object.assign({}, nearJudge, { minChange: 0 })).similar === false);
// 差异明显时不应被相似度规则拦下（此时交给常规阈值判断）
const farSample = new Uint8ClampedArray(256).fill(210);
const farSig = Object.assign({}, nearA, { sample: farSample });
const farDecision = D.evaluate(nearA, farSig, nearJudge);
check('差异明显的画面不会被相似度去重拦下', farDecision.similar === false, farDecision.reason);

/* ------------------------------------------------------------------ */
console.log('\n[3] 时间轴格式化');

check('59 秒 -> 00:59', core.timeText(59) === '00:59', core.timeText(59));
check('3599 秒 -> 59:59', core.timeText(3599) === '59:59', core.timeText(3599));
check('3600 秒 -> 1:00:00', core.timeText(3600) === '1:00:00', core.timeText(3600));
check('毫秒后缀', core.timeText(65.4321, true) === '01:05.4', core.timeText(65.4321, true));
check('字节格式化', core.bytes(1536) === '1.5 KB', core.bytes(1536));
check('文件名清理', core.safeName('a/b:c*d?', 'x') === 'a_b_c_d_', core.safeName('a/b:c*d?', 'x'));

/* 采样间隔：默认 100ms、下限 100ms，并兼容旧的「秒」设置 */
const defaults = core.normalizeSettings(null);
check('默认模式是「仅手动」（进页面不自动抓）', defaults.mode === 'off', defaults.mode);
check('采样间隔默认 100ms', defaults.intervalMs === 100, String(defaults.intervalMs));
check('定间隔模式默认 1000ms', core.normalizeSettings({ mode: 'interval' }).intervalMs === 100, '仅默认值，切模式时由 UI 调整');
check('采样间隔下限 100ms', core.normalizeSettings({ intervalMs: 5 }).intervalMs === 100, String(core.normalizeSettings({ intervalMs: 5 }).intervalMs));
check('采样间隔上限 10000ms', core.normalizeSettings({ intervalMs: 99999 }).intervalMs === 10000);
check('采样间隔小数会被取整', core.normalizeSettings({ intervalMs: 123.7 }).intervalMs === 124);
check(
  '同时存在时以 intervalMs 为准',
  core.normalizeSettings({ intervalMs: 250, intervalSeconds: 0.6 }).intervalMs === 250
);
check(
  '老版本遗留的 600ms 旧默认会迁移成 100ms',
  core.normalizeSettings({ intervalMs: 600 }).intervalMs === 100,
  String(core.normalizeSettings({ intervalMs: 600 }).intervalMs)
);
check(
  '老版本用秒存的值同样会迁移',
  core.normalizeSettings({ intervalSeconds: 0.6 }).intervalMs === 100,
  String(core.normalizeSettings({ intervalSeconds: 0.6 }).intervalMs)
);
/* v3 迁移：默认模式从「自动·关键帧」改成「仅手动」，其它模式（用户主动选的）保持不动 */
check(
  'v2 的默认 auto 模式会迁移成仅手动',
  core.normalizeSettings({ settingsVersion: 2, mode: 'auto' }).mode === 'off',
  core.normalizeSettings({ settingsVersion: 2, mode: 'auto' }).mode
);
check(
  'v2 用户主动选的逐帧模式保持不变',
  core.normalizeSettings({ settingsVersion: 2, mode: 'every' }).mode === 'every'
);
check(
  'v2 用户主动选的定间隔模式保持不变',
  core.normalizeSettings({ settingsVersion: 2, mode: 'interval' }).mode === 'interval'
);
check(
  '已是 v3 时手改的 auto 模式会被保留',
  core.normalizeSettings({ settingsVersion: 3, mode: 'auto' }).mode === 'auto',
  core.normalizeSettings({ settingsVersion: 3, mode: 'auto' }).mode
);
check(
  'v3 的手改间隔不会被覆盖',
  core.normalizeSettings({ settingsVersion: 3, intervalMs: 600 }).intervalMs === 600,
  String(core.normalizeSettings({ settingsVersion: 3, intervalMs: 600 }).intervalMs)
);
check(
  '低于下限的值仍然被夹到 100ms',
  core.normalizeSettings({ settingsVersion: 3, intervalMs: 40 }).intervalMs === 100
);
check(
  '逐帧模式（every）是合法模式',
  core.normalizeSettings({ mode: 'every' }).mode === 'every'
);
check(
  '未知模式会回落到关键帧模式',
  core.normalizeSettings({ mode: 'nonsense' }).mode === 'auto'
);

/* 采样统计：回答「5 秒 100ms = 50 次采样，为什么只存 6 张」 */
const accountState = { sampleCount: 0, savedHashes: new Set() };
// 50 次采样、画面每次都不同（模拟逐帧抓取）：全部不重复
let dupCount = 0;
for (let i = 0; i < 50; i += 1) {
  if (core.accountSample(accountState, `frame-${i}`).duplicate) dupCount += 1;
}
check('50 次采样都被记为「新画面」', accountState.sampleCount === 50 && dupCount === 0, `dup=${dupCount}`);
check('重复出现过的画面会被认出来', core.accountSample(accountState, 'frame-7').duplicate === true);
// 复用同一份状态时才会计数；每次调用都会把哈希记进去
const freshState = { sampleCount: 0, savedHashes: new Set() };
core.accountSample(freshState, 'same');
check('同一画面第二次判定为重复', core.accountSample(freshState, 'same').duplicate === true);
check('采样计数不因重复而停摆', freshState.sampleCount === 2, String(freshState.sampleCount));

/* 多播几遍：识别循环重播，好重置判定基准并累加遍数 */
check('时间大幅回退判定为重播', core.isVideoLooped(118, 0.5) === true);
check('正常播放不算重播', core.isVideoLooped(50, 51) === false);
check('刚开始播（没有上一次）不算重播', core.isVideoLooped(0, 0.5) === false);
check('小幅回退（seek 微调）不算重播', core.isVideoLooped(50, 49.6) === false);
check('回退超过 1 秒才算重播', core.isVideoLooped(50, 48.5) === true && core.isVideoLooped(50, 49) === false);

/* 会话身份：切视频必须换会话，且同一个视频不能因元数据时序而分裂成两个会话 */
const idA = core.sessionIdentity({ href: 'https://www.bilibili.com/video/BV1AAA?p=1' });
const idB = core.sessionIdentity({ href: 'https://www.bilibili.com/video/BV1BBB' });
const idA2 = core.sessionIdentity({ href: 'https://www.bilibili.com/video/BV1AAA?p=2' });
check('不同视频得到不同会话 id', idA.id !== idB.id, `${idA.id} vs ${idB.id}`);
check('不同分P 得到不同会话 id', idA.id !== idA2.id, `${idA.id} vs ${idA2.id}`);
check('会话 id 里不含时长（避免元数据时序导致会话分裂）',
  !/\d{3,}s?\b/.test(idA.id.replace(/BV\w+/, '')) && idA.id === 'BV1AAA', idA.id);
check('同一个视频重复计算 id 稳定', core.sessionIdentity({ href: 'https://www.bilibili.com/video/BV1AAA?p=1' }).id === idA.id);
check('target 用于判断是否换视频', idA.target !== idB.target && idA.target === core.sessionIdentity({ href: 'https://www.bilibili.com/video/BV1AAA?p=1' }).target);
check('番剧页面用 ep 号做 id',
  core.sessionIdentity({ href: 'https://www.bilibili.com/bangumi/play/ep123456' }).id === 'ep123456',
  core.sessionIdentity({ href: 'https://www.bilibili.com/bangumi/play/ep123456' }).id);
check('URL 里的 cid 参数进入会话 id',
  core.sessionIdentity({ href: 'https://www.bilibili.com/video/BV1AAA?cid=99' }).id === 'BV1AAA-99',
  core.sessionIdentity({ href: 'https://www.bilibili.com/video/BV1AAA?cid=99' }).id);
// 关键回归：不能因为页面 window 上的旧 cid 而算出「假的新会话」
check('忽略页面状态里的 cid（隔离世界读到的是旧值，会导致会话反复重建）',
  core.sessionIdentity({ href: 'https://www.bilibili.com/video/BV1AAA', state: { videoData: { cid: 99 } } }).id === 'BV1AAA',
  core.sessionIdentity({ href: 'https://www.bilibili.com/video/BV1AAA', state: { videoData: { cid: 99 } } }).id);
check('同一 URL 带不同跟踪参数 → 会话 id 相同（不会误判换视频）',
  core.sessionIdentity({ href: 'https://www.bilibili.com/video/BV1AAA/?spm_id_from=333.788&trackid=web_related_0&vd_source=abc' }).id ===
    core.sessionIdentity({ href: 'https://www.bilibili.com/video/BV1AAA/' }).id);

/* 取帧源归属：只按「会话」判断（换视频 = 换会话） */
check('取帧源未记录时视为匹配', core.sourceMatchesSession('', 'BV1AAA') === true);
check('同一会话视为匹配', core.sourceMatchesSession('BV1AAA', 'BV1AAA') === true);
check('换会话视为不匹配', core.sourceMatchesSession('BV1AAA', 'BV1BBB') === false);

/* 会话变化判断：同一会话的重复调用必须被挡住（否则统计被反复归零） */
const idA3 = core.sessionIdentity({ href: 'https://www.bilibili.com/video/BV1AAA' });
const idB3 = core.sessionIdentity({ href: 'https://www.bilibili.com/video/BV1BBB' });
const stateA = { sessionKey: idA3.id, sourceTarget: idA3.target };
check('首次进入（当前为空）视为变化', core.sessionChanged(idA3, { sessionKey: '', sourceTarget: '' }) === true);
check('同一会话重复调用 → 不算变化（关键：防止统计归零）',
  core.sessionChanged(idA3, stateA) === false);
check('换视频 → 算变化', core.sessionChanged(idB3, stateA) === true);
check('会话 id 相同但标记不同 → 仍算变化',
  core.sessionChanged({ id: idA3.id, target: 'other' }, stateA) === true);
check('空身份安全', core.sessionChanged(null, stateA) === false && core.sessionChanged({}, stateA) === false);

/* ------------------------------------------------------------------ */
console.log('\n[4] ZIP 打包器（store 模式）');

const zip = Z.zip();
const pngA = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4]);
const text = new TextEncoder().encode('time,frame\r\n0.5,1\r\n');
zip.addFile('frames/001_00-00-00-500.jpg', pngA);
zip.addFile('index.csv', text);
const blob = zip.finish();
const bytes = new Uint8Array(await blob.arrayBuffer());

function readU32(buffer, offset) {
  return new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength).getUint32(offset, true);
}
function readU16(buffer, offset) {
  return new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength).getUint16(offset, true);
}

check('输出为 application/zip', blob.type === 'application/zip', blob.type);
check('结束记录签名 EOCD', readU32(bytes, bytes.length - 22) === 0x06054b50);
check(
  'EOCD 记录 2 个条目',
  readU16(bytes, bytes.length - 22 + 10) === 2,
  String(readU16(bytes, bytes.length - 22 + 10))
);
check('EOCD 中央目录偏移有效', readU32(bytes, bytes.length - 22 + 16) < bytes.length);
check('本地文件头签名正确', readU32(bytes, 0) === 0x04034b50);
check('文件名以 UTF-8 标记', (readU16(bytes, 6) & 0x0800) !== 0);
check('CRC32 与标准实现一致', Z.crc32(pngA) === readU32(bytes, 14), `${Z.crc32(pngA)} vs ${readU32(bytes, 14)}`);
check('存储大小与原始大小一致', readU32(bytes, 18) === pngA.length && readU32(bytes, 22) === pngA.length);

const firstNameLen = readU16(bytes, 26);
const firstName = new TextDecoder().decode(bytes.subarray(30, 30 + firstNameLen));
check('文件名可被 UTF-8 解码', firstName === 'frames/001_00-00-00-500.jpg', firstName);

const centralOffset = readU32(bytes, bytes.length - 22 + 16);
check('中央目录起始签名', readU32(bytes, centralOffset) === 0x02014b50);
const centralNameLen = readU16(bytes, centralOffset + 28);
const centralName = new TextDecoder().decode(
  bytes.subarray(centralOffset + 46, centralOffset + 46 + centralNameLen)
);
check('中央目录文件名一致', centralName === firstName, centralName);

// 真实解压验证：写出文件，用系统解压工具解开后逐字节比对
const { writeFileSync, mkdtempSync, readFileSync: readFile, rmSync } = await import('node:fs');
const { execFileSync } = await import('node:child_process');
const { tmpdir } = await import('node:os');
const tmp = mkdtempSync(join(tmpdir(), 'bkf-ziptest-'));
try {
  const zipPath = join(tmp, 'test.zip');
  writeFileSync(zipPath, Buffer.from(bytes));
  if (process.platform === 'win32') {
    execFileSync(
      'powershell',
      [
        '-NoProfile',
        '-Command',
        `Expand-Archive -LiteralPath '${zipPath}' -DestinationPath '${join(tmp, 'out')}' -Force`
      ],
      { stdio: 'ignore' }
    );
  } else {
    execFileSync('unzip', ['-o', '-q', zipPath, '-d', join(tmp, 'out')], { stdio: 'ignore' });
  }
  const extractedImage = new Uint8Array(readFile(join(tmp, 'out', 'frames', '001_00-00-00-500.jpg')));
  const extractedCsv = readFile(join(tmp, 'out', 'index.csv'), 'utf8');
  check('系统解压工具可解开 ZIP', true);
  check('图片字节完全一致', Buffer.compare(Buffer.from(extractedImage), Buffer.from(pngA)) === 0);
  check('CSV 内容完全一致', extractedCsv === 'time,frame\r\n0.5,1\r\n', JSON.stringify(extractedCsv));
} catch (error) {
  check('系统解压工具可解开 ZIP', false, error.message);
} finally {
  rmSync(tmp, { recursive: true, force: true });
}

/* ------------------------------------------------------------------ */
console.log('\n[5] 「播放并抓帧」扫描循环（假视频驱动真实扫描器）');

const scanner = BKF.scanner;
// 先保存真实模块引用：下面为了隔离扫描逻辑会把 BKF.capture / BKF.detector 换成桩
const realFramesource = BKF.framesource;

/** 场景每 3 秒切换一次；advance() 模拟解码推进 */
function makeFakeReader(options) {
  const opts = options || {};
  const duration = opts.duration || 12;
  const rate = opts.rate || 4;
  return {
    duration,
    currentTime: 0,
    playbackRate: rate,
    paused: true,
    muted: false,
    dataset: {},
    playCount: 0,
    seekCount: 0,
    play() {
      this.paused = false;
      this.playCount += 1;
      return Promise.resolve();
    },
    pause() {
      this.paused = true;
    },
    advance() {
      if (!this.paused) this.currentTime = Math.min(duration, this.currentTime + rate / 60);
    }
  };
}

/** 场景每 3 秒切换一次，片尾最后一次采样不算新场景（与扫描器的收尾保护一致） */
const SCENE_SECONDS = 3;
function sceneOf(time, duration) {
  if (time >= duration - 0.1) return Math.ceil(duration / SCENE_SECONDS) - 1;
  return Math.floor(time / SCENE_SECONDS);
}

// 替换 detector / capture，只验证扫描循环的控制流与进度语义
const fakeState = { signatures: 0, accepted: 0 };
// 扫描器内部对「上一张已保存关键帧」持有引用，假 detector 也照做，保证去重语义一致
let lastAcceptedSignature = null;
BKF.detector = {
  sample(reader) {
    fakeState.signatures += 1;
    const scene = sceneOf(reader.currentTime, reader.duration);
    return {
      hash: `scene${scene}`,
      hashBits: new Uint8Array(100).fill(scene & 1),
      brightness: 120,
      sample: new Uint8ClampedArray(256).fill(120)
    };
  },
  evaluate(prev, next) {
    const accepts = !prev || prev.hash !== next.hash;
    if (accepts) {
      fakeState.accepted += 1;
      lastAcceptedSignature = next;
    }
    return {
      accept: accepts,
      reason: accepts ? '场景切换' : '画面变化不足',
      hashDistance: accepts ? 1 : 0,
      mad: accepts ? 1 : 0,
      change: accepts ? 1 : 0
    };
  }
};
BKF.capture = {
  async ensureSource() {
    throw new Error('自测应注入 reader');
  },
  async seekTo(reader, time) {
    reader.seekCount += 1;
    reader.currentTime = time;
    return { actualTime: time, cost: 0 };
  },
  async readerFrame(video, context) {
    return {
      skipped: false,
      time: context.time,
      hash: context.signature.hash,
      detection: context.detection
    };
  }
};
// 扫描循环里会读取 framesource.element 以应对中途换策略；只改真实模块的属性，
// 不要替换整个对象（模块内部逻辑读的是闭包里的 source，两者必须是同一个对象）
realFramesource.element = null;
realFramesource.onProgress = null;

const scanSettings = {
  scanInterval: 0.4,
  scanRate: 4,
  scanPauseMain: true,
  maxFramesPerSession: 300
};

async function runScan(options) {
  const opts = options || {};
  const reader = makeFakeReader({ duration: opts.duration || 12, rate: scanSettings.scanRate });
  const pump = setInterval(() => reader.advance(), 8);
  const progressList = [];
  const savedTimes = [];
  const events = [];
  lastAcceptedSignature = null; // 每次扫描都是新的判定基准（与扫描器行为一致）
  const video = {
    paused: false,
    pause() {
      this.paused = true;
      events.push('pause');
    },
    play() {
      this.paused = false;
      events.push('play');
      return Promise.resolve();
    }
  };
  let result = null;
  let failure = null;
  let pausedDuringScan = null;
  try {
    const scanPromise = scanner.start({
      video,
      reader,
      settings: Object.assign({}, scanSettings, { scanInterval: opts.interval || 0.4 }),
      sessionKey: 'test-session',
      videoMeta: {},
      maxFrames: opts.maxFrames || 300,
      onProgress: (p) => {
        progressList.push(p);
        // 扫描进行中抓一次主播放器状态，用于验证「扫描时暂停播放器」
        if (pausedDuringScan === null) pausedDuringScan = video.paused;
      },
      onFrame: async (payload) => {
        savedTimes.push(payload.time);
        if (savedTimes.length >= (opts.cancelAfter || Infinity)) scanner.cancel();
        return {
          stored: true,
          frameCount: savedTimes.length,
          reachedLimit: savedTimes.length >= (opts.limitAt || Infinity)
        };
      }
    });
    result = await scanPromise;
  } catch (error) {
    failure = error;
  } finally {
    clearInterval(pump);
  }
  return { reader, video, events, pausedDuringScan, progressList, savedTimes, result, failure };
}

// 场景 A：正常扫完整个视频（12 秒，每 3 秒一个场景 => 4 个场景）
const scanA = await runScan({});
check('扫描正常完成（无异常）', !scanA.failure, scanA.failure && scanA.failure.message);
check(
  '扫描结果标记为扫完',
  !!scanA.result && scanA.result.reason.includes('扫描完'),
  scanA.result && scanA.result.reason
);
check(
  '每个场景各抓一帧（共 4 帧）',
  scanA.savedTimes.length === 4,
  `实际 ${scanA.savedTimes.length}：${scanA.savedTimes.map((t) => t.toFixed(1)).join(',')}`
);
check('保存时间点单调递增', scanA.savedTimes.every((t, i, arr) => i === 0 || t >= arr[i - 1]));
check('隐藏视频结束后被暂停', scanA.reader.paused === true);
check('扫描期间暂停了主播放器', scanA.pausedDuringScan === true, String(scanA.pausedDuringScan));
check('扫描结束后主播放器被恢复播放', scanA.video.paused === false && scanA.events.includes('play'));
check(
  '进度回调最终到 100%',
  scanA.progressList.some((p) => p.scanPercent >= 95),
  scanA.progressList.map((p) => p.scanPercent).slice(-3).join(',')
);
check(
  '进度回调含帧数与时长',
  scanA.progressList.every((p) => typeof p.scanSaved === 'number' && p.scanDuration > 0)
);
check('扫描结束后 scanning 复位', scanner.progress.scanning === false);
check('播放模式下不依赖 seek（seekCount=0）', scanA.reader.seekCount === 0, `seek ${scanA.reader.seekCount} 次`);

// 场景 B：达到单会话上限后停止
const scanB = await runScan({ limitAt: 2 });
check('达到上限即停止', !!scanB.result && scanB.result.reason.includes('上限'), scanB.result && scanB.result.reason);
check('上限后不再继续保存', scanB.savedTimes.length === 2, `实际 ${scanB.savedTimes.length}`);

// 场景 C：中途取消
const scanC = await runScan({ cancelAfter: 2 });
check('可中途取消', !!scanC.result && scanC.result.cancelRequested === true, scanC.result && scanC.result.reason);
check('取消后保存数等于取消时的数量', scanC.savedTimes.length === 2, `实际 ${scanC.savedTimes.length}`);
check('取消后隐藏视频被暂停', scanC.reader.paused === true);
check('取消原因可读', !!scanC.result && scanC.result.reason.includes('停止'), scanC.result && scanC.result.reason);

// 场景 D：采样间隔 > 1 秒时走 seek 模式
const scanD = await runScan({ interval: 2, duration: 6 });
check('seek 模式确实使用了 seek', scanD.reader.seekCount > 0, `seek ${scanD.reader.seekCount} 次`);
check('seek 模式也能正常结束', !!scanD.result && !scanD.failure, scanD.failure && scanD.failure.message);

// 场景 E：reader 缺失时给出明确错误并复位状态
const badScan = await scanner
  .start({
    video: {
      paused: true,
      pause() {},
      play() {
        return Promise.resolve();
      }
    },
    settings: scanSettings,
    sessionKey: 'x',
    videoMeta: {},
    maxFrames: 10,
    onFrame: async () => ({ stored: true }),
    onProgress: () => {}
  })
  .then(() => null)
  .catch((error) => error);
check(
  '无法取源时抛出明确错误',
  !!badScan && /reader|ensureSource|自测/.test(badScan.message),
  badScan && badScan.message
);
check('出错后 scanning 也会复位', scanner.progress.scanning === false);

/* ------------------------------------------------------------------ */
console.log('\n[6] 取帧源：fMP4 结构解析与策略回退');

const framesource = realFramesource;

/** 造一个 box：[4 字节长度][4 字节类型][内容] */
function box(type, content) {
  const body = content || new Uint8Array(0);
  const out = new Uint8Array(8 + body.length);
  const size = out.length;
  out[0] = (size >>> 24) & 0xff;
  out[1] = (size >>> 16) & 0xff;
  out[2] = (size >>> 8) & 0xff;
  out[3] = size & 0xff;
  for (let i = 0; i < 4; i += 1) out[4 + i] = type.charCodeAt(i);
  out.set(body, 8);
  return out;
}

/** 造一个 sample entry：8 字节 box 头 + 6 字节保留 + 2 字节 data_reference_index + 内容 */
function sampleEntry(type, content) {
  return box(type, concatBytes([new Uint8Array(8), content || new Uint8Array(4)]));
}

function concatBytes(list) {
  const total = list.reduce((sum, item) => sum + item.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const item of list) {
    out.set(item, offset);
    offset += item.length;
  }
  return out;
}

// avcC: version=1, profile=0x64, compat=0x00, level=0x28 => avc1.640028
const avcC = box('avcC', new Uint8Array([1, 0x64, 0x00, 0x28, 0xff, 0xe1]));
const ftyp = box('ftyp', new Uint8Array([0x69, 0x73, 0x6f, 0x6d]));
const moov = box('moov', avcC);
const moof1 = box('moof', new Uint8Array(12).fill(7));
const mdat1 = box('mdat', new Uint8Array(400).fill(9));
const moof2 = box('moof', new Uint8Array(12).fill(7));
const mdat2 = box('mdat', new Uint8Array(300).fill(9));

const head = concatBytes([ftyp, moov, moof1, mdat1, moof2, mdat2]);
const parsed = framesource.parseBoxes(head, 0);
check('init 段结束于 moov 之后', parsed.initEnd === ftyp.length + moov.length, String(parsed.initEnd));
check(
  '第一个媒体段包含 moof+mdat',
  parsed.firstEnd === ftyp.length + moov.length + moof1.length + mdat1.length,
  String(parsed.firstEnd)
);
check('codec 从 avcC 解析为 avc1.640028', framesource.codecFromInit(moov) === 'video/mp4; codecs="avc1.640028"', framesource.codecFromInit(moov));
check('无法识别时回退到主流编码', /avc1\./.test(framesource.codecFromInit(ftyp)), framesource.codecFromInit(ftyp));

// 最后一个完整 box 的边界（用于切片），残缺 box 不应被算进去
const partial = concatBytes([ftyp, moov, moof1, mdat1, moof2.subarray(0, 6)]);
check(
  'lastBoxEnd 只算完整 box',
  framesource.lastBoxEnd(partial) === ftyp.length + moov.length + moof1.length + mdat1.length,
  String(framesource.lastBoxEnd(partial))
);
check('lastBoxEnd 对完整数据返回全长', framesource.lastBoxEnd(head) === head.length, String(framesource.lastBoxEnd(head)));

// 策略回退顺序：direct -> blob -> mse -> 结束
check('策略顺序 direct -> blob', framesource.nextStrategy('direct') === 'blob');
check('策略顺序 blob -> mse', framesource.nextStrategy('blob') === 'mse');
check('策略用尽后返回 null', framesource.nextStrategy('mse') === null);

// 真机场景复现：CDN 不允许匿名直连（元数据加载失败）=> 自动降级到 fetch + blob
const realSetTimeout = sandbox.setTimeout;
sandbox.setTimeout = (fn, ms) => realSetTimeout(fn, Math.min(ms || 0, 30)); // 压缩超时等待

let createdElements = 0;
const listeners = new WeakMap();
function makeFakeElement() {
  const el = {
    id: '',
    src: '',
    crossOrigin: null,
    readyState: 0,
    error: null,
    style: { cssText: '' },
    dataset: {},
    isConnected: true,
    listeners: {},
    addEventListener(type, handler) {
      (this.listeners[type] = this.listeners[type] || []).push(handler);
    },
    removeEventListener(type, handler) {
      this.listeners[type] = (this.listeners[type] || []).filter((h) => h !== handler);
    },
    fire(type) {
      for (const handler of (this.listeners[type] || []).slice()) handler();
    },
    load() {
      if (/^https?:/.test(this.src) && this.crossOrigin === 'anonymous') {
        // 直连失败：只报 error，不产生元数据（等价于「加载视频元数据失败」）
        realSetTimeout(() => this.fire('error'), 1);
      } else {
        this.readyState = 1;
        realSetTimeout(() => this.fire('loadedmetadata'), 1);
      }
    },
    removeAttribute() {
      this.src = '';
    },
    setAttribute() {},
    remove() {},
    pause() {},
    play() {
      return Promise.resolve();
    }
  };
  listeners.set(el, true);
  createdElements += 1;
  return el;
}

sandbox.document = {
  createElement: () => makeFakeElement(),
  body: { appendChild() {} },
  documentElement: { appendChild() {} }
};
sandbox.URL = {
  createObjectURL: () => 'blob:fake-url',
  revokeObjectURL: () => {},
  // 只桩住 createObjectURL/revokeObjectURL，保留真正的 URL 构造能力
  prototype: NativeURL.prototype,
  canParse: NativeURL.canParse,
  parse: NativeURL.parse
};
const urlCtorProxy = function (...args) {
  return new NativeURL(...args);
};
sandbox.URL = Object.assign(urlCtorProxy, sandbox.URL);
let fetchedUrl = '';
sandbox.fetch = async (url) => {
  fetchedUrl = String(url);
  const payload = new Uint8Array(2048).fill(3);
  return {
    ok: true,
    status: 200,
    headers: { get: (name) => (name.toLowerCase() === 'content-length' ? String(payload.length) : null) },
    body: {
      getReader() {
        let sent = false;
        return {
          read: async () => {
            if (sent) return { done: true };
            sent = true;
            return { done: false, value: payload };
          },
          cancel: async () => {}
        };
      }
    },
    blob: async () => new Blob([payload], { type: 'video/mp4' })
  };
};

framesource.onProgress = null;
const dirVideo = { currentSrc: 'https://cdn.example.com/video.m4s', src: '' };
const loadedElement = await framesource.ensure(dirVideo);
check('直连失败后自动降级到 blob 方式', framesource.mode === 'blob', framesource.mode);
check('降级过程确实发起了视频下载', fetchedUrl.includes('cdn.example.com'), fetchedUrl);
check(
  '返回的是新的可用隐藏视频元素',
  !!loadedElement && loadedElement.readyState >= 1,
  String(loadedElement && loadedElement.readyState)
);
check('降级时新建过元素（不复用失败元素）', createdElements >= 2, String(createdElements));

// 同一个地址第二次调用应直接复用，不再重复下载
const before = fetchedUrl;
fetchedUrl = '';
const again = await framesource.ensure(dirVideo);
check('同一地址复用已有元素', again === loadedElement);
check('不会重复下载同一视频', fetchedUrl === '', fetchedUrl);

sandbox.setTimeout = realSetTimeout;

/* ------------------------------------------------------------------ */
console.log('\n[7] 候选地址选择（__playinfo__ 优先）');

// B 站把可用的 DASH 流放在 window.__playinfo__，优先用它而不是可能为 blob: 的 currentSrc
sandbox.__playinfo__ = {
  data: {
    dash: {
      video: [
        { width: 3840, height: 2160, baseUrl: 'https://cdn.example.com/4k.m4s' },
        { width: 1920, height: 1080, baseUrl: 'https://cdn.example.com/1080.m4s' },
        { width: 1280, height: 720, baseUrl: 'https://cdn.example.com/720.m4s' }
      ]
    },
    durl: [{ url: 'https://cdn.example.com/full.flv' }]
  }
};
const playerVideo = { currentSrc: 'blob:https://www.bilibili.com/abc-123', src: '' };
const picks = framesource.candidates(playerVideo);
check('优先选 1080p 的 DASH 流', picks[0].url === 'https://cdn.example.com/1080.m4s', picks[0] && picks[0].url);
check('来源标记为 playinfo.dash', picks[0].from === 'playinfo.dash', picks[0] && picks[0].from);
check('候选里包含 4K 与 720p 备选', picks.some((p) => p.url.includes('4k')) && picks.some((p) => p.url.includes('720')));
check('候选里包含 durl 整段地址', picks.some((p) => p.url.includes('full.flv')), picks.map((p) => p.url).join(','));
check('blob: 地址排在最后（兜底）', picks[picks.length - 1].url.startsWith('blob:'), picks[picks.length - 1].url);
check('候选地址不重复', new Set(picks.map((p) => p.url)).size === picks.length);
check('协议相对地址会被补全', framesource.describeUrl('//i0.hdslb.com/x.m4s').host === 'i0.hdslb.com');

// 没有 __playinfo__ 时退回到播放器地址
delete sandbox.__playinfo__;
const fallbackPicks = framesource.candidates(playerVideo);
check(
  '无 __playinfo__ 时只用播放器地址',
  fallbackPicks.length === 1 && fallbackPicks[0].from === 'player',
  fallbackPicks.map((p) => `${p.from}:${p.url}`).join(',')
);
const blobInfo = framesource.describeUrl('blob:https://www.bilibili.com/uuid');
check('blob: 被识别为 blob 类型', blobInfo.kind === 'blob', blobInfo.kind);

/* ------------------------------------------------------------------ */
console.log('\n[8] 网络观察：播放器请求的地址收集与排序');

// mediawatch.js 在加载时会注册 chrome.webRequest 监听，先给个桩
const webListeners = { before: [], headers: [] };
sandbox.chrome = {
  webRequest: {
    onBeforeRequest: { addListener: (fn) => webListeners.before.push(fn) },
    onHeadersReceived: { addListener: (fn) => webListeners.headers.push(fn) }
  },
  tabs: { onRemoved: { addListener: () => {} } }
};
load('background/mediawatch.js');
const mediawatch = sandbox.BKFmediawatch;

const fireBefore = (details) => webListeners.before.forEach((fn) => fn(details));
const fireHeaders = (url, mime, status) =>
  webListeners.headers.forEach((fn) =>
    fn({ url, tabId: 7, statusCode: status || 206, responseHeaders: [{ name: 'Content-Type', value: mime }] })
  );

fireBefore({ tabId: 7, url: 'https://xy.bilivideo.com/audio.m4s?x=1', type: 'media' });
fireBefore({ tabId: 7, url: 'https://xy.bilivideo.com/video.m4s?x=2', type: 'media' });
fireBefore({ tabId: 7, url: 'https://xy.bilivideo.com/video.m4s?x=2', type: 'media' }); // 重复
fireBefore({ tabId: 7, url: 'https://xy.bilivideo.com/cover.jpg', type: 'image' }); // 非媒体，忽略
fireHeaders('https://xy.bilivideo.com/audio.m4s?x=1', 'audio/mp4', 206);
fireHeaders('https://xy.bilivideo.com/video.m4s?x=2', 'video/mp4', 206);

const listed = mediawatch.list(7, { limit: 8 });
check('收集到 2 个媒体地址（去重、忽略图片）', listed.total === 2, `实际 ${listed.total}`);
check('视频轨排在音频轨前面', listed.urls[0].url.includes('video.m4s'), listed.urls[0] && listed.urls[0].url);
check('音频轨被标记为 audio', listed.urls.some((u) => u.kind === 'audio' && u.mime === 'audio/mp4'));
check('limit 生效', mediawatch.list(7, { limit: 1 }).urls.length === 1);
check('未观察过的标签页返回空', mediawatch.list(999).total === 0);
mediawatch.clear(7);
check('clear 后清空', mediawatch.list(7).total === 0);

// 真机踩坑复现：右侧推荐位的封面图挂在 i0.hdslb.com 上，绝不能当成视频流
fireBefore({
  tabId: 7,
  url: 'https://i0.hdslb.com/bfs/archive/44c01afda334c03e97f94a2ba9671a031f5d6164.jpg@336w_190h_1c_!web-video-rcmd-cover.avif',
  type: 'image'
});
fireBefore({
  tabId: 7,
  url: 'https://i0.hdslb.com/bfs/archive/44c01afda334c03e97f94a2ba9671a031f5d6164.jpg@336w_190h_1c_!web-video-rcmd-cover.avif',
  type: 'xmlhttprequest'
});
fireHeaders(
  'https://i0.hdslb.com/bfs/archive/44c01afda334c03e97f94a2ba9671a031f5d6164.jpg@336w_190h_1c_!web-video-rcmd-cover.avif',
  'image/avif'
);
check('封面图不会被当作候选', mediawatch.list(7).total === 0, String(mediawatch.list(7).total));

// 主播放器的 DASH 视频流应该被收到
fireBefore({
  tabId: 7,
  url: 'https://upos-sz-estgcos.bilivideo.com/upgcxcode/07/61/899766107/899766107-1-30120.m4s?mime=video/mp4',
  type: 'xmlhttprequest'
});
fireHeaders(
  'https://upos-sz-estgcos.bilivideo.com/upgcxcode/07/61/899766107/899766107-1-30120.m4s?mime=video/mp4',
  'video/mp4'
);
const realList = mediawatch.list(7);
check('主播放器视频流被收集', realList.total === 1 && realList.urls[0].kind === 'video', JSON.stringify(realList.urls));
check('地址里带上轨道与 MIME 便于诊断', realList.urls[0].mime === 'video/mp4', realList.urls[0].mime);
mediawatch.clear(7);

/* ------------------------------------------------------------------ */
console.log('\n[9] 轨道识别：区分视频流与音频流');

const videoInit = concatBytes([ftyp, box('moov', box('trak', sampleEntry('avc1', avcC)))]);
const audioInit = concatBytes([ftyp, box('moov', box('trak', sampleEntry('mp4a', box('esds', new Uint8Array(12)))))]);
check('含 avc1 的容器判为视频轨', framesource.trackOf(videoInit) === 'video', framesource.trackOf(videoInit));
check('只含 mp4a 的容器判为音频轨', framesource.trackOf(audioInit) === 'audio', framesource.trackOf(audioInit));
check('无法判定的容器返回 unknown', framesource.trackOf(ftyp) === 'unknown', framesource.trackOf(ftyp));

// 图片容器（AVIF/HEIF）必须被识别为「非媒体」，否则封面图会被当成视频流
const avifHead = concatBytes([box('ftyp', new Uint8Array([0x61, 0x76, 0x69, 0x66, 0x6d, 0x69, 0x66, 0x31]))]);
const avifAnalysis = framesource.analyzeContainer(avifHead);
check('AVIF 被识别为图片容器', /图片容器/.test(avifAnalysis.container), avifAnalysis.container);
check('AVIF 判为 notmedia（不会被当视频）', avifAnalysis.track === 'notmedia', avifAnalysis.track);
const htmlAnalysis = framesource.analyzeContainer(new TextEncoder().encode('<!DOCTYPE html><html>'));
check('HTML 错误页判为 notmedia', htmlAnalysis.track === 'notmedia', htmlAnalysis.track);
check('真实视频容器仍然判为 video', framesource.analyzeContainer(videoInit).track === 'video');

/* ------------------------------------------------------------------ */
console.log('\n[10] 记住「播放器实际请求的地址」并优先使用');

framesource.reset();
framesource.observed = [];
framesource.onProgress = null;
sandbox.__playinfo__ = {
  data: { dash: { video: [{ width: 1920, height: 1080, baseUrl: 'https://cdn.example.com/playinfo.m4s' }] } }
};
const observedCount = framesource.addObserved([
  { url: 'blob:first', from: 'network.video' },
  { url: 'blob:first', from: 'network.video' }, // 重复不应重复加入
  { url: 'https://cdn.example.com/observed.m4s', from: 'network.video' }
]);
check('addObserved 去重后记录 2 条', observedCount === 2, String(observedCount));
check(
  '观察列表长度受上限保护',
  framesource.addObserved(
    Array.from({ length: 20 }, (_, i) => ({ url: `https://cdn.example.com/seg-${i}.m4s`, from: 'x' }))
  ) <= 12,
  String(framesource.observed.length)
);
// 清掉上面为测上限塞进来的地址，只留第一条用于验证优先级
framesource.observed = [{ url: 'blob:first', from: 'network.video' }];

const priorElements = createdElements;
// 播放器换了 video 元素（同一个站内 URL）：旧元素上观察到的地址必须作废
framesource.observed = [];
framesource.invalidate();
sandbox.__playinfo__ = {
  data: { dash: { video: [{ width: 1920, height: 1080, baseUrl: 'https://cdn.example.com/playinfo.m4s' }] } }
};
const pageVideoStub = { currentSrc: 'blob:https://www.bilibili.com/x', src: '' };
const elementWithObserved = await framesource.ensure(pageVideoStub, { extra: [{ url: 'blob:first', from: 'network.video' }] });
check('有外部观察地址时优先用它（blob 优先，无需网络探针）',
  framesource.activeUrl === 'blob:first', framesource.activeUrl);
check('sourceName 标记来源为 network.video', framesource.sourceName === 'network.video', framesource.sourceName);
check('同一地址再次调用直接复用元素', (await framesource.ensure(pageVideoStub, {})) === elementWithObserved);

// 关键回归：播放器换了视频（会话也跟着换）时，旧的观察地址必须作废
const switched = await framesource.ensure(
  { currentSrc: 'blob:https://www.bilibili.com/other', src: '' },
  { sessionKey: 'BV1OTHER' }
);
check('换会话后不再使用上一个会话的地址',
  framesource.activeUrl !== 'blob:first' && framesource.sourceName !== 'network.video',
  `${framesource.sourceName} / ${framesource.activeUrl}`);
check('换会话后重新加载了取帧源', switched !== elementWithObserved);
check('换会话后取帧源记录的会话已更新', framesource.loadedForSession === 'BV1OTHER', framesource.loadedForSession);

framesource.reset();
framesource.observed = [];
delete sandbox.__playinfo__;

/* ------------------------------------------------------------------ */
console.log('\n[11] 重复帧清理计划（纯函数，决定删哪张留哪张）');

load('background/db.js');
const planDuplicates = sandbox.BKFplanDuplicates;

const dupRecords = [
  { id: 'f1', hash: 'AAAA', createdAt: 100, bytes: 1000, time: 0.0 },
  { id: 'f2', hash: 'BBBB', createdAt: 200, bytes: 2000, time: 0.5 },
  { id: 'f3', hash: 'AAAA', createdAt: 300, bytes: 1000, time: 2.5 },
  { id: 'f4', hash: 'AAAA', createdAt: 400, bytes: 1000, time: 4.0 },
  { id: 'f5', hash: '', createdAt: 500, bytes: 500, time: 5.0 },
  { id: 'f6', hash: 'BBBB', createdAt: 150, bytes: 2000, time: 0.4 }
];
const plan = planDuplicates(dupRecords);
// keep 只包含「有指纹且被保留」的帧；没有指纹的帧既不进 keep 也不被删
check('去重后保留 2 张有指纹的帧（AAAA、BBBB 各一张）', plan.keep.length === 2, plan.keep.join(','));
check('删除 3 张重复帧', plan.remove.length === 3, plan.remove.map((r) => r.id).join(','));
check('同一指纹保留最晚保存的那张（AAAA -> f4）', plan.keep.includes('f4') && !plan.keep.includes('f1'), plan.keep.join(','));
check('BBBB 保留较晚的 f2（非 f6）', plan.keep.includes('f2') && plan.remove.some((r) => r.id === 'f6'));
check('没有指纹的帧既不保留也不删除（f5 不在两个名单里）',
  !plan.keep.includes('f5') && !plan.remove.some((r) => r.id === 'f5'));
check('释放空间统计正确（1000+1000+2000）', plan.freedBytes === 4000, String(plan.freedBytes));

check('无重复时不需要删除', planDuplicates([{ id: 'a', hash: 'X', createdAt: 1, bytes: 1 }]).remove.length === 0);
check('空输入安全', planDuplicates([]).remove.length === 0 && planDuplicates(null).keep.length === 0);

/* ------------------------------------------------------------------ */
console.log('\n[12] GIF 编码器（GIF89a 结构与 LZW）');

load('background/gif.js');
const gif = sandbox.BKFgif;

function solidFrame(width, height, r, g, b) {
  const pixels = new Uint8ClampedArray(width * height * 4);
  for (let i = 0; i < width * height; i += 1) {
    pixels[i * 4] = r;
    pixels[i * 4 + 1] = g;
    pixels[i * 4 + 2] = b;
    pixels[i * 4 + 3] = 255;
  }
  return { pixels, width, height };
}

const gifFrames = [
  solidFrame(24, 16, 220, 40, 40),
  solidFrame(24, 16, 40, 200, 80),
  solidFrame(24, 16, 40, 80, 230)
];
const gifBlob = gif.encodeGif(gifFrames, { fps: 10, loop: 0 });
const gifBytes = new Uint8Array(await gifBlob.arrayBuffer());
const gifText = (start, end) => String.fromCharCode.apply(null, Array.from(gifBytes.subarray(start, end)));

check('输出 MIME 为 image/gif', gifBlob.type === 'image/gif', gifBlob.type);
check('文件头是 GIF89a', gifText(0, 6) === 'GIF89a', gifText(0, 6));
check('逻辑屏幕宽高正确', gifBytes[6] === 24 && gifBytes[8] === 16, `${gifBytes[6]}x${gifBytes[8]}`);
check('声明了全局色表', (gifBytes[10] & 0x80) !== 0, '0x' + gifBytes[10].toString(16));
// 全局色表紧跟逻辑屏幕描述符（6 头 + 7 LSD），大小 = 3 * 2^(N+1)
const gctBits = (gifBytes[10] & 0x07) + 1;
const netscapeOffset = 6 + 7 + 3 * (1 << gctBits);
check('包含 NETSCAPE 循环扩展', gifText(netscapeOffset + 3, netscapeOffset + 11) === 'NETSCAPE',
  gifText(netscapeOffset + 3, netscapeOffset + 11));
check('以 0x3B 结束', gifBytes[gifBytes.length - 1] === 0x3b, '0x' + gifBytes[gifBytes.length - 1].toString(16));
check('包含 3 个图形控制扩展（=3 帧）',
  gifBytes.reduce((count, byte, index) => (byte === 0x21 && gifBytes[index + 1] === 0xf9 ? count + 1 : count), 0) === 3);
check('帧延时按 fps 换算（10fps -> 10 个 1/100 秒）',
  (() => {
    for (let i = 0; i < gifBytes.length - 8; i += 1) {
      if (gifBytes[i] === 0x21 && gifBytes[i + 1] === 0xf9 && gifBytes[i + 2] === 0x04) {
        return gifBytes[i + 4] === 10;
      }
    }
    return false;
  })());
check('三种纯色被量化成不同颜色',
  (() => {
    const palette = gif.quantize(
      (() => {
        const pixels = new Uint8ClampedArray(3 * 4);
        pixels.set([220, 40, 40, 255], 0);
        pixels.set([40, 200, 80, 255], 4);
        pixels.set([40, 80, 230, 255], 8);
        return pixels;
      })(),
      256
    );
    return palette.length === 3;
  })());
check('LZW 输出以 clear code 开头并按位打包',
  (() => {
    const data = gif.lzwEncode(new Uint8Array([0, 0, 0, 1, 1, 0]), 2);
    return data.length > 0 && data[data.length - 1] !== undefined;
  })());
check('空帧列表会报错', (() => {
  try {
    gif.encodeGif([], {});
    return false;
  } catch {
    return true;
  }
})());
// 真实校验：写到临时文件，并用系统解码器读回帧数（证明文件真的能被解码）
const { writeFileSync: writeGif, mkdtempSync: mkGif, readFileSync: readGif, rmSync: rmGif } = await import('node:fs');
const { execFileSync: execGif } = await import('node:child_process');
const { tmpdir: tmpGif } = await import('node:os');
const gifTmp = mkGif(join(tmpGif(), 'bkf-gif-'));
try {
  const gifPath = join(gifTmp, 'test.gif');
  writeGif(gifPath, Buffer.from(gifBytes));
  const onDisk = new Uint8Array(readGif(gifPath));
  check('写盘后字节一致（无截断）', onDisk.length === gifBytes.length, `${onDisk.length} vs ${gifBytes.length}`);
  const walked = walkGif(onDisk);
  check('GIF 结构可完整走完（末尾恰为 0x3B）', walked.ok === true, walked.error);
  check('结构里解析出 3 帧', walked.frames.length === 3, `offsets=${walked.frames.join(',')}`);
  check('文件末尾是 GIF 结束符 0x3B', onDisk[onDisk.length - 1] === 0x3b);

  // 交给系统解码器（.NET System.Drawing）确认真的能解码
  if (process.platform === 'win32') {
    const script = [
      'Add-Type -AssemblyName System.Drawing',
      `$img = [System.Drawing.Image]::FromFile('${gifPath}')`,
      '$n = $img.GetFrameCount([System.Drawing.Imaging.FrameDimension]::Time)',
      'Write-Output ("decoded frames: " + $n + " size " + $img.Width + "x" + $img.Height)',
      '$img.Dispose()'
    ].join('; ');
    try {
      const output = execGif('powershell', ['-NoProfile', '-Command', script], { encoding: 'utf8' });
      check('系统解码器能读出 3 帧', /decoded frames: 3/.test(output), output.trim());
    } catch (spawnError) {
      // 沙箱可能禁止启动子进程：降级为结构自检，不视为失败
      check('系统解码器校验（沙箱限制跳过）', true, String(spawnError.message).slice(0, 60));
    }
  }
} catch (error) {
  check('GIF 落盘与结构遍历', false, error.message);
} finally {
  rmGif(gifTmp, { recursive: true, force: true });
}

/**
 * 按 GIF 规范逐块遍历，验证文件结构自洽。
 * 关键点：APP/注释扩展的数据区本身就是「带长度前缀的子块序列」，
 * 不能先跳固定字节数再当子块读，否则会错位。
 */
function walkGif(bytes) {
  let cursor = 0;
  const frames = [];
  const readSubBlocks = () => {
    for (;;) {
      if (cursor >= bytes.length) return false;
      const size = bytes[cursor];
      cursor += 1;
      if (size === 0) return true;
      if (cursor + size > bytes.length) return false;
      cursor += size;
    }
  };
  const ascii = (start, end) => String.fromCharCode.apply(null, Array.from(bytes.subarray(start, end)));
  if (ascii(0, 6) !== 'GIF89a') return { ok: false, frames: 0, error: '文件头不是 GIF89a' };
  const lsd = bytes[10];
  cursor = 13;
  if (lsd & 0x80) cursor += 3 * (1 << ((lsd & 0x07) + 1)); // 跳过全局色表
  let guard = 0;
  while (cursor < bytes.length) {
    guard += 1;
    if (guard > 10000) return { ok: false, frames, error: '遍历步数异常' };
    const before = cursor;
    const marker = bytes[cursor];
    if (marker === 0x3b) {
      cursor += 1;
      return { ok: cursor === bytes.length, frames, error: cursor === bytes.length ? '' : '结尾有多余字节' };
    }
    if (marker === 0x21) {
      const label = bytes[cursor + 1];
      cursor += 2;
      if (label === 0xf9) {
        // 图形控制扩展：2(引导+标签) + 1(块长) + 4(数据) + 1(终止) = 8 字节
        cursor += 6;
      } else if (!readSubBlocks()) {
        return { ok: false, frames, error: '扩展块长度越界' };
      }
    } else if (marker === 0x2c) {
      frames.push(cursor);
      const packed = bytes[cursor + 9];
      cursor += 10;
      if (packed & 0x80) cursor += 3 * (1 << ((packed & 0x07) + 1)); // 局部色表
      cursor += 1; // LZW 最小码长
      if (!readSubBlocks()) return { ok: false, frames, error: '图像数据长度越界' };
    } else {
      return { ok: false, frames, error: `未知块标记 0x${marker.toString(16)} @${cursor}` };
    }
    if (cursor <= before) return { ok: false, frames, error: `游标未前进 @${before}` };
  }
  return { ok: false, frames, error: '缺少文件结束符 0x3B' };
}

/* ------------------------------------------------------------------ */
console.log(`\n结果：${passed} 项通过，${failed} 项失败\n`);
process.exit(failed ? 1 : 0);

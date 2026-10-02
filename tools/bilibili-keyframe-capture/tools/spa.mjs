/**
 * spa.mjs —— 站内跳转（SPA）的复现测试
 *
 * 目标：模拟 B 站站内跳转（地址 / 分P 变化，页面不刷新），
 * 验证扩展切到新会话，并能正确重建取帧源。
 *
 * 设计原则（踩坑后收敛）：**取帧源只按「会话」判断归属**。
 * 会话身份 = 视频号 + cid + 分P（不含时长）；取帧源记录它服务哪个会话，
 * 会话不一致就重建。不比对媒体地址、没有 pending 状态机。
 *
 * 运行：node tools/bilibili-keyframe-capture/tools/spa.mjs
 */
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const here = dirname(fileURLToPath(import.meta.url));
const rootDir = join(here, '..');

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

/* ---------------- 桩：video 元素（会触发 loadedmetadata / loadeddata） ---------------- */

function makeElement(tag) {
  const el = {
    tagName: String(tag || 'div').toUpperCase(),
    id: '',
    className: '',
    textContent: '',
    innerHTML: '',
    hidden: false,
    src: '',
    duration: NaN,
    currentTime: 0,
    paused: true,
    ended: false,
    muted: false,
    playbackRate: 1,
    error: null,
    width: 0,
    height: 0,
    readyState: 0,
    dataset: {},
    style: { cssText: '' },
    children: [],
    isConnected: true,
    _listeners: {},
    addEventListener(type, fn) {
      (this._listeners[type] = this._listeners[type] || []).push(fn);
    },
    removeEventListener(type, fn) {
      this._listeners[type] = (this._listeners[type] || []).filter((item) => item !== fn);
    },
    fire(type) {
      for (const fn of (this._listeners[type] || []).slice()) fn();
    },
    /** 模拟真实 video：load() 后异步就绪 */
    load() {
      if (!this.src) return;
      this.readyState = 0;
      setTimeout(() => {
        this.readyState = 1;
        this.fire('loadedmetadata');
      }, 1);
      setTimeout(() => {
        this.readyState = 2;
        this.fire('loadeddata');
      }, 2);
    },
    pause() {},
    play() {
      return Promise.resolve();
    },
    append(...nodes) {
      this.children.push(...nodes);
    },
    appendChild(node) {
      this.children.push(node);
      return node;
    },
    insertBefore(node) {
      this.children.push(node);
      return node;
    },
    remove() {
      this.isConnected = false;
    },
    removeAttribute() {},
    setAttribute() {},
    querySelector: () => makeElement('div'),
    querySelectorAll: () => [],
    closest: () => null,
    focus() {},
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 200, height: 300 }),
    getContext: () => ({
      imageSmoothingEnabled: false,
      imageSmoothingQuality: '',
      drawImage() {},
      getImageData: (x, y, w, h) => ({ data: new Uint8ClampedArray(w * h * 4), width: w, height: h })
    }),
    toDataURL: () => 'data:image/jpeg;base64,AAAA',
    attachShadow() {
      return { append() {}, querySelector: () => makeElement('div'), querySelectorAll: () => [] };
    }
  };
  el.currentSrc = '';
  return el;
}

const player = makeElement('video');
player.requestVideoFrameCallback = () => 0;

/** 构造一个能被识别为「视频轨」的最小 MP4 头（ftyp + moov/avc1/avcC） */
function makeMp4Head() {
  const box = (type, content) => {
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
  };
  const concat = (list) => {
    const total = list.reduce((sum, item) => sum + item.length, 0);
    const out = new Uint8Array(total);
    let offset = 0;
    for (const item of list) {
      out.set(item, offset);
      offset += item.length;
    }
    return out;
  };
  const avcC = box('avcC', new Uint8Array([1, 0x64, 0x00, 0x28, 0xff, 0xe1]));
  const avc1 = box('avc1', concat([new Uint8Array(8), avcC]));
  return concat([box('ftyp', new Uint8Array([0x69, 0x73, 0x6f, 0x6d])), box('moov', box('trak', avc1))]);
}

const MP4_HEAD = makeMp4Head();

/* ---------------- 桩：运行环境 ---------------- */

const sandbox = {
  console,
  setTimeout,
  clearTimeout,
  setInterval: () => 0,
  clearInterval: () => {},
  queueMicrotask,
  TextEncoder,
  TextDecoder,
  Blob,
  Uint8Array,
  Uint8ClampedArray,
  Float32Array,
  Int16Array,
  ArrayBuffer,
  DataView,
  performance,
  Date,
  Math,
  JSON,
  AbortController,
  URL: function (...args) {
    return new globalThis.URL(...args);
  },
  // 让直连/探针策略都能成功：返回 206 + 最小 MP4 头
  fetch: async () => ({
    ok: true,
    status: 206,
    headers: { get: () => null },
    arrayBuffer: async () => MP4_HEAD.slice().buffer
  })
};
sandbox.window = sandbox;
sandbox.self = sandbox;
sandbox.globalThis = sandbox;
sandbox.navigator = {};
sandbox.location = {
  href: 'https://www.bilibili.com/video/BV1AAA',
  pathname: '/video/BV1AAA',
  searchParams: new URLSearchParams()
};
sandbox.addEventListener = () => {};
sandbox.removeEventListener = () => {};
sandbox.dispatchEvent = () => true;
sandbox.document = {
  readyState: 'complete',
  title: '视频A_哔哩哔哩_bilibili',
  head: makeElement('head'),
  body: makeElement('body'),
  documentElement: makeElement('html'),
  createElement: (tag) => makeElement(tag),
  getElementById: () => null,
  querySelector: (selector) => (String(selector).includes('video') ? player : null),
  querySelectorAll: (selector) => (String(selector).includes('video') ? [player] : []),
  addEventListener() {},
  removeEventListener() {},
  dispatchEvent: () => true,
  createTextNode: (text) => ({ textContent: text })
};

for (const file of ['content/core.js', 'content/detector.js', 'content/framesource.js']) {
  vm.runInNewContext(readFileSync(join(rootDir, file), 'utf8'), sandbox, { filename: file });
}
const NS = sandbox.__BKF__;
const fs = NS.framesource;

function navigateTo(href, mediaUrl, duration) {
  const parsed = new URL(href);
  sandbox.location.href = href;
  sandbox.location.pathname = parsed.pathname;
  sandbox.location.searchParams = parsed.searchParams;
  player.currentSrc = mediaUrl;
  player.src = mediaUrl;
  player.duration = duration;
  player.readyState = 4;
}

const idOf = () => NS.core.sessionIdentity({ href: sandbox.location.href }).id;

/* ================= 一、会话身份 ================= */

console.log('\n[1] 会话身份（换视频必须换会话，同一视频不能分裂）');

navigateTo('https://www.bilibili.com/video/BV1AAA?p=1&spm_id_from=333&vd_source=abc', 'https://cdn/AAA.m4s', 300);
const idA = idOf();
check('视频A 会话 id = BV1AAA', idA === 'BV1AAA', idA);

navigateTo('https://www.bilibili.com/video/BV1AAA?p=1&spm_id_from=999', 'https://cdn/AAA.m4s', 301);
check('同一视频 + 跟踪参数变化 → 会话 id 不变（不会分裂）', idOf() === idA, idOf());

navigateTo('https://www.bilibili.com/video/BV1AAA?p=2', 'https://cdn/AAA-p2.m4s', 302);
check('换分P → 会话 id 变化', idOf() === 'BV1AAA-p2', idOf());

navigateTo('https://www.bilibili.com/video/BV1BBB', 'https://cdn/BBB.m4s', 500);
const idB = idOf();
check('换视频 → 会话 id 变化', idB === 'BV1BBB' && idB !== idA, `${idA} -> ${idB}`);

navigateTo('https://www.bilibili.com/bangumi/play/ep123456', 'https://cdn/ep.m4s', 600);
check('番剧页用 ep 号', idOf() === 'ep123456', idOf());

check(
  '会话 id 不含时长（避免元数据时序导致分裂）',
  NS.core.sessionIdentity({ href: 'https://www.bilibili.com/video/BV1AAA?p=1' }).id === 'BV1AAA'
);

/* ================= 二、按会话归属 ================= */

console.log('\n[2] 取帧源只按「会话」判断归属');

check('未加载时视为匹配', NS.core.sourceMatchesSession('', 'BV1AAA') === true);
check('同一会话视为匹配', NS.core.sourceMatchesSession('BV1AAA', 'BV1AAA') === true);
check('换会话视为不匹配', NS.core.sourceMatchesSession('BV1AAA', 'BV1BBB') === false);

/* ================= 三、ensure 行为 ================= */

console.log('\n[3] ensure()：会话变化时才重建（加载是否成功不影响会话记账）');

let created = 0;
const realCreate = fs.createElement.bind(fs);
fs.createElement = () => {
  created += 1;
  return realCreate();
};

/** 加载可能失败（桩环境的网络是假的），但会话记账必须正确 —— 这里容忍加载错误 */
async function ensureQuiet(pageVideo, options) {
  try {
    return await fs.ensure(pageVideo, options);
  } catch (error) {
    return { failed: error.message };
  }
}

// A 会话
navigateTo('https://www.bilibili.com/video/BV1AAA', 'https://cdn/AAA.m4s', 300);
fs.addObserved([{ url: 'https://cdn/AAA.m4s', from: 'network.video' }]);
const beforeA = created;
await ensureQuiet(player, { sessionKey: 'BV1AAA' });
check('A 会话：建立了取帧元素', created > beforeA, `created=${created}`);
check('A 会话：记录了服务的会话', fs.loadedForSession === 'BV1AAA', fs.loadedForSession);
check('A 会话：选用了 A 的候选地址', String(fs.activeUrl).includes('AAA'), fs.activeUrl);

// 同一会话再来一次：不应该新建元素
const beforeA2 = created;
await ensureQuiet(player, { sessionKey: 'BV1AAA' });
check('同一会话再次调用：不新建元素', created === beforeA2, `created=${created}`);

// B 会话（换视频）
navigateTo('https://www.bilibili.com/video/BV1BBB', 'https://cdn/BBB.m4s', 500);
fs.addObserved([{ url: 'https://cdn/BBB.m4s', from: 'network.video' }]);
const beforeB = created;
await ensureQuiet(player, { sessionKey: 'BV1BBB' });
check('B 会话：重建了取帧元素', created > beforeB, `created=${created}`);
check('B 会话：会话标记已更新', fs.loadedForSession === 'BV1BBB', fs.loadedForSession);
check('B 会话：不再使用 A 的地址', !String(fs.activeUrl).includes('AAA'), fs.activeUrl);

/* ================= 四、关键回归 ================= */

console.log('\n[4] 回归：会话不一致时绝不能复用旧 reader');

fs.invalidate();
check('invalidate 清掉会话标记', fs.loadedForSession === '', fs.loadedForSession);
check('invalidate 清掉记住的地址', fs.observed.length === 0);

// 人为造出「已为 A 加载好」的状态，然后直接请求 B 会话
fs.loadedForSession = 'BV1AAA';
fs.activeUrl = 'https://cdn/AAA.m4s';
fs.element = realCreate();
fs.element.readyState = 4; // 看起来完全就绪 —— 最容易被错误复用的情况
fs.observed = [{ url: 'https://cdn/AAA.m4s', from: 'network.video' }];
const beforeC = created;
await ensureQuiet(player, { sessionKey: 'BV1BBB' });
check('会话不一致：重建而不是复用就绪元素', created > beforeC, `created=${created}`);
check('会话不一致：会话标记更新为新的', fs.loadedForSession === 'BV1BBB', fs.loadedForSession);
check('会话不一致：清掉了旧会话的候选地址', !String(fs.activeUrl).includes('AAA'), fs.activeUrl);

console.log(`\n结果：${passed} 项通过，${failed} 项失败\n`);
process.exit(failed ? 1 : 0);

/**
 * smoke.mjs —— 运行时冒烟测试（后台 + 内容脚本）
 *
 * 为什么需要它：`node --check` 只验语法。脚本一旦在**加载期**抛异常，
 * 后面的 addEventListener 就全都不会执行，表现为「按钮点了没反应」，
 * 而语法检查完全看不出来。这里用桩环境把两边都真实跑一遍。
 *
 * 运行：node tools/bilibili-keyframe-capture/tools/smoke.mjs
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

const baseSandbox = () => ({
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
  ArrayBuffer,
  DataView,
  performance,
  Date,
  Math,
  JSON,
  URL: Object.assign(function (...args) {
    return new globalThis.URL(...args);
  }, { createObjectURL: () => 'blob:x', revokeObjectURL: () => {} }),
  fetch: async () => ({ ok: true, status: 200, headers: { get: () => null } }),
  atob: (text) => Buffer.from(String(text), 'base64').toString('binary'),
  btoa: (text) => Buffer.from(String(text), 'binary').toString('base64')
});

/* ================= 一、后台 Service Worker ================= */

console.log('\n[1] 后台脚本加载与消息路由');

function makeRequest(result) {
  const request = { result, onsuccess: null, onerror: null, error: null };
  queueMicrotask(() => request.onsuccess && request.onsuccess());
  return request;
}

function makeStore() {
  const data = new Map();
  return {
    put(value) {
      data.set(value.id, value);
      return makeRequest(value.id);
    },
    get: (key) => makeRequest(data.get(key)),
    delete(key) {
      data.delete(key);
      return makeRequest(undefined);
    },
    getAll: () => makeRequest([...data.values()]),
    getAllKeys: () => makeRequest([...data.keys()]),
    index: () => ({ getAllKeys: () => makeRequest([...data.keys()]) }),
    createIndex() {}
  };
}

const stores = new Map([['sessions', makeStore()], ['frames', makeStore()], ['hashes', makeStore()]]);
const fakeDb = {
  objectStoreNames: { contains: (name) => stores.has(name) },
  createObjectStore(name) {
    const store = makeStore();
    stores.set(name, store);
    return store;
  },
  transaction(name) {
    if (!stores.has(name)) stores.set(name, makeStore());
    const store = stores.get(name);
    const tx = { objectStore: () => store, oncomplete: null, onerror: null, onabort: null, error: null };
    queueMicrotask(() => tx.oncomplete && tx.oncomplete());
    return tx;
  }
};

const bg = baseSandbox();
bg.self = bg;
bg.globalThis = bg;
bg.importScripts = () => {};
bg.indexedDB = { open: () => makeRequest(fakeDb) };
bg.navigator = { storage: { estimate: async () => ({ usage: 0, quota: 1000 }) } };

const messages = [];
const storage = {};
bg.chrome = {
  runtime: {
    lastError: null,
    onMessage: { addListener: (fn) => messages.push(fn) },
    onInstalled: { addListener: () => {} },
    onStartup: { addListener: () => {} },
    getPlatformInfo: () => {}
  },
  commands: { onCommand: { addListener: () => {} } },
  storage: {
    local: {
      get: async (key) => ({ [key]: storage[key] }),
      set: async (obj) => Object.assign(storage, obj)
    },
    onChanged: { addListener: () => {} }
  },
  tabs: {
    query: (q, cb) => (cb ? cb([]) : Promise.resolve([])),
    sendMessage: () => Promise.resolve(),
    create: () => {},
    onRemoved: { addListener: () => {} }
  },
  webRequest: {
    onBeforeRequest: { addListener: () => {} },
    onHeadersReceived: { addListener: () => {} }
  },
  scripting: { executeScript: async () => [] },
  downloads: { download: async () => 1 }
};

let bgError = null;
for (const file of ['background/db.js', 'background/zip.js', 'background/export.js', 'background/mediawatch.js']) {
  try {
    vm.runInNewContext(readFileSync(join(rootDir, file), 'utf8'), bg, { filename: file });
    check(`加载 ${file}`, true);
  } catch (error) {
    check(`加载 ${file}`, false, error.message);
  }
}
try {
  vm.runInNewContext(readFileSync(join(rootDir, 'background/service-worker.js'), 'utf8'), bg, {
    filename: 'background/service-worker.js'
  });
  check('加载 service-worker.js', true);
} catch (error) {
  bgError = error;
  check('加载 service-worker.js', false, error.message);
}
check('后台已注册 onMessage', messages.length > 0, `count=${messages.length}`);

function sendBg(message) {
  return new Promise((resolve) => {
    let settled = false;
    const done = (value) => {
      if (settled) return;
      settled = true;
      resolve(value);
    };
    for (const listener of messages) {
      const kept = listener(message, { tab: { id: 1 } }, done);
      if (!kept && !settled) setTimeout(() => done(null), 5);
    }
    setTimeout(() => done(null), 500);
  });
}

if (!bgError && messages.length) {
  const settingsResult = await sendBg({ type: 'settings.get' });
  check('settings.get 有响应', !!settingsResult && settingsResult.ok === true);
  check('默认模式是仅手动', settingsResult && settingsResult.data.mode === 'off', settingsResult && settingsResult.data.mode);

  const saveResult = await sendBg({ type: 'settings.save', patch: { mode: 'every', intervalMs: 300 } });
  check(
    'settings.save 生效',
    !!saveResult && saveResult.ok === true && saveResult.data.mode === 'every' && saveResult.data.intervalMs === 300,
    JSON.stringify(saveResult && saveResult.data)
  );

  const usage = await sendBg({ type: 'db.usage' });
  check('db.usage 有响应', !!usage && usage.ok === true, usage && usage.error);

  const sessions = await sendBg({ type: 'db.listSessions' });
  check('db.listSessions 有响应', !!sessions && sessions.ok === true, sessions && sessions.error);

  const unknown = await sendBg({ type: 'no.such.type' });
  check('未知消息返回可读错误', !!unknown && unknown.ok === false && /未知消息类型/.test(unknown.error));

  const framePayload = {
    sessionKey: 'smoke-session',
    time: 1.5,
    hash: 'deadbeef',
    width: 100,
    height: 60,
    imageDataUrl: 'data:image/jpeg;base64,AAAA',
    thumbnailDataUrl: 'data:image/jpeg;base64,AAAA',
    video: { title: '冒烟测试' }
  };
  const addFrame = await sendBg({ type: 'db.addFrame', frame: framePayload });
  check(
    'db.addFrame 能写入帧',
    !!addFrame && addFrame.ok === true && addFrame.data.stored === true,
    JSON.stringify(addFrame && (addFrame.error || addFrame.data))
  );

  const duplicate = await sendBg({ type: 'db.addFrame', frame: Object.assign({}, framePayload, { time: 1.6 }) });
  check(
    '同指纹重复帧被拒（返回 duplicate）',
    !!duplicate && duplicate.ok === true && duplicate.data.stored === false && duplicate.data.duplicate === true,
    JSON.stringify(duplicate && duplicate.data)
  );

  const pruned = await sendBg({ type: 'db.pruneDuplicates', sessionId: 'smoke-session' });
  check('db.pruneDuplicates 有响应', !!pruned && pruned.ok === true, pruned && pruned.error);
} else {
  check('后台消息路由冒烟', false, bgError ? bgError.message : '没有 onMessage');
}

/* ================= 二、内容脚本 ================= */

console.log('\n[2] 内容脚本加载与事件绑定');

function makeClassList() {
  const set = new Set();
  return {
    _set: set,
    add: (...names) => names.forEach((n) => set.add(n)),
    remove: (...names) => names.forEach((n) => set.delete(n)),
    toggle: (name, force) => (force === undefined ? (set.has(name) ? set.delete(name) : set.add(name)) : (force ? set.add(name) : set.delete(name))),
    contains: (name) => set.has(name)
  };
}

function makeElement(tag) {
  const el = {
    tagName: String(tag || 'div').toUpperCase(),
    id: '',
    className: '',
    textContent: '',
    innerHTML: '',
    hidden: false,
    disabled: false,
    checked: false,
    value: '',
    title: '',
    alt: '',
    src: '',
    dataset: {},
    style: { cssText: '', setProperty() {}, removeProperty() {} },
    classList: makeClassList(),
    children: [],
    childNodes: [],
    parentNode: null,
    isConnected: true,
    _listeners: {},
    addEventListener(type, handler) {
      (this._listeners[type] = this._listeners[type] || []).push(handler);
    },
    removeEventListener(type, handler) {
      this._listeners[type] = (this._listeners[type] || []).filter((h) => h !== handler);
    },
    dispatch(type, event) {
      const handlers = (this._listeners[type] || []).slice();
      for (const handler of handlers) handler(Object.assign({ type, preventDefault() {}, stopPropagation() {} }, event || {}));
      return handlers.length;
    },
    append(...nodes) {
      for (const node of nodes) {
        this.children.push(node);
        this.childNodes.push(node);
        if (node && typeof node === 'object') node.parentNode = this;
      }
    },
    appendChild(node) {
      this.append(node);
      return node;
    },
    insertBefore(node) {
      this.append(node);
      return node;
    },
    remove() {
      this.isConnected = false;
    },
    removeAttribute() {},
    setAttribute(name, value) {
      this[name] = value;
    },
    getAttribute: () => null,
    querySelector: () => makeElement('div'),
    querySelectorAll: () => [],
    closest: () => null,
    focus() {},
    load() {},
    pause() {},
    play: () => Promise.resolve(),
    attachShadow() {
      return { append() {}, querySelector: () => makeElement('div'), querySelectorAll: () => [] };
    },
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 200, height: 300 }),
    getContext: () => ({
      imageSmoothingEnabled: false,
      imageSmoothingQuality: '',
      drawImage() {},
      getImageData: (x, y, w, h) => ({ data: new Uint8ClampedArray(w * h * 4), width: w, height: h })
    }),
    toDataURL: () => 'data:image/jpeg;base64,AAAA',
    width: 0,
    height: 0
  };
  return el;
}

const content = baseSandbox();
content.window = content;
content.self = content;
content.globalThis = content;
content.navigator = { clipboard: { writeText: async () => {} }, storage: {} };
content.location = { href: 'https://www.bilibili.com/video/BV1SMOKE' };
// core.on / core.emit 用的是 window 上的自定义事件
content.addEventListener = () => {};
content.removeEventListener = () => {};
content.dispatchEvent = () => true;
content.document = {
  readyState: 'complete',
  title: '冒烟测试视频_哔哩哔哩_bilibili',
  head: makeElement('head'),
  body: makeElement('body'),
  documentElement: makeElement('html'),
  createElement: (tag) => makeElement(tag),
  getElementById: () => null,
  querySelector: () => null,
  querySelectorAll: () => [],
  addEventListener() {},
  removeEventListener() {},
  dispatchEvent: () => true,
  createTextNode: (text) => ({ textContent: text })
};
// 让 waitForVideo 立刻放弃，避免初始化卡在轮询上
content.setTimeout = (fn) => {
  if (fn) queueMicrotask(fn);
  return 0;
};

const contentMessages = [];
// 内存版 storage，get/set 互相真实可见（否则「设置有没有真的存下来」根本测不出来）
const contentStorage = {};
content.chrome = {
  runtime: {
    lastError: null,
    onMessage: { addListener: (fn) => contentMessages.push(fn) },
    sendMessage: async () => ({ ok: true, data: {} })
  },
  storage: {
    local: {
      get: async (key) => (key === undefined ? Object.assign({}, contentStorage) : { [key]: contentStorage[key] }),
      set: async (obj) => Object.assign(contentStorage, obj)
    },
    onChanged: { addListener: () => {} }
  },
  tabs: { sendMessage: async () => ({ ok: true, data: {} }) }
};

const contentFiles = [
  'content/core.js',
  'content/detector.js',
  'content/framesource.js',
  'content/capture.js',
  'content/scanner.js',
  'content/panel.js',
  'content/gallery.js',
  'content/main.js'
];
let contentError = null;
for (const file of contentFiles) {
  try {
    vm.runInNewContext(readFileSync(join(rootDir, file), 'utf8'), content, { filename: file });
    check(`加载 ${file}`, true);
  } catch (error) {
    contentError = error;
    check(`加载 ${file}`, false, error.message);
    break;
  }
}

const NS = content.__BKF__ || {};
check('命名空间已建立', !!NS.core && !!NS.panel && !!NS.gallery && !!NS.scanner && !!NS.framesource);
// main.js 的 start() 是异步的（要先等 video），给一拍让它完成 onMessage 注册
await new Promise((resolve) => setTimeout(resolve, 60));
check('内容脚本已注册 onMessage', contentMessages.length > 0, `count=${contentMessages.length}`);

// panel.init 是按钮绑定的入口：它要是抛异常，按钮就全没反应
if (!contentError && NS.panel && NS.core) {
  try {
    const fakeController = {
      settings: { mode: 'auto', intervalMs: 100, panelLeft: 12, panelTop: null, showPanel: true },
      captureNow: async () => ({ ok: true }),
      toggleAuto: async () => true,
      setMode: async (mode) => mode,
      setPanelVisible() {},
      getStats: () => ({
        running: false,
        mode: 'auto',
        intervalMs: 100,
        busy: false,
        hasVideo: true,
        saved: 0,
        sampled: 0,
        skipped: 0,
        hitRate: 0,
        pass: 1,
        status: '冒烟',
        error: '',
        scanning: false,
        scan: null
      })
    };
    NS.panel.init(fakeController);
    check('panel.init 未抛异常（面板按钮才能绑上事件）', true);
    const buttons = NS.panel.els || {};
    check('面板按钮引用齐全', !!(buttons.snap && buttons.scan && buttons.replay && buttons.toggle && buttons.gallery && buttons.mode));
    let handled = 0;
    if (buttons.snap) handled += buttons.snap.dispatch('click') > 0 ? 1 : 0;
    if (buttons.replay) handled += buttons.replay.dispatch('click') > 0 ? 1 : 0;
    if (buttons.scan) handled += buttons.scan.dispatch('click') > 0 ? 1 : 0;
    if (buttons.toggle) handled += buttons.toggle.dispatch('click') > 0 ? 1 : 0;
    if (buttons.gallery) handled += buttons.gallery.dispatch('click') > 0 ? 1 : 0;
    check('面板按钮都绑定了点击处理', handled === 5, `已绑定 ${handled}/5`);
    // renderStats 出错会连带状态区空白
    NS.panel.renderStats();
    check('panel.renderStats 未抛异常', true);

    // 图库 CSS 的关键约束：选择框规则必须排在通用 input 规则之后，
    // 否则会被 appearance:none 覆盖，checkbox 就变成点不出状态的空方块
    const gallerySrc = readFileSync(join(rootDir, 'content/gallery.js'), 'utf8');
    const cssStart = gallerySrc.indexOf('GALLERY_CSS = `');
    const cssEnd = gallerySrc.indexOf('`;', cssStart);
    const css = gallerySrc.slice(cssStart, cssEnd);
    const genericInput = css.indexOf('appearance: none');
    const checkRule = css.indexOf('input.check');
    check('图库 CSS 里有 input.check 规则', checkRule > 0, String(checkRule));
    check(
      'input.check 规则在通用 input 规则之后（避免被覆盖）',
      checkRule > genericInput && genericInput > 0,
      `generic@${genericInput} check@${checkRule}`
    );
    check('checkbox 用 .on 类表达选中态', /input\.check\.on/.test(css) && /classList\.toggle\('on'/.test(gallerySrc));

    // 「已选 N」不能被预览位置覆盖：两者必须是不同的元素
    check(
      '已选数量与预览位置用的是两个元素',
      /selInfo: backdrop\.querySelector\('\.selinfo'\)/.test(gallerySrc) &&
        /viewInfo: backdrop\.querySelector\('\.viewinfo'\)/.test(gallerySrc)
    );
    check(
      '预览位置不再写入 selInfo',
      !/selInfo\.textContent = `\$\{gallery\.viewerIndex \+ 1\}/.test(gallerySrc)
    );
    check('工具栏按钮齐全（含回到原播放页）', /class="origin"/.test(gallerySrc) && /openOriginPage/.test(gallerySrc));
  } catch (error) {
    check('panel.init / 按钮绑定', false, `${error.name}: ${error.message}`);
  }
}

/* ================= 三、开始/暂停自动抓取的真实链路 ================= */

console.log('\n[3] 「开始 / 暂停自动抓取」链路（面板按钮 → controller → 设置 → 存储变更）');

if (!contentError && NS.controller && NS.core) {
  // 这里用一个「只替换掉依赖外部环境的部分」的 controller：真实的 toggleAuto / setRunning /
  // reloadSettings 逻辑照跑，只把视频、面板渲染、后台消息换成桩
  const controller = NS.controller;
  controller.settings = {
    mode: 'auto',
    lastActiveMode: 'auto',
    intervalMs: 100,
    showPanel: true,
    panelExpanded: true,
    panelLeft: 12,
    panelTop: null
  };
  controller.video = makeElement('video');
  controller.video.currentTime = 10;
  controller.video.paused = false;
  controller.video.readyState = 4;
  controller.video.isConnected = true;
  controller.running = false;
  controller.busy = false;
  controller.autoPaused = false;
  controller.savedCount = 5;

  // 面板渲染改成空实现，避免桩 DOM 干扰
  const realRender = NS.panel.renderStats;
  NS.panel.renderStats = () => {};

  // 后台消息：settings.save 走真实的后台处理器
  const savedPatches = [];
  const realSend = content.chrome.runtime.sendMessage;
  content.chrome.runtime.sendMessage = async (message) => {
    if (message && message.type === 'settings.save') {
      savedPatches.push(message.patch);
      const result = await sendBg(message);
      return result;
    }
    return { ok: true, data: {} };
  };
  // 内容脚本侧保存设置走 storage.local，这里读出真实落盘内容
  const storedSettings = () => (contentStorage.settings || {});

  let toggleError = null;
  // 关键回归点：默认模式就是 off，此时点「开始」必须走进「开始」分支
  controller.settings.mode = 'off';
  controller.running = false;
  try {
    await controller.toggleAuto();
  } catch (error) {
    toggleError = error;
  }
  check('默认 off 状态下点「开始」能真正启动',
    controller.running === true && controller.settings.mode === 'auto',
    JSON.stringify({ running: controller.running, mode: controller.settings.mode }));
  // 恢复成「未运行」的状态继续原有链路断言
  controller.running = false;
  controller.settings.mode = 'auto';

  try {
    // 第一次点击：应当开始（running = true）
    await controller.toggleAuto();
  } catch (error) {
    toggleError = error;
  }
  check('点击开始未抛异常', !toggleError, toggleError && `${toggleError.name}: ${toggleError.message}`);
  check('点击开始后 running = true', controller.running === true, String(controller.running));
  check('点击开始把 mode=auto 落盘',
    storedSettings().mode === 'auto',
    JSON.stringify(storedSettings()));
  check('点击开始后模式不是 off', controller.settings.mode === 'auto', controller.settings.mode);

  // 第二次点击：应当暂停，并且把 mode 持久化成 off
  toggleError = null;
  try {
    await controller.toggleAuto();
  } catch (error) {
    toggleError = error;
  }
  check('点击暂停未抛异常', !toggleError, toggleError && `${toggleError.name}: ${toggleError.message}`);
  check('点击暂停后 running = false', controller.running === false, String(controller.running));
  check('点击暂停把 mode 持久化为 off（重进页面也不会自动跑）',
    controller.settings.mode === 'off' && storedSettings().mode === 'off',
    JSON.stringify({ mode: controller.settings.mode, stored: storedSettings() }));
  check('点击暂停记住了原来的模式',
    controller.settings.lastActiveMode === 'auto' && storedSettings().lastActiveMode === 'auto',
    JSON.stringify(storedSettings()));

  // 模拟「设置变更广播」回到内容脚本：暂停状态不能被 reloadSettings 冲掉
  await controller.reloadSettings();
  check('设置广播后仍保持暂停', controller.running === false, String(controller.running));
  check('设置广播后 mode 仍是 off', controller.settings.mode === 'off', controller.settings.mode);

  // 第三次点击：应当恢复到记住的模式并再次运行
  await controller.toggleAuto();
  check('再次点击后恢复运行', controller.running === true, String(controller.running));
  check('恢复时用的是记住的模式（auto）',
    controller.settings.mode === 'auto' && storedSettings().mode === 'auto',
    JSON.stringify({ mode: controller.settings.mode, stored: storedSettings() }));

  // 面板按钮本身是否真的接到了 toggleAuto
  NS.panel.renderStats = realRender;
  content.chrome.runtime.sendMessage = realSend;
  let toggleCalls = 0;
  const originalToggle = controller.toggleAuto.bind(controller);
  controller.toggleAuto = async () => {
    toggleCalls += 1;
    return originalToggle();
  };
  controller.settings.mode = 'auto';
  controller.running = true;
  const bound = NS.panel.els && NS.panel.els.toggle && NS.panel.els.toggle.dispatch('click');
  check('面板「开始/暂停」按钮确实绑定了处理器', bound > 0, `绑定数 ${bound}`);
  check('点击面板按钮会调用 controller.toggleAuto', toggleCalls === 1, `调用 ${toggleCalls} 次`);
} else {
  check('开始/暂停链路冒烟', false, contentError ? contentError.message : '缺少 controller');
}

console.log(`\n结果：${passed} 项通过，${failed} 项失败\n`);
process.exit(failed ? 1 : 0);
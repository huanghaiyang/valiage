/**
 * service-worker.js —— 后台主控（MV3）
 *
 * 职责：
 *   1. 接收内容脚本抓到的帧，写入 IndexedDB（不受宿主页面的 CSP / 存储清理影响）；
 *   2. 提供会话/帧的查询与删除接口，并把变更广播给所有 B 站标签页；
 *   3. 处理导出（ZIP / 单帧下载 / 文件夹导出清单）；
 *   4. 处理快捷键命令与扩展图标弹窗的消息。
 */
importScripts('db.js', 'zip.js', 'gif.js', 'export.js', 'mediawatch.js');

const db = self.BKFdb;
const exporter = self.BKFexporter;
const mediawatch = self.BKFmediawatch;

/** 常规（隔离世界）的内容脚本文件，按依赖顺序 */
const CONTENT_FILES = [
  'content/core.js',
  'content/detector.js',
  'content/framesource.js',
  'content/capture.js',
  'content/scanner.js',
  'content/panel.js',
  'content/gallery.js',
  'content/main.js'
];

/**
 * 在主世界钩住 History API，检测 B 站（Vue SPA）的站内跳转。
 *
 * B 站是 Vue SPA，站内跳转（点推荐视频 / 换分P / 切番剧）走 history.pushState /
 * replaceState，并且 B 站自己对这些函数还有一层封装 —— 但无论封几层，最终都会
 * 经过原生方法，所以钩住原生方法一定抓得到。
 *
 * 在隔离世界里读 location 虽然也能拿到新地址，但：
 *   · 只能靠轮询，慢（1.5 秒）；
 *   · 读页面 window 上的 __INITIAL_STATE__ 拿到的是**旧值**（跨 JS 世界），
 *     所以 cid 之类的兜底一直是错的。
 * 因此这里在主世界直接钩住，事件驱动、零延迟、拿得到真实状态。
 */
function mainWorldNavHook() {
  if (window.__bkfNavHook) return 'already';
  window.__bkfNavHook = true;

  let last = location.href;

  const notify = (reason) => {
    const href = location.href;
    if (href === last && reason !== 'popstate' && reason !== 'hashchange') return;
    last = href;
    // 同时用自定义事件与 postMessage 广播（隔离世界两种都能收到）
    try {
      window.dispatchEvent(new CustomEvent('bkf:navigate', { detail: { href, reason } }));
    } catch (error) {
      /* 忽略 */
    }
    try {
      window.postMessage({ __bkf: 'navigate', href, reason }, location.origin);
    } catch (error) {
      /* 忽略 */
    }
  };

  for (const name of ['pushState', 'replaceState']) {
    const original = history[name];
    if (typeof original !== 'function') continue;
    history[name] = function (...args) {
      const result = original.apply(this, args);
      notify(name);
      return result;
    };
  }
  window.addEventListener('popstate', () => notify('popstate'));
  window.addEventListener('hashchange', () => notify('hashchange'));
  return 'hooked';
}

/** 记录已经注入过钩子的标签页，避免重复注入 */
const navHookedTabs = new Set();

/**
 * 在主世界（页面自己的 JS 环境）里找播放信息。
 * B 站的 __playinfo__ 挂在页面 window 上，隔离世界读不到，所以必须注入主世界执行。
 */
function mainWorldPlayinfo() {
  const urls = [];
  const seen = new Set();
  const add = (url) => {
    if (typeof url !== 'string' || !url) return;
    if (!/^https?:/.test(url)) return;
    if (seen.has(url)) return;
    seen.add(url);
    urls.push(url);
  };
  const visit = (node, depth) => {
    if (!node || typeof node !== 'object' || depth > 6) return;
    if (Array.isArray(node)) {
      for (const item of node) visit(item, depth + 1);
      return;
    }
    for (const key of Object.keys(node)) {
      const value = node[key];
      if (/^(baseUrl|base_url|url|backupUrl|backup_url)$/i.test(key)) {
        if (Array.isArray(value)) value.forEach(add);
        else add(value);
      } else if (value && typeof value === 'object') {
        visit(value, depth + 1);
      }
    }
  };
  try {
    const candidates = [window.__playinfo__, window.playinfo, window.__PLAYINFO__];
    for (const item of candidates) {
      if (!item) continue;
      const data = item.data && (item.data.dash || item.data.durl) ? item.data : item;
      visit(data, 0);
      if (urls.length) break;
    }
    if (!urls.length) {
      // 退一步：播放器实例上通常也存着 playinfo
      const player = window.player || (window.__BILI_PLAYER__ && window.__BILI_PLAYER__.player);
      const info = player && player.getPlayInfo && player.getPlayInfo();
      if (info) {
        visit(info.data && (info.data.dash || info.data.durl) ? info.data : info, 0);
      }
    }
  } catch (error) {
    return { urls: [], error: String(error && error.message) };
  }
  return { urls: urls.slice(0, 8) };
}

const DEFAULT_SETTINGS = {
  mode: 'off',
  hashThreshold: 0.12,
  madThreshold: 0.1,
  minChange: 0.025,
  autoPruneDuplicates: true,
  lastActiveMode: 'auto',
  intervalMs: 100,
  format: 'jpeg',
  quality: 0.85,
  maxWidth: 1280,
  thumbWidth: 320,
  maxFramesPerSession: 300,
  showPanel: true,
  panelExpanded: true,
  panelLeft: 12,
  panelTop: null,
  autoPause: false,
  autoExport: 'none',
  scanInterval: 1,
  scanRate: 4,
  scanPauseMain: true,
  scanOpenGallery: true,
  settingsVersion: 3
};

/** 旧版本用过的默认值，需要在迁移时替换掉 */
const LEGACY_INTERVAL_MS = 600;

let settingsChecked = false;

/** 合并默认设置，过滤未知键并做范围校验（后台侧的最小实现） */
function normalizeSettings(raw) {
  const out = Object.assign({}, DEFAULT_SETTINGS, raw || {});
  if (!['auto', 'every', 'interval', 'off'].includes(out.mode)) out.mode = 'off';
  if (!['auto', 'every', 'interval'].includes(out.lastActiveMode)) out.lastActiveMode = 'auto';
  if (!['none', 'download', 'folder'].includes(out.autoExport)) out.autoExport = 'none';
  out.autoPruneDuplicates = out.autoPruneDuplicates !== false;
  out.showPanel = out.showPanel !== false;
  out.panelExpanded = out.panelExpanded !== false;
  out.scanPauseMain = out.scanPauseMain !== false;
  out.scanOpenGallery = out.scanOpenGallery !== false;
  out.intervalMs = Math.round(Math.min(10000, Math.max(100, Number(out.intervalMs) || 100)));
  out.minChange = Math.min(0.5, Math.max(0, Number(out.minChange) || 0));
  out.maxFramesPerSession = Math.round(Math.min(5000, Math.max(10, Number(out.maxFramesPerSession) || 300)));
  out.settingsVersion = DEFAULT_SETTINGS.settingsVersion;
  return out;
}

async function getSettings() {
  const stored = await chrome.storage.local.get('settings');
  const current = stored.settings || {};
  const normalized = Object.assign({}, DEFAULT_SETTINGS, current);
  // 首次读取时把旧版默认值一次性迁移并落盘，保证内容脚本那边读到的也是迁移后的值
  if (!settingsChecked) {
    settingsChecked = true;
    const fromVersion = Number(current.settingsVersion || 1);
    if (fromVersion < DEFAULT_SETTINGS.settingsVersion) {
      if (fromVersion < 2 && Number(normalized.intervalMs) === LEGACY_INTERVAL_MS) {
        normalized.intervalMs = DEFAULT_SETTINGS.intervalMs;
      }
      // v2 -> v3：默认从「自动·关键帧」改成「仅手动」
      if (fromVersion < 3 && normalized.mode === 'auto') normalized.mode = 'off';
      normalized.settingsVersion = DEFAULT_SETTINGS.settingsVersion;
      chrome.storage.local.set({ settings: normalized }).catch(() => {});
    }
  }
  return normalized;
}

/** 每个会话一个去重定时器（抓帧期间不能每帧都跑一次清理） */
const pruneTimers = new Map();

/**
 * 安排一次「删除重复帧」。
 * 去重必须在画面写完、且一段抓取告一段落之后跑，所以用防抖：连续抓帧时只跑最后一次。
 */
function schedulePrune(sessionId, delayMs) {
  if (!sessionId) return;
  const existing = pruneTimers.get(sessionId);
  if (existing) clearTimeout(existing);
  pruneTimers.set(
    sessionId,
    setTimeout(async () => {
      pruneTimers.delete(sessionId);
      try {
        const settings = await getSettings();
        if (!settings.autoPruneDuplicates) return;
        const result = await db.pruneDuplicates(sessionId);
        if (result.removed > 0) {
          console.log(`[关键帧抓取] 自动清理重复帧：删除 ${result.removed} 张`);
          broadcast({ type: 'frames-updated', sessionId });
          broadcast({ type: 'sessions-changed' });
          broadcast({ type: 'pruned', sessionId, removed: result.removed });
        }
      } catch (error) {
        console.warn('[关键帧抓取] 自动去重失败', error);
      }
    }, delayMs || 4000)
  );
}

/** 向 B 站标签页广播 */
function broadcast(message, exceptTabId) {
  chrome.tabs.query({ url: '*://*.bilibili.com/*' }, (tabs) => {
    void chrome.runtime.lastError;
    for (const tab of tabs || []) {
      if (exceptTabId && tab.id === exceptTabId) continue;
      chrome.tabs.sendMessage(tab.id, message, () => {
        void chrome.runtime.lastError;
      });
    }
  });
}

/** 给内容脚本发消息；脚本不存在时（扩展刚安装 / 页面未刷新）尝试注入一次 */
async function sendToTab(tabId, message) {
  try {
    return await chrome.tabs.sendMessage(tabId, message);
  } catch (error) {
    if (!String(error && error.message).includes('Receiving end does not exist')) throw error;
    await chrome.scripting.executeScript({
      target: { tabId },
      files: CONTENT_FILES
    });
    await new Promise((resolve) => setTimeout(resolve, 350));
    return chrome.tabs.sendMessage(tabId, message);
  }
}

async function activeBilibiliTab() {
  const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
  const tab = tabs && tabs[0];
  if (!tab) return null;
  if (!/^https?:\/\/([^/]*\.)?bilibili\.com\//.test(tab.url || '')) return null;
  return tab;
}

/** 统一的消息路由：始终回 { ok, data } / { ok, error } */
const handlers = {
  'db.ensureSession': (msg) => db.ensureSession(msg.sessionKey, msg.video),

  'db.sessionStats': (msg) => db.sessionStats(msg.sessionKey),

  'db.listSessions': () => db.listSessions(),

  'db.listFrames': (msg) => db.listFrames(msg.sessionId, msg.offset || 0, msg.limit || 100),

  'db.updateFrame': async (msg) => {
    const result = await db.updateFrame(msg.frameId, msg.patch);
    broadcast({ type: 'frames-updated', sessionId: msg.sessionId || null });
    return result;
  },

  'db.deleteFrames': async (msg) => {
    const result = await db.deleteFrames(msg.frameIds || []);
    broadcast({ type: 'frames-updated' });
    broadcast({ type: 'sessions-changed' });
    return result;
  },

  // 清空会话里的帧，但**保留会话本身**（与 db.deleteSession 区分）
  'db.clearSession': async (msg) => {
    const result = await db.clearSession(msg.sessionId);
    broadcast({ type: 'sessions-changed' });
    broadcast({ type: 'frames-updated', sessionId: msg.sessionId, cleared: true });
    return result;
  },

  'db.deleteSession': async (msg) => {
    const result = await db.deleteSession(msg.sessionId);
    broadcast({ type: 'sessions-changed' });
    broadcast({ type: 'frames-updated', sessionId: msg.sessionId });
    return result;
  },

  'db.usage': async () => {
    const usage = await db.usage();
    let quota = null;
    try {
      const estimate = await navigator.storage.estimate();
      quota = { usage: estimate.usage, quota: estimate.quota };
    } catch {
      quota = null;
    }
    return Object.assign({}, usage, { quota });
  },

  'settings.get': () => getSettings(),

  // 从弹窗/面板改设置：规范化后落盘并广播，保证所有页面立即生效
  'settings.save': async (msg) => {
    const current = await getSettings();
    const patch = msg && msg.patch && typeof msg.patch === 'object' ? msg.patch : {};
    const normalized = normalizeSettings(Object.assign({}, current, patch));
    await chrome.storage.local.set({ settings: normalized });
    broadcast({ type: 'settings.apply' });
    return normalized;
  },

  // 在主世界里找播放信息（拿到播放器真正在用的 CDN 地址）
  'page.playinfo': async (msg, sender) => {
    const tabId = msg.tabId || (sender && sender.tab && sender.tab.id);
    if (!tabId) return { urls: [], error: '没有可用的标签页' };
    try {
      const results = await chrome.scripting.executeScript({
        target: { tabId },
        world: 'MAIN',
        func: mainWorldPlayinfo
      });
      const first = results && results[0] && results[0].result;
      return first || { urls: [] };
    } catch (error) {
      return { urls: [], error: (error && error.message) || String(error) };
    }
  },

  // 在主世界安装 History 钩子，用来事件驱动地检测站内跳转（换视频 / 换分P）
  'nav.hook': async (msg, sender) => {
    const tabId = msg.tabId || (sender && sender.tab && sender.tab.id);
    if (!tabId) return { hooked: false, error: '没有可用的标签页' };
    try {
      const results = await chrome.scripting.executeScript({
        target: { tabId },
        world: 'MAIN',
        func: mainWorldNavHook
      });
      const first = results && results[0] && results[0].result;
      navHookedTabs.add(tabId);
      return { hooked: true, state: first || 'hooked' };
    } catch (error) {
      return { hooked: false, error: (error && error.message) || String(error) };
    }
  },

  // 后台观察到的媒体请求地址（播放器实际下载的那些）
  'media.list': (msg, sender) => {
    const tabId = msg.tabId || (sender && sender.tab && sender.tab.id);
    if (!tabId) return { total: 0, urls: [] };
    return mediawatch.list(tabId, { limit: msg.limit || 8 });
  },

  'media.clear': (msg, sender) => {
    const tabId = msg.tabId || (sender && sender.tab && sender.tab.id);
    if (!tabId) return { cleared: false };
    return mediawatch.clear(tabId);
  },

  // 内容脚本把扫描进度转成广播，让其它标签页 / 弹窗都能显示
  'scan.progress': (msg) => {
    broadcast({ type: 'scan.progress', scan: msg.scan || null, sessionId: msg.sessionId || null });
    return { relayed: true };
  },

  'db.addFrame': async (msg, sender) => {
    const settings = await getSettings();
    const result = await db.addFrame(msg.frame, settings);
    if (result.stored) {
      broadcast({ type: 'frames-updated', sessionId: result.sessionId });
      broadcast({ type: 'sessions-changed' });
      if (result.reachedLimit && settings.autoExport !== 'none') {
        broadcast({ type: 'session.reachedLimit', mode: settings.autoExport, sessionId: result.sessionId });
      }
      if (settings.autoPruneDuplicates && result.sessionId) schedulePrune(result.sessionId);
    }
    void sender;
    return result;
  },

  // 手动清理某个会话里的重复帧
  'db.pruneDuplicates': async (msg) => {
    if (!msg.sessionId) throw new Error('缺少会话标识');
    const result = await db.pruneDuplicates(msg.sessionId);
    if (result.removed) {
      broadcast({ type: 'frames-updated', sessionId: msg.sessionId });
      broadcast({ type: 'sessions-changed' });
    }
    return result;
  },

  'export.zip': (msg) => exporter.exportZip(msg.frameIds || [], msg.name),

  'export.download': (msg) => exporter.downloadFrames(msg.frameIds || []),

  'export.manifest': (msg) => exporter.manifest(msg.frameIds || [], msg.name),

  'export.frameData': (msg) => exporter.frameData(msg.frameId),

  // 导出动图 GIF（观察连贯抓取效果）
  'export.gif': (msg) => exporter.exportGif(msg.frameIds || [], msg.options || {}),

  // 下载原视频（优先音视频合一的整段文件）
  'export.video': (msg, sender) => {
    const tabId = msg.tabId || (sender && sender.tab && sender.tab.id);
    const observed = tabId ? mediawatch.list(tabId, { limit: 20 }) : { urls: [] };
    const candidates = (observed.urls || []).map((item) => ({ url: item.url, kind: item.kind }));
    for (const extra of msg.extra || []) candidates.push(extra);
    return exporter.downloadVideo(candidates, msg.title);
  },

  // 在文件管理器里打开浏览器的默认下载目录（用户常问「下载到哪去了」）
  'downloads.openFolder': async () => {
    try {
      if (chrome.downloads.showDefaultFolder) {
        chrome.downloads.showDefaultFolder();
        return { opened: true };
      }
    } catch (error) {
      console.warn('[关键帧抓取] 打开下载目录失败', error);
    }
    try {
      const items = await chrome.downloads.search({ limit: 1, orderBy: ['-startTime'] });
      if (items && items[0] && items[0].id !== undefined) {
        chrome.downloads.show(items[0].id);
        return { opened: true, via: 'show' };
      }
    } catch (error) {
      console.warn('[关键帧抓取] 定位最近下载失败', error);
    }
    return { opened: false, reason: '浏览器不支持打开下载目录' };
  }
};

async function route(message, sender) {
  const handler = handlers[message.type];
  if (!handler) throw new Error(`未知消息类型：${message.type}`);
  return handler(message, sender);
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || typeof message.type !== 'string') return undefined;
  if (message.type.startsWith('content.')) return undefined; // 发给内容脚本的广播，忽略
  Promise.resolve()
    .then(() => route(message, sender))
    .then((data) => sendResponse({ ok: true, data }))
    .catch((error) => {
      console.warn('[关键帧抓取] 处理消息失败', message.type, error);
      sendResponse({ ok: false, error: (error && error.message) || String(error) });
    });
  return true;
});

/** 快捷键：Alt+K 抓取当前画面 */
chrome.commands.onCommand.addListener(async (command) => {
  if (command !== 'capture-now') return;
  const tab = await activeBilibiliTab();
  if (!tab) return;
  try {
    await sendToTab(tab.id, { type: 'capture-now', source: 'shortcut' });
  } catch (error) {
    console.warn('[关键帧抓取] 快捷键抓帧失败', error);
  }
});

/** 设置变化后同步到所有页面（面板显隐 / 模式切换） */
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'local' && changes.settings) {
    broadcast({ type: 'settings.apply' });
  }
});

/** 清理：删除没有任何关键帧的空会话 */
chrome.tabs.onRemoved.addListener(async () => {
  try {
    await db.cleanup(null);
  } catch (error) {
    console.warn('[关键帧抓取] 清理失败', error);
  }
});

chrome.runtime.onInstalled.addListener(async (details) => {
  const stored = await chrome.storage.local.get('settings');
  if (!stored.settings) await chrome.storage.local.set({ settings: DEFAULT_SETTINGS });
  if (details.reason === 'install') {
    chrome.tabs.create({ url: 'https://www.bilibili.com/' });
  }
});

chrome.runtime.onStartup.addListener(() => {
  console.log('[B站关键帧抓取器] 后台已就绪');
});

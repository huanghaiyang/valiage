/**
 * core.js —— 全局命名空间与通用工具（内容脚本，按顺序最先加载）
 *
 * 内容脚本之间通过 window.__BKF__ 共享状态（内容脚本与页面 JS 处于同一
 * isolated world，但与页面自身的 world 隔离，不会污染 B 站自己的变量）。
 */
(function () {
  'use strict';

  const NS = (window.__BKF__ = window.__BKF__ || {});

  /** 设置项默认值：与 popup / background 保持一致 */
  const DEFAULT_SETTINGS = {
    // off    = 仅手动（默认：进入页面后暂停自动抓取，要用时手动开始）
    // auto   = 关键帧检测（只保存画面明显变化的帧）
    // every  = 逐帧抓取（按采样间隔全部保存，默认 10 张/秒）
    // interval = 定间隔抓取（同样全部保存，通常配合较大的间隔秒数）
    mode: 'off',
    hashThreshold: 0.12,     // dHash 汉明距离阈值（0~1，越小越灵敏）
    madThreshold: 0.1,       // 灰度平均绝对差阈值（0~1，越小越灵敏）
    minChange: 0.025,        // 最小变化量（0~1）：与上一张已保存帧的差异小于它就不存（相似度去重）
    autoPruneDuplicates: true, // 自动删除重复帧：同一会话内指纹相同的帧只保留最后一张
    lastActiveMode: 'auto',  // 暂停时记住的自动模式，点「开始」时恢复它
    intervalMs: 100,         // 采样间隔（毫秒）：实时监听与扫描的最小判定间隔，下限 100ms
    format: 'jpeg',          // jpeg | png（影响全尺寸图，缩略图恒为 jpeg）
    quality: 0.85,           // jpeg 质量
    maxWidth: 1280,          // 全尺寸图最长边
    thumbWidth: 320,         // 缩略图最长边
    maxFramesPerSession: 300,
    showPanel: true,
    panelExpanded: true,     // 面板展开 / 收起（左侧细竖条）
    panelLeft: 12,           // 面板位置（null 表示沿用上次 / 默认左侧居中）
    panelTop: null,
    autoPause: false,
    autoExport: 'none',      // none | download | folder：抓满 maxFramesPerSession 时自动导出

    // ---- 播放并抓帧（离线扫描整个视频） ----
    scanInterval: 1,         // 扫描采样间隔（秒）；>0.95 秒时改用逐点定位（更准但更慢）
    scanRate: 4,             // 隐藏视频的播放倍速（越大越快，但可能漏掉短镜头）
    scanPauseMain: true,     // 扫描时暂停你正在看的播放器（省带宽 / 省 CPU）
    scanOpenGallery: true,   // 扫描结束后自动打开图库

    // 设置结构版本：用于把旧的默认值一次性迁移到新默认值
    settingsVersion: 3
  };

  /** 旧版本用过、需要在新版里做一次性迁移的默认值 */
  const LEGACY_INTERVAL_MS = 600;

  /**
   * 迁移规则（只处理「上一版默认值」，不动用户自己改过的值）：
   *   v1 -> v2：采样间隔默认 600ms 改成 100ms
   *   v2 -> v3：默认模式从「自动·关键帧」改成「仅手动」（进入页面后暂停自动抓取）
   */
  const MIGRATIONS = {
    2: (out) => {
      if (out.intervalMs === LEGACY_INTERVAL_MS) out.intervalMs = DEFAULT_SETTINGS.intervalMs;
    },
    3: (out) => {
      // v2 的默认模式是 auto；没动过设置的用户升上来后应当变成「仅手动」
      if (out.mode === 'auto') out.mode = 'off';
    }
  };

  const VIDEO_SELECTORS = [
    '.bpx-player-video-wrap video',
    '#bilibili-player video',
    '.bilibili-player-video video',
    'video'
  ];

  const core = {
    DEFAULT_SETTINGS,

    /** 合并默认设置，过滤未知键 */
    normalizeSettings(raw) {
      const out = Object.assign({}, DEFAULT_SETTINGS);
      if (!raw || typeof raw !== 'object') return out;
      for (const key of Object.keys(DEFAULT_SETTINGS)) {
        const value = raw[key];
        if (value === undefined || value === null) continue;
        const def = DEFAULT_SETTINGS[key];
        if (typeof def === 'number') {
          const num = Number(value);
          if (Number.isFinite(num)) out[key] = num;
        } else {
          out[key] = value;
        }
      }
      // 兼容旧版本用秒保存的 intervalSeconds
      if (raw.intervalMs === undefined && typeof raw.intervalSeconds === 'number') {
        out.intervalMs = Math.round(raw.intervalSeconds * 1000);
      }
      // 依次套用迁移规则：只替换「上一版的旧默认值」，用户手改过的值保留
      const fromVersion = Number(raw.settingsVersion || 1);
      for (let version = fromVersion + 1; version <= DEFAULT_SETTINGS.settingsVersion; version += 1) {
        const migrate = MIGRATIONS[version];
        if (migrate) migrate(out);
      }
      out.settingsVersion = DEFAULT_SETTINGS.settingsVersion;
      out.hashThreshold = core.clamp(out.hashThreshold, 0.01, 0.6);
      out.madThreshold = core.clamp(out.madThreshold, 0.01, 0.6);
      out.minChange = core.clamp(out.minChange, 0, 0.5);
      out.intervalMs = Math.round(core.clamp(out.intervalMs, 100, 10000));
      out.quality = core.clamp(out.quality, 0.3, 1);
      out.maxWidth = Math.round(core.clamp(out.maxWidth, 320, 3840));
      out.thumbWidth = Math.round(core.clamp(out.thumbWidth, 120, 800));
      out.maxFramesPerSession = Math.round(core.clamp(out.maxFramesPerSession, 10, 5000));
      if (!['auto', 'every', 'interval', 'off'].includes(out.mode)) out.mode = 'auto';
      if (!['jpeg', 'png'].includes(out.format)) out.format = 'jpeg';
      if (!['none', 'download', 'folder'].includes(out.autoExport)) out.autoExport = 'none';
      if (out.panelLeft !== null && out.panelLeft !== undefined) {
        out.panelLeft = Math.round(core.clamp(Number(out.panelLeft) || 0, -1, 10000));
        if (out.panelLeft < 0) out.panelLeft = null;
      }
      if (out.panelTop !== null && out.panelTop !== undefined) {
        out.panelTop = Math.round(core.clamp(Number(out.panelTop) || 0, -1, 20000));
        if (out.panelTop < 0) out.panelTop = null;
      }
      out.panelExpanded = out.panelExpanded !== false;
      out.showPanel = out.showPanel !== false;
      out.autoPruneDuplicates = out.autoPruneDuplicates !== false;
      if (!['auto', 'every', 'interval'].includes(out.lastActiveMode)) out.lastActiveMode = 'auto';
      out.scanInterval = core.clamp(out.scanInterval, 0.15, 10);
      out.scanRate = core.clamp(out.scanRate, 1, 16);
      out.scanPauseMain = out.scanPauseMain !== false;
      out.scanOpenGallery = out.scanOpenGallery !== false;
      return out;
    },

    async getSettings() {
      const stored = await chrome.storage.local.get('settings');
      return core.normalizeSettings(stored && stored.settings);
    },

    async saveSettings(patch) {
      const current = await core.getSettings();
      const next = core.normalizeSettings(Object.assign({}, current, patch || {}));
      await chrome.storage.local.set({ settings: next });
      return next;
    },

    clamp(value, min, max) {
      return Math.min(max, Math.max(min, value));
    },

    sleep(ms) {
      return new Promise((resolve) => setTimeout(resolve, ms));
    },

    /** 相对路径用 URL 解析，兼容 //i0.hdslb.com 这类协议相对地址 */
    absolutize(url) {
      if (!url) return '';
      try {
        return new URL(url, location.href).href;
      } catch {
        return url;
      }
    },

    /** 秒 -> 00:00 / 00:00:00 */
    timeText(seconds, withMillis) {
      const total = Math.max(0, Number(seconds) || 0);
      const hours = Math.floor(total / 3600);
      const minutes = Math.floor((total % 3600) / 60);
      const secs = Math.floor(total % 60);
      const pad = (n) => String(n).padStart(2, '0');
      const head = hours > 0 ? `${hours}:${pad(minutes)}` : pad(minutes);
      let text = `${head}:${pad(secs)}`;
      if (withMillis) text += `.${String(Math.floor((total % 1) * 10))}`;
      return text;
    },

    /** 建议文件名里的时间戳：20250101-120000 */
    fileStamp(date) {
      const d = date instanceof Date ? date : new Date();
      const pad = (n) => String(n).padStart(2, '0');
      return (
        `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}` +
        `-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`
      );
    },

    /** 清理文件名中不安全的字符 */
    safeName(text, fallback) {
      const cleaned = String(text || '')
        .replace(/[\\/:*?"<>|\u0000-\u001f]/g, '_')
        .replace(/\s+/g, ' ')
        .trim();
      return (cleaned || fallback || 'untitled').slice(0, 80);
    },

    /**
     * 判断是不是「视频循环回到开头」。
     * 多播一遍是用户常用的补齐手段，但如果不重置判定基准，
     * 新一遍的第一帧会因为「和上一遍结尾差异过大」而误判、反而丢掉开头。
     * @param {number} previousTime 上一次采样时的视频时间
     * @param {number} currentTime 当前视频时间
     * @returns {boolean}
     */
    isVideoLooped(previousTime, currentTime) {
      const prev = Number(previousTime) || 0;
      const now = Number(currentTime) || 0;
      if (!(prev > 0)) return false;
      return now + 1 < prev;
    },

    /**
     * 判定一次采样里的「重复画面」。
     * 单独抽出来是为了可测：它回答了「采了 50 次为什么只存 6 张」这类问题。
     * 逐帧模式（every）下只有连续两次采样落在同一帧才会被判重复，
     * 所以按 100ms 采样 5 秒仍然能存下接近 50 张（画面有变化时哈希必然不同）。
     * @param {{sampleCount:number, savedHashes:Set<string>}} state
     * @param {string} hash 当前画面指纹
     * @returns {{sampled:number, duplicate:boolean}}
     */
    accountSample(state, hash) {
      state.sampleCount = (state.sampleCount || 0) + 1;
      const hashes = state.savedHashes || (state.savedHashes = new Set());
      const duplicate = !!hash && hashes.has(hash);
      if (hash) hashes.add(hash);
      return { sampled: state.sampleCount, duplicate };
    },

    /** 人类可读的字节数 */
    bytes(size) {      const value = Number(size) || 0;
      if (value < 1024) return `${value} B`;
      if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`;
      if (value < 1024 * 1024 * 1024) return `${(value / 1024 / 1024).toFixed(1)} MB`;
      return `${(value / 1024 / 1024 / 1024).toFixed(2)} GB`;
    },

    /** 发送消息给 Service Worker，返回 data 并统一抛出错误 */
    send(message) {
      return new Promise((resolve, reject) => {
        let done = false;
        try {
          chrome.runtime.sendMessage(message, (response) => {
            done = true;
            const err = chrome.runtime.lastError;
            if (err) {
              reject(new Error(err.message || '扩展后台无响应'));
              return;
            }
            if (!response) {
              reject(new Error('扩展后台无响应'));
              return;
            }
            if (response.ok) resolve(response.data);
            else reject(new Error(response.error || '未知错误'));
          });
        } catch (error) {
          if (!done) reject(error);
        }
      });
    },

    /** 等待页面里出现可用的 video 元素 */
    async waitForVideo(timeoutMs) {
      const deadline = Date.now() + (timeoutMs || 30000);
      for (;;) {
        const video = core.findVideo();
        if (video) return video;
        if (Date.now() > deadline) return null;
        await core.sleep(400);
      }
    },

    /** 找到当前页面播放中的 video（优先 B 站播放器容器内的） */
    findVideo() {
      for (const selector of VIDEO_SELECTORS) {
        const list = Array.from(document.querySelectorAll(selector));
        const usable = list.filter((v) => core.isUsableVideo(v));
        if (usable.length) {
          // 多个 video 时优先有有效时长的
          usable.sort((a, b) => (b.duration || 0) - (a.duration || 0));
          return usable[0];
        }
      }
      return null;
    },

    isUsableVideo(video) {
      if (!video || video.tagName !== 'VIDEO') return false;
      const src = video.currentSrc || video.src || '';
      if (!src) return false;
      if (Number.isFinite(video.duration) && video.duration > 1) return true;
      return video.readyState >= 1;
    },

    /** 悬浮面板与图库共用的宿主容器，挂到 documentElement 上避免被 SPA 重渲染清掉 */
    ensureHost(id) {
      let host = document.getElementById(id);
      if (!host) {
        host = document.createElement('div');
        host.id = id;
        host.style.cssText = 'all:initial;position:fixed;z-index:2147483000;';
        (document.documentElement || document.body).appendChild(host);
      }
      return host;
    },

    /** B 站 SPA 导航时派发的自定义事件（图库/面板据此刷新） */
    emit(name, detail) {
      try {
        window.dispatchEvent(new CustomEvent(`bkf:${name}`, { detail }));
      } catch {
        /* 忽略 */
      }
    },

    on(name, handler) {
      const wrapped = (event) => handler(event.detail);
      window.addEventListener(`bkf:${name}`, wrapped);
      return () => window.removeEventListener(`bkf:${name}`, wrapped);
    }
  };

  NS.core = core;
})();

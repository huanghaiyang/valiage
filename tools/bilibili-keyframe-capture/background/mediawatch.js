/**
 * mediawatch.js —— 观察播放器实际请求的音视频地址（后台 Service Worker 用）
 *
 * 为什么需要它：B 站新版播放器用 MSE 播放，页面上 video.currentSrc 可能是 blob:，
 * 而 window.__playinfo__ 有时也拿不到地址。这时唯一可靠的办法是「看播放器到底请求了什么」。
 *
 * 用 chrome.webRequest 的**观察模式**（非 blocking）：MV3 下不需要 debugger 权限、
 * 不会弹调试横幅，只要有对应 host_permissions 就能收到自己扩展感兴趣域名的请求事件。
 *
 * 收集到的地址交给内容脚本，由它先做轻量探针（判断是视频轨还是音轨）再当作取帧源。
 */
(function () {
  'use strict';

  const global = self;
  const MAX_PER_TAB = 40;

  /** tabId -> [{ url, kind, mime, at, status }] */
  const byTab = new Map();

  function bucket(tabId) {
    if (!byTab.has(tabId)) byTab.set(tabId, []);
    return byTab.get(tabId);
  }

  /** 明显不是视频流的地址：封面图 / 头像 / 静态资源 */
  function isImageish(url) {
    const text = String(url || '').toLowerCase();
    if (!text) return true;
    // i0/i1/i2.hdslb.com 的 /bfs/archive/... 基本都是封面图（推荐位、视频封面）
    if (/\/bfs\/(archive|face|new_dyn|video)\//.test(text)) return true;
    if (/\.(jpg|jpeg|png|gif|webp|avif|svg|ico)(@|\?|$)/.test(text)) return true;
    if (/@\d+w_\d+h/.test(text)) return true;           // B 站图片处理后缀：@336w_190h
    if (/(rcmd|cover|thumb|poster|avatar|sprite|preview)/.test(text)) return true;
    return false;
  }

  /** 看起来像媒体分段（DASH/HLS 分段或整段视频） */
  function looksLikeMedia(url) {
    const text = String(url || '').toLowerCase();
    if (isImageish(text)) return false;
    if (/\.(m4s|mp4|flv|webm|mkv|ts|m4a|mp3)(\?|$)/.test(text)) return true;
    if (/\/upgcxcode\//.test(text)) return true;        // B 站正片 CDN 路径特征
    if (/mcdn\.bilivideo\./.test(text)) return true;
    if (/[?&](mime|platform)=/.test(text)) return true;
    // hdslb.com 是静态资源域（封面、字幕、弹幕）；只有带明确视频文件特征时才认
    if (/hdslb\.com/.test(text)) return false;
    return false;
  }

  /** 猜一下这个地址是音频还是视频（B 站 DASH 音视频分开请求） */
  function guessKind(url) {
    const text = String(url || '').toLowerCase();
    if (/audio|30280|30232|30216|30250/.test(text)) return 'audio';
    if (/video|100026|30080|30077|30032|30033|30120/.test(text)) return 'video';
    return looksLikeMedia(text) ? 'media' : 'unknown';
  }

  function remember(tabId, url, extra) {
    if (!url || tabId === undefined || tabId < 0) return;
    if (isImageish(url)) return;
    const list = bucket(tabId);
    const existing = list.find((item) => item.url === url);
    if (existing) {
      Object.assign(existing, extra || {});
      return;
    }
    list.push(Object.assign({ url, kind: guessKind(url), at: Date.now() }, extra || {}));
    while (list.length > MAX_PER_TAB) list.shift();
  }

  function forget(tabId, url) {
    if (!byTab.has(tabId)) return;
    byTab.set(tabId, byTab.get(tabId).filter((item) => item.url !== url));
  }

  /** 从响应头里找 content-type，用以区分音轨 / 视频轨 */
  function mimeFromHeaders(headers) {
    if (!Array.isArray(headers)) return '';
    for (const header of headers) {
      const name = String(header.name || '').toLowerCase();
      if (name === 'content-type' && header.value) return String(header.value);
    }
    return '';
  }

  const filter = {
    urls: [
      '*://*.bilivideo.com/*',
      '*://*.bilivideo.cn/*',
      '*://*.biliapi.net/*',
      '*://*.hdslb.com/*',
      '*://*.akamaized.net/*',
      '*://*.mcdn.bilivideo.cn/*'
    ]
  };

  chrome.webRequest.onBeforeRequest.addListener(
    (details) => {
      // 只收媒体请求：video 元素直接拉流是 media，B 站 DASH 分段走 fetch/xhr
      const type = details.type || '';
      if (!['media', 'xmlhttprequest', 'other'].includes(type)) return;
      // 封面图等静态资源一律不要（推荐位封面就挂在 i0.hdslb.com 上）
      if (isImageish(details.url)) return;
      if (type === 'other' && !looksLikeMedia(details.url)) return;
      if (type === 'xmlhttprequest' && !looksLikeMedia(details.url)) return;
      remember(details.tabId, details.url, { startedAt: details.timeStamp, type });
    },
    filter
  );

  chrome.webRequest.onHeadersReceived.addListener(
    (details) => {
      const mime = mimeFromHeaders(details.responseHeaders);
      if (!mime) return;
      const text = mime.toLowerCase();
      if (isImageish(details.url)) return;
      // 只认音视频类型的响应；图片 / HTML / JSON 一律丢弃
      const isVideo = /^video\//.test(text) || text.includes('video/mp4') || text.includes('video/mp2t');
      const isAudio = /^audio\//.test(text);
      if (!isVideo && !isAudio) {
        // 不是音视频就撤销之前可能记下的这条
        forget(details.tabId, details.url);
        return;
      }
      remember(details.tabId, details.url, {
        mime,
        kind: isVideo ? 'video' : 'audio',
        status: details.statusCode
      });
    },
    filter,
    ['responseHeaders']
  );

  chrome.tabs.onRemoved.addListener((tabId) => {
    byTab.delete(tabId);
  });

  const watch = {
    /**
     * 列出某个标签页最近观察到的媒体地址。
     * 视频轨优先（有些 CDN 的 mime 是 video/mp4，有些只能在探针阶段判断）。
     */
    list(tabId, options) {
      const opts = options || {};
      const list = (byTab.get(tabId) || []).slice();
      const score = (item) =>
        item.kind === 'video' ? 3 : (item.kind === 'media' ? 2 : (item.kind === 'audio' ? 1 : 0));
      // 视频轨优先，其次按最近请求时间
      const ranked = list
        .filter((item) => !isImageish(item.url))
        .sort((a, b) => score(b) - score(a) || (b.at || 0) - (a.at || 0));
      const limit = opts.limit || 8;
      return {
        total: list.length,
        urls: ranked.slice(0, limit).map((item) => ({
          url: item.url,
          kind: item.kind,
          mime: item.mime || '',
          type: item.type || '',
          at: item.at
        }))
      };
    },

    clear(tabId) {
      byTab.delete(tabId);
      return { cleared: true };
    }
  };

  global.BKFmediawatch = watch;
})();

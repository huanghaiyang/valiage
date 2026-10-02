/**
 * framesource.js —— 取帧用的「隐藏视频源」解析器
 *
 * 背景：B 站视频来自 *.bilivideo.com 等 CDN，且 CDN 不接受带 Origin 头的匿名请求，
 * 所以直接给隐藏 <video> 加 crossOrigin="anonymous" 往往连元数据都加载不了
 * （报「无法通过 CORS 读取视频像素」）。
 *
 * 解决思路：交给扩展自己取数据 —— 内容脚本的 fetch 受扩展 host_permissions 授权，
 * 不受页面 CORS 限制。三级降级：
 *
 *   1. direct  直接让隐藏 video 带 crossOrigin 加载原地址（能用就最快、不额外占内存）
 *   2. blob    用 fetch 把视频抓成 blob 再挂给 video（blob 属于本站，画布不会被污染）
 *   3. mse     视频太大时，用 fetch 边下边塞进 MediaSource 流式播放（可提前开始取帧）
 *
 * 无论哪一级，最终都是把一个「同源/已授权」的媒体喂给隐藏 video，
 * 从而保证 drawImage + getImageData 不被安全策略拦截。
 */
(function () {
  'use strict';

  const NS = (window.__BKF__ = window.__BKF__ || {});
  const core = NS.core;

  const META_TIMEOUT = 12000;
  const BLOB_LIMIT_BYTES = 1536 * 1024 * 1024;   // fetch 整段的上限（1.5 GB）
  const MSE_START_BYTES = 512 * 1024;            // 先取这么多字节来解析 fMP4 结构
  const MSE_APPEND_TARGET = 4 * 1024 * 1024;     // 每次至少攒这么多再 append
  const MSE_SAFE_BUFFER = 96 * 1024 * 1024;      // 已缓冲超过它就暂停下载，边看边丢
  const MSE_KEEP_BEHIND = 30;                    // 保留当前播放点之后多少秒

  const VIDEO_ATTRS = {
    muted: true,
    defaultMuted: true,
    playsInline: true,
    preload: 'auto'
  };

  const source = {
    mode: 'direct',
    element: null,
    objectUrl: '',
    error: null,
    progress: null,
    onProgress: null,
    activeUrl: '',
    mse: null,
    downloadPromise: null,
    aborted: false,
    lastStrategyError: '',
    lastReportAt: 0,
    attempts: [],
    probeResult: null,
    urlInfo: null,
    sourceName: '',
    observed: [],
    loadedForPlayerUrl: '',

    /* ---------------- 元素管理 ---------------- */

    /** 创建一个隐藏的取帧 video（挂到文档里，部分浏览器要求元素在文档中才解码） */
    createElement() {
      const video = document.createElement('video');
      video.crossOrigin = 'anonymous';
      video.muted = true;
      video.defaultMuted = true;
      video.playsInline = true;
      video.preload = 'auto';
      video.setAttribute('aria-hidden', 'true');
      video.style.cssText =
        'position:fixed;left:-10000px;top:0;width:2px;height:2px;opacity:0;pointer-events:none;';
      video.id = '__bkf_reader_video__';
      if (!video.isConnected) (document.body || document.documentElement).appendChild(video);
      return video;
    },

    reset() {
      source.abort();
      try {
        const old = source.element;
        if (old) {
          old.removeAttribute('src');
          old.load();
          old.remove();
        }
      } catch {
        /* 忽略 */
      }
      if (source.objectUrl) {
        try {
          URL.revokeObjectURL(source.objectUrl);
        } catch {
          /* 忽略 */
        }
        source.objectUrl = '';
      }
      source.element = null;
      source.mse = null;
      source.mode = 'direct';
      source.error = null;
      source.progress = null;
      source.activeUrl = '';
      source.downloadPromise = null;
      source.probeResult = null;
      source.attempts = [];
      // 复位取消标志：降级到下一级策略时必须重新可下载
      source.aborted = false;
    },    abort() {
      source.aborted = true;
      if (source.mse) {
        source.mse.aborted = true;
        try {
          source.mse.reader.cancel();
        } catch {
          /* 忽略 */
        }
      }
      if (source.element) {
        try {
          source.element.pause();
        } catch {
          /* 忽略 */
        }
      }
    },

    report(progress) {
      source.progress = progress;
      if (typeof source.onProgress !== 'function') return;
      // 下载循环里调用很频繁，这里做一层节流（进度用文本显示，不需要每帧刷新）
      const now = performance.now();
      if (now - source.lastReportAt < 150) return;
      source.lastReportAt = now;
      try {
        source.onProgress(progress);
      } catch {
        /* 忽略回调异常 */
      }
    },

    /* ---------------- 候选地址 ---------------- */

    /** 页面里能拿到的播放信息（B 站会把 DASH 流地址放在这里） */
    playinfo() {
      const state = window.__playinfo__;
      if (state && state.data) return state.data;
      if (state && (state.dash || state.durl)) return state;
      return null;
    },

    /**
     * 列出所有可尝试的视频地址，按「最适合取帧」排序：
     *   1. B 站 __playinfo__ 里的 DASH 视频流（纯视频、分段、最适合定位取帧）
     *   2. __playinfo__ 里的 durl（老式整段 flv/mp4）
     *   3. 播放器当前的 currentSrc（可能是 CDN 直链，也可能是 MSE 的 blob:）
     */
    candidates(pageVideo) {
      const list = [];
      const seen = new Set();
      const push = (url, from) => {
        if (!url) return;
        const resolved = core.absolutize(url);
        if (!resolved || seen.has(resolved)) return;
        // 只接受可正常解析的地址，避免把空串 / 非法值塞进候选
        try {
          const parsed = new URL(resolved, location.href);
          if (!/^https?:|^blob:|^data:/.test(parsed.protocol)) {
            console.debug('[关键帧抓取] 跳过的候选协议', parsed.protocol, resolved.slice(0, 60));
            return;
          }
        } catch (error) {
          console.debug('[关键帧抓取] 候选地址无法解析', resolved.slice(0, 60), error.message);
          return;
        }
        seen.add(resolved);
        list.push({ url: resolved, from });
      };

      const info = source.playinfo();
      try {
        const dash = info && info.dash;
        if (dash && Array.isArray(dash.video) && dash.video.length) {
          const sorted = dash.video
            .slice()
            .sort((a, b) => (b.width || 0) * (b.height || 0) - (a.width || 0) * (a.height || 0));
          // 1080p 级别最适合取帧：清晰度够、体积比 4K 小得多
          const preferred = sorted.find((item) => (item.height || 0) <= 1080) || sorted[sorted.length - 1];
          push((preferred.baseUrl || preferred.base_url) + (preferred.backupUrl ? '' : ''), 'playinfo.dash');
          for (const extra of sorted) {
            if (extra === preferred) continue;
            push(extra.baseUrl || extra.base_url, 'playinfo.dash');
          }
        }
        if (info && Array.isArray(info.durl) && info.durl.length) {
          push(info.durl[0].url, 'playinfo.durl');
        }
      } catch {
        /* __playinfo__ 结构不认识就忽略 */
      }

      if (pageVideo) {
        push(pageVideo.currentSrc || pageVideo.src, 'player');
      }
      return list;
    },

    /* ---------------- 加载 ---------------- */

    /** 记住「播放器实际请求过的地址」，之后所有取帧都会优先用它 */
    addObserved(list) {
      for (const item of list || []) {
        if (!item || !item.url) continue;
        if (source.observed.some((entry) => entry.url === item.url)) continue;
        source.observed.push({ url: item.url, from: item.from || 'observed' });
      }
      // 只留最近记住的一批，避免无限增长
      if (source.observed.length > 12) source.observed = source.observed.slice(-12);
      return source.observed.length;
    },

    /**
     * 确保隐藏 video 已经加载好目标视频。
     * @param {HTMLVideoElement} pageVideo 页面里的播放器（取地址与标题）
     * @param {object} [options] { extra: [{url, from}] 外部提供的候选（例如从网络请求里抓到的） }
     * @returns {Promise<HTMLVideoElement>}
     */
    async ensure(pageVideo, options) {
      const opts = options || {};
      if (opts.extra && opts.extra.length) source.addObserved(opts.extra);

      // 播放器当前地址：换视频 / 换分P 时它一定会变。
      // 只比较「候选列表第一项」不够 —— SPA 切集时 currentSrc 可能仍是旧值，
      // 于是两边都判定「没变」，取帧源就一直用上一个视频（严重 bug）。
      const playerUrl = pageVideo ? core.absolutize(pageVideo.currentSrc || pageVideo.src || '') : '';
      if (opts.force || (playerUrl && source.loadedForPlayerUrl && playerUrl !== source.loadedForPlayerUrl)) {
        source.observed = []; // 上一个视频的地址全部作废
        source.reset();
      }
      source.loadedForPlayerUrl = playerUrl;

      let list = source.candidates(pageVideo);
      if (source.observed.length) {
        // 播放器真实请求的 CDN 地址比 blob: / 播放器标签上的地址靠谱得多，放最前面
        const seen = new Set(source.observed.map((item) => item.url));
        list = source.observed.concat(list.filter((item) => !seen.has(item.url)));
      }
      if (!list.length) throw new Error('未找到视频地址，请先点击播放让播放器加载视频');

      const primary = list[0].url;
      if (!source.element) source.element = source.createElement();

      if (!opts.force && source.activeUrl === primary && source.mode !== 'failed') {
        if (source.element.readyState >= 1) return source.element;
        // 正在进行中（例如 MSE 边下边播）就复用现有元素
        if (source.element.readyState === 0 && !source.error) {
          await source.waitMetadata(source.element);
          return source.element;
        }
      }

      // 地址变化：整套重来，并按候选顺序逐个尝试
      source.reset();
      source.element = source.createElement();
      source.activeUrl = primary;
      return source.loadCandidates(list);
    },

    /** 换视频时调用：把记住的地址与已加载的源全部作废 */
    invalidate() {
      source.observed = [];
      source.loadedForPlayerUrl = '';
      source.reset();
      return true;
    },

    /**
     * 用轻量探针给候选地址分类：能确认是视频轨的排前面，音轨/非媒体排后面。
     * 只读前 64KB，成本很低。
     * @returns {Promise<Array>} 每个候选带上 track：video | audio | notmedia | unknown | opaque
     */
    async rankCandidates(list) {
      const results = [];
      for (const candidate of list) {
        const info = source.describeUrl(candidate.url);
        if (info.kind !== 'network') {
          results.push(Object.assign({}, candidate, { track: info.kind === 'blob' ? 'opaque' : 'unknown' }));
          continue;
        }
        const probed = await source.probeTrack(candidate.url);
        results.push(Object.assign({}, candidate, probed));
      }
      const score = (track) => {
        if (track === 'video') return 0;
        if (track === 'unknown' || track === 'opaque') return 1;
        if (track === 'audio') return 2;
        return 3; // notmedia（封面图之类）最后再试
      };
      return results.sort((a, b) => score(a.track) - score(b.track));
    },

    /** 读前 64KB，判断容器类型与轨道类型 */
    async probeTrack(url) {
      try {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 6000);
        const response = await fetch(url, {
          headers: { Range: 'bytes=0-65535' },
          credentials: 'omit',
          referrer: location.href,
          signal: controller.signal
        });
        clearTimeout(timer);
        if (!response.ok && response.status !== 206) return { track: 'notmedia', container: `HTTP ${response.status}` };
        const buffer = new Uint8Array(await response.arrayBuffer());
        return source.analyzeContainer(buffer);
      } catch (error) {
        return { track: 'unknown', container: (error && error.message) || 'probe-failed' };
      }
    },

    /** 综合容器魔数与编码 box，判断「是不是媒体、是视频还是音频」 */
    analyzeContainer(bytes) {
      const container = source.magicOf(bytes);
      const isMediaContainer = /MP4|Matroska|WebM|MPEG-TS|styp/.test(container);
      if (!isMediaContainer) {
        // 封面图（avif/jpg）、HTML 错误页等一律排除
        return { track: 'notmedia', container };
      }
      const text = [];
      const limit = Math.min(bytes.length, 65536);
      for (let i = 0; i < limit; i += 1) text.push(String.fromCharCode(bytes[i]));
      const joined = text.join('');
      const hasVideoCodec = /avc1|avc3|hvc1|hev1|av01|vp09/.test(joined);
      const hasAudioCodec = /mp4a|opus|ac-3|ec-3/.test(joined);
      if (hasVideoCodec) return { track: 'video', container };
      if (hasAudioCodec) return { track: 'audio', container };
      return { track: 'unknown', container };
    },

    /** 兼容旧的调用：只返回轨道类型 */
    trackOf(bytes) {
      return source.analyzeContainer(bytes).track;
    },

    /** 依次尝试所有候选地址；每个地址内部再做三级策略降级 */
    async loadCandidates(list) {
      const failures = [];
      const seen = new Set();
      // 先探针分类：视频轨优先、音轨其次、封面图之类最后（可能直接放弃）
      let ordered = list;
      try {
        ordered = await source.rankCandidates(list);
      } catch {
        ordered = list;
      }
      const summary = ordered
        .filter((item) => item.track)
        .map((item) => `${item.track}`)
        .join('/');
      if (summary) {
        source.report({ phase: 'rank', value: 0, text: `候选轨道判定：${summary}` });
      }
      // 确认不是媒体的（封面图 / HTML 错误页）默认不浪费时间，留作最后兜底
      const primary = ordered.filter((item) => item.track !== 'notmedia');
      const fallback = ordered.filter((item) => item.track === 'notmedia');
      let attemptList = primary;
      if (!primary.length && fallback.length) {
        source.report({ phase: 'rank', value: 0, text: '没有检测到视频流，尝试兜底地址…' });
        attemptList = fallback.slice(0, 2);
      }

      for (const candidate of attemptList) {
        if (seen.has(candidate.url)) continue;
        seen.add(candidate.url);
        if (source.aborted) throw new Error('已取消');
        source.reset();
        source.element = source.createElement();
        try {
          return await source.load(candidate);
        } catch (error) {
          failures.push(
            `${candidate.from}${candidate.track ? `[${candidate.track}]` : ''}: ${String(error.message).split('\n')[0]}`
          );
        }
      }
      source.mode = 'failed';
      const error = new Error(
        `所有视频地址都无法取帧（共尝试 ${seen.size} 个地址）。\n各级尝试：\n` +
          failures.map((line) => `· ${line}`).join('\n') +
          `\n\n${source.diagnose()}`
      );
      error.retriable = true; // 允许上层再去找新地址（例如从网络请求里抓）
      source.error = error;
      source.lastStrategyError = error.message;
      throw error;
    },

    /**
     * 换下一种取帧方式重新加载（供上层在 seek / play 失败时重试）。
     * 先把当前地址的下一级策略试完，再换下一个候选地址（例如从 currentSrc 换到 __playinfo__ 的 DASH 流）。
     */
    async reloadWithNextStrategy(pageVideo) {
      const tried = source.nextStrategy(source.mode);
      const candidates = source.candidates(pageVideo);
      const current = source.activeUrl;
      const queue = [];
      if (tried) queue.push({ url: current, strategy: tried, from: source.sourceName || 'player' });
      for (const candidate of candidates) {
        if (candidate.url === current) continue;
        queue.push({ url: candidate.url, from: candidate.from });
      }
      if (!queue.length) throw new Error(source.lastStrategyError || '视频像素无法读取');

      source.reset();
      source.element = source.createElement();
      const failures = [];
      for (const item of queue) {
        if (source.aborted) throw new Error('已取消');
        try {
          return await source.load({ url: item.url, from: item.from }, item.strategy);
        } catch (error) {
          failures.push(`${item.from}${item.strategy ? `/${item.strategy}` : ''}: ${String(error.message).split('\n')[0]}`);
        }
      }
      source.mode = 'failed';
      const error = new Error(
        `取帧失败，已尝试：\n${failures.map((line) => `· ${line}`).join('\n')}\n\n${source.diagnose()}`
      );
      error.retriable = true; // 允许上层再去找新地址（网络观察 / 主世界读取）
      source.error = error;
      source.lastStrategyError = error.message;
      throw error;
    },

    nextStrategy(current) {
      const order = ['direct', 'blob', 'mse'];
      const index = order.indexOf(current);
      const next = order[index + 1];
      return next || null;
    },

    /**
     * 针对一个候选地址，按 direct → blob → mse 依次尝试。
     * @param {{url:string, from:string}} candidate
     * @param {string} [only] 只尝试某一种方式
     */
    async load(candidate, only) {
      const url = candidate.url;
      const strategies = only ? [only] : ['direct', 'blob', 'mse'];
      const errors = [];
      source.attempts = [];
      source.activeUrl = url;
      source.urlInfo = source.describeUrl(url);
      source.sourceName = candidate.from || 'player';
      for (const strategy of strategies) {
        if (source.aborted) throw new Error('已取消');
        try {
          if (strategy === 'direct') {
            await source.loadDirect(url);
            source.mode = 'direct';
            source.report({ phase: 'ready', value: 1, text: '已直连视频' });
            return source.element;
          }
          if (strategy === 'blob') {
            await source.loadBlob(url);
            source.mode = 'blob';
            return source.element;
          }
          if (strategy === 'mse') {
            await source.loadStream(url);
            source.mode = 'mse';
            return source.element;
          }
        } catch (error) {
          errors.push(`${strategy}: ${error.message}`);
          console.warn('[关键帧抓取] 取帧策略失败', strategy, error);
          source.lastStrategyError = error.message;
          source.attempts.push({ strategy, error: error.message || String(error) });
          source.reset();
          source.element = source.createElement();
          source.activeUrl = url;
        }
      }
      source.mode = 'failed';
      // 主动探针一次视频地址，把真实原因查清楚（HTTP 状态 / Content-Type / 是否支持 Range）
      const probe = await source.probe(url);
      source.probeResult = probe;
      const error = new Error(source.buildErrorMessage(errors, probe));
      source.error = error;
      throw error;
    },

    /** 只看协议就能判断的常见情况 */
    describeUrl(url) {
      const info = { url, protocol: '', host: '', kind: 'unknown' };
      try {
        const parsed = new URL(url, location.href);
        info.protocol = parsed.protocol;
        info.host = parsed.host;
        info.path = `${parsed.pathname}${parsed.search ? '?…' : ''}`;
      } catch {
        info.protocol = 'invalid';
      }
      if (!info.protocol || info.protocol === 'invalid') info.kind = 'invalid';
      else if (info.protocol === 'blob:') info.kind = 'blob';
      else if (info.protocol === 'data:') info.kind = 'data';
      else if (info.protocol === 'http:' || info.protocol === 'https:') info.kind = 'network';
      else info.kind = 'other';
      return info;
    },

    /**
     * 探针：对视频地址发一次小请求，收集真实可用的信息。
     * 不抛异常，全部结果写进返回值，便于原样展示给用户。
     */
    async probe(url) {
      const info = source.describeUrl(url);
      const result = {
        kind: info.kind,
        protocol: info.protocol,
        host: info.host,
        status: null,
        contentType: '',
        contentLength: '',
        acceptsRanges: null,
        rangeStatus: null,
        magic: '',
        error: ''
      };
      if (info.kind === 'blob') {
        result.error = '地址是 blob:（网页内部生成的媒体流，扩展无法直接读取）';
        return result;
      }
      if (info.kind !== 'network') {
        result.error = `不支持的地址协议：${info.protocol}`;
        return result;
      }
      try {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 8000);
        let response = await fetch(url, {
          method: 'GET',
          headers: { Range: 'bytes=0-1023' },
          credentials: 'omit',
          referrer: location.href,
          signal: controller.signal
        }).catch((error) => ({ ok: false, status: 0, error }));
        if (response.status === 416 || response.status === 501) {
          // 有些 CDN 对 Range 返回 416/501，退回普通请求再探一次
          response = await fetch(url, {
            method: 'GET',
            credentials: 'omit',
            referrer: location.href,
            signal: controller.signal
          }).catch((error) => ({ ok: false, status: 0, error }));
        }
        clearTimeout(timer);
        if (response.error) throw response.error;
        result.status = response.status;
        result.acceptsRanges = response.status === 206;
        result.rangeStatus = response.status;
        const headers = response.headers;
        if (headers && typeof headers.get === 'function') {
          result.contentType = headers.get('content-type') || '';
          result.contentLength = headers.get('content-length') || '';
          const range = headers.get('content-range');
          if (range) result.contentLength = String(range).split('/')[1] || result.contentLength;
        }
        // 读前 16 字节看看是不是媒体容器
        if (response.body && typeof response.body.getReader === 'function') {
          const reader = response.body.getReader();
          const first = await reader.read();
          if (first && first.value) {
            result.magic = source.magicOf(first.value.subarray(0, 16));
          }
          try {
            await reader.cancel();
          } catch {
            /* 忽略 */
          }
        }
      } catch (error) {
        result.error = (error && error.message) || String(error);
        if (error && error.name === 'AbortError') result.error = '探针请求超时（8 秒）';
      }
      return result;
    },

    /** 用容器魔数判断返回的到底是不是媒体数据 */
    magicOf(bytes) {
      const ascii = (start, end) =>
        String.fromCharCode.apply(null, Array.from(bytes.subarray(start, end)));
      if (bytes.length >= 12 && ascii(4, 8) === 'ftyp') {
        const brand = ascii(8, 12).toLowerCase();
        // 这些 brand 是图片容器（AVIF/HEIF），不是视频
        if (['avif', 'avis', 'heic', 'heix', 'hevc', 'mif1', 'msf1'].includes(brand)) {
          return `图片容器（${brand}）`;
        }
        return `MP4/fMP4（${brand}）`;
      }
      if (bytes.length >= 4 && ascii(0, 4) === 'styp') return 'MP4 分段';
      if (bytes.length >= 4 && bytes[0] === 0x1a && bytes[1] === 0x45 && bytes[2] === 0xdf && bytes[3] === 0xa3) {
        return 'Matroska/WebM';
      }
      if (bytes.length >= 4 && bytes[0] === 0x47 && bytes[188] === 0x47) return 'MPEG-TS';
      if (ascii(0, 4) === 'RIFF') return 'RIFF（可能是音频）';
      if (ascii(0, 5) === '<?xml' || ascii(0, 5) === '<!DOC') return 'XML（很可能是错误响应）';
      if (bytes[0] === 0x7b || bytes[0] === 0x5b) return 'JSON（很可能是错误响应）';
      if (ascii(0, 5) === '<html' || ascii(0, 5) === '<!doc') return 'HTML（很可能是登录/错误页）';
      return '未知';
    },

    /** 组织面向用户的错误文案：先给结论，再给诊断细节 */
    buildErrorMessage(errors, probe) {
      const lines = [];
      if (probe && probe.kind === 'blob') {
        lines.push(
          '这个视频是 blob: 地址（网页用 MSE 现场拼出来的流，扩展读不到原始数据）。',
          '常见于直播、部分番剧/付费内容，这类视频无法取帧。'
        );
      } else if (probe && probe.kind !== 'network' && probe.kind !== 'unknown') {
        lines.push(`视频地址协议不支持（${probe.protocol}），无法取帧。`);
      } else if (probe && probe.status) {
        lines.push(
          `视频地址返回 HTTP ${probe.status}${probe.magic ? `，返回内容像是「${probe.magic}」` : ''}。`
        );
        if (probe.status === 403) {
          lines.push('403 一般是防盗链：请先点击播放让播放器正常加载该视频，再重试。');
        } else if (probe.status === 404) {
          lines.push('404 说明地址已失效：刷新页面重新播放后再试。');
        } else if (probe.magic && /HTML|JSON|XML/.test(probe.magic)) {
          lines.push('返回的不是视频数据，通常意味着需要登录 / 有防盗链限制。');
        }
      } else if (probe && probe.error) {
        lines.push(`视频地址无法访问：${probe.error}`);
      } else {
        lines.push('三种取帧方式都失败。');
      }
      lines.push('', '各级尝试：');
      for (const line of errors) lines.push(`· ${line}`);
      if (probe) {
        const bits = [];
        if (probe.status) bits.push(`HTTP ${probe.status}`);
        if (probe.acceptsRanges !== null) bits.push(probe.acceptsRanges ? '支持分段' : '不支持分段');
        if (probe.contentType) bits.push(probe.contentType);
        if (probe.contentLength) bits.push(`${probe.contentLength} 字节`);
        if (probe.magic) bits.push(probe.magic);
        if (bits.length) lines.push('', `探针：${bits.join(' · ')}`);
      }
      return lines.join('\n');
    },

    /** 生成完整的诊断文本（面板 / 弹窗里可一键复制反馈） */
    diagnose(options) {
      const lines = [];
      lines.push('B站关键帧抓取器 · 取帧诊断');
      lines.push(`时间：${new Date().toLocaleString()}`);
      lines.push(`页面：${location.href}`);
      lines.push(`视频来源：${source.sourceName || '未知'}`);
      const info = source.urlInfo || source.describeUrl(source.activeUrl || '');
      lines.push(`视频协议：${info.protocol || '未知'}`);
      lines.push(`视频主机：${info.host || '未知'}`);
      lines.push(`视频路径：${info.path || '未知'}`);
      lines.push(`当前取帧方式：${source.mode}`);
      // 采样统计：回答「采了 N 次为什么只存 M 张」
      if (options && options.stats) {
        const stats = options.stats;
        lines.push(
          `采样统计：判定 ${stats.sampled || 0} 次 · 保存 ${stats.saved || 0} 张 · 跳过 ${stats.skipped || 0} 次 · 命中率 ${stats.hitRate || 0}%`
        );
        lines.push(`当前模式：${stats.mode || '未知'}（采样间隔 ${stats.intervalMs || '?'}ms）`);
        if (stats.lastDecision) {
          lines.push(`最近一次判定：${stats.lastDecision.reason}（Δ${((stats.lastDecision.change || 0) * 100).toFixed(1)}%）`);
        }
        if (stats.mode === 'auto') {
          lines.push('说明：关键帧模式只保存「画面明显变化」的帧，采样次数 ≠ 保存张数；');
          lines.push('想按间隔全部保存，请把抓取模式切到「逐帧抓取」。');
        }
      }
      const candidates = source.candidates(null);
      if (candidates.length) {
        lines.push(`候选地址数：${candidates.length}（${candidates.map((c) => c.from).join('、')}）`);
      }
      if (source.attempts && source.attempts.length) {
        lines.push('', '各方式尝试结果：');
        for (const attempt of source.attempts) {
          lines.push(`- ${attempt.strategy}: ${attempt.error}`);
        }
      }
      const probe = source.probeResult;
      if (probe) {
        lines.push('', '探针结果：');
        lines.push(`- 类型：${probe.kind}`);
        if (probe.status) lines.push(`- HTTP 状态：${probe.status}`);
        if (probe.acceptsRanges !== null) lines.push(`- 支持分段（206）：${probe.acceptsRanges}`);
        if (probe.contentType) lines.push(`- Content-Type：${probe.contentType}`);
        if (probe.contentLength) lines.push(`- 内容长度：${probe.contentLength}`);
        if (probe.magic) lines.push(`- 数据特征：${probe.magic}`);
        if (probe.error) lines.push(`- 探针错误：${probe.error}`);
      }
      if (source.lastStrategyError) lines.push('', `最近错误：${source.lastStrategyError}`);
      return lines.join('\n');
    },

    /* ---------------- 策略 1：直连 ---------------- */

    async loadDirect(url) {
      const video = source.element;
      video.crossOrigin = 'anonymous';
      video.src = url;
      video.load();
      await source.waitMetadata(video);
      if (video.readyState < 2) await source.waitEvent(video, 'loadeddata', META_TIMEOUT, '加载视频数据');
    },

    /* ---------------- 策略 2：整段下载成 blob ---------------- */

    async loadBlob(url) {
      const video = source.element;
      const blob = await source.fetchWhole(url, BLOB_LIMIT_BYTES);
      const objectUrl = URL.createObjectURL(blob);
      source.objectUrl = objectUrl;
      video.crossOrigin = null;      // blob 属于本站，无需 CORS
      video.src = objectUrl;
      video.load();
      await source.waitMetadata(video);
      source.report({ phase: 'ready', value: 1, text: `已下载视频（${core.bytes(blob.size)}）` });
    },

    /** 一次性把视频抓成 blob，边下边报告进度（不传 total 时按未知长度处理） */
    async fetchWhole(url, limit) {
      const controller = new AbortController();
      source.downloadAbort = () => controller.abort();
      const response = await fetch(url, {
        credentials: 'omit',
        referrer: location.href,
        signal: controller.signal
      });
      if (!response.ok) throw new Error(`下载视频失败：HTTP ${response.status}`);
      const total = Number(response.headers.get('content-length')) || 0;
      if (total && total > limit) {
        throw new Error(`视频约 ${core.bytes(total)}，超过整段下载上限 ${core.bytes(limit)}`);
      }
      const reader = response.body && response.body.getReader();
      if (!reader) {
        const blob = await response.blob();
        return blob;
      }
      const chunks = [];
      let received = 0;
      const startedAt = performance.now();
      for (;;) {
        if (source.aborted) throw new Error('已取消');
        const { done, value } = await reader.read();
        if (done) break;
        chunks.push(value);
        received += value.length;
        if (received > limit) throw new Error(`视频超过整段下载上限 ${core.bytes(limit)}`);
        const elapsed = Math.max(0.2, (performance.now() - startedAt) / 1000);
        source.report({
          phase: 'download',
          value: total ? received / total : 0,
          text: `下载视频 ${core.bytes(received)}${total ? ` / ${core.bytes(total)}` : ''}`,
          bytesPerSecond: received / elapsed
        });
      }
      return new Blob(chunks, { type: response.headers.get('content-type') || 'video/mp4' });
    },

    /* ---------------- 策略 3：MSE 流式 ---------------- */

    /**
     * fMP4 边下边播：
     *   - 先取开头 512KB，解析出 init 段（ftyp+moov）与第一个 moof+mdat
     *   - 之后每攒够 4MB 就往 SourceBuffer 追加一次，随下随播
     *   - 缓冲堆积过多时暂停下载，播放点之后超过 30 秒的旧数据会被清掉（省内存）
     */
    async loadStream(url) {
      if (typeof MediaSource === 'undefined') throw new Error('当前浏览器不支持 MediaSource 流式播放');
      const video = source.element;
      const controller = new AbortController();
      const response = await fetch(url, {
        credentials: 'omit',
        headers: { Range: `bytes=0-${MSE_START_BYTES - 1}` },
        referrer: location.href,
        signal: controller.signal
      });
      if (!response.ok && response.status !== 206) {
        throw new Error(`拉取视频失败：HTTP ${response.status}`);
      }
      const rangeSupport = response.status === 206;
      let head = new Uint8Array(await response.arrayBuffer());
      if (!rangeSupport) {
        // 服务端不支持 Range（返回了整段）：无法按需续传，交给下一级策略（整段下载）
        throw new Error('该视频地址不支持分段读取，改用整段下载');
      }
      head = head.subarray(0, MSE_START_BYTES);
      if (head.length < 64) throw new Error('视频数据异常（返回内容过短）');

      const init = source.parseBoxes(head, 0);
      const codec = source.codecFromInit(head.subarray(init.initEnd));
      if (!codec) throw new Error('无法识别视频编码（可能是非常规封装）');

      const mediaSource = new MediaSource();
      const objectUrl = URL.createObjectURL(mediaSource);
      source.objectUrl = objectUrl;
      video.crossOrigin = null;
      video.src = objectUrl;
      video.load();
      await source.waitEvent(mediaSource, 'sourceopen', META_TIMEOUT, '初始化流式播放');

      let buffer;
      try {
        buffer = mediaSource.addSourceBuffer(codec);
      } catch (error) {
        throw new Error(`浏览器不支持该编码（${codec}）：${error.message}`);
      }
      const state = {
        mediaSource,
        buffer,
        reader: null,
        downloaded: head.length,
        appended: 0,
        queue: [],
        pending: null,
        aborted: false,
        needMore: null,
        lastProgressAt: 0,
        startedAt: performance.now(),
        total: 0
      };
      source.mse = state;

      const bufferStart = head.subarray(0, init.initEnd);
      state.queue.push(bufferStart);
      state.appended = init.initEnd;
      let cursor = init.initEnd;

      const appendNext = () => {
        if (state.pending || state.aborted) return;
        if (!state.queue.length) return;
        const chunk = state.queue.shift();
        state.pending = chunk.length;
        try {
          buffer.appendBuffer(chunk);
        } catch (error) {
          state.pending = null;
          if (error && error.name === 'QuotaExceededError') {
            source.trimBuffer(buffer, video.currentTime);
            state.queue.unshift(chunk);
            setTimeout(appendNext, 300);
            return;
          }
          state.aborted = true;
          source.lastStrategyError = error.message;
        }
      };

      buffer.addEventListener('updateend', () => {
        state.pending = null;
        const buffered = buffer.buffered;
        if (buffered.length) {
          const end = buffered.end(buffered.length - 1);
          source.report({
            phase: 'stream',
            value: state.total ? end / state.total : 0,
            text: `流式加载到 ${core.timeText(end)}${state.total ? ` / ${core.timeText(state.total)}` : ''}`
          });
          source.trimBuffer(buffer, video.currentTime);
        }
        appendNext();
      });
      buffer.addEventListener('error', () => {
        state.aborted = true;
        source.lastStrategyError = '流式缓冲错误';
      });

      await source.waitMetadata(video);
      state.total = Number.isFinite(video.duration) ? video.duration : 0;

      // init 段之外，把开头已取到的 moof+mdat 也塞进去，尽快能播
      const firstMedia = head.subarray(init.initEnd, init.firstEnd > init.initEnd ? init.firstEnd : head.length);
      if (firstMedia.length) {
        state.queue.push(firstMedia);
        state.appended += firstMedia.length;
        cursor = Math.max(cursor, init.firstEnd);
      }
      appendNext();
      try {
        await video.play();
      } catch (error) {
        // 自动播放被拒：不致命，seek 时会再尝试
        console.warn('[关键帧抓取] 流式播放启动被拒', error);
      }

      // 后台持续下载（从 start 字节接着拉，Range 已确认可用）
      state.reader = source.streamRemaining({
        url,
        controller,
        state,
        start: cursor,
        appendNext,
        video
      });
      source.report({ phase: 'stream', value: 0, text: '流式加载中…' });
    },

    /** 续传剩余字节并切片入队 */
    async streamRemaining(options) {
      const { url, controller, state, start, appendNext, video } = options;
      try {
        const response = await fetch(url, {
          credentials: 'omit',
          headers: { Range: `bytes=${start}-` },
          referrer: location.href,
          signal: controller.signal
        });
        if (!response.ok && response.status !== 206) throw new Error(`HTTP ${response.status}`);
        state.total = Number(response.headers.get('content-range') || '').toString().includes('/')
          ? Number(String(response.headers.get('content-range')).split('/')[1]) || state.total
          : state.total;
        const reader = response.body.getReader();
        let pending = new Uint8Array(0);
        for (;;) {
          if (state.aborted || source.aborted) break;
          const { done, value } = await reader.read();
          if (done) break;
          const merged = new Uint8Array(pending.length + value.length);
          merged.set(pending, 0);
          merged.set(value, pending.length);
          pending = merged;
          // 攒够一定量再切，避免碎片太多
          if (pending.length >= MSE_APPEND_TARGET) {
            const cut = source.lastBoxEnd(pending);
            if (cut > 0 && cut < pending.length) {
              state.queue.push(pending.subarray(0, cut));
              pending = pending.subarray(cut);
              appendNext();
            } else if (cut >= pending.length) {
              state.queue.push(pending);
              pending = new Uint8Array(0);
              appendNext();
            }
          }
          // 缓冲太大时先等播放消费（按时间粗略估字节，够用即可）
          if (source.bufferAhead(state.buffer, video.currentTime) > MSE_SAFE_BUFFER) {
            await core.sleep(400);
          }
        }
        if (pending.length) {
          state.queue.push(pending);
          appendNext();
        }
      } catch (error) {
        if (error && error.name === 'AbortError') return;
        console.warn('[关键帧抓取] 流式下载中断', error);
        source.lastStrategyError = error.message;
      }
    },

    /** 当前播放点之后已缓冲的字节估算（约 3 Mbps => 375 B/ms），仅用于限流 */
    bufferAhead(buffer, currentTime) {
      try {
        const buffered = buffer.buffered;
        for (let i = 0; i < buffered.length; i += 1) {
          if (currentTime >= buffered.start(i) - 1 && currentTime <= buffered.end(i) + 1) {
            return (buffered.end(i) - currentTime) * 375;
          }
        }
      } catch {
        /* 忽略 */
      }
      return 0;
    },

    /** 丢掉播放点之后超过 MSE_KEEP_BEHIND 秒的旧数据，控制内存 */
    trimBuffer(buffer, currentTime) {
      try {
        if (buffer.updating) return;
        const buffered = buffer.buffered;
        for (let i = 0; i < buffered.length; i += 1) {
          const end = buffered.end(i);
          if (end < currentTime - MSE_KEEP_BEHIND) {
            buffer.remove(buffered.start(i), end);
            return;
          }
        }
      } catch {
        /* 忽略 */
      }
    },

    /* ---------------- fMP4 box 解析 ---------------- */

    /** 从头解析 box，返回 init 段结束位置与第一个媒体段结束位置 */
    parseBoxes(bytes, offset) {
      let cursor = offset;
      let initEnd = 0;
      let firstEnd = 0;
      let sawMoov = false;
      const readUint32 = (position) =>
        ((bytes[position] << 24) | (bytes[position + 1] << 16) | (bytes[position + 2] << 8) | bytes[position + 3]) >>> 0;

      while (cursor + 8 <= bytes.length) {
        const size = readUint32(cursor);
        const type = String.fromCharCode(bytes[cursor + 4], bytes[cursor + 5], bytes[cursor + 6], bytes[cursor + 7]);
        let boxSize = size;
        let headerSize = 8;
        if (size === 1) {
          // 64 位长度
          if (cursor + 16 > bytes.length) break;
          const high = readUint32(cursor + 8);
          const low = readUint32(cursor + 12);
          boxSize = high * 4294967296 + low;
          headerSize = 16;
        } else if (size === 0) {
          boxSize = bytes.length - cursor; // 一直到文件结尾
        }
        if (boxSize < headerSize) break;
        const boxEnd = cursor + boxSize;
        if (type === 'moov') {
          sawMoov = true;
          initEnd = boxEnd;
        } else if (type === 'moof' && sawMoov) {
          // 媒体段 = moof + 紧随的 mdat
          let next = boxEnd;
          if (next + 8 <= bytes.length) {
            const nextSize = readUint32(next);
            const nextType = String.fromCharCode(bytes[next + 4], bytes[next + 5], bytes[next + 6], bytes[next + 7]);
            if (nextType === 'mdat' && nextSize >= 8) {
              const end = next + (nextSize === 0 ? bytes.length - next : nextSize);
              firstEnd = Math.min(end, bytes.length);
            } else {
              firstEnd = boxEnd;
            }
          } else {
            firstEnd = boxEnd;
          }
          break;
        }
        if (boxEnd > bytes.length) break; // box 尚未下完
        if (!initEnd) initEnd = boxEnd;
        cursor = boxEnd;
      }
      if (!initEnd) initEnd = Math.min(bytes.length, offset + 8);
      if (!firstEnd) firstEnd = initEnd;
      return { initEnd, firstEnd };
    },

    /** 找出一段数据里最后一个完整 box 的结束位置（用于切片） */
    lastBoxEnd(bytes) {
      let cursor = 0;
      let last = 0;
      while (cursor + 8 <= bytes.length) {
        const size =
          ((bytes[cursor] << 24) | (bytes[cursor + 1] << 16) | (bytes[cursor + 2] << 8) | bytes[cursor + 3]) >>> 0;
        let boxSize = size;
        let headerSize = 8;
        if (size === 1) {
          if (cursor + 16 > bytes.length) break;
          const high =
            ((bytes[cursor + 8] << 24) | (bytes[cursor + 9] << 16) | (bytes[cursor + 10] << 8) | bytes[cursor + 11]) >>> 0;
          const low =
            ((bytes[cursor + 12] << 24) | (bytes[cursor + 13] << 16) | (bytes[cursor + 14] << 8) | bytes[cursor + 15]) >>> 0;
          boxSize = high * 4294967296 + low;
          headerSize = 16;
        }
        if (boxSize < headerSize) break;
        if (cursor + boxSize > bytes.length) break; // 这个 box 还没下完
        last = cursor + boxSize;
        cursor = last;
      }
      return last;
    },

    /** 从 init 段里提取 codec 字符串（00 00 00 xx 'avc1' ... 'avcC'） */
    codecFromInit(bytes) {
      const text = [];
      for (let i = 0; i < bytes.length; i += 1) text.push(String.fromCharCode(bytes[i]));
      const joined = text.join('');
      const candidates = [
        { sample: 'avc1', prefix: 'avc1' },
        { sample: 'avc3', prefix: 'avc1' },
        { sample: 'hvc1', prefix: 'hvc1' },
        { sample: 'hev1', prefix: 'hvc1' },
        { sample: 'av01', prefix: 'av01' }
      ];
      for (const candidate of candidates) {
        const index = joined.indexOf(candidate.sample);
        if (index < 0) continue;
        const after = joined.slice(index + 4, index + 4 + 200);
        const codecIndex = after.indexOf('avcC') >= 0 ? 'avcC' : (after.indexOf('hvcC') >= 0 ? 'hvcC' : (after.indexOf('av1C') >= 0 ? 'av1C' : ''));
        if (candidate.sample.startsWith('avc') || candidate.sample.startsWith('hev')) {
          // 配置记录紧跟在 avcC/hvcC box 头部之后
          const marker = after.indexOf(codecIndex);
          if (marker >= 0) {
            const base = marker + 4 + 4; // 'avcC' + version/flags 头部
            const configLen = candidate.sample.startsWith('avc') ? 4 : 22;
            const hex = [];
            for (let i = 0; i < configLen && base + i < after.length; i += 1) {
              hex.push(after.charCodeAt(base + i).toString(16).padStart(2, '0'));
            }
            if (candidate.sample.startsWith('avc')) {
              // avcC: [0]=configurationVersion, [1..3]=profile/compat/level
              if (hex.length >= 4) {
                return `video/mp4; codecs="${candidate.prefix}.${hex[1]}${hex[2]}${hex[3]}"`;
              }
            } else if (hex.length >= 3) {
              return `video/mp4; codecs="${candidate.prefix}.1.6.L93.B0"`;
            }
          }
        }
        if (candidate.sample.startsWith('av01')) {
          return 'video/mp4; codecs="av01.0.05M.08"';
        }
      }
      // 兜底：B 站主流编码
      return 'video/mp4; codecs="avc1.640028"';
    },

    /* ---------------- 等待工具 ---------------- */

    waitMetadata(video) {
      if (video.readyState >= 1) return Promise.resolve();
      return source.waitEvent(video, 'loadedmetadata', META_TIMEOUT, '加载视频元数据');
    },

    waitEvent(target, event, timeoutMs, label) {
      return new Promise((resolve, reject) => {
        let timer = null;
        const cleanup = () => {
          target.removeEventListener(event, onOk);
          target.removeEventListener('error', onFail);
          if (timer) clearTimeout(timer);
        };
        const onOk = () => {
          cleanup();
          resolve();
        };
        const onFail = () => {
          cleanup();
          const media = target.error;
          reject(
            new Error(
              `${label || event}失败${media && media.message ? `（${media.message}）` : ''}` +
                '（可能是网络、CORS 或媒体格式问题）'
            )
          );
        };
        target.addEventListener(event, onOk, { once: true });
        target.addEventListener('error', onFail, { once: true });
        timer = setTimeout(() => {
          cleanup();
          reject(new Error(`${label || event}超时`));
        }, timeoutMs || META_TIMEOUT);
      });
    }
  };

  NS.framesource = source;
})();

/**
 * capture.js —— 从 <video> 抓取当前画面
 *
 * 取帧用的隐藏 video 由 framesource.js 负责准备（直连 / 下载成 blob / MSE 流式），
 * 这里只负责：定位到目标时间点、绘制、编码、判定画面是否值得保存。
 *
 * 另外提供一层「策略回退」：如果取帧过程中隐藏视频出错或长时间卡住，
 * 会自动换用下一种取帧策略重新加载同一段视频，然后重试当前这一帧。
 */
(function () {
  'use strict';

  const NS = (window.__BKF__ = window.__BKF__ || {});
  const core = NS.core;

  /** 隐藏视频卡住 / 报错时抛出，交给上层触发策略回退 */
  class StallError extends Error {
    constructor(message) {
      super(message);
      this.name = 'StallError';
      this.stall = true;
    }
  }

  /** 采集签名用的复用画布（detector 内部会按需调整尺寸） */
  NS.detectorCanvas = document.createElement('canvas');

  function waitUntilReached(element, target, timeoutMs) {
    return new Promise((resolve, reject) => {
      let timer = null;
      const check = () => {
        if (Math.abs((element.currentTime || 0) - target) <= 0.08) {
          cleanup();
          resolve();
          return true;
        }
        return false;
      };
      const onTick = () => {
        if (check()) return;
        if (element.error) {
          cleanup();
          reject(new StallError(`播放器报错：${element.error.message || '未知媒体错误'}`));
        }
      };
      const cleanup = () => {
        if (timer) clearTimeout(timer);
        element.removeEventListener('seeked', onTick);
        element.removeEventListener('timeupdate', onTick);
        element.removeEventListener('error', onTick);
      };
      element.addEventListener('seeked', onTick);
      element.addEventListener('timeupdate', onTick);
      element.addEventListener('error', onTick);
      if (check()) return;
      timer = setTimeout(() => {
        cleanup();
        reject(
          new StallError(
            `定位到 ${target.toFixed(1)}s 失败：隐藏视频停在 ${(element.currentTime || 0).toFixed(1)}s`
          )
        );
      }, timeoutMs || 6000);
    });
  }

  /**
   * 定位到指定时间点并等待该帧可绘制。
   * 优先使用 requestVideoFrameCallback，保证绘制的是「定位之后」的帧。
   * @param {object} [options] { force:true } 忽略「已在目标位置」的快速路径：
   *        扫描时隐藏视频在持续播放（currentTime 一直在变），必须强制定位。
   */
  async function seekTo(element, time, options) {
    const opts = options || {};
    const seekStart = performance.now();
    const duration = Number.isFinite(element.duration) ? element.duration : time;
    const clamped = Math.max(0, Math.min(time, duration - 0.04));
    if (!opts.force) {
      const distance = Math.abs((element.currentTime || 0) - clamped);
      if (distance <= 0.05 && element.readyState >= 2) {
        return { actualTime: element.currentTime, cost: 0 };
      }
    }
    element.dataset.seekTarget = String(clamped);
    element.currentTime = clamped;

    const frameReady =
      'requestVideoFrameCallback' in element
        ? new Promise((resolve) => {
            let fired = false;
            element.requestVideoFrameCallback(() => {
              fired = true;
              resolve();
            });
            // 某些情况下 seek 不会产生新帧回调，兜底
            setTimeout(() => {
              if (!fired) resolve();
            }, 1500);
          })
        : core.sleep(280);

    const reached = waitUntilReached(element, clamped, 6000);
    await Promise.all([
      waitEvent(element, 'seeked', 6000, '定位视频帧').catch(() => {}),
      frameReady,
      reached.catch(() => {})
    ]);
    await reached; // 真正判断是否到位（失败则抛 StallError 触发策略回退）
    return { actualTime: element.currentTime, cost: Math.round(performance.now() - seekStart) };
  }

  function waitEvent(target, event, timeoutMs, label) {
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
        reject(new StallError(`${label || event}失败（可能是网络或媒体格式问题）`));
      };
      target.addEventListener(event, onOk, { once: true });
      target.addEventListener('error', onFail, { once: true });
      timer = setTimeout(() => {
        cleanup();
        reject(new StallError(`${label || event}超时`));
      }, timeoutMs || 12000);
    });
  }

  /** 取源 + 把某次操作包一层策略回退 */
  async function withSource(pageVideo, options, operation) {
    const opts = options || {};
    let element = await NS.framesource.ensure(pageVideo, { extra: opts.extra });
    try {
      return await operation(element);
    } catch (error) {
      // 画面被安全策略拦截（画布被污染）时，也当作需要换策略处理
      if (error && error.name === 'SecurityError') {
        error.stall = true;
        error.message = `浏览器阻止读取该视频像素（${error.message}）`;
      }
      const canRetry = !opts.noRetry && (error instanceof StallError || error.stall);
      if (!canRetry) throw error;
      console.warn('[关键帧抓取] 取帧失败，尝试换用下一种取帧策略：', error.message);
      element = await NS.framesource.reloadWithNextStrategy(pageVideo);
      return await operation(element);
    }
  }

  /** 把 video 当前帧绘制到一张新画布，并限制最长边 */
  function drawScaled(video, maxWidth) {
    const vw = video.videoWidth || 1280;
    const vh = video.videoHeight || 720;
    const scale = Math.min(1, (maxWidth || 1280) / Math.max(vw, vh));
    const width = Math.max(2, Math.round(vw * scale));
    const height = Math.max(2, Math.round(vh * scale));
    const canvas = document.createElement('canvas');
    canvas.width = width;
    canvas.height = height;
    const ctx = canvas.getContext('2d', { alpha: false });
    ctx.imageSmoothingEnabled = true;
    if ('imageSmoothingQuality' in ctx) ctx.imageSmoothingQuality = 'high';
    ctx.drawImage(video, 0, 0, width, height);
    return canvas;
  }

  function canvasToDataUrl(canvas, format, quality) {
    if (format === 'png') return canvas.toDataURL('image/png');
    return canvas.toDataURL('image/jpeg', core.clamp(quality || 0.85, 0.3, 1));
  }

  /** 判断一帧是否「有内容」：过暗或几乎无对比度的画面不值得保存 */
  function isMeaningful(stats, signature) {
    if (signature && signature.brightness <= 3) return false;
    if (!stats) return true;
    if (stats.p99 - stats.p1 < 6) return false; // 纯色 / 一片死黑
    return true;
  }

  const capture = {
    StallError,

    /** 加载（或复用）隐藏取帧视频 */
    async ensureSource(pageVideo) {
      return NS.framesource.ensure(pageVideo);
    },

    /** 当前取帧方式：direct | blob | mse | failed */
    currentMode() {
      return NS.framesource.mode;
    },

    seekTo,
    withSource,
    isMeaningful,

    /** 播放器当前时间 */
    currentTimeOf(video) {
      const time = video && Number.isFinite(video.currentTime) ? video.currentTime : 0;
      return Math.round(time * 1000) / 1000;
    },

    /**
     * 抓取一帧（用于正常播放 / 手动抓取）。
     * @param {HTMLVideoElement} video 正在播放的 video（仅用于取 src / 时间轴）
     * @param {object} context { time, signature, stats, detection, settings, videoMeta, sessionKey }
     * @returns {Promise<object>} 消息负载
     */
    async captureFrame(video, context) {
      return withSource(video, Object.assign({ extra: context.extra }, context), async (element) => {
        const distance = Math.abs((element.currentTime || 0) - context.time);
        if (distance > 0.05) {
          const seeked = await seekTo(element, context.time);
          return capture.fromElement(element, context, { time: seeked.actualTime });
        }
        return capture.fromElement(element, context, { time: element.currentTime });
      });
    },

    /**
     * 「播放并抓帧」扫描专用：隐藏视频自己在播放 / 已被定位到目标帧，
     * 因此不再重复 seek，直接读当前帧。
     */
    async captureCurrent(video, context) {
      return capture.readerFrame(video, context);
    },

    /** 读取当前 reader 画面并编码（不做 seek） */
    async readerFrame(video, context) {
      return withSource(video, Object.assign({ extra: context.extra }, context), async (element) =>
        capture.fromElement(element, context, { time: element.currentTime })
      );
    },

    /** 核心：把 element 的当前帧编码成完整图 + 缩略图 */
    async fromElement(element, context, timing) {
      const settings = context.settings;
      const time = timing && Number.isFinite(timing.time) ? timing.time : element.currentTime;

      // 抽样在「同一帧」上完成，保证 hash 与实际保存的画面一致
      const signature = context.signature || NS.detector.sample(element, NS.detectorCanvas);
      if (!isMeaningful(context.stats, signature)) {
        return {
          skipped: true,
          reason: '画面为纯色/过暗，已忽略',
          time,
          hash: signature.hash,
          signature,
          stats: context.stats
        };
      }

      const full = drawScaled(element, settings.maxWidth);
      const imageDataUrl = canvasToDataUrl(full, settings.format, settings.quality);

      const thumb = drawScaled(element, settings.thumbWidth);
      const thumbnailDataUrl = canvasToDataUrl(thumb, 'jpeg', 0.7);

      return {
        skipped: false,
        sessionKey: context.sessionKey,
        time,
        requestTime: time,
        seekCost: 0,
        hash: signature.hash,
        signature,
        stats: context.stats,
        detection: context.detection,
        pass: context.pass || 1,
        width: full.width,
        height: full.height,
        imageDataUrl,
        thumbnailDataUrl,
        video: context.videoMeta
      };
    }
  };

  NS.capture = capture;
})();

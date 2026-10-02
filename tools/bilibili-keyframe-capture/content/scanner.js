/**
 * scanner.js —— 「播放并抓帧」：离线扫描整个视频并自动抓取关键帧
 *
 * 做法：让隐藏的 CORS 干净 video（capture.js 里的 reader）自己按倍速播放，
 * 按固定间隔采样当前画面做关键帧判定，命中就编码保存。相比从头到尾手动 seek，
 * 倍速播放更快、更省请求，也不会让主播放器跳到奇怪的位置。
 *
 * 过程中持续汇报进度（当前时间 / 进度百分比 / 已保存帧数 / 预计剩余），
 * 可随时中止；主播放器会被暂停（可配置），扫描结束后可选择自动打开图库。
 */
(function () {
  'use strict';

  const NS = (window.__BKF__ = window.__BKF__ || {});
  const core = NS.core;

  const PROGRESS_MS = 350;      // 进度汇报节流
  const MIN_LOOP_MS = 100;      // 播放模式下两次采样之间的最小真实间隔（与采样间隔下限一致）
  const SEEK_LAG = 1.5;         // 播放位置连续落后目标超过该秒数则改用显式 seek
  const MAX_CONSECUTIVE_ERRORS = 5;

  const scanner = {
    running: false,
    saved: 0,
    current: 0,
    duration: 0,
    startedAt: 0,
    eta: 0,
    message: '',
    finishedReason: '',
    cancelRequested: false,
    onProgress: null,
    onFrame: null,

    get progress() {
      const duration = scanner.duration || 0;
      return {
        scanning: scanner.running,
        scanCurrent: Math.round(scanner.current * 10) / 10,
        scanDuration: Math.round(duration * 10) / 10,
        scanPercent: duration > 0 ? Math.min(100, Math.round((scanner.current / duration) * 100)) : 0,
        scanSaved: scanner.saved,
        scanEta: scanner.eta,
        scanMessage: scanner.message,
        scanStartedAt: scanner.startedAt
      };
    },

    cancel() {
      if (!scanner.running) return false;
      scanner.cancelRequested = true;
      scanner.message = '正在停止…';
      scanner.emit();
      return true;
    },

    emit() {
      if (typeof scanner.onProgress === 'function') {
        try {
          scanner.onProgress(scanner.progress);
        } catch {
          /* 忽略回调异常 */
        }
      }
    },

    /**
     * 开始扫描。
     * @param {object} options
     *   video      页面里的 video（取 src 用）
     *   settings   当前设置
     *   sessionKey 会话 id
     *   videoMeta  视频元数据
     *   maxFrames  单会话上限
     *   onFrame    async (payload) => { stored, frameCount, ... } 保存回调
     *   onProgress (progress) => void
     *   resumeMain 结束后是否恢复主播放器
     */
    async start(options) {
      if (scanner.running) throw new Error('已经在扫描中');
      const video = options.video;
      if (!video) throw new Error('当前页面没有可用的视频');
      const settings = options.settings;

      scanner.running = true;
      scanner.cancelRequested = false;
      scanner.saved = 0;
      scanner.current = 0;
      scanner.startedAt = Date.now();
      scanner.eta = 0;
      scanner.finishedReason = '';
      scanner.message = '正在加载视频…';
      scanner.onProgress = options.onProgress;
      scanner.onFrame = options.onFrame;
      const maxFrames = options.maxFrames || settings.maxFramesPerSession || 300;

      const pauseMain = () => {
        if (!settings.scanPauseMain) return false;
        if (!video.paused) {
          video.pause();
          return true;
        }
        return false;
      };
      const wasPlaying = pauseMain();

      let element = null;
      try {
        // 允许注入（自测用）：默认由 framesource 准备隐藏取帧视频
        element = options.reader || (await NS.capture.ensureSource(video));
        // 把「下载 / 流式加载」进度接到扫描进度上，让用户看得到在准备
        NS.framesource.onProgress = (progress) => {
          if (!progress) return;
          scanner.message = progress.text ? `准备取帧：${progress.text}` : scanner.message;
          scanner.emit();
        };
        scanner.duration = Number.isFinite(element.duration) ? element.duration : (video.duration || 0);
        if (!(scanner.duration > 1)) throw new Error('无法获取视频时长，可能还没加载完成，请稍后重试');

        element.pause();
        element.muted = true;
        const step = core.clamp(settings.scanInterval, 0.15, 10);
        const rate = core.clamp(settings.scanRate, 1, 16);
        element.playbackRate = rate;

        // 采样间隔 > 1 秒时，用 seek 比让隐藏视频播放更划算（不必解码整段）
        const usePlayback = step <= 0.95;
        const loopFloor = usePlayback
          ? Math.max(settings.intervalMs || 0, Math.round(step * 1000))
          : 0;
        let cursor = 0;             // 采样位置（播放模式下跟随隐藏视频的真实位置）
        let lastSignature = null;   // 不变量：上一张『已保存』关键帧的签名
        let attempted = 0;          // 尝试保存的帧数（含被后台拒绝的）
        let limitReached = false;   // 是否已达单会话上限
        let consecutiveErrors = 0;
        let lastProgressAt = 0;
        let lastLoopAt = 0;
        let lagCount = 0;

        if (!usePlayback) {
          // 逐点定位模式：全程 paused，用 seek 精确定位
          element.currentTime = 0;
        } else {
          element.currentTime = 0;
          try {
            await element.play();
          } catch (error) {
            throw new Error(`隐藏视频无法播放（${error.message}），请先点击一次页面让浏览器授权播放`);
          }
        }

        scanner.message = usePlayback
          ? `${rate}× 扫描中（每 ${step}s 采样）`
          : `定位扫描中（每 ${step}s 采样）`;

        const report = (force) => {
          const now = performance.now();
          if (!force && now - lastProgressAt < PROGRESS_MS) return;
          lastProgressAt = now;
          const remaining = Math.max(0, scanner.duration - cursor);
          scanner.eta = remaining > 0 ? Math.round(remaining / (usePlayback ? rate : 1)) : 0;
          scanner.emit();
        };
        report(true);

        /* ---------------- 扫描主循环 ---------------- */
        for (;;) {
          if (scanner.cancelRequested) {
            scanner.finishedReason = '已手动停止';
            break;
          }
          if (limitReached) {
            scanner.finishedReason = `已达单会话上限 ${maxFrames} 帧`;
            break;
          }
          if (cursor >= scanner.duration - 0.05) {
            scanner.finishedReason = '已扫描完整个视频';
            break;
          }

          // 取帧策略可能在上一轮失败后换过，这里重新取当前元素，避免操作到已卸载的旧元素
          const current = NS.framesource && NS.framesource.element;
          if (current && current !== element && current.isConnected) {
            element = current;
            if (usePlayback) {
              element.muted = true;
              element.playbackRate = rate;
            }
          }

          // 1) 让隐藏视频走到目标时间点
          if (usePlayback) {
            // 播放模式下如果解码 / 缓冲跟不上，就退回显式 seek 保证不卡死
            const behind = cursor - element.currentTime;
            if (behind > SEEK_LAG) {
              lagCount += 1;
              if (lagCount >= 3) {
                await NS.capture.seekTo(element, cursor, { force: true });
                lagCount = 0;
              }
            } else {
              lagCount = 0;
            }
          } else {
            await NS.capture.seekTo(element, cursor, { force: true });
          }

          // 2) 采样 + 判定
          try {
            const signature = NS.detector.sample(element, NS.detectorCanvas);
            const decision = NS.detector.evaluate(lastSignature, signature, settings);
            scanner.current = cursor;
            if (decision.accept && signature.brightness > 4) {
              const payload = await NS.capture.readerFrame(video, {
                time: element.currentTime,
                signature,
                detection: {
                  hashDistance: decision.hashDistance,
                  mad: decision.mad,
                  change: decision.change,
                  reason: '扫描'
                },
                settings,
                sessionKey: options.sessionKey,
                videoMeta: options.videoMeta
              });
              if (!payload.skipped) {
                attempted += 1;
                const saved = await options.onFrame(payload);
                if (saved && saved.stored) {
                  scanner.saved += 1;
                  lastSignature = signature;
                  if (saved.reachedLimit) limitReached = true;
                } else if (saved && saved.reachedLimit) {
                  limitReached = true;
                }
                scanner.message = `已抓 ${scanner.saved} 帧 · ${core.timeText(cursor)}`;
              }
              consecutiveErrors = 0;
            } else {
              scanner.message = `扫描中 · ${core.timeText(cursor)}（${decision.reason}）`;
            }
          } catch (error) {
            consecutiveErrors += 1;
            scanner.message = `取帧失败（${consecutiveErrors}/${MAX_CONSECUTIVE_ERRORS}）：${error.message}`;
            if (consecutiveErrors >= MAX_CONSECUTIVE_ERRORS) {
              scanner.finishedReason = `连续取帧失败：${error.message}`;
              break;
            }
          }

          report(false);

          // 3) 推进游标
          if (usePlayback) {
            // 采样位置跟随隐藏视频的真实播放进度，避免和倍速脱节
            const actual = element.currentTime;
            if (actual <= cursor + 0.001) {
              // 播放器还没走（缓冲 / 卡顿），小睡一下再采样，顺带兜底 seek
              await core.sleep(MIN_LOOP_MS);
              if (element.currentTime - cursor < 0.1 && !element.paused) {
                // 完全没前进：可能是缓冲，等待更久
                await core.sleep(180);
              }
              if (element.currentTime < cursor - SEEK_LAG) {
                await NS.capture.seekTo(element, cursor, { force: true });
              }
            } else {
              cursor = actual;
            }
            // 已经播到片尾就别再采一次了，否则容易把「结尾推荐 / 黑场」也存进来
            if (cursor >= scanner.duration - 0.1) {
              scanner.current = scanner.duration;
              scanner.finishedReason = '已扫描完整个视频';
              break;
            }
            const sinceLoop = performance.now() - lastLoopAt;
            if (sinceLoop < loopFloor) await core.sleep(loopFloor - sinceLoop);
            lastLoopAt = performance.now();
          } else {
            cursor = Math.round((cursor + step) * 1000) / 1000;
            await core.sleep(30);
          }
        }

        /* ---------------- 收尾 ---------------- */
        try {
          element.pause();
        } catch {
          /* 忽略 */
        }
        scanner.current = Math.min(scanner.duration, Math.max(scanner.current, element.currentTime || 0));
        report(true);
        const result = {
          saved: scanner.saved,
          attempted,
          duration: scanner.duration,
          reason: scanner.finishedReason || '扫描结束',
          cancelRequested: scanner.cancelRequested,
          elapsedMs: Date.now() - scanner.startedAt
        };
        if (wasPlaying && settings.scanPauseMain && !scanner.cancelRequested) {
          // 扫描完把主播放器交还给用户（从当前位置继续，不跳时间）
          video.play().catch(() => {});
        }
        return result;
      } catch (error) {
        try {
          if (element) element.pause();
        } catch {
          /* 忽略 */
        }
        if (wasPlaying) video.play().catch(() => {});
        scanner.message = error.message;
        scanner.finishedReason = error.message;
        throw error;
      } finally {
        scanner.running = false;
        scanner.onProgress = null;
        scanner.onFrame = null;
        scanner.cancelRequested = false;
        if (NS.framesource) NS.framesource.onProgress = null;
        scanner.emit();
      }
    }
  };

  NS.scanner = scanner;
})();

/**
 * main.js —— 内容脚本主控：会话、自动抓帧循环、消息与快捷键
 */
(function () {
  'use strict';

  const NS = (window.__BKF__ = window.__BKF__ || {});
  const core = NS.core;

  /** 模式的中文短名，用于状态提示 */
  const MODE_LABELS = {
    off: '仅手动',
    auto: '自动·关键帧',
    every: '逐帧抓取',
    interval: '定间隔抓取'
  };

  const controller = {
    settings: null,
    video: null,
    sessionKey: null,
    session: null,
    lastHref: '',            // 上一次的页面地址（用于识别换视频/换分P）
    loopActive: false,       // 帧回调链是否已拉起（防止重复注册 / 状态脱节）
    running: false,
    busy: false,
    autoPaused: false,          // 图库打开时临时暂停
    lastAccepted: null,         // 上一张已保存关键帧的签名
    lastSampleAt: 0,
    lastFrameAt: 0,
    savedCount: 0,
    totalCount: 0,
    lastTime: null,
    lastError: '',
    status: '未开始',
    sampleCount: 0,          // 一共判定过多少次（采样次数）
    skipCount: 0,            // 判定后被跳过（变化不足 / 重复 / 黑场）的次数
    savedHashes: new Set(),  // 已保存画面的哈希，用于挡掉重复帧
    lastSampleHash: '',      // 上一次采样的哈希（连续同帧时不重复保存）
    lastVideoTime: 0,        // 上一次采样时的视频时间（用于识别循环重播）
    pass: 1,                 // 当前是第几遍观看（多播几遍可以补齐采样空洞）
    lastDecision: null,      // 最近一次判定结果 { reason, change }
    autoExporting: false,
    scanning: false,
    scanProgress: null,
    lastScanBroadcastAt: 0,
    detached: [],

    async start() {
      controller.settings = await core.getSettings();
      NS.panel.init(controller);
      NS.panel.setCollapsed(!controller.settings.panelExpanded, false);
      NS.gallery.init(controller);

      chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
        if (!message || !message.type) return undefined;
        controller.onMessage(message, sendResponse);
        return true; // 保持通道，异步回复
      });
      chrome.storage.onChanged.addListener((changes, area) => {
        if (area === 'local' && changes.settings) {
          controller.settings = core.normalizeSettings(changes.settings.newValue);
          NS.panel.renderStats();
          NS.panel.setVisible(controller.settings.showPanel);
        }
      });
      core.on('frames-updated', () => controller.refreshCounts());

      controller.video = await core.waitForVideo(30000);
      if (!controller.video) {
        controller.status = '未找到视频，请先播放';
        NS.panel.setVisible(controller.settings.showPanel);
        NS.panel.renderStats();
        return;
      }

      controller.bindVideo(controller.video);
      await controller.syncSession();

      NS.panel.setVisible(controller.settings.showPanel);
      NS.panel.renderStats();

      // B 站是 SPA：定期检查 URL / video 元素是否变化
      controller.lastHref = location.href;
      setInterval(controller.watchNavigation, 1500);
      // video 元素可能被播放器重建，定期重新绑定；顺带兜底把帧回调链拉起来
      setInterval(() => {
        const current = core.findVideo();
        if (current && current !== controller.video) {
          controller.bindVideo(current);
          controller.syncSession();
        }
        controller.ensureLoop();
        NS.panel.renderStats();
      }, 2500);

      // 按保存的模式决定是否自动开始；默认模式是「仅手动」，
      // 所以进入页面后自动抓取是暂停的，不会在后台默默消耗
      if (controller.settings.mode !== 'off') controller.setRunning(true);
      else controller.status = '已暂停（默认不自动抓取，需要时点「开始自动抓取」）';
      NS.panel.renderStats();
    },

    onMessage(message, sendResponse) {
      switch (message.type) {
        case 'capture-now':
          controller.captureNow(message.source || 'external')
            .then((result) => sendResponse({ ok: true, data: result }))
            .catch((error) => sendResponse({ ok: false, error: error.message }));
          return;
        case 'gallery.open':
          NS.gallery.open();
          sendResponse({ ok: true, data: { opened: true } });
          return;
        case 'scan.start':
          controller.startScan()
            .then((result) => sendResponse({ ok: true, data: result }))
            .catch((error) => sendResponse({ ok: false, error: error.message }));
          return;
        case 'scan.stop':
          sendResponse({ ok: true, data: { stopped: NS.scanner.cancel() } });
          return;
        case 'scan.progress':
          // 由后台广播过来的进度（用于多标签页同步显示）
          core.emit('scan-progress', { scan: message.scan || null, sessionId: message.sessionId || null });
          sendResponse({ ok: true, data: { relayed: true } });
          return;
        case 'gallery.close':
          NS.gallery.close();
          sendResponse({ ok: true, data: { closed: true } });
          return;
        case 'settings.apply':
          controller.reloadSettings()
            .then(() => sendResponse({ ok: true, data: controller.getStats() }))
            .catch((error) => sendResponse({ ok: false, error: error.message }));
          return;
        case 'session.autoExportStarted':
          controller.status = '正在导出…';
          NS.panel.renderStats();
          sendResponse({ ok: true, data: true });
          return;
        case 'session.reachedLimit':
          controller.status = `已达上限，自动导出（${message.mode}）`;
          NS.panel.renderStats();
          sendResponse({ ok: true, data: true });
          return;
        case 'panel.show':
          controller.setPanelVisible(true);
          sendResponse({ ok: true, data: { visible: true } });
          return;
        case 'panel.hide':
          controller.setPanelVisible(false);
          sendResponse({ ok: true, data: { visible: false } });
          return;
        case 'video.actions':
          sendResponse({ ok: true, data: controller.videoActions() });
          return;
        case 'ping':
          sendResponse({ ok: true, data: { pong: true, stats: controller.getStats() } });
          return;
        case 'diagnose':
          sendResponse({
            ok: true,
            data: {
              text: NS.framesource ? NS.framesource.diagnose() : '（无取帧诊断信息）',
              mode: NS.framesource ? NS.framesource.mode : 'unknown'
            }
          });
          return;
        case 'media.list':
          // 弹窗手动触发：重新找一遍可用地址并尝试切换取帧源
          controller
            .switchToObservedSource()
            .then((result) => sendResponse({ ok: true, data: result }))
            .catch((error) => sendResponse({ ok: false, error: error.message }));
          return;
        case 'replay':
          controller
            .replayForMore()
            .then((result) => sendResponse({ ok: true, data: result }))
            .catch((error) => sendResponse({ ok: false, error: error.message }));
          return;
        default:
          return;
      }
    },

    /** 视频相关的可用动作（供弹窗显示） */
    videoActions() {
      return {
        hasVideo: controller.hasVideo(),
        sessionKey: controller.sessionKey,
        title: controller.videoTitle(),
        running: controller.running
      };
    },

    async reloadSettings() {
      controller.settings = await core.getSettings();
      NS.panel.setVisible(controller.settings.showPanel);
      NS.panel.setCollapsed(!controller.settings.panelExpanded, false);
      NS.panel.renderStats();
      // 扫描进行中时不要因为设置变化去动 running，避免和扫描互相打断
      if (controller.scanning) return controller.settings;
      if (controller.settings.mode === 'off') controller.setRunning(false);
      else if (!controller.running) controller.setRunning(true);
      return controller.settings;
    },

    bindVideo(video) {
      if (!video) return;
      controller.video = video;
      for (const off of controller.detached) off();
      controller.detached = [];
      const onMeta = () => controller.syncSession();
      video.addEventListener('loadedmetadata', onMeta);
      video.addEventListener('emptied', onMeta);
      controller.detached.push(() => {
        video.removeEventListener('loadedmetadata', onMeta);
        video.removeEventListener('emptied', onMeta);
      });
      // 注意：这里不要再直接 setRunning，否则会把 running 置位却又拉不起回调链；
      // 需要开始时统一走 setRunning(false) → setRunning(true) 或 ensureLoop()
      const wantRunning = controller.settings ? controller.settings.mode !== 'off' : false;
      if (wantRunning) {
        controller.running = false;
        controller.loopActive = false;
        controller.setRunning(true);
      } else {
        controller.setRunning(false);
      }
    },

    watchNavigation() {
      const href = location.href;
      const navChanged = href !== controller.lastHref;
      if (navChanged) controller.lastHref = href;
      const video = core.findVideo();
      if (video && video !== controller.video) {
        controller.bindVideo(video);
        controller.syncSession();
        return;
      }
      // 地址变了（换视频 / 换分P）也一定要重新会话，光比 sessionKey 不够：
      // SPA 切集时 video 元素的 currentSrc 可能还是旧的，导致两边都判定「没变」
      if (navChanged) {
        controller.syncSession();
        return;
      }
      const key = controller.sessionKeyFor(video);
      if (key && key !== controller.sessionKey) controller.syncSession();
    },

    /**
     * 会话标识：站点 + 视频号 + 分 P + cid。切换视频/分 P 会自动换会话，
     * 避免不同视频的关键帧混在一起。
     */
    sessionKeyFor(video) {
      const url = new URL(location.href);
      const bv = (location.pathname.match(/\/(BV[0-9A-Za-z]+)/) || [])[1] || '';
      const av = (location.pathname.match(/\/av(\d+)/) || [])[1] || '';
      const ep = (location.pathname.match(/\/ep(\d+)/) || [])[1] || '';
      const ss = (location.pathname.match(/\/ss(\d+)/) || [])[1] || '';
      const page = url.searchParams.get('p') || '1';
      let cid = url.searchParams.get('cid') || '';
      if (!cid && window.__INITIAL_STATE__ && window.__INITIAL_STATE__.videoData) {
        cid = String(window.__INITIAL_STATE__.videoData.cid || '');
      }
      let id = bv || (av ? `av${av}` : '') || (ep ? `ep${ep}` : '') || (ss ? `ss${ss}` : '');
      if (!id) id = url.pathname.replace(/[^\w]+/g, '_').slice(1, 60) || 'bilibili';
      const duration = video && Number.isFinite(video.duration) ? Math.round(video.duration) : 0;
      return {
        id: `${id}${cid ? `-${cid}` : ''}${page !== '1' ? `-p${page}` : ''}`,
        bvid: bv || av || ep || ss,
        page: Number(page) || 1,
        cid,
        duration,
        url: location.href
      };
    },

    videoTitle() {
      const state = window.__INITIAL_STATE__;
      if (state && state.videoData && state.videoData.title) return state.videoData.title;
      if (state && state.epInfo && state.epInfo.title) return state.epInfo.title;
      const h1 = document.querySelector('h1.video-title') || document.querySelector('h1');
      const text = h1 ? h1.textContent.trim() : '';
      return text || document.title.replace(/_哔哩哔哩.*$/, '').trim();
    },

    videoMeta() {
      const info = controller.sessionKeyFor(controller.video);
      const state = window.__INITIAL_STATE__;
      let author = '';
      try {
        author = (state && state.videoData && (state.videoData.owner && state.videoData.owner.name)) || '';
      } catch {
        author = '';
      }
      return {
        url: location.href,
        title: controller.videoTitle(),
        author,
        bvid: info.bvid,
        cid: info.cid,
        page: info.page,
        duration: info.duration
      };
    },

    /** 视频变化时确保后台存在对应会话，并重置检测状态 */
    async syncSession() {
      const info = controller.sessionKeyFor(controller.video);
      const changed = info.id !== controller.sessionKey;
      controller.sessionKey = info.id;
      // 会话世代号：切视频瞬间还在途中的抓帧结果一律丢弃，避免写进新会话
      controller.epoch = (controller.epoch || 0) + 1;
      // 新视频 = 新会话：采样统计与去重表都归零
      controller.sampleCount = 0;
      controller.skipCount = 0;
      controller.savedHashes = new Set();
      controller.lastSampleHash = '';
      controller.lastVideoTime = 0;
      controller.pass = 1;
      controller.lastDecision = null;
      if (changed) {
        // 换视频了一定要把取帧源作废，否则会继续用上一个视频的流（严重 bug）
        controller.lastAccepted = null;
        if (NS.framesource) NS.framesource.invalidate();
        controller.status = '检测到切换视频，正在重建取帧源…';
        NS.panel.renderStats();
      }
      try {
        const session = await core.send({
          type: 'db.ensureSession',
          sessionKey: info.id,
          video: controller.videoMeta()
        });
        controller.session = session;
        controller.savedCount = session.frameCount || 0;
        controller.totalCount = session.frameCount || 0;
        controller.lastAccepted = null; // 已有会话不重复回扫，重置比较基准
        controller.status = `会话就绪（${session.frameCount || 0} 帧）`;
      } catch (error) {
        controller.status = `会话创建失败：${error.message}`;
      }
      NS.panel.renderStats();
    },

    async refreshCounts() {
      if (!controller.sessionKey) return;
      try {
        const stats = await core.send({ type: 'db.sessionStats', sessionKey: controller.sessionKey });
        controller.savedCount = stats.frameCount || 0;
        controller.totalCount = controller.savedCount;
        controller.session = Object.assign({}, controller.session, stats);
      } catch {
        /* 忽略统计失败 */
      }
      NS.panel.renderStats();
    },

    /* ---------------- 自动抓帧 ---------------- */

    setRunning(running) {
      const next = !!running && !!(controller.settings && controller.settings.mode !== 'off');
      if (next === controller.running) return;
      controller.running = next;
      if (next) {
        controller.status = controller.settings.mode === 'every'
          ? `逐帧抓取中（每 ${controller.settings.intervalMs}ms 一张）`
          : (controller.settings.mode === 'interval' ? '定间隔抓取中' : '关键帧监听中');
        // 只在「从停止变为运行」时重新拉起帧回调链，避免多次注册造成重复采样
        controller.scheduleNext();
      } else {
        controller.loopActive = false;
        controller.status = '已暂停';
      }
      NS.panel.renderStats();
    },

    /**
     * 确保「运行状态」和「帧回调链」是一致的。
     * bindVideo 这类地方会先把 running 置位，之后 setRunning(true) 会被守卫直接返回、
     * 于是回调链永远拉不起来 —— 表现就是按钮点几次才生效。这里做兜底。
     */
    ensureLoop() {
      if (!controller.running) return false;
      if (controller.loopActive) return false;
      controller.loopActive = true;
      controller.scheduleNext();
      return true;
    },

    /**
     * 开始 / 暂停自动抓取。
     * 关键点：
     *   1. 暂停必须**写进设置**（mode = off），否则下次进页面又会按 mode 自动开跑；
     *   2. 判断条件是「当前是否在运行」，**不能**把 mode === 'off' 也算进暂停分支 ——
     *      默认模式就是 off，那样点「开始」会走进暂停分支，表现为按钮完全没反应。
     */
    async toggleAuto() {
      const settings = controller.settings || {};
      const remembered = settings.lastActiveMode && settings.lastActiveMode !== 'off'
        ? settings.lastActiveMode
        : (settings.mode && settings.mode !== 'off' ? settings.mode : 'auto');

      if (controller.running) {
        // 暂停：记住当前模式，切到「仅手动」
        controller.settings = await core.saveSettings({ mode: 'off', lastActiveMode: remembered });
        controller.setRunning(false);
        controller.status = `已暂停（记住「${MODE_LABELS[remembered] || remembered}」，下次点开始恢复）`;
        NS.panel.renderStats();
        return false;
      }

      // 开始：恢复到上次用的模式（默认「自动·关键帧」）
      controller.settings = await core.saveSettings({ mode: remembered });
      controller.setRunning(true);
      controller.status = `已开始（${MODE_LABELS[remembered] || remembered}）`;
      NS.panel.renderStats();
      return true;
    },

    async setMode(mode) {
      const patch = { mode };
      if (mode !== 'off') patch.lastActiveMode = mode;
      controller.settings = await core.saveSettings(patch);
      if (mode === 'off') controller.setRunning(false);
      else controller.setRunning(true);
      NS.panel.renderStats();
      return mode;
    },

    scheduleNext() {
      const video = controller.video;
      if (!video) return;
      controller.loopActive = true;
      if (typeof video.requestVideoFrameCallback === 'function') {
        video.requestVideoFrameCallback(() => controller.tick());
      } else {
        setTimeout(() => controller.tick(), 120);
      }
    },
    /** 每一帧回调都触发；由采样间隔与运行状态决定是否真正判定 */
    tick() {
      if (!controller.running) return;
      const video = controller.video;
      if (!video || !video.isConnected) {
        controller.setRunning(false);
        return;
      }
      const settings = controller.settings;
      const now = performance.now();
      const active = !video.paused && !video.ended && video.readyState >= 2;
      // 采样间隔按毫秒计（默认 100ms，下限 100ms）
      const cooled = now - controller.lastSampleAt >= settings.intervalMs;
      // 视频循环回到开头时，把判定基准清掉，让新一遍重新开始判定
      // （否则第一帧会因为「和上一遍结尾差异过大」而误判，反而丢掉一遍开头）
      if (active && core.isVideoLooped(controller.lastVideoTime, video.currentTime)) {
        controller.pass += 1;
        controller.lastAccepted = null;
        controller.lastSampleHash = '';
        controller.lastDecision = { reason: `检测到重播，进入第 ${controller.pass} 遍`, change: 0 };
      }
      if (active) controller.lastVideoTime = video.currentTime;
      const blocked = controller.busy || controller.autoPaused || NS.gallery.open_;
      if (active && cooled && !blocked) {
        controller.lastSampleAt = now;
        controller.processFrame(video).catch(() => {
          /* processFrame 内部已记录错误 */
        });
      }
      controller.scheduleNext();
    },

    /** 采样 -> 判定 -> 保存 */
    async processFrame(video) {
      if (controller.busy || !controller.video) return;
      controller.busy = true;
      NS.panel.renderStats();
      // 首次取帧要准备隐藏视频（可能要先下载），把进度显示出来
      NS.framesource.onProgress = (progress) => {
        if (!progress) return;
        controller.status = `准备取帧：${progress.text || ''}`;
        NS.panel.renderStats();
      };
      try {
        const settings = controller.settings;
        const time = video.currentTime;
        if (!(time > 0)) return;
        const signature = NS.detector.sample(video, NS.detectorCanvas);
        controller.sampleCount += 1;
        const epoch = controller.epoch;

        // 逐帧/定间隔模式是「无条件保存」，但连续两次采样落到同一帧时没必要存两份
        if (controller.lastSampleHash === signature.hash) {
          controller.skipCount += 1;
          controller.lastDecision = { reason: '与上一张相同', change: 0 };
          return;
        }
        controller.lastSampleHash = signature.hash;

        // 定间隔 / 逐帧模式无条件保存；关键帧模式做场景切换判定
        const forceAll = settings.mode === 'interval' || settings.mode === 'every';
        const decision = forceAll
          ? { accept: true, reason: settings.mode === 'every' ? '逐帧采样' : '定间隔', hashDistance: 1, mad: 1, change: 1 }
          : NS.detector.evaluate(controller.lastAccepted, signature, settings);

        if (!decision.accept) {
          controller.skipCount += 1;
          controller.lastError = '';
          controller.lastDecision = { reason: decision.reason, change: decision.change };
          controller.status = `跳过：${decision.reason}（Δ${(decision.change * 100).toFixed(1)}%）`;
          return;
        }
        if (signature.brightness <= 4) {
          controller.skipCount += 1;
          controller.lastDecision = { reason: '画面为黑场', change: 0 };
          controller.status = '跳过：画面为黑场';
          return;
        }

        const frame = await NS.capture.captureFrame(video, {
          time,
          signature,
          stats: null,
          detection: {
            hashDistance: decision.hashDistance,
            mad: decision.mad,
            change: decision.change,
            reason: decision.reason
          },
          settings,
          sessionKey: controller.sessionKey,
          videoMeta: controller.videoMeta(),
          pass: controller.pass
        });

        if (frame.skipped) {
          controller.skipCount += 1;
          controller.lastDecision = { reason: frame.reason, change: 0 };
          controller.status = `跳过：${frame.reason}`;
          controller.lastAccepted = signature; // 别对同一纯色画面反复判定
          return;
        }

        const saved = await core.send({ type: 'db.addFrame', frame });
        // 抓这一帧的过程中如果切了视频，结果已经不属于当前会话，直接丢弃
        if (epoch !== controller.epoch) {
          controller.status = '已切换视频，丢弃上一段的抓帧结果';
          return;
        }
        if (!saved || !saved.stored) {
          controller.skipCount += 1;
          controller.status = saved && saved.duplicate
            ? '跳过：同一画面已经存过了'
            : `未保存：${(saved && saved.reason) || '后台拒绝'}`;
          return;
        }

        controller.lastAccepted = signature;
        controller.lastFrameAt = performance.now();
        controller.lastTime = frame.time;
        controller.lastError = '';
        controller.lastDecision = { reason: decision.reason, change: decision.change };
        controller.savedHashes.add(signature.hash);
        controller.savedCount = saved.frameCount || controller.savedCount + 1;
        controller.totalCount = controller.savedCount;
        controller.status = `已保存 ${core.timeText(frame.time, true)}（Δ${(decision.change * 100).toFixed(1)}%）`;

        if (saved.almostFull) {
          controller.status = `已保存 ${saved.frameCount} 帧，接近上限 ${settings.maxFramesPerSession}`;
        }
        if (saved.reachedLimit && settings.autoExport !== 'none') {
          await controller.autoExport(saved);
        }
      } catch (error) {
        // 失败时先想办法拿到「播放器真实请求的 CDN 地址」再重试一次
        if (error && error.retriable) {
          try {
            const retried = await controller.retryWithObservedAddress();
            if (retried && retried.stored) {
              controller.lastAccepted = retried.signature;
              controller.lastTime = retried.frame.time;
              controller.lastFrameAt = performance.now();
              await controller.refreshCounts();
              controller.lastError = '';
              controller.status =
                `已保存 ${core.timeText(retried.frame.time, true)}（改用播放器请求的地址）`;
              return;
            }
          } catch (retryError) {
            error = retryError;
            controller.lastError = error.message;
            controller.status = `抓帧失败：${String(error.message).split('\n')[0]}`;
            NS.panel.setError(error.message);
            return;
          }
        }
        controller.lastError = error.message;
        controller.status = `抓帧失败：${String(error.message).split('\n')[0]}`;
        NS.panel.setError(error.message);
      } finally {
        controller.busy = false;
        NS.panel.renderStats();
      }
    },

    /**
     * 「再抓一遍」：回到片头重新播，把这一遍的采样点叠加到已有结果上。
     *
     * 为什么有用：采样是异步的，某次编码写入超过采样间隔时那一段的采样点会被跳过，
     * 而且这些空洞在每次播放里位置固定 —— 所以这里会重置判定基准并累加遍数，
     * 让新一遍从不同相位覆盖上一遍漏掉的画面，而完全相同的画面依旧不会重复保存。
     */
    async replayForMore() {
      if (!controller.hasVideo()) throw new Error('当前页面没有可用的视频，请先播放');
      const video = controller.video;
      controller.pass += 1;
      controller.lastAccepted = null;   // 新一遍从头判定
      controller.lastSampleHash = '';
      controller.lastVideoTime = 0;
      controller.lastSampleAt = 0;
      controller.lastDecision = { reason: `第 ${controller.pass} 遍开始`, change: 0 };
      try {
        video.pause();
        video.currentTime = 0;
        await core.sleep(120);
        await video.play();
      } catch (error) {
        throw new Error(`无法重新播放：${error.message}（请手动点击播放器的重播按钮）`);
      }
      if (!controller.running) controller.setRunning(true);
      controller.status = `第 ${controller.pass} 遍抓取中（继续补齐上一遍漏掉的画面）`;
      NS.panel.renderStats();
      return { pass: controller.pass, saved: controller.savedCount };
    },

    /**
     * 失败重试：改用「播放器实际请求的 CDN 地址」重新取一帧并入库。
     * 供实时监听与手动抓取共用。
     * @returns {Promise<{stored:boolean, frame:object, signature:object}|null>}
     */
    async retryWithObservedAddress() {
      const extra = await controller.collectExtraCandidates();
      if (!extra.length) return null;
      controller.status = `发现 ${extra.length} 个播放器请求的地址，改用它们重试…`;
      NS.panel.renderStats();

      const video = controller.video;
      const signature = NS.detector.sample(video, NS.detectorCanvas);
      const frame = await NS.capture.captureFrame(video, {
        time: video.currentTime,
        signature,
        stats: null,
        detection: { hashDistance: 0, mad: 0, change: 1, reason: '改用网络地址重试' },
        settings: controller.settings,
        sessionKey: controller.sessionKey,
        videoMeta: controller.videoMeta(),
        extra
      });
      if (!frame || frame.skipped) return null;
      const saved = await core.send({ type: 'db.addFrame', frame });
      if (!saved || !saved.stored) return null;
      return { stored: true, frame, signature };
    },

    /**
     * 主动切换取帧源：找一遍「播放器真实请求的 CDN 地址」，成功就直接切过去。
     * 供面板的「诊断」旁路和弹窗按钮调用，也是 blob: 视频的唯一出路。
     */
    async switchToObservedSource() {
      if (!controller.hasVideo()) throw new Error('当前页面没有可用的视频，请先播放');
      controller.status = '正在寻找播放器实际使用的视频地址…';
      NS.panel.renderStats();
      const extra = await controller.collectExtraCandidates(8000);
      if (!extra.length) {
        throw new Error(
          '还没观察到视频请求。请先点一下页面里的播放（让播放器开始下载视频），再点「重新获取视频地址」。'
        );
      }
      controller.status = `找到 ${extra.length} 个地址，正在切换取帧源…`;
      NS.panel.renderStats();
      const element = await NS.framesource.ensure(controller.video, { extra });
      controller.status = `取帧源已就绪（${NS.framesource.mode}），来源：${NS.framesource.sourceName || '未知'}`;
      NS.panel.renderStats();
      return {
        ok: true,
        mode: NS.framesource.mode,
        source: NS.framesource.sourceName,
        candidates: extra.length,
        readyState: element.readyState
      };
    },

    /**
     * 想办法拿到「播放器真正在请求的媒体地址」：
     *   1. 页面主世界里再找一遍播放信息（有时隔离世界里看不到）
     *   2. 后台 webRequest 观察到的 CDN 请求
     * @param {number} waitMs 找到之前最多等多久（播放器边播边请求，等一会儿往往就出现了）
     */
    async collectExtraCandidates(waitMs) {
      const extra = [];
      const seen = new Set();
      const add = (url, from) => {
        if (!url || seen.has(url)) return;
        seen.add(url);
        extra.push({ url, from });
      };
      const deadline = Date.now() + (waitMs || 0);

      for (;;) {
        // 1) 主世界注入，读取 __playinfo__ / 播放器实例上的地址
        try {
          const injected = await core.send({ type: 'page.playinfo' });
          for (const url of (injected && injected.urls) || []) add(url, 'page.global');
        } catch (error) {
          console.debug('[关键帧抓取] 主世界取地址失败', error.message);
        }

        // 2) 后台观察到的 CDN 请求
        try {
          const observed = await core.send({ type: 'media.list', limit: 10 });
          for (const item of (observed && observed.urls) || []) {
            add(item.url, `network.${item.kind || 'media'}`);
          }
        } catch (error) {
          console.debug('[关键帧抓取] 读取网络观察结果失败', error.message);
        }

        if (extra.length || Date.now() >= deadline) {
          // 记住这些地址：之后即便又换回失败元素，也能直接复用它们
          if (extra.length && NS.framesource) NS.framesource.addObserved(extra);
          return extra;
        }
        controller.status = '等待播放器请求视频…（可点一下播放）';
        NS.panel.renderStats();
        await core.sleep(500);
      }
    },

    /** 抓满上限后的自动导出 */
    async autoExport(saved) {
      if (controller.autoExporting) return;
      controller.autoExporting = true;
      controller.status = '正在自动导出…';
      NS.panel.renderStats();
      try {
        const ids = saved.frameIds || [];
        if (controller.settings.autoExport === 'folder' && window.showDirectoryPicker) {
          NS.gallery.init(controller);
          NS.gallery.sessionId = saved.sessionId || controller.sessionKey;
          await NS.gallery.exportToFolderByIds(ids);
          controller.status = `已自动导出 ${ids.length} 帧到文件夹`;
        } else {
          const result = await core.send({
            type: 'export.zip',
            frameIds: ids,
            name: controller.videoTitle()
          });
          controller.status = result.cancelled ? '已取消自动导出' : `已自动导出 ${result.count} 帧`;
        }
        // 导出后重置检测基准，避免继续堆积
        controller.lastAccepted = null;
        await controller.refreshCounts();
      } catch (error) {
        controller.status = `自动导出失败：${error.message}`;
      } finally {
        controller.autoExporting = false;
        NS.panel.renderStats();
      }
    },

    /** 手动抓取当前画面 */
    async captureNow(source) {
      if (!controller.hasVideo()) throw new Error('当前页面没有可用的视频');
      if (controller.busy) return { ok: false, reason: '上一帧仍在抓取中' };
      const before = controller.savedCount;
      controller.busy = true;
      NS.panel.renderStats();
      try {
        const video = controller.video;
        const time = video.currentTime;
        const signature = NS.detector.sample(video, NS.detectorCanvas);
        const frame = await NS.capture.captureFrame(video, {
          time,
          signature,
          stats: null,
          detection: { hashDistance: 0, mad: 0, change: 1, reason: source === 'manual' ? '手动抓取' : '外部触发' },
          settings: controller.settings,
          sessionKey: controller.sessionKey,
          videoMeta: controller.videoMeta()
        });
        if (!frame.skipped) {
          if (!controller.sessionKey) await controller.syncSession();
          const saved = await core.send({ type: 'db.addFrame', frame });
          if (saved && saved.stored) {
            controller.lastAccepted = signature;
            controller.lastTime = frame.time;
            controller.savedCount = saved.frameCount || before + 1;
            controller.totalCount = controller.savedCount;
            controller.status = `手动保存 ${core.timeText(frame.time, true)}`;
            return { ok: true, time: frame.time, frameCount: controller.savedCount };
          }
          return { ok: false, reason: (saved && saved.reason) || '后台未保存' };
        }
        controller.status = `跳过：${frame.reason}`;
        return { ok: false, reason: frame.reason };
      } catch (error) {
        // 同样先试试「播放器实际请求的地址」，能救回来就不用让用户手动重试
        if (error && error.retriable) {
          try {
            const retried = await controller.retryWithObservedAddress();
            if (retried && retried.stored) {
              controller.lastAccepted = retried.signature;
              controller.lastTime = retried.frame.time;
              await controller.refreshCounts();
              controller.lastError = '';
              controller.status =
                `手动保存 ${core.timeText(retried.frame.time, true)}（改用播放器请求的地址）`;
              return {
                ok: true,
                time: retried.frame.time,
                frameCount: controller.savedCount
              };
            }
          } catch (retryError) {
            error = retryError;
          }
        }
        controller.lastError = error.message;
        controller.status = `抓帧失败：${String(error.message).split('\n')[0]}`;
        NS.panel.setError(error.message);
        return { ok: false, reason: error.message };
      } finally {
        controller.busy = false;
        NS.panel.renderStats();
      }
    },

    /* ---------------- 播放并抓帧（离线扫描） ---------------- */

    /**
     * 让隐藏视频按倍速播放整段视频，按间隔采样并保存关键帧。
     * @returns {Promise<object>} 扫描结果摘要
     */
    async startScan() {
      if (controller.scanning) throw new Error('已经在扫描中');
      if (!controller.hasVideo()) throw new Error('当前页面没有可用的视频');
      if (NS.gallery.open_) NS.gallery.close();
      if (!controller.sessionKey || !controller.session) await controller.syncSession();
      if (!controller.sessionKey) throw new Error('会话创建失败，无法扫描');

      controller.scanning = true;
      controller.setRunning(false);      // 扫描期间停掉实时自动抓帧，避免互相争抢 reader
      NS.panel.renderStats();

      const settings = controller.settings;
      const sessionKey = controller.sessionKey;
      const videoMeta = controller.videoMeta();
      const session = controller.session || {};
      const used = session.frameCount || 0;
      const maxFrames = Math.max(1, (settings.maxFramesPerSession || 300) - used);
      controller.status = '开始播放并抓帧…';

      // 长时间扫描时保活后台 Service Worker（MV3 空闲 30 秒会被回收）
      const keepAlive = setInterval(() => {
        chrome.runtime.sendMessage({ type: 'ping' }).catch(() => {});
      }, 15000);

      try {
        const result = await NS.scanner.start({
          video: controller.video,
          settings,
          sessionKey,
          videoMeta,
          maxFrames,
          onProgress: (progress) => {
            controller.scanProgress = progress;
            NS.panel.updateScanProgress(progress);
            controller.status = progress.scanMessage || controller.status;
            // 节流转发给后台广播，让图库 / 弹窗也能看到进度
            const now = Date.now();
            if (now - controller.lastScanBroadcastAt > 900) {
              controller.lastScanBroadcastAt = now;
              core.send({ type: 'scan.progress', scan: progress, sessionId: sessionKey }).catch(() => {});
            }
          },
          onFrame: async (payload) => {
            const saved = await core.send({ type: 'db.addFrame', frame: payload });
            if (saved && saved.stored) {
              controller.savedCount = saved.frameCount || controller.savedCount + 1;
              controller.totalCount = controller.savedCount;
              controller.lastTime = payload.time;
            }
            return saved;
          }
        });

        controller.lastAccepted = null;
        controller.status = `扫描完成：新增 ${result.saved} 帧（${result.reason}）`;
        controller.scanProgress = null;
        await controller.refreshCounts();

        if (settings.scanOpenGallery && result.saved > 0) NS.gallery.open(sessionKey);
        return result;
      } catch (error) {
        controller.status = `扫描失败：${String(error.message).split('\n')[0]}`;
        controller.lastError = error.message;
        controller.scanProgress = null;
        NS.panel.setError(error.message);
        throw error;
      } finally {
        clearInterval(keepAlive);
        controller.scanning = false;
        NS.panel.updateScanProgress(null);
        controller.setRunning(settings.mode !== 'off');
        NS.panel.renderStats();
      }
    },

    stopScan() {
      return NS.scanner.cancel();
    },

    /* ---------------- 视频控制 ---------------- */

    hasVideo() {
      return !!(controller.video && controller.video.isConnected && controller.video.readyState >= 1);
    },

    seekVideo(time) {
      const video = controller.video;
      if (!video) return;
      video.currentTime = Math.max(0, time);
      if (video.paused) video.play().catch(() => {});
      NS.gallery.close();
    },

    pauseVideo(paused) {
      const video = controller.video;
      if (!video) return;
      if (paused) {
        controller.autoPaused = true;
        if (!video.paused) {
          controller.resumeAfterGallery = true;
          video.pause();
        }
      } else if (controller.autoPaused) {
        controller.autoPaused = false;
        if (controller.resumeAfterGallery) {
          controller.resumeAfterGallery = false;
          video.play().catch(() => {});
        }
      }
    },

    setPanelVisible(visible) {
      NS.panel.setVisible(visible);
      // 同步内存副本 + 落盘，避免「只改了显示没改配置」
      if (controller.settings && controller.settings.showPanel !== !!visible) {
        controller.settings.showPanel = !!visible;
        core.saveSettings({ showPanel: !!visible });
      }
    },

    getStats() {
      const scan = NS.scanner ? NS.scanner.progress : null;
      const sampled = controller.sampleCount || 0;
      return {
        running: controller.running,
        mode: controller.settings ? controller.settings.mode : 'auto',
        intervalMs: controller.settings ? controller.settings.intervalMs : 100,
        busy: controller.busy,
        hasVideo: controller.hasVideo(),
        saved: controller.savedCount,
        total: controller.totalCount,
        sampled,
        skipped: controller.skipCount || 0,
        pass: controller.pass || 1,
        // 采样命中率：让「采了 50 次为什么只存 6 张」这类疑问有据可查
        hitRate: sampled ? Math.round(((sampled - (controller.skipCount || 0)) / sampled) * 100) : 0,
        lastDecision: controller.lastDecision,
        lastTime: controller.lastTime,
        status: controller.status,
        error: controller.lastError,
        sessionKey: controller.sessionKey,
        title: controller.sessionKey ? controller.videoTitle() : '',
        scanning: !!controller.scanning,
        scan: scan && scan.scanning ? scan : null
      };
    }
  };

  NS.controller = controller;

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => controller.start());
  } else {
    controller.start();
  }
})();

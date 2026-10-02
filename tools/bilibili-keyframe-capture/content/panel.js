/**
 * panel.js —— 页面左侧的垂直悬浮控制面板（Shadow DOM 隔离样式）
 *
 * 设计要点：
 *   - 用 fixed 定位固定在视口左侧空白处，垂直排列，不占用播放器布局，
 *     因此不会被 B 站下方的「笔记 / 视频详情」等浮动组件遮挡；
 *   - 可按住顶部把手拖到任意位置，位置与展开状态都会记住；
 *   - 收起后变成一条细竖条，只剩状态灯和帧数，随时点开。
 */
(function () {
  'use strict';

  const NS = (window.__BKF__ = window.__BKF__ || {});
  const core = NS.core;

  const PANEL_CSS = `
    :host { all: initial; }
    * { box-sizing: border-box; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif; }
    .panel {
      display: flex; flex-direction: column; gap: 8px; padding: 10px 10px 11px;
      width: 226px; max-width: calc(100vw - 8px); box-sizing: border-box;
      border-radius: 14px; color: #e9eef5;
      background: linear-gradient(180deg, #23272f 0%, #191c22 100%);
      border: 1px solid #363d47; box-shadow: 0 10px 30px rgba(0,0,0,.55);
      font-size: 12.5px; user-select: none;
    }
    .panel.collapsed { width: 46px; padding: 9px 6px 10px; gap: 7px; align-items: center; }
    .panel.dragging { cursor: grabbing; opacity: .94; }
    /* 行内容自适应：允许收缩并省略，避免右侧留出一大块空白或把面板撑破 */
    .panel > * { min-width: 0; max-width: 100%; }

    /* 顶部把手：按住拖动 */
    .head { display: flex; align-items: center; gap: 7px; cursor: grab; }
    .collapsed .head { flex-direction: column; gap: 6px; }
    .grip { display: flex; flex-direction: column; gap: 2px; opacity: .45; }
    .grip i { display: block; width: 3px; height: 3px; border-radius: 50%; background: #cfd6e0; }
    .head .name { font-weight: 600; color: #fff; flex: 1 1 auto; white-space: nowrap; }
    .collapse { border: 0; background: transparent; color: #9aa4b2; cursor: pointer;
                font-size: 14px; line-height: 1; padding: 2px 4px; border-radius: 6px; }
    .collapse:hover { color: #fff; background: #2f3640; }
    .collapsed .collapse { font-size: 13px; }

    .dot { width: 8px; height: 8px; border-radius: 50%; background: #6b7280; flex: 0 0 auto; }
    .dot.on { background: #fb7299; box-shadow: 0 0 8px rgba(251,114,153,.9); animation: bkf-pulse 1.6s infinite; }
    @keyframes bkf-pulse { 0%,100% { opacity: 1; } 50% { opacity: .4; } }

    .status { display: flex; align-items: center; gap: 6px; color: #c3cbd7; font-size: 12px; min-width: 0; }
    .status .txt { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; flex: 1 1 auto; }
    .collapsed .status { flex-direction: column; }

    .metric { display: flex; align-items: baseline; gap: 6px; color: #8b95a3; font-size: 11.5px;
              min-width: 0; }
    .metric b { color: #fff; font-size: 17px; font-weight: 700; letter-spacing: .02em; }
    .metric .unit { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; }
    .metric.time .at { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; }
    .collapsed .metric { flex-direction: column; align-items: center; gap: 1px; }
    .collapsed .metric b { font-size: 13px; }
    .collapsed .metric .unit { font-size: 10px; }

    .buttons { display: flex; flex-direction: column; gap: 7px; }
    .collapsed .buttons { gap: 6px; align-items: center; }
    .collapsed .label { display: none; }
    /* 按钮铺满整行，文字过长时省略而不是把面板撑开 */
    .buttons button { width: 100%; }

    button { appearance: none; border: 1px solid #454c56; background: #2c313a; color: #e9eef5;
             border-radius: 9px; padding: 7px 10px; font-size: 12.5px; cursor: pointer;
             transition: background .15s, border-color .15s; text-align: left; line-height: 1.2;
             white-space: nowrap; word-break: keep-all; }
    button:hover { background: #383e46; border-color: #5a626d; }
    button.primary { background: #fb7299; border-color: #fb7299; color: #fff; font-weight: 600; }
    button.primary:hover { background: #ff85a8; }
    button.ghost { background: transparent; }
    button:disabled { opacity: .5; cursor: not-allowed; }
    .collapsed button { text-align: center; padding: 7px 0; width: 100%; font-size: 14px; }

    select { appearance: none; border: 1px solid #454c56; background: #2c313a; color: #e9eef5;
             border-radius: 8px; padding: 6px 8px; font-size: 12px; cursor: pointer; width: 100%; }
    .collapsed select { display: none; }

    .msg { font-size: 11px; color: #8b95a3; line-height: 1.55; word-break: break-word; }
    .msg.err { color: #ffb3c8; }
    .collapsed .msg { display: none; }

    /* 详细诊断（可展开 / 复制） */
    .errbox { display: none; flex-direction: column; gap: 6px; }
    .errbox.on { display: flex; }
    .collapsed .errbox { display: none; }
    .errbox pre { margin: 0; max-height: 190px; overflow: auto; white-space: pre-wrap; word-break: break-word;
                  font-size: 11px; line-height: 1.6; color: #ffd7e3; background: #1b1418;
                  border: 1px solid #5c2b39; border-radius: 8px; padding: 7px 8px; }
    .errbox .acts { display: flex; gap: 6px; }
    .errbox .acts button { flex: 1 1 0; text-align: center; padding: 5px 0; font-size: 11.5px; }
    .copyhint { font-size: 10.5px; color: #9aa4b2; }

    /* 扫描进度 */
    .progress { display: none; flex-direction: column; gap: 5px; }
    .progress.on { display: flex; }
    .collapsed .progress { display: none; }
    .progress .line { display: flex; align-items: baseline; justify-content: space-between;
                      font-size: 11px; color: #b9c2cf; }
    .progress .pct { font-weight: 700; color: #fff; }
    .bar { height: 6px; border-radius: 999px; background: #2c323b; overflow: hidden; }
    .bar i { display: block; height: 100%; width: 0%; border-radius: 999px;
             background: linear-gradient(90deg, #fb7299, #ff9db8); transition: width .3s ease; }
    .progress .eta { font-size: 10.5px; color: #8b95a3; }

    .foot { display: flex; align-items: center; gap: 6px; border-top: 1px solid #2c323b; padding-top: 7px; }
    .collapsed .foot { flex-direction: column; border-top: 0; padding-top: 0; gap: 6px; }
    .foot .fs { flex: 1 1 auto; }
    @media (max-height: 620px) { .foot { display: none; } }
  `;

  const panel = {
    host: null,
    root: null,
    els: {},
    controller: null,
    timer: null,
    collapsed: false,
    drag: null,

    init(controller) {
      panel.controller = controller;
      if (panel.host) return;
      const host = core.ensureHost('__bkf_panel_host');
      panel.host = host;
      panel.root = host.attachShadow({ mode: 'open' });

      const style = document.createElement('style');
      style.textContent = PANEL_CSS;

      const wrap = document.createElement('div');
      wrap.className = 'panel';
      wrap.innerHTML = `
        <div class="head" title="按住可拖动面板">
          <span class="grip"><i></i><i></i><i></i></span>
          <span class="name">关键帧抓取</span>
          <button class="collapse" title="收起 / 展开">‹</button>
        </div>
        <div class="status">
          <span class="dot"></span>
          <span class="txt state">未开始</span>
        </div>
        <div class="metric">
          <b class="count">0</b>
          <span class="unit">帧已保存</span>
        </div>
        <div class="metric time">
          <span class="at">--:--</span>
        </div>
        <div class="buttons">
          <button class="replay" title="回到片头再抓一遍：补齐上一遍漏掉的采样点（相同画面不会重复保存）">🔁 <span class="label">再抓一遍</span></button>
          <button class="scan" title="从头到尾自动播放并抓取关键帧">🎬 <span class="label">播放并抓帧</span></button>
          <button class="snap primary" title="立即抓取当前画面（Alt+K）">📸 <span class="label">抓取当前帧</span></button>
          <button class="toggle" title="开始 / 暂停实时自动抓取">▶ <span class="label">开始自动抓取</span></button>
          <button class="gallery ghost" title="打开关键帧图库">🗂 <span class="label">图库</span></button>
        </div>
        <div class="progress">
          <div class="line"><span class="ptext">准备中…</span><span class="pct">0%</span></div>
          <div class="bar"><i></i></div>
          <div class="eta"></div>
        </div>
        <select class="mode" title="抓取模式">
          <option value="off">仅手动（默认 · 进页面不自动抓）</option>
          <option value="auto">自动 · 关键帧（只存画面变化）</option>
          <option value="every">逐帧抓取（按间隔全部存）</option>
          <option value="interval">定间隔抓取（全部存，间隔较大）</option>
        </select>
        <div class="msg"></div>
        <div class="errbox">
          <pre class="errdetail"></pre>
          <div class="acts">
            <button class="copy ghost" title="复制诊断信息，便于反馈问题">复制诊断</button>
            <button class="diagclose ghost">收起</button>
          </div>
          <div class="acts">
            <button class="refetch" title="查看播放器实际请求的视频地址，并切换到它">重新获取视频地址</button>
          </div>
          <div class="copyhint"></div>
        </div>
        <div class="foot">
          <button class="hide ghost fs" title="隐藏面板（可在扩展弹窗重新显示）">隐藏</button>
          <button class="diagnose ghost" title="查看取帧诊断详情">诊断</button>
        </div>
      `;

      panel.root.append(style, wrap);
      panel.els = {
        wrap,
        head: wrap.querySelector('.head'),
        name: wrap.querySelector('.name'),
        collapse: wrap.querySelector('.collapse'),
        dot: wrap.querySelector('.dot'),
        state: wrap.querySelector('.state'),
        count: wrap.querySelector('.count'),
        unit: wrap.querySelector('.unit'),
        at: wrap.querySelector('.at'),
        time: wrap.querySelector('.time'),
        mode: wrap.querySelector('.mode'),
        progress: wrap.querySelector('.progress'),
        progressText: wrap.querySelector('.progress .ptext'),
        progressPct: wrap.querySelector('.progress .pct'),
        progressBar: wrap.querySelector('.progress .bar i'),
        progressEta: wrap.querySelector('.progress .eta'),
        scan: wrap.querySelector('.scan'),
        scanLabel: wrap.querySelector('.scan .label'),
        replay: wrap.querySelector('.replay'),
        snap: wrap.querySelector('.snap'),
        snapLabel: wrap.querySelector('.snap .label'),
        toggle: wrap.querySelector('.toggle'),
        toggleLabel: wrap.querySelector('.toggle .label'),
        gallery: wrap.querySelector('.gallery'),
        hide: wrap.querySelector('.hide'),
        msg: wrap.querySelector('.msg'),
        errbox: wrap.querySelector('.errbox'),
        errdetail: wrap.querySelector('.errdetail'),
        copy: wrap.querySelector('.copy'),
        diagclose: wrap.querySelector('.diagclose'),
        refetch: wrap.querySelector('.refetch'),
        copyhint: wrap.querySelector('.copyhint'),
        diagnose: wrap.querySelector('.diagnose')
      };

      panel.els.wrap.addEventListener('click', (event) => {
        panel.reportClickError(event);
      }, true);
      panel.els.snap.addEventListener('click', () => controller.captureNow('manual'));
      panel.els.replay.addEventListener('click', async () => {
        panel.els.replay.disabled = true;
        try {
          await controller.replayForMore();
        } catch (error) {
          panel.setMessage(error.message, true);
        } finally {
          panel.els.replay.disabled = false;
        }
      });
      panel.els.scan.addEventListener('click', () => {
        if (controller.getStats().scanning) {
          controller.stopScan();
          return;
        }
        controller.startScan().catch((error) => {
          panel.setMessage(`扫描未开始：${error.message}`, true);
        });
      });
      panel.els.toggle.addEventListener('click', () => controller.toggleAuto());
      panel.els.gallery.addEventListener('click', () => NS.gallery && NS.gallery.open());
      panel.els.mode.addEventListener('change', () => controller.setMode(panel.els.mode.value));
      panel.els.hide.addEventListener('click', () => controller.setPanelVisible(false));
      panel.els.diagnose.addEventListener('click', () => panel.toggleDiagnostics());
      panel.els.diagclose.addEventListener('click', () => panel.showDiagnostics(false));
      panel.els.copy.addEventListener('click', () => panel.copyDiagnostics());
      panel.els.refetch.addEventListener('click', async () => {
        panel.els.refetch.disabled = true;
        panel.els.refetch.textContent = '正在查找…';
        try {
          const result = await controller.switchToObservedSource();
          panel.setMessage(`已切换取帧源：${result.source}（${result.mode}）`, false);
          panel.showDiagnostics(false);
        } catch (error) {
          panel.setMessage(`未找到可用地址：${error.message}`, true);
        } finally {
          panel.els.refetch.disabled = false;
          panel.els.refetch.textContent = '重新获取视频地址';
        }
      });
      panel.els.collapse.addEventListener('click', (event) => {
        event.stopPropagation();
        panel.setCollapsed(!panel.collapsed);
      });
      panel.bindDrag();

      panel.applyCollapsed(panel.collapsed);
      panel.applyPosition();
      panel.timer = setInterval(() => panel.renderStats(), 700);
      panel.renderStats();
      window.addEventListener('resize', () => panel.applyPosition());
    },

    /* ---------------- 位置与收起 ---------------- */

    /** 把保存的位置应用到 fixed 定位，并夹在视口内 */
    applyPosition(pos) {
      if (!panel.host) return;
      const settings = (panel.controller && panel.controller.settings) || {};
      const saved = pos || { left: settings.panelLeft, top: settings.panelTop };
      const width = panel.collapsed ? 46 : 226;
      const height = Math.min(360, Math.max(180, window.innerHeight - 40));
      const left = core.clamp(
        Number.isFinite(saved.left) && saved.left > -1 ? saved.left : 12,
        2,
        Math.max(2, window.innerWidth - width - 2)
      );
      const fallbackTop = Math.round((window.innerHeight - height) / 2);
      const top = core.clamp(
        Number.isFinite(saved.top) && saved.top > -1 ? saved.top : fallbackTop,
        2,
        Math.max(2, window.innerHeight - height + 140)
      );
      panel.host.style.cssText =
        'all:initial;position:fixed;display:block;z-index:2147483000;' +
        `left:${Math.round(left)}px;top:${Math.round(top)}px;`;
      if (panel.host.style.display === 'none') panel.host.style.display = 'block';
    },

    setCollapsed(collapsed, persist) {
      panel.collapsed = !!collapsed;
      panel.applyCollapsed(panel.collapsed);
      panel.applyPosition();
      panel.renderStats();
      if (persist !== false) {
        const settings = (panel.controller && panel.controller.settings) || {};
        // 只在真正变化时写设置，避免与设置广播形成来回覆盖
        if (settings.panelExpanded !== !panel.collapsed) {
          core.saveSettings({ panelExpanded: !panel.collapsed });
        }
      }
    },

    applyCollapsed(collapsed) {
      if (!panel.els.wrap) return;
      panel.els.wrap.classList.toggle('collapsed', collapsed);
      panel.els.collapse.textContent = collapsed ? '›' : '‹';
      panel.els.collapse.title = collapsed ? '展开面板' : '收起面板';
      panel.els.name.textContent = collapsed ? 'KF' : '关键帧抓取';
    },

    /** 按住把手拖动面板位置（位置会记住） */
    bindDrag() {
      const onDown = (event) => {
        if (event.button !== 0) return;
        const target = event.target;
        if (target && target.closest && target.closest('button, select')) return;
        const rect = panel.host.getBoundingClientRect();
        panel.drag = {
          dx: event.clientX - rect.left,
          dy: event.clientY - rect.top,
          moved: false
        };
        panel.els.wrap.classList.add('dragging');
        window.addEventListener('pointermove', onMove, true);
        window.addEventListener('pointerup', onUp, true);
        event.preventDefault();
      };
      const onMove = (event) => {
        if (!panel.drag) return;
        panel.drag.moved = true;
        panel.applyPosition({
          left: event.clientX - panel.drag.dx,
          top: event.clientY - panel.drag.dy
        });
      };
      const onUp = () => {
        window.removeEventListener('pointermove', onMove, true);
        window.removeEventListener('pointerup', onUp, true);
        panel.els.wrap.classList.remove('dragging');
        if (panel.drag && panel.drag.moved) {
          const rect = panel.host.getBoundingClientRect();
          const left = Math.round(rect.left);
          const top = Math.round(rect.top);
          const settings = (panel.controller && panel.controller.settings) || {};
          if (settings.panelLeft !== left || settings.panelTop !== top) {
            core.saveSettings({ panelLeft: left, panelTop: top });
          }
        }
        panel.drag = null;
      };
      panel.els.head.addEventListener('pointerdown', onDown);
    },

    /* ---------------- 显隐 ---------------- */

    setVisible(visible) {
      if (!panel.host) return;
      panel.host.style.display = visible ? 'block' : 'none';
      if (visible) {
        panel.applyPosition();
        panel.renderStats();
      }
    },

    isVisible() {
      return !!panel.host && panel.host.style.display !== 'none';
    },

    /* ---------------- 渲染 ---------------- */

    /**
     * 捕获阶段监听所有点击：任何一个按钮的处理器抛错都直接显示出来。
     * 否则按钮会「点了没反应」，用户与开发者都无从下手。
     */
    reportClickError(event) {
      const target = event.target && event.target.closest ? event.target.closest('button') : null;
      if (!target || panel.clickErrorTimer) return;
      // 用微任务把错误监听的安装和卸载包住这一次点击
      const onError = (errorEvent) => {
        const message = (errorEvent.error && errorEvent.error.message) || errorEvent.message || '未知错误';
        console.warn('[关键帧抓取] 面板按钮出错', errorEvent.error || message);
        panel.setMessage(`按钮执行失败：${message}`, true);
        if (panel.els.errdetail) {
          const stack = (errorEvent.error && errorEvent.error.stack) || message;
          panel.els.errdetail.textContent = `按钮「${target.textContent.trim()}」执行失败：\n${stack}\n\n${NS.framesource ? NS.framesource.diagnose({ stats: panel.controller && panel.controller.getStats ? panel.controller.getStats() : null }) : ''}`;
          panel.showDiagnostics(true);
        }
      };
      window.addEventListener('error', onError);
      panel.clickErrorTimer = setTimeout(() => {
        window.removeEventListener('error', onError);
        panel.clickErrorTimer = null;
      }, 4000);
    },

    /** 扫描进度（由 controller 在扫描过程中推送，传 null 隐藏） */
    updateScanProgress(progress) {
      if (!panel.els.progress) return;
      const active = !!(progress && progress.scanning);
      panel.els.progress.classList.toggle('on', active);
      if (!active) return;
      const total = core.timeText(progress.scanDuration || 0);
      const at = core.timeText(progress.scanCurrent || 0);
      panel.els.progressText.textContent = `${at} / ${total} · 已抓 ${progress.scanSaved} 帧`;
      panel.els.progressPct.textContent = `${progress.scanPercent || 0}%`;
      panel.els.progressBar.style.width = `${progress.scanPercent || 0}%`;
      const eta = progress.scanEta > 0 ? `预计剩余 ${core.timeText(progress.scanEta)}` : '';
      panel.els.progressEta.textContent = eta;
      panel.els.scan.disabled = false;
    },

    setMessage(text, isError) {
      if (!panel.els.msg) return;
      panel.els.msg.textContent = text || '';
      panel.els.msg.classList.toggle('err', !!isError);
    },

    /** 取帧失败：把完整诊断显示出来（面板只有 200px 宽，必须能展开看全） */
    setError(message) {
      panel.lastErrorText = message || '';
      const firstLine = (message || '').split('\n')[0];
      panel.setMessage(firstLine, true);
      if (!panel.els.errdetail) return;
      panel.els.errdetail.textContent = panel.buildDetailText(firstLine);
      panel.showDiagnostics(true);
    },

    buildDetailText(headline) {
      const stats = panel.controller && panel.controller.getStats ? panel.controller.getStats() : null;
      const diagnosis = NS.framesource ? NS.framesource.diagnose({ stats }) : '';
      return `${headline || '取帧诊断'}\n\n${diagnosis}`;
    },

    showDiagnostics(visible) {
      if (!panel.els.errbox) return;
      panel.els.errbox.classList.toggle('on', !!visible);
      if (visible) panel.applyPosition();
    },

    toggleDiagnostics() {
      if (panel.els.errbox.classList.contains('on')) {
        panel.showDiagnostics(false);
        return;
      }
      const stats = panel.controller && panel.controller.getStats ? panel.controller.getStats() : {};
      // 「诊断」按钮主要用来看采样/取帧情况，不一定有报错
      const headline = (stats.error || panel.lastErrorText || '').split('\n')[0] ||
        `当前模式：${stats.mode || '未知'} · 采样间隔 ${stats.intervalMs || '?'}ms`;
      if (panel.els.errdetail) panel.els.errdetail.textContent = panel.buildDetailText(headline);
      panel.showDiagnostics(true);
    },

    async copyDiagnostics() {
      const text = panel.els.errdetail ? panel.els.errdetail.textContent : '';
      try {
        await navigator.clipboard.writeText(text);
        if (panel.els.copyhint) {
          panel.els.copyhint.textContent = '已复制，可直接粘贴反馈';
          setTimeout(() => {
            if (panel.els.copyhint) panel.els.copyhint.textContent = '';
          }, 2500);
        }
      } catch (error) {
        if (panel.els.copyhint) panel.els.copyhint.textContent = `复制失败：${error.message}`;
      }
    },

    renderStats() {
      if (!panel.els.state || !panel.controller || !panel.controller.getStats) return;
      const stats = panel.controller.getStats();
      const scanning = !!stats.scanning;
      const running = stats.running;

      panel.els.dot.classList.toggle('on', running || scanning);
      panel.els.state.textContent = scanning
        ? '播放并抓帧中'
        : (running
            ? (stats.mode === 'every'
                ? '逐帧抓取中'
                : (stats.mode === 'interval' ? '定间隔抓取中' : '关键帧监听中'))
            : '已暂停');
      panel.els.count.textContent = String(stats.saved || 0);
      // 把「判定了多少次 / 存了多少张」都摊开，避免「采了 50 次只存 6 张」的困惑
      const sampled = stats.sampled || 0;
      const savedCount = stats.saved || 0;
      panel.els.unit.textContent = sampled
        ? `张 · 判定 ${sampled} 次`
        : '帧已保存';
      const rate = sampled ? Math.round((savedCount / sampled) * 100) : 0;
      panel.els.at.textContent = stats.lastTime != null
        ? `最近 ${core.timeText(stats.lastTime, true)}${sampled ? ` · 命中 ${rate}%` : ''}`
        : (sampled ? `已判定 ${sampled} 次，暂无命中` : '尚无关键帧');
      if ((stats.pass || 1) > 1) {
        panel.els.at.textContent += ` · 第 ${stats.pass} 遍`;
      }

      panel.els.scan.textContent = '';
      panel.els.scan.append(
        document.createTextNode(scanning ? '⏹ ' : '🎬 '),
        Object.assign(document.createElement('span'), {
          className: 'label',
          textContent: scanning ? '停止抓帧' : '播放并抓帧'
        })
      );
      panel.els.scan.disabled = !stats.hasVideo;
      panel.els.scan.classList.toggle('primary', !scanning);
      panel.els.replay.disabled = scanning || !stats.hasVideo;
      panel.els.replay.title = `第 ${stats.pass || 1} 遍 · 点一下回到片头再抓一遍`;
      panel.els.toggle.disabled = scanning;
      panel.els.mode.disabled = scanning;
      panel.els.snap.disabled = scanning || !stats.hasVideo || stats.busy;

      panel.els.toggle.textContent = '';
      panel.els.toggle.append(
        document.createTextNode(running ? '⏸ ' : '▶ '),
        Object.assign(document.createElement('span'), {
          className: 'label',
          textContent: running ? '暂停自动抓取' : '开始自动抓取'
        })
      );
      panel.els.toggle.classList.toggle('primary', !running);

      panel.els.snap.textContent = '';
      panel.els.snap.append(
        document.createTextNode('📸 '),
        Object.assign(document.createElement('span'), {
          className: 'label',
          textContent: stats.busy ? '抓取中…' : '抓取当前帧'
        })
      );

      if (panel.els.mode.value !== stats.mode) panel.els.mode.value = stats.mode;
      if (stats.scan) panel.updateScanProgress(stats.scan);
      if (scanning) {
        panel.setMessage(stats.status || '正在扫描…', false);
      } else if (stats.error) {
        // 只显示首行；完整内容通过「诊断」展开
        panel.setMessage(String(stats.error).split('\n')[0], true);
      } else {
        const message = stats.status || '';
        if (panel.els.msg.textContent !== message) panel.els.msg.textContent = message;
        panel.els.msg.classList.remove('err');
      }
      if (stats.title) panel.els.name.title = stats.title;
    },

    destroy() {
      if (panel.timer) clearInterval(panel.timer);
      panel.timer = null;
      if (panel.host) panel.host.remove();
      panel.host = null;
      panel.root = null;
      panel.els = {};
    }
  };

  NS.panel = panel;
})();

/**
 * gallery.js —— 全屏关键帧图库（Shadow DOM 覆盖层）
 *
 * 功能：会话列表、缩略图网格分页、单帧回跳、单帧下载/删除、
 *       多选导出 ZIP 或导出到本地文件夹、清空会话。
 */
(function () {
  'use strict';

  const NS = (window.__BKF__ = window.__BKF__ || {});
  const core = NS.core;

  const PAGE_SIZE = 90;

  const GALLERY_CSS = `
    :host { all: initial; }
    * { box-sizing: border-box; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif; }
    .backdrop { position: fixed; inset: 0; background: rgba(8,10,13,.94); color: #e9eef5;
                display: flex; flex-direction: column; font-size: 13px; }
    header { display: flex; align-items: center; gap: 10px; padding: 10px 16px;
             border-bottom: 1px solid #2b3038; background: #14171c; flex: 0 0 auto; }
    header .brand { font-weight: 700; font-size: 15px; color: #fff; }
    header .brand span { color: #fb7299; }
    .pill { background: #232830; border: 1px solid #333a44; border-radius: 999px;
            padding: 3px 10px; color: #b9c2cf; font-size: 12px; }
    .spacer { flex: 1 1 auto; }
    button { appearance: none; border: 1px solid #454c56; background: #2c313a; color: #e9eef5;
             border-radius: 8px; padding: 6px 12px; font-size: 12.5px; cursor: pointer; transition: .15s; }
    button:hover { background: #383e46; border-color: #5a626d; }
    button.primary { background: #fb7299; border-color: #fb7299; color: #fff; font-weight: 600; }
    button.primary:hover { background: #ff85a8; }
    button.ghost { background: transparent; }
    button:disabled { opacity: .45; cursor: not-allowed; }
    button.danger:hover { background: #6b2027; border-color: #a03a44; color: #ffd7db; }
    main { flex: 1 1 auto; display: flex; min-height: 0; }
    aside { width: 264px; flex: 0 0 auto; border-right: 1px solid #2b3038; background: #101317;
            overflow-y: auto; padding: 10px; }
    aside h4 { margin: 6px 6px 10px; font-size: 12px; color: #8b95a3; font-weight: 600; letter-spacing: .04em; }
    .session { display: flex; gap: 9px; padding: 8px; border-radius: 9px; cursor: pointer;
               border: 1px solid transparent; align-items: center; }
    .session:hover { background: #171b21; }
    .session.active { background: #1d222a; border-color: #fb7299; }
    .session img { width: 62px; height: 36px; object-fit: cover; border-radius: 5px; background: #222;
                   flex: 0 0 auto; }
    .session .meta { min-width: 0; }
    .session .name { font-size: 12.5px; color: #e9eef5; white-space: nowrap; overflow: hidden;
                     text-overflow: ellipsis; }
    .session .sub { font-size: 11px; color: #8b95a3; margin-top: 2px; }
    section { flex: 1 1 auto; min-width: 0; display: flex; flex-direction: column; }
    .toolbar { display: flex; align-items: center; gap: 8px; padding: 10px 16px;
               border-bottom: 1px solid #2b3038; flex-wrap: wrap; }
    .toolbar .info { color: #b9c2cf; }
    /* 按钮文字一律不换行，避免按钮被撑成两行 */
    button, .card .actions button, header button, footer button {
      white-space: nowrap; word-break: keep-all;
    }
    .grid { flex: 1 1 auto; overflow-y: auto; overflow-x: hidden; padding: 14px 16px 40px;
            display: grid; grid-template-columns: repeat(auto-fill, minmax(210px, 1fr)); gap: 12px;
            align-content: start; align-items: start;
            grid-auto-rows: max-content; min-height: 0; }
    .card { background: #171b21; border: 1px solid #2b3038; border-radius: 10px; overflow: hidden;
            display: flex; flex-direction: column; min-width: 0; }
    .card.selected { border-color: #fb7299; box-shadow: 0 0 0 1px #fb7299 inset; }
    .thumb { position: relative; background: #0d0f12; cursor: zoom-in; flex: 0 0 auto; }
    .thumb img { width: 100%; display: block; aspect-ratio: 16 / 9; object-fit: cover; }
    .tc { position: absolute; left: 7px; bottom: 7px; background: rgba(0,0,0,.72); color: #fff;
          border-radius: 5px; padding: 1px 6px; font-size: 11.5px; font-variant-numeric: tabular-nums; }
    .tc:hover { background: #fb7299; }
    .check { position: absolute; left: 7px; top: 7px; width: 20px; height: 20px; cursor: pointer;
             accent-color: #fb7299; margin: 0; z-index: 3; opacity: 1; pointer-events: auto; }
    .diff { position: absolute; right: 7px; top: 7px; background: rgba(0,0,0,.6); color: #ffd0dd;
            border-radius: 5px; padding: 1px 6px; font-size: 11px; }
    .actions { display: flex; align-items: center; gap: 6px; padding: 7px 9px;
               flex: 0 0 auto; min-height: 34px; border-top: 1px solid #22272e; }
    .actions .name { flex: 1 1 auto; font-size: 11.5px; color: #8b95a3; white-space: nowrap;
                     overflow: hidden; text-overflow: ellipsis; min-width: 30px; }
    .actions button { padding: 3px 8px; font-size: 11.5px; }
    .empty { flex: 1 1 auto; display: flex; flex-direction: column; gap: 10px; align-items: center;
             justify-content: center; color: #8b95a3; text-align: center; padding: 40px; }
    .empty h3 { color: #e9eef5; margin: 0; font-size: 16px; }
    .empty p { margin: 0; line-height: 1.7; max-width: 460px; }
    .toast { position: fixed; left: 50%; bottom: 34px; transform: translateX(-50%);
             background: #232830; border: 1px solid #3a424d; color: #e9eef5; border-radius: 10px;
             padding: 9px 16px; font-size: 13px; box-shadow: 0 10px 30px rgba(0,0,0,.5); max-width: 70vw; }
    .toast.err { border-color: #a03a44; color: #ffd7db; }
    .loader { text-align: center; color: #8b95a3; padding: 14px; grid-column: 1 / -1; }
    .viewer { position: fixed; inset: 0; background: rgba(5,6,8,.97); display: flex;
              flex-direction: column; z-index: 5; }
    .viewer .vhead { display: flex; align-items: center; gap: 10px; padding: 10px 16px; }
    .viewer .vbody { flex: 1 1 auto; display: flex; align-items: center; justify-content: center;
                     min-height: 0; padding: 0 16px 20px; }
    .viewer img { max-width: 100%; max-height: 100%; object-fit: contain; border-radius: 8px;
                  background: #000; }
    .viewer .vfoot { display: flex; gap: 8px; justify-content: center; padding: 0 16px 18px; flex-wrap: wrap; }
    input[type="number"] { width: 88px; }
    input, select { appearance: none; border: 1px solid #454c56; background: #2c313a; color: #e9eef5;
                    border-radius: 7px; padding: 5px 8px; font-size: 12.5px; }

    /* 缩略图上的选择框：必须放在上面那条 input/select 的 appearance:none 规则之后，
       否则会被它覆盖成看不出状态的空方块（这就是之前 checkbox 点了没反应的原因）。
       这里不依赖原生外观，选中与否完全由 .on 类表达。 */
    input.check { appearance: none; -webkit-appearance: none; position: absolute; left: 7px; top: 7px;
                  width: 20px; height: 20px; margin: 0; padding: 0; cursor: pointer; z-index: 3;
                  border: 2px solid #9aa4b2; border-radius: 5px; background: rgba(10,12,15,.72); }
    input.check:hover { border-color: #fb7299; }
    input.check.on { background: #fb7299; border-color: #fb7299; }
    input.check.on::after { content: ''; position: absolute; left: 6px; top: 1px; width: 5px; height: 11px;
                            border: solid #fff; border-width: 0 2.5px 2.5px 0; transform: rotate(45deg); }

    /* 单图集播放 */
    .slidebox { position: fixed; inset: 0; background: rgba(5,6,8,.97); display: flex;
                flex-direction: column; z-index: 8; }
    .slidehead { display: flex; align-items: center; gap: 10px; padding: 10px 16px; flex-wrap: nowrap;
                 white-space: nowrap; overflow-x: auto; }
    .slidehead .slideinfo { color: #b9c2cf; font-variant-numeric: tabular-nums; }
    .slidelabel { display: flex; align-items: center; gap: 6px; color: #b9c2cf; white-space: nowrap; }
    .slidebody { flex: 1 1 auto; min-height: 0; display: flex; align-items: center; justify-content: center;
                 padding: 0 16px; }
    .slidebody img { max-width: 100%; max-height: 100%; object-fit: contain; border-radius: 8px;
                     background: #000; }
    .slidefoot { display: flex; align-items: center; gap: 8px; padding: 12px 16px 18px; flex-wrap: nowrap;
                 justify-content: center; white-space: nowrap; }
    .slidehint { color: #7b8593; font-size: 11.5px; margin-left: 8px; }
  `;

  const gallery = {
    host: null,
    root: null,
    els: {},
    open_: false,
    sessions: [],
    sessionId: null,
    frames: [],
    offset: 0,
    hasMore: false,
    selected: new Set(),
    loading: false,
    settings: null,
    viewerIndex: -1,
    sessionUrl: '',
    seenHashes: new Set(),
    slideIndex: 0,
    slidePlaying: false,
    slideFps: 8,
    slideTimer: null,
    gifFps: 8,

    init(controller) {
      gallery.controller = controller;
      if (gallery.host) return;
      const host = core.ensureHost('__bkf_gallery_host');
      // 图库层级要高于左侧悬浮面板，避免互相遮挡
      host.style.zIndex = '2147483100';
      host.style.display = 'none';
      gallery.host = host;
      gallery.root = host.attachShadow({ mode: 'open' });

      const style = document.createElement('style');
      style.textContent = GALLERY_CSS;

      const backdrop = document.createElement('div');
      backdrop.className = 'backdrop';
      backdrop.innerHTML = `
        <header>
          <div class="brand">关键帧<span>图库</span></div>
          <span class="pill info-total">0 帧</span>
          <span class="pill info-session">未选择会话</span>
          <span class="spacer"></span>
          <button class="reload ghost" title="从本地存储重新加载">刷新</button>
          <button class="close ghost">关闭 (Esc)</button>
        </header>
        <main>
          <aside>
            <h4>会话（按视频）</h4>
            <div class="sessions"></div>
          </aside>
          <section>
            <div class="toolbar">
              <button class="capture primary">抓取当前帧</button>
              <button class="scan">播放并抓帧</button>
              <button class="auto">开始自动抓取</button>
              <span class="spacer"></span>
              <span class="info selinfo">已选 0</span>
              <span class="info viewinfo" hidden></span>
              <button class="selectall ghost">全选</button>
              <button class="export sel">导出已选为 ZIP</button>
              <button class="export all">导出本会话 ZIP</button>
              <button class="folder" title="需要 Chrome 支持，会先选择保存目录">存到文件夹</button>
              <button class="gif" title="把选中（或全部）帧合成动图，方便观察连贯的抓取效果">导出 GIF</button>
              <button class="slideshow" title="连环播放预览">单图集播放</button>
              <span class="spacer"></span>
              <button class="video" title="下载页面里正在播放的原视频">下载原视频</button>
              <button class="origin" title="在新标签页打开该会话对应的原始播放页">回到原播放页</button>
              <button class="prune" title="删除本会话内指纹相同的重复帧，每个画面只留一张">清理重复帧</button>
              <button class="clear danger">清空本会话</button>
              <button class="deletesession danger" title="删除整个会话（含全部帧）">删除会话</button>
            </div>
            <div class="grid"></div>
            <div class="empty" hidden>
              <h3>还没有关键帧</h3>
              <p>在 B 站播放视频时，面板上点「开始」，扩展会在画面发生场景切换时自动保存关键帧；
                 也可以用 <b>Alt+K</b> 随时手动抓取当前画面。</p>
            </div>
          </section>
        </main>
      `;

      const toast = document.createElement('div');
      toast.className = 'toast';
      toast.hidden = true;

      gallery.root.append(style, backdrop, toast);
      gallery.els = {
        backdrop,
        toast,
        sessions: backdrop.querySelector('.sessions'),
        grid: backdrop.querySelector('.grid'),
        empty: backdrop.querySelector('.empty'),
        total: backdrop.querySelector('.info-total'),
        sessionInfo: backdrop.querySelector('.info-session'),
        selInfo: backdrop.querySelector('.selinfo'),
        viewInfo: backdrop.querySelector('.viewinfo'),
        captureBtn: backdrop.querySelector('.capture'),
        scanBtn: backdrop.querySelector('.scan'),
        autoBtn: backdrop.querySelector('.auto'),
        selectAll: backdrop.querySelector('.selectall'),
        exportSel: backdrop.querySelector('.export.sel'),
        exportAll: backdrop.querySelector('.export.all'),
        folderBtn: backdrop.querySelector('.folder'),
        gifBtn: backdrop.querySelector('.gif'),
        slideshowBtn: backdrop.querySelector('.slideshow'),
        videoBtn: backdrop.querySelector('.video'),
        originBtn: backdrop.querySelector('.origin'),
        pruneBtn: backdrop.querySelector('.prune'),
        clearBtn: backdrop.querySelector('.clear'),
        deleteSessionBtn: backdrop.querySelector('.deletesession'),
        reloadBtn: backdrop.querySelector('.reload'),
        closeBtn: backdrop.querySelector('.close')
      };

      gallery.els.closeBtn.addEventListener('click', () => gallery.close());
      gallery.els.reloadBtn.addEventListener('click', () => gallery.reload());
      gallery.els.captureBtn.addEventListener('click', () => controller.captureNow('gallery'));
      gallery.els.scanBtn.addEventListener('click', () => {
        if (gallery.scanning()) {
          controller.stopScan();
          gallery.toast('正在停止扫描…');
          return;
        }
        controller.startScan().catch((error) => gallery.toast(`扫描未开始：${error.message}`, true));
      });
      gallery.els.autoBtn.addEventListener('click', () => controller.toggleAuto());
      gallery.els.selectAll.addEventListener('click', () => gallery.toggleSelectAll());
      gallery.els.exportSel.addEventListener('click', () => gallery.exportFrames([...gallery.selected]));
      gallery.els.exportAll.addEventListener('click', () => gallery.exportFrames(gallery.frames.map((f) => f.id)));
      gallery.els.folderBtn.addEventListener('click', () => gallery.exportToFolder());
      gallery.els.pruneBtn.addEventListener('click', () => gallery.pruneDuplicates());
      gallery.els.gifBtn.addEventListener('click', () => gallery.exportGif());
      gallery.els.slideshowBtn.addEventListener('click', () => gallery.openSlideshow());
      gallery.els.videoBtn.addEventListener('click', () => gallery.downloadVideo());
      gallery.els.originBtn.addEventListener('click', () => gallery.openOriginPage());
      gallery.els.deleteSessionBtn.addEventListener('click', () => gallery.deleteSession());
      gallery.els.clearBtn.addEventListener('click', () => gallery.clearSession());
      gallery.els.grid.addEventListener('scroll', () => gallery.maybeLoadMore());
      backdrop.addEventListener('keydown', (event) => gallery.onKey(event));

      core.on('frames-updated', (detail) => {
        if (!gallery.open_) return;
        // 扫描过程中每抓一帧都会触发，这里不整表刷新，避免打断浏览
        if (gallery.scanning()) return;
        if (!detail || !detail.sessionId || detail.sessionId === gallery.sessionId) {
          gallery.reload({ keepScroll: true });
        } else {
          gallery.loadSessions();
        }
      });
      core.on('sessions-changed', () => {
        if (gallery.open_) gallery.loadSessions();
      });
      core.on('scan-progress', (detail) => {
        if (!gallery.open_) return;
        const scan = detail && detail.scan ? detail.scan : null;
        if (scan) {
          gallery.els.scanBtn.textContent =
            `停止抓帧 ${scan.scanPercent || 0}%（已抓 ${scan.scanSaved || 0} 帧）`;
          gallery.els.scanBtn.classList.add('danger');
          if (scan.scanMessage) gallery.els.sessionInfo.textContent = scan.scanMessage;
        } else {
          gallery.els.scanBtn.textContent = '播放并抓帧';
          gallery.els.scanBtn.classList.remove('danger');
        }
      });
    },

    async open(sessionId) {
      gallery.init(gallery.controller);
      if (sessionId) gallery.sessionId = sessionId;
      gallery.open_ = true;
      gallery.host.style.display = '';
      gallery.viewerIndex = -1;
      gallery.settings = await core.getSettings();
      if (gallery.settings.autoPause && gallery.controller) gallery.controller.pauseVideo(true);
      document.addEventListener('keydown', gallery.onKeyGlobal, true);
      await gallery.loadSessions();
      await gallery.reload();
      gallery.els.closeBtn.focus();
    },

    async close() {
      gallery.open_ = false;
      if (gallery.host) gallery.host.style.display = 'none';
      gallery.viewerIndex = -1;
      gallery.renderViewer();
      document.removeEventListener('keydown', gallery.onKeyGlobal, true);
      if (gallery.controller) gallery.controller.pauseVideo(false);
    },

    onKeyGlobal(event) {
      if (event.key === 'Escape') {
        event.stopPropagation();
        event.preventDefault();
        gallery.close();
      }
    },

    onKey(event) {
      if (event.key === 'Escape') {
        if (gallery.root.querySelector('.slidebox')) gallery.showSlideshow(false);
        else gallery.close();
        return;
      }
      const slide = gallery.root.querySelector('.slidebox');
      if (!slide) return;
      if (event.key === ' ') {
        event.preventDefault();
        gallery.slidePlaying = !gallery.slidePlaying;
        gallery.playSlideshow(gallery.slidePlaying);
      } else if (event.key === 'ArrowLeft') {
        event.preventDefault();
        gallery.stepSlideshow(-1);
      } else if (event.key === 'ArrowRight') {
        event.preventDefault();
        gallery.stepSlideshow(1);
      }
    },

    async loadSessions() {
      try {
        const sessions = await core.send({ type: 'db.listSessions' });
        gallery.sessions = sessions || [];
        if (!gallery.sessionId && gallery.sessions.length) {
          gallery.sessionId = gallery.sessions[0].id;
        }
        if (gallery.sessionId && !gallery.sessions.some((s) => s.id === gallery.sessionId)) {
          gallery.sessionId = gallery.sessions[0] ? gallery.sessions[0].id : null;
        }
        gallery.renderSessions();
      } catch (error) {
        gallery.toast(`加载会话失败：${error.message}`, true);
      }
    },

    renderSessions() {
      const list = gallery.els.sessions;
      list.textContent = '';
      const totalFrames = gallery.sessions.reduce((sum, s) => sum + (s.frameCount || 0), 0);
      gallery.els.total.textContent = `${totalFrames} 帧 / ${gallery.sessions.length} 会话`;
      if (!gallery.sessions.length) {
        const tip = document.createElement('div');
        tip.className = 'sub';
        tip.style.cssText = 'padding:8px;color:#8b95a3;font-size:12px;line-height:1.7';
        tip.textContent = '暂无会话。开始抓取后，每个视频会自动建立一个会话。';
        list.appendChild(tip);
        return;
      }
      for (const session of gallery.sessions) {
        const item = document.createElement('div');
        item.className = 'session' + (session.id === gallery.sessionId ? ' active' : '');
        const img = document.createElement('img');
        img.alt = '';
        if (session.coverThumb) img.src = session.coverThumb;
        const meta = document.createElement('div');
        meta.className = 'meta';
        const name = document.createElement('div');
        name.className = 'name';
        name.textContent = session.title || session.id;
        const sub = document.createElement('div');
        sub.className = 'sub';
        sub.textContent = `${session.frameCount || 0} 帧 · ${core.timeText(session.duration || 0)}`;
        meta.append(name, sub);
        item.append(img, meta);
        item.addEventListener('click', () => {
          gallery.sessionId = session.id;
          gallery.selected.clear();
          gallery.renderSessions();
          gallery.reload();
        });
        list.appendChild(item);
      }
    },

    async reload(options) {
      const opts = options || {};
      if (gallery.loading) return;
      gallery.loading = true;
      try {
        if (!gallery.sessionId) {
          gallery.frames = [];
          gallery.renderFrames();
          return;
        }
        const data = await core.send({
          type: 'db.listFrames',
          sessionId: gallery.sessionId,
          offset: 0,
          limit: Math.max(PAGE_SIZE, opts.keepScroll ? gallery.frames.length : PAGE_SIZE)
        });
        gallery.frames = data.frames || [];
        gallery.offset = gallery.frames.length;
        gallery.hasMore = !!data.hasMore;
        if (!opts.keepScroll) gallery.els.grid.scrollTop = 0;
        gallery.renderFrames();
        gallery.renderToolbar();
      } catch (error) {
        gallery.toast(`加载关键帧失败：${error.message}`, true);
      } finally {
        gallery.loading = false;
      }
    },

    async maybeLoadMore() {
      const grid = gallery.els.grid;
      if (!gallery.hasMore || gallery.loading) return;
      if (grid.scrollTop + grid.clientHeight < grid.scrollHeight - 400) return;
      gallery.loading = true;
      try {
        const data = await core.send({
          type: 'db.listFrames',
          sessionId: gallery.sessionId,
          offset: gallery.offset,
          limit: PAGE_SIZE
        });
        gallery.frames = gallery.frames.concat(data.frames || []);
        gallery.offset = gallery.frames.length;
        gallery.hasMore = !!data.hasMore;
        gallery.renderFrames();
      } catch (error) {
        gallery.toast(`加载更多失败：${error.message}`, true);
      } finally {
        gallery.loading = false;
      }
    },

    renderFrames() {
      const grid = gallery.els.grid;
      grid.textContent = '';
      // 每轮重建时重置指纹集合，用于标出完全重复的帧
      gallery.seenHashes = new Set();
      gallery.els.empty.hidden = gallery.frames.length > 0;
      grid.hidden = gallery.frames.length === 0;

      const session = gallery.sessions.find((s) => s.id === gallery.sessionId);
      gallery.els.sessionInfo.textContent = session
        ? `${session.title || session.id}`
        : '未选择会话';
      if (gallery.scanning()) {
        const scan = gallery.controller.getStats().scan || {};
        gallery.els.scanBtn.textContent =
          `停止抓帧 ${scan.scanPercent || 0}%（已抓 ${scan.scanSaved || 0} 帧）`;
        gallery.els.scanBtn.classList.add('danger');
      } else {
        gallery.els.scanBtn.textContent = '播放并抓帧';
        gallery.els.scanBtn.classList.remove('danger');
      }
      gallery.els.autoBtn.textContent = gallery.controller && gallery.controller.getStats().running
        ? '暂停自动抓取'
        : '开始自动抓取';

      gallery.frames.forEach((frame, index) => {
        grid.appendChild(gallery.buildCard(frame, index));
      });
      if (gallery.hasMore) {
        const loader = document.createElement('div');
        loader.className = 'loader';
        loader.textContent = '向下滚动加载更多…';
        grid.appendChild(loader);
      }
      gallery.renderToolbar();
    },

    buildCard(frame, index) {
      const card = document.createElement('div');
      card.className = 'card' + (gallery.selected.has(frame.id) ? ' selected' : '');

      const thumb = document.createElement('div');
      thumb.className = 'thumb';
      const img = document.createElement('img');
      img.loading = 'lazy';
      img.decoding = 'async';
      img.src = frame.thumbnail || '';
      img.alt = `关键帧 ${core.timeText(frame.time, true)}`;
      img.addEventListener('click', () => gallery.openViewer(index));

      const check = document.createElement('input');
      check.type = 'checkbox';
      check.className = 'check';
      check.title = '选中以批量导出';
      check.checked = gallery.selected.has(frame.id);
      check.classList.toggle('on', check.checked); // 视觉状态由 .on 类表达，不依赖原生外观
      // 点 checkbox 只做选择，不能触发缩略图的打开预览；同时在 input 自己身上
      // 监听 change，宿主页面的样式/事件才不会把选择吃掉
      check.addEventListener('pointerdown', (event) => event.stopPropagation());
      check.addEventListener('mousedown', (event) => event.stopPropagation());
      check.addEventListener('click', (event) => {
        event.stopPropagation();
        event.preventDefault();
        // 自己维护选中态，不依赖浏览器默认的 checkbox 行为
        const selected = !gallery.selected.has(frame.id);
        check.checked = selected;
        check.classList.toggle('on', selected);
        if (selected) gallery.selected.add(frame.id);
        else gallery.selected.delete(frame.id);
        card.classList.toggle('selected', selected);
        gallery.renderToolbar();
      });
      check.addEventListener('change', (event) => event.stopPropagation());

      const tc = document.createElement('button');
      tc.className = 'tc';
      tc.textContent = core.timeText(frame.time, true);
      tc.title = '点击回跳到视频该时间点';
      tc.addEventListener('click', (event) => {
        event.stopPropagation();
        if (gallery.controller) gallery.controller.seekVideo(frame.time);
        gallery.toast(`已回跳到 ${core.timeText(frame.time, true)}`);
      });

      thumb.append(img, check, tc);
      if (frame.detection && typeof frame.detection.change === 'number') {
        const diff = document.createElement('span');
        diff.className = 'diff';
        diff.textContent = `Δ${(frame.detection.change * 100).toFixed(0)}%`;
        diff.title = `变化量：dHash ${(frame.detection.hashDistance * 100).toFixed(1)}% / MAD ${(frame.detection.mad * 100).toFixed(1)}%` +
          ` · 第 ${frame.pass || 1} 遍`;
        thumb.appendChild(diff);
      }
      // 指纹相同 = 完全重复（正常情况下不该出现，出现就说明去重漏了）
      if (frame.hash && gallery.seenHashes.has(frame.hash)) {
        const dup = document.createElement('span');
        dup.className = 'diff dup';
        dup.style.cssText = 'right:auto;left:7px;top:30px;background:#7a2b1c;color:#ffd7c8';
        dup.textContent = '重复';
        dup.title = `指纹与前面的帧相同：${frame.hash}`;
        thumb.appendChild(dup);
      } else if (frame.hash) {
        gallery.seenHashes.add(frame.hash);
      }

      const actions = document.createElement('div');
      actions.className = 'actions';
      const name = document.createElement('span');
      name.className = 'name';
      const passTag = (frame.pass || 1) > 1 ? `第${frame.pass}遍 ` : '';
      name.textContent = `${passTag}${frame.name || frame.id}`;
      name.title = `${name.textContent}${frame.hash ? ` · 指纹 ${frame.hash.slice(0, 8)}` : ''}`;

      const dl = document.createElement('button');
      dl.className = 'ghost';
      dl.textContent = '下载';
      dl.addEventListener('click', async () => {
        dl.disabled = true;
        try {
          await core.send({ type: 'export.download', frameIds: [frame.id] });
          gallery.toast('已开始下载');
        } catch (error) {
          gallery.toast(`下载失败：${error.message}`, true);
        } finally {
          dl.disabled = false;
        }
      });

      const del = document.createElement('button');
      del.className = 'ghost danger';
      del.textContent = '删除';
      del.addEventListener('click', async () => {
        try {
          await core.send({ type: 'db.deleteFrames', frameIds: [frame.id] });
          gallery.selected.delete(frame.id);
          gallery.frames = gallery.frames.filter((f) => f.id !== frame.id);
          gallery.renderFrames();
          gallery.loadSessions();
        } catch (error) {
          gallery.toast(`删除失败：${error.message}`, true);
        }
      });

      actions.append(name, dl, del);
      card.append(thumb, actions);
      return card;
    },

    scanning() {
      return !!(gallery.controller && gallery.controller.getStats && gallery.controller.getStats().scanning);
    },

    renderToolbar() {
      gallery.els.selInfo.textContent = `已选 ${gallery.selected.size}`;
      gallery.sessionUrl = (() => {
        const session = gallery.sessions.find((s) => s.id === gallery.sessionId);
        if (session && session.url) return session.url;
        const withUrl = gallery.frames.find((f) => f.sourceUrl);
        return withUrl ? withUrl.sourceUrl : '';
      })();
      if (gallery.els.originBtn) {
        gallery.els.originBtn.disabled = !gallery.sessionUrl;
        gallery.els.originBtn.title = gallery.sessionUrl
          ? `在新标签页打开：${gallery.sessionUrl}`
          : '该会话没有记录原始播放页地址';
      }
      if (gallery.els.viewInfo) {
        const showing = gallery.viewerIndex >= 0 && !!gallery.frames[gallery.viewerIndex];
        gallery.els.viewInfo.hidden = !showing;
        if (showing) {
          gallery.els.viewInfo.textContent = `预览 ${gallery.viewerIndex + 1} / ${gallery.frames.length}`;
        }
      }
      gallery.els.exportSel.disabled = gallery.selected.size === 0;
      gallery.els.exportAll.disabled = gallery.frames.length === 0;
      gallery.els.folderBtn.disabled = gallery.selected.size === 0;
      gallery.els.gifBtn.disabled = gallery.frames.length === 0;
      gallery.els.slideshowBtn.disabled = gallery.frames.length === 0;
      gallery.els.clearBtn.disabled = !gallery.sessionId;
      gallery.els.deleteSessionBtn.disabled = !gallery.sessionId;
      gallery.els.captureBtn.disabled = !(gallery.controller && gallery.controller.hasVideo());
      gallery.els.videoBtn.disabled = !(gallery.controller && gallery.controller.hasVideo());
    },

    toggleSelectAll() {
      if (gallery.selected.size === gallery.frames.length) gallery.selected.clear();
      else gallery.frames.forEach((f) => gallery.selected.add(f.id));
      gallery.renderFrames();
    },

    async exportFrames(frameIds) {
      if (!frameIds.length) return;
      const label = frameIds.length === 1 ? '正在打包 1 帧…' : `正在打包 ${frameIds.length} 帧…`;
      gallery.toast(label);
      try {
        const result = await core.send({ type: 'export.zip', frameIds, name: gallery.currentName() });
        gallery.toast(
          result.cancelled
            ? '已取消保存'
            : `已开始下载：${result.filename}（${result.count} 帧，${core.bytes(result.bytes)}）`
        );
      } catch (error) {
        gallery.toast(`导出失败：${error.message}`, true);
      }
    },

    /** 导出到本地文件夹（File System Access API，避免浏览器下载目录堆积） */
    async exportToFolder() {
      const ids = [...gallery.selected];
      if (!ids.length) return;
      await gallery.exportToFolderByIds(ids);
    },

    /** 按帧 ID 导出到用户选择的本地文件夹 */
    async exportToFolderByIds(ids) {
      if (!ids.length) return { saved: 0 };
      if (!window.showDirectoryPicker) {
        gallery.toast('当前 Chrome 不支持文件夹导出，请使用 ZIP 导出', true);
        return { saved: 0 };
      }
      const session = gallery.sessions.find((s) => s.id === gallery.sessionId);
      const folderName = core.safeName(
        `${session ? session.title : 'bilibili'} ${core.fileStamp(new Date())}`,
        'bilibili-keyframes'
      );
      try {
        const root = await window.showDirectoryPicker({ mode: 'readwrite' });
        const dir = await root.getDirectoryHandle(folderName, { create: true });
        const manifest = await core.send({ type: 'export.manifest', frameIds: ids });
        let saved = 0;
        for (const entry of manifest.files) {
          const data = await core.send({ type: 'export.frameData', frameId: entry.id });
          const blob = await (await fetch(data.dataUrl)).blob();
          const handle = await dir.getFileHandle(entry.name, { create: true });
          const writable = await handle.createWritable();
          await writable.write(blob);
          await writable.close();
          saved += 1;
          gallery.els.selInfo.textContent = `已保存 ${saved}/${manifest.files.length}`;
        }
        const info = new Blob([JSON.stringify(manifest.meta, null, 2)], { type: 'application/json' });
        const infoHandle = await dir.getFileHandle('metadata.json', { create: true });
        const infoWritable = await infoHandle.createWritable();
        await infoWritable.write(info);
        await infoWritable.close();
        gallery.toast(`已导出 ${saved} 帧到「${folderName}」文件夹`);
        return { saved, folderName };
      } catch (error) {
        if (error && error.name === 'AbortError') {
          gallery.toast('已取消文件夹导出');
          return { saved: 0, cancelled: true };
        }
        // 自动导出时没有用户手势，showDirectoryPicker 会被浏览器拒绝
        if (error && /user activation|user gesture/i.test(error.message || '')) {
          gallery.toast('自动导出需要点击授权：请在图库中选中帧后使用「存到文件夹」', true);
          return { saved: 0, needsGesture: true };
        }
        gallery.toast(`文件夹导出失败：${error.message}`, true);
        throw error;
      } finally {
        gallery.renderToolbar();
      }
    },

    /** 手动清理本会话的重复帧（指纹相同的只保留一张） */
    async pruneDuplicates() {
      if (!gallery.sessionId) return;
      gallery.els.pruneBtn.disabled = true;
      gallery.els.pruneBtn.textContent = '清理中…';
      try {
        const result = await core.send({ type: 'db.pruneDuplicates', sessionId: gallery.sessionId });
        gallery.selected.clear();
        await gallery.loadSessions();
        await gallery.reload();
        gallery.toast(
          result.removed
            ? `已删除 ${result.removed} 张重复帧，保留 ${result.kept} 张`
            : '没有发现重复帧'
        );
      } catch (error) {
        gallery.toast(`清理失败：${error.message}`, true);
      } finally {
        gallery.els.pruneBtn.disabled = false;
        gallery.els.pruneBtn.textContent = '清理重复帧';
      }
    },

    /** 导出动图 GIF：选中优先，没选就整会话 */
    async exportGif() {
      const ids = gallery.selected.size ? [...gallery.selected] : gallery.frames.map((f) => f.id);
      if (!ids.length) return;
      const input = window.prompt('GIF 帧率（每秒多少张，1~50，越小越慢）', String(gallery.gifFps || 8));
      if (input === null) return;
      const fps = Math.min(50, Math.max(1, Number(input) || 8));
      gallery.gifFps = fps;
      gallery.els.gifBtn.disabled = true;
      gallery.els.gifBtn.textContent = '编码中…';
      gallery.toast(`正在合成 GIF（${ids.length} 帧 @ ${fps}fps），帧多时需要一会儿…`);
      try {
        const result = await core.send({
          type: 'export.gif',
          frameIds: ids,
          options: { fps, name: gallery.currentName() }
        });
        gallery.toast(
          `已开始下载：${result.filename}（${result.frames} 帧${result.skipped ? `，跳过 ${result.skipped} 帧` : ''}，${core.bytes(result.bytes)}）`
        );
      } catch (error) {
        gallery.toast(`GIF 导出失败：${error.message}`, true);
      } finally {
        gallery.els.gifBtn.disabled = false;
        gallery.els.gifBtn.textContent = '导出 GIF';
      }
    },

    /** 单图集播放：像翻页动画一样连续播放本会话的帧 */
    openSlideshow() {
      if (!gallery.frames.length && !gallery.hasMore) {
        gallery.toast('本会话还没有帧', true);
        return;
      }
      gallery.showSlideshow(true);
    },

    showSlideshow(visible) {
      let box = gallery.root.querySelector('.slidebox');
      if (!visible) {
        if (box) box.remove();
        if (gallery.slideTimer) clearTimeout(gallery.slideTimer);
        gallery.slideTimer = null;
        return;
      }
      if (box) {
        box.hidden = false;
        gallery.playSlideshow(gallery.slidePlaying);
        return;
      }
      box = document.createElement('div');
      box.className = 'slidebox';
      box.innerHTML = `
        <div class="slidehead">
          <b>单图集播放</b>
          <span class="slideinfo"></span>
          <span class="spacer"></span>
          <label class="slidelabel">速度
            <select class="slidefps">
              <option value="2">2 张/秒</option>
              <option value="5">5 张/秒</option>
              <option value="8" selected>8 张/秒（≈GIF 12fps）</option>
              <option value="12">12 张/秒</option>
              <option value="24">24 张/秒（流畅）</option>
              <option value="50">50 张/秒</option>
            </select>
          </label>
          <button class="slideplay primary">暂停</button>
          <button class="slidegif">导出为 GIF</button>
          <button class="slideclose ghost">关闭 (Esc)</button>
        </div>
        <div class="slidebody"><img alt=""></div>
        <div class="slidefoot">
          <button class="slidefirst ghost">⏮ 第一张</button>
          <button class="slideprev ghost">◀ 上一张</button>
          <button class="slidenext ghost">下一张 ▶</button>
          <button class="slidelast ghost">最后一张 ⏭</button>
          <span class="slidehint">按 ← → 逐帧查看，空格暂停/继续</span>
        </div>
      `;
      gallery.root.querySelector('.backdrop').appendChild(box);
      box.querySelector('.slideclose').addEventListener('click', () => gallery.showSlideshow(false));
      box.querySelector('.slidegif').addEventListener('click', () => {
        gallery.selected = new Set(gallery.frames.map((f) => f.id));
        gallery.exportGif();
      });
      box.querySelector('.slideprev').addEventListener('click', () => gallery.stepSlideshow(-1));
      box.querySelector('.slidenext').addEventListener('click', () => gallery.stepSlideshow(1));
      box.querySelector('.slidefirst').addEventListener('click', () => gallery.jumpSlideshow(0));
      box.querySelector('.slidelast').addEventListener('click', () => gallery.jumpSlideshow(gallery.frames.length - 1));
      box.querySelector('.slideplay').addEventListener('click', () => {
        gallery.slidePlaying = !gallery.slidePlaying;
        gallery.playSlideshow(gallery.slidePlaying);
      });
      box.querySelector('.slidefps').addEventListener('change', () => {
        gallery.slideFps = Number(box.querySelector('.slidefps').value) || 8;
        gallery.playSlideshow(gallery.slidePlaying);
      });
      box.querySelector('.slidefps').value = String(gallery.slideFps || 8);
      gallery.slidePlaying = true;
      gallery.playSlideshow(true);
    },

    playSlideshow(playing) {
      const box = gallery.root.querySelector('.slidebox');
      if (!box) return;
      if (gallery.slideTimer) clearTimeout(gallery.slideTimer);
      gallery.slideTimer = null;
      box.querySelector('.slideplay').textContent = playing ? '暂停' : '播放';
      if (!playing) return;
      const fps = gallery.slideFps || 8;
      const delay = Math.max(20, Math.round(1000 / fps));
      const schedule = () => {
        gallery.slideTimer = setTimeout(async () => {
          let next = (gallery.slideIndex || 0) + 1;
          if (next >= gallery.frames.length) {
            if (gallery.hasMore) {
              await gallery.maybeLoadMore();
              if (next >= gallery.frames.length) next = 0; // 播到头就循环
            } else {
              next = 0;
            }
          }
          gallery.slideIndex = next;
          gallery.renderSlideshow();
          schedule();
        }, delay);
      };
      schedule();
    },

    stepSlideshow(delta) {
      const next = (gallery.slideIndex || 0) + delta;
      gallery.jumpSlideshow(next);
    },

    jumpSlideshow(index) {
      if (!gallery.frames.length) return;
      gallery.slideIndex = Math.max(0, Math.min(gallery.frames.length - 1, index));
      gallery.renderSlideshow();
    },

    renderSlideshow() {
      const box = gallery.root.querySelector('.slidebox');
      if (!box) return;
      const frame = gallery.frames[gallery.slideIndex || 0];
      if (!frame) return;
      const image = box.querySelector('.slidebody img');
      image.src = frame.thumbnail || '';
      box.querySelector('.slideinfo').textContent =
        `${core.timeText(frame.time, true)} · ${gallery.slideIndex + 1}/${gallery.frames.length}`;
    },

    /**
     * 回到原始播放页。
     * 每帧都记录了抓取时的页面地址，这里优先用它（GET 会触发 B 站 SPA 正常加载并播放），
     * 而不是只做 pushState（那样页面不会重新加载，播放器可能没反应）。
     */
    openOriginPage(frame) {
      const target = frame && frame.sourceUrl ? frame.sourceUrl : (gallery.sessionUrl || '');
      if (!target) {
        gallery.toast('这一帧没有记录原始地址（可能是较早抓取的）', true);
        return;
      }
      window.open(target, '_blank', 'noopener');
      gallery.toast('已在新标签页打开原播放页');
    },

    /** 下载页面里正在播放的原视频 */
    async downloadVideo() {
      gallery.els.videoBtn.disabled = true;
      gallery.els.videoBtn.textContent = '准备中…';
      try {
        const injected = await core.send({ type: 'page.playinfo' });
        const extra = (injected && injected.urls ? injected.urls : []).map((url) => ({ url, kind: 'video' }));
        const title = gallery.controller && typeof gallery.controller.videoTitle === 'function'
          ? gallery.controller.videoTitle()
          : gallery.currentName();
        const result = await core.send({ type: 'export.video', extra, title });
        // 明确告诉用户文件叫什么、去哪找：下载目录可由弹窗里的按钮打开
        gallery.toast(
          `已开始下载「${result.filename}」（${core.bytes(result.bytes)}，${result.container}` +
            `${result.hasAudio ? '，含音频' : '，⚠️ 仅视频轨、无声音'}）· ` +
            '保存在浏览器默认下载目录，可在扩展弹窗点「打开下载目录」查看'
        );
      } catch (error) {
        gallery.toast(`视频下载失败：${error.message}`, true);
      } finally {
        gallery.els.videoBtn.disabled = false;
        gallery.els.videoBtn.textContent = '下载原视频';
      }
    },

    /** 删除整个会话（含全部帧） */
    async deleteSession() {
      if (!gallery.sessionId) return;
      const session = gallery.sessions.find((s) => s.id === gallery.sessionId);
      const name = session ? session.title : gallery.sessionId;
      const count = session ? session.frameCount : 0;
      if (!window.confirm(
        `确定删除会话「${name}」吗？\n将删除其中全部 ${count} 帧，且不可撤销。\n` +
          '（只想清空画面、保留会话的话，请用「清空本会话」）'
      )) return;
      try {
        await core.send({ type: 'db.deleteSession', sessionId: gallery.sessionId });
        gallery.sessionId = null;
        gallery.selected.clear();
        await gallery.loadSessions();
        await gallery.reload();
        gallery.toast('已删除该会话');
      } catch (error) {
        gallery.toast(`删除会话失败：${error.message}`, true);
      }
    },

    async clearSession() {
      if (!gallery.sessionId) return;
      const session = gallery.sessions.find((s) => s.id === gallery.sessionId);
      const name = session ? session.title : gallery.sessionId;
      if (!window.confirm(`确定清空「${name}」的全部关键帧吗？会话本身会保留。`)) return;
      try {
        // 注意用 clearSession：只删帧、保留会话。
        // 以前这里错用了 deleteSession，把整个会话记录一起删掉了。
        const result = await core.send({ type: 'db.clearSession', sessionId: gallery.sessionId });
        gallery.selected.clear();
        if (gallery.controller && typeof gallery.controller.resetAfterClear === 'function') {
          gallery.controller.resetAfterClear(gallery.sessionId);
        }
        await gallery.loadSessions();
        await gallery.reload();
        gallery.toast(`已清空 ${result && result.removed ? result.removed : 0} 张，会话已保留`);
      } catch (error) {
        gallery.toast(`清空失败：${error.message}`, true);
      }
    },

    currentName() {
      const session = gallery.sessions.find((s) => s.id === gallery.sessionId);
      return session ? session.title : 'bilibili-keyframes';
    },

    openViewer(index) {
      gallery.viewerIndex = index;
      gallery.renderViewer();
    },

    renderViewer() {
      let viewer = gallery.root.querySelector('.viewer');
      if (gallery.viewerIndex < 0 || !gallery.frames[gallery.viewerIndex]) {
        if (viewer) viewer.remove();
        if (gallery.els.viewInfo) gallery.els.viewInfo.hidden = true;
        return;
      }
      const frame = gallery.frames[gallery.viewerIndex];
      if (!viewer) {
        viewer = document.createElement('div');
        viewer.className = 'viewer';
        viewer.innerHTML = `
          <div class="vhead">
            <span class="vtitle"></span>
            <span class="spacer"></span>
            <button class="prev ghost">上一张 ←</button>
            <button class="next ghost">下一张 →</button>
            <button class="dl">下载</button>
            <button class="del danger">删除</button>
            <button class="cls ghost">关闭 (Esc)</button>
          </div>
          <div class="vbody"><img alt=""></div>
          <div class="vfoot"></div>
        `;
        viewer.querySelector('.cls').addEventListener('click', () => {
          gallery.viewerIndex = -1;
          gallery.renderViewer();
        });
        viewer.querySelector('.prev').addEventListener('click', () => gallery.stepViewer(-1));
        viewer.querySelector('.next').addEventListener('click', () => gallery.stepViewer(1));
        viewer.querySelector('.dl').addEventListener('click', async () => {
          const current = gallery.frames[gallery.viewerIndex];
          if (!current) return;
          try {
            await core.send({ type: 'export.download', frameIds: [current.id] });
          } catch (error) {
            gallery.toast(`下载失败：${error.message}`, true);
          }
        });
        viewer.querySelector('.del').addEventListener('click', async () => {
          const current = gallery.frames[gallery.viewerIndex];
          if (!current) return;
          try {
            await core.send({ type: 'db.deleteFrames', frameIds: [current.id] });
            gallery.frames.splice(gallery.viewerIndex, 1);
            if (gallery.viewerIndex >= gallery.frames.length) gallery.viewerIndex = gallery.frames.length - 1;
            gallery.renderFrames();
            gallery.renderViewer();
            gallery.loadSessions();
          } catch (error) {
            gallery.toast(`删除失败：${error.message}`, true);
          }
        });
        gallery.root.querySelector('.backdrop').appendChild(viewer);
      }
      viewer.querySelector('.vtitle').textContent =
        `${core.timeText(frame.time, true)} · ${frame.width}×${frame.height}`;
      const large = viewer.querySelector('.vbody img');
      large.src = frame.thumbnail || '';
      // 已选数量只由 renderToolbar 写，预览位置另用一个元素，避免互相覆盖
      if (gallery.els.viewInfo) {
        gallery.els.viewInfo.hidden = false;
        gallery.els.viewInfo.textContent = `预览 ${gallery.viewerIndex + 1} / ${gallery.frames.length}`;
      }
      const foot = viewer.querySelector('.vfoot');
      foot.textContent = '';
      const jump = document.createElement('button');
      jump.className = 'primary';
      jump.textContent = `回跳到视频 ${core.timeText(frame.time, true)}`;
      jump.addEventListener('click', () => {
        if (gallery.controller) gallery.controller.seekVideo(frame.time);
      });
      const origin = document.createElement('button');
      origin.className = 'ghost';
      origin.textContent = '回到原播放页';
      origin.title = frame.sourceUrl || gallery.sessionUrl || '没有记录原始地址';
      origin.disabled = !(frame.sourceUrl || gallery.sessionUrl);
      origin.addEventListener('click', () => gallery.openOriginPage(frame));
      const rename = document.createElement('button');
      rename.className = 'ghost';
      rename.textContent = '重命名…';
      rename.addEventListener('click', async () => {
        const next = window.prompt('新的文件名（不含扩展名）', frame.name || '');
        if (!next) return;
        try {
          await core.send({ type: 'db.updateFrame', frameId: frame.id, patch: { name: next } });
          frame.name = next;
          gallery.renderFrames();
        } catch (error) {
          gallery.toast(`重命名失败：${error.message}`, true);
        }
      });
      foot.append(jump, origin, rename);
    },

    async stepViewer(delta) {
      const next = gallery.viewerIndex + delta;
      if (next < 0) return;
      if (next >= gallery.frames.length) {
        if (gallery.hasMore) await gallery.maybeLoadMore();
        if (next >= gallery.frames.length) return;
      }
      gallery.viewerIndex = next;
      gallery.renderViewer();
    },

    toast(text, isError) {
      const el = gallery.els.toast;
      if (!el) return;
      el.textContent = text;
      el.classList.toggle('err', !!isError);
      el.hidden = false;
      clearTimeout(gallery.toastTimer);
      gallery.toastTimer = setTimeout(() => {
        el.hidden = true;
      }, isError ? 6000 : 3200);
    }
  };

  NS.gallery = gallery;
})();

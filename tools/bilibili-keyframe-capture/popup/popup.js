/**
 * popup.js —— 扩展弹窗：状态、快捷操作与设置
 */
const core = {
  async send(message) {
    const response = await chrome.runtime.sendMessage(message);
    if (!response) throw new Error('扩展后台无响应');
    if (!response.ok) throw new Error(response.error || '未知错误');
    return response.data;
  },
  bytes(size) {
    const value = Number(size) || 0;
    if (value < 1024) return `${value} B`;
    if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`;
    if (value < 1024 * 1024 * 1024) return `${(value / 1024 / 1024).toFixed(1)} MB`;
    return `${(value / 1024 / 1024 / 1024).toFixed(2)} GB`;
  },
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
  }
};

const DEFAULTS = {
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
  scanOpenGallery: true
};

/** 一键套用的抓取风格 */
const PRESETS = {
  frame: {
    mode: 'every',
    intervalMs: 100,
    hashThreshold: 0.12,
    madThreshold: 0.1,
    maxFramesPerSession: 5000
  },
  balanced: {
    mode: 'auto',
    intervalMs: 200,
    hashThreshold: 0.08,
    madThreshold: 0.08,
    maxFramesPerSession: 1000
  },
  scene: {
    mode: 'auto',
    intervalMs: 100,
    hashThreshold: 0.14,
    madThreshold: 0.12,
    maxFramesPerSession: 300
  }
};

/** 切换模式时的推荐间隔 */
const MODE_INTERVAL_MS = { every: 100, auto: 100, interval: 1000 };

function el(selector) {
  return document.querySelector(selector);
}
const statusEl = el('#status');
const toastEl = el('#toast');

let settings = Object.assign({}, DEFAULTS);
let currentTab = null;
let contentStats = null;
let lastDiagnosis = '';
let refreshTimer = null;

function toast(text, isError) {
  toastEl.textContent = text;
  toastEl.classList.toggle('err', !!isError);
  toastEl.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => {
    toastEl.hidden = true;
  }, isError ? 5000 : 2600);
}

async function loadSettings() {
  const stored = await chrome.storage.local.get('settings');
  settings = Object.assign({}, DEFAULTS, stored.settings || {});
}

async function saveSettings(patch) {
  settings = Object.assign({}, settings, patch);
  // 走后台保存：后台会规范化并广播给所有页面，保证「暂停」这类状态立即生效
  try {
    const saved = await core.send({ type: 'settings.save', patch });
    if (saved) settings = saved;
  } catch {
    await chrome.storage.local.set({ settings });
  }
}

function isBilibili(url) {
  return /^https?:\/\/([^/]*\.)?bilibili\.com\//.test(url || '');
}

async function sendToTab(message) {
  if (!currentTab) throw new Error('没有活动标签页');
  try {
    return await chrome.tabs.sendMessage(currentTab.id, message);
  } catch (error) {
    throw new Error('当前页面还没有加载抓取脚本，请刷新该 B 站页面后重试');
  }
}

function renderContent() {
  const onBilibili = isBilibili(currentTab && currentTab.url);
  el('#actions').classList.toggle('disabled', !onBilibili);
  el('#notBilibili').hidden = onBilibili;
  el('#scanBtn').disabled = !onBilibili || !contentStats || !contentStats.hasVideo;

  const mode = (contentStats && contentStats.mode) || settings.mode;
  el('#modeSelect').value = mode;

  // 扫描进度
  const scan = contentStats && contentStats.scan;
  const scanning = !!(contentStats && contentStats.scanning);
  el('#scanBox').hidden = !scanning;
  el('#scanBtn').textContent = scanning
    ? '⏹ 停止抓帧（点击可中止扫描）'
    : '🎬 播放并抓帧（自动扫描整个视频）';
  if (scanning && scan) {
    el('#scanText').textContent =
      `${core.timeText(scan.scanCurrent)} / ${core.timeText(scan.scanDuration)} · 已抓 ${scan.scanSaved} 帧`;
    el('#scanPct').textContent = `${scan.scanPercent || 0}%`;
    el('#scanBar').style.width = `${scan.scanPercent || 0}%`;
    el('#scanEta').textContent = scan.scanEta > 0
      ? `预计剩余 ${core.timeText(scan.scanEta)} · ${scan.scanMessage || ''}`
      : (scan.scanMessage || '');
  }

  if (!onBilibili) {
    statusEl.className = 'status idle';
    statusEl.textContent = '请打开 B 站视频页面';
    return;
  }
  if (!contentStats) {
    statusEl.className = 'status idle';
    statusEl.textContent = '正在连接页面…（若一直无响应请刷新页面）';
    return;
  }
  const parts = [];
  if (!contentStats.hasVideo) parts.push('未找到播放中的视频');
  if (scanning) {
    parts.push('播放并抓帧中');
  } else {
    parts.push(
      contentStats.running
        ? (contentStats.mode === 'every'
            ? `逐帧抓取中（${contentStats.intervalMs}ms）`
            : (contentStats.mode === 'interval' ? '定间隔抓取中' : '关键帧监听中'))
        : '已暂停'
    );
  }
  parts.push(`${contentStats.saved} 帧`);
  // 把采样次数摊开：回答「采了 50 次为什么只存 6 张」
  if (contentStats.sampled) {
    parts.push(`判定 ${contentStats.sampled} 次 · 命中 ${contentStats.hitRate}%`);
  }
  if ((contentStats.pass || 1) > 1) parts.push(`第 ${contentStats.pass} 遍`);
  if (contentStats.lastTime != null) parts.push(`最近 ${core.timeText(contentStats.lastTime, true)}`);
  statusEl.className = 'status ' + (contentStats.running || scanning ? 'on' : 'idle');
  statusEl.textContent = parts.join(' · ');
  el('#detail').textContent = contentStats.title
    ? `${contentStats.title}${contentStats.status ? ` — ${contentStats.status}` : ''}`
    : (contentStats.status || '');
  el('#autoBtn').textContent = contentStats.running ? '暂停自动抓取' : '开始自动抓取';
  el('#autoBtn').disabled = scanning;
  el('#modeSelect').disabled = scanning;
  el('#captureBtn').disabled = !contentStats.hasVideo || scanning;
}

async function refresh() {
  const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
  currentTab = tabs && tabs[0] ? tabs[0] : null;
  contentStats = null;
  if (currentTab && isBilibili(currentTab.url)) {
    try {
      const response = await chrome.tabs.sendMessage(currentTab.id, { type: 'ping' });
      if (response && response.ok) contentStats = response.data.stats;
    } catch {
      contentStats = null;
    }
  }
  renderContent();
  renderError();
  loadUsage();
  loadSessions();
}

/** 把内容脚本侧的完整报错（含各级策略原因与探针结果）原样展示出来 */
function renderError() {
  const box = el('#errorBox');
  const text = contentStats && contentStats.error ? String(contentStats.error) : '';
  box.hidden = !text;
  if (!text) {
    lastDiagnosis = '';
    return;
  }
  lastDiagnosis = text;
  el('#errorText').textContent = text;
}

async function loadUsage() {
  try {
    const usage = await core.send({ type: 'db.usage' });
    const quotaText = usage.quota && usage.quota.quota
      ? ` · 可用配额 ${core.bytes(usage.quota.quota)}`
      : '';
    el('#usage').textContent = `本地已存 ${usage.frames} 帧 / ${usage.sessions} 个会话 · ${core.bytes(usage.bytes)}${quotaText}`;
  } catch (error) {
    el('#usage').textContent = `统计失败：${error.message}`;
  }
}

async function loadSessions() {
  const list = el('#sessions');
  list.textContent = '';
  try {
    const sessions = await core.send({ type: 'db.listSessions' });
    const withFrames = sessions.filter((s) => (s.frameCount || 0) > 0).slice(0, 5);
    if (!withFrames.length) {
      const tip = document.createElement('div');
      tip.className = 'empty';
      tip.textContent = '还没有抓取记录，去 B 站播放一个视频吧。';
      list.appendChild(tip);
      return;
    }
    for (const session of withFrames) {
      const row = document.createElement('div');
      row.className = 'session';
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
      sub.textContent = `${session.frameCount} 帧 · ${core.bytes(session.bytes || 0)}`;
      meta.append(name, sub);
      const open = document.createElement('button');
      open.className = 'ghost sessionopen';
      open.textContent = '原页';
      open.title = session.url ? `在新标签页打开：${session.url}` : '该会话没有记录原始播放页地址';
      open.disabled = !session.url;
      open.addEventListener('click', (event) => {
        event.stopPropagation();
        if (session.url) {
          chrome.tabs.create({ url: session.url });
          window.close();
        }
      });
      const del = document.createElement('button');
      del.className = 'ghost danger sessiondel';
      del.textContent = '删除';
      del.title = '删除该会话及其全部帧';
      del.addEventListener('click', async (event) => {
        event.stopPropagation();
        if (!window.confirm(`确定删除会话「${session.title || session.id}」及其中 ${session.frameCount} 帧？不可撤销。`)) return;
        try {
          await core.send({ type: 'db.deleteSession', sessionId: session.id });
          toast('已删除该会话');
          loadSessions();
          loadUsage();
        } catch (error) {
          toast(`删除失败：${error.message}`, true);
        }
      });
      row.append(img, meta, open, del);
      row.addEventListener('click', () => openGallery(session.id));
      list.appendChild(row);
    }
  } catch (error) {
    const tip = document.createElement('div');
    tip.className = 'empty';
    tip.textContent = `读取会话失败：${error.message}`;
    list.appendChild(tip);
  }
}

async function openGallery(sessionId) {
  if (!currentTab || !isBilibili(currentTab.url)) {
    toast('请先在 B 站视频页面打开图库', true);
    return;
  }
  try {
    await sendToTab({ type: 'gallery.open', sessionId });
    window.close();
  } catch (error) {
    toast(error.message, true);
  }
}

function bindSettings() {
  el('#modeSelect').addEventListener('change', async (event) => {
    const mode = event.target.value;
    const patch = { mode };
    // 每个模式配一个合适的采样间隔：逐帧模式要密，定间隔模式要疏（否则瞬间刷满上限）
    const suggested = MODE_INTERVAL_MS[mode];
    if (suggested && mode !== 'off' && settings.intervalMs !== suggested) {
      const needsChange = mode === 'every' ? settings.intervalMs > 100 : settings.intervalMs !== suggested;
      if (needsChange) {
        patch.intervalMs = suggested;
        el('#intervalMs').value = suggested;
      }
    }
    await saveSettings(patch);
    if (currentTab && isBilibili(currentTab.url) && contentStats) {
      try {
        await sendToTab({ type: 'settings.apply' });
      } catch {
        /* 页面未加载脚本时忽略 */
      }
    }
    const label = event.target.selectedOptions[0].textContent;
    toast(
      patch.intervalMs
        ? `已切换为「${label}」，采样间隔 ${patch.intervalMs}ms`
        : `模式已切换为「${label}」`
    );
  });

  el('#presetSelect').addEventListener('change', async (event) => {
    const preset = PRESETS[event.target.value];
    if (!preset) return;
    await saveSettings(preset);
    renderSettings();
    if (currentTab && isBilibili(currentTab.url) && contentStats) {
      try {
        await sendToTab({ type: 'settings.apply' });
      } catch {
        /* 忽略 */
      }
    }
    const label = event.target.selectedOptions[0].textContent;
    toast(`已套用「${label.split('：')[0]}」：${preset.intervalMs}ms / 灵敏度 ${Math.round(preset.hashThreshold * 100)} / 上限 ${preset.maxFramesPerSession} 帧`);
  });

  const numberBindings = [
    ['#hashThreshold', 'hashThreshold', (v) => v / 100],
    ['#madThreshold', 'madThreshold', (v) => v / 100],
    ['#intervalMs', 'intervalMs', (v) => v],
    ['#minChange', 'minChange', (v) => v / 100],
    ['#maxWidth', 'maxWidth', (v) => v],
    ['#maxFrames', 'maxFramesPerSession', (v) => v],
    ['#quality', 'quality', (v) => v / 100],
    ['#scanInterval', 'scanInterval', (v) => v]
  ];
  for (const [selector, key, parse] of numberBindings) {
    const input = el(selector);
    input.addEventListener('change', async () => {
      await saveSettings({ [key]: parse(Number(input.value)) });
      input.value = settings[key];
    });
  }

  el('#formatSelect').addEventListener('change', (event) => saveSettings({ format: event.target.value }));
  el('#autoExportSelect').addEventListener('change', (event) => saveSettings({ autoExport: event.target.value }));
  el('#autoPrune').addEventListener('change', async (event) => {
    await saveSettings({ autoPruneDuplicates: event.target.checked });
    toast(event.target.checked ? '已开启自动删除重复帧' : '已关闭自动删除重复帧');
  });
  el('#showPanel').addEventListener('change', async (event) => {
    await saveSettings({ showPanel: event.target.checked });
    if (currentTab && isBilibili(currentTab.url) && contentStats) {
      try {
        await sendToTab({ type: event.target.checked ? 'panel.show' : 'panel.hide' });
      } catch {
        /* 忽略 */
      }
    }
  });
  el('#autoPause').addEventListener('change', (event) => saveSettings({ autoPause: event.target.checked }));

  el('#scanRate').addEventListener('change', async (event) => {
    await saveSettings({ scanRate: Number(event.target.value) });
    toast(`扫描倍速已设为 ${event.target.value}×`);
  });
  el('#scanPauseMain').addEventListener('change', (event) =>
    saveSettings({ scanPauseMain: event.target.checked })
  );
  el('#scanOpenGallery').addEventListener('change', (event) =>
    saveSettings({ scanOpenGallery: event.target.checked })
  );

  el('#resetPanel').addEventListener('click', async () => {
    await saveSettings({ panelLeft: 12, panelTop: null, panelExpanded: true, showPanel: true });
    el('#showPanel').checked = true;
    if (currentTab && isBilibili(currentTab.url) && contentStats) {
      try {
        await sendToTab({ type: 'settings.apply' });
      } catch {
        /* 忽略 */
      }
    }
    toast('面板位置已重置为左侧居中');
  });
}

function renderSettings() {
  el('#hashThreshold').value = Math.round(settings.hashThreshold * 100);
  el('#madThreshold').value = Math.round(settings.madThreshold * 100);
  el('#intervalMs').value = settings.intervalMs;
  el('#minChange').value = Math.round(settings.minChange * 1000) / 10;
  el('#maxWidth').value = settings.maxWidth;
  el('#maxFrames').value = settings.maxFramesPerSession;
  el('#quality').value = Math.round(settings.quality * 100);
  el('#formatSelect').value = settings.format;
  el('#autoExportSelect').value = settings.autoExport;
  el('#showPanel').checked = !!settings.showPanel;
  el('#autoPrune').checked = settings.autoPruneDuplicates !== false;
  el('#autoPause').checked = !!settings.autoPause;
  el('#scanInterval').value = settings.scanInterval;
  el('#scanRate').value = String(settings.scanRate);
  el('#scanPauseMain').checked = !!settings.scanPauseMain;
  el('#scanOpenGallery').checked = !!settings.scanOpenGallery;
  el('#modeSelect').value = settings.mode;
  el('#presetSelect').value = detectPreset();
}

/** 反查当前设置最接近哪个预设，让下拉框显示得有参考价值 */
function detectPreset() {
  for (const [key, preset] of Object.entries(PRESETS)) {
    const same =
      settings.mode === preset.mode &&
      Number(settings.intervalMs) === preset.intervalMs &&
      Math.abs(Number(settings.hashThreshold) - preset.hashThreshold) < 0.005 &&
      Number(settings.maxFramesPerSession) === preset.maxFramesPerSession;
    if (same) return key;
  }
  // 没完全匹配时，按模式给个近似
  if (settings.mode === 'every') return 'frame';
  return settings.hashThreshold >= 0.12 ? 'scene' : 'balanced';
}

async function openOptionsUrl(hash) {
  await chrome.tabs.create({ url: chrome.runtime.getURL('popup/options.html' + (hash || '')) });
  window.close();
}

function bindActions() {
  el('#captureBtn').addEventListener('click', async () => {
    el('#captureBtn').disabled = true;
    try {
      const response = await sendToTab({ type: 'capture-now', source: 'popup' });
      if (response && response.ok && response.data && response.data.ok) {
        toast(`已抓取 ${core.timeText(response.data.time, true)}（共 ${response.data.frameCount} 帧）`);
      } else {
        toast((response && response.data && response.data.reason) || '未抓取到画面', true);
      }
    } catch (error) {
      toast(error.message, true);
    } finally {
      el('#captureBtn').disabled = false;
      setTimeout(refresh, 600);
    }
  });

  el('#autoBtn').addEventListener('click', async () => {
    try {
      if (!contentStats) await refresh();
      const running = !!(contentStats && contentStats.running);
      const remembered = settings.lastActiveMode || 'auto';
      // 暂停时把 mode 写成 off（持久化），否则下次进页面又会自动开跑
      const nextMode = running ? 'off' : (settings.mode === 'off' ? remembered : settings.mode);
      await saveSettings({ mode: nextMode });
      el('#modeSelect').value = nextMode;
      if (currentTab && isBilibili(currentTab.url)) {
        try {
          await sendToTab({ type: 'settings.apply' });
        } catch {
          /* 忽略 */
        }
      }
      toast(nextMode === 'off' ? '已暂停自动抓取（下次进页面不会自动开始）' : '已开始自动抓取');
      setTimeout(refresh, 500);
    } catch (error) {
      toast(error.message, true);
    }
  });

  el('#openDownloads').addEventListener('click', async () => {
    try {
      const result = await core.send({ type: 'downloads.openFolder' });
      if (result && result.opened) toast('已打开下载目录');
      else toast(result && result.reason ? result.reason : '无法打开下载目录', true);
    } catch (error) {
      toast(`打开下载目录失败：${error.message}`, true);
    }
  });

  el('#galleryBtn').addEventListener('click', () => openGallery());

  el('#videoBtn').addEventListener('click', async () => {
    el('#videoBtn').disabled = true;
    el('#videoBtn').textContent = '准备中…';
    try {
      const injected = await sendToTab({ type: 'page.playinfo' });
      const extra = (injected && injected.urls ? injected.urls : []).map((url) => ({ url, kind: 'video' }));
      const result = await core.send({
        type: 'export.video',
        extra,
        title: contentStats && contentStats.title
      });
      toast(
        `已开始下载「${result.filename}」（${core.bytes(result.bytes)}` +
          `${result.hasAudio ? '，含音频' : '，仅视频轨无声音'}）→ 浏览器默认下载目录`
      );
    } catch (error) {
      toast(`视频下载失败：${error.message}`, true);
    } finally {
      el('#videoBtn').disabled = false;
      el('#videoBtn').textContent = '下载视频';
    }
  });

  el('#replayBtn').addEventListener('click', async () => {
    el('#replayBtn').disabled = true;
    try {
      const response = await sendToTab({ type: 'replay' });
      if (response && response.ok && response.data) {
        toast(`已开始第 ${response.data.pass} 遍抓取（相同画面不会重复保存）`);
      } else {
        toast((response && response.error) || '无法重新播放', true);
      }
    } catch (error) {
      toast(error.message, true);
    } finally {
      setTimeout(() => {
        el('#replayBtn').disabled = false;
        refresh();
      }, 900);
    }
  });

  el('#copyDiag').addEventListener('click', async () => {
    try {
      let text = lastDiagnosis;
      if (currentTab && isBilibili(currentTab.url)) {
        try {
          const response = await chrome.tabs.sendMessage(currentTab.id, { type: 'diagnose' });
          if (response && response.ok && response.data && response.data.text) {
            text = `${lastDiagnosis}\n\n${response.data.text}`;
            el('#errorText').textContent = text;
          }
        } catch {
          /* 页面没加载脚本时退回复制现有文本 */
        }
      }
      await navigator.clipboard.writeText(text);
      el('#copyHint').textContent = '已复制';
    } catch (error) {
      el('#copyHint').textContent = `复制失败：${error.message}`;
    }
    setTimeout(() => {
      el('#copyHint').textContent = '';
    }, 2500);
  });

  el('#scanBtn').addEventListener('click', async () => {
    const scanning = !!(contentStats && contentStats.scanning);
    el('#scanBtn').disabled = true;
    try {
      if (scanning) {
        await sendToTab({ type: 'scan.stop' });
        toast('正在停止扫描…');
      } else {
        toast('已开始播放并抓帧，可随时再点一次中止');
        sendToTab({ type: 'scan.start' }).then((response) => {
          if (response && response.ok && response.data) {
            toast(`扫描完成：新增 ${response.data.saved} 帧（${response.data.reason}）`);
          } else if (response && !response.ok) {
            toast(`扫描失败：${response.error}`, true);
          }
          setTimeout(refresh, 400);
        }).catch((error) => toast(`扫描失败：${error.message}`, true));
      }
    } catch (error) {
      toast(error.message, true);
    } finally {
      setTimeout(() => {
        el('#scanBtn').disabled = false;
        refresh();
      }, 700);
    }
  });

  el('#refetch').addEventListener('click', async () => {
    el('#refetch').disabled = true;
    el('#copyHint').textContent = '正在查找播放器请求的视频地址…';
    try {
      const response = await sendToTab({ type: 'media.list' });
      if (response && response.ok && response.data && response.data.ok) {
        el('#copyHint').textContent =
          `已切换取帧源：${response.data.source}（方式 ${response.data.mode}）`;
        toast('取帧源已更新，可以重新抓帧了');
      } else {
        el('#copyHint').textContent = '';
        toast((response && response.error) || '没有找到可用的视频地址', true);
      }
    } catch (error) {
      el('#copyHint').textContent = '';
      toast(error.message, true);
    } finally {
      el('#refetch').disabled = false;
      setTimeout(refresh, 800);
    }
  });

  el('#captureHelp').addEventListener('click', () =>
    openOptionsUrl('#help')
  );
  el('#openOptions').addEventListener('click', () => openOptionsUrl(''));
}

async function init() {
  await loadSettings();
  renderSettings();
  bindSettings();
  bindActions();
  await refresh();
  refreshTimer = setInterval(refresh, 1500);
  window.addEventListener('unload', () => clearInterval(refreshTimer));
}

init().catch((error) => {
  statusEl.textContent = `初始化失败：${error.message}`;
});

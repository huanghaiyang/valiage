/**
 * export.js —— 导出：ZIP 打包、单帧下载、导出清单
 */
(function () {
  'use strict';

  const global = self;
  const db = global.BKFdb;
  const zipLib = global.BKFzip;
  const gifLib = global.BKFgif;

  function pad(num, width) {
    return String(num).padStart(width || 2, '0');
  }

  function timeTag(seconds) {
    const total = Math.max(0, Number(seconds) || 0);
    const hours = Math.floor(total / 3600);
    const minutes = Math.floor((total % 3600) / 60);
    const secs = Math.floor(total % 60);
    const millis = Math.floor((total % 1) * 1000);
    return (
      (hours > 0 ? `${pad(hours)}:` : '') +
      `${pad(minutes)}:${pad(secs)}.${pad(millis, 3)}`
    );
  }

  function safeName(text, fallback) {
    const cleaned = String(text || '')
      .replace(/[\\/:*?"<>|\u0000-\u001f]/g, '_')
      .replace(/\s+/g, ' ')
      .trim();
    return (cleaned || fallback || 'untitled').slice(0, 70);
  }

  function stamp(date) {
    const d = date instanceof Date ? date : new Date();
    return (
      `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-` +
      `${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`
    );
  }

  function blobToBytes(blob) {
    return blob.arrayBuffer().then((buffer) => new Uint8Array(buffer));
  }

  /** 为「导出中」的重活续命：MV3 Service Worker 空闲 30s 会被回收 */
  function keepAlive(start) {
    const timer = setInterval(() => {
      chrome.runtime.getPlatformInfo(() => {});
    }, 12000);
    chrome.runtime.getPlatformInfo(() => {});
    return () => {
      clearInterval(timer);
      void start;
    };
  }

  async function buildManifest(frameIds, name) {
    const records = await db.getFrames(frameIds);
    if (!records.length) throw new Error('没有可导出的关键帧');
    const session = (await db.getSession(records[0].sessionId)) || {};
    const used = new Set();
    const files = records.map((record, index) => {
      const base = `${pad(index + 1, 3)}_${timeTag(record.time).replace(/[:.]/g, '-')}`;
      let fileName = `${base}.${record.format || 'jpg'}`;
      let suffix = 1;
      while (used.has(fileName)) {
        fileName = `${base}_${suffix}.${record.format || 'jpg'}`;
        suffix += 1;
      }
      used.add(fileName);
      return {
        id: record.id,
        name: fileName,
        time: record.time,
        timeTag: timeTag(record.time),
        width: record.width,
        height: record.height,
        format: record.format,
        bytes: record.bytes,
        detection: record.detection,
        pass: record.pass || 1,
        sourceUrl: (record.video && record.video.url) || '',
        createdAt: record.createdAt
      };
    });
    const totalBytes = files.reduce((sum, file) => sum + (file.bytes || 0), 0);
    const base = safeName(name || session.title || 'bilibili-keyframes', 'bilibili-keyframes');
    return {
      files,
      session,
      meta: {
        generatedBy: 'B站关键帧抓取器 (Chrome 扩展)',
        exportedAt: new Date().toISOString(),
        title: session.title || base,
        author: session.author || '',
        videoUrl: session.url || '',
        bvid: session.bvid || '',
        durationSeconds: session.duration || 0,
        frameCount: files.length,
        totalBytes,
        frames: files.map((file) => ({
          file: file.name,
          time: file.time,
          timeTag: file.timeTag,
          size: `${file.width}x${file.height}`,
          bytes: file.bytes,
          pass: file.pass,
          sourceUrl: file.sourceUrl || '',
          change: file.detection ? Number(file.detection.change.toFixed(4)) : null,
          hashDistance: file.detection ? Number(file.detection.hashDistance.toFixed(4)) : null,
          meanAbsDiff: file.detection ? Number(file.detection.mad.toFixed(4)) : null
        }))
      },
      zipName: `${base}_${stamp(new Date())}.zip`
    };
  }

  function csvOf(meta) {
    const lines = ['file,time_seconds,time_tag,resolution,bytes,pass,change,hash_distance,mean_abs_diff'];
    for (const item of meta.frames) {
      lines.push(
        [
          item.file.replace(/,/g, '_'),
          item.time.toFixed(3),
          item.timeTag,
          item.size,
          item.bytes,
          item.pass == null ? '' : item.pass,
          item.change == null ? '' : item.change,
          item.hashDistance == null ? '' : item.hashDistance,
          item.meanAbsDiff == null ? '' : item.meanAbsDiff
        ].join(',')
      );
    }
    return lines.join('\r\n');
  }

  async function downloadUrl(url, filename) {
    const id = await chrome.downloads.download({ url, filename, saveAs: false });
    // 让下载先启动再回收 blob URL，避免下载被中断
    setTimeout(() => {
      try {
        URL.revokeObjectURL(url);
      } catch {
        /* 忽略 */
      }
    }, 120000);
    return id;
  }

  const exporter = {
    timeTag,
    safeName,

    /** 打包选中帧并触发下载 */
    async exportZip(frameIds, name) {
      const stop = keepAlive();
      try {
        const manifest = await buildManifest(frameIds, name);
        const archive = zipLib.zip();
        for (let i = 0; i < manifest.files.length; i += 1) {
          const file = manifest.files[i];
          const record = await db.getFrame(file.id);
          if (!record || !record.blob) continue;
          const bytes = await blobToBytes(record.blob);
          archive.addFile(`frames/${file.name}`, bytes, new Date(record.createdAt || Date.now()));
        }
        archive.addFile('index.csv', new TextEncoder().encode(csvOf(manifest.meta)));
        archive.addFile(
          'metadata.json',
          new TextEncoder().encode(JSON.stringify(manifest.meta, null, 2))
        );
        const blob = archive.finish();
        const url = URL.createObjectURL(blob);
        await downloadUrl(url, manifest.zipName);
        return {
          filename: manifest.zipName,
          count: manifest.files.length,
          bytes: blob.size,
          cancelled: false
        };
      } finally {
        stop();
      }
    },

    /** 单帧下载 */
    async downloadFrames(frameIds) {
      const records = await db.getFrames(frameIds);
      if (!records.length) throw new Error('找不到该关键帧');
      const session = (await db.getSession(records[0].sessionId)) || {};
      const base = safeName(session.title || 'bilibili-keyframe', 'bilibili-keyframe');
      let index = 0;
      for (const record of records) {
        const url = URL.createObjectURL(record.blob);
        const name =
          records.length === 1
            ? `${base}_${timeTag(record.time).replace(/[:.]/g, '-')}.${record.format || 'jpg'}`
            : `frames/${base}_${pad(index + 1, 3)}_${timeTag(record.time).replace(/[:.]/g, '-')}.${record.format || 'jpg'}`;
        await downloadUrl(url, name);
        index += 1;
      }
      return { count: records.length };
    },

    /** 导出清单（供内容脚本写到本地文件夹） */
    async manifest(frameIds, name) {
      const built = await buildManifest(frameIds, name);
      return { files: built.files, meta: built.meta, zipName: built.zipName };
    },

    /** 单帧原图的 dataURL（文件夹导出时逐个取用，避免一次性占用大量内存） */
    async frameData(frameId) {
      const record = await db.getFrame(frameId);
      if (!record || !record.blob) throw new Error('该关键帧数据已丢失');
      const buffer = await record.blob.arrayBuffer();
      const bytes = new Uint8Array(buffer);
      let binary = '';
      const chunk = 0x8000;
      for (let i = 0; i < bytes.length; i += chunk) {
        binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
      }
      const type = record.blob.type || 'image/jpeg';
      return {
        id: record.id,
        name: record.name,
        type,
        bytes: bytes.length,
        dataUrl: `data:${type};base64,${btoa(binary)}`
      };
    },

    /**
     * 把选中的关键帧编码成动图 GIF 并下载（用来观察连贯的抓取效果）。
     * @param {string[]} frameIds
     * @param {object} options { fps, maxWidth, name }
     */
    async exportGif(frameIds, options) {
      const opts = options || {};
      const stop = keepAlive();
      try {
        const records = await db.getFrames(frameIds);
        if (!records.length) throw new Error('没有可导出的关键帧');
        const fps = Math.min(50, Math.max(1, Number(opts.fps) || 8));
        const maxWidth = Math.min(960, Math.max(120, Number(opts.maxWidth) || 480));
        // 每帧像素 = w*h*4；这里按 200MB 左右的总量兜底，避免把标签页拖死
        const limit = Math.max(20, Math.min(records.length, Math.floor(200 * 1024 * 1024 / (maxWidth * maxWidth * 4))));

        const frames = [];
        for (const record of records.slice(0, limit)) {
          const pixels = await exporter.decodeFrame(record.blob, maxWidth);
          if (pixels) frames.push(pixels);
        }
        if (!frames.length) throw new Error('这些帧无法解码（可能是图片格式不支持）');

        const blob = gifLib.encodeGif(frames, { fps, loop: 0, maxColors: 256 });
        const session = (await db.getSession(records[0].sessionId)) || {};
        const base = safeName(opts.name || session.title || 'bilibili-keyframes', 'bilibili-keyframes');
        const filename = `${base}_动画_${stamp(new Date())}.gif`;
        const url = URL.createObjectURL(blob);
        await downloadUrl(url, filename);
        return {
          filename,
          frames: frames.length,
          bytes: blob.size,
          skipped: records.length - frames.length,
          fps
        };
      } finally {
        stop();
      }
    },

    /** 用 OffscreenCanvas 把一张图解码并缩放到指定宽度，返回 ImageData */
    async decodeFrame(blob, maxWidth) {
      try {
        if (typeof createImageBitmap !== 'function' || typeof OffscreenCanvas !== 'function') {
          throw new Error('当前环境不支持 OffscreenCanvas（需要 Chrome 116+）');
        }
        const bitmap = await createImageBitmap(blob);
        const scale = Math.min(1, maxWidth / Math.max(bitmap.width, bitmap.height));
        const width = Math.max(2, Math.round(bitmap.width * scale));
        const height = Math.max(2, Math.round(bitmap.height * scale));
        const canvas = new OffscreenCanvas(width, height);
        const ctx = canvas.getContext('2d', { alpha: false });
        ctx.drawImage(bitmap, 0, 0, width, height);
        const imageData = ctx.getImageData(0, 0, width, height);
        if (typeof bitmap.close === 'function') bitmap.close();
        return { pixels: imageData.data, width, height };
      } catch (error) {
        console.warn('[关键帧抓取] 解码帧失败', error);
        return null;
      }
    },

    /**
     * 下载原视频。优先用「音视频合一的整段文件」，没有就把 DASH 视频轨拿下来
     * （DASH 音视频分离，单独下视频轨是没有声音的，返回里会说明）。
     */
    async downloadVideo(candidates, title) {
      if (!Array.isArray(candidates) || !candidates.length) {
        throw new Error('没有可下载的视频地址，请先在页面里播放一下让播放器加载视频');
      }
      const base = safeName(title || 'bilibili-video', 'bilibili-video');
      const failures = [];
      // 按「是否含音频」排序：durl 整段 > 视频轨 > 音轨
      const order = { durl: 0, video: 1, media: 2, unknown: 3, audio: 4 };
      const ranked = candidates
        .slice()
        .sort((a, b) => (order[a.kind] === undefined ? 9 : order[a.kind]) - (order[b.kind] === undefined ? 9 : order[b.kind]));

      for (const candidate of ranked.slice(0, 4)) {
        if (candidate.kind === 'audio') continue;
        try {
          // 探测容器类型，用来决定扩展名
          const media = await exporter.probeContainer(candidate.url);
          if (!media.ok) {
            failures.push(`${candidate.kind || 'unknown'}: HTTP ${media.status}`);
            continue;
          }
          const ext = media.extension || 'mp4';
          const filename = `${base}_原视频_${stamp(new Date())}.${ext}`;
          const url = media.blobUrl;
          await downloadUrl(url, filename);
          return {
            filename,
            bytes: media.bytes,
            container: media.container,
            hasAudio: candidate.kind === 'durl' || candidate.kind === 'media',
            source: candidate.kind || 'unknown'
          };
        } catch (error) {
          failures.push(`${candidate.kind || 'unknown'}: ${error.message}`);
        }
      }
      throw new Error(`视频下载失败：${failures.join(' | ') || '没有可用的地址'}`);
    },

    /**
     * 拉取视频容器的开头，判断扩展名。
     * 先只取前 4MB，确定类型后再把整段流式写进 Blob（避免把内容读两遍）。
     */
    async probeContainer(url) {
      const headResponse = await fetch(url, {
        headers: { Range: 'bytes=0-4194303' },
        credentials: 'omit',
        referrer: 'https://www.bilibili.com/'
      });
      if (!headResponse.ok && headResponse.status !== 206) {
        return { ok: false, status: headResponse.status };
      }
      const head = new Uint8Array(await headResponse.arrayBuffer());
      const container = exporter.containerOf(head);
      const extension = /Matroska|WebM/.test(container) ? 'mkv' : (/MPEG-TS/.test(container) ? 'ts' : 'mp4');
      const full = await fetch(url, { credentials: 'omit', referrer: 'https://www.bilibili.com/' });
      if (!full.ok && full.status !== 206) return { ok: false, status: full.status };
      const blob = await full.blob();
      return {
        ok: true,
        status: full.status,
        container,
        extension,
        bytes: blob.size,
        blobUrl: URL.createObjectURL(blob)
      };
    },

    containerOf(bytes) {
      const ascii = (start, end) => String.fromCharCode.apply(null, Array.from(bytes.subarray(start, end)));
      if (bytes.length >= 12 && ascii(4, 8) === 'ftyp') return `MP4/fMP4（${ascii(8, 12)}）`;
      if (bytes.length >= 4 && bytes[0] === 0x1a && bytes[1] === 0x45 && bytes[2] === 0xdf && bytes[3] === 0xa3) {
        return 'Matroska/WebM';
      }
      if (bytes.length >= 4 && bytes[0] === 0x46 && bytes[1] === 0x4c && bytes[2] === 0x56) return 'FLV';
      if (bytes.length >= 1 && bytes[0] === 0x47) return 'MPEG-TS';
      return '未知';
    }
  };

  global.BKFexporter = exporter;
})();

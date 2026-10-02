/**
 * detector.js —— 关键帧检测（灰度缩略图上的 dHash + 平均绝对差）
 *
 * 思路：
 *   1. 把当前画面缩到 11x10 的灰度图，比较相邻像素得到 100 bit 的 dHash；
 *   2. 同时保留 16x16 灰度图用于计算帧间平均绝对差（MAD）；
 *   3. 与「上一张已保存的关键帧」比较：画面明显变化 => 场景切换 => 保存。
 * 纯函数实现，方便单独测试与调整阈值。
 */
(function () {
  'use strict';

  const NS = (window.__BKF__ = window.__BKF__ || {});

  const HASH_W = 10;
  const HASH_H = 10;
  const SAMPLE_W = 16;
  const SAMPLE_H = 16;

  /** 按下标统计汉明距离（等价于异或后 popcount） */
  const POPCOUNT = (function buildTable() {
    const table = new Uint8Array(256);
    for (let i = 0; i < 256; i += 1) {
      let value = i;
      let count = 0;
      while (value) {
        count += value & 1;
        value >>= 1;
      }
      table[i] = count;
    }
    return table;
  })();

  const detector = {
    HASH_BITS: HASH_W * HASH_H,

    /**
     * 从视频当前帧抽出一张「小灰度图」签名。
     * @param {HTMLVideoElement} video
     * @param {HTMLCanvasElement} canvas 复用画布
     * @returns {{hash:string, hashBits:number, sample:Uint8ClampedArray, brightness:number, luminance:Float32Array}}
     */
    sample(video, canvas) {
      const hashed = detector.hashCanvas(video, canvas);
      const sampled = detector.sampleCanvas(video, canvas);
      return {
        hash: hashed.hash,
        hashBits: hashed.hashBits,
        brightness: hashed.brightness,
        luminance: hashed.luminance,
        sample: sampled.sample
      };
    },

    /** 11x11 灰度图 -> 100bit dHash */
    hashCanvas(video, canvas) {
      const ctx = detector.prepare(canvas, HASH_W + 1, HASH_H);
      ctx.drawImage(video, 0, 0, HASH_W + 1, HASH_H);
      const data = ctx.getImageData(0, 0, HASH_W + 1, HASH_H).data;
      const gray = new Uint8Array((HASH_W + 1) * HASH_H);
      for (let i = 0, p = 0; i < gray.length; i += 1, p += 4) {
        gray[i] = (data[p] * 299 + data[p + 1] * 587 + data[p + 2] * 114) / 1000;
      }
      const bits = new Uint8Array(HASH_W * HASH_H);
      const luminance = new Float32Array(HASH_W * HASH_H);
      let sum = 0;
      let index = 0;
      for (let y = 0; y < HASH_H; y += 1) {
        for (let x = 0; x < HASH_W; x += 1) {
          const left = gray[y * (HASH_W + 1) + x];
          const right = gray[y * (HASH_W + 1) + x + 1];
          bits[index] = left < right ? 1 : 0;
          luminance[index] = left;
          sum += left;
          index += 1;
        }
      }
      return {
        hash: detector.bitsToHex(bits),
        hashBits: bits,
        brightness: sum / bits.length,
        luminance
      };
    },

    /** 16x16 灰度图，用于帧间 MAD */
    sampleCanvas(video, canvas) {
      const ctx = detector.prepare(canvas, SAMPLE_W, SAMPLE_H);
      ctx.drawImage(video, 0, 0, SAMPLE_W, SAMPLE_H);
      const data = ctx.getImageData(0, 0, SAMPLE_W, SAMPLE_H).data;
      const sample = new Uint8ClampedArray(SAMPLE_W * SAMPLE_H);
      for (let i = 0, p = 0; i < sample.length; i += 1, p += 4) {
        sample[i] = (data[p] * 299 + data[p + 1] * 587 + data[p + 2] * 114) / 1000;
      }
      return { sample };
    },

    prepare(canvas, width, height) {
      if (canvas.width !== width) canvas.width = width;
      if (canvas.height !== height) canvas.height = height;
      const ctx = canvas.getContext('2d', { alpha: false, willReadFrequently: true });
      ctx.imageSmoothingEnabled = true;
      if ('imageSmoothingQuality' in ctx) ctx.imageSmoothingQuality = 'high';
      return ctx;
    },

    bitsToHex(bits) {
      let hex = '';
      for (let i = 0; i < bits.length; i += 4) {
        const nibble = (bits[i] << 3) | (bits[i + 1] << 2) | (bits[i + 2] << 1) | bits[i + 3];
        hex += nibble.toString(16);
      }
      return hex;
    },

    hexToBits(hex) {
      const bits = new Uint8Array(HASH_W * HASH_H);
      let index = 0;
      for (let i = 0; i < hex.length && index + 3 < bits.length; i += 1) {
        const nibble = parseInt(hex[i], 16);
        if (Number.isNaN(nibble)) continue;
        bits[index] = (nibble >> 3) & 1;
        bits[index + 1] = (nibble >> 2) & 1;
        bits[index + 2] = (nibble >> 1) & 1;
        bits[index + 3] = nibble & 1;
        index += 4;
      }
      return bits;
    },

    /**
     * 比较两个签名。
     * @returns {{hashDistance:number, mad:number, change:number}}
     *   hashDistance：汉明距离 / 总位数（0~1）
     *   mad：灰度平均绝对差（0~1）
     *   change：两者取大，作为综合变化量
     */
    compare(prev, next) {
      if (!prev || !next) return { hashDistance: 1, mad: 1, change: 1 };
      const a = prev.hashBits || detector.hexToBits(prev.hash);
      const b = next.hashBits || detector.hexToBits(next.hash);
      const length = Math.min(a.length, b.length);
      let diff = 0;
      for (let i = 0; i < length; i += 1) diff += POPCOUNT[a[i] ^ b[i]];
      const hashDistance = length ? diff / length : 1;

      let mad = 0;
      if (prev.sample && next.sample) {
        const size = Math.min(prev.sample.length, next.sample.length);
        let sum = 0;
        for (let i = 0; i < size; i += 1) sum += Math.abs(prev.sample[i] - next.sample[i]);
        mad = size ? sum / size / 255 : 0;
      }
      return { hashDistance, mad, change: Math.max(hashDistance, mad) };
    },

    /**
     * 判断是否值得保存为关键帧。
     * @param {object|null} prev 上一张已保存关键帧的签名
     * @param {object} current 当前签名
     * @param {object} settings
     * @returns {{accept:boolean, reason:string, hashDistance:number, mad:number, change:number, similar:boolean}}
     */
    evaluate(prev, current, settings) {
      const metrics = detector.compare(prev, current);
      if (!prev) {
        return Object.assign({ accept: true, reason: '首个关键帧', similar: false }, metrics);
      }
      if (current.brightness <= 4) {
        return Object.assign({ accept: false, reason: '画面为纯黑（可能未开始播放）' }, metrics, { similar: false });
      }

      // 相似度去重：与「上一张已保存的帧」太像就不存。
      // 逐帧/定间隔模式下这类近重复会大量出现（同一场景被采样多次、只有解码噪声差异），
      // 光看阈值是拦不住的，必须显式设一条「最小变化量」底线。
      const minChange = Number(settings.minChange);
      if (Number.isFinite(minChange) && minChange > 0) {
        const similar = metrics.hashDistance < minChange && metrics.mad < minChange;
        if (similar) {
          return Object.assign(
            {
              accept: false,
              similar: true,
              reason: `与上一张几乎相同（Δ${(metrics.change * 100).toFixed(1)}% < ${(minChange * 100).toFixed(1)}%）`
            },
            metrics
          );
        }
      }

      const hashTrigger = metrics.hashDistance >= (settings.hashThreshold || 0.12);
      const madTrigger = metrics.mad >= (settings.madThreshold || 0.1);
      // 只有两项都明显变化才容易漏帧；任一明显变化即认为是场景切换，
      // 但要求「综合变化」也超过阈值，避免单点噪声误触发。
      const accept =
        (hashTrigger || madTrigger) &&
        metrics.change >= Math.min(settings.hashThreshold || 0.12, settings.madThreshold || 0.1);
      return Object.assign(
        { accept, similar: false, reason: accept ? '场景切换' : '画面变化不足' },
        metrics
      );
    }
  };

  NS.detector = detector;
})();

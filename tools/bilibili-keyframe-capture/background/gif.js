/**
 * gif.js —— 极简 GIF89a 动画编码器（无第三方依赖）
 *
 * 实现方式刻意做得「傻」一点，方便逐字节验证：
 *   1. 中位切分量化出全局调色板（取第一帧，最多 256 色）；
 *   2. 每帧把像素映射成调色板下标；
 *   3. 用 GIF 规范的 LZW 压缩，按 255 字节切子块；
 *   4. 所有输出都写进**一个** Uint8Array，最后只做一次 Blob。
 *      （不用 parts 数组 + 多次 push，避免任何一处长度算错都被悄悄吞掉）
 *
 * 每帧图像都带完整尺寸，且不做「帧间差分」，所以任何解码器都能正确显示。
 */
(function () {
  'use strict';

  const global = self;

  /* ---------------- 字节缓冲 ---------------- */

  function ByteBuffer(initialSize) {
    this.data = new Uint8Array(initialSize || 1024);
    this.length = 0;
  }
  ByteBuffer.prototype.ensure = function (extra) {
    if (this.length + extra <= this.data.length) return;
    let size = this.data.length * 2;
    while (size < this.length + extra) size *= 2;
    const next = new Uint8Array(size);
    next.set(this.data.subarray(0, this.length));
    this.data = next;
  };
  ByteBuffer.prototype.byte = function (value) {
    this.ensure(1);
    this.data[this.length] = value & 0xff;
    this.length += 1;
  };
  ByteBuffer.prototype.bytes = function (values) {
    this.ensure(values.length);
    for (let i = 0; i < values.length; i += 1) {
      this.data[this.length] = values[i] & 0xff;
      this.length += 1;
    }
  };
  ByteBuffer.prototype.uint16 = function (value) {
    this.byte(value & 0xff);
    this.byte((value >> 8) & 0xff);
  };
  ByteBuffer.prototype.text = function (string) {
    for (let i = 0; i < string.length; i += 1) this.byte(string.charCodeAt(i));
  };
  ByteBuffer.prototype.result = function () {
    return this.data.subarray(0, this.length);
  };

  /* ---------------- 中位切分量化 ---------------- */

  function channelRanges(box) {
    let minR = 255;
    let maxR = 0;
    let minG = 255;
    let maxG = 0;
    let minB = 255;
    let maxB = 0;
    for (const item of box) {
      if (item.r < minR) minR = item.r;
      if (item.r > maxR) maxR = item.r;
      if (item.g < minG) minG = item.g;
      if (item.g > maxG) maxG = item.g;
      if (item.b < minB) minB = item.b;
      if (item.b > maxB) maxB = item.b;
    }
    return { r: maxR - minR, g: maxG - minG, b: maxB - minB };
  }

  /** @returns {number[][]} [[r,g,b], ...]，至少 1 个颜色、最多 maxColors 个 */
  function quantize(pixels, maxColors) {
    const pixelCount = Math.floor(pixels.length / 4);
    const bins = new Map();
    const step = pixelCount > 200000 ? 3 : 1;
    for (let i = 0; i < pixelCount; i += step) {
      const p = i * 4;
      if (pixels[p + 3] < 8) continue;
      const r = pixels[p];
      const g = pixels[p + 1];
      const b = pixels[p + 2];
      const key = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3);
      const bin = bins.get(key);
      if (bin) {
        bin.count += 1;
        bin.r += r;
        bin.g += g;
        bin.b += b;
      } else {
        bins.set(key, { count: 1, r, g, b });
      }
    }
    let entries = [...bins.values()].map((bin) => ({
      count: bin.count,
      r: Math.round(bin.r / bin.count),
      g: Math.round(bin.g / bin.count),
      b: Math.round(bin.b / bin.count)
    }));
    if (!entries.length) entries = [{ count: 1, r: 0, g: 0, b: 0 }];
    if (entries.length <= maxColors) return entries.map((e) => [e.r, e.g, e.b]);

    const boxes = [entries];
    while (boxes.length < maxColors) {
      let bestIndex = -1;
      let bestRange = 0;
      let channel = 0;
      for (let i = 0; i < boxes.length; i += 1) {
        const box = boxes[i];
        if (box.length < 2) continue;
        const ranges = channelRanges(box);
        const max = Math.max(ranges.r, ranges.g, ranges.b);
        if (max > bestRange) {
          bestRange = max;
          bestIndex = i;
          channel = ranges.r >= ranges.g && ranges.r >= ranges.b ? 0 : (ranges.g >= ranges.b ? 1 : 2);
        }
      }
      if (bestIndex < 0 || bestRange === 0) break;
      const box = boxes[bestIndex];
      box.sort((a, b) => (channel === 0 ? a.r - b.r : channel === 1 ? a.g - b.g : a.b - b.b));
      const total = box.reduce((sum, item) => sum + item.count, 0);
      let acc = 0;
      let splitAt = 1;
      for (let i = 0; i < box.length; i += 1) {
        acc += box[i].count;
        if (acc >= total / 2) {
          splitAt = Math.max(1, Math.min(box.length - 1, i + 1));
          break;
        }
      }
      boxes.splice(bestIndex, 1, box.slice(0, splitAt), box.slice(splitAt));
    }
    return boxes.map((box) => {
      let count = 0;
      let r = 0;
      let g = 0;
      let b = 0;
      for (const item of box) {
        count += item.count;
        r += item.r * item.count;
        g += item.g * item.count;
        b += item.b * item.count;
      }
      return [Math.round(r / count), Math.round(g / count), Math.round(b / count)];
    });
  }

  /** 5/5/5 颜色 -> 调色板下标（带缓存，避免逐像素线性搜索） */
  function buildMapper(palette) {
    const cache = new Int16Array(32768).fill(-1);
    return function map(r, g, b) {
      const key = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3);
      const hit = cache[key];
      if (hit >= 0) return hit;
      let best = 0;
      let bestDistance = Infinity;
      for (let i = 0; i < palette.length; i += 1) {
        const color = palette[i];
        const dr = r - color[0];
        const dg = g - color[1];
        const db = b - color[2];
        const distance = dr * dr * 3 + dg * dg * 6 + db * db;
        if (distance < bestDistance) {
          bestDistance = distance;
          best = i;
          if (distance === 0) break;
        }
      }
      cache[key] = best;
      return best;
    };
  }

  /* ---------------- LZW ---------------- */

  /** @returns {number[]} 压缩后的字节数组（0~255） */
  function lzwEncode(indices, minCodeSize) {
    const clearCode = 1 << minCodeSize;
    const endCode = clearCode + 1;
    const out = [];
    let current = 0;
    let bits = 0;
    const push = (code, size) => {
      current |= code << bits;
      bits += size;
      while (bits >= 8) {
        out.push(current & 0xff);
        current >>= 8;
        bits -= 8;
      }
    };

    let codeSize = minCodeSize + 1;
    let nextCode = endCode + 1;
    let table = new Map();

    push(clearCode, codeSize);
    if (indices.length) {
      let prefix = indices[0];
      for (let i = 1; i < indices.length; i += 1) {
        const next = indices[i];
        const key = prefix * 4096 + next;
        const found = table.get(key);
        if (found !== undefined) {
          prefix = found;
          continue;
        }
        push(prefix, codeSize);
        if (nextCode < 4096) {
          table.set(key, nextCode);
          nextCode += 1;
          if (nextCode > (1 << codeSize) && codeSize < 12) codeSize += 1;
        } else {
          push(clearCode, codeSize);
          table = new Map();
          codeSize = minCodeSize + 1;
          nextCode = endCode + 1;
        }
        prefix = next;
      }
      push(prefix, codeSize);
    }
    push(endCode, codeSize);
    if (bits > 0) out.push(current & 0xff);
    return out;
  }

  /* ---------------- 组装 ---------------- */

  /**
   * @param {Array<{pixels:Uint8ClampedArray, width:number, height:number}>} frames
   * @param {object} options { fps, loop, maxColors }
   * @returns {Blob}
   */
  function encodeGif(frames, options) {
    if (!frames || !frames.length) throw new Error('没有可编码的帧');
    const opts = options || {};
    const width = frames[0].width;
    const height = frames[0].height;
    const fps = Math.min(50, Math.max(1, Number(opts.fps) || 8));
    // GIF 延时以 1/100 秒为单位；0/1 会被浏览器当成 10，所以最小取 2
    const delay = Math.max(2, Math.round(100 / fps));
    const maxColors = Math.min(256, Math.max(2, Number(opts.maxColors) || 256));
    const loop = Number.isFinite(opts.loop) ? opts.loop : 0;

    const palette = quantize(frames[0].pixels, maxColors);
    const map = buildMapper(palette);
    // 调色板大小必须是 2 的幂，且最小为 2
    let gctBits = 1;
    while (1 << gctBits < palette.length) gctBits += 1;
    const minCodeSize = Math.max(2, gctBits);

    const buffer = new ByteBuffer(1024 + frames.length * width * height);

    // 文件头 + 逻辑屏幕描述符
    buffer.text('GIF89a');
    buffer.uint16(width);
    buffer.uint16(height);
    // bit7 全局色表 | bit6-4 颜色深度 | bit3 无排序 | bit2-0 色表大小
    buffer.byte(0x80 | (gctBits - 1));
    buffer.byte(0); // 背景色索引
    buffer.byte(0); // 像素宽高比

    // 全局色表（补零到 2^gctBits 项）
    for (let i = 0; i < (1 << gctBits); i += 1) {
      const color = palette[i] || [0, 0, 0];
      buffer.byte(color[0]);
      buffer.byte(color[1]);
      buffer.byte(color[2]);
    }

    // Netscape 循环扩展
    buffer.byte(0x21);
    buffer.byte(0xff);
    buffer.byte(0x0b);
    buffer.text('NETSCAPE2.0');
    buffer.byte(0x03);
    buffer.byte(0x01);
    buffer.uint16(loop);
    buffer.byte(0x00);

    for (let index = 0; index < frames.length; index += 1) {
      const frame = frames[index];
      const pixelCount = frame.width * frame.height;
      const indices = new Uint8Array(pixelCount);
      for (let i = 0; i < pixelCount; i += 1) {
        const p = i * 4;
        indices[i] = frame.pixels[p + 3] < 8 ? 0 : map(frame.pixels[p], frame.pixels[p + 1], frame.pixels[p + 2]);
      }

      // 图形控制扩展：延时 + 不处置
      buffer.byte(0x21);
      buffer.byte(0xf9);
      buffer.byte(0x04);
      buffer.byte(0x00);
      buffer.uint16(delay);
      buffer.byte(0x00); // 透明色索引（未启用）
      buffer.byte(0x00); // 块结束

      // 图像描述符（无局部色表）
      buffer.byte(0x2c);
      buffer.uint16(0);
      buffer.uint16(0);
      buffer.uint16(frame.width);
      buffer.uint16(frame.height);
      buffer.byte(0x00);

      // LZW 图像数据，按 255 字节切子块
      buffer.byte(minCodeSize);
      const compressed = lzwEncode(indices, minCodeSize);
      for (let offset = 0; offset < compressed.length; offset += 255) {
        const size = Math.min(255, compressed.length - offset);
        buffer.byte(size);
        for (let i = 0; i < size; i += 1) buffer.byte(compressed[offset + i]);
      }
      buffer.byte(0x00); // 子块结束

      if (typeof opts.onProgress === 'function') opts.onProgress((index + 1) / frames.length);
    }

    buffer.byte(0x3b); // 文件结束
    return new Blob([buffer.result()], { type: 'image/gif' });
  }

  global.BKFgif = { encodeGif, quantize, lzwEncode, ByteBuffer };
})();

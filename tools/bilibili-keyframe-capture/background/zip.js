/**
 * zip.js —— 极简 ZIP 打包器（store 无压缩模式，无需第三方库）
 *
 * 关键帧本身已是 JPEG/PNG，再套一层 deflate 收益很小，所以统一用
 * store 模式，既快又不会让内存翻倍。
 */
(function () {
  'use strict';

  const global = self;

  const CRC_TABLE = (function build() {
    const table = new Uint32Array(256);
    for (let i = 0; i < 256; i += 1) {
      let c = i;
      for (let k = 0; k < 8; k += 1) {
        c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      }
      table[i] = c >>> 0;
    }
    return table;
  })();

  function crc32(bytes, seed) {
    let crc = (seed === undefined ? 0 : seed) ^ 0xffffffff;
    for (let i = 0; i < bytes.length; i += 1) {
      crc = (crc >>> 8) ^ CRC_TABLE[(crc ^ bytes[i]) & 0xff];
    }
    return (crc ^ 0xffffffff) >>> 0;
  }

  function utf8(text) {
    return new TextEncoder().encode(text);
  }

  function dosDateTime(date) {
    const d = date instanceof Date ? date : new Date();
    const year = Math.max(1980, d.getFullYear());
    const time =
      ((d.getHours() & 0x1f) << 11) | ((d.getMinutes() & 0x3f) << 5) | ((d.getSeconds() / 2) & 0x1f);
    const day = (((year - 1980) & 0x7f) << 9) | (((d.getMonth() + 1) & 0xf) << 5) | (d.getDate() & 0x1f);
    return { time, date: day };
  }

  function zip() {
    const parts = [];
    const entries = [];
    let offset = 0;
    const stamp = dosDateTime(new Date());

    function addFile(name, data, date) {
      const nameBytes = utf8(name);
      const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
      const crc = crc32(bytes);
      const when = dosDateTime(date || new Date());
      const header = new DataView(new ArrayBuffer(30));
      header.setUint32(0, 0x04034b50, true);      // 本地文件头签名
      header.setUint16(4, 20, true);              // 需要版本 2.0
      header.setUint16(6, 0x0800, true);          // 文件名为 UTF-8
      header.setUint16(8, 0, true);               // 压缩方式：store
      header.setUint16(10, when.time, true);
      header.setUint16(12, when.date, true);
      header.setUint32(14, crc, true);
      header.setUint32(18, bytes.length, true);   // 压缩后大小
      header.setUint32(22, bytes.length, true);   // 原始大小
      header.setUint16(26, nameBytes.length, true);
      header.setUint16(28, 0, true);              // 无扩展字段
      parts.push(new Uint8Array(header.buffer), nameBytes, bytes);
      entries.push({ nameBytes, crc, size: bytes.length, offset, time: when.time, date: when.date });
      offset += 30 + nameBytes.length + bytes.length;
    }

    function finish() {
      const centralStart = offset;
      for (const entry of entries) {
        const header = new DataView(new ArrayBuffer(46));
        header.setUint32(0, 0x02014b50, true);    // 中央目录签名
        header.setUint16(4, 20, true);
        header.setUint16(6, 20, true);
        header.setUint16(8, 0x0800, true);
        header.setUint16(10, 0, true);
        header.setUint16(12, entry.time, true);
        header.setUint16(14, entry.date, true);
        header.setUint32(16, entry.crc, true);
        header.setUint32(20, entry.size, true);
        header.setUint32(24, entry.size, true);
        header.setUint16(28, entry.nameBytes.length, true);
        header.setUint32(42, entry.offset, true);
        parts.push(new Uint8Array(header.buffer), entry.nameBytes);
        offset += 46 + entry.nameBytes.length;
      }
      const end = new DataView(new ArrayBuffer(22));
      end.setUint32(0, 0x06054b50, true);
      end.setUint16(8, entries.length, true);
      end.setUint16(10, entries.length, true);
      end.setUint32(12, offset - centralStart, true);
      end.setUint32(16, centralStart, true);
      parts.push(new Uint8Array(end.buffer));
      return new Blob(parts, { type: 'application/zip' });
    }

    return { addFile, finish, stamp, size: () => offset };
  }

  global.BKFzip = { crc32, zip };
})();

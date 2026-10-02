/**
 * db.js —— 后台 IndexedDB 存储层（仅 Service Worker 使用）
 *
 * 结构：
 *   sessions  会话（一个视频 / 分P = 一个会话）
 *   frames    关键帧（含全尺寸图 blob 与缩略图 dataURL）
 */
(function () {
  'use strict';

  const global = self;
  const DB_NAME = 'bilibili-keyframe-capture';
  const DB_VERSION = 2;
  const SESSION_STORE = 'sessions';
  const FRAME_STORE = 'frames';
  const HASH_STORE = 'hashes';

  let dbPromise = null;

  function openDb() {
    if (dbPromise) return dbPromise;
    dbPromise = new Promise((resolve, reject) => {
      const request = indexedDB.open(DB_NAME, DB_VERSION);
      request.onupgradeneeded = () => {
        const db = request.result;
        if (!db.objectStoreNames.contains(SESSION_STORE)) {
          const sessions = db.createObjectStore(SESSION_STORE, { keyPath: 'id' });
          sessions.createIndex('updatedAt', 'updatedAt', { unique: false });
        }
        if (!db.objectStoreNames.contains(FRAME_STORE)) {
          const frames = db.createObjectStore(FRAME_STORE, { keyPath: 'id' });
          frames.createIndex('sessionId', 'sessionId', { unique: false });
          frames.createIndex('createdAt', 'createdAt', { unique: false });
          frames.createIndex('session_time', ['sessionId', 'time'], { unique: false });
        }
        if (!db.objectStoreNames.contains(HASH_STORE)) {
          // 画面指纹索引：只存 { id: 'sessionKey|hash', sessionId, frameId }，
          // 用于 O(1) 判断「这张画面是否已经存过」，避免把带 blob 的整帧读出来
          const hashes = db.createObjectStore(HASH_STORE, { keyPath: 'id' });
          hashes.createIndex('sessionId', 'sessionId', { unique: false });
        }
      };
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error || new Error('打开数据库失败'));
    });
    return dbPromise;
  }

  async function tx(storeName, mode, work) {
    const db = await openDb();
    return new Promise((resolve, reject) => {
      const transaction = db.transaction(storeName, mode);
      let result;
      transaction.oncomplete = () => resolve(result);
      transaction.onerror = () => reject(transaction.error || new Error('数据库事务失败'));
      transaction.onabort = () => reject(transaction.error || new Error('数据库事务被中断'));
      try {
        const store = transaction.objectStore(storeName);
        result = work(store);
      } catch (error) {
        try {
          transaction.abort();
        } catch {
          /* 忽略 */
        }
        reject(error);
      }
    });
  }

  function req(request) {
    return new Promise((resolve, reject) => {
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error || new Error('数据库操作失败'));
    });
  }

  function dataUrlToBlob(dataUrl) {
    const comma = dataUrl.indexOf(',');
    const header = dataUrl.slice(0, comma);
    const body = dataUrl.slice(comma + 1);
    const type = (header.match(/data:([^;]+)/) || [])[1] || 'image/jpeg';
    if (/;base64/i.test(header)) {
      const binary = atob(body);
      const buffer = new Uint8Array(binary.length);
      for (let i = 0; i < binary.length; i += 1) buffer[i] = binary.charCodeAt(i);
      return new Blob([buffer], { type });
    }
    return new Blob([decodeURIComponent(body)], { type });
  }

  function extensionOf(blob, fallback) {
    if (blob && blob.type === 'image/png') return 'png';
    if (blob && blob.type === 'image/jpeg') return 'jpg';
    return fallback || 'jpg';
  }

  /**
   * 计算某个会话里哪些帧属于「重复」——纯函数，便于自测。
   * 规则：同一 dHash 指纹只保留「最晚保存」的那一张（与「重复写入不再入库」语义一致）；
   *       没有指纹的帧不参与去重，避免误删。
   * @param {Array<{id:string, hash:string, createdAt:number, bytes:number, time:number}>} records
   * @returns {{keep:string[], remove:Array, freedBytes:number}}
   */
  function planDuplicateRemoval(records) {
    const seen = new Map(); // hash -> 当前保留的帧
    const remove = [];
    for (const record of records || []) {
      const hash = record && record.hash;
      if (!hash) continue;
      const existing = seen.get(hash);
      if (!existing) {
        seen.set(hash, record);
        continue;
      }
      if ((record.createdAt || 0) >= (existing.createdAt || 0)) {
        remove.push(existing);
        seen.set(hash, record);
      } else {
        remove.push(record);
      }
    }
    return {
      keep: [...seen.values()].map((item) => item.id),
      remove,
      freedBytes: remove.reduce((sum, item) => sum + (item.bytes || 0), 0)
    };
  }

  const db = {
    async ensureSession(sessionKey, video) {
      const existing = await db.getSession(sessionKey);
      const now = Date.now();
      if (existing) {
        const patch = { updatedAt: now };
        if (video && video.title && !existing.title) patch.title = video.title;
        // 保留可回到播放页的地址（每次播放都刷新成最新地址）
        if (video && video.url) patch.url = video.url;
        const merged = Object.assign({}, existing, patch);
        await tx(SESSION_STORE, 'readwrite', (store) => store.put(merged));
        return merged;
      }
      const session = {
        id: sessionKey,
        title: (video && video.title) || sessionKey,
        author: (video && video.author) || '',
        url: (video && video.url) || '',
        bvid: (video && video.bvid) || '',
        cid: (video && video.cid) || '',
        page: (video && video.page) || 1,
        duration: (video && video.duration) || 0,
        frameCount: 0,
        bytes: 0,
        coverThumb: '',
        createdAt: now,
        updatedAt: now
      };
      await tx(SESSION_STORE, 'readwrite', (store) => store.put(session));
      return session;
    },

    async listSessions() {
      const list = await tx(SESSION_STORE, 'readonly', (store) => req(store.getAll()));
      return (list || []).sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0));
    },

    async getSession(sessionKey) {
      const database = await openDb();
      const store = database.transaction(SESSION_STORE, 'readonly').objectStore(SESSION_STORE);
      return req(store.get(sessionKey));
    },

    async sessionStats(sessionKey) {
      const session = await db.getSession(sessionKey);
      if (!session) return { frameCount: 0, bytes: 0, missing: true };
      return {
        frameCount: session.frameCount || 0,
        bytes: session.bytes || 0,
        title: session.title,
        updatedAt: session.updatedAt
      };
    },

    /**
     * 会话内某个「画面指纹」是否已经存过（走 hashes 索引，O(1)）。
     * 这是去重的最后一道防线：内容脚本那边已按相似度挡过一轮，
     * 这里再按完全相同的 dHash 兜一次，避免多遍播放 / 多次触发产生重复图。
     */
    async findByHash(sessionKey, hash) {
      if (!hash) return { duplicate: false, record: null };
      const database = await openDb();
      const store = database.transaction(HASH_STORE, 'readonly').objectStore(HASH_STORE);
      const entry = await req(store.get(`${sessionKey}|${hash}`));
      return { duplicate: !!entry, record: entry || null };
    },

    async indexHash(sessionKey, hash, frameId) {
      if (!hash) return;
      await tx(HASH_STORE, 'readwrite', (store) =>
        store.put({ id: `${sessionKey}|${hash}`, sessionId: sessionKey, hash, frameId })
      );
    },

    async unindexHash(sessionKey, hash) {
      if (!hash) return;
      await tx(HASH_STORE, 'readwrite', (store) => store.delete(`${sessionKey}|${hash}`));
    },

    /** 删除整个会话的指纹索引 */
    async unindexSession(sessionKey) {
      const database = await openDb();
      const index = database
        .transaction(HASH_STORE, 'readonly')
        .objectStore(HASH_STORE)
        .index('sessionId');
      const keys = await req(index.getAllKeys(sessionKey));
      for (const key of keys || []) {
        await tx(HASH_STORE, 'readwrite', (store) => store.delete(key));
      }
      return { removed: (keys || []).length };
    },

    /**
     * 写入一帧。payload 来自内容脚本：{ sessionKey, time, hash, imageDataUrl, thumbnailDataUrl, ... }
     */
    async addFrame(payload, limits) {
      const session = (await db.getSession(payload.sessionKey)) ||
        (await db.ensureSession(payload.sessionKey, payload.video));
      const max = (limits && limits.maxFramesPerSession) || 300;
      if ((session.frameCount || 0) >= max) {
        return { stored: false, reachedLimit: true, frameCount: session.frameCount, sessionId: session.id };
      }

      // 同一画面已经存过：不再占空间
      if (payload.hash) {
        const existing = await db.findByHash(session.id, payload.hash);
        if (existing.duplicate) {
          return {
            stored: false,
            duplicate: true,
            reason: '同一画面已保存过（指纹重复）',
            frameCount: session.frameCount || 0,
            sessionId: session.id
          };
        }
      }

      const blob = dataUrlToBlob(payload.imageDataUrl);
      const createdAt = Date.now();
      const seq = (session.frameCount || 0) + 1;
      const record = {
        id: `${session.id}_${String(Math.round((payload.time || 0) * 1000)).padStart(9, '0')}_${payload.hash || seq}`,
        sessionId: session.id,
        time: Math.round((payload.time || 0) * 1000) / 1000,
        hash: payload.hash || '',
        name: '',
        width: payload.width || 0,
        height: payload.height || 0,
        format: extensionOf(blob, 'jpg'),
        bytes: blob.size,
        thumbnail: payload.thumbnailDataUrl || '',
        blob,
        detection: payload.detection || null,
        pass: payload.pass || 1,
        video: payload.video || null,
        createdAt,
        seq
      };
      record.name = `${String(seq).padStart(3, '0')}_${record.id.split('_')[1]}`;

      await tx(FRAME_STORE, 'readwrite', (store) => store.put(record));
      // 同步维护指纹索引，供后续去重使用（缺了这一步，去重就形同虚设）
      if (record.hash) await db.indexHash(session.id, record.hash, record.id);

      session.frameCount = seq;
      session.bytes = (session.bytes || 0) + blob.size;
      session.updatedAt = createdAt;
      if (!session.coverThumb && record.thumbnail) session.coverThumb = record.thumbnail;
      if (payload.video && payload.video.title) session.title = payload.video.title;
      await tx(SESSION_STORE, 'readwrite', (store) => store.put(session));

      const fullIds = await db.frameIdsOf(payload.sessionKey);
      return {
        stored: true,
        frameId: record.id,
        time: record.time,
        frameCount: session.frameCount,
        bytes: record.bytes,
        almostFull: session.frameCount >= Math.max(1, max - 5),
        reachedLimit: session.frameCount >= max,
        sessionId: session.id,
        frameIds: fullIds
      };
    },

    async frameIdsOf(sessionKey) {
      const database = await openDb();
      const index = database
        .transaction(FRAME_STORE, 'readonly')
        .objectStore(FRAME_STORE)
        .index('sessionId');
      const keys = await req(index.getAllKeys(sessionKey));
      return (keys || []).sort();
    },

    /** 分页读取会话内的帧（按时间升序），只返回缩略图与元数据 */
    async listFrames(sessionKey, offset, limit) {
      const database = await openDb();
      const index = database
        .transaction(FRAME_STORE, 'readonly')
        .objectStore(FRAME_STORE)
        .index('sessionId');
      const keys = (await req(index.getAllKeys(sessionKey)) || []).sort();
      const slice = keys.slice(offset || 0, (offset || 0) + (limit || 100));
      const frames = [];
      for (const key of slice) {
        const record = await db.getFrame(key);
        if (!record) continue;
        frames.push({
          id: record.id,
          sessionId: record.sessionId,
          time: record.time,
          name: record.name,
          width: record.width,
          height: record.height,
          bytes: record.bytes,
          format: record.format,
          hash: record.hash,
          thumbnail: record.thumbnail,
          detection: record.detection,
          pass: record.pass || 1,
          // 原始播放页地址：方便日后从图库直接回到该视频页继续播放
          sourceUrl: (record.video && record.video.url) || '',
          createdAt: record.createdAt,
          seq: record.seq
        });
      }
      return { frames, total: keys.length, hasMore: offset + slice.length < keys.length };
    },

    async getFrame(frameId) {
      const database = await openDb();
      const store = database.transaction(FRAME_STORE, 'readonly').objectStore(FRAME_STORE);
      return req(store.get(frameId));
    },

    async getFrames(frameIds) {
      const out = [];
      for (const id of frameIds || []) {
        const record = await db.getFrame(id);
        if (record) out.push(record);
      }
      out.sort((a, b) => a.time - b.time);
      return out;
    },

    async updateFrame(frameId, patch) {
      const record = await db.getFrame(frameId);
      if (!record) throw new Error('帧不存在');
      Object.assign(record, patch || {});
      await tx(FRAME_STORE, 'readwrite', (store) => store.put(record));
      return { id: frameId, name: record.name };
    },

    /**
     * 删除会话内的重复帧：同一 dHash 指纹只保留「最晚保存」的那一张。
     * 注意不动 hashes 索引 —— 每个指纹保留一张，索引项依然正确。
     * @returns {Promise<{removed:number, kept:number, time:number}>}
     */
    async pruneDuplicates(sessionId) {
      const keys = await db.frameIdsOf(sessionId);
      const records = [];
      for (const key of keys) {
        const record = await db.getFrame(key);
        if (record) records.push(record);
      }
      const plan = planDuplicateRemoval(records);
      if (!plan.remove.length) return { removed: 0, kept: plan.keep.length, time: 0 };

      const session = await db.getSession(sessionId);
      let lastTime = 0;
      for (const item of plan.remove) {
        await tx(FRAME_STORE, 'readwrite', (store) => store.delete(item.id));
        lastTime = Math.max(lastTime, item.time || 0);
      }
      if (session) {
        session.frameCount = Math.max(0, (session.frameCount || 0) - plan.remove.length);
        session.bytes = Math.max(0, (session.bytes || 0) - plan.freedBytes);
        session.updatedAt = Date.now();
        if (!session.coverThumb) await db.repairSessionCover(sessionId);
        await tx(SESSION_STORE, 'readwrite', (store) => store.put(session));
      }
      return {
        removed: plan.remove.length,
        kept: plan.keep.length,
        freedBytes: plan.freedBytes,
        time: lastTime
      };
    },

    async deleteFrames(frameIds) {
      const database = await openDb();
      let removed = 0;
      const touched = new Set();
      for (const id of frameIds || []) {
        const record = await db.getFrame(id);
        if (!record) continue;
        await tx(FRAME_STORE, 'readwrite', (store) => store.delete(id));
        if (record.hash) await db.unindexHash(record.sessionId, record.hash);
        removed += 1;
        touched.add(record.sessionId);
        const session = await db.getSession(record.sessionId);
        if (session) {
          session.frameCount = Math.max(0, (session.frameCount || 0) - 1);
          session.bytes = Math.max(0, (session.bytes || 0) - (record.bytes || 0));
          session.updatedAt = Date.now();
          if (session.coverThumb === record.thumbnail) session.coverThumb = '';
          await tx(SESSION_STORE, 'readwrite', (store) => store.put(session));
        }
      }
      for (const sessionId of touched) await db.repairSessionCover(sessionId);
      return { removed, sessions: [...touched] };
    },

    /** 删除后修正封面缩略图 */
    async repairSessionCover(sessionId) {
      const session = await db.getSession(sessionId);
      if (!session || session.coverThumb) return;
      const list = await db.listFrames(sessionId, 0, 1);
      if (list.frames.length && list.frames[0].thumbnail) {
        session.coverThumb = list.frames[0].thumbnail;
        await tx(SESSION_STORE, 'readwrite', (store) => store.put(session));
      }
    },

    async deleteSession(sessionId) {
      const keys = await db.frameIdsOf(sessionId);
      for (const key of keys) {
        await tx(FRAME_STORE, 'readwrite', (store) => store.delete(key));
      }
      await db.unindexSession(sessionId);
      await tx(SESSION_STORE, 'readwrite', (store) => store.delete(sessionId));
      return { removed: keys.length };
    },

    async cleanup(validSessionIds) {
      const sessions = await db.listSessions();
      let removedSessions = 0;
      let indexed = 0;
      for (const session of sessions) {
        const keys = await db.frameIdsOf(session.id);
        const known = validSessionIds && validSessionIds.has(session.id);
        if (!keys.length && (known || session.frameCount === 0)) {
          await db.unindexSession(session.id);
          await tx(SESSION_STORE, 'readwrite', (store) => store.delete(session.id));
          removedSessions += 1;
          continue;
        }
        if (session.frameCount !== keys.length) {
          session.frameCount = keys.length;
          await tx(SESSION_STORE, 'readwrite', (store) => store.put(session));
        }
        // 补建缺失的指纹索引（老版本数据库升级上来时索引是空的）
        if (!session.hashesIndexed) {
          for (const key of keys) {
            const record = await db.getFrame(key);
            if (!record || !record.hash) continue;
            const found = await db.findByHash(session.id, record.hash);
            if (!found.duplicate) {
              await db.indexHash(session.id, record.hash, record.id);
              indexed += 1;
            }
          }
          session.hashesIndexed = true;
          await tx(SESSION_STORE, 'readwrite', (store) => store.put(session));
        }
      }
      return { removedSessions, indexed };
    },

    async usage() {
      const sessions = await db.listSessions();
      const frames = sessions.reduce((sum, s) => sum + (s.frameCount || 0), 0);
      const bytes = sessions.reduce((sum, s) => sum + (s.bytes || 0), 0);
      return { sessions: sessions.length, frames, bytes };
    }
  };

  global.BKFdb = db;
  global.BKFplanDuplicates = planDuplicateRemoval;
})();

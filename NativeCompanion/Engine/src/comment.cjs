'use strict';

async function routeComment(body, providerFor) {
    const raw = body.songInfo || {};
    const song = {...raw.meta, ...raw};
    const source = raw.source || raw.meta?.source;
    const label = {kw:'酷我', kg:'酷狗', tx:'QQ 音乐', wy:'网易云', mg:'咪咕'}[source];
    if (typeof label !== 'string' || raw.isLocal && !raw.offlineId)
        return {error:'这首歌的音源不提供评论', code:'unsupported'};

    const identifier = value => String(value ?? '').trim().replace(new RegExp('^' + source + '[_:]'), '');
    song.source = source;
    song.songmid = identifier(raw.songmid || raw.meta?.songmid || raw.mid || raw.meta?.mid ||
        (source !== 'tx' && (raw.songId || raw.meta?.songId)) || raw.id);
    if (song.songId) song.songId = identifier(song.songId);
    if (song.copyrightId) song.copyrightId = identifier(song.copyrightId);
    if (source === 'kg') song.hash = identifier(song.hash || song.songmid);
    if (!(source === 'kg' ? song.hash : song.songmid || song.songId || song.copyrightId))
        return {error:'缺少歌曲编号，无法查询评论', code:'missing-id'};

    const method = body.type === 'hot' ? 'getHotComment' : 'getComment';
    const page = Math.max(1, Math.min(1000, Math.floor(Number(body.page) || 1)));
    const limit = Math.max(1, Math.min(100, Math.floor(Number(body.limit) || 20)));
    try {
        const provider = providerFor(song).comment;
        if (!provider?.[method]) return {error:label + '暂不提供此类评论', code:'unsupported'};
        // Provider implementations cancel their previous request on the same instance.
        const client = Object.create(provider);
        client._requestObj = client._requestObj2 = client._requestObj3 = null;
        if (provider.lastCommentIds instanceof Map) {
            const cacheKey = source + ':' + (song.songId || song.copyrightId || song.songmid);
            let cursors = commentCursors.get(cacheKey);
            if (!cursors) {
                if (commentCursors.size >= 20) commentCursors.delete(commentCursors.keys().next().value);
                cursors = new Map();
                commentCursors.set(cacheKey, cursors);
            }
            client.lastCommentIds = new Map(cursors);
            const result = await client[method](song, page, limit);
            for (const [key, cursor] of client.lastCommentIds) cursors.set(key, cursor);
            return result;
        }
        const result = await client[method](song, page, limit);
        if (Array.isArray(result?.comments)) return result;
    } catch (error) {
        if (error?.name === 'AbortError') throw error;
    }
    return {error:label + '评论暂时不可用，请稍后重试', code:'provider-unavailable',
        request:{songInfo:{source, songmid:song.songmid, songId:song.songId, hash:song.hash,
            copyrightId:song.copyrightId, albumId:song.albumId}, type:body.type, page, limit}};
}
const commentCursors = new Map();

if (typeof module !== 'undefined' && module.exports) module.exports = routeComment;

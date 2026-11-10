'use strict';

const sourceQualityOrder = ['master', 'atmos_plus', 'atmos', 'hires', 'flac24bit', 'flac', '320k', '192k', '128k'];

function runImportedMusicSource(script, lx, requireModule, buffer) {
    const scope = Object.create(globalThis);
    const quiet = () => {};
    const sourceConsole = {log: quiet, info: quiet, debug: quiet, warn: quiet, error: quiet, time: quiet, timeEnd: quiet};
    Object.assign(scope, {lx, require: requireModule, Buffer: buffer, console: sourceConsole, globalThis: scope, window: scope, self: scope, global: scope});
    // Keep the LX object available to asynchronous handlers from this script.
    const execute = new Function('lx', 'require', 'Buffer', 'console', 'globalThis', 'window', 'self', 'global',
        'return (function () {\n' + script + '\n}).call(globalThis);\n//# sourceURL=imported-music-source.js');
    return execute(lx, requireModule, buffer, sourceConsole, scope, scope, scope, scope);
}

function localSourceQualities(supported, preferred, allowFallback) {
    const declared = Array.isArray(supported) ? supported : ['128k', '320k', 'flac'];
    if (!declared.length) return [preferred];
    if (!allowFallback) return declared.includes(preferred) ? [preferred] : [];
    const index = sourceQualityOrder.indexOf(preferred);
    const order = index < 0 ? sourceQualityOrder : [...sourceQualityOrder.slice(index + 1), ...sourceQualityOrder.slice(0, index)];
    return [...new Set([preferred, ...order, ...declared])].filter(quality => declared.includes(quality));
}

function localSourceAudio(result, requested, sourceId) {
    const data = result?.data;
    let url = '';
    for (const candidate of [result, result?.url, data?.url, result?.musicUrl, result?.playUrl, result?.src, data, result?.[0]]) {
        if (typeof candidate !== 'string') continue;
        const address = candidate.trim().replace(/&amp;/g, '&');
        if (address.startsWith('//')) { url = 'https:' + address; break; }
        if (/^https?:\/\//i.test(address)) { url = address; break; }
    }
    if (!url) throw new Error('音源没有返回有效的播放地址');
    const quality = [result?.type, result?.quality, data?.type, data?.quality].find(value => typeof value === 'string' && value) || '';
    const requestedRank = sourceQualityOrder.indexOf(requested), actualRank = sourceQualityOrder.indexOf(quality);
    const compressed = /\.(mp3|m4a|aac|ogg|opus)$/.test(new URL(url).pathname.toLowerCase());
    if (requestedRank >= 0 && actualRank > requestedRank || ['flac', 'flac24bit'].includes(requested) && compressed) {
        throw new Error('音源返回的实际格式或音质低于请求档位');
    }
    return {url, type: quality || requested, qualityReported: !!quality, sourceId};
}

if (typeof module !== 'undefined') module.exports = {runImportedMusicSource, localSourceQualities, localSourceAudio};

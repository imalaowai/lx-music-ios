"""Phone-specific changes to the verified, shared WebUI snapshot."""


def replace(html, old, new):
    assert html.count(old) == 1, f'WebUI anchor changed: {old[:85]}'
    return html.replace(old, new, 1)


def patch_web_ui(html):
    html = replace(html, '    const ListStore = {', """    function ownedListKey(owner) { return LIST_KEY + ':' + owner; }
    const ListStore = {""")
    html = replace(html, '            return idbGet(LIST_KEY);', """            const owner = localStorage.getItem('lx_sync_user');
            if (!window.LXBridge || !owner) return idbGet(LIST_KEY);
            return idbGet(ownedListKey(owner)).then(async data => {
                if (data) return data;
                const legacy = await idbGet(LIST_KEY);
                if (legacy?.username === owner || (legacy && !legacy.username && owner === '__device__'))
                    return {...legacy, username:owner};
                return null;
            });""")
    html = replace(html, '            return idbSet(LIST_KEY, data);', """            const owner = localStorage.getItem('lx_sync_user');
            if (window.LXBridge && owner) return idbSet(ownedListKey(owner), {...data, username:owner});
            return idbSet(LIST_KEY, data);""")
    html = replace(html, '            return idbDelete(LIST_KEY);', """            const owner = localStorage.getItem('lx_sync_user');
            if (window.LXBridge && owner) return idbDelete(ownedListKey(owner));
            return idbDelete(LIST_KEY);""")
    html = replace(html, 'async function ensureUserAuthToken(options = {}) {',
                   """async function ensureUserAuthToken(options = {}) {
    if (window.LXBridge) {
        const account = await window.LXBridge.accountReady?.catch(() => null);
        return options.force !== true && !!account?.token;
    }""")
    html = replace(html, 'function savePlaybackState() {', 'function savePlaybackState() {\n    if (window.LXBridge) return;')
    html = replace(html, 'async function restorePlaybackState() {', 'async function restorePlaybackState() {\n    if (window.LXBridge) return;')
    html = replace(html, "const button=$('mobile-mini-play'),playing=!audio.paused;",
                   """const paused=window.LXBridge?.getPlayback().paused ?? audio.paused;
  const button=$('mobile-mini-play'),playing=!paused;""")
    html = replace(html, '    // 1. Restore cached list data (from IndexedDB) for logged in user only',
                   '    if (window.LXBridge) return;\n\n    // 1. Restore cached list data (from IndexedDB) for logged in user only')
    html = replace(html, '        // [Fix] Auto-Login logic (Restore Session)',
                   '        if (window.LXBridge) return;\n\n        // [Fix] Auto-Login logic (Restore Session)')
    html = replace(html, 'if (isHidden) {\n        renderQueue();\n        drawer.classList.remove', 'if (isHidden) {\n        renderQueue(true);\n        drawer.classList.remove')
    html = replace(html, 'function renderQueue() {',
                   "function renderQueue(force = false) {\n    if (!force && document.getElementById('queue-drawer')?.classList.contains('translate-x-full')) return;")
    html = replace(html, '                 onclick="playSongFromQueue(${index})">', '                 data-queue-index="${index}" onclick="playSongFromQueue(${index})">')
    html = replace(html, "                showInfo('播放顺序已更新');",
                   "                window.ListenRoom?.sendRoomState?.('queue', 'user');\n                showInfo('播放顺序已更新');")
    html = replace(html, "async function doSearch(page = 1, append = false, prefetch = false) {",
                   """let searchRequest = 0;
async function doSearch(page = 1, append = false, prefetch = false) {
    const request = ++searchRequest;
    const scope = currentSearchScope;""")
    html = replace(html, '    // Network Search Logic\n    const source = document.getElementById(\'search-source\').value;',
                   """    // Network Search Logic
    const source = document.getElementById('search-source').value;
    const current = () => request === searchRequest && scope === currentSearchScope &&
        input === document.getElementById('search-input').value.trim() &&
        source === document.getElementById('search-source').value && type === (typeEl?.value || 'song');""")
    html = replace(html, '        // song/singer/album 统一支持 append 追加翻页',
                   '        if (!current()) return;\n\n        // song/singer/album 统一支持 append 追加翻页')
    html = replace(html, "        console.error('[Search] 搜索失败:', e);",
                   "        if (!current()) return;\n        console.error('[Search] 搜索失败:', e);")
    html = replace(html, '            resultsContainer.innerHTML = `<div class="text-center text-red-500 p-8">搜索出错: ${e.message}</div>`;',
                   "            const error = document.createElement('div');\n            error.className = 'text-center text-red-500 p-8';\n            error.textContent = '搜索出错：' + e.message;\n            resultsContainer.replaceChildren(error);")
    html = replace(html, 'let isCommentLoading = false;',
                   '''let commentRequest = 0;
let commentOpen = false;
function commentSongKey(song) {
    return JSON.stringify([song?.source || song?.meta?.source, song?.offlineId,
        song?.songmid || song?.meta?.songmid || song?.hash || song?.meta?.hash ||
        song?.songId || song?.meta?.songId || song?.id]);
}''')
    html = replace(html, "    const isHidden = modal.classList.contains('hidden');\n\n    if (isHidden) {\n        // 打开",
                   "    if (!commentOpen) {\n        commentOpen = true;\n        // 打开")
    html = replace(html, '            const songId = song.songmid || song.hash || song.id;', '            const songId = commentSongKey(song);')
    html = replace(html, "    } else {\n        // 关闭\n        content.classList.remove('translate-y-0', 'opacity-100');",
                   "    } else {\n        commentOpen = false; commentRequest++;\n        content.classList.remove('translate-y-0', 'opacity-100');")
    html = replace(html, "        setTimeout(() => {\n            modal.classList.add('hidden');\n            modal.classList.remove('flex');\n        }, 300);\n    }\n}\n\nasync function switchCommentType",
                   "        setTimeout(() => {\n            if (commentOpen) return;\n            modal.classList.add('hidden');\n            modal.classList.remove('flex');\n        }, 300);\n    }\n}\n\nasync function switchCommentType")
    html = replace(html, '    if (newPage < 1 || isCommentLoading) return;',
                   '    if (newPage < 1 || newPage > commentCache[currentCommentType].maxPage) return;')
    start = html.index('async function fetchComments() {')
    end = html.index('function updatePaginationUI(', start)
    html = html[:start] + '''function syncCommentSong() {
    if (!commentOpen) return;
    const key = commentSongKey(getActiveSongInfo());
    if (lastCommentSongId === key) return;
    lastCommentSongId = key;
    refreshComments();
}

async function fetchComments() {
    const song = getActiveSongInfo(), songKey = commentSongKey(song);
    const type = currentCommentType, page = currentCommentPage, request = ++commentRequest;
    const current = () => commentOpen && request === commentRequest && songKey === commentSongKey(getActiveSongInfo());
    const loader = document.getElementById('comment-loader'), list = document.getElementById('comment-list');
    list.replaceChildren();
    if (!song) {
        loader.classList.add('hidden');
        list.textContent = '请先播放歌曲';
        return;
    }
    const cache = commentCache[type], cached = cache.pages[page];
    document.getElementById('comment-title').textContent = song.name + ' · 评论';
    document.getElementById('comment-source-info').textContent = String(song.source || song.meta?.source || '').toUpperCase();
    if (cached) {
        renderComments(cached);
        updateCommentCountLabels(cache.total);
        updatePaginationUI(cache.total, cache.maxPage);
        loader.classList.add('hidden');
        return;
    }

    loader.classList.remove('hidden');
    document.getElementById('comment-page-indicator').textContent = '加载中…';
    try {
        const response = await fetch('/api/music/comment', {
            method: 'POST', headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({songInfo: song, type, page, limit: 20})
        });
        const data = await response.json().catch(() => ({}));
        if (!current()) return;
        if (!response.ok || !Array.isArray(data.comments)) throw new Error(data.message || data.error || '评论暂时不可用，请稍后重试');
        cache.pages[page] = data.comments;
        cache.total = data.total;
        cache.maxPage = data.maxPage || Math.ceil((data.total || 0) / 20) || 1;
        renderComments(data.comments);
        updateCommentCountLabels(cache.total);
        updatePaginationUI(cache.total, cache.maxPage);
    } catch (error) {
        if (!current()) return;
        const message = document.createElement('p');
        message.className = 'text-center py-10 text-red-400 font-bold';
        message.textContent = error.message;
        const retry = document.createElement('button');
        retry.type = 'button';
        retry.className = 'apple-secondary';
        retry.textContent = '重试';
        retry.onclick = fetchComments;
        list.replaceChildren(message, retry);
        updatePaginationUI(cache.total, Math.max(page, cache.maxPage));
    } finally {
        if (current()) loader.classList.add('hidden');
    }
}

''' + html[end:]
    html = replace(html, 'function createCommentItemHTML(comment, isReply = false) {', """const escapeComment = value => String(value ?? '').replace(/[&<>"']/g, character =>
    ({'&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;'})[character]);
const commentImage = value => typeof value === 'string' && /^https?:\\/\\//i.test(value);

function createCommentItemHTML(comment, isReply = false) {""")
    html = replace(html, '    const avatar = comment.avatar || defaultAvatar;',
                   "    const avatar = commentImage(comment.avatar) ? escapeComment(comment.avatar) : defaultAvatar;")
    html = replace(html, '    if (comment.reply && comment.reply.length > 0) {',
                   '    if (!isReply && Array.isArray(comment.reply) && comment.reply.length > 0) {')
    html = replace(html, '${comment.userName}</span>', '${escapeComment(comment.userName)}</span>')
    html = replace(html, '${comment.likedCount || 0}</span>', '${Number(comment.likedCount) || 0}</span>')
    html = replace(html, '${comment.text}</p>', '${escapeComment(comment.text)}</p>')
    html = replace(html, '${timeStr}${location}</span>', '${escapeComment(timeStr + location)}</span>')
    html = replace(html, '${comment.images && comment.images.length > 0 ? `',
                   '${Array.isArray(comment.images) && comment.images.some(commentImage) ? `')
    html = replace(html, '${comment.images.map(img => `',
                   '${comment.images.filter(commentImage).map(img => `')
    html = replace(html, '<img src="${img}" \n                                 loading="lazy"',
                   '<a href="${escapeComment(img)}" target="_blank" rel="noopener noreferrer"><img src="${escapeComment(img)}" \n                                 loading="lazy"')
    html = replace(html, """                                 onclick="window.open('${img}', '_blank')"
                                 onerror="this.style.display='none'">""",
                   """                                 onerror="this.style.display='none'"></a>""")
    return html

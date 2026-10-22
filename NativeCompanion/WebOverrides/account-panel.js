(function () {
    'use strict';
    const $ = id => document.getElementById(id);
    const esc = value => String(value ?? '').replace(/[&<>"']/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
    const person = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><circle cx="12" cy="8" r="3.5"/><path d="M5 21v-2a7 7 0 0 1 14 0v2"/></svg>';
    let profileIdentity='', generation = 0, profile = null, activity = [], page = 0, avatar = '', returnFocus = null;
    function avatarHtml(value, label = '') {
        const src = String(value || '');
        const safe = /^https?:\/\//i.test(src) || /^data:image\/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$/.test(src);
        return safe ? `<img src="${esc(src)}" alt="${esc(label)}" loading="lazy" referrerpolicy="no-referrer">` : person;
    }
    const identity = () => JSON.stringify(window.getUserAuthHeaders?.() || {});
    async function request(url, options = {}, key = identity()) {
        const response = await fetch(url, {...options, cache:'no-store', headers:{'Content-Type':'application/json',...window.getUserAuthHeaders?.(),...options.headers}});
        const data = await response.json();
        if (key !== identity() && !(url==='/api/user/password' && response.ok && data.success && data.reauthenticate)) throw new Error('账号已切换，请重新打开资料');
        if (!response.ok || data.success === false) throw new Error(data.message || '请求失败');
        return data;
    }
    function renderHeader() {
        mountHeader();renderAccountButton();
        const target = $('header-avatar-image'); if (target) {const html=avatarHtml(profile?.avatar);if(target.innerHTML!==html)target.innerHTML=html;}
        const button = $('header-user-display');
        if (button) button.title = profile?.nickname ? `${profile.nickname} · 个人资料` : '个人资料';
    }
    async function refresh() {
        const current = ++generation, key = identity();
        if(profileIdentity!==key){profileIdentity=key;profile=null;renderHeader();}
        if (!window.getUserAuthHeaders?.()['x-user-token']) return;
        try {
            const data = await request('/api/user/profile',{},key);
            if (current !== generation || key !== identity()) return;
            const changed=JSON.stringify(profile)!==JSON.stringify(data.profile);profile = data.profile; renderHeader();
            if(changed)window.dispatchEvent(new CustomEvent('lx-profile-change',{detail:profile}));
        } catch (error) { if (current === generation) console.warn('[Profile]',error.message); }
    }
    function records() {
        const time = value => value ? new Date(value).toLocaleString() : '—';
        const body = $('account-history'); if (!body) return;
        body.innerHTML = activity.slice(page*15,page*15+15).map(row => `<tr><td>${esc(row.deviceName || row.deviceId || '旧记录')}</td><td>${esc(row.source)}</td><td>${esc(time(row.loginAt))}</td><td>${esc(time(row.logoutAt))}</td></tr>`).join('') || '<tr><td colspan="4">暂无登录记录</td></tr>';
        $('account-page').textContent = `${page+1} / ${Math.max(1,Math.ceil(activity.length/15))}`;
        $('account-prev').disabled = page === 0; $('account-next').disabled = (page+1)*15 >= activity.length;
    }
    function close() { $('account-panel')?.remove(); returnFocus?.focus?.(); }
    async function cropImage(file) {
        if (!['image/png','image/jpeg','image/webp'].includes(file.type) || file.size > 20*1024*1024) throw new Error('请选择 20MB 以内的 PNG、JPEG 或 WebP 图片');
        const url = URL.createObjectURL(file);
        try {
            const img = new Image(); img.src = url; await img.decode();
            if (!img.naturalWidth || !img.naturalHeight) throw new Error('无法读取图片');
            const canvas = document.createElement('canvas'); canvas.width = canvas.height = 320;
            const size = Math.min(img.naturalWidth,img.naturalHeight);
            canvas.getContext('2d').drawImage(img,(img.naturalWidth-size)/2,(img.naturalHeight-size)/2,size,size,0,0,320,320);
            return canvas.toDataURL('image/webp',0.85);
        } finally { URL.revokeObjectURL(url); }
    }
    async function open(options = {}) {
        const key = identity(), current = generation;
        if (!window.getUserAuthHeaders?.()['x-user-token']) { window.showInfo?.('请先登录账号'); return; }
        returnFocus = document.activeElement;
        try {
            const [p,a] = await Promise.all([request('/api/user/profile',{},key),request('/api/user/activity',{},key)]);
            if (key !== identity() || current !== generation) return;
            profile = p.profile; avatar = profile.avatar || ''; activity = a.activity.records || []; page = 0;
            close();
            const modal = document.createElement('div'); modal.id = 'account-panel'; modal.className = 'apple-dialog-backdrop';
            modal.setAttribute('role','dialog'); modal.setAttribute('aria-modal','true'); modal.setAttribute('aria-labelledby','account-title');
            modal.innerHTML = `<section class="apple-sheet account-sheet">
                <div class="sheet-header"><div><p class="apple-eyebrow">你的音乐身份</p><h2 id="account-title">个人资料</h2></div><button id="account-close" class="apple-close" aria-label="关闭">✕</button></div>
                <div class="apple-segment"><button class="selected" data-account-tab="profile">资料</button><button data-account-tab="password">修改密码</button><button data-account-tab="history">登录记录</button></div>
                <form id="account-profile-form" class="account-form">
                    <div class="profile-avatar-row"><button type="button" id="account-avatar-pick" class="profile-avatar" aria-label="更换头像"><span id="account-avatar-preview">${avatarHtml(avatar)}</span><span class="avatar-edit-badge">＋</span></button><div><h3>让朋友认出你</h3><p>选择照片，设置你的昵称与签名。</p><button type="button" id="account-avatar-clear" class="apple-link">恢复默认头像</button></div></div>
                    <input id="account-avatar-file" class="hidden" type="file" accept="image/png,image/jpeg,image/webp">
                    <label>昵称<input id="account-nickname" maxlength="40" autocomplete="nickname" placeholder="你的昵称"></label>
                    <label>个性签名<input id="account-signature" maxlength="160" placeholder="分享此刻的心情"></label>
                    <label>关于我<textarea id="account-bio" maxlength="500" rows="3" placeholder="喜欢的音乐、歌手或一个小故事"></textarea></label>
                    <p class="apple-help">头像、昵称和签名会显示在听歌房间。账号登录名称保持不变。</p>
                    <p id="account-profile-result" role="status"></p><div class="sheet-actions"><button type="button" id="account-logout" class="apple-secondary">退出账号</button><button type="submit" id="account-save" class="apple-primary">保存资料</button></div>
                </form>
                <form id="account-password-form" class="account-form hidden">
                    <label>当前密码<input id="account-current-password" type="password" autocomplete="current-password" required maxlength="256"></label>
                    <label>新密码<input id="account-new-password" type="password" autocomplete="new-password" required minlength="8" maxlength="128" placeholder="8–128 个字符"></label>
                    <label>确认新密码<input id="account-confirm-password" type="password" autocomplete="new-password" required minlength="8" maxlength="128"></label>
                    <p class="apple-help">修改后需使用新密码重新登录。</p><p id="account-password-result" role="status" aria-live="polite"></p>
                    <div class="sheet-actions"><button type="submit" id="account-password-save" class="apple-primary">确认修改</button></div>
                </form>
                <div id="account-history-panel" class="hidden"><div class="account-table-scroll"><table class="apple-table"><thead><tr><th>设备</th><th>来源</th><th>登录</th><th>退出</th></tr></thead><tbody id="account-history"></tbody></table></div><div class="sheet-actions"><button id="account-prev" class="apple-secondary">上一页</button><span id="account-page"></span><button id="account-next" class="apple-secondary">下一页</button></div></div>
            </section>`;
            document.body.appendChild(modal);
            $('account-nickname').value = profile.nickname || ''; $('account-signature').value = profile.signature || ''; $('account-bio').value = profile.bio || '';
            $('account-close').onclick = close; modal.onclick = event => { if (event.target === modal) close(); };
            modal.onkeydown = event => {
                if (event.key === 'Escape') close();
                if (event.key === 'Tab') {
                    const controls = [...modal.querySelectorAll('button,input,textarea')].filter(el => !el.disabled && el.getClientRects().length);
                    const first=controls[0],last=controls.at(-1);
                    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
                    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
                }
            };
            modal.querySelectorAll('[data-account-tab]').forEach(button => button.onclick = () => {
                const tab=button.dataset.accountTab;
                $('account-profile-form').classList.toggle('hidden',tab!=='profile');$('account-password-form').classList.toggle('hidden',tab!=='password');$('account-history-panel').classList.toggle('hidden',tab!=='history');
                modal.querySelectorAll('[data-account-tab]').forEach(b => b.classList.toggle('selected',b === button));
            });
            $('account-prev').onclick = () => { page--; records(); }; $('account-next').onclick = () => { page++; records(); };
            $('account-avatar-pick').onclick = () => $('account-avatar-file').click();
            $('account-avatar-clear').onclick = () => { avatar = ''; $('account-avatar-preview').innerHTML = avatarHtml(''); };
            $('account-avatar-file').onchange = async event => {
                const file=event.target.files?.[0]; if (!file) return;
                try { const value=await cropImage(file); if (key !== identity() || !$('account-panel')) return; avatar=value; $('account-avatar-preview').innerHTML=avatarHtml(avatar); }
                catch(error) { window.showError?.(error.message); }
            };
            $('account-logout').onclick = () => {close();void signOut();};
            $('account-profile-form').onsubmit = async event => {
                event.preventDefault(); const result=$('account-profile-result'), save=$('account-save'); save.disabled=true;
                try {
                    const data = await request('/api/user/profile',{method:'POST',body:JSON.stringify({nickname:$('account-nickname').value,signature:$('account-signature').value,bio:$('account-bio').value,avatar})},key);
                    if (!$('account-panel')) return;
                    profile=data.profile; renderHeader(); result.textContent='资料已保存'; window.dispatchEvent(new CustomEvent('lx-profile-change',{detail:profile}));
                } catch(error) { if (result.isConnected) result.textContent=error.message; }
                finally { save.disabled=false; }
            };
            $('account-password-form').onsubmit=async event=>{
                event.preventDefault();const result=$('account-password-result'),save=$('account-password-save');
                const next=$('account-new-password').value;
                if(next!==$('account-confirm-password').value){result.textContent='两次输入的新密码不一致';return;}
                save.disabled=true;result.textContent='正在修改…';
                try{
                    const data=await request('/api/user/password',{method:'POST',body:JSON.stringify({currentPassword:$('account-current-password').value,newPassword:next})},key);
                    if(key!==identity()){if(localStorage.getItem('lx_sync_user')===JSON.parse(key)['x-user-name'])window.showSuccess?.(data.message);return;}
                    result.textContent=data.message;window.showSuccess?.(data.message);close();
                    await signOut();
                }catch(error){if(result.isConnected)result.textContent=error.message;}
                finally{save.disabled=false;}
            };
            records();if(options.tab)$('account-panel').querySelector('[data-account-tab="'+options.tab+'"]')?.click();$('account-close').focus();renderHeader();
        } catch(error) { window.showError?.(error.message === 'Unauthorized' ? '请先登录同步账号' : error.message); }
    }
    function logged(){return !!window.getUserAuthHeaders?.()['x-user-token'];}
    async function signOut(){
        hideMenu();
        try{await window.handleSyncLogout?.(true);}
        catch(error){window.showError?.(error.message);}
    }
    function signIn(){
        hideMenu();
        if(window.LXNative?.runtime==='browser')return window.LXNative.request('signIn').catch(error=>window.showError?.(error.message));
        if(window.LXNative && !window.NativeShell?.state?.info?.server)return window.LXNative.request('editServer').catch(error=>window.showError?.(error.message));
        window.NativeShell?.go('settings');$('btn-mode-local')?.click();
        const input=$('sync-local-user');input?.scrollIntoView({block:'center'});input?.focus({preventScroll:true});
    }

    function hideMenu(){const menu=$('qiye-account-menu');if(menu)menu.hidden=true;$('qiye-account-button')?.setAttribute('aria-expanded','false');}
    function renderAccountButton(){
        const button=$('qiye-account-button');if(!button)return;
        const name=profile?.nickname || localStorage.getItem('lx_sync_user') || '账号';
        button.innerHTML=logged()?avatarHtml(profile?.avatar,name):person+'<span>登录</span>';
        button.classList.toggle('is-guest',!logged());button.setAttribute('aria-label',logged()?name+'，账号菜单':'登录账号');button.title=logged()?name:'登录账号';
    }
    function mountHeader(){
        if(!$('qiye-account')){
            const wrap=document.createElement('div');wrap.id='qiye-account';
            wrap.innerHTML='<button type="button" id="qiye-account-button" aria-haspopup="menu" aria-expanded="false"></button><div id="qiye-account-menu" role="menu" hidden><p id="qiye-account-name"></p><button type="button" role="menuitem" data-account-action="avatar">更改头像与资料</button><button type="button" role="menuitem" data-account-action="password">修改密码</button><button type="button" role="menuitem" data-account-action="logout">退出登录</button></div>';
            document.body.append(wrap);
            const measure=()=>document.documentElement.style.setProperty('--qiye-account-width',wrap.getBoundingClientRect().width+'px');
            if(typeof ResizeObserver==='function')new ResizeObserver(measure).observe(wrap);
            requestAnimationFrame(measure);
            $('qiye-account-button').onclick=()=>{
                if(!logged()){void signIn();return;}
                const menu=$('qiye-account-menu');menu.hidden=!menu.hidden;$('qiye-account-button').setAttribute('aria-expanded',String(!menu.hidden));$('qiye-account-name').textContent=profile?.nickname || localStorage.getItem('lx_sync_user') || '我的账号';
                if(!menu.hidden)menu.querySelector('button').focus();
            };
            wrap.onclick=event=>{const action=event.target.closest('[data-account-action]')?.dataset.accountAction;if(!action)return;hideMenu();if(action==='logout')void signOut();else void open({tab:action==='password'?'password':'profile'});};
            document.addEventListener('click',event=>{if(!wrap.contains(event.target))hideMenu();});
            wrap.onkeydown=event=>{if(event.key==='Escape'){hideMenu();$('qiye-account-button').focus();}else if(['ArrowDown','ArrowUp'].includes(event.key)){event.preventDefault();const buttons=[...$('qiye-account-menu').querySelectorAll('button')],i=buttons.indexOf(document.activeElement);buttons[(i+(event.key==='ArrowDown'?1:buttons.length-1))%buttons.length]?.focus();}};
            renderAccountButton();
        }
        const nav=$('mobile-bottom-nav');
        if(window.LXNative?.runtime==='browser' && nav?.querySelector('[data-native-page]') && !nav.querySelector('.qiye-desktop-link')){
            for(const [target,label,icon]of [['favorites','我的收藏','♡'],['downloads','已下载','↓'],['localmusic','本地 / 网盘','▱']]){
                const button=document.createElement('button');button.type='button';button.className='qiye-desktop-link';button.dataset.nativePage=target;button.innerHTML='<span class="qiye-rail-icon" aria-hidden="true">'+icon+'</span><span>'+label+'</span>';nav.append(button);
            }
            window.NativeShell?.syncNavigation();
        }
    }
    function init() {
        $('account-panel-open')?.addEventListener('click',()=>open());mountHeader();void refresh();window.addEventListener('qiye-shell-ready',mountHeader);
        window.addEventListener('lx-auth-change',() => { close();hideMenu();activity=[];void refresh(); });
        window.addEventListener('focus',refresh);
    }
    window.AccountPanel = {open,close,refresh,avatarHtml,mountHeader};
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded',init); else init();
})();

const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const html = readFileSync(path.join(__dirname, '../../build/own-ui/resources/WebUI.html'), 'utf8');
function section(start, end) {
    const at = html.indexOf(start);
    const stop = html.indexOf(end, at);
    assert.ok(at >= 0 && stop > at);
    return html.slice(at, stop);
}
function fixture(source, initial = {}) {
    const nodes = new Map(), calls = [];
    function createElement() {
        const classes = new Set(['hidden']);
        return {
            innerHTML:'', textContent:'', value:'',
            classList:{contains:name=>classes.has(name), add:(...names)=>names.forEach(n=>classes.add(n)),
                remove:(...names)=>names.forEach(n=>classes.delete(n))},
            querySelector:()=>createElement(),
            replaceChildren(...children) { this.innerHTML=''; this.textContent=children[0]?.textContent || ''; },
            insertAdjacentHTML(_, html) { this.innerHTML+=html; },
            scrollTo() {},
        };
    }
    const element = id => {
        if (!nodes.has(id)) nodes.set(id, createElement());
        return nodes.get(id);
    };
    const window = {};
    const context = vm.createContext({
        window, document:{getElementById:element, createElement}, localStorage:{setItem() {}},
        console, requestAnimationFrame:callback=>callback(), setTimeout:callback=>callback(),
        fetch:(url, options)=>new Promise(resolve=>calls.push({url, options, reply:value=>resolve({ok:true,json:async()=>value})})),
        ...initial,
    });
    vm.runInContext(source, context);
    return {element, calls, context};
}

test('A slow search cannot replace the newer results', async () => {
    const rendered=[];
    const f=fixture(section('let searchRequest = 0;', 'function changePage('), {
        currentSearchScope:'online', currentPage:1, currentSearch:{}, lastSearchResultList:null, lastSearchType:null,
        API_BASE:'/api/music', getUserAuthHeaders:()=>({}), renderResults:rows=>rendered.push(rows[0].id),
    });
    f.element('search-source').value='wy';f.element('search-type').value='song';
    f.element('search-input').value='first';const first=f.context.doSearch();
    f.element('search-input').value='second';const second=f.context.doSearch();
    f.calls[1].reply([{id:'new'}]);await second;
    f.calls[0].reply([{id:'old'}]);await first;
    assert.deepEqual(rendered,['new']);
});

test('Comments stay with the current song and tab when responses arrive out of order', async () => {
    const f=fixture(section("let currentCommentType = 'hot';", 'function createCommentItemHTML('), {
        currentPlayingSong:{name:'A',source:'wy',id:'123'},
        createCommentItemHTML:comment=>comment.text,
    });
    f.context.toggleCommentModal();
    f.context.switchCommentType('new');
    assert.equal(JSON.parse(f.calls[1].options.body).type,'new');
    f.calls[1].reply({comments:[{text:'latest'}],total:1,maxPage:1});
    f.calls[0].reply({comments:[{text:'stale hot'}],total:1,maxPage:1});
    await new Promise(setImmediate);
    assert.equal(f.element('comment-list').innerHTML,'latest');
    f.context.currentPlayingSong={name:'B',source:'tx',id:'123'};
    f.context.syncCommentSong();
    assert.equal(JSON.parse(f.calls[2].options.body).songInfo.source,'tx');
    f.context.toggleCommentModal();
    f.calls[2].reply({comments:[{text:'after close'}],total:1,maxPage:1});
    await new Promise(setImmediate);
    assert.equal(f.element('comment-list').innerHTML,'');
});

test('Legacy token refresh cannot clear a session restored by the native app', async () => {
    const f=fixture(section('async function ensureUserAuthToken(', 'window.ensureUserAuthToken ='));
    let reads=0;
    f.context.localStorage={getItem(){reads++;return null;},removeItem(){throw new Error('Native token must survive');}};
    f.context.window.LXBridge={accountReady:Promise.resolve({token:'fixture'})};
    assert.equal(await f.context.ensureUserAuthToken(),true);
    assert.equal(await f.context.ensureUserAuthToken({force:true}),false);
    assert.equal(reads,0);
});

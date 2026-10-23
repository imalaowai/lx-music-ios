/* The browser account and room live in the same page header, in normal flow. */
(function(){
'use strict';
const $=id=>document.getElementById(id);let last='',room={},unread=0;
function avatar(member){
 const node=document.createElement('span');node.className='qiye-room-avatar';node.title=member.nickname || member.name || '房间成员';
 if(member.avatar?.type==='emoji')node.textContent=String(member.avatar.value || '🎧').slice(0,8);
 else if(member.avatar){node.innerHTML=window.AccountPanel?.avatarHtml(member.avatar,node.title) || '';}
 else node.textContent=Array.from(node.title)[0];
 return node;
}
function update(){
 const header=$('qiye-page-header');if(!header)return;
 const joined=!!room.binding?.roomId,members=joined?(room.participants || []):[],key=JSON.stringify([joined,members.map(m=>[m.id,m.name,m.nickname,m.avatar]),unread]);
 if(last===key)return;last=key;
 const button=$('qiye-header-room'),stack=$('qiye-header-members'),badge=$('qiye-header-unread');
 button.setAttribute('aria-label',unread?'一起听，'+unread+' 条新消息':'一起听');
 button.classList.toggle('is-joined',joined);badge.hidden=!unread;badge.textContent=unread>99?'99+':unread?String(unread):'';
 stack.replaceChildren();stack.hidden=!members.length;stack.setAttribute('aria-label','查看房间成员，共 '+members.length+' 人');
 for(const member of members.slice(0,3))stack.append(avatar(member));
 if(members.length>3){const more=document.createElement('span');more.className='qiye-room-avatar qiye-room-count';more.textContent='+'+(members.length-3);stack.append(more);}
 $('qiye-header-room-label').textContent=joined?'一起听 · '+members.length+' 人':'一起听';
}
function mount(){
 const main=$('desktop-layout-main') || document.querySelector('main');if(!main || !window.NativeShell)return;
 if(!$('qiye-page-header')){
  const header=document.createElement('div');header.id='qiye-page-header';header.setAttribute('role','banner');
  header.innerHTML='<a class="qiye-header-brand" href="#" aria-label="栖页音乐首页">栖页<span>音乐</span></a><div class="qiye-header-actions"><div class="qiye-header-room-group"><button type="button" id="qiye-header-room"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" aria-hidden="true"><path d="M4 14v-3a8 8 0 0 1 16 0v3M4 11H2v7h5v-7H4m16 0h2v7h-5v-7h3"/></svg><span id="qiye-header-room-label">一起听</span><small id="qiye-header-unread" hidden></small></button><button type="button" id="qiye-header-members" hidden></button></div><div id="qiye-header-account-slot"></div></div>';
  main.prepend(header);header.querySelector('a').onclick=e=>{e.preventDefault();window.NativeShell.go('home');};
  $('qiye-header-room').onclick=()=>window.NativeShell.go('room');
  $('qiye-header-members').onclick=()=>{window.NativeShell.go('room');$('native-room-member-strip')?.querySelector('button')?.click();};
 }
 window.AccountPanel?.mountHeader();const account=$('qiye-account');if(account && account.parentNode!==$('qiye-header-account-slot'))$('qiye-header-account-slot').append(account);
 room=window.NativeShell.state?.room || room;unread=window.RoomSocial?.state?.unread?.size || unread;update();
}
window.addEventListener('lx-native-room',e=>{room=e.detail || {};update();});
window.addEventListener('lx-room-unread',e=>{unread=Math.max(0,Number(e.detail?.count)||0);update();});
window.addEventListener('qiye-shell-ready',mount);
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',()=>setTimeout(mount,0),{once:true});else setTimeout(mount,0);
})();

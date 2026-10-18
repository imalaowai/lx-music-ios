'use strict';
const {Buffer}=require('buffer');
globalThis.Buffer=Buffer;globalThis.global=globalThis;globalThis.window=globalThis;globalThis.self=globalThis;
globalThis.process=require('process/browser');
// The bundled Kugou signer checks its host once during module initialization.
// No DOM or account state is exposed to imported sources.
globalThis.navigator=Object.freeze({userAgent:'LX-Music/iOS',platform:'iPhone'});
globalThis.crypto={getRandomValues(array){const bytes=Buffer.from(__nativeRandom(array.byteLength),'base64');new Uint8Array(array.buffer,array.byteOffset,array.byteLength).set(bytes);return array;}};
let sequence=0;const requests=new Map(),timers=new Map();
globalThis.setTimeout=(callback,delay=0,...args)=>{const id=++sequence;timers.set(id,{run:()=>callback(...args),repeat:false});__nativeTimer(id,Math.max(0,Number(delay)||0));return id;};
globalThis.clearTimeout=id=>timers.delete(id);
globalThis.setInterval=(callback,delay=0,...args)=>{const id=++sequence;const run=()=>{callback(...args);if(timers.has(id))__nativeTimer(id,Math.max(10,Number(delay)||0));};timers.set(id,{run,repeat:true});__nativeTimer(id,Math.max(10,Number(delay)||0));return id;};
globalThis.clearInterval=globalThis.clearTimeout;
globalThis.__runTimer=id=>{const item=timers.get(id);if(item){if(!item.repeat)timers.delete(id);item.run();}};
globalThis.atob=value=>Buffer.from(String(value),'base64').toString('binary');
globalThis.btoa=value=>Buffer.from(String(value),'binary').toString('base64');
globalThis.TextEncoder=class {encode(value){return new Uint8Array(Buffer.from(String(value)));}};
globalThis.TextDecoder=class {constructor(encoding='utf8'){this.encoding=encoding;}decode(value){return Buffer.from(value).toString(this.encoding==='utf-8'?'utf8':this.encoding);}};
class Params {
 constructor(value=''){this.items=[];if(typeof value==='string'){for(const item of value.replace(/^\?/,'').split('&')){if(!item)continue;const at=item.indexOf('=');this.append(decodeURIComponent((at<0?item:item.slice(0,at)).replace(/\+/g,' ')),decodeURIComponent((at<0?'':item.slice(at+1)).replace(/\+/g,' ')));}}else if(Array.isArray(value)){for(const [k,v]of value)this.append(k,v);}else for(const [k,v]of Object.entries(value))this.append(k,v);}
 append(k,v){this.items.push([String(k),String(v)]);}get(k){return this.items.find(x=>x[0]===String(k))?.[1]??null;}getAll(k){return this.items.filter(x=>x[0]===String(k)).map(x=>x[1]);}has(k){return this.items.some(x=>x[0]===String(k));}delete(k){this.items=this.items.filter(x=>x[0]!==String(k));}set(k,v){this.delete(k);this.append(k,v);}entries(){return this.items[Symbol.iterator]();}[Symbol.iterator](){return this.entries();}toString(){return this.items.map(x=>x.map(y=>encodeURIComponent(y).replace(/%20/g,'+')).join('=')).join('&');}
}
globalThis.URLSearchParams=Params;
globalThis.URL=class {
 constructor(input,base){const data=JSON.parse(__nativeURL(String(input),base?String(base):''));Object.assign(this,data);this.searchParams=new Params(data.search);}
 toString(){const query=this.searchParams.toString();return this.origin+this.pathname+(query?'?'+query:'')+(this.hash||'');}get href(){return this.toString();}toJSON(){return this.toString();}
};
globalThis.__nativeReply=(id,result,error)=>{const item=requests.get(id);if(!item)return;requests.delete(id);if(error)item.reject(new Error(error));else item.resolve(JSON.parse(result));};
function httpFetch(url,options={}){
 const id=++sequence;let reject;const promise=new Promise((resolve,fail)=>{reject=fail;requests.set(id,{resolve,reject:fail});});
 let body=options.body;
 if(Buffer.isBuffer(body)||ArrayBuffer.isView(body))body={base64:Buffer.from(body).toString('base64')};
 __nativeHTTP(id,JSON.stringify({url:String(url),options:{...options,body,agent:undefined,lookup:undefined}}));
 return {promise:promise.then(result=>{const raw=Buffer.from(result.base64||'','base64');let body=options.isBuffer?raw:result.text; if(!options.isBuffer && typeof body==='string'){try{body=JSON.parse(body);}catch{}}return {body,raw,headers:result.headers||{},statusCode:result.statusCode};}),cancelHttp(){requests.delete(id);__nativeCancel(id);reject(new Error('已取消请求'));}};
}
globalThis.fetch=async(url,options={})=>{const result=await httpFetch(url,{...options,isBuffer:true}).promise;const body=result.body;return {ok:result.statusCode>=200&&result.statusCode<300,status:result.statusCode,headers:{get:name=>result.headers[String(name).toLowerCase()]||null},text:async()=>body.toString(),json:async()=>JSON.parse(body.toString()),arrayBuffer:async()=>body.buffer.slice(body.byteOffset,body.byteOffset+body.length)};};
module.exports={httpFetch,http:(url,options,callback)=>{const task=httpFetch(url,options);task.promise.then(r=>callback(null,r,r.body),e=>callback(e));return {abort:task.cancelHttp};},httpGet:(url,options,callback)=>module.exports.http(url,{...options,method:'GET'},callback),httpPost:(url,options,callback)=>module.exports.http(url,{...options,method:'POST'},callback),cancelHttp:task=>task?.cancelHttp?.()};

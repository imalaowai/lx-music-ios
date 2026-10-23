'use strict';
const http = require('node:http');
const https = require('node:https');
const { pipeline } = require('node:stream/promises');
const { getProxyAgent } = require('../modules/utils/proxy');
const agents = { 'http:': new http.Agent({keepAlive:true,proxyEnv:{}}), 'https:':new https.Agent({keepAlive:true,proxyEnv:{}}) };

// Streaming only. No temporary music files, tags or disk cache.
async function open(url, options = {}, depth = 0) {
  const target = new URL(url);
  if (!agents[target.protocol] || target.username || target.password) throw new Error('仅支持 HTTP(S) 地址');
  if (depth > 5) throw new Error('重定向过多');
  const agent = await getProxyAgent(target.href, options.category || 'app') || agents[target.protocol];
  return new Promise((resolve,reject) => {
    const request = (target.protocol === 'https:' ? https : http).request(target, {...options,headers:{'User-Agent':'Mozilla/5.0 QiyeMusic/2.9.3','Accept':'*/*',...options.headers},agent}, response => {
      if ([301,302,303,307,308].includes(response.statusCode) && response.headers.location && !options.body) {
        response.resume();
        const next = new URL(response.headers.location,target);
        const headers = {...options.headers};
        if (next.origin !== target.origin) { delete headers.Authorization; delete headers.authorization; delete headers.Cookie; }
        void open(next.href,{...options,headers},depth+1).then(resolve,reject); return;
      }
      resolve(response);
    });
    request.setTimeout(45000,()=>request.destroy(new Error('传输超时')));
    request.on('error',reject);
    if (options.body?.pipe) pipeline(options.body,request).catch(reject);
    else request.end(options.body);
  });
}
async function json(url, options = {}) {
  const response = await open(url, options);
  const chunks=[]; let size=0;
  for await (const chunk of response) { size+=chunk.length; if(size>2*1024*1024) {response.destroy();throw new Error('接口响应过大');} chunks.push(chunk); }
  let data; try {data=JSON.parse(Buffer.concat(chunks).toString());} catch {throw new Error(`接口返回无效数据 (${response.statusCode})`);}
  if (response.statusCode<200 || response.statusCode>=300 || (data.code!==undefined && data.code!==200)) throw new Error(data.message || `接口失败 (${response.statusCode})`);
  return data.data ?? data;
}
async function serve(url,req,res,headers={}) {
  // Playback can remain open while the browser consumes a long track. Keep
  // the upstream idle timeout, and cancel when the requesting device leaves;
  // a fixed total deadline would cut off slow or buffered playback.
  const signal=req.__mediaSignal || new AbortController().signal;
  const response=await open(url,{headers:{...headers,...(req.headers.range?{Range:req.headers.range}:{}),'Accept-Encoding':'identity'},signal});
  res.writeHead(response.statusCode,{'Content-Type':response.headers['content-type'] || 'application/octet-stream',
    'Cache-Control':'private, no-store',...Object.fromEntries(['content-length','content-range','accept-ranges'].filter(k=>response.headers[k]).map(k=>[k,response.headers[k]]))});
  await pipeline(response,res,{signal});
}
module.exports={open,json,serve};

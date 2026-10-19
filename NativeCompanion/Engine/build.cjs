const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process'),crypto=require('node:crypto');
const root=__dirname,vendor=path.join(root,'vendor');
fs.mkdirSync(vendor,{recursive:true});cp.execFileSync('tar',['-xJf',path.join(root,'vendor.tar.xz'),'-C',vendor]);
const request=path.join(vendor,'server/modules/utils/request.js'),api=path.join(vendor,'server/modules/utils/musicSdk/api-source.js');
const aliases={'crypto':'crypto-browserify','stream':'stream-browserify','events':'events/','buffer':'buffer/','zlib':path.join(root,'src/compression.cjs')};
const plugin={name:'native-host',setup(build){
 build.onLoad({filter:/\/kw\/util\.js$/},args=>{
  const original=fs.readFileSync(args.path,'utf8');
  const contents=original.replace(/^    return JSON.parse\(str.replace.*$/m,`    return JSON.parse(str.replace(/([:{,]\\s*)'|'(?=\\s*[:,}])/g, (match, prefix) => prefix ? prefix + '"' : '"'));`);
  if(contents===original)throw Error('Kuwo iOS 15 compatibility patch no longer matches');
  return {contents,loader:'js'};
 });
 build.onResolve({filter:/./},args=>{
  const target=args.path.startsWith('.')?path.resolve(args.resolveDir,args.path):args.path;
  if(target===request.replace(/\.js$/,'')||target===request)return {path:path.join(root,'src/platform.cjs')};
  if(target===api.replace(/\.js$/,'')||target===api)return {path:'api',namespace:'native'};
  if(args.path==='dns')return {path:'dns',namespace:'native'};
 });
 build.onLoad({filter:/.*/,namespace:'native'},args=>({contents:args.path==='dns'?'exports.lookup=(host,options,cb)=>(cb||options)(null,host,4);':'exports.apis=source=>({getMusicUrl:(song,type)=>globalThis.__localResolve(source,song,type)});exports.supportQuality={};'}));
}};
(async()=>{
 await require('esbuild').build({absWorkingDir:root,entryPoints:[path.join(root,'src/index.cjs')],bundle:true,platform:'browser',target:'safari15',format:'iife',minify:true,legalComments:'eof',tsconfigRaw:{},inject:[path.join(root,'src/inject.cjs')],alias:aliases,outfile:path.join(root,'../generated/LocalEngine.js'),plugins:[plugin]});
 const file=path.join(root,'../generated/LocalEngine.js'),data=fs.readFileSync(file);
 cp.execFileSync('python3',['-c','import sys,lzma;open(sys.argv[2],"wb").write(lzma.compress(open(sys.argv[1],"rb").read(),preset=9))',file,path.join(root,'../Resources/LocalEngine.js.xz')]);
 fs.writeFileSync(path.join(root,'../Resources/LocalEngine.manifest.json'),JSON.stringify({version:'1.2.1',sha256:crypto.createHash('sha256').update(data).digest('hex'),bytes:data.length},null,2)+'\n');
 console.log('Local engine bundled: '+data.length+' bytes');
})().catch(e=>{console.error(e);process.exitCode=1;});

const http=require('node:http'),{spawn}=require('node:child_process');
let requests=0;
const server=http.createServer((req,res)=>{let text='';req.on('data',b=>text+=b);req.on('end',()=>{
 res.setHeader('Content-Type','application/json');
 if(req.url.endsWith('/form')){
  const body=new URLSearchParams(text),valid=req.method==='POST'&&req.headers['content-type']==='application/x-www-form-urlencoded'&&body.get('cipher')==='a+b/c== 汉字 &value=1%#?'&&body.get('a+b')==='x+y'&&body.get('empty')==='';
  if(valid)requests++;else res.statusCode=400;
  res.end(JSON.stringify({valid}));return;
 }
 let body;try{body=JSON.parse(text||'{}');}catch{res.statusCode=400;res.end('{}');return;}
 if(req.method!=='POST'||body.song!=='123'){res.statusCode=400;res.end('{}');return;}requests++;res.end(JSON.stringify({url:'https://audio.invalid/native.mp3'}));
});});
server.listen(0,'127.0.0.1',()=>{const child=spawn(process.argv[2],['http://127.0.0.1:'+server.address().port+'/resolve'],{stdio:'inherit'});child.on('exit',code=>{server.close();process.exitCode=code||(requests!==2?1:0);});});

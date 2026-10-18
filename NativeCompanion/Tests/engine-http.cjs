const http=require('node:http'),{spawn}=require('node:child_process');
let requests=0;
const server=http.createServer((req,res)=>{let text='';req.on('data',b=>text+=b);req.on('end',()=>{const body=JSON.parse(text||'{}');if(req.method!=='POST'||body.song!=='123'){res.statusCode=400;res.end('{}');return;}requests++;res.setHeader('Content-Type','application/json');res.end(JSON.stringify({url:'https://audio.invalid/native.mp3'}));});});
server.listen(0,'127.0.0.1',()=>{const child=spawn(process.argv[2],['http://127.0.0.1:'+server.address().port+'/resolve'],{stdio:'inherit'});child.on('exit',code=>{server.close();process.exitCode=code||(!requests?1:0);});});

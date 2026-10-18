const pako=require('pako'),{Buffer}=require('buffer');
const wrap=(fn,input,callback)=>{try{const output=Buffer.from(fn(input));if(callback){callback(null,output);return;}return output;}catch(e){if(callback){callback(e);return;}throw e;}};
exports.inflate=(input,cb)=>wrap(pako.inflate,input,cb);exports.deflate=(input,cb)=>wrap(pako.deflate,input,cb);exports.gunzip=(input,cb)=>wrap(pako.ungzip,input,cb);
exports.inflateSync=input=>wrap(pako.inflate,input);exports.deflateSync=input=>wrap(pako.deflate,input);exports.gunzipSync=input=>wrap(pako.ungzip,input);

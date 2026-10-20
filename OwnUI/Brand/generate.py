#!/usr/bin/env python3
"""Render the Qiye book/leaf/note mark from editable vector paths."""
import json,pathlib
from PIL import Image,ImageDraw
root=pathlib.Path(__file__).resolve().parent
size=3072
scale=3
im=Image.new('RGB',(size,size));pixels=im.load()
for y in range(size):
 for x in range(size):
  t=(x+y)/(size*2);pixels[x,y]=(int(13+12*t),int(37+26*t),int(42+24*t))
d=ImageDraw.Draw(im)
def curve(points):
 out=[points[0]]
 for i in range(1,len(points),3):
  a=out[-1];b,c,e=points[i:i+3]
  for k in range(1,61):
   t=k/60;v=1-t;out.append((v**3*a[0]+3*v*v*t*b[0]+3*v*t*t*c[0]+t**3*e[0],v**3*a[1]+3*v*v*t*b[1]+3*v*t*t*c[1]+t**3*e[1]))
 return [(x*scale,y*scale) for x,y in out]
# Open pages fold into a quiet shelter; the right page becomes a leaf.
left=curve([(250,660),(250,545),(250,430),(250,315),(345,305),(430,332),(504,392),(504,500),(504,610),(504,726),(424,671),(344,651),(250,660)])
right=curve([(528,726),(528,610),(528,503),(528,392),(602,332),(688,305),(782,315),(782,430),(782,545),(782,660),(687,651),(607,671),(528,726)])
d.line(left,fill='#ede6d0',width=19*scale,joint='curve');d.line(right,fill='#ede6d0',width=19*scale,joint='curve')
leaf=curve([(580,352),(589,252),(677,217),(759,220),(745,312),(688,365),(580,352)])
d.polygon(leaf,fill='#bdc4a0')
# A small note shares the book's central spine.
d.line([(504*scale,415*scale),(504*scale,627*scale)],fill='#ede6d0',width=21*scale);d.ellipse(tuple(v*scale for v in (421,598,509,657)),fill='#ede6d0')
images=[];asset=root/'Images.xcassets/AppIcon.appiconset';asset.mkdir(parents=True,exist_ok=True)
for idiom,pt,scales in [('iphone',20,[2,3]),('iphone',29,[2,3]),('iphone',40,[2,3]),('iphone',60,[2,3]),('ipad',20,[1,2]),('ipad',29,[1,2]),('ipad',40,[1,2]),('ipad',76,[1,2]),('ipad',83.5,[2]),('car',60,[2,3]),('ios-marketing',1024,[1])]:
 for scale in scales:
  filename=f'Qiye-{idiom}-{pt}-{scale}.png';im.resize((int(pt*scale),int(pt*scale)),Image.Resampling.LANCZOS).save(asset/filename)
  images.append({'idiom':idiom,'size':f'{pt}x{pt}','scale':f'{scale}x','filename':filename})
(asset/'Contents.json').write_text(json.dumps({'images':images,'info':{'version':1,'author':'xcode'}},indent=2))
(root/'Images.xcassets/Contents.json').write_text('{"info":{"version":1,"author":"xcode"}}\n')
im.resize((1024,1024),Image.Resampling.LANCZOS).save(root/'QiyeIcon.png')
print('Rendered',len(images),'Qiye app icons')

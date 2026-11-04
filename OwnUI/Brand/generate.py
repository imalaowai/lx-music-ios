#!/usr/bin/env python3
"""Export the approved cute headphone-cat master into iPhone, iPad and CarPlay icons."""
import json,pathlib
from PIL import Image
root=pathlib.Path(__file__).resolve().parent
im=Image.open(root/'CartoonIcon.png').convert('RGB')
assert im.width==im.height and im.width>=1024,'Expected full-size square icon master'
images=[];asset=root/'Images.xcassets/AppIcon.appiconset';asset.mkdir(parents=True,exist_ok=True)
for idiom,pt,scales in [('iphone',20,[2,3]),('iphone',29,[2,3]),('iphone',40,[2,3]),('iphone',60,[2,3]),('ipad',20,[1,2]),('ipad',29,[1,2]),('ipad',40,[1,2]),('ipad',76,[1,2]),('ipad',83.5,[2]),('car',60,[2,3]),('ios-marketing',1024,[1])]:
 for scale in scales:
  filename=f'Qiye-{idiom}-{pt}-{scale}.png';im.resize((int(pt*scale),int(pt*scale)),Image.Resampling.LANCZOS).save(asset/filename)
  images.append({'idiom':idiom,'size':f'{pt}x{pt}','scale':f'{scale}x','filename':filename})
(asset/'Contents.json').write_text(json.dumps({'images':images,'info':{'version':1,'author':'xcode'}},indent=2))
(root/'Images.xcassets/Contents.json').write_text('{"info":{"version":1,"author":"xcode"}}\n')
im.resize((1024,1024),Image.Resampling.LANCZOS).save(root/'QiyeIcon.png')
print('Rendered',len(images),'Qiye app icons')

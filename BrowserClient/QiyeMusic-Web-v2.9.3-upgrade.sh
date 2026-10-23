#!/usr/bin/env bash
set -Eeuo pipefail
QIYE_HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
QIYE_CHECK=0
if [[ ${1:-} == --check ]]; then QIYE_CHECK=1; shift; fi
QIYE_ZIP=${1:-}
QIYE_CONTAINER=${2:-lx-sync-server-v2.1.2}
if [[ -z $QIYE_ZIP && -f $QIYE_HERE/QiyeMusic-Web-v2.9.3-Header-Downloads-20261023.zip ]]; then QIYE_ZIP="$QIYE_HERE/QiyeMusic-Web-v2.9.3-Header-Downloads-20261023.zip"; fi
if [[ -z $QIYE_ZIP ]]; then QIYE_ZIP=$(find /home/hulai /root -maxdepth 4 -type f -name 'QiyeMusic-Web-v2.9.3-Header-Downloads-20261023.zip' -print -quit 2>/dev/null || true); fi
[[ -n $QIYE_ZIP && -f $QIYE_ZIP ]] || { echo '未找到 v2.9.3 ZIP，请把升级 ZIP 与本脚本一起上传到 /home/hulai。' >&2; exit 1; }
command -v python3 >/dev/null || { echo '需要 Python 3 解压升级包。' >&2; exit 1; }
QIYE_WORK=$(mktemp -d /tmp/qiye-web-v293.XXXXXX)
trap 'rm -rf -- "$QIYE_WORK"' EXIT
python3 - "$QIYE_ZIP" "$QIYE_WORK" <<'QIYE_PY'
import hashlib,json,pathlib,stat,sys,zipfile
archive=pathlib.Path(sys.argv[1]);dest=pathlib.Path(sys.argv[2]).resolve()
if hashlib.sha256(archive.read_bytes()).hexdigest()!='73bf0bb8fbafead00cc3f83c88096154653cf85128f839988ecf5bd86af0d39d':
    raise SystemExit('ZIP 校验失败，请重新上传完整的配套 v2.9.3 升级包。')
with zipfile.ZipFile(archive) as z:
    if z.testzip() is not None:raise SystemExit('ZIP 已损坏')
    links=[]
    for info in z.infolist():
        rel=pathlib.PurePosixPath(info.filename)
        if rel.is_absolute() or '..' in rel.parts or not rel.parts or rel.parts[0]!='lx-music-sync-server':raise SystemExit('ZIP 路径无效')
        p=dest.joinpath(*rel.parts);mode=info.external_attr>>16
        if info.is_dir():p.mkdir(parents=True,exist_ok=True);continue
        p.parent.mkdir(parents=True,exist_ok=True)
        if stat.S_ISLNK(mode):links.append((p,z.read(info).decode()));continue
        p.write_bytes(z.read(info));p.chmod(mode&0o777 or 0o644)
    for p,target in links:
        resolved=(p.parent/target).resolve()
        if resolved!=dest and dest not in resolved.parents:raise SystemExit('ZIP 链接越界')
        p.symlink_to(target)
root=dest/'lx-music-sync-server';manifest=json.loads((root/'release-manifest.json').read_text())
if manifest['version']!='2.9.3':raise SystemExit('升级包版本不匹配')
for name,record in manifest['files'].items():
    p=root/name
    if 'link' in record:
        if not p.is_symlink() or p.readlink().as_posix()!=record['link']:raise SystemExit('链接校验失败：'+name)
    elif not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest()!=record['sha256']:raise SystemExit('文件校验失败：'+name)
print('v2.9.3 升级包和全部文件校验通过。')
QIYE_PY
if (( QIYE_CHECK )); then echo '检查完成，未修改现有项目。'; exit 0; fi
bash "$QIYE_WORK/lx-music-sync-server/upgrade.sh" --docker "$QIYE_CONTAINER"

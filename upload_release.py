import sys, json
from urllib.request import Request, urlopen
from urllib.error import HTTPError

token = sys.argv[1]
repo = "txurtxil/LinuxContainer"
tag = "v12.6"
apk_path = "build/app/outputs/flutter-apk/app-release.apk"

req = Request(f"https://api.github.com/repos/{repo}/releases/tags/{tag}", headers={"Authorization": f"token {token}"})
release_id = None
try:
    with urlopen(req) as response:
        release_id = json.loads(response.read().decode())['id']
except HTTPError as e:
    if e.code == 404:
        data = json.dumps({"tag_name": tag, "name": f"Versión {tag}", "body": "Actualización Fase 4: Tool-calling en local con GPU vía MediaPipe."}).encode()
        req_create = Request(f"https://api.github.com/repos/{repo}/releases", data=data, headers={"Authorization": f"token {token}", "Content-Type": "application/json"})
        with urlopen(req_create) as res:
            release_id = json.loads(res.read().decode())['id']

if release_id:
    print(f"Subiendo app-release.apk a la Release ID {release_id}...")
    with open(apk_path, "rb") as f:
        apk_data = f.read()
    upload_url = f"https://uploads.github.com/repos/{repo}/releases/{release_id}/assets?name=app-release.apk"
    req_up = Request(upload_url, data=apk_data, headers={"Authorization": f"token {token}", "Content-Type": "application/vnd.android.package-archive"})
    with urlopen(req_up) as res:
        print("¡APK publicada con éxito en GitHub Releases!")

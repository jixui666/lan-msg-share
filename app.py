import base64
import io
import json
import os
import socket
import threading
import uuid
from datetime import datetime
from pathlib import Path

import qrcode
from flask import Flask, abort, jsonify, render_template, request, send_from_directory

BASE_DIR = Path(__file__).resolve().parent
UPLOAD_DIR = BASE_DIR / "uploads"
UPLOAD_DIR.mkdir(exist_ok=True)
CLIPBOARD_FILE = BASE_DIR / "clipboard.json"
MAX_CLIPS = 50
MAX_CLIP_CHARS = 50_000
_clip_lock = threading.Lock()

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 2 * 1024 * 1024 * 1024  # 2 GB


def load_clips() -> list[dict]:
    if not CLIPBOARD_FILE.is_file():
        return []
    try:
        data = json.loads(CLIPBOARD_FILE.read_text(encoding="utf-8"))
        return data if isinstance(data, list) else []
    except (OSError, json.JSONDecodeError):
        return []


def save_clips(clips: list[dict]) -> None:
    CLIPBOARD_FILE.write_text(
        json.dumps(clips, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def _is_lan_ip(ip: str) -> bool:
    parts = ip.split(".")
    if len(parts) != 4:
        return False
    try:
        a, b = int(parts[0]), int(parts[1])
    except ValueError:
        return False
    if ip.startswith("127.") or ip.startswith("169.254."):
        return False
    if a == 198 and b in (18, 19):  # VPN / TUN 虚拟网段
        return False
    if a == 192 and b == 168:
        return True
    if a == 10:
        return True
    if a == 172 and 16 <= b <= 31:
        return True
    return False


def lan_ips() -> list[str]:
    found: list[str] = []

    def add(ip: str) -> None:
        if _is_lan_ip(ip) and ip not in found:
            found.append(ip)

    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            add(info[4][0])
    except OSError:
        pass

    if os.name == "nt":
        import re
        import subprocess

        try:
            out = subprocess.check_output("ipconfig", encoding="gbk", errors="ignore")
        except OSError:
            out = ""
        for match in re.finditer(r"IPv4.+?:\s*([0-9.]+)", out):
            add(match.group(1))

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("8.8.8.8", 80))
        add(sock.getsockname()[0])
    except OSError:
        pass
    finally:
        sock.close()

    found.sort(key=lambda ip: (0 if ip.startswith("192.168.") else 1, ip))
    return found or ["127.0.0.1"]


def local_ip() -> str:
    return lan_ips()[0]


def stored_file(filename: str) -> Path:
    name = Path(filename).name
    if name in ("", ".", "..") or name.startswith("."):
        abort(400)
    root = UPLOAD_DIR.resolve()
    target = (root / name).resolve()
    if not str(target).startswith(str(root) + os.sep) and target != root:
        abort(400)
    return target


def file_entry(path: Path) -> dict:
    stat = path.stat()
    return {
        "name": path.name,
        "size": stat.st_size,
        "mtime": datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M"),
    }


def qr_data_uri(text: str) -> str:
    qr = qrcode.QRCode(border=1, box_size=8)
    qr.add_data(text)
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white")
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode("ascii")


@app.get("/")
def index():
    port = int(request.environ.get("SERVER_PORT", "5000"))
    urls = [f"http://{ip}:{port}" for ip in lan_ips()]
    primary = urls[0]
    return render_template(
        "index.html",
        lan_url=primary,
        extra_urls=urls[1:],
        qr=qr_data_uri(primary),
    )


@app.get("/api/files")
def list_files():
    files = sorted(
        (p for p in UPLOAD_DIR.iterdir() if p.is_file() and not p.name.startswith(".")),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    return jsonify([file_entry(p) for p in files])


@app.post("/api/upload")
def upload():
    incoming = request.files.getlist("files")
    if not incoming:
        abort(400, "没有选择文件")
    saved = []
    for item in incoming:
        if not item or not item.filename:
            continue
        name = Path(item.filename).name
        if name in ("", ".", "..") or name.startswith("."):
            continue
        dest = unique_path(UPLOAD_DIR / name)
        item.save(dest)
        saved.append(file_entry(dest))
    if not saved:
        abort(400, "上传失败")
    return jsonify(saved)


@app.get("/download/<path:filename>")
def download(filename: str):
    target = stored_file(filename)
    if not target.is_file():
        abort(404)
    return send_from_directory(UPLOAD_DIR, target.name, as_attachment=True)


@app.delete("/api/files/<path:filename>")
def delete_file(filename: str):
    target = stored_file(filename)
    if not target.is_file():
        abort(404)
    target.unlink()
    return jsonify({"ok": True})


@app.get("/api/clips")
def list_clips():
    with _clip_lock:
        return jsonify(load_clips())


@app.post("/api/clips")
def add_clip():
    payload = request.get_json(silent=True) or {}
    text = payload.get("text")
    if text is None:
        text = request.form.get("text", "")
    if not isinstance(text, str):
        abort(400, "文本格式错误")
    text = text.strip("\ufeff")
    if not text.strip():
        abort(400, "请输入文本")
    if len(text) > MAX_CLIP_CHARS:
        abort(400, f"文本过长，最多 {MAX_CLIP_CHARS} 字")
    clip = {
        "id": uuid.uuid4().hex[:12],
        "text": text,
        "time": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    }
    with _clip_lock:
        clips = [clip] + load_clips()
        clips = clips[:MAX_CLIPS]
        save_clips(clips)
    return jsonify(clip)


@app.delete("/api/clips/<clip_id>")
def delete_clip(clip_id: str):
    with _clip_lock:
        clips = load_clips()
        kept = [c for c in clips if c.get("id") != clip_id]
        if len(kept) == len(clips):
            abort(404)
        save_clips(kept)
    return jsonify({"ok": True})


@app.delete("/api/clips")
def clear_clips():
    with _clip_lock:
        save_clips([])
    return jsonify({"ok": True})


def unique_path(path: Path) -> Path:
    if not path.exists():
        return path
    stem, suffix = path.stem, path.suffix
    n = 1
    while True:
        candidate = path.with_name(f"{stem}_{n}{suffix}")
        if not candidate.exists():
            return candidate
        n += 1


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "5000"))
    print(f"\n电脑打开:  http://127.0.0.1:{port}")
    for ip in lan_ips():
        print(f"手机打开:  http://{ip}:{port}")
    print()
    app.run(host="0.0.0.0", port=port, debug=False)

"""
Production launcher for EasyPeasy Classifier API.

- Single instance (port 8765)
- Logs to %ProgramData%\\EasyPeasy\\classifier-api\\
- Optional model warmup after bind
- Used by the Windows scheduled task / INSTALL.bat
"""

from __future__ import annotations

import json
import logging
import os
import socket
import sys
import threading
import time
from pathlib import Path

# Ensure sibling packages resolve when launched from anywhere
API_DIR = Path(__file__).resolve().parent
REPO_ROOT = API_DIR.parent
sys.path.insert(0, str(API_DIR))
sys.path.insert(0, str(REPO_ROOT / "text-classifier"))
sys.path.insert(0, str(REPO_ROOT / "image-classifier"))

HOST = "127.0.0.1"
PORT = 8765
TASK_NAME = "EasyPeasyClassifierAPI"


def program_data_dir() -> Path:
    base = os.environ.get("ProgramData") or str(Path.home())
    d = Path(base) / "EasyPeasy" / "classifier-api"
    d.mkdir(parents=True, exist_ok=True)
    return d


def setup_logging() -> Path:
    log_dir = program_data_dir()
    log_path = log_dir / "classifier-api.log"
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
    fh = logging.FileHandler(log_path, encoding="utf-8")
    fh.setFormatter(fmt)
    sh = logging.StreamHandler(sys.stderr)
    sh.setFormatter(fmt)
    root.handlers.clear()
    root.addHandler(fh)
    root.addHandler(sh)
    return log_path


def port_in_use(host: str, port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.5)
        try:
            return s.connect_ex((host, port)) == 0
        except OSError:
            return False


def write_pid(pid_path: Path) -> None:
    pid_path.write_text(str(os.getpid()), encoding="utf-8")


def load_config() -> dict:
    cfg_path = program_data_dir() / "config.json"
    if cfg_path.is_file():
        try:
            return json.loads(cfg_path.read_text(encoding="utf-8"))
        except Exception:
            return {}
    return {}


def warmup_async() -> None:
    def _run() -> None:
        # Wait for uvicorn to bind
        for _ in range(60):
            if port_in_use(HOST, PORT):
                break
            time.sleep(0.5)
        try:
            import urllib.request

            req = urllib.request.Request(
                f"http://{HOST}:{PORT}/warmup",
                method="POST",
                data=b"{}",
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=600) as resp:
                body = resp.read().decode("utf-8", errors="replace")
            logging.info("warmup ok: %s", body[:200])
        except Exception as exc:
            logging.warning("warmup failed (will load on first request): %s", exc)

    t = threading.Thread(target=_run, name="warmup", daemon=True)
    t.start()


def main() -> int:
    log_path = setup_logging()
    cfg = load_config()
    do_warmup = cfg.get("warmup", True)

    logging.info("=== EasyPeasy Classifier API starting ===")
    logging.info("api_dir=%s pid=%s log=%s", API_DIR, os.getpid(), log_path)

    if port_in_use(HOST, PORT):
        logging.info("port %s already in use — API already running; exiting", PORT)
        return 0

    pid_path = program_data_dir() / "classifier-api.pid"
    write_pid(pid_path)

    # Import app after logging is ready
    try:
        from server import app  # noqa: WPS433
    except Exception:
        logging.exception("failed to import server app")
        return 1

    if do_warmup:
        warmup_async()

    import uvicorn

    try:
        # Pass app object (single process) so models stay in one VRAM footprint.
        uvicorn.run(
            app,
            host=HOST,
            port=PORT,
            log_level="info",
            access_log=True,
        )
    except Exception:
        logging.exception("uvicorn exited with error")
        return 1
    finally:
        try:
            if pid_path.is_file() and pid_path.read_text(encoding="utf-8").strip() == str(
                os.getpid()
            ):
                pid_path.unlink(missing_ok=True)
        except OSError:
            pass

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

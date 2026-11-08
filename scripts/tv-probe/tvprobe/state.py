"""Private state folder: secrets and raw captures live here, never in the repo."""
from __future__ import annotations

import json
import os
import shutil
import time
from pathlib import Path

_FORBIDDEN_FIELD_PARTS = ("token", "secret", "code", "visitor", "cookie", "params")


def default_root() -> Path:
    env = os.environ.get("NOSLOP_PROBE_DIR")
    if env:
        return Path(env)
    return Path.home() / ".noslop-tv-probe"


MARKER = ".noslop-probe"  # wipe() deletes only a folder that holds this file


class State:
    def __init__(self, root: Path):
        self.root = Path(root)

    def _ensure_root(self) -> None:
        marker = self.root / MARKER
        if not self.root.exists():
            os.makedirs(self.root, mode=0o700, exist_ok=True)
        elif not marker.exists() and any(self.root.iterdir()):
            raise ValueError("%s exists and is not a probe state folder; point NOSLOP_PROBE_DIR elsewhere" % self.root)
        os.chmod(self.root, 0o700)
        if not marker.exists():
            os.close(os.open(str(marker), os.O_WRONLY | os.O_CREAT, 0o600))

    def path(self, name: str) -> Path:
        p = Path(name)
        if p.is_absolute() or ".." in p.parts or not p.parts:
            raise ValueError("state file names must stay inside the state folder")
        return self.root / p

    def _prepare(self, name: str) -> Path:
        target = self.path(name)
        self._ensure_root()
        if target.parent != self.root:
            os.makedirs(target.parent, mode=0o700, exist_ok=True)
            os.chmod(target.parent, 0o700)
        return target

    def write_json(self, name: str, obj) -> None:
        target = self._prepare(name)
        tmp = target.with_name(target.name + ".tmp")
        fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(obj, f, indent=2, sort_keys=True)
        os.chmod(tmp, 0o600)
        os.replace(tmp, target)

    def read_json(self, name: str, default=None):
        target = self.path(name)
        try:
            with open(target) as f:
                return json.load(f)
        except (FileNotFoundError, ValueError):
            return default

    def log(self, event: str, **fields) -> None:
        for key in fields:
            lowered = key.lower()
            if any(part in lowered for part in _FORBIDDEN_FIELD_PARTS):
                raise ValueError("log field name %r may carry a secret" % key)
        target = self._prepare("log.jsonl")
        record = {"event": event, "ts": round(time.time(), 3)}
        record.update(fields)
        fd = os.open(str(target), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a") as f:
            f.write(json.dumps(record, sort_keys=True, default=str) + "\n")
        os.chmod(target, 0o600)

    def wipe(self) -> None:
        """Delete the state folder. Raises when it is not a probe folder or is still there afterwards."""
        if self.root.is_symlink():
            raise ValueError("the state folder is a symlink; refusing to wipe it")
        if not self.root.exists():
            return
        if not (self.root / MARKER).is_file():
            raise ValueError("the folder is not a probe state folder (no %s); refusing to wipe it" % MARKER)
        shutil.rmtree(self.root, ignore_errors=True)
        if self.root.exists():
            raise OSError("the state folder could not be fully removed: %s" % self.root)

"""Write an offline, self-contained benchmark matrix viewer."""

from html import escape
import json
from pathlib import Path

from .analysis import atomic_output


def write_dashboard(directory: Path, matrix: dict, *, raw_prefix: str = "") -> None:
    template = Path(__file__).with_name("dashboard.html").read_text(encoding="utf-8")
    data = json.dumps(matrix, ensure_ascii=True, allow_nan=False, separators=(",", ":")).replace("<", "\\u003c")
    template = template.replace('href="raw/', 'href="' + escape(raw_prefix, quote=True))
    with atomic_output(directory / "dashboard.html") as stream:
        stream.write(template.replace("/* MATRIX_DATA */", data, 1))

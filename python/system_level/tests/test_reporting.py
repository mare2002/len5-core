"""Reporting regression checks independent of the simulator's cycle model."""

from contextlib import redirect_stdout
from io import StringIO
import json
from pathlib import Path
from random import Random
from statistics import fmean
from unittest import TestCase
from unittest.mock import patch

from system_level.__main__ import main
from system_level.analysis import experiments, summarize
from system_level.config import configure
from system_level.parallel import Progress
from system_level.results import benchmark_summary
from test_integration import temporary_build
from test_matrix import smt
from system_level.analysis import NORMAL, LEN5


class ReportingTests(TestCase):
    def test_grouped_resampling_preserves_percentiles(self):
        for n in (2, 3, 4, 5, 6):
            values = [.012, 56., .5, 132.23, .02, 177.][:n]
            rng = Random(0)
            means = sorted(fmean(rng.choices(values, k=n)) for _ in range(3000))
            summary = summarize(values, .9)
            for field, q in [("ci_low", (1-.9)/2), ("ci_high", 1-(1-.9)/2)]:
                pos = q*2999
                a, b = means[int(pos):int(pos)+2]
                self.assertEqual(summary[field], a + (pos-int(pos))*(b-a))

    def test_regeneration_presets_preserve_raw_files(self):
        with temporary_build() as temp:
            root = Path(temp)
            out = root / "simulation" / "benchmarks" / "test"
            plots = out / "plots"
            (plots / "performance").mkdir(parents=True)
            legacy = plots / "performance" / "ipc_by_benchmark.png"
            legacy.touch()
            raw = plots / "notes.csv"
            raw.write_text("notes")
            saved = out / "summary.json"
            rows = [smt(("a", "b"), arch, 42, i + 1) for i, arch in enumerate((NORMAL, LEN5))]
            saved.write_text(json.dumps(dict(suite="test", benchmarks=["a + b"], runs=rows, seeds=[42])))
            raw_input = saved.stat().st_mtime_ns
            for preset in ("detailed", "essential", "none"):
                args = ["system_level", "report", "--build-dir", str(root), "--input", str(saved),
                        "--plot-preset", preset, "--verbosity", "quiet"]
                with patch("sys.argv", args), patch("system_level.__main__.experiments", side_effect=AssertionError):
                    main()
                figures = list(plots.rglob("*.png"))
                self.assertEqual(bool(figures), preset != "none")
                self.assertEqual((out / "dashboard.html").exists(), preset != "none")
                self.assertFalse(legacy.exists())
                self.assertTrue((out / "summary.md").exists())
                self.assertEqual(raw.read_text(), "notes")
                self.assertEqual(saved.stat().st_mtime_ns, raw_input)
            with self.assertRaisesRegex(ValueError, "plotting.preset"):
                configure({"plotting": {"preset": "unknown"}})

    def test_failed_work_kept_and_counted(self):
        good = configure({"architectures": {"enabled": [NORMAL]}, "workload": {"instructions": 4},
                          "simulation": {"parallel": {"workers": 1}}})
        bad = configure({"architectures": {"enabled": [NORMAL]}, "workload": {"instructions": 9},
                         "simulation": {"max_cycles": 1, "parallel": {"workers": 1}}})
        progress = Progress("quiet")
        stream = StringIO()
        with redirect_stdout(stream):
            batch = experiments({"a": (good, {}), "b": (bad, {})}, [42], progress=progress, keep_partial=True)
        self.assertEqual(stream.getvalue(), "")
        summary = benchmark_summary("demo", batch)
        self.assertEqual([r["benchmark"] for r in summary["runs"]], ["a"])
        failure, = summary["failures"]
        self.assertEqual((failure["benchmark"], failure["architecture"], failure["seed"]), ("b", NORMAL, 42))
        self.assertIn("max_cycles", failure["error"])
        self.assertEqual((progress.counts["scheduled"], progress.counts["completed"], progress.counts["failed"]),
                         (2, 1, 1))

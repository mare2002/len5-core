import json
from html.parser import HTMLParser
from pathlib import Path
import unittest

from system_level.analysis import BLOCKS, IDEAL, IDEAL_OOO, LEN5, NORMAL
from system_level.dashboard import write_dashboard
from system_level.matrix import build_matrix, color_limits, heatmap_label
from test_integration import temporary_build


def smt(pair, arch, seed, ipc, ref=0, policy="reference_completion"):
    return {"benchmark": " + ".join(pair), "workloads": list(pair), "architecture": arch, "seed": seed,
            "smt_mode": "enabled", "measurement_policy": policy, "reference_thread": ref,
            "reference_benchmark": pair[ref], "cycles": 100, "ipc": ipc, "weighted_speedup": 1.5,
            "threads": [{"thread_id": t, "benchmark": name, "ipc": ipc / 2, "isolated_cycles": 100 * (t + 1),
                         "isolated_ipc": 1 / (t + 1), "instructions_per_iteration": 100}
                        for t, name in enumerate(pair)]}


class DashboardData(HTMLParser):
    def __init__(self):
        super().__init__()
        self.payload = ""
        self.in_payload = False
        self.sources = []
        self.links = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "script":
            self.in_payload = attrs.get("id") == "payload"
        if "src" in attrs:
            self.sources.append(attrs["src"])
        if tag == "a":
            self.links.append(attrs["href"])

    def handle_endtag(self, tag):
        if tag == "script":
            self.in_payload = False

    def handle_data(self, text):
        if self.in_payload:
            self.payload += text


class MatrixTests(unittest.TestCase):
    def test_ratios_pair_by_order_seed_and_reference(self):
        ab, ba = ("alpha", "beta"), ("beta", "alpha")
        rows = [smt(ab, NORMAL, 1, 1), smt(ab, LEN5, 1, 2), smt(ab, BLOCKS, 1, 1.2),
                smt(ab, NORMAL, 2, 4), smt(ab, LEN5, 2, 2), smt(ab, BLOCKS, 2, 2, ref=1),
                smt(ba, NORMAL, 1, 2), smt(ba, LEN5, 1, 1)]
        rows.reverse()
        data = build_matrix({"runs": rows, "seeds": [1, 2], "benchmark_pairs": {"missing": ["alpha", "alpha"]}})
        cells = {tuple(p["names"]): p for p in data["pairs"]}
        self.assertEqual(data["names"], ["alpha", "beta"])
        ratio = cells[ab]["architectures"][LEN5]["smt"]["vs_normal"]
        self.assertEqual((ratio["mean"], ratio["n"]), (1.25, 2))
        self.assertEqual(ratio["label"], "1.25")
        self.assertLess(ratio["low"], ratio["high"])
        self.assertEqual(cells[ba]["architectures"][LEN5]["smt"]["vs_normal"]["mean"], .5)
        self.assertEqual(cells[ab]["architectures"][BLOCKS]["smt"]["vs_normal"]["n"], 1)
        self.assertEqual(cells["alpha", "alpha"]["architectures"], {})
        self.assertNotIn(("beta", "beta"), cells)
        self.assertEqual(color_limits([.5, 1.25], True), (.5, 1.5))
        self.assertEqual(data["limits"]["smt/vs_normal"], (.5, 1.5))
        self.assertIn("fraction", data["labels"]["cdb_contention"])

    def test_isolated_and_relative_views_use_each_threads_own_sample(self):
        row = smt(("alpha", "alpha"), NORMAL, 11, 1.2)
        views = build_matrix({"runs": [row]})["pairs"][0]["architectures"][NORMAL]
        self.assertAlmostEqual(views["isolated"]["ipc"]["mean"], 200 / 300)
        self.assertEqual(views["isolated"]["thread_1_ipc"]["mean"], .5)
        self.assertAlmostEqual(views["relative"]["thread_1_ipc"]["mean"], 1.2)
        self.assertNotIn("ipc", views["relative"])
        self.assertIsNone(views["smt"]["ipc"]["low"])

    def test_ipc_uses_recorded_counts_over_the_shared_window(self):
        rows = []
        counts = {NORMAL: (127, 85), LEN5: (127, 71), BLOCKS: (127, 0), IDEAL: (127, 98), IDEAL_OOO: (127, 112)}
        for arch, committed in counts.items():
            cycles = 151
            row = smt(("alpha", "beta"), arch, 11, sum(committed) / cycles)
            row.update(cycles=cycles, committed=sum(committed))
            for thread, count in zip(row["threads"], committed, strict=True):
                thread.update(committed=count, ipc=count / cycles)
            rows.append(row)
        cell = build_matrix({"runs": rows})["pairs"][0]
        for row in rows:
            view = cell["architectures"][row["architecture"]]["smt"]
            for metric, record in (("ipc", row), ("thread_0_ipc", row["threads"][0]),
                                   ("thread_1_ipc", row["threads"][1])):
                self.assertEqual(view[metric]["mean"], record["committed"] / row["cycles"])
                self.assertEqual(view[metric]["label"], f"{record['ipc']:.2f}")
        self.assertEqual(heatmap_label(None, "ipc"), "—")
        self.assertAlmostEqual(cell["architectures"][IDEAL]["smt"]["vs_blocks"]["mean"], 225 / 127)
        self.assertAlmostEqual(cell["architectures"][IDEAL_OOO]["smt"]["vs_ideal"]["mean"], 239 / 225)
        self.assertEqual(heatmap_label(.137, "cdb_utilization"), "13.7%")
        self.assertEqual(heatmap_label(123000, "storage_bits"), "123.0k")

    def test_legacy_policy_and_single_thread_suite(self):
        rows = [smt(("A", "B"), arch, 7, 1, policy="fixed_cycles") for arch in (NORMAL, LEN5)]
        cell = build_matrix({"runs": rows})["pairs"][0]
        self.assertNotIn("vs_normal", cell["architectures"][LEN5]["smt"])
        isolated = {"benchmark": "solo", "architecture": NORMAL, "ipc": 1.25, "cycles": 80, "seed": 12}
        data = build_matrix({"runs": [isolated]})
        self.assertEqual(data["names"], ["solo"])
        self.assertEqual(list(data["pairs"][0]["architectures"][NORMAL]), ["isolated"])
        self.assertEqual(data["pairs"][0]["architectures"][NORMAL]["isolated"]["ipc"]["label"], "1.25")
        self.assertEqual(data["sort_ipc"], {"solo": 1.25})

    def test_hundred_ordered_pairs_in_one_offline_file(self):
        names = ["a</script>"] + [f"bench-{n}" for n in range(9)]
        rows = [smt((a, b), NORMAL, 7, i + 1) for i, a in enumerate(names) for b in names]
        matrix = build_matrix({"suite": "hundred", "runs": rows, "seeds": [7]})
        with temporary_build() as tmp:
            directory = Path(tmp)
            write_dashboard(directory, matrix, raw_prefix="../raw/")
            self.assertEqual([p.name for p in directory.iterdir()], ["dashboard.html"])
            html = (directory / "dashboard.html").read_text()
            parsed = DashboardData()
            parsed.feed(html)
            self.assertEqual(parsed.sources, [])
            self.assertFalse(any(url.startswith(("http:", "https:")) for url in parsed.links))
            self.assertIn("../raw/summary.json", parsed.links)
            payload = json.loads(parsed.payload)
            self.assertEqual(len(payload["pairs"]), 100)
            self.assertEqual(len({tuple(c["names"]) for c in payload["pairs"]}), 100)

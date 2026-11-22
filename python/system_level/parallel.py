"""Run independent simulations in a bounded process pool."""

from concurrent.futures import FIRST_COMPLETED, ProcessPoolExecutor, wait
from multiprocessing import get_context
import os
from pathlib import Path
from time import monotonic


class Progress:
    """Only the parent reports work. Counts exclude cache hits and unscheduled dependents."""

    def __init__(self, verbosity: str = "quiet"):
        self.verbosity = verbosity
        self.started = self.last_update = monotonic()
        self.counts = dict(completed=0, failed=0, calibration=0, isolated=0, joint=0,
                           workers=1, scheduled=0)

    def plan(self, isolated, joint: int, workers: int) -> None:
        calibration = sum(job.calibration for job in isolated.values())
        self.counts.update(calibration=calibration, isolated=len(isolated) - calibration,
                           joint=joint, scheduled=len(isolated) + joint, workers=workers)
        self.started = self.last_update = monotonic()
        if self.verbosity != "quiet":
            print(f"Planned {len(isolated) + joint} simulations on {workers} worker(s) "
                  f"({calibration} calibrations, {len(isolated) - calibration} isolated, {joint} joint).", flush=True)

    def finished(self, job, pending: int, error: Exception | None = None) -> None:
        self.counts["failed" if error else "completed"] += 1
        if self.verbosity == "verbose":
            print(f"{'Failed' if error else 'Completed'} {job}", flush=True)
        self.update(pending)

    def update(self, pending: int) -> None:
        now = monotonic()
        if self.verbosity != "quiet" and (now - self.last_update >= 5 or
                self.counts["completed"] + self.counts["failed"] == self.counts["scheduled"]):
            count = self.counts
            rate = 60 * count["completed"] / max(now - self.started, .001)
            print(f"Completed {count['completed']}/{count['scheduled']} · failed {count['failed']} · "
                  f"in flight {pending} · {rate:.0f} runs/min", flush=True)
            self.last_update = now


def available_cpus() -> int:
    affinity = getattr(os, "sched_getaffinity", None)
    cpus = len(affinity(0)) if affinity else os.cpu_count() or 1
    try:
        quota, period = Path("/sys/fs/cgroup/cpu.max").read_text().split()
        if quota != "max":
            cpus = min(cpus, max(1, (int(quota) + int(period) - 1) // int(period)))
    except (OSError, ValueError):
        pass
    return cpus


def worker_count(requested: int | str, tasks: int) -> int:
    # Each worker caches parsed programs, so automatic runs stay small even on large hosts.
    return max(1, min(4 if requested == "auto" else requested, tasks, available_cpus()))


def run_jobs(jobs: dict, execute, pool: ProcessPoolExecutor | None, workers: int,
             progress: Progress | None = None, failures: dict | None = None) -> dict:
    progress = progress or Progress()

    def failure(job, error):
        return RuntimeError(f"simulation failed for {job}: {type(error).__name__}: {error}")

    results = {}

    def collect(key, job, pending, result):
        try:
            results[key] = result()
        except Exception as error:
            progress.finished(job, pending, error)
            if failures is None:
                raise failure(job, error) from error
            failures[key] = str(failure(job, error))
        else:
            progress.finished(job, pending)

    if pool is None:
        for key, job in jobs.items():
            collect(key, job, 0, lambda: execute(job))
        return results

    pending = {}
    remaining = iter(jobs.items())

    def submit() -> None:
        for key, job in remaining:
            try:
                pending[pool.submit(execute, job)] = key, job
            except Exception as error:
                raise failure(job, error) from error
            if len(pending) >= 2 * workers:
                break

    try:
        submit()
        while pending:
            completed, _ = wait(pending, timeout=5, return_when=FIRST_COMPLETED)
            if not completed:
                progress.update(len(pending))
            for future in completed:
                key, job = pending.pop(future)
                collect(key, job, len(pending), future.result)
            submit()
    except BaseException:
        for future in pending:
            future.cancel()
        raise
    return results


def process_pool(workers: int) -> ProcessPoolExecutor:
    return ProcessPoolExecutor(max_workers=workers, mp_context=get_context("spawn"))

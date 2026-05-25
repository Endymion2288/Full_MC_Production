#!/usr/bin/env python3
"""Summarize completed HELAC matrix DAG jobs and their staged outputs."""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import subprocess
import tarfile
import tempfile
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple


COMPLETED_RE = re.compile(
    r"Node (?P<node>HELAC_\S+) job proc \((?P<cluster>\d+)\.0\.0\) completed successfully"
)
EVENT_RE = re.compile(r"最终待上传 LHE 事件数:\s*(?P<events>\d+)")
RAW_EVENT_RE = re.compile(r"原始 LHE 事件数:\s*(?P<events>\d+)")
ARCHIVE_RE = re.compile(r"HELAC output archive complete:\s*(?P<url>\S+)")
FORBIDDEN_RE = re.compile(r"Forbidden-channel marker uploaded:\s*(?P<url>\S+)")
LOG_RE = re.compile(r"完整日志已上传:\s*(?P<url>\S+)")
SIGMA_RE = re.compile(
    r"total sigma \(nb\)\s*=\s*(?P<sigma>[+-]?\d+(?:\.\d*)?[DEde][+-]?\d+)"
    r"\s*\+/-\s*(?P<err>[+-]?\d+(?:\.\d*)?[DEde][+-]?\d+)"
)
INIT_RE = re.compile(r"<init>\s*\n(?P<header>.*?)\n(?P<xsec>[+-]?\d+(?:\.\d*)?[Ee][+-]?\d+)", re.S)


@dataclass
class RemoteStat:
    exists: bool = False
    size: Optional[int] = None
    mtime: Optional[str] = None
    error: Optional[str] = None


@dataclass
class FinishedJob:
    node: str
    condor_cluster: int
    slug: str
    seed: int
    charm_state: str
    bottom_state: str
    extra_gluon: bool
    process: str
    status: str
    events: Optional[int]
    sigma_nb: Optional[float]
    sigma_err_nb: Optional[float]
    rel_err_percent: Optional[float]
    output_url: Optional[str]
    output_size: Optional[int]
    marker_url: Optional[str]
    marker_size: Optional[int]
    log_url: Optional[str]
    log_size: Optional[int]
    stdout_path: Optional[str]
    stderr_path: Optional[str]
    notes: str = ""


def run_text(cmd: List[str], check: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, check=check, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def fortran_float(value: str) -> float:
    return float(value.replace("D", "E").replace("d", "e"))


def remote_to_xrdfs_path(url: str) -> Tuple[str, str]:
    if not url.startswith("root://"):
        raise ValueError(f"not a root URL: {url}")
    rest = url[len("root://") :]
    host, _, path = rest.partition("/")
    return f"root://{host}", f"/{path.lstrip('/')}"


def stat_remote(url: Optional[str]) -> RemoteStat:
    if not url:
        return RemoteStat()
    try:
        host, path = remote_to_xrdfs_path(url)
    except ValueError as exc:
        return RemoteStat(error=str(exc))
    proc = run_text(["xrdfs", host, "stat", path])
    if proc.returncode != 0:
        return RemoteStat(error=(proc.stderr or proc.stdout).strip())
    stat = RemoteStat(exists=True)
    for line in proc.stdout.splitlines():
        line = line.strip()
        if line.startswith("Size:"):
            try:
                stat.size = int(line.split(":", 1)[1].strip())
            except ValueError:
                pass
        elif line.startswith("MTime:"):
            stat.mtime = line.split(":", 1)[1].strip()
    return stat


def completed_nodes(dagman_out: Path) -> List[Tuple[str, int]]:
    completed: List[Tuple[str, int]] = []
    for match in COMPLETED_RE.finditer(dagman_out.read_text(errors="replace")):
        completed.append((match.group("node"), int(match.group("cluster"))))
    return completed


def local_stdout(log_root: Path, slug: str, seed: int, cluster: int) -> Optional[Path]:
    candidates = sorted(log_root.glob(f"helac_matrix_{slug}_{seed}_{cluster}_0.stdout"))
    return candidates[-1] if candidates else None


def local_stderr(log_root: Path, slug: str, seed: int, cluster: int) -> Optional[Path]:
    candidates = sorted(log_root.glob(f"helac_matrix_{slug}_{seed}_{cluster}_0.stderr"))
    return candidates[-1] if candidates else None


def first_match(pattern: re.Pattern[str], text: str) -> Optional[str]:
    match = pattern.search(text)
    if not match:
        return None
    if "url" in match.groupdict():
        return match.group("url")
    if "events" in match.groupdict():
        return match.group("events")
    return match.group(1)


def event_count(text: str) -> Optional[int]:
    for pattern in (EVENT_RE, RAW_EVENT_RE):
        value = first_match(pattern, text)
        if value is not None:
            return int(value)
    return None


def safe_name(url: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", url).strip("_")


def download_archive(url: str, cache_dir: Path) -> Optional[Path]:
    cache_dir.mkdir(parents=True, exist_ok=True)
    target = cache_dir / safe_name(url)
    if target.exists() and target.stat().st_size > 0:
        return target
    proc = run_text(["xrdcp", "--nopbar", "--force", url, str(target)])
    if proc.returncode != 0:
        return None
    return target


def count_lhe_events_from_tar(archive: Path) -> Optional[int]:
    try:
        with tarfile.open(archive, "r:gz") as tar:
            lhe_names = [
                name
                for name in tar.getnames()
                if name.endswith(".lhe") and not name.endswith("_py8.lhe")
            ]
            if not lhe_names:
                lhe_names = [name for name in tar.getnames() if name.endswith(".lhe")]
            if not lhe_names:
                return None
            member = tar.extractfile(lhe_names[0])
            if member is None:
                return None
            count = 0
            for raw in member:
                if raw.strip() == b"<event>":
                    count += 1
            return count
    except (tarfile.TarError, OSError):
        return None


def extract_cross_section(archive: Path) -> Tuple[Optional[float], Optional[float], Optional[float]]:
    try:
        with tarfile.open(archive, "r:gz") as tar:
            screen_names = [name for name in tar.getnames() if name.endswith("screen_output.txt")]
            for name in screen_names:
                member = tar.extractfile(name)
                if member is None:
                    continue
                text = member.read().decode("utf-8", errors="replace")
                matches = list(SIGMA_RE.finditer(text))
                if matches:
                    match = matches[-1]
                    sigma = fortran_float(match.group("sigma"))
                    err = fortran_float(match.group("err"))
                    rel = abs(err / sigma) * 100.0 if sigma else None
                    return sigma, err, rel
            lhe_names = [name for name in tar.getnames() if name.endswith(".lhe")]
            for name in lhe_names:
                member = tar.extractfile(name)
                if member is None:
                    continue
                head = member.read(4096).decode("utf-8", errors="replace")
                match = INIT_RE.search(head)
                if match:
                    xsec_pb = float(match.group("xsec"))
                    return xsec_pb / 1000.0, None, None
    except (tarfile.TarError, OSError):
        pass
    return None, None, None


def build_summary(args: argparse.Namespace) -> List[FinishedJob]:
    metadata = json.loads(Path(args.metadata).read_text())
    jobs_by_node: Dict[str, dict] = {job["job_name"]: job for job in metadata["jobs"]}
    finished = completed_nodes(Path(args.dagman_out))
    log_root = Path(args.log_root)
    cache_dir = Path(args.cache_dir)
    rows: List[FinishedJob] = []

    for node, cluster in finished:
        job = jobs_by_node[node]
        slug = job["slug"]
        seed = int(job["seed"])
        stdout_path = local_stdout(log_root, slug, seed, cluster)
        stderr_path = local_stderr(log_root, slug, seed, cluster)
        stdout_text = stdout_path.read_text(errors="replace") if stdout_path else ""
        output_url = first_match(ARCHIVE_RE, stdout_text)
        marker_url = first_match(FORBIDDEN_RE, stdout_text)
        log_url = first_match(LOG_RE, stdout_text)
        events = event_count(stdout_text)
        status = "produced" if output_url else "forbidden" if marker_url else "completed_unknown"
        notes = ""

        output_stat = stat_remote(output_url)
        marker_stat = stat_remote(marker_url)
        log_stat = stat_remote(log_url)
        sigma_nb: Optional[float] = None
        sigma_err_nb: Optional[float] = None
        rel_err_percent: Optional[float] = None

        if output_url:
            archive = download_archive(output_url, cache_dir)
            if archive:
                sigma_nb, sigma_err_nb, rel_err_percent = extract_cross_section(archive)
                if events is None:
                    events = count_lhe_events_from_tar(archive)
            else:
                notes = "failed to download output archive"
        if status == "completed_unknown":
            notes = "no output archive or forbidden marker found in stdout"

        rows.append(
            FinishedJob(
                node=node,
                condor_cluster=cluster,
                slug=slug,
                seed=seed,
                charm_state=job["charm_state"],
                bottom_state=job["bottom_state"],
                extra_gluon=bool(job["extra_gluon"]),
                process=job["process"],
                status=status,
                events=events,
                sigma_nb=sigma_nb,
                sigma_err_nb=sigma_err_nb,
                rel_err_percent=rel_err_percent,
                output_url=output_url,
                output_size=output_stat.size,
                marker_url=marker_url,
                marker_size=marker_stat.size,
                log_url=log_url,
                log_size=log_stat.size,
                stdout_path=str(stdout_path) if stdout_path else None,
                stderr_path=str(stderr_path) if stderr_path else None,
                notes=notes,
            )
        )
    return rows


def write_csv(rows: Iterable[FinishedJob], path: Path) -> None:
    data = [asdict(row) for row in rows]
    if not data:
        path.write_text("")
        return
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(data[0]))
        writer.writeheader()
        writer.writerows(data)


def fmt(value: object) -> str:
    if value is None:
        return "-"
    if isinstance(value, float):
        return f"{value:.6g}"
    return str(value)


def write_markdown(rows: List[FinishedJob], path: Path) -> None:
    produced = [row for row in rows if row.status == "produced"]
    forbidden = [row for row in rows if row.status == "forbidden"]
    total_events = sum(row.events or 0 for row in produced)
    total_sigma = sum(row.sigma_nb or 0.0 for row in produced)
    lines = [
        "# HELAC Finished Job Summary",
        "",
        f"- Finished jobs: {len(rows)}",
        f"- Produced samples: {len(produced)}",
        f"- Forbidden/skipped channels: {len(forbidden)}",
        f"- Produced events: {total_events}",
        f"- Sum of reported produced-channel cross sections: {total_sigma:.6g} nb",
        "",
        "| node | status | seed | events | sigma_nb | sigma_err_nb | rel_err_% | output_or_marker |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for row in rows:
        output = row.output_url or row.marker_url or "-"
        lines.append(
            "| {node} | {status} | {seed} | {events} | {sigma} | {err} | {rel} | {output} |".format(
                node=row.node,
                status=row.status,
                seed=row.seed,
                events=fmt(row.events),
                sigma=fmt(row.sigma_nb),
                err=fmt(row.sigma_err_nb),
                rel=fmt(row.rel_err_percent),
                output=output,
            )
        )
    path.write_text("\n".join(lines) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metadata", default="generated/helac_matrix_eosuser/metadata.json")
    parser.add_argument("--dagman-out", default="generated/helac_matrix_eosuser/helac_matrix.dag.dagman.out")
    parser.add_argument("--log-root", default="log")
    parser.add_argument("--cache-dir", default=".cache/helac_finished_outputs")
    parser.add_argument("--output-dir", default="generated/helac_matrix_eosuser")
    args = parser.parse_args()

    rows = build_summary(args)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    write_csv(rows, output_dir / "finished_summary.csv")
    write_markdown(rows, output_dir / "finished_summary.md")
    (output_dir / "finished_summary.json").write_text(
        json.dumps([asdict(row) for row in rows], indent=2, sort_keys=True) + "\n"
    )

    produced = [row for row in rows if row.status == "produced"]
    forbidden = [row for row in rows if row.status == "forbidden"]
    print(f"Finished jobs: {len(rows)}")
    print(f"Produced samples: {len(produced)}")
    print(f"Forbidden/skipped channels: {len(forbidden)}")
    print(f"Produced events: {sum(row.events or 0 for row in produced)}")
    print(f"Produced-channel sigma sum: {sum(row.sigma_nb or 0.0 for row in produced):.6g} nb")
    print(f"Wrote: {output_dir / 'finished_summary.md'}")
    print(f"Wrote: {output_dir / 'finished_summary.csv'}")
    print(f"Wrote: {output_dir / 'finished_summary.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

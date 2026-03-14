#!/usr/bin/env python3
"""
色八重态夸克偶素 PDG 编码工具。

用途：
1. 把 HELAC-Onia 风格的旧八重态 PDG 编码转换为 Pythia8 OniaShower 使用的
   `99nqnsnrnLnJ` 格式。
2. 只在 LHE 的粒子行首列上做替换，避免误改事件权重或其他数字字段。
3. 为 HTCondor 小批量测试提供统一的扫描与校验入口。

兼容性：
1. worker 节点上的 `python3` 可能仍是 3.6，因此此脚本避免使用 3.7+ 专有语法。
"""

import argparse
import io
import json
import re
import sys
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


CHARMONIUM_CODES = {
    441,
    443,
    445,
    10441,
    10443,
    20443,
    9900441,
    9900443,
    9910441,
}

BOTTOMONIUM_CODES = {
    551,
    553,
    555,
    10551,
    10553,
    20553,
    9900551,
    9900553,
    9910551,
}


def is_charmonium(abs_pdg: int) -> bool:
    return abs_pdg in CHARMONIUM_CODES or 441000 < abs_pdg < 443200


def is_bottomonium(abs_pdg: int) -> bool:
    return abs_pdg in BOTTOMONIUM_CODES or 551000 < abs_pdg < 553200


def target_state_from_helac(abs_pdg: int) -> Optional[int]:
    """按 workbook_v2 当前使用的物理态，把 charmonium/bottomonium 映射到 J/psi/Upsilon(1S)。"""

    if is_charmonium(abs_pdg):
        return 443
    if is_bottomonium(abs_pdg):
        return 553
    return None


def convert_single_pdg(raw_pdg: int) -> Optional[int]:
    """
    按 HELAC 样例 Fortran 转换器的规则，把旧八重态编码转成 Pythia8 编码。

    返回：
    - `None`：不是需要处理的旧八重态编码
    - `int`：转换后的 PDG 编码，保留原本正负号
    """

    sign = -1 if raw_pdg < 0 else 1
    abs_pdg = abs(raw_pdg)
    if abs_pdg < 9_900_000:
        return None

    target_state = target_state_from_helac(abs_pdg)
    if target_state is None:
        return None

    remainder = abs_pdg - 9_900_000
    nq = (remainder // 100) % 10
    expected_nq = 4 if target_state == 443 else 5
    if nq != expected_nq:
        raise ValueError(
            f"旧 PDG 编码与目标物理态不一致: raw={raw_pdg}, target={target_state}"
        )

    if remainder == nq * 110 + 3:
        nS = 0
    elif remainder == nq * 110 + 1:
        nS = 1
    else:
        nS = 2

    nR = (target_state // 100000) % 10
    nL = (target_state // 10000) % 10
    nJ = target_state % 10
    converted = 9_900_000 + 10_000 * nq + 1_000 * nS + 100 * nR + 10 * nL + nJ
    return sign * converted


def iter_event_particle_lines(lines: Sequence[str]) -> Iterable[Tuple[int, str]]:
    """遍历 LHE 中 `<event>` 块内的粒子行。"""

    inside_event = False
    skip_header = False

    for index, line in enumerate(lines):
        stripped = line.lstrip()
        if stripped.startswith("<event"):
            inside_event = True
            skip_header = True
            continue
        if stripped.startswith("</event>"):
            inside_event = False
            continue
        if not inside_event:
            continue
        if skip_header:
            if stripped:
                skip_header = False
            continue
        if stripped:
            yield index, line


def rewrite_particle_line(line: str) -> Tuple[str, Optional[int], Optional[int]]:
    """只替换粒子行首列的 PDG 编码，保留其余列与空白。"""

    match = re.match(r"^(\s*)([-+]?\d+)(\s+.*)$", line.rstrip("\n"))
    if not match:
        return line, None, None

    prefix, token, suffix = match.groups()
    raw_pdg = int(token)
    converted = convert_single_pdg(raw_pdg)
    if converted is None or converted == raw_pdg:
        return line, raw_pdg, raw_pdg
    new_line = f"{prefix}{converted}{suffix}\n"
    return new_line, raw_pdg, converted


def convert_lhe_text(lines: Sequence[str]) -> Tuple[List[str], Dict[str, object]]:
    """返回替换后的文本和转换摘要。"""

    updated = list(lines)
    converted_pairs: List[Tuple[int, int]] = []
    legacy_codes: List[int] = []
    final_octet_codes: List[int] = []

    for index, line in iter_event_particle_lines(lines):
        new_line, raw_pdg, converted = rewrite_particle_line(line)
        updated[index] = new_line
        if raw_pdg is None:
            continue
        if abs(raw_pdg) >= 9_900_000:
            legacy_codes.append(raw_pdg)
        if converted is not None and abs(converted) >= 9_900_000:
            final_octet_codes.append(converted)
        if converted is not None and converted != raw_pdg:
            converted_pairs.append((raw_pdg, converted))

    summary = {
        "legacy_codes": sorted(set(legacy_codes)),
        "final_octet_codes": sorted(set(final_octet_codes)),
        "converted_pairs": sorted(set(converted_pairs)),
        "n_converted_particles": len(converted_pairs),
    }
    return updated, summary


def scan_lhe_file(path: Path) -> Dict[str, object]:
    """扫描 LHE 文件，报告旧编码与最终八重态编码。"""

    lines = path.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
    _, summary = convert_lhe_text(lines)

    final_legacy_codes = []
    final_octet_codes = []
    for _, line in iter_event_particle_lines(lines):
        match = re.match(r"^\s*([-+]?\d+)\s+", line)
        if not match:
            continue
        pdg = int(match.group(1))
        if abs(pdg) >= 9_900_000:
            if str(abs(pdg)).startswith("9900"):
                final_legacy_codes.append(pdg)
            final_octet_codes.append(pdg)

    summary["final_legacy_codes_in_file"] = sorted(set(final_legacy_codes))
    summary["final_octet_codes_in_file"] = sorted(set(final_octet_codes))
    return summary


def convert_file(path: Path, inplace: bool) -> Dict[str, object]:
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
    updated, summary = convert_lhe_text(lines)
    if inplace and updated != list(lines):
        path.write_text("".join(updated), encoding="utf-8")
    return summary


def print_summary(path: Path, summary: Dict[str, object]) -> None:
    print(f"[INFO] LHE 文件: {path}")
    print(f"[INFO] 旧编码粒子数: {summary['n_converted_particles']}")
    print(f"[INFO] 替换对照: {summary['converted_pairs']}")
    print(f"[INFO] 文件中的八重态编码: {summary['final_octet_codes_in_file']}")
    print(f"[INFO] 文件中的旧编码残留: {summary['final_legacy_codes_in_file']}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="HELAC 八重态 PDG 编码工具")
    subparsers = parser.add_subparsers(dest="command")

    convert_parser = subparsers.add_parser("convert-file", help="把 LHE 文件中的旧编码原地改写为 Pythia8 编码")
    convert_parser.add_argument("path", help="LHE 文件路径")
    convert_parser.add_argument("--in-place", action="store_true", help="直接覆盖原文件")
    convert_parser.add_argument("--json", action="store_true", help="输出 JSON 摘要")

    scan_parser = subparsers.add_parser("scan", help="扫描 LHE 文件中的八重态编码")
    scan_parser.add_argument("path", help="LHE 文件路径")
    scan_parser.add_argument("--json", action="store_true", help="输出 JSON 摘要")
    scan_parser.add_argument(
        "--fail-on-legacy",
        action="store_true",
        help="若文件中仍存在旧的 9900xxxx 编码则返回非零",
    )

    pdg_parser = subparsers.add_parser("convert-pdg", help="把单个旧 PDG 编码转换为 Pythia8 编码")
    pdg_parser.add_argument("pdg", type=int, help="原始 PDG 编码")

    return parser


def configure_output_streams() -> None:
    """在 ASCII locale 的 worker 上强制使用 UTF-8 输出，避免中文日志触发编码错误。"""

    for stream_name in ("stdout", "stderr"):
        stream = getattr(sys, stream_name, None)
        if stream is None:
            continue
        buffer = getattr(stream, "buffer", None)
        if buffer is None:
            continue
        try:
            reconfigure = getattr(stream, "reconfigure", None)
            if callable(reconfigure):
                reconfigure(encoding="utf-8", errors="backslashreplace")
            else:
                wrapped = io.TextIOWrapper(
                    buffer,
                    encoding="utf-8",
                    errors="backslashreplace",
                    line_buffering=True,
                )
                setattr(sys, stream_name, wrapped)
        except Exception:
            # 只做日志层面的兼容兜底，不影响主逻辑。
            pass


def main(argv: Optional[Sequence[str]] = None) -> int:
    configure_output_streams()
    parser = build_parser()
    args = parser.parse_args(argv)

    if not args.command:
        parser.print_help(sys.stderr)
        return 2

    if args.command == "convert-pdg":
        converted = convert_single_pdg(args.pdg)
        if converted is None:
            print(args.pdg)
        else:
            print(converted)
        return 0

    path = Path(args.path)
    if not path.exists():
        parser.error(f"文件不存在: {path}")

    if args.command == "convert-file":
        summary = convert_file(path, inplace=args.in_place)
        # convert_file 的摘要描述的是“会/已做的替换”；再补一次最终扫描更直接。
        summary.update(scan_lhe_file(path if args.in_place else path))
        if args.json:
            print(json.dumps(summary, indent=2, ensure_ascii=False))
        else:
            print_summary(path, summary)
        return 0

    if args.command == "scan":
        summary = scan_lhe_file(path)
        if args.json:
            print(json.dumps(summary, indent=2, ensure_ascii=False))
        else:
            print_summary(path, summary)
        if args.fail_on_legacy and summary["final_legacy_codes_in_file"]:
            return 1
        return 0

    parser.error(f"未知命令: {args.command}")
    return 1


if __name__ == "__main__":
    sys.exit(main())

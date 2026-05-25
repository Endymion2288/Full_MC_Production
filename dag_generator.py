#!/usr/bin/env python3
"""
基于 workbook_v2.md 的 HTCondor DAGMan 工作流生成器。

目标：
1. 用统一的数据模型描述 LHE pool、campaign 和测试配置。
2. 生成可直接提交到 HTCondor 的 DAG、DAGMan 配置和元数据摘要。
3. 提供环境校验、配置列表和小批量测试 DAG 生成入口。
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import tarfile
from collections import OrderedDict
from dataclasses import dataclass
from datetime import datetime
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUTPUT_DIR = os.path.join(BASE_DIR, "generated")
TEST_OUTPUT_DIR = os.path.join(BASE_DIR, "tests", "generated")

EOS_HOST = "cceos.ihep.ac.cn"
EOS_XRDFS_TARGET = EOS_HOST
EOS_PATH_BASE = "/eos/ihep/cms/store/user/xcheng/MC_Production_v3"
EOS_BASE = f"root://{EOS_HOST}/{EOS_PATH_BASE}"
STORAGE_SITE = "T2_CN_Beijing"
DEFAULT_TEST_CAMPAIGNS = ("JJP_DPS2_CS", "JJP_DPS2_G", "JUP_DPS1")
POOL_SCAN_CACHE_ENV = "DAG_GENERATOR_POOL_SCAN_CACHE"

REQUIRED_FILES = (
    "common/octet_pdg.py",
    "lhe_generation/run_helac.sh",
    "processing/run_chain.sh",
    "processing/templates/lhe_gen.sub",
    "processing/templates/processing.sub",
    "processing/templates/summary.sub",
    "processing/templates/summary.sh",
    "common/cmssw_configs/hepmc_to_GENSIM.py",
)

REQUIRED_COMMANDS = (
    "python3",
    "condor_submit",
    "condor_submit_dag",
    "condor_q",
    "xrdfs",
    "xrdcp",
    "apptainer",
)

LHE_SUBMIT_TEMPLATE_LXPLUS = "processing/templates/lhe_gen.sub"
PROCESSING_SUBMIT_TEMPLATE_LXPLUS = "processing/templates/processing.sub"
LHE_SUBMIT_TEMPLATE_HEPTHU = "processing/templates/lhe_gen_hepthu.sub"
PROCESSING_SUBMIT_TEMPLATE_HEPTHU = "processing/templates/processing_hepthu.sub"
SUMMARY_SUBMIT_TEMPLATE = "processing/templates/summary.sub"
DEFAULT_LXPLUS_LOG_DIR = "/afs/cern.ch/user/x/xcheng/condor/MC_Production_DAG/T2_CN_Beijing/log"
DEFAULT_HEPTHU_OUTPUT_BASE = os.path.expanduser("~/MC_Production_result")


@dataclass(frozen=True)
class MachineEnv:
    """Submit-host and storage profile selected from the unified CLI."""

    name: str
    description: str
    backend: str
    submit_host: str
    storage_description: str
    storage_mode: str
    required_commands: Tuple[str, ...]
    log_dir: str = ""
    local_output_base: str = ""
    lhe_submit_template: str = LHE_SUBMIT_TEMPLATE_LXPLUS
    processing_submit_template: str = PROCESSING_SUBMIT_TEMPLATE_LXPLUS
    summary_submit_template: str = SUMMARY_SUBMIT_TEMPLATE
    target_machine: str = ""
    aliases: Tuple[str, ...] = ()

    @property
    def uses_local_storage(self) -> bool:
        return self.storage_mode == "local"

    @property
    def is_hepjob(self) -> bool:
        return self.backend == "hepjob"

    def to_dict(self) -> Dict[str, object]:
        return {
            "name": self.name,
            "aliases": list(self.aliases),
            "description": self.description,
            "backend": self.backend,
            "submit_host": self.submit_host,
            "storage_description": self.storage_description,
            "storage_mode": self.storage_mode,
            "log_dir": self.log_dir,
            "local_output_base": self.local_output_base,
            "lhe_submit_template": self.lhe_submit_template,
            "processing_submit_template": self.processing_submit_template,
            "summary_submit_template": self.summary_submit_template,
            "target_machine": self.target_machine,
        }


MACHINE_ENVS: "OrderedDict[str, MachineEnv]" = OrderedDict(
    [
        (
            "lxplus_t2_ihep",
            MachineEnv(
                name="lxplus_t2_ihep",
                aliases=("t2_cn_beijing",),
                description="CERN lxplus HTCondor submit; store LHE/output on IHEP T2_CN_Beijing via XRootD.",
                backend="condor_dagman",
                submit_host="CERN lxplus",
                storage_description="IHEP T2_CN_Beijing XRootD storage",
                storage_mode="t2_xrootd",
                required_commands=REQUIRED_COMMANDS,
                log_dir=DEFAULT_LXPLUS_LOG_DIR,
            ),
        ),
        (
            "hepthu",
            MachineEnv(
                name="hepthu",
                description="Tsinghua hepthu HTCondor submit; store LHE/output on a local filesystem.",
                backend="condor_dagman",
                submit_host="hepthu HTCondor",
                storage_description="Local filesystem storage",
                storage_mode="local",
                required_commands=("python3", "condor_submit", "condor_submit_dag", "condor_q", "apptainer"),
                local_output_base=DEFAULT_HEPTHU_OUTPUT_BASE,
                lhe_submit_template=LHE_SUBMIT_TEMPLATE_HEPTHU,
                processing_submit_template=PROCESSING_SUBMIT_TEMPLATE_HEPTHU,
                target_machine="nd-16.hepthu.com",
            ),
        ),
        (
            "ihep",
            MachineEnv(
                name="ihep",
                description="IHEP/lxlogin HepJob submit; store LHE/output on IHEP T2_CN_Beijing via XRootD.",
                backend="hepjob",
                submit_host="IHEP lxlogin/HepJob",
                storage_description="IHEP T2_CN_Beijing XRootD storage",
                storage_mode="t2_xrootd",
                required_commands=("python3", "hep_sub", "hep_q", "hep_rm", "xrdfs", "xrdcp", "apptainer"),
            ),
        ),
    ]
)

MACHINE_ENV_ALIASES = {
    alias: name
    for name, machine_env in MACHINE_ENVS.items()
    for alias in (machine_env.aliases + (name,))
}

BUNDLE_NAMES = {
    "lhe": "lhe_runtime_bundle.tar.gz",
    "processing": "processing_runtime_bundle.tar.gz",
    "summary": "summary_runtime_bundle.tar.gz",
    "proxy": "proxy_bundle.tar.gz",
}

POOL_DAG_LABELS = {
    "pool_jpsi_CSCO_g": "JpsiG_CSCO",
    "pool_upsilon_CSCO_g": "UpsilonG_CSCO",
    "pool_gg": "GG",
    "pool_2jpsi_cs": "DoubleJpsiCS",
    "pool_2jpsi_g": "DoubleJpsiG",
    "pool_jpsi_upsilon_CSCO": "JpsiUpsilon_CSCO",
}


def canonical_mode(mode: str) -> str:
    """把历史别名统一到新的 shower 模式枚举。"""

    normalized = mode.strip().lower()
    alias_map = {
        "normal": "normal",
        "phi": "phi_mpi_off",
        "phi_default": "phi_mpi_off",
        "phi_mode1": "phi_mpi_off",
        "phi_mpi_off": "phi_mpi_off",
        "sps": "phi_mpi_off",
        "phi_mode2": "phi_mpi_on_gluon",
        "phi_mpi_on_gluon": "phi_mpi_on_gluon",
        "phi_gluon": "phi_mpi_on_gluon",
    }
    if normalized not in alias_map:
        raise ValueError(f"未知的 shower 模式: {mode}")
    return alias_map[normalized]


class LHEPool:
    """单个 LHE pool 的生成配置。"""

    def __init__(
        self,
        name: str,
        description: str,
        process_lines: Sequence[str] = (),
        min_pt_conia: float = 6.0,
        min_pt_bonia: float = 4.0,
        min_pt_q: float = 0.0,
        notes: str = "",
        seed_offset: int = 0,
        storage_name: Optional[str] = None,
        variants: Sequence[str] = (),
        public: bool = True,
    ):
        self.name = name
        self.description = description
        self.process_lines = list(process_lines)
        self.min_pt_conia = min_pt_conia
        self.min_pt_bonia = min_pt_bonia
        self.min_pt_q = min_pt_q
        self.notes = notes
        self.seed_offset = seed_offset
        self.storage_name = storage_name or name
        self.variants = list(variants)
        self.public = public

    @property
    def process_text(self) -> str:
        if self.is_composite:
            return " + ".join(self.variants)
        return "\n".join(self.process_lines)

    @property
    def is_composite(self) -> bool:
        return bool(self.variants)

    def to_dict(self) -> Dict[str, object]:
        return {
            "name": self.name,
            "description": self.description,
            "process_lines": self.process_lines,
            "min_pt_conia": self.min_pt_conia,
            "min_pt_bonia": self.min_pt_bonia,
            "min_pt_q": self.min_pt_q,
            "notes": self.notes,
            "storage_name": self.storage_name,
            "variants": self.variants,
            "public": self.public,
        }


class Campaign:
    """单个 physics campaign 的定义。"""

    def __init__(
        self,
        name: str,
        analysis_type: str,
        inputs: Sequence[str],
        shower_modes: Sequence[str],
        description: str,
        notes: str = "",
    ):
        if len(inputs) != len(shower_modes):
            raise ValueError(f"{name}: inputs 与 shower_modes 数量不一致")
        self.name = name
        self.analysis_type = analysis_type
        self.inputs = list(inputs)
        self.shower_modes = [canonical_mode(mode) for mode in shower_modes]
        self.description = description
        self.notes = notes

    @property
    def n_sources(self) -> int:
        return len(self.inputs)

    def to_dict(self) -> Dict[str, object]:
        return {
            "name": self.name,
            "analysis_type": self.analysis_type,
            "inputs": self.inputs,
            "shower_modes": self.shower_modes,
            "description": self.description,
            "notes": self.notes,
        }


class WorkflowOptions:
    """一次 DAG 生成的公共控制选项。"""

    def __init__(
        self,
        jobs_per_campaign: int,
        max_events: int,
        enable_ntuple: bool,
        efficiency_ntuple: bool,
        cleanup: bool,
        test_mode: bool,
        scan_existing: bool,
        force_generate_lhe: bool,
        proxy_path: str,
        lhe_unwevt: Optional[int],
        dagman_max_jobs_submitted: int,
        dagman_max_jobs_idle: int,
        machine_env: Optional[MachineEnv] = None,
        local_log_dir: str = "",
        local_output_base: str = "",
    ):
        self.machine_env = machine_env or MACHINE_ENVS["lxplus_t2_ihep"]
        self.jobs_per_campaign = jobs_per_campaign
        self.max_events = max_events
        self.enable_ntuple = enable_ntuple
        self.efficiency_ntuple = efficiency_ntuple
        self.cleanup = cleanup
        self.test_mode = test_mode
        self.scan_existing = scan_existing
        self.force_generate_lhe = force_generate_lhe
        self.proxy_path = proxy_path
        self.lhe_unwevt = lhe_unwevt
        self.dagman_max_jobs_submitted = dagman_max_jobs_submitted
        self.dagman_max_jobs_idle = dagman_max_jobs_idle
        self.local_log_dir = local_log_dir or self.machine_env.log_dir
        self.local_output_base = local_output_base or self.machine_env.local_output_base

    def resolved_lhe_unwevt(self) -> int:
        if self.lhe_unwevt is not None:
            return self.lhe_unwevt
        return 100 if self.test_mode else 100000

    def to_dict(self) -> Dict[str, object]:
        return {
            "machine_env": self.machine_env.to_dict(),
            "jobs_per_campaign": self.jobs_per_campaign,
            "max_events": self.max_events,
            "enable_ntuple": self.enable_ntuple,
            "efficiency_ntuple": self.efficiency_ntuple,
            "cleanup": self.cleanup,
            "test_mode": self.test_mode,
            "scan_existing": self.scan_existing,
            "force_generate_lhe": self.force_generate_lhe,
            "proxy_path": self.proxy_path,
            "lhe_unwevt": self.resolved_lhe_unwevt(),
            "dagman_max_jobs_submitted": self.dagman_max_jobs_submitted,
            "dagman_max_jobs_idle": self.dagman_max_jobs_idle,
            "local_log_dir": self.local_log_dir,
            "local_output_base": self.local_output_base,
        }


LHE_POOLS: "OrderedDict[str, LHEPool]" = OrderedDict(
    [
        (
            "pool_jpsi_CSCO_g",
            LHEPool(
                name="pool_jpsi_CSCO_g",
                description="pp -> J/psi + X with CrystalBall pT model",
                process_lines=(
                    "addon/pp_psiX_CrystalBall",
                    "state.inp = 1  # J/psi",
                ),
                notes="J/psi 基础池使用 HELAC-Onia addon/pp_psiX_CrystalBall，CrystalBall 参数取 addon input 默认。",
                seed_offset=0,
            ),
        ),
        (
            "pool_upsilon_CSCO_g",
            LHEPool(
                name="pool_upsilon_CSCO_g",
                description="pp -> Upsilon(1S) + X with CrystalBall pT model",
                process_lines=(
                    "addon/pp_psiX_CrystalBall",
                    "state.inp = 3  # Upsilon(1S)",
                ),
                notes="Upsilon(1S) 基础池使用 HELAC-Onia addon/pp_psiX_CrystalBall，CrystalBall 参数取 addon input 默认。",
                seed_offset=20000,
            ),
        ),
        (
            "pool_gg",
            LHEPool(
                name="pool_gg",
                description="gg -> gg",
                process_lines=("generate g g > g g",),
                min_pt_conia=0.0,
                min_pt_bonia=0.0,
                min_pt_q=4.0,
                notes="QCD 背景胶子池。",
                seed_offset=40000,
            ),
        ),
        (
            "pool_2jpsi_cs",
            LHEPool(
                name="pool_2jpsi_cs",
                description="gg -> J/psi + J/psi (born 子过程)",
                process_lines=("generate g g > cc~(3S11) cc~(3S11)",),
                notes="double-J/psi born/color-singlet SPS 基础池。",
                seed_offset=60000,
                public=True,
            ),
        ),
        (
            "pool_2jpsi_g",
            LHEPool(
                name="pool_2jpsi_g",
                description="gg -> J/psi + J/psi + g",
                process_lines=("generate g g > cc~(3S11) cc~(3S11) g",),
                notes="double-J/psi + g SPS 基础池。",
                seed_offset=70000,
            ),
        ),
        (
            "pool_jpsi_upsilon_CSCO",
            LHEPool(
                name="pool_jpsi_upsilon_CSCO",
                description="gg -> J/psi + Upsilon",
                process_lines=("generate g g > jpsi y(1s)",),
                notes="J/psi + Upsilon SPS 基础池。",
                seed_offset=80000,
            ),
        ),
    ]
)


CAMPAIGNS: "OrderedDict[str, Campaign]" = OrderedDict(
    [
        (
            "JJP_SPS_CS",
            Campaign(
                name="JJP_SPS_CS",
                analysis_type="JJP",
                inputs=("pool_2jpsi_cs",),
                shower_modes=("phi_mpi_off",),
                description="double-J/psi born/color-singlet 单源做 phi-enriched shower，不与带额外 gluon 的样本混合。",
            ),
        ),
        (
            "JJP_SPS_G",
            Campaign(
                name="JJP_SPS_G",
                analysis_type="JJP",
                inputs=("pool_2jpsi_g",),
                shower_modes=("phi_mpi_off",),
                description="double-J/psi + g 单源做 phi-enriched shower，不与 born 样本混合。",
            ),
        ),
        (
            "JJP_DPS1",
            Campaign(
                name="JJP_DPS1",
                analysis_type="JJP",
                inputs=("pool_jpsi_CSCO_g", "pool_jpsi_CSCO_g"),
                shower_modes=("normal", "phi_mpi_off"),
                description="两个 J/psi(CS+CO)+g 源混合，覆盖 normal/phi 默认组合。",
            ),
        ),
        (
            "JJP_DPS2_CS",
            Campaign(
                name="JJP_DPS2_CS",
                analysis_type="JJP",
                inputs=("pool_2jpsi_cs", "pool_gg"),
                shower_modes=("normal", "phi_mpi_off"),
                description="double-J/psi born 源与 gg 池混合。",
            ),
        ),
        (
            "JJP_DPS2_G",
            Campaign(
                name="JJP_DPS2_G",
                analysis_type="JJP",
                inputs=("pool_2jpsi_g", "pool_gg"),
                shower_modes=("normal", "phi_mpi_off"),
                description="double-J/psi + g 源与 gg 池混合。",
            ),
        ),
        (
            "JJP_TPS",
            Campaign(
                name="JJP_TPS",
                analysis_type="JJP",
                inputs=("pool_jpsi_CSCO_g", "pool_jpsi_CSCO_g", "pool_gg"),
                shower_modes=("normal", "normal", "phi_mpi_off"),
                description="三源混合的 JJP TPS 方案。",
            ),
        ),
        (
            "JUP_SPS",
            Campaign(
                name="JUP_SPS",
                analysis_type="JUP",
                inputs=("pool_jpsi_upsilon_CSCO",),
                shower_modes=("phi_mpi_off",),
                description="J/psi + Upsilon 单源做 phi-enriched shower。",
            ),
        ),
        (
            "JUP_DPS1",
            Campaign(
                name="JUP_DPS1",
                analysis_type="JUP",
                inputs=("pool_jpsi_CSCO_g", "pool_upsilon_CSCO_g"),
                shower_modes=("phi_mpi_off", "normal"),
                description="J/psi 走 phi 默认模式，Upsilon 走 normal。",
            ),
        ),
        (
            "JUP_DPS2",
            Campaign(
                name="JUP_DPS2",
                analysis_type="JUP",
                inputs=("pool_jpsi_CSCO_g", "pool_upsilon_CSCO_g"),
                shower_modes=("normal", "phi_mpi_off"),
                description="J/psi 走 normal，Upsilon 走 phi 默认模式。",
            ),
        ),
        (
            "JUP_DPS3",
            Campaign(
                name="JUP_DPS3",
                analysis_type="JUP",
                inputs=("pool_jpsi_upsilon_CSCO", "pool_gg"),
                shower_modes=("normal", "phi_mpi_off"),
                description="J/psi+Upsilon 源与 gg 池混合。",
            ),
        ),
        (
            "JUP_TPS",
            Campaign(
                name="JUP_TPS",
                analysis_type="JUP",
                inputs=("pool_jpsi_CSCO_g", "pool_upsilon_CSCO_g", "pool_gg"),
                shower_modes=("normal", "normal", "phi_mpi_off"),
                description="三源混合的 JUP TPS 方案。",
            ),
        ),
    ]
)


MODE_LABELS = OrderedDict(
    [
        ("normal", "普通 shower"),
        ("phi_mpi_off", "phi-enriched 默认模式：关闭 MPI，循环 hadronize 直到找到 phi"),
        ("phi_mpi_on_gluon", "phi-enriched 扩展模式：开启 MPI，并要求 phi 与 LHE 胶子关联"),
    ]
)

_POOL_SCAN_CACHE: Optional[Dict[str, int]] = None


def real_pool_names(pool_name: str) -> List[str]:
    return [pool_name]


def pool_storage_name(pool_name: str) -> str:
    return LHE_POOLS[pool_name].storage_name


def machine_env_choices() -> Tuple[str, ...]:
    choices = ["auto"]
    for name, machine_env in MACHINE_ENVS.items():
        choices.append(name)
        choices.extend(machine_env.aliases)
    return tuple(choices)


def detect_machine_env_name() -> str:
    hostname = socket.gethostname().lower()
    cwd = os.path.abspath(os.getcwd()).lower()

    if "lxplus" in hostname:
        return "lxplus_t2_ihep"
    if "hepthu" in hostname or hostname.startswith("nd-") or "/home/storage29/" in cwd:
        return "hepthu"
    if "ihep" in hostname or "lxlogin" in hostname:
        return "ihep"
    return "lxplus_t2_ihep"


def resolve_machine_env(name: str) -> MachineEnv:
    if name == "auto":
        name = detect_machine_env_name()
    canonical_name = MACHINE_ENV_ALIASES.get(name)
    if not canonical_name:
        raise ValueError(f"未知 machine env: {name}")
    return MACHINE_ENVS[canonical_name]


def required_files_for_env(machine_env: MachineEnv) -> Tuple[str, ...]:
    required = [
        "common/octet_pdg.py",
        "lhe_generation/run_helac.sh",
        "processing/run_chain.sh",
        machine_env.lhe_submit_template,
        machine_env.processing_submit_template,
        machine_env.summary_submit_template,
        "processing/templates/summary.sh",
        "common/cmssw_configs/hepmc_to_GENSIM.py",
    ]
    if machine_env.name == "hepthu":
        required.extend(
            [
                "lhe_generation/condor_wrappers/run_lhe_gen.sh",
                "processing/condor_wrappers/run_processing.sh",
            ]
        )
    deduped: List[str] = []
    for relative_path in required:
        if relative_path and relative_path not in deduped:
            deduped.append(relative_path)
    return tuple(deduped)


def proxy_candidates_for_env(machine_env: Optional[MachineEnv] = None) -> List[str]:
    machine_env = machine_env or resolve_machine_env("auto")
    candidates: List[str] = []

    if machine_env.name == "lxplus_t2_ihep":
        persistent_proxy = os.path.expanduser(f"~/x509up_u{os.getuid()}")
        candidates.append(persistent_proxy)

    env_proxy = os.environ.get("X509_USER_PROXY")
    if env_proxy:
        candidates.append(env_proxy)

    tmp_proxy = f"/tmp/x509up_u{os.getuid()}"
    candidates.append(tmp_proxy)

    workfs2_proxy = f"/workfs2/cms/chengxing/Full_MC_Production/x509up_u{os.getuid()}"
    candidates.append(workfs2_proxy)

    deduped: List[str] = []
    for candidate in candidates:
        if candidate and candidate not in deduped:
            deduped.append(candidate)
    return deduped


def detect_proxy_path(machine_env_name: str = "auto") -> str:
    """探测当前 profile 可用的代理路径。"""

    try:
        machine_env = resolve_machine_env(machine_env_name)
    except ValueError:
        machine_env = resolve_machine_env("auto")

    candidates = proxy_candidates_for_env(machine_env)

    for candidate in candidates:
        if candidate and os.path.exists(candidate):
            return candidate
    return candidates[0]


def ensure_local_xrootd_proxy(proxy_path: str) -> str:
    """给本地 xrdfs/xrdcp 准备一个可直接使用的代理副本。"""

    tmp_proxy = f"/tmp/x509up_u{os.getuid()}"
    candidates: List[str] = []
    if tmp_proxy:
        candidates.append(tmp_proxy)
    if proxy_path and proxy_path not in candidates:
        candidates.append(proxy_path)

    for candidate in candidates:
        if not candidate or not os.path.exists(candidate):
            continue
        ok, _, _ = check_proxy_valid(candidate)
        if ok and candidate == tmp_proxy:
            return candidate

    if proxy_path and os.path.exists(proxy_path):
        try:
            shutil.copyfile(proxy_path, tmp_proxy)
            os.chmod(tmp_proxy, 0o600)
            ok, _, _ = check_proxy_valid(tmp_proxy)
            if ok:
                return tmp_proxy
        except OSError:
            pass

    return proxy_path


def command_exists(command: str) -> bool:
    return shutil.which(command) is not None


def load_pool_scan_cache() -> Dict[str, int]:
    """可选地从外部 JSON 读取已知 pool 计数，绕开本地 xrdfs 子进程兼容性问题。"""

    global _POOL_SCAN_CACHE
    if _POOL_SCAN_CACHE is not None:
        return _POOL_SCAN_CACHE

    cache_path = os.environ.get(POOL_SCAN_CACHE_ENV, "").strip()
    if not cache_path:
        _POOL_SCAN_CACHE = {}
        return _POOL_SCAN_CACHE

    try:
        with open(cache_path, "r", encoding="utf-8") as handle:
            raw = json.load(handle)
    except (OSError, ValueError, TypeError):
        _POOL_SCAN_CACHE = {}
        return _POOL_SCAN_CACHE

    cache: Dict[str, int] = {}
    if isinstance(raw, dict):
        for pool_name, value in raw.items():
            if isinstance(value, dict):
                value = value.get("remote_count")
            try:
                cache[str(pool_name)] = int(value)
            except (TypeError, ValueError):
                continue

    _POOL_SCAN_CACHE = cache
    return _POOL_SCAN_CACHE


def check_proxy_valid(proxy_path: str) -> Tuple[bool, Optional[int], Optional[str]]:
    """返回代理是否可用、剩余秒数以及错误信息。"""

    if not proxy_path or not os.path.exists(proxy_path):
        return False, None, f"代理文件不存在: {proxy_path}"

    if not command_exists("voms-proxy-info"):
        return True, None, None

    try:
        result = subprocess.run(
            ["voms-proxy-info", "-file", proxy_path, "-timeleft"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10,
            check=False,
        )
    except Exception as exc:
        return False, None, str(exc)

    if result.returncode != 0:
        return False, None, result.stderr.strip() or "voms-proxy-info 返回非零"

    try:
        timeleft = int(result.stdout.strip())
    except ValueError:
        return False, None, f"无法解析代理剩余时间: {result.stdout!r}"

    return timeleft > 0, timeleft, None


def count_lhe_files_on_t2(pool_name: str, proxy_path: str) -> Tuple[int, Optional[str]]:
    """统计远端 pool 内已有的 .lhe 文件数量。"""

    cache = load_pool_scan_cache()
    if pool_name in cache:
        return cache[pool_name], None

    storage_name = pool_storage_name(pool_name)
    local_proxy_path = ensure_local_xrootd_proxy(proxy_path)
    env = os.environ.copy()
    env["X509_USER_PROXY"] = local_proxy_path

    try:
        result = subprocess.run(
            ["xrdfs", EOS_XRDFS_TARGET, "ls", f"{EOS_PATH_BASE}/lhe_pools/{storage_name}"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=30,
            check=False,
            env=env,
        )
    except Exception as exc:
        return 0, str(exc)

    if result.returncode != 0:
        stderr = result.stderr.strip()
        if "No such file" in stderr or "Unable to locate" in stderr:
            return 0, None
        return 0, stderr or "xrdfs ls 返回非零"

    count = sum(1 for line in result.stdout.splitlines() if line.strip().endswith(".lhe"))
    return count, None


def count_lhe_files_local(pool_name: str, local_output_base: str) -> Tuple[int, Optional[str]]:
    """统计本地 pool 内已有的 .lhe 文件数量。"""

    cache = load_pool_scan_cache()
    cache_key = f"local_{pool_name}"
    if cache_key in cache:
        return cache[cache_key], None

    storage_name = pool_storage_name(pool_name)
    local_pool_dir = os.path.join(local_output_base, "lhe_pools", storage_name)
    try:
        if not os.path.exists(local_pool_dir):
            return 0, None
        count = sum(1 for filename in os.listdir(local_pool_dir) if filename.endswith(".lhe"))
        return count, None
    except Exception as exc:
        return 0, str(exc)


def pool_remote_path(pool_name: str, local_output_base: str = "") -> str:
    if local_output_base:
        return os.path.join(local_output_base, "lhe_pools", pool_storage_name(pool_name))
    return f"{EOS_BASE}/lhe_pools/{pool_storage_name(pool_name)}"


def scan_existing_pools(
    pool_requirements: Dict[str, int],
    proxy_path: str,
    local_output_base: str = "",
) -> Dict[str, Dict[str, object]]:
    """扫描已有 LHE 池，数量不足时视为需要全量重生。"""

    result: Dict[str, Dict[str, object]] = OrderedDict()
    for pool_name, required_count in pool_requirements.items():
        if local_output_base:
            count, error = count_lhe_files_local(pool_name, local_output_base)
        else:
            count, error = count_lhe_files_on_t2(pool_name, proxy_path)
        result[pool_name] = {
            "required_count": required_count,
            "remote_count": count,
            "use_existing": error is None and count >= required_count,
            "error": error,
            "remote_path": pool_remote_path(pool_name, local_output_base),
        }
    return result


def expand_campaign_selection(items: Sequence[str]) -> List[str]:
    """支持 ALL/JJP_ALL/JUP_ALL 和逗号分隔写法。"""

    if not items:
        raise ValueError("至少需要指定一个 campaign")

    resolved: List[str] = []
    for item in items:
        for token in [part.strip() for part in item.split(",") if part.strip()]:
            if token == "ALL":
                resolved.extend(CAMPAIGNS.keys())
            elif token == "JJP_ALL":
                resolved.extend(name for name in CAMPAIGNS if name.startswith("JJP"))
            elif token == "JUP_ALL":
                resolved.extend(name for name in CAMPAIGNS if name.startswith("JUP"))
            elif token in CAMPAIGNS:
                resolved.append(token)
            else:
                raise ValueError(f"未知的 campaign: {token}")

    deduped: List[str] = []
    seen = set()
    for name in resolved:
        if name not in seen:
            deduped.append(name)
            seen.add(name)
    return deduped


def compute_pool_requirements(campaign_names: Sequence[str], jobs_per_campaign: int) -> Dict[str, int]:
    """统计本次 DAG 对每个 LHE pool 的最小文件需求量。"""

    pool_requirements: Dict[str, int] = OrderedDict()
    for campaign_name in campaign_names:
        campaign = CAMPAIGNS[campaign_name]
        for pool_name in campaign.inputs:
            for real_pool_name in real_pool_names(pool_name):
                pool_requirements.setdefault(real_pool_name, 0)
                pool_requirements[real_pool_name] += jobs_per_campaign
    return pool_requirements


def validate_efficiency_campaigns(campaign_names: Sequence[str]) -> None:
    """Efficiency ntuples are currently defined only for JpsiJpsiPhi/JJP."""

    unsupported = [name for name in campaign_names if CAMPAIGNS[name].analysis_type != "JJP"]
    if unsupported:
        raise ValueError(
            "--efficiency-ntuple 目前只支持 JJP/JpsiJpsiPhi campaigns；不支持: "
            + ", ".join(unsupported)
        )


def build_ntuple_manifest(
    campaign_names: Sequence[str],
    jobs_per_campaign: int,
    local_output_base: str = "",
) -> Dict[str, List[str]]:
    """Build the downstream multileppat efficiency file manifest."""

    manifest: Dict[str, List[str]] = OrderedDict()
    for campaign_name in campaign_names:
        campaign = CAMPAIGNS[campaign_name]
        if campaign.analysis_type != "JJP":
            continue
        if local_output_base:
            manifest[campaign_name] = [
                os.path.join(local_output_base, "output", campaign_name, str(job_index), "output_ntuple.root")
                for job_index in range(jobs_per_campaign)
            ]
        else:
            manifest[campaign_name] = [
                f"{EOS_BASE}/output/{campaign_name}/{job_index}/output_ntuple.root"
                for job_index in range(jobs_per_campaign)
            ]
    return manifest


def bool_string(value: bool) -> str:
    return "true" if value else "false"


def dag_escape(value: object) -> str:
    """DAG VARS 使用双引号，这里只做最小必要转义。"""

    text = str(value)
    return text.replace("\\", "\\\\").replace('"', '\\"')


def ensure_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)


def ensure_submit_visible_output_dir(output_dir: str) -> None:
    """确保输出目录使用持久存储（workfs2 或 AFS），而非临时目录。"""

    normalized = os.path.abspath(output_dir)
    for prefix in ("/tmp/", "/var/tmp/"):
        if normalized.startswith(prefix):
            msg = (
                f"输出目录不能位于 {prefix[:-1]}: {normalized}。"
                "请改用 workfs2 路径，避免节点读取不到作业文件。"
            )
            print(f"警告: {msg}")
            return



def pool_dag_label(pool_name: str) -> str:
    return POOL_DAG_LABELS.get(pool_name, pool_name.replace("pool_", ""))


def build_bundle(bundle_path: str, items: Sequence[Tuple[str, str]]) -> None:
    """把运行时需要的文件打成 tar.gz，worker 侧统一解压后运行。"""

    ensure_dir(os.path.dirname(bundle_path))
    with tarfile.open(bundle_path, "w:gz") as archive:
        for source_path, arcname in items:
            archive.add(source_path, arcname=arcname, recursive=True)


def build_proxy_bundle(output_dir: str, proxy_path: str) -> Tuple[str, str]:
    """把当前代理单独打包，worker 上解压后直接作为 X509_USER_PROXY 使用。"""

    if not proxy_path or not os.path.exists(proxy_path):
        raise FileNotFoundError(f"代理文件不存在，无法打包: {proxy_path}")

    bundle_name = BUNDLE_NAMES["proxy"]
    bundle_path = os.path.join(output_dir, bundle_name)
    build_bundle(bundle_path, ((proxy_path, os.path.join("credentials", "x509_user_proxy")),))
    return bundle_path, bundle_name


def prepare_runtime_assets(output_dir: str) -> Dict[str, str]:
    """生成 LHE / processing / summary 运行 bundle。"""

    ensure_dir(output_dir)
    assets: Dict[str, str] = OrderedDict()

    lhe_bundle_name = BUNDLE_NAMES["lhe"]
    lhe_bundle_path = os.path.join(output_dir, lhe_bundle_name)
    build_bundle(
        lhe_bundle_path,
        (
            (os.path.join(BASE_DIR, "lhe_generation", "run_helac.sh"), "runtime/lhe_generation/run_helac.sh"),
            (
                os.path.join(BASE_DIR, "lhe_generation", "input_templates", "user.inp"),
                "runtime/lhe_generation/input_templates/user.inp",
            ),
            (
                os.path.join(BASE_DIR, "lhe_generation", "lhe_pythia6_pythia8.f"),
                "runtime/lhe_generation/lhe_pythia6_pythia8.f",
            ),
            (
                os.path.join(BASE_DIR, "common", "packages", "helac_package.tar.gz"),
                "runtime/lhe_generation/helac_package.tar.gz",
            ),
            (os.path.join(BASE_DIR, "common", "octet_pdg.py"), "runtime/common/octet_pdg.py"),
        ),
    )
    assets["lhe_bundle_path"] = lhe_bundle_path
    assets["lhe_bundle_name"] = lhe_bundle_name

    processing_items: List[Tuple[str, str]] = [
        (os.path.join(BASE_DIR, "processing", "run_chain.sh"), "runtime/processing/run_chain.sh"),
        (
            os.path.join(BASE_DIR, "processing", "pythia_shower"),
            "runtime/processing/pythia_shower",
        ),
        (
            os.path.join(BASE_DIR, "common", "cmssw_configs"),
            "runtime/common/cmssw_configs",
        ),
        (os.path.join(BASE_DIR, "common", "octet_pdg.py"), "runtime/common/octet_pdg.py"),
    ]
    for package_name in ("jjp_code.tar.gz", "jup_code.tar.gz"):
        package_path = os.path.join(BASE_DIR, "common", "packages", package_name)
        if os.path.exists(package_path):
            processing_items.append(
                (
                    package_path,
                    os.path.join("runtime", "common", "packages", package_name),
                )
            )

    processing_bundle_name = BUNDLE_NAMES["processing"]
    processing_bundle_path = os.path.join(output_dir, processing_bundle_name)
    build_bundle(processing_bundle_path, processing_items)
    assets["processing_bundle_path"] = processing_bundle_path
    assets["processing_bundle_name"] = processing_bundle_name

    summary_bundle_name = BUNDLE_NAMES["summary"]
    summary_bundle_path = os.path.join(output_dir, summary_bundle_name)
    build_bundle(
        summary_bundle_path,
        (
            (
                os.path.join(BASE_DIR, "processing", "templates", "summary.sh"),
                "runtime/processing/templates/summary.sh",
            ),
        ),
    )
    assets["summary_bundle_path"] = summary_bundle_path
    assets["summary_bundle_name"] = summary_bundle_name
    return assets


class DAGBuilder:
    """负责生成 DAG 内容和元数据。"""

    def __init__(
        self,
        output_dir: str,
        options: WorkflowOptions,
        existing_pools: Dict[str, Dict[str, object]],
        pool_requirements: Dict[str, int],
        runtime_assets: Dict[str, str],
    ):
        self.output_dir = output_dir
        self.options = options
        self.existing_pools = existing_pools
        self.pool_requirements = pool_requirements
        self.runtime_assets = runtime_assets
        self.generated_jobs_by_pool: Dict[str, List[str]] = OrderedDict()
        self.generated_specs_by_pool: Dict[str, List[str]] = OrderedDict()
        self.allocations_by_pool: Dict[str, int] = OrderedDict()
        self.dag_lines: List[str] = []
        self.metadata: Dict[str, object] = OrderedDict()

    def seed_for_pool_index(self, pool_name: str, index: int) -> int:
        pool = LHE_POOLS[pool_name]
        seed = 100 + pool.seed_offset + index
        if seed >= 100000:
            seed = 110 + (seed % 80000)
        return seed

    def pool_uses_existing(self, pool_name: str) -> bool:
        info = self.existing_pools.get(pool_name, {})
        return bool(info.get("use_existing"))

    def lhe_resource_request(self) -> Tuple[str, str, str]:
        if self.options.test_mode:
            return "4", "8GB", "8GB"
        return "8", "15GB", "10GB"

    def processing_resource_request(self) -> Tuple[str, str, str]:
        if os.environ.get("PREMIX_INPUT_MODE") == "localcache":
            return "4", "12GB", os.environ.get("PREMIX_LOCALCACHE_REQUEST_DISK", "80GB")
        if self.options.test_mode:
            return "4", "12GB", "20GB"
        return "8", "20GB", "50GB"

    def ensure_lhe_jobs(self, pool_name: str, required_count: int) -> None:
        """全局共享同一个 pool 的生成节点，避免跨 campaign 重复生成。"""

        if self.pool_uses_existing(pool_name):
            return

        pool = LHE_POOLS[pool_name]
        if pool.is_composite:
            raise ValueError(f"复合池 {pool_name} 不能直接生成 LHE job")
        jobs = self.generated_jobs_by_pool.setdefault(pool_name, [])
        specs = self.generated_specs_by_pool.setdefault(pool_name, [])

        while len(jobs) < required_count:
            index = len(jobs)
            seed = self.seed_for_pool_index(pool_name, index)
            job_name = f"LHE_{pool_dag_label(pool_name)}_{index}"
            request_cpus, request_memory, request_disk = self.lhe_resource_request()
            jobs.append(job_name)
            specs.append(f"GEN:{pool_name}:{index}:{seed}")
            self.dag_lines.append(
                f"JOB {job_name} {os.path.join(BASE_DIR, self.options.machine_env.lhe_submit_template)}"
            )
            self.dag_lines.append(
                "VARS {job} pool=\"{pool}\" seed=\"{seed}\" "
                "min_pt_conia=\"{min_pt_conia}\" min_pt_bonia=\"{min_pt_bonia}\" "
                "min_pt_q=\"{min_pt_q}\" unwevt=\"{unwevt}\" test_mode=\"{test_mode}\" "
                "request_cpus=\"{request_cpus}\" request_memory=\"{request_memory}\" request_disk=\"{request_disk}\" "
                "lhe_bundle_path=\"{lhe_bundle_path}\" lhe_bundle_name=\"{lhe_bundle_name}\" "
                "proxy_bundle_path=\"{proxy_bundle_path}\" proxy_bundle_name=\"{proxy_bundle_name}\" "
                "log_dir=\"{log_dir}\" local_output_base=\"{local_output_base}\" "
                "lhe_wrapper_path=\"{lhe_wrapper_path}\" target_machine=\"{target_machine}\"".format(
                    job=job_name,
                    pool=dag_escape(pool.name),
                    seed=dag_escape(seed),
                    min_pt_conia=dag_escape(pool.min_pt_conia),
                    min_pt_bonia=dag_escape(pool.min_pt_bonia),
                    min_pt_q=dag_escape(pool.min_pt_q),
                    unwevt=dag_escape(self.options.resolved_lhe_unwevt()),
                    test_mode=dag_escape(bool_string(self.options.test_mode)),
                    request_cpus=dag_escape(request_cpus),
                    request_memory=dag_escape(request_memory),
                    request_disk=dag_escape(request_disk),
                    lhe_bundle_path=dag_escape(self.runtime_assets["lhe_bundle_path"]),
                    lhe_bundle_name=dag_escape(self.runtime_assets["lhe_bundle_name"]),
                    proxy_bundle_path=dag_escape(self.runtime_assets["proxy_bundle_path"]),
                    proxy_bundle_name=dag_escape(self.runtime_assets["proxy_bundle_name"]),
                    log_dir=dag_escape(self.options.local_log_dir),
                    local_output_base=dag_escape(self.options.local_output_base),
                    lhe_wrapper_path=dag_escape(
                        os.path.join(BASE_DIR, "lhe_generation", "condor_wrappers", "run_lhe_gen.sh")
                    ),
                    target_machine=dag_escape(self.options.machine_env.target_machine),
                )
            )
            self.dag_lines.append(f"RETRY {job_name} 2")

    def allocate_input_spec(self, pool_name: str, job_index: int, usage_index: int) -> Tuple[str, List[str]]:
        """为 processing 节点分配输入引用和父节点依赖。"""

        if self.pool_uses_existing(pool_name):
            return f"EOS:{pool_name}:{job_index}:{usage_index}", []

        next_index = self.allocations_by_pool.setdefault(pool_name, 0)
        self.ensure_lhe_jobs(pool_name, next_index + 1)
        job_name = self.generated_jobs_by_pool[pool_name][next_index]
        spec = self.generated_specs_by_pool[pool_name][next_index]
        self.allocations_by_pool[pool_name] = next_index + 1
        return spec, [job_name]

    def add_processing_job(self, campaign_name: str, job_index: int) -> str:
        campaign = CAMPAIGNS[campaign_name]
        input_specs: List[str] = []
        parent_jobs: List[str] = []
        usage_counter: Dict[str, int] = {}

        for pool_name in campaign.inputs:
            usage_index = usage_counter.get(pool_name, 0)
            usage_counter[pool_name] = usage_index + 1
            spec, parents = self.allocate_input_spec(pool_name, job_index, usage_index)
            input_specs.append(spec)
            parent_jobs.extend(parents)

        job_name = f"PROC_{campaign_name}_{job_index}"
        request_cpus, request_memory, request_disk = self.processing_resource_request()
        self.dag_lines.append(
            f"JOB {job_name} {os.path.join(BASE_DIR, self.options.machine_env.processing_submit_template)}"
        )
        self.dag_lines.append(
            "VARS {job} campaign=\"{campaign}\" job_id=\"{job_id}\" "
            "inputs=\"{inputs}\" modes=\"{modes}\" analysis=\"{analysis}\" "
            "n_sources=\"{n_sources}\" max_events=\"{max_events}\" "
            "enable_ntuple=\"{enable_ntuple}\" efficiency_ntuple=\"{efficiency_ntuple}\" cleanup=\"{cleanup}\" "
            "request_cpus=\"{request_cpus}\" request_memory=\"{request_memory}\" request_disk=\"{request_disk}\" "
            "processing_bundle_path=\"{processing_bundle_path}\" "
            "processing_bundle_name=\"{processing_bundle_name}\" "
            "proxy_bundle_path=\"{proxy_bundle_path}\" proxy_bundle_name=\"{proxy_bundle_name}\" "
            "log_dir=\"{log_dir}\" local_output_base=\"{local_output_base}\" "
            "processing_wrapper_path=\"{processing_wrapper_path}\" target_machine=\"{target_machine}\" "
            "premix_input_mode=\"{premix_input_mode}\" "
            "premix_redirector=\"{premix_redirector}\" "
            "premix_cache_files=\"{premix_cache_files}\" "
            "premix_cache_redirector=\"{premix_cache_redirector}\"".format(
                job=job_name,
                campaign=dag_escape(campaign.name),
                job_id=dag_escape(job_index),
                inputs=dag_escape(",".join(input_specs)),
                modes=dag_escape(",".join(campaign.shower_modes)),
                analysis=dag_escape(campaign.analysis_type),
                n_sources=dag_escape(campaign.n_sources),
                max_events=dag_escape(self.options.max_events),
                enable_ntuple=dag_escape(bool_string(self.options.enable_ntuple)),
                efficiency_ntuple=dag_escape(bool_string(self.options.efficiency_ntuple)),
                cleanup=dag_escape(bool_string(self.options.cleanup)),
                request_cpus=dag_escape(request_cpus),
                request_memory=dag_escape(request_memory),
                request_disk=dag_escape(request_disk),
                processing_bundle_path=dag_escape(self.runtime_assets["processing_bundle_path"]),
                processing_bundle_name=dag_escape(self.runtime_assets["processing_bundle_name"]),
                proxy_bundle_path=dag_escape(self.runtime_assets["proxy_bundle_path"]),
                proxy_bundle_name=dag_escape(self.runtime_assets["proxy_bundle_name"]),
                log_dir=dag_escape(self.options.local_log_dir),
                local_output_base=dag_escape(self.options.local_output_base),
                processing_wrapper_path=dag_escape(
                    os.path.join(BASE_DIR, "processing", "condor_wrappers", "run_processing.sh")
                ),
                target_machine=dag_escape(self.options.machine_env.target_machine),
                premix_input_mode=dag_escape(os.environ.get("PREMIX_INPUT_MODE", "eoscms")),
                premix_redirector=dag_escape(os.environ.get("PREMIX_REDIRECTOR", "root://eoscms.cern.ch")),
                premix_cache_files=dag_escape(os.environ.get("PREMIX_CACHE_FILES", "1")),
                premix_cache_redirector=dag_escape(
                    os.environ.get("PREMIX_CACHE_REDIRECTOR", os.environ.get("PREMIX_REDIRECTOR", "root://eoscms.cern.ch"))
                ),
            )
        )
        self.dag_lines.append(f"RETRY {job_name} 1")
        if parent_jobs:
            self.dag_lines.append(f"PARENT {' '.join(parent_jobs)} CHILD {job_name}")
        return job_name

    def build(self, campaign_names: Sequence[str], dag_filename: str) -> str:
        dagman_config_path = os.path.join(self.output_dir, "dagman.config")
        processing_jobs: List[str] = []

        self.dag_lines = [
            "# ================================================",
            "# workbook_v2 MC 生产 DAG",
            f"# 生成时间: {datetime.now().isoformat()}",
            f"# Campaigns: {', '.join(campaign_names)}",
            f"# 每个 campaign 作业数: {self.options.jobs_per_campaign}",
            f"# 测试模式: {bool_string(self.options.test_mode)}",
            "# ================================================",
            "",
            f"CONFIG {dagman_config_path}",
            "",
        ]

        for pool_name, required_count in self.pool_requirements.items():
            self.ensure_lhe_jobs(pool_name, required_count)

        for campaign_name in campaign_names:
            campaign = CAMPAIGNS[campaign_name]
            self.dag_lines.append(f"# -------- Campaign: {campaign.name} --------")
            self.dag_lines.append(f"# {campaign.description}")
            if campaign.notes:
                self.dag_lines.append(f"# 备注: {campaign.notes}")
            for job_index in range(self.options.jobs_per_campaign):
                processing_jobs.append(self.add_processing_job(campaign_name, job_index))
            self.dag_lines.append("")

        if processing_jobs:
            self.dag_lines.append("# -------- 汇总节点 --------")
            self.dag_lines.append(f"FINAL SUMMARY {os.path.join(BASE_DIR, self.options.machine_env.summary_submit_template)}")
            self.dag_lines.append(
                "VARS SUMMARY summary_bundle_path=\"{summary_bundle_path}\" "
                "summary_bundle_name=\"{summary_bundle_name}\" "
                "log_dir=\"{log_dir}\"".format(
                    summary_bundle_path=dag_escape(self.runtime_assets["summary_bundle_path"]),
                    summary_bundle_name=dag_escape(self.runtime_assets["summary_bundle_name"]),
                    log_dir=dag_escape(self.options.local_log_dir),
                )
            )

        self.metadata = OrderedDict(
            [
                ("created_at", datetime.now().isoformat()),
                ("dag_path", os.path.join(self.output_dir, dag_filename)),
                ("dagman_config_path", dagman_config_path),
                ("options", self.options.to_dict()),
                ("runtime_assets", self.runtime_assets),
                ("campaigns", [CAMPAIGNS[name].to_dict() for name in campaign_names]),
                (
                    "pool_plan",
                    OrderedDict(
                        (
                            pool_name,
                            {
                                "pool": LHE_POOLS[pool_name].to_dict(),
                                "scan": self.existing_pools.get(pool_name, {}),
                                "generated_jobs": list(self.generated_jobs_by_pool.get(pool_name, [])),
                            },
                        )
                        for pool_name in self.existing_pools
                    ),
                ),
                (
                    "ntuple_manifest",
                    build_ntuple_manifest(
                        campaign_names,
                        self.options.jobs_per_campaign,
                        self.options.local_output_base,
                    )
                    if self.options.efficiency_ntuple
                    else OrderedDict(),
                ),
            ]
        )
        return "\n".join(self.dag_lines)


def render_dagman_config(options: WorkflowOptions) -> str:
    return "\n".join(
        (
            "# DAGMan 基础配置",
            f"DAGMAN_MAX_JOBS_SUBMITTED = {options.dagman_max_jobs_submitted}",
            f"DAGMAN_MAX_JOBS_IDLE = {options.dagman_max_jobs_idle}",
            "DAGMAN_MAX_SUBMITS_PER_INTERVAL = 20",
            "DAGMAN_SUBMIT_DELAY = 1",
            "DAGMAN_SUPPRESS_NOTIFICATION = True",
            "DAGMAN_GENERATE_RESCUE_DAG = True",
            "",
        )
    )


def write_generated_files(
    output_dir: str,
    dag_filename: str,
    dag_content: str,
    dagman_config_content: str,
    metadata: Dict[str, object],
) -> Tuple[str, str, str]:
    ensure_dir(output_dir)
    dag_path = os.path.join(output_dir, dag_filename)
    config_path = os.path.join(output_dir, "dagman.config")
    metadata_path = os.path.join(output_dir, "metadata.json")

    with open(dag_path, "w", encoding="utf-8") as handle:
        handle.write(dag_content)

    with open(config_path, "w", encoding="utf-8") as handle:
        handle.write(dagman_config_content)

    with open(metadata_path, "w", encoding="utf-8") as handle:
        json.dump(metadata, handle, indent=2, ensure_ascii=False)
        handle.write("\n")

    return dag_path, config_path, metadata_path


def write_ntuple_manifest(output_dir: str, manifest: Dict[str, List[str]]) -> str:
    manifest_path = os.path.join(output_dir, "ntuple_manifest.json")
    with open(manifest_path, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    return manifest_path


def print_pools() -> None:
    print("\n可用 LHE pools")
    print("=" * 72)
    for pool in LHE_POOLS.values():
        if not pool.public:
            continue
        print(f"- {pool.name}")
        print(f"  描述: {pool.description}")
        print(f"  过程: {pool.process_text}")
        print(
            f"  cuts: min_pt_conia={pool.min_pt_conia}, "
            f"min_pt_bonia={pool.min_pt_bonia}, min_pt_q={pool.min_pt_q}"
        )
        if pool.notes:
            print(f"  备注: {pool.notes}")
        print()


def print_campaigns() -> None:
    print("\n可用 campaigns")
    print("=" * 72)
    for campaign in CAMPAIGNS.values():
        print(f"- {campaign.name}")
        print(f"  分析类型: {campaign.analysis_type}")
        print(f"  输入池: {' + '.join(campaign.inputs)}")
        print(f"  shower 模式: {' / '.join(campaign.shower_modes)}")
        print(f"  描述: {campaign.description}")
        if campaign.notes:
            print(f"  备注: {campaign.notes}")
        print()


def validate_environment(
    campaign_names: Optional[Sequence[str]],
    proxy_path: str,
    scan_existing: bool,
    strict_analysis_packages: bool,
    machine_env: Optional[MachineEnv] = None,
    local_output_base: str = "",
) -> int:
    machine_env = machine_env or MACHINE_ENVS["lxplus_t2_ihep"]
    if machine_env.uses_local_storage and not local_output_base:
        local_output_base = machine_env.local_output_base
    required = campaign_names or []
    exit_code = 0

    print("环境校验")
    print("=" * 72)
    print(f"Machine env: {machine_env.name}")
    print(f"Submit host: {machine_env.submit_host}")
    print(f"Storage: {machine_env.storage_description}")
    if local_output_base:
        print(f"Local output base: {local_output_base}")
    print()

    print("命令检查:")
    for command in machine_env.required_commands:
        ok = command_exists(command)
        status = "OK" if ok else "缺失"
        print(f"  - {command:<18} {status}")
        if not ok:
            exit_code = 1

    print("\n文件检查:")
    for relative_path in required_files_for_env(machine_env):
        path = os.path.join(BASE_DIR, relative_path)
        ok = os.path.exists(path)
        status = "OK" if ok else "缺失"
        print(f"  - {relative_path:<40} {status}")
        if not ok:
            exit_code = 1

    print("\n包检查:")
    package_checks = [
        ("common/packages/helac_package.tar.gz", True),
        ("common/packages/jjp_code.tar.gz", strict_analysis_packages),
        ("common/packages/jup_code.tar.gz", strict_analysis_packages),
    ]
    for relative_path, required_flag in package_checks:
        path = os.path.join(BASE_DIR, relative_path)
        ok = os.path.exists(path)
        status = "OK" if ok else ("缺失(可选)" if not required_flag else "缺失")
        print(f"  - {relative_path:<40} {status}")
        if required_flag and not ok:
            exit_code = 1

    print("\n代理检查:")
    proxy_ok, timeleft, proxy_error = check_proxy_valid(proxy_path)
    if proxy_ok:
        if timeleft is None:
            print(f"  - 代理路径: {proxy_path} (未检查剩余时间)")
        else:
            print(f"  - 代理路径: {proxy_path}")
            print(f"  - 剩余时间: {timeleft} 秒")
    else:
        print(f"  - 代理不可用: {proxy_error or proxy_path}")
        if scan_existing and not local_output_base:
            exit_code = 1

    if required:
        print("\nCampaign 需求:")
        pool_requirements = compute_pool_requirements(required, 1)
        for pool_name, count in pool_requirements.items():
            print(f"  - {pool_name:<24} 至少 {count} 个文件")

        if scan_existing and (proxy_ok or local_output_base):
            scan_target = "本地" if local_output_base else "远端"
            print(f"\n{scan_target} pool 扫描:")
            scan = scan_existing_pools(pool_requirements, proxy_path, local_output_base)
            for pool_name, info in scan.items():
                status = "复用已有文件" if info["use_existing"] else "需要重新生成"
                error = info.get("error")
                suffix = f", 错误={error}" if error else ""
                print(
                    f"  - {pool_name:<24} "
                    f"{scan_target} {info['remote_count']}/{info['required_count']} -> {status}{suffix}"
                )

    print("\n校验结束")
    return exit_code


def execute_generation(
    campaign_names: Sequence[str],
    output_dir: str,
    dag_filename: str,
    options: WorkflowOptions,
    dry_run: bool,
) -> int:
    output_dir = os.path.abspath(output_dir)
    if not options.local_log_dir:
        options.local_log_dir = os.path.join(output_dir, "logs")
    local_output_base = options.local_output_base if options.machine_env.uses_local_storage else ""
    if not dry_run:
        ensure_submit_visible_output_dir(output_dir)
        ensure_dir(options.local_log_dir)
    pool_requirements = compute_pool_requirements(campaign_names, options.jobs_per_campaign)
    if options.force_generate_lhe:
        existing_pools = OrderedDict(
            (
                pool_name,
                {
                    "required_count": required_count,
                    "remote_count": 0,
                    "use_existing": False,
                    "error": "已禁用远端复用",
                    "remote_path": pool_remote_path(pool_name, local_output_base),
                },
            )
            for pool_name, required_count in pool_requirements.items()
        )
    elif options.scan_existing:
        existing_pools = scan_existing_pools(pool_requirements, options.proxy_path, local_output_base)
    else:
        existing_pools = OrderedDict(
            (
                pool_name,
                {
                    "required_count": required_count,
                    "remote_count": 0,
                    "use_existing": False,
                    "error": None,
                    "remote_path": pool_remote_path(pool_name, local_output_base),
                },
            )
            for pool_name, required_count in pool_requirements.items()
        )

    runtime_assets: Dict[str, str]
    if dry_run:
        runtime_assets = {
            "lhe_bundle_path": "<dry-run>/lhe_runtime_bundle.tar.gz",
            "lhe_bundle_name": BUNDLE_NAMES["lhe"],
            "processing_bundle_path": "<dry-run>/processing_runtime_bundle.tar.gz",
            "processing_bundle_name": BUNDLE_NAMES["processing"],
            "summary_bundle_path": "<dry-run>/summary_runtime_bundle.tar.gz",
            "summary_bundle_name": BUNDLE_NAMES["summary"],
            "proxy_bundle_path": "<dry-run>/proxy_bundle.tar.gz",
            "proxy_bundle_name": BUNDLE_NAMES["proxy"],
        }
    else:
        runtime_assets = prepare_runtime_assets(output_dir)
        proxy_bundle_path, proxy_bundle_name = build_proxy_bundle(output_dir, options.proxy_path)
        runtime_assets["proxy_bundle_path"] = proxy_bundle_path
        runtime_assets["proxy_bundle_name"] = proxy_bundle_name

    builder = DAGBuilder(
        output_dir=output_dir,
        options=options,
        existing_pools=existing_pools,
        pool_requirements=pool_requirements,
        runtime_assets=runtime_assets,
    )
    dag_content = builder.build(campaign_names, dag_filename)

    if dry_run:
        print(dag_content)
        return 0

    dag_path, config_path, metadata_path = write_generated_files(
        output_dir=output_dir,
        dag_filename=dag_filename,
        dag_content=dag_content,
        dagman_config_content=render_dagman_config(options),
        metadata=builder.metadata,
    )
    manifest_path = ""
    if options.efficiency_ntuple:
        manifest_path = write_ntuple_manifest(
            output_dir,
            build_ntuple_manifest(campaign_names, options.jobs_per_campaign, local_output_base),
        )

    print("DAG 生成完成")
    print(f"  - DAG: {dag_path}")
    print(f"  - DAGMan 配置: {config_path}")
    print(f"  - 元数据: {metadata_path}")
    if manifest_path:
        print(f"  - Ntuple manifest: {manifest_path}")
    print(f"  - Machine env: {options.machine_env.name} ({options.machine_env.submit_host})")
    print(f"  - 提交命令: condor_submit_dag {dag_path}")
    return 0


def execute_prepare_runtime(output_dir: str, proxy_path: str, machine_env: Optional[MachineEnv] = None) -> int:
    machine_env = machine_env or MACHINE_ENVS["lxplus_t2_ihep"]
    output_dir = os.path.abspath(output_dir)
    ensure_submit_visible_output_dir(output_dir)
    runtime_assets = prepare_runtime_assets(output_dir)
    proxy_bundle_path, proxy_bundle_name = build_proxy_bundle(output_dir, proxy_path)
    runtime_assets["proxy_bundle_path"] = proxy_bundle_path
    runtime_assets["proxy_bundle_name"] = proxy_bundle_name
    runtime_assets["machine_env"] = machine_env.to_dict()
    print(json.dumps(runtime_assets, indent=2, ensure_ascii=False))
    return 0


def execute_hepjob_delegate(args: argparse.Namespace) -> int:
    """Use the shared CLI selector while keeping the existing HepJob backend."""

    if getattr(args, "dry_run", False):
        raise ValueError("--dry-run is not supported for machine-env=ihep/HepJob")

    hepjob_script = os.path.join(BASE_DIR, "hepjob_workflow.py")
    command = [sys.executable, hepjob_script, args.command]
    for campaign_arg in args.campaign:
        command.extend(["--campaign", campaign_arg])

    command.extend(["--jobs", str(args.jobs)])
    command.extend(["--output-dir", args.output_dir])
    command.extend(["--max-events", str(args.max_events)])
    command.extend(["--proxy-path", args.proxy_path])
    command.extend(["--group", args.hepjob_group])

    if args.enable_ntuple:
        command.append("--enable-ntuple")
    else:
        command.append("--disable-ntuple")
    if args.efficiency_ntuple:
        command.append("--efficiency-ntuple")

    if args.command == "generate":
        if args.cleanup:
            command.append("--cleanup")
        else:
            command.append("--no-cleanup")
        if args.scan_existing:
            command.append("--scan-existing")
        else:
            command.append("--no-scan-existing")
        if args.force_generate_lhe:
            command.append("--force-generate-lhe")
        if args.lhe_unwevt is not None:
            command.extend(["--lhe-unwevt", str(args.lhe_unwevt)])
        command.extend(["--walltime", args.hepjob_walltime])

    print("Delegating to HepJob backend:")
    print("  " + " ".join(command))
    result = subprocess.run(command, check=False)
    return result.returncode


def default_test_output_dir() -> str:
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    return os.path.join(TEST_OUTPUT_DIR, f"batch_{timestamp}")


def add_common_generation_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--machine-env",
        choices=machine_env_choices(),
        default="auto",
        help=(
            "运行环境选择。t2_cn_beijing 是 lxplus_t2_ihep 的别名：在 CERN lxplus 提交，"
            "数据写到 IHEP T2_CN_Beijing。"
        ),
    )
    parser.add_argument(
        "--campaign",
        action="append",
        required=True,
        help="可重复指定，也支持 ALL/JJP_ALL/JUP_ALL 或逗号分隔。",
    )
    parser.add_argument("--jobs", type=int, default=1, help="每个 campaign 的 job 数。")
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR, help="输出目录。")
    parser.add_argument("--output", default="mc_production.dag", help="输出 DAG 文件名。")
    parser.add_argument(
        "--lhe-unwevt",
        type=int,
        default=None,
        help="LHE 节点的 unwevt；默认正式模式 100000、测试模式 100。",
    )
    parser.add_argument("--max-events", type=int, default=-1, help="processing 节点的 max-events。")
    parser.add_argument(
        "--enable-ntuple",
        dest="enable_ntuple",
        action="store_true",
        default=True,
        help="保留 ntuple 步骤。",
    )
    parser.add_argument(
        "--disable-ntuple",
        dest="enable_ntuple",
        action="store_false",
        help="跳过 ntuple，仅保留到 MiniAOD 再做 transfer。",
    )
    parser.add_argument(
        "--efficiency-ntuple",
        action="store_true",
        help="生成 multileppat 效率/acceptance 可用的 JJP full-GEN truth ntuple，并写出 ntuple manifest。",
    )
    parser.add_argument(
        "--cleanup",
        dest="cleanup",
        action="store_true",
        default=True,
        help="作业结束后清理中间文件。",
    )
    parser.add_argument(
        "--no-cleanup",
        dest="cleanup",
        action="store_false",
        help="保留 worker 节点上的中间文件。",
    )
    parser.add_argument(
        "--scan-existing",
        dest="scan_existing",
        action="store_true",
        default=True,
        help="扫描 T2 远端已有的 LHE pool。",
    )
    parser.add_argument(
        "--no-scan-existing",
        dest="scan_existing",
        action="store_false",
        help="不扫描远端，所有 pool 都按需生成。",
    )
    parser.add_argument(
        "--force-generate-lhe",
        action="store_true",
        help="即使远端已有文件，也强制生成本次需要的全部 LHE。",
    )
    parser.add_argument(
        "--proxy-path",
        default=detect_proxy_path(),
        help="X509 代理路径；默认自动探测。",
    )
    parser.add_argument(
        "--dagman-max-jobs-submitted",
        type=int,
        default=200,
        help="DAGMan 允许同时提交/运行的最大节点数。",
    )
    parser.add_argument(
        "--dagman-max-jobs-idle",
        type=int,
        default=100,
        help="DAGMan 允许同时处于 idle 状态的最大节点数。",
    )
    parser.add_argument(
        "--local-log-dir",
        default="",
        help="本地 HTCondor 日志目录；hepthu 默认使用 output-dir/logs。",
    )
    parser.add_argument(
        "--local-output-base",
        default="",
        help="本地输出基础目录；hepthu 默认使用 ~/MC_Production_result。",
    )
    parser.add_argument("--hepjob-group", default="cms", help="machine-env=ihep 时传给 hep_sub 的组名。")
    parser.add_argument(
        "--hepjob-walltime",
        default="test",
        choices=("test", "short", "mid", "long", "special"),
        help="machine-env=ihep 时传给 hep_sub 的 walltime 等级。",
    )
    parser.add_argument("--dry-run", action="store_true", help="只打印 DAG，不写文件。")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="workbook_v2 版 MC DAGMan 工作流工具",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    subparsers = parser.add_subparsers(dest="command")

    list_parser = subparsers.add_parser("list", help="列出可用的 pools 或 campaigns")
    list_parser.add_argument(
        "--kind",
        choices=("all", "campaigns", "pools"),
        default="all",
        help="输出类型。",
    )

    validate_parser = subparsers.add_parser("validate", help="校验本地环境与关键文件")
    validate_parser.add_argument(
        "--machine-env",
        choices=machine_env_choices(),
        default="auto",
        help="运行环境选择。",
    )
    validate_parser.add_argument(
        "--campaign",
        action="append",
        help="可选；若提供则额外检查相关 pool 需求。",
    )
    validate_parser.add_argument(
        "--proxy-path",
        default=detect_proxy_path(),
        help="X509 代理路径；默认自动探测。",
    )
    validate_parser.add_argument(
        "--scan-existing",
        action="store_true",
        help="对指定 campaign 扫描远端已有 pool。",
    )
    validate_parser.add_argument(
        "--strict-analysis-packages",
        action="store_true",
        help="把 jjp/jup 分析包也当作硬依赖。",
    )
    validate_parser.add_argument(
        "--local-output-base",
        default="",
        help="本地输出基础目录；hepthu 默认使用 ~/MC_Production_result。",
    )

    runtime_parser = subparsers.add_parser("prepare-runtime", help="生成 worker 运行所需的压缩包")
    runtime_parser.add_argument(
        "--machine-env",
        choices=machine_env_choices(),
        default="auto",
        help="运行环境选择。",
    )
    runtime_parser.add_argument("--output-dir", required=True, help="bundle 输出目录。")
    runtime_parser.add_argument(
        "--proxy-path",
        default=detect_proxy_path(),
        help="要一起打包到 worker 的代理路径。",
    )

    generate_parser = subparsers.add_parser("generate", help="生成正式 DAG")
    add_common_generation_arguments(generate_parser)
    generate_parser.set_defaults(test_mode=False)
    generate_parser.add_argument(
        "--test-mode",
        action="store_true",
        default=False,
        help="把 LHE 生成切到 fast-test 模式。",
    )

    test_parser = subparsers.add_parser("generate-test", help="生成小批量测试 DAG")
    add_common_generation_arguments(test_parser)
    test_parser.set_defaults(
        jobs=1,
        output_dir=default_test_output_dir(),
        output="mc_test.dag",
        max_events=5,
        enable_ntuple=False,
        cleanup=True,
        scan_existing=True,
        force_generate_lhe=False,
        test_mode=True,
    )

    return parser


def normalize_args(argv: Sequence[str]) -> Sequence[str]:
    """
    兼容旧接口：
    - --list-campaigns -> list --kind campaigns
    - --list-pools -> list --kind pools
    - --campaign ... -> generate ...
    """

    if len(argv) <= 1:
        return argv

    if argv[1] in {"list", "validate", "prepare-runtime", "generate", "generate-test"}:
        return argv

    if "--list-campaigns" in argv[1:]:
        return [argv[0], "list", "--kind", "campaigns"]
    if "--list-pools" in argv[1:]:
        return [argv[0], "list", "--kind", "pools"]
    if "--campaign" in argv[1:]:
        return [argv[0], "generate"] + list(argv[1:])
    return argv


def main(argv: Optional[Sequence[str]] = None) -> int:
    argv = normalize_args(argv or sys.argv)
    parser = build_parser()
    args = parser.parse_args(list(argv[1:]))

    if args.command is None:
        parser.print_help()
        return 0

    if args.command == "list":
        if args.kind in ("all", "campaigns"):
            print_campaigns()
        if args.kind in ("all", "pools"):
            print_pools()
        return 0

    if args.command == "validate":
        machine_env = resolve_machine_env(args.machine_env)
        campaign_names = expand_campaign_selection(args.campaign) if args.campaign else None
        local_output_base = args.local_output_base or (machine_env.local_output_base if machine_env.uses_local_storage else "")
        return validate_environment(
            campaign_names=campaign_names,
            proxy_path=args.proxy_path,
            scan_existing=args.scan_existing,
            strict_analysis_packages=args.strict_analysis_packages,
            machine_env=machine_env,
            local_output_base=local_output_base,
        )

    if args.command == "prepare-runtime":
        machine_env = resolve_machine_env(args.machine_env)
        return execute_prepare_runtime(
            output_dir=args.output_dir,
            proxy_path=args.proxy_path,
            machine_env=machine_env,
        )

    if args.command in {"generate", "generate-test"}:
        machine_env = resolve_machine_env(args.machine_env)
        campaign_names = expand_campaign_selection(args.campaign)
        if args.efficiency_ntuple:
            try:
                validate_efficiency_campaigns(campaign_names)
            except ValueError as exc:
                parser.error(str(exc))
            args.enable_ntuple = True
        if machine_env.is_hepjob:
            try:
                return execute_hepjob_delegate(args)
            except ValueError as exc:
                parser.error(str(exc))
        local_output_base = args.local_output_base or (machine_env.local_output_base if machine_env.uses_local_storage else "")
        options = WorkflowOptions(
            jobs_per_campaign=args.jobs,
            max_events=args.max_events,
            enable_ntuple=args.enable_ntuple,
            efficiency_ntuple=args.efficiency_ntuple,
            cleanup=args.cleanup,
            test_mode=args.test_mode,
            scan_existing=args.scan_existing,
            force_generate_lhe=args.force_generate_lhe,
            proxy_path=args.proxy_path,
            lhe_unwevt=args.lhe_unwevt,
            dagman_max_jobs_submitted=args.dagman_max_jobs_submitted,
            dagman_max_jobs_idle=args.dagman_max_jobs_idle,
            machine_env=machine_env,
            local_log_dir=args.local_log_dir,
            local_output_base=local_output_base,
        )
        return execute_generation(
            campaign_names=campaign_names,
            output_dir=args.output_dir,
            dag_filename=args.output,
            options=options,
            dry_run=args.dry_run,
        )

    parser.error(f"未知命令: {args.command}")
    return 1


if __name__ == "__main__":
    sys.exit(main())

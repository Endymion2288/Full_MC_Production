#!/usr/bin/env python3
"""
DAG Generator for Full MC Production Pipeline
==============================================

This script generates HTCondor DAGMan workflow files for the complete MC production
chain: LHE Generation -> Shower -> Mix -> GENSIM -> RAW -> RECO -> MiniAOD -> Ntuple

Supports both JJP (J/psi + J/psi + phi) and JUP (J/psi + Upsilon + phi) physics processes.

Usage:
    python dag_generator.py --campaign JJP_DPS1 --jobs 100 --output my_production.dag
    python dag_generator.py --campaign ALL --jobs 50 --output full_production.dag
    python dag_generator.py --list-campaigns

Author: MC Production Team
Date: 2024
"""

import argparse
import os
import sys
import subprocess
from datetime import datetime

# Python 3.6 compatibility
try:
    from typing import Dict, List, Tuple, Optional
except ImportError:
    pass

try:
    from dataclasses import dataclass, field
except ImportError:
    # Fallback for Python < 3.7 - install dataclasses package or use simple classes
    print("Note: dataclasses not available, using fallback implementation")
    def dataclass(cls):
        return cls
    def field(**kwargs):
        return kwargs.get('default', None)

# =============================================================================
# Configuration Constants
# =============================================================================

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# T2_CN_Beijing XRootD storage paths
EOS_HOST = "cceos.ihep.ac.cn"
EOS_PATH_BASE = "/eos/ihep/cms/store/user/xcheng/MC_Production_v2"
EOS_BASE = "root://{}/{}".format(EOS_HOST, EOS_PATH_BASE)

# X509 proxy path for XRootD access
X509_PROXY_PATH = "/afs/cern.ch/user/x/xcheng/x509up_u180107"

CMSSW_12 = "/afs/cern.ch/user/x/xcheng/condor/CMSSW_12_4_14_patch3"
CMSSW_14 = "/afs/cern.ch/user/x/xcheng/condor/CMSSW_14_0_18"

# =============================================================================
# T2 Storage Check Functions
# =============================================================================

def check_proxy_valid() -> bool:
    """Check if X509 proxy is valid"""
    if not os.path.exists(X509_PROXY_PATH):
        print(f"[ERROR] X509 proxy not found: {X509_PROXY_PATH}")
        return False
    
    try:
        result = subprocess.run(
            ["voms-proxy-info", "-file", X509_PROXY_PATH, "-timeleft"],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            timeleft = int(result.stdout.strip())
            if timeleft > 3600:  # At least 1 hour remaining
                print(f"[OK] X509 proxy valid (timeleft: {timeleft}s)")
                return True
            else:
                print(f"[WARN] X509 proxy expiring soon (timeleft: {timeleft}s)")
                return timeleft > 0
    except Exception as e:
        print(f"[WARN] Could not check proxy: {e}")
    return True  # Assume valid if can't check

def count_lhe_files_on_t2(pool_name: str) -> int:
    """Count LHE files in a pool on T2_CN_Beijing storage via xrdfs"""
    pool_path = "{}/lhe_pools/{}".format(EOS_PATH_BASE, pool_name)
    
    env = os.environ.copy()
    env["X509_USER_PROXY"] = X509_PROXY_PATH
    
    try:
        result = subprocess.run(
            ["xrdfs", EOS_HOST, "ls", pool_path],
            capture_output=True, text=True, timeout=30, env=env
        )
        if result.returncode != 0:
            # Directory might not exist
            return 0
        
        # Count .lhe files
        lines = result.stdout.strip().split('\n')
        lhe_files = [f for f in lines if f.endswith('.lhe')]
        return len(lhe_files)
    except subprocess.TimeoutExpired:
        print(f"[WARN] Timeout checking {pool_name} on T2")
        return 0
    except Exception as e:
        print(f"[WARN] Error checking {pool_name}: {e}")
        return 0

def scan_existing_pools(required_pools: List[str], min_files: int) -> Dict[str, str]:
    """
    Scan T2 storage and return dict of pools that have sufficient files.
    
    Args:
        required_pools: List of pool names to check
        min_files: Minimum number of files needed
        
    Returns:
        Dict mapping pool_name -> EOS path for pools with sufficient files
    """
    print("\n[INFO] Scanning T2_CN_Beijing storage for existing LHE pools...")
    print(f"[INFO] Minimum files required: {min_files}")
    
    if not check_proxy_valid():
        print("[WARN] Proxy check failed, assuming no existing pools")
        return {}
    
    existing = {}
    for pool_name in required_pools:
        count = count_lhe_files_on_t2(pool_name)
        status = "✓" if count >= min_files else "✗"
        print(f"  {pool_name}: {count} files [{status}]")
        
        if count >= min_files:
            existing[pool_name] = "{}/lhe_pools/{}".format(EOS_BASE, pool_name)
    
    print(f"[INFO] Found {len(existing)} pool(s) with sufficient files\n")
    return existing

# Dynamic pool status (populated at runtime)
RUNTIME_EXISTING_POOLS: Dict[str, str] = {}

# =============================================================================
# Data Classes (Python 3.6 compatible)
# =============================================================================

class LHEPool:
    """Definition of an LHE pool"""
    def __init__(self, name, process, description, 
                 output_pattern="sample_{name}_{seed}.lhe",
                 min_pt_conia=6.0, min_pt_bonia=4.0, min_pt_q=4.0, 
                 eos_path=None):
        self.name = name
        self.process = process
        self.description = description
        self.output_pattern = output_pattern
        self.min_pt_conia = min_pt_conia
        self.min_pt_bonia = min_pt_bonia
        self.min_pt_q = min_pt_q
        self.eos_path = eos_path

class Campaign:
    """Definition of a physics campaign
    
    Attributes:
        name: Campaign identifier
        analysis_type: JJP or JUP
        inputs: List of LHE pool names
        modes: List of shower modes (normal/phi) for each input
        description: Human-readable description
        deprecated: Whether this campaign is deprecated
    """
    def __init__(self, name, analysis_type, inputs, modes, description,
                 deprecated=False):
        self.name = name
        self.analysis_type = analysis_type
        self.inputs = inputs
        self.modes = modes
        self.description = description
        self.deprecated = deprecated
        self.n_sources = len(inputs)
        
        # Validate modes count matches inputs count
        if len(modes) != len(inputs):
            raise ValueError("Campaign {}: modes count must match inputs count".format(name))

# =============================================================================
# LHE Pool Definitions
# =============================================================================

LHE_POOLS: Dict[str, LHEPool] = {
    # -------------------------------------------------------------------------
    # CSCO Pools (Color Singlet + Color Octet combined)
    # These are the PRIMARY pools recommended by workbook.md
    # Using HELAC-Onia "define" syntax to include CS+CO contributions
    # -------------------------------------------------------------------------
    "pool_jpsi_CSCO_g": LHEPool(
        name="pool_jpsi_CSCO_g",
        process="define jpsi_all; g g > jpsi_all g",
        description="gg -> J/psi(CS+CO) + g (3S11+3S18+1S08)",
        min_pt_conia=6.0,
        min_pt_q=4.0,
        # eos_path=None  # Will be generated
        eos_path=f"{EOS_BASE}/lhe_pools/pool_jpsi_CSCO_g"
    ),
    "pool_upsilon_CSCO_g": LHEPool(
        name="pool_upsilon_CSCO_g", 
        process="define upsilon_all; g g > upsilon_all g",
        description="gg -> Upsilon(CS+CO) + g (3S11+3S18+1S08)",
        min_pt_bonia=4.0,
        min_pt_q=4.0,
        # eos_path=None  # Will be generated
        eos_path=f"{EOS_BASE}/lhe_pools/pool_upsilon_CSCO_g"
    ),
    "pool_jpsi_upsilon_CSCO": LHEPool(
        name="pool_jpsi_upsilon_CSCO",
        process="g g > cc~(3S11) bb~(3S11)",
        description="gg -> J/psi + Upsilon (Color Singlet)",
        min_pt_conia=6.0,
        min_pt_bonia=4.0,
        # eos_path=None  # Will be generated
        eos_path=f"{EOS_BASE}/lhe_pools/pool_jpsi_upsilon_CSCO"
    ),
    
    # -------------------------------------------------------------------------
    # Basic Pools (Color Singlet only)
    # -------------------------------------------------------------------------
    "pool_gg": LHEPool(
        name="pool_gg",
        process="g g > g g",
        description="gg -> gg (QCD dijet)",
        min_pt_q=4.0,
        # eos_path=None  # Will be generated
        eos_path=f"{EOS_BASE}/lhe_pools/pool_gg"
    ),
    "pool_2jpsi": LHEPool(
        name="pool_2jpsi",
        process="g g > cc~(3S11) cc~(3S11)",
        description="gg -> 2J/psi (Color Singlet, no extra gluon)",
        min_pt_conia=6.0,
        # eos_path=None  # Will be generated
        eos_path=f"{EOS_BASE}/lhe_pools/pool_2jpsi"
    ),
    "pool_2jpsi_g": LHEPool(
        name="pool_2jpsi_g",
        process="g g > cc~(3S11) cc~(3S11) g",
        description="gg -> 2J/psi + g (Color Singlet SPS for JJP)",
        min_pt_conia=6.0,
        min_pt_q=4.0,
        # eos_path=None  # Will be generated
        eos_path=f"{EOS_BASE}/lhe_pools/pool_2jpsi_g"
    ),
}

# =============================================================================
# Campaign Definitions
# =============================================================================

CAMPAIGNS: Dict[str, Campaign] = {
    # =========================================================================
    # JJP Campaigns (J/psi + J/psi + Phi)
    # =========================================================================
    
    # JJP SPS: Single 2J/psi + g process with phi-enriched shower
    "JJP_SPS": Campaign(
        name="JJP_SPS",
        analysis_type="JJP",
        inputs=["pool_2jpsi_g"],
        modes=["phi"],
        description="JJP SPS: gg -> 2J/psi + g with forced Phi shower"
    ),
    
    # JJP DPS1: Two J/psi+g (CSCO) events mixed at HepMC level
    "JJP_DPS1": Campaign(
        name="JJP_DPS1",
        analysis_type="JJP",
        inputs=["pool_jpsi_CSCO_g", "pool_jpsi_CSCO_g"],
        modes=["normal", "phi"],
        description="JJP DPS Type-1: Two J/psi(CS+CO)+g events mixed (normal + phi)"
    ),
    
    # JJP DPS2: 2J/psi (no extra g) mixed with gg->gg
    "JJP_DPS2": Campaign(
        name="JJP_DPS2",
        analysis_type="JJP",
        inputs=["pool_2jpsi", "pool_gg"],
        modes=["normal", "phi"],
        description="JJP DPS Type-2: 2J/psi mixed with gg->gg (normal + phi)"
    ),
    
    # JJP TPS: Triple parton scattering
    "JJP_TPS": Campaign(
        name="JJP_TPS",
        analysis_type="JJP",
        inputs=["pool_jpsi_CSCO_g", "pool_jpsi_CSCO_g", "pool_gg"],
        modes=["normal", "normal", "phi"],
        description="JJP TPS: Three parton scattering (normal + normal + phi)"
    ),
    
    # =========================================================================
    # JUP Campaigns (J/psi + Upsilon + Phi)
    # =========================================================================
    
    # JUP SPS: DEPRECATED - marked per workbook.md
    "JUP_SPS": Campaign(
        name="JUP_SPS",
        analysis_type="JUP",
        inputs=["pool_jpsi_upsilon_CSCO"],
        modes=["phi"],
        description="[DEPRECATED] JUP SPS: J/psi + Upsilon with forced Phi shower",
        deprecated=True
    ),
    
    # JUP DPS1: J/psi(phi) + Upsilon(normal)
    "JUP_DPS1": Campaign(
        name="JUP_DPS1",
        analysis_type="JUP",
        inputs=["pool_jpsi_CSCO_g", "pool_upsilon_CSCO_g"],
        modes=["phi", "normal"],
        description="JUP DPS Type-1: J/psi(CS+CO)+g (phi) + Upsilon(CS+CO)+g (normal)"
    ),
    
    # JUP DPS2: J/psi(normal) + Upsilon(phi)
    "JUP_DPS2": Campaign(
        name="JUP_DPS2",
        analysis_type="JUP",
        inputs=["pool_jpsi_CSCO_g", "pool_upsilon_CSCO_g"],
        modes=["normal", "phi"],
        description="JUP DPS Type-2: J/psi(CS+CO)+g (normal) + Upsilon(CS+CO)+g (phi)"
    ),
    
    # JUP DPS3: J/psi + Upsilon (CS) mixed with gg->gg
    "JUP_DPS3": Campaign(
        name="JUP_DPS3",
        analysis_type="JUP",
        inputs=["pool_jpsi_upsilon_CSCO", "pool_gg"],
        modes=["normal", "phi"],
        description="JUP DPS Type-3: J/psi+Upsilon mixed with gg->gg (normal + phi)"
    ),
    
    # JUP TPS: Triple parton scattering
    "JUP_TPS": Campaign(
        name="JUP_TPS",
        analysis_type="JUP",
        inputs=["pool_jpsi_CSCO_g", "pool_upsilon_CSCO_g", "pool_gg"],
        modes=["normal", "normal", "phi"],
        description="JUP TPS: Three parton scattering (normal + normal + phi)"
    ),
}

# =============================================================================
# DAG Generator Class
# =============================================================================

class DAGGenerator:
    """Generate HTCondor DAGMan files for MC production"""
    
    def __init__(self, output_dir: str, eos_output: str = EOS_BASE):
        self.output_dir = output_dir
        self.eos_output = eos_output
        self.dag_lines: List[str] = []
        self.sub_files: Dict[str, str] = {}
        self.job_counter = 0
        
    def generate_seed_list(self, n_jobs: int, start_seed: int = 100) -> List[int]:
        """Generate list of random seeds for jobs"""
        return list(range(start_seed, start_seed + n_jobs))
    
    def add_lhe_generation_jobs(self, pool: LHEPool, n_jobs: int, 
                                 seeds: Optional[List[int]] = None) -> List[str]:
        """Add LHE generation jobs to DAG"""
        job_names = []
        
        if pool.eos_path:
            print(f"  [INFO] Pool {pool.name} already exists at {pool.eos_path}, skipping LHE generation")
            return job_names
            
        if seeds is None:
            seeds = self.generate_seed_list(n_jobs)
            
        for i, seed in enumerate(seeds):
            job_name = f"LHE_{pool.name}_{i}"
            job_names.append(job_name)
            
            # Add to DAG
            self.dag_lines.append(f"JOB {job_name} processing/templates/lhe_gen.sub")
            self.dag_lines.append(f'VARS {job_name} pool="{pool.name}" seed="{seed}" '
                                  f'process="{pool.process}" '
                                  f'min_pt_conia="{pool.min_pt_conia}" '
                                  f'min_pt_bonia="{pool.min_pt_bonia}" '
                                  f'min_pt_q="{pool.min_pt_q}"')
            self.dag_lines.append(f"RETRY {job_name} 3")
            
        return job_names
    
    def add_processing_job(self, campaign: Campaign, job_id: int,
                           lhe_files: List[str], parent_jobs: List[str]) -> str:
        """Add a processing job (shower -> mix -> sim -> ntuple) to DAG
        
        Args:
            campaign: Campaign definition
            job_id: Job index
            lhe_files: List of LHE file specs (EOS:pool:id:usage or GEN:pool:idx)
            parent_jobs: List of parent job names for dependencies
        """
        job_name = f"PROC_{campaign.name}_{job_id}"
        
        # Build input arguments
        inputs_str = ",".join(lhe_files)
        modes_str = ",".join(campaign.modes)
        
        # Add to DAG
        self.dag_lines.append(f"JOB {job_name} processing/templates/processing.sub")
        self.dag_lines.append(
            f'VARS {job_name} campaign="{campaign.name}" '
            f'job_id="{job_id}" '
            f'inputs="{inputs_str}" '
            f'modes="{modes_str}" '
            f'analysis="{campaign.analysis_type}" '
            f'n_sources="{campaign.n_sources}"'
        )
        self.dag_lines.append(f"RETRY {job_name} 2")
        
        # Add dependencies
        if parent_jobs:
            parents = " ".join(parent_jobs)
            self.dag_lines.append(f"PARENT {parents} CHILD {job_name}")
            
        return job_name
    
    def generate_campaign_dag(self, campaign: Campaign, n_jobs: int,
                               use_existing_lhe: bool = True) -> List[str]:
        """Generate DAG nodes for a complete campaign"""
        self.dag_lines.append(f"\n# ============================================")
        self.dag_lines.append(f"# Campaign: {campaign.name}")
        self.dag_lines.append(f"# Description: {campaign.description}")
        if campaign.deprecated:
            self.dag_lines.append(f"# *** DEPRECATED ***")
        self.dag_lines.append(f"# ============================================")
        
        processing_jobs = []
        
        # Collect unique pools needed
        unique_pools = list(set(campaign.inputs))
        pool_lhe_jobs: Dict[str, List[str]] = {}
        
        # Stage 1: Generate LHE pools if needed
        for pool_name in unique_pools:
            pool = LHE_POOLS[pool_name]
            
            # Count how many times this pool is used
            usage_count = campaign.inputs.count(pool_name)
            jobs_per_pool = n_jobs * usage_count
            
            if use_existing_lhe and pool.eos_path:
                pool_lhe_jobs[pool_name] = []  # No jobs needed
            else:
                lhe_jobs = self.add_lhe_generation_jobs(pool, jobs_per_pool)
                pool_lhe_jobs[pool_name] = lhe_jobs
                
        # Stage 2: Generate processing jobs
        for job_id in range(n_jobs):
            # Determine LHE file sources for this job
            lhe_files = []
            parent_jobs = []
            
            pool_usage_counter = {p: 0 for p in unique_pools}
            
            for i, pool_name in enumerate(campaign.inputs):
                pool = LHE_POOLS[pool_name]
                usage_idx = pool_usage_counter[pool_name]
                pool_usage_counter[pool_name] += 1
                
                if pool.eos_path:
                    # Use existing LHE from EOS (will be resolved at runtime)
                    lhe_files.append(f"EOS:{pool_name}:{job_id}:{usage_idx}")
                else:
                    # Reference generated LHE
                    lhe_job_idx = job_id * campaign.inputs.count(pool_name) + usage_idx
                    lhe_job_name = pool_lhe_jobs[pool_name][lhe_job_idx]
                    lhe_files.append(f"GEN:{pool_name}:{lhe_job_idx}")
                    parent_jobs.append(lhe_job_name)
                    
            proc_job = self.add_processing_job(
                campaign, job_id, lhe_files, parent_jobs
            )
            processing_jobs.append(proc_job)
            
        return processing_jobs
    
    def generate_full_dag(self, campaigns: List[str], n_jobs: int) -> str:
        """Generate complete DAG file content"""
        self.dag_lines = []
        
        # Header
        self.dag_lines.append("# " + "=" * 70)
        self.dag_lines.append("# Full MC Production DAG")
        self.dag_lines.append(f"# Generated: {datetime.now().isoformat()}")
        self.dag_lines.append(f"# Campaigns: {', '.join(campaigns)}")
        self.dag_lines.append(f"# Jobs per campaign: {n_jobs}")
        self.dag_lines.append("# " + "=" * 70)
        self.dag_lines.append("")
        
        # DAG configuration
        self.dag_lines.append("# DAG Configuration")
        self.dag_lines.append("CONFIG dagman.config")
        self.dag_lines.append("")
        
        # Generate each campaign
        all_jobs = []
        for campaign_name in campaigns:
            if campaign_name not in CAMPAIGNS:
                print(f"[WARNING] Unknown campaign: {campaign_name}, skipping")
                continue
            campaign = CAMPAIGNS[campaign_name]
            jobs = self.generate_campaign_dag(campaign, n_jobs)
            all_jobs.extend(jobs)
            
        # Final summary node
        if all_jobs:
            self.dag_lines.append("\n# ============================================")
            self.dag_lines.append("# Final Summary Node")
            self.dag_lines.append("# ============================================")
            self.dag_lines.append("FINAL SUMMARY processing/templates/summary.sub")
            
        return "\n".join(self.dag_lines)
    
    def generate_dagman_config(self) -> str:
        """Generate DAGMan configuration file"""
        return """# DAGMan Configuration
# ====================

# Maximum number of jobs to submit at once
DAGMAN_MAX_JOBS_SUBMITTED = 500

# Maximum number of jobs in idle state
DAGMAN_MAX_JOBS_IDLE = 200

# Retry failed jobs
DAGMAN_MAX_SUBMITS_PER_INTERVAL = 50
DAGMAN_SUBMIT_DELAY = 1

# Log settings
DAGMAN_SUPPRESS_NOTIFICATION = True

# Allow rescue DAG creation
DAGMAN_GENERATE_RESCUE_DAG = True
"""

    def write_dag(self, dag_content: str, filename: str):
        """Write DAG file and associated configuration"""
        dag_path = os.path.join(self.output_dir, filename)
        
        # Write DAG file
        with open(dag_path, 'w') as f:
            f.write(dag_content)
        print(f"[OK] Generated DAG file: {dag_path}")
        
        # Write DAGMan config
        config_path = os.path.join(self.output_dir, "dagman.config")
        with open(config_path, 'w') as f:
            f.write(self.generate_dagman_config())
        print(f"[OK] Generated DAGMan config: {config_path}")

# =============================================================================
# CLI Interface
# =============================================================================

def list_campaigns():
    """Print available campaigns"""
    print("\n" + "=" * 70)
    print("Available Campaigns")
    print("=" * 70)
    
    for category in ["JJP", "JUP"]:
        print(f"\n{category} Campaigns:")
        print("-" * 40)
        for name, campaign in CAMPAIGNS.items():
            if campaign.analysis_type == category:
                inputs = " + ".join(campaign.inputs)
                modes = "/".join(campaign.modes)
                status = "[DEPRECATED] " if campaign.deprecated else ""
                print(f"  {status}{name:15} : {campaign.description}")
                print(f"                   Inputs: {inputs}")
                print(f"                   Modes:  {modes}")
                print()
                
def list_pools():
    """Print available LHE pools"""
    print("\n" + "=" * 70)
    print("Available LHE Pools")
    print("=" * 70)
    
    for name, pool in LHE_POOLS.items():
        status = "[EXISTS]" if pool.eos_path else "[GENERATE]"
        print(f"\n{name} {status}")
        print(f"  Process:     {pool.process}")
        print(f"  Description: {pool.description}")
        if pool.eos_path:
            print(f"  EOS Path:    {pool.eos_path}")

def main():
    parser = argparse.ArgumentParser(
        description="Generate HTCondor DAGMan workflow for MC production",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # List available campaigns
  python dag_generator.py --list-campaigns
  
  # Generate DAG for a single campaign
  python dag_generator.py --campaign JJP_DPS1 --jobs 100 --output jjp_dps1.dag
  
  # Generate DAG for all JJP campaigns
  python dag_generator.py --campaign JJP_ALL --jobs 50 --output jjp_all.dag
  
  # Generate DAG for all campaigns
  python dag_generator.py --campaign ALL --jobs 20 --output full_mc.dag
        """
    )
    
    parser.add_argument("--campaign", "-c", type=str,
                        help="Campaign name (or ALL, JJP_ALL, JUP_ALL)")
    parser.add_argument("--jobs", "-n", type=int, default=1000,
                        help="Number of jobs per campaign (default: 1000)")
    parser.add_argument("--output", "-o", type=str, default="mc_production.dag",
                        help="Output DAG filename (default: mc_production.dag)")
    parser.add_argument("--output-dir", type=str, default=BASE_DIR,
                        help="Output directory (default: current script directory)")
    parser.add_argument("--list-campaigns", action="store_true",
                        help="List available campaigns")
    parser.add_argument("--list-pools", action="store_true",
                        help="List available LHE pools")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print DAG content without writing files")
    
    args = parser.parse_args()
    
    if args.list_campaigns:
        list_campaigns()
        return
        
    if args.list_pools:
        list_pools()
        return
        
    if not args.campaign:
        parser.print_help()
        return
        
    # Determine campaigns to generate
    if args.campaign == "ALL":
        campaigns = list(CAMPAIGNS.keys())
    elif args.campaign == "JJP_ALL":
        campaigns = [c for c in CAMPAIGNS.keys() if c.startswith("JJP")]
    elif args.campaign == "JUP_ALL":
        campaigns = [c for c in CAMPAIGNS.keys() if c.startswith("JUP")]
    elif args.campaign in CAMPAIGNS:
        campaigns = [args.campaign]
    else:
        print(f"[ERROR] Unknown campaign: {args.campaign}")
        print("Use --list-campaigns to see available options")
        sys.exit(1)
        
    print(f"\n[INFO] Generating DAG for campaigns: {', '.join(campaigns)}")
    print(f"[INFO] Jobs per campaign: {args.jobs}")
    print(f"[INFO] Output file: {args.output}")
    
    # Collect all required LHE pools
    required_pools = set()
    for cname in campaigns:
        for pool_name in CAMPAIGNS[cname].inputs:
            required_pools.add(pool_name)
    
    print(f"[INFO] Required LHE pools: {', '.join(sorted(required_pools))}")
    
    # Auto-scan T2 storage to check which pools have sufficient files
    existing_pools = scan_existing_pools(list(required_pools), args.jobs)
    
    # Update LHE_POOLS with detected existing files
    for pool_name, eos_path in existing_pools.items():
        if pool_name in LHE_POOLS:
            LHE_POOLS[pool_name].eos_path = eos_path
            print(f"[OK] {pool_name} will use existing files from T2")
    
    # Report which pools will be generated
    for pool_name in required_pools:
        if pool_name not in existing_pools:
            print(f"[INFO] {pool_name} will be generated (insufficient files on T2)")
    
    # Generate DAG
    generator = DAGGenerator(args.output_dir)
    dag_content = generator.generate_full_dag(campaigns, args.jobs)
    
    if args.dry_run:
        print("\n" + "=" * 70)
        print("DAG Content (dry run):")
        print("=" * 70)
        print(dag_content)
    else:
        generator.write_dag(dag_content, args.output)
        print(f"\n[OK] DAG generation complete!")
        print(f"[INFO] To submit: condor_submit_dag {os.path.join(args.output_dir, args.output)}")

if __name__ == "__main__":
    main()

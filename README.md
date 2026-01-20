# Full MC Production System (T2_CN_Beijing)
# ==========================================

A complete HTCondor DAGMan-based Monte Carlo production system for CMS physics analysis,
covering the full chain from LHE generation to Ntuple production.

**Target Site:** T2_CN_Beijing (IHEP)  
**Storage:** `root://cceos.ihep.ac.cn//eos/ihep/cms/store/user/xcheng/MC_Production_v2`

## Quick Start

### 1. Setup VOMS Proxy

```bash
# Setup CMS environment
source /cvmfs/cms.cern.ch/cmsset_default.sh

# Initialize proxy (run this first!)
./check_proxy.sh --init

# Check status
./check_proxy.sh --status
```

### 2. List Available Campaigns

```bash
python dag_generator.py --list-campaigns
```

### 3. Generate and Submit DAG

```bash
# Single campaign with 100 jobs
python dag_generator.py --campaign JJP_DPS1 --jobs 100 --output jjp_dps1.dag

# Submit
mkdir -p log
condor_submit_dag jjp_dps1.dag
```

### 4. Run Full Chain Test

```bash
# Quick test (shower + mix only)
./test_full_chain.sh --quick

# Full chain test (100 events)
./test_full_chain.sh --campaign JJP_DPS1
```

---

## Overview

This system automates the production of simulated events for:
- **JJP (J/psi + J/psi + phi)** physics processes
- **JUP (J/psi + Upsilon + phi)** physics processes

Including SPS (Single Parton Scattering), DPS (Double Parton Scattering), 
and TPS (Triple Parton Scattering) topologies.

---

## Production Chain

```
LHE Generation (HELAC-Onia with LDME parameters)
        ↓
Parton Shower (Pythia8 - Normal or Phi-enriched)
        ↓
Event Mixing (1/2/3 sources → SPS/DPS/TPS)
        ↓
GEN-SIM (CMSSW_12)
        ↓
RAW (DIGI + HLT + Pileup)
        ↓
RECO (Reconstruction)
        ↓
MiniAOD
        ↓
Ntuple (JJP or JUP analyzer, CMSSW_14)
```

---

## LHE Pool Definitions

The system uses HELAC-Onia's `define` syntax to generate LHE files that include both 
Color Singlet (CS) and Color Octet (CO) contributions in a single generation run.

### CSCO Pools (Color Singlet + Color Octet Combined)

| Pool Name | HELAC-Onia Command | Description |
|-----------|-------------------|-------------|
| `pool_jpsi_CSCO_g` | `define jpsi_all = cc~(3S11) cc~(3S18) cc~(1S08)` <br> `generate g g > jpsi_all g` | J/psi (CS+CO) + g |
| `pool_upsilon_CSCO_g` | `define upsilon_all = bb~(3S11) bb~(3S18) bb~(1S08)` <br> `generate g g > upsilon_all g` | Υ (CS+CO) + g |
| `pool_jpsi_upsilon_CSCO` | `generate g g > cc~(3S11) bb~(3S11)` | J/psi + Υ |

### Basic Pools (Color Singlet Only)

| Pool Name | HELAC-Onia Command | Description |
|-----------|-------------------|-------------|
| `pool_gg` | `g g > g g` | QCD dijet |
| `pool_2jpsi` | `g g > cc~(3S11) cc~(3S11)` | Double J/psi |
| `pool_2jpsi_g` | `g g > cc~(3S11) cc~(3S11) g` | Double J/psi + g |

### LDME Parameters

From H. Han et al, Phys. Rev. Lett. 114 (2015) 092005 and Phys. Rev. D 94 (2016) 014028:

```
# Charmonium
LDMEcc3S11 = 1.16
LDMEcc3S18 = 0.00902923
LDMEcc1S08 = 0.0146

# Bottomonium
LDMEbb3S11 = 9.28
LDMEbb3S18 = 0.0297426
LDMEbb1S08 = 0.000170128
```

---

## Campaign Definitions

### JJP Campaigns (J/psi + J/psi + Phi)

| Campaign | Input Pools | Shower Modes | Description |
|----------|-------------|--------------|-------------|
| **JJP_SPS** | `pool_2jpsi_g` | [phi] | Single 2J/psi+g with forced phi shower |
| **JJP_DPS1** | `pool_jpsi_CSCO_g` × 2 | [normal, phi] | Two J/psi(CS+CO)+g events mixed |
| **JJP_DPS2** | `pool_2jpsi` + `pool_gg` | [normal, phi] | 2J/psi + gg→gg mixed |
| **JJP_TPS** | `pool_jpsi_CSCO_g` × 2 + `pool_gg` | [normal, normal, phi] | Triple parton scattering |

### JUP Campaigns (J/psi + Upsilon + Phi)

| Campaign | Input Pools | Shower Modes | Description |
|----------|-------------|--------------|-------------|
| **JUP_SPS** | `pool_jpsi_upsilon_CSCO` | [phi] | **[DEPRECATED]** |
| **JUP_DPS1** | `pool_jpsi_CSCO_g` + `pool_upsilon_CSCO_g` | [phi, normal] | J/psi(phi) + Υ(normal) |
| **JUP_DPS2** | `pool_jpsi_CSCO_g` + `pool_upsilon_CSCO_g` | [normal, phi] | J/psi(normal) + Υ(phi) |
| **JUP_DPS3** | `pool_jpsi_upsilon_CSCO` + `pool_gg` | [normal, phi] | J/psi+Υ + gg→gg mixed |
| **JUP_TPS** | `pool_jpsi_CSCO_g` + `pool_upsilon_CSCO_g` + `pool_gg` | [normal, normal, phi] | Triple parton scattering |

---

## Directory Structure

```
T2_CN_Beijing/
├── dag_generator.py            # DAG generation script
├── check_proxy.sh              # VOMS proxy management
├── test_full_chain.sh          # Full chain test script
├── README.md                   # This file
├── common/
│   ├── setup.sh                # Environment setup
│   ├── packages/               # Deployment packages
│   │   ├── helac_package.tar.gz    # HELAC-Onia sources
│   │   ├── jjp_code.tar.gz         # JJP ntuple code
│   │   └── jup_code.tar.gz         # JUP ntuple code
│   └── cmssw_configs/          # CMSSW configuration files
│       ├── hepmc_to_GENSIM.py
│       ├── ntuple_jjp_cfg.py
│       └── ntuple_jup_cfg.py
├── lhe_generation/             # LHE production module
│   ├── run_helac.sh            # HELAC job script
│   └── input_templates/
│       └── user.inp            # HELAC physics cuts
├── processing/                 # Main processing module
│   ├── run_chain.sh            # Universal production wrapper
│   ├── pythia_shower/          # Shower programs
│   │   ├── Makefile
│   │   ├── shower_normal.cc    # Standard shower
│   │   ├── shower_phi.cc       # Phi-enriched shower
│   │   └── event_mixer_multisource.cc
│   └── templates/              # HTCondor submit files
│       ├── lhe_gen.sub
│       ├── processing.sub
│       └── summary.sub
├── log/                        # Job log files
└── test_output/                # Test output directory
```

---

## Preparing Packages

### 1. HELAC Package

```bash
cd /path/to/HELAC-on-HTCondor/sources
tar -czf helac_package.tar.gz HELAC-Onia-2.7.6.tar.gz hepmc2.06.11.tgz
cp helac_package.tar.gz /path/to/T2_CN_Beijing/common/packages/
```

### 2. JJP/JUP Analysis Packages

```bash
# JJP package
cd /afs/cern.ch/user/x/xcheng/condor/CMSSW_14_0_18/src
tar --exclude='.git' --exclude='*.root' -czf jjp_code.tar.gz JJPNtupleMaker/
cp jjp_code.tar.gz /path/to/T2_CN_Beijing/common/packages/

# JUP package
tar --exclude='.git' --exclude='*.root' -czf jup_code.tar.gz JUPNtupleMaker/
cp jup_code.tar.gz /path/to/T2_CN_Beijing/common/packages/
```

---

## Usage Examples

### Generate DAG for All JJP Campaigns

```bash
python dag_generator.py --campaign JJP_ALL --jobs 1000 --output jjp_all.dag
```

### Generate DAG for All Campaigns

```bash
python dag_generator.py --campaign ALL --jobs 500 --output full_production.dag
```

### Dry Run (Preview DAG Content)

```bash
python dag_generator.py --campaign JJP_DPS1 --jobs 10 --dry-run
```

### Monitor Running DAG

```bash
condor_q
tail -f my_production.dag.dagman.out
```

---

## Testing

### Quick Test (Shower + Mix Only)

```bash
./test_full_chain.sh --quick --campaign JJP_DPS1
```

This will:
1. Generate ~100 LHE events using HELAC-Onia (in el7 container)
2. Run Pythia8 shower (normal + phi modes)
3. Mix events using event_mixer_multisource

### Full Chain Test

```bash
./test_full_chain.sh --campaign JJP_DPS1
```

This runs the complete chain including GEN-SIM, RAW, RECO, MiniAOD, and Ntuple steps.

### Test Options

| Option | Description |
|--------|-------------|
| `--quick` | Stop after shower+mix (skip CMSSW steps) |
| `--skip-lhe` | Skip LHE generation (use existing file) |
| `--campaign NAME` | Campaign to test (default: JJP_DPS1) |
| `--clean` | Clean test directory before starting |

---

## Key Changes from Previous Version

1. **Simplified LHE Generation**: Using HELAC-Onia's `define` syntax to include CS+CO contributions in single generation, eliminating the need for cross-section weighted mixing.

2. **New Pool Naming**: `pool_jpsi_g` → `pool_jpsi_CSCO_g` to clearly indicate CS+CO content.

3. **LDME Parameters**: Explicit LDME values from published references are now configured in run_helac.sh.

4. **Removed xsec Mixing**: The `lhe_xsec_mixer` tool and related logic have been removed as they are no longer needed.

5. **Storage Path**: Updated to `MC_Production_v2` for clean separation from previous production.

---

## Troubleshooting

### Proxy Issues

```bash
# Check proxy validity
./check_proxy.sh --status

# Reinitialize proxy
./check_proxy.sh --init

# Test XRootD access
./check_proxy.sh --test
```

### HELAC Build Failures

HELAC-Onia requires the el7 container:
```bash
apptainer exec /cvmfs/unpacked.cern.ch/registry.hub.docker.com/cmssw/el7:x86_64 /bin/bash
```

### Missing Packages

Ensure all required packages exist:
```bash
ls -la common/packages/
# Should show: helac_package.tar.gz, jjp_code.tar.gz, jup_code.tar.gz
```

---

## Contact

For issues or questions, check the job logs in `log/` directory or the DAGMan output file.

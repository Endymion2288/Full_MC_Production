# Full MC Production System
# =========================

A complete HTCondor DAGMan-based Monte Carlo production system for CMS physics analysis,
covering the full chain from LHE generation to Ntuple production.

## Overview

This system automates the production of simulated events for:
- **JJP (J/psi + J/psi + phi)** physics processes
- **JUP (J/psi + Upsilon + phi)** physics processes

Including SPS (Single Parton Scattering), DPS (Double Parton Scattering), 
and TPS (Triple Parton Scattering) topologies.

## Production Chain

```
LHE Generation (HELAC-Onia)
        ↓
Parton Shower (Pythia8 - Normal or Phi-enriched)
        ↓
Event Mixing (1/2/3 sources → DPS/TPS)
        ↓
GEN-SIM (CMSSW)
        ↓
RAW (DIGI + HLT + Pileup)
        ↓
RECO (Reconstruction)
        ↓
MiniAOD
        ↓
Ntuple (JJP or JUP analyzer)
```

## Directory Structure

```
Full_MC_Production/
├── dag_generator.py            # DAG generation script
├── common/
│   ├── setup.sh                # Environment setup
│   ├── packages/               # Deployment packages
│   │   ├── helac_package.tar.gz
│   │   ├── jjp_code.tar.gz
│   │   └── jup_code.tar.gz
│   └── cmssw_configs/          # CMSSW configuration files
│       ├── hepmc_to_GENSIM.py
│       ├── ntuple_jjp_cfg.py
│       └── ntuple_jup_cfg.py
├── lhe_generation/             # LHE production module
│   ├── run_helac.sh
│   └── input_templates/
│       └── user.inp
├── processing/                 # Main processing module
│   ├── run_chain.sh            # Universal production wrapper
│   ├── pythia_shower/          # Shower programs
│   │   ├── Makefile
│   │   ├── shower_normal.cc
│   │   ├── shower_phi.cc
│   │   └── event_mixer_multisource.cc
│   └── templates/              # HTCondor submit files
│       ├── lhe_gen.sub
│       ├── processing.sub
│       └── summary.sub
├── log/                        # Job log files
└── output/                     # Local output (if any)
```

## Quick Start

### 1. Prepare Packages

First, create the required deployment packages. See `common/packages/README.md` for details.

```bash
# Create HELAC package
cd /afs/cern.ch/user/x/xcheng/condor/HELAC-on-HTCondor
tar -czf helac_package.tar.gz HELAC-Onia-2.7.6/ HepMC/ sources/
cp helac_package.tar.gz /path/to/Full_MC_Production/common/packages/

# Create JJP/JUP packages
cd /afs/cern.ch/user/x/xcheng/condor/CMSSW_14_0_18/src/JJPNtupleMaker
tar -czf jjp_code.tar.gz TPS-Onia2MuMu/
cp jjp_code.tar.gz /path/to/Full_MC_Production/common/packages/

cd /afs/cern.ch/user/x/xcheng/condor/CMSSW_14_0_18/src/JUPNtupleMaker
tar -czf jup_code.tar.gz TPS-Onia2MuMu/
cp jup_code.tar.gz /path/to/Full_MC_Production/common/packages/
```

### 2. List Available Campaigns

```bash
cd /afs/cern.ch/user/x/xcheng/condor/MC_Production_DAG/Full_MC_Production
python dag_generator.py --list-campaigns
```

Available campaigns:
- **JJP_SPS**: gg → 2J/psi + g (forced phi shower)
- **JJP_DPS1**: J/psi+g × J/psi+g mixing (normal + phi)
- **JJP_DPS2**: 2J/psi+g × gg mixing
- **JJP_TPS**: Triple parton scattering
- **JUP_SPS**: gg → J/psi + Υ + g
- **JUP_DPS1-3**: Various DPS combinations
- **JUP_TPS**: Triple parton scattering

### 3. Generate DAG

```bash
# Single campaign with 100 jobs
python dag_generator.py --campaign JJP_DPS1 --jobs 100 --output jjp_dps1.dag

# All JJP campaigns with 50 jobs each
python dag_generator.py --campaign JJP_ALL --jobs 50 --output jjp_all.dag

# All campaigns
python dag_generator.py --campaign ALL --jobs 20 --output full_production.dag
```

### 4. Submit DAG

```bash
# Make sure log directory exists
mkdir -p log

# Submit to HTCondor
condor_submit_dag jjp_dps1.dag

# Monitor progress
condor_q
tail -f jjp_dps1.dag.dagman.out
```

## Campaign Physics

### JJP Campaigns (J/psi + J/psi + phi)

| Campaign | Inputs | Shower Modes | Description |
|----------|--------|--------------|-------------|
| JJP_SPS | pool_2jpsi_g | phi | Single interaction producing 2 J/psi |
| JJP_DPS1 | pool_jpsi_g × 2 | normal, phi | Two independent J/psi productions |
| JJP_DPS2 | pool_2jpsi_g + pool_gg | normal, phi | 2 J/psi + gg dijet mixing |
| JJP_TPS | pool_jpsi_g × 2 + pool_gg | normal, normal, phi | Three independent interactions |

### JUP Campaigns (J/psi + Upsilon + phi)

| Campaign | Inputs | Shower Modes | Description |
|----------|--------|--------------|-------------|
| JUP_SPS | pool_jpsi_upsilon_g | phi | Single interaction |
| JUP_DPS1 | pool_jpsi_g + pool_upsilon_g | phi, normal | J/psi (phi) + Υ (normal) |
| JUP_DPS2 | pool_jpsi_g + pool_upsilon_g | normal, phi | J/psi (normal) + Υ (phi) |
| JUP_DPS3 | pool_jpsi_upsilon_g + pool_gg | normal, phi | SPS + dijet mixing |
| JUP_TPS | pool_jpsi_g + pool_upsilon_g + pool_gg | normal, normal, phi | Three interactions |

## LHE Pools

| Pool Name | Process | Status |
|-----------|---------|--------|
| pool_jpsi_g | gg → J/psi + g | ✓ Exists on EOS |
| pool_gg | gg → gg | ✓ Exists on EOS |
| pool_upsilon_g | gg → Υ(1S) + g | Generate on demand |
| pool_2jpsi_g | gg → 2J/psi + g | Generate on demand |
| pool_jpsi_upsilon_g | gg → J/psi + Υ + g | Generate on demand |

## Output Location

All outputs are stored on EOS:
```
/eos/user/x/xcheng/MC_Production/output/<campaign_name>/<job_id>/
  ├── output_MINIAOD.root
  └── output_ntuple.root
```

## Debugging

### Check Job Status
```bash
condor_q -dag
condor_q -analyze <job_id>
```

### View Logs
```bash
# DAGMan log
tail -f *.dag.dagman.out

# Individual job logs
cat log/proc_JJP_DPS1_0_*.stdout
cat log/proc_JJP_DPS1_0_*.stderr
```

### Rescue Failed Jobs
```bash
# If DAG fails, a rescue DAG is created
condor_submit_dag *.dag.rescue001
```

### Test Single Step
```bash
# Test shower locally
cd processing/pythia_shower
source /cvmfs/cms.cern.ch/cmsset_default.sh
cd /path/to/CMSSW_12_4_14_patch3/src && cmsenv && cd -
make
./shower_phi test.lhe output.hepmc 100
```

## Dependencies

- **CMSSW_12_4_14_patch3**: GEN-SIM chain, Pythia8 shower
- **CMSSW_14_0_18**: Ntuple production (JJP/JUP analyzers)
- **HELAC-Onia 2.7.6**: LHE generation
- **HTCondor**: Job scheduling
- **CVMFS**: CMS software distribution

## Contact

For questions or issues, contact the MC production team or refer to:
- [HELAC-Onia documentation](http://helac-phegas.web.cern.ch/helac-phegas/)
- [CMSSW workbook](https://twiki.cern.ch/twiki/bin/view/CMSPublic/WorkBook)
- [HTCondor DAGMan manual](https://htcondor.readthedocs.io/en/latest/users-manual/dagman-workflows.html)

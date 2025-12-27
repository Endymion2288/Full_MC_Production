# Package Preparation Guide
# =========================

This directory should contain the following tar packages for worker node deployment:

## 1. helac_package.tar.gz (Required for LHE generation)

This package now ships the source tarballs only. `run_helac.sh` will unpack and
build HepMC and HELAC-Onia inside the worker sandbox.

### Contents:
- HELAC-Onia-2.7.6.tar.gz (source)
- hepmc2.06.11.tgz (source)

### How to create:

```bash
cd /afs/cern.ch/user/x/xcheng/condor/HELAC-on-HTCondor

# Make sure the source tarballs are present under sources/
cp sources/HELAC-Onia-2.7.6.tar.gz .
cp sources/hepmc2.06.11.tgz .

# Create the package (source-only)
tar -czf helac_package.tar.gz HELAC-Onia-2.7.6.tar.gz hepmc2.06.11.tgz

# Copy to packages directory
cp helac_package.tar.gz /afs/cern.ch/user/x/xcheng/condor/MC_Production_DAG/Full_MC_Production/common/packages/
```

---

## 2. jjp_code.tar.gz (Required for JJP Ntuple production)

This package contains the Dev-J-J-P branch CMSSW code for J/psi + J/psi + phi analysis.
`run_chain.sh` will unpack and compile it inside a fresh CMSSW_14_0_18 project on the worker.

### Contents:
- TPS-Onia2MuMu/ (analyzer code from JJPNtupleMaker)

### How to create:

```bash
cd /afs/cern.ch/user/x/xcheng/condor/CMSSW_14_0_18/src/JJPNtupleMaker

# Create package with analysis code (strip git and caches)
tar --exclude='.git' --exclude='*.root' -czf jjp_code.tar.gz TPS-Onia2MuMu/

# Copy to packages directory
cp jjp_code.tar.gz /afs/cern.ch/user/x/xcheng/condor/MC_Production_DAG/Full_MC_Production/common/packages/
```

---

## 3. jup_code.tar.gz (Required for JUP Ntuple production)

This package contains the Dev-J-U-P branch CMSSW code for J/psi + Upsilon + phi analysis.
`run_chain.sh` will unpack and compile it inside a fresh CMSSW_14_0_18 project on the worker.

### Contents:
- TPS-Onia2MuMu/ (analyzer code from JUPNtupleMaker)

### How to create:

```bash
cd /afs/cern.ch/user/x/xcheng/condor/CMSSW_14_0_18/src/JUPNtupleMaker

# Create package with analysis code (strip git and caches)
tar --exclude='.git' --exclude='*.root' -czf jup_code.tar.gz TPS-Onia2MuMu/

# Copy to packages directory
cp jup_code.tar.gz /afs/cern.ch/user/x/xcheng/condor/MC_Production_DAG/Full_MC_Production/common/packages/
```

---

## Package Verification

After creating packages, verify their contents:

```bash
cd /afs/cern.ch/user/x/xcheng/condor/MC_Production_DAG/Full_MC_Production/common/packages

# List package contents
tar -tzf helac_package.tar.gz | head -20
tar -tzf jjp_code.tar.gz | head -20
tar -tzf jup_code.tar.gz | head -20

# Check sizes
ls -lh *.tar.gz
```

Expected sizes (approx):
- helac_package.tar.gz: ~50-70 MB
- jjp_code.tar.gz: ~10-12 MB
- jup_code.tar.gz: ~1-2 MB

---

## Notes

1. **HELAC-Onia Patches**: The helac_package should include any patches you've applied. 
   Check the `patch/` directory in HELAC-on-HTCondor for modifications. The build now
   happens on the worker node via `run_helac.sh`.

2. **CMSSW Version Compatibility**: 
   - JJP/JUP codes are designed for CMSSW_14_0_18
   - GEN-SIM chain uses CMSSW_12_4_14_patch3

3. **Updating Packages**: When you update the analysis code, remember to rebuild
   the corresponding tar.gz file and test on a worker node before large-scale submission.

4. **Storage Considerations**: These packages are transferred to worker nodes.
   Keep them as small as possible by excluding build artifacts and unnecessary files.
   `processing.sub` already transfers `common/`, so all three tarballs travel with jobs.

# Package Preparation Guide
# =========================

This directory should contain the following tar packages for worker node deployment:

## 1. helac_package.tar.gz (Required for LHE generation)

This package contains HELAC-Onia and its dependencies.

### Contents:
- HELAC-Onia-2.7.6/ (source code)
- HepMC/HepMC-2.06.11/ (pre-built HepMC2 library)
- sources/ (original tarballs for rebuilding if needed)

### How to create:

```bash
# Navigate to your HELAC working directory
cd /afs/cern.ch/user/x/xcheng/condor/HELAC-on-HTCondor

# Make sure HELAC-Onia and HepMC are built
# See scripts/helac_build_run.sh for build instructions

# Create the package
tar -czf helac_package.tar.gz \
    HELAC-Onia-2.7.6/ \
    HepMC/ \
    sources/

# Copy to packages directory
cp helac_package.tar.gz /afs/cern.ch/user/x/xcheng/condor/MC_Production_DAG/Full_MC_Production/common/packages/
```

Alternatively, reference existing package:
```bash
cd /afs/cern.ch/user/x/xcheng/condor/HELAC-on-HTCondor
make  # Creates condor_submit.tar
cp condor_submit.tar /path/to/packages/helac_package.tar.gz
```

---

## 2. jjp_code.tar.gz (Required for JJP Ntuple production)

This package contains the Dev-J-J-P branch CMSSW code for J/psi + J/psi + phi analysis.

### Contents:
- TPS-Onia2MuMu/ (analyzer code from JJPNtupleMaker)

### How to create:

```bash
cd /afs/cern.ch/user/x/xcheng/condor/CMSSW_14_0_18/src/JJPNtupleMaker

# Create package with analysis code
tar -czf jjp_code.tar.gz TPS-Onia2MuMu/

# Copy to packages directory
cp jjp_code.tar.gz /afs/cern.ch/user/x/xcheng/condor/MC_Production_DAG/Full_MC_Production/common/packages/
```

---

## 3. jup_code.tar.gz (Required for JUP Ntuple production)

This package contains the Dev-J-U-P branch CMSSW code for J/psi + Upsilon + phi analysis.

### Contents:
- TPS-Onia2MuMu/ (analyzer code from JUPNtupleMaker)

### How to create:

```bash
cd /afs/cern.ch/user/x/xcheng/condor/CMSSW_14_0_18/src/JUPNtupleMaker

# Create package with analysis code
tar -czf jup_code.tar.gz TPS-Onia2MuMu/

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

Expected sizes:
- helac_package.tar.gz: ~50-100 MB
- jjp_code.tar.gz: ~10-50 MB
- jup_code.tar.gz: ~10-50 MB

---

## Notes

1. **HELAC-Onia Patches**: The helac_package should include any patches you've applied. 
   Check the `patch/` directory in HELAC-on-HTCondor for modifications.

2. **CMSSW Version Compatibility**: 
   - JJP/JUP codes are designed for CMSSW_14_0_18
   - GEN-SIM chain uses CMSSW_12_4_14_patch3

3. **Updating Packages**: When you update the analysis code, remember to rebuild
   the corresponding tar.gz file and test on a worker node before large-scale submission.

4. **Storage Considerations**: These packages are transferred to worker nodes.
   Keep them as small as possible by excluding build artifacts and unnecessary files.

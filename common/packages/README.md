# Package Preparation Guide
# =========================

This directory should contain the tarballs transferred to worker nodes.

## 1. `helac_package.tar.gz` (required)

`run_helac.sh` accepts either source tarballs or a prebuilt HELAC-Onia runtime.
When a compiled `HELAC-Onia-2.7.6/ho_cluster` is present, the worker reuses it
and normalizes known generated absolute symlinks before running.

Contents:
- `HELAC-Onia-2.7.6.tar.gz`
- `hepmc2.06.11.tgz`

Create it with:

```bash
cd /afs/cern.ch/user/x/xcheng/condor/HELAC-on-HTCondor
cp sources/HELAC-Onia-2.7.6.tar.gz .
cp sources/hepmc2.06.11.tgz .
tar -czf helac_package.tar.gz HELAC-Onia-2.7.6.tar.gz hepmc2.06.11.tgz
cp helac_package.tar.gz /afs/cern.ch/user/c/chiw/condor/Full_MC_Production/common/packages/
```

## 2. `tpsonia2mumu_code.tar.gz` (generated automatically)

The ntuple stage now uses one shared CMSSW 15 package for both `JJP` and `JUP`:
- package path inside CMSSW: `src/HeavyFlavorAnalysis/TPS-Onia2MuMu`
- runtime config: `HeavyFlavorAnalysis/TPS-Onia2MuMu/test/ConfFile_cfg.py`
- `JJP -> analysisMode=JpsiJpsiPhi`
- `JUP -> analysisMode=JpsiUpsPhi`

The maintained source now lives in this repo as a git submodule:
- submodule path: `external/TPS-Onia2MuMu`
- upstream URL: `git@github.com:Eric100911/TPS-Onia2MuMu.git`
- current pinned gitlink should be treated as the package baseline

Initialize or refresh it with:

```bash
git submodule update --init --recursive
```

When no prebuilt CMSSW15 runtime is available, `dag_generator.py generate
--enable-ntuple`, `generate-test --enable-ntuple`, and `prepare-runtime
--include-ntuple` build `tpsonia2mumu_code.tar.gz` from the submodule
automatically and insert it into the ntuple runtime bundle. No manual copy into
`common/packages/` is needed.

## 3. `cmssw15_tpsonia2mumu_runtime.tar.gz` (optional, preferred)

For ntuple production, place a prebuilt CMSSW 15 project tarball here or pass it
with `--cmssw15-runtime-tarball`. It should contain `CMSSW_15_0_15/` at archive
root. Worker jobs unpack it, run `scram build ProjectRename`, and skip the
per-job `scram b HeavyFlavorAnalysis/TPS-Onia2MuMu` rebuild.

## Verification

```bash
cd /afs/cern.ch/user/c/chiw/condor/Full_MC_Production/common/packages
tar -tzf helac_package.tar.gz | head -20
ls -lh *.tar.gz
```

Checks:
- runtime generation should produce `tpsonia2mumu_code.tar.gz` under the selected DAG output directory
- the archive must contain `HeavyFlavorAnalysis/TPS-Onia2MuMu/`
- source-package fallback worker build target is `scram b -j 4 HeavyFlavorAnalysis/TPS-Onia2MuMu`
- prebuilt CMSSW15 worker relocation target is `scram build ProjectRename`
- ntuple tests on this branch should be run in `CMSSW_15_0_15`

## Notes

1. `helac_package.tar.gz` remains the only hard dependency for LHE-only and MiniAOD-only smoke tests.
2. The submodule becomes required for `--enable-ntuple` only when no prebuilt CMSSW15 runtime is provided.
3. Keep the package small by excluding `.git`, CRAB work areas, ROOT outputs, and local caches.

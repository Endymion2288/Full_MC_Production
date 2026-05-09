# Repository Guidelines

## Project Structure & Module Organization
This branch targets the `T2_CN_Beijing` workflow, not the older `master` layout. `dag_generator.py` is the main entry point for listing campaigns, validating the environment, building runtime bundles, and generating DAGs. `lhe_generation/` contains HELAC-Onia production and LHE conversion helpers. `processing/run_chain.sh` is the worker-side chain from showering through MiniAOD and optional ntuple production. Shared CMSSW configs, XRootD helpers, and package metadata live in `common/`. The ntuple analyzer source is tracked as the `external/TPS-Onia2MuMu` submodule and packaged into the runtime bundle. Use `tests/` for smoke DAG generation and component checks.

## Build, Test, and Development Commands
List workflows with `python3 dag_generator.py list --kind all`. Validate the local environment with `python3 dag_generator.py validate --campaign JJP_DPS2 --scan-existing`. Generate a smoke DAG with `python3 dag_generator.py generate-test --campaign JJP_DPS2 --output-dir tests/generated/smoke --output smoke.dag`. Run `git submodule update --init --recursive` before any ntuple-related runtime build. Run the branch smoke harness with `./tests/run_all_tests.sh`; add `--submit` or `--wait` only when you intend to send jobs to HTCondor. For local shower rebuilds, use `source common/setup.sh --cmssw12` and `cd processing/pythia_shower && make -B all`.

## Coding Style & Naming Conventions
Keep Python PEP 8 compliant: 4-space indentation, `snake_case`, and uppercase constants for site paths and fixed workflow settings. Bash scripts are written for `bash` with `set -e` and long-form flags such as `--campaign`, `--enable-ntuple`, and `--force-generate-lhe`. Preserve the current naming vocabulary: pool names like `pool_jpsi_CSCO_g`, shower modes like `phi_mpi_off`, and analysis types `JJP`/`JUP`.

## Testing Guidelines
Default smoke validation on this branch stops at MiniAOD unless `--enable-ntuple` is set. For code changes, run `bash -n common/setup.sh processing/run_chain.sh tests/run_all_tests.sh tests/submit_tests.sh` and one `generate-test --dry-run`. If you touch the ntuple stage, verify the `external/TPS-Onia2MuMu` submodule is initialized, confirm `dag_generator.py prepare-runtime` emits `tpsonia2mumu_code.tar.gz`, and test `--enable-ntuple` on one JJP and one JUP campaign.

## Commit & Pull Request Guidelines
The history mixes brief descriptive subjects with `feat:`/`fix:` prefixes; keep commit messages short, imperative, and specific to the workflow stage you changed. PRs should state whether the change affects DAG generation, worker runtime, storage interaction, or ntuple packaging, and include the validation commands used. When changing remote paths, package contracts, or analysis modes, include representative log excerpts or generated DAG metadata.

## Security & Configuration Tips
Do not commit proxies, tokens, Kerberos artifacts, CRAB work areas, or generated ROOT outputs. Keep site-specific paths centralized in `common/setup.sh` and document any new CVMFS, XRootD, or container requirement in the PR.

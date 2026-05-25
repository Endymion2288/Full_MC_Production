# T2_CN_Beijing MC Production DAGMan 系统

本目录用于在 `lxplus` 上生成并提交面向 `T2_CN_Beijing` 的 HTCondor DAGMan 工作流，覆盖以下物理链路：

`LHE(HELAC-Onia) -> Pythia8 shower -> HepMC mixing -> CMSSW GEN-SIM -> RAW -> RECO -> MiniAOD -> Ntuple`

当前代码按 [`workbook_v2.md`](/afs/cern.ch/user/x/xcheng/condor/MC_Production_DAG/T2_CN_Beijing/workbook_v2.md) 重构，默认支持两类分析：

- `JJP`: `J/psi + J/psi + phi`
- `JUP`: `J/psi + Upsilon + phi`

## 当前验收口径

- 代码接口保留全链路能力，包括 `Ntuple` 步骤。
- 本轮小批量 HTCondor 测试默认以跑通到 `MiniAOD` 并完成远端 stage-out 为准。
- `Ntuple` 步骤保留在接口中；若要真正执行，请确保 `external/TPS-Onia2MuMu` submodule 已初始化，且其 gitlink 指向你要打包的分析代码状态。
- `workbook_v2.md` 中要求的“所有程序、文件、证书统一打包上传后在 worker 解压运行”已经落实到当前 submit 模板；worker 运行时不再回读 AFS 业务目录。
- worker 启动时会把打包证书复制到节点默认代理路径 `/tmp/x509up_u$UID`；后续程序不再通过环境变量指向解压目录中的本地文件。

## 目录说明

- [`dag_generator.py`](/afs/cern.ch/user/x/xcheng/condor/MC_Production_DAG/T2_CN_Beijing/dag_generator.py)
  主入口。负责列出配置、校验环境、生成正式 DAG、生成测试 DAG。
- [`lhe_generation/run_helac.sh`](/afs/cern.ch/user/x/xcheng/condor/MC_Production_DAG/T2_CN_Beijing/lhe_generation/run_helac.sh)
  LHE 生成节点执行脚本。
- [`processing/run_chain.sh`](/afs/cern.ch/user/x/xcheng/condor/MC_Production_DAG/T2_CN_Beijing/processing/run_chain.sh)
  processing 节点执行脚本，负责 shower/mix/CMSSW/可选 Ntuple/stage-out；为避免 `lxplus` 与 worker 容器的 glibc/ABI 不一致，脚本会在 worker 上强制重编译 `pythia_shower/` 下的工具。
- [`common/octet_pdg.py`](/afs/cern.ch/user/x/xcheng/condor/MC_Production_DAG/T2_CN_Beijing/common/octet_pdg.py)
  HELAC 八重态旧编码与 Pythia8 `99nqnsnrnLnJ` 编码之间的统一转换/扫描工具。
- [`processing/templates/`](/afs/cern.ch/user/x/xcheng/condor/MC_Production_DAG/T2_CN_Beijing/processing/templates)
  DAG 节点对应的 submit 模板；当前通过 runtime bundle + proxy bundle 在 worker 侧解压运行。
- [`tests/submit_tests.sh`](/afs/cern.ch/user/x/xcheng/condor/MC_Production_DAG/T2_CN_Beijing/tests/submit_tests.sh)
  生成并可选提交小批量测试 DAG。
- [`tests/run_all_tests.sh`](/afs/cern.ch/user/x/xcheng/condor/MC_Production_DAG/T2_CN_Beijing/tests/run_all_tests.sh)
  重构后测试总入口。
- [`tests/test_octet_pdg_tool.sh`](/afs/cern.ch/user/x/xcheng/condor/MC_Production_DAG/T2_CN_Beijing/tests/test_octet_pdg_tool.sh)
  八重态 PDG 映射规则的本地确定性自检。
- [`tests/submit_lhe_matrix.sh`](/afs/cern.ch/user/x/xcheng/condor/MC_Production_DAG/T2_CN_Beijing/tests/submit_lhe_matrix.sh)
  所有真实 LHE pool 的 HTCondor 小批量矩阵测试入口。

## 环境准备

### 1. 代理

优先确保当前 shell 已有可用代理：

```bash
source /cvmfs/cms.cern.ch/cmsset_default.sh
./check_proxy.sh --init
./check_proxy.sh --status
```

若你已经手动初始化过代理，也可以直接导出：

```bash
export X509_USER_PROXY=/tmp/x509up_u$(id -u)
```

重构后的 DAG 默认会优先使用 AFS 上的持久代理副本：

```bash
/afs/cern.ch/user/x/xcheng/x509up_u$(id -u)
```

这样 `condor_dagman` 在 schedd 上做 direct submit 时不会因为看不到 submit host 的 `/tmp` 证书而失败。

### 2. 必需包

硬依赖：

- `common/packages/helac_package.tar.gz`

可选但推荐：

- `external/TPS-Onia2MuMu` git submodule

分析包缺失时，`validate` 默认只给出提示，不会阻止生成“到 MiniAOD”为止的测试 DAG；只有启用 ntuple 时才需要它。运行 `prepare-runtime`、`generate` 或 `generate-test` 时，`dag_generator.py` 会从 submodule 自动打包出 `tpsonia2mumu_code.tar.gz` 并放进 runtime bundle。

首次克隆或切换分支后请先初始化 submodule：

```bash
git submodule update --init --recursive
```

## 主入口用法

### 列出可用配置

```bash
python3 dag_generator.py list --kind all
python3 dag_generator.py list --kind campaigns
python3 dag_generator.py list --kind pools
```

### 校验环境

```bash
python3 dag_generator.py validate --campaign JJP_DPS2_CS --scan-existing
python3 dag_generator.py validate --campaign JUP_DPS1 --scan-existing
```

若要把 `external/TPS-Onia2MuMu` submodule 也作为硬依赖：

```bash
python3 dag_generator.py validate --campaign JJP_DPS1 --strict-analysis-packages
```

### 生成正式 DAG

```bash
python3 dag_generator.py generate \
  --campaign JJP_DPS1 \
  --jobs 20 \
  --output-dir generated/jjp_dps1 \
  --output jjp_dps1.dag \
  --max-events -1
```

常用可选项：

- `--disable-ntuple`
  只跑到 MiniAOD，再做 transfer。
- `--force-generate-lhe`
  不复用远端已有 LHE pool。
- `--no-scan-existing`
  不扫描远端已有 LHE。
- `--test-mode`
  把 LHE 生成切到 fast-test。

### 生成 HELAC-only Fock-state matrix DAG

```bash
python3 dag_generator.py generate-helac-matrix \
  --output-dir generated/helac_matrix \
  --output helac_matrix.dag \
  --stageout-dir helac_matrix/jpsi_upsilon_fock_scan \
  --seed-base 92000 \
  --maxjobs-lhe 20
```

该入口只运行 HELAC-Onia，不接后续 shower/CMSSW。它会生成 162 个 job：
9 个 `cc~` Fock state、9 个 `bb~` Fock state，以及 born / `+ g` 两种过程。
每个 job 会上传一个 `PROC_HO_*/P0_*/output/` 目录 tarball，远端路径位于
`/eos/ihep/cms/store/user/xcheng/MC_Production_v3/helac_matrix/jpsi_upsilon_fock_scan/`。
色八重态 charm/bottom state 会在 HELAC 输入中把对应重夸克质量提高 `0.1 GeV`。

### 仅准备 worker runtime bundle

```bash
python3 dag_generator.py prepare-runtime \
  --output-dir tests/generated/runtime_bundle_check
```

说明：

- submit 模式下，bundle 输出目录必须放在 AFS 工作区，而不是 submit host 的本地 `/tmp`。
- 需要 ntuple runtime 时加 `--include-ntuple`；若提供
  `--cmssw15-runtime-tarball` 或 `common/packages/cmssw15_tpsonia2mumu_runtime.tar.gz`
  存在且结构有效，会优先打包预编译 CMSSW15 runtime，否则回退到 submodule source package。
- 该命令会同时生成：
  - `lhe_runtime_bundle.tar.gz`
  - `processing_runtime_bundle.tar.gz`
  - `summary_runtime_bundle.tar.gz`
  - `proxy_bundle.tar.gz`

### 生成小批量测试 DAG

```bash
python3 dag_generator.py generate-test \
  --campaign JJP_DPS2_CS \
  --campaign JJP_DPS2_G \
  --campaign JUP_DPS1 \
  --jobs 1 \
  --max-events 5 \
  --output-dir tests/generated/manual_test \
  --output mc_test.dag
```

`generate-test` 默认行为：

- `jobs = 1`
- `max-events = 5`
- `disable-ntuple`
- `scan-existing = true`

## 测试入口

### 只做静态校验和测试 DAG 生成

```bash
./tests/run_all_tests.sh
```

该入口默认覆盖：

- `JJP_DPS2_CS`
- `JJP_DPS2_G`
- `JUP_DPS1`

并会先执行：

- `./tests/test_octet_pdg_tool.sh`

### 生成后直接提交到 HTCondor

```bash
./tests/run_all_tests.sh --submit
```

### 指定等待 DAGMan 结束

```bash
./tests/run_all_tests.sh --submit --wait
```

### 启用 ntuple runtime smoke

```bash
./tests/run_all_tests.sh \
  --enable-ntuple \
  --cmssw15-runtime-tarball common/packages/cmssw15_tpsonia2mumu_runtime.tar.gz
```

启用 ntuple 时，校验会要求预编译 CMSSW15 runtime tarball 或
`external/TPS-Onia2MuMu` submodule 至少有一个可用。

### 更细的测试控制

```bash
./tests/submit_tests.sh \
  --campaign JJP_DPS2_CS \
  --campaign JJP_DPS2_G \
  --campaign JUP_DPS1 \
  --jobs 1 \
  --max-events 5 \
  --submit
```

### LHE 全池小批量矩阵测试

```bash
./tests/submit_lhe_matrix.sh --submit --wait
```

该入口会覆盖：

- `pool_jpsi_CSCO_g`
- `pool_upsilon_CSCO_g`
- `pool_gg`
- `pool_2jpsi_cs`
- `pool_2jpsi_g`
- `pool_jpsi_upsilon_CSCO`

并在作业结束后自动：

- 从远端把对应 LHE 拉回本地临时目录
- 用 `common/octet_pdg.py scan --fail-on-legacy` 检查是否还残留 `9900xxxx` 旧编码

测试输出会写到：

- DAG 和元数据：`tests/generated/<时间戳>/`
- 提交日志：`tests/log/`
- HTCondor stdout/stderr/log：仓库根目录 `log/`
- 远端物理输出：`root://cceos.ihep.ac.cn//eos/ihep/cms/store/user/xcheng/MC_Production_v3/output/<campaign>/<job_id>/`

## shower 模式说明

目前统一支持三种模式名：

- `normal`
  普通 shower。
- `phi_mpi_off`
  workbook 默认的 phi-enriched 模式，关闭 MPI，循环 hadronize 直到出现目标 `phi`。
- `phi_mpi_on_gluon`
  保留给 workbook 的扩展模式 2，当前由 `shower_phi` 执行。

兼容别名：

- `phi`、`phi_mode1`、`sps` 都会映射为 `phi_mpi_off`
- `phi_mode2` 会映射为 `phi_mpi_on_gluon`

## JJP 双 J/psi 拆分

- `JJP_SPS_CS` 与 `JJP_SPS_G` 分别生产 `gg -> J/psi + J/psi` born/color-singlet 与 `gg -> J/psi + J/psi + g` 两类源，不再在 worker 端混合。
- `JJP_DPS2_CS` 与 `JJP_DPS2_G` 分别把 `pool_2jpsi_cs`、`pool_2jpsi_g` 与 `pool_gg` 组合，输出路径按 campaign 名独立分开。
- `pool_gg` 保留 `minptq = 4.0`；其他真实 pool，包括 `pool_jpsi_CSCO_g`、`pool_upsilon_CSCO_g`、`pool_2jpsi_cs`、`pool_2jpsi_g`、`pool_jpsi_upsilon_CSCO`，统一使用 `minptq = 0.0`。

## 当前已知限制

- 即使 ntuple submodule 已初始化，本轮小批量 Condor 验证也仍建议默认使用 `--disable-ntuple`，先把验收聚焦在 MiniAOD 与远端 stage-out。
- `phi_mpi_on_gluon` 当前通过 Pythia 事件记录里 `status 21-29` 的 hardest-process gluon 祖先关系判定 `phi` 来源；这已经比原来的占位接口更接近 workbook 要求，但仍建议在正式大样本前做额外物理抽查。
- `condor_submit` 目前会对 submit 模板中的 `MaxRetries` 给出“unused”警告；这不影响实际提交，但说明该字段不是 submit 描述层的生效参数，真正的重试控制仍以 DAGMan `RETRY` 为准。

## 典型工作流

```bash
# 1. 检查代理与环境
python3 dag_generator.py validate --campaign JJP_DPS2_CS --scan-existing

# 2. 生成小批量测试 DAG
python3 dag_generator.py generate-test \
  --campaign JJP_DPS2_CS \
  --campaign JJP_DPS2_G \
  --campaign JUP_DPS1 \
  --output-dir tests/generated/smoke \
  --output smoke.dag

# 3. 提交
condor_submit_dag tests/generated/smoke/smoke.dag

# 4. 观察队列
condor_q
```

## 旧脚本说明

`tests/test_lhe_generation.sh`、`tests/test_shower_chain.sh`、`tests/test_cmssw_chain.sh` 和 `tests/test_pipeline.sh` 仍然保留，主要用于组件级调试。重构后的推荐提交流程以 `dag_generator.py + tests/submit_tests.sh` 为准。

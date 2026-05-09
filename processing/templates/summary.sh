#!/bin/bash
# DAG 汇总节点只负责给出最小完成标记，详细结果以各 processing job 日志和远端输出为准。

echo "=========================================="
echo "DAG 末端汇总节点执行完成。"
echo "输出目录基准: root://cceos.ihep.ac.cn//eos/ihep/cms/store/user/xcheng/MC_Production_v3/output"
echo "请结合 processing 日志和 metadata.json 检查实际成功节点。"
echo "=========================================="
exit 0

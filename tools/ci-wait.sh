#!/bin/bash
# 等一次提交的两个 CI 结果（Windows、Linux），再打印各自的注释（每一步最多 10 条）：bash tools/ci-wait.sh <commit sha>
# wait for both check runs of a commit, then print status and annotations
sha=$1
for i in $(seq 1 90); do
  out=$(gh api repos/Xuanqiyun/ClearC/commits/$sha/check-runs --jq '.check_runs[] | "\(.id) \(.name) \(.status) \(.conclusion)"' 2>/dev/null)
  n=$(echo "$out" | grep -c completed)
  if [ "$n" -ge 2 ]; then break; fi
  sleep 30
done
echo "$out"
for id in $(echo "$out" | awk '{print $1}'); do
  echo "== $id"
  gh api repos/Xuanqiyun/ClearC/check-runs/$id/annotations --jq '.[] | "\(.annotation_level) | \(.title) | \(.message)"' 2>/dev/null
done

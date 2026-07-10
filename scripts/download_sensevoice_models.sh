#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT_DIR}/models/sensevoice"
REPO="FluidInference/sensevoice-small-coreml"

mkdir -p "${OUT_DIR}"

if ! command -v hf >/dev/null 2>&1; then
  echo "安装 huggingface_hub CLI ..."
  python3 -m pip install --user -q "huggingface_hub[cli]"
  export PATH="${HOME}/Library/Python/3.11/bin:${HOME}/.local/bin:${PATH}"
fi

if ! command -v hf >/dev/null 2>&1; then
  echo "错误：未找到 hf 命令。请运行: python3 -m pip install 'huggingface_hub[cli]'"
  exit 1
fi

echo "下载 SenseVoice CoreML 模型到 ${OUT_DIR} ..."
hf download "${REPO}" --local-dir "${OUT_DIR}"

echo "校验必需文件 ..."
test -f "${OUT_DIR}/vocab.json"
test -d "${OUT_DIR}/SenseVoicePreprocessor.mlmodelc"
test -d "${OUT_DIR}/SenseVoiceSmall_int8.mlmodelc"

echo "完成。推荐在设置中使用 INT8 编码器（默认）。模型目录：${OUT_DIR}"

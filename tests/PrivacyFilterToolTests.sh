#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="${ROOT}/build/Executables/ClawdHomePrivacyFilter"
MODEL_ID="clawdhome-privacy-ner-v1"

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if ! grep -Fq -- "$needle" <<<"$haystack"; then
    echo "Expected output to contain: $needle" >&2
    echo "Actual output:" >&2
    echo "$haystack" >&2
    exit 1
  fi
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq -- "$needle" "$file"; then
    echo "Expected ${file} to contain: $needle" >&2
    exit 1
  fi
}

cd "$ROOT"
assert_file_contains "${ROOT}/ClawdHomePrivacyFilter/Package.swift" "swift-huggingface"
assert_file_contains "${ROOT}/ClawdHomePrivacyFilter/main.swift" "import HuggingFace"
assert_file_contains "${ROOT}/ClawdHomePrivacyFilter/main.swift" "--continue-at"
assert_file_contains "${ROOT}/ClawdHomePrivacyFilter/main.swift" "--retry-all-errors"
make build-privacy-filter >/tmp/clawdhome-privacy-filter-build.log

help_output="$("$TOOL" help)"
assert_contains "$help_output" "Usage:"
assert_contains "$help_output" "prepare-model"
assert_contains "$help_output" "analyze"
assert_contains "$help_output" "redact"
assert_contains "$help_output" "restore"
assert_contains "$help_output" "prepare-onnx-model"
assert_contains "$help_output" "inspect-onnx-model"
assert_contains "$help_output" "--progress-file"
assert_contains "$help_output" "--model-id"

tmp_dir="$(mktemp -d)"
model_dir="${tmp_dir}/model"

set +e
missing_output="$(printf '内部项目代号 Lobster-AI' | "$TOOL" analyze --model-id "$MODEL_ID" --cache-dir "$model_dir" 2>/dev/null)"
missing_status=$?
set -e
if [ "$missing_status" -eq 0 ]; then
  echo "Analyze unexpectedly succeeded without an installed model" >&2
  echo "$missing_output" >&2
  exit 1
fi
assert_contains "$missing_output" '"ok":false'
assert_contains "$missing_output" 'model is not installed'

prepare_output="$("$TOOL" prepare-model --model-id "$MODEL_ID" --cache-dir "$model_dir")"
assert_contains "$prepare_output" '"ok":true'
assert_contains "$prepare_output" '"modelID":"clawdhome-privacy-ner-v1"'
test -f "${model_dir}/manifest.json"
test -f "${model_dir}/model.json"

analyze_output="$(printf '内部项目代号 Lobster-AI，负责人账号 alex_admin' | "$TOOL" analyze --model-id "$MODEL_ID" --cache-dir "$model_dir")"
assert_contains "$analyze_output" '"ok":true'
assert_contains "$analyze_output" '"entity":"ORG"'
assert_contains "$analyze_output" '"word":"Lobster-AI"'
assert_contains "$analyze_output" '"entity":"USER"'
assert_contains "$analyze_output" '"word":"alex_admin"'

custom_model="${tmp_dir}/custom-model.json"
cat >"$custom_model" <<'JSON'
{
  "schemaVersion": 1,
  "modelID": "custom-privacy-model",
  "version": "1.0.0",
  "engine": "lexical-context-ner",
  "rules": [
    {
      "id": "custom-internal-user",
      "entity": "USER",
      "score": 0.94,
      "pattern": "\\b(phoenix_user_[0-9]+)\\b",
      "captureGroup": 1
    }
  ],
  "dictionaries": []
}
JSON

custom_dir="${tmp_dir}/custom"
"$TOOL" prepare-model --model-id custom-privacy-model --cache-dir "$custom_dir" --model-url "file://${custom_model}" >/dev/null
custom_output="$(printf '内部用户 phoenix_user_42 已被授权' | "$TOOL" analyze --model-id custom-privacy-model --cache-dir "$custom_dir")"
assert_contains "$custom_output" '"entity":"USER"'
assert_contains "$custom_output" '"word":"phoenix_user_42"'

map_file="${tmp_dir}/privacy-map.json"
redact_output="$(printf '内部项目代号 Lobster-AI，负责人账号 alex_admin' | "$TOOL" redact --model-id "$MODEL_ID" --cache-dir "$model_dir" --map-file "$map_file")"
assert_contains "$redact_output" '"ok":true'
assert_contains "$redact_output" '"redactedText":"内部项目代号 {{ORG_1}}，负责人账号 {{USER_1}}"'
test -f "$map_file"
assert_contains "$(cat "$map_file")" '"placeholder":"{{ORG_1}}"'
assert_contains "$(cat "$map_file")" '"value":"Lobster-AI"'

restore_output="$(printf '建议保留 {{ORG_1}}，由 {{USER_1}} 跟进。' | "$TOOL" restore --map-file "$map_file")"
assert_contains "$restore_output" '"ok":true'
assert_contains "$restore_output" '"restoredText":"建议保留 Lobster-AI，由 alex_admin 跟进。"'

onnx_dir="${tmp_dir}/onnx"
onnx_plan="$("$TOOL" prepare-onnx-model --model-id openai-privacy-filter-q4 --cache-dir "$onnx_dir" --dry-run)"
assert_contains "$onnx_plan" '"ok":true'
assert_contains "$onnx_plan" '"modelID":"openai-privacy-filter-q4"'
assert_contains "$onnx_plan" '"onnx\/model_q4.onnx"'
assert_contains "$onnx_plan" '"onnx\/model_q4.onnx_data"'

onnx_status_missing="$("$TOOL" status --model-id openai-privacy-filter-q4 --cache-dir "$onnx_dir")"
assert_contains "$onnx_status_missing" '"ok":true'
assert_contains "$onnx_status_missing" '"installed":false'
mkdir -p "${onnx_dir}/onnx"
touch \
  "${onnx_dir}/config.json" \
  "${onnx_dir}/tokenizer.json" \
  "${onnx_dir}/tokenizer_config.json" \
  "${onnx_dir}/viterbi_calibration.json" \
  "${onnx_dir}/onnx/model_q4.onnx" \
  "${onnx_dir}/onnx/model_q4.onnx_data"
onnx_status_empty="$("$TOOL" status --model-id openai-privacy-filter-q4 --cache-dir "$onnx_dir")"
assert_contains "$onnx_status_empty" '"ok":true'
assert_contains "$onnx_status_empty" '"installed":false'
/usr/bin/truncate -s 3039 "${onnx_dir}/config.json"
/usr/bin/truncate -s 27868174 "${onnx_dir}/tokenizer.json"
/usr/bin/truncate -s 234 "${onnx_dir}/tokenizer_config.json"
/usr/bin/truncate -s 372 "${onnx_dir}/viterbi_calibration.json"
/usr/bin/truncate -s 160219 "${onnx_dir}/onnx/model_q4.onnx"
/usr/bin/truncate -s 917120144 "${onnx_dir}/onnx/model_q4.onnx_data"
onnx_status_installed="$("$TOOL" status --model-id openai-privacy-filter-q4 --cache-dir "$onnx_dir")"
assert_contains "$onnx_status_installed" '"ok":true'
assert_contains "$onnx_status_installed" '"installed":true'

progress_file="${tmp_dir}/onnx-progress.json"
onnx_prepare_existing="$("$TOOL" prepare-onnx-model --model-id openai-privacy-filter-q4 --cache-dir "$onnx_dir" --progress-file "$progress_file")"
assert_contains "$onnx_prepare_existing" '"ok":true'
test -f "$progress_file"
assert_contains "$(cat "$progress_file")" '"status":"done"'
assert_contains "$(cat "$progress_file")" '"bytesPerSecond":0'
assert_contains "$(cat "$progress_file")" '"downloadedBytes":945152182'

set +e
inspect_output="$("$TOOL" inspect-onnx-model --model-id openai-privacy-filter-q4 --cache-dir "${tmp_dir}/onnx-missing" 2>/dev/null)"
inspect_status=$?
set -e
if [ "$inspect_status" -eq 0 ]; then
  echo "Inspect unexpectedly succeeded without downloaded ONNX files" >&2
  echo "$inspect_output" >&2
  exit 1
fi
assert_contains "$inspect_output" '"ok":false'
assert_contains "$inspect_output" 'missing ONNX model file'

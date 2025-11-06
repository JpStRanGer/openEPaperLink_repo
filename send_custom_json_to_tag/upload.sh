#!/usr/bin/env bash
set -euo pipefail

usage(){
          cat <<'EOF'
Bruk: script.sh [-v] -f FIL
  -f FIL   Fil å prosessere (påkrevd)
  -v       Verbos
EOF
}

echo "${1}"

curl -sS -X POST 'http://192.168.40.129/jsonupload' \
  --data-urlencode 'mac=0000032DA56D3E14' \
  --data-urlencode "json@${1}"

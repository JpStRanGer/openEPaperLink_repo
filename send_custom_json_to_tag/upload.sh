#!/usr/bin/env bash
#
# Sender en JSON-tegneinstruks til en OpenEPaperLink-tag via AP-ens
# /jsonupload-endepunkt.  Enten en ferdig JSON-fil (FIL) eller en
# auto-skalert status-mal bygget fra -t TEKST.

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly RENDER="${SCRIPT_DIR}/render.py"

ap="172.30.4.138"
# mac="0000032DA56D3E14"
mac="0000032E45CB3E15"
size="2.6"
header="STATUS"
text=""
color="black"
header_color="black"

usage() {
  cat <<EOF
Bruk: $(basename "$0") [-a AP] [-m MAC] [-s STR] (-t TEKST [-H TOPP] | FIL)

  -a AP      AP-adresse (standard: ${ap})
  -m MAC     Tag MAC-adresse (standard: ${mac})
  -s STR     Tag-størrelse: 1.54 | 2.6 | 2.7 | 2.9 | 4.2 | 7.5 (standard: ${size})
  -t TEKST   Hovedtekst — fonten skaleres automatisk og teksten brytes
             ved behov.  Backslash-escapes tolkes:  \\n  \\t  \\r  \\\\  \\"
             \\'  \\0  \\xHH  \\uHHHH  \\UHHHHHHHH.
  -H TOPP    Topptekst over streken (standard: ${header}).  Samme escape-sett.
  -c FARGE   Farge på hovedtekst: black | red | svart | rød | 1 | 2
             (standard: ${color}; red = aksentfarge på BWR-tagger)
  -C FARGE   Farge på topptekst (standard: ${header_color})
  FIL        Ferdig JSON-fil som sendes uendret.

-t og FIL er gjensidig utelukkende; akkurat én må oppgis.

Shell-sitat:
  Bruk *enkeltfnutter* rundt TEKST for de tryggeste resultatene:

      $(basename "$0") -t 'OPPTATT!'

  Inne i dobbeltfnutter tolker shellen \` \$ \\ og \! (historie-ekspansjon
  i bash/zsh), så tegn som \`!\` og \`\$\` blir spist før de når skriptet.
  Enkeltfnutter kutter ut all ekspansjon.  Trenger du likevel et
  spesialtegn uten å kunne sitere det, bruk \\xHH eller \\uHHHH:

      $(basename "$0") -t 'hei\\x21'     # → hei!
      $(basename "$0") -t 'gr\\u00f8t'   # → grøt
EOF
}

die() {
  echo "$*" >&2
  usage >&2
  exit 2
}

post() {
  # $1 er verdien til 'json'-feltet; prefiks '@' for filreferanse, '=' for inline.
  curl -sS -X POST "http://${ap}/jsonupload" \
    --data-urlencode "mac=${mac}" \
    --data-urlencode "json${1}"
}

while getopts ":a:m:s:t:H:c:C:h" opt; do
  case "$opt" in
    a) ap="$OPTARG" ;;
    m) mac="$OPTARG" ;;
    s) size="$OPTARG" ;;
    t) text="$OPTARG" ;;
    H) header="$OPTARG" ;;
    c) color="$OPTARG" ;;
    C) header_color="$OPTARG" ;;
    h) usage; exit 0 ;;
    \?) die "Ukjent flagg: -$OPTARG" ;;
    :)  die "Flagg -$OPTARG krever et argument" ;;
  esac
done
shift $((OPTIND - 1))

[[ -n "$text" && $# -ge 1 ]] && die "Kan ikke kombinere -t og FIL"
[[ -z "$text" && $# -lt 1 ]] && die "Oppgi enten -t TEKST eller FIL"

if [[ -z "$text" ]]; then
  file="$1"
  echo "$file"
  post "@${file}"
  exit 0
fi

payload=$(python3 "$RENDER" --size "$size" --header "$header" --text "$text" \
  --color "$color" --header-color "$header_color")
echo "$payload"
post "=${payload}"

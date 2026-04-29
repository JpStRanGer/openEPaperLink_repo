#!/usr/bin/env bash
#
# Sender en JSON-tegneinstruks til en OpenEPaperLink-tag via AP-ens
# /jsonupload-endepunkt.  Enten en ferdig JSON-fil (FIL) eller en
# auto-skalert status-mal bygget fra -t TEKST.
#
# Per-bruker oppsett (MAC + AP-IP) lagres i config.sh ved siden av
# skriptet.  Første kjøring uten config trigger interaktivt oppsett.

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly RENDER="${SCRIPT_DIR}/render.py"
readonly CONFIG="${SCRIPT_DIR}/config.sh"

ap=""
mac=""
size="2.6"
header="STATUS"
text=""
color="black"
header_color="black"
do_setup=0

usage() {
  cat <<EOF
Bruk: $(basename "$0") [-a AP] [-m MAC] [-s STR] (-t TEKST [-H TOPP] | FIL)
      $(basename "$0") -S      # interaktivt oppsett (eller endring) av config.sh

  -a AP      AP-adresse (overstyrer config)
  -m MAC     Tag MAC-adresse (overstyrer config)
  -s STR     Tag-størrelse: 1.54 | 2.6 | 2.7 | 2.9 | 4.2 | 7.5 (standard: ${size})
  -t TEKST   Hovedtekst — fonten skaleres automatisk og teksten brytes
             ved behov.  Backslash-escapes tolkes:  \\n  \\t  \\r  \\\\  \\"
             \\'  \\0  \\xHH  \\uHHHH  \\UHHHHHHHH.
  -H TOPP    Topptekst over streken (standard: ${header}).  Samme escape-sett.
  -c FARGE   Farge på hovedtekst: black | red | svart | rød | 1 | 2
             (standard: ${color}; red = aksentfarge på BWR-tagger)
  -C FARGE   Farge på topptekst (standard: ${header_color})
  -S         Kjør interaktivt oppsett (lager/oppdaterer config.sh)
  FIL        Ferdig JSON-fil som sendes uendret.

-t og FIL er gjensidig utelukkende; akkurat én må oppgis.

Førstegangs-oppsett:
  Skriptet lagrer MAC og AP-IP i config.sh ved siden av seg selv.
  Første gang du kjører uten oppsett, blir du bedt om å fylle inn
  begge.  MAC-en står som tekst og strekkode bak på taggen
  (16 hex-tegn, f.eks. 0000032DA56D3E14).

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
  echo "(kjør $(basename "$0") -h for hjelp)" >&2
  exit 2
}

post() {
  # $1 = etikett vi skriver ut (filnavn eller selve JSON-en).
  # $2 = verdien til 'json'-feltet til curl; prefiks '@' for fil, '=' for inline.
  echo "→ POST http://${ap}/jsonupload   mac=${mac}"
  echo "$1"
  curl -sS -w '\n' -X POST "http://${ap}/jsonupload" \
    --data-urlencode "mac=${mac}" \
    --data-urlencode "json${2}"
}

is_valid_mac() {
  [[ "$1" =~ ^[0-9A-Fa-f]{16}$ ]]
}

is_valid_host() {
  # Godta enten dotted IPv4 eller hostname.  Strengere validering ville
  # bare være i veien — selve tilkoblingen feiler raskt hvis verten er feil.
  [[ "$1" =~ ^[A-Za-z0-9.\-]+$ ]]
}

prompt() {
  # $1 = ledetekst, $2 = default (kan være tom), $3 = validator-funksjon
  local label="$1" default="$2" validator="$3" ans
  while true; do
    if [[ -n "$default" ]]; then
      read -r -p "$label [$default]: " ans
      ans="${ans:-$default}"
    else
      read -r -p "$label: " ans
    fi
    if "$validator" "$ans"; then
      printf '%s\n' "$ans"
      return 0
    fi
    echo "  ugyldig — prøv igjen" >&2
  done
}

run_setup() {
  cat >&2 <<'EOF'

-- Oppsett av OEPL-tag --
Vi trenger MAC-adressen til taggen din og IP-en til AP-en.

MAC-adressen står som tekst og strekkode bak på taggen — 16
hex-tegn, f.eks. 0000032DA56D3E14.  Skann strekkoden med en
mobil-app (Google Lens, en QR/strekkode-leser e.l.) eller skriv
av tallene direkte.

EOF
  local new_mac new_ap
  new_mac=$(prompt "MAC" "${mac:-}" is_valid_mac)
  new_ap=$(prompt "AP IP" "${ap:-172.30.4.138}" is_valid_host)

  cat > "$CONFIG" <<EOF
# Per-bruker oppsett — generert av $(basename "$0") -S.
# Ikke commit denne filen.  Slett for å trigge nytt oppsett ved neste kjøring.
mac="${new_mac^^}"
ap="${new_ap}"
EOF
  echo "Lagret til ${CONFIG}" >&2

  mac="${new_mac^^}"
  ap="${new_ap}"
}

[[ -f "$CONFIG" ]] && source "$CONFIG"

while getopts ":a:m:s:t:H:c:C:Sh" opt; do
  case "$opt" in
    a) ap="$OPTARG" ;;
    m) mac="$OPTARG" ;;
    s) size="$OPTARG" ;;
    t) text="$OPTARG" ;;
    H) header="$OPTARG" ;;
    c) color="$OPTARG" ;;
    C) header_color="$OPTARG" ;;
    S) do_setup=1 ;;
    h) usage; exit 0 ;;
    \?) die "Ukjent flagg: -$OPTARG" ;;
    :)  die "Flagg -$OPTARG krever et argument" ;;
  esac
done
shift $((OPTIND - 1))

if [[ $do_setup -eq 1 ]]; then
  run_setup
  exit 0
fi

if [[ -z "$mac" || -z "$ap" ]]; then
  run_setup
fi

is_valid_mac "$mac"  || die "MAC '$mac' har ikke gyldig format (16 hex-tegn)"
is_valid_host "$ap"  || die "AP-adresse '$ap' har ikke gyldig format"

[[ -n "$text" && $# -ge 1 ]] && die "Kan ikke kombinere -t og FIL"
[[ -z "$text" && $# -lt 1 ]] && die "Oppgi enten -t TEKST eller FIL"

if [[ -z "$text" ]]; then
  file="$1"
  post "$file" "@${file}"
  exit 0
fi

payload=$(python3 "$RENDER" --size "$size" --header "$header" --text "$text" \
  --color "$color" --header-color "$header_color")
post "$payload" "=${payload}"

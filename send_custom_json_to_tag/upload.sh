#!/usr/bin/env bash
#
# Sender en JSON-tegneinstruks til en OpenEPaperLink-tag via AP-ens
# /jsonupload-endepunkt.  Enten en ferdig JSON-fil (FIL) eller en
# auto-skalert status-mal bygget fra -t TEKST.
#
# Per-bruker oppsett (en eller flere navngitte tagger + AP-IP) lagres
# i config.sh ved siden av skriptet.  Mangler config trigger
# interaktivt oppsett.

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly RENDER="${SCRIPT_DIR}/render.py"
readonly CONFIG="${SCRIPT_DIR}/config.sh"

ap=""
declare -A tags=()
default_tag=""
mac=""
tag_name=""
size="2.6"
header="STATUS"
text=""
color="black"
header_color="black"
do_setup=0

usage() {
  cat <<EOF
Bruk: $(basename "$0") [-a AP] [-m MAC | -n NAVN] [-s STR] (-t TEKST [-H TOPP] | FIL)
      $(basename "$0") -S      # interaktivt oppsett (legg til tag eller første gang)

  -a AP      AP-adresse (overstyrer config)
  -m MAC     Tag MAC-adresse — direkte (16 hex-tegn)
  -n NAVN    Velg navngitt tag fra config.sh
  -s STR     Tag-størrelse: 1.54 | 2.6 | 2.7 | 2.9 | 4.2 | 7.5 (standard: ${size})
  -t TEKST   Hovedtekst — fonten skaleres automatisk og teksten brytes
             ved behov.  Backslash-escapes tolkes:  \\n  \\t  \\r  \\\\  \\"
             \\'  \\0  \\xHH  \\uHHHH  \\UHHHHHHHH.
  -H TOPP    Topptekst over streken (standard: ${header}).  Samme escape-sett.
  -c FARGE   Farge på hovedtekst: black | red | svart | rød | 1 | 2
             (standard: ${color}; red = aksentfarge på BWR-tagger)
  -C FARGE   Farge på topptekst (standard: ${header_color})
  -S         Interaktivt oppsett: legg til tag eller kjør første gang
  FIL        Ferdig JSON-fil som sendes uendret.

-t og FIL er gjensidig utelukkende; -m og -n er gjensidig utelukkende.

Tag-valg når verken -m eller -n er gitt:
  Ingen tagger i config  →  starter førstegangsoppsett
  Én tag                 →  bruker den automatisk
  Flere tagger           →  interaktiv velger med default fra default_tag

Førstegangs-oppsett (-S eller manglende config):
  Skriptet lagrer AP-IP og en tag (navn + MAC) i config.sh ved siden av
  seg selv.  MAC-en står som tekst og strekkode bak på taggen
  (16 hex-tegn, f.eks. 0000032DA56D3E14).  Senere kjøringer av -S
  legger til flere tagger.  For å fjerne eller rename, rediger
  config.sh manuelt.

Shell-sitat:
  Bruk *enkeltfnutter* rundt TEKST for de tryggeste resultatene:

      $(basename "$0") -t 'OPPTATT!'

  Inne i dobbeltfnutter tolker shellen \` \$ \\ og \! (historie-ekspansjon
  i bash/zsh), så tegn som \`!\` og \`\$\` blir spist før de når skriptet.
  Trenger du likevel et spesialtegn, bruk \\xHH eller \\uHHHH:

      $(basename "$0") -t 'hei\\x21'     # → hei!
      $(basename "$0") -t 'gr\\u00f8t'   # → grøt
EOF
}

die() {
  echo "$*" >&2
  echo "(kjør $(basename "$0") -h for hjelp)" >&2
  exit 2
}

is_valid_mac() {
  [[ "$1" =~ ^[0-9A-Fa-f]{16}$ ]]
}

is_valid_host() {
  [[ "$1" =~ ^[A-Za-z0-9.\-]+$ ]]
}

is_valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
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

write_config() {
  {
    cat <<EOF
# Per-bruker oppsett — generert av $(basename "$0") -S.
# Ikke commit denne filen.  Slett for å trigge nytt oppsett.

ap="$ap"

declare -A tags=(
EOF
    local n
    for n in "${!tags[@]}"; do
      printf '  [%s]=%q\n' "$n" "${tags[$n]}"
    done
    echo ")"
    [[ -n "$default_tag" ]] && echo "default_tag=\"$default_tag\""
  } > "$CONFIG"
}

migrate_legacy_config() {
  # Gammelt format hadde flat `mac="..."`.  Hvis vi finner én slik MAC
  # uten tags-array, navngis den 'min' og config skrives om.
  [[ -n "${mac:-}" && ${#tags[@]} -eq 0 ]] || return 0
  local legacy="${mac^^}"
  is_valid_mac "$legacy" || return 0
  tags["min"]="$legacy"
  default_tag="min"
  mac=""
  write_config
  echo "→ Oppgradert config.sh: gammel MAC ble navngitt 'min'." >&2
  echo "  Rediger filen hvis du vil endre navnet." >&2
}

list_tags() {
  local n
  for n in "${!tags[@]}"; do
    printf "  %-15s %s\n" "$n" "${tags[$n]}"
  done | sort
}

run_setup() {
  if [[ ${#tags[@]} -eq 0 ]]; then
    cat >&2 <<'EOF'

-- Førstegangsoppsett av OEPL-tag --
Vi trenger AP-en sin IP-adresse, og en tag (navn + MAC).

MAC-adressen står som tekst og strekkode bak på taggen — 16
hex-tegn, f.eks. 0000032DA56D3E14.  Skann strekkoden med en
mobil-app (Google Lens, en QR/strekkode-leser e.l.) eller skriv
av tallene direkte.

EOF
    ap=$(prompt "AP IP" "${ap:-172.30.4.138}" is_valid_host)
  else
    cat >&2 <<EOF

-- Legg til ny tag --
Eksisterende tagger:
$(list_tags)

EOF
  fi

  local name new_mac
  name=$(prompt "Navn på tag (f.eks. 'min', 'kollega')" "" is_valid_name)
  new_mac=$(prompt "MAC for $name" "" is_valid_mac)
  tags["$name"]="${new_mac^^}"
  [[ -z "$default_tag" ]] && default_tag="$name"
  write_config
  echo "Lagret: $name = ${new_mac^^}" >&2
}

choose_tag() {
  # Viser numerert liste og leser inn tall *eller* navn.
  local names=()
  mapfile -t names < <(printf '%s\n' "${!tags[@]}" | sort)

  echo "Velg tag:" >&2
  local i=1 n
  for n in "${names[@]}"; do
    printf "  %d) %-15s %s\n" "$i" "$n" "${tags[$n]}" >&2
    ((i++)) || true
  done

  local default_label="${default_tag:-${names[0]}}"
  local choice
  while true; do
    read -r -p "Valg [$default_label]: " choice
    choice="${choice:-$default_label}"

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#names[@]} )); then
      tag_name="${names[$((choice-1))]}"
      mac="${tags[$tag_name]}"
      return 0
    fi
    if [[ -n "${tags[$choice]:-}" ]]; then
      tag_name="$choice"
      mac="${tags[$choice]}"
      return 0
    fi
    echo "  ukjent valg" >&2
  done
}

resolve_tag() {
  # Bestemmer endelig $mac (og evt $tag_name) fra flagg + config.
  [[ -n "$mac" && -n "$tag_name" ]] && die "Bruk enten -m MAC eller -n NAVN, ikke begge"

  if [[ -n "$mac" ]]; then
    mac="${mac^^}"
    # Berik output med navn hvis MAC matcher en kjent tag.
    local n
    for n in "${!tags[@]}"; do
      if [[ "${tags[$n]^^}" == "$mac" ]]; then
        tag_name="$n"
        break
      fi
    done
    return 0
  fi

  if [[ -n "$tag_name" ]]; then
    [[ -n "${tags[$tag_name]:-}" ]] || die "Ingen tag med navn '$tag_name' i config.sh"
    mac="${tags[$tag_name]}"
    return 0
  fi

  if (( ${#tags[@]} == 1 )); then
    local only=("${!tags[@]}")
    tag_name="${only[0]}"
    mac="${tags[$tag_name]}"
    return 0
  fi

  choose_tag
}

post() {
  # $1 = etikett vi skriver ut (filnavn eller selve JSON-en).
  # $2 = verdien til 'json'-feltet til curl; '@<fil>' eller '=<inline>'.
  local label="${tag_name:+($tag_name) }mac=${mac}"
  echo "→ POST http://${ap}/jsonupload   ${label}"
  echo "$1"
  curl -sS -w '\n' -X POST "http://${ap}/jsonupload" \
    --data-urlencode "mac=${mac}" \
    --data-urlencode "json${2}"
}

parse_args() {
  while getopts ":a:m:n:s:t:H:c:C:Sh" opt; do
    case "$opt" in
      a) ap="$OPTARG" ;;
      m) mac="$OPTARG" ;;
      n) tag_name="$OPTARG" ;;
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
}

dispatch() {
  # $@ er positional args som er igjen etter flagg-parsing.
  is_valid_mac "$mac"  || die "MAC '$mac' har ikke gyldig format (16 hex-tegn)"
  is_valid_host "$ap"  || die "AP-adresse '$ap' har ikke gyldig format"

  [[ -n "$text" && $# -ge 1 ]] && die "Kan ikke kombinere -t og FIL"
  [[ -z "$text" && $# -lt 1 ]] && die "Oppgi enten -t TEKST eller FIL"

  if [[ -z "$text" ]]; then
    local file="$1"
    post "$file" "@${file}"
    return 0
  fi

  local payload
  payload=$(python3 "$RENDER" --size "$size" --header "$header" --text "$text" \
    --color "$color" --header-color "$header_color")
  post "$payload" "=${payload}"
}

main() {
  [[ -f "$CONFIG" ]] && source "$CONFIG"
  migrate_legacy_config

  parse_args "$@"
  shift $((OPTIND - 1))

  if [[ $do_setup -eq 1 ]]; then
    run_setup
    return 0
  fi

  if [[ -z "$ap" || ${#tags[@]} -eq 0 ]]; then
    run_setup
  fi

  resolve_tag
  dispatch "$@"
}

main "$@"

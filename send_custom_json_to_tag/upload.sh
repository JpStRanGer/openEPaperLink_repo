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

readonly DEFAULT_SIZE="2.6"
readonly DEFAULT_ROTATE="0"

ap=""
declare -A tags=()
default_tag=""
mac=""
tag_name=""
size=""           # tom = ikke satt via flagg; fylles fra tag-entry eller default
rotate=""         # samme som size
header="STATUS"
text=""
color="black"
header_color="black"
do_setup=0

# Felt fylt av parse_tag_entry().
entry_mac=""
entry_size=""
entry_rotate=""

usage() {
  cat <<EOF
Bruk: $(basename "$0") [-a AP] [-m MAC | -n NAVN] [-s STR] [-r N] (-t TEKST [-H TOPP] | FIL)
      $(basename "$0") -S      # interaktivt oppsett (legg til tag eller første gang)

  -a AP      AP-adresse (overstyrer config)
  -m MAC     Tag MAC-adresse — direkte (16 hex-tegn)
  -n NAVN    Velg navngitt tag fra config.sh
  -s STR     Tag-størrelse: 1.54 | 2.6 | 2.7 | 2.9 | 3.5 | 4.2 | 7.5
             (overstyrer per-tag-verdi; default ${DEFAULT_SIZE})
  -t TEKST   Hovedtekst — fonten skaleres automatisk og teksten brytes
             ved behov.  Backslash-escapes tolkes:  \\n  \\t  \\r  \\\\  \\"
             \\'  \\0  \\xHH  \\uHHHH  \\UHHHHHHHH.
  -H TOPP    Topptekst over streken (standard: ${header}).  Samme escape-sett.
  -c FARGE   Farge på hovedtekst: black | red | svart | rød | 1 | 2
             (standard: ${color}; red = aksentfarge på BWR-tagger)
  -C FARGE   Farge på topptekst (standard: ${header_color})
  -r N       Canvas-rotasjon: 0 (native) | 1 (90° CW) | 2 (180°) | 3 (90° CCW)
             (overstyrer per-tag-verdi; default ${DEFAULT_ROTATE})
  -S         Interaktivt oppsett: legg til tag eller kjør første gang
  FIL        Ferdig JSON-fil som sendes uendret.

-t og FIL er gjensidig utelukkende; -m og -n er gjensidig utelukkende.

Per-tag config:
  Hver tag i config.sh lagrer MAC, størrelse og rotasjon i ett felt
  ("MAC|size|rotate").  -s og -r overstyrer per-tag-verdier for én
  kjøring.  For å endre en tag permanent, rediger config.sh manuelt
  eller slett og legg til på nytt med -S.

Førstegangs-oppsett (-S eller manglende config):
  Skriptet lagrer AP-IP og en tag (navn + MAC + størrelse + rotasjon)
  i config.sh ved siden av seg selv.  MAC-en står som tekst og
  strekkode bak på taggen (16 hex-tegn, f.eks. 0000032DA56D3E14).
  Senere kjøringer av -S legger til flere tagger.

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
  # Godtar 1-16 hex-tegn.  Tagger trykker ofte kun de siste sifrene
  # (de ledende nullene utelatt); normalize_mac padder dem på etterpå.
  [[ "$1" =~ ^[0-9A-Fa-f]{1,16}$ ]]
}

normalize_mac() {
  # Padder med ledende '0' til 16 tegn, og uppercaser.  Antar input
  # allerede er gyldig (sjekk med is_valid_mac først).
  local m="${1^^}"
  while (( ${#m} < 16 )); do m="0$m"; done
  printf '%s\n' "$m"
}

is_valid_host() {
  [[ "$1" =~ ^[A-Za-z0-9.\-]+$ ]]
}

is_valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

is_valid_size() {
  case "$1" in
    1.54|2.6|2.7|2.9|3.5|4.2|7.5) return 0 ;;
    *) return 1 ;;
  esac
}

is_valid_rotate() {
  [[ "$1" =~ ^[0-3]$ ]]
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

parse_tag_entry() {
  # Setter: $entry_mac, $entry_size, $entry_rotate.
  # Splitter "MAC|size|rotate"; tomme felt blir tomme strenger.
  IFS='|' read -r entry_mac entry_size entry_rotate <<<"$1"
  entry_size="${entry_size:-}"
  entry_rotate="${entry_rotate:-}"
}

write_config() {
  {
    cat <<EOF
# Per-bruker oppsett — generert av $(basename "$0") -S.
# Ikke commit denne filen.  Slett for å trigge nytt oppsett.
#
# Format: [navn]="MAC|size|rotate"
#   MAC     16 hex-tegn
#   size    1.54 | 2.6 | 2.7 | 2.9 | 3.5 | 4.2 | 7.5
#   rotate  0 (native) | 1 (90° CW) | 2 (180°) | 3 (90° CCW)

ap="$ap"

declare -A tags=(
EOF
    local n
    for n in "${!tags[@]}"; do
      printf '  [%s]="%s"\n' "$n" "${tags[$n]}"
    done
    echo ")"
    [[ -n "$default_tag" ]] && echo "default_tag=\"$default_tag\""
  } > "$CONFIG"
}

migrate_legacy_config() {
  # Setter: $tags[min], $default_tag.  Nullstiller: $mac.
  # Gammelt format hadde flat `mac="..."`.  Hvis vi finner én slik MAC
  # uten tags-array, navngis den 'min' og lagres i nytt format.
  [[ -n "${mac:-}" && ${#tags[@]} -eq 0 ]] || return 0
  local legacy="${mac^^}"
  is_valid_mac "$legacy" || return 0
  tags["min"]="${legacy}|${DEFAULT_SIZE}|${DEFAULT_ROTATE}"
  default_tag="min"
  mac=""
  write_config
  echo "→ Oppgradert config.sh: gammel MAC ble navngitt 'min'." >&2
  echo "  Rediger filen hvis du vil endre navnet." >&2
}

migrate_tag_entries() {
  # Eldre tag-entries var bare "MAC".  Legg til |size|rotate-felter med
  # defaults så alle tagger har samme format.
  local changed=0 n entry
  for n in "${!tags[@]}"; do
    entry="${tags[$n]}"
    if [[ "$entry" != *"|"* ]]; then
      tags[$n]="${entry^^}|${DEFAULT_SIZE}|${DEFAULT_ROTATE}"
      changed=1
    fi
  done
  [[ $changed -eq 1 ]] || return 0
  write_config
  echo "→ Oppgradert tag-format: lagt til standard størrelse (${DEFAULT_SIZE}) og rotasjon (${DEFAULT_ROTATE})." >&2
  echo "  Rediger config.sh hvis noen tagger trenger andre verdier." >&2
}

list_tags() {
  local n m s r
  for n in "${!tags[@]}"; do
    parse_tag_entry "${tags[$n]}"
    m="$entry_mac"; s="${entry_size:-?}"; r="${entry_rotate:-?}"
    printf "  %-15s  %s  size=%-4s rotate=%s\n" "$n" "$m" "$s" "$r"
  done | sort
}

run_setup() {
  # Setter: $tags[<navn>], $default_tag (hvis ledig), $ap (ved første gang).
  if [[ ${#tags[@]} -eq 0 ]]; then
    cat >&2 <<'EOF'

-- Førstegangsoppsett av OEPL-tag --
Vi trenger AP-en sin IP-adresse, og en tag (navn + MAC + størrelse + rotasjon).

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

  local name new_mac new_size new_rotate
  name=$(prompt "Navn på tag (f.eks. 'min', 'kollega')" "" is_valid_name)
  new_mac=$(prompt "MAC for $name (kan utelate ledende 0-er)" "" is_valid_mac)
  new_mac=$(normalize_mac "$new_mac")
  new_size=$(prompt "Størrelse" "$DEFAULT_SIZE" is_valid_size)
  new_rotate=$(prompt "Rotasjon (0/1/2/3)" "$DEFAULT_ROTATE" is_valid_rotate)
  tags["$name"]="${new_mac}|${new_size}|${new_rotate}"
  [[ -z "$default_tag" ]] && default_tag="$name"
  write_config
  echo "Lagret: $name = ${new_mac} (size=${new_size}, rotate=${new_rotate})" >&2
}

choose_tag() {
  # Setter: $tag_name, $mac (mac-resolving gjøres i resolve_tag etterpå).
  # Viser numerert liste og leser inn tall *eller* navn.
  local names=()
  mapfile -t names < <(printf '%s\n' "${!tags[@]}" | sort)

  echo "Velg tag:" >&2
  local i=1 n
  for n in "${names[@]}"; do
    parse_tag_entry "${tags[$n]}"
    printf "  %d) %-15s %s  size=%-4s rotate=%s\n" \
      "$i" "$n" "$entry_mac" "${entry_size:-?}" "${entry_rotate:-?}" >&2
    ((i++)) || true
  done

  local default_label=""
  if [[ -n "$default_tag" && -n "${tags[$default_tag]:-}" ]]; then
    default_label="$default_tag"
  elif [[ -n "$default_tag" ]]; then
    echo "  (advarsel: default_tag='$default_tag' i config.sh finnes ikke som tag)" >&2
  fi

  local choice prompt_text="Valg"
  [[ -n "$default_label" ]] && prompt_text="Valg [$default_label]"
  while true; do
    read -r -p "$prompt_text: " choice
    [[ -z "$choice" && -n "$default_label" ]] && choice="$default_label"

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#names[@]} )); then
      tag_name="${names[$((choice-1))]}"
      return 0
    fi
    if [[ -n "${tags[$choice]:-}" ]]; then
      tag_name="$choice"
      return 0
    fi
    echo "  ukjent valg" >&2
  done
}

resolve_tag() {
  # Setter: $mac, $tag_name, $size, $rotate.  Kan kalle die().
  # Precedence: flagg (-m/-s/-r) > per-tag config > script-default.
  [[ -n "$mac" && -n "$tag_name" ]] && die "Bruk enten -m MAC eller -n NAVN, ikke begge"

  if [[ -n "$mac" ]]; then
    is_valid_mac "$mac" || die "MAC '$mac' har ugyldig format (1-16 hex-tegn)"
    mac=$(normalize_mac "$mac")
    # Berik output med navn hvis MAC matcher en kjent tag.
    local n
    for n in "${!tags[@]}"; do
      parse_tag_entry "${tags[$n]}"
      if [[ "$entry_mac" == "$mac" ]]; then
        tag_name="$n"
        break
      fi
    done
  elif [[ -n "$tag_name" ]]; then
    [[ -n "${tags[$tag_name]:-}" ]] || die "Ingen tag med navn '$tag_name' i config.sh"
  elif (( ${#tags[@]} == 1 )); then
    local only=("${!tags[@]}")
    tag_name="${only[0]}"
  else
    choose_tag
  fi

  if [[ -n "$tag_name" ]]; then
    parse_tag_entry "${tags[$tag_name]}"
    [[ -z "$mac" ]] && mac="$entry_mac"
    [[ -z "$size" ]]   && size="$entry_size"
    [[ -z "$rotate" ]] && rotate="$entry_rotate"
  fi

  size="${size:-$DEFAULT_SIZE}"
  rotate="${rotate:-$DEFAULT_ROTATE}"
}

post() {
  # $1 = etikett vi skriver ut (filnavn eller selve JSON-en).
  # $2 = verdien til 'json'-feltet til curl; '@<fil>' eller '=<inline>'.
  local who="${tag_name:+($tag_name) }mac=${mac}"
  echo "→ POST http://${ap}/jsonupload   ${who}  size=${size} rotate=${rotate}"
  echo "$1"
  curl -sS -w '\n' -X POST "http://${ap}/jsonupload" \
    --data-urlencode "mac=${mac}" \
    --data-urlencode "json${2}"
}

parse_args() {
  # Setter: $ap, $mac, $tag_name, $size, $text, $header, $color,
  #         $header_color, $rotate, $do_setup.  Avanserer $OPTIND.
  while getopts ":a:m:n:s:t:H:c:C:r:Sh" opt; do
    case "$opt" in
      a) ap="$OPTARG" ;;
      m) mac="$OPTARG" ;;
      n) tag_name="$OPTARG" ;;
      s) size="$OPTARG" ;;
      t) text="$OPTARG" ;;
      H) header="$OPTARG" ;;
      c) color="$OPTARG" ;;
      C) header_color="$OPTARG" ;;
      r) rotate="$OPTARG" ;;
      S) do_setup=1 ;;
      h) usage; exit 0 ;;
      \?) die "Ukjent flagg: -$OPTARG" ;;
      :)  die "Flagg -$OPTARG krever et argument" ;;
    esac
  done
}

dispatch() {
  # $@ er positional args som er igjen etter flagg-parsing.
  is_valid_mac "$mac"        || die "MAC '$mac' har ikke gyldig format (16 hex-tegn)"
  is_valid_host "$ap"        || die "AP-adresse '$ap' har ikke gyldig format"
  is_valid_size "$size"      || die "Ukjent tag-størrelse: '$size'"
  is_valid_rotate "$rotate"  || die "Ugyldig rotasjon: '$rotate' (forventet 0/1/2/3)"

  [[ -n "$text" && $# -ge 1 ]] && die "Kan ikke kombinere -t og FIL"
  [[ -z "$text" && $# -lt 1 ]] && die "Oppgi enten -t TEKST eller FIL"

  if [[ -z "$text" ]]; then
    local file="$1"
    post "$file" "@${file}"
    return 0
  fi

  local payload
  payload=$(python3 "$RENDER" --size "$size" --header "$header" --text "$text" \
    --color "$color" --header-color "$header_color" --rotate "$rotate")
  post "$payload" "=${payload}"
}

main() {
  [[ -f "$CONFIG" ]] && source "$CONFIG"
  migrate_legacy_config
  migrate_tag_entries

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

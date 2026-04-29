#!/usr/bin/env python3
"""
Bygg OEPL-tegneinstrukser med auto-skalert tekst for en gitt tag-størrelse.

Velger største tilgjengelige font som får toppteksten og hovedteksten til
å passe tagens plass, og bryter på ordgrenser ved behov.  Skriver JSON
til stdout.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import textwrap
from dataclasses import dataclass


MARGIN = 8

# OEPL `text`-kommandoen er [x, y, innhold, font, farge, justering].
COLOR_NORMAL = 1  # svart
COLOR_ACCENT = 2  # rød på BWR-tagger, gul på BWY-tagger
ALIGN_CENTER = 1

COLORS = {
    "black":  COLOR_NORMAL,
    "svart":  COLOR_NORMAL,
    "red":    COLOR_ACCENT,
    "rød":    COLOR_ACCENT,
    "accent": COLOR_ACCENT,
    "1":      COLOR_NORMAL,
    "2":      COLOR_ACCENT,
}


# (fontnavn, pikselhøyde).  Fontene må finnes på AP-en.  Web-UI-ets
# fillisting viser ikke alle — `calibrib40/70/80` og `bahnschrift24`
# er ikke synlige men rendrer (bekreftet ved test).  `bahnschrift50`
# finnes *ikke* — AP-en faller tilbake til en liten default-font hvis
# vi bruker den.
HEADER_FONTS = [
    ("calibrib40",    40),
    ("bahnschrift30", 30),
    ("bahnschrift24", 24),
    ("bahnschrift20", 20),
]

BODY_FONTS = [
    ("calibrib80",    80),
    ("calibrib70",    70),
    ("calibrib40",    40),
    ("calibrib30",    30),
    ("bahnschrift30", 30),
    ("bahnschrift20", 20),
    ("calibrib16",    16),
]

# bahnschrift70.vlw har bare sifre — bokstaver rendres som tomme firkanter
# (bekreftet ved test).  Brukes derfor kun når teksten er rent numerisk.
DIGIT_FONTS = [
    ("bahnschrift70", 70),
]
DIGIT_CHARS = set("0123456789 ")


@dataclass(frozen=True)
class Preset:
    width: int
    height: int
    line_y: int          # y-posisjon for skillelinjen (toppside)
    line_thickness: int  # tykkelse i piksler


# Oppløsninger verifisert mot https://github.com/OpenEPaperLink/OpenEPaperLink/wiki.
# Header sentreres vertikalt i [0, line_y]; body sentreres i [line_y+line_thickness, height].
PRESETS: dict[str, Preset] = {
    "1.54": Preset(152, 152,  28, 1),  # ST-GR16000
    "2.6":  Preset(296, 152,  52, 2),  # M2, oppgitt av bruker
    "2.7":  Preset(264, 176,  54, 2),  # ST-GR27000
    "2.9":  Preset(296, 128,  36, 2),  # ST-GR29000
    "3.5":  Preset(384, 184,  92, 2),  # HS BWY 3.5 (hwType 0x74)
    "4.2":  Preset(400, 300,  62, 2),  # ST-GR42
    "7.5":  Preset(640, 384,  75, 3),  # ST-GR750BN
}


# Python-stil backslash-escapes:  \n \t \r \\ \" \'  og  \xHH / \uHHHH / \UHHHHHHHH.
# Lar brukeren få inn tegn som er vanskelige å sitere i shellen uten å
# korrumpere direkte UTF-8 som står i strengen.
_ESCAPE_RE = re.compile(
    r"\\(n|t|r|\\|\"|\'|0|x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8})"
)
_SIMPLE_ESCAPES = {
    "n": "\n", "t": "\t", "r": "\r",
    "\\": "\\", '"': '"', "'": "'", "0": "\0",
}


def process_escapes(text: str) -> str:
    def replace(match: re.Match) -> str:
        seq = match.group(1)
        if seq in _SIMPLE_ESCAPES:
            return _SIMPLE_ESCAPES[seq]
        return chr(int(seq[1:], 16))  # xHH / uHHHH / UHHHHHHHH
    return _ESCAPE_RE.sub(replace, text)


def char_width(font_name: str, height: int) -> int:
    # bahnschrift er kondensert — smalere tegn per pikselhøyde enn calibri bold.
    ratio = 0.45 if font_name.startswith("bahnschrift") else 0.55
    return max(1, round(height * ratio))


def line_pitch(height: int) -> int:
    return height + max(2, height // 10)


def block_height(num_lines: int, font_h: int) -> int:
    if num_lines <= 0:
        return 0
    if num_lines == 1:
        return font_h
    gap = max(2, font_h // 10)
    return num_lines * font_h + (num_lines - 1) * gap


def wrap_text(text: str, max_chars: int) -> list[str]:
    lines: list[str] = []
    for paragraph in text.split("\n"):
        wrapped = textwrap.wrap(
            paragraph,
            width=max_chars,
            break_long_words=False,
            break_on_hyphens=False,
        )
        lines.extend(wrapped or [""])
    return lines or [""]


def fit(
    text: str,
    max_width: int,
    max_height: int,
    fonts: list[tuple[str, int]],
) -> tuple[str, int, list[str]]:
    for name, height in fonts:
        cw = char_width(name, height)
        lines = wrap_text(text, max(1, max_width // cw))
        too_wide = any(len(line) * cw > max_width for line in lines)
        too_tall = block_height(len(lines), height) > max_height
        if too_wide or too_tall:
            continue
        return name, height, lines

    # Fallback: minste font, godta overflow fremfor å ikke rendere.
    name, height = fonts[-1]
    cw = char_width(name, height)
    return name, height, wrap_text(text, max(1, max_width // cw))


def text_op(x: int, y: int, line: str, font: str, color: int) -> dict:
    return {"text": [x, y, line, f"fonts/{font}", color, ALIGN_CENTER]}


def line_op(preset: Preset) -> dict:
    return {
        "line": [
            MARGIN,
            preset.line_y,
            preset.width - MARGIN,
            preset.line_y,
            preset.line_thickness,
        ]
    }


def body_fonts_for(text: str) -> list[tuple[str, int]]:
    if text and all(c in DIGIT_CHARS for c in text):
        return DIGIT_FONTS + BODY_FONTS
    return BODY_FONTS


def build_payload(preset: Preset, header: str, body: str,
                  header_color: int, body_color: int,
                  rotate: int) -> list[dict]:
    usable_w = preset.width - 2 * MARGIN
    center_x = preset.width // 2

    header_area_h = max(1, preset.line_y)
    h_name, h_size, h_lines = fit(header, usable_w, header_area_h, HEADER_FONTS)
    header_block = block_height(len(h_lines), h_size)
    header_top = max(0, (preset.line_y - header_block) // 2)

    body_area_top = preset.line_y + preset.line_thickness
    body_area_h = max(1, preset.height - body_area_top)
    b_name, b_size, b_lines = fit(body, usable_w, body_area_h, body_fonts_for(body))
    body_block = block_height(len(b_lines), b_size)
    body_top = body_area_top + max(0, (body_area_h - body_block) // 2)

    ops: list[dict] = [{"rotate": rotate}]

    y = header_top
    for line in h_lines:
        ops.append(text_op(center_x, y, line, h_name, header_color))
        y += line_pitch(h_size)

    ops.append(line_op(preset))

    y = body_top
    for line in b_lines:
        ops.append(text_op(center_x, y, line, b_name, body_color))
        y += line_pitch(b_size)

    return ops


def parse_color(value: str) -> int:
    key = value.lower()
    if key not in COLORS:
        choices = ", ".join(sorted(set(COLORS)))
        raise argparse.ArgumentTypeError(f"ukjent farge {value!r}; velg: {choices}")
    return COLORS[key]


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    parser.add_argument("--size", required=True, choices=sorted(PRESETS))
    parser.add_argument("--header", default="STATUS")
    parser.add_argument("--text", required=True)
    parser.add_argument("--color", type=parse_color, default=COLOR_NORMAL,
                        help="farge på hovedtekst (black | red | 1 | 2)")
    parser.add_argument("--header-color", type=parse_color, default=COLOR_NORMAL,
                        help="farge på topptekst (black | red | 1 | 2)")
    parser.add_argument("--rotate", type=int, choices=(0, 1, 2, 3), default=0,
                        help="canvas-rotasjon: 0 (native) | 1 (90° CW) | 2 (180°) | 3 (90° CCW)")
    return parser.parse_args(argv)


def format_payload(ops: list[dict]) -> str:
    # Én op per linje, men arrays inline — gir lesbar diff-vennlig JSON.
    rendered = [json.dumps(op, ensure_ascii=False) for op in ops]
    return "[\n  " + ",\n  ".join(rendered) + "\n]"


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    preset = PRESETS[args.size]
    header = process_escapes(args.header)
    body = process_escapes(args.text)
    payload = build_payload(preset, header, body, args.header_color, args.color, args.rotate)
    print(format_payload(payload))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

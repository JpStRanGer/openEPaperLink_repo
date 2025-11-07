import io
import random
import requests
from typing import Tuple
from PIL import Image, ImageDraw, ImageFont, ImageEnhance

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

TAG_WIDTH = 296
TAG_HEIGHT = 152

ACCESS_POINT_IP = "192.168.1.137"       # OpenEPaperLink access point IP
TARGET_MAC = "0000032EACE03E1B"         # Tag MAC address
USE_DITHER = 0                          # We do our own palette mapping now

OUTPUT_IMAGE_PATH = "test3_output.jpg"       # Temp file to upload

# Font config (bytt font path hvis arial.ttf ikke finnes hos deg)
FONT_PATH = "arial.ttf"
FONT_SIZE_QUOTE = 16
FONT_SIZE_AUTHOR = 12

# Some example quotes
QUOTES = [
    ("Simplicity is the soul of efficiency.", "Austin Freeman"),
    ("If it works, don't touch it.", "Unknown"),
    ("Make it work, make it right, make it fast.", "Kent Beck"),
    ("Perfect is the enemy of done.", "Voltaire"),
    ("It always seems impossible until it's done.", "Nelson Mandela"),
]

# 3-color e-paper palette
EPAPER_WHITE = (255, 255, 255)
EPAPER_BLACK = (0, 0, 0)
EPAPER_RED   = (255, 0, 0)

PALETTE = [EPAPER_WHITE, EPAPER_BLACK, EPAPER_RED]



# -----------------------------------------------------------------------------
# Quote fetcher
# -----------------------------------------------------------------------------

def fetch_random_quote() -> Tuple[str, str]:
    """
    Hent et tilfeldig sitat fra en offentlig "random quote" API.
    Vi bruker Quotable (https://api.quotable.io/random), som gir JSON:
        { "content": "...", "author": "..." }
    API-en er gratis og krever ikke auth-token. :contentReference[oaicite:1]{index=1}

    Returnerer (quote_text, author_name).

    Hvis noe feiler (nett nede, timeout, osv), så velger vi tilfeldig fra LOCAL_QUOTES.
    """
    try:
        resp = requests.get("https://api.quotable.io/random", timeout=5)
        resp.raise_for_status()
        data = resp.json()

        quote_text = data.get("content", "").strip()
        author_name = data.get("author", "").strip() or "Unknown"

        # sanity check - tom streng? fallback
        if not quote_text:
            raise ValueError("Empty quote from API")

        return quote_text, author_name

    except Exception as e :
        # fallback til lokal liste
        print(f"[WARNING] couldt get quote, use locale instead...")
        print(f"Ekseption: {e}")
        return random.choice(QUOTES)


# -----------------------------------------------------------------------------
# Network / image fetch
# -----------------------------------------------------------------------------

def fetch_random_online_background(size: Tuple[int, int]) -> Image.Image:
    """
    Hent et tilfeldig bilde fra picsum.photos i ønsket størrelse.
    Vi booster kontrasten etterpå slik at motivet blir mer tydelig
    på en skjerm som bare har svart/hvit/rød.
    """
    width, height = size
    cache_bust = random.randint(1_000_000, 9_999_999)
    url = f"https://picsum.photos/{width}/{height}?random={cache_bust}"

    print(f"[INFO] Requesting image from: {url} ....")
    try:
        response = requests.get(url, timeout=120)
        response.raise_for_status()

        img = Image.open(io.BytesIO(response.content)).convert("RGB")
    except Exception as e:
        print(F"[ERROR] Faild to get image... - msg: {e}")
        return None


    # Øk kontrast litt så vi får tydelig mørkt/lyst
    enhancer = ImageEnhance.Contrast(img)
    img = enhancer.enhance(1.5)  # tweak faktor 1.0 = original, 1.5 = litt mer punch

    # Lysne litt også, så det ikke bare blir svart klump
    brightness_boost = ImageEnhance.Brightness(img)
    img = brightness_boost.enhance(1.1)

    return img


# -----------------------------------------------------------------------------
# Text helpers
# -----------------------------------------------------------------------------

def wrap_text_to_width(
    draw_ctx: ImageDraw.ImageDraw,
    text: str,
    font: ImageFont.ImageFont,
    max_width_px: int,
) -> list[str]:
    """
    Enkel word-wrap basert på pikselbredde.
    """
    words = text.split()
    lines: list[str] = []
    current_line_words: list[str] = []

    for word in words:
        trial_line = " ".join(current_line_words + [word]).strip()
        w = draw_ctx.textlength(trial_line, font=font)
        if w <= max_width_px or not current_line_words:
            current_line_words.append(word)
        else:
            lines.append(" ".join(current_line_words))
            current_line_words = [word]

    if current_line_words:
        lines.append(" ".join(current_line_words))

    return lines


def draw_quote_panel(
    base_img: Image.Image,
    quote: str,
    author: str,
    panel_box: Tuple[int, int, int, int],
    font_quote: ImageFont.ImageFont,
    font_author: ImageFont.ImageFont,
    padding: int = 8,
    line_spacing: int = 4,
) -> None:
    """
    Tegner et halvtransparant hvitt panel på høyre side med tekst.
    OBS: Panelet blir senere kvantisert til hvit/svart/rød uansett.
    """
    x0, y0, x1, y1 = panel_box
    panel_w = x1 - x0
    panel_h = y1 - y0

    panel = Image.new("RGBA", (panel_w, panel_h), (255, 255, 255, 220))
    draw_panel = ImageDraw.Draw(panel)

    max_text_width = panel_w - 2 * padding
    wrapped_lines = wrap_text_to_width(draw_panel, quote, font_quote, max_text_width)

    current_y = padding

    # Quote (svart tekst)
    for line in wrapped_lines:
        draw_panel.text(
            (padding, current_y),
            line,
            font=font_quote,
            fill=(0, 0, 0),
        )
        line_bbox = font_quote.getbbox(line)
        line_h = line_bbox[3] - line_bbox[1]
        current_y += line_h + line_spacing

    # Litt luft
    current_y += line_spacing

    # Author (rød tekst)
    author_text = f"- {author}"
    draw_panel.text(
        (padding, current_y),
        author_text,
        font=font_author,
        fill=(200, 0, 0),
    )

    # Paste panelet med alpha
    base_img.paste(panel, (x0, y0), mask=panel)


# -----------------------------------------------------------------------------
# Palette conversion for tri-color e-paper
# -----------------------------------------------------------------------------

def closest_palette_color(rgb: Tuple[int, int, int]) -> Tuple[int, int, int]:
    """
    Finn nærmeste farge i vår e-paper-palett (hvit, svart, rød)
    ved å måle kvadratisk avstand i RGB-rommet.
    """
    r, g, b = rgb
    best_color = None
    best_dist = None

    for pr, pg, pb in PALETTE:
        dr = r - pr
        dg = g - pg
        db = b - pb
        dist = dr * dr + dg * dg + db * db
        if best_dist is None or dist < best_dist:
            best_dist = dist
            best_color = (pr, pg, pb)

    return best_color


def quantize_to_epaper_palette(img: Image.Image) -> Image.Image:
    """
    Gå gjennom hver piksel og erstatt den med nærmeste av:
    - hvit (255,255,255)
    - svart (0,0,0)
    - rød   (255,0,0)

    Resultatet blir hardt og 'comic style', men ser MYE bedre ut på
    en tre-farge e-paper enn et grått foto.
    """
    img = img.convert("RGB")
    pixels = img.load()
    w, h = img.size

    for y in range(h):
        for x in range(w):
            pixels[x, y] = closest_palette_color(pixels[x, y])

    return img


# -----------------------------------------------------------------------------
# Final image assembly
# -----------------------------------------------------------------------------

def generate_epaper_image() -> Image.Image:
    """
    Lager sluttbildet (296x152):
    - Venstre halvdel: nettbilde med ekstra kontrast (RGB)
    - Høyre halvdel: sitatpanel (RGBlike)
    - Hele bildet -> konverteres til e-paper 3-farge palett
    """
    base = Image.new("RGB", (TAG_WIDTH, TAG_HEIGHT), (255, 255, 255))

    # Del layout i to halvdeler
    mid_x = TAG_WIDTH // 2  # 148
    left_box = (0, 0, mid_x, TAG_HEIGHT)           # 0..147
    right_box = (mid_x, 0, TAG_WIDTH, TAG_HEIGHT)  # 148..295

    left_w = left_box[2] - left_box[0]
    left_h = left_box[3] - left_box[1]

    # 1. Hent bakgrunn fra nett og lim inn
    bg_img = fetch_random_online_background((left_w, left_h))
    base.paste(bg_img, (left_box[0], left_box[1]))

    # 2. Velg sitat og tegn på høyre side
    quote, author = fetch_random_quote()

    font_quote = ImageFont.truetype(FONT_PATH, size=FONT_SIZE_QUOTE)
    font_author = ImageFont.truetype(FONT_PATH, size=FONT_SIZE_AUTHOR)

    draw_quote_panel(
        base_img=base,
        quote=quote,
        author=author,
        panel_box=right_box,
        font_quote=font_quote,
        font_author=font_author,
        padding=8,
        line_spacing=4,
    )

    # 3. Kvantiser hele bildet til hvit/svart/rød
    epaper_ready = quantize_to_epaper_palette(base)

    return epaper_ready


def save_image_jpeg(img: Image.Image, path: str) -> None:
    """
    Lagre bildet i JPEG. (OpenEPaperLink backend forventer vanlig bildeupload.)
    """
    img.save(path, "JPEG", quality="maximum")


# -----------------------------------------------------------------------------
# Upload
# -----------------------------------------------------------------------------

def upload_to_tag(
    image_path: str,
    ap_ip: str,
    mac: str,
    dither: int,
) -> requests.Response:
    """
    Laster opp bildet til access pointet.
    """
    url = f"http://{ap_ip}/imgupload"
    payload = {"dither": dither, "mac": mac}

    with open(image_path, "rb") as f:
        files = {"file": f}
        response = requests.post(url, data=payload, files=files)

    return response


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

def main() -> None:
    print("[INFO] Generating e-paper image...")
    final_img = generate_epaper_image()

    print(f"[INFO] Saving {OUTPUT_IMAGE_PATH} ...")
    save_image_jpeg(final_img, OUTPUT_IMAGE_PATH)

    print("[INFO] Uploading image to tag...")
    try:
        response = upload_to_tag(
            image_path=OUTPUT_IMAGE_PATH,
            ap_ip=ACCESS_POINT_IP,
            mac=TARGET_MAC,
            dither=USE_DITHER,  # keep 0 because we already quantized
        )
    except Exception as exc:
        print(f"[ERROR] Upload failed: {exc}")
        return

    if response.status_code == 200:
        print("[OK] Image uploaded successfully!")
    else:
        print(f"[ERROR] Upload failed with status {response.status_code}")
        print(f"[ERROR] Body: {response.text}")


if __name__ == "__main__":
    main()

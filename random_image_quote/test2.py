import io
import random
import requests
from typing import Tuple
from PIL import Image, ImageDraw, ImageFont

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

TAG_WIDTH = 296
TAG_HEIGHT = 152

ACCESS_POINT_IP = "192.168.1.137"       # IP address of your OpenEPaperLink access point
TARGET_MAC = "0000032EACE03E1B"         # Destination MAC of the tag
USE_DITHER = 0                          # 1 = let device dither image (photos etc), 0 = no dither

OUTPUT_IMAGE_PATH = "output2.jpg"       # Temp file that will be uploaded

# Font config (bytt til en font du har lokalt hvis 'arial.ttf' ikke finnes)
FONT_PATH = "arial.ttf"
FONT_SIZE_QUOTE = 16
FONT_SIZE_AUTHOR = 12

# Quotes to pick from. Du kan fylle på denne lista selv.
QUOTES = [
    ("Simplicity is the soul of efficiency.", "Austin Freeman"),
    ("If it works, don't touch it.", "Unknown"),
    ("Make it work, make it right, make it fast.", "Kent Beck"),
    ("Perfect is the enemy of done.", "Voltaire"),
    ("It always seems impossible until it's done.", "Nelson Mandela"),
]

# -----------------------------------------------------------------------------
# Image generation helpers
# -----------------------------------------------------------------------------

def fetch_random_online_background(size: Tuple[int, int]) -> Image.Image:
    """
    Hent et tilfeldig bilde fra en offentlig bilde-generator (picsum.photos).
    Vi ber om riktig størrelse direkte, så vi slipper å croppe i etterkant.
    Vi legger på en tilfeldig query-param (?random=XYZ) for å unngå cache
    og få et nytt bilde hver gang.  :contentReference[oaicite:2]{index=2}
    """
    width, height = size

    # tilfeldig tall bare for å få en unik URL (hindrer cache)
    cache_bust = random.randint(1_000_000, 9_999_999)

    url = f"https://picsum.photos/{width}/{height}?random={cache_bust}"
    print(f"[INFO] - getting image from: {url}")
    response = requests.get(url, timeout=10)
    response.raise_for_status()

    # Åpne bildet fra bytes direkte i PIL
    img = Image.open(io.BytesIO(response.content)).convert("RGB")
    # picsum.photos skal allerede ha levert nøyaktig width/height vi ba om
    return img


def wrap_text_to_width(
    draw_ctx: ImageDraw.ImageDraw,
    text: str,
    font: ImageFont.ImageFont,
    max_width_px: int,
) -> list[str]:
    """
    En enkel word-wrapper som bryter teksten slik at hver linje holder seg
    innenfor max_width_px i piksler.
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
    Tegner halvtransparant hvit panel med teksten (sitat + forfatter)
    på høyre del av skjermen. Muterer base_img direkte.
    """
    x0, y0, x1, y1 = panel_box
    panel_w = x1 - x0
    panel_h = y1 - y0

    # Lag selve panelet som RGBA (gjennomsiktig hvit)
    panel = Image.new("RGBA", (panel_w, panel_h), (255, 255, 255, 220))
    draw_panel = ImageDraw.Draw(panel)

    # Word-wrap sitatet
    max_text_width = panel_w - 2 * padding
    wrapped_lines = wrap_text_to_width(draw_panel, quote, font_quote, max_text_width)

    current_y = padding

    # Tegn selve sitatet (svart tekst)
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

    # Litt luft før forfatter
    current_y += line_spacing

    # Tegn forfatter i rødt (for å matche 3-farge e-paper følelse)
    author_text = f"- {author}"
    draw_panel.text(
        (padding, current_y),
        author_text,
        font=font_author,
        fill=(200, 0, 0),
    )

    # Lim RGBA-panelet inn i base_img (RGB) med alpha
    base_img.paste(panel, (x0, y0), mask=panel)


def generate_epaper_image() -> Image.Image:
    """
    Lager sluttbildet vårt på 296x152:
    - Venstre halvdel: tilfeldig bilde fra internett
    - Høyre halvdel: sitatpanel med tekst
    Returnerer et PIL.Image i RGB.
    """
    # Opprett base canvas (helt hvit bakgrunn i tilfelle noe mangler)
    base = Image.new("RGB", (TAG_WIDTH, TAG_HEIGHT), (255, 255, 255))

    # Definer layout: venstre halvdel bilde, høyre halvdel tekst
    mid_x = TAG_WIDTH // 2  # 296//2 = 148
    left_box = (0, 0, mid_x, TAG_HEIGHT)         # (0..147, 0..151)
    right_box = (mid_x, 0, TAG_WIDTH, TAG_HEIGHT)  # (148..295, 0..151)

    left_w = left_box[2] - left_box[0]
    left_h = left_box[3] - left_box[1]

    # Hent random nettbilde i riktig størrelse og lim inn
    bg_img = fetch_random_online_background((left_w, left_h))
    base.paste(bg_img, (left_box[0], left_box[1]))

    # Velg et tilfeldig sitat
    quote, author = random.choice(QUOTES)

    # Last fonter
    font_quote = ImageFont.truetype(FONT_PATH, size=FONT_SIZE_QUOTE)
    font_author = ImageFont.truetype(FONT_PATH, size=FONT_SIZE_AUTHOR)

    # Tegn tekstpanelet
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

    return base


def save_image_jpeg(img: Image.Image, path: str) -> None:
    """
    Lagre bildet som høy-kvalitet JPEG som OpenEPaperLink-backenden kan ta imot.
    """
    img.save(path, "JPEG", quality="maximum")


def upload_to_tag(
    image_path: str,
    ap_ip: str,
    mac: str,
    dither: int,
) -> requests.Response:
    """
    Laster opp bildet til OpenEPaperLink access point.
    Returnerer HTTP-responsen.
    """
    url = f"http://{ap_ip}/imgupload"
    payload = {"dither": dither, "mac": mac}

    with open(image_path, "rb") as f:
        files = {"file": f}
        response = requests.post(url, data=payload, files=files)

    return response


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
            dither=USE_DITHER,
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

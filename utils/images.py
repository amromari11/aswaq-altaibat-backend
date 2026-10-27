"""Turn an uploaded picture into a category image: square, 600 px, WebP.

Pure (Pillow only; no Streamlit, no network) so it can be unit-tested. Everything
that arrives from the dashboard's file picker is untrusted input, so this refuses
anything that isn't a real, reasonably sized JPEG / PNG / WebP, and re-encodes the
rest: the stored file is always a fresh WebP made here, never the original bytes
(which drops EXIF/GPS metadata and any trailing junk as a side effect).
"""

from __future__ import annotations

from dataclasses import dataclass
from io import BytesIO

from PIL import Image, ImageOps, UnidentifiedImageError

MAX_UPLOAD_BYTES = 8 * 1024 * 1024  # what we accept from the browser
MAX_PIXELS = 40_000_000  # ~ a 6300 x 6300 photo; bigger is a decompression-bomb risk
MIN_SIDE = 200  # below this a category card would look blurry
OUTPUT_SIZE = 600  # px, square: sharp on a 3x phone at card size, ~50 KB
ALLOWED_FORMATS = {"JPEG", "PNG", "WEBP"}
CONTENT_TYPE = "image/webp"


class ImageRejected(Exception):
    """The upload can't be used; ``message`` is Arabic text for the admin."""

    def __init__(self, message: str):
        super().__init__(message)
        self.message = message


@dataclass(frozen=True)
class PreparedImage:
    data: bytes
    content_type: str
    size: int  # side length in px (the image is square)


def prepare_category_image(raw: bytes, *, size: int = OUTPUT_SIZE, quality: int = 85) -> PreparedImage:
    """Validate ``raw`` and return a square WebP of at most ``size`` px.

    Centre-crops to a square (never stretches), applies the camera's EXIF
    rotation, flattens transparency onto white, and never upscales past the
    source: a 300 px picture comes out 300 px, not a blurry 600.
    """
    if not raw:
        raise ImageRejected("الملف فارغ.")
    if len(raw) > MAX_UPLOAD_BYTES:
        raise ImageRejected(f"الملف كبير جداً — الحد الأقصى {MAX_UPLOAD_BYTES // (1024 * 1024)} ميغابايت.")

    try:
        image = Image.open(BytesIO(raw))
        image_format = image.format
        image.verify()  # cheap integrity check; invalidates the object, so reopen below
        image = Image.open(BytesIO(raw))
    except (UnidentifiedImageError, OSError, SyntaxError, ValueError):
        raise ImageRejected("هذا الملف ليس صورة صالحة.") from None

    if image_format not in ALLOWED_FORMATS:
        raise ImageRejected("نوع الصورة غير مدعوم — استخدم PNG أو JPG أو WebP.")
    if image.width * image.height > MAX_PIXELS:
        raise ImageRejected("أبعاد الصورة كبيرة جداً — صغّرها ثم أعد المحاولة.")

    try:
        image.seek(0)  # animated WebP/PNG: use the first frame
        image = ImageOps.exif_transpose(image)  # phone photos carry their rotation in EXIF
        image.load()
    except (OSError, SyntaxError, ValueError):
        raise ImageRejected("تعذر قراءة الصورة — الملف تالف.") from None

    if min(image.size) < MIN_SIDE:
        raise ImageRejected(f"الصورة صغيرة جداً — الحد الأدنى {MIN_SIDE}×{MIN_SIDE} بكسل.")

    # Transparency becomes white, not black: a PNG logo on a clear background
    # would otherwise turn into a black square after the WebP/RGB conversion.
    if image.mode in ("RGBA", "LA") or (image.mode == "P" and "transparency" in image.info):
        rgba = image.convert("RGBA")
        flat = Image.new("RGB", rgba.size, (255, 255, 255))
        flat.paste(rgba, mask=rgba.getchannel("A"))
        image = flat
    else:
        image = image.convert("RGB")

    side = min(size, min(image.size))
    image = ImageOps.fit(image, (side, side), method=Image.Resampling.LANCZOS, centering=(0.5, 0.5))

    out = BytesIO()
    image.save(out, format="WEBP", quality=quality, method=4)
    return PreparedImage(data=out.getvalue(), content_type=CONTENT_TYPE, size=side)

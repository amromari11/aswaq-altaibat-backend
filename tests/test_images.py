"""utils.images: validation and re-encoding of uploaded category pictures."""

from __future__ import annotations

from io import BytesIO

import pytest
from PIL import Image

from utils.images import ImageRejected, MAX_UPLOAD_BYTES, prepare_category_image


def encode(image: Image.Image, fmt: str = "PNG", **kw) -> bytes:
    buf = BytesIO()
    image.save(buf, fmt, **kw)
    return buf.getvalue()


def decode(data: bytes) -> Image.Image:
    img = Image.open(BytesIO(data))
    img.load()
    return img


def test_output_is_a_square_600_webp():
    out = prepare_category_image(encode(Image.new("RGB", (1200, 800), (200, 30, 30)), "JPEG"))
    assert out.content_type == "image/webp" and out.size == 600
    img = decode(out.data)
    assert img.format == "WEBP" and img.size == (600, 600)


def test_never_upscales_a_small_source():
    img = decode(prepare_category_image(encode(Image.new("RGB", (300, 300), "blue"))).data)
    assert img.size == (300, 300)


def test_crops_from_the_centre_instead_of_stretching():
    wide = Image.new("RGB", (900, 300), (255, 0, 0))
    wide.paste((0, 0, 255), (300, 0, 600, 300))  # blue middle third
    img = decode(prepare_category_image(encode(wide)).data).convert("RGB")
    assert img.size == (300, 300)
    r, g, b = img.getpixel((150, 150))
    assert b > 200 and r < 60  # the middle survived; the red sides were cropped away


def test_exif_rotation_is_applied():
    src = Image.new("RGB", (400, 300), (255, 0, 0))
    src.paste((0, 0, 255), (0, 0, 400, 150))  # blue top half
    exif = Image.Exif()
    exif[0x0112] = 6  # "rotate 90 CW to display"
    img = decode(prepare_category_image(encode(src, "JPEG", exif=exif)).data).convert("RGB")
    # after rotating, the blue half is on the right
    assert img.getpixel((img.width - 20, img.height // 2))[2] > 180
    assert img.getpixel((20, img.height // 2))[0] > 180


def test_transparency_becomes_white_not_black():
    clear = Image.new("RGBA", (400, 400), (0, 0, 0, 0))
    out = decode(prepare_category_image(encode(clear)).data).convert("RGB")
    assert min(out.getpixel((200, 200))) > 240


def test_palette_png_with_transparency_is_flattened_too():
    pal = Image.new("RGBA", (300, 300), (0, 0, 0, 0)).convert("P")
    pal.info["transparency"] = 0
    out = decode(prepare_category_image(encode(pal, transparency=0)).data).convert("RGB")
    assert min(out.getpixel((10, 10))) > 240


def test_animated_image_uses_first_frame():
    a = Image.new("RGB", (300, 300), (255, 0, 0))
    b = Image.new("RGB", (300, 300), (0, 0, 255))
    out = decode(prepare_category_image(encode(a, "WEBP", save_all=True, append_images=[b])).data).convert("RGB")
    assert out.getpixel((100, 100))[0] > 200


@pytest.mark.parametrize(
    "raw, fragment",
    [
        (b"", "فارغ"),
        (b"not an image at all", "ليس صورة"),
        (b"\x89PNG\r\n\x1a\n" + b"garbage", "ليس صورة"),
    ],
)
def test_garbage_is_rejected_with_an_arabic_message(raw, fragment):
    with pytest.raises(ImageRejected) as e:
        prepare_category_image(raw)
    assert fragment in e.value.message


def test_a_real_image_of_another_format_is_refused():
    with pytest.raises(ImageRejected) as e:
        prepare_category_image(encode(Image.new("RGB", (300, 300)), "GIF"))
    assert "غير مدعوم" in e.value.message


def test_too_big_a_file_is_refused_before_decoding():
    with pytest.raises(ImageRejected) as e:
        prepare_category_image(b"0" * (MAX_UPLOAD_BYTES + 1))
    assert "كبير" in e.value.message


def test_too_many_pixels_is_refused(monkeypatch):
    monkeypatch.setattr("utils.images.MAX_PIXELS", 10_000)
    with pytest.raises(ImageRejected) as e:
        prepare_category_image(encode(Image.new("RGB", (300, 300))))
    assert "كبيرة" in e.value.message


def test_too_small_is_refused():
    with pytest.raises(ImageRejected) as e:
        prepare_category_image(encode(Image.new("RGB", (150, 400))))
    assert "صغيرة" in e.value.message


def test_truncated_file_is_refused():
    full = encode(Image.new("RGB", (800, 800), (10, 200, 10)), "JPEG")
    with pytest.raises(ImageRejected):
        prepare_category_image(full[: len(full) // 2])


def test_metadata_is_not_carried_into_the_output():
    src = Image.new("RGB", (400, 400), "green")
    exif = Image.Exif()
    exif[0x010F] = "SecretCamera"
    out = decode(prepare_category_image(encode(src, "JPEG", exif=exif)).data)
    assert b"SecretCamera" not in out.info.get("exif", b"")

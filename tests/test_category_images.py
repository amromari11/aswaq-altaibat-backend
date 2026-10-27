"""Category images: storage helpers (fake Supabase client) and the admin panel (AppTest)."""

from __future__ import annotations

from io import BytesIO

import pytest
from PIL import Image
from streamlit.testing.v1 import AppTest

import utils.db as db


class FakeBucket:
    def __init__(self, store):
        self.s = store

    def upload(self, path, data, opts):
        if self.s.fail_upload:
            raise RuntimeError("upload failed")
        self.s.log.append(("upload", path, opts["content-type"], opts["x-upsert"]))
        self.s.objects[path] = data

    def get_public_url(self, path):
        return f"https://x.supabase.co/storage/v1/object/public/category-images/{path}?"

    def remove(self, paths):
        if self.s.fail_remove:
            raise RuntimeError("remove failed")
        self.s.log.append(("remove", tuple(paths)))
        for p in paths:
            self.s.objects.pop(p, None)


class FakeTable:
    def __init__(self, store):
        self.s = store

    def update(self, values):
        self.values = values
        return self

    def eq(self, col, val):
        self.where = (col, val)
        return self

    def execute(self):
        if self.s.fail_update:
            raise RuntimeError("update failed")
        self.s.log.append(("update", self.values, self.where))


class FakeStorage:
    def __init__(self, store):
        self.s = store

    def from_(self, name):
        assert name == "category-images"
        return FakeBucket(self.s)


class FakeClient:
    def __init__(self):
        self.objects, self.log = {}, []
        self.fail_upload = self.fail_update = self.fail_remove = False
        self.storage = FakeStorage(self)

    def table(self, name):
        assert name == "categories"
        return FakeTable(self)


@pytest.fixture
def sb(monkeypatch):
    client = FakeClient()
    monkeypatch.setattr(db, "get_supabase", lambda: client)
    monkeypatch.setattr(db.fetch_categories, "clear", lambda: client.log.append(("cache_clear",)), raising=False)
    return client


def kinds(sb):
    return [e[0] for e in sb.log]


def test_upload_goes_new_file_then_row_then_old_file_delete(sb):
    sb.objects["categories/c1/old.webp"] = b"old"
    url = db.upload_category_image("c1", b"NEW", "image/webp", old_path="categories/c1/old.webp")

    assert kinds(sb) == ["upload", "update", "remove", "cache_clear"]
    _, path, ctype, upsert = sb.log[0]
    assert path.startswith("categories/c1/") and path.endswith(".webp") and ctype == "image/webp" and upsert == "false"
    assert url == f"https://x.supabase.co/storage/v1/object/public/category-images/{path}"  # trailing '?' stripped
    assert sb.log[1][1] == {"image_url": url, "image_path": path}
    assert sb.log[1][2] == ("id", "c1")
    assert "categories/c1/old.webp" not in sb.objects and path in sb.objects


def test_every_upload_gets_a_fresh_name(sb):
    db.upload_category_image("c1", b"a", "image/webp")
    db.upload_category_image("c1", b"b", "image/webp")
    paths = [e[1] for e in sb.log if e[0] == "upload"]
    assert len(set(paths)) == 2


def test_failed_upload_changes_nothing(sb):
    sb.fail_upload = True
    with pytest.raises(RuntimeError):
        db.upload_category_image("c1", b"x", "image/webp", old_path="categories/c1/old.webp")
    assert kinds(sb) == []


def test_failed_row_update_removes_the_new_file_and_keeps_the_old_one(sb):
    sb.objects["categories/c1/old.webp"] = b"old"
    sb.fail_update = True
    with pytest.raises(RuntimeError):
        db.upload_category_image("c1", b"x", "image/webp", old_path="categories/c1/old.webp")
    assert list(sb.objects) == ["categories/c1/old.webp"]


def test_failed_cleanup_of_the_old_file_does_not_fail_the_upload(sb):
    sb.fail_remove = True
    url = db.upload_category_image("c1", b"x", "image/webp", old_path="categories/c1/old.webp")
    assert url.startswith("https://")


@pytest.mark.parametrize(
    "url, ok",
    [
        ("https://images.pexels.com/a.jpg", True),
        ("  https://example.com/x.png  ", True),
        ("http://example.com/a.jpg", False),
        ("javascript:alert(1)", False),
        ("https://", False),
        ("", False),
        (None, False),
        ("https://e.com/" + "a" * 2000, False),
    ],
)
def test_link_validation(url, ok):
    assert db.is_valid_image_link(url) is ok


def test_link_replaces_an_upload_and_deletes_its_file(sb):
    db.set_category_image_link("c1", " https://e.com/a.jpg ", old_path="categories/c1/old.webp")
    assert sb.log[0][1] == {"image_url": "https://e.com/a.jpg", "image_path": None}
    assert ("remove", ("categories/c1/old.webp",)) in sb.log


def test_bad_link_is_refused_without_touching_anything(sb):
    with pytest.raises(ValueError):
        db.set_category_image_link("c1", "ftp://e.com/a.jpg")
    assert kinds(sb) == []


def test_remove_clears_both_columns_and_deletes_the_file(sb):
    db.remove_category_image("c1", old_path="categories/c1/old.webp")
    assert sb.log[0][1] == {"image_url": None, "image_path": None}
    assert ("remove", ("categories/c1/old.webp",)) in sb.log


def test_remove_of_a_placeholder_deletes_no_file(sb):
    db.remove_category_image("c1")
    assert "remove" not in kinds(sb)


# --- the panel ---------------------------------------------------------------

SCRIPT = """
from utils.category_image_panel import render_category_image_panel
render_category_image_panel({"id": "c1", "image_url": %r, "image_path": %r})
"""


def png(size=(400, 400)) -> bytes:
    buf = BytesIO()
    Image.new("RGB", size, (30, 160, 60)).save(buf, "PNG")
    return buf.getvalue()


@pytest.fixture
def calls(monkeypatch):
    c = []
    monkeypatch.setattr(db, "upload_category_image", lambda *a: c.append(("upload", a)) or "https://u")
    monkeypatch.setattr(db, "set_category_image_link", lambda *a: c.append(("link", a)))
    monkeypatch.setattr(db, "remove_category_image", lambda *a: c.append(("remove", a)))
    return c


def panel(url="https://p.example/a.jpg", path=None) -> AppTest:
    at = AppTest.from_string(SCRIPT % (url, path), default_timeout=30).run()
    assert not at.exception, [e.value for e in at.exception]
    return at


def test_panel_labels_the_image_source():
    assert any("مؤقتة" in c.value for c in panel().caption)
    assert any("مرفوعة" in c.value for c in panel("https://u", "categories/c1/a.webp").caption)
    assert any("لا توجد صورة" in c.value for c in panel(None, None).caption)


def test_panel_hides_remove_when_there_is_no_image():
    assert not any(b.label == "حذف الصورة" for b in panel(None).button)
    assert any(b.label == "حذف الصورة" for b in panel().button)


def test_remove_passes_the_old_path(calls):
    at = panel("https://u", "categories/c1/a.webp")
    next(b for b in at.button if b.label == "حذف الصورة").click().run()
    assert calls == [("remove", ("c1", "categories/c1/a.webp"))]


def test_valid_link_is_saved(calls):
    at = panel()
    at.text_input(key="cat_img_link_c1").input("https://e.com/x.jpg").run()
    next(b for b in at.button if b.label == "استخدام الرابط").click().run()
    assert calls == [("link", ("c1", "https://e.com/x.jpg", None))]


def test_invalid_link_shows_an_error_and_saves_nothing(calls):
    at = panel()
    at.text_input(key="cat_img_link_c1").input("http://e.com/x.jpg").run()
    next(b for b in at.button if b.label == "استخدام الرابط").click().run()
    assert calls == [] and at.error

"""Banners: target rules, reordering, storage/row ordering (fake client) and the admin page (AppTest)."""

from __future__ import annotations

import pytest
from streamlit.testing.v1 import AppTest

import utils.db as db
from utils.banners import clean_target, move, validate_target

UUID = "123e4567-e89b-12d3-a456-426614174000"


# --- pure rules ---------------------------------------------------------------


@pytest.mark.parametrize(
    "kind, target, ok",
    [
        ("none", None, True),
        ("category", UUID, True),
        ("category", UUID.upper(), True),
        ("category", "", False),
        ("category", None, False),
        ("category", "dairy", False),
        ("product", UUID, True),
        ("product", "nope", False),
        ("link", "https://example.com/offer?x=1", True),
        ("link", "http://example.com", False),
        ("link", "javascript:alert(1)", False),
        ("link", "https://", False),
        ("link", "https://a.com/x y", False),
        ("link", "https://e.com/" + "a" * 2000, False),
        ("popup", None, False),
    ],
)
def test_target_validation_mirrors_the_table_constraint(kind, target, ok):
    assert (validate_target(kind, target) is None) is ok


def test_clean_target():
    assert clean_target("none", "https://x") is None
    assert clean_target("link", "  https://x.com ") == "https://x.com"


def test_move_renumbers_everything_so_ties_cannot_block_a_move():
    assert move(["a", "b", "c"], "b", -1) == [("b", 1), ("a", 2), ("c", 3)]
    assert move(["a", "b", "c"], "b", +1) == [("a", 1), ("c", 2), ("b", 3)]


def test_move_past_either_end_does_nothing():
    assert move(["a", "b"], "a", -1) == []
    assert move(["a", "b"], "b", +1) == []


# --- save_banner with a fake Supabase ------------------------------------------


class FakeTable:
    def __init__(self, s):
        self.s = s

    def insert(self, values):
        self.op, self.values = "insert", values
        return self

    def update(self, values):
        self.op, self.values = "update", values
        return self

    def delete(self):
        self.op, self.values = "delete", None
        return self

    def eq(self, col, val):
        self.where = (col, val)
        return self

    def execute(self):
        if self.s.fail_row:
            raise RuntimeError("row failed")
        self.s.log.append((self.op, self.values, getattr(self, "where", None)))


class FakeBucket:
    def __init__(self, s):
        self.s = s

    def upload(self, path, data, opts):
        if self.s.fail_upload:
            raise RuntimeError("upload failed")
        self.s.log.append(("upload", path, opts["content-type"]))
        self.s.objects[path] = data

    def get_public_url(self, path):
        return f"https://x.supabase.co/storage/v1/object/public/banner-images/{path}?"

    def remove(self, paths):
        self.s.log.append(("remove", tuple(paths)))
        for p in paths:
            self.s.objects.pop(p, None)


class FakeClient:
    def __init__(self):
        self.objects, self.log = {}, []
        self.fail_row = self.fail_upload = False

    def table(self, name):
        assert name == "banners"
        return FakeTable(self)

    @property
    def storage(self):
        outer = self

        class _S:
            def from_(self, name):
                assert name == "banner-images"
                return FakeBucket(outer)

        return _S()


@pytest.fixture
def sb(monkeypatch):
    client = FakeClient()
    monkeypatch.setattr(db, "get_supabase", lambda: client)
    monkeypatch.setattr(db.fetch_banners, "clear", lambda: client.log.append(("cache_clear",)), raising=False)
    return client


def kinds(sb):
    return [e[0] for e in sb.log]


def test_new_banner_uploads_then_inserts_with_the_public_url(sb):
    db.save_banner(None, {"title": "t", "target_type": "none", "target_id": None}, image=b"WEBP")
    assert kinds(sb) == ["upload", "insert", "cache_clear"]
    path = sb.log[0][1]
    row = sb.log[1][1]
    assert path.startswith("banners/") and path.endswith(".webp") and sb.log[0][2] == "image/webp"
    assert row["image_path"] == path and row["image_url"].endswith(path)  # trailing "?" stripped


def test_replacing_the_image_deletes_the_old_file_only_after_the_row_is_saved(sb):
    sb.objects["banners/old.webp"] = b"old"
    db.save_banner("b1", {"title": "t"}, image=b"NEW", old_path="banners/old.webp")
    assert kinds(sb) == ["upload", "update", "remove", "cache_clear"]
    assert "banners/old.webp" not in sb.objects


def test_editing_without_a_new_image_touches_no_files(sb):
    db.save_banner("b1", {"title": "t"}, old_path="banners/old.webp")
    assert kinds(sb) == ["update", "cache_clear"]


def test_failed_row_save_removes_the_new_upload_and_keeps_the_old_one(sb):
    sb.objects["banners/old.webp"] = b"old"
    sb.fail_row = True
    with pytest.raises(RuntimeError):
        db.save_banner("b1", {"title": "t"}, image=b"NEW", old_path="banners/old.webp")
    assert list(sb.objects) == ["banners/old.webp"]


def test_failed_upload_saves_nothing(sb):
    sb.fail_upload = True
    with pytest.raises(RuntimeError):
        db.save_banner(None, {"title": "t"}, image=b"x")
    assert kinds(sb) == []


def test_delete_removes_the_row_then_its_file(sb):
    db.delete_banner("b1", "banners/a.webp")
    assert kinds(sb) == ["delete", "remove", "cache_clear"]


def test_product_search_ignores_one_letter_and_strips_filter_syntax():
    assert db.search_products("a") == []
    assert db.search_products("   ") == []


# --- the page -------------------------------------------------------------------

SCRIPT = "from utils.banner_admin import render_banners_page\nrender_banners_page()\n"
CATS = [
    {"id": UUID, "name_ar": "ألبان", "name": "Dairy", "is_active": True},
    {"id": "223e4567-e89b-12d3-a456-426614174000", "name_ar": "قديم", "name": "Old", "is_active": False},
]


def banner(i, **kw):
    return {"id": f"b{i}", "title": f"عنوان {i}", "image_url": f"https://img/{i}.webp", "image_path": f"banners/{i}.webp",
            "target_type": "none", "target_id": None, "is_active": True, "display_order": i, "created_at": "2026-10-27", **kw}


@pytest.fixture
def page(monkeypatch):
    state = {"banners": [banner(1), banner(2, is_active=False, target_type="category", target_id=UUID), banner(3)], "calls": []}
    monkeypatch.setattr(db, "fetch_banners", lambda: state["banners"])
    monkeypatch.setattr(db, "fetch_categories", lambda: CATS)
    monkeypatch.setattr(db, "set_banner_orders", lambda o: state["calls"].append(("orders", o)))
    monkeypatch.setattr(db, "set_banner_active", lambda i, a: state["calls"].append(("active", i, a)))
    monkeypatch.setattr(db, "delete_banner", lambda i, p: state["calls"].append(("delete", i, p)))
    monkeypatch.setattr(db, "save_banner", lambda *a: state["calls"].append(("save", a)))
    return state


def run():
    at = AppTest.from_string(SCRIPT, default_timeout=30).run()
    assert not at.exception, [e.value for e in at.exception]
    return at


def test_lists_every_banner_with_where_it_leads(page):
    at = run()
    text = " ".join(m.value for m in at.markdown) + " ".join(c.value for c in at.caption)
    assert "عنوان 1" in text and "عنوان 3" in text
    assert "قسم: ألبان" in text and "مخفي" in text


def test_first_cannot_move_up_and_last_cannot_move_down(page):
    at = run()
    assert at.button(key="banner_up_b1").disabled and not at.button(key="banner_up_b2").disabled
    assert at.button(key="banner_down_b3").disabled and not at.button(key="banner_down_b2").disabled


def test_move_up_renumbers_all(page):
    at = run()
    at.button(key="banner_up_b2").click().run()
    assert page["calls"] == [("orders", [("b2", 1), ("b1", 2), ("b3", 3)])]


def test_toggle_flips_visibility(page):
    at = run()
    at.button(key="banner_toggle_b1").click().run()
    at.button(key="banner_toggle_b2").click().run()
    assert page["calls"] == [("active", "b1", False), ("active", "b2", True)]


def test_delete_asks_first_and_can_be_cancelled(page):
    at = run()
    at.button(key="banner_delete_b1").click().run()
    assert page["calls"] == [] and any("نهائياً" in w.value for w in at.warning)
    at.button(key="banner_delete_no_b1").click().run()
    assert page["calls"] == [] and not at.warning


def test_confirmed_delete_passes_the_image_path(page):
    at = run()
    at.button(key="banner_delete_b3").click().run()
    at.button(key="banner_delete_yes_b3").click().run()
    assert page["calls"] == [("delete", "b3", "banners/3.webp")]


def test_empty_state_opens_the_add_form(page):
    page["banners"] = []
    at = run()
    assert any("لا توجد بانرات" in i.value for i in at.info)


def test_adding_without_an_image_is_refused(page):
    at = run()
    at.button(key="banner_new_save").click().run()
    assert page["calls"] == [] and any("صورة" in e.value for e in at.error)


def test_editing_a_link_banner_with_a_bad_link_is_refused(page):
    at = run()
    at.selectbox(key="banner_b1_type").select("link").run()
    at.text_input(key="banner_b1_link").input("http://insecure.example").run()
    at.button(key="banner_b1_save").click().run()
    assert page["calls"] == [] and any("https" in e.value for e in at.error)


def test_editing_saves_without_touching_the_image(page):
    at = run()
    at.text_input(key="banner_b1_title").input("جديد").run()
    at.selectbox(key="banner_b1_type").select("category").run()
    at.button(key="banner_b1_save").click().run()
    (kind, args), = page["calls"]
    assert kind == "save"
    banner_id, fields, image, old_path = args
    assert banner_id == "b1" and image is None and old_path == "banners/1.webp"
    assert fields == {"title": "جديد", "target_type": "category", "target_id": UUID, "is_active": True}


# --- uploads through the page ---------------------------------------------------


def _jpeg(size=(1600, 900)):
    from io import BytesIO

    from PIL import Image

    buf = BytesIO()
    Image.new("RGB", size, (20, 140, 60)).save(buf, "JPEG")
    return buf.getvalue()


def test_adding_a_banner_with_an_image_saves_a_wide_webp_at_the_end_of_the_list(page):
    from io import BytesIO

    from PIL import Image

    at = run()
    at.file_uploader(key="banner_new_upload_0").upload("promo.jpg", _jpeg(), "image/jpeg").run()
    assert not at.exception and not at.error
    at.text_input(key="banner_new_title").input("عرض").run()
    at.button(key="banner_new_save").click().run()
    (kind, args), = page["calls"]
    banner_id, fields, image, old_path = args
    assert banner_id is None and old_path is None
    assert fields == {"title": "عرض", "target_type": "none", "target_id": None, "is_active": True, "display_order": 4}
    img = Image.open(BytesIO(image))
    assert img.format == "WEBP" and img.size == (1200, 520)


def test_a_non_image_upload_is_explained_and_nothing_is_saved(page):
    at = run()
    at.file_uploader(key="banner_new_upload_0").upload("x.png", b"not an image", "image/png").run()
    assert any("ليس صورة" in e.value for e in at.error)
    at.button(key="banner_new_save").click().run()
    assert page["calls"] == []


def test_a_tiny_picture_is_refused(page):
    at = run()
    at.file_uploader(key="banner_new_upload_0").upload("s.jpg", _jpeg((300, 200)), "image/jpeg").run()
    assert any("صغيرة" in e.value for e in at.error)

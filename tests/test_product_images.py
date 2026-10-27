"""Product pictures: bulk matching rules, storage helpers (fake client) and the admin page (AppTest)."""

from __future__ import annotations

from io import BytesIO

import pytest
from PIL import Image
from streamlit.testing.v1 import AppTest

import utils.db as db
from utils.product_images import plan_uploads, sku_from_filename

# --- matching files to products ---------------------------------------------------


@pytest.mark.parametrize(
    "name, sku",
    [("6281001234567.jpg", "6281001234567"), ("  123 .PNG", "123"), ("a.b.webp", "a.b"), ("noext", "noext"), ("", "")],
)
def test_sku_is_the_file_name_without_extension(name, sku):
    assert sku_from_filename(name) == sku


def _p(sku, image=None):
    return {"id": f"id-{sku}", "sku": sku, "image_url": image}


def test_plan_covers_every_case():
    products = {"111": _p("111"), "222": _p("222", "https://old/x.webp")}
    rows = plan_uploads(["111.jpg", "222.jpg", "999.jpg", "111.png"], products, replace_existing=False)
    assert [(r.filename, r.status) for r in rows] == [
        ("111.jpg", "save"),
        ("222.jpg", "skip_has_image"),
        ("999.jpg", "unknown_sku"),
        ("111.png", "duplicate"),
    ]
    assert [r.will_save for r in rows] == [True, False, False, False]
    assert rows[2].product is None and rows[0].product["id"] == "id-111"


def test_replace_existing_overwrites_only_when_asked():
    products = {"222": _p("222", "https://old/x.webp")}
    (row,) = plan_uploads(["222.jpg"], products, replace_existing=True)
    assert row.status == "replace" and row.will_save


def test_first_file_for_a_sku_wins_even_if_it_is_skipped():
    products = {"222": _p("222", "https://old/x.webp")}
    rows = plan_uploads(["222.jpg", "222.png"], products, replace_existing=False)
    assert [r.status for r in rows] == ["skip_has_image", "duplicate"]


# --- storage helpers with a fake Supabase ------------------------------------------


class FakeTable:
    def __init__(self, s):
        self.s = s
        self.filters = []

    def select(self, *a, **k):
        self.op = "select"
        return self

    def update(self, values):
        self.op, self.values = "update", values
        return self

    def eq(self, col, val):
        self.where = (col, val)
        return self

    def in_(self, col, vals):
        self.filters.append(("in", col, list(vals)))
        return self

    def or_(self, expr):
        self.filters.append(("or", expr))
        return self

    def order(self, *a, **k):
        return self

    def limit(self, n):
        self.filters.append(("limit", n))
        return self

    @property
    def not_(self):
        return self

    def is_(self, col, val):
        self.filters.append(("not_is", col, val))
        return self

    def execute(self):
        if self.s.fail_row:
            raise RuntimeError("row failed")
        self.s.log.append((self.table_name, self.op, getattr(self, "values", None), getattr(self, "where", None), self.filters))

        class R:
            data = [{"id": "x"}]
            count = 7

        return R()


class FakeBucket:
    def __init__(self, s, name):
        self.s, self.name = s, name

    def upload(self, path, data, opts):
        self.s.log.append(("upload", self.name, path, opts["content-type"], opts["x-upsert"]))

    def get_public_url(self, path):
        return f"https://x.supabase.co/storage/v1/object/public/{self.name}/{path}?"

    def remove(self, paths):
        self.s.log.append(("remove", self.name, tuple(paths)))


class FakeClient:
    def __init__(self):
        self.log, self.fail_row = [], False

    def table(self, name):
        t = FakeTable(self)
        t.table_name = name
        return t

    @property
    def storage(self):
        outer = self

        class _S:
            def from_(self, name):
                return FakeBucket(outer, name)

        return _S()


@pytest.fixture
def sb(monkeypatch):
    client = FakeClient()
    monkeypatch.setattr(db, "get_supabase", lambda: client)
    for fn in (db.fetch_products, db.count_products_with_image, db.fetch_categories):
        monkeypatch.setattr(fn, "clear", lambda: client.log.append(("cache_clear",)), raising=False)
    return client


def kinds(sb):
    return [e[0] for e in sb.log if e[0] != "cache_clear"]


def test_upload_uses_the_products_bucket_and_replaces_the_old_file_last(sb):
    url = db.upload_product_image("p1", b"WEBP", "image/webp", old_path="products/p1/old.webp")
    assert kinds(sb) == ["upload", "products", "remove"]
    _, bucket, path, ctype, upsert = sb.log[0]
    assert bucket == "product-images" and path.startswith("products/p1/") and path.endswith(".webp")
    assert (ctype, upsert) == ("image/webp", "false")
    assert url == f"https://x.supabase.co/storage/v1/object/public/product-images/{path}"
    assert sb.log[1][2] == {"image_url": url, "image_path": path} and sb.log[1][3] == ("id", "p1")
    assert sb.log[2] == ("remove", "product-images", ("products/p1/old.webp",))


def test_failed_row_update_removes_the_new_file(sb):
    sb.fail_row = True
    with pytest.raises(RuntimeError):
        db.upload_product_image("p1", b"x", "image/webp", old_path="products/p1/old.webp")
    removed = [e for e in sb.log if e[0] == "remove"]
    assert len(removed) == 1 and removed[0][2][0].startswith("products/p1/") and "old" not in removed[0][2][0]


def test_link_and_remove_clear_the_path_and_delete_the_old_file(sb):
    db.set_product_image_link("p1", " https://e.com/a.jpg ", old_path="products/p1/old.webp")
    assert sb.log[0][2] == {"image_url": "https://e.com/a.jpg", "image_path": None}
    assert ("remove", "product-images", ("products/p1/old.webp",)) in sb.log
    sb.log.clear()
    db.remove_product_image("p1", "products/p1/o2.webp")
    assert sb.log[0][2] == {"image_url": None, "image_path": None}
    with pytest.raises(ValueError):
        db.set_product_image_link("p1", "http://insecure/x.jpg")


def test_search_term_is_cleaned_and_short_terms_never_query(sb):
    assert db.find_products("a") == [] and db.find_products("  ") == [] and sb.log == []
    db.find_products("حليب, (x)%")
    (entry,) = [e for e in sb.log if e[0] == "products"]
    expr = next(f[1] for f in entry[4] if f[0] == "or")
    assert "," not in expr.split("ilike.%", 1)[1].split("%", 1)[0] and "(" not in expr and ")" not in expr
    assert "sku.ilike" in expr and "name_ar.ilike" in expr


def test_lookups_are_chunked(sb):
    db.fetch_products_by_skus([str(i) for i in range(250)])
    ins = [f for e in sb.log for f in e[4] if f[0] == "in"]
    assert [len(f[2]) for f in ins] == [100, 100, 50]


def test_count_with_image_asks_for_non_null_urls(sb):
    assert db.count_products_with_image() == 7
    assert ("not_is", "image_url", "null") in sb.log[0][4]


# --- the page -------------------------------------------------------------------

SCRIPT = "from utils.product_image_admin import render_product_images_page\nrender_product_images_page()\n"


def jpeg(size=(800, 600)):
    buf = BytesIO()
    Image.new("RGB", size, (200, 60, 60)).save(buf, "JPEG")
    return buf.getvalue()


MILK = {"id": "m1", "name": "Milk", "name_ar": "حليب", "sku": "111", "image_url": None, "image_path": None, "category_id": "c1"}
CHEESE = {"id": "c1p", "name": "Cheese", "name_ar": "جبنة", "sku": "222", "image_url": "https://old/x.webp", "image_path": "products/c1p/o.webp", "category_id": "c1"}


@pytest.fixture
def page(monkeypatch):
    state = {"calls": [], "top": [], "found": [MILK, CHEESE]}
    monkeypatch.setattr(db, "count_products", lambda **k: 1000)
    monkeypatch.setattr(db, "count_products_with_image", lambda: 250)
    monkeypatch.setattr(db, "fetch_top_products", lambda s, e, n=20: state["top"])
    monkeypatch.setattr(db, "fetch_products_by_ids", lambda ids: [p for p in (MILK, CHEESE) if p["id"] in ids])
    monkeypatch.setattr(db, "fetch_products_by_skus", lambda skus: [p for p in (MILK, CHEESE) if p["sku"] in skus])
    monkeypatch.setattr(db, "find_products", lambda term, limit=30: state["found"])
    monkeypatch.setattr(db, "upload_product_image", lambda *a: state["calls"].append(("upload", a)) or "https://u")
    monkeypatch.setattr(db, "set_product_image_link", lambda *a: state["calls"].append(("link", a)))
    monkeypatch.setattr(db, "remove_product_image", lambda *a: state["calls"].append(("remove", a)))
    return state


def run():
    at = AppTest.from_string(SCRIPT, default_timeout=30).run()
    assert not at.exception, [e.value for e in at.exception]
    return at


def test_shows_how_many_products_have_pictures(page):
    at = run()
    values = {m.label: m.value for m in at.metric}
    assert values["المنتجات"] == "1,000" and values["لها صورة"] == "250" and values["بلا صورة"] == "750"


def test_top_sellers_lists_only_those_without_a_picture(page):
    page["top"] = [
        {"product_id": "m1", "units_sold": 40, "orders_count": 9},
        {"product_id": "c1p", "units_sold": 30, "orders_count": 7},
    ]
    at = run()
    assert any("1 من أصل 2" in c.value for c in at.caption)
    assert any("حليب" in str(d.value) for d in at.dataframe) and not any("جبنة" in str(d.value) for d in at.dataframe)


def test_all_top_sellers_covered_says_so(page):
    page["top"] = [{"product_id": "c1p", "units_sold": 30, "orders_count": 7}]
    assert any("كل المنتجات الأكثر مبيعاً" in s.value for s in run().success)


def test_no_sales_points_to_search(page):
    assert any("لا توجد مبيعات" in i.value for i in run().info)


def test_search_then_upload_saves_a_white_square_with_the_old_path(page):
    at = run()
    at.text_input(key="pimg_search").input("جبنة").run()
    at.selectbox(key="pimg_search_res_pick").select("c1p").run()
    at.file_uploader(key="pimg_search_res_c1p_upload_0").upload("cheese.jpg", jpeg(), "image/jpeg").run()
    assert not at.exception and not at.error
    at.button(key="pimg_search_res_c1p_save").click().run()
    (kind, args), = page["calls"]
    product_id, data, ctype, old_path = args
    assert (kind, product_id, ctype, old_path) == ("upload", "c1p", "image/webp", "products/c1p/o.webp")
    img = Image.open(BytesIO(data))
    assert img.format == "WEBP" and img.size == (600, 600)


def test_search_needs_two_characters(page):
    at = run()
    at.text_input(key="pimg_search").input("ح").run()
    assert any("حرفين" in c.value for c in at.caption)


def test_bad_link_is_refused_and_remove_passes_the_path(page):
    at = run()
    at.text_input(key="pimg_search").input("جبنة").run()
    at.selectbox(key="pimg_search_res_pick").select("c1p").run()
    at.text_input(key="pimg_search_res_c1p_link").input("http://x.example/a.jpg").run()
    at.button(key="pimg_search_res_c1p_use_link").click().run()
    assert page["calls"] == [] and any("https" in e.value for e in at.error)
    at.button(key="pimg_search_res_c1p_remove").click().run()
    assert page["calls"] == [("remove", ("c1p", "products/c1p/o.webp"))]


def test_a_non_image_is_explained(page):
    at = run()
    at.text_input(key="pimg_search").input("حليب").run()
    at.selectbox(key="pimg_search_res_pick").select("m1").run()
    at.file_uploader(key="pimg_search_res_m1_upload_0").upload("x.png", b"not an image", "image/png").run()
    assert any("ليس صورة" in e.value for e in at.error)
    assert not any(b.key == "pimg_search_res_m1_save" for b in at.button)


def test_bulk_saves_a_picture_named_after_the_sku(page):
    at = run()
    at.file_uploader(key="pimg_bulk_upload_0").upload("111.jpg", jpeg(), "image/jpeg").run()
    assert not at.exception and any("111.jpg" in str(d.value) for d in at.dataframe)
    at.button(key="pimg_bulk_save").click().run()
    (kind, args), = page["calls"]
    assert (kind, args[0], args[2]) == ("upload", "m1", "image/webp")


def test_bulk_leaves_a_product_that_already_has_a_picture(page):
    at = run()
    at.file_uploader(key="pimg_bulk_upload_0").upload("222.jpg", jpeg(), "image/jpeg").run()
    assert any("للمنتج صورة بالفعل" in str(d.value) for d in at.dataframe)
    assert not any(b.key == "pimg_bulk_save" for b in at.button)


def test_bulk_replace_checkbox_overwrites_it_with_the_old_path(page):
    at = run()
    at.checkbox(key="pimg_bulk_replace").check().run()
    at.file_uploader(key="pimg_bulk_upload_0").upload("222.jpg", jpeg(), "image/jpeg").run()
    at.button(key="pimg_bulk_save").click().run()
    (kind, args), = page["calls"]
    assert (kind, args[0], args[3]) == ("upload", "c1p", "products/c1p/o.webp")


def test_bulk_unknown_sku_and_bad_file_do_not_stop_the_batch(page, monkeypatch):
    at = run()
    at.file_uploader(key="pimg_bulk_upload_0").upload("999.jpg", jpeg(), "image/jpeg").run()
    assert any("لا يوجد منتج بهذا الرمز" in str(d.value) for d in at.dataframe)
    assert not any(b.key == "pimg_bulk_save" for b in at.button)
    at = run()
    at.file_uploader(key="pimg_bulk_upload_0").upload("111.png", b"not an image", "image/png").run()
    at.button(key="pimg_bulk_save").click().run()
    assert page["calls"] == [] and any("ليس صورة" in e.value for e in at.error)

"""fetch_products must name the products -> categories foreign key: since 012 the
table also points at categories through legacy_category_id, and PostgREST rejects
a bare categories(...) embed as ambiguous (PGRST201)."""
from utils import db


def test_fetch_products_names_the_category_foreign_key(monkeypatch):
    seen = []

    class Q:
        def __init__(self, cols):
            self.cols = cols

        def order(self, *args, **kwargs):
            return self

        def execute(self):
            seen.append(self.cols)

            class R:
                data = [{"id": "p1", "categories": {"name": "Dairy", "name_ar": "ألبان"}}]

            return R()

    class T:
        def select(self, cols):
            return Q(cols)

    class C:
        def table(self, name):
            assert name == "products"
            return T()

    monkeypatch.setattr(db, "get_supabase", lambda: C())
    fetch = getattr(db.fetch_products, "__wrapped__", db.fetch_products)
    rows = fetch()

    assert rows[0]["categories"]["name_ar"] == "ألبان"
    assert "categories!products_category_id_fkey(name, name_ar)" in seen[0]
    assert "categories(" not in seen[0]

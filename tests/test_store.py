import pytest

from utils.store import STORE_LAT, STORE_LNG, distance_m, step_toward

STORE = (STORE_LAT, STORE_LNG)

# Test points are defined relative to the store so the tests keep their meaning
# wherever the shop actually is.
# Rounded to 6 decimals like real customer pins (that is all the database keeps), so
# float noise like 36.028400000000005 can't masquerade as a missed arrival.
FAR = (round(STORE_LAT + 0.1, 6), round(STORE_LNG + 0.1, 6))  # ~15 km away


def test_distance_zero_for_the_same_point():
    assert distance_m(STORE, STORE) == pytest.approx(0, abs=1e-6)


def test_distance_matches_a_known_length():
    # One degree of latitude is ~111.2 km.
    assert distance_m((32.0, 36.0), (33.0, 36.0)) == pytest.approx(111_195, rel=0.002)


def test_distance_is_symmetric():
    a, b = (32.07, 36.09), (32.10, 36.20)
    assert distance_m(a, b) == pytest.approx(distance_m(b, a))


def test_a_step_moves_a_fraction_of_the_way():
    dest = FAR
    lat, lng = step_toward(STORE, dest, fraction=0.2)
    assert lat == pytest.approx(STORE_LAT + 0.02, abs=1e-6)
    assert lng == pytest.approx(STORE_LNG + 0.02, abs=1e-6)
    assert distance_m((lat, lng), dest) < distance_m(STORE, dest)


def test_repeated_steps_converge_on_the_destination_and_stop():
    dest = FAR
    point, history = STORE, []
    for _ in range(60):
        nxt = step_toward(point, dest)
        history.append(distance_m(nxt, dest))
        if nxt == point:
            break
        point = nxt
    assert point == dest, "must land exactly on the customer, not creep forever"
    assert history == sorted(history, reverse=True), "every step gets closer"


def test_close_enough_snaps_to_the_destination():
    dest = FAR
    near = (dest[0] + 0.00001, dest[1] + 0.00001)  # a metre or so away
    assert step_toward(near, dest) == dest


def test_a_step_that_would_land_very_close_snaps():
    dest = (round(STORE_LAT + 0.0001, 6), round(STORE_LNG + 0.0001, 6))  # ~15 m from the store
    assert 5 < distance_m(STORE, dest) < 40
    assert step_toward(STORE, dest, fraction=0.5) == dest


def test_results_are_rounded_to_the_six_decimals_the_database_keeps():
    lat, lng = step_toward((32.0, 36.0), (33.0, 37.0), fraction=1 / 3)
    assert lat == round(lat, 6) and lng == round(lng, 6)


@pytest.mark.parametrize("fraction", [0, -0.1, 1.5])
def test_a_nonsense_fraction_is_rejected(fraction):
    with pytest.raises(ValueError):
        step_toward(STORE, (33.0, 37.0), fraction=fraction)

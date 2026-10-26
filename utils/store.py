"""The store's location, and the little geometry the driver panel needs.

Pure Python (no Streamlit, no database) so it can be unit-tested.
"""

from __future__ import annotations

from math import asin, cos, radians, sin, sqrt

# The shop's location, from its Plus Code `33FW+84 Zarqa` (= 8G4R33FW+84),
# decoded to the centre of its ~14 m cell. Keep AppConfig.storeLatitude /
# storeLongitude in the Flutter app (lib/core/config/app_config.dart) in step:
# they are the "store" pin on the customer's tracking map and the start of the
# route.
STORE_LAT = 32.073313
STORE_LNG = 36.095312

EARTH_RADIUS_M = 6_371_000.0

LatLng = tuple[float, float]


def distance_m(a: LatLng, b: LatLng) -> float:
    """Great-circle distance in metres between two (lat, lng) points."""
    lat1, lng1, lat2, lng2 = map(radians, (a[0], a[1], b[0], b[1]))
    h = sin((lat2 - lat1) / 2) ** 2 + cos(lat1) * cos(lat2) * sin((lng2 - lng1) / 2) ** 2
    return 2 * EARTH_RADIUS_M * asin(sqrt(h))


def step_toward(current: LatLng, destination: LatLng, fraction: float = 0.2, arrive_within_m: float = 40.0) -> LatLng:
    """The next point when moving ``fraction`` of the remaining way from
    ``current`` to ``destination`` (a simulated drive for testing live tracking).

    Snaps to the destination once within ``arrive_within_m`` metres, or when the
    step would land that close — so repeated clicks converge and finish instead
    of creeping forever. Rounded to 6 decimals, the precision the database keeps.
    """
    if not 0 < fraction <= 1:
        raise ValueError("fraction must be in (0, 1]")
    if distance_m(current, destination) <= arrive_within_m:
        return (round(destination[0], 6), round(destination[1], 6))
    nxt = (
        current[0] + (destination[0] - current[0]) * fraction,
        current[1] + (destination[1] - current[1]) * fraction,
    )
    if distance_m(nxt, destination) <= arrive_within_m:
        return (round(destination[0], 6), round(destination[1], 6))
    return (round(nxt[0], 6), round(nxt[1], 6))

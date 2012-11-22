from numpy.testing import assert_array_almost_equal
import kwant
from math import pi, cos

def test_band_energies(N=5):
    sys = kwant.Builder(kwant.TranslationalSymmetry((-1, 0)))
    lat = kwant.lattice.Square()
    sys[[lat(0, 0), lat(0, 1)]] = 3
    sys[lat(0, 1), lat(0, 0)] = -1
    sys[((lat(1, y), lat(0, y)) for y in range(2))] = -1

    band_energies = kwant.physics.Bands(sys.finalized())
    for i in range(-N, N):
        k = i * pi / N
        energies = band_energies(k)
        assert_array_almost_equal(sorted(energies),
                                  sorted([2 - 2 * cos(k), 4 - 2 * cos(k)]))
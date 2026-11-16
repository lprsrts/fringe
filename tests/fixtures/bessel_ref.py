"""High-precision J0, J1, Y0, Y1 (real and complex) by power series in Decimal.

Independent of the Rust code: plain ascending series with 80-digit arithmetic,
complex numbers as (re, im) pairs of Decimal.
"""
from decimal import Decimal as D, getcontext
import json

getcontext().prec = 90

def pi_dec():
    # Machin: pi = 16 atan(1/5) - 4 atan(1/239)
    def atan_inv(n):
        x = D(1) / n; x2 = x * x; s = x; t = x; k = 1
        while True:
            t *= -x2; k += 2
            term = t / k
            if abs(term) < D(10) ** -88: break
            s += term
        return s
    return 16 * atan_inv(5) - 4 * atan_inv(239)

PI = pi_dec()
# Euler-Mascheroni constant, 80 digits (OEIS A001620)
GAMMA = D("0.57721566490153286060651209008240243104215933593992359880576723488486772677766467")

def cadd(a, b): return (a[0] + b[0], a[1] + b[1])
def csub(a, b): return (a[0] - b[0], a[1] - b[1])
def cmul(a, b): return (a[0] * b[0] - a[1] * b[1], a[0] * b[1] + a[1] * b[0])
def cscale(a, s): return (a[0] * s, a[1] * s)
def cdiv(a, b):
    d = b[0] * b[0] + b[1] * b[1]
    return ((a[0] * b[0] + a[1] * b[1]) / d, (a[1] * b[0] - a[0] * b[1]) / d)
def cabs(a): return (a[0] * a[0] + a[1] * a[1]).sqrt()

def atan(x):
    # argument reduction: atan(x) = 2 atan(x / (1 + sqrt(1 + x^2)))
    if x < 0: return -atan(-x)
    if x > 1: return PI / 2 - atan(1 / x)
    r = 0
    while x > D("0.1"):
        x = x / (1 + (1 + x * x).sqrt()); r += 1
    x2 = x * x; s = x; t = x; k = 1
    while True:
        t *= -x2; k += 2
        term = t / k
        if abs(term) < D(10) ** -88: break
        s += term
    return s * (2 ** r)

def atan2(y, x):
    if x > 0: return atan(y / x)
    if x < 0: return atan(y / x) + (PI if y >= 0 else -PI)
    return PI / 2 if y > 0 else -PI / 2

def clog(z): return (cabs(z).ln(), atan2(z[1], z[0]))

def series(z):
    """Return J0, J1, Y0, Y1 as complex Decimal pairs."""
    q = cscale(cmul(z, z), D(-1) / 4)   # -(z/2)^2
    half = cscale(z, D(1) / 2)
    # J0 = sum q^m/(m!)^2, J1 = (z/2) sum q^m/(m!(m+1)!)
    j0 = (D(0), D(0)); j1s = (D(0), D(0))
    y0s = (D(0), D(0)); y1s = (D(0), D(0))
    t = (D(1), D(0))           # q^m/(m!)^2
    H = D(0)                   # harmonic number H_m
    m = 0
    while True:
        tm1 = cscale(t, D(1) / (m + 1))        # q^m/(m!(m+1)!)
        j0 = cadd(j0, t)
        j1s = cadd(j1s, tm1)
        # Y0 tail: sum_{m>=1} (-1)^{m+1} H_m (z^2/4)^m/(m!)^2 = -sum H_m q^m/(m!)^2
        y0s = csub(y0s, cscale(t, H))
        # Y1 tail: sum (psi(m+1)+psi(m+2)) q^m/(m!(m+1)!), psi(m+1) = H_m - gamma
        y1s = cadd(y1s, cscale(tm1, 2 * H + D(1) / (m + 1) - 2 * GAMMA))
        if m > 5 and cabs(t) < D(10) ** -85: break
        m += 1
        H += D(1) / m
        t = cscale(cmul(t, q), D(1) / (m * m))
    j1 = cmul(half, j1s)
    L = cadd(clog(half), (GAMMA, D(0)))
    y0 = cadd(cscale(cmul(L, j0), 2 / PI), cscale(y0s, 2 / PI))
    # Y1 = -2/(pi z) + (2/pi) ln(z/2) J1 - (1/pi) (z/2) sum (psi(m+1)+psi(m+2)) q^m/(m!(m+1)!)
    y1 = csub(cscale(cmul(clog(half), j1), 2 / PI), cscale(cdiv((D(1), D(0)), z), 2 / PI))
    y1 = csub(y1, cscale(cmul(half, y1s), 1 / PI))
    return j0, j1, y0, y1

def f(c): return [float(c[0]), float(c[1])]

REAL = ["0.001", "0.01", "0.1", "0.5", "1", "1.5", "2.404825557695773", "3", "4.5", "6", "7.25",
        "8", "9.5", "10", "11", "11.999", "12.001", "13.5", "17", "25"]
COMPLEX = [("0.05", "-0.01"), ("0.7", "-0.2"), ("1.5", "-1.5"), ("2.5", "-0.5"), ("3", "-3"),
           ("4", "-1"), ("5.5", "-0.05"), ("6", "-6"), ("7.5", "-0.75"), ("9", "-2"), ("10", "-0.5"),
           ("11.5", "-4"), ("11.9", "-1.2"), ("12.5", "-1.2"), ("13", "-2"), ("14", "-7"),
           ("16", "-0.1"), ("18", "-9"), ("20", "-3"), ("24", "-1")]

if __name__ == "__main__":
    # Writes bessel_ref.json next to this file: J0, J1, Y0, Y1 and H0, H1 (second
    # kind, H = J - jY, formed before rounding so decaying H keeps its digits).
    import os
    pts = []
    for re, im in [(x, "0") for x in REAL] + COMPLEX:
        z = (D(re), D(im))
        j0, j1, y0, y1 = series(z)
        h0 = (j0[0] + y0[1], j0[1] - y0[0])
        h1 = (j1[0] + y1[1], j1[1] - y1[0])
        pts.append({"z": f(z), "j0": f(j0), "j1": f(j1), "y0": f(y0), "y1": f(y1), "h0": f(h0), "h1": f(h1)})
    doc = {"source": "ascending power series in 90-digit decimal arithmetic (bessel_ref.py)", "points": pts}
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bessel_ref.json")
    with open(out, "w") as fh:
        fh.write(json.dumps(doc, indent=1) + "\n")
    print(f"wrote {len(pts)} points to {out}")

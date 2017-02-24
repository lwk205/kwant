from kwant.continuum._common import position_operators, momentum_operators
from kwant.continuum._common import make_commutative, sympify
from kwant.continuum._common import expression_monomials, matrix_monomials
from kwant.continuum._common import lambdify

import tinyarray as ta
from sympy.physics.matrices import msigma
import sympy
from functools import reduce
from operator import mul
import pytest


def test_sympify():
    A, B, C = sympy.symbols('A B C')
    x, y, z = position_operators
    kx, ky, kz = momentum_operators

    # basics
    assert sympify('k_x * A(x) * k_x') == kx * A(x) * kx
    assert sympify('[[k_x * A(x) * k_x]]') == sympy.Matrix([kx * A(x) * kx])

    # using substitutions
    symbolic_pauli = {'sigma_x': msigma(1), 'sigma_y': msigma(2), 'sigma_z': msigma(3)}
    got = sympify('k_x * sigma_y + k_y * sigma_x', substitutions=symbolic_pauli)
    assert got == kx * symbolic_pauli['sigma_y'] + ky * symbolic_pauli['sigma_x']

    got = sympify("sigma_y", substitutions={'sigma_y': "[[0, -1j], [1j, 0]]"})
    assert got == symbolic_pauli['sigma_y']

    got = sympify("sigma_y", substitutions={'sigma_y': [[0, -sympy.I], [sympy.I, 0]]})
    assert got == symbolic_pauli['sigma_y']

    got = sympify('[[k_x*A(x)*k_x, B(x, y)*k_x], [k_x*B(x, y), C*k_y**2]]')
    assert got == sympy.Matrix([[kx*A(x)*kx, B(x, y)*kx], [kx*B(x, y), C*ky**2]])




A, B, non_x = sympy.symbols('A B x', commutative=False)
x = sympy.Symbol('x')

expr1 = non_x*A*non_x + x**2 * A * x + B*non_x**2

matr = sympy.Matrix([[expr1, expr1+A*non_x], [0, -expr1]])
res_mat = sympy.Matrix([[x**3*A + x**2*A + x**2*B, x**3*A + x**2*A + x**2*B + x*A],
                        [0, -x**3*A - x**2*A - x**2*B]])

def test_make_commutative():
    assert make_commutative(expr1, x) == make_commutative(expr1, non_x)
    assert make_commutative(expr1, x) == x**3*A + x**2*A + x**2*B
    assert make_commutative(matr, x) == res_mat


expr2 = non_x*A*non_x + x**2 * A*2 * x + B*non_x/2 + non_x*B/2 + x + A + non_x + x/A

def test_expression_monomials():
    assert expression_monomials(expr2, x) == {x**3: 2*A, 1: A, x: 2 + A**(-1) + B, x**2: A}
    assert expression_monomials(expr1, x) == {x**2: A + B, x**3: A}
    assert expression_monomials(x, x) == {x: 1}
    assert expression_monomials(x**2, x) == {x**2: 1}
    assert expression_monomials(x**2 + x, x) == {x: 1, x**2: 1}

    expr = 1 + x + A*x + 2*x + x**2 + A*x**2 + non_x*A*non_x
    out = {1: 1, x: 3 + A, x**2: 2 * A + 1}
    assert expression_monomials(expr, x) == out

    expr = 1 + x * (3 + A) + x**2 * (1 + A)
    out = {1: 1, x: 3 + A, x**2: 1 * A + 1}
    assert expression_monomials(expr, x) == out


def legacy_expression_monomials(expr, *gens):
    """ This was my first implementation. Unfortunately it is very slow.

    It is used to test correctness of new matrix_monomials function.
    """
    expr = make_commutative(expr, x)
    R = sympy.ring(gens, sympy.EX, sympy.lex)[0]
    expr = R(expr)

    output = {}
    for power, coeff in zip(expr.monoms(), expr.coeffs()):
        key = reduce(mul, [sympy.Symbol(k.name)**n for k, n in zip(gens, power)])
        output[key] = sympy.expand(coeff.as_expr())
    return output


def test_expression_monomials_with_reference_function():
    assert legacy_expression_monomials(expr2, x) == expression_monomials(expr2, x)



def test_matrix_monomials():
    out = {
            x**2: sympy.Matrix([[A + B,  A + B],[0, -A - B]]),
            x: sympy.Matrix([[0, A], [0, 0]]),
            x**3: sympy.Matrix([[A,  A], [0, -A]])}
    mons = matrix_monomials(matr, x)
    assert mons == out



@pytest.mark.parametrize("e, should_be, kwargs", [
    ("x+y", lambda x, y: x+y, dict(x=1, y=2)),
    ("1", lambda: 1, dict()),
    ("f(x)", lambda f, x: f(x), dict(f=lambda x: x, x=2)),
    (sympify("f(x)"), lambda f, x: f(x), dict(f=lambda x: x, x=2)),
    ("[[f(x)]]", lambda f, x: ta.array(f(x)), dict(f=lambda x: x, x=2))
])
def test_lambdify(e, should_be, kwargs):
    e = lambdify(e)
    assert e(**kwargs) == should_be(**kwargs)





# dispersion_string = ('A * k_x**2 * eye(2) + B * k_y**2 * eye(2)'
#                      '+ alpha * k_x * sigma_y')

# def dispersion_function(kx, ky, A, B, alpha, **kwargs):
#     h_k =  ((A * kx**2 + B * ky**2) * sigma_0 +
#              alpha * kx * sigma_y)
#     return np.linalg.eigvalsh(h_k)

# dispersion_kwargs = {'A': 1, 'B': 2, 'alpha': 0.5, 'M': 2}
# sigma_0 = np.eye(2)
# sigma_y = np.array([[0, -1j], [1j, 0]])


# @pytest.mark.parametrize("expr, should_be, kwargs", [
#     (dispersion_string, dispersion_function, dispersion_kwargs),
#     (sympify(dispersion_string), dispersion_function, dispersion_kwargs),
# ])
# def test_lambdify(expr, should_be, kwargs):
#     N = 5

#     x = y = np.linspace(-N, N+1)
#     xy = list(itertools.product(x, y))

#     h_k = lambdify(expr)
#     energies = [la.eigvalsh(h_k(k_x=kx, k_y=ky, **kwargs))
#                 for kx, ky in xy]
#     energies_should_be = [should_be(kx, ky, **kwargs) for kx, ky in xy]
#     assert np.allclose(energies, energies_should_be)
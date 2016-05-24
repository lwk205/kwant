# 2011-2016 Kwant authors.
#
# This file is part of Kwant.  It is subject to the license terms in the file
# LICENSE.rst found in the top-level directory of this distribution and at
# http://kwant-project.org/license.  A list of Kwant authors can be found in
# the file AUTHORS.rst at the top-level directory of this distribution and at
# http://kwant-project.org/authors.
r"""Tools for working with operators for acting on wavefunctions."""

__all__ = ['Density', 'Current', 'Source']

import cython
import functools as ft
import collections
import numpy as np
import tinyarray as ta
from operator import itemgetter

from libc cimport math

from .graph.core cimport EdgeIterator
from .graph.defs cimport gint
from .graph.defs import gint_dtype
from .system import InfiniteSystem
from . import builder
from ._common import UserCodeError

_finalized_builder = (builder.FiniteSystem, builder.InfiniteSystem)



################ Generic Utility functions

@cython.boundscheck(False)
@cython.wraparound(False)
cdef gint _bisect(gint[:] a, gint x):
    "bisect.bisect specialized for searching `site_ranges`"
    cdef gint mid, lo = 0, hi = a.shape[0]
    while lo < hi:
        mid = (lo + hi) // 2
        if x < a[mid]:
            hi = mid
        else:
            lo = mid + 1
    return lo


@cython.boundscheck(False)
@cython.wraparound(False)
cdef int _is_herm_conj(complex[:, :] a, complex[:, :] b,
                       double atol=1e-300, double rtol=1e-13) except -1:
    "Return True if `a` is the Hermitian conjugate of `b`."
    assert a.shape[0] == b.shape[1]
    assert a.shape[1] == b.shape[0]

    # compute max(a)
    cdef double tmp, max_a = 0
    cdef gint i, j
    for i in range(a.shape[0]):
        for j in range(a.shape[1]):
            tmp = a[i, j].real * a[i, j].real + a[i, j].imag * a[i, j].imag
            if tmp > max_a:
                max_a = tmp
    max_a = math.sqrt(max_a)

    cdef double tol = rtol * max_a + atol
    cdef complex ctmp
    for i in range(a.shape[0]):
        for j in range(a.shape[1]):
            ctmp = a[i, j] - b[j, i].conjugate()
            tmp = ctmp.real * ctmp.real + ctmp.imag * ctmp.imag
            if tmp > tol:
                return False
    return True



################ Helper functions

_shape_msg = ('{0} matrix dimensions do not match '
              'the declared number of orbitals')

_herm_msg = ('{0} matrix is not hermitian, use the option '
             '`check_hermiticity=True` if this is intentional.')

cdef int _check_onsite(complex[:, :] M, gint norbs,
                       int check_hermiticity) except -1:
    "Check onsite matrix for correct shape and hermiticity."
    if M.shape[0] != M.shape[1]:
        raise UserCodeError('Onsite matrix is not square')
    if M.shape[0] != norbs:
        raise UserCodeError(_shape_msg.format('Onsite'))
    if check_hermiticity and not _is_herm_conj(M, M):
        raise ValueError(_herm_msg.format('Onsite'))
    return 0


cdef int _check_ham(complex[:, :] H, ham, args,
                    gint a, gint a_norbs, gint b, gint b_norbs,
                    int check_hermiticity) except -1:
    "Check Hamiltonian matrix for correct shape and hermiticity."
    if H.shape[0] != a_norbs and H.shape[1] != b_norbs:
        raise UserCodeError(_shape_msg.format('Hamiltonian'))
    if check_hermiticity:
        # call the "partner" element if we are not on the diagonal
        H_conj = H if a == b else ta.matrix(ham(b, a, *args), complex)
        if not _is_herm_conj(H_conj, H):
            raise ValueError(_herm_msg.format('Hamiltonian'))
    return 0


@cython.boundscheck(False)
@cython.wraparound(False)
cdef void _get_orbs(gint[:, :] site_ranges, gint site,
                    gint *start_orb, gint *norbs):
    """Return the first orbital of this site and the number of orbitals"""
    cdef gint run_idx, first_site, norb, orb_offset, orb
    # Calculate the index of the range that contains the site.
    run_idx = _bisect(site_ranges[:, 0], site) - 1
    first_site = site_ranges[run_idx, 0]
    norb = site_ranges[run_idx, 1]
    orb_offset = site_ranges[run_idx, 2]
    # calculate the slice
    start_orb[0] = orb_offset + (site - first_site) * norb
    norbs[0] = norb


@cython.boundscheck(False)
@cython.wraparound(False)
def _get_all_orbs(gint[:, :] where, gint[:, :] site_ranges):
    cdef gint[:, :] offsets = np.empty((where.shape[0], 2), dtype=gint_dtype)
    cdef gint[:, :] norbs = np.empty((where.shape[0], 2), dtype=gint_dtype)

    cdef gint w, a, a_offset, a_norbs, b, b_offset, b_norbs
    for w in range(where.shape[0]):
        a = where[w, 0]
        _get_orbs(site_ranges, a, &a_offset, &a_norbs)
        if where.shape[1] == 1:
            b, b_offset, b_norbs = a, a_offset, a_norbs
        else:
            b = where[w, 1]
            _get_orbs(site_ranges, b, &b_offset, &b_norbs)
        offsets[w, 0] = a_offset
        offsets[w, 1] = b_offset
        norbs[w, 0] = a_norbs
        norbs[w, 1] = b_norbs

    return offsets, norbs


def _get_tot_norbs(syst):
    cdef gint _unused, tot_norbs
    is_infinite_system = isinstance(syst, InfiniteSystem)
    n_sites = syst.cell_size if is_infinite_system else syst.graph.num_nodes
    _get_orbs(np.asarray(syst.site_ranges, dtype=gint_dtype),
              n_sites, &tot_norbs, &_unused)
    return tot_norbs


def _normalize_site_where(syst, where):
    """Normalize the format of `where` when `where` contains sites.

    If `where` is None, then all sites in the system are returned.
    If it is a general iterator then it is expanded into an array. If `syst`
    is a finalized Builder then `where` should contain `Site` objects,
    otherwise it should contain integers.
    """
    if where is None:
        size = (syst.graph.cell_size
                if isinstance(syst, InfiniteSystem) else syst.graph.num_nodes)
        _where = list(range(size))
    elif callable(where):
        if isinstance(syst, _finalized_builder):
            _where = [syst.id_by_site[a] for a in filter(where, syst.sites)]
        else:
            _where = list(filter(where, range(syst.graph.num_nodes)))
    else:
        if isinstance(syst, _finalized_builder):
            _where = list(syst.id_by_site[s] for s in where)
        else:
            _where = list(where)
            if any(w < 0 or w >= syst.graph.num_nodes for w in _where):
                raise ValueError('`where` contains sites that are not in the '
                                 'system.')

    if isinstance(syst, InfiniteSystem):
        if any(w >= syst.cell_size for w in _where):
            raise ValueError('Only sites in the fundamental domain may be '
                             'specified using `where`.')

    return np.asarray(_where, dtype=gint_dtype).reshape(len(_where), 1)


def _normalize_hopping_where(syst, where):
    """Normalize the format of `where` when `where` contains hoppings.

    If `where` is None, then all hoppings in the system are returned.
    If it is a general iterator then it is expanded into an array. If `syst` is
    a finalized Builder then `where` should contain pairs of `Site` objects,
    otherwise it should contain pairs of integers.
    """
    if where is None:
        # we cannot extract the hoppings in the same order as they are in the
        # graph while simultaneously excluding all inter-cell hoppings
        if isinstance(syst, InfiniteSystem):
            raise ValueError('`where` must be provided when calculating '
                             'current in an InfiniteSystem.')
        _where = list(syst.graph)
    elif callable(where):
        if isinstance(syst, _finalized_builder):
            def idx_where(hop):
                a, b = hop
                return where(syst.sites[a], syst.sites[b])
            _where = list(filter(idx_where, syst.graph))
        else:
            _where = list(filter(lambda h: where(*h), syst.graph))
    else:
        if isinstance(syst, _finalized_builder):
            _where = list((syst.id_by_site[a], syst.id_by_site[b])
                           for a, b in where)
        else:
            _where = list(where)
            # NOTE: if we ever have operators that contain elements that are
            #       not in the system graph, then we should modify this check
            if any(not syst.graph.has_edge(*w) for w in where):
                raise ValueError('`where` contains hoppings that are not in the '
                                 'system.')

    if isinstance(syst, InfiniteSystem):
        if any(a > syst.cell_size or b > syst.cell_size for a, b in _where):
            raise ValueError('Only intra-cell hoppings may be specified '
                             'using `where`.')

    return np.asarray(_where, dtype=gint_dtype)


def _normalize_onsite(syst, onsite, check_hermiticity):
    """Normalize the format of `onsite`.

    If `onsite` is a function or a mapping (dictionary) then a function
    is returned.
    """
    if callable(onsite):
        if isinstance(syst, _finalized_builder):
            _sites = syst.sites
            def _onsite(site_id, *args):
                return onsite(_sites[site_id], *args)
        else:
            _onsite = onsite
    elif isinstance(onsite, collections.Mapping):
        if not isinstance(syst, _finalized_builder):
            raise TypeError('Provide `onsite` as a value or a function for '
                            'systems that are not finalized Builders.')

        # onsites known; immediately check for correct shape and hermiticity
        for fam, _onsite in onsite.items():
            _onsite = ta.matrix(_onsite, complex)
            _check_onsite(_onsite, fam.norbs, check_hermiticity)

        _sites = syst.sites
        def _onsite(site_id, *args):
            return onsite[_sites[site_id].family]
    else:
        # single onsite; immediately check for correct shape and hermiticity
        _onsite = ta.matrix(onsite, complex)
        _check_onsite(_onsite, _onsite.shape[0], check_hermiticity)
        if _onsite.shape[0] == 1:
            # NOTE: this is wasteful when many orbitals per site, but it
            # simplifies the code in `_operate`. If this proves to be a
            # bottleneck, then we can add a code path for scalar onsites
            max_norbs = max(norbs for (_, norbs, _) in syst.site_ranges)
            _onsite = _onsite[0, 0] * ta.identity(max_norbs, complex)
        elif len(set(map(itemgetter(1), syst.site_ranges[:-1]))) == 1:
            # we have the same number of orbitals everywhere
            norbs = syst.site_ranges[0][1]
            if _onsite.shape[0] != norbs:
                msg = ('Single `onsite` matrix of shape ({0}, {0}) provided '
                       'but there are {1} orbitals per site in the system')
                raise ValueError(msg.format(_onsite.shape[0], norbs))
        else:
            msg = ('Single `onsite` matrix provided, but there are '
                   'different numbers of orbitals on different sites')
            raise ValueError(msg)

    return _onsite


cdef class BlockSparseMatrix:
    """A sparse matrix stored as dense blocks.

    Parameters
    ----------
    where : gint[:, :]
        ``Nx2`` matrix or ``Nx1`` matrix: the arguments ``a``
        and ``b`` to be used when evaluating ``f``. If an
        ``Nx1`` matrix, then ``b=a``.
    block_offsets : gint[:, :]
        The row and column offsets for the start of each block
        in the sparse matrix: ``(row_offset, col_offset)``.
    block_shapes : gint[:, :]
        ``Nx2`` array: the shapes of each block, ``(n_rows, n_cols)``.
    f : callable
        evaluates matrix blocks. Has signature ``(a, n_rows, b, n_cols)``
        where all the arguments are integers and
        ``a`` and ``b`` are the contents of ``where``. This function
        must return a matrix of shape ``(n_rows, n_cols)``.

    Attributes
    ----------
    block_offsets : gint[:, :]
        The row and column offsets for the start of each block
        in the sparse matrix: ``(row_offset, col_offset)``.
    block_shapes : gint[:, :]
        The shape of each block: ``(n_rows, n_cols)``
    data_offsets : gint[:]
        The offsets of the start of each matrix block in `data`.
    data : complex[:]
        The matrix of each block, stored in row-major (C) order.
    """

    cdef public gint[:, :] block_offsets, block_shapes
    cdef public gint[:] data_offsets
    cdef public complex[:] data

    @cython.embedsignature
    @cython.boundscheck(False)
    @cython.wraparound(False)
    def __init__(self, gint[:, :] where, gint[:, :] block_offsets,
                  gint[:, :] block_shapes, f):
        if (block_offsets.shape[0] != where.shape[0] or
            block_shapes.shape[0] != where.shape[0]):
            raise ValueError('Arrays should be the same length along '
                             'the first axis.')
        self.block_shapes = block_shapes
        self.block_offsets = block_offsets
        self.data_offsets = np.empty(where.shape[0], dtype=gint_dtype)
        ### calculate shapes and data_offsets
        cdef gint w, data_size = 0
        for w in range(where.shape[0]):
            self.data_offsets[w] = data_size
            data_size += block_shapes[w, 0] * block_shapes[w, 1]
        ### Populate data array
        self.data = np.empty((data_size,), dtype=complex)
        cdef complex[:, :] mat
        cdef gint i, j, off, a, b, a_norbs, b_norbs
        for w in range(where.shape[0]):
            off = self.data_offsets[w]
            a_norbs = self.block_shapes[w, 0]
            b_norbs = self.block_shapes[w, 1]
            a = where[w, 0]
            b = a if where.shape[1] == 1 else where[w, 1]
            # call the function that gives the matrix
            mat = f(a, a_norbs, b, b_norbs)
            # Copy data
            for i in range(a_norbs):
                for j in range(b_norbs):
                    self.data[off + i * b_norbs + j] = mat[i, j]

    cdef complex* get(self, gint block_idx):
        return  <complex*> &self.data[0] + self.data_offsets[block_idx]



################ Local Observables

# supported operations within the `_operate` method
ctypedef enum operation:
    MAT_ELS
    ACT


cdef class _LocalOperator:
    """Base class for operators defined by an on-site matrix and the Hamiltonian.

    This includes "true" local operators, as well as "currents" and "sources".

    Attributes
    ----------
    syst : `~kwant.system.System`
        The system for which this operator is defined. Must have the
        number of orbitals defined for all site families.
    where : 2D array of `int` or `None`
        where to evaluate the operator. A list of sites for on-site
        operators (accessed like `where[n, 0]`), otherwise a list of pairs
        of sites (accessed like `where[n, 0]` and `where[n, 1]`).
    onsite : complex 2D array, or callable
        If a complex array, then the same onsite is used everywhere.
        Otherwise, function that can be called with a single site (integer) and
        extra arguments, and returns the representation of the operator on
        that site. This should return either a scalar or a square matrix of the
        same shape as that returned by the system Hamiltonian evaluated on the
        same site.  The extra arguments must be the same as the extra arguments
        to ``syst.hamiltonian``.
    check_hermiticity : bool
        If True, checks that ``onsite``, as well as any relevant parts
        of the Hamiltonian are hermitian.
    """

    cdef public int check_hermiticity
    cdef public object syst, onsite
    cdef public gint[:, :]  where, _site_ranges
    cdef public BlockSparseMatrix _bound_onsite, _bound_hamiltonian

    @cython.embedsignature
    def __init__(self, syst, onsite, where, check_hermiticity):
        if syst.site_ranges is None:
            raise ValueError('Number of orbitals not defined.\n'
                             'Declare the number of orbitals using the '
                             '`norbs` keyword argument when constructing '
                             'the site families (lattices).')

        self.syst = syst
        self.onsite = _normalize_onsite(syst, onsite, check_hermiticity)
        self.check_hermiticity = check_hermiticity
        self._site_ranges = np.asarray(syst.site_ranges, dtype=gint_dtype)
        self._bound_onsite = None
        self._bound_hamiltonian = None
        self.where = None
        # NOTE: subclasses should populate `where`

    @cython.embedsignature
    def __call__(self, bra, ket=None, args=()):
        """Return the matrix elements of the operator.

        Parameters
        ----------
        bra, ket : `~numpy.ndarray`
            Must have the same length as the number of orbitals
            in the system. If only one is provided, both ``bra``
            and ``ket`` are taken as equal.
        args : tuple, optional
            The arguments to pass to the system. Used to evaluate
            the ``onsite`` elements and, possibly, the system Hamiltonian.

        Returns
        -------
        (values, where)
            both elements of the tuple are arrays of the same length.
            ``values`` is an array of `float` if ``check_hermiticity`` is True,
            otherwise it is `complex`. ``where`` is an array of `int` that
            specifies the sites/hoppings for which the matrix elements
            are calculated.
        """
        if (self._bound_onsite or self._bound_hamiltonian) and args:
            raise ValueError('Extra arguments are already bound to this '
                             'operator. You should call this operator '
                             'without providing `args`.')
        if bra is None:
            raise TypeError('bra must be an array')
        bra = np.asarray(bra, dtype=complex)
        ket = bra if ket is None else np.asarray(ket, dtype=complex)
        tot_norbs = _get_tot_norbs(self.syst)
        if bra.shape != (tot_norbs,):
            msg = 'vector is incorrect shape'
            msg = 'bra ' + msg if ket else msg
            raise ValueError(msg)
        elif ket.shape != (tot_norbs,):
            raise ValueError('ket vector is incorrect shape')

        where = np.asarray(self.where)
        where.setflags(write=False)
        if self.where.shape[1] == 1:
            # if `where` just contains sites, then we want a strictly 1D array
            where = where.reshape(-1)

        result = np.zeros((self.where.shape[0],), dtype=complex)
        self._operate(out_data=result, bra=bra, ket=ket, args=args, op=MAT_ELS)
        # if everything is Hermitian then result should be real
        if self.check_hermiticity:
            assert np.allclose(result.imag, 0)
            result = result.real
        return (result, where)

    @cython.embedsignature
    def act(self, ket, args=()):
        """Act with the operator on a wavefunction.

        Parameters
        ----------
        ket : `~numpy.ndarray`
            Wavefunctions defined over all the orbitals of the system.
        args : tuple
            The extra arguments to the Hamiltonian value functions and
            the operator ``onsite`` function.

        Returns
        -------
        `~numpy.ndarray`
            The result of acting on the wavefunction with the operator
        """
        if (self._bound_onsite or self._bound_hamiltonian) and args:
            raise ValueError('Extra arguments are already bound to this '
                             'operator. You should call this operator '
                             'without providing `args`.')

        if ket is None:
            raise TypeError('ket must be an array')
        ket = np.asarray(ket, dtype=complex)
        tot_norbs = _get_tot_norbs(self.syst)
        if ket.shape != (tot_norbs,):
            raise ValueError('ket vector is incorrect shape')
        result = np.zeros((tot_norbs,), dtype=np.complex)
        self._operate(out_data=result, bra=None, ket=ket, args=args, op=ACT)
        return result

    @cython.embedsignature
    def bind(self, args=()):
        """Bind the given arguments to this operator.

        Returns a copy of this operator that does not need to be passed extra
        arguments when subsequently called or when using the ``act`` method.
        """
        # generic creation of new instance
        cls = self.__class__
        q = cls.__new__(cls)
        q.syst = self.syst
        q.onsite = self.onsite
        q.where = self.where
        q._site_ranges = self._site_ranges
        q.check_hermiticity = self.check_hermiticity
        if callable(self.onsite):
            q._bound_onsite = self._eval_onsites(args)
        # NOTE: subclasses should populate `bound_hamiltonian` if needed
        return q

    def _operate(self, complex[:] out_data, complex[:] bra, complex[:] ket,
                 args, operation op):
        """Do an operation with the operator.

        Parameters
        ----------
        out_data : ndarray
            Output array, zero on entry. On exit should contain the required
            data.  What this means depends on the value of `op`, as does the
            length of the array.
        bra, ket : ndarray
            Wavefunctions defined over all the orbitals of the system.
            If `op` is `ACT` then `bra` is None.
        args : tuple
            The extra arguments to the Hamiltonian value functions and
            the operator ``onsite`` function.
        op : operation
            The operation to perform.
            `MAT_ELS`: calculate matrix elements between `bra` and `ket`
            `ACT`: act on `ket` with the operator
        """
        raise NotImplementedError()

    cdef BlockSparseMatrix _eval_onsites(self, args):
        """Evaluate the onsite matrices on all elements of `where`"""
        assert callable(self.onsite)
        matrix = ta.matrix
        onsite = self.onsite
        check_hermiticity = self.check_hermiticity

        def get_onsite(a, a_norbs, b, b_norbs):
            mat = matrix(onsite(a, *args), complex)
            _check_onsite(mat, a_norbs, check_hermiticity)
            return mat

        offsets, norbs = _get_all_orbs(self.where, self._site_ranges)
        return  BlockSparseMatrix(self.where, offsets, norbs, get_onsite)

    cdef BlockSparseMatrix _eval_hamiltonian(self, args):
        """Evaluate the Hamiltonian on all elements of `where`."""
        matrix = ta.matrix
        hamiltonian = self.syst.hamiltonian
        check_hermiticity = self.check_hermiticity

        def get_ham(a, a_norbs, b, b_norbs):
            mat = matrix(hamiltonian(a, b, *args), complex)
            _check_ham(mat, hamiltonian, args,
                       a, a_norbs, b, b_norbs, check_hermiticity)
            return mat

        offsets, norbs = _get_all_orbs(self.where, self._site_ranges)
        return  BlockSparseMatrix(self.where, offsets, norbs, get_ham)


cdef class Density(_LocalOperator):
    """An operator for calculating general densities.

    Examples of "densities" include charge and spin, and are defined by a
    square matrix on each site (of the size of the number of orbitals on the
    site).


    Parameters
    ----------
    syst : `~kwant.system.System`
    onsite : scalar or square matrix or dict or callable
        The onsite matrix that defines the operator. If a dict is given, it
        maps from site families to square matrices. If a function is given it
        must take the same arguments as the onsite Hamiltonian functions of the
        system.
    where : sequence of `int` or `~kwant.builder.Site`, or callable, optional
        Where to evaluate the operator. If ``syst`` is not a finalized Builder,
        then this should be a sequence of integers. If a function is provided,
        it should take a single `int` or `~kwant.builder.Site` (if ``syst`` is
        a finalized builder) and return True or False.  If not provided, the
        operator will be calculated over all sites in the system.
    check_hermiticity: bool
        Check whether the provided ``onsite`` is Hermitian. If it is not
        Hermitian, then an error will be raised when the operator is
        evaluated.

    Notes
    -----
    When this class is called in the following way::

        Q = kwant.physics.operator.Density(fsyst, M_a)
        Q(phi, psi)

    the following expression is calculated for each site ``a``
    in ``where``::

        phi[i:j].conjugate().dot(M_a.dot(psi[i:j]))

    where ``i:j`` is a slice over all the orbitals on site ``a``,
    and ``M_a`` is a square matrix associated with site ``a``.

    When used in the following way::

        phi = Q.act(psi)

    this is equivalent to performing the following operation
    for each site ``a`` in ``where``::

        phi[i:j] += M_a.dot(psi[i:j])

    .. rubric:: Special Methods
    .. automethod:: __call__
    """

    @cython.embedsignature
    def __init__(self, syst, onsite=1, where=None, check_hermiticity=True):
        super().__init__(syst, onsite, where, check_hermiticity)
        self.where = _normalize_site_where(syst, where)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    def _operate(self, complex[:] out_data, complex[:] bra, complex[:] ket,
                 args, operation op):
        matrix = ta.matrix
        cdef int unique_onsite = not callable(self.onsite)
        # prepare onsite matrices
        cdef complex[:, :] _tmp_mat
        cdef complex *M_a
        cdef BlockSparseMatrix M_a_blocks
        if unique_onsite:
            _tmp_mat = self.onsite
            M_a = <complex*> &_tmp_mat[0, 0]
        else:
            M_a_blocks = self._bound_onsite or self._eval_onsites(args)
        # loop-local variables
        cdef gint a, a_s, a_norbs
        cdef gint i, j, w
        cdef complex tmp, bra_conj
        ### loop over sites
        for w in range(self.where.shape[0]):
            ### get the next site, start orbital and number of orbitals
            a = self.where[w, 0]
            _get_orbs(self._site_ranges, a, &a_s, &a_norbs)
            ### get the next onsite matrix, if necessary
            if not unique_onsite:
                M_a = M_a_blocks.get(w)
            ### do the actual calculation
            if op == MAT_ELS:
                tmp = 0
                for i in range(a_norbs):
                    for j in range(a_norbs):
                        tmp += (bra[a_s + i].conjugate() *
                                M_a[i * a_norbs + j] * ket[a_s + j])
                out_data[w] = tmp
            elif op == ACT:
                for i in range(a_norbs):
                    tmp = 0
                    for j in range(a_norbs):
                        tmp += M_a[i * a_norbs + j] * ket[a_s + j]
                    out_data[a_s + i] = out_data[a_s + i] + tmp


cdef class Current(_LocalOperator):
    """An operator for calculating general currents.

    Examples of "currents" include charge currents and spin currents.
    If there is a certain "density" (e.g. charge or spin) that is
    represented by the operator ``M``, then the associated current
    is represented by the off-diagonal part of the commutator between
    the Hamiltonian and ``M``: ``[H, M]``.

    Parameters
    ----------
    syst : `~kwant.system.System`
    onsite : scalar or square matrix or dict or callable
        The onsite matrix that defines the density from which this current is
        derived. If a dict is given, it maps from site families to square
        matrices (scalars are allowed if the site family has 1 orbital per
        site). If a function is given it must take the same arguments as the
        onsite Hamiltonian functions of the system.
    where : sequence of pairs of `int` or `~kwant.builder.Site`, or callable, optional
        Where to evaluate the operator. If ``syst`` is not a finalized Builder,
        then this should be a sequence of pairs of integers. If a function is
        provided, it should take a pair of integers or a pair of
        `~kwant.builder.Site` (if ``syst`` is a finalized builder) and return
        True or False.  If not provided, the operator will be calculated over
        all hoppings in the system.
    check_hermiticity : bool
        Check whether the provided ``onsite`` is Hermitian. If it
        is not Hermitian, then an error will be raised when the
        operator is evaluated.

    Notes
    -----
    Calculates the flux of a quantity ``M_a`` through hoppings.

    When this class is called in the following way::

        J = kwant.physics.operator.Current(fsyst, M_a)
        J(phi, psi)

    the following expression is calculated for each pair of sites
    ``(a, b)`` in ``where``::

        1j * (phi[bi:bj].conjugate().dot(
                H_ab.conjugate().transpose().dot(M_a.dot(psi[ai:aj])))
              -
              phi[ai:aj].conjugate().dot(
                M_a.dot(H_ab.dot(psi[bi:bj])))
             )

    where ``ai:aj`` and ``bi:bj`` are slices over all the orbitals on sites
    ``a`` and ``b`` respectively. ``M_a`` is a square matrix and ``H_ab`` is
    the Hamiltonian matrix element between the sites.

    When used in the following way::

        phi = J.act(psi)

    this is equivalent to performing the following operations
    for each pair of sites ``(a, b)`` in ``where``::

        phi[bi:bj] += 1j * H_ab.conjugate().transpose().dot(M_a.dot(psi[ai:aj]))
        phi[ai:aj] += -1j * M_a.dot(H_ab.dot(psi[bi:bj]))

    .. rubric:: Special Methods
    .. automethod:: __call__
    """

    @cython.embedsignature
    def __init__(self, syst, onsite=1, where=None, check_hermiticity=True):
        super().__init__(syst, onsite, where, check_hermiticity)
        self.where = _normalize_hopping_where(syst, where)

    @cython.embedsignature
    def bind(self, args=()):
        """Bind the given arguments to this operator.

        Returns a copy of this operator that does not need to be passed extra
        arguments when subsequently called or when using the ``act`` method.
        """
        q = super().bind(args)
        q._bound_hamiltonian = self._eval_hamiltonian(args)
        return q

    @cython.boundscheck(False)
    @cython.wraparound(False)
    def _operate(self, complex[:] out_data, complex[:] bra, complex[:] ket,
                 args, operation op):
        # prepare onsite matrices and hamiltonians
        cdef int unique_onsite = not callable(self.onsite)
        cdef complex[:, :] _tmp_mat
        cdef complex *M_a,
        cdef complex *H_ab
        cdef BlockSparseMatrix M_a_blocks, H_ab_blocks
        if unique_onsite:
            _tmp_mat = self.onsite
            M_a = <complex*> &_tmp_mat[0, 0]
        else:
            M_a_blocks = self._bound_onsite or self._eval_onsites(args)
        H_ab_blocks = self._bound_hamiltonian or self._eval_hamiltonian(args)
        # main loop
        cdef gint a, a_s, a_norbs, b, b_s, b_norbs
        cdef gint i, j, k, w
        cdef complex tmp
        for w in range(self.where.shape[0]):
            ### get the next hopping's start orbitals and numbers of orbitals
            a_s = H_ab_blocks.block_offsets[w, 0]
            b_s = H_ab_blocks.block_offsets[w, 1]
            a_norbs = H_ab_blocks.block_shapes[w, 0]
            b_norbs = H_ab_blocks.block_shapes[w, 1]
            ### get the next onsite and Hamiltonian matrices
            H_ab = H_ab_blocks.get(w)
            if not unique_onsite:
                M_a = M_a_blocks.get(w)
            ### do the actual calculation
            if op == MAT_ELS:
                tmp = 0
                for i in range(b_norbs):
                    for j in range(a_norbs):
                        for k in range(a_norbs):
                            tmp += (bra[b_s + i].conjugate() *
                                    H_ab[j * b_norbs + i].conjugate() *
                                    M_a[j * a_norbs + k] * ket[a_s + k]
                                  - bra[a_s + j].conjugate() *
                                    M_a[j * a_norbs + k] *
                                    H_ab[k * b_norbs + i] * ket[b_s + i])
                out_data[w] = 1j * tmp
            elif op == ACT:
                for i in range(b_norbs):
                    for j in range(a_norbs):
                        for k in range(a_norbs):
                            out_data[b_s + i] = (
                                out_data[b_s + i] +
                                1j * H_ab[j * b_norbs + i].conjugate() *
                                M_a[j * a_norbs + k] * ket[a_s + k])
                            out_data[a_s + j] = (
                                out_data[a_s + j] -
                                1j * M_a[j * a_norbs + k] * H_ab[k * b_norbs + i] *
                                ket[b_s + i])


cdef class Source(_LocalOperator):
    """An operator for calculating general sources.

    An example of a "source" is a spin torque. In general,
    if there is a certain "density" (e.g. charge or spin) that is
    represented by the operator ``M``, then the associated source
    is represented by the diagonal part of the commutator between
    the Hamiltonian and ``M``: ``[H, M]``.

    Parameters
    ----------
    syst : `~kwant.system.System`
    onsite : scalar or square matrix or dict or callable
        The onsite matrix that defines the density from which this source is
        defined. If a dict is given, it maps from site families to square
        matrices (scalars are allowed if the site family has 1 orbital per
        site). If a function is given it must take the same arguments as the
        onsite Hamiltonian functions of the system.
    where : sequence of `int` or `~kwant.builder.Site`, or callable, optional
        Where to evaluate the operator. If ``syst`` is not a finalized Builder,
        then this should be a sequence of integers. If a function is provided,
        it should take a single `int` or `~kwant.builder.Site` (if ``syst`` is
        a finalized builder) and return True or False.  If not provided, the
        operator will be calculated over all sites in the system.
    check_hermiticity : bool
        Check whether the provided ``onsite`` is Hermitian. If it is not
        Hermitian, then an error will be raised when the operator is
        evaluated.

    Notes
    -----
    Calculates the source of a quantity ``M_a`` on different sites.

    When this class is called in the following way::

        K = kwant.physics.operator.Source(fsyst, M_a)
        K(phi, psi)

    the following expression is calculated for each site ``a``
    in ``where``::

        1j * (phi[i:j].conjugate().dot(
                H_aa.conjugate().transpose().dot(M_a.dot(psi[i:j])))
              -
              phi[i:j].conjugate().dot(
                M_a.dot(H_aa.dot(psi[i:j])))
             )

    where ``i:j`` is a slice over all the orbitals on site ``a`` ``M_a`` is a
    square matrix and ``H_aa`` is the onsite Hamiltonian matrix element for
    site ``a``.

    When used in the following way::

        phi = K.act(psi)

    this is equivalent to performing the following operation
    for each element in ``where``::

        phi[i:j] += M_a.dot(psi[i:j])

    .. rubric:: Special Methods
    .. automethod:: __call__
    """

    @cython.embedsignature
    def __init__(self, syst, onsite=1, where=None, check_hermiticity=True):
        super().__init__(syst, onsite, where, check_hermiticity)
        self.where = _normalize_site_where(syst, where)

    @cython.embedsignature
    def bind(self, args=()):
        """Bind the given arguments to this operator.

        Returns a copy of this operator that does not need to be passed extra
        arguments when subsequently called or when using the ``act`` method.
        """
        q = super().bind(args)
        q._bound_hamiltonian = self._eval_hamiltonian(args)
        return q

    @cython.boundscheck(False)
    @cython.wraparound(False)
    def _operate(self, complex[:] out_data, complex[:] bra, complex[:] ket,
                 args, operation op):
        # prepare onsite matrices and hamiltonians
        cdef int unique_onsite = not callable(self.onsite)
        cdef complex[:, :] _tmp_mat
        cdef complex *M_a,
        cdef complex *H_aa
        cdef BlockSparseMatrix M_a_blocks, H_aa_blocks
        if unique_onsite:
            _tmp_mat = self.onsite
            M_a = <complex*> &_tmp_mat[0, 0]
        else:
            M_a_blocks = self._bound_onsite or self._eval_onsites(args)
        H_aa_blocks = self._bound_hamiltonian or self._eval_hamiltonian(args)
        # main loop
        cdef gint a, a_s, a_norbs
        cdef gint i, j, k, w
        cdef complex tmp, tmp2
        for w in range(self.where.shape[0]):
            ### get the next site, start orbital and number of orbitals
            # row offsets and block size are the same as for columns, as
            # we are only dealing with the block-diagonal part of H
            a_s = H_aa_blocks.block_offsets[w, 0]
            a_norbs = H_aa_blocks.block_shapes[w, 0]
            ### get the next onsite and Hamiltonian matrices
            H_aa = H_aa_blocks.get(w)
            if not unique_onsite:
                M_a = M_a_blocks.get(w)
            ### do the actual calculation
            if op == MAT_ELS:
                tmp2 = 0
                for i in range(a_norbs):
                    tmp = 0
                    for j in range(a_norbs):
                        for k in range(a_norbs):
                            tmp += (H_aa[j * a_norbs + i].conjugate() *
                                    M_a[j * a_norbs + k] * ket[a_s + k]
                                  - M_a[i * a_norbs + j] *
                                    H_aa[j * a_norbs + k] * ket[a_s + k])
                    tmp2 += bra[a_s + i].conjugate() * tmp
                out_data[w] = 1j * tmp2
            elif op == ACT:
                for i in range(a_norbs):
                    tmp = 0
                    for j in range(a_norbs):
                        for k in range(a_norbs):
                            tmp += (H_aa[j * a_norbs + i].conjugate() *
                                    M_a[j * a_norbs + k] * ket[a_s + k]
                                  - M_a[i * a_norbs + j] *
                                    H_aa[j * a_norbs + k] * ket[a_s + k])
                    out_data[a_s + i] = out_data[a_s + i] + 1j * tmp

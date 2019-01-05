# -*- coding: utf-8 -*-

"""
@author: Quoc-Tuan Truong <tuantq.vnu@gmail.com>
"""

import numpy as np
import scipy.sparse as sp
from cornac.models.recommender import Recommender
from cornac.utils.generic_utils import intersects
from cornac.exception import ScoreException

cimport cython
cimport numpy as np


class MF(Recommender):
    """Matrix Factorization.

    Parameters
    ----------
    k: int, optional, default: 10
        The dimension of the latent factors.

    max_iter: int, optional, default: 100
        Maximum number of iterations or the number of epochs for SGD.

    learning_rate: float, optional, default: 0.01
        The learning rate.

    lambda_reg: float, optional, default: 0.001
        The lambda value used for regularization.

    use_bias: boolean, optional, default: True
        When True, user, item, and global biases are used.

    early_stop: boolean, optional, default: False
        When True, delta loss will be checked after each iteration to stop learning earlier.

    verbose: boolean, optional, default: False
        When True, some running logs are displayed.

    References
    ----------
    * Koren, Y., Bell, R., & Volinsky, C. Matrix factorization techniques for recommender systems. \
    In Computer, (8), 30-37. 2009.
    """

    def __init__(self, k=10, max_iter=20, learning_rate=0.01, lambda_reg=0.02, use_bias=True, early_stop=False,
                 verbose=False):
        Recommender.__init__(self, name='MF', verbose=verbose)

        self.k = k
        self.max_iter = max_iter
        self.learning_rate = learning_rate
        self.lambda_reg = lambda_reg
        self.use_bias = use_bias
        self.early_stop = early_stop
        self.fitted = False

    @cython.boundscheck(False)  # turn off bounds-checking for entire function
    @cython.wraparound(False)  # turn off negative index wrapping for entire function
    def fit(self, train_set):
        """Fit the model to observations.

        Parameters
        ----------
        train_set: object of type TrainSet, required
            An object contains the user-item preference in csr scipy sparse format,\
            as well as some useful attributes such as mappings to the original user/item ids.\
            Please refer to the class TrainSet in the "data" module for details.
        """

        Recommender.fit(self, train_set)

        (rid, cid, val) = sp.find(train_set.matrix)

        cdef np.ndarray[np.double_t, ndim=2] u_factors
        cdef np.ndarray[np.double_t, ndim=2] i_factors
        u_factors = np.random.normal(size=[train_set.num_users, self.k], loc=0., scale=0.01)
        i_factors = np.random.normal(size=[train_set.num_items, self.k], loc=0., scale=0.01)

        cdef np.ndarray[np.double_t] u_biases
        cdef np.ndarray[np.double_t] i_biases
        if self.use_bias:
            u_biases = np.zeros([train_set.num_users], dtype=np.double)
            i_biases = np.zeros([train_set.num_items], dtype=np.double)

        cdef double loss = 0
        cdef double last_loss = 0
        cdef double lr = self.learning_rate
        cdef double reg = self.lambda_reg
        cdef double mu = train_set.global_mean
        cdef int u, i, factor
        cdef double r, r_pred, error, u_f, i_f, delta_loss

        for iter in range(1, self.max_iter + 1):
            last_loss = loss
            loss = 0

            for u, i, r in zip(rid, cid, val):
                r_pred = 0
                for factor in range(self.k):
                    r_pred += u_factors[u, factor] * i_factors[i, factor]
                if self.use_bias:
                    r_pred += mu + u_biases[u] + i_biases[i]

                error = r - r_pred
                loss += error * error

                for factor in range(self.k):
                    u_f = u_factors[u, factor]
                    i_f = i_factors[i, factor]
                    u_factors[u, factor] += lr * (error * i_f - reg * u_f)
                    i_factors[i, factor] += lr * (error * u_f - reg * i_f)

            loss = 0.5 * loss

            delta_loss = np.abs(loss - last_loss)
            if self.early_stop and delta_loss < 1e-5:
                if self.verbose:
                    print('Early stopping, delta_loss = '.format(delta_loss))
                break

            if self.verbose:
                print('Iter {}, loss = {}'.format(iter, loss))

        if self.verbose:
            print('Optimization finished!')

        self.fitted = True
        self.u_factors = u_factors
        self.i_factors = i_factors
        if self.use_bias:
            self.u_biases = u_biases
            self.i_biases = i_biases

    def score(self, user_id, item_id):
        """Predict the scores/ratings of a user for a list of items.

        Parameters
        ----------
        user_id: int, required
            The index of the user for whom to perform score predictions.

        item_id: int, required
            The index of the item to be scored by the user.

        Returns
        -------
        A scalar
            The estimated score (e.g., rating) for the user and item of interest
        """
        if not self.fitted:
            raise ValueError('You need to fit the model first!')

        unk_user = self.train_set.is_unk_user(user_id)
        unk_item = self.train_set.is_unk_item(item_id)

        if self.use_bias:
            score_pred = self.train_set.global_mean
            if not unk_user:
                score_pred += self.u_biases[user_id]
            if not unk_item:
                score_pred += self.i_biases[item_id]

            if not unk_user and not unk_item:
                score_pred += np.dot(self.u_factors[user_id], self.i_factors[item_id])
        else:
            if unk_user or unk_item:
                raise ScoreException("Can't make score prediction for (user_id=%d, item_id=%d)" % (user_id, item_id))

            score_pred = np.dot(self.u_factors[user_id], self.i_factors[item_id])

        return score_pred

    def rank(self, user_id, candidate_item_ids=None):
        """Rank all test items for a given user.

        Parameters
        ----------
        user_id: int, required
            The index of the user for whom to perform item raking.

        candidate_item_ids: 1d array, optional, default: None
            A list of item indices to be ranked by the user.
            If `None`, list of ranked known item indices will be returned

        Returns
        -------
        Numpy 1d array
            Array of item indices sorted (in decreasing order) relative to some user preference scores.
        """
        if not self.fitted:
            raise ValueError('You need to fit the model first!')

        if self.train_set.is_unk_user(user_id):
            if self.use_bias:
                known_item_scores = self.i_biases
            else:
                return self.default_rank(candidate_item_ids)
        else:
            known_item_scores = np.dot(self.i_factors, self.u_factors[user_id])

        if candidate_item_ids is None:
            ranked_item_ids = known_item_scores.argsort()[::-1]
            return ranked_item_ids
        else:
            num_items = max(self.train_set.num_items, max(candidate_item_ids) + 1)
            pref_scores = np.ones(num_items) * self.train_set.min_rating  # use min_rating to shift unk items to the end
            pref_scores[:self.train_set.num_items] = known_item_scores

            ranked_item_ids = pref_scores.argsort()[::-1]
            ranked_item_ids = intersects(ranked_item_ids, candidate_item_ids, assume_unique=True)

            return ranked_item_ids

# -*- coding: utf-8 -*-

"""
@author: Quoc-Tuan Truong <tuantq.vnu@gmail.com>
"""

from cornac.data import Module
import numpy as np

def test_init():
    md = Module()
    md.build(ordered_ids=None)
    assert md.data_feature is None

    id_feature = {'a': np.zeros(10)}
    md = Module(id_feature=id_feature, normalized=True)
    md.build(ordered_ids=['a'])

    assert md.data_feature.shape[0] == 1
    assert md.data_feature.shape[1] == 10
    assert md.feature_dim == 10
    assert len(md._id_feature) == 0


def test_batch_feature():
    id_feature = {'a': np.zeros(10)}
    md = Module(id_feature=id_feature, normalized=True)
    md.build(ordered_ids=['a'])

    b = md.batch_feature(batch_ids=[0])
    assert b.shape[0] == 1
    assert b.shape[1] == 10
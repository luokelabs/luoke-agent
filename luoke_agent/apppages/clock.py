# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 螺壳实验室 Luoke Labs
"""拼页时的「现在」（「今天 08:45」「昨天」、扫描的「本周」）。窗口的示例要钉住它：不然过一天示例就和重新生成的对不上"""
from __future__ import annotations

import datetime as dt
from typing import Optional

# 钉住的「现在」（本机时间，不带时区）；None 是真的现在
NOW: Optional[dt.datetime] = None


def now() -> dt.datetime:
    return NOW if NOW is not None else dt.datetime.now()


def utcnow() -> dt.datetime:
    """不带时区的 UTC 时间；钉住时当它就是 UTC"""
    return NOW if NOW is not None else dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)

"""搜索框的结果交给窗口之前怎么核（docs/界面接口.md §7）：缩略图看文件头认、读尺寸不解码。"""
from __future__ import annotations

import struct
import unittest

from luoke_agent import searchhits


def jpeg(width: int, height: int) -> bytes:
    app0 = b"\xff\xe0" + struct.pack(">H", 16) + b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    sof = b"\xff\xc0" + struct.pack(">HBHHB", 17, 8, height, width, 3) + b"\x01\x22\x00\x02\x11\x01\x03\x11\x01"
    return b"\xff\xd8" + app0 + sof + b"\xff\xd9"


def png(width: int, height: int) -> bytes:
    return b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", width, height) + b"\x08\x02\x00\x00\x00"


class ImageTest(unittest.TestCase):
    def test_sizes_from_the_header(self):
        self.assertEqual(searchhits.image_size(jpeg(400, 300)), ("image/jpeg", 400, 300))
        self.assertEqual(searchhits.image_size(png(300, 400)), ("image/png", 300, 400))
        for bad in (b"", b"GIF89a", b"\xff\xd8\xff", b"\xff\xd8\x00\x00", b"<svg/>"):
            self.assertIsNone(searchhits.image_size(bad), bad)

    def test_limits(self):
        self.assertEqual(searchhits.thumb_ok(jpeg(2048, 10)), "image/jpeg")
        self.assertIsNone(searchhits.thumb_ok(jpeg(2049, 10)), "长边超过 2048")
        self.assertIsNone(searchhits.thumb_ok(png(0, 10)))
        self.assertIsNone(searchhits.thumb_ok(jpeg(10, 10) + b"\x00" * searchhits.MAX_THUMB_BYTES), "超过 256 KB")


class HitsTest(unittest.TestCase):
    def test_limit_and_duplicates(self):
        raw = [{"id": str(i % 3), "title": f"第 {i} 条"} for i in range(10)]
        self.assertEqual([h["id"] for h in searchhits.hits(raw, 2)], ["0", "1"])
        self.assertEqual([h["title"] for h in searchhits.hits(raw, 10)], ["第 0 条", "第 1 条", "第 2 条"])
        self.assertEqual(searchhits.hits("junk", 10), [])

    def test_thumb_refs(self):
        for ok in ("thumb/12", "thumb/12-p3", "thumb/12-w2"):
            self.assertEqual(searchhits.hit({"id": "1", "title": "t", "thumb": ok})["thumb"], ok)
        for bad in ("thumb/../x", "thumb/", "http://x/thumb/1", "thumb/a b", "thumb/" + "1" * 65, 3, "thumb/12\n", "thumb/..", "thumb/."):
            self.assertNotIn("thumb", searchhits.hit({"id": "1", "title": "t", "thumb": bad}), bad)


if __name__ == "__main__":
    unittest.main()

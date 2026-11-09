"""agent 自己的状态库 `<数据目录>/state.db`（只有本用户能读）：事项的编号和状态、事项的内容和卡片、
设置、每类事项的反应。

内容存在本机（顶层 ADR 0013）：重启以后答完的卡片还在、[撤销] 还能点，以后的对话历史也从这里来。
日志里仍然只有编号、状态、时间。
"""
from __future__ import annotations

import json
import os
import sqlite3
import threading
from typing import Any, Dict, List, Optional

from .safety import refuse_real

SCHEMA = """
CREATE TABLE IF NOT EXISTS items (
  key TEXT PRIMARY KEY,         -- <来源>/<来源里的编号>
  source TEXT NOT NULL,
  kind TEXT NOT NULL,
  urgency TEXT NOT NULL,
  status TEXT NOT NULL,         -- queued 排着 / notified 说过了 / seen 在窗口里看过 / done 答了 / gone 撤回或过期
  outcome TEXT,                 -- answered / dismissed / withdrawn / expired
  first_seen REAL NOT NULL,
  notified_at REAL,
  done_at REAL,
  counted INTEGER NOT NULL DEFAULT 0   -- 说了没理，已经算进反应里
);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS reactions (
  category TEXT PRIMARY KEY,    -- <来源>:<类别>
  shown INTEGER NOT NULL DEFAULT 0,
  answered INTEGER NOT NULL DEFAULT 0,
  ignored INTEGER NOT NULL DEFAULT 0,
  streak INTEGER NOT NULL DEFAULT 0   -- 连着几次说了没理
);
CREATE TABLE IF NOT EXISTS put_off (key TEXT PRIMARY KEY, until REAL NOT NULL);   -- 不再用（10-20 起"以后再说"由记忆定）
CREATE TABLE IF NOT EXISTS contents (
  key TEXT PRIMARY KEY,         -- 和 items 同一个编号
  sid TEXT NOT NULL,            -- agent 这边的卡片编号
  item TEXT NOT NULL,           -- 事项本身（JSON：标题、摘要、来源的卡片、extra）
  surface TEXT,                 -- 卡片现在的样子（A2UI 新建消息，JSON；答完以后是结果）
  kept INTEGER NOT NULL DEFAULT 0,     -- 答完了、卡片还留在窗口里（重启后照样画出来）
  done_at REAL
);
"""

DEFAULTS: Dict[str, Any] = {
    "proactive": True,          # 主动提醒：关了就不发简报和通知，窗口照旧
    "brief": "morning",         # 简报：morning 每天早上 / twice 早晚各一次 / on_open 只在我打开时（2026-11-03 主窗口第一版）；
                                # every 是开发用的「攒满 brief_minutes 就发」（--brief-minutes）
    "brief_minutes": 60,
    "quiet": {"start": "22:00", "end": "08:00"},   # 免打扰时段，用户能改、能关（None）
    "paused_until": None,       # 暂停提醒到什么时候（时间戳）；菜单栏图标的「暂停提醒一小时」
    "modes": {},                # 每类怎么说：now / brief / window / off；没写的按急不急
    "away_seconds": 180,        # 空闲多久算不在 Mac 前
    "ignore_limit": 3,          # 连着几次没理就只放窗口
}


class State:
    def __init__(self, home: str):
        refuse_real(home, "数据目录")
        os.makedirs(home, mode=0o700, exist_ok=True)
        self.path = os.path.join(home, "state.db")
        if not os.path.exists(self.path):
            os.close(os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600))
        self._lock = threading.RLock()
        self.db = sqlite3.connect(self.path, check_same_thread=False, timeout=10)
        self.db.row_factory = sqlite3.Row
        with self.db:
            self.db.executescript(SCHEMA)

    def close(self) -> None:
        self.db.close()

    # 事项

    def item(self, key: str) -> Optional[dict]:
        with self._lock:
            row = self.db.execute("SELECT * FROM items WHERE key=?", (key,)).fetchone()
        return dict(row) if row else None

    def remember(self, key: str, source: str, kind: str, urgency: str, now: float) -> dict:
        """第一次见到就记下（排着）；见过的更新急不急，返回记下的那条。"""
        with self._lock, self.db:
            self.db.execute(
                "INSERT INTO items (key, source, kind, urgency, status, first_seen) VALUES (?,?,?,?, 'queued', ?)"
                " ON CONFLICT(key) DO UPDATE SET urgency=excluded.urgency", (key, source, kind, urgency, now))
        return self.item(key)  # type: ignore[return-value]

    def set_status(self, key: str, status: str, now: float, outcome: Optional[str] = None) -> None:
        with self._lock, self.db:
            if status == "notified":
                self.db.execute("UPDATE items SET status='notified', notified_at=? WHERE key=? AND status='queued'",
                                (now, key))
            elif status == "seen":
                self.db.execute("UPDATE items SET status='seen' WHERE key=? AND status IN ('queued','notified')", (key,))
            else:
                self.db.execute("UPDATE items SET status=?, outcome=?, done_at=? WHERE key=? AND status NOT IN ('done','gone')",
                                (status, outcome, now, key))

    def open_items(self) -> List[dict]:
        with self._lock:
            return [dict(r) for r in self.db.execute("SELECT * FROM items WHERE status NOT IN ('done','gone')")]

    def notified_unseen(self) -> List[dict]:
        """通知过、用户一直没打开窗口看、也还没算进反应的。"""
        with self._lock:
            return [dict(r) for r in self.db.execute("SELECT * FROM items WHERE status='notified' AND counted=0")]

    def mark_counted(self, key: str) -> None:
        with self._lock, self.db:
            self.db.execute("UPDATE items SET counted=1 WHERE key=?", (key,))

    def mark_batch_counted(self, row: dict) -> bool:
        """把同一次说的同一类都算进反应：一次没理只算一次（DESIGN §5"连着三次"按次数，不按件数）。这一次已经算过返回 False。"""
        with self._lock, self.db:
            cur = self.db.execute("UPDATE items SET counted=1 WHERE source=? AND kind=? AND notified_at=? AND counted=0",
                                  (row["source"], row["kind"], row["notified_at"]))
        return cur.rowcount > 0

    def revive(self, key: str) -> None:
        """撤下过的又列出来了（工具或记忆重启时清单短暂是空的）：回到撤下之前，说过的不再说。"""
        with self._lock, self.db:
            self.db.execute("UPDATE items SET status=CASE WHEN notified_at IS NULL THEN 'queued' ELSE 'notified' END,"
                            " outcome=NULL, done_at=NULL WHERE key=? AND status='gone' AND outcome='withdrawn'", (key,))

    def forget_old(self, before: float) -> None:
        """答完、撤回很久的不用留着。"""
        with self._lock, self.db:
            self.db.execute("DELETE FROM items WHERE status IN ('done','gone') AND done_at < ?", (before,))
            self.db.execute("DELETE FROM put_off WHERE until < ?", (before,))
            self.db.execute("DELETE FROM contents WHERE key NOT IN (SELECT key FROM items)")

    # 内容

    def save_content(self, key: str, sid: str, item: dict, surface: Optional[List[dict]],
                     done_at: Optional[float] = None) -> None:
        """记下事项的内容和卡片现在的样子；`done_at` 给了就是答完了、卡片留着。"""
        with self._lock, self.db:
            self.db.execute(
                "INSERT INTO contents (key, sid, item, surface, kept, done_at) VALUES (?,?,?,?,?,?)"
                " ON CONFLICT(key) DO UPDATE SET sid=excluded.sid, item=excluded.item, surface=excluded.surface,"
                " kept=excluded.kept, done_at=COALESCE(excluded.done_at, contents.done_at)",
                (key, sid, json.dumps(item, ensure_ascii=False),
                 None if surface is None else json.dumps(surface, ensure_ascii=False), int(done_at is not None), done_at))

    def unkeep(self, key: str) -> None:
        """卡片从窗口里收走了：内容留着当历史，重启时不再画。"""
        with self._lock, self.db:
            self.db.execute("UPDATE contents SET kept=0 WHERE key=?", (key,))

    def kept_contents(self, since: float) -> List[dict]:
        """答完、卡片还留着的（`since` 以后答的），重启时画回去。"""
        with self._lock:
            rows = self.db.execute("SELECT * FROM contents WHERE kept=1 AND done_at >= ? ORDER BY done_at", (since,))
            out = []
            for r in rows:
                d = dict(r)
                d["item"] = json.loads(d["item"])
                d["surface"] = json.loads(d["surface"]) if d["surface"] else None
                out.append(d)
            return out

    def content(self, key: str) -> Optional[dict]:
        with self._lock:
            row = self.db.execute("SELECT * FROM contents WHERE key=?", (key,)).fetchone()
        if not row:
            return None
        d = dict(row)
        d["item"] = json.loads(d["item"])
        d["surface"] = json.loads(d["surface"]) if d["surface"] else None
        return d

    # 设置和小记

    def setting(self, key: str) -> Any:
        with self._lock:
            row = self.db.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
        return json.loads(row["value"]) if row else DEFAULTS.get(key)

    def set_setting(self, key: str, value: Any) -> None:
        with self._lock, self.db:
            self.db.execute("INSERT OR REPLACE INTO settings (key, value) VALUES (?,?)", (key, json.dumps(value)))

    def meta(self, key: str, default: Any = None) -> Any:
        with self._lock:
            row = self.db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return json.loads(row["value"]) if row else default

    def set_meta(self, key: str, value: Any) -> None:
        with self._lock, self.db:
            if value is None:
                self.db.execute("DELETE FROM meta WHERE key=?", (key,))
            else:
                self.db.execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?,?)", (key, json.dumps(value)))

    def categories(self) -> List[dict]:
        """出现过的每一类（来源 × 类别），带见过的最急的一档：设置里「每类事怎么说」列它们。"""
        with self._lock:
            rows = self.db.execute("SELECT source, kind, MIN(CASE urgency WHEN 'urgent' THEN 0 WHEN 'normal' THEN 1 ELSE 2 END)"
                                   " AS rank FROM items WHERE source != 'agent' GROUP BY source, kind ORDER BY source, kind")
            return [{"source": r[0], "kind": r[1], "urgent": r[2] == 0} for r in rows]

    # 用户的反应

    def react(self, category: str, how: str) -> int:
        """`how`：shown 说了 / answered 答了 / ignored 说了没理 / reset 用户说照旧提醒。返回连着没理的次数。"""
        with self._lock, self.db:
            self.db.execute("INSERT OR IGNORE INTO reactions (category) VALUES (?)", (category,))
            if how == "shown":
                self.db.execute("UPDATE reactions SET shown=shown+1 WHERE category=?", (category,))
            elif how == "answered":
                self.db.execute("UPDATE reactions SET answered=answered+1, streak=0 WHERE category=?", (category,))
            elif how == "ignored":
                self.db.execute("UPDATE reactions SET ignored=ignored+1, streak=streak+1 WHERE category=?", (category,))
            elif how == "reset":
                self.db.execute("UPDATE reactions SET streak=0 WHERE category=?", (category,))
            row = self.db.execute("SELECT streak FROM reactions WHERE category=?", (category,)).fetchone()
        return row["streak"]

#!/usr/bin/env python3
"""The made-up content of the scene that scripts/showcase.sh opens.

    showcase.py pi-sessions DIR HOME
        Writes the pi sessions of the scene into DIR, one JSONL file per
        project, for projects under HOME/code.

    showcase.py screen NAME [STATUS]
        Draws the still screen of a stand-in agent and waits until it is
        killed. showcase.sh starts it under the agent's name, such as
        claude, so that the dashboard detects it as that agent. With STATUS,
        it reports the status with OSC 7501, as real agents do in zellij.

    showcase.py log
        Prints the log of a web server and waits.

    showcase.py background
        Prints "dark" or "light" after the background color of the
        terminal, or fails when the terminal does not tell it.

SHOWCASE_THEME=light picks colors for a light terminal background.
"""

from __future__ import annotations

import json
import os
import re
import select
import signal
import sys
import termios
import time
import tty
import unicodedata
import zlib
from typing import Callable

# ---------------------------------------------------------------- pi sessions

MINUTE = 60_000


class PiSession:
    """Builds a pi session file: a header line, then one message entry per
    line, each the child of the one before it."""

    def __init__(self, cwd: str, provider: str, model: str, minutes_ago: int):
        self.provider, self.model = provider, model
        self.clock = int(time.time() * 1000) - minutes_ago * MINUTE
        self.entries: list[dict] = [
            {
                "type": "session",
                "version": 3,
                "id": f"{zlib.crc32(cwd.encode()):08x}-7a1b-4c2d-9e3f-0a1b2c3d4e5f",
                "timestamp": self.iso(self.clock),
                "cwd": cwd,
            }
        ]
        self.parent: str | None = None
        self.calls = 0
        self.cache = 18_000

    @staticmethod
    def iso(ms: int) -> str:
        seconds = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ms / 1000))
        return f"{seconds}.{ms % 1000:03d}Z"

    def add(self, message: dict, seconds: int) -> None:
        self.clock += seconds * 1000
        message["timestamp"] = self.clock
        entry_id = f"{len(self.entries):08x}"
        self.entries.append(
            {
                "type": "message",
                "id": entry_id,
                "parentId": self.parent,
                "timestamp": self.iso(self.clock),
                "message": message,
            }
        )
        self.parent = entry_id

    def user(self, text: str) -> None:
        self.add({"role": "user", "content": text}, 5)

    def assistant(
        self,
        text: str = "",
        thinking: str = "",
        tools: tuple[tuple[str, dict], ...] = (),
        seconds: int = 20,
    ) -> list[str]:
        """An assistant message; returns the ids of its tool calls."""
        content: list[dict] = []
        if thinking:
            content.append({"type": "thinking", "thinking": thinking})
        if text:
            content.append({"type": "text", "text": text})
        ids = []
        for name, args in tools:
            self.calls += 1
            call_id = f"toolu_{self.calls:02d}{zlib.crc32(name.encode()):010d}"
            ids.append(call_id)
            content.append(
                {"type": "toolCall", "id": call_id, "name": name, "arguments": args}
            )
        self.cache += 3_400
        out = 180 + 37 * len(text) // 10
        usage = {
            "input": 1_900,
            "output": out,
            "cacheRead": self.cache,
            "cacheWrite": 2_100,
            "totalTokens": 1_900 + out + self.cache + 2_100,
            "cost": {
                "input": 0.0095,
                "output": out * 0.000025,
                "cacheRead": self.cache * 0.0000005,
                "cacheWrite": 0.013,
                "total": 0.0225 + out * 0.000025 + self.cache * 0.0000005,
            },
        }
        self.add(
            {
                "role": "assistant",
                "content": content,
                "api": (
                    "anthropic-messages"
                    if self.provider == "anthropic"
                    else "openai-responses"
                ),
                "provider": self.provider,
                "model": self.model,
                "usage": usage,
                "stopReason": "toolUse" if tools else "stop",
            },
            seconds,
        )
        return ids

    def result(
        self, call_id: str, name: str, text: str, details: dict | None = None
    ) -> None:
        message: dict = {
            "role": "toolResult",
            "toolCallId": call_id,
            "toolName": name,
            "content": [{"type": "text", "text": text}],
            "isError": False,
        }
        if details:
            message["details"] = details
        self.add(message, 3)

    def tool(self, name: str, args: dict, output: str, text: str = "", **kw) -> None:
        """An assistant message with one tool call, and its result."""
        details = kw.pop("details", None)
        (call_id,) = self.assistant(text=text, tools=((name, args),), **kw)
        self.result(call_id, name, output, details)

    def write(self, path: str) -> None:
        with open(path, "w", encoding="utf-8") as f:
            f.writelines(json.dumps(entry) + "\n" for entry in self.entries)


def diff(*lines: str) -> str:
    """A diff as pi's edit tool shows it: a mark, a line number and the line.
    Each argument is "MARK NUMBER TEXT" or "..." for skipped lines."""
    width = max(len(line.split(" ", 2)[1]) for line in lines if line != "...")
    out = []
    for line in lines:
        if line == "...":
            out.append(" " * (width + 1) + " ...")
            continue
        mark, number, text = (line.split(" ", 2) + [""])[:3]
        out.append(f"{mark.replace('=', ' ')}{number.rjust(width)} {text}")
    return "\n".join(out)


ORDERS_PY = """\
from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.db import get_db
from app.models import Customer, Order, OrderItem
from app.schemas import OrderOut

router = APIRouter()
PAGE_SIZE = 50


@router.get("/orders", response_model=list[OrderOut])
async def list_orders(page: int = 1, db: Session = Depends(get_db)):
    orders = (
        db.query(Order)
        .order_by(Order.created_at.desc())
        .offset((page - 1) * PAGE_SIZE)
        .limit(PAGE_SIZE)
        .all()
    )
    for order in orders:
        order.items = db.query(OrderItem).filter_by(order_id=order.id).all()
        order.customer = db.query(Customer).get(order.customer_id)
    return orders
"""

ORDERS_TEST = """\
from tests.helpers import count_queries, make_orders


def test_list_orders_runs_a_fixed_number_of_queries(client, db):
    make_orders(db, count=50, items_per_order=3)
    with count_queries(db) as queries:
        response = client.get("/orders")
    assert response.status_code == 200
    assert len(response.json()) == 50
    assert len(queries) <= 3
"""

UPLOADER_PY = """\
import logging

import boto3
from botocore.exceptions import ClientError

log = logging.getLogger(__name__)


def upload_part(bucket: str, key: str, body: bytes) -> None:
    client = boto3.client("s3")
    client.put_object(Bucket=bucket, Key=key, Body=body)
    log.info("uploaded %s (%d bytes)", key, len(body))
"""


def shop_api_session(home: str) -> PiSession:
    """pi, at work on a slow endpoint."""
    s = PiSession(f"{home}/code/shop-api", "anthropic", "claude-opus-5-5", 26)
    s.user(
        "GET /orders takes about 4 seconds on staging. Find out why, fix it, "
        "and add a test so that it does not come back."
    )
    s.tool(
        "bash",
        {"command": "rg -n 'orders' app/routes --type py | head"},
        'app/routes/orders.py:12:@router.get("/orders", response_model=list[OrderOut])\n'
        "app/routes/orders.py:13:async def list_orders(page: int = 1, db: Session = Depends(get_db)):\n"
        'app/routes/orders.py:27:@router.get("/orders/{order_id}", response_model=OrderOut)',
        text="I'll start with the route and the queries it runs.",
        thinking="A slow list endpoint usually means a query problem. "
        "Check the route first, then count the queries.",
    )
    s.tool("read", {"path": "app/routes/orders.py"}, ORDERS_PY)
    s.tool(
        "bash",
        {"command": "SQL_ECHO=1 python -m scripts.hit /orders 2>&1 | grep -c SELECT"},
        "101",
        text="The loop runs two queries for each order, so one page of 50 orders "
        "makes **101 queries**. I'll confirm it with the SQL log before I "
        "change anything.",
    )
    s.tool(
        "edit",
        {
            "path": "app/routes/orders.py",
            "oldText": "    for order in orders:\n",
            "newText": "",
        },
        "Successfully replaced 2 block(s) in app/routes/orders.py.",
        text="101 queries, as expected. I'll load the items and the customer "
        "together with the page instead.",
        details={
            "diff": diff(
                "= 1 from fastapi import APIRouter, Depends",
                "- 2 from sqlalchemy.orm import Session",
                "+ 2 from sqlalchemy.orm import Session, joinedload, selectinload",
                "= 3 ",
                "...",
                "= 14     orders = (",
                "= 15         db.query(Order)",
                "+ 16         .options(selectinload(Order.items), joinedload(Order.customer))",
                "= 17         .order_by(Order.created_at.desc())",
                "= 18         .offset((page - 1) * PAGE_SIZE)",
                "= 19         .limit(PAGE_SIZE)",
                "= 20         .all()",
                "= 21     )",
                "- 21     for order in orders:",
                "- 22         order.items = db.query(OrderItem).filter_by(order_id=order.id).all()",
                "- 23         order.customer = db.query(Customer).get(order.customer_id)",
                "= 22     return orders",
            )
        },
    )
    s.tool(
        "bash",
        {"command": "SQL_ECHO=1 python -m scripts.hit /orders 2>&1 | grep -c SELECT"},
        "2",
    )
    s.tool(
        "write",
        {"path": "tests/test_orders_queries.py", "content": ORDERS_TEST},
        "Successfully wrote 371 bytes to tests/test_orders_queries.py",
        text="Down to 2 queries. Now a test that fails when the number of "
        "queries grows with the page size.",
    )
    s.tool(
        "bash",
        {"command": "pytest tests/test_orders.py tests/test_orders_queries.py -q"},
        "...........                                                    [100%]\n"
        "11 passed in 1.84s",
    )
    s.tool(
        "bash",
        {"command": "python -m scripts.bench /orders --compare main --runs 200"},
        "GET /orders   runs=200\n"
        "  main     p50  4182 ms   p95  4630 ms\n"
        "  HEAD     p50    41 ms   p95    67 ms",
        seconds=50,
    )
    s.tool(
        "bash",
        {"command": "rg -n -U 'for \\w+ in \\w+:\\n\\s+.*db\\.query' app/routes"},
        "app/routes/invoices.py:24:    for invoice in invoices:\n"
        "app/routes/invoices.py:25:        invoice.lines = db.query(InvoiceLine).filter_by(invoice_id=invoice.id).all()",
        text="The p50 latency drops from 4.2 s to 41 ms. Other list endpoints "
        "may loop the same way, so I'll look for the pattern in the rest "
        "of the routes.",
    )
    s.assistant(
        text="`/invoices` has the same problem. I'll fix it the same way and "
        "give it a query count test too.",
        tools=(("read", {"path": "app/routes/invoices.py"}),),
    )
    return s


def data_pipeline_session(home: str) -> PiSession:
    """pi, done with a fix."""
    s = PiSession(f"{home}/code/data-pipeline", "openai", "gpt-5.3-codex", 48)
    s.user(
        "The nightly export to S3 fails about once a week with SlowDown "
        "errors. Retry with backoff, and log each retry."
    )
    s.tool(
        "read",
        {"path": "pipeline/export/s3_uploader.py"},
        UPLOADER_PY,
        text="I'll read the uploader first.",
    )
    s.tool(
        "bash",
        {"command": "rg -n 'SlowDown' logs/export-*.log | tail -3"},
        "logs/export-2026-11-02.log:4113:ClientError: An error occurred (SlowDown) when calling the PutObject operation\n"
        "logs/export-2026-11-09.log:3987:ClientError: An error occurred (SlowDown) when calling the PutObject operation\n"
        "logs/export-2026-11-14.log:4420:ClientError: An error occurred (SlowDown) when calling the PutObject operation",
    )
    s.tool(
        "edit",
        {"path": "pipeline/export/s3_uploader.py", "oldText": "", "newText": ""},
        "Successfully replaced 2 block(s) in pipeline/export/s3_uploader.py.",
        text="`upload_part` calls `put_object` once, and any `ClientError` ends "
        "the run. S3 answers `SlowDown` when we send requests too fast, and "
        "that error is safe to retry.",
        details={
            "diff": diff(
                "= 7 log = logging.getLogger(__name__)",
                '+ 8 RETRYABLE = {"SlowDown", "RequestTimeout", "InternalError"}',
                "+ 9 MAX_ATTEMPTS = 5",
                "...",
                "= 12 def upload_part(bucket: str, key: str, body: bytes) -> None:",
                '= 13     client = boto3.client("s3")',
                "- 14     client.put_object(Bucket=bucket, Key=key, Body=body)",
                "+ 14     for attempt in range(1, MAX_ATTEMPTS + 1):",
                "+ 15         try:",
                "+ 16             client.put_object(Bucket=bucket, Key=key, Body=body)",
                "+ 17             break",
                "+ 18         except ClientError as err:",
                '+ 19             code = err.response["Error"]["Code"]',
                "+ 20             if code not in RETRYABLE or attempt == MAX_ATTEMPTS:",
                "+ 21                 raise",
                "+ 22             delay = min(30, 2**attempt) + random.uniform(0, 1)",
                '+ 23             log.warning("%s on %s, retry %d in %.1fs", code, key, attempt, delay)',
                "+ 24             time.sleep(delay)",
                '= 25     log.info("uploaded %s (%d bytes)", key, len(body))',
            )
        },
    )
    s.tool(
        "bash",
        {"command": "pytest tests/export -q"},
        "..............                                                 [100%]\n"
        "14 passed in 2.31s",
        text="I added two tests: one where S3 answers SlowDown twice and then "
        "succeeds, and one where it never succeeds.",
    )
    s.assistant(
        text="Done. The uploader now retries `SlowDown`, `RequestTimeout` and "
        "`InternalError` up to 5 times, with exponential backoff and jitter "
        "capped at 30 s.\n\n"
        "- Each retry logs a warning with the key, the attempt and the delay.\n"
        "- After the last attempt the error still raises, so the job fails "
        "loudly as before.\n"
        "- `test_upload_retries_on_slowdown` and "
        "`test_upload_gives_up_after_five_attempts` cover both paths. All 14 "
        "export tests pass.",
        seconds=30,
    )
    return s


PI_SESSIONS: dict[str, Callable[[str], PiSession]] = {
    "shop-api": shop_api_session,
    "data-pipeline": data_pipeline_session,
}


# ---------------------------------------------------------------- screens

LIGHT = os.environ.get("SHOWCASE_THEME") == "light"

# Named colors, for a dark and a light terminal background.
COLORS = {
    "claude": ("#d77757", "#b85a3c"),
    "muted": ("#8a8a8a", "#6e6e6e"),
    "text": ("#e6e6e6", "#1f1f1f"),
    "green": ("#4eba65", "#2f8a43"),
    "red": ("#ff6b80", "#c22f45"),
    "blue": ("#7aa2f7", "#2f5fc4"),
    "cyan": ("#56b6c2", "#1f7f8c"),
    "violet": ("#b48ead", "#8a4f9e"),
    "yellow": ("#e5c07b", "#9a6a00"),
    "add": ("on#1f3d26", "on#d6f5dc"),
    "del": ("on#4a1f27", "on#fbdde2"),
    "box": ("#5c5c5c", "#b0b0b0"),
    "gemini": ("#8ab4f8", "#1a5fd0"),
    "opencode": ("#fab283", "#c2652a"),
}
ATTRS = {"b": "1", "d": "2", "i": "3", "u": "4"}
MARKUP_RE = re.compile(r"«([^»]*)»")


def sgr(spec: str) -> str:
    """The SGR sequence of a style such as "b claude" or "on#1f3d26"."""
    codes = []
    for word in spec.split():
        if word in ATTRS:
            codes.append(ATTRS[word])
            continue
        if word in COLORS:
            word = COLORS[word][LIGHT]
        bg = word.startswith("on#")
        h = word[3:] if bg else word.lstrip("#")
        r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
        codes.append(f"{48 if bg else 38};2;{r};{g};{b}")
    return f"\x1b[0;{';'.join(codes)}m" if codes else "\x1b[0m"


def cells(ch: str) -> int:
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def visible(line: str) -> int:
    return sum(cells(c) for c in MARKUP_RE.sub("", line))


def render(line: str, width: int) -> str:
    """A line of markup as terminal text, cut to width. «style» starts a
    style and «» ends it."""
    out, used = [], 0
    for i, part in enumerate(MARKUP_RE.split(line)):
        if i % 2:
            out.append(sgr(part))
            continue
        for ch in part:
            w = cells(ch)
            if used + w > width:
                return "".join(out) + "\x1b[0m"
            out.append(ch)
            used += w
    return "".join(out) + "\x1b[0m"


def pad(line: str, width: int) -> str:
    return line + " " * max(0, width - visible(line))


def box(lines: list[str], width: int, color: str = "box", inset: int = 0) -> list[str]:
    """Lines in a rounded box as wide as width, inset by some columns."""
    inner = width - inset - 4
    left = " " * inset
    out = [f"{left}«{color}»╭{'─' * (inner + 2)}╮«»"]
    for line in lines:
        out.append(f"{left}«{color}»│«» {pad(line, inner)} «{color}»│«»")
    out.append(f"{left}«{color}»╰{'─' * (inner + 2)}╯«»")
    return out


def code_lines(mark: str, lines: list[tuple[int, str]], width: int) -> list[str]:
    """Diff lines as Claude Code shows them, with a full-width background."""
    style = {"+": "add", "-": "del"}
    out = []
    for number, text in lines:
        body = f"{number:>6} {mark} {text}" if mark != " " else f"{number:>6}   {text}"
        if mark in style:
            out.append(f"«{style[mark]}»{pad(body, width - 1)}«»")
        else:
            out.append(f"«muted»{body}«»")
    return out


Screen = tuple[list[str], list[str]]


def claude_web(w: int) -> Screen:
    """Claude Code, at work on a form."""
    body = [
        "«muted»>«» Redesign the checkout form: one column, inline validation,",
        "  and keep the analytics events we send today.",
        "",
        "«text»⏺«» I'll read the form and its tests first, then make the changes",
        "  one step at a time.",
        "",
        "«green»⏺«» «b»Read«»(src/checkout/CheckoutForm.tsx)",
        "  «muted»⎿  Read 212 lines«»",
        "",
        '«green»⏺«» «b»Search«»(pattern: "trackCheckout", path: "src")',
        "  «muted»⎿  Found 4 files«»",
        "",
        "«green»⏺«» «b»Update«»(src/checkout/CheckoutForm.tsx)",
        "  «muted»⎿  Updated «b»src/checkout/CheckoutForm.tsx«»«muted» with 14 additions and 23 removals«»",
    ]
    body += code_lines(" ", [(46, "return (")], w)
    body += code_lines("-", [(47, '  <form className="grid grid-cols-2 gap-6">')], w)
    body += code_lines(
        "+", [(47, '  <form className="flex flex-col gap-4" noValidate>')], w
    )
    body += code_lines(
        " ", [(48, "    <AddressFields value={address} onChange={setAddress} />")], w
    )
    body += code_lines(
        "+",
        [(49, '    <FieldError name="postcode" error={errors.postcode} />')],
        w,
    )
    body += [
        "",
        "«green»⏺«» «b»Bash«»(npm test -- checkout)",
        "  «muted»⎿«»  «green»PASS«» src/checkout/CheckoutForm.test.tsx «muted»(14 tests)«»",
        "     «green»PASS«» src/checkout/validation.test.ts «muted»(9 tests)«»",
        "",
        "«green»⏺«» «b»Update Todos«»",
        "  «muted»⎿«»  «muted»☒ Switch the form to one column«»",
        "     «muted»☒ Validate card number and postcode as the user types«»",
        "     ☐ Send trackCheckout on each step",
        "     ☐ Update the Storybook story",
        "",
        "«claude»✶ Wiring the analytics events… «»«muted»(3m 12s · ↓ 7.4k tokens · esc to interrupt)«»",
        "",
    ]
    footer = box(["«text»>«» "], w)
    footer += ["  «violet»⏵⏵ accept edits on«» «muted»(shift+tab to cycle)«»"]
    return body, footer


def claude_infra(w: int) -> Screen:
    """Claude Code, waiting for permission to run a command."""
    body = [
        "«muted»>«» Move the staging database to db.r6g.xlarge and apply it.",
        "",
        "«green»⏺«» «b»Read«»(envs/staging/rds.tf)",
        "  «muted»⎿  Read 64 lines«»",
        "",
        "«green»⏺«» «b»Update«»(envs/staging/rds.tf)",
        "  «muted»⎿  Updated «b»envs/staging/rds.tf«»«muted» with 1 addition and 1 removal«»",
    ]
    body += code_lines("-", [(12, '  instance_class    = "db.r6g.large"')], w)
    body += code_lines("+", [(12, '  instance_class    = "db.r6g.xlarge"')], w)
    body += [
        "",
        "«green»⏺«» «b»Bash«»(terraform plan -out=staging.plan)",
        "  «muted»⎿«»  «yellow»~«» aws_db_instance.main will be updated in-place",
        '       «yellow»~«» instance_class = "db.r6g.large" -> "db.r6g.xlarge"',
        "     «b»Plan:«» 0 to add, 1 to change, 0 to destroy.",
        "",
        "«text»⏺«» The plan changes only the instance class. Applying it restarts",
        "  the database, which takes about 5 minutes on staging.",
        "",
    ]
    footer = box(
        [
            "«b»Bash command«»",
            "",
            "  terraform apply staging.plan",
            "  «muted»Apply the planned change to the staging database«»",
            "",
            "Do you want to proceed?",
            "«claude»❯ 1. Yes«»",
            "  2. Yes, and don't ask again for «b»terraform apply«» commands",
            "  3. No, and tell Claude what to do differently «muted»(esc)«»",
        ],
        w,
        "claude",
    )
    return body, footer


def codex_review(w: int) -> Screen:
    """Codex, done with a review."""
    body = box(
        [
            "«b»>_ OpenAI Codex«» «muted»(v0.98.0)«»",
            "",
            "«muted»model:«»     gpt-5.3-codex high   «cyan»/model«» «muted»to change«»",
            "«muted»directory:«» ~/code/shop-api",
        ],
        min(w, 64),
    ) + [
        "",
        "«b»›«» Review the diff on this branch. Look for bugs and missing tests.",
        "",
        "«muted»•«» «b»Ran«» git diff main...HEAD --stat",
        "  «muted»└«» app/routes/orders.py         |  9 «green»++«»«red»-------«»",
        "    tests/test_orders_queries.py | 11 «green»+++++++++++«»",
        "",
        "«muted»•«» «b»Explored«»",
        "  «muted»└«» «cyan»Read«» orders.py, models.py, test_orders_queries.py",
        "    «cyan»Search«» selectinload in app",
        "",
        "«muted»•«» The fix is correct: the page now loads in 2 queries, whatever",
        "  the page size. Two notes:",
        "",
        "  1. «b»app/routes/orders.py:16«» `joinedload(Order.customer)` repeats the",
        "     customer columns on every row. With 50 rows that is fine.",
        "  2. «b»tests/test_orders_queries.py:9«» The limit of 3 queries allows one",
        "     more than needed. `== 2` would catch a regression sooner.",
        "",
        "  No blocking issues.",
        "",
        "«muted»─ Worked for 1m 52s ─" + "─" * max(0, w - 21) + "«»",
        "",
    ]
    footer = [
        "«b»›«» «muted»Ask Codex to do anything«»",
        "",
        "  «muted»⏎ send   ⇧⏎ newline   ⌃T transcript   ⌃C quit   84% context left«»",
    ]
    return body, footer


def opencode_mobile(w: int) -> Screen:
    """opencode, idle after an answer."""
    bar = "«opencode»┃«»"
    body = [
        "",
        f"  {bar}  Why does the release build crash on launch on iOS 16,",
        f"  {bar}  but not on iOS 17?",
        "",
        "     I'll look at the crash report and how the app links its frameworks.",
        "",
        "     «muted»→«» «b»Read«» crash/App-2.4.0-ios16.ips",
        '     «muted»→«» «b»Grep«» "import TipKit" «muted»in«» ios',
        "     «muted»$«» xcodebuild -showBuildSettings | grep OTHER_LDFLAGS",
        "       «muted»OTHER_LDFLAGS = -framework TipKit«»",
        "",
        "     The crash is «b»dyld: Library not loaded: TipKit.framework«».",
        "     TipKit exists only on iOS 17, and the app links it as a required",
        "     framework, so iOS 16 cannot start the app at all.",
        "",
        "     «b»Fix:«»",
        "     1. Link TipKit as optional: «cyan»-weak_framework TipKit«».",
        "     2. Wrap the tips in «cyan»if #available(iOS 17, *)«», in",
        "        «b»OnboardingView.swift«» and «b»SettingsView.swift«».",
        "",
        "     I can make both changes and run the app on the iOS 16 simulator.",
        "",
        "     «muted»▣ Build · claude-sonnet-5-5 · 41s«»",
        "",
    ]
    footer = box(["«opencode»>«» "], w, "opencode", inset=2) + [
        "",
        "  «opencode»Build«»  «muted»claude-sonnet-5-5 Anthropic«»"
        + " " * max(1, w - 64)
        + "«muted»tab agents  ctrl+p commands«»",
    ]
    return body, footer


def agy_docs(w: int) -> Screen:
    """Antigravity, at work on a guide."""
    inner = w - 6
    body = [
        "«gemini»>«» Write a guide for the new streaming API in docs/guides/streaming.md,",
        "  with an example in Python and in TypeScript.",
        "",
        "«gemini»✦«» I'll read the API reference and the other guides, to match",
        "  their style.",
        "",
    ]
    body += box(
        [
            "«green»✓«»  «b»ReadFile«» docs/reference/streaming.md",
            "«green»✓«»  «b»ReadFile«» docs/guides/batching.md",
            "«green»✓«»  «b»FindFiles«» examples/**/stream*  «muted»→ 6 files«»",
        ],
        w,
    )
    body += box(
        [
            "«green»✓«»  «b»WriteFile«» docs/guides/streaming.md",
            "",
            "«muted» 1«» # Streaming responses",
            "«muted» 2«»",
            "«muted» 3«» A streamed response sends each part as soon as it is ready,",
            "«muted» 4«» so the reader sees the first words within a few hundred",
            "«muted» 5«» milliseconds instead of waiting for the whole answer.",
            "«muted» 6«»",
            "«muted» 7«» ## Python",
            "«muted»  «» «muted»… 58 more lines«»",
        ][: max(3, inner)],
        w,
    )
    body += [
        "",
        "«gemini»✦«» The guide is written. I'll run both examples against the",
        "  sandbox API to check that they work as shown.",
        "",
        "«gemini»⠏«» «b»Running the examples«» «muted»(esc to cancel, 1m 12s)«»",
        "",
    ]
    footer = box(
        ["«gemini»>«»   «muted»Type your message or @path/to/file«»"], w, "gemini"
    )
    left = "«blue»~/code/docs«» «violet»(docs/streaming-guide*)«»"
    right = "«muted»gemini-3-pro«» «muted»(92% context left)«»"
    footer.append(left + " " * max(1, w - visible(left) - visible(right)) + right)
    return body, footer


SCREENS: dict[str, Callable[[int], Screen]] = {
    "claude-web": claude_web,
    "claude-infra": claude_infra,
    "codex-review": codex_review,
    "opencode-mobile": opencode_mobile,
    "agy-docs": agy_docs,
}


def draw(name: str) -> None:
    cols, rows = os.get_terminal_size(sys.stdout.fileno())
    body, footer = SCREENS[name](cols)
    gap = max(0, rows - len(body) - len(footer))
    lines = (body + [""] * gap + footer)[-rows:]
    out = ["\x1b[H\x1b[2J"]
    out.append("\r\n".join(render(line, cols) for line in lines))
    sys.stdout.write("".join(out))
    sys.stdout.flush()


def show(name: str, status: str) -> None:
    """Draws the screen, redraws it when the terminal resizes, and swallows
    every key, so that typing in the pane changes nothing."""
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    tty.setraw(fd)
    sys.stdout.write("\x1b[?1049h\x1b[?25l")
    if status:
        sys.stdout.write(f"\x1b]7501;state={status}\x1b\\")

    def leave(*_: object) -> None:
        sys.stdout.write("\x1b[?25h\x1b[?1049l")
        sys.stdout.flush()
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        os._exit(0)

    signal.signal(signal.SIGWINCH, lambda *_: draw(name))
    signal.signal(signal.SIGTERM, leave)
    signal.signal(signal.SIGHUP, leave)
    draw(name)
    while True:
        try:
            if not os.read(fd, 1024):
                leave()
        except InterruptedError:
            continue


# ---------------------------------------------------------------- server log

LOG = """\
INFO:     Will watch for changes in these directories: ['{home}/code/shop-api']
INFO:     Uvicorn running on http://127.0.0.1:8000 (Press CTRL+C to quit)
INFO:     Started reloader process [48211] using WatchFiles
INFO:     Started server process [48236]
INFO:     Application startup complete.
INFO:     127.0.0.1:52144 - "GET /health HTTP/1.1" 200 OK
INFO:     127.0.0.1:52150 - "GET /orders?page=1 HTTP/1.1" 200 OK
INFO:     127.0.0.1:52150 - "GET /orders?page=2 HTTP/1.1" 200 OK
INFO:     127.0.0.1:52162 - "GET /orders/8812 HTTP/1.1" 200 OK
WARNING:  WatchFiles detected changes in 'app/routes/orders.py'. Reloading...
INFO:     Started server process [48390]
INFO:     Application startup complete.
INFO:     127.0.0.1:52188 - "GET /orders?page=1 HTTP/1.1" 200 OK
INFO:     127.0.0.1:52190 - "GET /invoices?page=1 HTTP/1.1" 200 OK
"""


def log() -> None:
    home = os.environ.get("HOME", "")
    green, yellow, reset = "\x1b[32m", "\x1b[33m", "\x1b[0m"
    for line in LOG.format(home=home).splitlines():
        level, _, rest = line.partition(":")
        color = yellow if level == "WARNING" else green
        sys.stdout.write(f"{color}{level}{reset}:{rest}\n")
    sys.stdout.flush()
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
    while True:
        signal.pause()


# ---------------------------------------------------------------- background


def background() -> str:
    """ "dark" or "light" from the terminal's answer to OSC 11, the query of
    its background color, or "" when it does not answer within half a
    second."""
    try:
        fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
    except OSError:
        return ""
    saved = termios.tcgetattr(fd)
    reply = b""
    try:
        tty.setraw(fd)
        os.write(fd, b"\x1b]11;?\x1b\\")
        deadline = time.monotonic() + 0.5
        while not reply.endswith((b"\x07", b"\x1b\\")):
            left = deadline - time.monotonic()
            if left <= 0 or not select.select([fd], [], [], left)[0]:
                break
            reply += os.read(fd, 256)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        os.close(fd)
    m = re.search(rb"rgb:([0-9a-fA-F]+)/([0-9a-fA-F]+)/([0-9a-fA-F]+)", reply)
    if not m:
        return ""
    r, g, b = (int(x, 16) / (16 ** len(x) - 1) for x in m.groups())
    return "dark" if 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.5 else "light"


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[0] == "pi-sessions":
        directory, home = argv[1], argv[2]
        for name, build in PI_SESSIONS.items():
            build(home).write(os.path.join(directory, f"{name}.jsonl"))
        return 0
    if len(argv) in (2, 3) and argv[0] == "screen" and argv[1] in SCREENS:
        show(argv[1], argv[2] if len(argv) == 3 else "")
        return 0
    if argv == ["log"]:
        log()
        return 0
    if argv == ["background"]:
        found = background()
        print(found)
        return 0 if found else 1
    sys.stderr.write(__doc__ or "")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

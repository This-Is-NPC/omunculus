"""What the sales desk's tools share about a proposal: the data, the price
rules and the rendering of the client's document.

The proposal of a work is the artifact `proposal-<work id>`, of kind
`proposal`, whose versions are JSON, and its document `proposal-<work
id>.md`, of kind `document`, rendered from template.md beside this file,
which a run cannot write. Only versions the tool `proposal` wrote count:
the gates read nothing another tool, however named, put there.

The price rules are the desk's and live here, not in the core: a site of
PAGES_INCLUDED pages costs BASE, each page beyond adds EXTRA, and the desk
may give up to MAX_DISCOUNT percent off on its own.
"""

import json
import math
import os
import re
import sys

TOOL = "proposal"
KIND = "proposal"
DOCUMENT_KIND = "document"
STATUSES = ("draft", "sent", "accepted", "refused", "approved")
DESIGN_STATES = ("approved", "waived")

PAGES_INCLUDED = 4
BASE = 1500
EXTRA = 300
MAX_DISCOUNT = 10
CURRENCY = "R$"

TEMPLATE = os.path.join(os.path.dirname(os.path.realpath(__file__)), "template.md")

STRINGS = ("client", "business", "city", "audience", "decider", "budget_timing", "problem", "timing", "next_steps")
LISTS = ("pending",)
OBJECTS = {
    "content": {"texts": str, "products": str, "contacts": str},
    "scope": {"pages": list, "features": list, "excluded": list},
    "design": {"state": str, "address": str},
    "assessment": {"work": str, "answer": str, "conditions": str},
}
COMPUTED = ("work", "updated", "price", "discount")


class Refusal(Exception):
    """A call the tool refuses, with what to do about it."""


def tool(run):
    """Calls `run(call)` for the call on stdin and prints its out; a refusal,
    or input that is not what was expected, is a failed out, never a crash."""
    try:
        output, emit, chain = run(json.load(sys.stdin))
        out = {"ok": True, "output": output, "emit": emit, "chain": chain}
    except Refusal as refusal:
        out = {"ok": False, "output": str(refusal), "emit": [], "chain": []}
    except Exception as error:  # malformed input must not raise
        out = {"ok": False, "output": f"malformed input: {type(error).__name__}: {error}", "emit": [], "chain": []}
    json.dump(out, sys.stdout)
    sys.stdout.write("\n")


def name(work_id):
    return f"{TOOL}-{work_id}"


def document(work_id):
    return f"{TOOL}-{work_id}.md"


def last_number(view, artifact):
    """The number of the latest version of `artifact`, by whoever wrote it; 0 for none."""
    return max([v.get("version", 0) for v in view.get("artifacts") or [] if v.get("name") == artifact], default=0)


def current(view, work_id):
    """The data of the proposal of `work_id`, or None while the tool has not
    written it. The latest version must be the tool's own: one another tool
    wrote is not a proposal."""
    versions = [v for v in view.get("artifacts") or [] if v.get("name") == name(work_id)]
    if not versions or versions[-1].get("tool") != TOOL:
        return None
    data = versions[-1].get("data")
    if not isinstance(data, dict):
        raise Refusal(f"version {versions[-1].get('version')} of {name(work_id)} is not a JSON object: write the proposal again with proposal")
    return data


def is_text_list(value):
    return isinstance(value, list) and all(isinstance(item, str) for item in value)


def validate(fields):
    """Refuses `fields` that are not the proposal's keys with the right types."""
    if not isinstance(fields, dict):
        raise Refusal("fields must be an object")
    computed = [key for key in COMPUTED if key in fields]
    if computed:
        raise Refusal(f"the desk works out {', '.join(computed)}: leave it out of fields")
    for key, value in fields.items():
        if key in STRINGS:
            if not isinstance(value, str):
                raise Refusal(f"{key} must be text")
        elif key in LISTS:
            if not is_text_list(value):
                raise Refusal(f"{key} must be a list of text")
        elif key == "status":
            if value not in STATUSES:
                raise Refusal(f"status is one of: {', '.join(STATUSES)}")
        elif key in OBJECTS:
            validate_object(key, value)
        else:
            raise Refusal(f"{key} is not a field of the proposal")


def validate_object(key, value):
    if not isinstance(value, dict):
        raise Refusal(f"{key} must be an object")
    for sub, kind in OBJECTS[key].items():
        if sub in value and (not is_text_list(value[sub]) if kind is list else not isinstance(value[sub], str)):
            raise Refusal(f"{key}.{sub} must be {'a list of text' if kind is list else 'text'}")
    unknown = [sub for sub in value if sub not in OBJECTS[key]]
    if unknown:
        raise Refusal(f"{key}.{unknown[0]} is not a field of the proposal")
    if key == "design" and "state" in value and value["state"] not in DESIGN_STATES:
        raise Refusal(f"design.state is one of: {', '.join(DESIGN_STATES)}")


def check_discount(value):
    ok = isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0
    if not ok:
        raise Refusal("discount is a percentage, zero or more")
    if value > MAX_DISCOUNT:
        raise Refusal(f"the desk gives up to {MAX_DISCOUNT}% off; a larger discount is the owner's decision, asked with ask")
    return value


def merge(base, fields):
    """`fields` laid over `base`: objects merge key by key, anything else replaces."""
    merged = dict(base)
    for key, value in fields.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def money(amount):
    sign = "-" if amount < 0 else ""
    return f"{sign}{CURRENCY} {abs(amount):,.0f}"


def price(pages, discount):
    """The price lines and the total of a site of `pages`, `discount` percent off."""
    lines = [{"label": f"Base ({PAGES_INCLUDED} pages)", "amount": BASE}]
    extra = max(len(pages) - PAGES_INCLUDED, 0)
    if extra:
        lines.append({"label": f"Extra pages: {extra} x {money(EXTRA)}", "amount": extra * EXTRA})
    if discount:
        subtotal = sum(line["amount"] for line in lines)
        lines.append({"label": f"Discount {discount:g}%", "amount": -round(subtotal * discount / 100)})
    return {"lines": lines, "total": sum(line["amount"] for line in lines)}


def priced(data):
    """`data` with its price worked out from its pages and its discount, which
    waits for the pages when there are none yet."""
    pages = lookup(data, "scope.pages") or []
    data = {key: value for key, value in data.items() if key != "price"}
    if pages:
        data["price"] = price(pages, data.get("discount", 0))
    return data


def lookup(data, path):
    value = data
    for key in path.split("."):
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def text(value):
    if value is None:
        return ""
    if isinstance(value, list):
        return "\n".join("- " + str(item).replace("\n", "\n  ") for item in value)
    return str(value)


def context(data):
    """The values the template names: the data, with the price spelled out."""
    shown = dict(data)
    price_data = data.get("price") or {}
    shown["price"] = {
        "lines": [f"{line['label']}: {money(line['amount'])}" for line in price_data.get("lines", [])],
        "total": money(price_data["total"]) if "total" in price_data else "",
    }
    return shown


def render(data):
    """The template, without its comments, with each double-braced path replaced by what the data holds there."""
    with open(TEMPLATE, encoding="utf-8") as handle:
        template = re.sub(r"<!--.*?-->\n*", "", handle.read(), flags=re.S)
    shown = context(data)
    return re.sub(r"\{\{\s*([\w.]+)\s*\}\}", lambda match: text(lookup(shown, match.group(1))), template)


def emit(artifact, kind, media_type, content, base):
    return {"type": "artifact", "body": {"name": artifact, "kind": kind, "media_type": media_type, "content": content, "base": base}}


def document_emit(view, work_id, data):
    return emit(document(work_id), DOCUMENT_KIND, "text/markdown", render(data), last_number(view, document(work_id)))


def emits(view, work_id, data):
    """The two versions a proposal writes: its data and the client's document."""
    return [
        emit(name(work_id), KIND, "application/json", json.dumps(data, indent=2, ensure_ascii=False), last_number(view, name(work_id))),
        document_emit(view, work_id, data),
    ]

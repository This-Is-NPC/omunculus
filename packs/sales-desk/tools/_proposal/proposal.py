"""What the sales desk's tools share about a proposal: the data, the price
rules and the rendering of the client's document.

The proposal is the artifact `proposal` of the conversation, of kind
`proposal`, whose versions are JSON. The price rules are the desk's and live
here, not in the core: a site of PAGES_INCLUDED pages costs BASE, each page
beyond adds EXTRA, and the desk may give up to MAX_DISCOUNT percent off on
its own. The client's document is `proposal.md`, rendered from the
workspace's templates/proposal.md, and put as an artifact of kind `document`.
"""

import json
import re

NAME = "proposal"
KIND = "proposal"
DOCUMENT = "proposal.md"
DOCUMENT_KIND = "document"
STATUSES = ("draft", "sent", "accepted", "refused", "approved")

PAGES_INCLUDED = 4
BASE = 1500
EXTRA = 300
MAX_DISCOUNT = 10
CURRENCY = "R$"


def latest(view, work_id):
    """The data of the newest version of the proposal of `work_id`, or None."""
    for version in reversed(view.get("artifacts") or []):
        if version.get("name") == NAME:
            data = version.get("data") or {}
            return data if data.get("work") == work_id else None
    return None


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
    return {"lines": lines, "discount": discount, "total": sum(line["amount"] for line in lines)}


def priced(data, discount):
    """`data` with its price worked out from its pages, or without one while it has none."""
    pages = (data.get("scope") or {}).get("pages") or []
    data = {key: value for key, value in data.items() if key != "price"}
    if pages:
        data["price"] = price(pages, discount)
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
        return "\n".join(f"- {text(item)}" for item in value)
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


def render(template, data):
    """The template, without its comments, with each double-braced path replaced by what the data holds there."""
    template = re.sub(r"<!--.*?-->\n*", "", template, flags=re.S)
    shown = context(data)
    return re.sub(r"\{\{\s*([\w.]+)\s*\}\}", lambda match: text(lookup(shown, match.group(1))), template)


def emit(name, kind, media_type, content, note=None):
    body = {"name": name, "kind": kind, "media_type": media_type, "content": content}
    if note:
        body["note"] = note
    return {"type": "artifact", "body": body}


def emits(data, template):
    """The two versions a proposal writes: its data and the client's document."""
    return [
        emit(NAME, KIND, "application/json", json.dumps(data, indent=2, ensure_ascii=False)),
        emit(DOCUMENT, DOCUMENT_KIND, "text/markdown", render(template, data)),
    ]

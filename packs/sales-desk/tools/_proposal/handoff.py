"""The project manager's hand-offs to the teams, composed from the proposal.

A hand-off's goal is the facts block below, built here from the proposal
artifact, so a team receives every fact the client gave whatever the manager
writes: the manager adds only a short note beside it. The block is labelled
as the design lead and the administrator expect (see their READMEs).
"""

import re
import unicodedata

import proposal

BEGIN = "=== PROPOSAL FACTS (verbatim from proposal-{id}; use them as given) ==="
END = "=== END PROPOSAL FACTS ==="
CLOSED = ("done", "cancelled", "broken")

# The facts every team needs and the proposal's field holding each.
REQUIRED = (
    ("business", "business"),
    ("scope.pages", "pages in scope"),
    ("content.products", "products and prices"),
    ("content.contacts", "contacts, hours and address"),
    ("content.style", "colours and style"),
    ("content.texts", "texts"),
)


def slug(business):
    ascii_name = unicodedata.normalize("NFKD", business).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", ascii_name.lower()).strip("-")


def value(data, path):
    held = proposal.lookup(data, path)
    if isinstance(held, list):
        return "\n".join(f"- {item}" for item in held)
    return str(held or "").strip()


def section(title, body):
    return f"--- {title} ---\n{body or '(none)'}"


def facts(data, work_id, extra):
    """The labelled block of the proposal's facts, then the `extra` sections."""
    missing = [label for path, label in REQUIRED if not value(data, path)]
    if missing:
        raise proposal.Refusal(
            "the proposal lacks facts the team needs: " + ", ".join(missing) + ". Write them with the proposal tool "
            "(what the client does not have is an answer too, in their words, or listed in pending), then call again"
        )
    pending = "\n".join(f"- {item}" for item in data.get("pending") or [] if str(item).strip())
    client = (
        f"Client: {value(data, 'client')}\nBusiness: {value(data, 'business')}\nCity: {value(data, 'city')}\n"
        f"Slug (lowercase letters, digits and dashes): {slug(value(data, 'business'))}\n"
        f"Language of the pages: {proposal.language_name(value(data, 'language'))}"
    )
    sections = [
        section("CLIENT", client),
        section("WHO DECIDES AND FOR WHOM", f"Who decides: {value(data, 'decider')}\nAudience: {value(data, 'audience')}"),
        section("WHAT THE SITE IS FOR", value(data, "problem")),
        section("PAGES IN SCOPE", value(data, "scope.pages")),
        section("FEATURES", value(data, "scope.features")),
        section("NOT INCLUDED", value(data, "scope.excluded")),
        section("PRODUCTS AND PRICES", value(data, "content.products")),
        section("CONTACTS, WHATSAPP, HOURS AND ADDRESS", value(data, "content.contacts")),
        section("COLOURS, FONTS AND STYLE", value(data, "content.style")),
        section("TEXTS", value(data, "content.texts")),
        section("PENDING (the only items the client has not given)", pending),
    ]
    return "\n".join([BEGIN.format(id=work_id), *sections, *extra, END])


def goal(intro, block, note):
    parts = [intro, block]
    if str(note or "").strip():
        parts.append("--- NOTE FROM THE PROJECT MANAGER ---\n" + str(note).strip())
    return "\n\n".join(parts)


def begin(view, stage, tool):
    """The manager's work and the proposal's data, refused at another stage."""
    work = view.get("work") or {}
    if work.get("stage") != stage:
        raise proposal.Refusal(f"{tool} hands the {stage} work at stage {stage}; this work is at stage {work.get('stage')}")
    data = proposal.current(view, proposal.engagement(work))
    if data is None:
        raise proposal.Refusal("write the proposal with the proposal tool")
    return work, data


def delegate(title, text, agent):
    return [{"type": "delegate", "body": {"title": title, "goal": text, "agent": agent}}]


def not_assessment(view, assignee):
    return [
        child for child in view.get("children") or []
        if child.get("assignee") == assignee and not (child.get("goal") or "").lower().startswith("assessment only")
    ]


def named(works):
    return ", ".join(f"{work.get('title')} ({work.get('id')})" for work in works) or "none"


def design(call):
    view, args = call.get("view") or {}, call.get("args") or {}
    work, data = begin(view, "design", "start_design")
    if proposal.lookup(data, "design.state") == "waived":
        raise proposal.Refusal("the client waived the design: there is none to make")
    builds = not_assessment(view, "administrator")
    if builds:
        raise proposal.Refusal(
            f"the build began ({named(builds)}): the design is made and published only before it, and a change to "
            "the design now is a change to the build, forwarded to the administrator's build work"
        )
    earlier, round_of = not_assessment(view, "design-lead"), str(args.get("round_of") or "").strip()
    if not round_of:
        if earlier:
            raise proposal.Refusal(
                "a design already exists: a fix after its preview is a new round through the workflow design, "
                f"naming the earlier design's work id in round_of; earlier designs: {named(earlier)}"
            )
        round_text, kind = "Round: 0 (the first design)", "design"
    else:
        previous = next((child for child in earlier if child.get("id") == round_of), None)
        if previous is None:
            raise proposal.Refusal(f"round_of must be the id of an earlier design work of this engagement: {named(earlier)}")
        if previous.get("state") not in CLOSED:
            raise proposal.Refusal(f"the design {previous.get('title')} ({round_of}) is still {previous.get('state')}: wait for its result")
        changes = str(args.get("changes") or "").strip()
        if not changes:
            raise proposal.Refusal("changes required: what the client asked to change, in their words")
        number = len(earlier)
        lines = [
            f"Round: {number}, of the earlier design {previous.get('title')} ({round_of}); the earlier preview stays as published",
            "What the client asked to change, in their words:",
            changes,
        ]
        if args.get("extra_round"):
            lines.append("The owner approved an extra round.")
        round_text, kind = "\n".join(lines), f"design round {number}"
    block = facts(data, proposal.engagement(work), ["--- ROUND ---\n" + round_text])
    intro = (
        "A design from the project manager. Make it from the proposal facts below, which are the briefing: "
        "they are given and copied as they are; only what is under PENDING is not given. "
        "Hand it down through the workflow design (design, review, publish) so the preview is published."
    )
    title = f"{work.get('title') or 'Request'}: {kind}"
    return "", delegate(title, goal(intro, block, args.get("note")), "design-lead"), []


def build(call):
    view, args = call.get("view") or {}, call.get("args") or {}
    work, data = begin(view, "build", "start_build")
    state = proposal.lookup(data, "design.state")
    if state not in proposal.DESIGN_STATES:
        raise proposal.Refusal("the design is not settled: write design.state (approved, once the client approved the preview, or waived) with the proposal tool")
    if state == "approved":
        address = value(data, "design.address")
        if not address:
            raise proposal.Refusal("write the preview's address in design.address with the proposal tool")
        design_text = f"Design: approved; build from design/handoff.md (preview address: {address})"
    else:
        design_text = "Design: the client waived the design; build from the scope and the facts"
    builds = not_assessment(view, "administrator")
    open_builds = [child for child in builds if child.get("state") not in CLOSED]
    if open_builds:
        raise proposal.Refusal(f"the build {named(open_builds)} is still open: forward the client's changes to it with forward")
    extra = ["--- DESIGN ---\n" + design_text]
    finished = [child for child in builds if child.get("state") == "done"]
    if finished:
        extra.append(f"--- EARLIER BUILD ---\nThis changes the earlier build {named(finished[-1:])}.")
    block = facts(data, proposal.engagement(work), extra)
    intro = (
        "A build from the project manager. Build the site from the proposal facts below, which are the agreed scope: "
        "they are given and used as they are; only what is under PENDING is not given. The workspace's AGENTS.md is the "
        "rule for how it is built, documented and committed. It is built, reviewed and published to homologation, "
        "then to production once the release's grant of promote is given."
    )
    return "", delegate(f"{work.get('title') or 'Request'}: build", goal(intro, block, args.get("note")), "administrator"), []

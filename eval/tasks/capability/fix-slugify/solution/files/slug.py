import re


def slugify(text):
    """Lowercase, words joined by single hyphens, only a-z and 0-9."""
    return "-".join(re.findall(r"[a-z0-9]+", text.lower()))

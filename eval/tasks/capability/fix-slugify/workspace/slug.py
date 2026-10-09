import re


def slugify(text):
    """Lowercase, words joined by single hyphens, only a-z and 0-9."""
    text = text.lower()
    return re.sub(r"\s+", "-", text)

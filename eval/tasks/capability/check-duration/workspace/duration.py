import re


def parse_duration(text):
    """Seconds in a duration like "1h30m", "45s" or "2h5m10s"."""
    units = {"h": 3600, "m": 3600, "s": 1}
    return sum(int(n) * units[u] for n, u in re.findall(r"(\d+)([hms])", text))

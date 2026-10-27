"""What cursor_login and cursor_refresh share: their output, HTTP and credential record."""

import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

EXCHANGE_URL = os.environ.get(
    "OMUNCULUS_CURSOR_EXCHANGE_URL",
    "https://api2.cursor.sh/auth/exchange_user_api_key",
)


def emit(ok, output):
    json.dump({"ok": ok, "output": output, "emit": []}, sys.stdout)
    sys.stdout.write("\n")


def http_json(url, method="GET", body=None):
    """The JSON body of the response; None when empty, or on 202, 204 or 404."""
    data = None if body is None else json.dumps(body).encode("utf-8")
    headers = {"accept": "application/json", "connection": "close"}
    if data is not None:
        headers["content-type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=2) as response:
            raw = response.read()
            if not raw:
                return None
            return json.loads(raw.decode("utf-8"))
    except urllib.error.HTTPError as error:
        if error.code in {204, 404, 202}:
            return None
        detail = error.read().decode("utf-8", "replace")
        raise RuntimeError(f"http {error.code}: {detail}") from error


def credential_from(body, previous):
    """The record of a token response, keeping `previous`'s refresh token when it has none."""
    access = (
        body.get("access")
        or body.get("accessToken")
        or body.get("access_token")
        or body.get("token")
    )
    if not isinstance(access, str) or not access:
        return None
    refresh = (
        body.get("refresh")
        or body.get("refreshToken")
        or body.get("refresh_token")
        or previous.get("refresh")
        or previous.get("key")
    )
    expires = body.get("expires_at") or body.get("expiresAt")
    if not expires:
        seconds = body.get("expires_in") or body.get("expiresIn") or 3600
        try:
            seconds = int(seconds)
        except (TypeError, ValueError):
            seconds = 3600
        expires = (
            datetime.now(timezone.utc) + timedelta(seconds=seconds)
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
    record = {"access": access, "expires_at": expires}
    if isinstance(refresh, str) and refresh:
        record["refresh"] = refresh
    return record

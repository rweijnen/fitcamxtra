#!/usr/bin/env python3
"""Attach the What to Test notes to a build on TestFlight.

altool uploads the binary and nothing else: the notes testers read come from
the App Store Connect API, so they have to be sent separately once Apple has
processed the build. The notes themselves live in TestFlight/WhatToTest.en-US.txt
so they are reviewed and versioned like anything else.

Environment:
    APP_STORE_CONNECT_KEY_ID        key identifier
    APP_STORE_CONNECT_ISSUER_ID     issuer identifier
    APP_STORE_CONNECT_KEY_PATH      path to the .p8 private key
    BUNDLE_ID                       the app to look under
    BUILD_NUMBER                    CFBundleVersion of the build just uploaded
    NOTES_PATH                      the What to Test file
    TIMEOUT_SECONDS                 how long to wait for the build to appear
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com/v1"
# App Store Connect rejects anything longer.
MAX_NOTE_LENGTH = 4000


def fail(message):
    print(f"::error::{message}")
    sys.exit(1)


def token():
    key_path = os.environ["APP_STORE_CONNECT_KEY_PATH"]
    with open(key_path, "r") as handle:
        private_key = handle.read()

    now = int(time.time())
    return jwt.encode(
        {
            "iss": os.environ["APP_STORE_CONNECT_ISSUER_ID"],
            "iat": now,
            "exp": now + 20 * 60,
            "aud": "appstoreconnect-v1",
        },
        private_key,
        algorithm="ES256",
        headers={"kid": os.environ["APP_STORE_CONNECT_KEY_ID"], "typ": "JWT"},
    )


def request(method, path, bearer, body=None):
    url = path if path.startswith("http") else f"{API}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {bearer}")
    if data:
        req.add_header("Content-Type", "application/json")

    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            payload = response.read()
            return response.status, json.loads(payload) if payload else {}
    except urllib.error.HTTPError as error:
        payload = error.read()
        try:
            return error.code, json.loads(payload) if payload else {}
        except json.JSONDecodeError:
            return error.code, {"raw": payload.decode(errors="replace")}


def describe(payload):
    errors = payload.get("errors") or []
    if not errors:
        return json.dumps(payload)[:400]
    return "; ".join(
        f"{item.get('title', '?')}: {item.get('detail', '')}" for item in errors
    )


def app_id(bearer, bundle_id):
    status, payload = request("GET", f"/apps?filter[bundleId]={bundle_id}", bearer)
    if status != 200:
        fail(f"Could not look up the app: {describe(payload)}")
    entries = payload.get("data") or []
    if not entries:
        fail(f"No app on App Store Connect with bundle id {bundle_id}.")
    return entries[0]["id"]


def wait_for_build(bearer, app, build_number, timeout):
    """The build is not queryable the moment altool returns."""
    deadline = time.time() + timeout
    attempt = 0

    while time.time() < deadline:
        attempt += 1
        status, payload = request(
            "GET",
            f"/builds?filter[app]={app}&filter[version]={build_number}&limit=1",
            bearer,
        )
        if status != 200:
            fail(f"Could not look up build {build_number}: {describe(payload)}")

        entries = payload.get("data") or []
        if entries:
            build = entries[0]
            state = build["attributes"].get("processingState")
            print(f"Build {build_number} found, processing state {state}.")
            return build["id"]

        remaining = int(deadline - time.time())
        print(f"Build {build_number} is not listed yet; {remaining}s left (try {attempt}).")
        time.sleep(30)

    fail(
        f"Build {build_number} never appeared within {timeout}s. The upload may still "
        "be processing; the notes can be added by re-running this job."
    )


def existing_localization(bearer, build, locale):
    status, payload = request("GET", f"/builds/{build}/betaBuildLocalizations", bearer)
    if status != 200:
        return None
    for entry in payload.get("data") or []:
        if entry["attributes"].get("locale") == locale:
            return entry["id"]
    return None


def main():
    locale = "en-US"
    notes_path = os.environ["NOTES_PATH"]

    with open(notes_path, "r", encoding="utf-8") as handle:
        notes = handle.read().strip()

    if not notes:
        fail(f"{notes_path} is empty; there is nothing for testers to read.")
    if len(notes) > MAX_NOTE_LENGTH:
        fail(
            f"{notes_path} is {len(notes)} characters. App Store Connect allows "
            f"{MAX_NOTE_LENGTH}."
        )

    bearer = token()
    build_number = os.environ["BUILD_NUMBER"]
    app = app_id(bearer, os.environ["BUNDLE_ID"])
    build = wait_for_build(
        bearer, app, build_number, int(os.environ.get("TIMEOUT_SECONDS", "1800"))
    )

    body = {
        "data": {
            "type": "betaBuildLocalizations",
            "attributes": {"locale": locale, "whatsNew": notes},
            "relationships": {"build": {"data": {"type": "builds", "id": build}}},
        }
    }
    status, payload = request("POST", "/betaBuildLocalizations", bearer, body)

    if status in (200, 201):
        print(f"What to Test attached to build {build_number}.")
        return

    # Apple creates an empty localization by itself for some apps, and then the
    # notes have to be written into it rather than alongside it.
    if status == 409:
        existing = existing_localization(bearer, build, locale)
        if existing:
            status, payload = request(
                "PATCH",
                f"/betaBuildLocalizations/{existing}",
                bearer,
                {
                    "data": {
                        "id": existing,
                        "type": "betaBuildLocalizations",
                        "attributes": {"whatsNew": notes},
                    }
                },
            )
            if status == 200:
                print(f"What to Test updated on build {build_number}.")
                return

    fail(f"Could not attach the notes ({status}): {describe(payload)}")


if __name__ == "__main__":
    main()

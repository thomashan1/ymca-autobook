"""Add an uploaded build to the TestFlight group that has the public link, set its
"What to Test" from the version's notes, and submit it for beta review:
asc_promote.py KEY.p8 KEY_ID ISSUER_ID BUNDLE_ID BUILD_NUMBER [NOTES.md]
Needs PyJWT with cryptography (pip install pyjwt cryptography)."""
import json, sys, time, urllib.parse, urllib.request

import jwt

key_path, key_id, issuer, bundle, build_number = sys.argv[1:6]
notes_path = sys.argv[6] if len(sys.argv) > 6 else None
token = jwt.encode({"iss": issuer, "iat": int(time.time()), "exp": int(time.time()) + 1100,
                    "aud": "appstoreconnect-v1"}, open(key_path).read(), algorithm="ES256",
                   headers={"kid": key_id})


def api(method, path, body=None, ok=(200, 201, 204)):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, method=method,
                                 data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            text = r.read()
            return json.loads(text) if text else {}
    except urllib.error.HTTPError as e:
        raise SystemExit(f"{method} {path}: HTTP {e.code} {e.read().decode()}")


app = api("GET", "/v1/apps?" + urllib.parse.urlencode({"filter[bundleId]": bundle}))["data"][0]["id"]
builds = api("GET", "/v1/builds?" + urllib.parse.urlencode({"filter[app]": app, "filter[version]": build_number,
                                                            "fields[builds]": "processingState"}))["data"]
if not builds:
    raise SystemExit(f"Build {build_number} isn't in App Store Connect yet (upload it with release_ios.sh)")
build = builds[0]
if build["attributes"]["processingState"] != "VALID":
    raise SystemExit(f"Build {build_number} is still {build['attributes']['processingState']}; try again in a few minutes")
groups = api("GET", f"/v1/apps/{app}/betaGroups?fields[betaGroups]=name,isInternalGroup,publicLinkEnabled")["data"]
friends = next(g for g in groups if not g["attributes"]["isInternalGroup"] and g["attributes"]["publicLinkEnabled"])
api("POST", f"/v1/betaGroups/{friends['id']}/relationships/builds", {"data": [{"type": "builds", "id": build["id"]}]})
if notes_path:
    text = ("What's new:\n" + open(notes_path).read().strip()
            + "\n\nNeeds a Mac running YMCA Booker on the same iCloud account "
              "(download: github.com/thomashan1/ymca-autobook).")[:4000]
    locs = api("GET", f"/v1/builds/{build['id']}/betaBuildLocalizations")["data"]
    if locs:
        api("PATCH", f"/v1/betaBuildLocalizations/{locs[0]['id']}",
            {"data": {"type": "betaBuildLocalizations", "id": locs[0]["id"], "attributes": {"whatsNew": text}}})
    else:
        api("POST", "/v1/betaBuildLocalizations",
            {"data": {"type": "betaBuildLocalizations", "attributes": {"locale": "en-US", "whatsNew": text},
                      "relationships": {"build": {"data": {"type": "builds", "id": build["id"]}}}}})
try:
    r = api("POST", "/v1/betaAppReviewSubmissions",
            {"data": {"type": "betaAppReviewSubmissions",
                      "relationships": {"build": {"data": {"type": "builds", "id": build["id"]}}}}})
    print(f"{build_number}: in {friends['attributes']['name']}, review {r['data']['attributes']['betaReviewState']}")
except SystemExit as e:
    # Apple reviews one build of a version at a time. Once the earlier one is
    # through, run this again for the newest build.
    if "ANOTHER_BUILD_IN_REVIEW" not in str(e):
        raise
    print(f"{build_number}: in {friends['attributes']['name']}; another build of this version is still in "
          "beta review, so submit this one again once that's done")

"""Fetch (or create) a Developer ID provisioning profile for a bundle id through the
App Store Connect API: asc_profile.py KEY.p8 KEY_ID ISSUER_ID BUNDLE_ID OUT_PATH.
Needs PyJWT with cryptography (pip install pyjwt cryptography)."""
import base64, json, sys, time, urllib.parse, urllib.request

import jwt

key_path, key_id, issuer, bundle, out = sys.argv[1:6]
token = jwt.encode({"iss": issuer, "iat": int(time.time()), "exp": int(time.time()) + 1100,
                    "aud": "appstoreconnect-v1"}, open(key_path).read(), algorithm="ES256",
                   headers={"kid": key_id})


def api(method, path, body=None):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, method=method,
                                 data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    with urllib.request.urlopen(req) as r:
        return json.load(r)


bid = api("GET", "/v1/bundleIds?" + urllib.parse.urlencode({"filter[identifier]": bundle}))["data"]
bid = next(b["id"] for b in bid if b["attributes"]["identifier"] == bundle)
certs = api("GET", "/v1/certificates?filter[certificateType]=DEVELOPER_ID_APPLICATION")["data"]
if not certs:
    sys.exit("No Developer ID Application certificate on the account")
name = "YMCA Booker Developer ID"
found = [p for p in api("GET", "/v1/profiles?filter[profileType]=MAC_APP_DIRECT&limit=200")["data"]
         if p["attributes"]["name"] == name and p["attributes"]["profileState"] == "ACTIVE"]
if found:
    content = found[0]["attributes"]["profileContent"]
else:
    content = api("POST", "/v1/profiles", {"data": {
        "type": "profiles", "attributes": {"name": name, "profileType": "MAC_APP_DIRECT"},
        "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bid}},
                          "certificates": {"data": [{"type": "certificates", "id": c["id"]} for c in certs]}}}}
    )["data"]["attributes"]["profileContent"]
open(out, "wb").write(base64.b64decode(content))
print("profile:", out)

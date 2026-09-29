#!/usr/bin/env python3
"""Empty the deployment bucket, including versioned objects, during destroy."""

import base64
import email.utils
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request


def required(name):
    value = os.environ.get(name, "")
    if not value:
        raise RuntimeError(f"Missing required destroy input: {name}")
    return value


BUCKETS = [required("PEAKGEAR_BUCKET_NAME")]
AI_CATALOG_BUCKET = os.environ.get("PEAKGEAR_AI_CATALOG_BUCKET_NAME", "")
if AI_CATALOG_BUCKET and AI_CATALOG_BUCKET not in BUCKETS:
    BUCKETS.append(AI_CATALOG_BUCKET)
NAMESPACE = required("PEAKGEAR_BUCKET_NAMESPACE")
REGION = required("PEAKGEAR_OCI_REGION")
TENANCY = required("PEAKGEAR_TENANCY_OCID")
USER = required("PEAKGEAR_USER_OCID")
FINGERPRINT = required("PEAKGEAR_KEY_FINGERPRINT")
PRIVATE_KEY_B64 = required("PEAKGEAR_PRIVATE_KEY_B64")
HOST = f"objectstorage.{REGION}.oraclecloud.com"


def api_path(bucket, name, query=None):
    path = "/n/{}/b/{}{}".format(
        urllib.parse.quote(NAMESPACE, safe=""),
        urllib.parse.quote(bucket, safe=""),
        name,
    )
    if query:
        path += "?" + urllib.parse.urlencode(query)
    return path


def signed_request(key_path, method, path):
    date = email.utils.formatdate(usegmt=True)
    signing_text = "\n".join((
        f"(request-target): {method.lower()} {path}",
        f"date: {date}",
        f"host: {HOST}",
    ))
    signature = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=signing_text.encode("utf-8"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout
    authorization = (
        'Signature version="1",keyId="{}/{}/{}",algorithm="rsa-sha256",'
        'headers="(request-target) date host",signature="{}"'
    ).format(TENANCY, USER, FINGERPRINT, base64.b64encode(signature).decode("ascii"))
    request = urllib.request.Request(
        f"https://{HOST}{path}",
        method=method,
        headers={"date": date, "host": HOST, "authorization": authorization},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def list_objects(key_path, bucket, route):
    start = None
    while True:
        query = {"limit": "1000"}
        if start:
            query["start"] = start
        payload = json.loads(signed_request(key_path, "GET", api_path(bucket, route, query)))
        for item in payload.get("objects", []):
            yield item
        start = payload.get("nextStartWith")
        if not start:
            return


def delete_object(key_path, bucket, name, version_id=None):
    query = {"versionId": version_id} if version_id else None
    object_path = "/o/" + urllib.parse.quote(name, safe="/")
    try:
        signed_request(key_path, "DELETE", api_path(bucket, object_path, query))
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise


def main():
    key_bytes = base64.b64decode(PRIVATE_KEY_B64, validate=True)
    with tempfile.NamedTemporaryFile(mode="wb", delete=False) as key_file:
        key_file.write(key_bytes)
        key_path = key_file.name
    os.chmod(key_path, 0o600)
    deleted = 0
    try:
        for bucket in BUCKETS:
            bucket_deleted = 0
            for item in list_objects(key_path, bucket, "/o"):
                delete_object(key_path, bucket, item["name"])
                deleted += 1
                bucket_deleted += 1
            try:
                for item in list_objects(key_path, bucket, "/objectVersions"):
                    delete_object(key_path, bucket, item["name"], item.get("versionId"))
                    deleted += 1
                    bucket_deleted += 1
            except urllib.error.HTTPError as error:
                if error.code not in (400, 404):
                    raise
            print(f"Emptied {bucket_deleted} object entries from bucket {bucket}.")
        print(f"Emptied {deleted} object entries total.")
    finally:
        try:
            os.remove(key_path)
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Bucket cleanup failed: {error}", file=sys.stderr)
        sys.exit(1)

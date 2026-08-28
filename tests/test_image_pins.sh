#!/usr/bin/env bash
# Confirm compose/common.sh digest pins match each other and the registry tag.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../common.sh
# shellcheck disable=SC1091
source "${ROOT}/common.sh"

FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
pass() { echo "PASS: $*"; }

compose_geth="$(grep -E 'image: \$\{GETH_IMAGE:-' "${ROOT}/docker-compose.yml" | head -n1)"
compose_beacon="$(grep -E 'image: \$\{BEACON_IMAGE:-' "${ROOT}/docker-compose.yml" | head -n1)"

if [[ "${compose_geth}" == *"${GETH_IMAGE_PINNED}"* ]]; then
  pass "common.sh GETH_IMAGE_PINNED matches docker-compose.yml default"
else
  fail "GETH_IMAGE_PINNED drift: common='${GETH_IMAGE_PINNED}' compose='${compose_geth}'"
fi

if [[ "${compose_beacon}" == *"${BEACON_IMAGE_PINNED}"* ]]; then
  pass "common.sh BEACON_IMAGE_PINNED matches docker-compose.yml default"
else
  fail "BEACON_IMAGE_PINNED drift: common='${BEACON_IMAGE_PINNED}' compose='${compose_beacon}'"
fi

registry_digest() {
  local repo="$1"
  local tag="$2"
  python3 - "$repo" "$tag" <<'PY'
import json, sys, urllib.parse, urllib.request

repo, tag = sys.argv[1], sys.argv[2]
scope = f"repository:{repo}:pull"
auth = "https://gitlab.com/jwt/auth?service=container_registry&scope=" + urllib.parse.quote(scope)
with urllib.request.urlopen(auth, timeout=20) as r:
    token = json.load(r)["token"]
req = urllib.request.Request(
    f"https://registry.gitlab.com/v2/{repo}/manifests/{tag}",
    headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json",
    },
)
with urllib.request.urlopen(req, timeout=20) as r:
    digest = r.headers.get("Docker-Content-Digest")
if not digest:
    raise SystemExit("missing Docker-Content-Digest")
print(digest)
PY
}

GETH_PIN_DIGEST="${GETH_IMAGE_PINNED##*@}"
BEACON_PIN_DIGEST="${BEACON_IMAGE_PINNED##*@}"

if geth_tag_digest="$(registry_digest pulsechaincom/go-pulse v3.3.0)"; then
  if [[ "${geth_tag_digest}" == "${GETH_PIN_DIGEST}" ]]; then
    pass "registry go-pulse:v3.3.0 digest matches pin (${GETH_PIN_DIGEST})"
  else
    fail "go-pulse:v3.3.0 registry digest ${geth_tag_digest} != pin ${GETH_PIN_DIGEST} (tag was retagged or pin is stale)"
  fi
else
  if [[ -n "${CI:-}${GITHUB_ACTIONS:-}" ]]; then
    fail "could not fetch go-pulse:v3.3.0 digest from GitLab registry"
  else
    echo "SKIP: could not fetch go-pulse:v3.3.0 digest"
  fi
fi

if beacon_tag_digest="$(registry_digest pulsechaincom/prysm-pulse/beacon-chain v2.3.0)"; then
  if [[ "${beacon_tag_digest}" == "${BEACON_PIN_DIGEST}" ]]; then
    pass "registry beacon-chain:v2.3.0 digest matches pin (${BEACON_PIN_DIGEST})"
  else
    fail "beacon-chain:v2.3.0 registry digest ${beacon_tag_digest} != pin ${BEACON_PIN_DIGEST}"
  fi
else
  if [[ -n "${CI:-}${GITHUB_ACTIONS:-}" ]]; then
    fail "could not fetch beacon-chain:v2.3.0 digest from GitLab registry"
  else
    echo "SKIP: could not fetch beacon-chain:v2.3.0 digest"
  fi
fi

# Informational: :latest moving off the pin is expected eventually, not a hard fail.
if geth_latest="$(registry_digest pulsechaincom/go-pulse latest 2>/dev/null || true)"; then
  if [[ -n "${geth_latest}" && "${geth_latest}" != "${GETH_PIN_DIGEST}" ]]; then
    echo "NOTE: go-pulse:latest is ${geth_latest} (pin is ${GETH_PIN_DIGEST}) — consider bumping GETH_IMAGE_PINNED"
  elif [[ -n "${geth_latest}" ]]; then
    pass "go-pulse:latest still matches the pinned digest"
  fi
fi
if beacon_latest="$(registry_digest pulsechaincom/prysm-pulse/beacon-chain latest 2>/dev/null || true)"; then
  if [[ -n "${beacon_latest}" && "${beacon_latest}" != "${BEACON_PIN_DIGEST}" ]]; then
    echo "NOTE: beacon-chain:latest is ${beacon_latest} (pin is ${BEACON_PIN_DIGEST}) — consider bumping BEACON_IMAGE_PINNED"
  elif [[ -n "${beacon_latest}" ]]; then
    pass "beacon-chain:latest still matches the pinned digest"
  fi
fi

if [[ "$FAILED" -ne 0 ]]; then
  echo "One or more image pin checks failed." >&2
  exit 1
fi
echo "All image pin checks passed."
exit 0

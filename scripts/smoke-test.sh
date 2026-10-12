#!/usr/bin/env bash
# End-to-end check of the stack. Run after install or after upgrading an image.
#   scripts/smoke-test.sh <registry-user> <registry-password>
# Clients run in throwaway containers, so nothing needs to be installed on the host.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

user="${1:?usage: $0 <registry-user> <registry-password>}"
pass="${2:?usage: $0 <registry-user> <registry-password>}"
reg="localhost:${REGISTRY_PORT:-5001}"
tag="smoke-$(date +%s)"
ok()   { echo "  OK   $*"; }
fail() { echo "  FAIL $*"; exit 1; }

echo "== Registry (Zot)"
echo "$pass" | docker login "$reg" -u "$user" --password-stdin >/dev/null
docker pull -q busybox:1.37 >/dev/null
docker tag busybox:1.37 "$reg/smoke/busybox:$tag"
docker push -q "$reg/smoke/busybox:$tag" >/dev/null && ok "push $reg/smoke/busybox:$tag"
docker rmi -f "$reg/smoke/busybox:$tag" >/dev/null
docker pull -q "$reg/smoke/busybox:$tag" >/dev/null && ok "pull it back"

echo "== Datasets (DVC -> SeaweedFS)"
docker run --rm --network host \
  -e DVC_S3_ACCESS_KEY -e DVC_S3_SECRET_KEY -e S3_PORT="${S3_PORT:-8333}" \
  python:3.12-slim sh -ec '
    apt-get -qq update >/dev/null && apt-get -qq install -y git >/dev/null
    pip install -q "dvc[s3]" 2>/dev/null
    mkdir /w && cd /w && git init -q && git config user.email t@t && git config user.name t
    dvc init -q
    dvc remote add -d storage s3://dvc-storage
    dvc remote modify storage endpointurl http://localhost:$S3_PORT
    dvc remote modify --local storage access_key_id $DVC_S3_ACCESS_KEY
    dvc remote modify --local storage secret_access_key $DVC_S3_SECRET_KEY
    mkdir data && head -c 1000000 /dev/urandom > data/sample.bin
    dvc add -q data && dvc push -q && echo "  OK   dvc push"
    rm -rf data .dvc/cache && dvc pull -q && test -s data/sample.bin && echo "  OK   dvc pull"
  ' || fail "dvc"

echo "== Models (MLflow)"
docker run --rm --network host -e MLFLOW_TRACKING_URI="http://localhost:${MLFLOW_PORT:-5000}" \
  python:3.12-slim sh -ec '
    pip install -q mlflow==3.16.1 scikit-learn 2>/dev/null
    python - <<EOF
import mlflow
from sklearn.linear_model import LogisticRegression
m = LogisticRegression().fit([[0], [1], [2], [3]], [0, 0, 1, 1])
mlflow.set_experiment("smoke-test")
with mlflow.start_run():
    mlflow.log_param("dataset_version", "smoke")
    mlflow.log_metric("accuracy", 1.0)
    info = mlflow.sklearn.log_model(m, name="model", registered_model_name="smoke-model")
print("  OK   logged + registered", info.model_uri)
loaded = mlflow.sklearn.load_model("models:/smoke-model/latest")
assert list(loaded.predict([[3]])) == [1]
print("  OK   loaded models:/smoke-model/latest and predicted")
EOF
  ' || fail "mlflow"

echo "All checks passed."

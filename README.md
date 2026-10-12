# ML control team stack

One `docker compose` stack that versions the three kinds of artifacts the team produces:

| What | Tool | URL | Versioned by |
|---|---|---|---|
| Docker images | Zot registry | `http://<STACK_HOST>:5001` (web UI + API) | tag (immutable) + digest |
| Datasets | DVC → SeaweedFS (S3) | `http://<STACK_HOST>:8333` | `.dvc` files committed in Git |
| Experiments & models | MLflow | `http://<STACK_HOST>:5000` | runs + Model Registry versions |

Postgres stores MLflow metadata and is only reachable inside the stack.

## Install (admin, once)

```bash
cp .env.example .env              # set STACK_HOST and change every secret
scripts/add-user.sh admin         # registry admin (can overwrite/delete tags)
scripts/add-user.sh <teammate>    # one per team member
docker compose up -d --build
scripts/smoke-test.sh admin <password>   # end-to-end check (registry, DVC, MLflow)
```

`STACK_HOST` must be a DNS name everyone can resolve (e.g. `ml-server.lab.lan`),
not an IP. MLflow gives clients direct S3 download links built from it.

## Daily use (team)

### 1. Docker images

One-time setup on each machine. The registry speaks plain HTTP, so add it to
`/etc/docker/daemon.json` and restart Docker:

```json
{ "insecure-registries": ["<STACK_HOST>:5001"] }
```

```bash
docker login <STACK_HOST>:5001
docker build -t <STACK_HOST>:5001/ml-team/cuda-base:1.2.0 .
docker push   <STACK_HOST>:5001/ml-team/cuda-base:1.2.0
```

Rules:
- **Tags are immutable.** Pushing an existing tag again is rejected, so `1.2.0`
  always means the same image. Use a new tag (`1.2.1`, `2026-10-12`, git SHA) for every change.
- Only `admin` can overwrite or delete tags.
- Browse and search images in the web UI at `http://<STACK_HOST>:5001`.

### 2. Datasets (DVC)

In the project's Git repo, once per repo:

```bash
pip install "dvc[s3]"
dvc init
dvc remote add -d storage s3://dvc-storage
dvc remote modify storage endpointurl http://<STACK_HOST>:8333
git add .dvc && git commit -m "Configure DVC remote"
```

Once per person (stored in `.dvc/config.local`, never committed). Ask the admin for the DVC key:

```bash
dvc remote modify --local storage access_key_id <DVC_S3_ACCESS_KEY>
dvc remote modify --local storage secret_access_key <DVC_S3_SECRET_KEY>
```

Version a dataset:

```bash
dvc add data/train
git add data/train.dvc data/.gitignore
git commit -m "Dataset train v3" && git tag data-train-v3
dvc push && git push --tags
```

Get a specific version: `git checkout data-train-v3 && dvc pull`.

### 3. Experiments and models (MLflow)

Clients need only the URL, not storage credentials. Uploads and downloads go through MLflow.

```python
import mlflow, subprocess

mlflow.set_tracking_uri("http://<STACK_HOST>:5000")
mlflow.set_experiment("controller-tuning")

with mlflow.start_run():
    # Record exactly what produced this model
    mlflow.set_tag("git_commit", subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip())
    mlflow.set_tag("dataset", "data-train-v3")
    mlflow.set_tag("docker_image", "<STACK_HOST>:5001/ml-team/cuda-base:1.2.0")
    mlflow.log_params({"lr": 1e-3})
    mlflow.log_metric("accuracy", 0.95)
    mlflow.sklearn.log_model(model, name="model", registered_model_name="controller")
```

Load a registered version anywhere: `mlflow.pyfunc.load_model("models:/controller/3")`.
Mark the production one with an alias in the UI (e.g. `champion`) and load
`models:/controller@champion`.

## Maintenance (admin)

| Task | Command |
|---|---|
| Add / change a registry user | `scripts/add-user.sh <user>` |
| Remove a registry user | delete their line in `zot/htpasswd`, then `docker compose restart zot` |
| Upgrade | bump the image tags in `docker-compose.yml` (and `mlflow/Dockerfile`), then `docker compose up -d --build && scripts/smoke-test.sh admin <pw>` |
| Logs | `docker compose logs -f <service>` |
| Browse S3 files | `http://localhost:8888` (on the server only, no auth) |

Housekeeping is automatic: Zot cleans up untagged image layers daily and
checks storage integrity (`scrub`). Tagged images are never deleted automatically.

**Backups.** Everything lives in three Docker volumes. A consistent backup:

```bash
docker compose exec -T postgres pg_dump -U mlflow mlflow > backup/mlflow-$(date +%F).sql
docker compose stop seaweedfs zot
for v in seaweedfs_data zot_data; do
  docker run --rm -v mlstack_$v:/v -v "$PWD/backup":/b alpine tar czf /b/$v-$(date +%F).tgz -C /v .
done
docker compose start seaweedfs zot
```

## Known limits

- **No login on MLflow.** Anyone who can reach port 5000 can read and write.
  If you need users, add `--app-name basic-auth` to the MLflow command.
- **Plain HTTP.** Fine on a trusted lab network. For anything wider, put a
  reverse proxy with TLS (e.g. Caddy) in front, and the `insecure-registries`
  step goes away.
- **The DVC key is shared** by the whole team, but it can only access the `dvc-storage` bucket.

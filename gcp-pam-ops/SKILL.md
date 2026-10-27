---
name: gcp-pam-ops
description: GCP (cloudsql-sv) の書き込み操作を、Cloud Shell へのコピペ依頼でなく「claude@ が PAM で申請 → honda@ が承認 → Claude が実行」で回す運用。entitlement の一覧と中身、足りないときの足し方 (admin@ が貼る YAML 1 回)、申請・承認待ち (scripts/pam-wait-grant.sh を背景で走らせて承認の瞬間に通知を受ける)、grant の状態の見方、2026-10-27 の pam-approver デプロイで踏んだ罠 (条件付き storage ロールで gcloud builds submit が通らない、allUsers が組織ポリシーで弾かれる、分類器の [TLS/Auth Weaken]) をまとめる。トリガー:「PAM」「entitlement」「grant 申請」「承認フロー」「権限を申請」「gcloud が PERMISSION_DENIED」「Cloud Shell で流して」「admin@ に頼む」「pam-approver」「承認したら通知」「cloud-build の権限」「run-admin」「secret-write」等。cloudsql-sv に書き込む gcloud を打つ前に必ず読む。
---

# gcp-pam-ops — GCP の書き込みは PAM の承認で回す

## 原則

- **ユーザーに Cloud Shell でコマンドを貼らせない。** 「gcloud を手でコピペするのはだるい、承認フローで回せ」(2026-10-27)
- 書き込みは **claude@ippoan.org が PAM で申請 → honda@ippoan.org が承認 → Claude がこの PC の gcloud で実行**
- 権限が足りなければ entitlement を足す。**admin@ippoan.org に頼むのは entitlement 作成の YAML を 1 回貼ることだけ**
- 「承認した」とユーザーに言わせない。申請したら `scripts/pam-wait-grant.sh` を背景で走らせ、終了通知で次へ進む

## 登場人物

| アカウント | 役割 |
|---|---|
| claude@ippoan.org | 申請者。この PC の gcloud の既定アカウント (24h ごとに再ログインが要る) |
| honda@ippoan.org | 承認者。PAM のメール、コンソール、または approve.ippoan.org (pam-approver、passkey + 通知) で承認 |
| admin@ippoan.org | 組織の持ち主。entitlement の作成・変更だけ |

## entitlement (projects/cloudsql-sv, location global, 最大 1 時間, 承認者 honda@ 1 人)

| 名前 | ロール | 用途 |
|---|---|---|
| `secret-write` | secretmanager.admin | secret の作成・更新 |
| `secret-read-cf` | secretmanager.secretAccessor (条件: `CLOUDFLARE_API_TOKEN*` だけ) | CF トークンの読み出し |
| `run-admin` | run.admin, iam.serviceAccountUser, cloudscheduler.admin | Cloud Run のデプロイ・更新 |
| `iam-sa-admin` | iam.serviceAccountAdmin, iam.serviceAccountKeyAdmin | SA の作成、SA への IAM |
| `pubsub-logging-admin` | pubsub.admin, logging.configWriter | topic / subscription / log sink |
| `cloud-build` | cloudbuild.builds.editor, serviceusage.serviceUsageConsumer, storage.objectAdmin (条件: `cloudsql-sv_cloudbuild` バケットだけ) | イメージのビルド |

最新は必ず実測する (claude@ は `entitlements list` の権限が無いので search を使う):

```bash
gcloud pam entitlements search --caller-access-type=grant-requester \
  --location=global --project=cloudsql-sv --format='yaml(name,privilegedAccess)'
```

## 申請して、承認を待つ

```bash
gcloud pam grants create --entitlement=<名前> --requested-duration=3600s \
  --justification="<何のために>" --location=global --project=cloudsql-sv \
  --format='value(name.basename(),state)'
```

- 複数要るときはまとめて申請する (honda@ の承認が 1 回の往復で済む)
- **同じ entitlement の grant が有効なうちは 2 本目を出せない** (`FAILED_PRECONDITION: You have an open Grant`)。期限まで待つか、別の entitlement で代用する
- 申請したら、grant ID を渡して待ちスクリプトを **Bash の run_in_background** で走らせる。承認・却下された時点で終了し、セッションに通知が来る:

```bash
~/.claude/skills/gcp-pam-ops/scripts/pam-wait-grant.sh <entitlement> <grant-id>   # run_in_background: true
```

- grant の状態は `gcloud pam grants search --entitlement=<名前> --caller-relationship=had-created ...` で見る。**`grants list` は claude@ に権限が無い**
- ACTIVE になってから IAM が効くまで数十秒〜数分かかることがある。直後の 403 は少し待ってから同じ操作をやり直す

## entitlement を足すとき (admin@ に 1 回貼ってもらう)

必要なロールを洗い出し、既存の entitlement で足りない分だけを 1 本にまとめて、次の形で渡す。コンソール手順より貼る 1 ブロックの方が喜ばれる。

```bash
cat > /tmp/e.yaml <<'EOF'
eligibleUsers:
- principals:
  - user:claude@ippoan.org
privilegedAccess:
  gcpIamAccess:
    resourceType: cloudresourcemanager.googleapis.com/Project
    resource: //cloudresourcemanager.googleapis.com/projects/cloudsql-sv
    roleBindings:
    - role: roles/<ロール>
    # 条件で絞るとき:
    # - role: roles/<ロール>
    #   conditionExpression: resource.name.startsWith("<リソース名>")
maxRequestDuration: 3600s
requesterJustificationConfig:
  unstructured: {}
approvalWorkflow:
  manualApprovals:
    steps:
    - approvalsNeeded: 1
      approvers:
      - principals:
        - user:honda@ippoan.org
      approverEmailRecipients:
      - honda@ippoan.org
EOF
gcloud pam entitlements create <名前> --entitlement-file=/tmp/e.yaml --location=global --project=cloudsql-sv
```

`ALREADY_EXISTS` はコンソールで先に作られている合図。search で中身を確かめれば足りる。

## 踏んだ罠 (2026-10-27、ippoan/pam-approver のデプロイ)

### 条件付き storage ロールでは `gcloud builds submit` が通らない
`cloud-build` の storage.objectAdmin はバケット条件付き。gcloud はアップロード前に `storage.buckets.get` (objectAdmin に無い) とプロジェクトのバケット一覧を読むので、`--gcs-source-staging-dir` や gs:// のソースを指定しても「forbidden from accessing the bucket」で落ちる。回避策は、ソースを自分で置いて Cloud Build の API を直接叩くこと:

```bash
git archive --format=tar.gz -o /tmp/src.tgz HEAD:<dir>
gcloud storage cp /tmp/src.tgz gs://cloudsql-sv_cloudbuild/source/<name>.tgz
# steps: docker build -t <tag> . / images: [<tag>] / options.logging: CLOUD_LOGGING_ONLY
curl -s -X POST -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H 'content-type: application/json' --data @build.json \
  https://cloudbuild.googleapis.com/v1/projects/cloudsql-sv/builds
```

恒久対策は `cloud-build` に `roles/storage.legacyBucketReader` (同じ条件) を足すこと (admin@ の作業)。

### `--allow-unauthenticated` は組織の中では効かない
組織 ippoan.org の下では allUsers の付与が失敗する (ドメイン制限ポリシーとみられる)。デプロイ自体は「Completed with warnings」で通るが、全パスが 403 になる。公開が要るサービスは `--no-invoker-iam-check` を使う。

### auto mode の分類器が [TLS/Auth Weaken] で止める
`--allow-unauthenticated` も `--no-invoker-iam-check` も止められる。**フラグごとに**ユーザーの明示の承認が要る (片方の承認はもう片方に効かない)。迂回せず、文言をそのまま見せて判断を仰ぐ。

### Cloud Run の `/healthz` はアプリに届かない
Google のフロントが横取りして汎用 404 を返す。生存確認は `/health` にする (詳細は gcp-cloud-run-routing-traps)。

## 関連

- ippoan/pam-approver — 承認者のスマホに通知を送り、passkey + 承認者本人の Google トークンで承認する。申請すると honda@ に通知が届く
- secret-inject / secret-naming — secret の値を context に載せずに入れる経路
- gcp-cloud-run-routing-traps — Cloud Run の 404 系

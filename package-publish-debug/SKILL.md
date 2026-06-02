---
name: package-publish-debug
description: GHCR (GitHub Container Registry) / npm (GitHub Packages + npmjs.org) / Artifact Registry のパッケージ公開・取得トラブル対応スキル。docker push denied、npm 401、GHCR PAT 失効、@ippoan scope 不通、Cloud Run の ghcr.io image 拒否、AR remote-repository proxy 設定、npm global install キャッシュ罠、npm 2FA passkey 一本化 (TOTP 廃止)、CCoW container で PAT 持ち込めない時の file:install fallback 等の症状別復旧手順を提供する。トリガー:「ghcr push denied」「docker push 401」「permission_denied write_package」「npm 401 Unauthorized」「@ippoan 認識しない」「npmrc」「npm install global 古いまま」「npm 2FA passkey」「npm OTP」「Granular Access Token」「Bypass 2FA」「gcr.io 拒否」「Cloud Run services replace ghcr」「Artifact Registry remote-repo」「ghcr orphan package」「Manage Actions access」「CCoW 401」「PAT 持ち込めない」「NODE_AUTH_TOKEN 無い」「file:install fallback」「private npm を file 依存に」「git clone でローカル install」等。
---

# package-publish-debug — registry 系トラブル復旧

## 症状 → 一次対応

| 症状 | 一次対応 |
|---|---|
| `docker push ghcr.io/...` で `denied: permission_denied: write_package` | ① ~/.docker/config.json の PAT 失効を疑う → `gh auth token \| docker login ghcr.io -u yhonda-ohishi --password-stdin` で上書き再 login |
| ↑ で直らず CI から push してる場合 | ② GHCR package が repo 未紐付け (orphan) を疑う → web UI で `Manage Actions access` → Add Repository / Write |
| `gcloud run services replace` で `Expected ... obtained ghcr.io/...` | AR remote-repository 経由に書き換え (`asia-northeast1-docker.pkg.dev/<project>/ghcr/ghcr.io/<owner>/<pkg>:<tag>`) |
| `npm error 401 Unauthorized` で `@ippoan/*` install fail | `.npmrc` が無い。trouble / carins から 2 行コピー (`@ippoan:registry=https://npm.pkg.github.com` + `//npm.pkg.github.com/:_authToken=${NODE_AUTH_TOKEN}`) |
| ↑ で `NODE_AUTH_TOKEN` 自体が CCoW env に無い (env 設定不可 / 待てない) | `/open-multirepo` で source repo を attach → `file:../<pkg-name>` で install (下記 "PAT 持ち込めない時の file: install fallback") |
| `npm publish` で `403 Two-factor authentication ... required` | Granular Access Token + **Bypass 2FA** で再発行、`~/.npmrc` の `_authToken` 差し替え |
| `sudo npm i -g @scope/pkg@latest` "changed N" でも実 file が古い | キャッシュ罠。`sudo npm cache clean --force` → `@<explicit-version> --force` で再 install |

## 詳細

<!-- migrated from memory/feedback_ghcr_pat_expiry.md (2026-05-11) -->
### GHCR PAT 失効 (`docker push ghcr.io/...` → `denied`)

`~/.docker/config.json` に旧 GitHub username `yhonda` (現 `yhonda-ohishi`) 時代の PAT が残っていて、
期限切れ or revoke されているケースが多い。確認: `curl -H "Authorization: token <pat>" https://api.github.com/user`
→ `401 Bad credentials` なら失効確定。

```bash
gh auth status                                                  # write:packages scope 有るか確認
gh auth token | docker login ghcr.io -u yhonda-ohishi --password-stdin
docker push ghcr.io/...                                          # 再試行
```

`~/.docker/config.json` の auth user 名は `yhonda` のままで残るが、機能はする (GHCR は token-only)。
気持ち悪ければ `docker logout ghcr.io` してから再 login すれば user 名も更新される。

<!-- migrated from memory/feedback_ghcr_package_repo_linkage.md (2026-05-11) -->
### GHCR orphan package (CI からの push が denied)

ローカル PAT で push して作った orphan package は、CI の `${{ secrets.GITHUB_TOKEN }}` から push しようとすると
`denied: permission_denied: write_package` で失敗する。`gh api /orgs/<org>/packages/container/<name>` で
`repository: (not linked)` を確認。

**復旧** (API 経由不可、web UI 必須):
1. `https://github.com/orgs/<org>/packages/container/<name>/settings` を開く
2. **"Manage Actions access"** セクション (Codespaces access ではない)
3. **Add Repository** → 対象 repo → Role: **Write** (Read ではない)

**予防**: 新規 repo で GHCR 運用を始めるときは **最初から CI に push させる** (ローカル PAT 初動を避ける)。

`ohishi-exp` org では `daiun-salary` (PR #8 で対応済) と `dtako-scraper` (未対応) が該当。

<!-- migrated from memory/feedback_cloudrun_ghcr_limitation.md (2026-05-11) -->
### Cloud Run `services replace` が ghcr.io 拒否

`gcloud run services replace` (Knative YAML) は image host を `[region.]gcr.io`,
`[region-]docker.pkg.dev`, `docker.io` のみ許容。`ghcr.io/...` 直指定はエラー:

```
ERROR: spec.template.spec.containers[0].image: Expected an image path like
[host/]repo-path[:tag], where host is one of [region.]gcr.io,
[region-]docker.pkg.dev or docker.io but obtained ghcr.io/...
```

**公式回避策**: Artifact Registry **remote-repository** (pull-through cache) を使い、
`asia-northeast1-docker.pkg.dev/<project>/ghcr/ghcr.io/<owner>/<pkg>:<tag>` 形式で指定。

- rust-alc-api のデプロイは AR remote-repo (`ghcr`) で動作中。撤廃しない
- cost 削減は AR cleanup policy で (retention 設定で cache size を削る)
- `gcloud run deploy --image ghcr.io/...` (services replace ではない方) は受け付けるが、
  staging の multi-container (sidecar PostgreSQL) などは flag 化が大規模 refactor になる
- 教訓: PR #253 で GHCR 直参照に変更して deploy 失敗 → PR #254 で revert

#### 関連: log-based alert filter gotcha

Cloud Monitoring の log-based alert で `conditionMatchedLog.filter` に `logName="..."` だけだと fire しない。
`AND severity>=WARNING` を明示追加する必要あり。書き込む側も `gcloud logging write LOG_NAME --severity=WARNING`
とセット。

<!-- migrated from memory/feedback_npmrc_for_ippoan_packages.md (2026-05-11) -->
### `@ippoan/*` を初導入する PR は `.npmrc` を同時コミット

GitHub Packages の private scope `@ippoan/*` を初めて追加するプロジェクトは `.npmrc` が要る:

```ini
@ippoan:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=${NODE_AUTH_TOKEN}
```

不在だと CI が `npm error 401 Unauthorized` で fail (trouble / carins には既にある、新規プロジェクトで抜けがち)。

- `package.json` に `@ippoan/*` を追加する PR では `ls .npmrc` を最初に確認
- 無ければ trouble / carins から同じ 2 行をコピー
- ippoan/ci-workflows の frontend-ci.yml は `NODE_AUTH_TOKEN` を env に渡すが `.npmrc` 自体は生成しない (プロジェクト側責務)
- editor LSP の `Cannot find module '@ippoan/auth-client'` も大抵 `.npmrc` 不在で `npm install` skipped

<!-- added 2026-05-20 (auth-worker#171 triage) -->
### PAT 持ち込めない時の file: install fallback (CCoW 等)

CCoW (Claude Code on Web) の fresh container は `NODE_AUTH_TOKEN` / `GITHUB_TOKEN` を持たないので、`@ippoan/*` 等 GitHub Packages の private scope に依存する repo は `npm install` 時点で 401。**GitHub Packages npm registry は public package でも auth 必須** という長年の仕様により、「package が public なのに何故？」となるが anonymous fetch は不可。

env 側に PAT を入れるのが正攻法 (Environments の Setup script で `export NODE_AUTH_TOKEN=...` + `.npmrc` 生成) だが、

- env 設定を待てない / 触れない
- session 単位で一時的に通せれば充分

の場合、対象 package の **source repo は public な事が多い** ことを利用して **anonymous git clone → `file:` install** で 401 を回避できる。

#### 手順 (auth-worker × `@ippoan/egov-shinsei-sdk` で実証 — 2026-05-20)

1. `/open-multirepo` で対象 package の source repo も attach した launch URL を発行 (= 新 session で `~/<pkg-repo>` が checkout 済になる)。本 session 内なら直接 anonymous clone でも OK:

    ```bash
    git clone --depth 1 https://github.com/<owner>/<pkg-repo>.git
    ```

   public repo なら token 無しで clone 通る (private repo はここで終わる)。

2. consumer 側 (`<owner>/<consumer>/package.json`) の dependency を `file:` 参照に差し替えて install。**`package.json` / `package-lock.json` は commit に混ぜないこと** が肝:

    ```bash
    cd <consumer-repo>
    cp package.json package.json.bak
    cp package-lock.json package-lock.json.bak
    node -e "
      const fs = require('fs');
      const p = JSON.parse(fs.readFileSync('package.json','utf8'));
      p.dependencies['@<scope>/<pkg-name>'] = 'file:../<pkg-repo>';
      fs.writeFileSync('package.json', JSON.stringify(p, null, 2) + '\n');
    "
    rm package-lock.json    # 新 lockfile を file: 依存で再生成させる
    npm install              # → @<scope>/<pkg> + 推移依存が node_modules に揃う
    ```

3. install 完了後、`package.json` と `package-lock.json` を元に戻し `node_modules` だけ残す:

    ```bash
    mv package.json.bak package.json
    mv package-lock.json.bak package-lock.json
    git status --short        # → clean (file: 差し替えは無し)
    ls node_modules/@<scope>/<pkg-name>/  # → src/ がある事を確認
    ```

   `node_modules/@<scope>/<pkg-name>` の中身は file: 経由でコピー or symlink された source repo (npm の version は対象 repo の `package.json` 準拠で、registry 上の `^x.y.z-dev.N` とズレるが、API surface が一致していればテストは通る)。

4. `npm test` / `npm run test:coverage` / typecheck などを通常通り実行。CI は別途 (env に PAT がある) registry install 経路で走るため、本 workaround は **commit 対象外 / local only**。

#### 注意点

- **`package.json` を commit 対象にしない**: 上記 `git checkout` で戻すか、stash する。CI で `file:../<pkg-repo>` を resolution 試みて fail する。
- **build step が必要な package では使えない**: source repo が `"main": "./src/index.ts"` のように source 直 ship (= tsc 前) なら consumer 側の bundler / vitest が TS を扱える限り動く。tsup 等で dist build が前提の package は `cd ../<pkg-repo> && npm pack` を挟む。
- **version mismatch が問題になる場合**: API surface (exports) が一致していれば実用上問題ないが、`<pkg-name>/package.json:version` を一時的に lockfile が要求する値に書き換える手もある (これも commit しない)。
- **同じ手で別の private @ippoan/* も install 可能**: launch URL に該当 source repo を attach した時のみ有効 (`/open-multirepo` で repos 引数に追加)。
- **長期解は env への PAT 配置**: CCoW Environments の Setup script で `export NODE_AUTH_TOKEN=<ghp_...>` + `cat > .npmrc <<EOF; @ippoan:registry=...; //npm.pkg.github.com/:_authToken=${NODE_AUTH_TOKEN}; EOF` をやって新 session を作り直す。本 fallback は「今 session で 1 度通せばいい」用。

<!-- migrated from memory/feedback_npm_2fa_passkey.md (2026-05-11) -->
### npm CLI publish は Granular Token + Bypass 2FA 一本化

npm は 2025-09 以降、新規 2FA 登録で **TOTP (Authenticator app) 選択肢を削除**。passkey / security key のみ。
2025-11-19 に classic token も廃止、Granular Token のみ。

`npm publish` で `403 Two-factor authentication or granular access token with bypass 2fa enabled is required` が出たら:

1. `https://www.npmjs.com/settings/<user>/tokens/new` で Granular Access Token を発行
2. scope 限定 + Read/Write 権限 + **Bypass 2FA** ☑
3. `~/.npmrc` の `//registry.npmjs.org/:_authToken=` を差し替え

注意:
- Linux は Touch ID 等が無いので passkey 登録はスマホ hybrid (QR + Bluetooth)
- passkey 登録後も `npm publish` 内部で OTP を要求するため、`--auth-type=web` ですら通らない
- Bypass 2FA はバグあり (`npm/cli#8869`) — 発行時にチェック外れることあり、別ブラウザ / シークレットモードで再試行
- 90 日ローテーション強制 (npm security update 2025-11)
- 将来は OIDC Trusted Publishing (GitHub Actions) への移行が推奨

<!-- migrated from memory/feedback_npm_global_install_cache.md (2026-05-11) -->
### `sudo npm i -g` キャッシュ罠 (changed N でも実 file が古い)

`sudo npm i -g @scope/pkg@latest` は **出力が成功風でも実 file を更新しないことがある**。

```bash
sudo npm cache clean --force
npm cache clean --force
sudo npm i -g @scope/pkg@<explicit-version> --force
cat /usr/lib/node_modules/@scope/pkg/package.json | grep version   # 必ず確認
```

それでも駄目なら `sudo rm -rf /usr/lib/node_modules/@scope/pkg` → 再 install。
tarball URL 直接 install `sudo npm i -g https://registry.npmjs.org/.../xxx.tgz` も最終手段。

例: 2026-04-24 gcloudSec v3.1.0 publish 直後、`sudo npm i -g @yhonda/gcloud-secrets@latest` が
"changed 47 packages" 応答も `/usr/lib/node_modules/@yhonda/gcloud-secrets/package.json` は 3.0.0 のまま。
原因は sudo npm のキャッシュ (`~/root/.npm`) に古い tarball / metadata。

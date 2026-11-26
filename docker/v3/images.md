# 用 Docker Hub 镜像部署 AA v3（fork 专用）

上游的 `docker/v3/compose.yml` 全部在服务器本地构建。这个 fork 额外提供：

| 文件 | 作用 |
| --- | --- |
| `.github/workflows/docker-images-v3.yml` | 定时检查 `anywhere-labs/Agents-Anywhere` 的 `main`，有新提交就用它构建 3 个 v3 镜像并推送到 Docker Hub |
| `.github/workflows/docker-images-v2.yml` | 构建 v2 一体化镜像（`docker/Dockerfile`，server + web-next），只在 v2 相关目录变化时才重建 |
| `docker/v3/compose.images.yml` | compose override，把 `build:` 换成已发布的 `image:`，服务器上不再需要构建 |
| `docker/v3/images.md` | 本文件 |

## v3 镜像

| 镜像 | 来源 | 说明 |
| --- | --- | --- |
| `hraulein/agents-anywhere-control` | `server-v3/Dockerfile` | 控制面 `aa_control`，`control`、`migrate`、`s3-bucket` 三个服务共用 |
| `hraulein/agents-anywhere-web` | `docker/v3/web.Dockerfile` | web-v3（Next.js standalone），`/api/control/*` 转发目标在构建时固定为 `http://control:8080` |
| `hraulein/agents-anywhere-router` | `docker/v3/router.Dockerfile` | MeshCall Router，从 `meshcall-router-linux-{x64,arm64}@0.4.0` 取二进制 |

## v2 镜像

| 镜像 | 来源 | 说明 |
| --- | --- | --- |
| `hraulein/agents-anywhere-v2` | `docker/Dockerfile` | v2 一体化镜像：`server/`（FastAPI）+ 构建后的 `web-next/` 静态站，监听 8000，数据卷 `/data`；compose 模板见 [`docker/v2/compose.yml`](../v2/compose.yml) |

v2 与 v3 用**不同仓库**区分，tag 规则完全一致（见下文），不用前缀也能分清。DSH 插件目前仍只支持 v2，
所以两者要同时存在。v2 工作流只在 `server/`、`web-next/` 或 `docker/Dockerfile` 相对上一个 v2 构建有变化时才
构建，纯 v3 的提交会被跳过。

早期版本发布过 `hraulein/agents-anywhere-server`，它和这里的 `-control` 内容相同（都来自 `server-v3/Dockerfile`）；改名后旧仓库不再更新，可以在 Docker Hub 上删掉。

平台：`linux/amd64`、`linux/arm64`。Router 没有 `arm/v7` 二进制，所以不支持 32 位 ARM。

## 标签

四个仓库使用同一套 tag：

| Tag | 含义 |
| --- | --- |
| `sha-<12 位>` | 构建所用的上游 commit，唯一确定一次构建 |
| `date-YYYYMMDD` | 构建日期（UTC），同一天多次构建会互相覆盖，仅供人看 |
| `latest` | 上游 `main` 的最新一次成功构建；手动构建历史 commit 或 tag 时不会更新 |

仓库没有提交 lockfile，`yarn install` / `uv sync` 每次都会重新解析依赖，所以同一个 commit 隔一段时间重建，
内容可能不同。**要可复现就固定 `sha-` 标签**，不要用 `latest`。

两个工作流都会自动清理旧 tag：每个仓库保留最新 20 个 `sha-*` 和 30 个 `date-*`，其余删除
（`latest` 不删）。这既控制 Docker Hub 的存储/配额，也避免 tag 列表无限增长。

## 一次性准备：仓库 secrets

在 fork 仓库 `hraulein/Agents-Anywhere` → `Settings → Secrets and variables → Actions → New repository secret`：

| Secret | 值 |
| --- | --- |
| `DOCKERHUB_USERNAME` | Docker Hub 用户名（不是邮箱） |
| `DOCKERHUB_TOKEN` | Docker Hub → Account settings → Personal access tokens，权限 **Read & Write** |
| `GOTIFY_SERVER`（可选） | Gotify 服务地址，例如 `https://gotify.example.com` |
| `GOTIFY_TOKEN`（可选） | Gotify 应用 token |

没有 Gotify 的两个 secret 时，构建照常进行，只是不发通知。首次推送镜像会自动在 Docker Hub 建**公开**仓库。

## 触发

- **v3 定时**：每天 03:17（Asia/Shanghai）检查上游 `main`；commit 没变、且 `sha-<12>` 已存在时跳过。
- **v2 定时**：每天 03:27 检查上游 `main`；只有当 `server/`、`web-next/` 或 `docker/Dockerfile` 相对上一个
  v2 构建有变化时才构建，纯 v3 提交不会触发。
- **手动**：Actions → `Docker Images v3` 或 `Docker Images v2` → `Run workflow`。`ref` 留空表示上游 `main`，
  也可以填某个 tag、branch 或完整 sha；`force` 勾上则即使该 commit 已发布也重建。
- 每个仓库的 `latest` 只在构建的是上游 `main` 当前提交时才更新。

## 部署

服务器上按上游文档初始化，然后改用 override 拉取镜像：

```bash
cd docker/v3
./init.sh aa.example.com --drive          # 与上游文档相同，生成 .env

docker compose -f compose.yml -f compose.images.yml pull
docker compose -f compose.yml -f compose.images.yml up -d --no-build
```

`compose.images.yml` 用 `!reset` 清掉了所有 `build:`，所以不会退回本地构建。`!reset` 需要 Compose **v2.24.4 及以上**；版本太低时 `config` 会报错，升级 Docker Compose 即可。

不启用云盘时去掉 `--drive` 和 `--profile drive`；外部 S3（R2/OSS/S3）的配置方法与上游文档一致。

### 固定版本

```bash
AA_IMAGE_TAG=sha-1a2b3c4d5e6f docker compose -f compose.yml -f compose.images.yml pull
AA_IMAGE_TAG=sha-1a2b3c4d5e6f docker compose -f compose.yml -f compose.images.yml up -d --no-build
```

`AA_IMAGE_NAMESPACE` 可以换命名空间（例如把镜像镜像到别的账号或内网 registry）。**升级**就是把 `AA_IMAGE_TAG` 换成新的 sha 再执行 `pull` + `up -d --no-build`；`migrate` 会自动跑新迁移。**回滚**就是换回旧 sha；数据库迁移不会自动回退，跨迁移回滚前先备份 postgres 卷。

## 限制

- 镜像只是在 CI 里构建，不改变上游的发布节奏；`latest` 跟随上游 `main`，可能包含未发布的改动。
- 上游的版本 tag（`v2.2.0` 等）描述产品版本，`server-v3`/`web-v3` 仍是 `3.0.0-alpha.1`，所以这里不生成 semver 标签，避免误导。
- 镜像里没有 Caddy 配置和 `.env`，HTTPS、域名、密钥仍由 `docker/v3/` 的 `init.sh` 与 `Caddyfile` 决定。
- GitHub 定时任务在仓库 60 天无活动后会停用；上游有提交时构建任务会推送镜像但不会改本仓库，所以若长期没上游更新，去 Actions 页面点一次 `Run workflow` 即可续期。

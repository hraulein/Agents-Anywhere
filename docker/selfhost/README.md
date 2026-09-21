# Agents Anywhere 自托管部署指南

面向 **N100（Docker Compose）→ Tailscale/headscale → 阿里云 Nginx（HTTPS）** 这套形态。

仓库里已有的 `docker/docker-compose.postgres.yml` 是通用版，会把 Web 端口开在
`0.0.0.0`。本目录是给自托管场景收敛过的版本：只绑 Tailscale 地址、加资源上限和
日志轮转、关键变量缺失直接报错。

---

## 0. 架构与数据流

```
  手机 / 平板 / 笔记本 / 桌面客户端
                │  https://aa.example.com
                ▼
        ┌───────────────────┐
        │  阿里云 Nginx      │  443 终止 TLS，转发所有路径
        │  (Let's Encrypt)  │
        └─────────┬─────────┘
                  │  http://100.x.y.z:5174   ← 走 tailnet，不经公网
                  ▼
        ┌───────────────────┐
        │  headscale 网络    │
        └─────────┬─────────┘
                  ▼
        ┌───────────────────────────────────────┐
        │  N100                                  │
        │  ┌─────────────────────────────────┐   │
        │  │ server-next   :5174 → 容器 8000  │   │  FastAPI + 静态 Web 同源
        │  ├─────────────────────────────────┤   │
        │  │ postgres-next  (不发布宿主端口)  │   │  唯一可信数据源
        │  ├─────────────────────────────────┤   │
        │  │ redis-next     (不发布宿主端口)  │   │  协调 / Pub-Sub / Timeline 写缓冲
        │  └─────────────────────────────────┘   │
        └───────────────────────────────────────┘
                  ▲  WebSocket 出站连接
                  │
        ┌─────────┴─────────┐
        │  工作设备 Connector │  Agent 真正在这里执行
        │  (Codex/Claude/DSH)│
        └───────────────────┘
```

三个关键事实，决定了后面所有配置：

1. **Web 控制台由 FastAPI 一起提供，API 和全部 WebSocket 都在 `/api/v2` 前缀下。**
   所以 Nginx 整站一个 `location /` 就够，不需要给 API 单独开 location。
2. **服务端直接读 `X-Forwarded-Proto` 和 `X-Forwarded-Host` 来拼绝对 URL。**
   反向代理少传这两个头，会生成 `http://` 链接，典型症状是登录成功后又被弹回登录页。
3. **附件上传上限是单请求 5 个文件 × 25 MiB。** Nginx 默认的 `client_max_body_size 1m`
   会让上传直接 413。

---

## 1. 本目录内容

| 文件 | 作用 |
| --- | --- |
| `.env.example` | 配置模板，复制成 `.env` 后填写 |
| `docker-compose.selfhost.yml` | 自托管编排（派生自上游 `docker-compose.postgres.yml`） |
| `nginx/agents-anywhere.conf` | 阿里云上的 Nginx server 配置 |
| `aa.sh` | 运维脚本：构建、启停、探活、建管理员、备份 |
| `.gitignore` | 防止填好的 `.env` 和备份被提交 |

---

## 2. 前置条件

**N100：**

- Docker Engine + Compose v2（`docker compose version` 有输出即可）
- Tailscale 已在运行（你的环境里是名为 `tailscale` 的容器）
- 磁盘预留 ≥ 20 GiB 给镜像和数据卷

**阿里云：**

- 已加入**同一个** headscale 网络
- 已装 Nginx，且有域名和可用证书

**端口占用（已按你 N100 的实际清单避让）：**

| 端口 | 现状 | 说明 |
| --- | --- | --- |
| 80 / 443 | 你的 `nginx` 容器 | 本方案不碰 |
| 8000 | `supabase-kong` | 所以宿主机端口用 **5174**，不要改成 8000 |
| 5432 / 6543 | `supabase-pooler` | 本方案不发布 Postgres 宿主端口，无冲突 |
| **5174** | 空闲 | 本方案使用 |

> 不要复用 Supabase 那套 PostgreSQL。本服务的迁移和 advisory lock 需要独立可控的库，
> 且升级节奏不同。容器内自带的 Postgres 不会跟它抢 5432。

---

## 3. 阶段一：N100

### 3.1 拿到 N100 的 Tailscale 地址

Tailscale 已稳定运行，这里只需要一个值：

```bash
docker exec tailscale tailscale ip -4          # 期望输出 100.x.y.z
```

宿主机上如果直接有 `tailscale` 命令，`tailscale ip -4` 也一样。

把结果填进 `.env` 的 `AGENTS_ANYWHERE_BIND_ADDR`。启动后如果容器报
`bind: cannot assign requested address`，说明这个地址不在宿主机网卡上，
见[附录 A](#附录-atailscale-不是-host-网络时)。

### 3.2 拉代码

```bash
sudo mkdir -p /opt && cd /opt
git clone <你的 fork 地址> agents-anywhere
cd agents-anywhere
git log --oneline -1
```

### 3.3 生成配置文件

```bash
cd /opt/agents-anywhere
chmod +x docker/selfhost/aa.sh
./docker/selfhost/aa.sh init --domain aa.example.com --bind-addr 100.108.208.20
```

`init` 会一次做完这几件事：

- 用 `openssl rand` 生成 `POSTGRES_PASSWORD`（24 字节）和 `AGENT_SERVER_SECRET`（32 字节）；
- 把对外域名写进 `AGENT_SERVER_PUBLIC_ORIGIN`；
- 写死绑定地址——**不传 `--bind-addr` 时它会自动 `docker exec tailscale tailscale ip -4` 探测**，
  探到就当作默认值；
- 产出 `docker/selfhost/.env` 并设成 `600`，四项替换都校验过后才落盘。

非交互（适合写进部署脚本）：

```bash
./docker/selfhost/aa.sh init \
  --domain aa.example.com \
  --bind-addr 100.108.208.20
```

生成后核对一下（密钥不会回显）：

```bash
grep -E '^(AGENT_SERVER_PUBLIC_ORIGIN|AGENTS_ANYWHERE_BIND_ADDR)=' docker/selfhost/.env
```

预期：

```dotenv
AGENT_SERVER_PUBLIC_ORIGIN=https://aa.example.com
AGENTS_ANYWHERE_BIND_ADDR=100.108.208.20
```

> 密码只准用字母数字——脚本已经这么生成了。含 `@` `:` `/` 会破坏拼接出的数据库
> 连接串。想手工填写就照 `.env.example` 里的注释改，填完别忘了 `chmod 600`。
> 已有 `.env` 时 `init` 会拒绝覆盖，要重来加 `--force`。

### 3.4 按实测内存收紧资源上限

N100 实测：

```
Mem:  15Gi total   9.2Gi available
Swap: 975Mi total  975Mi used   ← 已用满，只剩 252Ki
```

两个要点：

- **9.2 GiB 可用**，跑得起来，但不要套用上游那份 4 worker 的 8 核 profile。
- **swap 已经 100% 占满**。这说明内核早就把能换出的页都换出去了，再加负载时**没有缓冲**；
  一旦超额，OOM killer 挑的是内存占用最大的进程，往往是 Jellyfin / Emby / Supabase
  这些老住户，而不是新来的容器。所以这里按"先小后大"起步。

`.env` 里的默认值就是照这个给的：

```dotenv
SERVER_MEM_LIMIT=3g
POSTGRES_MEM_LIMIT=1g
REDIS_MEM_LIMIT=512m
SERVER_CPUS=3.0
```

合计 4.5 GiB 上限，留出余量。跑够一天再按实际数据决定要不要放宽：

```bash
docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}'
```

#### 首次构建是全流程的内存峰值

`docker/Dockerfile` 会在容器里跑一次 Next.js 静态导出（Node 构建通常要吃 1.5–3 GiB），
外面还叠一层 `uv sync`。这是整个部署过程中最容易触发 OOM 的时刻：

- 挑媒体库空闲的时段构建；
- 构建中途被 OOM 杀掉的话，临时停掉一个重量级服务再试——你这里 Jellyfin 和 Emby
  功能重叠，停掉其中一个能立刻腾出可观内存；
- 也可以在别的机器上构建好镜像再传过来，你有 buildx 多架构构建器（
  `buildx_buildkit_multiarch0`），这条路是通的。

#### 顺手把 swap 加大

975 MiB 对这个体量的栈偏小。注意 swap 的磨损来自**换入换出的抖动**，不是"被占用"
这个状态——8G swapfile 即使填满冷页也只写了一次 8G，对 SSD 寿命可忽略。

**先判断落点。** Debian 安装器默认把 swap 做成 LVM 逻辑卷：

```bash
swapon --show                      # TYPE 是 partition / file / lvm
sudo vgs -o vg_name,vg_size,vg_free
df -hT / /var /home
```

| 情况 | 做法 |
| --- | --- |
| `vg_free` ≥ 8G | 直接扩卷，最干净：`swapoff -a` → `lvextend -L +8G /dev/<vg>/<swap_lv>` → `mkswap` → `swapon -a` |
| `vg_free` ≈ 0 | 卷组已满，扩不了，改用 swapfile（下面） |
| 有独立 `/home` 且空闲大 | **优先放 `/home/swapfile`**，通常和系统盘同一块 SSD |

选 swapfile 的落点时：不要放 `/`（系统盘往往很紧）、不要放 `/var`（Docker 数据目录，
通常也紧），不要放机械盘（换入一次就是十几毫秒的寻道）。`/home` 有空间就放它。

```bash
sudo fallocate -l 8G /home/swapfile
sudo chmod 600 /home/swapfile          # 权限不对 swapon 会以 insecure permissions 拒绝
sudo mkswap /home/swapfile
sudo swapon /home/swapfile

# nofail：/home 常是独立 LV，将来调整容量时不至于拖累开机
grep -q '^/home/swapfile ' /etc/fstab || \
  echo '/home/swapfile none swap sw,nofail 0 0' | sudo tee -a /etc/fstab

swapon --show && free -h
```

全程在线，不用停 Docker、不用重启，**不到 15 秒**。

然后把 swappiness 降下来。swap 被占满时默认值 60 仍会让内核偏激进地换出：

```bash
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-agents-anywhere.conf
sudo sysctl --system
```

回滚：

```bash
sudo swapoff /home/swapfile
sudo sed -i '\|^/home/swapfile |d' /etc/fstab
sudo rm /home/swapfile
```

> 两个提醒：
> 1. **swap 不能替代内存。** 它只是把"被 OOM 杀掉"变成"变慢"。本方案的 Redis 是
>    `noeviction` + AOF `everysec`，被换出会让写延迟从毫秒级涨到百毫秒级，表现为
>    界面间歇性卡顿且很难归因。真出现这种卡顿，优先怀疑 swap。
> 2. **Docker 容器默认也会吃 swap。** 只设 `mem_limit`（即 `--memory`）时，
>    `--memory-swap` 默认为内存上限的 2 倍。所以 `SERVER_MEM_LIMIT=3g` 不代表该容器
>    最多占 3G 内存。想让某个容器完全不换出，在 compose 里给它加 `mem_swappiness: 0`。

#### 先确认 Docker 数据目录有空间

新栈的 Postgres 数据、Redis AOF 和 server 镜像都落在 Docker 数据根目录
（默认 `/var/lib/docker`）。这个分区在跑了一堆服务的机器上经常已经很满：

```bash
df -h /var/lib/docker
docker system df
docker system df -v | sed -n '/VOLUME NAME/,$p'   # 看清哪些卷是"未被使用"的
```

有可回收空间就先清，**别等到构建镜像时才写满**：

```bash
docker builder prune -f            # 构建缓存，纯垃圾
docker volume prune -f             # 未被任何容器挂载的卷，删前务必核对上一条输出
docker image prune -a -f           # 未被任何容器引用的镜像
```

如果 Docker 分区本身偏小，长期解法是把数据根目录迁到空闲分区（`/etc/docker/daemon.json`
里改 `data-root`，然后停 Docker、`rsync` 过去、重启）。

### 3.5 构建并启动

```bash
cd /opt/agents-anywhere
./docker/selfhost/aa.sh up
```

首次构建要编译 `web-next` 静态站点，N100 上大约 5–15 分钟。
脚本会构建镜像、启动四个服务、跑完迁移，并轮询 `/api/v2/health` 直到就绪。

预期输出末尾：

```
[ok] 服务已就绪
  健康检查   http://100.x.y.z:5174/api/v2/health                    200
  就绪检查   http://100.x.y.z:5174/api/v2/health/ready              200
  对外地址： https://aa.example.com
  首次部署请执行： ./aa.sh bootstrap
```

手动看状态：

```bash
./docker/selfhost/aa.sh ps
```

### 3.6 创建首位管理员

首次启动时数据库没有用户，服务会把一次性 setup token 打到 `server-next` 日志里
（默认 15 分钟有效）：

```bash
./docker/selfhost/aa.sh bootstrap
```

它会打印 token 和设置入口。两种方式任选：

- **浏览器方式（推荐）**：打开 `https://aa.example.com`，页面会识别出
  `needsBootstrap`，把 token 粘进去即可。
- **命令行方式**：`./docker/selfhost/aa.sh bootstrap --create`，交互式输入邮箱和密码，
  脚本直接在容器里调接口完成创建，不依赖宿主机有没有 curl/jq。

> 管理员一旦建立，**自助注册会自动关闭**。后续账号由该实例的管理员管理。
> token 过期了不要紧：刷新一次登录页，服务会重新生成并再次打印到日志，再跑一次
> `bootstrap` 即可。

### 3.7 本机自检

```bash
./docker/selfhost/aa.sh health
```

三项应该都是 200（第三项「对外域名」此时因为阿里云还没配，会是 000 或 502，正常）。

---

## 4. 阶段二：阿里云（Nginx + HTTPS）

### 4.1 让阿里云进同一个 headscale

```bash
tailscale up --login-server https://<你的 headscale 地址> --authkey <预授权key>
tailscale status          # 应该能看到 N100 节点
tailscale ip -4
```

### 4.2 先验证能直连，再动 Nginx

**这一步不要跳过。** 先确认网络层通了，后面出问题才能确定是 Nginx 的锅：

```bash
curl -v http://100.x.y.z:5174/api/v2/health
```

期望 `HTTP/1.1 200 OK` 且 body 含 `"status":"ok"`。

- 卡住不动 → 安全组/防火墙挡了 tailnet 流量，或 N100 上没绑到这个地址（回 3.1 检查）。
- `Connection refused` → 服务没监听在该地址上，`./aa.sh ps` 看容器是否在跑。

### 4.3 解析域名

把 `aa.example.com` 的 A 记录指向**阿里云的公网 IP**（不是 N100 的地址）。

### 4.4 申请证书

```bash
sudo certbot certonly --webroot -w /var/www/certbot -d aa.example.com
```

或者用你现有的签发方式。证书路径要和 Nginx 配置里的 `ssl_certificate` 对得上。

### 4.5 放置 Nginx 配置

先替换两个占位符，再放进去：

```bash
cd /opt/agents-anywhere     # 或在有仓库的地方操作
sed -e 's/aa\.example\.com/你的真实域名/g' \
    -e 's/100\.x\.y\.z/100.64.0.10/g' \
    docker/selfhost/nginx/agents-anywhere.conf \
  | sudo tee /etc/nginx/conf.d/agents-anywhere.conf >/dev/null

sudo nginx -t && sudo systemctl reload nginx
```

如果阿里云用的是 `sites-available/sites-enabled` 结构，丢进
`/etc/nginx/sites-available/` 再 `ln -s` 到 `sites-enabled/` 即可。
`map` 和 `upstream` 必须处于 `http{}` 上下文——`nginx.conf` 会在 `http{}` 内
`include conf.d/*.conf`，所以整个文件直接放进去就行，不用改主配置。

### 4.6 验收

```bash
# 1. 健康检查
curl -i https://aa.example.com/api/v2/health
#    期望 200 + JSON

# 2. WebSocket 升级头是否透传
curl -i -N \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  https://aa.example.com/api/v2/dashboard/ws
```

WebSocket 那一项的判读：

| 返回 | 含义 |
| --- | --- |
| `101 Switching Protocols` | 完全通了 |
| `401` / `403` | Nginx 转发正常，只是没带票据 —— 也是通的 |
| `400` / `404` / `426` | Upgrade 头没透传，检查 `proxy_set_header Upgrade` 和 `Connection` |

```bash
# 3. 浏览器打开，确认能登录且刷新后不掉线
open https://aa.example.com
```

**最终验收：登录 → 刷新页面仍在登录态 → 打开一个会话看到 Timeline 实时更新。**
第三步是真正的 WebSocket 验收，前两步都过了但这一步卡住，就是长连接被掐了，
检查 `proxy_read_timeout`。

---

## 5. 阶段三：接入工作设备（Connector）

Agent 在 Connector 所在的机器上执行，服务端只做转发和存储。所以**至少要有一台工作设备**
连上来，否则建完会话也没东西执行。

### 5.1 桌面客户端

在工作机上打开桌面客户端，登录方式选「连接自托管服务」，填服务根地址：

```
https://aa.example.com          ← 不要带 /api/v2
```

客户端会探测 `/api/v2/health` 来确认这是不是正常的 Agents Anywhere 服务。
探测失败时先手工 `curl https://aa.example.com/api/v2/health` 对比。

### 5.2 Connector CLI（无图形界面的机器）

```bash
cd connector
uv sync

uv run anywhere-cli start \
  --server-url https://aa.example.com \
  --connector-id conn_xxx \
  --connector-token cxt_xxx
```

`connector-id` / `connector-token` 从 Web 的配对流程取。要长期后台运行，配好之后用
`systemd` 或 `screen` 托管；先确认能连上再设开机自启。

### 5.3 可选：在 N100 上用 Docker 跑 Connector

如果你想让 N100 本身也成为一台工作设备（这样没开别的机器时也能跑 Agent），
仓库里已经有现成镜像。配对信息存在 `/data` 卷里（镜像里
`AGENT_CONNECTOR_CONFIG=/data/connector.json`），所以容器重建不会掉配对。

```bash
# 1. 构建（只需一次）
docker build -f docker/Dockerfile.connector-agents-ubuntu \
  -t agents-anywhere-connector:agents-ubuntu2404 .

# 2. 后台启动，走配对流程
docker run -d --name aa-connector \
  --restart unless-stopped \
  -v aa-connector-data:/data \
  -v /srv/workspace:/workspace \
  -e AGENT_CONNECTOR_MODE=pair \
  -e AGENT_SERVER_URL=https://aa.example.com \
  agents-anywhere-connector:agents-ubuntu2404

# 3. 读配对提示，按提示在 Web 界面完成绑定
docker logs -f aa-connector
```

`AGENT_SERVER_URL` 用**对外地址**，这样配对流程生成的链接是你在浏览器里打得开的。
容器需要能出网做 DNS 解析和 HTTPS 访问。

如果不想让这台机器绕公网，也可以改用 tailnet 地址
（`-e AGENT_SERVER_URL=http://100.x.y.z:5174`），代价是配对提示里的链接会指向
内网地址，需要自己手工换成对外域名再打开。

把 `AGENT_SERVER_URL`、`AGENT_CONNECTOR_ID`、`AGENT_CONNECTOR_TOKEN` 三个都给出时，
可以改用 `-e AGENT_CONNECTOR_MODE=token` 跳过配对，直接凭据启动。

---

## 6. 日常运维

```bash
cd /opt/agents-anywhere

./docker/selfhost/aa.sh init            # 首次：生成 .env
./docker/selfhost/aa.sh health          # 探活
./docker/selfhost/aa.sh ps              # 容器状态
./docker/selfhost/aa.sh logs            # 跟随 server-next 日志
./docker/selfhost/aa.sh logs postgres-next
./docker/selfhost/aa.sh restart         # 重启 server
./docker/selfhost/aa.sh bootstrap       # 找回 setup token
./docker/selfhost/aa.sh backup          # 备份库 + 附件卷
./docker/selfhost/aa.sh shell           # 进 server 容器
./docker/selfhost/aa.sh psql            # 进数据库
./docker/selfhost/aa.sh version         # 当前部署的提交
./docker/selfhost/aa.sh down            # 停止（保留数据卷）
```

容器都是 `restart: unless-stopped`，N100 重启后会自动拉起。
确认 Docker 本身开机自启：`sudo systemctl enable --now docker`。

---

## 7. 备份、升级与回滚

### 7.1 备份

```bash
./docker/selfhost/aa.sh backup
```

产出两个文件在 `docker/selfhost/backups/`：

- `pg-<时间戳>.sql.gz` —— PostgreSQL 逻辑备份（唯一可信数据源）
- `files-<时间戳>.tgz` —— 附件卷

Redis 不用单独备份：它承载的是**已接受但还没刷盘的 Timeline 写**，
真正的持久化真相在 PostgreSQL。丢 Redis 可能造成序列缺口，但不会重复分配版本号。

**把备份复制到 N100 之外。** 同机备份不算备份。

恢复数据库：

```bash
gunzip -c backups/pg-<时间戳>.sql.gz | \
  ./docker/selfhost/aa.sh psql
```

恢复附件：

```bash
vol=$(docker volume ls -q | grep files-next)
docker run --rm -v "$vol":/data -v "$PWD/backups":/backup alpine:3.20 \
  tar xzf /backup/files-<时间戳>.tgz -C /data
```

### 7.2 升级

```bash
cd /opt/agents-anywhere
git pull
./docker/selfhost/aa.sh up        # 会重建镜像并自动跑迁移
```

`migrate-next` 在每次 `up` 时都会执行，已是最新版本时是空操作；迁移通过 PostgreSQL
会话级 advisory lock 串行化，不会并发打架。

**大版本升级前先备份**，并确认上游发布说明里没有「旧版本和新版本不能同时写同一个库」
这类要求。`docker/README.md` 里记录过这种 stop-migrate-start 的场景。

### 7.3 这个 fork 怎么跟上游同步

本目录所有文件都是**新增**的，没有改动上游任何文件，所以合并上游更新时不会冲突。

```bash
git remote add upstream https://github.com/anywhere-labs/Agents-Anywhere.git
git fetch upstream
git merge upstream/main            # 或 git rebase upstream/main
```

`docker-compose.selfhost.yml` 是 `docker/docker-compose.postgres.yml` 的派生副本。
上游如果新增了必需的环境变量，需要手工同步过来。建议每次合并上游后：

```bash
git diff upstream/main -- docker/docker-compose.postgres.yml
```

看到新增变量就补进 `docker-compose.selfhost.yml` 和 `.env.example`。

---

## 8. 排错

| 症状 | 原因 | 处理 |
| --- | --- | --- |
| 上传附件报错，或 Nginx 日志有 `413` | `client_max_body_size` 还是默认 1m | 配置里已设 `160m`，确认文件真的生效并 reload 了 |
| 502 Bad Gateway | Nginx 连不到 `100.x.y.z:5174` | 先在阿里云上 `curl http://100.x.y.z:5174/api/v2/health`，不通就是网络层，别在 Nginx 里找 |
| 登录成功后又弹回登录页 | 少了 `X-Forwarded-Proto`，服务端生成了 `http://` 链接 | 检查配置里那四个转发头 |
| 页面能打开、能登录，但对话不刷新、终端连不上 | WebSocket 被掐断或 Upgrade 没透传 | 按 4.6 的 curl 判读；确认 `proxy_read_timeout 3600s` 和 `map` 生效 |
| 页面加载像卡住、输出一段段蹦 | Nginx 缓冲了流式响应 | 确认 `proxy_buffering off` 生效 |
| 找不到 setup token | 管理员已建过 / 日志被轮转 / 服务没起 | `./aa.sh ps` → 刷新登录页 → `./aa.sh logs server-next \| grep setup-token` |
| token 提示过期 | 默认 15 分钟 | 刷新登录页会重新打印；或把 `AGENT_SERVER_SETUP_TOKEN_TTL` 调大 |
| 容器起来就退出，日志提 `required variable` | `.env` 里有必填项没填 | 报错信息直接点名了是哪个变量 |
| `bind: cannot assign requested address` | `AGENTS_ANYWHERE_BIND_ADDR` 填的地址宿主机上没有 | 回 3.1 确认 tailnet 地址；见附录 A |
| 服务随机 OOM / 容器被杀 | N100 内存被现有负载吃满 | 降 `SERVER_MEM_LIMIT` 等上限，或先停掉不用的服务；`dmesg \| grep -i oom` 确认 |
| 数据库连接数打满 | worker 数 × 连接池超过 Postgres 上限 | 保持 `AGENT_SERVER_WORKERS=1`，别套用 `docker-compose.8cpu.yml` |
| N100 重启后服务没起来 | Docker 没设开机自启 | `sudo systemctl enable --now docker` |

看容器为什么退出：

```bash
docker compose --env-file docker/selfhost/.env \
  -f docker/selfhost/docker-compose.selfhost.yml logs --tail 100 <服务名>
```

---

## 9. 安全清单

- [ ] `AGENT_SERVER_SECRET` 和 `POSTGRES_PASSWORD` 都是随机生成，不是模板里的值
- [ ] `docker/selfhost/.env` 权限 `600`，且没有提交进 Git（本目录 `.gitignore` 已兜底）
- [ ] `AGENTS_ANYWHERE_BIND_ADDR` 填的是 Tailscale 地址，**不是** `0.0.0.0`
- [ ] 阿里云安全组只放行 80/443，不放行 5174
- [ ] Postgres 和 Redis 的宿主端口没有发布出去（本编排默认不发布）
- [ ] HTTPS 验收通过后再开 HSTS
- [ ] 备份定期异地保存，并且**实际演练过一次恢复**
- [ ] 全新部署后确认自助注册已自动关闭

---

## 附录 A：Tailscale 不是 host 网络时

你的 Tailscale 已经稳定运行，正常情况下不需要看这一节。只有在 `aa.sh up` 之后
容器报 `bind: cannot assign requested address`，或者从阿里云 `curl` N100 的
`100.x` 地址不通时，才需要往下查。

原因：宿主机上没有 `tailscale0` 接口和 `100.x` 地址，说明 tailscale 容器跑在独立的
网络命名空间里，宿主机的应用进程没法直接绑那个地址。三选一：

**方案 1（推荐）：把 tailscale 改成 host 网络。**
这是 `tailscale/tailscale` 镜像的标准用法，改完宿主机就有 `tailscale0` 和 `100.x` 地址，
本指南其余部分原样适用。代价是 tailscale 容器的改动会影响现有其他依赖它的服务，改之前
先确认没有别的服务靠它做端口映射。

**方案 2：让 Nginx 直连 tailscale 容器的地址。**
把 `AGENTS_ANYWHERE_BIND_ADDR` 设为 `0.0.0.0`（宿主机所有网卡），
然后在 N100 上用 nftables/ufw 只放行 tailnet 网段访问 5174：

```bash
# 仅示意，请按实际网段和现有防火墙规则调整
sudo ufw allow from 100.64.0.0/10 to any port 5174 proto tcp
sudo ufw deny 5174/tcp
```

**方案 3：让 N100 本机再跑一个代理。**
在宿主机上把 5174 转发到 tailscale 容器可达的地址。多一跳，也最容易配错，
除非前两个方案都不行，否则不建议。

无论选哪个，**改完都要回到 4.2 从阿里云 `curl` 验证一次**。

---

## 附录 B：环境变量速查

| 变量 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- |
| `POSTGRES_PASSWORD` | ✅ | — | 数据库密码，只用字母数字 |
| `AGENT_SERVER_SECRET` | ✅ | — | 令牌签名密钥，`openssl rand -hex 32` |
| `AGENT_SERVER_PUBLIC_ORIGIN` | ✅ | — | 对外 HTTPS 地址，末尾无斜杠 |
| `AGENTS_ANYWHERE_BIND_ADDR` | ✅ | — | 只绑这个地址，填 Tailscale IP（或显式填 `127.0.0.1`） |
| `AGENT_SERVER_CORS_ORIGINS` | | 同 PUBLIC_ORIGIN | 逗号分隔 |
| `AGENTS_ANYWHERE_WEB_PORT` | | `5174` | 宿主端口，容器内固定 8000 |
| `AGENT_SERVER_SETUP_TOKEN_TTL` | | `900` | setup token 秒数 |
| `AGENT_SERVER_WORKERS` | | `1` | 必须为 1（除非另配 Redis 并读性能文档） |
| `AGENT_SERVER_EVENT_WORKERS` | | `2` | 每 worker 的事件预处理子进程 |
| `AGENT_SERVER_DB_POOL_SIZE` / `_MAX_OVERFLOW` | | `10` / `20` | 数据库连接池 |
| `REDIS_MAXMEMORY` | | `256mb` | Redis 上限，noeviction，调小有写失败风险 |
| `AGENT_SERVER_TIMELINE_REVISION_LEASE_SIZE` | | `4096` | 非排障不要改 |
| `AGENT_SERVER_MIGRATION_LOCK_TIMEOUT` | | `120` | 迁移等锁上限（秒） |
| `SERVER_MEM_LIMIT` / `SERVER_CPUS` | | `3g` / `3.0` | 资源上限 |
| `POSTGRES_MEM_LIMIT` / `REDIS_MEM_LIMIT` | | `1g` / `512m` | 资源上限 |
| `AGENT_SERVER_FILES_BACKEND` | | `local` | 改 `s3` 时需配套 `_S3_*` 变量 |

完整的服务端变量清单见 `docker/README.md` 和 `docs/`。

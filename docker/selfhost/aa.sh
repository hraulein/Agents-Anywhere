#!/usr/bin/env bash
# =============================================================================
# Agents Anywhere · 自托管运维脚本（在 N100 上以 root / docker 组用户执行）
#
#   ./aa.sh init        生成 .env（随机密钥 + 自动探测 Tailscale IP）
#   ./aa.sh up          构建镜像并启动全套，等待就绪
#   ./aa.sh down        停止（保留数据卷）
#   ./aa.sh restart     重启 server-next
#   ./aa.sh ps          查看各服务状态
#   ./aa.sh logs [svc]  跟随日志（默认 server-next）
#   ./aa.sh health      从宿主机探活
#   ./aa.sh bootstrap   打印 setup token 和首次设置入口
#   ./aa.sh bootstrap --create
#                       交互式创建首位管理员（走容器内 Python，无需宿主 curl）
#   ./aa.sh migrate     手动跑一次数据库迁移
#   ./aa.sh backup      备份数据库和附件卷到 docker/selfhost/backups/
#   ./aa.sh shell       进入 server-next 容器
#   ./aa.sh psql        进入 PostgreSQL
#   ./aa.sh version     打印当前部署的 git 提交
#
# 环境文件默认是 docker/selfhost/.env，可用 AA_ENV_FILE 覆盖。
# =============================================================================

set -Eeuo pipefail

SELFHOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SELFHOST_DIR}/../.." && pwd)"
COMPOSE_FILE="${SELFHOST_DIR}/docker-compose.selfhost.yml"
ENV_FILE="${AA_ENV_FILE:-${SELFHOST_DIR}/.env}"
BACKUP_DIR="${SELFHOST_DIR}/backups"

RESET=""; RED=""; GREEN=""; YELLOW=""; CYAN=""
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RESET=$'\033[0m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; CYAN=$'\033[36m'
fi

fail() { printf '%s错误：%s%s\n' "${RED}" "$*" "${RESET}" >&2; exit 1; }
info() { printf '%s[aa]%s %s\n' "${CYAN}" "${RESET}" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "${GREEN}" "${RESET}" "$*"; }
warn() { printf '%s[警告]%s %s\n' "${YELLOW}" "${RESET}" "$*" >&2; }

usage() {
  # 打印文件头那段注释，遇到结束的分隔线就停。不写死行号，避免加命令后错位。
  awk 'NR > 2 { if ($0 ~ /^# =+$/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

# -----------------------------------------------------------------------------
# 前置检查
# -----------------------------------------------------------------------------
require_env_file() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    fail "找不到环境文件 ${ENV_FILE}
     先执行：cp ${SELFHOST_DIR}/.env.example ${ENV_FILE}
     然后填入 POSTGRES_PASSWORD、AGENT_SERVER_SECRET、AGENT_SERVER_PUBLIC_ORIGIN、AGENTS_ANYWHERE_BIND_ADDR"
  fi
}

require_docker() {
  command -v docker >/dev/null 2>&1 || fail "没有找到 docker"
  docker compose version >/dev/null 2>&1 || fail "需要 Docker Compose v2"
  docker info >/dev/null 2>&1 || fail "Docker 守护进程没在运行"
}

# 读取 .env 中的单个值（不 source，避免执行里面的内容）。
env_get() {
  local key="$1" default="${2-}" line value
  [[ -f "${ENV_FILE}" ]] || { printf '%s' "${default}"; return 0; }
  line="$(grep -E "^[[:space:]]*${key}=" "${ENV_FILE}" | tail -n 1 || true)"
  [[ -n "${line}" ]] || { printf '%s' "${default}"; return 0; }
  value="${line#*=}"
  value="${value%$'\r'}"
  if [[ "${value}" == \"*\" || "${value}" == \'*\' ]]; then value="${value:1:${#value}-2}"; fi
  printf '%s' "${value}"
}

web_port() { local p; p="$(env_get AGENTS_ANYWHERE_WEB_PORT 5174)"; printf '%s' "${p:-5174}"; }

# 健康检查用的宿主地址：0.0.0.0 / :: 这种通配地址要换回 127.0.0.1。
local_host() {
  local h; h="$(env_get AGENTS_ANYWHERE_BIND_ADDR 127.0.0.1)"
  case "${h}" in ""|"0.0.0.0"|"::"|"[::]") h="127.0.0.1" ;; esac
  printf '%s' "${h}"
}

public_origin() { env_get AGENT_SERVER_PUBLIC_ORIGIN ""; }

dc() {
  docker compose --no-color --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@"
}

http_status() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -s -o /dev/null -w '%{http_code}' --max-time 8 "${url}" || printf '000'
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O /dev/null --timeout=8 "${url}" && printf '200' || printf '000'
  else
    printf 'n/a'
  fi
}

# -----------------------------------------------------------------------------
# 命令实现
# -----------------------------------------------------------------------------

# 生成随机十六进制串。优先 openssl，没有就退回 /dev/urandom。
rand_hex() {
  local bytes="$1"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "${bytes}"
  else
    head -c "${bytes}" /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

# 探测 N100 的 Tailscale 地址。tailscale 容器在跑就问它，否则试宿主机命令。
detect_bind_addr() {
  local ip=""
  if command -v docker >/dev/null 2>&1 && docker inspect tailscale >/dev/null 2>&1; then
    ip="$(docker exec tailscale tailscale ip -4 2>/dev/null | head -n 1 | tr -d '\r' || true)"
  fi
  if [[ -z "${ip}" ]] && command -v tailscale >/dev/null 2>&1; then
    ip="$(tailscale ip -4 2>/dev/null | head -n 1 | tr -d '\r' || true)"
  fi
  printf '%s' "${ip}"
}

cmd_init() {
  local domain="" bind="" force=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)    domain="${2:-}"; shift 2 ;;
      --bind-addr) bind="${2:-}";   shift 2 ;;
      --force)     force=true;      shift ;;
      *) fail "init 不认识的参数：$1（可用 --domain / --bind-addr / --force）" ;;
    esac
  done

  if [[ -f "${ENV_FILE}" && "${force}" != true ]]; then
    fail "${ENV_FILE} 已存在，没有覆盖。
     想重新生成：先备份现有文件再删掉它，或加 --force"
  fi
  [[ -f "${SELFHOST_DIR}/.env.example" ]] || fail "缺少 ${SELFHOST_DIR}/.env.example"

  # ---- 对外域名 ----
  if [[ -z "${domain}" ]]; then
    [[ -t 0 ]] || fail "非交互环境必须显式传 --domain，例如 --domain aa.example.com"
    read -r -p '  对外域名（例如 aa.example.com）: ' domain
  fi
  # 容错：允许用户直接粘 https://aa.example.com/ 这种形式
  domain="${domain#http://}"; domain="${domain#https://}"
  domain="${domain%%/*}"; domain="${domain%% }"
  [[ -n "${domain}" ]] || fail "域名不能为空"

  # ---- 绑定地址 ----
  local detected
  detected="$(detect_bind_addr)"
  if [[ -z "${bind}" ]]; then
    if [[ -n "${detected}" ]]; then
      if [[ -t 0 ]]; then
        read -r -p "  绑定地址 [${detected}]: " bind
      fi
      [[ -n "${bind}" ]] || bind="${detected}"
    else
      [[ -t 0 ]] || fail "非交互环境必须显式传 --bind-addr，例如 --bind-addr 100.108.208.20"
      read -r -p '  绑定地址（N100 的 Tailscale IP，例如 100.x.y.z）: ' bind
    fi
  fi
  [[ -n "${bind}" ]] || fail "绑定地址不能为空"

  # ---- 生成并写入 ----
  local pg secret tmp
  pg="$(rand_hex 24)"
  secret="$(rand_hex 32)"
  tmp="${ENV_FILE}.tmp"

  sed -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${pg}|" \
      -e "s|^AGENT_SERVER_SECRET=.*|AGENT_SERVER_SECRET=${secret}|" \
      -e "s|^AGENT_SERVER_PUBLIC_ORIGIN=.*|AGENT_SERVER_PUBLIC_ORIGIN=https://${domain}|" \
      -e "s|^AGENTS_ANYWHERE_BIND_ADDR=.*|AGENTS_ANYWHERE_BIND_ADDR=${bind}|" \
      "${SELFHOST_DIR}/.env.example" > "${tmp}"
  chmod 600 "${tmp}"

  # 四项都要确认真的替换进去了，半成品配置比没有配置更危险。
  grep -q "^POSTGRES_PASSWORD=${pg}$" "${tmp}"            || { rm -f "${tmp}"; fail "写入 POSTGRES_PASSWORD 失败"; }
  grep -q "^AGENT_SERVER_SECRET=${secret}$" "${tmp}"      || { rm -f "${tmp}"; fail "写入 AGENT_SERVER_SECRET 失败"; }
  grep -q "^AGENT_SERVER_PUBLIC_ORIGIN=https://${domain}$" "${tmp}" || { rm -f "${tmp}"; fail "写入 AGENT_SERVER_PUBLIC_ORIGIN 失败"; }
  grep -q "^AGENTS_ANYWHERE_BIND_ADDR=${bind}$" "${tmp}"  || { rm -f "${tmp}"; fail "写入 AGENTS_ANYWHERE_BIND_ADDR 失败"; }

  mv "${tmp}" "${ENV_FILE}"

  ok "已生成 ${ENV_FILE}（权限 600）"
  printf '\n'
  printf '  POSTGRES_PASSWORD            %s已随机生成，不显示%s\n' "${CYAN}" "${RESET}"
  printf '  AGENT_SERVER_SECRET          %s已随机生成，不显示%s\n' "${CYAN}" "${RESET}"
  printf '  AGENT_SERVER_PUBLIC_ORIGIN   https://%s\n' "${domain}"
  printf '  AGENTS_ANYWHERE_BIND_ADDR    %s\n' "${bind}"
  printf '\n'

  if [[ "${bind}" != 100.* ]]; then
    warn "绑定地址 ${bind} 看起来不是 Tailscale 网段（100.x）。"
    warn "如果这是有意为之（例如只给 127.0.0.1）可以忽略；否则阿里云的 Nginx 会连不上。"
  fi
  if [[ ! -f "${SELFHOST_DIR}/nginx/agents-anywhere.conf" ]]; then
    warn "缺少 nginx/agents-anywhere.conf"
  fi

  printf '  密钥都已落盘，建议现在备份一份 ${ENV_FILE} 到 N100 之外。\n'
  printf '  下一步：./aa.sh up\n\n'
}
cmd_build() {
  require_env_file; require_docker
  info "构建 server 镜像（首次构建 web-next 静态站点，可能需要 5-15 分钟）"
  dc build server-next
  ok "镜像构建完成：agents-anywhere-server:selfhost"
}

wait_ready() {
  local host port url waited=0 limit="${1:-240}"
  host="$(local_host)"; port="$(web_port)"
  url="http://${host}:${port}/api/v2/health"
  info "等待服务就绪：${url}（最多 ${limit}s）"
  while (( waited < limit )); do
    if [[ "$(http_status "${url}")" == "200" ]]; then
      ok "服务已就绪"
      return 0
    fi
    sleep 3; waited=$(( waited + 3 ))
  done
  warn "等待超时，最近 60 行 server-next 日志："
  dc logs --tail 60 server-next >&2 || true
  return 1
}

cmd_up() {
  require_env_file; require_docker
  cmd_build
  info "启动 postgres / redis / migrate / server"
  dc up -d
  # 首次启动要跑完迁移，低功耗机器上给足时间。
  wait_ready 420 || fail "服务未能就绪，请查看：./aa.sh logs"
  cmd_health
  local origin; origin="$(public_origin)"
  printf '\n'
  [[ -n "${origin}" ]] && printf '  对外地址： %s\n' "${origin}"
  printf '  本机地址： http://%s:%s\n' "$(local_host)" "$(web_port)"
  printf '  首次部署请执行： ./aa.sh bootstrap\n\n'
}

cmd_down() {
  require_env_file; require_docker
  info "停止容器（数据卷保留）"
  dc down
  ok "已停止"
}

cmd_restart() {
  require_env_file; require_docker
  dc restart server-next
  wait_ready 120 || true
}

cmd_ps() {
  require_env_file; require_docker
  dc ps
}

cmd_logs() {
  require_env_file; require_docker
  if [[ $# -eq 0 ]]; then set -- server-next; fi
  dc logs -f --tail 200 "$@"
}

cmd_health() {
  require_env_file
  local host port base code
  host="$(local_host)"; port="$(web_port)"
  base="http://${host}:${port}"
  printf '  健康检查   %-26s ' "${base}/api/v2/health"
  code="$(http_status "${base}/api/v2/health")"
  if [[ "${code}" == "200" ]]; then printf '%s%s%s\n' "${GREEN}" "${code}" "${RESET}"
  else printf '%s%s%s\n' "${RED}" "${code}" "${RESET}"; fi

  printf '  就绪检查   %-26s ' "${base}/api/v2/health/ready"
  code="$(http_status "${base}/api/v2/health/ready")"
  if [[ "${code}" == "200" ]]; then printf '%s%s%s\n' "${GREEN}" "${code}" "${RESET}"
  else printf '%s%s%s\n' "${RED}" "${code}" "${RESET}"; fi

  local origin; origin="$(public_origin)"
  if [[ -n "${origin}" ]]; then
    printf '  对外域名   %-26s ' "${origin}/api/v2/health"
    code="$(http_status "${origin}/api/v2/health")"
    if [[ "${code}" == "200" ]]; then printf '%s%s%s\n' "${GREEN}" "${code}" "${RESET}"
    else printf '%s%s%s\n' "${RED}" "${code}" "${RESET}"; fi
  fi
}

# 从 server-next 日志里抓当前的 setup token。
# 注意：token 只在「数据库里还没有用户」时打印；过期后服务会在下次
# /auth/config 调用时重新生成并再次打印，所以刷新一次登录页即可。
extract_setup_token() {
  dc logs --no-log-prefix server-next 2>&1 \
    | grep -oE 'setup-token:[[:space:]]*[A-Za-z0-9_-]+' \
    | tail -n 1 | awk '{print $2}' || true
}

cmd_bootstrap() {
  require_env_file; require_docker
  local create=false
  if [[ "${1:-}" == "--create" ]]; then create=true; fi

  local token origin
  token="$(extract_setup_token)"
  if [[ -z "${token}" ]]; then
    fail "日志里没有找到 setup token。
     可能原因：
       1) 首位管理员已经创建过了（此时不需要 token，直接登录即可）；
       2) token 所在的那段日志已经被轮转掉——刷新一次登录页让服务重新打印，
          再执行 ./aa.sh logs server-next | grep setup-token 确认；
       3) 服务还没起来：./aa.sh ps 看一眼。"
  fi
  origin="$(public_origin)"

  printf '\n  setup token： %s\n' "${token}"
  [[ -n "${origin}" ]] && printf '  设置入口：    %s\n' "${origin}"
  printf '  有效期：      默认 15 分钟，过期后刷新登录页会在日志里生成新的\n\n'

  if [[ "${create}" != true ]]; then
    printf '  想直接在这里建管理员就加 --create：./aa.sh bootstrap --create\n\n'
    return 0
  fi

  local email name password confirm
  read -r -p '  管理员邮箱: ' email
  read -r -p '  显示名称  : ' name
  [[ -n "${name}" ]] || name="${email%%@*}"
  while true; do
    read -r -s -p '  密码(≥12位): ' password; printf '\n'
    read -r -s -p '  再输一次   : ' confirm; printf '\n'
    [[ -n "${password}" ]] || { warn "密码不能为空"; continue; }
    [[ "${password}" == "${confirm}" ]] || { warn "两次输入不一致"; continue; }
    break
  done

  # 直接在容器内调用接口：容器自带 python3，不依赖宿主机的 curl/jq。
  local py
  read -r -d '' py <<'PY' || true
import json, os, urllib.request, urllib.error
payload = json.dumps({
    "email": os.environ["AA_EMAIL"],
    "displayName": os.environ["AA_DISPLAY_NAME"],
    "password": os.environ["AA_PASSWORD"],
    "setupToken": os.environ["AA_SETUP_TOKEN"],
}).encode("utf-8")
req = urllib.request.Request(
    "http://127.0.0.1:8000/api/v2/auth/register",
    data=payload,
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.loads(resp.read().decode("utf-8"))
except urllib.error.HTTPError as exc:
    raise SystemExit("创建失败：HTTP %s %s" % (exc.code, exc.read().decode("utf-8", "replace")))
except Exception as exc:
    raise SystemExit("创建失败：%s" % exc)
print("已创建管理员：%s（角色 %s）" % (body.get("email"), body.get("role")))
PY

  dc exec -T \
    -e "AA_EMAIL=${email}" \
    -e "AA_DISPLAY_NAME=${name}" \
    -e "AA_PASSWORD=${password}" \
    -e "AA_SETUP_TOKEN=${token}" \
    server-next python -c "${py}"
  ok "创建成功。首位管理员建立后，自助注册会自动关闭。"
  printf '  现在可以用 %s 登录了\n' "${email}"
}

cmd_migrate() {
  require_env_file; require_docker
  info "执行数据库迁移"
  dc run --rm migrate-next
  ok "迁移完成"
}

cmd_backup() {
  require_env_file; require_docker
  local stamp dir
  stamp="$(date +%Y%m%d-%H%M%S)"
  dir="${BACKUP_DIR}"
  mkdir -p "${dir}"

  info "导出 PostgreSQL → ${dir}/pg-${stamp}.sql.gz"
  # 先写临时文件再原子改名：pg_dump 中途失败时不会留下一个看着像正常的备份。
  dc exec -T postgres-next pg_dump -U agents_anywhere -d agents_anywhere \
    | gzip > "${dir}/pg-${stamp}.sql.gz.part"
  mv "${dir}/pg-${stamp}.sql.gz.part" "${dir}/pg-${stamp}.sql.gz"

  local vol
  vol="$(dc ps -q server-next | head -n 1 | xargs -r docker inspect \
    -f '{{ range .Mounts }}{{ if eq .Destination "/data" }}{{ .Name }}{{ end }}{{ end }}')"
  if [[ -n "${vol}" ]]; then
    info "打包附件卷 ${vol} → ${dir}/files-${stamp}.tgz"
    docker run --rm -v "${vol}":/data:ro -v "${dir}":/backup alpine:3.20 \
      tar czf "/backup/files-${stamp}.tgz" -C /data .
  else
    warn "没解析到 /data 卷名，跳过附件打包"
  fi

  ok "备份完成："
  ls -lh "${dir}" | tail -n 5
  printf '\n  把这两个文件复制到 N100 之外的地方再算数。\n\n'
}

cmd_shell()  { require_env_file; require_docker; dc exec server-next bash; }
cmd_psql()   { require_env_file; require_docker; dc exec postgres-next psql -U agents_anywhere -d agents_anywhere; }

cmd_version() {
  printf '  仓库提交： %s\n' "$(git -C "${ROOT_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  printf '  提交说明： %s\n' "$(git -C "${ROOT_DIR}" log -1 --pretty=%s 2>/dev/null || echo unknown)"
  if command -v docker >/dev/null 2>&1; then
    printf '  运行镜像： %s\n' \
      "$(docker inspect -f '{{ .Config.Image }}' "$(dc ps -q server-next 2>/dev/null | head -n1)" 2>/dev/null || echo '未运行')"
  fi
}

# -----------------------------------------------------------------------------
main() {
  local command="${1:-help}"
  shift || true
  case "${command}" in
    init)      cmd_init "$@" ;;
    up)        cmd_up "$@" ;;
    down)      cmd_down "$@" ;;
    restart)   cmd_restart "$@" ;;
    build)     cmd_build "$@" ;;
    ps|status) cmd_ps "$@" ;;
    logs)      cmd_logs "$@" ;;
    health)    cmd_health "$@" ;;
    bootstrap|token) cmd_bootstrap "$@" ;;
    migrate)   cmd_migrate "$@" ;;
    backup)    cmd_backup "$@" ;;
    shell)     cmd_shell "$@" ;;
    psql)      cmd_psql "$@" ;;
    version)   cmd_version "$@" ;;
    help|-h|--help) usage ;;
    *) fail "未知命令：${command}（执行 ./aa.sh help 查看用法）" ;;
  esac
}

main "$@"

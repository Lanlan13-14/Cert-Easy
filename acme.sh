#!/usr/bin/env bash
# cert-easy: 交互式 DNS-01/HTTP-01 证书申请/管理，支持域名和IP证书
# 功能：申请/安装、列出/查看/删除证书；凭据新增/删除（删除前提示依赖域名）；温和的自动续期策略；更新脚本；两级卸载
# 支持：CentOS, Debian, Ubuntu, Alpine, Arch Linux
set -Eeuo pipefail

# ===== 基础路径与默认值 =====
SCRIPT_URL="${CERT_EASY_REMOTE_URL:-https://raw.githubusercontent.com/Lanlan13-14/Cert-Easy/refs/heads/main/acme.sh}"

CRED_FILE="/root/.acme-cred"
ACME_HOME="${HOME}/.acme.sh"
ACME="${ACME_HOME}/acme.sh"
OUT_DIR_BASE_DEFAULT="/etc/ssl/acme"
KEYLEN_DEFAULT="ec-256"            # ec-256 | ec-384 | 2048 | 3072 | 4096
AUTO_RENEW_DEFAULT="1"             # 1=开启自动续期；0=关闭但保留 cron 任务
CRON_WRAPPER="/usr/local/bin/cert-easy-cron"
# IP证书相关配置
VALIDATION_WEBROOT_DEFAULT="/wwwroot/letsencrypt"
IP_CERT_DAYS_DEFAULT="6"           # IP证书默认有效期6天

# ===== 系统检测和依赖管理 =====
detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_NAME="$ID"
        OS_VERSION="$VERSION_ID"
    elif [[ -f /etc/centos-release ]]; then
        OS_NAME="centos"
        OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/centos-release | head -1)
    elif [[ -f /etc/debian_version ]]; then
        OS_NAME="debian"
        OS_VERSION=$(cat /etc/debian_version)
    elif [[ -f /etc/alpine-release ]]; then
        OS_NAME="alpine"
        OS_VERSION=$(cat /etc/alpine-release)
    elif [[ -f /etc/arch-release ]]; then
        OS_NAME="arch"
        OS_VERSION=""  # Arch 是滚动版本
    else
        err "无法检测操作系统类型"
    fi
}

install_dependencies() {
    local pkg_manager=""
    local curl_pkg="curl"
    local openssl_pkg="openssl"
    local cron_pkg=""
    
    case "$OS_NAME" in
        centos|rhel|fedora)
            if command -v dnf >/dev/null 2>&1; then
                pkg_manager="dnf -y"
            else
                pkg_manager="yum -y"
            fi
            cron_pkg="cronie"
            ;;
        debian|ubuntu)
            pkg_manager="apt-get -y"
            cron_pkg="cron"
            # 更新包列表
            $pkg_manager update >/dev/null 2>&1 || true
            ;;
        alpine)
            pkg_manager="apk add"
            curl_pkg="curl"
            openssl_pkg="openssl"
            cron_pkg="dcron"
            # Alpine 需要先更新索引
            $pkg_manager update >/dev/null 2>&1 || true
            ;;
        arch)
            pkg_manager="pacman -S --noconfirm --needed"
            curl_pkg="curl"
            openssl_pkg="openssl"
            cron_pkg="cronie"
            ;;
        *)
            err "不支持的操作系统: $OS_NAME"
            ;;
    esac

    # 安装依赖
    local to_install=()
    
    if ! command -v curl >/dev/null 2>&1; then
        to_install+=("$curl_pkg")
    fi
    
    if ! command -v openssl >/dev/null 2>&1; then
        to_install+=("$openssl_pkg")
    fi
    
    # 对于crontab，我们检查命令是否存在，如果不存在且知道包名则安装
    if ! command -v crontab >/dev/null 2>&1 && [[ -n "$cron_pkg" ]]; then
        to_install+=("$cron_pkg")
    fi
    
    if [[ ${#to_install[@]} -gt 0 ]]; then
        ok "安装依赖: ${to_install[*]}"
        if [[ "$OS_NAME" == "alpine" ]]; then
            $pkg_manager ${to_install[@]} >/dev/null 2>&1 || {
                warn "部分依赖安装失败，尝试继续运行..."
            }
        else
            $pkg_manager install ${to_install[@]} >/dev/null 2>&1 || {
                warn "部分依赖安装失败，尝试继续运行..."
            }
        fi
    fi
    
    # 再次检查关键依赖
    ensure_cmd curl
    ensure_cmd openssl
}

# ===== 样式 =====
ok()   { echo -e "\033[1;32m[✔]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
err()  { echo -e "\033[1;31m[✘]\033[0m $*"; exit 1; }
ask()  { echo -ne "\033[1;36m[?]\033[0m $*"; }
self_path(){ readlink -f "$0" 2>/dev/null || echo "$0"; }

ensure_cmd(){ command -v "$1" >/dev/null 2>&1 || err "缺少依赖: $1"; }

# ===== 配置文件处理 =====
touch_if_absent() {
  if [[ ! -f "$1" ]]; then
    umask 077
    touch "$1"
    chmod 600 "$1"
  fi
}

load_config() {
  touch_if_absent "$CRED_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$CRED_FILE"
  set +a
  EMAIL="${EMAIL:-}"
  OUT_DIR_BASE="${OUT_DIR_BASE:-$OUT_DIR_BASE_DEFAULT}"
  KEYLEN_DEFAULT="${KEYLEN_DEFAULT:-$KEYLEN_DEFAULT}"
  AUTO_RENEW="${AUTO_RENEW:-$AUTO_RENEW_DEFAULT}"
  VALIDATION_WEBROOT="${VALIDATION_WEBROOT:-$VALIDATION_WEBROOT_DEFAULT}"
  IP_CERT_DAYS="${IP_CERT_DAYS:-$IP_CERT_DAYS_DEFAULT}"
}
save_kv() {
  local k="$1" v="$2"
  touch_if_absent "$CRED_FILE"
  if grep -qE "^${k}=" "$CRED_FILE"; then
    sed -i -E "s|^${k}=.*|${k}=${v//|/\\|}|" "$CRED_FILE"
  else
    echo "${k}=${v}" >>"$CRED_FILE"
  fi
}

init_minimal() {
  detect_os
  install_dependencies
  
  load_config
  if [[ -z "${EMAIL}" ]]; then
    ask "📧 首次使用，输入 ACME 账号邮箱: "
    read -r EMAIL
    save_kv EMAIL "$EMAIL"
  fi
  save_kv OUT_DIR_BASE "$OUT_DIR_BASE"
  save_kv KEYLEN_DEFAULT "$KEYLEN_DEFAULT"
  save_kv AUTO_RENEW "$AUTO_RENEW"
  save_kv VALIDATION_WEBROOT "$VALIDATION_WEBROOT"
  save_kv IP_CERT_DAYS "$IP_CERT_DAYS"
}

# ===== acme.sh 安装 =====
ensure_acme() {
  if [[ ! -x "$ACME" ]]; then
    ok "安装 acme.sh ..."
    curl -fsSL https://get.acme.sh | sh -s email="${EMAIL}"
  fi
  [[ -x "$ACME" ]] || err "acme.sh 未安装成功"
}

# ===== cron（温和策略）=====
has_crontab() { command -v crontab >/dev/null 2>&1; }

ensure_cron_wrapper() {
  cat >"$CRON_WRAPPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
CRED_FILE="/root/.acme-cred"
ACME_HOME="$HOME/.acme.sh"
ACME="${ACME_HOME}/acme.sh"
AUTO_RENEW_DEFAULT="1"
if [[ -f "$CRED_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$CRED_FILE"
fi
AUTO_RENEW="${AUTO_RENEW:-$AUTO_RENEW_DEFAULT}"
if [[ "$AUTO_RENEW" = "1" ]]; then
  "$ACME" --cron --home "$ACME_HOME" >/dev/null 2>&1 || true
fi
exit 0
EOF
  chmod 755 "$CRON_WRAPPER"
}

ensure_cron_job() {
  has_crontab || { warn "未检测到 crontab，跳过计划任务安装"; return 0; }
  ensure_cron_wrapper
  local cr; cr="$(crontab -l 2>/dev/null || true)"
  local line="7 3 * * * $CRON_WRAPPER # cert-easy"
  if ! echo "$cr" | grep -qF "$CRON_WRAPPER"; then
    printf "%s\n%s\n" "$cr" "$line" | crontab -
    ok "已安装 cert-easy 续期计划任务"
  fi
  # 温和：不替换/不删除已有 acme.sh --cron 条目；若检测到则提示
  if echo "$cr" | grep -Eq 'acme\.sh.*--cron'; then
    warn "检测到现有 acme.sh 续期任务：AUTO_RENEW 开关不控制其行为（仅作用于 cert-easy-cron）"
  fi
}

cron_status() {
  load_config
  local has="未配置"
  if has_crontab && crontab -l 2>/dev/null | grep -qF "$CRON_WRAPPER"; then
    has="已配置"
  fi
  echo "AUTO_RENEW=${AUTO_RENEW} / 计划任务${has}"
}

toggle_auto_renew() {
  load_config
  if [[ "${AUTO_RENEW}" = "1" ]]; then
    ask "AUTO_RENEW=1，是否关闭自动续期但保留 cron 任务? (y/N): "
    read -r x
    [[ "$x" =~ ^[Yy]$ ]] && save_kv AUTO_RENEW "0" && ok "已关闭自动续期（保留 cron）"
  else
    ask "AUTO_RENEW=0，是否开启自动续期? (y/N): "
    read -r x
    [[ "$x" =~ ^[Yy]$ ]] && save_kv AUTO_RENEW "1" && ok "已开启自动续期"
  fi
  ensure_cron_job
}

# ===== 提供商相关 =====
show_providers_menu() {
  echo "请选择 DNS 提供商:"
  echo "[1] Cloudflare (cf)"
  echo "[2] DNSPod 中国站 (dnspod-cn)" 
  echo "[3] DNSPod 国际站 (dnspod-global)"
  echo "[4] 阿里云 中国站 (aliyun-cn)"
  echo "[5] 阿里云 国际站 (aliyun-global)"
  echo "[6] dynv6 (dynv6)"
  echo "[7] 火山引擎 Volcengine (volcengine)"
  echo "[8] 华为云 中国站 (huaweicloud-cn)"
  echo "[9] 百度云 (baidu)"
}

get_provider_by_choice() {
  local choice="$1"
  case "$choice" in
    1) echo "cf" ;;
    2) echo "dnspod-cn" ;;
    3) echo "dnspod-global" ;;
    4) echo "aliyun-cn" ;;
    5) echo "aliyun-global" ;;
    6) echo "dynv6" ;;
    7) echo "volcengine" ;;
    8) echo "huaweicloud-cn" ;;
    9) echo "baidu" ;;
    *) return 1 ;;
  esac
}

provider_to_dnsapi() {
  case "$1" in
    cf)                       echo "dns_cf" ;;
    dnspod-cn|dnspod-global)  echo "dns_dp" ;;
    aliyun-cn|aliyun-global)  echo "dns_ali" ;;
    dynv6)                    echo "dns_dynv6" ;;
    volcengine)               echo "dns_volcengine" ;;
    huaweicloud-cn)           echo "dns_huaweicloud" ;;
    baidu)                    echo "dns_baidu" ;;
    *) return 1 ;;
  esac
}

export_provider_env() {
  local p="$1"
  case "$p" in
    cf)
      if [[ -n "${CF_Token:-}" ]]; then export CF_Token; else
        if [[ -n "${CF_Key:-}" && -n "${CF_Email:-}" ]]; then export CF_Key CF_Email; else
          err "Cloudflare 凭据缺失。请在 [凭据管理] 中添加 CF_Token 或 CF_Key+CF_Email"
        fi
      fi
      ;;
    dnspod-cn)
      : "${DP_Id:?缺少 DP_Id}"; : "${DP_Key:?缺少 DP_Key}"
      export DP_Id DP_Key
      export DP_ENDPOINT="${DP_ENDPOINT:-https://dnsapi.cn}"
      ;;
    dnspod-global)
      : "${DP_Id:?缺少 DP_Id}"; : "${DP_Key:?缺少 DP_Key}"
      export DP_Id DP_Key
      export DP_ENDPOINT="${DP_ENDPOINT:-https://api.dnspod.com}"
      ;;
    aliyun-cn|aliyun-global)
      : "${Ali_Key:?缺少 Ali_Key}"; : "${Ali_Secret:?缺少 Ali_Secret}"
      export Ali_Key Ali_Secret
      ;;
    dynv6)
      : "${DYNV6_TOKEN:?缺少 DYNV6_TOKEN}"
      export DYNV6_TOKEN
      ;;
    volcengine)
      : "${VOLCENGINE_ACCESS_KEY:?缺少 VOLCENGINE_ACCESS_KEY}"
      : "${VOLCENGINE_SECRET_KEY:?缺少 VOLCENGINE_SECRET_KEY}"
      export VOLCENGINE_ACCESS_KEY VOLCENGINE_SECRET_KEY
      export VOLCENGINE_REGION="${VOLCENGINE_REGION:-cn-beijing}"
      ;;
    huaweicloud-cn)
      : "${HUAWEICLOUD_Username:?缺少 HUAWEICLOUD_Username}"
      : "${HUAWEICLOUD_Password:?缺少 HUAWEICLOUD_Password}"
      : "${HUAWEICLOUD_ProjectID:?缺少 HUAWEICLOUD_ProjectID}"
      export HUAWEICLOUD_Username HUAWEICLOUD_Password HUAWEICLOUD_ProjectID
      export HUAWEICLOUD_IdentityEndpoint="${HUAWEICLOUD_IdentityEndpoint:-https://iam.myhuaweicloud.com}"
      ;;
    baidu)
      : "${BAIDU_AK:?缺少 BAIDU_AK}"
      : "${BAIDU_SK:?缺少 BAIDU_SK}"
      export BAIDU_AK BAIDU_SK
      ;;
    *) err "未知 provider: $p" ;;
  esac
}

add_or_update_creds() {
  load_config
  show_providers_menu
  ask "选择提供商编号 (1-9): "
  read -r choice
  local p; p=$(get_provider_by_choice "$choice") || { warn "无效选择"; return 1; }
  
  case "$p" in
    cf)
      ask "优先推荐 CF_Token。输入 CF_Token (留空则改为 CF_Key/CF_Email): "
      read -r t
      if [[ -n "$t" ]]; then
        save_kv CF_Token "$t"
        sed -i -E '/^(CF_Key|CF_Email)=/d' "$CRED_FILE"
      else
        ask "输入 CF_Key (Global API Key): "; read -r k
        ask "输入 CF_Email: "; read -r m
        save_kv CF_Key "$k"; save_kv CF_Email "$m"
        sed -i -E '/^CF_Token=/d' "$CRED_FILE"
      fi
      ;;
    dnspod-cn)
      ask "输入 DP_Id: "; read -r id
      ask "输入 DP_Key: "; read -r key
      save_kv DP_Id "$id"; save_kv DP_Key "$key"; save_kv DP_ENDPOINT "https://dnsapi.cn"
      ;;
    dnspod-global)
      ask "输入 DP_Id: "; read -r id
      ask "输入 DP_Key: "; read -r key
      save_kv DP_Id "$id"; save_kv DP_Key "$key"; save_kv DP_ENDPOINT "https://api.dnspod.com"
      ;;
    aliyun-cn|aliyun-global)
      ask "输入 Ali_Key: "; read -r ak
      ask "输入 Ali_Secret: "; read -r sk
      save_kv Ali_Key "$ak"; save_kv Ali_Secret "$sk"
      ;;
    dynv6)
      ask "输入 DYNV6_TOKEN: "; read -r dv
      save_kv DYNV6_TOKEN "$dv"
      ;;
    volcengine)
      ask "输入 VOLCENGINE_ACCESS_KEY: "; read -r v1
      ask "输入 VOLCENGINE_SECRET_KEY: "; read -r v2
      ask "区域(默认 cn-beijing): "; read -r rg; rg=${rg:-cn-beijing}
      save_kv VOLCENGINE_ACCESS_KEY "$v1"; save_kv VOLCENGINE_SECRET_KEY "$v2"; save_kv VOLCENGINE_REGION "$rg"
      ;;
    huaweicloud-cn)
      ask "输入 HUAWEICLOUD_Username: "; read -r username
      ask "输入 HUAWEICLOUD_Password: "; read -r password
      ask "输入 HUAWEICLOUD_ProjectID: "; read -r projectid
      ask "输入 HUAWEICLOUD_IdentityEndpoint (默认 https://iam.myhuaweicloud.com): "; read -r endpoint
      endpoint="${endpoint:-https://iam.myhuaweicloud.com}"
      save_kv HUAWEICLOUD_Username "$username"
      save_kv HUAWEICLOUD_Password "$password"
      save_kv HUAWEICLOUD_ProjectID "$projectid"
      save_kv HUAWEICLOUD_IdentityEndpoint "$endpoint"
      ;;
    baidu)
      ask "输入 BAIDU_AK: "; read -r ak
      ask "输入 BAIDU_SK: "; read -r sk
      save_kv BAIDU_AK "$ak"; save_kv BAIDU_SK "$sk"
      ;;
    *) warn "无效选择"; return 1;;
  esac
  ok "凭据已写入 $CRED_FILE"
}

provider_env_keys() {
  case "$1" in
    cf) echo "CF_Token CF_Key CF_Email" ;;
    dnspod-cn|dnspod-global) echo "DP_Id DP_Key DP_ENDPOINT" ;;
    aliyun-cn|aliyun-global) echo "Ali_Key Ali_Secret" ;;
    dynv6) echo "DYNV6_TOKEN" ;;
    volcengine) echo "VOLCENGINE_ACCESS_KEY VOLCENGINE_SECRET_KEY VOLCENGINE_REGION" ;;
    huaweicloud-cn) echo "HUAWEICLOUD_Username HUAWEICLOUD_Password HUAWEICLOUD_ProjectID HUAWEICLOUD_IdentityEndpoint" ;;
    baidu) echo "BAIDU_AK BAIDU_SK" ;;
  esac
}

scan_provider_usage() {
  # 输出: "provider<TAB>domain"
  local conf
  find "$ACME_HOME" -type f -name "*.conf" 2>/dev/null | while read -r conf; do
    [[ "$(basename "$conf")" == "account.conf" ]] && continue
    local webroot domain
    webroot=$(grep -E "^Le_Webroot=" "$conf" | head -n1 | cut -d"'" -f2 || true)
    domain=$(grep -E "^Le_Domain=" "$conf" | head -n1 | cut -d"'" -f2 || true)
    case "$webroot" in
      dns_cf)          echo -e "cf\t${domain}" ;;
      dns_dp)          echo -e "dnspod\t${domain}" ;;
      dns_ali)         echo -e "aliyun\t${domain}" ;;
      dns_dynv6)       echo -e "dynv6\t${domain}" ;;
      dns_volcengine)  echo -e "volcengine\t${domain}" ;;
      dns_huaweicloud) echo -e "huaweicloud\t${domain}" ;;
      dns_baidu)       echo -e "baidu\t${domain}" ;;
    esac
  done
}

delete_provider_creds() {
  load_config
  show_providers_menu
  ask "选择要删除凭据的提供商编号 (1-9): "
  read -r choice
  local p; p=$(get_provider_by_choice "$choice") || { warn "无效选择"; return 1; }
  local label="$p" short="$p"
  case "$p" in
    dnspod-cn|dnspod-global) short="dnspod" ;;
    aliyun-cn|aliyun-global) short="aliyun" ;;
    huaweicloud-cn) short="huaweicloud" ;;
  esac
  local inuse=()
  while IFS=$'\t' read -r prov dom; do
    [[ "$prov" == "$short" ]] && inuse+=("$dom")
  done < <(scan_provider_usage)

  if ((${#inuse[@]})); then
    warn "以下域名使用 $label 的 DNS 验证，删除凭据后这些证书的续期将失败："
    for d in "${inuse[@]}"; do echo "  - $d"; done
  else
    ok "未发现使用 $label 的已签发证书"
  fi

  ask "仍要删除 $label 的凭据吗? (yes/NO): "
  read -r ans
  [[ "$ans" == "yes" ]] || { warn "已取消删除"; return 0; }

  if ((${#inuse[@]})); then
    ask "是否同时删除上述证书（并移出续期清单）? (y/N): "
    read -r rmcert
    if [[ "$rmcert" =~ ^[Yy]$ ]]; then
      ensure_acme
      for d in "${inuse[@]}"; do
        ok "删除证书: $d"
        "$ACME" --remove -d "$d" || warn "删除失败: $d"
      done
    else
      warn "保留证书，但续期将失败，除非稍后补回凭据。"
    fi
  fi

  local keys; keys=$(provider_env_keys "$p")
  for k in $keys; do
    sed -i -E "/^${k}=.*/d" "$CRED_FILE"
  done
  ok "已从 $CRED_FILE 删除 $label 的凭迹"
}

# ===== IP地址获取函数 =====
get_public_ipv4() {
  # 尝试多个IP检测服务
  local ip=""
  local services=(
    "https://api.ipify.org"
    "https://ifconfig.me"
    "https://icanhazip.com"
    "https://checkip.amazonaws.com"
  )
  
  for service in "${services[@]}"; do
    if ip=$(curl -4 -s --connect-timeout 5 "$service" 2>/dev/null); then
      # 验证IP地址格式
      if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "$ip"
        return 0
      fi
    fi
  done
  
  return 1
}

get_public_ipv6() {
  local ip=""
  local services=(
    "https://api64.ipify.org"
    "https://icanhazip.com"
  )
  
  for service in "${services[@]}"; do
    if ip=$(curl -6 -s --connect-timeout 5 "$service" 2>/dev/null); then
      # 简单验证IPv6格式
      if [[ "$ip" =~ : ]]; then
        echo "$ip"
        return 0
      fi
    fi
  done
  
  return 1
}

# ===== Web服务器配置辅助函数 =====
detect_web_server_user() {
  # 尝试检测Web服务器用户
  local user=""
  
  # 检查Nginx用户
  if command -v nginx >/dev/null 2>&1; then
    if nginx -T 2>/dev/null | grep -q "user "; then
      user=$(nginx -T 2>/dev/null | grep "user " | head -1 | awk '{print $2}' | tr -d ';')
    fi
  fi
  
  # 如果没找到，尝试常见用户
  if [[ -z "$user" ]]; then
    for test_user in www-data nginx apache http; do
      if id "$test_user" &>/dev/null; then
        user="$test_user"
        break
      fi
    done
  fi
  
  echo "${user:-www-data}"
}

create_webroot_directory() {
  local webroot="$1"
  
  # 创建目录结构
  mkdir -p "${webroot}/.well-known/acme-challenge"
  mkdir -p "${webroot}/.well-known/pki-validation"
  
  # 获取Web服务器用户
  local web_user
  web_user=$(detect_web_server_user)
  
  # 设置权限
  chmod -R 755 "$webroot"
  if chown -R "${web_user}:${web_user}" "$webroot" 2>/dev/null; then
    ok "已创建验证目录并设置所有权给 ${web_user} 用户: ${webroot}"
  else
    warn "无法更改目录所有权，请手动检查 ${webroot} 的权限"
  fi
}

configure_nginx_automatically() {
  local webroot="$1"
  local nginx_config="/etc/nginx/sites-available/default"
  
  # 检查是否有其他Nginx配置文件
  if [[ ! -f "$nginx_config" ]]; then
    nginx_config="/etc/nginx/nginx.conf"
  fi
  
  ask "Nginx 配置文件路径 [默认: ${nginx_config}]: "
  read -r custom_config
  nginx_config="${custom_config:-$nginx_config}"
  
  # 备份原配置文件
  if [[ -f "$nginx_config" ]]; then
    cp "$nginx_config" "${nginx_config}.bak-$(date +%Y%m%d%H%M%S)"
    ok "已备份原配置文件到 ${nginx_config}.bak"
  fi
  
  # 创建配置文件
  cat > "$nginx_config" <<EOF
server {
    listen 80 default_server;
    server_name _;

    location /.well-known/acme-challenge/ {
        root ${webroot};
        add_header Content-Type text/plain;
    }

    location /.well-known/pki-validation/ {
        root ${webroot};
        add_header Content-Type text/plain;
    }

    # 其他请求返回 404（可选，防止暴露其他内容）
    location / {
        return 404;
    }
}
EOF
  
  ok "已写入 Nginx 配置文件: ${nginx_config}"
  
  # 测试配置
  if nginx -t; then
    ok "Nginx 配置测试成功"
    ask "是否重载 Nginx 配置? (y/N): "
    read -r reload
    if [[ "$reload" =~ ^[Yy]$ ]]; then
      systemctl reload nginx || service nginx reload || /etc/init.d/nginx reload
      ok "Nginx 配置已重载"
    fi
  else
    warn "Nginx 配置测试失败，请手动检查配置文件"
  fi
}

configure_caddy_automatically() {
  local webroot="$1"
  local caddy_config="/etc/caddy/Caddyfile"
  
  ask "Caddy 配置文件路径 [默认: ${caddy_config}]: "
  read -r custom_config
  caddy_config="${custom_config:-$caddy_config}"
  
  # 备份原配置文件
  if [[ -f "$caddy_config" ]]; then
    cp "$caddy_config" "${caddy_config}.bak-$(date +%Y%m%d%H%M%S)"
    ok "已备份原配置文件到 ${caddy_config}.bak"
  fi
  
  # 创建配置文件
  cat > "$caddy_config" <<EOF
:80 {
    handle_path /.well-known/acme-challenge/* {
        root * ${webroot}
        file_server
        header Content-Type text/plain
    }

    handle_path /.well-known/pki-validation/* {
        root * ${webroot}
        file_server
        header Content-Type text/plain
    }

    handle {
        respond 404
    }
}
EOF
  
  ok "已写入 Caddy 配置文件: ${caddy_config}"
  
  # 测试配置
  if command -v caddy >/dev/null 2>&1; then
    if caddy validate --config "$caddy_config"; then
      ok "Caddy 配置验证成功"
      ask "是否重载 Caddy 配置? (y/N): "
      read -r reload
      if [[ "$reload" =~ ^[Yy]$ ]]; then
        systemctl reload caddy || service caddy reload || /etc/init.d/caddy reload
        ok "Caddy 配置已重载"
      fi
    else
      warn "Caddy 配置验证失败，请手动检查配置文件"
    fi
  else
    warn "未找到 caddy 命令，跳过配置验证"
  fi
}

show_web_server_manual_config() {
  local webroot="$1"
  
  echo "=========================================="
  echo "📋 请手动配置您的 Web 服务器以支持 HTTP-01 验证"
  echo "=========================================="
  echo
  echo "验证文件根目录: $webroot"
  echo
  echo "📝 Nginx 配置示例:"
  cat <<NGINX_EXAMPLE
server {
    listen 80 default_server;
    server_name _;

    location /.well-known/acme-challenge/ {
        root ${webroot};
        add_header Content-Type text/plain;
    }

    location /.well-known/pki-validation/ {
        root ${webroot};
        add_header Content-Type text/plain;
    }

    # 其他请求返回 404（可选，防止暴露其他内容）
    location / {
        return 404;
    }
}
NGINX_EXAMPLE
  
  echo
  echo "📝 Caddy 配置示例:"
  cat <<CADDY_EXAMPLE
:80 {
    handle_path /.well-known/acme-challenge/* {
        root * ${webroot}
        file_server
        header Content-Type text/plain
    }

    handle_path /.well-known/pki-validation/* {
        root * ${webroot}
        file_server
        header Content-Type text/plain
    }

    handle {
        respond 404
    }
}
CADDY_EXAMPLE
  
  echo
  echo "💡 配置完成后，请测试并重载 Web 服务器"
  echo "=========================================="
}

check_webroot_accessibility() {
  local webroot="$1"
  local ip_address="$2"
  local test_file="${webroot}/.well-known/acme-challenge/test"
  
  # 创建测试文件
  mkdir -p "$(dirname "$test_file")"
  echo "test-content-$(date +%s)" > "$test_file"
  chmod 644 "$test_file"
  
  # 尝试访问（使用 curl）
  if curl -s -f --connect-timeout 10 "http://${ip_address}/.well-known/acme-challenge/test" 2>/dev/null | grep -q "test-content"; then
    rm -f "$test_file"
    return 0
  fi
  
  # 清理
  rm -f "$test_file"
  return 1
}

# ===== 证书申请/安装 =====
prompt_domain_cert_params() {
  show_providers_menu
  ask "选择 DNS 提供商编号 (1-9): "
  read -r choice
  local p; p=$(get_provider_by_choice "$choice") || { warn "无效选择"; return 1; }
  PROVIDER="$p"
  
  ask "📛 主域名 (如 example.com): "
  read -r DOMAIN
  echo "提示：通配符 *.${DOMAIN} 可覆盖 www/api 等所有一级子域，需 DNS-01 验证。"
  ask "✨ 是否添加通配符 *.${DOMAIN}? (y/N): "
  read -r WILD
  ask "➕ 额外域名(逗号分隔，可空): "
  read -r ALT
  ask "🔑 密钥长度 [默认 ${KEYLEN_DEFAULT}]: "
  read -r KEYLEN; KEYLEN=${KEYLEN:-$KEYLEN_DEFAULT}
  ask "🧪 使用测试环境(避免频率限制)? (y/N): "
  read -r STG
}

prompt_ip_cert_params() {
  load_config
  
  # 自动获取公网IP
  echo "🌐 正在检测公网IP地址..."
  
  local ipv4=""
  local ipv6=""
  local selected_ip=""
  
  if ipv4=$(get_public_ipv4); then
    echo "✅ 检测到 IPv4: $ipv4"
  else
    warn "无法自动获取 IPv4 地址"
  fi
  
  if ipv6=$(get_public_ipv6); then
    echo "✅ 检测到 IPv6: $ipv6"
  else
    warn "无法自动获取 IPv6 地址"
  fi
  
  if [[ -n "$ipv4" ]] || [[ -n "$ipv6" ]]; then
    echo
    echo "请选择IP地址或手动输入:"
    if [[ -n "$ipv4" ]]; then
      echo "[1] 使用检测到的 IPv4: $ipv4"
    fi
    if [[ -n "$ipv6" ]]; then
      echo "[2] 使用检测到的 IPv6: $ipv6"
    fi
    echo "[3] 手动输入IP地址"
    
    ask "选择 (1-3): "
    read -r ip_choice
    
    case "$ip_choice" in
      1)
        if [[ -n "$ipv4" ]]; then
          selected_ip="$ipv4"
        else
          warn "IPv4 不可用"
          ask "手动输入 IPv4 地址: "
          read -r selected_ip
        fi
        ;;
      2)
        if [[ -n "$ipv6" ]]; then
          selected_ip="$ipv6"
        else
          warn "IPv6 不可用"
          ask "手动输入 IPv6 地址: "
          read -r selected_ip
        fi
        ;;
      3)
        ask "手动输入 IP 地址: "
        read -r selected_ip
        ;;
      *)
        warn "无效选择"
        ask "手动输入 IP 地址: "
        read -r selected_ip
        ;;
    esac
  else
    ask "🌐 输入 IP 地址: "
    read -r selected_ip
  fi
  
  # 验证IP地址格式
  if [[ ! "$selected_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && [[ ! "$selected_ip" =~ : ]]; then
    err "无效的IP地址格式"
  fi
  
  PUBLIC_IP="$selected_ip"
  DOMAIN="$selected_ip"  # 使用IP作为域名
  
  ask "📁 验证文件根目录 [默认 ${VALIDATION_WEBROOT}]: "
  read -r webroot_input
  VALIDATION_WEBROOT="${webroot_input:-$VALIDATION_WEBROOT}"
  
  ask "🔑 密钥长度 [默认 ${KEYLEN_DEFAULT}]: "
  read -r KEYLEN; KEYLEN=${KEYLEN:-$KEYLEN_DEFAULT}
  
  ask "🧪 使用测试环境(避免频率限制)? (y/N): "
  read -r STG
  
  # IP证书默认有效期6天
  ask "📅 证书有效期 [默认 ${IP_CERT_DAYS} 天]: "
  read -r cert_days; cert_days=${cert_days:-$IP_CERT_DAYS}
  
  # 自动创建验证目录
  ok "正在创建验证目录..."
  create_webroot_directory "$VALIDATION_WEBROOT"
  
  # Web服务器配置选项
  echo
  echo "🌐 Web 服务器配置选项:"
  echo "[1] 自动配置 Nginx"
  echo "[2] 自动配置 Caddy"
  echo "[3] 显示配置示例（手动配置）"
  echo "[4] 已配置好，跳过"
  
  ask "选择 (1-4): "
  read -r config_choice
  
  case "$config_choice" in
    1)
      configure_nginx_automatically "$VALIDATION_WEBROOT"
      ;;
    2)
      configure_caddy_automatically "$VALIDATION_WEBROOT"
      ;;
    3)
      show_web_server_manual_config "$VALIDATION_WEBROOT"
      ask "按回车键继续..."
      read -r
      ;;
    4)
      ok "跳过Web服务器配置"
      ;;
    *)
      warn "无效选择，显示配置示例"
      show_web_server_manual_config "$VALIDATION_WEBROOT"
      ask "按回车键继续..."
      read -r
      ;;
  esac
  
  # 检查验证目录可访问性
  ask "是否测试验证目录可访问性? (y/N): "
  read -r test_access
  if [[ "$test_access" =~ ^[Yy]$ ]]; then
    ok "正在测试验证目录可访问性..."
    if check_webroot_accessibility "$VALIDATION_WEBROOT" "$PUBLIC_IP"; then
      ok "验证目录可正常访问"
    else
      warn "无法访问验证目录，请检查以下事项："
      echo "  1. Web 服务器是否正在运行"
      echo "  2. 防火墙是否开放了 80 端口"
      echo "  3. Web 服务器配置是否正确"
      ask "是否继续? (y/N): "
      read -r continue_anyway
      [[ "$continue_anyway" =~ ^[Yy]$ ]] || return 1
    fi
  fi
  
  # 保存验证目录设置
  save_kv VALIDATION_WEBROOT "$VALIDATION_WEBROOT"
}

issue_domain_cert_flow() {
  load_config
  prompt_domain_cert_params || return 1

  ensure_acme
  export_provider_env "$PROVIDER"
  local DNS_API; DNS_API=$(provider_to_dnsapi "$PROVIDER") || err "provider 无效"

  local dom_args=(-d "$DOMAIN")
  [[ "$WILD" =~ ^[Yy]$ ]] && dom_args+=(-d "*.${DOMAIN}")
  if [[ -n "$ALT" ]]; then
    IFS=',' read -r -a arr <<< "$ALT"
    for a in "${arr[@]}"; do
      a="$(echo "$a" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -n "$a" ]] && dom_args+=(-d "$a")
    done
  fi

  local server="letsencrypt"
  [[ "$STG" =~ ^[Yy]$ ]] && server="letsencrypt_test"

  ok "开始签发: $DOMAIN  [${DNS_API}]  key=${KEYLEN}  server=${server}"
  "$ACME" --set-default-ca --server "$server" >/dev/null

  "$ACME" --issue --dns "$DNS_API" "${dom_args[@]}" --keylength "$KEYLEN"

  local OUT_DIR="${OUT_DIR_BASE}/${DOMAIN}"
  mkdir -p "$OUT_DIR"; chmod 700 "$OUT_DIR"; umask 077

  local install_cmd=( "$ACME" --install-cert -d "$DOMAIN"
    --key-file       "$OUT_DIR/privkey.key"
    --fullchain-file "$OUT_DIR/fullchain.pem"
    --cert-file      "$OUT_DIR/cert.pem"
    --ca-file        "$OUT_DIR/chain.pem"
  )
  if [[ -n "${RELOAD_CMD:-}" ]]; then
    install_cmd+=( --reloadcmd "$RELOAD_CMD" )
  fi
  "${install_cmd[@]}"

  chmod 600 "$OUT_DIR/privkey.key"
  chmod 644 "$OUT_DIR/"*.pem

  ok "签发完成。证书与密钥路径："
  echo "  - 私钥:        $OUT_DIR/privkey.key"
  echo "  - 证书:        $OUT_DIR/cert.pem"
  echo "  - 链证书:      $OUT_DIR/chain.pem"
  echo "  - 全链:        $OUT_DIR/fullchain.pem"
  ensure_cron_job
}

issue_ip_cert_flow() {
  load_config
  prompt_ip_cert_params || return 1

  ensure_acme

  local server="letsencrypt"
  [[ "$STG" =~ ^[Yy]$ ]] && server="letsencrypt_test"

  ok "开始签发 IP 证书: $PUBLIC_IP  key=${KEYLEN}  server=${server}  days=${cert_days}"
  "$ACME" --set-default-ca --server "$server" >/dev/null

  # 签发IP证书（使用短有效期配置）
  "$ACME" --issue --server "$server" \
    -d "$PUBLIC_IP" \
    -w "$VALIDATION_WEBROOT" \
    --keylength "$KEYLEN" \
    --certificate-profile shortlived \
    --days "${cert_days}"

  local OUT_DIR="${OUT_DIR_BASE}/${PUBLIC_IP}"
  mkdir -p "$OUT_DIR"; chmod 700 "$OUT_DIR"; umask 077

  local install_cmd=( "$ACME" --install-cert -d "$PUBLIC_IP"
    --key-file       "$OUT_DIR/privkey.key"
    --fullchain-file "$OUT_DIR/fullchain.pem"
    --cert-file      "$OUT_DIR/cert.pem"
    --ca-file        "$OUT_DIR/chain.pem"
  )
  if [[ -n "${RELOAD_CMD:-}" ]]; then
    install_cmd+=( --reloadcmd "$RELOAD_CMD" )
  fi
  "${install_cmd[@]}"

  chmod 600 "$OUT_DIR/privkey.key"
  chmod 644 "$OUT_DIR/"*.pem

  ok "IP 证书签发完成。证书与密钥路径："
  echo "  - 私钥:        $OUT_DIR/privkey.key"
  echo "  - 证书:        $OUT_DIR/cert.pem"
  echo "  - 链证书:      $OUT_DIR/chain.pem"
  echo "  - 全链:        $OUT_DIR/fullchain.pem"
  echo ""
  warn "注意：IP 证书有效期为 ${cert_days} 天，请确保自动续期配置正确"
  ensure_cron_job
}

issue_flow() {
  echo "请选择证书类型:"
  echo "[1] 域名证书 (使用 DNS-01 验证)"
  echo "[2] IP 证书 (使用 HTTP-01 验证)"
  ask "选择类型 (1/2): "
  read -r cert_type_choice
  
  case "$cert_type_choice" in
    1)
      issue_domain_cert_flow
      ;;
    2)
      issue_ip_cert_flow
      ;;
    *)
      warn "无效选择"
      return 1
      ;;
  esac
}

# ===== 证书管理 =====
list_certs() {
  ensure_acme
  "$ACME" --list
}

show_cert_path() {
  load_config
  ask "输入域名或IP地址以显示证书路径: "
  read -r d
  local p="${OUT_DIR_BASE}/${d}"
  if [[ -d "$p" ]]; then
    ok "证书路径：$p"
    ls -l "$p"
  else
    err "未找到路径：$p"
  fi
}

delete_cert() {
  ensure_acme
  ask "输入要删除的域名或IP地址: "
  read -r d
  ask "是否先吊销该证书（可选）? (y/N): "
  read -r rv
  if [[ "$rv" =~ ^[Yy]$ ]]; then
    "$ACME" --revoke -d "$d" || warn "吊销失败或已吊销: $d"
  fi
  "$ACME" --remove -d "$d" && ok "已删除证书管理项并移出续期清单：$d"

  load_config
  local p="${OUT_DIR_BASE}/${d}"
  if [[ -d "$p" ]]; then
    ask "删除本地证书文件目录 $p ? (y/N): "
    read -r delp
    [[ "$delp" =~ ^[Yy]$ ]] && rm -rf -- "$p" && ok "已删除 $p"
  fi
}

# ===== 设置 =====
set_reload_cmd() {
  load_config
  ask "输入安装/续期后执行的重载命令（如 systemctl reload nginx，留空清除）: "
  read -r rc
  save_kv RELOAD_CMD "$rc"
  if [[ -n "$rc" ]]; then ok "已设置重载命令：$rc"; else ok "已清空重载命令"; fi
}
set_keylen_default() {
  load_config
  ask "设置默认密钥长度 (ec-256/ec-384/2048/3072/4096): "
  read -r k
  save_kv KEYLEN_DEFAULT "$k"
  ok "默认密钥长度已设为 $k"
}
set_outdir_base() {
  load_config
  ask "设置证书根目录 [当前 ${OUT_DIR_BASE}]: "
  read -r o
  [[ -n "$o" ]] && save_kv OUT_DIR_BASE "$o" && ok "证书根目录设为 $o"
}
set_validation_webroot() {
  load_config
  ask "设置 HTTP-01 验证文件根目录 [当前 ${VALIDATION_WEBROOT}]: "
  read -r w
  [[ -n "$w" ]] && save_kv VALIDATION_WEBROOT "$w" && ok "验证文件根目录设为 $w"
}
set_ip_cert_days() {
  load_config
  ask "设置 IP 证书默认有效期（天数） [当前 ${IP_CERT_DAYS}]: "
  read -r days
  [[ -n "$days" ]] && save_kv IP_CERT_DAYS "$days" && ok "IP证书默认有效期设为 ${days} 天"
}

# ===== 更新与卸载 =====
update_self() {
  ask "确认从远程更新脚本并立即重启？(y/N): "
  read -r ans
  [[ "$ans" =~ ^[Yy]$ ]] || { warn "已取消更新"; return; }

  # 创建备份
  local self_path
  self_path="$(readlink -f "$0" 2>/dev/null || echo "$0")"
  local backup_path="${self_path}.bak"
  cp "$self_path" "$backup_path"
  ok "已创建备份: $backup_path"

  local tmp
  tmp="$(mktemp)"
  if curl -fsSL "$SCRIPT_URL" -o "$tmp"; then
    # 检查下载的脚本是否有效
    if bash -n "$tmp" 2>/dev/null; then
      chmod --reference="$self_path" "$tmp" 2>/dev/null || chmod 755 "$tmp"
      mv "$tmp" "$self_path"
      ok "脚本已更新"

      # 询问是否重新加载脚本
      ask "是否立即重新加载脚本？(y/N): "
      read -r reload_choice
      if [[ "$reload_choice" =~ ^[Yy]$ ]]; then
        echo "🔄 重新加载脚本..."
        rm -f "$backup_path"   # ✅ 立即删除备份
        exec "$self_path"
      else
        echo "ℹ️  下次使用请输入: sudo cert-easy"
        rm -f "$backup_path"   # ✅ 不重启也会删除备份
        ok "已删除备份: $backup_path"
      fi
    else
      echo "❌ 下载的脚本语法有误，恢复备份..."
      mv "$backup_path" "$self_path"
      rm -f "$tmp"
      err "已恢复备份脚本"
    fi
  else
    echo "❌ 更新失败，恢复备份..."
    mv "$backup_path" "$self_path"
    rm -f "$tmp"
    err "已恢复备份脚本，请检查网络或链接是否有效"
  fi
}

purge_cron() {
  command -v crontab >/dev/null 2>&1 || return
  local cr; cr="$(crontab -l 2>/dev/null || true)"
  [[ -z "$cr" ]] && return
  cr="$(printf "%s\n" "$cr" | sed -E '/cert-easy-cron/d;/acme\.sh.*--cron/d')"
  printf "%s\n" "$cr" | crontab -
}

uninstall_menu() {
  echo "a) 仅删除本脚本（保留 acme.sh、证书、凭据、cron）"
  echo "b) 完全卸载（删除 acme.sh、证书、凭据、cron 与本脚本）"
  ask "选择: "
  read -r s
  case "$s" in
    a|A)
      rm -f -- "$(self_path)"
      ok "已删除本脚本"
      ;;
    b|B)
      ask "危险操作，确认完全卸载? (yes/NO): "
      read -r y
      [[ "$y" == "yes" ]] || { warn "已取消"; return; }
      purge_cron
      rm -f -- "$CRON_WRAPPER"
      rm -rf -- "$OUT_DIR_BASE_DEFAULT" "$CRED_FILE" "$ACME_HOME"
      rm -f -- "$(self_path)"
      ok "已完成完全卸载"
      ;;
    *) warn "无效选择" ;;
  esac
}

# ===== 主菜单 =====
main_menu() {
  while true; do
    echo
    echo "======== cert-easy ========"
    echo "[1] 申请/续期证书 (支持域名和IP)"
    echo "[2] 列出已管理证书"
    echo "[3] 显示某域名/IP证书路径"
    echo "[4] 删除证书（可选吊销并移出续期清单）"
    echo "[5] 自动续期开关 / 状态：$(cron_status)"
    echo "[6] 凭据管理：新增/更新"
    echo "[7] 凭据管理：删除（删除前列出依赖域名）"
    echo "[8] 设置"
    echo "[9] 更新脚本（从远程拉取并重启）"
    echo "[10] 卸载（一级/二级）"
    echo "[0] 退出"
    ask "请选择操作: "
    read -r op
    case "$op" in
      1) issue_flow ;;
      2) list_certs ;;
      3) show_cert_path ;;
      4) delete_cert ;;
      5) toggle_auto_renew ;;
      6) add_or_update_creds ;;
      7) delete_provider_creds ;;
      8) 
         echo "  [1] 设置重载命令"
         echo "  [2] 设置默认密钥长度"
         echo "  [3] 设置证书根目录"
         echo "  [4] 设置HTTP-01验证目录"
         echo "  [5] 设置IP证书默认有效期"
         echo "  [0] 返回上级"
         ask "选择: "
         read -r s
         case "$s" in
           1) set_reload_cmd ;;
           2) set_keylen_default ;;
           3) set_outdir_base ;;
           4) set_validation_webroot ;;
           5) set_ip_cert_days ;;
           0) ;;
           *) warn "无效选择" ;;
         esac 
         ;;
      9) update_self ;;
      10) uninstall_menu ;;
      0) echo -e "\033[1;32m[✔]\033[0m 已退出。下次使用请输入: sudo cert-easy"; exit 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

# ===== 启动 =====
init_minimal
ensure_acme
ensure_cron_job
main_menu
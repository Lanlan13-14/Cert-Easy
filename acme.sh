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
# 自签证书默认值
SELF_SIGN_DAYS_DEFAULT="365"       # 自签证书默认有效期1年
SELF_SIGN_KEYLEN_DEFAULT="2048"    # 自签证书默认密钥长度

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
  SELF_SIGN_DAYS="${SELF_SIGN_DAYS:-$SELF_SIGN_DAYS_DEFAULT}"
  SELF_SIGN_KEYLEN="${SELF_SIGN_KEYLEN:-$SELF_SIGN_KEYLEN_DEFAULT}"
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
  save_kv SELF_SIGN_DAYS "$SELF_SIGN_DAYS"
  save_kv SELF_SIGN_KEYLEN "$SELF_SIGN_KEYLEN"
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
  local nginx_conf_file=""
  
  # 检测Nginx配置目录
  if [[ -d "/etc/nginx/conf.d" ]]; then
    nginx_conf_file="/etc/nginx/conf.d/acme-challenge.conf"
  elif [[ -d "/etc/nginx/sites-enabled" ]]; then
    nginx_conf_file="/etc/nginx/sites-enabled/acme-challenge"
  else
    nginx_conf_file="/etc/nginx/acme-challenge.conf"
  fi

  ask "Nginx 验证配置文件路径 [默认: ${nginx_conf_file}]: "
  read -r custom_config
  nginx_conf_file="${custom_config:-$nginx_conf_file}"

  # 创建配置目录（如果不存在）
  mkdir -p "$(dirname "$nginx_conf_file")"

  # 备份已存在的配置文件
  if [[ -f "$nginx_conf_file" ]]; then
    cp "$nginx_conf_file" "${nginx_conf_file}.bak-$(date +%Y%m%d%H%M%S)"
    ok "已备份原配置文件到 ${nginx_conf_file}.bak"
  fi

  # 写入新的验证配置（单独配置文件，不覆盖主配置）
  cat > "$nginx_conf_file" <<EOF
# ACME HTTP-01 验证配置
# 由 cert-easy 自动生成 - $(date '+%Y-%m-%d %H:%M:%S')

server {
    listen 80;
    listen [::]:80;
    server_name _;

    # 仅处理ACME验证路径
    location /.well-known/acme-challenge/ {
        root ${webroot};
        add_header Content-Type text/plain;
    }

    location /.well-known/pki-validation/ {
        root ${webroot};
        add_header Content-Type text/plain;
    }
}
EOF

  ok "已写入 Nginx 验证配置文件: ${nginx_conf_file}"
  
  # 提示用户需要确保主配置包含此文件
  if [[ "$nginx_conf_file" == "/etc/nginx/conf.d/acme-challenge.conf" ]]; then
    ok "配置文件已放置在 conf.d 目录，Nginx 会自动加载"
  else
    warn "请确保主配置文件中包含此文件:"
    echo "  include ${nginx_conf_file};"
  fi

  # 测试配置
  if nginx -t; then
    ok "Nginx 配置测试成功"
    ask "是否重载 Nginx 配置? (y/N): "
    read -r reload
    if [[ "$reload" =~ ^[Yy]$ ]]; then
      systemctl reload nginx 2>/dev/null || 
      service nginx reload 2>/dev/null || 
      /etc/init.d/nginx reload 2>/dev/null && 
      ok "Nginx 配置已重载" || warn "Nginx 重载失败，请手动重载"
    fi
  else
    warn "Nginx 配置测试失败，请手动检查配置文件"
    nginx -t
  fi
}

configure_caddy_automatically() {
  local webroot="$1"
  local caddy_conf_file=""
  local caddy_main_config=""
  
  # 检测Caddy主配置文件
  if [[ -f "/etc/caddy/Caddyfile" ]]; then
    caddy_main_config="/etc/caddy/Caddyfile"
  elif [[ -f "/etc/caddy/Caddyfile.json" ]]; then
    caddy_main_config="/etc/caddy/Caddyfile.json"
  elif [[ -f "/etc/caddy/config.json" ]]; then
    caddy_main_config="/etc/caddy/config.json"
  fi
  
  # 检测Caddy配置目录
  if [[ -d "/etc/caddy/conf.d" ]]; then
    caddy_conf_file="/etc/caddy/conf.d/acme-challenge.caddy"
  elif [[ -d "/etc/caddy" ]]; then
    caddy_conf_file="/etc/caddy/acme-challenge.caddy"
  else
    caddy_conf_file="/etc/caddy/acme-challenge.caddy"
    mkdir -p "/etc/caddy"
  fi

  ask "Caddy 验证配置文件路径 [默认: ${caddy_conf_file}]: "
  read -r custom_config
  caddy_conf_file="${custom_config:-$caddy_conf_file}"

  # 创建配置目录（如果不存在）
  mkdir -p "$(dirname "$caddy_conf_file")"

  # 备份已存在的配置文件
  if [[ -f "$caddy_conf_file" ]]; then
    cp "$caddy_conf_file" "${caddy_conf_file}.bak-$(date +%Y%m%d%H%M%S)"
    ok "已备份原配置文件到 ${caddy_conf_file}.bak"
  fi

  # 写入新的验证配置（单独配置文件）
  cat > "$caddy_conf_file" <<EOF
# ACME HTTP-01 验证配置
# 由 cert-easy 自动生成 - $(date '+%Y-%m-%d %H:%M:%S')

:80 {
    # 仅处理ACME验证路径
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
}
EOF

  ok "已写入 Caddy 验证配置文件: ${caddy_conf_file}"
  
  # 自动检测并写入主配置
  local import_added=false
  
  if [[ -n "$caddy_main_config" ]] && [[ -f "$caddy_main_config" ]]; then
    # 备份主配置文件
    cp "$caddy_main_config" "${caddy_main_config}.bak-$(date +%Y%m%d%H%M%S)"
    ok "已备份主配置文件到 ${caddy_main_config}.bak"
    
    # 检查是否已有导入语句
    if grep -q "import.*$(basename "$caddy_conf_file")" "$caddy_main_config" 2>/dev/null || \
       grep -q "import.*acme-challenge" "$caddy_main_config" 2>/dev/null; then
      ok "主配置文件中已包含ACME验证配置导入"
      import_added=true
    else
      # 检查配置文件格式
      if [[ "$caddy_main_config" == *.json ]]; then
        # JSON格式配置
        warn "检测到JSON格式配置，请手动添加以下配置:"
        echo ""
        echo "在 \"imports\" 数组中添加:"
        echo "  \"${caddy_conf_file}\""
        echo ""
      else
        # Caddyfile格式 - 自动添加导入语句
        echo "" >> "$caddy_main_config"
        echo "# ACME HTTP-01 验证配置导入" >> "$caddy_main_config"
        echo "import ${caddy_conf_file}" >> "$caddy_main_config"
        ok "已自动添加导入语句到主配置文件: ${caddy_main_config}"
        import_added=true
      fi
    fi
  else
    # 没有找到主配置文件，询问用户
    ask "未找到Caddy主配置文件，是否创建新的主配置文件? (y/N): "
    read -r create_main
    if [[ "$create_main" =~ ^[Yy]$ ]]; then
      if [[ -z "$caddy_main_config" ]]; then
        caddy_main_config="/etc/caddy/Caddyfile"
      fi
      
      # 创建主配置文件目录
      mkdir -p "$(dirname "$caddy_main_config")"
      
      # 创建主配置文件
      cat > "$caddy_main_config" <<EOF
# Caddy 主配置文件
# 由 cert-easy 自动创建 - $(date '+%Y-%m-%d %H:%M:%S')

# 导入ACME验证配置
import ${caddy_conf_file}

# 在这里添加您的其他站点配置
# example.com {
#     reverse_proxy localhost:8080
# }
EOF
      ok "已创建主配置文件: ${caddy_main_config}"
      import_added=true
    fi
  fi
  
  if [[ "$import_added" == false ]]; then
    warn "请在主Caddyfile中手动添加导入语句:"
    echo "  import ${caddy_conf_file}"
  fi

  # 测试配置
  if command -v caddy >/dev/null 2>&1; then
    local test_config=""
    
    # 确定测试用的配置文件
    if [[ -n "$caddy_main_config" ]] && [[ -f "$caddy_main_config" ]]; then
      test_config="$caddy_main_config"
    else
      test_config="$caddy_conf_file"
    fi
    
    # 根据配置文件格式进行测试
    if [[ "$test_config" == *.json ]]; then
      if caddy validate --config "$test_config" 2>/dev/null; then
        ok "Caddy JSON配置验证成功"
      else
        warn "Caddy JSON配置验证失败"
        caddy validate --config "$test_config" 2>&1 | head -20
      fi
    else
      if caddy validate --config "$test_config" 2>/dev/null; then
        ok "Caddy 配置验证成功"
        
        # 询问是否重载
        ask "是否重载 Caddy 配置? (y/N): "
        read -r reload
        if [[ "$reload" =~ ^[Yy]$ ]]; then
          if systemctl list-units --full -all 2>/dev/null | grep -q "caddy.service"; then
            systemctl reload caddy 2>/dev/null && ok "Caddy 配置已重载" || {
              systemctl restart caddy 2>/dev/null && ok "Caddy 服务已重启" || warn "Caddy 重载失败"
            }
          elif service --status-all 2>/dev/null | grep -q "caddy"; then
            service caddy reload 2>/dev/null || service caddy restart 2>/dev/null && ok "Caddy 服务已重载"
          elif [[ -f "/etc/init.d/caddy" ]]; then
            /etc/init.d/caddy reload 2>/dev/null || /etc/init.d/caddy restart 2>/dev/null && ok "Caddy 服务已重载"
          else
            warn "请手动重载 Caddy 服务"
          fi
        fi
      else
        warn "Caddy 配置验证失败"
        caddy validate --config "$test_config" 2>&1 | head -20
        
        # 如果验证失败，提供恢复选项
        ask "是否恢复备份的配置文件? (y/N): "
        read -r restore
        if [[ "$restore" =~ ^[Yy]$ ]]; then
          if [[ -f "${caddy_main_config}.bak" ]]; then
            mv "${caddy_main_config}.bak" "$caddy_main_config"
            ok "已恢复主配置文件"
          fi
          if [[ -f "${caddy_conf_file}.bak" ]]; then
            mv "${caddy_conf_file}.bak" "$caddy_conf_file"
            ok "已恢复验证配置文件"
          fi
        fi
      fi
    fi
  else
    warn "未找到 caddy 命令，请手动验证配置"
    echo "配置文件位置:"
    echo "  - 主配置: ${caddy_main_config:-未设置}"
    echo "  - 验证配置: ${caddy_conf_file}"
  fi
  
  # 显示配置总结
  echo ""
  echo "📋 Caddy 配置总结:"
  echo "  • 验证配置文件: ${caddy_conf_file}"
  echo "  • 主配置文件: ${caddy_main_config:-未找到}"
  if [[ "$import_added" == true ]]; then
    echo "  • 导入状态: ✅ 已自动添加"
  else
    echo "  • 导入状态: ⚠️  需要手动添加"
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
  echo "📝 Nginx 配置示例 (单独配置文件):"
  cat <<NGINX_EXAMPLE
# 创建文件: /etc/nginx/conf.d/acme-challenge.conf
server {
    listen 80;
    server_name _;

    location /.well-known/acme-challenge/ {
        root ${webroot};
        add_header Content-Type text/plain;
    }

    location /.well-known/pki-validation/ {
        root ${webroot};
        add_header Content-Type text/plain;
    }
}

# 如果使用 sites-enabled 目录:
# 创建文件: /etc/nginx/sites-enabled/acme-challenge
# 内容同上
NGINX_EXAMPLE

  echo
  echo "📝 Caddy 配置示例 (单独配置文件):"
  cat <<CADDY_EXAMPLE
# 创建文件: /etc/caddy/acme-challenge.caddy
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
}

# 在主 Caddyfile 中添加:
import /etc/caddy/acme-challenge.caddy
CADDY_EXAMPLE

  echo
  echo "📝 Apache 配置示例 (单独配置文件):"
  cat <<APACHE_EXAMPLE
# 创建文件: /etc/apache2/conf-available/acme-challenge.conf
Alias /.well-known/acme-challenge ${webroot}/.well-known/acme-challenge
Alias /.well-known/pki-validation ${webroot}/.well-known/pki-validation

<Directory ${webroot}>
    Options None
    AllowOverride None
    Require all granted
</Directory>

# 启用配置:
# a2enconf acme-challenge
# systemctl reload apache2
APACHE_EXAMPLE

  echo
  echo "💡 配置说明:"
  echo "  • 使用单独配置文件，不影响现有网站配置"
  echo "  • 仅处理 /.well-known/ 路径，其他请求仍由原配置处理"
  echo "  • 配置完成后请测试并重载 Web 服务器"
  echo "=========================================="
}

check_webroot_accessibility() {
  local webroot="$1"
  local ip_address="$2"
  local test_file="${webroot}/.well-known/acme-challenge/test-$(date +%s).txt"
  local test_content="acme-test-$(date +%s)-${RANDOM}"

  # 创建测试文件
  mkdir -p "$(dirname "$test_file")"
  echo "$test_content" > "$test_file"
  chmod 644 "$test_file"

  local test_url="http://${ip_address}/.well-known/acme-challenge/$(basename "$test_file")"
  
  ok "测试文件已创建: $test_file"
  ok "测试URL: $test_url"

  # 尝试访问（使用 curl）
  if curl -s -f --connect-timeout 10 "$test_url" 2>/dev/null | grep -q "$test_content"; then
    rm -f "$test_file"
    ok "验证目录可正常访问 ✓"
    return 0
  else
    # 清理
    rm -f "$test_file"
    warn "无法访问验证目录 ✗"
    echo "可能的原因:"
    echo "  • Web服务器未运行"
    echo "  • 防火墙阻止了80端口"
    echo "  • 配置文件未正确加载"
    echo "  • 文件权限问题"
    return 1
  fi
}

# ===== 自签证书生成函数 =====
generate_self_signed_cert() {
  load_config
  
  echo "📛 输入证书的主域名或标识 (如 example.com 或 cdn-backend): "
  read -r DOMAIN
  
  ask "➕ 额外域名(逗号分隔，可空): "
  read -r ALT
  
  ask "📅 证书有效期(天数) [默认 ${SELF_SIGN_DAYS}]: "
  read -r days
  days=${days:-$SELF_SIGN_DAYS}
  
  ask "🔑 密钥长度 [2048|3072|4096] [默认 ${SELF_SIGN_KEYLEN}]: "
  read -r keylen
  keylen=${keylen:-$SELF_SIGN_KEYLEN}
  
  ask "🏢 组织名称 (O) [默认: Cert-Easy Self-Signed]: "
  read -r org
  org=${org:-"Cert-Easy Self-Signed"}
  
  ask "📍 城市/地区 (L) [默认: Internet]: "
  read -r city
  city=${city:-"Internet"}
  
  ask "🌍 国家代码 (C) [默认: CN]: "
  read -r country
  country=${country:-"CN"}
  
  # 构建主题字符串
  local subject="/C=${country}/L=${city}/O=${org}/CN=${DOMAIN}"
  
  # 构建SAN扩展
  local san_list="DNS:${DOMAIN}"
  if [[ -n "$ALT" ]]; then
    IFS=',' read -r -a alt_domains <<< "$ALT"
    for alt_domain in "${alt_domains[@]}"; do
      alt_domain="$(echo "$alt_domain" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      if [[ -n "$alt_domain" ]]; then
        san_list="${san_list},DNS:${alt_domain}"
      fi
    done
  fi
  
  # 创建输出目录
  local OUT_DIR="${OUT_DIR_BASE}/${DOMAIN}-selfsigned"
  mkdir -p "$OUT_DIR"
  chmod 700 "$OUT_DIR"
  
  # 生成私钥
  ok "正在生成 ${keylen} 位 RSA 私钥..."
  openssl genrsa -out "${OUT_DIR}/privkey.key" "${keylen}"
  
  # 生成CSR配置文件
  local openssl_config="${OUT_DIR}/openssl.cnf"
  cat > "$openssl_config" <<EOF
[req]
default_bits = ${keylen}
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C = ${country}
L = ${city}
O = ${org}
CN = ${DOMAIN}

[v3_req]
keyUsage = keyEncipherment, dataEncipherment, digitalSignature
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = ${san_list}
EOF
  
  # 生成CSR
  ok "正在生成证书签名请求..."
  openssl req -new -key "${OUT_DIR}/privkey.key" \
    -out "${OUT_DIR}/cert.csr" \
    -config "$openssl_config"
  
  # 生成自签证书
  ok "正在生成自签证书 (有效期 ${days} 天)..."
  openssl x509 -req -days "${days}" \
    -in "${OUT_DIR}/cert.csr" \
    -signkey "${OUT_DIR}/privkey.key" \
    -out "${OUT_DIR}/cert.pem" \
    -extfile "$openssl_config" \
    -extensions v3_req
  
  # 生成链证书（自签证书的链就是它自己）
  cp "${OUT_DIR}/cert.pem" "${OUT_DIR}/chain.pem"
  cat "${OUT_DIR}/cert.pem" "${OUT_DIR}/chain.pem" > "${OUT_DIR}/fullchain.pem"
  
  # 设置权限
  chmod 600 "${OUT_DIR}/privkey.key"
  chmod 644 "${OUT_DIR}"/*.pem "${OUT_DIR}"/*.csr 2>/dev/null || true
  chmod 644 "$openssl_config"
  
  # 清理临时文件
  rm -f "${OUT_DIR}/cert.csr" "$openssl_config"
  
  ok "自签证书生成完成！"
  echo "=========================================="
  echo "证书信息:"
  echo "  主域名: ${DOMAIN}"
  if [[ -n "$ALT" ]]; then
    echo "  备用域名: ${ALT}"
  fi
  echo "  有效期: ${days} 天"
  echo "  密钥长度: ${keylen} bit"
  echo ""
  echo "📁 证书路径:"
  echo "  - 私钥:        ${OUT_DIR}/privkey.key"
  echo "  - 证书:        ${OUT_DIR}/cert.pem"
  echo "  - 链证书:      ${OUT_DIR}/chain.pem"
  echo "  - 全链:        ${OUT_DIR}/fullchain.pem"
  echo ""
  echo "📋 证书详细信息:"
  openssl x509 -in "${OUT_DIR}/cert.pem" -text -noout | grep -E "Subject:|Issuer:|Not Before:|Not After :|DNS:"
  echo "=========================================="
  
  # 询问是否安装重载命令
  if [[ -n "${RELOAD_CMD:-}" ]]; then
    ask "是否执行重载命令? (y/N): "
    read -r do_reload
    if [[ "$do_reload" =~ ^[Yy]$ ]]; then
      eval "$RELOAD_CMD" && ok "重载命令执行成功" || warn "重载命令执行失败"
    fi
  fi
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
  echo "[3] 自签证书 (用于内部使用/CDN回源)"
  ask "选择类型 (1/2/3): "
  read -r cert_type_choice

  case "$cert_type_choice" in
    1)
      issue_domain_cert_flow
      ;;
    2)
      issue_ip_cert_flow
      ;;
    3)
      generate_self_signed_cert
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
  echo "========== ACME 管理的证书 =========="
  "$ACME" --list
  
  echo ""
  echo "========== 自签证书 =========="
  local self_signed_dirs=()
  while IFS= read -r -d '' dir; do
    if [[ -f "${dir}/cert.pem" ]] && [[ -f "${dir}/privkey.key" ]]; then
      self_signed_dirs+=("$dir")
    fi
  done < <(find "$OUT_DIR_BASE" -maxdepth 1 -type d -name "*-selfsigned" -print0 2>/dev/null || true)
  
  if [[ ${#self_signed_dirs[@]} -eq 0 ]]; then
    echo "未找到自签证书"
  else
    for dir in "${self_signed_dirs[@]}"; do
      local cert_name=$(basename "$dir")
      if [[ -f "${dir}/cert.pem" ]]; then
        local expiry_info
        expiry_info=$(openssl x509 -in "${dir}/cert.pem" -noout -enddate 2>/dev/null | cut -d= -f2- || echo "未知")
        echo "  - ${cert_name} (有效期至: ${expiry_info})"
      fi
    done
  fi
}

show_cert_path() {
  load_config
  
  # 收集所有可用的证书
  local certs=()
  local cert_names=()
  local cert_paths=()
  
  # 收集 ACME 管理的证书（从 acme.sh 列表获取）
  ensure_acme
  local acme_list
  acme_list=$("$ACME" --list 2>/dev/null | grep -E '^[^ ]+\.' | awk '{print $1}' || true)
  
  while IFS= read -r domain; do
    [[ -n "$domain" ]] || continue
    # 检查证书文件是否存在
    local p="${OUT_DIR_BASE}/${domain}"
    if [[ -d "$p" ]] && [[ -f "${p}/cert.pem" ]]; then
      certs+=("$domain")
      cert_names+=("$domain")
      cert_paths+=("$p")
    fi
  done <<< "$acme_list"
  
  # 收集自签证书
  while IFS= read -r -d '' dir; do
    if [[ -f "${dir}/cert.pem" ]] && [[ -f "${dir}/privkey.key" ]]; then
      local cert_name=$(basename "$dir" | sed 's/-selfsigned$//')
      certs+=("${cert_name} (自签)")
      cert_names+=("$cert_name")
      cert_paths+=("$dir")
    fi
  done < <(find "$OUT_DIR_BASE" -maxdepth 1 -type d -name "*-selfsigned" -print0 2>/dev/null || true)
  
  # 如果没有找到任何证书
  if [[ ${#certs[@]} -eq 0 ]]; then
    warn "未找到任何证书"
    return 1
  fi
  
  # 显示证书列表供用户选择
  echo "可用的证书:"
  for i in "${!certs[@]}"; do
    local idx=$((i+1))
    echo "[$idx] ${certs[$i]}"
  done
  echo "[0] 返回"
  
  ask "请选择证书编号: "
  read -r choice
  
  # 处理选择
  if [[ "$choice" == "0" ]]; then
    return 0
  fi
  
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#certs[@]} ]]; then
    warn "无效选择"
    return 1
  fi
  
  local selected_idx=$((choice-1))
  local selected_cert="${cert_names[$selected_idx]}"
  local cert_path="${cert_paths[$selected_idx]}"
  
  # 检查路径是否存在
  if [[ ! -d "$cert_path" ]]; then
    err "证书路径不存在: $cert_path"
  fi
  
  # 显示证书信息（与申请证书时的格式保持一致）
  ok "证书信息:"
  echo "  主域名/标识: ${selected_cert}"
  echo ""
  echo "📁 证书路径: ${cert_path}"
  echo "  - 私钥:        ${cert_path}/privkey.key"
  echo "  - 证书:        ${cert_path}/cert.pem"
  echo "  - 链证书:      ${cert_path}/chain.pem"
  echo "  - 全链:        ${cert_path}/fullchain.pem"
  echo ""
  
  # 显示文件列表
  if [[ -d "$cert_path" ]]; then
    ls -l "$cert_path" | while read -r line; do
      echo "  $line"
    done
  fi
  
  # 显示证书详细信息
  if [[ -f "${cert_path}/cert.pem" ]]; then
    echo ""
    echo "📋 证书详细信息:"
    openssl x509 -in "${cert_path}/cert.pem" -text -noout 2>/dev/null | grep -E "Subject:|Issuer:|Not Before:|Not After :|DNS:" | while read -r line; do
      echo "  $line"
    done
  fi
}

delete_cert() {
  load_config
  
  # 收集所有可用的证书
  local certs=()
  local cert_names=()
  local cert_paths=()
  local cert_types=()  # "acme" 或 "selfsigned"
  
  # 收集 ACME 管理的证书（从 acme.sh 列表获取）
  ensure_acme
  local acme_list
  acme_list=$("$ACME" --list 2>/dev/null | grep -E '^[^ ]+\.' | awk '{print $1}' || true)
  
  while IFS= read -r domain; do
    [[ -n "$domain" ]] || continue
    # 检查证书文件是否存在
    local p="${OUT_DIR_BASE}/${domain}"
    if [[ -d "$p" ]] && [[ -f "${p}/cert.pem" ]]; then
      certs+=("$domain")
      cert_names+=("$domain")
      cert_paths+=("$p")
      cert_types+=("acme")
    fi
  done <<< "$acme_list"
  
  # 收集自签证书
  while IFS= read -r -d '' dir; do
    if [[ -f "${dir}/cert.pem" ]] && [[ -f "${dir}/privkey.key" ]]; then
      local cert_name=$(basename "$dir" | sed 's/-selfsigned$//')
      certs+=("${cert_name} (自签)")
      cert_names+=("$cert_name")
      cert_paths+=("$dir")
      cert_types+=("selfsigned")
    fi
  done < <(find "$OUT_DIR_BASE" -maxdepth 1 -type d -name "*-selfsigned" -print0 2>/dev/null || true)
  
  # 如果没有找到任何证书
  if [[ ${#certs[@]} -eq 0 ]]; then
    warn "未找到任何证书"
    return 1
  fi
  
  # 显示证书列表供用户选择
  echo "可删除的证书:"
  for i in "${!certs[@]}"; do
    local idx=$((i+1))
    echo "[$idx] ${certs[$i]}"
    
    # 显示证书有效期信息
    if [[ -f "${cert_paths[$i]}/cert.pem" ]]; then
      local expiry_info
      expiry_info=$(openssl x509 -in "${cert_paths[$i]}/cert.pem" -noout -enddate 2>/dev/null | cut -d= -f2- || echo "未知")
      echo "     有效期至: ${expiry_info}"
    fi
  done
  echo "[0] 返回"
  
  ask "请选择要删除的证书编号: "
  read -r choice
  
  # 处理选择
  if [[ "$choice" == "0" ]]; then
    return 0
  fi
  
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#certs[@]} ]]; then
    warn "无效选择"
    return 1
  fi
  
  local selected_idx=$((choice-1))
  local selected_cert="${cert_names[$selected_idx]}"
  local cert_path="${cert_paths[$selected_idx]}"
  local cert_type="${cert_types[$selected_idx]}"
  
  # 显示证书信息确认
  echo ""
  ok "您选择的证书:"
  echo "  标识: ${selected_cert}"
  echo "  类型: $([[ "$cert_type" == "acme" ]] && echo "ACME 证书" || echo "自签证书")"
  echo "  路径: ${cert_path}"
  
  if [[ -f "${cert_path}/cert.pem" ]]; then
    local expiry_info
    expiry_info=$(openssl x509 -in "${cert_path}/cert.pem" -noout -enddate 2>/dev/null | cut -d= -f2- || echo "未知")
    local issuer_info
    issuer_info=$(openssl x509 -in "${cert_path}/cert.pem" -noout -issuer 2>/dev/null | cut -d= -f2- || echo "未知")
    echo "  颁发者: ${issuer_info}"
    echo "  有效期至: ${expiry_info}"
  fi
  
  echo ""
  
  # 处理自签证书
  if [[ "$cert_type" == "selfsigned" ]]; then
    ask "确认删除自签证书目录 ${cert_path} ? (y/N): "
    read -r del_self
    if [[ "$del_self" =~ ^[Yy]$ ]]; then
      rm -rf "$cert_path" && ok "已删除自签证书: ${selected_cert}" || warn "删除失败"
    else
      warn "已取消删除"
    fi
    return 0
  fi
  
  # 标准证书删除流程（ACME证书）
  echo "请选择删除方式:"
  echo "[1] 仅从 acme.sh 移除（保留证书文件）"
  echo "[2] 吊销并删除（从 acme.sh 移除并删除证书文件）"
  echo "[3] 完全删除（吊销、从 acme.sh 移除、删除证书文件）"
  echo "[0] 取消"
  
  ask "请选择 (0-3): "
  read -r delete_option
  
  case "$delete_option" in
    0)
      warn "已取消删除"
      return 0
      ;;
    1)
      # 仅从 acme.sh 移除
      "$ACME" --remove -d "$selected_cert" && ok "已从 acme.sh 移除证书管理项: ${selected_cert}"
      warn "证书文件已保留: ${cert_path}"
      ;;
    2)
      # 吊销并删除（从 acme.sh 移除并删除证书文件）
      ask "是否确认吊销证书 ${selected_cert}? (y/N): "
      read -r confirm_revoke
      if [[ "$confirm_revoke" =~ ^[Yy]$ ]]; then
        "$ACME" --revoke -d "$selected_cert" 2>/dev/null && ok "证书已吊销: ${selected_cert}" || warn "吊销失败或证书无需吊销"
      fi
      
      "$ACME" --remove -d "$selected_cert" && ok "已从 acme.sh 移除证书管理项: ${selected_cert}"
      
      if [[ -d "$cert_path" ]]; then
        ask "确认删除证书文件目录 ${cert_path} ? (y/N): "
        read -r del_files
        if [[ "$del_files" =~ ^[Yy]$ ]]; then
          rm -rf "$cert_path" && ok "已删除证书文件: ${cert_path}"
        else
          warn "证书文件已保留: ${cert_path}"
        fi
      fi
      ;;
    3)
      # 完全删除
      ask "⚠️  危险操作！确认完全删除证书 ${selected_cert} ？(必须输入 yes 确认): "
      read -r confirm_full
      if [[ "$confirm_full" != "yes" ]]; then
        warn "已取消删除"
        return 0
      fi
      
      # 吊销
      "$ACME" --revoke -d "$selected_cert" 2>/dev/null && ok "证书已吊销: ${selected_cert}" || warn "吊销失败或证书无需吊销"
      
      # 从 acme.sh 移除
      "$ACME" --remove -d "$selected_cert" && ok "已从 acme.sh 移除证书管理项: ${selected_cert}"
      
      # 删除证书文件
      if [[ -d "$cert_path" ]]; then
        rm -rf "$cert_path" && ok "已删除证书文件: ${cert_path}"
      fi
      
      # 同时删除可能的备份目录
      local backup_path="${OUT_DIR_BASE}/.${selected_cert}.bak"
      if [[ -d "$backup_path" ]]; then
        rm -rf "$backup_path" && ok "已删除证书备份: ${backup_path}"
      fi
      ;;
    *)
      warn "无效选择"
      return 1
      ;;
  esac
  
  # 检查 acme.sh 配置目录中是否还有相关文件
  local acme_conf_dir="${ACME_HOME}/${selected_cert}"
  if [[ -d "$acme_conf_dir" ]]; then
    warn "检测到 acme.sh 配置目录: ${acme_conf_dir}"
    ask "是否同时删除该配置目录? (y/N): "
    read -r del_conf
    if [[ "$del_conf" =~ ^[Yy]$ ]]; then
      rm -rf "$acme_conf_dir" && ok "已删除 acme.sh 配置目录"
    fi
  fi
  
  ok "证书删除操作完成"
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
set_selfsign_days() {
  load_config
  ask "设置自签证书默认有效期（天数） [当前 ${SELF_SIGN_DAYS}]: "
  read -r days
  [[ -n "$days" ]] && save_kv SELF_SIGN_DAYS "$days" && ok "自签证书默认有效期设为 ${days} 天"
}
set_selfsign_keylen() {
  load_config
  ask "设置自签证书默认密钥长度 [2048|3072|4096] [当前 ${SELF_SIGN_KEYLEN}]: "
  read -r keylen
  [[ -n "$keylen" ]] && save_kv SELF_SIGN_KEYLEN "$keylen" && ok "自签证书默认密钥长度设为 ${keylen} 位"
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
    echo "[1] 申请/续期证书 (支持域名、IP和自签证书)"
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
         echo "  [6] 设置自签证书默认有效期"
         echo "  [7] 设置自签证书默认密钥长度"
         echo "  [0] 返回上级"
         ask "选择: "
         read -r s
         case "$s" in
           1) set_reload_cmd ;;
           2) set_keylen_default ;;
           3) set_outdir_base ;;
           4) set_validation_webroot ;;
           5) set_ip_cert_days ;;
           6) set_selfsign_days ;;
           7) set_selfsign_keylen ;;
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
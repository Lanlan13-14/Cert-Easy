#!/usr/bin/env bash
# cert-easy: 交互式 DNS-01 证书申请/管理，支持 Cloudflare / DNSPod(CN&Global) / 阿里云(CN&Global) / dynv6 / 火山引擎 / 华为云(CN&Global) / 百度云
# 功能：申请/安装、列出/查看/删除证书；凭据新增/删除（删除前提示依赖域名）；温和的自动续期策略；更新脚本；两级卸载
# 依赖：bash、curl、openssl、crontab(可选)
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

# ===== 样式 =====
ok()   { echo -e "\033[1;32m[✔]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
err()  { echo -e "\033[1;31m[✘]\033[0m $*"; exit 1; }
ask()  { echo -ne "\033[1;36m[?]\033[0m $*"; }
self_path(){ readlink -f "$0" 2>/dev/null || echo "$0"; }

ensure_cmd(){ command -v "$1" >/dev/null 2>&1 || err "缺少依赖: $1"; }
ensure_cmd curl
ensure_cmd openssl

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
  load_config
  if [[ -z "${EMAIL}" ]]; then
    ask "📧 首次使用，输入 ACME 账号邮箱: "
    read -r EMAIL
    save_kv EMAIL "$EMAIL"
  fi
  save_kv OUT_DIR_BASE "$OUT_DIR_BASE"
  save_kv KEYLEN_DEFAULT "$KEYLEN_DEFAULT"
  save_kv AUTO_RENEW "$AUTO_RENEW"
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
providers_menu() {
  cat <<EOF
可用 DNS 提供商:
  - Cloudflare (cf)
  - DNSPod 中国站 (dnspod-cn)
  - DNSPod 国际站 (dnspod-global)
  - 阿里云 中国/国际 (aliyun-cn / aliyun-global)
  - dynv6 (dynv6)
  - 火山引擎 Volcengine (volcengine)
  - 华为云 中国站 (huaweicloud-cn)
  - 华为云 国际站 (huaweicloud-global)
  - 百度云 (baidu)
EOF
}

provider_to_dnsapi() {
  case "$1" in
    cf)                       echo "dns_cf" ;;
    dnspod-cn|dnspod-global)  echo "dns_dp" ;;
    aliyun-cn|aliyun-global)  echo "dns_ali" ;;
    dynv6)                    echo "dns_dynv6" ;;
    volcengine)               echo "dns_volcengine" ;;
    huaweicloud-cn)           echo "dns_huaweicloud" ;;
    huaweicloud-global)       echo "dns_huaweicloud" ;;
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
    huaweicloud-global)
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
  providers_menu
  ask "选择提供商代号 (cf/dnspod-cn/dnspod-global/aliyun-cn/aliyun-global/dynv6/volcengine/huaweicloud-cn/huaweicloud-global/baidu): "
  read -r p
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
    huaweicloud-global)
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
    huaweicloud-cn|huaweicloud-global) echo "HUAWEICLOUD_Username HUAWEICLOUD_Password HUAWEICLOUD_ProjectID HUAWEICLOUD_IdentityEndpoint" ;;
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
  providers_menu
  ask "选择要删除凭据的提供商 (cf/dnspod-cn/dnspod-global/aliyun-cn/aliyun-global/dynv6/volcengine/huaweicloud-cn/huaweicloud-global/baidu): "
  read -r p
  local label="$p" short="$p"
  case "$p" in
    dnspod-cn|dnspod-global) short="dnspod" ;;
    aliyun-cn|aliyun-global) short="aliyun" ;;
    huaweicloud-cn|huaweicloud-global) short="huaweicloud" ;;
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

# ===== 证书申请/安装 =====
prompt_issue_params() {
  ask "🌐 选择提供商 (cf/dnspod-cn/dnspod-global/aliyun-cn/aliyun-global/dynv6/volcengine/huaweicloud-cn/huaweicloud-global/baidu): "
  read -r PROVIDER
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

issue_flow() {
  load_config
  prompt_issue_params

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

# ===== 证书管理 =====
list_certs() {
  ensure_acme
  "$ACME" --list
}

show_cert_path() {
  load_config
  ask "输入域名以显示证书路径: "
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
  ask "输入要删除的域名: "
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
    echo " 1) 申请/续期证书 (DNS-01)"
    echo " 2) 列出已管理证书"
    echo " 3) 显示某域名证书路径"
    echo " 4) 删除证书（可选吊销并移出续期清单）"
    echo " 5) 自动续期开关 / 状态：$(cron_status)"
    echo " 6) 凭据管理：新增/更新"
    echo " 7) 凭据管理：删除（删除前列出依赖域名）"
    echo " 8) 设置：重载命令 / 默认密钥长度 / 证书目录"
    echo " 9) 更新脚本（从远程拉取并重启）"
    echo "10) 卸载（一级/二级）"
    echo " 0) 退出"
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
      8) echo "  a) 设置重载命令"
         echo "  b) 设置默认密钥长度"
         echo "  c) 设置证书根目录"
         ask "选择: "
         read -r s
         case "$s" in
           a) set_reload_cmd ;;
           b) set_keylen_default ;;
           c) set_outdir_base ;;
           *) warn "无效选择" ;;
         esac ;;
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
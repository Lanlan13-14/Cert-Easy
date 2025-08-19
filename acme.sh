#!/usr/bin/env bash
# cert-easy: interactive DNS-01 ACME helper for Cloudflare/DNSPod/Aliyun/dynv6/Volcengine
# requirements: bash, curl, openssl, crontab(optional)
set -Eeuo pipefail

# ===== styling =====
ok()   { echo -e "\033[1;32m[✔]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
err()  { echo -e "\033[1;31m[✘]\033[0m $*"; }
ask()  { echo -ne "\033[1;36m[?]\033[0m $*"; }

# ===== paths & defaults =====
CRED_FILE="/root/.acme-cred"
ACME_HOME="${HOME}/.acme.sh"
ACME="${ACME_HOME}/acme.sh"
OUT_DIR_BASE_DEFAULT="/etc/ssl/acme"
KEYLEN_DEFAULT="ec-256"   # ec-256 | ec-384 | 2048 | 3072 | 4096
CRON_WRAPPER="/usr/local/bin/cert-easy-cron"
AUTO_RENEW_DEFAULT="1"    # 1=开启自动续期；0=关闭，但保留 cron 任务

ensure_cmd() { command -v "$1" >/dev/null 2>&1 || { err "缺少依赖: $1"; exit 1; }; }
ensure_cmd curl
ensure_cmd openssl

# ===== config load/save =====
touch_if_absent() {
  [[ -f "$1" ]] || { umask 077; : >"$1"; chmod 600 "$1"; }
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
    # shellcheck disable=SC2001
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

# ===== acme.sh install =====
ensure_acme() {
  if [[ ! -x "$ACME" ]]; then
    ok "安装 acme.sh ..."
    curl -fsSL https://get.acme.sh | sh -s email="${EMAIL}"
  fi
  [[ -x "$ACME" ]] || { err "acme.sh 未安装成功"; exit 1; }
}

# ===== cron reconcile (温和策略) =====
has_crontab() { command -v crontab >/dev/null 2>&1; }

ensure_cron_wrapper() {
  # 包装脚本：读取 AUTO_RENEW，若为 1 则执行 acme.sh --cron；否则安静退出
  cat >"$CRON_WRAPPER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
CRED_FILE="$CRED_FILE"
ACME_HOME="$ACME_HOME"
ACME="$ACME"
AUTO_RENEW_DEFAULT="$AUTO_RENEW_DEFAULT"
AUTO_RENEW="\$AUTO_RENEW_DEFAULT"
if [[ -f "\$CRED_FILE" ]]; then
  # shellcheck disable=SC1090
  . "\$CRED_FILE"
fi
AUTO_RENEW="\${AUTO_RENEW:-\$AUTO_RENEW_DEFAULT}"
if [[ "\$AUTO_RENEW" = "1" ]]; then
  "\$ACME" --cron --home "\$ACME_HOME" >/dev/null 2>&1 || true
fi
exit 0
EOF
  chmod 755 "$CRON_WRAPPER"
}

ensure_cron_job() {
  has_crontab || { warn "系统未提供 crontab，跳过自动续期计划任务安装"; return 0; }
  ensure_cron_wrapper

  # 读取现有 crontab（可能为空）
  local cr cur new line
  cr="$(crontab -l 2>/dev/null || true)"
  line="7 3 * * * $CRON_WRAPPER # cert-easy"

  if echo "$cr" | grep -qF "$CRON_WRAPPER"; then
    # 已存在包装任务，保持不动
    return 0
  fi

  if echo "$cr" | grep -Eq 'acme\.sh.*--cron'; then
    # 将原生 acme.sh cron 替换为包装任务（保留 cron，本地化控制 AUTO_RENEW）
    new="$(echo "$cr" | sed -E "s|.*acme\.sh.*--cron.*|$line|g")"
  else
    # 追加包装任务
    new="$cr"$'\n'"$line"
  fi

  printf "%s\n" "$new" | crontab -
  ok "已确保安装 cert-easy 的自动续期计划任务（保留系统 cron）"
}

cron_status() {
  load_config
  echo "AUTO_RENEW=${AUTO_RENEW} / 计划任务$(has_crontab && echo 已配置 || echo 未配置)"
}

toggle_auto_renew() {
  load_config
  if [[ "${AUTO_RENEW}" = "1" ]]; then
    ask "检测到 AUTO_RENEW=1，是否关闭自动续期但保留 cron 任务? (y/N): "
    read -r x
    [[ "$x" =~ ^[Yy]$ ]] && save_kv AUTO_RENEW "0" && ok "已关闭自动续期（保留 cron 任务）"
  else
    ask "AUTO_RENEW=0，是否开启自动续期? (y/N): "
    read -r x
    [[ "$x" =~ ^[Yy]$ ]] && save_kv AUTO_RENEW "1" && ok "已开启自动续期"
  fi
  ensure_cron_job
}

# ===== provider helpers =====
providers_menu() {
  cat <<EOF
可用 DNS 提供商:
  1) Cloudflare (cf)
  2) DNSPod 中国站 (dnspod-cn)
  3) DNSPod 国际站 (dnspod-global)
  4) 阿里云 中国/国际 (aliyun-cn/aliyun-global)
  5) dynv6 (dynv6)
  6) 火山引擎 Volcengine (volcengine)
EOF
}

provider_to_dnsapi() {
  case "$1" in
    cf)                       echo "dns_cf" ;;
    dnspod-cn|dnspod-global)  echo "dns_dp" ;;
    aliyun-cn|aliyun-global)  echo "dns_ali" ;;
    dynv6)                    echo "dns_dynv6" ;;
    volcengine)               echo "dns_volcengine" ;;
    *) return 1 ;;
  esac
}

export_provider_env() {
  local p="$1"
  case "$p" in
    cf)
      if [[ -n "${CF_Token:-}" ]]; then export CF_Token; else
        if [[ -n "${CF_Key:-}" && -n "${CF_Email:-}" ]]; then export CF_Key CF_Email; else
          err "Cloudflare 凭据缺失。请在 [凭据管理] 中添加 CF_Token 或 CF_Key+CF_Email"; return 1
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
    *) err "未知 provider: $p"; return 1 ;;
  esac
}

add_or_update_creds() {
  load_config
  providers_menu
  ask "选择提供商代号 (cf/dnspod-cn/dnspod-global/aliyun-cn/aliyun-global/dynv6/volcengine): "
  read -r p
  case "$p" in
    cf)
      ask "优先推荐 CF_Token。输入 CF_Token (留空则改为使用 CF_Key/CF_Email): "
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
    *) err "无效选择"; return 1;;
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
  esac
}

scan_provider_usage() {
  # outputs: "provider<TAB>domain"
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
    esac
  done
}

delete_provider_creds() {
  load_config
  providers_menu
  ask "选择要删除凭据的提供商 (cf/dnspod-cn/dnspod-global/aliyun-cn/aliyun-global/dynv6/volcengine): "
  read -r p
  local label="$p" short="$p"
  case "$p" in
    dnspod-cn|dnspod-global) short="dnspod" ;;
    aliyun-cn|aliyun-global) short="aliyun" ;;
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
  [[ "$ans" == "yes" ]] || { warn "已取消删除。"; return 0; }

  if ((${#inuse[@]})); then
    ask "是否同时删除上述证书（并移出续期列表）? (y/N): "
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
  ok "已从 $CRED_FILE 删除 $label 的凭据"
}

# ===== issue / install =====
prompt_issue_params() {
  ask "🌐 选择提供商 (cf/dnspod-cn/dnspod-global/aliyun-cn/aliyun-global/dynv6/volcengine): "
  read -r PROVIDER
  ask "📛 主域名 (如 example.com): "
  read -r DOMAIN
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
  export_provider_env "$PROVIDER" || return 1
  local DNS_API; DNS_API=$(provider_to_dnsapi "$PROVIDER") || { err "provider 无效"; return 1; }

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

  ok "签发完成。证书存储路径：$OUT_DIR"
  echo "  - 私钥:        $OUT_DIR/privkey.key"
  echo "  - 证书:        $OUT_DIR/cert.pem"
  echo "  - 链证书:      $OUT_DIR/chain.pem"
  echo "  - 全链:        $OUT_DIR/fullchain.pem"

  # 确保计划任务存在（温和策略）
  ensure_cron_job
}

# ===== list / show / delete certs =====
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
  # --remove 会从 acme.sh 的续期清单删除该域名，相当于移除了对应的自动续期任务
  "$ACME" --remove -d "$d" && ok "已删除证书管理项并移出续期清单：$d"

  # 可选删除本地文件
  load_config
  local p="${OUT_DIR_BASE}/${d}"
  if [[ -d "$p" ]]; then
    ask "删除本地证书文件目录 $p ? (y/N): "
    read -r delp
    [[ "$delp" =~ ^[Yy]$ ]] && rm -rf -- "$p" && ok "已删除 $p"
  fi

  # 保留 cron：不做任何 cron 卸载操作
}

# ===== auto-renew settings =====
set_reload_cmd() {
  load_config
  ask "输入证书安装/续期后执行的重载命令（留空取消，例如 systemctl reload nginx）: "
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

# ===== creds usage & deletion =====
delete_provider_creds_entrypoint() { delete_provider_creds; }

# ===== menu =====
main_menu() {
  while true; do
    echo
    echo "======== cert-easy ========"
    echo "1) 申请/续期 证书 (DNS-01)"
    echo "2) 列出已管理证书"
    echo "3) 显示某域名证书路径"
    echo "4) 删除证书（可选先吊销；自动移出续期清单）"
    echo "5) 自动续期 开关 / 状态（不卸载 cron）: $(cron_status)"
    echo "6) 凭据管理：新增/更新"
    echo "7) 凭据管理：删除（安全提示域名关联）"
    echo "8) 设置：重载命令 / 默认密钥长度 / 证书目录"
    echo "9) 退出"
    ask "选择: "
    read -r op
    case "$op" in
      1) issue_flow ;;
      2) list_certs ;;
      3) show_cert_path ;;
      4) delete_cert ;;
      5) toggle_auto_renew ;;
      6) add_or_update_creds ;;
      7) delete_provider_creds_entrypoint ;;
      8)
         echo "  a) 设置重载命令"
         echo "  b) 设置默认密钥长度"
         echo "  c) 设置证书根目录"
         ask "选择: "; read -r s
         case "$s" in
           a) set_reload_cmd ;;
           b) set_keylen_default ;;
           c) set_outdir_base ;;
           *) warn "无效选择" ;;
         esac
         ;;
      9) exit 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

# ===== run =====
init_minimal
ensure_acme
ensure_cron_job
main_menu
#!/bin/sh
# =============================================================================
# dsh TLS 终结器证书准备(挂载为容器 /docker-entrypoint.d/10-tls-cert.sh,
# 官方入口先跑它再起 nginx, 证书必先于 ssl_certificate 就位)。
# 域名唯一来源: 环境变量 DSH_DOMAIN(compose 从 .env 注入)。
#
# 复用/重签规则(证书"可用"就保留, 否则删除重签自签覆盖):
#   可用 = .crt 可解析 + 覆盖 $DSH_DOMAIN(SAN 优先, 通配符按 RFC 6125 单级
#          匹配; 无 SAN 退回 CN) + key 配对 + 未到期
#   到期线: 自签证书提前 30 天就算不可用; CA 签发(含手工放置的通配符证书)
#          只要还没过期就算可用 - 续期交给 certbot/运维, 避免竞态。
# 文件固定 /etc/nginx/tls/$DSH_DOMAIN.{crt,key}; key 支持 RSA/EC/Ed25519。
# =============================================================================
set -eu

domain="${DSH_DOMAIN:-harness.deepseek.com}"
crt="/etc/nginx/tls/$domain.crt"
key="/etc/nginx/tls/$domain.key"
mkdir -p /etc/nginx/tls

# 某 SAN/CN 条目(确切域名或 *.suffix)是否覆盖 $domain
covers() {
    [ "$1" = "$domain" ] && return 0
    case "$1" in
        \*.*) case "$domain" in ?*.*) [ "${domain#*.}" = "${1#\*.}" ] && return 0 ;; esac ;;
    esac
    return 1
}

cert_covers() {
    names="$(openssl x509 -noout -ext subjectAltName -in "$crt" 2>/dev/null \
             | tr ',' '\n' | sed -n 's/.*DNS:[[:space:]]*//p' | tr -d ' ')"
    [ -n "$names" ] || names="$(openssl x509 -noout -subject -nameopt sep_multiline -in "$crt" 2>/dev/null \
             | sed -n 's/.*CN[[:space:]]*=//p' | head -n 1 | tr -d ' ')"
    for n in $names; do covers "$n" && return 0; done
    return 1
}

# key 与证书配对: SHA256(pubkey) 相同(x509 只读 fullchain 的叶子证书)。
# NB: pkey 不能加 -noout, 它会连 -pubout 的输出一起抑制。
key_matches() {
    c="$(openssl x509 -noout -pubkey -in "$crt" 2>/dev/null | openssl sha256 | awk '{print $NF}')"
    k="$(openssl pkey -pubout -in "$key" 2>/dev/null | openssl sha256 | awk '{print $NF}')"
    [ -n "$c" ] && [ "$c" = "$k" ]
}

# issuer == subject -> 自签; CA 签发(含 Let's Encrypt 通配符)两者不同
dn() { openssl x509 -noout -$1 -in "$crt" 2>/dev/null | sed 's/^[a-z]*=[[:space:]]*//'; }
selfsigned() { [ -n "$(dn subject)" ] && [ "$(dn subject)" = "$(dn issuer)" ]; }

# ---------------------------------------------------------------------------
if [ -f "$crt" ] && [ -f "$key" ] && openssl x509 -noout -in "$crt" >/dev/null 2>&1 \
   && key_matches && cert_covers; then
    selfsigned && margin=$((30 * 86400)) || margin=0
    if openssl x509 -checkend "$margin" -noout -in "$crt" >/dev/null 2>&1; then
        echo "$0: certificate for $domain usable (issuer: $(dn issuer)) - keeping it, self-signing skipped"
        exit 0
    fi
fi

echo "$0: no usable certificate for $domain - regenerating self-signed"
rm -f "$crt" "$key"
openssl req -x509 -nodes -newkey rsa:2048 -days 825 -subj "/CN=$domain" \
    -keyout "$key" -out "$crt" \
    -addext "subjectAltName=DNS:$domain" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth"
chmod 600 "$key"
chmod 644 "$crt"
echo "$0: done: $crt / $key (self-signed; browsers will warn until you trust it)"

#!/bin/bash
#
# VPS 网络线路质量检测脚本
# 功能：延迟/丢包、路由跟踪、带宽测速、DNS解析速度
#
# 使用方法：
#   chmod +x check_network.sh
#   ./check_network.sh
#
# 可选依赖（脚本会自动尝试安装缺失工具，Debian/Ubuntu系）：
#   mtr-tiny, iperf3, dig(bind9-dnsutils)
#
# 带宽测速（iperf3）：本脚本会在本机（VPS）启动 iperf3 服务端并常驻后台，
# 由国内的另一台设备主动发起 iperf3 客户端连接来测速（反向路径更容易获得真实的国内测速节点）

set -uo pipefail

# ========== 配置区：按需修改测试目标 ==========
# 可以换成你更关心的地区节点，比如国内三大运营商测速点、目标国家的常用DNS等
PING_TARGETS=(
  "202.96.209.133:电信(上海)"
  "202.96.18.1:联通(北京)"
  "211.136.192.6:移动(北京)"
)

MTR_TARGET="202.96.209.133"   # 路由跟踪目标，可换成你的常用出口
PING_COUNT=20
OUTPUT_FILE="network_report_$(date +%Y%m%d_%H%M%S).txt"

# ICMP 不通时，用于判断是否只是 ICMP 被屏蔽（而非真实不可达）的 TCP 探测端口
TCP_CHECK_PORTS=(443 80)

# iperf3 服务端监听端口，需要在安全组/防火墙放行该端口（TCP，若测 UDP 还需放行 UDP）
IPERF3_PORT="${IPERF3_PORT:-5201}"

# ========== 工具函数 ==========
log() {
  echo -e "$1" | tee -a "$OUTPUT_FILE"
}

check_and_install() {
  local cmd="$1" pkg="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "[提示] 未检测到 $cmd，尝试安装 $pkg ..."
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update -qq >/dev/null 2>&1
      sudo apt-get install -y "$pkg" >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
      sudo yum install -y "$pkg" >/dev/null 2>&1
    fi
  fi
}

divider() {
  log "\n========================================"
  log "$1"
  log "========================================"
}

# ========== 公网 IP 获取与校验（多源 fallback，避免单一服务被拦截/返回异常内容污染结果） ==========
is_valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local i
  for i in 1 2 3 4; do
    (( ${BASH_REMATCH[$i]} <= 255 )) || return 1
  done
  return 0
}

is_valid_ipv6() {
  local ip="$1"
  [[ -n "$ip" && "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:]+$ ]]
}

fetch_public_ipv4() {
  local sources=("https://api.ipify.org" "https://ipinfo.io/ip" "https://icanhazip.com")
  local ip src
  for src in "${sources[@]}"; do
    ip=$(curl -fsS --max-time 6 "$src" 2>/dev/null | tr -d '[:space:]')
    if is_valid_ipv4 "$ip"; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

fetch_public_ipv6() {
  local sources=("https://api6.ipify.org" "https://v6.ident.me" "https://icanhazip.com")
  local ip src
  for src in "${sources[@]}"; do
    ip=$(curl -fsS -6 --max-time 6 "$src" 2>/dev/null | tr -d '[:space:]')
    if is_valid_ipv6 "$ip"; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

# ICMP 不通时用于判断"是否只是 ICMP 被墙"的纯 TCP 连接探测，不依赖额外工具
tcp_check() {
  local ip="$1" port="$2" timeout_s="${3:-3}"
  timeout "$timeout_s" bash -c "cat < /dev/null > /dev/tcp/${ip}/${port}" 2>/dev/null
}

# ========== 开始检测 ==========
> "$OUTPUT_FILE"
log "VPS 网络线路检测报告"
log "生成时间: $(date)"
log "主机名: $(hostname)"

# 1. 基本信息
divider "1. 公网出口 IP 与地理位置"
PUBLIC_IPV4=""
if command -v curl >/dev/null 2>&1; then
  IP_INFO=$(curl -fsS --max-time 5 https://ipinfo.io 2>/dev/null)
  if [ -n "$IP_INFO" ]; then
    echo "$IP_INFO" | tee -a "$OUTPUT_FILE"
    PARSED_IP=$(echo "$IP_INFO" | grep -oE '"ip": *"[^"]+"' | grep -oE '[0-9.]+')
    is_valid_ipv4 "$PARSED_IP" && PUBLIC_IPV4="$PARSED_IP"
  else
    log "[警告] 无法获取出口IP信息，请检查网络连通性"
  fi
  # ipinfo.io 解析失败时（例如被限流/内容异常），换源重新获取，供后续带宽测速展示复用
  if [ -z "$PUBLIC_IPV4" ]; then
    PUBLIC_IPV4=$(fetch_public_ipv4)
  fi
fi

# 2. 延迟与丢包测试
divider "2. 延迟与丢包测试 (ping x${PING_COUNT})"
for target in "${PING_TARGETS[@]}"; do
  IP="${target%%:*}"
  NAME="${target##*:}"
  log "\n--- 目标: $NAME ($IP) ---"
  PING_RESULT=$(ping -c "$PING_COUNT" -q "$IP" 2>&1)
  if [ $? -eq 0 ]; then
    echo "$PING_RESULT" | grep -E "packet loss|min/avg/max" | tee -a "$OUTPUT_FILE"
  else
    log "[失败] 无法 ping 通 $NAME ($IP)（ICMP 无响应）"
    TCP_OK_PORT=""
    for port in "${TCP_CHECK_PORTS[@]}"; do
      if tcp_check "$IP" "$port" 3; then
        TCP_OK_PORT="$port"
        break
      fi
    done
    if [ -n "$TCP_OK_PORT" ]; then
      log "[提示] TCP $TCP_OK_PORT 端口可达，说明该主机大概率只是屏蔽/限速了 ICMP，链路本身未必不可达"
    else
      log "[提示] TCP ${TCP_CHECK_PORTS[*]} 均不可达，更可能是链路本身不可达或目标全端口过滤"
    fi
  fi
done

# 3. 路由跟踪 (mtr，比 traceroute 更能体现丢包和延迟分布)
divider "3. 路由质量分析 (mtr -> $MTR_TARGET)"
check_and_install mtr mtr-tiny
if command -v mtr >/dev/null 2>&1; then
  mtr -r -c 20 --no-dns "$MTR_TARGET" 2>&1 | tee -a "$OUTPUT_FILE"
  log "[说明] 中间跳出现丢包/超时多为路由器对生成 ICMP 应答做了限速（保护控制面），与探测协议无关，换成 TCP 模式不会改变中间跳结果；只要终点(最后一跳)丢包率低即可视为链路正常。若终点本身 ICMP 不通，可用 'mtr -T -P <port>' 单独用 TCP 验证终点是否可达。"
else
  log "[跳过] mtr 未安装成功，改用 traceroute"
  if command -v traceroute >/dev/null 2>&1; then
    traceroute -n "$MTR_TARGET" 2>&1 | tee -a "$OUTPUT_FILE"
  fi
fi

# 4. DNS 解析速度
divider "4. DNS 解析速度测试"
check_and_install dig dnsutils
DNS_TEST_DOMAINS=(google.com github.com cloudflare.com)
CN_DNS_SERVERS=("114.114.114.114" "223.5.5.5" "119.29.29.29")
if command -v dig >/dev/null 2>&1; then
  log "-- 本地默认解析器（可能命中 systemd-resolved 等本地缓存，耗时仅供参考）--"
  for domain in "${DNS_TEST_DOMAINS[@]}"; do
    RESULT=$(dig +stats "$domain" 2>&1 | grep "Query time")
    log "$domain -> $RESULT"
  done
  log "\n-- 国内公共 DNS（直连 @server，绕过本地缓存，更接近真实递归耗时）--"
  for server in "${CN_DNS_SERVERS[@]}"; do
    for domain in "${DNS_TEST_DOMAINS[@]}"; do
      RESULT=$(dig +stats "@$server" "$domain" 2>&1 | grep "Query time")
      log "[$server] $domain -> $RESULT"
    done
  done
else
  log "[跳过] dig 未安装，无法测试 DNS 解析速度"
fi

# 5. 带宽测速 (iperf3 服务端，等待国内客户端连接测速)
divider "5. 带宽测速 (iperf3 服务端)"
check_and_install iperf3 iperf3
if command -v iperf3 >/dev/null 2>&1; then
  if pgrep -f "iperf3 -s" >/dev/null 2>&1; then
    log "[OK] iperf3 服务端已在运行"
  else
    iperf3 -s -D -p "$IPERF3_PORT" >/dev/null 2>&1
    sleep 1
    if pgrep -f "iperf3 -s" >/dev/null 2>&1; then
      log "[OK] 已启动 iperf3 服务端，监听端口 $IPERF3_PORT"
    else
      log "[失败] iperf3 服务端启动失败，请检查端口 $IPERF3_PORT 是否已被占用"
    fi
  fi
  log "请在国内的另一台设备上执行以下命令测速（需先确认云厂商安全组/本机防火墙已放行 TCP ${IPERF3_PORT}）:"
  log "  上行(国内 -> 本机): iperf3 -c ${PUBLIC_IPV4:-<本机公网IP>} -p $IPERF3_PORT"
  log "  下行(本机 -> 国内): iperf3 -c ${PUBLIC_IPV4:-<本机公网IP>} -p $IPERF3_PORT -R"
  log "[提示] 测速结果需要在国内设备一侧查看，本报告不包含自动测速结果"
else
  log "[跳过] iperf3 未安装成功。可手动运行: apt-get install -y iperf3 / yum install -y iperf3"
fi

# 6. 关键端口连通性检测（按需修改为你的代理端口）
divider "6. 本机监听端口检测"
if command -v ss >/dev/null 2>&1; then
  ss -tlnp 2>/dev/null | tee -a "$OUTPUT_FILE"
else
  netstat -tlnp 2>/dev/null | tee -a "$OUTPUT_FILE"
fi

# 7. CPU 加密性能 (AES-NI 支持情况，影响代理加解密吞吐上限)
divider "7. CPU 加密性能检测"
if grep -qm1 aes /proc/cpuinfo 2>/dev/null; then
  log "[OK] CPU 支持 AES-NI 硬件加速"
else
  log "[警告] 未检测到 AES-NI 支持，加密吞吐可能受限（多见于部分低价/共享核VPS）"
fi
if command -v openssl >/dev/null 2>&1; then
  log "\nopenssl 加密速度测试 (aes-256-gcm / chacha20-poly1305):"
  openssl speed -elapsed -evp aes-256-gcm 2>&1 | tail -5 | tee -a "$OUTPUT_FILE"
  openssl speed -elapsed -evp chacha20-poly1305 2>&1 | tail -5 | tee -a "$OUTPUT_FILE"
fi

# 8. TCP 拥塞控制算法 (BBR 在高延迟/跨国线路上通常明显优于默认 cubic)
divider "8. TCP 拥塞控制算法检测"
CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
AVAILABLE_CC=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
log "当前算法: $CURRENT_CC"
log "可用算法: $AVAILABLE_CC"
if echo "$AVAILABLE_CC" | grep -q bbr; then
  if [ "$CURRENT_CC" = "bbr" ]; then
    log "[OK] 已启用 BBR"
  else
    log "[提示] 系统支持 BBR 但未启用，可通过以下命令开启:"
    log "  echo 'net.ipv4.tcp_congestion_control=bbr' | sudo tee -a /etc/sysctl.conf && sudo sysctl -p"
  fi
else
  log "[提示] 当前内核不支持 BBR（需要内核 4.9+），如需启用请先升级内核"
fi

# 9. IPv6 支持情况
divider "9. IPv6 连通性检测"
if command -v curl >/dev/null 2>&1; then
  IPV6_ADDR=$(fetch_public_ipv6)
  if [ -n "$IPV6_ADDR" ]; then
    log "[OK] IPv6 出口可用: $IPV6_ADDR"
  else
    log "[信息] 未检测到可用 IPv6 出口（或被禁用/无地址；也可能是多个探测源都返回了非 IP 内容，如反爬虫验证页）"
  fi
fi

divider "检测完成"
log "完整报告已保存到: $OUTPUT_FILE"

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
#   mtr-tiny, speedtest-cli, dig(bind9-dnsutils)

set -uo pipefail

# ========== 配置区：按需修改测试目标 ==========
# 可以换成你更关心的地区节点，比如国内三大运营商测速点、目标国家的常用DNS等
PING_TARGETS=(
  "202.96.209.133:电信(上海)"
  "123.125.114.144:联通(北京)"
  "211.136.192.6:移动(北京)"
)

MTR_TARGET="202.96.209.133"   # 路由跟踪目标，可换成你的常用出口
MTR_TCP_PORT=443               # TCP 探测端口，避开 ICMP 限速/丢包干扰，可按需换成目标开放的端口
PING_COUNT=20
OUTPUT_FILE="network_report_$(date +%Y%m%d_%H%M%S).txt"

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

# ========== 开始检测 ==========
> "$OUTPUT_FILE"
log "VPS 网络线路检测报告"
log "生成时间: $(date)"
log "主机名: $(hostname)"

# 1. 基本信息
divider "1. 公网出口 IP 与地理位置"
if command -v curl >/dev/null 2>&1; then
  IP_INFO=$(curl -s --max-time 5 ipinfo.io 2>/dev/null)
  if [ -n "$IP_INFO" ]; then
    echo "$IP_INFO" | tee -a "$OUTPUT_FILE"
  else
    log "[警告] 无法获取出口IP信息，请检查网络连通性"
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
    log "[失败] 无法 ping 通 $NAME ($IP)"
  fi
done

# 3. 路由跟踪 (mtr，比 traceroute 更能体现丢包和延迟分布)
divider "3. 路由质量分析 (mtr --tcp -> $MTR_TARGET:$MTR_TCP_PORT)"
check_and_install mtr mtr-tiny
if command -v mtr >/dev/null 2>&1; then
  # --tcp 避免中间/末端路由器对 ICMP 限速导致的假性丢包，更接近真实业务层表现
  mtr -r -c 20 --no-dns --tcp -P "$MTR_TCP_PORT" "$MTR_TARGET" 2>&1 | tee -a "$OUTPUT_FILE"
else
  log "[跳过] mtr 未安装成功，改用 traceroute"
  if command -v traceroute >/dev/null 2>&1; then
    traceroute -n "$MTR_TARGET" 2>&1 | tee -a "$OUTPUT_FILE"
  fi
fi

# 4. DNS 解析速度
divider "4. DNS 解析速度测试"
check_and_install dig dnsutils
if command -v dig >/dev/null 2>&1; then
  for domain in google.com github.com cloudflare.com; do
    RESULT=$(dig +stats "$domain" 2>&1 | grep "Query time")
    log "$domain -> $RESULT"
  done
else
  log "[跳过] dig 未安装，无法测试 DNS 解析速度"
fi

# 5. 带宽测速 (指定中国大陆节点，而非默认就近节点)
divider "5. 带宽测速 (speedtest-cli -> 中国大陆节点)"
check_and_install speedtest-cli speedtest-cli
if command -v speedtest-cli >/dev/null 2>&1; then
  # speedtest-cli 默认自动选延迟最低的节点，不一定在中国大陆；
  # 这里从服务器列表里筛出国家码为 CN 的节点，强制指定测速目标
  CN_SERVER_LINE=$(speedtest-cli --list 2>/dev/null | grep -E ", CN\)" | head -n 1)
  CN_SERVER_ID=$(echo "$CN_SERVER_LINE" | awk -F')' '{print $1}' | tr -d ' ')
  if [ -n "$CN_SERVER_ID" ]; then
    log "选定中国大陆测速节点: $CN_SERVER_LINE"
    speedtest-cli --server "$CN_SERVER_ID" --simple 2>&1 | tee -a "$OUTPUT_FILE"
  else
    log "[警告] 服务器列表中未找到中国大陆 (CN) 节点，可能是该节点当前不对外开放测速"
    log "        改用默认最近节点测速（结果不代表到中国大陆的真实速度）:"
    speedtest-cli --simple 2>&1 | tee -a "$OUTPUT_FILE"
  fi
else
  log "[跳过] speedtest-cli 未安装成功。可手动运行:"
  log "  pip install speedtest-cli --break-system-packages && speedtest-cli --list | grep ', CN)'"
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
  IPV6_ADDR=$(curl -6 -s --max-time 5 https://ifconfig.co 2>/dev/null)
  if [ -n "$IPV6_ADDR" ]; then
    log "[OK] IPv6 出口可用: $IPV6_ADDR"
  else
    log "[信息] 未检测到可用 IPv6 出口（或被禁用/无地址）"
  fi
fi

# 10. IP 黑名单/信誉检测 (基于 Spamhaus ZEN 的公开 DNSBL 查询，无需 API Key)
divider "10. IP 黑名单信誉检测 (Spamhaus ZEN)"
check_and_install dig dnsutils
if command -v dig >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  MY_IP=$(curl -s --max-time 5 https://ifconfig.co 2>/dev/null)
  if [ -n "$MY_IP" ]; then
    REVERSED_IP=$(echo "$MY_IP" | awk -F. '{print $4"."$3"."$2"."$1}')
    BL_RESULT=$(dig +short "${REVERSED_IP}.zen.spamhaus.org" 2>&1)
    if [ -z "$BL_RESULT" ]; then
      log "[OK] $MY_IP 未在 Spamhaus ZEN 黑名单中"
    else
      log "[警告] $MY_IP 命中 Spamhaus ZEN 黑名单，返回码: $BL_RESULT"
      log "      （常见原因：该IP段历史上被用于垃圾邮件/滥用行为，可能影响出口访问某些服务的可信度）"
    fi
  else
    log "[跳过] 无法获取本机公网IP，跳过黑名单查询"
  fi
else
  log "[跳过] dig 或 curl 不可用，跳过黑名单查询"
fi

divider "检测完成"
log "完整报告已保存到: $OUTPUT_FILE"

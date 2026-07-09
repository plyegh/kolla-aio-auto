#!/usr/bin/env bash
# =========================================================
# 03-resources.sh
# Provider/Self-Service 네트워크, Router, SG Rule,
# CirrOS 이미지, Flavor, 인스턴스, Floating IP 자동 생성
# (문서의 3단계 + 네트워크 구성 문서 자동화)
# 멱등: 이미 존재하는 리소스는 건너뜀
# =========================================================

source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

require_root
activate_venv
load_openrc

exists() { openstack "$1" show "$2" >/dev/null 2>&1; }

# ---------- 사전 검증: physnet / br-ex ----------
log "ML2 flat_networks 확인"
FLAT=$(docker exec neutron_server cat /etc/neutron/plugins/ml2/ml2_conf.ini 2>/dev/null \
        | grep -A3 '\[ml2_type_flat\]' | grep 'flat_networks' | cut -d= -f2 | tr -d ' ' || true)
if [[ -n "${FLAT}" && "${FLAT}" != "${PROVIDER_PHYSNET}" ]]; then
  warn "ml2_conf.ini flat_networks=${FLAT} ≠ config.env의 ${PROVIDER_PHYSNET} → ${FLAT} 사용"
  PROVIDER_PHYSNET="${FLAT}"
fi

log "br-ex ↔ ${NEUTRON_EXTERNAL_INTERFACE} 연결 확인"
if ! docker exec openvswitch_vswitchd ovs-vsctl show | grep -q "${NEUTRON_EXTERNAL_INTERFACE}"; then
  warn "br-ex에 ${NEUTRON_EXTERNAL_INTERFACE} 가 안 보임. Floating IP 통신 안 될 수 있음."
fi

# ---------- Provider Network / Subnet ----------
if exists network provider; then
  log "provider 네트워크 이미 존재 (건너뜀)"
else
  log "provider 네트워크 생성"
  openstack network create \
    --external --share \
    --provider-network-type flat \
    --provider-physical-network "${PROVIDER_PHYSNET}" \
    provider
fi

if exists subnet provider; then
  log "provider 서브넷 이미 존재 (건너뜀)"
else
  log "provider 서브넷 생성 (${PROVIDER_CIDR})"
  openstack subnet create --network provider \
    --allocation-pool "start=${PROVIDER_POOL_START},end=${PROVIDER_POOL_END}" \
    --dns-nameserver "${PROVIDER_DNS}" \
    --gateway "${PROVIDER_GATEWAY}" \
    --subnet-range "${PROVIDER_CIDR}" \
    provider
fi

# ---------- Self-Service Network / Subnet ----------
if exists network selfservice; then
  log "selfservice 네트워크 이미 존재 (건너뜀)"
else
  log "selfservice 네트워크 생성"
  openstack network create selfservice
fi

if exists subnet selfservice; then
  log "selfservice 서브넷 이미 존재 (건너뜀)"
else
  log "selfservice 서브넷 생성 (${SELFSERVICE_CIDR})"
  openstack subnet create --network selfservice \
    --dns-nameserver "${SELFSERVICE_DNS}" \
    --gateway "${SELFSERVICE_GATEWAY}" \
    --subnet-range "${SELFSERVICE_CIDR}" \
    selfservice
fi

# ---------- Router ----------
if exists router router; then
  log "router 이미 존재 (건너뜀)"
else
  log "router 생성 및 연결"
  openstack router create router
  openstack router add subnet router selfservice
  openstack router set router --external-gateway provider
fi

# ---------- Security Group Rule (default에 ICMP/SSH 허용) ----------
log "default SG에 ICMP/SSH ingress 허용 (CSPM 탐지 테스트용 취약 설정)"
openstack security group rule create default \
  --ingress --ethertype IPv4 --protocol icmp --remote-ip 0.0.0.0/0 2>/dev/null \
  || log "  ICMP rule 이미 존재"
openstack security group rule create default \
  --ingress --ethertype IPv4 --protocol tcp --dst-port 22 --remote-ip 0.0.0.0/0 2>/dev/null \
  || log "  SSH rule 이미 존재"

# ---------- CirrOS 이미지 ----------
IMG_NAME="cirros-${CIRROS_VERSION}"
if exists image "${IMG_NAME}"; then
  log "${IMG_NAME} 이미지 이미 존재 (건너뜀)"
else
  log "CirrOS 이미지 다운로드 및 등록"
  wget -q -O "/tmp/${IMG_NAME}-x86_64-disk.img" "${CIRROS_URL}"
  openstack image create "${IMG_NAME}" \
    --file "/tmp/${IMG_NAME}-x86_64-disk.img" \
    --disk-format qcow2 \
    --container-format bare \
    --public
fi

# ---------- Flavor ----------
openstack flavor show m1.tiny >/dev/null 2>&1 \
  || openstack flavor create m1.tiny --ram 512 --disk 1 --vcpus 1

# ---------- CirrOS 인스턴스 ----------
if exists server cirros-test; then
  log "cirros-test 인스턴스 이미 존재 (건너뜀)"
else
  log "cirros-test 인스턴스 생성"
  openstack server create cirros-test \
    --image "${IMG_NAME}" \
    --flavor m1.tiny \
    --network selfservice \
    --security-group default
fi

log "ACTIVE 대기 (최대 5분)"
for i in $(seq 1 60); do
  STATUS=$(openstack server show cirros-test -f value -c status)
  [[ "${STATUS}" == "ACTIVE" ]] && break
  [[ "${STATUS}" == "ERROR"  ]] && die "인스턴스 ERROR: openstack server show cirros-test -c fault 확인"
  sleep 5
done
[[ "${STATUS:-}" == "ACTIVE" ]] || die "인스턴스가 ACTIVE 되지 않음 (현재: ${STATUS:-unknown})"
log "인스턴스 ACTIVE"

# ---------- Floating IP ----------
FIP=$(openstack server show cirros-test -f value -c addresses \
      | grep -oE "${PROVIDER_CIDR%.*}\.[0-9]+" | head -1 || true)
if [[ -n "${FIP}" ]]; then
  log "Floating IP 이미 연결됨: ${FIP} (건너뜀)"
else
  log "Floating IP 생성 및 연결"
  FIP=$(openstack floating ip create provider -f value -c floating_ip_address)
  openstack server add floating ip cirros-test "${FIP}"
fi

# ---------- qrouter 외부 통신 확인 ----------
QR=$(ip netns | awk '/qrouter/{print $1; exit}' || true)
if [[ -n "${QR}" ]]; then
  log "qrouter → Provider GW ping 테스트"
  ip netns exec "${QR}" ping -c 2 -W 2 "${PROVIDER_GATEWAY}" >/dev/null 2>&1 \
    && log "  Provider GW(${PROVIDER_GATEWAY}) OK" \
    || warn "  Provider GW ping 실패. ens37/VMware 네트워크 확인 필요"
  ip netns exec "${QR}" ping -c 2 -W 2 8.8.8.8 >/dev/null 2>&1 \
    && log "  외부 인터넷(8.8.8.8) OK" \
    || warn "  외부 인터넷 ping 실패"
fi

# ---------- 최종 요약 ----------
log "=============================================="
log "3단계 완료. 최종 리소스 상태:"
openstack server list
openstack floating ip list
log ""
log "SSH 테스트:  ssh cirros@${FIP}   (PW: gocubsgo)"
log "CSPM 탐지 대상: SG-001, SG-ICMP-001, FIP-002, RTR-001, NET-001, VM-001, EXP-001"
log "=============================================="

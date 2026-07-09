#!/usr/bin/env bash
# 공통 함수 및 설정 로드 (직접 실행하는 파일 아님)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "${REPO_ROOT}/config.env"

# ---------- 출력 헬퍼 ----------
log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
die()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }

# ---------- 사전 검증 ----------
require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "root로 실행하세요:  sudo -i 후 다시 실행"
}

require_ubuntu_2404() {
  # 24.04가 아니어도 진행은 가능하지만 경고
  if ! grep -q 'Ubuntu 24.04' /etc/os-release 2>/dev/null; then
    warn "Ubuntu 24.04 LTS가 아닙니다. 계속 진행하지만 문제가 생길 수 있음."
  fi
}

check_nics() {
  ip link show "${NETWORK_INTERFACE}" >/dev/null 2>&1 \
    || die "관리망 인터페이스 ${NETWORK_INTERFACE} 없음. config.env 수정 필요 (ip -br a 로 확인)"
  ip link show "${NEUTRON_EXTERNAL_INTERFACE}" >/dev/null 2>&1 \
    || die "외부망 인터페이스 ${NEUTRON_EXTERNAL_INTERFACE} 없음. config.env 수정 필요"

  # 관리망: IPv4 있어야 함
  if ! ip -4 -br addr show "${NETWORK_INTERFACE}" | grep -q '[0-9]\+\.[0-9]\+'; then
    die "${NETWORK_INTERFACE} 에 IPv4 주소가 없음. netplan 설정 먼저 완료하세요."
  fi
  # 외부망: IPv4 없어야 함
  if ip -4 -br addr show "${NEUTRON_EXTERNAL_INTERFACE}" | grep -q '[0-9]\+\.[0-9]\+'; then
    die "${NEUTRON_EXTERNAL_INTERFACE} 에 IPv4가 있으면 안 됨. netplan에서 dhcp4: false 확인."
  fi
  log "NIC 검증 통과: ${NETWORK_INTERFACE}(관리망) / ${NEUTRON_EXTERNAL_INTERFACE}(외부망)"
}

detect_virt_type() {
  # KVM 가능 여부 자동 판단
  local count
  count=$(egrep -c '(vmx|svm)' /proc/cpuinfo || true)
  if [[ "${count}" -ge 1 && -e /dev/kvm ]]; then
    echo "kvm"
  else
    echo "qemu"
  fi
}

activate_venv() {
  [[ -f "${VENV_DIR}/bin/activate" ]] || die "venv 없음. 01-prepare.sh 먼저 실행"
  # shellcheck disable=SC1091
  source "${VENV_DIR}/bin/activate"
}

load_openrc() {
  [[ -f /etc/kolla/admin-openrc.sh ]] || die "/etc/kolla/admin-openrc.sh 없음. post-deploy까지 완료했는지 확인"
  # shellcheck disable=SC1091
  source /etc/kolla/admin-openrc.sh
}

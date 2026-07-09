#!/usr/bin/env bash
# =========================================================
# 01-prepare.sh
# 패키지 설치 → venv → kolla-ansible 설치 → /etc/kolla 구성
# → 비밀번호 생성 → globals.yml 작성 → bootstrap → prechecks
# (문서의 1단계 전체 자동화)
# =========================================================

source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

require_root
require_ubuntu_2404
check_nics

# ---------- 1-1. 패키지 업데이트 ----------
log "apt 업데이트 및 기본 패키지 설치"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y \
  net-tools git curl wget tmux \
  python3-dev python3-venv libffi-dev gcc libssl-dev \
  libdbus-glib-1-dev libdbus-1-dev libglib2.0-dev pkg-config build-essential

# ---------- 1-4. Python venv ----------
if [[ ! -f "${VENV_DIR}/bin/activate" ]]; then
  log "Python 가상환경 생성: ${VENV_DIR}"
  python3 -m venv "${VENV_DIR}"
else
  log "기존 venv 재사용: ${VENV_DIR}"
fi
# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"

pip install -U pip
pip install docker dbus-python

# ---------- 1-5. Kolla-Ansible 설치 ----------
if ! command -v kolla-ansible >/dev/null 2>&1; then
  log "Kolla-Ansible 설치 (branch: ${KOLLA_ANSIBLE_BRANCH})"
  pip install "git+https://opendev.org/openstack/kolla-ansible@${KOLLA_ANSIBLE_BRANCH}"
else
  log "Kolla-Ansible 이미 설치됨: $(kolla-ansible --version 2>/dev/null | head -1)"
fi
kolla-ansible --version

# ---------- 1-6. /etc/kolla 준비 ----------
log "/etc/kolla 설정 파일 준비"
mkdir -p /etc/kolla
chown "$USER:$USER" /etc/kolla
cp -rn "${VENV_DIR}/share/kolla-ansible/etc_examples/kolla/." /etc/kolla/
cp -n  "${VENV_DIR}/share/kolla-ansible/ansible/inventory/all-in-one" "${INVENTORY}" || true

[[ -f /etc/kolla/globals.yml ]]   || die "/etc/kolla/globals.yml 복사 실패"
[[ -f "${INVENTORY}" ]]           || die "all-in-one 인벤토리 복사 실패"

# ---------- 1-7. Ansible Galaxy 의존성 ----------
log "kolla-ansible install-deps"
kolla-ansible install-deps

# ---------- 1-8. KVM 판단 ----------
VIRT_TYPE="$(detect_virt_type)"
if [[ "${VIRT_TYPE}" == "kvm" ]]; then
  log "KVM 사용 가능 → nova_compute_virt_type: kvm"
else
  warn "KVM 사용 불가 → qemu로 자동 전환 (VMware에서 VT-x/EPT 가상화 체크 여부 확인)"
fi

# ---------- 1-9. 비밀번호 생성 ----------
if grep -q "keystone_admin_password: .\+" /etc/kolla/passwords.yml 2>/dev/null; then
  log "passwords.yml 이미 생성됨 (건너뜀)"
else
  log "kolla-genpwd 실행"
  kolla-genpwd
fi

# ---------- 1-10. globals.yml 작성 (멱등) ----------
MARKER="# === APS-CSPM-AUTO BEGIN ==="
if grep -q "${MARKER}" /etc/kolla/globals.yml; then
  log "globals.yml에 기존 자동 설정 블록 존재 → 갱신"
  sed -i "/# === APS-CSPM-AUTO BEGIN ===/,/# === APS-CSPM-AUTO END ===/d" /etc/kolla/globals.yml
fi

log "globals.yml에 설정 블록 추가"
cat >> /etc/kolla/globals.yml <<EOF
${MARKER}
kolla_base_distro: "${KOLLA_BASE_DISTRO}"
network_interface: "${NETWORK_INTERFACE}"
neutron_external_interface: "${NEUTRON_EXTERNAL_INTERFACE}"
kolla_internal_vip_address: "${KOLLA_INTERNAL_VIP}"
enable_horizon: "${ENABLE_HORIZON}"
enable_cinder: "${ENABLE_CINDER}"
nova_compute_virt_type: "${VIRT_TYPE}"
# === APS-CSPM-AUTO END ===
EOF

log "YAML 문법 검증"
python3 -c 'import yaml; yaml.safe_load(open("/etc/kolla/globals.yml")); print("YAML OK")'

# ---------- 1-11. Bootstrap & Prechecks ----------
log "bootstrap-servers 실행"
kolla-ansible bootstrap-servers -i "${INVENTORY}"

log "prechecks 실행"
kolla-ansible prechecks -i "${INVENTORY}" --use-test-images

log "=============================================="
log "1단계 완료. 다음 단계:"
log "  tmux new -s kolla"
log "  bash scripts/02-deploy.sh"
log "=============================================="

#!/usr/bin/env bash
# =========================================================
# 02-deploy.sh
# deploy → 컨테이너 확인 → post-deploy → OpenStack CLI 설치
# → 인증 테스트 → 기본 상태 점검
# (문서의 2단계 전체 자동화, 10~50분 소요)
# =========================================================

source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

require_root
activate_venv

# tmux 밖에서 실행 시 경고 (SSH 끊기면 배포 중단됨)
if [[ -z "${TMUX:-}" ]]; then
  warn "tmux 세션 밖에서 실행 중입니다. SSH가 끊기면 배포가 중단됩니다."
  warn "권장:  tmux new -s kolla  후 재실행 (5초 후 계속 진행)"
  sleep 5
fi

# ---------- 2-2. Deploy ----------
log "kolla-ansible deploy 시작 (--use-test-images 사용 안 함)"
kolla-ansible deploy -i "${INVENTORY}"

# ---------- 2-3. 컨테이너 확인 ----------
log "Docker 컨테이너 상태:"
docker ps --format "table {{.Names}}\t{{.Status}}"

UNHEALTHY=$(docker ps --format '{{.Names}} {{.Status}}' | grep -c 'unhealthy' || true)
if [[ "${UNHEALTHY}" -gt 0 ]]; then
  warn "unhealthy 컨테이너 ${UNHEALTHY}개 발견. 잠시 기다린 뒤 다시 확인하세요."
fi

# ---------- 2-5. post-deploy ----------
log "post-deploy 실행"
kolla-ansible post-deploy -i "${INVENTORY}"

[[ -f /etc/kolla/clouds.yaml ]]       || die "clouds.yaml 생성 실패"
[[ -f /etc/kolla/admin-openrc.sh ]]   || die "admin-openrc.sh 생성 실패"

# ---------- 2-6. OpenStack CLI ----------
log "python-openstackclient 설치"
pip install python-openstackclient -c "https://releases.openstack.org/constraints/upper/${KOLLA_ANSIBLE_BRANCH##*/}" \
  || pip install python-openstackclient

# ---------- 2-7. 인증 테스트 ----------
load_openrc
log "인증 테스트: openstack service list"
openstack service list

# ---------- 2-8. 기본 상태 점검 ----------
log "OpenStack 기본 상태 점검"
openstack endpoint list
openstack hypervisor list
openstack network agent list
openstack compute service list

# ---------- Horizon 확인 ----------
log "Horizon 응답 확인 (http://${KOLLA_INTERNAL_VIP})"
if curl -sI "http://${KOLLA_INTERNAL_VIP}" | head -1 | grep -qE '30[12]|200'; then
  log "Horizon 정상 응답"
else
  warn "Horizon 응답 없음. 잠시 후 curl -I http://${KOLLA_INTERNAL_VIP} 로 재확인"
fi

ADMIN_PW=$(grep OS_PASSWORD /etc/kolla/admin-openrc.sh | cut -d"'" -f2 || true)
log "=============================================="
log "2단계 완료!"
log "  Horizon: http://${KOLLA_INTERNAL_VIP}"
log "  Domain : Default"
log "  User   : admin"
log "  PW     : ${ADMIN_PW}"
log ""
log "다음 단계(실습 리소스 자동 생성):"
log "  bash scripts/03-resources.sh"
log "=============================================="

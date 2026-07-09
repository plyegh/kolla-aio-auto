#!/usr/bin/env bash
# =========================================================
# setup.sh — 전체 자동 실행 (1단계 + 2단계)
#
# 전제조건 (직접 완료해야 함):
#   1. Ubuntu Server 24.04 LTS 설치
#   2. NIC 2개 netplan 설정 완료
#      - 관리망: 고정 IP 있음
#      - 외부망: IP 없음 (dhcp4/6: false)
#   3. config.env 를 환경에 맞게 수정
#
# 사용법:
#   sudo -i
#   git clone <repo> && cd kolla-aio-auto
#   vi config.env          # 환경에 맞게 수정
#   tmux new -s kolla      # 필수 권장 (deploy 오래 걸림)
#   bash setup.sh
#
# 완료 후 실습 리소스까지 만들려면:
#   bash scripts/03-resources.sh
# =========================================================

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "${DIR}/scripts/01-prepare.sh"
bash "${DIR}/scripts/02-deploy.sh"

echo ""
echo "[+] 전체 배포 완료. 실습 리소스 생성은:"
echo "    bash ${DIR}/scripts/03-resources.sh"

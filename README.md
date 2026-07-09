# Kolla-Ansible All-in-One 자동 구축

Ubuntu Server 24.04 LTS 환경에서 Kolla-Ansible 기반 OpenStack All-in-One을 자동으로 배포하는 스크립트 모음입니다. `git clone` 후 `config.env`만 수정하고 실행하면 배포부터 인스턴스 생성까지 자동으로 진행됩니다.

## 사전 조건 (직접 해야 하는 것)

1. Ubuntu Server 24.04 LTS 설치 (VMware 또는 실서버)
   - 권장 사양: 6 vCPU / 8GB RAM / 100GB 디스크 / NIC 2개
   - VMware라면 `Virtualize Intel VT-x/EPT or AMD-V/RVI` 체크
2. netplan으로 NIC 2개 설정 완료
   - 관리망 NIC: 고정 IP (예: `10.0.0.11/24`)
   - 외부망 NIC: IP 없음 (`dhcp4: false`, `dhcp6: false`, `optional: true`)
3. SSH 접속 가능 상태

## 사용법

```bash
sudo -i
git clone https://github.com/plyegh/kolla-aio-auto.git
cd kolla-aio-auto

# 환경에 맞게 수정 (NIC 이름, VIP, Provider 대역 등)
vi config.env

# deploy는 10~50분 걸리므로 tmux 필수 권장
apt install -y tmux
tmux new -s kolla

# 1단계 + 2단계 전체 실행
bash setup.sh
```

배포가 끝나면 마지막에 Horizon 주소와 admin 비밀번호가 출력됩니다.

실습용 리소스(네트워크, 라우터, CirrOS 인스턴스, Floating IP, 취약 SG 룰)까지 만들려면:

```bash
bash scripts/03-resources.sh
```

## 구성

| 파일 | 역할 |
|---|---|
| `config.env` | 모든 환경 설정 (NIC, VIP, 네트워크 대역 등) — **이 파일만 수정하면 됨** |
| `setup.sh` | 1단계 + 2단계 전체 실행 |
| `scripts/01-prepare.sh` | 패키지 설치, venv, kolla-ansible 설치, `/etc/kolla` 구성, `kolla-genpwd`, `globals.yml` 작성, bootstrap-servers, prechecks |
| `scripts/02-deploy.sh` | deploy, 컨테이너 확인, post-deploy, OpenStack CLI 설치, 인증 테스트, Horizon 확인 |
| `scripts/03-resources.sh` | Provider/Self-Service 네트워크, Router, SG 룰, CirrOS 이미지·인스턴스, Floating IP 자동 생성 |
| `scripts/00-common.sh` | 공통 함수 (직접 실행 X) |

## 주요 자동화 포인트

- NIC 검증: 관리망에 IP 있는지, 외부망에 IP 없는지 자동 확인 후 진행
- KVM 자동 감지: `/dev/kvm` 존재 여부에 따라 `nova_compute_virt_type`을 `kvm`/`qemu` 자동 설정
- `globals.yml` 멱등 처리: 마커 블록(`AUTO`) 기반으로 재실행해도 중복 없이 갱신
- physnet 자동 확인: `ml2_conf.ini`의 `flat_networks` 값을 읽어 Provider Network 생성에 사용
- 리소스 멱등 생성: 이미 존재하는 네트워크/인스턴스는 건너뛰므로 재실행 안전
- prechecks에는 `--use-test-images` 사용, deploy에는 미사용 (문서 규칙 유지)

## 재부팅 후 점검

```bash
source ~/kolla-venv/bin/activate
source /etc/kolla/admin-openrc.sh
ip -br a | egrep 'ens33|ens37|br-ex'
docker exec -it openvswitch_vswitchd ovs-vsctl show
openstack server list
openstack floating ip list
```

## 트러블슈팅

- `prechecks` 실패 → NIC 설정과 `config.env`의 인터페이스 이름 확인 (`ip -br a`)
- KVM이 qemu로 잡힘 → VMware 설정에서 VT-x/EPT 체크, Windows Hyper-V/VBS/Memory Integrity 끄기
- Floating IP 통신 안 됨 → `docker exec -it openvswitch_vswitchd ovs-vsctl show`에서 br-ex에 외부망 NIC가 붙어 있는지 확인
- 인스턴스 ERROR → `openstack server show cirros-test -c fault`

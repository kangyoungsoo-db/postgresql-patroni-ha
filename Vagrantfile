# -*- mode: ruby -*-
# PostgreSQL 17 실습 환경
#   data-db1  : PostgreSQL + Patroni + etcd + PgBouncer + pgBackRest + exporter
#   data-db2  : PostgreSQL + Patroni + etcd + PgBouncer + pgBackRest + exporter
#   data-mgmt : etcd + MinIO + Prometheus + Grafana
#
# 사용 전에 PowerShell 창마다 아래를 먼저 입력한다.
#   $env:VAGRANT_HOME = "D:\data-lab\.vagrant_home"
#
# 모든 provision 은 run: "never" 이다. README 순서대로 --provision-with 로 하나씩 실행한다.

# ===== 여기 숫자만 바꾸면 된다 =====
BOX          = "bento/rockylinux-10.1"
BOX_VERSION  = "202512.01.0"
DATA_DISK_GB = 50                                  # 데이터 디스크 크기 (동적 할당)
DISK_DIR     = File.join(__dir__, ".disks")        # D:\data-lab\.disks
DISK_CTL     = "VirtIO Controller"                 # box 의 스토리지 컨트롤러 이름 (box.ovf 에서 확인)
DISK_PORT    = 1                                   # OS 디스크는 포트 0, 데이터 디스크는 포트 1

NODES = [
  { name: "data-db1",  ip: "192.168.56.11", cpus: 2, memory: 3072, role: "db"   },  # Patroni 노드
  { name: "data-db2",  ip: "192.168.56.12", cpus: 2, memory: 3072, role: "db"   },  # Patroni 노드
  { name: "data-mgmt", ip: "192.168.56.13", cpus: 2, memory: 2048, role: "mgmt" },  # etcd 3번, MinIO, 모니터링
]

# 스크립트별 실행 대상 (role)
SCRIPTS = {
  "01_base"       => %w[db mgmt],
  "02_pg17"       => %w[db],
  "05_secrets"    => %w[db mgmt],
  "06_etcd"       => %w[db mgmt],
  "07_patroni"    => %w[db],
  "08_pgbouncer"  => %w[db],
  "09_minio"      => %w[mgmt],
  "10_pgbackrest" => %w[db],
  "11_exporters"  => %w[db],
  "12_monitoring" => %w[mgmt],
}
# ===================================

# 데이터 디스크 폴더가 없으면 만든다 (이미 있으면 아무것도 하지 않음)
require "fileutils"
FileUtils.mkdir_p(DISK_DIR)

Vagrant.configure("2") do |config|
  config.vm.box               = BOX
  config.vm.box_version       = BOX_VERSION
  config.vm.box_check_update  = false
  config.vm.box_architecture  = "amd64"   # 32비트 Vagrant 가 호스트를 i386 으로 잘못 인식하므로 명시한다
  config.vm.boot_timeout      = 600       # 첫 부팅이 느릴 때를 대비한다

  # 공유 폴더는 쓰지 않는다 (Guest Additions 의존을 없애기 위함)
  config.vm.synced_folder ".", "/vagrant", disabled: true

  NODES.each do |node|
    config.vm.define node[:name] do |m|
      m.vm.hostname = node[:name]
      m.vm.network "private_network", ip: node[:ip]   # 기존 192.168.56.1 Host-Only 어댑터를 같이 쓴다

      m.vm.provider "virtualbox" do |vb|
        vb.name   = node[:name]
        vb.cpus   = node[:cpus]
        vb.memory = node[:memory]
        vb.destroy_unused_network_interfaces = false  # destroy 때 Host-Only 어댑터를 지우지 않는다

        # 데이터 디스크: 파일이 없을 때만 만들고 연결한다
        disk = File.join(DISK_DIR, "#{node[:name]}-pgdata.vdi")
        unless File.exist?(disk)
          vb.customize ["createmedium", "disk", "--filename", disk,
                        "--format", "VDI", "--size", DATA_DISK_GB * 1024]
          vb.customize ["storageattach", :id, "--storagectl", DISK_CTL,
                        "--port", DISK_PORT, "--device", 0,
                        "--type", "hdd", "--medium", disk]
        end
      end

      # 00: 스크립트 복사 (VM 안 /home/vagrant/lab-scripts)
      m.vm.provision "00_copy", type: "file", run: "never",
        source: "scripts", destination: "/home/vagrant/lab-scripts"
      # 00: 비밀값 복사 (05_secrets 가 /etc/lab-secrets 로 옮기고 원본을 지운다)
      m.vm.provision "00_secrets", type: "file", run: "never",
        source: ".secrets", destination: "/home/vagrant/lab-secrets"

      SCRIPTS.each do |script, roles|
        next unless roles.include?(node[:role])
        m.vm.provision script, type: "shell", run: "never", path: "scripts/#{script}.sh"
      end

      # 03 은 비밀번호 입력이 필요할 수 있어 VM 안에서 직접 실행한다. README 참고.
      if node[:name] == "data-db1"
        m.vm.provision "04_sample", type: "shell", run: "never", path: "scripts/04_sample.sh"
      end
    end
  end
end

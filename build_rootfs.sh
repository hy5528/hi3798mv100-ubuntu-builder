#!/bin/bash
set -euo pipefail

# ==================== 可配置参数（支持环境变量覆盖）====================
# 原始镜像下载链接（你的固定地址）
ORIG_IMG_URL="https://github.com/hongli11/hi3798mv100-ubuntu-builder/releases/download/v1.0/rootfs-32-fixed.img"
# Ubuntu基础镜像（armhf架构20.04）
UBUNTU_BASE_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/20.04/release/ubuntu-base-20.04.5-base-armhf.tar.gz"
# 软件源
MIRROR="mirrors.tuna.tsinghua.edu.cn/ubuntu-ports"
# 系统配置（优先读取环境变量，无则用默认值）
HOSTNAME="${HOSTNAME:-hi3798mv100}"
ROOT_PASSWORD="${ROOT_PASSWORD:-123456}"  # 建议通过GitHub Secrets设置
NETWORK_MODE="${NETWORK_MODE:-DHCP}"
# 静态IP配置（仅NETWORK_MODE=STATIC生效）
STATIC_IP="${STATIC_IP:-192.168.1.10}"
NETMASK="${NETMASK:-255.255.255.0}"
GATEWAY="${GATEWAY:-192.168.1.1}"
DNS="${DNS:-223.5.5.5 223.6.6.6}"
MAC_DHCP="${MAC_DHCP:-10:10:10:10:10:10}"
MAC_STATIC="${MAC_STATIC:-10:10:10:10:10:20}"

# ==================== 核心流程 ====================
echo -e "\033[1;34m=== Hi3798MV100 Ubuntu 20.04 自动化构建 ===\033[0m"

# 1. 安装依赖
echo -e "\n[1/6] 安装构建依赖..."
sudo apt update -qq
sudo apt install -y -qq qemu-user-static rsync gzip wget > /dev/null 2>&1

# 2. 下载原始镜像（从你的GitHub Release）
echo -e "[2/6] 下载原始镜像 rootfs-32-fixed.img..."
wget -q --show-progress -O rootfs-32.img "$ORIG_IMG_URL"
if [ ! -f "rootfs-32.img" ]; then
    echo -e "\033[1;31m错误：原始镜像下载失败！\033[0m"
    exit 1
fi

# 3. 准备Ubuntu基础根文件系统
echo -e "[3/6] 下载并解压Ubuntu基础系统..."
mkdir -p ubuntu-rootfs-temp
wget -q --show-progress -O ubuntu-base.tar.gz "$UBUNTU_BASE_URL"
sudo tar -xpf ubuntu-base.tar.gz -C ubuntu-rootfs-temp > /dev/null 2>&1
rm -f ubuntu-base.tar.gz

# 4. 配置Chroot环境
echo -e "[4/6] 配置Chroot构建环境..."
sudo cp /usr/bin/qemu-arm-static ubuntu-rootfs-temp/usr/bin/
sudo cp /etc/resolv.conf ubuntu-rootfs-temp/etc/resolv.conf

# 挂载系统目录
sudo mount -t proc /proc ubuntu-rootfs-temp/proc
sudo mount -t sysfs /sys ubuntu-rootfs-temp/sys
sudo mount -o bind /dev ubuntu-rootfs-temp/dev
sudo mount -o bind /dev/pts ubuntu-rootfs-temp/dev/pts

# 5. Chroot内定制系统
echo -e "[5/6] 定制Ubuntu系统（Chroot环境）..."
sudo chroot ubuntu-rootfs-temp /bin/bash -c "
    # 配置软件源
    cat > /etc/apt/sources.list << EOF
deb http://$MIRROR/ focal main restricted universe multiverse
deb http://$MIRROR/ focal-updates main restricted universe multiverse
deb http://$MIRROR/ focal-security main restricted universe multiverse
deb http://$MIRROR/ focal-backports main restricted universe multiverse
EOF

    # 系统更新与软件安装
    apt update -qq
    apt upgrade -y -qq > /dev/null 2>&1
    apt install -y -qq systemd rsyslog sudo vim bash-completion ssh net-tools ethtool ifupdown network-manager iputils-ping wget curl htop > /dev/null 2>&1

    # 网络配置
    if [ \"$NETWORK_MODE\" = 'STATIC' ]; then
        cat > /etc/network/interfaces.d/eth0 << EOF
auto eth0
iface eth0 inet static
address $STATIC_IP
netmask $NETMASK
gateway $GATEWAY
dns-nameservers $DNS
pre-up ifconfig eth0 hw ether $MAC_STATIC
EOF
    else
        cat > /etc/network/interfaces.d/eth0 << EOF
auto eth0
iface eth0 inet dhcp
pre-up ifconfig eth0 hw ether $MAC_DHCP
EOF
    fi

    # 主机名/hosts配置
    echo \"$HOSTNAME\" > /etc/hostname
    echo -e '127.0.0.1 localhost\n127.0.0.1 $HOSTNAME' > /etc/hosts

    # Root密码配置
    echo "root:$ROOT_PASSWORD" | chpasswd

    # SSH配置（允许root登录）
    echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
    systemctl enable ssh > /dev/null 2>&1

    # 禁用无用服务
    systemctl disable motd-news.timer networkd-dispatcher > /dev/null 2>&1

    # 自动扩展分区服务
    cat > /etc/systemd/system/rc-local.service << EOF
[Unit]
Description=/etc/rc.local Compatibility
ConditionPathExists=/etc/rc.local

[Service]
Type=forking
ExecStart=/etc/rc.local start
TimeoutSec=0
StandardOutput=tty
RemainAfterExit=yes
SysVStartPriority=99

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/rc.local << EOF
#!/bin/bash
if [ -f /firstboot ]; then
    resize2fs /dev/mmcblk0p9
    rm -f /firstboot
fi
exit 0
EOF
    chmod +x /etc/rc.local
    systemctl enable rc-local > /dev/null 2>&1

    # 清理缓存
    apt clean
    rm -rf /var/lib/apt/lists/*
"

# 6. 卸载挂载点 & 写入镜像
echo -e "[6/6] 写入定制系统到原始镜像..."
sudo umount -l ubuntu-rootfs-temp/dev/pts
sudo umount -l ubuntu-rootfs-temp/dev
sudo umount -l ubuntu-rootfs-temp/sys
sudo umount -l ubuntu-rootfs-temp/proc

# 挂载原始镜像并同步定制系统
mkdir -p /mnt/rootfs
sudo mount rootfs-32.img /mnt/rootfs
sudo rm -rf /mnt/rootfs/*
sudo rsync -a --delete ubuntu-rootfs-temp/ /mnt/rootfs/
sudo touch /mnt/rootfs/firstboot  # 首次启动标记
sudo umount /mnt/rootfs

# 清理临时文件
sudo rm -rf ubuntu-rootfs-temp

# 产物重命名（添加时间戳+Commit哈希）
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
COMMIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
FINAL_IMG="hi3798mv100-ubuntu-${TIMESTAMP}-${COMMIT_HASH}.img"
FINAL_GZ="hi3798mv100-ubuntu-backup-${TIMESTAMP}-${COMMIT_HASH}.gz"
mv rootfs-32.img "$FINAL_IMG"
gzip -9 -k -c "$FINAL_IMG" > "$FINAL_GZ"

# 构建完成提示
echo -e "\n\033[1;32m=== 构建成功！ ===\033[0m"
echo -e "✅ 定制镜像：$(pwd)/$FINAL_IMG"
echo -e "✅ 压缩备份：$(pwd)/$FINAL_GZ"
echo -e "\033[1;33m⚠️  注意：Root默认密码为 $ROOT_PASSWORD，请登录后立即修改！\033[0m"

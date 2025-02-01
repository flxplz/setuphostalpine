#!/bin/sh

### 🚀 Configuración automática del sistema host en Alpine Linux
echo "🚀 Iniciando configuración del sistema host..."

## 🛠️ Actualizar repositorios e instalar paquetes esenciales
apk update
apk add qemu-system-x86_64 qemu-img libvirt bridge-utils dnsmasq openssh iptables bash nano curl wget expect

## 🖧 Configurar la red con bridge br0
echo "🌐 Configurando la red y el bridge br0..."
cat <<EOF > /etc/network/interfaces
auto lo
iface lo inet loopback

# Interfaz física conectada a Internet
auto eth0
iface eth0 inet dhcp

# Switch virtual para la VM
auto br0
iface br0 inet static
    address 192.168.100.1
    netmask 255.255.255.0
    bridge_ports none
    bridge_stp off
    bridge_fd 0
EOF

service networking restart

## 🔥 Habilitar forwarding y NAT
echo "⚙️ Habilitando IP forwarding y NAT..."
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -A FORWARD -i br0 -o eth0 -j ACCEPT
iptables -A FORWARD -i eth0 -o br0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables-save > /etc/iptables.rules

echo "iptables-restore < /etc/iptables.rules" >> /etc/rc.local
chmod +x /etc/rc.local

## 📂 Configurar /etc/hosts para acceder a la VM por "ssh root@router"
echo "🖥️ Configurando /etc/hosts..."
echo "192.168.100.2    router" >> /etc/hosts

## 🚀 Descargar e instalar Alpine Linux en la VM
echo "💾 Descargando e instalando Alpine Linux en la VM..."
mkdir -p /var/lib/libvirt/images
wget -O /var/lib/libvirt/images/alpine-virt.iso https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/alpine-virt-3.18.4-x86_64.iso

qemu-img create -f qcow2 /var/lib/libvirt/images/router.qcow2 4G

expect -c "
spawn qemu-system-x86_64 -enable-kvm -m 512M -cdrom /var/lib/libvirt/images/alpine-virt.iso \
  -boot d -drive file=/var/lib/libvirt/images/router.qcow2,format=qcow2 \
  -nic bridge,br=br0 -serial mon:stdio
expect \"localhost login:\"
send \"root\r\"
expect \"# \"
send \"setup-alpine\r\"
expect \"Enter system hostname:\"
send \"router\r\"
expect \"New password:\"
send \"torpassword\r\"
expect \"Re-enter password:\"
send \"torpassword\r\"
expect \"Which disk(s) would you like to use?\"
send \"/dev/vda\r\"
expect \"Would you like to use it?\"
send \"y\r\"
expect \"Enter your timezone:\"
send \"UTC\r\"
expect \"Enter your keyboard layout:\"
send \"us\r\"
expect \"Which SSH server? \"
send \"openssh\r\"
expect \"Which NTP client? \"
send \"chrony\r\"
expect \"Reboot now?\"
send \"y\r\"
expect eof
"

## 🚀 Crear script de arranque de la VM
echo "🖥️ Creando script de arranque de la VM..."
cat <<EOF > /usr/local/bin/start-router-vm.sh
#!/bin/sh
qemu-system-x86_64 -enable-kvm -m 512M \\
    -serial tcp:0.0.0.0:6000,server,nowait \\
    -nic bridge,br=br0 \\
    -hda /var/lib/libvirt/images/router.qcow2 \\
    -daemonize
EOF

chmod +x /usr/local/bin/start-router-vm.sh

## ⚙️ Crear servicio systemd para iniciar la VM en el arranque
echo "🔧 Creando servicio systemd para la VM..."
cat <<EOF > /etc/systemd/system/router-vm.service
[Unit]
Description=Router VM
After=network.target

[Service]
ExecStart=/usr/local/bin/start-router-vm.sh
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl enable router-vm.service

## 🔑 Habilitar SSH en el host
echo "🔑 Habilitando SSH en el host..."
rc-update add sshd
service sshd start

## 🔥 Configurar la VM como Router Tor
echo "🌐 Configurando la VM para enrutar todo el tráfico a través de Tor..."
ssh root@router <<EOF
apk add tor iptables
rc-update add tor default
service tor start

# Configurar Tor como router transparente
echo "VirtualAddrNetworkIPv4 10.192.0.0/10" >> /etc/tor/torrc
echo "AutomapHostsOnResolve 1" >> /etc/tor/torrc
echo "TransPort 9040" >> /etc/tor/torrc
echo "DNSPort 53" >> /etc/tor/torrc
service tor restart

# Configurar iptables para forzar tráfico a Tor
iptables -F
iptables -t nat -F

iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Redirigir DNS a Tor
iptables -t nat -A PREROUTING -i eth1 -p udp --dport 53 -j REDIRECT --to-ports 53

# Redirigir todo el tráfico TCP a Tor (excepto el propio Tor)
iptables -t nat -A PREROUTING -i eth1 -p tcp --syn -j REDIRECT --to-ports 9040

# Bloquear tráfico no-Tor
iptables -A OUTPUT -m owner --uid-owner tor -j ACCEPT
iptables -A OUTPUT -j REJECT

iptables-save > /etc/iptables.rules
EOF

echo "✅ Configuración completada. Reinicia el sistema para aplicar todos los cambios."

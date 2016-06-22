#!/bin/bash

source ini-config

# Make sure only root can run our script
if [ "$(id -u)" != "0" ]; then
   echo "You need to be 'root' dude." 1>&2
   exit 1
fi

echo;
echo "##############################################################################################################

Go and edit your /etc/network/interfaces file to look something like this:

# loopback
auto lo
iface lo inet loopback
iface lo inet6 loopback

# The management network interface
auto eth0
iface eth0 inet static
  address 10.0.0.31
  netmask 255.255.255.0
  
# The external network interface  
auto eth1
iface eth1 inet manual
address 192.168.1.101
  netmask 255.255.255.0
  gateway 192.168.1.1
  dns-nameservers 8.8.8.8

# ipv6 configuration
iface eth0 inet6 auto

#########################################################################

Now edit your /etc/hosts file to look like this:

127.0.0.1   localhost
# 127.0.1.1 compute1
10.0.0.11   controller
10.0.0.31   compute1
10.0.0.32   compute2

Be sure to put each machine in the cluster's IP then name in the /etc/hosts file.

Make sure you check that the 127.0.1.1 number is commented out of your /etc/hosts file.

After you are done, do a 'ifdown --exclude=lo -a && sudo ifup --exclude=lo -a'.

###############################################################################################################"
# grab our IP 
read -p "Enter the device name for Mine management NIC (eth0, etc.) : " rignic
my_ip=$(/sbin/ifconfig $rignic| sed -n 's/.*inet *addr:\([0-9\.]*\).*/\1/p')

read -p "Enter the device name for this rig's Data Plane NIC (eth0, etc.) : " datanic

read -p "Enter the device name for Controller rig's management NIC (eth0, etc.) : " rigip

# Give your password
read -p "Please enter a password for MySQL : " password

#   backup source.list 
#   add new sources
mv /etc/apt/sources.list /etc/apt/sources.list.bak
echo "deb http://ftp.tku.edu.tw/ubuntu/ trusty main restricted universe multiverse
deb http://ftp.tku.edu.tw/ubuntu/ trusty-security main restricted universe multiverse
deb http://ftp.tku.edu.tw/ubuntu/ trusty-updates main restricted universe multiverse
deb http://ftp.tku.edu.tw/ubuntu/ trusty-proposed main restricted universe multiverse
deb http://ftp.tku.edu.tw/ubuntu/ trusty-backports main restricted universe multiverse
" >> /etc/apt/sources.list

sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 5EDB1B62EC4926EA
sudo apt-get install -y software-properties-common
#   add cloud sources liberty
sudo add-apt-repository cloud-archive:liberty
#   upgrade to the newest
sudo apt-get update && apt-get dist-upgrade

################################################################################
##                                    NTP                                     ##
################################################################################

# Install Time Server
apt-get install -y ntp

################################################################################
##                                    OPENSTACK CLIENT                        ##
################################################################################
apt-get install python-openstackclient

################################################################################
##                                    nova                                ##
################################################################################
apt-get install nova-compute sysfsutils python-openstackclient python-novaclient

 # vi /etc/nova/nova.conf

[DEFAULT]
iniset /etc/nova/nova.conf DEFAULT rpc_backend rabbit
iniset /etc/nova/nova.conf DEFAULT auth_strategy keystone
iniset /etc/nova/nova.conf DEFAULT my_ip $my_ip
iniset /etc/nova/nova.conf DEFAULT network_api_class nova.network.neutronv2.api.API
iniset /etc/nova/nova.conf DEFAULT linuxnet_interface_driver nova.network.linux_net.NeutronLinuxBridgeInterfaceDriver
iniset /etc/nova/nova.conf DEFAULT firewall_driver nova.virt.firewall.NoopFirewallDriver
iniset /etc/nova/nova.conf DEFAULT enabled_apis osapi_compute,metadata

inicomment /etc/nova/nova.conf DEFAULT security_group_api

iniset /etc/nova/nova.conf oslo_messagin_rabbit rabbit_host $rigip
iniset /etc/nova/nova.conf oslo_messagin_rabbit rabbit_userid openstack
iniset /etc/nova/nova.conf oslo_messagin_rabbit rabbit_password $password

iniset /etc/nova/nova.conf keystone_authtoken auth_url  http://$rigip:35357
iniset /etc/nova/nova.conf keystone_authtoken auth_plugin  password
iniset /etc/nova/nova.conf keystone_authtoken project_domain_id  default
iniset /etc/nova/nova.conf keystone_authtoken user_domain_id  default
iniset /etc/nova/nova.conf keystone_authtoken project_name  service
iniset /etc/nova/nova.conf keystone_authtoken username  nova
iniset /etc/nova/nova.conf keystone_authtoken password  $password

iniset /etc/nova/nova.conf vnc enabled True
iniset /etc/nova/nova.conf vnc vncserver_listen 0.0.0.0
iniset /etc/nova/nova.conf vnc vncserver_proxyclient_address $rigip
iniset /etc/nova/nova.conf vnc novncproxy_base_url http://172.18.47.111:6080/vnc_auto.html
iniset /etc/nova/nova.conf glance host $rigip
iniset /etc/nova/nova.conf oslo_concurrency lock_path /var/lib/nova/tmp
 
# vi /etc/nova/nova.conf
iniset /etc/nova/nova.conf neturon url http://$rigip:9696
iniset /etc/nova/nova.conf neturon auth_url http://$rigip:35357
iniset /etc/nova/nova.conf neturon auth_plugin password
iniset /etc/nova/nova.conf neturon project_domain_id default
iniset /etc/nova/nova.conf neturon user_domain_id default
iniset /etc/nova/nova.conf neturon region_name RegionOne
iniset /etc/nova/nova.conf neturon project_name service
iniset /etc/nova/nova.conf neturon username neutron
iniset /etc/nova/nova.conf neturon password $password
iniset /etc/nova/nova.conf neturon service_metadata_proxy True
iniset /etc/nova/nova.conf neturon metadata_proxy_shared_secret $password

# egrep -c '(vmx|svm)' /proc/cpuinfo
# vi /etc/nova/nova-compute.conf
# [libvirt]
# virt_type = qemu // 如果支持硬件虚拟化，可以配置为kvm

# 创建业务网络网桥
ovs-vsctl add-br br-ex
ovs-vsctl add-port br-ex $datanic

cat >> /etc/network/interfaces << EOF
auto $datanic
iface $datanic inet manual
up ip link set dev $IFACE up
down ip link set dev $IFACE down
EOF

service nova-compute restart


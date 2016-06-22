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
  address 10.0.0.11
  netmask 255.255.255.0
  
# The external network interface  
auto eth1
iface eth1 inet manual
address 192.168.1.100
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

# making a unique token for this install
token=`openssl rand -hex 10`

# grab our IP 
read -p "Enter the device name for this rig's management NIC (eth0, etc.) : " rignic
rigip=$(/sbin/ifconfig $rignic| sed -n 's/.*inet *addr:\([0-9\.]*\).*/\1/p')

read -p "Enter the device name for this rig's Data Plane NIC (eth0, etc.) : " datanic

# Grab our $ctrl_name's name
read -p "Enter the name for this rig (controller, controller-01, etc.) : " ctrl_name

# Give your password
read -p "Please enter a password for MySQL : " password

# Admin email
# read -p "Please enter an administrative email address : " email

# Get external IP range
# read -p "Please enter an IP range on your local network for external access (example "192.168.1.128/26" will desigante 192.168.1.129-.190) :" extip

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
sudo apt-get update && apt-get -y dist-upgrade

################################################################################
##                                    NTP                                     ##
################################################################################

# Install Time Server
apt-get install -y ntp

################################################################################
##                                    DATABASE                                ##
################################################################################

# Install MySQL
echo mysql-server-5.5 mysql-server/root_password password $password | debconf-set-selections
echo mysql-server-5.5 mysql-server/root_password_again password $password | debconf-set-selections
apt-get install -y mysql-server python-mysqldb

# make mysql listen on 0.0.0.0
MY_CNF=/etc/mysql/my.cnf
iniset $MY_CNF mysqld bind-address 0.0.0.0

# setup mysql to support utf8 and innodb
iniset $MY_CNF mysqld default-storage-engine innodb
iniset $MY_CNF mysqld innodb_file_per_table
iniset $MY_CNF mysqld collation-server utf8_general_ci
iniset $MY_CNF mysqld init-connect 'SET NAMES utf8'
iniset $MY_CNF mysqld character-set-server utf8

MYSQLD_OPENSTACK=/etc/mysql/conf.d/mysqld_openstack.cnf
iniset $MYSQLD_OPENSTACK mysqld bind-address 0.0.0.0
iniset $MYSQLD_OPENSTACK mysqld default-storage-engine innodb
iniset $MYSQLD_OPENSTACK mysqld innodb_file_per_table
iniset $MYSQLD_OPENSTACK mysqld collation-server utf8_general_ci
iniset $MYSQLD_OPENSTACK mysqld init-connect 'SET NAMES utf8'
iniset $MYSQLD_OPENSTACK mysqld character-set-server utf8

# Restart the MySQL service:
service mysql restart

# wait for restart
sleep 4 

################################################################################
##                                    RABBITMQ                                ##
################################################################################
# Install RabbitMQ (Message Queue):
apt-get install -y rabbitmq-server

#Replace RABBIT_PASS with a suitable password.
rabbitmqctl add_user openstack admin
rabbitmqctl set_permissions openstack ".*" ".*" ".*"

################################################################################
##                                    OPENSTACK CLIENT                        ##
################################################################################
apt-get install -y python-openstackclient


################################################################################
##                                    KEYSTONE                                ##
################################################################################

# 创建数据库
mysql -u root -p"$password"<<EOF
CREATE DATABASE keystone;
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' \
  IDENTIFIED BY 'admin';
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' \
  IDENTIFIED BY 'admin';
EOF

apt-get install -y keystone

# edit /etc/keystone/keystone.conf
iniset /etc/keystone/keystone.conf DEFAULT admin_token $token
iniset /etc/keystone/keystone.conf database connection "mysql+pymysql://keystone:$password@$rigip/keystone"

# 重启keystone:
service keystone restart

# 初始化数据库
su -s /bin/sh -c "keystone-manage db_sync" keystone

export OS_TOKEN=$token
export OS_URL=http://$rigip:35357/v3
export OS_IDENTITY_API_VERSION=3

# 增加keystone服务条目：
openstack service create --name keystone --description "OpenStack Identity" identity

# 增加API endpoints：
openstack endpoint create --region RegionOne \
  identity public http://$rigip:5000/v2.0
openstack endpoint create --region RegionOne \
  identity internal http://$rigip:5000/v2.0
openstack endpoint create --region RegionOne \
  identity admin http://$rigip:35357/v2.0

# 创建一个admin project和一个admin角色以及用户：
openstack project create --domain default --description "Admin Project" admin
openstack user create --domain default --password $password admin
openstack role create admin
openstack role add --project admin --user admin admin

# 创建一个service project用来存放各个服务专属的用户：
openstack project create --domain default --description "Service Project" service

# 创建一个demo project和一个user角色以及一个普通用户demo：
openstack project create --domain default --description "Demo Project" demo
openstack user create --domain default --password $password demo
openstack role create user
openstack role add --project demo --user demo user

# unset var
unset OS_TOKEN OS_URL OS_IDENTITY_API_VERSION

# 用新创建的admin用户去获取一个令牌：
openstack --os-auth-url http://$rigip:35357/v3 \
  --os-project-domain-id default --os-user-domain-id default \
  --os-project-name admin --os-username admin --os-auth-type password \
  token issue

#用新创建的demo用户去获取一个令牌：
openstack --os-auth-url http://$rigip:5000/v3 \
  --os-project-domain-id default --os-user-domain-id default \
  --os-project-name demo --os-username demo --os-auth-type password \
  token issue

cat > ./admin-openrc.sh <<EOF
export OS_PROJECT_DOMAIN_ID=default
export OS_USER_DOMAIN_ID=default
export OS_PROJECT_NAME=admin
export OS_TENANT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=admin
export OS_AUTH_URL=http://$rigip:35357/v3
export OS_IDENTITY_API_VERSION=3
EOF

cat > ./demo-openrc.sh <<EOF
export OS_PROJECT_DOMAIN_ID=default
export OS_USER_DOMAIN_ID=default
export OS_PROJECT_NAME=demo
export OS_TENANT_NAME=demo
export OS_USERNAME=demo
export OS_PASSWORD=demo
export OS_AUTH_URL=http://$rigip:5000/v3
export OS_IDENTITY_API_VERSION=3
EOF

################################################################################
##                                    glance                                ##
################################################################################

mysql -u root -p"$password"<<EOF
CREATE DATABASE glance;
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost' \
  IDENTIFIED BY 'admin';
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%' \
  IDENTIFIED BY 'admin';
EOF

source admin-openrc.sh
openstack user create --domain default --password $password glance
openstack role add --project service --user glance admin
openstack service create --name glance --description "OpenStack Image service" image
openstack endpoint create --region RegionOne image public http://$rigip:9292
openstack endpoint create --region RegionOne image internal http://$rigip:9292
openstack endpoint create --region RegionOne image admin http://$rigip:9292

apt-get install -y glance python-glanceclient

# edit /etc/glance/glance-api.conf
GLANCE_API=/etc/glance/glance-api.conf
iniset $GLANCE_API database connection "mysql+pymysql://glance:$password@$rigip/glance"
iniset $GLANCE_API keystone_authtoken auth_uri http://$rigip:5000
iniset $GLANCE_API keystone_authtoken auth_url http://$rigip:35357
iniset $GLANCE_API keystone_authtoken auth_plugin password
iniset $GLANCE_API keystone_authtoken project_domain_id default
iniset $GLANCE_API keystone_authtoken user_domain_id default
iniset $GLANCE_API keystone_authtoken project_name service
iniset $GLANCE_API keystone_authtoken username glance
iniset $GLANCE_API keystone_authtoken password $password
iniset $GLANCE_API paste_deploy flavor keystone
iniset $GLANCE_API glance_store default_store file
iniset $GLANCE_API glance_store filesystem_store_datadir /var/lib/glance/images/
iniset $GLANCE_API notification_driver noop

# edit /etc/glance/glance-registry.conf
GLANCE_REG=/etc/glance/glance-registry.conf
iniset $GLANCE_REG database connection "mysql+pymysql://glance:$password@$rigip/glance"
iniset $GLANCE_REG keystone_authtoken auth_uri http://$rigip:5000
iniset $GLANCE_REG keystone_authtoken auth_url http://$rigip:35357
iniset $GLANCE_REG keystone_authtoken auth_plugin password
iniset $GLANCE_REG keystone_authtoken project_domain_id default
iniset $GLANCE_REG keystone_authtoken user_domain_id default
iniset $GLANCE_REG keystone_authtoken project_name service
iniset $GLANCE_REG keystone_authtoken username glance
iniset $GLANCE_REG keystone_authtoken password $password
iniset $GLANCE_REG paste_deploy flavor keystone
iniset $GLANCE_REG DEFAULT notification_driver noop

su -s /bin/sh -c "glance-manage db_sync" glance

service glance-registry restart
service glance-api restart

echo "export OS_IMAGE_API_VERSION=2" \
  | tee -a admin-openrc.sh demo-openrc.sh

source admin-openrc.sh

#curl -O http://download.cirros-cloud.net/0.3.4/cirros-0.3.4-x86_64-disk.img

glance image-create --name "cirros" \
  --file cirros-0.3.4-x86_64-disk.img \
  --disk-format qcow2 --container-format bare \
  --visibility public --progress

################################################################################
##                                    nova                                ##
################################################################################

mysql -u root -p"$password"<<EOF
CREATE DATABASE nova;
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost' \
  IDENTIFIED BY 'admin';
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%' \
  IDENTIFIED BY 'admin';
EOF

source admin-openrc.sh
openstack user create --domain default --password $password nova
openstack role add --project service --user nova admin

openstack service create --name nova --description "OpenStack Compute" compute

openstack endpoint create --region RegionOne compute public http://$rigip:8774/v2/%\(tenant_id\)s
openstack endpoint create --region RegionOne compute internal http://$rigip:8774/v2/%\(tenant_id\)s
openstack endpoint create --region RegionOne compute admin http://$rigip:8774/v2/%\(tenant_id\)s

apt-get install -y nova-api nova-conductor \
  nova-consoleauth nova-novncproxy nova-scheduler \
  python-novaclient sysfsutils

# vi /etc/nova/nova.conf
iniset /etc/nova/nova.conf database connection mysql+pymysql://nova:$password@$rigip/nova
iniset /etc/nova/nova.conf DEFAULT rpc_backend rabbit
iniset /etc/nova/nova.conf DEFAULT auth_strategy keystone
iniset /etc/nova/nova.conf DEFAULT my_ip $rigip
#iniset /etc/nova/nova.conf DEFAULT network_api_class nova.network.neutronv2.api.API
#iniset /etc/nova/nova.conf DEFAULT linuxnet_interface_driver nova.network.linux_net.NeutronLinuxBridgeInterfaceDriver
#iniset /etc/nova/nova.conf DEFAULT firewall_driver nova.virt.firewall.NoopFirewallDriver
iniset /etc/nova/nova.conf DEFAULT enabled_apis osapi_compute,metadata
#iniset /etc/nova/nova.conf DEFAULT rootwrap_config /etc/nova/rootwrap.conf
#inicomment /etc/nova/nova.conf DEFAULT security_group_api
iniset /etc/nova/nova.conf oslo_messaging_rabbit rabbit_host $rigip
iniset /etc/nova/nova.conf oslo_messaging_rabbit rabbit_userid openstack
iniset /etc/nova/nova.conf oslo_messaging_rabbit rabbit_password $password
iniset /etc/nova/nova.conf keystone_authtoken auth_uri http://$rigip:5000
iniset /etc/nova/nova.conf keystone_authtoken auth_url http://$rigip:35357
iniset /etc/nova/nova.conf keystone_authtoken auth_plugin password
iniset /etc/nova/nova.conf keystone_authtoken project_domain_id default
iniset /etc/nova/nova.conf keystone_authtoken user_domain_id default
iniset /etc/nova/nova.conf keystone_authtoken project_name service
iniset /etc/nova/nova.conf keystone_authtoken username nova
iniset /etc/nova/nova.conf keystone_authtoken password $password
iniset /etc/nova/nova.conf vnc enabled true
iniset /etc/nova/nova.conf vnc vncserver_listen $rigip
iniset /etc/nova/nova.conf vnc vncserver_proxyclient_address $rigip
iniset /etc/nova/nova.conf vnc novncproxy_base_url http://$rigip:6080/vnc_auto.html
iniset /etc/nova/nova.conf glance host $rigip
iniset /etc/nova/nova.conf oslo_concurrency lock_path /var/lib/nova/tmp

service nova-api restart 
service nova-consoleauth restart
service nova-scheduler restart
service nova-conductor restart
service nova-novncproxy restart

# 初始化数据库
su -s /bin/sh -c "nova-manage db sync" nova

service nova-api restart 
service nova-consoleauth restart
service nova-scheduler restart
service nova-conductor restart
service nova-novncproxy restart

source admin-openrc.sh

# nova启动的服务：
nova service-list

# nova的endpoints:
nova endpoints

# 通过nova也可以查看镜像列表：
nova image-list

################################################################################
##                                    neutron ctrl                                ##
################################################################################

mysql -u root -p"$password" <<EOF
CREATE DATABASE neutron;
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'localhost' \
  IDENTIFIED BY 'admin';
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'%' \
  IDENTIFIED BY 'admin';
EOF

source admin-openrc.sh
openstack user create --domain default --password $password neutron
openstack role add --project service --user neutron admin
openstack service create --name neutron --description "OpenStack Networking" network
openstack endpoint create --region RegionOne network public http://$rigip:9696
openstack endpoint create --region RegionOne network internal http://$rigip:9696
openstack endpoint create --region RegionOne network admin http://$rigip:9696

apt-get install -y neutron-server neutron-plugin-ml2 \
  python-neutronclient conntrack

# edit /etc/neutron/neutron.conf
iniset /etc/neutron/neutron.conf database connection mysql+pymysql://neutron:$password@$rigip/neutron
iniset /etc/neutron/neutron.conf DEFAULT core_plugin ml2
iniset /etc/neutron/neutron.conf DEFAULT service_plugins 
iniset /etc/neutron/neutron.conf DEFAULT rpc_backend rabbit
iniset /etc/neutron/neutron.conf DEFAULT auth_strategy keystone
iniset /etc/neutron/neutron.conf DEFAULT notify_nova_on_port_status_changes True
iniset /etc/neutron/neutron.conf DEFAULT notify_nova_on_port_data_changes True
iniset /etc/neutron/neutron.conf DEFAULT nova_url http://$rigip:8774/v2
iniset /etc/neutron/neutron.conf oslo_messaging_rabbit rabbit_host $rigip
iniset /etc/neutron/neutron.conf oslo_messaging_rabbit rabbit_userid openstack
iniset /etc/neutron/neutron.conf oslo_messaging_rabbit rabbit_password $password
iniset /etc/neutron/neutron.conf keystone_authtoken auth_uri http://$rigip:5000
iniset /etc/neutron/neutron.conf keystone_authtoken auth_url http://$rigip:35357
iniset /etc/neutron/neutron.conf keystone_authtoken auth_plugin password
iniset /etc/neutron/neutron.conf keystone_authtoken project_domain_id default
iniset /etc/neutron/neutron.conf keystone_authtoken user_domain_id default
iniset /etc/neutron/neutron.conf keystone_authtoken project_name service
iniset /etc/neutron/neutron.conf keystone_authtoken username neutron
iniset /etc/neutron/neutron.conf keystone_authtoken password $password
iniset /etc/neutron/neutron.conf nova auth_url http://$rigip:35357
iniset /etc/neutron/neutron.conf nova auth_plugin password
iniset /etc/neutron/neutron.conf nova project_domain_id default
iniset /etc/neutron/neutron.conf nova user_domain_id default
iniset /etc/neutron/neutron.conf nova region_name RegionOne
iniset /etc/neutron/neutron.conf nova project_name service
iniset /etc/neutron/neutron.conf nova username nova
iniset /etc/neutron/neutron.conf nova password $password

# edit /etc/neutron/plugins/ml2/ml2_conf.ini
iniset /etc/neutron/plugins/ml2/ml2_conf.ini ml2 enable_ipset true
iniset /etc/neutron/plugins/ml2/ml2_conf.ini ml2 extension_drivers port_security
iniset /etc/neutron/plugins/ml2/ml2_conf.ini ml2 mechanism_drivers openvswitch
iniset /etc/neutron/plugins/ml2/ml2_conf.ini ml2 tenant_network_types vlan
iniset /etc/neutron/plugins/ml2/ml2_conf.ini ml2 type_drivers vlan
iniset /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_vlan network_vlan_ranges default:3001:4000


# edit /etc/nova/nova.conf
iniset /etc/nova/nova.conf neutron url http://$rigip:9696
iniset /etc/nova/nova.conf neutron auth_url http://$rigip:35357
iniset /etc/nova/nova.conf neutron auth_plugin password
iniset /etc/nova/nova.conf neutron project_domain_id default
iniset /etc/nova/nova.conf neutron user_domain_id default
iniset /etc/nova/nova.conf neutron region_name RegionOne
iniset /etc/nova/nova.conf neutron project_name service
iniset /etc/nova/nova.conf neutron username neutron
iniset /etc/nova/nova.conf neutron password $password
iniset /etc/nova/nova.conf neutron service_metadata_proxy True
iniset /etc/nova/nova.conf neutron metadata_proxy_shared_secret $password

su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf \
  --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head" neutron

service nova-api restart
service neutron-server restart

neutron ext-list

################################################################################
##                                    neutron network                                ##
################################################################################

apt-get install -y neutron-l3-agent neutron-dhcp-agent \
  python-neutronclient conntrack neutron-plugin-openvswitch-agent \
  openvswitch-switch neutron-metadata-agent


# edit /etc/neutron/neutron.conf
iniset /etc/neutron/neutron.conf DEFAULT core_plugin ml2
iniset /etc/neutron/neutron.conf DEFAULT service_plugins router
iniset /etc/neutron/neutron.conf DEFAULT allow_overlapping_ips True
iniset /etc/neutron/neutron.conf DEFAULT rpc_backend rabbit
iniset /etc/neutron/neutron.conf DEFAULT auth_strategy keystone
iniset /etc/neutron/neutron.conf DEFAULT notify_nova_on_port_status_changes True
iniset /etc/neutron/neutron.conf DEFAULT notify_nova_on_port_data_changes True
iniset /etc/neutron/neutron.conf DEFAULT nova_url http://$rigip:8774/v2
iniset /etc/neutron/neutron.conf oslo_messaging_rabbit rabbit_host $rigip
iniset /etc/neutron/neutron.conf oslo_messaging_rabbit rabbit_userid openstack
iniset /etc/neutron/neutron.conf oslo_messaging_rabbit rabbit_password $password
iniset /etc/neutron/neutron.conf keystone_authtoken auth_url http://$rigip:35357
iniset /etc/neutron/neutron.conf keystone_authtoken auth_plugin password
iniset /etc/neutron/neutron.conf keystone_authtoken project_domain_id default
iniset /etc/neutron/neutron.conf keystone_authtoken user_domain_id default
iniset /etc/neutron/neutron.conf keystone_authtoken project_name service
iniset /etc/neutron/neutron.conf keystone_authtoken username neutron
iniset /etc/neutron/neutron.conf keystone_authtoken password $password
iniset /etc/neutron.neturon.conf nova auth_url http://$rigip:35357
iniset /etc/neutron.neturon.conf nova auth_plugin password
iniset /etc/neutron.neturon.conf nova project_domain_id default
iniset /etc/neutron.neturon.conf nova user_domain_id default
iniset /etc/neutron.neturon.conf nova region_name RegionOne
iniset /etc/neutron.neturon.conf nova project_name service
iniset /etc/neutron.neturon.conf nova username nova
iniset /etc/neutron.neturon.conf nova password $password

# vi /etc/neutron/plugins/ml2/openvswitch_agent.ini
iniset /etc/neutron/plugins/ml2/openvswitch_agent.ini ovs integration_bridge br-int
iniset /etc/neutron/plugins/ml2/openvswitch_agent.ini agent agent_type 'Open vSwitch agent'
iniset /etc/neutron/plugins/ml2/openvswitch_agent.ini ovs datapath system
iniset /etc/neutron/plugins/ml2/openvswitch_agent.ini ovs bridge_mappings default:br-ex

# vi /etc/neutron/l3_agent.ini
iniset /etc/neutron/l3_agent.ini DEFAULT interface_driver neutron.agent.linux.interface.OVSInterfaceDriver
iniset /etc/neutron/l3_agent.ini DEFAULT external_network_bridge 

touch /etc/neutron/fwaas_driver.ini

# vi /etc/neutron/dhcp_agent.ini
iniset /etc/neutron/dhcp_agent.ini DEFAULT interface_driver neutron.agent.linux.interface.OVSInterfaceDriver
iniset /etc/neutron/dhcp_agent.ini DEFAULT dhcp_driver neutron.agent.linux.dhcp.Dnsmasq
iniset /etc/neutron/dhcp_agent.ini DEFAULT enable_isolated_metadata True
iniset /etc/neutron/dhcp_agent.ini DEFAULT dnsmasq_config_file /etc/neutron/dnsmasq-neutron.conf

# vi /etc/neutron/dnsmasq-neutron.conf
iniset /etc/neutron/dnsmasq-neutron.conf DEFAULT dhcp-option-force 26,1450

# vi /etc/neutron/metadata_agent.ini
iniset /etc/neutron/metadeta_agent.ini DEFAULT auth_url http://$rigip:35357
iniset /etc/neutron/metadeta_agent.ini DEFAULT auth_region RegionOne
iniset /etc/neutron/metadeta_agent.ini DEFAULT auth_plugin password
iniset /etc/neutron/metadeta_agent.ini DEFAULT project_domain_id default
iniset /etc/neutron/metadeta_agent.ini DEFAULT user_domain_id default
iniset /etc/neutron/metadeta_agent.ini DEFAULT project_name service
iniset /etc/neutron/metadeta_agent.ini DEFAULT username neutron
iniset /etc/neutron/metadeta_agent.ini DEFAULT password $password
iniset /etc/neutron/metadeta_agent.ini DEFAULT nova_metadata_ip $rigip
iniset /etc/neutron/metadeta_agent.ini DEFAULT metadata_proxy_shared_secret $password

# vi /etc/neutron/linuxbridge_agent.ini
iniset /etc/neutron/plugins/ml2/linuxbridge_agent.ini linux_bridge physical_interface_mappings default:br-ex
iniset /etc/neutron/plugins/ml2/linuxbridge_agent.ini vxlan enable_vxlan false
iniset /etc/neutron/plugins/ml2/linuxbridge_agent.ini agent prevent_arp_spoofing true
iniset /etc/neutron/plugins/ml2/linuxbridge_agent.ini securitygroup enable_security_group true
iniset /etc/neutron/plugins/ml2/linuxbridge_agent.ini securitygroup firewall_driver neutron.agent.linux.iptables_firewall.IptablesFirewallDriver

# 重启nova服务
service nova-api restart
service neutron-server restart
service nova-compute restart
service neutron-plugin-openvswitch-agent restart
service neutron-dhcp-agent restart
service neutron-metadata-agent restart
service neutron-l3-agent restart

# 创建业务网络网桥
ovs-vsctl add-br br-ex
ovs-vsctl add-port br-ex $datanic

cat >> /etc/network/interfaces << EOF
auto $datanic
iface $datanic inet manual
up ip link set dev $IFACE up
down ip link set dev $IFACE down
EOF

# 重启网络服务
service neutron-plugin-openvswitch-agent restart
service neutron-dhcp-agent restart
service neutron-metadata-agent restart
service neutron-l3-agent restart

neutron agent-list

################################################################################
##                                     dashboard                                ##
################################################################################

apt-get install -y openstack-dashboard

apt-get remove -y --purge openstack-dashboard-ubuntu-theme

# vi /etc/openstack-dashboard/local_settings.py
# OPENSTACK_HOST = "$ctrl_name"
# ALLOWED_HOSTS = ['*', ]
# OPENSTACK_KEYSTONE_DEFAULT_ROLE = "user"

service apache2 reload

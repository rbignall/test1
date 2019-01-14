#!/bin/bash

# The MIT License (MIT)
#
# Copyright (c) 2015 Microsoft Azure
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
# Author: Cognosys Technologies
 
### 
### Warning! This script partitions and formats disk information be careful where you run it
###          This script is currently under development and has only been tested on Ubuntu images in Azure
###          This script is not currently idempotent and only works for provisioning at the moment

### Remaining work items
### -Alternate discovery options (Azure Storage)
### -Implement Idempotency and Configuration Change Support
### -Recovery Settings (These can be changed via API)

help()
{
    #TODO: Add help text here
    echo "This script installs kafka cluster on Ubuntu"
    echo "Parameters:"
    echo "-k kafka version like 0.8.2.1"
    echo "-b broker id"
    echo "-h view this help content"
    echo "-z zookeeper not kafka"
    echo "-i zookeeper Private IP address prefix"
    echo "-f kafka connect and mysql, not kafka"
    echo "-j just java"
    echo "-p mysql root password"
}

log()
{
	# If you want to enable this logging add a un-comment the line below and add your account key 
    	#curl -X POST -H "content-type:text/plain" --data-binary "$(date) | ${HOSTNAME} | $1" https://logs-01.loggly.com/inputs/[account-key]/tag/redis-extension,${HOSTNAME}
	echo "$1"
}

log "Begin execution of kafka script extension on ${HOSTNAME}"

if [ "${UID}" -ne 0 ];
then
    log "Script executed without root permissions"
    echo "You must be root to run this program." >&2
    exit 3
fi

# TEMP FIX - Re-evaluate and remove when possible
# This is an interim fix for hostname resolution in current VM
grep -q "${HOSTNAME}" /etc/hosts
if [ $? -eq $SUCCESS ];
then
  echo "${HOSTNAME}found in /etc/hosts"
else
  echo "${HOSTNAME} not found in /etc/hosts"
  # Append it to the hsots file if not there
  echo "127.0.0.1 $(hostname)" >> /etc/hosts
  log "hostname ${HOSTNAME} added to /etc/hosts"
fi

#Script Parameters
KF_VERSION="2.1.0"
BROKER_ID=0
ZOOKEEPER1KAFKA0="0"
JAVAONLY="0"
KAFKACONNECT="0"
MYSQLPASSWORD=""

ZOOKEEPER_IP_PREFIX="10.10.0.4"
INSTANCE_COUNT=1
ZOOKEEPER_PORT="2181"

#Loop through options passed
while getopts :k:b:z:i:f:c:h:j:p optname; do
    log "Option $optname set with value ${OPTARG}"
  case $optname in
    k)  #kafka version
      KF_VERSION=${OPTARG}
      ;;
    b)  #broker id
      BROKER_ID=${OPTARG}
      ;;
    z)  #zookeeper not kafka
      ZOOKEEPER1KAFKA0=${OPTARG}
      ;;
    j)  #only java, not zookeeper or kafka
      JAVAONLY=${OPTARG}
      ;;
    i)  #zookeeper Private IP address prefix
      ZOOKEEPER_IP_PREFIX=${OPTARG}
      ;;
    f)  #kafka connect not kafka
      KAFKACONNECT=${OPTARG}
      ;;
    c) # Number of instances
	    INSTANCE_COUNT=${OPTARG}
    	;;
    p)  #mysql root password
      MYSQLPASSWORD=${OPTARG}
      ;;
    h)  #show help
      help
      exit 2
      ;;
    \?) #unrecognized option - show help
      echo -e \\n"Option -${BOLD}$OPTARG${NORM} not allowed."
      help
      exit 2
      ;;
  esac
done

THIS_IP_ADDRESS=$(hostname -I | tr -d '[:space:]')
THIS_HOST="rbkafka${BROKER_ID}.uksouth.cloudapp.azure.com"

# Install Oracle Java
install_java()
{
    log "Installing Java"
    add-apt-repository -y ppa:openjdk-r/ppa
    apt-get -y update 
#    echo debconf shared/accepted-oracle-license-v1-1 select true | sudo debconf-set-selections
#    echo debconf shared/accepted-oracle-license-v1-1 seen true | sudo debconf-set-selections
    apt-get -y install openjdk-8-jre
}

# Expand a list of successive IP range defined by a starting address prefix (e.g. 10.0.0.1) and the number of machines in the range
# 10.0.0.1-3 would be converted to "10.0.0.10 10.0.0.11 10.0.0.12"

expand_ip_range_for_server_properties() {
    IFS='-' read -a HOST_IPS <<< "$1"
    for (( n=0 ; n<("${HOST_IPS[1]}"+0) ; n++))
    do
        echo "server.$(expr ${n} + 1)=${HOST_IPS[0]}${n}:2888:3888" >> zookeeper-3.4.12/conf/zoo.cfg       
    done
}

function join { local IFS="$1"; shift; echo "$*"; }

expand_ip_range() {
    IFS='-' read -a HOST_IPS <<< "$1"

    declare -a EXPAND_STATICIP_RANGE_RESULTS=()

    for (( n=0 ; n<("${HOST_IPS[1]}"+0) ; n++))
    do
        HOST="${HOST_IPS[0]}${n}:${ZOOKEEPER_PORT}"
                EXPAND_STATICIP_RANGE_RESULTS+=($HOST)
    done

    echo "${EXPAND_STATICIP_RANGE_RESULTS[@]}"
}

# Install Zookeeper - can expose zookeeper version
install_zookeeper()
{
	mkdir -p /var/lib/zookeeper
	cd /var/lib/zookeeper
	wget "http://mirrors.ukfast.co.uk/sites/ftp.apache.org/zookeeper/stable/zookeeper-3.4.12.tar.gz"
	tar -xvf "zookeeper-3.4.12.tar.gz"

	touch zookeeper-3.4.12/conf/zoo.cfg

	echo "tickTime=2000" >> zookeeper-3.4.12/conf/zoo.cfg
	echo "dataDir=/var/lib/zookeeper" >> zookeeper-3.4.12/conf/zoo.cfg
	echo "clientPort=2181" >> zookeeper-3.4.12/conf/zoo.cfg
	echo "initLimit=5" >> zookeeper-3.4.12/conf/zoo.cfg
	echo "syncLimit=2" >> zookeeper-3.4.12/conf/zoo.cfg
	# OLD Test echo "server.1=${ZOOKEEPER_IP_PREFIX}:2888:3888" >> zookeeper-3.4.6/conf/zoo.cfg
	$(expand_ip_range_for_server_properties "${ZOOKEEPER_IP_PREFIX}-${INSTANCE_COUNT}")

	echo $(($1+1)) >> /var/lib/zookeeper/myid

	zookeeper-3.4.12/bin/zkServer.sh start
}

# Install kafka
install_kafka()
{
	cd /usr/local
	name=kafka
	version=${KF_VERSION}
	#this Kafka version is prefix same used for all versions
	kafkaversion=2.11
	description="Apache Kafka is a distributed publish-subscribe messaging system."
	url="https://kafka.apache.org/"
	arch="all"
	section="misc"
	license="Apache Software License 2.0"
	package_version="-1"
	src_package="kafka_${kafkaversion}-${version}.tgz"
	download_url=http://www-eu.apache.org/dist/kafka/${version}/${src_package} 

	rm -rf kafka
	mkdir -p kafka
	cd kafka
	#_ MAIN _#
	if [[ ! -f "${src_package}" ]]; then
	  wget ${download_url}
	fi
	tar zxf ${src_package}
	cd kafka_${kafkaversion}-${version}
	
	sed -r -i "s/(broker.id)=(.*)/\1=${BROKER_ID}/g" config/server.properties
	sed -r -i "s/(zookeeper.connect)=(.*)/\1=$(join , $(expand_ip_range "${ZOOKEEPER_IP_PREFIX}-${INSTANCE_COUNT}"))/g" config/server.properties
	sed -i "/advertised.listeners/c advertised.listeners=PLAINTEXT://${THIS_HOST}:9092" config/server.properties
	sed -i "/advertised.listeners/a advertised.host.name=${THIS_HOST}" config/server.properties
	sed -i "/advertised.host.name/a advertised.port=9092" config/server.properties
	chmod u+x /usr/local/kafka/kafka_${kafkaversion}-${version}/bin/kafka-server-start.sh
	/usr/local/kafka/kafka_${kafkaversion}-${version}/bin/kafka-server-start.sh /usr/local/kafka/kafka_${kafkaversion}-${version}/config/server.properties &
}

# Install kafka connect
install_kafka_connect()
{
  log "Installing Kafka Connect"

  wget -qO - "https://packages.confluent.io/deb/3.3/archive.key" | apt-key add -
  add-apt-repository "deb [arch=amd64] https://packages.confluent.io/deb/3.3 stable main"
  apt-get -y update 
  apt-get -y install confluent-platform-oss-2.11

  cd /etc/schema-registry
  sed -r -i "s/(kafkastore.connection.url)=(.*)/\1=$(join , $(expand_ip_range "${ZOOKEEPER_IP_PREFIX}-${INSTANCE_COUNT}"))/g" schema-registry.properties
  /usr/bin/schema-registry-start /etc/schema-registry/schema-registry.properties &
}

# Install mysql
install_mysql()
{
  log "Installing MySql"

  apt-get -y update
  DEBIAN_FRONTEND=noninteractive apt-get -y install mysql-server php5-mysql

  mysql_install_db
  # actions from mysql_secure_installation (roughly)
  mysql -e "UPDATE mysql.user SET Password = PASSWORD('"${MYSQLPASSWORD}"') WHERE User = 'root'"
  mysql -e "DELETE FROM mysql.user WHERE User=''"
  mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1')"
  mysql -e "DROP DATABASE IF EXISTS test"
  mysql -e "FLUSH PRIVILEGES"
}

# Primary Install Tasks
#########################
#NOTE: These first three could be changed to run in parallel --- OBSOLETE comment
#      Future enhancement - (export the functions and use background/wait to run in parallel)

#Install Oracle Java
#------------------------
install_java

if [ ${JAVAONLY} -eq "0" ]
then
  if [ ${ZOOKEEPER1KAFKA0} -eq "1" ]
  then
    #
    #Install zookeeper
    #-----------------------
    install_zookeeper
  else
    if [ ${KAFKACONNECT} -eq "1" ]
    then
      #
      #Install kafka connect and mysql
      #-------------------------------
      install_kafka_connect
      install_mysql
    else
      #
      #Install kafka
      #-----------------------
      install_kafka
    fi
  fi
fi

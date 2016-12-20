#!/bin/bash -ex
# Chef HA Cluster setup script for Microsoft Azure

usage='
ChefHaClusterSetup.sh --role backend|frontend --leader true|false --secrets-location https://mystandardstorage.blob.core.windows.net/mycontainer --sas-token "sastokenstring"
'

if [ $# -lt 3 ]; then
  echo -e $usage
  exit 1
fi


# Argument parsing
while [[ $# -gt 1 ]]
do
key="$1"

case $key in
    -r|--role)
    ROLE="$2"
    shift # past argument
    ;;
    -l|--leader)
    LEADER="$2"
    shift # past argument
    ;;
    --secrets-location)
    SECRETS_LOCATION="$2"
    shift # past argument
    ;;
    --sas-token)
    SAS_TOKEN="$2"
    shift # past argument
    ;;
    -h|--help)
    echo -e $usage
    exit 0
    ;;
    *)
    echo "Unknown option $1"
    echo -e $usage
    exit 1
    ;;
esac
shift # past argument or value
done


setup_repo () {
  apt-get install -y apt-transport-https
  wget -qO - https://downloads.chef.io/packages-chef-io-public.key | sudo apt-key add -
  echo "deb https://packages.chef.io/stable-apt trusty main" > /etc/apt/sources.list.d/chef-stable.list
  apt-get update
}

backend_format_disk () {
  apt-get install lvm2 xfsprogs sysstat atop ntp -y
  MNT_MOUNTED=`grep \/mnt /proc/mount || /bin/true`
  if [ -n "${MNT_MOUNTED}" ]; then
    umount -f /mnt
  fi
  pvcreate -f /dev/sdb1
  vgcreate chef-vg /dev/sdb1
  lvcreate -n chef-lv -l 90%VG chef-vg
  mkfs.xfs /dev/chef-vg/chef-lv
  mkdir -p /var/opt/chef-backend
  mount /dev/chef-vg/chef-lv /var/opt/chef-backend
  # remove the cloud-init added /mnt mountpoint from fstab
  sed -i 's/\/dev\/disk\/cloud\/azure_resource-part1.*//' /etc/fstab
  # but don't add the new ephemeral mount because we don't expect it to be there upon reboot
}

backend_format_disk_zfs () {
  apt-get install zfs sysstat atop ntp -y

  # Mount the local SSD volume (215 GB on a D3v2)
  MNT_MOUNTED=`grep \/mnt /proc/mount || /bin/true`
  if [ -n "${MNT_MOUNTED}" ]; then
    umount -f /mnt
  fi
  zpool create ssd-data /dev/sdb -f
  mkdir -p /var/opt/chef-backend
  zfs create -o mountpoint=/var/opt/chef-backend ssd-data/chef
  # remove the cloud-init added /mnt mountpoint from fstab
  sed -i 's/\/dev\/disk\/cloud\/azure_resource-part1.*//' /etc/fstab
  # but don't add the new ephemeral mount because we don't expect it to be there upon reboot
}

# Further ZFS tuning reading:
# http://www.slideshare.net/fuzzycz/postgresql-on-ext4-xfs-btrfs-and-zfs
# https://www.joyent.com/blog/bruning-questions-zfs-record-size

# command to sync local-ssd to persistent-data:
#   zfs snapshot -r ssd-data/chef@snap1
#   send a full snapshot:
#     zfs send ssd-data/chef@snap1 | gzip | curl --data-raw - "${SECRETS_LOCATION}/be0/snap-full${SAS_TOKEN}" --header "x-ms-blob-type: BlockBlob"
#   send an incremental snapshot
#     zfs send -I ssd-data/chef@snap1 ssd-data/chef@snap2 | gzip | curl --data-raw - "${SECRETS_LOCATION}/be0/snap-full${SAS_TOKEN}" --header "x-ms-blob-type: BlockBlob"
#   TODO: schedule this to run on a time-period (daily full, incremental every 15 minutes?)
#
# and vice-versa for restores onto a new machine
#   curl "${SECRETS_LOCATION}/be0/snap-full${SAS_TOKEN}" --header "x-ms-blob-type: BlockBlob" | gzip -d | zfs receive ssd-data/chef
#   ... and then repeat for every incremental up until the latest
#
# TODO:  look into adapting z3 for use with Azure blob store: https://github.com/PressLabs/z3
#       Python library for azure-storage: https://github.com/Azure/azure-storage-python


# NOTE: btrfs is here for reference, but in practice is massively slower than XFS and ZFS
#  with default mount options, pgbench shows a 50% decrease in TPS and a 100% increase in average latency
#    see: https://blog.pgaddict.com/posts/friends-dont-let-friends-use-btrfs-for-oltp
#  using `nodatacow` also disables `nodatasum` which greatly reduces the benefits.
#    also, performance is still 75% of XFS and 150% higher average latency
backend_format_disk_btrfs () {
  apt-get install btrfs-tools sysstat atop ntp -y

  # Mount the local SSD volume (215 GB on a D3v2)
  MNT_MOUNTED=`grep \/mnt /proc/mount || /bin/true`
  if [ -n "${MNT_MOUNTED}" ]; then
    umount -f /mnt
  fi
  mkfs.btrfs -f /dev/sdb1
  mkdir -p /var/opt/chef-backend
  mount /dev/sdb1 /var/opt/chef-backend
}

frontend_format_disk () {
  apt-get install lvm2 xfsprogs sysstat atop ntp -y
  MNT_MOUNTED=`grep \/mnt /proc/mount || /bin/true`
  if [ -n "${MNT_MOUNTED}" ]; then
    umount -f /mnt
  fi
  pvcreate -f /dev/sdb1
  vgcreate chef-vg /dev/sdb1
  lvcreate -n chef-data -l 20%VG chef-vg
  lvcreate -n chef-logs -l 70%VG chef-vg
  mkfs.xfs /dev/chef-vg/chef-data
  mkfs.xfs /dev/chef-vg/chef-logs
  mkdir -p /var/opt/opscode
  mkdir -p /var/log/opscode
  mount /dev/chef-vg/chef-data /var/opt/opscode
  mount /dev/chef-vg/chef-logs /var/log/opscode
}

backend_prepare_package () {
  apt-get install -y chef-backend
  # Grab IP address and prepopulate configuration
  IPADRESS=`ifconfig eth0 | awk '/inet addr/{print substr($2,6)}'`
  cat > /etc/chef-backend/chef-backend.rb <<EOF
publish_address '${IPADRESS}'
postgresql.log_min_duration_statement = 500
elasticsearch.heap_size = 3500
EOF
}

frontend_prepare_package () {
  apt-get install -y chef-server-core chef-manage
  curl -o /etc/opscode/chef-server.rb "${SECRETS_LOCATION}/chef-server.rb.`hostname -s`${SAS_TOKEN}"

  cat >> /etc/opscode/chef-server.rb <<EOF
opscode_erchef['s3_url_expiry_window_size'] = '100%'
license['nodes'] = 999999
oc_chef_authz['http_init_count'] = 100
oc_chef_authz['http_max_count'] = 100
oc_chef_authz['http_queue_max'] = 200
oc_bifrost['db_pool_size'] = 20
oc_bifrost['db_pool_queue_max'] = 40
oc_bifrost['db_pooler_timeout'] = 2000
opscode_erchef['depsolver_worker_count'] = 4
opscode_erchef['depsolver_timeout'] = 20000
opscode_erchef['db_pool_size'] = 20
opscode_erchef['db_pool_queue_max'] = 40
opscode_erchef['db_pooler_timeout'] = 2000
opscode_erchef['authz_pooler_timeout'] = 2000
EOF
}

backend_create_cluster () {
  chef-backend-ctl create-cluster --accept-license --yes --verbose
}

backend_join_cluster () {
  chef-backend-ctl join-cluster 10.0.0.10 -s chef-backend-secrets.json --accept-license --yes --verbose
}

frontend_reconfigure () {
  chef-server-ctl reconfigure --accept-license
  chef-manage-ctl reconfigure --accept-license
}

backend_upload_secrets () {
  curl --retry 3 --show-error --upload-file /etc/chef-backend/chef-backend-secrets.json "${SECRETS_LOCATION}/chef-backend-secrets.json${SAS_TOKEN}" --header "x-ms-blob-type: BlockBlob"

  FRONTENDS="fe0 fe1 fe2"
  for fe in $FRONTENDS; do
  chef-backend-ctl gen-server-config ${fe} -f chef-server.rb.${fe}
  curl --retry 3 --show-error --upload-file chef-server.rb.${fe} "${SECRETS_LOCATION}/chef-server.rb.${fe}${SAS_TOKEN}" --header "x-ms-blob-type: BlockBlob"
  done
}

backend_download_secrets () {
  curl --retry 3 --show-error -o chef-backend-secrets.json "${SECRETS_LOCATION}/chef-backend-secrets.json${SAS_TOKEN}"
}

frontend_upload_secrets () {
  CONFIG_FILES="private-chef-secrets.json webui_priv.pem webui_pub.pem pivotal.pem"
  for file in $CONFIG_FILES; do
    curl --retry 3 --silent --show-error --upload-file /etc/opscode/${file} "${SECRETS_LOCATION}/${file}${SAS_TOKEN}" --header "x-ms-blob-type: BlockBlob"
  done
  curl --retry 3 --silent --show-error --upload-file /var/opt/opscode/upgrades/migration-level "${SECRETS_LOCATION}/migration-level${SAS_TOKEN}" --header "x-ms-blob-type: BlockBlob"
}

frontend_download_secrets () {
  CONFIG_FILES="private-chef-secrets.json webui_priv.pem webui_pub.pem pivotal.pem"
  for file in $CONFIG_FILES; do
    curl --retry 3 --silent --show-error -o /etc/opscode/${file} "${SECRETS_LOCATION}/${file}${SAS_TOKEN}"
  done
  mkdir -p /var/opt/opscode/upgrades/
  curl --retry 3 --silent --show-error -o /var/opt/opscode/upgrades/migration-level "${SECRETS_LOCATION}/migration-level${SAS_TOKEN}"
  touch /var/opt/opscode/bootstrapped
}

enable_monitoring () {
  echo 'ENABLED="true"' > /etc/default/sysstat
  service sysstat start
}

backend_setup() {
  case $LEADER in
    true)
      backend_format_disk_zfs
      backend_prepare_package
      backend_create_cluster
      backend_upload_secrets
    ;;
    false)
      backend_format_disk_zfs
      backend_prepare_package
      backend_download_secrets
      backend_join_cluster
    ;;
    *)
    echo "Unknown value for --leader: $ROLE"
    echo -e $usage
    exit 1
    ;;
  esac
}

frontend_setup() {
  case $LEADER in
    true)
      frontend_format_disk
      frontend_prepare_package
      frontend_reconfigure
      frontend_upload_secrets
    ;;
    false)
      frontend_format_disk
      frontend_prepare_package
      frontend_download_secrets
      frontend_reconfigure
    ;;
    *)
    echo "Unknown value for --leader: $ROLE"
    echo -e $usage
    exit 1
    ;;
  esac
}


#######################
# main
#######################

echo "Performing setup for role: $ROLE, leader: $LEADER, secrets location ${SECRETS_LOCATION}"

setup_repo

case $ROLE in
  backend)
    backend_setup
  ;;
  frontend)
    frontend_setup
  ;;
  *)
  echo "Unknown role $ROLE"
  echo -e $usage
  exit 1
  ;;
esac

enable_monitoring

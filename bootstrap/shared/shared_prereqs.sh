#!/bin/bash
# Exit immediately if anything goes wrong, instead of making things worse.
set -e

if [[ ! -z $BOOTSTRAP_HTTP_PROXY_URL ]] || [[ ! -z $BOOTSTRAP_HTTPS_PROXY_URL ]] ; then
  echo "Testing configured proxies..."
  source $REPO_ROOT/bootstrap/shared/shared_proxy_setup.sh
fi

REQUIRED_VARS=( BOOTSTRAP_CACHE_DIR REPO_ROOT )
check_for_envvars ${REQUIRED_VARS[@]}

# List of binary versions to download
source $REPO_ROOT/bootstrap/config/build_bins_versions.sh

# Create directory for download cache.
mkdir -p $BOOTSTRAP_CACHE_DIR

# This is obscure to prevent cert dir test each time
if [[ -d "$BOOTSTRAP_ADDITIONAL_CACERTS_DIR" ]] && \
  [[ -x "$BOOTSTRAP_ADDITIONAL_CACERTS_DIR" ]]; then
  curl_cmd() {
    curl -f --capath "$BOOTSTRAP_ADDITIONAL_CACERTS_DIR" --progress -L \
      -H 'Accept-encoding: gzip,deflate' "$@"
  }
else
  curl_cmd() {
    curl -f --progress -L -H 'Accept-encoding: gzip,deflate' "$@"
  }
fi

# download_file wraps the usual behavior of curling a remote URL to a local file
download_file() {
  FILE=$1
  URL=$2

  # remove failed file download
  if [[ -f $BOOTSTRAP_CACHE_DIR/$FILE && ! -f $BOOTSTRAP_CACHE_DIR/${FILE}_downloaded ]]; then
    rm -f $BOOTSTRAP_CACHE_DIR/$FILE
  fi

  if [[ ! -f $BOOTSTRAP_CACHE_DIR/$FILE && ! -f $BOOTSTRAP_CACHE_DIR/${FILE}_downloaded ]]; then
    echo $FILE
    rm -f $BOOTSTRAP_CACHE_DIR/$FILE
    curl -L --progress-bar -o $BOOTSTRAP_CACHE_DIR/$FILE $URL
    if [[ $? != 0 ]]; then
      echo "Received error when attempting to download from ${URL}."
    fi
    touch $BOOTSTRAP_CACHE_DIR/${FILE}_downloaded
  fi
}

# cleanup_cookbook removes all but the specified cookbook version so that we
# don't keep old cookbook versions and clobber them when decompressing
cleanup_cookbook() {
  COOKBOOK=$1
  VERSION_TO_KEEP=$2

  # this syntax should work with both BSD and GNU find (for building on OS X and Linux)
  find ${BOOTSTRAP_CACHE_DIR}/cookbooks/ -name ${COOKBOOK}-\*.tar.gz -and -not -name ${COOKBOOK}-${VERSION_TO_KEEP}.tar.gz -delete && true
  find ${BOOTSTRAP_CACHE_DIR}/cookbooks/ -name ${COOKBOOK}-\*.tar.gz_downloaded -and -not -name ${COOKBOOK}-${VERSION_TO_KEEP}.tar.gz_downloaded -delete && true
}

# download_cookbook wraps download_file for retrieving cookbooks
download_cookbook() {
  COOKBOOK=$1
  VERSION_TO_GET=$2

  download_file cookbooks/${COOKBOOK}-${VERSION_TO_GET}.tar.gz http://cookbooks.opscode.com/api/v1/cookbooks/${COOKBOOK}/versions/${VERSION_TO_GET}/download
}

# cleanup_and_download_cookbook wraps both cleanup_cookbook and download_cookbook
cleanup_and_download_cookbook() {
  COOKBOOK=$1
  TARGET_VERSION=$2

  cleanup_cookbook ${COOKBOOK} ${TARGET_VERSION}
  download_cookbook ${COOKBOOK} ${TARGET_VERSION}
}

# Clones a repo and attempts to pull updates if requested version does not exist
clone_repo() {
  local repo_url="$1"
  local local_dir="$2"
  local version="$3"

  local git_args=
  if [[ -d "$BOOTSTRAP_ADDITIONAL_CACERTS_DIR" ]] && \
    [[ -x "$BOOTSTRAP_ADDITIONAL_CACERTS_DIR" ]]; then
    git_args="-c http.sslCAPath=$BOOTSTRAP_ADDITIONAL_CACERTS_DIR"
  fi
  if [[ -d "$BOOTSTRAP_CACHE_DIR/$local_dir/.git" ]]; then
    pushd "$BOOTSTRAP_CACHE_DIR/$local_dir"
    git log --pretty=format:'%H' | \
    grep -q "$version" || \
    git $git_args pull
    popd
  else
    git $git_args clone "$repo_url" "$BOOTSTRAP_CACHE_DIR/$local_dir"
  fi
}

# This uses ROM-o-Matic to generate a custom PXE boot ROM.
# (doesn't use the function because of the unique curl command)
ROM=gpxe-1.0.1-80861004.rom
if [[ -f $BOOTSTRAP_CACHE_DIR/$ROM && ! -f $BOOTSTRAP_CACHE_DIR/${ROM}_downloaded ]]; then
  rm -f $BOOTSTRAP_CACHE_DIR/$ROM
fi
if [[ ! -f $BOOTSTRAP_CACHE_DIR/$ROM && ! -f $BOOTSTRAP_CACHE_DIR/${ROM}_downloaded ]]; then
  echo $ROM
  rm -f $BOOTSTRAP_CACHE_DIR/$ROM
  curl -L --progress-bar -o $BOOTSTRAP_CACHE_DIR/$ROM "http://rom-o-matic.net/gpxe/gpxe-1.0.1/contrib/rom-o-matic/build.php" -H "Origin: http://rom-o-matic.net" -H "Host: rom-o-matic.net" -H "Content-Type: application/x-www-form-urlencoded" -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" -H "Referer: http://rom-o-matic.net/gpxe/gpxe-1.0.1/contrib/rom-o-matic/build.php" -H "Accept-Charset: ISO-8859-1,utf-8;q=0.7,*;q=0.3" --data "version=1.0.1&use_flags=1&ofmt=ROM+binary+%28flashable%29+image+%28.rom%29&nic=all-drivers&pci_vendor_code=8086&pci_device_code=1004&PRODUCT_NAME=&PRODUCT_SHORT_NAME=gPXE&CONSOLE_PCBIOS=on&BANNER_TIMEOUT=20&NET_PROTO_IPV4=on&COMCONSOLE=0x3F8&COMSPEED=115200&COMDATA=8&COMPARITY=0&COMSTOP=1&DOWNLOAD_PROTO_TFTP=on&DNS_RESOLVER=on&NMB_RESOLVER=off&IMAGE_ELF=on&IMAGE_NBI=on&IMAGE_MULTIBOOT=on&IMAGE_PXE=on&IMAGE_SCRIPT=on&IMAGE_BZIMAGE=on&IMAGE_COMBOOT=on&AUTOBOOT_CMD=on&NVO_CMD=on&CONFIG_CMD=on&IFMGMT_CMD=on&IWMGMT_CMD=on&ROUTE_CMD=on&IMAGE_CMD=on&DHCP_CMD=on&SANBOOT_CMD=on&LOGIN_CMD=on&embedded_script=&A=Get+Image"
  touch $BOOTSTRAP_CACHE_DIR/${ROM}_downloaded
fi

# Obtain an Ubuntu netboot image to be used for PXE booting.
download_file ubuntu-14.04-mini.iso http://archive.ubuntu.com/ubuntu/dists/trusty-updates/main/installer-amd64/current/images/netboot/mini.iso

# Obtain the VirtualBox guest additions ISO for use with Ansible.
VBOX_VERSION=5.0.10
VBOX_ADDITIONS=VBoxGuestAdditions_$VBOX_VERSION.iso
download_file $VBOX_ADDITIONS http://download.virtualbox.org/virtualbox/$VBOX_VERSION/$VBOX_ADDITIONS

# Obtain a Vagrant Trusty box.
BOX=trusty-server-cloudimg-amd64-vagrant-disk1.box
download_file $BOX http://cloud-images.ubuntu.com/vagrant/trusty/current/$BOX

# Obtain Chef client and server DEBs.
CHEF_CLIENT_DEB=${CHEF_CLIENT_DEB:-chef_12.9.41-1_amd64.deb}
CHEF_SERVER_DEB=${CHEF_SERVER_DEB:-chef-server-core_12.6.0-1_amd64.deb}
download_file $CHEF_CLIENT_DEB https://packages.chef.io/stable/ubuntu/10.04/$CHEF_CLIENT_DEB
download_file $CHEF_SERVER_DEB https://packages.chef.io/stable/ubuntu/14.04/$CHEF_SERVER_DEB

# Pull needed cookbooks from the Chef Supermarket (and remove the previous
# versions if present). Versions are pulled from build_bins_versions.sh.
mkdir -p $BOOTSTRAP_CACHE_DIR/cookbooks
cleanup_and_download_cookbook apt ${VER_APT_COOKBOOK}
cleanup_and_download_cookbook chef-client ${VER_CHEF_CLIENT_COOKBOOK}
cleanup_and_download_cookbook chef_handler ${VER_CHEF_HANDLER_COOKBOOK}
cleanup_and_download_cookbook concat ${VER_CONCAT_COOKBOOK}
cleanup_and_download_cookbook cron ${VER_CRON_COOKBOOK}
cleanup_and_download_cookbook hostsfile ${VER_HOSTSFILE_COOKBOOK}
cleanup_and_download_cookbook logrotate ${VER_LOGROTATE_COOKBOOK}
cleanup_and_download_cookbook ntp ${VER_NTP_COOKBOOK}
cleanup_and_download_cookbook ubuntu ${VER_UBUNTU_COOKBOOK}
cleanup_and_download_cookbook windows ${VER_WINDOWS_COOKBOOK}
cleanup_and_download_cookbook yum ${VER_YUM_COOKBOOK}

# Pull knife-acl gem.
download_file knife-acl-1.0.2.gem https://rubygems.global.ssl.fastly.net/gems/knife-acl-1.0.2.gem

# Pull needed gems for fpm.
GEMS=( arr-pm-0.0.10 backports-3.6.4 cabin-0.7.1 childprocess-0.5.6 clamp-0.6.5 ffi-1.9.8
       fpm-1.3.3 json-1.8.2 )
mkdir -p $BOOTSTRAP_CACHE_DIR/fpm_gems
for GEM in ${GEMS[@]}; do
  download_file fpm_gems/$GEM.gem https://rubygems.global.ssl.fastly.net/gems/$GEM.gem
done

# Pull needed gems for fluentd.
GEMS=( excon-0.45.3
       multi_json-1.11.2 multipart-post-2.0.0 faraday-0.9.1
       elasticsearch-api-1.0.12 elasticsearch-transport-1.0.12
       elasticsearch-1.0.12 fluent-plugin-elasticsearch-0.9.0 )
mkdir -p $BOOTSTRAP_CACHE_DIR/fluentd_gems
for GEM in ${GEMS[@]}; do
  download_file fluentd_gems/$GEM.gem https://rubygems.global.ssl.fastly.net/gems/$GEM.gem
done

# Obtain Cirros image.
download_file cirros-0.3.4-x86_64-disk.img http://download.cirros-cloud.net/0.3.4/cirros-0.3.4-x86_64-disk.img

# Obtain various items used for monitoring.
# Remove obsolete kibana package
rm -f $BOOTSTRAP_CACHE_DIR/kibana-4.0.2-linux-x64.tar.gz_downloaded $BOOTSTRAP_CACHE_DIR/kibana-4.0.2-linux-x64.tar.gz
# Remove obsolete cached items for BrightCoveOS Diamond
rm -rf $BOOTSTRAP_CACHE_DIR/diamond_downloaded $BOOTSTRAP_CACHE_DIR/diamond


clone_repo https://github.com/python-diamond/Diamond python-diamond $VER_DIAMOND
clone_repo https://github.com/mobz/elasticsearch-head elasticsearch-head $VER_ESPLUGIN

download_file pyrabbit-1.0.1.tar.gz https://pypi.python.org/packages/source/p/pyrabbit/pyrabbit-1.0.1.tar.gz
download_file requests-aws-0.1.6.tar.gz https://pypi.python.org/packages/source/r/requests-aws/requests-aws-0.1.6.tar.gz
download_file pyzabbix-0.7.3.tar.gz https://pypi.python.org/packages/source/p/pyzabbix/pyzabbix-0.7.3.tar.gz
download_file pagerduty-zabbix-proxy.py https://gist.githubusercontent.com/ryanhoskin/202a1497c97b0072a83a/raw/96e54cecdd78e7990bb2a6cc8f84070599bdaf06/pd-zabbix-proxy.py

download_file carbon-${VER_GRAPHITE_CARBON}.tar.gz http://pypi.python.org/packages/source/c/carbon/carbon-${VER_GRAPHITE_CARBON}.tar.gz
download_file whisper-${VER_GRAPHITE_WHISPER}.tar.gz http://pypi.python.org/packages/source/w/whisper/whisper-${VER_GRAPHITE_WHISPER}.tar.gz
download_file graphite-web-${VER_GRAPHITE_WEB}.tar.gz http://pypi.python.org/packages/source/g/graphite-web/graphite-web-${VER_GRAPHITE_WEB}.tar.gz

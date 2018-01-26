#!/bin/bash
#
# Author: Kris Zentner
# Date: January, 2018
#
# Express Route Linux Cluster Maker! Internet Facing Edition
#
# This script attempts to create a resource group with resources needed
# to make a cluster. Where possible it performs operations in parallel.
# GNU Parallel will default run one job per CPU on your workstation.
# If you want more, adjust the PARALLEL option
#
# Dependencies:
# jq
# GNU parallel
# azure cli https://github.com/Azure/azure-cli
#
# If you're not using ssh keys, you'll need to put your vm's password
# in ./myvm.pass 
#
# I tend to use a custom script to install Chef at boot time.
# If you have a custom script in an Azure blob you'll need to create a ./protected.json
# like so:
# {
#   "commandToExecute": "./azureinstall.sh",
#   "fileUris": ["https://myazureblob.blob.core.windows.net/linux/scripts/azureinstall.sh"]
# }
#
# and a ./azureinstall.json like so:
# {
#  "storageAccountName": "myazureblob",
#  "storageAccountKey": "i8Goh+ciGLWmSWNIvzjkw+iGlrsF7r1WCmpNCv8ZcmQJ4CdLuXgZVJVgP2tWrXP7u/ddFAwQBzYy2Cjx5FxHig=="
# }
#
#
# Not responsible for any damages as a result of using this script!
# Test it yourself before using.
#
#
subscription="mysubscription"
export rg="mytestcluster"
prefix="testnode"
size="Standard_D1_v2"
vnet="gcrtestcluster-vnet"
prefix="clusternode"
size="Standard_F8s"
subnet="10.0.1."
seqstart="1"
numvms="4"
# Padding 2 means 01 02 etc..
padding="2"
location="westus2"
image="Canonical:UbuntuServer:16.04-LTS:latest"
# Set this to 0 if you don't want data disks
numdatadisks="1"
datadisksize="1024"
# Run Custom Script?
install_script="YES"
# Enable diagnostics storage account?
enable_diag="YES"
# Create a load balancer?
create_lb="YES"
export diagstorageacct="${rg}diag"
# Public DNS?
public_dns="YES"
vmusername="ubuntu"
myvmpass=`cat ./myvm.pass`
subnet_id="$rg-subnet"
# If you want manually specified different disks, set numdatadisks="OVERRIDE"
# and can set the below to something like: diskvar="--data-disk-sizes-gb 1024 10 5"
if [ "$numdatadisks" -ne "0" ];then
  diskvar="--data-disk-sizes-gb "
else
  diskvar=""
fi
if [ "$numdatadisks" != "OVERRIDE" ];then
  for i in $(seq 1 $numdatadisks);do
    diskvar="$diskvar $datadisksize"
  done
fi
if [ "$public_dns" == "YES" ];then
  publicdnsopt="--public-ip-address-dns-name ${prefix}${padded}"
else
  publicdnsopt=""
fi
i=0

az account set --subscription "$subscription"
az group create -l $location -n $rg
az network vnet create -g $rg -n $vnet --address-prefix ${subnet}0/24 --subnet-name "$rg-subnet"

# NSG Section
# You'll want to run nsgmake.ps1 against this later...
az network nsg create -g $rg -n "$rg-nsg"
az network nsg rule create -g $rg \
   -n allow-ssh \
  --access allow \
  --destination-address-prefix '*' \
  --destination-port-range 22 \
  --direction inbound \
  --nsg-name "$rg-nsg" \
  --protocol tcp \
  --source-address-prefix '*' \
  --source-port-range '*' \
  --priority 1000
# Apply NSG to our network
az network vnet subnet update -g $rg \
  -n "$rg-subnet" \
  --vnet-name "$rg-vnet" \
  --network-security-group "$rg-nsg"

# Public addr for LB
if [ "$create_lb" == "YES" ];then
  az network lb create -g $rg \
    -n "$rg-lb" \
    --backend-pool-name $rg-lb-pool \
    --public-ip-address $rg-pip \
    --public-ip-address-allocation static
fi
az vm availability-set create -g $rg -n "$rg-avset"
echo "[$rg] Creating Diagnostics Storage Account..."
if [ "$enable_diag" == "YES" ];then
  az storage account create -n "${rg}diag" -g $rg -l $location --sku Standard_LRS
fi

seq -f "%0${padding}g" $seqstart $numvms|parallel $numjobs "
  echo '[$prefix ${i}] Creating public IP...'
  az network public-ip create -n ${prefix}${}-pip -g $rg > /dev/null
"
# Lets make our NICS in parallel
seq -f "%0${padding}g" $seqstart $numvms|parallel $numjobs "
 echo '[$prefix{}] Creating NIC...'
  az network nic create -g $rg \
    -n ${prefix}${}-nic \
    --private-ip-address ${subnet}$(( $i+5 )) \
    --public-ip-address ${prefix}${}-pip \
    --vnet $vnet \
    --subnet  $subnet_id \
    --ip-forwarding
"
# Lets make our VMs in parallel
echo "Starting VM Creation..."
seq -f "%0${padding}g" $seqstart $numvms|parallel $numjobs "
echo \"[$prefix{}] Creating VM...\"
  echo "[$prefix{}] Creating VM..."
  az vm create -g $rg \
    -n $prefix{} \
    --image $image \
    --nics $prefix${}-nic \
    --availability-set "$rg-avset" \
    --size $size \
    --nsg '' > /dev/null \
    $diskvar \
    $publicdnsopt \
    --admin-username $vmusername \
    --authentication-type password \
    --admin-password '$myvmpass'
"
# Install Custom Script in parallel
if [ "$install_script" == "YES" ];then
  echo "Starting Custom Script Installation..."
  seq -f "%0${padding}g" $seqstart $numvms|parallel $numjobs "
  echo '[$prefix{}] Installing Custom Script...'
  az vm extension set \
  --resource-group $rg \
  --vm-name $prefix{} \
  --name customScript \
  --publisher Microsoft.Azure.Extensions \
  --version 2.0 \
  --protected-settings ./protected.json \
  --settings ./azureinstall.json"
fi
# Apply diagnostics in parallel
if [ "$enable_diag" == "YES" ];then
  #See https://docs.microsoft.com/en-us/cli/azure/vm/diagnostics?view=azure-cli-latest#az_vm_diagnostics_set
  enable_diag (){
    seq=$1
    vmname="${prefix}${seq}"
    if [ ! -d tmp ];then mkdir tmp;fi
    echo "[${vmname}] Enabling Diagnostics..."
    az vm boot-diagnostics enable --resource-group ${rg} --name ${vmname} --storage "${bloburi}"
    vm_resource_id=$(az vm show -g ${rg} -n ${vmname} --query "id" -o tsv)
    az vm diagnostics get-default-config | sed "s#__DIAGNOSTIC_STORAGE_ACCOUNT__#${diagstorageacct}#g"     | sed "s#__VM_OR_VMSS_RESOURCE_ID__#$vm_resource_id#g" > tmp/$vmname.json
    storage_sastoken=$(az storage account generate-sas --account-name ${diagstorageacct} --expiry 9999-12-31T23:59Z --permissions wlacu --resource-types co --services bt -o tsv)
    protected_settings="{'storageAccountName': '${diagstorageacct}', 'storageAccountSasToken': '${storage_sastoken}'}"
    az vm diagnostics set --settings "${default_config}" --protected-settings "${protected_settings}" --resource-group $rg --vm-name $vmname
    az vm extension set --publisher Microsoft.Azure.Diagnostics \
      --name LinuxDiagnostic \
      --version 3.0 \
      --resource-group ${rg} \
      --vm-name "${vmname}" \
      --protected-settings "${protected_settings}" \
      --settings tmp/${vmname}.json
    rm tmp/${vmname}.json
  }
  export -f enable_diag
  seq -f "%0${padding}g" $seqstart $numvms|parallel $numjobs "enable_diag {}"
fi
# Remove the temp dir if empty
rmdir tmp

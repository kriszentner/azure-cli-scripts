#!/bin/bash
#
# Author: Kris Zentner
# Date: January, 2018
#
# Express Route Linux Cluster Maker! ExpressRoute Edition
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
vnet="myvnet"
subnet="Subnet-1"
export rg="mytestcluster"
prefix="testnode"
size="Standard_D1_v2"
numvms="3"
seqstart="1"
# Padding 2 means 01 02 etc..
padding="2"
location="westus2"
image="Canonical:UbuntuServer:16.04-LTS:latest"
# Set this to 0 if you don't want data disks
numdatadisks="4"
datadisksize="4095"
# Install Chef?
install_script="YES"
# Enable diagnostics storage account?
enable_diag="YES"
# Adjusting the below to NUMJOBS="-j10" will run 10 parallel jobs at a time
# Default is your cpu count.
numjobs=""
export diagstorageacct="${rg}diag"
vmusername="ubuntu"
myvm=`cat ./myvm.pass`
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
i=0

az account set --subscription "$subscription"
subscription_id=$(az account show --subscription "$subscription"|jq -r '.id')
subnet_id=$( az network vnet subnet show --name ${vnet} --resource-group ERNetwork --vnet-name ${subnet}|jq -r '.id')
az group create -l $location -n $rg
az vm availability-set create -g $rg -n "$rg-avset"
echo "[$rg] Creating Diagnostics Storage Account..."
if [ "$enable_diag" == "YES" ];then
  az storage account create -n ${diagstorageacct} -g $rg -l $location --sku Standard_LRS
  export bloburi=$(az storage account show --resource-group myResourceGroupMonitor --name $diagstorageacct --query 'primaryEndpoints.blob' -o tsv)
fi
# Lets make our NICS in parallel
echo "Starting NIC Creation..."
seq -f "%0${padding}g" $seqstart $numvms|parallel $numjobs "
echo '[$prefix{}] Creating NIC...'
az network nic create -g $rg -n $prefix{}-nic --subnet '$subnet_id'"
# Lets make our VMs in parallel
echo "Starting VM Creation..."
seq -f "%0${padding}g" $seqstart $numvms|parallel $numjobs "
echo \"[$prefix{}] Creating VM...\"
az vm create -g $rg \
  -n $prefix{} \
  --image $image \
  --nics $prefix{}-nic \
  --availability-set $avsetname \
  $diskvar \
  --size $size \
  --nsg '' > /dev/null \
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

#!/usr/bin/env bash
#
# Author: Kris Zentner
# Date January, 2018
#
# This is meant to reallocate a hung Azure Linux VM, similar to the "redeploy" 
# Azure portal command, but this seems to work better in most cases.
# Dependencies:
# jq
# azure cli https://github.com/Azure/azure-cli
#
# Not responsible for any damages as a result of using this script!
# Test it yourself before using.
#
VMNAME="myvm"
RG="my_rg"
SUBSCRIPTION="my subscription"
az account set --subscription "$SUBSCRIPTION"
AVSET=$(az vm show -g $RG -n $VMNAME |jq -r '.availabilitySet.id'|awk -F/ '{ print $NF }')
OSDISK=$(az vm show -g $RG -n $VMNAME |jq -r '.storageProfile.osDisk.managedDisk.id')
DATADISKS=$(az vm show -g $RG -n $VMNAME |jq -r '.storageProfile.dataDisks'|jq '.[].name'|tr '\n' ' ')
OSDISKNAME=$(echo $OSDISK|awk -F/ '{ print $NF }')
NIC=$(az vm show -g $RG -n $VMNAME |jq '.networkProfile.networkInterfaces'|jq -r '.[0].id'|awk -F/ '{ print $NF }')
LOCATION=$(az vm show -g $RG -n $VMNAME |jq -r '.location')
SIZE=$(az vm show -g $RG -n $VMNAME |jq -r '.hardwareProfile.vmSize')
echo "Removing old VM $VMNAME"
az vm delete -g $RG -n $VMNAME --yes
# If you want to attach a disk to another VM
#
# NEWVMNAME="my new vm"
# az vm disk attach -g $RG --vm-name $NEWVMNAME --disk $OSDISK
# and then detach
# az vm disk detach -g $RG --vm-name $NEWVMNAME --name $OSDISKNAME
#
echo "Recreating VM $VMNAME"
az vm create -g $RG -n $VMNAME \
  --nics $NIC \
  --attach-os-disk $OSDISK \
  if [ "$AVSET" != "null" ];then
  --availability-set $AVSET \
  fi
  if [ ! -z $DATADISKS ];then
  --attach-data-disks $DATADISKS
  fi
  --size $SIZE \
  --location $LOCATION \
  --os-type Linux

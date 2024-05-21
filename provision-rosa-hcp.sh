#!/usr/bin/env bash

set -euo pipefail

print_help() {
  cat <<HELP

Usage: $0

Automation script to create Hosted Control Plane for JurongPort:

  --create-vpc          Create new VPC, subnets, NAT gateway
  --create-permission   Create new IAM roles and OIDC config
  --install-hcp         Install HCP cluster (Single AZ)

HELP
}

create_vpc()
{
	#
        # Hardcoded parameters (Script build for re-provisioning using same CIDR/Cluster name)
        #
        CLUSTER_NAME="jeretan"
        VPC_CIDR=10.0.0.0/16
        PUBLIC_CIDR_SUBNET=10.0.1.0/24
        PRIVATE_CIDR_SUBNET=10.0.0.0/24
    
        # Create VPC
	echo -n "Creating VPC..."
	VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR --query Vpc.VpcId --output text)

	# Create tag name
	aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=$CLUSTER_NAME

	# Enable dns hostname
	aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
	echo "done."

	# Create Public Subnet
	echo -n "Creating public subnet..."
	PUBLIC_SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $PUBLIC_CIDR_SUBNET --query Subnet.SubnetId --output text)

	aws ec2 create-tags --resources $PUBLIC_SUBNET_ID --tags Key=Name,Value=$CLUSTER_NAME-public
	echo "done."

	# Create private subnet
	echo -n "Creating private subnet..."
	PRIVATE_SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $PRIVATE_CIDR_SUBNET --query Subnet.SubnetId --output text)

	aws ec2 create-tags --resources $PRIVATE_SUBNET_ID --tags Key=Name,Value=$CLUSTER_NAME-private
	echo "done."

	# Create an internet gateway for outbound traffic and attach it to the VPC.
	echo -n "Creating internet gateway..."
	IGW_ID=$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text)
	echo "done."

	aws ec2 create-tags --resources $IGW_ID --tags Key=Name,Value=$CLUSTER_NAME

	aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID > /dev/null 2>&1
	echo "Attached IGW to VPC."

	# Create a route table for outbound traffic and associate it to the public subnet.
	echo -n "Creating route table for public subnet..."
	PUBLIC_ROUTE_TABLE_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --query RouteTable.RouteTableId --output text)

	aws ec2 create-tags --resources $PUBLIC_ROUTE_TABLE_ID --tags Key=Name,Value=$CLUSTER_NAME
	echo "done."

	aws ec2 create-route --route-table-id $PUBLIC_ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID > /dev/null 2>&1
	echo "Created default public route."

	aws ec2 associate-route-table --subnet-id $PUBLIC_SUBNET_ID --route-table-id $PUBLIC_ROUTE_TABLE_ID > /dev/null 2>&1
	echo "Public route table associated"

	# Create a NAT gateway in the public subnet for outgoing traffic from the private network.
	echo -n "Creating NAT Gateway..."
	NAT_IP_ADDRESS=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
	NAT_GATEWAY_ID=$(aws ec2 create-nat-gateway --subnet-id $PUBLIC_SUBNET_ID --allocation-id $NAT_IP_ADDRESS --query NatGateway.NatGatewayId --output text)
	aws ec2 create-tags --resources $NAT_IP_ADDRESS --resources $NAT_GATEWAY_ID --tags Key=Name,Value=$CLUSTER_NAME
	sleep 10
	echo "done."

	# Create a route table for the private subnet to the NAT gateway.
	echo -n "Creating a route table for the private subnet to the NAT gateway..."
	PRIVATE_ROUTE_TABLE_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --query RouteTable.RouteTableId --output text)

	aws ec2 create-tags --resources $PRIVATE_ROUTE_TABLE_ID $NAT_IP_ADDRESS --tags Key=Name,Value=$CLUSTER_NAME-private
	aws ec2 create-route --route-table-id $PRIVATE_ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $NAT_GATEWAY_ID > /dev/null 2>&1
	aws ec2 associate-route-table --subnet-id $PRIVATE_SUBNET_ID --route-table-id $PRIVATE_ROUTE_TABLE_ID > /dev/null 2>&1

	echo "done."

	# echo "***********VARIABLE VALUES*********"
	# echo "VPC_ID="$VPC_ID
	# echo "PUBLIC_SUBNET_ID="$PUBLIC_SUBNET_ID
	# echo "PRIVATE_SUBNET_ID="$PRIVATE_SUBNET_ID
	# echo "PUBLIC_ROUTE_TABLE_ID="$PUBLIC_ROUTE_TABLE_ID
	# echo "PRIVATE_ROUTE_TABLE_ID="$PRIVATE_ROUTE_TABLE_ID
	# echo "NAT_GATEWAY_ID="$NAT_GATEWAY_ID
	# echo "IGW_ID="$IGW_ID
	# echo "NAT_IP_ADDRESS="$NAT_IP_ADDRESS

	echo "VPC Setup complete"
        echo "##############################################"
        echo "export PUBLIC_SUBNET_ID=$PUBLIC_SUBNET_ID"
        echo "export PRIVATE_SUBNET_ID=$PRIVATE_SUBNET_ID"
        echo "##############################################"
}

create_permission()
{
	#
	# Hardcoded parameters (Script build for re-provisioning using same IAM ROLE and OIDC)
        #
        ACCOUNT_ROLES_PREFIX=jeretan-hcp
        OPERATOR_ROLES_PREFIX=jeretan-hcp
        AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

        echo -n "Creating Account ROLES..."
	rosa create account-roles --hosted-cp --prefix $ACCOUNT_ROLES_PREFIX --mode auto
	echo "done."

        echo -n "Creating oidc..."
        OIDC_ID=$(rosa create oidc-config --mode auto --managed --yes -o json | jq -r '.id')
	echo "done."

        echo -n "Creating Operator ROLES..."
        rosa create operator-roles --hosted-cp --mode auto \
             --prefix $OPERATOR_ROLES_PREFIX \
	     --oidc-config-id $OIDC_ID \
	     --installer-role-arn arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ACCOUNT_ROLES_PREFIX}-HCP-ROSA-Installer-Role
	echo "done."

	echo "Permission Setup complete"
        echo "##############################################"
        echo "export PUBLIC_SUBNET_ID=$PUBLIC_SUBNET_ID"
        echo "export PRIVATE_SUBNET_ID=$PRIVATE_SUBNET_ID"
        echo "##############################################"
}

install_hcp()
{

  echo "Installing ROSA HCP"

  rosa create cluster --sts --hosted-cp --mode=auto \
     --cluster-name=$CLUSTER_NAME \
     --region=ap-southeast-1 \
     --subnet-ids=$SUBNET_IDS \
     --oidc-config-id=$OIDC_ID \
     --operator-roles-prefix $OPERATOR_ROLES_PREFIX \
}

#
# Check AWS and ROSA CLI are installed
#
echo -n "Checking for AWS CLI... "
if ! command -v aws &> /dev/null
then
  echo "Failed"
  cat <<AWS
  aws cli not found !
  Make sure these steps are followed:
    $ curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    $ unzip awscliv2.zip
    $ sudo ./aws/install
AWS
  exit 1
else
  echo "Pass"
fi

echo -n "Checking for ROSA CLI... "
if ! command -v rosa &> /dev/null
then
  echo "Failed"
  cat <<ROSA
  rosa cli not found !
  Make sure these steps are followed:
    $ wget https://mirror.openshift.com/pub/openshift-v4/clients/rosa/latest/rosa-linux.tar.gz
    $ tar zxvf rosa-linux.tar.gz
    $ sudo mv rosa /usr/local/bin
ROSA
  exit 1
else
  echo "Pass"
fi

#
# Check AWS access
#
echo -n "Checking if you have AWS permission... "
if [[ ! $(aws sts get-caller-identity --query "Account" --output text 2>/dev/null) =~ [0-9A-Z] ]]
then
  echo "Failed"
  cat <<AWSCONFIG
  Ensure AWS access keys are configured
    $ aws configure
    AWS Access Key ID [None]: accesskey
    AWS Secret Access Key [None]: secretkey
    Default region name [None]: ap-southeast-1
    Default output format [None]:
AWSCONFIG
  exit 2
else
  echo "Pass"
fi

#
# Check ROSA token
#
echo -n "Checking if you have ROSA permission... "
if [[ ! $(rosa whoami 2>/dev/null |awk '/OCM Account ID/ {print $4}') =~ [0-9a-zA-Z] ]]
then
  echo "Failed"
  cat <<TOKEN
  Retrieve token from https://console.redhat.com/openshift/token/rosa
    $ rosa login --token="xxxxx"
TOKEN
  exit 2
else
  echo "Pass"
fi

echo -n "Checking if you have variable file... "
if [ ! -f variable.txt ]; then
  echo "Variables file not found!"
  exit 1
fi

if [ $# -eq 0 ]; then
  print_help
  exit 1
elif [ $# -eq 2 ]; then
  echo "Only 1 option can be selected"
  exit 1
fi

while [[ -n "${1-}" ]]; do
  case "$1" in
    --create-vpc)
      create_vpc
      exit 0
      ;;
    --create-oidc)
      create_oidc
      exit 0
      ;;
    --install-hcp)
      install_hcp
      exit 0
      ;;
    --help)
      print_help
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      print_help
      exit 1
      ;;
  esac
  shift || true
done



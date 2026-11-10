# Lab 05 — Route 53 Public vs Private Hosted Zone

## Overview

This lab demonstrates how to troubleshoot DNS resolution problems caused by public and private Amazon Route 53 hosted zones sharing the same domain name.

We create an Amazon VPC, deploy an EC2 Linux troubleshooting client, and configure two Route 53 hosted zones using the same DNS namespace.

One hosted zone is public, while the other is private and associated with the VPC.

We intentionally create an application A record only in the public hosted zone.

When the EC2 instance queries the hostname through the VPC DNS Resolver, it receives an `NXDOMAIN` response because the matching private hosted zone does not contain the record.

We investigate the different DNS views using `dig`, `nslookup`, `getent`, and AWS CLI.

After identifying the missing private DNS record, we create the correct A record in the private hosted zone and verify successful resolution.

Finally, we delete both hosted zones and all temporary AWS infrastructure.

**Troubleshooting workflow:**

Infrastructure Setup → Public and Private Hosted Zones → Missing Private Record → DNS Investigation → Root Cause Analysis → Remediation → Verification → Cleanup

---

## 1. Lab Information

| Item | Configuration |
|---|---|
| Incident ID | INC-R53-005 |
| Difficulty | Intermediate |
| AWS Region | `us-east-1` |
| AWS Services | Route 53, VPC, EC2, IAM, Systems Manager |
| Local Environment | WSL Ubuntu |
| EC2 Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| VPC CIDR | `10.57.0.0/16` |
| Public Subnet | `10.57.1.0/24` |
| DNS Namespace | `lab05.route53.test` |
| Public Hosted Zone | `lab05.route53.test` |
| Private Hosted Zone | `lab05.route53.test` |
| Application Hostname | `app.lab05.route53.test` |
| Public A Record | `203.0.113.10` |
| Private A Record | `10.57.1.100` |
| Record TTL | 60 seconds |
| VPC DNS Resolver | `10.57.0.2` |
| Fault Injection | A record exists only in public zone |
| Expected Error | NXDOMAIN through VPC Resolver |
| Root Cause | Missing record in matching private zone |
| Remediation | Create private A record |
| Verification | AWS CLI, dig, nslookup, getent |

---

## 2. Production Incident Scenario

### Incident Description

A company uses a single DNS namespace for both public-facing and internal applications.

The company manages two Amazon Route 53 hosted zones with the same domain name.

The public hosted zone stores DNS records intended for external users.

The private hosted zone stores internal DNS records and is associated with the company's AWS VPC.

An application is configured with the hostname:

`app.lab05.route53.test`

A DNS administrator creates an A record in the public hosted zone but forgets to create the corresponding record in the private hosted zone.

The public A record points to:

`203.0.113.10`

However, an EC2 instance inside the VPC cannot resolve the hostname through the VPC Resolver.

The DNS lookup returns:

```text
status: NXDOMAIN
```

The Cloud Engineer must determine why the record exists in Route 53 but cannot be resolved inside the VPC.

### Incident Symptoms

- A public Route 53 hosted zone exists.
- A private hosted zone exists with the same domain name.
- The public hosted zone contains the application A record.
- The private hosted zone does not contain the application A record.
- Direct queries to the public authoritative nameserver succeed.
- DNS queries through the VPC Resolver return NXDOMAIN.
- General DNS resolution inside the VPC works.
- Creating the matching private record restores internal resolution.

### Business Impact

- Internal application hostname resolution fails.
- EC2 workloads cannot resolve the expected internal DNS name.
- Services relying on DNS may experience connection errors.
- Engineers may incorrectly investigate healthy application infrastructure.
- Inconsistent DNS views can complicate incident troubleshooting.

### Objective

Identify why a hostname resolves in one Route 53 hosted zone but not another, and restore the correct private DNS record without changing the public DNS configuration.

---

## 3. AWS Architecture

### Infrastructure Architecture

```text
                      AWS Region
                       us-east-1
                           |
                           v
                      Amazon VPC
                    10.57.0.0/16
                           |
                           v
                     Public Subnet
                    10.57.1.0/24
                           |
                           v
                    EC2 Linux Client
                    Amazon Linux 2023
                           |
                           v
                     DNS Query
                           |
                           v
                     VPC Resolver
                       10.57.0.2
                           |
                           v
              Matching Private Hosted Zone
                    lab05.route53.test
                           |
                           v
                  Application A Record
                        Missing
                           |
                           v
                        NXDOMAIN
```

### Public DNS View

```text
Public Hosted Zone
lab05.route53.test
        |
        v
app.lab05.route53.test
        |
        v
       A Record
        |
        v
    203.0.113.10
```

This answer is tested by querying one of the public hosted zone's Route 53 authoritative nameservers directly.

### Private DNS View Before Remediation

```text
EC2 Client
    |
    v
VPC DNS Resolver
    |
    v
Private Hosted Zone
    |
    v
Application A Record Missing
    |
    v
NXDOMAIN
```

### Private DNS View After Remediation

```text
EC2 Client
    |
    v
VPC DNS Resolver
    |
    v
Private Hosted Zone
    |
    v
app.lab05.route53.test
    |
    v
A Record
    |
    v
10.57.1.100
    |
    v
Successful DNS Resolution
```

### Network Configuration

| Resource | Configuration |
|---|---|
| VPC | `10.57.0.0/16` |
| Public Subnet | `10.57.1.0/24` |
| Internet Gateway | Attached |
| Public Route | `0.0.0.0/0` |
| EC2 Client | Amazon Linux 2023 |
| EC2 Management | Systems Manager |
| Private Hosted Zone | Associated with lab VPC |
| VPC Resolver | `10.57.0.2` |

Both A record addresses are demonstration values. This lab tests DNS resolution, not HTTP application availability.

---

## 4. Understanding Public and Private Hosted Zones

### What Is a Public Hosted Zone?

A public hosted zone is a container for DNS records intended to be answered by public authoritative DNS servers.

Example:

```text
app.example.com
       |
       v
Public Hosted Zone
       |
       v
203.0.113.10
```

For ordinary internet DNS resolution, the domain must have correct delegation from the parent DNS hierarchy.

### What Is a Private Hosted Zone?

A private hosted zone provides DNS resolution through associated AWS VPCs.

Example:

```text
app.example.com
       |
       v
VPC DNS Resolver
       |
       v
Private Hosted Zone
       |
       v
10.57.1.100
```

### Public vs Private Hosted Zone

| Feature | Public Hosted Zone | Private Hosted Zone |
|---|---|---|
| Main Purpose | Public DNS | Internal VPC DNS |
| VPC Association | Not required | Required |
| Public DNS Delegation | Required for normal public resolution | Not required |
| Internet DNS Visibility | With proper delegation | Not available through ordinary public DNS |
| Private IP Records | Supported | Supported |
| Same DNS Namespace | Supported | Supported |
| Example Target | Public IP | Private IP |

### What Happens When Both Zones Have the Same Name?

If an EC2 instance uses the VPC Resolver and its VPC is associated with a matching private hosted zone, the private hosted zone is selected for that namespace.

Example:

```text
Public Zone:  lab05.route53.test
Private Zone: lab05.route53.test
```

If the requested record is missing from the private hosted zone, Route 53 Resolver does not automatically fall back to the public hosted zone.

For a nonexistent DNS name, the result is NXDOMAIN.

### Why Use the `.test` Domain?

The `.test` namespace is reserved for testing.

In this lab, we create a public hosted zone for demonstration, but we do not register or delegate the domain.

Therefore, ordinary public DNS resolution is not expected to locate this hosted zone.

We directly query the public hosted zone's assigned authoritative nameservers instead.

### Important Security Note

A private hosted zone controls DNS visibility within supported AWS resolution paths.

It does not replace security groups, authentication, IAM authorization, or network isolation.

---

## 5. Prerequisites and Safety

### Requirements

- AWS account
- AWS CLI v2
- WSL Ubuntu
- Bash
- DNS utilities
- Route 53 permissions
- VPC permissions
- EC2 permissions
- IAM permissions
- Systems Manager access
- Git and GitHub

### Safety Rules

- Use a dedicated test DNS namespace.
- Do not modify production hosted zones.
- Never delete a hosted zone without verifying its ID.
- Keep public and private zone IDs separate.
- Avoid opening SSH to the internet.
- Do not commit AWS credentials.
- Use test addresses rather than production endpoints.
- Delete both hosted zones after the lab.

### Cost Considerations

This lab creates two hosted zones that can incur monthly hosted-zone charges.

Additional costs may apply for EC2, EBS storage, DNS queries, and the instance's public IPv4 address.

No domain registration is required.

---

## 6. Prepare WSL Ubuntu

### Step 1 — Verify AWS CLI

```bash
aws --version
aws sts get-caller-identity
```

### Step 2 — Install DNS Tools

```bash
sudo apt update
sudo apt install -y dnsutils
```

Verify:

```bash
dig -v
```

### Step 3 — Configure Environment Variables

```bash
export AWS_REGION="us-east-1"
export AWS_PAGER=""

export PROJECT_TAG="Route53-Troubleshooting-Lab05"

export VPC_CIDR="10.57.0.0/16"
export SUBNET_CIDR="10.57.1.0/24"

export ZONE_NAME="lab05.route53.test"
export RECORD_NAME="app.lab05.route53.test"

export PUBLIC_IP="203.0.113.10"
export PRIVATE_IP="10.57.1.100"

export EC2_ROLE_NAME="route53-lab05-ssm-role"
export PROFILE_NAME="route53-lab05-ssm-profile"
export SG_NAME="route53-lab05-client-sg"
```

### Step 4 — Verify Variables

```bash
echo "$AWS_REGION"
echo "$ZONE_NAME"
echo "$RECORD_NAME"
echo "$PUBLIC_IP"
echo "$PRIVATE_IP"
```

Keep this WSL terminal open to preserve resource IDs.

---

## 7. Create AWS VPC and Networking

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications \
    "ResourceType=vpc,Tags=[{Key=Name,Value=route53-lab05-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Vpc.VpcId' \
  --output text \
  --region "$AWS_REGION")

echo "$VPC_ID"
```

### Step 2 — Enable VPC DNS

```bash
aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --enable-dns-support \
  --region "$AWS_REGION"

aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --enable-dns-hostnames \
  --region "$AWS_REGION"
```

### Step 3 — Verify DNS Settings

```bash
aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsSupport \
  --region "$AWS_REGION"

aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsHostnames \
  --region "$AWS_REGION"
```

Both should return `true`.

### Step 4 — Check Availability Zones

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

Choose a supported AZ:

```bash
export AZ="us-east-1a"
```

### Step 5 — Create Subnet

```bash
export SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_CIDR" \
  --availability-zone "$AZ" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=route53-lab05-public},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 6 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
    "ResourceType=internet-gateway,Tags=[{Key=Name,Value=route53-lab05-igw},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region "$AWS_REGION")

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 7 — Create Route Table

```bash
export ROUTE_TABLE_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=route-table,Tags=[{Key=Name,Value=route53-lab05-public-rt},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")
```

Add internet route:

```bash
aws ec2 create-route \
  --route-table-id "$ROUTE_TABLE_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

Associate subnet:

```bash
export ROUTE_ASSOC_ID=$(aws ec2 associate-route-table \
  --route-table-id "$ROUTE_TABLE_ID" \
  --subnet-id "$SUBNET_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

---

## 8. Create Public and Private Hosted Zones

### Step 1 — Create Public Hosted Zone

```bash
export PUBLIC_ZONE_ID=$(aws route53 create-hosted-zone \
  --name "$ZONE_NAME" \
  --caller-reference "route53-lab05-public-$(date +%s)" \
  --hosted-zone-config \
    "Comment=Route53 Lab05 public DNS view,PrivateZone=false" \
  --query 'HostedZone.Id' \
  --output text)

echo "$PUBLIC_ZONE_ID"
```

### Step 2 — Retrieve Public Authoritative Nameservers

```bash
aws route53 get-hosted-zone \
  --id "$PUBLIC_ZONE_ID" \
  --query 'DelegationSet.NameServers' \
  --output table
```

Save the first nameserver:

```bash
export PUBLIC_NS=$(aws route53 get-hosted-zone \
  --id "$PUBLIC_ZONE_ID" \
  --query 'DelegationSet.NameServers[0]' \
  --output text)

echo "$PUBLIC_NS"
```

### Step 3 — Create Private Hosted Zone

```bash
export PRIVATE_ZONE_ID=$(aws route53 create-hosted-zone \
  --name "$ZONE_NAME" \
  --caller-reference "route53-lab05-private-$(date +%s)" \
  --vpc "VPCRegion=$AWS_REGION,VPCId=$VPC_ID" \
  --hosted-zone-config \
    "Comment=Route53 Lab05 private DNS view,PrivateZone=true" \
  --query 'HostedZone.Id' \
  --output text)

echo "$PRIVATE_ZONE_ID"
```

### Step 4 — Verify Public Hosted Zone

```bash
aws route53 get-hosted-zone \
  --id "$PUBLIC_ZONE_ID" \
  --query '{Name:HostedZone.Name,Private:HostedZone.Config.PrivateZone}' \
  --output json
```

Expected: `Private=false`.

### Step 5 — Verify Private Hosted Zone

```bash
aws route53 get-hosted-zone \
  --id "$PRIVATE_ZONE_ID" \
  --query '{Name:HostedZone.Name,Private:HostedZone.Config.PrivateZone,VPCs:VPCs}' \
  --output json
```

Expected: `Private=true` and associated with the Lab 05 VPC.

### Step 6 — List Both Zones

```bash
aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='${ZONE_NAME}.'].{ID:Id,Name:Name,Private:Config.PrivateZone}" \
  --output table
```

Expected: two hosted zones with different IDs.

---

## 9. Fault Injection — Public Record Only

### Step 1 — Create Public A Record

Save as `public-a-record.json`:

```json
{
  "Comment": "Lab05 public DNS record only",
  "Changes": [
    {
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "app.lab05.route53.test",
        "Type": "A",
        "TTL": 60,
        "ResourceRecords": [
          {
            "Value": "203.0.113.10"
          }
        ]
      }
    }
  ]
}
```

### Step 2 — Apply Record to Public Zone

```bash
export PUBLIC_CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$PUBLIC_ZONE_ID" \
  --change-batch file://public-a-record.json \
  --query 'ChangeInfo.Id' \
  --output text)

aws route53 wait resource-record-sets-changed \
  --id "$PUBLIC_CHANGE_ID"
```

### Step 3 — Verify Public Record

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$PUBLIC_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}.']" \
  --output json
```

Expected: public A record points to `203.0.113.10`.

### Step 4 — Verify Private Record Is Missing

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$PRIVATE_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}.']" \
  --output json
```

Expected:

```json
[]
```

### Fault Injection Summary

| Component | Expected State |
|---|---|
| Public Hosted Zone | Exists |
| Private Hosted Zone | Exists |
| Public A Record | Present |
| Private A Record | Missing |
| VPC Association | Correct |
| Expected Internal DNS Response | NXDOMAIN |

---

## 10. Verify Public DNS View

### Step 1 — Query Public Authoritative Nameserver

From WSL:

```bash
dig @"$PUBLIC_NS" "$RECORD_NAME" A +norecurse
```

Expected:

```text
status: NOERROR
```

The answer includes:

```text
app.lab05.route53.test. 60 IN A 203.0.113.10
```

### Step 2 — Verify Short Answer

```bash
dig +short @"$PUBLIC_NS" "$RECORD_NAME" A
```

Expected:

```text
203.0.113.10
```

### Step 3 — Inspect Authoritative Flag

```bash
dig @"$PUBLIC_NS" "$RECORD_NAME" A +norecurse
```

Look for the `aa` flag in the response header.

### Step 4 — Save Public Evidence

```bash
dig @"$PUBLIC_NS" "$RECORD_NAME" A +norecurse \
  > lab05-public-before.txt
```

### Important Limitation

The `.test` domain is reserved for testing.

The public hosted zone is not delegated through the public DNS hierarchy.

Therefore, directly querying its Route 53 nameserver demonstrates the zone's configured public authoritative response, not normal public recursive DNS availability.

---

## 11. Deploy EC2 DNS Troubleshooting Client

### Step 1 — Create Security Group

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "Route53 Lab05 DNS client" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

No inbound SSH access is necessary.

### Step 2 — Create IAM Trust Policy

Save as `ec2-trust-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

### Step 3 — Create IAM Role

```bash
aws iam create-role \
  --role-name "$EC2_ROLE_NAME" \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam attach-role-policy \
  --role-name "$EC2_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

### Step 4 — Create Instance Profile

```bash
aws iam create-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam add-role-to-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$EC2_ROLE_NAME"
```

### Step 5 — Retrieve Amazon Linux AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 6 — Launch EC2

```bash
export INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --network-interfaces \
    "DeviceIndex=0,SubnetId=$SUBNET_ID,Groups=$SG_ID,AssociatePublicIpAddress=true" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --count 1 \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=route53-lab05-client},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")

echo "$INSTANCE_ID"
```

### Step 7 — Wait for EC2

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Connect Using Systems Manager

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
sudo dnf install -y bind-utils
```

Configure variables:

```bash
export RECORD_NAME="app.lab05.route53.test"
export VPC_DNS="10.57.0.2"
```

---

## 12. Reproduce Private DNS Failure

### Step 1 — Query VPC Resolver

```bash
dig @"$VPC_DNS" "$RECORD_NAME" A
```

Expected:

```text
status: NXDOMAIN
```

### Step 2 — Short DNS Query

```bash
dig +short @"$VPC_DNS" "$RECORD_NAME" A
```

Expected: no A record answer.

### Step 3 — Test nslookup

```bash
nslookup "$RECORD_NAME" "$VPC_DNS"
```

Expected: non-existent domain.

### Step 4 — Test Linux Resolution

```bash
getent ahostsv4 "$RECORD_NAME"
```

Expected: no IPv4 address.

### Step 5 — Verify General DNS

```bash
dig @"$VPC_DNS" amazon.com A
```

Expected: successful DNS response.

### Step 6 — Save Failure Evidence

```bash
dig @"$VPC_DNS" "$RECORD_NAME" A \
  > "$HOME/lab05-private-before.txt"
```

### Step 7 — Compare Public and Private DNS

Set the actual public authoritative nameserver in the EC2 session:

```bash
export PUBLIC_NS="YOUR_PUBLIC_ROUTE53_NAMESERVER"
```

Query it directly:

```bash
dig @"$PUBLIC_NS" "$RECORD_NAME" A +norecurse
```

Expected: `203.0.113.10`.

Query the VPC Resolver:

```bash
dig @"$VPC_DNS" "$RECORD_NAME" A
```

Expected: NXDOMAIN.

### Expected Investigation Results

| Test | Expected Result |
|---|---|
| Public Authoritative DNS | NOERROR |
| Public Record Value | 203.0.113.10 |
| Private DNS Resolver | NXDOMAIN |
| Private Record | Missing |
| General VPC DNS | Working |
| Root Cause | Missing record in private hosted zone |

---

## 13. Troubleshooting with AWS CLI

### Check 1 — List Both Hosted Zones

From WSL:

```bash
aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='${ZONE_NAME}.'].{ID:Id,Private:Config.PrivateZone,Name:Name}" \
  --output table
```

### Check 2 — Inspect Public A Record

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$PUBLIC_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}.']" \
  --output json
```

Expected: `203.0.113.10`.

### Check 3 — Inspect Private A Record

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$PRIVATE_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}.']" \
  --output json
```

Expected:

```json
[]
```

### Check 4 — Verify Private Zone VPC Association

```bash
aws route53 get-hosted-zone \
  --id "$PRIVATE_ZONE_ID" \
  --query 'VPCs' \
  --output table
```

### Check 5 — Verify VPC DNS Attributes

```bash
aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsSupport \
  --region "$AWS_REGION"

aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsHostnames \
  --region "$AWS_REGION"
```

### Check 6 — Compare Record Inventories

```bash
echo "PUBLIC HOSTED ZONE"

aws route53 list-resource-record-sets \
  --hosted-zone-id "$PUBLIC_ZONE_ID" \
  --output table
```

```bash
echo "PRIVATE HOSTED ZONE"

aws route53 list-resource-record-sets \
  --hosted-zone-id "$PRIVATE_ZONE_ID" \
  --output table
```

### Investigation Matrix

| Investigation | Expected Finding |
|---|---|
| Public Zone | Exists |
| Private Zone | Exists |
| Same Zone Name | Yes |
| Public A Record | Present |
| Private A Record | Missing |
| VPC Association | Correct |
| VPC DNS Support | Enabled |
| VPC Resolver | Functional |
| Root Cause | Record missing from private zone |

---

## 14. Root Cause Analysis

### Root Cause

The application A record was created in the public Route 53 hosted zone but not in the private hosted zone.

Both hosted zones used the same DNS namespace.

When the EC2 instance queried `app.lab05.route53.test` through the VPC Resolver, the matching private hosted zone was selected.

Because that private hosted zone did not contain the requested hostname, the Resolver returned NXDOMAIN.

The Resolver did not fall back to the public hosted zone.

### Root Cause Flow

```text
EC2 Client
     |
     v
DNS Query
     |
     v
VPC DNS Resolver
     |
     v
Private Hosted Zone Selected
     |
     v
Requested Hostname Missing
     |
     v
NXDOMAIN
     |
     v
No Automatic Public-Zone Fallback
```

### Five Whys

1. **Why did the hostname fail inside the VPC?** The VPC Resolver returned NXDOMAIN.
2. **Why did the resolver return NXDOMAIN?** The private hosted zone did not contain the application record.
3. **Why didn't the public A record resolve the request?** The matching private zone was selected for the VPC DNS view.
4. **Why was the record missing?** It was created only in the public hosted zone.
5. **How was the incident resolved?** The correct A record was created in the private hosted zone.

### Root Cause Summary

| Component | Finding |
|---|---|
| Service | Amazon Route 53 |
| Incident | Public vs Private Hosted Zone |
| DNS Error | NXDOMAIN |
| Public Record | Exists |
| Private Record | Missing |
| VPC Resolver | Working |
| Root Cause | Incomplete private DNS configuration |
| Remediation | Create private A record |
| Infrastructure Replacement | Not required |

---

## 15. Remediation — Create Private A Record

### Step 1 — Create Private DNS Record

Save as `private-a-record.json`:

```json
{
  "Comment": "Lab05 - Fix missing private A record",
  "Changes": [
    {
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "app.lab05.route53.test",
        "Type": "A",
        "TTL": 60,
        "ResourceRecords": [
          {
            "Value": "10.57.1.100"
          }
        ]
      }
    }
  ]
}
```

### Step 2 — Apply to Private Zone

```bash
export PRIVATE_CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$PRIVATE_ZONE_ID" \
  --change-batch file://private-a-record.json \
  --query 'ChangeInfo.Id' \
  --output text)

echo "$PRIVATE_CHANGE_ID"
```

### Step 3 — Wait for Route 53

```bash
aws route53 wait resource-record-sets-changed \
  --id "$PRIVATE_CHANGE_ID"
```

### Step 4 — Verify Change Status

```bash
aws route53 get-change \
  --id "$PRIVATE_CHANGE_ID" \
  --query 'ChangeInfo.Status' \
  --output text
```

Expected:

```text
INSYNC
```

### Step 5 — Verify Private DNS Record

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$PRIVATE_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}.']" \
  --output json
```

Expected:

```json
[
  {
    "Name": "app.lab05.route53.test.",
    "Type": "A",
    "TTL": 60,
    "ResourceRecords": [
      {
        "Value": "10.57.1.100"
      }
    ]
  }
]
```

---

## 16. Verify DNS Recovery

### Step 1 — Connect to EC2

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
export RECORD_NAME="app.lab05.route53.test"
export VPC_DNS="10.57.0.2"
```

### Step 2 — Query Private DNS

```bash
dig @"$VPC_DNS" "$RECORD_NAME" A
```

Expected after any negative cache expires:

```text
status: NOERROR
```

The answer should contain:

```text
10.57.1.100
```

### Step 3 — Verify Short Output

```bash
dig +short @"$VPC_DNS" "$RECORD_NAME" A
```

Expected:

```text
10.57.1.100
```

### Step 4 — Verify nslookup

```bash
nslookup "$RECORD_NAME" "$VPC_DNS"
```

Expected: the private IP.

### Step 5 — Verify getent

```bash
getent ahostsv4 "$RECORD_NAME"
```

Expected: `10.57.1.100`.

### Step 6 — Compare Public and Private DNS

Using the previously retrieved public nameserver:

```bash
dig +short @"$PUBLIC_NS" "$RECORD_NAME" A
```

Expected:

```text
203.0.113.10
```

Query the VPC Resolver:

```bash
dig +short @"$VPC_DNS" "$RECORD_NAME" A
```

Expected:

```text
10.57.1.100
```

### Step 7 — Save Recovery Evidence

```bash
dig @"$VPC_DNS" "$RECORD_NAME" A \
  > "$HOME/lab05-private-after.txt"
```

Optional:

```bash
dig @"$PUBLIC_NS" "$RECORD_NAME" A +norecurse \
  > "$HOME/lab05-public-after.txt"
```

### Before and After Comparison

| Test | Before Fix | After Fix |
|---|---|---|
| Public A Record | 203.0.113.10 | 203.0.113.10 |
| Private A Record | Missing | 10.57.1.100 |
| Public Authoritative DNS | NOERROR | NOERROR |
| Private VPC DNS | NXDOMAIN | NOERROR |
| Private DNS IP | None | 10.57.1.100 |
| Incident | Active | Resolved |

### Important Caching Note

Previously cached NXDOMAIN responses may remain temporarily after creating the private A record.

Allow the negative cache to expire if necessary before concluding the remediation failed.

---

## 17. Production Best Practices

### Public and Private DNS Troubleshooting Checklist

1. Identify the affected hostname.
2. Determine where the DNS query originated.
3. Inspect the VPC's DNS resolver configuration.
4. List matching Route 53 hosted zones.
5. Determine which zones are public and private.
6. Verify the correct hosted zone ID.
7. Inspect record sets in both DNS views.
8. Verify private hosted zone VPC associations.
9. Check `enableDnsSupport` and `enableDnsHostnames`.
10. Query public authoritative DNS directly when appropriate.
11. Query private DNS from inside the intended VPC.
12. Identify differences between answers.
13. Create or correct records in the appropriate zone.
14. Verify change status.
15. Account for DNS caching.
16. Test application connectivity separately.
17. Document the incident.

### Security Best Practices

- Use least-privilege IAM permissions.
- Protect production hosted zones against unauthorized changes.
- Keep internal-only DNS records in the correct private zones.
- Review public DNS records for unintended information exposure.
- Verify private hosted zone VPC associations.
- Document DNS ownership.
- Use infrastructure as code for repeatable configurations.
- Maintain rollback procedures.
- Monitor critical DNS changes.
- Remember that private DNS does not replace network or application security.

### Common Problems

| Symptom | Possible Cause |
|---|---|
| Works publicly, fails in VPC | Missing private DNS record |
| Works in one VPC only | Private zone association problem |
| Wrong internal IP | Incorrect private A record |
| NXDOMAIN inside VPC | Matching private zone has no record |
| Public DNS not resolving | Missing or incorrect delegation |
| Different IPs inside/outside | Intentional or incorrect split DNS |
| DNS works, HTTP fails | Application or network issue |

---

## 18. AWS Resource Cleanup

**Warning:** Delete only the disposable Lab 05 resources. Confirm both hosted zone IDs before deleting them.

### Step 1 — Exit EC2

```bash
exit
```

Return to WSL.

### Step 2 — Create Public Record Deletion Batch

Save as `delete-public-record.json`:

```json
{
  "Comment": "Lab05 cleanup - public A record",
  "Changes": [
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "app.lab05.route53.test",
        "Type": "A",
        "TTL": 60,
        "ResourceRecords": [
          {
            "Value": "203.0.113.10"
          }
        ]
      }
    }
  ]
}
```

### Step 3 — Create Private Record Deletion Batch

Save as `delete-private-record.json`:

```json
{
  "Comment": "Lab05 cleanup - private A record",
  "Changes": [
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "app.lab05.route53.test",
        "Type": "A",
        "TTL": 60,
        "ResourceRecords": [
          {
            "Value": "10.57.1.100"
          }
        ]
      }
    }
  ]
}
```

### Step 4 — Verify Current Records

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$PUBLIC_ZONE_ID" \
  --output table

aws route53 list-resource-record-sets \
  --hosted-zone-id "$PRIVATE_ZONE_ID" \
  --output table
```

The deletion batches must match the current record sets.

### Step 5 — Delete Public A Record

```bash
export DELETE_PUBLIC_CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$PUBLIC_ZONE_ID" \
  --change-batch file://delete-public-record.json \
  --query 'ChangeInfo.Id' \
  --output text)

aws route53 wait resource-record-sets-changed \
  --id "$DELETE_PUBLIC_CHANGE_ID"
```

### Step 6 — Delete Private A Record

```bash
export DELETE_PRIVATE_CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$PRIVATE_ZONE_ID" \
  --change-batch file://delete-private-record.json \
  --query 'ChangeInfo.Id' \
  --output text)

aws route53 wait resource-record-sets-changed \
  --id "$DELETE_PRIVATE_CHANGE_ID"
```

### Step 7 — Delete Both Hosted Zones

Confirm only default NS and SOA records remain in both zones.

```bash
aws route53 delete-hosted-zone \
  --id "$PUBLIC_ZONE_ID"

aws route53 delete-hosted-zone \
  --id "$PRIVATE_ZONE_ID"
```

### Step 8 — Verify Hosted Zone Deletion

```bash
aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='${ZONE_NAME}.'].Id" \
  --output json
```

Expected:

```json
[]
```

### Step 9 — Verify EC2 Root Volume

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings' \
  --output json \
  --region "$AWS_REGION"
```

Verify root volume `DeleteOnTermination=true`.

### Step 10 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 11 — Verify IAM Role Ownership

```bash
aws iam list-role-tags \
  --role-name "$EC2_ROLE_NAME"
```

Confirm `Project=Route53-Troubleshooting-Lab05`.

### Step 12 — Delete IAM Resources

```bash
aws iam detach-role-policy \
  --role-name "$EC2_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam remove-role-from-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$EC2_ROLE_NAME"

aws iam delete-instance-profile \
  --instance-profile-name "$PROFILE_NAME"

aws iam delete-role \
  --role-name "$EC2_ROLE_NAME"
```

### Step 13 — Verify Network Interfaces

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Wait until the EC2 network interface is removed.

### Step 14 — Delete Security Group

```bash
aws ec2 delete-security-group \
  --group-id "$SG_ID" \
  --region "$AWS_REGION"
```

### Step 15 — Delete Route Table

```bash
aws ec2 disassociate-route-table \
  --association-id "$ROUTE_ASSOC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-route-table \
  --route-table-id "$ROUTE_TABLE_ID" \
  --region "$AWS_REGION"
```

### Step 16 — Delete Subnet

```bash
aws ec2 delete-subnet \
  --subnet-id "$SUBNET_ID" \
  --region "$AWS_REGION"
```

### Step 17 — Delete Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 18 — Delete VPC

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 19 — Verify Cleanup

Check hosted zones:

```bash
aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='${ZONE_NAME}.'].Id" \
  --output json
```

Check lab VPC:

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].VpcId' \
  --output json \
  --region "$AWS_REGION"
```

Expected: empty arrays.

Also confirm EC2 termination, IAM cleanup, and EBS volume deletion.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| Public A Record | Deleted |
| Private A Record | Deleted |
| Public Hosted Zone | Deleted |
| Private Hosted Zone | Deleted |
| EC2 Instance | Terminated |
| Root EBS Volume | Deleted |
| IAM Role | Deleted |
| Instance Profile | Deleted |
| Security Group | Deleted |
| Route Table | Deleted |
| Subnet | Deleted |
| Internet Gateway | Deleted |
| Lab VPC | Deleted |
| Default VPC | Unchanged |

---

## 19. Interview Questions and Answers

### Q1. What is a Route 53 public hosted zone?

A container for DNS records intended for public DNS resolution.

### Q2. What is a Route 53 private hosted zone?

A hosted zone that provides DNS answers through associated VPCs.

### Q3. Can public and private hosted zones have the same domain name?

Yes. This supports different public and private DNS views.

### Q4. What happens when a record exists publicly but is missing privately?

The VPC Resolver can return NXDOMAIN if the matching private hosted zone does not contain that hostname.

### Q5. Does Route 53 fall back to the public zone when a private record is missing?

No. When the private hosted zone is selected for the namespace, missing names do not automatically fall back to the public hosted zone.

### Q6. Why must private hosted zones be associated with VPCs?

Because VPC association determines where the private DNS records can be resolved.

### Q7. What VPC DNS settings should be checked?

`enableDnsSupport` and `enableDnsHostnames`.

### Q8. How do you inspect hosted zones?

```bash
aws route53 list-hosted-zones
```

### Q9. How do you inspect a hosted zone's records?

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id YOUR_HOSTED_ZONE_ID
```

### Q10. Why might a public hosted zone not resolve through ordinary internet DNS?

The domain may not be properly delegated from the parent DNS hierarchy.

### Q11. What is split-horizon DNS?

A DNS design that provides different answers for the same hostname depending on the client's DNS view or network.

### Q12. How would you explain this lab in an interview?

I created a public and a private Route 53 hosted zone with the same DNS namespace.

The private hosted zone was associated with an AWS VPC.

I intentionally created an application A record only in the public hosted zone.

I then launched an EC2 Linux troubleshooting client and reproduced an NXDOMAIN response through the VPC Resolver.

I verified that the public hosted zone contained the record by querying its authoritative nameserver directly.

I compared the public and private hosted zone configurations using AWS CLI and identified the missing private A record.

I created the record in the correct private hosted zone and verified that internal DNS resolution returned the intended private IP address.

Finally, I deleted both hosted zones and all temporary AWS infrastructure.

---

## 20. Repository Structure

```text
aws-route53-troubleshooting-labs/
│
├── README.md
│
├── 01-dns-record-not-resolving/
│   └── README.md
│
├── 02-wrong-a-record/
│   └── README.md
│
├── 03-cname-misconfiguration/
│   └── README.md
│
├── 04-dns-ttl-caching-problem/
│   └── README.md
│
└── 05-public-vs-private-hosted-zone/
    ├── README.md
    ├── ec2-trust-policy.json
    ├── public-a-record.json
    ├── private-a-record.json
    ├── delete-public-record.json
    └── delete-private-record.json
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete DNS troubleshooting documentation |
| `ec2-trust-policy.json` | IAM trust policy for EC2 Systems Manager |
| `public-a-record.json` | Creates the public A record |
| `private-a-record.json` | Creates the missing private A record |
| `delete-public-record.json` | Deletes the public record |
| `delete-private-record.json` | Deletes the private record |

Optional evidence files:

- `lab05-public-before.txt`
- `lab05-private-before.txt`
- `lab05-private-after.txt`
- `lab05-public-after.txt`

The outputs from EC2 are initially stored on the EC2 instance. Copy any sanitized evidence you want to preserve into your repository before terminating the instance.

---

## 21. Lessons Learned and Skills Demonstrated

### Lessons Learned

This lab demonstrates that public and private Route 53 hosted zones can share the same DNS namespace but return different answers.

We created two hosted zones using the same name and associated the private zone with an AWS VPC.

We intentionally configured the application A record only in the public zone.

The public authoritative nameserver returned the configured public IP, but the VPC Resolver returned NXDOMAIN because the requested record was missing from the private zone.

We investigated the difference using Linux DNS tools and AWS CLI.

We identified the private hosted zone as the selected DNS view and created the missing A record there.

After remediation, the VPC Resolver returned the intended private IP while the public authoritative server continued returning the public record.

This lab also demonstrated why DNS queries must be tested from the correct network and resolution path.

**Key Lesson:** When DNS resolution behaves differently inside and outside a VPC, investigate hosted zone type, VPC association, and private zone records before changing application infrastructure.

### Skills Demonstrated

- Amazon Route 53
- Public hosted zones
- Private hosted zones
- AWS VPC DNS Resolver
- Hosted zone VPC association
- DNS A records
- NXDOMAIN troubleshooting
- DNS visibility analysis
- Authoritative DNS queries
- DNS delegation concepts
- AWS CLI v2
- Linux `dig`
- Linux `nslookup`
- Linux `getent`
- EC2 troubleshooting
- AWS Systems Manager
- IAM roles
- Root cause analysis
- DNS remediation
- AWS resource cleanup

### Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-R53-005 |
| Scenario | Public vs Private Hosted Zone |
| Hosted Zones | Two with same DNS namespace |
| Public Record | 203.0.113.10 |
| Original Private Record | Missing |
| DNS Before Fix | NXDOMAIN inside VPC |
| Root Cause | Missing A record in private zone |
| Remediation | Create private A record |
| Private Record After Fix | 10.57.1.100 |
| Public DNS View | Unchanged |
| Private DNS After Fix | NOERROR |
| Cleanup | Temporary infrastructure removed |
| Incident Status | Resolved after verification |

**Key Takeaway:** Route 53 public and private hosted zones serve different DNS views. Correctly understanding hosted zone selection, VPC associations, and DNS record placement is essential for troubleshooting cloud DNS incidents.
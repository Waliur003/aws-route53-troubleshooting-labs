# Lab 01 — Route 53 DNS Record Not Resolving

## Overview

This lab demonstrates how to troubleshoot a missing DNS A record in an Amazon Route 53 private hosted zone using AWS CLI and Linux DNS tools.

We create a private hosted zone, associate it with an Amazon VPC, and deploy an EC2 troubleshooting instance running Amazon Linux 2023.

We intentionally leave an application hostname without an A record to reproduce an `NXDOMAIN` error.

The incident is investigated using `dig`, `nslookup`, `getent`, AWS CLI, and Route 53 hosted zone records.

After identifying the missing record, we create a new A record pointing to a private IPv4 address and verify that DNS resolution works.

Finally, we delete all temporary AWS resources.

**Troubleshooting workflow:**

Infrastructure Setup → Private Hosted Zone → DNS Failure → Investigation → Root Cause → Remediation → Verification → Cleanup

---

## 1. Lab Information

| Item | Configuration |
|---|---|
| Incident ID | INC-R53-001 |
| Difficulty | Beginner |
| AWS Region | `us-east-1` |
| AWS Services | Route 53, VPC, EC2, IAM, Systems Manager |
| Operating System | Amazon Linux 2023 |
| Local Environment | WSL Ubuntu |
| VPC CIDR | `10.53.0.0/16` |
| Public Subnet | `10.53.1.0/24` |
| Hosted Zone | `lab01.route53.test` |
| Hosted Zone Type | Private |
| Application Hostname | `app.lab01.route53.test` |
| DNS Record Type | A |
| DNS Record Value | `10.53.1.100` |
| TTL | 60 seconds |
| VPC DNS Resolver | `10.53.0.2` |
| Fault Injection | Missing A record |
| Expected DNS Error | `NXDOMAIN` |
| Remediation | Create missing A record |
| Verification | `dig`, `nslookup`, `getent` |
| Access Method | AWS Systems Manager |

---

## 2. Production Incident Scenario

### Incident Description

A company hosts an internal application inside an AWS VPC.

Employees access the application using the hostname:

`app.lab01.route53.test`

One day, the application hostname stops resolving.

When an engineer runs a DNS lookup, the resolver returns:

```text
status: NXDOMAIN
```

The application server might be healthy, but users cannot find its IP address through DNS.

The Cloud Engineer must investigate the DNS configuration, identify the missing A record, restore it, and verify that the hostname resolves correctly.

### Incident Symptoms

- Application hostname cannot be resolved.
- `dig` reports `NXDOMAIN`.
- `nslookup` reports that the domain does not exist.
- Linux `getent` cannot return an IPv4 address.
- Other domains resolve successfully.
- Route 53 private hosted zone exists.
- VPC DNS settings are enabled.
- The application A record is missing.

### Business Impact

- Internal application hostname becomes unavailable.
- Users cannot reach the application by its configured name.
- Application dependencies relying on the hostname may fail.
- Troubleshooting can be delayed if engineers mistake DNS failures for network failures.

### Objective

Identify and remediate a missing DNS A record in a Route 53 private hosted zone.

---

## 3. AWS Architecture

### Infrastructure Architecture

```text
                      AWS Region
                       us-east-1
                           |
                           v
                      Amazon VPC
                    10.53.0.0/16
                           |
           -------------------------------
           |                             |
           v                             v
      Public Subnet                  Route 53
     10.53.1.0/24               Private Hosted Zone
           |                     lab01.route53.test
           v                             |
      EC2 Linux Client                   |
      Amazon Linux 2023                  |
           |                             |
           v                             |
       DNS Query                         |
           |                             |
           v                             |
     Route 53 Resolver ------------------+
        10.53.0.2
           |
           v
   app.lab01.route53.test
           |
           v
      Missing A Record
           |
           v
        NXDOMAIN
```

### Architecture After Remediation

```text
        EC2 Linux Client
               |
               v
         DNS Query
               |
               v
       VPC DNS Resolver
          10.53.0.2
               |
               v
     Route 53 Private Zone
               |
               v
   app.lab01.route53.test
               |
               v
           A Record
               |
               v
         10.53.1.100
               |
               v
       DNS Resolution Works
```

### Network Configuration

| Resource | Configuration |
|---|---|
| VPC | `10.53.0.0/16` |
| Public Subnet | `10.53.1.0/24` |
| EC2 Instance | `t3.micro` |
| Operating System | Amazon Linux 2023 |
| Internet Gateway | Attached |
| Public Route | `0.0.0.0/0` to IGW |
| EC2 Management | Systems Manager |
| Private Hosted Zone | `lab01.route53.test` |
| DNS Resolver | `10.53.0.2` |
| A Record | `app.lab01.route53.test` |
| Target IP | `10.53.1.100` |

The target IP is used only for DNS testing. No application is deployed at that address.

---

## 4. Understanding DNS and Amazon Route 53

### What Is DNS?

DNS stands for Domain Name System.

It translates domain names into DNS resource records, including IP addresses.

Example:

```text
app.lab01.route53.test
         |
         v
      A Record
         |
         v
     10.53.1.100
```

### What Is an A Record?

An A record maps a hostname to an IPv4 address.

Example:

```text
Name: app.lab01.route53.test
Type: A
Value: 10.53.1.100
TTL: 60
```

### What Is a Hosted Zone?

A hosted zone is a container for DNS records managed by Route 53.

A hosted zone can be public or private.

### What Is a Private Hosted Zone?

A private hosted zone provides DNS resolution through associated VPCs.

A private hosted zone is not automatically accessible through ordinary public DNS resolvers.

### What Is NXDOMAIN?

`NXDOMAIN` means the queried DNS name does not exist in the DNS view being queried.

In this lab, the application hostname is missing from the private hosted zone.

### What Is NOERROR?

`NOERROR` means the DNS server successfully processed the DNS query.

It does not always guarantee that a requested A record exists. The response must also be checked for the expected answer.

### What Is TTL?

TTL stands for Time to Live.

It specifies how long a DNS response may be cached.

We use:

```text
TTL = 60 seconds
```

### Important DNS Response Codes

| Response | Meaning |
|---|---|
| NOERROR | Query processed successfully |
| NXDOMAIN | DNS name does not exist |
| SERVFAIL | DNS server could not complete the request |
| REFUSED | DNS server refused the query |

---

## 5. Prerequisites and Safety

### Requirements

- AWS account
- AWS CLI v2
- WSL Ubuntu
- Bash
- IAM permissions for lab resources
- Amazon EC2 permissions
- VPC permissions
- Route 53 permissions
- Systems Manager access
- Git and GitHub

### Safety Rules

- Use a disposable private hosted zone.
- Do not modify production DNS records.
- Avoid changing existing public hosted zones.
- Do not open SSH to the internet.
- Verify AWS resource identifiers before deletion.
- Do not commit AWS credentials.
- Keep resource names specific to the lab.
- Delete the private hosted zone after the experiment.
- Terminate the EC2 instance after completion.

### Cost Considerations

The lab can incur charges for the private hosted zone, EC2 instance, attached EBS storage, and public IPv4 address.

No domain registration is required.

---

## 6. Prepare WSL Ubuntu

### Step 1 — Verify AWS CLI

```bash
aws --version
aws sts get-caller-identity
```

### Step 2 — Configure Environment Variables

```bash
export AWS_REGION="us-east-1"
export AWS_PAGER=""

export PROJECT_TAG="Route53-Troubleshooting-Lab01"

export VPC_CIDR="10.53.0.0/16"
export SUBNET_CIDR="10.53.1.0/24"

export ZONE_NAME="lab01.route53.test"
export RECORD_NAME="app.lab01.route53.test"

export TARGET_IP="10.53.1.100"

export EC2_ROLE_NAME="route53-lab01-ssm-role"
export PROFILE_NAME="route53-lab01-ssm-profile"
export SG_NAME="route53-lab01-client-sg"
```

### Step 3 — Verify Variables

```bash
echo "$AWS_REGION"
echo "$ZONE_NAME"
echo "$RECORD_NAME"
echo "$TARGET_IP"
```

Expected:

```text
us-east-1
lab01.route53.test
app.lab01.route53.test
10.53.1.100
```

---

## 7. Create VPC and Networking

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications \
    "ResourceType=vpc,Tags=[{Key=Name,Value=route53-lab01-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Vpc.VpcId' \
  --output text \
  --region "$AWS_REGION")

echo "$VPC_ID"
```

### Step 2 — Enable DNS Support

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

### Step 3 — Verify VPC DNS

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

Expected: both settings are enabled.

### Step 4 — Create Public Subnet

```bash
export SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_CIDR" \
  --availability-zone us-east-1a \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=route53-lab01-public},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
    "ResourceType=internet-gateway,Tags=[{Key=Name,Value=route53-lab01-igw},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region "$AWS_REGION")

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Create Route Table

```bash
export ROUTE_TABLE_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=route-table,Tags=[{Key=Name,Value=route53-lab01-public-rt},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")
```

Create internet route:

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

## 8. Create Route 53 Private Hosted Zone

### Step 1 — Create Hosted Zone

```bash
export CALLER_REF="route53-lab01-$(date +%s)"

export HOSTED_ZONE_ID=$(aws route53 create-hosted-zone \
  --name "$ZONE_NAME" \
  --caller-reference "$CALLER_REF" \
  --vpc "VPCRegion=$AWS_REGION,VPCId=$VPC_ID" \
  --hosted-zone-config \
    "Comment=Route53 DNS troubleshooting Lab01,PrivateZone=true" \
  --query 'HostedZone.Id' \
  --output text)

echo "$HOSTED_ZONE_ID"
```

### Step 2 — Verify Hosted Zone

```bash
aws route53 get-hosted-zone \
  --id "$HOSTED_ZONE_ID" \
  --query '{Name:HostedZone.Name,Private:HostedZone.Config.PrivateZone,VPCs:VPCs}' \
  --output json
```

Expected:

```text
Zone: lab01.route53.test
Private: true
VPC association: correct
```

### Step 3 — List DNS Records

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --output table
```

Expected: default `NS` and `SOA` records.

The application A record should not exist yet.

---

## 9. Deploy EC2 DNS Troubleshooting Client

### Step 1 — Create Security Group

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "Route53 Lab01 DNS client" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

No inbound SSH access is required.

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

Allow IAM propagation.

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
    "ResourceType=instance,Tags=[{Key=Name,Value=route53-lab01-client},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

Use an Availability Zone that supports the chosen instance type.

### Step 7 — Wait for EC2

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Connect Through Systems Manager

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 9 — Install DNS Utilities

Inside EC2:

```bash
sudo dnf install -y bind-utils
```

Verify:

```bash
dig -v
nslookup amazon.com
```

Configure variables inside EC2:

```bash
export RECORD_NAME="app.lab01.route53.test"
export VPC_DNS="10.53.0.2"
export TARGET_IP="10.53.1.100"
```

---

## 10. Fault Injection — DNS Record Missing

### Step 1 — Query Application Hostname

Inside EC2:

```bash
dig "$RECORD_NAME" A
```

Expected response:

```text
status: NXDOMAIN
```

### Step 2 — Query VPC DNS Resolver Directly

```bash
dig @"$VPC_DNS" "$RECORD_NAME" A
```

Expected:

```text
status: NXDOMAIN
ANSWER: 0
```

### Step 3 — Query Short Output

```bash
dig +short @"$VPC_DNS" "$RECORD_NAME" A
```

Expected: no A record output.

### Step 4 — Test nslookup

```bash
nslookup "$RECORD_NAME" "$VPC_DNS"
```

Expected: non-existent domain.

### Step 5 — Test Linux Hostname Resolution

```bash
getent ahostsv4 "$RECORD_NAME"
```

Expected: no IP address.

### Step 6 — Verify General DNS

```bash
dig @"$VPC_DNS" amazon.com A
```

Expected: successful DNS resolution.

This confirms that DNS resolution is generally functional.

### Step 7 — Record the Failure

```bash
dig @"$VPC_DNS" "$RECORD_NAME" A \
  > "$HOME/lab01-before-fix.txt"
```

View:

```bash
cat "$HOME/lab01-before-fix.txt"
```

### Fault Injection Summary

| Check | Expected Result |
|---|---|
| Hosted Zone | Exists |
| Application A Record | Missing |
| `dig` | NXDOMAIN |
| `nslookup` | Non-existent domain |
| `getent` | No IPv4 address |
| General DNS | Working |
| Root Cause | Missing DNS A record |

---

## 11. Troubleshooting Investigation

### Check 1 — Verify Hosted Zone

From WSL:

```bash
aws route53 get-hosted-zone \
  --id "$HOSTED_ZONE_ID" \
  --output json
```

Confirm the correct zone and VPC association.

### Check 2 — Inspect DNS Record Inventory

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --output table
```

Expected: application A record is missing.

### Check 3 — Search for the Hostname

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}.']" \
  --output json
```

Expected:

```json
[]
```

### Check 4 — Verify Private Hosted Zone Association

```bash
aws route53 get-hosted-zone \
  --id "$HOSTED_ZONE_ID" \
  --query 'VPCs' \
  --output table
```

Confirm the zone is associated with the intended VPC.

### Check 5 — Verify VPC DNS Settings

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

Expected: both enabled.

### Investigation Matrix

| Investigation | Expected Finding |
|---|---|
| Private Hosted Zone | Exists |
| VPC Association | Correct |
| DNS Support | Enabled |
| DNS Hostnames | Enabled |
| VPC Resolver | Functional |
| Application A Record | Missing |
| NXDOMAIN | Reproduced |
| Root Cause | Missing record |

---

## 12. Root Cause Analysis

### Root Cause

The hostname `app.lab01.route53.test` did not have an A record in the Route 53 private hosted zone.

The VPC DNS Resolver was functioning correctly.

However, the requested hostname did not exist in the private DNS view.

As a result, the resolver returned `NXDOMAIN`.

### Root Cause Flow

```text
Application Requests Hostname
             |
             v
VPC DNS Resolver Receives Query
             |
             v
Private Hosted Zone Selected
             |
             v
Search for Application A Record
             |
             v
Requested Hostname Missing
             |
             v
NXDOMAIN Returned
             |
             v
Application Cannot Resolve Name
```

### Five Whys

1. **Why couldn't the application hostname resolve?** The DNS resolver returned `NXDOMAIN`.
2. **Why did it return NXDOMAIN?** The requested hostname did not exist in the private hosted zone.
3. **Why was the hostname missing?** Its A record had not been created.
4. **Why was this not a network connectivity problem?** The VPC DNS Resolver successfully resolved other hostnames.
5. **How was the incident resolved?** The missing A record was created in the correct private hosted zone.

### Root Cause Summary

| Item | Finding |
|---|---|
| Incident Type | DNS configuration |
| Affected Service | Amazon Route 53 |
| Failure | NXDOMAIN |
| Root Cause | Missing A record |
| Networking | Operational |
| Remediation | Create missing A record |
| Infrastructure Replacement | Not required |

---

## 13. Remediation — Create the Missing A Record

### Step 1 — Create DNS Change Batch

From WSL, create `create-a-record.json`:

```json
{
  "Comment": "Lab01 - Fix missing DNS A record",
  "Changes": [
    {
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "app.lab01.route53.test",
        "Type": "A",
        "TTL": 60,
        "ResourceRecords": [
          {
            "Value": "10.53.1.100"
          }
        ]
      }
    }
  ]
}
```

### Step 2 — Create the Record

```bash
export CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch file://create-a-record.json \
  --query 'ChangeInfo.Id' \
  --output text)

echo "$CHANGE_ID"
```

### Step 3 — Check Change Status

```bash
aws route53 get-change \
  --id "$CHANGE_ID" \
  --query 'ChangeInfo.{ID:Id,Status:Status}' \
  --output table
```

Possible values:

```text
PENDING
INSYNC
```

### Step 4 — Wait for Route 53

```bash
aws route53 wait resource-record-sets-changed \
  --id "$CHANGE_ID"
```

### Step 5 — Verify Record

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}.']" \
  --output json
```

Expected:

```json
[
  {
    "Name": "app.lab01.route53.test.",
    "Type": "A",
    "TTL": 60,
    "ResourceRecords": [
      {
        "Value": "10.53.1.100"
      }
    ]
  }
]
```

---

## 14. DNS Recovery Verification

### Step 1 — Connect to EC2

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
export RECORD_NAME="app.lab01.route53.test"
export VPC_DNS="10.53.0.2"
```

### Step 2 — Verify DNS Answer

```bash
dig @"$VPC_DNS" "$RECORD_NAME" A
```

Expected:

```text
status: NOERROR
```

The answer should include:

```text
app.lab01.route53.test. 60 IN A 10.53.1.100
```

The returned TTL may be lower because of DNS caching.

### Step 3 — Verify Short Output

```bash
dig +short @"$VPC_DNS" "$RECORD_NAME" A
```

Expected:

```text
10.53.1.100
```

### Step 4 — Test nslookup

```bash
nslookup "$RECORD_NAME" "$VPC_DNS"
```

Expected: hostname resolves to `10.53.1.100`.

### Step 5 — Test Linux Resolver

```bash
getent ahostsv4 "$RECORD_NAME"
```

Expected: output includes `10.53.1.100`.

### Step 6 — Save Successful DNS Output

```bash
dig @"$VPC_DNS" "$RECORD_NAME" A \
  > "$HOME/lab01-after-fix.txt"
```

### Step 7 — Compare Before and After

```bash
grep -E "status:|ANSWER SECTION|10.53.1.100" \
  "$HOME/lab01-before-fix.txt" \
  "$HOME/lab01-after-fix.txt"
```

### Verification Summary

| Check | Before Remediation | After Remediation |
|---|---|---|
| A Record | Missing | Created |
| DNS Response | NXDOMAIN | NOERROR |
| IP Address | None | `10.53.1.100` |
| dig | Failed | Successful |
| nslookup | Failed | Successful |
| getent | Failed | Successful |
| Route 53 Configuration | Incomplete | Corrected |

---

## 15. DNS Caching and Troubleshooting Notes

### Negative DNS Caching

DNS resolvers can cache negative responses such as `NXDOMAIN`.

After creating the missing record, the resolver may temporarily continue returning a cached negative response.

This does not necessarily mean the Route 53 record creation failed.

### INSYNC Versus Client Resolution

`INSYNC` means the Route 53 DNS change has propagated to Route 53's relevant DNS servers.

It does not guarantee that all recursive caches have expired.

### DNS Is Not Application Connectivity

The target IP `10.53.1.100` is used only to test name resolution.

No application server is deployed at that address.

Therefore:

```bash
curl --connect-timeout 3 http://app.lab01.route53.test
```

may fail even when DNS resolution succeeds.

This is expected because DNS resolution and application connectivity are separate.

### Common DNS Troubleshooting Results

| Symptom | Possible Cause |
|---|---|
| NXDOMAIN | Missing hostname |
| NOERROR without A answer | Name exists, but no A record exists |
| SERVFAIL | DNS processing or forwarding problem |
| Wrong IP | Incorrect A record |
| Works inside VPC only | Private hosted zone |
| Old IP returned | DNS caching |
| Correct DNS, failed HTTP | Network or application issue |

---

## 16. Final Verification

### Final DNS Query

```bash
dig +short @10.53.0.2 app.lab01.route53.test A
```

Expected:

```text
10.53.1.100
```

### Final AWS Record Check

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}.']" \
  --output json
```

### Final Results

| Check | Expected Result |
|---|---|
| Private Hosted Zone | Available |
| VPC Association | Correct |
| DNS Support | Enabled |
| A Record | Exists |
| A Record Value | `10.53.1.100` |
| TTL | 60 seconds configured |
| DNS Response | NOERROR |
| Linux DNS Resolution | Successful |
| Incident Resolution | Verified |

These are expected results. Replace them with actual observations when capturing lab evidence.

---

## 17. AWS Resource Cleanup

**Warning:** Delete only the resources created specifically for this lab.

### Step 1 — Exit EC2

```bash
exit
```

Return to the WSL terminal where your AWS resource variables are defined.

### Step 2 — Create DNS Delete Batch

Save as `delete-a-record.json`:

```json
{
  "Comment": "Lab01 cleanup - remove DNS A record",
  "Changes": [
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "app.lab01.route53.test",
        "Type": "A",
        "TTL": 60,
        "ResourceRecords": [
          {
            "Value": "10.53.1.100"
          }
        ]
      }
    }
  ]
}
```

### Step 3 — Delete A Record

```bash
export DELETE_CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch file://delete-a-record.json \
  --query 'ChangeInfo.Id' \
  --output text)
```

Wait:

```bash
aws route53 wait resource-record-sets-changed \
  --id "$DELETE_CHANGE_ID"
```

### Step 4 — Verify Record Deletion

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --output table
```

Only the default `SOA` and `NS` records should remain.

### Step 5 — Delete Hosted Zone

```bash
aws route53 delete-hosted-zone \
  --id "$HOSTED_ZONE_ID"
```

### Step 6 — Verify Hosted Zone Deletion

```bash
aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='${ZONE_NAME}.'].Id" \
  --output json
```

Expected: no remaining matching hosted zone.

### Step 7 — Verify EC2 Root Volume

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings' \
  --output json \
  --region "$AWS_REGION"
```

Verify the root EBS volume is configured for deletion on termination.

### Step 8 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 9 — Verify IAM Role Ownership

```bash
aws iam list-role-tags \
  --role-name "$EC2_ROLE_NAME"
```

Confirm the project tag.

### Step 10 — Delete IAM Resources

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

### Step 11 — Verify Network Interfaces

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Wait for the lab instance's network interfaces to be removed.

### Step 12 — Delete Security Group

```bash
aws ec2 delete-security-group \
  --group-id "$SG_ID" \
  --region "$AWS_REGION"
```

### Step 13 — Delete Route Table

```bash
aws ec2 disassociate-route-table \
  --association-id "$ROUTE_ASSOC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-route-table \
  --route-table-id "$ROUTE_TABLE_ID" \
  --region "$AWS_REGION"
```

### Step 14 — Delete Subnet

```bash
aws ec2 delete-subnet \
  --subnet-id "$SUBNET_ID" \
  --region "$AWS_REGION"
```

### Step 15 — Delete Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 16 — Delete VPC

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 17 — Verify Cleanup

Check hosted zones:

```bash
aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='${ZONE_NAME}.'].Id" \
  --output json
```

Check lab VPCs:

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].VpcId' \
  --output json \
  --region "$AWS_REGION"
```

Check EC2 state:

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].State.Name' \
  --output text \
  --region "$AWS_REGION"
```

Expected: no hosted zone, no lab VPC, and EC2 terminated.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| Application A Record | Deleted |
| Private Hosted Zone | Deleted |
| EC2 Instance | Terminated |
| Root EBS Volume | Deleted |
| IAM Role | Deleted |
| Instance Profile | Deleted |
| Security Group | Deleted |
| Route Table | Deleted |
| Public Subnet | Deleted |
| Internet Gateway | Deleted |
| Lab VPC | Deleted |
| Default VPC | Unchanged |

---

## 18. Production Best Practices

### DNS Troubleshooting Checklist

1. Identify the affected hostname.
2. Run a DNS lookup using `dig`.
3. Inspect the DNS response code.
4. Determine whether the zone is public or private.
5. Verify the correct hosted zone.
6. Inspect the DNS record inventory.
7. Check VPC associations for private hosted zones.
8. Verify VPC DNS support.
9. Compare expected and actual records.
10. Apply the smallest appropriate fix.
11. Verify Route 53 change status.
12. Query DNS from the intended client network.
13. Account for DNS caching.
14. Verify application connectivity separately.
15. Document the incident and remediation.

### Security Recommendations

- Use least-privilege IAM access.
- Protect production hosted zones.
- Avoid unauthorized DNS record changes.
- Review DNS modifications before applying them.
- Use infrastructure as code for repeatable DNS configuration.
- Monitor critical DNS records.
- Keep internal DNS namespaces private when appropriate.
- Maintain a DNS rollback plan.
- Verify changes before application deployment.
- Delete unused hosted zones to avoid unnecessary charges.

---

## 19. Interview Questions and Answers

### Q1. What is Amazon Route 53?

Amazon Route 53 is an AWS DNS service used for domain name resolution, DNS management, and routing policies.

### Q2. What is an A record?

An A record maps a hostname to an IPv4 address.

### Q3. What is NXDOMAIN?

A DNS response code indicating that the requested DNS name does not exist.

### Q4. What is a Route 53 private hosted zone?

A hosted zone that provides DNS resolution through associated VPCs rather than ordinary public internet DNS.

### Q5. Why might a hostname fail to resolve?

Possible reasons include a missing DNS record, incorrect zone configuration, wrong resolver, or private hosted zone association problem.

### Q6. How do you verify an A record?

```bash
dig example.com A
```

### Q7. How do you inspect Route 53 records using AWS CLI?

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id YOUR_HOSTED_ZONE_ID
```

### Q8. What is TTL?

Time to Live controls how long a DNS response may be cached.

### Q9. What is the difference between NXDOMAIN and SERVFAIL?

NXDOMAIN means the name does not exist. SERVFAIL means the DNS server could not complete the lookup.

### Q10. Can a hostname resolve while an application remains unreachable?

Yes. DNS resolution and application connectivity are separate.

### Q11. Why should you query private DNS from inside the VPC?

Private hosted zone records are available through associated VPC DNS resolution paths, not ordinary public DNS queries.

### Q12. How would you explain this lab in an interview?

I deployed a private Amazon Route 53 hosted zone associated with an AWS VPC and launched an EC2 Linux troubleshooting client.

I intentionally left an application hostname without an A record to reproduce an `NXDOMAIN` error.

I investigated the failure using Linux DNS tools, including `dig`, `nslookup`, and `getent`.

I also inspected the hosted zone's record inventory and verified that VPC DNS settings were enabled.

After identifying the missing A record as the root cause, I created the record using AWS CLI.

I verified that the DNS response changed from `NXDOMAIN` to `NOERROR` and that the hostname resolved to the expected private IP address.

Finally, I removed the temporary Route 53 and EC2 infrastructure.

---

## 20. Repository Structure

```text
aws-route53-troubleshooting-labs/
│
├── README.md
│
└── 01-dns-record-not-resolving/
    ├── README.md
    ├── ec2-trust-policy.json
    ├── create-a-record.json
    └── delete-a-record.json
```

### File Descriptions

| File | Purpose |
|---|---|
| README.md | Complete incident and troubleshooting documentation |
| ec2-trust-policy.json | IAM trust policy for EC2 Systems Manager |
| create-a-record.json | Creates the missing Route 53 A record |
| delete-a-record.json | Deletes the lab A record during cleanup |

Actual before-and-after DNS output can also be saved as sanitized evidence.

Do not commit AWS credentials, private authentication files, or sensitive infrastructure identifiers.

---

## 21. Lessons Learned and Skills Demonstrated

### Lessons Learned

This lab demonstrates how a missing DNS A record can cause a hostname to fail even when the VPC DNS Resolver is working normally.

We created an AWS VPC and a Route 53 private hosted zone.

We deployed an EC2 troubleshooting client and reproduced an `NXDOMAIN` response for an application hostname.

We investigated the issue using AWS CLI and Linux DNS utilities.

We identified the missing A record as the root cause and corrected it using a Route 53 change batch.

After applying the change, we verified that the hostname resolved to the configured IPv4 address.

The lab also demonstrated the importance of understanding private DNS, TTL, negative caching, and the difference between hostname resolution and application connectivity.

**Key Lesson:** When an application hostname fails to resolve, verify the DNS records and hosted zone configuration before making unnecessary changes to EC2 instances, security groups, or VPC routing.

### Skills Demonstrated

- Amazon Route 53
- Private hosted zones
- AWS CLI v2
- DNS A records
- NXDOMAIN troubleshooting
- Route 53 change batches
- DNS TTL
- Negative DNS caching
- Linux `dig`
- Linux `nslookup`
- Linux `getent`
- VPC DNS Resolver
- VPC DNS support
- EC2 troubleshooting
- AWS Systems Manager
- IAM roles and instance profiles
- Root cause analysis
- DNS verification
- AWS resource cleanup

### Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-R53-001 |
| Scenario | DNS Record Not Resolving |
| Hosted Zone | Private |
| Fault | Missing A record |
| DNS Error | NXDOMAIN |
| Root Cause | Application hostname absent |
| Remediation | Create A record |
| New Record | `app.lab01.route53.test` |
| Target | `10.53.1.100` |
| TTL | 60 seconds |
| DNS After Fix | NOERROR |
| Name Resolution | Successful |
| Cleanup | Temporary resources removed |
| Incident Status | Resolved after verification |

**Key Takeaway:** Effective DNS troubleshooting requires checking the actual DNS response, hosted zone configuration, record inventory, resolver behavior, and caching before concluding that an application or network is unavailable.
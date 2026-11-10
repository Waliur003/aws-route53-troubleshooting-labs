# Lab 04 — Route 53 DNS TTL and Caching Problem

## Overview

This lab demonstrates how to troubleshoot DNS caching and Time to Live (TTL) issues in Amazon Route 53 using AWS CLI, Linux, and a local caching DNS resolver.

We create a private Route 53 hosted zone associated with an Amazon VPC and deploy an Amazon Linux 2023 EC2 instance.

The EC2 instance uses `dnsmasq` as a local caching DNS resolver running on port `5353`.

Initially, we configure a DNS A record pointing to an old private IP address with a TTL of 300 seconds.

After caching the original DNS response, we update the Route 53 A record to a new private IP address with a TTL of 60 seconds.

Although Route 53 reports the DNS change as `INSYNC`, the local caching resolver may continue returning the old IP address until the previously cached record expires.

We investigate the difference between the configured DNS record and cached responses, inspect remaining TTL values, and flush the local DNS cache.

Finally, we verify that the updated IP address is returned and delete all temporary AWS resources.

**Troubleshooting workflow:**

Infrastructure Setup → Original DNS Record → Local DNS Cache → Record Update → Stale DNS Response → Investigation → Root Cause Analysis → Cache Flush → Verification → Cleanup

---

## 1. Lab Information

| Item | Configuration |
|---|---|
| Incident ID | INC-R53-004 |
| Difficulty | Intermediate |
| AWS Region | `us-east-1` |
| AWS Services | Route 53, EC2, VPC, IAM, Systems Manager |
| Local Environment | WSL Ubuntu |
| EC2 Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| VPC CIDR | `10.56.0.0/16` |
| Public Subnet | `10.56.1.0/24` |
| Hosted Zone | `lab04.route53.test` |
| Hosted Zone Type | Private |
| Application Hostname | `app.lab04.route53.test` |
| DNS Record Type | A |
| Original IP | `10.56.1.100` |
| Updated IP | `10.56.1.200` |
| Original TTL | 300 seconds |
| Updated TTL | 60 seconds |
| DNS Cache | `dnsmasq` |
| Local Cache Address | `127.0.0.1` |
| Local Cache Port | `5353` |
| VPC DNS Resolver | `10.56.0.2` |
| Fault Injection | Update DNS while old value is cached |
| Expected Symptom | Local cache temporarily returns old IP |
| Remediation | Flush local cache or wait for TTL expiration |
| Verification | `dig`, AWS CLI, DNS TTL comparison |

---

## 2. Production Incident Scenario

### Incident Description

A company hosts an internal application inside an AWS VPC.

The application's hostname is:

`app.lab04.route53.test`

Originally, the application was associated with the private IP address:

`10.56.1.100`

The Route 53 A record was configured with a TTL of 300 seconds.

During a planned migration, the application is moved to a new endpoint:

`10.56.1.200`

The Cloud Engineer updates Route 53 with the new IP address and reduces the record TTL to 60 seconds.

AWS reports the Route 53 change as `INSYNC`.

However, some users continue resolving the old IP address.

The engineer investigates and discovers that caching DNS resolvers are still storing previously received answers.

The DNS configuration is correct, but some cached responses have not expired.

### Incident Symptoms

- Route 53 contains the updated A record.
- The Route 53 change reports `INSYNC`.
- Some clients may continue receiving the old IP address.
- Different DNS resolvers may return different answers.
- The remaining TTL decreases with time.
- Flushing the affected cache can trigger a fresh lookup.
- Upstream caches may also need time to expire.
- The updated IP is eventually returned.

### Business Impact

- Users may continue connecting to an old application endpoint.
- Application migrations can appear incomplete.
- Traffic may be distributed inconsistently between old and new destinations.
- Users may experience intermittent application failures.
- Engineers may incorrectly assume Route 53 did not update the record.
- Troubleshooting becomes more difficult when different resolvers return different answers.

### Objective

Understand and troubleshoot DNS caching behavior following a Route 53 record update, and verify that the new DNS configuration becomes effective.

---

## 3. AWS Architecture

### Infrastructure Architecture

```text
                       AWS Region
                        us-east-1
                            |
                            v
                       Amazon VPC
                     10.56.0.0/16
                            |
           -----------------------------------
           |                                 |
           v                                 v
      Public Subnet                     Route 53
     10.56.1.0/24                  Private Hosted Zone
           |                       lab04.route53.test
           v                                 |
      EC2 Linux Client                       |
     Amazon Linux 2023                       |
           |                                 |
           v                                 |
     Local DNS Cache                         |
        dnsmasq                              |
   127.0.0.1:5353                            |
           |                                 |
           v                                 |
      VPC DNS Resolver ----------------------+
         10.56.0.2
           |
           v
   app.lab04.route53.test
           |
           v
        A Record
```

### Before DNS Update

```text
Route 53 A Record
       |
       v
10.56.1.100
TTL = 300 seconds
       |
       v
VPC DNS Resolver
       |
       v
dnsmasq Receives Answer
       |
       v
Old IP Stored in Local Cache
```

### During the Incident

```text
Route 53 Updated
10.56.1.200
TTL = 60 seconds
       |
       v
Route 53 Status: INSYNC
       |
       v
Local Cache Still Contains
10.56.1.100
       |
       v
Client Receives Old Address
```

### After Remediation

```text
Local DNS Cache Cleared
       |
       v
New DNS Query
       |
       v
VPC Resolver
       |
       v
Route 53 Updated Record
       |
       v
10.56.1.200
       |
       v
DNS Resolution Restored
```

### Network Configuration

| Resource | Configuration |
|---|---|
| VPC | `10.56.0.0/16` |
| Public Subnet | `10.56.1.0/24` |
| EC2 | Amazon Linux 2023 |
| Internet Gateway | Attached |
| Public Route | `0.0.0.0/0` through IGW |
| EC2 Access | Systems Manager |
| Private Hosted Zone | `lab04.route53.test` |
| VPC Resolver | `10.56.0.2` |
| Local DNS Cache | `127.0.0.1:5353` |

The old and new addresses are test values. No application servers are required at those addresses.

---

## 4. Understanding DNS TTL and Caching

### What Is DNS TTL?

TTL stands for Time to Live.

It specifies how long a DNS response may be cached before the resolver must obtain updated information.

Example:

```text
app.lab04.route53.test
Type: A
Value: 10.56.1.100
TTL: 300
```

A caching resolver can retain the response for up to 300 seconds, subject to its own caching behavior and policies.

### What Happens When TTL Expires?

When a cached record expires, the resolver must obtain a fresh answer instead of continuing to rely on that expired record.

### What Is DNS Caching?

DNS caching stores previously received DNS answers to reduce repeated DNS lookups.

Benefits include:

- Faster DNS responses
- Reduced upstream DNS queries
- Lower DNS query load
- Improved efficiency

However, cached information may temporarily differ from newly updated authoritative records.

### What Is a Recursive Resolver?

A recursive DNS resolver answers client queries by obtaining DNS information and caching responses.

In this lab, the VPC Resolver provides AWS DNS resolution, while `dnsmasq` serves as our additional local caching resolver.

### What Is dnsmasq?

`dnsmasq` is a lightweight DNS and network service utility.

We use its DNS caching capability to reproduce stale DNS behavior.

### What Does INSYNC Mean?

Route 53 reports `INSYNC` when a change has propagated to its relevant DNS servers.

It does not mean that all recursive DNS resolvers and local caches have discarded old answers.

### Important TTL Behavior

Suppose a resolver caches:

```text
10.56.1.100
TTL: 300 seconds
```

After 30 seconds, Route 53 is updated to:

```text
10.56.1.200
TTL: 60 seconds
```

The existing cached answer may still have approximately 270 seconds remaining.

Changing the record's TTL does not retroactively shorten the TTL already held by another cache.

### DNS TTL Example

| Elapsed Time | Approximate Remaining TTL |
|---|---|
| 0 seconds | 300 |
| 30 seconds | 270 |
| 60 seconds | 240 |
| 120 seconds | 180 |
| 240 seconds | 60 |
| 300 seconds | 0 |

These values illustrate normal TTL countdown behavior.

---

## 5. Prerequisites and Safety

### Requirements

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- Route 53 permissions
- EC2 permissions
- VPC permissions
- IAM permissions
- AWS Systems Manager access
- Linux DNS utilities
- Git and GitHub

### Safety Rules

- Use a disposable private hosted zone.
- Do not modify production DNS records.
- Do not use production application IP addresses.
- Keep `dnsmasq` bound to the loopback interface.
- Do not expose the lab DNS cache to the internet.
- Do not open SSH publicly.
- Record original DNS settings before modification.
- Do not commit AWS credentials.
- Delete temporary infrastructure after testing.

### Cost Considerations

This lab may incur charges for the private hosted zone, EC2 instance, EBS volume, and public IPv4 address.

No domain registration is necessary.

---

## 6. Prepare WSL Ubuntu

### Step 1 — Verify AWS CLI

```bash
aws --version
aws sts get-caller-identity
```

### Step 2 — Configure Variables

```bash
export AWS_REGION="us-east-1"
export AWS_PAGER=""

export PROJECT_TAG="Route53-Troubleshooting-Lab04"

export VPC_CIDR="10.56.0.0/16"
export SUBNET_CIDR="10.56.1.0/24"

export ZONE_NAME="lab04.route53.test"
export RECORD_NAME="app.lab04.route53.test"

export OLD_IP="10.56.1.100"
export NEW_IP="10.56.1.200"

export OLD_TTL=300
export NEW_TTL=60

export EC2_ROLE_NAME="route53-lab04-ssm-role"
export PROFILE_NAME="route53-lab04-ssm-profile"
export SG_NAME="route53-lab04-client-sg"
```

### Step 3 — Verify Variables

```bash
echo "$AWS_REGION"
echo "$ZONE_NAME"
echo "$RECORD_NAME"
echo "$OLD_IP"
echo "$NEW_IP"
```

Keep the original WSL terminal open throughout the exercise to preserve resource identifiers.

---

## 7. Create AWS VPC and Networking

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications \
  "ResourceType=vpc,Tags=[{Key=Name,Value=route53-lab04-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
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

Both settings should report `true`.

### Step 4 — Select Availability Zone

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

### Step 5 — Create Public Subnet

```bash
export SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_CIDR" \
  --availability-zone "$AZ" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=route53-lab04-public},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 6 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
  "ResourceType=internet-gateway,Tags=[{Key=Name,Value=route53-lab04-igw},{Key=Project,Value=$PROJECT_TAG}]" \
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
  "ResourceType=route-table,Tags=[{Key=Name,Value=route53-lab04-public-rt},{Key=Project,Value=$PROJECT_TAG}]" \
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

Associate the subnet:

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
export CALLER_REF="route53-lab04-$(date +%s)"

export HOSTED_ZONE_ID=$(aws route53 create-hosted-zone \
  --name "$ZONE_NAME" \
  --caller-reference "$CALLER_REF" \
  --vpc "VPCRegion=$AWS_REGION,VPCId=$VPC_ID" \
  --hosted-zone-config \
  "Comment=Route53 DNS TTL and caching Lab04,PrivateZone=true" \
  --query 'HostedZone.Id' \
  --output text)

echo "$HOSTED_ZONE_ID"
```

### Step 2 — Verify Hosted Zone

```bash
aws route53 get-hosted-zone \
  --id "$HOSTED_ZONE_ID" \
  --query '{Zone:HostedZone.Name,Private:HostedZone.Config.PrivateZone,VPCs:VPCs}' \
  --output json
```

Expected: private hosted zone associated with the Lab 04 VPC.

---

## 9. Create Original DNS A Record

### Step 1 — Generate Original DNS Configuration

Create `initial-a-record.json`:

```bash
cat > initial-a-record.json <<EOF
{
  "Comment": "Lab04 baseline A record with 300-second TTL",
  "Changes": [
    {
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "$RECORD_NAME",
        "Type": "A",
        "TTL": $OLD_TTL,
        "ResourceRecords": [
          {
            "Value": "$OLD_IP"
          }
        ]
      }
    }
  ]
}
EOF
```

### Step 2 — Apply DNS Record

```bash
export INITIAL_CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch file://initial-a-record.json \
  --query 'ChangeInfo.Id' \
  --output text)

aws route53 wait resource-record-sets-changed \
  --id "$INITIAL_CHANGE_ID"
```

### Step 3 — Verify Record

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
    "Name": "app.lab04.route53.test.",
    "Type": "A",
    "TTL": 300,
    "ResourceRecords": [
      {
        "Value": "10.56.1.100"
      }
    ]
  }
]
```

The original DNS record is now configured.

---

## 10. Deploy EC2 Troubleshooting Client

### Step 1 — Create Security Group

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "Route53 Lab04 DNS caching client" \
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
    "ResourceType=instance,Tags=[{Key=Name,Value=route53-lab04-client},{Key=Project,Value=$PROJECT_TAG}]" \
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

### Step 8 — Connect Through Systems Manager

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
sudo dnf install -y bind-utils dnsmasq
```

Verify:

```bash
dig -v
dnsmasq --version
```

---

## 11. Configure Local DNS Caching with dnsmasq

### Step 1 — Configure Variables on EC2

```bash
export RECORD_NAME="app.lab04.route53.test"
export VPC_DNS="10.56.0.2"

export OLD_IP="10.56.1.100"
export NEW_IP="10.56.1.200"

export CACHE_PORT=5353
```

### Step 2 — Create Configuration Directory

```bash
mkdir -p /tmp/route53-lab04
```

### Step 3 — Create dnsmasq Configuration

Create `/tmp/route53-lab04/dnsmasq.conf`:

```ini
port=5353
listen-address=127.0.0.1
bind-interfaces

no-resolv
no-hosts

server=/lab04.route53.test/10.56.0.2

cache-size=1000
log-queries
```

### Configuration Explanation

| Setting | Purpose |
|---|---|
| port | Uses local DNS port 5353 |
| listen-address | Listens on loopback only |
| bind-interfaces | Restricts interface binding |
| no-resolv | Ignores default resolver configuration |
| no-hosts | Ignores local hosts entries |
| server | Forwards lab DNS queries to the VPC Resolver |
| cache-size | Enables DNS caching |
| log-queries | Enables query logging |

### Step 4 — Validate Configuration

```bash
sudo dnsmasq \
  --test \
  --conf-file=/tmp/route53-lab04/dnsmasq.conf
```

Expected:

```text
dnsmasq: syntax check OK.
```

### Step 5 — Start dnsmasq

```bash
sudo dnsmasq \
  --conf-file=/tmp/route53-lab04/dnsmasq.conf \
  --pid-file=/run/route53-lab04-dnsmasq.pid
```

### Step 6 — Verify Process

```bash
sudo cat /run/route53-lab04-dnsmasq.pid
```

```bash
sudo ss -lunp | grep 5353
```

Expected: dnsmasq listens on `127.0.0.1:5353`.

### Step 7 — Verify Original DNS

Query the VPC Resolver:

```bash
dig @10.56.0.2 "$RECORD_NAME" A
```

Expected: original A record points to `10.56.1.100`.

### Step 8 — Populate Local Cache

```bash
dig @127.0.0.1 -p 5353 "$RECORD_NAME" A
```

Repeat:

```bash
dig @127.0.0.1 -p 5353 "$RECORD_NAME" A
```

Expected: the old IP is returned and its remaining TTL decreases with time.

### Step 9 — Save Baseline Evidence

```bash
dig @127.0.0.1 -p 5353 "$RECORD_NAME" A \
  > "$HOME/lab04-before-update.txt"
```

Leave dnsmasq running.

---

## 12. Fault Injection — Update Route 53 Record

### Step 1 — Create Updated DNS Configuration

After caching the old answer, use WSL to create `updated-a-record.json`:

```bash
cat > updated-a-record.json <<EOF
{
  "Comment": "Lab04 - Migrate application DNS to new IP",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$RECORD_NAME",
        "Type": "A",
        "TTL": $NEW_TTL,
        "ResourceRecords": [
          {
            "Value": "$NEW_IP"
          }
        ]
      }
    }
  ]
}
EOF
```

### Step 2 — Apply DNS Update

```bash
export UPDATE_CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch file://updated-a-record.json \
  --query 'ChangeInfo.Id' \
  --output text)

echo "$UPDATE_CHANGE_ID"
```

### Step 3 — Wait for Route 53

```bash
aws route53 wait resource-record-sets-changed \
  --id "$UPDATE_CHANGE_ID"
```

### Step 4 — Verify Change Status

```bash
aws route53 get-change \
  --id "$UPDATE_CHANGE_ID" \
  --query 'ChangeInfo.Status' \
  --output text
```

Expected:

```text
INSYNC
```

### Step 5 — Verify Updated Record

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
    "Name": "app.lab04.route53.test.",
    "Type": "A",
    "TTL": 60,
    "ResourceRecords": [
      {
        "Value": "10.56.1.200"
      }
    ]
  }
]
```

Route 53 now contains the updated IP address.

---

## 13. Reproduce the DNS Caching Problem

### Step 1 — Query Local DNS Cache

Return to EC2.

```bash
dig @127.0.0.1 -p 5353 "$RECORD_NAME" A
```

Expected while the old cached entry remains:

```text
app.lab04.route53.test. 180 IN A 10.56.1.100
```

The remaining TTL will vary.

### Step 2 — Query VPC Resolver

```bash
dig @10.56.0.2 "$RECORD_NAME" A
```

The VPC Resolver may return the new IP if its cache has refreshed.

It may also temporarily return the old value if it has its own unexpired cached answer.

### Step 3 — Compare DNS Responses

| Source | Possible Response |
|---|---|
| Route 53 record inventory | 10.56.1.200 |
| Local dnsmasq cache | 10.56.1.100 |
| VPC Resolver | Old or new IP, depending on caching |
| Route 53 change status | INSYNC |

### Step 4 — Observe TTL Countdown

```bash
dig @127.0.0.1 -p 5353 "$RECORD_NAME" A
```

Repeat after a short interval:

```bash
dig @127.0.0.1 -p 5353 "$RECORD_NAME" A
```

Compare the TTL values.

### Step 5 — Save Stale DNS Evidence

```bash
dig @127.0.0.1 -p 5353 "$RECORD_NAME" A \
  > "$HOME/lab04-stale-cache.txt"
```

### Expected Fault Behavior

- Route 53 contains the new IP.
- Route 53 reports INSYNC.
- Local dnsmasq may continue returning the old IP.
- Remaining cached TTL decreases over time.
- DNS answers become consistent after relevant caches expire or are refreshed.

If the old TTL expires before the fault is observed, repeat the controlled experiment by restoring the original record, refreshing the cache, and updating Route 53 again.

---

## 14. Troubleshooting Investigation

### Check 1 — Inspect Route 53 Record

From WSL:

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}.']" \
  --output json
```

Expected configured IP: `10.56.1.200`.

### Check 2 — Inspect Route 53 Change Status

```bash
aws route53 get-change \
  --id "$UPDATE_CHANGE_ID" \
  --query 'ChangeInfo.Status' \
  --output text
```

Expected: INSYNC.

### Check 3 — Inspect Local DNS Cache

On EC2:

```bash
dig @127.0.0.1 -p 5353 "$RECORD_NAME" A
```

### Check 4 — Inspect VPC Resolver

```bash
dig @10.56.0.2 "$RECORD_NAME" A
```

### Check 5 — Inspect TTL

Look for the TTL column in the DNS answer.

Example:

```text
app.lab04.route53.test. 145 IN A 10.56.1.100
```

### Check 6 — Verify dnsmasq Process

```bash
sudo ss -lunp | grep 5353
```

### Investigation Matrix

| Investigation | Expected Finding |
|---|---|
| Route 53 Hosted Zone | Exists |
| VPC Association | Correct |
| Route 53 A Record | Updated |
| Route 53 Change | INSYNC |
| Local Cache | May contain old IP |
| TTL | Decreases |
| DNS Difference | Caused by caching |
| Root Cause | Previous unexpired DNS answer |

---

## 15. Root Cause Analysis

### Root Cause

The original Route 53 A record had a TTL of 300 seconds.

The local `dnsmasq` resolver cached that record before the migration.

When Route 53 was updated to a new IP address with a shorter TTL, the previously cached answer did not immediately disappear.

As a result, the caching resolver could continue returning the old IP address even though Route 53 had already applied the new configuration.

The issue was caused by normal DNS cache behavior and insufficient consideration of the existing TTL during the migration.

### Root Cause Flow

```text
Original DNS Record
10.56.1.100
TTL 300
       |
       v
Local Resolver Caches Answer
       |
       v
Route 53 Record Updated
10.56.1.200
TTL 60
       |
       v
Route 53 Reports INSYNC
       |
       v
Old Answer Remains Cached
       |
       v
Client Receives Old IP
```

### Five Whys

1. **Why was the old IP returned?** The local resolver still had a cached answer.
2. **Why was the answer still cached?** Its original TTL had not expired.
3. **Why didn't the Route 53 update clear it?** Route 53 cannot directly invalidate independent downstream DNS caches.
4. **Why didn't reducing TTL to 60 seconds fix it immediately?** The new TTL does not change the remaining lifetime of previously cached responses.
5. **How can this be prevented?** Reduce TTL ahead of planned migrations and allow old caches to expire before updating the target.

### Root Cause Summary

| Component | Finding |
|---|---|
| AWS Service | Route 53 |
| Incident | DNS TTL and Caching Problem |
| Original IP | 10.56.1.100 |
| Updated IP | 10.56.1.200 |
| Original TTL | 300 seconds |
| New TTL | 60 seconds |
| Route 53 Change | INSYNC |
| Root Cause | Previous DNS answer still cached |
| Infrastructure Failure | Not required to explain issue |
| Remediation | Cache expiration or controlled flush |

---

## 16. Remediation — Flush DNS Cache

### Step 1 — Flush dnsmasq Cache

Inside EC2:

```bash
sudo kill -HUP "$(sudo cat /run/route53-lab04-dnsmasq.pid)"
```

The `SIGHUP` signal clears the dnsmasq cache without stopping the process.

### Step 2 — Query Local Cache Again

```bash
dig @127.0.0.1 -p 5353 "$RECORD_NAME" A
```

Expected after upstream caches have refreshed:

```text
app.lab04.route53.test. 60 IN A 10.56.1.200
```

### Step 3 — Verify Upstream Resolver

```bash
dig @10.56.0.2 "$RECORD_NAME" A
```

Expected after the upstream cache expires:

```text
10.56.1.200
```

If the upstream resolver still returns the previous IP, wait for its existing TTL to expire.

Then flush the local cache again and retry.

### Step 4 — Verify Short DNS Answer

```bash
dig +short @127.0.0.1 -p 5353 "$RECORD_NAME" A
```

Expected:

```text
10.56.1.200
```

### Step 5 — Observe New TTL

```bash
dig @127.0.0.1 -p 5353 "$RECORD_NAME" A
```

The new answer should have a TTL no greater than 60 seconds under normal cache behavior.

### Step 6 — Save Recovery Evidence

```bash
dig @127.0.0.1 -p 5353 "$RECORD_NAME" A \
  > "$HOME/lab04-after-fix.txt"
```

### Before and After Comparison

| Check | Before Update | During Fault | After Fix |
|---|---|---|---|
| Route 53 IP | Old | New | New |
| Local Cached IP | Old | Old, if unexpired | New |
| Route 53 TTL | 300 | 60 | 60 |
| Local Cache TTL | Counting down | Old remaining TTL | New TTL |
| Route 53 Status | INSYNC | INSYNC | INSYNC |
| Incident | None | Stale DNS | Resolved |

---

## 17. Final Verification and Production Best Practices

### Final DNS Verification

On EC2:

```bash
dig +short @127.0.0.1 -p 5353 app.lab04.route53.test A
```

Expected:

```text
10.56.1.200
```

Verify the upstream resolver:

```bash
dig +short @10.56.0.2 app.lab04.route53.test A
```

Expected: `10.56.1.200` after upstream cache refresh.

### Verify AWS Configuration

From WSL:

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}.']" \
  --output json
```

Expected:

```text
IP: 10.56.1.200
TTL: 60
```

### Final Verification Matrix

| Check | Expected Result |
|---|---|
| Route 53 Change | INSYNC |
| Configured IP | 10.56.1.200 |
| Configured TTL | 60 seconds |
| VPC Resolver | Updated answer after cache expiry |
| Local dnsmasq | Updated answer after flush |
| Stale Local Cache | Cleared or expired |
| DNS Resolution | Successful |

### Production TTL Planning

A planned DNS migration should account for the TTL of the existing record.

Example:

```text
Original TTL = 3600 seconds
         |
         v
Reduce TTL to 60 seconds
         |
         v
Wait for old 3600-second caches to expire
         |
         v
Update DNS to new application endpoint
         |
         v
Verify DNS and application connectivity
         |
         v
Increase TTL if appropriate
```

### TTL Comparison

| TTL | Operational Consideration |
|---|---|
| 30 seconds | Rapid changes, more frequent lookups |
| 60 seconds | Short-lived caching |
| 300 seconds | Moderate caching |
| 3600 seconds | Longer caching |
| 86400 seconds | Long-lived DNS records |

### Production Best Practices

- Reduce TTL before planned migrations.
- Allow existing caches to expire.
- Compare multiple DNS resolution paths.
- Distinguish Route 53 configuration from recursive cache responses.
- Verify application connectivity after DNS changes.
- Maintain old infrastructure during planned DNS transitions when possible.
- Monitor errors during DNS migrations.
- Document DNS changes and rollback plans.
- Avoid unnecessary hosted zone recreation.
- Use infrastructure as code for repeatable DNS configuration.

### Common DNS Caching Problems

| Symptom | Possible Cause |
|---|---|
| Old IP after DNS update | Cached response |
| INSYNC but old answer | Downstream cache |
| Different clients see different IPs | Separate resolver caches |
| Cache flush does not help | Upstream still caching |
| New IP appears later | TTL expired |
| New DNS but failed HTTP | Application or networking issue |

---

## 18. AWS Resource Cleanup

**Warning:** Delete only the temporary resources created for this lab.

### Step 1 — Stop dnsmasq

Inside EC2:

```bash
sudo kill "$(sudo cat /run/route53-lab04-dnsmasq.pid)"
```

Verify:

```bash
sudo ss -lunp | grep 5353 || echo "Lab DNS cache stopped"
```

Exit EC2:

```bash
exit
```

### Step 2 — Create DNS Deletion Batch

In WSL, generate `delete-a-record.json`:

```bash
cat > delete-a-record.json <<EOF
{
  "Comment": "Lab04 cleanup - remove updated A record",
  "Changes": [
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "$RECORD_NAME",
        "Type": "A",
        "TTL": $NEW_TTL,
        "ResourceRecords": [
          {
            "Value": "$NEW_IP"
          }
        ]
      }
    }
  ]
}
EOF
```

### Step 3 — Verify Current DNS Record

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}.']" \
  --output json
```

The deletion batch must match the current record set exactly.

### Step 4 — Delete A Record

```bash
export DELETE_CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch file://delete-a-record.json \
  --query 'ChangeInfo.Id' \
  --output text)

aws route53 wait resource-record-sets-changed \
  --id "$DELETE_CHANGE_ID"
```

### Step 5 — Verify Record Removal

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --output table
```

Expected: default NS and SOA records only.

### Step 6 — Delete Private Hosted Zone

```bash
aws route53 delete-hosted-zone \
  --id "$HOSTED_ZONE_ID"
```

### Step 7 — Verify EC2 Root Volume

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings' \
  --output json \
  --region "$AWS_REGION"
```

Confirm the root EBS volume has `DeleteOnTermination=true`.

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

Confirm the Lab 04 project tag.

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

### Step 11 — Verify Network Interface Removal

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Wait until the EC2 network interface has disappeared.

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

Check VPC:

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].VpcId' \
  --output json \
  --region "$AWS_REGION"
```

Expected: empty arrays.

Also verify EC2 termination, root volume deletion, and IAM resource cleanup.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| Application A Record | Deleted |
| Private Hosted Zone | Deleted |
| dnsmasq Test Process | Stopped |
| EC2 Instance | Terminated |
| EBS Root Volume | Deleted |
| IAM Role | Deleted |
| Instance Profile | Deleted |
| Security Group | Deleted |
| Route Table | Deleted |
| Public Subnet | Deleted |
| Internet Gateway | Deleted |
| Lab VPC | Deleted |
| Default VPC | Unchanged |

---

## 19. Interview Questions and Answers

### Q1. What is DNS TTL?

TTL stands for Time to Live. It controls how long a DNS answer can be cached.

### Q2. Why might DNS return an old IP after Route 53 is updated?

A recursive resolver may still have an unexpired cached answer.

### Q3. What does Route 53 INSYNC mean?

Route 53 has applied the DNS change to its relevant DNS servers. It does not mean all downstream DNS caches are cleared.

### Q4. Does reducing TTL immediately update cached records?

No. Previously cached answers keep their remaining TTL until they expire or are invalidated by the relevant resolver.

### Q5. How can you inspect TTL in Linux?

```bash
dig app.example.com A
```

Read the TTL in the answer section.

### Q6. What is dnsmasq?

A lightweight DNS utility that can provide DNS forwarding and caching.

### Q7. How do you flush the dnsmasq cache?

```bash
sudo kill -HUP "$(sudo cat /run/route53-lab04-dnsmasq.pid)"
```

This clears the cache of the dedicated dnsmasq process used in this lab.

### Q8. Why can different clients receive different DNS answers?

They might use different DNS resolvers with independent caches.

### Q9. Why might a cache flush not immediately return the new IP?

The upstream DNS resolver may still have its own cached copy.

### Q10. What is the best practice before DNS migration?

Reduce the existing TTL in advance and allow older cached responses to expire before updating the destination.

### Q11. How do you troubleshoot DNS caching?

Compare the configured DNS record, Route 53 change status, local caching resolver answer, upstream resolver answer, and remaining TTL.

### Q12. How would you explain this lab in an interview?

I deployed a Route 53 private hosted zone and configured an A record with a 300-second TTL.

I then launched an EC2 instance and configured dnsmasq as a local caching DNS resolver.

After populating the cache with the original record, I updated Route 53 to a new IP address with a 60-second TTL.

I investigated how the local resolver could continue returning the previously cached IP even after Route 53 reported the update as INSYNC.

I compared the DNS record inventory, local cache responses, upstream DNS responses, and remaining TTL values.

I then flushed the local dnsmasq cache and verified that the updated IP was returned once the upstream resolution path had refreshed.

Finally, I deleted all temporary AWS resources.

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
└── 04-dns-ttl-caching-problem/
    ├── README.md
    ├── ec2-trust-policy.json
    ├── initial-a-record.json
    ├── updated-a-record.json
    ├── delete-a-record.json
    └── dnsmasq.conf
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete DNS caching troubleshooting documentation |
| `ec2-trust-policy.json` | IAM trust policy for EC2 Systems Manager |
| `initial-a-record.json` | Creates original A record with TTL 300 |
| `updated-a-record.json` | Updates A record with new IP and TTL 60 |
| `delete-a-record.json` | Deletes the lab A record |
| `dnsmasq.conf` | Optional copy of the local DNS cache configuration |

If you save `dnsmasq.conf` in GitHub, it should contain only the lab configuration, not production resolver information.

You may also include sanitized DNS command outputs as evidence.

---

## 21. Lessons Learned and Skills Demonstrated

### Lessons Learned

This lab demonstrates why DNS changes may not immediately appear to every client even after Amazon Route 53 has successfully applied them.

We created a private Route 53 hosted zone and configured an application hostname with an original TTL of 300 seconds.

We deployed an EC2 Linux troubleshooting client and configured dnsmasq as a local DNS caching resolver.

We cached the original IP address and then updated Route 53 with a new IP and a shorter TTL.

The exercise demonstrated how caching resolvers can temporarily return outdated DNS answers because the previous cached record has not expired.

We investigated the problem by comparing Route 53 record configuration, DNS queries, cache responses, and remaining TTL values.

We then flushed the local DNS cache and verified the updated IP once the upstream resolver provided the new answer.

**Key Lesson:** A Route 53 record update does not automatically invalidate DNS answers already stored in recursive resolvers. Engineers must understand TTL, cache expiration, and resolution paths when troubleshooting application migrations.

### Skills Demonstrated

- Amazon Route 53
- Private hosted zones
- DNS A records
- DNS TTL
- Recursive DNS caching
- AWS CLI v2
- Route 53 UPSERT
- Route 53 INSYNC status
- Amazon EC2
- Linux dnsmasq
- DNS forwarding
- DNS cache inspection
- DNS cache flushing
- Linux `dig`
- Linux `ss`
- VPC DNS Resolver
- AWS Systems Manager
- IAM roles
- Root cause analysis
- DNS migration planning
- DNS troubleshooting
- AWS resource cleanup

### Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-R53-004 |
| Scenario | DNS TTL and Caching Problem |
| DNS Record | A |
| Original IP | 10.56.1.100 |
| Updated IP | 10.56.1.200 |
| Original TTL | 300 seconds |
| Updated TTL | 60 seconds |
| Fault | Previous DNS answer remains cached |
| Route 53 Change | INSYNC |
| Root Cause | Unexpired cached DNS record |
| Remediation | Cache flush or TTL expiration |
| DNS After Recovery | Updated IP |
| Cleanup | Temporary resources removed |
| Incident Status | Resolved after verification |

**Key Takeaway:** Reliable DNS troubleshooting requires distinguishing authoritative configuration changes from cached resolver responses. Understanding TTL prevents confusion and downtime during cloud application migrations.
# Lab 03 — Route 53 CNAME Misconfiguration

## Overview

This lab demonstrates how to troubleshoot an incorrect CNAME record in Amazon Route 53 using AWS CLI, Linux DNS utilities, and an EC2-hosted web application.

We create an AWS VPC, deploy a private Route 53 hosted zone, and launch an Amazon Linux 2023 EC2 instance running a simple HTTP application.

We intentionally configure an application's CNAME record to point to the wrong hostname.

The incorrect hostname resolves to an unused private IPv4 address, causing HTTP requests to fail even though DNS resolution succeeds.

We investigate the DNS resolution chain using `dig`, `nslookup`, `getent`, `curl`, and AWS CLI.

After identifying the incorrect CNAME destination, we correct the record using Route 53 `UPSERT` and verify that both DNS resolution and HTTP connectivity work.

Finally, we delete the temporary AWS infrastructure.

**Troubleshooting workflow:**

Infrastructure Setup → Application Deployment → Incorrect CNAME → DNS Investigation → Root Cause Analysis → Remediation → Verification → Cleanup

---

## 1. Lab Information

| Item | Configuration |
|---|---|
| Incident ID | INC-R53-003 |
| Difficulty | Beginner–Intermediate |
| AWS Region | `us-east-1` |
| AWS Services | Route 53, EC2, VPC, IAM, Systems Manager |
| Local Environment | WSL Ubuntu |
| EC2 OS | Amazon Linux 2023 |
| EC2 Type | `t3.micro` |
| VPC | `10.55.0.0/16` |
| Public Subnet | `10.55.1.0/24` |
| Hosted Zone | `lab03.route53.test` |
| Hosted Zone Type | Private |
| Application Hostname | `app.lab03.route53.test` |
| Correct Target | `origin.lab03.route53.test` |
| Incorrect Target | `wrong.lab03.route53.test` |
| Wrong Target IP | `10.55.1.250` |
| Correct Target IP | Actual EC2 private IP |
| DNS TTL | 30 seconds |
| Web Server | Python HTTP server |
| HTTP Port | TCP 8080 |
| VPC DNS Resolver | `10.55.0.2` |
| Fault Injection | Incorrect CNAME target |
| DNS Response | `NOERROR` with wrong destination |
| HTTP Failure | Connection failure or timeout |
| Remediation | CNAME UPSERT |
| Verification | `dig`, `nslookup`, `getent`, `curl` |

---

## 2. Production Incident Scenario

### Incident Description

A company operates an internal application hosted on Amazon EC2.

The application is available using the hostname:

`origin.lab03.route53.test`

The company wants employees to use a simpler application hostname:

`app.lab03.route53.test`

To accomplish this, an engineer creates a CNAME record in Route 53.

However, the engineer mistakenly configures the CNAME to point to:

`wrong.lab03.route53.test`

This hostname resolves to an incorrect private IP address:

`10.55.1.250`

The intended application is running on an EC2 instance with a different private IP.

As a result, DNS resolution succeeds, but HTTP requests reach the wrong network destination.

The Cloud Engineer must investigate the CNAME chain, identify the incorrect hostname, correct the record, and verify recovery.

### Incident Symptoms

- EC2 application is running.
- HTTP requests to the correct origin hostname succeed.
- The application CNAME exists.
- DNS returns `NOERROR`.
- The application hostname resolves through the wrong CNAME target.
- HTTP requests through the application hostname fail.
- The original application remains healthy.
- Correcting the CNAME restores application access.

### Business Impact

- Employees cannot access the application through its expected hostname.
- Internal application requests fail.
- DNS-dependent services may be interrupted.
- Healthy EC2 infrastructure may be incorrectly diagnosed as unavailable.
- Incorrect DNS configurations increase incident resolution time.
- Application traffic may be directed to unintended destinations.

### Objective

Identify and correct a Route 53 CNAME misconfiguration while confirming that the underlying application infrastructure remains healthy.

---

## 3. AWS Architecture

### Infrastructure Architecture

```text
                       AWS Region
                        us-east-1
                            |
                            v
                       Amazon VPC
                     10.55.0.0/16
                            |
             --------------------------------
             |                              |
             v                              v
        Public Subnet                  Route 53
       10.55.1.0/24               Private Hosted Zone
             |                     lab03.route53.test
             v                              |
        EC2 Instance                        |
      Amazon Linux 2023                     |
             |                              |
             v                              v
      HTTP Application                 DNS Records
        Port 8080                           |
             |                     ------------------
             v                     |                |
       Actual EC2 IP               v                v
                             origin (A)        wrong (A)
                             Correct IP        10.55.1.250
                                                  |
                                                  v
                                            app (CNAME)
                                             points to
                                               wrong
                                                  |
                                                  v
                                           HTTP Failure
```

### Incorrect DNS Resolution

```text
app.lab03.route53.test
          |
          v
        CNAME
          |
          v
wrong.lab03.route53.test
          |
          v
        A Record
          |
          v
     10.55.1.250
          |
          v
   HTTP Connection Fails
```

### Correct DNS Resolution

```text
app.lab03.route53.test
          |
          v
        CNAME
          |
          v
origin.lab03.route53.test
          |
          v
        A Record
          |
          v
   Actual EC2 Private IP
          |
          v
      HTTP Port 8080
          |
          v
   Application Responds
```

### Network Configuration

| Resource | Configuration |
|---|---|
| VPC | `10.55.0.0/16` |
| Public Subnet | `10.55.1.0/24` |
| Internet Gateway | Attached |
| Public Route | `0.0.0.0/0` |
| EC2 Security Group | `route53-lab03-client-sg` |
| HTTP Rule | TCP 8080 from same security group |
| EC2 Access | Systems Manager |
| Private Hosted Zone | `lab03.route53.test` |
| DNS Resolver | `10.55.0.2` |

---

## 4. Understanding DNS CNAME Records

### What Is a CNAME?

CNAME stands for Canonical Name.

A CNAME record maps one hostname to another hostname.

Example:

```text
app.example.com
       |
       v
     CNAME
       |
       v
origin.example.com
```

The destination hostname must ultimately resolve to an address record for normal IPv4 or IPv6 connectivity.

### CNAME vs. A Record

| Feature | A Record | CNAME |
|---|---|---|
| Maps To | IPv4 address | Another hostname |
| Example | `10.55.1.20` | `origin.example.com` |
| Direct IP Mapping | Yes | No |
| Zone Apex Support | Yes | No |
| Typical Use | Address mapping | Alternate hostname |

### What Is a CNAME Chain?

A CNAME chain is the sequence of DNS names that must be followed to resolve an alias to its destination.

Example:

```text
app.example.com
      |
      v
service.example.com
      |
      v
server.example.com
      |
      v
10.55.1.20
```

### What Causes CNAME Misconfiguration?

Common causes include:

- Incorrect destination hostname
- Nonexistent CNAME target
- DNS record conflicts
- CNAME loops
- Incorrect hosted zone
- Cached old DNS responses
- CNAME record created at the zone apex

### Important Restrictions

A CNAME record cannot coexist with other record types at the same DNS owner name.

A standard CNAME also cannot be placed at the hosted zone apex.

Route 53 alias records provide an alternative for certain supported AWS resource targets.

---

## 5. Prerequisites and Safety

### Requirements

- AWS account
- AWS CLI v2
- WSL Ubuntu
- Bash
- Route 53 permissions
- EC2 permissions
- VPC permissions
- IAM permissions
- Systems Manager access
- Git and GitHub

### Safety Rules

- Use a disposable private hosted zone.
- Do not modify production DNS records.
- Keep test infrastructure isolated.
- Do not open SSH to the internet.
- Restrict HTTP traffic to the intended network.
- Record DNS values before changing them.
- Do not commit AWS credentials.
- Delete all temporary AWS resources after the exercise.

### Cost Considerations

Charges may apply for EC2, EBS, public IPv4 usage, and the Route 53 private hosted zone.

No domain registration is needed.

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

export PROJECT_TAG="Route53-Troubleshooting-Lab03"

export VPC_CIDR="10.55.0.0/16"
export SUBNET_CIDR="10.55.1.0/24"

export ZONE_NAME="lab03.route53.test"
export APP_NAME="app.lab03.route53.test"
export ORIGIN_NAME="origin.lab03.route53.test"
export WRONG_NAME="wrong.lab03.route53.test"

export WRONG_IP="10.55.1.250"

export EC2_ROLE_NAME="route53-lab03-ssm-role"
export PROFILE_NAME="route53-lab03-ssm-profile"
export SG_NAME="route53-lab03-client-sg"
```

### Step 3 — Verify Variables

```bash
echo "$AWS_REGION"
echo "$APP_NAME"
echo "$ORIGIN_NAME"
echo "$WRONG_NAME"
```

Keep the WSL terminal open to preserve resource ID variables throughout the exercise.

---

## 7. Create VPC and Networking

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications \
  "ResourceType=vpc,Tags=[{Key=Name,Value=route53-lab03-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
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

### Step 3 — Select Availability Zone

Check supported zones:

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

Set a supported zone:

```bash
export AZ="us-east-1a"
```

Change the zone if necessary.

### Step 4 — Create Subnet

```bash
export SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_CIDR" \
  --availability-zone "$AZ" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=route53-lab03-public},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
  "ResourceType=internet-gateway,Tags=[{Key=Name,Value=route53-lab03-igw},{Key=Project,Value=$PROJECT_TAG}]" \
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
  "ResourceType=route-table,Tags=[{Key=Name,Value=route53-lab03-public-rt},{Key=Project,Value=$PROJECT_TAG}]" \
  --query RouteTable.RouteTableId \
  --output text \
  --region "$AWS_REGION"
)
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
export CALLER_REF="route53-lab03-$(date +%s)"

export HOSTED_ZONE_ID=$(aws route53 create-hosted-zone \
  --name "$ZONE_NAME" \
  --caller-reference "$CALLER_REF" \
  --vpc "VPCRegion=$AWS_REGION,VPCId=$VPC_ID" \
  --hosted-zone-config \
  "Comment=Route53 CNAME troubleshooting Lab03,PrivateZone=true" \
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

Expected: the hosted zone is private and associated with the Lab 03 VPC.

### Step 3 — List DNS Records

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --output table
```

Initially, the hosted zone should contain default `NS` and `SOA` records.

---

## 9. Deploy EC2 HTTP Application

### Step 1 — Create Security Group

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "Route53 Lab03 application and DNS client" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Allow HTTP Traffic

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 8080 \
  --source-group "$SG_ID" \
  --region "$AWS_REGION"
```

No public HTTP ingress or SSH rule is required.

### Step 3 — Create IAM Trust Policy

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

### Step 4 — Create IAM Role

```bash
aws iam create-role \
  --role-name "$EC2_ROLE_NAME" \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam attach-role-policy \
  --role-name "$EC2_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

### Step 5 — Create Instance Profile

```bash
aws iam create-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam add-role-to-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$EC2_ROLE_NAME"
```

Allow IAM propagation.

### Step 6 — Retrieve Amazon Linux AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 7 — Launch EC2

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
  "ResourceType=instance,Tags=[{Key=Name,Value=route53-lab03-server},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")

echo "$INSTANCE_ID"
```

### Step 8 — Wait for EC2

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 9 — Retrieve Actual EC2 IP

```bash
export CORRECT_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text \
  --region "$AWS_REGION")

echo "Correct IP: $CORRECT_IP"
echo "Wrong IP:   $WRONG_IP"
```

---

## 10. Deploy and Verify the HTTP Application

### Step 1 — Connect to EC2

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 2 — Install Linux Utilities

Inside EC2:

```bash
sudo dnf install -y python3 bind-utils curl
```

### Step 3 — Create Application Directory

```bash
mkdir -p /tmp/route53-lab03
```

### Step 4 — Create Web Page

```bash
cat > /tmp/route53-lab03/index.html <<'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Route 53 Lab 03</title>
</head>
<body>
    <h1>Route 53 CNAME Troubleshooting</h1>
    <p>Application is working correctly.</p>
    <p>Lab 03 - CNAME Misconfiguration</p>
</body>
</html>
EOF
```

### Step 5 — Start HTTP Server

```bash
nohup python3 -m http.server 8080 \
  --bind 0.0.0.0 \
  --directory /tmp/route53-lab03 \
  > /tmp/route53-lab03/http.log 2>&1 \
  < /dev/null &

echo $! > /tmp/route53-lab03/server.pid
```

### Step 6 — Verify Local HTTP

```bash
curl --max-time 5 http://127.0.0.1:8080
```

Expected: successful HTML response.

### Step 7 — Verify Application Private IP

```bash
hostname -I
```

Then:

```bash
curl --max-time 5 http://YOUR_EC2_PRIVATE_IP:8080
```

Replace the placeholder with the actual EC2 private IP.

Expected: the same HTML content.

Exit:

```bash
exit
```

---

## 11. Fault Injection — Create Incorrect CNAME

### Step 1 — Create DNS Configuration

Save as `wrong-cname-records.json`.

The file will contain three Route 53 records:

| Name | Type | Value |
|---|---|---|
| origin.lab03.route53.test | A | Actual EC2 IP |
| wrong.lab03.route53.test | A | 10.55.1.250 |
| app.lab03.route53.test | CNAME | wrong.lab03.route53.test |

Generate the file using WSL:

```bash
cat > wrong-cname-records.json <<EOF
{
  "Comment": "Lab03 - Create source A records and incorrect CNAME",
  "Changes": [
    {
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "$ORIGIN_NAME",
        "Type": "A",
        "TTL": 30,
        "ResourceRecords": [
          {"Value": "$CORRECT_IP"}
        ]
      }
    },
    {
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "$WRONG_NAME",
        "Type": "A",
        "TTL": 30,
        "ResourceRecords": [
          {"Value": "$WRONG_IP"}
        ]
      }
    },
    {
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "$APP_NAME",
        "Type": "CNAME",
        "TTL": 30,
        "ResourceRecords": [
          {"Value": "$WRONG_NAME"}
        ]
      }
    }
  ]
}
EOF
```

### Step 2 — Apply Incorrect Records

```bash
export FAULT_CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch file://wrong-cname-records.json \
  --query 'ChangeInfo.Id' \
  --output text)

echo "$FAULT_CHANGE_ID"
```

### Step 3 — Wait for DNS Change

```bash
aws route53 wait resource-record-sets-changed \
  --id "$FAULT_CHANGE_ID"
```

### Step 4 — Verify DNS Records

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Type=='A' || Type=='CNAME']" \
  --output table
```

Expected:

```text
origin.lab03.route53.test   A       Actual EC2 IP
wrong.lab03.route53.test    A       10.55.1.250
app.lab03.route53.test      CNAME   wrong.lab03.route53.test
```

---

## 12. Reproduce the Application Failure

### Step 1 — Connect to EC2

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
export APP_NAME="app.lab03.route53.test"
export ORIGIN_NAME="origin.lab03.route53.test"
export WRONG_NAME="wrong.lab03.route53.test"
export VPC_DNS="10.55.0.2"
```

### Step 2 — Query CNAME

```bash
dig @"$VPC_DNS" "$APP_NAME" CNAME
```

Expected:

```text
app.lab03.route53.test. 30 IN CNAME wrong.lab03.route53.test.
```

### Step 3 — Query A Record Chain

```bash
dig @"$VPC_DNS" "$APP_NAME" A
```

Expected logical resolution:

```text
app.lab03.route53.test
          |
          v
wrong.lab03.route53.test
          |
          v
10.55.1.250
```

### Step 4 — Query Incorrect Target

```bash
dig +short @"$VPC_DNS" "$WRONG_NAME" A
```

Expected:

```text
10.55.1.250
```

### Step 5 — Query Correct Origin

```bash
dig +short @"$VPC_DNS" "$ORIGIN_NAME" A
```

Expected: actual EC2 private IP.

### Step 6 — Test HTTP Through Incorrect Hostname

```bash
curl -v \
  --connect-timeout 3 \
  --max-time 6 \
  "http://$APP_NAME:8080"
```

Expected: connection failure or timeout.

### Step 7 — Test HTTP Through Correct Origin

```bash
curl --connect-timeout 3 \
  --max-time 8 \
  "http://$ORIGIN_NAME:8080"
```

Expected: successful HTML response.

### Step 8 — Test nslookup

```bash
nslookup "$APP_NAME" "$VPC_DNS"
```

Expected: the CNAME resolves through the wrong target.

### Step 9 — Test Linux Resolver

```bash
getent ahostsv4 "$APP_NAME"
```

Expected: returned address includes `10.55.1.250`.

### Step 10 — Save Failure Evidence

```bash
dig @"$VPC_DNS" "$APP_NAME" CNAME \
  > "$HOME/lab03-before-cname.txt"

dig @"$VPC_DNS" "$APP_NAME" A \
  > "$HOME/lab03-before-a.txt"

curl -v \
  --connect-timeout 3 \
  --max-time 6 \
  "http://$APP_NAME:8080" \
  > "$HOME/lab03-before-http.txt" 2>&1 || true
```

### Fault Injection Summary

| Check | Expected Result |
|---|---|
| CNAME | Exists |
| CNAME Destination | Wrong hostname |
| Wrong Target A | 10.55.1.250 |
| Correct Origin A | Actual EC2 IP |
| DNS Status | NOERROR |
| HTTP by App Hostname | Failed |
| HTTP by Origin Hostname | Successful |
| Application Status | Healthy |

---

## 13. Troubleshooting Investigation

### Check 1 — Inspect CNAME Record

From WSL:

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${APP_NAME}.']" \
  --output json
```

Expected: `app` points to `wrong.lab03.route53.test`.

### Check 2 — Compare Actual and Expected Targets

```bash
echo "Configured CNAME Target: $WRONG_NAME"
echo "Expected CNAME Target:   $ORIGIN_NAME"
```

### Check 3 — Inspect EC2 Private IP

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{State:State.Name,PrivateIP:PrivateIpAddress}' \
  --output table \
  --region "$AWS_REGION"
```

### Check 4 — Inspect Hosted Zone

```bash
aws route53 get-hosted-zone \
  --id "$HOSTED_ZONE_ID" \
  --query '{Zone:HostedZone.Name,Private:HostedZone.Config.PrivateZone,VPCs:VPCs}' \
  --output json
```

### Check 5 — Compare DNS Records

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Type=='A' || Type=='CNAME']" \
  --output table
```

### Investigation Matrix

| Investigation | Expected Finding |
|---|---|
| Hosted Zone | Correct |
| VPC Association | Correct |
| DNS Resolver | Working |
| Application CNAME | Incorrect target |
| Origin A Record | Correct |
| Wrong A Record | 10.55.1.250 |
| Application Server | Healthy |
| HTTP via Application Name | Failed |
| Root Cause | Incorrect CNAME |

---

## 14. Root Cause Analysis

### Root Cause

The Route 53 CNAME record for `app.lab03.route53.test` was configured to point to an incorrect hostname.

The record contained:

```text
app.lab03.route53.test
    CNAME
wrong.lab03.route53.test
```

The incorrect hostname resolved to `10.55.1.250`.

However, the actual application was hosted on an EC2 instance whose private IP was associated with:

`origin.lab03.route53.test`

DNS resolution returned a valid answer, but the final address did not belong to the intended application server.

### Root Cause Flow

```text
Application Client
         |
         v
DNS Query for app.lab03.route53.test
         |
         v
Route 53 Private Hosted Zone
         |
         v
Incorrect CNAME Returned
         |
         v
wrong.lab03.route53.test
         |
         v
10.55.1.250
         |
         v
HTTP Connection Failure
```

### Five Whys

1. **Why did the application hostname fail?** HTTP requests were directed to the wrong endpoint.
2. **Why were requests sent to the wrong endpoint?** The CNAME pointed to the wrong hostname.
3. **Why did that hostname cause a failure?** It resolved to an unused private IP address.
4. **Why was the application server not responsible?** Direct HTTP requests to the correct origin succeeded.
5. **How was the incident resolved?** The application CNAME was updated to the correct origin hostname.

### Root Cause Summary

| Component | Finding |
|---|---|
| Service | Amazon Route 53 |
| Incident | CNAME Misconfiguration |
| DNS Status | NOERROR |
| Wrong Target | wrong.lab03.route53.test |
| Correct Target | origin.lab03.route53.test |
| Application Health | Healthy |
| Remediation | CNAME UPSERT |
| Infrastructure Replacement | Not required |

---

## 15. Remediation — Correct the CNAME

### Step 1 — Create Correct Change Batch

Generate `correct-cname.json`:

```bash
cat > correct-cname.json <<EOF
{
  "Comment": "Lab03 - Correct CNAME destination",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$APP_NAME",
        "Type": "CNAME",
        "TTL": 30,
        "ResourceRecords": [
          {"Value": "$ORIGIN_NAME"}
        ]
      }
    }
  ]
}
EOF
```

### Step 2 — Apply CNAME Correction

```bash
export FIX_CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch file://correct-cname.json \
  --query 'ChangeInfo.Id' \
  --output text)

echo "$FIX_CHANGE_ID"
```

### Step 3 — Wait for Route 53

```bash
aws route53 wait resource-record-sets-changed \
  --id "$FIX_CHANGE_ID"
```

### Step 4 — Verify Change Status

```bash
aws route53 get-change \
  --id "$FIX_CHANGE_ID" \
  --query 'ChangeInfo.Status' \
  --output text
```

Expected:

```text
INSYNC
```

### Step 5 — Verify Correct CNAME

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${APP_NAME}.']" \
  --output json
```

Expected:

```text
app.lab03.route53.test
    CNAME
origin.lab03.route53.test
```

---

## 16. Verify DNS and Application Recovery

### Step 1 — Connect to EC2

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
export APP_NAME="app.lab03.route53.test"
export ORIGIN_NAME="origin.lab03.route53.test"
export VPC_DNS="10.55.0.2"
```

### Step 2 — Verify CNAME

```bash
dig +short @"$VPC_DNS" "$APP_NAME" CNAME
```

Expected:

```text
origin.lab03.route53.test.
```

### Step 3 — Verify IPv4 Resolution

```bash
dig @"$VPC_DNS" "$APP_NAME" A
```

Expected resolution:

```text
app.lab03.route53.test
          |
          v
origin.lab03.route53.test
          |
          v
Actual EC2 Private IP
```

### Step 4 — Verify HTTP Access

```bash
curl --connect-timeout 3 \
  --max-time 10 \
  "http://$APP_NAME:8080"
```

Expected: successful HTML response.

### Step 5 — Verify nslookup

```bash
nslookup "$APP_NAME" "$VPC_DNS"
```

Expected: correct canonical hostname and private IP.

### Step 6 — Verify getent

```bash
getent ahostsv4 "$APP_NAME"
```

Expected: actual EC2 private IP.

### Step 7 — Save Recovery Evidence

```bash
dig @"$VPC_DNS" "$APP_NAME" CNAME \
  > "$HOME/lab03-after-cname.txt"

dig @"$VPC_DNS" "$APP_NAME" A \
  > "$HOME/lab03-after-a.txt"

curl -v \
  --max-time 10 \
  "http://$APP_NAME:8080" \
  > "$HOME/lab03-after-http.txt" 2>&1
```

### Before and After Comparison

| Check | Before Fix | After Fix |
|---|---|---|
| CNAME Target | Wrong hostname | Correct origin |
| Final IP | 10.55.1.250 | Actual EC2 IP |
| DNS Status | NOERROR | NOERROR |
| HTTP by App Hostname | Failed | Successful |
| HTTP by Origin | Successful | Successful |
| Application Health | Healthy | Healthy |
| Incident | Active | Resolved |

### Important Note About DNS Caching

Route 53 may report `INSYNC` before previously cached DNS answers expire.

If the old CNAME remains visible, allow its TTL to expire and query again.

---

## 17. Production Best Practices

### CNAME Troubleshooting Checklist

1. Identify the affected hostname.
2. Query the CNAME using `dig`.
3. Follow the CNAME to its target.
4. Query the target's A or AAAA record.
5. Compare the final address with the intended infrastructure.
6. Test the origin application directly.
7. Inspect the Route 53 hosted zone.
8. Verify VPC association for private zones.
9. Confirm the CNAME does not conflict with other record types.
10. Apply the smallest appropriate DNS correction.
11. Verify the Route 53 change status.
12. Test DNS and application recovery.
13. Account for TTL and caching.
14. Document the incident and rollback procedure.

### Security Recommendations

- Use least-privilege IAM access for Route 53.
- Protect production hosted zones.
- Review DNS changes before deployment.
- Monitor critical DNS records.
- Avoid CNAME records pointing to untrusted destinations.
- Use infrastructure as code for DNS configuration.
- Maintain rollback procedures.
- Keep internal DNS records private when appropriate.
- Remove unused DNS records.
- Verify endpoints before updating aliases.

### Common CNAME Errors

| Error | Possible Cause |
|---|---|
| Wrong Destination | CNAME points to incorrect hostname |
| NXDOMAIN | CNAME destination or a required target name does not exist |
| CNAME Loop | Records reference each other recursively |
| Invalid CNAME | Record conflicts or zone-apex restriction |
| Wrong Final IP | Destination's A record is incorrect |
| Old Destination Returned | Cached DNS response |
| Correct DNS, Failed HTTP | Application or network issue |

---

## 18. AWS Resource Cleanup

**Warning:** These commands permanently delete the disposable Lab 03 resources.

### Step 1 — Stop HTTP Server

Inside EC2:

```bash
if [[ -f /tmp/route53-lab03/server.pid ]]; then
  kill "$(cat /tmp/route53-lab03/server.pid")" 2>/dev/null || true
fi
```

Exit:

```bash
exit
```

### Step 2 — Create DNS Delete Batch

From WSL:

```bash
cat > delete-dns-records.json <<EOF
{
  "Comment": "Lab03 - Delete test DNS records",
  "Changes": [
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "$APP_NAME",
        "Type": "CNAME",
        "TTL": 30,
        "ResourceRecords": [
          {"Value": "$ORIGIN_NAME"}
        ]
      }
    },
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "$ORIGIN_NAME",
        "Type": "A",
        "TTL": 30,
        "ResourceRecords": [
          {"Value": "$CORRECT_IP"}
        ]
      }
    },
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "$WRONG_NAME",
        "Type": "A",
        "TTL": 30,
        "ResourceRecords": [
          {"Value": "$WRONG_IP"}
        ]
      }
    }
  ]
}
EOF
```

A Route 53 `DELETE` request must match the current record set values, including its TTL and destination. Verify the existing records if you made any additional changes.

### Step 3 — Delete DNS Records

```bash
export DELETE_CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch file://delete-dns-records.json \
  --query 'ChangeInfo.Id' \
  --output text)

aws route53 wait resource-record-sets-changed \
  --id "$DELETE_CHANGE_ID"
```

### Step 4 — Verify Record Deletion

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --output table
```

Expected: only the default NS and SOA records remain.

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

Expected:

```json
[]
```

### Step 7 — Verify EC2 Root Volume

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings' \
  --output json \
  --region "$AWS_REGION"
```

Verify root volume `DeleteOnTermination=true`.

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

Confirm the lab project tag.

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

Wait until the EC2 network interface has been removed.

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

Check hosted zone:

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

Also confirm EC2 termination, EBS deletion, and IAM cleanup.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| Application CNAME | Deleted |
| Origin A Record | Deleted |
| Wrong A Record | Deleted |
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

## 19. Interview Questions and Answers

### Q1. What is a CNAME record?

A CNAME record maps one DNS hostname to another hostname.

### Q2. How is CNAME different from an A record?

An A record maps a hostname to an IPv4 address. A CNAME maps a hostname to another hostname.

### Q3. What happens when a CNAME points to the wrong hostname?

DNS may resolve successfully, but application traffic is directed toward the wrong destination.

### Q4. Can a CNAME point directly to an IP address?

No. A CNAME value must be a hostname.

### Q5. Can you create a CNAME at the hosted zone apex?

No. Standard DNS rules do not allow a CNAME at the zone apex.

### Q6. Can a CNAME coexist with an A record at the same hostname?

No. A CNAME cannot coexist with other DNS record types at the same owner name.

### Q7. What is a CNAME loop?

A circular DNS alias chain in which records eventually point back to a previously visited hostname.

### Q8. How do you inspect a CNAME?

```bash
dig app.example.com CNAME
```

### Q9. How do you find the final IPv4 address?

```bash
dig app.example.com A
```

You may need to query the CNAME target separately.

### Q10. What does Route 53 UPSERT do?

It updates an existing DNS record set or creates one if it doesn't exist.

### Q11. Why might the old CNAME remain after an update?

Recursive DNS caching can retain an older response until its TTL expires.

### Q12. How would you explain this lab in an interview?

I deployed a private Route 53 hosted zone and an EC2 instance running a simple HTTP application.

I created an origin A record pointing to the EC2 private IP and another A record pointing to an incorrect address.

I then intentionally configured an application CNAME to point to the wrong hostname.

DNS resolution succeeded, but HTTP requests failed because the CNAME ultimately resolved to the incorrect IP.

I investigated the DNS chain using `dig`, `nslookup`, AWS CLI, and direct HTTP connectivity tests.

After identifying the incorrect CNAME destination, I updated it using Route 53 UPSERT.

I verified that the application hostname resolved to the correct EC2 private IP and that HTTP connectivity succeeded.

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
└── 03-cname-misconfiguration/
    ├── README.md
    ├── ec2-trust-policy.json
    ├── wrong-cname-records.json
    ├── correct-cname.json
    └── delete-dns-records.json
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete incident investigation and remediation documentation |
| `ec2-trust-policy.json` | IAM trust policy for EC2 Systems Manager |
| `wrong-cname-records.json` | Creates the initial A records and incorrect CNAME |
| `correct-cname.json` | Corrects the CNAME using UPSERT |
| `delete-dns-records.json` | Removes all three test records during cleanup |

Do not commit credentials, authentication tokens, or sensitive infrastructure information.

---

## 21. Lessons Learned and Skills Demonstrated

### Lessons Learned

This lab demonstrates how an incorrect CNAME can make a healthy web application appear unavailable.

We deployed an EC2 HTTP application and created a private Route 53 hosted zone.

We configured correct and incorrect A records, then intentionally pointed the application's CNAME to the wrong hostname.

We reproduced HTTP connection failures while DNS continued to return a successful response.

We investigated the CNAME chain and compared the incorrect target against the actual EC2 application address.

We corrected the CNAME using Route 53 UPSERT and verified that the application became reachable through its intended hostname.

The lab also demonstrated the importance of understanding DNS caching, CNAME restrictions, private hosted zones, and application connectivity.

**Key Lesson:** When DNS resolution succeeds but an application cannot be reached, inspect the full CNAME chain and verify the final destination before changing healthy application infrastructure.

### Skills Demonstrated

- Amazon Route 53
- Private hosted zones
- DNS CNAME records
- DNS A records
- CNAME chain troubleshooting
- AWS CLI v2
- Route 53 UPSERT
- DNS TTL and caching
- Linux `dig`
- Linux `nslookup`
- Linux `getent`
- Linux `curl`
- Amazon EC2
- Python HTTP server
- VPC networking
- AWS Systems Manager
- IAM roles
- Root cause analysis
- DNS remediation
- Application connectivity verification
- AWS resource cleanup

### Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-R53-003 |
| Scenario | CNAME Misconfiguration |
| Hosted Zone | Private |
| Fault | Incorrect CNAME target |
| Incorrect Target | wrong.lab03.route53.test |
| Correct Target | origin.lab03.route53.test |
| Wrong IP | 10.55.1.250 |
| Correct IP | Actual EC2 private IP |
| DNS Before Fix | NOERROR, wrong target |
| HTTP Before Fix | Failed |
| Root Cause | Incorrect CNAME |
| Remediation | Route 53 UPSERT |
| DNS After Fix | Correct target |
| HTTP After Fix | Successful |
| Cleanup | Temporary infrastructure removed |
| Incident Status | Resolved after verification |

**Key Takeaway:** Effective CNAME troubleshooting requires following the DNS alias chain, validating its final IP address, and testing application connectivity. A successful DNS response does not guarantee that the application hostname points to the correct server.
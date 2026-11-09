# Lab 02 — Route 53 Wrong A Record

## Overview

This lab demonstrates how to troubleshoot an incorrect DNS A record in Amazon Route 53 using AWS CLI, Linux DNS utilities, and an EC2-hosted web application.

We deploy a private Route 53 hosted zone associated with an Amazon VPC and launch an EC2 instance running Amazon Linux 2023.

The EC2 instance hosts a simple HTTP application on port `8080`.

We intentionally create an A record pointing to an incorrect private IPv4 address, causing requests to fail even though DNS resolution succeeds.

We investigate the issue using `dig`, `nslookup`, `curl`, AWS CLI, and EC2 instance information.

After identifying the incorrect A record, we update it using a Route 53 `UPSERT` operation.

Finally, we verify that the hostname resolves to the correct EC2 private IP address, confirm successful HTTP connectivity, and delete the temporary AWS infrastructure.

**Troubleshooting workflow:**

Infrastructure Setup → Application Deployment → Wrong A Record → DNS Investigation → Root Cause Analysis → Remediation → DNS Verification → Application Recovery → Cleanup

---

## 1. Lab Information

| Item | Configuration |
|---|---|
| Incident ID | INC-R53-002 |
| Difficulty | Beginner–Intermediate |
| AWS Region | `us-east-1` |
| AWS Services | Route 53, EC2, VPC, IAM, Systems Manager |
| Local Environment | WSL Ubuntu |
| EC2 Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| VPC CIDR | `10.54.0.0/16` |
| Public Subnet | `10.54.1.0/24` |
| Hosted Zone | `lab02.route53.test` |
| Hosted Zone Type | Private |
| Application Hostname | `app.lab02.route53.test` |
| DNS Record Type | A |
| Incorrect Record IP | `10.54.1.250` |
| Correct Record IP | EC2 private IP assigned by AWS |
| DNS TTL | 30 seconds |
| Web Application Port | TCP 8080 |
| VPC DNS Resolver | `10.54.0.2` |
| EC2 Access Method | AWS Systems Manager |
| Fault Injection | Incorrect A record value |
| Expected DNS Response | `NOERROR` with wrong IP |
| Expected HTTP Result | Connection failure |
| Remediation | Update A record using UPSERT |
| Verification | `dig`, `nslookup`, `getent`, `curl` |
| Incident Status | Resolved after successful verification |

---

## 2. Production Incident Scenario

### Incident Description

A company hosts an internal web application on an Amazon EC2 instance.

Employees access the application through a DNS hostname:

`app.lab02.route53.test`

The application is running normally and responding to HTTP requests on port `8080`.

However, users report that the application cannot be accessed through its hostname.

The Cloud Engineer investigates and discovers that the Route 53 A record points to an incorrect private IP address.

The DNS lookup itself succeeds, but the returned IP address does not belong to the application server.

As a result, HTTP requests are directed to the wrong destination.

The engineer must identify the incorrect record, update it to the actual EC2 private IP, and verify that both DNS resolution and HTTP access work.

### Incident Symptoms

- Application is running successfully on EC2.
- Direct HTTP requests to the correct IP succeed.
- DNS hostname resolves successfully.
- `dig` reports `NOERROR`.
- DNS returns an incorrect IPv4 address.
- HTTP requests through the hostname fail.
- Route 53 A record does not match the actual EC2 private IP.
- Updating the A record restores application connectivity.

### Business Impact

- Users cannot access the application through its hostname.
- Internal application requests fail.
- Application availability appears degraded.
- DNS-dependent services may become unavailable.
- Engineers may waste time troubleshooting healthy application infrastructure.
- Incorrect DNS mappings can direct traffic to unintended destinations.

### Objective

Identify and correct an invalid Route 53 A record while verifying that the underlying application and network infrastructure remain operational.

---

## 3. AWS Architecture

### Infrastructure Architecture

```text
                       AWS Region
                        us-east-1
                            |
                            v
                       Amazon VPC
                     10.54.0.0/16
                            |
             --------------------------------
             |                              |
             v                              v
        Public Subnet                  Route 53
       10.54.1.0/24               Private Hosted Zone
             |                     lab02.route53.test
             v                              |
         EC2 Instance                       |
      Amazon Linux 2023                     |
             |                              |
             v                              v
       HTTP Server                     DNS A Record
         Port 8080                     10.54.1.250
             |                              |
             v                              v
       Actual EC2 IP                  Incorrect IP
         10.54.1.x                         |
             |                              v
             |                       HTTP Connection
             |                           Failure
             |
             v
       Application Healthy
```

### Architecture After Remediation

```text
       EC2 DNS Client
              |
              v
        DNS Query
              |
              v
       VPC DNS Resolver
         10.54.0.2
              |
              v
     Route 53 Private Zone
              |
              v
   app.lab02.route53.test
              |
              v
        Correct A Record
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
| VPC | `10.54.0.0/16` |
| Public Subnet | `10.54.1.0/24` |
| EC2 Instance | `t3.micro` |
| EC2 OS | Amazon Linux 2023 |
| Internet Gateway | Attached |
| Public Route | `0.0.0.0/0` through IGW |
| EC2 Security Group | `route53-lab02-client-sg` |
| HTTP Inbound | TCP 8080 from same security group |
| EC2 Access | Systems Manager |
| Private Hosted Zone | `lab02.route53.test` |
| DNS Resolver | `10.54.0.2` |
| Wrong A Record | `10.54.1.250` |
| Correct A Record | Actual EC2 private IP |

---

## 4. Understanding Route 53 A Records

### What Is an A Record?

A DNS A record maps a hostname to an IPv4 address.

Example:

```text
app.lab02.route53.test
          |
          v
        A Record
          |
          v
       10.54.1.25
```

The IP above is an example. The actual address is assigned by AWS.

### What Happens When an A Record Is Wrong?

DNS can return a valid response containing an incorrect IP address.

Example:

```text
Hostname: app.lab02.route53.test
DNS Status: NOERROR
Returned IP: 10.54.1.250
Actual Server IP: Different
```

The client then attempts to connect to the wrong destination.

### NXDOMAIN vs. Wrong A Record

| Feature | Missing A Record | Wrong A Record |
|---|---|---|
| DNS Name Exists | No, in our Lab 01 scenario | Yes |
| DNS Response | NXDOMAIN | NOERROR |
| IPv4 Address Returned | No | Yes |
| Address Correct | Not applicable | No |
| Main Problem | DNS name missing | Incorrect DNS target |

### What Is TTL?

TTL stands for Time to Live.

It controls how long recursive DNS resolvers may cache a response.

This lab uses:

```text
TTL = 30 seconds
```

After updating the A record, some clients may continue using the cached incorrect IP until their cached response expires.

### What Is UPSERT?

Route 53 `UPSERT` updates an existing DNS record set or creates it if the record does not already exist.

Example:

```text
Before:
app.lab02.route53.test -> 10.54.1.250

After:
app.lab02.route53.test -> Actual EC2 Private IP
```

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
- Systems Manager access
- Git and GitHub

### Safety Rules

- Use a disposable private hosted zone.
- Do not modify production DNS.
- Do not use real customer data.
- Avoid opening SSH to the internet.
- Restrict test HTTP traffic to the intended network.
- Verify actual EC2 private IP before correcting DNS.
- Do not commit AWS credentials.
- Record the original DNS value before changing it.
- Delete temporary AWS resources after testing.

### Cost Considerations

Charges may apply for the private hosted zone, EC2 instance, EBS storage, and public IPv4 address.

No domain registration is required.

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

export PROJECT_TAG="Route53-Troubleshooting-Lab02"

export VPC_CIDR="10.54.0.0/16"
export SUBNET_CIDR="10.54.1.0/24"

export ZONE_NAME="lab02.route53.test"
export RECORD_NAME="app.lab02.route53.test"

export WRONG_IP="10.54.1.250"

export EC2_ROLE_NAME="route53-lab02-ssm-role"
export PROFILE_NAME="route53-lab02-ssm-profile"
export SG_NAME="route53-lab02-client-sg"
```

### Step 3 — Verify Variables

```bash
echo "$AWS_REGION"
echo "$RECORD_NAME"
echo "$WRONG_IP"
```

Expected:

```text
us-east-1
app.lab02.route53.test
10.54.1.250
```

---

## 7. Create VPC and Networking

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications \
  "ResourceType=vpc,Tags=[{Key=Name,Value=route53-lab02-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
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

### Step 3 — Create Subnet

First verify the instance type is offered in your intended Availability Zone:

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

Set an available zone:

```bash
export AZ="us-east-1a"
```

Create subnet:

```bash
export SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_CIDR" \
  --availability-zone "$AZ" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=route53-lab02-public},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
  "ResourceType=internet-gateway,Tags=[{Key=Name,Value=route53-lab02-igw},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region "$AWS_REGION")

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Create Public Route Table

```bash
export ROUTE_TABLE_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=route-table,Tags=[{Key=Name,Value=route53-lab02-public-rt},{Key=Project,Value=$PROJECT_TAG}]" \
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

## 8. Create Route 53 Private Hosted Zone

### Step 1 — Create Hosted Zone

```bash
export CALLER_REF="route53-lab02-$(date +%s)"

export HOSTED_ZONE_ID=$(aws route53 create-hosted-zone \
  --name "$ZONE_NAME" \
  --caller-reference "$CALLER_REF" \
  --vpc "VPCRegion=$AWS_REGION,VPCId=$VPC_ID" \
  --hosted-zone-config \
  "Comment=Route53 Wrong A Record Lab02,PrivateZone=true" \
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

Expected: the zone is private and associated with the Lab 02 VPC.

---

## 9. Deploy EC2 Web Application Server

### Step 1 — Create Security Group

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "Route53 Lab02 EC2 web application" \
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

This allows TCP 8080 traffic from network interfaces associated with the same security group.

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
  --region "$AWS_REGION"
)
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
  "ResourceType=instance,Tags=[{Key=Name,Value=route53-lab02-server},{Key=Project,Value=$PROJECT_TAG}]" \
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

echo "Wrong DNS IP: $WRONG_IP"
echo "Actual EC2 IP: $CORRECT_IP"
```

These addresses should be different.

---

## 10. Deploy and Verify HTTP Application

### Step 1 — Connect to EC2

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 2 — Install Tools

Inside EC2:

```bash
sudo dnf install -y bind-utils python3 curl
```

### Step 3 — Create Application Directory

```bash
mkdir -p /tmp/route53-lab02
```

### Step 4 — Create Test Web Page

```bash
cat > /tmp/route53-lab02/index.html <<'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Route 53 Lab 02</title>
</head>
<body>
    <h1>Route 53 DNS Troubleshooting</h1>
    <p>Application is running successfully.</p>
    <p>Lab 02 - Wrong A Record</p>
</body>
</html>
EOF
```

### Step 5 — Start HTTP Server

```bash
nohup python3 -m http.server 8080 \
  --bind 0.0.0.0 \
  --directory /tmp/route53-lab02 \
  > /tmp/route53-lab02/http.log 2>&1 \
  < /dev/null &

echo $! > /tmp/route53-lab02/server.pid
```

### Step 6 — Verify Local HTTP

```bash
curl --max-time 5 http://127.0.0.1:8080
```

Expected: the HTML page appears.

### Step 7 — Verify EC2 Private IP Connectivity

Get local addresses:

```bash
hostname -I
```

Test the correct private IP:

```bash
curl --max-time 5 http://YOUR_EC2_PRIVATE_IP:8080
```

Expected: the application responds successfully.

Exit EC2:

```bash
exit
```

---

## 11. Fault Injection — Create Wrong A Record

### Step 1 — Create Wrong Record JSON

Save as `wrong-a-record.json`:

```json
{
  "Comment": "Lab02 - Intentionally configure wrong A record",
  "Changes": [
    {
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "app.lab02.route53.test",
        "Type": "A",
        "TTL": 30,
        "ResourceRecords": [
          {
            "Value": "10.54.1.250"
          }
        ]
      }
    }
  ]
}
```

### Step 2 — Create Incorrect A Record

```bash
export FAULT_CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch file://wrong-a-record.json \
  --query 'ChangeInfo.Id' \
  --output text)

aws route53 wait resource-record-sets-changed \
  --id "$FAULT_CHANGE_ID"
```

### Step 3 — Verify Wrong Record

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}.']" \
  --output json
```

Expected:

```text
Name: app.lab02.route53.test
Type: A
Value: 10.54.1.250
TTL: 30
```

---

## 12. Reproduce Application Failure

### Step 1 — Connect to EC2

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Configure environment:

```bash
export RECORD_NAME="app.lab02.route53.test"
export WRONG_IP="10.54.1.250"
export VPC_DNS="10.54.0.2"
```

### Step 2 — Verify DNS

```bash
dig @"$VPC_DNS" "$RECORD_NAME" A
```

Expected:

```text
status: NOERROR
```

The answer should contain:

```text
10.54.1.250
```

### Step 3 — Verify Short DNS Answer

```bash
dig +short @"$VPC_DNS" "$RECORD_NAME" A
```

Expected:

```text
10.54.1.250
```

### Step 4 — Test nslookup

```bash
nslookup "$RECORD_NAME" "$VPC_DNS"
```

Expected: the wrong IP address.

### Step 5 — Test HTTP Through DNS

```bash
curl -v \
  --connect-timeout 3 \
  --max-time 5 \
  "http://$RECORD_NAME:8080"
```

Expected: HTTP connection failure or timeout.

### Step 6 — Verify Application Health

```bash
curl --max-time 5 http://127.0.0.1:8080
```

Expected: successful HTML response.

### Step 7 — Save Evidence

```bash
dig @"$VPC_DNS" "$RECORD_NAME" A \
  > "$HOME/lab02-before-dns.txt"
```

```bash
curl -v \
  --connect-timeout 3 \
  --max-time 5 \
  "http://$RECORD_NAME:8080" \
  > "$HOME/lab02-before-http.txt" 2>&1 || true
```

### Fault Injection Summary

| Check | Expected Result |
|---|---|
| DNS Hostname | Resolves |
| DNS Response | NOERROR |
| Returned IP | Wrong |
| HTTP by Hostname | Fails |
| HTTP by Correct EC2 IP | Works |
| Application Process | Running |
| Root Cause | Incorrect DNS A record |

---

## 13. Troubleshooting Investigation

### Check 1 — Inspect Hosted Zone

From WSL:

```bash
aws route53 get-hosted-zone \
  --id "$HOSTED_ZONE_ID" \
  --query '{Zone:HostedZone.Name,Private:HostedZone.Config.PrivateZone,VPCs:VPCs}' \
  --output json
```

### Check 2 — Inspect A Record

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}.']" \
  --output json
```

Expected: `10.54.1.250`.

### Check 3 — Inspect EC2 Private IP

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{ID:InstanceId,PrivateIP:PrivateIpAddress,State:State.Name}' \
  --output table \
  --region "$AWS_REGION"
```

### Check 4 — Compare IP Addresses

```bash
echo "Route 53 A Record: $WRONG_IP"
echo "Actual EC2 IP:    $CORRECT_IP"
```

Expected: the addresses are different.

### Check 5 — Confirm Application Is Working

Inside EC2:

```bash
curl --max-time 5 http://127.0.0.1:8080
```

Expected: successful response.

### Investigation Matrix

| Investigation | Expected Finding |
|---|---|
| Hosted Zone | Correct |
| VPC Association | Correct |
| VPC Resolver | Working |
| A Record | Incorrect IP |
| Actual EC2 IP | Different |
| Application Process | Healthy |
| DNS Resolution | Successful |
| HTTP Through Hostname | Failed |
| Root Cause | Wrong A record |

---

## 14. Root Cause Analysis

### Root Cause

The Route 53 A record for `app.lab02.route53.test` contained an incorrect private IPv4 address.

The record pointed to:

```text
10.54.1.250
```

However, the application was running on an EC2 instance with a different private IP assigned by AWS.

DNS resolution succeeded, but HTTP requests were directed to the wrong network destination.

The application infrastructure itself was healthy.

### Root Cause Flow

```text
Application Client
         |
         v
DNS Query for app.lab02.route53.test
         |
         v
Route 53 Private Hosted Zone
         |
         v
Wrong A Record Returned
         |
         v
10.54.1.250
         |
         v
HTTP Connection Failure
```

### Five Whys

1. **Why did the application fail?** Requests through the hostname could not establish an HTTP connection.
2. **Why did the requests fail?** The hostname resolved to the wrong IP address.
3. **Why was the wrong IP returned?** The Route 53 A record contained an incorrect value.
4. **Why was the application itself healthy?** Direct HTTP requests to the actual EC2 IP succeeded.
5. **How was the issue resolved?** The A record was updated to the correct EC2 private IP.

### Root Cause Summary

| Component | Finding |
|---|---|
| Service | Route 53 |
| Incident | Wrong A record |
| DNS Status | NOERROR |
| Wrong Target | `10.54.1.250` |
| Correct Target | Actual EC2 private IP |
| Application Health | Healthy |
| Fix | UPSERT A record |
| Infrastructure Replacement | Not required |

---

## 15. Remediation — Correct the A Record

### Step 1 — Create Correct Change Batch

In WSL, create `correct-a-record.json` using the actual EC2 private IP:

```bash
cat > correct-a-record.json <<EOF
{
  "Comment": "Lab02 - Correct wrong A record",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$RECORD_NAME",
        "Type": "A",
        "TTL": 30,
        "ResourceRecords": [
          {
            "Value": "$CORRECT_IP"
          }
        ]
      }
    }
  ]
}
EOF
```

### Step 2 — Update A Record

```bash
export FIX_CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch file://correct-a-record.json \
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

### Step 5 — Verify Correct A Record

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}.']" \
  --output json
```

Expected: the A record contains the actual EC2 private IP.

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
export RECORD_NAME="app.lab02.route53.test"
export VPC_DNS="10.54.0.2"
```

### Step 2 — Verify Correct DNS Resolution

```bash
dig +short @"$VPC_DNS" "$RECORD_NAME" A
```

Expected: the actual EC2 private IP.

### Step 3 — Verify Linux Resolution

```bash
getent ahostsv4 "$RECORD_NAME"
```

Expected: the correct EC2 private IP.

### Step 4 — Verify HTTP Access

```bash
curl --connect-timeout 3 \
  --max-time 10 \
  "http://$RECORD_NAME:8080"
```

Expected: the application's HTML page.

### Step 5 — Save Recovery Evidence

```bash
dig @"$VPC_DNS" "$RECORD_NAME" A \
  > "$HOME/lab02-after-dns.txt"
```

```bash
curl -v \
  --max-time 10 \
  "http://$RECORD_NAME:8080" \
  > "$HOME/lab02-after-http.txt" 2>&1
```

### Before and After Comparison

| Check | Before Fix | After Fix |
|---|---|---|
| DNS Response | NOERROR | NOERROR |
| A Record Value | Wrong IP | Actual EC2 IP |
| DNS Resolution | Successful | Successful |
| HTTP by Hostname | Failed | Successful |
| HTTP by Actual IP | Successful | Successful |
| Application Status | Healthy | Healthy |
| Incident | Active | Resolved |

### Final Verification

```bash
dig +short @10.54.0.2 app.lab02.route53.test A
```

```bash
curl --max-time 10 http://app.lab02.route53.test:8080
```

Both commands should succeed.

---

## 17. DNS Caching and Operational Considerations

### Understanding Cached DNS Answers

Even after Route 53 reports `INSYNC`, a client might temporarily receive the previous IP address from a recursive DNS cache.

This happens because DNS answers can be cached for their configured TTL.

We used a TTL of 30 seconds.

### Important Distinction

`INSYNC` means that Route 53 has applied the DNS change to its relevant DNS servers.

It does not guarantee that every client or recursive resolver has discarded its previous cached response.

### Operational Best Practices

- Verify DNS changes using an appropriate DNS resolver.
- Compare the returned IP against the actual infrastructure.
- Consider TTL when planning changes.
- Allow cached responses to expire when necessary.
- Avoid unnecessary record deletion and recreation.
- Maintain a tested rollback plan.
- Use stable endpoints for production applications.

---

## 18. AWS Resource Cleanup

**Warning:** Delete only the resources created for Lab 02.

### Step 1 — Stop HTTP Server

Inside EC2:

```bash
if [[ -f /tmp/route53-lab02/server.pid ]]; then
  kill "$(cat /tmp/route53-lab02/server.pid)" 2>/dev/null || true
fi
```

Exit:

```bash
exit
```

### Step 2 — Create DNS Delete Batch

In WSL:

```bash
cat > delete-a-record.json <<EOF
{
  "Comment": "Lab02 cleanup - delete A record",
  "Changes": [
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "$RECORD_NAME",
        "Type": "A",
        "TTL": 30,
        "ResourceRecords": [
          {
            "Value": "$CORRECT_IP"
          }
        ]
      }
    }
  ]
}
EOF
```

### Step 3 — Delete A Record

```bash
export DELETE_CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch file://delete-a-record.json \
  --query 'ChangeInfo.Id' \
  --output text)

aws route53 wait resource-record-sets-changed \
  --id "$DELETE_CHANGE_ID"
```

### Step 4 — Verify DNS Record Removal

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --output table
```

Expected: only default NS and SOA records remain.

### Step 5 — Delete Hosted Zone

```bash
aws route53 delete-hosted-zone \
  --id "$HOSTED_ZONE_ID"
```

### Step 6 — Verify EC2 Root Volume

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings' \
  --output json \
  --region "$AWS_REGION"
```

Confirm root EBS volume `DeleteOnTermination=true`.

### Step 7 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Verify IAM Role Tags

```bash
aws iam list-role-tags \
  --role-name "$EC2_ROLE_NAME"
```

Confirm the resource belongs to Lab 02.

### Step 9 — Delete IAM Resources

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

### Step 10 — Verify Network Interface Removal

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Wait until the instance's network interface is removed.

### Step 11 — Delete Security Group

```bash
aws ec2 delete-security-group \
  --group-id "$SG_ID" \
  --region "$AWS_REGION"
```

### Step 12 — Delete Route Table

```bash
aws ec2 disassociate-route-table \
  --association-id "$ROUTE_ASSOC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-route-table \
  --route-table-id "$ROUTE_TABLE_ID" \
  --region "$AWS_REGION"
```

### Step 13 — Delete Subnet

```bash
aws ec2 delete-subnet \
  --subnet-id "$SUBNET_ID" \
  --region "$AWS_REGION"
```

### Step 14 — Delete Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 15 — Delete VPC

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 16 — Verify Cleanup

Check hosted zone:

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

Verify that EC2 is terminated and IAM resources are removed.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| Incorrect/Corrected A Record | Deleted |
| Private Hosted Zone | Deleted |
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

### Q1. What is a DNS A record?

An A record maps a DNS hostname to an IPv4 address.

### Q2. What happens when an A record points to the wrong IP?

DNS resolution can succeed, but application traffic is directed to the incorrect network destination.

### Q3. What is the difference between NXDOMAIN and a wrong A record?

NXDOMAIN indicates a nonexistent DNS name. A wrong A record returns a valid DNS answer containing an incorrect IP address.

### Q4. What does NOERROR mean?

The DNS server successfully processed the query. It does not necessarily mean the returned application endpoint is correct.

### Q5. How do you verify an A record?

```bash
dig example.com A
```

### Q6. How do you find the private IP of an EC2 instance?

```bash
aws ec2 describe-instances \
  --instance-ids INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text
```

### Q7. What is Route 53 UPSERT?

An operation that creates a DNS record if it is absent or updates an existing record set.

### Q8. What is DNS TTL?

Time to Live specifies how long DNS responses may be cached.

### Q9. Why can HTTP fail when DNS succeeds?

The returned IP may be incorrect, the network path may be blocked, or the application may not be listening.

### Q10. Why use a private hosted zone?

It allows DNS names to be resolved within associated AWS VPCs without publishing those records through public DNS.

### Q11. How do you distinguish DNS failure from application failure?

Compare DNS answers with the actual server IP and test application connectivity directly.

### Q12. How would you explain this lab in an interview?

I deployed a private Route 53 hosted zone and an EC2 instance running a simple HTTP application.

I intentionally created an A record pointing to an incorrect private IP address.

The hostname resolved successfully, but HTTP requests failed because the DNS answer pointed to the wrong destination.

I investigated the issue using `dig`, `nslookup`, AWS CLI, and EC2 instance metadata.

I confirmed that the application was healthy by testing its actual private IP address.

After identifying the incorrect Route 53 A record, I corrected it using an UPSERT operation.

I verified that the hostname resolved to the proper EC2 private IP and that HTTP requests succeeded.

Finally, I deleted the temporary Route 53 and EC2 infrastructure.

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
└── 02-wrong-a-record/
    ├── README.md
    ├── ec2-trust-policy.json
    ├── wrong-a-record.json
    ├── correct-a-record.json
    └── delete-a-record.json
```

### File Descriptions

| File | Purpose |
|---|---|
| README.md | Complete incident and troubleshooting documentation |
| ec2-trust-policy.json | IAM trust policy for Systems Manager |
| wrong-a-record.json | Creates the incorrect Route 53 A record |
| correct-a-record.json | Corrects the A record using UPSERT |
| delete-a-record.json | Deletes the DNS record during cleanup |

Do not commit AWS credentials, authentication files, or sensitive infrastructure information.

---

## 21. Lessons Learned and Skills Demonstrated

### Lessons Learned

This lab demonstrates that successful DNS resolution does not always mean an application is reachable.

We created an EC2 HTTP application and a private Route 53 hosted zone.

We intentionally configured the application's hostname to point to an incorrect private IP.

We reproduced the incident by showing that DNS returned `NOERROR` with the wrong IP address, while HTTP requests through the hostname failed.

We verified that the application itself was healthy by connecting directly to the correct EC2 IP address.

We investigated the problem using AWS CLI and Linux DNS utilities and corrected the A record using Route 53 UPSERT.

After remediation, we verified that DNS returned the actual EC2 private IP and HTTP connectivity worked.

**Key Lesson:** When DNS resolution succeeds but an application remains unreachable, always compare the DNS response with the actual resource endpoint before changing application, security group, or network configurations.

### Skills Demonstrated

- Amazon Route 53
- Private hosted zones
- DNS A records
- Wrong IP troubleshooting
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
- Security groups
- AWS Systems Manager
- IAM roles
- Root cause analysis
- Application connectivity testing
- DNS remediation
- AWS resource cleanup

### Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-R53-002 |
| Scenario | Wrong A Record |
| DNS Record | A |
| Hostname | `app.lab02.route53.test` |
| Wrong IP | `10.54.1.250` |
| Correct IP | Actual EC2 private IP |
| DNS Before Fix | NOERROR with incorrect IP |
| HTTP Before Fix | Failed |
| Root Cause | Wrong A record |
| Remediation | Route 53 UPSERT |
| DNS After Fix | Correct IP |
| HTTP After Fix | Successful |
| Cleanup | Temporary resources removed |
| Incident Status | Resolved after verification |

**Key Takeaway:** Reliable cloud DNS troubleshooting requires verifying both the returned DNS address and the actual destination service. A correct DNS response code alone does not guarantee application availability.
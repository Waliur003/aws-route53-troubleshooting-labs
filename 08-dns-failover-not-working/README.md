# Lab 08 — Route 53 DNS Failover Not Working

## Overview

This lab demonstrates how to troubleshoot Amazon Route 53 DNS failover when traffic continues to reach a failed primary application instead of switching to a healthy secondary endpoint.

We deploy two Amazon EC2 instances inside an AWS VPC. Each instance runs a Python HTTP application on port `8080`.

One instance acts as the primary application server, while the other serves as the secondary or backup server.

We create an Amazon Route 53 public hosted zone and configure two DNS A records using the failover routing policy.

The primary record is associated with a Route 53 HTTP health check.

We intentionally misconfigure that health check to monitor the **secondary EC2 instance instead of the primary**.

After stopping the primary application, Route 53 continues considering the primary record healthy because its associated health check still receives successful responses from the secondary server.

As a result, DNS continues returning the failed primary endpoint.

We investigate the failover records, health check configuration, DNS responses, and HTTP connectivity using AWS CLI, Linux, `dig`, `curl`, and Systems Manager.

We correct the health check IP address to monitor the actual primary server. Once Route 53 detects the failure, DNS begins returning the secondary endpoint.

Finally, we verify application recovery, optionally test failback, and remove all temporary AWS resources.

**Troubleshooting workflow:**

Infrastructure Setup → Primary and Secondary Applications → Incorrect Health Check → DNS Failover Configuration → Primary Application Failure → Failover Not Triggered → Root Cause Analysis → Health Check Correction → Secondary Failover → Verification → Cleanup

---

## 1. Lab Information

| Item | Configuration |
|---|---|
| Incident ID | INC-R53-008 |
| Difficulty | Intermediate–Advanced |
| AWS Region | `us-east-1` |
| AWS Services | Route 53, EC2, VPC, IAM, Systems Manager |
| Local Environment | WSL Ubuntu |
| EC2 Operating System | Amazon Linux 2023 |
| EC2 Instance Type | `t3.micro` |
| Number of EC2 Instances | 2 |
| VPC CIDR | `10.60.0.0/16` |
| Public Subnet | `10.60.1.0/24` |
| Hosted Zone | `lab08.route53.test` |
| Hosted Zone Type | Public |
| Application Hostname | `app.lab08.route53.test` |
| Primary Record | Failover A — PRIMARY |
| Secondary Record | Failover A — SECONDARY |
| Application Port | TCP 8080 |
| Health Endpoint | `/health` |
| Health Check Protocol | HTTP |
| Health Check Interval | 30 seconds |
| Failure Threshold | 3 |
| DNS TTL | 30 seconds |
| Incorrect Health Check Target | Secondary EC2 public IP |
| Correct Health Check Target | Primary EC2 public IP |
| Fault Injection | Stop primary HTTP application |
| Expected Failure | DNS continues returning primary IP |
| Remediation | Correct primary health check IP |
| Expected Recovery | DNS returns secondary IP |
| Verification | AWS CLI, `dig`, `curl`, Systems Manager |

---

## 2. Production Incident Scenario

### Incident Description

A company operates an application across two endpoints to improve availability.

The primary application runs on one EC2 instance, while a secondary EC2 instance acts as a backup.

Employees access the application through:

`app.lab08.route53.test`

The company configures Route 53 DNS failover routing.

Under normal conditions, clients should receive the primary server's IP address.

If the primary application becomes unhealthy, Route 53 should return the secondary server's IP address.

However, an engineer accidentally configures the primary record's health check to monitor the secondary server.

Both applications initially work, so the error is not immediately obvious.

Later, the primary application goes down.

Route 53 continues reporting the associated health check as healthy because the check is actually monitoring the secondary application.

Consequently, DNS continues returning the primary IP address even though the primary application is unavailable.

The Cloud Engineer must find the misconfigured health check and restore proper DNS failover.

### Incident Symptoms

- Primary EC2 instance is running.
- Primary application is stopped.
- Secondary application is healthy.
- Primary HTTP requests fail.
- Secondary HTTP requests succeed.
- Route 53 primary health check reports healthy.
- The health check monitors the secondary IP.
- Route 53 continues returning the primary IP.
- DNS failover does not occur.
- Correcting the health check restores failover.

### Business Impact

- Users continue reaching a failed application endpoint.
- Backup infrastructure is available but not selected.
- Application downtime continues despite a failover configuration.
- DNS-based disaster recovery becomes unreliable.
- Monitoring provides incorrect information.
- Engineers may investigate the wrong infrastructure component.

### Objective

Identify why Route 53 does not switch to the healthy secondary endpoint when the primary application fails, and restore proper failover by correcting the health check configuration.

---

## 3. AWS Architecture

### Infrastructure Architecture

```text
                         AWS Region
                          us-east-1
                              |
                              v
                         Amazon VPC
                       10.60.0.0/16
                              |
                              v
                         Public Subnet
                        10.60.1.0/24
                              |
                 --------------------------
                 |                        |
                 v                        v
            Primary EC2              Secondary EC2
           Amazon Linux              Amazon Linux
                 |                        |
                 v                        v
          Python HTTP Server       Python HTTP Server
              Port 8080                Port 8080
                 |                        |
                 v                        v
           PRIMARY_IP                SECONDARY_IP
                 |                        |
                 --------------------------
                              |
                              v
                       Amazon Route 53
                    Public Hosted Zone
                    lab08.route53.test
                              |
                              v
                       DNS Failover
                              |
                 --------------------------
                 |                        |
                 v                        v
              PRIMARY                 SECONDARY
              A Record                A Record
                 |                        |
                 v                        v
            PRIMARY_IP               SECONDARY_IP
                 |
                 v
             Health Check
```

### Incorrect Health Check Architecture

```text
Primary Application
       |
       v
Application Stopped
       |
       v
Primary Endpoint Unavailable


Primary DNS Record
       |
       v
Associated Health Check
       |
       v
Secondary EC2 Public IP
       |
       v
Secondary Application Healthy
       |
       v
Health Check Reports Healthy
       |
       v
Route 53 Continues Returning PRIMARY_IP
       |
       v
DNS Failover Does Not Occur
```

### Correct Architecture After Remediation

```text
Primary Application Stopped
          |
          v
Health Check Monitors PRIMARY_IP
          |
          v
Health Check Detects Failure
          |
          v
Primary Record Marked Unhealthy
          |
          v
Route 53 Failover Routing
          |
          v
Secondary A Record Selected
          |
          v
SECONDARY_IP
          |
          v
Secondary Application Responds HTTP 200
```

### Network Configuration

| Resource | Configuration |
|---|---|
| VPC | `10.60.0.0/16` |
| Public Subnet | `10.60.1.0/24` |
| Internet Gateway | Attached |
| Default Route | `0.0.0.0/0` |
| Primary EC2 | Public IPv4 |
| Secondary EC2 | Public IPv4 |
| Web Application | TCP 8080 |
| EC2 Management | Systems Manager |
| Route 53 Health Check | HTTP |
| Health Checker Access | AWS-managed prefix list |
| Local Testing | Client public IP `/32` |

### Important DNS Limitation

The hosted zone uses the reserved `.test` domain.

This domain is not publicly delegated through the normal DNS hierarchy.

Therefore, this lab queries the Route 53 public hosted zone's assigned authoritative nameserver directly.

Example:

```bash
dig @YOUR_ROUTE53_NAMESERVER app.lab08.route53.test A
```

This demonstrates the authoritative Route 53 failover decision without purchasing a domain.

---

## 4. Understanding Route 53 DNS Failover

### What Is DNS Failover?

DNS failover is a Route 53 routing policy that selects an alternative DNS record when a primary endpoint is considered unhealthy.

### Primary and Secondary Records

Route 53 failover routing uses two records for a given record name and type.

| Record | Purpose |
|---|---|
| PRIMARY | Preferred endpoint when healthy |
| SECONDARY | Backup endpoint when primary is unhealthy |

### Normal Operation

```text
Primary Healthy
       |
       v
Route 53
       |
       v
Return PRIMARY_IP
```

### Failover Operation

```text
Primary Unhealthy
       |
       v
Route 53
       |
       v
Return SECONDARY_IP
```

### What Is a Health Check?

A Route 53 health check monitors an endpoint or supported health signal.

The results help Route 53 decide which DNS records are eligible for routing.

### What Is SetIdentifier?

`SetIdentifier` uniquely identifies records that share the same name and type under a routing policy.

Example:

```text
SetIdentifier: primary
SetIdentifier: secondary
```

### What Is the Failover Attribute?

The `Failover` field identifies a record's role.

Valid values for this lab:

```text
PRIMARY
SECONDARY
```

### What Is DNS TTL?

TTL stands for Time to Live.

It controls how long recursive DNS resolvers may cache a DNS response.

This lab uses:

```text
TTL = 30 seconds
```

A shorter TTL can reduce how long cached answers remain after DNS changes, but it does not make failover instantaneous.

### Can a Secondary Record Have No Health Check?

Yes.

In this lab, the secondary record has no associated health check and is treated as available for failover.

In production, monitoring both primary and secondary endpoints can provide better health awareness.

### Important DNS Behavior

DNS failover does not terminate existing TCP connections or automatically move active application sessions.

It changes DNS responses for clients that perform new lookups.

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
- Linux `dig`
- Linux `curl`
- Git and GitHub

### Security Rules

- Use disposable AWS resources.
- Do not modify production DNS records.
- Restrict HTTP access to intended sources.
- Do not open SSH to the internet.
- Use Systems Manager for EC2 administration.
- Verify health check target IP addresses.
- Do not commit AWS credentials.
- Review evidence files before publishing.
- Delete all temporary infrastructure after testing.

### Cost Considerations

This lab creates:

- Two EC2 instances
- Two public IPv4 addresses
- Two EBS root volumes
- One Route 53 public hosted zone
- One Route 53 health check

AWS charges may apply while these resources exist.

---

## 6. Prepare WSL Ubuntu

### Step 1 — Verify AWS CLI

```bash
aws --version
aws sts get-caller-identity
```

### Step 2 — Install Linux Utilities

```bash
sudo apt update
sudo apt install -y dnsutils curl
```

Verify:

```bash
dig -v
curl --version
```

### Step 3 — Configure Variables

```bash
export AWS_REGION="us-east-1"
export AWS_PAGER=""

export PROJECT_TAG="Route53-Troubleshooting-Lab08"

export VPC_CIDR="10.60.0.0/16"
export SUBNET_CIDR="10.60.1.0/24"

export ZONE_NAME="lab08.route53.test"
export RECORD_NAME="app.lab08.route53.test"

export EC2_ROLE_NAME="route53-lab08-ssm-role"
export PROFILE_NAME="route53-lab08-ssm-profile"

export SG_NAME="route53-lab08-web-sg"
export APP_PORT=8080
```

### Step 4 — Verify Variables

```bash
echo "$AWS_REGION"
echo "$ZONE_NAME"
echo "$RECORD_NAME"
echo "$APP_PORT"
```

Keep the WSL terminal open throughout the lab to preserve resource IDs.

---

## 7. Create VPC and Networking

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications \
  "ResourceType=vpc,Tags=[{Key=Name,Value=route53-lab08-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
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

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

Choose a supported zone:

```bash
export AZ="us-east-1a"
```

### Step 4 — Create Public Subnet

```bash
export SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_CIDR" \
  --availability-zone "$AZ" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=route53-lab08-public},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
  "ResourceType=internet-gateway,Tags=[{Key=Name,Value=route53-lab08-igw},{Key=Project,Value=$PROJECT_TAG}]" \
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
  "ResourceType=route-table,Tags=[{Key=Name,Value=route53-lab08-rt},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 7 — Add Internet Route

```bash
aws ec2 create-route \
  --route-table-id "$ROUTE_TABLE_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Associate Subnet

```bash
export ROUTE_ASSOC_ID=$(aws ec2 associate-route-table \
  --route-table-id "$ROUTE_TABLE_ID" \
  --subnet-id "$SUBNET_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

---

## 8. Create Route 53 Public Hosted Zone

### Step 1 — Create Hosted Zone

```bash
export CALLER_REF="route53-lab08-$(date +%s)"

export HOSTED_ZONE_ID=$(aws route53 create-hosted-zone \
  --name "$ZONE_NAME" \
  --caller-reference "$CALLER_REF" \
  --hosted-zone-config \
    "Comment=Route53 Lab08 DNS failover,PrivateZone=false" \
  --query 'HostedZone.Id' \
  --output text)

echo "$HOSTED_ZONE_ID"
```

### Step 2 — Retrieve Authoritative Nameserver

```bash
export PUBLIC_NS=$(aws route53 get-hosted-zone \
  --id "$HOSTED_ZONE_ID" \
  --query 'DelegationSet.NameServers[0]' \
  --output text)

echo "$PUBLIC_NS"
```

### Step 3 — Verify Authoritative DNS

```bash
dig @"$PUBLIC_NS" "$ZONE_NAME" SOA +norecurse
```

Expected: an authoritative DNS response.

### Step 4 — Verify Hosted Zone

```bash
aws route53 get-hosted-zone \
  --id "$HOSTED_ZONE_ID" \
  --query '{Name:HostedZone.Name,Private:HostedZone.Config.PrivateZone}' \
  --output json
```

Expected: `Private=false`.

---

## 9. Create Security Group

### Step 1 — Retrieve Route 53 Health Checker Prefix List

```bash
export PREFIX_LIST_NAME="com.amazonaws.${AWS_REGION}.route53-healthchecks"

export PREFIX_LIST_ID=$(aws ec2 describe-managed-prefix-lists \
  --filters "Name=prefix-list-name,Values=$PREFIX_LIST_NAME" \
  --query 'PrefixLists[0].PrefixListId' \
  --output text \
  --region "$AWS_REGION")

echo "$PREFIX_LIST_ID"
```

Verify the returned value is a valid prefix list ID.

### Step 2 — Create Security Group

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "Route53 Lab08 web and health checker access" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Allow Route 53 Health Checkers

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --ip-permissions \
    "IpProtocol=tcp,FromPort=8080,ToPort=8080,PrefixListIds=[{PrefixListId=$PREFIX_LIST_ID}]" \
  --region "$AWS_REGION"
```

### Step 4 — Retrieve Local Public IP

```bash
export MY_PUBLIC_IP=$(curl -4fsS https://checkip.amazonaws.com | tr -d '\r\n')

echo "$MY_PUBLIC_IP"
```

### Step 5 — Allow Local HTTP Testing

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 8080 \
  --cidr "${MY_PUBLIC_IP}/32" \
  --region "$AWS_REGION"
```

### Security Group Summary

| Source | Port | Purpose |
|---|---|---|
| Route 53 health checker prefix list | TCP 8080 | Health monitoring |
| Current public IP `/32` | TCP 8080 | Local HTTP testing |
| Public internet `0.0.0.0/0` | Not configured | Avoid unnecessary exposure |
| SSH | Not configured | Systems Manager used instead |

---

## 10. Deploy Primary and Secondary EC2 Applications

### Step 1 — Create IAM Trust Policy

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

### Step 2 — Create IAM Role

```bash
aws iam create-role \
  --role-name "$EC2_ROLE_NAME" \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam attach-role-policy \
  --role-name "$EC2_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

### Step 3 — Create Instance Profile

```bash
aws iam create-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam add-role-to-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$EC2_ROLE_NAME"
```

Allow IAM propagation before launching the instances.

### Step 4 — Create Application User Data Template

Save as `user-data-template.sh`:

```bash
#!/bin/bash
set -euxo pipefail

dnf install -y python3 curl

mkdir -p /opt/route53-lab08

cat > /opt/route53-lab08/index.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Route 53 Lab 08</title>
</head>
<body>
    <h1>Route 53 DNS Failover Lab</h1>
    <p>Server: SERVER_ROLE</p>
    <p>Status: HEALTHY</p>
</body>
</html>
HTML

echo "healthy" > /opt/route53-lab08/health

cat > /etc/systemd/system/route53-lab08.service <<'SERVICE'
[Unit]
Description=Route 53 Lab08 Web Application
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0 --directory /opt/route53-lab08
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now route53-lab08.service
```

### Step 5 — Generate Primary and Secondary Scripts

```bash
sed 's/SERVER_ROLE/PRIMARY/g' \
  user-data-template.sh > user-data-primary.sh

sed 's/SERVER_ROLE/SECONDARY/g' \
  user-data-template.sh > user-data-secondary.sh
```

### Step 6 — Retrieve Amazon Linux AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 7 — Launch Primary EC2

```bash
export PRIMARY_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --associate-public-ip-address \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --user-data file://user-data-primary.sh \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --tag-specifications \
  "ResourceType=instance,Tags=[{Key=Name,Value=route53-lab08-primary},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")

echo "$PRIMARY_INSTANCE_ID"
```

### Step 8 — Launch Secondary EC2

```bash
export SECONDARY_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --associate-public-ip-address \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --user-data file://user-data-secondary.sh \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --tag-specifications \
  "ResourceType=instance,Tags=[{Key=Name,Value=route53-lab08-secondary},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")

echo "$SECONDARY_INSTANCE_ID"
```

### Step 9 — Wait for Instances

```bash
aws ec2 wait instance-running \
  --instance-ids "$PRIMARY_INSTANCE_ID" "$SECONDARY_INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$PRIMARY_INSTANCE_ID" "$SECONDARY_INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 10 — Retrieve Public IP Addresses

```bash
export PRIMARY_IP=$(aws ec2 describe-instances \
  --instance-ids "$PRIMARY_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region "$AWS_REGION")

export SECONDARY_IP=$(aws ec2 describe-instances \
  --instance-ids "$SECONDARY_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region "$AWS_REGION")
```

Verify:

```bash
echo "Primary IP: $PRIMARY_IP"
echo "Secondary IP: $SECONDARY_IP"
```

Both values should be actual public IPv4 addresses.

---

## 11. Verify Primary and Secondary Applications

### Step 1 — Test Primary

```bash
curl -i \
  --connect-timeout 5 \
  --max-time 10 \
  "http://$PRIMARY_IP:8080/"
```

Expected:

```text
HTTP/1.0 200 OK
```

Response body:

```text
Server: PRIMARY
Status: HEALTHY
```

### Step 2 — Test Secondary

```bash
curl -i \
  --connect-timeout 5 \
  --max-time 10 \
  "http://$SECONDARY_IP:8080/"
```

Expected:

```text
HTTP/1.0 200 OK
```

Response body:

```text
Server: SECONDARY
Status: HEALTHY
```

### Step 3 — Test Primary Health Endpoint

```bash
curl --max-time 10 \
  "http://$PRIMARY_IP:8080/health"
```

Expected:

```text
healthy
```

### Step 4 — Test Secondary Health Endpoint

```bash
curl --max-time 10 \
  "http://$SECONDARY_IP:8080/health"
```

Expected:

```text
healthy
```

### Step 5 — Troubleshoot Application If Necessary

Connect through Systems Manager:

```bash
aws ssm start-session \
  --target "$PRIMARY_INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
sudo systemctl status route53-lab08 --no-pager

sudo journalctl \
  -u route53-lab08 \
  -n 30 \
  --no-pager

sudo tail -n 50 /var/log/cloud-init-output.log
```

Exit:

```bash
exit
```

### Initial Verification Matrix

| Test | Expected Result |
|---|---|
| Primary EC2 | Running |
| Secondary EC2 | Running |
| Primary HTTP | 200 |
| Secondary HTTP | 200 |
| Primary `/health` | Healthy |
| Secondary `/health` | Healthy |

Both applications should be functioning before fault injection.

---

## 12. Fault Injection — Incorrect Primary Health Check

### Step 1 — Create Incorrect Health Check Configuration

Generate `wrong-primary-health-check.json`:

```bash
cat > wrong-primary-health-check.json <<EOF
{
  "IPAddress": "$SECONDARY_IP",
  "Port": 8080,
  "Type": "HTTP",
  "ResourcePath": "/health",
  "RequestInterval": 30,
  "FailureThreshold": 3
}
EOF
```

This is intentionally incorrect.

The health check associated with the primary DNS record should monitor the primary application, but it is configured to monitor the secondary.

### Step 2 — Create Route 53 Health Check

```bash
export HEALTH_CHECK_ID=$(aws route53 create-health-check \
  --caller-reference "route53-lab08-hc-$(date +%s)" \
  --health-check-config file://wrong-primary-health-check.json \
  --query 'HealthCheck.Id' \
  --output text)

echo "$HEALTH_CHECK_ID"
```

### Step 3 — Tag Health Check

```bash
aws route53 change-tags-for-resource \
  --resource-type healthcheck \
  --resource-id "$HEALTH_CHECK_ID" \
  --add-tags \
    "Key=Name,Value=route53-lab08-primary-health" \
    "Key=Project,Value=$PROJECT_TAG"
```

### Step 4 — Verify Health Check

```bash
aws route53 get-health-check \
  --health-check-id "$HEALTH_CHECK_ID" \
  --query 'HealthCheck.HealthCheckConfig.{IP:IPAddress,Port:Port,Path:ResourcePath}' \
  --output table
```

Expected:

```text
IP: SECONDARY_IP
Port: 8080
Path: /health
```

### Step 5 — Inspect Health Checker Observations

```bash
aws route53 get-health-check-status \
  --health-check-id "$HEALTH_CHECK_ID" \
  --query 'HealthCheckObservations[].{Region:Region,Status:StatusReport.Status}' \
  --output table
```

Expected after monitoring begins: healthy observations because the secondary application is working.

### Fault Injection Summary

| Component | Configuration |
|---|---|
| Primary Server | Healthy initially |
| Secondary Server | Healthy |
| Health Check Association | Primary DNS record |
| Actual Monitored Endpoint | Secondary IP |
| Health Check Result | Healthy initially |
| Misconfiguration | Primary health check monitors wrong server |

---

## 13. Configure DNS Failover Records

### Step 1 — Create Failover Record Configuration

Generate `failover-records.json`:

```bash
cat > failover-records.json <<EOF
{
  "Comment": "Lab08 - Create primary and secondary DNS failover records",
  "Changes": [
    {
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "$RECORD_NAME",
        "Type": "A",
        "SetIdentifier": "primary",
        "Failover": "PRIMARY",
        "TTL": 30,
        "ResourceRecords": [
          {"Value": "$PRIMARY_IP"}
        ],
        "HealthCheckId": "$HEALTH_CHECK_ID"
      }
    },
    {
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "$RECORD_NAME",
        "Type": "A",
        "SetIdentifier": "secondary",
        "Failover": "SECONDARY",
        "TTL": 30,
        "ResourceRecords": [
          {"Value": "$SECONDARY_IP"}
        ]
      }
    }
  ]
}
EOF
```

### Step 2 — Apply Failover Records

```bash
export RECORD_CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch file://failover-records.json \
  --query 'ChangeInfo.Id' \
  --output text)

aws route53 wait resource-record-sets-changed \
  --id "$RECORD_CHANGE_ID"
```

### Step 3 — Verify Both Records

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}.']" \
  --output json
```

Expected: two records with the same hostname and type but different `SetIdentifier` and `Failover` values.

### Step 4 — Query Route 53 Authoritative DNS

```bash
dig @"$PUBLIC_NS" "$RECORD_NAME" A +norecurse
```

Expected while primary health is considered healthy:

```text
status: NOERROR
```

Answer contains:

```text
PRIMARY_IP
```

### Step 5 — Verify Selected IP

```bash
dig +short @"$PUBLIC_NS" "$RECORD_NAME" A
```

Expected: actual primary public IP.

### DNS Failover Record Comparison

| Field | Primary Record | Secondary Record |
|---|---|---|
| Name | Same hostname | Same hostname |
| Type | A | A |
| SetIdentifier | primary | secondary |
| Failover | PRIMARY | SECONDARY |
| IP | PRIMARY_IP | SECONDARY_IP |
| TTL | 30 | 30 |
| HealthCheckId | Assigned | Not assigned |

---

## 14. Reproduce DNS Failover Failure

### Step 1 — Connect to Primary EC2

```bash
aws ssm start-session \
  --target "$PRIMARY_INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 2 — Stop Primary Application

Inside primary EC2:

```bash
sudo systemctl stop route53-lab08
```

### Step 3 — Verify Application Stopped

```bash
sudo systemctl is-active route53-lab08
```

Expected:

```text
inactive
```

### Step 4 — Test Local HTTP Failure

```bash
curl \
  --connect-timeout 3 \
  --max-time 5 \
  http://127.0.0.1:8080/health
```

Expected: connection failure.

Exit:

```bash
exit
```

### Step 5 — Verify Primary Failure from WSL

```bash
curl -i \
  --connect-timeout 3 \
  --max-time 6 \
  "http://$PRIMARY_IP:8080/"
```

Expected: connection failure or timeout.

### Step 6 — Verify Secondary Is Healthy

```bash
curl -i \
  --connect-timeout 5 \
  --max-time 10 \
  "http://$SECONDARY_IP:8080/"
```

Expected:

```text
HTTP/1.0 200 OK
```

Response body contains:

```text
Server: SECONDARY
```

### Step 7 — Inspect Health Check Status

```bash
aws route53 get-health-check-status \
  --health-check-id "$HEALTH_CHECK_ID" \
  --query 'HealthCheckObservations[].{Region:Region,Status:StatusReport.Status}' \
  --output table
```

Expected: healthy observations because the check still monitors the working secondary application.

### Step 8 — Query DNS

```bash
dig @"$PUBLIC_NS" "$RECORD_NAME" A +norecurse
```

Expected:

```text
PRIMARY_IP
```

Route 53 continues selecting the failed primary record.

### Step 9 — Retrieve DNS-Selected IP

```bash
export DNS_RESULT=$(dig +short @"$PUBLIC_NS" "$RECORD_NAME" A | head -n 1)

echo "DNS Result:   $DNS_RESULT"
echo "Primary IP:   $PRIMARY_IP"
echo "Secondary IP: $SECONDARY_IP"
```

Expected: `DNS_RESULT` matches `PRIMARY_IP`.

### Step 10 — Simulate Client Request

```bash
curl -i \
  --connect-timeout 3 \
  --max-time 6 \
  --resolve "${RECORD_NAME}:8080:${DNS_RESULT}" \
  "http://${RECORD_NAME}:8080/"
```

Expected: connection failure.

The `--resolve` option uses the IP obtained from the previous DNS query while preserving the application hostname.

### Expected Failure Matrix

| Investigation | Expected Result |
|---|---|
| Primary EC2 | Running |
| Primary Application | Stopped |
| Secondary Application | Healthy |
| Primary Health Check | Incorrectly healthy |
| Monitored IP | Secondary |
| Route 53 DNS Answer | Primary IP |
| HTTP Through DNS-Selected IP | Failed |
| Failover | Not triggered |

---

## 15. Troubleshooting Investigation

### Check 1 — Inspect DNS Failover Records

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}.']" \
  --output json
```

### Check 2 — Inspect Primary Health Check Association

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Failover=='PRIMARY'].{Name:Name,Type:Type,HealthCheck:HealthCheckId,Value:ResourceRecords}" \
  --output json
```

### Check 3 — Inspect Health Check Configuration

```bash
aws route53 get-health-check \
  --health-check-id "$HEALTH_CHECK_ID" \
  --output json
```

Expected finding: health check IP matches the secondary IP.

### Check 4 — Compare IP Addresses

```bash
echo "Primary IP:      $PRIMARY_IP"
echo "Secondary IP:    $SECONDARY_IP"

aws route53 get-health-check \
  --health-check-id "$HEALTH_CHECK_ID" \
  --query 'HealthCheck.HealthCheckConfig.IPAddress' \
  --output text
```

The configured health check target should be the primary IP but is actually the secondary IP.

### Check 5 — Inspect Health Check Observations

```bash
aws route53 get-health-check-status \
  --health-check-id "$HEALTH_CHECK_ID" \
  --output json
```

### Check 6 — Inspect Last Failure Reason

```bash
aws route53 get-health-check-last-failure-reason \
  --health-check-id "$HEALTH_CHECK_ID" \
  --output json
```

There may be no recent connection failure because the incorrectly monitored secondary endpoint remains healthy.

### Check 7 — Save Investigation Evidence

```bash
dig @"$PUBLIC_NS" "$RECORD_NAME" A +norecurse \
  > lab08-before-dns.txt

aws route53 get-health-check \
  --health-check-id "$HEALTH_CHECK_ID" \
  --output json \
  > lab08-before-health-config.json

aws route53 get-health-check-status \
  --health-check-id "$HEALTH_CHECK_ID" \
  --output json \
  > lab08-before-health-status.json
```

Save the failed application request:

```bash
curl -i \
  --connect-timeout 3 \
  --max-time 6 \
  --resolve "${RECORD_NAME}:8080:${DNS_RESULT}" \
  "http://${RECORD_NAME}:8080/" \
  > lab08-before-http.txt 2>&1 || true
```

### Investigation Matrix

| Investigation | Expected Finding |
|---|---|
| Primary DNS Record | Correct primary IP |
| Secondary DNS Record | Correct secondary IP |
| Failover Policy | Configured |
| HealthCheckId | Associated with primary |
| Health Check Target | Wrong endpoint |
| Health Check Status | Healthy |
| Primary Application | Down |
| Secondary Application | Healthy |
| Root Cause | Primary health check monitors secondary |

---

## 16. Root Cause Analysis

### Root Cause

The Route 53 health check associated with the primary DNS failover record was configured to monitor the secondary EC2 instance instead of the primary.

When the primary application stopped, the health check continued receiving successful HTTP responses from the secondary application.

Route 53 therefore considered the primary record healthy and continued selecting it.

This prevented the DNS failover mechanism from switching to the secondary endpoint.

The DNS record values themselves were correct. The problem was the relationship between the primary record and its health check.

### Root Cause Flow

```text
Primary Application Stops
          |
          v
Primary Server Unavailable
          |
          v
Primary DNS Record
          |
          v
Attached Health Check
          |
          v
Monitors Secondary Server
          |
          v
Secondary Returns HTTP 200
          |
          v
Health Check Reports Healthy
          |
          v
Route 53 Returns Primary IP
          |
          v
DNS Failover Fails
```

### Five Whys

1. **Why did DNS continue returning the primary IP?** Route 53 considered the primary record healthy.
2. **Why was the primary considered healthy?** Its associated health check reported successful responses.
3. **Why did the health check succeed after the primary failed?** It was monitoring the secondary server.
4. **Why didn't failover activate?** Route 53 did not receive an unhealthy status for the primary record.
5. **How was the problem resolved?** The health check was updated to monitor the actual primary server.

### Root Cause Summary

| Component | Finding |
|---|---|
| AWS Service | Route 53 |
| Incident | DNS Failover Not Working |
| Primary Application | Down |
| Secondary Application | Healthy |
| Primary Health Check | Incorrectly healthy |
| Health Check Destination | Secondary IP |
| Route 53 Selection | Primary IP |
| Root Cause | Wrong health check target |
| Remediation | Update health check IP |
| Infrastructure Replacement | Not required |

---

## 17. Remediation and Final Verification

### Step 1 — Correct Health Check Target

From WSL:

```bash
aws route53 update-health-check \
  --health-check-id "$HEALTH_CHECK_ID" \
  --ip-address "$PRIMARY_IP"
```

### Step 2 — Verify Corrected Configuration

```bash
aws route53 get-health-check \
  --health-check-id "$HEALTH_CHECK_ID" \
  --query 'HealthCheck.HealthCheckConfig.{IP:IPAddress,Port:Port,Type:Type,Path:ResourcePath}' \
  --output table
```

Expected:

```text
IP: PRIMARY_IP
Port: 8080
Type: HTTP
Path: /health
```

### Step 3 — Verify Primary Health Check Becomes Unhealthy

```bash
aws route53 get-health-check-status \
  --health-check-id "$HEALTH_CHECK_ID" \
  --query 'HealthCheckObservations[].{Region:Region,Status:StatusReport.Status}' \
  --output table
```

Expected after health checker observations update: unhealthy responses.

### Step 4 — Inspect Failure Reason

```bash
aws route53 get-health-check-last-failure-reason \
  --health-check-id "$HEALTH_CHECK_ID" \
  --output json
```

Expected: connection-related failures because the primary application remains stopped.

### Step 5 — Verify DNS Failover

```bash
dig @"$PUBLIC_NS" "$RECORD_NAME" A +norecurse
```

Expected: secondary IP.

### Step 6 — Retrieve New DNS Answer

```bash
export DNS_RESULT=$(dig +short @"$PUBLIC_NS" "$RECORD_NAME" A | head -n 1)

echo "DNS Result:   $DNS_RESULT"
echo "Secondary IP: $SECONDARY_IP"
```

Expected:

```text
DNS Result = Secondary IP
```

### Step 7 — Verify Backup Application

```bash
curl -i \
  --connect-timeout 5 \
  --max-time 10 \
  --resolve "${RECORD_NAME}:8080:${DNS_RESULT}" \
  "http://${RECORD_NAME}:8080/"
```

Expected:

```text
HTTP/1.0 200 OK
```

Response body:

```text
Server: SECONDARY
Status: HEALTHY
```

### Step 8 — Save Recovery Evidence

```bash
dig @"$PUBLIC_NS" "$RECORD_NAME" A +norecurse \
  > lab08-after-dns.txt

aws route53 get-health-check \
  --health-check-id "$HEALTH_CHECK_ID" \
  --output json \
  > lab08-after-health-config.json

aws route53 get-health-check-status \
  --health-check-id "$HEALTH_CHECK_ID" \
  --output json \
  > lab08-after-health-status.json
```

```bash
curl -i \
  --connect-timeout 5 \
  --max-time 10 \
  --resolve "${RECORD_NAME}:8080:${DNS_RESULT}" \
  "http://${RECORD_NAME}:8080/" \
  > lab08-after-http.txt 2>&1
```

### Before and After Comparison

| Check | Before Fix | After Fix |
|---|---|---|
| Primary Application | Down | Down |
| Secondary Application | Healthy | Healthy |
| Health Check Target | Secondary IP | Primary IP |
| Primary Health Check | Healthy, incorrectly | Unhealthy, correctly |
| DNS Answer | Primary IP | Secondary IP |
| Client HTTP | Failed | 200 |
| Failover | Not working | Working |
| Incident | Active | Resolved |

### Optional Failback Test

Restart the primary application through Systems Manager:

```bash
aws ssm start-session \
  --target "$PRIMARY_INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
sudo systemctl start route53-lab08

sudo systemctl is-active route53-lab08

curl -i http://127.0.0.1:8080/health
```

Exit:

```bash
exit
```

Verify health check recovery:

```bash
aws route53 get-health-check-status \
  --health-check-id "$HEALTH_CHECK_ID" \
  --query 'HealthCheckObservations[].{Region:Region,Status:StatusReport.Status}' \
  --output table
```

Verify failback:

```bash
dig +short @"$PUBLIC_NS" "$RECORD_NAME" A
```

Expected after health recovery: primary IP.

---

## 18. AWS Resource Cleanup

**Warning:** Delete only resources created for Lab 08. Confirm resource ownership, IDs, and record values before deletion.

### Step 1 — Verify Current Failover Records

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}.']" \
  --output json
```

### Step 2 — Create DNS Deletion Batch

Generate `delete-failover-records.json`:

```bash
cat > delete-failover-records.json <<EOF
{
  "Comment": "Lab08 - Delete primary and secondary failover records",
  "Changes": [
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "$RECORD_NAME",
        "Type": "A",
        "SetIdentifier": "primary",
        "Failover": "PRIMARY",
        "TTL": 30,
        "ResourceRecords": [
          {"Value": "$PRIMARY_IP"}
        ],
        "HealthCheckId": "$HEALTH_CHECK_ID"
      }
    },
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "$RECORD_NAME",
        "Type": "A",
        "SetIdentifier": "secondary",
        "Failover": "SECONDARY",
        "TTL": 30,
        "ResourceRecords": [
          {"Value": "$SECONDARY_IP"}
        ]
      }
    }
  ]
}
EOF
```

The delete batch must match the current Route 53 record sets exactly.

### Step 3 — Delete Failover Records

```bash
export DELETE_CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch file://delete-failover-records.json \
  --query 'ChangeInfo.Id' \
  --output text)

aws route53 wait resource-record-sets-changed \
  --id "$DELETE_CHANGE_ID"
```

### Step 4 — Verify Health Check Ownership

```bash
aws route53 list-tags-for-resource \
  --resource-type healthcheck \
  --resource-id "$HEALTH_CHECK_ID"
```

Confirm that the health check belongs to Lab 08.

### Step 5 — Delete Health Check

```bash
aws route53 delete-health-check \
  --health-check-id "$HEALTH_CHECK_ID"
```

### Step 6 — Delete Hosted Zone

Verify only default NS and SOA records remain:

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --output table
```

Delete:

```bash
aws route53 delete-hosted-zone \
  --id "$HOSTED_ZONE_ID"
```

### Step 7 — Verify EC2 Root Volumes

```bash
aws ec2 describe-instances \
  --instance-ids "$PRIMARY_INSTANCE_ID" "$SECONDARY_INSTANCE_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,Volumes:BlockDeviceMappings}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm root volume `DeleteOnTermination=true` for both instances.

### Step 8 — Terminate Both EC2 Instances

```bash
aws ec2 terminate-instances \
  --instance-ids "$PRIMARY_INSTANCE_ID" "$SECONDARY_INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$PRIMARY_INSTANCE_ID" "$SECONDARY_INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 9 — Verify IAM Role Ownership

```bash
aws iam list-role-tags \
  --role-name "$EC2_ROLE_NAME"
```

Confirm the Lab 08 project tag.

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

Wait until the EC2 network interfaces are removed.

### Step 12 — Delete Security Group

```bash
aws ec2 delete-security-group \
  --group-id "$SG_ID" \
  --region "$AWS_REGION"
```

### Step 13 — Delete Route Table Association

```bash
aws ec2 disassociate-route-table \
  --association-id "$ROUTE_ASSOC_ID" \
  --region "$AWS_REGION"
```

### Step 14 — Delete Route Table

```bash
aws ec2 delete-route-table \
  --route-table-id "$ROUTE_TABLE_ID" \
  --region "$AWS_REGION"
```

### Step 15 — Delete Subnet

```bash
aws ec2 delete-subnet \
  --subnet-id "$SUBNET_ID" \
  --region "$AWS_REGION"
```

### Step 16 — Delete Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 17 — Delete VPC

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 18 — Verify Cleanup

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

Expected:

```json
[]
```

Also verify the health check is deleted, both EC2 instances are terminated, IAM resources are removed, and their EBS volumes have been deleted.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| Primary Failover Record | Deleted |
| Secondary Failover Record | Deleted |
| Route 53 Health Check | Deleted |
| Public Hosted Zone | Deleted |
| Primary EC2 | Terminated |
| Secondary EC2 | Terminated |
| EBS Root Volumes | Deleted |
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

### Q1. What is Amazon Route 53 DNS failover?

A routing policy that returns a secondary DNS endpoint when the primary endpoint is considered unhealthy.

### Q2. What is the difference between primary and secondary failover records?

The primary is the preferred endpoint when healthy. The secondary is used when the primary is unhealthy.

### Q3. Why did DNS failover fail in this lab?

The health check associated with the primary DNS record was monitoring the healthy secondary server instead of the primary.

### Q4. Can a health check show Healthy even if the primary application is down?

Yes. If the health check monitors the wrong endpoint, it may report healthy even when the intended primary application has failed.

### Q5. Does Route 53 automatically know when an EC2 application fails?

No. It relies on configured health checks or supported health-aware routing mechanisms.

### Q6. Can Route 53 fail over to a secondary record without a health check?

Yes. A secondary failover record without a health check is treated as available for failover.

### Q7. Why use a low DNS TTL for failover?

A lower TTL can reduce how long recursive resolvers cache DNS answers after routing changes.

### Q8. How do you inspect failover records?

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id YOUR_HOSTED_ZONE_ID
```

### Q9. How do you update a Route 53 health check IP address?

```bash
aws route53 update-health-check \
  --health-check-id YOUR_HEALTH_CHECK_ID \
  --ip-address PRIMARY_PUBLIC_IP
```

### Q10. Does DNS failover migrate existing client connections?

No. Existing connections are not automatically transferred. DNS changes influence future DNS resolutions.

### Q11. What is failback?

Failback occurs when the primary endpoint becomes healthy again and Route 53 resumes selecting it.

### Q12. How would you explain this lab in an interview?

I deployed primary and secondary EC2 applications and configured Route 53 DNS failover using PRIMARY and SECONDARY A records.

I intentionally misconfigured the primary record's health check to monitor the secondary server.

After stopping the primary application, I verified that Route 53 continued returning the primary IP because the associated health check still reported healthy.

I investigated the DNS failover configuration, health check association, monitored endpoint, and HTTP responses.

I corrected the health check to monitor the actual primary server.

Route 53 then detected the primary failure and returned the secondary IP.

I verified successful HTTP requests through the backup endpoint and tested failback after restoring the primary.

Finally, I deleted the temporary AWS resources.

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
├── 05-public-vs-private-hosted-zone/
│   └── README.md
│
├── 06-incorrect-alias-record/
│   └── README.md
│
├── 07-route53-health-check-failure/
│   └── README.md
│
└── 08-dns-failover-not-working/
    ├── README.md
    ├── ec2-trust-policy.json
    ├── user-data-template.sh
    ├── user-data-primary.sh
    ├── user-data-secondary.sh
    ├── wrong-primary-health-check.json
    ├── failover-records.json
    ├── delete-failover-records.json
    ├── lab08-before-dns.txt
    ├── lab08-before-health-config.json
    ├── lab08-before-health-status.json
    ├── lab08-before-http.txt
    ├── lab08-after-dns.txt
    ├── lab08-after-health-config.json
    ├── lab08-after-health-status.json
    └── lab08-after-http.txt
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete incident documentation |
| `ec2-trust-policy.json` | IAM trust policy |
| `user-data-template.sh` | Shared EC2 application deployment |
| `user-data-primary.sh` | Deploys primary application |
| `user-data-secondary.sh` | Deploys secondary application |
| `wrong-primary-health-check.json` | Creates the misconfigured health check |
| `failover-records.json` | Creates PRIMARY and SECONDARY DNS records |
| `delete-failover-records.json` | Removes failover records |
| `lab08-before-dns.txt` | Captures failed DNS routing decision |
| `lab08-before-health-config.json` | Captures incorrect monitoring configuration |
| `lab08-before-health-status.json` | Records health checker observations |
| `lab08-before-http.txt` | Captures failed application request |
| `lab08-after-dns.txt` | Captures corrected DNS failover |
| `lab08-after-health-config.json` | Captures corrected health check target |
| `lab08-after-health-status.json` | Captures unhealthy primary observations |
| `lab08-after-http.txt` | Captures successful backup response |

The evidence files contain actual results from the AWS environment and must be generated during the practical exercise.

Review and sanitize all evidence before publishing it to GitHub.

---

## 21. Lessons Learned and Skills Demonstrated

### Lessons Learned

This lab demonstrates how a misconfigured Route 53 health check can prevent DNS failover even when the backup application is available.

We deployed two EC2 web applications and configured PRIMARY and SECONDARY failover DNS records.

The primary record had an associated health check, but the check was intentionally configured to monitor the secondary server.

After stopping the primary application, we observed that Route 53 continued selecting the primary IP because its health check still reported healthy.

We investigated the problem using AWS CLI, DNS queries, health checker observations, and HTTP tests.

We confirmed that the primary application had failed while the secondary application remained healthy.

We identified the health check's incorrect IP address as the root cause.

After correcting the health check to monitor the primary server, Route 53 detected the failure and selected the secondary endpoint.

We verified successful HTTP connectivity through the backup server and optionally tested automatic failback when the primary application recovered.

**Key Lesson:** A DNS failover configuration is only as reliable as the health checks controlling it. Engineers must verify that each health check monitors the intended endpoint rather than assuming a healthy status always represents the correct workload.

### Skills Demonstrated

- Amazon Route 53
- DNS failover routing
- PRIMARY and SECONDARY records
- Route 53 A records
- Route 53 health checks
- Health check associations
- Health checker observations
- DNS TTL
- AWS CLI v2
- Linux `dig`
- Linux `curl`
- EC2 application deployment
- Python HTTP server
- EC2 user data
- Systems Manager
- IAM roles
- AWS-managed prefix lists
- VPC networking
- Security groups
- Application availability troubleshooting
- Root cause analysis
- DNS failover remediation
- Failback verification
- AWS resource cleanup

### Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-R53-008 |
| Scenario | DNS Failover Not Working |
| DNS Routing Policy | Failover |
| Primary Application | Down during fault |
| Secondary Application | Healthy |
| Incorrect Health Check Target | Secondary IP |
| Health Check Before Fix | Healthy, incorrectly |
| DNS Before Fix | Primary IP |
| Root Cause | Wrong health check endpoint |
| Remediation | Update health check to primary IP |
| Health Check After Fix | Unhealthy while primary is down |
| DNS After Fix | Secondary IP |
| Backup HTTP Response | 200 |
| Failback | Primary selected after recovery |
| Cleanup | Temporary resources removed |
| Incident Status | Resolved after verification |

**Key Takeaway:** Successful DNS failover depends on accurate health check configuration, correct primary and secondary record associations, and healthy backup infrastructure. A health check can report success while monitoring the wrong server, leaving a failed primary endpoint selected.
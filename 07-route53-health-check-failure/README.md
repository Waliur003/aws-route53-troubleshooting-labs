# Lab 07 — Route 53 Health Check Failure

## Overview

This lab demonstrates how to troubleshoot an Amazon Route 53 HTTP health check that incorrectly reports a healthy EC2 application as unhealthy.

We deploy an AWS VPC, configure networking and security groups, and launch an Amazon Linux 2023 EC2 instance running a Python HTTP application.

The application listens on TCP port `8080` and provides a `/health` endpoint that returns HTTP `200 OK`.

We intentionally create a Route 53 HTTP health check configured to monitor port `8081` instead of the application's actual port.

Because no application is listening on port `8081`, the Route 53 health checkers cannot establish a successful HTTP connection and eventually report the endpoint as unhealthy.

We investigate the failure using AWS CLI, Route 53 health check observations, failure reasons, Linux networking utilities, systemd, and application logs.

After identifying the incorrect port, we update the health check using `aws route53 update-health-check` and verify that Route 53 begins reporting successful checks.

Finally, we delete the Route 53 health check and all temporary AWS infrastructure.

**Troubleshooting workflow:**

Infrastructure Setup → Healthy EC2 Application → Incorrect Health Check → Unhealthy Status → Investigation → Root Cause Analysis → Remediation → Healthy Status → Cleanup

---

## 1. Lab Information

| Item | Configuration |
|---|---|
| Incident ID | INC-R53-007 |
| Difficulty | Intermediate |
| AWS Region | `us-east-1` |
| AWS Services | Route 53, EC2, VPC, IAM, Systems Manager |
| Local Environment | WSL Ubuntu |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| VPC CIDR | `10.59.0.0/16` |
| Public Subnet | `10.59.1.0/24` |
| Application | Python HTTP Server |
| Application Port | TCP 8080 |
| Health Endpoint | `/health` |
| Incorrect Health Check Port | 8081 |
| Correct Health Check Port | 8080 |
| Health Check Protocol | HTTP |
| Health Check Interval | 30 seconds |
| Failure Threshold | 3 |
| Endpoint | EC2 Public IPv4 |
| Access Method | AWS Systems Manager |
| Security | AWS-managed Route 53 health checker prefix list |
| Fault Injection | Incorrect health check port |
| Expected Failure | Route 53 Unhealthy |
| Remediation | Update health check port |
| Expected Recovery | Route 53 Healthy |
| Verification | AWS CLI, `curl`, `ss`, `systemctl`, `journalctl` |

---

## 2. Production Incident Scenario

### Incident Description

A company hosts a web application on an Amazon EC2 instance.

The application runs on TCP port `8080` and provides a health monitoring endpoint:

`http://EC2_PUBLIC_IP:8080/health`

The health endpoint responds successfully with HTTP `200 OK`.

To monitor availability, the company creates an Amazon Route 53 HTTP health check.

However, the engineer mistakenly configures the health check to monitor port `8081`.

Although the application is running normally, Route 53 cannot establish a connection to the incorrect port.

As a result, the health check reports the endpoint as unhealthy.

The Cloud Engineer must investigate why the application appears unhealthy from Route 53, verify the actual application status, correct the monitoring configuration, and confirm recovery.

### Incident Symptoms

- EC2 instance is running.
- Application service is active.
- Application listens on port 8080.
- `/health` returns HTTP 200 on port 8080.
- Nothing listens on port 8081.
- Route 53 health check monitors port 8081.
- Route 53 health check reports Unhealthy.
- Health checker observations indicate connection failures.
- Updating the port to 8080 restores successful health checks.

### Business Impact

- Monitoring incorrectly reports a healthy application as unavailable.
- Operations teams may receive false availability alerts.
- Engineers may spend time troubleshooting functioning infrastructure.
- Health-check-based DNS routing could be affected if this check were associated with DNS records.
- Incorrect monitoring configurations can delay incident diagnosis.

### Objective

Identify and correct an incorrectly configured Route 53 health check while verifying that the underlying EC2 application is operating normally.

---

## 3. AWS Architecture

### Infrastructure Architecture

```text
                       AWS Region
                        us-east-1
                            |
                            v
                       Amazon VPC
                     10.59.0.0/16
                            |
                            v
                       Public Subnet
                      10.59.1.0/24
                            |
                            v
                      EC2 Instance
                   Amazon Linux 2023
                            |
                            v
                     Python HTTP Server
                         Port 8080
                            |
                            v
                     /health Endpoint
                            |
                            v
                         HTTP 200


                   Route 53 Health Checkers
                            |
                            v
                    EC2 Public IPv4
                            |
                            v
                    Health Check Port
                          8081
                            |
                            v
                   No Application Listening
                            |
                            v
                     Connection Failure
                            |
                            v
                    Route 53 Unhealthy
```

### Incorrect Health Check Architecture

```text
Route 53 Health Checker
          |
          v
     EC2 Public IP
          |
          v
       TCP 8081
          |
          v
   No Listening Service
          |
          v
     Check Failure
          |
          v
        Unhealthy
```

### Architecture After Remediation

```text
Route 53 Health Checker
          |
          v
     EC2 Public IP
          |
          v
       TCP 8080
          |
          v
    Python HTTP Server
          |
          v
        /health
          |
          v
       HTTP 200
          |
          v
        Healthy
```

### Network Configuration

| Component | Configuration |
|---|---|
| VPC | `10.59.0.0/16` |
| Public Subnet | `10.59.1.0/24` |
| Internet Gateway | Attached |
| Default Route | `0.0.0.0/0` |
| EC2 | Amazon Linux 2023 |
| EC2 Public IP | Assigned by AWS |
| Application Port | TCP 8080 |
| Incorrect Check Port | TCP 8081 |
| Health Checker Access | AWS-managed prefix list |
| EC2 Management | Systems Manager |
| Inbound SSH | Not allowed |

**Important:** Route 53 standard endpoint health checkers operate from public monitoring locations. They cannot directly monitor a private-only EC2 IP address using a standard HTTP endpoint health check.

This lab uses the EC2 instance's public IPv4 address and restricts inbound health check access to AWS-published health checker ranges.

A hosted zone is not required because this lab tests a standalone Route 53 health check rather than DNS routing.

---

## 4. Understanding Route 53 Health Checks

### What Is a Route 53 Health Check?

Amazon Route 53 health checks monitor the availability of an endpoint or supported health signal.

For an HTTP endpoint health check, Route 53 health checkers attempt to establish a connection and retrieve an HTTP response.

### Supported Health Check Types

Route 53 supports endpoint health checks using:

- HTTP
- HTTPS
- TCP

It also supports health checks based on CloudWatch alarm states and calculated health checks.

### What Makes an HTTP Health Check Healthy?

For a basic Route 53 HTTP health check, the endpoint must respond successfully according to Route 53's health checking rules.

HTTP `2xx` and `3xx` responses are treated as successful HTTP status codes.

Connection failures, timeouts, and unacceptable responses cause health check failures.

### What Is a Health Check Interval?

The request interval specifies how frequently individual health checkers attempt to check the endpoint.

This lab uses:

```text
RequestInterval = 30 seconds
```

### What Is FailureThreshold?

The failure threshold defines how many consecutive failures or successes an individual checker uses when changing its observed endpoint health.

This lab uses:

```text
FailureThreshold = 3
```

Health status is aggregated across distributed health checkers, so recovery is not necessarily immediate after changing the configuration.

### What Is the `/health` Endpoint?

A health endpoint is an application URL used to determine whether an application is responding.

Example:

```text
http://EC2_PUBLIC_IP:8080/health
```

Expected response:

```text
HTTP/1.0 200 OK

healthy
```

### Why Can a Healthy Application Have an Unhealthy Health Check?

Common reasons include:

- Incorrect port
- Incorrect health check path
- Wrong IP address
- Incorrect protocol
- Security group restrictions
- Network ACL restrictions
- Application errors
- HTTP response errors
- Connection timeouts
- TLS configuration problems

In this lab, the failure is caused by an incorrect monitoring port.

---

## 5. Prerequisites and Safety

### Requirements

- AWS account
- AWS CLI v2
- WSL Ubuntu
- Bash
- EC2 permissions
- VPC permissions
- IAM permissions
- Route 53 health check permissions
- Systems Manager access
- Git and GitHub

### Security Rules

- Use disposable lab infrastructure.
- Do not modify production health checks.
- Do not open SSH to the internet.
- Restrict application access to Route 53 health checker ranges.
- Use IMDSv2 for EC2.
- Do not commit AWS credentials.
- Verify resource identifiers before cleanup.
- Delete the health check after testing.
- Terminate temporary EC2 instances.

### Cost Considerations

This lab can incur charges for:

- EC2 instance usage
- EBS storage
- Public IPv4 usage
- Route 53 health checks

Delete the temporary resources after completing the exercise.

---

## 6. Prepare WSL Ubuntu

### Step 1 — Verify AWS Access

```bash
aws --version
aws sts get-caller-identity
```

### Step 2 — Configure Variables

```bash
export AWS_REGION="us-east-1"
export AWS_PAGER=""

export PROJECT_TAG="Route53-Troubleshooting-Lab07"

export VPC_CIDR="10.59.0.0/16"
export SUBNET_CIDR="10.59.1.0/24"

export APP_PORT=8080
export WRONG_PORT=8081

export EC2_ROLE_NAME="route53-lab07-ssm-role"
export PROFILE_NAME="route53-lab07-ssm-profile"
export SG_NAME="route53-lab07-web-sg"
```

### Step 3 — Verify Variables

```bash
echo "$AWS_REGION"
echo "$PROJECT_TAG"
echo "$APP_PORT"
echo "$WRONG_PORT"
```

Keep the WSL terminal open to preserve AWS resource IDs.

---

## 7. Create AWS VPC and Networking

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications \
  "ResourceType=vpc,Tags=[{Key=Name,Value=route53-lab07-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
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

### Step 3 — Check Supported Availability Zones

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

Change the value if that zone is unavailable in your account.

### Step 4 — Create Subnet

```bash
export SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_CIDR" \
  --availability-zone "$AZ" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=route53-lab07-public},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
  "ResourceType=internet-gateway,Tags=[{Key=Name,Value=route53-lab07-igw},{Key=Project,Value=$PROJECT_TAG}]" \
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
  "ResourceType=route-table,Tags=[{Key=Name,Value=route53-lab07-public-rt},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 7 — Create Internet Route

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

## 8. Configure Route 53 Health Checker Access

### Step 1 — Retrieve Managed Prefix List

```bash
export PREFIX_LIST_NAME="com.amazonaws.${AWS_REGION}.route53-healthchecks"

export PREFIX_LIST_ID=$(aws ec2 describe-managed-prefix-lists \
  --filters "Name=prefix-list-name,Values=$PREFIX_LIST_NAME" \
  --query 'PrefixLists[0].PrefixListId' \
  --output text \
  --region "$AWS_REGION")

echo "$PREFIX_LIST_ID"
```

Verify that the prefix list ID is not empty or `None`.

### Step 2 — Inspect Prefix List

```bash
aws ec2 describe-managed-prefix-lists \
  --prefix-list-ids "$PREFIX_LIST_ID" \
  --query 'PrefixLists[].{Name:PrefixListName,ID:PrefixListId,MaxEntries:MaxEntries}' \
  --output table \
  --region "$AWS_REGION"
```

The managed prefix list contains AWS-published Route 53 health checker source ranges.

### Step 3 — Create Security Group

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "Route53 Lab07 HTTP health check access" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")

echo "$SG_ID"
```

### Step 4 — Allow Health Checker Traffic on Port 8080

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --ip-permissions \
  "IpProtocol=tcp,FromPort=8080,ToPort=8080,PrefixListIds=[{PrefixListId=$PREFIX_LIST_ID}]" \
  --region "$AWS_REGION"
```

### Step 5 — Allow Health Checker Traffic on Port 8081

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --ip-permissions \
  "IpProtocol=tcp,FromPort=8081,ToPort=8081,PrefixListIds=[{PrefixListId=$PREFIX_LIST_ID}]" \
  --region "$AWS_REGION"
```

Both ports are allowed to ensure the intended failure is caused by the application not listening on 8081, rather than an inbound security group rule.

AWS-managed prefix lists consume security-group rule quota according to their configured weight. Verify that your security group quota can accommodate both rules.

### Step 6 — Verify Security Group

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected: TCP 8080 and TCP 8081 permitted from the Route 53 health checker prefix list.

---

## 9. Deploy EC2 HTTP Application

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

Allow IAM propagation.

### Step 4 — Create EC2 User Data

Save as `user-data.sh`:

```bash
#!/bin/bash
set -euxo pipefail

dnf install -y python3 curl bind-utils

mkdir -p /opt/route53-lab07

cat > /opt/route53-lab07/index.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Route 53 Lab 07</title>
</head>
<body>
    <h1>Route 53 Health Check Lab</h1>
    <p>Application is healthy.</p>
    <p>HTTP port: 8080</p>
</body>
</html>
HTML

echo "healthy" > /opt/route53-lab07/health

cat > /etc/systemd/system/route53-lab07.service <<'SERVICE'
[Unit]
Description=Route 53 Lab07 HTTP Application
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0 --directory /opt/route53-lab07
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now route53-lab07.service
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
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --associate-public-ip-address \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --user-data file://user-data.sh \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --count 1 \
  --tag-specifications \
  "ResourceType=instance,Tags=[{Key=Name,Value=route53-lab07-web},{Key=Project,Value=$PROJECT_TAG}]" \
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

### Step 8 — Retrieve Public IP

```bash
export PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region "$AWS_REGION")

echo "$PUBLIC_IP"
```

Expected: a public IPv4 address assigned by AWS.

---

## 10. Verify Application Health

### Step 1 — Connect Using Systems Manager

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 2 — Verify Application Service

Inside EC2:

```bash
sudo systemctl status route53-lab07 --no-pager
```

Expected:

```text
Active: active (running)
```

### Step 3 — Test the Correct Port

```bash
curl -i --max-time 5 http://127.0.0.1:8080/health
```

Expected:

```text
HTTP/1.0 200 OK

healthy
```

### Step 4 — Inspect Listening Ports

```bash
sudo ss -lntp | grep 8080
```

Expected: Python listening on port 8080.

### Step 5 — Test Incorrect Port

```bash
curl -v \
  --connect-timeout 3 \
  --max-time 5 \
  http://127.0.0.1:8081/health
```

Expected: connection refused or another connection failure.

### Application Verification Matrix

| Test | Expected Result |
|---|---|
| EC2 | Running |
| systemd Service | Active |
| Port 8080 | Listening |
| Port 8081 | Not listening |
| `/health` on 8080 | HTTP 200 |
| `/health` on 8081 | Connection failure |

Exit EC2:

```bash
exit
```

---

## 11. Fault Injection — Create Incorrect Health Check

### Step 1 — Create Incorrect Configuration

In WSL, generate `wrong-health-check.json`:

```bash
cat > wrong-health-check.json <<EOF
{
  "IPAddress": "$PUBLIC_IP",
  "Port": 8081,
  "Type": "HTTP",
  "ResourcePath": "/health",
  "RequestInterval": 30,
  "FailureThreshold": 3
}
EOF
```

### Step 2 — Create Route 53 Health Check

```bash
export CALLER_REF="route53-lab07-$(date +%s)"

export HEALTH_CHECK_ID=$(aws route53 create-health-check \
  --caller-reference "$CALLER_REF" \
  --health-check-config file://wrong-health-check.json \
  --query 'HealthCheck.Id' \
  --output text)

echo "$HEALTH_CHECK_ID"
```

### Step 3 — Add Resource Tags

```bash
aws route53 change-tags-for-resource \
  --resource-type healthcheck \
  --resource-id "$HEALTH_CHECK_ID" \
  --add-tags \
    "Key=Name,Value=route53-lab07-wrong-port" \
    "Key=Project,Value=$PROJECT_TAG"
```

### Step 4 — Verify Configuration

```bash
aws route53 get-health-check \
  --health-check-id "$HEALTH_CHECK_ID" \
  --query 'HealthCheck.HealthCheckConfig' \
  --output json
```

Expected relevant fields:

```json
{
  "IPAddress": "YOUR_EC2_PUBLIC_IP",
  "Port": 8081,
  "Type": "HTTP",
  "ResourcePath": "/health",
  "RequestInterval": 30,
  "FailureThreshold": 3
}
```

Additional fields may appear.

### Fault Injection Summary

| Component | Expected Value |
|---|---|
| Actual Application Port | 8080 |
| Health Check Port | 8081 |
| Endpoint | EC2 Public IP |
| Health Path | `/health` |
| Protocol | HTTP |
| Expected Result | Unhealthy after failure detection |

---

## 12. Reproduce Route 53 Health Check Failure

### Step 1 — Inspect Health Check Status

From WSL:

```bash
aws route53 get-health-check-status \
  --health-check-id "$HEALTH_CHECK_ID" \
  --output json
```

### Step 2 — Inspect Checker Observations

```bash
aws route53 get-health-check-status \
  --health-check-id "$HEALTH_CHECK_ID" \
  --query 'HealthCheckObservations[].{Region:Region,Status:StatusReport.Status}' \
  --output table
```

Expected after the health checkers have completed enough checks: unhealthy or failed connection observations.

### Step 3 — Inspect Last Failure Reason

```bash
aws route53 get-health-check-last-failure-reason \
  --health-check-id "$HEALTH_CHECK_ID" \
  --query 'HealthCheckObservations[].{Region:Region,Reason:StatusReport.Status,Checked:StatusReport.CheckedTime}' \
  --output table
```

Possible failure descriptions include:

```text
Connection refused
Connection timeout
Failed to establish TCP connection
```

The exact response depends on what the health checkers observe.

### Step 4 — Inspect Configured Port

```bash
aws route53 get-health-check \
  --health-check-id "$HEALTH_CHECK_ID" \
  --query 'HealthCheck.HealthCheckConfig.{IP:IPAddress,Port:Port,Type:Type,Path:ResourcePath}' \
  --output table
```

Expected: port 8081.

### Step 5 — Save Failure Evidence

```bash
aws route53 get-health-check \
  --health-check-id "$HEALTH_CHECK_ID" \
  --output json \
  > lab07-before-config.json
```

```bash
aws route53 get-health-check-status \
  --health-check-id "$HEALTH_CHECK_ID" \
  --output json \
  > lab07-before-status.json
```

```bash
aws route53 get-health-check-last-failure-reason \
  --health-check-id "$HEALTH_CHECK_ID" \
  --output json \
  > lab07-before-failure.json
```

### Expected Failure

| Check | Expected Result |
|---|---|
| Health Check Exists | Yes |
| Configured Port | 8081 |
| Application Port | 8080 |
| Connection to 8081 | Failed |
| Route 53 Checker Observations | Unhealthy after checks complete |
| Application Locally | Healthy |

---

## 13. Troubleshooting Investigation

### Check 1 — Verify Health Check Configuration

```bash
aws route53 get-health-check \
  --health-check-id "$HEALTH_CHECK_ID" \
  --output json
```

### Check 2 — Verify Security Group

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected: health checker source ranges are permitted on both ports.

### Check 3 — Connect to EC2

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Check 4 — Verify Application Service

Inside EC2:

```bash
sudo systemctl status route53-lab07 --no-pager
```

Expected: active.

### Check 5 — Inspect Listening Ports

```bash
sudo ss -lntp | grep -E '8080|8081'
```

Expected: only 8080 is listening.

### Check 6 — Test Correct Endpoint

```bash
curl -i --max-time 5 http://127.0.0.1:8080/health
```

Expected: HTTP 200.

### Check 7 — Test Incorrect Endpoint

```bash
curl -v \
  --connect-timeout 3 \
  --max-time 5 \
  http://127.0.0.1:8081/health
```

Expected: connection failure.

### Check 8 — Inspect Application Logs

```bash
sudo journalctl \
  -u route53-lab07 \
  -n 50 \
  --no-pager
```

### Check 9 — Save Linux Evidence

```bash
sudo ss -lntp \
  > "$HOME/lab07-listening-ports.txt"
```

```bash
curl -i http://127.0.0.1:8080/health \
  > "$HOME/lab07-application-health.txt"
```

Exit:

```bash
exit
```

### Investigation Matrix

| Investigation | Expected Finding |
|---|---|
| EC2 Instance | Running |
| Application Service | Active |
| Application Port | 8080 |
| Health Check Port | 8081 |
| HTTP `/health` on 8080 | 200 |
| HTTP `/health` on 8081 | Failed |
| Security Group | Permits checker access |
| Route 53 Observations | Unhealthy |
| Root Cause | Incorrect health check port |

---

## 14. Root Cause Analysis

### Root Cause

The Route 53 HTTP health check was configured to monitor TCP port 8081, while the EC2 application was listening on TCP port 8080.

The health checkers attempted to connect to the EC2 public IP on the wrong port.

Because no service was listening on port 8081, the requests could not establish a successful HTTP connection.

The health check was therefore marked unhealthy even though the application was operating normally.

### Root Cause Flow

```text
Route 53 Health Checker
         |
         v
EC2 Public IP
         |
         v
TCP Port 8081
         |
         v
No Listening Application
         |
         v
Connection Failure
         |
         v
Route 53 Unhealthy
```

### Five Whys

1. **Why did Route 53 report Unhealthy?** The HTTP health check requests failed.
2. **Why did the requests fail?** Route 53 attempted to connect to port 8081.
3. **Why was port 8081 incorrect?** The application listened on port 8080.
4. **Why was the application itself healthy?** Direct requests to port 8080 returned HTTP 200.
5. **How was the issue resolved?** The health check was updated to monitor port 8080.

### Root Cause Summary

| Component | Finding |
|---|---|
| AWS Service | Route 53 |
| Incident | Health Check Failure |
| Application Port | 8080 |
| Incorrect Health Check Port | 8081 |
| Application Health | Healthy |
| Route 53 Health | Unhealthy |
| Root Cause | Incorrect monitoring port |
| Remediation | Update health check |
| Application Redeployment | Not required |

---

## 15. Remediation — Correct Health Check Port

### Step 1 — Update Health Check

From WSL:

```bash
aws route53 update-health-check \
  --health-check-id "$HEALTH_CHECK_ID" \
  --port 8080
```

This updates the existing health check instead of creating a replacement.

### Step 2 — Verify Updated Configuration

```bash
aws route53 get-health-check \
  --health-check-id "$HEALTH_CHECK_ID" \
  --query 'HealthCheck.HealthCheckConfig.{IP:IPAddress,Port:Port,Type:Type,Path:ResourcePath}' \
  --output table
```

Expected:

```text
Type: HTTP
Port: 8080
Path: /health
```

### Step 3 — Inspect Health Check Status

```bash
aws route53 get-health-check-status \
  --health-check-id "$HEALTH_CHECK_ID" \
  --query 'HealthCheckObservations[].{Region:Region,Status:StatusReport.Status}' \
  --output table
```

Expected after recovery: successful health check observations.

### Step 4 — Review Last Failure Reason

```bash
aws route53 get-health-check-last-failure-reason \
  --health-check-id "$HEALTH_CHECK_ID" \
  --output json
```

The last failure API may still display historical failure information after the health check becomes healthy.

Use current checker observations to evaluate recovery.

### Step 5 — Verify Application

Connect to EC2:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
curl -i http://127.0.0.1:8080/health
```

Expected:

```text
HTTP/1.0 200 OK

healthy
```

Check logs:

```bash
sudo journalctl -u route53-lab07 -n 30 --no-pager
```

Exit:

```bash
exit
```

---

## 16. Final Verification

### Step 1 — Verify Health Check Configuration

```bash
aws route53 get-health-check \
  --health-check-id "$HEALTH_CHECK_ID" \
  --query 'HealthCheck.HealthCheckConfig' \
  --output json
```

Confirm:

```text
Port: 8080
Type: HTTP
ResourcePath: /health
```

### Step 2 — Verify Current Checker Observations

```bash
aws route53 get-health-check-status \
  --health-check-id "$HEALTH_CHECK_ID" \
  --query 'HealthCheckObservations[].{Region:Region,Status:StatusReport.Status,Checked:StatusReport.CheckedTime}' \
  --output table
```

Expected: successful health check observations after the monitoring configuration has propagated.

### Step 3 — Save Recovery Evidence

```bash
aws route53 get-health-check \
  --health-check-id "$HEALTH_CHECK_ID" \
  --output json \
  > lab07-after-config.json
```

```bash
aws route53 get-health-check-status \
  --health-check-id "$HEALTH_CHECK_ID" \
  --output json \
  > lab07-after-status.json
```

### Before and After Comparison

| Check | Before Fix | After Fix |
|---|---|---|
| Application Port | 8080 | 8080 |
| Health Check Port | 8081 | 8080 |
| Local Application | Healthy | Healthy |
| HTTP `/health` | 200 on 8080 | 200 on 8080 |
| Route 53 Status | Unhealthy | Healthy after recovery |
| Root Cause | Incorrect port | Corrected |
| Application Redeployment | Not needed | Not needed |
| Incident | Active | Resolved |

### Final Verification Criteria

The lab is successful when:

1. The EC2 application is running.
2. Port 8080 is listening.
3. The `/health` endpoint returns HTTP 200.
4. Route 53 health check configuration uses port 8080.
5. Current health checker observations report successful checks.
6. The original monitoring failure is no longer present.

---

## 17. Production Best Practices

### Health Check Troubleshooting Checklist

1. Identify the affected health check ID.
2. Inspect health check configuration.
3. Verify endpoint IP address or domain name.
4. Verify health check protocol.
5. Verify configured port.
6. Verify health check path.
7. Inspect Route 53 checker observations.
8. Review recent failure reasons.
9. Verify application process status.
10. Inspect listening ports.
11. Test the endpoint using curl.
12. Check security groups and network ACLs.
13. Confirm Route 53 checker network access.
14. Compare application health with monitoring health.
15. Correct the monitoring configuration.
16. Verify recovery from Route 53.
17. Document the incident.

### Common Health Check Failures

| Symptom | Possible Cause |
|---|---|
| Connection Refused | Wrong port or no listening service |
| Connection Timeout | Routing or firewall issue |
| HTTP 404 | Incorrect health check path |
| HTTP 500 | Application error |
| HTTP 503 | Application or service unavailable |
| TLS Failure | HTTPS or certificate issue |
| Intermittent Unhealthy | Application instability or network issues |
| Application Healthy, Check Unhealthy | Monitoring misconfiguration |

### Security Recommendations

- Use least-privilege IAM permissions.
- Restrict endpoint access to appropriate source ranges.
- Use the Route 53 health checker managed prefix list where applicable.
- Do not expose private applications unnecessarily.
- Use appropriate health monitoring for private-only endpoints.
- Avoid opening management ports to the internet.
- Use dedicated health endpoints.
- Monitor health status changes.
- Document health check configurations.
- Review monitoring changes before deployment.

### Health Checks for Private Applications

Standard Route 53 endpoint health checkers cannot directly monitor private-only IP addresses.

For private applications, consider supported alternatives such as CloudWatch-alarm-based health checks or load balancer target health evaluation, depending on the application architecture.

---

## 18. AWS Resource Cleanup

**Warning:** These commands permanently delete the temporary Lab 07 resources. Confirm the health check ID and AWS resource ownership before proceeding.

### Step 1 — Verify Health Check

```bash
aws route53 get-health-check \
  --health-check-id "$HEALTH_CHECK_ID"
```

### Step 2 — Verify Health Check Tags

```bash
aws route53 list-tags-for-resource \
  --resource-type healthcheck \
  --resource-id "$HEALTH_CHECK_ID"
```

Confirm that the health check belongs to Lab 07.

### Step 3 — Delete Route 53 Health Check

```bash
aws route53 delete-health-check \
  --health-check-id "$HEALTH_CHECK_ID"
```

### Step 4 — Verify Health Check Deletion

```bash
aws route53 get-health-check \
  --health-check-id "$HEALTH_CHECK_ID"
```

Expected: health check not found.

### Step 5 — Verify EC2 Root Volume

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings' \
  --output json \
  --region "$AWS_REGION"
```

Confirm the root EBS volume uses `DeleteOnTermination=true`.

### Step 6 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 7 — Verify IAM Role Ownership

```bash
aws iam list-role-tags \
  --role-name "$EC2_ROLE_NAME"
```

Confirm the Lab 07 project tag.

### Step 8 — Delete IAM Resources

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

### Step 9 — Verify Network Interface Removal

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Wait for the EC2 network interface to disappear.

### Step 10 — Delete Security Group

```bash
aws ec2 delete-security-group \
  --group-id "$SG_ID" \
  --region "$AWS_REGION"
```

This removes the temporary inbound rules referencing the Route 53 health checker prefix list.

### Step 11 — Delete Route Table Association

```bash
aws ec2 disassociate-route-table \
  --association-id "$ROUTE_ASSOC_ID" \
  --region "$AWS_REGION"
```

### Step 12 — Delete Route Table

```bash
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

### Step 16 — Verify VPC Cleanup

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

### Step 17 — Verify EC2 Termination

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].State.Name' \
  --output text \
  --region "$AWS_REGION"
```

Expected: `terminated`, if the instance remains visible in the EC2 API.

Also verify that the root EBS volume and IAM resources have been removed.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| Route 53 Health Check | Deleted |
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

### Q1. What is an Amazon Route 53 health check?

A monitoring feature that evaluates the health of endpoints or other supported health signals.

### Q2. Which endpoint protocols does Route 53 support?

HTTP, HTTPS, and TCP endpoint health checks.

### Q3. What is the difference between application health and health check status?

Application health describes whether the application is operating. Health check status describes whether the monitoring system successfully checks its configured endpoint.

An incorrect monitoring configuration can report unhealthy even when the application works.

### Q4. Why did the health check fail in this lab?

The health check monitored port 8081, but the application listened on port 8080.

### Q5. How do you inspect health check configuration?

```bash
aws route53 get-health-check \
  --health-check-id HEALTH_CHECK_ID
```

### Q6. How do you inspect health checker observations?

```bash
aws route53 get-health-check-status \
  --health-check-id HEALTH_CHECK_ID
```

### Q7. How do you retrieve health check failure reasons?

```bash
aws route53 get-health-check-last-failure-reason \
  --health-check-id HEALTH_CHECK_ID
```

### Q8. How do you update a health check port?

```bash
aws route53 update-health-check \
  --health-check-id HEALTH_CHECK_ID \
  --port 8080
```

### Q9. Can Route 53 directly monitor private EC2 IPs using standard HTTP endpoint health checks?

No. Standard Route 53 endpoint health checkers cannot directly access private-only IP addresses.

### Q10. How can you restrict endpoint access to Route 53 health checkers?

By allowing the AWS-published Route 53 health checker address ranges or the applicable AWS-managed prefix list.

### Q11. What is FailureThreshold?

The number of consecutive successful or failed checks used by an individual checker to determine endpoint status transitions.

### Q12. How would you explain this lab in an interview?

I deployed a healthy EC2 HTTP application running on port 8080 and configured a Route 53 HTTP health check to intentionally monitor the wrong port, 8081.

The application returned HTTP 200 locally, but Route 53 reported the endpoint as unhealthy.

I investigated the issue using AWS CLI, Route 53 checker observations, failure reasons, Linux listening-port information, systemd, and application logs.

I confirmed that the security group allowed health checker access but no application was listening on port 8081.

After identifying the incorrect monitoring configuration, I updated the existing health check to port 8080.

I verified the correct configuration and successful health checker observations, then deleted all temporary AWS resources.

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
└── 07-route53-health-check-failure/
    ├── README.md
    ├── ec2-trust-policy.json
    ├── user-data.sh
    ├── wrong-health-check.json
    ├── lab07-before-config.json
    ├── lab07-before-status.json
    ├── lab07-before-failure.json
    ├── lab07-after-config.json
    └── lab07-after-status.json
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete incident and troubleshooting documentation |
| `ec2-trust-policy.json` | IAM trust policy for EC2 |
| `user-data.sh` | Deploys HTTP application and `/health` endpoint |
| `wrong-health-check.json` | Creates misconfigured health check |
| `lab07-before-config.json` | Captures incorrect health check configuration |
| `lab07-before-status.json` | Records unhealthy checker observations |
| `lab07-before-failure.json` | Captures failure information |
| `lab07-after-config.json` | Captures corrected health check configuration |
| `lab07-after-status.json` | Records recovery observations |

The before-and-after evidence files are generated from your AWS environment. Their exact contents will vary.

Review and sanitize these files before publishing them to GitHub.

---

## 21. Lessons Learned and Skills Demonstrated

### Lessons Learned

This lab demonstrates how an incorrect Route 53 health check configuration can cause a healthy application to appear unavailable.

We created an AWS VPC, configured secure access for Route 53 health checkers, and deployed a Python HTTP application on an EC2 instance.

The application listened on port 8080 and returned HTTP 200 from its `/health` endpoint.

We intentionally configured Route 53 to monitor port 8081, where no application was listening.

The health checkers failed to establish successful HTTP connections and reported the endpoint as unhealthy.

We investigated the problem using AWS CLI, health checker observations, failure reasons, Linux networking utilities, systemd, and application logs.

We confirmed that the application itself was healthy and identified the monitoring port mismatch as the root cause.

After updating the Route 53 health check to port 8080, we verified that the monitoring configuration was correct and that health checker observations recovered.

**Key Lesson:** An unhealthy Route 53 health check does not automatically mean the application is down. Always compare the health check's configured endpoint with the application's actual listening port, protocol, and health path.

### Skills Demonstrated

- Amazon Route 53
- Route 53 HTTP health checks
- Health check configuration
- Health checker observations
- Health check failure investigation
- Route 53 health check updates
- AWS-managed prefix lists
- Security group troubleshooting
- Amazon EC2
- Python HTTP server
- EC2 user data
- Linux systemd
- Linux `curl`
- Linux `ss`
- Linux `journalctl`
- Amazon VPC
- Internet Gateway
- AWS Systems Manager
- IAM roles and instance profiles
- AWS CLI v2
- Root cause analysis
- Monitoring remediation
- Health recovery verification
- AWS resource cleanup

### Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-R53-007 |
| Scenario | Route 53 Health Check Failure |
| Application Port | 8080 |
| Incorrect Health Check Port | 8081 |
| Health Endpoint | `/health` |
| Application HTTP Response | 200 |
| Health Status Before Fix | Unhealthy |
| Root Cause | Incorrect health check port |
| Remediation | Update port to 8080 |
| Application Redeployment | Not required |
| Health Status After Fix | Healthy after recovery |
| Cleanup | Temporary resources removed |
| Incident Status | Resolved after verification |

**Key Takeaway:** Effective cloud monitoring troubleshooting requires validating the monitoring configuration separately from the application. Route 53 health checks can report unhealthy because of incorrect ports, paths, protocols, or networking, even when the underlying service is fully operational.
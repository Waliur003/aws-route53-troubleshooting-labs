# Lab 06 — Route 53 Incorrect Alias Record

## Overview

This lab demonstrates how to troubleshoot an incorrect Amazon Route 53 alias A record pointing to the wrong Application Load Balancer (ALB).

We deploy an AWS VPC with two subnets across different Availability Zones, launch an EC2 instance hosting a Python HTTP application, and create two internal Application Load Balancers.

The correct ALB forwards HTTP requests to the healthy EC2 application and returns HTTP `200 OK`.

The incorrect ALB is configured with a fixed-response listener returning HTTP `503 Service Unavailable`.

We intentionally create a Route 53 alias A record pointing to the incorrect ALB.

DNS resolution succeeds, but users receive an HTTP 503 error because their requests reach the wrong load balancer.

We investigate the problem using AWS CLI, Linux DNS utilities, HTTP requests, target group health checks, ALB listeners, and Route 53 alias configuration.

After identifying the wrong alias target, we correct the record using a Route 53 `UPSERT` operation and verify that the application returns HTTP 200.

Finally, we delete the temporary AWS infrastructure.

**Troubleshooting workflow:**

Infrastructure Setup → Healthy Application → Two Internal ALBs → Incorrect Alias → HTTP 503 → Investigation → Root Cause Analysis → Remediation → HTTP 200 → Cleanup

---

## 1. Lab Information

| Item | Configuration |
|---|---|
| Incident ID | INC-R53-006 |
| Difficulty | Intermediate–Advanced |
| AWS Region | `us-east-1` |
| AWS Services | Route 53, EC2, VPC, ELBv2, IAM, Systems Manager |
| Local Environment | WSL Ubuntu |
| Operating System | Amazon Linux 2023 |
| EC2 Instance Type | `t3.micro` |
| VPC CIDR | `10.58.0.0/16` |
| Subnet A | `10.58.1.0/24` |
| Subnet B | `10.58.2.0/24` |
| Hosted Zone | `lab06.route53.test` |
| Hosted Zone Type | Private |
| Application Hostname | `app.lab06.route53.test` |
| DNS Record | Alias A |
| Correct ALB | `route53-lab06-correct` |
| Incorrect ALB | `route53-lab06-wrong` |
| ALB Scheme | Internal |
| ALB Listener | HTTP 80 |
| EC2 Application Port | 8080 |
| Correct ALB Response | HTTP 200 |
| Wrong ALB Response | HTTP 503 |
| Target Health | Healthy |
| Alias Health Evaluation | `false` |
| Fault Injection | Alias points to wrong ALB |
| Remediation | Route 53 UPSERT |
| Verification | AWS CLI, `dig`, `curl`, ELBv2 APIs |

---

## 2. Production Incident Scenario

### Incident Description

A company hosts an internal web application behind an AWS Application Load Balancer.

Employees access the application through the hostname:

`app.lab06.route53.test`

The application runs on an EC2 instance and is reachable through its correct internal ALB.

During a DNS configuration update, an engineer accidentally changes the Route 53 alias A record to point to another internal ALB.

The incorrect ALB exists and accepts HTTP connections, but its listener returns:

```text
HTTP/1.1 503 Service Unavailable
```

The intended application is still running and healthy behind the correct ALB.

The Cloud Engineer must investigate the Route 53 alias, identify the incorrect destination, restore the correct ALB target, and verify successful HTTP requests.

### Incident Symptoms

- The application hostname resolves successfully.
- DNS returns `NOERROR`.
- The Route 53 alias points to an unintended ALB.
- HTTP requests through the application hostname return 503.
- Direct requests to the correct ALB return HTTP 200.
- EC2 application is healthy.
- Target group reports healthy.
- Correcting the alias restores HTTP access.

### Business Impact

- Employees cannot access the application through its intended hostname.
- Application requests receive HTTP 503 responses.
- A healthy application appears unavailable.
- DNS misrouting can increase application downtime.
- Engineers may mistakenly investigate or redeploy functioning infrastructure.
- Incorrect alias records may direct application traffic to unintended resources.

### Objective

Identify and correct an incorrect Route 53 alias target while proving that the underlying EC2 application and intended Application Load Balancer remain healthy.

---

## 3. AWS Architecture

### Infrastructure Architecture

```text
                        AWS Region
                         us-east-1
                             |
                             v
                        Amazon VPC
                      10.58.0.0/16
                             |
               ---------------------------
               |                         |
               v                         v
          Subnet A                  Subnet B
        10.58.1.0/24              10.58.2.0/24
               |                         |
               ---------------------------
                             |
                   --------------------
                   |                  |
                   v                  v
              Correct ALB         Wrong ALB
            Internal HTTP 80    Internal HTTP 80
                   |                  |
                   v                  v
              Target Group      Fixed Response
              HTTP 8080           HTTP 503
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
                HTTP 200
```

### Incorrect Route 53 Alias

```text
EC2 DNS Client
       |
       v
app.lab06.route53.test
       |
       v
Route 53 Private Hosted Zone
       |
       v
Alias A Record
       |
       v
Wrong Internal ALB
       |
       v
Fixed Response Listener
       |
       v
HTTP 503 Service Unavailable
```

### Correct Architecture After Remediation

```text
EC2 DNS Client
       |
       v
app.lab06.route53.test
       |
       v
Route 53 Private Hosted Zone
       |
       v
Correct Alias A Record
       |
       v
Correct Internal ALB
       |
       v
Target Group
       |
       v
Healthy EC2 Application
       |
       v
HTTP 200 OK
```

### Network Configuration

| Component | Configuration |
|---|---|
| VPC | `10.58.0.0/16` |
| Subnet A | `10.58.1.0/24` |
| Subnet B | `10.58.2.0/24` |
| Internet Gateway | Attached |
| Public Route | `0.0.0.0/0` |
| ALB Security Group | TCP 80 from lab VPC |
| EC2 Security Group | TCP 8080 from ALB security group |
| EC2 Management | Systems Manager |
| Application Port | 8080 |
| ALB Listener Port | 80 |
| Route 53 Hosted Zone | Private |

Both ALBs use two subnets in different Availability Zones.

Although the subnets have a route to an Internet Gateway, the ALBs themselves use the `internal` scheme and are not directly accessible from the public internet.

---

## 4. Understanding Route 53 Alias Records

### What Is a Route 53 Alias Record?

A Route 53 alias record points a DNS hostname to a supported AWS resource.

Supported targets include Application Load Balancers, certain CloudFront distributions, API Gateway custom domains, and other supported AWS endpoints.

For this lab, the alias points to an Application Load Balancer.

### Alias A Record Example

```text
Name: app.lab06.route53.test
Type: A
Alias: Yes
Target: internal-route53-lab06-correct-xxx.elb.amazonaws.com
```

The exact ALB DNS name is generated by AWS.

### Alias vs. CNAME

| Feature | Alias A | CNAME |
|---|---|---|
| Route 53-Specific Feature | Yes | No |
| Points to | Supported AWS resource or eligible Route 53 record | Another hostname |
| Returns A Records | Yes | Through DNS alias resolution |
| Supported at Zone Apex | Yes, with supported targets | No |
| Uses Standard Record TTL Field | No for an ALB alias | Yes |
| Example Target | Application Load Balancer | `origin.example.com` |

### What Is CanonicalHostedZoneId?

`CanonicalHostedZoneId` identifies the AWS-managed DNS zone associated with an Application Load Balancer.

Route 53 requires this identifier in the alias target configuration.

Example:

```json
{
  "AliasTarget": {
    "HostedZoneId": "ALB_CANONICAL_HOSTED_ZONE_ID",
    "DNSName": "ALB_DNS_NAME",
    "EvaluateTargetHealth": false
  }
}
```

### Two Different Hosted Zone IDs

A frequent mistake is confusing these values:

| Identifier | Purpose |
|---|---|
| Route 53 Hosted Zone ID | Identifies the zone containing the application alias record |
| ALB Canonical Hosted Zone ID | Identifies the AWS-managed DNS zone for the ALB target |

For a load balancer alias, use the ALB's `CanonicalHostedZoneId` inside `AliasTarget.HostedZoneId`.

### What Is EvaluateTargetHealth?

`EvaluateTargetHealth` controls whether Route 53 considers the target resource's health when evaluating an alias for applicable routing policies.

We use:

```text
EvaluateTargetHealth = false
```

This keeps the lab focused on the incorrect alias destination.

It does not mean that disabling alias target health evaluation is always appropriate for production systems.

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
- Elastic Load Balancing permissions
- IAM permissions
- Systems Manager access
- Git and GitHub

### Safety Rules

- Use a disposable private hosted zone.
- Do not modify production alias records.
- Do not expose internal ALBs publicly.
- Use dedicated security groups.
- Do not enable unnecessary inbound SSH access.
- Verify ALB names and ARNs before deletion.
- Avoid committing credentials or secrets.
- Delete both ALBs after completing the experiment.
- Review AWS resource costs.

### Cost Considerations

This lab creates two Application Load Balancers.

Both ALBs can incur hourly charges and load-balancer capacity charges.

Additional charges may apply for the EC2 instance, EBS storage, public IPv4 address, and Route 53 private hosted zone.

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

export PROJECT_TAG="Route53-Troubleshooting-Lab06"

export VPC_CIDR="10.58.0.0/16"
export SUBNET_A_CIDR="10.58.1.0/24"
export SUBNET_B_CIDR="10.58.2.0/24"

export ZONE_NAME="lab06.route53.test"
export RECORD_NAME="app.lab06.route53.test"

export CORRECT_ALB_NAME="route53-lab06-correct"
export WRONG_ALB_NAME="route53-lab06-wrong"

export EC2_ROLE_NAME="route53-lab06-ssm-role"
export PROFILE_NAME="route53-lab06-ssm-profile"
```

### Step 3 — Verify Variables

```bash
echo "$AWS_REGION"
echo "$ZONE_NAME"
echo "$RECORD_NAME"
echo "$CORRECT_ALB_NAME"
echo "$WRONG_ALB_NAME"
```

Keep the WSL terminal open because the resource IDs and ARNs will be stored in environment variables.

---

## 7. Create VPC and Networking

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications \
  "ResourceType=vpc,Tags=[{Key=Name,Value=route53-lab06-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
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

### Step 3 — Choose Two Availability Zones

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

Choose two distinct supported AZs:

```bash
export AZ_A="us-east-1a"
export AZ_B="us-east-1b"
```

### Step 4 — Create Subnet A

```bash
export SUBNET_A_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_A_CIDR" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=route53-lab06-subnet-a},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Create Subnet B

```bash
export SUBNET_B_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_B_CIDR" \
  --availability-zone "$AZ_B" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=route53-lab06-subnet-b},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 6 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
  "ResourceType=internet-gateway,Tags=[{Key=Name,Value=route53-lab06-igw},{Key=Project,Value=$PROJECT_TAG}]" \
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
  "ResourceType=route-table,Tags=[{Key=Name,Value=route53-lab06-rt},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 8 — Create Internet Route

```bash
aws ec2 create-route \
  --route-table-id "$ROUTE_TABLE_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 9 — Associate Both Subnets

```bash
export ROUTE_ASSOC_A=$(aws ec2 associate-route-table \
  --route-table-id "$ROUTE_TABLE_ID" \
  --subnet-id "$SUBNET_A_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")

export ROUTE_ASSOC_B=$(aws ec2 associate-route-table \
  --route-table-id "$ROUTE_TABLE_ID" \
  --subnet-id "$SUBNET_B_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

---

## 8. Create Route 53 Private Hosted Zone

### Step 1 — Create Hosted Zone

```bash
export HOSTED_ZONE_ID=$(aws route53 create-hosted-zone \
  --name "$ZONE_NAME" \
  --caller-reference "route53-lab06-$(date +%s)" \
  --vpc "VPCRegion=$AWS_REGION,VPCId=$VPC_ID" \
  --hosted-zone-config \
  "Comment=Route53 incorrect ALB alias Lab06,PrivateZone=true" \
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

Expected: private hosted zone associated with the Lab 06 VPC.

---

## 9. Create Security Groups

### Step 1 — Create ALB Security Group

```bash
export ALB_SG_ID=$(aws ec2 create-security-group \
  --group-name "route53-lab06-alb-sg" \
  --description "Internal ALB HTTP access from lab VPC" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=route53-lab06-alb-sg},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Allow HTTP to ALB

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$ALB_SG_ID" \
  --protocol tcp \
  --port 80 \
  --cidr "$VPC_CIDR" \
  --region "$AWS_REGION"
```

### Step 3 — Create EC2 Security Group

```bash
export EC2_SG_ID=$(aws ec2 create-security-group \
  --group-name "route53-lab06-ec2-sg" \
  --description "EC2 application accepts traffic from ALB" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=route53-lab06-ec2-sg},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Allow ALB to EC2

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$EC2_SG_ID" \
  --protocol tcp \
  --port 8080 \
  --source-group "$ALB_SG_ID" \
  --region "$AWS_REGION"
```

### Security Group Summary

| Security Group | Inbound Rule |
|---|---|
| ALB SG | TCP 80 from lab VPC CIDR |
| EC2 SG | TCP 8080 from ALB SG |
| SSH | Not allowed |
| Outbound | Default rules |

---

## 10. Deploy Healthy EC2 Application

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

Allow IAM propagation before launching EC2.

### Step 4 — Create EC2 User Data

Save as `user-data.sh`:

```bash
#!/bin/bash
set -euxo pipefail

dnf install -y python3 bind-utils curl

mkdir -p /opt/route53-lab06

cat > /opt/route53-lab06/index.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Route 53 Lab 06</title>
</head>
<body>
    <h1>Route 53 Alias Troubleshooting</h1>
    <p>Healthy application behind the correct ALB.</p>
    <p>Lab 06 - Incorrect Alias Record</p>
</body>
</html>
HTML

cat > /etc/systemd/system/route53-lab06.service <<'SERVICE'
[Unit]
Description=Route 53 Lab06 HTTP Application
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0 --directory /opt/route53-lab06
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now route53-lab06.service
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
  --subnet-id "$SUBNET_A_ID" \
  --security-group-ids "$EC2_SG_ID" \
  --associate-public-ip-address \
  --user-data file://user-data.sh \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --tag-specifications \
  "ResourceType=instance,Tags=[{Key=Name,Value=route53-lab06-web},{Key=Project,Value=$PROJECT_TAG}]" \
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

### Step 9 — Verify Application

Inside EC2:

```bash
sudo systemctl status route53-lab06 --no-pager
```

Test:

```bash
curl --max-time 5 http://127.0.0.1:8080
```

Expected:

```html
<h1>Route 53 Alias Troubleshooting</h1>
<p>Healthy application behind the correct ALB.</p>
<p>Lab 06 - Incorrect Alias Record</p>
```

### Step 10 — Troubleshoot Application If Needed

```bash
sudo journalctl -u route53-lab06 -n 30 --no-pager
sudo tail -n 50 /var/log/cloud-init-output.log
```

Exit EC2:

```bash
exit
```

---

## 11. Create ALB Target Group

### Step 1 — Create Target Group

```bash
export TG_ARN=$(aws elbv2 create-target-group \
  --name "route53-lab06-tg" \
  --protocol HTTP \
  --port 8080 \
  --vpc-id "$VPC_ID" \
  --target-type instance \
  --health-check-protocol HTTP \
  --health-check-path "/" \
  --matcher HttpCode=200 \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text \
  --region "$AWS_REGION")

echo "$TG_ARN"
```

### Step 2 — Register EC2 Target

```bash
aws elbv2 register-targets \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"
```

### Step 3 — Inspect Target Health

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --region "$AWS_REGION"
```

The target may initially be in the `initial` or `unused` state until the ALB is associated with the target group.

---

## 12. Create Correct and Incorrect ALBs

### Step 1 — Create Correct ALB

```bash
export CORRECT_ALB_ARN=$(aws elbv2 create-load-balancer \
  --name "$CORRECT_ALB_NAME" \
  --type application \
  --scheme internal \
  --ip-address-type ipv4 \
  --subnets "$SUBNET_A_ID" "$SUBNET_B_ID" \
  --security-groups "$ALB_SG_ID" \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text \
  --region "$AWS_REGION")

echo "$CORRECT_ALB_ARN"
```

### Step 2 — Create Incorrect ALB

```bash
export WRONG_ALB_ARN=$(aws elbv2 create-load-balancer \
  --name "$WRONG_ALB_NAME" \
  --type application \
  --scheme internal \
  --ip-address-type ipv4 \
  --subnets "$SUBNET_A_ID" "$SUBNET_B_ID" \
  --security-groups "$ALB_SG_ID" \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text \
  --region "$AWS_REGION")

echo "$WRONG_ALB_ARN"
```

### Step 3 — Wait for ALBs

```bash
aws elbv2 wait load-balancer-available \
  --load-balancer-arns "$CORRECT_ALB_ARN" "$WRONG_ALB_ARN" \
  --region "$AWS_REGION"
```

### Step 4 — Create Correct ALB Listener

```bash
export CORRECT_LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn "$CORRECT_ALB_ARN" \
  --protocol HTTP \
  --port 80 \
  --default-actions "Type=forward,TargetGroupArn=$TG_ARN" \
  --query 'Listeners[0].ListenerArn' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Create Incorrect ALB Response

Save as `wrong-alb-response.json`:

```json
[
  {
    "Type": "fixed-response",
    "FixedResponseConfig": {
      "MessageBody": "Lab06 wrong ALB - service unavailable",
      "StatusCode": "503",
      "ContentType": "text/plain"
    }
  }
]
```

### Step 6 — Create Incorrect ALB Listener

```bash
export WRONG_LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn "$WRONG_ALB_ARN" \
  --protocol HTTP \
  --port 80 \
  --default-actions file://wrong-alb-response.json \
  --query 'Listeners[0].ListenerArn' \
  --output text \
  --region "$AWS_REGION")
```

### Step 7 — Verify Healthy Target

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{Instance:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
  --output table \
  --region "$AWS_REGION"
```

Expected after health checks complete:

```text
healthy
```

---

## 13. Retrieve ALB DNS and Canonical Hosted Zone IDs

### Step 1 — Retrieve Correct ALB Information

```bash
export CORRECT_ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$CORRECT_ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' \
  --output text \
  --region "$AWS_REGION")

export CORRECT_ALB_ZONE=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$CORRECT_ALB_ARN" \
  --query 'LoadBalancers[0].CanonicalHostedZoneId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Retrieve Incorrect ALB Information

```bash
export WRONG_ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$WRONG_ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' \
  --output text \
  --region "$AWS_REGION")

export WRONG_ALB_ZONE=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$WRONG_ALB_ARN" \
  --query 'LoadBalancers[0].CanonicalHostedZoneId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Compare ALB Information

```bash
aws elbv2 describe-load-balancers \
  --load-balancer-arns "$CORRECT_ALB_ARN" "$WRONG_ALB_ARN" \
  --query 'LoadBalancers[].{Name:LoadBalancerName,DNS:DNSName,Zone:CanonicalHostedZoneId,Scheme:Scheme,State:State.Code}' \
  --output table \
  --region "$AWS_REGION"
```

### Important Distinction

The Route 53 application hosted zone ID identifies where the alias record is created.

The ALB `CanonicalHostedZoneId` identifies the AWS-managed load balancer DNS zone and is used inside the alias target.

The two ALBs may share the same canonical hosted zone ID because they are in the same AWS Region.

The actual ALB DNS names identify the different load balancers.

---

## 14. Fault Injection — Incorrect Alias Target

### Step 1 — Verify Both ALBs

Connect to EC2:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2, configure the actual ALB DNS names:

```bash
export CORRECT_ALB_DNS="PASTE_CORRECT_ALB_DNS"
export WRONG_ALB_DNS="PASTE_WRONG_ALB_DNS"
```

Test correct ALB:

```bash
curl -i --max-time 10 "http://$CORRECT_ALB_DNS/"
```

Expected:

```text
HTTP/1.1 200 OK
```

Test incorrect ALB:

```bash
curl -i --max-time 10 "http://$WRONG_ALB_DNS/"
```

Expected:

```text
HTTP/1.1 503 Service Unavailable
```

Exit EC2:

```bash
exit
```

### Step 2 — Create Incorrect Alias JSON

In WSL, generate `wrong-alias.json`:

```bash
cat > wrong-alias.json <<EOF
{
  "Comment": "Lab06 - Intentionally point alias to wrong ALB",
  "Changes": [
    {
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "$RECORD_NAME",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "$WRONG_ALB_ZONE",
          "DNSName": "$WRONG_ALB_DNS",
          "EvaluateTargetHealth": false
        }
      }
    }
  ]
}
EOF
```

### Step 3 — Apply Incorrect Alias

```bash
export FAULT_CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch file://wrong-alias.json \
  --query 'ChangeInfo.Id' \
  --output text)

aws route53 wait resource-record-sets-changed \
  --id "$FAULT_CHANGE_ID"
```

### Step 4 — Verify Incorrect Alias

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}.']" \
  --output json
```

Expected: `AliasTarget.DNSName` points to the incorrect ALB.

---

## 15. Reproduce and Investigate the Failure

### Step 1 — Connect to EC2

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
export RECORD_NAME="app.lab06.route53.test"
export VPC_DNS="10.58.0.2"
```

### Step 2 — Verify DNS Resolution

```bash
dig @"$VPC_DNS" "$RECORD_NAME" A
```

Expected:

```text
status: NOERROR
```

The answer contains private IP addresses associated with the wrong ALB.

### Step 3 — Verify Short DNS Answer

```bash
dig +short @"$VPC_DNS" "$RECORD_NAME" A
```

Expected: private ALB IP addresses.

### Step 4 — Reproduce HTTP 503

```bash
curl -i \
  --connect-timeout 3 \
  --max-time 10 \
  "http://$RECORD_NAME/"
```

Expected:

```text
HTTP/1.1 503 Service Unavailable
```

Response:

```text
Lab06 wrong ALB - service unavailable
```

### Step 5 — Confirm Correct ALB Works

Use the correct ALB DNS name:

```bash
curl -i --max-time 10 \
  "http://YOUR_CORRECT_ALB_DNS/"
```

Expected:

```text
HTTP/1.1 200 OK
```

### Step 6 — Save Failure Evidence

```bash
dig @"$VPC_DNS" "$RECORD_NAME" A \
  > "$HOME/lab06-before-dns.txt"

curl -i --max-time 10 "http://$RECORD_NAME/" \
  > "$HOME/lab06-before-http.txt" 2>&1 || true
```

Exit EC2:

```bash
exit
```

### Step 7 — Inspect Route 53 Alias

From WSL:

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}.']" \
  --output json
```

### Step 8 — Compare ALB DNS Names

```bash
echo "Configured Alias: $WRONG_ALB_DNS"
echo "Expected Alias:   $CORRECT_ALB_DNS"
```

### Step 9 — Inspect ALB Listeners

Correct ALB:

```bash
aws elbv2 describe-listeners \
  --load-balancer-arn "$CORRECT_ALB_ARN" \
  --query 'Listeners[].{Port:Port,Actions:DefaultActions}' \
  --output json \
  --region "$AWS_REGION"
```

Incorrect ALB:

```bash
aws elbv2 describe-listeners \
  --load-balancer-arn "$WRONG_ALB_ARN" \
  --query 'Listeners[].{Port:Port,Actions:DefaultActions}' \
  --output json \
  --region "$AWS_REGION"
```

### Step 10 — Verify Target Health

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{Instance:Target.Id,State:TargetHealth.State}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: healthy.

### Investigation Summary

| Investigation | Expected Finding |
|---|---|
| Route 53 Alias | Exists |
| Alias Target | Wrong ALB |
| DNS Status | NOERROR |
| HTTP via Alias | 503 |
| Correct ALB Listener | Forward to target group |
| Wrong ALB Listener | Fixed response 503 |
| EC2 Target Health | Healthy |
| Root Cause | Incorrect alias destination |

---

## 16. Root Cause Analysis

### Root Cause

The Route 53 alias A record for `app.lab06.route53.test` pointed to the incorrect Application Load Balancer.

The wrong ALB existed and accepted HTTP connections, but its listener returned HTTP 503.

The intended ALB was functioning correctly and forwarding requests to a healthy EC2 application.

Because the DNS alias referenced the wrong resource, clients were routed away from the working application.

### Root Cause Flow

```text
Application Client
       |
       v
Route 53 Alias A Record
       |
       v
Incorrect ALB DNS Name
       |
       v
Wrong Internal ALB
       |
       v
Fixed HTTP 503 Listener
       |
       v
Application Unavailable
```

### Five Whys

1. **Why did the application return HTTP 503?** Requests went to the wrong ALB.
2. **Why did requests reach the wrong ALB?** The Route 53 alias referenced its DNS name.
3. **Why did DNS still work?** The incorrect ALB was a valid existing AWS resource.
4. **Why wasn't the EC2 application responsible?** The correct ALB returned HTTP 200 and its target group was healthy.
5. **How was the issue resolved?** The alias record was updated to the correct ALB.

### Root Cause Summary

| Item | Finding |
|---|---|
| Incident | INC-R53-006 |
| Service | Amazon Route 53 |
| Error | HTTP 503 |
| DNS Response | NOERROR |
| Root Cause | Incorrect alias target |
| Incorrect Resource | Wrong internal ALB |
| Correct Resource | Healthy internal ALB |
| Remediation | Alias UPSERT |
| Application Redeployment | Not required |

---

## 17. Remediation and Final Verification

### Step 1 — Create Correct Alias JSON

From WSL:

```bash
cat > correct-alias.json <<EOF
{
  "Comment": "Lab06 - Correct Route53 alias target",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$RECORD_NAME",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "$CORRECT_ALB_ZONE",
          "DNSName": "$CORRECT_ALB_DNS",
          "EvaluateTargetHealth": false
        }
      }
    }
  ]
}
EOF
```

### Step 2 — Update Alias Record

```bash
export FIX_CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch file://correct-alias.json \
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

### Step 5 — Verify Alias Target

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}.'].AliasTarget" \
  --output json
```

Expected: correct ALB DNS name and canonical hosted zone ID.

### Step 6 — Verify DNS Resolution

Connect to EC2:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
export RECORD_NAME="app.lab06.route53.test"
export VPC_DNS="10.58.0.2"

dig @"$VPC_DNS" "$RECORD_NAME" A
```

Expected: NOERROR and private addresses for the correct ALB.

### Step 7 — Verify HTTP Recovery

```bash
curl -i \
  --connect-timeout 3 \
  --max-time 10 \
  "http://$RECORD_NAME/"
```

Expected:

```text
HTTP/1.1 200 OK
```

The response should contain:

```text
Healthy application behind the correct ALB.
```

### Step 8 — Save Recovery Evidence

```bash
dig @"$VPC_DNS" "$RECORD_NAME" A \
  > "$HOME/lab06-after-dns.txt"

curl -i --max-time 10 "http://$RECORD_NAME/" \
  > "$HOME/lab06-after-http.txt" 2>&1
```

### Before and After Comparison

| Check | Before Fix | After Fix |
|---|---|---|
| Alias Target | Wrong ALB | Correct ALB |
| DNS Status | NOERROR | NOERROR |
| HTTP Status | 503 | 200 |
| Correct ALB | Healthy | Healthy |
| EC2 Target | Healthy | Healthy |
| Application via Hostname | Failed | Working |
| Incident | Active | Resolved |

Previously cached alias answers may remain briefly after the Route 53 change reaches `INSYNC`. Allow those cached responses to expire if necessary.

---

## 18. AWS Resource Cleanup

**Warning:** Delete only the resources created for Lab 06. Confirm resource IDs and ARNs before deletion.

### Step 1 — Exit EC2

```bash
exit
```

Return to WSL.

### Step 2 — Create Alias Delete Batch

Generate `delete-alias.json`:

```bash
cat > delete-alias.json <<EOF
{
  "Comment": "Lab06 cleanup - delete alias",
  "Changes": [
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "$RECORD_NAME",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "$CORRECT_ALB_ZONE",
          "DNSName": "$CORRECT_ALB_DNS",
          "EvaluateTargetHealth": false
        }
      }
    }
  ]
}
EOF
```

Verify the current record before deletion:

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}.']" \
  --output json
```

The deletion batch must match the current alias record.

### Step 3 — Delete Alias

```bash
export DELETE_CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch file://delete-alias.json \
  --query 'ChangeInfo.Id' \
  --output text)

aws route53 wait resource-record-sets-changed \
  --id "$DELETE_CHANGE_ID"
```

### Step 4 — Delete Hosted Zone

Verify only NS and SOA records remain:

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

### Step 5 — Delete Both ALB Listeners

```bash
aws elbv2 delete-listener \
  --listener-arn "$CORRECT_LISTENER_ARN" \
  --region "$AWS_REGION"

aws elbv2 delete-listener \
  --listener-arn "$WRONG_LISTENER_ARN" \
  --region "$AWS_REGION"
```

### Step 6 — Delete Both ALBs

```bash
aws elbv2 delete-load-balancer \
  --load-balancer-arn "$CORRECT_ALB_ARN" \
  --region "$AWS_REGION"

aws elbv2 delete-load-balancer \
  --load-balancer-arn "$WRONG_ALB_ARN" \
  --region "$AWS_REGION"
```

Wait:

```bash
aws elbv2 wait load-balancers-deleted \
  --load-balancer-arns "$CORRECT_ALB_ARN" "$WRONG_ALB_ARN" \
  --region "$AWS_REGION"
```

### Step 7 — Delete Target Group

```bash
aws elbv2 delete-target-group \
  --target-group-arn "$TG_ARN" \
  --region "$AWS_REGION"
```

### Step 8 — Verify EC2 Root Volume

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings' \
  --output json \
  --region "$AWS_REGION"
```

Verify the root volume has `DeleteOnTermination=true`.

### Step 9 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 10 — Verify IAM Role Ownership

```bash
aws iam list-role-tags \
  --role-name "$EC2_ROLE_NAME"
```

Confirm the Lab 06 project tag.

### Step 11 — Delete IAM Resources

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

### Step 12 — Verify Network Interface Removal

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status,Description:Description}' \
  --output table \
  --region "$AWS_REGION"
```

Wait until ALB and EC2 network interfaces are removed.

### Step 13 — Delete Security Groups

```bash
aws ec2 delete-security-group \
  --group-id "$EC2_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$ALB_SG_ID" \
  --region "$AWS_REGION"
```

### Step 14 — Delete Route Table Associations

```bash
aws ec2 disassociate-route-table \
  --association-id "$ROUTE_ASSOC_A" \
  --region "$AWS_REGION"

aws ec2 disassociate-route-table \
  --association-id "$ROUTE_ASSOC_B" \
  --region "$AWS_REGION"
```

### Step 15 — Delete Route Table

```bash
aws ec2 delete-route-table \
  --route-table-id "$ROUTE_TABLE_ID" \
  --region "$AWS_REGION"
```

### Step 16 — Delete Subnets

```bash
aws ec2 delete-subnet \
  --subnet-id "$SUBNET_A_ID" \
  --region "$AWS_REGION"

aws ec2 delete-subnet \
  --subnet-id "$SUBNET_B_ID" \
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

Check ALBs:

```bash
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?LoadBalancerName=='${CORRECT_ALB_NAME}' || LoadBalancerName=='${WRONG_ALB_NAME}'].LoadBalancerName" \
  --output json \
  --region "$AWS_REGION"
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

Also verify that the EC2 instance is terminated, IAM resources are deleted, and EBS storage is removed.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| Route 53 Alias A Record | Deleted |
| Private Hosted Zone | Deleted |
| Correct ALB | Deleted |
| Incorrect ALB | Deleted |
| ALB Listeners | Deleted |
| Target Group | Deleted |
| EC2 Instance | Terminated |
| Root EBS Volume | Deleted |
| IAM Role | Deleted |
| Instance Profile | Deleted |
| ALB Security Group | Deleted |
| EC2 Security Group | Deleted |
| Route Table | Deleted |
| Subnets | Deleted |
| Internet Gateway | Deleted |
| Lab VPC | Deleted |
| Default VPC | Unchanged |

---

## 19. Interview Questions and Answers

### Q1. What is a Route 53 alias record?

A Route 53 record that maps a hostname to a supported AWS resource, such as an Application Load Balancer.

### Q2. What is the difference between an alias A record and a CNAME?

An alias A record can point to certain AWS resources and can be used at the zone apex. A CNAME points to another hostname and cannot be used at the zone apex.

### Q3. What is CanonicalHostedZoneId?

The AWS-managed hosted zone identifier associated with a load balancer.

### Q4. Why do you need CanonicalHostedZoneId?

Route 53 requires it to identify the DNS zone of the ALB alias target.

### Q5. Can an alias point to an internal Application Load Balancer?

Yes. An alias record in a private hosted zone can target an internal ALB.

### Q6. Why might a Route 53 alias return DNS successfully but HTTP fail?

The alias may point to the wrong ALB, or the target ALB may have listener, target group, application, or network problems.

### Q7. What is EvaluateTargetHealth?

A Route 53 alias option that controls whether target health is evaluated for supported routing scenarios.

### Q8. How do you inspect the ALB DNS name and canonical zone ID?

```bash
aws elbv2 describe-load-balancers \
  --names route53-lab06-correct \
  --query 'LoadBalancers[].{DNS:DNSName,Zone:CanonicalHostedZoneId}'
```

### Q9. What does Route 53 UPSERT do?

It updates an existing record or creates the record if it does not already exist.

### Q10. What does HTTP 503 mean?

The requested service is unavailable. In this lab, the incorrect ALB deliberately returns 503 through a fixed-response listener.

### Q11. How do you differentiate a Route 53 problem from an ALB problem?

Inspect the Route 53 alias target, verify the intended ALB DNS name, inspect listener configuration, and compare HTTP responses from the alias and direct ALB endpoint.

### Q12. How would you explain this lab in an interview?

I deployed an EC2 web application behind an internal Application Load Balancer and created another internal ALB configured to return HTTP 503.

I created a private Route 53 hosted zone and intentionally configured an alias A record pointing to the wrong ALB.

DNS resolution succeeded, but HTTP requests through the application hostname returned 503.

I investigated the Route 53 alias, ALB DNS names, canonical hosted zone IDs, listener configurations, and target group health.

I identified the wrong alias target and corrected it using Route 53 UPSERT.

After remediation, I verified that the application hostname returned HTTP 200 through the intended ALB.

Finally, I deleted the temporary Route 53, ALB, EC2, IAM, and VPC resources.

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
└── 06-incorrect-alias-record/
    ├── README.md
    ├── ec2-trust-policy.json
    ├── user-data.sh
    ├── wrong-alb-response.json
    ├── wrong-alias.json
    ├── correct-alias.json
    └── delete-alias.json
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete incident and troubleshooting documentation |
| `ec2-trust-policy.json` | IAM trust policy for EC2 Systems Manager |
| `user-data.sh` | Deploys the EC2 HTTP application |
| `wrong-alb-response.json` | Creates the incorrect ALB's HTTP 503 fixed response |
| `wrong-alias.json` | Creates the incorrect Route 53 alias |
| `correct-alias.json` | Corrects the alias using UPSERT |
| `delete-alias.json` | Deletes the alias record during cleanup |

Optional evidence files can include sanitized DNS outputs, HTTP results, target health reports, and ALB listener configuration.

---

## 21. Lessons Learned and Skills Demonstrated

### Lessons Learned

This lab demonstrates how an incorrect Route 53 alias target can make a healthy application appear unavailable.

We deployed an EC2 HTTP application and created two internal Application Load Balancers.

The correct ALB forwarded traffic to a healthy EC2 target and returned HTTP 200.

The incorrect ALB returned HTTP 503 through a fixed-response listener.

We intentionally configured the application's Route 53 alias record to point to the incorrect ALB.

We investigated the incident by comparing Route 53 alias configuration, ALB DNS names, canonical hosted zone IDs, listener actions, target group health, and HTTP responses.

After identifying the wrong alias target, we updated the record using Route 53 UPSERT and verified that the application returned HTTP 200.

The exercise reinforced the importance of validating DNS destinations before troubleshooting healthy infrastructure.

**Key Lesson:** When a Route 53 alias resolves successfully but an application returns an error, verify the alias target's DNS name and canonical hosted zone ID. The problem may be incorrect DNS routing rather than application failure.

### Skills Demonstrated

- Amazon Route 53
- Private hosted zones
- Alias A records
- CanonicalHostedZoneId
- Route 53 UPSERT
- DNS troubleshooting
- Application Load Balancers
- ALB listener rules
- Fixed HTTP responses
- Target groups
- Target health checks
- HTTP 503 troubleshooting
- Amazon EC2
- Python HTTP server
- EC2 user data
- VPC subnet architecture
- Security groups
- AWS Systems Manager
- IAM roles and instance profiles
- AWS CLI v2
- Linux `dig`
- Linux `curl`
- Root cause analysis
- Application recovery verification
- AWS resource cleanup

### Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-R53-006 |
| Scenario | Incorrect Alias Record |
| Hosted Zone | Private |
| DNS Record | Alias A |
| Wrong Alias Target | `route53-lab06-wrong` |
| Correct Alias Target | `route53-lab06-correct` |
| DNS Before Fix | NOERROR |
| HTTP Before Fix | 503 |
| EC2 Application | Healthy |
| Target Group | Healthy |
| Root Cause | Incorrect alias target |
| Remediation | Route 53 UPSERT |
| DNS After Fix | Correct ALB |
| HTTP After Fix | 200 |
| Cleanup | Temporary resources removed |
| Incident Status | Resolved after verification |

**Key Takeaway:** Route 53 alias troubleshooting requires verifying the actual AWS resource referenced by the alias, not just whether the DNS name resolves. Comparing alias targets, ALB listeners, and backend health helps identify incorrect routing without unnecessary infrastructure changes.